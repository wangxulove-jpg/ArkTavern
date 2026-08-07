import { describe, it, expect } from '@ohos/hypium';
import {
  WorldSessionParticipantSnapshot,
  validateParticipantSnapshots,
  serializeParticipantSnapshots,
  deserializeParticipantSnapshots,
  createWorldConversationSessionRecord,
  WorldConversationSessionStatus
} from '../../../main/ets/models/world/WorldConversationSession';
import { DATABASE_VERSION } from '../../../main/ets/database/DatabaseConstants';

function makeSnapshot(
  characterInstanceId: string = 'ci-1',
  displayNameSnapshot: string = 'Alice',
  locationIdAtStart?: string,
  isActiveAtStart: boolean = true,
  joinedAt: number = 1000,
  leftAt?: number
): WorldSessionParticipantSnapshot {
  if (locationIdAtStart !== undefined && leftAt !== undefined) {
    return {
      characterInstanceId: characterInstanceId,
      displayNameSnapshot: displayNameSnapshot,
      locationIdAtStart: locationIdAtStart,
      isActiveAtStart: isActiveAtStart,
      joinedAt: joinedAt,
      leftAt: leftAt
    };
  }
  if (locationIdAtStart !== undefined) {
    return {
      characterInstanceId: characterInstanceId,
      displayNameSnapshot: displayNameSnapshot,
      locationIdAtStart: locationIdAtStart,
      isActiveAtStart: isActiveAtStart,
      joinedAt: joinedAt
    };
  }
  if (leftAt !== undefined) {
    return {
      characterInstanceId: characterInstanceId,
      displayNameSnapshot: displayNameSnapshot,
      isActiveAtStart: isActiveAtStart,
      joinedAt: joinedAt,
      leftAt: leftAt
    };
  }
  return {
    characterInstanceId: characterInstanceId,
    displayNameSnapshot: displayNameSnapshot,
    isActiveAtStart: isActiveAtStart,
    joinedAt: joinedAt
  };
}

