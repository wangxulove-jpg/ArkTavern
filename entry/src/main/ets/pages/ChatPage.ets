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
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { MessageSwipeSummary, MAX_SWIPE_CANDIDATES } from '../models/MessageSwipe';
import { MessageSwipeControls } from '../components/MessageSwipeControls';
import { HistoricalMessageEditDialog } from '../components/HistoricalMessageEditDialog';
import { ChatMessageBubble } from '../components/ChatMessageBubble';
import { ChatMessageActionSheet, MessageAction } from '../components/ChatMessageActionSheet';
import { ChatMoreMenuSheet } from '../components/ChatMoreMenuSheet';
import { CharacterImageView } from '../components/CharacterImageView';
import { promptAction, router, window } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { inputMethod } from '@kit.IMEKit';
import { AppServices } from '../services/AppServices';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';
import { ChatBackgroundConfig } from '../services/ChatBackgroundService';
import { ContextBudgetViewModel } from '../viewmodels/ContextBudgetViewModel';
import { ContextBudgetSnapshotStore } from '../services/ContextBudgetSnapshotStore';
import {
  ContextBudgetStats,
  BudgetLevel
} from '../services/ContextBudgetEstimator';
import { ForkChatMode } from '../models/ForkChatOptions';
import { ChatSessionListPanel } from '../components/ChatSessionListPanel';
import { Character } from '../models/Character';
import { TypingState } from '../models/TypingState';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatPage';

