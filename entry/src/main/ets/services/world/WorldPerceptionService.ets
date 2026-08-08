import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import {
  WorldLocationPresenceSnapshot,
  WorldCharacterPerceptionSnapshot
} from '../../models/world/WorldPerception';
import { nowMillis } from '../../utils/Time';

export class WorldPerceptionService {
  private readonly instanceRepo: WorldCharacterInstanceRepository;

  constructor(instanceRepo: WorldCharacterInstanceRepository) {
    this.instanceRepo = instanceRepo;
  }

  async getLocationPresence(
    worldId: string,
    locationId: string
  ): Promise<WorldLocationPresenceSnapshot> {
    const instances: WorldCharacterInstance[] =
      await this.instanceRepo.listByLocation(worldId, locationId);
    const activeIds: string[] = [];
    for (let i = 0; i < instances.length; i++) {
      if (instances[i].isActive) {
        activeIds.push(instances[i].id);
      }
    }
    const snapshot: WorldLocationPresenceSnapshot = {
      worldId: worldId,
      locationId: locationId,
      characterInstanceIds: activeIds,
      capturedAt: nowMillis()
    };
    return snapshot;
  }

  async getCharacterPerception(
    worldId: string,
    characterInstanceId: string,
    currentLocationId: string
  ): Promise<WorldCharacterPerceptionSnapshot> {
    const instances: WorldCharacterInstance[] =
      await this.instanceRepo.listByLocation(worldId, currentLocationId);
    const coPresentIds: string[] = [];
    for (let i = 0; i < instances.length; i++) {
      if (instances[i].isActive && instances[i].id !== characterInstanceId) {
        coPresentIds.push(instances[i].id);
      }
    }
    const snapshot: WorldCharacterPerceptionSnapshot = {
      worldId: worldId,
      characterInstanceId: characterInstanceId,
      locationId: currentLocationId,
      coPresentCharacterInstanceIds: coPresentIds,
      capturedAt: nowMillis()
    };
    return snapshot;
  }

  async resolvePotentialWitnesses(
    worldId: string,
    locationId: string,
    excludeInstanceId: string
  ): Promise<string[]> {
    const instances: WorldCharacterInstance[] =
      await this.instanceRepo.listByLocation(worldId, locationId);
    const witnesses: string[] = [];
    for (let i = 0; i < instances.length; i++) {
      if (instances[i].isActive && instances[i].id !== excludeInstanceId) {
        witnesses.push(instances[i].id);
      }
    }
    return witnesses;
  }
}
