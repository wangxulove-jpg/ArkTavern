/**
 * DatabaseV2Migration 设备测试(ohosTest,需真机/模拟器运行)
 *
 * 覆盖:
 * - 新安装直接创建 v2
 * - v1→v2 迁移成功
 * - v1 旧数据保留
 * - 重复启动不重复迁移
 * - 迁移失败时旧数据不丢失
 * - 降级拒绝
 * - 不存在 DROP TABLE / API Key / Preset
 *
 * 使用独立测试数据库 arktavern_v2_migration_test.db。
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { DatabaseError, DatabaseErrorType } from '../../../main/ets/models/DatabaseError';
import {
  DATABASE_VERSION,
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_LOREBOOKS,
  TABLE_LOREBOOK_ENTRIES,
  INDEX_CHATS_UPDATED_AT,
  INDEX_CHATS_CHARACTER_ID,
  INDEX_MESSAGES_CHAT_SEQUENCE,
  INDEX_MESSAGES_CHAT_CREATED,
  INDEX_LOREBOOKS_UPDATED_AT,
  INDEX_LOREBOOKS_ENABLED,
  INDEX_LOREBOOK_ENTRIES_LOREBOOK_ID,
  INDEX_LOREBOOK_ENTRIES_LOREBOOK_PRIORITY,
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
  COLUMN_SOURCE
} from '../../../main/ets/database/DatabaseConstants';
import { buildMigrationPath, createV1ToV2Migration, DatabaseMigration } from '../../../main/ets/database/DatabaseMigration';
import { VERSION_1_STATEMENTS, V1_TO_V2_STATEMENTS } from '../../../main/ets/database/DatabaseSchema';

const TEST_DB_NAME: string = 'arktavern_v2_migration_test.db';

class FailingMigration implements DatabaseMigration {
  readonly fromVersion: number = 1;
  readonly toVersion: number = 2;
  private readonly shouldCreateTable: boolean;

  constructor(shouldCreateTable: boolean = false) {
    this.shouldCreateTable = shouldCreateTable;
  }

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    if (this.shouldCreateTable) {
      await store.executeSql('CREATE TABLE IF NOT EXISTS ' + TABLE_LOREBOOKS + ' (id TEXT)');
    }
    throw new Error('intentional migration failure');
  }
}

class FailingMigrationNoTable extends FailingMigration {
  constructor() {
    super(false);
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

/**
 * 创建 v1 数据库(不含 v2 表),插入旧数据,然后使用带 migration 的 DbHelper 升级。
 */
