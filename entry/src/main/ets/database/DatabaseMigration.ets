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
import { V1_TO_V2_STATEMENTS, V2_TO_V3_STATEMENTS, V3_TO_V4_STATEMENTS, V4_TO_V5_DDL_STATEMENTS } from './DatabaseSchema';
import {
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_CONVERSATION_BRANCHES,
  TABLE_CHAT_BRANCH_STATE,
  TABLE_CONVERSATION_BRANCH_MESSAGES,
  TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS,
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
  COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX
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
