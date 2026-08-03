/**
 * GroupMemberChip 群聊成员芯片
 *
 * G-UI-1 预览组件:成员横向栏中的单个成员展示。
 * 显示顺序号 + 头像 + 名称 + 状态(图标+文字,不只靠颜色)。
 *
 * 纯 UI,复用 CharacterImageView。
 */

import { CharacterImageView } from '../CharacterImageView';
import { GroupChatPreviewMember, GroupMemberPreviewStatus } from '../../pages/groupchat/preview/GroupChatPreviewModels';

@Component
export struct GroupMemberChip {
  /** 成员数据 */
  member: GroupChatPreviewMember | null = null;
  /** 点击成员回调(弹出轻量菜单) */
  onMemberClick: (member: GroupChatPreviewMember) => void = () => {};

  build(): void {
    if (this.member === null) {
      Column().width(64)
    } else {
      Column() {
        // 头像 + 顺序号 + 状态角标
        Stack({ alignContent: Alignment.BottomEnd }) {
          CharacterImageView({
            imageUri: this.member!.avatarUri,
            fallbackName: this.member!.name,
            imgWidth: 44,
            imgHeight: 44,
            imgBorderRadius: 22,
            displayMode: 'thumbnail',
            objectFit: ImageFit.Cover
          })
            .opacity(this.member!.enabled ? 1.0 : 0.4)

          // 顺序号(左上角)
          Text(this.formatOrder(this.member!.order))
            .fontSize(10)
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius(8)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
        }
        .width(44)
        .height(44)
        .alignContent(Alignment.TopStart)

        // 名称(单行截断)
        Text(this.member!.name)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.member!.enabled ? $r('app.color.app_text_primary') : $r('app.color.app_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(56)
          .textAlign(TextAlign.Center)
          .margin({ top: 4 })

        // 状态文字(不只靠颜色,同时显示图标+文字)
        this.statusLabel(this.member!.status, this.member!.enabled)
      }
      .width(64)
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 4, bottom: 4 })
      .onClick(() => {
        if (this.member !== null) {
          this.onMemberClick(this.member!);
        }
      })
    }
  }

  /** 状态标签(图标 + 文字,确保不只靠颜色区分) */
  @Builder
  statusLabel(status: GroupMemberPreviewStatus, enabled: boolean): void {
    if (!enabled) {
      Text('已停用')
        .fontSize(10)
        .fontColor($r('app.color.app_text_tertiary'))
    } else if (status === GroupMemberPreviewStatus.Generating) {
      Row() {
        LoadingProgress()
          .width(10)
          .height(10)
          .color($r('app.color.app_accent'))
        Text('回复中')
          .fontSize(10)
          .fontColor($r('app.color.app_accent'))
          .margin({ left: 2 })
      }
    } else if (status === GroupMemberPreviewStatus.Completed) {
      Text('✓ 完成')
        .fontSize(10)
        .fontColor($r('app.color.app_text_secondary'))
    } else if (status === GroupMemberPreviewStatus.Failed) {
      Text('✗ 失败')
        .fontSize(10)
        .fontColor($r('app.color.app_danger'))
    } else {
      Text('等待')
        .fontSize(10)
        .fontColor($r('app.color.app_text_tertiary'))
    }
  }

  /** order 转为带圈数字(0~7 → ①~⑧) */
  private formatOrder(order: number): string {
    const circles: string[] = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
    if (order >= 0 && order < circles.length) {
      return circles[order];
    }
    return String(order + 1);
  }
}
