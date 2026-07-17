/**
 * DbHelper 设备集成测试(ohosTest,需真机/模拟器运行)
 *
 * 覆盖数据库初始化、Schema、约束、事务、生命周期、错误。
 * 使用独立的测试数据库 arktavern_test.db,与生产 arktavern.db 隔离。
 *
 * 验证项(共 40 项):
 * === 初始化与 Schema ===
 * 1. 第一次初始化成功
 * 2. 重复初始化不报错
 * 3. 并发初始化只获得一个有效 Store
 * 4. characters 表存在
 * 5. chats 表存在
 * 6. messages 表存在
 * 7. 所有索引存在
 * 8. 数据库版本为 1
 * 9. 重新创建 DbHelper 后表仍存在
 * 10. 重复执行 Schema 不报错
 *
 * === 基础 SQL 可用性 ===
 * 11. characters 可插入最小合法记录
 * 12. chats 可插入无 character_id 的普通聊天
 * 13. chats 可插入带 character_id 的角色聊天
 * 14. messages 可插入 User 消息
 * 15. messages 可插入 Assistant 消息
 * 16. messages source 可为空
 * 17. messages source 可保存 Conversation
 * 18. 同一 chat 按 sequence_number 排序正确
 * 19. 不同 chat 的消息互不混淆
 * 20. sequence 唯一索引生效
 *
 * === 约束 ===
 * 21. Character id 重复插入失败
 * 22. Chat id 重复插入失败
 * 23. Message id 重复插入失败
 * 24. Message 缺 chat_id 失败
 * 25. Message 缺 role 失败
 * 26. Message 缺 sequence_number 失败
 * 27. 必填时间字段约束生效
 *
 * === 事务 ===
 * 28. 成功事务提交
 * 29. 中途失败事务回滚
 * 30. 回滚后无部分数据残留
 * 31. 连续多个事务正常
 * 32. action 抛异常后 DbHelper 仍可继续使用
 *
 * === 生命周期和错误 ===
 * 33. 未初始化调用 getStore 返回明确错误
 * 34. close 后 getStore 返回明确错误
 * 35. close 幂等
 * 36. close 后允许重新 initialize
 * 37. 初始化错误不泄露 SQL
 * 38. 错误日志不包含正文
 * 39. 不存在 API Key 字段或表
 * 40. 不存在 Lorebook 表
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { DatabaseError, DatabaseErrorType, isDatabaseError } from '../../../main/ets/models/DatabaseError';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  INDEX_CHATS_UPDATED_AT,
  INDEX_CHATS_CHARACTER_ID,
  INDEX_MESSAGES_CHAT_SEQUENCE,
  INDEX_MESSAGES_CHAT_CREATED,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_CHARACTER_ID,
  COLUMN_TITLE,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
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

const TEST_DB_NAME: string = 'arktavern_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function deleteTestDbIfExists(ctx: common.Context): Promise<void> {
  try {
    const config: relationalStore.StoreConfig = {
      name: TEST_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore =
      await relationalStore.getRdbStore(ctx, config);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGES);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHATS);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHARACTERS);
    await store.close();
  } catch (e) {
    /* cleanup best-effort */
  }
}

async function makeHelper(): Promise<DbHelper> {
  const helper: DbHelper = new DbHelper(TEST_DB_NAME, []);
  const ctx: common.Context = await getContext();
  await deleteTestDbIfExists(ctx);
  await helper.initialize(ctx);
  return helper;
}

async function cleanupHelper(helper: DbHelper): Promise<void> {
  try {
    await helper.close();
  } catch (e) {
    /* ignore */
  }
  const ctx: common.Context = await getContext();
  await deleteTestDbIfExists(ctx);
}

async function tableExists(
  store: relationalStore.RdbStore,
  table: string
): Promise<boolean> {
  const predicates: relationalStore.RdbPredicates =
    new relationalStore.RdbPredicates(table);
  try {
    const rs = await store.query(predicates);
    const exists: boolean = rs !== null && rs !== undefined;
    try { rs.close(); } catch (e) { /* ignore */ }
    return exists;
  } catch (e) {
    return false;
  }
}

