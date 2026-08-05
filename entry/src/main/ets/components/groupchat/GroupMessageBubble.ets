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
import {
  computeAssistantBubbleColor,
  computeUserBubbleColor
} from '../../utils/ChatBubbleAppearance';
import { GroupMessageRenderState } from '../../viewmodels/groupchat/GroupMessageRenderState';

@Component
export struct GroupMessageBubble {
  /** 稳定渲染状态(@ObjectLink 单向同步,字段赋值触发本组件重建) */
  @ObjectLink renderState: GroupMessageRenderState;
  /** 聊天文本样式设置(复用单聊同一套显示偏好,@Prop 确保父组件样式变化时同步) */
  @Prop settings: ChatTextStyle | null = null;
  /**
   * G-UI-ALIGN-2A: 气泡背景不透明度(0.40~0.90,仅控制背景 Alpha,不影响文字/头像/按钮)。
   * 与单聊 ChatMessageBubble 共享同一份 Preferences 设置,父组件调节时即时同步。
   */
  @Prop bubbleOpacity: number = 1.0;
  /** G-UI-ALIGN-2A: 当前是否为深色模式(用于动态计算气泡背景 RGB) */
  @Prop isDarkMode: boolean = false;

  build() {
    if (this.renderState.role === ChatRole.User) {
      this.userBubble()
    } else if (this.renderState.senderType === 'narrator') {
      this.narratorBubble()
    } else {
      this.characterBubble()
    }
  }

  /** 旁白消息:居中信息框,淡色背景,小字体,无头像 */
  @Builder
  narratorBubble(): void {
    Column() {
      // 标签:"旁白"
      Text('旁白')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontStyle(FontStyle.Italic)
        .margin({ bottom: 4 })

      // 正文(居中, dimmed)
      if (this.renderState.content.length > 0) {
        ChatRichText({
          content: this.renderState.content,
          senderType: 'narrator' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: this.renderState.isStreaming,
          settings: this.settings,
          colorTheme: null,
          selectable: true
        })
      }

      if (this.renderState.isStreaming && this.renderState.content.length === 0) {
        Text('旁白生成中…')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .fontStyle(FontStyle.Italic)
      }

      if (this.renderState.isStreaming && this.renderState.content.length > 0) {
        Text('▍')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_accent'))
          .margin({ top: 2 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .padding({
      left: 16,
      right: 16,
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_8')
    })
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
      .constraintSize({ maxWidth: '88%' })
      .backgroundColor(computeUserBubbleColor(this.bubbleOpacity, this.isDarkMode))
      .border({
        width: $r('app.float.chat_bubble_border_width'),
        color: $r('app.color.chat_user_border')
      })
      .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 6 })
      .padding({
        left: $r('app.float.chat_bubble_padding_h'),
        right: $r('app.float.chat_bubble_padding_h'),
        top: $r('app.float.chat_bubble_padding_v'),
        bottom: $r('app.float.chat_bubble_padding_v')
      })

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

  /** 角色消息:头像 + 名称在气泡上方,左对齐,对齐单聊 assistantBubble 纵向结构 */
  @Builder
  characterBubble(): void {
    Column() {
      // 头像 + 角色名称行(在气泡上方,对齐单聊头像位置)
      Row() {
        CharacterImageView({
          imageUri: this.renderState.senderAvatarUri,
          fallbackName: this.renderState.senderName,
          imgWidth: 32,
          imgHeight: 32,
          imgBorderRadius: 16,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })

        Text(this.renderState.senderName)
          .fontSize($r('app.float.app_font_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.resolveCharacterColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })
      }
      .margin({ bottom: 6 })

      // 气泡区
      Column() {
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
        }

        // streaming:思考中提示(无内容时,对齐单聊文案)
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

        // streaming:光标(有内容时,对齐单聊:仅光标,无"生成中"文字,避免噪声)
        if (this.renderState.isStreaming && this.renderState.content.length > 0) {
          Text('▍')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_accent'))
            .margin({ top: 2 })
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
      }
      .constraintSize({ maxWidth: '94%' })
      .backgroundColor(computeAssistantBubbleColor(this.bubbleOpacity, this.isDarkMode))
      .border({
        width: $r('app.float.chat_bubble_border_width'),
        color: $r('app.color.chat_assistant_border')
      })
      .borderRadius({ topLeft: 6, topRight: 16, bottomLeft: 16, bottomRight: 16 })
      .padding({
        left: $r('app.float.chat_bubble_padding_h'),
        right: $r('app.float.chat_bubble_padding_h'),
        top: $r('app.float.chat_bubble_padding_v'),
        bottom: $r('app.float.chat_bubble_padding_v')
      })
      .alignItems(HorizontalAlign.Start)
      // 微阴影:让角色气泡在浅色背景上有浮起感(对齐单聊助手气泡)
      .shadow({
        radius: 6,
        color: $r('app.color.chat_assistant_shadow'),
        offsetX: 0,
        offsetY: 2
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
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
