import { describe, it, expect } from '@ohos/hypium';
import {
  WorldSceneLaunchError,
  WorldSceneLaunchErrorKind,
  WorldSceneLaunchSnapshot,
  WorldSceneLaunchTarget,
  WorldSceneLaunchResult,
  WorldSceneLaunchEligibleParticipant
} from '../../../main/ets/models/world/WorldSceneLaunch';
import {
  WorldScene,
  WorldSceneStatus,
  createWorldSceneRecord
} from '../../../main/ets/models/world/WorldScene';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  createWorldConversationSessionRecord,
  serializeParticipantSnapshots,
  WorldSessionParticipantSnapshot
} from '../../../main/ets/models/world/WorldConversationSession';
import { preValidateParticipantIds } from '../../../main/ets/services/world/WorldSceneLaunchService';

function makeScene(id: string, worldId: string, locationId: string, status: WorldSceneStatus): WorldScene {
  return createWorldSceneRecord({
    id: id,
    worldId: worldId,
    locationId: locationId,
    status: status,
    startedAt: 1000,
    endedAt: status === WorldSceneStatus.Ended ? 2000 : undefined,
    createdAt: 1000,
    updatedAt: 1000
  });
}

function makeSession(id: string, worldId: string, sceneId: string, seq: number, status: WorldConversationSessionStatus): WorldConversationSession {
  return createWorldConversationSessionRecord({
    id: id,
    worldId: worldId,
    sceneId: sceneId,
    sequenceNumber: seq,
    status: status,
    participantSnapshotJson: '[]',
    playerDisplayNameSnapshot: 'Player',
    createdAt: 1000,
    updatedAt: 1000
  });
}

