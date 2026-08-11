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
 * @Observed 装饰:使页面能观察 viewport/mapLayout/placements/background
 * 等字段赋值并触发重绘(节点跟随视口平移/缩放的关键)。
 *
 * 不直接依赖 @ohos.net.http / @ohos.security.asset / Repository。
 */

import { WorldMapInteractionService, MapSnapshotResult, SavePlacementResult } from '../../services/world/WorldMapInteractionService';
import { WorldCharacterMovementService, TravelOption } from '../../services/world/WorldCharacterMovementService';
import { WorldLocationMapPlacement } from '../../models/world/WorldLocationMapPlacement';
import { WorldMapBackground } from '../../models/world/WorldMapBackground';
import {
  ImportBackgroundResult,
  RotateBackgroundResult,
  RemoveBackgroundResult
} from '../../services/world/WorldMapBackgroundService';
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

export interface MapBackgroundPort {
  loadBackground(worldId: string): Promise<WorldMapBackground | null>;
  importBackground(worldId: string, sourceUri: string): Promise<ImportBackgroundResult>;
  rotateBackground(worldId: string, deltaRadians: number): Promise<RotateBackgroundResult>;
  removeBackground(worldId: string): Promise<RemoveBackgroundResult>;
}

export interface MapMovementPort {
  travelCharacter(instanceId: string, targetLocationId: string): Promise<void>;
  listTravelOptions(instanceId: string): Promise<TravelOption[]>;
}

export const TRAVEL_ANIMATION_DURATION_MS: number = 800;

@Observed
export class WorldImmersiveMapViewModel {
  private readonly interactionService: MapInteractionPort;
  private readonly movementService: MapMovementPort | null;
  private readonly backgroundService: MapBackgroundPort | null;

  state: MapLoadState = MapLoadState.Loading;
  errorMessage: string = '';
  world: World | null = null;
  locations: WorldLocationUiModel[] = [];
  edges: WorldEdgeUiModel[] = [];
  characters: WorldCharacterInstanceUiModel[] = [];
  placements: WorldLocationMapPlacement[] = [];
  background: WorldMapBackground | null = null;
  viewport: ImmersiveMapViewport = createDefaultViewport();
  selectedLocationId: string = '';
  editMode: MapEditMode = MapEditMode.Browse;
  mapLayout: ImmersiveMapLayout | null = null;
  isTravelling: boolean = false;
  travellingInstanceId: string = '';
  travellingFromLocationId: string = '';
  travellingToLocationId: string = '';
  travelAnimationProgress: number = 0;

  private containerWidth: number = 0;
  private containerHeight: number = 0;
  private backgroundInitialized: boolean = false;

  private expectedWorldId: string = '';
  private loadOperationId: number = 0;
  private disposed: boolean = false;
  private dragOriginalPlacement: WorldLocationMapPlacement | null = null;
  readonly instanceShortId: string;

