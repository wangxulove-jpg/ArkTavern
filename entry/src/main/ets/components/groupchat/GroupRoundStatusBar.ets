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
      // 说明:Generating 时不在此显示停止按钮,主操作由底部输入栏承担,
      //       避免状态栏与输入栏同时出现两个停止按钮造成混淆。
      //       Failed 时不在此显示重试/结束按钮,主操作由失败消息气泡内的
      //       GroupGenerationErrorCard 承担,避免同一错误操作堆叠两次。
      if (this.roundStatus === GroupRoundPreviewStatus.Generating) {
        Text($r('app.string.group_stop_round'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
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
