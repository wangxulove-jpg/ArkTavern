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
/**
 * Runtime 渲染 Profile (Phase 4B-1)。
 *
 * 同一个 vrmviewer 页面在不同宿主场景下需要不同渲染表现:
 *   - VIEWER: VRM Viewer 普通模式,深色实体背景,Grid 可见,Canvas 不透明
 *   - CHAT_STAGE: 聊天页面透明 Avatar Stage,Scene 背景为 null,
 *     Canvas 透明,Grid 隐藏,相机控制默认禁用
 *
 * Profile 切换不修改三个业务 Runtime Controller,只影响 Scene/Core/Renderer。
 */
export enum ArkWebRenderProfile {
  VIEWER = 'VIEWER',
  CHAT_STAGE = 'CHAT_STAGE'
}

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
  resourceId: string;
  duration: number;
  currentTime: number;
  playbackSpeed: number;
  loop: boolean;
  loadGeneration: number;
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
  public static readonly DEPENDENCY_VERSION_MISMATCH: string = 'ANIMATION_DEPENDENCY_VERSION_MISMATCH';
  public static readonly DEPENDENCY_EXPORT_MISSING: string = 'ANIMATION_DEPENDENCY_EXPORT_MISSING';
  public static readonly DEPENDENCY_BUILD_FAILED: string = 'ANIMATION_DEPENDENCY_BUILD_FAILED';
  public static readonly DEPENDENCY_LICENSE_MISSING: string = 'ANIMATION_DEPENDENCY_LICENSE_MISSING';
  // Phase 3A — VRMA 文件导入与最小播放闭环
  public static readonly RESOURCE_INVALID: string = 'ANIMATION_RESOURCE_INVALID';
  public static readonly RESOURCE_URL_INVALID: string = 'ANIMATION_RESOURCE_URL_INVALID';
  public static readonly RESOURCE_SIZE_INVALID: string = 'ANIMATION_RESOURCE_SIZE_INVALID';
  public static readonly LOAD_IN_PROGRESS: string = 'ANIMATION_LOAD_IN_PROGRESS';
  public static readonly DATA_MISSING: string = 'ANIMATION_DATA_MISSING';
  public static readonly CLIP_CREATION_FAILED: string = 'ANIMATION_CLIP_CREATION_FAILED';
  public static readonly CLIP_INVALID: string = 'ANIMATION_CLIP_INVALID';
  public static readonly CLIP_EMPTY: string = 'ANIMATION_CLIP_EMPTY';
  public static readonly NOT_READY: string = 'ANIMATION_NOT_READY';
  public static readonly ALREADY_PLAYING: string = 'ANIMATION_ALREADY_PLAYING';
  public static readonly ACTION_MISSING: string = 'ANIMATION_ACTION_MISSING';
  public static readonly PAUSE_INVALID_STATE: string = 'ANIMATION_PAUSE_INVALID_STATE';
  public static readonly STOP_INVALID_STATE: string = 'ANIMATION_STOP_INVALID_STATE';
  public static readonly POSE_RESET_WARNING: string = 'ANIMATION_POSE_RESET_WARNING';
  public static readonly STALE_RESULT: string = 'ANIMATION_STALE_RESULT';
  public static readonly LOAD_FAILED: string = 'ANIMATION_LOAD_FAILED';
}

/**
 * Phase 3A 依赖补齐: 动画系统依赖状态(只读)。
 *
 * 与 Web 端 ViewerAnimationController.getDependencyState() 返回对象字段一一对应。
 * 供 Debug Tab / Animation Tab 显示 three-vrm-animation 依赖可用性。
 *
 * 不暴露:
 * - Node 模块路径
 * - 本机绝对路径
 * - 完整 package.json
 * - 许可证全文
 */
export interface ArkWebAnimationDependencyState {
  available: boolean;
  packageName: string;
  version: string;
  loaderAvailable: boolean;
  clipFactoryAvailable: boolean;
  runtimeNetworkRequired: boolean;
}

/**
 * Phase 3A — VRMA 文件导入与最小播放闭环: 已准备的动画资源。
 *
 * 由 ArkWebAnimationResourceProvider.registerFile() 产出,
 * 传给 JavaScript loadAnimationResource() 时只包含:
 *   publicUrl / displayName / size / mimeType / resourceId
 *
 * cachePath 只能存在于 ArkTS 内部,不传给 JavaScript。
 *
 * 规范 §十一。
 */
