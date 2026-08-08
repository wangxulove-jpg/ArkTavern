import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldKnownEventEntry,
  WorldKnownEventSourceKind,
  WorldKnownEventEntryStatus,
  isWorldKnownEventSourceKind,
  isWorldKnownEventEntryStatus
} from '../../models/world/WorldKnownEventEntry';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_KNOWN_EVENT_ENTRIES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_OWNER_CHARACTER_INSTANCE_ID_WKEE,
  COLUMN_EVENT_ID_WKEE,
  COLUMN_EXTRACTION_RUN_ID_WKEE,
  COLUMN_KNOWLEDGE_SOURCE_KIND,
  COLUMN_SOURCE_SESSION_ID_WKEE,
  COLUMN_KNOWLEDGE_SOURCE_MESSAGE_IDS_JSON,
  COLUMN_STATUS_WKEE,
  COLUMN_CREATED_AT,
  COLUMN_STATUS_UPDATED_AT_WKEE
} from '../../database/DatabaseConstants';
import {
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldKnownEventEntryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldKnownEventEntry | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_KNOWN_EVENT_ENTRIES);
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

  async findByIdentityWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    ownerCharacterInstanceId: string,
    eventId: string,
    knowledgeSourceKind: WorldKnownEventSourceKind,
    sourceSessionId: string
  ): Promise<WorldKnownEventEntry | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.findByIdentityWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.findByIdentityWithStore: ownerCharacterInstanceId empty');
    }
    if (eventId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.findByIdentityWithStore: eventId empty');
    }
    if (sourceSessionId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.findByIdentityWithStore: sourceSessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_KNOWN_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WKEE, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_EVENT_ID_WKEE, eventId);
    predicates.equalTo(COLUMN_KNOWLEDGE_SOURCE_KIND, knowledgeSourceKind);
    predicates.equalTo(COLUMN_SOURCE_SESSION_ID_WKEE, sourceSessionId);
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
  ): Promise<WorldKnownEventEntry[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.listActiveByOwnerWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.listActiveByOwnerWithStore: ownerCharacterInstanceId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_KNOWN_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WKEE, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_STATUS_WKEE, WorldKnownEventEntryStatus.Active);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldKnownEventEntry[] = [];
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
    sourceSessionId: string
  ): Promise<WorldKnownEventEntry[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.listActiveByOwnerAndSessionWithStore: worldId empty');
    }
    if (ownerCharacterInstanceId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.listActiveByOwnerAndSessionWithStore: ownerCharacterInstanceId empty');
    }
    if (sourceSessionId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.listActiveByOwnerAndSessionWithStore: sourceSessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_KNOWN_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WKEE, ownerCharacterInstanceId);
    predicates.equalTo(COLUMN_SOURCE_SESSION_ID_WKEE, sourceSessionId);
    predicates.equalTo(COLUMN_STATUS_WKEE, WorldKnownEventEntryStatus.Active);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldKnownEventEntry[] = [];
      while (rs.goToNextRow()) {
        list.push(entryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async listByExtractionRunIdWithStore(
    store: relationalStore.RdbStore,
    extractionRunId: string
  ): Promise<WorldKnownEventEntry[]> {
    if (extractionRunId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.listByExtractionRunIdWithStore: extractionRunId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_KNOWN_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_EXTRACTION_RUN_ID_WKEE, extractionRunId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldKnownEventEntry[] = [];
      while (rs.goToNextRow()) {
        list.push(entryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    entry: WorldKnownEventEntry
  ): Promise<void> {
    try {
      await store.insert(TABLE_WORLD_KNOWN_EVENT_ENTRIES, entryToBucket(entry));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldKnownEventEntry.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldKnownEventEntry.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async updateStatusToRejectedWithStore(
    store: relationalStore.RdbStore,
    id: string,
    statusUpdatedAt: number
  ): Promise<boolean> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.updateStatusToRejectedWithStore: id empty');
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS_WKEE] = WorldKnownEventEntryStatus.Rejected;
    bucket[COLUMN_STATUS_UPDATED_AT_WKEE] = statusUpdatedAt;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_KNOWN_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_ID, id);
    predicates.equalTo(COLUMN_STATUS_WKEE, WorldKnownEventEntryStatus.Active);
    try {
      const affected: number = await store.update(bucket, predicates);
      return affected > 0;
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldKnownEventEntry.updateStatusToRejectedWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_KNOWN_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldKnownEventEntry.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async rejectByExtractionRunIdWithStore(
    store: relationalStore.RdbStore,
    extractionRunId: string,
    statusUpdatedAt: number
  ): Promise<number> {
    if (extractionRunId === '') {
      throw DatabaseError.invalidData('WorldKnownEventEntry.rejectByExtractionRunIdWithStore: extractionRunId empty');
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS_WKEE] = WorldKnownEventEntryStatus.Rejected;
    bucket[COLUMN_STATUS_UPDATED_AT_WKEE] = statusUpdatedAt;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_KNOWN_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_EXTRACTION_RUN_ID_WKEE, extractionRunId);
    predicates.equalTo(COLUMN_STATUS_WKEE, WorldKnownEventEntryStatus.Active);
    try {
      const affected: number = await store.update(bucket, predicates);
      return affected;
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldKnownEventEntry.rejectByExtractionRunIdWithStore: ${extractCauseMessage(err)}`);
    }
  }
}

function entryToBucket(entry: WorldKnownEventEntry): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = entry.id;
  bucket[COLUMN_WORLD_ID] = entry.worldId;
  bucket[COLUMN_OWNER_CHARACTER_INSTANCE_ID_WKEE] = entry.ownerCharacterInstanceId;
  bucket[COLUMN_EVENT_ID_WKEE] = entry.eventId;
  bucket[COLUMN_EXTRACTION_RUN_ID_WKEE] = entry.extractionRunId;
  bucket[COLUMN_KNOWLEDGE_SOURCE_KIND] = entry.knowledgeSourceKind;
  bucket[COLUMN_SOURCE_SESSION_ID_WKEE] = entry.sourceSessionId;
  bucket[COLUMN_KNOWLEDGE_SOURCE_MESSAGE_IDS_JSON] = entry.knowledgeSourceMessageIdsJson;
  bucket[COLUMN_STATUS_WKEE] = entry.status;
  bucket[COLUMN_CREATED_AT] = entry.createdAt;
  bucket[COLUMN_STATUS_UPDATED_AT_WKEE] = entry.statusUpdatedAt;
  return bucket;
}

function entryFromRow(rs: relationalStore.ResultSet): WorldKnownEventEntry {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  const ownerCharacterInstanceId: string = rs.getString(rs.getColumnIndex(COLUMN_OWNER_CHARACTER_INSTANCE_ID_WKEE));
  const eventId: string = rs.getString(rs.getColumnIndex(COLUMN_EVENT_ID_WKEE));
  const extractionRunId: string = rs.getString(rs.getColumnIndex(COLUMN_EXTRACTION_RUN_ID_WKEE));
  const sourceKindRaw: string = rs.getString(rs.getColumnIndex(COLUMN_KNOWLEDGE_SOURCE_KIND));
  if (!isWorldKnownEventSourceKind(sourceKindRaw)) {
    throw DatabaseError.invalidData(`WorldKnownEventEntry.knowledgeSourceKind invalid in row: ${sourceKindRaw}`);
  }
  const sourceSessionId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SESSION_ID_WKEE));
  const knowledgeSourceMessageIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_KNOWLEDGE_SOURCE_MESSAGE_IDS_JSON));
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS_WKEE));
  if (!isWorldKnownEventEntryStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldKnownEventEntry.status invalid in row: ${statusRaw}`);
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const statusUpdatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_STATUS_UPDATED_AT_WKEE));
  return {
    id: id,
    worldId: worldId,
    ownerCharacterInstanceId: ownerCharacterInstanceId,
    eventId: eventId,
    extractionRunId: extractionRunId,
    knowledgeSourceKind: sourceKindRaw as WorldKnownEventSourceKind,
    sourceSessionId: sourceSessionId,
    knowledgeSourceMessageIdsJson: knowledgeSourceMessageIdsJson,
    status: statusRaw as WorldKnownEventEntryStatus,
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}
