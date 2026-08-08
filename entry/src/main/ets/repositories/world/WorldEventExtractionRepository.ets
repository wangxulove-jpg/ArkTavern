import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldEventExtractionRun,
  WorldEventEntry,
  WorldEventExtractionRunStatus,
  WorldEventEntryStatus,
  WorldEventKind,
  isWorldEventExtractionRunStatus,
  isWorldEventEntryStatus,
  isWorldEventKind
} from '../../models/world/WorldEventExtraction';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_EVENT_EXTRACTION_RUNS,
  TABLE_WORLD_EVENT_ENTRIES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_SOURCE_SCENE_ID_WEER,
  COLUMN_SOURCE_SESSION_ID_WEER,
  COLUMN_SOURCE_LOCATION_ID_WEER,
  COLUMN_VERSION_WEER,
  COLUMN_SOURCE_SUMMARY_ID_WEER,
  COLUMN_SOURCE_SUMMARY_VERSION_WEER,
  COLUMN_SOURCE_MESSAGE_IDS_JSON_WEER,
  COLUMN_SOURCE_MESSAGE_COUNT_WEER,
  COLUMN_PARTICIPANT_INSTANCE_IDS_JSON_WEER,
  COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WEER,
  COLUMN_STATUS_WEER,
  COLUMN_PROMPT_VERSION_WEER,
  COLUMN_PROVIDER_ID_WEER,
  COLUMN_MODEL_ID_WEER,
  COLUMN_CREATED_AT,
  COLUMN_STATUS_UPDATED_AT_WEER,
  COLUMN_EXTRACTION_RUN_ID,
  COLUMN_EVENT_ORDINAL,
  COLUMN_EVENT_KIND,
  COLUMN_EVENT_TEXT,
  COLUMN_ACTOR_INSTANCE_IDS_JSON,
  COLUMN_PLAYER_INVOLVED,
  COLUMN_EVIDENCE_MESSAGE_IDS_JSON,
  COLUMN_WITNESS_INSTANCE_IDS_JSON,
  COLUMN_CONFIDENCE,
  COLUMN_STATUS_WEE,
  COLUMN_STATUS_UPDATED_AT_WEE
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldEventExtractionRunRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldEventExtractionRun | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldEventExtractionRun.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_EXTRACTION_RUNS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return runFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async getActiveBySessionWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    sourceSessionId: string
  ): Promise<WorldEventExtractionRun | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEventExtractionRun.getActiveBySessionWithStore: worldId empty');
    }
    if (sourceSessionId === '') {
      throw DatabaseError.invalidData('WorldEventExtractionRun.getActiveBySessionWithStore: sourceSessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_EXTRACTION_RUNS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_SOURCE_SESSION_ID_WEER, sourceSessionId);
    predicates.equalTo(COLUMN_STATUS_WEER, WorldEventExtractionRunStatus.Active);
    predicates.orderByDesc(COLUMN_VERSION_WEER);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return runFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listBySessionWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    sourceSessionId: string
  ): Promise<WorldEventExtractionRun[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEventExtractionRun.listBySessionWithStore: worldId empty');
    }
    if (sourceSessionId === '') {
      throw DatabaseError.invalidData('WorldEventExtractionRun.listBySessionWithStore: sourceSessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_EXTRACTION_RUNS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_SOURCE_SESSION_ID_WEER, sourceSessionId);
    predicates.orderByDesc(COLUMN_VERSION_WEER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldEventExtractionRun[] = [];
      while (rs.goToNextRow()) {
        list.push(runFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async getNextVersionForSessionWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    sourceSessionId: string
  ): Promise<number> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEventExtractionRun.getNextVersionForSessionWithStore: worldId empty');
    }
    if (sourceSessionId === '') {
      throw DatabaseError.invalidData('WorldEventExtractionRun.getNextVersionForSessionWithStore: sourceSessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_EXTRACTION_RUNS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_SOURCE_SESSION_ID_WEER, sourceSessionId);
    predicates.orderByDesc(COLUMN_VERSION_WEER);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return 1;
      }
      return rs.getLong(rs.getColumnIndex(COLUMN_VERSION_WEER)) + 1;
    } finally {
      rs.close();
    }
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    run: WorldEventExtractionRun
  ): Promise<void> {
    try {
      await store.insert(TABLE_WORLD_EVENT_EXTRACTION_RUNS, runToBucket(run));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldEventExtractionRun.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldEventExtractionRun.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async updateStatusWithStore(
    store: relationalStore.RdbStore,
    id: string,
    expectedStatus: WorldEventExtractionRunStatus,
    newStatus: WorldEventExtractionRunStatus,
    statusUpdatedAt: number
  ): Promise<boolean> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldEventExtractionRun.updateStatusWithStore: id empty');
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS_WEER] = newStatus;
    bucket[COLUMN_STATUS_UPDATED_AT_WEER] = statusUpdatedAt;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_EXTRACTION_RUNS);
    predicates.equalTo(COLUMN_ID, id);
    predicates.equalTo(COLUMN_STATUS_WEER, expectedStatus);
    try {
      const affected: number = await store.update(bucket, predicates);
      return affected > 0;
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldEventExtractionRun.updateStatusWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEventExtractionRun.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_EXTRACTION_RUNS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldEventExtractionRun.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`);
    }
  }
}

export class WorldEventEntryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    id: string
  ): Promise<WorldEventEntry | null> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEventEntry.getByIdWithStore: worldId empty');
    }
    if (id === '') {
      throw DatabaseError.invalidData('WorldEventEntry.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_ENTRIES);
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

  async listByRunWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    extractionRunId: string
  ): Promise<WorldEventEntry[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEventEntry.listByRunWithStore: worldId empty');
    }
    if (extractionRunId === '') {
      throw DatabaseError.invalidData('WorldEventEntry.listByRunWithStore: extractionRunId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_EXTRACTION_RUN_ID, extractionRunId);
    predicates.orderByAsc(COLUMN_EVENT_ORDINAL);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldEventEntry[] = [];
      while (rs.goToNextRow()) {
        list.push(entryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async listActiveByRunWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    extractionRunId: string
  ): Promise<WorldEventEntry[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEventEntry.listActiveByRunWithStore: worldId empty');
    }
    if (extractionRunId === '') {
      throw DatabaseError.invalidData('WorldEventEntry.listActiveByRunWithStore: extractionRunId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_EXTRACTION_RUN_ID, extractionRunId);
    predicates.equalTo(COLUMN_STATUS_WEE, WorldEventEntryStatus.Active);
    predicates.orderByAsc(COLUMN_EVENT_ORDINAL);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldEventEntry[] = [];
      while (rs.goToNextRow()) {
        list.push(entryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async listCurrentActiveBySessionWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    sourceSessionId: string
  ): Promise<WorldEventEntry[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEventEntry.listCurrentActiveBySessionWithStore: worldId empty');
    }
    if (sourceSessionId === '') {
      throw DatabaseError.invalidData('WorldEventEntry.listCurrentActiveBySessionWithStore: sourceSessionId empty');
    }
    const runRepo: WorldEventExtractionRunRepository = new WorldEventExtractionRunRepository(this.dbHelper);
    const activeRun: WorldEventExtractionRun | null =
      await runRepo.getActiveBySessionWithStore(store, worldId, sourceSessionId);
    if (activeRun === null) {
      return [];
    }
    return await this.listActiveByRunWithStore(store, worldId, activeRun.id);
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    entry: WorldEventEntry
  ): Promise<void> {
    try {
      await store.insert(TABLE_WORLD_EVENT_ENTRIES, entryToBucket(entry));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldEventEntry.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldEventEntry.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async updateStatusWithStore(
    store: relationalStore.RdbStore,
    id: string,
    newStatus: WorldEventEntryStatus,
    statusUpdatedAt: number
  ): Promise<boolean> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldEventEntry.updateStatusWithStore: id empty');
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS_WEE] = newStatus;
    bucket[COLUMN_STATUS_UPDATED_AT_WEE] = statusUpdatedAt;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_ID, id);
    predicates.equalTo(COLUMN_STATUS_WEE, WorldEventEntryStatus.Active);
    try {
      const affected: number = await store.update(bucket, predicates);
      return affected > 0;
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldEventEntry.updateStatusWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldEventEntry.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldEventEntry.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByExtractionRunIdWithStore(
    store: relationalStore.RdbStore,
    extractionRunId: string
  ): Promise<void> {
    if (extractionRunId === '') {
      throw DatabaseError.invalidData('WorldEventEntry.deleteByExtractionRunIdWithStore: extractionRunId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_EVENT_ENTRIES);
    predicates.equalTo(COLUMN_EXTRACTION_RUN_ID, extractionRunId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldEventEntry.deleteByExtractionRunIdWithStore: ${extractCauseMessage(err)}`);
    }
  }
}

