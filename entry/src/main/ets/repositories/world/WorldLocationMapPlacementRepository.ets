/**
 * WorldLocationMapPlacementRepository
 *
 * 职责(W1C-WORLD-MAP-CONTRACT):
 * - world_location_map_placements 表的 CRUD 操作
 * - 提供事务内写入方法(insertWithStore / upsertWithStore / deleteByWorldWithStore / deleteByLocationWithStore)
 * - 行对象转换(REAL ↔ number、时间戳保持 number)
 *
 * 不负责:
 * - 跨表业务验证(见 W1D Service)
 * - 数值有效性校验(由模型层 validatePlacementNumbers 提供)
 * - 确认 Location / World 是否存在(由调用方 Service 负责)
 *
 * 规则:
 * - listByWorldId 按 createdAt ASC 排序
 * - UNIQUE(world_id, location_id) 冲突映射为 AlreadyExists
 * - upsert 利用 UNIQUE 冽突替换实现 INSERT OR REPLACE
 * - update 不存在返回 NotFound
 * - update 不修改 worldId / locationId(由调用方保证)
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldLocationMapPlacement,
  validatePlacementNumbers
} from '../../models/world/WorldLocationMapPlacement';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_LOCATION_MAP_PLACEMENTS,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_LOCATION_ID,
  COLUMN_POSITION_X,
  COLUMN_POSITION_Y,
  COLUMN_POSITION_Z,
  COLUMN_ROTATION_X,
  COLUMN_ROTATION_Y,
  COLUMN_ROTATION_Z,
  COLUMN_PLACEMENT_SCALE,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldLocationMapPlacementRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldLocationMapPlacement | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldLocationMapPlacement | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return placementFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listByWorldId(worldId: string): Promise<WorldLocationMapPlacement[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.listByWorldId: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listByWorldIdWithStore(store, worldId);
  }

  async listByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<WorldLocationMapPlacement[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.listByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldLocationMapPlacement[] = [];
      while (rs.goToNextRow()) {
        list.push(placementFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async getByWorldAndLocation(
    worldId: string,
    locationId: string
  ): Promise<WorldLocationMapPlacement | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.getByWorldAndLocation: worldId empty');
    }
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.getByWorldAndLocation: locationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByWorldAndLocationWithStore(store, worldId, locationId);
  }

  async getByWorldAndLocationWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    locationId: string
  ): Promise<WorldLocationMapPlacement | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.getByWorldAndLocationWithStore: worldId empty');
    }
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.getByWorldAndLocationWithStore: locationId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_LOCATION_ID, locationId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return placementFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async insert(placement: WorldLocationMapPlacement): Promise<void> {
    this.validatePlacement(placement);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_LOCATION_MAP_PLACEMENTS, placementToBucket(placement));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldLocationMapPlacement.insert');
      }
      throw DatabaseError.queryFailed(`WorldLocationMapPlacement.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, placement: WorldLocationMapPlacement): Promise<void> {
    this.validatePlacement(placement);
    try {
      await store.insert(TABLE_WORLD_LOCATION_MAP_PLACEMENTS, placementToBucket(placement));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldLocationMapPlacement.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldLocationMapPlacement.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 基于 UNIQUE(world_id, location_id) 的 upsert。
   * 存在则更新位置/旋转/缩放/updatedAt,不存在则插入。
   * 不修改 worldId / locationId / createdAt。
   */
  async upsertWithStore(store: relationalStore.RdbStore, placement: WorldLocationMapPlacement): Promise<void> {
    this.validatePlacement(placement);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_WORLD_ID, placement.worldId);
    predicates.equalTo(COLUMN_LOCATION_ID, placement.locationId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (rs.goToFirstRow()) {
        const existingId: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
        const existingCreatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
        const updateBucket: relationalStore.ValuesBucket = {};
        updateBucket[COLUMN_ID] = existingId;
        updateBucket[COLUMN_WORLD_ID] = placement.worldId;
        updateBucket[COLUMN_LOCATION_ID] = placement.locationId;
        updateBucket[COLUMN_POSITION_X] = placement.positionX;
        updateBucket[COLUMN_POSITION_Y] = placement.positionY;
        updateBucket[COLUMN_POSITION_Z] = placement.positionZ;
        updateBucket[COLUMN_ROTATION_X] = placement.rotationX;
        updateBucket[COLUMN_ROTATION_Y] = placement.rotationY;
        updateBucket[COLUMN_ROTATION_Z] = placement.rotationZ;
        updateBucket[COLUMN_PLACEMENT_SCALE] = placement.scale;
        updateBucket[COLUMN_CREATED_AT] = existingCreatedAt;
        updateBucket[COLUMN_UPDATED_AT] = placement.updatedAt;
        const updatePredicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
        updatePredicates.equalTo(COLUMN_ID, existingId);
        try {
          await store.update(updateBucket, updatePredicates);
        } catch (err) {
          throw DatabaseError.queryFailed(`WorldLocationMapPlacement.upsertWithStore update: ${extractCauseMessage(err)}`);
        }
      } else {
        try {
          await store.insert(TABLE_WORLD_LOCATION_MAP_PLACEMENTS, placementToBucket(placement));
        } catch (err) {
          if (isConstraintViolation(err)) {
            throw DatabaseError.alreadyExists('WorldLocationMapPlacement.upsertWithStore insert');
          }
          throw DatabaseError.queryFailed(`WorldLocationMapPlacement.upsertWithStore insert: ${extractCauseMessage(err)}`);
        }
      }
    } finally {
      rs.close();
    }
  }

  async update(placement: WorldLocationMapPlacement): Promise<void> {
    this.validatePlacement(placement);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_ID, placement.id);
    let affected: number;
    try {
      affected = await store.update(placementToBucket(placement), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationMapPlacement.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldLocationMapPlacement.update');
    }
  }

  async updateWithStore(store: relationalStore.RdbStore, placement: WorldLocationMapPlacement): Promise<void> {
    this.validatePlacement(placement);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_ID, placement.id);
    let affected: number;
    try {
      affected = await store.update(placementToBucket(placement), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationMapPlacement.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldLocationMapPlacement.updateWithStore');
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationMapPlacement.deleteById: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationMapPlacement.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除指定 World 的全部 Placement 行。
   * 幂等:不存在返回 0,不抛错。
   */
  async deleteByWorldWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.deleteByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationMapPlacement.deleteByWorldWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除指定 Location 关联的 Placement 行。
   * 幂等:不存在返回 0,不抛错。
   */
  async deleteByLocationWithStore(store: relationalStore.RdbStore, locationId: string): Promise<void> {
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.deleteByLocationWithStore: locationId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_LOCATION_MAP_PLACEMENTS);
    predicates.equalTo(COLUMN_LOCATION_ID, locationId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldLocationMapPlacement.deleteByLocationWithStore: ${extractCauseMessage(err)}`);
    }
  }

  private validatePlacement(placement: WorldLocationMapPlacement): void {
    if (placement.id === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.id empty');
    }
    if (placement.worldId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.worldId empty');
    }
    if (placement.locationId === '') {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.locationId empty');
    }
    validatePlacementNumbers(
      placement.positionX, placement.positionY, placement.positionZ,
      placement.rotationX, placement.rotationY, placement.rotationZ,
      placement.scale
    );
    if (!isValidTimestamp(placement.createdAt)) {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.createdAt invalid');
    }
    if (!isValidTimestamp(placement.updatedAt)) {
      throw DatabaseError.invalidData('WorldLocationMapPlacement.updatedAt invalid');
    }
  }
}

function placementToBucket(placement: WorldLocationMapPlacement): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = placement.id;
  bucket[COLUMN_WORLD_ID] = placement.worldId;
  bucket[COLUMN_LOCATION_ID] = placement.locationId;
  bucket[COLUMN_POSITION_X] = placement.positionX;
  bucket[COLUMN_POSITION_Y] = placement.positionY;
  bucket[COLUMN_POSITION_Z] = placement.positionZ;
  bucket[COLUMN_ROTATION_X] = placement.rotationX;
  bucket[COLUMN_ROTATION_Y] = placement.rotationY;
  bucket[COLUMN_ROTATION_Z] = placement.rotationZ;
  bucket[COLUMN_PLACEMENT_SCALE] = placement.scale;
  bucket[COLUMN_CREATED_AT] = placement.createdAt;
  bucket[COLUMN_UPDATED_AT] = placement.updatedAt;
  return bucket;
}

function placementFromRow(rs: relationalStore.ResultSet): WorldLocationMapPlacement {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldLocationMapPlacement.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldLocationMapPlacement.worldId empty in row');
  }
  const locationId: string = rs.getString(rs.getColumnIndex(COLUMN_LOCATION_ID));
  if (locationId === '') {
    throw DatabaseError.invalidData('WorldLocationMapPlacement.locationId empty in row');
  }
  const positionX: number = rs.getDouble(rs.getColumnIndex(COLUMN_POSITION_X));
  const positionY: number = rs.getDouble(rs.getColumnIndex(COLUMN_POSITION_Y));
  const positionZ: number = rs.getDouble(rs.getColumnIndex(COLUMN_POSITION_Z));
  const rotationX: number = rs.getDouble(rs.getColumnIndex(COLUMN_ROTATION_X));
  const rotationY: number = rs.getDouble(rs.getColumnIndex(COLUMN_ROTATION_Y));
  const rotationZ: number = rs.getDouble(rs.getColumnIndex(COLUMN_ROTATION_Z));
  const scale: number = rs.getDouble(rs.getColumnIndex(COLUMN_PLACEMENT_SCALE));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldLocationMapPlacement.createdAt invalid in row');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('WorldLocationMapPlacement.updatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    locationId: locationId,
    positionX: positionX,
    positionY: positionY,
    positionZ: positionZ,
    rotationX: rotationX,
    rotationY: rotationY,
    rotationZ: rotationZ,
    scale: scale,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