export interface ArkWebPreparedAnimationResource {
  /** 资源 ID (与缓存文件名一致, 不透明)。 */
  resourceId: string;
  /** 受控内部 URL: https://ark-tavern.local/animation/<resourceId>。 */
  publicUrl: string;
  /** 用户可读显示名。 */
  displayName: string;
  /** MIME 类型 (固定为 model/gltf-binary)。 */
  mimeType: string;
  /** 文件字节数。 */
  size: number;
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
    'getAnimationDebugState',
    // Phase 3A 依赖补齐: 动画系统依赖状态只读查询
    'getAnimationDependencyState',
    // Phase 3A — VRMA 文件导入与最小播放闭环: 动画加载与播放控制
    'loadAnimationResource',
    'playAnimation',
    'pauseAnimation',
    'stopAnimation',
    // Phase 3D-2 — JSON 姿势解析、应用与恢复
    'applyPose',
    'resetPose',
    'getPoseState',
    'getPoseDebugState',
    // Phase 3E-1 — VRM 表情系统(枚举 / 设置 / 清除 / 状态查询)
    'getAvailableExpressions',
    'setExpression',
    'resetExpression',
    'getExpressionState',
    'getExpressionDebugState',
    // Phase 3E-2 — 表情别名映射、临时表情与自动恢复
    'setTemporaryExpression',
    'cancelTemporaryExpression',
    'getTemporaryExpressionState',
    'setExpressionByAlias',
    'setTemporaryExpressionByAlias',
    'resolveExpressionAlias'
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
  /** Final Acceptance Fix: OrbitControls 最小距离 */
  minDistance?: number;
  /** Final Acceptance Fix: OrbitControls 最大距离 */
  maxDistance?: number;
  /** Final Acceptance Fix: 当前模型包围球半径 */
  modelBoundingRadius?: number;
  /** Final Acceptance Fix: 最近一次裁剪更新原因 */
  lastClipUpdateReason?: string;
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
 * Phase 4B-2R: fitAvatarFullBody 可选参数载荷。
 *
 * 用于构造传给 Web 端的 paramsJson, 控制模型垂直占比。
 *   - fillRatio=0.78 → margin=1/0.78 (模型占垂直约 78%)
 */
export interface ArkWebFitAvatarFullBodyParams {
  /** 模型垂直占比 (0 < fillRatio < 1) */
  fillRatio: number;
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

// ===== Phase 3D-2: JSON 姿势系统类型 =====

/**
 * Phase 3D-2: 姿势系统状态机(与 Web 端 ViewerPoseController.PoseState 对齐)。
 *
 * 状态流转:
 *   IDLE → APPLIED (applyPose 成功)
 *   IDLE → FAILED  (applyPose 失败,可重新应用)
 *   APPLIED → APPLIED (重复应用,直接替换)
 *   APPLIED → IDLE (resetPose 成功)
 *   APPLIED → FAILED (applyPose 失败)
 *   任意 → DISPOSED (dispose)
 *
 * 姿势错误不得导致 ViewerState = FAILED / ModelState = FAILED / AnimationState = FAILED。
 */
export enum ArkWebPoseState {
  /** 初始状态或已恢复 */
  IDLE = 'IDLE',
  /** 已应用姿势 */
  APPLIED = 'APPLIED',
  /** 应用失败 (可重试) */
  FAILED = 'FAILED',
  /** 已销毁 */
  DISPOSED = 'DISPOSED'
}

/**
 * Phase 3D-2: 姿势系统错误代码(与 Web 端 ViewerPoseController.PoseErrorCode 对齐)。
 *
 * 姿势错误只影响 PoseState,不影响 ViewerState / ModelState / AnimationState。
 */
export class ArkWebPoseErrorCode {
  /** 控制器已销毁 */
  static readonly CONTROLLER_DISPOSED: string = 'POSE_CONTROLLER_DISPOSED';
  /** 当前未绑定 VRM */
  static readonly VRM_MISSING: string = 'POSE_VRM_MISSING';
  /** VRM 对象无效 */
  static readonly VRM_INVALID: string = 'POSE_VRM_INVALID';
  /** 姿势数据非法 (非对象 / 缺字段 / 含禁止字段) */
  static readonly POSE_DATA_INVALID: string = 'POSE_DATA_INVALID';
  /** 未找到 bones/humanBones/pose 任一入口 */
  static readonly POSE_BONES_MISSING: string = 'POSE_BONES_MISSING';
  /** rotation 字段非法 (非数组/对象,长度错误,非有限数,长度接近 0) */
  static readonly POSE_ROTATION_INVALID: string = 'POSE_ROTATION_INVALID';
  /** 没有有效骨骼可应用 (全部被过滤) */
  static readonly POSE_NO_VALID_BONES: string = 'POSE_NO_VALID_BONES';
  /** humanoid 缺失或 API 不完整 */
  static readonly HUMANOID_MISSING: string = 'POSE_HUMANOID_MISSING';
  /** Phase 3D-2R: 旋转顺序不支持 */
  static readonly POSE_ROTATION_ORDER_UNSUPPORTED: string = 'POSE_ROTATION_ORDER_UNSUPPORTED';
  /** Phase 3D-2R: 坐标空间不支持 */
  static readonly POSE_COORDINATE_SPACE_UNSUPPORTED: string = 'POSE_COORDINATE_SPACE_UNSUPPORTED';
  /** Phase 3D-2R: position 字段非法 */
  static readonly POSE_POSITION_INVALID: string = 'POSE_POSITION_INVALID';
  /** Phase 3D-2R: 姿势转换失败 */
  static readonly POSE_CONVERSION_FAILED: string = 'POSE_CONVERSION_FAILED';
}

/**
 * Phase 3D-2: 姿势系统状态快照 (getPoseState 返回值)。
 *
 * 不暴露路径、文件描述符或 VRM 对象引用。
 */
export interface ArkWebPoseStatePayload {
  /** 当前姿势状态 */
  state: ArkWebPoseState;
  /** 当前已应用的 poseId (空字符串表示无应用) */
  poseId: string;
  /** 当前已应用的 displayName */
  displayName: string;
  /** 最近一次应用的有效骨骼数 */
  appliedBoneCount: number;
  /** 最近一次应用的忽略骨骼数 */
  ignoredBoneCount: number;
}

/**
 * Phase 3D-2: 姿势系统调试状态快照 (getPoseDebugState 返回值)。
 *
 * 比 ArkWebPoseStatePayload 多出 lastIgnoredBones / lastErrorCode / lastErrorMessage,
 * 供 Debug Tab 显示。
 */
export interface ArkWebPoseDebugState {
  /** 当前姿势状态 */
  state: ArkWebPoseState;
  /** 是否已绑定 VRM */
  vrmBound: boolean;
  /** 当前已应用的 poseId */
  currentPoseId: string;
  /** 当前已应用的 displayName */
  currentDisplayName: string;
  /** 最近一次应用的有效骨骼数 */
  appliedBoneCount: number;
  /** 最近一次应用的忽略骨骼数 */
  ignoredBoneCount: number;
  /** 最近一次忽略的骨骼名列表 (前 20 条) */
  lastIgnoredBones: string[];
  /** 最近一次错误码 (空字符串表示无错误) */
  lastErrorCode: string;
  /** 最近一次错误消息 */
  lastErrorMessage: string;
  /** Phase 3D-2R: 版本同步转换的骨骼数 */
  convertedBoneCount: number;
  /** Phase 3D-2R: 来源格式 (bones/humanBones/pose/data) */
  sourceFormat: string;
  /** Phase 3D-2R: 坐标空间 */
  coordinateSpace: string;
  /** Phase 3D-2R: 旋转顺序 */
  rotationOrder: string;
  /** Phase 3D-2R: 是否存在 position */
  positionPresent: boolean;
  /** Phase 3D-2R: 是否应用了 position */
  positionApplied: boolean;
}

/**
 * Phase 3D-2: 传给 JavaScript applyPose 的受控姿势数据。
 *
 * ArkTS 从持久 JSON 文件读取后,必须构造此对象再序列化为 JSON 字符串传给 Web。
 * 不得包含 absolutePath / relativePath / filesDir / 文件描述符 / 原始 URI。
 */
export interface ArkWebPoseData {
  /** 姿势 ID (与持久资产 poseId 一致) */
  poseId: string;
  /** 显示名 */
  displayName: string;
  /** 骨骼映射 (key=骨骼名, value=骨骼条目) */
  bones: Record<string, ArkWebPoseBoneEntry>;
  /** Phase 3D-2R: 来源姿势 JSON 的 vrmVersion (空字符串表示未指定) */
  vrmVersion: string;
}

/**
 * Phase 3D-2: 单个骨骼的姿势条目 (本阶段只处理 rotation)。
 */
export interface ArkWebPoseBoneEntry {
  /** 旋转四元数 [x, y, z, w] */
  rotation: number[];
}

/**
 * Phase 3D-2: 解析 getPoseState 返回的 JSON 字符串。
 * 解析失败时返回 null。
 */
export function parsePoseState(jsonStr: string): ArkWebPoseStatePayload | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    const stateStr: string = (obj['state'] as string) || 'IDLE';
    let state: ArkWebPoseState = ArkWebPoseState.IDLE;
    switch (stateStr) {
      case 'IDLE':
        state = ArkWebPoseState.IDLE;
        break;
      case 'APPLIED':
        state = ArkWebPoseState.APPLIED;
        break;
      case 'FAILED':
        state = ArkWebPoseState.FAILED;
        break;
      case 'DISPOSED':
        state = ArkWebPoseState.DISPOSED;
        break;
      default:
        state = ArkWebPoseState.IDLE;
    }
    return {
      state: state,
      poseId: (obj['poseId'] as string) || '',
      displayName: (obj['displayName'] as string) || '',
      appliedBoneCount: (obj['appliedBoneCount'] as number) || 0,
      ignoredBoneCount: (obj['ignoredBoneCount'] as number) || 0
    };
  } catch (e) {
    return null;
  }
}

