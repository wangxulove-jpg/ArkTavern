/**
 * ViewerCore — Web Viewer 总控制器
 *
 * 职责:
 *   - 状态机(UNINITIALIZED / INITIALIZING / READY / FAILED / DISPOSING / DISPOSED)
 *   - Scene 初始化
 *   - Camera 初始化
 *   - Model Loader 初始化 + 默认 VRM 加载(Phase 1C-2)
 *   - Frame Loop 初始化(包含 modelLoader.update)
 *   - 调用 Bridge 通知 ArkTS(onViewerReady / onViewerError / onModelStateChanged)
 *   - 错误处理(模型失败不阻塞 Viewer)
 *   - 销毁(先模型后 Scene)
 *
 * 防止:
 *   - 重复 initialize
 *   - 重复 Frame Loop
 *   - 重复 dispose
 *   - dispose 后继续 render
 *   - 异步初始化完成后修改已销毁对象(通过 _initToken)
 *   - 异步模型加载完成后写入已销毁对象(通过 loadGeneration)
 *
 * Reference:
 *   - figure-main/index.html initThree() + animate(): 初始化与渲染循环编排
 *   - figure-main/index.html loadVRM(): 模型加载与挂载
 *   - figure-main/index.html disposeVrm(): 资源释放思路
 *   - figure-main/index.html resize handler: camera.aspect + updateProjectionMatrix + renderer.setSize
 *   - ownverse-vrm-viewer/analysis/VIEWER_ARCHITECTURE.md: 状态机设计参考
 *
 * 与 Figure 的差异:
 *   - Figure 在 IIFE 中同步初始化,本实现拆分为异步 initialize(便于错误处理与状态机)
 *   - Figure 不显式管理状态机,本实现引入显式状态机(Viewer + Model 双状态机)
 *   - Figure 不 dispose renderer,本实现补充完整 dispose 链路
 *   - Figure 仅监听 window resize,本实现补充 ResizeObserver(更精确响应容器尺寸变化)
 *   - Figure 在 loadVRM 中先移除旧模型再添加新模型;本实现采用原子替换(先加载成功再替换)
 *
 * Phase 1C-2 范围:
 *   - 加载默认 VRM(./assets/models/default.vrm)
 *   - 模型挂载到 Scene,移除测试方块
 *   - 每帧 currentVrm.update(deltaSeconds)
 *   - 模型失败时保留测试方块,Viewer 仍为 READY
 *   - 不实现动画系统 / 文件选择器 / 自动取景
 */
import { ViewerScene } from './ViewerScene.js';
import { ViewerCamera } from './ViewerCamera.js';
import { ViewerFrameLoop } from './ViewerFrameLoop.js';
import { ViewerModelLoader, ModelState } from './ViewerModelLoader.js';
import { ViewerAnimationController, AnimationState } from './ViewerAnimationController.js';
import { ViewerPoseController, PoseState } from './ViewerPoseController.js';
import { ViewerExpressionController, ExpressionState } from './ViewerExpressionController.js';

// ===== 状态枚举 =====
var STATE_UNINITIALIZED = 'UNINITIALIZED';
var STATE_INITIALIZING = 'INITIALIZING';
var STATE_READY = 'READY';
var STATE_FAILED = 'FAILED';
var STATE_DISPOSING = 'DISPOSING';
var STATE_DISPOSED = 'DISPOSED';

// ===== 错误代码(与 AGENTS.md Phase 1B 要求一致) =====
export var ERR_THREE_IMPORT_FAILED = 'THREE_IMPORT_FAILED';
export var ERR_WEBGL_NOT_SUPPORTED = 'WEBGL_NOT_SUPPORTED';
export var ERR_SCENE_INITIALIZATION_FAILED = 'SCENE_INITIALIZATION_FAILED';
export var ERR_CAMERA_INITIALIZATION_FAILED = 'CAMERA_INITIALIZATION_FAILED';
export var ERR_RENDER_LOOP_FAILED = 'RENDER_LOOP_FAILED';
export var ERR_VIEWER_ALREADY_DISPOSED = 'VIEWER_ALREADY_DISPOSED';
/** Phase 2A-1: Viewer 未就绪(状态机非 READY) */
export var ERR_VIEWER_NOT_READY = 'VIEWER_NOT_READY';

/**
 * 构造错误对象。
 * @param {string} code
 * @param {string} message
 * @param {string} phase
 * @param {boolean} recoverable
 * @returns {{code: string, message: string, phase: string, recoverable: boolean}}
 */
function makeError(code, message, phase, recoverable) {
  return {
    code: code,
    message: message,
    phase: phase,
    recoverable: !!recoverable
  };
}

export class ViewerCore {
  constructor() {
    /** @type {string} */
    this._state = STATE_UNINITIALIZED;
    /** @type {ViewerScene|null} */
    this.scene = null;
    /** @type {ViewerCamera|null} */
    this.camera = null;
    /** @type {ViewerFrameLoop|null} */
    this.frameLoop = null;
    /** @type {ViewerModelLoader|null} */
    this.modelLoader = null;
    /** @type {ViewerAnimationController|null} Phase 3A: 动画运行时控制器 */
    this.animationController = null;
    /** @type {ViewerPoseController|null} Phase 3D-2: 静态姿势控制器 */
    this.poseController = null;
    /** @type {ViewerExpressionController|null} Phase 3E-1: 表情控制器 */
    this.expressionController = null;
    /** @type {HTMLElement|null} */
    this._container = null;
    /** @type {ResizeObserver|null} */
    this._resizeObserver = null;
    /** @type {function} */
    this._boundWindowResize = this._onWindowResize.bind(this);
    /** 防止异步初始化完成后修改已销毁对象 */
    this._initToken = 0;
    /** 上一帧 resize 的尺寸,避免重复无意义 resize */
    this._lastResizeWidth = 0;
    this._lastResizeHeight = 0;
    /** Phase 2A-2: 模型替换后自动取景的最近一次警告(供 loadUserModelResource 读取) */
    this._lastCameraFocusWarning = null;
  }

  /**
   * 初始化 Viewer。
   *
   * 顺序:
   *   1. 校验状态(防止重复 initialize)
   *   2. 创建 ViewerScene,initialize(container)
   *   3. 创建 ViewerCamera,initialize(renderer.domElement)
   *   4. 创建 ViewerFrameLoop,注册 updateCallback
   *   5. 启动 Frame Loop
   *   6. 设置 Resize 监听
   *   7. 状态推进到 READY,通知 ArkTS
   *
   * @param {HTMLElement} container
   * @returns {Promise<{success: boolean, state?: string, error?: object}>}
   */
  async initialize(container) {
    // 防止重复 initialize
    if (this._state === STATE_DISPOSED) {
      return { success: false, error: makeError(ERR_VIEWER_ALREADY_DISPOSED, 'Viewer already disposed', this._state, false) };
    }
    if (this._state === STATE_INITIALIZING) {
      return { success: false, error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'initialize already in progress', this._state, true) };
    }
    if (this._state === STATE_READY) {
      return { success: true, state: this._state };
    }

    this._state = STATE_INITIALIZING;
    this._initToken++;
    var token = this._initToken;

