/**
 * GroupGenerationErrorCard 多人生成失败卡片(G-RUNTIME-1C)
 *
 * 在最近一条 Failed/Cancelled 角色消息下方展示:
 * - 失败说明文字
 * - 重试当前角色按钮(主操作)
 * - 结束本轮按钮(次操作)
 *
 * 重复点击保护:
 * - isRetrying=true:重试按钮进入 Loading 且禁用
 * - isEndingRound=true:结束本轮按钮进入 Loading 且禁用
 *
 * 纯 UI,按钮回调和状态由父组件注入。
 */

@Component
export struct GroupGenerationErrorCard {
  /** 失败说明文字 */
  errorText: ResourceStr = '';
  /** 是否正在重试(防止重复点击) */
  isRetrying: boolean = false;
  /** 是否正在结束本轮(防止重复点击) */
  isEndingRound: boolean = false;
  /** 重试当前角色回调 */
  onRetry: () => void = () => {};
  /** 结束本轮回调 */
  onEndRound: () => void = () => {};

  build(): void {
    Column() {
      Row() {
        Text('⚠')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_danger'))
        Text(this.errorText)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .margin({ left: 6 })
          .layoutWeight(1)
      }
      .width('100%')

      Row() {
        // 主操作:重试当前角色
        Button() {
          Row() {
            if (this.isRetrying) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color($r('app.color.app_on_accent'))
                .margin({ right: 6 })
            }
            Text(this.isRetrying ? $r('app.string.group_retrying') : $r('app.string.group_retry_current'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_on_accent'))
          }
        }
        .type(ButtonType.Capsule)
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 16, right: 16 })
        .key('group.retry_current_btn')
        .accessibilityText('重试当前角色')
        .enabled(!this.isRetrying && !this.isEndingRound)
        .onClick(() => {
          if (!this.isRetrying && !this.isEndingRound) {
            this.onRetry();
          }
        })

        // 次操作:结束本轮
        Button() {
          Row() {
            if (this.isEndingRound) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color($r('app.color.app_text_secondary'))
                .margin({ right: 6 })
            }
            Text(this.isEndingRound ? $r('app.string.group_ending_round') : $r('app.string.group_end_round'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
          }
        }
        .type(ButtonType.Capsule)
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 16, right: 16 })
        .margin({ left: 8 })
        .key('group.end_round_btn')
        .accessibilityText('结束本轮')
        .enabled(!this.isRetrying && !this.isEndingRound)
        .onClick(() => {
          if (!this.isRetrying && !this.isEndingRound) {
            this.onEndRound();
          }
        })
      }
      .width('100%')
      .margin({ top: 8 })
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.chat_status_failed_bg'))
    .borderRadius($r('app.float.app_radius_sm'))
  }
}
