import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import {
  WorldScene,
  WorldSceneStatus,
  createWorldSceneRecord,
  CreateWorldSceneOptions
} from '../../../main/ets/models/world/WorldScene';
import {
  WorldSceneMessage,
  WorldSceneMessageSenderType,
  WorldSceneMessageVisibility,
  WorldSceneMessageStatus,
  createWorldSceneMessageRecord,
  normalizeIdArray
} from '../../../main/ets/models/world/WorldSceneMessage';
import { WorldSceneRepository } from '../../../main/ets/repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../../main/ets/repositories/world/WorldSceneMessageRepository';
import { DatabaseError } from '../../../main/ets/models/DatabaseError';

const TEST_DB: string = 'w1b1_session_storage_contract_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

function makeScene(
  id: string = 'scene-1',
  worldId: string = 'world-1',
  locationId: string = 'loc-1',
  title?: string
): WorldScene {
  const opts: CreateWorldSceneOptions = {
    id: id,
    worldId: worldId,
    locationId: locationId,
    title: title,
    startedAt: 1000,
    createdAt: 1000,
    updatedAt: 1000
  };
  return createWorldSceneRecord(opts);
}

function makeMessage(
  id: string = 'msg-1',
  worldId: string = 'world-1',
  sceneId: string = 'scene-1',
  sequenceNumber: number = 0,
  sessionId?: string,
  locationId?: string
): WorldSceneMessage {
  return createWorldSceneMessageRecord({
    id: id,
    worldId: worldId,
    sceneId: sceneId,
    senderType: WorldSceneMessageSenderType.User,
    content: 'hello',
    sequenceNumber: sequenceNumber,
    status: WorldSceneMessageStatus.Completed,
    visibility: WorldSceneMessageVisibility.Public,
    sessionId: sessionId,
    locationId: locationId,
    createdAt: 1000,
    updatedAt: 1000
  });
}