    try {
      // ===== Scene =====
      this.scene = new ViewerScene();
      await this.scene.initialize(container);

      // 检查是否在异步过程中被销毁或重新初始化
      if (token !== this._initToken) {
        return { success: false, error: makeError(ERR_VIEWER_ALREADY_DISPOSED, 'Viewer disposed during initialization', STATE_DISPOSING, false) };
      }
      // Phase 1D-2C-2A: 记录 VIEWER_SCENE_READY
      this._emitStartupDiagnostic('VIEWER_SCENE_READY', '', 'ViewerScene initialized');

      // ===== Camera =====
      this.camera = new ViewerCamera();
      this.camera.initialize(this.scene.getRenderer().domElement);

      if (token !== this._initToken) {
        return { success: false, error: makeError(ERR_VIEWER_ALREADY_DISPOSED, 'Viewer disposed during initialization', STATE_DISPOSING, false) };
      }
      // Phase 1D-2C-2A: 记录 VIEWER_CAMERA_READY
      this._emitStartupDiagnostic('VIEWER_CAMERA_READY', '', 'ViewerCamera initialized');

      // ===== Frame Loop =====
      this.frameLoop = new ViewerFrameLoop();
      this._container = container;
      this._setupResizeListeners();

      // ===== Model Loader =====
      // 创建 ModelLoader,注入状态变化与错误回调
      // 回调顺序:ModelLoader 状态变化 → ViewerCore 处理 Scene 挂载/相机重置 → 通知 ArkTS
      // Phase 1D-2B-2:新增 onReplaceModel 回调,由 ViewerCore 同步完成 Scene 替换,
      // 确保 currentVrm 提交前新模型已挂载、旧模型已从 Scene 移除(原子替换)。
      // Phase 1D-2C-1:新增 onDiagnostic 回调,转发到 arkTavernVrmRuntimeDiagnostics keeper。
      this.modelLoader = new ViewerModelLoader({
        onStateChanged: (state, detail) => {
          this._onModelStateChanged(state, detail);
        },
        onError: (err) => {
          this._notifyError(err);
        },
        onReplaceModel: (nextVrm, previousVrm) => {
          this._replaceModelInScene(nextVrm, previousVrm);
        },
        onDiagnostic: (diagnostic) => {
          this._forwardModelLoaderDiagnostic(diagnostic);
        }
      });
      this.modelLoader.initialize();
      // Phase 1D-2C-2A: 记录 VIEWER_MODEL_LOADER_READY
      this._emitStartupDiagnostic('VIEWER_MODEL_LOADER_READY', '', 'ViewerModelLoader initialized');

      // ===== Phase 3A: Animation Controller =====
      // 创建动画控制器,注入 getCurrentVrm 回调(由 ModelLoader 提供)
      // 动画控制器独立于 ModelLoader,仅持有 AnimationMixer / currentAction / currentClip
      // 不阻塞 Viewer READY,失败仅记录,不改 ViewerState / ModelState
      this.animationController = new ViewerAnimationController({
        getCurrentVrm: () => {
          return this.modelLoader ? this.modelLoader.getCurrentVrm() : null;
        }
      });
      this.animationController.initialize();
      this._emitStartupDiagnostic('VIEWER_ANIMATION_CONTROLLER_READY', '', 'ViewerAnimationController initialized');

      // ===== Phase 3D-2: Pose Controller =====
      // 创建静态姿势控制器,注入 getCurrentVrm 回调(由 ModelLoader 提供)
      // 姿势控制器独立于 ModelLoader / AnimationController,
      // 仅持有 currentVrm / currentPoseId / 状态计数。
      // 不阻塞 Viewer READY,失败仅记录,不改 ViewerState / ModelState / AnimationState。
      // 不做姿势动画过渡 / CrossFade / 骨骼插值 (本阶段范围外)。
      this.poseController = new ViewerPoseController({
        getCurrentVrm: () => {
          return this.modelLoader ? this.modelLoader.getCurrentVrm() : null;
        }
      });
      this.poseController.initialize();
      this._emitStartupDiagnostic('VIEWER_POSE_CONTROLLER_READY', '', 'ViewerPoseController initialized');

      // ===== Phase 3E-1: Expression Controller =====
      // 创建表情控制器,注入 getCurrentVrm 回调(由 ModelLoader 提供)
      // 表情控制器独立于 ModelLoader / AnimationController / PoseController,
      // 仅持有 currentVrm / currentExpressionName / currentExpressionWeight / 状态枚举。
      // 不阻塞 Viewer READY,失败仅记录,不改 ViewerState / ModelState / AnimationState / PoseState。
      // 不做 AI 自动选择表情 / 语音口型同步 / Blink 自动眨眼 / 多表情混合 (本阶段范围外)。
      this.expressionController = new ViewerExpressionController({
        getCurrentVrm: () => {
          return this.modelLoader ? this.modelLoader.getCurrentVrm() : null;
        }
      });
      this.expressionController.initialize();
      this._emitStartupDiagnostic('VIEWER_EXPRESSION_CONTROLLER_READY', '', 'ViewerExpressionController initialized');

      // 启动渲染循环
      // 顺序(与 Figure animate() 行 2860-2906 一致,Phase 3A 新增 animationController.update):
      //   FRAME_START → deltaSeconds
      //   → modelLoader.update(delta) [vrm.update]      ← VRM 变换先规范化
      //   → animationController.update(delta) [mixer.update]  ← 动画后应用
      //   → camera.update(delta)                         ← OrbitControls 更新
      //   → scene.render(camera)                         ← 最终渲染
      //   FRAME_END
      // 更新顺序依据:Figure index.html:2876-2880 vrm.update → mixer.update,
      //   three-vrm 3.x 的 humanoid.update() 需在 mixer.update() 之前执行。
      // ANIMATION_UPDATE_ORDER: VRM_FIRST_THEN_MIXER
      this.frameLoop.start((deltaSeconds) => {
        if (this.modelLoader) {
          this.modelLoader.update(deltaSeconds);
        }
        if (this.animationController) {
          this.animationController.update(deltaSeconds);
        }
        this.camera.update(deltaSeconds);
        this.scene.render(this.camera.getCamera());
      });
      // Phase 1D-2C-2A: 记录 VIEWER_FRAME_LOOP_READY
      this._emitStartupDiagnostic('VIEWER_FRAME_LOOP_READY', '', 'ViewerFrameLoop started');

      if (token !== this._initToken) {
        return { success: false, error: makeError(ERR_VIEWER_ALREADY_DISPOSED, 'Viewer disposed during initialization', STATE_DISPOSING, false) };
      }

      // Viewer READY(模型仍为 NOT_LOADED,异步加载中)
      this._state = STATE_READY;
      this._notifyReady();

      // 异步加载默认 VRM(不阻塞 Viewer READY 状态)
      // Figure: DOMContentLoaded → loadVRM(VRM_MODEL_URL, 'default.vrm')
      // 失败时 Viewer 仍为 READY,Model 为 FAILED,保留测试方块
      this.modelLoader.loadDefault().catch((e) => {
        console.warn('[ViewerCore] loadDefault failed:', e);
      });

      return { success: true, state: this._state };
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      var code = (e && e.code) || ERR_SCENE_INITIALIZATION_FAILED;
      // WebGL 不支持 / Three.js import 失败的特定映射
      if (code === ERR_WEBGL_NOT_SUPPORTED) {
        // 已在 ViewerScene 中标记
      } else if (code === ERR_CAMERA_INITIALIZATION_FAILED) {
        // 已在 ViewerCamera 中标记
      } else if (/WebGL/i.test(msg) || /context/i.test(msg)) {
        code = ERR_WEBGL_NOT_SUPPORTED;
      } else if (/import/i.test(msg) || /module/i.test(msg)) {
        code = ERR_THREE_IMPORT_FAILED;
      }
      this._state = STATE_FAILED;
      var err = makeError(code, msg, STATE_INITIALIZING, false);
      this._notifyError(err);
      // 清理已分配的资源
      this._cleanupAfterFailure();
      return { success: false, error: err };
    }
  }

  /**
   * Phase 2A-2: 重置相机到 Figure 基准位置。
   *
   * Figure 基准: FOV=30, position=(0,1.25,2), target=(0,1.25,0)
   *
   * Final Acceptance Fix: near/far 不再固定 0.1/20,reset 后调用 updateCameraClipping
   * 根据当前模型 bounds 和默认距离计算,避免拉远时模型被 far plane 裁掉。
   *
   * preserveControlsEnabled 保持控制面板触摸隔离状态。
   *
   * @returns {{success: boolean, state?: object, error?: object}}
   */
  resetCamera() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.camera) {
      return {
        success: false,
        error: makeError(ERR_CAMERA_INITIALIZATION_FAILED, 'Camera not initialized', this._state, true)
      };
    }
    // Final Acceptance Fix: 计算当前模型 bounds 传给 reset
    var modelBounds = null;
    if (this.modelLoader) {
      var currentVrm = this.modelLoader.getCurrentVrm();
      if (currentVrm && currentVrm.scene) {
        var bounds = this.camera.computeModelBounds(currentVrm.scene);
        if (bounds.valid) {
          modelBounds = { radius: bounds.radius };
        }
      }
    }
    var result = this.camera.reset({
      preserveControlsEnabled: true,
      modelBounds: modelBounds
    });
    return result;
  }

  /**
   * Phase 2A-2: 聚焦到当前已加载模型。
   *
   * 从 ViewerModelLoader.currentVrm 获取真实模型对象,
   * 调用 ViewerCamera.focusOnObject 计算包围盒并调整相机。
   *
   * 自动取景失败不得让模型加载失败:返回 cameraFocusWarning 但 success 仍为 true。
   *
   * @param {object} [options] 传递给 focusOnObject 的选项
   * @returns {{success: boolean, state?: object, bounds?: object, error?: object}}
   */
  focusCameraOnCurrentModel(options) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.camera) {
      return {
        success: false,
        error: makeError(ERR_CAMERA_INITIALIZATION_FAILED, 'Camera not initialized', this._state, true)
      };
    }
    if (!this.modelLoader) {
      return {
        success: false,
        error: makeError('MODEL_LOADER_NOT_INITIALIZED', 'ModelLoader not initialized', this._state, false)
      };
    }
    var currentVrm = this.modelLoader.getCurrentVrm();
    if (!currentVrm || !currentVrm.scene) {
      return {
        success: false,
        error: makeError('CAMERA_FOCUS_MODEL_NOT_LOADED', 'No current VRM loaded', this._state, false)
      };
    }
    var result = this.camera.focusOnObject(currentVrm.scene, options || {});
    return result;
  }

  /**
   * Phase 2A-2: 获取当前 Camera 状态。
   *
   * @returns {{success: boolean, state?: object, error?: object}}
   */
  getCameraState() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.camera) {
      return {
        success: false,
        error: makeError(ERR_CAMERA_INITIALIZATION_FAILED, 'Camera not initialized', this._state, true)
      };
    }
    return this.camera.getCameraState();
  }

  // ===== Phase 2B: 平滑重置 =====

  /**
   * Phase 2B: 平滑重置相机到 Figure 基准位置。
   *
   * 同步启动过渡,由现有帧循环(ViewerCamera.update)异步驱动完成。
   * 不创建第二个 requestAnimationFrame。
   *
   * 终点固定为 Figure 基准(与 resetCamera() 完全一致):
   *   FOV=30, near=0.1, far=20, position=(0,1.25,2), target=(0,1.25,0)
   *
   * 起点为当前真实相机状态。缓动:smootherStep(本地纯函数)。
   *
   * @param {object} [options]
   * @param {number} [options.durationSeconds=0.45] 过渡时长(0.1~2.0 秒)
   * @param {boolean} [options.preserveControlsEnabled=true] 是否保持 controls.enabled
   * @returns {{success: boolean, state?: string, transition?: object, error?: object}}
   */
  smoothResetCamera(options) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.camera) {
      return {
        success: false,
        error: makeError(ERR_CAMERA_INITIALIZATION_FAILED, 'Camera not initialized', this._state, true)
      };
    }
    return this.camera.smoothReset(options);
  }

  /**
   * Phase 2B: 获取当前相机过渡状态。
   *
   * @returns {{success: boolean, transition?: object}}
   */
  getCameraTransitionState() {
    if (!this.camera) {
      return {
        success: false,
        transition: {
          state: 'IDLE',
          progress: 0,
          durationSeconds: 0,
          elapsedSeconds: 0,
          cancelReason: '',
          errorCode: '',
          errorMessage: '',
          startedAt: 0,
          completedAt: 0
        }
      };
    }
    return { success: true, transition: this.camera.getTransitionState() };
  }

  /**
   * Phase 2B: 取消当前平滑相机过渡。
   *
   * 取消后保留取消瞬间的相机位置,不跳到终点,不恢复起点。
   *
   * @param {string} reason 取消原因
   * @returns {{success: boolean, cancelled?: boolean, transition?: object}}
   */
  cancelCameraTransition(reason) {
    if (!this.camera) {
      return { success: false };
    }
    this.camera.cancelTransition(reason);
    return { success: true, transition: this.camera.getTransitionState() };
  }

  /**
   * 调整 Viewer 尺寸。
   *
   * 统一处理三种触发源:
   *   - ResizeObserver(容器尺寸变化)
   *   - window resize(兜底)
   *   - ArkTS resizeViewer(width, height)
   *
   * 防止:
   *   - width <= 0 / height <= 0
   *   - 重复无意义 resize(相同尺寸跳过)
   *   - 页面已销毁后 resize
   *
   * @param {number} [width] 未提供时从 container 读取
   * @param {number} [height] 未提供时从 container 读取
   */
  resize(width, height) {
    if (this._state !== STATE_READY) return;
    if (!this._container || !this.scene || !this.camera) return;

    if (width === undefined || height === undefined) {
      width = this._container.clientWidth;
      height = this._container.clientHeight;
    }
    if (width <= 0 || height <= 0) return;
    // 避免重复无意义 resize
    if (width === this._lastResizeWidth && height === this._lastResizeHeight) return;
    this._lastResizeWidth = width;
    this._lastResizeHeight = height;

    // Figure resize handler:
    //   camera.aspect = w/h; camera.updateProjectionMatrix()
    //   renderer.setSize(w, h)
    this.camera.resize(width, height);
    this.scene.resize(width, height);
  }

  /** @returns {string} */
  getState() {
    return this._state;
  }

  /**
   * 获取场景状态(供 Bridge getSceneState 使用)。
   *
   * Phase 2A-1 扩展:
   * - 增加 modelSource 字段(USER / DEFAULT / NONE)
   * - 增加 modelLoaded 字段(基于 currentVrm != null)
   * - 增加 backgroundColor / gridVisible / lightIntensity / cameraControlsEnabled 字段
   * - sceneReady / cameraReady / frameLoopRunning 重命名为 threeLoaded / sceneInitialized /
   *   cameraInitialized / frameLoopRunning(保留旧字段供向后兼容)
   *
   * Phase 3A 扩展:
   * - animationState 字段从硬编码 'NOT_INITIALIZED' 改为读取 animationController.getState()
   * - 新增 animationVrmBound / animationMixerReady 字段供 Debug 使用
   *
   * @returns {object}
   */
  getSceneState() {
    var modelState = this.modelLoader ? this.modelLoader.getState() : ModelState.NOT_LOADED;
    var modelDisplayName = this.modelLoader ? this.modelLoader.getDisplayName() : '';
    var modelError = this.modelLoader && this.modelLoader.getLastError()
      ? this.modelLoader.getLastError().message : '';

    // Phase 2A-1: modelSource 推导
    // - 默认 VRM:displayName === 'Default VRM' 且 currentVrm 非空 → DEFAULT
    // - 用户模型:currentVrm 非空且 displayName !== 'Default VRM' → USER
    // - 无模型:currentVrm 为 null → NONE
    var currentVrm = this.modelLoader ? this.modelLoader.getCurrentVrm() : null;
    var modelLoaded = !!currentVrm;
    var modelSource = 'NONE';
    if (modelLoaded) {
      if (modelDisplayName === 'Default VRM') {
        modelSource = 'DEFAULT';
      } else {
        modelSource = 'USER';
      }
    }

    // Phase 2A-1: Scene 设置与 Camera Controls 状态
    var sceneSettings = this.scene ? this.scene.getSettings() : null;
    var cameraControls = this.camera ? this.camera.getControlsEnabled() : { success: false, error: 'CAMERA_NOT_INITIALIZED' };

    // Phase 3A: 动画状态(从 animationController 读取,未初始化时为 UNINITIALIZED)
    var animationState = this.animationController
      ? this.animationController.getState()
      : AnimationState.UNINITIALIZED;
    var animationVrmBound = this.animationController
      ? !!this.animationController.currentVrm
      : false;
    var animationMixerReady = this.animationController
      ? !!this.animationController.mixer
      : false;

    return {
      viewerState: this._state,
      // Phase 2A-1: 模型状态扩展
      modelState: modelState,
      modelLoaded: modelLoaded,
      modelDisplayName: modelDisplayName,
      modelSource: modelSource,
      modelError: modelError,
      // Phase 3A: 动画状态扩展(替换原硬编码 'NOT_INITIALIZED')
      animationState: animationState,
      animationVrmBound: animationVrmBound,
      animationMixerReady: animationMixerReady,
      humanoidState: 'NOT_INITIALIZED',
      springBoneState: 'NOT_INITIALIZED',
      // Phase 2A-1: Scene 与 Camera 状态扩展
      threeLoaded: !!this.scene,
      sceneInitialized: !!this.scene,
      cameraInitialized: !!this.camera,
      frameLoopRunning: !!(this.frameLoop && this.frameLoop.isRunning()),
      backgroundColor: sceneSettings ? sceneSettings.backgroundColor : '#222222',
      gridVisible: sceneSettings ? sceneSettings.gridVisible : false,
      lightIntensity: sceneSettings ? sceneSettings.lightIntensity : 3.0,
      cameraControlsEnabled: cameraControls.success ? !!cameraControls.enabled : false,
      // 保留旧字段供向后兼容
      sceneReady: !!this.scene,
      cameraReady: !!this.camera,
      phase: 'PHASE_3A'
    };
  }

  // ===== Phase 3A: Animation System =====

  /**
   * Phase 3A: 初始化动画系统。
   *
   * 在 ViewerCore.initialize 中已自动调用,此方法用于:
   *   - 幂等查询:返回当前动画系统状态
   *   - 失败后重试(若 animationController 处于 FAILED)
   *
   * 不阻塞 Viewer READY。
   * 动画系统失败不改 ViewerState / ModelState。
   *
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  initializeAnimationSystem() {
    if (!this.animationController) {
      // 创建并初始化(仅在 initialize 未自动完成时使用)
      this.animationController = new ViewerAnimationController({
        getCurrentVrm: () => {
          return this.modelLoader ? this.modelLoader.getCurrentVrm() : null;
        }
      });
    }
    var result = this.animationController.initialize();
    return result;
  }

  /**
   * Phase 3A: 获取动画系统状态(只读)。
   *
   * @returns {{success: boolean, state?: string}}
   */
  getAnimationState() {
    if (!this.animationController) {
      return { success: true, state: AnimationState.UNINITIALIZED };
    }
    return { success: true, state: this.animationController.getState() };
  }

  /**
   * Phase 3A: 获取动画系统调试状态快照(只读)。
   *
   * 供 Bridge getAnimationDebugState 使用,字段与 ArkWebAnimationDebugState 对齐。
   *
   * @returns {{success: boolean, debugState?: object}}
   */
  getAnimationDebugState() {
    if (!this.animationController) {
      return {
        success: true,
        debugState: {
          state: AnimationState.UNINITIALIZED,
          vrmBound: false,
          mixerReady: false,
          clipReady: false,
          actionReady: false,
          animationName: '',
          duration: 0,
          currentTime: 0,
          playbackSpeed: 1,
          loop: true,
          errorCode: '',
          errorMessage: ''
        }
      };
    }
    return { success: true, debugState: this.animationController.getDebugState() };
  }

  /**
   * Phase 3A 依赖补齐: 获取动画系统依赖状态(只读)。
   *
   * 供 Bridge getAnimationDependencyState 使用,返回 three-vrm-animation 依赖可用性。
   * 不暴露 Node 模块路径、本机绝对路径、完整 package.json、许可证全文。
   *
   * @returns {{success: boolean, dependencyState?: object}}
   */
  getAnimationDependencyState() {
    if (!this.animationController) {
      return {
        success: true,
        dependencyState: {
          available: false,
          packageName: '@pixiv/three-vrm-animation',
          version: '',
          loaderAvailable: false,
          clipFactoryAvailable: false,
          runtimeNetworkRequired: true
        }
      };
    }
    return { success: true, dependencyState: this.animationController.getDependencyState() };
  }

  // ===== Phase 3A — VRMA 文件导入与最小播放闭环 =====

  /**
   * Phase 3A: 加载 VRMA 动画资源 (规范 §二十九)。
   *
   * 同步返回加载启动结果,异步结果通过 getAnimationState() / getAnimationDebugState() 查询。
   * 不通过 Bridge 返回 Promise。
   *
   * 动画加载失败不得改变 ViewerState / ModelState / CameraState / SceneState。
   *
   * @param {object} resource
   *   {resourceUrl, resourceId, displayName, mimeType, size}
   * @returns {{success: boolean, state?: string, generation?: number, error?: {code: string, message: string}}}
   */
  loadAnimationResource(resource) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: { code: 'VIEWER_NOT_READY', message: 'Viewer not ready (state=' + this._state + ')' }
      };
    }
    if (!this.animationController) {
      return {
        success: false,
        error: { code: 'ANIMATION_NOT_INITIALIZED', message: 'AnimationController not initialized' }
      };
    }
    if (!this.modelLoader || !this.modelLoader.currentVrm) {
      return {
        success: false,
        error: { code: 'ANIMATION_VRM_MISSING', message: 'currentVrm is null (model not loaded)' }
      };
    }
    try {
      var result = this.animationController.loadVrmaResource(resource);
      return result;
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      return {
        success: false,
        error: { code: 'ANIMATION_LOAD_FAILED', message: 'loadVrmaResource threw: ' + msg }
      };
    }
  }

  /**
   * Phase 3A: 播放动画 (规范 §二十九)。
   *
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  playAnimation() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: { code: 'VIEWER_NOT_READY', message: 'Viewer not ready (state=' + this._state + ')' }
      };
    }
    if (!this.animationController) {
      return {
        success: false,
        error: { code: 'ANIMATION_NOT_INITIALIZED', message: 'AnimationController not initialized' }
      };
    }
    return this.animationController.play();
  }

  /**
   * Phase 3A: 暂停动画 (规范 §二十九)。
   *
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  pauseAnimation() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: { code: 'VIEWER_NOT_READY', message: 'Viewer not ready (state=' + this._state + ')' }
      };
    }
    if (!this.animationController) {
      return {
        success: false,
        error: { code: 'ANIMATION_NOT_INITIALIZED', message: 'AnimationController not initialized' }
      };
    }
    return this.animationController.pause();
  }

  /**
   * Phase 3A: 停止动画 (规范 §二十九)。
   *
   * @param {object} [options] {resetPose?: boolean} 默认 resetPose=true
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  stopAnimation(options) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: { code: 'VIEWER_NOT_READY', message: 'Viewer not ready (state=' + this._state + ')' }
      };
    }
    if (!this.animationController) {
      return {
        success: false,
        error: { code: 'ANIMATION_NOT_INITIALIZED', message: 'AnimationController not initialized' }
      };
    }
    return this.animationController.stop(options);
  }

  // ===== Phase 3D-2: Pose System (静态姿势应用与恢复) =====

  /**
   * Phase 3D-2: 应用静态姿势到当前 VRM Humanoid normalized bones。
   *
   * 执行顺序 (与 ViewerPoseController.applyPose 一致):
   *   1. 前置条件检查 (未 dispose / currentVrm / humanoid / poseData 合法)
   *   2. resetNormalizedPose()
   *   3. 遍历有效骨骼,设置 quaternion + normalize + updateMatrix
   *   4. 记录 currentPoseId
   *   5. state = APPLIED
   *
   * 应用前会先调用 stopAnimation(),确保动画不再覆盖骨骼旋转。
   * 应用失败不影响 ViewerState / ModelState / AnimationState。
   *
   * 同一姿势可以重复应用。
   * 应用新姿势时直接替换旧姿势 (先 resetNormalizedPose 再应用),不叠加旧骨骼旋转。
   *
   * 未知骨骼策略: 忽略 + warning (不让整个姿势失败)
   * 非法 rotation 策略: 拒绝该骨骼 (跳过),记录 warning
   *
   * @param {object} poseData 姿势数据对象
   *   { poseId, displayName, bones | humanBones | pose }
   * @returns {{success: boolean, state?: string, poseId?: string, displayName?: string, appliedBoneCount?: number, ignoredBoneCount?: number, error?: {code: string, message: string}}}
   */
  applyPose(poseData) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: { code: 'VIEWER_NOT_READY', message: 'Viewer not ready (state=' + this._state + ')' }
      };
    }
    if (!this.poseController) {
      return {
        success: false,
        error: { code: 'POSE_NOT_INITIALIZED', message: 'PoseController not initialized' }
      };
    }
    // Phase 3D-2: 应用静态姿势前先停止当前动画,避免动画覆盖骨骼旋转
    // - stopAnimation 失败仅记录,不阻塞姿势应用
    // - stopAnimation 使用默认 resetPose=true,会调用 resetNormalizedPose
    //   (applyPose 内部会再次 resetNormalizedPose,确保骨骼从 rest pose 开始)
    if (this.animationController) {
      try {
        var animState = this.animationController.getState();
        if (animState === 'PLAYING' || animState === 'PAUSED' || animState === 'READY') {
          var stopResult = this.animationController.stop({ resetPose: true });
          if (!stopResult.success) {
            console.warn('[ViewerCore] stopAnimation before applyPose failed: ' +
              (stopResult.error ? stopResult.error.code + ' ' + stopResult.error.message : 'unknown'));
          }
        }
      } catch (e) {
        console.warn('[ViewerCore] stopAnimation before applyPose threw: ' + (e && e.message ? e.message : String(e)));
      }
    }
    return this.poseController.applyPose(poseData);
  }

  /**
   * Phase 3D-2: 恢复 VRM Humanoid 到 normalized rest pose。
   *
   * 执行:
   *   currentVrm.humanoid.resetNormalizedPose()
   *   currentPoseId = ''
   *   state = IDLE
   *
   * 恢复失败不影响 ViewerState / ModelState / AnimationState。
   *
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  resetPose() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: { code: 'VIEWER_NOT_READY', message: 'Viewer not ready (state=' + this._state + ')' }
      };
    }
    if (!this.poseController) {
      return {
        success: false,
        error: { code: 'POSE_NOT_INITIALIZED', message: 'PoseController not initialized' }
      };
    }
    return this.poseController.resetPose();
  }

  /**
   * Phase 3D-2: 获取姿势系统状态(只读)。
   *
   * @returns {{success: boolean, state?: string, poseId?: string, displayName?: string, appliedBoneCount?: number, ignoredBoneCount?: number}}
   */
  getPoseState() {
    if (!this.poseController) {
      return {
        success: true,
        state: PoseState.IDLE,
        poseId: '',
        displayName: '',
        appliedBoneCount: 0,
        ignoredBoneCount: 0
      };
    }
    return this.poseController.getPoseState();
  }

  /**
   * Phase 3D-2: 获取姿势系统调试状态快照(只读)。
   *
   * 供 Bridge getPoseDebugState 使用,字段与 ArkWebPoseDebugState 对齐。
   *
   * @returns {{success: boolean, debugState?: object}}
   */
  getPoseDebugState() {
    if (!this.poseController) {
      return {
        success: true,
        debugState: {
          state: PoseState.IDLE,
          vrmBound: false,
          currentPoseId: '',
          currentDisplayName: '',
          appliedBoneCount: 0,
          ignoredBoneCount: 0,
          lastIgnoredBones: [],
          lastErrorCode: '',
          lastErrorMessage: ''
        }
      };
    }
    return this.poseController.getPoseDebugState();
  }

  // ===== Phase 3E-1 — VRM 表情系统 =====

  /**
   * Phase 3E-1: 获取当前 VRM 真实可用 Expression 列表。
   *
   * 模型未 READY 时返回 EXPRESSION_VRM_MISSING。
   * 不得假定所有模型都支持 happy/angry/sad/relaxed/surprised/neutral。
   *
   * @returns {{success: boolean, expressions?: Array<{name:string,weight:number,isPreset:boolean}>, error?: {code: string, message: string}}}
   */
  getAvailableExpressions() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: { code: 'VIEWER_NOT_READY', message: 'Viewer not ready (state=' + this._state + ')' }
      };
    }
    if (!this.expressionController) {
      return {
        success: false,
        error: { code: 'EXPRESSION_NOT_INITIALIZED', message: 'ExpressionController not initialized' }
      };
    }
    // 检查 VRM 是否已绑定 (expressionManagerReady 隐含 VRM 已绑定且 manager 存在)
    if (!this.expressionController.expressionManagerReady) {
      return {
        success: false,
        error: { code: 'EXPRESSION_VRM_MISSING', message: 'VRM not bound or expressionManager missing' }
      };
    }
    return {
      success: true,
      expressions: this.expressionController.getAvailableExpressions()
    };
  }

  /**
   * Phase 3E-1: 设置单个业务表情权重。
   *
   * 表情错误不得改变 ViewerState / ModelState / AnimationState / PoseState。
   *
   * @param {string} name 表情名 (必须真实存在于 expressionManager)
   * @param {number} weight 权重 (0~1)
   * @returns {{success: boolean, state?: string, name?: string, weight?: number, error?: {code: string, message: string}}}
   */
  setExpression(name, weight) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: { code: 'VIEWER_NOT_READY', message: 'Viewer not ready (state=' + this._state + ')' }
      };
    }
    if (!this.expressionController) {
      return {
        success: false,
        error: { code: 'EXPRESSION_NOT_INITIALIZED', message: 'ExpressionController not initialized' }
      };
    }
    return this.expressionController.setExpression(name, weight);
  }

  /**
   * Phase 3E-1: 清除业务表情,恢复 neutral。
   *
   * 不强制把 neutral 设置为 1。
   * 保留口型通道 aa/ee/ih/oh/ou。
   * 表情错误不得改变 ViewerState / ModelState / AnimationState / PoseState。
   *
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  resetExpression() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: { code: 'VIEWER_NOT_READY', message: 'Viewer not ready (state=' + this._state + ')' }
      };
    }
    if (!this.expressionController) {
      return {
        success: false,
        error: { code: 'EXPRESSION_NOT_INITIALIZED', message: 'ExpressionController not initialized' }
      };
    }
    return this.expressionController.resetExpression();
  }

  /**
   * Phase 3E-1: 获取表情系统状态 (只读)。
   *
   * @returns {{success: boolean, state?: string, currentExpressionName?: string, currentExpressionWeight?: number, expressionManagerReady?: boolean}}
   */
  getExpressionState() {
    if (!this.expressionController) {
      return {
        success: true,
        state: ExpressionState.UNBOUND,
        currentExpressionName: '',
        currentExpressionWeight: 0,
        expressionManagerReady: false
      };
    }
    return this.expressionController.getExpressionState();
  }

  /**
   * Phase 3E-1: 获取表情系统调试状态快照 (只读)。
   *
   * 供 Bridge getExpressionDebugState 使用,字段与 ArkWebExpressionDebugState 对齐。
   *
   * @returns {{success: boolean, debugState?: object}}
   */
  getExpressionDebugState() {
    if (!this.expressionController) {
      return {
        success: true,
        debugState: {
          state: ExpressionState.UNBOUND,
          vrmBound: false,
          expressionManagerReady: false,
          availableExpressionCount: 0,
          currentExpressionName: '',
          currentExpressionWeight: 0,
          lastErrorCode: '',
          lastErrorMessage: '',
          lipSyncChannelsPreserved: true
        }
      };
    }
    return this.expressionController.getExpressionDebugState();
  }

  // ===== Phase 3E-2: 临时表情与别名 =====

  /**
   * Phase 3E-2: 设置临时表情。
   *
   * 委托给 ViewerExpressionController.setTemporaryExpression。
   * 模型未 READY 返回 EXPRESSION_VRM_MISSING。
   *
   * @param {string} name 模型真实 expressionName
   * @param {number} weight 0~1
   * @param {number} durationMs 100..30000
   * @param {string} restorePolicy PREVIOUS | RESET
   * @returns {{success: boolean, state?: ExpressionState, temporaryExpressionName?: string, temporaryExpressionWeight?: number, expiresAt?: number, error?: object}}
   */
  setTemporaryExpression(name, weight, durationMs, restorePolicy) {
    if (!this.expressionController) {
      return {
        success: false,
        error: { code: 'EXPRESSION_VRM_MISSING', message: 'expressionController not initialized' }
      };
    }
    if (!this.expressionController.expressionManagerReady) {
      return {
        success: false,
        error: { code: 'EXPRESSION_VRM_MISSING', message: 'expressionManager not ready' }
      };
    }
    return this.expressionController.setTemporaryExpression(name, weight, durationMs, restorePolicy);
  }

  /**
   * Phase 3E-2: 取消临时表情。
   */
  cancelTemporaryExpression() {
    if (!this.expressionController) {
      return { success: true, state: ExpressionState.UNBOUND };
    }
    return this.expressionController.cancelTemporaryExpression();
  }

  /**
   * Phase 3E-2: 获取临时表情状态。
   */
  getTemporaryExpressionState() {
    if (!this.expressionController) {
      return {
        success: true,
        temporaryExpressionName: '',
        temporaryExpressionWeight: 0,
        temporaryExpiresAt: 0,
        temporaryRestorePolicy: 'PREVIOUS',
        restoreExpressionName: '',
        restoreExpressionWeight: 0,
        temporaryGeneration: 0
      };
    }
    return this.expressionController.getTemporaryExpressionState();
  }

  /**
   * Phase 3E-2: 通过业务 expressionId 设置表情 (使用持久化别名映射)。
   *
   * @param {string} expressionId 业务 ID
   * @param {object} aliases 持久化映射 { expressionId: expressionName }
   * @param {number} weight 0~1
   */
  setExpressionByAlias(expressionId, aliases, weight) {
    if (!this.expressionController) {
      return {
        success: false,
        error: { code: 'EXPRESSION_VRM_MISSING', message: 'expressionController not initialized' }
      };
    }
    if (!this.expressionController.expressionManagerReady) {
      return {
        success: false,
        error: { code: 'EXPRESSION_VRM_MISSING', message: 'expressionManager not ready' }
      };
    }
    return this.expressionController.setExpressionByAlias(expressionId, aliases, weight);
  }

  /**
   * Phase 3E-2: 通过业务 expressionId 设置临时表情。
   */
  setTemporaryExpressionByAlias(expressionId, aliases, weight, durationMs, restorePolicy) {
    if (!this.expressionController) {
      return {
        success: false,
        error: { code: 'EXPRESSION_VRM_MISSING', message: 'expressionController not initialized' }
      };
    }
    if (!this.expressionController.expressionManagerReady) {
      return {
        success: false,
        error: { code: 'EXPRESSION_VRM_MISSING', message: 'expressionManager not ready' }
      };
    }
    return this.expressionController.setTemporaryExpressionByAlias(expressionId, aliases, weight, durationMs, restorePolicy);
  }

  /**
   * Phase 3E-2: 解析业务 expressionId 到模型真实 expressionName。
   * @returns {{success: boolean, expressionName?: string|null, error?: object}}
   */
  resolveExpressionAlias(expressionId, aliases) {
    if (!this.expressionController) {
      return {
        success: false,
        error: { code: 'EXPRESSION_VRM_MISSING', message: 'expressionController not initialized' }
      };
    }
    if (!this.expressionController.expressionManagerReady) {
      return {
        success: false,
        error: { code: 'EXPRESSION_VRM_MISSING', message: 'expressionManager not ready' }
      };
    }
    var resolved = this.expressionController.resolveExpressionAlias(expressionId, aliases);
    if (resolved === null) {
      return {
        success: false,
        error: { code: 'EXPRESSION_ALIAS_NOT_RESOLVED', message: 'cannot resolve expressionId: ' + expressionId }
      };
    }
    return { success: true, expressionName: resolved };
  }

  // ===== Phase 2A-1: Camera Controls enable/disable =====

  /**
   * Phase 2A-1: 启用/禁用 OrbitControls。
   *
   * 用于控制面板触摸隔离。Viewer 不为 READY 时返回 VIEWER_NOT_READY。
   *
   * @param {boolean} enabled
   * @returns {{success: boolean, enabled?: boolean, error?: {code: string, message: string}}}
   */
  setCameraControlsEnabled(enabled) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (typeof enabled !== 'boolean') {
      return {
        success: false,
        error: makeError('INVALID_ARGUMENT', 'enabled must be a boolean', this._state, false)
      };
    }
    if (!this.camera) {
      return {
        success: false,
        error: makeError(ERR_CAMERA_INITIALIZATION_FAILED, 'Camera not initialized', this._state, false)
      };
    }
    return this.camera.setControlsEnabled(enabled);
  }

  /**
   * Phase 2A-1: 查询 OrbitControls 当前启用状态。
   *
   * @returns {{success: boolean, enabled?: boolean, error?: {code: string, message: string}}}
   */
  getCameraControlsEnabled() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.camera) {
      return {
        success: false,
        error: makeError(ERR_CAMERA_INITIALIZATION_FAILED, 'Camera not initialized', this._state, false)
      };
    }
    return this.camera.getControlsEnabled();
  }

  // ===== Phase 2A-1: Scene 设置 =====

  /**
   * Phase 2A-1: 设置场景背景颜色。
   *
   * @param {string} color #RRGGBB 格式
   * @returns {{success: boolean, color?: string, error?: {code: string, message: string}}}
   */
  setSceneBackgroundColor(color) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    return this.scene.setBackgroundColor(color);
  }

  /**
   * Phase 2A-1: 设置网格显示。
   *
   * @param {boolean} visible
   * @returns {{success: boolean, visible?: boolean, error?: {code: string, message: string}}}
   */
  setSceneGridVisible(visible) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    return this.scene.setGridVisible(visible);
  }

  /**
   * Phase 2A-1: 设置主方向光强度。
   *
   * @param {number} intensity 0.0 ~ 4.0
   * @returns {{success: boolean, intensity?: number, error?: {code: string, message: string}}}
   */
  setSceneLightIntensity(intensity) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    return this.scene.setLightIntensity(intensity);
  }

  /**
   * Phase 2A-1: 获取场景设置(背景颜色 / 网格 / 灯光)。
   *
   * @returns {{success: boolean, settings?: object, error?: {code: string, message: string}}}
   */
  getSceneSettings() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    return this.scene.getSettings();
  }

  // ===== Phase 4B-1: Runtime 渲染 Profile =====

  /**
   * Phase 4B-1: 设置渲染 Profile (VIEWER / CHAT_STAGE)。
   *
   * 委托给 ViewerScene.setRenderProfile,同时:
   *   - CHAT_STAGE: 禁用相机控制(模型不响应拖拽/缩放,聊天手势优先)
   *   - VIEWER: 恢复相机控制到上次状态
   *
   * 不修改三个业务 Runtime Controller。
   *
   * @param {string} profile 'VIEWER' | 'CHAT_STAGE'
   * @returns {{success: boolean, profile?: string, error?: {code: string, message: string}}}
   */
  setRenderProfile(profile) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    var result = this.scene.setRenderProfile(profile);
    if (!result.success) {
      return {
        success: false,
        error: makeError(result.error || 'RENDER_PROFILE_FAILED',
          'setRenderProfile failed: ' + (result.error || 'unknown'), this._state, false)
      };
    }
    // CHAT_STAGE: 禁用相机控制(聊天手势优先,模型不响应拖拽/缩放)
    // VIEWER: 恢复相机控制(enabled=true,与历史行为一致)
    if (this.camera) {
      if (profile === 'CHAT_STAGE') {
        this.camera.setControlsEnabled(false);
      } else {
        this.camera.setControlsEnabled(true);
      }
    }
    return { success: true, profile: result.profile };
  }

  /**
   * Phase 4B-1: 获取当前渲染 Profile。
   *
   * @returns {{success: boolean, profile?: string, error?: {code: string, message: string}}}
   */
  getRenderProfile() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    return this.scene.getRenderProfile();
  }

  /**
   * Phase 4B-1: 聊天页面默认全身构图。
   *
   * 基于当前模型 BoundingBox / BoundingSphere / 相机 FOV / 视口宽高,
   * 调整相机 position / target / distance,使模型全身可见:
   *   - 头顶保留少量安全区(margin=1.15)
   *   - 脚部保持可见
   *   - 尽量完整显示身体
   *   - 模型不超出左右边界
   *
   * 禁止:
   *   - 修改 VRM scene scale
   *   - 修改 VRM scene position
   *
   * 允许:
   *   - camera position / target / distance
   *
   * 复用 ViewerCamera.focusOnObject,仅传入全身构图专用选项:
   *   - margin: 1.15 (头顶安全区 + 脚部可见余量)
   *   - preserveDirection: false (使用默认正前方 (0,0,1) 方向,确保正面构图)
   *   - preserveControlsEnabled: true (保持 CHAT_STAGE 下 controls.enabled=false)
   *
   * @returns {{success: boolean, state?: object, bounds?: object, error?: {code: string, message: string}}}
   */
  fitAvatarFullBody(fillRatio) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.camera) {
      return {
        success: false,
        error: makeError(ERR_CAMERA_INITIALIZATION_FAILED, 'Camera not initialized', this._state, true)
      };
    }
    if (!this.modelLoader) {
      return {
        success: false,
        error: makeError('MODEL_LOADER_NOT_INITIALIZED', 'ModelLoader not initialized', this._state, false)
      };
    }
    var currentVrm = this.modelLoader.getCurrentVrm();
    if (!currentVrm || !currentVrm.scene) {
      return {
        success: false,
        error: makeError('CAMERA_FOCUS_MODEL_NOT_LOADED', 'No current VRM loaded', this._state, false)
      };
    }
    // 全身构图:margin=1.15 提供头顶安全区 + 脚部可见余量,
    // preserveDirection=false 强制正面构图(避免从侧面/斜角看模型),
    // preserveControlsEnabled=true 保持 CHAT_STAGE 下 controls.enabled=false。
    //
    // Phase 4B-2R: 支持可选 fillRatio (0 < fillRatio < 1) 控制模型垂直占比。
    //   - 不传或非法 → margin=1.15 (原行为,向后兼容)
    //   - fillRatio=0.78 → margin=1/0.78 ≈ 1.282 (模型变小,占垂直约 78%)
    // 禁止修改 model.scene.position/scale, 仅调整相机。
    var margin = 1.15;
    if (typeof fillRatio === 'number' && isFinite(fillRatio) && fillRatio > 0 && fillRatio < 1) {
      margin = 1.0 / fillRatio;
    }
    var result = this.camera.focusOnObject(currentVrm.scene, {
      action: 'FIT_FULL_BODY',
      margin: margin,
      preserveDirection: false,
      preserveControlsEnabled: true
    });
    return result;
  }

  /**
   * Phase 4B-2R2: 应用相机缩放倍率。
   *
   * 通过缩短相机到目标点距离实现视觉放大, 不修改 model.scene.position / scale / 骨骼。
   *
   * 倍率范围 0.5 ~ 3.0:
   *   - 1.0: 无变化
   *   - 2.0: 相机距离缩短至 1/2, 模型视觉放大 2 倍
   *   - 3.0: 相机距离缩短至 1/3, 模型视觉放大 3 倍
   *
   * @param {number} multiplier 缩放倍率
   * @returns {{success: boolean, state?: object, multiplier?: number, error?: {code: string, message: string}}}
   */
  applyCameraZoomMultiplier(multiplier) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.camera) {
      return {
        success: false,
        error: makeError(ERR_CAMERA_INITIALIZATION_FAILED, 'Camera not initialized', this._state, true)
      };
    }
    var result = this.camera.applyCameraZoomMultiplier(multiplier);
    if (result && result.success) {
      return { success: true, state: result.state, multiplier: result.multiplier };
    }
    return {
      success: false,
      error: {
        code: 'ZOOM_MULTIPLIER_FAILED',
        message: result && result.error ? String(result.error) : 'applyCameraZoomMultiplier failed'
      }
    };
  }

  // ===== Phase 2F: 环境贴图 API =====

  /**
   * Phase 2F: 初始化环境贴图。
   *
   * 使用程序化 RoomEnvironment 生成 PMREM 环境纹理。
   * 同步执行,由 ViewerScene.initializeEnvironment 完成。
   *
   * 初始化失败:
   *   - 保留现有纯色背景和灯光
   *   - 不影响 ViewerState(仍为 READY)
   *
   * @returns {{success: boolean, state?: string, settings?: object, error?: object}}
   */
  initializeEnvironment() {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    var result = this.scene.initializeEnvironment();
    if (result && result.success) {
      var settingsResult = this.scene.getEnvironmentSettings();
      return {
        success: true,
        state: result.state,
        settings: settingsResult.settings
      };
    }
    return result;
  }

  /**
   * Phase 2F: 启用/禁用环境光照。
   *
   * @param {boolean} enabled
   * @returns {{success: boolean, enabled?: boolean, settings?: object, error?: object}}
   */
  setEnvironmentEnabled(enabled) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    var result = this.scene.setEnvironmentEnabled(enabled);
    if (result && result.success) {
      var settingsResult = this.scene.getEnvironmentSettings();
      return {
        success: true,
        enabled: result.enabled,
        settings: settingsResult.settings
      };
    }
    return result;
  }

  /**
   * Phase 2F: 显示/隐藏天空盒。
   *
   * @param {boolean} visible
   * @returns {{success: boolean, visible?: boolean, settings?: object, error?: object}}
   */
  setSkyboxVisible(visible) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    var result = this.scene.setSkyboxVisible(visible);
    if (result && result.success) {
      var settingsResult = this.scene.getEnvironmentSettings();
      return {
        success: true,
        visible: result.visible,
        settings: settingsResult.settings
      };
    }
    return result;
  }

  /**
   * Phase 2F: 设置环境强度。
   *
   * @param {number} intensity 0.0 ~ 2.0
   * @returns {{success: boolean, intensity?: number, settings?: object, error?: object}}
   */
  setEnvironmentIntensity(intensity) {
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError(ERR_VIEWER_NOT_READY, 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: makeError(ERR_SCENE_INITIALIZATION_FAILED, 'Scene not initialized', this._state, false)
      };
    }
    var result = this.scene.setEnvironmentIntensity(intensity);
    if (result && result.success) {
      var settingsResult = this.scene.getEnvironmentSettings();
      return {
        success: true,
        intensity: result.intensity,
        settings: settingsResult.settings
      };
    }
    return result;
  }

  /**
   * Phase 2F: 获取环境设置快照。
   *
   * @returns {{success: boolean, settings?: object, error?: object}}
   */
  getEnvironmentSettings() {
    if (!this.scene) {
      return {
        success: false,
        settings: {
          state: 'UNINITIALIZED',
          source: 'NONE',
          environmentEnabled: false,
          skyboxVisible: false,
          environmentIntensity: 1.0,
          backgroundColor: '#222222',
          errorCode: '',
          errorMessage: ''
        }
      };
    }
    return this.scene.getEnvironmentSettings();
  }

  /**
   * 销毁 Viewer,释放所有资源。
   *
   * 顺序(AGENTS.md Phase 1C-2 §十九,Phase 3A 补充 animationController):
   *   1. 状态推进到 DISPOSING
   *   2. 使进行中的 initialize 失效(_initToken++)
   *   3. 移除 ResizeObserver / window resize listener
   *   4. 停止 Frame Loop
   *   5. dispose AnimationController(释放 AnimationMixer,不销毁 VRM)
   *   6. dispose ModelLoader(释放当前 VRM:Geometry / Material / Texture)
   *   7. dispose Camera(OrbitControls)
   *   8. dispose Scene(Renderer / 测试方块 / 灯光 / Canvas)
   *   9. 清空引用
   *  10. 状态推进到 DISPOSED
   *
   * 必须先 dispose AnimationController,再 dispose ModelLoader:
   *   AnimationMixer.uncacheRoot 需要 vrm.scene 仍可访问,
   *   而 ModelLoader.dispose 会释放 vrm.scene 资源。
   *
   * 必须先 dispose ModelLoader,再 dispose Scene:
   *   模型的 Geometry / Material / Texture 需要遍历 vrm.scene 释放,
   *   若先销毁 Scene 会导致 vrm.scene 被清空,无法正确遍历。
   */
  dispose() {
    if (this._state === STATE_DISPOSED) return;
    this._state = STATE_DISPOSING;
    this._initToken++; // 使进行中的 initialize 失效

    this._teardownResizeListeners();

    if (this.frameLoop) {
      this.frameLoop.dispose();
      this.frameLoop = null;
    }
    // Phase 3A: 先 dispose AnimationController(释放 Mixer,不销毁 VRM)
    if (this.animationController) {
      this.animationController.dispose();
      this.animationController = null;
    }
    // 必须先 dispose ModelLoader,再 dispose Scene
    // (ModelLoader 需要遍历 vrm.scene 释放资源,Scene 不能先被清空)
    if (this.modelLoader) {
      this.modelLoader.dispose();
      this.modelLoader = null;
    }
    if (this.camera) {
      this.camera.dispose();
      this.camera = null;
    }
    if (this.scene) {
      this.scene.dispose();
      this.scene = null;
    }

    this._container = null;
    this._state = STATE_DISPOSED;
  }

  // ===== 内部方法 =====

  _setupResizeListeners() {
    if (!this._container) return;
    // ResizeObserver:监听容器尺寸变化(比 window resize 更精确)
    if (typeof ResizeObserver !== 'undefined') {
      this._resizeObserver = new ResizeObserver(() => {
        this.resize();
      });
      this._resizeObserver.observe(this._container);
    }
    // Figure: window.addEventListener('resize', ...)
    // 作为兜底,防止 ResizeObserver 不可用或不触发
    window.addEventListener('resize', this._boundWindowResize);
  }

  _teardownResizeListeners() {
    if (this._resizeObserver) {
      try { this._resizeObserver.disconnect(); } catch (e) { /* ignore */ }
      this._resizeObserver = null;
    }
    window.removeEventListener('resize', this._boundWindowResize);
  }

  _onWindowResize() {
    this.resize();
  }

  _cleanupAfterFailure() {
    if (this.frameLoop) {
      this.frameLoop.dispose();
      this.frameLoop = null;
    }
    // Phase 3A: 失败时也清理 AnimationController
    if (this.animationController) {
      this.animationController.dispose();
      this.animationController = null;
    }
    if (this.modelLoader) {
      this.modelLoader.dispose();
      this.modelLoader = null;
    }
    if (this.camera) {
      this.camera.dispose();
      this.camera = null;
    }
    if (this.scene) {
      this.scene.dispose();
      this.scene = null;
    }
    this._container = null;
  }

  /**
   * ModelLoader 状态变化回调。
   *
   * Phase 1D-2B-2 起职责调整:
   * - LOADING:仅通知 ArkTS
   * - READY:Scene 替换已由 onReplaceModel 同步完成,此处仅做相机重置 + 通知 ArkTS
   *   Phase 3A:同时调用 animationController.bindVrm(currentVrm)
   * - FAILED:保留当前显示(旧模型或测试方块),通知 ArkTS(Viewer 仍为 READY,仅 Model FAILED)
   * - DISPOSED:不处理(由 dispose 流程触发)
   *
   * @param {string} state ModelState 枚举值
   * @param {string} [detail] 详细描述
   */
  _onModelStateChanged(state, detail) {
    if (this._state !== STATE_READY) return;

    if (state === ModelState.READY) {
      // Phase 2A-2: 模型替换成功后自动取景(MODEL_REPLACED_FOCUS)
      // - 自动取景失败不得让模型加载失败:只记录警告,不回滚模型
      // - 默认模型首次加载时也走此路径(若当前代码已这样做的源码证据:Phase 1B 即如此)
      var cameraFocusWarning = null;
      if (this.camera && this.modelLoader) {
        var currentVrm = this.modelLoader.getCurrentVrm();
        if (currentVrm && currentVrm.scene) {
          var focusResult = this.camera.focusOnObject(currentVrm.scene, {
            action: 'MODEL_REPLACED_FOCUS',
            preserveControlsEnabled: true
          });
          if (!focusResult.success) {
            // 自动取景失败:记录警告,不回滚模型,相机保持原状态
            cameraFocusWarning = {
              success: false,
              errorCode: focusResult.error || 'UNKNOWN',
              errorMessage: 'Auto focus after model replace failed'
            };
          } else {
            cameraFocusWarning = {
              success: true,
              errorCode: '',
              errorMessage: ''
            };
          }
        }
      }
      // 保存最近的 cameraFocusWarning 供 loadUserModelResource 读取
      this._lastCameraFocusWarning = cameraFocusWarning;

      // Phase 3A: 模型 READY 后绑定 VRM 到动画控制器
      // - 绑定失败仅记录,不改 ModelState / ViewerState
      // - 绑定后 state = IDLE (无 clip,不进入 READY/PLAYING)
      if (this.animationController && this.modelLoader) {
        var vrmToBind = this.modelLoader.getCurrentVrm();
        if (vrmToBind) {
          try {
            var bindResult = this.animationController.bindVrm(vrmToBind);
            if (!bindResult.success) {
              console.warn('[ViewerCore] animationController.bindVrm failed: ' +
                (bindResult.error ? bindResult.error.code + ' ' + bindResult.error.message : 'unknown'));
            }
          } catch (e) {
            console.warn('[ViewerCore] animationController.bindVrm threw: ' + (e && e.message ? e.message : String(e)));
          }
        }
      }

      // Phase 3D-2: 模型 READY 后绑定 VRM 到姿势控制器
      // - 绑定失败仅记录,不改 ModelState / ViewerState / AnimationState
      // - 不自动应用旧姿势 (Phase 3D-2 不实现启动后自动应用)
      // - 模型替换时清除姿势状态由 _replaceModelInScene 调用 unbindVrm 完成
      if (this.poseController && this.modelLoader) {
        var vrmForPose = this.modelLoader.getCurrentVrm();
        if (vrmForPose) {
          try {
            var poseBindResult = this.poseController.bindVrm(vrmForPose);
            if (!poseBindResult.success) {
              console.warn('[ViewerCore] poseController.bindVrm failed: ' +
                (poseBindResult.error ? poseBindResult.error.code + ' ' + poseBindResult.error.message : 'unknown'));
            }
          } catch (e) {
            console.warn('[ViewerCore] poseController.bindVrm threw: ' + (e && e.message ? e.message : String(e)));
          }
        }
      }

      // Phase 3E-1: 模型 READY 后绑定 VRM 到表情控制器
      // - 绑定失败仅记录,不改 ModelState / ViewerState / AnimationState / PoseState
      // - 不自动设置任何表情 (bindVrm 仅枚举可用 Expression 列表)
      // - 模型替换时清除表情状态由 _replaceModelInScene 调用 unbindVrm 完成
      // - 不跨模型缓存 Expression 实例
      if (this.expressionController && this.modelLoader) {
        var vrmForExpression = this.modelLoader.getCurrentVrm();
        if (vrmForExpression) {
          try {
            var expBindResult = this.expressionController.bindVrm(vrmForExpression);
            if (!expBindResult.success) {
              console.warn('[ViewerCore] expressionController.bindVrm failed: ' +
                (expBindResult.error ? expBindResult.error.code + ' ' + expBindResult.error.message : 'unknown'));
            }
          } catch (e) {
            console.warn('[ViewerCore] expressionController.bindVrm threw: ' + (e && e.message ? e.message : String(e)));
          }
        }
      }

      // 通知 ArkTS 模型状态变化
      if (window.ViewerBridge && typeof window.ViewerBridge.notifyModelStateChanged === 'function') {
        window.ViewerBridge.notifyModelStateChanged(state);
      }
    } else if (state === ModelState.FAILED) {
      // 模型加载失败:保留当前显示(旧模型或测试方块),通知 ArkTS
      // Viewer 仍为 READY,仅 Model FAILED
      if (window.ViewerBridge && typeof window.ViewerBridge.notifyModelStateChanged === 'function') {
        window.ViewerBridge.notifyModelStateChanged(state);
      }
    } else if (state === ModelState.LOADING || state === ModelState.NOT_LOADED) {
      // 加载中 / 未加载:仅通知 ArkTS
      if (window.ViewerBridge && typeof window.ViewerBridge.notifyModelStateChanged === 'function') {
        window.ViewerBridge.notifyModelStateChanged(state);
      }
    }
    // DISPOSED 状态不通知(由 dispose 流程触发)
  }

  /**
   * 同步完成 Scene 中的模型替换(Phase 1D-2B-2 新增)。
   *
   * 由 ViewerModelLoader.loadModel 在新模型完整准备后、currentVrm 提交前调用,
   * 确保两次 render 之间不会同时出现两个模型。
   *
   * 步骤(AGENTS.md Phase 1D-2B-2 §十四):
   * 1. scene.addModel(nextVrm.scene) — 新模型加入 Scene
   * 2. if (previousVrm) scene.removeModel(previousVrm.scene) — 旧模型从 Scene 移除
   * 3. scene.removeTestObject() — 移除测试方块(若存在)
   *
   * Phase 3A 补充:
   * - 在 Scene 替换前,若存在旧 VRM,先调用 animationController.unbindVrm()
   *   释放旧 AnimationMixer(避免 mixer 引用已被移除的 scene root)
   * - 新 VRM 的 bindVrm 由 _onModelStateChanged(READY) 处理
   *
   * 抛异常时 ViewerModelLoader 会释放新模型,旧模型保留。
   *
   * @param {object} nextVrm 新加载的 VRM 根对象
   * @param {object|null} previousVrm 旧 VRM 根对象(首次加载时为 null)
   */
  _replaceModelInScene(nextVrm, previousVrm) {
    if (!this.scene) {
      throw new Error('Scene not available');
    }
    if (!nextVrm || !nextVrm.scene) {
      throw new Error('nextVrm.scene is empty');
    }
    // Phase 3A: 替换前先解绑旧 VRM(释放旧 AnimationMixer)
    // - 首次加载时 previousVrm 为 null,animationController.currentVrm 也为 null,unbindVrm 是安全的
    // - 解绑失败仅记录,不阻塞 Scene 替换
    if (this.animationController && previousVrm) {
      try {
        this.animationController.unbindVrm();
      } catch (e) {
        console.warn('[ViewerCore] animationController.unbindVrm threw: ' + (e && e.message ? e.message : String(e)));
      }
    }
    // Phase 3D-2: 替换前先解绑旧 VRM 的姿势状态
    // - 清除 currentPoseId / state=IDLE / 计数归零
    // - 不自动重新应用旧姿势 (新模型由 _onModelStateChanged 重新 bindVrm,但不应用)
    // - 不把旧模型的骨骼节点保存给新模型使用
    if (this.poseController && previousVrm) {
      try {
        this.poseController.unbindVrm();
      } catch (e) {
        console.warn('[ViewerCore] poseController.unbindVrm threw: ' + (e && e.message ? e.message : String(e)));
      }
    }
    // Phase 3E-1: 替换前先解绑旧 VRM 的表情状态
    // - 清除 currentExpressionName / currentExpressionWeight / state=UNBOUND
    // - 不保存旧 Expression 实例 (不跨模型缓存)
    // - 新模型由 _onModelStateChanged 重新 bindVrm, 但不自动设置任何表情
    if (this.expressionController && previousVrm) {
      try {
        this.expressionController.unbindVrm();
      } catch (e) {
        console.warn('[ViewerCore] expressionController.unbindVrm threw: ' + (e && e.message ? e.message : String(e)));
      }
    }
    // 1. 新模型加入 Scene
    this.scene.addModel(nextVrm.scene);
    // 2. 旧模型从 Scene 移除(若存在)
    if (previousVrm && previousVrm.scene) {
      this.scene.removeModel(previousVrm.scene);
    }
    // 3. 移除测试方块(让出 Scene 给真实 VRM)
    this.scene.removeTestObject();
  }

  /**
   * 加载用户模型(Phase 1D-2B-2 新增)。
   *
   * 由 ViewerUserModelLoadCoordinator.start 调用,加载受控 URL 的用户模型。
   *
   * 验证:
   * - ViewerState === READY
   * - modelLoader 已初始化
   * - resource.resourceUrl 是受控资源 URL(https://ark-tavern.local/model/<opaque-id>)
   * - resource.displayName 非空
   *
   * 不得接受 ArkTS 直接传入的任意 URL。
   * 不使用 fetch / ArrayBuffer / Blob / Base64。
   * 模型二进制只能由 GLTFLoader 通过受控 URL 获取。
   *
   * @param {object} resource 已准备的资源对象
   *   必需字段:resourceUrl / displayName / mimeType / size / extension / gltfDependencyState
   * @returns {Promise<{success: boolean, error?: object, state?: string}>}
   */
  async loadUserModelResource(resource) {
    // 1. Viewer 状态检查
    if (this._state !== STATE_READY) {
      return {
        success: false,
        error: makeError('VIEWER_NOT_READY', 'Viewer state is ' + this._state + ', expected READY', this._state, true)
      };
    }
    // 2. modelLoader 初始化检查
    if (!this.modelLoader) {
      return {
        success: false,
        error: makeError('MODEL_LOADER_NOT_INITIALIZED', 'ModelLoader not initialized', this._state, false)
      };
    }
    // 3. resource 存在性检查
    if (!resource || typeof resource !== 'object') {
      return {
        success: false,
        error: makeError('INVALID_RESOURCE', 'resource is null or not an object', this._state, true)
      };
    }
    // 4. resourceUrl 受控 URL 检查
    if (typeof resource.resourceUrl !== 'string' || resource.resourceUrl.length === 0) {
      return {
        success: false,
        error: makeError('INVALID_RESOURCE', 'resourceUrl missing or empty', this._state, true)
      };
    }
    var CONTROLLED_URL_PREFIX = 'https://ark-tavern.local/model/';
    if (resource.resourceUrl.indexOf(CONTROLLED_URL_PREFIX) !== 0) {
      return {
        success: false,
        error: makeError('INVALID_RESOURCE',
          'resourceUrl is not a controlled URL (must start with ' + CONTROLLED_URL_PREFIX + ')',
          this._state, false)
      };
    }
    // 5. displayName 非空检查
    if (typeof resource.displayName !== 'string' || resource.displayName.length === 0) {
      return {
        success: false,
        error: makeError('INVALID_RESOURCE', 'displayName missing or empty', this._state, true)
      };
    }

    // 6. 委托 modelLoader.loadModel 执行 GLTFLoader 加载
    //    ViewerModelLoader 内部会通过 onReplaceModel 同步完成 Scene 替换,
    //    并在成功后提交 currentVrm / displayName,失败时保留旧模型。
    //    Phase 2A-2: 模型 READY 后 _onModelStateChanged 会自动取景,
    //    此处将 _lastCameraFocusWarning 附加到返回结果。
    this._lastCameraFocusWarning = null;
    try {
      var result = await this.modelLoader.loadModel(resource.resourceUrl, resource.displayName);
      // Phase 2A-2: 附加 cameraFocusWarning(成功或失败都附加,不改变 success)
      if (result && result.success) {
        result.cameraFocus = this._lastCameraFocusWarning || { success: true, errorCode: '', errorMessage: '' };
      }
      return result;
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      return {
        success: false,
        error: makeError('MODEL_LOAD_FAILED', msg, this._state, true)
      };
    }
  }

  /**
   * 通知 ArkTS:Viewer 已就绪。
   * 通过 window.ViewerBridge.notifyViewerReady → window.arkTavernNative.onViewerReady
   *
   * Phase 1D-2C-2A: 同时记录 VIEWER_READY 启动诊断。
   */
  _notifyReady() {
    // Phase 1D-2C-2A: 记录 VIEWER_READY 启动诊断
    this._emitStartupDiagnostic('VIEWER_READY', '', 'ViewerCore entered READY state');
    if (window.ViewerBridge && typeof window.ViewerBridge.notifyViewerReady === 'function') {
      window.ViewerBridge.notifyViewerReady();
    }
  }

  /**
   * 通知 ArkTS:Viewer 发生错误。
   * 通过 window.ViewerBridge.notifyViewerError → window.arkTavernNative.onViewerError
   * @param {{code: string, message: string, phase: string, recoverable: boolean}} err
   *
   * Phase 1D-2C-2A: 同时记录 VIEWER_INITIALIZE_FAILED 启动诊断,保留底层 err.code。
   */
  _notifyError(err) {
    // Phase 1D-2C-2A: 记录 VIEWER_INITIALIZE_FAILED 启动诊断(保留底层错误码)
    var errCode = (err && err.code) ? err.code : 'UNKNOWN';
    var errMsg = (err && err.message) ? err.message : 'Unknown error';
    this._emitStartupDiagnostic('VIEWER_INITIALIZE_FAILED', errCode, errMsg);
    if (window.ViewerBridge && typeof window.ViewerBridge.notifyViewerError === 'function') {
      window.ViewerBridge.notifyViewerError(err.code, err.message, err.phase, err.recoverable);
    }
  }

  /**
   * Phase 1D-2C-2A: 记录启动诊断(内部方法)。
   *
   * 委托 window.arkTavernVrmRuntimeDiagnostics keeper(ViewerBridge.js 注册)。
   * 与 _forwardModelLoaderDiagnostic 不同,本方法用于 ViewerCore 自身的启动阶段
   * (VIEWER_SCENE_READY / VIEWER_CAMERA_READY / VIEWER_MODEL_LOADER_READY /
   *  VIEWER_FRAME_LOOP_READY / VIEWER_READY / VIEWER_INITIALIZE_FAILED)。
   *
   * 安全约束:不记录 cachePath / sourceUri / fd / stack / 用户目录。
   *
   * @param {string} stage 启动阶段字符串(与 VrmRuntimeStage 枚举对齐)
   * @param {string} code 错误码(成功阶段为空字符串)
   * @param {string} message 简短消息(已截断为 256 字符)
   */
  _emitStartupDiagnostic(stage, code, message) {
    var keeper = window.arkTavernVrmRuntimeDiagnostics;
    if (!keeper || typeof keeper.record !== 'function') {
      return;
    }
    var msg = String(message || '');
    if (msg.length > 256) {
      msg = msg.substring(0, 256);
    }
    var diagnostic = {
      stage: stage,
      code: code || '',
      message: msg,
      resourceId: '',
      requestMethod: '',
      httpStatus: 0,
      mimeType: '',
      contentLength: 0,
      timestamp: Date.now()
    };
    try {
      keeper.record(diagnostic);
    } catch (e) {
      console.warn('[ViewerCore] startup diagnostic record failed: ' + (e && e.message ? e.message : String(e)));
    }
  }

  /**
   * Phase 1D-2C-1: 转发 ModelLoader 诊断到 arkTavernVrmRuntimeDiagnostics keeper。
   *
   * app.js 会在 window.arkTavernVrmRuntimeDiagnostics 上注册 record(diagnostic) 方法。
   * ViewerCore 不解析诊断内容,只做转发。诊断对象格式由 ViewerModelLoader 保证。
   *
   * 安全约束:
   * - diagnostic 不含 cachePath / sourceUri / fd / stack(由 ViewerModelLoader 保证)
   * - 转发失败仅日志,不影响加载主流程
   *
   * @param {object} diagnostic 诊断对象
   */
  _forwardModelLoaderDiagnostic(diagnostic) {
    var keeper = window.arkTavernVrmRuntimeDiagnostics;
    if (!keeper || typeof keeper.record !== 'function') {
      // keeper 未注册,仅日志(不影响加载)
      return;
    }
    try {
      keeper.record(diagnostic);
    } catch (e) {
      console.warn('[ViewerCore] forward model loader diagnostic failed: ' + (e && e.message ? e.message : String(e)));
    }
  }
}
