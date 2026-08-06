import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  createWorldConversationSessionRecord,
  isWorldConversationSessionStatus,
  WORLD_CONVERSATION_SESSION_ID_PREFIX
} from '../../../main/ets/models/world/WorldConversationSession';
import { WorldConversationSessionRepository } from '../../../main/ets/repositories/world/WorldConversationSessionRepository';

const TEST_DB: string = 'w1a_conversation_session_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function worldConversationSessionContractTest(): void {
  describe('WorldConversationSession 数据契约', () => {
    let dbHelper: DbHelper;
    let repo: WorldConversationSessionRepository;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
      repo = new WorldConversationSessionRepository(dbHelper);
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('createWorldConversationSessionRecord 正常创建 Active', () => {
      const session: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-1',
        worldId: 'world-1',
        sceneId: 'scene-1',
        sequenceNumber: 0,
        participantSnapshotJson: '[{"characterInstanceId":"ci-1","displayName":"Alice","locationId":"loc-1"}]',
        playerDisplayNameSnapshot: 'Hero'
      });
      expect(session.id).assertEqual('session-1');
      expect(session.status).assertEqual(WorldConversationSessionStatus.Active);
      expect(session.sequenceNumber).assertEqual(0);
      expect(session.playerDisplayNameSnapshot).assertEqual('Hero');
      expect(session.createdAt > 0).assertTrue();
    });

    it('createWorldConversationSessionRecord 空 sceneId 抛错', () => {
      try {
        createWorldConversationSessionRecord({
          id: 'session-2',
          worldId: 'world-1',
          sceneId: '',
          sequenceNumber: 0
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('createWorldConversationSessionRecord 负 sequenceNumber 抛错', () => {
      try {
        createWorldConversationSessionRecord({
          id: 'session-3',
          worldId: 'world-1',
          sceneId: 'scene-1',
          sequenceNumber: -1
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('isWorldConversationSessionStatus 校验', () => {
      expect(isWorldConversationSessionStatus('active')).assertTrue();
      expect(isWorldConversationSessionStatus('ended')).assertTrue();
      expect(isWorldConversationSessionStatus('invalid')).assertFalse();
    });

    it('insert + getById 成功', async () => {
      const session: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-ins-1',
        worldId: 'world-ins-1',
        sceneId: 'scene-ins-1',
        sequenceNumber: 0,
        participantSnapshotJson: '[]',
        playerDisplayNameSnapshot: 'Player'
      });
      await repo.insert(session);
      const found: WorldConversationSession | null = await repo.getById('session-ins-1');
      expect(found !== null).assertTrue();
      expect(found!.sceneId).assertEqual('scene-ins-1');
      expect(found!.participantSnapshotJson).assertEqual('[]');
    });

    it('UNIQUE(sceneId, sequenceNumber) 重复插入抛 alreadyExists', async () => {
      const s1: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-uniq-1',
        worldId: 'world-uniq-1',
        sceneId: 'scene-uniq-1',
        sequenceNumber: 0
      });
      await repo.insert(s1);
      const s2: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-uniq-2',
        worldId: 'world-uniq-1',
        sceneId: 'scene-uniq-1',
        sequenceNumber: 0
      });
      try {
        await repo.insert(s2);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('getActiveBySceneId 多个 Active 抛 invalidData', async () => {
      const s1: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-multi-1',
        worldId: 'world-multi-1',
        sceneId: 'scene-multi-1',
        sequenceNumber: 0,
        status: WorldConversationSessionStatus.Active
      });
      const s2: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-multi-2',
        worldId: 'world-multi-1',
        sceneId: 'scene-multi-1',
        sequenceNumber: 1,
        status: WorldConversationSessionStatus.Active
      });
      await dbHelper.runInTransaction('w1a_test', async (store) => {
        await repo.insertWithStore(store, s1);
        await repo.insertWithStore(store, s2);
      });
      try {
        await repo.getActiveBySceneId('scene-multi-1');
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('listBySceneId 按 sequenceNumber ASC 排序', async () => {
      const s1: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-list-1',
        worldId: 'world-list-1',
        sceneId: 'scene-list-1',
        sequenceNumber: 2
      });
      const s2: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-list-2',
        worldId: 'world-list-1',
        sceneId: 'scene-list-1',
        sequenceNumber: 0
      });
      const s3: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-list-3',
        worldId: 'world-list-1',
        sceneId: 'scene-list-1',
        sequenceNumber: 1
      });
      await dbHelper.runInTransaction('w1a_test', async (store) => {
        await repo.insertWithStore(store, s1);
        await repo.insertWithStore(store, s2);
        await repo.insertWithStore(store, s3);
      });
      const list: WorldConversationSession[] = await repo.listBySceneId('scene-list-1');
      expect(list.length).assertEqual(3);
      expect(list[0].sequenceNumber).assertEqual(0);
      expect(list[1].sequenceNumber).assertEqual(1);
      expect(list[2].sequenceNumber).assertEqual(2);
    });

    it('deleteByWorldIdWithStore 成功删除', async () => {
      const session: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-dw-1',
        worldId: 'world-dw-1',
        sceneId: 'scene-dw-1',
        sequenceNumber: 0
      });
      await repo.insert(session);
      await dbHelper.runInTransaction('w1a_test', async (store) => {
        await repo.deleteByWorldIdWithStore(store, 'world-dw-1');
      });
      const found: WorldConversationSession | null = await repo.getById('session-dw-1');
      expect(found).assertNull();
    });

    it('ID_PREFIX 格式正确', () => {
      expect(WORLD_CONVERSATION_SESSION_ID_PREFIX).assertEqual('world-conversation-session-');
    });

    it('ParticipantSnapshot 使用完整字段名(非缩写)', () => {
      const json: string = '[{"characterInstanceId":"ci-1","displayName":"Alice","locationId":"loc-1"}]';
      const session: WorldConversationSession = createWorldConversationSessionRecord({
        id: 'session-snap-1',
        worldId: 'world-snap-1',
        sceneId: 'scene-snap-1',
        sequenceNumber: 0,
        participantSnapshotJson: json
      });
      expect(session.participantSnapshotJson.indexOf('cid')).assertEqual(-1);
      expect(session.participantSnapshotJson.indexOf('characterInstanceId')).assertGreater(-1);
    });
  });
}
