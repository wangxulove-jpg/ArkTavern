/**
 * WorldMapToolbar 世界地图工具栏(W-UI-1A)
 *
 * 浮于地图视口上方的半透明工具栏,提供图层、筛选、定位、指南针、
 * 放大、缩小、重置视角等操作入口。
 *
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 * 所有操作通过回调通知父组件。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct WorldMapToolbar {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  onLayers: () => void = (): void => {};
  onFilter: () => void = (): void => {};
  onLocate: () => void = (): void => {};
  onCompass: () => void = (): void => {};
  onZoomIn: () => void = (): void => {};
  onZoomOut: () => void = (): void => {};
  onReset: () => void = (): void => {};

  build() {
    Row() {
      this.toolbarButton('⊞', (): void => { this.onLayers(); })
      this.toolbarDivider()
      this.toolbarButton('☖', (): void => { this.onFilter(); })
      this.toolbarDivider()
      this.toolbarButton('⊕', (): void => { this.onZoomIn(); })
      this.toolbarButton('⊖', (): void => { this.onZoomOut(); })
      this.toolbarDivider()
      this.toolbarButton('⌖', (): void => { this.onLocate(); })
      this.toolbarButton('✦', (): void => { this.onCompass(); })
      this.toolbarButton('↺', (): void => { this.onReset(); })
    }
    .width('100%')
    .height(44)
    .backgroundColor(this.effectiveTheme === 'tavern' ? '#241A13' : ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.world_radius_chip'))
    .borderWidth(1)
    .borderColor(ThemePalette.worldBorderColor(this.effectiveTheme))
    .padding({ left: 4, right: 4 })
    .justifyContent(FlexAlign.SpaceEvenly)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  toolbarButton(icon: string, action: () => void): void {
    Button(icon)
      .fontSize(16)
      .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .borderRadius($r('app.float.world_radius_chip'))
      .onClick(action)
  }

  @Builder
  toolbarDivider(): void {
    Divider()
      .vertical(true)
      .height(20)
      .color(ThemePalette.worldBorderColor(this.effectiveTheme))
      .width(1)
  }
}