/**
 * Phase 3D-2: 解析 getPoseDebugState 返回的 JSON 字符串。
 * 解析失败时返回 null。
 */
export function parsePoseDebugState(jsonStr: string): ArkWebPoseDebugState | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    const debugObj: Record<string, Object> = (obj['debugState'] as Record<string, Object>) || {} as Record<string, Object>;
    const stateStr: string = (debugObj['state'] as string) || 'IDLE';
    let state: ArkWebPoseState = ArkWebPoseState.IDLE;
    switch (stateStr) {
      case 'IDLE':
        state = ArkWebPoseState.IDLE;
        break;
      case 'APPLIED':
        state = ArkWebPoseState.APPLIED;
        break;
      case 'FAILED':
        state = ArkWebPoseState.FAILED;
        break;
      case 'DISPOSED':
        state = ArkWebPoseState.DISPOSED;
        break;
      default:
        state = ArkWebPoseState.IDLE;
    }
    const ignoredBonesRaw: Object = debugObj['lastIgnoredBones'];
    let ignoredBones: string[] = [];
    if (Array.isArray(ignoredBonesRaw)) {
      ignoredBones = (ignoredBonesRaw as Object[]).map((v: Object): string => String(v));
    }
    return {
      state: state,
      vrmBound: !!debugObj['vrmBound'],
      currentPoseId: (debugObj['currentPoseId'] as string) || '',
      currentDisplayName: (debugObj['currentDisplayName'] as string) || '',
      appliedBoneCount: (debugObj['appliedBoneCount'] as number) || 0,
      ignoredBoneCount: (debugObj['ignoredBoneCount'] as number) || 0,
      lastIgnoredBones: ignoredBones,
      lastErrorCode: (debugObj['lastErrorCode'] as string) || '',
      lastErrorMessage: (debugObj['lastErrorMessage'] as string) || '',
      convertedBoneCount: (debugObj['convertedBoneCount'] as number) || 0,
      sourceFormat: (debugObj['sourceFormat'] as string) || '',
      coordinateSpace: (debugObj['coordinateSpace'] as string) || '',
      rotationOrder: (debugObj['rotationOrder'] as string) || '',
      positionPresent: !!debugObj['positionPresent'],
      positionApplied: !!debugObj['positionApplied']
    };
  } catch (e) {
    return null;
  }
}

