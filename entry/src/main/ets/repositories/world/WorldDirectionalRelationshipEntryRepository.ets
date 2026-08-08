import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldDirectionalRelationshipEntry,
  WorldDirectionalRelationshipEntryStatus,
  isWorldDirectionalRelationshipEntryStatus
} from '../../models/world/WorldDirectionalRelationshipEntry';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_OWNER_CHARACTER_INSTANCE_ID_WDRE,
  COLUMN_TARGET_CHARACTER_INSTANCE_ID_WDRE,
  COLUMN_VERSION_WDRE,
  COLUMN_RELATIONSHIP_TEXT,
  COLUMN_SOURCE_SCENE_ID_WDRE,
  COLUMN_SOURCE_SESSION_ID_WDRE,
  COLUMN_SOURCE_LOCATION_ID_WDRE,
  COLUMN_EVIDENCE_MESSAGE_IDS_JSON_WDRE,
  COLUMN_OWNER_DISPLAY_NAME_SNAPSHOT_WDRE,
  COLUMN_TARGET_DISPLAY_NAME_SNAPSHOT_WDRE,
  COLUMN_PROMPT_VERSION,
  COLUMN_PROVIDER_ID_WDRE,
  COLUMN_MODEL_ID_WDRE,
  COLUMN_SUPERSEDES_RELATIONSHIP_ID,
  COLUMN_STATUS_WDRE,
  COLUMN_CREATED_AT,
  COLUMN_STATUS_UPDATED_AT_WDRE,
  COLUMN_CONFIDENCE
} from '../../database/DatabaseConstants';
import {
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldDirectionalRelationshipEntryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    id: string
  ): Promise<WorldDirectionalRelationshipEntry | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.getByIdWithStore: worldId empty');
    }
    if (id === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return entryFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async getActiveForPairWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string
  ): Promise<WorldDirectionalRelationshipEntry | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.getActiveForPairWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.getActiveForPairWithStore: owner empty');
    }
    if (targetCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.getActiveForPairWithStore: target empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WDRE, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_TARGET_CHARACTER_INSTANCE_ID_WDRE, targetCharacterInstanceId);
    predicates.equalTo(COLUMN_STATUS_WDRE, WorldDirectionalRelationshipEntryStatus.Active);
    predicates.orderByDesc(COLUMN_VERSION_WDRE);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return entryFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listActiveByOwnerWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string
  ): Promise<WorldDirectionalRelationshipEntry[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.listActiveByOwnerWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.listActiveByOwnerWithStore: owner empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WDRE, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_STATUS_WDRE, WorldDirectionalRelationshipEntryStatus.Active);
    predicates.orderByAsc(COLUMN_TARGET_CHARACTER_INSTANCE_ID_WDRE);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldDirectionalRelationshipEntry[] = [];
      while (rs.goToNextRow()) {
        list.push(entryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async listHistoricalForPairWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string
  ): Promise<WorldDirectionalRelationshipEntry[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.listHistoricalForPairWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.listHistoricalForPairWithStore: owner empty');
    }
    if (targetCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.listHistoricalForPairWithStore: target empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WDRE, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_TARGET_CHARACTER_INSTANCE_ID_WDRE, targetCharacterInstanceId);
    predicates.orderByDesc(COLUMN_VERSION_WDRE);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldDirectionalRelationshipEntry[] = [];
      while (rs.goToNextRow()) {
        list.push(entryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async getNextVersionForPairWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string
  ): Promise<number> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.getNextVersionForPairWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.getNextVersionForPairWithStore: owner empty');
    }
    if (targetCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.getNextVersionForPairWithStore: target empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WDRE, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_TARGET_CHARACTER_INSTANCE_ID_WDRE, targetCharacterInstanceId);
    predicates.orderByDesc(COLUMN_VERSION_WDRE);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return 1;
      }
      return rs.getLong(rs.getColumnIndex(COLUMN_VERSION_WDRE)) + 1;
    } finally {
      rs.close();
    }
  }

  async countActiveForPairWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string
  ): Promise<number> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.countActiveForPairWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WDRE, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_TARGET_CHARACTER_INSTANCE_ID_WDRE, targetCharacterInstanceId);
    predicates.equalTo(COLUMN_STATUS_WDRE, WorldDirectionalRelationshipEntryStatus.Active);
    const rs: relationalStore.ResultSet = await store.query(predicates, ['COUNT(*) AS cnt']);
    try {
      if (!rs.goToFirstRow()) {
        return 0;
      }
      return rs.getLong(0);
    } finally {
      rs.close();
    }
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    entry: WorldDirectionalRelationshipEntry
  ): Promise<void> {
    try {
      await store.insert(TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES, entryToBucket(entry));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldDirectionalRelationshipEntry.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldDirectionalRelationshipEntry.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async updateStatusWithStore(
    store: relationalStore.RdbStore,
    id: string,
    expectedStatus: WorldDirectionalRelationshipEntryStatus,
    newStatus: WorldDirectionalRelationshipEntryStatus,
    statusUpdatedAt: number
  ): Promise<boolean> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.updateStatusWithStore: id empty');
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS_WDRE] = newStatus;
    bucket[COLUMN_STATUS_UPDATED_AT_WDRE] = statusUpdatedAt;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES);
    predicates.equalTo(COLUMN_ID, id);
    predicates.equalTo(COLUMN_STATUS_WDRE, expectedStatus);
    try {
      const affected: number = await store.update(bucket, predicates);
      return affected > 0;
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldDirectionalRelationshipEntry.updateStatusWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldDirectionalRelationshipEntry.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldDirectionalRelationshipEntry.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`);
    }
  }
}

function entryToBucket(entry: WorldDirectionalRelationshipEntry): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = entry.id;
  bucket[COLUMN_WORLD_ID] = entry.worldId;
  bucket[COLUMN_OWNER_CHARACTER_INSTANCE_ID_WDRE] = entry.ownerCharacterInstanceId;
  bucket[COLUMN_TARGET_CHARACTER_INSTANCE_ID_WDRE] = entry.targetCharacterInstanceId;
  bucket[COLUMN_VERSION_WDRE] = entry.version;
  bucket[COLUMN_RELATIONSHIP_TEXT] = entry.relationshipText;
  bucket[COLUMN_CONFIDENCE] = entry.confidence;
  bucket[COLUMN_SOURCE_SCENE_ID_WDRE] = entry.sourceSceneId;
  bucket[COLUMN_SOURCE_SESSION_ID_WDRE] = entry.sourceSessionId;
  bucket[COLUMN_SOURCE_LOCATION_ID_WDRE] = entry.sourceLocationId;
  bucket[COLUMN_EVIDENCE_MESSAGE_IDS_JSON_WDRE] = entry.evidenceMessageIdsJson;
  bucket[COLUMN_OWNER_DISPLAY_NAME_SNAPSHOT_WDRE] = entry.ownerDisplayNameSnapshot;
  bucket[COLUMN_TARGET_DISPLAY_NAME_SNAPSHOT_WDRE] = entry.targetDisplayNameSnapshot;
  bucket[COLUMN_PROMPT_VERSION] = entry.promptVersion;
  if (entry.providerId !== undefined) {
    bucket[COLUMN_PROVIDER_ID_WDRE] = entry.providerId;
  }
  if (entry.modelId !== undefined) {
    bucket[COLUMN_MODEL_ID_WDRE] = entry.modelId;
  }
  if (entry.supersedesRelationshipId !== undefined) {
    bucket[COLUMN_SUPERSEDES_RELATIONSHIP_ID] = entry.supersedesRelationshipId;
  }
  bucket[COLUMN_STATUS_WDRE] = entry.status;
  bucket[COLUMN_CREATED_AT] = entry.createdAt;
  bucket[COLUMN_STATUS_UPDATED_AT_WDRE] = entry.statusUpdatedAt;
  return bucket;
}

function entryFromRow(rs: relationalStore.ResultSet): WorldDirectionalRelationshipEntry {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  const ownerCharacterInstanceId: string = rs.getString(rs.getColumnIndex(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WDRE));
  const targetCharacterInstanceId: string = rs.getString(rs.getColumnIndex(COLUMN_TARGET_CHARACTER_INSTANCE_ID_WDRE));
  const version: number = rs.getLong(rs.getColumnIndex(COLUMN_VERSION_WDRE));
  const relationshipText: string = rs.getString(rs.getColumnIndex(COLUMN_RELATIONSHIP_TEXT));
  const confidence: number = rs.getDouble(rs.getColumnIndex(COLUMN_CONFIDENCE));
  const sourceSceneId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SCENE_ID_WDRE));
  const sourceSessionId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SESSION_ID_WDRE));
  const sourceLocationId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_LOCATION_ID_WDRE));
  const evidenceMessageIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_EVIDENCE_MESSAGE_IDS_JSON_WDRE));
  const ownerDisplayNameSnapshot: string = rs.getString(rs.getColumnIndex(COLUMN_OWNER_DISPLAY_NAME_SNAPSHOT_WDRE));
  const targetDisplayNameSnapshot: string = rs.getString(rs.getColumnIndex(COLUMN_TARGET_DISPLAY_NAME_SNAPSHOT_WDRE));
  const promptVersion: string = rs.getString(rs.getColumnIndex(COLUMN_PROMPT_VERSION));
  const providerIdRaw: string = rs.getString(rs.getColumnIndex(COLUMN_PROVIDER_ID_WDRE));
  const modelIdRaw: string = rs.getString(rs.getColumnIndex(COLUMN_MODEL_ID_WDRE));
  const supersedesRaw: string = rs.getString(rs.getColumnIndex(COLUMN_SUPERSEDES_RELATIONSHIP_ID));
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS_WDRE));
  if (!isWorldDirectionalRelationshipEntryStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldDirectionalRelationshipEntry.status invalid in row: ${statusRaw}`);
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const statusUpdatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_STATUS_UPDATED_AT_WDRE));
  return {
    id: id,
    worldId: worldId,
    ownerCharacterInstanceId: ownerCharacterInstanceId,
    targetCharacterInstanceId: targetCharacterInstanceId,
    version: version,
    relationshipText: relationshipText,
    confidence: confidence,
    sourceSceneId: sourceSceneId,
    sourceSessionId: sourceSessionId,
    sourceLocationId: sourceLocationId,
    evidenceMessageIdsJson: evidenceMessageIdsJson,
    ownerDisplayNameSnapshot: ownerDisplayNameSnapshot,
    targetDisplayNameSnapshot: targetDisplayNameSnapshot,
    promptVersion: promptVersion,
    providerId: providerIdRaw !== '' ? providerIdRaw : undefined,
    modelId: modelIdRaw !== '' ? modelIdRaw : undefined,
    supersedesRelationshipId: supersedesRaw !== '' ? supersedesRaw : undefined,
    status: statusRaw as WorldDirectionalRelationshipEntryStatus,
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}
