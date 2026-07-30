/**
 * ViewerCamera — PerspectiveCamera + OrbitControls 管理
 *
 * 职责:
 *   - 创建 PerspectiveCamera
 *   - 创建 OrbitControls
 *   - 默认位置与目标点
 *   - 相机重置(立即)
 *   - 逐帧 controls.update
 *   - Resize aspect 更新
 *   - Dispose
 *
 * Reference:
 *   - figure-main/index.html initThree():
 *       PerspectiveCamera(30.0, aspect, 0.1, 20.0)
 *       camera.position.copy(DEFAULT_CAMERA_POSITION) = (0, 1.25, 2)
 *       new OrbitControls(camera, renderer.domElement)
 *       controls.screenSpacePanning = true
 *       controls.target.copy(DEFAULT_CONTROLS_TARGET) = (0, 1.25, 0)
 *       controls.update()
 *   - figure-main/index.html animate(): 每帧 controls.update()
 *   - figure-main/index.html smoothResetCamera(): 重置目标点参考(Phase 2B 实现平滑版)
 *   - ownverse-vrm-viewer/analysis/CAMERA_PIPELINE.md: 交叉验证
 *     (OWNverse 用 CameraControls 库,Figure 用 OrbitControls,以 Figure 为准)
 *
 * 与 Figure 的差异:
 *   - Figure 未启用 damping(animate 中直接 controls.update()),本实现保持一致,不启用 damping
 *   - Figure 在 IIFE 中初始化,本实现拆分为独立类
 *   - Figure 通过 smoothResetCamera() 实现平滑重置,本阶段仅实现 immediate reset(Phase 2B 再实现平滑)
 *
 * Phase 1B 限制:
 *   - 仅实现 immediate reset,不实现平滑过渡
 *   - 不实现 positional camera mode / pointer lock(Phase 2A)
 *   - 不实现 FOV 运行时调整(Phase 2A)
 */
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

// Figure 默认相机参数
var DEFAULT_FOV = 30.0;
var DEFAULT_NEAR = 0.1;
var DEFAULT_FAR = 20.0;
var DEFAULT_CAMERA_POSITION = { x: 0.0, y: 1.25, z: 2.0 };
var DEFAULT_CONTROLS_TARGET = { x: 0.0, y: 1.25, z: 0.0 };

/** 错误代码:Camera 初始化失败 */
export var CAMERA_INITIALIZATION_FAILED = 'CAMERA_INITIALIZATION_FAILED';

// Phase 2A-2: Camera 错误码
export var CAMERA_NOT_INITIALIZED = 'CAMERA_NOT_INITIALIZED';
export var CAMERA_DISPOSED = 'CAMERA_DISPOSED';
export var CAMERA_FOCUS_MODEL_MISSING = 'CAMERA_FOCUS_MODEL_MISSING';
export var CAMERA_FOCUS_BOUNDS_EMPTY = 'CAMERA_FOCUS_BOUNDS_EMPTY';
export var CAMERA_FOCUS_BOUNDS_INVALID = 'CAMERA_FOCUS_BOUNDS_INVALID';
export var CAMERA_FOCUS_FOV_INVALID = 'CAMERA_FOCUS_FOV_INVALID';

// Phase 2A-2: 聚焦边距(固定值,不根据文件名特殊处理)
var CAMERA_FOCUS_MARGIN = 1.2;

// Phase 2A-2: lastAction 枚举
var ACTION_INITIALIZE = 'INITIALIZE';
var ACTION_RESET = 'RESET';
var ACTION_FOCUS = 'FOCUS';
var ACTION_MODEL_REPLACED_FOCUS = 'MODEL_REPLACED_FOCUS';
// Phase 2B: 平滑重置 lastAction
var ACTION_SMOOTH_RESET = 'SMOOTH_RESET';
// Final Acceptance Fix: 裁剪更新原因
var ACTION_CLIP_UPDATE_RESIZE = 'CLIP_UPDATE_RESIZE';
var ACTION_CLIP_UPDATE_CONTROLS = 'CLIP_UPDATE_CONTROLS';

// Final Acceptance Fix: 裁剪范围计算常量
// near = clamp(distance * NEAR_RATIO, NEAR_MIN, NEAR_MAX)
var CLIP_NEAR_RATIO = 0.01;
var CLIP_NEAR_MIN = 0.005;
var CLIP_NEAR_MAX = 0.05;
// far = max(FAR_FLOOR, distance + modelRadius * FAR_RADIUS_FACTOR)
var CLIP_FAR_FLOOR = 100;
var CLIP_FAR_RADIUS_FACTOR = 20;
// controls.minDistance = max(MIN_DISTANCE_FLOOR, modelRadius * MIN_DISTANCE_RADIUS_RATIO)
var CONTROLS_MIN_DISTANCE_FLOOR = 0.1;
var CONTROLS_MIN_DISTANCE_RADIUS_RATIO = 0.3;
// controls.maxDistance = max(MAX_DISTANCE_FLOOR, modelRadius * MAX_DISTANCE_RADIUS_FACTOR)
var CONTROLS_MAX_DISTANCE_FLOOR = 10;
var CONTROLS_MAX_DISTANCE_RADIUS_FACTOR = 25;
// near/far 变化阈值(相对值),超过才调用 updateProjectionMatrix
var CLIP_CHANGE_THRESHOLD = 0.05;

// ===== Phase 2B: 平滑重置状态机 =====

/** 平滑过渡状态枚举 */
export var CameraTransitionState = Object.freeze({
  IDLE: 'IDLE',
  RUNNING: 'RUNNING',
  COMPLETED: 'COMPLETED',
  CANCELLED: 'CANCELLED',
  FAILED: 'FAILED',
  DISPOSED: 'DISPOSED'
});

/** Phase 2B: 取消原因枚举 */
var CANCEL_REASON_USER_INTERACTION = 'USER_INTERACTION';
var CANCEL_REASON_INSTANT_RESET = 'INSTANT_RESET';
var CANCEL_REASON_FOCUS = 'FOCUS';
var CANCEL_REASON_MODEL_REPLACED_FOCUS = 'MODEL_REPLACED_FOCUS';
var CANCEL_REASON_DISPOSE = 'DISPOSE';