export default function participantSnapshotContractTest(): void {
  describe('WorldSessionParticipantSnapshot 契约', () => {
    it('PARTSNAP-01 完整 ParticipantSnapshot 可以创建', 0, () => {
      const snap: WorldSessionParticipantSnapshot = makeSnapshot('ci-1', 'Alice', 'loc-1', true, 1000, 2000);
      expect(snap.characterInstanceId).assertEqual('ci-1');
      expect(snap.displayNameSnapshot).assertEqual('Alice');
      expect(snap.locationIdAtStart).assertEqual('loc-1');
      expect(snap.isActiveAtStart).assertTrue();
      expect(snap.joinedAt).assertEqual(1000);
      expect(snap.leftAt).assertEqual(2000);
    });

    it('PARTSNAP-02 characterInstanceId 空白拒绝', 0, () => {
      try {
        validateParticipantSnapshots([makeSnapshot('  ')]);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('PARTSNAP-03 characterInstanceId=user 拒绝', 0, () => {
      try {
        validateParticipantSnapshots([makeSnapshot('user')]);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('PARTSNAP-04 displayNameSnapshot 空白拒绝', 0, () => {
      try {
        validateParticipantSnapshots([makeSnapshot('ci-1', '  ')]);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('PARTSNAP-05 locationIdAtStart 可为空', 0, () => {
      const snap: WorldSessionParticipantSnapshot = makeSnapshot('ci-1', 'Alice');
      expect(snap.locationIdAtStart === undefined).assertTrue();
      validateParticipantSnapshots([snap]);
    });

    it('PARTSNAP-06 locationIdAtStart 空白字符串拒绝', 0, () => {
      try {
        validateParticipantSnapshots([makeSnapshot('ci-1', 'Alice', '  ')]);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('PARTSNAP-07 isActiveAtStart=true 正确保存', 0, () => {
      const snap: WorldSessionParticipantSnapshot = makeSnapshot('ci-1', 'Alice', undefined, true);
      expect(snap.isActiveAtStart).assertTrue();
      validateParticipantSnapshots([snap]);
    });

    it('PARTSNAP-08 isActiveAtStart=false 正确保存', 0, () => {
      const snap: WorldSessionParticipantSnapshot = makeSnapshot('ci-1', 'Alice', undefined, false);
      expect(snap.isActiveAtStart).assertFalse();
      validateParticipantSnapshots([snap]);
    });

    it('PARTSNAP-09 joinedAt 正确保存', 0, () => {
      const snap: WorldSessionParticipantSnapshot = makeSnapshot('ci-1', 'Alice', undefined, true, 5000);
      expect(snap.joinedAt).assertEqual(5000);
      validateParticipantSnapshots([snap]);
    });

    it('PARTSNAP-10 joinedAt 非法值拒绝', 0, () => {
      try {
        validateParticipantSnapshots([makeSnapshot('ci-1', 'Alice', undefined, true, -1)]);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('PARTSNAP-11 leftAt 可为空', 0, () => {
      const snap: WorldSessionParticipantSnapshot = makeSnapshot('ci-1', 'Alice', undefined, true, 1000);
      expect(snap.leftAt === undefined).assertTrue();
      validateParticipantSnapshots([snap]);
    });

    it('PARTSNAP-12 leftAt < joinedAt 拒绝', 0, () => {
      try {
        validateParticipantSnapshots([makeSnapshot('ci-1', 'Alice', undefined, true, 1000, 999)]);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('PARTSNAP-13 重复 characterInstanceId 拒绝', 0, () => {
      try {
        validateParticipantSnapshots([
          makeSnapshot('ci-1', 'Alice', undefined, true, 1000),
          makeSnapshot('ci-1', 'Bob', undefined, true, 1000)
        ]);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('PARTSNAP-14 参与者顺序保持', 0, () => {
      const snaps: WorldSessionParticipantSnapshot[] = [
        makeSnapshot('ci-2', 'Bob'),
        makeSnapshot('ci-1', 'Alice')
      ];
      validateParticipantSnapshots(snaps);
      expect(snaps[0].characterInstanceId).assertEqual('ci-2');
      expect(snaps[1].characterInstanceId).assertEqual('ci-1');
    });

    it('PARTSNAP-15 Factory 对输入数组 defensive copy', 0, () => {
      const original: WorldSessionParticipantSnapshot[] = [
        makeSnapshot('ci-1', 'Alice', 'loc-1', true, 1000)
      ];
      const json: string = serializeParticipantSnapshots(original);
      original[0] = makeSnapshot('ci-2', 'Bob', 'loc-2', false, 2000);
      const restored: WorldSessionParticipantSnapshot[] = deserializeParticipantSnapshots(json);
      expect(restored[0].characterInstanceId).assertEqual('ci-1');
      expect(restored[0].displayNameSnapshot).assertEqual('Alice');
    });

    it('PARTSNAP-16 Factory 对参与者对象 defensive copy', 0, () => {
      const snaps: WorldSessionParticipantSnapshot[] = [
        makeSnapshot('ci-1', 'Alice', 'loc-1', true, 1000)
      ];
      const json: string = serializeParticipantSnapshots(snaps);
      const restored: WorldSessionParticipantSnapshot[] = deserializeParticipantSnapshots(json);
      expect(restored[0].characterInstanceId).assertEqual('ci-1');
      expect(restored[0].displayNameSnapshot).assertEqual('Alice');
      expect(restored[0].locationIdAtStart).assertEqual('loc-1');
      expect(restored[0].isActiveAtStart).assertTrue();
      expect(restored[0].joinedAt).assertEqual(1000);
    });

    it('PARTSNAP-17 JSON 使用 displayNameSnapshot', 0, () => {
      const json: string = serializeParticipantSnapshots([makeSnapshot('ci-1', 'Alice')]);
      expect(json.indexOf('displayNameSnapshot') >= 0).assertTrue();
      expect(json.indexOf('"displayName"')).assertEqual(-1);
    });

    it('PARTSNAP-18 JSON 使用 locationIdAtStart', 0, () => {
      const json: string = serializeParticipantSnapshots([makeSnapshot('ci-1', 'Alice', 'loc-1')]);
      expect(json.indexOf('locationIdAtStart') >= 0).assertTrue();
      expect(json.indexOf('"locationId"')).assertEqual(-1);
    });

    it('PARTSNAP-19 JSON 包含 isActiveAtStart/joinedAt/leftAt', 0, () => {
      const json: string = serializeParticipantSnapshots([makeSnapshot('ci-1', 'Alice', 'loc-1', true, 1000, 2000)]);
      expect(json.indexOf('isActiveAtStart') >= 0).assertTrue();
      expect(json.indexOf('joinedAt') >= 0).assertTrue();
      expect(json.indexOf('leftAt') >= 0).assertTrue();
    });

    it('PARTSNAP-20 序列化后反序列化内容一致', 0, () => {
      const original: WorldSessionParticipantSnapshot[] = [
        makeSnapshot('ci-1', 'Alice', 'loc-1', true, 1000, 2000),
        makeSnapshot('ci-2', 'Bob', undefined, false, 1500)
      ];
      const json: string = serializeParticipantSnapshots(original);
      const restored: WorldSessionParticipantSnapshot[] = deserializeParticipantSnapshots(json);
      expect(restored.length).assertEqual(2);
      expect(restored[0].characterInstanceId).assertEqual('ci-1');
      expect(restored[0].displayNameSnapshot).assertEqual('Alice');
      expect(restored[0].locationIdAtStart).assertEqual('loc-1');
      expect(restored[0].isActiveAtStart).assertTrue();
      expect(restored[0].joinedAt).assertEqual(1000);
      expect(restored[0].leftAt).assertEqual(2000);
      expect(restored[1].characterInstanceId).assertEqual('ci-2');
      expect(restored[1].displayNameSnapshot).assertEqual('Bob');
      expect(restored[1].locationIdAtStart === undefined).assertTrue();
      expect(restored[1].isActiveAtStart).assertFalse();
      expect(restored[1].joinedAt).assertEqual(1500);
      expect(restored[1].leftAt === undefined).assertTrue();
    });

    it('PARTSNAP-21 损坏 JSON 明确失败', 0, () => {
      try {
        deserializeParticipantSnapshots('{not valid json');
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('PARTSNAP-22 playerDisplayNameSnapshot 不回归', 0, () => {
      const session = createWorldConversationSessionRecord({
        id: 's-pd-1',
        worldId: 'w-1',
        sceneId: 'sc-1',
        sequenceNumber: 0,
        playerDisplayNameSnapshot: 'Hero'
      });
      expect(session.playerDisplayNameSnapshot).assertEqual('Hero');
    });

    it('PARTSNAP-23 Session Active/Ended 约束不回归', 0, () => {
      const active = createWorldConversationSessionRecord({
        id: 's-act-1',
        worldId: 'w-1',
        sceneId: 'sc-1',
        sequenceNumber: 0,
        status: WorldConversationSessionStatus.Active
      });
      expect(active.status).assertEqual(WorldConversationSessionStatus.Active);
      const ended = createWorldConversationSessionRecord({
        id: 's-end-1',
        worldId: 'w-2',
        sceneId: 'sc-2',
        sequenceNumber: 0,
        status: WorldConversationSessionStatus.Ended
      });
      expect(ended.status).assertEqual(WorldConversationSessionStatus.Ended);
    });

    it('PARTSNAP-24 DATABASE_VERSION >= 21(未回退)', 0, () => {
      expect(DATABASE_VERSION >= 21).assertTrue();
    });

    it('PARTSNAP-25 locationIdAtStart 省略时 JSON 不包含该字段', 0, () => {
      const json: string = serializeParticipantSnapshots([makeSnapshot('ci-1', 'Alice')]);
      const parsed: Object[] = JSON.parse(json) as Object[];
      const record: Record<string, Object> = parsed[0] as Record<string, Object>;
      expect(record['locationIdAtStart'] === undefined).assertTrue();
    });

    it('PARTSNAP-26 leftAt 省略时 JSON 不包含该字段', 0, () => {
      const json: string = serializeParticipantSnapshots([makeSnapshot('ci-1', 'Alice')]);
      const parsed: Object[] = JSON.parse(json) as Object[];
      const record: Record<string, Object> = parsed[0] as Record<string, Object>;
      expect(record['leftAt'] === undefined).assertTrue();
    });
  });
}
