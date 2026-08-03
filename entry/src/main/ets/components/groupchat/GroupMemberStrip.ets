/**
 * GroupMemberStrip 群聊成员横向栏
 *
 * G-UI-1 预览组件:GroupChatPage 顶部标题栏下方的横向成员列表。
 * 横向滚动展示所有成员(GroupMemberChip)。
 *
 * 纯 UI,不依赖 Service / Repository / 数据库。
 */

import { GroupMemberChip } from './GroupMemberChip';
import { GroupChatPreviewMember } from '../../pages/groupchat/preview/GroupChatPreviewModels';

@Component
export struct GroupMemberStrip {
  /** 成员列表 */
  members: GroupChatPreviewMember[] = [];
  /** 点击成员回调 */
  onMemberClick: (member: GroupChatPreviewMember) => void = () => {};

  build(): void {
    Scroll() {
      Row() {
        ForEach(this.members, (member: GroupChatPreviewMember) => {
          GroupMemberChip({
            member: member,
            onMemberClick: (m: GroupChatPreviewMember): void => {
              this.onMemberClick(m);
            }
          })
        }, (member: GroupChatPreviewMember) => member.id + '_' + member.status)
      }
      .padding({ left: 12, right: 12 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(96)
    .backgroundColor($r('app.color.app_bg'))
    .border({ width: { bottom: 0.5 }, color: $r('app.color.app_divider') })
  }
}