// ===== Phase 3E-1: VRM 表情系统类型 =====

/**
 * Phase 3E-1: 表情系统状态机(与 Web 端 ViewerExpressionController.ExpressionState 对齐)。
 *
 * 状态流转:
 *   UNBOUND → READY (bindVrm 成功且 expressionManager 存在)
 *   UNBOUND → UNBOUND (bindVrm 成功但 expressionManager 缺失)
 *   READY → APPLIED (setExpression 成功)
 *   READY → FAILED (setExpression 失败,可重试)
 *   APPLIED → READY (resetExpression 成功)
 *   APPLIED → APPLIED (重复 setExpression,直接替换)
 *   APPLIED → FAILED (setExpression 失败)
 *   任意 → DISPOSED (dispose)
 *
 * 表情错误不得导致 ViewerState = FAILED / ModelState = FAILED / AnimationState = FAILED / PoseState = FAILED。
 */
export enum ArkWebExpressionState {
  /** 未绑定 VRM (初始状态或 expressionManager 缺失) */
  UNBOUND = 'UNBOUND',
  /** 已绑定 VRM 且 expressionManager 就绪,可设置表情 */
  READY = 'READY',
  /** 已应用单个业务表情 */
  APPLIED = 'APPLIED',
  /** 应用失败 (可重试) */
  FAILED = 'FAILED',
  /** 已销毁 */
  DISPOSED = 'DISPOSED'
}

