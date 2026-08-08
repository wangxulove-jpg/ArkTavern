import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import {
  WorldLocationMapPlacement,
  createWorldLocationMapPlacementRecord,
  WORLD_MAP_PLACEMENT_ID_PREFIX
} from '../../../main/ets/models/world/WorldLocationMapPlacement';
import { WorldLocationMapPlacementRepository } from '../../../main/ets/repositories/world/WorldLocationMapPlacementRepository';
import { WorldCharacterLocationHistoryRepository } from '../../../main/ets/repositories/world/WorldCharacterLocationHistoryRepository';
import { WorldRepository } from '../../../main/ets/repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../../main/ets/repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../../main/ets/repositories/world/WorldLocationEdgeRepository';
import { WorldCharacterInstanceRepository } from '../../../main/ets/repositories/world/WorldCharacterInstanceRepository';
import { WorldEventRepository } from '../../../main/ets/repositories/world/WorldEventRepository';
import { WorldSceneRepository } from '../../../main/ets/repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../../main/ets/repositories/world/WorldSceneMessageRepository';
import { WorldConversationSessionRepository } from '../../../main/ets/repositories/world/WorldConversationSessionRepository';
import { WorldPlayerProfileRepository } from '../../../main/ets/repositories/world/WorldPlayerProfileRepository';
import { WorldCharacterMemoryService } from '../../../main/ets/services/world/WorldCharacterMemoryService';
import { WorldCharacterMovementService } from '../../../main/ets/services/world/WorldCharacterMovementService';
import { WorldCharacterMemoryRepository } from '../../../main/ets/repositories/world/WorldCharacterMemoryRepository';
import { WorldStateService } from '../../../main/ets/services/world/WorldStateService';
import { CharacterService } from '../../../main/ets/services/CharacterService';
import { CharacterRepository } from '../../../main/ets/repositories/CharacterRepository';
import { CharacterSelectionStore } from '../../../main/ets/storage/CharacterSelectionStore';
import { CharacterAssetStore } from '../../../main/ets/storage/CharacterAssetStore';
import { LorebookRepository } from '../../../main/ets/repositories/LorebookRepository';
import {
  World,
  WorldStatus,
  createWorldRecord
} from '../../../main/ets/models/world/World';
import {
  WorldLocation,
  WorldLocationStatus,
  createWorldLocationRecord,
  buildCanonicalKey
} from '../../../main/ets/models/world/WorldLocation';

