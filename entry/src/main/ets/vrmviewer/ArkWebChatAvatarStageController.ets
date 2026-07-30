/**
 * ArkWebChatAvatarStageController — 单人聊天页面透明 Avatar Stage 控制器 (Phase 4B-1R)
 *
 * 职责:
 *   - 创建聊天页面专用 ArkWeb 实例 (复用 ArkWebVrmViewerController)
 *   - 加载本地 vrmviewer 页面 (与 VrmViewerPage 相同的 rawfile 资源)
 *   - onPageEnd 后等待 Viewer READY → setRenderProfile('CHAT_STAGE') → 确认 → startActiveModelRestore
 *   - 严格初始化顺序: init → Web.onControllerAttached → Web.onPageEnd → Viewer READY → Profile → AssetLibrary → Restore
 *   - active model 恢复链路: ensureInitialized → findActiveModel → validateModelFile → registerPersistentAsset →
 *     prepareModelResource → getPreparedModelResource 回读 → probePreparedModelResource → 轮询 VERIFIED →
 *     loadPreparedModelResource → 轮询 READY → MODEL_READY → fitAvatarFullBody
 *   - 维护详细运行时状态 (stageState / viewerState / modelState / renderProfile / size / errorCode)
 *   - 注册 Avatar endpoint 到 ArkWebAvatarChatBridge (覆盖式)
 *   - 提供 getCapabilitySnapshot / cancelPerformance / reloadActiveModel 给 AI 面板调用
 *
 * 不做的事:
 *   - 不复制 VRM Loader / AnimationMixer / ExpressionManager 等底层实现
 *   - 不修改背景图片 / Scene 背景色 (透明由 Web 端 CHAT_STAGE profile 完成)
 *   - 不实现真实 AI Tool Calling / 镜头导演 / 脸部特写
 *   - 不创建 setInterval 永久轮询 (仅有限次数的 readiness polling)
 *   - 不把 loadPreparedModelResource 返回 success 等同于 MODEL_READY
 *
 * 复用模块:
 *   - ArkWebVrmViewerController (Web 实例 + Bridge 注册 + Viewer 状态机)
 *   - ArkWebAvatarAssetLibrary (持久化资产目录读取)
 *   - ArkWebPersistentModelStore (模型文件验证)
 *   - ArkWebModelResourceProvider (资源 URL 注册)
 *   - ArkWebAvatarPerformanceController (演出执行)
 *   - ArkWebVrmViewerPagePerformanceRuntime (Runtime 回调)
 *   - ArkWebDialoguePerformanceMapper (Hint → Command 映射)
 *   - ArkWebDialoguePerformanceLifecycleController (生命周期)
 *   - ArkWebAvatarAiCapabilityCatalog (能力快照)
 *   - ArkWebAvatarChatBridge (应用级桥接器单例)
 *
 * 生命周期:
 *   - ChatAvatarStage aboutToAppear → init(ctx)
 *   - Web 组件 onControllerAttached → onWebControllerAttached()
 *   - Web 组件 onPageEnd → onWebPageEnd()
 *   - Viewer READY → onViewerReady() (setRenderProfile + startActiveModelRestore)
 *   - 模型 READY → fitAvatarFullBody + 刷新能力快照
 *   - ChatAvatarStage aboutToDisappear → dispose()
 *
 * Reference:
 *   - AGENTS.md Phase 4B-1R §初始化顺序 / §模型恢复 / §MODEL_READY 等待
 *   - VrmViewerPage.ets startActiveModelRestore / validateRegisterAndLoadPersistentAsset
 *     / ensurePreparedModelResource / tryAutoProbeResource / waitForProbeVerified
 *     / autoLoadCurrentModel / waitForLoadReady
 *   - ArkWebVrmViewerController.ets (Web 实例管理 + probe/load polling 接口)
 */

import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import {
  ArkWebViewerState,
  ArkWebRenderProfile
} from './ArkWebVrmViewerTypes';
import {
  ArkWebViewerEventListener,
  ArkWebVrmViewerController
} from './ArkWebVrmViewerController';
import { ArkWebAvatarAssetLibrary } from './ArkWebAvatarAssetLibrary';
import { ArkWebPersistentModelStore } from './ArkWebPersistentModelStore';
import { ArkWebPersistentPoseStore } from './ArkWebPersistentPoseStore';
import { ArkWebPersistentAnimationStore } from './ArkWebPersistentAnimationStore';
import {
  ArkWebAnimationResourceProvider,
  WebAnimationResource
} from './ArkWebAnimationResourceProvider';
import {
  ArkWebModelResourceProvider
} from './ArkWebModelResourceProvider';
import {
  WebModelResource
} from './ArkWebModelResourceTypes';
import {
  ArkWebAvatarModelAsset,
  ArkWebAvatarAnimationAsset
} from './ArkWebAvatarAssetTypes';
import {
  GltfDependencyState
} from './ArkWebModelImportTypes';
import {
  ArkWebAvatarPerformanceCommand,
  ArkWebPerformanceResult
} from './ArkWebAvatarPerformanceTypes';
import { ArkWebAvatarPerformanceController } from './ArkWebAvatarPerformanceController';
import {
  ArkWebVrmViewerPagePerformanceRuntime,
  ArkWebVrmViewerPagePerformanceRuntimeDeps
} from './ArkWebVrmViewerPagePerformanceRuntime';
import { ArkWebDialoguePerformanceMapper } from './ArkWebDialoguePerformanceMapper';
import {
  ArkWebDialoguePerformanceLifecycleController,
  ArkWebDialoguePerformanceLifecycleRuntime
} from './ArkWebDialoguePerformanceLifecycleController';
import { ArkWebAvatarAiCapabilityCatalog } from './ArkWebAvatarAiCapabilityCatalog';
import {
  ArkWebAvatarAiCapabilitySnapshot,
  ArkWebAvatarAiAnimationCapability,
  ArkWebAvatarAiPoseCapability
} from './ArkWebAvatarAiTypes';
import { ArkWebExpressionAliasBusinessId } from './ArkWebAvatarAssetTypes';
import {
  ArkWebAvatarChatBridge
} from '../services/avatar/ArkWebAvatarChatBridge';
import {
  ArkWebAvatarChatFinalResult,
  ArkWebAvatarChatFinalResultSource
} from '../services/avatar/ArkWebAvatarChatBridgeTypes';
import {
  ArkWebAvatarShotDirector
} from './ArkWebAvatarShotDirector';
import {
  ArkWebAvatarShot,
  ArkWebAvatarShotControlMode,
  ArkWebAvatarShotDirectorState,
  ArkWebAvatarShotRuntime,
  ArkWebAvatarShotRuntimeSnapshot
} from './ArkWebAvatarShotDirectorTypes';

const LOG_TAG: string = 'ChatAvatarStage';

/**
 * Stage 运行状态 (Phase 4B-1R §第一项)。
 *
 * 严格状态流转:
 *   CREATED
 *     ├─ init() → INITIALIZING
 *     └─ dispose() → DISPOSED
 *   INITIALIZING
 *     ├─ Web.onControllerAttached → WEB_LOADING
 *     └─ dispose() → DISPOSED
 *   WEB_LOADING
 *     ├─ Web.onPageEnd → WEB_READY
 *     └─ dispose() → DISPOSED
 *   WEB_READY
 *     ├─ Viewer READY → VIEWER_READY
 *     └─ dispose() → DISPOSED
 *   VIEWER_READY
 *     ├─ setRenderProfile(CHAT_STAGE) 成功 → PROFILE_READY
 *     └─ dispose() → DISPOSED
 *   PROFILE_READY
 *     ├─ AssetLibrary.ensureInitialized 成功 → ASSET_LIBRARY_READY
 *     └─ dispose() → DISPOSED
 *   ASSET_LIBRARY_READY
 *     ├─ findActiveModel → 有 → MODEL_RESOLVING
 *     └─ findActiveModel → 无 → EMPTY
 *   MODEL_RESOLVING
 *     ├─ validate + register + prepare + probe + load + READY 等待 → MODEL_LOADING
 *   MODEL_LOADING
 *     ├─ getPreparedModelLoadResult state=READY → MODEL_READY
 *     ├─ getPreparedModelLoadResult state=FAILED → FAILED
 *     └─ 超时 → FAILED
 *   MODEL_READY
 *     ├─ dispose() → DISPOSED
 *     └─ reloadActiveModel → MODEL_RESOLVING (generation++)
 *   EMPTY
 *     ├─ dispose() → DISPOSED
 *     └─ reloadActiveModel → MODEL_RESOLVING
 *   FAILED
 *     ├─ dispose() → DISPOSED
 *     └─ reloadActiveModel → MODEL_RESOLVING
 *   任意 → DISPOSED (dispose 调用,不可恢复)
 */
export type ArkWebChatAvatarStageState =
  'CREATED'
  | 'INITIALIZING'
  | 'WEB_LOADING'
  | 'WEB_READY'
  | 'VIEWER_READY'
  | 'PROFILE_READY'
  | 'ASSET_LIBRARY_READY'
  | 'MODEL_RESOLVING'
  | 'MODEL_LOADING'
  | 'MODEL_READY'
  | 'EMPTY'
  | 'FAILED'
  | 'DISPOSED';

/**
 * Stage 错误码 (Phase 4B-1R §第一项)。
 */
export class ArkWebChatAvatarStageErrorCode {
  static readonly CHAT_STAGE_CONTEXT_MISSING: string = 'CHAT_STAGE_CONTEXT_MISSING';
  static readonly CHAT_STAGE_WEB_NOT_READY: string = 'CHAT_STAGE_WEB_NOT_READY';
  static readonly CHAT_STAGE_VIEWER_NOT_READY: string = 'CHAT_STAGE_VIEWER_NOT_READY';
  static readonly CHAT_STAGE_PROFILE_FAILED: string = 'CHAT_STAGE_PROFILE_FAILED';
  static readonly CHAT_STAGE_ASSET_LIBRARY_FAILED: string = 'CHAT_STAGE_ASSET_LIBRARY_FAILED';
  static readonly CHAT_STAGE_ACTIVE_MODEL_EMPTY: string = 'CHAT_STAGE_ACTIVE_MODEL_EMPTY';
  static readonly CHAT_STAGE_MODEL_RECORD_MISSING: string = 'CHAT_STAGE_MODEL_RECORD_MISSING';
  static readonly CHAT_STAGE_MODEL_FILE_MISSING: string = 'CHAT_STAGE_MODEL_FILE_MISSING';
  static readonly CHAT_STAGE_PROVIDER_REGISTER_FAILED: string = 'CHAT_STAGE_PROVIDER_REGISTER_FAILED';
  static readonly CHAT_STAGE_MODEL_LOAD_FAILED: string = 'CHAT_STAGE_MODEL_LOAD_FAILED';
  static readonly CHAT_STAGE_MODEL_READY_TIMEOUT: string = 'CHAT_STAGE_MODEL_READY_TIMEOUT';
  static readonly CHAT_STAGE_SIZE_INVALID: string = 'CHAT_STAGE_SIZE_INVALID';
  static readonly CHAT_STAGE_FULL_BODY_FIT_FAILED: string = 'CHAT_STAGE_FULL_BODY_FIT_FAILED';
  static readonly CHAT_STAGE_RESTORE_STALE: string = 'CHAT_STAGE_RESTORE_STALE';
}

/**
 * Phase 4B-2R: loadAnimationResource 传给 Web 端的 JSON 载荷。
 *
 * 从 WebAnimationResource 提取核心字段, 序列化为 JSON 字符串,
 * 传给 ArkWebVrmViewerController.loadAnimationResource(resourceJson)。
 */
interface LoadAnimationResourcePayload {
  /** 受控内部 URL: https://ark-tavern.local/animation/<resourceId> */
  resourceUrl: string;
  /** 资源 ID (与缓存文件名一致) */
  resourceId: string;
  /** 用户可读显示名 */
  displayName: string;
  /** MIME 类型 (固定为 model/gltf-binary) */
  mimeType: string;
  /** 文件字节数 */
  size: number;
}

/**
 * Stage 运行时快照 (供 AI 面板诊断显示)。
 */
export interface ArkWebChatAvatarStageRuntimeSnapshot {
  stageState: ArkWebChatAvatarStageState;
  viewerState: string;
  modelState: string;
  renderProfile: string;
  activeModelId: string;
  activeModelDisplayName: string;
  resourceRegistered: boolean;
  stageWidth: number;
  stageHeight: number;
  lastErrorCode: string;
  lastErrorMessage: string;
  restoreGeneration: number;
  // Phase 4B-2R: AI 面板状态一致性扩展字段
  currentShot: string;
  currentActionId: string;
  currentActionDisplayName: string;
  animationRuntimeState: string;
  currentPoseId: string;
  currentPoseDisplayName: string;
  poseRuntimeState: string;
  currentExpressionId: string;
  currentExpressionActualName: string;
  expressionRuntimeState: string;
  lastPublishResult: string;
  lastPublishErrorCode: string;
  lastPublishErrorMessage: string;
  lastTurnId: string;
  defaultPoseRestored: boolean;
  chatFullBodyReferenceBoundsRecorded: boolean;
  // Phase 4B-2R2: 运行时诊断扩展字段
  /** 当前相机缩放倍率 (0.5~3.0) */
  cameraZoomMultiplier: number;
  /** 当前正在加载的动画 actionId (LOADING 时) */
  animationLoadActionId: string;
  /** 动画加载错误码 (失败时) */
  animationLoadErrorCode: string;
  /** 最后一次 Lifecycle 执行状态 */
  lastLifecycleState: string;
}

/**
 * Phase 4B-2R2: AI 面板演出真实执行结果。
 *
 * 不再将 Bridge 接受视为播放成功。面板必须等待真实 Lifecycle 执行结果。
 * - accepted: Bridge.publishFinalResult 是否接受 (true 表示已入队/投递)
 * - executed: Lifecycle.submitFinalAssistantResult 是否成功 (true 表示演出已开始执行)
 * - lifecycleState: 执行后 Lifecycle 状态
 * - animationState / poseState / expressionState: Runtime Debug State 快照
 * - errorCode / errorMessage: 失败时的错误信息
 *
 * 超时错误码: CHAT_PANEL_PERFORMANCE_TIMEOUT (35s)
 */
export interface ArkWebPanelPerformanceResult {
  /** Bridge.publishFinalResult 是否接受 */
  accepted: boolean;
  /** Lifecycle.submitFinalAssistantResult 是否成功执行 */
  executed: boolean;
  /** 当前 Turn ID */
  turnId: string;
  /** 当前 Command ID (Lifecycle 映射后, 失败时可能为空) */
  commandId: string;
  /** Lifecycle 执行后状态 */
  lifecycleState: string;
  /** 动画 Runtime 状态 (LOADING/READY/PLAYING/FAILED 等) */
  animationState: string;
  /** 姿势 Runtime 状态 (IDLE/APPLYING/APPLIED/FAILED 等) */
  poseState: string;
  /** 表情 Runtime 状态 (IDLE/APPLYING/APPLIED/EXPIRED/FAILED 等) */
  expressionState: string;
  /** 错误码 (失败时) */
  errorCode: string;
  /** 错误消息 (失败时) */
  errorMessage: string;
}

