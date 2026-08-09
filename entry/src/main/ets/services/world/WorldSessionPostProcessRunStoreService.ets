import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldSessionPostProcessRunRepository } from '../../repositories/world/WorldSessionPostProcessRunRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import {
  WorldSessionPostProcessRun,
  WorldSessionPostProcessRunStatus,
  WorldSessionPostProcessStepStatus,
  WorldSessionPostProcessResultCode,
  WorldSessionPostProcessErrorKind,
  WorldSessionPostProcessState,
  WorldSessionPostProcessStepState,
  WorldSessionPostProcessOwnerState,
  WorldSessionPostProcessRelationshipPairState,
  WORLD_SESSION_POST_PROCESS_RUN_ID_PREFIX,
  WORLD_SESSION_POST_PROCESS_PIPELINE_VERSION,
  createInitialPostProcessState,
  serializePostProcessState,
  parsePostProcessState,
  isValidRunStatus,
  isValidStepStatus,
  isValidResultCode,
  isValidErrorKind,
  isSummaryResultCode,
  isMemoryResultCode,
  isEventResultCode,
  isKnownEventResultCode,
  isRelationshipResultCode
} from '../../models/world/WorldSessionPostProcessRun';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { DatabaseError } from '../../models/DatabaseError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';

export class WorldSessionPostProcessRunStoreService {
  private readonly runRepo: WorldSessionPostProcessRunRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    runRepo: WorldSessionPostProcessRunRepository,
    sessionRepo: WorldConversationSessionRepository,
    dbHelper: DbHelper
  ) {
    this.runRepo = runRepo;
    this.sessionRepo = sessionRepo;
    this.dbHelper = dbHelper;
  }

  async getOrCreateForEndedSession(
    worldId: string,
    sceneId: string,
    sessionId: string
  ): Promise<WorldSessionPostProcessRun> {
    if (worldId === '' || sceneId === '' || sessionId === '') {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.getOrCreateForEndedSession: empty param');
    }
    const session: WorldConversationSession | null =
      await this.sessionRepo.getById(sessionId);
    if (session === null) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService: session not found');
    }
    if (session.status !== WorldConversationSessionStatus.Ended) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService: session not ended');
    }

    const existing: WorldSessionPostProcessRun | null =
      await this.runRepo.getBySession(sessionId);
    if (existing !== null) {
      return existing;
    }

    const participantIds: string[] = this.extractParticipantIds(session);
    if (participantIds.length === 0) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService: no participants');
    }

    const now: number = nowMillis();
    const initialState: WorldSessionPostProcessState =
      createInitialPostProcessState(participantIds, now);
    const stateJson: string = serializePostProcessState(initialState);

    const run: WorldSessionPostProcessRun = {
      id: WORLD_SESSION_POST_PROCESS_RUN_ID_PREFIX + generateUuid(),
      worldId: worldId,
      sceneId: sceneId,
      sessionId: sessionId,
      pipelineVersion: WORLD_SESSION_POST_PROCESS_PIPELINE_VERSION,
      status: WorldSessionPostProcessRunStatus.Pending,
      stateJson: stateJson,
      attemptCount: 0,
      revision: 1,
      createdAt: now,
      updatedAt: now,
      completedAt: undefined
    };

    await this.runRepo.insertWithStore(this.dbHelper.getStore(), run);
    return run;
  }

  async getBySession(sessionId: string): Promise<WorldSessionPostProcessRun | null> {
    return this.runRepo.getBySession(sessionId);
  }

  async getById(runId: string): Promise<WorldSessionPostProcessRun | null> {
    return this.runRepo.getById(runId);
  }

  async listIncompleteByWorld(worldId: string): Promise<WorldSessionPostProcessRun[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return this.runRepo.listIncompleteByWorldWithStore(store, worldId);
  }

  async listRunningByWorld(worldId: string): Promise<WorldSessionPostProcessRun[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return this.runRepo.listRunningByWorldWithStore(store, worldId);
  }

  async listRecentByWorld(worldId: string, limit: number): Promise<WorldSessionPostProcessRun[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return this.runRepo.listRecentByWorldWithStore(store, worldId, limit);
  }

  async beginAttempt(runId: string): Promise<WorldSessionPostProcessRun> {
    let result: WorldSessionPostProcessRun | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldSessionPostProcessRun | null =
          await this.runRepo.getByIdWithStore(store, runId);
        if (existing === null) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.beginAttempt: not found');
        }
        if (existing.status !== WorldSessionPostProcessRunStatus.Pending &&
            existing.status !== WorldSessionPostProcessRunStatus.Running) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.beginAttempt: already completed');
        }
        const now: number = nowMillis();
        const updated: WorldSessionPostProcessRun = {
          id: existing.id,
          worldId: existing.worldId,
          sceneId: existing.sceneId,
          sessionId: existing.sessionId,
          pipelineVersion: existing.pipelineVersion,
          status: WorldSessionPostProcessRunStatus.Running,
          stateJson: existing.stateJson,
          attemptCount: existing.attemptCount + 1,
          revision: existing.revision + 1,
          createdAt: existing.createdAt,
          updatedAt: now,
          completedAt: undefined
        };
        const ok: boolean = await this.runRepo.updateWithRevisionWithStore(
          store, updated, existing.revision
        );
        if (!ok) {
          throw DatabaseError.constraintFailed(
            'WorldSessionPostProcessRunStoreService.beginAttempt: revision conflict'
          );
        }
        result = updated;
      },
      'world_post_process_run_begin'
    );
    if (result === null) {
      throw DatabaseError.transactionFailed('transaction produced no result');
    }
    return result;
  }

  async markSummarySucceeded(
    runId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isSummaryResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markSummarySucceeded: invalid resultCode');
    }
    return this.updateStepWithStore(runId, (state: WorldSessionPostProcessState): WorldSessionPostProcessState => {
      const now: number = nowMillis();
      const newSummary: WorldSessionPostProcessStepState = {
        status: WorldSessionPostProcessStepStatus.Succeeded,
        resultCode: resultCode,
        errorKind: undefined,
        updatedAt: now
      };
      return {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: newSummary,
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
    }, updatedStateJson);
  }

  async markSummarySkipped(
    runId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isSummaryResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markSummarySkipped: invalid resultCode');
    }
    return this.updateStepWithStore(runId, (state: WorldSessionPostProcessState): WorldSessionPostProcessState => {
      const now: number = nowMillis();
      const newSummary: WorldSessionPostProcessStepState = {
        status: WorldSessionPostProcessStepStatus.Skipped,
        resultCode: resultCode,
        errorKind: undefined,
        updatedAt: now
      };
      return {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: newSummary,
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
    }, updatedStateJson);
  }

  async markSummaryFailed(
    runId: string,
    errorKind: WorldSessionPostProcessErrorKind,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isValidErrorKind(errorKind)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markSummaryFailed: invalid errorKind');
    }
    return this.updateStepWithStore(runId, (state: WorldSessionPostProcessState): WorldSessionPostProcessState => {
      const now: number = nowMillis();
      const newSummary: WorldSessionPostProcessStepState = {
        status: WorldSessionPostProcessStepStatus.Failed,
        resultCode: undefined,
        errorKind: errorKind,
        updatedAt: now
      };
      return {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: newSummary,
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
    }, updatedStateJson);
  }

  async markMemorySucceeded(
    runId: string,
    ownerCharacterInstanceId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isMemoryResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markMemorySucceeded: invalid resultCode');
    }
    return this.updateOwnerStepWithStore(runId, ownerCharacterInstanceId,
      WorldSessionPostProcessStepStatus.Succeeded, resultCode, undefined, updatedStateJson);
  }

  async markMemorySkipped(
    runId: string,
    ownerCharacterInstanceId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isMemoryResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markMemorySkipped: invalid resultCode');
    }
    return this.updateOwnerStepWithStore(runId, ownerCharacterInstanceId,
      WorldSessionPostProcessStepStatus.Skipped, resultCode, undefined, updatedStateJson);
  }

  async markMemoryFailed(
    runId: string,
    ownerCharacterInstanceId: string,
    errorKind: WorldSessionPostProcessErrorKind,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isValidErrorKind(errorKind)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markMemoryFailed: invalid errorKind');
    }
    return this.updateOwnerStepWithStore(runId, ownerCharacterInstanceId,
      WorldSessionPostProcessStepStatus.Failed, undefined, errorKind, updatedStateJson);
  }

  async markEventExtractionSucceeded(
    runId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isEventResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markEventExtractionSucceeded: invalid resultCode');
    }
    return this.updateStepWithStore(runId, (state: WorldSessionPostProcessState): WorldSessionPostProcessState => {
      const now: number = nowMillis();
      const newStep: WorldSessionPostProcessStepState = {
        status: WorldSessionPostProcessStepStatus.Succeeded,
        resultCode: resultCode,
        errorKind: undefined,
        updatedAt: now
      };
      return {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: newStep,
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
    }, updatedStateJson);
  }

  async markEventExtractionSkipped(
    runId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isEventResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markEventExtractionSkipped: invalid resultCode');
    }
    return this.updateStepWithStore(runId, (state: WorldSessionPostProcessState): WorldSessionPostProcessState => {
      const now: number = nowMillis();
      const newStep: WorldSessionPostProcessStepState = {
        status: WorldSessionPostProcessStepStatus.Skipped,
        resultCode: resultCode,
        errorKind: undefined,
        updatedAt: now
      };
      return {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: newStep,
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
    }, updatedStateJson);
  }

  async markEventExtractionFailed(
    runId: string,
    errorKind: WorldSessionPostProcessErrorKind,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isValidErrorKind(errorKind)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markEventExtractionFailed: invalid errorKind');
    }
    return this.updateStepWithStore(runId, (state: WorldSessionPostProcessState): WorldSessionPostProcessState => {
      const now: number = nowMillis();
      const newStep: WorldSessionPostProcessStepState = {
        status: WorldSessionPostProcessStepStatus.Failed,
        resultCode: undefined,
        errorKind: errorKind,
        updatedAt: now
      };
      return {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: newStep,
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
    }, updatedStateJson);
  }

  async markKnownEventsSucceeded(
    runId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isKnownEventResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markKnownEventsSucceeded: invalid resultCode');
    }
    return this.updateStepWithStore(runId, (state: WorldSessionPostProcessState): WorldSessionPostProcessState => {
      const now: number = nowMillis();
      const newStep: WorldSessionPostProcessStepState = {
        status: WorldSessionPostProcessStepStatus.Succeeded,
        resultCode: resultCode,
        errorKind: undefined,
        updatedAt: now
      };
      return {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: newStep,
        relationships: state.relationships
      };
    }, updatedStateJson);
  }

  async markKnownEventsSkipped(
    runId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isKnownEventResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markKnownEventsSkipped: invalid resultCode');
    }
    return this.updateStepWithStore(runId, (state: WorldSessionPostProcessState): WorldSessionPostProcessState => {
      const now: number = nowMillis();
      const newStep: WorldSessionPostProcessStepState = {
        status: WorldSessionPostProcessStepStatus.Skipped,
        resultCode: resultCode,
        errorKind: undefined,
        updatedAt: now
      };
      return {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: newStep,
        relationships: state.relationships
      };
    }, updatedStateJson);
  }

  async markKnownEventsFailed(
    runId: string,
    errorKind: WorldSessionPostProcessErrorKind,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isValidErrorKind(errorKind)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markKnownEventsFailed: invalid errorKind');
    }
    return this.updateStepWithStore(runId, (state: WorldSessionPostProcessState): WorldSessionPostProcessState => {
      const now: number = nowMillis();
      const newStep: WorldSessionPostProcessStepState = {
        status: WorldSessionPostProcessStepStatus.Failed,
        resultCode: undefined,
        errorKind: errorKind,
        updatedAt: now
      };
      return {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: newStep,
        relationships: state.relationships
      };
    }, updatedStateJson);
  }

  async markRelationshipPairSucceeded(
    runId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isRelationshipResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markRelationshipPairSucceeded: invalid resultCode');
    }
    return this.updatePairStepWithStore(runId, ownerCharacterInstanceId, targetCharacterInstanceId,
      WorldSessionPostProcessStepStatus.Succeeded, resultCode, undefined, updatedStateJson);
  }

  async markRelationshipPairSkipped(
    runId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string,
    resultCode: WorldSessionPostProcessResultCode,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isRelationshipResultCode(resultCode)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markRelationshipPairSkipped: invalid resultCode');
    }
    return this.updatePairStepWithStore(runId, ownerCharacterInstanceId, targetCharacterInstanceId,
      WorldSessionPostProcessStepStatus.Skipped, resultCode, undefined, updatedStateJson);
  }

  async markRelationshipPairFailed(
    runId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string,
    errorKind: WorldSessionPostProcessErrorKind,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    if (!isValidErrorKind(errorKind)) {
      throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.markRelationshipPairFailed: invalid errorKind');
    }
    return this.updatePairStepWithStore(runId, ownerCharacterInstanceId, targetCharacterInstanceId,
      WorldSessionPostProcessStepStatus.Failed, undefined, errorKind, updatedStateJson);
  }

  async recoverInterruptedRuns(): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const runningRuns: WorldSessionPostProcessRun[] =
      await this.runRepo.listAllRunningWithStore(store);
    let recovered: number = 0;
    for (let i = 0; i < runningRuns.length; i++) {
      const run: WorldSessionPostProcessRun = runningRuns[i];
      try {
        const state: WorldSessionPostProcessState = parsePostProcessState(run.stateJson);
        const recoveredState: WorldSessionPostProcessState = resetRunningToPending(state);
        const recoveredStateJson: string = serializePostProcessState(recoveredState);
        const now: number = nowMillis();
        const updated: WorldSessionPostProcessRun = {
          id: run.id,
          worldId: run.worldId,
          sceneId: run.sceneId,
          sessionId: run.sessionId,
          pipelineVersion: run.pipelineVersion,
          status: WorldSessionPostProcessRunStatus.Pending,
          stateJson: recoveredStateJson,
          attemptCount: run.attemptCount,
          revision: run.revision + 1,
          createdAt: run.createdAt,
          updatedAt: now,
          completedAt: undefined
        };
        const ok: boolean = await this.runRepo.updateWithRevisionWithStore(
          store, updated, run.revision
        );
        if (ok) {
          recovered++;
        }
      } catch (_err) {
        // 单个 Run 恢复失败不阻塞其余 Run 的恢复。
        // revision conflict 表示该 Run 已被其他进程更新,跳过即可。
      }
    }
    return recovered;
  }

  async recoverInterruptedRun(runId: string): Promise<boolean> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const run: WorldSessionPostProcessRun | null =
      await this.runRepo.getByIdWithStore(store, runId);
    if (run === null || run.status !== WorldSessionPostProcessRunStatus.Running) {
      return false;
    }
    try {
      const state: WorldSessionPostProcessState = parsePostProcessState(run.stateJson);
      const recoveredState: WorldSessionPostProcessState = resetRunningToPending(state);
      const recoveredStateJson: string = serializePostProcessState(recoveredState);
      const now: number = nowMillis();
      const updated: WorldSessionPostProcessRun = {
        id: run.id,
        worldId: run.worldId,
        sceneId: run.sceneId,
        sessionId: run.sessionId,
        pipelineVersion: run.pipelineVersion,
        status: WorldSessionPostProcessRunStatus.Pending,
        stateJson: recoveredStateJson,
        attemptCount: run.attemptCount,
        revision: run.revision + 1,
        createdAt: run.createdAt,
        updatedAt: now,
        completedAt: undefined
      };
      return await this.runRepo.updateWithRevisionWithStore(store, updated, run.revision);
    } catch (_err) {
      return false;
    }
  }

  async finalizeRun(runId: string): Promise<WorldSessionPostProcessRun> {
    let result: WorldSessionPostProcessRun | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldSessionPostProcessRun | null =
          await this.runRepo.getByIdWithStore(store, runId);
        if (existing === null) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.finalizeRun: not found');
        }
        const state: WorldSessionPostProcessState = parsePostProcessState(existing.stateJson);
        if (hasNonTerminalSteps(state)) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.finalizeRun: has pending/running steps');
        }
        const hasFailed: boolean = hasAnyFailedStep(state);
        const finalStatus: WorldSessionPostProcessRunStatus = hasFailed
          ? WorldSessionPostProcessRunStatus.CompletedWithErrors
          : WorldSessionPostProcessRunStatus.Completed;
        const now: number = nowMillis();
        const updated: WorldSessionPostProcessRun = {
          id: existing.id,
          worldId: existing.worldId,
          sceneId: existing.sceneId,
          sessionId: existing.sessionId,
          pipelineVersion: existing.pipelineVersion,
          status: finalStatus,
          stateJson: existing.stateJson,
          attemptCount: existing.attemptCount,
          revision: existing.revision + 1,
          createdAt: existing.createdAt,
          updatedAt: now,
          completedAt: now
        };
        const ok: boolean = await this.runRepo.updateWithRevisionWithStore(
          store, updated, existing.revision
        );
        if (!ok) {
          throw DatabaseError.constraintFailed(
            'WorldSessionPostProcessRunStoreService.finalizeRun: revision conflict'
          );
        }
        result = updated;
      },
      'world_post_process_run_finalize'
    );
    if (result === null) {
      throw DatabaseError.transactionFailed('finalizeRun: transaction produced no result');
    }
    return result;
  }

  async deleteByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<number> {
    return this.runRepo.deleteByWorldIdWithStore(store, worldId);
  }

  async deleteBySessionIdWithStore(
    store: relationalStore.RdbStore,
    sessionId: string
  ): Promise<number> {
    return this.runRepo.deleteBySessionIdWithStore(store, sessionId);
  }

  private extractParticipantIds(session: WorldConversationSession): string[] {
    const snapshots = deserializeParticipantSnapshots(session.participantSnapshotJson);
    const ids: string[] = [];
    for (let i = 0; i < snapshots.length; i++) {
      if (snapshots[i].isActiveAtStart) {
        ids.push(snapshots[i].characterInstanceId);
      }
    }
    return ids;
  }

  private async updateStepWithStore(
    runId: string,
    stateUpdater: (state: WorldSessionPostProcessState) => WorldSessionPostProcessState,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    let result: WorldSessionPostProcessRun | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldSessionPostProcessRun | null =
          await this.runRepo.getByIdWithStore(store, runId);
        if (existing === null) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.updateStep: not found');
        }
        if (existing.status !== WorldSessionPostProcessRunStatus.Running) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.updateStep: not running');
        }
        const now: number = nowMillis();
        const updated: WorldSessionPostProcessRun = {
          id: existing.id,
          worldId: existing.worldId,
          sceneId: existing.sceneId,
          sessionId: existing.sessionId,
          pipelineVersion: existing.pipelineVersion,
          status: existing.status,
          stateJson: updatedStateJson,
          attemptCount: existing.attemptCount,
          revision: existing.revision + 1,
          createdAt: existing.createdAt,
          updatedAt: now,
          completedAt: existing.completedAt
        };
        const ok: boolean = await this.runRepo.updateWithRevisionWithStore(
          store, updated, existing.revision
        );
        if (!ok) {
          throw DatabaseError.constraintFailed(
            'WorldSessionPostProcessRunStoreService.updateStep: revision conflict'
          );
        }
        result = updated;
      },
      'world_post_process_run_mark'
    );
    if (result === null) {
      throw DatabaseError.transactionFailed('updateStep: transaction produced no result');
    }
    return result;
  }

  private async updateOwnerStepWithStore(
    runId: string,
    ownerCharacterInstanceId: string,
    status: WorldSessionPostProcessStepStatus,
    resultCode: WorldSessionPostProcessResultCode | undefined,
    errorKind: WorldSessionPostProcessErrorKind | undefined,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    let result: WorldSessionPostProcessRun | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldSessionPostProcessRun | null =
          await this.runRepo.getByIdWithStore(store, runId);
        if (existing === null) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.updateOwnerStep: not found');
        }
        if (existing.status !== WorldSessionPostProcessRunStatus.Running) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.updateOwnerStep: not running');
        }
        const state: WorldSessionPostProcessState = parsePostProcessState(existing.stateJson);
        const now: number = nowMillis();
        const updatedMemories: WorldSessionPostProcessOwnerState[] = [];
        let found: boolean = false;
        for (let i = 0; i < state.memories.length; i++) {
          const m: WorldSessionPostProcessOwnerState = state.memories[i];
          if (m.ownerCharacterInstanceId === ownerCharacterInstanceId) {
            updatedMemories.push({
              ownerCharacterInstanceId: m.ownerCharacterInstanceId,
              status: status,
              resultCode: resultCode,
              errorKind: errorKind,
              updatedAt: now
            });
            found = true;
          } else {
            updatedMemories.push(m);
          }
        }
        if (!found) {
          throw DatabaseError.invalidData(
            'WorldSessionPostProcessRunStoreService.updateOwnerStep: owner not found'
          );
        }
        const updated: WorldSessionPostProcessRun = {
          id: existing.id,
          worldId: existing.worldId,
          sceneId: existing.sceneId,
          sessionId: existing.sessionId,
          pipelineVersion: existing.pipelineVersion,
          status: existing.status,
          stateJson: updatedStateJson,
          attemptCount: existing.attemptCount,
          revision: existing.revision + 1,
          createdAt: existing.createdAt,
          updatedAt: now,
          completedAt: existing.completedAt
        };
        const ok: boolean = await this.runRepo.updateWithRevisionWithStore(
          store, updated, existing.revision
        );
        if (!ok) {
          throw DatabaseError.constraintFailed(
            'WorldSessionPostProcessRunStoreService.updateOwnerStep: revision conflict'
          );
        }
        result = updated;
      },
      'world_post_process_run_mark'
    );
    if (result === null) {
      throw DatabaseError.transactionFailed('updateOwnerStep: transaction produced no result');
    }
    return result;
  }

  private async updatePairStepWithStore(
    runId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string,
    status: WorldSessionPostProcessStepStatus,
    resultCode: WorldSessionPostProcessResultCode | undefined,
    errorKind: WorldSessionPostProcessErrorKind | undefined,
    updatedStateJson: string
  ): Promise<WorldSessionPostProcessRun> {
    let result: WorldSessionPostProcessRun | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldSessionPostProcessRun | null =
          await this.runRepo.getByIdWithStore(store, runId);
        if (existing === null) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.updatePairStep: not found');
        }
        if (existing.status !== WorldSessionPostProcessRunStatus.Running) {
          throw DatabaseError.invalidData('WorldSessionPostProcessRunStoreService.updatePairStep: not running');
        }
        const state: WorldSessionPostProcessState = parsePostProcessState(existing.stateJson);
        const now: number = nowMillis();
        const updatedPairs: WorldSessionPostProcessRelationshipPairState[] = [];
        let found: boolean = false;
        for (let i = 0; i < state.relationships.length; i++) {
          const p: WorldSessionPostProcessRelationshipPairState = state.relationships[i];
          if (p.ownerCharacterInstanceId === ownerCharacterInstanceId &&
              p.targetCharacterInstanceId === targetCharacterInstanceId) {
            updatedPairs.push({
              ownerCharacterInstanceId: p.ownerCharacterInstanceId,
              targetCharacterInstanceId: p.targetCharacterInstanceId,
              status: status,
              resultCode: resultCode,
              errorKind: errorKind,
              updatedAt: now
            });
            found = true;
          } else {
            updatedPairs.push(p);
          }
        }
        if (!found) {
          throw DatabaseError.invalidData(
            'WorldSessionPostProcessRunStoreService.updatePairStep: pair not found'
          );
        }
        const updated: WorldSessionPostProcessRun = {
          id: existing.id,
          worldId: existing.worldId,
          sceneId: existing.sceneId,
          sessionId: existing.sessionId,
          pipelineVersion: existing.pipelineVersion,
          status: existing.status,
          stateJson: updatedStateJson,
          attemptCount: existing.attemptCount,
          revision: existing.revision + 1,
          createdAt: existing.createdAt,
          updatedAt: now,
          completedAt: existing.completedAt
        };
        const ok: boolean = await this.runRepo.updateWithRevisionWithStore(
          store, updated, existing.revision
        );
        if (!ok) {
          throw DatabaseError.constraintFailed(
            'WorldSessionPostProcessRunStoreService.updatePairStep: revision conflict'
          );
        }
        result = updated;
      },
      'world_post_process_run_mark'
    );
    if (result === null) {
      throw DatabaseError.transactionFailed('updatePairStep: transaction produced no result');
    }
    return result;
  }
}