function runToBucket(run: WorldEventExtractionRun): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = run.id;
  bucket[COLUMN_WORLD_ID] = run.worldId;
  bucket[COLUMN_SOURCE_SCENE_ID_WEER] = run.sourceSceneId;
  bucket[COLUMN_SOURCE_SESSION_ID_WEER] = run.sourceSessionId;
  bucket[COLUMN_SOURCE_LOCATION_ID_WEER] = run.sourceLocationId;
  bucket[COLUMN_VERSION_WEER] = run.version;
  bucket[COLUMN_SOURCE_SUMMARY_ID_WEER] = run.sourceSummaryId;
  bucket[COLUMN_SOURCE_SUMMARY_VERSION_WEER] = run.sourceSummaryVersion;
  bucket[COLUMN_SOURCE_MESSAGE_IDS_JSON_WEER] = run.sourceMessageIdsJson;
  bucket[COLUMN_SOURCE_MESSAGE_COUNT_WEER] = run.sourceMessageCount;
  bucket[COLUMN_PARTICIPANT_INSTANCE_IDS_JSON_WEER] = run.participantInstanceIdsJson;
  bucket[COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WEER] = run.playerDisplayNameSnapshot;
  bucket[COLUMN_STATUS_WEER] = run.status;
  bucket[COLUMN_PROMPT_VERSION_WEER] = run.promptVersion;
  if (run.providerId !== undefined) {
    bucket[COLUMN_PROVIDER_ID_WEER] = run.providerId;
  }
  if (run.modelId !== undefined) {
    bucket[COLUMN_MODEL_ID_WEER] = run.modelId;
  }
  bucket[COLUMN_CREATED_AT] = run.createdAt;
  bucket[COLUMN_STATUS_UPDATED_AT_WEER] = run.statusUpdatedAt;
  return bucket;
}

