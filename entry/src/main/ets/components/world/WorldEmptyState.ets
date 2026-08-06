/**
 * WorldEmptyState 世界模式空状态组件(W-UI-1A)
 *
 * 深色酒馆风格的空状态展示,包含图标区域、标题、描述和可选操作按钮。
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 */

import { WorldPrimaryButton } from './WorldPrimaryButton';
import { WorldSecondaryButton } from './WorldSecondaryButton';

@Component
export struct WorldEmptyState {
  title: ResourceStr = '';
  description: ResourceStr = '';
  primaryLabel: ResourceStr = '';
  secondaryLabel: ResourceStr = '';
  onPrimary: () => void = (): void => {};
  onSecondary: () => void = (): void => {};

  build() {
    Column() {
      Column() {
        Text('◯')
          .fontSize(48)
          .fontColor($r('app.color.world_border'))
      }
      .width(80)
      .height(80)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(40)
      .backgroundColor($r('app.color.world_surface_1'))
      .borderWidth(1)
      .borderColor($r('app.color.world_border'))

      if (this.hasValue(this.title)) {
        Text(this.title)
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.world_text_primary'))
          .margin({ top: 16 })
          .textAlign(TextAlign.Center)
      }

      if (this.hasValue(this.description)) {
        Text(this.description)
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ top: 8 })
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (this.hasValue(this.primaryLabel) || this.hasValue(this.secondaryLabel)) {
        Row() {
          if (this.hasValue(this.secondaryLabel)) {
            WorldSecondaryButton({
              label: this.secondaryLabel,
              fullWidth: true,
              onButtonClick: (): void => {
                this.onSecondary();
              }
            })
              .layoutWeight(1)
              .margin({ right: this.hasValue(this.primaryLabel) ? 12 : 0 })
          }
          if (this.hasValue(this.primaryLabel)) {
            WorldPrimaryButton({
              label: this.primaryLabel,
              fullWidth: true,
              onButtonClick: (): void => {
                this.onPrimary();
              }
            })
              .layoutWeight(1)
          }
        }
        .width('100%')
        .margin({ top: 24 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 48, bottom: 48 })
  }

  private hasValue(value: ResourceStr): boolean {
    if (typeof value === 'string') {
      return value.length > 0;
    }
    return true;
  }
}