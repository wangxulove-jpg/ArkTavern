import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { WorldRepository } from '../../../main/ets/repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../../main/ets/repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../../main/ets/repositories/world/WorldLocationEdgeRepository';
import { WorldCharacterInstanceRepository } from '../../../main/ets/repositories/world/WorldCharacterInstanceRepository';
import { WorldEventRepository } from '../../../main/ets/repositories/world/WorldEventRepository';
import { WorldSceneRepository } from '../../../main/ets/repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../../main/ets/repositories/world/WorldSceneMessageRepository';
import { WorldConversationSessionRepository } from '../../../main/ets/repositories/world/WorldConversationSessionRepository';
import { WorldPlayerProfileRepository } from '../../../main/ets/repositories/world/WorldPlayerProfileRepository';
import { WorldLocationMapPlacementRepository } from '../../../main/ets/repositories/world/WorldLocationMapPlacementRepository';
import { WorldCharacterMemoryService } from '../../../main/ets/services/world/WorldCharacterMemoryService';
import { WorldCharacterMemoryRepository } from '../../../main/ets/repositories/world/WorldCharacterMemoryRepository';
import { WorldStateService } from '../../../main/ets/services/world/WorldStateService';
import { CharacterService } from '../../../main/ets/services/CharacterService';
import { CharacterRepository } from '../../../main/ets/repositories/CharacterRepository';
import { CharacterSelectionStore } from '../../../main/ets/storage/CharacterSelectionStore';
import { CharacterAssetStore } from '../../../main/ets/storage/CharacterAssetStore';
import { LorebookRepository } from '../../../main/ets/repositories/LorebookRepository';
import { WorldStatus } from '../../../main/ets/models/world/World';

const TEST_DB: string = 'w2a1_domain_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

function isErrorOfClass(err: Object, className: string): boolean {
  return err !== null && err !== undefined && err.constructor.name === className;
}

