/**
 * WorldEdgeEditViewModel 世界地点连接编辑 ViewModel(W-CONTROL-1B)
 *
 * 职责:
 * - 创建模式:edgeId 为空,调用 WorldStateService.createEdge
 * - 编辑模式:edgeId 非空,加载真实连接,端点只读,可修改方向标签 / 旅行描述 / 单向双向 / 启用停用
 *   调用 WorldStateService.updateEdge(只传 directionLabel / travelDescription /
 *   isBidirectional / isEnabled),Service 内部执行冲突检查
 * - 防重复提交(isSaving / operationId)
 * - 页面销毁后不更新状态(disposed)
 * - 错误映射为用户安全文案
 *
 * 依赖方向:Page → ViewModel → WorldStateService(写) +
 *          WorldRepository / WorldLocationRepository / WorldLocationEdgeRepository(只读加载)
 *
 * 不创建反向边。
 * 不修改端点(端点变更等价于删除 + 新建,本阶段不开放)。
 */

import { WorldStateService, WorldLocationEdgeUpdates } from '../../services/world/WorldStateService';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../repositories/world/WorldLocationEdgeRepository';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldLocationEdge } from '../../models/world/WorldLocationEdge';
import { Logger } from '../../utils/Logger';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';

const LOG_TAG: string = 'WorldEdgeEditViewModel';

/** 字段长度上限(与 WorldStateService 对齐) */
const DIRECTION_LABEL_MAX: number = 100;
const TRAVEL_DESCRIPTION_MAX: number = 2000;

/** 编辑页加载状态 */
export enum WorldEdgeEditLoadState {
  Loading = 'loading',
  Ready = 'ready',
  NotFound = 'not_found',
  Error = 'error'
}

/** Active 地点候选 UI 模型 */
export interface WorldEdgeLocationOptionUiModel {
  readonly id: string;
  readonly name: string;
}

/** 端点解析结果(用于编辑模式回显) */
export interface WorldEdgeEndpointUiModel {
  readonly locationId: string;
  readonly name: string;
  readonly missing: boolean;
}

export class WorldEdgeEditViewModel {
  private readonly stateService: WorldStateService;
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly edgeRepo: WorldLocationEdgeRepository;

  /** 当前 World ID */
  private boundWorldId: string;
  /** 当前 Edge ID(创建模式为空) */
  private boundEdgeId: string;
  /** 是否为创建模式 */
  readonly isCreateMode: boolean;

  loadState: WorldEdgeEditLoadState = WorldEdgeEditLoadState.Loading;
  /** Active 地点候选(创建模式使用) */
  locationOptions: WorldEdgeLocationOptionUiModel[] = [];
  /** 起点(创建模式可改,编辑模式只读) */
  fromLocationId: string = '';
  /** 终点(创建模式可改,编辑模式只读) */
  toLocationId: string = '';
  /** 方向标签输入 */
  directionLabelInput: string = '';
  /** 旅行描述输入 */
  travelDescriptionInput: string = '';
  /** 是否双向 */
  isBidirectional: boolean = false;
  /** 是否启用 */
  isEnabled: boolean = true;
  /** 世界状态(归档时禁止保存) */
  worldStatus: WorldStatus = WorldStatus.Active;
  /** 起点解析(编辑模式) */
  fromEndpoint: WorldEdgeEndpointUiModel | null = null;
  /** 终点解析(编辑模式) */
  toEndpoint: WorldEdgeEndpointUiModel | null = null;

  isSaving: boolean = false;
  errorMessage: string = '';
  /** 保存成功后为 true,页面据此返回 */
  saveSucceeded: boolean = false;

  /** 操作 ID(防重复提交 / 拒绝迟到结果) */
  private operationId: number = 0;
  /** 页面是否已销毁 */
  private disposed: boolean = false;

  constructor(
    stateService: WorldStateService,
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    edgeRepo: WorldLocationEdgeRepository,
    worldId: string,
    edgeId: string,
    fromLocationId?: string
  ) {
    this.stateService = stateService;
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.edgeRepo = edgeRepo;
    this.boundWorldId = worldId;
    this.boundEdgeId = edgeId;
    this.isCreateMode = edgeId.length === 0;
    if (this.isCreateMode && fromLocationId !== undefined && fromLocationId.length > 0) {
      this.fromLocationId = fromLocationId;
    }
  }