@Entry
@Component
struct ChatPage {
  @State viewModel: ChatViewModel | null = null;
  /** 独立 @State 消息列表(确保 ForEach 响应式刷新) */
  @State messages: ChatMessage[] = [];
  /** 打字机状态数组(@Observed class,与 messages 一一对应,原地修改字段触发 @ObjectLink 响应) */
  @State typingStates: TypingState[] = [];
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
      // 先同步 typingStates(原地修改字段,触发 @ObjectLink 响应)
      this.syncTypingStates(msgs);
      this.messages = msgs;
      this.maybeLoadChatBackground();
      // 消息变更后刷新上下文占用统计
      this.refreshBudgetSnapshot();
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
  }

  aboutToDisappear(): void {
    this.unregisterKeyboardListener();
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
      this.viewModel = null;
    }
    this.messages = [];
    const v: number = AppStorage.get<number>('chatListVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatListVersion', v + 1);
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

  /**
   * 同步 typingStates 数组,与 messages 保持一致。
   * - 已有的 TypingState:原地修改 content/isStreaming 字段(触发 @ObjectLink 响应)
   * - 新消息:创建新 TypingState(包含 message 引用)
   * - 已删除的消息:不放入新数组
   */
  private syncTypingStates(msgs: ChatMessage[]): void {
    const newStates: TypingState[] = [];
    let added: number = 0;
    let updated: number = 0;
    for (let i = 0; i < msgs.length; i++) {
      const msg: ChatMessage = msgs[i];
      // 在旧数组中查找相同 messageId 的 TypingState
      let state: TypingState | undefined = undefined;
      for (let j = 0; j < this.typingStates.length; j++) {
        if (this.typingStates[j].messageId === msg.id) {
          state = this.typingStates[j];
          break;
        }
      }
      if (state !== undefined) {
        // 原地修改字段(@Observed class 字段赋值触发 @ObjectLink 响应)
        state.content = msg.content;
        state.isStreaming = msg.isStreaming === true;
        newStates.push(state);
        updated++;
      } else {
        newStates.push(new TypingState(msg, msg.content, msg.isStreaming === true));
        added++;
      }
    }
    this.typingStates = newStates;
    const lastMsg: ChatMessage | undefined = msgs.length > 0 ? msgs[msgs.length - 1] : undefined;
    const lastStreaming: boolean = lastMsg !== undefined && lastMsg.isStreaming === true;
    const lastLen: number = lastMsg !== undefined ? lastMsg.content.length : 0;
    Logger.info(LOG_TAG, 'syncTypingStates | total=' + newStates.length.toString()
      + ' added=' + added.toString() + ' updated=' + updated.toString()
      + ' lastStreaming=' + lastStreaming.toString() + ' lastLen=' + lastLen.toString());
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

        // ===== 底层:消息列表 + 浮动按钮(占满全屏,从状态栏延伸到底部手势区) =====
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
        .width('100%')
        .height('100%')
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

        // ===== 浮层:顶栏(顶部对齐,半透明背景) =====
        // 注意:Stack 默认 alignContent=Center,若 Column 只设 width 不设 height,
        // 会被居中显示(顶栏/输入栏"集中在中间"的根因)。
        // 解法:Column 占满 height + justifyContent(Start/End) 让内容在顶部/底部对齐,
        // 同时 hitTestBehavior=Transparent 让空白区域点击穿透到下层消息列表。
        Column() {
          this.topBar()

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

  // ===== 消息列表 =====

  @Builder
  messageList() {
    Scroll(this.scroller) {
      Column() {
        ForEach(this.typingStates, (state: TypingState, _index: number) => {
          if (state.message.role !== ChatRole.System) {
            Column() {
              ChatMessageBubble({
                msg: state.message,
                typingState: state,
                characterAvatarUri: this.character !== null ? this.character!.avatarUri : '',
                characterName: this.viewModel !== null ? this.viewModel!.characterName : '',
                showAvatar: state.message.source !== ChatMessageSource.CharacterFirstMessage,
                settings: this.chatTextStyle,
                senderCharacterId: this.character !== null ? this.character!.id : '',
                onLongPress: (target: ChatMessage): void => {
                  this.actionSheetMsg = target;
                  this.showActionSheet = true;
                }
              })

              // 分支切换控件(仅 Assistant 非首条消息)
              if (state.message.role === ChatRole.Assistant
                && state.message.source !== ChatMessageSource.CharacterFirstMessage
                && this.viewModel !== null) {
                MessageSwipeControls({
                  activeCandidateIndex: this.getSwipeActiveIndex(state.message.id),
                  candidateCount: this.getCandidateCount(state.message.id),
                  isGenerating: this.viewModel!.isGenerating,
                  isOperable: this.viewModel!.canOperateSwipe(state.message.id),
                  isMaxReached: this.getCandidateCount(state.message.id) >= MAX_SWIPE_CANDIDATES,
                  onPrevious: (): void => {
                    this.viewModel!.swipePrevious(state.message.id);
                  },
                  onNext: (): void => {
                    this.viewModel!.swipeNext(state.message.id);
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
              if (state.message.status === ChatMessageStatus.Failed
                && this.viewModel !== null
                && this.viewModel!.canRegenerateAssistantMessage(state.message.id)) {
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
                  .backgroundColor($r('app.color.app_surface_2'))
                  .borderRadius(14)
                  .height(28)
                  .padding({ left: 12, right: 12 })
                  .margin({ top: 4, bottom: 4 })
                  .onClick(() => {
                    this.regenerateAssistantMessage(state.message.id);
                  })
                }
                .width('100%')
                .justifyContent(FlexAlign.Start)
                .margin({ left: 44 })
              }
            }
            .width('100%')
          }
        }, (state: TypingState) => state.messageId)
      // 底部空白占位:高度等于悬浮输入栏占用空间(输入栏 56 + bottom padding 12 + navBar 12),
      // 让 scrollEdge(Bottom) 时最后一条消息显示在悬浮输入栏上方,不被遮挡。
      Blank().height(80 + this.navigationBarHeight)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: 4,
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
    Logger.info(LOG_TAG, 'onBranchChangeSeqChanged | seq=' + this.branchChangeSeq.toString());
    this.viewModel!.reloadAfterBranchChange();
    // 分支切换后,上下文占用需重新统计
    this.refreshBudgetSnapshot();
  }
}
