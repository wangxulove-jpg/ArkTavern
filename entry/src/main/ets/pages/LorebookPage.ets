/**
 * LorebookPage 世界书页面(静态占位)
 *
 * 正式导航目标,当前仅显示空状态。
 * 不创建虚假可用功能,不调用网络/存储/数据库。
 */

@Component
export struct LorebookPage {
  pathStack: NavPathStack = new NavPathStack();

  build() {
    NavDestination() {
      Column() {
        // 空状态
        Column() {
          Text($r('app.string.nav_lorebook_empty'))
            .fontSize($r('app.float.nav_body_font_size'))
            .fontColor($r('app.color.page_secondary_text'))
            .textAlign(TextAlign.Center)
            .padding(20)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
    }
    .title($r('app.string.nav_lorebook_title'))
    .backgroundColor($r('app.color.page_background'))
  }
}