export default function worldPlayerCharacterDomainContractTest(): void {
  describe('PLAYERCHAR-25~41 WorldStateService 玩家身份与角色领域契约(W2A1)', () => {
    let dbHelper: DbHelper;
    let stateService: WorldStateService;
    let profileRepo: WorldPlayerProfileRepository;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
      const worldRepo: WorldRepository = new WorldRepository(dbHelper);
      const locationRepo: WorldLocationRepository = new WorldLocationRepository(dbHelper);
      const edgeRepo: WorldLocationEdgeRepository = new WorldLocationEdgeRepository(dbHelper);
      const instanceRepo: WorldCharacterInstanceRepository = new WorldCharacterInstanceRepository(dbHelper);
      const eventRepo: WorldEventRepository = new WorldEventRepository(dbHelper);
      const sceneRepo: WorldSceneRepository = new WorldSceneRepository(dbHelper);
      const sceneMessageRepo: WorldSceneMessageRepository = new WorldSceneMessageRepository(dbHelper);
      const sessionRepo: WorldConversationSessionRepository = new WorldConversationSessionRepository(dbHelper);
      const profileRepository: WorldPlayerProfileRepository = new WorldPlayerProfileRepository(dbHelper);
      const placementRepo: WorldLocationMapPlacementRepository = new WorldLocationMapPlacementRepository(dbHelper);
      const memoryRepo: WorldCharacterMemoryRepository = new WorldCharacterMemoryRepository(dbHelper);
      const characterRepo: CharacterRepository = new CharacterRepository(dbHelper);
      const lorebookRepo: LorebookRepository = new LorebookRepository(dbHelper);
      const memoryService: WorldCharacterMemoryService = new WorldCharacterMemoryService(
        worldRepo, locationRepo, instanceRepo, sceneRepo, sceneMessageRepo, memoryRepo, dbHelper
      );
      const characterService: CharacterService = new CharacterService(
        characterRepo, new CharacterSelectionStore(), new CharacterAssetStore(), lorebookRepo, instanceRepo
      );
      stateService = new WorldStateService(
        worldRepo, locationRepo, edgeRepo, instanceRepo, eventRepo,
        sceneRepo, sceneMessageRepo, sessionRepo, profileRepository, placementRepo,
        memoryService, characterService, dbHelper
      );
      profileRepo = profileRepository;
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('PLAYERCHAR-25 createWorld 原子创建 World + PlayerProfile', 0, async () => {
      const world = await stateService.createWorld('TestWorld25', '', 'Player25');
      expect(world.name).assertEqual('TestWorld25');
      expect(world.status).assertEqual(WorldStatus.Active);
      const profile = await stateService.getPlayerProfile(world.id);
      expect(profile !== null).assertTrue();
      expect(profile!.displayName).assertEqual('Player25');
      expect(profile!.worldId).assertEqual(world.id);
    });

    it('PLAYERCHAR-26 createWorld 空 playerDisplayName 抛错', 0, async () => {
      try {
        await stateService.createWorld('TestWorld26', '', '   ');
        expect(true).assertFalse();
      } catch (err) {
        expect(isErrorOfClass(err as Object, 'WorldStateError')).assertTrue();
      }
    });

    it('PLAYERCHAR-27 addCharacterToWorld 角色不存在抛错', 0, async () => {
      const world = await stateService.createWorld('TestWorld27', '', 'Player27');
      try {
        await stateService.addCharacterToWorld(world.id, 'nonexistent-char-27');
        expect(true).assertFalse();
      } catch (err) {
        expect(isErrorOfClass(err as Object, 'WorldStateError')).assertTrue();
      }
    });

    it('PLAYERCHAR-28 getPlayerProfile 不存在的世界返回 null', 0, async () => {
      const profile = await stateService.getPlayerProfile('nonexistent-world');
      expect(profile === null).assertTrue();
    });

    it('PLAYERCHAR-29 updatePlayerProfile 更新 persona', 0, async () => {
      const world = await stateService.createWorld('TestWorld29', '', 'Player29');
      const updated = await stateService.updatePlayerProfile(
        world.id, undefined, 'New persona text'
      );
      expect(updated.persona).assertEqual('New persona text');
      expect(updated.displayName).assertEqual('Player29');
    });

    it('PLAYERCHAR-30 updatePlayerProfile 更新 publicIdentity', 0, async () => {
      const world = await stateService.createWorld('TestWorld30', '', 'Player30');
      const updated = await stateService.updatePlayerProfile(
        world.id, undefined, undefined, 'Visible Identity'
      );
      expect(updated.publicIdentity).assertEqual('Visible Identity');
    });

    it('PLAYERCHAR-31 updatePlayerProfile 更新 privateIdentity', 0, async () => {
      const world = await stateService.createWorld('TestWorld31', '', 'Player31');
      const updated = await stateService.updatePlayerProfile(
        world.id, undefined, undefined, undefined, 'Secret Identity'
      );
      expect(updated.privateIdentity).assertEqual('Secret Identity');
    });

    it('PLAYERCHAR-32 updatePlayerProfile 更新 displayName', 0, async () => {
      const world = await stateService.createWorld('TestWorld32', '', 'Player32');
      const updated = await stateService.updatePlayerProfile(
        world.id, 'NewName'
      );
      expect(updated.displayName).assertEqual('NewName');
    });

    it('PLAYERCHAR-33 updatePlayerProfile 空 displayName 抛错', 0, async () => {
      const world = await stateService.createWorld('TestWorld33', '', 'Player33');
      try {
        await stateService.updatePlayerProfile(world.id, '   ');
        expect(true).assertFalse();
      } catch (err) {
        expect(isErrorOfClass(err as Object, 'WorldStateError')).assertTrue();
      }
    });

    it('PLAYERCHAR-34 updatePlayerProfile 设置 currentLocationId 到有效地点', 0, async () => {
      const world = await stateService.createWorld('TestWorld34', '', 'Player34');
      const location = await stateService.createLocation(world.id, 'Tavern', '');
      const updated = await stateService.updatePlayerProfile(
        world.id, undefined, undefined, undefined, undefined, location.id
      );
      expect(updated.currentLocationId).assertEqual(location.id);
    });

    it('PLAYERCHAR-35 updatePlayerProfile currentLocationId 到不存在地点抛错', 0, async () => {
      const world = await stateService.createWorld('TestWorld35', '', 'Player35');
      try {
        await stateService.updatePlayerProfile(
          world.id, undefined, undefined, undefined, undefined, 'nonexistent-loc'
        );
        expect(true).assertFalse();
      } catch (err) {
        expect(isErrorOfClass(err as Object, 'WorldStateError')).assertTrue();
      }
    });

    it('PLAYERCHAR-36 updatePlayerProfile 清空 currentLocationId', 0, async () => {
      const world = await stateService.createWorld('TestWorld36', '', 'Player36');
      const location = await stateService.createLocation(world.id, 'Forest', '');
      await stateService.updatePlayerProfile(
        world.id, undefined, undefined, undefined, undefined, location.id
      );
      const cleared = await stateService.updatePlayerProfile(
        world.id, undefined, undefined, undefined, undefined, ''
      );
      expect(cleared.currentLocationId === undefined).assertTrue();
    });

    it('PLAYERCHAR-37 placeCharacterAtLocation 实例不存在抛错', 0, async () => {
      const world = await stateService.createWorld('TestWorld37', '', 'Player37');
      const location = await stateService.createLocation(world.id, 'Castle', '');
      try {
        await stateService.placeCharacterAtLocation('nonexistent-instance', location.id);
        expect(true).assertFalse();
      } catch (err) {
        expect(isErrorOfClass(err as Object, 'WorldStateError')).assertTrue();
      }
    });

    it('PLAYERCHAR-38 unplaceCharacter 实例不存在抛错', 0, async () => {
      try {
        await stateService.unplaceCharacter('nonexistent-instance');
        expect(true).assertFalse();
      } catch (err) {
        expect(isErrorOfClass(err as Object, 'WorldStateError')).assertTrue();
      }
    });

    it('PLAYERCHAR-39 updatePlayerProfile 不存在的世界抛错', 0, async () => {
      try {
        await stateService.updatePlayerProfile('nonexistent', 'Name');
        expect(true).assertFalse();
      } catch (err) {
        expect(isErrorOfClass(err as Object, 'WorldStateError')).assertTrue();
      }
    });

    it('PLAYERCHAR-40 deleteWorld 级联删除 PlayerProfile', 0, async () => {
      const world = await stateService.createWorld('TestWorld40', '', 'Player40');
      const profile = await stateService.getPlayerProfile(world.id);
      expect(profile !== null).assertTrue();
      await stateService.deleteWorld(world.id);
      const deletedProfile = await stateService.getPlayerProfile(world.id);
      expect(deletedProfile === null).assertTrue();
    });

    it('PLAYERCHAR-41 createWorld 后 Profile 默认字段为空', 0, async () => {
      const world = await stateService.createWorld('TestWorld41', '', 'Player41');
      const profile = await stateService.getPlayerProfile(world.id);
      expect(profile !== null).assertTrue();
      expect(profile!.persona).assertEqual('');
      expect(profile!.publicIdentity).assertEqual('');
      expect(profile!.privateIdentity).assertEqual('');
      expect(profile!.currentLocationId === undefined).assertTrue();
    });
  });
}
