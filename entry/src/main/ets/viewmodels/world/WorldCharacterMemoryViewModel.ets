/**
 * WorldCharacterMemoryViewModel 世界角色记忆页 ViewModel(W-MEMORY-1A)
 *
 * 职责:
 * - 根据 worldId + characterInstanceId 加载角色实例 + 头部信息 + 当前 World 地点列表 + 记忆列表
 * - 创建 / 编辑 / 归档 / 恢复 / 删除 记忆(调用 WorldCharacterMemoryService)
 * - 处理页面切换(expectedWorldId + expectedCharacterInstanceId + loadOperationId)和销毁(disposed)
 * - 写操作防重复(operationId + isSaving + isDeleting)
 * - 角色名称解析:实例+Character 存在→Character.name;实例存在+Character 缺失→displayNameSnapshot;实例已移除→"已移除角色"
 *
 * 不负责:
 * - AI 自动提取记忆 / Prompt 注入 / 检索排序
 * - 直接调用 Repository 的写入方法(只走 Service)
 *
 * 依赖方向:
 * Page → ViewModel → Repository(只读) / CharacterService(只读 getById) /
 *                    WorldCharacterMemoryService(写入)
 *
 * 日志安全:不记录完整记忆正文 / 完整 ID / SQL,仅记录操作类型、memoryType、importance、
 * status、数量、operationId、截断短 ID。
 */

import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { CharacterService } from '../../services/CharacterService';
import {
  WorldCharacterMemoryService,
  WorldCharacterMemoryFilter,
  CreateManualWorldMemoryInput,
  UpdateWorldMemoryInput
} from '../../services/world/WorldCharacterMemoryService';
import { Logger } from '../../utils/Logger';
import { World } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { Character } from '../../models/Character';
import {
  WorldCharacterMemory,
  WorldCharacterMemoryType,
  WorldCharacterMemoryOrigin,
  WorldCharacterMemoryStatus
} from '../../models/world/WorldCharacterMemory';
import { DatabaseError } from '../../models/DatabaseError';
import { mapWorldMemoryErrorToMessage } from './WorldMemoryErrorMapper';
import { formatWorldTimestamp } from './WorldUiModels';

const LOG_TAG: string = 'WorldCharacterMemoryViewModel';

/** 记忆页加载状态 */
export enum WorldCharacterMemoryLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

/** 记忆筛选 */
export enum WorldCharacterMemoryListFilter {
  All = 'all',
  Active = 'active',
  Archived = 'archived'
}

/** 角色头部 UI 模型 */
export interface MemoryCharacterHeaderUiModel {
  readonly worldId: string;
  readonly characterInstanceId: string;
  readonly displayName: string;
  readonly fallbackName: string;
  readonly avatarUri: string;
  readonly isActive: boolean;
  readonly characterCardMissing: boolean;
  readonly currentLocationId: string;
  readonly currentLocationName: string;
  readonly locationMissing: boolean;
  readonly memoryCount: number;
}

/** 地点候选项 UI 模型(用于"发生地点"选择) */
export interface MemoryLocationOptionUiModel {
  readonly id: string;
  readonly name: string;
  readonly status: string;
}

/** 记忆卡片 UI 模型(已本地化类型/状态/来源摘要) */
export interface MemoryItemUiModel {
  readonly id: string;
  readonly type: WorldCharacterMemoryType;
  readonly typeLabel: string;
  readonly origin: WorldCharacterMemoryOrigin;
  readonly originLabel: string;
  readonly status: WorldCharacterMemoryStatus;
  readonly statusLabel: string;
  readonly content: string;
  readonly importance: number;
  readonly sourceLocationId: string;
  readonly sourceLocationName: string;
  readonly sourceLocationMissing: boolean;
  readonly sourceSceneId: string;
  readonly sourceMessageId: string;
  readonly sourceSummary: string;
  readonly occurredAt: number;
  readonly occurredAtLabel: string;
  readonly createdAt: number;
  readonly createdAtLabel: string;
  readonly updatedAt: number;
}