/**
 * Stage 事件监听器 (供 ChatAvatarStage 组件订阅状态变化)。
 */
export interface ChatAvatarStageEventListener {
  onStateChanged(state: ArkWebChatAvatarStageState, detail: string): void;
  onModelNameChanged(displayName: string): void;
}

/**
 * 模型加载轮询参数 (Phase 4B-1R §第四项)。
 *
 * - 间隔 100ms
 * - 总时长不超过 15 秒
 */
const MODEL_READY_POLL_INTERVAL_MS: number = 100;
const MODEL_READY_POLL_TOTAL_TIMEOUT_MS: number = 15000;

/**
 * 资源探测轮询参数 (与 VrmViewerPage 对齐)。
 */
const PROBE_POLL_INTERVAL_MS: number = 200;
const PROBE_POLL_TOTAL_TIMEOUT_MS: number = 4500;

/**
 * Phase 4B-2R: 聊天页面全身构图目标垂直占比。
 *
 * 取值 0.78 → 模型占安全区域高度约 78%, 头顶和脚部保留少量空间。
 * 不取 0.8+ 是为了避免极端姿势 (T-Pose 双臂展开) 时模型顶到边缘。
 *
 * 禁止:
 *   - 在动画每帧重新计算 Bounds
 *   - 根据当前动作伸展范围持续缩放镜头
 */
const CHAT_FULL_BODY_FILL_RATIO: number = 0.78;

/**
 * Phase 4B-2R2: 相机缩放倍率范围。
 *
 * 通过调整相机到目标点的距离实现视觉缩放, 不修改模型 transform。
 *   - 0.5: 模型视觉缩小至 1/2
 *   - 1.0: 默认 (无变化)
 *   - 3.0: 模型视觉放大 3 倍 (允许部分身体超出屏幕)
 *
 * 步进 0.1, 默认 1.0。
 */
const CHAT_CAMERA_ZOOM_MULTIPLIER_MIN: number = 0.5;
const CHAT_CAMERA_ZOOM_MULTIPLIER_MAX: number = 3.0;
const CHAT_CAMERA_ZOOM_MULTIPLIER_DEFAULT: number = 1.0;
const CHAT_CAMERA_ZOOM_MULTIPLIER_STEP: number = 0.1;

/**
 * Phase 4B-2R2: AI 面板演出真实执行结果等待超时 (毫秒)。
 *
 * 面板调用 publishPerformanceFromPanelAndWait 后, 等待 Lifecycle 真实执行结果的最长时间。
 * 超时后返回 CHAT_PANEL_PERFORMANCE_TIMEOUT 错误。
 * 取 35 秒 (大于动画 READY 等待超时 30 秒 + 执行开销)。
 */
const CHAT_PANEL_PERFORMANCE_TIMEOUT_MS: number = 35000;
const CHAT_PANEL_PERFORMANCE_TIMEOUT_ERROR: string = 'CHAT_PANEL_PERFORMANCE_TIMEOUT';

/**
 * Phase 4B-2R: 动画 READY 等待超时 (与 VrmViewerPage 对齐)。
 */
const ANIMATION_READY_WAIT_TIMEOUT_MS: number = 30000;
const ANIMATION_READY_POLL_INTERVAL_MS: number = 100;

/**
 * 单人聊天页面透明 Avatar Stage 控制器。
 */
export class ArkWebChatAvatarStageController implements ArkWebViewerEventListener {
  /** ArkWeb VRM Viewer 主控制器 (复用,不复制) */
  private arkWebController: ArkWebVrmViewerController = new ArkWebVrmViewerController();
  /** 持久化资产库 (独立实例,读取同一 filesDir 目录) */
  private assetLibrary: ArkWebAvatarAssetLibrary | null = null;
  /** 持久化模型存储 */
  private persistentModelStore: ArkWebPersistentModelStore | null = null;
  /** Phase 4B-2R: 持久化姿势存储 (与 VrmViewerPage 共用同一类, 支持姿势 JSON 读取) */
  private persistentPoseStore: ArkWebPersistentPoseStore | null = null;
  /** Phase 4B-2R: 持久化动画存储 (与 VrmViewerPage 共用同一类, 支持动画路径解析) */
  private persistentAnimationStore: ArkWebPersistentAnimationStore | null = null;
  /** Phase 4B-2R: 动画资源 Provider (与 VrmViewerPage 共用同一类) */
  private animationResourceProvider: ArkWebAnimationResourceProvider | null = null;
  /** 模型资源 Provider */
  private resourceProvider: ArkWebModelResourceProvider | null = null;
  /** 演出控制器 */
  private performanceController: ArkWebAvatarPerformanceController | null = null;
  /** 演出运行时 */
  private performanceRuntime: ArkWebVrmViewerPagePerformanceRuntime | null = null;
  /** 对话演出映射器 */
  private dialogueMapper: ArkWebDialoguePerformanceMapper | null = null;
  /** 对话演出生命周期控制器 */
  private dialogueLifecycle: ArkWebDialoguePerformanceLifecycleController | null = null;
  /** AI 能力目录 */
  private capabilityCatalog: ArkWebAvatarAiCapabilityCatalog | null = null;
  /** Phase 4B-2R: 缓存的能力快照 (供 resolveAnimationDisplayName / resolvePoseDisplayName 使用) */
  private cachedCapabilitySnapshot: ArkWebAvatarAiCapabilitySnapshot | null = null;
  /** Phase 4B-2: 镜头导演 (管理 FULL_BODY / FACE_RESET_VIEW 平滑切换) */
  private shotDirector: ArkWebAvatarShotDirector | null = null;

  // ===== 运行时状态 (Phase 4B-1R §第一项) =====

  /** 当前 Stage 状态 */
  private currentStageState: ArkWebChatAvatarStageState = 'CREATED';
  /** 状态详细描述 */
  private currentDetail: string = '已创建';
  /** Viewer 状态字符串 (来自 ArkWebViewerState) */
  private viewerStateStr: string = '';
  /** 模型状态字符串 (LOADING/READY/FAILED 等, 来自 getPreparedModelLoadResult) */
  private modelStateStr: string = 'NOT_REQUESTED';
  /** 当前渲染 Profile (VIEWER / CHAT_STAGE / 空字符串) */
  private renderProfileStr: string = '';
  /** 当前激活模型 ID (空字符串表示无) */
  private activeModelId: string = '';
  /** 当前激活模型显示名 */
  private activeModelDisplayName: string = '';
  /** Provider 是否已注册当前资源 */
  private resourceRegistered: boolean = false;
  /** Stage 宽度 (vp, 由组件 onAreaChange 报告) */
  private stageWidth: number = 0;
  /** Stage 高度 (vp, 由组件 onAreaChange 报告) */
  private stageHeight: number = 0;
  /** 当前模型 fillRatio (用户可通过滑动条调节, 默认 0.78) */
  private currentFillRatio: number = CHAT_FULL_BODY_FILL_RATIO;
  /** Phase 4B-2R2: 相机缩放倍率 (用户可通过滑动条调节, 默认 1.0)。
   *
   * 范围 0.5~3.0, 1.0 为默认。通过调整相机距离实现, 不修改模型 transform。
   * 在当前 ChatPage 生命周期内, 镜头切换 / 演出 / 停止 / 失败 / 模型隐藏重新显示
   * 都不会重置此倍率。仅在模型重新加载时恢复默认 1.0。
   */
  private cameraZoomMultiplier: number = CHAT_CAMERA_ZOOM_MULTIPLIER_DEFAULT;

  /**
   * Phase 4B-2R2: AI 面板演出真实执行结果 pending map。
   *
   * key: turnId
   * value: resolver 函数, 由 onBridgeFinalResult 在 Lifecycle 执行完成后调用。
   *
   * 不再将 Bridge 接受视为播放成功, 面板通过 publishPerformanceFromPanelAndWait
   * 等待真实 Lifecycle 执行结果。
   */
  private pendingPanelPerformanceResolvers: Map<string, (result: ArkWebPanelPerformanceResult) => void> =
    new Map<string, (result: ArkWebPanelPerformanceResult) => void>();
  /** 最近错误码 */
  private lastErrorCode: string = '';
  /** 最近错误消息 */
  private lastErrorMessage: string = '';
  /** 恢复代次 (用于过期判断) */
  private modelRestoreGeneration: number = 0;

  /** 事件监听器 (ChatAvatarStage 组件) */
  private eventListener: ChatAvatarStageEventListener | null = null;
  /** 是否已销毁 */
  private disposed: boolean = false;

  /** Avatar endpoint ID (覆盖式注册到 Bridge) */
  private avatarEndpointId: string = '';
  /** endpoint ID 计数器 (跨实例唯一) */
  private static endpointCounter: number = 0;

  /** Phase 4B-2R: 表情别名映射 (modelId → { businessId: actualExpressionName }) */
  private expressionAliasMap: Record<string, string> = {} as Record<string, string>;
  /** Phase 4B-2R: 动画调试状态字符串 (LOADING/READY/FAILED 等, 来自 getAnimationDebugState) */
  private debugAnimationStateStr: string = 'NOT_REQUESTED';
  /**
   * Phase 4B-2R2: 动画加载 Promise (single promise, 同 action 并发点击复用)。
   *
   * - 同 action 并发点击: 复用同一个 Promise, 不重复发起加载
   * - 不同 action 并发点击: 递增 generation, 启动新加载, 旧结果按 generation 丢弃
   * - READY/FAILED/超时: 清除 Promise, 允许再次点击
   *
   * 禁止永久卡在 LOADING: 失败后状态应为 FAILED 或 NOT_REQUESTED。
   */
  private animationLoadPromise: Promise<boolean> | null = null;
  /** Phase 4B-2R2: 当前 animationLoadPromise 对应的 actionId */
  private animationLoadActionId: string = '';
  /** Phase 4B-2R2: 动画加载代次 (防止旧加载结果覆盖新状态) */
  private animationLoadGeneration: number = 0;
  /** Phase 4B-2R2: 已加载完成的 actionId (Web state === READY 时记录, 允许直接播放) */
  private loadedActionId: string = '';
  /** Phase 4B-2R2: 动画加载错误码 (失败时记录, 供诊断显示) */
  private animationLoadErrorCode: string = '';
  /** Phase 4B-2R: AI 面板 Turn ID 递增计数器 (独立于 endpointCounter) */
  private static panelTurnIdCounter: number = 0;
  /** Phase 4B-2R: 页面实例 ID (用于 Turn ID 生成) */
  private pageInstanceId: string = '';
  /** Phase 4B-2R: 页面实例计数器 (跨实例唯一) */
  private static pageInstanceCounter: number = 0;

  // ===== Phase 4B-2R: AI 面板状态一致性 (Runtime Debug State) =====

  /** 当前动作 displayName (来自能力目录, 仅显示用) */
  private currentActionDisplayName: string = '';
  /** 当前动作 actionId (来自命令, 用于诊断) */
  private currentActionId: string = '';
  /** 当前姿势 displayName */
  private currentPoseDisplayName: string = '';
  /** 当前姿势 poseId */
  private currentPoseId: string = '';
  /** 当前表情业务 ID (neutral/happy/angry/sad/relaxed/surprised) */
  private currentExpressionId: string = '';
  /** 当前表情实际名称 (来自别名映射) */
  private currentExpressionActualName: string = '';
  /** 动画运行状态 (LOADING/READY/PLAYING/FAILED 等, 来自 getAnimationDebugState) */
  private animationRuntimeState: string = 'IDLE';
  /** 姿势运行状态 (IDLE/APPLYING/APPLIED/FAILED 等, 来自 getPoseDebugState) */
  private poseRuntimeState: string = 'IDLE';
  /** 表情运行状态 (IDLE/APPLYING/APPLIED/EXPIRED/FAILED 等, 来自 getExpressionDebugState) */
  private expressionRuntimeState: string = 'IDLE';
  /** 最后一次 publishFinalResult 返回值 (OK/REJECTED/THREW) */
  private lastPublishResult: string = '';
  /** 最后一次 publishFinalResult 错误码 */
  private lastPublishErrorCode: string = '';
  /** 最后一次 publishFinalResult 错误消息 */
  private lastPublishErrorMessage: string = '';
  /** 最后一次 Turn ID */
  private lastTurnId: string = '';
  /** Phase 4B-2R2: 最后一次 Lifecycle 执行状态 (供诊断显示) */
  private lastLifecycleState: string = 'IDLE';
  /** 模型 READY 后是否已恢复默认姿势 */
  private defaultPoseRestored: boolean = false;
  /** 稳定全身参考 Bounds 是否已记录 (模型 READY + 默认姿势恢复后) */
  private chatFullBodyReferenceBoundsRecorded: boolean = false;

  /** 模型恢复单次触发保护 (首次恢复启动后置 true, dispose 后重置) */
  private restoreStarted: boolean = false;
  /** 模型恢复进行中 */
  private modelRestoreInProgress: boolean = false;

  /** 已准备的资源 (供 loadPreparedModelResource 使用) */
  private preparedResource: WebModelResource | null = null;

  /** 是否已应用 CHAT_STAGE 渲染 Profile */
  private chatStageProfileApplied: boolean = false;

  /** init() 是否已完成 (创建依赖项) */
  private initCompleted: boolean = false;
  /** Web.onPageEnd 是否已触发 */
  private pageEndReceived: boolean = false;
  /** Viewer READY 是否已收到 */
  private viewerReadyReceived: boolean = false;
  /** restore 是否已被调度 (避免重复触发) */
  private restoreScheduled: boolean = false;

  constructor() {
    this.arkWebController.setEventListener(this);
  }

  // ===== 公共接口 =====

  /** 设置事件监听器。 */
  setEventListener(listener: ChatAvatarStageEventListener): void {
    this.eventListener = listener;
  }

  /** 获取 WebviewController,供 Web 组件使用。 */
  getWebviewController(): webview.WebviewController {
    return this.arkWebController.getWebviewController();
  }

  /** 获取当前 Stage 状态。 */
  getStageState(): ArkWebChatAvatarStageState {
    return this.currentStageState;
  }

  /** 获取状态详细描述。 */
  getDetail(): string {
    return this.currentDetail;
  }

  /** 获取当前激活模型显示名。 */
  getActiveModelDisplayName(): string {
    return this.activeModelDisplayName;
  }

  /** 获取当前激活模型 ID。 */
  getActiveModelId(): string {
    return this.activeModelId;
  }

  /** 获取 Stage 宽度 (vp)。 */
  getStageWidth(): number {
    return this.stageWidth;
  }

  /** 获取 Stage 高度 (vp)。 */
  getStageHeight(): number {
    return this.stageHeight;
  }

  /** 获取最近错误码。 */
  getLastErrorCode(): string {
    return this.lastErrorCode;
  }

  /** 获取最近错误消息。 */
  getLastErrorMessage(): string {
    return this.lastErrorMessage;
  }

