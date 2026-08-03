/**
 * WorldEventRepository
 *
 * 职责(W-DATA-1A):
 * - world_events 表的 CRUD 操作(主要为 insert / 查询 / 事务删除)
 * - 提供事务内写入方法(insertWithStore / deleteByWorldWithStore)
 * - 行对象转换(TEXT ↔ 枚举、NULL ↔ undefined、时间戳保持 number)
 *
 * 不负责:
 * - 跨表业务验证(见 W-DATA-1B WorldStateService)
 * - 事件与状态写入同一事务编排
 * - 事件更新(视为追加式记录,不提供普通业务更新方法)
 *
 * 规则:
 * - listByWorld / listRecentByWorld 按 occurredAt DESC(最近在前)
 * - 未知 eventType 抛 InvalidData,不静默解释为其他状态
 * - 不提供普通业务 update 方法
 * - 事件记录默认不可更新
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldEvent, WorldEventType, isWorldEventType } from '../../models/world/WorldEvent';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_EVENTS,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_EVENT_TYPE,
  COLUMN_SOURCE_CHARACTER_INSTANCE_ID,
  COLUMN_SOURCE_LOCATION_ID,
  COLUMN_TARGET_LOCATION_ID,
  COLUMN_SOURCE_SCENE_ID,
  COLUMN_SOURCE_MESSAGE_ID,
  COLUMN_SUMMARY,
  COLUMN_PAYLOAD_JSON,
  COLUMN_OCCURRED_AT,
  COLUMN_CREATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldEventRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldEvent | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldEvent.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENTS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return eventFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 World 的全部事件,按 occurredAt DESC(最近在前)。
   */
  async listByWorld(worldId: string): Promise<WorldEvent[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEvent.listByWorld: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENTS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.orderByDesc(COLUMN_OCCURRED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldEvent[] = [];
      while (rs.goToNextRow()) {
        list.push(eventFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 World 最近 limit 条事件,按 occurredAt DESC(最近在前)。
   * limit <= 0 时返回空数组。
   */
  async listRecentByWorld(worldId: string, limit: number): Promise<WorldEvent[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEvent.listRecentByWorld: worldId empty');
    }
    if (!Number.isFinite(limit) || limit <= 0) {
      return [];
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENTS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.orderByDesc(COLUMN_OCCURRED_AT);
    predicates.limitAs(limit);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldEvent[] = [];
      while (rs.goToNextRow()) {
        list.push(eventFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async insert(event: WorldEvent): Promise<void> {
    this.validateEvent(event);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_EVENTS, eventToBucket(event));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldEvent.insert');
      }
      throw DatabaseError.queryFailed(`WorldEvent.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, event: WorldEvent): Promise<void> {
    this.validateEvent(event);
    try {
      await store.insert(TABLE_WORLD_EVENTS, eventToBucket(event));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldEvent.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldEvent.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除指定 World 的全部事件。
   * - 幂等:不存在返回 0,不抛错
   * - 用于 W-DATA-1B 删除 World 时同步清理事件
   * - 不提供单条事件的普通业务删除入口(事件视为追加式记录)
   */
  async deleteByWorldWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEvent.deleteByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENTS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldEvent.deleteByWorldWithStore: ${extractCauseMessage(err)}`);
    }
  }

  private validateEvent(event: WorldEvent): void {
    if (event.id === '') {
      throw DatabaseError.invalidData('WorldEvent.id empty');
    }
    if (event.worldId === '') {
      throw DatabaseError.invalidData('WorldEvent.worldId empty');
    }
    if (!isWorldEventType(event.eventType)) {
      throw DatabaseError.invalidData(`WorldEvent.eventType invalid: ${event.eventType}`);
    }
    if (!isValidTimestamp(event.occurredAt)) {
      throw DatabaseError.invalidData('WorldEvent.occurredAt invalid');
    }
    if (!isValidTimestamp(event.createdAt)) {
      throw DatabaseError.invalidData('WorldEvent.createdAt invalid');
    }
  }
}

function eventToBucket(event: WorldEvent): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = event.id;
  bucket[COLUMN_WORLD_ID] = event.worldId;
  bucket[COLUMN_EVENT_TYPE] = event.eventType;
  bucket[COLUMN_SOURCE_CHARACTER_INSTANCE_ID] = event.sourceCharacterInstanceId !== undefined
    ? event.sourceCharacterInstanceId : null;
  bucket[COLUMN_SOURCE_LOCATION_ID] = event.sourceLocationId !== undefined
    ? event.sourceLocationId : null;
  bucket[COLUMN_TARGET_LOCATION_ID] = event.targetLocationId !== undefined
    ? event.targetLocationId : null;
  bucket[COLUMN_SOURCE_SCENE_ID] = event.sourceSceneId !== undefined
    ? event.sourceSceneId : null;
  bucket[COLUMN_SOURCE_MESSAGE_ID] = event.sourceMessageId !== undefined
    ? event.sourceMessageId : null;
  bucket[COLUMN_SUMMARY] = event.summary;
  bucket[COLUMN_PAYLOAD_JSON] = event.payloadJson !== undefined
    ? event.payloadJson : null;
  bucket[COLUMN_OCCURRED_AT] = event.occurredAt;
  bucket[COLUMN_CREATED_AT] = event.createdAt;
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

function eventFromRow(rs: relationalStore.ResultSet): WorldEvent {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldEvent.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldEvent.worldId empty in row');
  }
  const eventTypeRaw: string = rs.getString(rs.getColumnIndex(COLUMN_EVENT_TYPE));
  if (!isWorldEventType(eventTypeRaw)) {
    throw DatabaseError.invalidData(`WorldEvent.eventType invalid in row: ${eventTypeRaw}`);
  }
  const summary: string = rs.getString(rs.getColumnIndex(COLUMN_SUMMARY));
  const occurredAt: number = rs.getLong(rs.getColumnIndex(COLUMN_OCCURRED_AT));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(occurredAt)) {
    throw DatabaseError.invalidData('WorldEvent.occurredAt invalid in row');
  }
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldEvent.createdAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    eventType: eventTypeRaw as WorldEventType,
    sourceCharacterInstanceId: readOptionalString(rs, COLUMN_SOURCE_CHARACTER_INSTANCE_ID),
    sourceLocationId: readOptionalString(rs, COLUMN_SOURCE_LOCATION_ID),
    targetLocationId: readOptionalString(rs, COLUMN_TARGET_LOCATION_ID),
    sourceSceneId: readOptionalString(rs, COLUMN_SOURCE_SCENE_ID),
    sourceMessageId: readOptionalString(rs, COLUMN_SOURCE_MESSAGE_ID),
    summary: summary,
    payloadJson: readOptionalString(rs, COLUMN_PAYLOAD_JSON),
    occurredAt: occurredAt,
    createdAt: createdAt
  };
}
