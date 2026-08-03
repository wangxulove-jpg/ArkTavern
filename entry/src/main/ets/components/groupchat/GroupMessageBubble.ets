/**
 * GroupMessageBubble 群聊消息气泡(G-RUNTIME-1C-FIX)
 *
 * 重写目的:
 * - 复用单聊 ChatRichText 文字渲染能力(Markdown/字体/行距/代码块)
 * - 采用 @ObjectLink + GroupMessageRenderState 响应式刷新,
 *   与单聊 ChatMessageBubble 保持同一套刷新机制
 * - 保留多人特有的角色头像、角色名称、轮次状态
 * - 不依赖单聊的模型显示/Swipe/Branch/再生控制
 *
 * 状态管理(与单聊一致):
 * - @ObjectLink renderState: GroupMessageRenderState,@Observed 字段赋值即触发重建
 * - ForEach key 固定为 renderState.messageId,组件实例可被复用
 * - 业务层 GroupMessageUiModel 不可变更新后,GroupChatPage 同步调用 renderState.applyMessage,
 *   本气泡无需重建实例即可看到最新 content/isStreaming/status
 *
 * 不依赖:
 * - GroupChatViewModel
 * - 网络/数据库/服务
 * - 单聊模型显示相关组件
 */

import { ChatMessageStatus } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { CharacterImageView } from '../CharacterImageView';
import { ChatRichText, ChatSenderType } from '../ChatRichText';
import { ChatTextStyle } from '../../utils/ChatTextStyleSettings';
import { getCharacterColor } from '../../utils/ChatPalette';
import { GroupMessageRenderState } from '../../viewmodels/groupchat/GroupMessageRenderState';

@Component
export struct GroupMessageBubble {
  /** 稳定渲染状态(@ObjectLink 单向同步,字段赋值触发本组件重建) */
  @ObjectLink renderState: GroupMessageRenderState;
  /** 聊天文本样式设置(复用单聊同一套显示偏好,@Prop 确保父组件样式变化时同步) */
  @Prop settings: ChatTextStyle | null = null;

  build() {
    if (this.renderState.role === ChatRole.User) {
      this.userBubble()
    } else {
      this.characterBubble()
    }
  }

  /** 用户消息:右对齐,复用单聊 ChatRichText 渲染 */
  @Builder
  userBubble(): void {
    Column() {
      // 气泡
      Column() {
        ChatRichText({
          content: this.renderState.content.length > 0 ? this.renderState.content : ' ',
          senderType: 'user' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: false,
          settings: this.settings,
          colorTheme: null,
          selectable: true
        })
      }
      .constraintSize({ maxWidth: '80%' })
      .backgroundColor($r('app.color.chat_user_bubble'))
      .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 6 })
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })

      // G-CONTROL-2A: 多角色回复目标标签(仅指定角色时显示)
      if (this.renderState.replyTargetNames.length > 0) {
        Row() {
          Text(this.formatReplyTargetLabel())
            .fontSize(10)
            .fontColor($r('app.color.app_text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .margin({ top: 2, right: 4 })
      }

      // 时间
      Text(this.formatTime(this.renderState.createdAt))
        .fontSize(10)
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 4, right: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
    .margin({ top: 8, bottom: 8 })
  }

  /** 角色消息:左对齐,头像 + 名称 + 正文 + 状态 */
  @Builder
  characterBubble(): void {
    Row() {
      // 头像
      CharacterImageView({
        imageUri: this.renderState.senderAvatarUri,
        fallbackName: this.renderState.senderName,
        imgWidth: 32,
        imgHeight: 32,
        imgBorderRadius: 16,
        displayMode: 'thumbnail',
        objectFit: ImageFit.Cover
      })
        .alignSelf(ItemAlign.Start)

      // 气泡区
      Column() {
        // 角色名称(使用角色强调色)
        Text(this.renderState.senderName)
          .fontSize($r('app.float.app_font_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.resolveCharacterColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        // 正文(有内容时显示,复用单聊 ChatRichText)
        if (this.renderState.content.length > 0) {
          ChatRichText({
            content: this.renderState.content,
            senderType: 'character' as ChatSenderType,
            senderCharacterId: this.renderState.senderCharacterId,
            isStreaming: this.renderState.isStreaming,
            settings: this.settings,
            colorTheme: null,
            selectable: true
          })
            .margin({ top: 4 })
        }

        // streaming:思考中提示(无内容时)
        if (this.renderState.isStreaming && this.renderState.content.length === 0) {
          Row() {
            LoadingProgress()
              .width(14)
              .height(14)
              .color($r('app.color.app_text_tertiary'))
              .margin({ right: 6 })
            Text('正在思考…')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
          }
          .margin({ top: 4 })
        }

        // streaming:光标 + "生成中"(有内容时)
        if (this.renderState.isStreaming && this.renderState.content.length > 0) {
          Row() {
            Text('▍')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_accent'))
              .margin({ left: 2 })
            Text('生成中…')
              .fontSize(11)
              .fontColor($r('app.color.app_text_tertiary'))
              .fontStyle(FontStyle.Italic)
              .margin({ left: 4 })
          }
          .margin({ top: 4 })
        }

        // cancelled:已停止标记
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

        // failed:失败标记
        if (this.renderState.status === ChatMessageStatus.Failed) {
          Row() {
            Text(this.renderState.content.length === 0 ? '⚠ 未收到回复' : '⚠ 生成失败')
              .fontSize(11)
              .fontColor($r('app.color.app_danger'))
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.chat_status_failed_bg'))
          .borderRadius(8)
          .margin({ top: 6 })
        }

        // 时间
        Text(this.formatTime(this.renderState.createdAt))
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 4 })
      }
      .constraintSize({ maxWidth: '78%' })
      .backgroundColor($r('app.color.chat_assistant_bubble'))
      .borderRadius({ topLeft: 6, topRight: 16, bottomLeft: 16, bottomRight: 16 })
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .margin({ left: 8 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: 8, bottom: 8 })
  }

  /** 解析角色强调色(基于 characterId 稳定生成) */
  private resolveCharacterColor(): ResourceColor {
    const id: string = this.renderState.senderCharacterId;
    if (id.length === 0) {
      return $r('app.color.app_text_secondary');
    }
    if (!this.renderState.characterExists) {
      return $r('app.color.app_danger');
    }
    return getCharacterColor(id);
  }

  /** 格式化时间(HH:mm) */
  private formatTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const hour: string = d.getHours().toString().padStart(2, '0');
    const minute: string = d.getMinutes().toString().padStart(2, '0');
    return hour + ':' + minute;
  }

  /**
   * G-CONTROL-2A: 格式化回复目标标签文案。
   *
   * 规则:
   * - 空数组:返回空字符串(全员回复,不显示标签)
   * - 1 个目标:仅{name}回复
   * - 2~3 个目标且名称总长较短(<=12 字符):仅{n1}、{n2}回复
   * - 名称过多或过长:指定 N 位角色回复
   *
   * 已删除角色名称显示"角色已删除",标签仍可安全显示。
   */
  private formatReplyTargetLabel(): string {
    const names: string[] = this.renderState.replyTargetNames;
    if (names.length === 0) {
      return '';
    }
    if (names.length === 1) {
      return '仅' + names[0] + '回复';
    }
    const joined: string = names.join('、');
    if (names.length <= 3 && joined.length <= 12) {
      return '仅' + joined + '回复';
    }
    return '指定 ' + String(names.length) + ' 位角色回复';
  }
}
