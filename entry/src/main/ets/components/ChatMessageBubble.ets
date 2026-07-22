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
 * 状态管理(单角色聊天稳定渲染):
 * - @ObjectLink renderState: ChatMessageRenderState,@Observed 字段赋值即触发重建
 * - ForEach key 固定为 renderState.messageId,组件实例可被复用
 * - 业务层 ChatMessage 不可变更新后,ChatPage 同步调用 renderState.applyMessage,
 *   本气泡无需重建实例即可看到最新 content/isStreaming/status
 * - 直接读取 renderState.content / renderState.isStreaming / renderState.status / renderState.role
 * - 不使用 TypingState 中间层、不打字机定时器、不缓存 displayedContent
 * - 流式光标根据 renderState.isStreaming && renderState.content.length > 0 显示
 * - "思考中"提示根据 renderState.isStreaming && renderState.content.length === 0 显示
 *
 * 不依赖:
 * - ChatViewModel(只接收展示数据 + 回调)
 * - 网络/数据库/服务
 */

import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { CharacterImageView } from './CharacterImageView';
import { ChatRichText, ChatSenderType } from './ChatRichText';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';
import { ChatMessageRenderState } from '../models/ChatMessageRenderState';

@Component
export struct ChatMessageBubble {
  /** 稳定渲染状态(@ObjectLink 单向同步,字段赋值触发本组件重建) */
  @ObjectLink renderState: ChatMessageRenderState;
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
  /** 聊天文本样式设置(v11 富文本) */
  settings: ChatTextStyle | null = null;
  /** 发送者角色 ID(用于角色独立颜色) */
  senderCharacterId: string = '';

  build() {
    if (this.renderState.role === ChatRole.System) {
      this.systemBubble()
    } else if (this.renderState.role === ChatRole.User) {
      this.userBubble()
    } else {
      this.assistantBubble()
    }
  }

  aboutToUpdate(): void {
    // 关键不变量检查:状态/流式标志互斥校验,异常时记录便于回归
    const s: ChatMessageStatus = this.renderState.status;
    const isStreaming: boolean = this.renderState.isStreaming;
    if ((s === ChatMessageStatus.Failed || s === ChatMessageStatus.Completed || s === ChatMessageStatus.Cancelled)
      && isStreaming) {
      console.warn(`[Bubble] inconsistency mid=${this.renderState.messageId.slice(0,8)} status=${String(s)} isStreaming=true`);
    }
  }

  /** 系统消息:居中、tertiary 文字、无气泡背景 */
  @Builder
  systemBubble() {
    Row() {
      Column() {
        ChatRichText({
          content: this.renderState.content,
          senderType: 'system' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: false,
          settings: this.settings,
          selectable: true
        })
      }
      .constraintSize({ maxWidth: '80%' })
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 4, bottom: 4 })
  }

  /** User 消息:右对齐,accent 背景(头像在气泡上方) */
  @Builder
  userBubble() {
    Column() {
      // 气泡
      Column() {
        ChatRichText({
          content: this.renderState.content.length > 0 ? this.renderState.content : ' ',
          senderType: 'user' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: false,
          settings: this.settings,
          selectable: true
        })
      }
      .constraintSize({ maxWidth: '94%' })
      .backgroundColor($r('app.color.chat_user_bubble'))
      .borderRadius({
        topLeft: 16, topRight: 16,
        bottomLeft: 16, bottomRight: 6
      })
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .gesture(
        LongPressGesture()
          .onAction(() => {
            if (this.onLongPress !== undefined) {
              this.onLongPress!(this.renderState.message);
            }
          })
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
    .margin({ top: 8, bottom: 8 })
  }

  /** Assistant 消息:头像在气泡上方 + 左对齐气泡 */
  @Builder
  assistantBubble() {
    Column() {
      // 头像(可选,空会话等场景不显示)
      if (this.showAvatar) {
        CharacterImageView({
          imageUri: this.characterAvatarUri,
          fallbackName: this.characterName,
          imgWidth: 32,
          imgHeight: 32,
          imgBorderRadius: 16,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })
          .onClick(() => {
            if (this.onAvatarClick !== undefined) {
              this.onAvatarClick!();
            }
          })
          .margin({ bottom: 6 })
      }

      // 气泡
      Column() {
        // 正文内容(content.length > 0 时显示)
        if (this.renderState.content.length > 0) {
          ChatRichText({
            content: this.renderState.content,
            senderType: 'assistant' as ChatSenderType,
            senderCharacterId: this.senderCharacterId,
            isStreaming: this.renderState.isStreaming,
            settings: this.settings,
            selectable: true
          })
        }

        // 流式光标:流式中且已有正文
        if (this.renderState.isStreaming && this.renderState.content.length > 0) {
          Text('▍')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_accent'))
            .margin({ top: 2 })
        }

        // "思考中"提示:流式中但还没收到任何内容(首字延迟阶段)
        if (this.renderState.isStreaming && this.renderState.content.length === 0) {
          Row() {
            Text('思考中')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .fontStyle(FontStyle.Italic)
            Text('...')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_accent'))
              .margin({ left: 2 })
          }
          .margin({ top: 2 })
        }

        // 已停止状态(带背景小标签)
        if (this.renderState.status === ChatMessageStatus.Cancelled) {
          Row() {
            Text('■ 已停止')
              .fontSize(11)
              .fontColor($r('app.color.app_text_tertiary'))
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.chat_status_stopped_bg'))
          .borderRadius(8)
          .margin({ top: 6 })
        }

        // 失败状态(带背景小标签)
        if (this.renderState.status === ChatMessageStatus.Failed) {
          Row() {
            Text(this.renderState.content.length === 0 ? '⚠ 未收到回复,请重试' : '⚠ 生成失败')
              .fontSize(11)
              .fontColor($r('app.color.app_danger'))
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.chat_status_failed_bg'))
          .borderRadius(8)
          .margin({ top: 6 })
        }
      }
      .backgroundColor($r('app.color.chat_assistant_bubble'))
      .borderRadius({
        topLeft: 6, topRight: 16,
        bottomLeft: 16, bottomRight: 16
      })
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .constraintSize({ maxWidth: '94%' })
      .alignItems(HorizontalAlign.Start)
      // 微阴影:让 Assistant 气泡在浅色背景上有浮起感
      .shadow({
        radius: 6,
        color: $r('app.color.chat_assistant_shadow'),
        offsetX: 0,
        offsetY: 2
      })
      .gesture(
        LongPressGesture()
          .onAction(() => {
            if (this.onLongPress !== undefined) {
              this.onLongPress!(this.renderState.message);
            }
          })
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8, bottom: 8 })
  }
}
