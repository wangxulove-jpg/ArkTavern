import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldPlayerProfileRepository } from '../../repositories/world/WorldPlayerProfileRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import {
  World,
  WorldStatus
} from '../../models/world/World';
import {
  WorldScene,
  WorldSceneStatus
} from '../../models/world/WorldScene';
import {
  WorldCharacterInstance
} from '../../models/world/WorldCharacterInstance';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  WorldSessionParticipantSnapshot,
  createWorldConversationSessionRecord,
  serializeParticipantSnapshots,
  WORLD_CONVERSATION_SESSION_ID_PREFIX
} from '../../models/world/WorldConversationSession';
import {
  WorldConversationSessionError
} from '../../models/world/WorldConversationSessionError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';

export interface StartSessionOptions {
  readonly worldId: string;
  readonly sceneId: string;
  readonly participantCharacterInstanceIds: string[];
  readonly previousSessionId?: string;
  readonly startedAt?: number;
}

export interface EndSessionOptions {
  readonly worldId: string;
  readonly sessionId: string;
  readonly endedAt?: number;
}

export class WorldConversationSessionService {
  private readonly worldRepo: WorldRepository;
  private readonly profileRepo: WorldPlayerProfileRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    worldRepo: WorldRepository,
    profileRepo: WorldPlayerProfileRepository,
    sceneRepo: WorldSceneRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sessionRepo: WorldConversationSessionRepository,
    dbHelper: DbHelper
  ) {
    this.worldRepo = worldRepo;
    this.profileRepo = profileRepo;
    this.sceneRepo = sceneRepo;
    this.instanceRepo = instanceRepo;
    this.sessionRepo = sessionRepo;
    this.dbHelper = dbHelper;
  }

  async startSession(options: StartSessionOptions): Promise<WorldConversationSession> {
    const trimmedIds: string[] = validateAndTrimParticipantIds(options);
    let result: WorldConversationSession | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        result = await this.startSessionWithStore(store, options, trimmedIds);
      },
      'world_session_start'
    );
    if (result === null) {
      throw WorldConversationSessionError.internal('事务未产生结果');
    }
    return result;
  }

  async startSessionWithStore(
    store: relationalStore.RdbStore,
    options: StartSessionOptions,
    trimmedIds: string[],
    sceneOverride?: WorldScene
  ): Promise<WorldConversationSession> {
    if (options.worldId === '') {
      throw WorldConversationSessionError.worldNotFound();
    }
    if (options.sceneId === '') {
      throw WorldConversationSessionError.sceneNotFound();
    }
    if (trimmedIds.length === 0) {
      throw WorldConversationSessionError.noParticipants();
    }

    const world: World | null = await this.worldRepo.getByIdWithStore(store, options.worldId);
    if (world === null) {
      throw WorldConversationSessionError.worldNotFound();
    }
    if (world.status !== WorldStatus.Active) {
      throw WorldConversationSessionError.worldNotActive();
    }

    // 同事务内新建场景时,RDB 查询可能看不到尚未提交的 insert,
    // 因此允许调用方直接传入已创建的场景对象,避免重查。
    const scene: WorldScene | null =
      sceneOverride !== undefined ? sceneOverride : await this.sceneRepo.getByIdWithStore(store, options.sceneId);
    if (scene === null) {
      throw WorldConversationSessionError.sceneNotFound();
    }
    if (scene.worldId !== options.worldId) {
      throw WorldConversationSessionError.sceneWorldMismatch();
    }
    if (scene.status !== WorldSceneStatus.Active) {
      throw WorldConversationSessionError.sceneNotActive();
    }

    const profile = await this.profileRepo.getByWorldIdWithStore(store, options.worldId);
    if (profile === null) {
      throw WorldConversationSessionError.playerProfileNotFound();
    }
    const playerDisplayNameSnapshot: string = profile.displayName;

    const activeSession: WorldConversationSession | null =
      await this.sessionRepo.getActiveBySceneIdWithStore(store, options.sceneId);
    if (activeSession !== null) {
      throw WorldConversationSessionError.activeSessionAlreadyExists(activeSession.id);
    }

    const snapshots: WorldSessionParticipantSnapshot[] = [];
    for (let i = 0; i < trimmedIds.length; i++) {
      const instanceId: string = trimmedIds[i];
      const instance: WorldCharacterInstance | null =
        await this.instanceRepo.getByIdWithStore(store, instanceId);
      if (instance === null) {
        throw WorldConversationSessionError.participantNotFound();
      }
      if (instance.worldId !== options.worldId) {
        throw WorldConversationSessionError.participantWorldMismatch();
      }
      if (!instance.isActive) {
        throw WorldConversationSessionError.participantInactive();
      }
      if (instance.currentLocationId !== scene.locationId) {
        throw WorldConversationSessionError.participantLocationMismatch();
      }
      const snapshot: WorldSessionParticipantSnapshot = {
        characterInstanceId: instance.id,
        displayNameSnapshot: instance.displayNameSnapshot,
        locationIdAtStart: instance.currentLocationId,
        isActiveAtStart: instance.isActive,
        joinedAt: options.startedAt !== undefined ? options.startedAt : nowMillis()
      };
      snapshots.push(snapshot);
    }

    if (options.previousSessionId !== undefined) {
      const prevId: string = options.previousSessionId.trim();
      if (prevId !== '') {
        const prevSession: WorldConversationSession | null =
          await this.sessionRepo.getByIdWithStore(store, prevId);
        if (prevSession === null) {
          throw WorldConversationSessionError.previousSessionNotFound();
        }
        if (prevSession.worldId !== options.worldId) {
          throw WorldConversationSessionError.previousSessionWorldMismatch();
        }
        if (prevSession.sceneId !== options.sceneId) {
          throw WorldConversationSessionError.previousSessionSceneMismatch();
        }
        if (prevSession.status !== WorldConversationSessionStatus.Ended) {
          throw WorldConversationSessionError.previousSessionNotEnded();
        }
      }
    }

    const sequenceNumber: number =
      await this.sessionRepo.nextSequenceNumberForSceneWithStore(store, options.sceneId);
    const startedAt: number = options.startedAt !== undefined ? options.startedAt : nowMillis();
    const participantJson: string = serializeParticipantSnapshots(snapshots);

    const session: WorldConversationSession = createWorldConversationSessionRecord({
      id: WORLD_CONVERSATION_SESSION_ID_PREFIX + generateUuid(),
      worldId: options.worldId,
      sceneId: options.sceneId,
      sequenceNumber: sequenceNumber,
      status: WorldConversationSessionStatus.Active,
      participantSnapshotJson: participantJson,
      playerDisplayNameSnapshot: playerDisplayNameSnapshot,
      createdAt: startedAt,
      updatedAt: startedAt
    });
    await this.sessionRepo.insertWithStore(store, session);
    return session;
  }

  async getActiveSessionWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    sceneId: string
  ): Promise<WorldConversationSession | null> {
    if (worldId === '') {
      throw WorldConversationSessionError.worldNotFound();
    }
    if (sceneId === '') {
      throw WorldConversationSessionError.sceneNotFound();
    }
    const scene: WorldScene | null = await this.sceneRepo.getByIdWithStore(store, sceneId);
    if (scene === null) {
      throw WorldConversationSessionError.sceneNotFound();
    }
    if (scene.worldId !== worldId) {
      throw WorldConversationSessionError.sceneWorldMismatch();
    }
    const active: WorldConversationSession | null =
      await this.sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
    return active;
  }

  async getActiveSessionForScene(worldId: string, sceneId: string): Promise<WorldConversationSession | null> {
    if (worldId === '') {
      throw WorldConversationSessionError.worldNotFound();
    }
    if (sceneId === '') {
      throw WorldConversationSessionError.sceneNotFound();
    }
    let result: WorldConversationSession | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const scene: WorldScene | null = await this.sceneRepo.getByIdWithStore(store, sceneId);
        if (scene === null) {
          throw WorldConversationSessionError.sceneNotFound();
        }
        if (scene.worldId !== worldId) {
          throw WorldConversationSessionError.sceneWorldMismatch();
        }
        const active: WorldConversationSession | null =
          await this.sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
        result = active;
      },
      'world_session_continue'
    );
    return result;
  }

  async endSession(options: EndSessionOptions): Promise<WorldConversationSession> {
    if (options.worldId === '') {
      throw WorldConversationSessionError.worldNotFound();
    }
    if (options.sessionId === '') {
      throw WorldConversationSessionError.sessionNotFound();
    }
    let result: WorldConversationSession | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const session: WorldConversationSession | null =
          await this.sessionRepo.getByIdWithStore(store, options.sessionId);
        if (session === null) {
          throw WorldConversationSessionError.sessionNotFound();
        }
        if (session.worldId !== options.worldId) {
          throw WorldConversationSessionError.sessionWorldMismatch();
        }
        const scene: WorldScene | null = await this.sceneRepo.getByIdWithStore(store, session.sceneId);
        if (scene === null) {
          throw WorldConversationSessionError.sceneNotFound();
        }
        if (session.status === WorldConversationSessionStatus.Ended) {
          result = session;
          return;
        }
        const endedAt: number = options.endedAt !== undefined ? options.endedAt : nowMillis();
        if (endedAt < session.createdAt) {
          throw WorldConversationSessionError.invalidEndedAt();
        }
        const now: number = nowMillis();
        const ended: WorldConversationSession = createWorldConversationSessionRecord({
          id: session.id,
          worldId: session.worldId,
          sceneId: session.sceneId,
          sequenceNumber: session.sequenceNumber,
          status: WorldConversationSessionStatus.Ended,
          participantSnapshotJson: session.participantSnapshotJson,
          playerDisplayNameSnapshot: session.playerDisplayNameSnapshot,
          createdAt: session.createdAt,
          updatedAt: now
        });
        await this.sessionRepo.updateWithStore(store, ended);
        result = ended;
      },
      'world_session_end'
    );
    if (result === null) {
      throw WorldConversationSessionError.internal('事务未产生结果');
    }
    return result;
  }
}

export function validateAndTrimParticipantIds(options: StartSessionOptions): string[] {
  if (options.participantCharacterInstanceIds.length === 0) {
    throw WorldConversationSessionError.noParticipants();
  }
  const trimmedIds: string[] = [];
  for (let i = 0; i < options.participantCharacterInstanceIds.length; i++) {
    const trimmed: string = options.participantCharacterInstanceIds[i].trim();
    if (trimmed === '') {
      throw WorldConversationSessionError.noParticipants();
    }
    if (trimmed === 'user') {
      throw WorldConversationSessionError.participantNotFound();
    }
    trimmedIds.push(trimmed);
  }
  const seenIds: Set<string> = new Set<string>();
  for (let i = 0; i < trimmedIds.length; i++) {
    if (seenIds.has(trimmedIds[i])) {
      throw WorldConversationSessionError.duplicateParticipant(trimmedIds[i]);
    }
    seenIds.add(trimmedIds[i]);
  }
  return trimmedIds;
}
