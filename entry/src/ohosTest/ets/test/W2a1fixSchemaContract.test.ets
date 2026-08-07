import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import {
  DATABASE_VERSION,
  TABLE_WORLD_PLAYER_PROFILES,
  TABLE_WORLD_CHARACTER_INSTANCES,
  COLUMN_PERSONA,
  COLUMN_PUBLIC_IDENTITY,
  COLUMN_PRIVATE_IDENTITY,
  COLUMN_CURRENT_LOCATION_ID,
  COLUMN_CURRENT_GOAL,
  COLUMN_MAP_ICON_STYLE
} from '../../../main/ets/database/DatabaseConstants';

const TEST_DB: string = 'w2a1fix_schema_contract_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function getColumnNames(store: relationalStore.RdbStore, tableName: string): Promise<string[]> {
  const rs: relationalStore.ResultSet = await store.querySql(
    `PRAGMA table_info('${tableName}')`
  );
  const columns: string[] = [];
  try {
    while (rs.goToNextRow()) {
      const nameCol: number = rs.getColumnIndex('name');
      if (nameCol >= 0) {
        columns.push(rs.getString(nameCol));
      }
    }
  } finally {
    rs.close();
  }
  return columns;
}

export default function w2a1fixSchemaContractTest(): void {
  describe('W2A1FIX Schema 契约', () => {
    let dbHelper: DbHelper;
    let store: relationalStore.RdbStore;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
      store = dbHelper.getStore();
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('W2A1FIX-01 V20 PlayerProfile 原始列只有 5 列(id/world_id/display_name/created_at/updated_at)', 0, async () => {
      const columns: string[] = await getColumnNames(store, TABLE_WORLD_PLAYER_PROFILES);
      const original5: string[] = ['id', 'world_id', 'display_name', 'created_at', 'updated_at'];
      for (let i = 0; i < original5.length; i++) {
        expect(columns.indexOf(original5[i]) >= 0).assertTrue();
      }
    });

    it('W2A1FIX-02 persona 在最终表中存在且只出现一次', 0, async () => {
      const columns: string[] = await getColumnNames(store, TABLE_WORLD_PLAYER_PROFILES);
      const count: number = columns.filter((c: string) => c === COLUMN_PERSONA).length;
      expect(count).assertEqual(1);
    });

    it('W2A1FIX-03 public_identity 在最终表中存在且只出现一次', 0, async () => {
      const columns: string[] = await getColumnNames(store, TABLE_WORLD_PLAYER_PROFILES);
      const count: number = columns.filter((c: string) => c === COLUMN_PUBLIC_IDENTITY).length;
      expect(count).assertEqual(1);
    });

    it('W2A1FIX-04 private_identity 在最终表中存在且只出现一次', 0, async () => {
      const columns: string[] = await getColumnNames(store, TABLE_WORLD_PLAYER_PROFILES);
      const count: number = columns.filter((c: string) => c === COLUMN_PRIVATE_IDENTITY).length;
      expect(count).assertEqual(1);
    });

    it('W2A1FIX-05 current_location_id 在 profile 表中存在且只出现一次', 0, async () => {
      const columns: string[] = await getColumnNames(store, TABLE_WORLD_PLAYER_PROFILES);
      const count: number = columns.filter((c: string) => c === COLUMN_CURRENT_LOCATION_ID).length;
      expect(count).assertEqual(1);
    });

    it('W2A1FIX-06 current_goal 在 instance 表中存在且只出现一次', 0, async () => {
      const columns: string[] = await getColumnNames(store, TABLE_WORLD_CHARACTER_INSTANCES);
      const count: number = columns.filter((c: string) => c === COLUMN_CURRENT_GOAL).length;
      expect(count).assertEqual(1);
    });

    it('W2A1FIX-07 map_icon_style 在 instance 表中存在且只出现一次', 0, async () => {
      const columns: string[] = await getColumnNames(store, TABLE_WORLD_CHARACTER_INSTANCES);
      const count: number = columns.filter((c: string) => c === COLUMN_MAP_ICON_STYLE).length;
      expect(count).assertEqual(1);
    });

    it('W2A1FIX-08 fresh V23 profile 结构完整(9 列)', 0, async () => {
      const columns: string[] = await getColumnNames(store, TABLE_WORLD_PLAYER_PROFILES);
      expect(columns.length).assertEqual(9);
    });

    it('W2A1FIX-09 fresh V23 instance 结构完整(10 列)', 0, async () => {
      const columns: string[] = await getColumnNames(store, TABLE_WORLD_CHARACTER_INSTANCES);
      expect(columns.length).assertEqual(10);
    });
  });
}
