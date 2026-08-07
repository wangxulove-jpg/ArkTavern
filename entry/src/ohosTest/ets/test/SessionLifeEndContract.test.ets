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
  WorldSceneStatus,
  createWorldSceneRecord
} from '../../../main/ets/models/world/WorldScene';
import {
  createWorldCharacterInstanceRecord
} from '../../../main/ets/models/world/WorldCharacterInstance';
import { WorldConversationSessionStatus } from '../../../main/ets/models/world/WorldConversationSession';
import {
  WorldConversationSessionError,
  SessionErrorKind
} from '../../../main/ets/models/world/WorldConversationSessionError';

const TEST_DB: string = 'sessionlife_end_contract_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function sessionLifeEndContractTest(): void {
  describe('SESSIONLIFE endSession 与 getActiveSessionForScene 契约', () => {
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
    let instanceId: string;

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

      worldId = 'w-sl-end';
      locationId = 'loc-sl-end';
      sceneId = 'scene-sl-end';
      instanceId = 'ci-sl-end';

      const store: relationalStore.RdbStore = dbHelper.getStore();
      await worldRepo.insertWithStore(store, createWorldRecord({
        id: worldId,
        name: 'EndWorld',
        status: WorldStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await locationRepo.insertWithStore(store, createWorldLocationRecord({
        id: locationId,
        worldId: worldId,
        name: 'EndLocation',
        canonicalKey: 'endlocation',
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
        characterId: 'char-end',
        displayNameSnapshot: 'EndChar',
        currentLocationId: locationId,
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await profileRepo.insertWithStore(store, createWorldPlayerProfileRecord({
        id: 'profile-sl-end',
        worldId: worldId,
        displayName: 'Player',
        createdAt: 1000,
        updatedAt: 1000
      }));
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('SESSIONLIFE-16: getActiveSessionForScene 无 Active 会话返回 null', 0, async () => {
      const result = await service.getActiveSessionForScene(worldId, sceneId);
      expect(result).assertNull();
    });

    it('SESSIONLIFE-17: getActiveSessionForScene 空 worldId 抛 WorldNotFound', 0, async () => {
      try {
        await service.getActiveSessionForScene('', sceneId);
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.WorldNotFound);
      }
    });

    it('SESSIONLIFE-18: getActiveSessionForScene 场景不属于该世界抛 SceneWorldMismatch', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await sceneRepo.insertWithStore(store, createWorldSceneRecord({
        id: 'scene-other-end',
        worldId: 'other-world-end',
        locationId: 'other-loc-end',
        startedAt: 1000,
        createdAt: 1000,
        updatedAt: 1000
      }));
      try {
        await service.getActiveSessionForScene(worldId, 'scene-other-end');
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.SceneWorldMismatch);
      }
    });

    it('SESSIONLIFE-19: endSession 空 sessionId 抛 SessionNotFound', 0, async () => {
      try {
        await service.endSession({ worldId: worldId, sessionId: '' });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.SessionNotFound);
      }
    });

    it('SESSIONLIFE-20: endSession 会话不存在抛 SessionNotFound', 0, async () => {
      try {
        await service.endSession({ worldId: worldId, sessionId: 'nonexistent-session' });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.SessionNotFound);
      }
    });

    it('SESSIONLIFE-21: endSession 会话不属于该世界抛 SessionWorldMismatch', 0, async () => {
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 5000
      });
      try {
        await service.endSession({ worldId: 'wrong-world', sessionId: session.id });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.SessionWorldMismatch);
      }
    });

    it('SESSIONLIFE-22: endSession 正常结束返回 Ended 会话', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id, endedAt: 7000 });
      }
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 8000
      });
      const ended = await service.endSession({ worldId: worldId, sessionId: session.id, endedAt: 9000 });
      expect(ended.status).assertEqual(WorldConversationSessionStatus.Ended);
      expect(ended.id).assertEqual(session.id);
    });

    it('SESSIONLIFE-23: endSession 幂等 - 已结束会话返回原 Ended 记录', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 10000
      });
      const ended1 = await service.endSession({ worldId: worldId, sessionId: session.id, endedAt: 11000 });
      expect(ended1.status).assertEqual(WorldConversationSessionStatus.Ended);
      const ended2 = await service.endSession({ worldId: worldId, sessionId: session.id, endedAt: 12000 });
      expect(ended2.status).assertEqual(WorldConversationSessionStatus.Ended);
      expect(ended2.updatedAt).assertEqual(ended1.updatedAt);
    });

    it('SESSIONLIFE-24: getActiveSessionForScene 有 Active 会话返回该会话', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 13000
      });
      const result = await service.getActiveSessionForScene(worldId, sceneId);
      expect(result !== null).assertTrue();
      expect(result!.status).assertEqual(WorldConversationSessionStatus.Active);
    });

    it('SESSIONLIFE-25: endSession 后 getActiveSessionForScene 返回 null', 0, async () => {
      const active = await service.getActiveSessionForScene(worldId, sceneId);
      expect(active !== null).assertTrue();
      await service.endSession({ worldId: worldId, sessionId: active!.id });
      const result = await service.getActiveSessionForScene(worldId, sceneId);
      expect(result).assertNull();
    });

    it('SESSIONLIFE-26: endSession endedAt < createdAt 抛 InvalidEndedAt', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 15000
      });
      try {
        await service.endSession({ worldId: worldId, sessionId: session.id, endedAt: 14000 });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.InvalidEndedAt);
      }
    });

    it('SESSIONLIFE-27: startSession sequenceNumber 自增', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      let active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const s1 = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 16000
      });
      expect(s1.sequenceNumber).assertEqual(1);
      await service.endSession({ worldId: worldId, sessionId: s1.id });
      const s2 = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 17000
      });
      expect(s2.sequenceNumber).assertEqual(2);
      await service.endSession({ worldId: worldId, sessionId: s2.id });
    });

    it('SESSIONLIFE-28: startSession 参与者快照冻结 displayName', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      let active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 18000
      });
      expect(session.playerDisplayNameSnapshot).assertEqual('Player');
    });

    it('SESSIONLIFE-29: startSession 场景已结束(Scene ended)抛 SceneNotActive', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      let active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const endedSceneId = 'scene-ended-sl';
      await sceneRepo.insertWithStore(store, createWorldSceneRecord({
        id: endedSceneId,
        worldId: worldId,
        locationId: locationId,
        status: WorldSceneStatus.Ended,
        endedAt: 2000,
        startedAt: 1000,
        createdAt: 1000,
        updatedAt: 2000
      }));
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: endedSceneId,
          participantCharacterInstanceIds: [instanceId]
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.SceneNotActive);
      }
    });

    it('SESSIONLIFE-30: endSession 空 worldId 抛 WorldNotFound', 0, async () => {
      try {
        await service.endSession({ worldId: '', sessionId: 'some-session' });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.WorldNotFound);
      }
    });
  });
}
