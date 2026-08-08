import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldCharacterMemoryEntry,
  WorldCharacterMemoryKind,
  WorldCharacterMemoryEntryStatus,
  isWorldCharacterMemoryKind,
  isWorldCharacterMemoryEntryStatus
} from '../../models/world/WorldCharacterMemoryEntry';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_CHARACTER_MEMORY_ENTRIES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_OWNER_CHARACTER_INSTANCE_ID_WCME,
  COLUMN_MEMORY_KIND_WCME,
  COLUMN_SOURCE_SCENE_ID_WCME,
  COLUMN_SOURCE_SESSION_ID_WCME,
  COLUMN_SOURCE_LOCATION_ID_WCME,
  COLUMN_VERSION,
  COLUMN_MEMORY_TEXT_WCME,
  COLUMN_SOURCE_MESSAGE_IDS_JSON_WCME,
  COLUMN_SOURCE_MESSAGE_COUNT,
  COLUMN_SOURCE_PARTICIPANT_INSTANCE_IDS_JSON_WCME,
  COLUMN_SOURCE_WITNESS_INSTANCE_IDS_JSON_WCME,
  COLUMN_OWNER_DISPLAY_NAME_SNAPSHOT_WCME,
  COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WCME,
  COLUMN_CONFIDENCE_WCME,
  COLUMN_STATUS_WCME,
  COLUMN_PROMPT_VERSION_WCME,
  COLUMN_PROVIDER_ID_WCME,
  COLUMN_MODEL_ID_WCME,
  COLUMN_SUPERSEDES_MEMORY_ID_WCME,
  COLUMN_CREATED_AT,
  COLUMN_STATUS_UPDATED_AT_WCME
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldCharacterMemoryEntryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<WorldCharacterMemoryEntry | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORY_ENTRIES);
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

  async insertWithStore(store: relationalStore.RdbStore, entry: WorldCharacterMemoryEntry): Promise<void> {
    try {
      await store.insert(TABLE_WORLD_CHARACTER_MEMORY_ENTRIES, entryToBucket(entry));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldCharacterMemoryEntry.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldCharacterMemoryEntry.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async updateStatusWithStore(
    store: relationalStore.RdbStore,
    id: string,
    newStatus: WorldCharacterMemoryEntryStatus,
    statusUpdatedAt: number
  ): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.updateStatusWithStore: id empty');
    }
    if (!isValidTimestamp(statusUpdatedAt)) {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.updateStatusWithStore: statusUpdatedAt invalid');
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS_WCME] = newStatus;
    bucket[COLUMN_STATUS_UPDATED_AT_WCME] = statusUpdatedAt;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORY_ENTRIES);
    predicates.equalTo(COLUMN_ID, id);
    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldCharacterMemoryEntry.updateStatusWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldCharacterMemoryEntry.updateStatusWithStore');
    }
  }

  async listActiveByOwnerWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string
  ): Promise<WorldCharacterMemoryEntry[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.listActiveByOwnerWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.listActiveByOwnerWithStore: ownerCharacterInstanceId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORY_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WCME, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_STATUS_WCME, WorldCharacterMemoryEntryStatus.Active);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldCharacterMemoryEntry[] = [];
      while (rs.goToNextRow()) {
        list.push(entryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async listActiveByOwnerAndSessionWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string,
    sessionId: string
  ): Promise<WorldCharacterMemoryEntry[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.listActiveByOwnerAndSessionWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.listActiveByOwnerAndSessionWithStore: ownerCharacterInstanceId empty');
    }
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.listActiveByOwnerAndSessionWithStore: sessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORY_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WCME, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_SOURCE_SESSION_ID_WCME, sessionId);
    predicates.equalTo(COLUMN_STATUS_WCME, WorldCharacterMemoryEntryStatus.Active);
    predicates.orderByDesc(COLUMN_VERSION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldCharacterMemoryEntry[] = [];
      while (rs.goToNextRow()) {
        list.push(entryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async findActiveByOwnerSessionKindPromptVersionWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string,
    sessionId: string,
    memoryKind: WorldCharacterMemoryKind,
    promptVersion: string
  ): Promise<WorldCharacterMemoryEntry | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.findActiveByOwnerSessionKindPromptVersionWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.findActiveByOwnerSessionKindPromptVersionWithStore: ownerCharacterInstanceId empty');
    }
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.findActiveByOwnerSessionKindPromptVersionWithStore: sessionId empty');
    }
    if (promptVersion === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.findActiveByOwnerSessionKindPromptVersionWithStore: promptVersion empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORY_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WCME, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_SOURCE_SESSION_ID_WCME, sessionId);
    predicates.equalTo(COLUMN_MEMORY_KIND_WCME, memoryKind);
    predicates.equalTo(COLUMN_PROMPT_VERSION_WCME, promptVersion);
    predicates.equalTo(COLUMN_STATUS_WCME, WorldCharacterMemoryEntryStatus.Active);
    predicates.orderByDesc(COLUMN_VERSION);
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

  async getNextVersionForOwnerSessionKindWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string,
    sessionId: string,
    memoryKind: WorldCharacterMemoryKind
  ): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORY_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WCME, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_SOURCE_SESSION_ID_WCME, sessionId);
    predicates.equalTo(COLUMN_MEMORY_KIND_WCME, memoryKind);
    const columns: string[] = [`MAX(${COLUMN_VERSION}) AS max_version`];
    const rs: relationalStore.ResultSet = await store.query(predicates, columns);
    try {
      if (!rs.goToFirstRow()) {
        return 1;
      }
      const col: number = rs.getColumnIndex('max_version');
      if (col < 0 || rs.isColumnNull(col)) {
        return 1;
      }
      const maxVersion: number = rs.getLong(col);
      if (!Number.isFinite(maxVersion) || maxVersion < 0) {
        return 1;
      }
      return maxVersion + 1;
    } finally {
      rs.close();
    }
  }

  async deleteByWorldIdWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORY_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldCharacterMemoryEntry.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async countByWorldIdWithStore(store: relationalStore.RdbStore, worldId: string): Promise<number> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterMemoryEntry.countByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_MEMORY_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    const rs: relationalStore.ResultSet = await store.query(predicates, ['COUNT(*) AS cnt']);
    try {
      if (!rs.goToFirstRow()) {
        return 0;
      }
      return rs.getLong(rs.getColumnIndex('cnt'));
    } finally {
      rs.close();
    }
  }
}

