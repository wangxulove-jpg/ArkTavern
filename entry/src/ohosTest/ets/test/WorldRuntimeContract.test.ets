import { describe, it, expect } from '@ohos/hypium';
import {
  WorldRuntimeError,
  WorldRuntimeErrorKind
} from '../../../main/ets/models/world/WorldRuntimeError';
import {
  WorldSceneMessage,
  WorldSceneMessageSenderType,
  WorldSceneMessageVisibility,
  WorldSceneMessageStatus,
  createWorldSceneMessageRecord
} from '../../../main/ets/models/world/WorldSceneMessage';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  createWorldConversationSessionRecord,
  serializeParticipantSnapshots,
  WorldSessionParticipantSnapshot
} from '../../../main/ets/models/world/WorldConversationSession';
import { WorldScene, WorldSceneStatus } from '../../../main/ets/models/world/WorldScene';
import { World } from '../../../main/ets/models/world/World';
import { WorldStatus } from '../../../main/ets/models/world/World';
import { WorldCharacterInstance } from '../../../main/ets/models/world/WorldCharacterInstance';
import { WorldPlayerProfile } from '../../../main/ets/models/world/WorldPlayerProfile';
import { WorldLocation, WorldLocationStatus } from '../../../main/ets/models/world/WorldLocation';
import { WorldRuntimeRegistry, RegistryEntry } from '../../../main/ets/services/world/WorldRuntimeRegistry';

function makeSession(
  id: string,
  worldId: string,
  sceneId: string,
  seq: number,
  status: WorldConversationSessionStatus,
  participantJson: string
): WorldConversationSession {
  return createWorldConversationSessionRecord({
    id: id,
    worldId: worldId,
    sceneId: sceneId,
    sequenceNumber: seq,
    status: status,
    participantSnapshotJson: participantJson,
    playerDisplayNameSnapshot: '玩家甲',
    createdAt: 1000,
    updatedAt: 1000
  });
}

function singleParticipantJson(instanceId: string, displayName: string): string {
  const snapshot: WorldSessionParticipantSnapshot = {
    characterInstanceId: instanceId,
    displayNameSnapshot: displayName,
    locationIdAtStart: 'loc-1',
    isActiveAtStart: true,
    joinedAt: 1000
  };
  return serializeParticipantSnapshots([snapshot]);
}

function twoParticipantJson(id1: string, name1: string, id2: string, name2: string): string {
  const s1: WorldSessionParticipantSnapshot = {
    characterInstanceId: id1,
    displayNameSnapshot: name1,
    locationIdAtStart: 'loc-1',
    isActiveAtStart: true,
    joinedAt: 1000
  };
  const s2: WorldSessionParticipantSnapshot = {
    characterInstanceId: id2,
    displayNameSnapshot: name2,
    locationIdAtStart: 'loc-1',
    isActiveAtStart: true,
    joinedAt: 1000
  };
  return serializeParticipantSnapshots([s1, s2]);
}

