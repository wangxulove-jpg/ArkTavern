import { WorldSessionPostProcessRunStoreService } from './WorldSessionPostProcessRunStoreService';
import { WorldCrossSessionContextService } from './WorldCrossSessionContextService';
import { WorldCharacterMemoryStoreService } from './WorldCharacterMemoryStoreService';
import { WorldKnownEventStoreService } from './WorldKnownEventStoreService';
import { WorldDirectionalRelationshipStoreService } from './WorldDirectionalRelationshipStoreService';
import { WorldEventStoreService } from './WorldEventStoreService';
import { WorldConversationSessionService } from './WorldConversationSessionService';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import {
  WorldSessionPostProcessRun,
  WorldSessionPostProcessState,
  parsePostProcessState
} from '../../models/world/WorldSessionPostProcessRun';
import {
  WorldCrossSessionContextSnapshot,
  WorldCrossSessionContextRequest
} from '../../models/world/WorldCrossSessionContext';
import { WorldCharacterMemoryEntry } from '../../models/world/WorldCharacterMemoryEntry';
import { WorldKnownEventEntry } from '../../models/world/WorldKnownEventEntry';
import { WorldDirectionalRelationshipEntry } from '../../models/world/WorldDirectionalRelationshipEntry';
import { WorldEventEntry } from '../../models/world/WorldEventExtraction';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldScene } from '../../models/world/WorldScene';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';

export interface InspectorPipelineRun {
  readonly run: WorldSessionPostProcessRun;
  readonly state: WorldSessionPostProcessState;
}

export interface InspectorSpeakerContext {
  readonly snapshot: WorldCrossSessionContextSnapshot;
  readonly totalDisplayChars: number;
}

export interface InspectorSpeakerContextError {
  readonly errorCategory: string;
}

export interface InspectorCharacterDossier {
  readonly instance: WorldCharacterInstance;
  readonly currentLocation: WorldScene | null;
  readonly memories: WorldCharacterMemoryEntry[];
  readonly knownEvents: WorldKnownEventEntry[];
  readonly relationships: WorldDirectionalRelationshipEntry[];
}

export interface InspectorSessionInfo {
  readonly session: WorldConversationSession;
  readonly scene: WorldScene | null;
  readonly participants: WorldSessionParticipantSnapshot[];
}

const RECENT_RUN_LIMIT: number = 30;

export class WorldInspectorService {
  private readonly runStoreService: WorldSessionPostProcessRunStoreService;
  private readonly crossSessionContextService: WorldCrossSessionContextService;
  private readonly memoryStoreService: WorldCharacterMemoryStoreService;
  private readonly knownEventStoreService: WorldKnownEventStoreService;
  private readonly relationshipStoreService: WorldDirectionalRelationshipStoreService;
  private readonly eventStoreService: WorldEventStoreService;
  private readonly sessionService: WorldConversationSessionService;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly characterInstanceRepo: WorldCharacterInstanceRepository;

  constructor(
    runStoreService: WorldSessionPostProcessRunStoreService,
    crossSessionContextService: WorldCrossSessionContextService,
    memoryStoreService: WorldCharacterMemoryStoreService,
    knownEventStoreService: WorldKnownEventStoreService,
    relationshipStoreService: WorldDirectionalRelationshipStoreService,
    eventStoreService: WorldEventStoreService,
    sessionService: WorldConversationSessionService,
    sessionRepo: WorldConversationSessionRepository,
    sceneRepo: WorldSceneRepository,
    characterInstanceRepo: WorldCharacterInstanceRepository
  ) {
    this.runStoreService = runStoreService;
    this.crossSessionContextService = crossSessionContextService;
    this.memoryStoreService = memoryStoreService;
    this.knownEventStoreService = knownEventStoreService;
    this.relationshipStoreService = relationshipStoreService;
    this.eventStoreService = eventStoreService;
    this.sessionService = sessionService;
    this.sessionRepo = sessionRepo;
    this.sceneRepo = sceneRepo;
    this.characterInstanceRepo = characterInstanceRepo;
  }

  async listRecentPipelineRuns(worldId: string): Promise<InspectorPipelineRun[]> {
    const runs: WorldSessionPostProcessRun[] =
      await this.runStoreService.listRecentByWorld(worldId, RECENT_RUN_LIMIT);
    const results: InspectorPipelineRun[] = [];
    for (let i = 0; i < runs.length; i++) {
      const run: WorldSessionPostProcessRun = runs[i];
      try {
        const state: WorldSessionPostProcessState = parsePostProcessState(run.stateJson);
        results.push({ run: run, state: state });
      } catch (_err) {
        results.push({ run: run, state: parsePostProcessState(run.stateJson) });
      }
    }
    return results;
  }