/** Phase 2B: 平滑重置默认时长(秒) - ArkTavern 交互适配参数,不声称来自 Figure */
var DEFAULT_SMOOTH_RESET_DURATION = 0.45;
/** Phase 2B: 合法时长范围(秒) */
var MIN_SMOOTH_RESET_DURATION = 0.1;
var MAX_SMOOTH_RESET_DURATION = 2.0;

/** Phase 2B: 平滑重置错误码 */
export var CAMERA_SMOOTH_RESET_DURATION_INVALID = 'CAMERA_SMOOTH_RESET_DURATION_INVALID';
export var CAMERA_SMOOTH_RESET_STATE_INVALID = 'CAMERA_SMOOTH_RESET_STATE_INVALID';
export var CAMERA_SMOOTH_RESET_ALREADY_RUNNING = 'CAMERA_SMOOTH_RESET_ALREADY_RUNNING';
export var CAMERA_SMOOTH_RESET_CANCELLED = 'CAMERA_SMOOTH_RESET_CANCELLED';
export var CAMERA_SMOOTH_RESET_DISPOSED = 'CAMERA_SMOOTH_RESET_DISPOSED';

/**
 * Phase 2B: smootherStep 缓动函数(本地纯函数,不引入外部 Tween 库)。
 *
 * 比 smoothstep 在边缘更平滑(C2 连续导数)。
 * 公式: t^3 * (t * (t * 6 - 15) + 10)
 *
 * @param {number} t 进度 [0,1]
 * @returns {number} 缓动后的进度 [0,1]
 */
function smootherStep(t) {
  var clamped = Math.min(1, Math.max(0, t));
  return clamped * clamped * clamped *
    (clamped * (clamped * 6 - 15) + 10);
}

/**
 * Phase 2B: 创建空闲过渡结果。
 * @returns {object}
 */
function createIdleTransitionResult() {
  return {
    state: CameraTransitionState.IDLE,
    progress: 0,
    durationSeconds: 0,
    elapsedSeconds: 0,
    cancelReason: '',
    errorCode: '',
    errorMessage: '',
    startedAt: 0,
    completedAt: 0
  };
}

export class ViewerCamera {
  constructor() {
    /** @type {THREE.PerspectiveCamera|null} */
    this.camera = null;
    /** @type {OrbitControls|null} */
    this.controls = null;
    this._disposed = false;
    /** @type {string} Phase 2A-2: 最近一次相机操作 */
    this.lastAction = ACTION_INITIALIZE;

    // ===== Phase 2B: 平滑重置状态机 =====
    /** @type {string} 过渡状态 */
    this.transitionState = CameraTransitionState.IDLE;
    /** @type {number} 代次(防止过期结果提交) */
    this.transitionGeneration = 0;
    /** @type {number} 已经过渡时间(秒) */
    this.transitionElapsed = 0;
    /** @type {number} 过渡总时长(秒) */
    this.transitionDuration = 0;
    /** @type {object|null} 起点状态 */
    this.transitionStartState = null;
    /** @type {object|null} 终点状态(固定为 Figure 基准) */
    this.transitionTargetState = null;
    /** @type {string} 最近错误码 */
    this.transitionLastError = '';
    /** @type {string} 取消原因 */
    this.transitionCancelReason = '';
    /** @type {number} 过渡开始时间戳(ms) */
    this.transitionStartedAt = 0;
    /** @type {number} 过渡完成时间戳(ms) */
    this.transitionCompletedAt = 0;
    /** @type {function|null} OrbitControls start 事件处理器(用于取消监听) */
    this._controlsStartHandler = null;

    // ===== Final Acceptance Fix: 相机裁剪状态 =====
    /** @type {number} 最近一次模型包围球半径 */
    this.lastModelBoundingRadius = 0;
    /** @type {number} 最近一次 controls.minDistance */
    this.lastMinDistance = 0;
    /** @type {number} 最近一次 controls.maxDistance */
    this.lastMaxDistance = 0;
    /** @type {string} 最近一次裁剪更新原因 */
    this.lastClipUpdateReason = '';
    /** @type {number} 上次更新裁剪时的相机距离(用于 change 事件节流) */
    this._lastClipUpdateDistance = -1;
    /** @type {function|null} OrbitControls change 事件处理器 */
    this._controlsChangeHandler = null;
  }