function resetRunningToPending(state: WorldSessionPostProcessState): WorldSessionPostProcessState {
  const now: number = nowMillis();
  const resetStep = (step: WorldSessionPostProcessStepState): WorldSessionPostProcessStepState => {
    if (step.status === WorldSessionPostProcessStepStatus.Running) {
      return {
        status: WorldSessionPostProcessStepStatus.Pending,
        resultCode: undefined,
        errorKind: undefined,
        updatedAt: now
      };
    }
    return step;
  };
  const resetOwner = (owner: WorldSessionPostProcessOwnerState): WorldSessionPostProcessOwnerState => {
    if (owner.status === WorldSessionPostProcessStepStatus.Running) {
      return {
        ownerCharacterInstanceId: owner.ownerCharacterInstanceId,
        status: WorldSessionPostProcessStepStatus.Pending,
        resultCode: undefined,
        errorKind: undefined,
        updatedAt: now
      };
    }
    return owner;
  };
  const resetPair = (pair: WorldSessionPostProcessRelationshipPairState): WorldSessionPostProcessRelationshipPairState => {
    if (pair.status === WorldSessionPostProcessStepStatus.Running) {
      return {
        ownerCharacterInstanceId: pair.ownerCharacterInstanceId,
        targetCharacterInstanceId: pair.targetCharacterInstanceId,
        status: WorldSessionPostProcessStepStatus.Pending,
        resultCode: undefined,
        errorKind: undefined,
        updatedAt: now
      };
    }
    return pair;
  };
  const updatedMemories: WorldSessionPostProcessOwnerState[] = [];
  for (let i = 0; i < state.memories.length; i++) {
    updatedMemories.push(resetOwner(state.memories[i]));
  }
  const updatedPairs: WorldSessionPostProcessRelationshipPairState[] = [];
  for (let i = 0; i < state.relationships.length; i++) {
    updatedPairs.push(resetPair(state.relationships[i]));
  }
  return {
    participantCharacterInstanceIds: state.participantCharacterInstanceIds,
    summary: resetStep(state.summary),
    memories: updatedMemories,
    eventExtraction: resetStep(state.eventExtraction),
    knownEvents: resetStep(state.knownEvents),
    relationships: updatedPairs
  };
}

