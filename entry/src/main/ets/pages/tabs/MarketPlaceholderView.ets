/**
 * MarketPlaceholderView 市场 Tab 占位视图(UI-1)
 *
 * 作为 HdsTabs 的第三个 Tab 内容,纯 UI 占位页,不发起任何网络请求。
 *
 * 设计:
 * - 顶部标题栏:标题"市场"(与 Tab1/Tab2 顶栏样式一致,不设 backgroundColor 让壁纸透出)
 * - 空状态:使用 SymbolGlyph + 系统空状态布局
 * - 文案说明市场将在后续接入
 *
 * 禁止:
 * - 发起任何网络请求
 * - 添加 MarketRepository / MarketService
 * - 添加登录 / API / 下载
 * - 添加虚假角色数据
 * - 修改数据库版本
 */

@Component
export struct MarketPlaceholderView {
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  build() {
    Stack() {
      Column() {
        // ===== 顶部标题栏(与 Tab1/Tab2 一致,不设 backgroundColor 让壁纸透出) =====
        Row() {
          Text($r('app.string.tab_market'))
            .fontSize($r('app.float.app_font_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_20'),
          right: $r('app.float.app_spacing_20'),
          top: this.statusBarHeight + 8,
          bottom: $r('app.float.app_spacing_8')
        })
        .alignItems(VerticalAlign.Center)

        // 占位空状态区
        Column() {
          SymbolGlyph($r('sys.symbol.star'))
            .fontSize(56)
            .fontColor([$r('app.color.app_text_tertiary')])
            .margin({ bottom: 16 })

          Text($r('app.string.tab_market_placeholder_title'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_secondary'))
            .textAlign(TextAlign.Center)
            .width('100%')

          Text($r('app.string.tab_market_placeholder_desc'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .margin({ top: 6 })
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({
          left: $r('app.float.app_spacing_32'),
          right: $r('app.float.app_spacing_32'),
          bottom: $r('app.float.app_spacing_48')
        })
      }
      .width('100%')
      .height('100%')
      // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .width('100%')
    .height('100%')
    // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}
