import { WorldSessionPostProcessRunStoreService } from './WorldSessionPostProcessRunStoreService';
import { WorldSessionSummaryGenerationService, WorldSessionSummaryGenerationStatus, WorldSessionSummaryGenerationError, WorldSessionSummaryGenerationErrorKind } from './WorldSessionSummaryGenerationService';
import { WorldCharacterMemoryGenerationService, WorldCharacterMemoryGenerationOptions, WorldCharacterMemoryGenerationStatus } from './WorldCharacterMemoryGenerationService';
import { WorldEventExtractionGenerationService, WorldEventExtractionGenerationOptions, WorldEventExtractionGenerationStatus, WorldEventExtractionGenerationError, WorldEventExtractionGenerationErrorKind } from './WorldEventExtractionGenerationService';
import { WorldKnownEventStoreService } from './WorldKnownEventStoreService';
import { WorldDirectionalRelationshipGenerationService, WorldDirectionalRelationshipPairGenerationOptions, WorldDirectionalRelationshipPairGenerationStatus, MAX_RELATIONSHIP_PAIR_GENERATIONS_PER_BATCH } from './WorldDirectionalRelationshipGenerationService';
import { WorldEventStoreService } from './WorldEventStoreService';
import {
  WorldSessionPostProcessRun,
  WorldSessionPostProcessRunStatus,
  WorldSessionPostProcessStepStatus,
  WorldSessionPostProcessResultCode,
  WorldSessionPostProcessErrorKind,
  WorldSessionPostProcessState,
  WorldSessionPostProcessOwnerState,
  WorldSessionPostProcessRelationshipPairState,
  parsePostProcessState,
  serializePostProcessState
} from '../../models/world/WorldSessionPostProcessRun';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'PostProcessOrch';

const RELATIONSHIP_PAIR_CAP: number = MAX_RELATIONSHIP_PAIR_GENERATIONS_PER_BATCH;

export class WorldSessionPostProcessingOrchestrator {
  private readonly runStoreService: WorldSessionPostProcessRunStoreService;
  private readonly summaryGenerationService: WorldSessionSummaryGenerationService;
  private readonly memoryGenerationService: WorldCharacterMemoryGenerationService;
  private readonly eventGenerationService: WorldEventExtractionGenerationService;
  private readonly knownEventStoreService: WorldKnownEventStoreService;
  private readonly relationshipGenerationService: WorldDirectionalRelationshipGenerationService;
  private readonly eventStoreService: WorldEventStoreService;

  private readonly activeSessions: Set<string> = new Set();

  constructor(
    runStoreService: WorldSessionPostProcessRunStoreService,
    summaryGenerationService: WorldSessionSummaryGenerationService,
    memoryGenerationService: WorldCharacterMemoryGenerationService,
    eventGenerationService: WorldEventExtractionGenerationService,
    knownEventStoreService: WorldKnownEventStoreService,
    relationshipGenerationService: WorldDirectionalRelationshipGenerationService,
    eventStoreService: WorldEventStoreService
  ) {
    this.runStoreService = runStoreService;
    this.summaryGenerationService = summaryGenerationService;
    this.memoryGenerationService = memoryGenerationService;
    this.eventGenerationService = eventGenerationService;
    this.knownEventStoreService = knownEventStoreService;
    this.relationshipGenerationService = relationshipGenerationService;
    this.eventStoreService = eventStoreService;
  }

  startEndedSessionProcessing(
    worldId: string,
    sceneId: string,
    sessionId: string
  ): void {
    this.processEndedSession(worldId, sceneId, sessionId).catch((): void => {
      // 内部 catch,不产生 unhandled rejection。
    });
  }

  async processEndedSession(
    worldId: string,
    sceneId: string,
    sessionId: string
  ): Promise<void> {
    const activeKey: string = worldId + ':' + sessionId;
    if (this.activeSessions.has(activeKey)) {
      Logger.info(LOG_TAG, 'processEndedSession: already active key=' + activeKey.substring(0, 16));
      return;
    }
    this.activeSessions.add(activeKey);
    try {
      const run: WorldSessionPostProcessRun =
        await this.runStoreService.getOrCreateForEndedSession(worldId, sceneId, sessionId);
      if (run.status === WorldSessionPostProcessRunStatus.Completed
          || run.status === WorldSessionPostProcessRunStatus.CompletedWithErrors) {
        Logger.info(LOG_TAG, 'processEndedSession: run terminal runId=' + run.id.substring(0, 16)
          + ' status=' + run.status);
        return;
      }
      if (run.status === WorldSessionPostProcessRunStatus.Running) {
        Logger.info(LOG_TAG, 'processEndedSession: run already running runId=' + run.id.substring(0, 16));
        return;
      }
      const attemptRun: WorldSessionPostProcessRun =
        await this.runStoreService.beginAttempt(run.id);
      await this.executePipeline(attemptRun);
    } catch (err) {
      this.logSafeError('processEndedSession', worldId, sessionId, err);
    } finally {
      this.activeSessions.delete(activeKey);
    }
  }

