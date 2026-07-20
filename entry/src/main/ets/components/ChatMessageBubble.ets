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
 * 打字机效果:
 * - 通过 @ObjectLink 持有 TypingState(@Observed class),响应字段赋值
 * - 父组件 ChatPage 维护 typingStates 数组,原地修改字段触发响应式
 * - 流式 Assistant 消息:从 0 开始逐字追赶 targetContent
 * - User/System/历史消息:直接显示完整内容
 *
 * 不依赖:
 * - ChatViewModel(只接收展示数据 + 回调)
 * - 网络/数据库/服务
 */

import { ChatMessage, ChatMessageStatus, createChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { CharacterImageView } from './CharacterImageView';
import { TypingState } from '../models/TypingState';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatMessageBubble';

@Component
export struct ChatMessageBubble {
  /** 消息对象(用于读取 role/status 等非高频变化字段) */
  msg: ChatMessage = createChatMessage('', ChatRole.User, '', 0);
  /** 打字机状态(@Observed class),父组件原地修改字段触发响应式 */
  @ObjectLink typingState: TypingState;
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

  /** 打字机当前显示内容 */
  @State displayedContent: string = '';
  /** 打字机定时器句柄,-1 表示未运行 */
  private typingTimerId: number = -1;
  /** 每帧追加字符数(中文 2 字符/帧,平衡流畅度与跟随速度) */
  private static readonly CHARS_PER_TICK: number = 2;
  /** 打字机间隔(ms):约 33fps,肉眼可见的逐字效果 */
  private static readonly TYPING_INTERVAL_MS: number = 30;

  aboutToAppear(): void {
    const role: string = this.msg.role;
    const contentLen: number = this.typingState.content.length;
    const isStreaming: boolean = this.typingState.isStreaming;
    Logger.info(LOG_TAG, 'aboutToAppear | role=' + role
      + ' contentLen=' + contentLen.toString()
      + ' isStreaming=' + isStreaming.toString());
    if (this.typingState.isStreaming && this.msg.role === ChatRole.Assistant) {
      // 流式 Assistant 消息:从空开始打字
      this.displayedContent = '';
      this.startTyping();
    } else {
      // User/System/历史消息:直接显示完整内容,不打字
      this.displayedContent = this.typingState.content;
    }
  }

  aboutToDisappear(): void {
    this.stopTyping();
  }

  /**
   * 监听 typingState 字段变化。
   * 父组件 ChatPage 在 flushMessages 时原地修改 typingState.content / isStreaming,
   * @ObjectLink 会触发本回调。
   */
  aboutToUpdate(): void {
    // do nothing, actual sync happens in startTyping's timer
  }

  /** 启动打字机定时器,追赶 typingState.content */
  private startTyping(): void {
    if (this.typingTimerId !== -1) {
      return;
    }
    this.typingTimerId = setInterval((): void => {
      const target: string = this.typingState.content;
      // 已追上 target:检查是否流式结束
      if (this.displayedContent.length >= target.length) {
        // 流式已结束且已追上:停止定时器
        if (!this.typingState.isStreaming) {
          this.stopTyping();
        }
        // 流式未结束但已追上:等待更多 delta,继续保留定时器
        return;
      }
      // 追赶 target(无论 isStreaming 是否结束,都逐字显示)
      const nextLen: number = Math.min(
        this.displayedContent.length + ChatMessageBubble.CHARS_PER_TICK,
        target.length
      );
      this.displayedContent = target.substring(0, nextLen);
    }, ChatMessageBubble.TYPING_INTERVAL_MS);
  }

  /** 停止打字机定时器 */
  private stopTyping(): void {
    if (this.typingTimerId !== -1) {
      clearInterval(this.typingTimerId);
      this.typingTimerId = -1;
    }
  }

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
      Text(this.displayedContent)
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
        Text(this.displayedContent.length > 0 ? this.displayedContent : ' ')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.chat_user_text'))
          .textAlign(TextAlign.Start)
          .wordBreak(WordBreak.BREAK_WORD)
          .lineHeight(22)
          .constraintSize({ maxWidth: '78%' })
          .backgroundColor($r('app.color.chat_user_bubble'))
          .borderRadius({
            topLeft: 18, topRight: 18,
            bottomLeft: 18, bottomRight: 6
          })
          .padding({ left: 14, right: 14, top: 10, bottom: 12 })
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
          .lineHeight(22)

        // 流式光标(打字机在追赶或流式中)
        if (this.typingState.isStreaming && this.displayedContent.length < this.typingState.content.length) {
          Text('▍')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_accent'))
            .margin({ top: 2 })
        } else if (this.typingState.isStreaming && this.typingState.content.length === 0) {
          // 流式但还没收到任何内容:显示"思考中..."提示(模型推理阶段,首字延迟)
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
        if (this.msg.status === ChatMessageStatus.Cancelled) {
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
        if (this.msg.status === ChatMessageStatus.Failed) {
          Row() {
            Text(this.msg.content.length === 0 ? '⚠ 未收到回复,请重试' : '⚠ 生成失败')
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
        topLeft: 6, topRight: 18,
        bottomLeft: 18, bottomRight: 18
      })
      .padding({ left: 14, right: 14, top: 10, bottom: 12 })
      .constraintSize({ maxWidth: '78%' })
      .margin({ left: this.showAvatar ? 8 : 0 })
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
    if (this.displayedContent.length > 0) {
      return this.displayedContent;
    }
    return ' ';
  }
}