/**
 * Phase 3E-1: 表情系统错误代码(与 Web 端 ViewerExpressionController.ExpressionErrorCode 对齐)。
 *
 * 表情错误只影响 ExpressionState,不影响 ViewerState / ModelState / AnimationState / PoseState。
 */
export class ArkWebExpressionErrorCode {
  /** 控制器已销毁 */
  static readonly CONTROLLER_DISPOSED: string = 'EXPRESSION_CONTROLLER_DISPOSED';
  /** 当前未绑定 VRM */
  static readonly VRM_MISSING: string = 'EXPRESSION_VRM_MISSING';
  /** expressionManager 缺失或 API 不完整 */
  static readonly MANAGER_MISSING: string = 'EXPRESSION_MANAGER_MISSING';
  /** name 字段非法 (非字符串 / 空字符串 / 含禁止字段) */
  static readonly NAME_INVALID: string = 'EXPRESSION_NAME_INVALID';
  /** 表情名在当前模型中不存在 */
  static readonly NOT_FOUND: string = 'EXPRESSION_NOT_FOUND';
  /** weight 字段非法 (非有限数 / 超出 0..1) */
  static readonly WEIGHT_INVALID: string = 'EXPRESSION_WEIGHT_INVALID';
  /** 应用表情失败 (setValue / update 抛出异常) */
  static readonly APPLY_FAILED: string = 'EXPRESSION_APPLY_FAILED';
  /** Phase 3E-2: 业务 expressionId 无法解析到模型真实 expressionName */
  static readonly ALIAS_NOT_RESOLVED: string = 'EXPRESSION_ALIAS_NOT_RESOLVED';
  /** Phase 3E-2: durationMs 超出 100..30000 范围 */
  static readonly DURATION_INVALID: string = 'EXPRESSION_DURATION_INVALID';
  /** Phase 3E-2: restorePolicy 非 PREVIOUS / RESET */
  static readonly RESTORE_POLICY_INVALID: string = 'EXPRESSION_RESTORE_POLICY_INVALID';
  /** Phase 3E-2: 临时表情应用失败 (setExpression 在临时上下文中失败) */
  static readonly TEMPORARY_APPLY_FAILED: string = 'EXPRESSION_TEMPORARY_APPLY_FAILED';
}

/**
 * Phase 3E-2: 临时表情恢复策略 (与 Web 端 TemporaryRestorePolicy 对齐)。
 *
 * - PREVIOUS: 到期恢复临时表情开始前的业务表情 (若无则 resetExpression)
 * - RESET: 到期清除业务表情 (resetExpression)
 */
export class ArkWebTemporaryRestorePolicy {
  static readonly PREVIOUS: string = 'PREVIOUS';
  static readonly RESET: string = 'RESET';

  static isValid(value: string): boolean {
    return value === ArkWebTemporaryRestorePolicy.PREVIOUS ||
      value === ArkWebTemporaryRestorePolicy.RESET;
  }
}

/**
 * Phase 3E-2: 传给 JavaScript setTemporaryExpression 的受控参数。
 *
 * 序列化为 JSON 字符串后传给 Web 端。
 * 不得包含 absolutePath / relativePath / filesDir / 文件描述符 / 原始 URI。
 */
export interface ArkWebSetTemporaryExpressionParams {
  /** 表情名 (必须真实存在于 expressionManager,非业务 ID) */
  name: string;
  /** 权重 (0..1) */
  weight: number;
  /** 持续时间 (100..30000 ms) */
  durationMs: number;
  /** 恢复策略 (PREVIOUS / RESET) */
  restorePolicy: string;
}

/**
 * Phase 3E-2: 传给 JavaScript setExpressionByAlias 的受控参数。
 *
 * 序列化为 JSON 字符串后传给 Web 端。
 * aliases 由 ArkTS AssetLibrary.getExpressionAliases 读取,不直接由 UI 构造。
 */