  /**
   * 初始化 Camera 与 OrbitControls。
   * @param {HTMLElement} rendererDomElement WebGLRenderer.domElement
   * @throws {Error} rendererDomElement 缺失时抛出 code=CAMERA_INITIALIZATION_FAILED
   */
  initialize(rendererDomElement) {
    if (!rendererDomElement) {
      var err = new Error('rendererDomElement is required');
      err.code = CAMERA_INITIALIZATION_FAILED;
      throw err;
    }

    // ===== PerspectiveCamera =====
    // Figure: PerspectiveCamera(30.0, aspect, 0.1, 20.0)
    var width = rendererDomElement.clientWidth || window.innerWidth || 1;
    var height = rendererDomElement.clientHeight || window.innerHeight || 1;
    this.camera = new THREE.PerspectiveCamera(
      DEFAULT_FOV,
      width / height,
      DEFAULT_NEAR,
      DEFAULT_FAR
    );
    // Figure: camera.position.copy(DEFAULT_CAMERA_POSITION) = (0, 1.25, 2)
    this.camera.position.set(
      DEFAULT_CAMERA_POSITION.x,
      DEFAULT_CAMERA_POSITION.y,
      DEFAULT_CAMERA_POSITION.z
    );

    // ===== OrbitControls =====
    // Figure: new OrbitControls(camera, renderer.domElement)
    this.controls = new OrbitControls(this.camera, rendererDomElement);
    // Figure: controls.screenSpacePanning = true
    this.controls.screenSpacePanning = true;
    // Figure: controls.target.copy(DEFAULT_CONTROLS_TARGET) = (0, 1.25, 0)
    this.controls.target.set(
      DEFAULT_CONTROLS_TARGET.x,
      DEFAULT_CONTROLS_TARGET.y,
      DEFAULT_CONTROLS_TARGET.z
    );
    // Figure 未启用 damping(animate 中直接 controls.update())
    // 按"以源码为准"原则,不启用 damping
    this.controls.enableDamping = false;
    // Figure: controls.update()
    this.controls.update();
    // Phase 2A-2: 初始化完成
    this.lastAction = ACTION_INITIALIZE;

    // Phase 2B: 注册 OrbitControls 'start' 事件监听器
    // 用户直接操作 3D Canvas 时取消正在运行的平滑重置
    // 控制面板触摸隔离调用 setCameraControlsEnabled(false) 不会触发此事件
    // (OrbitControls.start 只在 controls.enabled=true 且接收到有效指针时触发)
    this._controlsStartHandler = () => {
      this._cancelTransitionIfNeeded(CANCEL_REASON_USER_INTERACTION);
    };
    try {
      this.controls.addEventListener('start', this._controlsStartHandler);
    } catch (e) {
      // 某些 OrbitControls 版本可能不支持 addEventListener,记录但不阻塞
      console.warn('[ViewerCamera] OrbitControls start listener failed: ' + (e && e.message ? e.message : String(e)));
    }

    // Final Acceptance Fix: 注册 OrbitControls 'change' 事件监听器
    // 距离发生明显变化(超过阈值)时更新 near/far 裁剪范围,避免模型被裁剪平面切开
    // 不每帧无条件执行,仅在 change 事件且距离变化超过阈值时执行
    this._controlsChangeHandler = () => {
      this._onControlsChange();
    };
    try {
      this.controls.addEventListener('change', this._controlsChangeHandler);
    } catch (e) {
      console.warn('[ViewerCamera] OrbitControls change listener failed: ' + (e && e.message ? e.message : String(e)));
    }
  }

  /**
   * 每帧更新。
   * Figure: animate() 中调用 controls.update()
   *
   * Phase 2B: 若平滑过渡处于 RUNNING,先更新过渡插值,再调用 controls.update()。
   * 顺序(与 AGENTS.md §十 推荐一致):
   *   1. 更新平滑相机过渡
   *   2. controls.update()
   *
   * @param {number} deltaSeconds 自上一帧以来的秒数
   */
  update(deltaSeconds) {
    if (this._disposed || !this.controls) return;
    // Phase 2B: 先更新平滑过渡
    if (this.transitionState === CameraTransitionState.RUNNING) {
      this._applyTransitionFrame(deltaSeconds);
    }
    this.controls.update();
  }

  /**
   * 调整 Camera aspect。
   * Figure resize handler: camera.aspect = w/h; camera.updateProjectionMatrix()
   *
   * Final Acceptance Fix: resize 后调用 updateCameraClipping,确保画布尺寸变化时裁剪范围正确。
   *
   * @param {number} width
   * @param {number} height
   */
  resize(width, height) {
    if (this._disposed || !this.camera) return;
    if (width <= 0 || height <= 0) return;
    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();
    // Final Acceptance Fix: 画布尺寸变化后更新裁剪范围
    if (this.controls) {
      this.updateCameraClipping(null, ACTION_CLIP_UPDATE_RESIZE);
    }
  }

  /**
   * Phase 2A-2: 重置相机到 Figure 基准位置与目标点。
   *
   * Figure 基准(精确,不依赖当前模型大小):
   *   FOV=30, position=(0, 1.25, 2), target=(0, 1.25, 0)
   *
   * Final Acceptance Fix: near/far 不再使用固定 0.1/20,
   * 而是重置 position/target 后调用 updateCameraClipping 根据当前距离和模型半径计算,
   * 避免远距离拉远时模型被 far plane 裁掉。
   *
   * preserveControlsEnabled:
   *   重置发生时若 controls.enabled === false(控制面板正在触摸),
   *   重置结束仍保持 enabled === false,等待控制面板触摸结束后
   *   由现有手势隔离逻辑恢复。
   *
   * @param {object} [options]
   * @param {boolean} [options.preserveControlsEnabled=true] 是否保持 controls.enabled 状态
   * @param {object} [options.modelBounds] 模型包围信息 { radius: number } (可选)
   * @returns {{success: boolean, state?: object, error?: string}}
   */
  reset(options) {
    if (this._disposed) {
      return { success: false, error: CAMERA_DISPOSED };
    }
    if (!this.camera || !this.controls) {
      return { success: false, error: CAMERA_NOT_INITIALIZED };
    }

    // Phase 2B: 即时重置必须先取消正在运行的平滑过渡
    this._cancelTransitionIfNeeded(CANCEL_REASON_INSTANT_RESET);

    var opts = options || {};
    var preserveEnabled = opts.preserveControlsEnabled !== false;

    // 1. 保存 controls.enabled
    var savedEnabled = this.controls.enabled;

    // 2. 恢复 FOV(Figure 基准), near/far 由 updateCameraClipping 计算
    this.camera.fov = DEFAULT_FOV;

    // 3. 恢复 position
    this.camera.position.set(
      DEFAULT_CAMERA_POSITION.x,
      DEFAULT_CAMERA_POSITION.y,
      DEFAULT_CAMERA_POSITION.z
    );

    // 4. 恢复 target
    this.controls.target.set(
      DEFAULT_CONTROLS_TARGET.x,
      DEFAULT_CONTROLS_TARGET.y,
      DEFAULT_CONTROLS_TARGET.z
    );

    // 5. controls.update() 先应用位置
    this.controls.update();

    // 6. Final Acceptance Fix: 统一更新裁剪范围和距离限制
    this.updateCameraClipping(opts.modelBounds || null, ACTION_RESET);

    // 7. 按 preserveControlsEnabled 恢复 enabled
    if (preserveEnabled) {
      this.controls.enabled = savedEnabled;
    }

    // 8. 更新 lastAction
    this.lastAction = ACTION_RESET;

    // 9. 返回完整 CameraState
    return { success: true, state: this._buildCameraState() };
  }

  /** @returns {THREE.PerspectiveCamera|null} */
  getCamera() { return this.camera; }

  /** @returns {OrbitControls|null} */
  getControls() { return this.controls; }