function entryToBucket(entry: WorldCharacterMemoryEntry): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = entry.id;
  bucket[COLUMN_WORLD_ID] = entry.worldId;
  bucket[COLUMN_OWNER_CHARACTER_INSTANCE_ID_WCME] = entry.ownerCharacterInstanceId;
  bucket[COLUMN_MEMORY_KIND_WCME] = entry.memoryKind;
  bucket[COLUMN_SOURCE_SCENE_ID_WCME] = entry.sourceSceneId;
  bucket[COLUMN_SOURCE_SESSION_ID_WCME] = entry.sourceSessionId;
  bucket[COLUMN_SOURCE_LOCATION_ID_WCME] = entry.sourceLocationId;
  bucket[COLUMN_VERSION] = entry.version;
  bucket[COLUMN_MEMORY_TEXT_WCME] = entry.memoryText;
  bucket[COLUMN_SOURCE_MESSAGE_IDS_JSON_WCME] = entry.sourceMessageIdsJson;
  bucket[COLUMN_SOURCE_MESSAGE_COUNT] = entry.sourceMessageCount;
  bucket[COLUMN_SOURCE_PARTICIPANT_INSTANCE_IDS_JSON_WCME] = entry.sourceParticipantInstanceIdsJson;
  bucket[COLUMN_SOURCE_WITNESS_INSTANCE_IDS_JSON_WCME] = entry.sourceWitnessInstanceIdsJson;
  bucket[COLUMN_OWNER_DISPLAY_NAME_SNAPSHOT_WCME] = entry.ownerDisplayNameSnapshot;
  bucket[COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WCME] = entry.playerDisplayNameSnapshot;
  bucket[COLUMN_CONFIDENCE_WCME] = entry.confidence;
  bucket[COLUMN_STATUS_WCME] = entry.status;
  bucket[COLUMN_PROMPT_VERSION_WCME] = entry.promptVersion;
  if (entry.providerId !== undefined) {
    bucket[COLUMN_PROVIDER_ID_WCME] = entry.providerId;
  } else {
    bucket[COLUMN_PROVIDER_ID_WCME] = null;
  }
  if (entry.modelId !== undefined) {
    bucket[COLUMN_MODEL_ID_WCME] = entry.modelId;
  } else {
    bucket[COLUMN_MODEL_ID_WCME] = null;
  }
  if (entry.supersedesMemoryId !== undefined) {
    bucket[COLUMN_SUPERSEDES_MEMORY_ID_WCME] = entry.supersedesMemoryId;
  } else {
    bucket[COLUMN_SUPERSEDES_MEMORY_ID_WCME] = null;
  }
  bucket[COLUMN_CREATED_AT] = entry.createdAt;
  bucket[COLUMN_STATUS_UPDATED_AT_WCME] = entry.statusUpdatedAt;
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