export interface ArkWebSetExpressionByAliasParams {
  /** 业务 expressionId (neutral/happy/angry/sad/relaxed/surprised) */
  expressionId: string;
  /** 持久化别名映射 (业务 ID → 模型真实 expressionName) */
  aliases: Record<string, string>;
  /** 权重 (0..1) */
  weight: number;
}

/**
 * Phase 3E-2: 传给 JavaScript setTemporaryExpressionByAlias 的受控参数。
 */
export interface ArkWebSetTemporaryExpressionByAliasParams {
  /** 业务 expressionId (neutral/happy/angry/sad/relaxed/surprised) */
  expressionId: string;
  /** 持久化别名映射 */
  aliases: Record<string, string>;
  /** 权重 (0..1) */
  weight: number;
  /** 持续时间 (100..30000 ms) */
  durationMs: number;
  /** 恢复策略 (PREVIOUS / RESET) */
  restorePolicy: string;
}

/**
 * Phase 3E-2: 传给 JavaScript resolveExpressionAlias 的受控参数。
 */
export interface ArkWebResolveExpressionAliasParams {
  /** 业务 expressionId */
  expressionId: string;
  /** 持久化别名映射 */
  aliases: Record<string, string>;
}

/**
 * Phase 3E-2: resolveExpressionAlias 返回值。
 *
 * success=true 时 resolvedName 为模型真实 expressionName;
 * success=false 时 resolvedName 为空字符串。
 */
export interface ArkWebExpressionAliasResolution {
  success: boolean;
  resolvedName: string;
}

/**
 * Phase 3E-2: 临时表情状态快照 (getTemporaryExpressionState 返回值)。
 *
 * 供 UI 显示和测试验证。
 */
export interface ArkWebTemporaryExpressionState {
  /** 当前临时表情名 (空字符串表示无临时表情) */
  temporaryExpressionName: string;
  /** 当前临时表情权重 */
  temporaryExpressionWeight: number;
  /** 临时表情到期时间戳 (0 表示无任务) */
  temporaryExpiresAt: number;
  /** 恢复策略 (PREVIOUS / RESET) */
  temporaryRestorePolicy: string;
  /** 临时表情开始前保存的业务表情名 */
  restoreExpressionName: string;
  /** 临时表情开始前保存的业务表情权重 */
  restoreExpressionWeight: number;
  /** 临时表情代次 */
  temporaryGeneration: number;
}

/**
 * Phase 3E-1: 单个可用表情项 (getAvailableExpressions 返回值元素)。
 *
 * 不暴露 VRMExpression 对象引用或 Three.js 对象。
 */
export interface ArkWebAvailableExpression {
  /** 表情名 (与 expressionManager 中的 expressionName 一致) */
  name: string;
  /** 当前权重 (0..1,读取自 expression.weight) */
  weight: number;
  /** 是否为 VRM 预设表情 (aa/ih/ou/ee/oh/blink/happy/angry/sad/relaxed/lookUp/surprised/lookDown/lookLeft/lookRight/blinkLeft/blinkRight/neutral) */
  isPreset: boolean;
}

/**
 * Phase 3E-1: 表情系统状态快照 (getExpressionState 返回值)。
 */
export interface ArkWebExpressionStatePayload {
  /** 当前表情状态 */
  state: ArkWebExpressionState;
  /** 当前已应用的业务表情名 (空字符串表示无应用) */
  currentExpressionName: string;
  /** 当前已应用的业务表情权重 */
  currentExpressionWeight: number;
  /** expressionManager 是否就绪 (VRM 已绑定且 API 完整) */
  expressionManagerReady: boolean;
}

/**
 * Phase 3E-1: 表情系统调试状态快照 (getExpressionDebugState 返回值)。
 *
 * 供 Debug Tab 显示。
 */
