/**
 * ChatPage 聊天页面
 *
 * 正式聊天页面,支持流式发送、停止、重新生成、复制消息、自动滚动。
 * 本次只做基础文本聊天,不做 Markdown 渲染。
 *
 * 要求:
 * - 页面只通过 ChatViewModel 访问业务能力
 * - 不直接调用 OpenAIProvider/ProviderKeyStore/ProviderConfigStore
 * - 所有 @Builder 方法不传参数,直接访问 this.viewModel
 * - 深色模式可读,长回复不溢出
 * - 不显示 API Key、Base URL 或底层日志
 */

import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { ChatService } from '../services/ChatService';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { MessageSwipeSummary, MAX_SWIPE_CANDIDATES } from '../models/MessageSwipe';
import { MessageSwipeControls } from '../components/MessageSwipeControls';
import { HistoricalMessageEditDialog } from '../components/HistoricalMessageEditDialog';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppServices } from '../services/AppServices';
import { ChatSessionListPanel } from '../components/ChatSessionListPanel';
import { BranchListPanel } from '../components/BranchListPanel';
import { Logger } from '../utils/Logger';

// ===== 资源引用 =====
const RES_NAV_CHAT_TITLE: string = 'nav_chat_title';
const RES_CHAT_EMPTY: string = 'nav_chat_empty';
const RES_CHAT_NO_MODEL: string = 'chat_no_model';
const RES_CHAT_GO_SETTINGS: string = 'chat_go_settings';
const RES_CHAT_INPUT_PLACEHOLDER: string = 'chat_input_placeholder';
const RES_CHAT_SEND: string = 'chat_send';
const RES_CHAT_STOP: string = 'chat_stop';
const RES_CHAT_CLEAR: string = 'chat_clear';
const RES_CHAT_REGENERATE: string = 'chat_regenerate';
const RES_CHAT_COPY: string = 'chat_copy';
const RES_CHAT_COPY_SUCCESS: string = 'chat_copy_success';
const RES_CHAT_SCROLL_BOTTOM: string = 'chat_scroll_to_bottom';
const RES_CHAT_CANCELLED: string = 'chat_cancelled';
const RES_CHAT_FAILED: string = 'chat_failed';
const RES_CHAT_EMPTY_RESPONSE: string = 'chat_empty_response';
const RES_CONTINUE_FROM_HERE: string = 'chat_continue_from_here';
const RES_GENERATE_FROM_USER: string = 'chat_generate_from_user';
const RES_REGENERATE_ASSISTANT: string = 'chat_regenerate_assistant';
const RES_EDIT_USER_MESSAGE: string = 'chat_edit_user_message';
const RES_BRANCH_SWITCH_BUSY: string = 'chat_branch_switch_busy';
const RES_BRANCH_CREATE_BUSY: string = 'chat_branch_create_busy';

const LOG_TAG: string = 'ChatPage';

// ===== 颜色 =====
const COLOR_USER_BUBBLE: string = '#5B7CFA';
const COLOR_USER_TEXT: string = '#FFFFFF';
const COLOR_ASSISTANT_BUBBLE: string = '#F2F2F2';
const COLOR_DIVIDER: string = '#E0E0E0';
const COLOR_STATUS_ERROR: string = '#E74C3C';
const COLOR_STATUS_WARN: string = '#F39C12';

