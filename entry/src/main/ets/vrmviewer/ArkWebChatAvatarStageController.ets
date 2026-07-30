/**
 * ArkWebChatAvatarStageController — 单人聊天页面透明 Avatar Stage 控制器 (Phase 4B-1)
 *
 * 职责:
 *   - 创建聊天页面专用 ArkWeb 实例 (复用 ArkWebVrmViewerController)
 *   - 加载本地 vrmviewer 页面 (与 VrmViewerPage 相同的 rawfile 资源)
 *   - onPageEnd 后调用 setRenderProfile('CHAT_STAGE') 进入透明渲染模式
 *   - AssetLibrary READY 时读取 activeModelId, 注册 Provider, 加载持久模型
 *   - 模型 READY 后调用 fitAvatarFullBody 完成全身构图
 *   - 注册 Avatar endpoint 到 ArkWebAvatarChatBridge (覆盖式)
 *   - 通过 LifecycleController 消费 Bridge 投递的 performanceHint
 *   - 提供 getCapabilitySnapshot / cancelPerformance 给 AI 面板调用
 *
 * 不做的事:
 *   - 不复制 VRM Loader / AnimationMixer / ExpressionManager 等底层实现
 *   - 不修改背景图片 / Scene 背景色 (透明由 Web 端 CHAT_STAGE profile 完成)
 *   - 不实现真实 AI Tool Calling / 镜头导演 / 脸部特写
 *   - 不创建 setInterval 轮询 (尺寸变化由组件 onAreaChange 触发)
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
 *   - 模型 READY → onModelReady() (fitAvatarFullBody + 刷新能力快照)
 *   - ChatAvatarStage aboutToDisappear → dispose()
 *
 * Reference:
 *   - AGENTS.md Phase 4B-1 §页面层级 / §渲染 Profile / §模型自动恢复
 *   - VrmViewerPage.ets (startActiveModelRestore / processRestoredFile 参考)
 *   - ArkWebVrmViewerController.ets (Web 实例管理)
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
 * Stage 状态 (供 UI 显示)。
 */
export enum ChatAvatarStageState {
  /** 初始状态 / 未初始化 */
  IDLE = 'IDLE',
  /** Web 加载中 */
  WEB_LOADING = 'WEB_LOADING',
  /** Viewer 初始化中 */
  VIEWER_INITIALIZING = 'VIEWER_INITIALIZING',
  /** Viewer 就绪, 等待模型恢复 */
  VIEWER_READY = 'VIEWER_READY',
  /** 模型恢复中 */
  MODEL_RESTORING = 'MODEL_RESTORING',
  /** 模型就绪 */
  MODEL_READY = 'MODEL_READY',
  /** 无激活模型 */
  EMPTY = 'EMPTY',
  /** 失败 */
  FAILED = 'FAILED',
  /** 已销毁 */
  DISPOSED = 'DISPOSED'
}

/**
 * Stage 事件监听器 (供 ChatAvatarStage 组件订阅状态变化)。
 */
export interface ChatAvatarStageEventListener {
  onStateChanged(state: ChatAvatarStageState, detail: string): void;
  onModelNameChanged(displayName: string): void;
}