  /**
   * 获取运行时快照 (供 AI 面板诊断显示)。
   */
  getRuntimeSnapshot(): ArkWebChatAvatarStageRuntimeSnapshot {
    let currentShot: string = 'IDLE';
    if (this.shotDirector !== null) {
      const snap: ArkWebAvatarShotRuntimeSnapshot = this.shotDirector.getRuntimeSnapshot();
      currentShot = snap.currentShot;
    }
    return {
      stageState: this.currentStageState,
      viewerState: this.viewerStateStr,
      modelState: this.modelStateStr,
      renderProfile: this.renderProfileStr,
      activeModelId: this.activeModelId,
      activeModelDisplayName: this.activeModelDisplayName,
      resourceRegistered: this.resourceRegistered,
      stageWidth: this.stageWidth,
      stageHeight: this.stageHeight,
      lastErrorCode: this.lastErrorCode,
      lastErrorMessage: this.lastErrorMessage,
      restoreGeneration: this.modelRestoreGeneration,
      currentShot: currentShot,
      currentActionId: this.currentActionId,
      currentActionDisplayName: this.currentActionDisplayName,
      animationRuntimeState: this.animationRuntimeState,
      currentPoseId: this.currentPoseId,
      currentPoseDisplayName: this.currentPoseDisplayName,
      poseRuntimeState: this.poseRuntimeState,
      currentExpressionId: this.currentExpressionId,
      currentExpressionActualName: this.currentExpressionActualName,
      expressionRuntimeState: this.expressionRuntimeState,
      lastPublishResult: this.lastPublishResult,
      lastPublishErrorCode: this.lastPublishErrorCode,
      lastPublishErrorMessage: this.lastPublishErrorMessage,
      lastTurnId: this.lastTurnId,
      defaultPoseRestored: this.defaultPoseRestored,
      chatFullBodyReferenceBoundsRecorded: this.chatFullBodyReferenceBoundsRecorded,
      cameraZoomMultiplier: this.cameraZoomMultiplier,
      animationLoadActionId: this.animationLoadActionId,
      animationLoadErrorCode: this.animationLoadErrorCode,
      lastLifecycleState: this.lastLifecycleState
    };
  }

