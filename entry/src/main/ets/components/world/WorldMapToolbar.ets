/**
 * WorldMapToolbar 世界地图工具栏(W-UI-1A)
 *
 * 浮于地图视口上方的半透明工具栏,提供定位、放大、缩小、重置视角、
 * 以及背景图旋转(左旋/右旋)等操作入口。
 * 使用文字标签,清晰可读。
 *
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 * 所有操作通过回调通知父组件。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct WorldMapToolbar {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  onLocate: () => void = (): void => {};
  onZoomIn: () => void = (): void => {};
  onZoomOut: () => void = (): void => {};
  onReset: () => void = (): void => {};
  /** 是否有背景图(有则显示旋转按钮) */
  @Prop hasBackground: boolean = false;
  onRotateLeft: () => void = (): void => {};
  onRotateRight: () => void = (): void => {};

  build() {
    Row() {
      this.toolbarButton('定位', (): void => { this.onLocate(); })
      this.toolbarDivider()
      this.toolbarButton('放大', (): void => { this.onZoomIn(); })
      this.toolbarButton('缩小', (): void => { this.onZoomOut(); })
      if (this.hasBackground) {
        this.toolbarDivider()
        this.toolbarButton('左旋', (): void => { this.onRotateLeft(); })
        this.toolbarButton('右旋', (): void => { this.onRotateRight(); })
      }
      this.toolbarDivider()
      this.toolbarButton('重置', (): void => { this.onReset(); })
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
  toolbarButton(label: string, action: () => void): void {
    Button(label)
      .fontSize(13)
      .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      .backgroundColor(Color.Transparent)
      .padding({ left: 12, right: 12 })
      .height(32)
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