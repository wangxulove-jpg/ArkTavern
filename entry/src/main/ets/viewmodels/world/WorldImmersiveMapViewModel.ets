/**
 * WorldImmersiveMapViewModel 沉浸式地图 ViewModel(W1D)
 *
 * 职责:
 * - 加载地图快照(通过 WorldMapInteractionService)
 * - 管理视口状态(offsetX/Y, zoom) — 仅内存,不持久化
 * - 管理选中地点
 * - 管理浏览/编辑模式(浏览=默认,无编辑工具栏;编辑=工具可见,允许拖动)
 * - 处理节点拖动(拖动结束=单次保存,失败=UI 回滚+错误)
 * - 计算 2.5D 沉浸式布局(通过 WorldImmersiveMapLayout)
 *
 * 依赖方向:
 * Page → ViewModel → Service(只读+放置写入) / WorldImmersiveMapLayout(纯逻辑)
 *
 * 不直接依赖 @ohos.net.http / @ohos.security.asset / Repository。
 */

import { WorldMapInteractionService, MapSnapshotResult, SavePlacementResult } from '../../services/world/WorldMapInteractionService';
import { WorldLocationMapPlacement } from '../../models/world/WorldLocationMapPlacement';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldLocationEdge } from '../../models/world/WorldLocationEdge';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { Character } from '../../models/Character';
import { Logger } from '../../utils/Logger';
import {
  WorldLocationUiModel,
  WorldEdgeUiModel,
  WorldCharacterInstanceUiModel,
  WorldDetailLoadState
} from './WorldUiModels';
import {
  ImmersiveMapViewport,
  ImmersiveMapLayout,
  MapNodeScreenLayout,
  MapEdgeScreenLayout,
  BillboardLayout,
  computeImmersiveMapLayout,
  computeBillboardLayout,
  computeFocusTarget,
  computeViewportForFocus,
  clampZoom,
  createDefaultViewport,
  worldToScreen,
  screenToWorld,
  MIN_ZOOM,
  MAX_ZOOM,
  DEFAULT_ZOOM,
  BILLBOARD_MAX_VISIBLE
} from './WorldImmersiveMapLayout';

const LOG_TAG: string = 'WorldImmersiveMapViewModel';

export enum MapEditMode {
  Browse,
  Edit
}

export enum MapLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

export interface MapInteractionPort {
  loadMapSnapshot(worldId: string): Promise<MapSnapshotResult>;
  saveLocationPlacement(worldId: string, locationId: string, positionX: number, positionY: number, positionZ: number): Promise<SavePlacementResult>;
}

export class WorldImmersiveMapViewModel {
  private readonly interactionService: MapInteractionPort;

  state: MapLoadState = MapLoadState.Loading;
  errorMessage: string = '';
  world: World | null = null;
  locations: WorldLocationUiModel[] = [];
  edges: WorldEdgeUiModel[] = [];
  characters: WorldCharacterInstanceUiModel[] = [];
  placements: WorldLocationMapPlacement[] = [];
  viewport: ImmersiveMapViewport = createDefaultViewport();
  selectedLocationId: string = '';
  editMode: MapEditMode = MapEditMode.Browse;
  mapLayout: ImmersiveMapLayout | null = null;

  private expectedWorldId: string = '';
  private loadOperationId: number = 0;
  private disposed: boolean = false;
  private dragOriginalPlacement: WorldLocationMapPlacement | null = null;
  readonly instanceShortId: string;

  constructor(interactionService: MapInteractionPort) {
    this.interactionService = interactionService;
    this.instanceShortId = WorldImmersiveMapViewModel.generateShortId();
  }

  private static generateShortId(): string {
    const ts: number = Date.now();
    const tail: number = Math.floor(ts % 0xffff);
    return tail.toString(16).padStart(4, '0');
  }

  activate(): void {
    if (this.disposed) {
      this.disposed = false;
      Logger.info(LOG_TAG, 'activate: vmInstance=' + this.instanceShortId);
    }
  }

  dispose(): void {
    this.disposed = true;
    Logger.info(LOG_TAG, 'dispose: vmInstance=' + this.instanceShortId);
  }