  /**
   * Phase 2A-1: 启用/禁用 OrbitControls。
   *
   * 用于控制面板触摸隔离:ArkUI 控制面板发生触摸时禁用 controls,
   * 触摸结束或取消时恢复 controls,避免手势穿透到 Three.js Canvas。
   *
   * 安全约束:
   * - enabled 必须为布尔值(由 Bridge 层校验,此处仅做 typeof 检查)
   * - Camera 尚未初始化时返回受控失败,不抛到全局
   * - 已 dispose 时返回受控失败
   *
   * @param {boolean} enabled true=启用 controls.enabled;false=禁用
   * @returns {{success: boolean, enabled?: boolean, error?: string}}
   */
  setControlsEnabled(enabled) {
    if (this._disposed) {
      return { success: false, error: 'CAMERA_DISPOSED' };
    }
    if (typeof enabled !== 'boolean') {
      return { success: false, error: 'INVALID_ARGUMENT' };
    }
    if (!this.controls) {
      return { success: false, error: 'CAMERA_NOT_INITIALIZED' };
    }
    this.controls.enabled = enabled;
    return { success: true, enabled: this.controls.enabled };
  }

  /**
   * Phase 2A-1: 查询 OrbitControls 当前启用状态。
   *
   * @returns {{success: boolean, enabled?: boolean, error?: string}}
   */
  getControlsEnabled() {
    if (this._disposed) {
      return { success: false, error: 'CAMERA_DISPOSED' };
    }
    if (!this.controls) {
      return { success: false, error: 'CAMERA_NOT_INITIALIZED' };
    }
    return { success: true, enabled: !!this.controls.enabled };
  }

  /**
   * Phase 2A-2: 聚焦到指定模型根节点。
   *
   * 算法:
   *   1. 对 modelRoot 调用 updateWorldMatrix(true, true)
   *   2. 使用 new THREE.Box3().setFromObject(modelRoot) 计算世界空间包围盒
   *   3. 验证包围盒非空、center/size 有限、sphere.radius 有限正数
   *   4. 计算垂直/水平半 FOV,取较小者作为限制半 FOV
   *   5. distance = sphere.radius / sin(limitingHalfFov) * CAMERA_FOCUS_MARGIN
   *   6. 保留当前观察方向(camera.position - controls.target),无效则用 (0,0,1)
   *   7. 新相机位置 = sphere.center + direction * distance
   *   8. 新目标 = sphere.center
   *   9. 更新 near/far 避免裁剪
   *  10. camera.updateProjectionMatrix() + controls.update()
   *
   * 安全约束:
   *   - 失败不得修改现有 Camera position/target/near/far
   *   - 因此先完整计算和验证,再一次性提交相机状态
   *   - preserveControlsEnabled 与 reset 一致
   *
   * @param {THREE.Object3D} modelRoot 模型根节点(通常为 currentVrm.scene)
   * @param {object} [options]
   * @param {number} [options.margin=1.2] 聚焦边距
   * @param {boolean} [options.preserveDirection=true] 是否保留当前观察方向
   * @param {boolean} [options.preserveControlsEnabled=true] 是否保持 controls.enabled
   * @param {string} [options.action='FOCUS'] lastAction 标记
   * @returns {{success: boolean, state?: object, error?: string, bounds?: object}}
   */
  focusOnObject(modelRoot, options) {
    if (this._disposed) {
      return { success: false, error: CAMERA_DISPOSED };
    }
    if (!this.camera || !this.controls) {
      return { success: false, error: CAMERA_NOT_INITIALIZED };
    }
    if (!modelRoot) {
      return { success: false, error: CAMERA_FOCUS_MODEL_MISSING };
    }

    // Phase 2B: 聚焦/自动取景必须先取消正在运行的平滑过渡
    var opts = options || {};
    var focusCancelReason = opts.action === ACTION_MODEL_REPLACED_FOCUS
      ? CANCEL_REASON_MODEL_REPLACED_FOCUS
      : CANCEL_REASON_FOCUS;
    this._cancelTransitionIfNeeded(focusCancelReason);

    var margin = typeof opts.margin === 'number' && opts.margin > 0 ? opts.margin : CAMERA_FOCUS_MARGIN;
    var preserveDirection = opts.preserveDirection !== false;
    var preserveEnabled = opts.preserveControlsEnabled !== false;
    var action = typeof opts.action === 'string' && opts.action.length > 0 ? opts.action : ACTION_FOCUS;

    // 1. 更新世界矩阵
    modelRoot.updateWorldMatrix(true, true);

    // 2. 计算包围盒
    var box = new THREE.Box3().setFromObject(modelRoot);

    // 3. 验证包围盒非空
    if (!box || box.isEmpty()) {
      return { success: false, error: CAMERA_FOCUS_BOUNDS_EMPTY };
    }

    var center = box.getCenter(new THREE.Vector3());
    var size = box.getSize(new THREE.Vector3());
    var sphere = box.getBoundingSphere(new THREE.Sphere());

    // 验证 center/size 有限
    if (!isFinite(center.x) || !isFinite(center.y) || !isFinite(center.z) ||
        !isFinite(size.x) || !isFinite(size.y) || !isFinite(size.z)) {
      return { success: false, error: CAMERA_FOCUS_BOUNDS_INVALID };
    }
    // 验证 sphere.radius 有限正数
    if (!isFinite(sphere.radius) || sphere.radius <= 0) {
      return { success: false, error: CAMERA_FOCUS_BOUNDS_INVALID };
    }

    // 4. 计算 FOV
    var fov = this.camera.fov;
    if (!isFinite(fov) || fov <= 0 || fov >= 180) {
      return { success: false, error: CAMERA_FOCUS_FOV_INVALID };
    }

    var verticalHalfFov = THREE.MathUtils.degToRad(fov * 0.5);
    var aspect = this.camera.aspect;
    if (!isFinite(aspect) || aspect <= 0) {
      aspect = 1;
    }
    var horizontalHalfFov = Math.atan(Math.tan(verticalHalfFov) * aspect);
    var limitingHalfFov = Math.min(verticalHalfFov, horizontalHalfFov);

    if (limitingHalfFov <= 0) {
      return { success: false, error: CAMERA_FOCUS_FOV_INVALID };
    }

    // 5. 计算距离
    var distance = sphere.radius / Math.sin(limitingHalfFov);
    distance *= margin;

    if (!isFinite(distance) || distance <= 0) {
      return { success: false, error: CAMERA_FOCUS_BOUNDS_INVALID };
    }

    // 6. 保留当前观察方向
    var direction;
    if (preserveDirection) {
      direction = new THREE.Vector3().subVectors(this.camera.position, this.controls.target);
      if (direction.lengthSq() < 1e-10) {
        direction = new THREE.Vector3(0, 0, 1);
      }
      direction.normalize();
    } else {
      direction = new THREE.Vector3(0, 0, 1);
    }

    // 7. 计算新的相机位置和目标(先计算,不提交)
    var newPosition = new THREE.Vector3().copy(sphere.center).addScaledVector(direction, distance);
    var newTarget = new THREE.Vector3().copy(sphere.center);

    // 8. Final Acceptance Fix: 保存 controls.enabled,一次性提交相机状态
    var savedEnabled = this.controls.enabled;

    // 一次性提交相机状态
    this.camera.position.copy(newPosition);
    this.controls.target.copy(newTarget);
    this.controls.update();

    // Final Acceptance Fix: 统一调用 updateCameraClipping 计算 near/far/minDistance/maxDistance
    // 避免旧逻辑的 near = distance - radius*2.5 在聚焦时过小导致裁剪
    this.updateCameraClipping(
      { radius: sphere.radius },
      action
    );

    // 9. 按 preserveControlsEnabled 恢复 enabled
    if (preserveEnabled) {
      this.controls.enabled = savedEnabled;
    }

    // 10. 更新 lastAction
    this.lastAction = action;

    // 11. 返回完整 CameraState + bounds
    return {
      success: true,
      state: this._buildCameraState(),
      bounds: {
        center: { x: center.x, y: center.y, z: center.z },
        size: { x: size.x, y: size.y, z: size.z },
        radius: sphere.radius
      }
    };
  }

