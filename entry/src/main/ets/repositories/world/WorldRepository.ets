/**
 * WorldRepository
 *
 * 职责(W-DATA-1A):
 * - worlds 表的 CRUD 操作
 * - 提供事务内写入方法(insertWithStore / updateWithStore / deleteByIdWithStore)
 * - 行对象转换(INTEGER 0/1 ↔ boolean、TEXT ↔ 枚举、NULL ↔ undefined、时间戳保持 number)
 *
 * 不负责:
 * - 跨表业务验证(见 W-DATA-1B WorldStateService)
 * - 角色是否存在 / 地点是否属于世界 / 是否允许移动
 * - 地点删除保护 / 边反向冲突 / Character 删除保护
 * - 事件与状态写入同一事务编排
 * - 级联删除(普通 deleteById 不偷偷级联其他表)
 *
 * 规则:
 * - 列表默认按 updatedAt DESC
 * - 写入校验:id / name 非空,status 合法,createdAt / updatedAt 合法
 * - 唯一约束冲突映射为 AlreadyExists
 * - update 不存在返回 NotFound
 * - 未知 status 抛 InvalidData,不静默解释为其他状态
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { World, WorldStatus, isWorldStatus } from '../../models/world/World';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLDS,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_DESCRIPTION,
  COLUMN_STATUS,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<World | null> {
    if (id === '') {
      throw DatabaseError.invalidData('World.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return worldFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 列出全部 World,按 updatedAt DESC 排序。
   */
  async listAll(): Promise<World[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: World[] = [];
      while (rs.goToNextRow()) {
        list.push(worldFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async insert(world: World): Promise<void> {
    this.validateWorld(world);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLDS, worldToBucket(world));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('World.insert');
      }
      throw DatabaseError.queryFailed(`World.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, world: World): Promise<void> {
    this.validateWorld(world);
    try {
      await store.insert(TABLE_WORLDS, worldToBucket(world));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('World.insertWithStore');
      }
      throw DatabaseError.queryFailed(`World.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(world: World): Promise<void> {
    this.validateWorld(world);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_ID, world.id);
    let affected: number;
    try {
      affected = await store.update(worldToBucket(world), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`World.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('World.update');
    }
  }

  async updateWithStore(store: relationalStore.RdbStore, world: World): Promise<void> {
    this.validateWorld(world);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_ID, world.id);
    let affected: number;
    try {
      affected = await store.update(worldToBucket(world), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`World.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('World.updateWithStore');
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('World.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`World.deleteById: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('World.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`World.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async exists(id: string): Promise<boolean> {
    if (id === '') {
      throw DatabaseError.invalidData('World.exists: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.goToFirstRow();
    } finally {
      rs.close();
    }
  }

  private validateWorld(world: World): void {
    if (world.id === '') {
      throw DatabaseError.invalidData('World.id empty');
    }
    if (world.name === '') {
      throw DatabaseError.invalidData('World.name empty');
    }
    if (!isWorldStatus(world.status)) {
      throw DatabaseError.invalidData(`World.status invalid: ${world.status}`);
    }
    if (!isValidTimestamp(world.createdAt)) {
      throw DatabaseError.invalidData('World.createdAt invalid');
    }
    if (!isValidTimestamp(world.updatedAt)) {
      throw DatabaseError.invalidData('World.updatedAt invalid');
    }
  }
}

function worldToBucket(world: World): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = world.id;
  bucket[COLUMN_NAME] = world.name;
  bucket[COLUMN_DESCRIPTION] = world.description;
  bucket[COLUMN_STATUS] = world.status;
  bucket[COLUMN_CREATED_AT] = world.createdAt;
  bucket[COLUMN_UPDATED_AT] = world.updatedAt;
  return bucket;
}

function worldFromRow(rs: relationalStore.ResultSet): World {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('World.id empty in row');
  }
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_NAME));
  if (name === '') {
    throw DatabaseError.invalidData('World.name empty in row');
  }
  const description: string = rs.getString(rs.getColumnIndex(COLUMN_DESCRIPTION));
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  if (!isWorldStatus(statusRaw)) {
    throw DatabaseError.invalidData(`World.status invalid in row: ${statusRaw}`);
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('World.createdAt invalid in row');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('World.updatedAt invalid in row');
  }
  return {
    id: id,
    name: name,
    description: description,
    status: statusRaw as WorldStatus,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
