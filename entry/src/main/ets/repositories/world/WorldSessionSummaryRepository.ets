import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldSessionSummary,
  WorldSessionSummaryVisibilityScope,
  isWorldSessionSummaryVisibilityScope
} from '../../models/world/WorldSessionSummary';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_SESSION_SUMMARIES,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_SCENE_ID,
  COLUMN_SESSION_ID_WSS,
  COLUMN_VERSION,
  COLUMN_VISIBILITY_SCOPE,
  COLUMN_CONTENT,
  COLUMN_SOURCE_MESSAGE_IDS_JSON_WSS,
  COLUMN_SOURCE_MESSAGE_COUNT,
  COLUMN_PARTICIPANT_SNAPSHOT_JSON_WSS,
  COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WSS,
  COLUMN_LOCATION_ID_WSS,
  COLUMN_PROMPT_VERSION,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldSessionSummaryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldSessionSummary | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldSessionSummary | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_SUMMARIES);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return summaryFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listBySessionId(sessionId: string): Promise<WorldSessionSummary[]> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.listBySessionId: sessionId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listBySessionIdWithStore(store, sessionId);
  }

  async listBySessionIdWithStore(
    store: relationalStore.RdbStore,
    sessionId: string
  ): Promise<WorldSessionSummary[]> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.listBySessionIdWithStore: sessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_SUMMARIES);
    predicates.equalTo(COLUMN_SESSION_ID_WSS, sessionId);
    predicates.orderByDesc(COLUMN_VERSION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldSessionSummary[] = [];
      while (rs.goToNextRow()) {
        list.push(summaryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async getLatestBySessionId(sessionId: string): Promise<WorldSessionSummary | null> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.getLatestBySessionId: sessionId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getLatestBySessionIdWithStore(store, sessionId);
  }

  async getLatestBySessionIdWithStore(
    store: relationalStore.RdbStore,
    sessionId: string
  ): Promise<WorldSessionSummary | null> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.getLatestBySessionIdWithStore: sessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_SUMMARIES);
    predicates.equalTo(COLUMN_SESSION_ID_WSS, sessionId);
    predicates.orderByDesc(COLUMN_VERSION);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return summaryFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listBySceneId(sceneId: string): Promise<WorldSessionSummary[]> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.listBySceneId: sceneId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_SUMMARIES);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    predicates.orderByDesc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldSessionSummary[] = [];
      while (rs.goToNextRow()) {
        list.push(summaryFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async insert(summary: WorldSessionSummary): Promise<void> {
    this.validateSummary(summary);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_SESSION_SUMMARIES, summaryToBucket(summary));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldSessionSummary.insert');
      }
      throw DatabaseError.queryFailed(`WorldSessionSummary.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, summary: WorldSessionSummary): Promise<void> {
    this.validateSummary(summary);
    try {
      await store.insert(TABLE_WORLD_SESSION_SUMMARIES, summaryToBucket(summary));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldSessionSummary.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldSessionSummary.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async getNextVersionForSession(sessionId: string): Promise<number> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.getNextVersionForSession: sessionId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getNextVersionForSessionWithStore(store, sessionId);
  }

  async getNextVersionForSessionWithStore(
    store: relationalStore.RdbStore,
    sessionId: string
  ): Promise<number> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.getNextVersionForSessionWithStore: sessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_SUMMARIES);
    predicates.equalTo(COLUMN_SESSION_ID_WSS, sessionId);
    predicates.orderByDesc(COLUMN_VERSION);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return 1;
      }
      return rs.getLong(rs.getColumnIndex(COLUMN_VERSION)) + 1;
    } finally {
      rs.close();
    }
  }

  async deleteByWorldIdWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_SUMMARIES);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldSessionSummary.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  async getBySessionIdAndVersionWithStore(
    store: relationalStore.RdbStore,
    sessionId: string,
    version: number
  ): Promise<WorldSessionSummary | null> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.getBySessionIdAndVersionWithStore: sessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_SUMMARIES);
    predicates.equalTo(COLUMN_SESSION_ID_WSS, sessionId);
    predicates.equalTo(COLUMN_VERSION, version);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return summaryFromRow(rs);
    } finally {
      rs.close();
    }
  }

  private validateSummary(summary: WorldSessionSummary): void {
    if (summary.id === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.id empty');
    }
    if (summary.worldId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.worldId empty');
    }
    if (summary.sceneId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.sceneId empty');
    }
    if (summary.sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.sessionId empty');
    }
    if (!Number.isFinite(summary.version) || !Number.isInteger(summary.version) || summary.version < 1) {
      throw DatabaseError.invalidData('WorldSessionSummary.version invalid');
    }
    if (!isWorldSessionSummaryVisibilityScope(summary.visibilityScope)) {
      throw DatabaseError.invalidData(`WorldSessionSummary.visibilityScope invalid: ${summary.visibilityScope}`);
    }
    if (summary.locationId === '') {
      throw DatabaseError.invalidData('WorldSessionSummary.locationId empty');
    }
    if (!isValidTimestamp(summary.createdAt)) {
      throw DatabaseError.invalidData('WorldSessionSummary.createdAt invalid');
    }
    if (!isValidTimestamp(summary.updatedAt)) {
      throw DatabaseError.invalidData('WorldSessionSummary.updatedAt invalid');
    }
  }
}

function summaryToBucket(summary: WorldSessionSummary): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = summary.id;
  bucket[COLUMN_WORLD_ID] = summary.worldId;
  bucket[COLUMN_SCENE_ID] = summary.sceneId;
  bucket[COLUMN_SESSION_ID_WSS] = summary.sessionId;
  bucket[COLUMN_VERSION] = summary.version;
  bucket[COLUMN_VISIBILITY_SCOPE] = summary.visibilityScope;
  bucket[COLUMN_CONTENT] = summary.content;
  bucket[COLUMN_SOURCE_MESSAGE_IDS_JSON_WSS] = summary.sourceMessageIdsJson;
  bucket[COLUMN_SOURCE_MESSAGE_COUNT] = summary.sourceMessageCount;
  bucket[COLUMN_PARTICIPANT_SNAPSHOT_JSON_WSS] = summary.participantSnapshotJson;
  bucket[COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WSS] = summary.playerDisplayNameSnapshot;
  bucket[COLUMN_LOCATION_ID_WSS] = summary.locationId;
  bucket[COLUMN_PROMPT_VERSION] = summary.promptVersion;
  bucket[COLUMN_CREATED_AT] = summary.createdAt;
  bucket[COLUMN_UPDATED_AT] = summary.updatedAt;
  return bucket;
}

function summaryFromRow(rs: relationalStore.ResultSet): WorldSessionSummary {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  const sceneId: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_ID));
  const sessionId: string = rs.getString(rs.getColumnIndex(COLUMN_SESSION_ID_WSS));
  const version: number = rs.getLong(rs.getColumnIndex(COLUMN_VERSION));
  const visibilityScopeRaw: string = rs.getString(rs.getColumnIndex(COLUMN_VISIBILITY_SCOPE));
  if (!isWorldSessionSummaryVisibilityScope(visibilityScopeRaw)) {
    throw DatabaseError.invalidData(`WorldSessionSummary.visibilityScope invalid in row: ${visibilityScopeRaw}`);
  }
  const content: string = rs.getString(rs.getColumnIndex(COLUMN_CONTENT));
  const sourceMessageIdsJson: string = rs.getString(rs.getColumnIndex(COLUMN_SOURCE_MESSAGE_IDS_JSON_WSS));
  const sourceMessageCount: number = rs.getLong(rs.getColumnIndex(COLUMN_SOURCE_MESSAGE_COUNT));
  const participantSnapshotJson: string = rs.getString(rs.getColumnIndex(COLUMN_PARTICIPANT_SNAPSHOT_JSON_WSS));
  const playerDisplayNameSnapshot: string = rs.getString(rs.getColumnIndex(COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WSS));
  const locationId: string = rs.getString(rs.getColumnIndex(COLUMN_LOCATION_ID_WSS));
  const promptVersion: string = rs.getString(rs.getColumnIndex(COLUMN_PROMPT_VERSION));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  return {
    id: id,
    worldId: worldId,
    sceneId: sceneId,
    sessionId: sessionId,
    version: version,
    visibilityScope: visibilityScopeRaw as WorldSessionSummaryVisibilityScope,
    content: content,
    sourceMessageIdsJson: sourceMessageIdsJson,
    sourceMessageCount: sourceMessageCount,
    participantSnapshotJson: participantSnapshotJson,
    playerDisplayNameSnapshot: playerDisplayNameSnapshot,
    locationId: locationId,
    promptVersion: promptVersion,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
