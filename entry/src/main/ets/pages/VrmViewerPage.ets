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
  ArkWebPresentationErrorCode,
  ArkWebAvailableExpression,
  ArkWebExpressionState,
  ArkWebExpressionErrorCode,
  ArkWebSetExpressionParams,
  ArkWebSetTemporaryExpressionParams,
  ArkWebSetExpressionByAliasParams,
  ArkWebSetTemporaryExpressionByAliasParams,
  ArkWebResolveExpressionAliasParams,
  ArkWebExpressionAliasResolution,
  ArkWebTemporaryExpressionState,
  ArkWebTemporaryRestorePolicy,
  parseAvailableExpressions,
  parseExpressionState,
  parseExpressionDebugState,
  parseTemporaryExpressionState,
  parseExpressionAliasResolution
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
import {
  ArkWebAnimationImportController,
  AnimationImportState,
  ImportedAnimationFile
} from '../vrmviewer/ArkWebAnimationImportController';
import {
  ArkWebAnimationResourceProvider,
  AnimationResourceState,
  WebAnimationResource
} from '../vrmviewer/ArkWebAnimationResourceProvider';
import {
  ArkWebAvatarAssetLibrary,
  AVATAR_ASSETS_DIR_NAME
} from '../vrmviewer/ArkWebAvatarAssetLibrary';
import {
  ArkWebPersistentModelStore
} from '../vrmviewer/ArkWebPersistentModelStore';
import {
  ArkWebPersistentAnimationStore
} from '../vrmviewer/ArkWebPersistentAnimationStore';
import {
  ArkWebPersistentPoseStore
} from '../vrmviewer/ArkWebPersistentPoseStore';
import {
  ArkWebPoseImportController,
  PoseImportState
} from '../vrmviewer/ArkWebPoseImportController';
import {
  ArkWebAvatarModelAsset,
  ArkWebAvatarAnimationAsset,
  ArkWebAvatarPoseAsset,
  ArkWebModelRestoreState,
  ArkWebModelRestoreResult,
  ASSET_LIBRARY_SCHEMA_VERSION,
  ModelRestoreErrorCode,
  PersistentAnimationErrorCode,
  AnimationManagementErrorCode,
  PersistentPoseErrorCode,
  PoseImportErrorCode,
  DefaultPoseErrorCode,
  DefaultPoseRestoreState,
  ExpressionAliasErrorCode,
  ArkWebExpressionAliasBusinessId
} from '../vrmviewer/ArkWebAvatarAssetTypes';
import {
  ArkWebAvatarPerformanceCommand,
  ArkWebAvatarPerformanceRuntime,
  ArkWebPerformanceState,
  ArkWebPerformanceResult,
  ArkWebPerformanceDebugState,
  ArkWebPerformanceMotionType,
  ArkWebPerformanceReturnPolicy,
  PerformanceErrorCode,
  validatePerformanceCommand
} from '../vrmviewer/ArkWebAvatarPerformanceTypes';
import { ArkWebAvatarPerformanceController } from '../vrmviewer/ArkWebAvatarPerformanceController';
import {
  ArkWebVrmViewerPagePerformanceRuntime,
  ArkWebVrmViewerPagePerformanceRuntimeDeps
} from '../vrmviewer/ArkWebVrmViewerPagePerformanceRuntime';
import { ArkWebDialoguePerformanceMapper } from '../vrmviewer/ArkWebDialoguePerformanceMapper';
import { ArkWebDialoguePerformanceHint, ArkWebDialoguePerformanceMappingResult } from '../vrmviewer/ArkWebDialoguePerformanceTypes';
import {
  ArkWebDialoguePerformanceLifecycleController,
  ArkWebDialoguePerformanceLifecycleRuntime,
  ArkWebDialogueLifecycleState
} from '../vrmviewer/ArkWebDialoguePerformanceLifecycleController';

/**
 * 传给 JavaScript loadVrmaResource 的资源 JSON 载荷。
 * 字段名与 JS 端期望一致(Phase 3A-2 第十五章)。
 * 仅包含可暴露给 JS 的字段(不含 cachePath/原始 URI/绝对路径)。
 */
