/**
 * WorldLocationEdgeRepository
 *
 * 职责(W-DATA-1A):
 * - world_location_edges 表的 CRUD 操作
 * - 提供事务内写入方法(insertWithStore / updateWithStore /
 *    deleteByWorldWithStore / deleteByLocationWithStore)
 * - 行对象转换(INTEGER 0/1 ↔ boolean、时间戳保持 number)
 *
 * 不负责:
 * - 跨表业务验证(见 W-DATA-1B WorldStateService)
 * - 双向可通行判断(已有 A→B 双向边时禁止再创建 B→A)
 * - 已有 A→B 和 B→A 时不能直接再创建 A↔B
 * - 地点是否存在 / 是否属于同一 World
 *
 * Repository 只查询精确方向(from_location_id → to_location_id)。
 * 双向可通行判断与反向冲突由 W-DATA-1B Service 处理。
 *
 * 规则:
 * - listByWorld / listFromLocation / listRelatedToLocation 按 createdAt ASC
 * - findExact 精确匹配(world_id, from_location_id, to_location_id)
 * - 唯一约束(world_id, from_location_id, to_location_id)冲突映射为 AlreadyExists
 * - update 不存在返回 NotFound
 * - directionLabel 不放入唯一约束
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldLocationEdge } from '../../models/world/WorldLocationEdge';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_LOCATION_EDGES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_FROM_LOCATION_ID,
  COLUMN_TO_LOCATION_ID,
  COLUMN_DIRECTION_LABEL,
  COLUMN_TRAVEL_DESCRIPTION,
  COLUMN_IS_BIDIRECTIONAL,
  COLUMN_IS_ENABLED,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  intToBoolean,
  booleanToInt,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldLocationEdgeRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldLocationEdge | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return edgeFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 World 的全部边,按 createdAt ASC 排序。
   */
  async listByWorld(worldId: string): Promise<WorldLocationEdge[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.listByWorld: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldLocationEdge[] = [];
      while (rs.goToNextRow()) {
        list.push(edgeFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出从指定地点出发的全部边,按 createdAt ASC 排序。
   */
  async listFromLocation(locationId: string): Promise<WorldLocationEdge[]> {
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.listFromLocation: locationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_FROM_LOCATION_ID, locationId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldLocationEdge[] = [];
      while (rs.goToNextRow()) {
        list.push(edgeFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出与指定地点相关的全部边(作为起点或终点),按 createdAt ASC 排序。
   */
  async listRelatedToLocation(locationId: string): Promise<WorldLocationEdge[]> {
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.listRelatedToLocation: locationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_FROM_LOCATION_ID, locationId);
    predicates.or();
    predicates.equalTo(COLUMN_TO_LOCATION_ID, locationId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldLocationEdge[] = [];
      while (rs.goToNextRow()) {
        list.push(edgeFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 精确查找(world_id, from_location_id, to_location_id)。
   */
  async findExact(
    worldId: string,
    fromLocationId: string,
    toLocationId: string
  ): Promise<WorldLocationEdge | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.findExact: worldId empty');
    }
    if (fromLocationId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.findExact: fromLocationId empty');
    }
    if (toLocationId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.findExact: toLocationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_FROM_LOCATION_ID, fromLocationId);
    predicates.equalTo(COLUMN_TO_LOCATION_ID, toLocationId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return edgeFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async insert(edge: WorldLocationEdge): Promise<void> {
    this.validateEdge(edge);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_LOCATION_EDGES, edgeToBucket(edge));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldLocationEdge.insert');
      }
      throw DatabaseError.queryFailed(`WorldLocationEdge.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, edge: WorldLocationEdge): Promise<void> {
    this.validateEdge(edge);
    try {
      await store.insert(TABLE_WORLD_LOCATION_EDGES, edgeToBucket(edge));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldLocationEdge.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldLocationEdge.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(edge: WorldLocationEdge): Promise<void> {
    this.validateEdge(edge);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_ID, edge.id);
    let affected: number;
    try {
      affected = await store.update(edgeToBucket(edge), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationEdge.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldLocationEdge.update');
    }
  }

  async updateWithStore(store: relationalStore.RdbStore, edge: WorldLocationEdge): Promise<void> {
    this.validateEdge(edge);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_ID, edge.id);
    let affected: number;
    try {
      affected = await store.update(edgeToBucket(edge), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationEdge.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldLocationEdge.updateWithStore');
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationEdge.deleteById: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationEdge.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除指定 World 的全部边。
   * - 幂等:不存在返回 0,不抛错
   */
  async deleteByWorldWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.deleteByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationEdge.deleteByWorldWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除与指定地点相关的全部边(作为起点或终点)。
   * - 幂等:不存在返回 0,不抛错
   * - 用于 W-DATA-1B 删除地点时同步清理边
   */
  async deleteByLocationWithStore(store: relationalStore.RdbStore, locationId: string): Promise<void> {
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.deleteByLocationWithStore: locationId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_EDGES);
    predicates.equalTo(COLUMN_FROM_LOCATION_ID, locationId);
    predicates.or();
    predicates.equalTo(COLUMN_TO_LOCATION_ID, locationId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationEdge.deleteByLocationWithStore: ${extractCauseMessage(err)}`);
    }
  }

  private validateEdge(edge: WorldLocationEdge): void {
    if (edge.id === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.id empty');
    }
    if (edge.worldId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.worldId empty');
    }
    if (edge.fromLocationId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.fromLocationId empty');
    }
    if (edge.toLocationId === '') {
      throw DatabaseError.invalidData('WorldLocationEdge.toLocationId empty');
    }
    if (edge.fromLocationId === edge.toLocationId) {
      throw DatabaseError.invalidData('WorldLocationEdge: self-loop not allowed');
    }
    if (!isValidTimestamp(edge.createdAt)) {
      throw DatabaseError.invalidData('WorldLocationEdge.createdAt invalid');
    }
    if (!isValidTimestamp(edge.updatedAt)) {
      throw DatabaseError.invalidData('WorldLocationEdge.updatedAt invalid');
    }
  }
}

function edgeToBucket(edge: WorldLocationEdge): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = edge.id;
  bucket[COLUMN_WORLD_ID] = edge.worldId;
  bucket[COLUMN_FROM_LOCATION_ID] = edge.fromLocationId;
  bucket[COLUMN_TO_LOCATION_ID] = edge.toLocationId;
  bucket[COLUMN_DIRECTION_LABEL] = edge.directionLabel;
  bucket[COLUMN_TRAVEL_DESCRIPTION] = edge.travelDescription;
  bucket[COLUMN_IS_BIDIRECTIONAL] = booleanToInt(edge.isBidirectional);
  bucket[COLUMN_IS_ENABLED] = booleanToInt(edge.isEnabled);
  bucket[COLUMN_CREATED_AT] = edge.createdAt;
  bucket[COLUMN_UPDATED_AT] = edge.updatedAt;
  return bucket;
}

function edgeFromRow(rs: relationalStore.ResultSet): WorldLocationEdge {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldLocationEdge.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldLocationEdge.worldId empty in row');
  }
  const fromLocationId: string = rs.getString(rs.getColumnIndex(COLUMN_FROM_LOCATION_ID));
  if (fromLocationId === '') {
    throw DatabaseError.invalidData('WorldLocationEdge.fromLocationId empty in row');
  }
  const toLocationId: string = rs.getString(rs.getColumnIndex(COLUMN_TO_LOCATION_ID));
  if (toLocationId === '') {
    throw DatabaseError.invalidData('WorldLocationEdge.toLocationId empty in row');
  }
  const directionLabel: string = rs.getString(rs.getColumnIndex(COLUMN_DIRECTION_LABEL));
  const travelDescription: string = rs.getString(rs.getColumnIndex(COLUMN_TRAVEL_DESCRIPTION));
  const isBidirectional: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_IS_BIDIRECTIONAL)));
  const isEnabled: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_IS_ENABLED)));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldLocationEdge.createdAt invalid in row');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('WorldLocationEdge.updatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    fromLocationId: fromLocationId,
    toLocationId: toLocationId,
    directionLabel: directionLabel,
    travelDescription: travelDescription,
    isBidirectional: isBidirectional,
    isEnabled: isEnabled,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
