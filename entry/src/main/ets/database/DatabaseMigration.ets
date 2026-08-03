/**
 * 数据库迁移框架
 *
 * 职责:
 * - 定义单步迁移接口
 * - 维护已注册的迁移列表
 * - 计算从 currentVersion 到 targetVersion 的迁移路径
 * - 不实现 destructive migration(禁止 DROP TABLE)
 *
 * 限制:
 * - 不支持降级(currentVersion > targetVersion 抛错)
 * - 不支持跳版本(必须逐版本)
 * - 不修改入参 migrations 数组
 */

import { relationalStore } from '@kit.ArkData';
import { V1_TO_V2_STATEMENTS, V2_TO_V3_STATEMENTS, V3_TO_V4_STATEMENTS, V4_TO_V5_DDL_STATEMENTS, V5_TO_V6_STATEMENTS, V6_TO_V7_STATEMENTS, V7_TO_V8_DDL_STATEMENTS, V8_TO_V9_STATEMENTS, V9_TO_V10_DDL_STATEMENTS, V10_TO_V11_DDL_STATEMENTS, V11_TO_V12_DDL_STATEMENTS, V11_TO_V12_DATA_MIGRATION_STATEMENTS, V12_TO_V13_DDL_STATEMENTS, V13_TO_V14_DDL_STATEMENTS, V13_TO_V14_DATA_MIGRATION_STATEMENTS, V14_TO_V15_DDL_STATEMENTS } from './DatabaseSchema';
import {
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_CONVERSATION_BRANCHES,
  TABLE_CHAT_BRANCH_STATE,
  TABLE_CONVERSATION_BRANCH_MESSAGES,
  TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS,
  TABLE_CHARACTERS,
  COLUMN_ID,
  COLUMN_CHAT_ID,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_LAST_MESSAGE_AT,
  COLUMN_NAME,
  COLUMN_PARENT_BRANCH_ID,
  COLUMN_FORK_MESSAGE_ID,
  COLUMN_IS_ROOT,
  COLUMN_ACTIVE_BRANCH_ID,
  COLUMN_BRANCH_ID,
  COLUMN_POSITION,
  COLUMN_SWIPE_ASSISTANT_MESSAGE_ID,
  COLUMN_CANDIDATE_INDEX,
  COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX,
  COLUMN_SORT_ORDER,
  COLUMN_ROLE,
  COLUMN_SENDER_TYPE
} from './DatabaseConstants';
import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

export interface DatabaseMigration {
  readonly fromVersion: number;
  readonly toVersion: number;
  migrate(store: relationalStore.RdbStore): Promise<void>;
}

export interface MigrationPath {
  readonly fromVersion: number;
  readonly toVersion: number;
  readonly steps: DatabaseMigration[];
}

export function buildMigrationPath(
  currentVersion: number,
  targetVersion: number,
  migrations: ReadonlyArray<DatabaseMigration>
): MigrationPath {
  if (currentVersion === targetVersion) {
    return { fromVersion: currentVersion, toVersion: targetVersion, steps: [] };
  }
  if (currentVersion > targetVersion) {
    throw new Error('downgrade not supported');
  }

  const sorted: DatabaseMigration[] = [...migrations].sort(
    (a, b) => a.fromVersion - b.fromVersion
  );

  const steps: DatabaseMigration[] = [];
  let expected: number = currentVersion;
  for (let i = 0; i < sorted.length; i++) {
    const m: DatabaseMigration = sorted[i];
    if (m.fromVersion !== expected) {
      continue;
    }
    if (m.toVersion > targetVersion) {
      continue;
    }
    steps.push(m);
    expected = m.toVersion;
    if (expected === targetVersion) {
      break;
    }
  }

  if (expected !== targetVersion) {
    throw new Error(`no migration path from ${currentVersion} to ${targetVersion}`);
  }

  return { fromVersion: currentVersion, toVersion: targetVersion, steps };
}

export function isMigrationRegistryValid(
  migrations: ReadonlyArray<DatabaseMigration>
): boolean {
  if (migrations.length === 0) {
    return true;
  }
  const seen: Set<string> = new Set();
  for (let i = 0; i < migrations.length; i++) {
    const m: DatabaseMigration = migrations[i];
    if (m.fromVersion >= m.toVersion) {
      return false;
    }
    const key: string = `${m.fromVersion}->${m.toVersion}`;
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
  }
  return true;
}

