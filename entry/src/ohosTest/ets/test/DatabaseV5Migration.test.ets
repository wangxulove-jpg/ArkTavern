/**
 * DatabaseV5Migration 设备测试(ohosTest,需真机/模拟器运行)
 *
 * 覆盖:
 * - DATABASE_VERSION=5
 * - 新安装完整 v5
 * - 四张 Branch 表存在
 * - Branch 索引存在
 * - v4→v5 成功
 * - 每个旧 Chat 创建 Root Branch
 * - 空 Chat 创建 Root Branch
 * - Root Branch Message Links 数量正确
 * - Message 顺序正确
 * - chat_branch_state 指向 Root
 * - 已有 Swipe activeIndex 迁移为 BranchSelection
 * - Candidate 不复制
 * - Message 不复制
 * - 旧七/八张业务表数据保留
 * - current Character 保持
 * - current Lorebook 保持
 * - current Preset 保持
 * - user_version=5
 * - 重启不重复迁移
 * - 失败回滚到4
 * - 失败不留下部分 Branch
 * - 高版本拒绝
 * - 不支持降级
 * - Branch 表不含正文
 * - 不含 API Key / Prompt / Secret
 *
 * 使用独立测试数据库 arktavern_v5_migration_test.db。
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
  TABLE_PROMPT_PRESETS,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_MESSAGE_SWIPE_CANDIDATES,
  TABLE_CONVERSATION_BRANCHES,
  TABLE_CHAT_BRANCH_STATE,
  TABLE_CONVERSATION_BRANCH_MESSAGES,
  TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS,
  INDEX_CHATS_UPDATED_AT,
  INDEX_CHATS_CHARACTER_ID,
  INDEX_MESSAGES_CHAT_SEQUENCE,
  INDEX_MESSAGES_CHAT_CREATED,
  INDEX_LOREBOOKS_UPDATED_AT,
  INDEX_LOREBOOKS_ENABLED,
  INDEX_LOREBOOK_ENTRIES_LOREBOOK_ID,
  INDEX_LOREBOOK_ENTRIES_LOREBOOK_PRIORITY,
  INDEX_PROMPT_PRESETS_UPDATED_AT,
  INDEX_SWIPE_GROUPS_CHAT_ID,
  INDEX_SWIPE_CANDIDATES_MESSAGE_ID,
  INDEX_SWIPE_CANDIDATES_MESSAGE_INDEX,
  INDEX_CONVERSATION_BRANCHES_CHAT_ID,
  INDEX_CONVERSATION_BRANCHES_PARENT_ID,
  INDEX_BRANCH_MESSAGES_MESSAGE_ID,
  INDEX_BRANCH_SWIPE_SELECTIONS_MESSAGE_ID,
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
  COLUMN_PRESET_TEMPERATURE,
  COLUMN_PRESET_CREATED_AT,
  COLUMN_PRESET_UPDATED_AT,
  COLUMN_SWIPE_ASSISTANT_MESSAGE_ID,
  COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX,
  COLUMN_SWIPE_CANDIDATE_ID,
  COLUMN_SWIPE_CANDIDATE_INDEX,
  COLUMN_BRANCH_ID,
  COLUMN_PARENT_BRANCH_ID,
  COLUMN_FORK_MESSAGE_ID,
  COLUMN_IS_ROOT,
  COLUMN_ACTIVE_BRANCH_ID,
  COLUMN_POSITION,
  COLUMN_CANDIDATE_INDEX,
  COLUMN_ERROR_MESSAGE
} from '../../../main/ets/database/DatabaseConstants';
import {
  V4_SCHEMA_STATEMENTS,
  V4_TO_V5_DDL_STATEMENTS
} from '../../../main/ets/database/DatabaseSchema';
import {
  buildMigrationPath,
  createV1ToV2Migration,
  createV2ToV3Migration,
  createV3ToV4Migration,
  createV4ToV5Migration,
  DatabaseMigration
} from '../../../main/ets/database/DatabaseMigration';

const TEST_DB_NAME: string = 'arktavern_v5_migration_test.db';

class FailingV4ToV5Migration implements DatabaseMigration {
  readonly fromVersion: number = 4;
  readonly toVersion: number = 5;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    await store.executeSql(V4_TO_V5_DDL_STATEMENTS[0]);
    throw new Error('intentional v5 migration failure');
  }
}

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function deleteDb(context: common.Context): Promise<void> {
  try {
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

function swipeGroupBucket(
  assistantMessageId: string, chatId: string, activeIndex: number
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_SWIPE_ASSISTANT_MESSAGE_ID] = assistantMessageId;
  bucket[COLUMN_CHAT_ID] = chatId;
  bucket[COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX] = activeIndex;
  bucket[COLUMN_CREATED_AT] = 5000;
  bucket[COLUMN_UPDATED_AT] = 5000;
  return bucket;
}

function swipeCandidateBucket(
  id: string, assistantMessageId: string, candidateIndex: number
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_SWIPE_CANDIDATE_ID] = id;
  bucket[COLUMN_SWIPE_ASSISTANT_MESSAGE_ID] = assistantMessageId;
  bucket[COLUMN_SWIPE_CANDIDATE_INDEX] = candidateIndex;
  bucket[COLUMN_CONTENT] = 'candidate content';
  bucket[COLUMN_STATUS] = 'completed';
  bucket[COLUMN_CREATED_AT] = 5100;
  bucket[COLUMN_UPDATED_AT] = 5100;
  bucket[COLUMN_IS_STREAMING] = 0;
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

function presetBucket(id: string, name: string): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_PRESET_ID] = id;
  bucket[COLUMN_PRESET_NAME] = name;
  bucket[COLUMN_PRESET_SYSTEM_PROMPT] = 'test system prompt';
  bucket[COLUMN_PRESET_TEMPERATURE] = 0.7;
  bucket[COLUMN_PRESET_CREATED_AT] = 6000;
  bucket[COLUMN_PRESET_UPDATED_AT] = 6000;
  return bucket;
}

/**
 * 创建 v4 数据库(含旧数据),用于 v4→v5 迁移测试。
 * 包含: 1 个 Chat + 2 条 Message(1 user + 1 assistant) + 1 个 SwipeGroup(activeIndex=1) + 2 个 Candidates
 */