  startResumeIncompleteForWorld(worldId: string): void {
    this.resumeIncompleteForWorld(worldId).catch((): void => {
      // 内部 catch,不产生 unhandled rejection。
    });
  }

  async resumeIncompleteForWorld(worldId: string): Promise<void> {
    try {
      const recovered: number = await this.runStoreService.recoverInterruptedRuns();
      if (recovered > 0) {
        Logger.info(LOG_TAG, 'resumeIncomplete: recovered ' + recovered.toString() + ' interrupted runs');
      }
      const incompleteRuns: WorldSessionPostProcessRun[] =
        await this.runStoreService.listIncompleteByWorld(worldId);
      for (let i = 0; i < incompleteRuns.length; i++) {
        const run: WorldSessionPostProcessRun = incompleteRuns[i];
        if (run.status === WorldSessionPostProcessRunStatus.Completed
            || run.status === WorldSessionPostProcessRunStatus.CompletedWithErrors) {
          continue;
        }
        const activeKey: string = run.worldId + ':' + run.sessionId;
        if (this.activeSessions.has(activeKey)) {
          Logger.info(LOG_TAG, 'resumeIncomplete: skip active key=' + activeKey.substring(0, 16));
          continue;
        }
        if (run.status === WorldSessionPostProcessRunStatus.Running) {
          Logger.info(LOG_TAG, 'resumeIncomplete: interrupted runId=' + run.id.substring(0, 16));
          this.startEndedSessionProcessing(run.worldId, run.sceneId, run.sessionId);
          continue;
        }
        if (run.status === WorldSessionPostProcessRunStatus.Pending) {
          Logger.info(LOG_TAG, 'resumeIncomplete: pending runId=' + run.id.substring(0, 16));
          this.startEndedSessionProcessing(run.worldId, run.sceneId, run.sessionId);
        }
      }
    } catch (err) {
      this.logSafeError('resumeIncompleteForWorld', worldId, '', err);
    }
  }

  private async executePipeline(run: WorldSessionPostProcessRun): Promise<void> {
    let currentRun: WorldSessionPostProcessRun = run;

    currentRun = await this.executeSummaryStage(currentRun);
    if (currentRun.status !== WorldSessionPostProcessRunStatus.Running) {
      return;
    }

    currentRun = await this.executeMemoryStage(currentRun);
    if (currentRun.status !== WorldSessionPostProcessRunStatus.Running) {
      return;
    }

    currentRun = await this.executeEventStage(currentRun);
    if (currentRun.status !== WorldSessionPostProcessRunStatus.Running) {
      return;
    }

    currentRun = await this.executeKnownEventStage(currentRun);
    if (currentRun.status !== WorldSessionPostProcessRunStatus.Running) {
      return;
    }

    currentRun = await this.executeRelationshipStage(currentRun);
    if (currentRun.status !== WorldSessionPostProcessRunStatus.Running) {
      return;
    }

    try {
      await this.runStoreService.finalizeRun(currentRun.id);
      Logger.info(LOG_TAG, 'executePipeline: finalized runId=' + currentRun.id.substring(0, 16));
    } catch (err) {
      this.logSafeError('finalizeRun', currentRun.worldId, currentRun.sessionId, err);
    }
  }