  setWorldId(worldId: string): void {
    if (this.expectedWorldId !== worldId) {
      this.expectedWorldId = worldId;
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  async loadSnapshot(worldId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.expectedWorldId = worldId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;
    this.state = MapLoadState.Loading;
    this.errorMessage = '';

    try {
      const snapshot: MapSnapshotResult = await this.interactionService.loadMapSnapshot(worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.world = snapshot.world;
      this.placements = snapshot.placements;
      this.locations = this.mapLocationsToUi(snapshot.locations);
      this.edges = this.mapEdgesToUi(snapshot.edges, snapshot.locations);
      this.characters = this.mapInstancesToUi(snapshot.instances, snapshot.characterMap, snapshot.locations);
      this.recomputeLayout();
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.state = MapLoadState.Ready;
      Logger.info(LOG_TAG, 'loadSnapshot done: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', locations=' + this.locations.length.toString()
        + ', placements=' + this.placements.length.toString()
        + ', characters=' + this.characters.length.toString());
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: ' + this.safeErrorCategory(e));
      this.errorMessage = '地图数据加载失败,请重试';
      this.state = MapLoadState.Error;
    }
  }

  selectLocation(locationId: string): void {
    this.selectedLocationId = locationId;
  }

  deselectLocation(): void {
    this.selectedLocationId = '';
  }

  toggleEditMode(): void {
    this.editMode = this.editMode === MapEditMode.Browse ? MapEditMode.Edit : MapEditMode.Browse;
  }

  setEditMode(mode: MapEditMode): void {
    this.editMode = mode;
  }

  zoomIn(): void {
    const newZoom: number = clampZoom(this.viewport.zoom + 0.15);
    this.viewport = { offsetX: this.viewport.offsetX, offsetY: this.viewport.offsetY, zoom: newZoom };
    this.recomputeLayout();
  }

  zoomOut(): void {
    const newZoom: number = clampZoom(this.viewport.zoom - 0.15);
    this.viewport = { offsetX: this.viewport.offsetX, offsetY: this.viewport.offsetY, zoom: newZoom };
    this.recomputeLayout();
  }

  resetViewport(): void {
    this.viewport = createDefaultViewport();
    this.selectedLocationId = '';
    this.recomputeLayout();
  }

  panBy(dx: number, dy: number): void {
    this.viewport = {
      offsetX: this.viewport.offsetX + dx,
      offsetY: this.viewport.offsetY + dy,
      zoom: this.viewport.zoom
    };
    this.recomputeLayout();
  }

  focusOnLocation(locationId: string, containerWidth: number, containerHeight: number): void {
    const target = computeFocusTarget(locationId, this.placements, []);
    if (target === null) {
      return;
    }
    this.viewport = computeViewportForFocus(target, containerWidth, containerHeight, this.viewport.zoom);
    this.selectedLocationId = locationId;
    this.recomputeLayout();
  }

  beginDrag(locationId: string): void {
    for (let i: number = 0; i < this.placements.length; i++) {
      if (this.placements[i].locationId === locationId) {
        this.dragOriginalPlacement = this.placements[i];
        return;
      }
    }
    this.dragOriginalPlacement = null;
  }

  updateDragPosition(locationId: string, worldX: number, worldY: number): void {
    for (let i: number = 0; i < this.placements.length; i++) {
      if (this.placements[i].locationId === locationId) {
        const orig: WorldLocationMapPlacement = this.placements[i];
        this.placements[i] = {
          id: orig.id,
          worldId: orig.worldId,
          locationId: orig.locationId,
          positionX: worldX,
          positionY: worldY,
          positionZ: orig.positionZ,
          rotationX: orig.rotationX,
          rotationY: orig.rotationY,
          rotationZ: orig.rotationZ,
          scale: orig.scale,
          createdAt: orig.createdAt,
          updatedAt: orig.updatedAt
        };
        this.recomputeLayout();
        return;
      }
    }
  }

  async endDrag(locationId: string, worldX: number, worldY: number): Promise<string> {
    if (this.world === null) {
      return '世界数据未加载';
    }
    const positionZ: number = this.getPlacementZ(locationId);
    const result: SavePlacementResult = await this.interactionService.saveLocationPlacement(
      this.world.id, locationId, worldX, worldY, positionZ
    );
    if (result.success && result.placement !== null) {
      this.updatePlacementInList(result.placement);
      this.recomputeLayout();
      return '';
    }
    if (this.dragOriginalPlacement !== null) {
      this.updatePlacementInList(this.dragOriginalPlacement);
      this.recomputeLayout();
    }
    this.dragOriginalPlacement = null;
    return result.errorMessage;
  }

  cancelDrag(): void {
    if (this.dragOriginalPlacement !== null) {
      this.updatePlacementInList(this.dragOriginalPlacement);
      this.recomputeLayout();
    }
    this.dragOriginalPlacement = null;
  }

  getBillboardLayout(locationId: string): BillboardLayout {
    return computeBillboardLayout(locationId, this.characters);
  }

  private recomputeLayout(): void {
    if (this.locations.length === 0) {
      this.mapLayout = null;
      return;
    }
    this.mapLayout = computeImmersiveMapLayout(
      this.locations,
      this.edges,
      this.placements,
      this.characters,
      this.viewport
    );
  }

  private getPlacementZ(locationId: string): number {
    for (let i: number = 0; i < this.placements.length; i++) {
      if (this.placements[i].locationId === locationId) {
        return this.placements[i].positionZ;
      }
    }
    return 0;
  }

  private updatePlacementInList(placement: WorldLocationMapPlacement): void {
    for (let i: number = 0; i < this.placements.length; i++) {
      if (this.placements[i].locationId === placement.locationId) {
        this.placements[i] = placement;
        return;
      }
    }
    this.placements.push(placement);
  }

  private mapLocationsToUi(locations: WorldLocation[]): WorldLocationUiModel[] {
    const result: WorldLocationUiModel[] = new Array<WorldLocationUiModel>(locations.length);
    for (let i: number = 0; i < locations.length; i++) {
      const loc: WorldLocation = locations[i];
      result[i] = {
        id: loc.id,
        name: loc.name,
        description: loc.description,
        status: loc.status as WorldLocationStatus,
        createdAt: loc.createdAt
      };
    }
    return result;
  }

  private mapEdgesToUi(edges: WorldLocationEdge[], locations: WorldLocation[]): WorldEdgeUiModel[] {
    const locationMap: Map<string, WorldLocationUiModel> = new Map<string, WorldLocationUiModel>();
    const uiLocs: WorldLocationUiModel[] = this.mapLocationsToUi(locations);
    for (let i: number = 0; i < uiLocs.length; i++) {
      locationMap.set(uiLocs[i].id, uiLocs[i]);
    }
    const result: WorldEdgeUiModel[] = new Array<WorldEdgeUiModel>(edges.length);
    for (let i: number = 0; i < edges.length; i++) {
      const edge: WorldLocationEdge = edges[i];
      const fromLoc: WorldLocationUiModel | undefined = locationMap.get(edge.fromLocationId);
      const toLoc: WorldLocationUiModel | undefined = locationMap.get(edge.toLocationId);
      const fromMissing: boolean = fromLoc === undefined;
      const toMissing: boolean = toLoc === undefined;
      const isSelfLoop: boolean = edge.fromLocationId === edge.toLocationId;
      const isAnomalous: boolean = fromMissing || toMissing || isSelfLoop;
      result[i] = {
        id: edge.id,
        fromLocationId: edge.fromLocationId,
        toLocationId: edge.toLocationId,
        fromLocationName: fromLoc !== undefined ? fromLoc.name : '',
        toLocationName: toLoc !== undefined ? toLoc.name : '',
        fromLocationMissing: fromMissing,
        toLocationMissing: toMissing,
        directionLabel: edge.directionLabel,
        travelDescription: edge.travelDescription,
        isBidirectional: edge.isBidirectional,
        isEnabled: edge.isEnabled,
        isAnomalous: isAnomalous
      };
    }
    return result;
  }

  private mapInstancesToUi(
    instances: WorldCharacterInstance[],
    characterMap: Map<string, Character | null>,
    locations: WorldLocation[]
  ): WorldCharacterInstanceUiModel[] {
    const locationMap: Map<string, WorldLocationUiModel> = new Map<string, WorldLocationUiModel>();
    const uiLocs: WorldLocationUiModel[] = this.mapLocationsToUi(locations);
    for (let i: number = 0; i < uiLocs.length; i++) {
      locationMap.set(uiLocs[i].id, uiLocs[i]);
    }
    const result: WorldCharacterInstanceUiModel[] = new Array<WorldCharacterInstanceUiModel>(instances.length);
    for (let i: number = 0; i < instances.length; i++) {
      const inst: WorldCharacterInstance = instances[i];
      const character: Character | null | undefined = characterMap.get(inst.characterId);
      const missing: boolean = character === null || character === undefined;
      const displayName: string = !missing && character !== null && character !== undefined
        ? character.name : inst.displayNameSnapshot;
      const avatarUri: string = !missing && character !== null && character !== undefined
        ? character.avatarUri : '';
      let currentLocationName: string = '';
      let locationMissing: boolean = false;
      const currentLocId: string = inst.currentLocationId !== undefined ? inst.currentLocationId : '';
      if (currentLocId.length === 0) {
        currentLocationName = '';
        locationMissing = false;
      } else {
        const loc: WorldLocationUiModel | undefined = locationMap.get(currentLocId);
        if (loc === undefined) {
          currentLocationName = '';
          locationMissing = true;
        } else {
          currentLocationName = loc.name;
          locationMissing = false;
        }
      }
      result[i] = {
        id: inst.id,
        characterId: inst.characterId,
        displayName: displayName,
        isActive: inst.isActive,
        currentLocationId: currentLocId,
        currentLocationName: currentLocationName,
        locationMissing: locationMissing,
        characterCardMissing: missing,
        avatarUri: avatarUri,
        fallbackName: displayName.length > 0 ? displayName.charAt(0) : '?',
        createdAt: inst.createdAt
      };
    }
    return result;
  }

  private safeErrorCategory(e: Object): string {
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }
}
