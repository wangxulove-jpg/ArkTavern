/**
 * ChatMemory Repository(分支感知长期记忆)
 *
 * 职责:
 * - chat_memories 表的 CRUD
 * - 按 chatId / branchId 查询
 * - 事务内清理(供 ChatPersistenceOperations 调用)
 *
 * 约定:
 * - 公开方法自行 getStore,委托 WithStore
 * - WithStore 方法不调用 getStore / runInTransaction
 * - ResultSet 所有路径 finally close
 * - 不暴露通用 SQL 执行方法
 * - 不记录正文
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { Logger } from '../utils/Logger';
import { ChatMemory, createChatMemory } from '../models/ChatMemory';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import { generateUuid } from '../utils/Uuid';
import {
  TABLE_CHAT_MEMORIES,
  COLUMN_MEMORY_ID,
  COLUMN_MEMORY_CHAT_ID,
  COLUMN_MEMORY_BRANCH_ID,
  COLUMN_MEMORY_END_POSITION,
  COLUMN_MEMORY_SUMMARY,
  COLUMN_MEMORY_ENABLED,
  COLUMN_MEMORY_SUMMARY_VERSION,
  COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID,
  COLUMN_UPDATED_AT,
  COLUMN_CREATED_AT
} from '../database/DatabaseConstants';
import { memoryFromRow, memoryToBucket } from './ChatMemoryRepositoryMapper';

const LOG_TAG: string = 'MemoryRepo';

export class ChatMemoryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  // ===== 查询 =====

  /**
   * 获取指定 Branch 的最新一条 Memory(endPosition 最大)。
   * 无 Memory 返回 null。
   */
  async getLatestByBranch(branchId: string): Promise<ChatMemory | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getLatestByBranchWithStore(store, branchId);
  }

  async getLatestByBranchWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<ChatMemory | null> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('getLatestByBranch: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.orderByDesc(COLUMN_MEMORY_END_POSITION);
    predicates.limitAs(1);
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
   * 获取指定 Branch 的全部 Memory(按 endPosition ASC)。
   */
  async listByBranch(branchId: string): Promise<ChatMemory[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listByBranchWithStore(store, branchId);
  }

  async listByBranchWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<ChatMemory[]> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('listByBranch: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.orderByAsc(COLUMN_MEMORY_END_POSITION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const result: ChatMemory[] = [];
    try {
      while (rs.goToNextRow()) {
        result.push(memoryFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return result;
  }

  /**
   * 按 chatId 列出所有 Memory(用于级联清理时统计)。
   */
  async listByChat(chatId: string): Promise<ChatMemory[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listByChatWithStore(store, chatId);
  }

  async listByChatWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ChatMemory[]> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('listByChat: chatId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_CHAT_ID, chatId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const result: ChatMemory[] = [];
    try {
      while (rs.goToNextRow()) {
        result.push(memoryFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return result;
  }

  /**
   * 按 ID 查询 Memory。
   */
  async getById(memoryId: string): Promise<ChatMemory | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, memoryId);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    memoryId: string
  ): Promise<ChatMemory | null> {
    if (memoryId.length === 0) {
      throw DatabaseError.invalidData('getById: memoryId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memoryId);
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

  // ===== 插入 / 更新 =====

  /**
   * 插入新的 Memory 记录。
   */
  async insert(memory: ChatMemory): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.insertWithStore(store, memory);
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    memory: ChatMemory
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket = memoryToBucket(memory);
    await store.insert(TABLE_CHAT_MEMORIES, bucket);
  }

  /**
   * 更新 Memory(summary / endPosition / enabled / summaryVersion / updatedAt)。
   * 不可变字段(id/chatId/branchId/startMessageId/startPosition/createdAt/inheritedFromMemoryId)保持不变。
   */
  async update(memory: ChatMemory): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.updateWithStore(store, memory);
  }

  async updateWithStore(
    store: relationalStore.RdbStore,
    memory: ChatMemory
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memory.id);
    const bucket: relationalStore.ValuesBucket = memoryToBucket(memory);
    await store.update(bucket, predicates);
  }

  /**
   * 仅更新 summary 字段(用于手动编辑摘要)。
   */
  async updateSummary(memoryId: string, newSummary: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.updateSummaryWithStore(store, memoryId, newSummary);
  }

  async updateSummaryWithStore(
    store: relationalStore.RdbStore,
    memoryId: string,
    newSummary: string
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memoryId);
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_MEMORY_SUMMARY] = newSummary;
    bucket[COLUMN_MEMORY_SUMMARY_VERSION] = Date.now(); // 简化:用时间戳保证递增
    bucket[COLUMN_UPDATED_AT] = Date.now();
    await store.update(bucket, predicates);
  }

  /**
   * 仅更新 enabled 字段。
   */
  async setEnabled(memoryId: string, enabled: boolean): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.setEnabledWithStore(store, memoryId, enabled);
  }

  async setEnabledWithStore(
    store: relationalStore.RdbStore,
    memoryId: string,
    enabled: boolean
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memoryId);
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_MEMORY_ENABLED] = enabled ? 1 : 0;
    bucket[COLUMN_UPDATED_AT] = Date.now();
    await store.update(bucket, predicates);
  }

  // ===== 删除 =====

  /**
   * 删除单条 Memory(按 ID)。
   */
  async removeById(memoryId: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.removeByIdWithStore(store, memoryId);
  }

  async removeByIdWithStore(
    store: relationalStore.RdbStore,
    memoryId: string
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memoryId);
    await store.delete(predicates);
  }

  /**
   * 按 chatId 删除所有 Memory(级联清理用)。
   * 同时清理继承关系(inheritedFromMemoryId 指向被删 Memory 的记录也会被清理,
   * 但通常继承方位于不同 Chat,不应在此调用)。
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('removeByChatId: chatId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_CHAT_ID, chatId);
    await store.delete(predicates);
  }

  /**
   * 按 branchId 删除该 Branch 自产的记忆(inheritedFromMemoryId 为 null)。
   * 继承来的记忆不删除(由原 Branch 持有)。
   * 用于单独清除某 Branch 的记忆时。
   */
  async removeOwnedByBranchWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<void> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('removeOwnedByBranch: branchId empty');
    }
    // RdbPredicates 不支持 IS NULL,需要用谓词isNull
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.and();
    predicates.isNull(COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID);
    await store.delete(predicates);
  }

  /**
   * 删除 Branch 中 endPosition >= threshold 的所有 Memory(用于编辑/切换 Swipe 后使摘要失效)。
   * 不区分继承/自产,因为失效后需要重新总结。
   */
  async invalidateFromPositionWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    thresholdPosition: number
  ): Promise<void> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('invalidateFromPosition: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.and();
    predicates.greaterThanOrEqualTo(COLUMN_MEMORY_END_POSITION, thresholdPosition);
    await store.delete(predicates);
  }

  // ===== Fork 支持 =====

  /**
   * 为 fork 复制祖先 Memory 到子 Branch(标记 inheritedFromMemoryId)。
   * 只复制 endPosition <= forkPosition 的祖先 Memory(分叉点之前可用的)。
   *
   * 复制策略:
   * - 创建新的 Memory 记录(新 ID),branchId = childBranchId
   * - inheritedFromMemoryId = 原 Memory ID(标记继承)
   * - 其余字段保持不变(summary / startMessageId / endMessageId / positions / createdAt)
   * - updatedAt 设为当前时间(标记继承时间)
   *
   * 原 Memory 不删除,继续归祖先 Branch 所有。
   */
  async copyAncestorMemoriesThroughPositionWithStore(
    store: relationalStore.RdbStore,
    sourceBranchId: string,
    childBranchId: string,
    forkPosition: number
  ): Promise<void> {
    if (sourceBranchId.length === 0) {
      throw DatabaseError.invalidData('copyAncestorMemories: sourceBranchId empty');
    }
    if (childBranchId.length === 0) {
      throw DatabaseError.invalidData('copyAncestorMemories: childBranchId empty');
    }
    // 读取源 Branch 中 endPosition <= forkPosition 的所有 Memory
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, sourceBranchId);
    predicates.and();
    predicates.lessThanOrEqualTo(COLUMN_MEMORY_END_POSITION, forkPosition);
    predicates.orderByAsc(COLUMN_MEMORY_END_POSITION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const ancestors: ChatMemory[] = [];
    try {
      while (rs.goToNextRow()) {
        ancestors.push(memoryFromRow(rs));
      }
    } finally {
      rs.close();
    }

    if (ancestors.length === 0) {
      return;
    }

    const now: number = nowMillis();
    for (let i = 0; i < ancestors.length; i++) {
      const ancestor: ChatMemory = ancestors[i];
      // 创建继承副本(新 ID)
      const inherited: ChatMemory = createChatMemory(
        generateUuid(),
        ancestor.chatId,
        childBranchId,
        ancestor.startMessageId,
        ancestor.endMessageId,
        ancestor.startPosition,
        ancestor.endPosition,
        ancestor.summary,
        ancestor.createdAt, // 保留原创建时间
        ancestor.id // 标记继承来源
      );
      // 更新 updatedAt 为当前时间
      const updated: ChatMemory = {
        id: inherited.id,
        chatId: inherited.chatId,
        branchId: inherited.branchId,
        startMessageId: inherited.startMessageId,
        endMessageId: inherited.endMessageId,
        startPosition: inherited.startPosition,
        endPosition: inherited.endPosition,
        summary: inherited.summary,
        createdAt: inherited.createdAt,
        updatedAt: now,
        enabled: ancestor.enabled,
        summaryVersion: ancestor.summaryVersion,
        inheritedFromMemoryId: inherited.inheritedFromMemoryId
      };
      await this.insertWithStore(store, updated);
    }
    Logger.info(LOG_TAG, 'copied memories | count=' + ancestors.length.toString());
  }
}
