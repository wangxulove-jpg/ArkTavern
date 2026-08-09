/**
 * WorldSecondaryButton 世界模式次操作按钮(W-UI-1A)
 *
 * 表面色次按钮,用于次要操作(查看历史、取消等)。
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 *
 * 注意:属性名 isEnabled / onButtonClick 避免与 CustomComponent 基类方法冲突。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct WorldSecondaryButton {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  label: ResourceStr = '';
  @Prop isEnabled: boolean = true;
  @Prop fullWidth: boolean = false;
  onButtonClick: () => void = (): void => {};

  build() {
    Button(this.label)
      .fontSize($r('app.float.world_font_body'))
      .fontColor(this.isEnabled
        ? ThemePalette.textSecondaryColor(this.effectiveTheme)
        : ThemePalette.textTertiaryColor(this.effectiveTheme))
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.world_radius_button'))
      .height(44)
      .width(this.fullWidth ? '100%' : undefined)
      .enabled(this.isEnabled)
      .onClick(() => {
        if (this.isEnabled) {
          this.onButtonClick();
        }
      })
  }
}