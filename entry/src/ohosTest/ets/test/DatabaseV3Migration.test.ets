/**
 * DatabaseV3Migration 设备测试(ohosTest,需真机/模拟器运行)
 *
 * 覆盖:
 * - 新安装直接创建 v3
 * - v2→v3 迁移成功
 * - v2 旧数据保留
 * - 重复启动不重复迁移
 * - 迁移失败时旧数据不丢失
 * - 降级拒绝
 * - 不存在 DROP TABLE / API Key / Base URL / Preset 默认记录
 * - prompt_presets 表存在
 * - Preset 索引存在
 *
 * 使用独立测试数据库 arktavern_v3_migration_test.db。
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { DatabaseError } from '../../../main/ets/models/DatabaseError';
import {
  DATABASE_VERSION,
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_LOREBOOKS,
  TABLE_LOREBOOK_ENTRIES,
  TABLE_PROMPT_PRESETS,
  INDEX_CHATS_UPDATED_AT,
  INDEX_CHATS_CHARACTER_ID,
  INDEX_MESSAGES_CHAT_SEQUENCE,
  INDEX_MESSAGES_CHAT_CREATED,
  INDEX_LOREBOOKS_UPDATED_AT,
  INDEX_LOREBOOKS_ENABLED,
  INDEX_LOREBOOK_ENTRIES_LOREBOOK_ID,
  INDEX_LOREBOOK_ENTRIES_LOREBOOK_PRIORITY,
  INDEX_PROMPT_PRESETS_UPDATED_AT,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_CHARACTER_ID,
  COLUMN_TITLE,
  COLUMN_LAST_MESSAGE_AT,
  COLUMN_IS_ARCHIVED,
  COLUMN_CHAT_ID,
  COLUMN_ROLE,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_IS_STREAMING,
  COLUMN_SOURCE,
  COLUMN_LOREBOOK_ID,
  COLUMN_LOREBOOK_NAME,
  COLUMN_LOREBOOK_DESCRIPTION,
  COLUMN_LOREBOOK_ENABLED,
  COLUMN_LOREBOOK_CREATED_AT,
  COLUMN_LOREBOOK_UPDATED_AT,
  COLUMN_ENTRY_ID,
  COLUMN_ENTRY_LOREBOOK_ID,
  COLUMN_ENTRY_CONTENT,
  COLUMN_ENTRY_ENABLED,
  COLUMN_ENTRY_POSITION,
  COLUMN_ENTRY_PRIORITY,
  COLUMN_ENTRY_CREATED_AT,
  COLUMN_ENTRY_UPDATED_AT,
  COLUMN_PRESET_ID,
  COLUMN_PRESET_NAME,
  COLUMN_PRESET_SYSTEM_PROMPT,
  COLUMN_PRESET_TEMPERATURE
} from '../../../main/ets/database/DatabaseConstants';
import {
  VERSION_1_STATEMENTS,
  V1_TO_V2_STATEMENTS,
  V2_TO_V3_STATEMENTS,
  CREATE_PROMPT_PRESETS_TABLE_SQL
} from '../../../main/ets/database/DatabaseSchema';
import {
  buildMigrationPath,
  createV1ToV2Migration,
  createV2ToV3Migration,
  DatabaseMigration
} from '../../../main/ets/database/DatabaseMigration';

const TEST_DB_NAME: string = 'arktavern_v3_migration_test.db';

class FailingV2ToV3Migration implements DatabaseMigration {
  readonly fromVersion: number = 2;
  readonly toVersion: number = 3;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    await store.executeSql(CREATE_PROMPT_PRESETS_TABLE_SQL);
    throw new Error('intentional migration failure');
  }
}

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function deleteDb(context: common.Context): Promise<void> {
  try {
    const config: relationalStore.StoreConfig = {
      name: TEST_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore =
      await relationalStore.getRdbStore(context, config);
    await relationalStore.deleteRdbStore(context, TEST_DB_NAME);
  } catch (e) {
    /* best-effort */
  }
}

