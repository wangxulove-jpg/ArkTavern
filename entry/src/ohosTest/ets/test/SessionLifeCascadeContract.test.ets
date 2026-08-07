import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { WorldRepository } from '../../../main/ets/repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../../main/ets/repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../../main/ets/repositories/world/WorldLocationEdgeRepository';
import { WorldCharacterInstanceRepository } from '../../../main/ets/repositories/world/WorldCharacterInstanceRepository';
import { WorldEventRepository } from '../../../main/ets/repositories/world/WorldEventRepository';
import { WorldSceneRepository } from '../../../main/ets/repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../../main/ets/repositories/world/WorldSceneMessageRepository';
import { WorldPlayerProfileRepository } from '../../../main/ets/repositories/world/WorldPlayerProfileRepository';
import { WorldConversationSessionRepository } from '../../../main/ets/repositories/world/WorldConversationSessionRepository';
import { WorldConversationSessionService } from '../../../main/ets/services/world/WorldConversationSessionService';
import { WorldStateService } from '../../../main/ets/services/world/WorldStateService';
import { WorldCharacterMemoryService } from '../../../main/ets/services/world/WorldCharacterMemoryService';
import { CharacterService } from '../../../main/ets/services/CharacterService';
import { CharacterRepository } from '../../../main/ets/repositories/CharacterRepository';
import { CharacterSelectionStore } from '../../../main/ets/storage/CharacterSelectionStore';
import { CharacterAssetStore } from '../../../main/ets/storage/CharacterAssetStore';
import { LorebookRepository } from '../../../main/ets/repositories/LorebookRepository';
import { WorldCharacterMemoryRepository } from '../../../main/ets/repositories/world/WorldCharacterMemoryRepository';
import {
  WorldStatus,
  createWorldRecord
} from '../../../main/ets/models/world/World';
import {
  WorldLocationStatus,
  createWorldLocationRecord
} from '../../../main/ets/models/world/WorldLocation';
import {
  createWorldPlayerProfileRecord
} from '../../../main/ets/models/world/WorldPlayerProfile';
import {
  createWorldSceneRecord
} from '../../../main/ets/models/world/WorldScene';
import {
  createWorldCharacterInstanceRecord
} from '../../../main/ets/models/world/WorldCharacterInstance';
import {
  WorldConversationSessionError,
  SessionErrorKind,
  isSessionError
} from '../../../main/ets/models/world/WorldConversationSessionError';

