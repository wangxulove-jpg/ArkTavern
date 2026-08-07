/**
 * WorldEditViewModel 世界编辑页 ViewModel(W-CONTROL-1A)
 *
 * 职责:
 * - 创建模式:无 worldId,调用 WorldStateService.createWorld
 * - 编辑模式:有 worldId,加载真实 World,调用 updateWorld / setWorldArchived / deleteWorld
 * - 防重复提交(isSaving / isDeleting / operationId)
 * - 页面销毁后不更新状态(disposed)
 * - 错误映射为用户安全文案
 *
 * 依赖方向:Page → ViewModel → WorldStateService(写) + WorldRepository(只读加载)
 */

import { WorldStateService } from '../../services/world/WorldStateService';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { World, WorldStatus } from '../../models/world/World';
import { Logger } from '../../utils/Logger';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';

const LOG_TAG: string = 'WorldEditViewModel';

/** 字段长度上限(与 WorldStateService 对齐) */
const WORLD_NAME_MAX: number = 100;
const WORLD_DESCRIPTION_MAX: number = 5000;

/** 编辑页加载状态 */
export enum WorldEditLoadState {
  Loading = 'loading',
  Ready = 'ready',
  NotFound = 'not_found',
  Error = 'error'
}

export class WorldEditViewModel {
  private readonly stateService: WorldStateService;
  private readonly worldRepository: WorldRepository;

  /** 是否为创建模式(worldId 为空) */
  readonly isCreateMode: boolean;
  /** 当前编辑的 worldId(创建模式为空) */
  private boundWorldId: string = '';

  /** 加载状态 */
  loadState: WorldEditLoadState = WorldEditLoadState.Loading;
  /** 名称输入 */
  nameInput: string = '';
  /** 描述输入 */
  descriptionInput: string = '';
  /** 玩家显示名称输入(仅创建模式) */
  playerDisplayNameInput: string = '';
  /** 当前世界状态(编辑模式) */
  currentStatus: WorldStatus = WorldStatus.Active;
  /** 是否正在保存 */
  isSaving: boolean = false;
  /** 是否正在删除 */
  isDeleting: boolean = false;
  /** 用户可见错误(空字符串表示无错误) */
  errorMessage: string = '';
  /** 保存成功后为 true,页面据此返回 */
  saveSucceeded: boolean = false;
  /** 删除成功后为 true,页面据此返回列表 */
  deleteSucceeded: boolean = false;

  /** 操作 ID(防重复提交) */
  private operationId: number = 0;
  /** 页面是否已销毁 */
  private disposed: boolean = false;

  constructor(stateService: WorldStateService, worldRepository: WorldRepository, worldId: string) {
    this.stateService = stateService;
    this.worldRepository = worldRepository;
    this.isCreateMode = worldId.length === 0;
    this.boundWorldId = worldId;
  }

  /** 加载现有世界(编辑模式) */
  async loadWorld(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.isCreateMode) {
      this.loadState = WorldEditLoadState.Ready;
      return;
    }
    this.loadState = WorldEditLoadState.Loading;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const world: World | null = await this.worldRepository.getById(this.boundWorldId);
      if (opId !== this.operationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.loadState = WorldEditLoadState.NotFound;
        return;
      }
      this.nameInput = world.name;
      this.descriptionInput = world.description;
      this.currentStatus = world.status;
      this.boundWorldId = world.id;
      this.loadState = WorldEditLoadState.Ready;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadWorld failed: ' + this.safeErrorCategory(e));
      this.loadState = WorldEditLoadState.Error;
      this.errorMessage = '世界数据加载失败,请重试';
    }
  }

  /** 保存(创建或更新) */
  async save(): Promise<void> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return;
    }
    const trimmedName: string = this.nameInput.trim();
    if (trimmedName.length === 0) {
      this.errorMessage = '世界名称不能为空';
      return;
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      if (this.isCreateMode) {
        const playerName: string = this.playerDisplayNameInput.trim();
        if (playerName.length === 0) {
          this.errorMessage = '玩家名称不能为空';
          this.isSaving = false;
          return;
        }
        await this.stateService.createWorld(trimmedName, this.descriptionInput.trim(), playerName);
      } else {
        await this.stateService.updateWorld(
          this.boundWorldId,
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
      const updated: World = await this.stateService.setWorldArchived(this.boundWorldId, archived);
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

  /** 硬删除世界 */
  async deleteWorld(): Promise<void> {
    if (this.disposed || this.isSaving || this.isDeleting || this.isCreateMode) {
      return;
    }
    this.isDeleting = true;
    this.errorMessage = '';
    try {
      await this.stateService.deleteWorld(this.boundWorldId);
      if (this.disposed) {
        return;
      }
      this.deleteSucceeded = true;
    } catch (e) {
      if (this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'deleteWorld failed: ' + this.safeErrorCategory(e));
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
    return WORLD_NAME_MAX;
  }

  /** 描述长度上限 */
  getDescriptionMax(): number {
    return WORLD_DESCRIPTION_MAX;
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