/** 记忆页 UI 快照 */
export interface WorldCharacterMemorySnapshotUiModel {
  readonly header: MemoryCharacterHeaderUiModel;
  readonly memories: MemoryItemUiModel[];
  readonly locationOptions: MemoryLocationOptionUiModel[];
}

/** 创建记忆表单输入 */
export interface CreateMemoryFormInput {
  readonly content: string;
  readonly type: WorldCharacterMemoryType;
  readonly importance: number;
  readonly sourceLocationId?: string;
  readonly occurredAt?: number;
}

/** 编辑记忆表单输入 */
export interface UpdateMemoryFormInput {
  readonly memoryId: string;
  readonly content: string;
  readonly type: WorldCharacterMemoryType;
  readonly importance: number;
  readonly sourceLocationId?: string;
  readonly occurredAt?: number;
}

/** 写操作结果 */
export interface MemorySaveResult {
  readonly success: boolean;
  readonly errorMessage: string;
}

export class WorldCharacterMemoryViewModel {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly characterService: CharacterService;
  private readonly memoryService: WorldCharacterMemoryService;

  state: WorldCharacterMemoryLoadState = WorldCharacterMemoryLoadState.Loading;
  errorMessage: string = '';
  snapshot: WorldCharacterMemorySnapshotUiModel | null = null;

  private expectedWorldId: string = '';
  private expectedCharacterInstanceId: string = '';
  private loadOperationId: number = 0;
  private operationId: number = 0;
  private disposed: boolean = false;
  isSaving: boolean = false;
  isDeleting: boolean = false;
  readonly instanceShortId: string;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    characterService: CharacterService,
    memoryService: WorldCharacterMemoryService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.characterService = characterService;
    this.memoryService = memoryService;
    this.instanceShortId = WorldCharacterMemoryViewModel.generateShortId();
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

  setTarget(worldId: string, characterInstanceId: string): void {
    if (this.expectedWorldId !== worldId
      || this.expectedCharacterInstanceId !== characterInstanceId) {
      this.expectedWorldId = worldId;
      this.expectedCharacterInstanceId = characterInstanceId;
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  expectedWorldIdOfPage(): string {
    return this.expectedWorldId;
  }

  expectedCharacterInstanceIdOfPage(): string {
    return this.expectedCharacterInstanceId;
  }

  /**
   * 加载记忆页快照。每次 onPageShow 和写操作完成后调用。
   */
  async loadSnapshot(
    worldId: string,
    characterInstanceId: string,
    filter: WorldCharacterMemoryListFilter
  ): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'loadSnapshot skipped: disposed vmInstance=' + this.instanceShortId);
      return;
    }
    this.expectedWorldId = worldId;
    this.expectedCharacterInstanceId = characterInstanceId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;

    this.state = WorldCharacterMemoryLoadState.Loading;
    this.errorMessage = '';