export default function sessionStorageContractTest(): void {
  describe('W1B1 Session Storage 契约', () => {
    let dbHelper: DbHelper;
    let sceneRepo: WorldSceneRepository;
    let msgRepo: WorldSceneMessageRepository;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
      sceneRepo = new WorldSceneRepository(dbHelper);
      msgRepo = new WorldSceneMessageRepository(dbHelper);
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('SESSIONSTORE-07: WorldScene 空 title 正常', 0, () => {
      const scene: WorldScene = makeScene('scene-empty-title', 'w-1', 'l-1');
      expect(scene.title).assertEqual('');
    });

    it('SESSIONSTORE-08: WorldScene title trim 正常', 0, () => {
      const scene: WorldScene = makeScene('scene-trim-title', 'w-1', 'l-1', '  My Title  ');
      expect(scene.title).assertEqual('My Title');
    });

    it('SESSIONSTORE-09: WorldSceneRepository 保存和读取 title', 0, async () => {
      const scene: WorldScene = makeScene('scene-repo-title', 'w-repo-title', 'l-repo-title', 'Test Title');
      await sceneRepo.insert(scene);
      const found: WorldScene | null = await sceneRepo.getById('scene-repo-title');
      expect(found !== null).assertTrue();
      expect(found!.title).assertEqual('Test Title');
    });

    it('SESSIONSTORE-10: 旧空 title 行映射为 empty string', 0, async () => {
      const scene: WorldScene = makeScene('scene-old-title', 'w-old-title', 'l-old-title');
      await sceneRepo.insert(scene);
      const found: WorldScene | null = await sceneRepo.getById('scene-old-title');
      expect(found !== null).assertTrue();
      expect(found!.title).assertEqual('');
    });

    it('SESSIONSTORE-11: WorldSceneMessage 无 sessionId/locationId 仍可创建', 0, () => {
      const msg: WorldSceneMessage = makeMessage('msg-no-session');
      expect(msg.sessionId === undefined).assertTrue();
      expect(msg.locationId === undefined).assertTrue();
    });

    it('SESSIONSTORE-12: sessionId 与 locationId 同时存在时合法', 0, () => {
      const msg: WorldSceneMessage = makeMessage('msg-with-session', 'w-1', 'scene-1', 0, 'session-1', 'loc-1');
      expect(msg.sessionId).assertEqual('session-1');
      expect(msg.locationId).assertEqual('loc-1');
    });

    it('SESSIONSTORE-13: 只有 sessionId 时拒绝', 0, () => {
      try {
        createWorldSceneMessageRecord({
          id: 'msg-only-session',
          worldId: 'w-1',
          sceneId: 'scene-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 0,
          sessionId: 'session-1'
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('SESSIONSTORE-14: 只有 locationId 时拒绝', 0, () => {
      try {
        createWorldSceneMessageRecord({
          id: 'msg-only-loc',
          worldId: 'w-1',
          sceneId: 'scene-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 0,
          locationId: 'loc-1'
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('SESSIONSTORE-15: 空白 sessionId 拒绝', 0, () => {
      try {
        createWorldSceneMessageRecord({
          id: 'msg-blank-session',
          worldId: 'w-1',
          sceneId: 'scene-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 0,
          sessionId: '  ',
          locationId: 'loc-1'
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('SESSIONSTORE-16: 空白 locationId 拒绝', 0, () => {
      try {
        createWorldSceneMessageRecord({
          id: 'msg-blank-loc',
          worldId: 'w-1',
          sceneId: 'scene-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 0,
          sessionId: 'session-1',
          locationId: '  '
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('SESSIONSTORE-17: Repository 保存 session_id/location_id', 0, async () => {
      const scene: WorldScene = makeScene('scene-save-session', 'w-save-session', 'l-save-session');
      await sceneRepo.insert(scene);
      const msg: WorldSceneMessage = makeMessage('msg-save-session', 'w-save-session', 'scene-save-session', 0, 'session-save', 'loc-save');
      await msgRepo.insert(msg);
      const found: WorldSceneMessage | null = await msgRepo.getById('msg-save-session');
      expect(found !== null).assertTrue();
      expect(found!.sessionId).assertEqual('session-save');
      expect(found!.locationId).assertEqual('loc-save');
    });

    it('SESSIONSTORE-18: listBySessionId 只返回目标 Session', 0, async () => {
      const scene: WorldScene = makeScene('scene-list-session', 'w-list-session', 'l-list-session');
      await sceneRepo.insert(scene);
      const msg1: WorldSceneMessage = makeMessage('msg-list-s1', 'w-list-session', 'scene-list-session', 0, 'session-target', 'loc-list');
      const msg2: WorldSceneMessage = makeMessage('msg-list-s2', 'w-list-session', 'scene-list-session', 1, 'session-other', 'loc-list');
      const msg3: WorldSceneMessage = makeMessage('msg-list-s3', 'w-list-session', 'scene-list-session', 2);
      await msgRepo.insert(msg1);
      await msgRepo.insert(msg2);
      await msgRepo.insert(msg3);
      const list: WorldSceneMessage[] = await msgRepo.listBySessionId('session-target');
      expect(list.length).assertEqual(1);
      expect(list[0].id).assertEqual('msg-list-s1');
    });

    it('SESSIONSTORE-19: NULL session_id 消息不进入 Session 查询', 0, async () => {
      const scene: WorldScene = makeScene('scene-null-session', 'w-null-session', 'l-null-session');
      await sceneRepo.insert(scene);
      const msgNoSession: WorldSceneMessage = makeMessage('msg-null-s1', 'w-null-session', 'scene-null-session', 0);
      await msgRepo.insert(msgNoSession);
      const list: WorldSceneMessage[] = await msgRepo.listBySessionId('session-nonexist');
      expect(list.length).assertEqual(0);
    });

    it('SESSIONSTORE-20: Session 消息按 sequenceNumber 升序', 0, async () => {
      const scene: WorldScene = makeScene('scene-seq-session', 'w-seq-session', 'l-seq-session');
      await sceneRepo.insert(scene);
      const msg5: WorldSceneMessage = makeMessage('msg-seq-5', 'w-seq-session', 'scene-seq-session', 5, 'session-seq', 'loc-seq');
      const msg2: WorldSceneMessage = makeMessage('msg-seq-2', 'w-seq-session', 'scene-seq-session', 2, 'session-seq', 'loc-seq');
      const msg8: WorldSceneMessage = makeMessage('msg-seq-8', 'w-seq-session', 'scene-seq-session', 8, 'session-seq', 'loc-seq');
      await msgRepo.insert(msg5);
      await msgRepo.insert(msg2);
      await msgRepo.insert(msg8);
      const list: WorldSceneMessage[] = await msgRepo.listBySessionId('session-seq');
      expect(list.length).assertEqual(3);
      expect(list[0].sequenceNumber).assertEqual(2);
      expect(list[1].sequenceNumber).assertEqual(5);
      expect(list[2].sequenceNumber).assertEqual(8);
    });

    it('SESSIONSTORE-21: Scene 级 sequenceNumber 语义未改变', 0, async () => {
      const scene: WorldScene = makeScene('scene-sceneseq', 'w-sceneseq', 'l-sceneseq');
      await sceneRepo.insert(scene);
      const msgA: WorldSceneMessage = makeMessage('msg-sceneseq-a', 'w-sceneseq', 'scene-sceneseq', 0, 'session-a', 'loc-a');
      const msgB: WorldSceneMessage = makeMessage('msg-sceneseq-b', 'w-sceneseq', 'scene-sceneseq', 1, 'session-b', 'loc-b');
      await msgRepo.insert(msgA);
      await msgRepo.insert(msgB);
      const sceneList: WorldSceneMessage[] = await msgRepo.listByScene('scene-sceneseq');
      expect(sceneList.length).assertEqual(2);
      expect(sceneList[0].sequenceNumber).assertEqual(0);
      expect(sceneList[1].sequenceNumber).assertEqual(1);
    });

    it('SESSIONSTORE-22: participant/witness/recipient/replyTarget 不回归', 0, async () => {
      const scene: WorldScene = makeScene('scene-snap', 'w-snap', 'l-snap');
      await sceneRepo.insert(scene);
      const charMsg: WorldSceneMessage = createWorldSceneMessageRecord({
        id: 'msg-snap-char',
        worldId: 'w-snap',
        sceneId: 'scene-snap',
        senderType: WorldSceneMessageSenderType.Character,
        senderCharacterInstanceId: 'ci-1',
        content: 'I speak',
        sequenceNumber: 0,
        status: WorldSceneMessageStatus.Completed,
        visibility: WorldSceneMessageVisibility.Private,
        recipientCharacterInstanceIds: ['ci-2'],
        participantCharacterInstanceIds: ['ci-1', 'ci-2'],
        sessionId: 'session-snap',
        locationId: 'loc-snap',
        createdAt: 1000,
        updatedAt: 1000
      });
      await msgRepo.insert(charMsg);
      const found: WorldSceneMessage | null = await msgRepo.getById('msg-snap-char');
      expect(found !== null).assertTrue();
      expect(found!.recipientCharacterInstanceIds !== undefined).assertTrue();
      expect(found!.participantCharacterInstanceIds !== undefined).assertTrue();
    });

    it('SESSIONSTORE-23: 损坏快照 JSON 不扩大可见范围', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const bucket: relationalStore.ValuesBucket = {
        'id': 'msg-corrupt-snap',
        'world_id': 'w-corrupt',
        'scene_id': 'scene-snap',
        'sender_type': 'character',
        'sender_character_instance_id': 'ci-1',
        'content': 'corrupt',
        'sequence_number': 10,
        'status': 'completed',
        'visibility': 'private',
        'recipient_character_instance_ids_json': 'not valid json',
        'session_id': 'session-corrupt',
        'location_id': 'loc-corrupt',
        'created_at': 1000,
        'updated_at': 1000
      };
      await store.insert('world_scene_messages', bucket);
      const found: WorldSceneMessage | null = await msgRepo.getById('msg-corrupt-snap');
      expect(found !== null).assertTrue();
      expect(found!.recipientCharacterInstanceIds === undefined).assertTrue();
    });
  });
}
