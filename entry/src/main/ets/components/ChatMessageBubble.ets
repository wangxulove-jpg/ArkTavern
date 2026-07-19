/**
 * ChatMessageBubble 聊天消息气泡
 *
 * 统一渲染 User / Assistant / System 三种消息:
 * - User:右对齐,accent 背景,on_accent 文字,右下角小圆角
 * - Assistant:左对齐,头像 + surface_1 背景,左下角小圆角
 * - System:居中,tertiary 文字,无气泡背景
 *
 * 设计:
 * - 颜色全部使用 $r('app.color.*') 资源,自动适配深色模式
 * - 长按触发 onLongPress 回调(由 ChatPage 打开消息操作菜单)
 * - 点击 Assistant 头像触发 onAvatarClick(可选)
 * - 分支切换控件由父组件 ChatPage 在气泡外渲染(MessageSwipeControls)
 *
 * 不依赖:
 * - ChatViewModel(只接收展示数据 + 回调)
 * - 网络/数据库/服务
 */

import { ChatMessage, ChatMessageStatus, createChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { CharacterImageView } from './CharacterImageView';

@Component
export struct ChatMessageBubble {
  /** 消息对象 */
  msg: ChatMessage = createChatMessage('', ChatRole.User, '', 0);
  /** 角色头像 URI(无角色时为空,显示占位) */
  characterAvatarUri: string = '';
  /** 角色名称(用于头像占位首字) */
  characterName: string = '';
  /** 是否显示 Assistant 头像(空会话开场白也用此组件时不显示) */
  showAvatar: boolean = true;
  /** 长按消息回调 */
  onLongPress?: (msg: ChatMessage) => void;
  /** 点击 Assistant 头像回调(可选) */
  onAvatarClick?: () => void;

  build() {
    if (this.msg.role === ChatRole.System) {
      this.systemBubble()
    } else if (this.msg.role === ChatRole.User) {
      this.userBubble()
    } else {
      this.assistantBubble()
    }
  }

  /** 系统消息:居中、tertiary 文字、无气泡背景 */
  @Builder
  systemBubble() {
    Row() {
      Text(this.msg.content)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontStyle(FontStyle.Italic)
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '80%' })
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 4, bottom: 4 })
  }

  /** User 消息:右对齐,accent 背景 */
  @Builder
  userBubble() {
    Row() {
      Column() {
        Text(this.msg.content.length > 0 ? this.msg.content : ' ')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.chat_user_text'))
          .textAlign(TextAlign.Start)
          .wordBreak(WordBreak.BREAK_WORD)
          .constraintSize({ maxWidth: '78%' })
          .backgroundColor($r('app.color.chat_user_bubble'))
          .borderRadius({
            topLeft: 16, topRight: 16,
            bottomLeft: 16, bottomRight: 4
          })
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .gesture(
            LongPressGesture()
              .onAction(() => {
                if (this.onLongPress !== undefined) {
                  this.onLongPress!(this.msg);
                }
              })
          )
      }
      .alignItems(HorizontalAlign.End)
      .layoutWeight(1)
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
    .margin({ top: 6, bottom: 6 })
  }

  /** Assistant 消息:头像 + 左对齐气泡 */
  @Builder
  assistantBubble() {
    Row() {
      // 头像(可选,空会话等场景不显示)
      if (this.showAvatar) {
        CharacterImageView({
          imageUri: this.characterAvatarUri,
          fallbackName: this.characterName,
          imgWidth: 36,
          imgHeight: 36,
          imgBorderRadius: 18,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })
          .onClick(() => {
            if (this.onAvatarClick !== undefined) {
              this.onAvatarClick!();
            }
          })
      }

      // 气泡
      Column() {
        Text(this.getDisplayContent())
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .textAlign(TextAlign.Start)
          .wordBreak(WordBreak.BREAK_WORD)

        // 流式光标
        if (this.msg.isStreaming === true && this.msg.content.length > 0) {
          Text('▍')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_accent'))
            .margin({ top: 2 })
        }

        // 已停止状态
        if (this.msg.status === ChatMessageStatus.Cancelled) {
          Text('已停止')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .margin({ top: 4 })
        }

        // 失败状态
        if (this.msg.status === ChatMessageStatus.Failed) {
          Row() {
            Text('生成失败')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 4 })
        }
        if (this.msg.status === ChatMessageStatus.Failed && this.msg.content.length === 0) {
          Text('未收到回复,请重试')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 2 })
        }
      }
      .backgroundColor($r('app.color.chat_assistant_bubble'))
      .borderRadius({
        topLeft: 4, topRight: 16,
        bottomLeft: 16, bottomRight: 16
      })
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .constraintSize({ maxWidth: '78%' })
      .margin({ left: this.showAvatar ? 8 : 0 })
      .alignItems(HorizontalAlign.Start)
      .gesture(
        LongPressGesture()
          .onAction(() => {
            if (this.onLongPress !== undefined) {
              this.onLongPress!(this.msg);
            }
          })
      )
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Top)
    .margin({ top: 6, bottom: 6 })
  }

  /** 获取展示内容(空内容时占位空格保持气泡高度) */
  private getDisplayContent(): string {
    if (this.msg.content.length > 0) {
      return this.msg.content;
    }
    if (this.msg.status === ChatMessageStatus.Streaming) {
      return ' ';
    }
    return ' ';
  }
}