/**
 * 单人聊天页面透明 Avatar Stage 控制器。
 *
 * 使用方式:
 *   1. ChatAvatarStage aboutToAppear: controller.init(ctx)
 *   2. Web 组件 controller 属性: controller.getWebviewController()
 *   3. Web 组件 onControllerAttached: controller.onWebControllerAttached()
 *   4. Web 组件 onPageEnd: controller.onWebPageEnd()
 *   5. AI 面板点击能力: controller.publishPerformanceFromPanel(hintJson)
 *   6. AI 面板停止: controller.cancelPerformance()
 *   7. ChatAvatarStage aboutToDisappear: controller.dispose()
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
  /** 演出运行时 (复用 VrmViewerPage 的 Runtime 实现) */
  private performanceRuntime: ArkWebVrmViewerPagePerformanceRuntime | null = null;
  /** 对话演出映射器 */
  private dialogueMapper: ArkWebDialoguePerformanceMapper | null = null;
  /** 对话演出生命周期控制器 */
  private dialogueLifecycle: ArkWebDialoguePerformanceLifecycleController | null = null;
  /** AI 能力目录 */
  private capabilityCatalog: ArkWebAvatarAiCapabilityCatalog | null = null;

  /** 当前 Stage 状态 */
  private currentState: ChatAvatarStageState = ChatAvatarStageState.IDLE;
  /** 状态详细描述 */
  private currentDetail: string = '未初始化';
  /** 事件监听器 (ChatAvatarStage 组件) */
  private eventListener: ChatAvatarStageEventListener | null = null;
  /** 是否已销毁 */
  private disposed: boolean = false;

  /** Avatar endpoint ID (覆盖式注册到 Bridge) */
  private avatarEndpointId: string = '';
  /** endpoint ID 计数器 (跨实例唯一) */
  private static endpointCounter: number = 0;

  /** 当前激活模型 ID (空字符串表示无) */
  private activeModelId: string = '';
  /** 当前激活模型显示名 */
  private activeModelDisplayName: string = '';

  /** 模型恢复单次触发保护 */
  private modelRestoreStarted: boolean = false;
  /** 模型恢复代次 (用于过期判断) */
  private modelRestoreGeneration: number = 0;
  /** 模型恢复中 */
  private modelRestoreInProgress: boolean = false;

  /** 已准备的资源 (供 loadPreparedModelResource 使用) */
  private preparedResource: WebModelResource | null = null;

  /** 是否已应用 CHAT_STAGE 渲染 Profile */
  private chatStageProfileApplied: boolean = false;

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

  /** 获取当前状态。 */
  getState(): ChatAvatarStageState {
    return this.currentState;
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

  /**
   * 初始化控制器 (在 ChatAvatarStage aboutToAppear 中调用)。
   *
   * 流程:
   *   1. 创建 AssetLibrary / PersistentModelStore / ResourceProvider
   *   2. 创建 PerformanceController + Runtime + Mapper + Lifecycle
   *   3. 创建 AiCapabilityCatalog
   *   4. 注册 Avatar endpoint 到 Bridge
   *   5. 异步 ensureInitialized AssetLibrary
   */
  init(ctx: common.UIAbilityContext): void {
    if (this.disposed) {
      return;
    }
    this.setState(ChatAvatarStageState.WEB_LOADING, '正在加载 Web Viewer...');

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

    // 4. 创建演出运行时 (复用 VrmViewerPage 的 Runtime 实现)
    if (this.performanceRuntime === null) {
      const self: ArkWebChatAvatarStageController = this;
      const deps: ArkWebVrmViewerPagePerformanceRuntimeDeps = {
        getArkWebController: (): ArkWebVrmViewerController | null => self.arkWebController,
        getAssetLibrary: (): ArkWebAvatarAssetLibrary | null => self.assetLibrary,
        getPersistentPoseStore: (): null => null, // 聊天 Stage 不需要姿势存储
        getExpressionAliasMap: (): Record<string, string> => ({} as Record<string, string>),
        getDebugAnimationState: (): string => '',
        loadAnimationByActionId: (_actionId: string): Promise<boolean> => {
          // 聊天 Stage 不支持动画导入流程, 由 PerformanceController 直接 playAnimationById
          // 但 Runtime.playAnimationById 内部会调用此回调; 这里返回 true 跳过加载,
          // 让 playAnimation 直接调用 (动画资源应在 VrmViewerPage 已导入)
          console.warn(LOG_TAG, 'loadAnimationByActionId called but not supported in chat stage');
          return Promise.resolve(true);
        },
        waitForAnimationReady: (_timeoutMs: number): Promise<boolean> => Promise.resolve(true),
        resetPoseInternal: (): Promise<boolean> => {
          // 复用 arkWebController.resetPose
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
          // 聊天 Stage 不持久化姿势数据, 这里通过 readPoseDataAsJson + applyPose 实现
          // 但本阶段不实现完整姿势应用, 返回 false 让 PerformanceController 记录失败
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

    // 9. 异步初始化 AssetLibrary (不阻塞 Web 加载)
    if (this.assetLibrary !== null) {
      this.assetLibrary.ensureInitialized().then((ok: boolean): void => {
        if (ok) {
          console.info(LOG_TAG, 'AssetLibrary initialized');
        } else {
          console.warn(LOG_TAG, 'AssetLibrary ensureInitialized failed');
        }
      }).catch((e: Object): void => {
        console.warn(LOG_TAG, 'AssetLibrary init exception: ' +
          (e instanceof Error ? e.message : String(e)));
      });
    }
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
   * Web 组件 onPageEnd 回调入口。
   *
   * 触发 Viewer 初始化; Viewer READY 后由 onStateChanged 推进到下一步。
   */
  async onWebPageEnd(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.setState(ChatAvatarStageState.VIEWER_INITIALIZING, '正在初始化 Viewer...');
    await this.arkWebController.onPageEnd();
  }

  /**
   * AI 面板发布演出 (source = CHAT_AI_PANEL)。
   *
   * 流程:
   *   1. 生成稳定本地 Turn ID (chat-ai-panel-<timestamp>-<counter>)
   *   2. 通过 AvatarChatBridge.publishFinalResult 投递
   *   3. Bridge 投递回当前 Avatar endpoint (本控制器) → LifecycleController
   *
   * @param performanceHintJson 结构化 Hint JSON (motionType/motionId/expressionId 等)
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
   * 重新计算全身构图 (页面尺寸变化时调用)。
   *
   * 防抖: 仅在 MODEL_READY 状态下调用 fitAvatarFullBody;
   * 输入法弹出等小幅变化由组件层通过尺寸阈值过滤。
   */
  async refitFullBody(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.currentState !== ChatAvatarStageState.MODEL_READY) {
      return;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return;
    }
    try {
      const resultJson: string = await this.arkWebController.fitAvatarFullBody();
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] !== true) {
        console.warn(LOG_TAG, 'refitFullBody failed: ' + resultJson);
      }
    } catch (e) {
      console.warn(LOG_TAG, 'refitFullBody threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * 销毁控制器 (在 ChatAvatarStage aboutToDisappear 中调用)。
   *
   * 流程:
   *   1. 注销 Avatar endpoint
   *   2. 销毁 LifecycleController / PerformanceController / Catalog
   *   3. 销毁 ResourceProvider / PersistentModelStore (不删除 filesDir 数据)
   *   4. 销毁 ArkWebController (销毁 Web 实例)
   *   5. state = DISPOSED
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
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
    // 不销毁 AssetLibrary / PersistentModelStore (它们由 VrmViewerPage 主实例管理)
    // 仅清除引用
    this.assetLibrary = null;
    this.persistentModelStore = null;
    this.performanceRuntime = null;
    this.dialogueMapper = null;

    // 4. 销毁 ArkWebController (销毁 Web 实例)
    try {
      this.arkWebController.destroy();
    } catch (e) {
      console.warn(LOG_TAG, 'arkWebController.destroy threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }

    this.setState(ChatAvatarStageState.DISPOSED, '已销毁');
  }

  // ===== ArkWebViewerEventListener 实现 =====

  /**
   * Viewer 状态变化回调。
   *
   * 关键转换:
   *   - READY → 应用 CHAT_STAGE Profile + 启动模型恢复
   *   - FAILED → 进入 FAILED 状态
   */
  onStateChanged(state: ArkWebViewerState, detail: string): void {
    if (this.disposed) {
      return;
    }
    console.info(LOG_TAG, `Viewer state changed: ${state} detail=${detail}`);
    if (state === ArkWebViewerState.READY) {
      this.setState(ChatAvatarStageState.VIEWER_READY, 'Viewer 就绪');
      this.onViewerReady();
    } else if (state === ArkWebViewerState.FAILED) {
      this.setState(ChatAvatarStageState.FAILED, `Viewer 失败: ${detail}`);
    } else if (state === ArkWebViewerState.INITIALIZING) {
      this.setState(ChatAvatarStageState.VIEWER_INITIALIZING, detail);
    }
  }

  onError(code: string, message: string): void {
    console.warn(LOG_TAG, `Viewer error: code=${code} msg=${message}`);
  }

  // ===== 内部方法 =====

  /**
   * Viewer READY 后的处理。
   *
   * 流程:
   *   1. 应用 CHAT_STAGE 渲染 Profile (透明背景 + 关闭网格)
   *   2. 启动模型自动恢复
   */
  private async onViewerReady(): Promise<void> {
    if (this.disposed) {
      return;
    }
    // 1. 应用 CHAT_STAGE Profile (幂等)
    if (!this.chatStageProfileApplied) {
      try {
        const resultJson: string = await this.arkWebController.setRenderProfile(
          ArkWebRenderProfile.CHAT_STAGE
        );
        const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
        if (obj['success'] === true) {
          this.chatStageProfileApplied = true;
          console.info(LOG_TAG, 'CHAT_STAGE profile applied');
        } else {
          console.warn(LOG_TAG, 'setRenderProfile failed: ' + resultJson);
        }
      } catch (e) {
        console.warn(LOG_TAG, 'setRenderProfile threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
    }

    // 2. 启动模型自动恢复
    this.startActiveModelRestore();
  }

  /**
   * 启动 activeModel 自动恢复 (参考 VrmViewerPage.startActiveModelRestore)。
   *
   * 流程:
   *   1. 单次触发保护
   *   2. 等待 AssetLibrary 初始化
   *   3. 查找 activeModelId
   *   4. 有 active model: 验证文件 → 注册 Provider → prepareModelResource → loadPreparedModelResource
   *   5. 无 active model: 进入 EMPTY 状态 (Stage 保持透明)
   */
  private async startActiveModelRestore(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.modelRestoreStarted) {
      return;
    }
    if (this.arkWebController.getState() !== ArkWebViewerState.READY) {
      return;
    }
    if (this.modelRestoreInProgress) {
      return;
    }
    if (this.assetLibrary === null || this.persistentModelStore === null
        || this.resourceProvider === null) {
      console.warn(LOG_TAG, 'startActiveModelRestore: deps null');
      return;
    }

    this.modelRestoreStarted = true;
    this.modelRestoreInProgress = true;
    this.modelRestoreGeneration++;
    const generation: number = this.modelRestoreGeneration;
    this.setState(ChatAvatarStageState.MODEL_RESTORING, '正在恢复模型...');

    try {
      const initOk: boolean = await this.assetLibrary.ensureInitialized();
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return;
      }
      if (!initOk) {
        this.setState(ChatAvatarStageState.FAILED, 'AssetLibrary 初始化失败');
        return;
      }

      const activeAsset: ArkWebAvatarModelAsset | null = await this.assetLibrary.findActiveModel();
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return;
      }

      if (activeAsset === null) {
        // 无 active model, 进入空状态 (Stage 保持透明, 不报错)
        this.activeModelId = '';
        this.activeModelDisplayName = '';
        this.setState(ChatAvatarStageState.EMPTY, '无激活模型');
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

      const loaded: boolean = await this.validateRegisterAndLoadPersistentAsset(activeAsset, generation);
      if (generation !== this.modelRestoreGeneration || this.disposed) {
        return;
      }
      if (loaded) {
        this.setState(ChatAvatarStageState.MODEL_READY, '模型就绪');
        // 模型 READY 后立即全身构图
        await this.fitFullBodyInternal();
        console.info(LOG_TAG, 'active model restored successfully');
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.setState(ChatAvatarStageState.FAILED, `恢复异常: ${msg}`);
    } finally {
      this.modelRestoreInProgress = false;
    }
  }

  /**
   * 验证、注册并加载持久化模型资产 (参考 VrmViewerPage.validateRegisterAndLoadPersistentAsset)。
   */
  private async validateRegisterAndLoadPersistentAsset(
    asset: ArkWebAvatarModelAsset,
    generation: number
  ): Promise<boolean> {
    if (this.disposed || this.persistentModelStore === null || this.resourceProvider === null) {
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
      console.warn(LOG_TAG, `validate failed: ${err}`);
      return false;
    }

    // 2. 注册到 Provider
    const absolutePath: string = this.persistentModelStore.resolveAbsolutePath(asset.relativePath);
    if (absolutePath.length === 0) {
      console.warn(LOG_TAG, 'resolveAbsolutePath empty');
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
      console.warn(LOG_TAG, `register failed: ${msg}`);
      return false;
    }
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }
    this.preparedResource = resource;
    console.info(LOG_TAG, `persistent asset registered: url=${resource.resourceUrl}`);

    // 3. prepareModelResource (将资源元数据同步到 Web 端 keeper)
    const resourceJson: string = JSON.stringify({
      resourceUrl: resource.resourceUrl,
      displayName: resource.displayName,
      mimeType: resource.mimeType,
      size: resource.size,
      extension: resource.extension
    });
    const prepareResult: string = await this.arkWebController.prepareModelResource(resourceJson);
    try {
      const obj: Record<string, Object> = JSON.parse(prepareResult) as Record<string, Object>;
      if (obj['success'] !== true) {
        console.warn(LOG_TAG, `prepareModelResource failed: ${prepareResult}`);
        return false;
      }
    } catch (e) {
      console.warn(LOG_TAG, `prepareModelResource result invalid: ${prepareResult}`);
      return false;
    }
    if (generation !== this.modelRestoreGeneration || this.disposed) {
      return false;
    }

    // 4. loadPreparedModelResource (触发实际加载)
    const loadResult: string = await this.arkWebController.loadPreparedModelResource();
    try {
      const obj: Record<string, Object> = JSON.parse(loadResult) as Record<string, Object>;
      if (obj['success'] !== true) {
        console.warn(LOG_TAG, `loadPreparedModelResource failed: ${loadResult}`);
        return false;
      }
    } catch (e) {
      console.warn(LOG_TAG, `loadPreparedModelResource result invalid: ${loadResult}`);
      return false;
    }

    return true;
  }

  /**
   * 调用 fitAvatarFullBody 完成全身构图 (基于模型 BoundingBox, 不缩放模型)。
   */
  private async fitFullBodyInternal(): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      const resultJson: string = await this.arkWebController.fitAvatarFullBody();
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      if (obj['success'] === true) {
        console.info(LOG_TAG, 'fitAvatarFullBody ok');
      } else {
        console.warn(LOG_TAG, 'fitAvatarFullBody failed: ' + resultJson);
      }
    } catch (e) {
      console.warn(LOG_TAG, 'fitAvatarFullBody threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * 注册 Avatar endpoint 到 Bridge (覆盖式)。
   *
   * handler 委托给 dialogueLifecycle.submitFinalAssistantResult,
   * 不直接调用 PerformanceController / Mapper。
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
   * 委托给 dialogueLifecycle.submitFinalAssistantResult,
   * 不直接调用 PerformanceController / Mapper。
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
   *
   * 禁止使用动作名称作为 turnId。
   */
  private generatePanelTurnId(): string {
    ArkWebChatAvatarStageController.endpointCounter++;
    return `chat-ai-panel-${Date.now()}-${ArkWebChatAvatarStageController.endpointCounter}`;
  }

  /**
   * 更新状态并通知监听器。
   */
  private setState(state: ChatAvatarStageState, detail: string): void {
    this.currentState = state;
    this.currentDetail = detail;
    if (this.eventListener !== null) {
      this.eventListener.onStateChanged(state, detail);
    }
  }
}
