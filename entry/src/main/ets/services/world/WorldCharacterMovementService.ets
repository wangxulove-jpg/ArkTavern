import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../repositories/world/WorldLocationEdgeRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldCharacterLocationHistoryRepository } from '../../repositories/world/WorldCharacterLocationHistoryRepository';
import {
  WorldCharacterInstance,
  createWorldCharacterInstanceRecord
} from '../../models/world/WorldCharacterInstance';
import {
  WorldCharacterLocationHistory,
  TransitionKind,
  InitiatorType,
  WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX,
  createWorldCharacterLocationHistoryRecord
} from '../../models/world/WorldCharacterLocationHistory';
import {
  WorldLocationEdge
} from '../../models/world/WorldLocationEdge';
import {
  WorldConversationSession,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import {
  World,
  WorldStatus
} from '../../models/world/World';
import {
  WorldLocation,
  WorldLocationStatus
} from '../../models/world/WorldLocation';
import { WorldMovementError } from '../../models/world/WorldMovementError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';

export interface TravelOption {
  readonly targetLocationId: string;
  readonly targetLocationName: string;
  readonly edgeId: string;
  readonly directionLabel: string;
  readonly isBidirectional: boolean;
}

export class WorldCharacterMovementService {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly edgeRepo: WorldLocationEdgeRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly historyRepo: WorldCharacterLocationHistoryRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    edgeRepo: WorldLocationEdgeRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sessionRepo: WorldConversationSessionRepository,
    historyRepo: WorldCharacterLocationHistoryRepository,
    dbHelper: DbHelper
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.edgeRepo = edgeRepo;
    this.instanceRepo = instanceRepo;
    this.sessionRepo = sessionRepo;
    this.historyRepo = historyRepo;
    this.dbHelper = dbHelper;
  }

  async travelCharacter(
    instanceId: string,
    targetLocationId: string
  ): Promise<WorldCharacterInstance> {
    let result: WorldCharacterInstance | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const instance: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, instanceId);
        if (instance === null) {
          throw WorldMovementError.characterInstanceNotFound();
        }
        await this.assertWorldActiveInTx(store, instance.worldId);
        if (!instance.isActive) {
          throw WorldMovementError.characterInstanceInactive();
        }
        if (instance.currentLocationId === undefined || instance.currentLocationId === '') {
          throw WorldMovementError.characterNotPlaced();
        }
        if (instance.currentLocationId === targetLocationId) {
          throw WorldMovementError.characterAlreadyAtLocation();
        }
        await this.assertNotInActiveSessionInTx(store, instance.worldId, instanceId);

        const target: WorldLocation | null =
          await this.locationRepo.getByIdWithStore(store, targetLocationId);
        if (target === null) {
          throw WorldMovementError.locationNotFound();
        }
        if (target.worldId !== instance.worldId) {
          throw WorldMovementError.locationNotInWorld();
        }
        if (target.status !== WorldLocationStatus.Active) {
          throw WorldMovementError.locationArchived();
        }

        const edgeResult: EdgeValidationResult = await this.validateEdgeInTx(
          store, instance.worldId, instance.currentLocationId, targetLocationId
        );
        if (!edgeResult.passable) {
          throw edgeResult.error!;
        }

        const freshCurrentLocationId: string = await this.readFreshCurrentLocationId(store, instanceId);
        if (freshCurrentLocationId !== instance.currentLocationId) {
          throw WorldMovementError.internal('位置状态已变更,请重试');
        }

        const updated: WorldCharacterInstance = createWorldCharacterInstanceRecord({
          id: instance.id,
          worldId: instance.worldId,
          characterId: instance.characterId,
          displayNameSnapshot: instance.displayNameSnapshot,
          currentLocationId: targetLocationId,
          isActive: instance.isActive,
          currentGoal: instance.currentGoal,
          mapIconStyle: instance.mapIconStyle,
          createdAt: instance.createdAt,
          updatedAt: nowMillis()
        });
        await this.instanceRepo.updateWithStore(store, updated);

        const history: WorldCharacterLocationHistory = createWorldCharacterLocationHistoryRecord({
          id: WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX + generateUuid(),
          worldId: instance.worldId,
          characterInstanceId: instanceId,
          transitionKind: TransitionKind.Travel,
          fromLocationId: instance.currentLocationId,
          toLocationId: targetLocationId,
          initiatorType: InitiatorType.User,
          edgeId: edgeResult.edgeId,
          directionLabel: edgeResult.directionLabel,
          createdAt: nowMillis()
        });
        await this.historyRepo.insertWithStore(store, history);

        result = updated;
      },
      'world_character_travel'
    );
    if (result === null) {
      throw WorldMovementError.internal('事务未产生结果');
    }
    return result;
  }

  async placeCharacter(
    instanceId: string,
    locationId: string,
    initiatorType: InitiatorType = InitiatorType.User
  ): Promise<WorldCharacterInstance> {
    let result: WorldCharacterInstance | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const instance: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, instanceId);
        if (instance === null) {
          throw WorldMovementError.characterInstanceNotFound();
        }
        await this.assertWorldActiveInTx(store, instance.worldId);
        if (!instance.isActive) {
          throw WorldMovementError.characterInstanceInactive();
        }
        if (instance.currentLocationId !== undefined && instance.currentLocationId !== '') {
          throw WorldMovementError.invalidOperation('角色已放置,请使用移动或重定位');
        }
        const target: WorldLocation | null =
          await this.locationRepo.getByIdWithStore(store, locationId);
        if (target === null) {
          throw WorldMovementError.locationNotFound();
        }
        if (target.worldId !== instance.worldId) {
          throw WorldMovementError.locationNotInWorld();
        }
        if (target.status !== WorldLocationStatus.Active) {
          throw WorldMovementError.locationArchived();
        }

        const updated: WorldCharacterInstance = createWorldCharacterInstanceRecord({
          id: instance.id,
          worldId: instance.worldId,
          characterId: instance.characterId,
          displayNameSnapshot: instance.displayNameSnapshot,
          currentLocationId: locationId,
          isActive: instance.isActive,
          currentGoal: instance.currentGoal,
          mapIconStyle: instance.mapIconStyle,
          createdAt: instance.createdAt,
          updatedAt: nowMillis()
        });
        await this.instanceRepo.updateWithStore(store, updated);

        const history: WorldCharacterLocationHistory = createWorldCharacterLocationHistoryRecord({
          id: WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX + generateUuid(),
          worldId: instance.worldId,
          characterInstanceId: instanceId,
          transitionKind: TransitionKind.Placement,
          fromLocationId: undefined,
          toLocationId: locationId,
          initiatorType: initiatorType,
          createdAt: nowMillis()
        });
        await this.historyRepo.insertWithStore(store, history);

        result = updated;
      },
      'world_character_place'
    );
    if (result === null) {
      throw WorldMovementError.internal('事务未产生结果');
    }
    return result;
  }

  async unplaceCharacter(
    instanceId: string,
    initiatorType: InitiatorType = InitiatorType.User
  ): Promise<WorldCharacterInstance> {
    let result: WorldCharacterInstance | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const instance: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, instanceId);
        if (instance === null) {
          throw WorldMovementError.characterInstanceNotFound();
        }
        await this.assertWorldActiveInTx(store, instance.worldId);
        if (instance.currentLocationId === undefined || instance.currentLocationId === '') {
          throw WorldMovementError.characterNotPlaced();
        }

        const previousLocationId: string = instance.currentLocationId;
        const updated: WorldCharacterInstance = createWorldCharacterInstanceRecord({
          id: instance.id,
          worldId: instance.worldId,
          characterId: instance.characterId,
          displayNameSnapshot: instance.displayNameSnapshot,
          currentLocationId: undefined,
          isActive: instance.isActive,
          currentGoal: instance.currentGoal,
          mapIconStyle: instance.mapIconStyle,
          createdAt: instance.createdAt,
          updatedAt: nowMillis()
        });
        await this.instanceRepo.updateWithStore(store, updated);

        const history: WorldCharacterLocationHistory = createWorldCharacterLocationHistoryRecord({
          id: WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX + generateUuid(),
          worldId: instance.worldId,
          characterInstanceId: instanceId,
          transitionKind: TransitionKind.Unplacement,
          fromLocationId: previousLocationId,
          toLocationId: undefined,
          initiatorType: initiatorType,
          createdAt: nowMillis()
        });
        await this.historyRepo.insertWithStore(store, history);

        result = updated;
      },
      'world_character_unplace'
    );
    if (result === null) {
      throw WorldMovementError.internal('事务未产生结果');
    }
    return result;
  }

  async relocateCharacter(
    instanceId: string,
    targetLocationId: string
  ): Promise<WorldCharacterInstance> {
    let result: WorldCharacterInstance | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const instance: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, instanceId);
        if (instance === null) {
          throw WorldMovementError.characterInstanceNotFound();
        }
        await this.assertWorldActiveInTx(store, instance.worldId);
        if (!instance.isActive) {
          throw WorldMovementError.characterInstanceInactive();
        }
        const target: WorldLocation | null =
          await this.locationRepo.getByIdWithStore(store, targetLocationId);
        if (target === null) {
          throw WorldMovementError.locationNotFound();
        }
        if (target.worldId !== instance.worldId) {
          throw WorldMovementError.locationNotInWorld();
        }
        if (target.status !== WorldLocationStatus.Active) {
          throw WorldMovementError.locationArchived();
        }

        const previousLocationId: string | undefined =
          instance.currentLocationId !== undefined && instance.currentLocationId !== ''
            ? instance.currentLocationId : undefined;

        const updated: WorldCharacterInstance = createWorldCharacterInstanceRecord({
          id: instance.id,
          worldId: instance.worldId,
          characterId: instance.characterId,
          displayNameSnapshot: instance.displayNameSnapshot,
          currentLocationId: targetLocationId,
          isActive: instance.isActive,
          currentGoal: instance.currentGoal,
          mapIconStyle: instance.mapIconStyle,
          createdAt: instance.createdAt,
          updatedAt: nowMillis()
        });
        await this.instanceRepo.updateWithStore(store, updated);

        const history: WorldCharacterLocationHistory = createWorldCharacterLocationHistoryRecord({
          id: WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX + generateUuid(),
          worldId: instance.worldId,
          characterInstanceId: instanceId,
          transitionKind: TransitionKind.Relocation,
          fromLocationId: previousLocationId,
          toLocationId: targetLocationId,
          initiatorType: InitiatorType.User,
          createdAt: nowMillis()
        });
        await this.historyRepo.insertWithStore(store, history);

        result = updated;
      },
      'world_character_move'
    );
    if (result === null) {
      throw WorldMovementError.internal('事务未产生结果');
    }
    return result;
  }

  async listTravelOptions(instanceId: string): Promise<TravelOption[]> {
    const instance: WorldCharacterInstance | null =
      await this.instanceRepo.getById(instanceId);
    if (instance === null) {
      throw WorldMovementError.characterInstanceNotFound();
    }
    if (!instance.isActive) {
      throw WorldMovementError.characterInstanceInactive();
    }
    if (instance.currentLocationId === undefined || instance.currentLocationId === '') {
      return [];
    }
    const currentLocId: string = instance.currentLocationId;
    const forwardEdges: WorldLocationEdge[] = await this.edgeRepo.listFromLocation(currentLocId);
    const options: TravelOption[] = [];
    const seenTargetIds: Set<string> = new Set<string>();
    for (let i = 0; i < forwardEdges.length; i++) {
      const edge: WorldLocationEdge = forwardEdges[i];
      if (!edge.isEnabled) {
        continue;
      }
      if (edge.worldId !== instance.worldId) {
        continue;
      }
      const targetLoc: WorldLocation | null =
        await this.locationRepo.getById(edge.toLocationId);
      if (targetLoc === null || targetLoc.status !== WorldLocationStatus.Active) {
        continue;
      }
      options.push({
        targetLocationId: edge.toLocationId,
        targetLocationName: targetLoc.name,
        edgeId: edge.id,
        directionLabel: edge.directionLabel,
        isBidirectional: edge.isBidirectional
      });
      seenTargetIds.add(edge.toLocationId);
    }
    const allEdges: WorldLocationEdge[] = await this.edgeRepo.listByWorld(instance.worldId);
    for (let i = 0; i < allEdges.length; i++) {
      const edge: WorldLocationEdge = allEdges[i];
      if (!edge.isEnabled) {
        continue;
      }
      if (!edge.isBidirectional) {
        continue;
      }
      if (edge.toLocationId !== currentLocId) {
        continue;
      }
      const targetId: string = edge.fromLocationId;
      if (seenTargetIds.has(targetId)) {
        continue;
      }
      const targetLoc: WorldLocation | null =
        await this.locationRepo.getById(targetId);
      if (targetLoc === null || targetLoc.status !== WorldLocationStatus.Active) {
        continue;
      }
      options.push({
        targetLocationId: targetId,
        targetLocationName: targetLoc.name,
        edgeId: edge.id,
        directionLabel: edge.directionLabel,
        isBidirectional: true
      });
      seenTargetIds.add(targetId);
    }
    return options;
  }

  async insertPlacementHistoryWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    characterInstanceId: string,
    toLocationId: string,
    initiatorType: InitiatorType
  ): Promise<void> {
    const history: WorldCharacterLocationHistory = createWorldCharacterLocationHistoryRecord({
      id: WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX + generateUuid(),
      worldId: worldId,
      characterInstanceId: characterInstanceId,
      transitionKind: TransitionKind.Placement,
      fromLocationId: undefined,
      toLocationId: toLocationId,
      initiatorType: initiatorType,
      createdAt: nowMillis()
    });
    await this.historyRepo.insertWithStore(store, history);
  }

  async insertUnplacementHistoryWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    characterInstanceId: string,
    fromLocationId: string,
    initiatorType: InitiatorType
  ): Promise<void> {
    const history: WorldCharacterLocationHistory = createWorldCharacterLocationHistoryRecord({
      id: WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX + generateUuid(),
      worldId: worldId,
      characterInstanceId: characterInstanceId,
      transitionKind: TransitionKind.Unplacement,
      fromLocationId: fromLocationId,
      toLocationId: undefined,
      initiatorType: initiatorType,
      createdAt: nowMillis()
    });
    await this.historyRepo.insertWithStore(store, history);
  }

  async insertRelocationHistoryWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    characterInstanceId: string,
    fromLocationId: string | undefined,
    toLocationId: string,
    initiatorType: InitiatorType
  ): Promise<void> {
    const history: WorldCharacterLocationHistory = createWorldCharacterLocationHistoryRecord({
      id: WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX + generateUuid(),
      worldId: worldId,
      characterInstanceId: characterInstanceId,
      transitionKind: TransitionKind.Relocation,
      fromLocationId: fromLocationId,
      toLocationId: toLocationId,
      initiatorType: initiatorType,
      createdAt: nowMillis()
    });
    await this.historyRepo.insertWithStore(store, history);
  }

  async insertRemovalHistoryWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    characterInstanceId: string,
    fromLocationId: string | undefined,
    initiatorType: InitiatorType
  ): Promise<void> {
    if (fromLocationId === undefined || fromLocationId === '') {
      return;
    }
    const history: WorldCharacterLocationHistory = createWorldCharacterLocationHistoryRecord({
      id: WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX + generateUuid(),
      worldId: worldId,
      characterInstanceId: characterInstanceId,
      transitionKind: TransitionKind.Removal,
      fromLocationId: fromLocationId,
      toLocationId: undefined,
      initiatorType: initiatorType,
      createdAt: nowMillis()
    });
    await this.historyRepo.insertWithStore(store, history);
  }

  async deleteByWorldWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    await this.historyRepo.deleteByWorldIdWithStore(store, worldId);
  }

  private async assertWorldActiveInTx(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<World> {
    const world: World | null = await this.worldRepo.getByIdWithStore(store, worldId);
    if (world === null) {
      throw WorldMovementError.worldNotFound();
    }
    if (world.status !== WorldStatus.Active) {
      throw WorldMovementError.worldArchived();
    }
    return world;
  }

  private async assertNotInActiveSessionInTx(
    store: relationalStore.RdbStore,
    worldId: string,
    characterInstanceId: string
  ): Promise<void> {
    const activeSessions: WorldConversationSession[] =
      await this.sessionRepo.listActiveByWorldIdWithStore(store, worldId);
    for (let i = 0; i < activeSessions.length; i++) {
      const session: WorldConversationSession = activeSessions[i];
      if (session.participantSnapshotJson === '' || session.participantSnapshotJson === '[]') {
        continue;
      }
      const participants: WorldSessionParticipantSnapshot[] =
        deserializeParticipantSnapshots(session.participantSnapshotJson);
      for (let j = 0; j < participants.length; j++) {
        if (participants[j].characterInstanceId === characterInstanceId) {
          throw WorldMovementError.activeSessionConflict();
        }
      }
    }
  }

  private async validateEdgeInTx(
    store: relationalStore.RdbStore,
    worldId: string,
    currentLocationId: string,
    targetLocationId: string
  ): Promise<EdgeValidationResult> {
    const forward: WorldLocationEdge | null = await this.edgeRepo.findExactWithStore(
      store, worldId, currentLocationId, targetLocationId
    );
    if (forward !== null) {
      if (!forward.isEnabled) {
        return { passable: false, error: WorldMovementError.edgeDisabled(), edgeId: '', directionLabel: '' };
      }
      return {
        passable: true,
        error: null,
        edgeId: forward.id,
        directionLabel: forward.directionLabel
      };
    }
    const reverse: WorldLocationEdge | null = await this.edgeRepo.findExactWithStore(
      store, worldId, targetLocationId, currentLocationId
    );
    if (reverse !== null && reverse.isBidirectional) {
      if (!reverse.isEnabled) {
        return { passable: false, error: WorldMovementError.edgeDisabled(), edgeId: '', directionLabel: '' };
      }
      return {
        passable: true,
        error: null,
        edgeId: reverse.id,
        directionLabel: reverse.directionLabel
      };
    }
    return { passable: false, error: WorldMovementError.noEnabledPath(), edgeId: '', directionLabel: '' };
  }

  private async readFreshCurrentLocationId(
    store: relationalStore.RdbStore,
    instanceId: string
  ): Promise<string> {
    const fresh: WorldCharacterInstance | null =
      await this.instanceRepo.getByIdWithStore(store, instanceId);
    if (fresh === null) {
      throw WorldMovementError.characterInstanceNotFound();
    }
    return fresh.currentLocationId !== undefined ? fresh.currentLocationId : '';
  }
}

interface EdgeValidationResult {
  readonly passable: boolean;
  readonly error: WorldMovementError | null;
  readonly edgeId: string;
  readonly directionLabel: string;
}
