/**
 * ChatPage 聊天页面(UI-CHAT-01 视觉重构)
 *
 * 设计依据:
 * - docs/ui_reference/generated/pages/chat_page.md
 * - docs/ui_reference/generated/screens/CHAT_PAGE_009.md
 * - docs/ui_reference/generated/glm_context.md 1.9 / 2.x
 *
 * 视觉结构:
 * - TopNavigation:返回 + 汉堡(打开会话列表) + 头像 + 角色名 + 更多(打开 ChatMoreMenuSheet)
 * - MessageArea:Scroll + ForEach,消息气泡由 ChatMessageBubble 渲染
 * - OptionalFloatingControls:回到底部 + 再试一次(条件渲染)
 * - InputArea:TextArea + 发送/停止按钮
 * - ConditionalOverlays:会话列表 / 更多菜单 / 消息操作菜单 / 清空确认
 *
 * 业务约束:
 * - 不显示无功能按钮(全屏 / 加号 / 齿轮未实现不显示)
 * - 不显示字数统计(ChatViewModel 无 4000 字限制,不引入虚假限制)
 * - 再试一次仅在 canRegenerate && !isGenerating && messages.length > 0 时显示
 * - 复用 ChatViewModel 所有接口,不修改业务逻辑
 * - 颜色全部使用 $r('app.color.*') 资源,自动适配深色模式
 */

import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { AvatarToolCallingStatus } from '../services/ChatService';
import { ArkWebAvatarDialogueStrategyStatus } from '../avatarai/ArkWebAvatarDialogueStrategyTypes';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatMessageRenderState } from '../models/ChatMessageRenderState';
import { MessageSwipeSummary, MAX_SWIPE_CANDIDATES } from '../models/MessageSwipe';
import { MessageSwipeControls } from '../components/MessageSwipeControls';
import { HistoricalMessageEditDialog } from '../components/HistoricalMessageEditDialog';
import { ChatMessageBubble } from '../components/ChatMessageBubble';
import { ChatMessageDataSource } from '../components/ChatMessageDataSource';
import { ChatMessageActionSheet, MessageAction } from '../components/ChatMessageActionSheet';
import { ChatMoreMenuSheet } from '../components/ChatMoreMenuSheet';
import { CharacterImageView } from '../components/CharacterImageView';
import { promptAction, router, window, mediaquery } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { inputMethod } from '@kit.IMEKit';
import { AppServices } from '../services/AppServices';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';
import {
  ChatTextColorMode,
  ChatMarkdownColorTheme,
  DEFAULT_ASSISTANT_TEXT_COLOR,
  DEFAULT_MARKDOWN_ACCENT_COLOR,
  DEFAULT_USER_TEXT_COLOR,
  DEFAULT_SECONDARY_TEXT_COLOR,
  getLightColorTheme,
  getDarkColorTheme,
  getCustomColorTheme,
  isValidHexColor,
  normalizeHexColor
} from '../utils/ChatTextColorTheme';
import { ChatBackgroundConfig } from '../services/ChatBackgroundService';
import { ContextBudgetViewModel } from '../viewmodels/ContextBudgetViewModel';
import { ChatArchiveViewModel } from '../viewmodels/ChatArchiveViewModel';
import { ContextBudgetSnapshotStore } from '../services/ContextBudgetSnapshotStore';
import {
  ContextBudgetStats
} from '../services/ContextBudgetEstimator';
import { ForkChatMode } from '../models/ForkChatOptions';
import { ChatSessionListPanel } from '../components/ChatSessionListPanel';
import { Character } from '../models/Character';
import { Logger } from '../utils/Logger';
import { ArkWebAvatarChatBridge } from '../services/avatar/ArkWebAvatarChatBridge';
import { ChatAvatarStage } from '../components/avatar/ChatAvatarStage';
import {
  ArkWebChatAvatarStageController,
  ArkWebChatAvatarStageState,
  ArkWebChatAvatarStageRuntimeSnapshot,
  ArkWebPanelPerformanceResult,
  ChatAvatarStageEventListener
} from '../vrmviewer/ArkWebChatAvatarStageController';
import {
  ArkWebAvatarShotControlMode,
  ArkWebAvatarShotRuntimeSnapshot
} from '../vrmviewer/ArkWebAvatarShotDirectorTypes';
import {
  ArkWebAvatarAiCapabilitySnapshot,
  ArkWebAvatarAiAnimationCapability,
  ArkWebAvatarAiPoseCapability,
  ArkWebAvatarAiExpressionCapability,
  AI_CAPABILITY_EXPRESSION_DISPLAY_NAMES
} from '../vrmviewer/ArkWebAvatarAiTypes';

const LOG_TAG: string = 'ChatPage';

/**
 * ChatAvatarStage 事件监听器实现 (ArkTS 不允许对象字面量实现接口, 必须用类)。
 *
 * 通过闭包注入回调, 让 ChatPage 在 aboutToAppear 中绑定 @State 更新。
 */
class ChatAvatarStageListenerImpl implements ChatAvatarStageEventListener {
  onStateChangedFn: ((state: ArkWebChatAvatarStageState, detail: string) => void) | null = null;
  onModelNameChangedFn: ((displayName: string) => void) | null = null;

  onStateChanged(state: ArkWebChatAvatarStageState, detail: string): void {
    const fn = this.onStateChangedFn;
    if (fn !== null) {
      fn(state, detail);
    }
  }

  onModelNameChanged(displayName: string): void {
    const fn = this.onModelNameChangedFn;
    if (fn !== null) {
      fn(displayName);
    }
  }
}

@Entry
@Component
struct ChatPage {
  @State viewModel: ChatViewModel | null = null;
  /** 业务消息列表(@State 用于触发消息源数据变更,ForEach 不再直接使用) */
  @State messages: ChatMessage[] = [];
  /** 稳定渲染状态列表(@Observed,ForEach 数据源,key 固定为 messageId) */
  @State messageStates: ChatMessageRenderState[] = [];
  /** messageId → RenderState 缓存(确保同一消息长期对应同一实例) */
  private stateMap: Map<string, ChatMessageRenderState> = new Map<string, ChatMessageRenderState>();
  /** 当前角色对象(用于头像) */
  @State character: Character | null = null;
  /** v11 富文本样式设置 */
  @State chatTextStyle: ChatTextStyle | null = null;
  /** 是否显示更多菜单 */
  @State showMoreMenu: boolean = false;
  /** 是否显示消息操作菜单 */
  @State showActionSheet: boolean = false;
  /** 消息操作菜单目标消息 */
  @State actionSheetMsg: ChatMessage | null = null;
  /** 是否显示清空确认 */
  @State showClearConfirm: boolean = false;
  /** v9: 是否显示本对话称呼覆盖编辑对话框 */
  @State showUserNameOverrideDialog: boolean = false;
  /** v9: 对话称呼输入草稿(对话框中使用) */
  @State userNameOverrideDraft: string = '';
  /** v9: 当前生效的用户称呼(供 ChatMoreMenuSheet 展示) */
  @State resolvedUserName: string = '';
  /** v9: 当前对话级覆盖(供 ChatMoreMenuSheet 展示) */
  @State currentUserNameOverride: string = '';
  /** 是否显示 Fork 模式选择弹窗 */
  @State showForkModePicker: boolean = false;
  /** Fork 操作目标消息 ID */
  private forkTargetMessageId: string = '';
  /** 上下文预算 ViewModel(v8.1) */
  @State budgetViewModel: ContextBudgetViewModel | null = null;
  /** 当前快照统计(由 ChatService 写入) */
  @State budgetStats: ContextBudgetStats | null = null;

  @StorageLink('branchChangeSeq') @Watch('onBranchChangeSeqChanged') branchChangeSeq: number = 0;
  /** 聊天背景配置变更通知(由 ChatBackgroundSettingsPage 通过 AppStorage.setOrCreate 触发) */
  @StorageProp('chatBgConfigVersion') @Watch('onChatBgConfigVersionChanged') chatBgConfigVersion: number = 0;
  /** 上下文预算配置变更通知(由 ContextBudgetPage 通过 AppStorage.setOrCreate 触发) */
  @StorageProp('chatBudgetConfigVersion') @Watch('onBudgetConfigVersionChanged') chatBudgetConfigVersion: number = 0;
  /** 聊天背景配置(为 null 表示未加载) */
  @State chatBgConfig: ChatBackgroundConfig | null = null;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  private scroller: Scroller = new Scroller();
  /** 懒加载数据源(配合 LazyForEach,仅构建可视区域气泡) */
  private dataSource: ChatMessageDataSource = new ChatMessageDataSource();
  private lastMessageCount: number = 0;
  private editDialogController: CustomDialogController | null = null;
  private editingMessageId: string = '';
  /** 键盘高度变化监听句柄 */
  private keyboardHeightChangeHandler: ((height: number) => void) | null = null;
  /** 主窗口实例(用于注销监听) */
  private mainWindow: window.Window | null = null;
  /** 跳转到 PromptPresetListPage 后返回时刷新当前 preset 名 */
  private pendingRefreshPresetName: boolean = false;
  /** 跳转到 BranchMapPage 后返回时重新加载消息和分支状态 */
  private pendingReloadAfterBranchChange: boolean = false;
  /** 已加载过背景配置的 chatId,避免 onMessagesUpdate 反复加载 */
  private lastLoadedBgChatId: string = '';
  /** 键盘弹起延迟滚动定时器 ID(-1 表示无 pending) */
  private keyboardScrollTimerId: number = -1;

  /** T-CHAT.1: 聊天归档 ViewModel(导出当前聊天/角色全部聊天) */
  @State archiveViewModel: ChatArchiveViewModel | null = null;
  /** T-CHAT.1: 导出进行中提示 */
  @State archiveBusy: boolean = false;

  /** 气泡背景不透明度(0.40~0.90,默认 0.65,仅控制背景 Alpha) */
  @State chatBubbleOpacity: number = 0.65;

  /**
   * 字体配色模式(AUTO / LIGHT / DARK / CUSTOM)。
   * 默认 AUTO:保持 ChatRichText 默认资源颜色。
   * 与 chatBubbleOpacity 完全独立:模式只控制文字颜色,不影响气泡背景透明度。
   * 本阶段仅页面生命周期内保存,不持久化。
   */
  @State chatTextColorMode: string = ChatTextColorMode.AUTO;

  /** 自定义模式下助手正文颜色(#RRGGBB,默认 DARK 模式色值) */
  @State chatAssistantTextColor: string = DEFAULT_ASSISTANT_TEXT_COLOR;

  /** 自定义模式下 Markdown 强调色(#RRGGBB,默认品牌蓝) */
  @State chatMarkdownAccentColor: string = DEFAULT_MARKDOWN_ACCENT_COLOR;

  /** 自定义模式下用户消息文字颜色(#RRGGBB,默认白色) */
  @State chatUserTextColor: string = DEFAULT_USER_TEXT_COLOR;

  /** 自定义模式下次级文字颜色(#RRGGBB,默认深灰) */
  @State chatSecondaryTextColor: string = DEFAULT_SECONDARY_TEXT_COLOR;

  /** 显示设置面板可见性(轻量卡片,非 Dialog) */
  @State chatAppearancePanelVisible: boolean = false;

  /** 当前是否为深色模式(用于动态计算气泡背景 RGB) */
  @State isDarkMode: boolean = false;

  /** 深色模式媒体查询监听器(aboutToDisappear 注销) */
  private darkModeListener: mediaquery.MediaQueryListener | null = null;

  /** 气泡不透明度持久化 Preferences key */
  private static readonly PREF_KEY_BUBBLE_OPACITY: string = 'chat_bubble_opacity';

  /** Phase 4A-2: 本页面实例在 AvatarChatBridge 上的 endpointId (aboutToAppear 生成) */
  private chatEndpointId: string = '';

  /** Phase 4A-2: endpointId 自增计数器 (进程内唯一) */
  private static chatEndpointCounter: number = 0;

  /** Phase 4B-1: Avatar Stage 控制器 (透明 VRM 模型展示) */
  @State avatarStageController: ArkWebChatAvatarStageController | null = null;
  /** Phase 4B-1: 模型显示开关 (false 时隐藏 Stage 但不销毁模型) */
  @State chatAvatarVisible: boolean = true;
  /** Phase 4B-1: AI 面板可见性 (右上角 AI 按钮切换) */
  @State aiPanelVisible: boolean = false;
  /** Phase 4B-1: AI 能力快照 (动作/姿势/表情列表, 供 AI 面板展示) */
  @State aiCapabilitySnapshot: ArkWebAvatarAiCapabilitySnapshot | null = null;
  /** Phase 4B-1R: 当前 Stage 状态 (供 AI 面板显示模型名/状态) */
  @State avatarStageState: ArkWebChatAvatarStageState = 'CREATED';
  /** Phase 4B-1R: 当前模型显示名 (供 AI 面板显示) */
  @State avatarModelDisplayName: string = '';
  /** Phase 4B-1R: Stage 运行时快照 (供 AI 面板紧凑诊断显示) */
  @State avatarStageSnapshot: ArkWebChatAvatarStageRuntimeSnapshot | null = null;
  /** Phase 4B-2: 镜头导演运行时快照 (供 AI 面板镜头状态显示) */
  @State avatarShotSnapshot: ArkWebAvatarShotRuntimeSnapshot | null = null;
  /** Phase 4B-2R: AI 面板按钮执行状态 (REQUESTING/LOADING/READY/PLAYING/APPLIED/FAILED/IDLE) */
  @State aiPanelButtonStatus: string = 'IDLE';
  /** Phase 4B-2R: AI 面板当前操作能力 ID (actionId/poseId/expressionId) */
  @State aiPanelActiveCapabilityId: string = '';
  /** Phase 4B-2R: AI 面板最后错误码 (供按钮反馈显示) */
  @State aiPanelLastErrorCode: string = '';
  /** Phase 4A-3: Avatar Tool Calling 权限模式 (DENY / READ_ONLY / CONTROL_THIS_CHAT) */
  @State avatarToolPermissionMode: string = 'DENY';
  /** Phase 4C-1: Avatar 对话演出策略状态 (供 AI 面板显示摘要) */
  @State avatarStrategyStatus: ArkWebAvatarDialogueStrategyStatus | null = null;
  /** Phase 4C-1: 是否展开策略摘要详情 */
  @State avatarStrategySummaryExpanded: boolean = false;
  /** Phase 4A-3: Avatar Tool Calling 状态快照 (供 AI 面板权限区显示) */
  @State avatarToolStatus: AvatarToolCallingStatus | null = null;
  /** 模型大小滑动条值 (fillRatio, 0.3~0.98, 默认 0.78) */
  @State avatarModelFillRatio: number = 0.78;
  /**
   * Phase 4B-2R2: 相机缩放倍率 (0.5~3.0, 默认 1.0)。
   *
   * 通过调整相机距离实现视觉缩放, 不修改模型 transform。
   * 在当前 ChatPage 生命周期内, 镜头切换 / 演出 / 停止 / 失败都不会重置倍率。
   */
  @State avatarCameraZoomMultiplier: number = 1.0;
  /**
   * Phase 4B-2R2: 镜头控制模式 (AUTO / MANUAL_FULL_BODY / MANUAL_FACE_RESET_VIEW)。
   *
   * AUTO: 自动导演 (animation/pose → FULL_BODY, expression-only → FACE_RESET_VIEW)
   * MANUAL_FULL_BODY: 锁定全身镜头, 演出不改变镜头
   * MANUAL_FACE_RESET_VIEW: 锁定脸部镜头, 演出不改变镜头
   */
  @State avatarShotControlMode: ArkWebAvatarShotControlMode = 'AUTO';