  /**
   * 报告 Stage 尺寸变化 (由 ChatAvatarStage 组件 onAreaChange 调用)。
   *
   * 用于:
   *   - 记录 stageWidth / stageHeight
   *   - 尺寸有效且 MODEL_READY 时重新 fitAvatarFullBody (尺寸阈值过滤由组件层处理)
   */
  setStageSize(width: number, height: number): void {
    this.stageWidth = width;
    this.stageHeight = height;
    if (width <= 0 || height <= 0) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_SIZE_INVALID;
      this.lastErrorMessage = `size invalid: ${width}x${height}`;
      return;
    }
    // 清除尺寸无效错误
    if (this.lastErrorCode === ArkWebChatAvatarStageErrorCode.CHAT_STAGE_SIZE_INVALID) {
      this.lastErrorCode = '';
      this.lastErrorMessage = '';
    }
    // MODEL_READY 时尺寸变化触发重新构图 (component 层已做阈值过滤)
    if (this.currentStageState === 'MODEL_READY' && !this.disposed) {
      this.fitFullBodyInternal().catch((e: Object): void => {
        console.warn(LOG_TAG, 'refit on size change failed: ' +
          (e instanceof Error ? e.message : String(e)));
      });
    }
  }

  /**
   * 重新加载当前 active model (Phase 4B-1R §第八项)。
   *
   * 流程:
   *   1. generation++ (使旧异步任务过期)
   *   2. 清理 restoreStarted / restoreScheduled
   *   3. 重新执行 startActiveModelRestore()
   *
   * 不删除持久模型 / library.json。
   */
  async reloadActiveModel(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.modelRestoreInProgress) {
      console.warn(LOG_TAG, 'reloadActiveModel: restore in progress, skip');
      return;
    }
    console.info(LOG_TAG, 'reloadActiveModel: generation++');
    this.modelRestoreGeneration++;
    this.restoreStarted = false;
    this.restoreScheduled = false;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    this.preparedResource = null;
    this.resourceRegistered = false;
    await this.startActiveModelRestore();
  }

  /**
   * 初始化控制器 (Phase 4B-1R §第二项 严格初始化顺序 步骤 1-3)。
   *
   * 流程:
   *   1. 创建 AssetLibrary / PersistentModelStore / Provider / Lifecycle
   *   2. 注册 Avatar endpoint
   *   3. 标记 initCompleted
   *
   * 不在此处启动模型恢复 (等待 Web.onPageEnd + Viewer READY)。
   */
  init(ctx: common.UIAbilityContext): void {
    if (this.disposed) {
      return;
    }
    if (this.initCompleted) {
      return;
    }
    if (ctx === null || ctx === undefined) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_CONTEXT_MISSING;
      this.lastErrorMessage = 'init ctx is null/undefined';
      this.setStageState('FAILED', 'context missing');
      return;
    }
    this.setStageState('INITIALIZING', '正在初始化依赖');

    // Phase 4B-2R: 生成页面实例 ID (用于 Turn ID 唯一性)
    if (this.pageInstanceId.length === 0) {
      ArkWebChatAvatarStageController.pageInstanceCounter++;
      this.pageInstanceId = `${ArkWebChatAvatarStageController.pageInstanceCounter}`;
    }
    // 1. 创建持久化资产库 (独立实例, 读取同一 filesDir 目录)
    if (this.assetLibrary === null) {
      this.assetLibrary = new ArkWebAvatarAssetLibrary(ctx);
    }
    // 2. 创建持久化模型存储
    if (this.persistentModelStore === null && this.assetLibrary !== null) {
      this.persistentModelStore = new ArkWebPersistentModelStore(ctx, this.assetLibrary);
    }
    // 3. 创建资源 Provider (使用 cacheDir, 与 VrmViewerPage 一致)
    if (this.resourceProvider === null) {
      this.resourceProvider = new ArkWebModelResourceProvider(ctx.cacheDir);
    }
    // 配置 Provider 接受 filesDir/avatar-assets/ 下的持久化模型
    if (this.resourceProvider !== null && this.assetLibrary !== null) {
      this.resourceProvider.setPersistentRootDir(this.assetLibrary.getAssetsRootDir());
    }

    // 4. Phase 4B-2R: 创建持久化姿势/动画存储 + 动画资源 Provider
    //    (与 VrmViewerPage 共用同一类, 不复制 JSON 解析 / VRMA 加载轮询逻辑)
    if (this.persistentPoseStore === null && this.assetLibrary !== null) {
      this.persistentPoseStore = new ArkWebPersistentPoseStore(ctx, this.assetLibrary);
    }
    if (this.persistentAnimationStore === null && this.assetLibrary !== null) {
      this.persistentAnimationStore = new ArkWebPersistentAnimationStore(ctx, this.assetLibrary);
    }
    if (this.animationResourceProvider === null) {
      this.animationResourceProvider = new ArkWebAnimationResourceProvider(ctx.cacheDir);
    }
    if (this.animationResourceProvider !== null && this.assetLibrary !== null) {
      this.animationResourceProvider.setPersistentRootDir(this.assetLibrary.getAssetsRootDir());
    }

    // 5. Phase 4B-2R: 创建演出运行时 (复用 ArkWebVrmViewerPagePerformanceRuntime,
    //    与 VrmViewerPage 共用同一执行算法, 实现运行时一致性)
    if (this.performanceRuntime === null) {
      const self: ArkWebChatAvatarStageController = this;
      const deps: ArkWebVrmViewerPagePerformanceRuntimeDeps = {
        getArkWebController: (): ArkWebVrmViewerController | null => self.arkWebController,
        getAssetLibrary: (): ArkWebAvatarAssetLibrary | null => self.assetLibrary,
        getPersistentPoseStore: (): ArkWebPersistentPoseStore | null => self.persistentPoseStore,
        getExpressionAliasMap: (): Record<string, string> => self.expressionAliasMap,
        getDebugAnimationState: (): string => self.debugAnimationStateStr,
        loadAnimationByActionId: (actionId: string): Promise<boolean> =>
          self.loadAnimationByActionId(actionId),
        waitForAnimationReady: (timeoutMs: number): Promise<boolean> =>
          self.waitForAnimationReady(timeoutMs),
        resetPoseInternal: (): Promise<boolean> => self.resetPoseInternal(),
        applyPoseByIdInternal: (poseId: string): Promise<boolean> =>
          self.applyPoseByIdInternal(poseId)
      };
      this.performanceRuntime = new ArkWebVrmViewerPagePerformanceRuntime(deps);
    }

    // 5. 创建演出控制器
    if (this.performanceController === null
        && this.assetLibrary !== null
        && this.performanceRuntime !== null) {
      this.performanceController =
        new ArkWebAvatarPerformanceController(this.assetLibrary, this.performanceRuntime);
    }

    // 6. 创建映射器 + 生命周期控制器
    if (this.dialogueMapper === null && this.assetLibrary !== null) {
      this.dialogueMapper = new ArkWebDialoguePerformanceMapper(this.assetLibrary);
    }
    if (this.dialogueLifecycle === null
        && this.dialogueMapper !== null
        && this.performanceController !== null) {
      const self: ArkWebChatAvatarStageController = this;
      const lifecycleRuntime: ArkWebDialoguePerformanceLifecycleRuntime = {
        stopPerformance: (): Promise<boolean> => {
          if (self.performanceController === null) {
            return Promise.resolve(false);
          }
          return self.performanceController.stopPerformance().then((ok: boolean): boolean => {
            // Phase 4B-2: 停止演出后通知 ShotDirector 恢复 FULL_BODY
            if (ok && self.shotDirector !== null) {
              self.shotDirector.onPerformanceStopped('PERFORMANCE_STOPPED')
                .catch((e: Object): void => {
                  console.warn(LOG_TAG, 'shotDirector.onPerformanceStopped threw: ' +
                    (e instanceof Error ? e.message : String(e)));
                });
            }
            return ok;
          });
        },
        executePerformance: (cmd: ArkWebAvatarPerformanceCommand): Promise<boolean> => {
          if (self.performanceController === null) {
            return Promise.resolve(false);
          }
          // Phase 4B-2: 镜头准备成功后才执行演出
          const preparePromise: Promise<boolean> = self.shotDirector !== null
            ? self.shotDirector.prepareForCommand(cmd)
            : Promise.resolve(true);
          return preparePromise.then((prepareOk: boolean): Promise<boolean> => {
            if (!prepareOk) {
              console.warn(LOG_TAG, 'shotDirector.prepareForCommand failed, skip performance');
              return Promise.resolve(false);
            }
            return self.performanceController!.executeCommand(cmd).then(
              (result: ArkWebPerformanceResult): boolean => {
                // Phase 4B-2: 演出失败通知 ShotDirector 恢复 FULL_BODY
                if (!result.success && self.shotDirector !== null) {
                  self.shotDirector.onPerformanceFailed('PERFORMANCE_EXECUTE_FAILED')
                    .catch((e: Object): void => {
                      console.warn(LOG_TAG, 'shotDirector.onPerformanceFailed threw: ' +
                        (e instanceof Error ? e.message : String(e)));
                    });
                }
                return result.success;
              }
            );
          });
        }
      };
      this.dialogueLifecycle =
        new ArkWebDialoguePerformanceLifecycleController(this.dialogueMapper, lifecycleRuntime);
    }

    // 7. 创建 AI 能力目录
    if (this.capabilityCatalog === null && this.assetLibrary !== null) {
      this.capabilityCatalog = new ArkWebAvatarAiCapabilityCatalog(this.assetLibrary);
    }

    // 7.5 Phase 4B-2: 创建镜头导演
    if (this.shotDirector === null) {
      const self: ArkWebChatAvatarStageController = this;
      const shotRuntime: ArkWebAvatarShotRuntime = {
        transitionToFullBody: (): Promise<boolean> => self.shotTransitionToFullBody(),
        transitionToResetView: (): Promise<boolean> => self.shotTransitionToResetView(),
        cancelCameraTransition: (reason: string): Promise<boolean> =>
          self.shotCancelCameraTransition(reason),
        isModelReady: (): boolean => self.currentStageState === 'MODEL_READY',
        isStageSizeValid: (): boolean => self.stageWidth > 0 && self.stageHeight > 0
      };
      this.shotDirector = new ArkWebAvatarShotDirector(shotRuntime);
    }

    // 8. 注册 Avatar endpoint 到 Bridge (覆盖式)
    this.registerAvatarEndpoint();

    this.initCompleted = true;
    console.info(LOG_TAG, 'init completed');
    // AssetLibrary 不在此处 ensureInitialized, 留待 startActiveModelRestore
  }

  /**
   * Web 组件 onControllerAttached 回调入口。
   */
  onWebControllerAttached(): void {
    if (this.disposed) {
      return;
    }
    this.arkWebController.onControllerAttached();
  }

  /**
   * Phase 4B-1R 修复: Web 组件 onInterceptRequest 资源拦截入口。
   *
   * ChatAvatarStage Web 组件必须设置 onInterceptRequest,
   * 将 ark-tavern.local 资源请求映射到本地缓存文件。
   * 缺少此拦截会导致 ModelResourceProvider 注册的 URL 无法被 Web 端访问,
   * 资源探测 (probePreparedModelResource) 失败, 模型不可见。
   *
   * Phase 4B-2R2 修复: 必须同时拦截 AnimationResourceProvider 注册的 URL,
   * 否则 Web 端请求动画资源时被放行, 触发 "Web page load error",
   * 导致动画状态变 FAILED, 演出执行失败 (DIALOGUE_LIFECYCLE_EXECUTE_FAILED)。
   *
   * @returns WebResourceResponse (拦截并返回本地文件) 或 null (放行,交由 Web 默认处理)
   */
  interceptResourceRequest(
    url: string,
    method: string,
    requestHeaders: Array<Header>
  ): WebResourceResponse | null {
    if (this.disposed) {
      return null;
    }
    // Phase 1D-2A: 模型资源拦截
    if (this.resourceProvider !== null && this.resourceProvider.matchesRequest(url)) {
      const result = this.resourceProvider.handleRequest(url, method, requestHeaders);
      if (result.response !== null) {
        return result.response;
      }
      console.warn(LOG_TAG,
        `model resource handleRequest returned null: ${result.errorCode} ${result.errorMessage}`);
      return null;
    }
    // Phase 4B-2R2: 动画资源拦截 (独立于模型 Provider)
    if (this.animationResourceProvider !== null && this.animationResourceProvider.matchesRequest(url)) {
      const animResult = this.animationResourceProvider.handleRequest(url, method, requestHeaders);
      if (animResult.response !== null) {
        return animResult.response;
      }
      console.warn(LOG_TAG,
        `animation resource handleRequest returned null: ${animResult.errorCode} ${animResult.errorMessage}`);
      return null;
    }
    return null;
  }

  /**
   * Web 组件 onPageEnd 回调入口 (Phase 4B-1R §第二项 步骤 5)。
   *
   * 触发 Viewer 初始化; Viewer READY 后由 onStateChanged 推进到下一步。
   * 不在此处启动模型恢复 (必须等 Viewer READY + Profile 应用)。
   */
  async onWebPageEnd(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.pageEndReceived) {
      return;
    }
    this.pageEndReceived = true;
    this.setStageState('WEB_READY', 'Web 页面加载完成,等待 Viewer 初始化');
    await this.arkWebController.onPageEnd();
  }

  /**
   * Phase 4B-2R: AI 面板发布演出 (source = CHAT_AI_PANEL)。
   *
   * 流程:
   *   1. 生成新稳定 Turn ID (chat_ai_panel_<pageInstanceId>_<sequence>)
   *   2. 构建 ArkWebAvatarChatFinalResult
   *   3. 调用 Bridge.publishFinalResult
   *   4. 检查返回值: false 时记录真实错误码到 AI 面板诊断
   *
   * 返回 false 时, AI 面板显示真实错误 (不静默丢弃)。
   */
  async publishPerformanceFromPanel(performanceHintJson: string): Promise<boolean> {
    if (this.disposed) {
      this.lastPublishResult = 'REJECTED';
      this.lastPublishErrorCode = 'CHAT_STAGE_DISPOSED';
      this.lastPublishErrorMessage = 'stage disposed';
      return false;
    }
    const turnId: string = this.generatePanelTurnId();
    this.lastTurnId = turnId;
    const result: ArkWebAvatarChatFinalResult = {
      turnId: turnId,
      performanceHintJson: performanceHintJson,
      finalizedAt: Date.now(),
      source: ArkWebAvatarChatFinalResultSource.CHAT_AI_PANEL
    };
    try {
      const ok: boolean = await ArkWebAvatarChatBridge.getInstance().publishFinalResult(result);
      if (ok) {
        this.lastPublishResult = 'OK';
        this.lastPublishErrorCode = '';
        this.lastPublishErrorMessage = '';
      } else {
        this.lastPublishResult = 'REJECTED';
        // Bridge 返回 false 的常见原因: 重复 turnId / 队列满 / 无 Avatar endpoint / Bridge disposed
        const bridgeState: string = ArkWebAvatarChatBridge.getInstance().getConnectionState();
        const pendingCount: number = ArkWebAvatarChatBridge.getInstance().getPendingCount();
        this.lastPublishErrorCode = `BRIDGE_REJECTED(state=${bridgeState},pending=${pendingCount})`;
        this.lastPublishErrorMessage = `publishFinalResult returned false, turnId=${turnId}`;
        console.warn(LOG_TAG, `publishPerformanceFromPanel rejected: turnId=${turnId} state=${bridgeState}`);
      }
      return ok;
    } catch (e) {
      this.lastPublishResult = 'THREW';
      this.lastPublishErrorCode = 'PUBLISH_THREW';
      this.lastPublishErrorMessage = e instanceof Error ? e.message : String(e);
      console.warn(LOG_TAG, 'publishPerformanceFromPanel threw: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  /**
   * Phase 4B-2R2: AI 面板发布演出并等待真实执行结果。
   *
   * 不再将 Bridge 接受视为播放成功。流程:
   *   1. 生成新 Turn ID
   *   2. 建立 pending result Promise (key = turnId)
   *   3. 调用 Bridge.publishFinalResult()
   *   4. Bridge 投递到 onBridgeFinalResult
   *   5. onBridgeFinalResult 调用 Lifecycle.submitFinalAssistantResult (真实执行)
   *   6. 执行完成后 resolve pending result
   *   7. 面板收到真实结果 (accepted + executed + runtime states + error)
   *
   * 超时: 35 秒, 超时返回 CHAT_PANEL_PERFORMANCE_TIMEOUT。
   * 页面销毁必须清理所有 pending result (dispose 中调用 clearPendingPanelPerformanceResolvers)。
   *
   * @param performanceHintJson 演出 hint JSON
   * @returns 真实执行结果 (accepted/execution/runtime states/error)
   */
  async publishPerformanceFromPanelAndWait(
    performanceHintJson: string
  ): Promise<ArkWebPanelPerformanceResult> {
    if (this.disposed) {
      const errResult: ArkWebPanelPerformanceResult = {
        accepted: false,
        executed: false,
        turnId: '',
        commandId: '',
        lifecycleState: 'DISPOSED',
        animationState: this.debugAnimationStateStr,
        poseState: this.poseRuntimeState,
        expressionState: this.expressionRuntimeState,
        errorCode: 'CHAT_STAGE_DISPOSED',
        errorMessage: 'stage disposed'
      };
      return errResult;
    }

    const turnId: string = this.generatePanelTurnId();
    this.lastTurnId = turnId;

    // 建立 pending result Promise
    const resultPromise: Promise<ArkWebPanelPerformanceResult> = new Promise(
      (resolve: (result: ArkWebPanelPerformanceResult) => void): void => {
        this.pendingPanelPerformanceResolvers.set(turnId, resolve);
      }
    );

    // 超时保护 (35s)
    const timeoutPromise: Promise<ArkWebPanelPerformanceResult> = new Promise(
      (resolve: (result: ArkWebPanelPerformanceResult) => void): void => {
        setTimeout((): void => {
          const resolver = this.pendingPanelPerformanceResolvers.get(turnId);
          if (resolver !== undefined) {
            this.pendingPanelPerformanceResolvers.delete(turnId);
            console.warn(LOG_TAG,
              `publishPerformanceFromPanelAndWait timeout: turnId=${turnId}`);
            resolve({
              accepted: true,
              executed: false,
              turnId: turnId,
              commandId: '',
              lifecycleState: this.dialogueLifecycle !== null
                ? this.dialogueLifecycle.getState() : 'DISPOSED',
              animationState: this.debugAnimationStateStr,
              poseState: this.poseRuntimeState,
              expressionState: this.expressionRuntimeState,
              errorCode: CHAT_PANEL_PERFORMANCE_TIMEOUT_ERROR,
              errorMessage: `面板演出执行超时 (${CHAT_PANEL_PERFORMANCE_TIMEOUT_MS}ms)`
            });
          }
        }, CHAT_PANEL_PERFORMANCE_TIMEOUT_MS);
      }
    );

    // 调用 Bridge.publishFinalResult (会触发 onBridgeFinalResult → Lifecycle 真实执行)
    const result: ArkWebAvatarChatFinalResult = {
      turnId: turnId,
      performanceHintJson: performanceHintJson,
      finalizedAt: Date.now(),
      source: ArkWebAvatarChatFinalResultSource.CHAT_AI_PANEL
    };

    let bridgeAccepted: boolean = false;
    try {
      bridgeAccepted = await ArkWebAvatarChatBridge.getInstance().publishFinalResult(result);
    } catch (e) {
      bridgeAccepted = false;
      this.lastPublishResult = 'THREW';
      this.lastPublishErrorCode = 'PUBLISH_THREW';
      this.lastPublishErrorMessage = e instanceof Error ? e.message : String(e);
    }

    if (!bridgeAccepted) {
      // Bridge 拒绝, 立即返回 (清理 pending resolver)
      this.pendingPanelPerformanceResolvers.delete(turnId);
      this.lastPublishResult = 'REJECTED';
      const bridgeState: string = ArkWebAvatarChatBridge.getInstance().getConnectionState();
      const pendingCount: number = ArkWebAvatarChatBridge.getInstance().getPendingCount();
      this.lastPublishErrorCode = `BRIDGE_REJECTED(state=${bridgeState},pending=${pendingCount})`;
      this.lastPublishErrorMessage = `publishFinalResult returned false, turnId=${turnId}`;
      const rejectedResult: ArkWebPanelPerformanceResult = {
        accepted: false,
        executed: false,
        turnId: turnId,
        commandId: '',
        lifecycleState: this.dialogueLifecycle !== null
          ? this.dialogueLifecycle.getState() : 'IDLE',
        animationState: this.debugAnimationStateStr,
        poseState: this.poseRuntimeState,
        expressionState: this.expressionRuntimeState,
        errorCode: this.lastPublishErrorCode,
        errorMessage: this.lastPublishErrorMessage
      };
      return rejectedResult;
    }

    this.lastPublishResult = 'OK';
    this.lastPublishErrorCode = '';
    this.lastPublishErrorMessage = '';

    // 等待真实执行结果或超时
    const finalResult: ArkWebPanelPerformanceResult =
      await Promise.race([resultPromise, timeoutPromise]);
    return finalResult;
  }

  /**
   * Phase 4B-2R2: 清理所有 pending panel performance resolvers (页面销毁时调用)。
   *
   * 不等待真实执行结果, 直接返回 DISPOSED 错误。
   */
  private clearPendingPanelPerformanceResolvers(): void {
    if (this.pendingPanelPerformanceResolvers.size === 0) {
      return;
    }
    const disposedResult: ArkWebPanelPerformanceResult = {
      accepted: true,
      executed: false,
      turnId: '',
      commandId: '',
      lifecycleState: 'DISPOSED',
      animationState: this.debugAnimationStateStr,
      poseState: this.poseRuntimeState,
      expressionState: this.expressionRuntimeState,
      errorCode: 'CHAT_STAGE_DISPOSED',
      errorMessage: 'stage disposed during panel performance wait'
    };
    this.pendingPanelPerformanceResolvers.forEach(
      (resolver: (result: ArkWebPanelPerformanceResult) => void): void => {
        try {
          resolver(disposedResult);
        } catch (_e) {
          // 忽略 resolver 异常
        }
      }
    );
    this.pendingPanelPerformanceResolvers.clear();
  }

  /**
   * 停止当前演出 (AI 面板停止按钮)。
   */
  async cancelPerformance(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.dialogueLifecycle === null) {
      return;
    }
    try {
      await this.dialogueLifecycle.cancelCurrent('chat_ai_panel_stop');
    } catch (e) {
      console.warn(LOG_TAG, 'cancelPerformance threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * 获取当前能力快照 (供 AI 面板展示动作/姿势/表情列表)。
   *
   * Phase 4B-2R: 同时缓存到 cachedCapabilitySnapshot, 供 resolveAnimationDisplayName /
   * resolvePoseDisplayName 在 updateTrackingFromHint 中查找显示名。
   */
  async getCapabilitySnapshot(): Promise<ArkWebAvatarAiCapabilitySnapshot | null> {
    if (this.disposed || this.capabilityCatalog === null) {
      return null;
    }
    try {
      const snapshot: ArkWebAvatarAiCapabilitySnapshot =
        await this.capabilityCatalog.buildSnapshot(this.activeModelId);
      this.cachedCapabilitySnapshot = snapshot;
      return snapshot;
    } catch (e) {
      console.warn(LOG_TAG, 'getCapabilitySnapshot threw: ' +
        (e instanceof Error ? e.message : String(e)));
      return null;
    }
  }

  /**
   * 重新计算全身构图 (页面尺寸变化时由组件层调用)。
   *
   * 只在 MODEL_READY 状态下调用 fitAvatarFullBody。
   * 失败时保留模型, 不隐藏 Stage。
   */
  async refitFullBody(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.currentStageState !== 'MODEL_READY') {
      return;
    }
    if (this.stageWidth <= 0 || this.stageHeight <= 0) {
      return;
    }
    await this.fitFullBodyInternal();
  }

  /**
   * 销毁控制器 (Phase 4B-1R §第九项 生命周期)。
   *
   * 流程:
   *   1. generation++ (使所有异步任务过期)
   *   2. disposed = true
   *   3. 注销 Avatar endpoint
   *   4. 销毁 LifecycleController / PerformanceController / Catalog
   *   5. 销毁 ResourceProvider
   *   6. 销毁 ArkWebController
   *   7. state = DISPOSED
   *
   * 禁止旧异步结果在页面离开后提交 MODEL_READY。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    // 关键: generation++ 让所有进行中的异步任务过期
    this.modelRestoreGeneration++;
    this.restoreStarted = false;
    this.modelRestoreInProgress = false;
    // Phase 4B-2R2: 清理动画加载状态 (generation++ 让旧加载结果过期)
    this.animationLoadGeneration++;
    this.animationLoadPromise = null;
    this.animationLoadActionId = '';
    this.loadedActionId = '';
    console.info(LOG_TAG, 'dispose');

    // Phase 4B-2R2: 清理 pending panel performance resolvers (不阻塞销毁)
    this.clearPendingPanelPerformanceResolvers();

    // 1. 注销 Avatar endpoint
    this.unregisterAvatarEndpoint();

    // 2. 销毁 LifecycleController (停止当前演出)
    if (this.dialogueLifecycle !== null) {
      try {
        this.dialogueLifecycle.dispose();
      } catch (e) {
        console.warn(LOG_TAG, 'dialogueLifecycle.dispose threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
      this.dialogueLifecycle = null;
    }
    if (this.performanceController !== null) {
      try {
        this.performanceController.dispose();
      } catch (e) {
        console.warn(LOG_TAG, 'performanceController.dispose threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
      this.performanceController = null;
    }
    if (this.capabilityCatalog !== null) {
      this.capabilityCatalog.dispose();
      this.capabilityCatalog = null;
    }
    this.cachedCapabilitySnapshot = null;
    // Phase 4B-2: 销毁 ShotDirector (清除表情恢复定时器 + 取消过渡, 不执行可见过渡)
    if (this.shotDirector !== null) {
      this.shotDirector.dispose();
      this.shotDirector = null;
    }

    // 3. 销毁 ResourceProvider (停止响应拦截请求)
    if (this.resourceProvider !== null) {
      this.resourceProvider.dispose();
      this.resourceProvider = null;
    }
    this.assetLibrary = null;
    this.persistentModelStore = null;
    this.performanceRuntime = null;
    this.dialogueMapper = null;
    this.preparedResource = null;
    this.resourceRegistered = false;

    // 4. 销毁 ArkWebController (销毁 Web 实例)
    try {
      this.arkWebController.destroy();
    } catch (e) {
      console.warn(LOG_TAG, 'arkWebController.destroy threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }

    this.setStageState('DISPOSED', '已销毁');
  }

  // ===== ArkWebViewerEventListener 实现 =====

  /**
   * Viewer 状态变化回调 (Phase 4B-1R §第二项 步骤 6)。
   *
   * 关键转换:
   *   - INITIALIZING → WEB_READY (Viewer 正在初始化)
   *   - READY → VIEWER_READY + onViewerReady (setRenderProfile + startActiveModelRestore)
   *   - FAILED → FAILED
   */
  onStateChanged(state: ArkWebViewerState, detail: string): void {
    if (this.disposed) {
      return;
    }
    this.viewerStateStr = String(state);
    console.info(LOG_TAG, `Viewer state changed: ${state} detail=${detail}`);
    if (state === ArkWebViewerState.READY) {
      if (this.viewerReadyReceived) {
        return;
      }
      this.viewerReadyReceived = true;
      this.setStageState('VIEWER_READY', 'Viewer 就绪');
      this.onViewerReady().catch((e: Object): void => {
        console.warn(LOG_TAG, 'onViewerReady threw: ' +
          (e instanceof Error ? e.message : String(e)));
      });
    } else if (state === ArkWebViewerState.FAILED) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_VIEWER_NOT_READY;
      this.lastErrorMessage = `Viewer 失败: ${detail}`;
      this.setStageState('FAILED', `Viewer 失败: ${detail}`);
    } else if (state === ArkWebViewerState.INITIALIZING) {
      // 仍处于 WEB_READY 阶段, Viewer 正在初始化
      this.setStageState('WEB_READY', `Viewer 初始化中: ${detail}`);
    }
  }

  onError(code: string, message: string): void {
    console.warn(LOG_TAG, `Viewer error: code=${code} msg=${message}`);
  }

  // ===== 内部方法 =====

  /**
   * Viewer READY 后的处理 (Phase 4B-1R §第二项 步骤 7-10)。
   *
   * 严格顺序:
   *   1. setRenderProfile(CHAT_STAGE)
   *   2. 确认 getRenderProfile() === CHAT_STAGE
   *   3. AssetLibrary.ensureInitialized
   *   4. startActiveModelRestore
   *
   * 并发保护: 如果 onPageEnd 与 READY 几乎同时发生, 通过 viewerReadyReceived + restoreScheduled 保证只启动一次。
   */
  private async onViewerReady(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (!this.initCompleted) {
      console.warn(LOG_TAG, 'onViewerReady: init not completed yet, skip');
      return;
    }

    // 1. 应用 CHAT_STAGE Profile (幂等)
    if (!this.chatStageProfileApplied) {
      try {
        const setResultJson: string = await this.arkWebController.setRenderProfile(
          ArkWebRenderProfile.CHAT_STAGE
        );
        if (this.disposed) {
          return;
        }
        const setResult: Record<string, Object> = JSON.parse(setResultJson) as Record<string, Object>;
        if (setResult['success'] !== true) {
          this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_PROFILE_FAILED;
          this.lastErrorMessage = `setRenderProfile failed: ${setResultJson}`;
          this.setStageState('FAILED', 'CHAT_STAGE Profile 设置失败');
          return;
        }
      } catch (e) {
        if (this.disposed) {
          return;
        }
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_PROFILE_FAILED;
        this.lastErrorMessage = 'setRenderProfile threw: ' +
          (e instanceof Error ? e.message : String(e));
        this.setStageState('FAILED', 'CHAT_STAGE Profile 异常');
        return;
      }
      this.chatStageProfileApplied = true;
      console.info(LOG_TAG, 'CHAT_STAGE profile applied');
    }

    // 2. 确认 getRenderProfile() === CHAT_STAGE
    try {
      const getResultJson: string = await this.arkWebController.getRenderProfile();
      if (this.disposed) {
        return;
      }
      const getResult: Record<string, Object> = JSON.parse(getResultJson) as Record<string, Object>;
      const profile: string = (getResult['profile'] as string) || '';
      this.renderProfileStr = profile;
      if (profile !== ArkWebRenderProfile.CHAT_STAGE) {
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_PROFILE_FAILED;
        this.lastErrorMessage = `getRenderProfile mismatch: ${profile}`;
        this.setStageState('FAILED', 'CHAT_STAGE Profile 确认失败');
        return;
      }
    } catch (e) {
      if (this.disposed) {
        return;
      }
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_PROFILE_FAILED;
      this.lastErrorMessage = 'getRenderProfile threw: ' +
        (e instanceof Error ? e.message : String(e));
      this.setStageState('FAILED', 'CHAT_STAGE Profile 回读异常');
      return;
    }
    this.setStageState('PROFILE_READY', 'CHAT_STAGE Profile 就绪');

    // 3. 启动模型自动恢复 (内部会 ensureInitialized AssetLibrary)
    this.startActiveModelRestore().catch((e: Object): void => {
      console.warn(LOG_TAG, 'startActiveModelRestore threw: ' +
        (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * 启动 activeModel 自动恢复 (Phase 4B-1R §第三项)。
   *
   * 严格流程:
   *   1. 单次触发保护 + 并发保护
   *   2. 检查 Viewer READY
   *   3. generation++
   *   4. AssetLibrary.ensureInitialized
   *   5. findActiveModel
   *   6. 无 active model → EMPTY
   *   7. 有 → validateRegisterAndLoadPersistentAsset (含 probe + load + READY 等待)
   *   8. 成功 → MODEL_READY → fitAvatarFullBody
   */
  private async startActiveModelRestore(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.restoreStarted) {
      console.info(LOG_TAG, 'startActiveModelRestore: already started, skip');
      return;
    }
    if (this.restoreScheduled) {
      return;
    }
    if (!this.initCompleted) {
      console.warn(LOG_TAG, 'startActiveModelRestore: init not completed');
      return;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      console.warn(LOG_TAG, 'startActiveModelRestore: viewer not ready');
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_VIEWER_NOT_READY;
      this.lastErrorMessage = `viewer state=${this.arkWebController.getState()}`;
      return;
    }
    if (!this.chatStageProfileApplied) {
      console.warn(LOG_TAG, 'startActiveModelRestore: profile not applied');
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_PROFILE_FAILED;
      this.lastErrorMessage = 'CHAT_STAGE profile not applied';
      return;
    }
    if (this.modelRestoreInProgress) {
      return;
    }
    if (this.assetLibrary === null || this.persistentModelStore === null
        || this.resourceProvider === null) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_CONTEXT_MISSING;
      this.lastErrorMessage = 'deps null (assetLibrary/store/provider)';
      this.setStageState('FAILED', '依赖缺失');
      return;
    }

    this.restoreStarted = true;
    this.restoreScheduled = true;
    this.modelRestoreInProgress = true;
    this.modelRestoreGeneration++;
    const generation: number = this.modelRestoreGeneration;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    this.setStageState('ASSET_LIBRARY_READY', '正在恢复模型');

    try {
      // 1. AssetLibrary.ensureInitialized
      const initOk: boolean = await this.assetLibrary.ensureInitialized();
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_RESTORE_STALE;
        this.lastErrorMessage = `stale after ensureInitialized gen=${generation}`;
        return;
      }
      if (!initOk) {
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_ASSET_LIBRARY_FAILED;
        this.lastErrorMessage = 'AssetLibrary ensureInitialized failed';
        this.setStageState('FAILED', 'AssetLibrary 初始化失败');
        return;
      }

      // 2. findActiveModel
      const activeAsset: ArkWebAvatarModelAsset | null = await this.assetLibrary.findActiveModel();
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_RESTORE_STALE;
        this.lastErrorMessage = `stale after findActiveModel gen=${generation}`;
        return;
      }

      if (activeAsset === null) {
        // 无 active model
        this.activeModelId = '';
        this.activeModelDisplayName = '';
        this.modelStateStr = 'EMPTY';
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_ACTIVE_MODEL_EMPTY;
        this.lastErrorMessage = '无激活模型 (需先在 VRM Viewer 导入模型)';
        this.setStageState('EMPTY', '无激活模型');
        if (this.eventListener !== null) {
          this.eventListener.onModelNameChanged('');
        }
        console.info(LOG_TAG, 'no active model, entering EMPTY state');
        return;
      }

      this.activeModelId = activeAsset.modelId;
      this.activeModelDisplayName = activeAsset.displayName;
      if (this.eventListener !== null) {
        this.eventListener.onModelNameChanged(this.activeModelDisplayName);
      }
      console.info(LOG_TAG, `active model found: id=${activeAsset.modelId} name=${activeAsset.displayName}`);

      // 3. 验证 + 注册 + prepare + probe + load + READY 等待
      this.setStageState('MODEL_RESOLVING', '验证并注册模型资源');
      const loaded: boolean = await this.validateRegisterAndLoadPersistentAsset(activeAsset, generation);
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_RESTORE_STALE;
        this.lastErrorMessage = `stale after load gen=${generation}`;
        return;
      }
      if (loaded) {
        this.modelStateStr = 'READY';
        this.lastErrorCode = '';
        this.lastErrorMessage = '';
        this.setStageState('MODEL_READY', '模型就绪');
        console.info(LOG_TAG, 'active model restored successfully');

        // Phase 4B-2R §第二项: 模型 READY 后先恢复默认姿势, 再记录稳定全身参考 Bounds
        // 顺序: 读取 defaultPoseId → 恢复默认姿势 → 等待应用完成 → 记录参考状态 → fitAvatarFullBody
        // 禁止: 模型刚进入 READY 就立即按 T-Pose 计算全身镜头
        this.defaultPoseRestored = false;
        this.chatFullBodyReferenceBoundsRecorded = false;
        await this.restoreDefaultPose();
        if (generation !== this.modelRestoreGeneration || this.disposed) {
          this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_RESTORE_STALE;
          this.lastErrorMessage = `stale after restoreDefaultPose gen=${generation}`;
          return;
        }
        // Phase 4B-2R: 加载当前模型的表情别名映射 (供 Runtime 表情按钮使用)
        await this.loadExpressionAliasMap();
        if (generation !== this.modelRestoreGeneration || this.disposed) {
          return;
        }
        // 标记稳定全身参考已记录 (默认姿势应用完成后, 不再因动画/表情短暂变化而重新生成)
        this.chatFullBodyReferenceBoundsRecorded = true;

        // MODEL_READY 后立即全身构图 (受尺寸有效性保护)
        if (this.stageWidth > 0 && this.stageHeight > 0) {
          await this.fitFullBodyInternal();
        } else {
          console.warn(LOG_TAG, 'fitAvatarFullBody skipped: size invalid, will retry on onAreaChange');
        }
        // Phase 4B-2: 通知 ShotDirector 模型 READY (执行 FULL_BODY 构图)
        if (this.shotDirector !== null) {
          this.shotDirector.onModelReady().catch((e: Object): void => {
            console.warn(LOG_TAG, 'shotDirector.onModelReady threw: ' +
              (e instanceof Error ? e.message : String(e)));
          });
        }
      }
      // loaded=false 时错误码已在内部设置
    } catch (e) {
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_RESTORE_STALE;
        this.lastErrorMessage = `stale exception gen=${generation}`;
        return;
      }
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `恢复异常: ${msg}`;
      this.setStageState('FAILED', `恢复异常: ${msg}`);
    } finally {
      this.modelRestoreInProgress = false;
    }
  }

  /**
   * 验证、注册并加载持久化模型资产 (Phase 4B-1R §第三项)。
   *
   * 严格流程 (对照 VrmViewerPage):
   *   1. validateModelFile
   *   2. registerPersistentAsset (Provider 必须绑定当前 Chat Stage WebView)
   *   3. prepareModelResource + 回读 getPreparedModelResource
   *   4. probePreparedModelResource + 轮询 VERIFIED
   *   5. loadPreparedModelResource + 轮询 READY
   *
   * 不把 loadPreparedModelResource 返回 success 等同于 MODEL_READY。
   */
  private async validateRegisterAndLoadPersistentAsset(
    asset: ArkWebAvatarModelAsset,
    generation: number
  ): Promise<boolean> {
    if (this.disposed || this.persistentModelStore === null || this.resourceProvider === null) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_CONTEXT_MISSING;
      this.lastErrorMessage = 'store/provider null';
      return false;
    }

    // 1. 验证文件
    const validateOk: boolean = await this.persistentModelStore.validateModelFile(
      asset.relativePath,
      asset.byteLength
    );
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }
    if (!validateOk) {
      const err: string = this.persistentModelStore.getLastError();
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_FILE_MISSING;
      this.lastErrorMessage = `validate failed: ${err}`;
      this.setStageState('FAILED', '模型文件验证失败');
      return false;
    }

    // 2. 注册到 Provider (绑定到当前 Chat Stage WebView)
    const absolutePath: string = this.persistentModelStore.resolveAbsolutePath(asset.relativePath);
    if (absolutePath.length === 0) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_FILE_MISSING;
      this.lastErrorMessage = 'resolveAbsolutePath empty';
      this.setStageState('FAILED', '模型路径解析失败');
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
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_PROVIDER_REGISTER_FAILED;
      this.lastErrorMessage = `register failed: ${msg}`;
      this.setStageState('FAILED', 'Provider 注册失败');
      return false;
    }
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }
    this.preparedResource = resource;
    this.resourceRegistered = true;
    console.info(LOG_TAG, `persistent asset registered: url=${resource.resourceUrl}`);

    // 3. prepareModelResource (将资源元数据同步到 Web 端 keeper) + 回读
    const preparePayload: Record<string, Object> = {
      'resourceUrl': resource.resourceUrl,
      'displayName': resource.displayName,
      'mimeType': resource.mimeType,
      'size': resource.size,
      'extension': resource.extension,
      'gltfDependencyState': resource.gltfDependencyState
    };
    const resourceJson: string = JSON.stringify(preparePayload);
    let prepareResultJson: string;
    try {
      prepareResultJson = await this.arkWebController.prepareModelResource(resourceJson);
    } catch (e) {
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return false;
      }
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `prepareModelResource threw: ${msg}`;
      this.setStageState('FAILED', 'prepareModelResource 异常');
      return false;
    }
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }
    let prepareObj: Record<string, Object>;
    try {
      prepareObj = JSON.parse(prepareResultJson) as Record<string, Object>;
    } catch (_e) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `prepareModelResource result invalid: ${prepareResultJson}`;
      this.setStageState('FAILED', 'prepareModelResource 返回非 JSON');
      return false;
    }
    if (prepareObj['success'] !== true) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `prepareModelResource rejected: ${prepareResultJson}`;
      this.setStageState('FAILED', 'prepareModelResource 被拒绝');
      return false;
    }
    const prepareState: string = (prepareObj['state'] as string) || '';
    if (prepareState !== 'RESOURCE_READY') {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `prepareModelResource state=${prepareState}`;
      this.setStageState('FAILED', 'prepareModelResource state 非 RESOURCE_READY');
      return false;
    }

    // 3.1 回读 getPreparedModelResource 验证 keeper 已保存
    let readbackJson: string;
    try {
      readbackJson = await this.arkWebController.getPreparedModelResource();
    } catch (e) {
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return false;
      }
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `getPreparedModelResource threw: ${msg}`;
      return false;
    }
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }
    try {
      const readbackObj: Record<string, Object> = JSON.parse(readbackJson) as Record<string, Object>;
      if (readbackObj['success'] !== true) {
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
        this.lastErrorMessage = `getPreparedModelResource success=false: ${readbackJson}`;
        return false;
      }
    } catch (_e) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `getPreparedModelResource result invalid: ${readbackJson}`;
      return false;
    }
    console.info(LOG_TAG, 'prepareModelResource verified (keeper saved)');

    // 4. probePreparedModelResource + 轮询 VERIFIED
    this.setStageState('MODEL_RESOLVING', '资源探测中');
    let probeStartJson: string;
    try {
      probeStartJson = await this.arkWebController.probePreparedModelResource();
    } catch (e) {
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return false;
      }
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `probePreparedModelResource threw: ${msg}`;
      return false;
    }
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }
    if (probeStartJson.indexOf('"success":true') < 0 && probeStartJson.indexOf('"success": true') < 0) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `probe start failed: ${probeStartJson}`;
      this.setStageState('FAILED', '资源探测启动失败');
      return false;
    }

    // 轮询探测结果
    const probeOk: boolean = await this.waitForProbeVerified(generation, PROBE_POLL_TOTAL_TIMEOUT_MS);
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }
    if (!probeOk) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `probe not verified within ${PROBE_POLL_TOTAL_TIMEOUT_MS}ms`;
      this.setStageState('FAILED', '资源探测未通过');
      return false;
    }
    console.info(LOG_TAG, 'probe verified');

    // 5. loadPreparedModelResource (触发实际加载)
    this.setStageState('MODEL_LOADING', '模型加载中');
    let loadStartJson: string;
    try {
      loadStartJson = await this.arkWebController.loadPreparedModelResource();
    } catch (e) {
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return false;
      }
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `loadPreparedModelResource threw: ${msg}`;
      this.setStageState('FAILED', '模型加载启动异常');
      return false;
    }
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }
    if (loadStartJson.indexOf('"success":true') < 0 && loadStartJson.indexOf('"success": true') < 0) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
      this.lastErrorMessage = `load start failed: ${loadStartJson}`;
      this.setStageState('FAILED', '模型加载启动失败');
      return false;
    }

    // 6. 轮询加载结果 (Phase 4B-1R §第四项 - 等待真实 MODEL_READY)
    const readyOk: boolean = await this.waitForModelLoadReady(generation, MODEL_READY_POLL_TOTAL_TIMEOUT_MS);
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }
    if (!readyOk) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_READY_TIMEOUT;
      this.lastErrorMessage = `model not READY within ${MODEL_READY_POLL_TOTAL_TIMEOUT_MS}ms`;
      this.setStageState('FAILED', '模型 READY 等待超时');
      return false;
    }
    console.info(LOG_TAG, 'model load READY confirmed via polling');
    return true;
  }

  /**
   * 等待资源探测达到 VERIFIED 状态 (Phase 4B-1R §第三项)。
   *
   * 有限次数轮询:
   *   - 间隔 200ms
   *   - 总时长 4500ms
   *   - VERIFIED → true
   *   - FAILED → false
   *   - 超时 → false
   *   - generation 改变 / disposed → false
   */
  private async waitForProbeVerified(generation: number, timeoutMs: number): Promise<boolean> {
    const startTime: number = Date.now();
    while (Date.now() - startTime < timeoutMs) {
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return false;
      }
      let resultJson: string;
      try {
        resultJson = await this.arkWebController.getModelResourceProbeResult();
      } catch (_e) {
        await this.delay(PROBE_POLL_INTERVAL_MS);
        continue;
      }
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return false;
      }
      try {
        const parsed: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        const resultObj: Object | undefined = parsed['result'];
        if (resultObj === undefined || resultObj === null) {
          await this.delay(PROBE_POLL_INTERVAL_MS);
          continue;
        }
        const result: Record<string, Object> = resultObj as Record<string, Object>;
        const stateStr: string = (result['state'] as string) || '';
        if (stateStr === 'VERIFIED') {
          return true;
        }
        if (stateStr === 'FAILED') {
          return false;
        }
        // PROBING / NOT_PROBED 继续等待
      } catch (_e) {
        // 解析失败继续等待
      }
      await this.delay(PROBE_POLL_INTERVAL_MS);
    }
    return false;
  }

  /**
   * 等待模型加载达到 READY 状态 (Phase 4B-1R §第四项)。
   *
   * 有限次数轮询:
   *   - 间隔 100ms
   *   - 总时长 15000ms
   *   - READY → true (并更新 modelStateStr)
   *   - FAILED / DISPOSED → false
   *   - 超时 → false
   *   - generation 改变 / disposed → false
   *
   * 通过 getPreparedModelLoadResult() 检查真实加载状态,
   * 不把 loadPreparedModelResource 返回 success 等同于 MODEL_READY。
   */
  private async waitForModelLoadReady(generation: number, timeoutMs: number): Promise<boolean> {
    const startTime: number = Date.now();
    while (Date.now() - startTime < timeoutMs) {
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return false;
      }
      let resultJson: string;
      try {
        resultJson = await this.arkWebController.getPreparedModelLoadResult();
      } catch (_e) {
        await this.delay(MODEL_READY_POLL_INTERVAL_MS);
        continue;
      }
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return false;
      }
      try {
        const parsed: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (parsed['success'] !== true) {
          // Bridge 返回错误, 继续轮询 (可能是临时错误)
          await this.delay(MODEL_READY_POLL_INTERVAL_MS);
          continue;
        }
        const resultObj: Object | undefined = parsed['result'];
        if (resultObj === undefined || resultObj === null) {
          // 还没有结果, 继续轮询
          await this.delay(MODEL_READY_POLL_INTERVAL_MS);
          continue;
        }
        const result: Record<string, Object> = resultObj as Record<string, Object>;
        const stateStr: string = (result['state'] as string) || 'NOT_REQUESTED';
        this.modelStateStr = stateStr;
        if (stateStr === 'READY') {
          // 额外校验: displayName 非空 (来自 VrmViewerPage §第四项 等待条件)
          const displayName: string = (result['modelDisplayName'] as string) || '';
          if (displayName.length > 0) {
            this.activeModelDisplayName = displayName;
            if (this.eventListener !== null) {
              this.eventListener.onModelNameChanged(displayName);
            }
          }
          return true;
        }
        if (stateStr === 'FAILED' || stateStr === 'DISPOSED') {
          const errCode: string = (result['errorCode'] as string) || '';
          const errMsg: string = (result['errorMessage'] as string) || '';
          this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_MODEL_LOAD_FAILED;
          this.lastErrorMessage = `load ${stateStr}: ${errCode} ${errMsg}`;
          return false;
        }
        // LOADING / NOT_REQUESTED 继续等待
      } catch (_e) {
        // 解析失败继续等待
      }
      await this.delay(MODEL_READY_POLL_INTERVAL_MS);
    }
    return false;
  }

  /**
   * Phase 4B-2R: 调用 fitAvatarFullBody 完成全身构图。
   *
   * 只在以下条件全部成立时调用:
   *   - stageState = MODEL_READY
   *   - stageWidth > 0
   *   - stageHeight > 0
   *   - 未 dispose
   *   - restoreGeneration 仍有效 (此处简化为 disposed 检查, generation 检查在调用方)
   *
   * Phase 4B-2R: 使用 fillRatio=0.78 控制模型垂直占比约 78%。
   * 失败时保留模型, 不隐藏 Stage, 不修改 model.scene.position/scale。
   *
   * 禁止:
   *   - 在动画每帧重新计算 Bounds
   *   - 根据当前动作伸展范围持续缩放镜头
   */
  private async fitFullBodyInternal(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.currentStageState !== 'MODEL_READY') {
      return;
    }
    if (this.stageWidth <= 0 || this.stageHeight <= 0) {
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_SIZE_INVALID;
      this.lastErrorMessage = `fit skipped: size ${this.stageWidth}x${this.stageHeight}`;
      return;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return;
    }
    try {
      // 使用 currentFillRatio (用户可通过滑动条调节, 默认 0.78)
      const resultJson: string = await this.arkWebController.fitAvatarFullBody(this.currentFillRatio);
      if (this.disposed) {
        return;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] === true) {
        console.info(LOG_TAG, 'fitAvatarFullBody ok (fillRatio=' + this.currentFillRatio + ')');
        // 清除 fit 失败错误
        if (this.lastErrorCode === ArkWebChatAvatarStageErrorCode.CHAT_STAGE_FULL_BODY_FIT_FAILED) {
          this.lastErrorCode = '';
          this.lastErrorMessage = '';
        }
      } else {
        this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_FULL_BODY_FIT_FAILED;
        this.lastErrorMessage = `fitAvatarFullBody failed: ${resultJson}`;
        console.warn(LOG_TAG, 'fitAvatarFullBody failed: ' + resultJson);
      }
    } catch (e) {
      if (this.disposed) {
        return;
      }
      this.lastErrorCode = ArkWebChatAvatarStageErrorCode.CHAT_STAGE_FULL_BODY_FIT_FAILED;
      this.lastErrorMessage = 'fitAvatarFullBody threw: ' +
        (e instanceof Error ? e.message : String(e));
      console.warn(LOG_TAG, 'fitAvatarFullBody threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  // ===== Phase 4B-2: ShotRuntime 实现 =====

  /**
   * ShotRuntime.transitionToFullBody 实现。
   *
   * 调用 arkWebController.fitAvatarFullBody (Phase 4B-1 已有)。
   * 复用现有 API, 不创建第二套相机系统。
   *
   * Phase 4B-2R2: 切换完成后应用当前 cameraZoomMultiplier, 保持用户设置的倍率。
   */
  private async shotTransitionToFullBody(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return false;
    }
    try {
      // 使用 currentFillRatio 保持与用户滑动条设置一致, 避免切换镜头时模型变小
      console.info(LOG_TAG, 'shotTransitionToFullBody: fillRatio=' + this.currentFillRatio);
      const resultJson: string = await this.arkWebController.fitAvatarFullBody(this.currentFillRatio);
      if (this.disposed) {
        return false;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const ok: boolean = obj['success'] === true;
      console.info(LOG_TAG, 'shotTransitionToFullBody: result ok=' + ok + ' fillRatio=' + this.currentFillRatio);
      // Phase 4B-2R2: 应用当前缩放倍率 (保持用户设置, 不重置)
      if (ok && Math.abs(this.cameraZoomMultiplier - 1.0) > 0.001) {
        await this.applyCameraZoomInternal('SHOT_FULL_BODY');
      }
      return ok;
    } catch (e) {
      console.warn(LOG_TAG, 'shotTransitionToFullBody threw: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  /**
   * ShotRuntime.transitionToResetView 实现。
   *
   * 调用 arkWebController.smoothResetCamera (与重置按钮相同的方法)。
   * 复用现有平滑重置 API, 不硬编码第二套脸部相机坐标。
   *
   * Phase 4B-2R2: 切换完成后应用当前 cameraZoomMultiplier, 保持用户设置的倍率。
   */
  private async shotTransitionToResetView(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return false;
    }
    try {
      // durationSeconds=0.45 (默认平滑时长), preserveControlsEnabled=true (保持 CHAT_STAGE 禁用)
      const resultJson: string = await this.arkWebController.smoothResetCamera(0.45, true);
      if (this.disposed) {
        return false;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const ok: boolean = obj['success'] === true;
      // Phase 4B-2R2: 应用当前缩放倍率 (保持用户设置, 不重置)
      if (ok && Math.abs(this.cameraZoomMultiplier - 1.0) > 0.001) {
        await this.applyCameraZoomInternal('SHOT_RESET_VIEW');
      }
      return ok;
    } catch (e) {
      console.warn(LOG_TAG, 'shotTransitionToResetView threw: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  /**
   * Phase 4B-2R2: 内部应用相机缩放倍率。
   *
   * 不修改 cameraZoomMultiplier 字段, 只将其应用到当前相机位置。
   * 供 shotTransitionToFullBody / shotTransitionToResetView / setCameraZoomMultiplier 调用。
   *
   * @param reason 调用原因 (诊断用)
   */
  private async applyCameraZoomInternal(reason: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return;
    }
    try {
      const resultJson: string =
        await this.arkWebController.applyCameraZoomMultiplier(this.cameraZoomMultiplier);
      if (this.disposed) {
        return;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const ok: boolean = obj['success'] === true;
      if (!ok) {
        console.warn(LOG_TAG, `applyCameraZoomInternal(${reason}) failed: ${resultJson}`);
      }
    } catch (e) {
      console.warn(LOG_TAG, `applyCameraZoomInternal(${reason}) threw: ` +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * ShotRuntime.cancelCameraTransition 实现。
   *
   * 调用 arkWebController.cancelCameraTransition (取消正在进行的过渡)。
   */
  private async shotCancelCameraTransition(reason: string): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    try {
      const resultJson: string = await this.arkWebController.cancelCameraTransition(reason);
      if (this.disposed) {
        return false;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      console.warn(LOG_TAG, 'shotCancelCameraTransition threw: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  // ===== Phase 4B-2R: 共享 Runtime 依赖方法 (与 VrmViewerPage 一致) =====

  /**
   * Phase 4B-2R2: 按 actionId 加载动画 (与 VrmViewerPage.loadAnimationByActionId 一致)。
   *
   * 流程:
   *   1. 已加载同一动作 (loadedActionId === actionId 且 Web state === READY) → 直接返回 true
   *   2. 同 action LOADING → 复用 animationLoadPromise (不重复发起)
   *   3. 不同 action LOADING → 递增 generation, 启动新加载, 旧结果按 generation 丢弃
   *   4. assetLibrary.findAnimation(actionId)
   *   5. persistentAnimationStore.resolveAbsolutePath
   *   6. animationResourceProvider.registerPersistentAsset
   *   7. arkWebController.loadAnimationResource
   *
   * Phase 4B-2R2 修复:
   * - 不再仅凭本地 LOADING 拒绝, 先调用 getAnimationDebugState 刷新 Web 状态
   * - 同 action 并发点击复用 Promise
   * - 失败/超时清理 Promise, 状态不得永久停留在 LOADING
   * - 不同 action 递增 generation, 旧结果按 generation 丢弃
   *
   * 不复制 VRMA 加载轮询逻辑, 轮询由 waitForAnimationReady 处理。
   */
  private async loadAnimationByActionId(actionId: string): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (actionId.length === 0) {
      return false;
    }
    if (this.assetLibrary === null || this.persistentAnimationStore === null
        || this.animationResourceProvider === null) {
      console.warn(LOG_TAG, 'loadAnimationByActionId: deps null');
      return false;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      console.warn(LOG_TAG, 'loadAnimationByActionId: viewer not READY');
      return false;
    }

    // Phase 4B-2R2: 已加载同一动作且 Web state === READY → 直接返回 true (无需再次加载)
    if (this.loadedActionId === actionId && this.debugAnimationStateStr === 'READY') {
      console.info(LOG_TAG, `loadAnimationByActionId: already loaded and READY: ${actionId}`);
      return true;
    }

    // Phase 4B-2R2: 本地状态为 LOADING 时先刷新 Web 端状态 (不直接拒绝)
    if (this.debugAnimationStateStr === 'LOADING') {
      try {
        const refreshJson: string = await this.arkWebController.getAnimationDebugState();
        if (this.disposed) {
          return false;
        }
        this.parseAnimationDebugState(refreshJson);
      } catch (e) {
        console.warn(LOG_TAG, 'loadAnimationByActionId: refresh state failed: ' +
          (e instanceof Error ? e.message : String(e)));
      }
      // 读取刷新后的最新状态到本地变量, 避免 ArkTS 在 if 块内将字段类型收窄为 'LOADING' 字面量
      const refreshedState: string = this.debugAnimationStateStr;
      // 刷新后若已 READY 且是同一 action → 直接返回 true
      if (refreshedState === 'READY' && this.loadedActionId === actionId) {
        console.info(LOG_TAG, `loadAnimationByActionId: refreshed to READY: ${actionId}`);
        return true;
      }
      // 刷新后若已 FAILED → 清理 Promise, 允许重新加载
      if (refreshedState === 'FAILED' || refreshedState === 'NOT_REQUESTED'
          || refreshedState === 'IDLE' || refreshedState === 'STOPPED') {
        console.info(LOG_TAG,
          `loadAnimationByActionId: recovered from stale LOADING, now ${refreshedState}`);
        this.animationLoadPromise = null;
        this.animationLoadActionId = '';
      }
    }

    // Phase 4B-2R2: 同 action 正在加载 → 复用同一个 Promise
    if (this.animationLoadPromise !== null && this.animationLoadActionId === actionId) {
      console.info(LOG_TAG, `loadAnimationByActionId: reuse pending promise for ${actionId}`);
      return await this.animationLoadPromise;
    }

    // Phase 4B-2R2: 不同 action 正在加载 → 递增 generation, 启动新加载
    this.animationLoadGeneration++;
    const myGeneration: number = this.animationLoadGeneration;
    this.animationLoadActionId = actionId;
    this.debugAnimationStateStr = 'LOADING';

    const loadPromise: Promise<boolean> = this.executeAnimationLoad(actionId, myGeneration);
    this.animationLoadPromise = loadPromise;

    try {
      const ok: boolean = await loadPromise;
      // generation 检查: 旧加载结果不得覆盖新状态
      if (myGeneration !== this.animationLoadGeneration) {
        console.info(LOG_TAG,
          `loadAnimationByActionId: stale generation ${myGeneration}, current ${this.animationLoadGeneration}, discard`);
        return false;
      }
      if (ok) {
        this.loadedActionId = actionId;
      } else {
        // 失败后状态应为 FAILED, 不得永久卡在 LOADING
        this.debugAnimationStateStr = 'FAILED';
      }
      return ok;
    } catch (e) {
      if (myGeneration === this.animationLoadGeneration) {
        this.debugAnimationStateStr = 'FAILED';
      }
      console.warn(LOG_TAG, 'loadAnimationByActionId threw: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    } finally {
      // Phase 4B-2R2: 清理 Promise (READY/FAILED/超时都允许再次点击)
      if (myGeneration === this.animationLoadGeneration) {
        this.animationLoadPromise = null;
        this.animationLoadActionId = '';
      }
    }
  }

  /**
   * Phase 4B-2R2: 执行动画加载 (内部方法, 由 loadAnimationByActionId 调用)。
   *
   * 不修改 animationLoadPromise 字段, 只执行实际加载逻辑。
   * 调用方负责 generation 检查和 Promise 清理。
   */
  private async executeAnimationLoad(actionId: string, generation: number): Promise<boolean> {
    // 1. 查找资产
    const asset: ArkWebAvatarAnimationAsset | null =
      await this.assetLibrary!.findAnimation(actionId);
    if (asset === null) {
      console.warn(LOG_TAG, `executeAnimationLoad: animation not found: ${actionId}`);
      this.animationLoadErrorCode = 'ANIMATION_ACTION_NOT_FOUND';
      return false;
    }

    // 2. 解析绝对路径
    const absolutePath: string = this.persistentAnimationStore!.resolveAbsolutePath(asset.relativePath);
    if (absolutePath.length === 0) {
      console.warn(LOG_TAG, `executeAnimationLoad: unsafe path: ${asset.relativePath}`);
      this.animationLoadErrorCode = 'ANIMATION_PATH_RESOLVE_FAILED';
      return false;
    }

    // 3. 注册到 Provider
    let publicResource: WebAnimationResource;
    try {
      publicResource = this.animationResourceProvider!.registerPersistentAsset(asset, absolutePath);
    } catch (e) {
      console.warn(LOG_TAG, 'executeAnimationLoad: provider register failed: ' +
        (e instanceof Error ? e.message : String(e)));
      this.animationLoadErrorCode = 'ANIMATION_PROVIDER_REGISTER_FAILED';
      return false;
    }

    // 4. 调用 Bridge loadAnimationResource
    const resourceJsonObj: LoadAnimationResourcePayload = {
      resourceUrl: publicResource.resourceUrl,
      resourceId: publicResource.resourceId,
      displayName: publicResource.displayName,
      mimeType: publicResource.mimeType,
      size: publicResource.size
    };
    const resourceJson: string = JSON.stringify(resourceJsonObj);

    try {
      const resultJson: string = await this.arkWebController.loadAnimationResource(resourceJson);
      // generation 检查
      if (generation !== this.animationLoadGeneration) {
        console.info(LOG_TAG, 'executeAnimationLoad: stale generation, discard');
        this.animationLoadErrorCode = 'ANIMATION_LOAD_STALE';
        return false;
      }
      if (this.disposed) {
        return false;
      }
      const parsed: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (parsed['success'] !== true) {
        const errObj = parsed['error'] as Record<string, Object>;
        const errorCode: string = errObj ? (errObj['code'] as string) || 'UNKNOWN' : 'UNKNOWN';
        const msg: string = errObj ? (errObj['message'] as string) || '' : '';
        console.warn(LOG_TAG, `executeAnimationLoad: load failed: ${errorCode} ${msg}`);
        this.debugAnimationStateStr = 'FAILED';
        this.animationLoadErrorCode = 'ANIMATION_LOAD_REQUEST_FAILED';
        return false;
      }
      this.debugAnimationStateStr = 'LOADING';
      this.animationLoadErrorCode = '';
      console.info(LOG_TAG, `executeAnimationLoad ok: ${actionId} gen=${generation}`);
      return true;
    } catch (e) {
      console.warn(LOG_TAG, 'executeAnimationLoad threw: ' +
        (e instanceof Error ? e.message : String(e)));
      this.debugAnimationStateStr = 'FAILED';
      this.animationLoadErrorCode = 'ANIMATION_LOAD_REQUEST_FAILED';
      return false;
    }
  }

  /**
   * Phase 4B-2R2: 等待动画进入 READY 状态 (与 VrmViewerPage.waitForAnimationReady 一致)。
   *
   * 复用 getAnimationDebugState 轮询, 不引入第二个轮询机制。
   * 状态: LOADING → READY / FAILED, 上限 timeoutMs 后放弃。
   *
   * Phase 4B-2R2 修复:
   * - 超时后状态设为 FAILED (不得永久停留在 LOADING)
   * - READY 时记录 loadedActionId (允许后续直接播放同一动作)
   */
  private async waitForAnimationReady(timeoutMs: number): Promise<boolean> {
    const startTick: number = Date.now();
    while (Date.now() - startTick < timeoutMs) {
      if (this.disposed) {
        return false;
      }
      // 先刷新状态 (避免使用上一次动画遗留的 READY 缓存)
      try {
        const resultJson: string = await this.arkWebController.getAnimationDebugState();
        if (this.disposed) {
          return false;
        }
        this.parseAnimationDebugState(resultJson);
      } catch (e) {
        console.warn(LOG_TAG, 'waitForAnimationReady poll failed: ' +
          (e instanceof Error ? e.message : String(e)));
      }
      if (this.debugAnimationStateStr === 'READY') {
        // Phase 4B-2R2: READY 时记录 loadedActionId
        if (this.animationLoadActionId.length > 0) {
          this.loadedActionId = this.animationLoadActionId;
        }
        return true;
      }
      if (this.debugAnimationStateStr === 'FAILED') {
        this.animationLoadErrorCode = 'ANIMATION_RUNTIME_FAILED';
        return false;
      }
      await this.delay(ANIMATION_READY_POLL_INTERVAL_MS);
    }
    // Phase 4B-2R2: 超时后状态设为 FAILED (不得永久停留在 LOADING)
    console.warn(LOG_TAG, `waitForAnimationReady timeout (${timeoutMs}ms), set FAILED`);
    this.debugAnimationStateStr = 'FAILED';
    this.animationLoadErrorCode = 'ANIMATION_READY_TIMEOUT';
    return false;
  }

  /**
   * Phase 4B-2R: 内部 resetPose 调用 (与 VrmViewerPage.resetPoseInternal 一致)。
   *
   * 复用 arkWebController.resetPose, 不复制骨骼重置逻辑。
   */
  private async resetPoseInternal(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return false;
    }
    try {
      const resultJson: string = await this.arkWebController.resetPose();
      if (this.disposed) {
        return false;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      console.warn(LOG_TAG, 'resetPoseInternal failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  /**
   * Phase 4B-2R: 内部 applyPoseById 调用 (与 VrmViewerPage.applyPoseByIdInternal 一致)。
   *
   * 复用 persistentPoseStore.readPoseDataAsJson + arkWebController.applyPose,
   * 不复制 JSON 骨骼转换逻辑。
   */
  private async applyPoseByIdInternal(poseId: string): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (this.persistentPoseStore === null) {
      return false;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return false;
    }
    try {
      const poseJson: string = await this.persistentPoseStore.readPoseDataAsJson(poseId);
      if (poseJson.length === 0) {
        console.warn(LOG_TAG, `applyPoseByIdInternal: poseJson empty: ${poseId}`);
        return false;
      }
      const resultJson: string = await this.arkWebController.applyPose(poseJson);
      if (this.disposed) {
        return false;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      console.warn(LOG_TAG, 'applyPoseByIdInternal failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  /**
   * Phase 4B-2R: 恢复默认姿势 (模型 READY 后调用, 用于稳定全身参考 Bounds)。
   *
   * 读取 defaultPoseId, 无默认姿势时降级为 resetPose。
   * 禁止在动画播放过程中或临时表情播放过程中调用。
   */
  private async restoreDefaultPose(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (this.assetLibrary === null) {
      return await this.resetPoseInternal();
    }
    try {
      const defaultPoseId: string = await this.assetLibrary.getDefaultPoseId();
      if (defaultPoseId.length === 0) {
        return await this.resetPoseInternal();
      }
      const ok: boolean = await this.applyPoseByIdInternal(defaultPoseId);
      if (ok) {
        this.defaultPoseRestored = true;
        console.info(LOG_TAG, `restoreDefaultPose ok: poseId=${defaultPoseId}`);
      }
      return ok;
    } catch (e) {
      console.warn(LOG_TAG, 'restoreDefaultPose failed, fallback to resetPose: ' +
        (e instanceof Error ? e.message : String(e)));
      return await this.resetPoseInternal();
    }
  }

  /**
   * Phase 4B-2R: 停止当前动画 (与 VrmViewerPage 一致)。
   *
   * 复用 arkWebController.stopAnimation, 不引入第二套停止逻辑。
   */
  async stopAnimation(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return false;
    }
    try {
      const resultJson: string = await this.arkWebController.stopAnimation('');
      if (this.disposed) {
        return false;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      console.warn(LOG_TAG, 'stopAnimation failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  /**
   * Phase 4B-2R: 解析 getAnimationDebugState 返回的 JSON (与 VrmViewerPage 一致)。
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
      this.debugAnimationStateStr = (debugState['state'] as string) || 'UNINITIALIZED';
      this.animationRuntimeState = this.debugAnimationStateStr;
    } catch (e) {
      console.warn(LOG_TAG, 'parseAnimationDebugState failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * Phase 4B-2R: 刷新姿势运行时状态 (从 getPoseDebugState)。
   *
   * 仅记录状态字符串, 不复制姿势解析逻辑。
   */
  async refreshPoseDebugState(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return;
    }
    try {
      const resultJson: string = await this.arkWebController.getPoseDebugState();
      if (this.disposed) {
        return;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] !== true) {
        return;
      }
      const debugState = obj['debugState'] as Record<string, Object>;
      if (!debugState) {
        return;
      }
      this.poseRuntimeState = (debugState['state'] as string) || 'IDLE';
    } catch (e) {
      console.warn(LOG_TAG, 'refreshPoseDebugState failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * Phase 4B-2R: 刷新表情运行时状态 (从 getExpressionDebugState)。
   */
  async refreshExpressionDebugState(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return;
    }
    try {
      const resultJson: string = await this.arkWebController.getExpressionDebugState();
      if (this.disposed) {
        return;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] !== true) {
        return;
      }
      const debugState = obj['debugState'] as Record<string, Object>;
      if (!debugState) {
        return;
      }
      this.expressionRuntimeState = (debugState['state'] as string) || 'IDLE';
    } catch (e) {
      console.warn(LOG_TAG, 'refreshExpressionDebugState failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * Phase 4B-2R: 加载当前模型的表情别名映射 (与 VrmViewerPage 一致)。
   *
   * 仅接受 ArkWebExpressionAliasBusinessId 校验通过的业务 ID。
   */
  private async loadExpressionAliasMap(): Promise<void> {
    if (this.disposed || this.assetLibrary === null) {
      return;
    }
    if (this.activeModelId.length === 0) {
      return;
    }
    try {
      const aliases: Record<string, string> =
        await this.assetLibrary.getExpressionAliases(this.activeModelId);
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
      console.info(LOG_TAG,
        `loadExpressionAliasMap: ${Object.keys(result).length} aliases for model=${this.activeModelId}`);
    } catch (e) {
      this.expressionAliasMap = {} as Record<string, string>;
      console.warn(LOG_TAG, 'loadExpressionAliasMap failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * Phase 4B-2R: 获取表情别名映射 (供 PerformanceRuntime 使用)。
   */
  getExpressionAliasMap(): Record<string, string> {
    return this.expressionAliasMap;
  }

  /**
   * Phase 4B-2R §第十一项: 验证 Avatar endpoint 已注册且属于本 Stage。
   *
   * 检查:
   *   1. avatarEndpointId 非空 (已注册)
   *   2. Bridge connection state = CONNECTED 或 AVATAR_READY
   *   3. endpointId 属于本 Stage (前缀 chat-avatar-stage-)
   *
   * 用于 ChatPage 打开时确认 endpoint 不会由已离开的 VrmViewerPage 消费。
   *
   * @returns [ok, errorCode, errorMessage]
   */
  verifyEndpointReady(): [boolean, string, string] {
    if (this.disposed) {
      return [false, 'STAGE_DISPOSED', 'stage disposed'];
    }
    if (this.avatarEndpointId.length === 0) {
      return [false, 'ENDPOINT_NOT_REGISTERED', 'avatarEndpointId empty'];
    }
    if (!this.avatarEndpointId.startsWith('chat-avatar-stage-')) {
      return [false, 'ENDPOINT_ID_MISMATCH',
        `endpointId=${this.avatarEndpointId} not chat-avatar-stage-*`];
    }
    const bridgeState: string = ArkWebAvatarChatBridge.getInstance().getConnectionState();
    if (bridgeState !== 'CONNECTED' && bridgeState !== 'AVATAR_READY') {
      return [false, 'BRIDGE_NOT_READY', `bridgeState=${bridgeState}`];
    }
    return [true, '', ''];
  }

  /**
   * Phase 4B-2R: 获取当前动画调试状态 (供 PerformanceRuntime 使用)。
   */
  getDebugAnimationState(): string {
    return this.debugAnimationStateStr;
  }

  /**
   * Phase 4B-2: 获取镜头导演运行时快照 (供 AI 面板诊断显示)。
   */
  getShotRuntimeSnapshot(): ArkWebAvatarShotRuntimeSnapshot | null {
    if (this.shotDirector === null) {
      return null;
    }
    return this.shotDirector.getRuntimeSnapshot();
  }

  /**
   * Phase 4B-2: 手动切换到全身镜头 (AI 面板验证按钮)。
   */
  async transitionToFullBody(reason: string): Promise<boolean> {
    if (this.shotDirector === null) {
      return false;
    }
    return await this.shotDirector.transitionToFullBody(reason);
  }

  /**
   * Phase 4B-2: 手动切换到脸部 (重置) 镜头 (AI 面板验证按钮)。
   */
  async transitionToFaceResetView(reason: string): Promise<boolean> {
    if (this.shotDirector === null) {
      return false;
    }
    return await this.shotDirector.transitionToFaceResetView(reason);
  }

  /**
   * 调节模型大小 (通过 fillRatio 重新构图)。
   *
   * 更新 currentFillRatio 并重新执行 fitAvatarFullBody。
   * fillRatio 越大模型越大 (0.3=较小, 0.98=几乎填满垂直空间)。
   * 仅在 MODEL_READY 状态下生效。
   *
   * @param fillRatio 模型垂直占比 (0.3 ~ 0.98)
   */
  async adjustModelFillRatio(fillRatio: number): Promise<void> {
    if (this.disposed) {
      return;
    }
    // 钳制到合法范围
    let ratio: number = fillRatio;
    if (ratio < 0.3) {
      ratio = 0.3;
    }
    if (ratio > 0.98) {
      ratio = 0.98;
    }
    this.currentFillRatio = ratio;
    // 仅在 READY 状态下重新构图
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return;
    }
    if (this.stageWidth <= 0 || this.stageHeight <= 0) {
      return;
    }
    try {
      const resultJson: string = await this.arkWebController.fitAvatarFullBody(this.currentFillRatio);
      if (this.disposed) {
        return;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] === true) {
        console.info(LOG_TAG, 'adjustModelFillRatio ok (fillRatio=' + this.currentFillRatio + ')');
        // Phase 4B-2R2: 重新构图后应用当前缩放倍率 (保持用户设置)
        if (Math.abs(this.cameraZoomMultiplier - 1.0) > 0.001) {
          await this.applyCameraZoomInternal('ADJUST_FILL_RATIO');
        }
      } else {
        console.warn(LOG_TAG, 'adjustModelFillRatio failed: ' + resultJson);
      }
    } catch (e) {
      console.warn(LOG_TAG, 'adjustModelFillRatio threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * Phase 4B-2R2: 设置相机缩放倍率。
   *
   * 更新 cameraZoomMultiplier 并立即应用到当前相机位置。
   * 不修改模型 transform, 只调整相机到目标点的距离。
   *
   * 范围 0.5~3.0, 1.0 为默认。非法值会被自动 clamp 到合法范围。
   *
   * @param multiplier 缩放倍率
   */
  async setCameraZoomMultiplier(multiplier: number): Promise<void> {
    if (this.disposed) {
      return;
    }
    const safeMultiplier: number = Math.max(
      CHAT_CAMERA_ZOOM_MULTIPLIER_MIN,
      Math.min(CHAT_CAMERA_ZOOM_MULTIPLIER_MAX, multiplier)
    );
    this.cameraZoomMultiplier = safeMultiplier;
    console.info(LOG_TAG, `setCameraZoomMultiplier: ${safeMultiplier}`);
    await this.applyCameraZoomInternal('SET_ZOOM');
  }

  /**
   * Phase 4B-2R2: 获取当前相机缩放倍率。
   */
  getCameraZoomMultiplier(): number {
    return this.cameraZoomMultiplier;
  }

  /**
   * Phase 4B-2R2: 获取相机缩放倍率范围与步进。
   *
   * @returns [min, max, default, step]
   */
  getCameraZoomMultiplierRange(): [number, number, number, number] {
    return [
      CHAT_CAMERA_ZOOM_MULTIPLIER_MIN,
      CHAT_CAMERA_ZOOM_MULTIPLIER_MAX,
      CHAT_CAMERA_ZOOM_MULTIPLIER_DEFAULT,
      CHAT_CAMERA_ZOOM_MULTIPLIER_STEP
    ];
  }

  /**
   * Phase 4B-2R2: 设置镜头控制模式 (AUTO / MANUAL_FULL_BODY / MANUAL_FACE_RESET_VIEW)。
   *
   * @param mode 控制模式
   */
  setShotControlMode(mode: ArkWebAvatarShotControlMode): void {
    if (this.disposed || this.shotDirector === null) {
      return;
    }
    this.shotDirector.setControlMode(mode);
  }

  /**
   * Phase 4B-2R2: 获取当前镜头控制模式。
   */
  getShotControlMode(): ArkWebAvatarShotControlMode {
    if (this.shotDirector === null) {
      return 'AUTO';
    }
    return this.shotDirector.getControlMode();
  }

  /**
   * Phase 4B-2: Stage 从隐藏切换为显示时由组件层调用。
   *
   * 通知 ShotDirector 恢复 FULL_BODY (不恢复隐藏前的脸部镜头)。
   */
  async onStageVisible(): Promise<void> {
    if (this.shotDirector === null) {
      return;
    }
    await this.shotDirector.onStageVisible();
  }

  /**
   * 注册 Avatar endpoint 到 Bridge (覆盖式)。
   */
  private registerAvatarEndpoint(): void {
    if (this.disposed) {
      return;
    }
    if (this.avatarEndpointId.length === 0) {
      ArkWebChatAvatarStageController.endpointCounter++;
      this.avatarEndpointId = `chat-avatar-stage-${ArkWebChatAvatarStageController.endpointCounter}`;
    }
    try {
      const self: ArkWebChatAvatarStageController = this;
      ArkWebAvatarChatBridge.getInstance().registerAvatarEndpoint(
        this.avatarEndpointId,
        async (result: ArkWebAvatarChatFinalResult): Promise<void> => {
          await self.onBridgeFinalResult(result);
        }
      );
      console.info(LOG_TAG, `registerAvatarEndpoint id=${this.avatarEndpointId}`);
    } catch (e) {
      console.warn(LOG_TAG, 'registerAvatarEndpoint failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /** 注销 Avatar endpoint。 */
  private unregisterAvatarEndpoint(): void {
    if (this.avatarEndpointId.length === 0) {
      return;
    }
    try {
      ArkWebAvatarChatBridge.getInstance().unregisterAvatarEndpoint(this.avatarEndpointId);
      console.info(LOG_TAG, `unregisterAvatarEndpoint id=${this.avatarEndpointId}`);
    } catch (e) {
      console.warn(LOG_TAG, 'unregisterAvatarEndpoint failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
    this.avatarEndpointId = '';
  }

  /**
   * Bridge Avatar endpoint handler 入口。
   *
   * Phase 4B-2R: 在提交给 LifecycleController 前, 解析 performanceHintJson
   * 更新 currentActionId / currentPoseId / currentExpressionId 等跟踪字段,
   * 供 AI 面板运行时状态显示。
   */
  private async onBridgeFinalResult(result: ArkWebAvatarChatFinalResult): Promise<void> {
    if (this.disposed || this.dialogueLifecycle === null) {
      console.warn(LOG_TAG, `onBridgeFinalResult skipped: disposed=${this.disposed}`);
      // Phase 4B-2R2: 即使 disposed 也要 resolve pending result
      this.resolvePendingPanelPerformance(result.turnId, false,
        'CHAT_STAGE_DISPOSED', 'stage disposed or lifecycle null');
      return;
    }
    // Phase 4B-2R: 解析 hint 更新跟踪字段 (显示用, 执行状态来自 Runtime Debug State)
    this.updateTrackingFromHint(result.performanceHintJson);
    let executed: boolean = false;
    let errorCode: string = '';
    let errorMessage: string = '';
    try {
      executed = await this.dialogueLifecycle.submitFinalAssistantResult(
        result.turnId,
        result.performanceHintJson,
        this.activeModelId
      );
      if (!executed) {
        errorCode = this.dialogueLifecycle.getLastErrorCode();
        errorMessage = this.dialogueLifecycle.getLastErrorMessage();
      }
    } catch (e) {
      executed = false;
      errorCode = 'ON_BRIDGE_FINAL_THREW';
      errorMessage = e instanceof Error ? e.message : String(e);
      console.warn(LOG_TAG, 'onBridgeFinalResult threw: ' + errorMessage);
    }
    // Phase 4B-2R2: 记录最后 Lifecycle 状态供诊断显示
    if (this.dialogueLifecycle !== null) {
      this.lastLifecycleState = this.dialogueLifecycle.getState().toString();
    }
    // Phase 4B-2R2: 刷新 Runtime Debug State 后 resolve pending result
    await this.refreshRuntimeDebugStates();
    this.resolvePendingPanelPerformance(result.turnId, executed, errorCode, errorMessage);
  }

  /**
   * Phase 4B-2R2: 刷新动画/姿势/表情 Runtime Debug State。
   *
   * 在 onBridgeFinalResult 执行完成后调用, 收集真实 Runtime 状态供面板显示。
   */
  private async refreshRuntimeDebugStates(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return;
    }
    try {
      const animJson: string = await this.arkWebController.getAnimationDebugState();
      if (!this.disposed) {
        this.parseAnimationDebugState(animJson);
      }
    } catch (e) {
      console.warn(LOG_TAG, 'refreshRuntimeDebugStates anim failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
    try {
      await this.refreshPoseDebugState();
    } catch (e) {
      console.warn(LOG_TAG, 'refreshRuntimeDebugStates pose failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
    try {
      await this.refreshExpressionDebugState();
    } catch (e) {
      console.warn(LOG_TAG, 'refreshRuntimeDebugStates expr failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * Phase 4B-2R2: resolve pending panel performance result。
   *
   * 如果 turnId 对应的 resolver 存在, 调用它并清理。
   * 不存在则 no-op (可能是 publishPerformanceFromPanel 旧路径或超时已触发)。
   */
  private resolvePendingPanelPerformance(
    turnId: string,
    executed: boolean,
    errorCode: string,
    errorMessage: string
  ): void {
    const resolver = this.pendingPanelPerformanceResolvers.get(turnId);
    if (resolver === undefined) {
      return;
    }
    this.pendingPanelPerformanceResolvers.delete(turnId);
    const lifecycleState: string = this.dialogueLifecycle !== null
      ? this.dialogueLifecycle.getState() : 'DISPOSED';
    const commandId: string = this.dialogueLifecycle !== null
      ? this.dialogueLifecycle.getCurrentCommandId() : '';
    const panelResult: ArkWebPanelPerformanceResult = {
      accepted: true,
      executed: executed,
      turnId: turnId,
      commandId: commandId,
      lifecycleState: lifecycleState,
      animationState: this.debugAnimationStateStr,
      poseState: this.poseRuntimeState,
      expressionState: this.expressionRuntimeState,
      errorCode: errorCode,
      errorMessage: errorMessage
    };
    try {
      resolver(panelResult);
    } catch (_e) {
      // 忽略 resolver 异常
    }
  }

  /**
   * Phase 4B-2R: 从 performanceHintJson 解析 motionType / motionId / expressionId,
   * 更新 currentActionId / currentPoseId / currentExpressionId 等跟踪字段。
   *
   * 显示名 (displayName) 通过能力目录查找, 找不到时使用 ID 作为兜底。
   */
  private updateTrackingFromHint(hintJson: string): void {
    if (hintJson.length === 0) {
      return;
    }
    try {
      const hint: Record<string, Object> = JSON.parse(hintJson) as Record<string, Object>;
      const motionType: string = (hint['motionType'] as string) || 'none';
      const motionId: string = (hint['motionId'] as string) || '';
      const expressionId: string = (hint['expressionId'] as string) || '';

      if (motionType === 'animation') {
        this.currentActionId = motionId;
        this.currentActionDisplayName = this.resolveAnimationDisplayName(motionId);
        this.animationRuntimeState = 'LOADING';
      } else if (motionType === 'pose') {
        this.currentPoseId = motionId;
        this.currentPoseDisplayName = this.resolvePoseDisplayName(motionId);
        this.poseRuntimeState = 'APPLYING';
      }

      if (expressionId.length > 0) {
        this.currentExpressionId = expressionId;
        const aliasMap: Record<string, string> = this.expressionAliasMap;
        this.currentExpressionActualName = aliasMap[expressionId] ?? '';
        this.expressionRuntimeState = 'APPLYING';
      }
    } catch (e) {
      console.warn(LOG_TAG, 'updateTrackingFromHint parse failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /** Phase 4B-2R: 从缓存的能力快照查找动画显示名, 找不到时返回 actionId。 */
  private resolveAnimationDisplayName(actionId: string): string {
    if (actionId.length === 0 || this.cachedCapabilitySnapshot === null) {
      return actionId;
    }
    const anims: ArkWebAvatarAiAnimationCapability[] = this.cachedCapabilitySnapshot!.animations;
    for (let i = 0; i < anims.length; i++) {
      if (anims[i].actionId === actionId) {
        return anims[i].displayName;
      }
    }
    return actionId;
  }

  /** Phase 4B-2R: 从缓存的能力快照查找姿势显示名, 找不到时返回 poseId。 */
  private resolvePoseDisplayName(poseId: string): string {
    if (poseId.length === 0 || this.cachedCapabilitySnapshot === null) {
      return poseId;
    }
    const poses: ArkWebAvatarAiPoseCapability[] = this.cachedCapabilitySnapshot!.poses;
    for (let i = 0; i < poses.length; i++) {
      if (poses[i].poseId === poseId) {
        return poses[i].displayName;
      }
    }
    return poseId;
  }

  /**
   * Phase 4B-2R: 生成稳定本地 Turn ID (chat_ai_panel_<pageInstanceId>_<incrementingSequence>)。
   *
   * 要求:
   *   - sequence 每次点击递增 (动画/姿势/表情共用同一计数器)
   *   - 重复点击同一能力不会使用相同 turnId (Bridge 按重复 Turn 忽略后续请求)
   *   - 禁止使用固定字符串 turnId / 只用 actionId / 只用 poseId 作为 turnId
   */
  private generatePanelTurnId(): string {
    ArkWebChatAvatarStageController.panelTurnIdCounter++;
    return `chat_ai_panel_${this.pageInstanceId}_${ArkWebChatAvatarStageController.panelTurnIdCounter}`;
  }

  /**
   * 延迟工具 (有限次数轮询使用, 非 setInterval)。
   */
  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 更新 Stage 状态并通知监听器。
   */
  private setStageState(state: ArkWebChatAvatarStageState, detail: string): void {
    this.currentStageState = state;
    this.currentDetail = detail;
    console.info(LOG_TAG, `stageState=${state} detail=${detail}`);
    if (this.eventListener !== null) {
      this.eventListener.onStateChanged(state, detail);
    }
  }
}