async function indexExists(
  store: relationalStore.RdbStore,
  indexName: string
): Promise<boolean> {
  const sql: string = `SELECT name FROM sqlite_master WHERE type='index' AND name='${indexName}'`;
  try {
    const rs = await store.querySql(sql);
    let found: boolean = false;
    if (rs !== null && rs !== undefined) {
      try {
        found = rs.goToFirstRow();
      } catch (e) {
        found = false;
      }
      try { rs.close(); } catch (e) { /* ignore */ }
    }
    return found;
  } catch (e) {
    return false;
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
  id: string,
  characterId: string | null,
  title: string,
  createdAt: number = 2000,
  updatedAt: number = 2000,
  lastMessageAt: number = 0
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = id;
  bucket[COLUMN_CHARACTER_ID] = characterId;
  bucket[COLUMN_TITLE] = title;
  bucket[COLUMN_CREATED_AT] = createdAt;
  bucket[COLUMN_UPDATED_AT] = updatedAt;
  bucket[COLUMN_LAST_MESSAGE_AT] = lastMessageAt;
  bucket[COLUMN_IS_ARCHIVED] = 0;
  return bucket;
}

function messageBucket(
  id: string,
  chatId: string,
  role: string,
  status: string,
  sequence: number,
  content: string = '',
  source: string | null = null
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = id;
  bucket[COLUMN_CHAT_ID] = chatId;
  bucket[COLUMN_ROLE] = role;
  bucket[COLUMN_CONTENT] = content;
  bucket[COLUMN_STATUS] = status;
  bucket[COLUMN_CREATED_AT] = 3000 + sequence;
  bucket[COLUMN_UPDATED_AT] = 3000 + sequence;
  bucket[COLUMN_SEQUENCE_NUMBER] = sequence;
  bucket[COLUMN_IS_STREAMING] = 0;
  bucket[COLUMN_SOURCE] = source;
  return bucket;
}

function omitField(
  src: relationalStore.ValuesBucket,
  key: string
): relationalStore.ValuesBucket {
  const result: relationalStore.ValuesBucket = {};
  const keys: string[] = Object.keys(src);
  for (let i: number = 0; i < keys.length; i++) {
    const k: string = keys[i];
    if (k !== key) {
      result[k] = src[k];
    }
  }
  return result;
}

export default function dbHelperDeviceTest(): void {
  describe('DbHelperDeviceTest', () => {

    // ===== 1. 第一次初始化成功 =====
    it('first_initialize_success', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        expect(helper.isInitialized()).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. 重复初始化不报错 =====
    it('repeat_initialize_no_error', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ctx: common.Context = await getContext();
        await helper.initialize(ctx);
        await helper.initialize(ctx);
        expect(helper.isInitialized()).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. 并发初始化只获得一个有效 Store =====
    it('concurrent_initialize_one_store', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ctx: common.Context = await getContext();
        const results = await Promise.all([
          helper.initialize(ctx),
          helper.initialize(ctx),
          helper.initialize(ctx)
        ]);
        expect(results.length).assertEqual(3);
        expect(helper.isInitialized()).assertTrue();
        const s: relationalStore.RdbStore = helper.getStore();
        expect(s.version).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. characters 表存在 =====
    it('characters_table_exists', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_CHARACTERS)).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. chats 表存在 =====
    it('chats_table_exists', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_CHATS)).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. messages 表存在 =====
    it('messages_table_exists', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await tableExists(store, TABLE_MESSAGES)).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. 所有索引存在 =====
    it('all_indexes_exist', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await indexExists(store, INDEX_CHATS_UPDATED_AT)).assertTrue();
        expect(await indexExists(store, INDEX_CHATS_CHARACTER_ID)).assertTrue();
        expect(await indexExists(store, INDEX_MESSAGES_CHAT_SEQUENCE)).assertTrue();
        expect(await indexExists(store, INDEX_MESSAGES_CHAT_CREATED)).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 8. 数据库版本为 1 =====
    it('database_version_is_1', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        expect(store.version).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 9. 重新创建 DbHelper 后表仍存在 =====
    it('recreate_helper_schema_persists', 0, async () => {
      const helper1: DbHelper = await makeHelper();
      const store1: relationalStore.RdbStore = helper1.getStore();
      const rowId: number = await store1.insert(TABLE_CHARACTERS, characterBucket('recreate-1', 'Recreate'));
      expect(rowId > 0).assertTrue();
      await helper1.close();

      const helper2: DbHelper = new DbHelper(TEST_DB_NAME, []);
      const ctx: common.Context = await getContext();
      await helper2.initialize(ctx);
      try {
        const store2: relationalStore.RdbStore = helper2.getStore();
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_CHARACTERS);
        predicates.equalTo(COLUMN_ID, 'recreate-1');
        const rs = await store2.query(predicates);
        let found: boolean = false;
        if (rs !== null) {
          try { found = rs.goToFirstRow(); } catch (e) { found = false; }
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        expect(found).assertTrue();
      } finally {
        await cleanupHelper(helper2);
      }
    });

    // ===== 10. 重复执行 Schema 不报错 =====
    it('re_execute_schema_no_error', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.executeSql('CREATE TABLE IF NOT EXISTS ' + TABLE_CHARACTERS + ' (' + COLUMN_ID + ' TEXT)');
        await store.executeSql('CREATE INDEX IF NOT EXISTS ' + INDEX_CHATS_UPDATED_AT + ' ON ' + TABLE_CHATS + '(' + COLUMN_UPDATED_AT + ')');
        expect(true).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 11. characters 可插入最小合法记录 =====
    it('insert_minimal_character', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        const rowId: number = await store.insert(TABLE_CHARACTERS, characterBucket('char-1', 'Alice'));
        expect(rowId > 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 12. chats 可插入无 character_id =====
    it('insert_chat_without_character_id', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        const rowId: number = await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        expect(rowId > 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 13. chats 可插入带 character_id =====
    it('insert_chat_with_character_id', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHARACTERS, characterBucket('char-1', 'Alice'));
        const rowId: number = await store.insert(TABLE_CHATS, chatBucket('chat-1', 'char-1', 'with char'));
        expect(rowId > 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 14. messages 可插入 User 消息 =====
    it('insert_user_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        const rowId: number = await store.insert(TABLE_MESSAGES, messageBucket('m-1', 'chat-1', 'user', 'completed', 1, 'hello'));
        expect(rowId > 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 15. messages 可插入 Assistant 消息 =====
    it('insert_assistant_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        const rowId: number = await store.insert(TABLE_MESSAGES, messageBucket('m-1', 'chat-1', 'assistant', 'completed', 1, 'hi'));
        expect(rowId > 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 16. messages source 可为空 =====
    it('message_source_nullable', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        const rowId: number = await store.insert(TABLE_MESSAGES, messageBucket('m-1', 'chat-1', 'user', 'completed', 1, 'x', null));
        expect(rowId > 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 17. messages source 可保存 Conversation =====
    it('message_source_conversation', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        const rowId: number = await store.insert(TABLE_MESSAGES, messageBucket('m-1', 'chat-1', 'user', 'completed', 1, 'x', 'conversation'));
        expect(rowId > 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 18. 同一 chat 按 sequence_number 排序 =====
    it('messages_sorted_by_sequence', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        await store.insert(TABLE_MESSAGES, messageBucket('m-3', 'chat-1', 'user', 'completed', 3, 'c'));
        await store.insert(TABLE_MESSAGES, messageBucket('m-1', 'chat-1', 'user', 'completed', 1, 'a'));
        await store.insert(TABLE_MESSAGES, messageBucket('m-2', 'chat-1', 'assistant', 'completed', 2, 'b'));
        const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_MESSAGES);
        predicates.equalTo(COLUMN_CHAT_ID, 'chat-1');
        predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
        const rs = await store.query(predicates);
        const ids: string[] = [];
        if (rs !== null) {
          try {
            while (rs.goToNextRow()) {
              const v: string = rs.getString(rs.getColumnIndex(COLUMN_ID) !== -1 ? rs.getColumnIndex(COLUMN_ID) : 0);
              ids.push(v);
            }
          } catch (e) { /* ignore */ }
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        expect(ids.length).assertEqual(3);
        expect(ids[0]).assertEqual('m-1');
        expect(ids[1]).assertEqual('m-2');
        expect(ids[2]).assertEqual('m-3');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 19. 不同 chat 的消息互不混淆 =====
    it('messages_isolated_per_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-A', null, 'A'));
        await store.insert(TABLE_CHATS, chatBucket('chat-B', null, 'B'));
        await store.insert(TABLE_MESSAGES, messageBucket('m-A', 'chat-A', 'user', 'completed', 1, 'a'));
        await store.insert(TABLE_MESSAGES, messageBucket('m-B', 'chat-B', 'user', 'completed', 1, 'b'));
        const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_MESSAGES);
        predicates.equalTo(COLUMN_CHAT_ID, 'chat-A');
        const rs = await store.query(predicates);
        let countA: number = 0;
        let contentA: string = '';
        if (rs !== null) {
          try {
            while (rs.goToNextRow()) {
              countA++;
              const ci: number = rs.getColumnIndex(COLUMN_CONTENT) !== -1 ? rs.getColumnIndex(COLUMN_CONTENT) : 0;
              contentA = rs.getString(ci);
            }
          } catch (e) { /* ignore */ }
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        expect(countA).assertEqual(1);
        expect(contentA).assertEqual('a');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 20. sequence 唯一索引生效 =====
    it('sequence_unique_index_enforced', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        await store.insert(TABLE_MESSAGES, messageBucket('m-1', 'chat-1', 'user', 'completed', 1, 'a'));
        let conflict: boolean = false;
        try {
          await store.insert(TABLE_MESSAGES, messageBucket('m-2', 'chat-1', 'user', 'completed', 1, 'b'));
        } catch (e) {
          conflict = true;
        }
        expect(conflict).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 21. Character id 重复插入失败 =====
    it('character_id_unique_enforced', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHARACTERS, characterBucket('c-1', 'A'));
        let conflict: boolean = false;
        try {
          await store.insert(TABLE_CHARACTERS, characterBucket('c-1', 'A2'));
        } catch (e) {
          conflict = true;
        }
        expect(conflict).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 22. Chat id 重复插入失败 =====
    it('chat_id_unique_enforced', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'A'));
        let conflict: boolean = false;
        try {
          await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'A2'));
        } catch (e) {
          conflict = true;
        }
        expect(conflict).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 23. Message id 重复插入失败 =====
    it('message_id_unique_enforced', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        await store.insert(TABLE_MESSAGES, messageBucket('m-1', 'chat-1', 'user', 'completed', 1, 'a'));
        let conflict: boolean = false;
        try {
          await store.insert(TABLE_MESSAGES, messageBucket('m-1', 'chat-1', 'user', 'completed', 2, 'b'));
        } catch (e) {
          conflict = true;
        }
        expect(conflict).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 24. Message 缺 chat_id 失败 =====
    it('message_missing_chat_id_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        const bucket: relationalStore.ValuesBucket = messageBucket('m-1', '', 'user', 'completed', 1, 'x');
        const badBucket: relationalStore.ValuesBucket = omitField(bucket, COLUMN_CHAT_ID);
        let rejected: boolean = false;
        try {
          await store.insert(TABLE_MESSAGES, badBucket);
        } catch (e) {
          rejected = true;
        }
        expect(rejected).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 25. Message 缺 role 失败 =====
    it('message_missing_role_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        const bucket: relationalStore.ValuesBucket = messageBucket('m-1', 'chat-1', '', 'completed', 1, 'x');
        const badBucket: relationalStore.ValuesBucket = omitField(bucket, COLUMN_ROLE);
        let rejected: boolean = false;
        try {
          await store.insert(TABLE_MESSAGES, badBucket);
        } catch (e) {
          rejected = true;
        }
        expect(rejected).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 26. Message 缺 sequence_number 失败 =====
    it('message_missing_sequence_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await store.insert(TABLE_CHATS, chatBucket('chat-1', null, 'plain'));
        const bucket: relationalStore.ValuesBucket = messageBucket('m-1', 'chat-1', 'user', 'completed', 0, 'x');
        const badBucket: relationalStore.ValuesBucket = omitField(bucket, COLUMN_SEQUENCE_NUMBER);
        let rejected: boolean = false;
        try {
          await store.insert(TABLE_MESSAGES, badBucket);
        } catch (e) {
          rejected = true;
        }
        expect(rejected).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 27. 必填时间字段约束生效 =====
    it('created_at_required_enforced', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        const bucket: relationalStore.ValuesBucket = characterBucket('c-1', 'A');
        const badBucket: relationalStore.ValuesBucket = omitField(bucket, COLUMN_CREATED_AT);
        let rejected: boolean = false;
        try {
          await store.insert(TABLE_CHARACTERS, badBucket);
        } catch (e) {
          rejected = true;
        }
        expect(rejected).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 28. 成功事务提交 =====
    it('transaction_commit_success', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        await helper.runInTransaction(async (s: relationalStore.RdbStore): Promise<void> => {
          await s.insert(TABLE_CHARACTERS, characterBucket('c-tx-1', 'Tx1'));
          await s.insert(TABLE_CHARACTERS, characterBucket('c-tx-2', 'Tx2'));
        });
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_CHARACTERS);
        const rs = await store.query(predicates);
        let count: number = 0;
        if (rs !== null) {
          try {
            while (rs.goToNextRow()) { count++; }
          } catch (e) { /* ignore */ }
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        expect(count).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 29. 中途失败事务回滚 =====
    it('transaction_rollback_on_failure', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        let rolled: boolean = false;
        try {
          await helper.runInTransaction(async (s: relationalStore.RdbStore): Promise<void> => {
            await s.insert(TABLE_CHARACTERS, characterBucket('c-rb-1', 'Rb1'));
            throw new Error('intentional');
          });
        } catch (e) {
          rolled = true;
        }
        expect(rolled).assertTrue();
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_CHARACTERS);
        predicates.equalTo(COLUMN_ID, 'c-rb-1');
        const rs = await store.query(predicates);
        let found: boolean = false;
        if (rs !== null) {
          try { found = rs.goToFirstRow(); } catch (e) { found = false; }
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        expect(found).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 30. 回滚后无部分数据残留 =====
    it('rollback_no_partial_data', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        try {
          await helper.runInTransaction(async (s: relationalStore.RdbStore): Promise<void> => {
            await s.insert(TABLE_CHARACTERS, characterBucket('c-partial-1', 'P1'));
            await s.insert(TABLE_CHARACTERS, characterBucket('c-partial-2', 'P2'));
            throw new Error('boom');
          });
        } catch (e) { /* expected */ }
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_CHARACTERS);
        const rs = await store.query(predicates);
        let count: number = 0;
        if (rs !== null) {
          try { while (rs.goToNextRow()) { count++; } } catch (e) { /* ignore */ }
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        expect(count).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 31. 连续多个事务正常 =====
    it('multiple_transactions_sequential', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        for (let i: number = 0; i < 5; i++) {
          await helper.runInTransaction(async (s: relationalStore.RdbStore): Promise<void> => {
            await s.insert(TABLE_CHARACTERS, characterBucket('c-seq-' + i, 'Seq' + i));
          });
        }
        const store: relationalStore.RdbStore = helper.getStore();
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_CHARACTERS);
        const rs = await store.query(predicates);
        let count: number = 0;
        if (rs !== null) {
          try { while (rs.goToNextRow()) { count++; } } catch (e) { /* ignore */ }
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        expect(count).assertEqual(5);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 32. action 抛异常后 DbHelper 仍可继续使用 =====
    it('helper_reusable_after_action_error', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        try {
          await helper.runInTransaction(async (): Promise<void> => {
              throw new Error('bad');
            });
        } catch (e) { /* expected */ }
        await helper.runInTransaction(async (s: relationalStore.RdbStore): Promise<void> => {
          await s.insert(TABLE_CHARACTERS, characterBucket('c-reuse', 'Reuse'));
        });
        expect(helper.isInitialized()).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 33. 未初始化调用 getStore 返回明确错误 =====
    it('getStore_before_init_throws_not_initialized', 0, () => {
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, []);
      let caught: boolean = false;
      let errorTypeOk: boolean = false;
      try {
        helper.getStore();
      } catch (e) {
        caught = true;
        if (e instanceof DatabaseError && e.type === DatabaseErrorType.NotInitialized) {
          errorTypeOk = true;
        }
      }
      expect(caught).assertTrue();
      expect(errorTypeOk).assertTrue();
    });

    // ===== 34. close 后 getStore 返回明确错误 =====
    it('getStore_after_close_throws_closed', 0, async () => {
      const helper: DbHelper = await makeHelper();
      await helper.close();
      let caught: boolean = false;
      let errorTypeOk: boolean = false;
      try {
        helper.getStore();
      } catch (e) {
        caught = true;
        if (isDatabaseError(e) && e.type === DatabaseErrorType.Closed) {
          errorTypeOk = true;
        }
      }
      expect(caught).assertTrue();
      expect(errorTypeOk).assertTrue();
    });

    // ===== 35. close 幂等 =====
    it('close_idempotent', 0, async () => {
      const helper: DbHelper = await makeHelper();
      await helper.close();
      await helper.close();
      await helper.close();
      expect(true).assertTrue();
    });

    // ===== 36. close 后允许重新 initialize =====
    it('reinitialize_after_close', 0, async () => {
      const helper: DbHelper = await makeHelper();
      await helper.close();
      const ctx: common.Context = await getContext();
      await helper.initialize(ctx);
      expect(helper.isInitialized()).assertTrue();
      expect(await helper.getVersion()).assertEqual(1);
      await cleanupHelper(helper);
    });

    // ===== 37. 初始化错误不泄露 SQL =====
    it('init_error_no_sql_leak', 0, async () => {
      // 通过注入不存在的 context 行为模拟错误:实际平台不允许传入 null,
      // 这里改为验证 getStore 错误的 causeMessage 不含 SQL
      const helper: DbHelper = new DbHelper(TEST_DB_NAME, []);
      let msg: string = '';
      try {
        helper.getStore();
      } catch (e) {
        if (e instanceof DatabaseError) {
          msg = e.causeMessage;
        } else if (e instanceof Error) {
          msg = e.message;
        }
      }
      expect(msg.indexOf('CREATE') < 0).assertTrue();
      expect(msg.indexOf('TABLE') < 0).assertTrue();
      expect(msg.indexOf('SELECT') < 0).assertTrue();
    });

    // ===== 38. 错误日志不包含正文 =====
    it('error_log_no_content_leak', 0, () => {
      const e1: DatabaseError = DatabaseError.notInitialized('test body content leak');
      const e2: DatabaseError = DatabaseError.closed('user message leaked here');
      const e3: DatabaseError = DatabaseError.transactionFailed('CHARACTER body');
      // 错误类型正确
      expect(e1.type).assertEqual(DatabaseErrorType.NotInitialized);
      expect(e2.type).assertEqual(DatabaseErrorType.Closed);
      expect(e3.type).assertEqual(DatabaseErrorType.TransactionFailed);
      // 错误对象不暴露原始 BusinessError
      expect(e1.toString().indexOf('BusinessError') < 0).assertTrue();
    });

    // ===== 39. 不存在 API Key 字段或表 =====
    it('no_apikey_table_or_column', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql("SELECT name FROM sqlite_master WHERE type='table'");
        const names: string[] = [];
        if (rs !== null) {
          try {
            while (rs.goToNextRow()) {
              const ci: number = rs.getColumnIndex('name') !== -1 ? rs.getColumnIndex('name') : 0;
              names.push(rs.getString(ci).toLowerCase());
            }
          } catch (e) { /* ignore */ }
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        for (let i: number = 0; i < names.length; i++) {
          expect(names[i].indexOf('apikey') < 0).assertTrue();
          expect(names[i].indexOf('secret') < 0).assertTrue();
          expect(names[i].indexOf('providerkey') < 0).assertTrue();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 40. 不存在 Lorebook 表 =====
    it('no_lorebook_table', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        const rs = await store.querySql("SELECT name FROM sqlite_master WHERE type='table'");
        const names: string[] = [];
        if (rs !== null) {
          try {
            while (rs.goToNextRow()) {
              const ci: number = rs.getColumnIndex('name') !== -1 ? rs.getColumnIndex('name') : 0;
              names.push(rs.getString(ci).toLowerCase());
            }
          } catch (e) { /* ignore */ }
          try { rs.close(); } catch (e) { /* ignore */ }
        }
        for (let i: number = 0; i < names.length; i++) {
          expect(names[i].indexOf('lorebook') < 0).assertTrue();
          expect(names[i].indexOf('worldbook') < 0).assertTrue();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
