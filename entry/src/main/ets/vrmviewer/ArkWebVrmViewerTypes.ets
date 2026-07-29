/**
 * ArkWebVrmViewerTypes — ArkWeb VRM Viewer 类型与常量定义
 *
 * 定义 ArkWeb 版 Viewer 的:
 * - Viewer 状态机(与 Web 端字符串状态对齐)
 * - 模型状态
 * - 动画状态
 * - Bridge 错误类型
 * - 默认配置常量
 *
 * Reference:
 * - figure-main: index.html(状态隐式表达,本文件将其显式化为状态机)
 * - ownverse-vrm-viewer: analysis/VIEWER_ARCHITECTURE.md §状态管理(分层参考)
 * - HarmonyOS ArkWeb: WebviewController API
 */

/**
 * ArkWeb Viewer 生命周期状态机。
 *
 * 与 Web 端 ViewerBridge.js 中的 __viewerState 字符串对齐。
 * 合法转换:
 * - UNINITIALIZED → INITIALIZING
 * - INITIALIZING → READY
 * - INITIALIZING → FAILED
 * - READY → LOADING_MODEL
 * - LOADING_MODEL → MODEL_READY
 * - LOADING_MODEL → FAILED
 * - MODEL_READY → LOADING_MODEL
 * - MODEL_READY → LOADING_ANIMATION
 * - LOADING_ANIMATION → ANIMATION_READY
 * - LOADING_ANIMATION → FAILED
 * - 任意 → DISPOSING(dispose 调用)
 * - DISPOSING → DISPOSED
 *
 * Phase 1A:仅使用 UNINITIALIZED / INITIALIZING / READY / FAILED / DISPOSING / DISPOSED。
 */
export enum ArkWebViewerState {
  /** 初始状态,Web 组件尚未加载完成。 */
  UNINITIALIZED = 'UNINITIALIZED',
  /** Viewer 正在初始化(等待 Web 端 initializeViewer 返回)。 */
  INITIALIZING = 'INITIALIZING',
  /** Viewer 就绪(Phase 1A 终态;Phase 1B+ 表示 Scene/Camera/Light 就绪)。 */
  READY = 'READY',
  /** 模型加载中(Phase 1C+)。 */
  LOADING_MODEL = 'LOADING_MODEL',
  /** 模型就绪(Phase 1C+)。 */
  MODEL_READY = 'MODEL_READY',
  /** 动画加载中(Phase 3+)。 */
  LOADING_ANIMATION = 'LOADING_ANIMATION',
  /** 动画就绪(Phase 3+)。 */
  ANIMATION_READY = 'ANIMATION_READY',
  /** 初始化或加载失败。 */
  FAILED = 'FAILED',
  /** 资源释放中。 */
  DISPOSING = 'DISPOSING',
  /** 已销毁。 */
  DISPOSED = 'DISPOSED'
}

/**
 * 模型加载状态(与 Web 端 onModelStateChanged 字符串对齐)。
 */
export enum ArkWebModelState {
  NOT_LOADED = 'NOT_LOADED',
  LOADING = 'LOADING',
  READY = 'READY',
  FAILED = 'FAILED'
}

/**
 * 动画播放状态(Phase 3A 重构,与 Web 端 AnimationState 枚举完全对齐)。
 *
 * Phase 1A 仅声明旧值(NOT_LOADED 等),Phase 3A 起替换为完整状态机:
 *   UNINITIALIZED → IDLE (initialize)
 *   IDLE → LOADING (loadAnimation,Phase 3A 未实现)
 *   LOADING → READY (clip 准备完成,Phase 3A 未实现)
 *   READY → PLAYING (play,Phase 3A 未实现)
 *   PLAYING → PAUSED (pause,Phase 3A 未实现)
 *   PLAYING/PAUSED → STOPPED (stop,Phase 3A 未实现)
 *   任意 → FAILED (错误,不影响 ViewerState/ModelState)
 *   任意 → DISPOSED (dispose)
 *
 * Phase 3A 骨架实际使用的状态:UNINITIALIZED / IDLE / FAILED / DISPOSED。
 */
export enum ArkWebAnimationState {
  UNINITIALIZED = 'UNINITIALIZED',
  IDLE = 'IDLE',
  LOADING = 'LOADING',
  READY = 'READY',
  PLAYING = 'PLAYING',
  PAUSED = 'PAUSED',
  STOPPED = 'STOPPED',
  FAILED = 'FAILED',
  DISPOSED = 'DISPOSED'
}

/**
 * Phase 3A: 动画系统调试状态快照(只读)。
 *
 * 与 Web 端 ViewerAnimationController.getDebugState() 返回对象字段一一对应。
 * 供 Debug Tab 显示动画系统内部状态。
 */
export interface ArkWebAnimationDebugState {
  state: ArkWebAnimationState;
  vrmBound: boolean;
  mixerReady: boolean;
  clipReady: boolean;
  actionReady: boolean;
  animationName: string;
  duration: number;
  currentTime: number;
  playbackSpeed: number;
  loop: boolean;
  errorCode: string;
  errorMessage: string;
}

/**
 * Phase 3A: 动画系统错误代码(与 Web 端 ViewerAnimationController 错误码对齐)。
 *
 * 动画错误不得导致 ViewerState = FAILED / ModelState = FAILED。
 */
export class ArkWebAnimationErrorCode {
  public static readonly CONTROLLER_DISPOSED: string = 'ANIMATION_CONTROLLER_DISPOSED';
  public static readonly NOT_INITIALIZED: string = 'ANIMATION_NOT_INITIALIZED';
  public static readonly VRM_MISSING: string = 'ANIMATION_VRM_MISSING';
  public static readonly VRM_INVALID: string = 'ANIMATION_VRM_INVALID';
  public static readonly MIXER_CREATION_FAILED: string = 'ANIMATION_MIXER_CREATION_FAILED';
  public static readonly DELTA_INVALID: string = 'ANIMATION_DELTA_INVALID';
  public static readonly DEPENDENCY_MISSING: string = 'ANIMATION_DEPENDENCY_MISSING';
  public static readonly UNSUPPORTED: string = 'ANIMATION_UNSUPPORTED';
}

