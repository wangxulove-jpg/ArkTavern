/**
 * GroupEmptyState 多人聊天空状态
 *
 * G-UI-1 预览组件:多人聊天首页无群聊时展示。
 * 标题 + 描述 + 创建按钮(CTA)。
 *
 * 纯 UI,不依赖 Service / Repository / 数据库。
 */

@Component
export struct GroupEmptyState {
  /** 空状态标题 */
  title: ResourceStr = '';
  /** 空状态描述 */
  description: ResourceStr = '';
  /** CTA 按钮文字 */
  actionText: ResourceStr = '';
  /** CTA 点击回调 */
  onAction: () => void = () => {};

  build(): void {
    Column() {
      Text(this.title)
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_secondary'))
        .textAlign(TextAlign.Center)
        .width('100%')

      Text(this.description)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 6 })
        .textAlign(TextAlign.Center)
        .width('100%')

      Button(this.actionText)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => {
          this.onAction();
        })
    }
    .width('100%')
    .padding({
      top: $r('app.float.app_spacing_48'),
      bottom: $r('app.float.app_spacing_48'),
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20')
    })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