function runFromRow(rs: relationalStore.ResultSet): WorldEventExtractionRun {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  const sourceSceneId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SCENE_ID_WEER));
  const sourceSessionId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SESSION_ID_WEER));
  const sourceLocationId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_LOCATION_ID_WEER));
  const version: number = rs.getLong(rs.getColumnIndex(COLUMN_VERSION_WEER));
  const sourceSummaryId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SUMMARY_ID_WEER));
  const sourceSummaryVersion: number = rs.getLong(rs.getColumnIndex(COLUMN_SOURCE_SUMMARY_VERSION_WEER));
  const sourceMessageIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_MESSAGE_IDS_JSON_WEER));
  const sourceMessageCount: number = rs.getLong(rs.getColumnIndex(COLUMN_SOURCE_MESSAGE_COUNT_WEER));
  const participantInstanceIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_PARTICIPANT_INSTANCE_IDS_JSON_WEER));
  const playerDisplayNameSnapshot: string = rs.getString(rs.getColumnIndex(COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WEER));
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS_WEER));
  if (!isWorldEventExtractionRunStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldEventExtractionRun.status invalid in row: ${statusRaw}`);
  }
  const promptVersion: string = rs.getString(rs.getColumnIndex(COLUMN_PROMPT_VERSION_WEER));
  const providerIdRaw: string = rs.getString(rs.getColumnIndex(COLUMN_PROVIDER_ID_WEER));
  const modelIdRaw: string = rs.getString(rs.getColumnIndex(COLUMN_MODEL_ID_WEER));
  const providerId: string | undefined = providerIdRaw !== '' ? providerIdRaw : undefined;
  const modelId: string | undefined = modelIdRaw !== '' ? modelIdRaw : undefined;
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const statusUpdatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_STATUS_UPDATED_AT_WEER));
  return {
    id: id,
    worldId: worldId,
    sourceSceneId: sourceSceneId,
    sourceSessionId: sourceSessionId,
    sourceLocationId: sourceLocationId,
    version: version,
    sourceSummaryId: sourceSummaryId,
    sourceSummaryVersion: sourceSummaryVersion,
    sourceMessageIdsJson: sourceMessageIdsJson,
    sourceMessageCount: sourceMessageCount,
    participantInstanceIdsJson: participantInstanceIdsJson,
    playerDisplayNameSnapshot: playerDisplayNameSnapshot,
    status: statusRaw as WorldEventExtractionRunStatus,
    promptVersion: promptVersion,
    providerId: providerId,
    modelId: modelId,
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}

function entryToBucket(entry: WorldEventEntry): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = entry.id;
  bucket[COLUMN_WORLD_ID] = entry.worldId;
  bucket[COLUMN_EXTRACTION_RUN_ID] = entry.extractionRunId;
  bucket[COLUMN_SOURCE_SCENE_ID_WEER] = entry.sourceSceneId;
  bucket[COLUMN_SOURCE_SESSION_ID_WEER] = entry.sourceSessionId;
  bucket[COLUMN_SOURCE_LOCATION_ID_WEER] = entry.sourceLocationId;
  bucket[COLUMN_EVENT_ORDINAL] = entry.eventOrdinal;
  bucket[COLUMN_EVENT_KIND] = entry.eventKind;
  bucket[COLUMN_EVENT_TEXT] = entry.eventText;
  bucket[COLUMN_ACTOR_INSTANCE_IDS_JSON] = entry.actorInstanceIdsJson;
  bucket[COLUMN_PLAYER_INVOLVED] = entry.playerInvolved ? 1 : 0;
  bucket[COLUMN_EVIDENCE_MESSAGE_IDS_JSON] = entry.evidenceMessageIdsJson;
  bucket[COLUMN_WITNESS_INSTANCE_IDS_JSON] = entry.witnessInstanceIdsJson;
  bucket[COLUMN_CONFIDENCE] = entry.confidence;
  bucket[COLUMN_STATUS_WEE] = entry.status;
  bucket[COLUMN_CREATED_AT] = entry.createdAt;
  bucket[COLUMN_STATUS_UPDATED_AT_WEE] = entry.statusUpdatedAt;
  return bucket;
}

function entryFromRow(rs: relationalStore.ResultSet): WorldEventEntry {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  const extractionRunId: string = rs.getString(rs.getColumnIndex(COLUMN_EXTRACTION_RUN_ID));
  const sourceSceneId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SCENE_ID_WEER));
  const sourceSessionId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_SESSION_ID_WEER));
  const sourceLocationId: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_LOCATION_ID_WEER));
  const eventOrdinal: number = rs.getLong(rs.getColumnIndex(COLUMN_EVENT_ORDINAL));
  const eventKindRaw: string = rs.getString(rs.getColumnIndex(COLUMN_EVENT_KIND));
  if (!isWorldEventKind(eventKindRaw)) {
    throw DatabaseError.invalidData(`WorldEventEntry.eventKind invalid in row: ${eventKindRaw}`);
  }
  const eventText: string = rs.getString(rs.getColumnIndex(COLUMN_EVENT_TEXT));
  const actorInstanceIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_ACTOR_INSTANCE_IDS_JSON));
  const playerInvolvedRaw: number = rs.getLong(rs.getColumnIndex(COLUMN_PLAYER_INVOLVED));
  const playerInvolved: boolean = playerInvolvedRaw !== 0;
  const evidenceMessageIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_EVIDENCE_MESSAGE_IDS_JSON));
  const witnessInstanceIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_WITNESS_INSTANCE_IDS_JSON));
  const confidence: number = rs.getDouble(rs.getColumnIndex(COLUMN_CONFIDENCE));
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS_WEE));
  if (!isWorldEventEntryStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldEventEntry.status invalid in row: ${statusRaw}`);
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const statusUpdatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_STATUS_UPDATED_AT_WEE));
  return {
    id: id,
    worldId: worldId,
    extractionRunId: extractionRunId,
    sourceSceneId: sourceSceneId,
    sourceSessionId: sourceSessionId,
    sourceLocationId: sourceLocationId,
    eventOrdinal: eventOrdinal,
    eventKind: eventKindRaw as WorldEventKind,
    eventText: eventText,
    actorInstanceIdsJson: actorInstanceIdsJson,
    playerInvolved: playerInvolved,
    evidenceMessageIdsJson: evidenceMessageIdsJson,
    witnessInstanceIdsJson: witnessInstanceIdsJson,
    confidence: confidence,
    status: statusRaw as WorldEventEntryStatus,
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}