const TEST_DB: string = 'w1c_map_placement_cascade_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function mapPlacementCascadeContractTest(): void {
  describe('MAPCONTRACT 级联删除契约', () => {
    let dbHelper: DbHelper;
    let placementRepo: WorldLocationMapPlacementRepository;
    let worldStateService: WorldStateService;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
      placementRepo = new WorldLocationMapPlacementRepository(dbHelper);
      const worldRepo: WorldRepository = new WorldRepository(dbHelper);
      const locationRepo: WorldLocationRepository = new WorldLocationRepository(dbHelper);
      const edgeRepo: WorldLocationEdgeRepository = new WorldLocationEdgeRepository(dbHelper);
      const instanceRepo: WorldCharacterInstanceRepository = new WorldCharacterInstanceRepository(dbHelper);
      const eventRepo: WorldEventRepository = new WorldEventRepository(dbHelper);
      const sceneRepo: WorldSceneRepository = new WorldSceneRepository(dbHelper);
      const sceneMessageRepo: WorldSceneMessageRepository = new WorldSceneMessageRepository(dbHelper);
      const sessionRepo: WorldConversationSessionRepository = new WorldConversationSessionRepository(dbHelper);
      const profileRepo: WorldPlayerProfileRepository = new WorldPlayerProfileRepository(dbHelper);
      const memoryRepo: WorldCharacterMemoryRepository = new WorldCharacterMemoryRepository(dbHelper);
      const characterRepo: CharacterRepository = new CharacterRepository(dbHelper);
      const lorebookRepo: LorebookRepository = new LorebookRepository(dbHelper);
      const memoryService: WorldCharacterMemoryService = new WorldCharacterMemoryService(
        worldRepo, locationRepo, instanceRepo, sceneRepo, sceneMessageRepo, memoryRepo, dbHelper
      );
      const characterService: CharacterService = new CharacterService(
        characterRepo, new CharacterSelectionStore(), new CharacterAssetStore(), lorebookRepo, instanceRepo
      );
      const historyRepo: WorldCharacterLocationHistoryRepository = new WorldCharacterLocationHistoryRepository(dbHelper);
      const movementService: WorldCharacterMovementService = new WorldCharacterMovementService(
        worldRepo, locationRepo, edgeRepo, instanceRepo, sessionRepo, historyRepo, dbHelper
      );
      worldStateService = new WorldStateService(
        worldRepo, locationRepo, edgeRepo, instanceRepo, eventRepo,
        sceneRepo, sceneMessageRepo, sessionRepo, profileRepo,
        placementRepo, memoryService, movementService, characterService, dbHelper
      );
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('MAPCONTRACT-27 deleteWorld 级联删除该 World 全部 Placement', 0, async () => {
      const world: World = await worldStateService.createWorld('CascadeWorld27', '', 'Player');
      const loc1: WorldLocation = await worldStateService.createLocation(world.id, 'Loc1', '');
      const loc2: WorldLocation = await worldStateService.createLocation(world.id, 'Loc2', '');
      const p1: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'c27-1',
        worldId: world.id,
        locationId: loc1.id,
        positionX: 1,
        positionY: 0,
        positionZ: 0
      });
      const p2: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'c27-2',
        worldId: world.id,
        locationId: loc2.id,
        positionX: 2,
        positionY: 0,
        positionZ: 0
      });
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await placementRepo.insertWithStore(s, p1);
          await placementRepo.insertWithStore(s, p2);
        },
        'world_map_placement_upsert'
      );
      await worldStateService.deleteWorld(world.id);
      const list: WorldLocationMapPlacement[] = await placementRepo.listByWorldId(world.id);
      expect(list.length).assertEqual(0);
    });

    it('MAPCONTRACT-28 deleteWorld 不影响其他 World 的 Placement', 0, async () => {
      const worldA: World = await worldStateService.createWorld('CascadeWorld28A', '', 'Player');
      const worldB: World = await worldStateService.createWorld('CascadeWorld28B', '', 'Player');
      const locA: WorldLocation = await worldStateService.createLocation(worldA.id, 'LocA28', '');
      const locB: WorldLocation = await worldStateService.createLocation(worldB.id, 'LocB28', '');
      const pA: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'c28-a',
        worldId: worldA.id,
        locationId: locA.id,
        positionX: 10,
        positionY: 0,
        positionZ: 0
      });
      const pB: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'c28-b',
        worldId: worldB.id,
        locationId: locB.id,
        positionX: 20,
        positionY: 0,
        positionZ: 0
      });
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await placementRepo.insertWithStore(s, pA);
          await placementRepo.insertWithStore(s, pB);
        },
        'world_map_placement_upsert'
      );
      await worldStateService.deleteWorld(worldA.id);
      const listB: WorldLocationMapPlacement[] = await placementRepo.listByWorldId(worldB.id);
      expect(listB.length).assertEqual(1);
      if (listB.length > 0) {
        expect(listB[0].positionX).assertEqual(20);
      }
    });

    it('MAPCONTRACT-29 deleteLocation 级联删除该地点的 Placement', 0, async () => {
      const world: World = await worldStateService.createWorld('CascadeWorld29', '', 'Player');
      const loc1: WorldLocation = await worldStateService.createLocation(world.id, 'LocDel29', '');
      const loc2: WorldLocation = await worldStateService.createLocation(world.id, 'LocKeep29', '');
      const p1: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'c29-1',
        worldId: world.id,
        locationId: loc1.id,
        positionX: 100,
        positionY: 0,
        positionZ: 0
      });
      const p2: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'c29-2',
        worldId: world.id,
        locationId: loc2.id,
        positionX: 200,
        positionY: 0,
        positionZ: 0
      });
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await placementRepo.insertWithStore(s, p1);
          await placementRepo.insertWithStore(s, p2);
        },
        'world_map_placement_upsert'
      );
      await worldStateService.deleteLocation(loc1.id);
      const found1: WorldLocationMapPlacement | null = await placementRepo.getByWorldAndLocation(world.id, loc1.id);
      expect(found1).assertNull();
      const found2: WorldLocationMapPlacement | null = await placementRepo.getByWorldAndLocation(world.id, loc2.id);
      expect(found2 !== null).assertTrue();
    });

    it('MAPCONTRACT-30 deleteLocation 不影响其他地点的 Placement', 0, async () => {
      const world: World = await worldStateService.createWorld('CascadeWorld30', '', 'Player');
      const locDel: WorldLocation = await worldStateService.createLocation(world.id, 'LocDel30', '');
      const locKeep: WorldLocation = await worldStateService.createLocation(world.id, 'LocKeep30', '');
      const pDel: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'c30-del',
        worldId: world.id,
        locationId: locDel.id,
        positionX: 50,
        positionY: 0,
        positionZ: 0
      });
      const pKeep: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'c30-keep',
        worldId: world.id,
        locationId: locKeep.id,
        positionX: 60,
        positionY: 0,
        positionZ: 0
      });
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await placementRepo.insertWithStore(s, pDel);
          await placementRepo.insertWithStore(s, pKeep);
        },
        'world_map_placement_upsert'
      );
      await worldStateService.deleteLocation(locDel.id);
      const kept: WorldLocationMapPlacement | null = await placementRepo.getByWorldAndLocation(world.id, locKeep.id);
      expect(kept !== null).assertTrue();
      if (kept !== null) {
        expect(kept.positionX).assertEqual(60);
      }
    });

    it('MAPCONTRACT-31 空 World 可有 0 个 Placement', 0, async () => {
      const world: World = await worldStateService.createWorld('CascadeWorld31', '', 'Player');
      const list: WorldLocationMapPlacement[] = await placementRepo.listByWorldId(world.id);
      expect(list.length).assertEqual(0);
    });

    it('MAPCONTRACT-32 Location 存在但无 Placement 是合法状态', 0, async () => {
      const world: World = await worldStateService.createWorld('CascadeWorld32', '', 'Player');
      const loc: WorldLocation = await worldStateService.createLocation(world.id, 'LocNoPlacement32', '');
      const found: WorldLocationMapPlacement | null = await placementRepo.getByWorldAndLocation(world.id, loc.id);
      expect(found).assertNull();
    });

    it('MAPCONTRACT-33 Placement 读取保留小数精度', 0, async () => {
      const world: World = await worldStateService.createWorld('CascadeWorld33', '', 'Player');
      const loc: WorldLocation = await worldStateService.createLocation(world.id, 'LocPrec33', '');
      const p: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'c33-prec',
        worldId: world.id,
        locationId: loc.id,
        positionX: 1.23456789,
        positionY: -9.87654321,
        positionZ: 0.0001,
        rotationX: 6.28318530,
        rotationY: -1.57079633,
        rotationZ: 3.14159265,
        scale: 0.12345
      });
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await placementRepo.insertWithStore(s, p);
        },
        'world_map_placement_upsert'
      );
      const loaded: WorldLocationMapPlacement | null = await placementRepo.getById(p.id);
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.positionX).assertEqual(1.23456789);
        expect(loaded.scale).assertEqual(0.12345);
      }
    });

    it('MAPCONTRACT-34 deleteByWorldWithStore 幂等(不存在不抛错)', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await placementRepo.deleteByWorldWithStore(s, 'world-nonexistent-cascade');
        },
        'world_map_placement_delete'
      );
      expect(true).assertTrue();
    });
  });
}