@Entry
@Component
export struct ChatPage {
  @State viewModel: ChatViewModel | null = null;
  /**
   * 独立 @State 消息列表。
   *
   * ArkUI 中 @State 持有 @Observed 对象时,ForEach 对内部数组属性变化的
   * 响应式刷新不完整(实测日志:ForEachNode skip mark dirty)。
   * 通过 onMessagesUpdate 回调将 messages 同步到独立 @State 变量,
   * 确保 ForEach 能检测到数据源引用变化并重新渲染。
   */
  @State messages: ChatMessage[] = [];
  /**
   * T-6.4B-1.2 跨页面 Branch 切换通知。
   *
   * BranchMapPage 切换 Active Branch 成功后,通过 AppStorage.set('branchChangeSeq', Date.now())
   * 递增此序列号。ChatPage 通过 @StorageLink + @Watch 响应变化,触发 reloadAfterBranchChange。
   *
   * 采用此方案的原因:NavDestination 的 .onShown() 用户回调实测不被 ArkUI 调用
   * (系统 onShown 生命周期日志触发,但注册的 .onShown(() => {...}) 回调不执行),
   * pushPathByName 的 onPop 回调也不可靠触发。@StorageLink 是 ArkUI 响应式状态,
   * 跨页面同步可靠。
   */
  @StorageLink('branchChangeSeq') @Watch('onBranchChangeSeqChanged') branchChangeSeq: number = 0;
  private scroller: Scroller = new Scroller();
  private lastMessageCount: number = 0;
  /**
   * T-6.4B-3.1 历史 User 消息编辑弹窗 Controller。
   * 在 openEditUserDialog 中按需重建(传入最新 originalContent 和回调)。
   */
  private editDialogController: CustomDialogController | null = null;
  /** 当前正在编辑的 User Message ID */
  private editingMessageId: string = '';