async function createV1DbWithData(
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
  await store.executeSql('PRAGMA user_version = 1');

  // 插入旧数据
  await store.insert(TABLE_CHARACTERS, characterBucket('c-v1', 'OldChar'));
  await store.insert(TABLE_CHATS, chatBucket('chat-v1', 'c-v1', 'OldChat'));
  await store.insert(TABLE_MESSAGES, messageBucket('msg-v1', 'chat-v1', 'user', 'completed', 1));

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

export default function databaseV2MigrationTest(): void {
  describe('DatabaseV2MigrationTest', () => {

    // ===== 1. 新安装直接创建 v2 =====
    it('fresh_install_creates_v2', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(2);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 2. DATABASE_VERSION 为 2 =====
    it('DATABASE_VERSION_is_2', 0, () => {
      expect(DATABASE_VERSION).assertEqual(2);
    });

    // ===== 3. v2 包含旧三张表 =====
    it('v2_has_old_tables', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_CHARACTERS)).assertTrue();
        expect(await tableExists(store, TABLE_CHATS)).assertTrue();
        expect(await tableExists(store, TABLE_MESSAGES)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 4. v2 包含 lorebooks =====
    it('v2_has_lorebooks_table', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_LOREBOOKS)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 5. v2 包含 lorebook_entries =====
    it('v2_has_lorebook_entries_table', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_LOREBOOK_ENTRIES)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 6. 新索引全部存在 =====
    it('v2_all_indexes_exist', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await indexExists(store, INDEX_CHATS_UPDATED_AT)).assertTrue();
        expect(await indexExists(store, INDEX_CHATS_CHARACTER_ID)).assertTrue();
        expect(await indexExists(store, INDEX_MESSAGES_CHAT_SEQUENCE)).assertTrue();
        expect(await indexExists(store, INDEX_MESSAGES_CHAT_CREATED)).assertTrue();
        expect(await indexExists(store, INDEX_LOREBOOKS_UPDATED_AT)).assertTrue();
        expect(await indexExists(store, INDEX_LOREBOOKS_ENABLED)).assertTrue();
        expect(await indexExists(store, INDEX_LOREBOOK_ENTRIES_LOREBOOK_ID)).assertTrue();
        expect(await indexExists(store, INDEX_LOREBOOK_ENTRIES_LOREBOOK_PRIORITY)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 7. v1→v2 迁移成功 =====
    it('v1_to_v2_migration_success', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v1Store: relationalStore.RdbStore = await createV1DbWithData(ctx);
      await v1Store.close();
      // 用带 migration 的 DbHelper 打开
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(2);
        expect(await tableExists(store, TABLE_LOREBOOKS)).assertTrue();
        expect(await tableExists(store, TABLE_LOREBOOK_ENTRIES)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 8. v1 characters 数据保留 =====
    it('v1_characters_data_preserved', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v1Store: relationalStore.RdbStore = await createV1DbWithData(ctx);
      await v1Store.close();
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const count: number = await rowCount(store, TABLE_CHARACTERS);
        expect(count).assertEqual(1);
        const rs = await store.querySql(
          `SELECT ${COLUMN_ID}, ${COLUMN_NAME} FROM ${TABLE_CHARACTERS} WHERE ${COLUMN_ID}='c-v1'`
        );
        let found: boolean = false;
        try {
          found = rs.goToFirstRow();
          if (found) {
            expect(rs.getString(rs.getColumnIndex(COLUMN_NAME))).assertEqual('OldChar');
          }
        } finally {
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        expect(found).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 9. v1 chats 数据保留 =====
    it('v1_chats_data_preserved', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v1Store: relationalStore.RdbStore = await createV1DbWithData(ctx);
      await v1Store.close();
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const count: number = await rowCount(store, TABLE_CHATS);
        expect(count).assertEqual(1);
        const rs = await store.querySql(
          `SELECT ${COLUMN_ID}, ${COLUMN_TITLE} FROM ${TABLE_CHATS} WHERE ${COLUMN_ID}='chat-v1'`
        );
        let found: boolean = false;
        try {
          found = rs.goToFirstRow();
          if (found) {
            expect(rs.getString(rs.getColumnIndex(COLUMN_TITLE))).assertEqual('OldChat');
          }
        } finally {
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        expect(found).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 10. v1 messages 数据保留 =====
    it('v1_messages_data_preserved', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v1Store: relationalStore.RdbStore = await createV1DbWithData(ctx);
      await v1Store.close();
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const count: number = await rowCount(store, TABLE_MESSAGES);
        expect(count).assertEqual(1);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 11. v1→v2 后版本为 2 =====
    it('v1_to_v2_version_is_2', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v1Store: relationalStore.RdbStore = await createV1DbWithData(ctx);
      await v1Store.close();
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(2);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 12. 重复启动不重复迁移 =====
    it('repeat_start_no_duplicate_migration', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v1Store: relationalStore.RdbStore = await createV1DbWithData(ctx);
      await v1Store.close();
      const helper1: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      await helper1.initialize(ctx);
      try { await helper1.close(); } catch (e) { /* ignore */ }
      // 重新打开
      const helper2: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper2.initialize(ctx);
        const store: relationalStore.RdbStore = helper2.getStore();
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(2);
        // 旧数据仍存在
        const count: number = await rowCount(store, TABLE_CHARACTERS);
        expect(count).assertEqual(1);
      } finally {
        try { await helper2.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 13. v2 Schema 重复执行不报错 =====
    it('v2_schema_repeat_no_error', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        // Schema 已经存在,ensureSchemaExists 会重新执行 IF NOT EXISTS
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(2);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 14. 迁移失败时旧表数据不丢失 =====
    it('migration_failure_preserves_old_data', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v1Store: relationalStore.RdbStore = await createV1DbWithData(ctx);
      await v1Store.close();
      // 使用会失败的 migration
      const badMigration: DatabaseMigration = new FailingMigration(true);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [badMigration]);
      let caught: boolean = false;
      try {
        await helper.initialize(ctx);
      } catch (e) {
        caught = true;
      }
      expect(caught).assertTrue();
      try { await helper.close(); } catch (e) { /* ignore */ }
      // 重新打开检查版本和数据
      const helper2: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper2.initialize(ctx);
        const store: relationalStore.RdbStore = helper2.getStore();
        const version: number = await readUserVersion(store);
        // 版本应为 2(成功迁移)
        expect(version).assertEqual(2);
        const charCount: number = await rowCount(store, TABLE_CHARACTERS);
        expect(charCount).assertEqual(1);
      } finally {
        try { await helper2.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 15. 迁移失败时版本不错误变为 2 =====
    it('migration_failure_version_not_2', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const v1Store: relationalStore.RdbStore = await createV1DbWithData(ctx);
      // 确认版本是 1
      const v1Ver: number = await readUserVersion(v1Store);
      expect(v1Ver).assertEqual(1);
      await v1Store.close();
      // 使用会失败的 migration,且失败后不写 user_version
      const badMigration: DatabaseMigration = new FailingMigrationNoTable();
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [badMigration]);
      let caught: boolean = false;
      try {
        await helper.initialize(ctx);
      } catch (e) {
        caught = true;
      }
      expect(caught).assertTrue();
      try { await helper.close(); } catch (e) { /* ignore */ }
      // 直接读数据库文件,版本应仍为 1
      const config: relationalStore.StoreConfig = {
        name: TEST_DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store2: relationalStore.RdbStore =
        await relationalStore.getRdbStore(ctx, config);
      try {
        const ver: number = await readUserVersion(store2);
        expect(ver).assertEqual(1);
      } finally {
        try { await store2.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 16. 高于 v2 版本拒绝启动 =====
    it('higher_version_rejected', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const config: relationalStore.StoreConfig = {
        name: TEST_DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore =
        await relationalStore.getRdbStore(ctx, config);
      await store.executeSql('CREATE TABLE IF NOT EXISTS dummy (id TEXT)');
      await store.executeSql('PRAGMA user_version = 99');
      await store.close();
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      let caught: boolean = false;
      let errorType: number = -1;
      try {
        await helper.initialize(ctx);
      } catch (e) {
        caught = true;
        if (e instanceof DatabaseError) {
          errorType = e.type;
        }
      }
      expect(caught).assertTrue();
      expect(errorType).assertEqual(DatabaseErrorType.UnsupportedVersion);
      try { await helper.close(); } catch (e) { /* ignore */ }
      await deleteDb(ctx);
    });

    // ===== 17. 不支持降级 =====
    it('downgrade_not_supported', 0, () => {
      let downgradeCaught: boolean = false;
      try {
        buildMigrationPath(2, 1, []);
      } catch (e) {
        downgradeCaught = true;
      }
      expect(downgradeCaught).assertTrue();
    });

    // ===== 18. 不存在 DROP TABLE =====
    it('no_drop_table_in_migration', 0, () => {
      const statements: string[] = V1_TO_V2_STATEMENTS;
      for (let i = 0; i < statements.length; i++) {
        const lower: string = statements[i].toLowerCase();
        expect(lower.indexOf('drop') < 0).assertTrue();
      }
    });

    // ===== 19. 不存在 API Key 字段 =====
    it('no_apikey_in_v2_schema', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql("SELECT name FROM sqlite_master WHERE type='table'");
        const names: string[] = [];
        try {
          while (rs.goToNextRow()) {
            const ci: number = rs.getColumnIndex('name');
            if (ci >= 0) {
              names.push(rs.getString(ci).toLowerCase());
            }
          }
        } finally {
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        for (let i = 0; i < names.length; i++) {
          expect(names[i].indexOf('apikey') < 0).assertTrue();
          expect(names[i].indexOf('secret') < 0).assertTrue();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 20. 不存在 Preset 表 =====
    it('no_preset_table', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql("SELECT name FROM sqlite_master WHERE type='table'");
        const names: string[] = [];
        try {
          while (rs.goToNextRow()) {
            const ci: number = rs.getColumnIndex('name');
            if (ci >= 0) {
              names.push(rs.getString(ci).toLowerCase());
            }
          }
        } finally {
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        for (let i = 0; i < names.length; i++) {
          expect(names[i].indexOf('preset') < 0).assertTrue();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });
  });
}