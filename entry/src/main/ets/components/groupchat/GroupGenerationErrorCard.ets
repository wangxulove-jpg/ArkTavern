/**
 * GroupGenerationErrorCard 多人生成失败卡片
 *
 * G-UI-1 预览组件:某角色回复失败时在消息气泡中展示。
 * 包含失败说明 + 重试当前角色 + 结束本轮按钮。
 *
 * 纯 UI,按钮回调由父组件注入,只修改本地预览状态。
 */

@Component
export struct GroupGenerationErrorCard {
  /** 失败说明文字 */
  errorText: ResourceStr = '';
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
        Button($r('app.string.group_retry_current'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.onRetry();
          })

        Button($r('app.string.group_end_round'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 16, right: 16 })
          .margin({ left: 8 })
          .onClick(() => {
            this.onEndRound();
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
