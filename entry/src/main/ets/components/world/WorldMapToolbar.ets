/**
 * WorldMapToolbar 世界地图工具栏(W-UI-1A)
 *
 * 浮于地图视口上方的半透明工具栏,提供图层、筛选、定位、指南针、
 * 放大、缩小、重置视角等操作入口。
 *
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 * 所有操作通过回调通知父组件。
 */

@Component
export struct WorldMapToolbar {
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
    .backgroundColor($r('app.color.world_toolbar_bg'))
    .borderRadius($r('app.float.world_radius_chip'))
    .borderWidth(1)
    .borderColor($r('app.color.world_border'))
    .padding({ left: 4, right: 4 })
    .justifyContent(FlexAlign.SpaceEvenly)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  toolbarButton(icon: string, action: () => void): void {
    Button(icon)
      .fontSize(16)
      .fontColor($r('app.color.world_text_secondary'))
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
      .color($r('app.color.world_border'))
      .width(1)
  }
}