  aboutToAppear(): void {
    // 每次进入页面创建新的 ChatService(跟随页面生命周期)
    // 避免复用已 disposed 的单例导致 sendMessage 静默失败
    const modelService = AppServices.getModelService();
    const characterService = AppServices.getCharacterService();
    const promptPresetService = AppServices.getPromptPresetService();
    const chatService = AppServices.createChatService();
    const vm: ChatViewModel = new ChatViewModel(chatService, modelService, characterService, promptPresetService);
    // 通过回调将 ViewModel 的 messages 同步到独立 @State 变量
    // 这是确保 ForEach 响应式刷新的关键
    vm.onMessagesUpdate = (msgs: ChatMessage[]): void => {
      this.messages = msgs;
    };
    this.viewModel = vm;
    vm.initialize();
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
      this.viewModel = null;
    }
    this.messages = [];
  }

  onBackPress(): boolean {
    if (this.viewModel !== null) {
      // 删除确认对话框优先关闭
      if (this.viewModel!.showDeleteSessionConfirm) {
        this.viewModel!.cancelDeleteSession();
        return true;
      }
      // Branch 列表面板次优先关闭
      if (this.viewModel!.showBranchList) {
        this.viewModel!.closeBranchList();
        return true;
      }
      // 会话列表面板再次优先关闭
      if (this.viewModel!.showSessionList) {
        this.viewModel!.closeSessionList();
        return true;
      }
    }
    return false;
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          // 顶部状态区
          Row() {
            Text(this.viewModel!.characterName.length > 0
              ? this.viewModel!.characterName + ' · ' + this.viewModel!.currentModelName
              : this.viewModel!.currentModelName)
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (this.viewModel!.statusMessage.length > 0) {
              Text(this.viewModel!.statusMessage)
                .fontSize(13)
                .fontColor(this.viewModel!.isGenerating
                  ? $r('sys.color.ohos_id_color_text_primary')
                  : COLOR_STATUS_WARN)
                .margin({ left: 8 })
            }

            // T-4.5 会话列表入口
            Button('会话')
              .fontSize(13)
              .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .borderRadius(16)
              .height(32)
              .padding({ left: 12, right: 12 })
              .margin({ left: 8 })
              .enabled(this.viewModel!.isSessionReady)
              .onClick(() => {
                this.viewModel!.openSessionList();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          // 预设状态
          Row() {
            Text('预设：' + (this.viewModel!.currentPresetName.length > 0
              ? this.viewModel!.currentPresetName
              : '未启用'))
              .fontSize(12)
              .fontColor(this.viewModel!.currentPresetName.length > 0
                ? '#007AFF'
                : '#999999')
              .onClick(() => {
                const navInfo = this.queryNavigationInfo();
                if (navInfo !== undefined) {
                  navInfo.pathStack.pushPathByName('PromptPresetListPage', undefined, () => {
                    this.viewModel!.refreshCurrentPresetName();
                  });
                }
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })

          // T-6.4B-1.1 Branch 状态入口(点击导航到 BranchMapPage)
          if (this.viewModel!.isSessionReady
            && this.viewModel!.getBranchStatusText().length > 0) {
            Row() {
              Text(this.viewModel!.getBranchStatusText())
                .fontSize(12)
                .fontColor('#007AFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)

              Text('查看')
                .fontSize(12)
                .fontColor(this.viewModel!.busy
                  ? '#999999'
                  : '#007AFF')
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 4 })
            .onClick(() => {
              if (this.viewModel!.busy) {
                promptAction.showToast({
                  message: $r('app.string.' + RES_BRANCH_SWITCH_BUSY),
                  duration: 1500
                });
                return;
              }
              this.navigateToBranchMap();
            })
          }

        if (this.viewModel!.errorMessage.length > 0) {
          Text(this.viewModel!.errorMessage)
            .fontSize(13)
            .fontColor(COLOR_STATUS_ERROR)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 4 })
        }

        // 消息列表区(含浮动回到底部按钮)
        Stack({ alignContent: Alignment.Bottom }) {
          Scroll(this.scroller) {
            Column() {
              if (this.messages.length === 0) {
                if (this.viewModel!.isInitializing) {
                  this.loadingState();
                } else if (this.viewModel!.initError.length > 0) {
                  this.initErrorState();
                } else {
                  this.emptyState();
                }
              } else {
                // key 包含 id + updatedAt + status + contentLength + isStreaming
                // 强制 ForEach 在消息内容/状态变化时重新渲染
                // (ArkUI ForEach 的 diff 基于 key,key 相同会 skip mark dirty)
                ForEach(this.messages, (msg: ChatMessage, _index: number) => {
                  if (msg.role !== ChatRole.System) {
                    Column() {
                      this.messageBubble(msg);
                      if (msg.role === ChatRole.Assistant &&
                        msg.source !== ChatMessageSource.CharacterFirstMessage &&
                        this.viewModel !== null) {
                        MessageSwipeControls({
                          activeCandidateIndex: this.viewModel!.getSwipeSummary(msg.id) !== undefined
                            ? this.viewModel!.getSwipeSummary(msg.id)!.activeCandidateIndex : 0,
                          candidateCount: this.viewModel!.getSwipeSummary(msg.id) !== undefined
                            ? this.viewModel!.getSwipeSummary(msg.id)!.candidateCount : 1,
                          isGenerating: this.viewModel!.isGenerating,
                          isOperable: this.viewModel!.canOperateSwipe(msg.id),
                          isMaxReached: this.viewModel!.getSwipeSummary(msg.id) !== undefined
                            ? this.viewModel!.getSwipeSummary(msg.id)!.candidateCount >= MAX_SWIPE_CANDIDATES
                            : false,
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
                    }
                    .width('100%')
                  }
                }, (msg: ChatMessage) => msg.id + '_' + (msg.updatedAt ?? 0) + '_'
                  + (msg.status ?? '') + '_' + msg.content.length + '_'
                  + (msg.isStreaming === true ? '1' : '0'));
              }
              Blank().height(12);
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onAreaChange(() => {
              this.autoScrollToBottom();
            })
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .height('100%')
          .onScrollEdge((side: Edge) => {
            if (side === Edge.Bottom) {
              this.viewModel!.userScrolledUp = false;
            }
          })
          .onScrollEnd(() => {
            const isAtBottom: boolean = this.scroller.isAtEnd();
            if (isAtBottom) {
              this.viewModel!.userScrolledUp = false;
            }
          })

          // 回到底部浮动按钮
          if (this.viewModel!.userScrolledUp && this.messages.length > 0) {
            Button($r('app.string.' + RES_CHAT_SCROLL_BOTTOM))
              .fontSize(12)
              .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
              .borderRadius(20)
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .margin({ bottom: 12 })
              .onClick(() => {
                this.scroller.scrollEdge(Edge.Bottom);
                this.viewModel!.userScrolledUp = false;
              })
          }
        }
        .layoutWeight(1)
        .width('100%')

        Divider()
          .color(COLOR_DIVIDER)
          .width('100%')
          .height(1)

        // 底部输入区
        Row() {
          Button($r('app.string.' + RES_CHAT_CLEAR))
            .fontSize(13)
            .backgroundColor(Color.Transparent)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .height(36)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.viewModel!.clear();
            })

          TextArea({
            placeholder: $r('app.string.' + RES_CHAT_INPUT_PLACEHOLDER),
            text: this.viewModel!.inputText
          })
            .fontSize(14)
            .maxLines(4)
            .backgroundColor(Color.Transparent)
            .layoutWeight(1)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onChange((value: string) => {
              this.viewModel!.updateInput(value);
            })

          if (this.viewModel!.canRegenerate && !this.viewModel!.isGenerating) {
            Button($r('app.string.' + RES_CHAT_REGENERATE))
              .fontSize(13)
              .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
              .borderRadius(16)
              .height(36)
              .padding({ left: 8, right: 8 })
              .onClick(() => {
                this.viewModel!.regenerate();
              })
          }

          if (this.viewModel!.canStop) {
            Button($r('app.string.' + RES_CHAT_STOP))
              .fontSize(13)
              .backgroundColor(COLOR_STATUS_ERROR)
              .borderRadius(16)
              .height(36)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                this.viewModel!.stop();
              })
          } else {
            Button($r('app.string.' + RES_CHAT_SEND))
              .fontSize(13)
              .backgroundColor(this.viewModel!.canSend
                ? $r('sys.color.ohos_id_color_emphasize')
                : $r('sys.color.ohos_id_color_button_normal'))
              .borderRadius(16)
              .height(36)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                this.viewModel!.send();
              })
          }
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_sub_background'))

      // T-4.5 会话列表面板覆盖层(全屏覆盖在主内容之上)
      if (this.viewModel !== null && this.viewModel!.showSessionList) {
        ChatSessionListPanel({ viewModel: this.viewModel! })
      }

      // T-6.4B-1 Branch 列表面板覆盖层
      if (this.viewModel !== null && this.viewModel!.showBranchList) {
        BranchListPanel({ viewModel: this.viewModel! })
      }
    }
    }
    .title(this.viewModel!.characterName.length > 0
      ? this.viewModel!.characterName
      : $r('app.string.' + RES_NAV_CHAT_TITLE))
    .hideTitleBar(false)
  }

  /**
   * T-6.4B-1.2: BranchMapPage 切换 Active Branch 后触发。
   *
   * 通过 @StorageLink('branchChangeSeq') + @Watch 响应跨页面状态变化,
   * 重新从数据库加载当前会话消息、SwipeSummary、Branch 状态。
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

  // ===== 加载/错误状态 =====

  @Builder
  loadingState() {
    Column() {
      LoadingProgress()
        .width(48)
        .height(48)
        .color($r('sys.color.ohos_id_color_text_secondary'))
        .margin({ bottom: 12 })
      Text('加载会话中…')
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  initErrorState() {
    Column() {
      Text('会话初始化失败')
        .fontSize(16)
        .fontColor(COLOR_STATUS_ERROR)
        .margin({ bottom: 8 })
      Text(this.viewModel!.initError)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 空状态 =====

  @Builder
  emptyState() {
    Column() {
      if (!this.viewModel!.hasCurrentModel) {
        Text($r('app.string.' + RES_CHAT_NO_MODEL))
          .fontSize(16)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .margin({ bottom: 16 })

        Button($r('app.string.' + RES_CHAT_GO_SETTINGS))
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .borderRadius(20)
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .onClick(() => {
            const pathStack: NavPathStack | null = this.getPathStack();
            if (pathStack !== null) {
              pathStack.pushPathByName('ModelSettingsPage', null);
            }
          })
      } else {
        Text($r('app.string.' + RES_CHAT_EMPTY))
          .fontSize(16)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 消息气泡 =====

  @Builder
  messageBubble(msg: ChatMessage) {
    Column() {
      if (msg.role === ChatRole.User) {
        this.userBubble(msg);
      } else {
        this.assistantBubble(msg);
      }
    }
    .width('100%')
  }

  @Builder
  userBubble(msg: ChatMessage) {
    Column() {
      Row() {
        Blank()
          .layoutWeight(1)
        Text(msg.content)
          .fontSize(14)
          .fontColor(COLOR_USER_TEXT)
          .textAlign(TextAlign.Start)
          .wordBreak(WordBreak.BREAK_WORD)
          .backgroundColor(COLOR_USER_BUBBLE)
          .borderRadius({
            topLeft: 16,
            topRight: 16,
            bottomLeft: 16,
            bottomRight: 4
          })
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .margin({ bottom: 4 })
          .constraintSize({ maxWidth: '80%' })
          .onClick(() => {
            this.copyMessage(msg);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      // T-6.4B-2 / T-6.4B-3.1 历史 User 操作区(满足任一条件时显示)
      if (this.viewModel !== null
        && (this.viewModel!.canGenerateFromUserMessage(msg.id)
          || this.viewModel!.canEditUserMessage(msg.id))) {
        Row() {
          // T-6.4B-3.1 编辑(使用编辑后新正文创建新 Branch)
          if (this.viewModel!.canEditUserMessage(msg.id)) {
            Button($r('app.string.' + RES_EDIT_USER_MESSAGE))
              .fontSize(12)
              .backgroundColor(Color.Transparent)
              .fontColor('#007AFF')
              .height(28)
              .padding({ left: 4, right: 4 })
              .onClick(() => {
                this.openEditUserDialog(msg.id, msg.content);
              })
          }

          // T-6.4B-2 从此处生成新回复(使用原 User 正文创建替代 Assistant)
          if (this.viewModel!.canGenerateFromUserMessage(msg.id)) {
            Button($r('app.string.' + RES_GENERATE_FROM_USER))
              .fontSize(12)
              .backgroundColor(Color.Transparent)
              .fontColor('#007AFF')
              .height(28)
              .padding({ left: 4, right: 4 })
              .onClick(() => {
                this.generateFromUserMessage(msg.id);
              })
          }

          Button($r('app.string.' + RES_CHAT_COPY))
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .height(28)
            .padding({ left: 4, right: 4 })
            .onClick(() => {
              this.copyMessage(msg);
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ bottom: 8 })
      }
    }
    .width('100%')
  }

  @Builder
  assistantBubble(msg: ChatMessage) {
    Row() {
      Column() {
        Text(msg.content.length > 0
          ? msg.content
          : (msg.status === ChatMessageStatus.Streaming ? ' ' : ''))
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .textAlign(TextAlign.Start)
          .wordBreak(WordBreak.BREAK_WORD)

        if (msg.isStreaming === true && msg.content.length > 0) {
          Text('|')
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
        }

        if (msg.status === ChatMessageStatus.Cancelled) {
          Text($r('app.string.' + RES_CHAT_CANCELLED))
            .fontSize(12)
            .fontColor(COLOR_STATUS_WARN)
            .margin({ top: 4 })
        }
        if (msg.status === ChatMessageStatus.Failed) {
          Text(msg.errorMessage !== undefined
            ? msg.errorMessage
            : $r('app.string.' + RES_CHAT_FAILED))
            .fontSize(12)
            .fontColor(COLOR_STATUS_ERROR)
            .margin({ top: 4 })
        }
        if (msg.status === ChatMessageStatus.Failed && msg.content.length === 0) {
          Text($r('app.string.' + RES_CHAT_EMPTY_RESPONSE))
            .fontSize(12)
            .fontColor(COLOR_STATUS_ERROR)
            .margin({ top: 4 })
        }

        if (!msg.isStreaming && msg.content.length > 0) {
          Row() {
            // T-6.4B-3 重新生成此回复(仅历史 Assistant 满足条件时显示)
            if (this.viewModel !== null
              && this.viewModel!.canRegenerateAssistantMessage(msg.id)) {
              Button($r('app.string.' + RES_REGENERATE_ASSISTANT))
                .fontSize(12)
                .backgroundColor(Color.Transparent)
                .fontColor('#007AFF')
                .height(28)
                .padding({ left: 4, right: 4 })
                .onClick(() => {
                  this.regenerateAssistantMessage(msg.id);
                })
            }

            // T-6.4B-1 从此处继续(仅历史 Assistant 满足条件时显示)
            if (this.viewModel !== null
              && this.viewModel!.canContinueFromAssistant(msg.id)) {
              Button($r('app.string.' + RES_CONTINUE_FROM_HERE))
                .fontSize(12)
                .backgroundColor(Color.Transparent)
                .fontColor('#007AFF')
                .height(28)
                .padding({ left: 4, right: 4 })
                .onClick(() => {
                  this.continueFromAssistant(msg.id);
                })
            }

            Button($r('app.string.' + RES_CHAT_COPY))
              .fontSize(12)
              .backgroundColor(Color.Transparent)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .height(28)
              .padding({ left: 4, right: 4 })
              .onClick(() => {
                this.copyMessage(msg);
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
          .margin({ top: 4 })
        }
      }
      .backgroundColor(COLOR_ASSISTANT_BUBBLE)
      .borderRadius({
        topLeft: 4,
        topRight: 16,
        bottomLeft: 16,
        bottomRight: 16
      })
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .constraintSize({ maxWidth: '85%' })
      .margin({ bottom: 8 })
      .alignItems(HorizontalAlign.Start)

      Blank()
        .layoutWeight(1)
    }
    .width('100%')
  }

  // ===== 辅助方法 =====

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
        promptAction.showToast({
          message: $r('app.string.' + RES_CHAT_COPY_SUCCESS),
          duration: 1500
        });
      });
    } catch (_e) {
      // 复制失败,静默处理
    }
  }

  private getPathStack(): NavPathStack | null {
    try {
      const navInfo: NavigationInfo | undefined = this.queryNavigationInfo();
      if (navInfo !== undefined) {
        return navInfo.pathStack;
      }
    } catch (_e) {
      // ignore
    }
    return null;
  }

  // ===== T-6.4B-1 Branch 操作 =====

  /**
   * T-6.4B-1.1: 导航到 BranchMapPage。
   * 传入当前 chatId,返回时通过 onPop 回调重新加载消息和 Branch 状态。
   */
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
    navInfo.pathStack.pushPathByName(
      'BranchMapPage',
      { chatId: chatId },
      async (): Promise<void> => {
        // 从 BranchMapPage 返回后重新加载会话
        if (this.viewModel !== null && !this.viewModel!.isDisposed) {
          await this.viewModel!.reloadAfterBranchChange();
        }
      }
    );
  }

  /**
   * 从历史 Assistant 创建 Child Branch。
   * 忙碌时显示提示并退出,由 ViewModel 处理具体逻辑。
   */
  private continueFromAssistant(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({
        message: $r('app.string.' + RES_BRANCH_CREATE_BUSY),
        duration: 1500
      });
      return;
    }
    this.viewModel!.continueFromAssistant(messageId);
  }

  /**
   * T-6.4B-2: 从历史 User 消息生成新回复。
   * 忙碌时显示提示并退出,由 ViewModel 处理具体逻辑。
   */
  private generateFromUserMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({
        message: $r('app.string.' + RES_BRANCH_CREATE_BUSY),
        duration: 1500
      });
      return;
    }
    this.viewModel!.generateFromUserMessage(messageId);
  }

  /**
   * T-6.4B-3: 历史 Assistant "重新生成此回复"。
   * 忙碌时显示提示并退出,由 ViewModel 处理具体逻辑。
   */
  private regenerateAssistantMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({
        message: $r('app.string.' + RES_BRANCH_CREATE_BUSY),
        duration: 1500
      });
      return;
    }
    this.viewModel!.regenerateAssistantMessage(messageId);
  }

  /**
   * T-6.4B-3.1: 打开历史 User 消息编辑弹窗。
   * 忙碌时显示提示并退出。
   * 每次打开按需重建 CustomDialogController,传入最新 originalContent 和回调。
   */
  private openEditUserDialog(messageId: string, originalContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({
        message: $r('app.string.' + RES_BRANCH_CREATE_BUSY),
        duration: 1500
      });
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

  /**
   * T-6.4B-3.1: 编辑弹窗确认回调,调用 ViewModel 执行实际操作。
   */
  private confirmEditUserMessage(messageId: string, editedContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.editUserMessageAndGenerate(messageId, editedContent);
  }
}