  /**
   * Phase 2A-2: 获取当前 Camera 状态。
   *
   * @returns {{success: boolean, state?: object, error?: string}}
   */
  getCameraState() {
    if (this._disposed) {
      return { success: false, error: CAMERA_DISPOSED };
    }
    if (!this.camera || !this.controls) {
      return { success: false, error: CAMERA_NOT_INITIALIZED };
    }
    return { success: true, state: this._buildCameraState() };
  }

  // ===== Final Acceptance Fix: 相机裁剪范围统一更新 =====

  /**
   * Final Acceptance Fix: 统一更新相机裁剪范围 (near/far) 和 controls 距离限制。
   *
   * 根据:
   *   - camera 到 controls.target 的距离
   *   - 当前模型 bounding sphere radius
   *   - 当前 focus/reset 模式 (通过 reason 区分)
   *
   * 计算并应用:
   *   - camera.near = clamp(distance * CLIP_NEAR_RATIO, CLIP_NEAR_MIN, CLIP_NEAR_MAX)
   *   - camera.far = max(CLIP_FAR_FLOOR, distance + modelRadius * CLIP_FAR_RADIUS_FACTOR)
   *   - controls.minDistance = max(CONTROLS_MIN_DISTANCE_FLOOR, modelRadius * RADIUS_RATIO)
   *   - controls.maxDistance = max(CONTROLS_MAX_DISTANCE_FLOOR, modelRadius * RADIUS_FACTOR)
   *     且 maxDistance < camera.far
   *
   * 约束:
   *   - near > 0
   *   - far > near
   *   - controls.minDistance > 0
   *   - controls.maxDistance < camera.far
   *   - 不使用 near=0 / near=0.000001 / 无限大 far
   *
   * 只在 near/far 实际变化超过阈值时调用 camera.updateProjectionMatrix()。
   *
   * @param {object} modelBounds 模型包围信息 { radius: number } 或 null (使用上次缓存)
   * @param {string} reason 更新原因 (用于 Debug)
   * @returns {{success: boolean, near?: number, far?: number, minDistance?: number, maxDistance?: number, updated?: boolean}}
   */
  updateCameraClipping(modelBounds, reason) {
    if (this._disposed) {
      return { success: false };
    }
    if (!this.camera || !this.controls) {
      return { success: false };
    }

    // 更新模型半径缓存
    if (modelBounds && typeof modelBounds.radius === 'number' &&
        isFinite(modelBounds.radius) && modelBounds.radius > 0) {
      this.lastModelBoundingRadius = modelBounds.radius;
    }
    var modelRadius = this.lastModelBoundingRadius;
    // 若无模型半径信息,使用默认值 (Figure 基准模型约 1.5m)
    if (!isFinite(modelRadius) || modelRadius <= 0) {
      modelRadius = 1.5;
    }

    // 计算当前距离
    var pos = this.camera.position;
    var target = this.controls.target;
    var dx = pos.x - target.x;
    var dy = pos.y - target.y;
    var dz = pos.z - target.z;
    var distance = Math.sqrt(dx * dx + dy * dy + dz * dz);
    if (!isFinite(distance) || distance <= 0) {
      return { success: false };
    }

    // 计算 near: clamp(distance * RATIO, MIN, MAX)
    var newNear = distance * CLIP_NEAR_RATIO;
    if (newNear < CLIP_NEAR_MIN) newNear = CLIP_NEAR_MIN;
    if (newNear > CLIP_NEAR_MAX) newNear = CLIP_NEAR_MAX;

    // 计算 far: max(FLOOR, distance + modelRadius * FACTOR)
    var newFar = Math.max(CLIP_FAR_FLOOR, distance + modelRadius * CLIP_FAR_RADIUS_FACTOR);

    // 确保 far > near + 1 (最小间隔)
    if (newFar <= newNear) {
      newFar = newNear + 1;
    }

    // 计算 controls.minDistance: max(FLOOR, modelRadius * RATIO)
    var newMinDistance = Math.max(
      CONTROLS_MIN_DISTANCE_FLOOR,
      modelRadius * CONTROLS_MIN_DISTANCE_RADIUS_RATIO
    );

    // 计算 controls.maxDistance: max(FLOOR, modelRadius * FACTOR)
    var newMaxDistance = Math.max(
      CONTROLS_MAX_DISTANCE_FLOOR,
      modelRadius * CONTROLS_MAX_DISTANCE_RADIUS_FACTOR
    );

    // 约束: controls.maxDistance < camera.far
    if (newMaxDistance >= newFar) {
      newMaxDistance = newFar - 0.1;
    }
    // 约束: controls.minDistance < controls.maxDistance
    if (newMinDistance >= newMaxDistance) {
      newMinDistance = newMaxDistance * 0.1;
    }

    // 判断 near/far 是否变化超过阈值
    var oldNear = this.camera.near;
    var oldFar = this.camera.far;
    var nearChanged = Math.abs(newNear - oldNear) / Math.max(oldNear, 1e-6) > CLIP_CHANGE_THRESHOLD;
    var farChanged = Math.abs(newFar - oldFar) / Math.max(oldFar, 1e-6) > CLIP_CHANGE_THRESHOLD;

    // 应用 controls 距离限制
    this.controls.minDistance = newMinDistance;
    this.controls.maxDistance = newMaxDistance;
    this.lastMinDistance = newMinDistance;
    this.lastMaxDistance = newMaxDistance;

    // 应用 near/far (仅在变化超过阈值时调用 updateProjectionMatrix)
    this.camera.near = newNear;
    this.camera.far = newFar;
    if (nearChanged || farChanged) {
      this.camera.updateProjectionMatrix();
    }

    this.lastClipUpdateReason = String(reason || 'UNKNOWN');
    this._lastClipUpdateDistance = distance;

    return {
      success: true,
      near: newNear,
      far: newFar,
      minDistance: newMinDistance,
      maxDistance: newMaxDistance,
      updated: nearChanged || farChanged
    };
  }