  private async executeSummaryStage(
    run: WorldSessionPostProcessRun
  ): Promise<WorldSessionPostProcessRun> {
    const state: WorldSessionPostProcessState = parsePostProcessState(run.stateJson);
    if (state.summary.status !== WorldSessionPostProcessStepStatus.Pending) {
      return run;
    }
    try {
      const result = await this.summaryGenerationService.generateSummary(run.sessionId);
      if (result.status === WorldSessionSummaryGenerationStatus.NoPublicContent) {
        const updatedState: WorldSessionPostProcessState = {
          participantCharacterInstanceIds: state.participantCharacterInstanceIds,
          summary: {
            status: WorldSessionPostProcessStepStatus.Skipped,
            resultCode: WorldSessionPostProcessResultCode.NoPublicContent,
            errorKind: undefined,
            updatedAt: this.now()
          },
          memories: state.memories,
          eventExtraction: state.eventExtraction,
          knownEvents: state.knownEvents,
          relationships: state.relationships
        };
        return await this.runStoreService.markSummarySkipped(
          run.id, WorldSessionPostProcessResultCode.NoPublicContent,
          serializePostProcessState(updatedState));
      }
      const resultCode: WorldSessionPostProcessResultCode =
        this.mapSummaryStatus(result.status);
      const updatedState: WorldSessionPostProcessState = {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: {
          status: WorldSessionPostProcessStepStatus.Succeeded,
          resultCode: resultCode,
          errorKind: undefined,
          updatedAt: this.now()
        },
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
      return await this.runStoreService.markSummarySucceeded(
        run.id, resultCode, serializePostProcessState(updatedState));
    } catch (err) {
      const errorKind: WorldSessionPostProcessErrorKind = this.mapErrorKind(err);
      const updatedState: WorldSessionPostProcessState = {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: {
          status: WorldSessionPostProcessStepStatus.Failed,
          resultCode: undefined,
          errorKind: errorKind,
          updatedAt: this.now()
        },
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
      return await this.runStoreService.markSummaryFailed(
        run.id, errorKind, serializePostProcessState(updatedState));
    }
  }

  private async executeMemoryStage(
    run: WorldSessionPostProcessRun
  ): Promise<WorldSessionPostProcessRun> {
    const state: WorldSessionPostProcessState = parsePostProcessState(run.stateJson);
    let currentState: WorldSessionPostProcessState = state;

    for (let i = 0; i < currentState.memories.length; i++) {
      const owner: string = currentState.memories[i].ownerCharacterInstanceId;
      if (currentState.memories[i].status !== WorldSessionPostProcessStepStatus.Pending) {
        continue;
      }
      try {
        const opts: WorldCharacterMemoryGenerationOptions = {
          worldId: run.worldId,
          sceneId: run.sceneId,
          sessionId: run.sessionId,
          ownerCharacterInstanceId: owner
        };
        const result = await this.memoryGenerationService.generateForOwner(opts);
        if (result.status === WorldCharacterMemoryGenerationStatus.Generated
            || result.status === WorldCharacterMemoryGenerationStatus.Existing) {
          const resultCode: WorldSessionPostProcessResultCode =
            result.status === WorldCharacterMemoryGenerationStatus.Generated
              ? WorldSessionPostProcessResultCode.Generated
              : WorldSessionPostProcessResultCode.Existing;
        const updatedMemories = this.replaceOwnerInList(currentState.memories, owner, {
          ownerCharacterInstanceId: owner,
          status: WorldSessionPostProcessStepStatus.Succeeded,
          resultCode: resultCode,
          errorKind: undefined,
          updatedAt: this.now()
        });
          currentState = {
            participantCharacterInstanceIds: currentState.participantCharacterInstanceIds,
            summary: currentState.summary,
            memories: updatedMemories,
            eventExtraction: currentState.eventExtraction,
            knownEvents: currentState.knownEvents,
            relationships: currentState.relationships
          };
          run = await this.runStoreService.markMemorySucceeded(
            run.id, owner, resultCode, serializePostProcessState(currentState));
        } else if (result.status === WorldCharacterMemoryGenerationStatus.NoVisibleEvidence) {
          const updatedMemories = this.replaceOwnerInList(currentState.memories, owner, {
            ownerCharacterInstanceId: owner,
            status: WorldSessionPostProcessStepStatus.Skipped,
            resultCode: WorldSessionPostProcessResultCode.NoVisibleEvidence,
            errorKind: undefined,
            updatedAt: this.now()
          });
          currentState = {
            participantCharacterInstanceIds: currentState.participantCharacterInstanceIds,
            summary: currentState.summary,
            memories: updatedMemories,
            eventExtraction: currentState.eventExtraction,
            knownEvents: currentState.knownEvents,
            relationships: currentState.relationships
          };
          run = await this.runStoreService.markMemorySkipped(
            run.id, owner, WorldSessionPostProcessResultCode.NoVisibleEvidence,
            serializePostProcessState(currentState));
        }
      } catch (err) {
        const errorKind: WorldSessionPostProcessErrorKind = this.mapErrorKind(err);
        const updatedMemories = this.replaceOwnerInList(currentState.memories, owner, {
          ownerCharacterInstanceId: owner,
          status: WorldSessionPostProcessStepStatus.Failed,
          resultCode: undefined,
          errorKind: errorKind,
          updatedAt: this.now()
        });
        currentState = {
          participantCharacterInstanceIds: currentState.participantCharacterInstanceIds,
          summary: currentState.summary,
          memories: updatedMemories,
          eventExtraction: currentState.eventExtraction,
          knownEvents: currentState.knownEvents,
          relationships: currentState.relationships
        };
        try {
          run = await this.runStoreService.markMemoryFailed(
            run.id, owner, errorKind, serializePostProcessState(currentState));
        } catch (checkpointErr) {
          this.logSafeError('memoryCheckpoint', run.worldId, run.sessionId, checkpointErr);
          return run;
        }
      }
      if (run.status !== WorldSessionPostProcessRunStatus.Running) {
        return run;
      }
    }
    return run;
  }

  private async executeEventStage(
    run: WorldSessionPostProcessRun
  ): Promise<WorldSessionPostProcessRun> {
    const state: WorldSessionPostProcessState = parsePostProcessState(run.stateJson);
    if (state.eventExtraction.status !== WorldSessionPostProcessStepStatus.Pending) {
      return run;
    }

    if (state.summary.status !== WorldSessionPostProcessStepStatus.Succeeded) {
      const updatedState: WorldSessionPostProcessState = {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: {
          status: WorldSessionPostProcessStepStatus.Skipped,
          resultCode: WorldSessionPostProcessResultCode.SkippedDependency,
          errorKind: undefined,
          updatedAt: this.now()
        },
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
      return await this.runStoreService.markEventExtractionSkipped(
        run.id, WorldSessionPostProcessResultCode.SkippedDependency,
        serializePostProcessState(updatedState));
    }

    try {
      const opts: WorldEventExtractionGenerationOptions = {
        worldId: run.worldId,
        sceneId: run.sceneId,
        sessionId: run.sessionId
      };
      const result = await this.eventGenerationService.generate(opts);
      const entriesCount: number = result.entries.length;
      let resultCode: WorldSessionPostProcessResultCode;
      if (result.status === WorldEventExtractionGenerationStatus.Generated) {
        resultCode = entriesCount > 0
          ? WorldSessionPostProcessResultCode.Generated
          : WorldSessionPostProcessResultCode.ZeroEvents;
      } else {
        resultCode = entriesCount > 0
          ? WorldSessionPostProcessResultCode.Existing
          : WorldSessionPostProcessResultCode.ZeroEvents;
      }
      const updatedState: WorldSessionPostProcessState = {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: {
          status: WorldSessionPostProcessStepStatus.Succeeded,
          resultCode: resultCode,
          errorKind: undefined,
          updatedAt: this.now()
        },
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
      return await this.runStoreService.markEventExtractionSucceeded(
        run.id, resultCode, serializePostProcessState(updatedState));
    } catch (err) {
      const errorKind: WorldSessionPostProcessErrorKind = this.mapErrorKind(err);
      const updatedState: WorldSessionPostProcessState = {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: {
          status: WorldSessionPostProcessStepStatus.Failed,
          resultCode: undefined,
          errorKind: errorKind,
          updatedAt: this.now()
        },
        knownEvents: state.knownEvents,
        relationships: state.relationships
      };
      return await this.runStoreService.markEventExtractionFailed(
        run.id, errorKind, serializePostProcessState(updatedState));
    }
  }

  private async executeKnownEventStage(
    run: WorldSessionPostProcessRun
  ): Promise<WorldSessionPostProcessRun> {
    const state: WorldSessionPostProcessState = parsePostProcessState(run.stateJson);
    if (state.knownEvents.status !== WorldSessionPostProcessStepStatus.Pending) {
      return run;
    }

    if (state.eventExtraction.status !== WorldSessionPostProcessStepStatus.Succeeded) {
      const updatedState: WorldSessionPostProcessState = {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: {
          status: WorldSessionPostProcessStepStatus.Skipped,
          resultCode: WorldSessionPostProcessResultCode.SkippedDependency,
          errorKind: undefined,
          updatedAt: this.now()
        },
        relationships: state.relationships
      };
      return await this.runStoreService.markKnownEventsSkipped(
        run.id, WorldSessionPostProcessResultCode.SkippedDependency,
        serializePostProcessState(updatedState));
    }

    try {
      const activeInfo = await this.eventStoreService.getActiveExtractionForSession(
        run.worldId, run.sessionId);
      if (activeInfo === null) {
        const updatedState: WorldSessionPostProcessState = {
          participantCharacterInstanceIds: state.participantCharacterInstanceIds,
          summary: state.summary,
          memories: state.memories,
          eventExtraction: state.eventExtraction,
          knownEvents: {
            status: WorldSessionPostProcessStepStatus.Failed,
            resultCode: undefined,
            errorKind: WorldSessionPostProcessErrorKind.SourceInvalid,
            updatedAt: this.now()
          },
          relationships: state.relationships
        };
        return await this.runStoreService.markKnownEventsFailed(
          run.id, WorldSessionPostProcessErrorKind.SourceInvalid,
          serializePostProcessState(updatedState));
      }
      const derivationResult = await this.knownEventStoreService.deriveKnownEventsForExtractionRun(
        run.worldId, activeInfo.run.id);
      const derivedCount: number = derivationResult.derived.length;
      let resultCode: WorldSessionPostProcessResultCode;
      let hasExisting: boolean = false;
      for (let i = 0; i < derivationResult.derived.length; i++) {
        if (derivationResult.derived[i].isExisting) {
          hasExisting = true;
          break;
        }
      }
      if (derivedCount === 0) {
        resultCode = WorldSessionPostProcessResultCode.ZeroKnownEvents;
      } else if (hasExisting) {
        resultCode = WorldSessionPostProcessResultCode.Derived;
      } else {
        resultCode = WorldSessionPostProcessResultCode.Derived;
      }
      const updatedState: WorldSessionPostProcessState = {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: {
          status: WorldSessionPostProcessStepStatus.Succeeded,
          resultCode: resultCode,
          errorKind: undefined,
          updatedAt: this.now()
        },
        relationships: state.relationships
      };
      return await this.runStoreService.markKnownEventsSucceeded(
        run.id, resultCode, serializePostProcessState(updatedState));
    } catch (err) {
      const errorKind: WorldSessionPostProcessErrorKind = this.mapErrorKind(err);
      const updatedState: WorldSessionPostProcessState = {
        participantCharacterInstanceIds: state.participantCharacterInstanceIds,
        summary: state.summary,
        memories: state.memories,
        eventExtraction: state.eventExtraction,
        knownEvents: {
          status: WorldSessionPostProcessStepStatus.Failed,
          resultCode: undefined,
          errorKind: errorKind,
          updatedAt: this.now()
        },
        relationships: state.relationships
      };
      return await this.runStoreService.markKnownEventsFailed(
        run.id, errorKind, serializePostProcessState(updatedState));
    }
  }

  private async executeRelationshipStage(
    run: WorldSessionPostProcessRun
  ): Promise<WorldSessionPostProcessRun> {
    const state: WorldSessionPostProcessState = parsePostProcessState(run.stateJson);
    let currentState: WorldSessionPostProcessState = state;

    const pendingPairs: WorldSessionPostProcessRelationshipPairState[] = [];
    for (let i = 0; i < currentState.relationships.length; i++) {
      if (currentState.relationships[i].status === WorldSessionPostProcessStepStatus.Pending) {
        pendingPairs.push(currentState.relationships[i]);
      }
    }

    if (pendingPairs.length > RELATIONSHIP_PAIR_CAP) {
      Logger.info(LOG_TAG, 'executeRelationshipStage: pair count=' + pendingPairs.length.toString()
        + ' exceeds cap=' + RELATIONSHIP_PAIR_CAP.toString() + ', marking BatchTooLarge');
      const updatedPairs: WorldSessionPostProcessRelationshipPairState[] = [];
      for (let i = 0; i < currentState.relationships.length; i++) {
        const pair: WorldSessionPostProcessRelationshipPairState = currentState.relationships[i];
        if (pair.status === WorldSessionPostProcessStepStatus.Pending) {
          updatedPairs.push({
            ownerCharacterInstanceId: pair.ownerCharacterInstanceId,
            targetCharacterInstanceId: pair.targetCharacterInstanceId,
            status: WorldSessionPostProcessStepStatus.Skipped,
            resultCode: WorldSessionPostProcessResultCode.BatchTooLarge,
            errorKind: undefined,
            updatedAt: this.now()
          });
        } else {
          updatedPairs.push(pair);
        }
      }
      currentState = {
        participantCharacterInstanceIds: currentState.participantCharacterInstanceIds,
        summary: currentState.summary,
        memories: currentState.memories,
        eventExtraction: currentState.eventExtraction,
        knownEvents: currentState.knownEvents,
        relationships: updatedPairs
      };
      try {
        run = await this.runStoreService.markRelationshipPairSkipped(
          run.id, '', '', WorldSessionPostProcessResultCode.BatchTooLarge,
          serializePostProcessState(currentState));
      } catch (_err) {
        // BatchTooLarge 标记失败不应阻断 finalize。
      }
      return run;
    }

    for (let i = 0; i < pendingPairs.length; i++) {
      const pair: WorldSessionPostProcessRelationshipPairState = pendingPairs[i];
      try {
        const opts: WorldDirectionalRelationshipPairGenerationOptions = {
          worldId: run.worldId,
          sceneId: run.sceneId,
          sessionId: run.sessionId,
          ownerCharacterInstanceId: pair.ownerCharacterInstanceId,
          targetCharacterInstanceId: pair.targetCharacterInstanceId
        };
        const result = await this.relationshipGenerationService.generateForPair(opts);
        if (result.status === WorldDirectionalRelationshipPairGenerationStatus.Generated) {
          const updatedPairs = this.replacePairInList(currentState.relationships,
            pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId, {
              ownerCharacterInstanceId: pair.ownerCharacterInstanceId,
              targetCharacterInstanceId: pair.targetCharacterInstanceId,
              status: WorldSessionPostProcessStepStatus.Succeeded,
              resultCode: WorldSessionPostProcessResultCode.Generated,
              errorKind: undefined,
              updatedAt: this.now()
            });
          currentState = this.rebuildStateWithPairs(currentState, updatedPairs);
          run = await this.runStoreService.markRelationshipPairSucceeded(
            run.id, pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId,
            WorldSessionPostProcessResultCode.Generated,
            serializePostProcessState(currentState));
        } else if (result.status === WorldDirectionalRelationshipPairGenerationStatus.Existing) {
          const updatedPairs = this.replacePairInList(currentState.relationships,
            pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId, {
              ownerCharacterInstanceId: pair.ownerCharacterInstanceId,
              targetCharacterInstanceId: pair.targetCharacterInstanceId,
              status: WorldSessionPostProcessStepStatus.Succeeded,
              resultCode: WorldSessionPostProcessResultCode.Existing,
              errorKind: undefined,
              updatedAt: this.now()
            });
          currentState = this.rebuildStateWithPairs(currentState, updatedPairs);
          run = await this.runStoreService.markRelationshipPairSucceeded(
            run.id, pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId,
            WorldSessionPostProcessResultCode.Existing,
            serializePostProcessState(currentState));
        } else if (result.status === WorldDirectionalRelationshipPairGenerationStatus.NoChange) {
          const updatedPairs = this.replacePairInList(currentState.relationships,
            pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId, {
              ownerCharacterInstanceId: pair.ownerCharacterInstanceId,
              targetCharacterInstanceId: pair.targetCharacterInstanceId,
              status: WorldSessionPostProcessStepStatus.Succeeded,
              resultCode: WorldSessionPostProcessResultCode.NoChange,
              errorKind: undefined,
              updatedAt: this.now()
            });
          currentState = this.rebuildStateWithPairs(currentState, updatedPairs);
          run = await this.runStoreService.markRelationshipPairSucceeded(
            run.id, pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId,
            WorldSessionPostProcessResultCode.NoChange,
            serializePostProcessState(currentState));
        } else if (result.status === WorldDirectionalRelationshipPairGenerationStatus.Failed) {
          const errorKind: WorldSessionPostProcessErrorKind = result.errorKind !== null
            ? this.mapRelationshipErrorKind(result.errorKind)
            : WorldSessionPostProcessErrorKind.Unknown;
          const updatedPairs = this.replacePairInList(currentState.relationships,
            pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId, {
              ownerCharacterInstanceId: pair.ownerCharacterInstanceId,
              targetCharacterInstanceId: pair.targetCharacterInstanceId,
              status: WorldSessionPostProcessStepStatus.Failed,
              resultCode: undefined,
              errorKind: errorKind,
              updatedAt: this.now()
            });
          currentState = this.rebuildStateWithPairs(currentState, updatedPairs);
          run = await this.runStoreService.markRelationshipPairFailed(
            run.id, pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId,
            errorKind, serializePostProcessState(currentState));
        }
      } catch (err) {
        const errorKind: WorldSessionPostProcessErrorKind = this.mapErrorKind(err);
        const updatedPairs = this.replacePairInList(currentState.relationships,
          pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId, {
            ownerCharacterInstanceId: pair.ownerCharacterInstanceId,
            targetCharacterInstanceId: pair.targetCharacterInstanceId,
            status: WorldSessionPostProcessStepStatus.Failed,
            resultCode: undefined,
            errorKind: errorKind,
            updatedAt: this.now()
          });
        currentState = this.rebuildStateWithPairs(currentState, updatedPairs);
        try {
          run = await this.runStoreService.markRelationshipPairFailed(
            run.id, pair.ownerCharacterInstanceId, pair.targetCharacterInstanceId,
            errorKind, serializePostProcessState(currentState));
        } catch (checkpointErr) {
          this.logSafeError('relationshipCheckpoint', run.worldId, run.sessionId, checkpointErr);
          return run;
        }
      }
      if (run.status !== WorldSessionPostProcessRunStatus.Running) {
        return run;
      }
    }
    return run;
  }

  private mapSummaryStatus(
    status: WorldSessionSummaryGenerationStatus
  ): WorldSessionPostProcessResultCode {
    if (status === WorldSessionSummaryGenerationStatus.Generated) {
      return WorldSessionPostProcessResultCode.Generated;
    }
    return WorldSessionPostProcessResultCode.Existing;
  }

  private mapErrorKind(err: Object): WorldSessionPostProcessErrorKind {
    if (err instanceof WorldSessionSummaryGenerationError) {
      return this.mapSummaryErrorKind(err.kind);
    }
    if (err instanceof WorldEventExtractionGenerationError) {
      return this.mapEventErrorKind(err.kind);
    }
    return WorldSessionPostProcessErrorKind.Unknown;
  }

  private mapSummaryErrorKind(
    kind: WorldSessionSummaryGenerationErrorKind
  ): WorldSessionPostProcessErrorKind {
    if (kind === WorldSessionSummaryGenerationErrorKind.NoModelConfiguration) {
      return WorldSessionPostProcessErrorKind.NoModelConfiguration;
    }
    if (kind === WorldSessionSummaryGenerationErrorKind.ModelRequestFailed) {
      return WorldSessionPostProcessErrorKind.ModelRequestFailed;
    }
    if (kind === WorldSessionSummaryGenerationErrorKind.ModelCancelled) {
      return WorldSessionPostProcessErrorKind.ModelCancelled;
    }
    if (kind === WorldSessionSummaryGenerationErrorKind.EmptyModelOutput
        || kind === WorldSessionSummaryGenerationErrorKind.ModelOutputTooLarge) {
      return WorldSessionPostProcessErrorKind.InvalidModelOutput;
    }
    if (kind === WorldSessionSummaryGenerationErrorKind.SourceChanged) {
      return WorldSessionPostProcessErrorKind.SourceChanged;
    }
    if (kind === WorldSessionSummaryGenerationErrorKind.SummaryPersistenceFailed) {
      return WorldSessionPostProcessErrorKind.PersistenceFailed;
    }
    if (kind === WorldSessionSummaryGenerationErrorKind.SourcePreparationFailed) {
      return WorldSessionPostProcessErrorKind.SourceInvalid;
    }
    return WorldSessionPostProcessErrorKind.Unknown;
  }

  private mapEventErrorKind(
    kind: WorldEventExtractionGenerationErrorKind
  ): WorldSessionPostProcessErrorKind {
    if (kind === WorldEventExtractionGenerationErrorKind.NoModelConfiguration) {
      return WorldSessionPostProcessErrorKind.NoModelConfiguration;
    }
    if (kind === WorldEventExtractionGenerationErrorKind.ModelRequestFailed) {
      return WorldSessionPostProcessErrorKind.ModelRequestFailed;
    }
    if (kind === WorldEventExtractionGenerationErrorKind.ModelCancelled) {
      return WorldSessionPostProcessErrorKind.ModelCancelled;
    }
    if (kind === WorldEventExtractionGenerationErrorKind.InvalidModelOutput
        || kind === WorldEventExtractionGenerationErrorKind.TooManyEvents
        || kind === WorldEventExtractionGenerationErrorKind.EventTextTooLarge
        || kind === WorldEventExtractionGenerationErrorKind.InvalidEventKind
        || kind === WorldEventExtractionGenerationErrorKind.InvalidActor
        || kind === WorldEventExtractionGenerationErrorKind.InvalidEvidence
        || kind === WorldEventExtractionGenerationErrorKind.InvalidConfidence) {
      return WorldSessionPostProcessErrorKind.InvalidModelOutput;
    }
    if (kind === WorldEventExtractionGenerationErrorKind.SourceChanged) {
      return WorldSessionPostProcessErrorKind.SourceChanged;
    }
    if (kind === WorldEventExtractionGenerationErrorKind.PersistenceFailed) {
      return WorldSessionPostProcessErrorKind.PersistenceFailed;
    }
    if (kind === WorldEventExtractionGenerationErrorKind.SourcePreparationFailed) {
      return WorldSessionPostProcessErrorKind.SourceInvalid;
    }
    if (kind === WorldEventExtractionGenerationErrorKind.NoSharedSummary) {
      return WorldSessionPostProcessErrorKind.DependencyFailed;
    }
    return WorldSessionPostProcessErrorKind.Unknown;
  }

  private mapRelationshipErrorKind(
    kind: string
  ): WorldSessionPostProcessErrorKind {
    if (kind === 'no_model_configuration') {
      return WorldSessionPostProcessErrorKind.NoModelConfiguration;
    }
    if (kind === 'model_request_failed') {
      return WorldSessionPostProcessErrorKind.ModelRequestFailed;
    }
    if (kind === 'model_cancelled') {
      return WorldSessionPostProcessErrorKind.ModelCancelled;
    }
    if (kind === 'invalid_model_output'
        || kind === 'invalid_result_field'
        || kind === 'empty_relationship_text'
        || kind === 'relationship_text_too_large'
        || kind === 'invalid_confidence'
        || kind === 'invalid_evidence_ids'
        || kind === 'unknown_evidence_id') {
      return WorldSessionPostProcessErrorKind.InvalidModelOutput;
    }
    if (kind === 'source_changed') {
      return WorldSessionPostProcessErrorKind.SourceChanged;
    }
    if (kind === 'persistence_failed') {
      return WorldSessionPostProcessErrorKind.PersistenceFailed;
    }
    if (kind === 'source_preparation_failed'
        || kind === 'no_visible_evidence'
        || kind === 'metadata_not_found'
        || kind === 'target_not_participant'
        || kind === 'owner_equals_target'
        || kind === 'session_not_found') {
      return WorldSessionPostProcessErrorKind.SourceInvalid;
    }
    return WorldSessionPostProcessErrorKind.Unknown;
  }

  private replaceOwnerInList(
    memories: WorldSessionPostProcessOwnerState[],
    ownerCharacterInstanceId: string,
    replacement: WorldSessionPostProcessOwnerState
  ): WorldSessionPostProcessOwnerState[] {
    const updated: WorldSessionPostProcessOwnerState[] = [];
    for (let i = 0; i < memories.length; i++) {
      if (memories[i].ownerCharacterInstanceId === ownerCharacterInstanceId) {
        updated.push(replacement);
      } else {
        updated.push(memories[i]);
      }
    }
    return updated;
  }

  private replacePairInList(
    pairs: WorldSessionPostProcessRelationshipPairState[],
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string,
    replacement: WorldSessionPostProcessRelationshipPairState
  ): WorldSessionPostProcessRelationshipPairState[] {
    const updated: WorldSessionPostProcessRelationshipPairState[] = [];
    for (let i = 0; i < pairs.length; i++) {
      if (pairs[i].ownerCharacterInstanceId === ownerCharacterInstanceId
          && pairs[i].targetCharacterInstanceId === targetCharacterInstanceId) {
        updated.push(replacement);
      } else {
        updated.push(pairs[i]);
      }
    }
    return updated;
  }

  private rebuildStateWithPairs(
    state: WorldSessionPostProcessState,
    updatedPairs: WorldSessionPostProcessRelationshipPairState[]
  ): WorldSessionPostProcessState {
    return {
      participantCharacterInstanceIds: state.participantCharacterInstanceIds,
      summary: state.summary,
      memories: state.memories,
      eventExtraction: state.eventExtraction,
      knownEvents: state.knownEvents,
      relationships: updatedPairs
    };
  }

  private now(): number {
    return Date.now();
  }

  private logSafeError(
    context: string,
    worldId: string,
    sessionId: string,
    err: Object
  ): void {
    const safeWorldId: string = worldId.length > 0 ? worldId.substring(0, 8) : '(empty)';
    const safeSessionId: string = sessionId.length > 0 ? sessionId.substring(0, 8) : '(empty)';
    let safeCategory: string = 'unknown';
    if (err instanceof WorldSessionSummaryGenerationError) {
      safeCategory = 'SummaryGen:' + err.kind;
    } else if (err instanceof WorldEventExtractionGenerationError) {
      safeCategory = 'EventGen:' + err.kind;
    } else {
      safeCategory = (err as Error).name || 'Error';
    }
    Logger.warn(LOG_TAG, context + ': worldId=' + safeWorldId
      + ' sessionId=' + safeSessionId + ' category=' + safeCategory);
  }
}