async function tableExists(
  store: relationalStore.RdbStore,
  table: string
): Promise<boolean> {
  try {
    const rs = await store.querySql(
      `SELECT name FROM sqlite_master WHERE type='table' AND name='${table}'`
    );
    let found: boolean = false;
    if (rs !== null) {
      try { found = rs.goToFirstRow(); } catch (e) { found = false; }
      try { rs.close(); } catch (e) { /* ignore */ }
    }
    return found;
  } catch (e) {
    return false;
  }
}

async function indexExists(
  store: relationalStore.RdbStore,
  indexName: string
): Promise<boolean> {
  try {
    const rs = await store.querySql(
      `SELECT name FROM sqlite_master WHERE type='index' AND name='${indexName}'`
    );
    let found: boolean = false;
    if (rs !== null) {
      try { found = rs.goToFirstRow(); } catch (e) { found = false; }
      try { rs.close(); } catch (e) { /* ignore */ }
    }
    return found;
  } catch (e) {
    return false;
  }
}

async function readUserVersion(
  store: relationalStore.RdbStore
): Promise<number> {
  const rs = await store.querySql('PRAGMA user_version');
  let version: number = 0;
  try {
    if (rs.goToFirstRow()) {
      const ci: number = rs.getColumnIndex('user_version');
      if (ci >= 0) {
        version = rs.getLong(ci);
      }
    }
  } finally {
    try { rs.close(); } catch (e) { /* ignore */ }
  }
  return version;
}

function characterBucket(id: string, name: string): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = id;
  bucket[COLUMN_NAME] = name;
  bucket[COLUMN_CREATED_AT] = 1000;
  bucket[COLUMN_UPDATED_AT] = 1000;
  return bucket;
}

function chatBucket(
  id: string, characterId: string | null, title: string
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = id;
  bucket[COLUMN_CHARACTER_ID] = characterId;
  bucket[COLUMN_TITLE] = title;
  bucket[COLUMN_CREATED_AT] = 2000;
  bucket[COLUMN_UPDATED_AT] = 2000;
  bucket[COLUMN_LAST_MESSAGE_AT] = 0;
  bucket[COLUMN_IS_ARCHIVED] = 0;
  return bucket;
}

function messageBucket(
  id: string, chatId: string, role: string, status: string, sequence: number
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = id;
  bucket[COLUMN_CHAT_ID] = chatId;
  bucket[COLUMN_ROLE] = role;
  bucket[COLUMN_CONTENT] = 'test content';
  bucket[COLUMN_STATUS] = status;
  bucket[COLUMN_CREATED_AT] = 3000 + sequence;
  bucket[COLUMN_UPDATED_AT] = 3000 + sequence;
  bucket[COLUMN_SEQUENCE_NUMBER] = sequence;
  bucket[COLUMN_IS_STREAMING] = 0;
  bucket[COLUMN_SOURCE] = 'conversation';
  return bucket;
}

function lorebookBucket(id: string, name: string): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_LOREBOOK_ID] = id;
  bucket[COLUMN_LOREBOOK_NAME] = name;
  bucket[COLUMN_LOREBOOK_DESCRIPTION] = '';
  bucket[COLUMN_LOREBOOK_ENABLED] = 1;
  bucket[COLUMN_LOREBOOK_CREATED_AT] = 4000;
  bucket[COLUMN_LOREBOOK_UPDATED_AT] = 4000;
  return bucket;
}

function lorebookEntryBucket(
  id: string, lorebookId: string
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ENTRY_ID] = id;
  bucket[COLUMN_ENTRY_LOREBOOK_ID] = lorebookId;
  bucket[COLUMN_ENTRY_CONTENT] = 'test';
  bucket[COLUMN_ENTRY_ENABLED] = 1;
  bucket[COLUMN_ENTRY_POSITION] = 'BeforeCharacter';
  bucket[COLUMN_ENTRY_PRIORITY] = 0;
  bucket[COLUMN_ENTRY_CREATED_AT] = 5000;
  bucket[COLUMN_ENTRY_UPDATED_AT] = 5000;
  return bucket;
}

