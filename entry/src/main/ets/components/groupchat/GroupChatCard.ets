/**
 * GroupChatCard 群聊列表卡片
 *
 * G-UI-1 预览组件:多人聊天首页的群聊列表项。
 * 展示头像堆叠 + 标题 + 成员摘要 + 最后消息 + 更新时间。
 *
 * 复用 PressableCard + GroupAvatarStack。
 * 纯 UI,不依赖 Service / Repository / 数据库。
 */

import { PressableCard } from '../PressableCard';
import { GroupAvatarStack, GroupAvatarStackItem } from './GroupAvatarStack';
import { GroupChatPreviewSession } from '../../pages/groupchat/preview/GroupChatPreviewModels';

@Component
export struct GroupChatCard {
  /** 群聊会话数据 */
  session: GroupChatPreviewSession | null = null;
  /** 点击卡片回调 */
  onPress: (session: GroupChatPreviewSession) => void = () => {};
  /** 长按(更多菜单)回调 */
  onMore: (session: GroupChatPreviewSession) => void = () => {};

  build(): void {
    if (this.session === null) {
      Column().width('100%')
    } else {
      PressableCard({
        onPress: () => {
          if (this.session !== null) {
            this.onPress(this.session!);
          }
        },
        surfaceColor: $r('app.color.app_surface_1')
      }) {
        Row() {
          // 左侧:头像堆叠
          GroupAvatarStack({
            items: this.buildAvatarItems(this.session!),
            avatarSize: 36
          })

          // 右侧:文本区
          Column() {
            // 第一行:标题 + 时间
            Row() {
              Text(this.session!.title)
                .fontSize($r('app.float.app_font_body'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)

              // 预览徽标
              Text($r('app.string.group_preview_badge'))
                .fontSize(10)
                .fontColor($r('app.color.app_accent'))
                .backgroundColor($r('app.color.app_accent_surface'))
                .borderRadius(4)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ left: 8 })

              Text(this.formatTime(this.session!.updatedAt))
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
                .margin({ left: 8 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // 第二行:成员名称摘要 + 成员数
            Row() {
              Text(this.buildMemberSummary(this.session!))
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 4 })

            // 第三行:最后消息摘要
            Text(this.buildLastMessageSummary(this.session!))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_12'),
          right: $r('app.float.app_spacing_12'),
          top: $r('app.float.app_spacing_12'),
          bottom: $r('app.float.app_spacing_12')
        })
        .alignItems(VerticalAlign.Center)
        .gesture(
          LongPressGesture()
            .onAction(() => {
              if (this.session !== null) {
                this.onMore(this.session!);
              }
            })
        )
      }
    }
  }

  /** 构建头像堆叠项(最多 4 个) */
  private buildAvatarItems(session: GroupChatPreviewSession): GroupAvatarStackItem[] {
    return session.members.slice(0, 4).map((m): GroupAvatarStackItem => {
      return { name: m.name, avatarUri: m.avatarUri };
    });
  }

  /** 成员名称摘要 + 成员数 */
  private buildMemberSummary(session: GroupChatPreviewSession): string {
    const names: string = session.members.map((m): string => m.name).join('、');
    return names + ' · ' + String(session.members.length) + ' 位角色';
  }

  /** 最后消息摘要 */
  private buildLastMessageSummary(session: GroupChatPreviewSession): string {
    if (session.messages.length === 0) {
      return '还没有消息';
    }
    const last = session.messages[session.messages.length - 1];
    const prefix: string = last.senderKind === 'user' ? '你: ' : last.senderName + ': ';
    return prefix + last.content;
  }

  /** 格式化时间(MM-DD HH:mm) */
  private formatTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    const hour: string = d.getHours().toString().padStart(2, '0');
    const minute: string = d.getMinutes().toString().padStart(2, '0');
    return month + '-' + day + ' ' + hour + ':' + minute;
  }
}