function hasNonTerminalSteps(state: WorldSessionPostProcessState): boolean {
  const isNonTerminal = (s: WorldSessionPostProcessStepStatus): boolean => {
    return s === WorldSessionPostProcessStepStatus.Pending ||
           s === WorldSessionPostProcessStepStatus.Running;
  };
  if (isNonTerminal(state.summary.status)) {
    return true;
  }
  for (let i = 0; i < state.memories.length; i++) {
    if (isNonTerminal(state.memories[i].status)) {
      return true;
    }
  }
  if (isNonTerminal(state.eventExtraction.status)) {
    return true;
  }
  if (isNonTerminal(state.knownEvents.status)) {
    return true;
  }
  for (let i = 0; i < state.relationships.length; i++) {
    if (isNonTerminal(state.relationships[i].status)) {
      return true;
    }
  }
  return false;
}

function hasAnyFailedStep(state: WorldSessionPostProcessState): boolean {
  if (state.summary.status === WorldSessionPostProcessStepStatus.Failed) {
    return true;
  }
  for (let i = 0; i < state.memories.length; i++) {
    if (state.memories[i].status === WorldSessionPostProcessStepStatus.Failed) {
      return true;
    }
  }
  if (state.eventExtraction.status === WorldSessionPostProcessStepStatus.Failed) {
    return true;
  }
  if (state.knownEvents.status === WorldSessionPostProcessStepStatus.Failed) {
    return true;
  }
  for (let i = 0; i < state.relationships.length; i++) {
    if (state.relationships[i].status === WorldSessionPostProcessStepStatus.Failed) {
      return true;
    }
  }
  return false;
}
