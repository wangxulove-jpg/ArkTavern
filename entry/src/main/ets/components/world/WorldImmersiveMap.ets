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
  worldToScreen,
  BILLBOARD_MAX_VISIBLE
} from '../../viewmodels/world/WorldImmersiveMapLayout';
import { WorldLocationMapPlacement } from '../../models/world/WorldLocationMapPlacement';
import { WorldMapBackground, backgroundWorldWidth, backgroundWorldHeight, backgroundCenterX, backgroundCenterY } from '../../models/world/WorldMapBackground';
import { WorldLocationUiModel, WorldEdgeUiModel, WorldCharacterInstanceUiModel } from '../../viewmodels/world/WorldUiModels';
import { WorldMapLocationNode } from './WorldMapLocationNode';
import { WorldMapCharacterBillboard, BillboardCharacterSlotData } from './WorldMapCharacterBillboard';
import { WorldMapToolbar } from './WorldMapToolbar';
import { WorldEmptyState } from './WorldEmptyState';
import { WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { Logger } from '../../utils/Logger';

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
  @Prop mapBackground: WorldMapBackground | null = null;
  @Prop selectedLocationId: string = '';
  @Prop isEditMode: boolean = false;
  @Prop worldStatus: WorldStatus = WorldStatus.Active;
  @Prop viewport: ImmersiveMapViewport = { offsetX: 0, offsetY: 0, zoom: 1.0 };
  @Prop billboardData: NodeBillboardData[] = [];
  /** 数据刷新令牌:父页面在放置/背景等数据变化后递增,触发本组件重渲染 */
  @Prop @Watch('onVersionChange') mapViewVersion: number = 0;

  onVersionChange(): void {
    Logger.info('MapView', 'version changed: ' + this.mapViewVersion.toString()
      + ', mapLayout=' + (this.mapLayout !== null ? this.mapLayout.nodes.length.toString() : 'null')
      + ', bg=' + (this.mapBackground !== null ? this.mapBackground.rotation.toFixed(3) : 'null')
      + ', node0world=(' + (this.mapLayout !== null && this.mapLayout.nodes.length > 0
        ? this.mapLayout.nodes[0].worldX.toFixed(1) + ',' + this.mapLayout.nodes[0].worldY.toFixed(1) : 'n/a') + ')');
  }

  onLocationTap: (locationId: string) => void = (_locationId: string): void => {};
  onLocationLongPress: (locationId: string) => void = (_locationId: string): void => {};
  onLocationDragPreview: (locationId: string, worldX: number, worldY: number) => void = (_id: string, _x: number, _y: number): void => {};
  onLocationDragEnd: (locationId: string, worldX: number, worldY: number) => void = (_id: string, _x: number, _y: number): void => {};
  onZoomIn: () => void = (): void => {};
  onZoomOut: () => void = (): void => {};
  onReset: () => void = (): void => {};
  onLocate: () => void = (): void => {};
  onPan: (dx: number, dy: number) => void = (_dx: number, _dy: number): void => {};
  onRotateLeft: () => void = (): void => {};
  onRotateRight: () => void = (): void => {};
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
          hasBackground: this.mapBackground !== null,
          onLocate: (): void => {
            this.onLocate();
          },
          onZoomIn: (): void => {
            this.onZoomIn();
          },
          onZoomOut: (): void => {
            this.onZoomOut();
          },
          onReset: (): void => {
            this.onReset();
          },
          onRotateLeft: (): void => {
            this.onRotateLeft();
          },
          onRotateRight: (): void => {
            this.onRotateRight();
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
      if (this.mapBackground !== null) {
        this.renderBackgroundImage(this.mapBackground!, layout)
      }

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
            viewport: this.viewport,
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
            onLocationLongPress: (locationId: string): void => {
              this.dragLocationId = locationId;
              this.isDragging = false;
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
              const fx: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
              const fy: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 0;
              const world: number[] = screenToWorld(fx, fy, this.viewport);
              this.onLocationDragPreview(this.dragLocationId, world[0], world[1]);
              this.dragStartX = event.offsetX;
              this.dragStartY = event.offsetY;
            } else {
              this.onPan(dx, dy);
              this.dragStartX = event.offsetX;
              this.dragStartY = event.offsetY;
            }
          })
          .onActionEnd((event: GestureEvent): void => {
            if (this.isDragging && this.dragLocationId.length > 0 && this.mapLayout !== null) {
              const fx: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
              const fy: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 0;
              const world: number[] = screenToWorld(fx, fy, this.viewport);
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
  renderBackgroundImage(background: WorldMapBackground, layout: ImmersiveMapLayout): void {
    Image(background.imageUri)
      .width(this.backgroundScreenW(background))
      .height(this.backgroundScreenH(background))
      .objectFit(ImageFit.Fill)
      .rotate({ angle: this.backgroundRotationDeg(background), centerX: '50%', centerY: '50%' })
      .position({ x: this.backgroundScreenX(background), y: this.backgroundScreenY(background) })
      .hitTestBehavior(HitTestMode.Transparent)
      .key('mapBackground')
  }

  private backgroundScreenW(background: WorldMapBackground): number {
    return backgroundWorldWidth(background) * this.viewport.zoom;
  }

  private backgroundScreenH(background: WorldMapBackground): number {
    return backgroundWorldHeight(background) * this.viewport.zoom;
  }

  private backgroundRotationDeg(background: WorldMapBackground): number {
    return background.rotation * 180 / Math.PI;
  }

  private backgroundScreenX(background: WorldMapBackground): number {
    const centerScreen: number[] = worldToScreen(backgroundCenterX(background), backgroundCenterY(background), this.viewport);
    return centerScreen[0] - this.backgroundScreenW(background) / 2;
  }

  private backgroundScreenY(background: WorldMapBackground): number {
    const centerScreen: number[] = worldToScreen(backgroundCenterX(background), backgroundCenterY(background), this.viewport);
    return centerScreen[1] - this.backgroundScreenH(background) / 2;
  }

  @Builder
  edgeLine(edge: MapEdgeScreenLayout): void {
    Polyline()
      .width(this.edgeWidth(edge))
      .height(this.edgeHeight(edge))
      .position(this.edgePosition(edge))
      .points(this.edgePoints(edge))
      .fillOpacity(0)
      .stroke($r('app.color.world_edge'))
      .strokeWidth(1.5)
      .strokeLineJoin(LineJoinStyle.Round)
      .strokeLineCap(LineCapStyle.Round)
      .strokeDashArray(edge.isEnabled ? [] : [4, 4])
      .opacity(edge.isEnabled ? 0.85 : 0.45)
  }

  private edgeFromScreen(edge: MapEdgeScreenLayout): number[] {
    return worldToScreen(edge.fromWorldX, edge.fromWorldY, this.viewport);
  }

  private edgeToScreen(edge: MapEdgeScreenLayout): number[] {
    return worldToScreen(edge.toWorldX, edge.toWorldY, this.viewport);
  }

  private edgeWidth(edge: MapEdgeScreenLayout): number {
    const from: number[] = this.edgeFromScreen(edge);
    const to: number[] = this.edgeToScreen(edge);
    return Math.abs(to[0] - from[0]) + 4;
  }

  private edgeHeight(edge: MapEdgeScreenLayout): number {
    const from: number[] = this.edgeFromScreen(edge);
    const to: number[] = this.edgeToScreen(edge);
    return Math.abs(to[1] - from[1]) + 4;
  }

  private edgePosition(edge: MapEdgeScreenLayout): Position {
    const from: number[] = this.edgeFromScreen(edge);
    const to: number[] = this.edgeToScreen(edge);
    return {
      x: Math.min(from[0], to[0]) - 2,
      y: Math.min(from[1], to[1]) - 2
    };
  }

  private edgePoints(edge: MapEdgeScreenLayout): number[][] {
    const from: number[] = this.edgeFromScreen(edge);
    const to: number[] = this.edgeToScreen(edge);
    const fromX: number = from[0];
    const fromY: number = from[1];
    const toX: number = to[0];
    const toY: number = to[1];
    const polyLeft: number = Math.min(fromX, toX) - 2;
    const polyTop: number = Math.min(fromY, toY) - 2;
    const midY: number = (fromY + toY) / 2;
    return [
      [fromX - polyLeft, fromY - polyTop],
      [fromX - polyLeft, midY - polyTop],
      [toX - polyLeft, midY - polyTop],
      [toX - polyLeft, toY - polyTop]
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
  @Prop node: MapNodeScreenLayout = { locationId: '', worldX: 0, worldY: 0, screenX: 0, screenY: 0, visualFactor: { scale: 1, opacity: 1, zIndex: 0 }, placement: null };
  @Prop viewport: ImmersiveMapViewport = { offsetX: 0, offsetY: 0, zoom: 1.0 };
  @Prop locationName: string = '';
  @Prop locationStatus: WorldLocationStatus = WorldLocationStatus.Active;
  @Prop characterCount: number = 0;
  @Prop isSelected: boolean = false;
  @Prop billboardSlots: BillboardCharacterSlotData[] = [];
  @Prop billboardOverflow: number = 0;
  @Prop isEditMode: boolean = false;
  onLocationTap: (locationId: string) => void = (_id: string): void => {};
  onLocationLongPress: (locationId: string) => void = (_id: string): void => {};
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
        },
        onLongPress: (locationId: string): void => {
          this.onLocationLongPress(locationId);
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
    .position(this.nodePosition())
    .zIndex(this.node.visualFactor.zIndex)
  }

  private nodePosition(): Position {
    const screen: number[] = worldToScreen(this.node.worldX, this.node.worldY, this.viewport);
    return { x: screen[0] - 60, y: screen[1] - 20 };
  }
}