const TEST_DB: string = 'sessionlife_cascade_contract_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function sessionLifeCascadeContractTest(): void {
  describe('SESSIONLIFE 级联删除与错误类型契约', () => {
    let dbHelper: DbHelper;
    let sessionService: WorldConversationSessionService;
    let stateService: WorldStateService;
    let worldRepo: WorldRepository;
    let profileRepo: WorldPlayerProfileRepository;
    let sceneRepo: WorldSceneRepository;
    let instanceRepo: WorldCharacterInstanceRepository;
    let sessionRepo: WorldConversationSessionRepository;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
      worldRepo = new WorldRepository(dbHelper);
      const locationRepo: WorldLocationRepository = new WorldLocationRepository(dbHelper);
      const edgeRepo: WorldLocationEdgeRepository = new WorldLocationEdgeRepository(dbHelper);
      instanceRepo = new WorldCharacterInstanceRepository(dbHelper);
      const eventRepo: WorldEventRepository = new WorldEventRepository(dbHelper);
      sceneRepo = new WorldSceneRepository(dbHelper);
      const sceneMessageRepo: WorldSceneMessageRepository = new WorldSceneMessageRepository(dbHelper);
      profileRepo = new WorldPlayerProfileRepository(dbHelper);
      sessionRepo = new WorldConversationSessionRepository(dbHelper);
      const memoryRepo: WorldCharacterMemoryRepository = new WorldCharacterMemoryRepository(dbHelper);
      const memoryService: WorldCharacterMemoryService = new WorldCharacterMemoryService(
        worldRepo,
        locationRepo,
        instanceRepo,
        sceneRepo,
        sceneMessageRepo,
        memoryRepo,
        dbHelper
      );
      const characterRepo: CharacterRepository = new CharacterRepository(dbHelper);
      const characterSelectionStore: CharacterSelectionStore = new CharacterSelectionStore();
      const characterAssetStore: CharacterAssetStore = new CharacterAssetStore();
      const lorebookRepo: LorebookRepository = new LorebookRepository(dbHelper);
      const characterService: CharacterService = new CharacterService(
        characterRepo,
        characterSelectionStore,
        characterAssetStore,
        lorebookRepo,
        instanceRepo
      );
      sessionService = new WorldConversationSessionService(
        worldRepo,
        profileRepo,
        sceneRepo,
        instanceRepo,
        sessionRepo,
        dbHelper
      );
      stateService = new WorldStateService(
        worldRepo,
        locationRepo,
        edgeRepo,
        instanceRepo,
        eventRepo,
        sceneRepo,
        sceneMessageRepo,
        sessionRepo,
        profileRepo,
        memoryService,
        characterService,
        dbHelper
      );
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('SESSIONLIFE-39: deleteWorld 级联删除会话', 0, async () => {
      const worldId = 'w-cascade-session';
      const locationId = 'loc-cascade-session';
      const sceneId = 'scene-cascade-session';
      const instanceId = 'ci-cascade-session';

      const store: relationalStore.RdbStore = dbHelper.getStore();
      await worldRepo.insertWithStore(store, createWorldRecord({
        id: worldId,
        name: 'CascadeWorld',
        status: WorldStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      const locationRepo: WorldLocationRepository = new WorldLocationRepository(dbHelper);
      await locationRepo.insertWithStore(store, createWorldLocationRecord({
        id: locationId,
        worldId: worldId,
        name: 'CascadeLoc',
        canonicalKey: 'cascadeloc',
        status: WorldLocationStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await sceneRepo.insertWithStore(store, createWorldSceneRecord({
        id: sceneId,
        worldId: worldId,
        locationId: locationId,
        startedAt: 1000,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await instanceRepo.insertWithStore(store, createWorldCharacterInstanceRecord({
        id: instanceId,
        worldId: worldId,
        characterId: 'char-cascade',
        displayNameSnapshot: 'CascadeChar',
        currentLocationId: locationId,
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await profileRepo.insertWithStore(store, createWorldPlayerProfileRecord({
        id: 'profile-cascade',
        worldId: worldId,
        displayName: 'CascadePlayer',
        createdAt: 1000,
        updatedAt: 1000
      }));
      const session = await sessionService.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 2000
      });
      expect(session.id.length > 0).assertTrue();
      await stateService.deleteWorld(worldId);
      const found = await sessionRepo.getById(session.id);
      expect(found).assertNull();
    });

    it('SESSIONLIFE-40: deleteWorld 级联删除玩家档案', 0, async () => {
      const worldId = 'w-cascade-profile';
      const locationId = 'loc-cascade-profile';
      const sceneId = 'scene-cascade-profile';
      const instanceId = 'ci-cascade-profile';
      const profileId = 'profile-cascade-2';

      const store: relationalStore.RdbStore = dbHelper.getStore();
      await worldRepo.insertWithStore(store, createWorldRecord({
        id: worldId,
        name: 'CascadeProfileWorld',
        status: WorldStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      const locationRepo: WorldLocationRepository = new WorldLocationRepository(dbHelper);
      await locationRepo.insertWithStore(store, createWorldLocationRecord({
        id: locationId,
        worldId: worldId,
        name: 'CascadeProfileLoc',
        canonicalKey: 'cascadeprofileloc',
        status: WorldLocationStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await sceneRepo.insertWithStore(store, createWorldSceneRecord({
        id: sceneId,
        worldId: worldId,
        locationId: locationId,
        startedAt: 1000,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await instanceRepo.insertWithStore(store, createWorldCharacterInstanceRecord({
        id: instanceId,
        worldId: worldId,
        characterId: 'char-cascade-2',
        displayNameSnapshot: 'CascadeChar2',
        currentLocationId: locationId,
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await profileRepo.insertWithStore(store, createWorldPlayerProfileRecord({
        id: profileId,
        worldId: worldId,
        displayName: 'CascadePlayer2',
        createdAt: 1000,
        updatedAt: 1000
      }));
      await stateService.deleteWorld(worldId);
      const profile = await profileRepo.getByWorldId(worldId);
      expect(profile).assertNull();
    });

    it('SESSIONLIFE-41: WorldConversationSessionError.isSessionError 识别正确', 0, () => {
      const err: WorldConversationSessionError = WorldConversationSessionError.worldNotFound();
      expect(isSessionError(err)).assertTrue();
    });

    it('SESSIONLIFE-42: 普通 Error 不被 isSessionError 识别', 0, () => {
      const err: Error = new Error('generic');
      expect(isSessionError(err)).assertFalse();
    });

    it('SESSIONLIFE-43: SessionErrorKind 枚举覆盖全部 24 种', 0, () => {
      const kinds: SessionErrorKind[] = [
        SessionErrorKind.WorldNotFound,
        SessionErrorKind.WorldNotActive,
        SessionErrorKind.SceneNotFound,
        SessionErrorKind.SceneWorldMismatch,
        SessionErrorKind.SceneNotActive,
        SessionErrorKind.PlayerProfileNotFound,
        SessionErrorKind.NoParticipants,
        SessionErrorKind.DuplicateParticipant,
        SessionErrorKind.ParticipantNotFound,
        SessionErrorKind.ParticipantWorldMismatch,
        SessionErrorKind.ParticipantInactive,
        SessionErrorKind.ParticipantLocationMismatch,
        SessionErrorKind.ActiveSessionAlreadyExists,
        SessionErrorKind.ActiveSessionDataCorrupted,
        SessionErrorKind.SessionNotFound,
        SessionErrorKind.SessionWorldMismatch,
        SessionErrorKind.SessionSceneMismatch,
        SessionErrorKind.SessionAlreadyEnded,
        SessionErrorKind.PreviousSessionNotFound,
        SessionErrorKind.PreviousSessionWorldMismatch,
        SessionErrorKind.PreviousSessionSceneMismatch,
        SessionErrorKind.PreviousSessionNotEnded,
        SessionErrorKind.InvalidEndedAt,
        SessionErrorKind.Internal
      ];
      expect(kinds.length).assertEqual(24);
    });

    it('SESSIONLIFE-44: WorldConversationSessionError 继承 Error 的 name 属性', 0, () => {
      const err: WorldConversationSessionError = WorldConversationSessionError.noParticipants();
      expect(err.name).assertEqual('WorldConversationSessionError');
      expect(err.kind).assertEqual(SessionErrorKind.NoParticipants);
    });

    it('SESSIONLIFE-45: Repository nextSequenceNumberForSceneWithStore 首次返回 1', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const seq = await sessionRepo.nextSequenceNumberForSceneWithStore(store, 'scene-no-sessions');
      expect(seq).assertEqual(1);
    });
  });
}
