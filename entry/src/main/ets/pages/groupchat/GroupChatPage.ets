/**
 * GroupChatPage 多人聊天主页面(G-DATA-1B / G-RUNTIME-1A / G-RUNTIME-1B)
 *
 * 数据来源:
 * - GroupConversationPersistenceService(真实数据库)
 * - GroupConversationMessageService(真实消息)
 * - GroupChatRuntimeService(严格顺序流式生成)
 *
 * 状态:
 * - Loading:加载中
 * - Ready:展示群聊标题、成员、真实消息列表、启用输入区
 * - NotFound:群聊不存在或已删除
 * - Error:加载失败
 *
 * 本轮状态(G-RUNTIME-1B):
 * - Idle:无活动轮次,输入可用
 * - Generating:本轮 N/M · 角色正在回复,输入禁用,显示停止按钮
 * - Completed:本轮完成 · M 位角色已回复,输入恢复
 * - Cancelled:本轮已停止 · N/M 位角色已完成,输入恢复
 * - Failed:角色回复失败,输入恢复
 *
 * 消息区域:
 * - 有消息:显示真实消息列表(用户右对齐,角色左对齐)
 * - Streaming 消息:实时显示当前角色生成内容
 * - Cancelled/Failed:保留部分正文并显示状态标记
 *
 * 输入区:
 * - 启用真实发送
 * - 发送期间禁用按钮(isSending)
 * - 生成期间禁用发送,显示停止按钮
 * - 失败时保留输入内容
 *
 * 不依赖:GroupChatPreviewStore / 预览种子数据。
 */

import { router, promptAction, mediaquery } from '@kit.ArkUI';
import { window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppServices } from '../../services/AppServices';
import { GroupChatViewModel } from '../../viewmodels/groupchat/GroupChatViewModel';
import {
  GroupConversationDetailUiModel,
  GroupMemberUiModel,
  GroupMessageUiModel,
  GroupChatDetailState,
  GroupMessageListState,
  GroupMemberRuntimeState,
  GroupMemberRuntimeUiModel,
  PENDING_GROUP_CHAT_ID_KEY,
  PENDING_GROUP_MEMORY_GROUP_ID_KEY,
  PENDING_GROUP_MEMORY_CHARACTER_ID_KEY
} from '../../viewmodels/groupchat/GroupChatUiModels';
import { GroupMessageRenderState } from '../../viewmodels/groupchat/GroupMessageRenderState';
import { GroupRoundState } from '../../services/groupchat/GroupRoundTypes';
import { CharacterImageView } from '../../components/CharacterImageView';
import { GroupMessageBubble } from '../../components/groupchat/GroupMessageBubble';
import { GroupGenerationErrorCard } from '../../components/groupchat/GroupGenerationErrorCard';
import { GroupAvatarStack, GroupAvatarStackItem } from '../../components/groupchat/GroupAvatarStack';
import { ChatRole } from '../../models/ChatRole';
import { ChatMessageStatus } from '../../models/ChatMessage';
import { ChatTextStyle } from '../../utils/ChatTextStyleSettings';
import {
  loadBubbleOpacity,
  persistBubbleOpacity,
  normalizeBubbleOpacity,
  DEFAULT_BUBBLE_OPACITY
} from '../../utils/ChatBubbleAppearance';
import { Logger } from '../../utils/Logger';

@Entry
@Component
struct GroupChatPage {
  /** 当前群聊 ID */
  @State chatId: string = '';
  /** 群聊详情(Ready 状态下非 null) */
  @State detail: GroupConversationDetailUiModel | null = null;
  /** 页面状态 */
  @State state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 消息列表 */
  @State messages: GroupMessageUiModel[] = [];
  /**
   * 稳定渲染状态列表(G-RUNTIME-1C-FIX)。
   * @Observed GroupMessageRenderState,ForEach 数据源,key 固定为 messageId。
   * 与单聊 ChatPage.messageStates 采用完全相同的模式:
   * - 同一 messageId 始终复用已有 RenderState 实例
   * - 已有实例就地调用 applyMessage,@Observed 字段赋值触发 @ObjectLink 响应式重建
   * - 新消息才创建新 RenderState
   */
  @State messageStates: GroupMessageRenderState[] = [];
  /** 消息列表状态 */
  @State messageState: GroupMessageListState = GroupMessageListState.Loading;
  /** 输入框文本 */
  @State inputText: string = '';
  /** 是否正在发送 */
  @State isSending: boolean = false;
  /** 错误提示 */
  @State errorMessage: string = '';
  /** 本轮状态 */
  @State roundState: GroupRoundState = GroupRoundState.Idle;
  /** 是否正在生成 */
  @State isGenerating: boolean = false;
  /** 是否正在停止 */
  @State isStopping: boolean = false;
  /** G-RUNTIME-1C: 是否正在重试 */
  @State isRetrying: boolean = false;
  /** G-RUNTIME-1C: 是否正在结束本轮 */
  @State isEndingRound: boolean = false;
  /** G-RUNTIME-1D: 是否有另一个群聊正在运行(跨群聊隔离提示) */
  @State isAnotherChatRunning: boolean = false;
  /** 本轮错误消息 */
  @State roundErrorMessage: string = '';
  /** 当前发言者索引 */
  @State currentSpeakerIndex: number = -1;
  /** 已完成发言者数 */
  @State completedSpeakerCount: number = 0;
  /** 总发言者数 */
  @State totalSpeakerCount: number = 0;
  /** 当前发言者角色 ID */
  @State currentSpeakerCharacterId: string = '';
  /** 成员运行时状态 */
  @State memberRuntimeStates: GroupMemberRuntimeUiModel[] = [];
  /** 更多菜单是否可见 */
  @State moreMenuVisible: boolean = false;
  /** G-MEMORY-1A: 角色记忆选择 Sheet 是否可见(更多菜单→角色记忆) */
  @State memoryPickerVisible: boolean = false;
  /** G-MEMORY-1A: 成员记忆数量映射(characterId → count),用于角色选择 Sheet */
  @State memberMemoryCounts: Map<string, number> = new Map();
  /** 重命名弹窗是否可见 */
  @State renameVisible: boolean = false;
  /** 重命名输入值 */
  @State renameInput: string = '';
  /** G-UI-ALIGN-3: 重命名保存中(防重复提交,失败保留输入) */
  @State renameSaving: boolean = false;
  /**
   * G-UI-ALIGN-3: 页面级错误提示可见性(顶部浮动,可关闭)。
   * 仅显示 errorMessage(页面操作错误),轮次级错误由 GroupGenerationErrorCard 处理。
   */
  @State errorBannerVisible: boolean = false;
  /** G-CONTROL-2A: 选中目标成员 UI 模型列表(空数组表示全员回复) */
  @State selectedReplyTargetMembers: GroupMemberUiModel[] = [];
  /** G-CONTROL-2A: @选择器是否可见 */
  @State isMentionPickerVisible: boolean = false;
  /** G-CONTROL-2A: @选择器候选成员 */
  @State mentionCandidates: GroupMemberUiModel[] = [];
  /** GROUP-CHAT-TARGET-1: 持续对话目标角色 ID(空表示无持续目标) */
  @State persistentReplyTargetCharacterId: string = '';
  /** GROUP-CHAT-TARGET-1: 持续目标角色名称(用于状态条显示) */
  @State persistentTargetName: string = '';
  /** GROUP-CHAT-TARGET-1: 持续目标角色头像 */
  @State persistentTargetAvatarUri: string = '';
  /** GROUP-CHAT-TARGET-1: 仅本次目标角色名称(用于 Chip 显示) */
  @State oneShotTargetName: string = '';
  /**
   * G-CONTROL-2A: 程序化设置输入文本时跳过 @检测的标志。
   * handleSelectMention 替换输入框文本后会触发 onChange,
   * 此时文本含 @角色名 会被 handleMentionDetection 误判为用户输入 @,
   * 重新打开选择器。此标志用于跳过该次 onChange 的检测。
   */
  private skipMentionDetectionOnNextChange: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  /**
   * 聊天文本样式设置(G-RUNTIME-1C-FIX)。
   * 复用单聊同一套 ChatTextStyleSettings,确保多人消息字体/行距/Markdown
   * 与单聊保持一致。从 AppServices.chatTextStyleSettings 加载。
   */
  @State chatTextStyle: ChatTextStyle | null = null;

  // ===== G-UI-ALIGN-2A: 气泡透明度 + 深色模式 + 显示设置面板 + 键盘高度 =====
  /**
   * G-UI-ALIGN-2A: 气泡背景不透明度(0.40~0.90,默认 0.65)。
   * 与单聊 ChatPage 共享同一份 Preferences key('chat_bubble_opacity'),
   * 用户在任一页面调节,两端均生效。
   */
  @State bubbleOpacity: number = DEFAULT_BUBBLE_OPACITY;
  /** G-UI-ALIGN-2A: 当前是否为深色模式(用于动态计算气泡背景 RGB) */
  @State isDarkMode: boolean = false;
  /** G-UI-ALIGN-2A: 显示设置面板可见性(轻量卡片,非 Dialog) */
  @State appearancePanelVisible: boolean = false;
  /**
   * G-UI-ALIGN-2A: 键盘高度(vp),0 表示键盘未弹起。
   * OFFSET 模式下用于消息列表底部占位与输入栏间距判断。
   */
  @State keyboardHeight: number = 0;

  // ===== G-UI-ALIGN-1: 成员栏动态展开/收起状态 =====
  /** 成员栏展示状态:Collapsed(收起头像堆叠)/ Expanded(展开横向列表) */
  @State memberStripDisplayState: MemberStripDisplayState = MemberStripDisplayState.Collapsed;
  /** 当前轮次内用户是否已主动收起(滚动或手动),本轮内不再自动展开 */
  @State memberStripCollapsedByUser: boolean = false;
  /** 上次观察到的轮次 ID(用于检测新轮次开始,允许重新展开) */
  @State lastObservedRoundId: string = '';

  // ===== G-UI-ALIGN-1: 用户滚动检测 =====
  /** 用户是否主动向上滚动离开底部 */
  @State userScrolledUp: boolean = false;
  /** 是否在底部(用于自动跟随新消息) */
  @State isAtBottom: boolean = true;
  /** 是否显示回到底部浮动按钮 */
  @State showScrollToBottom: boolean = false;
  /** 上次消息数量(用于判断新消息到达) */
  private lastMessageCount: number = 0;
  /** 是否已完成首次滚动到底部(避免 aboutToAppear 时组件未 build 导致 scrollEdge 无效) */
  private hasInitialScrolled: boolean = false;
  /** 延迟滚动定时器句柄(避免重复调度) */
  private scrollScheduleTimerId: number = -1;

  private viewModel: GroupChatViewModel | null = null;
  private messageScroller: Scroller = new Scroller();
  /** ViewModel 状态轮询定时器(G-RUNTIME-1B) */
  private syncTimerId: number = -1;
  /**
   * RenderState 缓存(G-RUNTIME-1C-FIX)。
   * key=messageId,value=GroupMessageRenderState 实例。
   * 与单聊 ChatPage.stateMap 采用相同模式,保证 ForEach 稳定复用气泡组件。
   */
  private stateMap: Map<string, GroupMessageRenderState> = new Map();
  /** G-UI-ALIGN-2A: 键盘高度变化监听句柄 */
  private keyboardHeightChangeHandler: ((height: number) => void) | null = null;
  /** G-UI-ALIGN-2A: 主窗口实例(用于注销监听) */
  private mainWindow: window.Window | null = null;
  /** G-UI-ALIGN-2A: 深色模式媒体查询监听器(aboutToDisappear 注销) */
  private darkModeListener: mediaquery.MediaQueryListener | null = null;

