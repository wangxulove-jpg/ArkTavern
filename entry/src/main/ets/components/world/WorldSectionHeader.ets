/**
 * WorldSectionHeader 世界模式分区标题(W-UI-1A)
 *
 * 纯 UI 组件,显示一个分区标题行,可选副标题和右侧操作按钮。
 * 不依赖 Repository / Service / AppServices / 数据库。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct WorldSectionHeader {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  title: ResourceStr = '';
  subtitle: ResourceStr = '';
  actionLabel: ResourceStr = '';
  onAction: () => void = (): void => {};

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize($r('app.float.world_font_section'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.hasValue(this.subtitle)) {
          Text(this.subtitle)
            .fontSize($r('app.float.world_font_micro'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.hasValue(this.actionLabel)) {
        Button(this.actionLabel)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .height(32)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  private hasValue(value: ResourceStr): boolean {
    if (typeof value === 'string') {
      return value.length > 0;
    }
    return true;
  }
}