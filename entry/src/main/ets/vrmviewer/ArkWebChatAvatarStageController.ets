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
import {
  ArkWebModelResourceProvider
} from './ArkWebModelResourceProvider';
import {
  WebModelResource
} from './ArkWebModelResourceTypes';
import {
  ArkWebAvatarModelAsset
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
  ArkWebAvatarAiCapabilitySnapshot
} from './ArkWebAvatarAiTypes';
import {
  ArkWebAvatarChatBridge
} from '../services/avatar/ArkWebAvatarChatBridge';
import {
  ArkWebAvatarChatFinalResult,
  ArkWebAvatarChatFinalResultSource
} from '../services/avatar/ArkWebAvatarChatBridgeTypes';

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
 * 单人聊天页面透明 Avatar Stage 控制器。
 */
export class ArkWebChatAvatarStageController implements ArkWebViewerEventListener {
  /** ArkWeb VRM Viewer 主控制器 (复用,不复制) */
  private arkWebController: ArkWebVrmViewerController = new ArkWebVrmViewerController();
  /** 持久化资产库 (独立实例,读取同一 filesDir 目录) */
  private assetLibrary: ArkWebAvatarAssetLibrary | null = null;
  /** 持久化模型存储 */
  private persistentModelStore: ArkWebPersistentModelStore | null = null;
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
      restoreGeneration: this.modelRestoreGeneration
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

    // 4. 创建演出运行时
    if (this.performanceRuntime === null) {
      const self: ArkWebChatAvatarStageController = this;
      const deps: ArkWebVrmViewerPagePerformanceRuntimeDeps = {
        getArkWebController: (): ArkWebVrmViewerController | null => self.arkWebController,
        getAssetLibrary: (): ArkWebAvatarAssetLibrary | null => self.assetLibrary,
        getPersistentPoseStore: (): null => null,
        getExpressionAliasMap: (): Record<string, string> => ({} as Record<string, string>),
        getDebugAnimationState: (): string => '',
        loadAnimationByActionId: (_actionId: string): Promise<boolean> => {
          console.warn(LOG_TAG, 'loadAnimationByActionId called but not supported in chat stage');
          return Promise.resolve(true);
        },
        waitForAnimationReady: (_timeoutMs: number): Promise<boolean> => Promise.resolve(true),
        resetPoseInternal: (): Promise<boolean> => {
          return self.arkWebController.resetPose().then((json: string): boolean => {
            try {
              const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
              return obj['success'] === true;
            } catch (_e) {
              return false;
            }
          });
        },
        applyPoseByIdInternal: (poseId: string): Promise<boolean> => {
          console.warn(LOG_TAG, 'applyPoseByIdInternal not fully supported in chat stage: ' + poseId);
          return Promise.resolve(false);
        }
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
          return self.performanceController.stopPerformance();
        },
        executePerformance: (cmd: ArkWebAvatarPerformanceCommand): Promise<boolean> => {
          if (self.performanceController === null) {
            return Promise.resolve(false);
          }
          return self.performanceController.executeCommand(cmd).then(
            (result: ArkWebPerformanceResult): boolean => result.success
          );
        }
      };
      this.dialogueLifecycle =
        new ArkWebDialoguePerformanceLifecycleController(this.dialogueMapper, lifecycleRuntime);
    }

    // 7. 创建 AI 能力目录
    if (this.capabilityCatalog === null && this.assetLibrary !== null) {
      this.capabilityCatalog = new ArkWebAvatarAiCapabilityCatalog(this.assetLibrary);
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
   * @returns WebResourceResponse (拦截并返回本地文件) 或 null (放行,交由 Web 默认处理)
   */
  interceptResourceRequest(
    url: string,
    method: string,
    requestHeaders: Array<Header>
  ): WebResourceResponse | null {
    if (this.disposed || this.resourceProvider === null) {
      return null;
    }
    if (!this.resourceProvider.matchesRequest(url)) {
      return null;
    }
    const result = this.resourceProvider.handleRequest(url, method, requestHeaders);
    if (result.response !== null) {
      return result.response;
    }
    console.warn(LOG_TAG,
      `resource handleRequest returned null: ${result.errorCode} ${result.errorMessage}`);
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
   * AI 面板发布演出 (source = CHAT_AI_PANEL)。
   */
  async publishPerformanceFromPanel(performanceHintJson: string): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    const turnId: string = this.generatePanelTurnId();
    const result: ArkWebAvatarChatFinalResult = {
      turnId: turnId,
      performanceHintJson: performanceHintJson,
      finalizedAt: Date.now(),
      source: ArkWebAvatarChatFinalResultSource.CHAT_AI_PANEL
    };
    try {
      const ok: boolean = await ArkWebAvatarChatBridge.getInstance().publishFinalResult(result);
      if (!ok) {
        console.warn(LOG_TAG, `publishPerformanceFromPanel rejected: turnId=${turnId}`);
      }
      return ok;
    } catch (e) {
      console.warn(LOG_TAG, 'publishPerformanceFromPanel threw: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
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
   */
  async getCapabilitySnapshot(): Promise<ArkWebAvatarAiCapabilitySnapshot | null> {
    if (this.disposed || this.capabilityCatalog === null) {
      return null;
    }
    try {
      return await this.capabilityCatalog.buildSnapshot(this.activeModelId);
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
    console.info(LOG_TAG, 'dispose');

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
        // MODEL_READY 后立即全身构图 (受尺寸有效性保护)
        if (this.stageWidth > 0 && this.stageHeight > 0) {
          await this.fitFullBodyInternal();
        } else {
          console.warn(LOG_TAG, 'fitAvatarFullBody skipped: size invalid, will retry on onAreaChange');
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
   * 调用 fitAvatarFullBody 完成全身构图 (Phase 4B-1R §第六项 调用时机)。
   *
   * 只在以下条件全部成立时调用:
   *   - stageState = MODEL_READY
   *   - stageWidth > 0
   *   - stageHeight > 0
   *   - 未 dispose
   *   - restoreGeneration 仍有效 (此处简化为 disposed 检查, generation 检查在调用方)
   *
   * 失败时保留模型, 不隐藏 Stage, 不修改 model.scene.position/scale。
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
      const resultJson: string = await this.arkWebController.fitAvatarFullBody();
      if (this.disposed) {
        return;
      }
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] === true) {
        console.info(LOG_TAG, 'fitAvatarFullBody ok');
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
   */
  private async onBridgeFinalResult(result: ArkWebAvatarChatFinalResult): Promise<void> {
    if (this.disposed || this.dialogueLifecycle === null) {
      console.warn(LOG_TAG, `onBridgeFinalResult skipped: disposed=${this.disposed}`);
      return;
    }
    try {
      await this.dialogueLifecycle.submitFinalAssistantResult(
        result.turnId,
        result.performanceHintJson,
        this.activeModelId
      );
    } catch (e) {
      console.warn(LOG_TAG, 'onBridgeFinalResult threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * 生成稳定本地 Turn ID (chat-ai-panel-<timestamp>-<counter>)。
   */
  private generatePanelTurnId(): string {
    ArkWebChatAvatarStageController.endpointCounter++;
    return `chat-ai-panel-${Date.now()}-${ArkWebChatAvatarStageController.endpointCounter}`;
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
