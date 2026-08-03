/**
 * WorldLocationRepository
 *
 * 职责(W-DATA-1A):
 * - world_locations 表的 CRUD 操作
 * - 提供事务内写入方法(insertWithStore / updateWithStore / deleteByWorldWithStore)
 * - 行对象转换(INTEGER 0/1 ↔ boolean、TEXT ↔ 枚举、NULL ↔ undefined、时间戳保持 number)
 *
 * 不负责:
 * - 跨表业务验证(见 W-DATA-1B WorldStateService)
 * - canonicalKey 生成(由模型层 buildCanonicalKey 提供)
 * - 地点名称模糊合并 / 语义近似 / 拼音近似 / 编辑距离自动合并
 * - 地点删除保护(其他表是否引用该地点)
 *
 * 规则:
 * - listByWorld 按 createdAt ASC 排序(不使用名称排序作为图布局语义)
 * - findByCanonicalKey 精确匹配
 * - 唯一约束(world_id, canonical_key)冲突映射为 AlreadyExists
 * - update 不存在返回 NotFound
 * - 未知 status 抛 InvalidData
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldLocation, WorldLocationStatus, isWorldLocationStatus } from '../../models/world/WorldLocation';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_LOCATIONS,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_NAME,
  COLUMN_DESCRIPTION,
  COLUMN_CANONICAL_KEY,
  COLUMN_STATUS,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldLocationRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldLocation | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocation.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  /**
   * 在事务内按 id 加载地点(由调用方持有 store 和事务)。
   * 用于 W-DATA-1B WorldStateService 在同一事务内读取地点状态。
   */
  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldLocation | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocation.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATIONS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return locationFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 World 的全部地点,按 createdAt ASC 排序。
   */
  async listByWorld(worldId: string): Promise<WorldLocation[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocation.listByWorld: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATIONS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldLocation[] = [];
      while (rs.goToNextRow()) {
        list.push(locationFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 按 canonicalKey 精确查找指定 World 内的地点。
   */
  async findByCanonicalKey(worldId: string, canonicalKey: string): Promise<WorldLocation | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocation.findByCanonicalKey: worldId empty');
    }
    if (canonicalKey === '') {
      throw DatabaseError.invalidData('WorldLocation.findByCanonicalKey: canonicalKey empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.findByCanonicalKeyWithStore(store, worldId, canonicalKey);
  }

  /**
   * 在事务内按 canonicalKey 精确查找(由调用方持有 store 和事务)。
   * 用于 W-DATA-1B 创建/更新地点时在同一事务内做精确去重校验。
   */
  async findByCanonicalKeyWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    canonicalKey: string
  ): Promise<WorldLocation | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocation.findByCanonicalKeyWithStore: worldId empty');
    }
    if (canonicalKey === '') {
      throw DatabaseError.invalidData('WorldLocation.findByCanonicalKeyWithStore: canonicalKey empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATIONS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CANONICAL_KEY, canonicalKey);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return locationFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async insert(location: WorldLocation): Promise<void> {
    this.validateLocation(location);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_LOCATIONS, locationToBucket(location));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldLocation.insert');
      }
      throw DatabaseError.queryFailed(`WorldLocation.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, location: WorldLocation): Promise<void> {
    this.validateLocation(location);
    try {
      await store.insert(TABLE_WORLD_LOCATIONS, locationToBucket(location));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldLocation.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldLocation.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(location: WorldLocation): Promise<void> {
    this.validateLocation(location);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATIONS);
    predicates.equalTo(COLUMN_ID, location.id);
    let affected: number;
    try {
      affected = await store.update(locationToBucket(location), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocation.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldLocation.update');
    }
  }

  async updateWithStore(store: relationalStore.RdbStore, location: WorldLocation): Promise<void> {
    this.validateLocation(location);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATIONS);
    predicates.equalTo(COLUMN_ID, location.id);
    let affected: number;
    try {
      affected = await store.update(locationToBucket(location), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocation.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldLocation.updateWithStore');
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocation.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATIONS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocation.deleteById: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocation.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATIONS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocation.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除指定 World 的全部地点行。
   * - 由调用方持有 store 和事务
   * - 幂等:不存在返回 0,不抛错
   * - 不级联删除 edges / character_instances(W-DATA-1B Service 负责编排)
   */
  async deleteByWorldWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocation.deleteByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATIONS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocation.deleteByWorldWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async countByWorld(worldId: string): Promise<number> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocation.countByWorld: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.countByWorldWithStore(store, worldId);
  }

  /**
   * 在事务内统计指定 World 的地点数量(由调用方持有 store 和事务)。
   */
  async countByWorldWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<number> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocation.countByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATIONS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
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

  private validateLocation(location: WorldLocation): void {
    if (location.id === '') {
      throw DatabaseError.invalidData('WorldLocation.id empty');
    }
    if (location.worldId === '') {
      throw DatabaseError.invalidData('WorldLocation.worldId empty');
    }
    if (location.name === '') {
      throw DatabaseError.invalidData('WorldLocation.name empty');
    }
    if (location.canonicalKey === '') {
      throw DatabaseError.invalidData('WorldLocation.canonicalKey empty');
    }
    if (!isWorldLocationStatus(location.status)) {
      throw DatabaseError.invalidData(`WorldLocation.status invalid: ${location.status}`);
    }
    if (!isValidTimestamp(location.createdAt)) {
      throw DatabaseError.invalidData('WorldLocation.createdAt invalid');
    }
    if (!isValidTimestamp(location.updatedAt)) {
      throw DatabaseError.invalidData('WorldLocation.updatedAt invalid');
    }
  }
}

function locationToBucket(location: WorldLocation): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = location.id;
  bucket[COLUMN_WORLD_ID] = location.worldId;
  bucket[COLUMN_NAME] = location.name;
  bucket[COLUMN_DESCRIPTION] = location.description;
  bucket[COLUMN_CANONICAL_KEY] = location.canonicalKey;
  bucket[COLUMN_STATUS] = location.status;
  bucket[COLUMN_CREATED_AT] = location.createdAt;
  bucket[COLUMN_UPDATED_AT] = location.updatedAt;
  return bucket;
}

function locationFromRow(rs: relationalStore.ResultSet): WorldLocation {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldLocation.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldLocation.worldId empty in row');
  }
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_NAME));
  if (name === '') {
    throw DatabaseError.invalidData('WorldLocation.name empty in row');
  }
  const description: string = rs.getString(rs.getColumnIndex(COLUMN_DESCRIPTION));
  const canonicalKey: string = rs.getString(rs.getColumnIndex(COLUMN_CANONICAL_KEY));
  if (canonicalKey === '') {
    throw DatabaseError.invalidData('WorldLocation.canonicalKey empty in row');
  }
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  if (!isWorldLocationStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldLocation.status invalid in row: ${statusRaw}`);
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldLocation.createdAt invalid in row');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('WorldLocation.updatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    name: name,
    description: description,
    canonicalKey: canonicalKey,
    status: statusRaw as WorldLocationStatus,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
