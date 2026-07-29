/**
 * VrmViewerPage VRM 查看器页面(Phase 1D-2A: 缓存模型向 ArkWeb 暴露与传输协议)
 *
 * 实现路线:ArkUI 原生外壳 + ArkWeb 加载本地 Viewer 页面 + Figure 源码适配。
 * 原因:ArkGraphics3D 当前缺少 SkinnedMesh / Skeleton / VRM Extension 等 BLOCKING 能力,
 *       见 docs/vrm/ARKGRAPHICS3D_API_MAPPING.md。
 *
 * Phase 1D-2A 范围:
 * - 接入 ArkWebModelResourceProvider(管理缓存模型资源)
 * - Web 组件 onInterceptRequest 回调:拦截 ark-tavern.local 资源请求
 * - 导入成功后注册资源,生成受控 URL(不调用 loadModel)
 * - 页面显示资源 URL / 大小 / MIME / 等待加载状态
 * - 不调用 JavaScript loadModel(Phase 1D-2B)
 * - 不替换默认 VRM
 *
 * Phase 1D-1 范围(已完成):
 * - 接入"导入模型"按钮(系统文件选择器)
 * - 显示导入状态、文件名、格式、大小、缓存准备状态、glTF 依赖状态
 * - 选择完成后仅显示"模型文件已准备,等待 Phase 1D-2 加载"
 *
 * 页面职责:
 * - 创建 ArkWebVrmViewerController
 * - 创建 ArkWebFileImportController(Phase 1D-1)
 * - 创建 ArkWebModelResourceProvider(Phase 1D-2A)
 * - 挂载 Web 组件渲染区域 + onInterceptRequest
 * - 显示状态与错误
 * - 连接聚焦/重置按钮(调用 resetCamera)
 * - 连接"导入模型"按钮(调用 pickModelFile + registerFile)
 * - 页面销毁时调用 dispose
 *
 * 结构(Stack overlay,预览区域始终不被压缩):
 * Stack
 * ├── 全屏预览区域(Web 组件,最底层,100% 尺寸)
 * ├── 顶部工具栏(返回 / 模型名 / 普通·演示模式 / 更多)
 * ├── 右侧快捷工具栏(聚焦 / 重置 / 截图 / 设置)
 * └── 底部控制抽屉(模型 / 姿势 / 动画 / 表情 / 物理 / 场景 / 调试)
 *
 * Reference:
 * - figure-main: index.html (整体页面结构与工具栏)
 * - ownverse-vrm-viewer: analysis/VIEWER_ARCHITECTURE.md (UI 层绑定)
 * - HarmonyOS ArkWeb: Web 组件 + WebviewController + onInterceptRequest
 * - HarmonyOS CoreFileKit: DocumentViewPicker / fileIo (Phase 1D-1)
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import {
  ArkWebViewerConfig,
  ArkWebViewerState,
  WebPreparedResourceErrorCode,
  WebPreparedResourceState,
  ArkWebCameraState,
  ArkWebCameraTransitionResult,
  ArkWebCameraTransitionState,
  ARKWEB_CAMERA_SMOOTH_RESET_DEFAULT_DURATION,
  ARKWEB_CAMERA_TRANSITION_POLL_INTERVAL_MS,
  ARKWEB_CAMERA_TRANSITION_POLL_TIMEOUT_MS,
  parseCameraState,
  parseCameraTransitionResult,
  ScreenshotState,
  ScreenshotResult,
  ScreenshotErrorCode,
  createIdleScreenshotResult,
  ArkWebEnvironmentState,
  ARKWEB_ENVIRONMENT_POLL_INTERVAL_MS,
  ARKWEB_ENVIRONMENT_POLL_TIMEOUT_MS,
  PresentationMode,
  ArkWebPresentationErrorCode
} from '../vrmviewer/ArkWebVrmViewerTypes';
import {
  ArkWebViewerEventListener,
  ArkWebVrmViewerController
} from '../vrmviewer/ArkWebVrmViewerController';
import {
  ArkWebFileImportController
} from '../vrmviewer/ArkWebFileImportController';
import {
  GltfDependencyState,
  ImportedModelFile,
  ModelImportState
} from '../vrmviewer/ArkWebModelImportTypes';
import {
  ArkWebModelResourceProvider
} from '../vrmviewer/ArkWebModelResourceProvider';
import {
  ModelResourceProbeState,
  ModelResourceState,
  WebModelResource,
  extractOpaqueIdFromUrl,
  isModelResourceUrl
} from '../vrmviewer/ArkWebModelResourceTypes';
import {
  ArkWebModelImportStateStore,
  ImportStateRestoreResult
} from '../vrmviewer/ArkWebModelImportStateStore';
import {
  VrmRuntimeDiagnostic,
  VrmRuntimeStage
} from '../vrmviewer/ArkWebVrmRuntimeDiagnosticsTypes';
import {
  ArkWebScreenshotController
} from '../vrmviewer/ArkWebScreenshotController';

/** 抽屉状态 */
enum DrawerState {
  Collapsed = 'collapsed',
  Half = 'half',
  Expanded = 'expanded'
}

/** 抽屉 Tab */
enum ViewerTab {
  Model = 'model',
  Pose = 'pose',
  Animation = 'animation',
  Expression = 'expression',
  Physics = 'physics',
  Scene = 'scene',
  Debug = 'debug'
}

/**
 * ArkWeb Viewer 事件监听器包装。
 *
 * ArkTS struct 不能 implements 接口,通过此包装类持有回调函数,
 * 让 VrmViewerPage 在 aboutToAppear 中注入闭包更新 @State。
 */
class ViewerEventListener implements ArkWebViewerEventListener {
  onStateChangedFn: ((state: ArkWebViewerState, detail: string) => void) | null = null;
  onErrorFn: ((code: string, message: string) => void) | null = null;

  onStateChanged(state: ArkWebViewerState, detail: string): void {
    const fn = this.onStateChangedFn;
    if (fn !== null) {
      fn(state, detail);
    }
  }

  onError(code: string, message: string): void {
    const fn = this.onErrorFn;
    if (fn !== null) {
      fn(code, message);
    }
  }
}

