/**
 * WorldMapBackgroundRepository 世界地图背景图仓储(W2A3-WORLD-MAP-BACKGROUND)
 *
 * 职责:
 * - 按世界查询背景图(一个世界最多一张)
 * - upsert / update / delete
 *
 * 只做数据库读写,不包含图片文件管理。
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  TABLE_WORLD_MAP_BACKGROUNDS,
  COLUMN_ID,
  COLUMN_WORLD_ID_WMB,
  COLUMN_IMAGE_URI_WMB,
  COLUMN_IMAGE_WIDTH_WMB,
  COLUMN_IMAGE_HEIGHT_WMB,
  COLUMN_ROTATION_WMB,
  COLUMN_FIT_SCALE_WMB,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import { WorldMapBackground } from '../../models/world/WorldMapBackground';
import { DatabaseError } from '../../models/DatabaseError';
import {
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldMapBackgroundRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getByWorldId(worldId: string): Promise<WorldMapBackground | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldMapBackground.getByWorldId: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByWorldIdWithStore(store, worldId);
  }

  async getByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<WorldMapBackground | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldMapBackground.getByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MAP_BACKGROUNDS);
    predicates.equalTo(COLUMN_WORLD_ID_WMB, worldId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return backgroundFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async upsertWithStore(store: relationalStore.RdbStore, background: WorldMapBackground): Promise<void> {
    this.validateBackground(background);
    const existing: WorldMapBackground | null =
      await this.getByWorldIdWithStore(store, background.worldId);
    if (existing !== null) {
      const updateBucket: relationalStore.ValuesBucket = {};
      updateBucket[COLUMN_ID] = existing.id;
      updateBucket[COLUMN_WORLD_ID_WMB] = background.worldId;
      updateBucket[COLUMN_IMAGE_URI_WMB] = background.imageUri;
      updateBucket[COLUMN_IMAGE_WIDTH_WMB] = background.imageWidth;
      updateBucket[COLUMN_IMAGE_HEIGHT_WMB] = background.imageHeight;
      updateBucket[COLUMN_ROTATION_WMB] = background.rotation;
      updateBucket[COLUMN_FIT_SCALE_WMB] = background.fitScale;
      updateBucket[COLUMN_CREATED_AT] = existing.createdAt;
      updateBucket[COLUMN_UPDATED_AT] = background.updatedAt;
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_WORLD_MAP_BACKGROUNDS);
      predicates.equalTo(COLUMN_ID, existing.id);
      try {
        await store.update(updateBucket, predicates);
      } catch (err) {
        throw DatabaseError.queryFailed(`WorldMapBackground.upsertWithStore update: ${extractCauseMessage(err)}`);
      }
    } else {
      try {
        await store.insert(TABLE_WORLD_MAP_BACKGROUNDS, backgroundToBucket(background));
      } catch (err) {
        if (isConstraintViolation(err)) {
          throw DatabaseError.alreadyExists('WorldMapBackground.upsertWithStore insert');
        }
        throw DatabaseError.queryFailed(`WorldMapBackground.upsertWithStore insert: ${extractCauseMessage(err)}`);
      }
    }
  }

  async update(background: WorldMapBackground): Promise<void> {
    this.validateBackground(background);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MAP_BACKGROUNDS);
    predicates.equalTo(COLUMN_ID, background.id);
    let affected: number;
    try {
      affected = await store.update(backgroundToBucket(background), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldMapBackground.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldMapBackground.update');
    }
  }

  async updateWithStore(store: relationalStore.RdbStore, background: WorldMapBackground): Promise<void> {
    this.validateBackground(background);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MAP_BACKGROUNDS);
    predicates.equalTo(COLUMN_ID, background.id);
    let affected: number;
    try {
      affected = await store.update(backgroundToBucket(background), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldMapBackground.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldMapBackground.updateWithStore');
    }
  }

  async deleteByWorldId(worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldMapBackground.deleteByWorldId: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MAP_BACKGROUNDS);
    predicates.equalTo(COLUMN_WORLD_ID_WMB, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldMapBackground.deleteByWorldId: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByWorldIdWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldMapBackground.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MAP_BACKGROUNDS);
    predicates.equalTo(COLUMN_WORLD_ID_WMB, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldMapBackground.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  private validateBackground(background: WorldMapBackground): void {
    if (background.id === '') {
      throw DatabaseError.invalidData('WorldMapBackground.id empty');
    }
    if (background.worldId === '') {
      throw DatabaseError.invalidData('WorldMapBackground.worldId empty');
    }
    if (background.imageUri === '') {
      throw DatabaseError.invalidData('WorldMapBackground.imageUri empty');
    }
    if (!Number.isFinite(background.imageWidth) || background.imageWidth <= 0) {
      throw DatabaseError.invalidData('WorldMapBackground.imageWidth invalid');
    }
    if (!Number.isFinite(background.imageHeight) || background.imageHeight <= 0) {
      throw DatabaseError.invalidData('WorldMapBackground.imageHeight invalid');
    }
    if (!Number.isFinite(background.rotation)) {
      throw DatabaseError.invalidData('WorldMapBackground.rotation invalid');
    }
    if (!Number.isFinite(background.fitScale) || background.fitScale <= 0) {
      throw DatabaseError.invalidData('WorldMapBackground.fitScale invalid');
    }
    if (!Number.isFinite(background.createdAt)) {
      throw DatabaseError.invalidData('WorldMapBackground.createdAt invalid');
    }
    if (!Number.isFinite(background.updatedAt)) {
      throw DatabaseError.invalidData('WorldMapBackground.updatedAt invalid');
    }
  }
}

function backgroundToBucket(background: WorldMapBackground): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = background.id;
  bucket[COLUMN_WORLD_ID_WMB] = background.worldId;
  bucket[COLUMN_IMAGE_URI_WMB] = background.imageUri;
  bucket[COLUMN_IMAGE_WIDTH_WMB] = background.imageWidth;
  bucket[COLUMN_IMAGE_HEIGHT_WMB] = background.imageHeight;
  bucket[COLUMN_ROTATION_WMB] = background.rotation;
  bucket[COLUMN_FIT_SCALE_WMB] = background.fitScale;
  bucket[COLUMN_CREATED_AT] = background.createdAt;
  bucket[COLUMN_UPDATED_AT] = background.updatedAt;
  return bucket;
}

function backgroundFromRow(rs: relationalStore.ResultSet): WorldMapBackground {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID_WMB));
  const imageUri: string = rs.getString(rs.getColumnIndex(COLUMN_IMAGE_URI_WMB));
  const imageWidth: number = rs.getLong(rs.getColumnIndex(COLUMN_IMAGE_WIDTH_WMB));
  const imageHeight: number = rs.getLong(rs.getColumnIndex(COLUMN_IMAGE_HEIGHT_WMB));
  const rotation: number = rs.getDouble(rs.getColumnIndex(COLUMN_ROTATION_WMB));
  const fitScale: number = rs.getDouble(rs.getColumnIndex(COLUMN_FIT_SCALE_WMB));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (id === '') {
    throw DatabaseError.invalidData('WorldMapBackground.id empty in row');
  }
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldMapBackground.worldId empty in row');
  }
  if (imageUri === '') {
    throw DatabaseError.invalidData('WorldMapBackground.imageUri empty in row');
  }
  if (!Number.isFinite(imageWidth) || imageWidth <= 0) {
    throw DatabaseError.invalidData('WorldMapBackground.imageWidth invalid in row');
  }
  if (!Number.isFinite(imageHeight) || imageHeight <= 0) {
    throw DatabaseError.invalidData('WorldMapBackground.imageHeight invalid in row');
  }
  if (!Number.isFinite(rotation)) {
    throw DatabaseError.invalidData('WorldMapBackground.rotation invalid in row');
  }
  if (!Number.isFinite(fitScale) || fitScale <= 0) {
    throw DatabaseError.invalidData('WorldMapBackground.fitScale invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    imageUri: imageUri,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    rotation: rotation,
    fitScale: fitScale,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
