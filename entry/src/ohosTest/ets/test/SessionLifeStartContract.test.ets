import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { WorldRepository } from '../../../main/ets/repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../../main/ets/repositories/world/WorldLocationRepository';
import { WorldPlayerProfileRepository } from '../../../main/ets/repositories/world/WorldPlayerProfileRepository';
import { WorldSceneRepository } from '../../../main/ets/repositories/world/WorldSceneRepository';
import { WorldCharacterInstanceRepository } from '../../../main/ets/repositories/world/WorldCharacterInstanceRepository';
import { WorldConversationSessionRepository } from '../../../main/ets/repositories/world/WorldConversationSessionRepository';
import { WorldConversationSessionService } from '../../../main/ets/services/world/WorldConversationSessionService';
import {
  World,
  WorldStatus,
  createWorldRecord
} from '../../../main/ets/models/world/World';
import {
  WorldLocation,
  WorldLocationStatus,
  createWorldLocationRecord
} from '../../../main/ets/models/world/WorldLocation';
import {
  WorldPlayerProfile,
  createWorldPlayerProfileRecord
} from '../../../main/ets/models/world/WorldPlayerProfile';
import {
  WorldScene,
  createWorldSceneRecord
} from '../../../main/ets/models/world/WorldScene';
import {
  WorldCharacterInstance,
  createWorldCharacterInstanceRecord
} from '../../../main/ets/models/world/WorldCharacterInstance';
import { WorldConversationSessionStatus } from '../../../main/ets/models/world/WorldConversationSession';
import {
  WorldConversationSessionError,
  SessionErrorKind
} from '../../../main/ets/models/world/WorldConversationSessionError';

