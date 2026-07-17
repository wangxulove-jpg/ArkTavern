/**
 * MessageRepository
 *
 * 职责:
 * - Message 的 CRUD 操作
 * - 按 chatId 分页查询,按 sequence_number 稳定排序
 * - 批量插入(事务,整批回滚)
 * - source 持久化白名单校验
 * - status 与 isStreaming 一致性校验
 * - 提供 WithStore 内部方法供事务组合使用
 *
 * 不负责:
 * - Chat 操作(见 ChatRepository)
 * - 级联删除(见 ChatPersistenceOperations)
 * - 业务逻辑
 *
 * 规则:
 * - insert 前检查 Chat 是否存在,不允许孤儿消息
 * - insertMany 在事务中只检查一次 Chat 是否存在
 * - source 为 CharacterPrompt/LorebookBefore/LorebookAfter 时拒绝持久化
 * - status 与 isStreaming 矛盾时拒绝持久化
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import {
  TABLE_MESSAGES,
  TABLE_CHATS,
  COLUMN_ID,
  COLUMN_CHAT_ID,
  COLUMN_ROLE,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_ERROR_MESSAGE,
  COLUMN_IS_STREAMING,
  COLUMN_SOURCE
} from '../database/DatabaseConstants';
import {
  parseChatRole,
  chatRoleToString,
  parseChatMessageStatus,
  chatMessageStatusToString,
  parseChatMessageSource,
  chatMessageSourceToString,
  intToBoolean,
  isValidTimestamp,
  isValidSequence,
  isPersistableSource,
  resolveIsStreaming,
  extractCauseMessage,
  isConstraintViolation
} from './RepositoryMappers';

const DEFAULT_LIMIT: number = 50;
const MAX_LIMIT: number = 200;
const EMPTY_SEQUENCE: number = 0;

export interface MessageInsertRecord {
  readonly message: ChatMessage;
  readonly sequenceNumber: number;
}

export interface MessagePageOptions {
  readonly limit?: number;
  readonly offset?: number;
  readonly ascending?: boolean;
}

export interface StoredChatMessage {
  readonly chatId: string;
  readonly sequenceNumber: number;
  readonly message: ChatMessage;
}

/**
 * 校验消息并构建 ValuesBucket。
 * 不修改输入 message 对象。
 * 不包含 chat_id 和 sequence_number(由调用方附加)。
 */
function buildValidatedMessageBucket(
  message: ChatMessage,
  chatId: string,
  sequenceNumber: number
): relationalStore.ValuesBucket {
  if (message.id === '') {
    throw DatabaseError.invalidData('message.id empty');
  }
  if (chatId === '') {
    throw DatabaseError.invalidData('chatId empty');
  }
  if (message.status === undefined) {
    throw DatabaseError.invalidData('message.status undefined');
  }
  if (!isValidSequence(sequenceNumber)) {
    throw DatabaseError.invalidData('sequenceNumber invalid');
  }
  if (!isValidTimestamp(message.createdAt)) {
    throw DatabaseError.invalidData('message.createdAt invalid');
  }
  if (message.updatedAt !== undefined && !isValidTimestamp(message.updatedAt)) {
    throw DatabaseError.invalidData('message.updatedAt invalid');
  }
  parseChatRole(message.role);
  parseChatMessageStatus(message.status);
  if (!isPersistableSource(message.source)) {
    throw DatabaseError.invalidData('source not persistable');
  }

  const status: ChatMessageStatus = message.status;
  const isStreamingInt: number = resolveIsStreaming(status, message.isStreaming);

  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = message.id;
  bucket[COLUMN_CHAT_ID] = chatId;
  bucket[COLUMN_ROLE] = chatRoleToString(message.role);
  bucket[COLUMN_CONTENT] = message.content;
  bucket[COLUMN_STATUS] = chatMessageStatusToString(status);
  bucket[COLUMN_CREATED_AT] = message.createdAt;
  bucket[COLUMN_UPDATED_AT] = message.updatedAt !== undefined ? message.updatedAt : null;
  bucket[COLUMN_SEQUENCE_NUMBER] = sequenceNumber;
  bucket[COLUMN_ERROR_MESSAGE] = message.errorMessage !== undefined ? message.errorMessage : null;
  bucket[COLUMN_IS_STREAMING] = isStreamingInt;
  bucket[COLUMN_SOURCE] = chatMessageSourceToString(message.source);
  return bucket;
}