  aboutToAppear(): void {
    const modelService = AppServices.getModelService();
    const characterService = AppServices.getCharacterService();
    const promptPresetService = AppServices.getPromptPresetService();
    const chatService = AppServices.createChatService();
    this.chatTextStyle = AppServices.getInstance().chatTextStyleSettings.get();
    const vm: ChatViewModel = new ChatViewModel(
      chatService, modelService, characterService, promptPresetService
    );
    vm.onMessagesUpdate = (msgs: ChatMessage[]): void => {
      // 同步业务数据 + 同步稳定 RenderState 列表
      this.messages = msgs;
      this.syncRenderStates(msgs);
      this.maybeLoadChatBackground();
      // 流式 delta 期间不刷新预算(避免高频 token 估算拖慢 UI)。
      // 只在非流式状态刷新:用户消息加入 / 回复完成 / 编辑删除 / Swipe / 分支切换 / 页面进入。
      // 其他触发点(onPageShow / onBudgetConfigVersionChanged / onBranchChangeSeqChanged)保持不变。
      const isStreaming: boolean = msgs.length > 0 && msgs[msgs.length - 1].isStreaming === true;
      if (!isStreaming) {
        this.refreshBudgetSnapshot();
      }
    };
    this.viewModel = vm;

    // 初始化上下文预算 ViewModel(v8.1)
    // 复用 line 109 的 modelService,避免重复声明
    const budgetService = AppServices.getContextBudgetService();
    const tokenCounter = AppServices.getTokenCounter();
    this.budgetViewModel = new ContextBudgetViewModel(
      budgetService, modelService, tokenCounter
    );

    const pendingChatId: string = AppStorage.get<string>('pendingChatId') ?? '';
    const pendingCharacterId: string = AppStorage.get<string>('pendingCharacterId') ?? '';
    if (pendingChatId.length > 0) {
      AppStorage.set<string>('pendingChatId', '');
      if (pendingCharacterId.length > 0) {
        AppStorage.set<string>('pendingCharacterId', '');
        this.loadCharacterAvatar(pendingCharacterId);
        vm.initialize(pendingCharacterId).then((): Promise<void> => vm.selectSession(pendingChatId))
          .catch((): void => {});
      } else {
        vm.initialize().then((): Promise<void> => vm.selectSession(pendingChatId))
          .catch((): void => {});
      }
    } else if (pendingCharacterId.length > 0) {
      AppStorage.set<string>('pendingCharacterId', '');
      this.loadCharacterAvatar(pendingCharacterId);
      // 角色卡"新建对话"入口:forceNew=true 跳过 openLatestSession,直接创建新会话
      vm.initialize(pendingCharacterId, true).catch((): void => {});
    } else {
      vm.initialize();
      // 从当前角色加载头像
      this.loadCurrentCharacterAvatar();
    }
    this.registerKeyboardListener();
    this.registerDarkModeListener();
    this.loadPersistedBubbleOpacity();
    // Phase 4A-2: 注册到 AvatarChatBridge, 使本页面发布的最终助手消息
    // 可被 VrmViewerPage (Avatar endpoint) 消费演出。
    // - endpointId 必须本页面实例内稳定,跨实例唯一
    // - 注册失败不阻塞页面初始化 (Bridge best-effort)
    try {
      ChatPage.chatEndpointCounter++;
      this.chatEndpointId = `chat-page-${ChatPage.chatEndpointCounter}`;
      ArkWebAvatarChatBridge.getInstance().registerChatEndpoint(this.chatEndpointId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'registerChatEndpoint failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }

    // Phase 4B-1: Avatar Stage 控制器由 ChatAvatarStage 组件内部创建
    // ChatPage 通过 onControllerReady 回调获取控制器引用, 用于:
    //   - AI 面板调用 publishPerformanceFromPanel / cancelPerformance / getCapabilitySnapshot
    //   - 监听状态变化 (onStateChanged / onModelNameChanged)
    // 控制器生命周期由 ChatAvatarStage 组件管理 (aboutToAppear 创建 / aboutToDisappear 销毁)
  }

  /**
   * 从 Preferences 读取持久化的气泡不透明度。
   * 读取失败或未初始化时静默使用默认值 0.65。
   */
  private loadPersistedBubbleOpacity(): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.getString(ChatPage.PREF_KEY_BUBBLE_OPACITY, '0.65')
        .then((value: string): void => {
          const parsed: number = parseFloat(value);
          if (Number.isFinite(parsed)) {
            this.chatBubbleOpacity = this.normalizeChatBubbleOpacity(parsed);
          }
        })
        .catch((_e: Object): void => {
          // 读取失败静默使用默认值
        });
    } catch (_e) {
      // AppServices 未初始化时静默使用默认值
    }
  }

