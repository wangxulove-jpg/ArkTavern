/**
 * WorldSceneRepository
 *
 * 职责(W-SCENE-1A):
 * - world_scenes 表的 CRUD 操作
 * - 提供事务内写入方法(insertWithStore / updateWithStore / deleteByWorldWithStore 等)
 * - 行对象转换(TEXT ↔ 枚举、NULL ↔ undefined、时间戳保持 number)
 *
 * 不负责:
 * - 跨表业务验证(见 W-SCENE-1B WorldSceneService)
 * - "同一地点最多一个 Active 场景"业务锁
 * - 场景生命周期管理(startScene / endScene)
 * - 参与者验证、角色移动保护、运行锁
 *
 * 规则:
 * - listByWorld / listByLocation 按 startedAt ASC 排序
 * - listByStatus 按 startedAt ASC 排序
 * - findActiveByWorldAndLocation 返回该 World+Location 下的 Active 场景(理论上最多一个)
 * - update 不存在返回 NotFound
 * - 未知 status 抛 InvalidData
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldScene, WorldSceneStatus, isWorldSceneStatus } from '../../models/world/WorldScene';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_SCENES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_LOCATION_ID,
  COLUMN_SCENE_TITLE,
  COLUMN_STATUS,
  COLUMN_STARTED_AT,
  COLUMN_ENDED_AT,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldSceneRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldScene | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldScene.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  /**
   * 在事务内按 id 加载场景(由调用方持有 store 和事务)。
   */
  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldScene | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldScene.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return sceneFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 World 的全部场景,按 startedAt ASC 排序。
   */
  async listByWorld(worldId: string): Promise<WorldScene[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldScene.listByWorld: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.orderByAsc(COLUMN_STARTED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldScene[] = [];
      while (rs.goToNextRow()) {
        list.push(sceneFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 Location 的全部场景,按 startedAt ASC 排序。
   */
  async listByLocation(locationId: string): Promise<WorldScene[]> {
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldScene.listByLocation: locationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_LOCATION_ID, locationId);
    predicates.orderByAsc(COLUMN_STARTED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldScene[] = [];
      while (rs.goToNextRow()) {
        list.push(sceneFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 World 内某状态的全部场景,按 startedAt ASC 排序。
   */
  async listByStatus(worldId: string, status: WorldSceneStatus): Promise<WorldScene[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldScene.listByStatus: worldId empty');
    }
    if (!isWorldSceneStatus(status)) {
      throw DatabaseError.invalidData(`WorldScene.listByStatus: status invalid: ${status}`);
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_STATUS, status);
    predicates.orderByAsc(COLUMN_STARTED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldScene[] = [];
      while (rs.goToNextRow()) {
        list.push(sceneFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 查找指定 World+Location 下的 Active 场景。
   * 理论上最多一个(由 W-SCENE-1B WorldSceneService 保证),本 Repository 不做业务锁。
   */
  async findActiveByWorldAndLocation(
    worldId: string,
    locationId: string
  ): Promise<WorldScene | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldScene.findActiveByWorldAndLocation: worldId empty');
    }
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldScene.findActiveByWorldAndLocation: locationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.findActiveByWorldAndLocationWithStore(store, worldId, locationId);
  }

  /**
   * 在事务内查找指定 World+Location 下的 Active 场景(由调用方持有 store 和事务)。
   */
  async findActiveByWorldAndLocationWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    locationId: string
  ): Promise<WorldScene | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldScene.findActiveByWorldAndLocationWithStore: worldId empty');
    }
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldScene.findActiveByWorldAndLocationWithStore: locationId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_LOCATION_ID, locationId);
    predicates.equalTo(COLUMN_STATUS, WorldSceneStatus.Active);
    predicates.orderByAsc(COLUMN_STARTED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return sceneFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async countByWorld(worldId: string): Promise<number> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldScene.countByWorld: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.countByWorldWithStore(store, worldId);
  }

  async countByWorldWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<number> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldScene.countByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
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

  async countByLocation(locationId: string): Promise<number> {
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldScene.countByLocation: locationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.countByLocationWithStore(store, locationId);
  }

  /**
   * 在事务内统计指定 Location 的场景数量(Active + Ended,由调用方持有 store 和事务)。
   * 用于 W-SCENE-1A WorldStateService.deleteLocation 删除保护。
   */
  async countByLocationWithStore(
    store: relationalStore.RdbStore,
    locationId: string
  ): Promise<number> {
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldScene.countByLocationWithStore: locationId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_LOCATION_ID, locationId);
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

  async insert(scene: WorldScene): Promise<void> {
    this.validateScene(scene);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_SCENES, sceneToBucket(scene));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldScene.insert');
      }
      throw DatabaseError.queryFailed(`WorldScene.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, scene: WorldScene): Promise<void> {
    this.validateScene(scene);
    try {
      await store.insert(TABLE_WORLD_SCENES, sceneToBucket(scene));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldScene.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldScene.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(scene: WorldScene): Promise<void> {
    this.validateScene(scene);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_ID, scene.id);
    let affected: number;
    try {
      affected = await store.update(sceneToBucket(scene), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldScene.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldScene.update');
    }
  }

  async updateWithStore(store: relationalStore.RdbStore, scene: WorldScene): Promise<void> {
    this.validateScene(scene);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_ID, scene.id);
    let affected: number;
    try {
      affected = await store.update(sceneToBucket(scene), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldScene.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldScene.updateWithStore');
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldScene.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldScene.deleteById: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldScene.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldScene.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除指定 World 的全部场景行。
   * - 由调用方持有 store 和事务
   * - 幂等:不存在返回 0,不抛错
   * - 不级联删除 world_scene_messages(由 Service 负责编排删除顺序)
   */
  async deleteByWorldWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldScene.deleteByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldScene.deleteByWorldWithStore: ${extractCauseMessage(err)}`);
    }
  }

  private validateScene(scene: WorldScene): void {
    if (scene.id === '') {
      throw DatabaseError.invalidData('WorldScene.id empty');
    }
    if (scene.worldId === '') {
      throw DatabaseError.invalidData('WorldScene.worldId empty');
    }
    if (scene.locationId === '') {
      throw DatabaseError.invalidData('WorldScene.locationId empty');
    }
    if (!isWorldSceneStatus(scene.status)) {
      throw DatabaseError.invalidData(`WorldScene.status invalid: ${scene.status}`);
    }
    if (!isValidTimestamp(scene.startedAt)) {
      throw DatabaseError.invalidData('WorldScene.startedAt invalid');
    }
    if (scene.endedAt !== undefined && !isValidTimestamp(scene.endedAt)) {
      throw DatabaseError.invalidData('WorldScene.endedAt invalid');
    }
    if (!isValidTimestamp(scene.createdAt)) {
      throw DatabaseError.invalidData('WorldScene.createdAt invalid');
    }
    if (!isValidTimestamp(scene.updatedAt)) {
      throw DatabaseError.invalidData('WorldScene.updatedAt invalid');
    }
  }
}

function sceneToBucket(scene: WorldScene): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = scene.id;
  bucket[COLUMN_WORLD_ID] = scene.worldId;
  bucket[COLUMN_LOCATION_ID] = scene.locationId;
  bucket[COLUMN_SCENE_TITLE] = scene.title;
  bucket[COLUMN_STATUS] = scene.status;
  bucket[COLUMN_STARTED_AT] = scene.startedAt;
  bucket[COLUMN_ENDED_AT] = scene.endedAt !== undefined ? scene.endedAt : null;
  bucket[COLUMN_CREATED_AT] = scene.createdAt;
  bucket[COLUMN_UPDATED_AT] = scene.updatedAt;
  return bucket;
}

