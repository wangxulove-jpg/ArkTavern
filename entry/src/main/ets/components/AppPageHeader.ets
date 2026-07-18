/**
 * AppPageHeader 应用页面顶部标题区
 *
 * UI-0 通用组件,纯 UI,不依赖任何业务 Service / Repository / 数据库。
 *
 * 用途:
 * - 首页或二级页面顶部展示应用 / 模块名称与简短副标题
 * - 左对齐,不嵌入返回按钮(返回按钮由 Navigation 系统标题栏管理)
 *
 * 设计:
 * - 标题:大字号,主文字色
 * - 副标题:中字号,强调色
 *
 * 不处理:
 * - 状态栏安全区(由调用方在 Navigation / NavDestination 处理)
 * - 滚动吸顶
 */

@Component
export struct AppPageHeader {
  /** 主标题(必填,通常为应用名或模块名) */
  title: ResourceStr = '';
  /** 副标题(必填,通常为英文名或分类) */
  subtitle: ResourceStr = '';

  build(): void {
    Column() {
      Text(this.title)
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(this.subtitle)
        .fontSize($r('app.float.app_font_subtitle'))
        .fontColor($r('app.color.app_accent'))
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      top: $r('app.float.app_spacing_24'),
      bottom: $r('app.float.app_spacing_12')
    })
  }
}
