/**
 * WorldLocationNode 地点节点组件(W-UI-1)
 *
 * 地点节点关系图中的单个节点。纯 UI,不依赖 Repository / Service / 数据库。
 *
 * 响应式约定:
 * - 所有会变化的属性使用 @Prop,父级 @State 变化时由 ArkUI 单向同步刷新;
 * - onTap 为函数类型,不能使用 @Prop,保持普通成员(闭包捕获父级 Page this,
 *   Page 实例不变,回调始终指向最新方法);
 * - 节点不保存任何独立选中状态副本,isSelected 完全由父级控制。
 *
 * 显示:
 * - 地点名称
 * - Active / Archived 状态标签(文字,不仅依赖颜色)
 * - 当前角色数量
 * - 出发连接数量
 *
 * 视觉规则:
 * - 选中态:粗边框 + 强调色 + 右上角"选中"圆点
 * - 归档态:整体 opacity 0.55 + "已归档"标签
 * - 颜色仅作辅助,关键状态用文字 + 几何标记传达
 *
 * 不处理:
 * - 移动角色 / 创建连接 / 编辑地点
 * - 点击通过 onTap 回调通知父组件
 */

import { WorldLocationStatus } from '../../models/world/WorldLocation';

@Component
export struct WorldLocationNode {
  /** 地点 ID(不变,用于 onTap 回传) */
  @Prop locationId: string = '';
  /** 地点名称(编辑地点后可能变化) */
  @Prop name: string = '';
  /** 地点状态(归档/激活切换后变化) */
  @Prop status: WorldLocationStatus = WorldLocationStatus.Active;
  /** 当前位置角色数量(角色移动后变化,必须响应式) */
  @Prop characterCount: number = 0;
  /** 从该地点出发的连接数量(连接增删后变化) */
  @Prop outgoingEdgeCount: number = 0;
  /** 是否为用户选中(由父级 selectedLocationId 派生,必须响应式) */
  @Prop isSelected: boolean = false;
  /** 点击回调(函数类型,保持普通成员) */
  onTap: (locationId: string) => void = (_: string) => {};

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        // 第1行:名称
        Text(this.name.length > 0 ? this.name : '(未命名地点)')
          .fontSize(13)
          .fontWeight(this.isSelected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        // 第2行:状态标签(文字,不仅依赖颜色)
        Text(this.resolveStatusLabel())
          .fontSize(10)
          .fontColor(this.status === WorldLocationStatus.Active
            ? $r('app.color.app_accent')
            : $r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ top: 4 })

        // 第3行:统计信息(角色数 / 出发连接数)
        Row() {
          Text(this.characterCount.toString() + ' 角色')
            .fontSize(10)
            .fontColor($r('app.color.app_text_secondary'))

          Text('·')
            .fontSize(10)
            .fontColor($r('app.color.app_text_tertiary'))
            .margin({ left: 6, right: 6 })

          Text(this.outgoingEdgeCount.toString() + ' 连接')
            .fontSize(10)
            .fontColor($r('app.color.app_text_secondary'))
        }
        .width('100%')
        .margin({ top: 6 })
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 10 })
      .borderRadius(12)
      .backgroundColor(this.computeBackgroundColor())
      .borderWidth(this.isSelected ? 2.5 : 1)
      .borderColor(this.isSelected ? $r('app.color.app_accent') : $r('app.color.app_divider'))
      .borderStyle(BorderStyle.Solid)
      .opacity(this.status === WorldLocationStatus.Archived ? 0.55 : 1.0)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.onTap(this.locationId);
      })

      // 选中态:右上角实心圆点(几何标记,不依赖颜色)
      if (this.isSelected) {
        Circle({ width: 10, height: 10 })
          .fill($r('app.color.app_accent'))
          .markAnchor({ x: 5, y: 5 })
          .position({ x: '100%', y: 0 })
          .translate({ x: -8, y: 8 })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 计算节点背景色:
   * - 选中:强调色表面
   * - 默认:普通表面色
   */
  private computeBackgroundColor(): ResourceColor {
    if (this.isSelected) {
      return $r('app.color.app_accent_surface');
    }
    return $r('app.color.app_surface_1');
  }

  /**
   * 解析状态标签文字。
   */
  private resolveStatusLabel(): string {
    if (this.status === WorldLocationStatus.Archived) {
      return '已归档';
    }
    return '活跃';
  }
}
