/**
 * WorldPrimaryButton 世界模式主操作按钮(W-UI-1A)
 *
 * 暖金色主按钮,用于创建、确认等主要操作。
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 *
 * 注意:属性名 isEnabled / onButtonClick 避免与 CustomComponent 基类方法冲突。
 */

@Component
export struct WorldPrimaryButton {
  label: ResourceStr = '';
  @Prop isEnabled: boolean = true;
  @Prop fullWidth: boolean = false;
  onButtonClick: () => void = (): void => {};

  build() {
    Button(this.label)
      .fontSize($r('app.float.world_font_body'))
      .fontWeight(FontWeight.Medium)
      .fontColor(this.isEnabled
        ? $r('app.color.world_on_gold')
        : $r('app.color.world_text_tertiary'))
      .backgroundColor(this.isEnabled
        ? $r('app.color.world_gold')
        : $r('app.color.world_surface_2'))
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