  /**
   * Final Acceptance Fix: OrbitControls 'change' 事件处理器。
   *
   * 距离发生明显变化(超过阈值)时更新裁剪范围。
   * 不每帧无条件执行,仅在距离变化超过阈值时执行。
   *
   * @private
   */
  _onControlsChange() {
    if (this._disposed || !this.camera || !this.controls) return;

    var pos = this.camera.position;
    var target = this.controls.target;
    var dx = pos.x - target.x;
    var dy = pos.y - target.y;
    var dz = pos.z - target.z;
    var distance = Math.sqrt(dx * dx + dy * dy + dz * dz);
    if (!isFinite(distance) || distance <= 0) return;

    // 距离变化超过阈值才更新
    if (this._lastClipUpdateDistance > 0) {
      var relativeChange = Math.abs(distance - this._lastClipUpdateDistance) /
        Math.max(this._lastClipUpdateDistance, 1e-6);
      if (relativeChange < CLIP_CHANGE_THRESHOLD) return;
    }

    // 使用缓存的模型半径更新裁剪
    this.updateCameraClipping(null, ACTION_CLIP_UPDATE_CONTROLS);
  }

  /**
   * Final Acceptance Fix: 计算模型包围球半径。
   *
   * @param {THREE.Object3D} modelRoot 模型根节点
   * @returns {{radius: number, center: THREE.Vector3, valid: boolean}}
   */
  computeModelBounds(modelRoot) {
    if (!modelRoot) {
      return { radius: 0, center: new THREE.Vector3(), valid: false };
    }
    try {
      modelRoot.updateWorldMatrix(true, true);
      var box = new THREE.Box3().setFromObject(modelRoot);
      if (!box || box.isEmpty()) {
        return { radius: 0, center: new THREE.Vector3(), valid: false };
      }
      var sphere = box.getBoundingSphere(new THREE.Sphere());
      if (!isFinite(sphere.radius) || sphere.radius <= 0) {
        return { radius: 0, center: new THREE.Vector3(), valid: false };
      }
      return { radius: sphere.radius, center: sphere.center, valid: true };
    } catch (e) {
      return { radius: 0, center: new THREE.Vector3(), valid: false };
    }
  }

  // ===== Phase 2B: 平滑重置 =====

  /**
   * Phase 2B: 平滑重置相机到 Figure 基准位置。
   *
   * 同步启动过渡,由现有帧循环(ViewerCamera.update)异步驱动完成。
   * 不创建第二个 requestAnimationFrame。
   *
   * 终点固定为 Figure 基准(与 reset() 完全一致):
   *   FOV=30, near=0.1, far=20, position=(0,1.25,2), target=(0,1.25,0)
   *
   * 起点为调用时当前真实相机状态。
   *
   * 缓动:smootherStep(本地纯函数,不引入外部 Tween 库)
   *
   * 控制状态:
   *   - preserveControlsEnabled=true 时,过渡开始前 controls.enabled 状态在过渡完成后保持不变
   *   - controls.enabled 只控制用户输入,不阻止内部相机插值
   *
   * 异常安全:
   *   - 启动失败不修改相机
   *   - 运行中遇到无效数值进入 FAILED,保留上一帧有效相机状态
   *
   * @param {object} [options]
   * @param {number} [options.durationSeconds=0.45] 过渡时长(0.1~2.0 秒)
   * @param {boolean} [options.preserveControlsEnabled=true] 是否保持 controls.enabled
   * @returns {{success: boolean, state?: string, error?: string, transition?: object}}
   */
  smoothReset(options) {
    if (this._disposed) {
      return { success: false, error: CAMERA_SMOOTH_RESET_DISPOSED };
    }
    if (!this.camera || !this.controls) {
      return { success: false, error: CAMERA_NOT_INITIALIZED };
    }
    // 重复启动拒绝:当前 RUNNING 时返回当前状态,不创建第二个过渡
    if (this.transitionState === CameraTransitionState.RUNNING) {
      return {
        success: false,
        error: CAMERA_SMOOTH_RESET_ALREADY_RUNNING,
        transition: this.getTransitionState()
      };
    }

    var opts = options || {};
    var duration = typeof opts.durationSeconds === 'number'
      ? opts.durationSeconds
      : DEFAULT_SMOOTH_RESET_DURATION;
    if (!isFinite(duration) ||
        duration < MIN_SMOOTH_RESET_DURATION ||
        duration > MAX_SMOOTH_RESET_DURATION) {
      return { success: false, error: CAMERA_SMOOTH_RESET_DURATION_INVALID };
    }

    // 捕获当前真实状态作为起点
    var startState = this._captureCurrentCameraState();
    if (!startState) {
      return { success: false, error: CAMERA_SMOOTH_RESET_STATE_INVALID };
    }
    // 验证起点所有数值有限
    if (!this._isFiniteCameraState(startState)) {
      return { success: false, error: CAMERA_SMOOTH_RESET_STATE_INVALID };
    }

    // 终点固定为 Figure 基准
    var targetState = this._buildFigureTargetState();
    // 验证终点所有数值有限
    if (!this._isFiniteCameraState(targetState)) {
      return { success: false, error: CAMERA_SMOOTH_RESET_STATE_INVALID };
    }

    // 启动过渡
    this.transitionGeneration++;
    this.transitionState = CameraTransitionState.RUNNING;
    this.transitionElapsed = 0;
    this.transitionDuration = duration;
    this.transitionStartState = startState;
    this.transitionTargetState = targetState;
    this.transitionLastError = '';
    this.transitionCancelReason = '';
    this.transitionStartedAt = Date.now();
    this.transitionCompletedAt = 0;

    return {
      success: true,
      state: CameraTransitionState.RUNNING,
      transition: this.getTransitionState()
    };
  }