/**
 * Bridge 错误代码(与 Web 端 ViewerBridge.notifyViewerError 的 code 字段对齐)。
 *
 * Phase 1D-2C-2A 新增 initializeViewer 同步返回链路上的错误码:
 * - INITIALIZE_RESULT_EMPTY: runJavaScript 返回空字符串
 * - INITIALIZE_RESULT_NOT_JSON: 返回内容不是合法 JSON
 * - INITIALIZE_RESULT_PROMISE: 返回 [object Promise](Bridge 误声明为 async)
 * - VIEWER_CONTAINER_NOT_FOUND: HTML 容器 ViewerStage 未找到
 * - VIEWER_INITIALIZE_REJECTED: ViewerCore.initialize 抛出异常
 * - VIEWER_READY_TIMEOUT: 初始化超时(沿用 INIT_TIMEOUT_MS)
 *
 * Phase 1D-2C-2B 新增 JsCaller 层错误码(Bridge 调用脚本与返回值规范化):
 * - BRIDGE_NOT_FOUND: window.arkTavernViewerBridge 不可用
 * - BRIDGE_METHOD_NOT_FOUND: 指定方法不存在或不是函数
 * - BRIDGE_CALL_FAILED: Bridge 方法同步抛出异常
 * - BRIDGE_RESULT_EMPTY: runJavaScript 返回 null / undefined / 空字符串
 * - BRIDGE_RESULT_PROMISE: runJavaScript 返回 [object Promise]
 * - BRIDGE_RESULT_NOT_JSON: 返回内容不是合法 JSON(也无法解包)
 *
 * 职责分层:
 * - JsCaller 层优先返回 BRIDGE_RESULT_*(底层调用与返回值规范化)
 * - Controller 层在未收到具体 BRIDGE_RESULT_* 时回退到 INITIALIZE_RESULT_*
 * - Controller 必须保留 JsCaller 返回的具体错误码,不强制改成 INITIALIZE_RESULT_*
 */
export enum ArkWebViewerErrorCode {
  INIT_FAILED = 'INIT_FAILED',
  DISPOSE_FAILED = 'DISPOSE_FAILED',
  MODEL_LOAD_FAILED = 'MODEL_LOAD_FAILED',
  ANIMATION_LOAD_FAILED = 'ANIMATION_LOAD_FAILED',
  WEBGL_UNAVAILABLE = 'WEBGL_UNAVAILABLE',
  INVALID_VRM = 'INVALID_VRM',
  FILE_UNREADABLE = 'FILE_UNREADABLE',
  INVALID_URI = 'INVALID_URI',
  PAGE_DISPOSED = 'PAGE_DISPOSED',
  // Phase 1D-2C-2A: initializeViewer 同步返回链路错误码(Controller 层)
  INITIALIZE_RESULT_EMPTY = 'INITIALIZE_RESULT_EMPTY',
  INITIALIZE_RESULT_NOT_JSON = 'INITIALIZE_RESULT_NOT_JSON',
  INITIALIZE_RESULT_PROMISE = 'INITIALIZE_RESULT_PROMISE',
  VIEWER_CONTAINER_NOT_FOUND = 'VIEWER_CONTAINER_NOT_FOUND',
  VIEWER_INITIALIZE_REJECTED = 'VIEWER_INITIALIZE_REJECTED',
  VIEWER_READY_TIMEOUT = 'VIEWER_READY_TIMEOUT',
  // Phase 1D-2C-2B: JsCaller 层错误码(Bridge 调用脚本与返回值规范化)
  BRIDGE_NOT_FOUND = 'BRIDGE_NOT_FOUND',
  BRIDGE_METHOD_NOT_FOUND = 'BRIDGE_METHOD_NOT_FOUND',
  BRIDGE_CALL_FAILED = 'BRIDGE_CALL_FAILED',
  BRIDGE_RESULT_EMPTY = 'BRIDGE_RESULT_EMPTY',
  BRIDGE_RESULT_PROMISE = 'BRIDGE_RESULT_PROMISE',
  BRIDGE_RESULT_NOT_JSON = 'BRIDGE_RESULT_NOT_JSON',
  // Phase 1D-2C-2C: app.js 模块启动诊断错误码(bootstrap 引导层)
  // - APP_BRIDGE_NOT_READY: window.arkTavernViewerBridge 不存在,但 bootstrap 状态可用
  // - APP_MODULE_LOAD_FAILED: app.js 模块加载失败(import 解析失败 / 网络错误)
  // - APP_MODULE_EXECUTION_FAILED: app.js 模块执行失败(语法错误 / 运行时错误)
  // - BOOTSTRAP_BRIDGE_NOT_FOUND: window.arkTavernBootstrapBridge 也不存在(bootstrap.js 未加载)
  APP_BRIDGE_NOT_READY = 'APP_BRIDGE_NOT_READY',
  APP_MODULE_LOAD_FAILED = 'APP_MODULE_LOAD_FAILED',
  APP_MODULE_EXECUTION_FAILED = 'APP_MODULE_EXECUTION_FAILED',
  BOOTSTRAP_BRIDGE_NOT_FOUND = 'BOOTSTRAP_BRIDGE_NOT_FOUND',
  UNKNOWN = 'UNKNOWN'
}

/**
 * Bridge 错误载荷(解析自 Web 端 onViewerError 的 JSON 字符串)。
 */
export interface ArkWebViewerError {
  /** 错误代码,见 ArkWebViewerErrorCode。 */
  code: string;
  /** 人类可读错误信息。 */
  message: string;
  /** 错误发生时的状态阶段。 */
  phase: string;
  /** 是否可恢复。 */
  recoverable: boolean;
}

/**
 * getViewerState 返回的状态载荷。
 */
export interface ArkWebViewerStatePayload {
  /** Viewer 当前状态。 */
  state: string;
  /** 详细描述。 */
  detail: string;
  /** 当前阶段标识(如 'PHASE_1A')。 */
  phase: string;
}

