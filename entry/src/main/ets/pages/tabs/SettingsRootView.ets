/**
 * SettingsRootView 设置 Tab 根视图(UI-1)
 *
 * 作为 HdsTabs 的第四个 Tab 内容,聚合现有设置功能入口。
 *
 * 分组:
 * - AI 与对话:模型设置 / 世界书 / 提示词预设
 * - 应用:应用设置
 *
 * 点击入口卡片通过 pathStack 跳转到现有二级页面,不复制业务逻辑。
 */

import { PressableCard } from '../../components/PressableCard';

@Component
export struct SettingsRootView {
  /** AppShell 传入的全局 NavPathStack,用于跳转二级页面 */
  pathStack: NavPathStack = new NavPathStack();
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  build() {
    Stack() {
      Column() {
        // ===== 顶部标题区(与 Tab1/Tab2 一致,不设 backgroundColor 让壁纸透出) =====
        Row() {
          Text($r('app.string.tab_settings'))
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

        // ===== 可滚动内容区 =====
        Scroll() {
          Column() {
            Text($r('app.string.tab_settings_desc'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({
                left: $r('app.float.app_spacing_20'),
                right: $r('app.float.app_spacing_20'),
                bottom: $r('app.float.app_spacing_12')
              })

            // ===== AI 与对话 =====
            this.sectionHeader($r('app.string.tab_settings_section_ai'))

            this.entryCard(
              $r('app.string.tab_settings_model'),
              $r('app.string.tab_settings_model_desc'),
              () => {
                this.pathStack.pushPath({ name: 'ModelSettingsPage' });
              }
            )

            this.entryCard(
              $r('app.string.tab_settings_lorebook'),
              $r('app.string.tab_settings_lorebook_desc'),
              () => {
                this.pathStack.pushPath({ name: 'LorebookPage' });
              }
            )

            this.entryCard(
              $r('app.string.tab_settings_preset'),
              $r('app.string.tab_settings_preset_desc'),
              () => {
                this.pathStack.pushPath({ name: 'PromptPresetListPage' });
              }
            )

            // ===== 应用 =====
            this.sectionHeader($r('app.string.tab_settings_section_app'))

            this.entryCard(
              $r('app.string.tab_settings_app_settings'),
              $r('app.string.tab_settings_app_settings_desc'),
              () => {
                this.pathStack.pushPath({ name: 'AppSettingsPage' });
              }
            )
          }
          .width('100%')
          .padding({
            // 滚动到底部时,最后一项与 Scroll 底部留出视觉间距
            bottom: 80
          })
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .width('100%')
        // margin-bottom 让 Scroll 视口在悬浮 HdsTabs 上方结束,
        // 防止内容落入 TabBar 覆盖区(80vp=TabBar高度 + 20vp缓冲)
        .margin({ bottom: 100 })
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

  /** 分组标题 */
  @Builder
  sectionHeader(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_tertiary'))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20'),
        top: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_8')
      })
  }

  /** 入口卡片 */
  @Builder
  entryCard(title: ResourceStr, desc: ResourceStr, onPress: () => void) {
    Column() {
      PressableCard({ onPress: onPress }) {
        Row() {
          Column() {
            Text(title)
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)

            Text(desc)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('›')
            .fontSize(20)
            .fontColor($r('app.color.app_text_tertiary'))
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_16'),
          right: $r('app.float.app_spacing_16'),
          top: $r('app.float.app_spacing_16'),
          bottom: $r('app.float.app_spacing_16')
        })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_4'),
      bottom: $r('app.float.app_spacing_4')
    })
  }
}