interface AnimationResourceBridgePayload {
  resourceUrl: string;
  resourceId: string;
  displayName: string;
  mimeType: string;
  size: number;
}

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
  /** VRMA 动画导入控制器(Phase 3A,在 aboutToAppear 中创建) */
  private animationImportController: ArkWebAnimationImportController | null = null;
  /** VRMA 动画资源提供者(Phase 3A,在 aboutToAppear 中创建) */
  private animationResourceProvider: ArkWebAnimationResourceProvider | null = null;
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
  // Final Acceptance Fix: 相机裁剪相关 Debug 状态
  @State debugCameraMinDistance: number = 0;
  @State debugCameraMaxDistance: number = 0;
  @State debugCameraModelBoundingRadius: number = 0;
  @State debugCameraLastClipUpdateReason: string = '';

  // ===== Final Acceptance UX Cleanup: Debug Tab 折叠区域状态 =====
  /** Debug:模型与资源诊断 折叠状态 (默认折叠) */
  @State debugSectionModelExpanded: boolean = false;
  /** Debug:相机诊断 折叠状态 (默认折叠) */
  @State debugSectionCameraExpanded: boolean = false;
  /** Debug:姿势运行时 折叠状态 (默认折叠) */
  @State debugSectionPoseExpanded: boolean = false;
  /** Debug:动画运行时 折叠状态 (默认折叠) */
  @State debugSectionAnimationExpanded: boolean = false;
  /** Debug:表情运行时 折叠状态 (默认折叠) */
  @State debugSectionExpressionExpanded: boolean = false;
  /** Debug:统一演出 折叠状态 (默认折叠) */
  @State debugSectionPerformanceExpanded: boolean = false;
  /** Debug:对话生命周期 折叠状态 (默认折叠) */
  @State debugSectionLifecycleExpanded: boolean = false;

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
  /** Debug:动画依赖可用性 (Phase 3A 依赖补齐) */
  @State debugAnimationDependencyAvailable: boolean = false;
  /** Debug:动画依赖包名 (Phase 3A 依赖补齐) */
  @State debugAnimationDependencyPackageName: string = '';
  /** Debug:动画依赖版本 (Phase 3A 依赖补齐) */
  @State debugAnimationDependencyVersion: string = '';
  /** Debug:VRMAnimationLoaderPlugin 可用 (Phase 3A 依赖补齐) */
  @State debugAnimationLoaderAvailable: boolean = false;
  /** Debug:createVRMAnimationClip 可用 (Phase 3A 依赖补齐) */
  @State debugAnimationClipFactoryAvailable: boolean = false;
  /** Debug:动画依赖是否需要运行时网络 (Phase 3A 依赖补齐) */
  @State debugAnimationRuntimeNetworkRequired: boolean = false;

  // ===== Phase 3A — VRMA 文件导入与最小播放闭环 =====
  /** Debug:动画资源 ID */
  @State debugAnimationResourceId: string = '';
  /** Debug:动画加载代次 */
  @State debugAnimationLoadGeneration: number = 0;
  /** 动画导入状态 */
  @State animationImportState: AnimationImportState = AnimationImportState.IDLE;
  /** 动画资源状态 */
  @State animationResourceState: AnimationResourceState = AnimationResourceState.EMPTY;
  /** 动画导入错误消息 */
  @State animationImportError: string = '';
  /** 动画操作错误消息 (play/pause/stop/load) */
  @State animationActionError: string = '';
  /** 动画加载轮询定时器 ID */
  private animationLoadPollTimerId: number = -1;
  /** 动画加载轮询次数 */
  private animationLoadPollCount: number = 0;
  /** 动画加载轮询间隔(ms) */
  private readonly ANIMATION_LOAD_POLL_INTERVAL_MS: number = 100;
  /** 动画加载轮询最大次数(300 × 100ms = 30s 超时) */
  private readonly ANIMATION_LOAD_POLL_MAX_COUNT: number = 300;

  // ===== Phase 3C-1 — 多 VRMA 持久化与动作列表 =====
  /** 持久化动画存储 (Phase 3C-1)。 */
  private persistentAnimationStore: ArkWebPersistentAnimationStore | null = null;
  /** 持久化动画资产列表 (从 library.animations 读取)。 */
  @State animationAssets: ArkWebAvatarAnimationAsset[] = [];
  /** 当前选中的 actionId (用户点击列表项后设置)。 */
  @State selectedActionId: string = '';
  /** 动画库错误码 (导入/恢复/加载失败时设置)。 */
  @State animationLibraryErrorCode: string = '';
  /** 动画库错误消息。 */
  @State animationLibraryErrorMessage: string = '';
  /** 默认待机 actionId (Phase 3C-2, 仅元数据, 不自动加载/播放)。 */
  @State defaultIdleActionId: string = '';
  // ===== Phase 3D-1 — JSON 姿势导入与持久化姿势库 =====
  /** 持久化姿势存储 (Phase 3D-1)。 */
  private persistentPoseStore: ArkWebPersistentPoseStore | null = null;
  /** 姿势导入控制器 (Phase 3D-1)。 */
  private poseImportController: ArkWebPoseImportController | null = null;
  /** 持久化姿势资产列表 (从 library.poses 读取)。 */
  @State poseAssets: ArkWebAvatarPoseAsset[] = [];
  /** 当前选中的 poseId (用户点击列表项后设置, 本阶段不应用姿势)。 */
  @State selectedPoseId: string = '';
  /** 姿势导入是否进行中。 */
  @State poseImporting: boolean = false;
  /** 姿势库错误码 (导入/恢复失败时设置)。 */
  @State poseLibraryErrorCode: string = '';
  /** 姿势库错误消息。 */
  @State poseLibraryErrorMessage: string = '';
  /** Phase 3D-2: 姿势应用是否进行中 (applyPose 调用期间)。 */
  @State poseApplying: boolean = false;
  /** Phase 3D-2: 当前已应用的 poseId (空字符串表示无应用)。 */
  @State appliedPoseId: string = '';
  /** Phase 3D-2: 当前已应用的姿势显示名。 */
  @State appliedPoseDisplayName: string = '';
  /** Phase 3D-2: 姿势系统状态文本 (IDLE/APPLIED/FAILED/DISPOSED)。 */
  @State poseSystemState: string = 'IDLE';
  /** Phase 3D-2: 最近一次应用的有效骨骼数。 */
  @State poseAppliedBoneCount: number = 0;
  /** Phase 3D-2: 最近一次应用的忽略骨骼数。 */
  @State poseIgnoredBoneCount: number = 0;
  /** Phase 3D-2: 最近一次姿势错误码 (空字符串表示无错误)。 */
  @State poseLastErrorCode: string = '';
  /** Phase 3D-2: 最近一次姿势错误消息。 */
  @State poseLastErrorMessage: string = '';
  // ===== Phase 3D-3 — 默认姿势与模型加载后自动恢复 =====
  /** 默认姿势 poseId (空字符串表示无默认)。 */
  @State defaultPoseId: string = '';
  /** 默认姿势显示名 (从 poseAssets 中匹配, 无匹配时为空)。 */
  @State defaultPoseDisplayName: string = '';
  /** 默认姿势恢复状态机 (DefaultPoseRestoreState)。 */
  @State defaultPoseRestoreState: DefaultPoseRestoreState = DefaultPoseRestoreState.IDLE;
  /** 默认姿势恢复错误码 (空字符串表示无错误)。 */
  @State defaultPoseRestoreErrorCode: string = '';
  /** 默认姿势恢复错误消息。 */
  @State defaultPoseRestoreErrorMessage: string = '';
  /** 默认姿势恢复是否正在执行中 (防止重复触发)。 */
  @State defaultPoseRestoreInProgress: boolean = false;
  /** 默认姿势恢复代次 (每次启动恢复递增, 用于过期判断)。 */
  private defaultPoseRestoreGeneration: number = 0;
  /** 默认姿势恢复绑定的模型 generation (同一模型最多自动应用一次)。 */
  private defaultPoseRestoreModelGeneration: number = -1;
  /** 最近一次成功恢复的 poseId (用于避免重复恢复同一姿势)。 */
  private lastRestoredDefaultPoseId: string = '';
  /** 页面销毁后阻止异步恢复回调。 */
  private defaultPoseRestoreDisposed: boolean = false;
  /** 删除确认对话框是否显示 (Phase 3C-2, 页面内确认状态, 不引入新 API)。 */
  @State animationDeleteConfirmVisible: boolean = false;
  /** 删除确认对话框待删除的 actionId。 */
  @State pendingDeleteActionId: string = '';
  /** 删除确认对话框待删除的动作显示名。 */
  @State pendingDeleteActionName: string = '';
  /** 重命名对话框是否显示 (Phase 3C-2)。 */
  @State animationRenameDialogVisible: boolean = false;
  /** 重命名对话框待编辑的 actionId。 */
  @State pendingRenameActionId: string = '';
  /** 重命名对话框输入的新名称。 */
  @State pendingRenameDisplayName: string = '';

  // ===== Phase 3E-1 — VRM 表情系统 =====
  /** 当前 VRM 可用表情列表 (从 expressionManager 真实枚举)。 */
  @State availableExpressions: ArkWebAvailableExpression[] = [];
  /** 当前选中的表情名 (用户点击列表项后设置, 空字符串表示未选中)。 */
  @State selectedExpressionName: string = '';
  /** 当前选中的目标权重 (0/0.25/0.5/0.75/1, 默认 1)。 */
  @State selectedExpressionWeight: number = 1;
  /** 表情系统状态 (UNBOUND/READY/APPLIED/FAILED/DISPOSED)。 */
  @State expressionState: string = 'UNBOUND';
  /** expressionManager 是否就绪 (VRM 已绑定且 API 完整)。 */
  @State expressionManagerReady: boolean = false;
  /** 表情系统错误码 (空字符串表示无错误)。 */
  @State expressionErrorCode: string = '';
  /** 表情系统错误消息。 */
  @State expressionErrorMessage: string = '';
  /** 表情操作是否进行中 (setExpression / resetExpression 调用期间)。 */
  @State expressionLoading: boolean = false;
  /** 当前已应用的业务表情名 (空字符串表示无应用)。 */
  @State appliedExpressionName: string = '';
  /** 当前已应用的业务表情权重。 */
  @State appliedExpressionWeight: number = 0;
  /** 口型通道是否保留 (true=YES / false=NO)。 */
  @State expressionLipSyncPreserved: boolean = true;

  // ===== Phase 3E-2 — 表情别名映射与临时表情 =====
  /** 持久化别名映射 (业务 expressionId → 模型真实 expressionName)。模型 READY 后从 AssetLibrary 读取,不自动设置表情。 */
  @State expressionAliasMap: Record<string, string> = {};
  /** 别名映射操作错误码 (成功时为空字符串)。 */
  @State expressionAliasErrorCode: string = '';
  /** 别名映射操作错误消息。 */
  @State expressionAliasErrorMessage: string = '';
  /** 别名映射操作进行中标志。 */
  @State expressionAliasOperating: boolean = false;
  /** 临时表情测试 - 持续时间选项 (1000 / 2500 / 5000 ms)。 */
  @State temporaryExpressionDurationMs: number = 2500;
  /** 临时表情测试 - 恢复策略 (PREVIOUS / RESET)。 */
  @State temporaryExpressionRestorePolicy: string = 'PREVIOUS';
  /** 临时表情测试 - 当前临时表情名 (空字符串表示无临时表情)。 */
  @State temporaryExpressionName: string = '';
  /** 临时表情测试 - 当前临时表情权重。 */
  @State temporaryExpressionWeight: number = 0;
  /** 临时表情测试 - 到期时间戳 (0 表示无任务)。 */
  @State temporaryExpressionExpiresAt: number = 0;
  /** 临时表情测试 - 是否有活跃的 setTimeout 句柄。 */
  @State temporaryExpressionTimerActive: boolean = false;
  /** 临时表情测试 - 代次 (用于让旧 timeout 失效)。 */
  @State temporaryExpressionGeneration: number = 0;
  /** 临时表情测试 - 操作错误码。 */
  @State temporaryExpressionErrorCode: string = '';
  /** 临时表情测试 - 操作错误消息。 */
  @State temporaryExpressionErrorMessage: string = '';
  /** 临时表情测试 - 操作进行中标志。 */
  @State temporaryExpressionOperating: boolean = false;
  /** 别名映射 - 当前选中的业务 ID (用于绑定/取消)。 */
  @State expressionAliasSelectedBusinessId: string = 'happy';

  // ===== Phase 3F-1 — 统一角色演出系统 =====
  /** PerformanceController 实例 (aboutToAppear 创建, disposeViewer 销毁) */
  @State performanceController: ArkWebAvatarPerformanceController | null = null;
  /** 演出状态 */
  @State performanceState: ArkWebPerformanceState = ArkWebPerformanceState.IDLE;
  /** 演出 generation */
  @State performanceGeneration: number = 0;
  /** 当前命令 ID */
  @State performanceCommandId: string = '';
  /** 当前动作类型 */
  @State performanceMotionType: string = '';
  /** 当前动作 ID (actionId / poseId) */
  @State performanceMotionId: string = '';
  /** 当前表情业务 ID */
  @State performanceExpressionId: string = '';
  /** 当前表情权重 */
  @State performanceExpressionWeight: number = 0;
  /** 到期时间戳 */
  @State performanceExpiresAt: number = 0;
  /** 恢复 timeout 是否活动 */
  @State performanceRestoreTimerActive: boolean = false;
  /** 最近错误码 */
  @State performanceLastErrorCode: string = '';
  /** 最近错误消息 */
  @State performanceLastErrorMessage: string = '';
  /** 演出测试 - 操作进行中标志 */
  @State performanceOperating: boolean = false;
  /** 演出测试 - 选中的动作类型 (animation / pose / none) */
  @State performanceTestMotionType: ArkWebPerformanceMotionType = 'none';
  /** 演出测试 - 选中的持续时间 */
  @State performanceTestDurationMs: number = 2500;
  /** 演出测试 - 选中的恢复策略 */
  @State performanceTestReturnPolicy: ArkWebPerformanceReturnPolicy = 'DEFAULT_POSE';
  /** 演出测试 - 选中的业务表情 ID (空表示不设置表情) */
  @State performanceTestExpressionId: string = 'happy';

  // ===== Phase 3F-2 — AI 对话结果到演出指令的安全映射 =====
  /** DialoguePerformanceMapper 实例 (aboutToAppear 创建, disposeViewer 销毁) */
  @State dialoguePerformanceMapper: ArkWebDialoguePerformanceMapper | null = null;
  /** 最近一次映射结果 accepted (供 UI 显示) */
  @State dialogueLastAccepted: boolean = false;
  /** 最近一次映射结果 degraded (供 UI 显示) */
  @State dialogueLastDegraded: boolean = false;
  /** 最近一次映射 warnings (供 UI 显示) */
  @State dialogueLastWarnings: string = '';
  /** 最近一次映射 errorCode (供 UI 显示) */
  @State dialogueLastErrorCode: string = '';
  /** 最近一次映射 errorMessage (供 UI 显示) */
  @State dialogueLastErrorMessage: string = '';
  /** 最近一次映射生成的 commandId (供 UI 显示) */
  @State dialogueLastCommandId: string = '';
  /** 映射操作进行中标志 */
  @State dialogueOperating: boolean = false;

  // ===== Phase 3F-3 — 对话演出生命周期接入 =====
  /** LifecycleController 实例 (aboutToAppear 创建, disposeViewer 销毁) */
  @State dialogueLifecycleController: ArkWebDialoguePerformanceLifecycleController | null = null;
  /** 当前生命周期状态 (UI 显示) */
  @State dialoguePerformanceState: ArkWebDialogueLifecycleState = ArkWebDialogueLifecycleState.IDLE;
  /** 当前在处理的 turnId */
  @State dialoguePerformanceTurnId: string = '';
  /** 当前 commandId */
  @State dialoguePerformanceCommandId: string = '';
  /** 最近一次映射是否降级 */
  @State dialoguePerformanceDegraded: boolean = false;
  /** 最近一次映射警告 */
  @State dialoguePerformanceWarnings: string = '';
  /** 生命周期最后错误码 */
  @State dialoguePerformanceErrorCode: string = '';
  /** 生命周期最后错误消息 */
  @State dialoguePerformanceErrorMessage: string = '';

  // ===== Phase 3B — 模型自动恢复与持久化资产目录 =====
  /** 资产库状态(READY / EMPTY / FAILED / DISPOSED) */
  @State assetLibraryState: string = 'IDLE';
  /** 资产库 schema 版本(固定 1) */
  @State assetLibraryVersion: number = 0;
  /** 当前 activeModelId(空字符串表示无) */
  @State activeModelId: string = '';
  /** 当前 activeModel 显示名 */
  @State activeModelDisplayName: string = '';
  /** 当前 activeModel 文件大小(字节) */
  @State activeModelByteLength: number = 0;
  /** 模型存储类型(固定 PERSISTENT) */
  @State modelStorageKind: string = 'PERSISTENT';
  /** 模型恢复状态机(ArkWebModelRestoreState) */
  @State modelRestoreState: ArkWebModelRestoreState = ArkWebModelRestoreState.IDLE;
  /** 模型恢复错误码(成功时为空字符串) */
  @State modelRestoreErrorCode: string = '';
  /** 模型恢复错误消息(成功时为空字符串) */
  @State modelRestoreErrorMessage: string = '';
  /** 旧缓存模型是否已迁移 */
  @State legacyModelMigrated: boolean = false;
  /** Debug: 测试立方体开关状态 */
  @State debugTestCubeEnabled: boolean = false;
  /** 持久化资产库(单一所有者,在 aboutToAppear 中创建) */
  private assetLibrary: ArkWebAvatarAssetLibrary | null = null;
  /** 持久化模型存储(在 aboutToAppear 中创建) */
  private persistentModelStore: ArkWebPersistentModelStore | null = null;
  /** 恢复是否已启动(单次触发保护) */
  private restoreStarted: boolean = false;
  /** 恢复是否已销毁(页面销毁后阻止异步回调) */
  private restoreDisposed: boolean = false;
  /** 恢复代次(每次启动恢复递增,用于过期判断) */
  private modelRestoreGeneration: number = 0;
  /** 恢复是否正在执行中(防止重复触发) */
  private modelRestoreInProgress: boolean = false;

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
        // Phase 3B:Viewer READY 后启动 activeModel 自动恢复(单次触发)
        // 读取 library.json → 验证持久化模型 → 注册 Provider → 加载模型
        // 失败不抛出,仅更新 modelRestoreState 供 UI 显示
        this.startActiveModelRestore();
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

    // Phase 3B:创建持久化资产库与模型存储(单次创建,页面重入复用)
    // 必须在 resourceProvider 创建之后,在 importStateStore 之前
    if (this.assetLibrary === null) {
      this.assetLibrary = new ArkWebAvatarAssetLibrary(ctx);
      // 异步初始化目录与清单,不阻塞页面构建
      // Viewer READY 后 startActiveModelRestore 会 await ensureInitialized
      this.assetLibrary.ensureInitialized().then((ok: boolean) => {
        if (ok) {
          this.assetLibraryState = 'READY';
          this.assetLibraryVersion = ASSET_LIBRARY_SCHEMA_VERSION;
          console.info('[VrmViewerPage] AssetLibrary initialized');
        } else {
          this.assetLibraryState = 'FAILED';
          console.warn('[VrmViewerPage] AssetLibrary ensureInitialized failed');
        }
      }).catch((e: Object) => {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.assetLibraryState = 'FAILED';
        console.warn(`[VrmViewerPage] AssetLibrary init exception: ${msg}`);
      });
    }
    if (this.persistentModelStore === null && this.assetLibrary !== null) {
      this.persistentModelStore = new ArkWebPersistentModelStore(ctx, this.assetLibrary);
    }
    // Phase 3B:配置 Provider 接受 filesDir/avatar-assets/ 下的持久化模型
    if (this.resourceProvider !== null && this.assetLibrary !== null) {
      this.resourceProvider.setPersistentRootDir(this.assetLibrary.getAssetsRootDir());
    }

    // Phase 1D-2C-1:创建导入元数据持久化存储(Phase 3B 起仅用于旧缓存迁移)
    // 恢复由 startActiveModelRestore 统一编排,不再在 aboutToAppear 中自动触发
    if (this.importStateStore === null) {
      this.importStateStore = new ArkWebModelImportStateStore(ctx);
    }

    // Phase 2A-3A:创建截图控制器(Route A: Native ArkWeb Snapshot)
    if (this.screenshotController === null) {
      this.screenshotController = new ArkWebScreenshotController(
        this.arkWebController.getWebviewController(),
        ctx.cacheDir,
        () => this.arkWebController.getState()
      );
    }

    // Phase 3A:创建 VRMA 动画导入控制器和资源 Provider
    if (this.animationImportController === null) {
      this.animationImportController = new ArkWebAnimationImportController(ctx);
      this.animationResourceProvider = new ArkWebAnimationResourceProvider(ctx.cacheDir);
    }

    // Phase 3C-1:创建持久化动画存储,配置 Provider 接受 filesDir/avatar-assets/animations/
    if (this.persistentAnimationStore === null && this.assetLibrary !== null) {
      this.persistentAnimationStore = new ArkWebPersistentAnimationStore(ctx, this.assetLibrary);
    }
    if (this.animationResourceProvider !== null && this.assetLibrary !== null) {
      this.animationResourceProvider.setPersistentRootDir(this.assetLibrary.getAssetsRootDir());
      // 异步加载已有动画列表(不在启动时自动加载动画内容)
      this.loadAnimationAssetsFromLibrary();
    }

    // Phase 3D-1:创建姿势导入控制器和持久化姿势存储
    // 本阶段只管理姿势资产元数据,不应用姿势到模型骨骼
    if (this.poseImportController === null) {
      this.poseImportController = new ArkWebPoseImportController(ctx);
    }
    if (this.persistentPoseStore === null && this.assetLibrary !== null) {
      this.persistentPoseStore = new ArkWebPersistentPoseStore(ctx, this.assetLibrary);
      // 异步加载已有姿势列表(不在启动时自动选中或应用姿势)
      this.loadPoseAssetsFromLibrary();
    }

    // Phase 3F-1:创建统一演出控制器 (注入 AssetLibrary 和 Runtime 回调)
    // Runtime 回调复用页面现有方法, 不复制底层实现
    if (this.performanceController === null && this.assetLibrary !== null) {
      const runtime: ArkWebAvatarPerformanceRuntime = this.createPerformanceRuntime();
      this.performanceController = new ArkWebAvatarPerformanceController(this.assetLibrary, runtime);
    }

    // Phase 3F-2:创建 AI 对话结果到演出指令的安全映射器
    // Mapper 只做 JSON 解析和字段校验, 不创建 Timer / 网络 / AI 客户端
    if (this.dialoguePerformanceMapper === null && this.assetLibrary !== null) {
      this.dialoguePerformanceMapper = new ArkWebDialoguePerformanceMapper(this.assetLibrary);
    }

    // Phase 3F-3:创建对话演出生命周期控制器
    // LifecycleController 通过依赖接口注入 Mapper 和 Runtime, 不重新实现映射或演出逻辑
    if (this.dialogueLifecycleController === null
        && this.dialoguePerformanceMapper !== null
        && this.performanceController !== null) {
      const self: VrmViewerPage = this;
      const lifecycleRuntime: ArkWebDialoguePerformanceLifecycleRuntime = {
        stopPerformance: (): Promise<boolean> => {
          if (self.performanceController === null) {
            return Promise.resolve(false);
          }
          return self.performanceController.stopPerformance();
        },
        executePerformance: (cmd: ArkWebAvatarPerformanceCommand): Promise<boolean> => {
          if (self.performanceController === null) {
            return Promise.resolve(false);
          }
          return self.performanceController.executeCommand(cmd).then(
            (result: ArkWebPerformanceResult): boolean => {
              self.syncPerformanceDebugState();
              return result.success;
            }
          );
        }
      };
      this.dialogueLifecycleController =
        new ArkWebDialoguePerformanceLifecycleController(
          this.dialoguePerformanceMapper, lifecycleRuntime);
    }

    // Web 组件加载由 build() 触发,初始化在 onPageEnd 回调中完成
  }

  /**
   * Phase 3F-1: 创建演出 Runtime 回调。
   *
   * 复用页面现有方法, 不复制底层实现:
   *   - stopAnimation → arkWebController.stopAnimation
   *   - playAnimationById → loadAnimationByActionId + playAnimation
   *   - applyPoseById → readPoseDataAsJson + applyPose
   *   - resetPose → arkWebController.resetPose
   *   - restoreDefaultPose → defaultPoseId + applyPose (无默认则 resetPose)
   *   - setTemporaryExpressionByAlias → arkWebController.setTemporaryExpressionByAlias
   *   - cancelTemporaryExpression → arkWebController.cancelTemporaryExpression
   */
  private createPerformanceRuntime(): ArkWebAvatarPerformanceRuntime {
    const self: VrmViewerPage = this;
    const deps: ArkWebVrmViewerPagePerformanceRuntimeDeps = {
      getArkWebController: (): ArkWebVrmViewerController | null => self.arkWebController,
      getAssetLibrary: (): ArkWebAvatarAssetLibrary | null => self.assetLibrary,
      getPersistentPoseStore: (): ArkWebPersistentPoseStore | null => self.persistentPoseStore,
      getExpressionAliasMap: (): Record<string, string> => self.expressionAliasMap,
      getDebugAnimationState: (): string => self.debugAnimationState,
      loadAnimationByActionId: (actionId: string): Promise<boolean> => self.loadAnimationByActionId(actionId),
      waitForAnimationReady: (timeoutMs: number): Promise<boolean> => self.waitForAnimationReady(timeoutMs),
      resetPoseInternal: (): Promise<boolean> => self.resetPoseInternal(),
      applyPoseByIdInternal: (poseId: string): Promise<boolean> => self.applyPoseByIdInternal(poseId)
    };
    return new ArkWebVrmViewerPagePerformanceRuntime(deps);
  }

  /**
   * Phase 3F-1: 内部 resetPose 调用 (供 Runtime 回调使用)。
   */
  private async resetPoseInternal(): Promise<boolean> {
    if (this.arkWebController === null) {
      return false;
    }
    try {
      const resultJson: string = await this.arkWebController.resetPose();
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      console.warn('[PerformanceRuntime] resetPoseInternal failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  /**
   * Phase 3F-1: 内部 applyPoseById 调用 (供 Runtime 回调使用)。
   *
   * 复用 readPoseDataAsJson + applyPose, 不复制 JSON 骨骼转换逻辑。
   */
  private async applyPoseByIdInternal(poseId: string): Promise<boolean> {
    if (this.arkWebController === null || this.persistentPoseStore === null) {
      return false;
    }
    try {
      const poseJson: string = await this.persistentPoseStore.readPoseDataAsJson(poseId);
      if (poseJson.length === 0) {
        console.warn(`[PerformanceRuntime] applyPoseByIdInternal: poseJson empty: ${poseId}`);
        return false;
      }
      const resultJson: string = await this.arkWebController.applyPose(poseJson);
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      console.warn('[PerformanceRuntime] applyPoseByIdInternal failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  /**
   * Phase 3F-1: 等待动画进入 READY 状态。
   *
   * 复用 animationLoadPolling 机制, 不引入第二个轮询。
   * 上限 timeoutMs 后放弃 (不阻塞 PerformanceController 主流程)。
   */
  private async waitForAnimationReady(timeoutMs: number): Promise<boolean> {
    const startTick: number = Date.now();
    while (Date.now() - startTick < timeoutMs) {
      if (this.debugAnimationState === 'READY') {
        return true;
      }
      if (this.debugAnimationState === 'FAILED') {
        return false;
      }
      // 刷新状态 (复用 refreshAnimationDebugState, 不启动新的 setInterval)
      if (this.arkWebController !== null) {
        try {
          const resultJson: string = await this.arkWebController.getAnimationDebugState();
          this.parseAnimationDebugState(resultJson);
        } catch (e) {
          console.warn('[PerformanceRuntime] waitForAnimationReady poll failed: ' +
            (e instanceof Error ? e.message : String(e)));
        }
      }
      // 短暂让步 (避免阻塞 UI, 不引入 setInterval)
      await new Promise<void>((resolve: Function) => setTimeout(resolve, 100));
    }
    return this.debugAnimationState === 'READY';
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
    // Phase 3A:10. 停止动画加载轮询
    this.stopAnimationLoadPolling();
    // Phase 3A:11. 销毁动画资源 Provider(停止响应拦截请求)
    if (this.animationResourceProvider !== null) {
      this.animationResourceProvider.dispose();
      this.animationResourceProvider = null;
    }
    // Phase 3A:12. 销毁动画导入控制器(不删除已缓存文件)
    if (this.animationImportController !== null) {
      this.animationImportController.dispose();
      this.animationImportController = null;
    }
    // Phase 3C-1:13. 销毁持久化动画存储(不删除 filesDir 下的动画文件,不清空 library.animations)
    if (this.persistentAnimationStore !== null) {
      this.persistentAnimationStore.dispose();
      this.persistentAnimationStore = null;
    }
    // Phase 3C-1:14. 清空动画列表运行时状态(下次进入重新读取 library)
    this.animationAssets = [];
    this.selectedActionId = '';
    this.animationLibraryErrorCode = '';
    this.animationLibraryErrorMessage = '';
    // Phase 3C-2: 清空管理对话框运行时状态 (不删除持久数据)
    this.defaultIdleActionId = '';
    this.animationDeleteConfirmVisible = false;
    this.pendingDeleteActionId = '';
    this.pendingDeleteActionName = '';
    this.animationRenameDialogVisible = false;
    this.pendingRenameActionId = '';
    this.pendingRenameDisplayName = '';
    // Phase 3D-1: 销毁姿势导入控制器和持久化姿势存储
    // (不删除 filesDir 下的姿势文件, 不清空 library.poses)
    if (this.poseImportController !== null) {
      this.poseImportController.dispose();
      this.poseImportController = null;
    }
    if (this.persistentPoseStore !== null) {
      this.persistentPoseStore.dispose();
      this.persistentPoseStore = null;
    }
    // Phase 3D-1: 清空姿势列表运行时状态(下次进入重新读取 library)
    this.poseAssets = [];
    this.selectedPoseId = '';
    this.poseImporting = false;
    this.poseLibraryErrorCode = '';
    this.poseLibraryErrorMessage = '';
    // Phase 3D-2: 清空姿势应用状态 (不调用 resetPose, Viewer 已 dispose)
    this.poseApplying = false;
    this.appliedPoseId = '';
    this.appliedPoseDisplayName = '';
    this.poseSystemState = 'IDLE';
    this.poseAppliedBoneCount = 0;
    this.poseIgnoredBoneCount = 0;
    this.poseLastErrorCode = '';
    this.poseLastErrorMessage = '';
    // Phase 3D-3: 默认姿势恢复状态清理 (不删除默认姿势文件 / library.json / defaultPoseId)
    this.defaultPoseRestoreDisposed = true;
    this.defaultPoseRestoreInProgress = false;
    this.defaultPoseRestoreGeneration++;
    this.defaultPoseRestoreState = DefaultPoseRestoreState.DISPOSED;
    this.defaultPoseId = '';
    this.defaultPoseDisplayName = '';
    this.defaultPoseRestoreErrorCode = '';
    this.defaultPoseRestoreErrorMessage = '';
    this.lastRestoredDefaultPoseId = '';
    // Phase 3E-1: 清空表情系统运行时状态 (不调用 resetExpression, Viewer 已 dispose)
    // 不跨模型缓存 Expression 实例, 仅清空 ArkTS 侧镜像
    this.availableExpressions = [];
    this.selectedExpressionName = '';
    this.selectedExpressionWeight = 1;
    this.expressionState = ArkWebExpressionState.DISPOSED;
    this.expressionManagerReady = false;
    this.expressionErrorCode = '';
    this.expressionErrorMessage = '';
    this.expressionLoading = false;
    this.appliedExpressionName = '';
    this.appliedExpressionWeight = 0;
    this.expressionLipSyncPreserved = true;
    // Phase 3E-2: 清空临时表情运行时状态 (Viewer 已 dispose, JS 端 timeout 随页面销毁;
    //             此处仅清空 ArkTS 侧镜像, 保留持久化别名映射在 library.json 中)
    this.temporaryExpressionName = '';
    this.temporaryExpressionWeight = 0;
    this.temporaryExpressionExpiresAt = 0;
    this.temporaryExpressionTimerActive = false;
    this.temporaryExpressionGeneration++;
    this.temporaryExpressionErrorCode = '';
    this.temporaryExpressionErrorMessage = '';
    this.temporaryExpressionOperating = false;
    // 别名映射运行时镜像清空 (持久化数据保留在 library.json, 下次进入重新读取)
    this.expressionAliasMap = {};
    this.expressionAliasErrorCode = '';
    this.expressionAliasErrorMessage = '';
    this.expressionAliasOperating = false;
    this.expressionAliasSelectedBusinessId = 'happy';
    // Phase 3F-1: 销毁 PerformanceController (不删除动作 / 姿势 / 表情别名 / library.json)
    // 内部 performanceGeneration++ 使任何在途 timeout 失效
    // best-effort cancelTemporaryExpression + stopAnimation (不等待)
    // 销毁顺序 (Phase 3F-3): LifecycleController → PerformanceController → Mapper
    if (this.dialogueLifecycleController !== null) {
      this.dialogueLifecycleController.dispose();
      this.dialogueLifecycleController = null;
    }
    this.dialoguePerformanceState = ArkWebDialogueLifecycleState.DISPOSED;
    this.dialoguePerformanceTurnId = '';
    this.dialoguePerformanceCommandId = '';
    this.dialoguePerformanceDegraded = false;
    this.dialoguePerformanceWarnings = '';
    this.dialoguePerformanceErrorCode = '';
    this.dialoguePerformanceErrorMessage = '';
    if (this.performanceController !== null) {
      this.performanceController.dispose();
      this.performanceController = null;
    }
    this.performanceState = ArkWebPerformanceState.DISPOSED;
    this.performanceGeneration++;
    this.performanceCommandId = '';
    this.performanceMotionType = '';
    this.performanceMotionId = '';
    this.performanceExpressionId = '';
    this.performanceExpressionWeight = 0;
    this.performanceExpiresAt = 0;
    this.performanceRestoreTimerActive = false;
    this.performanceLastErrorCode = '';
    this.performanceLastErrorMessage = '';
    this.performanceOperating = false;
    // Phase 3F-2: 销毁 DialoguePerformanceMapper (不删除动作 / 姿势 / 别名 / library.json)
    // 仅清理内存状态, 不停止在途演出 (由 PerformanceController.dispose 负责)
    if (this.dialoguePerformanceMapper !== null) {
      this.dialoguePerformanceMapper.dispose();
      this.dialoguePerformanceMapper = null;
    }
    this.dialogueLastAccepted = false;
    this.dialogueLastDegraded = false;
    this.dialogueLastWarnings = '';
    this.dialogueLastErrorCode = '';
    this.dialogueLastErrorMessage = '';
    this.dialogueLastCommandId = '';
    this.dialogueOperating = false;
    // Phase 3B:13. 销毁 Phase 3B 持久化资源(不删除 filesDir 下的模型文件与 library.json)
    // 标记 restoreDisposed 阻止异步恢复回调
    this.restoreDisposed = true;
    this.restoreStarted = false;
    this.modelRestoreInProgress = false;
    this.modelRestoreGeneration++;
    this.modelRestoreState = ArkWebModelRestoreState.DISPOSED;
    if (this.persistentModelStore !== null) {
      this.persistentModelStore.dispose();
      this.persistentModelStore = null;
    }
    if (this.assetLibrary !== null) {
      this.assetLibrary.dispose();
      this.assetLibrary = null;
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
        // Phase 3D-3: 模型 READY 后调度默认姿势自动恢复
        // (内部有 generation + inProgress 双重保护, 重复调用安全)
        this.scheduleDefaultPoseRestore();
        // Phase 3E-1: 模型 READY 后自动读取表情列表 (不自动设置任何表情)
        this.refreshAvailableExpressions();
        // Phase 3E-2: 模型 READY 后只恢复映射元数据, 不自动设置表情
        this.loadExpressionAliasMap();
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
    // Phase 3A 依赖补齐: 同时查询依赖状态
    this.arkWebController.getAnimationDependencyState().then((resultJson: string) => {
      this.parseAnimationDependencyState(resultJson);
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] getAnimationDependencyState exception: ' + (e instanceof Error ? e.message : String(e)));
    });
  }

  // ===== Phase 3E-1 — VRM 表情系统辅助方法 =====

  /**
   * Phase 3E-1: 刷新当前 VRM 可用表情列表。
   *
   * 模型 READY 后自动调用 (不自动设置任何表情)。
   * 用户也可通过"刷新列表"按钮手动触发。
   *
   * 从 expressionManager 真实枚举,不假定固定预设一定存在。
   */
  private refreshAvailableExpressions(): void {
    this.arkWebController.getAvailableExpressions().then((resultJson: string) => {
      const expressions: ArkWebAvailableExpression[] | null =
        parseAvailableExpressions(resultJson);
      if (expressions === null) {
        // 查询失败 (模型未 READY / expressionManager 缺失)
        try {
          const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
          const errObj: Record<string, Object> = (obj['error'] as Record<string, Object>) ||
            {} as Record<string, Object>;
          this.expressionErrorCode = (errObj['code'] as string) || '';
          this.expressionErrorMessage = (errObj['message'] as string) || '';
        } catch (e) {
          // ignore parse error
        }
        this.availableExpressions = [];
        this.expressionManagerReady = false;
        // 清空选中状态 (模型替换后旧选中表情可能不存在)
        this.selectedExpressionName = '';
        this.appliedExpressionName = '';
        this.appliedExpressionWeight = 0;
        this.expressionState = ArkWebExpressionState.UNBOUND;
        return;
      }
      this.availableExpressions = expressions;
      // 查询成功后清除错误 (但保留 expressionManagerReady 的判定)
      this.expressionErrorCode = '';
      this.expressionErrorMessage = '';
      // 同步表情系统状态 (确认 expressionManagerReady)
      this.refreshExpressionState();
      // 若当前选中的表情已不在新列表中,清空选中
      if (this.selectedExpressionName.length > 0) {
        let found: boolean = false;
        for (let i = 0; i < expressions.length; i++) {
          if (expressions[i].name === this.selectedExpressionName) {
            found = true;
            break;
          }
        }
        if (!found) {
          this.selectedExpressionName = '';
        }
      }
      // 若当前已应用的表情已不在新列表中,清空应用记录
      if (this.appliedExpressionName.length > 0) {
        let foundApplied: boolean = false;
        for (let i = 0; i < expressions.length; i++) {
          if (expressions[i].name === this.appliedExpressionName) {
            foundApplied = true;
            break;
          }
        }
        if (!foundApplied) {
          this.appliedExpressionName = '';
          this.appliedExpressionWeight = 0;
        }
      }
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] refreshAvailableExpressions exception: ' +
        (e instanceof Error ? e.message : String(e)));
      this.expressionErrorCode = 'EXPRESSION_LIST_QUERY_FAILED';
      this.expressionErrorMessage = e instanceof Error ? e.message : String(e);
    });
  }

  /**
   * Phase 3E-1: 刷新表情系统状态 (从 getExpressionState 解析)。
   */
  private refreshExpressionState(): void {
    this.arkWebController.getExpressionState().then((resultJson: string) => {
      const payload = parseExpressionState(resultJson);
      if (payload === null) {
        return;
      }
      this.expressionState = payload.state;
      this.expressionManagerReady = payload.expressionManagerReady;
      // 同步当前已应用表情 (模型替换后由 Web 端清空)
      this.appliedExpressionName = payload.currentExpressionName;
      this.appliedExpressionWeight = payload.currentExpressionWeight;
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] refreshExpressionState exception: ' +
        (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 3E-1: 点击"设置表情"按钮。
   *
   * 验证:
   *   - 模型 READY
   *   - 已选择真实存在的表情
   *   - 当前没有请求执行
   *
   * 参数序列化为 JSON 字符串后通过 Bridge 传给 Web,
   * 不向 JavaScript 传文件路径或模型内部对象。
   */
  private async onSetExpressionClick(): Promise<void> {
    if (this.expressionLoading) {
      return;
    }
    if (this.debugModelState !== 'READY') {
      this.expressionErrorCode = ArkWebExpressionErrorCode.VRM_MISSING;
      this.expressionErrorMessage = `模型未就绪 (state=${this.debugModelState})`;
      promptAction.showToast({ message: '模型未就绪' });
      return;
    }
    if (this.selectedExpressionName.length === 0) {
      this.expressionErrorCode = ArkWebExpressionErrorCode.NAME_INVALID;
      this.expressionErrorMessage = '未选择表情';
      promptAction.showToast({ message: '请先选择表情' });
      return;
    }
    if (!this.expressionManagerReady) {
      this.expressionErrorCode = ArkWebExpressionErrorCode.MANAGER_MISSING;
      this.expressionErrorMessage = 'Expression Manager 未就绪';
      promptAction.showToast({ message: 'Expression Manager 未就绪' });
      return;
    }

    this.expressionLoading = true;
    this.expressionErrorCode = '';
    this.expressionErrorMessage = '';
    try {
      const params: ArkWebSetExpressionParams = {
        name: this.selectedExpressionName,
        weight: this.selectedExpressionWeight
      };
      const paramsJson: string = JSON.stringify(params);
      console.info(`[ExpressionUI] onSetExpressionClick: name=${this.selectedExpressionName}, weight=${this.selectedExpressionWeight}`);
      const resultJson: string = await this.arkWebController.setExpression(paramsJson);
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] === true) {
        this.appliedExpressionName = this.selectedExpressionName;
        this.appliedExpressionWeight = this.selectedExpressionWeight;
        this.expressionState = (obj['state'] as string) || ArkWebExpressionState.APPLIED;
        promptAction.showToast({ message: `已设置表情: ${this.selectedExpressionName}` });
        // 刷新表情列表 (更新权重显示)
        this.refreshAvailableExpressions();
      } else {
        const errObj: Record<string, Object> = (obj['error'] as Record<string, Object>) ||
          {} as Record<string, Object>;
        this.expressionErrorCode = (errObj['code'] as string) || 'EXPRESSION_APPLY_FAILED';
        this.expressionErrorMessage = (errObj['message'] as string) || '';
        this.expressionState = ArkWebExpressionState.FAILED;
        promptAction.showToast({ message: `设置表情失败: ${this.expressionErrorCode}` });
        // 表情错误不改变 ViewerState / ModelState / AnimationState / PoseState
        // 仅刷新表情系统状态
        this.refreshExpressionState();
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.expressionErrorCode = 'EXPRESSION_SET_FAILED';
      this.expressionErrorMessage = msg;
      this.expressionState = ArkWebExpressionState.FAILED;
      promptAction.showToast({ message: `设置表情异常: ${msg}` });
    } finally {
      this.expressionLoading = false;
    }
  }

  /**
   * Phase 3E-1: 点击"清除表情"按钮。
   *
   * 验证:
   *   - 当前存在已应用表情
   *   - 当前没有请求执行
   *
   * 清除后 currentExpressionName = '', state = READY。
   * 不强制把 neutral 设置为 1。
   * 保留口型通道 aa/ee/ih/oh/ou (LIP_SYNC_CHANNELS_PRESERVED: YES)。
   */
  private async onResetExpressionClick(): Promise<void> {
    if (this.expressionLoading) {
      return;
    }
    if (this.appliedExpressionName.length === 0) {
      return;
    }

    this.expressionLoading = true;
    this.expressionErrorCode = '';
    this.expressionErrorMessage = '';
    try {
      console.info(`[ExpressionUI] onResetExpressionClick: clearing ${this.appliedExpressionName}`);
      const resultJson: string = await this.arkWebController.resetExpression();
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] === true) {
        this.appliedExpressionName = '';
        this.appliedExpressionWeight = 0;
        this.expressionState = (obj['state'] as string) || ArkWebExpressionState.READY;
        promptAction.showToast({ message: '已清除表情' });
        // 刷新表情列表 (更新权重显示)
        this.refreshAvailableExpressions();
      } else {
        const errObj: Record<string, Object> = (obj['error'] as Record<string, Object>) ||
          {} as Record<string, Object>;
        this.expressionErrorCode = (errObj['code'] as string) || 'EXPRESSION_RESET_FAILED';
        this.expressionErrorMessage = (errObj['message'] as string) || '';
        this.expressionState = ArkWebExpressionState.FAILED;
        promptAction.showToast({ message: `清除表情失败: ${this.expressionErrorCode}` });
        this.refreshExpressionState();
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.expressionErrorCode = 'EXPRESSION_RESET_FAILED';
      this.expressionErrorMessage = msg;
      this.expressionState = ArkWebExpressionState.FAILED;
      promptAction.showToast({ message: `清除表情异常: ${msg}` });
    } finally {
      this.expressionLoading = false;
    }
  }

  // ===== Phase 3E-2 — 表情别名映射与临时表情辅助方法 =====

  /**
   * Phase 3E-2: 模型 READY 后从 AssetLibrary 读取持久化别名映射。
   *
   * 仅恢复元数据,不自动设置任何表情。
   * 旧模型记录缺少 expressionAliases 字段时兼容为空对象。
   */
  private loadExpressionAliasMap(): void {
    if (this.assetLibrary === null) {
      console.warn('[ExpressionAlias] assetLibrary not initialized');
      return;
    }
    if (this.activeModelId.length === 0) {
      console.warn('[ExpressionAlias] activeModelId empty, skip load');
      return;
    }
    const lib: ArkWebAvatarAssetLibrary = this.assetLibrary;
    const modelId: string = this.activeModelId;
    lib.getExpressionAliases(modelId).then((aliases: Record<string, string>) => {
      const result: Record<string, string> = {};
      const keys: string[] = Object.keys(aliases);
      for (let i = 0; i < keys.length; i++) {
        const k: string = keys[i];
        if (ArkWebExpressionAliasBusinessId.isValid(k)) {
          const v: string = aliases[k];
          if (typeof v === 'string' && v.length > 0) {
            result[k] = v;
          }
        }
      }
      this.expressionAliasMap = result;
      this.expressionAliasErrorCode = '';
      this.expressionAliasErrorMessage = '';
      console.info(`[ExpressionAlias] loaded ${Object.keys(result).length} aliases for model=${modelId}`);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.expressionAliasMap = {};
      this.expressionAliasErrorCode = ExpressionAliasErrorCode.EXPRESSION_ALIAS_WRITE_FAILED;
      this.expressionAliasErrorMessage = `读取别名映射失败: ${msg}`;
      console.warn('[ExpressionAlias] loadExpressionAliasMap failed: ' + msg);
    });
  }

  /**
   * Phase 3E-2: 绑定一个真实 Expression 到固定业务 ID。
   *
   * 验证:
   *   - expressionId 属于固定业务 ID (neutral/happy/angry/sad/relaxed/surprised)
   *   - expressionName 非空
   *   - modelId 存在 (AssetLibrary 内部再次校验)
   *
   * 实际 Expression 是否存在由运行时再次验证 (setExpressionByAlias 会通过 resolveExpressionAlias 检查)。
   */
  private async saveExpressionAlias(expressionId: string, expressionName: string): Promise<void> {
    if (this.expressionAliasOperating) {
      return;
    }
    if (!ArkWebExpressionAliasBusinessId.isValid(expressionId)) {
      this.expressionAliasErrorCode = ExpressionAliasErrorCode.EXPRESSION_ALIAS_BUSINESS_ID_INVALID;
      this.expressionAliasErrorMessage = `非法业务 ID: ${expressionId}`;
      promptAction.showToast({ message: `非法业务 ID: ${expressionId}` });
      return;
    }
    if (typeof expressionName !== 'string' || expressionName.length === 0) {
      this.expressionAliasErrorCode = ExpressionAliasErrorCode.EXPRESSION_ALIAS_NAME_INVALID;
      this.expressionAliasErrorMessage = '表情名不能为空';
      promptAction.showToast({ message: '表情名不能为空' });
      return;
    }
    if (this.assetLibrary === null) {
      this.expressionAliasErrorCode = ExpressionAliasErrorCode.EXPRESSION_ALIAS_DISPOSED;
      this.expressionAliasErrorMessage = 'AssetLibrary 已释放';
      promptAction.showToast({ message: 'AssetLibrary 已释放' });
      return;
    }
    if (this.activeModelId.length === 0) {
      this.expressionAliasErrorCode = ExpressionAliasErrorCode.EXPRESSION_ALIAS_MODEL_NOT_FOUND;
      this.expressionAliasErrorMessage = '当前无活动模型';
      promptAction.showToast({ message: '当前无活动模型' });
      return;
    }

    this.expressionAliasOperating = true;
    this.expressionAliasErrorCode = '';
    this.expressionAliasErrorMessage = '';
    try {
      const ok: boolean = await this.assetLibrary.setExpressionAlias(
        this.activeModelId, expressionId, expressionName);
      if (ok) {
        const newMap: Record<string, string> = {};
        const keys: string[] = Object.keys(this.expressionAliasMap);
        for (let i = 0; i < keys.length; i++) {
          newMap[keys[i]] = this.expressionAliasMap[keys[i]];
        }
        newMap[expressionId] = expressionName;
        this.expressionAliasMap = newMap;
        promptAction.showToast({ message: `已绑定 ${expressionId} → ${expressionName}` });
      } else {
        this.expressionAliasErrorCode = ExpressionAliasErrorCode.EXPRESSION_ALIAS_WRITE_FAILED;
        this.expressionAliasErrorMessage = '写入持久化失败';
        promptAction.showToast({ message: '绑定失败' });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.expressionAliasErrorCode = ExpressionAliasErrorCode.EXPRESSION_ALIAS_WRITE_FAILED;
      this.expressionAliasErrorMessage = msg;
      promptAction.showToast({ message: `绑定异常: ${msg}` });
    } finally {
      this.expressionAliasOperating = false;
    }
  }

  /**
   * Phase 3E-2: 取消业务 ID 的映射。
   */
  private async clearExpressionAlias(expressionId: string): Promise<void> {
    if (this.expressionAliasOperating) {
      return;
    }
    if (!ArkWebExpressionAliasBusinessId.isValid(expressionId)) {
      return;
    }
    if (this.assetLibrary === null) {
      return;
    }
    if (this.activeModelId.length === 0) {
      return;
    }

    this.expressionAliasOperating = true;
    this.expressionAliasErrorCode = '';
    this.expressionAliasErrorMessage = '';
    try {
      const ok: boolean = await this.assetLibrary.clearExpressionAlias(this.activeModelId, expressionId);
      if (ok) {
        const newMap: Record<string, string> = {};
        const keys: string[] = Object.keys(this.expressionAliasMap);
        for (let i = 0; i < keys.length; i++) {
          if (keys[i] !== expressionId) {
            newMap[keys[i]] = this.expressionAliasMap[keys[i]];
          }
        }
        this.expressionAliasMap = newMap;
        promptAction.showToast({ message: `已取消 ${expressionId} 映射` });
      } else {
        this.expressionAliasErrorCode = ExpressionAliasErrorCode.EXPRESSION_ALIAS_WRITE_FAILED;
        this.expressionAliasErrorMessage = '取消映射失败';
        promptAction.showToast({ message: '取消映射失败' });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.expressionAliasErrorCode = ExpressionAliasErrorCode.EXPRESSION_ALIAS_WRITE_FAILED;
      this.expressionAliasErrorMessage = msg;
      promptAction.showToast({ message: `取消异常: ${msg}` });
    } finally {
      this.expressionAliasOperating = false;
    }
  }

  /**
   * Phase 3E-2: 播放临时表情。
   *
   * 通过 Bridge 调用 Web 端 setTemporaryExpression。
   * 流程: 保存当前表情 → 设置临时表情 → 创建单次 timeout → 到期检查 generation → 恢复或清除。
   *
   * 参数范围:
   *   - weight: 0..1
   *   - durationMs: 100..30000
   *   - restorePolicy: PREVIOUS / RESET
   */
  private async playTemporaryExpression(name: string, weight: number): Promise<void> {
    if (this.temporaryExpressionOperating) {
      return;
    }
    if (this.debugModelState !== 'READY') {
      this.temporaryExpressionErrorCode = 'TEMPORARY_VRM_MISSING';
      this.temporaryExpressionErrorMessage = `模型未就绪 (state=${this.debugModelState})`;
      promptAction.showToast({ message: '模型未就绪' });
      return;
    }
    if (!this.expressionManagerReady) {
      this.temporaryExpressionErrorCode = 'TEMPORARY_MANAGER_MISSING';
      this.temporaryExpressionErrorMessage = 'Expression Manager 未就绪';
      promptAction.showToast({ message: 'Expression Manager 未就绪' });
      return;
    }
    if (typeof name !== 'string' || name.length === 0) {
      this.temporaryExpressionErrorCode = 'TEMPORARY_NAME_INVALID';
      this.temporaryExpressionErrorMessage = '表情名为空';
      promptAction.showToast({ message: '请先选择表情' });
      return;
    }
    if (!ArkWebTemporaryRestorePolicy.isValid(this.temporaryExpressionRestorePolicy)) {
      this.temporaryExpressionErrorCode = 'TEMPORARY_POLICY_INVALID';
      this.temporaryExpressionErrorMessage = `非法恢复策略: ${this.temporaryExpressionRestorePolicy}`;
      promptAction.showToast({ message: '非法恢复策略' });
      return;
    }

    this.temporaryExpressionOperating = true;
    this.temporaryExpressionErrorCode = '';
    this.temporaryExpressionErrorMessage = '';
    try {
      const params: ArkWebSetTemporaryExpressionParams = {
        name: name,
        weight: weight,
        durationMs: this.temporaryExpressionDurationMs,
        restorePolicy: this.temporaryExpressionRestorePolicy
      };
      const paramsJson: string = JSON.stringify(params);
      console.info(`[TemporaryExpression] play: name=${name}, weight=${weight}, duration=${this.temporaryExpressionDurationMs}, policy=${this.temporaryExpressionRestorePolicy}`);
      const resultJson: string = await this.arkWebController.setTemporaryExpression(paramsJson);
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] === true) {
        this.temporaryExpressionName = (obj['temporaryExpressionName'] as string) || name;
        this.temporaryExpressionWeight = typeof obj['temporaryExpressionWeight'] === 'number'
          ? (obj['temporaryExpressionWeight'] as number) : weight;
        this.temporaryExpressionExpiresAt = typeof obj['expiresAt'] === 'number'
          ? (obj['expiresAt'] as number) : 0;
        this.temporaryExpressionTimerActive = this.temporaryExpressionExpiresAt > 0;
        this.temporaryExpressionGeneration++;
        promptAction.showToast({
          message: `临时表情: ${name} (${this.temporaryExpressionDurationMs}ms, ${this.temporaryExpressionRestorePolicy})`
        });
        this.refreshAvailableExpressions();
      } else {
        const errObj: Record<string, Object> = (obj['error'] as Record<string, Object>) ||
          {} as Record<string, Object>;
        this.temporaryExpressionErrorCode = (errObj['code'] as string) || 'TEMPORARY_SET_FAILED';
        this.temporaryExpressionErrorMessage = (errObj['message'] as string) || '';
        promptAction.showToast({ message: `临时表情失败: ${this.temporaryExpressionErrorCode}` });
        this.refreshTemporaryExpressionState();
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.temporaryExpressionErrorCode = 'TEMPORARY_SET_FAILED';
      this.temporaryExpressionErrorMessage = msg;
      promptAction.showToast({ message: `临时表情异常: ${msg}` });
    } finally {
      this.temporaryExpressionOperating = false;
    }
  }

  /**
   * Phase 3E-2: 取消临时表情。
   *
   * 取消后:
   *   - JS 端 clearTimeout 当前 timeout
   *   - temporaryGeneration++ 使任何在途 timeout 失效
   *   - 保留 restoreExpression* (调用方决定是否恢复)
   *   - 不自动恢复或清除业务表情 (由 cancelTemporaryExpression 内部决定)
   */
  private async cancelTemporaryExpressionClick(): Promise<void> {
    if (this.temporaryExpressionOperating) {
      return;
    }
    if (this.temporaryExpressionName.length === 0 && !this.temporaryExpressionTimerActive) {
      return;
    }

    this.temporaryExpressionOperating = true;
    this.temporaryExpressionErrorCode = '';
    this.temporaryExpressionErrorMessage = '';
    try {
      console.info('[TemporaryExpression] cancel');
      const resultJson: string = await this.arkWebController.cancelTemporaryExpression();
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] === true) {
        this.temporaryExpressionName = '';
        this.temporaryExpressionWeight = 0;
        this.temporaryExpressionExpiresAt = 0;
        this.temporaryExpressionTimerActive = false;
        this.temporaryExpressionGeneration++;
        promptAction.showToast({ message: '已取消临时表情' });
        this.refreshAvailableExpressions();
      } else {
        const errObj: Record<string, Object> = (obj['error'] as Record<string, Object>) ||
          {} as Record<string, Object>;
        this.temporaryExpressionErrorCode = (errObj['code'] as string) || 'TEMPORARY_CANCEL_FAILED';
        this.temporaryExpressionErrorMessage = (errObj['message'] as string) || '';
        promptAction.showToast({ message: `取消失败: ${this.temporaryExpressionErrorCode}` });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.temporaryExpressionErrorCode = 'TEMPORARY_CANCEL_FAILED';
      this.temporaryExpressionErrorMessage = msg;
      promptAction.showToast({ message: `取消异常: ${msg}` });
    } finally {
      this.temporaryExpressionOperating = false;
    }
  }

  /**
   * Phase 3E-2: 查询 Web 端临时表情状态 (供 UI 显示与测试验证)。
   */
  private refreshTemporaryExpressionState(): void {
    this.arkWebController.getTemporaryExpressionState().then((resultJson: string) => {
      const state: ArkWebTemporaryExpressionState | null = parseTemporaryExpressionState(resultJson);
      if (state === null) {
        return;
      }
      this.temporaryExpressionName = state.temporaryExpressionName;
      this.temporaryExpressionWeight = state.temporaryExpressionWeight;
      this.temporaryExpressionExpiresAt = state.temporaryExpiresAt;
      this.temporaryExpressionTimerActive = state.temporaryExpiresAt > 0;
      this.temporaryExpressionGeneration = state.temporaryGeneration;
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] refreshTemporaryExpressionState exception: ' +
        (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 3A 依赖补齐: 解析 getAnimationDependencyState 返回的 JSON,更新依赖状态。
   */
  private parseAnimationDependencyState(resultJson: string): void {
    try {
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] !== true) {
        return;
      }
      const depState = obj['dependencyState'] as Record<string, Object>;
      if (!depState) {
        return;
      }
      this.debugAnimationDependencyAvailable = depState['available'] === true;
      this.debugAnimationDependencyPackageName = (depState['packageName'] as string) || '';
      this.debugAnimationDependencyVersion = (depState['version'] as string) || '';
      this.debugAnimationLoaderAvailable = depState['loaderAvailable'] === true;
      this.debugAnimationClipFactoryAvailable = depState['clipFactoryAvailable'] === true;
      this.debugAnimationRuntimeNetworkRequired = depState['runtimeNetworkRequired'] === true;
    } catch (e) {
      console.warn('[VrmViewerPage] parseAnimationDependencyState parse failed: ' + (e instanceof Error ? e.message : String(e)));
    }
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
      this.debugAnimationResourceId = (debugState['resourceId'] as string) || '';
      this.debugAnimationLoadGeneration = (debugState['loadGeneration'] as number) || 0;
      this.debugAnimationErrorCode = (debugState['errorCode'] as string) || '';
      this.debugAnimationErrorMessage = (debugState['errorMessage'] as string) || '';
    } catch (e) {
      console.warn('[VrmViewerPage] parseAnimationDebugState failed: ' + (e instanceof Error ? e.message : String(e)));
    }
  }

  // ===== Phase 3A — VRMA 文件导入与最小播放闭环 =====

  /**
   * Phase 3C-1: 用户点击"选择 VRMA"按钮。
   *
   * 流程 (AGENTS.md Phase 3C-1 §六):
   * 1. 选择 .vrma (DocumentViewPicker, 仅 .vrma 后缀)
   * 2. 持久复制到 <filesDir>/avatar-assets/animations/<actionId>.vrma.part → rename
   * 3. 向 library.animations 追加记录 (不覆盖已有动作)
   * 4. 刷新动作列表
   * 5. 自动选择新动作
   * 6. 注册 Animation Provider (registerPersistentAsset)
   * 7. 调用现有 loadAnimationResource()
   * 8. 启动轮询
   *
   * 加载中禁用选择/播放/暂停/停止。
   * 失败保留其他动作记录,显示具体错误码。
   */
  private async onAnimationImportButton(): Promise<void> {
    if (this.animationImportController === null) {
      promptAction.showToast({ message: '动画导入控制器未初始化' });
      return;
    }
    if (this.animationResourceProvider === null) {
      promptAction.showToast({ message: '动画资源 Provider 未初始化' });
      return;
    }
    if (this.persistentAnimationStore === null) {
      promptAction.showToast({ message: '动画持久存储未初始化' });
      return;
    }
    // Viewer 必须 READY (Bridge 可用)
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: 'Viewer 尚未就绪' });
      return;
    }
    // 动画加载中禁止重复选择
    if (this.debugAnimationState === 'LOADING') {
      promptAction.showToast({ message: '动画加载中,请稍候' });
      return;
    }

    this.animationImportState = AnimationImportState.PICKING;
    this.animationImportError = '';
    this.animationActionError = '';
    this.animationLibraryErrorCode = '';
    this.animationLibraryErrorMessage = '';

    try {
      // 1. 选择 .vrma
      const file: ImportedAnimationFile | null =
        await this.animationImportController.pickAnimationFile();
      this.animationImportState = this.animationImportController.getState();
      this.animationImportError = this.animationImportController.getLastError();

      if (file === null) {
        // 用户取消或失败
        if (this.animationImportState === AnimationImportState.CANCELLED) {
          promptAction.showToast({ message: '已取消选择' });
        } else if (this.animationImportState === AnimationImportState.FAILED) {
          promptAction.showToast({ message: `导入失败: ${this.animationImportError}` });
        }
        // 恢复到 IDLE 以便再次选择
        if (this.animationImportState !== AnimationImportState.READY) {
          this.animationImportState = AnimationImportState.IDLE;
        }
        return;
      }

      // 2. 持久化到 filesDir/avatar-assets/animations/<actionId>.vrma
      const asset: ArkWebAvatarAnimationAsset | null =
        await this.persistentAnimationStore.importAnimation(
          file.sourceUri, file.displayName, file.extension
        );
      if (asset === null) {
        this.animationImportError = this.persistentAnimationStore.getLastError();
        this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_LIBRARY_WRITE_FAILED;
        this.animationLibraryErrorMessage = this.animationImportError;
        this.animationImportState = AnimationImportState.FAILED;
        promptAction.showToast({ message: `持久化失败: ${this.animationImportError}` });
        return;
      }

      // 3. 刷新动作列表
      await this.loadAnimationAssetsFromLibrary();

      // 4. 自动选择新动作 + 加载
      const loaded: boolean = await this.loadAnimationByActionId(asset.actionId);
      if (!loaded) {
        // 加载失败: 保留持久资产记录,显示错误码
        this.animationImportState = AnimationImportState.FAILED;
        promptAction.showToast({
          message: `动作已保存但加载失败: ${this.animationLibraryErrorMessage}`
        });
        return;
      }

      // 5. 加载已启动
      this.animationImportState = AnimationImportState.READY;
      this.animationActionError = '';
      this.refreshAnimationDebugState();
      this.startAnimationLoadPolling();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.animationImportError = `导入异常: ${msg}`;
      this.animationImportState = AnimationImportState.FAILED;
      promptAction.showToast({ message: this.animationImportError });
    }
  }

  // ===== Phase 3C-1 — 多 VRMA 持久化与动作列表 =====

  /**
   * Phase 3C-1: 从 library.json 读取 animations 数组,刷新动作列表。
   *
   * 仅恢复元数据,不在启动时解析所有 VRMA。
   * 失败时不清空已有列表 (保留上次状态)。
   *
   * Phase 3C-2: 同时读取 defaultIdleActionId (仅元数据, 不自动加载/播放)。
   */
  private async loadAnimationAssetsFromLibrary(): Promise<void> {
    if (this.assetLibrary === null) {
      return;
    }
    try {
      const animations: ArkWebAvatarAnimationAsset[] = await this.assetLibrary.readAnimations();
      this.animationAssets = animations;
      // 同步默认待机标记 (仅元数据, 不触发加载)
      this.defaultIdleActionId = await this.assetLibrary.getDefaultIdleActionId();
      console.info(`[VrmViewerPage] loaded ${animations.length} animation assets from library`);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] loadAnimationAssetsFromLibrary failed: ${msg}`);
    }
  }

  // ===== Phase 3D-1 — JSON 姿势导入与持久化姿势库 =====

  /**
   * Phase 3D-1: 从 library.json 读取 poses 数组, 刷新姿势列表。
   *
   * 仅恢复元数据, 不在启动时解析姿势 JSON 内容。
   * 不自动选中 poseId, 不自动应用姿势到模型骨骼。
   * 失败时不清空已有列表 (保留上次状态)。
   *
   * Phase 3D-3: 同时读取 defaultPoseId (仅元数据, 不自动应用)。
   */
  private async loadPoseAssetsFromLibrary(): Promise<void> {
    if (this.assetLibrary === null) {
      return;
    }
    try {
      const poses: ArkWebAvatarPoseAsset[] = await this.assetLibrary.readPoses();
      this.poseAssets = poses;
      // Phase 3D-3: 同步默认姿势标记 (仅元数据, 不触发自动应用, 由模型 READY 回调统一编排)
      this.defaultPoseId = await this.assetLibrary.getDefaultPoseId();
      this.refreshDefaultPoseDisplayName();
      console.info(`[VrmViewerPage] loaded ${poses.length} pose assets from library, defaultPoseId=${this.defaultPoseId}`);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] loadPoseAssetsFromLibrary failed: ${msg}`);
    }
  }

  /**
   * Phase 3D-3: 根据 defaultPoseId 从 poseAssets 匹配显示名。
   * 无匹配时清空显示名。
   */
  private refreshDefaultPoseDisplayName(): void {
    if (this.defaultPoseId.length === 0) {
      this.defaultPoseDisplayName = '';
      return;
    }
    let found: boolean = false;
    for (let i = 0; i < this.poseAssets.length; i++) {
      if (this.poseAssets[i].poseId === this.defaultPoseId) {
        this.defaultPoseDisplayName = this.poseAssets[i].displayName;
        found = true;
        break;
      }
    }
    if (!found) {
      this.defaultPoseDisplayName = '';
    }
  }

  /**
   * Phase 3D-1: 点击 "导入姿势" 按钮处理。
   *
   * 调用 Picker 选择 .json 文件, 由 PersistentPoseStore 完成持久化与 JSON 结构验证。
   * 成功后刷新姿势列表 (不自动选中, 不自动应用)。
   */
  private async onPoseImportButton(): Promise<void> {
    if (this.poseImportController === null || this.persistentPoseStore === null) {
      this.poseLibraryErrorCode = PoseImportErrorCode.POSE_IMPORT_FILENAME_INVALID;
      this.poseLibraryErrorMessage = '姿势导入控制器未初始化';
      promptAction.showToast({ message: this.poseLibraryErrorMessage });
      return;
    }
    this.poseImporting = true;
    this.poseLibraryErrorCode = '';
    this.poseLibraryErrorMessage = '';
    try {
      const asset: ArkWebAvatarPoseAsset | null =
        await this.poseImportController.pickAndImportPose(this.persistentPoseStore);
      if (asset === null) {
        const state: PoseImportState = this.poseImportController.getState();
        if (state === PoseImportState.CANCELLED) {
          // 用户取消, 非错误
          this.poseLibraryErrorCode = '';
          this.poseLibraryErrorMessage = '';
        } else {
          this.poseLibraryErrorCode = this.poseImportController.getLastError();
          this.poseLibraryErrorMessage = `姿势导入失败: ${this.poseLibraryErrorCode}`;
          promptAction.showToast({ message: this.poseLibraryErrorMessage });
        }
      } else {
        this.poseLibraryErrorCode = '';
        this.poseLibraryErrorMessage = '';
        promptAction.showToast({ message: '姿势已导入' });
        await this.loadPoseAssetsFromLibrary();
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.poseLibraryErrorCode = PersistentPoseErrorCode.POSE_LIBRARY_WRITE_FAILED;
      this.poseLibraryErrorMessage = `姿势导入异常: ${msg}`;
      promptAction.showToast({ message: this.poseLibraryErrorMessage });
    } finally {
      this.poseImporting = false;
    }
  }

  /**
   * Phase 3D-1: 点击姿势列表项处理。
   *
   * Phase 3D-2: 仍仅更新 selectedPoseId, 不直接应用姿势。
   * 用户需点击"应用姿势"按钮才会触发实际应用。
   */
  private onPoseListItemClick(poseId: string): void {
    if (poseId.length === 0) {
      return;
    }
    this.selectedPoseId = poseId;
  }

  /**
   * Phase 3D-2: 点击"应用姿势"按钮处理。
   *
   * 启用条件:
   *   - selectedPoseId 非空
   *   - 模型 READY (debugModelState === 'READY')
   *   - 当前没有姿势导入任务 (!poseImporting)
   *   - 当前没有姿势应用任务 (!poseApplying)
   *
   * 流程:
   *   1. 停止当前动画 (Web 端 applyPose 内部会调用 stopAnimation)
   *   2. 从 PersistentPoseStore 读取姿势 JSON 文件,构造受控 ArkWebPoseData
   *   3. 调用 Controller.applyPose(poseJson)
   *   4. 解析返回结果,更新 appliedPoseId / poseSystemState / 计数 / 错误
   *   5. 显示实际成功或错误码
   */
  private async onApplyPoseClick(): Promise<void> {
    if (this.selectedPoseId.length === 0) {
      this.poseLastErrorCode = 'POSE_NO_SELECTION';
      this.poseLastErrorMessage = '请先选择一个姿势';
      promptAction.showToast({ message: '请先选择一个姿势' });
      return;
    }
    if (this.poseImporting) {
      this.poseLastErrorCode = 'POSE_IMPORT_IN_PROGRESS';
      this.poseLastErrorMessage = '姿势导入进行中,请稍后';
      promptAction.showToast({ message: '姿势导入进行中,请稍后' });
      return;
    }
    if (this.poseApplying) {
      this.poseLastErrorCode = 'POSE_APPLY_IN_PROGRESS';
      this.poseLastErrorMessage = '姿势应用进行中,请稍后';
      promptAction.showToast({ message: '姿势应用进行中,请稍后' });
      return;
    }
    if (this.arkWebController === null) {
      this.poseLastErrorCode = 'POSE_VIEWER_CONTROLLER_NULL';
      this.poseLastErrorMessage = 'Viewer 控制器未初始化';
      promptAction.showToast({ message: this.poseLastErrorMessage });
      return;
    }
    if (this.persistentPoseStore === null) {
      this.poseLastErrorCode = 'POSE_STORE_NULL';
      this.poseLastErrorMessage = '姿势存储未初始化';
      promptAction.showToast({ message: this.poseLastErrorMessage });
      return;
    }
    if (this.debugModelState !== 'READY') {
      this.poseLastErrorCode = 'POSE_MODEL_NOT_READY';
      this.poseLastErrorMessage = `模型未就绪 (state=${this.debugModelState})`;
      promptAction.showToast({ message: this.poseLastErrorMessage });
      return;
    }

    this.poseApplying = true;
    this.poseLastErrorCode = '';
    this.poseLastErrorMessage = '';
    try {
      // 1. 从持久存储读取姿势 JSON,构造受控 ArkWebPoseData
      console.warn(`[PoseUI] onApplyPoseClick: poseId=${this.selectedPoseId}, modelState=${this.debugModelState}`);
      const poseJson: string = await this.persistentPoseStore.readPoseDataAsJson(this.selectedPoseId);
      console.warn(`[PoseUI] onApplyPoseClick: poseJson length=${poseJson.length}, lastError=${this.persistentPoseStore.getLastError()}`);
      if (poseJson.length === 0) {
        this.poseLastErrorCode = this.persistentPoseStore.getLastError() || 'POSE_READ_FAILED';
        this.poseLastErrorMessage = `读取姿势失败: ${this.poseLastErrorCode}`;
        this.poseSystemState = 'FAILED';
        promptAction.showToast({ message: this.poseLastErrorMessage });
        return;
      }

      // 2. 调用 Controller.applyPose (Web 端会先 stopAnimation 再 resetNormalizedPose + 应用)
      console.warn(`[PoseUI] onApplyPoseClick: calling arkWebController.applyPose`);
      const resultJson: string = await this.arkWebController.applyPose(poseJson);
      console.warn(`[PoseUI] onApplyPoseClick: applyPose result length=${resultJson.length}`);
      const resultObj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const success: boolean = !!resultObj['success'];
      if (success) {
        this.appliedPoseId = (resultObj['poseId'] as string) || this.selectedPoseId;
        this.appliedPoseDisplayName = (resultObj['displayName'] as string) || '';
        this.poseSystemState = (resultObj['state'] as string) || 'APPLIED';
        this.poseAppliedBoneCount = (resultObj['appliedBoneCount'] as number) || 0;
        this.poseIgnoredBoneCount = (resultObj['ignoredBoneCount'] as number) || 0;
        this.poseLastErrorCode = '';
        this.poseLastErrorMessage = '';
        promptAction.showToast({
          message: `姿势已应用: ${this.appliedPoseDisplayName} (有效 ${this.poseAppliedBoneCount} 骨骼, 忽略 ${this.poseIgnoredBoneCount})`
        });
      } else {
        const errObj: Record<string, Object> = (resultObj['error'] as Record<string, Object>) || {} as Record<string, Object>;
        this.poseLastErrorCode = (errObj['code'] as string) || 'POSE_APPLY_FAILED';
        this.poseLastErrorMessage = (errObj['message'] as string) || '姿势应用失败';
        this.poseSystemState = 'FAILED';
        promptAction.showToast({ message: `姿势应用失败: ${this.poseLastErrorCode}` });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.poseLastErrorCode = 'POSE_APPLY_EXCEPTION';
      this.poseLastErrorMessage = `姿势应用异常: ${msg}`;
      this.poseSystemState = 'FAILED';
      promptAction.showToast({ message: this.poseLastErrorMessage });
    } finally {
      this.poseApplying = false;
    }
  }

  /**
   * Phase 3D-2: 点击"恢复姿势"按钮处理。
   *
   * 流程:
   *   1. 调用 Controller.resetPose() (Web 端会 resetNormalizedPose + 清空 currentPoseId)
   *   2. 解析返回结果,更新 appliedPoseId / poseSystemState
   *   3. 显示实际成功或错误码
   *
   * 恢复失败不影响 ViewerState / ModelState / AnimationState。
   */
  private async onResetPoseClick(): Promise<void> {
    if (this.poseApplying) {
      this.poseLastErrorCode = 'POSE_APPLY_IN_PROGRESS';
      this.poseLastErrorMessage = '姿势应用进行中,请稍后';
      promptAction.showToast({ message: '姿势应用进行中,请稍后' });
      return;
    }
    if (this.arkWebController === null) {
      this.poseLastErrorCode = 'POSE_VIEWER_CONTROLLER_NULL';
      this.poseLastErrorMessage = 'Viewer 控制器未初始化';
      promptAction.showToast({ message: this.poseLastErrorMessage });
      return;
    }
    if (this.debugModelState !== 'READY') {
      this.poseLastErrorCode = 'POSE_MODEL_NOT_READY';
      this.poseLastErrorMessage = `模型未就绪 (state=${this.debugModelState})`;
      promptAction.showToast({ message: this.poseLastErrorMessage });
      return;
    }

    try {
      const resultJson: string = await this.arkWebController.resetPose();
      const resultObj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const success: boolean = !!resultObj['success'];
      if (success) {
        this.appliedPoseId = '';
        this.appliedPoseDisplayName = '';
        this.poseSystemState = (resultObj['state'] as string) || 'IDLE';
        this.poseAppliedBoneCount = 0;
        this.poseIgnoredBoneCount = 0;
        this.poseLastErrorCode = '';
        this.poseLastErrorMessage = '';
        promptAction.showToast({ message: '已恢复标准姿势' });
      } else {
        const errObj: Record<string, Object> = (resultObj['error'] as Record<string, Object>) || {} as Record<string, Object>;
        this.poseLastErrorCode = (errObj['code'] as string) || 'POSE_RESET_FAILED';
        this.poseLastErrorMessage = (errObj['message'] as string) || '姿势恢复失败';
        promptAction.showToast({ message: `姿势恢复失败: ${this.poseLastErrorCode}` });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.poseLastErrorCode = 'POSE_RESET_EXCEPTION';
      this.poseLastErrorMessage = `姿势恢复异常: ${msg}`;
      promptAction.showToast({ message: this.poseLastErrorMessage });
    }
  }

  // ===== Phase 3D-3 — 默认姿势与模型加载后自动恢复 =====

  /**
   * Phase 3D-3: 设为默认姿势 / 取消默认姿势。
   *
   * - 当前已是默认: 点击取消 (传入空字符串)
   * - 当前不是默认: 点击设为默认
   *
   * 仅保存元数据, 不强制立即应用姿势。
   * 用户可以再点击"应用姿势"按钮测试效果。
   */
  private async onPoseToggleDefaultButton(poseId: string): Promise<void> {
    if (poseId.length === 0) {
      return;
    }
    if (this.assetLibrary === null) {
      this.poseLibraryErrorCode = PersistentPoseErrorCode.POSE_STORE_LIBRARY_INVALID;
      this.poseLibraryErrorMessage = '资产库未初始化';
      promptAction.showToast({ message: '资产库未初始化' });
      return;
    }
    // 已是默认 → 取消; 否则 → 设为默认
    const target: string = this.defaultPoseId === poseId ? '' : poseId;
    const ok: boolean = await this.assetLibrary.setDefaultPose(target);
    if (!ok) {
      this.poseLibraryErrorCode = DefaultPoseErrorCode.POSE_DEFAULT_WRITE_FAILED;
      this.poseLibraryErrorMessage = '默认姿势标记更新失败 (清单写入失败)';
      promptAction.showToast({ message: '设置失败' });
      return;
    }
    this.defaultPoseId = target;
    this.refreshDefaultPoseDisplayName();
    promptAction.showToast({
      message: target.length > 0 ? '已设为默认姿势' : '已取消默认姿势'
    });
  }

  /**
   * Phase 3D-3: 模型 READY 后调度默认姿势自动恢复。
   *
   * 只在以下条件全部成立后执行:
   *   - 页面未销毁
   *   - Viewer READY
   *   - ModelState READY
   *   - active model 已完成加载
   *   - AssetLibrary READY
   *   - defaultPoseId 非空
   *   - 对应姿势记录存在
   *   - 当前没有姿势导入或姿势应用任务
   *
   * 同一模型 generation 最多自动应用一次。
   * 重复 READY 回调不得重复应用。
   * 模型替换或重新加载: generation++ 允许对新模型重新应用一次默认姿势。
   *
   * 失败策略: 不修改 ViewerState / ModelState, 不进入无限重试,
   * 不反复弹出 Toast, 只显示一次非阻塞提示并写入 Debug。
   */
  private async scheduleDefaultPoseRestore(): Promise<void> {
    // 1. 页面未销毁
    if (this.defaultPoseRestoreDisposed) {
      console.info('[VrmViewerPage] scheduleDefaultPoseRestore: disposed, skip');
      return;
    }
    // 2. Viewer READY
    if (this.viewerState !== ArkWebViewerState.READY) {
      console.info(`[VrmViewerPage] scheduleDefaultPoseRestore: viewer not ready (${this.viewerState}), skip`);
      return;
    }
    // 3. ModelState READY
    if (this.debugModelState !== 'READY') {
      console.info(`[VrmViewerPage] scheduleDefaultPoseRestore: model not ready (${this.debugModelState}), skip`);
      return;
    }
    // 4. active model 已完成加载 (loadState === 'READY')
    if (this.loadState !== 'READY') {
      console.info(`[VrmViewerPage] scheduleDefaultPoseRestore: loadState=${this.loadState}, skip`);
      return;
    }
    // 5. AssetLibrary READY
    if (this.assetLibrary === null || this.assetLibrary.isDisposed()) {
      console.info('[VrmViewerPage] scheduleDefaultPoseRestore: assetLibrary null, skip');
      return;
    }
    // 6. 当前没有姿势导入或姿势应用任务
    if (this.poseImporting || this.poseApplying) {
      console.info(`[VrmViewerPage] scheduleDefaultPoseRestore: poseImporting=${this.poseImporting}, poseApplying=${this.poseApplying}, skip`);
      return;
    }
    // 7. 并发保护
    if (this.defaultPoseRestoreInProgress) {
      console.info('[VrmViewerPage] scheduleDefaultPoseRestore: in progress, skip');
      return;
    }
    // 8. 同一模型 generation 最多自动应用一次
    const currentModelGen: number = this.modelRestoreGeneration;
    if (this.defaultPoseRestoreModelGeneration === currentModelGen
        && this.lastRestoredDefaultPoseId.length > 0) {
      console.info(`[VrmViewerPage] scheduleDefaultPoseRestore: already restored for modelGen=${currentModelGen}, skip`);
      return;
    }

    this.defaultPoseRestoreInProgress = true;
    this.defaultPoseRestoreGeneration++;
    const generation: number = this.defaultPoseRestoreGeneration;
    this.defaultPoseRestoreState = DefaultPoseRestoreState.WAITING_MODEL;
    this.defaultPoseRestoreErrorCode = '';
    this.defaultPoseRestoreErrorMessage = '';

    try {
      // 读取 defaultPoseId
      const poseId: string = await this.assetLibrary.getDefaultPoseId();
      if (generation !== this.defaultPoseRestoreGeneration || this.defaultPoseRestoreDisposed) {
        this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_RESTORE_STALE, 'stale generation before read poseId');
        return;
      }
      // defaultPoseId 为空: 进入 EMPTY 状态 (非错误)
      if (poseId.length === 0) {
        this.defaultPoseRestoreState = DefaultPoseRestoreState.EMPTY;
        console.info('[VrmViewerPage] scheduleDefaultPoseRestore: defaultPoseId empty, EMPTY state');
        return;
      }
      // 同步 @State (确保 UI 显示与持久数据一致)
      this.defaultPoseId = poseId;

      // 验证对应姿势记录存在
      const poseAsset: ArkWebAvatarPoseAsset | null = await this.assetLibrary.findPose(poseId);
      if (generation !== this.defaultPoseRestoreGeneration || this.defaultPoseRestoreDisposed) {
        this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_RESTORE_STALE, 'stale generation before findPose');
        return;
      }
      if (poseAsset === null) {
        this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_NOT_FOUND, `poseId not found: ${poseId}`);
        return;
      }

      // 读取并转换持久姿势 JSON
      this.defaultPoseRestoreState = DefaultPoseRestoreState.LOADING;
      if (this.persistentPoseStore === null) {
        this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_PARSE_FAILED, 'persistentPoseStore null');
        return;
      }
      const poseJson: string = await this.persistentPoseStore.readPoseDataAsJson(poseId);
      if (generation !== this.defaultPoseRestoreGeneration || this.defaultPoseRestoreDisposed) {
        this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_RESTORE_STALE, 'stale generation before readPoseDataAsJson');
        return;
      }
      if (poseJson.length === 0) {
        const storeErr: string = this.persistentPoseStore.getLastError();
        // 区分文件不存在和解析失败
        if (storeErr.indexOf('not found') >= 0 || storeErr.indexOf('POSE_JSON_PARSE_FAILED') >= 0) {
          this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_PARSE_FAILED, `parse failed: ${storeErr}`);
        } else {
          this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_FILE_MISSING, `read failed: ${storeErr}`);
        }
        return;
      }

      // 调用现有 viewerController.applyPose
      this.defaultPoseRestoreState = DefaultPoseRestoreState.APPLYING;
      if (this.arkWebController === null) {
        this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_APPLY_FAILED, 'arkWebController null');
        return;
      }
      const resultJson: string = await this.arkWebController.applyPose(poseJson);
      if (generation !== this.defaultPoseRestoreGeneration || this.defaultPoseRestoreDisposed) {
        this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_RESTORE_STALE, 'stale generation before applyPose result');
        return;
      }
      const resultObj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const success: boolean = !!resultObj['success'];
      if (!success) {
        const errObj: Record<string, Object> = (resultObj['error'] as Record<string, Object>) || {} as Record<string, Object>;
        const errCode: string = (errObj['code'] as string) || '';
        const errMsg: string = (errObj['message'] as string) || 'applyPose failed';
        this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_APPLY_FAILED, `${errCode}: ${errMsg}`);
        return;
      }

      // 成功: 更新当前姿势状态 (与手动应用保持一致)
      this.appliedPoseId = (resultObj['poseId'] as string) || poseId;
      this.appliedPoseDisplayName = (resultObj['displayName'] as string) || poseAsset.displayName;
      this.poseSystemState = (resultObj['state'] as string) || 'APPLIED';
      this.poseAppliedBoneCount = (resultObj['appliedBoneCount'] as number) || 0;
      this.poseIgnoredBoneCount = (resultObj['ignoredBoneCount'] as number) || 0;
      this.poseLastErrorCode = '';
      this.poseLastErrorMessage = '';
      this.defaultPoseRestoreState = DefaultPoseRestoreState.READY;
      this.defaultPoseRestoreModelGeneration = currentModelGen;
      this.lastRestoredDefaultPoseId = poseId;
      console.info(`[VrmViewerPage] scheduleDefaultPoseRestore ok: poseId=${poseId}, modelGen=${currentModelGen}`);
      // 非阻塞提示 (只显示一次)
      promptAction.showToast({
        message: `已自动应用默认姿势: ${this.appliedPoseDisplayName}`
      });
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.failDefaultPoseRestore(DefaultPoseErrorCode.POSE_DEFAULT_APPLY_FAILED, `exception: ${msg}`);
    } finally {
      this.defaultPoseRestoreInProgress = false;
    }
  }

  /**
   * Phase 3D-3: 默认姿势恢复失败处理。
   *
   * 策略:
   * - 不修改 ViewerState / ModelState
   * - 不进入无限重试
   * - 不反复弹出 Toast (同一错误只显示一次)
   * - 保留手动选择和应用姿势功能
   * - 写入 Debug 状态供 UI 显示
   */
  private failDefaultPoseRestore(code: string, message: string): void {
    this.defaultPoseRestoreState = DefaultPoseRestoreState.FAILED;
    this.defaultPoseRestoreErrorCode = code;
    this.defaultPoseRestoreErrorMessage = message;
    console.warn(`[VrmViewerPage] defaultPoseRestore failed: ${code} ${message}`);
    // 非阻塞提示 (只显示一次)
    promptAction.showToast({
      message: `默认姿势恢复失败: ${code}`
    });
  }

  /**
   * Phase 3D-1: 格式化姿势字节大小为可读字符串。
   */
  private formatPoseByteLength(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    const KB: number = 1024;
    const MB: number = KB * 1024;
    if (bytes >= MB) {
      return `${(bytes / MB).toFixed(2)} MB`;
    }
    if (bytes >= KB) {
      return `${(bytes / KB).toFixed(2)} KB`;
    }
    return `${bytes} B`;
  }

  /**
   * Phase 3C-1: 根据 actionId 加载持久化动画到现有 AnimationController。
   *
   * 流程:
   * 1. 校验状态 (Viewer READY / Store / Provider 可用)
   * 2. 从 library 查找 actionId 对应资产
   * 3. 解析绝对路径 (filesDir + relativePath)
   * 4. 注册到 Provider (registerPersistentAsset)
   * 5. 调用 Bridge loadAnimationResource
   * 6. 更新 selectedActionId
   *
   * 不自动播放 (用户需手动点击播放按钮)。
   *
   * @returns 成功返回 true; 失败返回 false (错误信息写入 animationLibraryErrorMessage)
   */
  private async loadAnimationByActionId(actionId: string): Promise<boolean> {
    if (actionId.length === 0) {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_STORE_DISPOSED;
      this.animationLibraryErrorMessage = 'actionId 为空';
      return false;
    }
    if (this.assetLibrary === null || this.persistentAnimationStore === null
        || this.animationResourceProvider === null) {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_STORE_LIBRARY_INVALID;
      this.animationLibraryErrorMessage = '动画库/存储/Provider 未初始化';
      return false;
    }
    if (this.viewerState !== ArkWebViewerState.READY) {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_STORE_DISPOSED;
      this.animationLibraryErrorMessage = 'Viewer 未 READY';
      return false;
    }
    if (this.debugAnimationState === 'LOADING') {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_STORE_DISPOSED;
      this.animationLibraryErrorMessage = '动画加载中,请稍候';
      return false;
    }

    // 1. 查找资产
    const asset: ArkWebAvatarAnimationAsset | null =
      await this.assetLibrary.findAnimation(actionId);
    if (asset === null) {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_STORE_LIBRARY_INVALID;
      this.animationLibraryErrorMessage = `未找到动作: ${actionId}`;
      return false;
    }

    // 2. 解析绝对路径
    const absolutePath: string = this.persistentAnimationStore.resolveAbsolutePath(asset.relativePath);
    if (absolutePath.length === 0) {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_STORE_LIBRARY_INVALID;
      this.animationLibraryErrorMessage = `路径不安全: ${asset.relativePath}`;
      return false;
    }

    // 3. 注册到 Provider
    let publicResource: WebAnimationResource;
    try {
      publicResource = this.animationResourceProvider.registerPersistentAsset(asset, absolutePath);
      this.animationResourceState = this.animationResourceProvider.getState();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_RENAME_FAILED;
      this.animationLibraryErrorMessage = `Provider 注册失败: ${msg}`;
      return false;
    }

    // 4. 调用 Bridge loadAnimationResource
    const resourceJsonObj: AnimationResourceBridgePayload = {
      resourceUrl: publicResource.resourceUrl,
      resourceId: publicResource.resourceId,
      displayName: publicResource.displayName,
      mimeType: publicResource.mimeType,
      size: publicResource.size
    };
    const resourceJson: string = JSON.stringify(resourceJsonObj);

    const resultJson: string = await this.arkWebController.loadAnimationResource(resourceJson);
    const parsed: Record<string, Object> | null = this.parseAnimationLoadResponse(resultJson);
    if (parsed === null) {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_LIBRARY_WRITE_FAILED;
      this.animationLibraryErrorMessage = 'loadAnimationResource 返回非法 JSON';
      return false;
    }
    if (parsed['success'] !== true) {
      const errObj = parsed['error'] as Record<string, Object>;
      const errorCode: string = errObj ? (errObj['code'] as string) || 'UNKNOWN' : 'UNKNOWN';
      const msg: string = errObj ? (errObj['message'] as string) || '' : '';
      this.animationLibraryErrorCode = errorCode;
      this.animationLibraryErrorMessage = `加载启动失败: ${errorCode}${msg.length > 0 ? ' - ' + msg : ''}`;
      return false;
    }

    // 5. 更新选中状态
    this.selectedActionId = actionId;
    this.animationLibraryErrorCode = '';
    this.animationLibraryErrorMessage = '';
    console.info(`[VrmViewerPage] loadAnimationByActionId ok: ${actionId}`);
    return true;
  }

  /**
   * Phase 3C-1: 用户点击动作列表项时触发。
   */
  private async onAnimationListItemClick(actionId: string): Promise<void> {
    if (actionId.length === 0) {
      return;
    }
    if (this.debugAnimationState === 'LOADING') {
      promptAction.showToast({ message: '动画加载中,请稍候' });
      return;
    }
    if (this.selectedActionId === actionId && this.debugAnimationState === 'READY') {
      // 已选中且已加载,不重复加载
      return;
    }

    const loaded: boolean = await this.loadAnimationByActionId(actionId);
    if (!loaded) {
      promptAction.showToast({
        message: `加载失败: ${this.animationLibraryErrorMessage}`
      });
      return;
    }
    this.refreshAnimationDebugState();
    this.startAnimationLoadPolling();
  }

  // ===== Phase 3C-2 — 动作重命名 / 删除 / 默认待机标记 =====

  /**
   * Phase 3C-2: 打开重命名对话框。
   */
  private onAnimationRenameButton(actionId: string, currentName: string): void {
    if (actionId.length === 0) {
      return;
    }
    this.pendingRenameActionId = actionId;
    this.pendingRenameDisplayName = currentName;
    this.animationRenameDialogVisible = true;
  }

  /**
   * Phase 3C-2: 取消重命名对话框。
   */
  private onAnimationRenameCancel(): void {
    this.animationRenameDialogVisible = false;
    this.pendingRenameActionId = '';
    this.pendingRenameDisplayName = '';
  }

  /**
   * Phase 3C-2: 确认重命名 (trim 后非空, 长度 <= 64)。
   *
   * 保持 actionId / resourceId / relativePath / 文件名不变, 只修改 displayName + updatedAt。
   */
  private async onAnimationRenameConfirm(): Promise<void> {
    const actionId: string = this.pendingRenameActionId;
    const newName: string = this.pendingRenameDisplayName.trim();
    if (actionId.length === 0) {
      return;
    }
    if (newName.length === 0 || newName.length > 64) {
      this.animationLibraryErrorCode = AnimationManagementErrorCode.ANIMATION_RENAME_NAME_INVALID;
      this.animationLibraryErrorMessage = '名称无效 (trim 后非空, 长度不超过 64)';
      promptAction.showToast({ message: '名称无效' });
      return;
    }
    if (this.assetLibrary === null) {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_STORE_LIBRARY_INVALID;
      this.animationLibraryErrorMessage = '资产库未初始化';
      promptAction.showToast({ message: '资产库未初始化' });
      return;
    }
    const updatedAsset: ArkWebAvatarAnimationAsset | null =
      await this.assetLibrary.renameAnimation(actionId, newName);
    if (updatedAsset === null) {
      this.animationLibraryErrorCode = AnimationManagementErrorCode.ANIMATION_RENAME_NAME_INVALID;
      this.animationLibraryErrorMessage = '重命名失败 (清单写入失败或 actionId 不存在)';
      promptAction.showToast({ message: '重命名失败' });
      return;
    }
    // 关闭对话框
    this.animationRenameDialogVisible = false;
    this.pendingRenameActionId = '';
    this.pendingRenameDisplayName = '';
    // 刷新列表
    await this.loadAnimationAssetsFromLibrary();
    promptAction.showToast({ message: '已重命名' });
  }

  /**
   * Phase 3C-2: 打开删除确认对话框。
   */
  private onAnimationDeleteButton(actionId: string, displayName: string): void {
    if (actionId.length === 0) {
      return;
    }
    this.pendingDeleteActionId = actionId;
    this.pendingDeleteActionName = displayName;
    this.animationDeleteConfirmVisible = true;
  }

  /**
   * Phase 3C-2: 取消删除。
   */
  private onAnimationDeleteCancel(): void {
    this.animationDeleteConfirmVisible = false;
    this.pendingDeleteActionId = '';
    this.pendingDeleteActionName = '';
  }

  /**
   * Phase 3C-2: 确认删除。
   *
   * 流程 (规范 §删除):
   * 1. 停止当前动画加载轮询
   * 2. 若删除的是 selectedActionId, 调用现有 stopAnimation()
   * 3. PersistentAnimationStore.deleteAnimation (rename .deleting → 移除清单 → 删除 .deleting)
   * 4. 清单写入失败: 文件 rename 回原文件 (回滚)
   * 5. 删除当前选中动作后: selectedActionId='', 清除选择状态, 禁用播放按钮
   */
  private async onAnimationDeleteConfirm(): Promise<void> {
    const actionId: string = this.pendingDeleteActionId;
    if (actionId.length === 0) {
      this.onAnimationDeleteCancel();
      return;
    }
    if (this.persistentAnimationStore === null || this.assetLibrary === null) {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_STORE_LIBRARY_INVALID;
      this.animationLibraryErrorMessage = '动画存储/资产库未初始化';
      promptAction.showToast({ message: '删除失败: 存储未初始化' });
      this.onAnimationDeleteCancel();
      return;
    }

    // 1. 停止加载轮询
    this.stopAnimationLoadPolling();

    // 2. 若删除的是当前选中动作, 调用 stopAnimation 停止播放
    const wasSelected: boolean = this.selectedActionId === actionId;
    if (wasSelected && this.viewerState === ArkWebViewerState.READY) {
      try {
        await this.arkWebController.stopAnimation('');
      } catch (_e) {
        // 忽略停止失败, 继续删除流程
      }
    }

    // 3. 删除持久化文件 + 移除清单记录 (含 .deleting 回滚)
    const ok: boolean = await this.persistentAnimationStore.deleteAnimation(actionId);
    if (!ok) {
      const err: string = this.persistentAnimationStore.getLastError();
      // 解析错误码前缀
      const code: string = err.indexOf(':') > 0 ? err.split(':')[0] : err;
      this.animationLibraryErrorCode = code;
      this.animationLibraryErrorMessage = err;
      promptAction.showToast({ message: `删除失败: ${err}` });
      this.onAnimationDeleteCancel();
      return;
    }

    // 5. 删除选中动作后清除选择状态 (禁用播放按钮由 isAnimationPlayButtonEnabled 自然处理)
    if (wasSelected) {
      this.selectedActionId = '';
    }

    // 关闭对话框 + 刷新列表
    this.animationDeleteConfirmVisible = false;
    this.pendingDeleteActionId = '';
    this.pendingDeleteActionName = '';
    await this.loadAnimationAssetsFromLibrary();
    this.refreshAnimationDebugState();
    promptAction.showToast({ message: '已删除' });
  }

  /**
   * Phase 3C-2: 设为默认待机 / 取消默认待机。
   *
   * - 当前已是默认: 点击取消 (传入空字符串)
   * - 当前不是默认: 点击设为默认
   *
   * 仅保存元数据, 不自动加载/播放。
   */
  private async onAnimationToggleIdleButton(actionId: string): Promise<void> {
    if (actionId.length === 0) {
      return;
    }
    if (this.assetLibrary === null) {
      this.animationLibraryErrorCode = PersistentAnimationErrorCode.ANIMATION_STORE_LIBRARY_INVALID;
      this.animationLibraryErrorMessage = '资产库未初始化';
      promptAction.showToast({ message: '资产库未初始化' });
      return;
    }
    // 已是默认 → 取消; 否则 → 设为默认
    const target: string = this.defaultIdleActionId === actionId ? '' : actionId;
    const ok: boolean = await this.assetLibrary.setDefaultIdleAction(target);
    if (!ok) {
      this.animationLibraryErrorCode = AnimationManagementErrorCode.ANIMATION_DEFAULT_IDLE_WRITE_FAILED;
      this.animationLibraryErrorMessage = '默认待机标记更新失败 (清单写入失败)';
      promptAction.showToast({ message: '设置失败' });
      return;
    }
    this.defaultIdleActionId = target;
    promptAction.showToast({
      message: target.length > 0 ? '已设为默认待机' : '已取消默认待机'
    });
  }

  /**
   * Phase 3A: 解析 loadAnimationResource 返回的 JSON。
   *
   * 合法返回:
   *   {"success": true, "state": "LOADING", "generation": <number>}
   *   {"success": false, "error": {"code": "...", "message": "..."}}
   *
   * @returns 解析后的对象; 非法 JSON 返回 null
   */
  private parseAnimationLoadResponse(resultJson: string): Record<string, Object> | null {
    if (resultJson.length === 0) {
      return null;
    }
    try {
      return JSON.parse(resultJson) as Record<string, Object>;
    } catch (e) {
      console.warn('[VrmViewerPage] parseAnimationLoadResponse failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return null;
    }
  }

  /**
   * Phase 3A: 启动动画加载状态轮询。
   *
   * 每 100ms 查询 getAnimationDebugState, 直到状态离开 LOADING 或超时 (30s)。
   * 页面销毁时停止 (disposeViewer 调用 stopAnimationLoadPolling)。
   */
  private startAnimationLoadPolling(): void {
    this.stopAnimationLoadPolling();
    this.animationLoadPollCount = 0;
    this.animationLoadPollTimerId = setInterval(() => {
      this.animationLoadPollCount++;
      if (this.animationLoadPollCount > this.ANIMATION_LOAD_POLL_MAX_COUNT) {
        // 超时 (30s)
        console.warn('[VrmViewerPage] animation load poll timeout');
        this.stopAnimationLoadPolling();
        this.animationActionError = '动画加载超时 (30s)';
        return;
      }
      this.arkWebController.getAnimationDebugState().then((resultJson: string) => {
        this.parseAnimationDebugState(resultJson);
        // 状态离开 LOADING → 停止轮询
        if (this.debugAnimationState !== 'LOADING') {
          this.stopAnimationLoadPolling();
          if (this.debugAnimationState === 'READY') {
            promptAction.showToast({ message: 'VRMA 已加载，可以播放' });
          } else if (this.debugAnimationState === 'FAILED') {
            const errorCode: string = this.debugAnimationErrorCode;
            const msg: string = this.debugAnimationErrorMessage;
            this.animationActionError = `加载失败: ${errorCode}${msg.length > 0 ? ' - ' + msg : ''}`;
            promptAction.showToast({ message: this.animationActionError });
          }
        }
      }).catch((e: Object) => {
        console.warn('[VrmViewerPage] animation poll getAnimationDebugState failed: ' +
          (e instanceof Error ? e.message : String(e)));
      });
    }, this.ANIMATION_LOAD_POLL_INTERVAL_MS);
  }

  /**
   * Phase 3A: 停止动画加载状态轮询。
   */
  private stopAnimationLoadPolling(): void {
    if (this.animationLoadPollTimerId !== -1) {
      clearInterval(this.animationLoadPollTimerId);
      this.animationLoadPollTimerId = -1;
    }
    this.animationLoadPollCount = 0;
  }

  /**
   * Phase 3A: 用户点击"播放"按钮。
   *
   * 合法状态: READY / PAUSED / STOPPED
   */
  private async onAnimationPlayButton(): Promise<void> {
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: 'Viewer 尚未就绪' });
      return;
    }
    this.animationActionError = '';
    try {
      const resultJson: string = await this.arkWebController.playAnimation();
      const parsed: Record<string, Object> | null = this.parseAnimationLoadResponse(resultJson);
      if (parsed === null || parsed['success'] !== true) {
        const errObj = parsed ? (parsed['error'] as Record<string, Object>) : null;
        const code: string = errObj ? (errObj['code'] as string) || 'UNKNOWN' : 'UNKNOWN';
        const msg: string = errObj ? (errObj['message'] as string) || '' : '';
        this.animationActionError = `播放失败: ${code}${msg.length > 0 ? ' - ' + msg : ''}`;
        promptAction.showToast({ message: this.animationActionError });
        return;
      }
      this.refreshAnimationDebugState();
      promptAction.showToast({ message: '动画播放中' });
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.animationActionError = `播放异常: ${msg}`;
      promptAction.showToast({ message: this.animationActionError });
    }
  }

  /**
   * Phase 3A: 用户点击"暂停"按钮。
   *
   * 只允许 PLAYING 状态。
   */
  private async onAnimationPauseButton(): Promise<void> {
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: 'Viewer 尚未就绪' });
      return;
    }
    this.animationActionError = '';
    try {
      const resultJson: string = await this.arkWebController.pauseAnimation();
      const parsed: Record<string, Object> | null = this.parseAnimationLoadResponse(resultJson);
      if (parsed === null || parsed['success'] !== true) {
        const errObj = parsed ? (parsed['error'] as Record<string, Object>) : null;
        const code: string = errObj ? (errObj['code'] as string) || 'UNKNOWN' : 'UNKNOWN';
        const msg: string = errObj ? (errObj['message'] as string) || '' : '';
        this.animationActionError = `暂停失败: ${code}${msg.length > 0 ? ' - ' + msg : ''}`;
        promptAction.showToast({ message: this.animationActionError });
        return;
      }
      this.refreshAnimationDebugState();
      promptAction.showToast({ message: '动画已暂停' });
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.animationActionError = `暂停异常: ${msg}`;
      promptAction.showToast({ message: this.animationActionError });
    }
  }

  /**
   * Phase 3A: 用户点击"停止"按钮。
   *
   * 允许 PLAYING / PAUSED 状态。默认 resetPose=true。
   */
  private async onAnimationStopButton(): Promise<void> {
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: 'Viewer 尚未就绪' });
      return;
    }
    this.animationActionError = '';
    try {
      // 默认 resetPose=true (传空字符串表示使用默认选项)
      const resultJson: string = await this.arkWebController.stopAnimation('');
      const parsed: Record<string, Object> | null = this.parseAnimationLoadResponse(resultJson);
      if (parsed === null || parsed['success'] !== true) {
        const errObj = parsed ? (parsed['error'] as Record<string, Object>) : null;
        const code: string = errObj ? (errObj['code'] as string) || 'UNKNOWN' : 'UNKNOWN';
        const msg: string = errObj ? (errObj['message'] as string) || '' : '';
        this.animationActionError = `停止失败: ${code}${msg.length > 0 ? ' - ' + msg : ''}`;
        promptAction.showToast({ message: this.animationActionError });
        return;
      }
      this.refreshAnimationDebugState();
      promptAction.showToast({ message: '动画已停止' });
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.animationActionError = `停止异常: ${msg}`;
      promptAction.showToast({ message: this.animationActionError });
    }
  }

  /**
   * Phase 3A: 判断"选择 VRMA"按钮是否可点击。
   *
   * 加载中禁用。
   */
  private isAnimationImportButtonEnabled(): boolean {
    if (this.viewerState !== ArkWebViewerState.READY) {
      return false;
    }
    if (this.debugAnimationState === 'LOADING') {
      return false;
    }
    if (this.animationImportState === AnimationImportState.PICKING ||
        this.animationImportState === AnimationImportState.COPYING) {
      return false;
    }
    return true;
  }

  /**
   * Phase 3A: 判断"播放"按钮是否可点击。
   *
   * 启用条件: READY / PAUSED / STOPPED
   */
  private isAnimationPlayButtonEnabled(): boolean {
    if (this.viewerState !== ArkWebViewerState.READY) {
      return false;
    }
    return this.debugAnimationState === 'READY' ||
           this.debugAnimationState === 'PAUSED' ||
           this.debugAnimationState === 'STOPPED';
  }

  /**
   * Phase 3A: 判断"暂停"按钮是否可点击。
   *
   * 启用条件: PLAYING
   */
  private isAnimationPauseButtonEnabled(): boolean {
    if (this.viewerState !== ArkWebViewerState.READY) {
      return false;
    }
    return this.debugAnimationState === 'PLAYING';
  }

  /**
   * Phase 3A: 判断"停止"按钮是否可点击。
   *
   * 启用条件: PLAYING / PAUSED
   */
  private isAnimationStopButtonEnabled(): boolean {
    if (this.viewerState !== ArkWebViewerState.READY) {
      return false;
    }
    return this.debugAnimationState === 'PLAYING' ||
           this.debugAnimationState === 'PAUSED';
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
    // Final Acceptance Fix: 裁剪相关 Debug 字段
    this.debugCameraMinDistance = cameraState.minDistance !== undefined ? cameraState.minDistance : 0;
    this.debugCameraMaxDistance = cameraState.maxDistance !== undefined ? cameraState.maxDistance : 0;
    this.debugCameraModelBoundingRadius =
      cameraState.modelBoundingRadius !== undefined ? cameraState.modelBoundingRadius : 0;
    this.debugCameraLastClipUpdateReason =
      cameraState.lastClipUpdateReason !== undefined ? cameraState.lastClipUpdateReason : '';
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
        // Phase 3B:使用 PersistentModelStore 持久化到 filesDir
        // 不再走 registerImportedResource 的 cacheDir 路径
        await this.persistAndRegisterImportedModel(result);
        // Phase 1D-2C-1:导入成功后持久化元数据到 StateStore(legacy,供旧版回退)
        // 保存失败不影响当前导入,只显示提示
        this.saveImportStateToStore(result);
        promptAction.showToast({ message: '模型已导入并加载' });
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
   * Phase 3B: 持久化导入的模型到 filesDir 并注册到 Provider。
   *
   * 流程 (AGENTS.md Phase 3B §十八):
   * 1. PersistentModelStore.importModel(sourceUri, displayName, extension)
   *    - 原子复制到 <filesDir>/avatar-assets/models/<modelId>.vrm
   *    - 更新 library.json (设置 activeModelId)
   * 2. 验证持久化文件
   * 3. 注册到 Provider (registerPersistentAsset,使用 filesDir 绝对路径)
   * 4. ensurePreparedModelResource + tryAutoProbeResource
   * 5. autoLoadCurrentModel (自动加载,无需用户点击)
   *
   * 失败处理:
   * - PersistentModelStore 失败:保留 ImportController 的 cacheDir 文件(legacy 行为)
   * - Provider 注册失败:保留持久化文件与 library.json 记录
   * - 加载失败:保留持久化文件与 library.json 记录,允许稍后重新加载
   *
   * @param file ImportController 产出的导入文件(含 sourceUri)
   */
  private async persistAndRegisterImportedModel(file: ImportedModelFile): Promise<void> {
    if (this.persistentModelStore === null || this.resourceProvider === null || this.assetLibrary === null) {
      // Phase 3B 未初始化,回退到 Phase 1D-2A 的 cacheDir 路径
      console.warn('[VrmViewerPage] Phase 3B store not ready, fallback to registerImportedResource');
      await this.registerImportedResource(file);
      return;
    }

    // 1. 持久化到 filesDir
    const asset: ArkWebAvatarModelAsset | null = await this.persistentModelStore.importModel(
      file.sourceUri,
      file.displayName,
      file.extension
    );
    if (asset === null) {
      const err: string = this.persistentModelStore.getLastError();
      this.preparedResource = null;
      this.resourceState = ModelResourceState.EMPTY;
      this.resourceLastError = `持久化失败: ${err}`;
      promptAction.showToast({ message: `模型持久化失败: ${err}` });
      return;
    }

    // 更新 Phase 3B @State
    this.activeModelId = asset.modelId;
    this.activeModelDisplayName = asset.displayName;
    this.activeModelByteLength = asset.byteLength;
    this.legacyModelMigrated = false;
    this.modelRestoreState = ArkWebModelRestoreState.READY;
    this.modelRestoreErrorCode = '';
    this.modelRestoreErrorMessage = '';
    // Phase 3D-3: 新模型导入 → generation++ 允许对新模型重新应用一次默认姿势
    this.modelRestoreGeneration++;
    console.info(`[VrmViewerPage] model persisted: id=${asset.modelId} size=${asset.byteLength}`);

    // 2. 注册到 Provider (使用 filesDir 绝对路径)
    const absolutePath: string = this.persistentModelStore.resolveAbsolutePath(asset.relativePath);
    if (absolutePath.length === 0) {
      this.resourceLastError = 'resolveAbsolutePath empty';
      promptAction.showToast({ message: '模型路径解析失败' });
      return;
    }
    let resource: WebModelResource;
    try {
      resource = this.resourceProvider.registerPersistentAsset(
        absolutePath,
        asset,
        file.gltfDependencyState
      );
      this.preparedResource = resource;
      this.resourceState = this.resourceProvider.getState();
      this.resourceLastError = '';
      console.info(`[VrmViewerPage] persistent resource ready: url=${resource.resourceUrl}`);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.preparedResource = null;
      this.resourceState = this.resourceProvider.getState();
      this.resourceLastError = msg;
      promptAction.showToast({ message: `资源注册失败: ${msg}` });
      return;
    }

    // 3. ensurePreparedModelResource (Viewer 未 READY 时静默失败,等待 READY 后重试)
    if (this.viewerState !== ArkWebViewerState.READY) {
      console.info('[VrmViewerPage] Viewer not ready, prepare will retry on READY');
      return;
    }
    const prepared: boolean = await this.ensurePreparedModelResource(resource, false);
    if (!prepared) {
      console.warn(`[VrmViewerPage] import ensurePreparedModelResource failed: ${this.webPreparedErrorCode}`);
      return;
    }

    // 4. 自动探测 + 自动加载
    this.tryAutoProbeResource();
    const probeOk: boolean = await this.waitForProbeVerified(4500);
    if (!probeOk) {
      console.warn(`[VrmViewerPage] import probe not verified: ${this.probeErrorCode}`);
      return;
    }
    const loadOk: boolean = await this.autoLoadCurrentModel();
    if (!loadOk) {
      console.warn(`[VrmViewerPage] import auto load failed: ${this.loadErrorCode}`);
      promptAction.showToast({ message: '模型加载失败,可点击"重新加载"重试' });
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

  // ===== Phase 3B: 模型自动恢复与持久化资产目录 =====

  /**
   * Phase 3B: 启动 activeModel 自动恢复。
   *
   * 触发时机:Viewer READY 后(由 onStateChangedFn 调用)。
   * 单次触发保护:restoreStarted 标志,重复 READY 回调不再启动。
   * 代次保护:modelRestoreGeneration,页面销毁后异步回调过期。
   *
   * 流程 (AGENTS.md Phase 3B §二十):
   * 1. 检查单次触发保护(restoreStarted / restoreDisposed)
   * 2. 检查 Viewer READY
   * 3. 等待 AssetLibrary 初始化完成
   * 4. 读取 library.json
   * 5. 查找 activeModelId
   * 6. 有 active model:验证文件 → 注册 Provider → loadPreparedModelResource → 自动取景
   * 7. 无 active model:尝试旧缓存迁移(StateStore) → 失败则进入 EMPTY
   *
   * 失败处理:
   * - 不崩溃,不无限重试,不反复弹 Toast
   * - 更新 modelRestoreState / modelRestoreErrorCode 供 UI 显示
   * - 保留 Viewer 现有状态(不强制 FAILED)
   */
  private async startActiveModelRestore(): Promise<void> {
    // 1. 单次触发保护
    if (this.restoreDisposed) {
      console.info('[VrmViewerPage] startActiveModelRestore: disposed, skip');
      return;
    }
    if (this.restoreStarted) {
      console.info('[VrmViewerPage] startActiveModelRestore: already started, skip');
      return;
    }
    // 2. Viewer 必须为 READY
    if (this.viewerState !== ArkWebViewerState.READY) {
      console.info(`[VrmViewerPage] startActiveModelRestore: viewer not ready (${this.viewerState}), skip`);
      return;
    }
    // 3. 并发保护
    if (this.modelRestoreInProgress) {
      console.info('[VrmViewerPage] startActiveModelRestore: in progress, skip');
      return;
    }

    this.restoreStarted = true;
    this.modelRestoreInProgress = true;
    this.modelRestoreGeneration++;
    const generation: number = this.modelRestoreGeneration;
    this.modelRestoreState = ArkWebModelRestoreState.READING_LIBRARY;
    this.modelRestoreErrorCode = '';
    this.modelRestoreErrorMessage = '';

    try {
      // 等待 AssetLibrary 初始化
      if (this.assetLibrary === null) {
        this.failModelRestore(ModelRestoreErrorCode.MODEL_RESTORE_LIBRARY_MISSING, 'AssetLibrary not created');
        return;
      }
      const initOk: boolean = await this.assetLibrary.ensureInitialized();
      if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
        return; // 过期
      }
      if (!initOk) {
        this.failModelRestore(ModelRestoreErrorCode.MODEL_RESTORE_LIBRARY_MISSING, 'AssetLibrary init failed');
        return;
      }

      // 读取清单并查找 active model
      const activeAsset: ArkWebAvatarModelAsset | null = await this.assetLibrary.findActiveModel();
      if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
        return;
      }

      if (activeAsset === null) {
        // 无 active model,尝试旧缓存迁移
        console.info('[VrmViewerPage] no active model, try legacy migration');
        this.modelRestoreState = ArkWebModelRestoreState.MIGRATING;
        const migrated: boolean = await this.tryLegacyCacheMigration();
        if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
          return;
        }
        if (!migrated) {
          // 无旧缓存,进入空状态
          this.modelRestoreState = ArkWebModelRestoreState.EMPTY;
          this.activeModelId = '';
          this.activeModelDisplayName = '';
          this.activeModelByteLength = 0;
          console.info('[VrmViewerPage] no model to restore, entering EMPTY state');
        }
        return;
      }

      // 有 active model,验证并加载
      this.activeModelId = activeAsset.modelId;
      this.activeModelDisplayName = activeAsset.displayName;
      this.activeModelByteLength = activeAsset.byteLength;
      console.info(`[VrmViewerPage] active model found: id=${activeAsset.modelId} name=${activeAsset.displayName}`);

      const loaded: boolean = await this.validateRegisterAndLoadPersistentAsset(activeAsset, generation);
      if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
        return;
      }
      if (loaded) {
        this.modelRestoreState = ArkWebModelRestoreState.READY;
        console.info('[VrmViewerPage] active model restored successfully');
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.failModelRestore(ModelRestoreErrorCode.MODEL_RESTORE_LOAD_FAILED, `restore exception: ${msg}`);
    } finally {
      this.modelRestoreInProgress = false;
    }
  }

  /**
   * Phase 3B: 尝试旧缓存迁移(从 StateStore 恢复 cacheDir 模型到 filesDir)。
   *
   * 仅在新清单无 active model 时执行一次。
   * 成功后通过 PersistentModelStore 写入 filesDir + library.json,后续不再走此路径。
   *
   * @returns true 表示迁移成功并已加载模型;false 表示无旧缓存或迁移失败
   */
  private async tryLegacyCacheMigration(): Promise<boolean> {
    if (this.importStateStore === null || this.persistentModelStore === null || this.assetLibrary === null) {
      return false;
    }
    try {
      const result: ImportStateRestoreResult = await this.importStateStore.restore();
      if (result.file === null) {
        // 无记录或损坏记录
        if (result.errorCode.length > 0) {
          console.warn(`[VrmViewerPage] legacy StateStore restore failed: ${result.errorCode} ${result.errorMessage}`);
        }
        return false;
      }

      const file: ImportedModelFile = result.file;
      console.info(`[VrmViewerPage] legacy cache found: ${file.displayName} size=${file.size}, migrating`);

      // 迁移到 filesDir 持久目录
      const asset: ArkWebAvatarModelAsset | null = await this.persistentModelStore.migrateFromLegacyCache(
        file.cachePath,
        file.displayName,
        file.extension,
        file.size
      );
      if (asset === null) {
        const err: string = this.persistentModelStore.getLastError();
        console.warn(`[VrmViewerPage] legacy migrate failed: ${err}`);
        // 迁移失败不删除旧缓存
        this.failModelRestore(ModelRestoreErrorCode.MODEL_RESTORE_LOAD_FAILED, `migrate failed: ${err}`);
        return false;
      }

      // 迁移成功,标记并加载
      this.legacyModelMigrated = true;
      this.activeModelId = asset.modelId;
      this.activeModelDisplayName = asset.displayName;
      this.activeModelByteLength = asset.byteLength;
      console.info(`[VrmViewerPage] legacy migration ok: id=${asset.modelId}`);

      const generation: number = this.modelRestoreGeneration;
      const loaded: boolean = await this.validateRegisterAndLoadPersistentAsset(asset, generation);
      return loaded;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] tryLegacyCacheMigration exception: ${msg}`);
      return false;
    }
  }

  /**
   * Phase 3B: 验证、注册并加载持久化模型资产。
   *
   * 流程:
   * 1. 验证文件存在与大小(VALIDATING)
   * 2. 注册到 Provider(REGISTERING)
   * 3. ensurePreparedModelResource + tryAutoProbeResource(LOADING)
   * 4. loadPreparedModelResource(自动加载,无需用户点击)
   *
   * @param asset 持久化模型资产
   * @param generation 调用时的恢复代次(用于过期判断)
   * @returns true 表示加载成功;false 表示失败(错误码已更新)
   */
  private async validateRegisterAndLoadPersistentAsset(
    asset: ArkWebAvatarModelAsset,
    generation: number
  ): Promise<boolean> {
    if (this.persistentModelStore === null || this.resourceProvider === null) {
      this.failModelRestore(ModelRestoreErrorCode.MODEL_RESTORE_PROVIDER_FAILED, 'store/provider null');
      return false;
    }

    // 1. VALIDATING: 验证文件
    this.modelRestoreState = ArkWebModelRestoreState.VALIDATING;
    const validateOk: boolean = await this.persistentModelStore.validateModelFile(
      asset.relativePath,
      asset.byteLength
    );
    if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
      return false;
    }
    if (!validateOk) {
      const err: string = this.persistentModelStore.getLastError();
      this.failModelRestore(ModelRestoreErrorCode.MODEL_RESTORE_FILE_MISSING, `validate failed: ${err}`);
      return false;
    }

    // 2. REGISTERING: 注册到 Provider
    this.modelRestoreState = ArkWebModelRestoreState.REGISTERING;
    const absolutePath: string = this.persistentModelStore.resolveAbsolutePath(asset.relativePath);
    if (absolutePath.length === 0) {
      this.failModelRestore(ModelRestoreErrorCode.MODEL_RESTORE_PATH_INVALID, 'resolveAbsolutePath empty');
      return false;
    }
    let resource: WebModelResource;
    try {
      resource = this.resourceProvider.registerPersistentAsset(
        absolutePath,
        asset,
        GltfDependencyState.NOT_APPLICABLE
      );
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.failModelRestore(ModelRestoreErrorCode.MODEL_RESTORE_PROVIDER_FAILED, `register failed: ${msg}`);
      return false;
    }
    if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
      return false;
    }
    this.preparedResource = resource;
    this.resourceState = this.resourceProvider.getState();
    this.resourceLastError = '';
    console.info(`[VrmViewerPage] persistent asset registered: url=${resource.resourceUrl}`);

    // 3. LOADING: ensurePreparedModelResource + probe + load
    this.modelRestoreState = ArkWebModelRestoreState.LOADING;
    const prepared: boolean = await this.ensurePreparedModelResource(resource, false);
    if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
      return false;
    }
    if (!prepared) {
      this.failModelRestore(
        ModelRestoreErrorCode.MODEL_RESTORE_LOAD_FAILED,
        `prepare failed: ${this.webPreparedErrorCode} ${this.webPreparedErrorMessage}`
      );
      return false;
    }

    // 自动探测
    this.tryAutoProbeResource();

    // 等待探测完成(最多 4.5s),VERIFIED 后自动加载
    const probeOk: boolean = await this.waitForProbeVerified(4500);
    if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
      return false;
    }
    if (!probeOk) {
      this.failModelRestore(
        ModelRestoreErrorCode.MODEL_RESTORE_LOAD_FAILED,
        `probe not verified: ${this.probeErrorCode} ${this.probeErrorMessage}`
      );
      return false;
    }

    // 自动加载模型(无需用户点击)
    const loadOk: boolean = await this.autoLoadCurrentModel();
    if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
      return false;
    }
    if (!loadOk) {
      this.failModelRestore(
        ModelRestoreErrorCode.MODEL_RESTORE_LOAD_FAILED,
        `load failed: ${this.loadErrorCode} ${this.loadErrorMessage}`
      );
      return false;
    }
    return true;
  }

  /**
   * Phase 3B: 等待资源探测达到 VERIFIED 状态(或 FAILED/超时)。
   *
   * 简单轮询:每 200ms 检查 probeState,最长等待 timeoutMs。
   * 注意:实际探测由 tryAutoProbeResource 启动,本方法只等待结果。
   *
   * @param timeoutMs 最大等待时间
   * @returns true 表示 VERIFIED;false 表示 FAILED / 超时 / 未启动
   */
  private async waitForProbeVerified(timeoutMs: number): Promise<boolean> {
    const startTime: number = Date.now();
    const intervalMs: number = 200;
    while (Date.now() - startTime < timeoutMs) {
      if (this.probeState === ModelResourceProbeState.VERIFIED) {
        return true;
      }
      if (this.probeState === ModelResourceProbeState.FAILED) {
        return false;
      }
      // 未探测或探测中,继续等待
      await this.delay(intervalMs);
    }
    return false;
  }

  /**
   * Phase 3B: 自动加载当前已准备的模型(无需用户点击)。
   *
   * 复用 onLoadModelButton 的核心流程,但不显示前置条件 Toast。
   * 失败时不弹 Toast(由调用方决定如何提示)。
   *
   * @returns true 表示加载成功;false 表示失败
   */
  private async autoLoadCurrentModel(): Promise<boolean> {
    if (this.preparedResource === null) {
      return false;
    }
    if (this.viewerState !== ArkWebViewerState.READY) {
      return false;
    }
    if (this.probeState !== ModelResourceProbeState.VERIFIED) {
      return false;
    }
    if (this.loadInProgress) {
      return false;
    }

    this.resetLoadState();
    this.loadInProgress = true;
    this.loadState = 'LOADING';
    this.loadStartedAt = Date.now();
    this.loadPollCount = 0;
    this.loadDisplayName = this.preparedResource.displayName;

    try {
      const startResult: string = await this.arkWebController.loadPreparedModelResource();
      if (startResult.indexOf('"success":true') < 0 && startResult.indexOf('"success": true') < 0) {
        this.loadState = 'FAILED';
        this.loadErrorCode = 'LOAD_START_FAILED';
        const errorMatch: RegExpMatchArray | null = startResult.match(/"message"\s*:\s*"([^"]*)"/);
        this.loadErrorMessage = errorMatch !== null && errorMatch.length >= 2 ? errorMatch[1] : startResult;
        this.loadCompletedAt = Date.now();
        this.loadInProgress = false;
        return false;
      }
      // 启动轮询
      this.startLoadPolling();
      // 等待加载完成(最多 60s)
      const loaded: boolean = await this.waitForLoadReady(60000);
      return loaded;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.loadState = 'FAILED';
      this.loadErrorCode = 'LOAD_START_FAILED';
      this.loadErrorMessage = msg;
      this.loadCompletedAt = Date.now();
      this.loadInProgress = false;
      return false;
    }
  }

  /**
   * Phase 3B: 等待模型加载达到 READY 状态(或 FAILED/超时)。
   *
   * @param timeoutMs 最大等待时间
   * @returns true 表示 READY;false 表示 FAILED / 超时
   */
  private async waitForLoadReady(timeoutMs: number): Promise<boolean> {
    const startTime: number = Date.now();
    const intervalMs: number = 250;
    while (Date.now() - startTime < timeoutMs) {
      if (this.loadState === 'READY') {
        this.loadInProgress = false;
        return true;
      }
      if (this.loadState === 'FAILED' || this.loadState === 'DISPOSED') {
        this.loadInProgress = false;
        return false;
      }
      await this.delay(intervalMs);
    }
    this.loadState = 'FAILED';
    this.loadErrorCode = 'LOAD_TIMEOUT';
    this.loadErrorMessage = `auto load timeout after ${timeoutMs}ms`;
    this.loadCompletedAt = Date.now();
    this.loadInProgress = false;
    return false;
  }

  /**
   * Phase 3B: 重新加载当前 activeModel(手动触发)。
   *
   * 用户点击"重新加载模型"按钮时调用。
   * 不重新选择文件,不复制模型,不修改 library.json。
   * 仅重新注册 Provider 并调用 loadPreparedModelResource。
   */
  private async onReloadModelButton(): Promise<void> {
    if (this.modelRestoreInProgress) {
      promptAction.showToast({ message: '模型恢复进行中' });
      return;
    }
    if (this.loadInProgress) {
      promptAction.showToast({ message: '模型加载中,请稍候' });
      return;
    }
    if (this.assetLibrary === null || this.persistentModelStore === null || this.resourceProvider === null) {
      promptAction.showToast({ message: '资产库未初始化' });
      return;
    }
    const activeAsset: ArkWebAvatarModelAsset | null = await this.assetLibrary.findActiveModel();
    if (activeAsset === null) {
      promptAction.showToast({ message: '无 activeModel,请导入模型' });
      return;
    }
    this.modelRestoreInProgress = true;
    this.modelRestoreGeneration++;
    const generation: number = this.modelRestoreGeneration;
    this.modelRestoreState = ArkWebModelRestoreState.LOADING;
    this.modelRestoreErrorCode = '';
    this.modelRestoreErrorMessage = '';
    try {
      const loaded: boolean = await this.validateRegisterAndLoadPersistentAsset(activeAsset, generation);
      if (generation !== this.modelRestoreGeneration || this.restoreDisposed) {
        return;
      }
      if (loaded) {
        this.modelRestoreState = ArkWebModelRestoreState.READY;
        promptAction.showToast({ message: '模型重新加载成功' });
      }
    } finally {
      this.modelRestoreInProgress = false;
    }
  }

  /**
   * Phase 3B: 记录模型恢复失败状态。
   */
  private failModelRestore(code: string, message: string): void {
    this.modelRestoreState = ArkWebModelRestoreState.FAILED;
    this.modelRestoreErrorCode = code;
    this.modelRestoreErrorMessage = message;
    console.warn(`[VrmViewerPage] model restore failed: ${code} ${message}`);
  }

  /**
   * Phase 3B: 延迟工具(供 waitForProbeVerified / waitForLoadReady 使用)。
   */
  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
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
    // Phase 3D-3: 手动加载模型 → generation++ 允许重新应用一次默认姿势
    this.modelRestoreGeneration++;

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
        // Phase 3D-2:模型加载成功后刷新 Debug 场景状态,同步 debugModelState='READY'
        // 否则姿势/动画等依赖 debugModelState==='READY' 的按钮会一直保持禁用
        this.refreshDebugSceneState();
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
  /**
   * Final Acceptance UX Cleanup: 模型简短加载状态标签 (主 Tab 用)。
   *
   * 只返回: 模型已加载 / 模型未加载 / 加载失败 / 加载中 / 恢复中
   */
  private modelLoadedLabel(): string {
    if (this.modelRestoreInProgress) {
      return '恢复中';
    }
    if (this.loadInProgress) {
      return '加载中';
    }
    if (this.importInProgress) {
      return '导入中';
    }
    if (this.loadErrorCode.length > 0 || this.modelRestoreErrorCode.length > 0) {
      return '加载失败';
    }
    if (this.activeModelId.length > 0 && this.debugModelState === 'READY') {
      return '模型已加载';
    }
    if (this.debugModelState === 'READY') {
      return '模型已加载';
    }
    return '模型未加载';
  }

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
          const request: WebResourceRequest = event.request;
          const url: string = request.getRequestUrl();
          const requestHeaders: Array<Header> = request.getRequestHeader();
          const method: string = request.getRequestMethod();

          // Phase 1D-2A: 模型资源拦截
          if (this.resourceProvider !== null && this.resourceProvider.matchesRequest(url)) {
            const modelResult = this.resourceProvider.handleRequest(url, method, requestHeaders);
            if (modelResult.response !== null) {
              return modelResult.response;
            }
            console.warn(`[VrmViewerPage] model resource handleRequest returned null: ${modelResult.errorCode} ${modelResult.errorMessage}`);
            return null;
          }

          // Phase 3A: 动画资源拦截 (独立于模型 Provider)
          if (this.animationResourceProvider !== null && this.animationResourceProvider.matchesRequest(url)) {
            const animResult = this.animationResourceProvider.handleRequest(url, method, requestHeaders);
            if (animResult.response !== null) {
              return animResult.response;
            }
            console.warn(`[VrmViewerPage] animation resource handleRequest returned null: ${animResult.errorCode} ${animResult.errorMessage}`);
            return null;
          }

          // 其他请求放行
          return null;
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

      // Phase 3B: 模型恢复中覆盖层(READING_LIBRARY/MIGRATING/VALIDATING/REGISTERING/LOADING)
      if (this.viewerState === ArkWebViewerState.READY &&
          this.modelRestoreState !== ArkWebModelRestoreState.READY &&
          this.modelRestoreState !== ArkWebModelRestoreState.EMPTY &&
          this.modelRestoreState !== ArkWebModelRestoreState.FAILED &&
          this.modelRestoreState !== ArkWebModelRestoreState.IDLE &&
          this.modelRestoreState !== ArkWebModelRestoreState.DISPOSED &&
          this.loadState !== 'READY') {
        Column() {
          Text('正在恢复角色模型…')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .margin({ bottom: 8 })
          Text(this.modelRestoreState)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor('#BFFFFFFF')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#80000000')
      }

      // Phase 3B: 空状态覆盖层(无 activeModel)
      // 不遮挡顶部导航与导入按钮,仅覆盖预览区域中心
      if (this.viewerState === ArkWebViewerState.READY &&
          this.modelRestoreState === ArkWebModelRestoreState.EMPTY &&
          this.loadState !== 'READY') {
        Column() {
          Text('尚未选择角色模型')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .margin({ bottom: 8 })
          Text('点击"导入模型"开始使用')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor('#BFFFFFFF')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#80000000')
      }

      // Phase 3B: 恢复失败覆盖层(保留重新加载与导入按钮)
      if (this.viewerState === ArkWebViewerState.READY &&
          this.modelRestoreState === ArkWebModelRestoreState.FAILED &&
          this.loadState !== 'READY') {
        Column() {
          Text('模型自动恢复失败')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FF6B6B')
            .margin({ bottom: 8 })
          Text(this.modelRestoreErrorCode)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor('#BFFFFFFF')
            .margin({ bottom: 4 })
          if (this.modelRestoreErrorMessage.length > 0) {
            Text(this.modelRestoreErrorMessage)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor('#99FFFFFF')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
          }
          Row() {
            Button('重新加载')
              .fontSize($r('app.float.app_font_body'))
              .fontColor('#FFFFFF')
              .backgroundColor($r('app.color.app_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .margin({ right: 8 })
              .enabled(!this.modelRestoreInProgress && !this.loadInProgress)
              .onClick(() => {
                this.onReloadModelButton();
              })
            Button('导入模型')
              .fontSize($r('app.float.app_font_body'))
              .fontColor('#FFFFFF')
              .backgroundColor('#33FFFFFF')
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .margin({ left: 8 })
              .enabled(!this.importInProgress && !this.loadInProgress)
              .onClick(() => {
                this.onImportModelButton();
              })
          }
          .margin({ top: 16 })
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
      // ===== Final Acceptance UX Cleanup: 主功能 Tab 只保留用户操作和简短状态 =====

      // 当前模型卡片:显示名称 + 加载状态
      Text('当前模型')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      Column() {
        Text(this.activeModelDisplayName.length > 0
          ? this.activeModelDisplayName
          : (this.debugModelDisplayName.length > 0 ? this.debugModelDisplayName : '未加载模型'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .width('100%')
        Text(this.modelLoadedLabel())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ top: 4 })
          .width('100%')
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius($r('app.float.app_radius_sm'))
      .margin({ bottom: 12 })

      // 主操作按钮:导入模型 / 重新加载模型
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

        Button('重新加载')
          .fontSize($r('app.float.app_font_body'))
          .fontColor('#FFFFFF')
          .backgroundColor('#33FFFFFF')
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .margin({ left: 8 })
          .enabled(this.activeModelId.length > 0 && !this.modelRestoreInProgress && !this.loadInProgress && !this.importInProgress)
          .onClick(() => {
            this.onReloadModelButton();
          })
      }
      .width('100%')

      // 导入进度简短状态
      if (this.importInProgress) {
        Text('正在导入模型...')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ top: 8 })
          .width('100%')
      }

      if (this.loadInProgress) {
        Text('正在加载模型...')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ top: 8 })
          .width('100%')
      }

      if (this.modelRestoreInProgress) {
        Text('正在恢复模型...')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ top: 8 })
          .width('100%')
      }

      // 错误摘要 (仅在真实错误存在时显示)
      if (this.importLastError.length > 0) {
        Column() {
          Text('导入失败')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.importLastError)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }

      if (this.loadErrorCode.length > 0) {
        Column() {
          Text('加载失败')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.loadErrorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }

      if (this.modelRestoreErrorCode.length > 0) {
        Column() {
          Text('恢复失败')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.modelRestoreErrorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }

      // 整体状态提示(仅在有提示时显示)
      if (this.overallStatusHint().length > 0) {
        Text(this.overallStatusHint())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.overallStatusColor())
          .margin({ top: 12 })
          .width('100%')
      }
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
      // Final Acceptance UX Cleanup: 主功能 Tab 只保留用户操作和资产列表
      Text('姿势系统')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 导入控件区
      Row() {
        Button('导入姿势')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .enabled(!this.poseImporting)
          .onClick(() => {
            this.onPoseImportButton();
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      // 姿势列表
      Text('姿势列表')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      if (this.poseAssets.length === 0) {
        Text('暂无已保存的姿势,点击"导入姿势"选择 .json 文件')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ bottom: 16 })
      } else {
        List({ space: 4 }) {
          ForEach(this.poseAssets, (asset: ArkWebAvatarPoseAsset) => {
            ListItem() {
              this.PoseListItem(asset)
            }
          }, (asset: ArkWebAvatarPoseAsset) => asset.poseId)
        }
        .width('100%')
        .margin({ bottom: 16 })
        .alignListItem(ListItemAlign.Center)
      }

      // 应用 / 恢复 按钮 (固定操作区)
      Row() {
        Button('应用姿势')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .enabled(this.selectedPoseId.length > 0
            && this.debugModelState === 'READY'
            && !this.poseImporting
            && !this.poseApplying)
          .onClick(() => {
            this.onApplyPoseClick();
          })

        Button('恢复姿势')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .margin({ left: 8 })
          .enabled(this.appliedPoseId.length > 0
            && this.debugModelState === 'READY'
            && !this.poseApplying)
          .onClick(() => {
            this.onResetPoseClick();
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      // 简短状态:已应用姿势
      if (this.appliedPoseId.length > 0) {
        Text(`已应用: ${this.appliedPoseDisplayName}`)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ top: 4 })
      }

      if (this.poseImporting) {
        Text('正在导入姿势...')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ top: 4 })
      }

      if (this.poseApplying) {
        Text('正在应用姿势...')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ top: 4 })
      }

      // 错误摘要 (仅在真实错误存在时显示)
      if (this.poseLastErrorCode.length > 0) {
        Column() {
          Text('姿势应用失败')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.poseLastErrorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }

      if (this.poseLibraryErrorCode.length > 0) {
        Column() {
          Text('姿势库错误')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.poseLibraryErrorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }

      if (this.defaultPoseRestoreErrorCode.length > 0) {
        Column() {
          Text('默认姿势恢复失败')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.defaultPoseRestoreErrorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * Phase 3D-1: 姿势列表项。
   *
   * 显示: displayName / 文件大小 / 格式 / 选中标记 / 默认姿势标记。
   * 点击: 仅更新 selectedPoseId (Phase 3D-2 起需点击"应用姿势"按钮才会实际应用)。
   * Phase 3D-3: 新增"设为默认"/"取消默认"按钮, 当前默认姿势显示"默认姿势"标记。
   * 不显示: absolutePath / relativePath / filesDir / 原始 URI。
   */
  @Builder
  PoseListItem(asset: ArkWebAvatarPoseAsset) {
    Row() {
      Column() {
        Row() {
          Text(asset.displayName)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
          // Phase 3D-3: 当前默认姿势标记
          if (this.defaultPoseId === asset.poseId) {
            Text('默认姿势')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ left: 6 })
          }
        }
        .width('100%')
        Row() {
          Text(this.formatPoseByteLength(asset.byteLength))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
          Text(' · ')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(asset.format)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
        }
        .width('100%')
        .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.selectedPoseId === asset.poseId) {
        Text('已选中')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ right: 6 })
      }

      // Phase 3D-3: 设为默认 / 取消默认 按钮
      // (不强制立即应用姿势, 只更新清单元数据)
      Button(this.defaultPoseId === asset.poseId ? '取消默认' : '设为默认')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(28)
        .enabled(this.assetLibrary !== null
          && !this.poseImporting
          && !this.poseApplying)
        .onClick(() => {
          this.onPoseToggleDefaultButton(asset.poseId);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_sm'))
    .onClick(() => {
      this.onPoseListItemClick(asset.poseId);
    })
  }

  @Builder
  TabAnimationContent() {
    Stack() {
    Column() {
      // Phase 3A — VRMA 文件导入与最小播放闭环
      Text('动画系统')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 控件区
      Row() {
        Button('选择 VRMA')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .margin({ right: 4 })
          .enabled(this.isAnimationImportButtonEnabled())
          .onClick(() => {
            this.onAnimationImportButton();
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      Row() {
        Button('播放')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .margin({ right: 4 })
          .enabled(this.isAnimationPlayButtonEnabled())
          .onClick(() => {
            this.onAnimationPlayButton();
          })

        Button('暂停')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .margin({ left: 4, right: 4 })
          .enabled(this.isAnimationPauseButtonEnabled())
          .onClick(() => {
            this.onAnimationPauseButton();
          })

        Button('停止')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .margin({ left: 4 })
          .enabled(this.isAnimationStopButtonEnabled())
          .onClick(() => {
            this.onAnimationStopButton();
          })
      }
      .width('100%')
      .margin({ bottom: 16 })

      // Phase 3C-1 — 动作列表
      Text('动作列表')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      if (this.animationAssets.length === 0) {
        Text('暂无已保存的动作,点击"选择 VRMA"导入')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ bottom: 16 })
      } else {
        List({ space: 4 }) {
          ForEach(this.animationAssets, (asset: ArkWebAvatarAnimationAsset) => {
            ListItem() {
              this.AnimationListItem(asset)
            }
          }, (asset: ArkWebAvatarAnimationAsset) => asset.actionId)
        }
        .width('100%')
        .margin({ bottom: 16 })
        .alignListItem(ListItemAlign.Center)
      }

      // Final Acceptance UX Cleanup: 移除内部 Debug 状态 (Mixer/Clip/Action/generation)
      // 保留简短状态和错误摘要

      // 简短状态
      if (this.debugAnimationName.length > 0) {
        Text(`当前动作: ${this.debugAnimationName}`)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ top: 4 })
      }

      if (this.debugAnimationState === 'LOADING') {
        Text('正在加载动作...')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ top: 4 })
      }

      // 错误摘要 (仅在真实错误存在时显示)
      if (this.debugAnimationErrorCode.length > 0) {
        Column() {
          Text('动作错误')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.debugAnimationErrorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }

      if (this.animationLibraryErrorCode.length > 0) {
        Column() {
          Text('动画库错误')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.animationLibraryErrorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }

      if (this.animationImportError.length > 0) {
        Column() {
          Text('导入错误')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.animationImportError)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }

      if (this.animationActionError.length > 0) {
        Column() {
          Text('动作操作错误')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
          Text(this.animationActionError)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)

    this.AnimationDeleteConfirmDialog()
    this.AnimationRenameDialog()
    }
    .width('100%')
    .alignContent(Alignment.Center)
  }

  /**
   * Phase 3C-1 / 3C-2: 动作列表项 (显示动作名/大小/选中状态 + 管理按钮)。
   *
   * 不显示: absolutePath / relativePath / filesDir / resourceId / 原始 URI。
   *
   * 操作:
   * - 点击列表项主体: 加载该动作
   * - 重命名按钮: 打开重命名对话框
   * - 设为待机 / 取消待机按钮: 切换默认待机标记
   * - 删除按钮: 打开删除确认对话框
   */
  @Builder
  AnimationListItem(asset: ArkWebAvatarAnimationAsset) {
    Column() {
      // 主行: 名称 + 大小 + 选中状态
      Row() {
        Column() {
          Row() {
            Text(asset.displayName)
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            // 默认待机标记
            if (this.defaultIdleActionId === asset.actionId) {
              Text('默认待机')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_primary'))
                .backgroundColor($r('app.color.app_surface_2'))
                .borderRadius($r('app.float.app_radius_sm'))
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ left: 6 })
            }
          }
          .width('100%')
          Text(this.formatAnimationByteLength(asset.byteLength))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.selectedActionId === asset.actionId ? '已选中' : '点击加载')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.selectedActionId === asset.actionId
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_secondary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .onClick(() => {
        this.onAnimationListItemClick(asset.actionId);
      })

      // 管理按钮行 (Phase 3C-2)
      Row() {
        Button('重命名')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(28)
          .layoutWeight(1)
          .margin({ right: 4 })
          .enabled(this.debugAnimationState !== 'LOADING')
          .onClick(() => {
            this.onAnimationRenameButton(asset.actionId, asset.displayName);
          })

        Button(this.defaultIdleActionId === asset.actionId ? '取消待机' : '设为待机')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(28)
          .layoutWeight(1)
          .margin({ left: 4, right: 4 })
          .enabled(this.debugAnimationState !== 'LOADING')
          .onClick(() => {
            this.onAnimationToggleIdleButton(asset.actionId);
          })

        Button('删除')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(28)
          .layoutWeight(1)
          .margin({ left: 4 })
          .enabled(this.debugAnimationState !== 'LOADING')
          .onClick(() => {
            this.onAnimationDeleteButton(asset.actionId, asset.displayName);
          })
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.selectedActionId === asset.actionId
      ? $r('app.color.app_surface_2')
      : $r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_sm'))
  }

  /**
   * Phase 3C-2: 删除确认对话框 (页面内确认状态, 不引入新 API)。
   */
  @Builder
  AnimationDeleteConfirmDialog() {
    if (this.animationDeleteConfirmVisible) {
      Column() {
        Text('确认删除动作')
          .fontSize($r('app.float.app_font_subtitle'))
          .fontColor($r('app.color.app_text_primary'))
          .margin({ bottom: 8 })
        Text(`将永久删除 "${this.pendingDeleteActionName}" 及其文件`)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ bottom: 16 })

        Row() {
          Button('取消')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(36)
            .layoutWeight(1)
            .margin({ right: 4 })
            .onClick(() => {
              this.onAnimationDeleteCancel();
            })

          Button('删除')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(36)
            .layoutWeight(1)
            .margin({ left: 4 })
            .onClick(() => {
              this.onAnimationDeleteConfirm();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(16)
      .backgroundColor($r('app.color.app_bg'))
      .borderRadius($r('app.float.app_radius_md'))
    }
  }

  /**
   * Phase 3C-2: 重命名对话框 (页面内输入 + 确认/取消)。
   */
  @Builder
  AnimationRenameDialog() {
    if (this.animationRenameDialogVisible) {
      Column() {
        Text('重命名动作')
          .fontSize($r('app.float.app_font_subtitle'))
          .fontColor($r('app.color.app_text_primary'))
          .margin({ bottom: 8 })
        TextInput({ text: this.pendingRenameDisplayName, placeholder: '输入新名称 (1-64 字符)' })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .width('100%')
          .margin({ bottom: 16 })
          .maxLength(64)
          .onChange((value: string) => {
            this.pendingRenameDisplayName = value;
          })

        Row() {
          Button('取消')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(36)
            .layoutWeight(1)
            .margin({ right: 4 })
            .onClick(() => {
              this.onAnimationRenameCancel();
            })

          Button('确定')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(36)
            .layoutWeight(1)
            .margin({ left: 4 })
            .onClick(() => {
              this.onAnimationRenameConfirm();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(16)
      .backgroundColor($r('app.color.app_bg'))
      .borderRadius($r('app.float.app_radius_md'))
    }
  }

  /**
   * Phase 3C-1: 格式化动画字节大小为可读字符串。
   */
  private formatAnimationByteLength(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    const KB: number = 1024;
    const MB: number = KB * 1024;
    if (bytes >= MB) {
      return `${(bytes / MB).toFixed(2)} MB`;
    }
    if (bytes >= KB) {
      return `${(bytes / KB).toFixed(2)} KB`;
    }
    return `${bytes} B`;
  }

  @Builder
  TabExpressionContent() {
    Column() {
      // Phase 3E-1 — VRM 表情系统
      Text('表情系统')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // Expression Manager 就绪状态
      Row() {
        Text('Expression Manager:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
        Text(this.expressionManagerReady ? '就绪' : '未就绪')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.expressionManagerReady
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_tertiary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ bottom: 8 })

      // 当前已应用表情
      Row() {
        Text('当前表情:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
        Text(this.appliedExpressionName.length > 0
          ? `${this.appliedExpressionName} (${this.appliedExpressionWeight.toFixed(2)})`
          : '无')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ bottom: 8 })

      // 最近错误
      if (this.expressionErrorCode.length > 0) {
        Row() {
          Text(`错误: ${this.expressionErrorCode}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ bottom: 4 })
        if (this.expressionErrorMessage.length > 0) {
          Text(this.expressionErrorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .width('100%')
            .margin({ bottom: 8 })
        }
      }

      // 表情列表
      Text('可用表情')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      if (!this.expressionManagerReady) {
        Text('模型不支持表情或未绑定 Expression Manager')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ bottom: 16 })
      } else if (this.availableExpressions.length === 0) {
        Text('当前模型无可用表情')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ bottom: 16 })
      } else {
        List({ space: 4 }) {
          ForEach(this.availableExpressions, (exp: ArkWebAvailableExpression) => {
            ListItem() {
              this.ExpressionListItem(exp)
            }
          }, (exp: ArkWebAvailableExpression) => exp.name)
        }
        .width('100%')
        .margin({ bottom: 16 })
        .alignListItem(ListItemAlign.Center)
      }

      // 权重选择
      Text('目标权重')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      Row({ space: 8 }) {
        ForEach([0, 0.25, 0.5, 0.75, 1], (w: number) => {
          Button(w === 0 ? '0' : w.toFixed(2))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.selectedExpressionWeight === w
              ? $r('app.color.app_text_primary')
              : $r('app.color.app_text_secondary'))
            .backgroundColor(this.selectedExpressionWeight === w
              ? $r('app.color.app_surface_2')
              : $r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .layoutWeight(1)
            .onClick(() => {
              this.selectedExpressionWeight = w;
            })
        })
      }
      .width('100%')
      .margin({ bottom: 16 })

      // 操作按钮
      Row() {
        Button('设置表情')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .enabled(this.debugModelState === 'READY'
            && this.selectedExpressionName.length > 0
            && this.expressionManagerReady
            && !this.expressionLoading)
          .onClick(() => {
            this.onSetExpressionClick();
          })

        Button('清除表情')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .margin({ left: 8 })
          .enabled(this.appliedExpressionName.length > 0
            && !this.expressionLoading)
          .onClick(() => {
            this.onResetExpressionClick();
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      Row() {
        Button('刷新列表')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .enabled(this.debugModelState === 'READY'
            && !this.expressionLoading)
          .onClick(() => {
            this.refreshAvailableExpressions();
          })
      }
      .width('100%')

      // Final Acceptance UX Cleanup: 表情别名映射改为纵向完整名称布局
      // 临时表情 / 统一演出 / 对话生命周期相关测试区域已移至 Debug Tab
      this.AliasMappingSection()
    }
    .width('100%')
  }

  /**
   * Final Acceptance UX Cleanup: 表情别名映射区域 (纵向布局)。
   *
   * 改为纵向映射列表, 顺序固定: 中性 / 开心 / 愤怒 / 悲伤 / 放松 / 惊讶
   * 每个别名使用独立映射行, 显示:
   *   - 中文别名 (完整显示)
   *   - 业务 ID (完整显示)
   *   - 当前映射的真实 Expression 名称 (独立文本区域, 最多两行, 超出才 ellipsis)
   *   - [绑定当前表情] [清除映射] 按钮
   *
   * 没有当前选择时: 绑定按钮禁用
   * 没有映射时: 显示 "未映射"
   */
  @Builder
  AliasMappingSection() {
    Divider()
      .color($r('app.color.app_divider'))
      .margin({ top: 16, bottom: 16 })

    Text('表情别名映射')
      .fontSize($r('app.float.app_font_subtitle'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.app_text_primary'))
      .margin({ bottom: 8 })

    Text('将固定业务 ID 绑定到当前模型真实存在的 Expression。')
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
      .margin({ bottom: 4 })

    // 当前选中的真实表情 (供绑定使用)
    Row() {
      Text('当前选择:')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(this.selectedExpressionName.length > 0 ? this.selectedExpressionName : '未选择')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.selectedExpressionName.length > 0
          ? $r('app.color.app_text_primary')
          : $r('app.color.app_text_tertiary'))
        .margin({ left: 8 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ bottom: 12 })

    // 重新载入按钮
    Row() {
      Button('重新载入映射')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .layoutWeight(1)
        .enabled(this.activeModelId.length > 0
          && !this.expressionAliasOperating)
        .onClick(() => {
          this.loadExpressionAliasMap();
        })
    }
    .width('100%')
    .margin({ bottom: 12 })

    // 纵向映射列表 (顺序固定: neutral / happy / angry / sad / relaxed / surprised)
    List({ space: 8 }) {
      ForEach(ArkWebExpressionAliasBusinessId.ALL, (id: string) => {
        ListItem() {
          this.AliasMappingRow(id)
        }
      }, (id: string) => id)
    }
    .width('100%')
    .margin({ bottom: 8 })
    .alignListItem(ListItemAlign.Center)

    // 错误显示
    if (this.expressionAliasErrorCode.length > 0) {
      Column() {
        Text('别名操作错误')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
        Text(this.expressionAliasErrorMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .margin({ top: 4 })
          .width('100%')
      }
      .width('100%')
      .padding(8)
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius($r('app.float.app_radius_sm'))
      .margin({ top: 8 })
    }
  }

  /**
   * Final Acceptance UX Cleanup: 单个别名映射行 (纵向布局)。
   *
   * 显示:
   *   - 中文别名 (完整显示)
   *   - 业务 ID: happy (完整显示)
   *   - 当前映射: Joy (独立文本区域, 最多两行, 超出才 ellipsis)
   *   - [绑定当前表情] [清除映射] 按钮 (文字不被截断)
   *
   * @param businessId 业务 ID (neutral/happy/angry/sad/relaxed/surprised)
   */
  @Builder
  AliasMappingRow(businessId: string) {
    Column() {
      // 第一行: 中文别名 (完整显示, 独占一行)
      Text(this.aliasChineseLabel(businessId))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .maxLines(1)

      // 第二行: 业务 ID (完整显示)
      Row() {
        Text('业务 ID:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
        Text(businessId)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .margin({ left: 6 })
      }
      .width('100%')
      .margin({ top: 2 })

      // 第三行: 当前映射的真实 Expression 名称 (独立文本区域, 最多两行)
      Row() {
        Text('当前映射:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
        Text(this.getAliasMappedName(businessId))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getAliasMappedName(businessId) === '未映射'
            ? $r('app.color.app_text_tertiary')
            : $r('app.color.app_text_primary'))
          .margin({ left: 6 })
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .margin({ top: 2 })

      // 第四行: 操作按钮 (绑定当前表情 / 清除映射)
      Row() {
        Button('绑定当前表情')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .layoutWeight(1)
          .enabled(this.debugModelState === 'READY'
            && this.expressionManagerReady
            && this.selectedExpressionName.length > 0
            && !this.expressionAliasOperating)
          .onClick(() => {
            this.saveExpressionAlias(businessId, this.selectedExpressionName);
          })

        Button('清除映射')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .layoutWeight(1)
          .margin({ left: 8 })
          .enabled(this.getAliasMappedName(businessId) !== '未映射'
            && !this.expressionAliasOperating)
          .onClick(() => {
            this.clearExpressionAlias(businessId);
          })
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .padding(10)
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_sm'))
  }

  /**
   * Final Acceptance UX Cleanup: 获取业务 ID 的中文别名标签。
   *
   * 顺序固定: 中性 / 开心 / 愤怒 / 悲伤 / 放松 / 惊讶
   */
  private aliasChineseLabel(businessId: string): string {
    if (businessId === 'neutral') {
      return '中性';
    } else if (businessId === 'happy') {
      return '开心';
    } else if (businessId === 'angry') {
      return '愤怒';
    } else if (businessId === 'sad') {
      return '悲伤';
    } else if (businessId === 'relaxed') {
      return '放松';
    } else if (businessId === 'surprised') {
      return '惊讶';
    }
    return businessId;
  }

  /**
   * Final Acceptance UX Cleanup: 获取业务 ID 当前映射的真实 Expression 名称。
   * 没有映射时返回 "未映射"。
   */
  private getAliasMappedName(businessId: string): string {
    const mapped: string = this.expressionAliasMap[businessId];
    if (mapped !== undefined && mapped.length > 0) {
      return mapped;
    }
    return '未映射';
  }

  /**
   * Phase 3E-2: 临时表情测试区域。
   *
   * 操作:
   *   - 选择真实 Expression (复用 selectedExpressionName 与 selectedExpressionWeight)
   *   - 选择持续时间 (1000 / 2500 / 5000 ms)
   *   - 选择恢复策略 (PREVIOUS / RESET)
   *   - 播放 / 取消临时表情
   */
  @Builder
  TemporaryExpressionSection() {
    Divider()
      .color($r('app.color.app_divider'))
      .margin({ top: 16, bottom: 16 })

    Text('临时表情测试')
      .fontSize($r('app.float.app_font_subtitle'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.app_text_primary'))
      .margin({ bottom: 8 })

    Text('设置临时表情并在到期后自动恢复或清除, 使用 generation 防止旧 timeout 干扰。')
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
      .margin({ bottom: 12 })

    // 当前临时表情状态
    Row() {
      Text('当前临时:')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(this.temporaryExpressionName.length > 0
        ? `${this.temporaryExpressionName} (${this.temporaryExpressionWeight.toFixed(2)})`
        : '无')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.temporaryExpressionName.length > 0
          ? $r('app.color.app_text_primary')
          : $r('app.color.app_text_tertiary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ bottom: 4 })

    Row() {
      Text('代次:')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(`${this.temporaryExpressionGeneration}`)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .margin({ left: 8 })
      Text(this.temporaryExpressionTimerActive ? '  (运行中)' : '  (空闲)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ bottom: 12 })

    // 持续时间
    Text('持续时间')
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
      .margin({ bottom: 4 })

    Row({ space: 8 }) {
      ForEach([1000, 2500, 5000], (ms: number) => {
        Button(`${ms}ms`)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.temporaryExpressionDurationMs === ms
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_secondary'))
          .backgroundColor(this.temporaryExpressionDurationMs === ms
            ? $r('app.color.app_surface_2')
            : $r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(28)
          .layoutWeight(1)
          .onClick(() => {
            this.temporaryExpressionDurationMs = ms;
          })
      }, (ms: number) => `${ms}`)
    }
    .width('100%')
    .margin({ bottom: 12 })

    // 恢复策略
    Text('恢复策略')
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
      .margin({ bottom: 4 })

    Row({ space: 8 }) {
      ForEach(['PREVIOUS', 'RESET'], (policy: string) => {
        Button(policy)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.temporaryExpressionRestorePolicy === policy
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_secondary'))
          .backgroundColor(this.temporaryExpressionRestorePolicy === policy
            ? $r('app.color.app_surface_2')
            : $r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(28)
          .layoutWeight(1)
          .onClick(() => {
            this.temporaryExpressionRestorePolicy = policy;
          })
      }, (policy: string) => policy)
    }
    .width('100%')
    .margin({ bottom: 12 })

    // 操作按钮
    Row() {
      Button('播放临时表情')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .layoutWeight(1)
        .enabled(this.debugModelState === 'READY'
          && this.expressionManagerReady
          && this.selectedExpressionName.length > 0
          && !this.temporaryExpressionOperating)
        .onClick(() => {
          this.playTemporaryExpression(this.selectedExpressionName, this.selectedExpressionWeight);
        })

      Button('取消临时表情')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .layoutWeight(1)
        .margin({ left: 8 })
        .enabled(this.temporaryExpressionName.length > 0
          && !this.temporaryExpressionOperating)
        .onClick(() => {
          this.cancelTemporaryExpressionClick();
        })
    }
    .width('100%')
    .margin({ bottom: 8 })

    Row() {
      Button('刷新状态')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .layoutWeight(1)
        .enabled(this.debugModelState === 'READY'
          && !this.temporaryExpressionOperating)
        .onClick(() => {
          this.refreshTemporaryExpressionState();
        })
    }
    .width('100%')
    .margin({ bottom: 8 })

    // 错误显示
    if (this.temporaryExpressionErrorCode.length > 0) {
      Text(`错误: ${this.temporaryExpressionErrorCode}`)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 4 })
      if (this.temporaryExpressionErrorMessage.length > 0) {
        Text(this.temporaryExpressionErrorMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ bottom: 8 })
      }
    }
  }

  /**
   * Phase 3F-1: 统一演出测试区域。
   *
   * 操作:
   *   - 选择演出类型 (animation / pose / none)
   *   - 选择持续时间 (1000 / 2500 / 5000 ms)
   *   - 选择恢复策略 (DEFAULT_POSE / RESET / KEEP)
   *   - 选择业务表情 ID (可选)
   *   - 执行演出 / 停止演出
   *
   * 显示:
   *   - Performance State / Command ID / Motion Type / Motion ID /
   *     Expression ID / Expires At / Last Error
   */
  @Builder
  PerformanceSection() {
    Divider()
      .color($r('app.color.app_divider'))
      .margin({ top: 16, bottom: 16 })

    Text('统一演出测试 (Phase 3F-1)')
      .fontSize($r('app.float.app_font_subtitle'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.app_text_primary'))
      .margin({ bottom: 8 })

    Text('统一调度动作 / 姿势 / 临时表情, 到期按策略恢复。')
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
      .margin({ bottom: 12 })

    // 当前演出状态
    Row() {
      Text('Performance State:')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(this.performanceState)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.performanceState === 'ACTIVE'
          ? $r('app.color.model_settings_success')
          : (this.performanceState === 'FAILED' || this.performanceState === 'DISPOSED'
            ? $r('app.color.app_text_tertiary')
            : $r('app.color.app_text_primary')))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ bottom: 4 })

    Row() {
      Text('Command ID:')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(this.performanceCommandId.length > 0 ? this.performanceCommandId : '-')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ bottom: 4 })

    Row() {
      Text('Motion Type:')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(this.performanceMotionType.length > 0 ? this.performanceMotionType : '-')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ bottom: 4 })

    Row() {
      Text('Motion ID:')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(this.performanceMotionId.length > 0 ? this.performanceMotionId : '-')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ bottom: 4 })

    Row() {
      Text('Expression ID:')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(this.performanceExpressionId.length > 0 ? this.performanceExpressionId : '-')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ bottom: 4 })

    Row() {
      Text('Expires At:')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(this.performanceExpiresAt > 0 ? String(this.performanceExpiresAt) : '-')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ bottom: 4 })

    if (this.performanceLastErrorCode.length > 0) {
      Row() {
        Text('Last Error:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
        Text(this.performanceLastErrorCode)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ bottom: 4 })
    }

    Divider()
      .color($r('app.color.app_divider'))
      .margin({ top: 8, bottom: 12 })

    // 演出类型选择
    Text('演出类型')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_primary'))
      .margin({ bottom: 8 })

    Row({ space: 8 }) {
      ForEach(['animation', 'pose', 'none'] as ArkWebPerformanceMotionType[], (t: ArkWebPerformanceMotionType) => {
        Button(t)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.performanceTestMotionType === t
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_secondary'))
          .backgroundColor(this.performanceTestMotionType === t
            ? $r('app.color.app_surface_2')
            : $r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.performanceTestMotionType = t;
          })
      })
    }
    .width('100%')
    .margin({ bottom: 12 })

    // 持续时间选择
    Text('持续时间 (ms)')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_primary'))
      .margin({ bottom: 8 })

    Row({ space: 8 }) {
      ForEach([1000, 2500, 5000], (d: number) => {
        Button(String(d))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.performanceTestDurationMs === d
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_secondary'))
          .backgroundColor(this.performanceTestDurationMs === d
            ? $r('app.color.app_surface_2')
            : $r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.performanceTestDurationMs = d;
          })
      })
    }
    .width('100%')
    .margin({ bottom: 12 })

    // 恢复策略选择
    Text('恢复策略')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_primary'))
      .margin({ bottom: 8 })

    Row({ space: 8 }) {
      ForEach(['DEFAULT_POSE', 'RESET', 'KEEP'] as ArkWebPerformanceReturnPolicy[], (p: ArkWebPerformanceReturnPolicy) => {
        Button(p)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.performanceTestReturnPolicy === p
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_secondary'))
          .backgroundColor(this.performanceTestReturnPolicy === p
            ? $r('app.color.app_surface_2')
            : $r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .layoutWeight(1)
          .onClick(() => {
            this.performanceTestReturnPolicy = p;
          })
      })
    }
    .width('100%')
    .margin({ bottom: 12 })

    // 表情 ID 选择 (可选)
    Text('业务表情 ID (可选)')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_primary'))
      .margin({ bottom: 8 })

    Row({ space: 6 }) {
      Button('无')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.performanceTestExpressionId.length === 0
          ? $r('app.color.app_text_primary')
          : $r('app.color.app_text_secondary'))
        .backgroundColor(this.performanceTestExpressionId.length === 0
          ? $r('app.color.app_surface_2')
          : $r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .layoutWeight(1)
        .onClick(() => {
          this.performanceTestExpressionId = '';
        })
      ForEach(ArkWebExpressionAliasBusinessId.ALL, (id: string) => {
        Button(id)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.performanceTestExpressionId === id
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_secondary'))
          .backgroundColor(this.performanceTestExpressionId === id
            ? $r('app.color.app_surface_2')
            : $r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .layoutWeight(1)
          .onClick(() => {
            this.performanceTestExpressionId = id;
          })
      })
    }
    .width('100%')
    .margin({ bottom: 16 })

    // 执行 / 停止按钮
    Row({ space: 8 }) {
      Button('执行演出')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .layoutWeight(1)
        .enabled(this.performanceController !== null
          && !this.performanceOperating
          && this.debugModelState === 'READY')
        .onClick(() => {
          this.onExecutePerformanceClick();
        })
      Button('停止演出')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .layoutWeight(1)
        .enabled(this.performanceController !== null
          && !this.performanceOperating
          && this.performanceState !== 'IDLE'
          && this.performanceState !== 'DISPOSED')
        .onClick(() => {
          this.onStopPerformanceClick();
        })
    }
    .width('100%')
    .margin({ bottom: 8 })

    // ===== Phase 3F-2: AI 对话结果到演出指令的安全映射测试 =====
    Text('AI Hint 安全映射 (Phase 3F-2)')
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
      .margin({ top: 8, bottom: 4 })

    // 映射结果状态显示
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text('Accepted:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
        Text(this.dialogueLastAccepted ? 'YES' : 'NO')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.dialogueLastAccepted
            ? $r('app.color.model_settings_success')
            : $r('app.color.app_text_secondary'))
          .layoutWeight(1)
      }.width('100%')
      Row({ space: 8 }) {
        Text('Degraded:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
        Text(this.dialogueLastDegraded ? 'YES' : 'NO')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.dialogueLastDegraded
            ? $r('app.color.app_accent')
            : $r('app.color.app_text_secondary'))
          .layoutWeight(1)
      }.width('100%')
      Row({ space: 8 }) {
        Text('Cmd ID:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
        Text(this.dialogueLastCommandId.length > 0 ? this.dialogueLastCommandId : '-')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      if (this.dialogueLastWarnings.length > 0) {
        Row({ space: 8 }) {
          Text('Warnings:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
          Text(this.dialogueLastWarnings)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_accent'))
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
      }
      if (this.dialogueLastErrorCode.length > 0) {
        Row({ space: 8 }) {
          Text('Error:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
          Text(`${this.dialogueLastErrorCode}: ${this.dialogueLastErrorMessage}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
      }
    }
    .width('100%')
    .padding(8)
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_sm'))
    .margin({ bottom: 8 })

    // 执行安全映射示例按钮 (用当前选择生成结构化 Hint, 验证生命周期 + 映射 + 演出全链路)
    Button('执行安全映射示例')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_primary'))
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .height(40)
      .width('100%')
      .enabled(this.dialogueLifecycleController !== null
        && this.dialoguePerformanceMapper !== null
        && this.performanceController !== null
        && !this.dialogueOperating
        && !this.performanceOperating
        && this.debugModelState === 'READY')
      .onClick(() => {
        this.onExecuteDialogueMappingClick();
      })

    // ===== Phase 3F-3: 对话演出生命周期状态 =====
    Text('对话演出生命周期 (Phase 3F-3)')
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
      .margin({ top: 8, bottom: 4 })

    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text('Lifecycle State:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
        Text(this.dialoguePerformanceState)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      Row({ space: 8 }) {
        Text('Turn ID:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
        Text(this.dialoguePerformanceTurnId.length > 0 ? this.dialoguePerformanceTurnId : '-')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      Row({ space: 8 }) {
        Text('Lifecycle Cmd ID:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
        Text(this.dialoguePerformanceCommandId.length > 0 ? this.dialoguePerformanceCommandId : '-')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      if (this.dialoguePerformanceWarnings.length > 0) {
        Row({ space: 8 }) {
          Text('Lifecycle Warnings:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
          Text(this.dialoguePerformanceWarnings)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_accent'))
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
      }
      if (this.dialoguePerformanceErrorCode.length > 0) {
        Row({ space: 8 }) {
          Text('Lifecycle Error:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
          Text(`${this.dialoguePerformanceErrorCode}: ${this.dialoguePerformanceErrorMessage}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
      }
    }
    .width('100%')
    .padding(8)
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_sm'))
    .margin({ bottom: 8 })

    // 中断当前生命周期 (模拟用户中断 / 新消息替换)
    Button('中断对话演出')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_primary'))
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .height(40)
      .width('100%')
      .enabled(this.dialogueLifecycleController !== null
        && this.dialoguePerformanceState !== ArkWebDialogueLifecycleState.IDLE
        && this.dialoguePerformanceState !== ArkWebDialogueLifecycleState.DISPOSED
        && this.dialoguePerformanceState !== ArkWebDialogueLifecycleState.CANCELLED
        && this.dialoguePerformanceState !== ArkWebDialogueLifecycleState.COMPLETED
        && this.dialoguePerformanceState !== ArkWebDialogueLifecycleState.COMPLETED_WITHOUT_PERFORMANCE
        && this.dialoguePerformanceState !== ArkWebDialogueLifecycleState.FAILED)
      .onClick(() => {
        if (this.dialogueLifecycleController !== null) {
          this.dialogueLifecycleController.cancelCurrent('manual').then((): void => {
            this.syncDialogueLifecycleState();
          });
        }
      })
  }

  /**
   * Phase 3F-1: 执行演出按钮处理。
   *
   * 根据 performanceTestMotionType 选择 motionId:
   *   - animation → selectedActionId
   *   - pose → selectedPoseId
   *   - none → 空字符串
   *
   * 表情权重固定为 1 (满权重)。
   */
  private async onExecutePerformanceClick(): Promise<void> {
    if (this.performanceController === null) {
      this.performanceLastErrorCode = PerformanceErrorCode.CONTROLLER_DISPOSED;
      this.performanceLastErrorMessage = 'PerformanceController 未初始化';
      promptAction.showToast({ message: 'PerformanceController 未初始化' });
      return;
    }
    if (this.performanceOperating) {
      return;
    }
    if (this.debugModelState !== 'READY') {
      this.performanceLastErrorCode = PerformanceErrorCode.COMMAND_INVALID;
      this.performanceLastErrorMessage = `模型未就绪 (state=${this.debugModelState})`;
      promptAction.showToast({ message: '模型未就绪' });
      return;
    }

    // 根据 motionType 确定 motionId
    let motionId: string = '';
    if (this.performanceTestMotionType === 'animation') {
      motionId = this.selectedActionId;
      if (motionId.length === 0) {
        promptAction.showToast({ message: '请先选择一个动作' });
        return;
      }
    } else if (this.performanceTestMotionType === 'pose') {
      motionId = this.selectedPoseId;
      if (motionId.length === 0) {
        promptAction.showToast({ message: '请先选择一个姿势' });
        return;
      }
    }

    const commandId: string = `perf_${Date.now()}_${Math.floor(Math.random() * 10000)}`;
    const cmd: ArkWebAvatarPerformanceCommand = {
      commandId: commandId,
      motionType: this.performanceTestMotionType,
      motionId: motionId,
      expressionId: this.performanceTestExpressionId,
      expressionWeight: 1,
      durationMs: this.performanceTestDurationMs,
      interruptPolicy: 'REPLACE',
      returnPolicy: this.performanceTestReturnPolicy
    };

    this.performanceOperating = true;
    this.performanceLastErrorCode = '';
    this.performanceLastErrorMessage = '';
    try {
      console.info(`[Performance] execute: cmd=${commandId}, motionType=${cmd.motionType}, motionId=${motionId}, exp=${cmd.expressionId}, duration=${cmd.durationMs}, returnPolicy=${cmd.returnPolicy}`);
      const result: ArkWebPerformanceResult =
        await this.performanceController.executeCommand(cmd);
      this.syncPerformanceDebugState();
      if (result.success) {
        promptAction.showToast({
          message: `演出已启动: ${cmd.motionType}${motionId.length > 0 ? ' ' + motionId : ''} (${cmd.durationMs}ms, ${cmd.returnPolicy})`
        });
      } else {
        promptAction.showToast({
          message: `演出失败: ${result.errorCode}`
        });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.performanceLastErrorCode = PerformanceErrorCode.MOTION_APPLY_FAILED;
      this.performanceLastErrorMessage = msg;
      promptAction.showToast({ message: `演出异常: ${msg}` });
    } finally {
      this.performanceOperating = false;
    }
  }

  /**
   * Phase 3F-1: 停止演出按钮处理。
   *
   * 调用 PerformanceController.stopPerformance, 内部:
   *   - performanceGeneration++
   *   - 清除 restoreTimer
   *   - cancelTemporaryExpression + stopAnimation
   *   - state = IDLE
   */
  private async onStopPerformanceClick(): Promise<void> {
    if (this.performanceController === null) {
      return;
    }
    if (this.performanceOperating) {
      return;
    }
    this.performanceOperating = true;
    try {
      await this.performanceController.stopPerformance();
      this.syncPerformanceDebugState();
      promptAction.showToast({ message: '演出已停止' });
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      promptAction.showToast({ message: `停止异常: ${msg}` });
    } finally {
      this.performanceOperating = false;
    }
  }

  /**
   * Phase 3F-1: 同步 PerformanceController 调试状态到 @State。
   */
  private syncPerformanceDebugState(): void {
    if (this.performanceController === null) {
      this.performanceState = ArkWebPerformanceState.DISPOSED;
      return;
    }
    const debug: ArkWebPerformanceDebugState = this.performanceController.getDebugState();
    this.performanceState = debug.state;
    this.performanceGeneration = debug.performanceGeneration;
    this.performanceCommandId = debug.currentCommandId;
    this.performanceMotionType = debug.currentMotionType;
    this.performanceMotionId = debug.currentMotionId;
    this.performanceExpressionId = debug.currentExpressionId;
    this.performanceExpressionWeight = debug.currentExpressionWeight;
    this.performanceExpiresAt = debug.expiresAt;
    this.performanceRestoreTimerActive = debug.restoreTimerActive;
    this.performanceLastErrorCode = debug.lastErrorCode;
    this.performanceLastErrorMessage = debug.lastErrorMessage;
  }

  /**
   * Phase 3F-3: 助手最终消息完成回调入口。
   *
   * 由未来真实对话页面在助手最终消息完成时调用 (流式 token / partial / 思考过程不得调用)。
   * 当前 VRM Viewer 未接入真实对话系统, 此方法作为生命周期入口预留。
   *
   * 只传:
   *   - turnId: 对话轮次 ID (非空)
   *   - performanceHintJson: AI 返回的 Hint JSON (可为空字符串)
   *
   * 不传: 完整提示词 / 聊天历史 / 文件路径 / Provider URL / Three.js 对象 / 原始模型数据。
   *
   * 流程 (委托 LifecycleController):
   *   1. 验证 turnId 非空
   *   2. 相同 turnId 已提交则忽略
   *   3. lifecycleGeneration++
   *   4. 停止上一条演出
   *   5. 空 Hint → COMPLETED_WITHOUT_PERFORMANCE
   *   6. Mapper.mapJson()
   *   7. accepted=false → FAILED (不影响消息显示)
   *   8. accepted=true → PerformanceController.execute()
   *   9. 成功后 ACTIVE
   *
   * @param turnId 对话轮次 ID (非空)
   * @param performanceHintJson AI 返回的 Hint JSON (可为空字符串)
   */
  async onAssistantMessageFinalized(
    turnId: string,
    performanceHintJson: string
  ): Promise<void> {
    if (this.dialogueLifecycleController === null) {
      this.dialoguePerformanceErrorCode = 'DIALOGUE_LIFECYCLE_NOT_READY';
      this.dialoguePerformanceErrorMessage = 'LifecycleController 未初始化';
      return;
    }
    const activeModelId: string = this.activeModelId;
    await this.dialogueLifecycleController.submitFinalAssistantResult(
      turnId, performanceHintJson, activeModelId
    );
    this.syncDialogueLifecycleState();
  }

  /**
   * Phase 3F-2 / 3F-3: 执行 AI 对话结果到演出指令的安全映射。
   *
   * Phase 3F-3 起必须经过 LifecycleController, 不得绕过生命周期直接调用 Mapper。
   * 此方法保留为内部入口, 生成临时 turnId 后委托 LifecycleController。
   *
   * @param rawJson AI 返回的原始 JSON 字符串
   */
  async executeDialoguePerformanceHintJson(rawJson: string): Promise<void> {
    if (this.dialogueLifecycleController === null) {
      this.dialogueLastAccepted = false;
      this.dialogueLastErrorCode = 'DIALOGUE_LIFECYCLE_NOT_READY';
      this.dialogueLastErrorMessage = 'LifecycleController 未初始化';
      promptAction.showToast({ message: 'LifecycleController 未初始化' });
      return;
    }
    if (this.dialogueOperating) {
      return;
    }
    this.dialogueOperating = true;
    // 生成临时 turnId (手动测试用, 真实对话由 onAssistantMessageFinalized 传入)
    const turnId: string = `manual_${Date.now()}`;
    try {
      const accepted: boolean =
        await this.dialogueLifecycleController.submitFinalAssistantResult(
          turnId, rawJson, this.activeModelId
        );
      this.syncDialogueLifecycleState();
      // 同步映射层 UI 状态 (向后兼容现有调试显示)
      this.dialogueLastAccepted = accepted;
      this.dialogueLastDegraded =
        this.dialogueLifecycleController.getMappingDegraded();
      this.dialogueLastWarnings =
        this.dialogueLifecycleController.getMappingWarnings();
      this.dialogueLastCommandId =
        this.dialogueLifecycleController.getCurrentCommandId();
      const lifecycleErr: string =
        this.dialogueLifecycleController.getLastErrorCode();
      this.dialogueLastErrorCode = lifecycleErr;
      this.dialogueLastErrorMessage =
        this.dialogueLifecycleController.getLastErrorMessage();
      if (accepted) {
        const state: ArkWebDialogueLifecycleState =
          this.dialogueLifecycleController.getState();
        if (state === ArkWebDialogueLifecycleState.ACTIVE) {
          promptAction.showToast({
            message: `映射执行: ${this.dialogueLastCommandId}${this.dialogueLastDegraded ? ' (降级)' : ''}`
          });
        } else if (state === ArkWebDialogueLifecycleState.COMPLETED_WITHOUT_PERFORMANCE) {
          promptAction.showToast({ message: '空 Hint, 无演出' });
        }
      } else {
        promptAction.showToast({
          message: `映射失败: ${lifecycleErr}`
        });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.dialogueLastErrorCode = 'DIALOGUE_LIFECYCLE_THREW';
      this.dialogueLastErrorMessage = msg;
      promptAction.showToast({ message: `映射异常: ${msg}` });
    } finally {
      this.dialogueOperating = false;
    }
  }

  /**
   * Phase 3F-3: 同步 LifecycleController 状态到页面 UI 变量。
   */
  private syncDialogueLifecycleState(): void {
    if (this.dialogueLifecycleController === null) {
      this.dialoguePerformanceState = ArkWebDialogueLifecycleState.IDLE;
      this.dialoguePerformanceTurnId = '';
      this.dialoguePerformanceCommandId = '';
      this.dialoguePerformanceDegraded = false;
      this.dialoguePerformanceWarnings = '';
      this.dialoguePerformanceErrorCode = '';
      this.dialoguePerformanceErrorMessage = '';
      return;
    }
    this.dialoguePerformanceState = this.dialogueLifecycleController.getState();
    this.dialoguePerformanceTurnId =
      this.dialogueLifecycleController.getCurrentTurnId();
    this.dialoguePerformanceCommandId =
      this.dialogueLifecycleController.getCurrentCommandId();
    this.dialoguePerformanceDegraded =
      this.dialogueLifecycleController.getMappingDegraded();
    this.dialoguePerformanceWarnings =
      this.dialogueLifecycleController.getMappingWarnings();
    this.dialoguePerformanceErrorCode =
      this.dialogueLifecycleController.getLastErrorCode();
    this.dialoguePerformanceErrorMessage =
      this.dialogueLifecycleController.getLastErrorMessage();
  }

  /**
   * Phase 3F-2: "执行安全映射示例" 按钮处理。
   *
   * Phase 3F-3 起必须经过 LifecycleController, 不再直接调用 Mapper。
   * 用当前选择生成结构化 Hint JSON, 验证生命周期 + 映射 + 演出全链路。
   * 不引入 JSON 编辑器, 只测试映射链路。
   */
  private async onExecuteDialogueMappingClick(): Promise<void> {
    // 根据当前 performanceTestMotionType 选择 motionId
    let motionId: string = '';
    if (this.performanceTestMotionType === 'animation') {
      motionId = this.selectedActionId;
    } else if (this.performanceTestMotionType === 'pose') {
      motionId = this.selectedPoseId;
    }
    // 构造结构化 Hint (模拟 AI 返回)
    const hint: ArkWebDialoguePerformanceHint = {
      version: 1,
      motionType: this.performanceTestMotionType,
      motionId: motionId,
      expressionId: this.performanceTestExpressionId,
      expressionWeight: 1,
      durationMs: this.performanceTestDurationMs,
      returnPolicy: this.performanceTestReturnPolicy
    };
    const rawJson: string = JSON.stringify(hint);
    console.info(`[DialogueMapper] test hint: ${rawJson}`);
    await this.executeDialoguePerformanceHintJson(rawJson);
  }

  /**
   * Phase 3E-1: 表情列表项 Builder。
   */
  @Builder
  ExpressionListItem(exp: ArkWebAvailableExpression) {
    Row() {
      Column() {
        Row() {
          Text(exp.name)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .layoutWeight(1)
          if (exp.isPreset) {
            Text('预设')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .margin({ left: 4 })
          }
        }
        .width('100%')
        Text(`权重: ${exp.weight.toFixed(2)}`)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 选中指示
      Text(this.selectedExpressionName === exp.name ? '✓' : '')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .width(24)
        .textAlign(TextAlign.Center)

      // 选择按钮
      Button('选择')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor(this.selectedExpressionName === exp.name
          ? $r('app.color.app_surface_2')
          : $r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(28)
        .enabled(!this.expressionLoading)
        .onClick(() => {
          this.selectedExpressionName = exp.name;
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6, left: 8, right: 8 })
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
      // Final Acceptance UX Cleanup: 调试 Tab 采用默认折叠区域
      // 默认全部折叠, 点击 "展开" 才渲染详细状态

      // ===== 模型与资源诊断 =====
      this.DebugSectionHeader('模型与资源诊断', this.debugSectionModelExpanded, () => {
        this.debugSectionModelExpanded = !this.debugSectionModelExpanded;
      })
      if (this.debugSectionModelExpanded) {
        Column() {
          this.DebugRow('Viewer UI', this.viewerState === ArkWebViewerState.READY ? 'READY' : this.viewerState)
          this.DebugRow('Web Bridge', this.webLoaded ? 'READY' : 'PENDING')
          this.DebugRow('Three.js', this.viewerState === ArkWebViewerState.READY ? 'READY' : 'NOT LOADED')
          this.DebugRow('Scene', this.viewerState === ArkWebViewerState.READY ? 'READY' : 'NOT INITIALIZED')
          this.DebugRow('Camera', this.viewerState === ArkWebViewerState.READY ? 'READY' : 'NOT INITIALIZED')
          this.DebugRow('Frame Loop', this.viewerState === ArkWebViewerState.READY ? 'RUNNING' : 'STOPPED')
          this.DebugRow('Model', this.debugModelState)
          this.DebugRow('Model Name', this.debugModelDisplayName.length > 0 ? this.debugModelDisplayName : '-')
          this.DebugRow('Model Source', this.debugModelSource)
          this.DebugRow('Model Loaded', this.debugModelLoaded ? 'TRUE' : 'FALSE')
          this.DebugRow('Asset Library State',
            this.assetLibrary !== null && !this.assetLibrary.isDisposed() ? 'READY' : 'NOT_INITIALIZED')
          this.DebugRow('Asset Library Version', '1')
          this.DebugRow('Active Model ID',
            this.activeModelId.length > 0 ? this.activeModelId : '-')
          this.DebugRow('Active Model Name',
            this.activeModelDisplayName.length > 0 ? this.activeModelDisplayName : '-')
          this.DebugRow('Active Model Size',
            this.activeModelByteLength > 0 ? this.formatByteLength(this.activeModelByteLength) : '-')
          this.DebugRow('Model Storage', 'PERSISTENT')
          this.DebugRow('Model Restore State', this.modelRestoreState)
          if (this.modelRestoreErrorCode.length > 0) {
            this.DebugRow('Model Restore Error',
              this.modelRestoreErrorCode + ': ' + this.modelRestoreErrorMessage)
          }
          this.DebugRow('Legacy Model Migrated', this.legacyModelMigrated ? 'YES' : 'NO')
          this.DebugRow('Debug Test Cube', 'DISABLED')
          this.DebugRow('Environment State', this.environmentState)
          this.DebugRow('Environment Source', this.environmentSource)
          this.DebugRow('Environment Enabled', this.environmentEnabled ? 'YES' : 'NO')
          this.DebugRow('Skybox Visible', this.skyboxVisible ? 'YES' : 'NO')
          this.DebugRow('Environment Intensity', this.environmentIntensity.toFixed(2))
          if (this.environmentErrorCode.length > 0) {
            this.DebugRow('Environment Error',
              this.environmentErrorCode + ': ' + this.environmentErrorMessage)
          }
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
        }
        .width('100%')
        .padding({ left: 12 })
      }

      // ===== 相机诊断 =====
      this.DebugSectionHeader('相机诊断', this.debugSectionCameraExpanded, () => {
        this.debugSectionCameraExpanded = !this.debugSectionCameraExpanded;
      })
      if (this.debugSectionCameraExpanded) {
        Column() {
          this.DebugRow('Background', this.sceneBackgroundColor)
          this.DebugRow('Grid', this.sceneGridVisible ? 'ON' : 'OFF')
          this.DebugRow('Light Intensity', this.sceneLightIntensity.toFixed(2))
          this.DebugRow('Camera Controls', this.debugCameraControlsEnabled ? 'ENABLED' : 'DISABLED')
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
          this.DebugRow('Controls Min/Max Distance',
            this.debugCameraMinDistance.toFixed(3) + ' / ' + this.debugCameraMaxDistance.toFixed(3))
          this.DebugRow('Model Bounding Radius', this.debugCameraModelBoundingRadius.toFixed(3))
          this.DebugRow('Last Camera Clip Update', this.debugCameraLastClipUpdateReason)
          this.DebugRow('Camera Last Action', this.debugCameraLastAction)
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
        }
        .width('100%')
        .padding({ left: 12 })
      }

      // ===== 姿势运行时 =====
      this.DebugSectionHeader('姿势运行时', this.debugSectionPoseExpanded, () => {
        this.debugSectionPoseExpanded = !this.debugSectionPoseExpanded;
      })
      if (this.debugSectionPoseExpanded) {
        Column() {
          this.DebugRow('Pose System State', this.poseSystemState)
          this.DebugRow('Pose Count', String(this.poseAssets.length))
          this.DebugRow('Selected Pose ID',
            this.selectedPoseId.length > 0 ? this.selectedPoseId : '-')
          this.DebugRow('Applied Pose ID',
            this.appliedPoseId.length > 0 ? this.appliedPoseId : '-')
          this.DebugRow('Applied Pose Name',
            this.appliedPoseDisplayName.length > 0 ? this.appliedPoseDisplayName : '-')
          this.DebugRow('Pose Importing', this.poseImporting ? 'YES' : 'NO')
          this.DebugRow('Pose Applying', this.poseApplying ? 'YES' : 'NO')
          this.DebugRow('Pose Applied Bones', String(this.poseAppliedBoneCount))
          this.DebugRow('Pose Ignored Bones', String(this.poseIgnoredBoneCount))
          if (this.poseLastErrorCode.length > 0) {
            this.DebugRow('Pose Last Error',
              this.poseLastErrorCode + ': ' + this.poseLastErrorMessage)
          }
          if (this.poseLibraryErrorCode.length > 0) {
            this.DebugRow('Pose Library Error',
              this.poseLibraryErrorCode + ': ' + this.poseLibraryErrorMessage)
          }
          this.DebugRow('Default Pose ID',
            this.defaultPoseId.length > 0 ? this.defaultPoseId : '-')
          this.DebugRow('Default Pose Name',
            this.defaultPoseDisplayName.length > 0 ? this.defaultPoseDisplayName : '-')
          this.DebugRow('Default Pose Restore State', this.defaultPoseRestoreState)
          this.DebugRow('Default Pose Restore In Progress',
            this.defaultPoseRestoreInProgress ? 'YES' : 'NO')
          if (this.defaultPoseRestoreErrorCode.length > 0) {
            this.DebugRow('Default Pose Restore Error',
              this.defaultPoseRestoreErrorCode + ': ' + this.defaultPoseRestoreErrorMessage)
          }
        }
        .width('100%')
        .padding({ left: 12 })
      }

      // ===== 动画运行时 =====
      this.DebugSectionHeader('动画运行时', this.debugSectionAnimationExpanded, () => {
        this.debugSectionAnimationExpanded = !this.debugSectionAnimationExpanded;
      })
      if (this.debugSectionAnimationExpanded) {
        Column() {
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
          this.DebugRow('Animation Resource ID',
            this.debugAnimationResourceId.length > 0 ? this.debugAnimationResourceId : '-')
          this.DebugRow('Animation Load Gen',
            this.debugAnimationLoadGeneration > 0 ? String(this.debugAnimationLoadGeneration) : '-')
          if (this.debugAnimationErrorCode.length > 0) {
            this.DebugRow('Animation Error', `${this.debugAnimationErrorCode}: ${this.debugAnimationErrorMessage}`)
          }
          this.DebugRow('VRMA Dependency', this.debugAnimationDependencyAvailable ? 'READY' : 'NOT READY')
          this.DebugRow('three-vrm-animation Version',
            this.debugAnimationDependencyVersion.length > 0 ? this.debugAnimationDependencyVersion : '-')
          this.DebugRow('VRMAnimationLoaderPlugin', this.debugAnimationLoaderAvailable ? 'READY' : 'NOT READY')
          this.DebugRow('createVRMAnimationClip', this.debugAnimationClipFactoryAvailable ? 'READY' : 'NOT READY')
          this.DebugRow('Runtime Network', this.debugAnimationRuntimeNetworkRequired ? 'YES (FAIL)' : 'NO (OK)')
          this.DebugRow('Humanoid', 'NOT INITIALIZED')
          this.DebugRow('Spring Bone', 'NOT INITIALIZED')
          this.DebugRow('Detail', this.viewerDetail)
        }
        .width('100%')
        .padding({ left: 12 })
      }

      // ===== 表情运行时 =====
      this.DebugSectionHeader('表情运行时', this.debugSectionExpressionExpanded, () => {
        this.debugSectionExpressionExpanded = !this.debugSectionExpressionExpanded;
      })
      if (this.debugSectionExpressionExpanded) {
        Column() {
          this.DebugRow('Expression State', this.expressionState)
          this.DebugRow('Expression Manager Ready', this.expressionManagerReady ? 'YES' : 'NO')
          this.DebugRow('Available Expression Count', String(this.availableExpressions.length))
          this.DebugRow('Current Expression Name',
            this.appliedExpressionName.length > 0 ? this.appliedExpressionName : '-')
          this.DebugRow('Current Expression Weight', this.appliedExpressionWeight.toFixed(2))
          if (this.expressionErrorCode.length > 0) {
            this.DebugRow('Expression Error Code', this.expressionErrorCode)
            this.DebugRow('Expression Error Message', this.expressionErrorMessage)
          }
          this.DebugRow('Lip Sync Channels Preserved', this.expressionLipSyncPreserved ? 'YES' : 'NO')
          // 临时表情测试 (已从主功能 Tab 移入调试 Tab)
          this.TemporaryExpressionSection()
        }
        .width('100%')
        .padding({ left: 12 })
      }

      // ===== 统一演出 =====
      this.DebugSectionHeader('统一演出', this.debugSectionPerformanceExpanded, () => {
        this.debugSectionPerformanceExpanded = !this.debugSectionPerformanceExpanded;
      })
      if (this.debugSectionPerformanceExpanded) {
        Column() {
          this.DebugRow('Performance State', this.performanceState)
          this.DebugRow('Performance Command ID',
            this.performanceCommandId.length > 0 ? this.performanceCommandId : '-')
          this.DebugRow('Performance Motion Type',
            this.performanceMotionType.length > 0 ? this.performanceMotionType : '-')
          this.DebugRow('Performance Motion ID',
            this.performanceMotionId.length > 0 ? this.performanceMotionId : '-')
          this.DebugRow('Performance Expression ID',
            this.performanceExpressionId.length > 0 ? this.performanceExpressionId : '-')
          this.DebugRow('Performance Expires At',
            this.performanceExpiresAt > 0 ? String(this.performanceExpiresAt) : '-')
          this.DebugRow('Performance Generation', String(this.performanceGeneration))
          this.DebugRow('Performance Restore Timer Active',
            this.performanceRestoreTimerActive ? 'YES' : 'NO')
          if (this.performanceLastErrorCode.length > 0) {
            this.DebugRow('Performance Last Error',
              this.performanceLastErrorCode + ': ' + this.performanceLastErrorMessage)
          }
          // 统一演出测试 UI (含 AI Hint 安全映射, 已从主功能 Tab 移入调试 Tab)
          this.PerformanceSection()
        }
        .width('100%')
        .padding({ left: 12 })
      }

      // ===== 对话生命周期 =====
      this.DebugSectionHeader('对话生命周期', this.debugSectionLifecycleExpanded, () => {
        this.debugSectionLifecycleExpanded = !this.debugSectionLifecycleExpanded;
      })
      if (this.debugSectionLifecycleExpanded) {
        Column() {
          this.DebugRow('Lifecycle State', this.dialoguePerformanceState)
          this.DebugRow('Lifecycle Turn ID',
            this.dialoguePerformanceTurnId.length > 0 ? this.dialoguePerformanceTurnId : '-')
          this.DebugRow('Lifecycle Command ID',
            this.dialoguePerformanceCommandId.length > 0 ? this.dialoguePerformanceCommandId : '-')
          this.DebugRow('Lifecycle Degraded', this.dialoguePerformanceDegraded ? 'YES' : 'NO')
          this.DebugRow('Lifecycle Operating', this.dialogueOperating ? 'YES' : 'NO')
          this.DebugRow('Dialogue Last Accepted', this.dialogueLastAccepted ? 'YES' : 'NO')
          this.DebugRow('Dialogue Last Degraded', this.dialogueLastDegraded ? 'YES' : 'NO')
          this.DebugRow('Dialogue Last Command ID',
            this.dialogueLastCommandId.length > 0 ? this.dialogueLastCommandId : '-')
          if (this.dialogueLastWarnings.length > 0) {
            this.DebugRow('Dialogue Last Warnings', this.dialogueLastWarnings)
          }
          if (this.dialogueLastErrorCode.length > 0) {
            this.DebugRow('Dialogue Last Error',
              this.dialogueLastErrorCode + ': ' + this.dialogueLastErrorMessage)
          }
          if (this.dialoguePerformanceWarnings.length > 0) {
            this.DebugRow('Lifecycle Warnings', this.dialoguePerformanceWarnings)
          }
          if (this.dialoguePerformanceErrorCode.length > 0) {
            this.DebugRow('Lifecycle Error',
              this.dialoguePerformanceErrorCode + ': ' + this.dialoguePerformanceErrorMessage)
          }
        }
        .width('100%')
        .padding({ left: 12 })
      }

      // 最近错误 (仅在真实错误存在时显示)
      if (this.lastError.length > 0) {
        Text(`Error [${this.lastErrorCode}]: ${this.lastError}`)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .margin({ top: 12 })
          .width('100%')
      }

      // 刷新诊断 / 清除诊断 按钮
      Button('刷新诊断')
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
          this.refreshAvailableExpressions();
        })

      Button('清除诊断')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .width('100%')
        .margin({ top: 8 })
        .onClick(() => {
          this.lastError = '';
          this.lastErrorCode = '';
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * Final Acceptance UX Cleanup: 调试 Tab 折叠区域标题行。
   *
   * 使用页面状态 + 普通按钮实现折叠, 不引入新 ArkUI API。
   * 默认全部折叠, 点击 "展开"/"收起" 切换。
   */
  @Builder
  DebugSectionHeader(title: string, expanded: boolean, onToggle: () => void) {
    Row() {
      Text(title)
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .layoutWeight(1)
      Button(expanded ? '收起' : '展开')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(28)
        .onClick(() => {
          onToggle();
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 8 })
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
