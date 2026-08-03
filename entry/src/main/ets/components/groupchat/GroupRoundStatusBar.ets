/**
 * GroupRoundStatusBar 本轮状态栏
 *
 * G-UI-1 预览组件:GroupChatPage 消息列表下方、输入栏上方的状态条。
 * 展示 Idle / Generating / Completed / Cancelled / Failed 五种状态。
 *
 * 纯 UI,按钮回调由父组件注入,只修改本地预览状态。
 */

import { GroupRoundPreviewStatus } from '../../pages/groupchat/preview/GroupChatPreviewModels';

@Component
export struct GroupRoundStatusBar {
  /** 本轮状态 */
  roundStatus: GroupRoundPreviewStatus = GroupRoundPreviewStatus.Idle;
  /** 已完成回复数 */
  completedCount: number = 0;
  /** 本轮应回复总数 */
  totalCount: number = 0;
  /** 当前正在生成的成员名称 */
  generatingMemberName: string = '';
  /** 停止本轮回调 */
  onStop: () => void = () => {};
  /** 重试回调(失败时) */
  onRetry: () => void = () => {};
  /** 结束本轮回调(失败时) */
  onEndRound: () => void = () => {};

  build(): void {
    Row() {
      // 左侧:状态文字
      Row() {
        if (this.roundStatus === GroupRoundPreviewStatus.Generating) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.app_accent'))
            .margin({ right: 6 })
        }

        Text(this.buildStatusText())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.statusColor())
          .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Center)
      .layoutWeight(1)

      // 右侧:操作按钮
      if (this.roundStatus === GroupRoundPreviewStatus.Generating) {
        Button($r('app.string.group_stop_round'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_danger'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(30)
          .padding({ left: 14, right: 14 })
          .accessibilityText('停止本轮')
          .onClick(() => {
            this.onStop();
          })
      } else if (this.roundStatus === GroupRoundPreviewStatus.Failed) {
        Button($r('app.string.group_retry'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(30)
          .padding({ left: 14, right: 14 })
          .accessibilityText('重试')
          .onClick(() => {
            this.onRetry();
          })

        Button($r('app.string.group_end_round'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(30)
          .padding({ left: 14, right: 14 })
          .margin({ left: 8 })
          .onClick(() => {
            this.onEndRound();
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: { top: 0.5 }, color: $r('app.color.app_divider') })
  }

  /** 构建状态文字 */
  private buildStatusText(): string {
    if (this.roundStatus === GroupRoundPreviewStatus.Idle) {
      return '等待发送';
    }
    if (this.roundStatus === GroupRoundPreviewStatus.Generating) {
      const name: string = this.generatingMemberName.length > 0 ? this.generatingMemberName : '成员';
      return '本轮 ' + String(this.completedCount) + ' / ' + String(this.totalCount) + ' · ' + name + '正在回复';
    }
    if (this.roundStatus === GroupRoundPreviewStatus.Completed) {
      return '本轮完成 · ' + String(this.totalCount) + ' 位角色已回复';
    }
    if (this.roundStatus === GroupRoundPreviewStatus.Cancelled) {
      return '本轮已停止 · ' + String(this.completedCount) + ' / ' + String(this.totalCount) + ' 位角色已回复';
    }
    if (this.roundStatus === GroupRoundPreviewStatus.Failed) {
      const name: string = this.generatingMemberName.length > 0 ? this.generatingMemberName : '成员';
      return name + '回复失败';
    }
    return '';
  }

  /** 状态文字颜色 */
  private statusColor(): ResourceColor {
    if (this.roundStatus === GroupRoundPreviewStatus.Generating) {
      return $r('app.color.app_accent');
    }
    if (this.roundStatus === GroupRoundPreviewStatus.Completed) {
      return $r('app.color.app_text_secondary');
    }
    if (this.roundStatus === GroupRoundPreviewStatus.Cancelled) {
      return $r('app.color.app_text_tertiary');
    }
    if (this.roundStatus === GroupRoundPreviewStatus.Failed) {
      return $r('app.color.app_danger');
    }
    return $r('app.color.app_text_tertiary');
  }
}