/**
 * Web 端 PreparedModelResourceKeeper 状态机(Phase 1D-2C-2E-1)。
 *
 * 与 Native 端 ModelResourceState 解耦:
 * - ModelResourceState.READY 只表示 Native ResourceProvider 已注册资源 URL
 * - WebPreparedResourceState.READY 表示 JavaScript keeper 已通过 prepareModelResource
 *   接收资源元数据并通过 getPreparedModelResource 回读校验
 *
 * 状态流转:
 *   EMPTY → PREPARING       (ensurePreparedModelResource 开始)
 *   PREPARING → READY       (prepare + readback 成功)
 *   PREPARING → FAILED      (任一校验失败)
 *   READY → PREPARING       (重新准备,资源更换或手动重试)
 *   FAILED → PREPARING      (手动重试)
 *   任意 → EMPTY            (clearPreparedModelResource / 资源注销)
 *
 * 关键约束:
 * - 自动探测(probePreparedModelResource)只允许在 READY 状态启动
 * - Native ModelResourceState.READY ≠ WebPreparedResourceState.READY
 */
export enum WebPreparedResourceState {
  /** 初始状态,JavaScript keeper 未收到资源元数据。 */
  EMPTY = 'EMPTY',
  /** 正在调用 prepareModelResource + getPreparedModelResource 回读校验。 */
  PREPARING = 'PREPARING',
  /** 资源元数据已同步到 JavaScript keeper 并通过回读校验。 */
  READY = 'READY',
  /** 准备失败(prepare 调用失败 / 返回无效 / 回读为空 / 回读不一致 / 代次过期)。 */
  FAILED = 'FAILED'
}

/**
 * Web 资源准备错误码(Phase 1D-2C-2E-1)。
 *
 * 用于精确描述 ensurePreparedModelResource 各阶段失败原因,
 * 替代之前将所有准备失败压缩为 PROBE_START_FAILED 的做法。
 */
export class WebPreparedResourceErrorCode {
  /** Viewer 未就绪(状态非 READY)。 */
  static readonly VIEWER_NOT_READY: string = 'VIEWER_NOT_READY';
  /** Native 资源未就绪(ModelResourceState 非 READY)。 */
  static readonly NATIVE_RESOURCE_NOT_READY: string = 'NATIVE_RESOURCE_NOT_READY';
  /** 资源元数据为 null(preparedResource 未注册)。 */
  static readonly RESOURCE_NULL: string = 'RESOURCE_NULL';
  /** 用户模型加载进行中,禁止替换 PreparedResource。 */
  static readonly MODEL_LOAD_IN_PROGRESS: string = 'MODEL_LOAD_IN_PROGRESS';
  /** 已有 prepare 操作进行中。 */
  static readonly RESOURCE_PREPARE_IN_PROGRESS: string = 'RESOURCE_PREPARE_IN_PROGRESS';
  /** prepareModelResource Bridge 调用本身失败(异常 / rejected)。 */
  static readonly RESOURCE_PREPARE_CALL_FAILED: string = 'RESOURCE_PREPARE_CALL_FAILED';
  /** prepareModelResource 返回内容不是合法 JSON 或结构无效。 */
  static readonly RESOURCE_PREPARE_RESULT_INVALID: string = 'RESOURCE_PREPARE_RESULT_INVALID';
  /** prepareModelResource 返回 success=false(keeper 拒绝,如字段缺失 / 类型错误)。 */
  static readonly RESOURCE_PREPARE_REJECTED: string = 'RESOURCE_PREPARE_REJECTED';
  /** getPreparedModelResource 回读 resource 为 null(keeper 未保存)。 */
  static readonly RESOURCE_PREPARE_READBACK_EMPTY: string = 'RESOURCE_PREPARE_READBACK_EMPTY';
  /** getPreparedModelResource 回读 JSON 无效或字段缺失。 */
  static readonly RESOURCE_PREPARE_READBACK_INVALID: string = 'RESOURCE_PREPARE_READBACK_INVALID';
  /** 回读字段与发送字段不一致(resourceUrl / displayName / mimeType / size / extension / gltfDependencyState)。 */
  static readonly RESOURCE_PREPARE_READBACK_MISMATCH: string = 'RESOURCE_PREPARE_READBACK_MISMATCH';
  /** prepareGeneration 已过期(期间发起新 prepare 或 dispose)。 */
  static readonly RESOURCE_PREPARE_STALE: string = 'RESOURCE_PREPARE_STALE';
  /** ensurePreparedModelResource 内部异常。 */
  static readonly RESOURCE_PREPARE_EXCEPTION: string = 'RESOURCE_PREPARE_EXCEPTION';
}

/**
 * 默认 Viewer 配置常量(Phase 1A:仅 Web 组件配置)。
 *
 * 后续阶段会补充相机/灯光/背景等参数(从 Figure index.html 迁移)。
 */
export class ArkWebViewerConfig {
  /** Web 页面在 rawfile 下的相对路径(供 $rawfile() 使用)。 */
  public static readonly VIEWER_PAGE_PATH: string = 'vrmviewer/index.html';

  /** Bridge 名称:ArkTS → JavaScript 调用入口(window.arkTavernViewerBridge)。 */
  public static readonly BRIDGE_NAME_JS: string = 'arkTavernViewerBridge';

  /** Bridge 名称:JavaScript → ArkTS 回调入口(window.arkTavernNative)。 */
  public static readonly BRIDGE_NAME_NATIVE: string = 'arkTavernNative';

  /** Bridge 方法白名单:ArkTS → JavaScript。 */
  public static readonly BRIDGE_METHODS_JS: string[] = [
    'initializeViewer',
    'retryInitializeViewer',
    'disposeViewer',
    'getViewerState',
    'resetCamera',
    'resizeViewer',
    'getSceneState',
    // Phase 1D-2A: 缓存模型资源协议骨架(不触发加载)
    'prepareModelResource',
    'getPreparedModelResource',
    'clearPreparedModelResource',
    // Phase 1D-2B-1: 资源探测(HEAD 请求校验,不读取模型文件)
    'probePreparedModelResource',
    'getModelResourceProbeResult',
    'clearModelResourceProbe',
    // Phase 1D-2B-2: 用户模型加载(GLTFLoader 实际加载与原子替换)
    'loadPreparedModelResource',
    'getPreparedModelLoadResult',
    'clearPreparedModelLoadResult',
    // Phase 1D-2C-1: 运行时诊断(获取/清除最近一条诊断记录)
    'getVrmRuntimeDiagnostic',
    'clearVrmRuntimeDiagnostic',
    // Phase 2A-1: Camera Controls enable/disable(控制面板触摸隔离)
    'setCameraControlsEnabled',
    'getCameraControlsEnabled',
    // Phase 2A-1: Scene 设置(背景颜色 / 网格 / 灯光)
    'setSceneBackgroundColor',
    'setSceneGridVisible',
    'setSceneLightIntensity',
    'getSceneSettings',
    // Phase 2A-2: 相机重置、聚焦与状态查询
    'focusCameraOnCurrentModel',
    'getCameraState',
    // Phase 2F: 环境贴图与天空盒
    'initializeEnvironment',
    'setEnvironmentEnabled',
    'setSkyboxVisible',
    'setEnvironmentIntensity',
    'getEnvironmentSettings',
    // Phase 3A: 动画系统只读查询(不包含 play/pause/stop/seek 等控制方法)
    'getAnimationState',
    'getAnimationDebugState'
  ];