export interface ArkWebExpressionDebugState {
  /** 当前表情状态 */
  state: ArkWebExpressionState;
  /** 是否已绑定 VRM */
  vrmBound: boolean;
  /** expressionManager 是否就绪 */
  expressionManagerReady: boolean;
  /** 可用表情数量 */
  availableExpressionCount: number;
  /** 当前已应用的业务表情名 */
  currentExpressionName: string;
  /** 当前已应用的业务表情权重 */
  currentExpressionWeight: number;
  /** 最近一次错误码 (空字符串表示无错误) */
  lastErrorCode: string;
  /** 最近一次错误消息 */
  lastErrorMessage: string;
  /** 口型通道是否保留 (YES=true / NO=false) */
  lipSyncChannelsPreserved: boolean;
  /** Phase 3E-2: 当前临时表情名 (空字符串表示无临时表情) */
  temporaryExpressionName: string;
  /** Phase 3E-2: 当前临时表情权重 */
  temporaryExpressionWeight: number;
  /** Phase 3E-2: 临时表情到期时间戳 (0 表示无任务) */
  temporaryExpiresAt: number;
  /** Phase 3E-2: 临时表情恢复策略 (PREVIOUS / RESET) */
  temporaryRestorePolicy: string;
  /** Phase 3E-2: 临时表情开始前保存的业务表情名 */
  restoreExpressionName: string;
  /** Phase 3E-2: 临时表情开始前保存的业务表情权重 */
  restoreExpressionWeight: number;
  /** Phase 3E-2: 临时表情代次 (用于让旧 timeout 失效) */
  temporaryGeneration: number;
  /** Phase 3E-2: 是否有活跃的 setTimeout 句柄 */
  temporaryTimerActive: boolean;
}

/**
 * Phase 3E-1: 传给 JavaScript setExpression 的受控参数。
 *
 * 序列化为 JSON 字符串后传给 Web 端。
 * 不得包含 absolutePath / relativePath / filesDir / 文件描述符 / 原始 URI。
 */
export interface ArkWebSetExpressionParams {
  /** 表情名 (必须真实存在于 expressionManager) */
  name: string;
  /** 权重 (0..1) */
  weight: number;
}

/**
 * Phase 3E-1: 解析 getAvailableExpressions 返回的 JSON 字符串。
 * 解析失败时返回 null。
 */
export function parseAvailableExpressions(jsonStr: string): ArkWebAvailableExpression[] | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    if (!obj['success']) {
      return null;
    }
    const expressionsRaw: Object = obj['expressions'];
    if (!Array.isArray(expressionsRaw)) {
      return [];
    }
    const result: ArkWebAvailableExpression[] = [];
    const arr: Object[] = expressionsRaw as Object[];
    for (let i = 0; i < arr.length; i++) {
      const item: Record<string, Object> = arr[i] as Record<string, Object>;
      result.push({
        name: (item['name'] as string) || '',
        weight: typeof item['weight'] === 'number' ? (item['weight'] as number) : 0,
        isPreset: !!item['isPreset']
      });
    }
    return result;
  } catch (e) {
    return null;
  }
}

/**
 * Phase 3E-1: 解析 getExpressionState 返回的 JSON 字符串。
 * 解析失败时返回 null。
 */
export function parseExpressionState(jsonStr: string): ArkWebExpressionStatePayload | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    const stateStr: string = (obj['state'] as string) || 'UNBOUND';
    let state: ArkWebExpressionState = ArkWebExpressionState.UNBOUND;
    switch (stateStr) {
      case 'UNBOUND':
        state = ArkWebExpressionState.UNBOUND;
        break;
      case 'READY':
        state = ArkWebExpressionState.READY;
        break;
      case 'APPLIED':
        state = ArkWebExpressionState.APPLIED;
        break;
      case 'FAILED':
        state = ArkWebExpressionState.FAILED;
        break;
      case 'DISPOSED':
        state = ArkWebExpressionState.DISPOSED;
        break;
      default:
        state = ArkWebExpressionState.UNBOUND;
    }
    return {
      state: state,
      currentExpressionName: (obj['currentExpressionName'] as string) || '',
      currentExpressionWeight: typeof obj['currentExpressionWeight'] === 'number'
        ? (obj['currentExpressionWeight'] as number) : 0,
      expressionManagerReady: !!obj['expressionManagerReady']
    };
  } catch (e) {
    return null;
  }
}

/**
 * Phase 3E-1: 解析 getExpressionDebugState 返回的 JSON 字符串。
 * 解析失败时返回 null。
 */