  constructor(
    interactionService: MapInteractionPort,
    movementService?: MapMovementPort,
    backgroundService?: MapBackgroundPort
  ) {
    this.interactionService = interactionService;
    this.movementService = movementService ?? null;
    this.backgroundService = backgroundService ?? null;
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
      if (this.backgroundService !== null) {
        const bg: WorldMapBackground | null = await this.backgroundService.loadBackground(worldId);
        if (operationId !== this.loadOperationId || this.disposed) {
          return;
        }
        this.background = bg;
      } else {
        this.background = null;
      }
      if (this.background !== null && !this.backgroundInitialized && this.containerWidth > 0 && this.containerHeight > 0) {
        this.backgroundInitialized = true;
        this.centerOnBackground();
      } else if (this.background === null) {
        this.backgroundInitialized = false;
      } else {
        this.recomputeLayout();
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.state = MapLoadState.Ready;
      Logger.info(LOG_TAG, 'loadSnapshot done: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', locations=' + this.locations.length.toString()
        + ', placements=' + this.placements.length.toString()
        + ', characters=' + this.characters.length.toString()
        + ', background=' + (this.background !== null ? '1' : '0'));
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
    if (this.background !== null && this.containerWidth > 0 && this.containerHeight > 0) {
      this.centerOnBackground();
      this.selectedLocationId = '';
      return;
    }
    this.viewport = createDefaultViewport();
    this.selectedLocationId = '';
    this.recomputeLayout();
  }

  /** 记录地图容器尺寸(用于背景图居中) */
  setContainerSize(width: number, height: number): void {
    this.containerWidth = width;
    this.containerHeight = height;
    if (this.background !== null && !this.backgroundInitialized && width > 0 && height > 0) {
      this.backgroundInitialized = true;
      this.centerOnBackground();
    }
  }

  /** 将视口对准背景图中心并适配(图片模式默认视角) */
  centerOnBackground(): void {
    if (this.background === null || this.containerWidth <= 0 || this.containerHeight <= 0) {
      this.viewport = createDefaultViewport();
      this.recomputeLayout();
      return;
    }
    const center: number[] = this.backgroundCenter();
    const bgW: number = this.background.imageWidth * this.background.fitScale;
    const bgH: number = this.background.imageHeight * this.background.fitScale;
    const fitZoom: number = clampZoom(
      Math.min((this.containerWidth - 16) / bgW, (this.containerHeight - 16) / bgH)
    );
    this.viewport = {
      offsetX: this.containerWidth / 2 - center[0] * fitZoom,
      offsetY: this.containerHeight / 2 - center[1] * fitZoom,
      zoom: fitZoom
    };
    this.recomputeLayout();
  }

  /** 旋转背景图(每次 deltaDeg 度),同步转换所有地点坐标 */
  async rotateBackgroundBy(deltaDeg: number): Promise<string> {
    if (this.backgroundService === null || this.world === null) {
      return '服务未初始化';
    }
    const deltaRadians: number = deltaDeg * Math.PI / 180;
    const result: RotateBackgroundResult =
      await this.backgroundService.rotateBackground(this.world.id, deltaRadians);
    if (result.success && result.background !== null) {
      this.background = result.background;
      this.placements = result.placements;
      this.recomputeLayout();
      Logger.info(LOG_TAG, 'rotateBackgroundBy: bg.rotation=' + this.background.rotation.toFixed(3)
        + ', placements=' + this.placements.length.toString()
        + ', firstX=' + (this.placements.length > 0 ? this.placements[0].positionX.toFixed(1) : 'n/a')
        + ', firstY=' + (this.placements.length > 0 ? this.placements[0].positionY.toFixed(1) : 'n/a')
        + ', mapLayout=' + (this.mapLayout !== null ? this.mapLayout.nodes.length.toString() : 'null'));
      return '';
    }
    return result.errorMessage;
  }

  /** 导入背景图(从相册 URI) */
  async importBackground(sourceUri: string): Promise<string> {
    if (this.backgroundService === null || this.world === null) {
      return '服务未初始化';
    }
    const result: ImportBackgroundResult =
      await this.backgroundService.importBackground(this.world.id, sourceUri);
    if (result.success && result.background !== null) {
      this.background = result.background;
      this.placements = result.placements;
      this.recomputeLayout();
      return '';
    }
    return result.errorMessage;
  }

  /** 移除背景图 */
  async removeBackground(): Promise<string> {
    if (this.backgroundService === null || this.world === null) {
      return '服务未初始化';
    }
    const result: RemoveBackgroundResult =
      await this.backgroundService.removeBackground(this.world.id);
    if (result.success) {
      this.background = null;
      this.recomputeLayout();
      return '';
    }
    return result.errorMessage;
  }

  private backgroundCenter(): number[] {
    const bg: WorldMapBackground | null = this.background;
    if (bg === null) {
      return [0, 0];
    }
    return [bg.imageWidth * bg.fitScale / 2, bg.imageHeight * bg.fitScale / 2];
  }

  panBy(dx: number, dy: number): void {
    this.viewport = {
      offsetX: this.viewport.offsetX + dx,
      offsetY: this.viewport.offsetY + dy,
      zoom: this.viewport.zoom
    };
    this.recomputeLayout();
    Logger.info(LOG_TAG, 'panBy: dx=' + dx.toFixed(0) + ', dy=' + dy.toFixed(0)
      + ', offset=(' + this.viewport.offsetX.toFixed(0) + ',' + this.viewport.offsetY.toFixed(0) + ')'
      + ', zoom=' + this.viewport.zoom.toFixed(3)
      + ', mapLayout=' + (this.mapLayout !== null ? this.mapLayout.nodes.length.toString() : 'null'));
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

  async listTravelOptionsForCharacter(instanceId: string): Promise<TravelOption[]> {
    if (this.movementService === null) {
      return [];
    }
    try {
      return await this.movementService.listTravelOptions(instanceId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listTravelOptions failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  async travelCharacterOnMap(instanceId: string, targetLocationId: string): Promise<boolean> {
    if (this.movementService === null || this.isTravelling) {
      return false;
    }
    const fromLocationId: string = this.resolveInstanceLocationId(instanceId);
    if (fromLocationId.length === 0) {
      return false;
    }
    this.isTravelling = true;
    this.travellingInstanceId = instanceId;
    this.travellingFromLocationId = fromLocationId;
    this.travellingToLocationId = targetLocationId;
    this.travelAnimationProgress = 0;
    try {
      await this.movementService.travelCharacter(instanceId, targetLocationId);
      this.travelAnimationProgress = 1;
      if (this.world !== null) {
        await this.loadSnapshot(this.world.id);
      }
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'travelCharacterOnMap failed: ' + this.safeErrorCategory(e));
      this.errorMessage = '移动失败,请重试';
      return false;
    } finally {
      this.isTravelling = false;
      this.travellingInstanceId = '';
      this.travellingFromLocationId = '';
      this.travellingToLocationId = '';
      this.travelAnimationProgress = 0;
    }
  }

  private resolveInstanceLocationId(instanceId: string): string {
    for (let i: number = 0; i < this.characters.length; i++) {
      if (this.characters[i].id === instanceId) {
        return this.characters[i].currentLocationId;
      }
    }
    return '';
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
      this.viewport,
      this.background
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
