/**
 * WorldCharacterMemoryService 世界角色记忆业务服务(W-MEMORY-1A)
 *
 * 职责:
 * - 世界角色实例独立长期记忆的唯一正式写入口
 * - 手动创建 / 编辑 / 归档 / 恢复 / 删除
 * - 跨表归属校验:World 存在 / CharacterInstance 存在且属于该 World / 来源 Location 属于该 World
 * - 软历史引用:来源 Location / Scene / Message 后续不存在时记忆仍保留
 *
 * 不负责(本阶段禁止):
 * - AI 自动提取记忆 / 模型总结 / 场景结束自动生成记忆
 * - 每条消息自动写记忆
 * - Prompt 注入 / 记忆检索排序算法 / 向量数据库 / Embedding
 * - 关系系统 / 地点知识 / 共享记忆 / 角色之间复制记忆
 *
 * 事务规则:
 * - 所有跨表操作使用 DbHelper.runInTransaction
 * - 事务内只调用 Repository 的 *WithStore 方法,不调用普通方法(避免嵌套事务)
 *
 * 依赖方向:
 * - WorldRepository(只读 getByIdWithStore)
 * - WorldLocationRepository(只读 getByIdWithStore)
 * - WorldCharacterInstanceRepository(只读 getByIdWithStore)
 * - WorldSceneRepository(只读 getByIdWithStore,验证来源 Scene)
 * - WorldSceneMessageRepository(只读 getByIdWithStore,验证来源 Message)
 * - WorldCharacterMemoryRepository(写入)
 * - DbHelper(事务)
 *
 * 日志安全:
 * - 不记录完整记忆正文 / 完整 ID / SQL 参数 / 数据库路径
 * - 仅记录操作类型、memoryType、origin、importance、status、数量、operationId、截断短 ID
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldCharacterMemoryRepository } from '../../repositories/world/WorldCharacterMemoryRepository';
import { World } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldScene } from '../../models/world/WorldScene';
import { WorldSceneMessage } from '../../models/world/WorldSceneMessage';
import {
  WorldCharacterMemory,
  WorldCharacterMemoryType,
  WorldCharacterMemoryOrigin,
  WorldCharacterMemoryStatus,
  WORLD_CHARACTER_MEMORY_ID_PREFIX,
  WORLD_CHARACTER_MEMORY_CONTENT_MAX,
  WORLD_CHARACTER_MEMORY_IMPORTANCE_MIN,
  WORLD_CHARACTER_MEMORY_IMPORTANCE_MAX,
  isWorldCharacterMemoryType,
  isWorldCharacterMemoryImportance,
  createWorldCharacterMemoryRecord
} from '../../models/world/WorldCharacterMemory';
import {
  WorldCharacterMemoryError,
  WorldCharacterMemoryErrorKind,
  isWorldCharacterMemoryError
} from '../../models/world/WorldCharacterMemoryError';
import { DatabaseError } from '../../models/DatabaseError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldCharacterMemoryService';

/** 手动记忆创建输入 */
export interface CreateManualWorldMemoryInput {
  readonly worldId: string;
  readonly characterInstanceId: string;
  readonly content: string;
  readonly type: WorldCharacterMemoryType;
  readonly importance: number;
  readonly sourceLocationId?: string;
  readonly occurredAt?: number;
}

/** 记忆更新输入 */
export interface UpdateWorldMemoryInput {
  readonly memoryId: string;
  readonly content: string;
  readonly type: WorldCharacterMemoryType;
  readonly importance: number;
  readonly sourceLocationId?: string;
  readonly occurredAt?: number;
}