  async aboutToAppear(): Promise<void> {
    const id: string = AppStorage.get<string>(PENDING_GROUP_CHAT_ID_KEY) ?? '';
    if (id.length === 0) {
      promptAction.showToast({ message: '未找到群聊', duration: 1500 });
      router.back();
      return;
    }
    this.chatId = id;
    // 清除 pending,避免返回后误用
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, '');
    try {
      await AppServices.whenReady();
      // 加载聊天文本样式(复用单聊同一套 ChatTextStyleSettings)
      this.chatTextStyle = AppServices.getInstance().chatTextStyleSettings.get();
      // G-UI-ALIGN-2A: 加载气泡透明度(与单聊共享 Preferences key)
      const opacity: number = await loadBubbleOpacity();
      this.bubbleOpacity = opacity;
      // G-UI-ALIGN-2A: 注册深色模式监听 + 键盘高度监听
      this.registerDarkModeListener();
      this.registerKeyboardListener();
      this.viewModel = new GroupChatViewModel();
      // GROUP-CHAT-TARGET-1: 加载当前群聊的 @角色回复模式
      await this.viewModel.loadReplyTargetMode();
      // 设置消息更新回调(即时同步 RenderState,不依赖 200ms 轮询)
      this.viewModel.onMessagesUpdate = (msgs: GroupMessageUiModel[]): void => {
        this.messages = msgs;
        this.syncRenderStates(msgs);
        // 消息更新后,若用户未主动上滑则延迟滚动到底部(流式生成/新消息到达)
        if (this.hasInitialScrolled && !this.userScrolledUp) {
          this.scheduleScrollToBottom();
        }
      };
      await this.viewModel.load(id);
      this.syncFromViewModel();
      // 首次加载后延迟滚动到底部(aboutToAppear 时组件尚未 build,直接 scrollEdge 无效)
      this.scheduleScrollToBottom();
      this.hasInitialScrolled = true;
      // 启动状态轮询(生成期间持续同步 ViewModel 状态)
      this.startSyncPolling();
    } catch (e) {
      this.state = GroupChatDetailState.Error;
    }
  }

  /** 页面销毁时停止整轮并清理 */
  async aboutToDisappear(): Promise<void> {
    this.stopSyncPolling();
    // 清理延迟滚动定时器
    if (this.scrollScheduleTimerId !== -1) {
      clearTimeout(this.scrollScheduleTimerId);
      this.scrollScheduleTimerId = -1;
    }
    // G-UI-ALIGN-2A: 注销键盘监听 + 深色模式监听 + 关闭显示设置面板
    this.unregisterKeyboardListener();
    this.unregisterDarkModeListener();
    this.appearancePanelVisible = false;
    if (this.viewModel !== null) {
      await this.viewModel.disposeWithStop();
      this.viewModel = null;
    }
  }

  /** 页面重新显示时刷新(从设置/成员管理返回);生成中不重新加载 */
  async onPageShow(): Promise<void> {
    if (this.viewModel === null || this.chatId.length === 0) {
      return;
    }
    // GROUP-CHAT-TARGET-1: 刷新 @角色回复模式(用户可能在设置页修改)
    await this.viewModel.loadReplyTargetMode();
    // 刷新聊天文本样式(用户可能在设置页修改了显示偏好)
    this.chatTextStyle = AppServices.getInstance().chatTextStyleSettings.get();
    // G-UI-ALIGN-2A: 刷新气泡透明度(用户可能在单聊调节过,共享 Preferences)
    loadBubbleOpacity().then((opacity: number): void => {
      this.bubbleOpacity = opacity;
    });
    // 生成中不重新加载,避免破坏活动轮次状态
    if (this.viewModel.isGenerating) {
      return;
    }
    await this.viewModel.load(this.chatId);
    this.syncFromViewModel();
    // 重新加载后延迟滚动到底部(从设置页返回时恢复底部位置)
    this.scheduleScrollToBottom();
  }

  /**
   * G-UI-ALIGN-2A: 注册深色模式监听器,实时更新 isDarkMode 状态。
   * 用于动态计算气泡背景 RGB(light/dark 资源值不同)。
   */
  private registerDarkModeListener(): void {
    try {
      const listener = mediaquery.matchMediaSync('(dark-mode: true)');
      this.isDarkMode = listener.matches;
      this.darkModeListener = listener;
      listener.on('change', (result: mediaquery.MediaQueryResult): void => {
        this.isDarkMode = result.matches;
      });
    } catch (e) {
      Logger.warn('GroupChatPage', 'registerDarkModeListener failed: ' + (e as Error).message);
    }
  }

  /** G-UI-ALIGN-2A: 注销深色模式监听器 */
  private unregisterDarkModeListener(): void {
    if (this.darkModeListener !== null) {
      try {
        this.darkModeListener.off('change');
      } catch (_e) {
        // 忽略注销异常
      }
      this.darkModeListener = null;
    }
  }

  /**
   * G-UI-ALIGN-2A: 注册键盘高度变化监听器(对齐单聊 ChatPage.registerKeyboardListener)。
   *
   * EntryAbility 设为 OFFSET 上抬模式:键盘弹出时系统上抬未加 expandSafeArea(KEYBOARD) 的组件。
   * 本页面背景/顶栏/消息列表均加 expandSafeArea(KEYBOARD) 固定不动,
   * 仅输入栏被系统上抬到键盘上方。
   * keyboardHeight 用于消息列表底部 Blank 占位与输入栏间距判断。
   */
  private registerKeyboardListener(): void {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      window.getLastWindow(ctx)
        .then((win: window.Window): void => {
          this.mainWindow = win;
          this.keyboardHeightChangeHandler = (height: number): void => {
            // px → vp 换算(键盘高度回调单位为 px,输入栏 padding 单位为 vp)
            const densityPixels: number = display.getDefaultDisplaySync().densityPixels;
            const density: number = densityPixels > 0 ? densityPixels : 3.0;
            this.keyboardHeight = height > 0 ? height / density : 0;
            if (height > 0 && !this.userScrolledUp) {
              // 键盘弹起,延迟一帧确保布局已更新,再滚动到底部
              setTimeout((): void => {
                try {
                  this.messageScroller.scrollEdge(Edge.Bottom);
                } catch (_e) {
                  // 忽略滚动异常
                }
              }, 80);
            }
          };
          win.on('keyboardHeightChange', this.keyboardHeightChangeHandler);
        })
        .catch((e: Error): void => {
          Logger.warn('GroupChatPage', 'getLastWindow failed: ' + e.message);
        });
    } catch (e) {
      Logger.warn('GroupChatPage', 'registerKeyboardListener failed: ' + (e as Error).message);
    }
  }

  /** G-UI-ALIGN-2A: 注销键盘高度监听器 */
  private unregisterKeyboardListener(): void {
    if (this.mainWindow !== null && this.keyboardHeightChangeHandler !== null) {
      try {
        this.mainWindow.off('keyboardHeightChange', this.keyboardHeightChangeHandler);
      } catch (_e) {
        // 忽略注销异常
      }
      this.mainWindow = null;
      this.keyboardHeightChangeHandler = null;
      this.keyboardHeight = 0;
    }
  }

  /** 从 ViewModel 同步状态 */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.detail = this.viewModel.detail;
    this.state = this.viewModel.state;
    this.messages = this.viewModel.messages;
    // 同步稳定 RenderState 列表(与单聊 ChatPage.syncRenderStates 相同模式)
    this.syncRenderStates(this.viewModel.messages);
    this.messageState = this.viewModel.messageState;
    this.inputText = this.viewModel.inputText;
    this.isSending = this.viewModel.isSending;
    this.errorMessage = this.viewModel.errorMessage;
    // G-UI-ALIGN-3: errorMessage 非空时自动显示 errorBanner,用户可手动关闭
    if (this.errorMessage.length > 0) {
      this.errorBannerVisible = true;
    }
    this.roundState = this.viewModel.roundState;
    this.isGenerating = this.viewModel.isGenerating;
    this.isStopping = this.viewModel.isStopping;
    this.isRetrying = this.viewModel.isRetrying;
    this.isEndingRound = this.viewModel.isEndingRound;
    // G-RUNTIME-1D: 同步跨群聊运行状态(用于显示隔离提示)
    this.isAnotherChatRunning = this.viewModel.isAnotherChatRunning();
    this.roundErrorMessage = this.viewModel.roundErrorMessage;
    this.currentSpeakerIndex = this.viewModel.currentSpeakerIndex;
    this.completedSpeakerCount = this.viewModel.completedSpeakerCount;
    this.totalSpeakerCount = this.viewModel.totalSpeakerCount;
    this.currentSpeakerCharacterId = this.viewModel.currentSpeakerCharacterId;
    this.memberRuntimeStates = this.viewModel.memberRuntimeStates;
    // G-CONTROL-2A: 同步草稿回复目标状态(多目标)
    this.selectedReplyTargetMembers = [...this.viewModel.selectedReplyTargetMembers];
    this.isMentionPickerVisible = this.viewModel.isMentionPickerVisible;
    this.mentionCandidates = this.viewModel.mentionCandidates;
    // GROUP-CHAT-TARGET-1: 同步持续/临时目标状态
    this.persistentReplyTargetCharacterId = this.viewModel.persistentReplyTargetCharacterId;
    this.persistentTargetName = this.viewModel.findPersistentTargetMemberName();
    this.persistentTargetAvatarUri = this.viewModel.findPersistentTargetMemberAvatarUri();
    this.oneShotTargetName = this.viewModel.findOneShotTargetMemberName();
    // G-UI-ALIGN-1: 同步成员栏展开/收起状态
    this.updateMemberStripState();
  }

  /**
   * G-UI-ALIGN-1: 根据轮次状态更新成员栏展开/收起状态。
   *
   * 状态机规则:
   * 1. 检测轮次 ID 变化 → 新轮次开始 → 重置 memberStripCollapsedByUser
   * 2. Generating 且本轮内用户未收起 → Expanded
   * 3. 非 Generating(Idle/Completed/Cancelled/Failed) → Collapsed
   * 4. memberStripCollapsedByUser=true 时,即使 Generating 也保持 Collapsed
   *
   * 不使用定时器/轮询/消息数量变化判断轮次,仅依赖 ViewModel.currentRoundId。
   */
  private updateMemberStripState(): void {
    if (this.viewModel === null) {
      return;
    }
    const currentRoundId: string = this.viewModel.currentRoundId;
    // 检测新轮次开始:roundId 变化时重置用户收起标记
    if (currentRoundId.length > 0 && currentRoundId !== this.lastObservedRoundId) {
      this.lastObservedRoundId = currentRoundId;
      this.memberStripCollapsedByUser = false;
    }
    // 根据生成状态和用户收起标记决定展开/收起
    if (this.isGenerating && !this.memberStripCollapsedByUser) {
      if (this.memberStripDisplayState !== MemberStripDisplayState.Expanded) {
        this.memberStripDisplayState = MemberStripDisplayState.Expanded;
      }
    } else {
      if (this.memberStripDisplayState !== MemberStripDisplayState.Collapsed) {
        this.memberStripDisplayState = MemberStripDisplayState.Collapsed;
      }
    }
  }

  /**
   * G-UI-ALIGN-1: 用户主动滚动消息列表时收起成员栏。
   *
   * 一旦用户主动上滑浏览消息,本轮内不再自动展开。
   */
  private collapseMemberStripOnUserScroll(): void {
    if (this.memberStripCollapsedByUser) {
      return;
    }
    this.memberStripCollapsedByUser = true;
    if (this.memberStripDisplayState !== MemberStripDisplayState.Collapsed) {
      this.memberStripDisplayState = MemberStripDisplayState.Collapsed;
    }
  }

  /**
   * 同步最新消息到稳定 RenderState 列表(G-RUNTIME-1C-FIX)。
   *
   * 与单聊 ChatPage.syncRenderStates 采用完全相同的模式:
   * - 同一 messageId 始终复用已有 RenderState 实例,保证 ForEach 稳定复用气泡
   * - 已有实例就地调用 applyMessage,@Observed 字段赋值触发 @ObjectLink 响应式重建
   * - 新消息才创建新 RenderState
   * - 已不存在于最新消息中的旧状态从缓存中移除
   * - 始终按最新消息顺序生成新 messageStates 数组(不原地修改)
   *
   * 这是解决"消息正文不刷新、需退出重进"根因的关键:
   * ForEach 在固定 key(messageId)下复用 GroupMessageBubble 时,
   * 普通参数传递不触发重渲染;通过 @Observed + @ObjectLink,
   * applyMessage 的字段赋值直接触发气泡重建。
   */
  private syncRenderStates(messages: GroupMessageUiModel[]): void {
    const nextStates: GroupMessageRenderState[] = [];
    const newIds: Set<string> = new Set<string>();
    for (let i: number = 0; i < messages.length; i++) {
      const msg: GroupMessageUiModel = messages[i];
      newIds.add(msg.id);
      let state: GroupMessageRenderState | undefined = this.stateMap.get(msg.id);
      if (state === undefined) {
        state = new GroupMessageRenderState(msg);
        this.stateMap.set(msg.id, state);
      } else {
        state.applyMessage(msg);
      }
      nextStates.push(state);
    }
    // 清理已不在最新消息列表中的旧状态
    const oldIds: string[] = Array.from(this.stateMap.keys());
    for (let i: number = 0; i < oldIds.length; i++) {
      if (!newIds.has(oldIds[i])) {
        this.stateMap.delete(oldIds[i]);
      }
    }
    this.messageStates = nextStates;
  }

  /** 启动状态轮询(生成期间持续同步) */
  private startSyncPolling(): void {
    this.stopSyncPolling();
    this.syncTimerId = setInterval((): void => {
      if (this.viewModel === null) {
        this.stopSyncPolling();
        return;
      }
      this.syncFromViewModel();
      // 不在生成/重试/结束本轮中时停止轮询
      if (!this.viewModel.isGenerating && !this.viewModel.isSending
        && !this.viewModel.isRetrying && !this.viewModel.isEndingRound) {
        this.stopSyncPolling();
      }
    }, 200);
  }

  /** 停止状态轮询 */
  private stopSyncPolling(): void {
    if (this.syncTimerId !== -1) {
      clearInterval(this.syncTimerId);
      this.syncTimerId = -1;
    }
  }

  build(): void {
    Stack() {
      if (this.state === GroupChatDetailState.Loading) {
        this.loadingView()
      } else if (this.state === GroupChatDetailState.Error) {
        this.errorView()
      } else if (this.state === GroupChatDetailState.NotFound || this.detail === null) {
        this.notFoundView()
      } else {
        this.chatLayout()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  loadingView(): void {
    Column() {
      Text('加载中…')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_tertiary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(): void {
    Column() {
      Text('加载失败')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
      Button('重新加载')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .margin({ top: 16 })
        .onClick(() => {
          this.reloadCurrent();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  notFoundView(): void {
    Column() {
      Text('多人聊天不存在或已被删除')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .textAlign(TextAlign.Center)
        .width('80%')
      Button('返回多人聊天首页')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .margin({ top: 16 })
        .onClick(() => {
          router.replaceUrl({ url: 'pages/groupchat/GroupChatHomePage' });
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  private async reloadCurrent(): Promise<void> {
    if (this.viewModel === null || this.chatId.length === 0) {
      return;
    }
    await this.viewModel.load(this.chatId);
    this.syncFromViewModel();
  }

  /**
   * 主聊天布局(G-UI-ALIGN-2A: Stack 浮层结构,对齐单聊沉浸式安全区)。
   *
   * 层级(从底到顶):
   * 1. 消息列表层(Stack alignContent=BottomEnd,含消息列表 + 顶部擦除遮罩 + 回到底部按钮)
   *    expandSafeArea(KEYBOARD, BOTTOM) 固定不动
   * 2. 顶部渐变层(状态栏可读性,Transparent 不拦截点击)
   *    expandSafeArea(KEYBOARD, BOTTOM) 固定不动
   * 3. 顶部浮层 Column(顶栏 + 动态成员栏 + 轮次状态 + 跨群聊提示,Transparent)
   *    expandSafeArea(KEYBOARD, BOTTOM) 固定不动
   * 4. 输入栏浮层 Column(悬浮胶囊,End 对齐,不加 expandSafeArea(KEYBOARD) 让系统上抬)
   * 5. 弹窗层(moreMenu / rename / appearancePanel)
   *
   * 消息列表 padding top = statusBarHeight + 12,留出顶栏空间;
   * 消息列表底部 Blank 占位 = 80 + navBarHeight + keyboardHeight,避让悬浮输入栏。
   */
  @Builder
  chatLayout(): void {
    Stack() {
      // ===== 1. 消息列表层(含顶部擦除遮罩 + 回到底部按钮)=====
      Column() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          if (this.messageState === GroupMessageListState.Loading) {
            this.messageLoadingView()
          } else if (this.messageStates.length === 0) {
            this.groupEmptyStateView()
          } else {
            this.messageList()
          }

          // 顶部擦除遮罩:DST_IN alpha 渐变,让消息从顶部淡出
          Column()
            .width('100%')
            .height('8%')
            .linearGradient({
              angle: 180,
              colors: [
                ['#00000000', 0.0],
                ['#00000000', 0.5],
                ['#FF000000', 0.9],
                ['#FF000000', 1.0]
              ]
            })
            .hitTestBehavior(HitTestMode.Transparent)
            .blendMode(BlendMode.DST_IN)
            .position({ x: 0, y: 0 })

          // 回到底部浮动按钮(用户上滑离开底部时显示)
          // bottom margin 动态:输入栏高度(56) + 间距(12) + 键盘高度(0 或已上抬)
          if (this.showScrollToBottom && this.messageStates.length > 0) {
            Button({ type: ButtonType.Circle, stateEffect: false }) {
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(20)
                .fontColor([$r('app.color.app_text_primary')])
            }
            .backgroundColor($r('app.color.app_surface_1'))
            .borderRadius(22)
            .width(44)
            .height(44)
            .margin({ bottom: this.keyboardHeight > 0 ? 68 : 68 + this.navBarHeight, right: 12 })
            .shadow({ radius: 8, color: 'rgba(0,0,0,0.15)' })
            .accessibilityText('回到最新消息')
            .onClick(() => {
              this.scrollToBottom(true);
            })
          }
        }
        .layoutWeight(1)
        .width('100%')
        .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])

      // ===== 2. 顶部渐变层(状态栏可读性)=====
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
      .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])

      // ===== 3. 顶部浮层(顶栏 + 错误条 + 动态成员栏 + 轮次状态 + 跨群聊提示)=====
      Column() {
        this.topBar()
        this.errorBanner()
        this.dynamicMemberStripArea()
        this.roundStatusBar()
        this.crossChatBanner()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .hitTestBehavior(HitTestMode.Transparent)
      .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])

      // ===== 4. 输入栏浮层(悬浮胶囊,End 对齐,不加 KEYBOARD 让系统上抬)=====
      Column() {
        this.inputBarArea()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)

      // ===== 5. 弹窗层 =====
      if (this.moreMenuVisible) {
        this.moreMenuDialog()
      }
      if (this.renameVisible) {
        this.renameDialog()
      }
      if (this.appearancePanelVisible) {
        this.chatAppearancePanel()
      }
      // G-MEMORY-1A: 角色记忆选择 Sheet
      if (this.memoryPickerVisible) {
        this.memoryPickerDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * G-UI-ALIGN-3: 页面级错误提示(顶部浮动,可关闭)。
   *
   * - 仅显示 errorMessage(页面操作错误:发送失败/停止失败/回复目标错误等)
   * - 轮次级错误由 GroupGenerationErrorCard 处理,不在此显示
   * - 半透明 surface 背景 + app_danger 文本 + 关闭按钮
   * - 不遮挡 topBar(在 topBar 下方),不拦截消息滚动(HitTestMode.Default)
   * - 不输出内部 ID / SQL / Prompt / 堆栈
   */
  @Builder
  errorBanner(): void {
    if (this.errorBannerVisible && this.errorMessage.length > 0) {
      Row() {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(14)
          .fontColor([$r('app.color.app_danger')])
        Text(this.errorMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 6 })
        Button({ type: ButtonType.Circle, stateEffect: false }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(12)
            .fontColor([$r('app.color.app_text_tertiary')])
        }
        .width(24)
        .height(24)
        .backgroundColor(Color.Transparent)
        .accessibilityText('关闭错误提示')
        .onClick(() => {
          this.errorBannerVisible = false;
        })
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 6, bottom: 6 })
      .margin({ left: 12, right: 12, top: 4 })
      .backgroundColor($r('app.color.chat_status_failed_bg'))
      .borderRadius($r('app.float.app_radius_sm'))
      .alignItems(VerticalAlign.Center)
    }
  }

  /**
   * G-UI-ALIGN-3: 跨群聊运行隔离提示(紧凑样式)。
   *
   * 当另一个群聊正在生成时,当前页面显示紧凑提示:
   * - 不显示 A 的停止按钮(本页 isGenerating=false,停止按钮不会出现)
   * - 不允许发送新一轮(输入区禁用)
   * - 紧凑提示条:surface_2 背景 + app_text_secondary 文字 + 图标
   * - 不再占据大色块横幅,与 errorBanner 视觉层级一致
   * - 状态解除后立即消失(isAnotherChatRunning 由 ViewModel 同步)
   */
  @Builder
  crossChatBanner(): void {
    if (this.isAnotherChatRunning) {
      Row() {
        SymbolGlyph($r('sys.symbol.lock'))
          .fontSize(12)
          .fontColor([$r('app.color.app_text_secondary')])
        Text('另一个群聊正在回复,当前输入暂不可用')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 6 })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .margin({ left: 12, right: 12, top: 4 })
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .alignItems(VerticalAlign.Center)
    }
  }

  /**
   * G-UI-ALIGN-2A: 本轮状态栏(弱化,对齐单聊轻量提示)。
   *
   * - 仅显示状态文本,无大色块背景(透明,透出页面背景)
   * - Generating/Completed/Cancelled/Failed 显示,Idle 隐藏
   * - G-UI-ALIGN-2A: 停止按钮已移至悬浮输入栏,状态栏不再保留停止入口
   */
  @Builder
  roundStatusBar(): void {
    if (this.roundState === GroupRoundState.Idle) {
      // Idle 不显示
    } else {
      Row() {
        Text(this.composeRoundStatusText())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 构建本轮状态文案 */
  private composeRoundStatusText(): string {
    const current: number = this.currentSpeakerIndex >= 0
      ? this.currentSpeakerIndex + 1 : 0;
    const total: number = this.totalSpeakerCount;
    const currentName: string = this.findMemberName(this.currentSpeakerCharacterId);

    if (this.roundState === GroupRoundState.Generating) {
      if (currentName.length > 0) {
        return '本轮 ' + String(current) + '/' + String(total) + ' · ' + currentName + '正在回复';
      }
      return '本轮 ' + String(current) + '/' + String(total) + ' · 正在回复';
    }
    if (this.roundState === GroupRoundState.Completed) {
      return '本轮完成 · ' + String(total) + ' 位角色已回复';
    }
    if (this.roundState === GroupRoundState.Cancelled) {
      return '本轮已停止 · ' + String(this.completedSpeakerCount) + '/' + String(total) + ' 位角色已完成';
    }
    if (this.roundState === GroupRoundState.Failed) {
      if (currentName.length > 0) {
        return currentName + '回复失败';
      }
      return '本轮失败';
    }
    return '';
  }

  /** 根据 characterId 查找成员名称 */
  private findMemberName(characterId: string): string {
    if (characterId.length === 0 || this.detail === null) {
      return '';
    }
    for (let i = 0; i < this.detail.members.length; i++) {
      if (this.detail.members[i].characterId === characterId) {
        return this.detail.members[i].name;
      }
    }
    return '';
  }

  /**
   * G-UI-ALIGN-1: 顶部栏(对齐单聊 topBar 样式)。
   *
   * - 返回按钮:40x40 Stack 纯图标,无背景
   * - 群名:保留,subtitle 字号,maxLines=1,Ellipsis
   * - 副标题(成员数):弱化,仅在 Expanded 成员栏未显示时短暂可见(本阶段默认不显示)
   * - 更多按钮:40x40 Stack 纯图标,无背景
   * - 顶部 padding = statusBarHeight + 4(对齐单聊)
   */
  @Builder
  topBar(): void {
    Row() {
      // 返回按钮(40x40,对齐单聊)
      Stack() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .width(40)
      .height(40)
      .accessibilityText('返回群聊列表')
      .onClick(() => {
        router.back();
      })

      // 群名(保留,弱化副标题)
      Text(this.detail!.title)
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 4, right: 4 })

      // G-UI-ALIGN-2A: 显示设置按钮(打开气泡透明度面板,对齐单聊 textformat 图标)
      Stack() {
        SymbolGlyph($r('sys.symbol.textformat'))
          .fontSize(20)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .width(40)
      .height(40)
      .margin({ right: 4 })
      .borderRadius($r('app.float.app_radius_sm'))
      .backgroundColor(this.appearancePanelVisible
        ? $r('app.color.app_surface_2') : Color.Transparent)
      .accessibilityText('打开显示设置')
      .onClick(() => {
        this.appearancePanelVisible = !this.appearancePanelVisible;
      })

      // 更多按钮(40x40,对齐单聊)
      Stack() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(22)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .width(40)
      .height(40)
      .accessibilityText('打开更多操作')
      .onClick(() => {
        this.moreMenuVisible = true;
      })
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: this.statusBarHeight + 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  /** 构建成员副标题 */
  private composeMemberSubtitle(): string {
    const members: GroupMemberUiModel[] = this.detail !== null ? this.detail.members : [];
    const enabled: number = members.filter((m: GroupMemberUiModel): boolean => m.isEnabled).length;
    return String(members.length) + ' 位成员 · ' + String(enabled) + ' 位启用';
  }

  /**
   * G-UI-ALIGN-1: 动态成员栏(Collapsed / Expanded)。
   *
   * - Collapsed:头像堆叠(GroupAvatarStack),点击打开成员管理,占用最小高度
   * - Expanded:横向成员列表(56vp 高),显示头像+名称+运行状态,点击切换回复目标
   *
   * 状态切换由 updateMemberStripState / collapseMemberStripOnUserScroll 控制。
   */
  @Builder
  dynamicMemberStripArea(): void {
    if (this.memberStripDisplayState === MemberStripDisplayState.Expanded) {
      this.memberStripExpanded()
    } else {
      this.memberStripCollapsed()
    }
  }

  /** 收起状态:头像堆叠 + 成员数 */
  @Builder
  memberStripCollapsed(): void {
    Row() {
      // 头像堆叠(前 3 个有效成员)
      GroupAvatarStack({
        items: this.buildAvatarStackItems(),
        avatarSize: 28
      })
      .accessibilityText('展开成员状态')

      // 成员数量文字
      Text(this.composeMemberCountText())
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .maxLines(1)
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      // 收起状态点击:展开成员栏(不直接切换回复目标,避免误触)
      if (this.isGenerating) {
        // 生成中展开显示运行状态
        this.memberStripDisplayState = MemberStripDisplayState.Expanded;
      } else {
        // 非生成中点击头像堆叠:打开成员管理页
        this.goManageMembers();
      }
    })
  }

  /**
   * G-UI-ALIGN-2A: 展开状态:横向成员列表(纵向项布局:头像→名称→状态)。
   *
   * 每个成员项为 Column:
   * - 头像(36×36,带轻量状态徽标)
   * - 角色名称(caption,48 宽,省略)
   * - 回复状态文字(caption,在名称下方,不在头像右侧)
   *
   * 总高度 68vp(对齐任务要求 56~68vp 范围,容纳纵向三行)。
   */
  @Builder
  memberStripExpanded(): void {
    Scroll() {
      Row() {
        if (this.isGenerating && this.memberRuntimeStates.length > 0) {
          ForEach(this.memberRuntimeStates, (member: GroupMemberRuntimeUiModel) => {
            Column() {
              // 头像(带轻量状态徽标)
              Stack() {
                CharacterImageView({
                  imageUri: member.avatarUri,
                  fallbackName: member.name,
                  imgWidth: 36,
                  imgHeight: 36,
                  imgBorderRadius: 18,
                  displayMode: 'thumbnail',
                  objectFit: ImageFit.Cover
                })
                // 轻量状态徽标(仅 Generating 显示 LoadingProgress,避免噪声)
                if (member.runtimeState === GroupMemberRuntimeState.Generating) {
                  LoadingProgress()
                    .width(12)
                    .height(12)
                    .color($r('app.color.app_accent'))
                    .position({ x: 24, y: -2 })
                }
              }
              .width(36)
              .height(36)

              // 角色名称(头像下方)
              Text(member.name)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(this.memberRuntimeTextColor(member.runtimeState))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(48)
                .textAlign(TextAlign.Center)
                .margin({ top: 2 })

              // G-UI-ALIGN-2A: 回复状态文字(名称下方,不在头像右侧)
              Text(this.memberRuntimeStateText(member.runtimeState))
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(this.memberRuntimeTextColor(member.runtimeState))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(48)
                .textAlign(TextAlign.Center)
                .margin({ top: 1 })
                .opacity(this.memberRuntimeOpacity(member.runtimeState))
            }
            .margin({ left: 6, right: 6 })
            .alignItems(HorizontalAlign.Center)
            .accessibilityText(this.composeMemberAccessibility(member.name, member.runtimeState))
          }, (member: GroupMemberRuntimeUiModel) => member.characterId)
        } else {
          ForEach(this.detail!.members, (member: GroupMemberUiModel) => {
            Column() {
              // 头像(带缺失/目标徽标)
              Stack() {
                CharacterImageView({
                  imageUri: member.avatarUri,
                  fallbackName: member.name,
                  imgWidth: 36,
                  imgHeight: 36,
                  imgBorderRadius: 18,
                  displayMode: 'thumbnail',
                  objectFit: ImageFit.Cover
                })
                if (!member.characterExists) {
                  Text('!')
                    .fontSize(10)
                    .fontColor($r('app.color.app_on_accent'))
                    .backgroundColor($r('app.color.app_danger'))
                    .borderRadius(6)
                    .width(12)
                    .height(12)
                    .textAlign(TextAlign.Center)
                    .position({ x: 24, y: -2 })
                } else if (this.isMemberReplyTarget(member.characterId)) {
                  Text('◎')
                    .fontSize(12)
                    .fontColor($r('app.color.app_on_accent'))
                    .backgroundColor($r('app.color.app_accent'))
                    .borderRadius(6)
                    .width(12)
                    .height(12)
                    .textAlign(TextAlign.Center)
                    .position({ x: 24, y: -2 })
                }
              }
              .width(36)
              .height(36)

              // 角色名称(头像下方)
              Text(member.name)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(this.memberTextColor(member))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(48)
                .textAlign(TextAlign.Center)
                .margin({ top: 2 })
                .opacity(this.memberOpacity(member))

              // G-UI-ALIGN-2A: 状态文字(名称下方)
              Text(member.isEnabled ? '就绪' : '未启用')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
                .maxLines(1)
                .width(48)
                .textAlign(TextAlign.Center)
                .margin({ top: 1 })
            }
            .margin({ left: 6, right: 6 })
            .alignItems(HorizontalAlign.Center)
            .opacity(member.isEnabled && member.characterExists ? 1 : 0.6)
            .accessibilityText(this.composeMemberAccessibility(member.name,
              member.isEnabled ? GroupMemberRuntimeState.Idle : GroupMemberRuntimeState.NotParticipating))
            .onClick(() => {
              this.handleMemberClick(member);
            })
            .gesture(
              LongPressGesture({ repeat: false, duration: 500 })
                .onAction(() => {
                  // G-MEMORY-1A: 长按成员头像 → 进入该角色记忆页
                  this.goCharacterMemory(member.characterId);
                })
            )
          }, (member: GroupMemberUiModel) => member.characterId + '|' + String(member.speakerOrder) + '|' + String(member.isEnabled) + '|' + (this.isMemberReplyTarget(member.characterId) ? '1' : '0'))
        }
      }
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    }
    .width('100%')
    .height(68)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 构建头像堆叠项(前 3 个有效成员) */
  private buildAvatarStackItems(): GroupAvatarStackItem[] {
    if (this.detail === null) {
      return [];
    }
    const items: GroupAvatarStackItem[] = [];
    for (let i = 0; i < this.detail.members.length && items.length < 3; i++) {
      const m: GroupMemberUiModel = this.detail.members[i];
      if (!m.characterExists) {
        continue;
      }
      items.push({ name: m.name, avatarUri: m.avatarUri });
    }
    return items;
  }

  /** 构建成员数量文字 */
  private composeMemberCountText(): string {
    if (this.detail === null) {
      return '';
    }
    const total: number = this.detail.members.length;
    const enabled: number = this.detail.members.filter((m: GroupMemberUiModel): boolean => m.isEnabled).length;
    return String(enabled) + ' 位成员';
  }

  /** 构建成员无障碍描述 */
  private composeMemberAccessibility(name: string, state: GroupMemberRuntimeState): string {
    const stateText: string = this.memberRuntimeStateText(state);
    return stateText.length > 0 ? name + ' · ' + stateText : name;
  }

  /** 成员运行时状态文字描述(用于无障碍) */
  private memberRuntimeStateText(state: GroupMemberRuntimeState): string {
    if (state === GroupMemberRuntimeState.Generating) {
      return '正在回复';
    }
    if (state === GroupMemberRuntimeState.Completed) {
      return '已完成';
    }
    if (state === GroupMemberRuntimeState.Waiting) {
      return '等待中';
    }
    if (state === GroupMemberRuntimeState.Failed) {
      return '回复失败';
    }
    if (state === GroupMemberRuntimeState.Cancelled) {
      return '已停止';
    }
    if (state === GroupMemberRuntimeState.NotParticipating) {
      return '本轮未参与';
    }
    return '';
  }

  /** 成员运行时状态文字颜色 */
  private memberRuntimeTextColor(state: GroupMemberRuntimeState): ResourceColor {
    if (state === GroupMemberRuntimeState.Generating) {
      return $r('app.color.app_accent');
    }
    if (state === GroupMemberRuntimeState.Completed) {
      return $r('app.color.app_text_primary');
    }
    return $r('app.color.app_text_tertiary');
  }

  /** 成员运行时状态透明度 */
  private memberRuntimeOpacity(state: GroupMemberRuntimeState): number {
    if (state === GroupMemberRuntimeState.Waiting) {
      return 0.5;
    }
    if (state === GroupMemberRuntimeState.Idle) {
      return 0.4;
    }
    // G-CONTROL-2A: 有限成员轮次中未选中的启用成员,半透明显示
    if (state === GroupMemberRuntimeState.NotParticipating) {
      return 0.4;
    }
    return 1;
  }

  // ===== G-CONTROL-2A 成员栏点击与目标选择 =====

  /** G-CONTROL-2A: 判断成员是否为当前回复目标(多选,检查数组) */
  private isMemberReplyTarget(characterId: string): boolean {
    for (let i = 0; i < this.selectedReplyTargetMembers.length; i++) {
      if (this.selectedReplyTargetMembers[i].characterId === characterId) {
        return true;
      }
    }
    return false;
  }

  /** G-CONTROL-1: 成员栏文字颜色(非生成态) */
  private memberTextColor(member: GroupMemberUiModel): ResourceColor {
    if (this.isMemberReplyTarget(member.characterId)) {
      return $r('app.color.app_accent');
    }
    if (!member.isEnabled) {
      return $r('app.color.app_text_tertiary');
    }
    return $r('app.color.app_text_primary');
  }

  /** G-CONTROL-1: 成员栏透明度(非生成态) */
  private memberOpacity(member: GroupMemberUiModel): number {
    if (!member.isEnabled || !member.characterExists) {
      return 0.5;
    }
    return 1;
  }

  /**
   * G-CONTROL-2A: 构建输入栏目标 Chip 文案。
   *
   * 规则:
   * - 1 个目标:仅{name}回复
   * - 2+ 个目标:指定 N 位角色回复
   * - 空数组:返回空(不会进入此分支,全员显示提示文案)
   */
  private composeTargetChipText(): string {
    const members: GroupMemberUiModel[] = this.selectedReplyTargetMembers;
    if (members.length === 0) {
      return '';
    }
    if (members.length === 1) {
      return '仅' + members[0].name + '回复';
    }
    return '指定 ' + String(members.length) + ' 位角色回复';
  }

  /** G-CONTROL-1: 处理成员栏点击 → GROUP-CHAT-TARGET-1: 按设置模式直接生效 */
  private handleMemberClick(member: GroupMemberUiModel): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.isGenerating || this.isSending) {
      return;
    }
    // 按群聊设置中的模式直接生效，先清除旧草稿防止残留
    if (this.viewModel.replyTargetMode === 'persistent') {
      this.viewModel.clearReplyTarget();
      const ok: boolean = this.viewModel.setPersistentReplyTarget(member.characterId);
      if (!ok) {
        promptAction.showToast({ message: this.viewModel.errorMessage, duration: 1500 });
      }
      this.syncFromViewModel();
      return;
    }
    // one_shot 模式:仅本次
    this.viewModel.clearReplyTarget();
    const ok: boolean = this.viewModel.setOneShotReplyTarget(member.characterId);
    if (!ok) {
      promptAction.showToast({ message: this.viewModel.errorMessage, duration: 1500 });
    }
    this.syncFromViewModel();
  }

  /** 消息加载中视图 */
  @Builder
  messageLoadingView(): void {
    Column() {
      Text('加载消息…')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_tertiary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * G-UI-ALIGN-1: 多人空状态(对齐单聊空状态视觉,保留多人语义)。
   *
   * 显示:GroupAvatarStack + 群名 + 成员数 + 开始发送消息提示
   */
  @Builder
  groupEmptyStateView(): void {
    Column() {
      // 头像堆叠(模拟单聊角色头像)
      GroupAvatarStack({
        items: this.buildAvatarStackItems(),
        avatarSize: 64
      })
      .margin({ bottom: $r('app.float.app_spacing_12') })

      // 群名
      Text(this.detail !== null ? this.detail.title : '')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ top: $r('app.float.app_spacing_12') })

      // 成员数 + 提示
      Text(this.composeMemberCountText())
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ top: $r('app.float.app_spacing_8') })

      Text('发送消息开始多人对话')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: $r('app.float.app_spacing_4') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * G-UI-ALIGN-1: 消息列表(对齐单聊滚动逻辑)。
   *
   * - padding top = statusBarHeight + 12,留出顶栏空间
   * - 底部 Blank 占位 = 80 + navBarHeight,避让悬浮输入栏
   * - onScrollIndex:检测用户上滑,收起成员栏 + 显示回到底部按钮
   * - onScrollEdge:到底部时恢复自动跟随
   * - onAreaChange:新消息到达时,若用户在底部则自动滚动
   */
  @Builder
  messageList(): void {
    List({ scroller: this.messageScroller }) {
      ForEach(this.messageStates, (state: GroupMessageRenderState) => {
        ListItem() {
          Column() {
            // 复用单聊同款 ChatRichText 渲染,@ObjectLink 响应式刷新
            // G-UI-ALIGN-2A: 传递 bubbleOpacity/isDarkMode,支持气泡透明度动态调节
            GroupMessageBubble({
              renderState: state,
              settings: this.chatTextStyle,
              bubbleOpacity: this.bubbleOpacity,
              isDarkMode: this.isDarkMode
            })
            // G-RUNTIME-1C-FIX: 最近一条 Failed/Cancelled 角色消息下方显示重试/结束本轮卡片
            if (this.shouldShowErrorCard(state)) {
              GroupGenerationErrorCard({
                errorText: this.composeErrorCardText(state),
                isRetrying: this.isRetrying,
                isEndingRound: this.isEndingRound,
                onRetry: () => {
                  this.handleRetrySpeaker(state);
                },
                onEndRound: () => {
                  this.handleEndRound();
                }
              })
                .margin({ top: 6 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .margin({ left: $r('app.float.app_spacing_12'), right: $r('app.float.app_spacing_12'), top: 6, bottom: 6 })
      }, (state: GroupMessageRenderState) => state.messageId)

      // 底部空白占位 ListItem:高度等于悬浮输入栏占用空间,让 scrollEdge(Bottom) 时最后一条消息显示在输入栏上方
      // G-UI-ALIGN-2A: 键盘弹起时占位 = 80 + keyboardHeight(输入栏被上抬到键盘上方,消息列表延伸到键盘下方需避让)
      // 键盘未弹起时占位 = 80 + navBarHeight(避让系统手势条 + 悬浮输入栏)
      ListItem() {
        Column()
          .width('100%')
          .height(this.keyboardHeight > 0 ? 80 + this.keyboardHeight : 80 + this.navBarHeight)
      }
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 0,
      right: 0,
      top: this.statusBarHeight + 12,
      bottom: 0
    })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .onScrollIndex((start: number, end: number, center: number) => {
      // 滚动位置变化:检测是否离开底部
      this.handleScrollPositionChange(start, end, center);
    })
    .onScroll((xOffset: number, yOffset: number) => {
      // 滚动时检测是否到达底部
      if (this.messageScroller.isAtEnd()) {
        this.isAtBottom = true;
        this.userScrolledUp = false;
        this.showScrollToBottom = false;
      }
    })
    .onAreaChange(() => {
      // 消息列表变化后,若用户在底部则自动滚动
      this.autoScrollToBottom();
    })
  }

  /**
   * G-UI-ALIGN-1: 处理滚动位置变化。
   *
   * - 用户主动上滑离开底部 → 收起成员栏 + 显示回到底部按钮
   * - 到达底部 → 恢复自动跟随
   */
  private handleScrollPositionChange(start: number, end: number, center: number): void {
    // 通过 Scroller 判断是否在底部
    const atEnd: boolean = this.messageScroller.isAtEnd();
    if (!atEnd && this.isAtBottom) {
      // 离开底部:用户主动上滑
      this.isAtBottom = false;
      this.userScrolledUp = true;
      this.showScrollToBottom = true;
      // 收起成员栏(本轮内不再自动展开)
      this.collapseMemberStripOnUserScroll();
    }
  }

  /**
   * G-UI-ALIGN-1: 自动滚动到底部(仅在用户未主动上滑时)。
   *
   * - 用户在底部:新消息到达自动滚动
   * - 用户主动上滑:不抢夺阅读位置
   */
  private autoScrollToBottom(): void {
    if (this.userScrolledUp) {
      return;
    }
    const newCount: number = this.messageStates.length;
    if (newCount > this.lastMessageCount) {
      this.lastMessageCount = newCount;
      this.messageScroller.scrollEdge(Edge.Bottom);
    }
  }

  /**
   * G-UI-ALIGN-1: 滚动到底部。
   *
   * @param resetUserScroll 是否重置用户滚动标记(点击回到底部按钮时为 true)
   */
  private scrollToBottom(resetUserScroll: boolean): void {
    this.messageScroller.scrollEdge(Edge.Bottom);
    if (resetUserScroll) {
      this.userScrolledUp = false;
      this.isAtBottom = true;
      this.showScrollToBottom = false;
    }
  }

  /**
   * 延迟一帧滚动到底部(等 List 布局完成)。
   *
   * 场景:
   * - aboutToAppear 首次加载:组件尚未 build,直接 scrollEdge 无效
   * - 发送消息后:新消息 ListItem 刚插入,需等布局完成才能正确滚到底部
   * - 流式更新:内容增长导致布局变化,延迟滚动确保滚到最新位置
   *
   * 使用 setTimeout 而非轮询,仅延迟一次,不重复调度。
   */
  private scheduleScrollToBottom(): void {
    if (this.scrollScheduleTimerId !== -1) {
      clearTimeout(this.scrollScheduleTimerId);
    }
    this.scrollScheduleTimerId = setTimeout((): void => {
      this.scrollScheduleTimerId = -1;
      try {
        this.messageScroller.scrollEdge(Edge.Bottom);
      } catch (_e) {
        // 忽略滚动异常
      }
    }, 80);
  }

  /**
   * G-RUNTIME-1C-FIX: 判断指定消息是否应该显示重试/结束本轮卡片。
   *
   * 修复要点(与用户实机问题 1 对齐):
   * - 不再依赖 roundState(页面重入后 roundState 重置为 Idle,导致重试入口消失)
   * - 改为基于消息自身真实状态(Failed/Cancelled)判断
   * - 退出重进后只要数据库消息仍为可重试状态,重试入口正确出现
   *
   * 规则:
   * - 仅角色消息(role !== User, senderCharacterId 存在)
   * - 消息状态为 Failed 或 Cancelled
   * - 角色仍存在(characterExists)
   * - 当前无活动生成/重试/结束本轮
   * - 仅最近一条可重试的角色消息显示大型错误卡
   */
  private shouldShowErrorCard(state: GroupMessageRenderState): boolean {
    // 生成/重试/结束本轮进行中:隐藏卡片(新 Streaming 已在底部)
    if (this.isGenerating || this.isRetrying || this.isEndingRound) {
      return false;
    }
    // 仅角色消息
    if (state.role === ChatRole.User) {
      return false;
    }
    if (state.senderCharacterId.length === 0) {
      return false;
    }
    if (state.status !== ChatMessageStatus.Failed && state.status !== ChatMessageStatus.Cancelled) {
      return false;
    }
    // 缺失角色无法重试
    if (!state.characterExists) {
      return false;
    }
    // 仅最近一条 Failed/Cancelled 角色消息
    return this.findLatestRetryableMessageId() === state.messageId;
  }

  /** 查找最近一条可重试的角色消息 ID */
  private findLatestRetryableMessageId(): string {
    for (let i: number = this.messageStates.length - 1; i >= 0; i--) {
      const s: GroupMessageRenderState = this.messageStates[i];
      if (s.role === ChatRole.User) {
        continue;
      }
      if (s.senderCharacterId.length === 0) {
        continue;
      }
      if (!s.characterExists) {
        continue;
      }
      if (s.status === ChatMessageStatus.Failed || s.status === ChatMessageStatus.Cancelled) {
        return s.messageId;
      }
    }
    return '';
  }

  /** 构建错误卡片文案 */
  private composeErrorCardText(state: GroupMessageRenderState): string {
    const name: string = state.senderName;
    if (state.status === ChatMessageStatus.Failed) {
      return name + ' 回复失败';
    }
    if (state.status === ChatMessageStatus.Cancelled) {
      return name + ' 已停止,可重试当前角色';
    }
    return '回复失败';
  }

  /** G-RUNTIME-1C-FIX: 处理重试当前角色 */
  private async handleRetrySpeaker(state: GroupMessageRenderState): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isGenerating || this.isRetrying || this.isEndingRound) {
      return;
    }
    // 构造 GroupMessageUiModel 用于 canRetryMessage 校验
    const msg: GroupMessageUiModel = {
      id: state.messageId,
      role: state.role,
      content: state.content,
      status: state.status,
      senderCharacterId: state.senderCharacterId.length > 0 ? state.senderCharacterId : undefined,
      senderName: state.senderName,
      senderAvatarUri: state.senderAvatarUri.length > 0 ? state.senderAvatarUri : undefined,
      characterExists: state.characterExists,
      generationBatchId: state.generationBatchId.length > 0 ? state.generationBatchId : undefined,
      sequenceNumber: 0,
      createdAt: state.createdAt,
      updatedAt: state.updatedAt,
      replyTargetCharacterIds: [],
      replyTargetNames: []
    };
    if (!this.viewModel.canRetryMessage(msg)) {
      promptAction.showToast({ message: '当前消息无法重试', duration: 1500 });
      return;
    }
    Logger.info('GroupChatPage', 'handleRetrySpeaker msgId=' + state.messageId);
    // 先启动轮询,确保 await retrySpeakerMessage 期间状态即时同步
    this.startSyncPolling();
    await this.viewModel.retrySpeakerMessage(state.messageId);
    this.syncFromViewModel();
    // 重试已启动,确保轮询运行
    if (this.viewModel.isGenerating) {
      this.startSyncPolling();
    }
  }

  /** G-RUNTIME-1C: 处理结束本轮 */
  private async handleEndRound(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isRetrying || this.isEndingRound) {
      return;
    }
    Logger.info('GroupChatPage', 'handleEndRound');
    await this.viewModel.endRound();
    this.syncFromViewModel();
  }

  /** 输入区(启用真实发送,G-CONTROL-1 增加目标 Chip 与 @选择器) */
  /**
   * G-UI-ALIGN-2A: 悬浮胶囊输入栏(对齐单聊 inputArea)。
   *
   * 结构:
   * - Column(透明容器,不承载不透明背景)
   *   ├─ 错误提示(条件)
   *   ├─ 回复目标 Chip(条件)
   *   ├─ @选择器(条件,放在胶囊上方避免键盘遮挡)
   *   └─ 悬浮输入胶囊 Row
   *      ├─ TextArea(minHeight=48, maxHeight=320, layoutWeight=1)
   *      └─ 发送/停止按钮 48×48(isGenerating 时显示停止)
   *
   * 胶囊造型:
   * - borderRadius=28, border 0.5 surface_2
   * - backgroundBlurStyle(Regular, ALWAYS_ACTIVE) 鸿蒙原生材质模糊
   * - 透出后方页面背景
   *
   * 键盘避让:
   * - OFFSET 模式:输入栏未加 expandSafeArea(KEYBOARD),被系统上抬到键盘上方
   * - bottom padding:键盘弹起 12(系统已上抬);未弹起 navBarHeight + 12(避让手势条)
   */
  @Builder
  inputBarArea(): void {
    Column() {
      // G-UI-ALIGN-3: 错误提示已移至顶部浮动 errorBanner,不再在输入栏内显示

      // GROUP-CHAT-TARGET-1: 持续对话状态条 + 仅本次 Chip + 多选草稿 Chip
      Row() {
        // 持续对话状态条(优先级最高,持续模式下显示)
        if (this.persistentReplyTargetCharacterId.length > 0) {
          Row() {
            CharacterImageView({
              imageUri: this.persistentTargetAvatarUri,
              fallbackName: this.persistentTargetName,
              imgWidth: 20,
              imgHeight: 20,
              imgBorderRadius: 10,
              displayMode: 'thumbnail',
              objectFit: ImageFit.Cover
            })
            Text('正在与 ' + this.persistentTargetName + ' 持续对话')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_on_accent'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: 6 })
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(12)
                .fontColor([$r('app.color.app_on_accent')])
            }
            .type(ButtonType.Circle)
            .backgroundColor(Color.Transparent)
            .width(20)
            .height(20)
            .margin({ left: 4 })
            .key('group.persistent_target_cancel')
            .accessibilityText('取消持续对话')
            .enabled(!this.isGenerating && !this.isSending)
            .onClick(() => {
              this.handleClearPersistentTarget();
            })
          }
          .padding({ left: 10, right: 6, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .alignItems(VerticalAlign.Center)
        } else if (this.oneShotTargetName.length > 0) {
          // 仅本次 Chip
          Row() {
            Text('仅' + this.oneShotTargetName + '回复(本次)')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_on_accent'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(12)
                .fontColor([$r('app.color.app_on_accent')])
            }
            .type(ButtonType.Circle)
            .backgroundColor(Color.Transparent)
            .width(20)
            .height(20)
            .margin({ left: 4 })
            .accessibilityText('取消仅本次目标')
            .enabled(!this.isGenerating && !this.isSending)
            .onClick(() => {
              this.handleClearOneShotTarget();
            })
          }
          .padding({ left: 10, right: 6, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .alignItems(VerticalAlign.Center)
        } else if (this.selectedReplyTargetMembers.length > 0) {
          // 多选草稿 Chip(现有行为)
          Row() {
            Text(this.composeTargetChipText())
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_on_accent'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(12)
                .fontColor([$r('app.color.app_on_accent')])
            }
            .type(ButtonType.Circle)
            .backgroundColor(Color.Transparent)
            .width(20)
            .height(20)
            .margin({ left: 4 })
            .accessibilityText('取消全部指定角色')
            .enabled(!this.isGenerating && !this.isSending)
            .onClick(() => {
              this.handleClearReplyTarget();
            })
          }
          .padding({ left: 10, right: 6, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .alignItems(VerticalAlign.Center)
        }
        // GROUP-CHAT-TARGET-1: 默认状态不显示任何提示文字(隐藏旧的 "所有启用角色将按顺序回复")
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })

      // G-CONTROL-1: @选择器浮层(放在胶囊上方,避免键盘弹出时被遮挡)
      if (this.isMentionPickerVisible && this.mentionCandidates.length > 0) {
        this.mentionPickerPanel()
      }

      // 悬浮输入胶囊:TextArea + 发送/停止按钮
      Row() {
        TextArea({
          placeholder: '发送消息(输入 @ 指定角色)',
          text: this.inputText
        })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.app_radius_md'))
          .border({ width: 0 })
          .maxLines(10)
          .barState(BarState.Auto)
          .constraintSize({ minHeight: 48, maxHeight: 320 })
          .layoutWeight(1)
          .padding({ left: 16, right: 8, top: 10, bottom: 10 })
          .enabled(!this.isSending && !this.isGenerating && !this.isAnotherChatRunning)
          .onChange((value: string) => {
            this.inputText = value;
            if (this.viewModel !== null) {
              this.viewModel.inputText = value;
            }
            // G-CONTROL-2A: 程序化设置文本(handleSelectMention)后跳过一次 @检测,
            // 避免 @角色名 被误判为用户输入 @ 重新打开选择器
            if (this.skipMentionDetectionOnNextChange) {
              this.skipMentionDetectionOnNextChange = false;
            } else {
              this.handleMentionDetection(value);
            }
          })

        // 发送/停止按钮:48×48 圆形(对齐单聊)
        if (this.isGenerating) {
          // 生成中:停止本轮按钮(红色,xmark 图标)
          Stack() {
            if (this.isStopping) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color($r('app.color.app_on_accent'))
            } else {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(20)
                .fontColor([$r('app.color.app_on_accent')])
            }
          }
          .backgroundColor($r('app.color.app_danger'))
          .borderRadius(24)
          .width(48)
          .height(48)
          .margin({ right: 4 })
          .key('group.stop_round_btn')
          .accessibilityText('停止本轮')
          .enabled(!this.isStopping)
          .onClick(() => {
            this.handleStopRound();
          })
        } else {
          // 普通状态:发送按钮(accent 色,arrow_up 图标)
          Stack() {
            SymbolGlyph($r('sys.symbol.arrow_up'))
              .fontSize(20)
              .fontColor([
                this.canSendInput()
                  ? $r('app.color.app_on_accent')
                  : $r('app.color.app_text_tertiary')
              ])
          }
          .backgroundColor(this.canSendInput()
            ? $r('app.color.app_accent')
            : Color.Transparent)
          .borderRadius(24)
          .width(48)
          .height(48)
          .margin({ right: 4 })
          .accessibilityText('发送消息')
          .enabled(this.canSendInput())
          .onClick(() => {
            this.handleSend();
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .borderRadius(28)
      .border({ width: 0.5, color: $r('app.color.app_surface_2') })
      .backgroundBlurStyle(BlurStyle.Regular, {
        policy: BlurStyleActivePolicy.ALWAYS_ACTIVE
      })
      .padding({ left: 4, right: 0, top: 0, bottom: 0 })
    }
    .width('100%')
    .padding({
      left: 12,
      right: 12,
      top: 4,
      bottom: this.keyboardHeight > 0 ? 12 : this.navBarHeight + 12
    })
  }

  /**
   * G-UI-ALIGN-2A: 判断当前输入是否可发送。
   * 条件:非发送中、非跨群聊锁、输入文本非空。
   */
  private canSendInput(): boolean {
    return !this.isSending && !this.isAnotherChatRunning && this.inputText.trim().length > 0;
  }

  /**
   * G-CONTROL-2A: @选择器面板(轻量透明布局,最小遮挡)。
   *
   * 设计:
   * - 透明背景 + backgroundBlurStyle 材质模糊,透出后方消息
   * - 高度自适应内容(最多 160vp),不固定 200vp 大块
   * - 紧凑行高(36vp),仅头像 24px + 名称 + ✓ 标记
   * - 无明显边框,仅底部圆角与阴影区分层次
   * - hitTestMode 透传,不拦截列表滚动
   */
  @Builder
  mentionPickerPanel(): void {
    Column() {
      List() {
        ForEach(this.mentionCandidates, (member: GroupMemberUiModel) => {
          ListItem() {
            Row() {
              CharacterImageView({
                imageUri: member.avatarUri,
                fallbackName: member.name,
                imgWidth: 24,
                imgHeight: 24,
                imgBorderRadius: 12,
                displayMode: 'thumbnail',
                objectFit: ImageFit.Cover
              })
              Text(member.name)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(this.isMemberReplyTarget(member.characterId)
                  ? $r('app.color.app_accent')
                  : $r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: 6 })
                .layoutWeight(1)
              // G-CONTROL-2A: 已选中的角色显示 ✓ 标记
              if (this.isMemberReplyTarget(member.characterId)) {
                Text('✓')
                  .fontSize(12)
                  .fontColor($r('app.color.app_accent'))
                  .margin({ left: 4 })
              }
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .alignItems(VerticalAlign.Center)
          }
          .onClick(() => {
            this.handleSelectMention(member);
          })
        }, (member: GroupMemberUiModel) => member.characterId + '|' + (this.isMemberReplyTarget(member.characterId) ? '1' : '0'))
      }
      .width('100%')
      .constraintSize({ maxHeight: 160 })
      .scrollBar(BarState.Off)
      .borderRadius($r('app.float.app_radius_md'))
      .backgroundBlurStyle(BlurStyle.Regular, {
        policy: BlurStyleActivePolicy.ALWAYS_ACTIVE
      })
      .border({ width: 0.5, color: $r('app.color.app_surface_2') })
      .shadow({ radius: 8, color: 'rgba(0,0,0,0.12)', offsetY: 2 })
    }
    .width('100%')
    .margin({ top: 4 })
    .hitTestBehavior(HitTestMode.Default)
  }

  /** G-CONTROL-1: 检测输入框中的 @触发点 */
  private handleMentionDetection(value: string): void {
    if (this.viewModel === null) {
      return;
    }
    // 生成中不处理 @检测
    if (this.isGenerating || this.isSending) {
      return;
    }
    // 查找最后一个 @
    const atIdx: number = value.lastIndexOf('@');
    if (atIdx < 0) {
      // 没有 @,关闭选择器
      if (this.viewModel.isMentionPickerVisible) {
        this.viewModel.closeMentionPicker();
        this.syncFromViewModel();
      }
      return;
    }
    // @ 必须在行首或前面是空白
    if (atIdx > 0) {
      const prevChar: string = value.charAt(atIdx - 1);
      if (prevChar !== ' ' && prevChar !== '\n' && prevChar !== '\t') {
        // @不在词首,关闭选择器
        if (this.viewModel.isMentionPickerVisible) {
          this.viewModel.closeMentionPicker();
this.syncFromViewModel();
    // GROUP-CHAT-TARGET-1: 发送后防御性清除仅本次目标(页面侧确保不会残留)
    this.oneShotTargetName = '';
    if (this.viewModel.pendingOneShotReplyTargetCharacterId.length > 0) {
      this.viewModel.pendingOneShotReplyTargetCharacterId = '';
    }
        }
        return;
      }
    }
    // 提取 @ 后的查询文本(直到空白或结尾)
    let query: string = '';
    for (let i: number = atIdx + 1; i < value.length; i++) {
      const ch: string = value.charAt(i);
      if (ch === ' ' || ch === '\n' || ch === '\t') {
        break;
      }
      query = query + ch;
    }
    // 更新或打开选择器
    if (this.viewModel.isMentionPickerVisible) {
      this.viewModel.updateMentionQuery(query);
    } else {
      this.viewModel.openMentionPicker(query);
    }
    this.syncFromViewModel();
  }

  /** G-CONTROL-1: 选择 @角色 → GROUP-CHAT-TARGET-1: 按设置模式直接生效 */
  private handleSelectMention(member: GroupMemberUiModel): void {
    if (this.viewModel === null) {
      return;
    }
    // 关闭 @选择器
    this.viewModel.closeMentionPicker();
    // 替换输入框中的 @查询 为 @角色名
    const value: string = this.inputText;
    const atIdx: number = value.lastIndexOf('@');
    if (atIdx >= 0) {
      const before: string = value.substring(0, atIdx);
      this.inputText = before + '@' + member.name + ' ';
      if (this.viewModel !== null) {
        this.viewModel.inputText = this.inputText;
      }
      this.skipMentionDetectionOnNextChange = true;
    }
    // GROUP-CHAT-TARGET-1: 按群聊设置中的模式直接生效，先清除旧草稿防止残留
    if (this.viewModel.replyTargetMode === 'persistent') {
      this.viewModel.clearReplyTarget();
      this.viewModel.setPersistentReplyTarget(member.characterId);
    } else {
      this.viewModel.clearReplyTarget();
      this.viewModel.setOneShotReplyTarget(member.characterId);
    }
    this.syncFromViewModel();
  }

  /** G-CONTROL-1: 取消回复目标 */
  private handleClearReplyTarget(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.clearReplyTarget();
    this.syncFromViewModel();
  }

  /** GROUP-CHAT-TARGET-1: 取消持续对话目标 */
  private handleClearPersistentTarget(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.clearPersistentReplyTarget();
    this.syncFromViewModel();
  }

  /** GROUP-CHAT-TARGET-1: 取消仅本次目标 */
  private handleClearOneShotTarget(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.pendingOneShotReplyTargetCharacterId = '';
    this.syncFromViewModel();
  }

  /**
   * 处理发送(G-RUNTIME-1C-FIX)。
   *
   * 关键修复:
   * - 在 await sendUserMessage 之前先启动轮询。
   * - sendUserMessage 内部 await startRound 会阻塞直到整轮完成,
   *   如果轮询在 await 之后启动,整个生成期间页面状态不会刷新。
   * - 先启动轮询,确保 await 期间 ViewModel 状态变化(轮次/消息)即时同步到页面。
   * - onMessagesUpdate 回调负责消息即时刷新,轮询负责 roundState 等其他状态。
   */
  private async handleSend(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const content: string = this.inputText.trim();
    if (content.length === 0 || this.isSending || this.isGenerating) {
      return;
    }
    // 先启动轮询,确保 await sendUserMessage 期间状态即时同步
    this.startSyncPolling();
    await this.viewModel.sendUserMessage(content);
    this.syncFromViewModel();
    if (this.viewModel.errorMessage.length === 0 && this.viewModel.inputText.length === 0) {
      // 发送成功,清空本地输入框
      this.inputText = '';
    }
    // 发送后强制重置用户滚动标记并延迟滚动到底部
    // (键盘弹起过程中 handleScrollPositionChange 可能误判为用户上滑,需显式重置)
    this.userScrolledUp = false;
    this.isAtBottom = true;
    this.showScrollToBottom = false;
    this.scheduleScrollToBottom();
    // 生成已启动,确保轮询运行
    if (this.viewModel.isGenerating) {
      this.startSyncPolling();
    }
  }

  /** 处理停止本轮 */
  private async handleStopRound(): Promise<void> {
    if (this.viewModel === null || !this.isGenerating || this.isStopping) {
      return;
    }
    await this.viewModel.stopRound();
    this.syncFromViewModel();
  }

  /**
   * G-UI-ALIGN-2A: 显示设置面板(气泡透明度 Slider)。
   *
   * 对齐单聊 chatAppearancePanel 的气泡不透明度部分:
   * - 半透明面板,靠右,不覆盖整屏,无全屏遮罩
   * - 标题"显示设置"+ 关闭按钮
   * - 气泡不透明度 Slider(min=0, max=100, step=10)
   * - 显示当前百分比
   * - onChange 实时更新 bubbleOpacity(触发气泡重绘)
   * - End/Click 时持久化到 Preferences(与单聊共享 key)
   *
   * 本阶段只接入气泡透明度,不复制字体/背景/VRM 等其他设置。
   */
  @Builder
  chatAppearancePanel(): void {
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
            .accessibilityText('关闭显示设置')
            .onClick(() => {
              this.appearancePanelVisible = false;
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
            Text(`${Math.round(this.bubbleOpacity * 100)}%`)
              .fontSize($r('app.float.app_font_caption'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_text_primary'))
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 8 })

          Slider({
            value: Math.round(this.bubbleOpacity * 100),
            min: 0,
            max: 100,
            step: 10,
            style: SliderStyle.OutSet
          })
            .blockColor($r('app.color.app_accent'))
            .trackColor($r('app.color.app_surface_2'))
            .selectedColor($r('app.color.app_accent'))
            .width('100%')
            .onChange((value: number, mode: SliderChangeMode) => {
              const opacity: number = normalizeBubbleOpacity(value / 100);
              this.bubbleOpacity = opacity;
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                persistBubbleOpacity(opacity);
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
        }
        .padding(16)
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_lg'))
        .width('80%')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Top)
    .padding({ top: this.statusBarHeight + 56, right: 12 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * G-UI-ALIGN-3: 更多菜单底部 Sheet(对齐单聊 ChatMoreMenuSheet 模式)。
   *
   * - 全屏 Stack + rgba scrim,点击 scrim 关闭
   * - 底部锚定 Column,顶部圆角 16,surface_1 背景
   * - 顶部拖动条 + 标题 + 菜单项 + 关闭
   * - 菜单项:管理成员 / 群聊设置 / 重命名
   * - 底部 padding 避开导航栏(navBarHeight + 16)
   */
  @Builder
  moreMenuDialog(): void {
    Stack() {
      Column() {
        Blank().layoutWeight(1)
        Column() {
          // 拖动条
          Column()
            .width(36)
            .height(4)
            .borderRadius(2)
            .backgroundColor($r('app.color.app_divider'))
            .margin({ top: 8, bottom: 12 })

          // 标题
          Text($r('app.string.group_more_title'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12, left: 16, right: 16 })
            .width('100%')

          // 菜单项:管理成员
          this.sheetMenuItem($r('app.string.group_chat_menu_manage'), (): void => {
            this.moreMenuVisible = false;
            this.goManageMembers();
          })

          // 菜单项:群聊设置
          this.sheetMenuItem($r('app.string.group_chat_menu_settings'), (): void => {
            this.moreMenuVisible = false;
            this.goSettings();
          })

          // 菜单项:重命名
          this.sheetMenuItem($r('app.string.group_chat_menu_rename'), (): void => {
            this.moreMenuVisible = false;
            this.renameInput = this.detail !== null ? this.detail.title : '';
            this.renameVisible = true;
          })

          // G-MEMORY-UI-2: 菜单项:角色记忆(直接进入页面,不再弹出选择 Sheet)
          this.sheetMenuItem('角色记忆', (): void => {
            this.moreMenuVisible = false;
            this.goCharacterMemoryPage();
          })

          // 关闭按钮
          Button($r('app.string.group_cancel'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_md'))
            .width('100%')
            .height(44)
            .margin({ top: 12, left: 16, right: 16 })
            .accessibilityText('关闭更多操作')
            .onClick(() => {
              this.moreMenuVisible = false;
            })
        }
        .width('100%')
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 0, bottomRight: 0 })
        .padding({ top: 0, bottom: this.navBarHeight + 16 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.moreMenuVisible = false;
    })
    .transition(TransitionEffect.OPACITY)
  }

  /**
   * G-UI-ALIGN-3: Sheet 菜单项(统一高度、圆角、点击反馈)。
   * 对齐单聊 ChatMoreMenuSheet 的列表项样式。
   */
  @Builder
  sheetMenuItem(label: ResourceStr, onTap: () => void): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.app_text_tertiary')])
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .margin({ left: 16, right: 16 })
    .borderRadius($r('app.float.app_radius_sm'))
    .onClick(() => {
      onTap();
    })
  }

  private goManageMembers(): void {
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.chatId);
    router.pushUrl({ url: 'pages/groupchat/GroupMemberManagePage' });
  }

  private goSettings(): void {
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.chatId);
    router.pushUrl({ url: 'pages/groupchat/GroupChatSettingsPage' });
  }

  /**
   * G-MEMORY-1A: 打开角色记忆选择 Sheet(更多菜单 → 角色记忆)。
   * 异步加载每个成员的记忆数量,显示成员列表供用户选择。
   */
  private openMemoryPicker(): void {
    if (this.detail === null) {
      return;
    }
    this.memberMemoryCounts = new Map();
    this.memoryPickerVisible = true;
    this.loadMemberMemoryCounts();
  }

  /** G-MEMORY-1A: 异步加载成员记忆数量(不阻塞 Sheet 显示) */
  private async loadMemberMemoryCounts(): Promise<void> {
    if (this.detail === null) {
      return;
    }
    try {
      const memoryService = AppServices.getGroupCharacterMemoryService();
      const counts: Map<string, number> = new Map();
      for (let i = 0; i < this.detail.members.length; i++) {
        const member: GroupMemberUiModel = this.detail.members[i];
        if (!member.characterExists) {
          counts.set(member.characterId, 0);
          continue;
        }
        const count: number = await memoryService.countByCharacter(
          this.chatId, member.characterId
        );
        counts.set(member.characterId, count);
      }
      this.memberMemoryCounts = counts;
    } catch (e) {
      Logger.warn('GroupChatPage', 'loadMemberMemoryCounts failed: ' + (e as Error).message);
    }
  }

  /** G-MEMORY-UI-2: 直接跳转角色记忆页(不弹角色选择 Sheet) */
  private goCharacterMemoryPage(): void {
    if (this.chatId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_GROUP_MEMORY_GROUP_ID_KEY, this.chatId);
    AppStorage.setOrCreate<string>(PENDING_GROUP_MEMORY_CHARACTER_ID_KEY, '');
    router.pushUrl({ url: 'pages/groupchat/GroupCharacterMemoryPage' });
  }

  /** G-MEMORY-1A: 跳转到指定角色的记忆页(长按成员头像) */
  private goCharacterMemory(characterId: string): void {
    if (characterId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_GROUP_MEMORY_GROUP_ID_KEY, this.chatId);
    AppStorage.setOrCreate<string>(PENDING_GROUP_MEMORY_CHARACTER_ID_KEY, characterId);
    router.pushUrl({ url: 'pages/groupchat/GroupCharacterMemoryPage' });
  }

  /**
   * G-MEMORY-1A: 角色记忆选择 Sheet(底部锚定,对齐更多菜单 Sheet 风格)。
   * 显示成员列表(头像/名称/启用状态/记忆数量),点击进入该角色记忆页。
   */
  @Builder
  memoryPickerDialog(): void {
    Stack() {
      Column() {
        Blank().layoutWeight(1)
        Column() {
          // 拖动条
          Column()
            .width(36)
            .height(4)
            .borderRadius(2)
            .backgroundColor($r('app.color.app_divider'))
            .margin({ top: 8, bottom: 12 })

          // 标题
          Text('角色记忆')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12, left: 16, right: 16 })
            .width('100%')

          // 成员列表
          if (this.detail !== null) {
            ForEach(this.detail.members, (member: GroupMemberUiModel) => {
              Row() {
                CharacterImageView({
                  imageUri: member.avatarUri,
                  fallbackName: member.name,
                  imgWidth: 36,
                  imgHeight: 36,
                  imgBorderRadius: 18,
                  displayMode: 'thumbnail'
                })

                Column() {
                  Text(member.name)
                    .fontSize($r('app.float.app_font_body'))
                    .fontColor($r('app.color.app_text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')

                  Row() {
                    Text(member.isEnabled ? '启用' : '停用')
                      .fontSize(10)
                      .fontColor(member.isEnabled
                        ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
                      .backgroundColor($r('app.color.app_surface_2'))
                      .borderRadius(3)
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })

                    Text(this.memberMemoryCountText(member.characterId))
                      .fontSize(10)
                      .fontColor($r('app.color.app_text_tertiary'))
                      .backgroundColor($r('app.color.app_surface_2'))
                      .borderRadius(3)
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                      .margin({ left: 4 })
                  }
                  .margin({ top: 4 })
                  .alignItems(VerticalAlign.Center)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 10 })

                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(16)
                  .fontColor([$r('app.color.app_text_tertiary')])
              }
              .width('100%')
              .height(56)
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
              .margin({ left: 16, right: 16 })
              .borderRadius($r('app.float.app_radius_sm'))
              .opacity(member.characterExists ? 1 : 0.6)
              .onClick(() => {
                this.memoryPickerVisible = false;
                this.goCharacterMemory(member.characterId);
              })
            }, (member: GroupMemberUiModel) => member.characterId)
          }

          // 关闭按钮
          Button($r('app.string.group_cancel'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_md'))
            .width('100%')
            .height(44)
            .margin({ top: 12, left: 16, right: 16 })
            .accessibilityText('关闭角色记忆选择')
            .onClick(() => {
              this.memoryPickerVisible = false;
            })
        }
        .width('100%')
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 0, bottomRight: 0 })
        .padding({ top: 0, bottom: this.navBarHeight + 16 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.memoryPickerVisible = false;
    })
    .transition(TransitionEffect.OPACITY)
  }

  /** G-MEMORY-1A: 构建成员记忆数量文字 */
  private memberMemoryCountText(characterId: string): string {
    const count: number = this.memberMemoryCounts.get(characterId) ?? 0;
    return count.toString() + ' 条记忆';
  }

/**
   * G-UI-ALIGN-3: 重命名底部 Sheet(对齐更多菜单 Sheet 模式)。
   *
   * - 底部锚定表单:拖动条 + 标题 + TextInput + 取消/保存
   * - 保存期间禁用按钮防重复提交(renameSaving)
   * - 失败保留输入,成功后刷新标题并关闭
   * - 底部 padding 避开导航栏
   */
  @Builder
  renameDialog(): void {
    Stack() {
      Column() {
        Blank().layoutWeight(1)
        Column() {
          // 拖动条
          Column()
            .width(36)
            .height(4)
            .borderRadius(2)
            .backgroundColor($r('app.color.app_divider'))
            .margin({ top: 8, bottom: 12 })

          // 标题
          Text($r('app.string.group_chat_menu_rename'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12, left: 16, right: 16 })
            .width('100%')

          // 群聊名称输入框
          TextInput({ placeholder: $r('app.string.group_rename_placeholder'), text: this.renameInput })
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_md'))
            .height(44)
            .padding({ left: 12, right: 12 })
            .margin({ left: 16, right: 16 })
            .enabled(!this.renameSaving)
            .onChange((value: string) => {
              this.renameInput = value;
            })

          // 取消 / 保存
          Row() {
            Button($r('app.string.group_cancel'))
              .fontSize($r('app.float.app_font_body'))
              .backgroundColor($r('app.color.app_surface_2'))
              .fontColor($r('app.color.app_text_secondary'))
              .borderRadius($r('app.float.app_radius_md'))
              .layoutWeight(1)
              .height(44)
              .enabled(!this.renameSaving)
              .accessibilityText('取消重命名')
              .onClick(() => {
                this.renameVisible = false;
                this.renameInput = '';
              })
            Button(this.renameSaving ? $r('app.string.group_saving') : $r('app.string.group_save'))
              .fontSize($r('app.float.app_font_body'))
              .backgroundColor($r('app.color.app_accent'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_md'))
              .layoutWeight(1)
              .height(44)
              .margin({ left: 12 })
              .enabled(!this.renameSaving)
              .accessibilityText('保存群聊名称')
              .onClick(() => {
                this.confirmRename();
              })
          }
          .width('100%')
          .margin({ top: 16, left: 16, right: 16 })
        }
        .width('100%')
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 0, bottomRight: 0 })
        .padding({ top: 0, bottom: this.navBarHeight + 16 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      if (!this.renameSaving) {
        this.renameVisible = false;
      }
    })
    .transition(TransitionEffect.OPACITY)
  }

  private async confirmRename(): Promise<void> {
    if (this.renameSaving) {
      return;
    }
    const trimmed: string = this.renameInput.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: '名称不能为空', duration: 1500 });
      return;
    }
    if (this.viewModel === null) {
      return;
    }
    this.renameSaving = true;
    try {
      await this.viewModel.rename(trimmed);
      this.syncFromViewModel();
      this.renameVisible = false;
      this.renameInput = '';
      promptAction.showToast({ message: '已保存', duration: 1200 });
    } catch (e) {
      // 失败保留输入,不关闭 Sheet
      promptAction.showToast({ message: '重命名失败', duration: 1500 });
    } finally {
      this.renameSaving = false;
    }
  }
}

/**
 * G-UI-ALIGN-1: 成员栏展示状态。
 *
 * - Collapsed:收起为头像堆叠(GroupAvatarStack),占用最小高度
 * - Expanded:展开为横向成员列表,显示头像+名称+运行状态
 *
 * 状态切换规则:
 * - 页面首次进入:Collapsed
 * - 新回复轮次开始(Generating 且轮次 ID 变化):若本轮内用户未收起,则 Expanded
 * - 用户主动向上滚动消息:Collapsed(并标记 memberStripCollapsedByUser)
 * - 轮次结束(Completed/Cancelled/Failed/Idle):Collapsed
 * - 下一次新轮次开始:重置 memberStripCollapsedByUser,允许 Expanded
 */
enum MemberStripDisplayState {
  Collapsed = 'collapsed',
  Expanded = 'expanded'
}
