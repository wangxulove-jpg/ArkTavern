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

export class ViewerCamera {
  constructor() {
    /** @type {THREE.PerspectiveCamera|null} */
    this.camera = null;
    /** @type {OrbitControls|null} */
    this.controls = null;
    this._disposed = false;
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
  }

  /**
   * 每帧更新。
   * Figure: animate() 中调用 controls.update()
   * @param {number} deltaSeconds 自上一帧以来的秒数(本阶段未使用,保留接口供后续 damping/动画)
   */
  update(deltaSeconds) {
    if (this._disposed || !this.controls) return;
    this.controls.update();
  }

  /**
   * 调整 Camera aspect。
   * Figure resize handler: camera.aspect = w/h; camera.updateProjectionMatrix()
   * @param {number} width
   * @param {number} height
   */
  resize(width, height) {
    if (this._disposed || !this.camera) return;
    if (width <= 0 || height <= 0) return;
    this.camera.aspect = width / height;
    this.camera.updateProjectionMatrix();
  }

  /**
   * 重置相机到默认位置与目标点。
   * 本阶段仅实现 immediate reset。
   * Phase 2B 将实现 smoothResetCamera(duration) 平滑过渡。
   * @param {boolean} [immediate=true] 是否立即重置(本阶段忽略,始终立即)
   */
  reset(immediate) {
    if (this._disposed || !this.camera || !this.controls) return;
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
    // 立即更新,避免渲染一帧旧视角
    this.controls.update();
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

  dispose() {
    if (this._disposed) return;
    this._disposed = true;
    if (this.controls) {
      try { this.controls.dispose(); } catch (e) { /* ignore */ }
      this.controls = null;
    }
    this.camera = null;
  }
}
