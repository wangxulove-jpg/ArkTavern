/**
 * WorldChatMessageBubble 世界场景聊天消息气泡
 *
 * 与 GroupMessageBubble 保持完全一致的 UI 风格:
 * - 用户消息:右对齐,半透明 accent 背景,边框,圆角
 * - 角色消息:左对齐,头像+名称在气泡上方,半透明背景,边框,阴影
 * - 旁白消息:居中,淡色背景,斜体
 * - 支持气泡透明度控制
 * - 复用 ChatRichText 渲染 Markdown
 */

import { ChatRichText, ChatSenderType } from '../ChatRichText';
import { ChatTextStyle } from '../../utils/ChatTextStyleSettings';
import { CharacterImageView } from '../CharacterImageView';
import { getCharacterColor } from '../../utils/ChatPalette';
import {
  computeAssistantBubbleColor,
  computeUserBubbleColor
} from '../../utils/ChatBubbleAppearance';
import {
  ChatMessageUiModel
} from '../../viewmodels/world/WorldSceneChatViewModel';
import {
  WorldSceneMessageSenderType,
  WorldSceneMessageStatus
} from '../../models/world/WorldSceneMessage';
import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct WorldChatMessageBubble {
  @Prop message: ChatMessageUiModel;
  @Prop bubbleOpacity: number = 0.65;
  @Prop isDarkMode: boolean = false;
  @Prop settings: ChatTextStyle | null = null;
  @Prop isStreaming: boolean = false;
  @Prop streamingContent: string = '';
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build() {
    if (this.message.senderType === WorldSceneMessageSenderType.User) {
      this.userBubble()
    } else if (this.message.senderType === WorldSceneMessageSenderType.Narrator) {
      this.narratorBubble()
    } else {
      this.characterBubble()
    }
  }

  @Builder
  narratorBubble(): void {
    Column() {
      Text('旁白')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .fontStyle(FontStyle.Italic)
        .margin({ bottom: 4 })

      if (this.isStreaming && this.streamingContent.length === 0) {
        Row() {
          Text('旁白生成中')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .fontStyle(FontStyle.Italic)
          Text('...')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        }
      }

      if (this.isStreaming && this.streamingContent.length > 0) {
        ChatRichText({
          content: this.streamingContent,
          senderType: 'narrator' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: true,
          settings: this.settings,
          colorTheme: null,
          selectable: true
        })
        Text('▍')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .margin({ top: 2 })
      }

      if (!this.isStreaming && this.message.content.length > 0) {
        ChatRichText({
          content: this.message.content,
          senderType: 'narrator' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: false,
          settings: this.settings,
          colorTheme: null,
          selectable: true
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 12, bottom: 12 })
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .padding({
      left: 16,
      right: 16,
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_8')
    })
  }

  @Builder
  userBubble(): void {
    Column() {
      Column() {
        if (this.isStreaming && this.streamingContent.length > 0) {
          ChatRichText({
            content: this.streamingContent,
            senderType: 'user' as ChatSenderType,
            senderCharacterId: '',
            isStreaming: true,
            settings: this.settings,
            colorTheme: null,
            selectable: true
          })
          Text('▍')
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .margin({ top: 2 })
        } else {
          ChatRichText({
            content: this.message.content.length > 0 ? this.message.content : ' ',
            senderType: 'user' as ChatSenderType,
            senderCharacterId: '',
            isStreaming: false,
            settings: this.settings,
            colorTheme: null,
            selectable: true
          })
        }
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

      Text(this.formatTime(this.message.createdAt))
        .fontSize(10)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 4, right: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
    .margin({ top: 8, bottom: 8 })
  }

  @Builder
  characterBubble(): void {
    Column() {
      Row() {
        CharacterImageView({
          imageUri: this.message.senderAvatarUri,
          fallbackName: this.message.senderFallbackName.length > 0
            ? this.message.senderFallbackName : this.message.senderDisplayName,
          imgWidth: 32,
          imgHeight: 32,
          imgBorderRadius: 16,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })

        Text(this.message.senderDisplayName)
          .fontSize($r('app.float.app_font_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.message.senderRemoved
            ? $r('app.color.app_danger')
            : getCharacterColor(this.message.senderInstanceId))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })
      }
      .margin({ bottom: 6 })

      Column() {
        if (this.isStreaming && this.streamingContent.length === 0) {
          Row() {
            Text('思考中')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .fontStyle(FontStyle.Italic)
            Text('...')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .margin({ left: 2 })
          }
          .margin({ top: 2 })
        }

        if (this.isStreaming && this.streamingContent.length > 0) {
          ChatRichText({
            content: this.streamingContent,
            senderType: 'character' as ChatSenderType,
            senderCharacterId: this.message.senderInstanceId,
            isStreaming: true,
            settings: this.settings,
            colorTheme: null,
            selectable: true
          })
          Text('▍')
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .margin({ top: 2 })
        }

        if (!this.isStreaming && this.message.content.length > 0) {
          ChatRichText({
            content: this.message.content,
            senderType: 'character' as ChatSenderType,
            senderCharacterId: this.message.senderInstanceId,
            isStreaming: false,
            settings: this.settings,
            colorTheme: null,
            selectable: true
          })
        }

        if (this.message.messageStatus === WorldSceneMessageStatus.Cancelled) {
          Row() {
            Text('■ 已停止')
              .fontSize(11)
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.chat_status_stopped_bg'))
          .borderRadius(8)
          .margin({ top: 6 })
        }

        if (this.message.messageStatus === WorldSceneMessageStatus.Failed) {
          Row() {
            Text(this.message.content.length === 0 ? '⚠ 未收到回复' : '⚠ 生成失败')
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

  private formatTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const hour: string = d.getHours().toString().padStart(2, '0');
    const minute: string = d.getMinutes().toString().padStart(2, '0');
    return hour + ':' + minute;
  }
}
