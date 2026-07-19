/**
 * ChatPage 聊天页面(沉浸式原生 UI 重构)
 *
 * 设计目标:
 * - 顶部栏:返回 + 角色名 + 更多按钮(模型/预设/分支状态收敛到更多菜单)
 * - 消息列表:左右气泡 + Assistant 头像 + 流式光标 + 失败重试
 * - 长按消息:打开底部操作菜单(复制/编辑/重生成/继续/切分支)
 * - 底部输入区:多行 TextArea + 发送/停止按钮(无清空、无独立重生成)
 * - 空会话:角色头像 + 名称 + 开场白
 * - 颜色全部用 $r('app.color.*') 资源,自动适配深色模式
 * - 键盘避让:expandInput + safeArea
 *
 * 复用 ChatViewModel 所有接口,不修改业务逻辑。
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
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppServices } from '../services/AppServices';
import { ChatSessionListPanel } from '../components/ChatSessionListPanel';
import { Character } from '../models/Character';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatPage';

@Entry
@Component
export struct ChatPage {
  @State viewModel: ChatViewModel | null = null;
  /** 独立 @State 消息列表(确保 ForEach 响应式刷新) */
  @State messages: ChatMessage[] = [];
  /** 当前角色对象(用于头像) */
  @State character: Character | null = null;
  /** 是否显示更多菜单 */
  @State showMoreMenu: boolean = false;
  /** 是否显示消息操作菜单 */
  @State showActionSheet: boolean = false;
  /** 消息操作菜单目标消息 */
  @State actionSheetMsg: ChatMessage | null = null;
  /** 是否显示清空确认 */
  @State showClearConfirm: boolean = false;
  /** 清空确认输入文本 */
  @State clearConfirmInput: string = '';

  @StorageLink('branchChangeSeq') @Watch('onBranchChangeSeqChanged') branchChangeSeq: number = 0;
  private scroller: Scroller = new Scroller();
  private lastMessageCount: number = 0;
  private editDialogController: CustomDialogController | null = null;
  private editingMessageId: string = '';

  aboutToAppear(): void {
    const modelService = AppServices.getModelService();
    const characterService = AppServices.getCharacterService();
    const promptPresetService = AppServices.getPromptPresetService();
    const chatService = AppServices.createChatService();
    const vm: ChatViewModel = new ChatViewModel(
      chatService, modelService, characterService, promptPresetService
    );
    vm.onMessagesUpdate = (msgs: ChatMessage[]): void => {
      this.messages = msgs;
    };
    this.viewModel = vm;

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
      vm.initialize(pendingCharacterId).catch((): void => {});
    } else {
      vm.initialize();
      // 从当前角色加载头像
      this.loadCurrentCharacterAvatar();
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
      this.viewModel = null;
    }
    this.messages = [];
    const v: number = AppStorage.get<number>('chatListVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatListVersion', v + 1);
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
    NavDestination() {
      Column() {
        this.topBar()

        // 错误提示条
        if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
          Text(this.viewModel!.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
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

        // 消息列表区
        Stack({ alignContent: Alignment.Bottom }) {
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
            Button('↓')
              .fontSize(20)
              .backgroundColor($r('app.color.app_surface_1'))
              .fontColor($r('app.color.app_text_primary'))
              .borderRadius(22)
              .width(44)
              .height(44)
              .margin({ bottom: 12 })
              .shadow({ radius: 8, color: 'rgba(0,0,0,0.15)' })
              .onClick(() => {
                this.scroller.scrollEdge(Edge.Bottom);
                this.viewModel!.userScrolledUp = false;
              })
          }
        }
        .layoutWeight(1)
        .width('100%')

        // 底部输入区
        this.inputArea()

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
            onClose: (): void => { this.showMoreMenu = false; },
            onGoModelSettings: (): void => { this.goToModelSettings(); },
            onGoPresetList: (): void => { this.goToPresetList(); },
            onGoBranchMap: (): void => { this.navigateToBranchMap(); },
            onOpenSessionList: (): void => {
              this.viewModel!.openSessionList();
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
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title('')
    .hideTitleBar(true)
    .mode(NavDestinationMode.STANDARD)
  }

  // ===== 顶部栏 =====

  @Builder
  topBar() {
    Row() {
      Button('‹')
        .fontSize(24)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_text_primary'))
        .height(40)
        .width(40)
        .padding({ left: 4, right: 4 })
        .onClick(() => {
          this.handleBack();
        })

      Column() {
        Text(this.viewModel !== null && this.viewModel!.characterName.length > 0
          ? this.viewModel!.characterName
          : '聊天')
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Button('⋯')
        .fontSize(22)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_text_primary'))
        .height(40)
        .width(40)
        .padding({ left: 4, right: 4 })
        .onClick(() => {
          this.showMoreMenu = true;
        })
    }
    .width('100%')
    .height(56)
    .padding({ left: 4, right: 4, top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.app_surface_1'))
  }

  // ===== 消息列表 =====

  @Builder
  messageList() {
    Scroll(this.scroller) {
      Column() {
        ForEach(this.messages, (msg: ChatMessage, _index: number) => {
          if (msg.role !== ChatRole.System) {
            Column() {
              ChatMessageBubble({
                msg: msg,
                characterAvatarUri: this.character !== null ? this.character!.avatarUri : '',
                characterName: this.viewModel !== null ? this.viewModel!.characterName : '',
                showAvatar: msg.source !== ChatMessageSource.CharacterFirstMessage,
                onLongPress: (target: ChatMessage): void => {
                  this.actionSheetMsg = target;
                  this.showActionSheet = true;
                }
              })

              // 分支切换控件(仅 Assistant 非首条消息)
              if (msg.role === ChatRole.Assistant
                && msg.source !== ChatMessageSource.CharacterFirstMessage
                && this.viewModel !== null) {
                MessageSwipeControls({
                  activeCandidateIndex: this.getSwipeActiveIndex(msg.id),
                  candidateCount: this.getCandidateCount(msg.id),
                  isGenerating: this.viewModel!.isGenerating,
                  isOperable: this.viewModel!.canOperateSwipe(msg.id),
                  isMaxReached: this.getCandidateCount(msg.id) >= MAX_SWIPE_CANDIDATES,
                  onPrevious: (): void => {
                    this.viewModel!.swipePrevious(msg.id);
                  },
                  onNext: (): void => {
                    this.viewModel!.swipeNext(msg.id);
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
              if (msg.status === ChatMessageStatus.Failed
                && this.viewModel !== null
                && this.viewModel!.canRegenerateAssistantMessage(msg.id)) {
                Row() {
                  Button('↻ 重试')
                    .fontSize($r('app.float.app_font_caption'))
                    .backgroundColor($r('app.color.app_surface_2'))
                    .fontColor($r('app.color.app_accent'))
                    .borderRadius(14)
                    .height(28)
                    .padding({ left: 12, right: 12 })
                    .margin({ top: 4, bottom: 4 })
                    .onClick(() => {
                      this.regenerateAssistantMessage(msg.id);
                    })
                }
                .width('100%')
                .justifyContent(FlexAlign.Start)
                .margin({ left: 44 })
              }
            }
            .width('100%')
          }
        }, (msg: ChatMessage) => msg.id + '_' + (msg.updatedAt ?? 0) + '_'
          + (msg.status ?? '') + '_' + msg.content.length + '_'
          + (msg.isStreaming === true ? '1' : '0'))
        Blank().height(12)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 12 })
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
        Text('尚未配置模型')
          .fontSize($r('app.float.app_font_subtitle'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ bottom: 16 })

        Button('前往模型设置')
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
          .margin({ top: 12 })

        if (this.character!.firstMessage.length > 0) {
          Text(this.character!.firstMessage)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .textAlign(TextAlign.Center)
            .margin({ top: 12, left: 32, right: 32 })
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor($r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_md'))
        }

        Text('输入消息开始对话')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 24 })
      } else {
        Text('开始聊天')
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

  @Builder
  inputArea() {
    Column() {
      Divider().color($r('app.color.app_divider')).height(0.5)

      Row() {
        TextArea({
          placeholder: '输入消息…',
          text: this.viewModel !== null ? this.viewModel!.inputText : ''
        })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_md'))
          .maxLines(5)
          .layoutWeight(1)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .onChange((value: string) => {
            if (this.viewModel !== null) {
              this.viewModel!.updateInput(value);
            }
          })

        if (this.viewModel !== null && this.viewModel!.canStop) {
          Button('■')
            .fontSize(18)
            .backgroundColor($r('app.color.app_danger'))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius(22)
            .height(44)
            .width(44)
            .margin({ left: 8 })
            .onClick(() => {
              this.viewModel!.stop();
            })
        } else {
          Button('↑')
            .fontSize(20)
            .backgroundColor(this.canSend()
              ? $r('app.color.app_accent')
              : $r('app.color.app_surface_2'))
            .fontColor(this.canSend()
              ? $r('app.color.app_on_accent')
              : $r('app.color.app_text_tertiary'))
            .borderRadius(22)
            .height(44)
            .width(44)
            .margin({ left: 8 })
            .enabled(this.canSend())
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel!.send();
              }
            })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .alignItems(VerticalAlign.Bottom)
    }
    .backgroundColor($r('app.color.app_surface_1'))
  }

  // ===== 清空确认弹窗 =====

  @Builder
  clearConfirmDialog() {
    Stack() {
      Column() {
        Column() {
          Text('清空对话')
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
            Button('清空')
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

  // ===== 辅助方法 =====

  private canSend(): boolean {
    return this.viewModel !== null && this.viewModel!.canSend;
  }

  private isInitialLoading(): boolean {
    return this.viewModel !== null && this.viewModel!.isInitializing;
  }

  private hasInitError(): boolean {
    return this.viewModel !== null && this.viewModel!.initError.length > 0;
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
    const navInfo = this.queryNavigationInfo();
    if (navInfo !== undefined) {
      navInfo.pathStack.pop();
    }
  }

  private goToModelSettings(): void {
    const navInfo = this.queryNavigationInfo();
    if (navInfo !== undefined) {
      navInfo.pathStack.pushPathByName('ModelSettingsPage', null);
    }
  }

  private goToPresetList(): void {
    const navInfo = this.queryNavigationInfo();
    if (navInfo !== undefined) {
      navInfo.pathStack.pushPathByName('PromptPresetListPage', undefined, () => {
        if (this.viewModel !== null) {
          this.viewModel!.refreshCurrentPresetName();
        }
      });
    }
  }

  private navigateToBranchMap(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    const navInfo = this.queryNavigationInfo();
    if (navInfo === undefined) {
      return;
    }
    navInfo.pathStack.pushPathByName('BranchMapPage', { chatId: chatId }, async (): Promise<void> => {
      if (this.viewModel !== null && !this.viewModel!.isDisposed) {
        await this.viewModel!.reloadAfterBranchChange();
      }
    });
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
        promptAction.showToast({ message: '已复制', duration: 1500 });
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
      promptAction.showToast({ message: '生成中或操作中,无法创建分支', duration: 1500 });
      return;
    }
    this.viewModel!.continueFromAssistant(messageId);
  }

  private generateFromUserMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: '生成中或操作中,无法创建分支', duration: 1500 });
      return;
    }
    this.viewModel!.generateFromUserMessage(messageId);
  }

  private regenerateAssistantMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: '生成中或操作中,无法创建分支', duration: 1500 });
      return;
    }
    this.viewModel!.regenerateAssistantMessage(messageId);
  }

  private openEditUserDialog(messageId: string, originalContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: '生成中或操作中,无法创建分支', duration: 1500 });
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
  }
}
