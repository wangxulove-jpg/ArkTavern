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

  onLocationTap: (locationId: string) => void = (_locationId: string): void => {};
  onLocationDragStart: (locationId: string) => void = (_locationId: string): void => {};
  onLocationDragPreview: (locationId: string, worldX: number, worldY: number) => void = (_id: string, _x: number, _y: number): void => {};
  onLocationDragEnd: (locationId: string, worldX: number, worldY: number) => void = (_id: string, _x: number, _y: number): void => {};
  onZoomIn: () => void = (): void => {};
  onZoomOut: () => void = (): void => {};
  onReset: () => void = (): void => {};
  onLocate: () => void = (): void => {};
  onPan: (dx: number, dy: number) => void = (_dx: number, _dy: number): void => {};
  onPinchZoom: (targetZoom: number, centerScreenX: number, centerScreenY: number) => void = (_z: number, _x: number, _y: number): void => {};
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
  private pinchStartZoom: number = 1.0;

  build(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.locations.length === 0) {
        this.emptyStateView()
      } else if (this.mapLayout !== null) {
        this.mapCanvas()
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
  mapCanvas(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.mapBackground !== null) {
        this.renderBackgroundImage()
      }

      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.mapLayout!.edges, (edge: MapEdgeScreenLayout) => {
          this.edgeLine(edge)
        }, (edge: MapEdgeScreenLayout) => edge.edgeId
          + '|' + edge.fromWorldX.toFixed(1) + '|' + edge.fromWorldY.toFixed(1)
          + '|' + edge.toWorldX.toFixed(1) + '|' + edge.toWorldY.toFixed(1)
          + '|' + this.viewport.offsetX.toFixed(1) + '|' + this.viewport.offsetY.toFixed(1)
          + '|' + this.viewport.zoom.toFixed(3))
      }
      .width(this.mapLayout!.canvasWidth)
      .height(this.mapLayout!.canvasHeight)
      .hitTestBehavior(HitTestMode.Transparent)

      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.mapLayout!.nodes, (node: MapNodeScreenLayout) => {
          this.mapNodeWithBillboard(node)
        }, (node: MapNodeScreenLayout) => node.locationId
          + '|' + node.worldX.toFixed(1) + '|' + node.worldY.toFixed(1)
          + '|' + this.viewport.offsetX.toFixed(1) + '|' + this.viewport.offsetY.toFixed(1)
          + '|' + this.viewport.zoom.toFixed(3)
          + '|' + (this.selectedLocationId === node.locationId ? '1' : '0'))
      }
      .width(this.mapLayout!.canvasWidth)
      .height(this.mapLayout!.canvasHeight)
    }
    .width(this.mapLayout!.canvasWidth)
    .height(this.mapLayout!.canvasHeight)
    .clip(true)
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        GestureGroup(GestureMode.Sequence,
          LongPressGesture({ repeat: false, duration: 300 })
            .onAction((event: GestureEvent): void => {
              this.handleCanvasLongPress(event);
            }),
          PanGesture({ fingers: 1, distance: 1 })
            .onActionUpdate((event: GestureEvent): void => {
              this.handleDragUpdate(event);
            })
            .onActionEnd((event: GestureEvent): void => {
              this.handleDragEnd(event);
            })
        ),
        PanGesture({ fingers: 1, distance: 5 })
          .onActionStart((event: GestureEvent): void => {
            this.dragStartX = event.offsetX;
            this.dragStartY = event.offsetY;
          })
          .onActionUpdate((event: GestureEvent): void => {
            this.handlePan(event);
          }),
        PinchGesture({ fingers: 2 })
          .onActionStart((): void => {
            this.pinchStartZoom = this.viewport.zoom;
          })
          .onActionUpdate((event: GestureEvent): void => {
            const targetZoom: number = this.pinchStartZoom * event.scale;
            this.onPinchZoom(targetZoom, event.pinchCenterX, event.pinchCenterY);
          })
          .onActionEnd((): void => {
          })
      )
    )
  }

  @Builder
  renderBackgroundImage(): void {
    Image(this.mapBackground!.imageUri)
      .width(this.backgroundScreenW(this.mapBackground!))
      .height(this.backgroundScreenH(this.mapBackground!))
      .objectFit(ImageFit.Fill)
      .rotate({ angle: this.backgroundRotationDeg(this.mapBackground!), centerX: '50%', centerY: '50%' })
      .position({ x: this.backgroundScreenX(this.mapBackground!), y: this.backgroundScreenY(this.mapBackground!) })
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

  @Builder
  mapNodeWithBillboard(node: MapNodeScreenLayout): void {
    Column() {
      WorldMapLocationNode({
        locationId: node.locationId,
        name: this.resolveLocationName(node.locationId),
        status: this.resolveLocationStatus(node.locationId),
        characterCount: this.countCharactersAt(node.locationId),
        isSelected: this.selectedLocationId === node.locationId,
        visualScale: node.visualFactor.scale,
        visualOpacity: node.visualFactor.opacity,
        onTap: (locationId: string): void => {
          this.onLocationTap(locationId);
        }
      })

      if (this.getBillboardSlots(node.locationId).length > 0 || this.getBillboardOverflow(node.locationId) > 0) {
        WorldMapCharacterBillboard({
          slots: this.getBillboardSlots(node.locationId),
          overflowCount: this.getBillboardOverflow(node.locationId),
          onCharacterTap: (instanceId: string): void => {
            this.onCharacterTap(instanceId);
          },
          onOverflowTap: (): void => {
            this.onOverflowTap();
          }
        })
      }
    }
    .position(this.nodeScreenPosition(node))
    .zIndex(node.visualFactor.zIndex)
  }

  private nodeScreenPosition(node: MapNodeScreenLayout): Position {
    const screen: number[] = worldToScreen(node.worldX, node.worldY, this.viewport);
    return { x: screen[0] - 60, y: screen[1] - 20 };
  }

  private handleCanvasLongPress(event: GestureEvent): void {
    const fx: number = event.fingerList.length > 0 ? event.fingerList[0].localX : -1;
    const fy: number = event.fingerList.length > 0 ? event.fingerList[0].localY : -1;
    const hitId: string = this.findNodeAt(fx, fy);
    if (hitId.length > 0) {
      this.dragLocationId = hitId;
      this.isDragging = false;
      this.onLocationDragStart(hitId);
    }
  }

  private findNodeAt(localX: number, localY: number): string {
    if (this.mapLayout === null || localX < 0 || localY < 0) {
      return '';
    }
    const nodes: MapNodeScreenLayout[] = this.mapLayout.nodes;
    for (let i: number = 0; i < nodes.length; i++) {
      const screen: number[] = worldToScreen(nodes[i].worldX, nodes[i].worldY, this.viewport);
      if (Math.abs(localX - screen[0]) < 80 && Math.abs(localY - screen[1]) < 50) {
        return nodes[i].locationId;
      }
    }
    return '';
  }

  private handleDragUpdate(event: GestureEvent): void {
    if (this.dragLocationId.length === 0) {
      return;
    }
    this.isDragging = true;
    const fx: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
    const fy: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 0;
    const world: number[] = screenToWorld(fx, fy, this.viewport);
    this.onLocationDragPreview(this.dragLocationId, world[0], world[1]);
  }

  private handleDragEnd(event: GestureEvent): void {
    if (this.dragLocationId.length === 0) {
      return;
    }
    const fx: number = event.fingerList.length > 0 ? event.fingerList[0].localX : 0;
    const fy: number = event.fingerList.length > 0 ? event.fingerList[0].localY : 0;
    const world: number[] = screenToWorld(fx, fy, this.viewport);
    this.onLocationDragEnd(this.dragLocationId, world[0], world[1]);
    this.dragLocationId = '';
    this.isDragging = false;
  }

  private handlePan(event: GestureEvent): void {
    const dx: number = event.offsetX - this.dragStartX;
    const dy: number = event.offsetY - this.dragStartY;
    this.onPan(dx, dy);
    this.dragStartX = event.offsetX;
    this.dragStartY = event.offsetY;
  }
}