const TEST_DB: string = 'sessionlife_start_contract_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function sessionLifeStartContractTest(): void {
  describe('SESSIONLIFE startSession 契约', () => {
    let dbHelper: DbHelper;
    let service: WorldConversationSessionService;
    let worldRepo: WorldRepository;
    let profileRepo: WorldPlayerProfileRepository;
    let sceneRepo: WorldSceneRepository;
    let instanceRepo: WorldCharacterInstanceRepository;
    let sessionRepo: WorldConversationSessionRepository;

    let worldId: string;
    let locationId: string;
    let sceneId: string;
    let instanceId1: string;
    let instanceId2: string;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
      worldRepo = new WorldRepository(dbHelper);
      const locationRepo: WorldLocationRepository = new WorldLocationRepository(dbHelper);
      profileRepo = new WorldPlayerProfileRepository(dbHelper);
      sceneRepo = new WorldSceneRepository(dbHelper);
      instanceRepo = new WorldCharacterInstanceRepository(dbHelper);
      sessionRepo = new WorldConversationSessionRepository(dbHelper);
      service = new WorldConversationSessionService(
        worldRepo,
        profileRepo,
        sceneRepo,
        instanceRepo,
        sessionRepo,
        dbHelper
      );

      worldId = 'w-sl-start';
      locationId = 'loc-sl-start';
      sceneId = 'scene-sl-start';
      instanceId1 = 'ci-sl-start-1';
      instanceId2 = 'ci-sl-start-2';

      const store: relationalStore.RdbStore = dbHelper.getStore();
      await worldRepo.insertWithStore(store, createWorldRecord({
        id: worldId,
        name: 'TestWorld',
        status: WorldStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await locationRepo.insertWithStore(store, createWorldLocationRecord({
        id: locationId,
        worldId: worldId,
        name: 'TestLocation',
        canonicalKey: 'testlocation',
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
        id: instanceId1,
        worldId: worldId,
        characterId: 'char-1',
        displayNameSnapshot: 'Alice',
        currentLocationId: locationId,
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await instanceRepo.insertWithStore(store, createWorldCharacterInstanceRecord({
        id: instanceId2,
        worldId: worldId,
        characterId: 'char-2',
        displayNameSnapshot: 'Bob',
        currentLocationId: locationId,
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await profileRepo.insertWithStore(store, createWorldPlayerProfileRecord({
        id: 'profile-sl-start',
        worldId: worldId,
        displayName: 'Hero',
        createdAt: 1000,
        updatedAt: 1000
      }));
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('SESSIONLIFE-01: startSession 空 worldId 抛 WorldNotFound', 0, async () => {
      try {
        await service.startSession({
          worldId: '',
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId1]
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.WorldNotFound);
      }
    });

    it('SESSIONLIFE-02: startSession 空 sceneId 抛 SceneNotFound', 0, async () => {
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: '',
          participantCharacterInstanceIds: [instanceId1]
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.SceneNotFound);
      }
    });

    it('SESSIONLIFE-03: startSession 无参与者抛 NoParticipants', 0, async () => {
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: []
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.NoParticipants);
      }
    });

    it('SESSIONLIFE-04: startSession 世界不存在抛 WorldNotFound', 0, async () => {
      try {
        await service.startSession({
          worldId: 'nonexistent',
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId1]
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.WorldNotFound);
      }
    });

    it('SESSIONLIFE-05: startSession 场景不属于该世界抛 SceneWorldMismatch', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await sceneRepo.insertWithStore(store, createWorldSceneRecord({
        id: 'scene-other-world',
        worldId: 'other-world',
        locationId: 'other-loc',
        startedAt: 1000,
        createdAt: 1000,
        updatedAt: 1000
      }));
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: 'scene-other-world',
          participantCharacterInstanceIds: [instanceId1]
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.SceneWorldMismatch);
      }
    });

    it('SESSIONLIFE-06: startSession 参与者不存在抛 ParticipantNotFound', 0, async () => {
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: ['nonexistent-ci']
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.ParticipantNotFound);
      }
    });

    it('SESSIONLIFE-07: startSession 参与者不属于该世界抛 ParticipantWorldMismatch', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await instanceRepo.insertWithStore(store, createWorldCharacterInstanceRecord({
        id: 'ci-other-world',
        worldId: 'other-world',
        characterId: 'char-other',
        displayNameSnapshot: 'Eve',
        currentLocationId: 'other-loc',
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: ['ci-other-world']
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.ParticipantWorldMismatch);
      }
    });

    it('SESSIONLIFE-08: startSession 参与者未激活抛 ParticipantInactive', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await instanceRepo.insertWithStore(store, createWorldCharacterInstanceRecord({
        id: 'ci-inactive',
        worldId: worldId,
        characterId: 'char-inactive',
        displayNameSnapshot: 'Inactive',
        currentLocationId: locationId,
        isActive: false,
        createdAt: 1000,
        updatedAt: 1000
      }));
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: ['ci-inactive']
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.ParticipantInactive);
      }
    });

    it('SESSIONLIFE-09: startSession 参与者不在场景地点抛 ParticipantLocationMismatch', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await instanceRepo.insertWithStore(store, createWorldCharacterInstanceRecord({
        id: 'ci-wrong-loc',
        worldId: worldId,
        characterId: 'char-wrong-loc',
        displayNameSnapshot: 'WrongLoc',
        currentLocationId: 'other-location-id',
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: ['ci-wrong-loc']
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.ParticipantLocationMismatch);
      }
    });

    it('SESSIONLIFE-10: startSession 无玩家档案抛 PlayerProfileNotFound', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await worldRepo.insertWithStore(store, createWorldRecord({
        id: 'w-no-profile',
        name: 'NoProfile',
        status: WorldStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      try {
        await service.startSession({
          worldId: 'w-no-profile',
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId1]
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.PlayerProfileNotFound);
      }
    });

    it('SESSIONLIFE-11: startSession 重复参与者抛 DuplicateParticipant', 0, async () => {
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId1, instanceId1]
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.DuplicateParticipant);
      }
    });

    it('SESSIONLIFE-12: startSession 正常创建返回 Active 会话', 0, async () => {
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId1, instanceId2],
        startedAt: 5000
      });
      expect(session.status).assertEqual(WorldConversationSessionStatus.Active);
      expect(session.worldId).assertEqual(worldId);
      expect(session.sceneId).assertEqual(sceneId);
      expect(session.sequenceNumber).assertEqual(1);
      expect(session.playerDisplayNameSnapshot).assertEqual('Hero');
      expect(session.createdAt).assertEqual(5000);
      expect(session.participantSnapshotJson.length > 0).assertTrue();
    });

    it('SESSIONLIFE-13: startSession 已有 Active 会话抛 ActiveSessionAlreadyExists', 0, async () => {
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId1],
          startedAt: 6000
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.ActiveSessionAlreadyExists);
      }
    });

    it('SESSIONLIFE-14: startSession 归档世界抛 WorldNotActive', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await worldRepo.insertWithStore(store, createWorldRecord({
        id: 'w-archived',
        name: 'ArchivedWorld',
        status: WorldStatus.Archived,
        createdAt: 1000,
        updatedAt: 1000
      }));
      try {
        await service.startSession({
          worldId: 'w-archived',
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId1]
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.WorldNotActive);
      }
    });

    it('SESSIONLIFE-15: startSession 参与者 participantId 为 "user" 抛 ParticipantNotFound', 0, async () => {
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: ['user']
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.ParticipantNotFound);
      }
    });
  });
}