  /** Bridge 方法白名单:JavaScript → ArkTS。 */
  public static readonly BRIDGE_METHODS_NATIVE: string[] = [
    'onViewerReady',
    'onViewerError',
    'onModelStateChanged',
    'onAnimationStateChanged'
  ];

  /** 状态轮询间隔(毫秒),用于 ArkTS 主动拉取 Web 端状态(备用机制)。 */
  public static readonly STATE_POLL_INTERVAL_MS: number = 500;

  /** 初始化超时(毫秒),超时后转 FAILED。 */
  public static readonly INIT_TIMEOUT_MS: number = 10000;
}

/**
 * 将错误 JSON 字符串解析为 ArkWebViewerError。
 * 解析失败时返回 UNKNOWN 错误。
 */
export function parseViewerError(jsonStr: string): ArkWebViewerError {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    return {
      code: (obj['code'] as string) || ArkWebViewerErrorCode.UNKNOWN,
      message: (obj['message'] as string) || '',
      phase: (obj['phase'] as string) || 'UNKNOWN',
      recoverable: obj['recoverable'] !== false
    };
  } catch (e) {
    return {
      code: ArkWebViewerErrorCode.UNKNOWN,
      message: `Failed to parse error payload: ${jsonStr}`,
      phase: 'UNKNOWN',
      recoverable: false
    };
  }
}

/**
 * 将状态字符串转换为 ArkWebViewerState 枚举。
 * 无法识别的字符串返回 FAILED(保守策略)。
 */
export function parseViewerState(stateStr: string): ArkWebViewerState {
  switch (stateStr) {
    case 'UNINITIALIZED':
      return ArkWebViewerState.UNINITIALIZED;
    case 'INITIALIZING':
      return ArkWebViewerState.INITIALIZING;
    case 'READY':
      return ArkWebViewerState.READY;
    case 'LOADING_MODEL':
      return ArkWebViewerState.LOADING_MODEL;
    case 'MODEL_READY':
      return ArkWebViewerState.MODEL_READY;
    case 'LOADING_ANIMATION':
      return ArkWebViewerState.LOADING_ANIMATION;
    case 'ANIMATION_READY':
      return ArkWebViewerState.ANIMATION_READY;
    case 'FAILED':
      return ArkWebViewerState.FAILED;
    case 'DISPOSING':
      return ArkWebViewerState.DISPOSING;
    case 'DISPOSED':
      return ArkWebViewerState.DISPOSED;
    default:
      return ArkWebViewerState.FAILED;
  }
}

// ===== Phase 2A-1: Scene 设置与状态类型 =====

/**
 * Phase 2A-1: 场景设置(背景颜色 / 网格 / 灯光)。
 *
 * 用于 setSceneBackgroundColor / setSceneGridVisible / setSceneLightIntensity
 * 的参数传递与 getSceneSettings 的返回值解析。
 *
 * 背景颜色格式:仅允许 #RRGGBB(6 位十六进制),禁止 rgba / url(...) / 脚本字符串。
 * 灯光强度范围:0.0 ~ 4.0(ArkUI 百分比 0-100% 映射:intensity = percentage / 25.0)。
 */
export interface ArkWebViewerSceneSettings {
  /** 背景颜色,#RRGGBB 格式(大写或小写,由 Bridge 规范化) */
  backgroundColor: string;
  /** 网格是否可见 */
  gridVisible: boolean;
  /** 主方向光强度(0.0 ~ 4.0) */
  lightIntensity: number;
}

/**
 * Phase 2A-1: 场景状态快照(包含设置 + Camera Controls 状态)。
 *
 * 用于 getSceneState 返回值的解析,供 Debug Tab 显示。
 */
export interface ArkWebViewerSceneState {
  /** 背景颜色,#RRGGBB 格式 */
  backgroundColor: string;
  /** 网格是否可见 */
  gridVisible: boolean;
  /** 主方向光强度(0.0 ~ 4.0) */
  lightIntensity: number;
  /** OrbitControls 是否启用(控制面板触摸隔离期间为 false) */
  cameraControlsEnabled: boolean;
}

/**
 * Phase 2A-2: 三维向量。
 */
export interface ArkWebCameraVector3 {
  x: number;
  y: number;
  z: number;
}

/**
 * Phase 2A-2: 相机状态。
 * 用于 Debug Tab 显示和相机操作返回值。
 */
export interface ArkWebCameraState {
  /** 相机位置 */
  position: ArkWebCameraVector3;
  /** OrbitControls 目标点 */
  target: ArkWebCameraVector3;
  /** 视场角(度) */
  fov: number;
  /** 近裁剪面 */
  near: number;
  /** 远裁剪面 */
  far: number;
  /** 宽高比 */
  aspect: number;
  /** 相机到目标的距离 */
  distance: number;
  /** OrbitControls 是否启用 */
  controlsEnabled: boolean;
  /** 最近一次相机操作: INITIALIZE / RESET / FOCUS / MODEL_REPLACED_FOCUS */
  lastAction: string;
}

/**
 * Phase 2A-1: 模型来源类型。
 * - USER:用户导入的模型
 * - DEFAULT:默认 VRM
 * - NONE:无模型
 */
export type ArkWebViewerModelSource = 'USER' | 'DEFAULT' | 'NONE';

/**
 * Phase 2A-1: 解析 getSceneSettings 返回的 JSON 字符串。
 *
 * @param jsonStr Bridge 返回的 JSON 字符串
 * @returns 解析成功返回 ArkWebViewerSceneSettings,失败返回 null
 */
