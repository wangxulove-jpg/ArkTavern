/**
 * WorldPrimaryButton 世界模式主操作按钮(W-UI-1A)
 *
 * 暖金色主按钮,用于创建、确认等主要操作。
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 *
 * 注意:属性名 isEnabled / onButtonClick 避免与 CustomComponent 基类方法冲突。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct WorldPrimaryButton {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  label: ResourceStr = '';
  @Prop isEnabled: boolean = true;
  @Prop fullWidth: boolean = false;
  @Prop fontSize: Resource = $r('app.float.world_font_body');
  @Prop buttonHeight: number = 44;
  onButtonClick: () => void = (): void => {};

  build() {
    Button(this.label)
      .fontSize(this.fontSize)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.isEnabled
        ? (this.effectiveTheme === 'tavern' ? '#1A1510' : $r('app.color.app_on_accent'))
        : ThemePalette.textTertiaryColor(this.effectiveTheme))
      .backgroundColor(this.isEnabled
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.world_radius_button'))
      .height(this.buttonHeight)
      .width(this.fullWidth ? '100%' : undefined)
      .enabled(this.isEnabled)
      .onClick(() => {
        if (this.isEnabled) {
          this.onButtonClick();
        }
      })
  }
}