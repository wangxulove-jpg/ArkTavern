/**
 * WorldImmersiveMap 沉浸式地图组件(W1D)
 *
 * 2.5D 沉浸式地图视图,包含:
 * - 分层背景(渐变深色酒馆质感)
 * - 连接线(Polyline)
 * - 地点节点(WorldMapLocationNode)
 * - 角色布告板(WorldMapCharacterBillboard)
 * - 平移/缩放手势
 * - 空状态
 *
 * 纯 UI 组件,不直接依赖 Repository / Service / 数据库。
 * 所有数据通过 props 从父页面注入,操作通过回调通知。
 */

import {
  ImmersiveMapLayout,
  MapNodeScreenLayout,
  MapEdgeScreenLayout,
  ImmersiveMapViewport,
  BillboardLayout,
  screenToWorld,
  BILLBOARD_MAX_VISIBLE
} from '../../viewmodels/world/WorldImmersiveMapLayout';
import { WorldLocationMapPlacement } from '../../models/world/WorldLocationMapPlacement';
import { WorldLocationUiModel, WorldEdgeUiModel, WorldCharacterInstanceUiModel } from '../../viewmodels/world/WorldUiModels';
import { WorldMapLocationNode } from './WorldMapLocationNode';
import { WorldMapCharacterBillboard, BillboardCharacterSlotData } from './WorldMapCharacterBillboard';
import { WorldMapToolbar } from './WorldMapToolbar';
import { WorldEmptyState } from './WorldEmptyState';
import { WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';

export interface NodeBillboardData {
  readonly locationId: string;
  readonly slots: BillboardCharacterSlotData[];
  readonly overflowCount: number;
}

@Component
export struct WorldImmersiveMap {
  @Prop mapLayout: ImmersiveMapLayout | null = null;
  @Prop locations: WorldLocationUiModel[] = [];
  @Prop edges: WorldEdgeUiModel[] = [];
  @Prop characters: WorldCharacterInstanceUiModel[] = [];
  @Prop placements: WorldLocationMapPlacement[] = [];
  @Prop selectedLocationId: string = '';
  @Prop isEditMode: boolean = false;
  @Prop worldStatus: WorldStatus = WorldStatus.Active;
  @Prop viewport: ImmersiveMapViewport = { offsetX: 0, offsetY: 0, zoom: 1.0 };
  @Prop billboardData: NodeBillboardData[] = [];

  onLocationTap: (locationId: string) => void = (_locationId: string): void => {};
  onLocationDragEnd: (locationId: string, worldX: number, worldY: number) => void = (_id: string, _x: number, _y: number): void => {};
  onZoomIn: () => void = (): void => {};
  onZoomOut: () => void = (): void => {};
  onReset: () => void = (): void => {};
  onLocate: () => void = (): void => {};
  onPan: (dx: number, dy: number) => void = (_dx: number, _dy: number): void => {};
  onAddCharacter: () => void = (): void => {};
  onCharacterTap: (instanceId: string) => void = (_instanceId: string): void => {};
  onTravelTo: (instanceId: string, targetLocationId: string) => void = (_instanceId: string, _targetId: string): void => {};
  onOverflowTap: () => void = (): void => {};
  onCreateLocation: () => void = (): void => {};

  private dragLocationId: string = '';
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private isDragging: boolean = false;

  build(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.locations.length === 0) {
        this.emptyStateView()
      } else if (this.mapLayout !== null) {
        this.mapCanvas(this.mapLayout!)
      }

      Row() {
        WorldMapToolbar({
          onLayers: (): void => {},
          onFilter: (): void => {},
          onLocate: (): void => {
            this.onLocate();
          },
          onCompass: (): void => {},
          onZoomIn: (): void => {
            this.onZoomIn();
          },
          onZoomOut: (): void => {
            this.onZoomOut();
          },
          onReset: (): void => {
            this.onReset();
          }
        })
          .width('100%')
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8 })

      if (this.worldStatus === WorldStatus.Active) {
        Stack({ alignContent: Alignment.Center }) {
          Button('+')
            .fontSize(28)
            .fontColor($r('app.color.world_on_gold'))
            .backgroundColor($r('app.color.world_gold'))
            .width(48)
            .height(48)
            .borderRadius(24)
            .shadow({ radius: 8, color: '#4DD4A843', offsetX: 0, offsetY: 4 })
            .onClick(() => {
              this.onAddCharacter();
            })
        }
        .width(48)
        .height(48)
        .position({ x: '100%', y: '100%' })
        .markAnchor({ x: 64, y: 64 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.world_map_bg'))
    .clip(true)
  }

  @Builder
  emptyStateView(): void {
    Column() {
      WorldEmptyState({
        title: $r('app.string.world_ui_map_empty_title'),
        description: $r('app.string.world_ui_map_empty_desc'),
        primaryLabel: this.worldStatus === WorldStatus.Archived
          ? '' : $r('app.string.world_ui_map_empty_add_character'),
        secondaryLabel: this.worldStatus === WorldStatus.Archived
          ? '' : $r('app.string.world_ui_map_empty_create_location'),
        onPrimary: (): void => {
          if (this.worldStatus !== WorldStatus.Archived) {
            this.onAddCharacter();
          }
        },
        onSecondary: (): void => {
          if (this.worldStatus !== WorldStatus.Archived) {
            this.onCreateLocation();
          }
        }
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  mapCanvas(layout: ImmersiveMapLayout): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(layout.edges, (edge: MapEdgeScreenLayout) => {
          this.edgeLine(edge)
        }, (edge: MapEdgeScreenLayout) => edge.edgeId)
      }
      .width(layout.canvasWidth)
      .height(layout.canvasHeight)
      .hitTestBehavior(HitTestMode.Transparent)

      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(layout.nodes, (node: MapNodeScreenLayout) => {
          MapNodeWithBillboard({
            node: node,
            locationName: this.resolveLocationName(node.locationId),
            locationStatus: this.resolveLocationStatus(node.locationId),
            characterCount: this.countCharactersAt(node.locationId),
            isSelected: this.selectedLocationId === node.locationId,
            billboardSlots: this.getBillboardSlots(node.locationId),
            billboardOverflow: this.getBillboardOverflow(node.locationId),
            isEditMode: this.isEditMode,
            onLocationTap: (locationId: string): void => {
              this.onLocationTap(locationId);
            },
            onCharacterTap: (instanceId: string): void => {
              this.onCharacterTap(instanceId);
            },
            onOverflowTap: (): void => {
              this.onOverflowTap();
            }
          })
        }, (node: MapNodeScreenLayout) => node.locationId + '|' + (this.selectedLocationId === node.locationId ? '1' : '0'))
      }
      .width(layout.canvasWidth)
      .height(layout.canvasHeight)
    }
    .width(layout.canvasWidth)
    .height(layout.canvasHeight)
    .clip(true)
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        PanGesture({ fingers: 1, distance: 5 })
          .onActionStart((event: GestureEvent): void => {
            this.isDragging = false;
            this.dragStartX = event.offsetX;
            this.dragStartY = event.offsetY;
          })
          .onActionUpdate((event: GestureEvent): void => {
            const dx: number = event.offsetX - this.dragStartX;
            const dy: number = event.offsetY - this.dragStartY;
            if (this.isEditMode && this.dragLocationId.length > 0) {
              this.isDragging = true;
            } else {
              this.onPan(dx, dy);
              this.dragStartX = event.offsetX;
              this.dragStartY = event.offsetY;
            }
          })
          .onActionEnd((event: GestureEvent): void => {
            if (this.isDragging && this.dragLocationId.length > 0 && this.mapLayout !== null) {
              const world: number[] = screenToWorld(
                event.offsetX, event.offsetY, this.viewport
              );
              this.onLocationDragEnd(this.dragLocationId, world[0], world[1]);
            }
            this.dragLocationId = '';
            this.isDragging = false;
          }),
        PinchGesture({ fingers: 2 })
          .onActionEnd((event: GestureEvent): void => {
            if (event.scale > 1.0) {
              this.onZoomIn();
            } else {
              this.onZoomOut();
            }
          })
      )
    )
  }

  @Builder
  edgeLine(edge: MapEdgeScreenLayout): void {
    Polyline()
      .width(Math.abs(edge.toScreenX - edge.fromScreenX) + 4)
      .height(Math.abs(edge.toScreenY - edge.fromScreenY) + 4)
      .position({
        x: Math.min(edge.fromScreenX, edge.toScreenX) - 2,
        y: Math.min(edge.fromScreenY, edge.toScreenY) - 2
      })
      .points(this.computeEdgePoints(edge))
      .fillOpacity(0)
      .stroke($r('app.color.world_edge'))
      .strokeWidth(1.5)
      .strokeLineJoin(LineJoinStyle.Round)
      .strokeLineCap(LineCapStyle.Round)
      .strokeDashArray(edge.isEnabled ? [] : [4, 4])
      .opacity(edge.isEnabled ? 0.85 : 0.45)
  }

  private computeEdgePoints(edge: MapEdgeScreenLayout): number[][] {
    const polyLeft: number = Math.min(edge.fromScreenX, edge.toScreenX) - 2;
    const polyTop: number = Math.min(edge.fromScreenY, edge.toScreenY) - 2;
    const midY: number = (edge.fromScreenY + edge.toScreenY) / 2;
    return [
      [edge.fromScreenX - polyLeft, edge.fromScreenY - polyTop],
      [edge.fromScreenX - polyLeft, midY - polyTop],
      [edge.toScreenX - polyLeft, midY - polyTop],
      [edge.toScreenX - polyLeft, edge.toScreenY - polyTop]
    ];
  }

  private resolveLocationName(locationId: string): string {
    for (let i: number = 0; i < this.locations.length; i++) {
      if (this.locations[i].id === locationId) {
        return this.locations[i].name;
      }
    }
    return '(未知地点)';
  }

  private resolveLocationStatus(locationId: string): WorldLocationStatus {
    for (let i: number = 0; i < this.locations.length; i++) {
      if (this.locations[i].id === locationId) {
        return this.locations[i].status;
      }
    }
    return WorldLocationStatus.Active;
  }

  private countCharactersAt(locationId: string): number {
    let count: number = 0;
    for (let i: number = 0; i < this.characters.length; i++) {
      if (this.characters[i].currentLocationId === locationId) {
        count = count + 1;
      }
    }
    return count;
  }

  private getBillboardSlots(locationId: string): BillboardCharacterSlotData[] {
    for (let i: number = 0; i < this.billboardData.length; i++) {
      if (this.billboardData[i].locationId === locationId) {
        return this.billboardData[i].slots;
      }
    }
    return [];
  }

  private getBillboardOverflow(locationId: string): number {
    for (let i: number = 0; i < this.billboardData.length; i++) {
      if (this.billboardData[i].locationId === locationId) {
        return this.billboardData[i].overflowCount;
      }
    }
    return 0;
  }
}

