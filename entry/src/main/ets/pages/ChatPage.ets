/**
 * ChatPage 聊天页面
 *
 * 正式流式聊天页面,提供:
 * - 消息列表(用户/Assistant 气泡)
 * - 底部输入区(多行输入 + 发送/停止/清空按钮)
 * - 顶部状态区(当前模型、生成状态)
 * - 无模型状态提示
 *
 * 页面只通过 ChatViewModel 操作,不直接调用 ChatService/ModelService。
 * 不使用 @Builder 参数传递 ViewModel(直接 @State 绑定)。
 */

import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { ChatService } from '../services/ChatService';
import { AppServices } from '../services/AppServices';
import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';

@Component
export struct ChatPage {
  pathStack: NavPathStack = new NavPathStack();
  @State viewModel: ChatViewModel | null = null;
  @State initError: string = '';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const ms = AppServices.getInstance().modelService;
      const cs: ChatService = new ChatService(ms);
      this.viewModel = new ChatViewModel(cs, ms);
      await this.viewModel.initialize();
    } catch (e) {
      this.initError = '初始化失败,请重试';
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  build() {
    NavDestination() {
      if (this.viewModel === null) {
        this.loadingView()
      } else {
        this.mainView()
      }
    }
    .title($r('app.string.nav_chat_title'))
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  loadingView() {
    Column() {
      if (this.initError.length > 0) {
        Text(this.initError)
          .fontSize($r('app.float.nav_body_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
      } else {
        LoadingProgress()
          .width(36)
          .height(36)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  mainView() {
    Column() {
      this.headerSection()
      this.messageListSection()
      this.inputSection()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  // ===== 顶部状态区 =====

  @Builder
  headerSection() {
    Column() {
      Row() {
        Text(this.viewModel !== null ? this.viewModel.currentModelName : '')
          .fontSize($r('app.float.home_caption_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (this.viewModel !== null && this.viewModel.isGenerating) {
          Text($r('app.string.chat_generating'))
            .fontSize($r('app.float.home_caption_font_size'))
            .fontColor($r('app.color.model_settings_accent'))
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 4 })

      // 错误消息
      if (this.viewModel !== null && this.viewModel.errorMessage.length > 0) {
        Text(this.viewModel.errorMessage)
          .fontSize($r('app.float.home_caption_font_size'))
          .fontColor($r('app.color.model_settings_danger'))
          .padding({ left: 16, right: 16, top: 2, bottom: 4 })
          .width('100%')
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.page_background'))
    .border({ width: { bottom: 0.5 }, color: $r('app.color.chat_divider') })
  }

  // ===== 消息列表区 =====

  @Builder
  messageListSection() {
    if (this.viewModel !== null && !this.viewModel.hasCurrentModel) {
      // 无模型状态
      Column() {
        Text($r('app.string.chat_no_model'))
          .fontSize($r('app.float.nav_body_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
          .margin({ bottom: 12 })

        Button($r('app.string.chat_go_settings'))
          .width(160)
          .height(40)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.model_settings_button_text'))
          .backgroundColor($r('app.color.model_settings_accent'))
          .borderRadius(8)
          .onClick(() => {
            this.pathStack.pushPath({ name: 'ModelSettingsPage' });
          })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.viewModel !== null && this.viewModel.messages.length === 0) {
      // 空状态
      Column() {
        Text($r('app.string.nav_chat_empty'))
          .fontSize($r('app.float.nav_body_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
          .textAlign(TextAlign.Center)
          .padding(20)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      // 消息列表
      Scroll() {
        Column() {
          ForEach(this.viewModel!.messages, (msg: ChatMessage) => {
            this.messageBubble(msg)
          })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .scrollable(ScrollDirection.Vertical)
    }
  }

  @Builder
  messageBubble(msg: ChatMessage) {
    Column() {
      if (msg.role === ChatRole.User) {
        Row() {
          Column() {
            Text(msg.content)
              .fontSize($r('app.float.home_body_font_size'))
              .fontColor($r('app.color.chat_user_text'))
              .textAlign(TextAlign.Start)
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor($r('app.color.chat_user_bubble'))
          .borderRadius(12)
          .constraintSize({ maxWidth: '80%' })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 4, bottom: 4 })
      }

      if (msg.role === ChatRole.Assistant) {
        Column() {
          Row() {
            Column() {
              Text(msg.content)
                .fontSize($r('app.float.home_body_font_size'))
                .fontColor($r('app.color.page_primary_text'))
                .textAlign(TextAlign.Start)

              if (msg.isStreaming === true) {
                Text('|')
                  .fontSize($r('app.float.home_body_font_size'))
                  .fontColor($r('app.color.model_settings_accent'))
                  .margin({ top: 2 })
              }

              if (msg.errorMessage !== undefined && msg.errorMessage.length > 0) {
                Text(msg.errorMessage)
                  .fontSize($r('app.float.home_caption_font_size'))
                  .fontColor($r('app.color.model_settings_danger'))
                  .margin({ top: 4 })
              }
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.chat_assistant_bubble'))
            .borderRadius(12)
            .constraintSize({ maxWidth: '85%' })
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)
          .margin({ top: 4, bottom: 4 })
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  // ===== 底部输入区 =====

  @Builder
  inputSection() {
    Column() {
      // 状态消息
      if (this.viewModel !== null && this.viewModel.statusMessage.length > 0) {
        Text(this.viewModel.statusMessage)
          .fontSize($r('app.float.home_caption_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
          .padding({ left: 12, bottom: 4 })
          .width('100%')
      }

      Row() {
        TextArea({ text: this.viewModel !== null ? this.viewModel.inputText : '', placeholder: $r('app.string.chat_input_placeholder') })
          .width('100%')
          .height(40)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .backgroundColor($r('app.color.model_settings_field_bg'))
          .borderRadius(8)
          .maxLines(3)
          .layoutWeight(1)
          .onChange((v: string) => {
            if (this.viewModel !== null) {
              this.viewModel.updateInput(v);
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8 })

      Row({ space: 8 }) {
        Button($r('app.string.chat_clear'))
          .height(40)
          .fontSize($r('app.float.home_caption_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
          .backgroundColor($r('app.color.model_settings_field_bg'))
          .borderRadius(8)
          .padding({ left: 12, right: 12 })
          .enabled(this.viewModel !== null && this.viewModel.messages.length > 0)
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.clear();
            }
          })

        Blank()

        if (this.viewModel !== null && this.viewModel.isGenerating) {
          Button($r('app.string.chat_stop'))
            .height(40)
            .fontSize($r('app.float.home_body_font_size'))
            .fontColor($r('app.color.model_settings_button_text'))
            .backgroundColor($r('app.color.model_settings_danger'))
            .borderRadius(8)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel.stop();
              }
            })
        }

        Button($r('app.string.chat_send'))
          .height(40)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.model_settings_button_text'))
          .backgroundColor($r('app.color.model_settings_accent'))
          .borderRadius(8)
          .padding({ left: 16, right: 16 })
          .enabled(this.viewModel !== null && this.viewModel.canSend)
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.send();
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    }
    .width('100%')
    .backgroundColor($r('app.color.page_background'))
    .border({ width: { top: 0.5 }, color: $r('app.color.chat_divider') })
  }
}