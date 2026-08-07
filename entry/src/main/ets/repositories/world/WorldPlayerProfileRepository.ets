import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldPlayerProfile } from '../../models/world/WorldPlayerProfile';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_PLAYER_PROFILES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_DISPLAY_NAME,
  COLUMN_PERSONA,
  COLUMN_PUBLIC_IDENTITY,
  COLUMN_PRIVATE_IDENTITY,
  COLUMN_CURRENT_LOCATION_ID,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldPlayerProfileRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldPlayerProfile | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldPlayerProfile | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_PLAYER_PROFILES);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return profileFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async getByWorldId(worldId: string): Promise<WorldPlayerProfile | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.getByWorldId: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByWorldIdWithStore(store, worldId);
  }

  async getByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<WorldPlayerProfile | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.getByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_PLAYER_PROFILES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return profileFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async insert(profile: WorldPlayerProfile): Promise<void> {
    this.validateProfile(profile);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_PLAYER_PROFILES, profileToBucket(profile));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldPlayerProfile.insert');
      }
      throw DatabaseError.queryFailed(`WorldPlayerProfile.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, profile: WorldPlayerProfile): Promise<void> {
    this.validateProfile(profile);
    try {
      await store.insert(TABLE_WORLD_PLAYER_PROFILES, profileToBucket(profile));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldPlayerProfile.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldPlayerProfile.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(profile: WorldPlayerProfile): Promise<void> {
    this.validateProfile(profile);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_PLAYER_PROFILES);
    predicates.equalTo(COLUMN_ID, profile.id);
    let affected: number;
    try {
      affected = await store.update(profileToBucket(profile), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldPlayerProfile.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldPlayerProfile.update');
    }
  }

  async updateWithStore(store: relationalStore.RdbStore, profile: WorldPlayerProfile): Promise<void> {
    this.validateProfile(profile);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_PLAYER_PROFILES);
    predicates.equalTo(COLUMN_ID, profile.id);
    let affected: number;
    try {
      affected = await store.update(profileToBucket(profile), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldPlayerProfile.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldPlayerProfile.updateWithStore');
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_PLAYER_PROFILES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldPlayerProfile.deleteById: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_PLAYER_PROFILES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldPlayerProfile.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByWorldId(worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.deleteByWorldId: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.deleteByWorldIdWithStore(store, worldId);
  }

  async deleteByWorldIdWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_PLAYER_PROFILES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldPlayerProfile.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  private validateProfile(profile: WorldPlayerProfile): void {
    if (profile.id === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.id empty');
    }
    if (profile.worldId === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.worldId empty');
    }
    if (profile.displayName.trim() === '') {
      throw DatabaseError.invalidData('WorldPlayerProfile.displayName empty after trim');
    }
    if (!isValidTimestamp(profile.createdAt)) {
      throw DatabaseError.invalidData('WorldPlayerProfile.createdAt invalid');
    }
    if (!isValidTimestamp(profile.updatedAt)) {
      throw DatabaseError.invalidData('WorldPlayerProfile.updatedAt invalid');
    }
  }
}

function profileToBucket(profile: WorldPlayerProfile): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = profile.id;
  bucket[COLUMN_WORLD_ID] = profile.worldId;
  bucket[COLUMN_DISPLAY_NAME] = profile.displayName;
  bucket[COLUMN_PERSONA] = profile.persona;
  bucket[COLUMN_PUBLIC_IDENTITY] = profile.publicIdentity;
  bucket[COLUMN_PRIVATE_IDENTITY] = profile.privateIdentity;
  bucket[COLUMN_CURRENT_LOCATION_ID] = profile.currentLocationId !== undefined
    ? profile.currentLocationId
    : null;
  bucket[COLUMN_CREATED_AT] = profile.createdAt;
  bucket[COLUMN_UPDATED_AT] = profile.updatedAt;
  return bucket;
}

function profileFromRow(rs: relationalStore.ResultSet): WorldPlayerProfile {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldPlayerProfile.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldPlayerProfile.worldId empty in row');
  }
  const displayName: string = rs.getString(rs.getColumnIndex(COLUMN_DISPLAY_NAME));
  if (displayName.trim() === '') {
    throw DatabaseError.invalidData('WorldPlayerProfile.displayName empty in row');
  }
  const personaCol: number = rs.getColumnIndex(COLUMN_PERSONA);
  const persona: string = personaCol >= 0 && !rs.isColumnNull(personaCol)
    ? rs.getString(personaCol) : '';
  const publicCol: number = rs.getColumnIndex(COLUMN_PUBLIC_IDENTITY);
  const publicIdentity: string = publicCol >= 0 && !rs.isColumnNull(publicCol)
    ? rs.getString(publicCol) : '';
  const privateCol: number = rs.getColumnIndex(COLUMN_PRIVATE_IDENTITY);
  const privateIdentity: string = privateCol >= 0 && !rs.isColumnNull(privateCol)
    ? rs.getString(privateCol) : '';
  const locCol: number = rs.getColumnIndex(COLUMN_CURRENT_LOCATION_ID);
  let currentLocationId: string | undefined;
  if (locCol >= 0 && !rs.isColumnNull(locCol)) {
    const locValue: string = rs.getString(locCol);
    if (locValue !== '') {
      currentLocationId = locValue;
    }
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldPlayerProfile.createdAt invalid in row');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('WorldPlayerProfile.updatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    displayName: displayName,
    persona: persona,
    publicIdentity: publicIdentity,
    privateIdentity: privateIdentity,
    currentLocationId: currentLocationId,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