function entryFromRow(rs: relationalStore.ResultSet): WorldCharacterMemoryEntry {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldCharacterMemoryEntry.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldCharacterMemoryEntry.worldId empty in row');
  }
  const ownerCharacterInstanceId: string = rs.getString(rs.getColumnIndex(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WCME));
  if (ownerCharacterInstanceId === '') {
    throw DatabaseError.invalidData('WorldCharacterMemoryEntry.ownerCharacterInstanceId empty in row');
  }
  const memoryKindRaw: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_KIND_WCME));
  if (!isWorldCharacterMemoryKind(memoryKindRaw)) {
    throw DatabaseError.invalidData(`WorldCharacterMemoryEntry.memoryKind invalid in row: ${memoryKindRaw}`);
  }
  const sourceSceneId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SCENE_ID_WCME));
  const sourceSessionId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SESSION_ID_WCME));
  const sourceLocationId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_LOCATION_ID_WCME));
  const version: number = rs.getLong(rs.getColumnIndex(COLUMN_VERSION));
  const memoryText: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_TEXT_WCME));
  const sourceMessageIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_MESSAGE_IDS_JSON_WCME));
  const sourceMessageCount: number = rs.getLong(rs.getColumnIndex(COLUMN_SOURCE_MESSAGE_COUNT));
  const sourceParticipantInstanceIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_PARTICIPANT_INSTANCE_IDS_JSON_WCME));
  const sourceWitnessInstanceIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_WITNESS_INSTANCE_IDS_JSON_WCME));
  const ownerDisplayNameSnapshot: string = rs.getString(rs.getColumnIndex(COLUMN_OWNER_DISPLAY_NAME_SNAPSHOT_WCME));
  const playerDisplayNameSnapshot: string = rs.getString(rs.getColumnIndex(COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WCME));
  const confidence: number = rs.getDouble(rs.getColumnIndex(COLUMN_CONFIDENCE_WCME));
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS_WCME));
  if (!isWorldCharacterMemoryEntryStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldCharacterMemoryEntry.status invalid in row: ${statusRaw}`);
  }
  const promptVersion: string = rs.getString(rs.getColumnIndex(COLUMN_PROMPT_VERSION_WCME));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldCharacterMemoryEntry.createdAt invalid in row');
  }
  const statusUpdatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_STATUS_UPDATED_AT_WCME));
  if (!isValidTimestamp(statusUpdatedAt)) {
    throw DatabaseError.invalidData('WorldCharacterMemoryEntry.statusUpdatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    ownerCharacterInstanceId: ownerCharacterInstanceId,
    memoryKind: memoryKindRaw as WorldCharacterMemoryKind,
    sourceSceneId: sourceSceneId,
    sourceSessionId: sourceSessionId,
    sourceLocationId: sourceLocationId,
    version: version,
    memoryText: memoryText,
    sourceMessageIdsJson: sourceMessageIdsJson,
    sourceMessageCount: sourceMessageCount,
    sourceParticipantInstanceIdsJson: sourceParticipantInstanceIdsJson,
    sourceWitnessInstanceIdsJson: sourceWitnessInstanceIdsJson,
    ownerDisplayNameSnapshot: ownerDisplayNameSnapshot,
    playerDisplayNameSnapshot: playerDisplayNameSnapshot,
    confidence: confidence,
    status: statusRaw as WorldCharacterMemoryEntryStatus,
    promptVersion: promptVersion,
    providerId: readOptionalString(rs, COLUMN_PROVIDER_ID_WCME),
    modelId: readOptionalString(rs, COLUMN_MODEL_ID_WCME),
    supersedesMemoryId: readOptionalString(rs, COLUMN_SUPERSEDES_MEMORY_ID_WCME),
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}