  /**
   * Phase 2B: 获取当前过渡状态。
   * @returns {object} 过渡结果对象
   */
  getTransitionState() {
    var progress = 0;
    if (this.transitionState === CameraTransitionState.COMPLETED) {
      progress = 1;
    } else if (this.transitionState === CameraTransitionState.RUNNING && this.transitionDuration > 0) {
      progress = Math.min(1, this.transitionElapsed / this.transitionDuration);
    } else if (this.transitionState === CameraTransitionState.CANCELLED ||
               this.transitionState === CameraTransitionState.FAILED) {
      // 保留取消/失败时的进度快照
      if (this.transitionDuration > 0) {
        progress = Math.min(1, this.transitionElapsed / this.transitionDuration);
      }
    }
    return {
      state: this.transitionState,
      progress: progress,
      durationSeconds: this.transitionDuration,
      elapsedSeconds: this.transitionElapsed,
      cancelReason: this.transitionCancelReason,
      errorCode: this.transitionLastError,
      errorMessage: this.transitionLastError ? 'Camera transition failed: ' + this.transitionLastError : '',
      startedAt: this.transitionStartedAt,
      completedAt: this.transitionCompletedAt
    };
  }

  /**
   * Phase 2B: 取消当前平滑过渡。
   *
   * 取消后:
   *   - 保留取消瞬间的相机位置(不跳到终点,不恢复起点)
   *   - 不修改 controls.enabled
   *
   * @param {string} reason 取消原因
   */
  cancelTransition(reason) {
    if (this._disposed) return;
    if (this.transitionState !== CameraTransitionState.RUNNING) return;
    this.transitionState = CameraTransitionState.CANCELLED;
    this.transitionCancelReason = String(reason || 'UNKNOWN');
    this.transitionCompletedAt = Date.now();
  }

  /**
   * Phase 2B: 内部取消辅助(仅在 RUNNING 时取消)。
   * @param {string} reason
   * @private
   */
  _cancelTransitionIfNeeded(reason) {
    if (this.transitionState === CameraTransitionState.RUNNING) {
      this.cancelTransition(reason);
    }
  }

  /**
   * Phase 2B: 每帧应用过渡插值。
   *
   * 流程:
   *   1. elapsed += deltaSeconds
   *   2. progress = min(1, elapsed / duration)
   *   3. eased = smootherStep(progress)
   *   4. 插值 position/target/fov/near/far
   *   5. camera.updateProjectionMatrix() + controls.update()
   *   6. 到达终点时显式写入精确 Figure 值,避免浮点残差
   *   7. state = COMPLETED, lastAction = SMOOTH_RESET
   *
   * 失败处理:
   *   - 插值遇到无效数值 → state=FAILED,保留上一帧有效相机状态
   *
   * @param {number} deltaSeconds
   * @private
   */
  _applyTransitionFrame(deltaSeconds) {
    if (!this.camera || !this.controls) return;
    if (!this.transitionStartState || !this.transitionTargetState) {
      this.transitionState = CameraTransitionState.FAILED;
      this.transitionLastError = CAMERA_SMOOTH_RESET_STATE_INVALID;
      this.transitionCompletedAt = Date.now();
      return;
    }

    // 1. 累加 elapsed
    var delta = typeof deltaSeconds === 'number' && isFinite(deltaSeconds) && deltaSeconds > 0
      ? deltaSeconds
      : 0;
    this.transitionElapsed += delta;

    // 2. 计算进度
    var progress = this.transitionDuration > 0
      ? Math.min(1, this.transitionElapsed / this.transitionDuration)
      : 1;

    // 3. 缓动
    var eased = smootherStep(progress);

    var s = this.transitionStartState;
    var t = this.transitionTargetState;

    // 4. 插值
    var newPos = this._lerpVec3(s.position, t.position, eased);
    var newTarget = this._lerpVec3(s.target, t.target, eased);
    var newFov = s.fov + (t.fov - s.fov) * eased;
    var newNear = s.near + (t.near - s.near) * eased;
    var newFar = s.far + (t.far - s.far) * eased;

    // 验证插值结果有限
    if (!isFinite(newPos.x) || !isFinite(newPos.y) || !isFinite(newPos.z) ||
        !isFinite(newTarget.x) || !isFinite(newTarget.y) || !isFinite(newTarget.z) ||
        !isFinite(newFov) || !isFinite(newNear) || !isFinite(newFar)) {
      this.transitionState = CameraTransitionState.FAILED;
      this.transitionLastError = CAMERA_SMOOTH_RESET_STATE_INVALID;
      this.transitionCompletedAt = Date.now();
      return;
    }

    // 5. 应用到相机
    this.camera.position.set(newPos.x, newPos.y, newPos.z);
    this.controls.target.set(newTarget.x, newTarget.y, newTarget.z);
    this.camera.fov = newFov;
    this.camera.near = newNear;
    this.camera.far = newFar;
    this.camera.updateProjectionMatrix();
    // controls.update() 由外层 update() 统一调用,这里不重复

    // 6. 到达终点
    if (progress >= 1) {
      // 显式写入精确 Figure 值,避免浮点残差
      this.camera.position.set(
        DEFAULT_CAMERA_POSITION.x,
        DEFAULT_CAMERA_POSITION.y,
        DEFAULT_CAMERA_POSITION.z
      );
      this.controls.target.set(
        DEFAULT_CONTROLS_TARGET.x,
        DEFAULT_CONTROLS_TARGET.y,
        DEFAULT_CONTROLS_TARGET.z
      );
      this.camera.fov = DEFAULT_FOV;
      // Final Acceptance Fix: near/far 由 updateCameraClipping 计算,不再使用固定 DEFAULT_NEAR/FAR
      this.updateCameraClipping(null, ACTION_SMOOTH_RESET);

      this.transitionState = CameraTransitionState.COMPLETED;
      this.transitionCompletedAt = Date.now();
      this.lastAction = ACTION_SMOOTH_RESET;
    }
  }