  async getPipelineRunBySession(sessionId: string): Promise<InspectorPipelineRun | null> {
    const run: WorldSessionPostProcessRun | null =
      await this.runStoreService.getBySession(sessionId);
    if (run === null) {
      return null;
    }
    const state: WorldSessionPostProcessState = parsePostProcessState(run.stateJson);
    return { run: run, state: state };
  }

  async getActiveSessionForScene(
    worldId: string,
    sceneId: string
  ): Promise<InspectorSessionInfo | null> {
    const session: WorldConversationSession | null =
      await this.sessionService.getActiveSessionForScene(worldId, sceneId);
    if (session === null) {
      return null;
    }
    return this.buildSessionInfo(session);
  }

  async getSessionById(sessionId: string): Promise<InspectorSessionInfo | null> {
    const session: WorldConversationSession | null =
      await this.sessionRepo.getById(sessionId);
    if (session === null) {
      return null;
    }
    return this.buildSessionInfo(session);
  }

  async prepareSpeakerContext(
    worldId: string,
    sceneId: string,
    sessionId: string,
    speakerCharacterInstanceId: string
  ): Promise<InspectorSpeakerContext | InspectorSpeakerContextError> {
    const request: WorldCrossSessionContextRequest = {
      worldId: worldId,
      sceneId: sceneId,
      sessionId: sessionId,
      speakerCharacterInstanceId: speakerCharacterInstanceId
    };
    try {
      const snapshot: WorldCrossSessionContextSnapshot =
        await this.crossSessionContextService.prepareContext(request);
      let totalChars: number = 0;
      for (let i = 0; i < snapshot.summaries.length; i++) {
        totalChars += snapshot.summaries[i].summaryText.length;
      }
      for (let i = 0; i < snapshot.memories.length; i++) {
        totalChars += snapshot.memories[i].memoryText.length;
      }
      return { snapshot: snapshot, totalDisplayChars: totalChars };
    } catch (err) {
      const msg: string = (err instanceof Error) ? err.message : 'Unknown';
      const safeCategory: string = this.safeErrorCategory(msg);
      return { errorCategory: safeCategory };
    }
  }

  async getCharacterDossier(
    worldId: string,
    instanceId: string
  ): Promise<InspectorCharacterDossier | null> {
    const instance: WorldCharacterInstance | null =
      await this.characterInstanceRepo.getById(instanceId);
    if (instance === null) {
      return null;
    }
    let currentLocation: WorldScene | null = null;
    if (instance.currentLocationId !== undefined && instance.currentLocationId.length > 0) {
      currentLocation = await this.sceneRepo.getById(instance.currentLocationId);
    }
    const memories: WorldCharacterMemoryEntry[] =
      await this.memoryStoreService.listActiveMemoriesForOwner(worldId, instanceId);
    const knownEvents: WorldKnownEventEntry[] =
      await this.knownEventStoreService.listActiveKnownEventsByOwner(worldId, instanceId);
    const relationships: WorldDirectionalRelationshipEntry[] =
      await this.relationshipStoreService.listActiveRelationshipsByOwner(worldId, instanceId);
    return {
      instance: instance,
      currentLocation: currentLocation,
      memories: memories,
      knownEvents: knownEvents,
      relationships: relationships
    };
  }

  async listWorldCharacterInstances(worldId: string): Promise<WorldCharacterInstance[]> {
    return this.characterInstanceRepo.listByWorld(worldId);
  }

  async listSessionEvents(worldId: string, sessionId: string): Promise<WorldEventEntry[]> {
    return this.eventStoreService.listCurrentEventsForSession(worldId, sessionId);
  }

  private async buildSessionInfo(
    session: WorldConversationSession
  ): Promise<InspectorSessionInfo> {
    let scene: WorldScene | null = null;
    if (session.sceneId.length > 0) {
      scene = await this.sceneRepo.getById(session.sceneId);
    }
    let participants: WorldSessionParticipantSnapshot[] = [];
    try {
      participants = deserializeParticipantSnapshots(session.participantSnapshotJson);
    } catch (_err) {
      participants = [];
    }
    return { session: session, scene: scene, participants: participants };
  }

  private safeErrorCategory(rawMessage: string): string {
    if (rawMessage.indexOf('not found') >= 0) {
      return 'DataUnavailable';
    }
    if (rawMessage.indexOf('not ended') >= 0 ||
        rawMessage.indexOf('must be Active') >= 0) {
      return 'InvalidState';
    }
    if (rawMessage.indexOf('not in current session') >= 0 ||
        rawMessage.indexOf('not in') >= 0) {
      return 'Unauthorized';
    }
    if (rawMessage.indexOf('mismatch') >= 0) {
      return 'ConsistencyError';
    }
    return 'ContextUnavailable';
  }
}
