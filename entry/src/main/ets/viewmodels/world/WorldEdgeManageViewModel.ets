/**
 * WorldEdgeManageViewModel 世界地点连接管理 ViewModel(W-CONTROL-1B)
 *
 * 职责:
 * - 加载指定 World 下的全部连接 + 全部地点(用于解析端点名称)
 * - 启用 / 停用连接(WorldStateService.updateEdge,只传 isEnabled)
 * - 删除连接(WorldStateService.deleteEdge)
 * - 不创建连接,不编辑端点 / 方向 / 描述(在 WorldEdgeEditPage 处理)
 * - 异常连接安全降级展示,允许删除但不允许编辑
 *
 * 依赖方向:Page → ViewModel → WorldStateService(写) + Repository(只读加载)
 *
 * 生命周期保护:
 * - loadOperationId 拒绝迟到加载结果
 * - operationId 防止启停 / 删除重复提交
 * - disposed 后不更新状态
 */

import { WorldStateService } from '../../services/world/WorldStateService';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../repositories/world/WorldLocationEdgeRepository';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldLocationEdge } from '../../models/world/WorldLocationEdge';
import { Logger } from '../../utils/Logger';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';

const LOG_TAG: string = 'WorldEdgeManageViewModel';

/** 加载状态 */
export enum WorldEdgeManageLoadState {
  Loading = 'loading',
  Ready = 'ready',
  NotFound = 'not_found',
  Error = 'error'
}

/** 连接管理 UI 模型(端点名称已解析,异常已标记) */
export interface WorldEdgeManageItemUiModel {
  readonly id: string;
  readonly fromLocationId: string;
  readonly toLocationId: string;
  readonly fromLocationName: string;
  readonly toLocationName: string;
  readonly fromLocationMissing: boolean;
  readonly toLocationMissing: boolean;
  readonly directionLabel: string;
  readonly travelDescription: string;
  readonly isBidirectional: boolean;
  readonly isEnabled: boolean;
  /** 异常边:端点缺失 / 自连接 / worldId 不一致 */
  readonly isAnomalous: boolean;
  /** 是否为自连接 */
  readonly isSelfLoop: boolean;
}

/** Active 地点数量(用于空状态提示) */
export interface WorldEdgeManageSnapshotUiModel {
  readonly worldName: string;
  readonly locationCount: number;
  readonly edgeCount: number;
  readonly anomalousEdgeCount: number;
}

export class WorldEdgeManageViewModel {
  private readonly stateService: WorldStateService;
  private readonly locationRepository: WorldLocationRepository;
  private readonly edgeRepository: WorldLocationEdgeRepository;

  private boundWorldId: string;

  loadState: WorldEdgeManageLoadState = WorldEdgeManageLoadState.Loading;
  snapshot: WorldEdgeManageSnapshotUiModel | null = null;
  edges: WorldEdgeManageItemUiModel[] = [];
  errorMessage: string = '';

  /** 启停 / 删除中状态 */
  isSaving: boolean = false;
  isDeleting: boolean = false;

  /** 加载操作 ID(拒绝迟到结果) */
  private loadOperationId: number = 0;
  /** 写入操作 ID(防重复提交) */
  private writeOperationId: number = 0;
  /** 页面是否已销毁 */
  private disposed: boolean = false;

  constructor(
    stateService: WorldStateService,
    locationRepository: WorldLocationRepository,
    edgeRepository: WorldLocationEdgeRepository,
    worldId: string
  ) {
    this.stateService = stateService;
    this.locationRepository = locationRepository;
    this.edgeRepository = edgeRepository;
    this.boundWorldId = worldId;
  }

