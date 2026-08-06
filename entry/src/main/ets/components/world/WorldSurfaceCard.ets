/**
 * WorldSurfaceCard 世界模式表面卡片容器(W-UI-1A)
 *
 * 深色奇幻酒馆质感的卡片容器,大圆角,暖色表面,可选阴影和点击回调。
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 *
 * 使用 @BuilderParam 接收子内容,支持包裹任意子组件。
 */

@Component
export struct WorldSurfaceCard {
  @Prop elevated: boolean = false;
  @Prop radius: number = 16;
  onPress: () => void = (): void => {};
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent(): void {
    Column().width('100%')
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .backgroundColor(this.elevated
      ? $r('app.color.world_surface_elevated')
      : $r('app.color.world_surface_1'))
    .borderRadius(this.radius)
    .borderWidth(1)
    .borderColor($r('app.color.world_border'))
    .shadow(this.elevated
      ? { radius: 12, color: '#66000000', offsetX: 0, offsetY: 4 }
      : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .onClick(() => {
      this.onPress();
    })
  }
}
