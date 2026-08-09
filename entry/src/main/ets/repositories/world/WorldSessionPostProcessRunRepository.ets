import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldSessionPostProcessRun,
  WorldSessionPostProcessRunStatus,
  isValidRunStatus
} from '../../models/world/WorldSessionPostProcessRun';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_SESSION_POST_PROCESS_RUNS,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_SCENE_ID,
  COLUMN_SESSION_ID_WPPR,
  COLUMN_PIPELINE_VERSION_WPPR,
  COLUMN_STATUS,
  COLUMN_STATE_JSON_WPPR,
  COLUMN_ATTEMPT_COUNT_WPPR,
  COLUMN_REVISION_WPPR,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_COMPLETED_AT_WPPR
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from '../RepositoryMappers';

export class WorldSessionPostProcessRunRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldSessionPostProcessRun | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
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

  async getById(id: string): Promise<WorldSessionPostProcessRun | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return this.getByIdWithStore(store, id);
  }

  async getBySessionWithStore(
    store: relationalStore.RdbStore,
    sessionId: string
  ): Promise<WorldSessionPostProcessRun | null> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.getBySessionWithStore: sessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
    predicates.equalTo(COLUMN_SESSION_ID_WPPR, sessionId);
    predicates.orderByDesc(COLUMN_CREATED_AT);
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

  async getBySession(sessionId: string): Promise<WorldSessionPostProcessRun | null> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.getBySession: sessionId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return this.getBySessionWithStore(store, sessionId);
  }

  async listIncompleteByWorldWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<WorldSessionPostProcessRun[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.listIncompleteByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_STATUS, WorldSessionPostProcessRunStatus.Pending);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const results: WorldSessionPostProcessRun[] = [];
    try {
      while (rs.goToNextRow()) {
        results.push(runFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return results;
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    run: WorldSessionPostProcessRun
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_ID] = run.id;
    bucket[COLUMN_WORLD_ID] = run.worldId;
    bucket[COLUMN_SCENE_ID] = run.sceneId;
    bucket[COLUMN_SESSION_ID_WPPR] = run.sessionId;
    bucket[COLUMN_PIPELINE_VERSION_WPPR] = run.pipelineVersion;
    bucket[COLUMN_STATUS] = run.status;
    bucket[COLUMN_STATE_JSON_WPPR] = run.stateJson;
    bucket[COLUMN_ATTEMPT_COUNT_WPPR] = run.attemptCount;
    bucket[COLUMN_REVISION_WPPR] = run.revision;
    bucket[COLUMN_CREATED_AT] = run.createdAt;
    bucket[COLUMN_UPDATED_AT] = run.updatedAt;
    if (run.completedAt !== undefined) {
      bucket[COLUMN_COMPLETED_AT_WPPR] = run.completedAt;
    } else {
      bucket[COLUMN_COMPLETED_AT_WPPR] = null;
    }
    try {
      await store.insert(TABLE_WORLD_SESSION_POST_PROCESS_RUNS, bucket);
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed(
          'WorldSessionPostProcessRun.insert: duplicate id=' + run.id.substring(0, 8)
        );
      }
      throw DatabaseError.queryFailed(extractCauseMessage(err));
    }
  }

  async updateWithRevisionWithStore(
    store: relationalStore.RdbStore,
    run: WorldSessionPostProcessRun,
    expectedRevision: number
  ): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
    predicates.equalTo(COLUMN_ID, run.id);
    predicates.equalTo(COLUMN_REVISION_WPPR, expectedRevision);
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS] = run.status;
    bucket[COLUMN_STATE_JSON_WPPR] = run.stateJson;
    bucket[COLUMN_ATTEMPT_COUNT_WPPR] = run.attemptCount;
    bucket[COLUMN_REVISION_WPPR] = run.revision;
    bucket[COLUMN_UPDATED_AT] = run.updatedAt;
    if (run.completedAt !== undefined) {
      bucket[COLUMN_COMPLETED_AT_WPPR] = run.completedAt;
    } else {
      bucket[COLUMN_COMPLETED_AT_WPPR] = null;
    }
    try {
      const affected: number = await store.update(bucket, predicates);
      return affected === 1;
    } catch (err) {
      throw DatabaseError.queryFailed(extractCauseMessage(err));
    }
  }

  async deleteByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<number> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.deleteByWorldIdWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      return await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldSessionPostProcessRun.deleteByWorldId: ${extractCauseMessage(err)}`);
    }
  }

  async deleteBySessionIdWithStore(
    store: relationalStore.RdbStore,
    sessionId: string
  ): Promise<number> {
    if (sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.deleteBySessionIdWithStore: sessionId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
    predicates.equalTo(COLUMN_SESSION_ID_WPPR, sessionId);
    try {
      return await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`WorldSessionPostProcessRun.deleteBySessionId: ${extractCauseMessage(err)}`);
    }
  }

  async listByWorldWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<WorldSessionPostProcessRun[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.listByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.orderByDesc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const results: WorldSessionPostProcessRun[] = [];
    try {
      while (rs.goToNextRow()) {
        results.push(runFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return results;
  }

  async listAllRunningWithStore(
    store: relationalStore.RdbStore
  ): Promise<WorldSessionPostProcessRun[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
    predicates.equalTo(COLUMN_STATUS, WorldSessionPostProcessRunStatus.Running);
    predicates.orderByAsc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const results: WorldSessionPostProcessRun[] = [];
    try {
      while (rs.goToNextRow()) {
        results.push(runFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return results;
  }

  async listRecentByWorldWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    limit: number
  ): Promise<WorldSessionPostProcessRun[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.listRecentByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.orderByDesc(COLUMN_CREATED_AT);
    if (limit > 0) {
      predicates.limitAs(limit);
    }
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const results: WorldSessionPostProcessRun[] = [];
    try {
      while (rs.goToNextRow()) {
        results.push(runFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return results;
  }

  async listRunningByWorldWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<WorldSessionPostProcessRun[]> {
    if (worldId === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRun.listRunningByWorldWithStore: worldId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SESSION_POST_PROCESS_RUNS);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_STATUS, WorldSessionPostProcessRunStatus.Running);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const results: WorldSessionPostProcessRun[] = [];
    try {
      while (rs.goToNextRow()) {
        results.push(runFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return results;
  }
}

function runFromRow(rs: relationalStore.ResultSet): WorldSessionPostProcessRun {
  const idCol: number = rs.getColumnIndex(COLUMN_ID);
  const worldIdCol: number = rs.getColumnIndex(COLUMN_WORLD_ID);
  const sceneIdCol: number = rs.getColumnIndex(COLUMN_SCENE_ID);
  const sessionIdCol: number = rs.getColumnIndex(COLUMN_SESSION_ID_WPPR);
  const pipelineVersionCol: number = rs.getColumnIndex(COLUMN_PIPELINE_VERSION_WPPR);
  const statusCol: number = rs.getColumnIndex(COLUMN_STATUS);
  const stateJsonCol: number = rs.getColumnIndex(COLUMN_STATE_JSON_WPPR);
  const attemptCountCol: number = rs.getColumnIndex(COLUMN_ATTEMPT_COUNT_WPPR);
  const revisionCol: number = rs.getColumnIndex(COLUMN_REVISION_WPPR);
  const createdAtCol: number = rs.getColumnIndex(COLUMN_CREATED_AT);
  const updatedAtCol: number = rs.getColumnIndex(COLUMN_UPDATED_AT);
  const completedAtCol: number = rs.getColumnIndex(COLUMN_COMPLETED_AT_WPPR);

  const status: string = rs.getString(statusCol);
  if (!isValidRunStatus(status)) {
    throw DatabaseError.invalidData(`WorldSessionPostProcessRun: invalid status=${status}`);
  }

  let completedAt: number | undefined = undefined;
  if (!rs.isColumnNull(completedAtCol)) {
    const val: number = rs.getLong(completedAtCol);
    if (isValidTimestamp(val)) {
      completedAt = val;
    }
  }

  return {
    id: rs.getString(idCol),
    worldId: rs.getString(worldIdCol),
    sceneId: rs.getString(sceneIdCol),
    sessionId: rs.getString(sessionIdCol),
    pipelineVersion: rs.getString(pipelineVersionCol),
    status: status as WorldSessionPostProcessRunStatus,
    stateJson: rs.getString(stateJsonCol),
    attemptCount: rs.getLong(attemptCountCol),
    revision: rs.getLong(revisionCol),
    createdAt: rs.getLong(createdAtCol),
    updatedAt: rs.getLong(updatedAtCol),
    completedAt: completedAt
  };
}
