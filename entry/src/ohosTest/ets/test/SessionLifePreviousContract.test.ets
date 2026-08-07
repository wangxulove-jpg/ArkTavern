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
  createWorldSceneRecord
} from '../../../main/ets/models/world/WorldScene';
import {
  createWorldCharacterInstanceRecord
} from '../../../main/ets/models/world/WorldCharacterInstance';
import {
  WorldConversationSessionStatus
} from '../../../main/ets/models/world/WorldConversationSession';
import {
  WorldConversationSessionError,
  SessionErrorKind
} from '../../../main/ets/models/world/WorldConversationSessionError';

const TEST_DB: string = 'sessionlife_previous_contract_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function sessionLifePreviousContractTest(): void {
  describe('SESSIONLIFE previousSessionId 契约', () => {
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

      worldId = 'w-sl-prev';
      locationId = 'loc-sl-prev';
      sceneId = 'scene-sl-prev';
      instanceId = 'ci-sl-prev';

      const store: relationalStore.RdbStore = dbHelper.getStore();
      await worldRepo.insertWithStore(store, createWorldRecord({
        id: worldId,
        name: 'PrevWorld',
        status: WorldStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await locationRepo.insertWithStore(store, createWorldLocationRecord({
        id: locationId,
        worldId: worldId,
        name: 'PrevLocation',
        canonicalKey: 'prevlocation',
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
        characterId: 'char-prev',
        displayNameSnapshot: 'PrevChar',
        currentLocationId: locationId,
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await profileRepo.insertWithStore(store, createWorldPlayerProfileRecord({
        id: 'profile-sl-prev',
        worldId: worldId,
        displayName: 'PrevPlayer',
        createdAt: 1000,
        updatedAt: 1000
      }));
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('SESSIONLIFE-31: startSession previousSessionId 不存在抛 PreviousSessionNotFound', 0, async () => {
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId],
          previousSessionId: 'nonexistent-prev-session'
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.PreviousSessionNotFound);
      }
    });

    it('SESSIONLIFE-32: startSession previousSessionId 不属于同世界抛 PreviousSessionWorldMismatch', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const otherWorldId = 'w-other-prev';
      const otherLocationId = 'loc-other-prev';
      const otherSceneId = 'scene-other-prev';
      const otherInstanceId = 'ci-other-prev';
      await worldRepo.insertWithStore(store, createWorldRecord({
        id: otherWorldId,
        name: 'OtherPrevWorld',
        status: WorldStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      const otherLocRepo: WorldLocationRepository = new WorldLocationRepository(dbHelper);
      await otherLocRepo.insertWithStore(store, createWorldLocationRecord({
        id: otherLocationId,
        worldId: otherWorldId,
        name: 'OtherPrevLoc',
        canonicalKey: 'otherprevloc',
        status: WorldLocationStatus.Active,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await sceneRepo.insertWithStore(store, createWorldSceneRecord({
        id: otherSceneId,
        worldId: otherWorldId,
        locationId: otherLocationId,
        startedAt: 1000,
        createdAt: 1000,
        updatedAt: 1000
      }));
      await instanceRepo.insertWithStore(store, createWorldCharacterInstanceRecord({
        id: otherInstanceId,
        worldId: otherWorldId,
        characterId: 'char-other-prev',
        displayNameSnapshot: 'OtherPrevChar',
        currentLocationId: otherLocationId,
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      const otherProfileRepo: WorldPlayerProfileRepository = new WorldPlayerProfileRepository(dbHelper);
      await otherProfileRepo.insertWithStore(store, createWorldPlayerProfileRecord({
        id: 'profile-other-prev',
        worldId: otherWorldId,
        displayName: 'OtherPlayer',
        createdAt: 1000,
        updatedAt: 1000
      }));
      const prevSession = await service.startSession({
        worldId: otherWorldId,
        sceneId: otherSceneId,
        participantCharacterInstanceIds: [otherInstanceId],
        startedAt: 2000
      });
      await service.endSession({ worldId: otherWorldId, sessionId: prevSession.id, endedAt: 3000 });
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId],
          previousSessionId: prevSession.id
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.PreviousSessionWorldMismatch);
      }
    });

    it('SESSIONLIFE-33: startSession previousSessionId 不属于同场景抛 PreviousSessionSceneMismatch', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const otherSceneId2 = 'scene-prev-mismatch';
      await sceneRepo.insertWithStore(store, createWorldSceneRecord({
        id: otherSceneId2,
        worldId: worldId,
        locationId: locationId,
        startedAt: 1000,
        createdAt: 1000,
        updatedAt: 1000
      }));
      const instanceId2 = 'ci-prev-mismatch';
      await instanceRepo.insertWithStore(store, createWorldCharacterInstanceRecord({
        id: instanceId2,
        worldId: worldId,
        characterId: 'char-prev-mismatch',
        displayNameSnapshot: 'PrevMismatch',
        currentLocationId: locationId,
        isActive: true,
        createdAt: 1000,
        updatedAt: 1000
      }));
      const prevSession = await service.startSession({
        worldId: worldId,
        sceneId: otherSceneId2,
        participantCharacterInstanceIds: [instanceId2],
        startedAt: 4000
      });
      await service.endSession({ worldId: worldId, sessionId: prevSession.id, endedAt: 5000 });
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId],
          previousSessionId: prevSession.id
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.PreviousSessionSceneMismatch);
      }
    });

    it('SESSIONLIFE-34: startSession previousSessionId 仍 Active 抛 PreviousSessionNotEnded', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      let active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const prevSession = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 6000
      });
      try {
        await service.startSession({
          worldId: worldId,
          sceneId: sceneId,
          participantCharacterInstanceIds: [instanceId],
          previousSessionId: prevSession.id
        });
        expect(true).assertFalse();
      } catch (e) {
        expect((e as WorldConversationSessionError).kind).assertEqual(SessionErrorKind.PreviousSessionNotEnded);
      }
    });

    it('SESSIONLIFE-35: startSession previousSessionId 已 Ended 正常通过', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      let active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const prevSession = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 7000
      });
      await service.endSession({ worldId: worldId, sessionId: prevSession.id, endedAt: 8000 });
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        previousSessionId: prevSession.id,
        startedAt: 9000
      });
      expect(session.status).assertEqual(WorldConversationSessionStatus.Active);
    });

    it('SESSIONLIFE-36: startSession previousSessionId 空字符串正常忽略', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      let active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        previousSessionId: '',
        startedAt: 10000
      });
      expect(session.id.length > 0).assertTrue();
    });

    it('SESSIONLIFE-37: startSession 不传 previousSessionId 正常', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      let active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 11000
      });
      expect(session.id.length > 0).assertTrue();
    });

    it('SESSIONLIFE-38: startSession 不自动复制前序会话的消息或快照', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      let active = await sessionRepo.getActiveBySceneIdWithStore(store, sceneId);
      if (active !== null) {
        await service.endSession({ worldId: worldId, sessionId: active.id });
      }
      const prevSession = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        startedAt: 12000
      });
      await service.endSession({ worldId: worldId, sessionId: prevSession.id, endedAt: 13000 });
      const session = await service.startSession({
        worldId: worldId,
        sceneId: sceneId,
        participantCharacterInstanceIds: [instanceId],
        previousSessionId: prevSession.id,
        startedAt: 14000
      });
      expect(session.id !== prevSession.id).assertTrue();
      expect(session.sequenceNumber > prevSession.sequenceNumber).assertTrue();
    });
  });
}
