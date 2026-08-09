/**
 * WorldBottomActionBar 世界模式底部操作栏(W-UI-1A)
 *
 * 固定在页面底部的操作栏,通常包含主操作按钮。
 * 自动避让底部安全区。
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 */

import { ThemePalette } from '../../theme/ThemePalette';
import { WorldPrimaryButton } from './WorldPrimaryButton';

@Component
export struct WorldBottomActionBar {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  primaryLabel: ResourceStr = '';
  @Prop isPrimaryEnabled: boolean = true;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;
  onPrimary: () => void = (): void => {};
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent(): void {
    Column().width('100%')
  }

  build() {
    Column() {
      this.content()

      if (this.hasLabel(this.primaryLabel)) {
        WorldPrimaryButton({
          label: this.primaryLabel,
          isEnabled: this.isPrimaryEnabled,
          fullWidth: true,
          onButtonClick: (): void => {
            this.onPrimary();
          }
        })
          .width('100%')
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.world_page_padding'),
      right: $r('app.float.world_page_padding'),
      top: 12,
      bottom: this.navBarHeight + 12
    })
    .backgroundColor(this.effectiveTheme === 'tavern' ? '#241A13' : ThemePalette.surface1Color(this.effectiveTheme))
    .borderWidth({ top: 1 })
    .borderColor(ThemePalette.worldBorderColor(this.effectiveTheme))
  }

  private hasLabel(value: ResourceStr): boolean {
    if (typeof value === 'string') {
      return value.length > 0;
    }
    return true;
  }
}