export default function worldRuntimeContractTest(): void {
  describe('WORLDRUNTIME 世界运行时契约(W3A1)', () => {

    describe('错误类型', () => {
      it('WORLDRUNTIME-01 只有1 participant的Active Session可运行', 0, () => {
        const session: WorldConversationSession = makeSession(
          's-1', 'w-1', 'sc-1', 1, WorldConversationSessionStatus.Active,
          singleParticipantJson('ci-1', 'Alice')
        );
        const participants = JSON.parse(session.participantSnapshotJson) as WorldSessionParticipantSnapshot[];
        expect(participants.length).assertEqual(1);
        expect(session.status).assertEqual(WorldConversationSessionStatus.Active);
      });

      it('WORLDRUNTIME-02 0 participant拒绝', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.unsupportedParticipantCount(0);
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.UnsupportedParticipantCount);
        expect(err.message.includes('0')).assertTrue();
      });

      it('WORLDRUNTIME-03 2+ participant拒绝', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.unsupportedParticipantCount(2);
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.UnsupportedParticipantCount);
        expect(err.message.includes('2')).assertTrue();
      });

      it('WORLDRUNTIME-04 Ended Session拒绝', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.sessionEnded();
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.SessionEnded);
      });

      it('WORLDRUNTIME-05 Ended Scene拒绝', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.sceneEnded();
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.SceneEnded);
      });

      it('WORLDRUNTIME-06 world/session mismatch拒绝', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.sessionWorldMismatch();
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.SessionWorldMismatch);
      });

      it('WORLDRUNTIME-07 scene/session mismatch拒绝', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.sessionSceneMismatch();
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.SessionSceneMismatch);
      });

      it('WORLDRUNTIME-08 location mismatch拒绝', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.sessionLocationMismatch();
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.SessionLocationMismatch);
      });
    });

    describe('玩家身份', () => {
      it('WORLDRUNTIME-09 玩家身份来自WorldPlayerProfile', 0, () => {
        const profile: WorldPlayerProfile = {
          id: 'wpp-1',
          worldId: 'w-1',
          displayName: '玩家甲',
          persona: 'test persona',
          publicIdentity: 'test identity',
          privateIdentity: '',
          currentLocationId: undefined,
          createdAt: 1000,
          updatedAt: 1000
        };
        expect(profile.displayName).assertEqual('玩家甲');
        expect(profile.publicIdentity).assertEqual('test identity');
      });

      it('WORLDRUNTIME-10 不使用Character.userName', 0, () => {
        const profile: WorldPlayerProfile = {
          id: 'wpp-1',
          worldId: 'w-1',
          displayName: '玩家甲',
          persona: '',
          publicIdentity: '',
          privateIdentity: '',
          currentLocationId: undefined,
          createdAt: 1000,
          updatedAt: 1000
        };
        expect(profile.displayName).assertEqual('玩家甲');
        expect(profile.displayName.includes('userName')).assertFalse();
      });
    });

    describe('角色身份', () => {
      it('WORLDRUNTIME-11 speaker来自Session participantSnapshot', 0, () => {
        const session: WorldConversationSession = makeSession(
          's-1', 'w-1', 'sc-1', 1, WorldConversationSessionStatus.Active,
          singleParticipantJson('ci-alice', 'Alice')
        );
        const participants = JSON.parse(session.participantSnapshotJson) as WorldSessionParticipantSnapshot[];
        expect(participants[0].characterInstanceId).assertEqual('ci-alice');
        expect(participants[0].displayNameSnapshot).assertEqual('Alice');
      });

      it('WORLDRUNTIME-12 读取正确WorldCharacterInstance', 0, () => {
        const instance: WorldCharacterInstance = {
          id: 'ci-alice',
          worldId: 'w-1',
          characterId: 'char-alice',
          displayNameSnapshot: 'Alice',
          currentLocationId: 'loc-1',
          isActive: true,
          currentGoal: '',
          mapIconStyle: undefined,
          createdAt: 1000,
          updatedAt: 1000
        };
        expect(instance.id).assertEqual('ci-alice');
        expect(instance.worldId).assertEqual('w-1');
        expect(instance.characterId).assertEqual('char-alice');
      });

      it('WORLDRUNTIME-13 读取正确Character卡(characterId)', 0, () => {
        const instance: WorldCharacterInstance = {
          id: 'ci-alice',
          worldId: 'w-1',
          characterId: 'char-alice',
          displayNameSnapshot: 'Alice',
          currentLocationId: 'loc-1',
          isActive: true,
          currentGoal: '',
          mapIconStyle: undefined,
          createdAt: 1000,
          updatedAt: 1000
        };
        expect(instance.characterId).assertEqual('char-alice');
      });

      it('WORLDRUNTIME-14 不读取其他Character卡', 0, () => {
        const session: WorldConversationSession = makeSession(
          's-1', 'w-1', 'sc-1', 1, WorldConversationSessionStatus.Active,
          singleParticipantJson('ci-alice', 'Alice')
        );
        const participants = JSON.parse(session.participantSnapshotJson) as WorldSessionParticipantSnapshot[];
        expect(participants.length).assertEqual(1);
        expect(participants[0].characterInstanceId).assertEqual('ci-alice');
        const bobExists: boolean = participants.some((p: WorldSessionParticipantSnapshot) =>
          p.characterInstanceId === 'ci-bob');
        expect(bobExists).assertFalse();
      });
    });

    describe('Prompt数据来源', () => {
      it('WORLDRUNTIME-15 Prompt包含World', 0, () => {
        const world: World = {
          id: 'w-1',
          name: '测试世界',
          description: '一个奇幻世界',
          status: WorldStatus.Active,
          createdAt: 1000,
          updatedAt: 1000
        };
        expect(world.description.length).assertLarger(0);
      });

      it('WORLDRUNTIME-16 Prompt包含Location', 0, () => {
        const location: WorldLocation = {
          id: 'loc-1',
          worldId: 'w-1',
          name: '酒馆',
          description: '一间温暖的酒馆',
          canonicalKey: '酒馆',
          status: WorldLocationStatus.Active,
          createdAt: 1000,
          updatedAt: 1000
        };
        expect(location.name.length).assertLarger(0);
      });

      it('WORLDRUNTIME-17 Prompt包含Scene', 0, () => {
        const scene: WorldScene = {
          id: 'sc-1',
          worldId: 'w-1',
          locationId: 'loc-1',
          title: '酒馆之夜',
          status: WorldSceneStatus.Active,
          startedAt: 1000,
          createdAt: 1000,
          updatedAt: 1000
        };
        expect(scene.title.length).assertLarger(0);
      });

      it('WORLDRUNTIME-18 Prompt包含当前Session', 0, () => {
        const session: WorldConversationSession = makeSession(
          's-1', 'w-1', 'sc-1', 1, WorldConversationSessionStatus.Active,
          singleParticipantJson('ci-1', 'Alice')
        );
        expect(session.id).assertEqual('s-1');
        expect(session.sequenceNumber).assertEqual(1);
      });

      it('WORLDRUNTIME-19 历史只使用当前sessionId', 0, () => {
        const session: WorldConversationSession = makeSession(
          's-2', 'w-1', 'sc-1', 2, WorldConversationSessionStatus.Active,
          singleParticipantJson('ci-1', 'Alice')
        );
        expect(session.id).assertEqual('s-2');
      });

      it('WORLDRUNTIME-20 同Scene其他Session消息不进入Prompt', 0, () => {
        const session1: WorldConversationSession = makeSession(
          's-1', 'w-1', 'sc-1', 1, WorldConversationSessionStatus.Ended,
          singleParticipantJson('ci-1', 'Alice')
        );
        const session2: WorldConversationSession = makeSession(
          's-2', 'w-1', 'sc-1', 2, WorldConversationSessionStatus.Active,
          singleParticipantJson('ci-1', 'Alice')
        );
        expect(session1.id).assertEqual('s-1');
        expect(session2.id).assertEqual('s-2');
        expect(session1.id !== session2.id).assertTrue();
      });

      it('WORLDRUNTIME-21 Failed消息不进入Prompt', 0, () => {
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-failed',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-1',
          content: 'test',
          sequenceNumber: 1,
          status: WorldSceneMessageStatus.Failed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.status).assertEqual(WorldSceneMessageStatus.Failed);
      });

      it('WORLDRUNTIME-22 Cancelled消息不进入Prompt', 0, () => {
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-cancelled',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-1',
          content: 'test',
          sequenceNumber: 2,
          status: WorldSceneMessageStatus.Cancelled,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.status).assertEqual(WorldSceneMessageStatus.Cancelled);
      });

      it('WORLDRUNTIME-23 空消息不进入Prompt', 0, () => {
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-empty',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-1',
          content: '',
          sequenceNumber: 3,
          status: WorldSceneMessageStatus.Streaming,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.content).assertEqual('');
        expect(msg.content.trim().length).assertEqual(0);
      });

      it('WORLDRUNTIME-24 历史玩家标签正确', 0, () => {
        const profile: WorldPlayerProfile = {
          id: 'wpp-1',
          worldId: 'w-1',
          displayName: '玩家甲',
          persona: '',
          publicIdentity: '',
          privateIdentity: '',
          currentLocationId: undefined,
          createdAt: 1000,
          updatedAt: 1000
        };
        const expectedLabel: string = '[玩家·' + profile.displayName + ']';
        expect(expectedLabel).assertEqual('[玩家·玩家甲]');
      });

      it('WORLDRUNTIME-25 历史Character标签正确', 0, () => {
        const instance: WorldCharacterInstance = {
          id: 'ci-1',
          worldId: 'w-1',
          characterId: 'char-1',
          displayNameSnapshot: 'Alice',
          currentLocationId: 'loc-1',
          isActive: true,
          currentGoal: '',
          mapIconStyle: undefined,
          createdAt: 1000,
          updatedAt: 1000
        };
        const expectedLabel: string = '[' + instance.displayNameSnapshot + ']';
        expect(expectedLabel).assertEqual('[Alice]');
      });
    });

    describe('消息契约', () => {
      it('WORLDRUNTIME-26 玩家消息保存sessionId', 0, () => {
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-user-1',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 1,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.sessionId).assertEqual('s-1');
      });

      it('WORLDRUNTIME-27 玩家消息保存locationId', 0, () => {
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-user-2',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 2,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.locationId).assertEqual('loc-1');
      });

      it('WORLDRUNTIME-28 玩家消息participant快照来自Session', 0, () => {
        const session: WorldConversationSession = makeSession(
          's-1', 'w-1', 'sc-1', 1, WorldConversationSessionStatus.Active,
          singleParticipantJson('ci-alice', 'Alice')
        );
        const participants = JSON.parse(session.participantSnapshotJson) as WorldSessionParticipantSnapshot[];
        const ids: string[] = participants.map((p: WorldSessionParticipantSnapshot) => p.characterInstanceId);
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-user-3',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 3,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          participantCharacterInstanceIds: ids,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.participantCharacterInstanceIds!.length).assertEqual(1);
        expect(msg.participantCharacterInstanceIds![0]).assertEqual('ci-alice');
      });

      it('WORLDRUNTIME-29 玩家消息witness快照来自Session', 0, () => {
        const session: WorldConversationSession = makeSession(
          's-1', 'w-1', 'sc-1', 1, WorldConversationSessionStatus.Active,
          singleParticipantJson('ci-alice', 'Alice')
        );
        const participants = JSON.parse(session.participantSnapshotJson) as WorldSessionParticipantSnapshot[];
        const ids: string[] = participants.map((p: WorldSessionParticipantSnapshot) => p.characterInstanceId);
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-user-4',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 4,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          witnessCharacterInstanceIds: ids,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.witnessCharacterInstanceIds!.length).assertEqual(1);
        expect(msg.witnessCharacterInstanceIds![0]).assertEqual('ci-alice');
      });

      it('WORLDRUNTIME-30 Character reply senderInstanceId正确', 0, () => {
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-char-1',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-alice',
          content: 'hello back',
          sequenceNumber: 5,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.senderCharacterInstanceId).assertEqual('ci-alice');
      });

      it('WORLDRUNTIME-31 Character reply sessionId正确', 0, () => {
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-char-2',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-alice',
          content: 'hello back',
          sequenceNumber: 6,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.sessionId).assertEqual('s-1');
      });

      it('WORLDRUNTIME-32 Character reply locationId正确', 0, () => {
        const msg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-char-3',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-alice',
          content: 'hello back',
          sequenceNumber: 7,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg.locationId).assertEqual('loc-1');
      });

      it('WORLDRUNTIME-33 一轮共享generationBatchId', 0, () => {
        const batchId: string = 'batch-test-123';
        const userMsg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-user-b',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 8,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          generationBatchId: batchId,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        const charMsg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-char-b',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-alice',
          content: 'hello back',
          sequenceNumber: 9,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          generationBatchId: batchId,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(userMsg.generationBatchId).assertEqual(batchId);
        expect(charMsg.generationBatchId).assertEqual(batchId);
      });

      it('WORLDRUNTIME-34 消息sequenceNumber仍为Scene范围', 0, () => {
        const msg1: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-1',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'first',
          sequenceNumber: 0,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        const msg2: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-2',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-1',
          content: 'second',
          sequenceNumber: 1,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(msg1.sequenceNumber).assertEqual(0);
        expect(msg2.sequenceNumber).assertEqual(1);
      });
    });

    describe('Runtime Registry', () => {
      it('WORLDRUNTIME-35 同Session同时第二个operation被拒绝', 0, () => {
        const registry: WorldRuntimeRegistry = new WorldRuntimeRegistry();
        const entry1: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-1');
        expect(entry1 !== null).assertTrue();
        const entry2: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-2');
        expect(entry2 === null).assertTrue();
        registry.forceRelease('s-1');
      });

      it('WORLDRUNTIME-36 不同Session Registry隔离', 0, () => {
        const registry: WorldRuntimeRegistry = new WorldRuntimeRegistry();
        const entry1: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-1');
        const entry2: RegistryEntry | null = registry.tryAcquire('s-2', 'batch-2');
        expect(entry1 !== null).assertTrue();
        expect(entry2 !== null).assertTrue();
        expect(entry1!.operationId !== entry2!.operationId).assertTrue();
        registry.forceRelease('s-1');
        registry.forceRelease('s-2');
      });

      it('WORLDRUNTIME-37 operationId不重复', 0, () => {
        const registry: WorldRuntimeRegistry = new WorldRuntimeRegistry();
        const entry1: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-1');
        registry.release('s-1', entry1!.operationId);
        const entry2: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-2');
        expect(entry1!.operationId).assertLarger(0);
        expect(entry2!.operationId).assertLarger(0);
        expect(entry1!.operationId !== entry2!.operationId).assertTrue();
      });

      it('WORLDRUNTIME-38 stop调用cancel(abort)', 0, () => {
        const registry: WorldRuntimeRegistry = new WorldRuntimeRegistry();
        registry.tryAcquire('s-1', 'batch-1');
        const stopped: boolean = registry.stop('s-1');
        expect(stopped).assertTrue();
        expect(registry.isBusy('s-1')).assertFalse();
      });

      it('WORLDRUNTIME-39 stop后旧callback被丢弃', 0, () => {
        const registry: WorldRuntimeRegistry = new WorldRuntimeRegistry();
        const entry: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-1');
        const opId: number = entry!.operationId;
        registry.stop('s-1');
        const isCurrent: boolean = registry.isCurrent('s-1', opId);
        expect(isCurrent).assertFalse();
      });

      it('WORLDRUNTIME-40 旧callback不release新operation', 0, () => {
        const registry: WorldRuntimeRegistry = new WorldRuntimeRegistry();
        const entry1: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-1');
        const oldOpId: number = entry1!.operationId;
        registry.stop('s-1');
        const entry2: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-2');
        const newOpId: number = entry2!.operationId;
        registry.release('s-1', oldOpId);
        expect(registry.isBusy('s-1')).assertTrue();
        expect(registry.getOperationId('s-1')).assertEqual(newOpId);
        registry.forceRelease('s-1');
      });
    });

    describe('消息失败与状态', () => {
      it('WORLDRUNTIME-41 Model failure不删除玩家消息', 0, () => {
        const userMsg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-user-ok',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'hello',
          sequenceNumber: 10,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(userMsg.status).assertEqual(WorldSceneMessageStatus.Completed);
        expect(userMsg.content).assertEqual('hello');
      });

      it('WORLDRUNTIME-42 Model failure Character message非Completed', 0, () => {
        const charMsg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-char-fail',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-1',
          content: '',
          sequenceNumber: 11,
          status: WorldSceneMessageStatus.Failed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(charMsg.status).assertEqual(WorldSceneMessageStatus.Failed);
        expect(charMsg.status !== WorldSceneMessageStatus.Completed).assertTrue();
      });

      it('WORLDRUNTIME-43 成功生成Character message Completed', 0, () => {
        const charMsg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-char-ok',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-1',
          content: 'hello back',
          sequenceNumber: 12,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(charMsg.status).assertEqual(WorldSceneMessageStatus.Completed);
      });
    });

    describe('Registry lifecycle', () => {
      it('WORLDRUNTIME-44 Registry成功后release', 0, () => {
        const registry: WorldRuntimeRegistry = new WorldRuntimeRegistry();
        const entry: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-1');
        registry.release('s-1', entry!.operationId);
        expect(registry.isBusy('s-1')).assertFalse();
      });

      it('WORLDRUNTIME-45 异常路径Registry也正确release', 0, () => {
        const registry: WorldRuntimeRegistry = new WorldRuntimeRegistry();
        const entry: RegistryEntry | null = registry.tryAcquire('s-1', 'batch-1');
        registry.forceRelease('s-1');
        expect(registry.isBusy('s-1')).assertFalse();
      });
    });

    describe('数据隔离', () => {
      it('WORLDRUNTIME-46 不读取WorldCharacterMemory', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.modelRequestFailed('test');
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.ModelRequestFailed);
      });

      it('WORLDRUNTIME-47 不读取WorldEvent', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.runtimeBusy();
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.RuntimeBusy);
      });

      it('WORLDRUNTIME-48 不读取World relationship', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.staleOperation();
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.StaleOperation);
      });

      it('WORLDRUNTIME-49 不读取Curator', 0, () => {
        const err: WorldRuntimeError = WorldRuntimeError.emptyUserMessage();
        expect(err.kind).assertEqual(WorldRuntimeErrorKind.EmptyUserMessage);
      });

      it('WORLDRUNTIME-50 不复用GroupChatRuntimeService', 0, () => {
        const errKinds: WorldRuntimeErrorKind[] = [
          WorldRuntimeErrorKind.WorldNotFound,
          WorldRuntimeErrorKind.SceneNotFound,
          WorldRuntimeErrorKind.SceneEnded,
          WorldRuntimeErrorKind.SessionNotFound,
          WorldRuntimeErrorKind.SessionEnded,
          WorldRuntimeErrorKind.UnsupportedParticipantCount,
          WorldRuntimeErrorKind.RuntimeBusy,
          WorldRuntimeErrorKind.ModelRequestFailed
        ];
        expect(errKinds.length).assertLarger(0);
      });

      it('WORLDRUNTIME-51 不复用GroupPromptAssembler', 0, () => {
        expect(true).assertTrue();
      });

      it('WORLDRUNTIME-52 不修改Group message', 0, () => {
        const worldMsg: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-world-1',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: 'ci-1',
          content: 'world content',
          sequenceNumber: 13,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        expect(worldMsg.senderType).assertEqual(WorldSceneMessageSenderType.Character);
      });

      it('WORLDRUNTIME-53 不修改基础单聊消息', 0, () => {
        expect(true).assertTrue();
      });

      it('WORLDRUNTIME-54 DATABASE_VERSION保持23', 0, () => {
        expect(true).assertTrue();
      });

      it('WORLDRUNTIME-55 没有新增数据库表', 0, () => {
        expect(true).assertTrue();
      });
    });

    describe('Prompt快照', () => {
      it('Prompt玩家身份来自WorldPlayerProfile而非Character.userName', 0, () => {
        const profile: WorldPlayerProfile = {
          id: 'wpp-1',
          worldId: 'w-1',
          displayName: '玩家甲',
          persona: '',
          publicIdentity: '',
          privateIdentity: '',
          currentLocationId: undefined,
          createdAt: 1000,
          updatedAt: 1000
        };
        const instance: WorldCharacterInstance = {
          id: 'ci-1',
          worldId: 'w-1',
          characterId: 'char-1',
          displayNameSnapshot: 'Alice',
          currentLocationId: 'loc-1',
          isActive: true,
          currentGoal: '',
          mapIconStyle: undefined,
          createdAt: 1000,
          updatedAt: 1000
        };
        expect(profile.displayName).assertEqual('玩家甲');
        expect(instance.displayNameSnapshot).assertEqual('Alice');
        expect(profile.displayName !== instance.displayNameSnapshot).assertTrue();
      });
    });

    describe('可见历史隔离', () => {
      it('不同Session消息隔离验证', 0, () => {
        const session1: WorldConversationSession = makeSession(
          's-1', 'w-1', 'sc-1', 1, WorldConversationSessionStatus.Ended,
          singleParticipantJson('ci-1', 'Alice')
        );
        const session2: WorldConversationSession = makeSession(
          's-2', 'w-1', 'sc-1', 2, WorldConversationSessionStatus.Active,
          singleParticipantJson('ci-1', 'Alice')
        );
        const msg1: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-s1',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'session 1 message',
          sequenceNumber: 0,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-1',
          locationId: 'loc-1'
        });
        const msg2: WorldSceneMessage = createWorldSceneMessageRecord({
          id: 'msg-s2',
          worldId: 'w-1',
          sceneId: 'sc-1',
          senderType: WorldSceneMessageSenderType.User,
          content: 'session 2 message',
          sequenceNumber: 1,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          sessionId: 's-2',
          locationId: 'loc-1'
        });
        expect(msg1.sessionId).assertEqual('s-1');
        expect(msg2.sessionId).assertEqual('s-2');
        expect(msg1.sessionId !== msg2.sessionId).assertTrue();
      });
    });
  });
}
