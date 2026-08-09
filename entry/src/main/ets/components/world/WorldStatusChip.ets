/**
 * WorldStatusChip 世界模式状态标签(W-UI-1A)
 *
 * 显示世界或地点的状态标签(活跃/已归档)。
 * 颜色仅辅助,状态用文字明确传达。
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct WorldStatusChip {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  @Prop label: string = '';
  @Prop isActive: boolean = true;

  build() {
    Text(this.label)
      .fontSize($r('app.float.world_font_micro'))
      .fontColor(this.isActive
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.textTertiaryColor(this.effectiveTheme))
      .backgroundColor(this.isActive
        ? (this.effectiveTheme === 'tavern' ? '#3D3220' : $r('app.color.app_accent_surface'))
        : ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.world_radius_chip'))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderWidth(1)
      .borderColor(this.isActive
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.worldBorderColor(this.effectiveTheme))
  }
}