export function parseSceneSettings(jsonStr: string): ArkWebViewerSceneSettings | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    if (!obj['success']) {
      return null;
    }
    const settingsObj = obj['settings'] as Record<string, Object>;
    if (!settingsObj) {
      return null;
    }
    return {
      backgroundColor: (settingsObj['backgroundColor'] as string) || '#222222',
      gridVisible: settingsObj['gridVisible'] === true,
      lightIntensity: (settingsObj['lightIntensity'] as number) ?? 3.0
    };
  } catch (e) {
    return null;
  }
}

/**
 * Phase 2A-1: 校验 #RRGGBB 颜色格式。
 *
 * 只允许 6 位十六进制(大写或小写),禁止:
 * - 3 位简写(#FFF)
 * - 带透明度(#RRGGBBAA)
 * - 任意 CSS(rgba / hsl / url(...))
 * - 脚本字符串
 *
 * @param color 待校验的颜色字符串
 * @returns true=合法;false=非法
 */
export function isValidHexColor(color: string): boolean {
  if (typeof color !== 'string') {
    return false;
  }
  return /^#[0-9A-Fa-f]{6}$/.test(color);
}

/**
 * Phase 2A-2: 解析 getCameraState / resetCamera / focusCameraOnCurrentModel 返回的 JSON 字符串。
 *
 * @param jsonStr Bridge 返回的 JSON 字符串
 * @returns 解析成功返回 ArkWebCameraState,失败返回 null
 */
export function parseCameraState(jsonStr: string): ArkWebCameraState | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    if (!obj['success']) {
      return null;
    }
    const cameraStateObj = obj['cameraState'] as Record<string, Object>;
    if (!cameraStateObj) {
      return null;
    }
    const positionObj = cameraStateObj['position'] as Record<string, Object>;
    const targetObj = cameraStateObj['target'] as Record<string, Object>;
    if (!positionObj || !targetObj) {
      return null;
    }
    return {
      position: {
        x: (positionObj['x'] as number) ?? 0,
        y: (positionObj['y'] as number) ?? 0,
        z: (positionObj['z'] as number) ?? 0
      },
      target: {
        x: (targetObj['x'] as number) ?? 0,
        y: (targetObj['y'] as number) ?? 0,
        z: (targetObj['z'] as number) ?? 0
      },
      fov: (cameraStateObj['fov'] as number) ?? 30,
      near: (cameraStateObj['near'] as number) ?? 0.1,
      far: (cameraStateObj['far'] as number) ?? 20,
      aspect: (cameraStateObj['aspect'] as number) ?? 1,
      distance: (cameraStateObj['distance'] as number) ?? 0,
      controlsEnabled: cameraStateObj['controlsEnabled'] === true,
      lastAction: (cameraStateObj['lastAction'] as string) || 'INITIALIZE'
    };
  } catch (e) {
    return null;
  }
}

// ===== Phase 2B: 平滑重置 =====

/**
 * Phase 2B: 相机过渡状态机。
 *
 * 状态流转:
 *   IDLE → RUNNING → COMPLETED
 *   RUNNING → CANCELLED  (用户交互 / 即时重置 / 聚焦 / dispose)
 *   RUNNING → FAILED     (无效数值)
 *   任意 → DISPOSED      (Viewer dispose)
 */
export enum ArkWebCameraTransitionState {
  IDLE = 'IDLE',
  RUNNING = 'RUNNING',
  COMPLETED = 'COMPLETED',
  CANCELLED = 'CANCELLED',
  FAILED = 'FAILED',
  DISPOSED = 'DISPOSED'
}

/**
 * Phase 2B: 平滑相机过渡结果。
 *
 * 由 getCameraTransitionState() / smoothResetCamera() / cancelCameraTransition() 返回。
 */
export interface ArkWebCameraTransitionResult {
  /** 当前过渡状态 */
  state: ArkWebCameraTransitionState;
  /** 过渡进度 [0,1] */
  progress: number;
  /** 过渡总时长(秒) */
  durationSeconds: number;
  /** 已经过渡时间(秒) */
  elapsedSeconds: number;
  /** 取消原因(空字符串表示未取消) */
  cancelReason: string;
  /** 错误码(空字符串表示无错误) */
  errorCode: string;
  /** 错误信息(空字符串表示无错误) */
  errorMessage: string;
  /** 过渡开始时间戳(ms) */
  startedAt: number;
  /** 过渡完成时间戳(ms) */
  completedAt: number;
}

/**
 * Phase 2B: 平滑重置选项(构造 optionsJson 时使用,ArkTS 严格模式要求对象字面量对应 interface)。
 */
export interface ArkWebSmoothResetOptions {
  /** 过渡时长(秒) */
  durationSeconds: number;
  /** 是否保持 controls.enabled */
  preserveControlsEnabled: boolean;
}

/**
 * Phase 2B: Bridge 错误载荷(Controller 返回失败响应时使用)。
 */
export interface ArkWebBridgeErrorPayload {
  /** 错误码 */
  code: string;
  /** 错误信息 */
  message: string;
}

/**
 * Phase 2B: Bridge 操作失败响应(Controller 在 disposed/catch 分支返回)。
 */
export interface ArkWebBridgeFailedResponse {
  /** 操作是否成功 */
  success: boolean;
  /** 错误载荷 */
  error: ArkWebBridgeErrorPayload;
}

/**
 * Phase 2B: getCameraTransitionState 失败响应(disposed 时返回 IDLE transition)。
 */
export interface ArkWebCameraTransitionStateResponse {
  /** 查询是否成功 */
  success: boolean;
  /** 过渡状态结果 */
  transition: ArkWebCameraTransitionResult;
}

/**
 * Phase 2B: 平滑重置默认时长(秒) - ArkTavern 交互适配参数。
 */
export const ARKWEB_CAMERA_SMOOTH_RESET_DEFAULT_DURATION: number = 0.45;

/**
 * Phase 2B: 平滑重置合法时长范围(秒)。
 */
export const ARKWEB_CAMERA_SMOOTH_RESET_MIN_DURATION: number = 0.1;
export const ARKWEB_CAMERA_SMOOTH_RESET_MAX_DURATION: number = 2.0;

/**
 * Phase 2B: 过渡状态轮询间隔(ms)。
 */
export const ARKWEB_CAMERA_TRANSITION_POLL_INTERVAL_MS: number = 100;

/**
 * Phase 2B: 过渡状态轮询超时(ms)。
 */
