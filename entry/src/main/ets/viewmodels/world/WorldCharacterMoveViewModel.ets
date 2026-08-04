/**
 * WorldCharacterMoveViewModel 世界角色移动 ViewModel(W-CONTROL-1B)
 *
 * 职责:
 * - 加载角色实例、当前位置、世界地点列表、世界连接列表
 * - 计算正常可达地点(存在启用边、目标 Active、非当前位置)
 * - 计算强制移动候选(世界内其他 Active 地点)
 * - 执行正常移动(WorldStateService.moveCharacter,要求实例 Active)
 * - 执行强制移动(WorldStateService.forceMoveCharacter,可移动 Inactive 实例)
 *
 * 依赖方向:Page → ViewModel → WorldStateService(写) + Repository(只读加载)
 *
 * 生命周期保护:
 * - loadOperationId 拒绝迟到加载结果
 * - moveOperationId 防止重复提交并拒绝迟到移动结果
 * - disposed 后不更新状态
 */

import { WorldStateService } from '../../services/world/WorldStateService';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../repositories/world/WorldLocationEdgeRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldLocationEdge } from '../../models/world/WorldLocationEdge';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { World, WorldStatus } from '../../models/world/World';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { Logger } from '../../utils/Logger';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';

const LOG_TAG: string = 'WorldCharacterMoveViewModel';

/** 加载状态 */
export enum WorldCharacterMoveLoadState {
  Loading = 'loading',
  Ready = 'ready',
  NotFound = 'not_found',
  Error = 'error'
}

/** 正常移动候选(已解析目标地点名与通过连接信息) */
export interface NormalMoveOptionUiModel {
  readonly targetLocationId: string;
  readonly targetLocationName: string;
  readonly viaEdgeId: string;
  readonly isBidirectional: boolean;
  readonly directionLabel: string;
  readonly travelDescription: string;
}

/** 强制移动候选(世界内其他 Active 地点,不含当前位置) */
export interface ForceMoveOptionUiModel {
  readonly targetLocationId: string;
  readonly targetLocationName: string;
}

/** 移动页面快照 */
export interface WorldCharacterMoveSnapshotUiModel {
  readonly worldId: string;
  readonly worldStatus: WorldStatus;
  readonly instanceId: string;
  readonly characterId: string;
  readonly displayName: string;
  readonly isActive: boolean;
  readonly currentLocationId: string;
  readonly currentLocationName: string;
  readonly locationMissing: boolean;
  readonly avatarUri: string;
  readonly fallbackName: string;
  readonly normalMoveOptions: NormalMoveOptionUiModel[];
  readonly forceMoveOptions: ForceMoveOptionUiModel[];
}

export class WorldCharacterMoveViewModel {
  private readonly stateService: WorldStateService;
  private readonly worldRepository: WorldRepository;
  private readonly locationRepository: WorldLocationRepository;
  private readonly edgeRepository: WorldLocationEdgeRepository;
  private readonly instanceRepository: WorldCharacterInstanceRepository;

  private boundWorldId: string;
  private boundInstanceId: string;

  loadState: WorldCharacterMoveLoadState = WorldCharacterMoveLoadState.Loading;
  snapshot: WorldCharacterMoveSnapshotUiModel | null = null;
  errorMessage: string = '';

  /** 移动中状态(用于禁用按钮) */
  isMoving: boolean = false;

  /** 加载操作 ID(拒绝迟到结果) */
  private loadOperationId: number = 0;
  /** 移动操作 ID(防重复提交) */
  private moveOperationId: number = 0;
  /** 页面是否已销毁 */
  private disposed: boolean = false;

  constructor(
    stateService: WorldStateService,
    worldRepository: WorldRepository,
    locationRepository: WorldLocationRepository,
    edgeRepository: WorldLocationEdgeRepository,
    instanceRepository: WorldCharacterInstanceRepository,
    worldId: string,
    instanceId: string
  ) {
    this.stateService = stateService;
    this.worldRepository = worldRepository;
    this.locationRepository = locationRepository;
    this.edgeRepository = edgeRepository;
    this.instanceRepository = instanceRepository;
    this.boundWorldId = worldId;
    this.boundInstanceId = instanceId;
  }

  /** 加载移动页面快照 */
  async loadSnapshot(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.boundWorldId.length === 0 || this.boundInstanceId.length === 0) {
      this.loadState = WorldCharacterMoveLoadState.NotFound;
      return;
    }
    this.loadState = WorldCharacterMoveLoadState.Loading;
    this.loadOperationId = this.loadOperationId + 1;
    const opId: number = this.loadOperationId;
    try {
      // 1. 加载世界(确认存在 + 获取状态)
      const world: World | null = await this.worldRepository.getById(this.boundWorldId);
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.loadState = WorldCharacterMoveLoadState.NotFound;
        return;
      }

      // 2. 加载实例
      const instance: WorldCharacterInstance | null =
        await this.instanceRepository.getById(this.boundInstanceId);
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (instance === null) {
        this.loadState = WorldCharacterMoveLoadState.NotFound;
        return;
      }
      // 实例不属于当前世界视为异常
      if (instance.worldId !== this.boundWorldId) {
        this.loadState = WorldCharacterMoveLoadState.NotFound;
        return;
      }