/**
 * 创建 v2 数据库(含旧数据),用于 v2→v3 迁移测试。
 */
async function createV2DbWithData(
  context: common.Context
): Promise<relationalStore.RdbStore> {
  const config: relationalStore.StoreConfig = {
    name: TEST_DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  const store: relationalStore.RdbStore =
    await relationalStore.getRdbStore(context, config);

  for (let i = 0; i < VERSION_1_STATEMENTS.length; i++) {
    await store.executeSql(VERSION_1_STATEMENTS[i]);
  }
  for (let i = 0; i < V1_TO_V2_STATEMENTS.length; i++) {
    await store.executeSql(V1_TO_V2_STATEMENTS[i]);
  }
  await store.executeSql('PRAGMA user_version = 2');

  // 插入 v2 旧数据
  await store.insert(TABLE_CHARACTERS, characterBucket('c-v2', 'OldChar'));
  await store.insert(TABLE_CHATS, chatBucket('chat-v2', 'c-v2', 'OldChat'));
  await store.insert(TABLE_MESSAGES, messageBucket('msg-v2', 'chat-v2', 'user', 'completed', 1));
  await store.insert(TABLE_LOREBOOKS, lorebookBucket('lb-v2', 'OldLorebook'));
  await store.insert(TABLE_LOREBOOK_ENTRIES, lorebookEntryBucket('le-v2', 'lb-v2'));

  return store;
}

async function rowCount(
  store: relationalStore.RdbStore,
  table: string
): Promise<number> {
  const rs = await store.querySql(`SELECT COUNT(*) AS cnt FROM ${table}`);
  try {
    if (rs.goToFirstRow()) {
      const ci: number = rs.getColumnIndex('cnt');
      if (ci >= 0) {
        return rs.getLong(ci);
      }
    }
    return 0;
  } finally {
    try { rs.close(); } catch (e) { /* ignore */ }
  }
}

export default function databaseV3MigrationTest(): void {
  describe('DatabaseV3MigrationTest', () => {

    // ===== 1. DATABASE_VERSION = 3 =====
    it('DATABASE_VERSION_is_3', 0, () => {
      expect(DATABASE_VERSION).assertEqual(3);
    });

    // ===== 2. 新安装直接创建 v3 =====
    it('fresh_install_creates_v3', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(3);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 3. prompt_presets 表存在 =====
    it('v3_has_prompt_presets_table', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_PROMPT_PRESETS)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 4. Preset 索引存在 =====
    it('v3_has_prompt_presets_index', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await indexExists(store, INDEX_PROMPT_PRESETS_UPDATED_AT)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 5. v3 包含 characters =====
    it('v3_has_characters', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_CHARACTERS)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 6. v3 包含 chats =====
    it('v3_has_chats', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_CHATS)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 7. v3 包含 messages =====
    it('v3_has_messages', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_MESSAGES)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 8. v3 包含 lorebooks =====
    it('v3_has_lorebooks', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_LOREBOOKS)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 9. v3 包含 lorebook_entries =====
    it('v3_has_lorebook_entries', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_LOREBOOK_ENTRIES)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 10. v2→v3 迁移成功 =====
    it('v2_to_v3_migration_success', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      // 创建 v2 数据库含旧数据
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(3);
        expect(await tableExists(store, TABLE_PROMPT_PRESETS)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 11. v2 characters 数据保留 =====
    it('v2_characters_data_preserved', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await rowCount(store, TABLE_CHARACTERS)).assertEqual(1);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 12. v2 chats 数据保留 =====
    it('v2_chats_data_preserved', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await rowCount(store, TABLE_CHATS)).assertEqual(1);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 13. v2 messages 数据保留 =====
    it('v2_messages_data_preserved', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await rowCount(store, TABLE_MESSAGES)).assertEqual(1);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 14. v2 lorebooks 数据保留 =====
    it('v2_lorebooks_data_preserved', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await rowCount(store, TABLE_LOREBOOKS)).assertEqual(1);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 15. v2 lorebook_entries 数据保留 =====
    it('v2_lorebook_entries_data_preserved', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await rowCount(store, TABLE_LOREBOOK_ENTRIES)).assertEqual(1);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 16. 升级后版本为 3 =====
    it('after_migration_version_is_3', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await readUserVersion(store)).assertEqual(3);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 17. 重启不重复迁移 =====
    it('restart_does_not_repeat_migration', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      let helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await readUserVersion(store)).assertEqual(3);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
      }

      // 重新初始化
      helper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await readUserVersion(store)).assertEqual(3);
        expect(await tableExists(store, TABLE_PROMPT_PRESETS)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 18. 迁移失败时版本保持 2 =====
    it('failed_migration_keeps_version_2', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), new FailingV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        // 不应该到达这里
        expect(false).assertTrue();
      } catch (e) {
        // 预期失败
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(2); // MigrationFailed
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
      }

      // 重新打开检查版本
      const checkHelper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await checkHelper.initialize(ctx);
        const store: relationalStore.RdbStore = checkHelper.getStore();
        // 由于 FailingMigration 抛错,版本应保持 2
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(2);
      } finally {
        try { await checkHelper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 19. 迁移失败时旧数据保留 =====
    it('failed_migration_preserves_old_data', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v2Store: relationalStore.RdbStore = await createV2DbWithData(ctx);
      try { await v2Store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), new FailingV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
      } catch (e) {
        /* expected */
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
      }

      const checkHelper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await checkHelper.initialize(ctx);
        const store: relationalStore.RdbStore = checkHelper.getStore();
        expect(await rowCount(store, TABLE_CHARACTERS)).assertEqual(1);
        expect(await rowCount(store, TABLE_CHATS)).assertEqual(1);
        expect(await rowCount(store, TABLE_MESSAGES)).assertEqual(1);
        expect(await rowCount(store, TABLE_LOREBOOKS)).assertEqual(1);
        expect(await rowCount(store, TABLE_LOREBOOK_ENTRIES)).assertEqual(1);
      } finally {
        try { await checkHelper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 20. 高于 v3 拒绝启动 =====
    it('rejects_version_higher_than_3', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const config: relationalStore.StoreConfig = {
        name: TEST_DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore =
        await relationalStore.getRdbStore(ctx, config);
      await store.executeSql('PRAGMA user_version = 99');
      try { await store.close(); } catch (e) { /* ignore */ }

      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(5); // UnsupportedVersion
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 21. 不支持降级 =====
    it('rejects_downgrade', 0, async () => {
      let threw: boolean = false;
      try {
        buildMigrationPath(3, 2, [createV1ToV2Migration(), createV2ToV3Migration()]);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // ===== 22. 不存在 DROP TABLE =====
    it('no_drop_table_in_v2_to_v3', 0, () => {
      for (let i = 0; i < V2_TO_V3_STATEMENTS.length; i++) {
        const sql: string = V2_TO_V3_STATEMENTS[i].toUpperCase();
        expect(sql.indexOf('DROP TABLE') >= 0).assertFalse();
      }
    });

    // ===== 23. prompt_presets 不含 API Key 字段 =====
    it('prompt_presets_no_api_key_fields', 0, () => {
      const upper: string = CREATE_PROMPT_PRESETS_TABLE_SQL.toUpperCase();
      expect(upper.indexOf('API_KEY') >= 0).assertFalse();
      expect(upper.indexOf('SECRET') >= 0).assertFalse();
      expect(upper.indexOf('BASE_URL') >= 0).assertFalse();
      expect(upper.indexOf('AUTHORIZATION') >= 0).assertFalse();
    });

    // ===== 24. prompt_presets 不含 Base URL =====
    // (covered by test 23)

    // ===== 25. 不存在 Preset 默认记录 =====
    it('no_default_preset_records', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await rowCount(store, TABLE_PROMPT_PRESETS)).assertEqual(0);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });
  });
}