export const ARKWEB_CAMERA_TRANSITION_POLL_TIMEOUT_MS: number = 3000;

/**
 * Phase 2B: 校验平滑重置时长是否合法。
 *
 * @param durationSeconds 时长(秒)
 * @returns true=合法;false=非法
 */
export function isValidSmoothResetDuration(durationSeconds: number): boolean {
  if (typeof durationSeconds !== 'number') {
    return false;
  }
  if (!isFinite(durationSeconds)) {
    return false;
  }
  return durationSeconds >= ARKWEB_CAMERA_SMOOTH_RESET_MIN_DURATION &&
         durationSeconds <= ARKWEB_CAMERA_SMOOTH_RESET_MAX_DURATION;
}

/**
 * Phase 2B: 构造平滑重置选项 JSON 字符串。
 *
 * @param durationSeconds 时长(秒),非法时使用默认值 0.45
 * @param preserveControlsEnabled 是否保持 controls.enabled,默认 true
 * @returns JSON 字符串,形如 '{"durationSeconds":0.45,"preserveControlsEnabled":true}'
 */
export function buildSmoothResetOptionsJson(
  durationSeconds: number,
  preserveControlsEnabled: boolean = true
): string {
  const duration: number = isValidSmoothResetDuration(durationSeconds)
    ? durationSeconds
    : ARKWEB_CAMERA_SMOOTH_RESET_DEFAULT_DURATION;
  const options: ArkWebSmoothResetOptions = {
    durationSeconds: duration,
    preserveControlsEnabled: preserveControlsEnabled === true
  };
  return JSON.stringify(options);
}

/**
 * Phase 2B: 解析 getCameraTransitionState / smoothResetCamera / cancelCameraTransition
 * 返回的 JSON 字符串。
 *
 * @param jsonStr Bridge 返回的 JSON 字符串
 * @returns 解析成功返回 ArkWebCameraTransitionResult,失败返回 null
 */
export function parseCameraTransitionResult(jsonStr: string): ArkWebCameraTransitionResult | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    // transition 对象可能在顶层或 nested 在 transition 字段
    let transitionObj: Record<string, Object> | null = null;
    if (obj['transition']) {
      transitionObj = obj['transition'] as Record<string, Object>;
    } else if (obj['state'] && typeof obj['state'] === 'string') {
      // 兼容直接返回 transition 对象的场景
      transitionObj = obj;
    }
    if (!transitionObj) {
      return null;
    }
    const stateStr: string = (transitionObj['state'] as string) || 'IDLE';
    let state: ArkWebCameraTransitionState;
    switch (stateStr) {
      case 'IDLE':
        state = ArkWebCameraTransitionState.IDLE;
        break;
      case 'RUNNING':
        state = ArkWebCameraTransitionState.RUNNING;
        break;
      case 'COMPLETED':
        state = ArkWebCameraTransitionState.COMPLETED;
        break;
      case 'CANCELLED':
        state = ArkWebCameraTransitionState.CANCELLED;
        break;
      case 'FAILED':
        state = ArkWebCameraTransitionState.FAILED;
        break;
      case 'DISPOSED':
        state = ArkWebCameraTransitionState.DISPOSED;
        break;
      default:
        state = ArkWebCameraTransitionState.IDLE;
        break;
    }
    return {
      state: state,
      progress: (transitionObj['progress'] as number) ?? 0,
      durationSeconds: (transitionObj['durationSeconds'] as number) ?? 0,
      elapsedSeconds: (transitionObj['elapsedSeconds'] as number) ?? 0,
      cancelReason: (transitionObj['cancelReason'] as string) || '',
      errorCode: (transitionObj['errorCode'] as string) || '',
      errorMessage: (transitionObj['errorMessage'] as string) || '',
      startedAt: (transitionObj['startedAt'] as number) ?? 0,
      completedAt: (transitionObj['completedAt'] as number) ?? 0
    };
  } catch (e) {
    return null;
  }
}

/**
 * Phase 2A-1: 将灯光百分比(0-100)映射为强度(0.0-4.0)。
 *
 * 映射规则:
 *   0%   → 0.0
 *   25%  → 1.0
 *   50%  → 2.0
 *   75%  → 3.0
 *   100% → 4.0
 *
 * @param percentage 0-100
 * @returns 强度值 0.0-4.0
 */
export function lightPercentageToIntensity(percentage: number): number {
  return percentage / 25.0;
}

/**
 * Phase 2A-1: 将灯光强度(0.0-4.0)映射回百分比(0-100)。
 *
 * @param intensity 0.0-4.0
 * @returns 百分比 0-100
 */
export function lightIntensityToPercentage(intensity: number): number {
  return intensity * 25.0;
}

// ===== Phase 2A-3A: 截图能力类型定义 =====

/**
 * Phase 2A-3A: 截图状态机。
 *
 * 状态流转:
 *   IDLE → CAPTURING → SAVING → READY
 *   IDLE → CAPTURING → FAILED
 *   IDLE → CAPTURING → SAVING → FAILED
 *   任意 → DISPOSED
 *
 * 约束:
 * - CAPTURING/SAVING 期间拒绝新的截图请求
 * - READY 后可以再次发起截图(回到 IDLE 再到 CAPTURING)
 * - DISPOSED 为终态,不可恢复
 */
export enum ScreenshotState {
  /** 空闲,可以发起截图 */
  IDLE = 'IDLE',
  /** 正在捕获 ArkWeb 快照(调用 webPageSnapshot) */
  CAPTURING = 'CAPTURING',
  /** 正在将 PNG 写入应用缓存 */
  SAVING = 'SAVING',
  /** 截图已完成并保存成功 */
  READY = 'READY',
  /** 截图失败 */
  FAILED = 'FAILED',
  /** 控制器已销毁 */
  DISPOSED = 'DISPOSED'
}

/**
 * Phase 2A-3A: 截图结果。
 *
 * 安全约束:
 * - cachePath 只存在于 ArkTS 内部,禁止发送到 JavaScript 或显示在 UI
 * - 禁止包含 Base64 / PixelMap 对象 / 文件描述符
 */
