/**
 * WorldCharacterInstanceRepository
 *
 * 职责(W-DATA-1A):
 * - world_character_instances 表的 CRUD 操作
 * - 提供事务内写入方法(insertWithStore / updateWithStore / deleteByWorldWithStore)
 * - 行对象转换(INTEGER 0/1 ↔ boolean、NULL ↔ undefined、时间戳保持 number)
 *
 * 不负责:
 * - 跨表业务验证(见 W-DATA-1B WorldStateService)
 * - 验证 Character 存在(由 Service 调用 CharacterService.getById)
 * - 验证地点属于同一 World
 * - Character 删除引用保护(本阶段不得修改 CharacterService.delete)
 *
 * 规则:
 * - listByWorld / listByLocation 按 createdAt ASC
 * - findByWorldAndCharacter 精确匹配(world_id, character_id)
 * - 唯一约束(world_id, character_id)冲突映射为 AlreadyExists
 * - update 不存在返回 NotFound
 * - currentLocationId 可空(NULL ↔ undefined)
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_CHARACTER_INSTANCES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_CHARACTER_ID,
  COLUMN_DISPLAY_NAME_SNAPSHOT,
  COLUMN_CURRENT_LOCATION_ID,
  COLUMN_IS_ACTIVE,
  COLUMN_CURRENT_GOAL,
  COLUMN_MAP_ICON_STYLE,
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

export class WorldCharacterInstanceRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldCharacterInstance | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  /**
   * 在事务内按 id 加载角色实例(由调用方持有 store 和事务)。
   * 用于 W-DATA-1B WorldStateService 在同一事务内读取实例状态后再决策。
   */
  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldCharacterInstance | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return instanceFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 World 的全部角色实例,按 createdAt ASC 排序。
   */
  async listByWorld(worldId: string): Promise<WorldCharacterInstance[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.listByWorld: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldCharacterInstance[] = [];
      while (rs.goToNextRow()) {
        list.push(instanceFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 World 内位于指定地点的全部角色实例,按 createdAt ASC 排序。
   */
  async listByLocation(worldId: string, locationId: string): Promise<WorldCharacterInstance[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.listByLocation: worldId empty');
    }
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.listByLocation: locationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listByLocationWithStore(store, worldId, locationId);
  }

  /**
   * 在事务内列出指定 World 内位于指定地点的全部角色实例,按 createdAt ASC 排序。
   * 用于 W-DATA-1B 归档/删除地点前校验是否有角色位于其中(由 Service 过滤 active)。
   */
  async listByLocationWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    locationId: string
  ): Promise<WorldCharacterInstance[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.listByLocationWithStore: worldId empty');
    }
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.listByLocationWithStore: locationId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CURRENT_LOCATION_ID, locationId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldCharacterInstance[] = [];
      while (rs.goToNextRow()) {
        list.push(instanceFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 精确查找(world_id, character_id)。
   */
  async findByWorldAndCharacter(
    worldId: string,
    characterId: string
  ): Promise<WorldCharacterInstance | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.findByWorldAndCharacter: worldId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.findByWorldAndCharacter: characterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.findByWorldAndCharacterWithStore(store, worldId, characterId);
  }

  /**
   * 在事务内精确查找(world_id, character_id)。
   * 用于 W-DATA-1B 添加角色到世界前在同一事务内做唯一性校验。
   */
  async findByWorldAndCharacterWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    characterId: string
  ): Promise<WorldCharacterInstance | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.findByWorldAndCharacterWithStore: worldId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.findByWorldAndCharacterWithStore: characterId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CHARACTER_ID, characterId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return instanceFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 统计引用指定 Character 的角色实例数量(跨全部 World)。
   * 用于 W-DATA-1B 角色删除引用保护。
   */
  async countByCharacterId(characterId: string): Promise<number> {
    if (characterId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.countByCharacterId: characterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.countByCharacterIdWithStore(store, characterId);
  }

  /**
   * 在事务内统计引用指定 Character 的角色实例数量(跨全部 World)。
   * 用于 W-DATA-1B CharacterService.remove 在删除引用检查时保持一致性读。
   */
  async countByCharacterIdWithStore(
    store: relationalStore.RdbStore,
    characterId: string
  ): Promise<number> {
    if (characterId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.countByCharacterIdWithStore: characterId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_CHARACTER_ID, characterId);
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
   * 统计指定地点上的角色实例数量(跨全部 World,不限定 World)。
   */
  async countByCurrentLocation(locationId: string): Promise<number> {
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.countByCurrentLocation: locationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.countByCurrentLocationWithStore(store, locationId);
  }

  /**
   * 在事务内统计指定地点上的角色实例数量(跨全部 World)。
   * 用于 W-DATA-1B 归档/删除地点前校验是否有角色位于其中。
   */
  async countByCurrentLocationWithStore(
    store: relationalStore.RdbStore,
    locationId: string
  ): Promise<number> {
    if (locationId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.countByCurrentLocationWithStore: locationId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_CURRENT_LOCATION_ID, locationId);
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

  async insert(instance: WorldCharacterInstance): Promise<void> {
    this.validateInstance(instance);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_CHARACTER_INSTANCES, instanceToBucket(instance));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldCharacterInstance.insert');
      }
      throw DatabaseError.queryFailed(`WorldCharacterInstance.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    instance: WorldCharacterInstance
  ): Promise<void> {
    this.validateInstance(instance);
    try {
      await store.insert(TABLE_WORLD_CHARACTER_INSTANCES, instanceToBucket(instance));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldCharacterInstance.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldCharacterInstance.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(instance: WorldCharacterInstance): Promise<void> {
    this.validateInstance(instance);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_ID, instance.id);
    let affected: number;
    try {
      affected = await store.update(instanceToBucket(instance), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldCharacterInstance.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldCharacterInstance.update');
    }
  }

  async updateWithStore(
    store: relationalStore.RdbStore,
    instance: WorldCharacterInstance
  ): Promise<void> {
    this.validateInstance(instance);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_ID, instance.id);
    let affected: number;
    try {
      affected = await store.update(instanceToBucket(instance), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldCharacterInstance.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldCharacterInstance.updateWithStore');
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldCharacterInstance.deleteById: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldCharacterInstance.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在事务内删除指定 World 的全部角色实例。
   * - 幂等:不存在返回 0,不抛错
   */
  async deleteByWorldWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.deleteByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldCharacterInstance.deleteByWorldWithStore: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 判断(world_id, character_id)是否已存在实例。
   */
  async existsByWorldAndCharacter(worldId: string, characterId: string): Promise<boolean> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.existsByWorldAndCharacter: worldId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.existsByWorldAndCharacter: characterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_INSTANCES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CHARACTER_ID, characterId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.goToFirstRow();
    } finally {
      rs.close();
    }
  }

  private validateInstance(instance: WorldCharacterInstance): void {
    if (instance.id === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.id empty');
    }
    if (instance.worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.worldId empty');
    }
    if (instance.characterId === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.characterId empty');
    }
    if (instance.displayNameSnapshot === '') {
      throw DatabaseError.invalidData('WorldCharacterInstance.displayNameSnapshot empty');
    }
    if (!isValidTimestamp(instance.createdAt)) {
      throw DatabaseError.invalidData('WorldCharacterInstance.createdAt invalid');
    }
    if (!isValidTimestamp(instance.updatedAt)) {
      throw DatabaseError.invalidData('WorldCharacterInstance.updatedAt invalid');
    }
  }
}

function instanceToBucket(instance: WorldCharacterInstance): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = instance.id;
  bucket[COLUMN_WORLD_ID] = instance.worldId;
  bucket[COLUMN_CHARACTER_ID] = instance.characterId;
  bucket[COLUMN_DISPLAY_NAME_SNAPSHOT] = instance.displayNameSnapshot;
  bucket[COLUMN_CURRENT_LOCATION_ID] = instance.currentLocationId !== undefined
    ? instance.currentLocationId
    : null;
  bucket[COLUMN_IS_ACTIVE] = booleanToInt(instance.isActive);
  bucket[COLUMN_CURRENT_GOAL] = instance.currentGoal;
  bucket[COLUMN_MAP_ICON_STYLE] = instance.mapIconStyle !== undefined
    ? instance.mapIconStyle
    : null;
  bucket[COLUMN_CREATED_AT] = instance.createdAt;
  bucket[COLUMN_UPDATED_AT] = instance.updatedAt;
  return bucket;
}

function instanceFromRow(rs: relationalStore.ResultSet): WorldCharacterInstance {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldCharacterInstance.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldCharacterInstance.worldId empty in row');
  }
  const characterId: string = rs.getString(rs.getColumnIndex(COLUMN_CHARACTER_ID));
  if (characterId === '') {
    throw DatabaseError.invalidData('WorldCharacterInstance.characterId empty in row');
  }
  const displayNameSnapshot: string = rs.getString(rs.getColumnIndex(COLUMN_DISPLAY_NAME_SNAPSHOT));
  if (displayNameSnapshot === '') {
    throw DatabaseError.invalidData('WorldCharacterInstance.displayNameSnapshot empty in row');
  }
  // currentLocationId 可空:NULL → undefined
  const locationCol: number = rs.getColumnIndex(COLUMN_CURRENT_LOCATION_ID);
  let currentLocationId: string | undefined;
  if (locationCol >= 0 && !rs.isColumnNull(locationCol)) {
    const locationValue: string = rs.getString(locationCol);
    if (locationValue !== '') {
      currentLocationId = locationValue;
    }
  }
  const isActive: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_IS_ACTIVE)));
  const goalCol: number = rs.getColumnIndex(COLUMN_CURRENT_GOAL);
  const currentGoal: string = goalCol >= 0 && !rs.isColumnNull(goalCol)
    ? rs.getString(goalCol) : '';
  const iconCol: number = rs.getColumnIndex(COLUMN_MAP_ICON_STYLE);
  let mapIconStyle: string | undefined;
  if (iconCol >= 0 && !rs.isColumnNull(iconCol)) {
    const iconValue: string = rs.getString(iconCol);
    if (iconValue !== '') {
      mapIconStyle = iconValue;
    }
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldCharacterInstance.createdAt invalid in row');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('WorldCharacterInstance.updatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    characterId: characterId,
    displayNameSnapshot: displayNameSnapshot,
    currentLocationId: currentLocationId,
    isActive: isActive,
    currentGoal: currentGoal,
    mapIconStyle: mapIconStyle,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