@Entry
@Component
struct VrmViewerPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  // ===== UI 状态 =====
  // Phase 2H: 演示模式状态
  @State presentationMode: PresentationMode = PresentationMode.NORMAL;
  @State presentationTransitioning: boolean = false;
  @State activeTab: ViewerTab = ViewerTab.Model;
  @State drawerState: DrawerState = DrawerState.Half;
  @State backgroundOption: string = '#1A1A1A';
  @State showGrid: boolean = false;
  @State lightIntensity: number = 75;
  @State lastMessage: string = '';

  /** 页面高度(由根 Stack onAreaChange 捕获,用于计算抽屉高度) */
  @State pageHeight: number = 0;
  /** 预览区域高度(始终等于 pageHeight,用于验收报告) */
  @State previewHeight: number = 0;

  // ===== ArkWeb Viewer 状态(由 Controller 通过 Listener 回调更新) =====
  @State viewerState: ArkWebViewerState = ArkWebViewerState.UNINITIALIZED;
  @State viewerDetail: string = '未初始化';
  @State lastErrorCode: string = '';
  @State lastError: string = '';
  /** Web 组件是否已加载完成(用于触发 Web 重建) */
  @State webLoaded: boolean = false;
  /** Phase 1D-2C-2A: Viewer 重试进行中(防止重复点击) */
  @State retryInProgress: boolean = false;

  // ===== Phase 1D-1: 模型导入状态 =====
  /** 导入状态机(由 ImportController 驱动,通过轮询同步到 @State) */
  @State importState: ModelImportState = ModelImportState.IDLE;
  /** 当前已导入的文件元数据(成功后非 null) */
  @State importedFile: ImportedModelFile | null = null;
  /** 最近一次导入错误消息(空字符串表示无错误) */
  @State importLastError: string = '';
  /** 是否正在导入(防止重复点击) */
  @State importInProgress: boolean = false;

  // ===== Phase 1D-2A: 资源暴露状态 =====
  /** 资源 Provider 状态(EMPTY / READY / DISPOSED) */
  @State resourceState: ModelResourceState = ModelResourceState.EMPTY;
  /** 当前已注册的公共资源(可安全传给 JavaScript,不含 cachePath) */
  @State preparedResource: WebModelResource | null = null;
  /** 资源准备错误消息(空字符串表示无错误) */
  @State resourceLastError: string = '';

  // ===== Phase 1D-2C-2E-1: Web Prepared 资源状态 =====
  // 与 Native resourceState 解耦:
  // - resourceState === READY 只表示 Native ResourceProvider 已注册资源 URL
  // - webPreparedState === READY 表示 JavaScript keeper 已通过 prepareModelResource
  //   接收资源元数据并通过 getPreparedModelResource 回读校验
  /** Web 端 PreparedModelResourceKeeper 状态(EMPTY / PREPARING / READY / FAILED) */
  @State webPreparedState: WebPreparedResourceState = WebPreparedResourceState.EMPTY;
  /** Web 资源准备错误码(成功时为空字符串) */
  @State webPreparedErrorCode: string = '';
  /** Web 资源准备错误消息(成功时为空字符串) */
  @State webPreparedErrorMessage: string = '';
  /** prepare 代次(每次 ensurePreparedModelResource 递增,用于过期判断) */
  private prepareGeneration: number = 0;
  /** 是否正在调用 prepareModelResource + 回读(防止重复触发) */
  private prepareInProgress: boolean = false;
  /** 最近一次成功准备的资源 URL(用于自动探测前的一致性校验) */
  private lastPreparedResourceUrl: string = '';

  // ===== Phase 1D-2B-1: 资源探测状态 =====
  /** 探测状态机(NOT_PROBED / PROBING / VERIFIED / FAILED) */
  @State probeState: ModelResourceProbeState = ModelResourceProbeState.NOT_PROBED;
  /** 探测 HTTP 状态码(HEAD 200 = 成功;失败时为 0 或具体错误码) */
  @State probeStatusCode: number = 0;
  /** 探测响应 Content-Type(成功时与资源 MIME 一致) */
  @State probeMimeType: string = '';
  /** 探测响应 Content-Length(成功时与资源大小一致) */
  @State probeContentLength: number = -1;
  /** 探测响应 X-ArkTavern-Resource-Id(成功时与资源 ID 一致) */
  @State probeResourceId: string = '';
  /** 探测是否发生重定向(应为 false) */
  @State probeRedirected: boolean = false;
  /** 探测错误码(成功时为空字符串) */
  @State probeErrorCode: string = '';
  /** 探测错误消息(成功时为空字符串) */
  @State probeErrorMessage: string = '';
  /** 探测完成时间戳(ms,0 表示未探测) */
  @State probeVerifiedAt: number = 0;
  /**
   * Phase 1D-2C-2E-2A: 长度来源类型(CUSTOM / STANDARD / UNAVAILABLE / '')。
   *
   * 显示 UI 诊断:
   * - CUSTOM: 使用 X-ArkTavern-Content-Length
   * - STANDARD: 使用标准 Content-Length
   * - UNAVAILABLE: 长度不可用
   * - '': 探测未到达长度校验阶段
   */
  @State probeContentLengthSource: string = '';
  /**
   * Phase 1D-2C-2E-2A: 自定义长度头解析后的数值(-1 表示未解析到)。
   */
  @State probeCustomContentLength: number = -1;
  /**
   * Phase 1D-2C-2E-2A: 标准长度头解析后的数值(-1 表示未解析到)。
   */
  @State probeStandardContentLength: number = -1;
  /** 是否正在探测(防止重复点击 + 轮询控制) */
  @State probeInProgress: boolean = false;
  /** 轮询计时器 ID(-1 表示无轮询) */
  private probePollTimerId: number = -1;
  /** 轮询间隔(ms) */
  private readonly PROBE_POLL_INTERVAL_MS: number = 200;
  /** 轮询最大次数(20 × 200ms = 4s 超时) */
  private readonly PROBE_POLL_MAX_COUNT: number = 20;
  /** 当前轮询次数 */
  private probePollCount: number = 0;

  // ===== Phase 1D-2B-2: 用户模型加载状态 =====
  /** 加载状态机(NOT_REQUESTED / LOADING / READY / FAILED) */
  @State loadState: string = 'NOT_REQUESTED';
  /** 是否正在加载(防止重复点击 + 轮询控制) */
  @State loadInProgress: boolean = false;
  /** 加载目标文件名(来自 preparedResource.displayName) */
  @State loadDisplayName: string = '';
  /** 加载完成后当前模型显示名 */
  @State loadModelDisplayName: string = '';
  /** 加载错误码(成功时为空字符串) */
  @State loadErrorCode: string = '';
  /** 加载错误消息(成功时为空字符串) */
  @State loadErrorMessage: string = '';
  /** 加载开始时间戳(ms,0 表示未加载) */
  @State loadStartedAt: number = 0;
  /** 加载完成时间戳(ms,0 表示未完成) */
  @State loadCompletedAt: number = 0;
  /** 加载结果轮询计时器 ID(-1 表示无轮询) */
  private loadPollTimerId: number = -1;
  /** 加载结果轮询间隔(ms) */
  private readonly LOAD_POLL_INTERVAL_MS: number = 250;
  /** 加载结果轮询最大次数(240 × 250ms = 60s 超时) */
  private readonly LOAD_POLL_MAX_COUNT: number = 240;
  /** 当前加载结果轮询次数 */
  private loadPollCount: number = 0;

  // ===== Controller 实例(非 @State,不参与 UI 渲染) =====
  private arkWebController: ArkWebVrmViewerController = new ArkWebVrmViewerController();
  /** 模型导入控制器(Phase 1D-1,在 aboutToAppear 中创建) */
  private importController: ArkWebFileImportController | null = null;
  /** 缓存模型资源提供者(Phase 1D-2A,在 aboutToAppear 中创建) */
  private resourceProvider: ArkWebModelResourceProvider | null = null;
  /** 导入元数据持久化存储(Phase 1D-2C-1,在 aboutToAppear 中创建) */
  private importStateStore: ArkWebModelImportStateStore | null = null;
  /** 3D 视口截图控制器(Phase 2A-3A,在 aboutToAppear 中创建) */
  private screenshotController: ArkWebScreenshotController | null = null;
  /** 事件监听器包装器(注入闭包更新 @State) */
  private eventListener: ViewerEventListener = new ViewerEventListener();

  /** 抽屉标题区(拖动条 + 标题)固定高度 */
  private readonly DRAWER_HEADER_HEIGHT: number = 60;

  // ===== Phase 1D-2C-1: 恢复与自动探测状态 =====
  /** 恢复代次(每次启动恢复递增,用于过期判断) */
  private restoreGeneration: number = 0;
  /** 是否正在恢复中(防止重复触发) */
  private restoreInProgress: boolean = false;
  /** 待 Viewer READY 后处理的恢复文件(ArkWeb 未就绪时暂存) */
  private pendingRestoredFile: ImportedModelFile | null = null;
  /** 自动探测代次(每次自动探测递增) */
  private autoProbeGeneration: number = 0;
  /** 上次自动探测的资源 URL(避免对同一 URL 重复自动探测) */
  private lastAutoProbedResourceUrl: string = '';

  // ===== Phase 1D-2C-1: 运行时诊断状态 =====
  /** 最近一条运行时诊断(由 Provider/Coordinator 等通过回调上报) */
  @State runtimeDiagnostic: VrmRuntimeDiagnostic | null = null;
  /** 恢复结果错误码(成功时为空字符串) */
  @State restoreErrorCode: string = '';
  /** 恢复结果错误消息(成功时为空字符串) */
  @State restoreErrorMessage: string = '';
  /** 恢复结果简短提示(用于 UI 显示) */
  @State restoreHint: string = '';

  // ===== Phase 2A-1: 控制面板触摸隔离 =====
  /**
   * 控制面板交互深度计数。
   *
   * - DOWN: depth++
   * - UP / CANCEL: depth--
   * - depth === 1 时禁用 OrbitControls(第一次进入交互)
   * - depth === 0 时恢复 OrbitControls(所有交互结束)
   *
   * 防止:
   * - 一次 MOVE 触发多次 disable
   * - 一次子控件事件导致提前恢复
   * - CANCEL 后永远不恢复
   * - 页面销毁后异步恢复 controls
   */
  private panelInteractionDepth: number = 0;
  /** OrbitControls 当前是否被抑制(供 Debug 显示) */
  @State cameraControlsSuppressed: boolean = false;
  /** Camera Control 恢复代次(防止页面销毁后异步恢复) */
  private cameraControlGeneration: number = 0;

  // ===== Phase 2H: 演示模式状态保存 =====
  /** 演示模式切换代次(防止过期异步回调) */
  private presentationGeneration: number = 0;
  /** 进入 DEMO 前保存的抽屉状态(-1 表示未保存) */
  private panelStateBeforeDemo: number = -1;
  /** 进入 DEMO 前保存的 Tab 索引 */
  private selectedTabBeforeDemo: number = 0;
  /** 进入 DEMO 前面板是否可见 */
  private panelVisibleBeforeDemo: boolean = true;
  /** 演示模式 warning 信息(如 Camera Controls 恢复失败) */
  @State presentationWarning: string = '';

  // ===== Phase 2A-1: 灯光强度节流 =====
  /** 待提交的灯光强度(0.0-4.0,Slider 拖动期间暂存) */
  private pendingLightIntensity: number = 3.0;
  /** 灯光更新代次(防止过期异步调用覆盖最新值) */
  private lightUpdateGeneration: number = 0;
  /** 是否已调度灯光节流定时器 */
  private lightUpdateScheduled: boolean = false;
  /** 灯光节流定时器 ID(-1 表示无定时器) */
  private lightUpdateTimerId: number = -1;
  /** 灯光节流间隔(ms) */
  private readonly LIGHT_UPDATE_THROTTLE_MS: number = 80;

  // ===== Phase 2A-1: Scene 设置状态(由 Viewer 实际状态初始化) =====
  /** 当前场景背景颜色(由 getSceneSettings 同步,而非 ArkUI 默认值) */
  @State sceneBackgroundColor: string = '#222222';
  /** 当前网格显示状态(由 getSceneSettings 同步) */
  @State sceneGridVisible: boolean = false;
  /** 当前灯光强度(0.0-4.0,由 getSceneSettings 同步) */
  @State sceneLightIntensity: number = 3.0;

  // ===== Phase 2F: 环境贴图状态 =====
  /** 环境状态(UNINITIALIZED / INITIALIZING / READY / FAILED / DISPOSED) */
  @State environmentState: string = 'UNINITIALIZED';
  /** 环境来源(ROOM_ENVIRONMENT / NONE) */
  @State environmentSource: string = 'NONE';
  /** 环境光照是否启用 */
  @State environmentEnabled: boolean = false;
  /** 天空盒是否可见 */
  @State skyboxVisible: boolean = false;
  /** 环境强度(0.0-2.0) */
  @State environmentIntensity: number = 1.0;
  /** 环境强度百分比显示(0-200) */
  @State environmentIntensityPercentage: number = 100;
  /** 环境错误码(空字符串表示无错误) */
  @State environmentErrorCode: string = '';
  /** 环境错误消息(空字符串表示无错误) */
  @State environmentErrorMessage: string = '';
  /** 环境初始化是否正在轮询(防止重复触发) */
  private environmentPollInProgress: boolean = false;
  /** 环境轮询定时器 ID(-1 表示无定时器) */
  private environmentPollTimerId: number = -1;
  /** 环境轮询开始时间戳(ms) */
  private environmentPollStartedAt: number = 0;
  /** Phase 2F: 环境强度节流 */
  private pendingEnvironmentIntensity: number = 1.0;
  private environmentUpdateGeneration: number = 0;
  private environmentUpdateScheduled: boolean = false;
  private environmentUpdateTimerId: number = -1;
  private readonly ENVIRONMENT_UPDATE_THROTTLE_MS: number = 80;

  // ===== Phase 2A-1: Debug 场景状态(由 getSceneState 解析) =====
  /** Debug:模型状态字符串 */
  @State debugModelState: string = 'NOT_LOADED';
  /** Debug:模型是否已加载 */
  @State debugModelLoaded: boolean = false;
  /** Debug:模型显示名 */
  @State debugModelDisplayName: string = '';
  /** Debug:模型来源(USER / DEFAULT / NONE) */
  @State debugModelSource: string = 'NONE';
  /** Debug:Camera Controls 是否启用 */
  @State debugCameraControlsEnabled: boolean = true;
  // Phase 2A-2: Camera Debug 状态(从 getCameraState 获取,非硬编码)
  @State debugCameraPositionX: number = 0;
  @State debugCameraPositionY: number = 0;
  @State debugCameraPositionZ: number = 0;
  @State debugCameraTargetX: number = 0;
  @State debugCameraTargetY: number = 0;
  @State debugCameraTargetZ: number = 0;
  @State debugCameraDistance: number = 0;
  @State debugCameraFov: number = 30;
  @State debugCameraNear: number = 0.1;
  @State debugCameraFar: number = 20;
  @State debugCameraAspect: number = 1;
  @State debugCameraLastAction: string = 'INITIALIZE';

  // ===== Phase 2B: 平滑相机过渡状态 =====
  /** Debug:过渡状态 (IDLE/RUNNING/COMPLETED/CANCELLED/FAILED/DISPOSED) */
  @State debugCameraTransitionState: string = 'IDLE';
  /** Debug:过渡进度 [0,1] */
  @State debugCameraTransitionProgress: number = 0;
  /** Debug:过渡总时长(秒) */
  @State debugCameraTransitionDuration: number = 0;
  /** Debug:已过过渡时间(秒) */
  @State debugCameraTransitionElapsed: number = 0;
  /** Debug:取消原因 */
  @State debugCameraTransitionCancelReason: string = '';
  /** Debug:错误码 */
  @State debugCameraTransitionErrorCode: string = '';
  /** Debug:错误信息 */
  @State debugCameraTransitionErrorMessage: string = '';
  /** 重置按钮禁用 (平滑重置进行中) */
  @State resetButtonDisabled: boolean = false;
  /** 平滑过渡状态轮询计时器 ID */
  private cameraTransitionPollTimerId: number = -1;
  /** 平滑过渡轮询开始时间戳(ms) */
  private cameraTransitionPollStartedAt: number = 0;

  // ===== Phase 2A-3A: 截图状态 =====
  @State screenshotState: string = 'IDLE';
  @State screenshotFileName: string = '';
  @State screenshotWidth: number = 0;
  @State screenshotHeight: number = 0;
  @State screenshotByteLength: number = 0;
  @State screenshotCreatedAt: number = 0;
  @State screenshotErrorCode: string = '';
  @State screenshotErrorMessage: string = '';
  @State screenshotInProgress: boolean = false;

  // ===== Phase 3A: 动画系统 Debug 状态(由 getAnimationDebugState 解析) =====
  /** Debug:动画状态机字符串(UNINITIALIZED/IDLE/LOADING/READY/PLAYING/PAUSED/STOPPED/FAILED/DISPOSED) */
  @State debugAnimationState: string = 'UNINITIALIZED';
  /** Debug:VRM 是否已绑定到动画控制器 */
  @State debugAnimationVrmBound: boolean = false;
  /** Debug:AnimationMixer 是否已创建 */
  @State debugAnimationMixerReady: boolean = false;
  /** Debug:AnimationClip 是否已准备 */
  @State debugAnimationClipReady: boolean = false;
  /** Debug:AnimationAction 是否已准备 */
  @State debugAnimationActionReady: boolean = false;
  /** Debug:当前动画名称 */
  @State debugAnimationName: string = '';
  /** Debug:动画总时长(秒) */
  @State debugAnimationDuration: number = 0;
  /** Debug:当前播放时间(秒) */
  @State debugAnimationCurrentTime: number = 0;
  /** Debug:播放速度 */
  @State debugAnimationPlaybackSpeed: number = 1;
  /** Debug:是否循环播放 */
  @State debugAnimationLoop: boolean = true;
  /** Debug:动画错误码 */
  @State debugAnimationErrorCode: string = '';
  /** Debug:动画错误信息 */
  @State debugAnimationErrorMessage: string = '';

  aboutToAppear(): void {
    // Phase 2A-3A: 启用 Web 全绘制能力(webPageSnapshot 前置条件)
    // 必须在 aboutToAppear 中调用(Web 组件初始化前),官方文档明确要求
    // 之前在 onControllerAttached 中调用太晚,导致 webPageSnapshot 返回 status=false
    try {
      webview.WebviewController.enableWholeWebPageDrawing();
      console.info('[VrmViewerPage] enableWholeWebPageDrawing called in aboutToAppear');
    } catch (e) {
      console.warn('[VrmViewerPage] enableWholeWebPageDrawing failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
    // Phase 2B: 重新进入页面时重置 Camera Transition Debug 状态到 IDLE
    this.resetCameraTransitionDebugState();

    // 注入闭包:Controller 回调 → 更新 @State
    this.eventListener.onStateChangedFn = (state: ArkWebViewerState, detail: string) => {
      this.viewerState = state;
      this.viewerDetail = detail;
      // Phase 1D-2C-1:Viewer 进入 READY 时,处理 pendingRestoredFile
      // Phase 1D-2C-2E-1:processRestoredFile 已改为 async,内部 await ensurePreparedModelResource
      // 这里不 await(闭包非 async),processRestoredFile 内部会自行更新 @State
      if (state === ArkWebViewerState.READY && this.pendingRestoredFile !== null) {
        const restoredFile: ImportedModelFile | null = this.pendingRestoredFile;
        this.pendingRestoredFile = null;
        console.info('[VrmViewerPage] Viewer READY, processing pending restored file');
        this.processRestoredFile(restoredFile);
      }
      // Phase 1D-2C-2E-1:Viewer 刚 READY 且已有 current ImportedModelFile 但 WebPrepared 未 READY
      // (导入发生在 Viewer READY 之前,ensurePreparedModelResource 当时返回 VIEWER_NOT_READY)
      // 维护 generation 防止与 restore 路径重复执行
      if (state === ArkWebViewerState.READY &&
          this.pendingRestoredFile === null &&
          this.preparedResource !== null &&
          this.resourceState === ModelResourceState.READY &&
          this.webPreparedState !== WebPreparedResourceState.READY &&
          this.webPreparedState !== WebPreparedResourceState.PREPARING &&
          !this.prepareInProgress &&
          !this.loadInProgress) {
        const currentResource: WebModelResource = this.preparedResource;
        console.info('[VrmViewerPage] Viewer READY, retry prepare for current resource');
        this.ensurePreparedModelResource(currentResource, false).then((ok: boolean) => {
          if (ok) {
            this.tryAutoProbeResource();
          }
        });
      }
      // Phase 2A-1:Viewer READY 后同步初始 Scene 设置与 Debug 状态
      // 不假设 ArkUI 默认值就是 Three.js 当前值,从 Viewer 实际状态初始化
      if (state === ArkWebViewerState.READY) {
        this.syncInitialSceneSettings();
        this.refreshDebugSceneState();
        // Phase 2A-2:Viewer READY 后刷新 Camera Debug 状态
        this.refreshCameraDebugState();
        // Phase 3A:Viewer READY 后刷新动画 Debug 状态
        this.refreshAnimationDebugState();
        // Phase 2F:Viewer READY 后启动环境贴图初始化(后台,不阻塞 UI)
        this.startEnvironmentInitialization();
      }
    };
    this.eventListener.onErrorFn = (code: string, message: string) => {
      this.lastErrorCode = code;
      this.lastError = message;
    };
    this.arkWebController.setEventListener(this.eventListener);

    this.viewerState = ArkWebViewerState.UNINITIALIZED;
    this.viewerDetail = '正在加载 Web Viewer...';

    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

    // Phase 1D-1:创建模型导入控制器(需要 UIAbilityContext 用于 cacheDir 和 Picker)
    if (this.importController === null) {
      this.importController = new ArkWebFileImportController(ctx);

      // Phase 1D-2A:创建资源 Provider(使用同一 context 的 cacheDir)
      // importDirectory = <cacheDir>/vrm-imports(与 ImportController 一致)
      this.resourceProvider = new ArkWebModelResourceProvider(ctx.cacheDir);
    }

    // Phase 1D-2C-1:创建导入元数据持久化存储,并启动恢复
    if (this.importStateStore === null) {
      this.importStateStore = new ArkWebModelImportStateStore(ctx);
      // 异步启动恢复,不阻塞页面构建
      this.startRestoreFromStateStore();
    }

    // Phase 2A-3A:创建截图控制器(Route A: Native ArkWeb Snapshot)
    if (this.screenshotController === null) {
      this.screenshotController = new ArkWebScreenshotController(
        this.arkWebController.getWebviewController(),
        ctx.cacheDir,
        () => this.arkWebController.getState()
      );
    }

    // Web 组件加载由 build() 触发,初始化在 onPageEnd 回调中完成
  }

  aboutToDisappear(): void {
    this.disposeViewer();
  }

  /**
   * 销毁 Viewer,释放所有资源。
   *
   * Phase 1D-2B-2 销毁顺序(AGENTS.md Phase 1D-2B-2 §二十二 页面销毁):
   * 1. 停止用户模型加载结果轮询
   * 2. 停止资源探测轮询
   * 3. Viewer dispose(使 ViewerModelLoader.loadGeneration 失效)
   * 4. clearPreparedModelLoadResult — 清除加载协调器状态
   * 5. clearModelResourceProbe — 清除探测状态
   * 6. resourceProvider.dispose — 停止响应资源请求
   * 7. importController.dispose — 标记导入控制器销毁
   *
   * Phase 1D-2B-1 销毁顺序(原始):
   * 1. clearModelResourceProbe() — 停止探测轮询,清除探测状态
   * 2. resourceProvider.dispose() — 停止响应资源请求
   * 3. importController.dispose() — 标记导入控制器销毁
   * 4. arkWebController.destroy() — 销毁 Web Viewer
   *
   * Phase 1D-1:
   * - 保留已缓存的 currentFile(避免页面短暂切换造成文件丢失)
   *
   * 不删除缓存文件(由 ArkWebFileImportController 负责)。
   *
   * Reference:
   * - figure-main: disposeVrm (资源释放)
   * - ownverse-vrm-viewer: RESOURCE_LIFECYCLE.md (避免已知泄漏)
   * - AGENTS.md Phase 1D-2B-2 §二十二 页面销毁顺序
   */
  private disposeViewer(): void {
    // Phase 2A-1: 清空控制面板触摸交互状态(禁止页面销毁后异步恢复 controls)
    this.panelInteractionDepth = 0;
    this.cameraControlGeneration++; // 使所有待恢复的异步回调过期
    this.cameraControlsSuppressed = false;
    // Phase 2H: 重置演示模式状态(禁止页面销毁后异步回调修改状态)
    this.resetPresentationState();
    // Phase 2A-1: 清理灯光节流定时器
    if (this.lightUpdateTimerId !== -1) {
      clearTimeout(this.lightUpdateTimerId);
      this.lightUpdateTimerId = -1;
    }
    this.lightUpdateScheduled = false;
    this.lightUpdateGeneration++;
    // Phase 2F: 停止环境状态轮询与节流定时器
    this.stopEnvironmentPolling();
    if (this.environmentUpdateTimerId !== -1) {
      clearTimeout(this.environmentUpdateTimerId);
      this.environmentUpdateTimerId = -1;
    }
    this.environmentUpdateScheduled = false;
    this.environmentUpdateGeneration++;
    // Phase 2B: 停止相机过渡状态轮询(页面销毁不再调用 JavaScript)
    this.stopCameraTransitionPolling();
    // Phase 1D-2B-2:1. 停止用户模型加载结果轮询
    this.stopLoadPolling();
    this.resetLoadState();
    // Phase 1D-2B-2:2. 停止资源探测轮询
    this.stopProbePolling();
    this.resetProbeState();
    // Phase 1D-2B-2:3. Viewer dispose 先触发(使 ViewerModelLoader.loadGeneration 失效,
    //                正在进行的加载结果会因代次检查被忽略)
    // Phase 1D-2B-2:4. clearPreparedModelLoadResult(异步,不等待)
    this.arkWebController.clearPreparedModelLoadResult().then((_r: string) => {
      console.info('[VrmViewerPage] clearPreparedModelLoadResult done on dispose');
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] clearPreparedModelLoadResult failed: ' + (e instanceof Error ? e.message : String(e)));
    });
    // Phase 1D-2B-1:5. clearModelResourceProbe(异步,不等待)
    this.arkWebController.clearModelResourceProbe().then((_r: string) => {
      console.info('[VrmViewerPage] clearModelResourceProbe done on dispose');
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] clearModelResourceProbe failed: ' + (e instanceof Error ? e.message : String(e)));
    });
    // Phase 1D-2A:6. 再销毁资源 Provider(停止响应拦截请求)
    if (this.resourceProvider !== null) {
      this.resourceProvider.dispose();
      this.resourceProvider = null;
    }
    // Phase 1D-1:7. 再销毁导入控制器
    if (this.importController !== null) {
      this.importController.dispose();
    }
    // Phase 1D-2C-1:8. 最后销毁 StateStore(不清除 Preferences 记录,保留供下次恢复)
    if (this.importStateStore !== null) {
      this.importStateStore.dispose();
      this.importStateStore = null;
    }
    // Phase 2A-3A:9. 销毁截图控制器(不删除已保存的截图文件)
    if (this.screenshotController !== null) {
      this.screenshotController.dispose();
      this.screenshotController = null;
    }
    // 清空恢复状态
    this.pendingRestoredFile = null;
    this.restoreInProgress = false;
    this.lastAutoProbedResourceUrl = '';
    // Phase 1D-2C-2E-1: 清空 Web Prepared 状态
    this.resetWebPreparedState();
    // 最后销毁 Web Viewer
    this.arkWebController.destroy();
    this.webLoaded = false;
  }

  // ===== Phase 2A-1: 控制面板触摸隔离 =====

  /**
   * Phase 2A-1: 控制面板触摸事件处理。
   *
   * 绑定在控制面板(抽屉面板)最外层容器上,覆盖:
   * - Scroll 滚动
   * - Slider 拖动
   * - Tab 横向切换
   * - 面板拖动
   * - Button 点击
   * - 颜色按钮点击
   * - Switch 切换
   *
   * 行为:
   * - DOWN: interactionDepth++,第一次进入时 disable controls
   * - UP / CANCEL: interactionDepth--,归零时 enable controls
   *
   * 防止:
   * - 一次 MOVE 触发多次 disable(只在 depth 0→1 时 disable)
   * - 一次子控件事件导致提前恢复(深度计数,不提前归零)
   * - CANCEL 后永远不恢复(CANCEL 与 UP 同等处理,递减 depth)
   * - 页面销毁后异步恢复 controls(generation 检查)
   */
  onPanelTouch(event: TouchEvent): void {
    // 页面已销毁时不处理
    if (this.viewerState === ArkWebViewerState.DISPOSED) {
      return;
    }
    switch (event.type) {
      case TouchType.Down:
        this.panelInteractionDepth++;
        if (this.panelInteractionDepth === 1) {
          // 第一次进入交互,禁用 OrbitControls
          this.suppressCameraControls();
        }
        break;
      case TouchType.Up:
      case TouchType.Cancel:
        this.panelInteractionDepth--;
        if (this.panelInteractionDepth <= 0) {
          // 所有交互结束,恢复 OrbitControls
          this.panelInteractionDepth = 0;
          this.restoreCameraControls();
        }
        break;
      case TouchType.Move:
      default:
        // Move 不改变 depth(已在 Down 时禁用,避免重复 disable)
        break;
    }
  }

  /**
   * Phase 2A-1: 禁用 OrbitControls。
   *
   * 调用 Bridge setCameraControlsEnabled(false)。
   * Viewer 不为 READY 时静默跳过(不报错)。
   */
  private suppressCameraControls(): void {
    if (this.viewerState !== ArkWebViewerState.READY) {
      return;
    }
    this.cameraControlsSuppressed = true;
    this.arkWebController.setCameraControlsEnabled(false).then((resultJson: string) => {
      // 异步回调,检查结果(失败仅日志,不影响交互)
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (!obj['success']) {
          console.warn('[VrmViewerPage] suppressCameraControls failed: ' + resultJson);
        }
      } catch (e) {
        // 忽略解析错误
      }
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] suppressCameraControls exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 2A-1: 恢复 OrbitControls。
   *
   * 使用 generation 检查,防止页面销毁后异步恢复。
   */
  private restoreCameraControls(): void {
    if (this.viewerState !== ArkWebViewerState.READY) {
      return;
    }
    const generation: number = this.cameraControlGeneration;
    this.cameraControlsSuppressed = false;
    this.arkWebController.setCameraControlsEnabled(true).then((resultJson: string) => {
      // generation 检查:页面销毁后 cameraControlGeneration 已递增,此回调过期
      if (generation !== this.cameraControlGeneration) {
        return;
      }
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (!obj['success']) {
          console.warn('[VrmViewerPage] restoreCameraControls failed: ' + resultJson);
        }
      } catch (e) {
        // 忽略解析错误
      }
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] restoreCameraControls exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  // ===== Phase 2H: 演示模式 =====

  /**
   * Phase 2H: 将 ViewerTab 转换为数字索引(用于保存/恢复)。
   */
  private viewerTabToIndex(tab: ViewerTab): number {
    switch (tab) {
      case ViewerTab.Model: return 0;
      case ViewerTab.Pose: return 1;
      case ViewerTab.Animation: return 2;
      case ViewerTab.Expression: return 3;
      case ViewerTab.Physics: return 4;
      case ViewerTab.Scene: return 5;
      case ViewerTab.Debug: return 6;
      default: return 0;
    }
  }

  /**
   * Phase 2H: 将数字索引恢复为 ViewerTab。
   * 无效索引恢复为 Model,并记录 warning。
   */
  private indexToViewerTab(index: number): ViewerTab {
    switch (index) {
      case 0: return ViewerTab.Model;
      case 1: return ViewerTab.Pose;
      case 2: return ViewerTab.Animation;
      case 3: return ViewerTab.Expression;
      case 4: return ViewerTab.Physics;
      case 5: return ViewerTab.Scene;
      case 6: return ViewerTab.Debug;
      default:
        this.presentationWarning =
          ArkWebPresentationErrorCode.PANEL_STATE_INVALID + ': invalid tab index ' + index;
        return ViewerTab.Model;
    }
  }

  /**
   * Phase 2H: 将 DrawerState 转换为数字(用于保存/恢复)。
   */
  private drawerStateToIndex(state: DrawerState): number {
    switch (state) {
      case DrawerState.Collapsed: return 0;
      case DrawerState.Half: return 1;
      case DrawerState.Expanded: return 2;
      default: return 1;
    }
  }

  /**
   * Phase 2H: 将数字恢复为 DrawerState。
   * 无效索引恢复为 Half,并记录 warning。
   */
  private indexToDrawerState(index: number): DrawerState {
    switch (index) {
      case 0: return DrawerState.Collapsed;
      case 1: return DrawerState.Half;
      case 2: return DrawerState.Expanded;
      default:
        this.presentationWarning =
          ArkWebPresentationErrorCode.PANEL_STATE_INVALID + ': invalid drawer index ' + index;
        return DrawerState.Half;
    }
  }

  /**
   * Phase 2H: 进入演示模式。
   *
   * 隐藏快捷工具栏和控制面板,保存当前面板状态供退出时恢复。
   * 进入 DEMO 后恢复 Camera Controls(若被面板触摸抑制)。
   *
   * 条件:
   *   - 页面未销毁
   *   - presentationMode === NORMAL
   *   - presentationTransitioning === false
   *   - ViewerState === READY
   *
   * Camera Controls 恢复失败只记录 warning,仍进入 DEMO。
   */
  private async enterDemoMode(): Promise<void> {
    // 1. 条件校验
    if (this.presentationMode === PresentationMode.DEMO) {
      console.info('[VrmViewerPage] enterDemoMode skipped: already DEMO');
      return;
    }
    if (this.presentationTransitioning) {
      console.info('[VrmViewerPage] enterDemoMode skipped: transition in progress');
      return;
    }
    if (this.viewerState !== ArkWebViewerState.READY) {
      this.presentationWarning = ArkWebPresentationErrorCode.VIEWER_NOT_READY +
        ': viewer state is ' + this.viewerState;
      console.warn('[VrmViewerPage] enterDemoMode rejected: viewer not READY');
      return;
    }

    // 2. 设置切换中标志
    this.presentationTransitioning = true;
    this.presentationGeneration++;
    const gen: number = this.presentationGeneration;
    this.presentationWarning = '';

    // 3. 保存当前面板状态
    this.panelStateBeforeDemo = this.drawerStateToIndex(this.drawerState);
    this.selectedTabBeforeDemo = this.viewerTabToIndex(this.activeTab);
    this.panelVisibleBeforeDemo = true; // NORMAL 模式下面板始终可见

    // 4. 清空面板触摸交互状态
    this.panelInteractionDepth = 0;

    // 5. 恢复 Camera Controls(若被面板触摸抑制)
    this.cameraControlGeneration++;
    this.cameraControlsSuppressed = false;
    this.arkWebController.setCameraControlsEnabled(true).then((resultJson: string) => {
      if (gen !== this.presentationGeneration) {
        return; // 过期回调
      }
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (!obj['success']) {
          this.presentationWarning =
            ArkWebPresentationErrorCode.CAMERA_CONTROLS_WARNING +
            ': setCameraControlsEnabled(true) failed';
          console.warn('[VrmViewerPage] enterDemoMode camera controls warning: ' + resultJson);
        }
      } catch (e) {
        this.presentationWarning =
          ArkWebPresentationErrorCode.CAMERA_CONTROLS_WARNING +
          ': result parse failed';
        console.warn('[VrmViewerPage] enterDemoMode camera controls parse warning');
      }
    }).catch((e: Object) => {
      if (gen !== this.presentationGeneration) {
        return;
      }
      this.presentationWarning =
        ArkWebPresentationErrorCode.CAMERA_CONTROLS_WARNING +
        ': ' + (e instanceof Error ? e.message : String(e));
      console.warn('[VrmViewerPage] enterDemoMode camera controls exception');
    });

    // 6. 切换到 DEMO
    this.presentationMode = PresentationMode.DEMO;
    this.presentationTransitioning = false;
    console.info('[VrmViewerPage] enterDemoMode done (gen=' + gen + ')');
  }

  /**
   * Phase 2H: 退出演示模式,恢复 NORMAL。
   *
   * 恢复进入前保存的面板状态、Tab 和可见性。
   * 不恢复或覆盖相机位置、Scene 设置、环境设置、模型状态等。
   */
  private async exitDemoMode(): Promise<void> {
    // 1. 条件校验
    if (this.presentationMode === PresentationMode.NORMAL) {
      console.info('[VrmViewerPage] exitDemoMode skipped: already NORMAL');
      return;
    }
    if (this.presentationTransitioning) {
      console.info('[VrmViewerPage] exitDemoMode skipped: transition in progress');
      return;
    }

    // 2. 设置切换中标志
    this.presentationTransitioning = true;
    this.presentationGeneration++;
    const gen: number = this.presentationGeneration;

    // 3. 切换到 NORMAL
    this.presentationMode = PresentationMode.NORMAL;

    // 4. 恢复保存的面板状态
    if (this.panelStateBeforeDemo >= 0 && this.panelStateBeforeDemo <= 2) {
      this.drawerState = this.indexToDrawerState(this.panelStateBeforeDemo);
    } else {
      this.drawerState = DrawerState.Half;
      this.presentationWarning =
        ArkWebPresentationErrorCode.PANEL_STATE_INVALID +
        ': panelStateBeforeDemo=' + this.panelStateBeforeDemo;
    }

    // 5. 恢复保存的 Tab
    this.activeTab = this.indexToViewerTab(this.selectedTabBeforeDemo);

    // 6. 恢复面板可见状态
    // NORMAL 模式下面板始终可见,panelVisibleBeforeDemo 仅作记录

    // 7. 清除切换中标志
    this.presentationTransitioning = false;
    console.info('[VrmViewerPage] exitDemoMode done (gen=' + gen + ')');
  }

  /**
   * Phase 2H: 重置演示模式状态(页面销毁时调用)。
   */
  private resetPresentationState(): void {
    this.presentationGeneration++;
    this.presentationTransitioning = false;
    this.presentationMode = PresentationMode.NORMAL;
    this.panelStateBeforeDemo = -1;
    this.selectedTabBeforeDemo = 0;
    this.panelVisibleBeforeDemo = true;
    this.presentationWarning = '';
  }

  /**
   * Phase 2H: 返回键处理。
   *
   * DEMO 模式下返回键退出 DEMO(不离开页面)。
   * NORMAL 模式下保持页面原有返回行为(路由返回)。
   */
  onBackPress(): boolean {
    if (this.presentationMode === PresentationMode.DEMO) {
      // 同步切换回 NORMAL(不等待异步完成,立即消费返回事件)
      this.presentationMode = PresentationMode.NORMAL;
      this.presentationTransitioning = false;
      this.presentationGeneration++;

      // 恢复保存的面板状态
      if (this.panelStateBeforeDemo >= 0 && this.panelStateBeforeDemo <= 2) {
        this.drawerState = this.indexToDrawerState(this.panelStateBeforeDemo);
      } else {
        this.drawerState = DrawerState.Half;
      }
      this.activeTab = this.indexToViewerTab(this.selectedTabBeforeDemo);

      console.info('[VrmViewerPage] onBackPress: exited DEMO mode');
      return true; // 消费返回事件,不离开页面
    }
    // NORMAL 模式:保持原有返回行为(路由返回)
    return false;
  }

  // ===== Phase 2A-1: Scene 设置同步 =====

  /**
   * Phase 2A-1: Viewer READY 后同步初始 Scene 设置。
   *
   * 调用 getSceneSettings 获取 Viewer 实际的背景/网格/灯光状态,
   * 用实际值初始化 ArkUI @State,不假设 ArkUI 默认值就是 Three.js 当前值。
   */
  private syncInitialSceneSettings(): void {
    this.arkWebController.getSceneSettings().then((resultJson: string) => {
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const settings = obj['settings'] as Record<string, Object>;
          if (settings) {
            const bgColor = (settings['backgroundColor'] as string) || '#222222';
            const gridVisible = settings['gridVisible'] === true;
            const lightIntensity = (settings['lightIntensity'] as number) ?? 3.0;
            this.sceneBackgroundColor = bgColor;
            this.sceneGridVisible = gridVisible;
            this.sceneLightIntensity = lightIntensity;
            this.backgroundOption = bgColor;
            this.showGrid = gridVisible;
            this.lightIntensity = Math.round(lightIntensity * 25.0);
            this.pendingLightIntensity = lightIntensity;
            console.info('[VrmViewerPage] Initial scene settings synced: bg=' + bgColor +
              ' grid=' + gridVisible + ' light=' + lightIntensity);
          }
        }
      } catch (e) {
        console.warn('[VrmViewerPage] syncInitialSceneSettings parse failed: ' + (e instanceof Error ? e.message : String(e)));
      }
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] syncInitialSceneSettings exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 2A-1: 刷新 Debug 场景状态(从 getSceneState 解析)。
   *
   * 获取 Viewer 实际的模型状态、Scene 设置、Camera Controls 状态,
   * 更新 Debug Tab 显示。
   */
  private refreshDebugSceneState(): void {
    this.arkWebController.getSceneState().then((resultJson: string) => {
      this.parseDebugSceneState(resultJson);
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] refreshDebugSceneState exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 2A-1: 解析 getSceneState 返回的 JSON,更新 Debug 状态。
   */
  private parseDebugSceneState(resultJson: string): void {
    try {
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] !== true) {
        return;
      }
      const scene = obj['scene'] as Record<string, Object>;
      if (!scene) {
        return;
      }
      // 模型状态
      this.debugModelState = (scene['modelState'] as string) || 'NOT_LOADED';
      this.debugModelLoaded = scene['modelLoaded'] === true;
      this.debugModelDisplayName = (scene['modelDisplayName'] as string) || '';
      this.debugModelSource = (scene['modelSource'] as string) || 'NONE';
      // Phase 2A-2: 模型 READY 后(自动取景已完成)刷新 Camera Debug
      if (this.debugModelState === 'READY') {
        this.refreshCameraDebugState();
        // Phase 3A: 模型 READY 后也刷新动画 Debug(绑定可能刚刚完成)
        this.refreshAnimationDebugState();
      }
      // Scene 设置
      this.debugCameraControlsEnabled = scene['cameraControlsEnabled'] === true;
      // 同步 Scene 设置状态(如果 Viewer 端有变化)
      const bgColor = (scene['backgroundColor'] as string);
      if (bgColor) {
        this.sceneBackgroundColor = bgColor;
      }
      const gridVisible = scene['gridVisible'];
      if (gridVisible !== undefined) {
        this.sceneGridVisible = gridVisible === true;
      }
      const lightIntensity = scene['lightIntensity'];
      if (lightIntensity !== undefined) {
        this.sceneLightIntensity = lightIntensity as number;
      }
    } catch (e) {
      console.warn('[VrmViewerPage] parseDebugSceneState failed: ' + (e instanceof Error ? e.message : String(e)));
    }
  }

  // ===== Phase 3A: 动画系统 Debug 状态查询 =====

  /**
   * Phase 3A: 刷新动画系统 Debug 状态(从 getAnimationDebugState 解析)。
   *
   * 仅在 Viewer READY / 模型替换完成 / 用户手动刷新 Debug 时查询,
   * 不每帧执行 ArkTS Bridge 查询。
   */
  private refreshAnimationDebugState(): void {
    this.arkWebController.getAnimationDebugState().then((resultJson: string) => {
      this.parseAnimationDebugState(resultJson);
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] refreshAnimationDebugState exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 3A: 解析 getAnimationDebugState 返回的 JSON,更新动画 Debug 状态。
   */
  private parseAnimationDebugState(resultJson: string): void {
    try {
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] !== true) {
        return;
      }
      const debugState = obj['debugState'] as Record<string, Object>;
      if (!debugState) {
        return;
      }
      this.debugAnimationState = (debugState['state'] as string) || 'UNINITIALIZED';
      this.debugAnimationVrmBound = debugState['vrmBound'] === true;
      this.debugAnimationMixerReady = debugState['mixerReady'] === true;
      this.debugAnimationClipReady = debugState['clipReady'] === true;
      this.debugAnimationActionReady = debugState['actionReady'] === true;
      this.debugAnimationName = (debugState['animationName'] as string) || '';
      this.debugAnimationDuration = (debugState['duration'] as number) || 0;
      this.debugAnimationCurrentTime = (debugState['currentTime'] as number) || 0;
      this.debugAnimationPlaybackSpeed = (debugState['playbackSpeed'] as number) || 1;
      this.debugAnimationLoop = debugState['loop'] === true;
      this.debugAnimationErrorCode = (debugState['errorCode'] as string) || '';
      this.debugAnimationErrorMessage = (debugState['errorMessage'] as string) || '';
    } catch (e) {
      console.warn('[VrmViewerPage] parseAnimationDebugState failed: ' + (e instanceof Error ? e.message : String(e)));
    }
  }

  // ===== Phase 2A-1: ArkUI 场景控件接入 =====

  /**
   * Phase 2A-2: 用 ArkWebCameraState 更新 Camera Debug 状态变量。
   *
   * @param cameraState 解析后的 CameraState
   */
  private updateCameraDebugState(cameraState: ArkWebCameraState): void {
    this.debugCameraPositionX = cameraState.position.x;
    this.debugCameraPositionY = cameraState.position.y;
    this.debugCameraPositionZ = cameraState.position.z;
    this.debugCameraTargetX = cameraState.target.x;
    this.debugCameraTargetY = cameraState.target.y;
    this.debugCameraTargetZ = cameraState.target.z;
    this.debugCameraDistance = cameraState.distance;
    this.debugCameraFov = cameraState.fov;
    this.debugCameraNear = cameraState.near;
    this.debugCameraFar = cameraState.far;
    this.debugCameraAspect = cameraState.aspect;
    this.debugCameraControlsEnabled = cameraState.controlsEnabled;
    this.debugCameraLastAction = cameraState.lastAction;
  }

  /**
   * Phase 2A-2: 主动刷新 Camera Debug 状态(调用 getCameraState)。
   *
   * 只在以下时机刷新:
   *   - Viewer READY
   *   - 聚焦完成
   *   - 重置完成
   *   - 模型替换完成
   *   - 用户手动刷新 Debug
   *
   * 避免每帧轮询。
   */
  private refreshCameraDebugState(): void {
    this.arkWebController.getCameraState().then((resultJson: string) => {
      if (resultJson && resultJson.length > 0) {
        const cameraState: ArkWebCameraState | null = parseCameraState(resultJson);
        if (cameraState) {
          this.updateCameraDebugState(cameraState);
        }
      }
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] refreshCameraDebugState exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 2A-1: 用户点击背景颜色按钮。
   *
   * 流程:
   * 1. 先调用 setSceneBackgroundColor
   * 2. success=true 后更新 ArkUI @State
   * 3. 失败时恢复之前选中颜色
   * 4. 显示具体错误码
   *
   * @param color 用户选择的 #RRGGBB 颜色
   */
  private onBackgroundColorSelected(color: string): void {
    const previousColor: string = this.backgroundOption;
    this.arkWebController.setSceneBackgroundColor(color).then((resultJson: string) => {
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const actualColor = (obj['color'] as string) || color;
          this.backgroundOption = actualColor;
          this.sceneBackgroundColor = actualColor;
          console.info('[VrmViewerPage] Background color set to ' + actualColor);
        } else {
          // 失败时恢复之前选中颜色
          this.backgroundOption = previousColor;
          const errorObj = obj['error'] as Record<string, Object>;
          const code = errorObj ? (errorObj['code'] as string) : 'UNKNOWN';
          console.warn('[VrmViewerPage] setSceneBackgroundColor failed: ' + code);
          promptAction.showToast({
            message: `背景颜色设置失败: ${code}`,
            duration: 2000
          });
        }
      } catch (e) {
        this.backgroundOption = previousColor;
        console.warn('[VrmViewerPage] setSceneBackgroundColor parse failed');
      }
    }).catch((e: Object) => {
      this.backgroundOption = previousColor;
      console.warn('[VrmViewerPage] setSceneBackgroundColor exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 2A-1: 用户切换网格显示开关。
   *
   * @param visible 用户选择是否显示网格
   */
  private onGridToggleChanged(visible: boolean): void {
    this.arkWebController.setSceneGridVisible(visible).then((resultJson: string) => {
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const actualVisible = obj['visible'] === true;
          this.showGrid = actualVisible;
          this.sceneGridVisible = actualVisible;
          console.info('[VrmViewerPage] Grid visible set to ' + actualVisible);
        } else {
          // 失败时恢复 Switch
          this.showGrid = !visible;
          const errorObj = obj['error'] as Record<string, Object>;
          const code = errorObj ? (errorObj['code'] as string) : 'UNKNOWN';
          console.warn('[VrmViewerPage] setSceneGridVisible failed: ' + code);
          promptAction.showToast({
            message: `网格设置失败: ${code}`,
            duration: 2000
          });
        }
      } catch (e) {
        this.showGrid = !visible;
        console.warn('[VrmViewerPage] setSceneGridVisible parse failed');
      }
    }).catch((e: Object) => {
      this.showGrid = !visible;
      console.warn('[VrmViewerPage] setSceneGridVisible exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 2A-1: 灯光强度 Slider 值变化(拖动中)。
   *
   * 本地更新百分比显示,但 Bridge 调用需节流。
   * 滑动结束必须提交最后一个值。
   *
   * @param percentage 0-100
   */
  private onLightIntensitySliderChange(percentage: number): void {
    this.lightIntensity = Math.round(percentage);
    const intensity: number = percentage / 25.0;
    this.pendingLightIntensity = intensity;
    this.scheduleLightUpdate();
  }

  /**
   * Phase 2A-1: 灯光强度 Slider 拖动结束。
   *
   * 立即提交最终值,取消待执行的节流定时器。
   * @param percentage 0-100
   */
  private onLightIntensitySliderChangeEnd(percentage: number): void {
    this.lightIntensity = Math.round(percentage);
    const intensity: number = percentage / 25.0;
    this.pendingLightIntensity = intensity;
    // 取消节流定时器,立即提交
    if (this.lightUpdateTimerId !== -1) {
      clearTimeout(this.lightUpdateTimerId);
      this.lightUpdateTimerId = -1;
    }
    this.lightUpdateScheduled = false;
    this.commitLightUpdate();
  }

  /**
   * Phase 2A-1: 调度灯光节流更新。
   *
   * 最大每 LIGHT_UPDATE_THROTTLE_MS 一次,避免每个像素移动都调用 runJavaScript()。
   */
  private scheduleLightUpdate(): void {
    if (this.lightUpdateScheduled) {
      return; // 已有定时器在等待
    }
    this.lightUpdateScheduled = true;
    const generation: number = this.lightUpdateGeneration;
    this.lightUpdateTimerId = setTimeout(() => {
      this.lightUpdateTimerId = -1;
      this.lightUpdateScheduled = false;
      // generation 检查:页面销毁后 lightUpdateGeneration 已递增
      if (generation !== this.lightUpdateGeneration) {
        return;
      }
      this.commitLightUpdate();
    }, this.LIGHT_UPDATE_THROTTLE_MS);
  }

  /**
   * Phase 2A-1: 实际提交灯光强度到 Bridge。
   */
  private commitLightUpdate(): void {
    if (this.viewerState !== ArkWebViewerState.READY) {
      return;
    }
    const intensity: number = this.pendingLightIntensity;
    this.arkWebController.setSceneLightIntensity(intensity).then((resultJson: string) => {
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const actualIntensity = (obj['intensity'] as number) ?? intensity;
          this.sceneLightIntensity = actualIntensity;
        } else {
          const errorObj = obj['error'] as Record<string, Object>;
          const code = errorObj ? (errorObj['code'] as string) : 'UNKNOWN';
          console.warn('[VrmViewerPage] setSceneLightIntensity failed: ' + code);
        }
      } catch (e) {
        console.warn('[VrmViewerPage] setSceneLightIntensity parse failed');
      }
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] setSceneLightIntensity exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  // ===== Phase 2F: 环境贴图与天空盒 =====

  /**
   * Phase 2F: 启动环境贴图初始化(后台,不阻塞 UI)。
   *
   * 流程:
   * 1. 调用 initializeEnvironment(同步返回 INITIALIZING 或 READY)
   * 2. 轮询 getEnvironmentSettings 直到 READY / FAILED(每 100ms,最长 5 秒)
   * 3. 环境就绪后用真实状态初始化 ArkUI(@State)
   *
   * 防止:
   * - 重复触发(environmentPollInProgress)
   * - 页面销毁后异步回调(generation 检查)
   * - 阻塞 Viewer READY 状态
   */
  private startEnvironmentInitialization(): void {
    if (this.environmentPollInProgress) {
      console.info('[VrmViewerPage] Environment initialization already in progress, skip');
      return;
    }
    this.environmentPollInProgress = true;
    this.environmentState = 'INITIALIZING';
    console.info('[VrmViewerPage] Starting environment initialization');

    this.arkWebController.initializeEnvironment().then((resultJson: string) => {
      // 解析立即返回结果(可能直接 READY 或 INITIALIZING)
      let immediateReady: boolean = false;
      let immediateFailed: boolean = false;
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const envState = (obj['environmentState'] as string) || 'INITIALIZING';
          if (envState === 'READY') {
            immediateReady = true;
          } else if (envState === 'FAILED') {
            immediateFailed = true;
          }
          // 同步 settings(如果有)
          const settingsObj = obj['settings'] as Record<string, Object>;
          if (settingsObj) {
            this.applyEnvironmentSettings(settingsObj);
          }
        } else {
          immediateFailed = true;
          const errorObj = obj['error'] as Record<string, Object>;
          if (errorObj) {
            this.environmentErrorCode = (errorObj['code'] as string) || 'ENVIRONMENT_INIT_FAILED';
            this.environmentErrorMessage = (errorObj['message'] as string) || '';
          }
        }
      } catch (e) {
        console.warn('[VrmViewerPage] initializeEnvironment parse failed: ' + (e instanceof Error ? e.message : String(e)));
      }

      if (immediateReady) {
        this.environmentPollInProgress = false;
        console.info('[VrmViewerPage] Environment initialized immediately (READY)');
        this.refreshEnvironmentSettings();
        return;
      }
      if (immediateFailed) {
        this.environmentPollInProgress = false;
        this.environmentState = 'FAILED';
        console.warn('[VrmViewerPage] Environment initialization failed immediately');
        return;
      }
      // INITIALIZING:启动轮询
      this.startEnvironmentPolling();
    }).catch((e: Object) => {
      this.environmentPollInProgress = false;
      this.environmentState = 'FAILED';
      this.environmentErrorCode = 'ENVIRONMENT_INIT_EXCEPTION';
      this.environmentErrorMessage = e instanceof Error ? e.message : String(e);
      console.warn('[VrmViewerPage] initializeEnvironment exception: ' + this.environmentErrorMessage);
    });
  }

  /**
   * Phase 2F: 启动环境状态轮询。
   *
   * 每 100ms 调用 getEnvironmentSettings,直到状态变为 READY 或 FAILED,
   * 或超过 5 秒超时。
   */
  private startEnvironmentPolling(): void {
    this.stopEnvironmentPolling();
    this.environmentPollStartedAt = Date.now();
    this.environmentPollTimerId = setTimeout(() => {
      this.environmentPollTimerId = -1;
      this.pollEnvironmentOnce();
    }, ARKWEB_ENVIRONMENT_POLL_INTERVAL_MS);
  }

  /**
   * Phase 2F: 停止环境状态轮询。
   */
  private stopEnvironmentPolling(): void {
    if (this.environmentPollTimerId !== -1) {
      clearTimeout(this.environmentPollTimerId);
      this.environmentPollTimerId = -1;
    }
    this.environmentPollInProgress = false;
  }

  /**
   * Phase 2F: 轮询一次环境状态。
   */
  private pollEnvironmentOnce(): void {
    if (this.viewerState !== ArkWebViewerState.READY) {
      this.environmentPollInProgress = false;
      return;
    }
    // 超时检查
    const elapsed: number = Date.now() - this.environmentPollStartedAt;
    if (elapsed > ARKWEB_ENVIRONMENT_POLL_TIMEOUT_MS) {
      this.environmentPollInProgress = false;
      this.environmentState = 'FAILED';
      this.environmentErrorCode = 'ENVIRONMENT_INIT_TIMEOUT';
      this.environmentErrorMessage = 'Environment initialization timed out after 5000ms';
      console.warn('[VrmViewerPage] Environment polling timed out');
      return;
    }

    this.arkWebController.getEnvironmentSettings().then((resultJson: string) => {
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const settingsObj = obj['settings'] as Record<string, Object>;
          if (settingsObj) {
            this.applyEnvironmentSettings(settingsObj);
            const currentState: string = (settingsObj['state'] as string) || 'INITIALIZING';
            if (currentState === 'READY' || currentState === 'FAILED' || currentState === 'DISPOSED') {
              this.environmentPollInProgress = false;
              console.info('[VrmViewerPage] Environment polling stopped, state=' + currentState);
              return;
            }
          }
        }
      } catch (e) {
        console.warn('[VrmViewerPage] pollEnvironmentOnce parse failed');
      }
      // 继续轮询
      this.environmentPollTimerId = setTimeout(() => {
        this.environmentPollTimerId = -1;
        this.pollEnvironmentOnce();
      }, ARKWEB_ENVIRONMENT_POLL_INTERVAL_MS);
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] pollEnvironmentOnce exception: ' + (e instanceof Error ? e.message : String(e)));
      // 异常不停止轮询,继续尝试直到超时
      this.environmentPollTimerId = setTimeout(() => {
        this.environmentPollTimerId = -1;
        this.pollEnvironmentOnce();
      }, ARKWEB_ENVIRONMENT_POLL_INTERVAL_MS);
    });
  }

  /**
   * Phase 2F: 应用环境设置到 ArkUI @State。
   *
   * @param settingsObj 从 Bridge 返回的 settings 对象
   */
  private applyEnvironmentSettings(settingsObj: Record<string, Object>): void {
    const state: string = (settingsObj['state'] as string) || 'UNINITIALIZED';
    const source: string = (settingsObj['source'] as string) || 'NONE';
    const enabled: boolean = settingsObj['environmentEnabled'] === true;
    const visible: boolean = settingsObj['skyboxVisible'] === true;
    const intensity: number = (settingsObj['environmentIntensity'] as number) ?? 1.0;
    const errorCode: string = (settingsObj['errorCode'] as string) || '';
    const errorMessage: string = (settingsObj['errorMessage'] as string) || '';

    this.environmentState = state;
    this.environmentSource = source;
    this.environmentEnabled = enabled;
    this.skyboxVisible = visible;
    this.environmentIntensity = intensity;
    this.environmentIntensityPercentage = Math.round(intensity * 100.0);
    this.pendingEnvironmentIntensity = intensity;
    this.environmentErrorCode = errorCode;
    this.environmentErrorMessage = errorMessage;
  }

  /**
   * Phase 2F: 主动刷新环境设置(从 Bridge 拉取最新状态)。
   *
   * 用于 Debug Tab "刷新" 按钮或环境状态可能变化的场景。
   */
  private refreshEnvironmentSettings(): void {
    if (this.viewerState !== ArkWebViewerState.READY) {
      return;
    }
    this.arkWebController.getEnvironmentSettings().then((resultJson: string) => {
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const settingsObj = obj['settings'] as Record<string, Object>;
          if (settingsObj) {
            this.applyEnvironmentSettings(settingsObj);
          }
        }
      } catch (e) {
        console.warn('[VrmViewerPage] refreshEnvironmentSettings parse failed');
      }
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] refreshEnvironmentSettings exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 2F: 用户切换环境光照开关。
   *
   * 流程:
   * 1. 调用 setEnvironmentEnabled
   * 2. 成功后更新 ArkUI @State
   * 3. 失败时恢复 Switch
   * 4. 显示具体错误
   *
   * @param enabled 用户选择是否启用环境光照
   */
  private onEnvironmentToggleChanged(enabled: boolean): void {
    const previousEnabled: boolean = this.environmentEnabled;
    this.arkWebController.setEnvironmentEnabled(enabled).then((resultJson: string) => {
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const actualEnabled = obj['enabled'] === true;
          this.environmentEnabled = actualEnabled;
          // 同步设置(禁用环境时 Skybox 自动关闭)
          const settingsObj = obj['settings'] as Record<string, Object>;
          if (settingsObj) {
            this.applyEnvironmentSettings(settingsObj);
          }
          console.info('[VrmViewerPage] Environment enabled set to ' + actualEnabled);
        } else {
          // 失败时恢复 Switch
          this.environmentEnabled = previousEnabled;
          const errorObj = obj['error'] as Record<string, Object>;
          const code = errorObj ? (errorObj['code'] as string) : 'UNKNOWN';
          const message = errorObj ? (errorObj['message'] as string) : '';
          console.warn('[VrmViewerPage] setEnvironmentEnabled failed: ' + code);
          promptAction.showToast({
            message: `环境光照设置失败: ${code}${message.length > 0 ? ' - ' + message : ''}`,
            duration: 2000
          });
        }
      } catch (e) {
        this.environmentEnabled = previousEnabled;
        console.warn('[VrmViewerPage] setEnvironmentEnabled parse failed');
      }
    }).catch((e: Object) => {
      this.environmentEnabled = previousEnabled;
      console.warn('[VrmViewerPage] setEnvironmentEnabled exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 2F: 用户切换天空盒开关。
   *
   * 前置条件:environmentState === READY && environmentEnabled === true
   * 失败时恢复 Switch。
   *
   * @param visible 用户选择是否显示天空盒
   */
  private onSkyboxToggleChanged(visible: boolean): void {
    const previousVisible: boolean = this.skyboxVisible;
    this.arkWebController.setSkyboxVisible(visible).then((resultJson: string) => {
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const actualVisible = obj['visible'] === true;
          this.skyboxVisible = actualVisible;
          // 同步设置
          const settingsObj = obj['settings'] as Record<string, Object>;
          if (settingsObj) {
            this.applyEnvironmentSettings(settingsObj);
          }
          console.info('[VrmViewerPage] Skybox visible set to ' + actualVisible);
        } else {
          // 失败时恢复 Switch
          this.skyboxVisible = previousVisible;
          const errorObj = obj['error'] as Record<string, Object>;
          const code = errorObj ? (errorObj['code'] as string) : 'UNKNOWN';
          const message = errorObj ? (errorObj['message'] as string) : '';
          console.warn('[VrmViewerPage] setSkyboxVisible failed: ' + code);
          promptAction.showToast({
            message: `天空盒设置失败: ${code}${message.length > 0 ? ' - ' + message : ''}`,
            duration: 2000
          });
        }
      } catch (e) {
        this.skyboxVisible = previousVisible;
        console.warn('[VrmViewerPage] setSkyboxVisible parse failed');
      }
    }).catch((e: Object) => {
      this.skyboxVisible = previousVisible;
      console.warn('[VrmViewerPage] setSkyboxVisible exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 2F: 环境强度 Slider 值变化(拖动中)。
   *
   * 本地更新百分比显示,但 Bridge 调用需节流。
   * 滑动结束必须提交最后一个值。
   *
   * @param percentage 0-200
   */
  private onEnvironmentIntensitySliderChange(percentage: number): void {
    this.environmentIntensityPercentage = Math.round(percentage);
    const intensity: number = percentage / 100.0;
    this.pendingEnvironmentIntensity = intensity;
    this.scheduleEnvironmentUpdate();
  }

  /**
   * Phase 2F: 环境强度 Slider 拖动结束。
   *
   * @param percentage 0-200
   */
  private onEnvironmentIntensitySliderChangeEnd(percentage: number): void {
    this.environmentIntensityPercentage = Math.round(percentage);
    const intensity: number = percentage / 100.0;
    this.pendingEnvironmentIntensity = intensity;
    if (this.environmentUpdateTimerId !== -1) {
      clearTimeout(this.environmentUpdateTimerId);
      this.environmentUpdateTimerId = -1;
    }
    this.environmentUpdateScheduled = false;
    this.commitEnvironmentUpdate();
  }

  /**
   * Phase 2F: 调度环境强度节流更新。
   */
  private scheduleEnvironmentUpdate(): void {
    if (this.environmentUpdateScheduled) {
      return;
    }
    this.environmentUpdateScheduled = true;
    const generation: number = this.environmentUpdateGeneration;
    this.environmentUpdateTimerId = setTimeout(() => {
      this.environmentUpdateTimerId = -1;
      this.environmentUpdateScheduled = false;
      if (generation !== this.environmentUpdateGeneration) {
        return;
      }
      this.commitEnvironmentUpdate();
    }, this.ENVIRONMENT_UPDATE_THROTTLE_MS);
  }

  /**
   * Phase 2F: 实际提交环境强度到 Bridge。
   */
  private commitEnvironmentUpdate(): void {
    if (this.viewerState !== ArkWebViewerState.READY) {
      return;
    }
    if (this.environmentState !== 'READY') {
      return;
    }
    const intensity: number = this.pendingEnvironmentIntensity;
    this.arkWebController.setEnvironmentIntensity(intensity).then((resultJson: string) => {
      try {
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          const actualIntensity = (obj['intensity'] as number) ?? intensity;
          this.environmentIntensity = actualIntensity;
          this.environmentIntensityPercentage = Math.round(actualIntensity * 100.0);
        } else {
          const errorObj = obj['error'] as Record<string, Object>;
          const code = errorObj ? (errorObj['code'] as string) : 'UNKNOWN';
          console.warn('[VrmViewerPage] setEnvironmentIntensity failed: ' + code);
        }
      } catch (e) {
        console.warn('[VrmViewerPage] setEnvironmentIntensity parse failed');
      }
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] setEnvironmentIntensity exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  /** 计算抽屉高度 */
  private getDrawerHeight(): number {
    if (this.pageHeight <= 0) {
      return this.DRAWER_HEADER_HEIGHT;
    }
    if (this.drawerState === DrawerState.Collapsed) {
      return this.DRAWER_HEADER_HEIGHT;
    } else if (this.drawerState === DrawerState.Half) {
      return Math.max(this.DRAWER_HEADER_HEIGHT, Math.round(this.pageHeight * 0.4));
    } else {
      return Math.max(this.DRAWER_HEADER_HEIGHT, Math.round(this.pageHeight * 0.7));
    }
  }

  /** 抽屉状态显示标签 */
  private drawerStateLabel(): string {
    if (this.drawerState === DrawerState.Collapsed) {
      return '收起';
    } else if (this.drawerState === DrawerState.Half) {
      return '半展开';
    } else {
      return '展开';
    }
  }

  /** 切换抽屉状态:collapsed → half → expanded → collapsed */
  private cycleDrawerState(): void {
    if (this.drawerState === DrawerState.Collapsed) {
      this.drawerState = DrawerState.Half;
    } else if (this.drawerState === DrawerState.Half) {
      this.drawerState = DrawerState.Expanded;
    } else {
      this.drawerState = DrawerState.Collapsed;
    }
  }

  /** 显示占位提示(快捷工具栏 / 更多 按钮) */
  private showPlaceholderToast(): void {
    this.lastMessage = '该功能将在后续阶段启用';
    promptAction.showToast({ message: '该功能将在后续阶段启用' });
  }

  /**
   * Phase 2A-2: 聚焦按钮。
   *
   * 聚焦到当前已加载模型,计算包围盒并调整相机位置和目标。
   * 成功后刷新 Camera Debug,失败显示具体错误。
   */
  private async onFocusButton(): Promise<void> {
    try {
      const resultJson: string = await this.arkWebController.focusCameraOnCurrentModel();
      if (resultJson && resultJson.length > 0) {
        const cameraState: ArkWebCameraState | null = parseCameraState(resultJson);
        if (cameraState) {
          this.updateCameraDebugState(cameraState);
          promptAction.showToast({ message: '已聚焦' });
        } else {
          promptAction.showToast({ message: '聚焦失败:状态解析失败' });
        }
      } else {
        promptAction.showToast({ message: '聚焦失败:Viewer 未就绪或无模型' });
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      promptAction.showToast({ message: '聚焦失败:' + msg });
    }
  }

  /**
   * Phase 2B: 重置按钮(用户可见的默认重置行为)。
   *
   * 调用 smoothResetCamera() 启动平滑重置过渡。
   * - 同步启动,异步完成(由帧循环驱动)
   * - 启动后立即禁用重置按钮
   * - 启动状态轮询(100ms 间隔,最长 3 秒)
   * - 终态 (COMPLETED/CANCELLED/FAILED/DISPOSED) 停止轮询并恢复按钮
   * - COMPLETED 时刷新 Camera Debug
   *
   * 即时重置 API resetCamera() 保留,本阶段不暴露第二个常驻按钮。
   */
  private async onResetButton(): Promise<void> {
    if (this.resetButtonDisabled) {
      promptAction.showToast({ message: '正在重置,请稍候' });
      return;
    }
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: '重置失败:Viewer 未就绪' });
      return;
    }
    this.resetButtonDisabled = true;
    try {
      const resultJson: string = await this.arkWebController.smoothResetCamera(
        ARKWEB_CAMERA_SMOOTH_RESET_DEFAULT_DURATION,
        true
      );
      const parsed: ArkWebCameraTransitionResult | null = parseCameraTransitionResult(resultJson);
      if (parsed === null) {
        promptAction.showToast({ message: '重置失败:启动结果解析失败' });
        this.resetButtonDisabled = false;
        return;
      }
      if (parsed.state === ArkWebCameraTransitionState.RUNNING) {
        // 启动成功,开始轮询
        this.updateCameraTransitionDebugState(parsed);
        this.startCameraTransitionPolling();
        promptAction.showToast({ message: '正在重置...' });
      } else {
        // 启动失败或状态非 RUNNING (例如 ALREADY_RUNNING 已被取消等)
        this.updateCameraTransitionDebugState(parsed);
        this.resetButtonDisabled = false;
        const errMsg: string = parsed.errorMessage.length > 0
          ? parsed.errorMessage
          : (parsed.errorCode.length > 0 ? parsed.errorCode : '未知错误');
        promptAction.showToast({ message: '重置失败:' + errMsg });
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.resetButtonDisabled = false;
      promptAction.showToast({ message: '重置失败:' + msg });
    }
  }

  /**
   * Phase 2B: 启动相机过渡状态轮询。
   *
   * - 间隔:ARKWEB_CAMERA_TRANSITION_POLL_INTERVAL_MS (100ms)
   * - 超时:ARKWEB_CAMERA_TRANSITION_POLL_TIMEOUT_MS (3000ms)
   * - 终态 (COMPLETED/CANCELLED/FAILED/DISPOSED) 停止轮询
   * - 页面销毁时停止轮询 (stopCameraTransitionPolling)
   */
  private startCameraTransitionPolling(): void {
    this.stopCameraTransitionPolling();
    this.cameraTransitionPollStartedAt = Date.now();
    this.cameraTransitionPollTimerId = setInterval(
      () => { this.pollCameraTransitionState(); },
      ARKWEB_CAMERA_TRANSITION_POLL_INTERVAL_MS
    );
  }

  /**
   * Phase 2B: 停止相机过渡状态轮询(取消计时器,不重置状态变量)。
   */
  private stopCameraTransitionPolling(): void {
    if (this.cameraTransitionPollTimerId !== -1) {
      clearInterval(this.cameraTransitionPollTimerId);
      this.cameraTransitionPollTimerId = -1;
    }
    this.cameraTransitionPollStartedAt = 0;
  }

  /**
   * Phase 2B: 轮询一次相机过渡状态。
   *
   * 终态时:
   * - 停止轮询
   * - 恢复重置按钮
   * - COMPLETED 时刷新 Camera Debug
   * - 超时强制停止轮询并恢复按钮 (保留最后一次状态)
   */
  private async pollCameraTransitionState(): Promise<void> {
    // 超时检查
    const elapsedMs: number = Date.now() - this.cameraTransitionPollStartedAt;
    if (elapsedMs >= ARKWEB_CAMERA_TRANSITION_POLL_TIMEOUT_MS) {
      console.warn('[VrmViewerPage] camera transition poll timeout, stopping');
      this.stopCameraTransitionPolling();
      this.resetButtonDisabled = false;
      return;
    }
    try {
      const resultJson: string = await this.arkWebController.getCameraTransitionState();
      const parsed: ArkWebCameraTransitionResult | null = parseCameraTransitionResult(resultJson);
      if (parsed === null) {
        console.warn('[VrmViewerPage] pollCameraTransitionState: parse failed');
        return;
      }
      this.updateCameraTransitionDebugState(parsed);
      // 终态检查
      if (parsed.state === ArkWebCameraTransitionState.COMPLETED ||
          parsed.state === ArkWebCameraTransitionState.CANCELLED ||
          parsed.state === ArkWebCameraTransitionState.FAILED ||
          parsed.state === ArkWebCameraTransitionState.DISPOSED) {
        this.stopCameraTransitionPolling();
        this.resetButtonDisabled = false;
        // COMPLETED 时刷新 Camera Debug
        if (parsed.state === ArkWebCameraTransitionState.COMPLETED) {
          this.refreshCameraDebugState();
          promptAction.showToast({ message: '已重置' });
        } else if (parsed.state === ArkWebCameraTransitionState.CANCELLED) {
          promptAction.showToast({ message: '重置已取消:' + parsed.cancelReason });
        } else if (parsed.state === ArkWebCameraTransitionState.FAILED) {
          promptAction.showToast({ message: '重置失败:' + parsed.errorCode });
        }
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.warn('[VrmViewerPage] pollCameraTransitionState failed: ' + msg);
    }
  }

  /**
   * Phase 2B: 用 ArkWebCameraTransitionResult 更新 Camera Transition Debug 状态变量。
   *
   * @param transition 解析后的过渡结果
   */
  private updateCameraTransitionDebugState(transition: ArkWebCameraTransitionResult): void {
    this.debugCameraTransitionState = transition.state;
    this.debugCameraTransitionProgress = transition.progress;
    this.debugCameraTransitionDuration = transition.durationSeconds;
    this.debugCameraTransitionElapsed = transition.elapsedSeconds;
    this.debugCameraTransitionCancelReason = transition.cancelReason;
    this.debugCameraTransitionErrorCode = transition.errorCode;
    this.debugCameraTransitionErrorMessage = transition.errorMessage;
  }

  /**
   * Phase 2B: 重置 Camera Transition Debug 状态到 IDLE (页面重新进入时)。
   */
  private resetCameraTransitionDebugState(): void {
    this.debugCameraTransitionState = 'IDLE';
    this.debugCameraTransitionProgress = 0;
    this.debugCameraTransitionDuration = 0;
    this.debugCameraTransitionElapsed = 0;
    this.debugCameraTransitionCancelReason = '';
    this.debugCameraTransitionErrorCode = '';
    this.debugCameraTransitionErrorMessage = '';
    this.resetButtonDisabled = false;
  }

  /**
   * Phase 2A-3A: 截图按钮。
   *
   * 捕获 Three.js 3D 视口(ArkWeb 快照),编码为 PNG,原子写入应用缓存。
   * 截图期间只禁用截图按钮,不禁用 Frame Loop / 模型 / 相机 / 页面。
   * 成功显示文件名/尺寸/大小,失败显示具体错误码。
   */
  private async onScreenshotButton(): Promise<void> {
    if (this.screenshotController === null) {
      promptAction.showToast({ message: '截图控制器未初始化' });
      return;
    }
    if (this.screenshotInProgress) {
      promptAction.showToast({ message: '截图进行中,请稍候' });
      return;
    }
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: 'Viewer 未就绪' });
      return;
    }

    this.screenshotInProgress = true;
    this.screenshotState = 'CAPTURING';
    this.screenshotErrorCode = '';
    this.screenshotErrorMessage = '';

    try {
      const result: ScreenshotResult = await this.screenshotController.capture();
      this.updateScreenshotState(result);
      if (result.state === ScreenshotState.READY) {
        promptAction.showToast({
          message: `截图已保存到应用缓存\n${result.fileName}\n${result.width}x${result.height} · ${this.formatByteLength(result.byteLength)}`
        });
      } else {
        promptAction.showToast({
          message: `截图失败:${result.errorCode}\n${result.errorMessage}`
        });
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.screenshotState = 'FAILED';
      this.screenshotErrorCode = ScreenshotErrorCode.EXCEPTION;
      this.screenshotErrorMessage = msg;
      promptAction.showToast({ message: '截图失败:' + msg });
    } finally {
      this.screenshotInProgress = false;
    }
  }

  /**
   * Phase 2A-3A: 更新截图 @State(从 ScreenshotResult)。
   *
   * 安全约束:不显示 cachePath。
   */
  private updateScreenshotState(result: ScreenshotResult): void {
    this.screenshotState = result.state;
    this.screenshotFileName = result.fileName;
    this.screenshotWidth = result.width;
    this.screenshotHeight = result.height;
    this.screenshotByteLength = result.byteLength;
    this.screenshotCreatedAt = result.createdAt;
    this.screenshotErrorCode = result.errorCode;
    this.screenshotErrorMessage = result.errorMessage;
  }

  /**
   * Phase 2A-3A: 格式化字节数为可读字符串。
   */
  private formatByteLength(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
  }

  /**
   * Phase 2A-3A: 格式化时间戳为可读字符串。
   */
  private formatTimestamp(ts: number): string {
    if (ts === 0) {
      return '-';
    }
    const d: Date = new Date(ts);
    const yyyy: string = String(d.getFullYear());
    const mm: string = String(d.getMonth() + 1).padStart(2, '0');
    const dd: string = String(d.getDate()).padStart(2, '0');
    const hh: string = String(d.getHours()).padStart(2, '0');
    const mi: string = String(d.getMinutes()).padStart(2, '0');
    const ss: string = String(d.getSeconds()).padStart(2, '0');
    return `${yyyy}-${mm}-${dd} ${hh}:${mi}:${ss}`;
  }

  /**
   * "导入模型"按钮:调用系统文件选择器并复制到受控缓存。
   *
   * Phase 1D-2A:
   * - 导入成功后调用 resourceProvider.registerFile(file)
   * - 生成受控资源 URL(不调用 loadModel)
   * - 资源注册失败:保留缓存文件,默认模型继续显示
   *
   * Phase 1D-1:
   * - 调用 importController.pickModelFile()
   * - 成功:显示"模型文件已准备,等待加载"
   * - 用户取消:显示"已取消选择"(非错误)
   * - 失败:显示错误信息
   * - 不调用 JavaScript loadModel
   * - 不替换默认 VRM
   */
  private async onImportModelButton(): Promise<void> {
    if (this.importController === null) {
      promptAction.showToast({ message: '导入控制器未初始化' });
      return;
    }
    if (this.importInProgress) {
      // 已有操作进行中,忽略重复点击
      return;
    }
    // Phase 1D-2B-2:用户模型加载期间禁止导入新模型
    if (this.loadInProgress) {
      promptAction.showToast({ message: '模型加载中,请稍候' });
      return;
    }
    this.importInProgress = true;
    this.importState = ModelImportState.PICKING;
    try {
      const result: ImportedModelFile | null = await this.importController.pickModelFile();
      // 同步状态到 @State
      this.importState = this.importController.getState();
      this.importLastError = this.importController.getLastError();
      this.importedFile = this.importController.getCurrentFile();

      if (result === null) {
        // 用户取消或失败
        if (this.importState === ModelImportState.CANCELLED) {
          promptAction.showToast({ message: '已取消选择' });
        } else if (this.importState === ModelImportState.FAILED) {
          promptAction.showToast({ message: `导入失败: ${this.importLastError}` });
        }
        // STALE_IMPORT_RESULT / DISPOSED 静默处理
      } else {
        // Phase 1D-2A:导入成功后注册资源(生成受控 URL)
        // Phase 1D-2C-2E-1:await 确保 prepare + readback 完成后再继续
        await this.registerImportedResource(result);
        // Phase 1D-2C-1:导入成功后持久化元数据到 StateStore
        // 保存失败不影响当前导入,只显示提示
        this.saveImportStateToStore(result);
        // 不调用 loadModel(Phase 1D-2B)
        // 不替换默认 VRM
        promptAction.showToast({ message: '模型文件已准备,等待加载' });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.importState = ModelImportState.FAILED;
      this.importLastError = msg;
      promptAction.showToast({ message: `导入异常: ${msg}` });
    } finally {
      this.importInProgress = false;
    }
  }

  /**
   * 注册已导入的模型文件到资源 Provider(Phase 1D-2A,1D-2C-2E-1 修正调用顺序)。
   *
   * 正确顺序(AGENTS.md Phase 1D-2C-2E-1 §十一 导入成功路径):
   *   ImportedModelFile READY
   *   → ResourceProvider.registerFile()
   *   → Native resourceState = READY
   *   → 等待 Viewer READY(若未 READY,ensurePreparedModelResource 会返回 VIEWER_NOT_READY)
   *   → ensurePreparedModelResource()
   *   → WebPrepared READY
   *   → tryAutoProbeResource()
   *
   * 失败处理:
   * - registerFile 失败:保留缓存文件,Provider state 保持 EMPTY,页面显示资源准备失败
   * - ensurePreparedModelResource 失败:保留 ImportedModelFile + Native ResourceProvider + 资源 URL,
   *   webPreparedState = FAILED,不启动 probe,允许用户重试
   *
   * @param file 已导入的模型文件
   */
  private async registerImportedResource(file: ImportedModelFile): Promise<void> {
    if (this.resourceProvider === null) {
      this.resourceState = ModelResourceState.EMPTY;
      this.preparedResource = null;
      this.resourceLastError = 'resourceProvider not initialized';
      return;
    }
    let resource: WebModelResource;
    try {
      resource = this.resourceProvider.registerFile(file);
      this.preparedResource = resource;
      this.resourceState = this.resourceProvider.getState();
      this.resourceLastError = '';
      console.info(`[VrmViewerPage] resource ready: url=${resource.resourceUrl}`);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.preparedResource = null;
      this.resourceState = this.resourceProvider.getState();
      this.resourceLastError = msg;
      console.error(`[VrmViewerPage] registerResource failed: ${msg}`);
      return;
    }

    // Phase 1D-2C-2E-1: 统一资源准备(prepare + readback),严格等待完成后再探测
    // 失败时 webPreparedState = FAILED,不启动 probe,保留缓存和 Native Resource
    const prepared: boolean = await this.ensurePreparedModelResource(resource, false);
    if (!prepared) {
      console.warn(`[VrmViewerPage] import ensurePreparedModelResource failed: ${this.webPreparedErrorCode}`);
      return;
    }
    // Phase 1D-2C-1:资源准备完成后尝试自动探测(满足条件时执行一次)
    this.tryAutoProbeResource();
  }

  /**
   * 统一资源准备方法(Phase 1D-2C-2E-1)。
   *
   * 替代原 fire-and-forget 的 notifyPreparedResourceToWeb,严格保证:
   *   1. 检查 ViewerState === READY
   *   2. 检查 resourceProvider state === READY
   *   3. 检查 resource 非 null
   *   4. 检查没有用户模型加载操作
   *   5. generation++
   *   6. webPreparedState = PREPARING
   *   7. 序列化公共资源字段(白名单,JSON.stringify)
   *   8. 调用 prepareModelResource(resourceJson)
   *   9. 解析返回 JSON
   *  10. 验证 success === true
   *  11. 验证 state === RESOURCE_READY
   *  12. 调用 getPreparedModelResource()
   *  13. 解析回读 JSON
   *  14. 验证资源字段完全一致(resourceUrl / displayName / mimeType / size / extension / gltfDependencyState)
   *  15. 检查 generation 未过期
   *  16. 提交 webPreparedState = READY
   *  17. 保存 lastPreparedResourceUrl
   *  18. 返回 true
   *
   * 失败时:
   * - 保留 ImportedModelFile
   * - 保留 Native ResourceProvider
   * - 保留资源 URL
   * - 不启动 probe
   * - 不启动 GLTFLoader
   * - 保持立方体
   * - 允许用户重试
   *
   * @param resource 已注册的公共资源(由 resourceProvider.registerFile 产出)
   * @param allowRetry 是否允许在已有 prepare 进行中时重试(手动验证按钮传 true)
   * @returns true 表示准备成功,false 表示失败(错误码已写入 webPreparedErrorCode)
   */
  private async ensurePreparedModelResource(
    resource: WebModelResource,
    allowRetry: boolean
  ): Promise<boolean> {
    // 1. 检查 ViewerState === READY
    if (this.viewerState !== ArkWebViewerState.READY) {
      this.webPreparedState = WebPreparedResourceState.FAILED;
      this.webPreparedErrorCode = WebPreparedResourceErrorCode.VIEWER_NOT_READY;
      this.webPreparedErrorMessage = 'Viewer 未就绪';
      console.warn(`[VrmViewerPage] ensurePreparedModelResource rejected: viewerState=${this.viewerState}`);
      return false;
    }
    // 2. 检查 resourceProvider state === READY
    if (this.resourceState !== ModelResourceState.READY) {
      this.webPreparedState = WebPreparedResourceState.FAILED;
      this.webPreparedErrorCode = WebPreparedResourceErrorCode.NATIVE_RESOURCE_NOT_READY;
      this.webPreparedErrorMessage = 'Native 资源未就绪';
      console.warn(`[VrmViewerPage] ensurePreparedModelResource rejected: resourceState=${this.resourceState}`);
      return false;
    }
    // 3. 检查 resource 非 null
    if (resource === null) {
      this.webPreparedState = WebPreparedResourceState.FAILED;
      this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_NULL;
      this.webPreparedErrorMessage = '资源元数据为空';
      console.warn('[VrmViewerPage] ensurePreparedModelResource rejected: resource null');
      return false;
    }
    // 4. 检查没有用户模型加载操作
    if (this.loadInProgress) {
      this.webPreparedState = WebPreparedResourceState.FAILED;
      this.webPreparedErrorCode = WebPreparedResourceErrorCode.MODEL_LOAD_IN_PROGRESS;
      this.webPreparedErrorMessage = '用户模型加载中';
      console.warn('[VrmViewerPage] ensurePreparedModelResource rejected: loadInProgress');
      return false;
    }
    // 检查 prepare 进行中(allowRetry 时跳过,手动验证按钮可重试)
    if (this.prepareInProgress && !allowRetry) {
      this.webPreparedState = WebPreparedResourceState.FAILED;
      this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_IN_PROGRESS;
      this.webPreparedErrorMessage = '资源准备进行中';
      console.warn('[VrmViewerPage] ensurePreparedModelResource rejected: prepareInProgress');
      return false;
    }

    // 5. generation++
    this.prepareGeneration++;
    const currentGeneration: number = this.prepareGeneration;

    // 6. webPreparedState = PREPARING
    this.webPreparedState = WebPreparedResourceState.PREPARING;
    this.webPreparedErrorCode = '';
    this.webPreparedErrorMessage = '';
    this.prepareInProgress = true;

    try {
      // 7. 序列化公共资源字段(白名单,JSON.stringify)
      // 禁止发送:cachePath / sourceUri / 文件描述符 / Preferences 记录 / Native Provider 内部对象
      const payload: Record<string, Object> = {
        'resourceUrl': resource.resourceUrl,
        'displayName': resource.displayName,
        'mimeType': resource.mimeType,
        'size': resource.size,
        'extension': resource.extension,
        'gltfDependencyState': resource.gltfDependencyState
      };
      const resourceJson: string = JSON.stringify(payload);

      // 8. 调用 prepareModelResource(resourceJson)
      const prepareResult: string = await this.arkWebController.prepareModelResource(resourceJson);

      // 9. 解析返回 JSON
      let parsedPrepare: Record<string, Object>;
      try {
        parsedPrepare = JSON.parse(prepareResult) as Record<string, Object>;
      } catch (e) {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_RESULT_INVALID;
        this.webPreparedErrorMessage = `prepareModelResource 返回非 JSON: ${prepareResult}`;
        console.error(`[VrmViewerPage] prepareModelResource result invalid: ${prepareResult}`);
        return false;
      }

      // 10. 验证 success === true
      if (parsedPrepare['success'] !== true) {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_REJECTED;
        const errorObj: Object | undefined = parsedPrepare['error'];
        if (errorObj !== undefined && errorObj !== null) {
          const errRecord: Record<string, Object> = errorObj as Record<string, Object>;
          this.webPreparedErrorMessage =
            `keeper 拒绝: ${(errRecord['code'] as string) || ''} ${(errRecord['message'] as string) || ''}`.trim();
        } else {
          this.webPreparedErrorMessage = `keeper 拒绝: ${prepareResult}`;
        }
        console.warn(`[VrmViewerPage] prepareModelResource rejected: ${this.webPreparedErrorMessage}`);
        return false;
      }

      // 11. 验证 state === RESOURCE_READY(允许 keeper 返回额外字段,但 state 必须匹配)
      const returnedState: string = (parsedPrepare['state'] as string) || '';
      if (returnedState !== 'RESOURCE_READY') {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_RESULT_INVALID;
        this.webPreparedErrorMessage = `state 非 RESOURCE_READY: ${returnedState}`;
        console.warn(`[VrmViewerPage] prepareModelResource state invalid: ${returnedState}`);
        return false;
      }

      // 12. 调用 getPreparedModelResource() 回读
      const getResult: string = await this.arkWebController.getPreparedModelResource();

      // 13. 解析回读 JSON
      let parsedGet: Record<string, Object>;
      try {
        parsedGet = JSON.parse(getResult) as Record<string, Object>;
      } catch (e) {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_READBACK_INVALID;
        this.webPreparedErrorMessage = `getPreparedModelResource 返回非 JSON: ${getResult}`;
        console.error(`[VrmViewerPage] getPreparedModelResource result invalid: ${getResult}`);
        return false;
      }

      if (parsedGet['success'] !== true) {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_READBACK_INVALID;
        this.webPreparedErrorMessage = `getPreparedModelResource success=false: ${getResult}`;
        console.warn(`[VrmViewerPage] getPreparedModelResource success=false: ${getResult}`);
        return false;
      }

      // 14. 验证资源字段完全一致
      const readbackResourceObj: Object | undefined = parsedGet['resource'];
      if (readbackResourceObj === undefined || readbackResourceObj === null) {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_READBACK_EMPTY;
        this.webPreparedErrorMessage = '回读资源为 null(keeper 未保存)';
        console.warn('[VrmViewerPage] getPreparedModelResource readback resource null');
        return false;
      }

      const readbackResource: Record<string, Object> = readbackResourceObj as Record<string, Object>;

      // 从 resourceUrl 提取 opaque ID,确认 /model/<opaque-id> 存在且非空
      if (!isModelResourceUrl(resource.resourceUrl)) {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_READBACK_MISMATCH;
        this.webPreparedErrorMessage = `resourceUrl 非受控 URL: ${resource.resourceUrl}`;
        console.warn(`[VrmViewerPage] resourceUrl not controlled: ${resource.resourceUrl}`);
        return false;
      }
      const opaqueId: string | null = extractOpaqueIdFromUrl(resource.resourceUrl);
      if (opaqueId === null || opaqueId.length === 0) {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_READBACK_MISMATCH;
        this.webPreparedErrorMessage = `opaque ID 为空: ${resource.resourceUrl}`;
        console.warn(`[VrmViewerPage] opaque id empty: ${resource.resourceUrl}`);
        return false;
      }

      // 字段逐一比对(完全一致)
      const readbackResourceUrl: string = (readbackResource['resourceUrl'] as string) || '';
      const readbackDisplayName: string = (readbackResource['displayName'] as string) || '';
      const readbackMimeType: string = (readbackResource['mimeType'] as string) || '';
      const readbackSize: number = this.safeNumber(readbackResource['size'], -1);
      const readbackExtension: string = (readbackResource['extension'] as string) || '';
      const readbackGltfDep: string = (readbackResource['gltfDependencyState'] as string) || '';

      if (readbackResourceUrl !== resource.resourceUrl ||
          readbackDisplayName !== resource.displayName ||
          readbackMimeType !== resource.mimeType ||
          readbackSize !== resource.size ||
          readbackExtension !== resource.extension ||
          readbackGltfDep !== resource.gltfDependencyState) {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_READBACK_MISMATCH;
        this.webPreparedErrorMessage =
          `回读不一致: url=${readbackResourceUrl === resource.resourceUrl ? 'ok' : 'X'}, ` +
          `name=${readbackDisplayName === resource.displayName ? 'ok' : 'X'}, ` +
          `mime=${readbackMimeType === resource.mimeType ? 'ok' : 'X'}, ` +
          `size=${readbackSize === resource.size ? 'ok' : 'X'}, ` +
          `ext=${readbackExtension === resource.extension ? 'ok' : 'X'}, ` +
          `dep=${readbackGltfDep === resource.gltfDependencyState ? 'ok' : 'X'}`;
        console.warn(`[VrmViewerPage] readback mismatch: ${this.webPreparedErrorMessage}`);
        return false;
      }

      // 15. 检查 generation 未过期
      if (currentGeneration !== this.prepareGeneration) {
        this.webPreparedState = WebPreparedResourceState.FAILED;
        this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_STALE;
        this.webPreparedErrorMessage =
          `generation 过期: current=${currentGeneration}, latest=${this.prepareGeneration}`;
        console.warn(`[VrmViewerPage] prepare generation stale: ${this.webPreparedErrorMessage}`);
        return false;
      }

      // 16. 提交 webPreparedState = READY
      this.webPreparedState = WebPreparedResourceState.READY;
      this.webPreparedErrorCode = '';
      this.webPreparedErrorMessage = '';
      // 17. 保存 lastPreparedResourceUrl
      this.lastPreparedResourceUrl = resource.resourceUrl;
      console.info(`[VrmViewerPage] ensurePreparedModelResource ok: url=${resource.resourceUrl}`);
      // 18. 返回 true
      return true;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.webPreparedState = WebPreparedResourceState.FAILED;
      this.webPreparedErrorCode = WebPreparedResourceErrorCode.RESOURCE_PREPARE_CALL_FAILED;
      this.webPreparedErrorMessage = `prepare 调用异常: ${msg}`;
      console.error(`[VrmViewerPage] ensurePreparedModelResource exception: ${msg}`);
      return false;
    } finally {
      this.prepareInProgress = false;
    }
  }

  /**
   * 重置 Web Prepared 状态到 EMPTY(用于资源注销 / 清除缓存)。
   */
  private resetWebPreparedState(): void {
    this.webPreparedState = WebPreparedResourceState.EMPTY;
    this.webPreparedErrorCode = '';
    this.webPreparedErrorMessage = '';
    this.lastPreparedResourceUrl = '';
    this.prepareInProgress = false;
  }

  // ===== Phase 1D-2C-1: 导入状态恢复与自动探测 =====

  /**
   * 启动从 StateStore 恢复上次导入的模型元数据。
   *
   * 流程(AGENTS.md Phase 1D-2C-1 §十 页面恢复顺序):
   * 1. StateStore.restore() 读取并验证持久化记录
   * 2. 验证成功:获取 ImportedModelFile
   * 3. ImportController.restoreCurrentFile(file) 注入到当前控制器
   * 4. 检查 Viewer 是否 READY:
   *    - READY:立即注册资源 + prepareModelResource + 自动探测
   *    - 未 READY:暂存 pendingRestoredFile,等待 onViewerReady 回调处理
   *
   * 失败处理:
   * - Preferences 无记录:静默(页面正常打开)
   * - 记录损坏:StateStore 自动 clear,页面显示"上次导入文件已失效"
   * - restoreCurrentFile 拒绝:页面显示错误
   */
  private async startRestoreFromStateStore(): Promise<void> {
    if (this.importStateStore === null) {
      return;
    }
    if (this.restoreInProgress) {
      return;
    }
    this.restoreInProgress = true;
    this.restoreGeneration++;
    const generation: number = this.restoreGeneration;

    try {
      const result: ImportStateRestoreResult = await this.importStateStore.restore();
      // 代次检查:若期间发起新恢复或已 dispose,放弃此次结果
      if (generation !== this.restoreGeneration) {
        console.info('[VrmViewerPage] restore result stale, ignored');
        return;
      }

      if (result.file === null) {
        // 无记录或损坏记录
        if (result.errorCode.length > 0) {
          this.restoreErrorCode = result.errorCode;
          this.restoreErrorMessage = result.errorMessage;
          this.restoreHint = '上次导入文件已失效';
          console.warn(`[VrmViewerPage] restore failed: ${result.errorCode} ${result.errorMessage}`);
        } else {
          // 无记录,正常情况
          this.restoreHint = '';
        }
        return;
      }

      // 恢复成功:注入到 ImportController
      const file: ImportedModelFile = result.file;
      if (this.importController === null) {
        console.warn('[VrmViewerPage] importController null during restore');
        return;
      }
      const restoreOk: boolean = this.importController.restoreCurrentFile(file);
      if (!restoreOk) {
        this.restoreErrorCode = 'RESTORE_CURRENT_FILE_REJECTED';
        this.restoreErrorMessage = 'ImportController 拒绝恢复文件';
        this.restoreHint = '恢复失败,请重新导入';
        return;
      }

      // 同步状态到 @State
      this.importState = this.importController.getState();
      this.importedFile = this.importController.getCurrentFile();
      this.importLastError = this.importController.getLastError();
      this.restoreHint = '已恢复上次导入模型,正在重新验证';

      console.info(`[VrmViewerPage] restore ok id=${file.id} size=${file.size} ext=${file.extension}`);

      // 检查 Viewer 是否 READY
      if (this.viewerState === ArkWebViewerState.READY) {
        // Viewer 已就绪,立即处理
        // Phase 1D-2C-2E-1:await 确保 prepare + readback 完成后再继续
        await this.processRestoredFile(file);
      } else {
        // Viewer 未就绪,暂存等待 onViewerReady
        this.pendingRestoredFile = file;
        console.info('[VrmViewerPage] Viewer not ready, pending restored file');
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.restoreErrorCode = 'RESTORE_EXCEPTION';
      this.restoreErrorMessage = msg;
      this.restoreHint = '恢复异常,请重新导入';
      console.error(`[VrmViewerPage] restore exception: ${msg}`);
    } finally {
      this.restoreInProgress = false;
    }
  }

  /**
   * 处理恢复的文件:注册资源 + ensurePreparedModelResource + 自动探测。
   *
   * 由 startRestoreFromStateStore(Viewer 已 READY)或 onViewerReady 回调(Viewer 刚 READY)调用。
   *
   * 正确顺序(AGENTS.md Phase 1D-2C-2E-1 §十一 页面恢复路径):
   *   StateStore.restore()
   *   → ImportController.restoreCurrentFile()
   *   → 等待 Viewer READY
   *   → ResourceProvider.registerFile()
   *   → ensurePreparedModelResource()
   *   → WebPrepared READY
   *   → 自动 HEAD 探测一次
   *
   * 不得因为页面已经恢复资源 URL,就跳过 prepareModelResource()。
   *
   * 失败处理:
   * - registerFile 失败:restoreHint 显示"资源准备失败"
   * - ensurePreparedModelResource 失败:webPreparedState = FAILED,不启动 probe,允许用户重试
   */
  private async processRestoredFile(file: ImportedModelFile): Promise<void> {
    if (this.resourceProvider === null) {
      this.restoreHint = '资源 Provider 未初始化';
      return;
    }
    let resource: WebModelResource;
    try {
      resource = this.resourceProvider.registerFile(file);
      this.preparedResource = resource;
      this.resourceState = this.resourceProvider.getState();
      this.resourceLastError = '';
      console.info(`[VrmViewerPage] restored resource ready: url=${resource.resourceUrl}`);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.preparedResource = null;
      this.resourceState = this.resourceProvider.getState();
      this.resourceLastError = msg;
      this.restoreHint = `资源准备失败: ${msg}`;
      console.error(`[VrmViewerPage] processRestoredFile register failed: ${msg}`);
      return;
    }

    // Phase 1D-2C-2E-1: 统一资源准备(prepare + readback),严格等待完成后再探测
    // 不得因为页面已经恢复资源 URL,就跳过 prepareModelResource()
    const prepared: boolean = await this.ensurePreparedModelResource(resource, false);
    if (!prepared) {
      console.warn(`[VrmViewerPage] restore ensurePreparedModelResource failed: ${this.webPreparedErrorCode}`);
      this.restoreHint = `资源同步失败: ${this.webPreparedErrorMessage}`;
      return;
    }
    // 自动探测(满足条件时执行一次)
    this.tryAutoProbeResource();
  }

  /**
   * 保存当前导入的模型元数据到 StateStore。
   *
   * 时机:
   * - 导入成功后(onImportModelButton)
   * - 缓存文件完整复制 + rename 成功 + 文件大小验证通过之后
   *
   * 失败处理:
   * - 缓存文件与当前导入仍可继续使用
   * - 页面显示"模型已导入,但重进恢复信息保存失败"
   * - 不删除缓存文件
   */
  private async saveImportStateToStore(file: ImportedModelFile): Promise<void> {
    if (this.importStateStore === null) {
      return;
    }
    try {
      const ok: boolean = await this.importStateStore.save(file);
      if (!ok) {
        console.warn('[VrmViewerPage] import state save failed (cache still usable)');
        promptAction.showToast({ message: '模型已导入,但重进恢复信息保存失败' });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] saveImportStateToStore exception: ${msg}`);
    }
  }

  /**
   * 自动执行 HEAD 探测(Phase 1D-2C-1 §十二)。
   *
   * 触发条件(全部满足才执行):
   * - Viewer READY
   * - PreparedResource 存在
   * - 当前没有探测
   * - 当前没有用户模型加载
   * - resourceUrl 与 PreparedResource 一致
   * - 该 resourceUrl 未自动探测过(同一 URL 只自动探测一次)
   *
   * 自动探测只执行一次:
   * - 维护 lastAutoProbedResourceUrl,避免重复自动探测
   * - 资源更换后允许对新 URL 自动探测一次
   *
   * 失败处理:
   * - 保留"验证资源"按钮,允许用户手动重试
   * - 不自动加载模型
   *
   * 成功处理:
   * - 启用"加载模型"按钮
   * - 仍不自动加载模型
   */
  private tryAutoProbeResource(): void {
    // 前置条件检查(Phase 1D-2C-2E-1:必须同时满足以下全部条件)
    // 1. ViewerState === READY
    if (this.viewerState !== ArkWebViewerState.READY) {
      return;
    }
    // 2. Native ResourceState === READY
    if (this.resourceState !== ModelResourceState.READY) {
      return;
    }
    // 3. WebPreparedResourceState === READY(关键新增:JavaScript keeper 必须已准备)
    if (this.webPreparedState !== WebPreparedResourceState.READY) {
      return;
    }
    // 4. preparedResource !== null
    if (this.preparedResource === null) {
      return;
    }
    // 5. 当前没有 prepare
    if (this.prepareInProgress) {
      return;
    }
    // 6. 当前没有 probe
    if (this.probeInProgress) {
      return;
    }
    // 7. 当前没有 model load
    if (this.loadInProgress) {
      return;
    }
    // 8. lastPreparedResourceUrl === preparedResource.resourceUrl(一致性校验)
    const resourceUrl: string = this.preparedResource.resourceUrl;
    if (resourceUrl !== this.lastPreparedResourceUrl) {
      console.warn(`[VrmViewerPage] auto probe skipped: url mismatch prepared=${resourceUrl} lastPrepared=${this.lastPreparedResourceUrl}`);
      return;
    }
    // 同一 URL 只自动探测一次
    if (resourceUrl === this.lastAutoProbedResourceUrl) {
      return;
    }
    // 已探测过(VERIFIED / FAILED)的 URL 不再自动探测
    if (this.probeState !== ModelResourceProbeState.NOT_PROBED) {
      return;
    }

    // Phase 1D-2C-2E-1: 探测前可做一次轻量回读(可选,若回读为空则标记 FAILED)
    // 这里不阻塞,直接启动探测(executeAutoProbe 内部会调用 probePreparedModelResource,
    // JS 端会再次从 keeper 读取,若为空返回 RESOURCE_NOT_PREPARED)

    this.autoProbeGeneration++;
    this.lastAutoProbedResourceUrl = resourceUrl;
    console.info(`[VrmViewerPage] auto probe started: url=${resourceUrl}`);
    // 直接调用 onProbeResourceButton 的逻辑,但不显示 toast(避免打扰用户)
    this.executeAutoProbe();
  }

  /**
   * 执行自动探测(不显示交互 toast,只更新状态)。
   */
  private async executeAutoProbe(): Promise<void> {
    if (this.preparedResource === null) {
      return;
    }
    if (this.viewerState !== ArkWebViewerState.READY) {
      return;
    }
    if (this.probeInProgress) {
      return;
    }
    if (this.loadInProgress) {
      return;
    }

    // 重置探测状态
    this.resetProbeState();
    this.probeInProgress = true;
    this.probeState = ModelResourceProbeState.PROBING;
    this.probePollCount = 0;

    try {
      const startResult: string = await this.arkWebController.probePreparedModelResource();
      console.info(`[VrmViewerPage] auto probePreparedModelResource result: ${startResult}`);
      if (startResult.indexOf('"success":true') < 0 && startResult.indexOf('"success": true') < 0) {
        // 启动失败
        this.probeState = ModelResourceProbeState.FAILED;
        this.probeErrorCode = 'PROBE_START_FAILED';
        const errorMatch: RegExpMatchArray | null = startResult.match(/"message"\s*:\s*"([^"]*)"/);
        this.probeErrorMessage = errorMatch !== null && errorMatch.length >= 2 ? errorMatch[1] : startResult;
        this.probeVerifiedAt = Date.now();
        this.probeInProgress = false;
        console.warn(`[VrmViewerPage] auto probe start failed: ${this.probeErrorMessage}`);
        return;
      }
      // 启动轮询
      this.startProbePolling();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.probeState = ModelResourceProbeState.FAILED;
      this.probeErrorCode = 'PROBE_START_FAILED';
      this.probeErrorMessage = msg;
      this.probeVerifiedAt = Date.now();
      this.probeInProgress = false;
      console.warn(`[VrmViewerPage] auto probe exception: ${msg}`);
    }
  }

  /**
   * 拉取并应用最新运行时诊断(由轮询或按钮触发)。
   *
   * 调用 arkWebController.getVrmRuntimeDiagnostic() 获取 Web 端最近一条诊断记录。
   * 失败仅日志,不影响页面状态。
   */
  private async refreshRuntimeDiagnostic(): Promise<void> {
    try {
      const resultJson: string = await this.arkWebController.getVrmRuntimeDiagnostic();
      this.applyRuntimeDiagnostic(resultJson);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] refreshRuntimeDiagnostic failed: ${msg}`);
    }
  }

  /**
   * 解析 getVrmRuntimeDiagnostic 返回的 JSON 并更新 @State。
   */
  private applyRuntimeDiagnostic(resultJson: string): void {
    try {
      const parsed: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const success: boolean = parsed['success'] === true;
      if (!success) {
        return;
      }
      const diagObj: Object = parsed['diagnostic'] as Object;
      if (diagObj === null || diagObj === undefined) {
        this.runtimeDiagnostic = null;
        return;
      }
      const diag: Record<string, Object> = diagObj as Record<string, Object>;
      this.runtimeDiagnostic = {
        stage: this.parseVrmStage(this.safeString(diag['stage'], '')),
        code: this.safeString(diag['code'], ''),
        message: this.safeString(diag['message'], ''),
        resourceId: this.safeString(diag['resourceId'], ''),
        requestMethod: this.safeString(diag['requestMethod'], ''),
        httpStatus: this.safeNumber(diag['httpStatus'], 0),
        mimeType: this.safeString(diag['mimeType'], ''),
        contentLength: this.safeNumber(diag['contentLength'], 0),
        timestamp: this.safeNumber(diag['timestamp'], 0)
      };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] applyRuntimeDiagnostic parse failed: ${msg}`);
    }
  }

  /**
   * 解析 VrmRuntimeStage 字符串(无法识别时返回 IDLE)。
   *
   * Phase 1D-2C-2A: 新增启动阶段(ARKWEB_PAGE_END ~ VIEWER_INITIALIZE_FAILED),
   * 用于在 Viewer 初始化失败时显示最近一条启动诊断。
   */
  private parseVrmStage(s: string): VrmRuntimeStage {
    switch (s) {
      case 'IDLE': return VrmRuntimeStage.IDLE;
      // Phase 1D-2C-2A: 启动阶段
      case 'ARKWEB_PAGE_END': return VrmRuntimeStage.ARKWEB_PAGE_END;
      case 'JS_BRIDGE_BOUND': return VrmRuntimeStage.JS_BRIDGE_BOUND;
      case 'INITIALIZE_REQUESTED': return VrmRuntimeStage.INITIALIZE_REQUESTED;
      case 'INITIALIZE_RESULT_RECEIVED': return VrmRuntimeStage.INITIALIZE_RESULT_RECEIVED;
      case 'VIEWER_CONTAINER_FOUND': return VrmRuntimeStage.VIEWER_CONTAINER_FOUND;
      case 'VIEWER_CONTAINER_NOT_FOUND': return VrmRuntimeStage.VIEWER_CONTAINER_NOT_FOUND;
      case 'VIEWER_CORE_INITIALIZING': return VrmRuntimeStage.VIEWER_CORE_INITIALIZING;
      case 'VIEWER_SCENE_READY': return VrmRuntimeStage.VIEWER_SCENE_READY;
      case 'VIEWER_CAMERA_READY': return VrmRuntimeStage.VIEWER_CAMERA_READY;
      case 'VIEWER_MODEL_LOADER_READY': return VrmRuntimeStage.VIEWER_MODEL_LOADER_READY;
      case 'VIEWER_FRAME_LOOP_READY': return VrmRuntimeStage.VIEWER_FRAME_LOOP_READY;
      case 'VIEWER_READY': return VrmRuntimeStage.VIEWER_READY;
      case 'VIEWER_INITIALIZE_FAILED': return VrmRuntimeStage.VIEWER_INITIALIZE_FAILED;
      // Phase 1D-2C-1: 导入/恢复/资源/探测/加载阶段
      case 'IMPORT_READY': return VrmRuntimeStage.IMPORT_READY;
      case 'RESTORE_READY': return VrmRuntimeStage.RESTORE_READY;
      case 'RESOURCE_REGISTERED': return VrmRuntimeStage.RESOURCE_REGISTERED;
      case 'RESOURCE_PREPARED': return VrmRuntimeStage.RESOURCE_PREPARED;
      case 'PROBE_STARTED': return VrmRuntimeStage.PROBE_STARTED;
      case 'PROBE_VERIFIED': return VrmRuntimeStage.PROBE_VERIFIED;
      case 'PROBE_FAILED': return VrmRuntimeStage.PROBE_FAILED;
      case 'LOAD_STARTED': return VrmRuntimeStage.LOAD_STARTED;
      case 'PROVIDER_HEAD': return VrmRuntimeStage.PROVIDER_HEAD;
      case 'PROVIDER_GET': return VrmRuntimeStage.PROVIDER_GET;
      case 'PROVIDER_RESPONSE': return VrmRuntimeStage.PROVIDER_RESPONSE;
      case 'GLTF_LOAD_STARTED': return VrmRuntimeStage.GLTF_LOAD_STARTED;
      case 'GLTF_LOAD_PROGRESS': return VrmRuntimeStage.GLTF_LOAD_PROGRESS;
      case 'GLTF_LOAD_FAILED': return VrmRuntimeStage.GLTF_LOAD_FAILED;
      case 'VRM_DATA_VALIDATED': return VrmRuntimeStage.VRM_DATA_VALIDATED;
      case 'MODEL_REPLACE_STARTED': return VrmRuntimeStage.MODEL_REPLACE_STARTED;
      case 'MODEL_REPLACE_COMMITTED': return VrmRuntimeStage.MODEL_REPLACE_COMMITTED;
      case 'MODEL_REPLACE_FAILED': return VrmRuntimeStage.MODEL_REPLACE_FAILED;
      default: return VrmRuntimeStage.IDLE;
    }
  }

  /** 运行时诊断时间显示(格式化为人类可读) */
  private diagnosticTimestampLabel(): string {
    if (this.runtimeDiagnostic === null || this.runtimeDiagnostic.timestamp <= 0) {
      return '—';
    }
    const date: Date = new Date(this.runtimeDiagnostic.timestamp);
    const h: number = date.getHours();
    const m: number = date.getMinutes();
    const s: number = date.getSeconds();
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return `${hh}:${mm}:${ss}`;
  }

  /** 清除运行时诊断按钮回调 */
  private async onClearDiagnosticButton(): Promise<void> {
    try {
      await this.arkWebController.clearVrmRuntimeDiagnostic();
      this.runtimeDiagnostic = null;
      console.info('[VrmViewerPage] runtime diagnostic cleared');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] clear diagnostic failed: ${msg}`);
    }
  }

  /**
   * Phase 1D-2C-2A: "重试 Viewer" 按钮回调。
   *
   * 仅在 Viewer 处于 FAILED 状态时可用。流程:
   * 1. 防止重复点击(retryInProgress)
   * 2. 清除当前 Viewer 错误(lastErrorCode / lastError)
   * 3. 调用 Controller.retryInitializeViewer()
   *    - Controller 内部校验 FAILED 状态
   *    - 调用 Web 端 retryInitializeViewer(同步返回)
   *    - 状态切换为 INITIALIZING
   *    - 等待 onViewerReady / onViewerError 回调推进状态
   * 4. 状态由 Controller 通过 Listener 回调更新到 @State
   *
   * 不重新进入页面,不重建 Web 组件。
   */
  private async onRetryViewerButton(): Promise<void> {
    if (this.retryInProgress) {
      console.warn('[VrmViewerPage] retry already in progress, ignore');
      return;
    }
    if (this.viewerState !== ArkWebViewerState.FAILED) {
      console.warn(`[VrmViewerPage] retry ignored: viewerState=${this.viewerState} (requires FAILED)`);
      return;
    }
    this.retryInProgress = true;
    // 清除当前错误显示(Controller 也会清除内部 lastError)
    this.lastErrorCode = '';
    this.lastError = '';
    try {
      await this.arkWebController.retryInitializeViewer();
      console.info('[VrmViewerPage] retryInitializeViewer dispatched');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.error(`[VrmViewerPage] retryInitializeViewer failed: ${msg}`);
      this.lastErrorCode = 'RETRY_FAILED';
      this.lastError = `重试失败: ${msg}`;
    } finally {
      this.retryInProgress = false;
    }
  }

  /**
   * "清除缓存文件"按钮:删除当前已导入的缓存文件。
   *
   * Phase 1D-2B-1 清除顺序(AGENTS.md §十六):
   * 1. clearModelResourceProbe() — 清除探测状态(异步,不等待)
   * 2. clearPreparedModelResource() — 清除 Web 端 keeper 资源元数据(异步,不等待)
   * 3. resourceProvider.unregisterCurrent() — 停止资源响应
   * 4. importController.clearCurrentFile() — 删除缓存文件
   *
   * Phase 1D-2A:
   * - 先调用 resourceProvider.unregisterCurrent()(停止资源响应)
   * - 再调用 importController.clearCurrentFile()(删除缓存文件)
   *
   * Phase 1D-1:
   * - 调用 importController.clearCurrentFile()
   * - 删除受控缓存文件
   * - 恢复 IDLE 状态
   */
  private async onClearImportButton(): Promise<void> {
    if (this.importController === null) {
      return;
    }
    if (this.importedFile === null) {
      promptAction.showToast({ message: '无缓存文件可清除' });
      return;
    }
    // Phase 1D-2B-2:用户模型加载期间禁止清除缓存
    if (this.loadInProgress) {
      promptAction.showToast({ message: '模型加载中,请稍候' });
      return;
    }
    // Phase 1D-2B-2:1. 停止加载结果轮询 + 重置加载状态
    this.stopLoadPolling();
    this.resetLoadState();
    // Phase 1D-2B-2:2. 清除 Web 端加载协调器状态(异步,不等待)
    this.arkWebController.clearPreparedModelLoadResult().then((result: string) => {
      console.info(`[VrmViewerPage] clearPreparedModelLoadResult result: ${result}`);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] clearPreparedModelLoadResult failed: ${msg}`);
    });
    // Phase 1D-2B-1:1. 停止探测轮询 + 重置探测状态
    this.stopProbePolling();
    this.resetProbeState();
    // Phase 1D-2B-1:2. 清除 Web 端探测状态(异步,不等待)
    this.arkWebController.clearModelResourceProbe().then((result: string) => {
      console.info(`[VrmViewerPage] clearModelResourceProbe result: ${result}`);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] clearModelResourceProbe failed: ${msg}`);
    });
    // Phase 1D-2B-1:3. 清除 Web 端 keeper 资源元数据(异步,不等待)
    this.arkWebController.clearPreparedModelResource().then((result: string) => {
      console.info(`[VrmViewerPage] clearPreparedModelResource result: ${result}`);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] clearPreparedModelResource failed: ${msg}`);
    });
    // Phase 1D-2B-1:4. 注销资源(避免缓存文件已删除但 Provider 仍尝试读取)
    if (this.resourceProvider !== null) {
      this.resourceProvider.unregisterCurrent();
      this.preparedResource = null;
      this.resourceState = this.resourceProvider.getState();
    }
    // Phase 1D-2B-1:5. 删除缓存文件
    await this.importController.clearCurrentFile();
    this.importState = this.importController.getState();
    this.importedFile = this.importController.getCurrentFile();
    this.importLastError = this.importController.getLastError();
    // Phase 1D-2C-1:6. 清除 StateStore 中的导入记录(清除缓存时必须清除 Preferences)
    if (this.importStateStore !== null) {
      await this.importStateStore.clear();
    }
    // Phase 1D-2C-1:7. 清空恢复状态与诊断
    this.restoreErrorCode = '';
    this.restoreErrorMessage = '';
    this.restoreHint = '';
    this.runtimeDiagnostic = null;
    this.lastAutoProbedResourceUrl = '';
    this.pendingRestoredFile = null;
    // Phase 1D-2C-2E-1: 清空 Web Prepared 状态
    this.resetWebPreparedState();
    // Phase 1D-2C-1:8. 清除 Web 端运行时诊断(异步,不等待)
    this.arkWebController.clearVrmRuntimeDiagnostic().then((result: string) => {
      console.info(`[VrmViewerPage] clearVrmRuntimeDiagnostic result: ${result}`);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] clearVrmRuntimeDiagnostic failed: ${msg}`);
    });
    promptAction.showToast({ message: '已清除缓存文件' });
  }

  // ===== Phase 1D-2B-1: 资源探测(HEAD 请求校验) =====

  /**
   * "验证资源"按钮:启动 HEAD 请求探测,校验受控资源 URL 是否可正常访问。
   *
   * 流程:
   * 1. 检查前置条件:WebModelResource != null && Viewer READY && !probeInProgress
   * 2. 调用 probePreparedModelResource() 同步启动探测
   * 3. 页面 @State probeState 推进到 PROBING
   * 4. 启动轮询,每 200ms 调用 getModelResourceProbeResult() 获取最终结果
   * 5. 检测到 VERIFIED / FAILED 状态时停止轮询
   * 6. 超时(4s)后强制停止,标记为 FAILED
   *
   * 严格不调用:
   * - GLTFLoader.load()
   * - ViewerModelLoader.loadModel()
   * - 不读取模型文件内容
   */
  private async onProbeResourceButton(): Promise<void> {
    // 前置条件检查
    // 1. Native 资源未 READY:提示资源未注册
    if (this.preparedResource === null || this.resourceState !== ModelResourceState.READY) {
      promptAction.showToast({ message: '资源未注册,请先导入模型' });
      return;
    }
    // 2. Viewer 未就绪
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: 'Viewer 未就绪' });
      return;
    }
    // 3. 已有探测进行中,忽略重复点击
    if (this.probeInProgress) {
      return;
    }
    // 4. 用户模型加载期间禁止验证资源
    if (this.loadInProgress) {
      promptAction.showToast({ message: '模型加载中,请稍候' });
      return;
    }

    // Phase 1D-2C-2E-1: 如果 WebPrepared 未 READY,先调用 ensurePreparedModelResource 重新准备
    // 这样手动验证按钮同时具备:重新准备资源 + 重新执行 HEAD 探测 的恢复能力
    // 不要求 WebPrepared 预先 READY,否则准备失败后用户无法重试
    if (this.webPreparedState !== WebPreparedResourceState.READY) {
      console.info('[VrmViewerPage] manual probe: WebPrepared not READY, retry prepare');
      const resource: WebModelResource = this.preparedResource;
      const prepared: boolean = await this.ensurePreparedModelResource(resource, true);
      if (!prepared) {
        promptAction.showToast({
          message: `资源同步失败: ${this.webPreparedErrorCode} ${this.webPreparedErrorMessage}`
        });
        return;
      }
    }

    // 重置探测状态
    this.resetProbeState();
    this.probeInProgress = true;
    this.probeState = ModelResourceProbeState.PROBING;
    this.probePollCount = 0;

    try {
      // 1. 启动探测(同步返回 PROBING)
      const startResult: string = await this.arkWebController.probePreparedModelResource();
      console.info(`[VrmViewerPage] probePreparedModelResource result: ${startResult}`);
      // 简单字符串匹配检查启动是否成功
      if (startResult.indexOf('"success":true') < 0 && startResult.indexOf('"success": true') < 0) {
        // 启动失败
        this.probeState = ModelResourceProbeState.FAILED;
        this.probeErrorCode = 'PROBE_START_FAILED';
        // 提取 error.message
        const errorMatch: RegExpMatchArray | null = startResult.match(/"message"\s*:\s*"([^"]*)"/);
        this.probeErrorMessage = errorMatch !== null && errorMatch.length >= 2 ? errorMatch[1] : startResult;
        this.probeVerifiedAt = Date.now();
        this.probeInProgress = false;
        promptAction.showToast({ message: `探测启动失败: ${this.probeErrorMessage}` });
        return;
      }
      // 2. 启动轮询,异步获取最终结果
      this.startProbePolling();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.probeState = ModelResourceProbeState.FAILED;
      this.probeErrorCode = 'PROBE_START_FAILED';
      this.probeErrorMessage = msg;
      this.probeVerifiedAt = Date.now();
      this.probeInProgress = false;
      promptAction.showToast({ message: `探测异常: ${msg}` });
    }
  }

  /**
   * 启动轮询:每 PROBE_POLL_INTERVAL_MS 检查一次探测结果。
   * 最多轮询 PROBE_POLL_MAX_COUNT 次,超时后标记为 FAILED。
   */
  private startProbePolling(): void {
    this.stopProbePolling();
    this.probePollTimerId = setTimeout(() => {
      this.pollProbeResultOnce();
    }, this.PROBE_POLL_INTERVAL_MS);
  }

  /**
   * 停止轮询(取消计时器,不重置状态)。
   */
  private stopProbePolling(): void {
    if (this.probePollTimerId >= 0) {
      clearTimeout(this.probePollTimerId);
      this.probePollTimerId = -1;
    }
  }

  /**
   * 执行一次轮询:调用 getModelResourceProbeResult() 检查探测状态。
   */
  private pollProbeResultOnce(): void {
    this.probePollTimerId = -1;
    if (!this.probeInProgress) {
      return;
    }
    this.probePollCount++;
    if (this.probePollCount > this.PROBE_POLL_MAX_COUNT) {
      // 超时
      this.probeState = ModelResourceProbeState.FAILED;
      this.probeErrorCode = 'PROBE_TIMEOUT';
      this.probeErrorMessage = `Probe timeout after ${this.PROBE_POLL_MAX_COUNT * this.PROBE_POLL_INTERVAL_MS}ms`;
      this.probeVerifiedAt = Date.now();
      this.probeInProgress = false;
      promptAction.showToast({ message: '探测超时' });
      return;
    }

    this.arkWebController.getModelResourceProbeResult().then((resultJson: string) => {
      this.handleProbeResultJson(resultJson);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] pollProbeResult failed: ${msg}`);
      // 继续轮询(可能是临时错误)
      this.startProbePolling();
    });
  }

  /**
   * 解析轮询结果 JSON,更新 @State。
   * - result.state === 'PROBING':继续轮询
   * - result.state === 'VERIFIED':停止轮询,显示成功
   * - result.state === 'FAILED':停止轮询,显示错误
   */
  private handleProbeResultJson(resultJson: string): void {
    try {
      const parsed: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const success: boolean = parsed['success'] === true;
      if (!success) {
        // Bridge 返回错误
        const errorObj: Record<string, Object> = parsed['error'] as Record<string, Object>;
        this.probeState = ModelResourceProbeState.FAILED;
        this.probeErrorCode = errorObj !== undefined && errorObj !== null
          ? (errorObj['code'] as string) : 'PROBE_BRIDGE_ERROR';
        this.probeErrorMessage = errorObj !== undefined && errorObj !== null
          ? (errorObj['message'] as string) : resultJson;
        this.probeVerifiedAt = Date.now();
        this.probeInProgress = false;
        promptAction.showToast({ message: `探测失败: ${this.probeErrorMessage}` });
        return;
      }
      const result: Record<string, Object> = parsed['result'] as Record<string, Object>;
      if (result === null || result === undefined) {
        // 还没有结果,继续轮询
        this.startProbePolling();
        return;
      }
      const stateStr: string = (result['state'] as string) || 'NOT_PROBED';
      if (stateStr === 'PROBING') {
        // 仍在探测中,继续轮询
        this.startProbePolling();
        return;
      }
      // 探测完成(VERIFIED / FAILED / NOT_PROBED / 其他)
      this.applyProbeResult(result, stateStr);
      this.probeInProgress = false;
      if (this.probeState === ModelResourceProbeState.VERIFIED) {
        promptAction.showToast({ message: '资源传输验证通过' });
      } else if (this.probeState === ModelResourceProbeState.FAILED) {
        promptAction.showToast({ message: `探测失败: ${this.probeErrorMessage}` });
      }
      // Phase 1D-2C-1:探测完成后刷新运行时诊断(拉取 Provider HEAD 阶段记录)
      this.refreshRuntimeDiagnostic();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.error(`[VrmViewerPage] parse probe result failed: ${msg}, raw=${resultJson}`);
      // 解析失败视为错误
      this.probeState = ModelResourceProbeState.FAILED;
      this.probeErrorCode = 'PROBE_RESULT_PARSE_FAILED';
      this.probeErrorMessage = msg;
      this.probeVerifiedAt = Date.now();
      this.probeInProgress = false;
    }
  }

  /**
   * 将探测结果字段应用到 @State。
   */
  private applyProbeResult(result: Record<string, Object>, stateStr: string): void {
    // 解析状态枚举
    if (stateStr === 'VERIFIED') {
      this.probeState = ModelResourceProbeState.VERIFIED;
    } else if (stateStr === 'FAILED') {
      this.probeState = ModelResourceProbeState.FAILED;
    } else if (stateStr === 'PROBING') {
      this.probeState = ModelResourceProbeState.PROBING;
    } else {
      this.probeState = ModelResourceProbeState.NOT_PROBED;
    }
    // 解析字段(使用类型守卫避免 undefined / null)
    this.probeStatusCode = this.safeNumber(result['statusCode'], 0);
    this.probeMimeType = this.safeString(result['mimeType'], '');
    this.probeContentLength = this.safeNumber(result['contentLength'], -1);
    this.probeResourceId = this.safeString(result['resourceId'], '');
    this.probeRedirected = result['redirected'] === true;
    this.probeErrorCode = this.safeString(result['errorCode'], '');
    this.probeErrorMessage = this.safeString(result['errorMessage'], '');
    this.probeVerifiedAt = this.safeNumber(result['verifiedAt'], 0);
    // Phase 1D-2C-2E-2A: 长度来源诊断字段
    this.probeContentLengthSource = this.safeString(result['contentLengthSource'], '');
    this.probeCustomContentLength = this.safeNumber(result['customContentLength'], -1);
    this.probeStandardContentLength = this.safeNumber(result['standardContentLength'], -1);
  }

  /**
   * 重置探测状态到 NOT_PROBED(不清除轮询计时器,由 stopProbePolling 负责)。
   */
  private resetProbeState(): void {
    this.probeState = ModelResourceProbeState.NOT_PROBED;
    this.probeStatusCode = 0;
    this.probeMimeType = '';
    this.probeContentLength = -1;
    this.probeResourceId = '';
    this.probeRedirected = false;
    this.probeErrorCode = '';
    this.probeErrorMessage = '';
    this.probeVerifiedAt = 0;
    // Phase 1D-2C-2E-2A: 重置长度诊断字段
    this.probeContentLengthSource = '';
    this.probeCustomContentLength = -1;
    this.probeStandardContentLength = -1;
    this.probePollCount = 0;
  }

  /** 安全读取 number 字段(失败返回 defaultValue)。 */
  private safeNumber(value: Object | undefined, defaultValue: number): number {
    if (typeof value === 'number') {
      return value;
    }
    return defaultValue;
  }

  /** 安全读取 string 字段(失败返回 defaultValue)。 */
  private safeString(value: Object | undefined, defaultValue: string): string {
    if (typeof value === 'string') {
      return value;
    }
    return defaultValue;
  }

  /** 探测状态显示标签(Phase 1D-2C-1: NOT_PROBED 为中性,不显示为错误色) */
  private probeStateLabel(): string {
    if (this.probeState === ModelResourceProbeState.NOT_PROBED) {
      return '未发起探测';
    } else if (this.probeState === ModelResourceProbeState.PROBING) {
      return '探测中...';
    } else if (this.probeState === ModelResourceProbeState.VERIFIED) {
      return '验证通过';
    } else if (this.probeState === ModelResourceProbeState.FAILED) {
      return '探测失败';
    }
    return '未知';
  }

  /** 探测验证时间显示(格式化为人类可读) */
  private probeVerifiedAtLabel(): string {
    if (this.probeVerifiedAt <= 0) {
      return '—';
    }
    const date: Date = new Date(this.probeVerifiedAt);
    const h: number = date.getHours();
    const m: number = date.getMinutes();
    const s: number = date.getSeconds();
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return `${hh}:${mm}:${ss}`;
  }

  /**
   * Phase 1D-2C-2E-2A: 长度来源显示标签。
   *
   * 用于 UI 诊断区域,标识最终选用的长度证明来源。
   * - CUSTOM: 自定义响应头(X-ArkTavern-Content-Length)
   * - STANDARD: 标准响应头(Content-Length)
   * - UNAVAILABLE: 长度不可用
   * - '': 探测未到达长度校验阶段
   */
  private probeLengthSourceLabel(): string {
    if (this.probeContentLengthSource === 'CUSTOM') {
      return '自定义响应头';
    } else if (this.probeContentLengthSource === 'STANDARD') {
      return '标准响应头';
    } else if (this.probeContentLengthSource === 'UNAVAILABLE') {
      return '不可用';
    }
    return '—';
  }

  // ===== Phase 1D-2B-2: 用户模型加载(GLTFLoader 实际加载与原子替换) =====

  /**
   * "加载模型"按钮:启动用户模型加载流程。
   *
   * 流程(AGENTS.md Phase 1D-2B-2 §二十一):
   * 1. 前置条件检查:PreparedResource 存在 / Viewer READY / ProbeState VERIFIED / !loadInProgress / !probeInProgress
   * 2. 调用 loadPreparedModelResource() 同步启动加载
   * 3. 页面状态改为 LOADING
   * 4. 每 250ms 查询 getPreparedModelLoadResult()
   * 5. READY / FAILED 时停止轮询
   * 6. 最长等待 60 秒(LOAD_POLL_MAX_COUNT × LOAD_POLL_INTERVAL_MS)
   *
   * 严格不:
   * - 不接受 URL 参数(由 Bridge 从 PreparedModelResourceKeeper 读取)
   * - 不直接调用 GLTFLoader.load()
   * - 不直接调用 fetch / arrayBuffer / blob
   *
   * 失败时(AGENTS.md Phase 1D-2B-2 §二十三):
   * - Provider 保持 READY
   * - PreparedResource 保持
   * - ProbeResult 保持 VERIFIED
   * - 当前模型保持显示
   * - 用户可再次点击"加载模型"
   */
  private async onLoadModelButton(): Promise<void> {
    // 前置条件检查
    if (this.preparedResource === null) {
      promptAction.showToast({ message: '请先准备资源' });
      return;
    }
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: 'Viewer 未就绪' });
      return;
    }
    if (this.probeState !== ModelResourceProbeState.VERIFIED) {
      promptAction.showToast({ message: '请先验证资源' });
      return;
    }
    if (this.probeInProgress) {
      // 探测进行中,禁止加载
      return;
    }
    if (this.loadInProgress) {
      // 已有加载进行中,忽略重复点击
      return;
    }

    // 重置加载状态并启动加载
    this.resetLoadState();
    this.loadInProgress = true;
    this.loadState = 'LOADING';
    this.loadStartedAt = Date.now();
    this.loadPollCount = 0;
    // 显示目标文件名
    if (this.preparedResource !== null) {
      this.loadDisplayName = this.preparedResource.displayName;
    }

    try {
      // 1. 启动加载(同步返回 LOADING 或 FAILED 结果)
      const startResult: string = await this.arkWebController.loadPreparedModelResource();
      console.info(`[VrmViewerPage] loadPreparedModelResource result: ${startResult}`);
      // 简单字符串匹配检查启动是否成功
      if (startResult.indexOf('"success":true') < 0 && startResult.indexOf('"success": true') < 0) {
        // 启动失败:解析错误信息
        this.loadState = 'FAILED';
        this.loadErrorCode = 'LOAD_START_FAILED';
        const errorMatch: RegExpMatchArray | null = startResult.match(/"message"\s*:\s*"([^"]*)"/);
        this.loadErrorMessage = errorMatch !== null && errorMatch.length >= 2 ? errorMatch[1] : startResult;
        this.loadCompletedAt = Date.now();
        this.loadInProgress = false;
        promptAction.showToast({ message: `模型加载失败,当前模型已保留` });
        return;
      }
      // 2. 启动轮询,异步获取最终结果
      this.startLoadPolling();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.loadState = 'FAILED';
      this.loadErrorCode = 'LOAD_START_FAILED';
      this.loadErrorMessage = msg;
      this.loadCompletedAt = Date.now();
      this.loadInProgress = false;
      promptAction.showToast({ message: `模型加载失败,当前模型已保留` });
    }
  }

  /**
   * 启动加载结果轮询:每 LOAD_POLL_INTERVAL_MS 检查一次加载结果。
   * 最多轮询 LOAD_POLL_MAX_COUNT 次,超时后标记为 FAILED。
   */
  private startLoadPolling(): void {
    this.stopLoadPolling();
    this.loadPollTimerId = setTimeout(() => {
      this.pollLoadResultOnce();
    }, this.LOAD_POLL_INTERVAL_MS);
  }

  /**
   * 停止加载结果轮询(取消计时器,不重置状态)。
   */
  private stopLoadPolling(): void {
    if (this.loadPollTimerId >= 0) {
      clearTimeout(this.loadPollTimerId);
      this.loadPollTimerId = -1;
    }
  }

  /**
   * 执行一次加载结果轮询:调用 getPreparedModelLoadResult() 检查加载状态。
   */
  private pollLoadResultOnce(): void {
    this.loadPollTimerId = -1;
    if (!this.loadInProgress) {
      return;
    }
    this.loadPollCount++;
    if (this.loadPollCount > this.LOAD_POLL_MAX_COUNT) {
      // 超时
      this.loadState = 'FAILED';
      this.loadErrorCode = 'LOAD_TIMEOUT';
      this.loadErrorMessage = `Load timeout after ${this.LOAD_POLL_MAX_COUNT * this.LOAD_POLL_INTERVAL_MS}ms`;
      this.loadCompletedAt = Date.now();
      this.loadInProgress = false;
      promptAction.showToast({ message: '模型加载失败,当前模型已保留' });
      return;
    }

    this.arkWebController.getPreparedModelLoadResult().then((resultJson: string) => {
      this.handleLoadResultJson(resultJson);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] pollLoadResult failed: ${msg}`);
      // 继续轮询(可能是临时错误)
      this.startLoadPolling();
    });
  }

  /**
   * 解析加载结果 JSON,更新 @State。
   * - result.state === 'LOADING':继续轮询
   * - result.state === 'READY':停止轮询,显示成功
   * - result.state === 'FAILED':停止轮询,显示错误
   * - result.state === 'DISPOSED':停止轮询,显示销毁
   */
  private handleLoadResultJson(resultJson: string): void {
    try {
      const parsed: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const success: boolean = parsed['success'] === true;
      if (!success) {
        // Bridge 返回错误
        const errorObj: Record<string, Object> = parsed['error'] as Record<string, Object>;
        this.loadState = 'FAILED';
        this.loadErrorCode = errorObj !== undefined && errorObj !== null
          ? (errorObj['code'] as string) : 'LOAD_BRIDGE_ERROR';
        this.loadErrorMessage = errorObj !== undefined && errorObj !== null
          ? (errorObj['message'] as string) : resultJson;
        this.loadCompletedAt = Date.now();
        this.loadInProgress = false;
        promptAction.showToast({ message: '模型加载失败,当前模型已保留' });
        return;
      }
      const result: Record<string, Object> = parsed['result'] as Record<string, Object>;
      if (result === null || result === undefined) {
        // 还没有结果,继续轮询
        this.startLoadPolling();
        return;
      }
      const stateStr: string = (result['state'] as string) || 'NOT_REQUESTED';
      if (stateStr === 'LOADING' || stateStr === 'NOT_REQUESTED') {
        // 仍在加载中(或刚启动还未推进),继续轮询
        this.startLoadPolling();
        return;
      }
      // 加载完成(READY / FAILED / DISPOSED / 其他)
      this.applyLoadResult(result, stateStr);
      this.loadInProgress = false;
      if (this.loadState === 'READY') {
        promptAction.showToast({ message: '用户模型加载成功' });
      } else if (this.loadState === 'FAILED') {
        promptAction.showToast({ message: '模型加载失败,当前模型已保留' });
      }
      // Phase 1D-2C-1:加载完成后刷新运行时诊断(拉取 GLTF_LOAD_* / MODEL_REPLACE_* 阶段记录)
      this.refreshRuntimeDiagnostic();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.error(`[VrmViewerPage] parse load result failed: ${msg}, raw=${resultJson}`);
      // 解析失败视为错误
      this.loadState = 'FAILED';
      this.loadErrorCode = 'LOAD_RESULT_PARSE_FAILED';
      this.loadErrorMessage = msg;
      this.loadCompletedAt = Date.now();
      this.loadInProgress = false;
      promptAction.showToast({ message: '模型加载失败,当前模型已保留' });
    }
  }

  /**
   * 将加载结果字段应用到 @State。
   */
  private applyLoadResult(result: Record<string, Object>, stateStr: string): void {
    // 解析状态枚举
    if (stateStr === 'READY') {
      this.loadState = 'READY';
    } else if (stateStr === 'FAILED') {
      this.loadState = 'FAILED';
    } else if (stateStr === 'DISPOSED') {
      this.loadState = 'DISPOSED';
    } else if (stateStr === 'LOADING') {
      this.loadState = 'LOADING';
    } else {
      this.loadState = 'NOT_REQUESTED';
    }
    // 解析字段(使用类型守卫避免 undefined / null)
    this.loadDisplayName = this.safeString(result['displayName'], this.loadDisplayName);
    this.loadModelDisplayName = this.safeString(result['modelDisplayName'], '');
    this.loadErrorCode = this.safeString(result['errorCode'], '');
    this.loadErrorMessage = this.safeString(result['errorMessage'], '');
    this.loadStartedAt = this.safeNumber(result['startedAt'], this.loadStartedAt);
    this.loadCompletedAt = this.safeNumber(result['completedAt'], 0);
  }

  /**
   * 重置加载状态到 NOT_REQUESTED(不清除轮询计时器,由 stopLoadPolling 负责)。
   */
  private resetLoadState(): void {
    this.loadState = 'NOT_REQUESTED';
    this.loadDisplayName = '';
    this.loadModelDisplayName = '';
    this.loadErrorCode = '';
    this.loadErrorMessage = '';
    this.loadStartedAt = 0;
    this.loadCompletedAt = 0;
    this.loadPollCount = 0;
  }

  /** 加载状态显示标签(Phase 1D-2C-1: NOT_REQUESTED 为中性,不显示为错误色) */
  private loadStateLabel(): string {
    if (this.loadState === 'NOT_REQUESTED') {
      return '未发起加载';
    } else if (this.loadState === 'LOADING') {
      return '加载中...';
    } else if (this.loadState === 'READY') {
      return '加载成功';
    } else if (this.loadState === 'FAILED') {
      return '加载失败';
    } else if (this.loadState === 'DISPOSED') {
      return '已销毁';
    }
    return '未知';
  }

  /** 加载开始时间显示(格式化为人类可读) */
  private loadStartedAtLabel(): string {
    if (this.loadStartedAt <= 0) {
      return '—';
    }
    const date: Date = new Date(this.loadStartedAt);
    const h: number = date.getHours();
    const m: number = date.getMinutes();
    const s: number = date.getSeconds();
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return `${hh}:${mm}:${ss}`;
  }

  /** 加载完成时间显示(格式化为人类可读) */
  private loadCompletedAtLabel(): string {
    if (this.loadCompletedAt <= 0) {
      return '—';
    }
    const date: Date = new Date(this.loadCompletedAt);
    const h: number = date.getHours();
    const m: number = date.getMinutes();
    const s: number = date.getSeconds();
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return `${hh}:${mm}:${ss}`;
  }

  /**
   * Phase 1D-2C-1: 整体动态状态提示。
   *
   * 替代旧版静态"未探测、未加载"文案。根据 importState / probeState / loadState /
   * restoreHint / viewerState 综合计算当前应显示的中性/成功/失败提示。
   *
   * Phase 1D-2C-2A:
   * - 新增优先级 0:Viewer FAILED 时显示"Viewer 初始化失败,模型验证尚未开始"
   *   (避免在 Viewer 失败时显示"导入完成,正在验证资源"等虚假进度提示)
   * - 资源不变量:Viewer FAILED 时不进入探测/加载链路
   *
   * 返回空字符串表示无提示(初始空闲态)。
   */
  private overallStatusHint(): string {
    // 优先级 0:Viewer 初始化失败(最高优先级,覆盖所有资源/加载提示)
    if (this.viewerState === ArkWebViewerState.FAILED) {
      return 'Viewer 初始化失败,模型验证尚未开始';
    }
    // 优先级 1:恢复中或恢复失败
    if (this.restoreHint.length > 0) {
      return this.restoreHint;
    }
    // 优先级 2:导入未完成
    if (this.importState === ModelImportState.IDLE ||
        this.importState === ModelImportState.PICKING ||
        this.importState === ModelImportState.COPYING) {
      return '';
    }
    if (this.importState === ModelImportState.READY) {
      // 优先级 3:加载中
      if (this.loadState === 'LOADING') {
        return '模型加载中';
      }
      // 优先级 4:加载成功
      if (this.loadState === 'READY') {
        return '模型加载成功';
      }
      // 优先级 5:加载失败
      if (this.loadState === 'FAILED') {
        return '模型加载失败,当前模型已保留';
      }
      // 优先级 6:探测中
      if (this.probeState === ModelResourceProbeState.PROBING) {
        return '导入完成,正在验证资源';
      }
      // 优先级 7:探测通过
      if (this.probeState === ModelResourceProbeState.VERIFIED) {
        return '资源验证通过,可以加载模型';
      }
      // 优先级 8:探测失败
      if (this.probeState === ModelResourceProbeState.FAILED) {
        return '资源验证失败,请查看运行诊断';
      }
      // Phase 1D-2C-2E-1: Web 资源准备失败(Native 已就绪,但 JS keeper 未接收或回读失败)
      // 显示真实 RESOURCE_PREPARE_* 错误,而不是把它压缩为 PROBE_START_FAILED
      if (this.webPreparedState === WebPreparedResourceState.FAILED) {
        return '资源同步失败,请重新验证资源';
      }
      // 优先级 9:已导入 + Web 资源准备中
      if (this.webPreparedState === WebPreparedResourceState.PREPARING) {
        return 'Native 资源已注册,正在同步到 Viewer';
      }
      // 优先级 10:已导入 + Web 资源已准备 + 未探测
      if (this.webPreparedState === WebPreparedResourceState.READY) {
        return '模型资源已同步,正在验证';
      }
      // 优先级 11:已导入但 Web 资源未准备(中性,不显示错误色)
      return '导入完成,正在验证资源';
    }
    return '';
  }

  /**
   * Phase 1D-2C-1: 整体动态状态颜色。
   * - 失败:app_danger
   * - 成功:model_settings_success
   * - 中性/进行中:app_text_secondary
   *
   * Phase 1D-2C-2A: Viewer FAILED 时也使用 app_danger。
   */
  private overallStatusColor(): ResourceColor {
    if (this.viewerState === ArkWebViewerState.FAILED) {
      return $r('app.color.app_danger');
    }
    if (this.restoreErrorCode.length > 0) {
      return $r('app.color.app_danger');
    }
    if (this.loadState === 'FAILED' ||
        this.probeState === ModelResourceProbeState.FAILED ||
        this.webPreparedState === WebPreparedResourceState.FAILED) {
      return $r('app.color.app_danger');
    }
    if (this.loadState === 'READY' || this.probeState === ModelResourceProbeState.VERIFIED) {
      return $r('app.color.model_settings_success');
    }
    return $r('app.color.app_text_secondary');
  }

  /**
   * Phase 1D-2C-1: 运行时诊断阶段标签(直接显示原始阶段字符串)。
   *
   * 规范要求错误信息必须显示实际阶段(如 GLTF_LOAD_FAILED / RESOURCE_OPEN_FAILED /
   * VRM_DATA_NOT_FOUND / MODEL_REPLACE_FAILED),不得压缩为通用的"加载失败"。
   * 因此直接返回 stage 枚举字符串。
   */
  private runtimeStageLabel(stage: VrmRuntimeStage): string {
    return String(stage);
  }

  /**
   * Phase 1D-2C-1: 运行时诊断阶段颜色。
   * - *_FAILED / MODEL_REPLACE_FAILED / GLTF_LOAD_FAILED: app_danger
   * - *_COMMITTED / VERIFIED / VALIDATED: model_settings_success
   * - 其他(进行中/中性): app_text_secondary
   *
   * Phase 1D-2C-2A: VIEWER_INITIALIZE_FAILED / VIEWER_CONTAINER_NOT_FOUND
   * 也归为失败阶段,使用 app_danger。
   * VIEWER_READY 启动阶段归为成功,使用 model_settings_success。
   */
  private runtimeStageColor(stage: VrmRuntimeStage): ResourceColor {
    if (stage === VrmRuntimeStage.PROBE_FAILED ||
        stage === VrmRuntimeStage.GLTF_LOAD_FAILED ||
        stage === VrmRuntimeStage.MODEL_REPLACE_FAILED ||
        stage === VrmRuntimeStage.VIEWER_INITIALIZE_FAILED ||
        stage === VrmRuntimeStage.VIEWER_CONTAINER_NOT_FOUND) {
      return $r('app.color.app_danger');
    }
    if (stage === VrmRuntimeStage.PROBE_VERIFIED ||
        stage === VrmRuntimeStage.VRM_DATA_VALIDATED ||
        stage === VrmRuntimeStage.MODEL_REPLACE_COMMITTED ||
        stage === VrmRuntimeStage.VIEWER_READY) {
      return $r('app.color.model_settings_success');
    }
    return $r('app.color.app_text_secondary');
  }

  /** 模型名称(顶部工具栏显示) */
  private modelDisplayName(): string {
    if (this.viewerState === ArkWebViewerState.UNINITIALIZED) {
      return '初始化中...';
    } else if (this.viewerState === ArkWebViewerState.INITIALIZING) {
      return '初始化中...';
    } else if (this.viewerState === ArkWebViewerState.LOADING_MODEL) {
      return '加载中...';
    } else if (this.viewerState === ArkWebViewerState.READY) {
      return 'VRM Viewer';
    } else if (this.viewerState === ArkWebViewerState.MODEL_READY) {
      return 'VRM 模型';
    } else if (this.viewerState === ArkWebViewerState.FAILED) {
      return '加载失败';
    } else if (this.viewerState === ArkWebViewerState.DISPOSED) {
      return '已销毁';
    } else {
      return '未加载';
    }
  }

  build() {
    Stack() {
      // ===== 1. 全屏预览区域(最底层,始终 100% 尺寸,不被压缩) =====
      this.PreviewArea()

      // ===== 2. 顶部工具栏 =====
      this.TopToolbar()

      // ===== 3. 右侧快捷工具栏(仅普通模式) =====
      if (this.presentationMode === PresentationMode.NORMAL) {
        this.QuickToolbar()
      }

      // ===== 4. 底部控制抽屉(仅普通模式,覆盖在预览上) =====
      if (this.presentationMode === PresentationMode.NORMAL) {
        this.BottomDrawer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .onAreaChange((_old: Area, newArea: Area) => {
      const rawH: Length = newArea.height;
      let h: number = 0;
      if (typeof rawH === 'number') {
        h = rawH;
      }
      this.pageHeight = h;
      this.previewHeight = h;
      // Phase 1B:主动通知 Web 端 Viewer 尺寸变化(配合 ResizeObserver 兜底)
      const rawW: Length = newArea.width;
      let w: number = 0;
      if (typeof rawW === 'number') {
        w = rawW;
      }
      if (w > 0 && h > 0 && this.viewerState === ArkWebViewerState.READY) {
        this.arkWebController.resizeViewer(w, h);
      }
    })
  }

  /** 全屏预览区域(Web 组件渲染 Viewer) */
  @Builder
  PreviewArea() {
    Stack() {
      // Web 组件加载 rawfile/vrmviewer/index.html
      // controller 由 ArkWebVrmViewerController 提供
      Web({
        src: $rawfile(ArkWebViewerConfig.VIEWER_PAGE_PATH),
        controller: this.arkWebController.getWebviewController()
      })
        .width('100%')
        .height('100%')
        .backgroundColor('#222222')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onControllerAttached(() => {
          this.arkWebController.onControllerAttached();
        })
        .onPageEnd(() => {
          this.webLoaded = true;
          this.arkWebController.onPageEnd();
        })
        .onPageBegin((_e) => {
          // 页面开始加载
        })
        .onErrorReceive((_e) => {
          this.lastErrorCode = 'WEB_LOAD_FAILED';
          this.lastError = 'Web 页面加载失败';
          this.viewerState = ArkWebViewerState.FAILED;
        })
        // Phase 1D-2A:资源请求拦截
        // 拦截 ark-tavern.local 资源请求,通过 FD 返回缓存文件内容
        // 其他请求返回 null(放行,交由 Web 默认处理)
        .onInterceptRequest((event: OnInterceptRequestEvent) => {
          if (this.resourceProvider === null) {
            return null;
          }
          const request: WebResourceRequest = event.request;
          const url: string = request.getRequestUrl();
          // 仅处理当前注册资源的 URL,其他一律放行
          if (!this.resourceProvider.matchesRequest(url)) {
            return null;
          }
          const requestHeaders: Array<Header> = request.getRequestHeader();
          const method: string = request.getRequestMethod();
          const result = this.resourceProvider.handleRequest(url, method, requestHeaders);
          if (result.response === null) {
            // 资源处理失败但不应阻塞 Web,放行让 Web 自行处理(通常 404)
            console.warn(`[VrmViewerPage] resource handleRequest returned null: ${result.errorCode} ${result.errorMessage}`);
            return null;
          }
          return result.response;
        })

      // 错误覆盖层(FAILED 状态)
      if (this.viewerState === ArkWebViewerState.FAILED) {
        Column() {
          Text('加载失败')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FF6B6B')
            .margin({ bottom: 8 })
          Text(this.lastError || this.viewerDetail)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor('#BFFFFFFF')
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // Phase 1D-2C-2A: 重试 Viewer 按钮(不重新进入页面即可重试)
          Button('重试 Viewer')
            .fontSize($r('app.float.app_font_body'))
            .fontColor('#FFFFFF')
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .margin({ top: 16, left: 32, right: 32 })
            .enabled(!this.retryInProgress)
            .onClick(() => {
              this.onRetryViewerButton();
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#CC000000')
      }
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Center)
  }

  /** 顶部工具栏(透明覆盖层,内容顶部对齐,空白区点击穿透) */
  @Builder
  TopToolbar() {
    Column() {
      Row() {
        // 返回
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor(['#FFFFFF'])
          .padding(8)
          .onClick(() => {
            router.back();
          })

        // 当前模型名称
        Text(this.modelDisplayName())
          .fontSize($r('app.float.app_font_body'))
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 8, right: 8 })

        // 普通 / 演示模式
        Button(this.presentationMode === PresentationMode.DEMO ? '退出演示' : '演示模式')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor('#FFFFFF')
          .backgroundColor('#33FFFFFF')
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .enabled(!this.presentationTransitioning)
          .onClick(() => {
            if (this.presentationMode === PresentationMode.NORMAL) {
              this.enterDemoMode();
            } else {
              this.exitDemoMode();
            }
          })

        // 更多
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(24)
          .fontColor(['#FFFFFF'])
          .padding(8)
          .margin({ left: 4 })
          .onClick(() => {
            this.showPlaceholderToast();
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: this.statusBarHeight + 8,
        bottom: $r('app.float.app_spacing_8')
      })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 右侧快捷工具栏(透明覆盖层,内容右侧居中,空白区点击穿透) */
  @Builder
  QuickToolbar() {
    Row() {
      Column() {
        this.QuickButton('聚焦', () => { this.onFocusButton(); })
        this.QuickButton('重置', () => { this.onResetButton(); }, this.resetButtonDisabled)
        this.QuickButton('截图', () => { this.onScreenshotButton(); })
        this.QuickButton('设置', () => { this.showPlaceholderToast(); })
      }
      .backgroundColor('#99000000')
      .borderRadius($r('app.float.app_radius_md'))
      .padding($r('app.float.app_spacing_8'))
      .margin({ right: $r('app.float.app_spacing_16') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  QuickButton(label: string, action: () => void, disabled: boolean = false) {
    Text(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(disabled ? '#80FFFFFF' : '#FFFFFF')
      .textAlign(TextAlign.Center)
      .width(44)
      .height(44)
      .borderRadius($r('app.float.app_radius_sm'))
      .margin({ top: 4, bottom: 4 })
      .opacity(disabled ? 0.5 : 1.0)
      .enabled(!disabled)
      .onClick(() => {
        if (!disabled) {
          action();
        }
      })
  }

  /** 底部控制抽屉(透明覆盖层,抽屉面板底部对齐,空白区点击穿透) */
  @Builder
  BottomDrawer() {
    Column() {
      // 抽屉面板(固定高度,不透明背景)
      Column() {
        // 拖动条 + 标题(点击切换状态)
        Column() {
          // 拖动条
          Row() {
            Divider()
              .color('#B0B0B0')
              .strokeWidth(3)
              .width(40)
              .borderRadius(2)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 8, bottom: 4 })

          // 标题行
          Row() {
            Text('控制面板')
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_text_primary'))
              .layoutWeight(1)

            // 三态指示
            Row() {
              this.StateDot(DrawerState.Collapsed)
              this.StateDot(DrawerState.Half)
              this.StateDot(DrawerState.Expanded)
            }
            .margin({ left: 8 })

            Text(this.drawerStateLabel())
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .margin({ left: 8 })
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_8')
          })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .onClick(() => {
          this.cycleDrawerState();
        })

        // Tab 栏 + 内容(仅 half / expanded 显示)
        if (this.drawerState !== DrawerState.Collapsed) {
          this.TabBar()
          this.TabContentArea()
        }
      }
      .width('100%')
      .height(this.getDrawerHeight())
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius({ topLeft: $r('app.float.app_radius_lg'), topRight: $r('app.float.app_radius_lg') })
      // Phase 2A-1: 控制面板触摸隔离
      // 在控制面板最外层容器接入 onTouch,覆盖 Scroll/Slider/Tab/Button/Switch 等所有子控件
      // 触摸期间禁用 OrbitControls,触摸结束或取消时恢复
      .onTouch((event: TouchEvent) => {
        this.onPanelTouch(event);
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 抽屉三态指示点 */
  @Builder
  StateDot(state: DrawerState) {
    Stack()
      .width(8)
      .height(8)
      .borderRadius(4)
      .backgroundColor(this.drawerState === state
        ? $r('app.color.app_accent')
        : $r('app.color.app_divider'))
      .margin({ left: 4, right: 4 })
  }

  /** Tab 栏(水平可滚动) */
  @Builder
  TabBar() {
    Scroll() {
      Row() {
        this.TabItem('模型', ViewerTab.Model)
        this.TabItem('姿势', ViewerTab.Pose)
        this.TabItem('动画', ViewerTab.Animation)
        this.TabItem('表情', ViewerTab.Expression)
        this.TabItem('物理', ViewerTab.Physics)
        this.TabItem('场景', ViewerTab.Scene)
        this.TabItem('调试', ViewerTab.Debug)
      }
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16')
      })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(40)
  }

  @Builder
  TabItem(label: string, tab: ViewerTab) {
    Text(label)
      .fontSize($r('app.float.app_font_body'))
      .fontColor(this.activeTab === tab
        ? $r('app.color.app_accent')
        : $r('app.color.app_text_secondary'))
      .fontWeight(this.activeTab === tab ? FontWeight.Medium : FontWeight.Normal)
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: $r('app.float.app_spacing_8'),
        bottom: $r('app.float.app_spacing_8')
      })
      .onClick(() => {
        this.activeTab = tab;
      })
  }

  /** Tab 内容区(可滚动) */
  @Builder
  TabContentArea() {
    Scroll() {
      Column() {
        if (this.activeTab === ViewerTab.Model) {
          this.TabModelContent()
        } else if (this.activeTab === ViewerTab.Pose) {
          this.TabPoseContent()
        } else if (this.activeTab === ViewerTab.Animation) {
          this.TabAnimationContent()
        } else if (this.activeTab === ViewerTab.Expression) {
          this.TabExpressionContent()
        } else if (this.activeTab === ViewerTab.Physics) {
          this.TabPhysicsContent()
        } else if (this.activeTab === ViewerTab.Scene) {
          this.TabSceneContent()
        } else {
          this.TabDebugContent()
        }
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_12'),
        bottom: this.navigationBarHeight + 24
      })
    }
    .layoutWeight(1)
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
  }

  // ===== 各 Tab 占位内容 =====

  @Builder
  TabModelContent() {
    Column() {
      // ===== Viewer 状态(只读) =====
      Text(`Viewer 状态: ${this.viewerState}`)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(`详情: ${this.viewerDetail}`)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 4 })

      // ===== Phase 1D-2C-1: 整体动态状态提示(替代旧版静态"未探测、未加载") =====
      if (this.overallStatusHint().length > 0) {
        Text(this.overallStatusHint())
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.overallStatusColor())
          .margin({ top: 8 })
          .width('100%')
      }

      Divider().margin({ top: 12, bottom: 12 })

      // ===== Phase 1D-1: 模型导入 =====
      Text('模型导入')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 导入按钮 + 清除按钮
      Row() {
        Button(this.importInProgress ? '导入中...' : '导入模型')
          .fontSize($r('app.float.app_font_body'))
          .fontColor('#FFFFFF')
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .enabled(!this.importInProgress && this.importState !== ModelImportState.DISPOSED && !this.loadInProgress)
          .onClick(() => {
            this.onImportModelButton();
          })

        Button('清除缓存')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .margin({ left: 8 })
          .enabled(this.importedFile !== null && !this.importInProgress && !this.loadInProgress)
          .onClick(() => {
            this.onClearImportButton();
          })
      }
      .width('100%')

      // ===== 导入状态显示 =====
      Column() {
        this.ImportInfoRow('导入状态', this.importStateLabel())
        if (this.importedFile !== null) {
          this.ImportInfoRow('文件名', this.importedFile.displayName)
          this.ImportInfoRow('格式', this.formatLabel(this.importedFile))
          this.ImportInfoRow('文件大小', this.sizeLabel(this.importedFile.size))
          this.ImportInfoRow('缓存准备', this.cacheReadyLabel())
          this.ImportInfoRow('glTF 依赖', this.gltfDependencyLabel(this.importedFile))
        }
        if (this.importLastError.length > 0) {
          Text(`错误: ${this.importLastError}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
        }
      }
      .width('100%')
      .margin({ top: 12 })

      // ===== Phase 1D-2A: 资源暴露状态 =====
      Divider().margin({ top: 12, bottom: 12 })

      Text('资源暴露(Phase 1D-2A)')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      Column() {
        this.ImportInfoRow('资源状态', this.resourceStateLabel())
        // Phase 1D-2C-2E-1: Web Prepared 状态(与 Native resourceState 解耦)
        // - resourceState === READY 仅表示 Native Provider 已注册资源 URL
        // - webPreparedState === READY 表示 JavaScript keeper 已通过 prepareModelResource
        //   接收资源元数据并通过 getPreparedModelResource 回读校验
        this.ImportInfoRow('Web 资源状态', this.webPreparedStateLabel())
        // Phase 1D-2C-2A: 资源状态不变量
        // - resourceState === EMPTY → preparedResource 必须为 null → 不显示 URL / MIME / 大小 / 扩展名
        // - preparedResource !== null → resourceState 必须为 READY
        // 双重校验:仅当 preparedResource 非空且 resourceState !== EMPTY 时才显示资源详情
        if (this.preparedResource !== null && this.resourceState !== ModelResourceState.EMPTY) {
          this.ImportInfoRow('资源 URL', this.preparedResource.resourceUrl)
          this.ImportInfoRow('MIME', this.preparedResource.mimeType)
          this.ImportInfoRow('资源大小', this.sizeLabel(this.preparedResource.size))
          this.ImportInfoRow('扩展名', this.preparedResource.extension)
        }
        if (this.resourceLastError.length > 0) {
          Text(`资源错误: ${this.resourceLastError}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
        }
        // Phase 1D-2C-2E-1: Web 资源准备错误显示
        // 失败时显示真实 RESOURCE_PREPARE_* 错误,而不是把它压缩为 PROBE_START_FAILED
        if (this.webPreparedState === WebPreparedResourceState.FAILED) {
          if (this.webPreparedErrorCode.length > 0) {
            Text(`Web 资源错误码: ${this.webPreparedErrorCode}`)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .margin({ top: 8 })
              .width('100%')
          }
          if (this.webPreparedErrorMessage.length > 0) {
            Text(`Web 资源错误: ${this.webPreparedErrorMessage}`)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .margin({ top: 4 })
              .width('100%')
          }
        }
      }
      .width('100%')
      .margin({ top: 12 })

      // ===== Phase 1D-2B-1: 资源探测(HEAD 请求校验) =====
      Divider().margin({ top: 12, bottom: 12 })

      Text('资源探测(Phase 1D-2B-1)')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 验证资源按钮
      Button(this.probeInProgress ? '探测中...' : '验证资源')
        .fontSize($r('app.float.app_font_body'))
        .fontColor('#FFFFFF')
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .width('100%')
        .enabled(
          this.preparedResource !== null &&
          this.viewerState === ArkWebViewerState.READY &&
          !this.probeInProgress &&
          this.resourceState === ModelResourceState.READY &&
          !this.loadInProgress
        )
        .onClick(() => {
          this.onProbeResourceButton();
        })

      // 探测结果信息
      Column() {
        this.ImportInfoRow('探测状态', this.probeStateLabel())
        if (this.probeState !== ModelResourceProbeState.NOT_PROBED) {
          this.ImportInfoRow('HTTP 状态', this.probeStatusCode > 0 ? `${this.probeStatusCode}` : '—')
          this.ImportInfoRow('MIME 校验', this.probeMimeType.length > 0 ? this.probeMimeType : '—')
          this.ImportInfoRow('文件大小', this.probeContentLength >= 0 ? this.sizeLabel(this.probeContentLength) : '—')
          this.ImportInfoRow('长度来源', this.probeLengthSourceLabel())
          this.ImportInfoRow('自定义长度', this.probeCustomContentLength >= 0 ? `${this.probeCustomContentLength}` : '—')
          this.ImportInfoRow('标准长度', this.probeStandardContentLength >= 0 ? `${this.probeStandardContentLength}` : '—')
          this.ImportInfoRow('资源 ID', this.probeResourceId.length > 0 ? this.probeResourceId : '—')
          this.ImportInfoRow('重定向', this.probeRedirected ? '是(异常)' : '否')
          this.ImportInfoRow('验证时间', this.probeVerifiedAtLabel())
        }
        if (this.probeErrorCode.length > 0) {
          Text(`错误码: ${this.probeErrorCode}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
          Text(`错误信息: ${this.probeErrorMessage}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        if (this.probeState === ModelResourceProbeState.VERIFIED) {
          Text('资源传输验证通过')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.model_settings_success'))
            .margin({ top: 8 })
            .width('100%')
        }
      }
      .width('100%')
      .margin({ top: 12 })

      // ===== Phase 1D-2B-2: 用户模型加载(GLTFLoader 实际加载与原子替换) =====
      Divider().margin({ top: 12, bottom: 12 })

      Text('用户模型加载(Phase 1D-2B-2)')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 加载模型按钮
      Button(this.loadInProgress ? '加载中...' : '加载模型')
        .fontSize($r('app.float.app_font_body'))
        .fontColor('#FFFFFF')
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .width('100%')
        .enabled(
          this.preparedResource !== null &&
          this.viewerState === ArkWebViewerState.READY &&
          this.probeState === ModelResourceProbeState.VERIFIED &&
          !this.loadInProgress &&
          !this.probeInProgress
        )
        .onClick(() => {
          this.onLoadModelButton();
        })

      // 加载结果信息
      Column() {
        this.ImportInfoRow('加载状态', this.loadStateLabel())
        if (this.loadState !== 'NOT_REQUESTED') {
          this.ImportInfoRow('目标文件', this.loadDisplayName.length > 0 ? this.loadDisplayName : '—')
          this.ImportInfoRow('当前模型', this.loadModelDisplayName.length > 0 ? this.loadModelDisplayName : '—')
          this.ImportInfoRow('开始时间', this.loadStartedAtLabel())
          this.ImportInfoRow('完成时间', this.loadCompletedAtLabel())
        }
        if (this.loadErrorCode.length > 0) {
          Text(`错误码: ${this.loadErrorCode}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
          Text(`错误信息: ${this.loadErrorMessage}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        if (this.loadState === 'READY') {
          Text('用户模型加载成功,已替换当前模型')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.model_settings_success'))
            .margin({ top: 8 })
            .width('100%')
        }
        if (this.loadState === 'FAILED') {
          Text('加载失败,当前模型已保留,可重试')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
        }
      }
      .width('100%')
      .margin({ top: 12 })

      // ===== Phase 1D-2C-1: 运行诊断(最近一条 Provider/GLTFLoader/Coordinator 诊断) =====
      Divider().margin({ top: 12, bottom: 12 })

      Text('运行诊断(Phase 1D-2C-1)')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 刷新诊断按钮(手动拉取一次最近诊断)
      // Phase 1D-2C-2A: 不再依赖 ViewerState === READY,只要 Viewer 未被销毁就允许刷新
      // (初始化失败时也必须能查看启动诊断)
      Button('刷新诊断')
        .fontSize($r('app.float.app_font_body'))
        .fontColor('#FFFFFF')
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .width('100%')
        .enabled(this.viewerState !== ArkWebViewerState.DISPOSED && this.webLoaded)
        .onClick(() => {
          this.refreshRuntimeDiagnostic();
        })

      // 诊断信息显示
      Column() {
        if (this.runtimeDiagnostic === null) {
          this.ImportInfoRow('最后阶段', '—')
          this.ImportInfoRow('错误码', '—')
          this.ImportInfoRow('错误信息', '暂无诊断记录')
        } else {
          this.ImportInfoRow('最后阶段', this.runtimeStageLabel(this.runtimeDiagnostic.stage))
          this.ImportInfoRow('错误码', this.runtimeDiagnostic.code.length > 0 ? this.runtimeDiagnostic.code : '—')
          this.ImportInfoRow('错误信息', this.runtimeDiagnostic.message.length > 0 ? this.runtimeDiagnostic.message : '—')
          this.ImportInfoRow('请求方法', this.runtimeDiagnostic.requestMethod.length > 0 ? this.runtimeDiagnostic.requestMethod : '—')
          this.ImportInfoRow('HTTP 状态', this.runtimeDiagnostic.httpStatus > 0 ? `${this.runtimeDiagnostic.httpStatus}` : '—')
          this.ImportInfoRow('MIME', this.runtimeDiagnostic.mimeType.length > 0 ? this.runtimeDiagnostic.mimeType : '—')
          this.ImportInfoRow('Content-Length', this.runtimeDiagnostic.contentLength > 0 ? this.sizeLabel(this.runtimeDiagnostic.contentLength) : '—')
          this.ImportInfoRow('资源 ID', this.runtimeDiagnostic.resourceId.length > 0 ? this.runtimeDiagnostic.resourceId : '—')
          this.ImportInfoRow('发生时间', this.diagnosticTimestampLabel())
        }
      }
      .width('100%')
      .margin({ top: 12 })

      // 阶段颜色提示(失败/成功)
      if (this.runtimeDiagnostic !== null) {
        Text(this.runtimeStageLabel(this.runtimeDiagnostic.stage))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.runtimeStageColor(this.runtimeDiagnostic.stage))
          .margin({ top: 8 })
          .width('100%')
      }

      // 清除诊断按钮
      Button('清除诊断')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .width('100%')
        .margin({ top: 8 })
        .enabled(this.runtimeDiagnostic !== null)
        .onClick(() => {
          this.onClearDiagnosticButton();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 导入状态显示标签 */
  private importStateLabel(): string {
    if (this.importState === ModelImportState.IDLE) {
      return '空闲';
    } else if (this.importState === ModelImportState.PICKING) {
      return '正在选择文件...';
    } else if (this.importState === ModelImportState.COPYING) {
      return '正在复制到缓存...';
    } else if (this.importState === ModelImportState.READY) {
      return '已准备';
    } else if (this.importState === ModelImportState.CANCELLED) {
      return '已取消选择';
    } else if (this.importState === ModelImportState.FAILED) {
      return '导入失败';
    } else if (this.importState === ModelImportState.DISPOSED) {
      return '已销毁';
    }
    return '未知';
  }

  /** 格式标签(显示扩展名 + 文件类型 + MIME) */
  private formatLabel(file: ImportedModelFile): string {
    return `.${file.extension} (${file.fileType}, ${file.mimeType})`;
  }

  /** 文件大小标签(人类可读) */
  private sizeLabel(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    } else if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    } else {
      return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
    }
  }

  /** 缓存准备状态标签 */
  private cacheReadyLabel(): string {
    if (this.importState === ModelImportState.READY && this.importedFile !== null) {
      return '已写入受控缓存';
    }
    return '未准备';
  }

  /** glTF 依赖状态标签 */
  private gltfDependencyLabel(file: ImportedModelFile): string {
    if (file.gltfDependencyState === GltfDependencyState.NOT_APPLICABLE) {
      return '不适用(自包含二进制)';
    } else if (file.gltfDependencyState === GltfDependencyState.SELF_CONTAINED) {
      return '自包含(data: URI 内嵌)';
    } else if (file.gltfDependencyState === GltfDependencyState.EXTERNAL_FILES_REQUIRED) {
      return `依赖外部文件(${file.gltfExternalUris.length} 个),后续阶段需要附属资源导入`;
    } else if (file.gltfDependencyState === GltfDependencyState.REMOTE_RESOURCES_FOUND) {
      return `引用远程资源(${file.gltfExternalUris.length} 个),后续阶段需要网络下载策略`;
    } else if (file.gltfDependencyState === GltfDependencyState.INVALID_JSON) {
      return 'JSON 无效';
    }
    return '未知';
  }

  /** Phase 1D-2A: 资源 Provider 状态显示标签 */
  private resourceStateLabel(): string {
    if (this.resourceState === ModelResourceState.EMPTY) {
      return '空闲(无资源)';
    } else if (this.resourceState === ModelResourceState.READY) {
      return '已就绪(可拦截请求)';
    } else if (this.resourceState === ModelResourceState.DISPOSED) {
      return '已销毁';
    }
    return '未知';
  }

  /**
   * Phase 1D-2C-2E-1: Web Prepared 资源状态显示标签。
   *
   * 与 resourceStateLabel 解耦:
   * - resourceState === READY 只表示 Native Provider 已注册资源 URL
   * - webPreparedState === READY 表示 JavaScript keeper 已通过 prepareModelResource
   *   接收资源元数据并通过 getPreparedModelResource 回读校验
   *
   * 状态机:
   *   EMPTY → PREPARING → READY
   *   PREPARING → FAILED
   */
  private webPreparedStateLabel(): string {
    if (this.webPreparedState === WebPreparedResourceState.EMPTY) {
      return '未准备';
    } else if (this.webPreparedState === WebPreparedResourceState.PREPARING) {
      return '准备中';
    } else if (this.webPreparedState === WebPreparedResourceState.READY) {
      return '已准备';
    } else if (this.webPreparedState === WebPreparedResourceState.FAILED) {
      return '准备失败';
    }
    return '未知';
  }

  @Builder
  ImportInfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width(80)
      Text(value)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  TabPoseContent() {
    Column() {
      Text('等待 3D 模型与 Humanoid 初始化')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 12 })

      Row() {
        this.DisabledPoseButton('Reset')
        this.DisabledPoseButton('Head Yaw Left')
        this.DisabledPoseButton('Head Yaw Right')
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DisabledPoseButton(label: string) {
    Button(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_tertiary'))
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .height(36)
      .enabled(false)
      .layoutWeight(1)
      .margin({ left: 4, right: 4 })
  }

  @Builder
  TabAnimationContent() {
    Column() {
      // Phase 3A: 动画系统状态显示(只读,无播放控件)
      Text('动画系统')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      this.DebugRow('动画状态', this.debugAnimationState)
      this.DebugRow('VRM 绑定', this.debugAnimationVrmBound ? '已绑定' : '未绑定')
      this.DebugRow('Mixer', this.debugAnimationMixerReady ? 'READY' : 'NOT READY')
      this.DebugRow('动画文件', this.debugAnimationClipReady ? this.debugAnimationName : '未导入')

      if (this.debugAnimationErrorCode.length > 0) {
        this.DebugRow('动画错误', `${this.debugAnimationErrorCode}: ${this.debugAnimationErrorMessage}`)
      }

      Text('VRMA 文件导入与播放将在下一项接入')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ top: 16 })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  TabExpressionContent() {
    Text('表情功能尚未启用')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
  }

  @Builder
  TabPhysicsContent() {
    Text('Spring Bone 功能尚未启用')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
  }

  @Builder
  TabSceneContent() {
    Column() {
      // 背景颜色选项
      Text('背景颜色')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      Row() {
        this.ColorSwatch('#1A1A1A')
        this.ColorSwatch('#2C3E50')
        this.ColorSwatch('#1B5E20')
        this.ColorSwatch('#4A148C')
        this.ColorSwatch('#F5F5F5')
      }
      .width('100%')
      .margin({ bottom: 16 })

      // 网格显示开关
      Row() {
        Text('网格显示')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.showGrid })
          .onChange((on: boolean) => {
            // Phase 2A-1: 调用 Bridge,成功后更新状态,失败时恢复 Switch
            this.onGridToggleChanged(on);
          })
      }
      .width('100%')
      .padding({
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .margin({ bottom: 16 })

      // 灯光强度滑块
      Column() {
        Row() {
          Text('灯光强度')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .layoutWeight(1)
          Text(`${this.lightIntensity}%`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
        }
        .width('100%')
        .margin({ bottom: 8 })

        Slider({ value: this.lightIntensity, min: 0, max: 100, style: SliderStyle.OutSet })
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            // Phase 2A-1: 拖动期间本地更新百分比显示,Bridge 调用节流
            this.onLightIntensitySliderChange(value);
            // 滑动结束(End)或点击(Click)时立即提交最终值
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onLightIntensitySliderChangeEnd(value);
            }
          })
      }
      .width('100%')
      .margin({ bottom: 16 })

      // Phase 2F: 环境贴图与天空盒
      Text('环境贴图')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 环境光照开关
      Row() {
        Text('环境光照')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
        // 环境未 READY 时禁用 Switch
        Toggle({
          type: ToggleType.Switch,
          isOn: this.environmentEnabled
        })
          .enabled(this.environmentState === 'READY')
          .onChange((on: boolean) => {
            this.onEnvironmentToggleChanged(on);
          })
      }
      .width('100%')
      .padding({
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .margin({ bottom: 8 })

      // 环境状态显示(未就绪或失败时显示状态)
      if (this.environmentState !== 'READY') {
        Text(`环境状态: ${this.environmentState}${this.environmentErrorMessage.length > 0 ? ' - ' + this.environmentErrorMessage : ''}`)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.environmentState === 'FAILED' ? $r('app.color.app_danger') : $r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ bottom: 8 })
      }

      // 天空盒开关(仅当环境 READY 且启用时才可用)
      Row() {
        Text('天空盒')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
        Toggle({
          type: ToggleType.Switch,
          isOn: this.skyboxVisible
        })
          .enabled(this.environmentState === 'READY' && this.environmentEnabled)
          .onChange((on: boolean) => {
            this.onSkyboxToggleChanged(on);
          })
      }
      .width('100%')
      .padding({
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .margin({ bottom: 8 })

      // 环境强度滑块(仅当环境 READY 时可用)
      Column() {
        Row() {
          Text('环境强度')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .layoutWeight(1)
          Text(`${this.environmentIntensityPercentage}%`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
        }
        .width('100%')
        .margin({ bottom: 8 })

        Slider({
          value: this.environmentIntensityPercentage,
          min: 0,
          max: 200,
          style: SliderStyle.OutSet
        })
          .enabled(this.environmentState === 'READY')
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            this.onEnvironmentIntensitySliderChange(value);
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onEnvironmentIntensitySliderChangeEnd(value);
            }
          })
      }
      .width('100%')

      Text('当前: 背景 ' + this.sceneBackgroundColor + ' | 灯光 ' + this.sceneLightIntensity.toFixed(2))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ColorSwatch(color: string) {
    Stack() {
      if (this.backgroundOption === color) {
        Text('✓')
          .fontSize(14)
          .fontColor(color === '#F5F5F5' ? '#1A1A1A' : '#FFFFFF')
      }
    }
    .width(36)
    .height(36)
    .borderRadius($r('app.float.app_radius_sm'))
    .backgroundColor(color)
    .border({
      width: this.backgroundOption === color ? 2 : 1,
      color: this.backgroundOption === color
        ? $r('app.color.app_accent')
        : $r('app.color.app_divider')
    })
    .margin({ right: 8 })
    .onClick(() => {
      // Phase 2A-1: 先调用 Bridge,成功后更新状态,失败时恢复之前选中颜色
      this.onBackgroundColorSelected(color);
    })
  }

  @Builder
  TabDebugContent() {
    Column() {
      this.DebugRow('Viewer UI', this.viewerState === ArkWebViewerState.READY ? 'READY' : this.viewerState)
      this.DebugRow('Web Bridge', this.webLoaded ? 'READY' : 'PENDING')
      this.DebugRow('Three.js', this.viewerState === ArkWebViewerState.READY ? 'READY' : 'NOT LOADED')
      this.DebugRow('Scene', this.viewerState === ArkWebViewerState.READY ? 'READY' : 'NOT INITIALIZED')
      this.DebugRow('Camera', this.viewerState === ArkWebViewerState.READY ? 'READY' : 'NOT INITIALIZED')
      this.DebugRow('Frame Loop', this.viewerState === ArkWebViewerState.READY ? 'RUNNING' : 'STOPPED')

      // Phase 2A-1: Model Debug 状态(来自 ViewerModelLoader 真实状态,不再硬编码 NOT LOADED)
      this.DebugRow('Model', this.debugModelState)
      this.DebugRow('Model Name', this.debugModelDisplayName.length > 0 ? this.debugModelDisplayName : '-')
      this.DebugRow('Model Source', this.debugModelSource)
      this.DebugRow('Model Loaded', this.debugModelLoaded ? 'TRUE' : 'FALSE')

      // Phase 2A-1: Scene 与 Camera Controls Debug 状态
      this.DebugRow('Background', this.sceneBackgroundColor)
      this.DebugRow('Grid', this.sceneGridVisible ? 'ON' : 'OFF')
      this.DebugRow('Light Intensity', this.sceneLightIntensity.toFixed(2))
      this.DebugRow('Camera Controls', this.debugCameraControlsEnabled ? 'ENABLED' : 'DISABLED')

      // Phase 2F: Environment Debug 状态
      this.DebugRow('Environment State', this.environmentState)
      this.DebugRow('Environment Source', this.environmentSource)
      this.DebugRow('Environment Enabled', this.environmentEnabled ? 'YES' : 'NO')
      this.DebugRow('Skybox Visible', this.skyboxVisible ? 'YES' : 'NO')
      this.DebugRow('Environment Intensity', this.environmentIntensity.toFixed(2))
      if (this.environmentErrorCode.length > 0) {
        this.DebugRow('Environment Error',
          this.environmentErrorCode + ': ' + this.environmentErrorMessage)
      }

      // Phase 2H: 演示模式 Debug 状态
      this.DebugRow('Presentation Mode', this.presentationMode)
      this.DebugRow('Presentation Transitioning',
        this.presentationTransitioning ? 'YES' : 'NO')
      this.DebugRow('Control Panel Visible',
        this.presentationMode === PresentationMode.NORMAL ? 'YES' : 'NO')
      this.DebugRow('Quick Toolbar Visible',
        this.presentationMode === PresentationMode.NORMAL ? 'YES' : 'NO')
      this.DebugRow('Saved Panel State',
        this.panelStateBeforeDemo >= 0
          ? this.indexToDrawerState(this.panelStateBeforeDemo)
          : '-')
      this.DebugRow('Saved Panel Tab',
        this.panelStateBeforeDemo >= 0
          ? this.indexToViewerTab(this.selectedTabBeforeDemo)
          : '-')
      if (this.presentationWarning.length > 0) {
        this.DebugRow('Presentation Warning', this.presentationWarning)
      }

      // Phase 2A-2: Camera Debug 状态(从 getCameraState 获取,非硬编码)
      this.DebugRow('Camera Position',
        this.debugCameraPositionX.toFixed(3) + ', ' +
        this.debugCameraPositionY.toFixed(3) + ', ' +
        this.debugCameraPositionZ.toFixed(3))
      this.DebugRow('Camera Target',
        this.debugCameraTargetX.toFixed(3) + ', ' +
        this.debugCameraTargetY.toFixed(3) + ', ' +
        this.debugCameraTargetZ.toFixed(3))
      this.DebugRow('Camera Distance', this.debugCameraDistance.toFixed(3))
      this.DebugRow('Camera FOV', this.debugCameraFov.toFixed(2))
      this.DebugRow('Camera Near/Far',
        this.debugCameraNear.toFixed(3) + ' / ' + this.debugCameraFar.toFixed(3))
      this.DebugRow('Camera Aspect', this.debugCameraAspect.toFixed(3))
      this.DebugRow('Camera Last Action', this.debugCameraLastAction)

      // Phase 2B: Camera Transition Debug
      this.DebugRow('Transition State', this.debugCameraTransitionState)
      this.DebugRow('Transition Progress',
        (this.debugCameraTransitionProgress * 100).toFixed(0) + '%')
      this.DebugRow('Transition Duration',
        this.debugCameraTransitionDuration > 0
          ? this.debugCameraTransitionDuration.toFixed(2) + 's'
          : '-')
      this.DebugRow('Transition Elapsed',
        this.debugCameraTransitionDuration > 0
          ? this.debugCameraTransitionElapsed.toFixed(2) + 's'
          : '-')
      if (this.debugCameraTransitionCancelReason.length > 0) {
        this.DebugRow('Transition Cancel', this.debugCameraTransitionCancelReason)
      }
      if (this.debugCameraTransitionErrorCode.length > 0) {
        this.DebugRow('Transition Error',
          this.debugCameraTransitionErrorCode + ': ' + this.debugCameraTransitionErrorMessage)
      }

      // Phase 2A-3A: 截图状态(不显示 cachePath)
      this.DebugRow('Screenshot State', this.screenshotState)
      this.DebugRow('Screenshot File', this.screenshotFileName.length > 0 ? this.screenshotFileName : '-')
      this.DebugRow('Screenshot Size',
        this.screenshotWidth > 0 && this.screenshotHeight > 0
          ? `${this.screenshotWidth}x${this.screenshotHeight}`
          : '-')
      this.DebugRow('Screenshot Bytes',
        this.screenshotByteLength > 0 ? this.formatByteLength(this.screenshotByteLength) : '-')
      this.DebugRow('Screenshot Time',
        this.screenshotCreatedAt > 0 ? this.formatTimestamp(this.screenshotCreatedAt) : '-')
      if (this.screenshotErrorCode.length > 0) {
        this.DebugRow('Screenshot Error', `${this.screenshotErrorCode}: ${this.screenshotErrorMessage}`)
      }

      // Phase 3A: 动画系统 Debug 字段(由 getAnimationDebugState 解析)
      this.DebugRow('Animation State', this.debugAnimationState)
      this.DebugRow('Animation VRM Bound', this.debugAnimationVrmBound ? 'YES' : 'NO')
      this.DebugRow('Animation Mixer', this.debugAnimationMixerReady ? 'READY' : 'NOT READY')
      this.DebugRow('Animation Clip', this.debugAnimationClipReady ? 'READY' : 'NOT READY')
      this.DebugRow('Animation Action', this.debugAnimationActionReady ? 'READY' : 'NOT READY')
      this.DebugRow('Animation Name', this.debugAnimationName.length > 0 ? this.debugAnimationName : '-')
      this.DebugRow('Animation Duration', this.debugAnimationDuration > 0 ? `${this.debugAnimationDuration.toFixed(3)}s` : '-')
      this.DebugRow('Animation Time', this.debugAnimationCurrentTime > 0 ? `${this.debugAnimationCurrentTime.toFixed(3)}s` : '-')
      this.DebugRow('Animation Speed', this.debugAnimationPlaybackSpeed.toFixed(2))
      this.DebugRow('Animation Loop', this.debugAnimationLoop ? 'YES' : 'NO')
      if (this.debugAnimationErrorCode.length > 0) {
        this.DebugRow('Animation Error', `${this.debugAnimationErrorCode}: ${this.debugAnimationErrorMessage}`)
      }
      this.DebugRow('Humanoid', 'NOT INITIALIZED')
      this.DebugRow('Spring Bone', 'NOT INITIALIZED')
      this.DebugRow('Detail', this.viewerDetail)

      if (this.lastError.length > 0) {
        Text(`Error [${this.lastErrorCode}]: ${this.lastError}`)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .margin({ top: 12 })
          .width('100%')
      }

      // Phase 2A-1: 刷新 Debug 状态按钮(手动触发 getSceneState + getCameraState + getAnimationDebugState)
      Button('刷新 Debug 状态')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .width('100%')
        .margin({ top: 12 })
        .onClick(() => {
          this.refreshDebugSceneState();
          this.refreshCameraDebugState();
          this.refreshAnimationDebugState();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DebugRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .layoutWeight(1)
      Text(value)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(value === 'READY'
          ? $r('app.color.model_settings_success')
          : (value === 'NOT IMPLEMENTED' || value === 'FAILED'
            ? $r('app.color.app_text_tertiary')
            : $r('app.color.app_text_primary')))
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .padding({
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_8')
    })
  }
}