function readOptionalLong(rs: relationalStore.ResultSet, columnName: string): number | undefined {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return undefined;
  }
  if (rs.isColumnNull(col)) {
    return undefined;
  }
  return rs.getLong(col);
}

function readOptionalString(rs: relationalStore.ResultSet, columnName: string): string | undefined {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return undefined;
  }
  if (rs.isColumnNull(col)) {
    return undefined;
  }
  return rs.getString(col);
}

function readStringWithDefault(rs: relationalStore.ResultSet, columnName: string, defaultValue: string): string {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return defaultValue;
  }
  if (rs.isColumnNull(col)) {
    return defaultValue;
  }
  const value: string = rs.getString(col);
  return value;
}

function sceneFromRow(rs: relationalStore.ResultSet): WorldScene {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldScene.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldScene.worldId empty in row');
  }
  const locationId: string = rs.getString(rs.getColumnIndex(COLUMN_LOCATION_ID));
  if (locationId === '') {
    throw DatabaseError.invalidData('WorldScene.locationId empty in row');
  }
  const title: string = readStringWithDefault(rs, COLUMN_SCENE_TITLE, '');
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  if (!isWorldSceneStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldScene.status invalid in row: ${statusRaw}`);
  }
  const startedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_STARTED_AT));
  if (!isValidTimestamp(startedAt)) {
    throw DatabaseError.invalidData('WorldScene.startedAt invalid in row');
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldScene.createdAt invalid in row');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('WorldScene.updatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    locationId: locationId,
    title: title !== undefined ? title : '',
    status: statusRaw as WorldSceneStatus,
    startedAt: startedAt,
    endedAt: readOptionalLong(rs, COLUMN_ENDED_AT),
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
