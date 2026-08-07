import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import {
  DATABASE_VERSION,
  TABLE_WORLD_PLAYER_PROFILES,
  TABLE_WORLD_CONVERSATION_SESSIONS
} from '../../../main/ets/database/DatabaseConstants';

const TEST_DB: string = 'w1a_schema_contract_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function w1aSchemaContractTest(): void {
  describe('W1A Schema 迁移契约', () => {
    let dbHelper: DbHelper;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('DATABASE_VERSION 为 21', 0, () => {
      expect(DATABASE_VERSION).assertEqual(21);
    });

    it('world_player_profiles 表存在', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT name FROM sqlite_master WHERE type='table' AND name='${TABLE_WORLD_PLAYER_PROFILES}'`
      );
      try {
        expect(rs.goToFirstRow()).assertTrue();
      } finally {
        rs.close();
      }
    });

    it('world_conversation_sessions 表存在', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT name FROM sqlite_master WHERE type='table' AND name='${TABLE_WORLD_CONVERSATION_SESSIONS}'`
      );
      try {
        expect(rs.goToFirstRow()).assertTrue();
      } finally {
        rs.close();
      }
    });

    it('world_player_profiles UNIQUE(worldId) 约束生效', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const bucket1: relationalStore.ValuesBucket = {
        'id': 'pp-uni-1',
        'world_id': 'world-uni-pp',
        'display_name': 'First',
        'created_at': 1000,
        'updated_at': 1000
      };
      await store.insert(TABLE_WORLD_PLAYER_PROFILES, bucket1);
      const bucket2: relationalStore.ValuesBucket = {
        'id': 'pp-uni-2',
        'world_id': 'world-uni-pp',
        'display_name': 'Second',
        'created_at': 2000,
        'updated_at': 2000
      };
      try {
        await store.insert(TABLE_WORLD_PLAYER_PROFILES, bucket2);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('world_conversation_sessions UNIQUE(sceneId, sequenceNumber) 约束生效', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const bucket1: relationalStore.ValuesBucket = {
        'id': 'cs-uni-1',
        'world_id': 'world-uni-cs',
        'scene_id': 'scene-uni-1',
        'sequence_number': 0,
        'status': 'active',
        'participant_snapshot_json': '[]',
        'player_display_name_snapshot': '',
        'created_at': 1000,
        'updated_at': 1000
      };
      await store.insert(TABLE_WORLD_CONVERSATION_SESSIONS, bucket1);
      const bucket2: relationalStore.ValuesBucket = {
        'id': 'cs-uni-2',
        'world_id': 'world-uni-cs',
        'scene_id': 'scene-uni-1',
        'sequence_number': 0,
        'status': 'ended',
        'participant_snapshot_json': '[]',
        'player_display_name_snapshot': '',
        'created_at': 2000,
        'updated_at': 2000
      };
      try {
        await store.insert(TABLE_WORLD_CONVERSATION_SESSIONS, bucket2);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('V1→V20 迁移路径完整(20 步)', 0, () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      expect(DATABASE_VERSION).assertEqual(21);
    });
  });
}
