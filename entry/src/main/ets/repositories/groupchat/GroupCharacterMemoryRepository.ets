/**
 * GroupCharacterMemoryRepository
 *
 * 职责(G-MEMORY-1A):
 * - group_character_memories 表的 CRUD 操作
 * - 提供事务内写入方法(insertWithStore / updateWithStore /
 *   deleteByIdWithStore / deleteByGroupWithStore)
 * - 行对象转换(TEXT ↔ 枚举、NULL ↔ undefined、INTEGER ↔ number、JSON ↔ string[])
 *
 * 不负责:
 * - 跨表业务验证(见 GroupCharacterMemoryService)
 * - 记忆 ID 生成(由 Service 调用 generateUuid 后传入)
 * - AI 总结 / Prompt 选择 / 相似度 / 记忆自动合并
 * - 交互记忆自动生成 / 自动失效(留给 G-MEMORY-1B / G-MEMORY-1C)
 *
 * 排序规则:
 * - listByCharacter:status ASC, importance DESC, updatedAt DESC, id ASC
 *   (Active 排前,Archived 排后,Invalidated 排最后)
 * - listActiveByCharacter / listArchivedByCharacter:importance DESC, updatedAt DESC, id ASC
 * - listByGroup:updatedAt DESC, id ASC
 * - listBySourceMessage / listBySourceRound:updatedAt DESC, id ASC
 *
 * 日志安全:
 * - 不记录完整记忆正文、完整 ID、SQL 参数
 * - 仅在抛错时附带截断后 cause message
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  GroupCharacterMemory,
  GroupCharacterMemoryOrigin,
  GroupCharacterMemoryStatus,
  isGroupCharacterMemoryOrigin,
  isGroupCharacterMemoryStatus,
  isGroupCharacterMemoryImportance,
  normalizeKeywords
} from '../../models/groupchat/GroupCharacterMemory';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_GROUP_CHARACTER_MEMORIES,
  COLUMN_ID,
  COLUMN_GROUP_CONVERSATION_ID,
  COLUMN_CHARACTER_ID,
  COLUMN_ORIGIN_TYPE,
  COLUMN_STATUS,
  COLUMN_MEMORY_TITLE_GCM,
  COLUMN_CONTENT,
  COLUMN_IMPORTANCE_GCM,
  COLUMN_MEMORY_KEYWORDS_JSON,
  COLUMN_SOURCE_MESSAGE_ID,
  COLUMN_SOURCE_ROUND_ID,
  COLUMN_SOURCE_SENDER_CHARACTER_ID,
  COLUMN_SOURCE_TYPE,
  COLUMN_MEMORY_SOURCE_HASH,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

const STATUS_ACTIVE: string = GroupCharacterMemoryStatus.Active;
const STATUS_ARCHIVED: string = GroupCharacterMemoryStatus.Archived;

export class GroupCharacterMemoryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<GroupCharacterMemory | null> {
    if (id === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<GroupCharacterMemory | null> {
    if (id === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_MEMORIES);
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
   * 列出指定角色在某群聊的全部记忆。
   * 排序:status ASC, importance DESC, updatedAt DESC, id ASC
   * (Active 排前,Archived 排后,Invalidated 排最后)
   */
  async listByCharacter(
    groupConversationId: string,
    characterId: string
  ): Promise<GroupCharacterMemory[]> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.listByCharacter: groupConversationId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.listByCharacter: characterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.queryListByCharacter(store, groupConversationId, characterId, undefined);
  }

  /**
   * 列出指定角色在某群聊的 Active 记忆。
   * 排序:importance DESC, updatedAt DESC, id ASC
   */
  async listActiveByCharacter(
    groupConversationId: string,
    characterId: string
  ): Promise<GroupCharacterMemory[]> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.listActiveByCharacter: groupConversationId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.listActiveByCharacter: characterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.queryListByCharacter(store, groupConversationId, characterId, STATUS_ACTIVE);
  }

  /**
   * 列出指定角色在某群聊的 Archived 记忆。
   * 排序:importance DESC, updatedAt DESC, id ASC
   */
  async listArchivedByCharacter(
    groupConversationId: string,
    characterId: string
  ): Promise<GroupCharacterMemory[]> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.listArchivedByCharacter: groupConversationId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.listArchivedByCharacter: characterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.queryListByCharacter(store, groupConversationId, characterId, STATUS_ARCHIVED);
  }

  /**
   * 列出指定群聊的全部记忆(所有角色)。
   * 排序:updatedAt DESC, id ASC
   * 用于群聊删除级联清理前的诊断(本阶段主要用 deleteByGroupWithStore)。
   */
  async listByGroup(groupConversationId: string): Promise<GroupCharacterMemory[]> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.listByGroup: groupConversationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    return await this.collectList(store, predicates);
  }

  async countByCharacter(
    groupConversationId: string,
    characterId: string
  ): Promise<number> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.countByCharacter: groupConversationId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.countByCharacter: characterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.countByCharacterWithStore(store, groupConversationId, characterId);
  }

  async countByCharacterWithStore(
    store: relationalStore.RdbStore,
    groupConversationId: string,
    characterId: string
  ): Promise<number> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.countByCharacterWithStore: groupConversationId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.countByCharacterWithStore: characterId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    predicates.equalTo(COLUMN_CHARACTER_ID, characterId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.rowCount;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 SourceMessage 的全部记忆(交互记忆预留,本阶段不写入)。
   * 排序:updatedAt DESC, id ASC
   */
  async listBySourceMessage(sourceMessageId: string): Promise<GroupCharacterMemory[]> {
    if (sourceMessageId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.listBySourceMessage: sourceMessageId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_SOURCE_MESSAGE_ID, sourceMessageId);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    return await this.collectList(store, predicates);
  }

  /**
   * 列出指定 SourceRound 的全部记忆(交互记忆预留,本阶段不写入)。
   * 排序:updatedAt DESC, id ASC
   */
  async listBySourceRound(sourceRoundId: string): Promise<GroupCharacterMemory[]> {
    if (sourceRoundId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.listBySourceRound: sourceRoundId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_SOURCE_ROUND_ID, sourceRoundId);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    return await this.collectList(store, predicates);
  }

  async insert(memory: GroupCharacterMemory): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.insertWithStore(store, memory);
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    memory: GroupCharacterMemory
  ): Promise<void> {
    this.validateMemory(memory);
    try {
      await store.insert(TABLE_GROUP_CHARACTER_MEMORIES, memoryToBucket(memory));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('GroupCharacterMemory.insertWithStore');
      }
      throw DatabaseError.queryFailed(`GroupCharacterMemory.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(memory: GroupCharacterMemory): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.updateWithStore(store, memory);
  }

  async updateWithStore(
    store: relationalStore.RdbStore,
    memory: GroupCharacterMemory
  ): Promise<void> {
    this.validateMemory(memory);
    const bucket: relationalStore.ValuesBucket = memoryToBucket(memory);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_ID, memory.id);
    try {
      const affected: number = await store.update(bucket, predicates);
      if (affected === 0) {
        throw DatabaseError.notFound('GroupCharacterMemory.updateWithStore');
      }
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.queryFailed(`GroupCharacterMemory.updateWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.deleteByIdWithStore(store, id);
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`GroupCharacterMemory.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除指定群聊的全部记忆(所有角色)。
   * 幂等:不存在返回 0,不抛错。
   * 用于 ChatPersistenceOperations.removeChatWithMessages 同事务级联清理。
   */
  async deleteByGroupWithStore(
    store: relationalStore.RdbStore,
    groupConversationId: string
  ): Promise<void> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.deleteByGroupWithStore: groupConversationId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `GroupCharacterMemory.deleteByGroupWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  // ===== 内部辅助 =====

  private async queryListByCharacter(
    store: relationalStore.RdbStore,
    groupConversationId: string,
    characterId: string,
    statusFilter: string | undefined
  ): Promise<GroupCharacterMemory[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_MEMORIES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    predicates.equalTo(COLUMN_CHARACTER_ID, characterId);
    if (statusFilter !== undefined) {
      predicates.equalTo(COLUMN_STATUS, statusFilter);
    } else {
      // 全部列表:Active 排前,Archived 排后,Invalidated 排最后
      // 'active' < 'archived' < 'invalidated' 字典序恰好匹配
      predicates.orderByAsc(COLUMN_STATUS);
    }
    predicates.orderByDesc(COLUMN_IMPORTANCE_GCM);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    return await this.collectList(store, predicates);
  }

  private async collectList(
    store: relationalStore.RdbStore,
    predicates: relationalStore.RdbPredicates
  ): Promise<GroupCharacterMemory[]> {
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: GroupCharacterMemory[] = [];
      while (rs.goToNextRow()) {
        list.push(memoryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  private validateMemory(memory: GroupCharacterMemory): void {
    if (memory.id === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.id empty');
    }
    if (memory.groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.groupConversationId empty');
    }
    if (memory.characterId === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.characterId empty');
    }
    if (!isGroupCharacterMemoryOrigin(memory.origin)) {
      throw DatabaseError.invalidData(`GroupCharacterMemory.origin invalid: ${memory.origin}`);
    }
    if (!isGroupCharacterMemoryStatus(memory.status)) {
      throw DatabaseError.invalidData(`GroupCharacterMemory.status invalid: ${memory.status}`);
    }
    if (memory.title === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.title empty');
    }
    if (memory.content === '') {
      throw DatabaseError.invalidData('GroupCharacterMemory.content empty');
    }
    if (!isGroupCharacterMemoryImportance(memory.importance)) {
      throw DatabaseError.invalidData(`GroupCharacterMemory.importance invalid: ${memory.importance}`);
    }
    if (!isValidTimestamp(memory.createdAt)) {
      throw DatabaseError.invalidData('GroupCharacterMemory.createdAt invalid');
    }
    if (!isValidTimestamp(memory.updatedAt)) {
      throw DatabaseError.invalidData('GroupCharacterMemory.updatedAt invalid');
    }
  }
}

function memoryToBucket(memory: GroupCharacterMemory): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = memory.id;
  bucket[COLUMN_GROUP_CONVERSATION_ID] = memory.groupConversationId;
  bucket[COLUMN_CHARACTER_ID] = memory.characterId;
  bucket[COLUMN_ORIGIN_TYPE] = memory.origin;
  bucket[COLUMN_STATUS] = memory.status;
  bucket[COLUMN_MEMORY_TITLE_GCM] = memory.title;
  bucket[COLUMN_CONTENT] = memory.content;
  bucket[COLUMN_IMPORTANCE_GCM] = memory.importance;
  bucket[COLUMN_MEMORY_KEYWORDS_JSON] = JSON.stringify(memory.keywords);
  bucket[COLUMN_SOURCE_MESSAGE_ID] = memory.sourceMessageId !== undefined ? memory.sourceMessageId : null;
  bucket[COLUMN_SOURCE_ROUND_ID] = memory.sourceRoundId !== undefined ? memory.sourceRoundId : null;
  bucket[COLUMN_SOURCE_SENDER_CHARACTER_ID] =
    memory.sourceSenderCharacterId !== undefined ? memory.sourceSenderCharacterId : null;
  bucket[COLUMN_SOURCE_TYPE] = memory.sourceType !== undefined ? memory.sourceType : null;
  bucket[COLUMN_MEMORY_SOURCE_HASH] = memory.sourceHash !== undefined ? memory.sourceHash : null;
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

function parseKeywordsJson(raw: string): string[] {
  if (raw === undefined || raw === '' || raw === '[]') {
    return [];
  }
  try {
    const parsed: Object = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }
    const items: string[] = [];
    for (let i = 0; i < parsed.length; i++) {
      const item: Object | undefined = parsed[i];
      if (item !== null && item !== undefined) {
        items.push(String(item));
      }
    }
    return normalizeKeywords(items);
  } catch (e) {
    return [];
  }
}

function memoryFromRow(rs: relationalStore.ResultSet): GroupCharacterMemory {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('GroupCharacterMemory.id empty in row');
  }
  const groupConversationId: string = rs.getString(rs.getColumnIndex(COLUMN_GROUP_CONVERSATION_ID));
  if (groupConversationId === '') {
    throw DatabaseError.invalidData('GroupCharacterMemory.groupConversationId empty in row');
  }
  const characterId: string = rs.getString(rs.getColumnIndex(COLUMN_CHARACTER_ID));
  if (characterId === '') {
    throw DatabaseError.invalidData('GroupCharacterMemory.characterId empty in row');
  }
  const originRaw: string = rs.getString(rs.getColumnIndex(COLUMN_ORIGIN_TYPE));
  if (!isGroupCharacterMemoryOrigin(originRaw)) {
    throw DatabaseError.invalidData(`GroupCharacterMemory.origin invalid in row: ${originRaw}`);
  }
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  if (!isGroupCharacterMemoryStatus(statusRaw)) {
    throw DatabaseError.invalidData(`GroupCharacterMemory.status invalid in row: ${statusRaw}`);
  }
  const title: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_TITLE_GCM));
  const content: string = rs.getString(rs.getColumnIndex(COLUMN_CONTENT));
  const importance: number = rs.getLong(rs.getColumnIndex(COLUMN_IMPORTANCE_GCM));
  if (!isGroupCharacterMemoryImportance(importance)) {
    throw DatabaseError.invalidData(`GroupCharacterMemory.importance invalid in row: ${importance}`);
  }
  const keywordsRaw: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_KEYWORDS_JSON));
  const keywords: string[] = parseKeywordsJson(keywordsRaw);
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('GroupCharacterMemory.createdAt invalid in row');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('GroupCharacterMemory.updatedAt invalid in row');
  }
  return {
    id: id,
    groupConversationId: groupConversationId,
    characterId: characterId,
    origin: originRaw as GroupCharacterMemoryOrigin,
    status: statusRaw as GroupCharacterMemoryStatus,
    title: title,
    content: content,
    importance: importance,
    keywords: keywords,
    sourceMessageId: readOptionalString(rs, COLUMN_SOURCE_MESSAGE_ID),
    sourceRoundId: readOptionalString(rs, COLUMN_SOURCE_ROUND_ID),
    sourceSenderCharacterId: readOptionalString(rs, COLUMN_SOURCE_SENDER_CHARACTER_ID),
    sourceType: readOptionalString(rs, COLUMN_SOURCE_TYPE),
    sourceHash: readOptionalString(rs, COLUMN_MEMORY_SOURCE_HASH),
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