export interface ScreenshotResult {
  /** 截图状态 */
  state: ScreenshotState;
  /** 文件名(不含路径) */
  fileName: string;
  /** 应用缓存完整路径(仅 ArkTS 内部使用,不显示在 UI) */
  cachePath: string;
  /** MIME 类型,固定 'image/png' */
  mimeType: string;
  /** 图像宽度(px) */
  width: number;
  /** 图像高度(px) */
  height: number;
  /** PNG 文件字节数 */
  byteLength: number;
  /** 创建时间戳(ms) */
  createdAt: number;
  /** 失败错误码(成功时为空字符串) */
  errorCode: string;
  /** 失败错误信息(成功时为空字符串) */
  errorMessage: string;
}

/**
 * Phase 2A-3A: 截图错误代码。
 *
 * 用于精确描述截图链路各阶段失败原因。
 */
export class ScreenshotErrorCode {
  /** 控制器已销毁 */
  static readonly CONTROLLER_DISPOSED: string = 'SCREENSHOT_CONTROLLER_DISPOSED';
  /** 已有截图进行中 */
  static readonly IN_PROGRESS: string = 'SCREENSHOT_IN_PROGRESS';
  /** Viewer 未就绪 */
  static readonly VIEWER_NOT_READY: string = 'VIEWER_NOT_READY';
  /** WebviewController 未就绪 */
  static readonly WEBVIEW_CONTROLLER_NOT_READY: string = 'SCREENSHOT_WEBVIEW_CONTROLLER_NOT_READY';
  /** 快照 API 调用失败 */
  static readonly SNAPSHOT_CALL_FAILED: string = 'SCREENSHOT_SNAPSHOT_CALL_FAILED';
  /** 快照返回 status=false */
  static readonly SNAPSHOT_STATUS_FALSE: string = 'SCREENSHOT_SNAPSHOT_STATUS_FALSE';
  /** PixelMap 为空 */
  static readonly PIXELMAP_EMPTY: string = 'SCREENSHOT_PIXELMAP_EMPTY';
  /** PNG 编码失败 */
  static readonly PNG_ENCODE_FAILED: string = 'SCREENSHOT_PNG_ENCODE_FAILED';
  /** PNG 编码结果为空 */
  static readonly PNG_BUFFER_EMPTY: string = 'SCREENSHOT_PNG_BUFFER_EMPTY';
  /** 缓存目录创建失败 */
  static readonly CACHE_DIRECTORY_FAILED: string = 'SCREENSHOT_CACHE_DIRECTORY_FAILED';
  /** 文件创建失败 */
  static readonly FILE_CREATE_FAILED: string = 'SCREENSHOT_FILE_CREATE_FAILED';
  /** 文件写入失败 */
  static readonly FILE_WRITE_FAILED: string = 'SCREENSHOT_FILE_WRITE_FAILED';
  /** 文件为空 */
  static readonly FILE_EMPTY: string = 'SCREENSHOT_FILE_EMPTY';
  /** 文件 rename 失败 */
  static readonly FILE_RENAME_FAILED: string = 'SCREENSHOT_FILE_RENAME_FAILED';
  /** 截图代次已过期 */
  static readonly STALE: string = 'SCREENSHOT_STALE';
  /** 内部异常 */
  static readonly EXCEPTION: string = 'SCREENSHOT_EXCEPTION';
}

/**
 * Phase 2A-3A: 创建空的截图结果(IDLE 状态)。
 */
export function createIdleScreenshotResult(): ScreenshotResult {
  return {
    state: ScreenshotState.IDLE,
    fileName: '',
    cachePath: '',
    mimeType: 'image/png',
    width: 0,
    height: 0,
    byteLength: 0,
    createdAt: 0,
    errorCode: '',
    errorMessage: ''
  };
}

// ===== Phase 2F: 环境贴图与天空盒类型 =====

/**
 * Phase 2F: 环境贴图状态机。
 *
 * 与 Web 端 ViewerScene.js 中的 EnvironmentState 字符串对齐。
 *
 * 状态流转:
 *   UNINITIALIZED → INITIALIZING → READY
 *   INITIALIZING → FAILED
 *   任意 → DISPOSED
 *
 * 关键约束:
 * - Environment 失败不影响 ViewerState(仍为 READY)
 * - DISPOSED 为终态,重新进入页面后重新初始化
 */
export enum ArkWebEnvironmentState {
  /** 初始状态,环境未初始化 */
  UNINITIALIZED = 'UNINITIALIZED',
  /** 正在初始化(PMREM 生成中) */
  INITIALIZING = 'INITIALIZING',
  /** 环境就绪,可启用 environment / skybox */
  READY = 'READY',
  /** 初始化失败 */
  FAILED = 'FAILED',
  /** 已销毁,资源已释放 */
  DISPOSED = 'DISPOSED'
}

/**
 * Phase 2F: 环境来源常量。
 */
export class ArkWebEnvironmentSource {
  /** 本地 HDR 文件(本阶段未使用) */
  static readonly LOCAL_HDR: string = 'LOCAL_HDR';
  /** 本地 Cube Map(本阶段未使用) */
  static readonly LOCAL_CUBE: string = 'LOCAL_CUBE';
  /** 程序化 RoomEnvironment(本阶段使用) */
  static readonly ROOM_ENVIRONMENT: string = 'ROOM_ENVIRONMENT';
  /** 无环境来源 */
  static readonly NONE: string = 'NONE';
}

/**
 * Phase 2F: 环境设置快照(由 getEnvironmentSettings 返回)。
 *
 * 用于场景 Tab 控制、Debug 状态显示、轮询同步。
 *
 * 安全约束:
 * - 不含纹理对象、WebGLRenderTarget、Renderer、绝对资源路径
 * - backgroundColor 为 #RRGGBB 格式
 * - environmentIntensity 范围 0.0 ~ 2.0
 */
export interface ArkWebEnvironmentSettings {
  /** 环境状态 (EnvironmentState 枚举字符串) */
  state: string;
  /** 环境来源 (ROOM_ENVIRONMENT / NONE) */
  source: string;
  /** 环境光照是否启用(scene.environment 已设置) */
  environmentEnabled: boolean;
  /** 天空盒是否可见(scene.background 指向环境纹理) */
  skyboxVisible: boolean;
  /** 环境强度 (0.0 ~ 2.0) */
  environmentIntensity: number;
  /** 当前保存的纯色背景 (#RRGGBB) */
  backgroundColor: string;
  /** 环境最近错误码(成功时为空字符串) */
  errorCode: string;
  /** 环境最近错误信息(成功时为空字符串) */
  errorMessage: string;
}

