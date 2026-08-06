/**
 * WorldStatusChip 世界模式状态标签(W-UI-1A)
 *
 * 显示世界或地点的状态标签(活跃/已归档)。
 * 颜色仅辅助,状态用文字明确传达。
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 */

@Component
export struct WorldStatusChip {
  @Prop label: string = '';
  @Prop isActive: boolean = true;

  build() {
    Text(this.label)
      .fontSize($r('app.float.world_font_micro'))
      .fontColor(this.isActive
        ? $r('app.color.world_gold')
        : $r('app.color.world_text_tertiary'))
      .backgroundColor(this.isActive
        ? $r('app.color.world_gold_surface')
        : $r('app.color.world_surface_2'))
      .borderRadius($r('app.float.world_radius_chip'))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderWidth(1)
      .borderColor(this.isActive
        ? $r('app.color.world_gold_border')
        : $r('app.color.world_border'))
  }
}
