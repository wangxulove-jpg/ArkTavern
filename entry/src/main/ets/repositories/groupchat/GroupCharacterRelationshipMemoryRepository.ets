/**
 * GroupCharacterRelationshipMemoryRepository
 *
 * 职责(G-MEMORY-AUTO-1B):
 * - group_character_relationship_memories 表的 CRUD 操作
 * - 提供事务内写入方法(upsertWithStore / updateEditableFieldsWithStore /
 *   setArchivedWithStore / deleteByGroupWithStore)
 * - 行对象转换(TEXT ↔ 枚举、JSON ↔ string[])
 *
 * 不负责:
 * - 跨表业务验证(见 GroupCharacterRelationshipMemoryService)
 * - 关系记忆 ID 生成(由 Service 调用 generateUuid 后传入)
 * - Prompt 注入 / 自动总结 / 自动失效
 *
 * 唯一性:
 * - UNIQUE(group_conversation_id, owner_character_id, target_type, target_id)
 * - upsertWithStore 按该唯一键 INSERT or UPDATE,不会产生重复记录
 * - 更新 A→B 不会影响 B→A(因为 B→A 的唯一键不同)
 *
 * 排序规则:
 * - listByOwner / listActiveByOwner:status ASC, importance DESC, updatedAt DESC, id ASC
 *   (Active 排前,Archived 排后,Invalidated 排最后)
 *
 * 日志安全:
 * - 不记录完整摘要正文、完整 ID、SQL 参数
 * - 仅在抛错时附带截断后 cause message
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  GroupCharacterRelationshipMemory,
  GroupRelationshipTargetType,
  GroupRelationshipMemoryStatus,
  isGroupRelationshipTargetType,
  isGroupRelationshipMemoryStatus,
  isRelationshipImportance,
  normalizeMessageIds,
  parseSourceMessageIdsJson,
  sourceMessageIdsToJson,
  normalizeKeywords
} from '../../models/groupchat/GroupCharacterRelationshipMemory';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES,
  COLUMN_ID,
  COLUMN_GROUP_CONVERSATION_ID,
  COLUMN_OWNER_CHARACTER_ID,
  COLUMN_TARGET_TYPE,
  COLUMN_TARGET_ID,
  COLUMN_EXPERIENCE_SUMMARY,
  COLUMN_ATTITUDE_SUMMARY,
  COLUMN_RELATIONSHIP_SUMMARY,
  COLUMN_IMPORTANCE_GCRM,
  COLUMN_KEYWORDS_JSON,
  COLUMN_SOURCE_MESSAGE_IDS_JSON,
  COLUMN_SOURCE_HASH_GCRM,
  COLUMN_SOURCE_TYPE_GCRM,
  COLUMN_STATUS,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

const STATUS_ACTIVE: string = GroupRelationshipMemoryStatus.Active;
const STATUS_ARCHIVED: string = GroupRelationshipMemoryStatus.Archived;

export class GroupCharacterRelationshipMemoryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<GroupCharacterRelationshipMemory | null> {
    if (id === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<GroupCharacterRelationshipMemory | null> {
    if (id === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES);
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
   * 按唯一键 (groupConversationId, ownerCharacterId, targetType, targetId) 查询。
   * 返回 null 表示不存在。
   */
  async getByOwnerAndTarget(
    groupConversationId: string,
    ownerCharacterId: string,
    targetType: GroupRelationshipTargetType,
    targetId: string
  ): Promise<GroupCharacterRelationshipMemory | null> {
    if (groupConversationId === '' || ownerCharacterId === '' || targetId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.getByOwnerAndTarget: empty key');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_ID, ownerCharacterId);
    predicates.equalTo(COLUMN_TARGET_TYPE, targetType);
    predicates.equalTo(COLUMN_TARGET_ID, targetId);
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
   * 列出指定 owner 在某群聊的全部关系记忆。
   * 排序:status ASC, importance DESC, updatedAt DESC, id ASC
   */
  async listByOwner(
    groupConversationId: string,
    ownerCharacterId: string
  ): Promise<GroupCharacterRelationshipMemory[]> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.listByOwner: groupConversationId empty');
    }
    if (ownerCharacterId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.listByOwner: ownerCharacterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.queryListByOwner(store, groupConversationId, ownerCharacterId, undefined);
  }

  /**
   * 列出指定群聊中所有"指向目标角色 A"的关系记录(其他 owner → A)。
   *
   * G-CONTEXT-MEMORY-SELECTION-1 反向关系诊断专用窄查询:
   * - 仅按 target_id + target_type='character' 过滤,不按 owner 过滤
   * - 用于在检查器显示 B→A、C→A,不进入 A 的 selectedRelationships
   * - 不修改 Schema / DATABASE_VERSION / 现有方法语义
   *
   * 排序:status ASC, importance DESC, updatedAt DESC, id ASC
   */
  async listByTarget(
    groupConversationId: string,
    targetCharacterId: string
  ): Promise<GroupCharacterRelationshipMemory[]> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.listByTarget: groupConversationId empty');
    }
    if (targetCharacterId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.listByTarget: targetCharacterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    predicates.equalTo(COLUMN_TARGET_ID, targetCharacterId);
    predicates.equalTo(COLUMN_TARGET_TYPE, GroupRelationshipTargetType.Character);
    // 'active' < 'archived' < 'invalidated' 字典序恰好匹配
    predicates.orderByAsc(COLUMN_STATUS);
    predicates.orderByDesc(COLUMN_IMPORTANCE_GCRM);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: GroupCharacterRelationshipMemory[] = [];
      while (rs.goToNextRow()) {
        list.push(memoryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 owner 在某群聊的 Active 关系记忆。
   * 排序:importance DESC, updatedAt DESC, id ASC
   */
  async listActiveByOwner(
    groupConversationId: string,
    ownerCharacterId: string
  ): Promise<GroupCharacterRelationshipMemory[]> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.listActiveByOwner: groupConversationId empty');
    }
    if (ownerCharacterId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.listActiveByOwner: ownerCharacterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.queryListByOwner(store, groupConversationId, ownerCharacterId, STATUS_ACTIVE);
  }

  /**
   * 在事务内按唯一键 UPSERT 关系记忆。
   * - 不存在时 INSERT(此时 createdAt 由 memory 决定)
   * - 已存在时 UPDATE(保留原 createdAt,更新其他字段)
   * - 失败时抛 DatabaseError
   *
   * 注意:此方法只更新"完整对象",不区分可编辑字段。Service 在调用前应构建好完整对象。
   */
  async upsertWithStore(
    store: relationalStore.RdbStore,
    memory: GroupCharacterRelationshipMemory
  ): Promise<void> {
    this.validateMemory(memory);
    const existing: GroupCharacterRelationshipMemory | null =
      await this.getByOwnerAndTargetWithStore(
        store,
        memory.groupConversationId,
        memory.ownerCharacterId,
        memory.targetType,
        memory.targetId
      );
    try {
      if (existing === null) {
        await store.insert(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES, memoryToBucket(memory));
      } else {
        // 保留原 createdAt,使用现有 id 更新
        const updated: GroupCharacterRelationshipMemory = {
          id: existing.id,
          groupConversationId: memory.groupConversationId,
          ownerCharacterId: memory.ownerCharacterId,
          targetType: memory.targetType,
          targetId: memory.targetId,
          experienceSummary: memory.experienceSummary,
          attitudeSummary: memory.attitudeSummary,
          relationshipSummary: memory.relationshipSummary,
          importance: memory.importance,
          keywords: memory.keywords,
          sourceMessageIds: memory.sourceMessageIds,
          sourceHash: memory.sourceHash,
          sourceType: memory.sourceType,
          status: memory.status,
          createdAt: existing.createdAt,
          updatedAt: memory.updatedAt
        };
        const bucket: relationalStore.ValuesBucket = memoryToBucket(updated);
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES);
        predicates.equalTo(COLUMN_ID, existing.id);
        await store.update(bucket, predicates);
      }
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('GroupCharacterRelationshipMemory.upsertWithStore');
      }
      throw DatabaseError.queryFailed(
        `GroupCharacterRelationshipMemory.upsertWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 在事务内更新可编辑字段(experience/attitude/relationship/importance/keywords)。
   * - 不修改 groupConversationId/ownerCharacterId/targetType/targetId
   * - 不修改 sourceMessageIds/sourceHash/sourceType
   * - 不修改 createdAt
   * - updatedAt 更新为传入值
   * - 返回更新后的对象(失败抛 DatabaseError)
   */
  async updateEditableFieldsWithStore(
    store: relationalStore.RdbStore,
    id: string,
    experienceSummary: string,
    attitudeSummary: string,
    relationshipSummary: string,
    importance: number,
    keywords: string[],
    updatedAt: number
  ): Promise<GroupCharacterRelationshipMemory> {
    if (id === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.updateEditableFieldsWithStore: id empty');
    }
    if (!isRelationshipImportance(importance)) {
      throw DatabaseError.invalidData(
        `GroupCharacterRelationshipMemory.updateEditableFieldsWithStore: importance invalid: ${importance}`
      );
    }
    const existing: GroupCharacterRelationshipMemory | null =
      await this.getByIdWithStore(store, id);
    if (existing === null) {
      throw DatabaseError.notFound('GroupCharacterRelationshipMemory.updateEditableFieldsWithStore');
    }
    const updated: GroupCharacterRelationshipMemory = {
      id: existing.id,
      groupConversationId: existing.groupConversationId,
      ownerCharacterId: existing.ownerCharacterId,
      targetType: existing.targetType,
      targetId: existing.targetId,
      experienceSummary: experienceSummary,
      attitudeSummary: attitudeSummary,
      relationshipSummary: relationshipSummary,
      importance: importance,
      keywords: normalizeKeywords(keywords),
      sourceMessageIds: existing.sourceMessageIds,
      sourceHash: existing.sourceHash,
      sourceType: existing.sourceType,
      status: existing.status,
      createdAt: existing.createdAt,
      updatedAt: updatedAt
    };
    const bucket: relationalStore.ValuesBucket = memoryToBucket(updated);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      const affected: number = await store.update(bucket, predicates);
      if (affected === 0) {
        throw DatabaseError.notFound('GroupCharacterRelationshipMemory.updateEditableFieldsWithStore');
      }
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.queryFailed(
        `GroupCharacterRelationshipMemory.updateEditableFieldsWithStore: ${extractCauseMessage(err)}`
      );
    }
    return updated;
  }

  /**
   * 在事务内归档 / 恢复关系记忆(只改 status)。
   */
  async setArchivedWithStore(
    store: relationalStore.RdbStore,
    id: string,
    archived: boolean,
    updatedAt: number
  ): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.setArchivedWithStore: id empty');
    }
    const newStatus: string = archived ? STATUS_ARCHIVED : STATUS_ACTIVE;
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS] = newStatus;
    bucket[COLUMN_UPDATED_AT] = updatedAt;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      const affected: number = await store.update(bucket, predicates);
      if (affected === 0) {
        throw DatabaseError.notFound('GroupCharacterRelationshipMemory.setArchivedWithStore');
      }
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.queryFailed(
        `GroupCharacterRelationshipMemory.setArchivedWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 在事务内删除指定群聊的全部关系记忆(所有 owner / 所有方向)。
   * 幂等:不存在返回 0,不抛错。
   * 用于 ChatPersistenceOperations.removeChatWithMessages 同事务级联清理。
   */
  async deleteByGroupWithStore(
    store: relationalStore.RdbStore,
    groupConversationId: string
  ): Promise<void> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData(
        'GroupCharacterRelationshipMemory.deleteByGroupWithStore: groupConversationId empty'
      );
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `GroupCharacterRelationshipMemory.deleteByGroupWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  // ===== 内部辅助 =====

  async getByOwnerAndTargetWithStore(
    store: relationalStore.RdbStore,
    groupConversationId: string,
    ownerCharacterId: string,
    targetType: GroupRelationshipTargetType,
    targetId: string
  ): Promise<GroupCharacterRelationshipMemory | null> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_ID, ownerCharacterId);
    predicates.equalTo(COLUMN_TARGET_TYPE, targetType);
    predicates.equalTo(COLUMN_TARGET_ID, targetId);
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

  private async queryListByOwner(
    store: relationalStore.RdbStore,
    groupConversationId: string,
    ownerCharacterId: string,
    statusFilter: string | undefined
  ): Promise<GroupCharacterRelationshipMemory[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_ID, ownerCharacterId);
    if (statusFilter !== undefined) {
      predicates.equalTo(COLUMN_STATUS, statusFilter);
    } else {
      // 'active' < 'archived' < 'invalidated' 字典序恰好匹配
      predicates.orderByAsc(COLUMN_STATUS);
    }
    predicates.orderByDesc(COLUMN_IMPORTANCE_GCRM);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: GroupCharacterRelationshipMemory[] = [];
      while (rs.goToNextRow()) {
        list.push(memoryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  private validateMemory(memory: GroupCharacterRelationshipMemory): void {
    if (memory.id === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.id empty');
    }
    if (memory.groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.groupConversationId empty');
    }
    if (memory.ownerCharacterId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.ownerCharacterId empty');
    }
    if (!isGroupRelationshipTargetType(memory.targetType)) {
      throw DatabaseError.invalidData(
        `GroupCharacterRelationshipMemory.targetType invalid: ${memory.targetType}`
      );
    }
    if (memory.targetId === '') {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.targetId empty');
    }
    if (memory.targetType === GroupRelationshipTargetType.Character
      && memory.targetId === memory.ownerCharacterId) {
      throw DatabaseError.invalidData(
        'GroupCharacterRelationshipMemory.targetId cannot equal ownerCharacterId'
      );
    }
    if (!isGroupRelationshipMemoryStatus(memory.status)) {
      throw DatabaseError.invalidData(
        `GroupCharacterRelationshipMemory.status invalid: ${memory.status}`
      );
    }
    if (!isRelationshipImportance(memory.importance)) {
      throw DatabaseError.invalidData(
        `GroupCharacterRelationshipMemory.importance invalid: ${memory.importance}`
      );
    }
    if (!isValidTimestamp(memory.createdAt)) {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.createdAt invalid');
    }
    if (!isValidTimestamp(memory.updatedAt)) {
      throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.updatedAt invalid');
    }
  }
}

function memoryToBucket(memory: GroupCharacterRelationshipMemory): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = memory.id;
  bucket[COLUMN_GROUP_CONVERSATION_ID] = memory.groupConversationId;
  bucket[COLUMN_OWNER_CHARACTER_ID] = memory.ownerCharacterId;
  bucket[COLUMN_TARGET_TYPE] = memory.targetType;
  bucket[COLUMN_TARGET_ID] = memory.targetId;
  bucket[COLUMN_EXPERIENCE_SUMMARY] = memory.experienceSummary;
  bucket[COLUMN_ATTITUDE_SUMMARY] = memory.attitudeSummary;
  bucket[COLUMN_RELATIONSHIP_SUMMARY] = memory.relationshipSummary;
  bucket[COLUMN_IMPORTANCE_GCRM] = memory.importance;
  bucket[COLUMN_KEYWORDS_JSON] = JSON.stringify(memory.keywords);
  bucket[COLUMN_SOURCE_MESSAGE_IDS_JSON] = sourceMessageIdsToJson(memory.sourceMessageIds);
  bucket[COLUMN_SOURCE_HASH_GCRM] = memory.sourceHash;
  bucket[COLUMN_SOURCE_TYPE_GCRM] = memory.sourceType;
  bucket[COLUMN_STATUS] = memory.status;
  bucket[COLUMN_CREATED_AT] = memory.createdAt;
  bucket[COLUMN_UPDATED_AT] = memory.updatedAt;
  return bucket;
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

function memoryFromRow(rs: relationalStore.ResultSet): GroupCharacterRelationshipMemory {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.id empty in row');
  }
  const groupConversationId: string = rs.getString(rs.getColumnIndex(COLUMN_GROUP_CONVERSATION_ID));
  if (groupConversationId === '') {
    throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.groupConversationId empty in row');
  }
  const ownerCharacterId: string = rs.getString(rs.getColumnIndex(COLUMN_OWNER_CHARACTER_ID));
  if (ownerCharacterId === '') {
    throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.ownerCharacterId empty in row');
  }
  const targetTypeRaw: string = rs.getString(rs.getColumnIndex(COLUMN_TARGET_TYPE));
  if (!isGroupRelationshipTargetType(targetTypeRaw)) {
    throw DatabaseError.invalidData(
      `GroupCharacterRelationshipMemory.targetType invalid in row: ${targetTypeRaw}`
    );
  }
  const targetId: string = rs.getString(rs.getColumnIndex(COLUMN_TARGET_ID));
  if (targetId === '') {
    throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.targetId empty in row');
  }
  const experienceSummary: string = rs.getString(rs.getColumnIndex(COLUMN_EXPERIENCE_SUMMARY));
  const attitudeSummary: string = rs.getString(rs.getColumnIndex(COLUMN_ATTITUDE_SUMMARY));
  const relationshipSummary: string = rs.getString(rs.getColumnIndex(COLUMN_RELATIONSHIP_SUMMARY));
  const importance: number = rs.getLong(rs.getColumnIndex(COLUMN_IMPORTANCE_GCRM));
  if (!isRelationshipImportance(importance)) {
    throw DatabaseError.invalidData(
      `GroupCharacterRelationshipMemory.importance invalid in row: ${importance}`
    );
  }
  const keywordsRaw: string = rs.getString(rs.getColumnIndex(COLUMN_KEYWORDS_JSON));
  const keywords: string[] = parseKeywordsJson(keywordsRaw);
  const sourceMessageIdsRaw: string =
    rs.getString(rs.getColumnIndex(COLUMN_SOURCE_MESSAGE_IDS_JSON));
  const sourceMessageIds: string[] = parseSourceMessageIdsJson(sourceMessageIdsRaw);
  const sourceHash: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_HASH_GCRM));
  if (sourceHash === '') {
    throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.sourceHash empty in row');
  }
  const sourceType: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_TYPE_GCRM));
  if (sourceType === '') {
    throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.sourceType empty in row');
  }
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  if (!isGroupRelationshipMemoryStatus(statusRaw)) {
    throw DatabaseError.invalidData(
      `GroupCharacterRelationshipMemory.status invalid in row: ${statusRaw}`
    );
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.createdAt invalid in row');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('GroupCharacterRelationshipMemory.updatedAt invalid in row');
  }
  return {
    id: id,
    groupConversationId: groupConversationId,
    ownerCharacterId: ownerCharacterId,
    targetType: targetTypeRaw as GroupRelationshipTargetType,
    targetId: targetId,
    experienceSummary: experienceSummary,
    attitudeSummary: attitudeSummary,
    relationshipSummary: relationshipSummary,
    importance: importance,
    keywords: keywords,
    sourceMessageIds: sourceMessageIds,
    sourceHash: sourceHash,
    sourceType: sourceType,
    status: statusRaw as GroupRelationshipMemoryStatus,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
