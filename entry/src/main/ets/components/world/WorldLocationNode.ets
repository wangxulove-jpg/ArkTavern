/**
 * WorldLocationNode 地点节点组件(W-UI-1A 重构)
 *
 * 地点节点关系图中的单个节点。纯 UI,不依赖 Repository / Service / 数据库。
 *
 * W-UI-1A 重构:深色奇幻酒馆质感视觉,暖金色选中态,等距氛围阴影。
 * 逻辑接口(locationId / name / status / characterCount / outgoingEdgeCount /
 * isSelected / onTap)保持不变,不影响布局算法和点击行为。
 *
 * 响应式约定:
 * - 所有会变化的属性使用 @Prop,父级 @State 变化时由 ArkUI 单向同步刷新
 * - onTap 为函数类型,保持普通成员
 * - 节点不保存独立选中状态,isSelected 完全由父级控制
 */

import { WorldLocationStatus } from '../../models/world/WorldLocation';

@Component
export struct WorldLocationNode {
  @Prop locationId: string = '';
  @Prop name: string = '';
  @Prop status: WorldLocationStatus = WorldLocationStatus.Active;
  @Prop characterCount: number = 0;
  @Prop outgoingEdgeCount: number = 0;
  @Prop isSelected: boolean = false;
  onTap: (locationId: string) => void = (_: string) => {};

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        Text(this.name.length > 0 ? this.name : '(未命名地点)')
          .fontSize($r('app.float.world_font_body'))
          .fontWeight(this.isSelected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor($r('app.color.world_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Text(this.resolveStatusLabel())
          .fontSize($r('app.float.world_font_micro'))
          .fontColor(this.status === WorldLocationStatus.Active
            ? $r('app.color.world_gold')
            : $r('app.color.world_text_tertiary'))
          .backgroundColor(this.status === WorldLocationStatus.Active
            ? $r('app.color.world_gold_surface')
            : $r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ top: 4 })

        Row() {
          Text(this.characterCount.toString() + ' 角色')
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_secondary'))

          Text('·')
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ left: 6, right: 6 })

          Text(this.outgoingEdgeCount.toString() + ' 连接')
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_secondary'))
        }
        .width('100%')
        .margin({ top: 6 })
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 10 })
      .borderRadius($r('app.float.world_radius_card'))
      .backgroundColor(this.computeBackgroundColor())
      .borderWidth(this.isSelected ? 2 : 1)
      .borderColor(this.isSelected
        ? $r('app.color.world_gold_border')
        : $r('app.color.world_border'))
      .borderStyle(BorderStyle.Solid)
      .shadow(this.isSelected
        ? { radius: 12, color: '#4DD4A843', offsetX: 0, offsetY: 4 }
        : { radius: 6, color: '#33000000', offsetX: 0, offsetY: 2 })
      .opacity(this.status === WorldLocationStatus.Archived ? 0.55 : 1.0)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.onTap(this.locationId);
      })

      if (this.isSelected) {
        Circle({ width: 10, height: 10 })
          .fill($r('app.color.world_gold'))
          .markAnchor({ x: 5, y: 5 })
          .position({ x: '100%', y: 0 })
          .translate({ x: -8, y: 8 })
      }
    }
    .width('100%')
    .height('100%')
  }

  private computeBackgroundColor(): ResourceColor {
    if (this.isSelected) {
      return $r('app.color.world_gold_surface');
    }
    return $r('app.color.world_surface_elevated');
  }

  private resolveStatusLabel(): string {
    if (this.status === WorldLocationStatus.Archived) {
      return '已归档';
    }
    return '活跃';
  }
}