  /**
   * 将气泡不透明度持久化到 Preferences。
   * 写入失败静默忽略(不影响 UI 交互)。
   */
  private persistBubbleOpacity(value: number): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.putString(ChatPage.PREF_KEY_BUBBLE_OPACITY, value.toString())
        .catch((_e: Object): void => {
          // 写入失败静默忽略
        });
    } catch (_e) {
      // AppServices 未初始化时静默忽略
    }
  }

  /**
   * 注册深色模式监听器,实时更新 isDarkMode 状态。
   * 用于动态计算气泡背景 RGB(light/dark 资源值不同)。
   */
  private registerDarkModeListener(): void {
    try {
      const listener = mediaquery.matchMediaSync('(dark-mode: true)');
      this.isDarkMode = listener.matches;
      listener.on('change', (result: mediaquery.MediaQueryResult): void => {
        this.isDarkMode = result.matches;
      });
      this.darkModeListener = listener;
    } catch (_e) {
      // mediaquery 不可用时默认浅色模式
      this.isDarkMode = false;
    }
  }

  aboutToDisappear(): void {
    this.unregisterKeyboardListener();
    // Phase 4A-2: 注销 AvatarChatBridge chat endpoint
    // - 不 dispose Bridge (Bridge 为应用级单例,仅应用退出时 dispose)
    // - 注销失败不阻塞页面销毁
    if (this.chatEndpointId.length > 0) {
      try {
        ArkWebAvatarChatBridge.getInstance().unregisterChatEndpoint(this.chatEndpointId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'unregisterChatEndpoint failed: ' +
          (e instanceof Error ? e.message : String(e)));
      }
      this.chatEndpointId = '';
    }
    // Phase 4B-1: Avatar Stage 控制器由 ChatAvatarStage 组件销毁
    // 这里仅清除引用, 不调用 dispose (避免重复销毁)
    this.avatarStageController = null;
    this.aiCapabilitySnapshot = null;
    this.aiPanelVisible = false;
    // 注销深色模式监听器
    if (this.darkModeListener !== null) {
      try {
        this.darkModeListener.off('change');
      } catch (_e) {
        // 忽略注销失败
      }
      this.darkModeListener = null;
    }
    // 关闭显示设置面板
    this.chatAppearancePanelVisible = false;
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
      this.viewModel = null;
    }
    this.messages = [];
    this.messageStates = [];
    this.stateMap.clear();
    this.dataSource.clear();
    const v: number = AppStorage.get<number>('chatListVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatListVersion', v + 1);
  }

  // ===== Phase 4B-1: AI 面板辅助方法 =====

  /**
   * 刷新 AI 能力快照 (供 AI 面板展示动作/姿势/表情列表)。
   *
   * 触发时机:
   *   - 模型 READY (onStateChanged 回调)
   *   - AI 面板打开
   *   - 用户手动刷新 (未来)
   */
  private refreshAiCapabilitySnapshot(): void {
    if (this.avatarStageController === null) {
      this.aiCapabilitySnapshot = null;
      return;
    }
    const controller: ArkWebChatAvatarStageController = this.avatarStageController!;
    controller.getCapabilitySnapshot().then((snapshot: ArkWebAvatarAiCapabilitySnapshot | null) => {
      this.aiCapabilitySnapshot = snapshot;
      // Phase 4A-3: 同步刷新 Avatar Tool Calling 状态 (权限/工具数/能力就绪)
      this.refreshAvatarToolCallingStatus();
    }).catch((e: Object) => {
      Logger.warn(LOG_TAG, 'refreshAiCapabilitySnapshot failed: ' +
        (e instanceof Error ? e.message : String(e)));
      this.aiCapabilitySnapshot = null;
    });
  }

  /**
   * Phase 4A-3: 刷新 Avatar Tool Calling 状态 (供 AI 面板权限区显示)。
   *
   * 触发时机:
   *   - AI 面板打开
   *   - 能力快照刷新后
   *   - 权限模式变更后
   *   - 工具调用完成后
   */
  private refreshAvatarToolCallingStatus(): void {
    if (this.viewModel === null) {
      this.avatarToolStatus = null;
      this.avatarStrategyStatus = null;
      return;
    }
    try {
      const status: AvatarToolCallingStatus =
        this.viewModel!.getAvatarToolCallingStatus();
      this.avatarToolStatus = status;
      this.avatarToolPermissionMode = status.permissionMode;
      // Phase 4C-1: 同步刷新策略状态摘要
      this.avatarStrategyStatus = this.viewModel!.getAvatarDialogueStrategyStatus();
    } catch (e) {
      Logger.warn(LOG_TAG, 'refreshAvatarToolCallingStatus failed: ' +
        (e instanceof Error ? e.message : String(e)));
      this.avatarToolStatus = null;
      this.avatarStrategyStatus = null;
    }
  }

  /**
   * Phase 4A-3: 设置 Avatar Tool Calling 权限模式 (UI 调用)。
   *
   * - DENY: 不注入任何 Avatar 工具
   * - READ_ONLY: 只注入 avatar_list_capabilities + avatar_get_state
   * - CONTROL_THIS_CHAT: 注入全部四个工具
   */
  private setAvatarToolPermission(mode: string): void {
    if (this.viewModel === null) {
      return;
    }
    try {
      this.viewModel!.setAvatarPermissionMode(mode);
      this.avatarToolPermissionMode = mode;
      // 刷新状态以反映工具数量变化
      this.refreshAvatarToolCallingStatus();
    } catch (e) {
      Logger.warn(LOG_TAG, 'setAvatarToolPermission failed: ' +
        (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * Phase 4B-2R §第十一项: 验证 Avatar endpoint 已注册且属于本 Stage。
   *
   * ChatPage 打开 AI 面板时调用, 确保请求不会被已离开的 VrmViewerPage endpoint 消费。
   * 失败时记录警告日志 (不阻塞面板使用, 仅作诊断)。
   */
  private verifyAvatarEndpoint(): void {
    if (this.avatarStageController === null) {
      Logger.warn(LOG_TAG, 'verifyAvatarEndpoint: controller null');
      return;
    }
    const result: [boolean, string, string] =
      this.avatarStageController!.verifyEndpointReady();
    if (!result[0]) {
      Logger.warn(LOG_TAG,
        `verifyAvatarEndpoint FAILED: code=${result[1]} msg=${result[2]}`);
    } else {
      Logger.info(LOG_TAG, 'verifyAvatarEndpoint OK');
    }
  }

  /**
   * 触发动画演出 (source = CHAT_AI_PANEL)。
   *
   * 构建 performanceHintJson:
   *   { "motionType": "animation", "motionId": "<actionId>", "durationMs": 5000,
   *     "returnPolicy": "DEFAULT_POSE" }
   *
   * Phase 4B-2R2: 不再将 Bridge 接受视为 PLAYING, 等待真实 Lifecycle 执行结果。
   * 状态流转: REQUESTING → LOADING → READY → PLAYING / FAILED
   */
  private triggerAnimation(actionId: string): void {
    this.aiPanelActiveCapabilityId = actionId;
    this.aiPanelButtonStatus = 'REQUESTING';
    this.aiPanelLastErrorCode = '';
    const hintJson: string = JSON.stringify({
      version: 1,
      motionType: 'animation',
      motionId: actionId,
      expressionId: '',
      expressionWeight: 0,
      durationMs: 5000,
      returnPolicy: 'DEFAULT_POSE'
    });
    this.publishPanelPerformanceAndWait(hintJson).then((result: ArkWebPanelPerformanceResult) => {
      if (result.executed && result.animationState === 'PLAYING') {
        this.aiPanelButtonStatus = 'PLAYING';
      } else if (result.executed && result.animationState === 'READY') {
        // Lifecycle 执行成功但动画状态仍为 READY (可能已开始播放但状态刷新延迟)
        this.aiPanelButtonStatus = 'PLAYING';
      } else if (result.executed && result.animationState === 'LOADING') {
        // Lifecycle 执行成功但动画仍在加载 ( READY 等待超时前)
        this.aiPanelButtonStatus = 'LOADING';
      } else {
        this.aiPanelButtonStatus = 'FAILED';
        this.aiPanelLastErrorCode = result.errorCode || result.animationState || 'UNKNOWN';
      }
    }).catch((e: Object) => {
      this.aiPanelButtonStatus = 'FAILED';
      this.aiPanelLastErrorCode = e instanceof Error ? e.message : String(e);
      Logger.warn(LOG_TAG, 'triggerAnimation failed: ' + this.aiPanelLastErrorCode);
    });
  }

  /**
   * 触发姿势演出 (source = CHAT_AI_PANEL)。
   *
   * 构建 performanceHintJson:
   *   { "motionType": "pose", "motionId": "<poseId>", "durationMs": 5000,
   *     "returnPolicy": "DEFAULT_POSE" }
   *
   * Phase 4B-2R2: 不再将 Bridge 接受视为 APPLIED, 等待真实 Lifecycle 执行结果。
   * 状态流转: REQUESTING → APPLIED / FAILED
   */
  private triggerPose(poseId: string): void {
    this.aiPanelActiveCapabilityId = poseId;
    this.aiPanelButtonStatus = 'REQUESTING';
    this.aiPanelLastErrorCode = '';
    const hintJson: string = JSON.stringify({
      version: 1,
      motionType: 'pose',
      motionId: poseId,
      expressionId: '',
      expressionWeight: 0,
      durationMs: 5000,
      returnPolicy: 'DEFAULT_POSE'
    });
    this.publishPanelPerformanceAndWait(hintJson).then((result: ArkWebPanelPerformanceResult) => {
      if (result.executed) {
        this.aiPanelButtonStatus = 'APPLIED';
      } else {
        this.aiPanelButtonStatus = 'FAILED';
        this.aiPanelLastErrorCode = result.errorCode || result.poseState || 'UNKNOWN';
      }
    }).catch((e: Object) => {
      this.aiPanelButtonStatus = 'FAILED';
      this.aiPanelLastErrorCode = e instanceof Error ? e.message : String(e);
      Logger.warn(LOG_TAG, 'triggerPose failed: ' + this.aiPanelLastErrorCode);
    });
  }

  /**
   * 触发表情演出 (source = CHAT_AI_PANEL)。
   *
   * 构建 performanceHintJson:
   *   { "motionType": "none", "motionId": "", "expressionId": "<expressionId>",
   *     "expressionWeight": 1.0, "durationMs": 3000, "returnPolicy": "KEEP" }
   *
   * Phase 4B-2R2: 不再将 Bridge 接受视为 APPLIED, 等待真实 Lifecycle 执行结果。
   * 状态流转: REQUESTING → APPLIED / FAILED
   */
  private triggerExpression(expressionId: string): void {
    this.aiPanelActiveCapabilityId = expressionId;
    this.aiPanelButtonStatus = 'REQUESTING';
    this.aiPanelLastErrorCode = '';
    // 预检: 表情别名是否已映射 (避免静默失败)
    if (this.avatarStageController !== null) {
      const aliasMap: Record<string, string> = this.avatarStageController!.getExpressionAliasMap();
      const actualName: string = aliasMap[expressionId] ?? '';
      if (actualName.length === 0) {
        this.aiPanelButtonStatus = 'FAILED';
        this.aiPanelLastErrorCode = 'EXPRESSION_ALIAS_NOT_RESOLVED';
        Logger.warn(LOG_TAG, `triggerExpression: alias not resolved: ${expressionId}`);
        return;
      }
    }
    const hintJson: string = JSON.stringify({
      version: 1,
      motionType: 'none',
      motionId: '',
      expressionId: expressionId,
      expressionWeight: 1.0,
      durationMs: 3000,
      returnPolicy: 'KEEP'
    });
    this.publishPanelPerformanceAndWait(hintJson).then((result: ArkWebPanelPerformanceResult) => {
      if (result.executed) {
        this.aiPanelButtonStatus = 'APPLIED';
      } else {
        this.aiPanelButtonStatus = 'FAILED';
        this.aiPanelLastErrorCode = result.errorCode || result.expressionState || 'UNKNOWN';
      }
    }).catch((e: Object) => {
      this.aiPanelButtonStatus = 'FAILED';
      this.aiPanelLastErrorCode = e instanceof Error ? e.message : String(e);
      Logger.warn(LOG_TAG, 'triggerExpression failed: ' + this.aiPanelLastErrorCode);
    });
  }

  /**
   * Phase 4B-2R: 从 Stage Snapshot 提取最近错误码 (供按钮反馈显示)。
   */
  private resolvePanelErrorCode(): string {
    if (this.avatarStageSnapshot === null) {
      return 'UNKNOWN';
    }
    if (this.avatarStageSnapshot!.lastPublishErrorCode.length > 0) {
      return this.avatarStageSnapshot!.lastPublishErrorCode;
    }
    if (this.avatarStageSnapshot!.lastErrorCode.length > 0) {
      return this.avatarStageSnapshot!.lastErrorCode;
    }
    return 'UNKNOWN';
  }

  /**
   * 停止当前演出 (调用 LifecycleController.cancelCurrent)。
   */
  private stopAvatarPerformance(): void {
    if (this.avatarStageController === null) {
      return;
    }
    this.avatarStageController!.cancelPerformance().catch((e: Object) => {
      Logger.warn(LOG_TAG, 'stopAvatarPerformance failed: ' +
        (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * 通过 AvatarChatBridge 发布演出消息 (source = CHAT_AI_PANEL)。
   *
   * 流程:
   *   1. controller.publishPerformanceFromPanel(hintJson)
   *   2. Bridge 投递回当前 Avatar endpoint (本页面的 Stage 控制器)
   *   3. Stage 控制器经 LifecycleController → PerformanceController 执行演出
   *
   * Phase 4B-2R: 返回 Promise<boolean>, 调用方据此显示成功/失败状态。
   * 错误隔离: 演出失败不影响聊天文本显示, 仅记录日志。
   */
  private publishPanelPerformance(hintJson: string): Promise<boolean> {
    if (this.avatarStageController === null) {
      Logger.warn(LOG_TAG, 'publishPanelPerformance: avatarStageController null');
      return Promise.resolve(false);
    }
    return this.avatarStageController!.publishPerformanceFromPanel(hintJson).catch((e: Object): boolean => {
      Logger.warn(LOG_TAG, 'publishPanelPerformance failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    });
  }

  /**
   * Phase 4B-2R2: 通过 AvatarChatBridge 发布演出消息并等待真实执行结果。
   *
   * 不再将 Bridge 接受视为播放成功, 等待真实 Lifecycle 执行结果。
   * 返回详细结果 (accepted/executed/runtime states/error)。
   *
   * 错误隔离: 演出失败不影响聊天文本显示, 仅记录日志。
   */
  private publishPanelPerformanceAndWait(hintJson: string): Promise<ArkWebPanelPerformanceResult> {
    if (this.avatarStageController === null) {
      Logger.warn(LOG_TAG, 'publishPanelPerformanceAndWait: avatarStageController null');
      const errResult: ArkWebPanelPerformanceResult = {
        accepted: false,
        executed: false,
        turnId: '',
        commandId: '',
        lifecycleState: 'IDLE',
        animationState: 'IDLE',
        poseState: 'IDLE',
        expressionState: 'IDLE',
        errorCode: 'AVATAR_STAGE_NULL',
        errorMessage: 'avatarStageController null'
      };
      return Promise.resolve(errResult);
    }
    return this.avatarStageController!.publishPerformanceFromPanelAndWait(hintJson).catch((e: Object): ArkWebPanelPerformanceResult => {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.warn(LOG_TAG, 'publishPanelPerformanceAndWait failed: ' + msg);
      const errResult: ArkWebPanelPerformanceResult = {
        accepted: false,
        executed: false,
        turnId: '',
        commandId: '',
        lifecycleState: 'IDLE',
        animationState: 'IDLE',
        poseState: 'IDLE',
        expressionState: 'IDLE',
        errorCode: 'PUBLISH_AND_WAIT_THREW',
        errorMessage: msg
      };
      return errResult;
    });
  }

  onPageShow(): void {
    // 处理从二级页面返回后的回调(替代原 pushPathByName 的 onPop 回调)
    if (this.pendingRefreshPresetName) {
      this.pendingRefreshPresetName = false;
      if (this.viewModel !== null && !this.viewModel!.isDisposed) {
        this.viewModel!.refreshCurrentPresetName();
      }
    }
    if (this.pendingReloadAfterBranchChange) {
      this.pendingReloadAfterBranchChange = false;
      if (this.viewModel !== null && !this.viewModel!.isDisposed) {
        this.viewModel!.reloadAfterBranchChange().catch((): void => {});
      }
    }
    // 从二级页面返回时刷新上下文占用统计
    this.refreshBudgetSnapshot();
  }

  onBackPress(): boolean {
    if (this.showActionSheet) {
      this.showActionSheet = false;
      this.actionSheetMsg = null;
      return true;
    }
    if (this.showMoreMenu) {
      this.showMoreMenu = false;
      return true;
    }
    if (this.showClearConfirm) {
      this.showClearConfirm = false;
      return true;
    }
    if (this.viewModel !== null) {
      if (this.viewModel!.showDeleteSessionConfirm) {
        this.viewModel!.cancelDeleteSession();
        return true;
      }
      if (this.viewModel!.showSessionList) {
        this.viewModel!.closeSessionList();
        return true;
      }
    }
    return false;
  }

  build() {
    Stack() {
        // ===== 背景层(最底层,位于消息列表之下)=====
        // 仅在配置已加载、启用、且图片存在时渲染。否则透出根 Stack 的 page_background。
        if (this.chatBgConfig !== null
          && this.chatBgConfig!.enabled
          && this.chatBgConfig!.imageUri.length > 0) {
          // 背景图(应用模糊度,模糊后图像边缘有透明像素,由 page_background 兜底)
          Image(this.chatBgConfig!.imageUri)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.chatBgConfig!.blur)
            .hitTestBehavior(HitTestMode.Transparent)

          // 暗化遮罩(增强浅色背景图下的文字可读性)
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,' + (this.chatBgConfig!.dim / 100).toString() + ')')
            .hitTestBehavior(HitTestMode.Transparent)
        }

        // ===== Phase 4B-1: Avatar Stage 层 (透明 VRM 模型, 位于背景之上、消息列表之下) =====
        // - 保留用户当前背景图片, 不修改背景透明度
        // - 透明效果由 Web 端 CHAT_STAGE profile 实现 (renderer alpha=true, scene.background=null)
        // - 不响应触摸 (hitTestBehavior=Transparent), 让触摸穿透到下层消息列表
        // - visible=false 时隐藏 Stage 但不销毁模型 (visibility=Hidden 保留布局)
        // - 控制器由组件内部创建, 通过 onControllerReady 回调暴露给 ChatPage
        ChatAvatarStage({
          visible: this.chatAvatarVisible,
          onControllerReady: (controller: ArkWebChatAvatarStageController): void => {
            this.avatarStageController = controller;
            // 设置事件监听器, 接收状态变化和模型名变化
            const self: ChatPage = this;
            const listener: ChatAvatarStageListenerImpl = new ChatAvatarStageListenerImpl();
            listener.onStateChangedFn = (state: ArkWebChatAvatarStageState, _detail: string): void => {
              self.avatarStageState = state;
              self.avatarStageSnapshot = controller.getRuntimeSnapshot();
              self.avatarShotSnapshot = controller.getShotRuntimeSnapshot();
              // 模型就绪后刷新能力快照
              if (state === 'MODEL_READY') {
                self.refreshAiCapabilitySnapshot();
              }
            };
            listener.onModelNameChangedFn = (displayName: string): void => {
              self.avatarModelDisplayName = displayName;
              self.avatarStageSnapshot = controller.getRuntimeSnapshot();
            };
            controller.setEventListener(listener);
            // 初始快照
            this.avatarStageSnapshot = controller.getRuntimeSnapshot();
          }
        })

        // ===== 底层:消息列表 + 浮动按钮 =====
        Column() {
          // 消息列表 + 浮动按钮
          Stack({ alignContent: Alignment.BottomEnd }) {
            if (this.isInitialLoading()) {
              this.loadingView()
            } else if (this.hasInitError()) {
              this.initErrorView()
            } else if (this.messages.length === 0) {
              this.emptyStateView()
            } else {
              this.messageList()
            }

            // 回到底部浮动按钮
            if (this.viewModel !== null
              && this.viewModel!.userScrolledUp
              && this.messages.length > 0) {
              Button({ type: ButtonType.Circle, stateEffect: false }) {
                SymbolGlyph($r('sys.symbol.chevron_down'))
                  .fontSize(20)
                  .fontColor([$r('app.color.app_text_primary')])
              }
              .backgroundColor($r('app.color.app_surface_1'))
              .borderRadius(22)
              .width(44)
              .height(44)
              .margin({ bottom: 12, right: 12 })
              .shadow({ radius: 8, color: 'rgba(0,0,0,0.15)' })
              .onClick(() => {
                this.scroller.scrollEdge(Edge.Bottom);
                this.viewModel!.userScrolledUp = false;
              })
            }
          }
          .layoutWeight(1)
          .width('100%')
          // padding 0:消息列表占满全屏,顶栏/输入栏作为浮层叠加(顶栏透明、输入栏底部带不透明背景)。
          // 最新消息通过 autoScrollToBottom 滚动到输入栏上方可视区域。
          .padding({ top: 0, bottom: 0 })
          .onClick(() => {
            // 点击消息列表空白区域收起软键盘
            try {
              inputMethod.getController().stopInputSession();
            } catch (_e) {
              // 输入法未显示或已隐藏,忽略
            }
          })
        }
        .width('100%')
        .height('100%')

        // ===== 顶部渐变层(增强状态栏图标和顶部文字可读性) =====
        // 不响应触摸:hitTestBehavior(Transparent)
        // 不改变背景图片透明度:仅本层自身带渐变背景
        // 仅覆盖状态栏和顶部过渡区域(高度 = 状态栏高度 + 渐变过渡区 112vp)
        Column() {
          Column()
            .width('100%')
            .height(this.statusBarHeight + 112)
            .linearGradient({
              angle: 180,
              colors: [
                [$r('app.color.chat_top_gradient_start'), 0.0],
                [$r('app.color.chat_top_gradient_mid'), 0.5],
                [$r('app.color.chat_top_gradient_end'), 1.0]
              ]
            })
            .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)

        // ===== 浮层:顶栏(顶部对齐,半透明背景) =====
        // 注意:Stack 默认 alignContent=Center,若 Column 只设 width 不设 height,
        // 会被居中显示(顶栏/输入栏"集中在中间"的根因)。
        // 解法:Column 占满 height + justifyContent(Start/End) 让内容在顶部/底部对齐,
        // 同时 hitTestBehavior=Transparent 让空白区域点击穿透到下层消息列表。
        Column() {
          this.topBar()

          // 显示设置面板(气泡不透明度)
          this.chatAppearancePanel()

          // 错误提示条
          if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
            Text(this.viewModel!.errorMessage)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .width('100%')
              .padding({
                left: $r('app.float.app_spacing_16'),
                right: $r('app.float.app_spacing_16'),
                top: $r('app.float.app_spacing_4'),
                bottom: $r('app.float.app_spacing_4')
              })
              .backgroundColor($r('app.color.app_surface_2'))
          }

          // 状态条(生成中/已停止 - 轻量提示)
          if (this.viewModel !== null && this.viewModel!.statusMessage.length > 0) {
            Text(this.viewModel!.statusMessage)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 2, bottom: 2 })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        // 顶栏 Column 透明:让下层消息列表完全可见,顶栏背景由 topBar Row 自己带
        // hitTestBehavior=Transparent 让顶栏下方空白区域点击穿透到消息列表
        .hitTestBehavior(HitTestMode.Transparent)

        // ===== 浮层:输入栏(底部对齐,悬浮胶囊式) =====
        // 外层 Column 透明,只负责把 inputArea 推到底部对齐位置;
        // 输入栏本身由 inputArea 的 backgroundBlurStyle 提供视觉容器,不承载不透明背景。
        // margin bottom 12vp + navigationBarHeight:避开系统手势条;
        // margin left/right 12vp:与页面其他内容对齐。
        Column() {
          // v8.1: 紧凑上下文占用指示器(输入栏上方,点击打开上下文管理)
          this.budgetIndicator()
          this.inputArea()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ left: 12, right: 12, bottom: this.navigationBarHeight + 12 })
        .hitTestBehavior(HitTestMode.Transparent)

        // ===== Phase 4B-1: AI 控制面板浮层 (紧凑半透明, 右侧对齐) =====
        // Phase 4B-2R: 移到输入栏之后渲染, z-order 高于输入栏,
        // 确保面板 hitTestBehavior(Block) 不被输入栏 Transparent 层阻挡。
        // - 不使用全屏 Dialog 和遮罩
        // - 顶部显示模型显示开关
        // - 分组显示动作/姿势/表情能力列表
        // - 点击能力时构建 performanceHint 并通过 AvatarChatBridge 发布 (source=CHAT_AI_PANEL)
        if (this.aiPanelVisible) {
          this.aiControlPanel()
        }

        // ===== 弹窗层(覆盖在最上层) =====
        // 会话列表面板(覆盖层)
        if (this.viewModel !== null && this.viewModel!.showSessionList) {
          ChatSessionListPanel({ viewModel: this.viewModel! })
        }

        // 更多菜单
        if (this.showMoreMenu && this.viewModel !== null) {
          ChatMoreMenuSheet({
            visible: true,
            characterName: this.viewModel!.characterName,
            modelName: this.viewModel!.currentModelName,
            presetName: this.viewModel!.currentPresetName,
            hasModel: this.viewModel!.hasCurrentModel,
            branchStatusText: this.viewModel!.getBranchStatusText(),
            canRegenerate: this.viewModel!.canRegenerate,
            isGenerating: this.viewModel!.isGenerating,
            busy: this.viewModel!.busy,
            userNameOverride: this.currentUserNameOverride,
            resolvedUserName: this.resolvedUserName,
            onClose: (): void => {
              this.showMoreMenu = false;
              // 关闭菜单时刷新一次当前生效称呼(可能在其他地方被修改)
              this.refreshUserNameDisplay();
            },
            onGoModelSettings: (): void => { this.goToModelSettings(); },
            onGoPresetList: (): void => { this.goToPresetList(); },
            onGoBranchMap: (): void => { this.navigateToBranchMap(); },
            onOpenSessionList: (): void => {
              this.viewModel!.openSessionList();
            },
            onGoChatBackground: (): void => { this.navigateToChatBackgroundSettings(); },
            onGoMemory: (): void => { this.navigateToMemoryManagement(); },
            onGoContextBudget: (): void => { this.navigateToContextBudget(); },
            onEditUserNameOverride: (): void => {
              this.openUserNameOverrideDialog();
            },
            onRegenerate: (): void => { this.viewModel!.regenerate(); },
            onClearChat: (): void => {
              this.showClearConfirm = true;
            }
          })
        }

        // 消息操作菜单
        if (this.showActionSheet && this.actionSheetMsg !== null && this.viewModel !== null) {
          ChatMessageActionSheet({
            visible: true,
            msg: this.actionSheetMsg,
            canEdit: this.viewModel!.canEditUserMessage(this.actionSheetMsg!.id),
            canGenerateFromUser: this.viewModel!.canGenerateFromUserMessage(this.actionSheetMsg!.id),
            canRegenerate: this.viewModel!.canRegenerateAssistantMessage(this.actionSheetMsg!.id),
            canContinue: this.viewModel!.canContinueFromAssistant(this.actionSheetMsg!.id),
            candidateCount: this.getCandidateCount(this.actionSheetMsg!.id),
            canForkChat: !this.viewModel!.busy && this.viewModel!.isSessionReady,
            onClose: (): void => {
              this.showActionSheet = false;
              this.actionSheetMsg = null;
            },
            onAction: (action: MessageAction): void => {
              this.handleMessageAction(action);
            }
          })
        }

        // 清空确认弹窗
        if (this.showClearConfirm) {
          this.clearConfirmDialog()
        }

        // v9: 本对话称呼覆盖编辑弹窗
        if (this.showUserNameOverrideDialog) {
          this.userNameOverrideDialog()
        }

        // Fork 模式选择弹窗
        if (this.showForkModePicker) {
          this.forkModePickerDialog()
        }
      }
      .width('100%')
      .height('100%')
      // PanoVR2 模式:不透明背景填满到状态栏区域
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ===== 顶部栏 =====

  @Builder
  topBar() {
    Row() {
      // 返回按钮(纯图标,无背景无边框,用 Stack 居中图标)
      Stack() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .width(40)
      .height(40)
      .onClick(() => {
        this.handleBack();
      })

      // 汉堡按钮(打开会话列表,仅 viewModel 就绪时显示)
      if (this.viewModel !== null) {
        Stack() {
          SymbolGlyph($r('sys.symbol.line_3_horizontal'))
            .fontSize(22)
            .fontColor([$r('app.color.app_text_primary')])
        }
        .width(40)
        .height(40)
        .margin({ left: 4 })
        .onClick(() => {
          this.viewModel!.openSessionList();
        })
      }

      // 占位:让汉堡按钮和更多按钮分布在两侧(已按用户要求移除头像和角色名)
      Blank()

      // 显示按钮(打开气泡不透明度设置卡片)
      Stack() {
        SymbolGlyph($r('sys.symbol.textformat'))
          .fontSize(20)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .width(40)
      .height(40)
      .margin({ right: 4 })
      .borderRadius($r('app.float.app_radius_sm'))
      .backgroundColor(this.chatAppearancePanelVisible
        ? $r('app.color.app_surface_2') : Color.Transparent)
      .onClick(() => {
        this.chatAppearancePanelVisible = !this.chatAppearancePanelVisible;
      })

      // Phase 4B-1: AI 按钮 (打开/关闭 AI 控制面板)
      // - 不直接隐藏聊天内容, 仅切换 AI 面板可见性
      // - 面板为紧凑半透明浮层, 位于右上角按钮下方
      Stack() {
        Text('AI')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_text_primary'))
      }
      .width(40)
      .height(40)
      .margin({ right: 4 })
      .borderRadius($r('app.float.app_radius_sm'))
      .backgroundColor(this.aiPanelVisible
        ? $r('app.color.app_surface_2') : Color.Transparent)
      .onClick(() => {
        this.aiPanelVisible = !this.aiPanelVisible;
        // 打开面板时刷新能力快照 + 验证 endpoint + 刷新 Avatar Tool 状态
        if (this.aiPanelVisible) {
          this.refreshAiCapabilitySnapshot();
          this.verifyAvatarEndpoint();
          this.refreshAvatarToolCallingStatus();
        }
      })

      // 更多按钮(纯图标,无背景无边框)
      Stack() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(22)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .width(40)
      .height(40)
      .onClick(() => {
        // 打开菜单前刷新一次当前生效称呼(可能角色或全局设置已变化)
        this.refreshUserNameDisplay();
        this.showMoreMenu = true;
      })
    }
    .width('100%')
    // 顶部 padding = 状态栏高度 + 原始间距 4(避开状态栏,按钮不被遮挡)
    .padding({ left: 4, right: 4, top: this.statusBarHeight + 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    // 背景层分离:顶栏不设 backgroundColor,透出 Index 根背景,避免形成与状态栏区域的色差。
  }

  // ===== Phase 4B-1: AI 控制面板 (紧凑半透明浮层) =====

  @Builder
  aiControlPanel() {
    // 面板容器:靠右,不覆盖整屏,半透明背景,无全屏遮罩
    // 面板结构 = 可滚动主区域 (状态区 + 能力列表) + 固定底部停止按钮
    Column() {
      // ===== 可滚动主区域 (标题 + 诊断 + 镜头按钮 + 模型大小滑动条 + 能力列表) =====
      Scroll() {
        Column() {
          // 标题行:模型名 + 模型显示开关 + 关闭按钮
          Row() {
            Text(this.avatarModelDisplayName.length > 0
              ? this.avatarModelDisplayName : '未加载模型')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_primary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            // 模型显示开关 (Toggle)
            Toggle({ type: ToggleType.Switch, isOn: this.chatAvatarVisible })
              .selectedColor($r('app.color.app_accent'))
              .scale({ x: 0.8, y: 0.8 })
              .onChange((isOn: boolean) => {
                this.chatAvatarVisible = isOn;
              })

            // 关闭按钮
            Stack() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([$r('app.color.app_text_secondary')])
            }
            .width(28)
            .height(28)
            .margin({ left: 4 })
            .onClick(() => {
              this.aiPanelVisible = false;
            })
          }
          .width('100%')
          .margin({ bottom: 8 })

          // ===== Phase 4B-1R §第八项: 紧凑诊断信息 =====
          this.stageDiagnosticBlock()

          // Phase 4B-2R §第十二项: 运行时状态一致性 (来自 Runtime Debug State)
          this.runtimeStatusBlock()

          // Phase 4A-3: AI 模型权限区 (Avatar Tool Calling 权限控制)
          this.avatarToolPermissionBlock()

          // Phase 4C-1: Avatar 对话演出策略状态区
          this.avatarDialogueStrategyBlock()

          // 重新加载模型按钮 (Phase 4B-1R §第八项)
          Button('重新加载模型')
            .type(ButtonType.Normal)
            .borderRadius($r('app.float.app_radius_sm'))
            .backgroundColor('rgba(255,255,255,0.12)')
            .fontColor($r('app.color.app_text_primary'))
            .fontSize($r('app.float.app_font_caption'))
            .width('100%')
            .height(30)
            .margin({ top: 6, bottom: 4 })
            .onClick(() => {
              this.reloadAvatarModel();
            })

          // Phase 4B-2R2: 镜头控制模式按钮 (自动 / 全身 / 脸部)
          Row() {
            Button('自动镜头')
              .type(ButtonType.Normal)
              .borderRadius($r('app.float.app_radius_sm'))
              .backgroundColor(this.avatarShotControlMode === 'AUTO'
                ? $r('app.color.app_accent') : 'rgba(255,255,255,0.12)')
              .fontColor(this.avatarShotControlMode === 'AUTO'
                ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
              .fontSize($r('app.float.app_font_caption'))
              .height(28)
              .layoutWeight(1)
              .margin({ right: 4 })
              .onClick(() => {
                this.setShotControlMode('AUTO');
              })

            Button('全身')
              .type(ButtonType.Normal)
              .borderRadius($r('app.float.app_radius_sm'))
              .backgroundColor(this.avatarShotControlMode === 'MANUAL_FULL_BODY'
                ? $r('app.color.app_accent') : 'rgba(255,255,255,0.12)')
              .fontColor(this.avatarShotControlMode === 'MANUAL_FULL_BODY'
                ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
              .fontSize($r('app.float.app_font_caption'))
              .height(28)
              .layoutWeight(1)
              .margin({ left: 2, right: 2 })
              .onClick(() => {
                this.setShotControlMode('MANUAL_FULL_BODY');
                this.transitionToFullBody();
              })

            Button('脸部')
              .type(ButtonType.Normal)
              .borderRadius($r('app.float.app_radius_sm'))
              .backgroundColor(this.avatarShotControlMode === 'MANUAL_FACE_RESET_VIEW'
                ? $r('app.color.app_accent') : 'rgba(255,255,255,0.12)')
              .fontColor(this.avatarShotControlMode === 'MANUAL_FACE_RESET_VIEW'
                ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
              .fontSize($r('app.float.app_font_caption'))
              .height(28)
              .layoutWeight(1)
              .margin({ left: 4 })
              .onClick(() => {
                this.setShotControlMode('MANUAL_FACE_RESET_VIEW');
                this.transitionToFaceResetView();
              })
          }
          .width('100%')
          .margin({ bottom: 8 })

          // ===== Phase 4B-2R2: 模型大小滑动条 (fillRatio, 调整基础构图占比) =====
          Row() {
            Text('模型大小')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width(56)
            Slider({ value: this.avatarModelFillRatio, min: 0.3, max: 0.98, step: 0.01 })
              .layoutWeight(1)
              .selectedColor($r('app.color.app_accent'))
              .trackColor('rgba(255,255,255,0.15)')
              .blockColor($r('app.color.app_accent'))
              .onChange((value: number, mode: SliderChangeMode) => {
                this.avatarModelFillRatio = value;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.adjustAvatarModelSize(value);
                }
              })
          }
          .width('100%')
          .margin({ bottom: 8 })

          // ===== Phase 4B-2R2: 相机缩放倍率滑动条 (0.5×~3.0×) =====
          Row() {
            Text('缩放')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width(56)
            Slider({ value: this.avatarCameraZoomMultiplier, min: 0.5, max: 3.0, step: 0.1 })
              .layoutWeight(1)
              .selectedColor($r('app.color.app_accent'))
              .trackColor('rgba(255,255,255,0.15)')
              .blockColor($r('app.color.app_accent'))
              .onChange((value: number, mode: SliderChangeMode) => {
                this.avatarCameraZoomMultiplier = value;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.adjustCameraZoomMultiplier(value);
                }
              })
            Text(this.formatZoomMultiplier(this.avatarCameraZoomMultiplier))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width(40)
              .textAlign(TextAlign.RIGHT)
          }
          .width('100%')
          .margin({ bottom: 8 })

          // ===== 能力列表 (动作 / 姿势 / 表情) =====
          // 无能力快照时提示
          if (this.aiCapabilitySnapshot === null) {
            Text('暂无可用能力 (需先在 VRM Viewer 导入模型/动作/姿势/表情)')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 16, bottom: 16 })
          } else {
            // 动作分组
            if (this.aiCapabilitySnapshot!.animations.length > 0) {
              Column() {
                Text('动作')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.app_text_secondary'))
                  .width('100%')
                  .margin({ top: 8, bottom: 4 })
                ForEach(this.aiCapabilitySnapshot!.animations,
                  (anim: ArkWebAvatarAiAnimationCapability) => {
                    this.aiCapabilityButton(
                      anim.displayName + (anim.isDefaultIdle ? ' (默认)' : ''),
                      () => this.triggerAnimation(anim.actionId)
                    )
                  },
                  (anim: ArkWebAvatarAiAnimationCapability) => anim.actionId
                )
              }
              .width('100%')
            }

            // 姿势分组
            if (this.aiCapabilitySnapshot!.poses.length > 0) {
              Column() {
                Text('姿势')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.app_text_secondary'))
                  .width('100%')
                  .margin({ top: 8, bottom: 4 })
                ForEach(this.aiCapabilitySnapshot!.poses,
                  (pose: ArkWebAvatarAiPoseCapability) => {
                    this.aiCapabilityButton(
                      pose.displayName + (pose.isDefaultPose ? ' (默认)' : ''),
                      () => this.triggerPose(pose.poseId)
                    )
                  },
                  (pose: ArkWebAvatarAiPoseCapability) => pose.poseId
                )
              }
              .width('100%')
            }

            // 表情分组
            if (this.aiCapabilitySnapshot!.expressions.length > 0) {
              Column() {
                Text('表情')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.app_text_secondary'))
                  .width('100%')
                  .margin({ top: 8, bottom: 4 })
                ForEach(this.aiCapabilitySnapshot!.expressions,
                  (exp: ArkWebAvatarAiExpressionCapability) => {
                    if (exp.available) {
                      this.aiCapabilityButton(
                        AI_CAPABILITY_EXPRESSION_DISPLAY_NAMES[exp.expressionId] ?? exp.expressionId,
                        () => this.triggerExpression(exp.expressionId)
                      )
                    }
                  },
                  (exp: ArkWebAvatarAiExpressionCapability) => exp.expressionId
                )
              }
              .width('100%')
            }
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12, bottom: 4 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)

      // ===== 固定底部停止按钮 (始终可见, 不被滚动隐藏) =====
      Column() {
        Button('停止演出')
          .type(ButtonType.Normal)
          .borderRadius($r('app.float.app_radius_sm'))
          .backgroundColor($r('app.color.app_danger'))
          .fontColor(Color.White)
          .fontSize($r('app.float.app_font_caption'))
          .width('100%')
          .height(32)
          .margin({ top: 4 })
          .onClick(() => {
            this.stopAvatarPerformance();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 12 })
    }
    .width('82%')
    .constraintSize({ maxWidth: 420 })
    .height('72%')
    .backgroundColor('rgba(30,30,30,0.85)')
    .borderRadius($r('app.float.app_radius_md'))
    .border({ width: 1, color: 'rgba(255,255,255,0.1)' })
    // Phase 4B-2R: 水平居中 (顶部导航下方, 底部不覆盖输入栏)
    .margin({ top: this.statusBarHeight + 52 })
    // Phase 4B-2R 修正: 不使用 HitTestMode.Block (会阻止子按钮接收触摸)。
    // zIndex 提升层级确保面板在消息列表之上;
    // 空 onClick 吸收面板空白区域的触摸, 阻止穿透到下层消息列表;
    // 不透明背景视觉上遮挡下层, 子按钮可正常响应。
    .zIndex(100)
    .onClick(() => {
      // 吸收面板空白区域的触摸, 阻止穿透到下层消息列表 (不执行任何操作)
    })
  }

  /** AI 能力按钮 (点击触发演出) */
  @Builder
  aiCapabilityButton(label: string, onClick: () => void) {
    Button(label)
      .type(ButtonType.Normal)
      .borderRadius($r('app.float.app_radius_sm'))
      .backgroundColor('rgba(255,255,255,0.08)')
      .fontColor($r('app.color.app_text_primary'))
      .fontSize($r('app.float.app_font_caption'))
      .width('100%')
      .height(32)
      .margin({ top: 4 })
      .onClick(() => {
        onClick();
      })
  }

  /**
   * Phase 4B-1R §第八项: Stage 紧凑诊断信息块。
   *
   * 显示:
   *   Stage：<state> / Viewer：<state> / 模型：<name|未加载>
   *   Profile：<profile> / 尺寸：<w>x<h>
   *   错误：<errorCode> (仅失败时显示)
   */
  @Builder
  stageDiagnosticBlock() {
    Column() {
      Text(`Stage: ${this.avatarStageState} | Viewer: ${this.stageViewerStateText()} | 模型: ${this.stageModelText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`Profile: ${this.stageProfileText()} | 尺寸: ${this.stageSizeText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // Phase 4B-2: 镜头状态行
      Text(`镜头: ${this.shotStateText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.stageErrorText().length > 0) {
        Text(`错误: ${this.stageErrorText()}`)
          .fontSize(11)
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .margin({ top: 2 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(8)
    .margin({ bottom: 4 })
    .borderRadius($r('app.float.app_radius_sm'))
    .backgroundColor('rgba(255,255,255,0.05)')
  }

  /**
   * Phase 4B-2R §第十二项: 运行时状态一致性显示块。
   *
   * 显示名称来自能力目录, 执行状态来自 Runtime Debug State。
   * 例如: 当前动作：Spin 状态：PLAYING
   */
  @Builder
  runtimeStatusBlock() {
    Column() {
      Text(`镜头模式: ${this.runtimeShotControlModeText()} | 镜头: ${this.runtimeShotText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`模型倍率: ${this.runtimeCameraZoomText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`动作: ${this.runtimeActionText()} | 状态: ${this.runtimeAnimationStateText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`动画加载: ${this.runtimeAnimationLoadText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`姿势: ${this.runtimePoseText()} | 状态: ${this.runtimePoseStateText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`表情: ${this.runtimeExpressionText()} | 状态: ${this.runtimeExpressionStateText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`Turn: ${this.runtimeLastTurnIdText()} | Lifecycle: ${this.runtimeLifecycleStateText()}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(`最后结果: ${this.runtimeLastResultText()}`)
        .fontSize(11)
        .fontColor(this.aiPanelLastErrorCode.length > 0
          ? $r('app.color.app_danger')
          : $r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(8)
    .margin({ bottom: 4 })
    .borderRadius($r('app.float.app_radius_sm'))
    .backgroundColor('rgba(255,255,255,0.05)')
  }

  /**
   * Phase 4A-3: AI 模型权限区块 (Avatar Tool Calling 权限控制)。
   *
   * 显示:
   *   - 当前 Provider 是否支持 Tool Calling
   *   - 注入工具数量
   *   - 当前模型能力是否就绪
   *   - 最后工具名称 / 结果 / 错误
   *   - 三档权限切换按钮 (不允许 / 只读 / 控制本次聊天)
   *
   * 权限为 DENY 时, AI 面板手动按钮仍可使用 (手动按钮属用户操作)。
   */
  @Builder
  avatarToolPermissionBlock() {
    Column() {
      Text('AI 模型权限')
        .fontSize($r('app.float.app_font_caption'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ bottom: 4 })

      // Provider 支持状态 + 工具数量 + 能力就绪
      Row() {
        Text(`Provider: ${this.avatarToolStatus !== null && this.avatarToolStatus!.providerSupported ? '支持' : '不支持'}`)
          .fontSize(11)
          .fontColor(this.avatarToolStatus !== null && this.avatarToolStatus!.providerSupported
            ? $r('app.color.app_text_secondary')
            : $r('app.color.app_danger'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(`工具: ${this.avatarToolStatus !== null ? this.avatarToolStatus!.toolCount : 0} 个`)
          .fontSize(11)
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      // 能力就绪 + 最后工具名/结果/错误
      Text(`能力: ${this.avatarToolStatus !== null && this.avatarToolStatus!.capabilityReady ? '就绪' : '未就绪'}${this.avatarToolStatus !== null && this.avatarToolStatus!.lastToolName.length > 0 ? ' | 最后工具: ' + this.avatarToolStatus!.lastToolName : ''}`)
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.avatarToolStatus !== null && this.avatarToolStatus!.lastToolError.length > 0) {
        Text(`错误: ${this.avatarToolStatus!.lastToolError}`)
          .fontSize(11)
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .margin({ top: 2 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // 权限切换按钮 (三档)
      Row() {
        Button('不允许')
          .type(ButtonType.Normal)
          .borderRadius($r('app.float.app_radius_sm'))
          .backgroundColor(this.avatarToolPermissionMode === 'DENY'
            ? $r('app.color.app_accent') : 'rgba(255,255,255,0.08)')
          .fontColor(this.avatarToolPermissionMode === 'DENY'
            ? Color.White : $r('app.color.app_text_primary'))
          .fontSize(11)
          .height(28)
          .layoutWeight(1)
          .margin({ right: 2 })
          .onClick(() => {
            this.setAvatarToolPermission('DENY');
          })

        Button('只读')
          .type(ButtonType.Normal)
          .borderRadius($r('app.float.app_radius_sm'))
          .backgroundColor(this.avatarToolPermissionMode === 'READ_ONLY'
            ? $r('app.color.app_accent') : 'rgba(255,255,255,0.08)')
          .fontColor(this.avatarToolPermissionMode === 'READ_ONLY'
            ? Color.White : $r('app.color.app_text_primary'))
          .fontSize(11)
          .height(28)
          .layoutWeight(1)
          .margin({ left: 2, right: 2 })
          .onClick(() => {
            this.setAvatarToolPermission('READ_ONLY');
          })

        Button('控制本次聊天')
          .type(ButtonType.Normal)
          .borderRadius($r('app.float.app_radius_sm'))
          .backgroundColor(this.avatarToolPermissionMode === 'CONTROL_THIS_CHAT'
            ? $r('app.color.app_accent') : 'rgba(255,255,255,0.08)')
          .fontColor(this.avatarToolPermissionMode === 'CONTROL_THIS_CHAT'
            ? Color.White : $r('app.color.app_text_primary'))
          .fontSize(11)
          .height(28)
          .layoutWeight(1)
          .margin({ left: 2 })
          .onClick(() => {
            this.setAvatarToolPermission('CONTROL_THIS_CHAT');
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding(8)
    .margin({ bottom: 4 })
    .borderRadius($r('app.float.app_radius_sm'))
    .backgroundColor('rgba(255,255,255,0.05)')
  }

  /**
   * Phase 4C-1: Avatar 对话演出策略状态区块。
   *
   * 显示:
   *   - 演出策略: BALANCED
   *   - 策略版本: V1
   *   - 策略已注入 / 未注入
   *   - 折叠区域: 允许工具 / 每 Turn 上限 / 当前权限 / 当前能力数量
   *
   * 不显示完整系统提示词。
   */
  @Builder
  avatarDialogueStrategyBlock() {
    Column() {
      Text('演出策略')
        .fontSize($r('app.float.app_font_caption'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ bottom: 4 })

      Row() {
        Text(`策略: ${this.avatarStrategyStatus !== null ? this.avatarStrategyStatus!.strategyMode : 'BALANCED'}`)
          .fontSize(11)
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(`版本: ${this.avatarStrategyStatus !== null ? this.avatarStrategyStatus!.strategyVersion.replace('AVATAR_DIALOGUE_STRATEGY_', '') : 'V1'}`)
          .fontSize(11)
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Text(`状态: ${this.avatarStrategyStatus !== null && this.avatarStrategyStatus!.injected ? '已注入' : '未注入'}${this.avatarStrategyStatus !== null && this.avatarStrategyStatus!.lastError.length > 0 ? ' | ' + this.avatarStrategyStatus!.lastError : ''}`)
        .fontSize(11)
        .fontColor(this.avatarStrategyStatus !== null && this.avatarStrategyStatus!.lastError.length > 0
          ? $r('app.color.app_danger')
          : $r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 2 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 折叠区域: 查看策略摘要
      Row() {
        Text(this.avatarStrategySummaryExpanded ? '收起摘要' : '查看策略摘要')
          .fontSize(11)
          .fontColor($r('app.color.app_accent'))
          .layoutWeight(1)
        Text(this.avatarStrategySummaryExpanded ? '▲' : '▼')
          .fontSize(11)
          .fontColor($r('app.color.app_accent'))
      }
      .width('100%')
      .margin({ top: 4 })
      .onClick(() => {
        this.avatarStrategySummaryExpanded = !this.avatarStrategySummaryExpanded;
      })

      if (this.avatarStrategySummaryExpanded && this.avatarStrategyStatus !== null) {
        Column() {
          Text(`当前权限: ${this.avatarStrategyStatus!.permissionMode}`)
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')
            .margin({ top: 2 })
          Text(`Provider: ${this.avatarStrategyStatus!.providerSupported ? '支持' : '不支持'}`)
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')
            .margin({ top: 2 })
          Text(`能力数量: ${this.avatarStrategyStatus!.capabilityCount}`)
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')
            .margin({ top: 2 })
          Text(`每 Turn 演出上限: ${this.avatarStrategyStatus!.maxPerformPerTurn}`)
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')
            .margin({ top: 2 })
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .margin({ top: 4 })
        .borderRadius($r('app.float.app_radius_sm'))
        .backgroundColor('rgba(255,255,255,0.04)')
      }
    }
    .width('100%')
    .padding(8)
    .margin({ bottom: 4 })
    .borderRadius($r('app.float.app_radius_sm'))
    .backgroundColor('rgba(255,255,255,0.05)')
  }

  /** Phase 4B-2R: 运行时辅助 - 当前镜头。 */
  private runtimeShotText(): string {
    if (this.avatarShotSnapshot === null) {
      return '-';
    }
    return this.avatarShotSnapshot!.currentShot;
  }

  /** Phase 4B-2R2: 运行时辅助 - 镜头控制模式 (AUTO / MANUAL_FULL_BODY / MANUAL_FACE)。 */
  private runtimeShotControlModeText(): string {
    if (this.avatarShotSnapshot === null) {
      return 'AUTO';
    }
    const mode: string = this.avatarShotSnapshot!.controlMode;
    if (mode === 'MANUAL_FULL_BODY') {
      return 'MANUAL_FULL_BODY';
    }
    if (mode === 'MANUAL_FACE_RESET_VIEW') {
      return 'MANUAL_FACE';
    }
    return 'AUTO';
  }

  /** Phase 4B-2R2: 运行时辅助 - 相机缩放倍率 (0.5×~3.0×)。 */
  private runtimeCameraZoomText(): string {
    if (this.avatarStageSnapshot === null) {
      return '1.0×';
    }
    const m: number = this.avatarStageSnapshot!.cameraZoomMultiplier;
    const fixed: number = Math.round(m * 10) / 10;
    return `${fixed.toFixed(1)}×`;
  }

  /** Phase 4B-2R2: 运行时辅助 - 动画加载状态 (actionId + 错误码)。 */
  private runtimeAnimationLoadText(): string {
    if (this.avatarStageSnapshot === null) {
      return '-';
    }
    const loadId: string = this.avatarStageSnapshot!.animationLoadActionId;
    const errCode: string = this.avatarStageSnapshot!.animationLoadErrorCode;
    if (loadId.length === 0 && errCode.length === 0) {
      return '-';
    }
    if (errCode.length > 0) {
      return `${loadId || '-'} | 错误: ${errCode}`;
    }
    return loadId.length > 0 ? loadId : '-';
  }

  /** Phase 4B-2R2: 运行时辅助 - 最后 Turn ID。 */
  private runtimeLastTurnIdText(): string {
    if (this.avatarStageSnapshot === null) {
      return '-';
    }
    const t: string = this.avatarStageSnapshot!.lastTurnId;
    return t.length > 0 ? t : '-';
  }

  /** Phase 4B-2R2: 运行时辅助 - 最后 Lifecycle 状态。 */
  private runtimeLifecycleStateText(): string {
    if (this.avatarStageSnapshot === null) {
      return 'IDLE';
    }
    return this.avatarStageSnapshot!.lastLifecycleState;
  }

  /** Phase 4B-2R: 运行时辅助 - 当前动作显示名。 */
  private runtimeActionText(): string {
    if (this.avatarStageSnapshot === null) {
      return '-';
    }
    const name: string = this.avatarStageSnapshot!.currentActionDisplayName;
    return name.length > 0 ? name : '-';
  }

  /** Phase 4B-2R: 运行时辅助 - 动画运行状态 (来自 Runtime Debug State)。 */
  private runtimeAnimationStateText(): string {
    if (this.avatarStageSnapshot === null) {
      return 'IDLE';
    }
    return this.avatarStageSnapshot!.animationRuntimeState;
  }

  /** Phase 4B-2R: 运行时辅助 - 当前姿势显示名。 */
  private runtimePoseText(): string {
    if (this.avatarStageSnapshot === null) {
      return '-';
    }
    const name: string = this.avatarStageSnapshot!.currentPoseDisplayName;
    return name.length > 0 ? name : '-';
  }

  /** Phase 4B-2R: 运行时辅助 - 姿势运行状态。 */
  private runtimePoseStateText(): string {
    if (this.avatarStageSnapshot === null) {
      return 'IDLE';
    }
    return this.avatarStageSnapshot!.poseRuntimeState;
  }

  /** Phase 4B-2R: 运行时辅助 - 当前表情显示名。 */
  private runtimeExpressionText(): string {
    if (this.avatarStageSnapshot === null) {
      return '-';
    }
    const id: string = this.avatarStageSnapshot!.currentExpressionId;
    const actual: string = this.avatarStageSnapshot!.currentExpressionActualName;
    if (id.length === 0) {
      return '-';
    }
    return actual.length > 0 ? `${id}→${actual}` : id;
  }

  /** Phase 4B-2R: 运行时辅助 - 表情运行状态。 */
  private runtimeExpressionStateText(): string {
    if (this.avatarStageSnapshot === null) {
      return 'IDLE';
    }
    return this.avatarStageSnapshot!.expressionRuntimeState;
  }

  /** Phase 4B-2R: 运行时辅助 - 最后结果文本 (含 publish 结果 + 错误码)。 */
  private runtimeLastResultText(): string {
    if (this.aiPanelButtonStatus === 'LOADING') {
      return `加载中 (${this.aiPanelActiveCapabilityId})`;
    }
    if (this.aiPanelButtonStatus === 'PLAYING') {
      return `播放中 (${this.aiPanelActiveCapabilityId})`;
    }
    if (this.aiPanelButtonStatus === 'APPLIED') {
      return `已应用 (${this.aiPanelActiveCapabilityId})`;
    }
    if (this.aiPanelButtonStatus === 'FAILED') {
      return `失败: ${this.aiPanelLastErrorCode}`;
    }
    if (this.avatarStageSnapshot !== null
        && this.avatarStageSnapshot!.lastPublishResult.length > 0) {
      return this.avatarStageSnapshot!.lastPublishResult;
    }
    return 'IDLE';
  }

  /** 诊断辅助: Viewer 状态文本。 */
  private stageViewerStateText(): string {
    if (this.avatarStageSnapshot === null) {
      return '-';
    }
    const s: string = this.avatarStageSnapshot!.viewerState;
    return s.length > 0 ? s : '-';
  }

  /** 诊断辅助: 模型状态/名称文本。 */
  private stageModelText(): string {
    if (this.avatarStageSnapshot === null) {
      return '未加载';
    }
    const name: string = this.avatarStageSnapshot!.activeModelDisplayName;
    if (name.length > 0) {
      return name;
    }
    return this.avatarStageSnapshot!.modelState;
  }

  /** 诊断辅助: 渲染 Profile 文本。 */
  private stageProfileText(): string {
    if (this.avatarStageSnapshot === null) {
      return '-';
    }
    const p: string = this.avatarStageSnapshot!.renderProfile;
    return p.length > 0 ? p : '-';
  }

  /** 诊断辅助: Stage 尺寸文本。 */
  private stageSizeText(): string {
    if (this.avatarStageSnapshot === null) {
      return '0x0';
    }
    const w: number = this.avatarStageSnapshot!.stageWidth;
    const h: number = this.avatarStageSnapshot!.stageHeight;
    return `${w}x${h}`;
  }

  /** 诊断辅助: 错误码文本 (仅在 FAILED/有错误码时显示)。 */
  private stageErrorText(): string {
    if (this.avatarStageSnapshot === null) {
      return '';
    }
    const code: string = this.avatarStageSnapshot!.lastErrorCode;
    return code.length > 0 ? code : '';
  }

  /** Phase 4B-2 诊断辅助: 镜头状态文本。 */
  private shotStateText(): string {
    if (this.avatarShotSnapshot === null) {
      return '-';
    }
    const state: string = this.avatarShotSnapshot!.state;
    const shot: string = this.avatarShotSnapshot!.currentShot;
    if (state === 'TRANSITIONING') {
      return `切换中 → ${this.avatarShotSnapshot!.requestedShot}`;
    }
    if (state === 'FAILED') {
      return `失败 (${shot})`;
    }
    if (state === 'DISPOSED') {
      return '已销毁';
    }
    // FULL_BODY / FACE_RESET_VIEW / IDLE
    return shot;
  }

  /**
   * Phase 4B-1R §第八项: 重新加载模型按钮回调。
   *
   * 流程:
   *   1. controller.reloadActiveModel() (内部 generation++ + 重新 startActiveModelRestore)
   *   2. 刷新快照到 @State (触发诊断块刷新)
   *
   * 不删除持久模型 / library.json。
   */
  private reloadAvatarModel(): void {
    if (this.avatarStageController === null) {
      Logger.warn(LOG_TAG, 'reloadAvatarModel: controller null');
      return;
    }
    const controller: ArkWebChatAvatarStageController = this.avatarStageController!;
    // 立即刷新一次快照 (展示用户已点击)
    this.avatarStageSnapshot = controller.getRuntimeSnapshot();
    controller.reloadActiveModel().then((): void => {
      this.avatarStageSnapshot = controller.getRuntimeSnapshot();
      this.avatarShotSnapshot = controller.getShotRuntimeSnapshot();
    }).catch((e: Object): void => {
      Logger.warn(LOG_TAG, 'reloadAvatarModel failed: ' +
        (e instanceof Error ? e.message : String(e)));
      this.avatarStageSnapshot = controller.getRuntimeSnapshot();
      this.avatarShotSnapshot = controller.getShotRuntimeSnapshot();
    });
  }

  /**
   * Phase 4B-2: 手动切换到全身镜头 (AI 面板验证按钮)。
   *
   * 只调用 ShotDirector, 不直接调用 ArkWebVrmViewerController 相机方法。
   */
  private transitionToFullBody(): void {
    if (this.avatarStageController === null) {
      Logger.warn(LOG_TAG, 'transitionToFullBody: controller null');
      return;
    }
    const controller: ArkWebChatAvatarStageController = this.avatarStageController!;
    controller.transitionToFullBody('AI_PANEL_BUTTON').then((ok: boolean): void => {
      this.avatarShotSnapshot = controller.getShotRuntimeSnapshot();
      if (!ok) {
        Logger.warn(LOG_TAG, 'transitionToFullBody returned false');
      }
    }).catch((e: Object): void => {
      Logger.warn(LOG_TAG, 'transitionToFullBody failed: ' +
        (e instanceof Error ? e.message : String(e)));
      this.avatarShotSnapshot = controller.getShotRuntimeSnapshot();
    });
  }

  /**
   * Phase 4B-2: 手动切换到脸部 (重置) 镜头 (AI 面板验证按钮)。
   *
   * 只调用 ShotDirector, 不直接调用 ArkWebVrmViewerController 相机方法。
   */
  private transitionToFaceResetView(): void {
    if (this.avatarStageController === null) {
      Logger.warn(LOG_TAG, 'transitionToFaceResetView: controller null');
      return;
    }
    const controller: ArkWebChatAvatarStageController = this.avatarStageController!;
    controller.transitionToFaceResetView('AI_PANEL_BUTTON').then((ok: boolean): void => {
      this.avatarShotSnapshot = controller.getShotRuntimeSnapshot();
      if (!ok) {
        Logger.warn(LOG_TAG, 'transitionToFaceResetView returned false');
      }
    }).catch((e: Object): void => {
      Logger.warn(LOG_TAG, 'transitionToFaceResetView failed: ' +
        (e instanceof Error ? e.message : String(e)));
      this.avatarShotSnapshot = controller.getShotRuntimeSnapshot();
    });
  }

  /**
   * 调节模型大小 (通过 fillRatio 重新构图)。
   *
   * 调用 controller.adjustModelFillRatio(fillRatio) 重新执行 fitAvatarFullBody。
   * fillRatio 越大模型越大 (0.5=较小, 0.95=几乎填满)。
   */
  private adjustAvatarModelSize(fillRatio: number): void {
    if (this.avatarStageController === null) {
      Logger.warn(LOG_TAG, 'adjustAvatarModelSize: controller null');
      return;
    }
    this.avatarStageController!.adjustModelFillRatio(fillRatio).catch((e: Object): void => {
      Logger.warn(LOG_TAG, 'adjustAvatarModelSize failed: ' +
        (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 4B-2R2: 设置镜头控制模式。
   *
   * @param mode AUTO / MANUAL_FULL_BODY / MANUAL_FACE_RESET_VIEW
   */
  private setShotControlMode(mode: ArkWebAvatarShotControlMode): void {
    if (this.avatarStageController === null) {
      Logger.warn(LOG_TAG, 'setShotControlMode: controller null');
      return;
    }
    this.avatarShotControlMode = mode;
    this.avatarStageController!.setShotControlMode(mode);
    this.avatarShotSnapshot = this.avatarStageController!.getShotRuntimeSnapshot();
    Logger.info(LOG_TAG, `setShotControlMode: ${mode}`);
  }

  /**
   * Phase 4B-2R2: 调节相机缩放倍率 (通过相机距离实现视觉缩放)。
   *
   * 调用 controller.setCameraZoomMultiplier(multiplier) 调整相机到目标点的距离。
   * 不修改模型 transform, 不重置 fillRatio。
   *
   * @param multiplier 缩放倍率 (0.5~3.0)
   */
  private adjustCameraZoomMultiplier(multiplier: number): void {
    if (this.avatarStageController === null) {
      Logger.warn(LOG_TAG, 'adjustCameraZoomMultiplier: controller null');
      return;
    }
    this.avatarStageController!.setCameraZoomMultiplier(multiplier).catch((e: Object): void => {
      Logger.warn(LOG_TAG, 'adjustCameraZoomMultiplier failed: ' +
        (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * Phase 4B-2R2: 格式化缩放倍率显示文本。
   *
   * @param multiplier 缩放倍率
   * @returns 格式化文本 (如 "1.0×")
   */
  private formatZoomMultiplier(multiplier: number): string {
    const fixed: number = Math.round(multiplier * 10) / 10;
    return `${fixed.toFixed(1)}×`;
  }

  // ===== 显示设置面板(气泡不透明度 + 字体配色) =====

  @Builder
  chatAppearancePanel() {
    if (this.chatAppearancePanelVisible) {
      // 面板容器:靠右,不覆盖整屏,半透明背景,无全屏遮罩
      Row() {
        Scroll() {
          Column() {
            // 标题行
            Row() {
              Text('显示设置')
                .fontSize($r('app.float.app_font_body'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.app_text_primary'))
              Blank()
              // 关闭按钮
              Stack() {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(14)
                  .fontColor([$r('app.color.app_text_secondary')])
              }
              .width(28)
              .height(28)
              .borderRadius(14)
              .onClick(() => {
                this.chatAppearancePanelVisible = false;
              })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 12 })

            // ===== 气泡不透明度 =====
            Row() {
              Text('气泡不透明度')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_secondary'))
              Blank()
              Text(`${Math.round(this.chatBubbleOpacity * 100)}%`)
                .fontSize($r('app.float.app_font_caption'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.app_text_primary'))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 8 })

            Slider({
              value: Math.round(this.chatBubbleOpacity * 100),
              min: 0,
              max: 100,
              step: 5,
              style: SliderStyle.OutSet
            })
              .blockColor($r('app.color.app_accent'))
              .trackColor($r('app.color.app_surface_2'))
              .selectedColor($r('app.color.app_accent'))
              .width('100%')
              .onChange((value: number, mode: SliderChangeMode) => {
                const opacity: number = this.normalizeChatBubbleOpacity(value / 100);
                this.chatBubbleOpacity = opacity;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.persistBubbleOpacity(opacity);
                }
              })

            Row() {
              Text('0%')
                .fontSize(11)
                .fontColor($r('app.color.app_text_secondary'))
              Blank()
              Text('100%')
                .fontSize(11)
                .fontColor($r('app.color.app_text_secondary'))
            }
            .width('100%')
            .margin({ top: 4 })

            Divider()
              .color($r('app.color.app_divider'))
              .margin({ top: 16, bottom: 12 })

            // ===== 文字配色模式 =====
            Row() {
              Text('文字配色')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_secondary'))
              Blank()
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 8 })

            // 模式按钮:自动 / 浅色 / 深色 / 自定义
            Row({ space: 6 }) {
              ForEach([
                ChatTextColorMode.AUTO,
                ChatTextColorMode.LIGHT,
                ChatTextColorMode.DARK,
                ChatTextColorMode.CUSTOM
              ], (mode: string) => {
                Button(this.getModeLabel(mode))
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor(this.chatTextColorMode === mode
                    ? $r('app.color.app_on_accent')
                    : $r('app.color.app_text_primary'))
                  .backgroundColor(this.chatTextColorMode === mode
                    ? $r('app.color.app_accent')
                    : $r('app.color.app_surface_2'))
                  .borderRadius(14)
                  .height(28)
                  .padding({ left: 10, right: 10 })
                  .onClick(() => {
                    this.setChatTextColorMode(mode);
                  })
              }, (mode: string) => mode)
            }
            .width('100%')

            // 对比度辅助提示
            Text('气泡较透明时建议使用浅色文字,气泡较不透明时可使用深色文字')
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .margin({ top: 8 })

            // 快捷按钮:适合深色背景 / 适合浅色背景
            Row({ space: 8 }) {
              Button('适合深色背景')
                .fontSize(11)
                .fontColor(this.chatTextColorMode === ChatTextColorMode.LIGHT
                  ? $r('app.color.app_on_accent')
                  : $r('app.color.app_accent'))
                .backgroundColor(this.chatTextColorMode === ChatTextColorMode.LIGHT
                  ? $r('app.color.app_accent')
                  : Color.Transparent)
                .border({
                  width: 1,
                  color: $r('app.color.app_accent')
                })
                .borderRadius(12)
                .height(24)
                .padding({ left: 8, right: 8 })
                .onClick(() => {
                  this.setChatTextColorMode(ChatTextColorMode.LIGHT);
                })
              Button('适合浅色背景')
                .fontSize(11)
                .fontColor(this.chatTextColorMode === ChatTextColorMode.DARK
                  ? $r('app.color.app_on_accent')
                  : $r('app.color.app_accent'))
                .backgroundColor(this.chatTextColorMode === ChatTextColorMode.DARK
                  ? $r('app.color.app_accent')
                  : Color.Transparent)
                .border({
                  width: 1,
                  color: $r('app.color.app_accent')
                })
                .borderRadius(12)
                .height(24)
                .padding({ left: 8, right: 8 })
                .onClick(() => {
                  this.setChatTextColorMode(ChatTextColorMode.DARK);
                })
            }
            .width('100%')
            .margin({ top: 8 })

            // ===== 自定义配色(仅在 CUSTOM 模式下显示)=====
            if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
              Divider()
                .color($r('app.color.app_divider'))
                .margin({ top: 12, bottom: 12 })

              Text('自定义配色')
                .fontSize($r('app.float.app_font_caption'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.app_text_primary'))
                .width('100%')
                .margin({ bottom: 8 })

              // 正文颜色
              this.colorSwatchRow('正文颜色', 'body', this.chatAssistantTextColor)

              // Markdown 强调色
              this.colorSwatchRow('Markdown 强调色', 'accent', this.chatMarkdownAccentColor)

              // 次级文字颜色
              this.colorSwatchRow('次级文字', 'secondary', this.chatSecondaryTextColor)

              // 用户消息文字
              this.colorSwatchRow('用户消息文字', 'user', this.chatUserTextColor)
            }

            Divider()
              .color($r('app.color.app_divider'))
              .margin({ top: 12, bottom: 12 })

            // ===== 预览区域 =====
            Text('预览')
              .fontSize($r('app.float.app_font_caption'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_text_primary'))
              .width('100%')
              .margin({ bottom: 6 })

            this.fontColorPreviewArea()

            // ===== 恢复默认按钮 =====
            Row({ space: 8 }) {
              Button('恢复默认')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_accent'))
                .backgroundColor(Color.Transparent)
                .borderRadius(8)
                .height(32)
                .padding({ left: 12, right: 12 })
                .enabled(!this.isChatTextColorDefault())
                .onClick(() => {
                  this.resetChatTextColor();
                })
              Button('全部恢复默认')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_secondary'))
                .backgroundColor(Color.Transparent)
                .borderRadius(8)
                .height(32)
                .padding({ left: 12, right: 12 })
                .enabled(this.chatBubbleOpacity !== 0.65 || !this.isChatTextColorDefault())
                .onClick(() => {
                  this.resetAllAppearance();
                })
            }
            .width('100%')
            .margin({ top: 12 })
          }
          .width('100%')
          .padding(16)
        }
        .width('70%')
        .height('70%')
        .scrollBar(BarState.Auto)
        .backgroundColor(this.isDarkMode ? '#CC2A2A2A' : '#E6FFFFFF')
        .borderRadius(16)
        .shadow({ radius: 12, color: 'rgba(0,0,0,0.15)', offsetX: 0, offsetY: 4 })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ right: 12, top: this.statusBarHeight + 52 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }

  /**
   * 颜色色块行:标签 + 预设色块 + Hex 输入。
   * 仅在 CUSTOM 模式下渲染。
   * 色块点击即应用,Hex 输入失焦时校验并提交(非法值不提交)。
   */
  @Builder
  colorSwatchRow(label: string, target: 'body' | 'accent' | 'user' | 'secondary', currentColor: string) {
    Column() {
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
        Blank()
        // 当前颜色预览圆点
        Stack()
          .width(16)
          .height(16)
          .borderRadius(8)
          .backgroundColor(currentColor)
          .border({ width: 1, color: $r('app.color.app_divider') })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 6 })

      // 预设色块
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.presetSwatches, (swatch: string) => {
          Stack() {
            if (currentColor.toUpperCase() === swatch.toUpperCase()) {
              // 选中标记:勾选
              Text('✓')
                .fontSize(12)
                .fontColor(swatch.toUpperCase() === '#FFFFFF' || swatch.toUpperCase() === '#E5E7EB' || swatch.toUpperCase() === '#90CAF9' || swatch.toUpperCase() === '#FFC107'
                  ? '#171717' : '#FFFFFF')
                .fontWeight(FontWeight.Bold)
            }
          }
          .width(24)
          .height(24)
          .borderRadius(12)
          .backgroundColor(swatch)
          .border({
            width: currentColor.toUpperCase() === swatch.toUpperCase() ? 2 : 1,
            color: currentColor.toUpperCase() === swatch.toUpperCase()
              ? $r('app.color.app_accent')
              : $r('app.color.app_divider')
          })
          .margin({ right: 8, bottom: 6 })
          .onClick(() => {
            this.setCustomColor(target, swatch);
          })
        }, (swatch: string, index: number) => swatch + index.toString())
      }
      .width('100%')

      // Hex 输入框
      Row() {
        TextInput({ text: currentColor, placeholder: '#RRGGBB' })
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(8)
          .height(32)
          .layoutWeight(1)
          .onChange((value: string) => {
            // 实时校验:合法时立即提交,非法值不提交
            const normalized: string | null = normalizeHexColor(value);
            if (normalized !== null) {
              this.setCustomColor(target, normalized);
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  /**
   * 字体配色预览区域(固定演示文本,不发送消息,不调用网络)。
   * 颜色根据当前模式实时计算,立即更新。
   */
  @Builder
  fontColorPreviewArea() {
    Column({ space: 6 }) {
      // 正文预览
      Row() {
        Text('正文预览')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewBodyColor())
      }
      .width('100%')

      // 强调文字(模拟 Markdown 加粗)
      Row() {
        Text('强调文字')
          .fontSize($r('app.float.app_font_caption'))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.getPreviewAccentColor())
      }
      .width('100%')

      // 链接文字
      Row() {
        Text('链接文字')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewAccentColor())
      }
      .width('100%')

      // 次级文字(旁白/引用)
      Row() {
        Text('次级文字(旁白)')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewSecondaryColor())
      }
      .width('100%')

      // 用户消息预览(右对齐,带气泡背景)
      Row() {
        Text('用户消息')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewUserColor())
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(this.computeUserBubbleColor())
          .borderRadius(10)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(this.computeAssistantBubbleColor())
    .borderRadius(10)
  }

  /**
   * 计算预览区域助手气泡背景色(基于当前气泡不透明度)。
   * 字体配色与气泡不透明度相互独立:此处仅用于预览背景渲染,
   * 不影响字体颜色,也不受字体模式影响。
   * 浅色模式下基底为白色,深色模式下基底为深灰,叠加 chatBubbleOpacity。
   */
  private computeAssistantBubbleColor(): string {
    const alpha: number = this.chatBubbleOpacity;
    if (this.isDarkMode) {
      // 深色模式:深灰底 0x2A2A2A,叠加 Alpha
      const r: number = Math.round(0x2A * alpha + 0x00 * (1 - alpha));
      const g: number = Math.round(0x2A * alpha + 0x00 * (1 - alpha));
      const b: number = Math.round(0x2A * alpha + 0x00 * (1 - alpha));
      return `#${this.toHex2(r)}${this.toHex2(g)}${this.toHex2(b)}`;
    }
    // 浅色模式:白底 0xFFFFFF,叠加 Alpha 向透明过渡(与 0x000000 混合)
    const r: number = Math.round(0xFF * alpha + 0xFF * (1 - alpha));
    const g: number = Math.round(0xFF * alpha + 0xFF * (1 - alpha));
    const b: number = Math.round(0xFF * alpha + 0xFF * (1 - alpha));
    return `#${this.toHex2(r)}${this.toHex2(g)}${this.toHex2(b)}`;
  }

  /**
   * 计算预览区域用户气泡背景色(品牌蓝 + 当前不透明度)。
   * 用户气泡背景与字体颜色独立,保持品牌色基调。
   */
  private computeUserBubbleColor(): string {
    const alpha: number = this.chatBubbleOpacity;
    // 品牌蓝 0x5B7CFA,叠加 Alpha
    const r: number = Math.round(0x5B * alpha + 0x00 * (1 - alpha));
    const g: number = Math.round(0x7C * alpha + 0x00 * (1 - alpha));
    const b: number = Math.round(0xFA * alpha + 0x00 * (1 - alpha));
    return `#${this.toHex2(r)}${this.toHex2(g)}${this.toHex2(b)}`;
  }

  /** 将 0~255 整数转为 2 位大写 Hex */
  private toHex2(value: number): string {
    const clamped: number = Math.max(0, Math.min(255, Math.round(value)));
    const hex: string = clamped.toString(16).toUpperCase();
    return hex.length === 1 ? '0' + hex : hex;
  }

  /**
   * 获取预览区域正文颜色。
   * AUTO 模式使用默认色值,DARK/CUSTOM 使用对应主题色值。
   */
  private getPreviewBodyColor(): string {
    if (this.chatTextColorMode === ChatTextColorMode.LIGHT) {
      return '#FFFFFF';
    }
    if (this.chatTextColorMode === ChatTextColorMode.DARK) {
      return DEFAULT_ASSISTANT_TEXT_COLOR;
    }
    if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
      return isValidHexColor(this.chatAssistantTextColor)
        ? this.chatAssistantTextColor.toUpperCase()
        : DEFAULT_ASSISTANT_TEXT_COLOR;
    }
    // AUTO:使用默认深色正文(预览固定展示)
    return DEFAULT_ASSISTANT_TEXT_COLOR;
  }

  /** 获取预览区域强调色 */
  private getPreviewAccentColor(): string {
    if (this.chatTextColorMode === ChatTextColorMode.LIGHT) {
      return '#90CAF9';
    }
    if (this.chatTextColorMode === ChatTextColorMode.DARK) {
      return DEFAULT_MARKDOWN_ACCENT_COLOR;
    }
    if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
      return isValidHexColor(this.chatMarkdownAccentColor)
        ? this.chatMarkdownAccentColor.toUpperCase()
        : DEFAULT_MARKDOWN_ACCENT_COLOR;
    }
    return DEFAULT_MARKDOWN_ACCENT_COLOR;
  }

  /** 获取预览区域次级文字颜色 */
  private getPreviewSecondaryColor(): string {
    if (this.chatTextColorMode === ChatTextColorMode.LIGHT) {
      return '#E5E7EB';
    }
    if (this.chatTextColorMode === ChatTextColorMode.DARK) {
      return DEFAULT_SECONDARY_TEXT_COLOR;
    }
    if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
      return isValidHexColor(this.chatSecondaryTextColor)
        ? this.chatSecondaryTextColor.toUpperCase()
        : DEFAULT_SECONDARY_TEXT_COLOR;
    }
    return DEFAULT_SECONDARY_TEXT_COLOR;
  }

  /** 获取预览区域用户消息颜色 */
  private getPreviewUserColor(): string {
    if (this.chatTextColorMode === ChatTextColorMode.LIGHT) {
      return '#FFFFFF';
    }
    if (this.chatTextColorMode === ChatTextColorMode.DARK) {
      return DEFAULT_USER_TEXT_COLOR;
    }
    if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
      return isValidHexColor(this.chatUserTextColor)
        ? this.chatUserTextColor.toUpperCase()
        : DEFAULT_USER_TEXT_COLOR;
    }
    return DEFAULT_USER_TEXT_COLOR;
  }

  // ===== 消息列表 =====

  @Builder
  messageList() {
    Scroll(this.scroller) {
      Column() {
        LazyForEach(this.dataSource, (state: ChatMessageRenderState, _index: number) => {
          if (state.role !== ChatRole.System) {
            Column() {
              ChatMessageBubble({
                renderState: state,
                characterAvatarUri: this.character !== null ? this.character!.avatarUri : '',
                characterName: this.viewModel !== null ? this.viewModel!.characterName : '',
                showAvatar: state.source !== ChatMessageSource.CharacterFirstMessage,
                settings: this.chatTextStyle,
                senderCharacterId: this.character !== null ? this.character!.id : '',
                colorTheme: this.getCurrentColorTheme(),
                bubbleOpacity: this.chatBubbleOpacity,
                isDarkMode: this.isDarkMode,
                onLongPress: (target: ChatMessage): void => {
                  this.actionSheetMsg = target;
                  this.showActionSheet = true;
                }
              })

              // 分支切换控件(仅 Assistant 非首条消息)
              if (state.role === ChatRole.Assistant
                && state.source !== ChatMessageSource.CharacterFirstMessage
                && this.viewModel !== null) {
                MessageSwipeControls({
                  activeCandidateIndex: this.getSwipeActiveIndex(state.messageId),
                  candidateCount: this.getCandidateCount(state.messageId),
                  isGenerating: this.viewModel!.isGenerating,
                  isOperable: this.viewModel!.canOperateSwipe(state.messageId),
                  isMaxReached: this.getCandidateCount(state.messageId) >= MAX_SWIPE_CANDIDATES,
                  onPrevious: (): void => {
                    this.viewModel!.swipePrevious(state.messageId);
                  },
                  onNext: (): void => {
                    this.viewModel!.swipeNext(state.messageId);
                  },
                  onRegenerate: (): void => {
                    this.viewModel!.regenerateAsNewCandidate();
                  },
                  onStop: (): void => {
                    this.viewModel!.stop();
                  }
                })
              }

              // 失败重试按钮
              if (state.status === ChatMessageStatus.Failed
                && this.viewModel !== null
                && this.viewModel!.canRegenerateAssistantMessage(state.messageId)) {
                Row() {
                  Button({ type: ButtonType.Normal, stateEffect: false }) {
                    Row() {
                      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                        .fontSize(14)
                        .fontColor([$r('app.color.app_accent')])
                      Text($r('app.string.chat_regenerate'))
                        .fontSize($r('app.float.app_font_caption'))
                        .fontColor($r('app.color.app_accent'))
                        .margin({ left: 4 })
                    }
                  }
                  .backgroundColor(this.computeRegenerateButtonColor())
                  .borderRadius(14)
                  .height(28)
                  .padding({ left: 12, right: 12 })
                  .margin({ top: 4, bottom: 4 })
                  .onClick(() => {
                    this.regenerateAssistantMessage(state.messageId);
                  })
                }
                .width('100%')
                .justifyContent(FlexAlign.Start)
                .margin({ left: 0 })
              }
            }
            .width('100%')
          }
        }, (state: ChatMessageRenderState) => state.messageId)
        // 底部空白占位:高度等于悬浮输入栏占用空间(输入栏 56 + bottom padding 12 + navBar 12),
        // 让 scrollEdge(Bottom) 时最后一条消息显示在悬浮输入栏上方,不被遮挡。
        Blank().height(80 + this.navigationBarHeight)
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: this.statusBarHeight + 12,
        bottom: 0
      })
      .onAreaChange(() => {
        this.autoScrollToBottom();
      })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .height('100%')
    .onScrollEdge((side: Edge) => {
      if (side === Edge.Bottom && this.viewModel !== null) {
        this.viewModel!.userScrolledUp = false;
      }
    })
    .onScrollEnd(() => {
      if (this.viewModel !== null && this.scroller.isAtEnd()) {
        this.viewModel!.userScrolledUp = false;
      }
    })
  }

  /**
   * 同步最新消息到稳定 RenderState 列表。
   *
   * 关键约束:
   * - 同一 messageId 始终复用已有 RenderState 实例,保证 ForEach 稳定复用 Bubble
   * - 已有实例就地调用 applyMessage,@Observed 字段赋值触发 @ObjectLink 响应式重建
   * - 新消息才创建新 RenderState
   * - 已不存在于最新消息中的旧状态从缓存中移除
   * - 始终按最新消息顺序生成新 messageStates 数组(不原地修改)
   */
  private syncRenderStates(messages: ChatMessage[]): void {
    const nextStates: ChatMessageRenderState[] = [];
    const newIds: Set<string> = new Set<string>();
    let reusedCount: number = 0;
    let newCount: number = 0;
    for (let i: number = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      newIds.add(msg.id);
      let state: ChatMessageRenderState | undefined = this.stateMap.get(msg.id);
      if (state === undefined) {
        state = new ChatMessageRenderState(msg);
        this.stateMap.set(msg.id, state);
        newCount++;
      } else {
        state.applyMessage(msg);
        reusedCount++;
      }
      nextStates.push(state);
    }
    // 清理已不在最新消息列表中的旧状态
    const oldIds: string[] = Array.from(this.stateMap.keys());
    let removedCount: number = 0;
    for (let i: number = 0; i < oldIds.length; i++) {
      if (!newIds.has(oldIds[i])) {
        this.stateMap.delete(oldIds[i]);
        removedCount++;
      }
    }
    this.messageStates = nextStates;
    // 同步懒加载数据源,触发 LazyForEach 按 key 复用已有气泡组件
    this.dataSource.setStates(nextStates);
  }

  // ===== 空会话状态 =====

  @Builder
  emptyStateView() {
    Column() {
      if (this.viewModel !== null && !this.viewModel!.hasCurrentModel) {
        Text($r('app.string.chat_no_model'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ bottom: $r('app.float.app_spacing_16') })

        Button($r('app.string.chat_go_settings'))
          .fontSize($r('app.float.app_font_body'))
          .backgroundColor($r('app.color.app_accent'))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(40)
          .padding({ left: 20, right: 20 })
          .onClick(() => {
            this.goToModelSettings();
          })
      } else if (this.character !== null) {
        // 显示角色头像 + 名称 + 开场白
        CharacterImageView({
          imageUri: this.character!.avatarUri,
          fallbackName: this.character!.name,
          imgWidth: 80,
          imgHeight: 80,
          imgBorderRadius: 40,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })
        Text(this.character!.name)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ top: $r('app.float.app_spacing_12') })

        if (this.character!.firstMessage.length > 0) {
          Text(this.character!.firstMessage)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ top: $r('app.float.app_spacing_12'), left: 32, right: 32 })
            .padding({
              left: $r('app.float.app_spacing_16'),
              right: $r('app.float.app_spacing_16'),
              top: $r('app.float.app_spacing_12'),
              bottom: $r('app.float.app_spacing_12')
            })
            .backgroundColor($r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_md'))
        }

        Text($r('app.string.nav_chat_empty'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: $r('app.float.app_spacing_24') })
      } else {
        Text($r('app.string.nav_chat_empty'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontColor($r('app.color.app_text_secondary'))
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24, top: 32, bottom: 32 })
  }

  // ===== 加载/错误视图 =====

  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color($r('app.color.app_accent'))
      Text('加载会话中…')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  initErrorView() {
    Column() {
      Text('会话初始化失败')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontColor($r('app.color.app_danger'))
        .margin({ bottom: 8 })
      Text(this.viewModel !== null ? this.viewModel!.initError : '')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 底部输入区 =====

  /**
   * v8.1: 紧凑上下文占用指示器
   * - 显示在输入栏上方(贴近输入栏,不遮挡消息)
   * - 格式:"12.4K / 32K · 39%"
   * - 颜色按占用级别变化(Normal/Warning/High/Exceeded)
   * - 点击打开 ContextBudgetPage
   * - 无统计数据时隐藏
   */
  @Builder
  budgetIndicator() {
    if (this.budgetViewModel !== null
      && this.budgetStats !== null
      && this.budgetViewModel!.effectiveAvailable > 0
      && this.budgetStats!.totalInputTokens > 0) {
      Row() {
        Text(this.getBudgetIndicatorText())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getBudgetIndicatorColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .margin({ bottom: 6 })
      .borderRadius(12)
      .backgroundColor($r('app.color.app_surface_1'))
      .onClick(() => {
        this.navigateToContextBudget();
      })
    }
  }

  @Builder
  inputArea() {
    // 悬浮式输入容器:胶囊造型 + 鸿蒙原生材质模糊(Regular 厚度)
    // 容器本身不承载不透明背景,页面背景透过模糊隐约可见。
    // 外边距:左右 12vp(与页面其他内容对齐),底部 12vp + 手势条高度(避开系统手势条)。
    Row() {
      TextArea({
        placeholder: $r('app.string.chat_input_placeholder'),
        text: this.viewModel !== null ? this.viewModel!.inputText : ''
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        // 背景透明:由外层 Row 的 backgroundBlurStyle 统一提供视觉容器
        .backgroundColor(Color.Transparent)
        .borderRadius($r('app.float.app_radius_md'))
        .border({ width: 0 })
        .maxLines(5)
        .constraintSize({ minHeight: 48 })
        .layoutWeight(1)
        .padding({ left: 16, right: 8, top: 10, bottom: 10 })
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string) => {
          if (this.viewModel !== null) {
            this.viewModel!.updateInput(value);
          }
        })
        .onSubmit((enterKey: EnterKeyType, event?: SubmitEvent) => {
          // 软键盘回车(EnterKeyType.Send):触发发送并保持编辑态
          if (this.isBudgetExceeded()) {
            this.notifyBudgetBlocked();
          } else if (this.canSend() && this.viewModel !== null) {
            this.viewModel!.send();
          }
          event?.keepEditableState();
        })
        .onKeyPreIme((event: KeyEvent): boolean => {
          // 物理键盘回车发送消息(Ctrl+Enter 仍为换行)
          if (event.type === KeyType.Down
            && (event.keyCode === KeyCode.KEYCODE_ENTER
              || event.keyCode === KeyCode.KEYCODE_NUMPAD_ENTER)) {
            let hasCtrl: boolean = false;
            try {
              hasCtrl = event.getModifierKeyState?.(['Ctrl']) ?? false;
            } catch (_e) {
              hasCtrl = false;
            }
            if (hasCtrl) {
              return false;
            }
            if (this.isBudgetExceeded()) {
              this.notifyBudgetBlocked();
              return true;
            }
            if (this.canSend() && this.viewModel !== null) {
              this.viewModel!.send();
              return true;
            }
          }
          return false;
        })

      // 发送/停止按钮:圆形 48x48,与输入框同处一个胶囊容器
      if (this.viewModel !== null && this.viewModel!.canStop) {
        // 停止按钮:危险色填充,圆角 24(圆形)
        Stack() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(20)
            .fontColor([$r('app.color.app_on_accent')])
        }
        .backgroundColor($r('app.color.app_danger'))
        .borderRadius(24)
        .height(48)
        .width(48)
        .margin({ right: 4 })
        .onClick(() => {
          this.viewModel!.stop();
        })
      } else {
        // 发送按钮:可发送用强调色 + 轻量光感,不可发送弱化为透明
        Stack() {
          SymbolGlyph($r('sys.symbol.arrow_up'))
            .fontSize(20)
            .fontColor([
              this.canSend()
                ? $r('app.color.app_on_accent')
                : $r('app.color.app_text_tertiary')
            ])
        }
        .backgroundColor(this.canSend()
          ? $r('app.color.app_accent')
          : Color.Transparent)
        .borderRadius(24)
        .height(48)
        .width(48)
        .margin({ right: 4 })
        .onClick(() => {
          if (this.isBudgetExceeded()) {
            this.notifyBudgetBlocked();
            return;
          }
          if (this.canSend() && this.viewModel !== null) {
            this.viewModel!.send();
          }
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 胶囊造型:大圆角,轻量边框增强层次(边框色用 surface_2 自动适配深浅色)
    .borderRadius(28)
    .border({ width: 0.5, color: $r('app.color.app_surface_2') })
    // 鸿蒙原生材质模糊:Regular 厚度,自动适配深浅色模式,隐约透出后方页面背景
    .backgroundBlurStyle(BlurStyle.Regular, {
      policy: BlurStyleActivePolicy.ALWAYS_ACTIVE
    })
    .padding({ left: 4, right: 0, top: 0, bottom: 0 })
  }

  // ===== 清空确认弹窗 =====

  @Builder
  clearConfirmDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.chat_clear'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 8 })

          Text('将删除当前会话的所有消息,此操作不可撤销。')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ bottom: 16 })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.app_text_secondary'))
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.showClearConfirm = false;
              })
            Button($r('app.string.chat_clear'))
              .fontSize(15)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  this.viewModel!.clear();
                }
                this.showClearConfirm = false;
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showClearConfirm = false;
    })
  }

  // ===== v9: 本对话称呼覆盖对话框 =====

  /**
   * 打开本对话称呼覆盖编辑对话框。
   * - 加载当前覆盖值到草稿
   * - 同步刷新一次 resolvedUserName
   */
  private openUserNameOverrideDialog(): void {
    if (this.viewModel === null) {
      return;
    }
    this.userNameOverrideDraft = this.viewModel!.getCurrentChatUserNameOverride();
    this.showUserNameOverrideDialog = true;
  }

  /**
   * 保存对话级用户称呼覆盖。
   * - 草稿 trim 后为空:清空覆盖(回退到角色或全局)
   * - 草稿非空:写入覆盖(仅影响当前会话)
   */
  private async saveUserNameOverride(): Promise<void> {
    if (this.viewModel === null) {
      this.showUserNameOverrideDialog = false;
      return;
    }
    try {
      const trimmed: string = this.userNameOverrideDraft.trim();
      await this.viewModel!.updateUserNameOverride(trimmed.length > 0 ? trimmed : null);
      await this.refreshUserNameDisplay();
    } catch (e) {
      // 失败时只关闭对话框,不阻塞后续操作
    }
    this.showUserNameOverrideDialog = false;
  }

  /**
   * 刷新当前生效用户称呼 + 对话覆盖的显示状态。
   * 在打开菜单、关闭菜单、保存覆盖后调用。
   */
  private async refreshUserNameDisplay(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      this.resolvedUserName = await this.viewModel!.getResolvedUserName();
      this.currentUserNameOverride = this.viewModel!.getCurrentChatUserNameOverride();
    } catch (e) {
      // 读取失败时保留空值,不影响主流程
    }
  }

  @Builder
  userNameOverrideDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.chat_user_name_override_menu_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 8 })

          Text($r('app.string.chat_user_name_override_hint'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ bottom: 16 })

          TextInput({
            placeholder: $r('app.string.chat_user_name_override_placeholder'),
            text: this.userNameOverrideDraft
          })
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_md'))
            .height(48)
            .padding({ left: 16, right: 16 })
            .width('100%')
            .onChange((value: string) => {
              this.userNameOverrideDraft = value;
            })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.app_text_secondary'))
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.showUserNameOverrideDialog = false;
              })
            Button($r('app.string.character_edit_save'))
              .fontSize(15)
              .backgroundColor($r('app.color.app_accent'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                this.saveUserNameOverride();
              })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('80%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showUserNameOverrideDialog = false;
    })
  }

  // ===== 辅助方法 =====

  private canSend(): boolean {
    // v8.1: 上下文超预算时禁止发送(必须先处理超限)
    if (this.isBudgetExceeded()) {
      return false;
    }
    return this.viewModel !== null && this.viewModel!.canSend;
  }

  /**
   * v8.1: 当前上下文是否超出输入预算。
   * 基于 budgetViewModel.stats 与 effectiveAvailable 计算。
   */
  private isBudgetExceeded(): boolean {
    if (this.budgetViewModel === null || this.budgetStats === null) {
      return false;
    }
    const available: number = this.budgetViewModel!.effectiveAvailable;
    if (available <= 0) {
      return true;
    }
    return this.budgetStats!.totalInputTokens > available;
  }

  /**
   * v8.1: 当前占用比例(0~1+,无 stats 时返回 0)。
   */
  private getBudgetUsageRatio(): number {
    if (this.budgetViewModel === null || this.budgetStats === null) {
      return 0;
    }
    const available: number = this.budgetViewModel!.effectiveAvailable;
    if (available <= 0) {
      return this.budgetStats!.totalInputTokens > 0 ? 1 : 0;
    }
    return this.budgetStats!.totalInputTokens / available;
  }

  /**
   * v8.1: 紧凑指示器文本,如 "12.4K / 32K · 39%"。
   */
  private getBudgetIndicatorText(): string {
    if (this.budgetViewModel === null || this.budgetStats === null) {
      return '';
    }
    const used: number = this.budgetStats!.totalInputTokens;
    const available: number = this.budgetViewModel!.effectiveAvailable;
    const ratio: number = this.getBudgetUsageRatio();
    const percent: number = Math.round(ratio * 100);
    return this.formatTokenCompact(used) + ' / ' + this.formatTokenCompact(available)
      + ' · ' + percent.toString() + '%';
  }

  /**
   * v8.2: 紧凑 Token 数值格式化。
   * - >= 1000000 显示为 M(保留 1 位小数,如 1M / 1.5M)
   * - >= 1000 显示为 K(保留 1 位小数,如 12.4K / 128K)
   * - 否则原样显示
   */
  private formatTokenCompact(value: number): string {
    if (value >= 1000000) {
      const m: number = value / 1000000;
      const s: string = m.toFixed(1);
      if (s.endsWith('.0')) {
        return s.substring(0, s.length - 2) + 'M';
      }
      return s + 'M';
    }
    if (value >= 1000) {
      const k: number = value / 1000;
      const s: string = k.toFixed(1);
      // 去除 .0 后缀
      if (s.endsWith('.0')) {
        return s.substring(0, s.length - 2) + 'K';
      }
      return s + 'K';
    }
    return value.toString();
  }

  /**
   * v8.1: 指示器颜色(按占用级别)。
   * - Normal(<70%):text_tertiary
   * - Warning(70~90%):app_accent
   * - High(>=90%):app_danger
   * - Exceeded(>100%):app_danger
   */
  private getBudgetIndicatorColor(): ResourceColor {
    if (this.budgetViewModel === null || this.budgetStats === null) {
      return $r('app.color.app_text_tertiary');
    }
    const ratio: number = this.getBudgetUsageRatio();
    if (ratio >= 0.9) {
      return $r('app.color.app_danger');
    }
    if (ratio >= 0.7) {
      return $r('app.color.app_accent');
    }
    return $r('app.color.app_text_tertiary');
  }

  /**
   * v8.1: 发送被预算阻止时,提示用户处理超限。
   */
  private notifyBudgetBlocked(): void {
    promptAction.showToast({
      message: '上下文已超出输入预算,请打开"上下文管理"减少历史或调整配置',
      duration: 2000
    });
  }

  private isInitialLoading(): boolean {
    return this.viewModel !== null && this.viewModel!.isInitializing;
  }

  private hasInitError(): boolean {
    return this.viewModel !== null && this.viewModel!.initError.length > 0;
  }

  /**
   * 是否显示"再试一次"悬浮按钮:
   * - ViewModel 就绪
   * - 可重新生成(canRegenerate)
   * - 当前未生成中(!isGenerating)
   * - 当前未忙碌(!busy)
   * - 消息列表非空
   */
  private showRetryFloating(): boolean {
    return this.viewModel !== null
      && this.viewModel!.canRegenerate
      && !this.viewModel!.isGenerating
      && !this.viewModel!.busy
      && this.messages.length > 0;
  }

  private getSwipeActiveIndex(messageId: string): number {
    if (this.viewModel === null) {
      return 0;
    }
    const s: MessageSwipeSummary | undefined = this.viewModel!.getSwipeSummary(messageId);
    return s !== undefined ? s.activeCandidateIndex : 0;
  }

  private getCandidateCount(messageId: string): number {
    if (this.viewModel === null) {
      return 1;
    }
    const s: MessageSwipeSummary | undefined = this.viewModel!.getSwipeSummary(messageId);
    return s !== undefined ? s.candidateCount : 1;
  }

  private autoScrollToBottom(): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel.userScrolledUp) {
      return;
    }
    const newCount: number = this.messages.length;
    if (newCount > this.lastMessageCount) {
      this.lastMessageCount = newCount;
      this.scroller.scrollEdge(Edge.Bottom);
    }
  }

  /**
   * 注册键盘高度变化监听。
   *
   * RESIZE 模式下,键盘弹起会压缩页面高度,但 Scroll 的滚动位置不会自动更新,
   * 导致最后一条消息被压缩后的输入区遮挡。这里在键盘弹起时主动滚动到底部。
   */
  private registerKeyboardListener(): void {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      window.getLastWindow(ctx)
        .then((win: window.Window): void => {
          this.mainWindow = win;
          this.keyboardHeightChangeHandler = (height: number): void => {
            Logger.info(LOG_TAG, 'keyboardHeightChange: height=' + height);
            if (height > 0 && this.viewModel !== null && !this.viewModel!.userScrolledUp) {
              // 键盘弹起,延迟一帧确保布局已更新,再滚动到底部
              setTimeout((): void => {
                try {
                  this.scroller.scrollEdge(Edge.Bottom);
                } catch (_e) {
                  // 忽略滚动异常
                }
              }, 80);
            }
          };
          win.on('keyboardHeightChange', this.keyboardHeightChangeHandler);
        })
        .catch((e: Error): void => {
          Logger.warn(LOG_TAG, 'getLastWindow failed: ' + e.message);
        });
    } catch (e) {
      Logger.warn(LOG_TAG, 'registerKeyboardListener failed: ' + (e as Error).message);
    }
  }

  private unregisterKeyboardListener(): void {
    if (this.mainWindow !== null && this.keyboardHeightChangeHandler !== null) {
      try {
        this.mainWindow.off('keyboardHeightChange', this.keyboardHeightChangeHandler);
      } catch (_e) {
        // 忽略注销异常
      }
      this.mainWindow = null;
      this.keyboardHeightChangeHandler = null;
    }
  }

  /** 加载角色头像(指定 characterId) */
  private loadCharacterAvatar(characterId: string): void {
    const characterService = AppServices.getCharacterService();
    characterService.getById(characterId)
      .then((c: Character | null): void => {
        this.character = c;
      })
      .catch((e: Error): void => {
        Logger.warn(LOG_TAG, 'loadCharacterAvatar failed: ' + e.message);
      });
  }

  /** 加载当前角色头像(无 characterId 时) */
  private loadCurrentCharacterAvatar(): void {
    const characterService = AppServices.getCharacterService();
    characterService.getCurrentCharacter()
      .then((c: Character | null): void => {
        this.character = c;
      })
      .catch((e: Error): void => {
        Logger.warn(LOG_TAG, 'loadCurrentCharacterAvatar failed: ' + e.message);
      });
  }

  private handleBack(): void {
    router.back();
  }

  private goToModelSettings(): void {
    router.pushUrl({ url: 'pages/ModelSettingsPage' });
  }

  private goToPresetList(): void {
    this.pendingRefreshPresetName = true;
    router.pushUrl({ url: 'pages/PromptPresetListPage' });
  }

  private navigateToBranchMap(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    this.pendingReloadAfterBranchChange = true;
    router.pushUrl({
      url: 'pages/BranchMapPage',
      params: { chatId: chatId }
    });
  }

  private navigateToChatBackgroundSettings(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    router.pushUrl({
      url: 'pages/ChatBackgroundSettingsPage',
      params: { chatId: chatId }
    });
  }

  private navigateToMemoryManagement(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    router.pushUrl({
      url: 'pages/MemoryManagementPage',
      params: { chatId: chatId }
    });
  }

  /**
   * v8.1: 刷新上下文占用统计。
   * 由 onMessagesUpdate / onBranchChangeSeqChanged / onBudgetConfigVersionChanged / onPageShow 调用。
   * 读取 chatService.getLastBuiltRequestMessages + getLastTokenBudget,
   * 通过 budgetViewModel 估算分段统计,并写入 SnapshotStore 供 ContextBudgetPage 读取。
   */
  private refreshBudgetSnapshot(): void {
    if (this.viewModel === null || this.budgetViewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    const budget = this.viewModel!.getLastTokenBudget();
    const requestMessages = this.viewModel!.getLastBuiltRequestMessages();
    // 写入 SnapshotStore(无论是否为空,都更新最新状态)
    const store = ContextBudgetSnapshotStore.getInstance();
    store.setSnapshot({
      chatId: chatId,
      budget: budget,
      requestMessages: requestMessages
    });
    // 异步刷新 VM 统计(避免阻塞 UI)
    this.budgetViewModel!.refreshFromSnapshot(budget, requestMessages).then((): void => {
      this.budgetStats = this.budgetViewModel!.stats;
    }).catch((e: Error): void => {
      Logger.warn(LOG_TAG, 'refreshBudgetSnapshot failed: ' + e.message);
    });
  }

  /**
   * v8.1: 上下文预算配置变更(由 ContextBudgetPage 触发)。
   * 重新加载 budget 配置后,基于已有 messages 重算占用统计。
   */
  onBudgetConfigVersionChanged(): void {
    if (this.budgetViewModel === null || this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    // 重新加载配置 + 重算 stats
    this.budgetViewModel!.initialize(chatId).then((): void => {
      this.refreshBudgetSnapshot();
    }).catch((e: Error): void => {
      Logger.warn(LOG_TAG, 'onBudgetConfigVersionChanged reload failed: ' + e.message);
    });
  }

  /**
   * v8.1: 导航到上下文管理页。
   */
  private navigateToContextBudget(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    // 离开前刷新一次快照,确保 ContextBudgetPage 读到最新数据
    this.refreshBudgetSnapshot();
    router.pushUrl({
      url: 'pages/ContextBudgetPage',
      params: { chatId: chatId }
    });
  }

  // ===== T-CHAT.1: 聊天归档导出 =====

  /**
   * T-CHAT.1: 导出当前聊天。
   * 从 ChatViewModel 获取当前 chatId 与角色信息,调用 ChatArchiveViewModel 执行导出。
   */
  private async exportCurrentChat(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.archiveBusy) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    this.archiveBusy = true;
    try {
      const vm: ChatArchiveViewModel = this.ensureArchiveViewModel();
      const title: string = this.viewModel!.characterName.length > 0
        ? this.viewModel!.characterName
        : '对话';
      const charName: string = this.character !== null ? this.character!.name : '';
      const ok: boolean = await vm.exportCurrentConversation({
        conversationId: chatId,
        conversationTitle: title,
        characterName: charName
      });
      if (ok && vm.lastExportStats !== null) {
        promptAction.showToast({
          message: '聊天导出成功: ' + String(vm.lastExportStats!.conversationCount)
            + ' 个对话, ' + String(vm.lastExportStats!.messageCount) + ' 条消息',
          duration: 2500
        });
      } else if (!ok && vm.errorMessage.length > 0) {
        promptAction.showToast({ message: vm.errorMessage, duration: 2500 });
      }
      vm.resetState();
    } finally {
      this.archiveBusy = false;
    }
  }

  /**
   * T-CHAT.1: 导出该角色全部聊天。
   */
  private async exportCharacterChats(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.archiveBusy) {
      return;
    }
    if (this.character === null || this.character!.id.length === 0) {
      promptAction.showToast({ message: '当前无角色,无法导出', duration: 1500 });
      return;
    }
    this.archiveBusy = true;
    try {
      const vm: ChatArchiveViewModel = this.ensureArchiveViewModel();
      const ok: boolean = await vm.exportCharacterConversations({
        characterId: this.character!.id,
        characterName: this.character!.name
      });
      if (ok && vm.lastExportStats !== null) {
        promptAction.showToast({
          message: '导出成功: ' + String(vm.lastExportStats!.conversationCount)
            + ' 个对话, ' + String(vm.lastExportStats!.messageCount) + ' 条消息',
          duration: 2500
        });
      } else if (!ok && vm.errorMessage.length > 0) {
        promptAction.showToast({ message: vm.errorMessage, duration: 2500 });
      }
      vm.resetState();
    } finally {
      this.archiveBusy = false;
    }
  }

  /**
   * 懒创建 ChatArchiveViewModel。
   */
  private ensureArchiveViewModel(): ChatArchiveViewModel {
    if (this.archiveViewModel === null) {
      this.archiveViewModel = AppServices.createChatArchiveViewModel();
    }
    return this.archiveViewModel!;
  }

  /**
   * 从指定消息创建独立对话。
   * 弹出自定义选择弹窗,让用户选择完整历史或仅记忆模式。
   */
  private forkChatFromMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    const branchId: string = this.viewModel!.activeBranchId;
    if (branchId.length === 0) {
      promptAction.showToast({ message: '当前无活动分支', duration: 1500 });
      return;
    }
    this.forkTargetMessageId = messageId;
    this.showForkModePicker = true;
  }

  @Builder
  forkModePickerDialog() {
    Stack() {
      Column() {
        Text('从此处创建独立对话')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ top: 20, bottom: 8 })

        Text('选择新会话的初始内容范围,新会话与原会话后续完全独立。')
          .fontSize(13)
          .fontColor($r('app.color.app_text_secondary'))
          .lineHeight(20)
          .margin({ left: 16, right: 16, bottom: 12 })

        Divider().color($r('app.color.app_divider'))

        // 携带完整历史
        Column() {
          Text('携带完整历史')
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ top: 12, bottom: 4 })
          Text('复制从根到当前消息的全部历史与记忆')
            .fontSize(12)
            .fontColor($r('app.color.app_text_tertiary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 8, bottom: 12 })
        .onClick(() => {
          this.showForkModePicker = false;
          void this.executeForkChat(this.forkTargetMessageId, true);
        })

        Divider().color($r('app.color.app_divider'))

        // 只携带记忆
        Column() {
          Text('只携带记忆')
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ top: 12, bottom: 4 })
          Text('不复制旧消息,仅继承记忆摘要 + 最近 2 条消息')
            .fontSize(12)
            .fontColor($r('app.color.app_text_tertiary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 8, bottom: 12 })
        .onClick(() => {
          this.showForkModePicker = false;
          void this.executeForkChat(this.forkTargetMessageId, false);
        })

        Divider().color($r('app.color.app_divider'))

        // 取消
        Text('取消')
          .fontSize(15)
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .onClick(() => {
            this.showForkModePicker = false;
          })
      }
      .width('80%')
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showForkModePicker = false;
    })
  }

  private async executeForkChat(
    forkMessageId: string,
    fullHistory: boolean
  ): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const sourceChatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (sourceChatId === undefined || sourceChatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    const sourceBranchId: string = this.viewModel!.activeBranchId;
    if (sourceBranchId.length === 0) {
      promptAction.showToast({ message: '当前无活动分支', duration: 1500 });
      return;
    }
    promptAction.showToast({ message: '正在创建独立对话...', duration: 1500 });
    try {
      const forkService = AppServices.getForkChatService();
      const result = fullHistory
        ? await forkService.forkChatWithFullHistory({
            mode: ForkChatMode.FullHistory,
            sourceChatId: sourceChatId,
            sourceBranchId: sourceBranchId,
            forkMessageId: forkMessageId
          })
        : await forkService.forkChatWithMemoryOnly({
            mode: ForkChatMode.MemoryOnly,
            sourceChatId: sourceChatId,
            sourceBranchId: sourceBranchId,
            keepRecentMessages: 2
          });
      const msg: string = '已创建新对话(复制 '
        + result.copiedMessageCount.toString() + ' 条消息, '
        + result.copiedMemoryCount.toString() + ' 条记忆)';
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (e) {
      Logger.error(LOG_TAG, 'executeForkChat failed: ' + String(e));
      promptAction.showToast({
        message: '创建失败: ' + (e instanceof Error ? e.message : String(e)),
        duration: 2500
      });
    }
  }

  /**
   * 会话首次就绪或切换时加载背景配置。
   * 通过 lastLoadedBgChatId 缓存避免 onMessagesUpdate 反复加载。
   */
  private maybeLoadChatBackground(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    if (chatId === this.lastLoadedBgChatId) {
      return;
    }
    this.lastLoadedBgChatId = chatId;
    this.loadChatBackground();
  }

  private loadChatBackground(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    const service = AppServices.getChatBackgroundService();
    if (service === null) {
      return;
    }
    service.getConfig(chatId)
      .then((cfg: ChatBackgroundConfig): void => {
        this.chatBgConfig = cfg;
      })
      .catch((e: Error): void => {
        Logger.warn(LOG_TAG, 'loadChatBackground failed: ' + e.message);
      });
  }

  /**
   * ChatBackgroundSettingsPage 保存配置后通过 AppStorage.setOrCreate 触发。
   */
  onChatBgConfigVersionChanged(): void {
    this.loadChatBackground();
  }

  private copyMessage(msg: ChatMessage): void {
    if (msg.content.length === 0 || msg.isStreaming === true) {
      return;
    }
    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(
        pasteboard.MIMETYPE_TEXT_PLAIN, msg.content
      );
      const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      systemPasteboard.setData(pasteData, (err: Error) => {
        if (err) {
          return;
        }
        promptAction.showToast({ message: $r('app.string.chat_copy_success'), duration: 1500 });
      });
    } catch (_e) {
      // 复制失败,静默处理
    }
  }

  /** 处理消息操作菜单点击 */
  private handleMessageAction(action: MessageAction): void {
    if (this.actionSheetMsg === null || this.viewModel === null) {
      return;
    }
    const msg: ChatMessage = this.actionSheetMsg!;
    switch (action) {
      case 'copy':
        this.copyMessage(msg);
        break;
      case 'edit':
        this.openEditUserDialog(msg.id, msg.content);
        break;
      case 'generate_from_user':
        this.generateFromUserMessage(msg.id);
        break;
      case 'regenerate_assistant':
        this.regenerateAssistantMessage(msg.id);
        break;
      case 'continue_from_here':
        this.continueFromAssistant(msg.id);
        break;
      case 'switch_branch':
        // 简化:直接 swipeNext,不弹二级菜单
        this.viewModel!.swipeNext(msg.id);
        break;
      case 'fork_chat':
        this.forkChatFromMessage(msg.id);
        break;
      default:
        break;
    }
    this.actionSheetMsg = null;
  }

  private continueFromAssistant(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    this.viewModel!.continueFromAssistant(messageId);
  }

  private generateFromUserMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    this.viewModel!.generateFromUserMessage(messageId);
  }

  private regenerateAssistantMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    this.viewModel!.regenerateAssistantMessage(messageId);
  }

  /**
   * 将气泡不透明度 clamp 到 [0.0, 1.0]。
   * 非有限值(NaN/Infinity)恢复为默认 0.65。
   * Slider 范围为 0~100%,允许完全透明到完全不透明。
   */
  private normalizeChatBubbleOpacity(value: number): number {
    if (!Number.isFinite(value)) {
      return 0.65;
    }
    if (value < 0.0) {
      return 0.0;
    }
    if (value > 1.0) {
      return 1.0;
    }
    return value;
  }

  /** 恢复默认气泡不透明度 */
  private resetChatBubbleOpacity(): void {
    this.chatBubbleOpacity = 0.65;
    this.persistBubbleOpacity(this.chatBubbleOpacity);
  }

  // ===== 字体配色主题 =====

  /**
   * 根据当前 chatTextColorMode 计算传入 ChatRichText 的颜色主题。
   * - AUTO:返回 null(使用默认资源颜色)
   * - LIGHT:返回预设浅色主题
   * - DARK:返回预设深色主题
   * - CUSTOM:使用用户选择的 4 个颜色值构造主题
   *
   * 返回 null 时,ChatRichText 保持原有解析与颜色行为,不做任何覆盖。
   */
  private getCurrentColorTheme(): ChatMarkdownColorTheme | null {
    if (this.chatTextColorMode === ChatTextColorMode.LIGHT) {
      return getLightColorTheme();
    }
    if (this.chatTextColorMode === ChatTextColorMode.DARK) {
      return getDarkColorTheme();
    }
    if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
      return getCustomColorTheme(
        this.chatAssistantTextColor,
        this.chatSecondaryTextColor,
        this.chatMarkdownAccentColor,
        this.chatUserTextColor
      );
    }
    // AUTO 或未知模式
    return null;
  }

  /**
   * 切换字体配色模式。
   * 不修改 chatBubbleOpacity,保持两者完全独立。
   */
  private setChatTextColorMode(mode: string): void {
    this.chatTextColorMode = mode;
  }

  /**
   * 设置自定义颜色项。
   * 仅在 CUSTOM 模式下生效,非法值不提交。
   * 自动转为大写,禁止 Alpha 与 CSS 函数。
   */
  private setCustomColor(target: 'body' | 'accent' | 'user' | 'secondary', color: string): void {
    const normalized: string | null = normalizeHexColor(color);
    if (normalized === null) {
      return;
    }
    if (target === 'body') {
      this.chatAssistantTextColor = normalized;
    } else if (target === 'accent') {
      this.chatMarkdownAccentColor = normalized;
    } else if (target === 'user') {
      this.chatUserTextColor = normalized;
    } else if (target === 'secondary') {
      this.chatSecondaryTextColor = normalized;
    }
  }

  /**
   * 恢复默认字体配色。
   * 模式恢复 AUTO,4 个颜色值恢复默认。
   * 不修改 chatBubbleOpacity。
   */
  private resetChatTextColor(): void {
    this.chatTextColorMode = ChatTextColorMode.AUTO;
    this.chatAssistantTextColor = DEFAULT_ASSISTANT_TEXT_COLOR;
    this.chatMarkdownAccentColor = DEFAULT_MARKDOWN_ACCENT_COLOR;
    this.chatUserTextColor = DEFAULT_USER_TEXT_COLOR;
    this.chatSecondaryTextColor = DEFAULT_SECONDARY_TEXT_COLOR;
  }

  /**
   * 全部恢复默认(气泡不透明度 + 字体配色)。
   */
  private resetAllAppearance(): void {
    this.resetChatBubbleOpacity();
    this.resetChatTextColor();
  }

  /** 判断字体配色是否处于默认状态(用于"恢复默认"按钮 enabled 状态) */
  private isChatTextColorDefault(): boolean {
    return this.chatTextColorMode === ChatTextColorMode.AUTO
      && this.chatAssistantTextColor === DEFAULT_ASSISTANT_TEXT_COLOR
      && this.chatMarkdownAccentColor === DEFAULT_MARKDOWN_ACCENT_COLOR
      && this.chatUserTextColor === DEFAULT_USER_TEXT_COLOR
      && this.chatSecondaryTextColor === DEFAULT_SECONDARY_TEXT_COLOR;
  }

  /** 获取模式按钮显示文本 */
  private getModeLabel(mode: string): string {
    if (mode === ChatTextColorMode.AUTO) {
      return '自动';
    }
    if (mode === ChatTextColorMode.LIGHT) {
      return '浅色';
    }
    if (mode === ChatTextColorMode.DARK) {
      return '深色';
    }
    return '自定义';
  }

  /**
   * 预设色块列表(白色/浅灰/深灰/黑色/品牌蓝/浅蓝/暖黄色)。
   * 用于自定义模式下的颜色选择,避免引入未经验证的 ColorPicker API。
   */
  private readonly presetSwatches: string[] = [
    '#FFFFFF', '#E5E7EB', '#4B5563', '#171717',
    '#1976D2', '#90CAF9', '#FFC107'
  ];

  /**
   * 重新生成按钮背景色:RGB 保持 surface_2 浅色/深色值,Alpha = chatBubbleOpacity。
   * light: #F0F1F4, dark: #3A3A3A
   */
  private computeRegenerateButtonColor(): string {
    const rgb: string = this.isDarkMode ? '3A3A3A' : 'F0F1F4';
    const clamped: number = Math.max(0, Math.min(255, Math.round(this.chatBubbleOpacity * 255)));
    const hex: string = clamped.toString(16).toUpperCase();
    const alphaHex: string = hex.length === 1 ? '0' + hex : hex;
    return '#' + alphaHex + rgb;
  }

  private openEditUserDialog(messageId: string, originalContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    this.editingMessageId = messageId;
    this.editDialogController = new CustomDialogController({
      builder: HistoricalMessageEditDialog({
        originalContent: originalContent,
        isSubmitting: false,
        onConfirm: (editedContent: string): void => {
          this.confirmEditUserMessage(messageId, editedContent);
        },
        onCancel: (): void => {}
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: false
    });
    this.editDialogController.open();
  }

  private confirmEditUserMessage(messageId: string, editedContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.editUserMessageAndGenerate(messageId, editedContent);
  }

  /**
   * BranchMapPage 切换 Active Branch 后触发。
   */
  onBranchChangeSeqChanged(): void {
    if (this.viewModel === null || this.viewModel!.isDisposed) {
      return;
    }
    if (!this.viewModel!.isSessionReady) {
      return;
    }
    this.viewModel!.reloadAfterBranchChange();
    // 分支切换后,上下文占用需重新统计
    this.refreshBudgetSnapshot();
  }
}