/**
 * 从 ResultSet 当前行读取 ChatMessage。
 * 不读取 chat_id 和 sequence_number(持久化关系字段)。
 * 枚举字符串经显式校验,非法值抛 InvalidData。
 */
function messageFromRow(rs: relationalStore.ResultSet): ChatMessage {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const role: ChatRole = parseChatRole(rs.getString(rs.getColumnIndex(COLUMN_ROLE)));
  const content: string = rs.getString(rs.getColumnIndex(COLUMN_CONTENT));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));

  const updatedAtCol: number = rs.getColumnIndex(COLUMN_UPDATED_AT);
  const updatedAt: number | undefined =
    (updatedAtCol >= 0 && !rs.isColumnNull(updatedAtCol))
      ? rs.getLong(updatedAtCol)
      : undefined;

  const statusStr: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  const status: ChatMessageStatus = parseChatMessageStatus(statusStr);

  const isStreamingCol: number = rs.getColumnIndex(COLUMN_IS_STREAMING);
  const isStreaming: boolean = intToBoolean(rs.getLong(isStreamingCol));

  const errorMessageCol: number = rs.getColumnIndex(COLUMN_ERROR_MESSAGE);
  const errorMessage: string | undefined =
    (errorMessageCol >= 0 && !rs.isColumnNull(errorMessageCol))
      ? rs.getString(errorMessageCol)
      : undefined;

  const sourceCol: number = rs.getColumnIndex(COLUMN_SOURCE);
  const sourceStr: string | null =
    (sourceCol >= 0 && !rs.isColumnNull(sourceCol))
      ? rs.getString(sourceCol)
      : null;
  const source: ChatMessageSource | undefined = parseChatMessageSource(sourceStr);

  return {
    id: id,
    role: role,
    content: content,
    createdAt: createdAt,
    updatedAt: updatedAt,
    isStreaming: isStreaming,
    errorMessage: errorMessage,
    status: status,
    source: source
  };
}

function readSequenceNumber(rs: relationalStore.ResultSet): number {
  const ci: number = rs.getColumnIndex(COLUMN_SEQUENCE_NUMBER);
  if (ci < 0) {
    throw DatabaseError.invalidData('sequence_number column missing');
  }
  const val: number = rs.getLong(ci);
  if (!isValidSequence(val)) {
    throw DatabaseError.invalidData('sequence_number invalid in DB');
  }
  return val;
}

