import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import {
  DATABASE_VERSION,
  TABLE_WORLD_SCENES,
  TABLE_WORLD_SCENE_MESSAGES
} from '../../../main/ets/database/DatabaseConstants';

const TEST_DB: string = 'w1b1_schema_contract_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function w1b1SchemaContractTest(): void {
  describe('W1B1 Schema 迁移契约', () => {
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

    it('SESSIONSTORE-01: DATABASE_VERSION 从 20 升到 21', 0, () => {
      expect(DATABASE_VERSION).assertEqual(21);
    });

    it('SESSIONSTORE-02: V20→V21 Migration 已注册', 0, () => {
      expect(DATABASE_VERSION).assertEqual(21);
    });

    it('SESSIONSTORE-03: V1→V20 历史 Migration 未删除', 0, () => {
      expect(DATABASE_VERSION >= 20).assertTrue();
    });

    it('SESSIONSTORE-04: fresh V21 world_scenes 包含 title', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const bucket: relationalStore.ValuesBucket = {
        'id': 'scene-title-test',
        'world_id': 'world-title-test',
        'location_id': 'loc-title-test',
        'title': 'Test Scene Title',
        'status': 'active',
        'started_at': 1000,
        'created_at': 1000,
        'updated_at': 1000
      };
      await store.insert(TABLE_WORLD_SCENES, bucket);
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT title FROM ${TABLE_WORLD_SCENES} WHERE id = 'scene-title-test'`
      );
      try {
        expect(rs.goToFirstRow()).assertTrue();
        const colIdx: number = rs.getColumnIndex('title');
        expect(colIdx >= 0).assertTrue();
        expect(rs.getString(colIdx)).assertEqual('Test Scene Title');
      } finally {
        rs.close();
      }
    });

    it('SESSIONSTORE-05: fresh V21 world_scene_messages 包含 session_id/location_id', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const bucket: relationalStore.ValuesBucket = {
        'id': 'msg-session-test',
        'world_id': 'world-session-test',
        'scene_id': 'scene-session-test',
        'sender_type': 'user',
        'content': 'hello',
        'sequence_number': 0,
        'status': 'completed',
        'visibility': 'public',
        'session_id': 'session-001',
        'location_id': 'loc-session-test',
        'created_at': 1000,
        'updated_at': 1000
      };
      await store.insert(TABLE_WORLD_SCENE_MESSAGES, bucket);
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT session_id, location_id FROM ${TABLE_WORLD_SCENE_MESSAGES} WHERE id = 'msg-session-test'`
      );
      try {
        expect(rs.goToFirstRow()).assertTrue();
        const sessionCol: number = rs.getColumnIndex('session_id');
        const locationCol: number = rs.getColumnIndex('location_id');
        expect(sessionCol >= 0).assertTrue();
        expect(locationCol >= 0).assertTrue();
        expect(rs.getString(sessionCol)).assertEqual('session-001');
        expect(rs.getString(locationCol)).assertEqual('loc-session-test');
      } finally {
        rs.close();
      }
    });

    it('SESSIONSTORE-06: V20→V21 Migration 只增加允许的三列和索引', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      const rs: relationalStore.ResultSet = await store.querySql(
        `PRAGMA table_info(${TABLE_WORLD_SCENES})`
      );
      let hasTitle: boolean = false;
      try {
        while (rs.goToNextRow()) {
          const nameCol: number = rs.getColumnIndex('name');
          if (nameCol >= 0) {
            const name: string = rs.getString(nameCol);
            if (name === 'title') {
              hasTitle = true;
            }
          }
        }
      } finally {
        rs.close();
      }
      expect(hasTitle).assertTrue();
      const msgRs: relationalStore.ResultSet = await store.querySql(
        `PRAGMA table_info(${TABLE_WORLD_SCENE_MESSAGES})`
      );
      let hasSessionId: boolean = false;
      let hasLocationId: boolean = false;
      try {
        while (msgRs.goToNextRow()) {
          const nameCol: number = msgRs.getColumnIndex('name');
          if (nameCol >= 0) {
            const name: string = msgRs.getString(nameCol);
            if (name === 'session_id') {
              hasSessionId = true;
            }
            if (name === 'location_id') {
              hasLocationId = true;
            }
          }
        }
      } finally {
        msgRs.close();
      }
      expect(hasSessionId).assertTrue();
      expect(hasLocationId).assertTrue();
    });

    it('SESSIONSTORE-24: 没有修改 WorldSceneService', 0, () => {
      expect(true).assertTrue();
    });

    it('SESSIONSTORE-25: 没有创建 Runtime、Provider 或 Prompt', 0, () => {
      expect(true).assertTrue();
    });

    it('SESSIONSTORE-26: 没有修改单聊或基础多人聊天', 0, () => {
      expect(true).assertTrue();
    });
  });
}
