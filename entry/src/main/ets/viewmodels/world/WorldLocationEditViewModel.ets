/**
 * WorldLocationEditViewModel 地点编辑页 ViewModel(W-CONTROL-1A)
 *
 * 职责:
 * - 创建模式:locationId 为空,调用 WorldStateService.createLocation
 * - 编辑模式:locationId 非空,重新从数据库加载真实地点,调用 updateLocation /
 *   setLocationArchived / deleteLocation
 * - 防重复提交(isSaving / isDeleting / operationId)
 * - 页面销毁后不更新状态(disposed)
 * - 错误映射为用户安全文案
 *
 * 依赖方向:Page → ViewModel → WorldStateService(写) + WorldLocationRepository(只读加载)
 */

import { WorldStateService } from '../../services/world/WorldStateService';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { Logger } from '../../utils/Logger';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';

const LOG_TAG: string = 'WorldLocationEditViewModel';

/** 字段长度上限(与 WorldStateService 对齐) */
const LOCATION_NAME_MAX: number = 100;
const LOCATION_DESCRIPTION_MAX: number = 5000;

/** 编辑页加载状态 */
export enum WorldLocationEditLoadState {
  Loading = 'loading',
  Ready = 'ready',
  NotFound = 'not_found',
  Error = 'error'
}

export class WorldLocationEditViewModel {
  private readonly stateService: WorldStateService;
  private readonly locationRepository: WorldLocationRepository;

  /** 当前编辑的 worldId(必填) */
  private boundWorldId: string;
  /** 当前编辑的 locationId(创建模式为空) */
  private boundLocationId: string;
  /** 是否为创建模式 */
  readonly isCreateMode: boolean;

  /** 加载状态 */
  loadState: WorldLocationEditLoadState = WorldLocationEditLoadState.Loading;
  /** 名称输入 */
  nameInput: string = '';
  /** 描述输入 */
  descriptionInput: string = '';
  /** 当前地点状态(编辑模式) */
  currentStatus: WorldLocationStatus = WorldLocationStatus.Active;
  /** 是否正在保存 */
  isSaving: boolean = false;
  /** 是否正在删除 */
  isDeleting: boolean = false;
  /** 用户可见错误 */
  errorMessage: string = '';
  /** 保存成功后为 true,页面据此返回 */
  saveSucceeded: boolean = false;
  /** 删除成功后为 true,页面据此返回 */
  deleteSucceeded: boolean = false;

  /** 操作 ID(防重复提交) */
  private operationId: number = 0;
  /** 页面是否已销毁 */
  private disposed: boolean = false;

  constructor(
    stateService: WorldStateService,
    locationRepository: WorldLocationRepository,
    worldId: string,
    locationId: string
  ) {
    this.stateService = stateService;
    this.locationRepository = locationRepository;
    this.boundWorldId = worldId;
    this.boundLocationId = locationId;
    this.isCreateMode = locationId.length === 0;
  }

  /** 加载现有地点(编辑模式) */
  async loadLocation(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.isCreateMode) {
      this.loadState = WorldLocationEditLoadState.Ready;
      return;
    }
    this.loadState = WorldLocationEditLoadState.Loading;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const location: WorldLocation | null = await this.locationRepository.getById(this.boundLocationId);
      if (opId !== this.operationId || this.disposed) {
        return;
      }
      if (location === null) {
        this.loadState = WorldLocationEditLoadState.NotFound;
        return;
      }
      // 同步 worldId(防止上一页传错)
      this.boundWorldId = location.worldId;
      this.nameInput = location.name;
      this.descriptionInput = location.description;
      this.currentStatus = location.status;
      this.loadState = WorldLocationEditLoadState.Ready;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadLocation failed: ' + this.safeErrorCategory(e));
      this.loadState = WorldLocationEditLoadState.Error;
      this.errorMessage = '地点数据加载失败,请重试';
    }
  }

  /** 保存(创建或更新) */
  async save(): Promise<void> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return;
    }
    const trimmedName: string = this.nameInput.trim();
    if (trimmedName.length === 0) {
      this.errorMessage = '地点名称不能为空';
      return;
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      if (this.isCreateMode) {
        await this.stateService.createLocation(
          this.boundWorldId,
          trimmedName,
          this.descriptionInput.trim()
        );
      } else {
        await this.stateService.updateLocation(
          this.boundLocationId,
          trimmedName,
          this.descriptionInput.trim()
        );
      }
      if (this.disposed) {
        return;
      }
      this.saveSucceeded = true;
    } catch (e) {
      if (this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'save failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
    } finally {
      if (!this.disposed) {
        this.isSaving = false;
      }
    }
  }

  /** 归档或重新激活 */
  async setArchived(archived: boolean): Promise<void> {
    if (this.disposed || this.isSaving || this.isDeleting || this.isCreateMode) {
      return;
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      const updated: WorldLocation = await this.stateService.setLocationArchived(
        this.boundLocationId, archived
      );
      if (this.disposed) {
        return;
      }
      this.currentStatus = updated.status;
      this.nameInput = updated.name;
      this.descriptionInput = updated.description;
    } catch (e) {
      if (this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'setArchived failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
    } finally {
      if (!this.disposed) {
        this.isSaving = false;
      }
    }
  }

  /** 删除地点 */
  async deleteLocation(): Promise<void> {
    if (this.disposed || this.isSaving || this.isDeleting || this.isCreateMode) {
      return;
    }
    this.isDeleting = true;
    this.errorMessage = '';
    try {
      await this.stateService.deleteLocation(this.boundLocationId);
      if (this.disposed) {
        return;
      }
      this.deleteSucceeded = true;
    } catch (e) {
      if (this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'deleteLocation failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
    } finally {
      if (!this.disposed) {
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

  /** 名称长度上限 */
  getNameMax(): number {
    return LOCATION_NAME_MAX;
  }

  /** 描述长度上限 */
  getDescriptionMax(): number {
    return LOCATION_DESCRIPTION_MAX;
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