/**
 * 创建 v1→v2 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 lorebooks 表
 * 2. 创建 lorebook_entries 表
 * 3. 创建新索引
 * 4. 任一失败全部回滚,不影响旧数据
 */
export function createV1ToV2Migration(): DatabaseMigration {
  return new V1ToV2Migration();
}

class V1ToV2Migration implements DatabaseMigration {
  readonly fromVersion: number = 1;
  readonly toVersion: number = 2;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V1_TO_V2_STATEMENTS.length; i++) {
      await store.executeSql(V1_TO_V2_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v2→v3 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 prompt_presets 表
 * 2. 创建相关索引
 * 3. 任一失败全部回滚,不影响旧数据
 */
export function createV2ToV3Migration(): DatabaseMigration {
  return new V2ToV3Migration();
}

class V2ToV3Migration implements DatabaseMigration {
  readonly fromVersion: number = 2;
  readonly toVersion: number = 3;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V2_TO_V3_STATEMENTS.length; i++) {
      await store.executeSql(V2_TO_V3_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v3→v4 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 message_swipe_groups 表
 * 2. 创建 message_swipe_candidates 表
 * 3. 创建 Swipe 索引
 * 4. 任一失败全部回滚,不影响旧数据
 * 5. 不修改现有表结构
 * 6. 不为旧消息批量创建 Swipe 数据
 */
export function createV3ToV4Migration(): DatabaseMigration {
  return new V3ToV4Migration();
}

class V3ToV4Migration implements DatabaseMigration {
  readonly fromVersion: number = 3;
  readonly toVersion: number = 4;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V3_TO_V4_STATEMENTS.length; i++) {
      await store.executeSql(V3_TO_V4_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v4→v5 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 conversation_branches / chat_branch_state /
 *    conversation_branch_messages / conversation_branch_swipe_selections 表
 * 2. 创建相关索引
 * 3. 为每个现有 Chat 创建 Root Branch
 * 4. 为每个 Chat 的全部 Message 创建 BranchMessage Link(按 sequence ASC)
 * 5. 为已有 Swipe Group 创建 Root Branch 的 SwipeSelection
 * 6. 创建 chat_branch_state 指向 Root Branch
 * 7. 任一失败全部回滚,不影响旧数据
 * 8. 不修改 Message / Candidate / Group 数据
 */
export function createV4ToV5Migration(): DatabaseMigration {
  return new V4ToV5Migration();
}

class V4ToV5Migration implements DatabaseMigration {
  readonly fromVersion: number = 4;
  readonly toVersion: number = 5;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. 执行 DDL(建表 + 建索引)
    for (let i = 0; i < V4_TO_V5_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V4_TO_V5_DDL_STATEMENTS[i]);
    }

    // 2. 为每个现有 Chat 创建 Root Branch + Message Links + SwipeSelections + BranchState
    const chatIds: string[] = await this.listAllChatIds(store);
    for (let i = 0; i < chatIds.length; i++) {
      await this.createRootBranchForChat(store, chatIds[i]);
    }
  }

  private async listAllChatIds(store: relationalStore.RdbStore): Promise<string[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const ids: string[] = [];
    try {
      while (rs.goToNextRow()) {
        const col: number = rs.getColumnIndex(COLUMN_ID);
        if (col >= 0) {
          ids.push(rs.getString(col));
        }
      }
    } finally {
      rs.close();
    }
    return ids;
  }

  private async createRootBranchForChat(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<void> {
    const now: number = nowMillis();
    const branchId: string = generateUuid();

    // 插入 Root Branch
    const branchBucket: relationalStore.ValuesBucket = {};
    branchBucket[COLUMN_ID] = branchId;
    branchBucket[COLUMN_CHAT_ID] = chatId;
    branchBucket[COLUMN_PARENT_BRANCH_ID] = null;
    branchBucket[COLUMN_FORK_MESSAGE_ID] = null;
    branchBucket[COLUMN_NAME] = '';
    branchBucket[COLUMN_IS_ROOT] = 1;
    branchBucket[COLUMN_CREATED_AT] = now;
    branchBucket[COLUMN_UPDATED_AT] = now;
    branchBucket[COLUMN_LAST_MESSAGE_AT] = now;
    await store.insert(TABLE_CONVERSATION_BRANCHES, branchBucket);

    // 查询该 Chat 的全部 messages,按 sequence ASC, createdAt ASC, id ASC 排序
    const msgPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    msgPredicates.equalTo(COLUMN_CHAT_ID, chatId);
    msgPredicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    msgPredicates.orderByAsc(COLUMN_CREATED_AT);
    msgPredicates.orderByAsc(COLUMN_ID);
    const msgRs: relationalStore.ResultSet = await store.query(msgPredicates);
    const messageIds: string[] = [];
    try {
      while (msgRs.goToNextRow()) {
        const col: number = msgRs.getColumnIndex(COLUMN_ID);
        if (col >= 0) {
          messageIds.push(msgRs.getString(col));
        }
      }
    } finally {
      msgRs.close();
    }

    // 为每条 Message 创建 BranchMessage Link
    for (let i = 0; i < messageIds.length; i++) {
      const linkBucket: relationalStore.ValuesBucket = {};
      linkBucket[COLUMN_BRANCH_ID] = branchId;
      linkBucket[COLUMN_ID] = messageIds[i];
      linkBucket[COLUMN_POSITION] = i;
      linkBucket[COLUMN_CREATED_AT] = now;
      await store.insert(TABLE_CONVERSATION_BRANCH_MESSAGES, linkBucket);
    }

    // 查询该 Chat 的已有 Swipe Groups,迁移为 Root Branch 的 SwipeSelection
    const swipePredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_GROUPS);
    swipePredicates.equalTo(COLUMN_CHAT_ID, chatId);
    const swipeRs: relationalStore.ResultSet = await store.query(swipePredicates);
    const swipeEntries: BranchSwipeMigrationEntry[] = [];
    try {
      while (swipeRs.goToNextRow()) {
        const msgIdCol: number = swipeRs.getColumnIndex(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID);
        const activeIdxCol: number = swipeRs.getColumnIndex(COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX);
        if (msgIdCol >= 0 && activeIdxCol >= 0) {
          swipeEntries.push({
            assistantMessageId: swipeRs.getString(msgIdCol),
            activeCandidateIndex: swipeRs.getLong(activeIdxCol)
          });
        }
      }
    } finally {
      swipeRs.close();
    }

    for (let i = 0; i < swipeEntries.length; i++) {
      const entry: BranchSwipeMigrationEntry = swipeEntries[i];
      const selBucket: relationalStore.ValuesBucket = {};
      selBucket[COLUMN_BRANCH_ID] = branchId;
      selBucket[COLUMN_SWIPE_ASSISTANT_MESSAGE_ID] = entry.assistantMessageId;
      selBucket[COLUMN_CANDIDATE_INDEX] = entry.activeCandidateIndex;
      selBucket[COLUMN_UPDATED_AT] = now;
      await store.insert(TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS, selBucket);
    }

    // 创建 chat_branch_state 指向 Root Branch
    const stateBucket: relationalStore.ValuesBucket = {};
    stateBucket[COLUMN_CHAT_ID] = chatId;
    stateBucket[COLUMN_ACTIVE_BRANCH_ID] = branchId;
    stateBucket[COLUMN_UPDATED_AT] = now;
    await store.insert(TABLE_CHAT_BRANCH_STATE, stateBucket);
  }
}

interface BranchSwipeMigrationEntry {
  readonly assistantMessageId: string;
  readonly activeCandidateIndex: number;
}

/**
 * 创建 v5→v6 数据库迁移。
 *
 * 事务中执行:
 * 1. 为 characters 表添加 Tavern Card V2 扩展字段
 *    (mes_example / creator_notes / post_history_instructions /
 *     alternate_greetings_json / tags_json / creator / character_version /
 *     extensions_json / character_book_id)
 * 2. 旧角色新字段使用 DEFAULT 值('' / '[]' / '{}'),不强制填写
 * 3. 任一失败全部回滚,不影响旧数据
 * 4. 不修改 Message / Branch / Swipe 等其他表
 */
export function createV5ToV6Migration(): DatabaseMigration {
  return new V5ToV6Migration();
}

class V5ToV6Migration implements DatabaseMigration {
  readonly fromVersion: number = 5;
  readonly toVersion: number = 6;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V5_TO_V6_STATEMENTS.length; i++) {
      await store.executeSql(V5_TO_V6_STATEMENTS[i]);
    }
  }
}

/**
 * v6 → v7 迁移
 *
 * 改动:
 * - characters 表添加 sort_order INTEGER NOT NULL DEFAULT 0
 * - chats 表添加 sort_order INTEGER NOT NULL DEFAULT 0
 * - 回填旧数据:按现有默认排序分配连续 sort_order(0, 1, 2, ...)
 *   - characters: 按 created_at ASC, id ASC
 *   - chats: 按 last_message_at DESC, updated_at DESC, id ASC(保持原 list() 默认顺序)
 *
 * 安全性:
 * - 所有 DDL 用 IF NOT EXISTS / ALTER TABLE ADD COLUMN(重复执行会报错,但事务保证回滚)
 * - 数据回填使用 UPDATE WHERE id = ?,按当前列表顺序逐条更新
 * - 任一失败全部回滚,不影响旧数据
 */
export function createV6ToV7Migration(): DatabaseMigration {
  return new V6ToV7Migration();
}

class V6ToV7Migration implements DatabaseMigration {
  readonly fromVersion: number = 6;
  readonly toVersion: number = 7;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. 执行 DDL(添加 sort_order 字段)
    for (let i = 0; i < V6_TO_V7_STATEMENTS.length; i++) {
      await store.executeSql(V6_TO_V7_STATEMENTS[i]);
    }

    // 2. 回填 characters: 按 created_at ASC, id ASC 分配 sort_order
    await this.backfillSortOrder(store, TABLE_CHARACTERS, true);

    // 3. 回填 chats: 按 last_message_at DESC, updated_at DESC, id ASC 分配 sort_order
    await this.backfillSortOrder(store, TABLE_CHATS, false);
  }

  /**
   * 按现有默认顺序回填 sort_order(0, 1, 2, ...)
   *
   * @param store RDB Store
   * @param tableName 表名
   * @param ascending true=按 created_at ASC(characters),false=按 last_message_at DESC(chats)
   */
  private async backfillSortOrder(
    store: relationalStore.RdbStore,
    tableName: string,
    ascending: boolean
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(tableName);
    if (ascending) {
      predicates.orderByAsc(COLUMN_CREATED_AT);
    } else {
      predicates.orderByDesc(COLUMN_LAST_MESSAGE_AT);
      predicates.orderByDesc(COLUMN_UPDATED_AT);
    }
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const ids: string[] = [];
    try {
      while (rs.goToNextRow()) {
        const col: number = rs.getColumnIndex(COLUMN_ID);
        if (col >= 0) {
          ids.push(rs.getString(col));
        }
      }
    } finally {
      rs.close();
    }

    // 逐条 UPDATE sort_order
    for (let i = 0; i < ids.length; i++) {
      const updatePredicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(tableName);
      updatePredicates.equalTo(COLUMN_ID, ids[i]);
      const bucket: relationalStore.ValuesBucket = {};
      bucket[COLUMN_SORT_ORDER] = i;
      await store.update(bucket, updatePredicates);
    }
  }
}

/**
 * 创建 v7→v8 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 chat_memories 表(分支感知长期记忆)
 * 2. 创建相关索引(chat_id / branch_id / branch_id+end_position)
 * 3. 不为旧 Chat 创建 Memory 记录(按需触发总结时才创建)
 * 4. 任一失败全部回滚,不影响旧数据
 * 5. 不修改现有 Branch / Message / Swipe 数据
 *
 * 设计:
 * - Memory 表通过 (chat_id, branch_id) 关联现有 Branch
 * - 不强制每个 Chat 都有 Memory,旧 Chat 视为新无 Memory,后续按需总结
 * - 共享祖先记忆通过 inherited_from_memory_id 字段标记,删除 Branch 时不级联删除共享祖先记忆
 */
export function createV7ToV8Migration(): DatabaseMigration {
  return new V7ToV8Migration();
}

class V7ToV8Migration implements DatabaseMigration {
  readonly fromVersion: number = 7;
  readonly toVersion: number = 8;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 仅执行 DDL(建表 + 建索引),不创建任何 Memory 数据
    // 旧 Chat 视为"无 Memory",后续按需触发总结
    for (let i = 0; i < V7_TO_V8_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V7_TO_V8_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v8→v9 数据库迁移。
 *
 * 事务中执行:
 * 1. characters 表添加 user_name TEXT NOT NULL DEFAULT ''(角色对用户的称呼)
 * 2. chats 表添加 user_name_override TEXT NOT NULL DEFAULT ''(对话级覆盖)
 * 3. 旧角色 / 旧对话新字段使用空字符串(表示"未设置",运行时回退到全局用户称呼)
 * 4. 任一失败全部回滚,不影响旧数据
 * 5. 不修改 Message / Branch / Swipe / Memory 数据
 *
 * 设计:
 * - 留空时由 ChatService.resolveUserName 按优先级回退:
 *   对话覆盖 > 角色设置 > 全局设置 > 'User'
 * - 不直接读取 V2 spec 的 data.user_name,避免覆盖用户已有角色卡数据
 */
export function createV8ToV9Migration(): DatabaseMigration {
  return new V8ToV9Migration();
}

class V8ToV9Migration implements DatabaseMigration {
  readonly fromVersion: number = 8;
  readonly toVersion: number = 9;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V8_TO_V9_STATEMENTS.length; i++) {
      await store.executeSql(V8_TO_V9_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v9→v10 数据库迁移。
 *
 * 事务中执行:
 * 1. messages 表扩展 sender_type / sender_character_id / scene_id / generation_batch_id
 * 2. 创建相关索引(messages_chat_batch / messages_sender_character)
 * 3. 旧消息 sender_type 默认 'user' (User 消息) 或根据 role 推断
 *    - role='user' → sender_type='user'
 *    - role='assistant' → sender_type='character' (单角色兼容)
 *    - role='system' → sender_type='narrator'
 * 4. 任一失败全部回滚,不影响旧数据
 * 5. 不修改现有 Character / Chat / Branch / Swipe / Memory 数据
 *
 * 设计:
 * - messages.sender_type 默认 'user' 保证旧 User 消息兼容
 * - 旧 Assistant 消息在迁移时回填 sender_type='character' 以保持一致性
 */
export function createV9ToV10Migration(): DatabaseMigration {
  return new V9ToV10Migration();
}

class V9ToV10Migration implements DatabaseMigration {
  readonly fromVersion: number = 9;
  readonly toVersion: number = 10;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. 执行 DDL(添加新字段 + 创建新表 + 创建索引)
    for (let i = 0; i < V9_TO_V10_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V9_TO_V10_DDL_STATEMENTS[i]);
    }

    // 2. 回填旧消息的 sender_type:
    //    role='assistant' → sender_type='character'(单角色兼容)
    //    role='system' → sender_type='narrator'
    //    role='user' 已经是默认 'user',无需更新
    await store.executeSql(
      `UPDATE ${TABLE_MESSAGES} SET ${COLUMN_SENDER_TYPE} = 'character' ` +
      `WHERE ${COLUMN_ROLE} = 'assistant' AND ${COLUMN_SENDER_TYPE} = 'user'`
    );
    await store.executeSql(
      `UPDATE ${TABLE_MESSAGES} SET ${COLUMN_SENDER_TYPE} = 'narrator' ` +
      `WHERE ${COLUMN_ROLE} = 'system' AND ${COLUMN_SENDER_TYPE} = 'user'`
    );
  }
}

/**
 * v10→v11 迁移:
 * - 给 messages 表添加 visibility / recipient_character_ids_json / participant_ids_json / witness_ids_json 字段
 * - 旧消息默认 visibility='public'(由 ALTER 默认值保证)
 * - 不需要回填 recipient/participant/witness(旧消息无这些信息)
 */
export function createV10ToV11Migration(): DatabaseMigration {
  return new V10ToV11Migration();
}

class V10ToV11Migration implements DatabaseMigration {
  readonly fromVersion: number = 10;
  readonly toVersion: number = 11;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V10_TO_V11_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V10_TO_V11_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v11→v12 迁移:
 * - 给 chat_memories 表添加多层记忆字段
 *   (memory_type / title / detail / importance / keywords_json / source_hash / invalidated)
 * - 创建新索引 idx_chat_memories_branch_type(branch_id, memory_type, invalidated)
 * - 旧 Memory 记录默认 memory_type='rolling',随后通过 DATA_MIGRATION 改为 'legacy'
 * - 不修改现有 Memory 的 summary / enabled / range 等字段
 * - 不创建新的 Memory 记录
 */
export function createV11ToV12Migration(): DatabaseMigration {
  return new V11ToV12Migration();
}

class V11ToV12Migration implements DatabaseMigration {
  readonly fromVersion: number = 11;
  readonly toVersion: number = 12;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. DDL: ALTER TABLE + CREATE INDEX
    for (let i = 0; i < V11_TO_V12_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V11_TO_V12_DDL_STATEMENTS[i]);
    }
    // 2. 数据迁移:将旧 Memory 标记为 'legacy' 类型
    //    新安装时表为空,UPDATE 不影响任何行
    for (let i = 0; i < V11_TO_V12_DATA_MIGRATION_STATEMENTS.length; i++) {
      await store.executeSql(V11_TO_V12_DATA_MIGRATION_STATEMENTS[i]);
    }
  }
}

/**
 * v12→v13 迁移(G-DATA-1A 多人聊天数据底座):
 * - ALTER chats 表添加 conversation_mode TEXT NOT NULL DEFAULT 'single'
 *   (旧 Chat 统一视为 Single,不从 character_id 反推模式)
 * - 创建 chat_participants 表(多人聊天参与者关系)
 * - 创建 idx_chat_participants_chat_order 索引
 *
 * 安全性:
 * - 所有 DDL 用 IF NOT EXISTS / ALTER TABLE ADD COLUMN
 * - 不重建 chats / messages / characters 等现有表
 * - 不删除任何现有数据
 * - 不为旧 Chat 创建 participant 行(旧 Chat 全部为 Single,无参与者)
 * - 任一失败由 DbHelper 事务回滚,保持 v12
 */
export function createV12ToV13Migration(): DatabaseMigration {
  return new V12ToV13Migration();
}

class V12ToV13Migration implements DatabaseMigration {
  readonly fromVersion: number = 12;
  readonly toVersion: number = 13;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V12_TO_V13_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V12_TO_V13_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v13→v14 迁移(G-CONTROL-2A 公开消息回复目标字段):
 * 1. DDL:ALTER messages 表添加 reply_target_character_ids_json TEXT 字段
 * 2. 数据迁移:将 G-CONTROL-1 误写入 recipient_character_ids_json 的
 *    公开用户消息回复目标复制到 reply_target_character_ids_json,
 *    然后清空 recipient_character_ids_json(恢复私聊语义)
 *
 * 安全性:
 * - 所有 DDL 用 ALTER TABLE ADD COLUMN
 * - 不重建 messages 表
 * - 不删除任何现有数据
 * - 数据迁移用条件 UPDATE,只影响 user+public+recipient 非空的行
 * - 私聊消息(visibility='private')的 recipient 不动
 * - 任一失败由 DbHelper 事务回滚,保持 v13
 */
export function createV13ToV14Migration(): DatabaseMigration {
  return new V13ToV14Migration();
}

class V13ToV14Migration implements DatabaseMigration {
  readonly fromVersion: number = 13;
  readonly toVersion: number = 14;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. DDL:ALTER TABLE 添加新字段
    for (let i = 0; i < V13_TO_V14_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V13_TO_V14_DDL_STATEMENTS[i]);
    }
    // 2. 数据迁移:G-CONTROL-1 旧单角色目标数据迁移
    for (let i = 0; i < V13_TO_V14_DATA_MIGRATION_STATEMENTS.length; i++) {
      await store.executeSql(V13_TO_V14_DATA_MIGRATION_STATEMENTS[i]);
    }
  }
}

/**
 * v14→v15 迁移(W-DATA-1A 世界模式数据域):
 * 1. 创建 5 张 world_* 表(worlds / world_locations / world_location_edges /
 *    world_character_instances / world_events)
 * 2. 创建相关索引(status / updated_at / world_id / from_location_id /
 *    to_location_id / is_enabled / character_id / current_location_id /
 *    world_id+is_active / world_id+occurred_at / event_type /
 *    source_character_instance_id / source_scene_id)
 *
 * 安全性:
 * - 所有 DDL 用 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
 * - 不修改任何现有表(characters / chats / messages / chat_participants 等)
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 14
 * - 失败不写入 V15
 *
 * 本阶段不实现:
 * - WorldStateService
 * - 世界 UI / 地点节点图 / 角色移动 / 世界场景 / 世界消息 / 世界 Prompt
 * - 关系 / 记忆 / AI 候选地点 / AI 世界 Builder
 */
export function createV14ToV15Migration(): DatabaseMigration {
  return new V14ToV15Migration();
}

class V14ToV15Migration implements DatabaseMigration {
  readonly fromVersion: number = 14;
  readonly toVersion: number = 15;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 仅执行 DDL(建表 + 建索引),不修改任何现有表,不迁移任何现有数据
    for (let i = 0; i < V14_TO_V15_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V14_TO_V15_DDL_STATEMENTS[i]);
    }
  }
}
