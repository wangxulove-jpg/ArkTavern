/**
 * WorldCharacterMemoryRepository
 *
 * 职责(W-MEMORY-1A):
 * - world_character_memories 表的 CRUD 操作
 * - 提供事务内写入方法(insertWithStore / updateWithStore /
 *   deleteByIdWithStore / deleteByCharacterInstanceWithStore / deleteByWorldWithStore)
 * - 行对象转换(TEXT ↔ 枚举、NULL ↔ undefined、INTEGER ↔ number)
 *
 * 不负责:
 * - 跨表业务验证(见 WorldCharacterMemoryService)
 * - 记忆 ID 生成(由 Service 调用 generateUuid 后传入)
 * - AI 总结 / Prompt 选择 / 相似度 / 记忆自动合并
 *
 * 排序规则:
 * - listByCharacterInstance:status ASC, importance DESC, occurredAt DESC, updatedAt DESC, id ASC
 * - listActiveByCharacterInstance:importance DESC, occurredAt DESC, updatedAt DESC, id ASC
 * - listArchivedByCharacterInstance:importance DESC, occurredAt DESC, updatedAt DESC, id ASC
 * - listByType / listBySourceScene / listBySourceMessage:updatedAt DESC, id ASC
 *
 * 日志安全:
 * - 不记录完整记忆正文、完整 ID、SQL 参数
 * - 仅在抛错时附带截断后 cause message
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldCharacterMemory,
  WorldCharacterMemoryType,
  WorldCharacterMemoryOrigin,
  WorldCharacterMemoryStatus,
  isWorldCharacterMemoryType,
  isWorldCharacterMemoryOrigin,
  isWorldCharacterMemoryStatus,
  isWorldCharacterMemoryImportance
} from '../../models/world/WorldCharacterMemory';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_CHARACTER_MEMORIES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_CHARACTER_INSTANCE_ID,
  COLUMN_MEMORY_TYPE_WCM,
  COLUMN_ORIGIN_TYPE,
  COLUMN_STATUS,
  COLUMN_CONTENT,
  COLUMN_IMPORTANCE_WCM,
  COLUMN_SOURCE_SCENE_ID,
  COLUMN_SOURCE_MESSAGE_ID,
  COLUMN_SOURCE_LOCATION_ID,
  COLUMN_OCCURRED_AT,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

const STATUS_ACTIVE: string = WorldCharacterMemoryStatus.Active;
const STATUS_ARCHIVED: string = WorldCharacterMemoryStatus.Archived;

export class WorldCharacterMemoryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldCharacterMemory | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldCharacterMemory | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return memoryFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定角色实例的全部记忆。
   * 排序:status ASC, importance DESC, occurredAt DESC, updatedAt DESC, id ASC
   * occurredAt 为 NULL 时按 0 处理(在排序中视为最早)。
   */
  async listByCharacterInstance(characterInstanceId: string): Promise<WorldCharacterMemory[]> {
    if (characterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.listByCharacterInstance: instanceId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.queryListByInstance(store, characterInstanceId, undefined);
  }

  async listByCharacterInstanceWithStore(
    store: relationalStore.RdbStore,
    characterInstanceId: string
  ): Promise<WorldCharacterMemory[]> {
    if (characterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.listByCharacterInstanceWithStore: instanceId empty');
    }
    return await this.queryListByInstance(store, characterInstanceId, undefined);
  }

  /**
   * 列出指定角色实例的 Active 记忆。
   * 排序:importance DESC, occurredAt DESC, updatedAt DESC, id ASC
   */
  async listActiveByCharacterInstance(characterInstanceId: string): Promise<WorldCharacterMemory[]> {
    if (characterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.listActiveByCharacterInstance: instanceId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.queryListByInstance(store, characterInstanceId, STATUS_ACTIVE);
  }

  /**
   * 列出指定角色实例的 Archived 记忆。
   * 排序:importance DESC, occurredAt DESC, updatedAt DESC, id ASC
   */
  async listArchivedByCharacterInstance(characterInstanceId: string): Promise<WorldCharacterMemory[]> {
    if (characterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.listArchivedByCharacterInstance: instanceId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.queryListByInstance(store, characterInstanceId, STATUS_ARCHIVED);
  }

  /**
   * 列出指定 World 内某类型的全部记忆。
   * 排序:updatedAt DESC, id ASC
   */
  async listByType(worldId: string, type: WorldCharacterMemoryType): Promise<WorldCharacterMemory[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.listByType: worldId empty');
    }
    if (!isWorldCharacterMemoryType(type)) {
      throw DatabaseError.invalidData(`WorldCharacterMemory.listByType: type invalid: ${type}`);
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_MEMORY_TYPE_WCM, type);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    return await this.collectList(store, predicates);
  }

  /**
   * 列出指定 Scene 中作为来源的全部记忆。
   * 排序:updatedAt DESC, id ASC
   */
  async listBySourceScene(sceneId: string): Promise<WorldCharacterMemory[]> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.listBySourceScene: sceneId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_SOURCE_SCENE_ID, sceneId);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    return await this.collectList(store, predicates);
  }

  /**
   * 列出指定 SourceMessage 的全部记忆。
   * 排序:updatedAt DESC, id ASC
   */
  async listBySourceMessage(messageId: string): Promise<WorldCharacterMemory[]> {
    if (messageId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.listBySourceMessage: messageId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_SOURCE_MESSAGE_ID, messageId);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    return await this.collectList(store, predicates);
  }

  async countByCharacterInstance(characterInstanceId: string): Promise<number> {
    if (characterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.countByCharacterInstance: instanceId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.countByCharacterInstanceWithStore(store, characterInstanceId);
  }

  async countByCharacterInstanceWithStore(
    store: relationalStore.RdbStore,
    characterInstanceId: string
  ): Promise<number> {
    if (characterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.countByCharacterInstanceWithStore: instanceId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_CHARACTER_INSTANCE_ID, characterInstanceId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.rowCount;
    } finally {
      rs.close();
    }
  }

  async insert(memory: WorldCharacterMemory): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.insertWithStore(store, memory);
  }

  async insertWithStore(store: relationalStore.RdbStore, memory: WorldCharacterMemory): Promise<void> {
    this.validateMemory(memory);
    try {
      await store.insert(TABLE_WORLD_CHARACTER_MEMORIES, memoryToBucket(memory));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldCharacterMemory.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldCharacterMemory.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(memory: WorldCharacterMemory): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.updateWithStore(store, memory);
  }

  async updateWithStore(store: relationalStore.RdbStore, memory: WorldCharacterMemory): Promise<void> {
    this.validateMemory(memory);
    const bucket: relationalStore.ValuesBucket = memoryToBucket(memory);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_ID, memory.id);
    try {
      const affected: number = await store.update(bucket, predicates);
      if (affected === 0) {
        throw DatabaseError.notFound('WorldCharacterMemory.updateWithStore');
      }
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.queryFailed(`WorldCharacterMemory.updateWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.deleteByIdWithStore(store, id);
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldCharacterMemory.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除指定角色实例的全部记忆。
   * 幂等:不存在返回 0,不抛错。
   * 用于 WorldStateService.removeCharacterFromWorld 同事务级联。
   */
  async deleteByCharacterInstanceWithStore(
    store: relationalStore.RdbStore,
    characterInstanceId: string
  ): Promise<void> {
    if (characterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.deleteByCharacterInstanceWithStore: instanceId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_CHARACTER_INSTANCE_ID, characterInstanceId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldCharacterMemory.deleteByCharacterInstanceWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 在事务内删除指定 World 的全部记忆。
   * 幂等:不存在返回 0,不抛错。
   * 用于 WorldStateService.deleteWorld 同事务级联。
   */
  async deleteByWorldWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.deleteByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldCharacterMemory.deleteByWorldWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  // ===== 内部辅助 =====

  private async queryListByInstance(
    store: relationalStore.RdbStore,
    characterInstanceId: string,
    statusFilter: string | undefined
  ): Promise<WorldCharacterMemory[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_CHARACTER_INSTANCE_ID, characterInstanceId);
    if (statusFilter !== undefined) {
      predicates.equalTo(COLUMN_STATUS, statusFilter);
    } else {
      // 全部列表:Active 排在前,Archived 排在后
      predicates.orderByAsc(COLUMN_STATUS);
    }
    predicates.orderByDesc(COLUMN_IMPORTANCE_WCM);
    predicates.orderByDesc(COLUMN_OCCURRED_AT);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    return await this.collectList(store, predicates);
  }

  private async collectList(
    store: relationalStore.RdbStore,
    predicates: relationalStore.RdbPredicates
  ): Promise<WorldCharacterMemory[]> {
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldCharacterMemory[] = [];
      while (rs.goToNextRow()) {
        list.push(memoryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  private validateMemory(memory: WorldCharacterMemory): void {
    if (memory.id === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.id empty');
    }
    if (memory.worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.worldId empty');
    }
    if (memory.characterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.characterInstanceId empty');
    }
    if (!isWorldCharacterMemoryType(memory.type)) {
      throw DatabaseError.invalidData(`WorldCharacterMemory.type invalid: ${memory.type}`);
    }
    if (!isWorldCharacterMemoryOrigin(memory.origin)) {
      throw DatabaseError.invalidData(`WorldCharacterMemory.origin invalid: ${memory.origin}`);
    }
    if (!isWorldCharacterMemoryStatus(memory.status)) {
      throw DatabaseError.invalidData(`WorldCharacterMemory.status invalid: ${memory.status}`);
    }
    if (memory.content === '') {
      throw DatabaseError.invalidData('WorldCharacterMemory.content empty');
    }
    if (!isWorldCharacterMemoryImportance(memory.importance)) {
      throw DatabaseError.invalidData(`WorldCharacterMemory.importance invalid: ${memory.importance}`);
    }
    if (!isValidTimestamp(memory.createdAt)) {
      throw DatabaseError.invalidData('WorldCharacterMemory.createdAt invalid');
    }
    if (!isValidTimestamp(memory.updatedAt)) {
      throw DatabaseError.invalidData('WorldCharacterMemory.updatedAt invalid');
    }
  }
}

function memoryToBucket(memory: WorldCharacterMemory): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = memory.id;
  bucket[COLUMN_WORLD_ID] = memory.worldId;
  bucket[COLUMN_CHARACTER_INSTANCE_ID] = memory.characterInstanceId;
  bucket[COLUMN_MEMORY_TYPE_WCM] = memory.type;
  bucket[COLUMN_ORIGIN_TYPE] = memory.origin;
  bucket[COLUMN_STATUS] = memory.status;
  bucket[COLUMN_CONTENT] = memory.content;
  bucket[COLUMN_IMPORTANCE_WCM] = memory.importance;
  bucket[COLUMN_SOURCE_SCENE_ID] = memory.sourceSceneId !== undefined ? memory.sourceSceneId : null;
  bucket[COLUMN_SOURCE_MESSAGE_ID] = memory.sourceMessageId !== undefined ? memory.sourceMessageId : null;
  bucket[COLUMN_SOURCE_LOCATION_ID] = memory.sourceLocationId !== undefined ? memory.sourceLocationId : null;
  bucket[COLUMN_OCCURRED_AT] = memory.occurredAt !== undefined ? memory.occurredAt : null;
  bucket[COLUMN_CREATED_AT] = memory.createdAt;
  bucket[COLUMN_UPDATED_AT] = memory.updatedAt;
  return bucket;
}

function readOptionalString(rs: relationalStore.ResultSet, columnName: string): string | undefined {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return undefined;
  }
  if (rs.isColumnNull(col)) {
    return undefined;
  }
  const value: string = rs.getString(col);
  return value !== '' ? value : undefined;
}

function readOptionalLong(rs: relationalStore.ResultSet, columnName: string): number | undefined {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return undefined;
  }
  if (rs.isColumnNull(col)) {
    return undefined;
  }
  const value: number = rs.getLong(col);
  if (!Number.isFinite(value) || value <= 0) {
    return undefined;
  }
  return value;
}

function memoryFromRow(rs: relationalStore.ResultSet): WorldCharacterMemory {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldCharacterMemory.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldCharacterMemory.worldId empty in row');
  }
  const characterInstanceId: string = rs.getString(rs.getColumnIndex(COLUMN_CHARACTER_INSTANCE_ID));
  if (characterInstanceId === '') {
    throw DatabaseError.invalidData('WorldCharacterMemory.characterInstanceId empty in row');
  }
  const typeRaw: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_TYPE_WCM));
  if (!isWorldCharacterMemoryType(typeRaw)) {
    throw DatabaseError.invalidData(`WorldCharacterMemory.type invalid in row: ${typeRaw}`);
  }
  const originRaw: string = rs.getString(rs.getColumnIndex(COLUMN_ORIGIN_TYPE));
  if (!isWorldCharacterMemoryOrigin(originRaw)) {
    throw DatabaseError.invalidData(`WorldCharacterMemory.origin invalid in row: ${originRaw}`);
  }
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  if (!isWorldCharacterMemoryStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldCharacterMemory.status invalid in row: ${statusRaw}`);
  }
  const content: string = rs.getString(rs.getColumnIndex(COLUMN_CONTENT));
  const importance: number = rs.getLong(rs.getColumnIndex(COLUMN_IMPORTANCE_WCM));
  if (!isWorldCharacterMemoryImportance(importance)) {
    throw DatabaseError.invalidData(`WorldCharacterMemory.importance invalid in row: ${importance}`);
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldCharacterMemory.createdAt invalid in row');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('WorldCharacterMemory.updatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    characterInstanceId: characterInstanceId,
    type: typeRaw as WorldCharacterMemoryType,
    origin: originRaw as WorldCharacterMemoryOrigin,
    status: statusRaw as WorldCharacterMemoryStatus,
    content: content,
    importance: importance,
    sourceSceneId: readOptionalString(rs, COLUMN_SOURCE_SCENE_ID),
    sourceMessageId: readOptionalString(rs, COLUMN_SOURCE_MESSAGE_ID),
    sourceLocationId: readOptionalString(rs, COLUMN_SOURCE_LOCATION_ID),
    occurredAt: readOptionalLong(rs, COLUMN_OCCURRED_AT),
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