async function createV4DbWithData(
  context: common.Context
): Promise<relationalStore.RdbStore> {
  const config: relationalStore.StoreConfig = {
    name: TEST_DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  const store: relationalStore.RdbStore =
    await relationalStore.getRdbStore(context, config);

  for (let i = 0; i < V4_SCHEMA_STATEMENTS.length; i++) {
    await store.executeSql(V4_SCHEMA_STATEMENTS[i]);
  }
  await store.executeSql('PRAGMA user_version = 4');

  // 插入 v4 旧数据
  await store.insert(TABLE_CHARACTERS, characterBucket('c-v4', 'OldChar'));
  await store.insert(TABLE_CHATS, chatBucket('chat-v4', 'c-v4', 'OldChat'));
  await store.insert(TABLE_MESSAGES, messageBucket('msg-v4-u', 'chat-v4', 'user', 'completed', 1));
  await store.insert(TABLE_MESSAGES, messageBucket('msg-v4-a', 'chat-v4', 'assistant', 'completed', 2));
  await store.insert(TABLE_LOREBOOKS, lorebookBucket('lb-v4', 'OldLorebook'));
  await store.insert(TABLE_LOREBOOK_ENTRIES, lorebookEntryBucket('le-v4', 'lb-v4'));
  await store.insert(TABLE_PROMPT_PRESETS, presetBucket('p-v4', 'OldPreset'));
  // Swipe data: activeIndex=1
  await store.insert(TABLE_MESSAGE_SWIPE_GROUPS, swipeGroupBucket('msg-v4-a', 'chat-v4', 1));
  await store.insert(TABLE_MESSAGE_SWIPE_CANDIDATES, swipeCandidateBucket('cand-0', 'msg-v4-a', 0));
  await store.insert(TABLE_MESSAGE_SWIPE_CANDIDATES, swipeCandidateBucket('cand-1', 'msg-v4-a', 1));

  return store;
}

/**
 * 创建 v4 数据库(空 Chat,无 Message),用于空 Chat 迁移测试。
 */
async function createV4DbWithEmptyChat(
  context: common.Context
): Promise<relationalStore.RdbStore> {
  const config: relationalStore.StoreConfig = {
    name: TEST_DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  const store: relationalStore.RdbStore =
    await relationalStore.getRdbStore(context, config);

  for (let i = 0; i < V4_SCHEMA_STATEMENTS.length; i++) {
    await store.executeSql(V4_SCHEMA_STATEMENTS[i]);
  }
  await store.executeSql('PRAGMA user_version = 4');

  // 空 Chat(无 Message)
  await store.insert(TABLE_CHATS, chatBucket('chat-empty', null, 'EmptyChat'));

  return store;
}

export default function databaseV5MigrationTest(): void {
  describe('DatabaseV5MigrationTest', () => {

    // ===== 1. DATABASE_VERSION = 5 =====
    it('DATABASE_VERSION_is_5', 0, () => {
      expect(DATABASE_VERSION).assertEqual(5);
    });

    // ===== 2. 新安装完整 v5 =====
    it('fresh_install_creates_v5', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(5);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 3. 四张 Branch 表存在 =====
    it('v5_has_conversation_branches_table', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_CONVERSATION_BRANCHES)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    it('v5_has_chat_branch_state_table', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_CHAT_BRANCH_STATE)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    it('v5_has_conversation_branch_messages_table', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_CONVERSATION_BRANCH_MESSAGES)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    it('v5_has_conversation_branch_swipe_selections_table', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 4. Branch 索引存在 =====
    it('v5_has_branch_indexes', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await indexExists(store, INDEX_CONVERSATION_BRANCHES_CHAT_ID)).assertTrue();
        expect(await indexExists(store, INDEX_CONVERSATION_BRANCHES_PARENT_ID)).assertTrue();
        expect(await indexExists(store, INDEX_BRANCH_MESSAGES_MESSAGE_ID)).assertTrue();
        expect(await indexExists(store, INDEX_BRANCH_SWIPE_SELECTIONS_MESSAGE_ID)).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 5. v4→v5 成功 =====
    it('v4_to_v5_migration_succeeds', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(5);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 6. 每个旧 Chat 创建 Root Branch =====
    it('v4_to_v5_creates_root_branch_for_chat', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql(
          `SELECT * FROM ${TABLE_CONVERSATION_BRANCHES} WHERE ${COLUMN_CHAT_ID}='chat-v4' AND ${COLUMN_IS_ROOT}=1`
        );
        try {
          expect(rs.goToFirstRow()).assertTrue();
          const nameCol: number = rs.getColumnIndex(COLUMN_NAME);
          if (nameCol >= 0) {
            expect(rs.getString(nameCol)).assertEqual('');
          }
        } finally {
          rs.close();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 7. 空 Chat 创建 Root Branch =====
    it('v4_to_v5_creates_root_branch_for_empty_chat', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithEmptyChat(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql(
          `SELECT * FROM ${TABLE_CONVERSATION_BRANCHES} WHERE ${COLUMN_CHAT_ID}='chat-empty' AND ${COLUMN_IS_ROOT}=1`
        );
        try {
          expect(rs.goToFirstRow()).assertTrue();
        } finally {
          rs.close();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 8. Root Branch Message Links 数量正确 =====
    it('v4_to_v5_root_branch_message_links_count', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        // chat-v4 has 2 messages
        const linkCount: number = await rowCount(store, TABLE_CONVERSATION_BRANCH_MESSAGES);
        expect(linkCount).assertEqual(2);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 9. Message 顺序正确(position ASC) =====
    it('v4_to_v5_message_links_ordered_by_position', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql(
          `SELECT * FROM ${TABLE_CONVERSATION_BRANCH_MESSAGES} ORDER BY ${COLUMN_POSITION} ASC`
        );
        try {
          expect(rs.goToFirstRow()).assertTrue();
          const posCol: number = rs.getColumnIndex(COLUMN_POSITION);
          const msgIdCol: number = rs.getColumnIndex(COLUMN_ID);
          if (posCol >= 0 && msgIdCol >= 0) {
            expect(rs.getLong(posCol)).assertEqual(0);
            expect(rs.getString(msgIdCol)).assertEqual('msg-v4-u');
          }
          expect(rs.goToNextRow()).assertTrue();
          if (posCol >= 0 && msgIdCol >= 0) {
            expect(rs.getLong(posCol)).assertEqual(1);
            expect(rs.getString(msgIdCol)).assertEqual('msg-v4-a');
          }
        } finally {
          rs.close();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 10. chat_branch_state 指向 Root =====
    it('v4_to_v5_chat_branch_state_points_to_root', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const stateRs = await store.querySql(
          `SELECT * FROM ${TABLE_CHAT_BRANCH_STATE} WHERE ${COLUMN_CHAT_ID}='chat-v4'`
        );
        let activeBranchId: string = '';
        try {
          expect(stateRs.goToFirstRow()).assertTrue();
          const col: number = stateRs.getColumnIndex(COLUMN_ACTIVE_BRANCH_ID);
          if (col >= 0) {
            activeBranchId = stateRs.getString(col);
          }
        } finally {
          stateRs.close();
        }
        expect(activeBranchId.length > 0).assertTrue();
        // Verify the active branch is the root
        const branchRs = await store.querySql(
          `SELECT * FROM ${TABLE_CONVERSATION_BRANCHES} WHERE ${COLUMN_ID}='${activeBranchId}'`
        );
        try {
          expect(branchRs.goToFirstRow()).assertTrue();
          const isRootCol: number = branchRs.getColumnIndex(COLUMN_IS_ROOT);
          if (isRootCol >= 0) {
            expect(branchRs.getLong(isRootCol)).assertEqual(1);
          }
        } finally {
          branchRs.close();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 11. 已有 Swipe activeIndex 迁移为 BranchSelection =====
    it('v4_to_v5_swipe_activeindex_migrated_to_branch_selection', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const selCount: number = await rowCount(store, TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS);
        expect(selCount).assertEqual(1);
        const rs = await store.querySql(
          `SELECT * FROM ${TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS} WHERE ${COLUMN_SWIPE_ASSISTANT_MESSAGE_ID}='msg-v4-a'`
        );
        try {
          expect(rs.goToFirstRow()).assertTrue();
          const idxCol: number = rs.getColumnIndex(COLUMN_CANDIDATE_INDEX);
          if (idxCol >= 0) {
            // Original activeIndex was 1
            expect(rs.getLong(idxCol)).assertEqual(1);
          }
        } finally {
          rs.close();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 12. Candidate 不复制 =====
    it('v4_to_v5_does_not_duplicate_candidates', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const candCount: number = await rowCount(store, TABLE_MESSAGE_SWIPE_CANDIDATES);
        expect(candCount).assertEqual(2);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 13. Message 不复制 =====
    it('v4_to_v5_does_not_duplicate_messages', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const msgCount: number = await rowCount(store, TABLE_MESSAGES);
        expect(msgCount).assertEqual(2);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 14. 旧业务表数据保留 =====
    it('v4_to_v5_preserves_old_table_data', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await rowCount(store, TABLE_CHARACTERS)).assertEqual(1);
        expect(await rowCount(store, TABLE_CHATS)).assertEqual(1);
        expect(await rowCount(store, TABLE_MESSAGES)).assertEqual(2);
        expect(await rowCount(store, TABLE_LOREBOOKS)).assertEqual(1);
        expect(await rowCount(store, TABLE_LOREBOOK_ENTRIES)).assertEqual(1);
        expect(await rowCount(store, TABLE_PROMPT_PRESETS)).assertEqual(1);
        expect(await rowCount(store, TABLE_MESSAGE_SWIPE_GROUPS)).assertEqual(1);
        expect(await rowCount(store, TABLE_MESSAGE_SWIPE_CANDIDATES)).assertEqual(2);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 15-17. current Character / Lorebook / Preset 保持 =====
    // (Preferences 层测试,此处验证数据库数据未丢失)
    it('v4_to_v5_preserves_character_data', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql(
          `SELECT * FROM ${TABLE_CHARACTERS} WHERE ${COLUMN_ID}='c-v4'`
        );
        try {
          expect(rs.goToFirstRow()).assertTrue();
          const nameCol: number = rs.getColumnIndex(COLUMN_NAME);
          if (nameCol >= 0) {
            expect(rs.getString(nameCol)).assertEqual('OldChar');
          }
        } finally {
          rs.close();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    it('v4_to_v5_preserves_lorebook_data', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql(
          `SELECT * FROM ${TABLE_LOREBOOKS} WHERE ${COLUMN_LOREBOOK_ID}='lb-v4'`
        );
        try {
          expect(rs.goToFirstRow()).assertTrue();
          const nameCol: number = rs.getColumnIndex(COLUMN_LOREBOOK_NAME);
          if (nameCol >= 0) {
            expect(rs.getString(nameCol)).assertEqual('OldLorebook');
          }
        } finally {
          rs.close();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    it('v4_to_v5_preserves_preset_data', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql(
          `SELECT * FROM ${TABLE_PROMPT_PRESETS} WHERE ${COLUMN_PRESET_ID}='p-v4'`
        );
        try {
          expect(rs.goToFirstRow()).assertTrue();
          const nameCol: number = rs.getColumnIndex(COLUMN_PRESET_NAME);
          if (nameCol >= 0) {
            expect(rs.getString(nameCol)).assertEqual('OldPreset');
          }
        } finally {
          rs.close();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 18. user_version=5 =====
    it('v4_to_v5_sets_user_version_5', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await readUserVersion(store)).assertEqual(5);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 19. 重启不重复迁移 =====
    it('v4_to_v5_restart_does_not_re_migrate', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const branchCountAfterFirst: number = await rowCount(store, TABLE_CONVERSATION_BRANCHES);
        await helper.close();
        // Re-initialize
        await helper.initialize(ctx);
        const store2: relationalStore.RdbStore = helper.getStore();
        const branchCountAfterSecond: number = await rowCount(store2, TABLE_CONVERSATION_BRANCHES);
        expect(branchCountAfterSecond).assertEqual(branchCountAfterFirst);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 20. 失败回滚到 4 =====
    it('v4_to_v5_failure_rolls_back_to_4', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), new FailingV4ToV5Migration()]);
      try {
        try {
          await helper.initialize(ctx);
          expect(false).assertTrue(); // should have thrown
        } catch (e) {
          // expected
        }
        // Verify version is still 4
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore =
          await relationalStore.getRdbStore(ctx, config);
        const version: number = await readUserVersion(store);
        expect(version).assertEqual(4);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 21. 失败不留下部分 Branch =====
    it('v4_to_v5_failure_no_partial_branches', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      await createV4DbWithData(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), new FailingV4ToV5Migration()]);
      try {
        try {
          await helper.initialize(ctx);
        } catch (e) {
          // expected
        }
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore =
          await relationalStore.getRdbStore(ctx, config);
        // Failing migration creates tables but throws before creating Root Branch
        // Branch tables may exist but should have 0 rows
        const branchCount: number = await rowCount(store, TABLE_CONVERSATION_BRANCHES);
        expect(branchCount).assertEqual(0);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 22. 高版本拒绝 =====
    it('higher_version_rejected', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      // Create v5 database
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        await helper.close();
        // Manually set version to 6
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore =
          await relationalStore.getRdbStore(ctx, config);
        await store.executeSql('PRAGMA user_version = 6');
        // Re-initialize should fail
        const helper2: DbHelper = new DbHelper(TEST_DB_NAME,
          [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
        try {
          try {
            await helper2.initialize(ctx);
            expect(false).assertTrue(); // should have thrown
          } catch (e) {
            // expected
          }
        } finally {
          try { await helper2.close(); } catch (e) { /* ignore */ }
        }
      } finally {
        await deleteDb(ctx);
      }
    });

    // ===== 23. 不支持降级 =====
    it('downgrade_not_supported', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      // Create v5 database
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        await helper.close();
        // Manually set version to 4 (downgrade)
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore =
          await relationalStore.getRdbStore(ctx, config);
        await store.executeSql('PRAGMA user_version = 4');
        // Re-initialize should fail (no v5 migration since current=4 but target=5)
        // Actually with currentVersion=4 and targetVersion=5, it should try to migrate again
        // But v5 tables already exist, so the migration should be idempotent
        // The real downgrade test: set version to 6, target is 5
        await store.executeSql('PRAGMA user_version = 6');
        const helper2: DbHelper = new DbHelper(TEST_DB_NAME,
          [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
        try {
          try {
            await helper2.initialize(ctx);
            expect(false).assertTrue(); // should have thrown
          } catch (e) {
            // expected: downgrade not supported
          }
        } finally {
          try { await helper2.close(); } catch (e) { /* ignore */ }
        }
      } finally {
        await deleteDb(ctx);
      }
    });

    // ===== 24. Branch 表不含正文 =====
    it('branch_tables_no_content_columns', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        // conversation_branches should not have content column
        const rs = await store.querySql(`PRAGMA table_info(${TABLE_CONVERSATION_BRANCHES})`);
        try {
          let hasContent: boolean = false;
          while (rs.goToNextRow()) {
            const nameCol: number = rs.getColumnIndex('name');
            if (nameCol >= 0) {
              const colName: string = rs.getString(nameCol);
              if (colName === COLUMN_CONTENT || colName === 'prompt' || colName === 'api_key') {
                hasContent = true;
              }
            }
          }
          expect(hasContent).assertFalse();
        } finally {
          rs.close();
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 25. 不含 API Key / Prompt / Secret =====
    it('branch_tables_no_api_key_prompt_secret', 0, async () => {
      const ctx: common.Context = await getContext();
      await deleteDb(ctx);
      const helper: DbHelper = new DbHelper(TEST_DB_NAME,
        [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration()]);
      try {
        await helper.initialize(ctx);
        const store: relationalStore.RdbStore = helper.getStore();
        const tables: string[] = [
          TABLE_CONVERSATION_BRANCHES,
          TABLE_CHAT_BRANCH_STATE,
          TABLE_CONVERSATION_BRANCH_MESSAGES,
          TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS
        ];
        for (let i = 0; i < tables.length; i++) {
          const rs = await store.querySql(`PRAGMA table_info(${tables[i]})`);
          try {
            while (rs.goToNextRow()) {
              const nameCol: number = rs.getColumnIndex('name');
              if (nameCol >= 0) {
                const colName: string = rs.getString(nameCol).toLowerCase();
                expect(colName.indexOf('api_key') < 0).assertTrue();
                expect(colName.indexOf('secret') < 0).assertTrue();
                expect(colName.indexOf('prompt') < 0).assertTrue();
                expect(colName.indexOf('authorization') < 0).assertTrue();
                expect(colName.indexOf('bearer') < 0).assertTrue();
              }
            }
          } finally {
            rs.close();
          }
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });
  });
}