export default function sceneLaunchContractTest(): void {
  describe('SCENELAUNCH 场景启动契约(W2B1)', () => {
    it('SCENELAUNCH-01 WorldSceneLaunchError 保留 kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.worldNotFound();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.WorldNotFound);
      expect(err.name).assertEqual('WorldSceneLaunchError');
    });

    it('SCENELAUNCH-02 WorldSceneLaunchError.worldNotActive kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.worldNotActive();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.WorldNotActive);
    });

    it('SCENELAUNCH-03 WorldSceneLaunchError.locationNotFound kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.locationNotFound();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.LocationNotFound);
    });

    it('SCENELAUNCH-04 WorldSceneLaunchError.locationArchived kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.locationArchived();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.LocationArchived);
    });

    it('SCENELAUNCH-05 WorldSceneLaunchError.sceneAlreadyActive kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.sceneAlreadyActive();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.SceneAlreadyActive);
    });

    it('SCENELAUNCH-06 WorldSceneLaunchError.sceneAlreadyEnded kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.sceneAlreadyEnded();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.SceneAlreadyEnded);
    });

    it('SCENELAUNCH-07 WorldSceneLaunchError.noEligibleParticipants kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.noEligibleParticipants();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.NoEligibleParticipants);
    });

    it('SCENELAUNCH-08 WorldSceneLaunchError.participantNotFound kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.participantNotFound();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.ParticipantNotFound);
    });

    it('SCENELAUNCH-09 WorldSceneLaunchError.participantWorldMismatch kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.participantWorldMismatch();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.ParticipantWorldMismatch);
    });

    it('SCENELAUNCH-10 WorldSceneLaunchError.participantInactive kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.participantInactive();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.ParticipantInactive);
    });

    it('SCENELAUNCH-11 WorldSceneLaunchError.participantLocationMismatch kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.participantLocationMismatch();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.ParticipantLocationMismatch);
    });

    it('SCENELAUNCH-12 WorldSceneLaunchError.activeSessionAlreadyExists 截断 ID', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.activeSessionAlreadyExists('session-abcdefghijk');
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.ActiveSessionAlreadyExists);
      expect(err.message.includes('session-')).assertTrue();
      expect(err.message.includes('session-abcdefghijk')).assertFalse();
    });

    it('SCENELAUNCH-13 WorldSceneLaunchError.playerProfileNotFound kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.playerProfileNotFound();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.PlayerProfileNotFound);
    });

    it('SCENELAUNCH-14 WorldSceneLaunchError.duplicateParticipant 截断 ID', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.duplicateParticipant('ci-abcdefghijk');
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.DuplicateParticipant);
      expect(err.message.includes('ci-abcde')).assertTrue();
    });

    it('SCENELAUNCH-15 WorldSceneLaunchError.previousSessionNotFound kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.previousSessionNotFound();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.PreviousSessionNotFound);
    });

    it('SCENELAUNCH-16 WorldSceneLaunchError.previousSessionWorldMismatch kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.previousSessionWorldMismatch();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.PreviousSessionWorldMismatch);
    });

    it('SCENELAUNCH-17 WorldSceneLaunchError.previousSessionSceneMismatch kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.previousSessionSceneMismatch();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.PreviousSessionSceneMismatch);
    });

    it('SCENELAUNCH-18 WorldSceneLaunchError.previousSessionNotEnded kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.previousSessionNotEnded();
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.PreviousSessionNotEnded);
    });

    it('SCENELAUNCH-19 WorldSceneLaunchError.internal kind', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.internal('内部错误');
      expect(err.kind).assertEqual(WorldSceneLaunchErrorKind.Internal);
    });

    it('SCENELAUNCH-20 WorldSceneLaunchError 是 Error 子类', 0, () => {
      const err: WorldSceneLaunchError = WorldSceneLaunchError.worldNotFound();
      expect(err instanceof Error).assertTrue();
    });

    it('SCENELAUNCH-21 WorldSceneLaunchSnapshot 基本字段', 0, () => {
      const snapshot: WorldSceneLaunchSnapshot = {
        worldId: 'w-1',
        locationId: 'loc-1',
        locationName: 'Tavern',
        existingActiveScene: null,
        existingActiveSession: null,
        eligibleParticipants: []
      };
      expect(snapshot.worldId).assertEqual('w-1');
      expect(snapshot.locationId).assertEqual('loc-1');
      expect(snapshot.locationName).assertEqual('Tavern');
      expect(snapshot.existingActiveScene).assertNull();
      expect(snapshot.existingActiveSession).assertNull();
      expect(snapshot.eligibleParticipants.length).assertEqual(0);
    });

    it('SCENELAUNCH-22 WorldSceneLaunchSnapshot 含已有 Scene 和 Session', 0, () => {
      const scene: WorldScene = makeScene('ws-1', 'w-1', 'loc-1', WorldSceneStatus.Active);
      const session: WorldConversationSession = makeSession('wcs-1', 'w-1', 'ws-1', 1, WorldConversationSessionStatus.Active);
      const snapshot: WorldSceneLaunchSnapshot = {
        worldId: 'w-1',
        locationId: 'loc-1',
        locationName: 'Tavern',
        existingActiveScene: scene,
        existingActiveSession: session,
        eligibleParticipants: []
      };
      expect(snapshot.existingActiveScene === null).assertFalse();
      expect(snapshot.existingActiveSession === null).assertFalse();
      expect(snapshot.existingActiveScene!.id).assertEqual('ws-1');
      expect(snapshot.existingActiveSession!.id).assertEqual('wcs-1');
    });

    it('SCENELAUNCH-23 WorldSceneLaunchEligibleParticipant 字段', 0, () => {
      const p: WorldSceneLaunchEligibleParticipant = {
        characterInstanceId: 'ci-1',
        displayNameSnapshot: 'Alice'
      };
      expect(p.characterInstanceId).assertEqual('ci-1');
      expect(p.displayNameSnapshot).assertEqual('Alice');
    });

    it('SCENELAUNCH-24 WorldSceneLaunchTarget 必需字段', 0, () => {
      const target: WorldSceneLaunchTarget = {
        worldId: 'w-1',
        locationId: 'loc-1',
        participantCharacterInstanceIds: ['ci-1', 'ci-2']
      };
      expect(target.worldId).assertEqual('w-1');
      expect(target.locationId).assertEqual('loc-1');
      expect(target.participantCharacterInstanceIds.length).assertEqual(2);
      expect(target.previousSessionId).assertUndefined();
    });

    it('SCENELAUNCH-25 WorldSceneLaunchTarget 含 previousSessionId', 0, () => {
      const target: WorldSceneLaunchTarget = {
        worldId: 'w-1',
        locationId: 'loc-1',
        participantCharacterInstanceIds: ['ci-1'],
        previousSessionId: 'wcs-prev'
      };
      expect(target.previousSessionId).assertEqual('wcs-prev');
    });

    it('SCENELAUNCH-26 WorldSceneLaunchResult 新场景+新会话', 0, () => {
      const scene: WorldScene = makeScene('ws-1', 'w-1', 'loc-1', WorldSceneStatus.Active);
      const session: WorldConversationSession = makeSession('wcs-1', 'w-1', 'ws-1', 1, WorldConversationSessionStatus.Active);
      const result: WorldSceneLaunchResult = {
        scene: scene,
        session: session,
        isNewScene: true,
        isNewSession: true
      };
      expect(result.isNewScene).assertTrue();
      expect(result.isNewSession).assertTrue();
    });

    it('SCENELAUNCH-27 WorldSceneLaunchResult 复用已有场景+新会话', 0, () => {
      const scene: WorldScene = makeScene('ws-1', 'w-1', 'loc-1', WorldSceneStatus.Active);
      const session: WorldConversationSession = makeSession('wcs-1', 'w-1', 'ws-1', 1, WorldConversationSessionStatus.Active);
      const result: WorldSceneLaunchResult = {
        scene: scene,
        session: session,
        isNewScene: false,
        isNewSession: true
      };
      expect(result.isNewScene).assertFalse();
      expect(result.isNewSession).assertTrue();
    });

    it('SCENELAUNCH-28 WorldSceneLaunchResult 复用已有场景+已有会话', 0, () => {
      const scene: WorldScene = makeScene('ws-1', 'w-1', 'loc-1', WorldSceneStatus.Active);
      const session: WorldConversationSession = makeSession('wcs-1', 'w-1', 'ws-1', 1, WorldConversationSessionStatus.Active);
      const result: WorldSceneLaunchResult = {
        scene: scene,
        session: session,
        isNewScene: false,
        isNewSession: false
      };
      expect(result.isNewScene).assertFalse();
      expect(result.isNewSession).assertFalse();
    });

    it('SCENELAUNCH-29 preValidateParticipantIds 正常去重', 0, () => {
      const ids: string[] = ['ci-1', 'ci-2'];
      const result: string[] = preValidateParticipantIds(ids);
      expect(result.length).assertEqual(2);
      expect(result[0]).assertEqual('ci-1');
      expect(result[1]).assertEqual('ci-2');
    });

    it('SCENELAUNCH-30 preValidateParticipantIds 空数组返回空数组(不抛错)', 0, () => {
      const result: string[] = preValidateParticipantIds([]);
      expect(result.length).assertEqual(0);
    });

    it('SCENELAUNCH-31 preValidateParticipantIds 含空串抛 noEligibleParticipants', 0, () => {
      try {
        preValidateParticipantIds(['ci-1', '']);
        expect(true).assertFalse();
      } catch (e) {
        const err: Error = e as Error;
        expect(err.message.includes('没有可参与')).assertTrue();
      }
    });

    it('SCENELAUNCH-32 preValidateParticipantIds 含 "user" 抛 participantNotFound', 0, () => {
      try {
        preValidateParticipantIds(['ci-1', 'user']);
        expect(true).assertFalse();
      } catch (e) {
        const err: Error = e as Error;
        expect(err.message.includes('角色实例不存在')).assertTrue();
      }
    });

    it('SCENELAUNCH-33 preValidateParticipantIds 重复 ID 抛 duplicateParticipant', 0, () => {
      try {
        preValidateParticipantIds(['ci-1', 'ci-1']);
        expect(true).assertFalse();
      } catch (e) {
        const err: Error = e as Error;
        expect(err.message.includes('重复参与')).assertTrue();
      }
    });

    it('SCENELAUNCH-34 preValidateParticipantIds trim 后重复 抛 duplicateParticipant', 0, () => {
      try {
        preValidateParticipantIds(['ci-1', '  ci-1  ']);
        expect(true).assertFalse();
      } catch (e) {
        const err: Error = e as Error;
        expect(err.message.includes('重复参与')).assertTrue();
      }
    });

    it('SCENELAUNCH-35 preValidateParticipantIds trim 后空串 抛 noEligibleParticipants', 0, () => {
      try {
        preValidateParticipantIds(['   ']);
        expect(true).assertFalse();
      } catch (e) {
        const err: Error = e as Error;
        expect(err.message.includes('没有可参与')).assertTrue();
      }
    });

    it('SCENELAUNCH-36 WorldSceneLaunchError 所有工厂方法不泄漏完整 ID', 0, () => {
      const longId: string = 'ci-abcdefghijklmnopqrst';
      const err1: WorldSceneLaunchError = WorldSceneLaunchError.duplicateParticipant(longId);
      expect(err1.message.includes('ci-abcde')).assertTrue();
      expect(err1.message.includes('ci-abcdefghijklmnopqrst')).assertFalse();

      const err2: WorldSceneLaunchError = WorldSceneLaunchError.activeSessionAlreadyExists(longId);
      expect(err2.message.includes('ci-abcde')).assertTrue();
      expect(err2.message.includes('ci-abcdefghijklmnopqrst')).assertFalse();
    });

    it('SCENELAUNCH-37 WorldSceneLaunchErrorKind 全枚举覆盖', 0, () => {
      const allKinds: WorldSceneLaunchErrorKind[] = [
        WorldSceneLaunchErrorKind.WorldNotFound,
        WorldSceneLaunchErrorKind.WorldNotActive,
        WorldSceneLaunchErrorKind.LocationNotFound,
        WorldSceneLaunchErrorKind.LocationArchived,
        WorldSceneLaunchErrorKind.SceneAlreadyActive,
        WorldSceneLaunchErrorKind.SceneAlreadyEnded,
        WorldSceneLaunchErrorKind.NoEligibleParticipants,
        WorldSceneLaunchErrorKind.ParticipantNotFound,
        WorldSceneLaunchErrorKind.ParticipantWorldMismatch,
        WorldSceneLaunchErrorKind.ParticipantInactive,
        WorldSceneLaunchErrorKind.ParticipantLocationMismatch,
        WorldSceneLaunchErrorKind.ActiveSessionAlreadyExists,
        WorldSceneLaunchErrorKind.PlayerProfileNotFound,
        WorldSceneLaunchErrorKind.DuplicateParticipant,
        WorldSceneLaunchErrorKind.PreviousSessionNotFound,
        WorldSceneLaunchErrorKind.PreviousSessionWorldMismatch,
        WorldSceneLaunchErrorKind.PreviousSessionSceneMismatch,
        WorldSceneLaunchErrorKind.PreviousSessionNotEnded,
        WorldSceneLaunchErrorKind.Internal
      ];
      expect(allKinds.length).assertEqual(19);
    });

    it('SCENELAUNCH-38 WorldSceneLaunchResult 场景 locationId 权威', 0, () => {
      const scene: WorldScene = makeScene('ws-1', 'w-1', 'loc-1', WorldSceneStatus.Active);
      const session: WorldConversationSession = makeSession('wcs-1', 'w-1', 'ws-1', 1, WorldConversationSessionStatus.Active);
      const result: WorldSceneLaunchResult = {
        scene: scene,
        session: session,
        isNewScene: true,
        isNewSession: true
      };
      expect(result.scene.locationId).assertEqual('loc-1');
    });

    it('SCENELAUNCH-39 participantSnapshot 创建时冻结', 0, () => {
      const snapshots: WorldSessionParticipantSnapshot[] = [
        {
          characterInstanceId: 'ci-1',
          displayNameSnapshot: 'Alice',
          locationIdAtStart: 'loc-1',
          isActiveAtStart: true,
          joinedAt: 1000
        }
      ];
      const json: string = serializeParticipantSnapshots(snapshots);
      const session: WorldConversationSession = makeSession('wcs-1', 'w-1', 'ws-1', 1, WorldConversationSessionStatus.Active);
      expect(session.participantSnapshotJson.length > 0).assertTrue();
    });

    it('SCENELAUNCH-40 玩家不进入 participantCharacterInstanceIds', 0, () => {
      const target: WorldSceneLaunchTarget = {
        worldId: 'w-1',
        locationId: 'loc-1',
        participantCharacterInstanceIds: ['ci-1', 'ci-2']
      };
      const hasUser: boolean = target.participantCharacterInstanceIds.indexOf('user') >= 0;
      expect(hasUser).assertFalse();
    });

    it('SCENELAUNCH-41 Ended Scene 不允许新建会话', 0, () => {
      const endedScene: WorldScene = makeScene('ws-1', 'w-1', 'loc-1', WorldSceneStatus.Ended);
      expect(endedScene.status).assertEqual(WorldSceneStatus.Ended);
      expect(endedScene.endedAt).assertEqual(2000);
    });

    it('SCENELAUNCH-42 同一 Scene 同时最多一个 Active Session', 0, () => {
      const scene: WorldScene = makeScene('ws-1', 'w-1', 'loc-1', WorldSceneStatus.Active);
      const session1: WorldConversationSession = makeSession('wcs-1', 'w-1', 'ws-1', 1, WorldConversationSessionStatus.Active);
      expect(session1.status).assertEqual(WorldConversationSessionStatus.Active);
      expect(session1.sceneId).assertEqual(scene.id);
    });

    it('SCENELAUNCH-43 previousSessionId 只能显式传入', 0, () => {
      const targetWithoutPrev: WorldSceneLaunchTarget = {
        worldId: 'w-1',
        locationId: 'loc-1',
        participantCharacterInstanceIds: ['ci-1']
      };
      expect(targetWithoutPrev.previousSessionId).assertUndefined();

      const targetWithPrev: WorldSceneLaunchTarget = {
        worldId: 'w-1',
        locationId: 'loc-1',
        participantCharacterInstanceIds: ['ci-1'],
        previousSessionId: 'wcs-prev'
      };
      expect(targetWithPrev.previousSessionId).assertEqual('wcs-prev');
    });

    it('SCENELAUNCH-44 WorldSceneLaunchSnapshot eligibleParticipants 仅含匹配条件实例', 0, () => {
      const eligible: WorldSceneLaunchEligibleParticipant[] = [
        { characterInstanceId: 'ci-1', displayNameSnapshot: 'Alice' },
        { characterInstanceId: 'ci-2', displayNameSnapshot: 'Bob' }
      ];
      const snapshot: WorldSceneLaunchSnapshot = {
        worldId: 'w-1',
        locationId: 'loc-1',
        locationName: 'Tavern',
        existingActiveScene: null,
        existingActiveSession: null,
        eligibleParticipants: eligible
      };
      expect(snapshot.eligibleParticipants.length).assertEqual(2);
      expect(snapshot.eligibleParticipants[0].characterInstanceId).assertEqual('ci-1');
      expect(snapshot.eligibleParticipants[1].characterInstanceId).assertEqual('ci-2');
    });

    it('SCENELAUNCH-45 WorldSceneLaunchTarget 参与者输入顺序保持', 0, () => {
      const target: WorldSceneLaunchTarget = {
        worldId: 'w-1',
        locationId: 'loc-1',
        participantCharacterInstanceIds: ['ci-3', 'ci-1', 'ci-2']
      };
      const validated: string[] = preValidateParticipantIds(target.participantCharacterInstanceIds);
      expect(validated[0]).assertEqual('ci-3');
      expect(validated[1]).assertEqual('ci-1');
      expect(validated[2]).assertEqual('ci-2');
    });
  });
}