    try {
      const world: World | null = await this.worldRepo.getById(worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.state = WorldCharacterMemoryLoadState.NotFound;
        return;
      }

      const instance: WorldCharacterInstance | null =
        await this.instanceRepo.getById(characterInstanceId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (instance === null) {
        this.state = WorldCharacterMemoryLoadState.NotFound;
        return;
      }
      if (instance.worldId !== worldId) {
        this.state = WorldCharacterMemoryLoadState.NotFound;
        return;
      }

      // 解析角色卡
      let character: Character | null = null;
      if (instance.characterId.length > 0) {
        try {
          character = await this.characterService.getById(instance.characterId);
        } catch (e) {
          Logger.warn(LOG_TAG, 'characterService.getById failed: ' + this.safeErrorCategory(e));
          character = null;
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const characterMissing: boolean = character === null;
      const displayName: string = !characterMissing && character !== null
        ? character.name : instance.displayNameSnapshot;
      const avatarUri: string = !characterMissing && character !== null
        ? character.avatarUri : '';

      // 解析当前位置名称
      let currentLocationName: string = '';
      let locationMissing: boolean = false;
      if (instance.currentLocationId !== undefined && instance.currentLocationId.length > 0) {
        try {
          const loc: WorldLocation | null =
            await this.locationRepo.getById(instance.currentLocationId);
          if (loc !== null) {
            currentLocationName = loc.name;
          } else {
            locationMissing = true;
          }
        } catch (e) {
          Logger.warn(LOG_TAG, 'locationRepo.getById(current) failed: ' + this.safeErrorCategory(e));
          locationMissing = true;
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 加载当前 World 全部地点(用于"发生地点"候选,允许 Archived)
      let locations: WorldLocation[] = [];
      try {
        locations = await this.locationRepo.listByWorld(worldId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'locationRepo.listByWorld failed: ' + this.safeErrorCategory(e));
        locations = [];
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 加载记忆列表
      const memoryFilter: WorldCharacterMemoryFilter = this.toServiceFilter(filter);
      let memories: WorldCharacterMemory[] = [];
      try {
        memories = await this.memoryService.listByCharacterInstance(characterInstanceId, memoryFilter);
      } catch (e) {
        Logger.warn(LOG_TAG, 'listByCharacterInstance failed: ' + this.safeErrorCategory(e));
        memories = [];
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 记忆总数(不受筛选影响)
      let memoryCount: number = 0;
      try {
        memoryCount = await this.memoryService.countByCharacterInstance(characterInstanceId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'countByCharacterInstance failed: ' + this.safeErrorCategory(e));
        memoryCount = memories.length;
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 构建地点 Map(用于来源地点名称解析)
      const locationMap: Map<string, WorldLocation> = new Map<string, WorldLocation>();
      for (let i = 0; i < locations.length; i++) {
        locationMap.set(locations[i].id, locations[i]);
      }

      // 构建 UI 模型
      const header: MemoryCharacterHeaderUiModel = {
        worldId: world.id,
        characterInstanceId: instance.id,
        displayName: displayName,
        fallbackName: instance.displayNameSnapshot,
        avatarUri: avatarUri,
        isActive: instance.isActive,
        characterCardMissing: characterMissing,
        currentLocationId: instance.currentLocationId !== undefined ? instance.currentLocationId : '',
        currentLocationName: currentLocationName,
        locationMissing: locationMissing,
        memoryCount: memoryCount
      };

      const locationOptions: MemoryLocationOptionUiModel[] =
        new Array<MemoryLocationOptionUiModel>(locations.length);
      for (let i = 0; i < locations.length; i++) {
        locationOptions[i] = {
          id: locations[i].id,
          name: locations[i].name,
          status: locations[i].status
        };
      }

      const memoryItems: MemoryItemUiModel[] = new Array<MemoryItemUiModel>(memories.length);
      for (let i = 0; i < memories.length; i++) {
        memoryItems[i] = this.buildMemoryItem(memories[i], locationMap);
      }

      const snapshot: WorldCharacterMemorySnapshotUiModel = {
        header: header,
        memories: memoryItems,
        locationOptions: locationOptions
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.snapshot = snapshot;
      this.state = WorldCharacterMemoryLoadState.Ready;
      Logger.info(LOG_TAG, 'loadSnapshot done: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', state=ready, memoryCount=' + memoryItems.length.toString()
        + ', instanceShortId=' + this.shortId(characterInstanceId));
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', ' + this.safeErrorCategory(e)
        + ', instanceShortId=' + this.shortId(characterInstanceId));
      this.errorMessage = '记忆数据加载失败,请重试';
      this.state = WorldCharacterMemoryLoadState.Error;
    }
  }

  /** 创建手动记忆 */
  async createMemory(input: CreateMemoryFormInput): Promise<MemorySaveResult> {
    if (this.isSaving) {
      Logger.warn(LOG_TAG, 'createMemory skipped: isSaving');
      return { success: false, errorMessage: '正在处理,请稍候' } as MemorySaveResult;
    }
    if (this.expectedWorldId.length === 0 || this.expectedCharacterInstanceId.length === 0) {
      return { success: false, errorMessage: '目标未加载' } as MemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const serviceInput: CreateManualWorldMemoryInput = {
        worldId: this.expectedWorldId,
        characterInstanceId: this.expectedCharacterInstanceId,
        content: input.content,
        type: input.type,
        importance: input.importance,
        sourceLocationId: input.sourceLocationId,
        occurredAt: input.occurredAt
      };
      await this.memoryService.createManualMemory(serviceInput);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      Logger.info(LOG_TAG, 'createMemory ok: type=' + input.type
        + ', importance=' + input.importance.toString()
        + ', instanceShortId=' + this.shortId(this.expectedCharacterInstanceId));
      return { success: true, errorMessage: '' } as MemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'createMemory failed: ' + this.safeErrorCategory(e)
        + ', type=' + input.type
        + ', instanceShortId=' + this.shortId(this.expectedCharacterInstanceId));
      return { success: false, errorMessage: msg } as MemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /** 编辑记忆 */
  async updateMemory(input: UpdateMemoryFormInput): Promise<MemorySaveResult> {
    if (this.isSaving) {
      Logger.warn(LOG_TAG, 'updateMemory skipped: isSaving');
      return { success: false, errorMessage: '正在处理,请稍候' } as MemorySaveResult;
    }
    if (input.memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as MemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const serviceInput: UpdateWorldMemoryInput = {
        memoryId: input.memoryId,
        content: input.content,
        type: input.type,
        importance: input.importance,
        sourceLocationId: input.sourceLocationId,
        occurredAt: input.occurredAt
      };
      await this.memoryService.updateMemory(serviceInput);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      Logger.info(LOG_TAG, 'updateMemory ok: type=' + input.type
        + ', importance=' + input.importance.toString()
        + ', memoryShortId=' + this.shortId(input.memoryId));
      return { success: true, errorMessage: '' } as MemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'updateMemory failed: ' + this.safeErrorCategory(e)
        + ', type=' + input.type
        + ', memoryShortId=' + this.shortId(input.memoryId));
      return { success: false, errorMessage: msg } as MemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /** 归档 / 恢复记忆 */
  async setMemoryArchived(
    memoryId: string,
    archived: boolean
  ): Promise<MemorySaveResult> {
    if (this.isSaving || this.isDeleting) {
      Logger.warn(LOG_TAG, 'setMemoryArchived skipped: busy');
      return { success: false, errorMessage: '正在处理,请稍候' } as MemorySaveResult;
    }
    if (memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as MemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.memoryService.setMemoryArchived(memoryId, archived);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      Logger.info(LOG_TAG, 'setMemoryArchived ok: archived=' + archived.toString()
        + ', memoryShortId=' + this.shortId(memoryId));
      return { success: true, errorMessage: '' } as MemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'setMemoryArchived failed: ' + this.safeErrorCategory(e)
        + ', memoryShortId=' + this.shortId(memoryId));
      return { success: false, errorMessage: msg } as MemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /** 永久删除记忆 */
  async deleteMemory(memoryId: string): Promise<MemorySaveResult> {
    if (this.isDeleting) {
      Logger.warn(LOG_TAG, 'deleteMemory skipped: isDeleting');
      return { success: false, errorMessage: '正在处理,请稍候' } as MemorySaveResult;
    }
    if (memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as MemorySaveResult;
    }
    this.isDeleting = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.memoryService.deleteMemory(memoryId);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      Logger.info(LOG_TAG, 'deleteMemory ok: memoryShortId=' + this.shortId(memoryId));
      return { success: true, errorMessage: '' } as MemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'deleteMemory failed: ' + this.safeErrorCategory(e)
        + ', memoryShortId=' + this.shortId(memoryId));
      return { success: false, errorMessage: msg } as MemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isDeleting = false;
      }
    }
  }

  // ===== 私有辅助 =====

  private toServiceFilter(filter: WorldCharacterMemoryListFilter): WorldCharacterMemoryFilter {
    if (filter === WorldCharacterMemoryListFilter.Active) {
      return WorldCharacterMemoryFilter.Active;
    }
    if (filter === WorldCharacterMemoryListFilter.Archived) {
      return WorldCharacterMemoryFilter.Archived;
    }
    return WorldCharacterMemoryFilter.All;
  }

  private buildMemoryItem(
    memory: WorldCharacterMemory,
    locationMap: Map<string, WorldLocation>
  ): MemoryItemUiModel {
    let sourceLocationName: string = '';
    let sourceLocationMissing: boolean = false;
    if (memory.sourceLocationId !== undefined && memory.sourceLocationId.length > 0) {
      const loc: WorldLocation | undefined = locationMap.get(memory.sourceLocationId);
      if (loc !== undefined) {
        sourceLocationName = loc.name;
      } else {
        sourceLocationMissing = true;
      }
    }
    const sourceSummary: string = this.buildSourceSummary(memory, sourceLocationName, sourceLocationMissing);
    return {
      id: memory.id,
      type: memory.type,
      typeLabel: this.typeLabel(memory.type),
      origin: memory.origin,
      originLabel: this.originLabel(memory.origin),
      status: memory.status,
      statusLabel: this.statusLabel(memory.status),
      content: memory.content,
      importance: memory.importance,
      sourceLocationId: memory.sourceLocationId !== undefined ? memory.sourceLocationId : '',
      sourceLocationName: sourceLocationName,
      sourceLocationMissing: sourceLocationMissing,
      sourceSceneId: memory.sourceSceneId !== undefined ? memory.sourceSceneId : '',
      sourceMessageId: memory.sourceMessageId !== undefined ? memory.sourceMessageId : '',
      sourceSummary: sourceSummary,
      occurredAt: memory.occurredAt !== undefined ? memory.occurredAt : 0,
      occurredAtLabel: memory.occurredAt !== undefined ? formatWorldTimestamp(memory.occurredAt) : '',
      createdAt: memory.createdAt,
      createdAtLabel: formatWorldTimestamp(memory.createdAt),
      updatedAt: memory.updatedAt
    };
  }

  private buildSourceSummary(
    memory: WorldCharacterMemory,
    locationName: string,
    locationMissing: boolean
  ): string {
    const parts: string[] = [];
    if (memory.origin === WorldCharacterMemoryOrigin.SceneMessage) {
      const sceneId: string = memory.sourceSceneId ?? '';
      const messageId: string = memory.sourceMessageId ?? '';
      if (sceneId.length === 0) {
        parts.push('场景已删除');
      } else if (messageId.length === 0) {
        parts.push('消息已删除');
      } else {
        parts.push('场景消息');
      }
    }
    const locationId: string = memory.sourceLocationId ?? '';
    if (locationId.length > 0) {
      if (locationMissing) {
        parts.push('地点已删除');
      } else if (locationName.length > 0) {
        parts.push(locationName);
      }
    }
    return parts.join(' · ');
  }

  private typeLabel(type: WorldCharacterMemoryType): string {
    if (type === WorldCharacterMemoryType.Episodic) {
      return '事件记忆';
    }
    if (type === WorldCharacterMemoryType.Semantic) {
      return '事实认知';
    }
    return '反思总结';
  }

  private originLabel(origin: WorldCharacterMemoryOrigin): string {
    return origin === WorldCharacterMemoryOrigin.Manual ? '手动' : '场景消息';
  }

  private statusLabel(status: WorldCharacterMemoryStatus): string {
    return status === WorldCharacterMemoryStatus.Active ? '活跃' : '已归档';
  }

  private resolveErrorMessage(e: Object): string {
    return mapWorldMemoryErrorToMessage(e);
  }

  private safeErrorCategory(e: Object): string {
    if (e instanceof DatabaseError) {
      return 'DatabaseError:' + e.type;
    }
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }

  private shortId(id: string): string {
    if (id.length <= 8) {
      return id;
    }
    return id.substring(id.length - 8);
  }
}
