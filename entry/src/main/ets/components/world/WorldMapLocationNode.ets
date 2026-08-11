/**
 * WorldMapLocationNode 轻量地图节点(W1D)
 *
 * 2.5D 沉浸式地图中的地点节点组件:
 * - 地点图标(状态色圆点)
 * - 地点名称
 * - 角色数量徽标
 * - 选中金色光晕
 * - 长按触发 onLongPress(编辑模式下进入地点拖拽)
 *
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 */

import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldMetrics } from './WorldDesignTokens';

@Component
export struct WorldMapLocationNode {
  @Prop locationId: string = '';
  @Prop name: string = '';
  @Prop status: WorldLocationStatus = WorldLocationStatus.Active;
  @Prop characterCount: number = 0;
  @Prop isSelected: boolean = false;
  @Prop visualScale: number = 1.0;
  @Prop visualOpacity: number = 1.0;
  onTap: (locationId: string) => void = (_locationId: string): void => {};

  build(): void {
    Column() {
      Row() {
        Circle({ width: 10, height: 10 })
          .fill(this.status === WorldLocationStatus.Active
            ? $r('app.color.world_gold')
            : $r('app.color.world_text_tertiary'))

        Text(this.name.length > 0 ? this.name : '(未命名)')
          .fontSize(12)
          .fontColor($r('app.color.world_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 4 })

        if (this.characterCount > 0) {
          Text(this.characterCount.toString())
            .fontSize(9)
            .fontColor($r('app.color.world_on_gold'))
            .backgroundColor($r('app.color.world_gold'))
            .borderRadius(8)
            .width(16)
            .height(16)
            .textAlign(TextAlign.Center)
            .padding({ left: 0, right: 0, top: 0, bottom: 0 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    }
    .width(120)
    .backgroundColor($r('app.color.world_surface_1'))
    .borderRadius($r('app.float.world_radius_chip'))
    .borderWidth(this.isSelected ? 2 : 1)
    .borderColor(this.isSelected ? $r('app.color.world_gold') : $r('app.color.world_border'))
    .shadow(this.isSelected
      ? { radius: 8, color: '#4DD4A843', offsetX: 0, offsetY: 0 }
      : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .opacity(this.visualOpacity)
    .scale({ x: this.visualScale, y: this.visualScale })
    .onClick(() => {
      this.onTap(this.locationId);
    })
    .key('mapNode.' + this.locationId)
  }
}
