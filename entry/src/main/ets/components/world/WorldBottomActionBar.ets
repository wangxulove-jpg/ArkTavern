/**
 * WorldBottomActionBar 世界模式底部操作栏(W-UI-1A)
 *
 * 固定在页面底部的操作栏,通常包含主操作按钮。
 * 自动避让底部安全区。
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 */

import { WorldPrimaryButton } from './WorldPrimaryButton';

@Component
export struct WorldBottomActionBar {
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
    .backgroundColor($r('app.color.world_bg'))
    .borderWidth({ top: 1 })
    .borderColor($r('app.color.world_border'))
  }

  private hasLabel(value: ResourceStr): boolean {
    if (typeof value === 'string') {
      return value.length > 0;
    }
    return true;
  }
}