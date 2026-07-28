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
 * 动画播放状态(Phase 3+ 使用,Phase 1A 仅声明)。
 */
export enum ArkWebAnimationState {
  NOT_LOADED = 'NOT_LOADED',
  LOADING = 'LOADING',
  PLAYING = 'PLAYING',
  PAUSED = 'PAUSED',
  STOPPED = 'STOPPED',
  FAILED = 'FAILED'
}

/**
 * Bridge 错误代码(与 Web 端 ViewerBridge.notifyViewerError 的 code 字段对齐)。
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
    'clearPreparedModelLoadResult'
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