@Component
struct MapNodeWithBillboard {
  @Prop node: MapNodeScreenLayout = { locationId: '', screenX: 0, screenY: 0, visualFactor: { scale: 1, opacity: 1, zIndex: 0 }, placement: null };
  @Prop locationName: string = '';
  @Prop locationStatus: WorldLocationStatus = WorldLocationStatus.Active;
  @Prop characterCount: number = 0;
  @Prop isSelected: boolean = false;
  @Prop billboardSlots: BillboardCharacterSlotData[] = [];
  @Prop billboardOverflow: number = 0;
  @Prop isEditMode: boolean = false;
  onLocationTap: (locationId: string) => void = (_id: string): void => {};
  onCharacterTap: (instanceId: string) => void = (_id: string): void => {};
  onOverflowTap: () => void = (): void => {};

  build(): void {
    Column() {
      WorldMapLocationNode({
        locationId: this.node.locationId,
        name: this.locationName,
        status: this.locationStatus,
        characterCount: this.characterCount,
        isSelected: this.isSelected,
        visualScale: this.node.visualFactor.scale,
        visualOpacity: this.node.visualFactor.opacity,
        onTap: (locationId: string): void => {
          this.onLocationTap(locationId);
        }
      })

      if (this.billboardSlots.length > 0 || this.billboardOverflow > 0) {
        WorldMapCharacterBillboard({
          slots: this.billboardSlots,
          overflowCount: this.billboardOverflow,
          onCharacterTap: (instanceId: string): void => {
            this.onCharacterTap(instanceId);
          },
          onOverflowTap: (): void => {
            this.onOverflowTap();
          }
        })
      }
    }
    .position({ x: this.node.screenX - 60, y: this.node.screenY - 20 })
    .zIndex(this.node.visualFactor.zIndex)
  }
}