  /**
   * Phase 2B: 捕获当前相机状态(作为过渡起点)。
   * @returns {object|null}
   * @private
   */
  _captureCurrentCameraState() {
    if (!this.camera || !this.controls) return null;
    var pos = this.camera.position;
    var target = this.controls.target;
    return {
      position: { x: pos.x, y: pos.y, z: pos.z },
      target: { x: target.x, y: target.y, z: target.z },
      fov: this.camera.fov,
      near: this.camera.near,
      far: this.camera.far
    };
  }

  /**
   * Phase 2B: 构造 Figure 基准目标状态(过渡终点)。
   * @returns {object}
   * @private
   */
  _buildFigureTargetState() {
    return {
      position: {
        x: DEFAULT_CAMERA_POSITION.x,
        y: DEFAULT_CAMERA_POSITION.y,
        z: DEFAULT_CAMERA_POSITION.z
      },
      target: {
        x: DEFAULT_CONTROLS_TARGET.x,
        y: DEFAULT_CONTROLS_TARGET.y,
        z: DEFAULT_CONTROLS_TARGET.z
      },
      fov: DEFAULT_FOV,
      near: DEFAULT_NEAR,
      far: DEFAULT_FAR
    };
  }

  /**
   * Phase 2B: 验证相机状态所有数值有限。
   * @param {object} state
   * @returns {boolean}
   * @private
   */
  _isFiniteCameraState(state) {
    if (!state || !state.position || !state.target) return false;
    return isFinite(state.position.x) && isFinite(state.position.y) && isFinite(state.position.z) &&
           isFinite(state.target.x) && isFinite(state.target.y) && isFinite(state.target.z) &&
           isFinite(state.fov) && isFinite(state.near) && isFinite(state.far);
  }

  /**
   * Phase 2B: 线性插值两个三维向量。
   * @param {object} a 起点向量 {x,y,z}
   * @param {object} b 终点向量 {x,y,z}
   * @param {number} t 插值因子 [0,1]
   * @returns {{x: number, y: number, z: number}}
   * @private
   */
  _lerpVec3(a, b, t) {
    return {
      x: a.x + (b.x - a.x) * t,
      y: a.y + (b.y - a.y) * t,
      z: a.z + (b.z - a.z) * t
    };
  }

  /**
   * Phase 2A-2: 构造 CameraState 对象。
   *
   * Final Acceptance Fix: 增加 minDistance / maxDistance / modelBoundingRadius / lastClipUpdateReason
   *
   * @returns {object} CameraState
   * @private
   */
  _buildCameraState() {
    var pos = this.camera.position;
    var target = this.controls.target;
    var dx = pos.x - target.x;
    var dy = pos.y - target.y;
    var dz = pos.z - target.z;
    var distance = Math.sqrt(dx * dx + dy * dy + dz * dz);
    return {
      position: { x: pos.x, y: pos.y, z: pos.z },
      target: { x: target.x, y: target.y, z: target.z },
      fov: this.camera.fov,
      near: this.camera.near,
      far: this.camera.far,
      aspect: this.camera.aspect,
      distance: distance,
      controlsEnabled: !!this.controls.enabled,
      lastAction: this.lastAction,
      // Final Acceptance Fix: 裁剪相关 Debug 字段
      minDistance: this.controls.minDistance,
      maxDistance: this.controls.maxDistance,
      modelBoundingRadius: this.lastModelBoundingRadius,
      lastClipUpdateReason: this.lastClipUpdateReason
    };
  }

  dispose() {
    if (this._disposed) return;
    this._disposed = true;
    // Phase 2B: 取消正在运行的过渡,标记为 DISPOSED
    if (this.transitionState === CameraTransitionState.RUNNING) {
      this.transitionState = CameraTransitionState.DISPOSED;
      this.transitionCancelReason = CANCEL_REASON_DISPOSE;
      this.transitionCompletedAt = Date.now();
    } else {
      this.transitionState = CameraTransitionState.DISPOSED;
    }
    // 移除 OrbitControls start 事件监听器
    if (this.controls && this._controlsStartHandler) {
      try {
        this.controls.removeEventListener('start', this._controlsStartHandler);
      } catch (e) { /* ignore */ }
    }
    this._controlsStartHandler = null;
    // Final Acceptance Fix: 移除 OrbitControls change 事件监听器
    if (this.controls && this._controlsChangeHandler) {
      try {
        this.controls.removeEventListener('change', this._controlsChangeHandler);
      } catch (e) { /* ignore */ }
    }
    this._controlsChangeHandler = null;
    // 清空过渡状态引用
    this.transitionStartState = null;
    this.transitionTargetState = null;
    if (this.controls) {
      try { this.controls.dispose(); } catch (e) { /* ignore */ }
      this.controls = null;
    }
    this.camera = null;
  }
}
