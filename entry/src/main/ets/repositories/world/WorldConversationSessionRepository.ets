import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldConversationSession, WorldConversationSessionStatus, isWorldConversationSessionStatus } from '../../models/world/WorldConversationSession';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_CONVERSATION_SESSIONS,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_SCENE_ID,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_STATUS,
  COLUMN_PARTICIPANT_SNAPSHOT_JSON,
  COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldConversationSessionRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldConversationSession | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldConversationSession.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldConversationSession | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldConversationSession.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return sessionFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listBySceneId(sceneId: string): Promise<WorldConversationSession[]> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.listBySceneId: sceneId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldConversationSession[] = [];
      while (rs.goToNextRow()) {
        list.push(sessionFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async getActiveBySceneId(sceneId: string): Promise<WorldConversationSession | null> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.getActiveBySceneId: sceneId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getActiveBySceneIdWithStore(store, sceneId);
  }

  async getActiveBySceneIdWithStore(
    store: relationalStore.RdbStore,
    sceneId: string
  ): Promise<WorldConversationSession | null> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.getActiveBySceneIdWithStore: sceneId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    predicates.equalTo(COLUMN_STATUS, WorldConversationSessionStatus.Active);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldConversationSession[] = [];
      while (rs.goToNextRow()) {
        list.push(sessionFromRow(rs));
      }
      if (list.length > 1) {
        throw DatabaseError.invalidData(
          `WorldConversationSession.getActiveBySceneId: multiple Active sessions found for sceneId=${sceneId}`
        );
      }
      if (list.length === 0) {
        return null;
      }
      return list[0];
    } finally {
      rs.close();
    }
  }

  async insert(session: WorldConversationSession): Promise<void> {
    this.validateSession(session);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_CONVERSATION_SESSIONS, sessionToBucket(session));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldConversationSession.insert');
      }
      throw DatabaseError.queryFailed(`WorldConversationSession.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWithStore(store: relationalStore.RdbStore, session: WorldConversationSession): Promise<void> {
    this.validateSession(session);
    try {
      await store.insert(TABLE_WORLD_CONVERSATION_SESSIONS, sessionToBucket(session));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('WorldConversationSession.insertWithStore');
      }
      throw DatabaseError.queryFailed(`WorldConversationSession.insertWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async update(session: WorldConversationSession): Promise<void> {
    this.validateSession(session);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_ID, session.id);
    let affected: number;
    try {
      affected = await store.update(sessionToBucket(session), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldConversationSession.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldConversationSession.update');
    }
  }

  async updateWithStore(store: relationalStore.RdbStore, session: WorldConversationSession): Promise<void> {
    this.validateSession(session);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_ID, session.id);
    let affected: number;
    try {
      affected = await store.update(sessionToBucket(session), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldConversationSession.updateWithStore: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('WorldConversationSession.updateWithStore');
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldConversationSession.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldConversationSession.deleteById: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByIdWithStore(store: relationalStore.RdbStore, id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldConversationSession.deleteByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldConversationSession.deleteByIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteByWorldId(worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.deleteByWorldId: worldId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.deleteByWorldIdWithStore(store, worldId);
  }

  async deleteByWorldIdWithStore(store: relationalStore.RdbStore, worldId: string): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldConversationSession.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async deleteBySceneIdWithStore(store: relationalStore.RdbStore, sceneId: string): Promise<void> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.deleteBySceneIdWithStore: sceneId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldConversationSession.deleteBySceneIdWithStore: ${extractCauseMessage(err)}`);
    }
  }

  async nextSequenceNumberForSceneWithStore(
    store: relationalStore.RdbStore,
    sceneId: string
  ): Promise<number> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.nextSequenceNumberForSceneWithStore: sceneId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    predicates.orderByDesc(COLUMN_SEQUENCE_NUMBER);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return 1;
      }
      return rs.getLong(rs.getColumnIndex(COLUMN_SEQUENCE_NUMBER)) + 1;
    } finally {
      rs.close();
    }
  }

  async getLatestBySceneIdWithStore(
    store: relationalStore.RdbStore,
    sceneId: string
  ): Promise<WorldConversationSession | null> {
    if (sceneId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.getLatestBySceneIdWithStore: sceneId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CONVERSATION_SESSIONS);
    predicates.equalTo(COLUMN_SCENE_ID, sceneId);
    predicates.orderByDesc(COLUMN_SEQUENCE_NUMBER);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return sessionFromRow(rs);
    } finally {
      rs.close();
    }
  }

  private validateSession(session: WorldConversationSession): void {
    if (session.id === '') {
      throw DatabaseError.invalidData('WorldConversationSession.id empty');
    }
    if (session.worldId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.worldId empty');
    }
    if (session.sceneId === '') {
      throw DatabaseError.invalidData('WorldConversationSession.sceneId empty');
    }
    if (!Number.isFinite(session.sequenceNumber) || !Number.isInteger(session.sequenceNumber) || session.sequenceNumber < 0) {
      throw DatabaseError.invalidData('WorldConversationSession.sequenceNumber invalid');
    }
    if (!isWorldConversationSessionStatus(session.status)) {
      throw DatabaseError.invalidData(`WorldConversationSession.status invalid: ${session.status}`);
    }
    if (!isValidTimestamp(session.createdAt)) {
      throw DatabaseError.invalidData('WorldConversationSession.createdAt invalid');
    }
    if (!isValidTimestamp(session.updatedAt)) {
      throw DatabaseError.invalidData('WorldConversationSession.updatedAt invalid');
    }
  }
}

function sessionToBucket(session: WorldConversationSession): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = session.id;
  bucket[COLUMN_WORLD_ID] = session.worldId;
  bucket[COLUMN_SCENE_ID] = session.sceneId;
  bucket[COLUMN_SEQUENCE_NUMBER] = session.sequenceNumber;
  bucket[COLUMN_STATUS] = session.status;
  bucket[COLUMN_PARTICIPANT_SNAPSHOT_JSON] = session.participantSnapshotJson;
  bucket[COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT] = session.playerDisplayNameSnapshot;
  bucket[COLUMN_CREATED_AT] = session.createdAt;
  bucket[COLUMN_UPDATED_AT] = session.updatedAt;
  return bucket;
}

function readOptionalString(rs: relationalStore.ResultSet, columnName: string): string {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return '';
  }
  if (rs.isColumnNull(col)) {
    return '';
  }
  return rs.getString(col);
}

function sessionFromRow(rs: relationalStore.ResultSet): WorldConversationSession {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldConversationSession.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldConversationSession.worldId empty in row');
  }
  const sceneId: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_ID));
  if (sceneId === '') {
    throw DatabaseError.invalidData('WorldConversationSession.sceneId empty in row');
  }
  const sequenceNumber: number = rs.getLong(rs.getColumnIndex(COLUMN_SEQUENCE_NUMBER));
  const statusRaw: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  if (!isWorldConversationSessionStatus(statusRaw)) {
    throw DatabaseError.invalidData(`WorldConversationSession.status invalid in row: ${statusRaw}`);
  }
  const participantSnapshotJson: string = readOptionalString(rs, COLUMN_PARTICIPANT_SNAPSHOT_JSON);
  const playerDisplayNameSnapshot: string = readOptionalString(rs, COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT);
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldConversationSession.createdAt invalid in row');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('WorldConversationSession.updatedAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    sceneId: sceneId,
    sequenceNumber: sequenceNumber,
    status: statusRaw as WorldConversationSessionStatus,
    participantSnapshotJson: participantSnapshotJson,
    playerDisplayNameSnapshot: playerDisplayNameSnapshot,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