export function parseExpressionDebugState(jsonStr: string): ArkWebExpressionDebugState | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    const debugObj: Record<string, Object> = (obj['debugState'] as Record<string, Object>) ||
      {} as Record<string, Object>;
    const stateStr: string = (debugObj['state'] as string) || 'UNBOUND';
    let state: ArkWebExpressionState = ArkWebExpressionState.UNBOUND;
    switch (stateStr) {
      case 'UNBOUND':
        state = ArkWebExpressionState.UNBOUND;
        break;
      case 'READY':
        state = ArkWebExpressionState.READY;
        break;
      case 'APPLIED':
        state = ArkWebExpressionState.APPLIED;
        break;
      case 'FAILED':
        state = ArkWebExpressionState.FAILED;
        break;
      case 'DISPOSED':
        state = ArkWebExpressionState.DISPOSED;
        break;
      default:
        state = ArkWebExpressionState.UNBOUND;
    }
    return {
      state: state,
      vrmBound: !!debugObj['vrmBound'],
      expressionManagerReady: !!debugObj['expressionManagerReady'],
      availableExpressionCount: typeof debugObj['availableExpressionCount'] === 'number'
        ? (debugObj['availableExpressionCount'] as number) : 0,
      currentExpressionName: (debugObj['currentExpressionName'] as string) || '',
      currentExpressionWeight: typeof debugObj['currentExpressionWeight'] === 'number'
        ? (debugObj['currentExpressionWeight'] as number) : 0,
      lastErrorCode: (debugObj['lastErrorCode'] as string) || '',
      lastErrorMessage: (debugObj['lastErrorMessage'] as string) || '',
      lipSyncChannelsPreserved: debugObj['lipSyncChannelsPreserved'] !== false,
      // Phase 3E-2: 临时表情字段
      temporaryExpressionName: (debugObj['temporaryExpressionName'] as string) || '',
      temporaryExpressionWeight: typeof debugObj['temporaryExpressionWeight'] === 'number'
        ? (debugObj['temporaryExpressionWeight'] as number) : 0,
      temporaryExpiresAt: typeof debugObj['temporaryExpiresAt'] === 'number'
        ? (debugObj['temporaryExpiresAt'] as number) : 0,
      temporaryRestorePolicy: (debugObj['temporaryRestorePolicy'] as string) || 'PREVIOUS',
      restoreExpressionName: (debugObj['restoreExpressionName'] as string) || '',
      restoreExpressionWeight: typeof debugObj['restoreExpressionWeight'] === 'number'
        ? (debugObj['restoreExpressionWeight'] as number) : 0,
      temporaryGeneration: typeof debugObj['temporaryGeneration'] === 'number'
        ? (debugObj['temporaryGeneration'] as number) : 0,
      temporaryTimerActive: !!debugObj['temporaryTimerActive']
    };
  } catch (e) {
    return null;
  }
}

/**
 * Phase 3E-2: 解析 getTemporaryExpressionState 返回的 JSON 字符串。
 * 解析失败时返回 null。
 */
export function parseTemporaryExpressionState(jsonStr: string): ArkWebTemporaryExpressionState | null {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    return {
      temporaryExpressionName: (obj['temporaryExpressionName'] as string) || '',
      temporaryExpressionWeight: typeof obj['temporaryExpressionWeight'] === 'number'
        ? (obj['temporaryExpressionWeight'] as number) : 0,
      temporaryExpiresAt: typeof obj['temporaryExpiresAt'] === 'number'
        ? (obj['temporaryExpiresAt'] as number) : 0,
      temporaryRestorePolicy: (obj['temporaryRestorePolicy'] as string) || 'PREVIOUS',
      restoreExpressionName: (obj['restoreExpressionName'] as string) || '',
      restoreExpressionWeight: typeof obj['restoreExpressionWeight'] === 'number'
        ? (obj['restoreExpressionWeight'] as number) : 0,
      temporaryGeneration: typeof obj['temporaryGeneration'] === 'number'
        ? (obj['temporaryGeneration'] as number) : 0
    };
  } catch (e) {
    return null;
  }
}

/**
 * Phase 3E-2: 解析 resolveExpressionAlias 返回的 JSON 字符串。
 *
 * ViewerCore.resolveExpressionAlias 返回:
 *   - 成功: { success: true, expressionName: "Joy" }
 *   - 失败: { success: false, error: { code, message } }
 *
 * 解析失败或 success=false 时 resolvedName 为空字符串。
 */
export function parseExpressionAliasResolution(jsonStr: string): ArkWebExpressionAliasResolution {
  try {
    const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
    if (!obj['success']) {
      return { success: false, resolvedName: '' };
    }
    const name: string = (obj['expressionName'] as string) || '';
    if (name.length > 0) {
      return { success: true, resolvedName: name };
    }
    return { success: false, resolvedName: '' };
  } catch (e) {
    return { success: false, resolvedName: '' };
  }
}