export class WorldCharacterMemoryService {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly sceneMessageRepo: WorldSceneMessageRepository;
  private readonly memoryRepo: WorldCharacterMemoryRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sceneRepo: WorldSceneRepository,
    sceneMessageRepo: WorldSceneMessageRepository,
    memoryRepo: WorldCharacterMemoryRepository,
    dbHelper: DbHelper
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.sceneRepo = sceneRepo;
    this.sceneMessageRepo = sceneMessageRepo;
    this.memoryRepo = memoryRepo;
    this.dbHelper = dbHelper;
  }

  /** 获取单条记忆(只读,不走事务) */
  async getById(memoryId: string): Promise<WorldCharacterMemory | null> {
    if (memoryId === '') {
      throw WorldCharacterMemoryError.memoryNotFound();
    }
    return await this.memoryRepo.getById(memoryId);
  }

  /**
   * 列出指定角色实例的全部记忆(全部 / Active / Archived 由调用方决定筛选)。
   * 不走事务,直接读取。
   */
  async listByCharacterInstance(
    characterInstanceId: string,
    filter: WorldCharacterMemoryFilter
  ): Promise<WorldCharacterMemory[]> {
    if (characterInstanceId === '') {
      throw WorldCharacterMemoryError.characterInstanceNotFound();
    }
    if (filter === WorldCharacterMemoryFilter.Active) {
      return await this.memoryRepo.listActiveByCharacterInstance(characterInstanceId);
    }
    if (filter === WorldCharacterMemoryFilter.Archived) {
      return await this.memoryRepo.listArchivedByCharacterInstance(characterInstanceId);
    }
    return await this.memoryRepo.listByCharacterInstance(characterInstanceId);
  }

  /** 统计记忆数量(只读) */
  async countByCharacterInstance(characterInstanceId: string): Promise<number> {
    if (characterInstanceId === '') {
      return 0;
    }
    return await this.memoryRepo.countByCharacterInstance(characterInstanceId);
  }

  /**
   * 创建手动记忆。
   * 事务内校验:World 存在 → 实例存在 → 实例属于该 World →
   *   来源 Location 非空时 Location 存在且属于该 World → 插入记忆。
   * 固定 origin=Manual / status=Active。
   */
  async createManualMemory(input: CreateManualWorldMemoryInput): Promise<WorldCharacterMemory> {
    validateContent(input.content);
    validateType(input.type);
    validateImportance(input.importance);
    if (input.occurredAt !== undefined && (!Number.isFinite(input.occurredAt) || input.occurredAt <= 0)) {
      throw WorldCharacterMemoryError.invalidOperation('发生时间不合法');
    }

    const memoryId: string = WORLD_CHARACTER_MEMORY_ID_PREFIX + generateUuid();
    const now: number = nowMillis();

    let result: WorldCharacterMemory | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const world: World | null = await this.worldRepo.getByIdWithStore(store, input.worldId);
        if (world === null) {
          throw WorldCharacterMemoryError.worldNotFound();
        }
        const instance: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, input.characterInstanceId);
        if (instance === null) {
          throw WorldCharacterMemoryError.characterInstanceNotFound();
        }
        if (instance.worldId !== input.worldId) {
          throw WorldCharacterMemoryError.characterInstanceNotInWorld();
        }
        if (input.sourceLocationId !== undefined && input.sourceLocationId !== '') {
          const location: WorldLocation | null =
            await this.locationRepo.getByIdWithStore(store, input.sourceLocationId);
          if (location === null) {
            throw WorldCharacterMemoryError.locationNotFound();
          }
          if (location.worldId !== input.worldId) {
            throw WorldCharacterMemoryError.locationNotInWorld();
          }
        }

        const memory: WorldCharacterMemory = createWorldCharacterMemoryRecord({
          id: memoryId,
          worldId: input.worldId,
          characterInstanceId: input.characterInstanceId,
          type: input.type,
          origin: WorldCharacterMemoryOrigin.Manual,
          status: WorldCharacterMemoryStatus.Active,
          content: normalizeContent(input.content),
          importance: input.importance,
          sourceLocationId: input.sourceLocationId,
          occurredAt: input.occurredAt,
          createdAt: now,
          updatedAt: now
        });
        await this.memoryRepo.insertWithStore(store, memory);
        result = memory;
      },
      'world_memory_create'
    );
    if (result === null) {
      throw WorldCharacterMemoryError.internal('事务未产生结果');
    }
    const created: WorldCharacterMemory = result;
    Logger.info(LOG_TAG, 'createManualMemory: type=' + created.type
      + ' origin=' + created.origin + ' importance=' + created.importance
      + ' id=' + shortId(created.id));
    return created;
  }

  /**
   * 编辑记忆。
   * 允许修改:content / type / importance / sourceLocationId / occurredAt
   * 不得修改:worldId / characterInstanceId / origin / sourceSceneId / sourceMessageId / createdAt
   */
  async updateMemory(input: UpdateWorldMemoryInput): Promise<WorldCharacterMemory> {
    validateContent(input.content);
    validateType(input.type);
    validateImportance(input.importance);
    if (input.occurredAt !== undefined && (!Number.isFinite(input.occurredAt) || input.occurredAt <= 0)) {
      throw WorldCharacterMemoryError.invalidOperation('发生时间不合法');
    }

    let result: WorldCharacterMemory | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldCharacterMemory | null =
          await this.memoryRepo.getByIdWithStore(store, input.memoryId);
        if (existing === null) {
          throw WorldCharacterMemoryError.memoryNotFound();
        }
        if (input.sourceLocationId !== undefined && input.sourceLocationId !== '') {
          const location: WorldLocation | null =
            await this.locationRepo.getByIdWithStore(store, input.sourceLocationId);
          if (location === null) {
            throw WorldCharacterMemoryError.locationNotFound();
          }
          if (location.worldId !== existing.worldId) {
            throw WorldCharacterMemoryError.locationNotInWorld();
          }
        }
        const updated: WorldCharacterMemory = createWorldCharacterMemoryRecord({
          id: existing.id,
          worldId: existing.worldId,
          characterInstanceId: existing.characterInstanceId,
          type: input.type,
          origin: existing.origin,
          status: existing.status,
          content: normalizeContent(input.content),
          importance: input.importance,
          sourceSceneId: existing.sourceSceneId,
          sourceMessageId: existing.sourceMessageId,
          sourceLocationId: input.sourceLocationId,
          occurredAt: input.occurredAt,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.memoryRepo.updateWithStore(store, updated);
        result = updated;
      },
      'world_memory_update'
    );
    if (result === null) {
      throw WorldCharacterMemoryError.internal('事务未产生结果');
    }
    const updatedMemory: WorldCharacterMemory = result;
    Logger.info(LOG_TAG, 'updateMemory: id=' + shortId(updatedMemory.id)
      + ' type=' + updatedMemory.type + ' importance=' + updatedMemory.importance);
    return updatedMemory;
  }

  /**
   * 归档 / 恢复记忆。Active ↔ Archived 双向切换。
   */
  async setMemoryArchived(memoryId: string, archived: boolean): Promise<WorldCharacterMemory> {
    let result: WorldCharacterMemory | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldCharacterMemory | null =
          await this.memoryRepo.getByIdWithStore(store, memoryId);
        if (existing === null) {
          throw WorldCharacterMemoryError.memoryNotFound();
        }
        const targetStatus: WorldCharacterMemoryStatus = archived
          ? WorldCharacterMemoryStatus.Archived : WorldCharacterMemoryStatus.Active;
        if (existing.status === targetStatus) {
          result = existing;
          return;
        }
        const updated: WorldCharacterMemory = createWorldCharacterMemoryRecord({
          id: existing.id,
          worldId: existing.worldId,
          characterInstanceId: existing.characterInstanceId,
          type: existing.type,
          origin: existing.origin,
          status: targetStatus,
          content: existing.content,
          importance: existing.importance,
          sourceSceneId: existing.sourceSceneId,
          sourceMessageId: existing.sourceMessageId,
          sourceLocationId: existing.sourceLocationId,
          occurredAt: existing.occurredAt,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.memoryRepo.updateWithStore(store, updated);
        result = updated;
      },
      'world_memory_archive'
    );
    if (result === null) {
      throw WorldCharacterMemoryError.internal('事务未产生结果');
    }
    const archivedMemory: WorldCharacterMemory = result;
    Logger.info(LOG_TAG, 'setMemoryArchived: id=' + shortId(archivedMemory.id)
      + ' archived=' + archived + ' status=' + archivedMemory.status);
    return archivedMemory;
  }

  /**
   * 永久删除记忆。不级联删除其他记忆或来源 Scene / Message。
   */
  async deleteMemory(memoryId: string): Promise<void> {
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldCharacterMemory | null =
          await this.memoryRepo.getByIdWithStore(store, memoryId);
        if (existing === null) {
          throw WorldCharacterMemoryError.memoryNotFound();
        }
        await this.memoryRepo.deleteByIdWithStore(store, memoryId);
      },
      'world_memory_delete'
    );
    Logger.info(LOG_TAG, 'deleteMemory: id=' + shortId(memoryId));
  }

  /**
   * 仅供 WorldStateService.removeCharacterFromWorld 内部调用:
   * 在同一事务内删除该实例全部记忆。
   * 不在此方法做事务包装(由调用方持有事务)。
   */
  async deleteByCharacterInstanceWithStore(
    store: relationalStore.RdbStore,
    characterInstanceId: string
  ): Promise<void> {
    await this.memoryRepo.deleteByCharacterInstanceWithStore(store, characterInstanceId);
  }

  /**
   * 仅供 WorldStateService.deleteWorld 内部调用:
   * 在同一事务内删除该 World 全部记忆。
   * 不在此方法做事务包装(由调用方持有事务)。
   */
  async deleteByWorldWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    await this.memoryRepo.deleteByWorldWithStore(store, worldId);
  }
}