export class MessageRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async insert(
    message: ChatMessage,
    chatId: string,
    sequenceNumber: number
  ): Promise<void> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const exists: boolean = await this.chatExistsWithStore(store, chatId);
    if (!exists) {
      throw DatabaseError.notFound('message.insert: chat not found');
    }
    await this.insertWithStore(store, message, chatId, sequenceNumber);
  }

  /**
   * 在给定 store 上直接插入消息,不检查 Chat 是否存在。
   * 调用方(insert / insertMany)负责检查 Chat 存在性。
   * 用于事务组合,避免嵌套检查。
   */
  async insertWithStore(
    store: relationalStore.RdbStore,
    message: ChatMessage,
    chatId: string,
    sequenceNumber: number
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket =
      buildValidatedMessageBucket(message, chatId, sequenceNumber);
    try {
      await store.insert(TABLE_MESSAGES, bucket);
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('message.insert');
      }
      throw DatabaseError.queryFailed(`message.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertMany(
    chatId: string,
    records: MessageInsertRecord[]
  ): Promise<void> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    if (records.length === 0) {
      return;
    }

    // 预校验所有记录(在事务开启前)
    for (let i = 0; i < records.length; i++) {
      const rec: MessageInsertRecord = records[i];
      buildValidatedMessageBucket(rec.message, chatId, rec.sequenceNumber);
    }

    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        // 事务中只检查一次 Chat 是否存在
        const exists: boolean = await this.chatExistsWithStore(store, chatId);
        if (!exists) {
          throw DatabaseError.notFound('message.insertMany: chat not found');
        }
        for (let i = 0; i < records.length; i++) {
          const rec: MessageInsertRecord = records[i];
          const bucket: relationalStore.ValuesBucket =
            buildValidatedMessageBucket(rec.message, chatId, rec.sequenceNumber);
          try {
            await store.insert(TABLE_MESSAGES, bucket);
          } catch (err) {
            if (isConstraintViolation(err)) {
              throw DatabaseError.constraintFailed(`message.insertMany[${i}]`);
            }
            throw DatabaseError.queryFailed(
              `message.insertMany[${i}]: ${extractCauseMessage(err)}`
            );
          }
        }
      }
    );
  }

  async getById(id: string): Promise<ChatMessage | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return messageFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listByChat(
    chatId: string,
    options?: MessagePageOptions
  ): Promise<ChatMessage[]> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const limit: number =
      options !== undefined && options.limit !== undefined
        ? options.limit
        : DEFAULT_LIMIT;
    const offset: number =
      options !== undefined && options.offset !== undefined
        ? options.offset
        : 0;
    const ascending: boolean =
      options !== undefined && options.ascending !== undefined
        ? options.ascending
        : true;

    if (limit < 1 || limit > MAX_LIMIT) {
      throw DatabaseError.invalidData('limit out of range');
    }
    if (offset < 0) {
      throw DatabaseError.invalidData('offset out of range');
    }

    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    if (ascending) {
      predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    } else {
      predicates.orderByDesc(COLUMN_SEQUENCE_NUMBER);
    }
    predicates.limitAs(limit);
    predicates.offsetAs(offset);

    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const messages: ChatMessage[] = [];
      while (rs.goToNextRow()) {
        messages.push(messageFromRow(rs));
      }
      return messages;
    } finally {
      rs.close();
    }
  }

  async listRecordsByChat(
    chatId: string,
    options?: MessagePageOptions
  ): Promise<StoredChatMessage[]> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const limit: number =
      options !== undefined && options.limit !== undefined
        ? options.limit
        : DEFAULT_LIMIT;
    const offset: number =
      options !== undefined && options.offset !== undefined
        ? options.offset
        : 0;
    const ascending: boolean =
      options !== undefined && options.ascending !== undefined
        ? options.ascending
        : true;

    if (limit < 1 || limit > MAX_LIMIT) {
      throw DatabaseError.invalidData('limit out of range');
    }
    if (offset < 0) {
      throw DatabaseError.invalidData('offset out of range');
    }

    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    if (ascending) {
      predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    } else {
      predicates.orderByDesc(COLUMN_SEQUENCE_NUMBER);
    }
    predicates.limitAs(limit);
    predicates.offsetAs(offset);

    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const records: StoredChatMessage[] = [];
      while (rs.goToNextRow()) {
        const message: ChatMessage = messageFromRow(rs);
        const seq: number = readSequenceNumber(rs);
        records.push({
          chatId: chatId,
          sequenceNumber: seq,
          message: message
        });
      }
      return records;
    } finally {
      rs.close();
    }
  }

  async getMaxSequenceNumber(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const sql: string =
      `SELECT MAX(${COLUMN_SEQUENCE_NUMBER}) AS max_seq ` +
      `FROM ${TABLE_MESSAGES} ` +
      `WHERE ${COLUMN_CHAT_ID} = ?`;
    const rs: relationalStore.ResultSet =
      await store.querySql(sql, [chatId]);
    try {
      if (rs.goToFirstRow()) {
        const ci: number = rs.getColumnIndex('max_seq');
        if (ci >= 0 && !rs.isColumnNull(ci)) {
          const val: number = rs.getLong(ci);
          if (isValidSequence(val)) {
            return val;
          }
        }
      }
      return EMPTY_SEQUENCE;
    } finally {
      rs.close();
    }
  }

  async update(message: ChatMessage): Promise<void> {
    if (message.id === '') {
      throw DatabaseError.invalidData('message.id empty');
    }
    if (message.status === undefined) {
      throw DatabaseError.invalidData('message.status undefined');
    }
    if (!isValidTimestamp(message.createdAt)) {
      throw DatabaseError.invalidData('message.createdAt invalid');
    }
    if (message.updatedAt !== undefined && !isValidTimestamp(message.updatedAt)) {
      throw DatabaseError.invalidData('message.updatedAt invalid');
    }
    parseChatRole(message.role);
    parseChatMessageStatus(message.status);
    if (!isPersistableSource(message.source)) {
      throw DatabaseError.invalidData('source not persistable');
    }

    const status: ChatMessageStatus = message.status;
    const isStreamingInt: number = resolveIsStreaming(status, message.isStreaming);

    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_ROLE] = chatRoleToString(message.role);
    bucket[COLUMN_CONTENT] = message.content;
    bucket[COLUMN_STATUS] = chatMessageStatusToString(status);
    bucket[COLUMN_UPDATED_AT] = message.updatedAt !== undefined ? message.updatedAt : null;
    bucket[COLUMN_ERROR_MESSAGE] = message.errorMessage !== undefined ? message.errorMessage : null;
    bucket[COLUMN_IS_STREAMING] = isStreamingInt;
    bucket[COLUMN_SOURCE] = chatMessageSourceToString(message.source);

    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_ID, message.id);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`message.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('message.update');
    }
  }

  async remove(id: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`message.remove: ${extractCauseMessage(err)}`);
    }
  }

  async removeByChatId(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.removeByChatIdWithStore(store, chatId);
  }

  /**
   * 在给定 store 上删除指定 chat 的所有消息,返回删除行数。
   * 用于事务组合,避免嵌套事务。
   * 对不存在的 chat 执行返回 0(幂等)。
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    try {
      return await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `message.removeByChatId: ${extractCauseMessage(err)}`
      );
    }
  }

  async countByChatId(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const sql: string =
      `SELECT COUNT(*) AS cnt ` +
      `FROM ${TABLE_MESSAGES} ` +
      `WHERE ${COLUMN_CHAT_ID} = ?`;
    const rs: relationalStore.ResultSet =
      await store.querySql(sql, [chatId]);
    try {
      if (rs.goToFirstRow()) {
        const ci: number = rs.getColumnIndex('cnt');
        if (ci >= 0) {
          return rs.getLong(ci);
        }
      }
      return 0;
    } finally {
      rs.close();
    }
  }

  private async chatExistsWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.equalTo(COLUMN_ID, chatId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.goToFirstRow();
    } finally {
      rs.close();
    }
  }

  /**
   * 删除指定 chat 中 sequence_number > sequenceNumber 的所有消息。
   * 不删除 sequence_number 等于传入值的消息(保留边界 User 消息)。
   * 返回删除行数。对不存在的 chat 执行返回 0(幂等)。
   *
   * 使用 RdbPredicates.greaterThan,不拼接用户输入 SQL。
   */
  async removeAfterSequence(
    chatId: string,
    sequenceNumber: number
  ): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    if (!isValidSequence(sequenceNumber)) {
      throw DatabaseError.invalidData('sequenceNumber invalid');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.removeAfterSequenceWithStore(store, chatId, sequenceNumber);
  }

  /**
   * 在给定 store 上删除 sequence_number > sequenceNumber 的所有消息。
   * 用于事务组合,避免嵌套事务。
   * 不删除边界消息(sequence_number 等于传入值)。
   * 对不存在的 chat 执行返回 0(幂等)。
   */
  async removeAfterSequenceWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    sequenceNumber: number
  ): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    if (!isValidSequence(sequenceNumber)) {
      throw DatabaseError.invalidData('sequenceNumber invalid');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.greaterThan(COLUMN_SEQUENCE_NUMBER, sequenceNumber);
    try {
      return await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `message.removeAfterSequence: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 规范化指定 chat 中所有 Streaming 状态的异常中断消息:
   * - status: Streaming → Cancelled
   * - is_streaming: 1 → 0
   *
   * 用于应用启动后恢复会话时,把上次未正常结束的 Streaming 消息转为 Cancelled。
   * 不修改 Completed/Cancelled/Failed 消息。
   * 返回受影响行数。
   *
   * errorMessage 不被覆盖(保留原有值,通常为空)。
   */
  async normalizeInterruptedMessages(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS] = chatMessageStatusToString(ChatMessageStatus.Cancelled);
    bucket[COLUMN_IS_STREAMING] = 0;
    bucket[COLUMN_UPDATED_AT] = nowMillis();

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_STATUS, chatMessageStatusToString(ChatMessageStatus.Streaming));

    try {
      return await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `message.normalizeInterrupted: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 查询指定消息的 chatId。
   * 用于 Swipe ensureSwipeState 时获取消息所属 Chat。
   * 消息不存在返回 null。
   */
  async getChatIdByMessageId(messageId: string): Promise<string | null> {
    if (messageId === '') {
      throw DatabaseError.invalidData('messageId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_ID, messageId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      const ci: number = rs.getColumnIndex(COLUMN_CHAT_ID);
      if (ci >= 0) {
        return rs.getString(ci);
      }
      return null;
    } finally {
      rs.close();
    }
  }
}
