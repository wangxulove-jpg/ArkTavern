import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldPlayerProfileRepository } from '../../repositories/world/WorldPlayerProfileRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldSceneService } from './WorldSceneService';
import { WorldConversationSessionService, StartSessionOptions, validateAndTrimParticipantIds } from './WorldConversationSessionService';
import { World } from '../../models/world/World';
import { WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldConversationSession } from '../../models/world/WorldConversationSession';
import {
  WorldSceneLaunchError,
  WorldSceneLaunchSnapshot,
  WorldSceneLaunchTarget,
  WorldSceneLaunchResult,
  WorldSceneLaunchEligibleParticipant
} from '../../models/world/WorldSceneLaunch';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneLaunchService';

export class WorldSceneLaunchService {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly profileRepo: WorldPlayerProfileRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly sceneService: WorldSceneService;
  private readonly sessionService: WorldConversationSessionService;
  private readonly dbHelper: DbHelper;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    profileRepo: WorldPlayerProfileRepository,
    sceneRepo: WorldSceneRepository,
    sessionRepo: WorldConversationSessionRepository,
    sceneService: WorldSceneService,
    sessionService: WorldConversationSessionService,
    dbHelper: DbHelper
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.profileRepo = profileRepo;
    this.sceneRepo = sceneRepo;
    this.sessionRepo = sessionRepo;
    this.sceneService = sceneService;
    this.sessionService = sessionService;
    this.dbHelper = dbHelper;
  }

  async loadLaunchSnapshot(worldId: string, locationId: string): Promise<WorldSceneLaunchSnapshot> {
    if (worldId === '') {
      throw WorldSceneLaunchError.worldNotFound();
    }
    if (locationId === '') {
      throw WorldSceneLaunchError.locationNotFound();
    }

    const world: World | null = await this.worldRepo.getById(worldId);
    if (world === null) {
      throw WorldSceneLaunchError.worldNotFound();
    }
    if (world.status !== WorldStatus.Active) {
      throw WorldSceneLaunchError.worldNotActive();
    }

    const location: WorldLocation | null = await this.locationRepo.getById(locationId);
    if (location === null) {
      throw WorldSceneLaunchError.locationNotFound();
    }
    if (location.worldId !== worldId) {
      throw WorldSceneLaunchError.locationNotFound();
    }
    if (location.status !== WorldLocationStatus.Active) {
      throw WorldSceneLaunchError.locationArchived();
    }

    const existingActiveScene: WorldScene | null =
      await this.sceneRepo.findActiveByWorldAndLocation(worldId, locationId);

    let existingActiveSession: WorldConversationSession | null = null;
    if (existingActiveScene !== null) {
      existingActiveSession = await this.sessionRepo.getActiveBySceneId(existingActiveScene.id);
    }

    const allInstances: WorldCharacterInstance[] =
      await this.instanceRepo.listByLocation(worldId, locationId);
    const eligibleParticipants: WorldSceneLaunchEligibleParticipant[] = [];
    for (let i = 0; i < allInstances.length; i++) {
      const inst: WorldCharacterInstance = allInstances[i];
      if (inst.isActive && inst.currentLocationId === locationId) {
        eligibleParticipants.push({
          characterInstanceId: inst.id,
          displayNameSnapshot: inst.displayNameSnapshot
        });
      }
    }

    const snapshot: WorldSceneLaunchSnapshot = {
      worldId: worldId,
      locationId: locationId,
      locationName: location.name,
      existingActiveScene: existingActiveScene,
      existingActiveSession: existingActiveSession,
      eligibleParticipants: eligibleParticipants
    };
    return snapshot;
  }

  async launchSceneSession(target: WorldSceneLaunchTarget): Promise<WorldSceneLaunchResult> {
    if (target.worldId === '') {
      throw WorldSceneLaunchError.worldNotFound();
    }
    if (target.locationId === '') {
      throw WorldSceneLaunchError.locationNotFound();
    }
    if (target.participantCharacterInstanceIds.length === 0) {
      throw WorldSceneLaunchError.noEligibleParticipants();
    }

    const trimmedIds: string[] = preValidateParticipantIds(target.participantCharacterInstanceIds);

    let result: WorldSceneLaunchResult | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        result = await this.launchSceneSessionInStore(store, target, trimmedIds);
      },
      'world_scene_launch'
    );
    if (result === null) {
      throw WorldSceneLaunchError.internal('事务未产生结果');
    }
    Logger.info(LOG_TAG, `launchSceneSession ok`);
    return result;
  }

  async continueActiveSession(worldId: string, sceneId: string): Promise<WorldSceneLaunchResult> {
    if (worldId === '') {
      throw WorldSceneLaunchError.worldNotFound();
    }
    if (sceneId === '') {
      throw WorldSceneLaunchError.sceneAlreadyEnded();
    }

    let result: WorldSceneLaunchResult | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const scene: WorldScene | null = await this.sceneRepo.getByIdWithStore(store, sceneId);
        if (scene === null) {
          throw WorldSceneLaunchError.sceneAlreadyEnded();
        }
        if (scene.worldId !== worldId) {
          throw WorldSceneLaunchError.sceneAlreadyEnded();
        }
        if (scene.status === WorldSceneStatus.Ended) {
          throw WorldSceneLaunchError.sceneAlreadyEnded();
        }
        const activeSession: WorldConversationSession | null =
          await this.sessionService.getActiveSessionWithStore(store, worldId, sceneId);
        if (activeSession === null) {
          throw WorldSceneLaunchError.activeSessionAlreadyExists('');
        }
        result = {
          scene: scene,
          session: activeSession,
          isNewScene: false,
          isNewSession: false
        };
      },
      'world_scene_launch'
    );
    if (result === null) {
      throw WorldSceneLaunchError.internal('事务未产生结果');
    }
    return result;
  }

  private async launchSceneSessionInStore(
    store: relationalStore.RdbStore,
    target: WorldSceneLaunchTarget,
    trimmedIds: string[]
  ): Promise<WorldSceneLaunchResult> {
    const world: World | null = await this.worldRepo.getByIdWithStore(store, target.worldId);
    if (world === null) {
      throw WorldSceneLaunchError.worldNotFound();
    }
    if (world.status !== WorldStatus.Active) {
      throw WorldSceneLaunchError.worldNotActive();
    }

    const location: WorldLocation | null =
      await this.locationRepo.getByIdWithStore(store, target.locationId);
    if (location === null) {
      throw WorldSceneLaunchError.locationNotFound();
    }
    if (location.worldId !== target.worldId) {
      throw WorldSceneLaunchError.locationNotFound();
    }
    if (location.status !== WorldLocationStatus.Active) {
      throw WorldSceneLaunchError.locationArchived();
    }

    // 支持多场景并行:
    // - 显式指定 previousSessionId 时复用该会话所属场景(续写);
    // - 否则总是创建新的独立场景+会话,即使同地点已有其他 Active 场景。
    let scene: WorldScene | null = null;
    let isNewScene: boolean = false;
    if (target.previousSessionId !== undefined && target.previousSessionId !== '') {
      const prevSession: WorldConversationSession | null =
        await this.sessionRepo.getByIdWithStore(store, target.previousSessionId);
      if (prevSession !== null) {
        scene = await this.sceneRepo.getByIdWithStore(store, prevSession.sceneId);
      }
    }
    if (scene === null || scene.status === WorldSceneStatus.Ended) {
      scene = await this.sceneService.startSceneWithStore(store, target.worldId, target.locationId);
      isNewScene = true;
    }

    // 新建场景时场景刚在当前事务插入,RDB 重查可能不可见,直接跳过 Active 会话检查。
    let activeSession: WorldConversationSession | null = null;
    if (!isNewScene) {
      activeSession =
        await this.sessionService.getActiveSessionWithStore(store, target.worldId, scene.id);
    }
    if (activeSession !== null) {
      return {
        scene: scene,
        session: activeSession,
        isNewScene: isNewScene,
        isNewSession: false
      };
    }

    const sessionOptions: StartSessionOptions = {
      worldId: target.worldId,
      sceneId: scene.id,
      participantCharacterInstanceIds: trimmedIds,
      previousSessionId: target.previousSessionId
    };
    const session: WorldConversationSession =
      isNewScene
        ? await this.sessionService.startSessionWithStore(store, sessionOptions, trimmedIds, scene)
        : await this.sessionService.startSessionWithStore(store, sessionOptions, trimmedIds);

    return {
      scene: scene,
      session: session,
      isNewScene: isNewScene,
      isNewSession: true
    };
  }
}

export function preValidateParticipantIds(ids: string[]): string[] {
  const trimmedIds: string[] = [];
  for (let i = 0; i < ids.length; i++) {
    const trimmed: string = ids[i].trim();
    if (trimmed === '') {
      throw WorldSceneLaunchError.noEligibleParticipants();
    }
    if (trimmed === 'user') {
      throw WorldSceneLaunchError.participantNotFound();
    }
    trimmedIds.push(trimmed);
  }
  const seenIds: Set<string> = new Set<string>();
  for (let i = 0; i < trimmedIds.length; i++) {
    if (seenIds.has(trimmedIds[i])) {
      throw WorldSceneLaunchError.duplicateParticipant(trimmedIds[i]);
    }
    seenIds.add(trimmedIds[i]);
  }
  return trimmedIds;
}