/** 记忆筛选 */
export enum WorldCharacterMemoryFilter {
  All = 'all',
  Active = 'active',
  Archived = 'archived'
}

// ===== 内部校验辅助 =====

function validateContent(content: string): void {
  const trimmed: string = content.trim();
  if (trimmed === '') {
    throw WorldCharacterMemoryError.memoryContentEmpty();
  }
  if (trimmed.length > WORLD_CHARACTER_MEMORY_CONTENT_MAX) {
    throw WorldCharacterMemoryError.memoryContentTooLong();
  }
}

function validateType(type: string): void {
  if (!isWorldCharacterMemoryType(type)) {
    throw WorldCharacterMemoryError.invalidMemoryType();
  }
}

function validateImportance(importance: number): void {
  if (!isWorldCharacterMemoryImportance(importance)) {
    throw WorldCharacterMemoryError.invalidImportance();
  }
}

function normalizeContent(content: string): string {
  // 保留内部换行,仅去除首尾空白
  return content.trim();
}

function shortId(id: string): string {
  if (id.length <= 12) {
    return id;
  }
  return id.substring(0, 8) + '…';
}

/**
 * 将 Service 抛出的错误安全映射为用户可见 message。
 * 不暴露内部枚举原值 / 表名 / SQL / 完整 ID / 堆栈。
 */
export function mapWorldCharacterMemoryErrorToMessage(e: Error): string {
  if (isWorldCharacterMemoryError(e)) {
    return e.message;
  }
  if (e instanceof DatabaseError) {
    return '记忆数据操作失败,请重试';
  }
  return '记忆操作失败,请重试';
}

/**
 * 用于暴露 WorldCharacterMemoryErrorKind 给 UI 层做错误分支(可选)。
 * 当前阶段 UI 仅使用 message。
 */
export function classifyWorldCharacterMemoryError(e: Error): WorldCharacterMemoryErrorKind {
  if (isWorldCharacterMemoryError(e)) {
    return (e as WorldCharacterMemoryError).kind;
  }
  return WorldCharacterMemoryErrorKind.Internal;
}