  /** 加载连接列表快照 */
  async loadSnapshot(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.boundWorldId.length === 0) {
      this.loadState = WorldEdgeManageLoadState.NotFound;
      return;
    }
    this.loadState = WorldEdgeManageLoadState.Loading;
    this.loadOperationId = this.loadOperationId + 1;
    const opId: number = this.loadOperationId;
    try {
      const edgesResult: WorldLocationEdge[] =
        await this.edgeRepository.listByWorld(this.boundWorldId);
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }
      const locationsResult: WorldLocation[] =
        await this.locationRepository.listByWorld(this.boundWorldId);
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 构造地点查找表
      const locationMap: Map<string, WorldLocation> = new Map<string, WorldLocation>();
      for (let i: number = 0; i < locationsResult.length; i++) {
        locationMap.set(locationsResult[i].id, locationsResult[i]);
      }

      // 映射连接 UI 模型
      const items: WorldEdgeManageItemUiModel[] = new Array<WorldEdgeManageItemUiModel>(edgesResult.length);
      let anomalousCount: number = 0;
      for (let i: number = 0; i < edgesResult.length; i++) {
        const e: WorldLocationEdge = edgesResult[i];
        const fromLoc: WorldLocation | undefined = locationMap.get(e.fromLocationId);
        const toLoc: WorldLocation | undefined = locationMap.get(e.toLocationId);
        const fromMissing: boolean = fromLoc === undefined;
        const toMissing: boolean = toLoc === undefined;
        const isSelfLoop: boolean = e.fromLocationId === e.toLocationId;
        const worldMismatch: boolean = e.worldId !== this.boundWorldId;
        const isAnomalous: boolean = fromMissing || toMissing || isSelfLoop || worldMismatch;
        if (isAnomalous) {
          anomalousCount = anomalousCount + 1;
        }
        items[i] = {
          id: e.id,
          fromLocationId: e.fromLocationId,
          toLocationId: e.toLocationId,
          fromLocationName: fromLoc !== undefined ? fromLoc.name : '',
          toLocationName: toLoc !== undefined ? toLoc.name : '',
          fromLocationMissing: fromMissing,
          toLocationMissing: toMissing,
          directionLabel: e.directionLabel,
          travelDescription: e.travelDescription,
          isBidirectional: e.isBidirectional,
          isEnabled: e.isEnabled,
          isAnomalous: isAnomalous,
          isSelfLoop: isSelfLoop
        };
      }
      this.edges = items;
      this.snapshot = {
        worldName: '',
        locationCount: locationsResult.length,
        edgeCount: edgesResult.length,
        anomalousEdgeCount: anomalousCount
      };
      this.loadState = WorldEdgeManageLoadState.Ready;
    } catch (e) {
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: ' + this.safeErrorCategory(e));
      this.loadState = WorldEdgeManageLoadState.Error;
      this.errorMessage = '连接数据加载失败,请重试';
    }
  }

  /** 启用或停用连接 */
  async setEdgeEnabled(edgeId: string, enabled: boolean): Promise<boolean> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return false;
    }
    this.isSaving = true;
    this.errorMessage = '';
    this.writeOperationId = this.writeOperationId + 1;
    const opId: number = this.writeOperationId;
    try {
      await this.stateService.updateEdge(edgeId, { isEnabled: enabled });
      if (this.disposed || opId !== this.writeOperationId) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed || opId !== this.writeOperationId) {
        return false;
      }
      Logger.error(LOG_TAG, 'setEdgeEnabled failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed && opId === this.writeOperationId) {
        this.isSaving = false;
      }
    }
  }

  /** 删除连接 */
  async deleteEdge(edgeId: string): Promise<boolean> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return false;
    }
    this.isDeleting = true;
    this.errorMessage = '';
    this.writeOperationId = this.writeOperationId + 1;
    const opId: number = this.writeOperationId;
    try {
      await this.stateService.deleteEdge(edgeId);
      if (this.disposed || opId !== this.writeOperationId) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed || opId !== this.writeOperationId) {
        return false;
      }
      Logger.error(LOG_TAG, 'deleteEdge failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed && opId === this.writeOperationId) {
        this.isDeleting = false;
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
