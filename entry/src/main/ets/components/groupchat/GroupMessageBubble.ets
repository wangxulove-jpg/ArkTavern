/**
 * GroupMessageBubble 群聊消息气泡
 *
 * G-UI-1 预览组件:群聊消息列表中的单条消息。
 *
 * 用户消息:右对齐,accent 背景。
 * 角色消息:左对齐,头像 + 名称(角色强调色)+ 正文 + 状态。
 *
 * 状态支持:streaming / completed / cancelled / failed。
 *
 * 复用 CharacterImageView + ChatPalette.getCharacterColor。
 * 不依赖单聊 ChatMessageBubble / ChatMessageRenderState。
 */

import { CharacterImageView } from '../CharacterImageView';
import { GroupGenerationErrorCard } from './GroupGenerationErrorCard';
import { getCharacterColor } from '../../utils/ChatPalette';
import { GroupChatPreviewMessage } from '../../pages/groupchat/preview/GroupChatPreviewModels';

@Component
export struct GroupMessageBubble {
  /** 消息数据 */
  message: GroupChatPreviewMessage | null = null;
  /** 重试当前角色回调(失败消息时) */
  onRetry: () => void = () => {};
  /** 结束本轮回调(失败消息时) */
  onEndRound: () => void = () => {};

  build(): void {
    if (this.message === null) {
      Column().width('100%')
    } else if (this.message!.senderKind === 'user') {
      this.userBubble()
    } else {
      this.characterBubble()
    }
  }

  /** 用户消息:右对齐 */
  @Builder
  userBubble(): void {
    Column() {
      // 气泡
      Column() {
        Text(this.message!.content)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .width('100%')
      }
      .constraintSize({ maxWidth: '80%' })
      .backgroundColor($r('app.color.app_accent'))
      .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 6 })
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })

      // 时间
      Text(this.formatTime(this.message!.createdAt))
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
        imageUri: this.message!.avatarUri,
        fallbackName: this.message!.senderName,
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
        Text(this.message!.senderName)
          .fontSize($r('app.float.app_font_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.resolveCharacterColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        // 正文(有内容时显示)
        if (this.message!.content.length > 0) {
          Text(this.message!.content)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .width('100%')
            .margin({ top: 4 })
        }

        // streaming:光标 + "正在回复"
        if (this.message!.status === 'streaming') {
          Row() {
            if (this.message!.content.length > 0) {
              Text('▍')
                .fontSize($r('app.float.app_font_body'))
                .fontColor($r('app.color.app_accent'))
                .margin({ left: 2 })
            }
            Text('正在回复')
              .fontSize(11)
              .fontColor($r('app.color.app_text_tertiary'))
              .fontStyle(FontStyle.Italic)
              .margin({ left: 4 })
          }
          .margin({ top: 4 })
        }

        // cancelled:已停止标记
        if (this.message!.status === 'cancelled') {
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

        // failed:失败卡片(重试 + 结束本轮)
        if (this.message!.status === 'failed') {
          GroupGenerationErrorCard({
            errorText: '回复失败,请重试',
            onRetry: (): void => {
              this.onRetry();
            },
            onEndRound: (): void => {
              this.onEndRound();
            }
          })
            .margin({ top: 6 })
        }

        // 时间
        Text(this.formatTime(this.message!.createdAt))
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 4 })
      }
      .constraintSize({ maxWidth: '78%' })
      .backgroundColor($r('app.color.app_surface_1'))
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
  private resolveCharacterColor(): string {
    const id: string = this.message?.senderCharacterId ?? '';
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
}
