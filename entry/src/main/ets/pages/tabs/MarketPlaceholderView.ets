/**
 * MarketPlaceholderView 市场 Tab 占位视图(UI-1)
 *
 * 作为 HdsTabs 的第三个 Tab 内容,纯 UI 占位页,不发起任何网络请求。
 *
 * 设计:
 * - 标题区:应用名 + 简短描述
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

import { AppPageHeader } from '../../components/AppPageHeader';

@Component
export struct MarketPlaceholderView {
  build() {
    Stack() {
      Column() {
        AppPageHeader({
          title: $r('app.string.tab_market'),
          subtitle: $r('app.string.tab_market_subtitle')
        })

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
      .backgroundColor($r('app.color.app_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}
