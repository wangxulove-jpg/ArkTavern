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
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppServices } from '../services/AppServices';

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
  private scroller: Scroller = new Scroller();
  private lastMessageCount: number = 0;

  aboutToAppear(): void {
    // 每次进入页面创建新的 ChatService(跟随页面生命周期)
    // 避免复用已 disposed 的单例导致 sendMessage 静默失败
    const modelService = AppServices.getModelService();
    const chatService = new ChatService(modelService);
    const vm: ChatViewModel = new ChatViewModel(chatService, modelService);
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

  build() {
    NavDestination() {
      Column() {
        // 顶部状态区
        Row() {
          Text(this.viewModel!.currentModelName)
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
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

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
                this.emptyState();
              } else {
                // key 包含 id + updatedAt + status + contentLength + isStreaming
                // 强制 ForEach 在消息内容/状态变化时重新渲染
                // (ArkUI ForEach 的 diff 基于 key,key 相同会 skip mark dirty)
                ForEach(this.messages, (msg: ChatMessage, _index: number) => {
                  this.messageBubble(msg);
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
    }
    .title($r('app.string.' + RES_NAV_CHAT_TITLE))
    .hideTitleBar(false)
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
        .margin({ bottom: 8 })
        .constraintSize({ maxWidth: '80%' })
        .onClick(() => {
          this.copyMessage(msg);
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
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
}