/**
 * Phase 2F: 环境强度合法范围。
 */
export const ARKWEB_ENVIRONMENT_INTENSITY_MIN: number = 0.0;
export const ARKWEB_ENVIRONMENT_INTENSITY_MAX: number = 2.0;
/** Phase 2F: 环境强度默认值 */
export const ARKWEB_ENVIRONMENT_INTENSITY_DEFAULT: number = 1.0;

/**
 * Phase 2F: 环境状态轮询间隔(ms)。
 *
 * Viewer READY 后调用 initializeEnvironment,然后按本间隔轮询
 * getEnvironmentSettings 直到状态变为 READY 或 FAILED。
 */
export const ARKWEB_ENVIRONMENT_POLL_INTERVAL_MS: number = 100;

/**
 * Phase 2F: 环境状态轮询超时(ms)。
 *
 * 超时后停止轮询,EnvironmentState 保持 INITIALIZING(不再推进)。
 */
export const ARKWEB_ENVIRONMENT_POLL_TIMEOUT_MS: number = 5000;

/**
 * Phase 2F: 创建默认的环境设置(UNINITIALIZED 状态)。
 *
 * 用于 Controller 在 Viewer 未 READY 时返回受控默认值。
 */
export function createDefaultEnvironmentSettings(): ArkWebEnvironmentSettings {
  return {
    state: ArkWebEnvironmentState.UNINITIALIZED,
    source: ArkWebEnvironmentSource.NONE,
    environmentEnabled: false,
    skyboxVisible: false,
    environmentIntensity: ARKWEB_ENVIRONMENT_INTENSITY_DEFAULT,
    backgroundColor: '#222222',
    errorCode: '',
    errorMessage: ''
  };
}

/**
 * Phase 2F: 解析 getEnvironmentSettings 返回的 JSON 字符串。
 *
 * @param jsonStr Bridge 返回的 JSON 字符串
 * @returns 解析成功返回 ArkWebEnvironmentSettings,失败返回 null
 */
export function parseEnvironmentSettings(jsonStr: string): ArkWebEnvironmentSettings | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    if (!obj['success']) {
      return null;
    }
    const settingsObj = obj['settings'] as Record<string, Object>;
    if (!settingsObj) {
      return null;
    }
    return {
      state: (settingsObj['state'] as string) || ArkWebEnvironmentState.UNINITIALIZED,
      source: (settingsObj['source'] as string) || ArkWebEnvironmentSource.NONE,
      environmentEnabled: settingsObj['environmentEnabled'] === true,
      skyboxVisible: settingsObj['skyboxVisible'] === true,
      environmentIntensity: (settingsObj['environmentIntensity'] as number) ?? ARKWEB_ENVIRONMENT_INTENSITY_DEFAULT,
      backgroundColor: (settingsObj['backgroundColor'] as string) || '#222222',
      errorCode: (settingsObj['errorCode'] as string) || '',
      errorMessage: (settingsObj['errorMessage'] as string) || ''
    };
  } catch (e) {
    return null;
  }
}

/**
 * Phase 2F: 将环境强度百分比(0-200)映射为强度(0.0-2.0)。
 *
 * 映射规则:
 *   0%   → 0.0
 *   50%  → 0.5
 *   100% → 1.0
 *   200% → 2.0
 *
 * @param percentage 0-200
 * @returns 强度值 0.0-2.0
 */
export function environmentPercentageToIntensity(percentage: number): number {
  return percentage / 100.0;
}

/**
 * Phase 2F: 将环境强度(0.0-2.0)映射回百分比(0-200)。
 *
 * @param intensity 0.0-2.0
 * @returns 百分比 0-200
 */
export function environmentIntensityToPercentage(intensity: number): number {
  return intensity * 100.0;
}

/**
 * Phase 2F: 校验环境强度是否合法。
 *
 * @param intensity 强度值
 * @returns true=合法;false=非法
 */
export function isValidEnvironmentIntensity(intensity: number): boolean {
  if (typeof intensity !== 'number') {
    return false;
  }
  if (!isFinite(intensity)) {
    return false;
  }
  return intensity >= ARKWEB_ENVIRONMENT_INTENSITY_MIN &&
         intensity <= ARKWEB_ENVIRONMENT_INTENSITY_MAX;
}

// ===== Phase 2H: 演示模式 (Presentation Mode) =====

/**
 * Phase 2H: 演示模式枚举。
 *
 * NORMAL — 正常模式,显示全部 ArkUI 覆盖层(快捷工具栏、控制面板)。
 * DEMO   — 演示模式,隐藏会遮挡 3D 模型的 ArkUI 覆盖层,仅保留顶部导航栏。
 */
export enum PresentationMode {
  NORMAL = 'NORMAL',
  DEMO = 'DEMO'
}

/**
 * Phase 2H: 演示模式错误码。
 *
 * 这些错误只影响演示模式状态,不影响 ViewerState / ModelState / CameraState /
 * EnvironmentState / ScreenshotState。
 */
export class ArkWebPresentationErrorCode {
  /** Viewer 未 READY,拒绝进入 DEMO */
  static readonly VIEWER_NOT_READY: string = 'PRESENTATION_VIEWER_NOT_READY';
  /** 切换正在进行,拒绝重复操作 */
  static readonly TRANSITION_IN_PROGRESS: string = 'PRESENTATION_TRANSITION_IN_PROGRESS';
  /** 已经处于 DEMO 模式 */
  static readonly ALREADY_ACTIVE: string = 'PRESENTATION_ALREADY_ACTIVE';
  /** 已经处于 NORMAL 模式 */
  static readonly ALREADY_NORMAL: string = 'PRESENTATION_ALREADY_NORMAL';
  /** Camera Controls 恢复失败(仅 warning,仍进入 DEMO) */
  static readonly CAMERA_CONTROLS_WARNING: string = 'PRESENTATION_CAMERA_CONTROLS_WARNING';
  /** 保存的面板状态无效,恢复为默认值 */
  static readonly PANEL_STATE_INVALID: string = 'PRESENTATION_PANEL_STATE_INVALID';
  /** 页面已销毁 */
  static readonly PAGE_DISPOSED: string = 'PRESENTATION_PAGE_DISPOSED';
}
