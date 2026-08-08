/**
 * WorldSceneMessageRepository
 *
 * 职责(W-SCENE-1A):
 * - world_scene_messages 表的 CRUD 操作
 * - 提供事务内写入方法(insertWithStore / updateWithStore / deleteBySceneWithStore / deleteByWorldWithStore)
 * - 行对象转换(TEXT ↔ 枚举、NULL ↔ undefined、JSON TEXT ↔ string[]、时间戳保持 number)
 * - Streaming 条件更新原语(updateStreamingContentIfStreaming / finalizeIfStreaming)
 *
 * 不负责:
 * - 跨表业务验证(见 W-SCENE-1B WorldSceneService)
 * - sequenceNumber 自动分配(由 Service 负责调用 getMaxSequenceNumber 后分配)
 * - 模型流式运行时(只提供原子条件更新能力)
 *
 * 规则:
 * - listByScene / listBySceneAfterSequence / listStreamingByScene 按 sequenceNumber ASC 排序
 * - listByGenerationBatch 按 sequenceNumber ASC 排序
 * - getMaxSequenceNumber 返回该 Scene 内最大 sequenceNumber,无消息返回 -1
 * - update 不存在返回 NotFound
 * - 未知 senderType / visibility / status 抛 InvalidData
 * - JSON 数组字段:写入前过滤空字符串 + 去重 + 排序;读取时安全解析,异常 JSON 回退为 undefined
 * - 异常 JSON 不得导致整个消息列表加载失败
 *
 * 日志安全:
 * - 不记录完整消息正文、完整 ID 数组、原始 JSON
 * - JSON 解析失败不输出原始 JSON
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldSceneMessage,
  WorldSceneMessageSenderType,
  WorldSceneMessageVisibility,
  WorldSceneMessageStatus,
  isWorldSceneMessageSenderType,
  isWorldSceneMessageVisibility,
  isWorldSceneMessageStatus,
  isTerminalStatus,
  normalizeIdArray
} from '../../models/world/WorldSceneMessage';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_SCENE_MESSAGES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_SCENE_ID,
  COLUMN_SENDER_TYPE_WS,
  COLUMN_SENDER_CHARACTER_INSTANCE_ID,
  COLUMN_CONTENT,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_STATUS,
  COLUMN_GENERATION_BATCH_ID_WS,
  COLUMN_VISIBILITY_WS,
  COLUMN_RECIPIENT_CHARACTER_INSTANCE_IDS_JSON,
  COLUMN_PARTICIPANT_CHARACTER_INSTANCE_IDS_JSON,
  COLUMN_WITNESS_CHARACTER_INSTANCE_IDS_JSON,
  COLUMN_REPLY_TARGET_CHARACTER_INSTANCE_IDS_JSON,
  COLUMN_SESSION_ID,
  COLUMN_LOCATION_ID_WS,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  isValidSequence,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

const STREAMING_STATUS: string = WorldSceneMessageStatus.Streaming;

export class WorldSceneMessageRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldSceneMessage | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldSceneMessage | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
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

  /**
   * 列出指定 Scene 的全部消息,按 sequenceNumber ASC 排序。
   */
  async listByScene(sceneId: string): Promise<WorldSceneMessage[]> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.listByScene: sceneId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listBySceneWithStore(store, sceneId);
  }

  async listBySceneWithStore(
    store: relationalStore.RdbStore,
    sceneId: string
  ): Promise<WorldSceneMessage[]> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.listBySceneWithStore: sceneId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldSceneMessage[] = [];
      while (rs.goToNextRow()) {
        list.push(messageFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 Session 的全部消息,按 sequenceNumber ASC 排序。
   * NULL session_id 消息不会出现在结果中。
   */
  async listBySessionId(sessionId: string): Promise<WorldSceneMessage[]> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.listBySessionId: sessionId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listBySessionIdWithStore(store, sessionId);
  }

  async listBySessionIdWithStore(
    store: relationalStore.RdbStore,
    sessionId: string
  ): Promise<WorldSceneMessage[]> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.listBySessionIdWithStore: sessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_SESSION_ID, sessionId);
    predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldSceneMessage[] = [];
      while (rs.goToNextRow()) {
        list.push(messageFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 统计指定 Session 的消息数量。
   * NULL session_id 消息不计入。
   */
  async countBySessionId(sessionId: string): Promise<number> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.countBySessionId: sessionId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.countBySessionIdWithStore(store, sessionId);
  }

  async countBySessionIdWithStore(
    store: relationalStore.RdbStore,
    sessionId: string
  ): Promise<number> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.countBySessionIdWithStore: sessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_SESSION_ID, sessionId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      let count: number = 0;
      while (rs.goToNextRow()) {
        count++;
      }
      return count;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 Scene 中 sequenceNumber 大于 afterSequence 的消息,按 sequenceNumber ASC 排序。
   */
  async listBySceneAfterSequence(
    sceneId: string,
    afterSequence: number
  ): Promise<WorldSceneMessage[]> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.listBySceneAfterSequence: sceneId empty');
    }
    if (!isValidSequence(afterSequence)) {
      throw DatabaseError.invalidData('WorldSceneMessage.listBySceneAfterSequence: afterSequence invalid');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    predicates.greaterThan(COLUMN_SEQUENCE_NUMBER, afterSequence);
    predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldSceneMessage[] = [];
      while (rs.goToNextRow()) {
        list.push(messageFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 generationBatchId 的全部消息,按 sequenceNumber ASC 排序。
   */
  async listByGenerationBatch(generationBatchId: string): Promise<WorldSceneMessage[]> {
    if (generationBatchId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.listByGenerationBatch: generationBatchId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_GENERATION_BATCH_ID_WS, generationBatchId);
    predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldSceneMessage[] = [];
      while (rs.goToNextRow()) {
        list.push(messageFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async listBySessionAndGenerationBatch(
    sessionId: string,
    generationBatchId: string
  ): Promise<WorldSceneMessage[]> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.listBySessionAndGenerationBatch: sessionId empty');
    }
    if (generationBatchId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.listBySessionAndGenerationBatch: generationBatchId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_SESSION_ID, sessionId);
    predicates.equalTo(COLUMN_GENERATION_BATCH_ID_WS, generationBatchId);
    predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldSceneMessage[] = [];
      while (rs.goToNextRow()) {
        list.push(messageFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 Scene 中 status=Streaming 的消息,按 sequenceNumber ASC 排序。
   */
  async listStreamingByScene(sceneId: string): Promise<WorldSceneMessage[]> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.listStreamingByScene: sceneId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    predicates.equalTo(COLUMN_STATUS, WorldSceneMessageStatus.Streaming);
    predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldSceneMessage[] = [];
      while (rs.goToNextRow()) {
        list.push(messageFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 获取指定 Scene 内最大 sequenceNumber。
   * 无消息时返回 -1(表示下一条消息应从 0 开始)。
   */
  async getMaxSequenceNumber(sceneId: string): Promise<number> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.getMaxSequenceNumber: sceneId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getMaxSequenceNumberWithStore(store, sceneId);
  }

  /**
   * 在事务内获取指定 Scene 内最大 sequenceNumber(由调用方持有 store 和事务)。
   * 无消息时返回 -1。
   */
  async getMaxSequenceNumberWithStore(
    store: relationalStore.RdbStore,
    sceneId: string
  ): Promise<number> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.getMaxSequenceNumberWithStore: sceneId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    predicates.orderByDesc(COLUMN_SEQUENCE_NUMBER);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return -1;
      }
      return rs.getLong(rs.getColumnIndex(COLUMN_SEQUENCE_NUMBER));
    } finally {
      rs.close();
    }
  }

  async insert(message: WorldSceneMessage): Promise<void> {
    this.validateMessage(message);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_SCENE_MESSAGES, messageToBucket(message));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldSceneMessage.insert');
      }
      throw DatabaseError.queryFailed(`WorldSceneMessage.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, message: WorldSceneMessage): Promise<void> {
    this.validateMessage(message);
    try {
      await store.insert(TABLE_WORLD_SCENE_MESSAGES, messageToBucket(message));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldSceneMessage.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldSceneMessage.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(message: WorldSceneMessage): Promise<void> {
    this.validateMessage(message);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_ID, message.id);
    let affected: number;
    try {
      affected = await store.update(messageToBucket(message), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldSceneMessage.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldSceneMessage.update');
    }
  }

  async updateWithStore(store: relationalStore.RdbStore, message: WorldSceneMessage): Promise<void> {
    this.validateMessage(message);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_ID, message.id);
    let affected: number;
    try {
      affected = await store.update(messageToBucket(message), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldSceneMessage.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldSceneMessage.updateWithStore');
    }
  }

  /**
   * Streaming 条件更新:仅当消息 status='streaming' 时更新 content + updatedAt。
   * 用于未来运行时流式增量写入。返回 affectedRows > 0。
   */
  async updateStreamingContentIfStreaming(
    messageId: string,
    content: string,
    updatedAt: number
  ): Promise<boolean> {
    if (messageId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.updateStreamingContentIfStreaming: messageId empty');
    }
    if (!isValidTimestamp(updatedAt)) {
      throw DatabaseError.invalidData('WorldSceneMessage.updateStreamingContentIfStreaming: updatedAt invalid');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.updateStreamingContentIfStreamingWithStore(store, messageId, content, updatedAt);
  }

  /**
   * Streaming 条件更新的 WithStore 版本(由调用方持有 store 和事务)。
   */
  async updateStreamingContentIfStreamingWithStore(
    store: relationalStore.RdbStore,
    messageId: string,
    content: string,
    updatedAt: number
  ): Promise<boolean> {
    if (messageId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.updateStreamingContentIfStreamingWithStore: messageId empty');
    }
    if (!isValidTimestamp(updatedAt)) {
      throw DatabaseError.invalidData('WorldSceneMessage.updateStreamingContentIfStreamingWithStore: updatedAt invalid');
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_CONTENT] = content;
    bucket[COLUMN_UPDATED_AT] = updatedAt;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_ID, messageId);
    predicates.equalTo(COLUMN_STATUS, STREAMING_STATUS);
    try {
      const affected: number = await store.update(bucket, predicates);
      return affected > 0;
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldSceneMessage.updateStreamingContentIfStreamingWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * Streaming 终态条件更新:仅当消息 status='streaming' 时更新 content + status + updatedAt。
   * terminalStatus 只允许 Completed / Cancelled / Failed。
   * 不允许 Completed → Failed / Cancelled → Completed / Failed → Completed / 任意终态再次覆盖。
   * 返回 affectedRows > 0。
   */
  async finalizeIfStreaming(
    messageId: string,
    content: string,
    terminalStatus: WorldSceneMessageStatus,
    updatedAt: number
  ): Promise<boolean> {
    if (messageId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.finalizeIfStreaming: messageId empty');
    }
    if (!isValidTimestamp(updatedAt)) {
      throw DatabaseError.invalidData('WorldSceneMessage.finalizeIfStreaming: updatedAt invalid');
    }
    if (!isTerminalStatus(terminalStatus)) {
      throw DatabaseError.invalidData(
        `WorldSceneMessage.finalizeIfStreaming: terminalStatus not terminal: ${terminalStatus}`
      );
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.finalizeIfStreamingWithStore(store, messageId, content, terminalStatus, updatedAt);
  }

  /**
   * Streaming 终态条件更新的 WithStore 版本(由调用方持有 store 和事务)。
   */
  async finalizeIfStreamingWithStore(
    store: relationalStore.RdbStore,
    messageId: string,
    content: string,
    terminalStatus: WorldSceneMessageStatus,
    updatedAt: number
  ): Promise<boolean> {
    if (messageId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.finalizeIfStreamingWithStore: messageId empty');
    }
    if (!isValidTimestamp(updatedAt)) {
      throw DatabaseError.invalidData('WorldSceneMessage.finalizeIfStreamingWithStore: updatedAt invalid');
    }
    if (!isTerminalStatus(terminalStatus)) {
      throw DatabaseError.invalidData(
        `WorldSceneMessage.finalizeIfStreamingWithStore: terminalStatus not terminal: ${terminalStatus}`
      );
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_CONTENT] = content;
    bucket[COLUMN_STATUS] = terminalStatus;
    bucket[COLUMN_UPDATED_AT] = updatedAt;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_ID, messageId);
    predicates.equalTo(COLUMN_STATUS, STREAMING_STATUS);
    try {
      const affected: number = await store.update(bucket, predicates);
      return affected > 0;
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldSceneMessage.finalizeIfStreamingWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 在事务内删除指定 Scene 的全部消息。
   * - 由调用方持有 store 和事务
   * - 幂等:不存在返回 0,不抛错
   */
  async deleteBySceneWithStore(store: relationalStore.RdbStore, sceneId: string): Promise<void> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.deleteBySceneWithStore: sceneId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldSceneMessage.deleteBySceneWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 在事务内删除指定 World 的全部场景消息。
   * - 由调用方持有 store 和事务
   * - 幂等:不存在返回 0,不抛错
   * - 用于 W-SCENE-1A WorldStateService.deleteWorld 删除完整性
   */
  async deleteByWorldWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.deleteByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENE_MESSAGES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldSceneMessage.deleteByWorldWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  private validateMessage(message: WorldSceneMessage): void {
    if (message.id === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.id empty');
    }
    if (message.worldId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.worldId empty');
    }
    if (message.sceneId === '') {
      throw DatabaseError.invalidData('WorldSceneMessage.sceneId empty');
    }
    if (!isWorldSceneMessageSenderType(message.senderType)) {
      throw DatabaseError.invalidData(`WorldSceneMessage.senderType invalid: ${message.senderType}`);
    }
    if (!isWorldSceneMessageVisibility(message.visibility)) {
      throw DatabaseError.invalidData(`WorldSceneMessage.visibility invalid: ${message.visibility}`);
    }
    if (!isWorldSceneMessageStatus(message.status)) {
      throw DatabaseError.invalidData(`WorldSceneMessage.status invalid: ${message.status}`);
    }
    if (!isValidSequence(message.sequenceNumber)) {
      throw DatabaseError.invalidData('WorldSceneMessage.sequenceNumber invalid');
    }
    if (!isValidTimestamp(message.createdAt)) {
      throw DatabaseError.invalidData('WorldSceneMessage.createdAt invalid');
    }
    if (!isValidTimestamp(message.updatedAt)) {
      throw DatabaseError.invalidData('WorldSceneMessage.updatedAt invalid');
    }
  }
}

function messageToBucket(message: WorldSceneMessage): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = message.id;
  bucket[COLUMN_WORLD_ID] = message.worldId;
  bucket[COLUMN_SCENE_ID] = message.sceneId;
  bucket[COLUMN_SENDER_TYPE_WS] = message.senderType;
  bucket[COLUMN_SENDER_CHARACTER_INSTANCE_ID] = message.senderCharacterInstanceId !== undefined
    ? message.senderCharacterInstanceId : null;
  bucket[COLUMN_CONTENT] = message.content;
  bucket[COLUMN_SEQUENCE_NUMBER] = message.sequenceNumber;
  bucket[COLUMN_STATUS] = message.status;
  bucket[COLUMN_GENERATION_BATCH_ID_WS] = message.generationBatchId !== undefined
    ? message.generationBatchId : null;
  bucket[COLUMN_VISIBILITY_WS] = message.visibility;
  bucket[COLUMN_RECIPIENT_CHARACTER_INSTANCE_IDS_JSON] = idsToJson(message.recipientCharacterInstanceIds);
  bucket[COLUMN_PARTICIPANT_CHARACTER_INSTANCE_IDS_JSON] = idsToJson(message.participantCharacterInstanceIds);
  bucket[COLUMN_WITNESS_CHARACTER_INSTANCE_IDS_JSON] = idsToJson(message.witnessCharacterInstanceIds);
  bucket[COLUMN_REPLY_TARGET_CHARACTER_INSTANCE_IDS_JSON] = idsToJson(message.replyTargetCharacterInstanceIds);
  bucket[COLUMN_SESSION_ID] = message.sessionId !== undefined ? message.sessionId : null;
  bucket[COLUMN_LOCATION_ID_WS] = message.locationId !== undefined ? message.locationId : null;
  bucket[COLUMN_CREATED_AT] = message.createdAt;
  bucket[COLUMN_UPDATED_AT] = message.updatedAt;
  return bucket;
}

/**
 * 将 ID 数组序列化为 JSON TEXT。
 * 空数组或 undefined 统一保存为 null(不写入 JSON 字符串)。
 * 非空数组在写入前再次规范化(过滤空 + 去重 + 排序),保证写入一致。
 */
function idsToJson(ids: string[] | undefined): string | null {
  if (ids === undefined || ids.length === 0) {
    return null;
  }
  const normalized: string[] | undefined = normalizeIdArray(ids);
  if (normalized === undefined || normalized.length === 0) {
    return null;
  }
  return JSON.stringify(normalized);
}

/**
 * 安全解析 JSON TEXT 为 string[]。
 * - null / 空字符串 → undefined
 * - 只接受字符串数组
 * - 过滤非法值(非字符串、空字符串)
 * - 再次去重
 * - 异常 JSON 回退为 undefined,不抛错
 *
 * 日志安全:解析失败不输出原始 JSON。
 */
function jsonToIds(json: string | null | undefined): string[] | undefined {
  if (json === null || json === undefined || json === '') {
    return undefined;
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(json);
  } catch (e) {
    // 异常 JSON 回退为 undefined,不输出原始 JSON
    return undefined;
  }
  if (!Array.isArray(parsed)) {
    return undefined;
  }
  const arr: Object[] = parsed as Object[];
  const collected: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (typeof item !== 'string') {
      continue;
    }
    const str: string = item as string;
    if (str === '') {
      continue;
    }
    collected.push(str);
  }
  return normalizeIdArray(collected);
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

function messageFromRow(rs: relationalStore.ResultSet): WorldSceneMessage {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldSceneMessage.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldSceneMessage.worldId empty in row');
  }
  const sceneId: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_ID));
  if (sceneId === '') {
    throw DatabaseError.invalidData('WorldSceneMessage.sceneId empty in row');
  }
  const senderTypeRaw: string = rs.getString(rs.getColumnIndex(COLUMN_SENDER_TYPE_WS));
  if (!isWorldSceneMessageSenderType(senderTypeRaw)) {
    throw DatabaseError.invalidData(`WorldSceneMessage.senderType invalid in row: ${senderTypeRaw}`);
  }
  const visibilityRaw: string = rs.getString(rs.getColumnIndex(COLUMN_VISIBILITY_WS));
  if (!isWorldSceneMessageVisibility(visibilityRaw)) {
    throw DatabaseError.invalidData(`WorldSceneMessage.visibility invalid in row: ${visibilityRaw}`);
  }
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  if (!isWorldSceneMessageStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldSceneMessage.status invalid in row: ${statusRaw}`);
  }
  const content: string = rs.getString(rs.getColumnIndex(COLUMN_CONTENT));
  const sequenceNumber: number = rs.getLong(rs.getColumnIndex(COLUMN_SEQUENCE_NUMBER));
  if (!isValidSequence(sequenceNumber)) {
    throw DatabaseError.invalidData('WorldSceneMessage.sequenceNumber invalid in row');
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldSceneMessage.createdAt invalid in row');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('WorldSceneMessage.updatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    sceneId: sceneId,
    senderType: senderTypeRaw as WorldSceneMessageSenderType,
    senderCharacterInstanceId: readOptionalString(rs, COLUMN_SENDER_CHARACTER_INSTANCE_ID),
    content: content,
    sequenceNumber: sequenceNumber,
    status: statusRaw as WorldSceneMessageStatus,
    generationBatchId: readOptionalString(rs, COLUMN_GENERATION_BATCH_ID_WS),
    visibility: visibilityRaw as WorldSceneMessageVisibility,
    recipientCharacterInstanceIds: jsonToIds(readOptionalString(rs, COLUMN_RECIPIENT_CHARACTER_INSTANCE_IDS_JSON)),
    participantCharacterInstanceIds: jsonToIds(readOptionalString(rs, COLUMN_PARTICIPANT_CHARACTER_INSTANCE_IDS_JSON)),
    witnessCharacterInstanceIds: jsonToIds(readOptionalString(rs, COLUMN_WITNESS_CHARACTER_INSTANCE_IDS_JSON)),
    replyTargetCharacterInstanceIds: jsonToIds(readOptionalString(rs, COLUMN_REPLY_TARGET_CHARACTER_INSTANCE_IDS_JSON)),
    sessionId: readOptionalString(rs, COLUMN_SESSION_ID),
    locationId: readOptionalString(rs, COLUMN_LOCATION_ID_WS),
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