      // 3. 加载世界全部地点与连接
      const locations: WorldLocation[] =
        await this.locationRepository.listByWorld(this.boundWorldId);
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }
      const edges: WorldLocationEdge[] =
        await this.edgeRepository.listByWorld(this.boundWorldId);
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 4. 构造地点查找表
      const locationMap: Map<string, WorldLocation> = new Map<string, WorldLocation>();
      for (let i: number = 0; i < locations.length; i++) {
        locationMap.set(locations[i].id, locations[i]);
      }

      // 5. 解析当前位置名称
      const currentLocationId: string = instance.currentLocationId !== undefined
        ? instance.currentLocationId : '';
      const currentLocation: WorldLocation | undefined =
        currentLocationId.length > 0 ? locationMap.get(currentLocationId) : undefined;
      const currentLocationName: string = currentLocation !== undefined ? currentLocation.name : '';
      const locationMissing: boolean = currentLocationId.length > 0 && currentLocation === undefined;

      // 6. 计算正常可达地点
      // 仅当实例 Active、已放置、当前位置存在且 Active 时计算正常移动候选
      const normalOptions: NormalMoveOptionUiModel[] = [];
      if (instance.isActive
        && currentLocationId.length > 0
        && currentLocation !== undefined
        && currentLocation.status === WorldLocationStatus.Active) {
        for (let i: number = 0; i < edges.length; i++) {
          const edge: WorldLocationEdge = edges[i];
          if (!edge.isEnabled) {
            continue;
          }
          // 跳过异常边(worldId 不一致)
          if (edge.worldId !== this.boundWorldId) {
            continue;
          }
          // 单向正向:edge.fromLocationId = 当前 → edge.toLocationId = 目标
          let targetLocId: string = '';
          let isViaBidirectional: boolean = false;
          if (edge.fromLocationId === currentLocationId) {
            targetLocId = edge.toLocationId;
            isViaBidirectional = edge.isBidirectional;
          } else if (edge.isBidirectional && edge.toLocationId === currentLocationId) {
            // 双向边反向:edge.toLocationId = 当前 → edge.fromLocationId = 目标
            targetLocId = edge.fromLocationId;
            isViaBidirectional = true;
          }
          if (targetLocId.length === 0 || targetLocId === currentLocationId) {
            continue;
          }
          const targetLoc: WorldLocation | undefined = locationMap.get(targetLocId);
          if (targetLoc === undefined || targetLoc.status !== WorldLocationStatus.Active) {
            continue;
          }
          normalOptions.push({
            targetLocationId: targetLocId,
            targetLocationName: targetLoc.name,
            viaEdgeId: edge.id,
            isBidirectional: isViaBidirectional,
            directionLabel: edge.directionLabel,
            travelDescription: edge.travelDescription
          });
        }
      }

      // 7. 计算强制移动候选:世界内其他 Active 地点(不含当前位置)
      const forceOptions: ForceMoveOptionUiModel[] = [];
      for (let i: number = 0; i < locations.length; i++) {
        const loc: WorldLocation = locations[i];
        if (loc.status !== WorldLocationStatus.Active) {
          continue;
        }
        if (loc.id === currentLocationId) {
          continue;
        }
        forceOptions.push({
          targetLocationId: loc.id,
          targetLocationName: loc.name
        });
      }

      this.snapshot = {
        worldId: this.boundWorldId,
        worldStatus: world.status,
        instanceId: instance.id,
        characterId: instance.characterId,
        displayName: instance.displayNameSnapshot,
        isActive: instance.isActive,
        currentLocationId: currentLocationId,
        currentLocationName: currentLocationName,
        locationMissing: locationMissing,
        avatarUri: '',
        fallbackName: instance.displayNameSnapshot.length > 0
          ? instance.displayNameSnapshot.charAt(0) : '?',
        normalMoveOptions: normalOptions,
        forceMoveOptions: forceOptions
      };
      this.loadState = WorldCharacterMoveLoadState.Ready;
    } catch (e) {
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: ' + this.safeErrorCategory(e));
      this.loadState = WorldCharacterMoveLoadState.Error;
      this.errorMessage = '角色移动数据加载失败,请重试';
    }
  }

  /** 执行正常移动 */
  async moveCharacter(targetLocationId: string): Promise<boolean> {
    if (this.disposed || this.isMoving) {
      return false;
    }
    this.isMoving = true;
    this.errorMessage = '';
    this.moveOperationId = this.moveOperationId + 1;
    const opId: number = this.moveOperationId;
    try {
      await this.stateService.moveCharacter(this.boundInstanceId, targetLocationId);
      if (this.disposed || opId !== this.moveOperationId) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed || opId !== this.moveOperationId) {
        return false;
      }
      Logger.error(LOG_TAG, 'moveCharacter failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed && opId === this.moveOperationId) {
        this.isMoving = false;
      }
    }
  }

  /** 执行主持者强制移动 */
  async forceMoveCharacter(targetLocationId: string): Promise<boolean> {
    if (this.disposed || this.isMoving) {
      return false;
    }
    this.isMoving = true;
    this.errorMessage = '';
    this.moveOperationId = this.moveOperationId + 1;
    const opId: number = this.moveOperationId;
    try {
      await this.stateService.forceMoveCharacter(this.boundInstanceId, targetLocationId);
      if (this.disposed || opId !== this.moveOperationId) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed || opId !== this.moveOperationId) {
        return false;
      }
      Logger.error(LOG_TAG, 'forceMoveCharacter failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed && opId === this.moveOperationId) {
        this.isMoving = false;
      }
    }
  }

  /** 清除错误消息 */
  clearError(): void {
    this.errorMessage = '';
  }

  /** 标记页面已销毁 */
  dispose(): void {
    this.disposed = true;
  }

  /** 安全错误分类(日志用,不含 SQL) */
  private safeErrorCategory(e: Object): string {
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }
}
