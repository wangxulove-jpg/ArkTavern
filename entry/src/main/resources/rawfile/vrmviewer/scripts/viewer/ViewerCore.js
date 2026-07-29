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

      // 启动渲染循环
      // 顺序(与 Figure animate() 行 2860-2906 一致):
      //   FRAME_START → deltaSeconds → modelLoader.update(delta) → camera.update(delta) → scene.render(camera) → FRAME_END
      // Figure: currentVrm.update(deltaTime) → controls.update() → renderer.render()
      this.frameLoop.start((deltaSeconds) => {
        if (this.modelLoader) {
          this.modelLoader.update(deltaSeconds);
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
   * Figure 基准: FOV=30, near=0.1, far=20, position=(0,1.25,2), target=(0,1.25,0)
   *
   * 不依赖当前模型大小。preserveControlsEnabled 保持控制面板触摸隔离状态。
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
    var result = this.camera.reset({ preserveControlsEnabled: true });
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

    return {
      viewerState: this._state,
      // Phase 2A-1: 模型状态扩展
      modelState: modelState,
      modelLoaded: modelLoaded,
      modelDisplayName: modelDisplayName,
      modelSource: modelSource,
      modelError: modelError,
      animationState: 'NOT_INITIALIZED',
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
      phase: 'PHASE_2A_2'
    };
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

  /**
   * 销毁 Viewer,释放所有资源。
   *
   * 顺序(AGENTS.md Phase 1C-2 §十九):
   *   1. 状态推进到 DISPOSING
   *   2. 使进行中的 initialize 失效(_initToken++)
   *   3. 移除 ResizeObserver / window resize listener
   *   4. 停止 Frame Loop
   *   5. dispose ModelLoader(释放当前 VRM:Geometry / Material / Texture)
   *   6. dispose Camera(OrbitControls)
   *   7. dispose Scene(Renderer / 测试方块 / 灯光 / Canvas)
   *   8. 清空引用
   *   9. 状态推进到 DISPOSED
   *
   * 必须先销毁模型,再销毁 Scene:
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