  /** 加载表单(创建模式加载地点候选;编辑模式加载连接 + 地点候选 + 端点解析) */
  async loadForm(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.loadState = WorldEdgeEditLoadState.Loading;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      // 1. 加载 World(校验存在 + 获取状态)
      const world: World | null = await this.worldRepo.getById(this.boundWorldId);
      if (opId !== this.operationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.loadState = WorldEdgeEditLoadState.NotFound;
        return;
      }
      this.worldStatus = world.status;

      // 2. 加载地点候选(仅 Active)
      const locations: WorldLocation[] = await this.locationRepo.listByWorld(this.boundWorldId);
      if (opId !== this.operationId || this.disposed) {
        return;
      }
      const options: WorldEdgeLocationOptionUiModel[] = [];
      for (let i: number = 0; i < locations.length; i++) {
        if (locations[i].status === WorldLocationStatus.Active) {
          options.push({
            id: locations[i].id,
            name: locations[i].name
          });
        }
      }
      this.locationOptions = options;

      // 3. 编辑模式:加载连接
      if (!this.isCreateMode) {
        const edge: WorldLocationEdge | null = await this.edgeRepo.getById(this.boundEdgeId);
        if (opId !== this.operationId || this.disposed) {
          return;
        }
        if (edge === null) {
          this.loadState = WorldEdgeEditLoadState.NotFound;
          return;
        }
        // 同步 worldId(防止上一页传错)
        this.boundWorldId = edge.worldId;
        this.fromLocationId = edge.fromLocationId;
        this.toLocationId = edge.toLocationId;
        this.directionLabelInput = edge.directionLabel;
        this.travelDescriptionInput = edge.travelDescription;
        this.isBidirectional = edge.isBidirectional;
        this.isEnabled = edge.isEnabled;
        // 解析端点名称
        this.fromEndpoint = this.resolveEndpoint(edge.fromLocationId, locations);
        this.toEndpoint = this.resolveEndpoint(edge.toLocationId, locations);
      } else {
        // 创建模式:若预设起点不在候选列表中(已归档),清空
        if (this.fromLocationId.length > 0) {
          let found: boolean = false;
          for (let i: number = 0; i < options.length; i++) {
            if (options[i].id === this.fromLocationId) {
              found = true;
              break;
            }
          }
          if (!found) {
            this.fromLocationId = '';
          }
        }
      }
      this.loadState = WorldEdgeEditLoadState.Ready;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadForm failed: ' + this.safeErrorCategory(e));
      this.loadState = WorldEdgeEditLoadState.Error;
      this.errorMessage = '连接数据加载失败,请重试';
    }
  }

  /** 保存(创建或更新) */
  async save(): Promise<void> {
    if (this.disposed || this.isSaving) {
      return;
    }
    // 表单校验
    if (this.fromLocationId.length === 0) {
      this.errorMessage = '请选择起点地点';
      return;
    }
    if (this.toLocationId.length === 0) {
      this.errorMessage = '请选择终点地点';
      return;
    }
    if (this.fromLocationId === this.toLocationId) {
      this.errorMessage = '连接的起点和终点不能相同';
      return;
    }
    this.isSaving = true;
    this.errorMessage = '';
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const trimmedDirection: string = this.directionLabelInput.trim();
      const trimmedTravel: string = this.travelDescriptionInput.trim();
      if (this.isCreateMode) {
        await this.stateService.createEdge(
          this.boundWorldId,
          this.fromLocationId,
          this.toLocationId,
          trimmedDirection,
          trimmedTravel,
          this.isBidirectional
        );
      } else {
        const updates: WorldLocationEdgeUpdates = {
          directionLabel: trimmedDirection,
          travelDescription: trimmedTravel,
          isBidirectional: this.isBidirectional,
          isEnabled: this.isEnabled
        };
        await this.stateService.updateEdge(this.boundEdgeId, updates);
      }
      if (this.disposed || opId !== this.operationId) {
        return;
      }
      this.saveSucceeded = true;
    } catch (e) {
      if (this.disposed || opId !== this.operationId) {
        return;
      }
      Logger.error(LOG_TAG, 'save failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
    } finally {
      if (!this.disposed && opId === this.operationId) {
        this.isSaving = false;
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

  /** 方向标签长度上限 */
  getDirectionLabelMax(): number {
    return DIRECTION_LABEL_MAX;
  }

  /** 旅行描述长度上限 */
  getTravelDescriptionMax(): number {
    return TRAVEL_DESCRIPTION_MAX;
  }

  /** 解析端点(编辑模式回显) */
  private resolveEndpoint(locationId: string, locations: WorldLocation[]): WorldEdgeEndpointUiModel {
    for (let i: number = 0; i < locations.length; i++) {
      if (locations[i].id === locationId) {
        return {
          locationId: locationId,
          name: locations[i].name,
          missing: false
        };
      }
    }
    return {
      locationId: locationId,
      name: '',
      missing: true
    };
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
