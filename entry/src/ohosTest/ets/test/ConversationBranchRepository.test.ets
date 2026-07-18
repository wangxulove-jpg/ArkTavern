/**
 * ConversationBranchRepository 设备测试(ohosTest,需真机/模拟器运行)
 *
 * 覆盖:
 * - 创建 Root / Child Branch
 * - 每 Chat 仅一个 Root
 * - parentBranchId / forkMessageId 正确
 * - 设置 / 获取 Active Branch
 * - 插入 Message Link(position 排序/唯一/Link 唯一)
 * - 同一 Message 可被不同 Branch 共享
 * - SwipeSelection 插入 / 更新 / Candidate index 校验
 * - listBranches / messageCount / totalBranchCount / totalUniqueMessageCount / totalSwipeCandidateCount
 * - removeByChatId
 * - ResultSet 全路径关闭
 * - 错误不含正文
 * - 不影响 Character / Lorebook / Preset
 *
 * 使用独立测试数据库 arktavern_branch_repo_test.db。
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ConversationBranchRepository } from '../../../main/ets/repositories/ConversationBranchRepository';
import {
  ConversationBranch,
  BranchMessageLink,
  BranchSwipeSelection,
  ConversationBranchSummary,
  ConversationRecordCounts,
  createRootBranch,
  createChildBranch,
  createBranchMessageLink,
  createBranchSwipeSelection
} from '../../../main/ets/models/ConversationBranch';
import { DatabaseError } from '../../../main/ets/models/DatabaseError';
import {
  TABLE_CHARACTERS,
  TABLE_LOREBOOKS,
  TABLE_PROMPT_PRESETS,
  TABLE_CONVERSATION_BRANCHES,
  TABLE_CHAT_BRANCH_STATE,
  TABLE_CONVERSATION_BRANCH_MESSAGES,
  TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_LOREBOOK_ID,
  COLUMN_LOREBOOK_NAME,
  COLUMN_LOREBOOK_DESCRIPTION,
  COLUMN_LOREBOOK_ENABLED,
  COLUMN_LOREBOOK_CREATED_AT,
  COLUMN_LOREBOOK_UPDATED_AT,
  COLUMN_PRESET_ID,
  COLUMN_PRESET_NAME,
  COLUMN_PRESET_SYSTEM_PROMPT,
  COLUMN_PRESET_TEMPERATURE,
  COLUMN_PRESET_CREATED_AT,
  COLUMN_PRESET_UPDATED_AT
} from '../../../main/ets/database/DatabaseConstants';

const TEST_DB_NAME: string = 'arktavern_branch_repo_test.db';

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

async function makeRepository(): Promise<ConversationBranchRepository> {
  const ctx: common.Context = await getContext();
  await deleteDb(ctx);
  const helper: DbHelper = new DbHelper(TEST_DB_NAME);
  await helper.initialize(ctx);
  return new ConversationBranchRepository(helper);
}

async function getStore(): Promise<relationalStore.RdbStore> {
  const ctx: common.Context = await getContext();
  const config: relationalStore.StoreConfig = {
    name: TEST_DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  return await relationalStore.getRdbStore(ctx, config);
}

async function cleanupRepo(): Promise<void> {
  const ctx: common.Context = await getContext();
  await deleteDb(ctx);
}

async function rowCount(
  store: relationalStore.RdbStore, table: string
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

export default function conversationBranchRepositoryTest(): void {
  describe('ConversationBranchRepositoryTest', () => {

    // ===== 1. 创建 Root =====
    it('create_root_branch', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const branch: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        expect(branch.chatId).assertEqual('chat-1');
        expect(branch.isRoot).assertTrue();
        expect(branch.parentBranchId === undefined).assertTrue();
        expect(branch.forkMessageId === undefined).assertTrue();
        expect(branch.name).assertEqual('');
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 2. 每 Chat 仅一个 Root =====
    it('only_one_root_per_chat', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        await repo.createRootBranchWithStore(store, 'chat-1');
        let threw: boolean = false;
        try {
          await repo.createRootBranchWithStore(store, 'chat-1');
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
        // Verify only 1 root exists
        const root: ConversationBranch | null = await repo.getRootBranch('chat-1');
        expect(root !== null).assertTrue();
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 3. 创建 Child =====
    it('create_child_branch', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        const child: ConversationBranch =
          await repo.createChildBranchWithStore(
            store, 'chat-1', root.id, 'msg-1', 'Branch A'
          );
        expect(child.isRoot).assertFalse();
        expect(child.name).assertEqual('Branch A');
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 4. parentBranchId 正确 =====
    it('child_parent_branch_id_correct', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        const child: ConversationBranch =
          await repo.createChildBranchWithStore(
            store, 'chat-1', root.id, 'msg-1', 'Child'
          );
        expect(child.parentBranchId).assertEqual(root.id);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 5. forkMessageId 正确 =====
    it('child_fork_message_id_correct', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        const child: ConversationBranch =
          await repo.createChildBranchWithStore(
            store, 'chat-1', root.id, 'msg-fork', 'Child'
          );
        expect(child.forkMessageId).assertEqual('msg-fork');
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 6. 设置 Active =====
    it('set_active_branch', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        // createRootBranchWithStore also sets active
        await repo.setActiveBranchWithStore(store, 'chat-1', root.id);
        // Verify state exists
        const active: ConversationBranch | null = await repo.getActiveBranch('chat-1');
        expect(active !== null).assertTrue();
        if (active !== null) {
          expect(active.id).assertEqual(root.id);
        }
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 7. 获取 Active =====
    it('get_active_branch', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        const child: ConversationBranch =
          await repo.createChildBranchWithStore(
            store, 'chat-1', root.id, 'msg-1', 'Child'
          );
        await repo.setActiveBranchWithStore(store, 'chat-1', child.id);
        const active: ConversationBranch | null = await repo.getActiveBranch('chat-1');
        expect(active !== null).assertTrue();
        if (active !== null) {
          expect(active.id).assertEqual(child.id);
        }
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 8. 插入 Message Link =====
    it('insert_message_link', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-1', 0);
        const links: BranchMessageLink[] =
          await repo.listMessageLinks(root.id);
        expect(links.length).assertEqual(1);
        expect(links[0].messageId).assertEqual('msg-1');
        expect(links[0].position).assertEqual(0);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 9. position 排序 =====
    it('message_links_ordered_by_position', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        // Insert out of order
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-2', 1);
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-1', 0);
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-3', 2);
        const links: BranchMessageLink[] =
          await repo.listMessageLinks(root.id);
        expect(links.length).assertEqual(3);
        expect(links[0].position).assertEqual(0);
        expect(links[1].position).assertEqual(1);
        expect(links[2].position).assertEqual(2);
        expect(links[0].messageId).assertEqual('msg-1');
        expect(links[1].messageId).assertEqual('msg-2');
        expect(links[2].messageId).assertEqual('msg-3');
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 10. position 唯一 =====
    it('position_unique_per_branch', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-1', 0);
        let threw: boolean = false;
        try {
          await repo.insertMessageLinkWithStore(store, root.id, 'msg-2', 0);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 11. Message Link 唯一(branch_id + message_id) =====
    it('message_link_unique_per_branch', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-1', 0);
        let threw: boolean = false;
        try {
          await repo.insertMessageLinkWithStore(store, root.id, 'msg-1', 1);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 12. 同一 Message 可被不同 Branch 共享 =====
    it('same_message_shared_across_branches', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        const child: ConversationBranch =
          await repo.createChildBranchWithStore(
            store, 'chat-1', root.id, 'msg-1', 'Child'
          );
        // Insert same message in both branches
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-shared', 0);
        await repo.insertMessageLinkWithStore(store, child.id, 'msg-shared', 0);
        const rootLinks: BranchMessageLink[] =
          await repo.listMessageLinks(root.id);
        const childLinks: BranchMessageLink[] =
          await repo.listMessageLinks(child.id);
        expect(rootLinks.length).assertEqual(1);
        expect(childLinks.length).assertEqual(1);
        expect(rootLinks[0].messageId).assertEqual('msg-shared');
        expect(childLinks[0].messageId).assertEqual('msg-shared');
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 13. SwipeSelection 插入 =====
    it('insert_swipe_selection', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.upsertSwipeSelectionWithStore(
          store, root.id, 'msg-assistant', 0
        );
        const sel: BranchSwipeSelection | null =
          await repo.getSwipeSelection(root.id, 'msg-assistant');
        expect(sel !== null).assertTrue();
        if (sel !== null) {
          expect(sel.candidateIndex).assertEqual(0);
        }
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 14. SwipeSelection 更新 =====
    it('update_swipe_selection', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.upsertSwipeSelectionWithStore(
          store, root.id, 'msg-assistant', 0
        );
        await repo.upsertSwipeSelectionWithStore(
          store, root.id, 'msg-assistant', 2
        );
        const sel: BranchSwipeSelection | null =
          await repo.getSwipeSelection(root.id, 'msg-assistant');
        expect(sel !== null).assertTrue();
        if (sel !== null) {
          expect(sel.candidateIndex).assertEqual(2);
        }
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 15. Candidate index 校验 =====
    it('candidate_index_validation', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        // Negative index should throw
        let threw: boolean = false;
        try {
          await repo.upsertSwipeSelectionWithStore(
            store, root.id, 'msg-a', -1
          );
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 16. listBranches =====
    it('list_branches', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.createChildBranchWithStore(
          store, 'chat-1', root.id, 'msg-1', 'Child A'
        );
        await repo.createChildBranchWithStore(
          store, 'chat-1', root.id, 'msg-2', 'Child B'
        );
        const branches: ConversationBranchSummary[] =
          await repo.listBranches('chat-1');
        expect(branches.length).assertEqual(3);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 17. messageCount =====
    it('message_count', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-1', 0);
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-2', 1);
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-3', 2);
        const count: number = await repo.countMessages(root.id);
        expect(count).assertEqual(3);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 18. totalBranchCount =====
    it('total_branch_count', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.createChildBranchWithStore(
          store, 'chat-1', root.id, 'msg-1', 'Child'
        );
        const counts: ConversationRecordCounts =
          await repo.getRecordCounts('chat-1');
        expect(counts.totalBranchCount).assertEqual(2);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 19. totalUniqueMessageCount =====
    it('total_unique_message_count', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        const child: ConversationBranch =
          await repo.createChildBranchWithStore(
            store, 'chat-1', root.id, 'msg-1', 'Child'
          );
        // Root: msg-1, msg-2, msg-3
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-1', 0);
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-2', 1);
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-3', 2);
        // Child: msg-1 (shared), msg-2 (shared)
        await repo.insertMessageLinkWithStore(store, child.id, 'msg-1', 0);
        await repo.insertMessageLinkWithStore(store, child.id, 'msg-2', 1);
        const counts: ConversationRecordCounts =
          await repo.getRecordCounts('chat-1');
        // 3 unique messages (msg-1, msg-2, msg-3)
        expect(counts.totalUniqueMessageCount).assertEqual(3);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 20. totalSwipeCandidateCount =====
    it('total_swipe_candidate_count', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.upsertSwipeSelectionWithStore(
          store, root.id, 'msg-a1', 0
        );
        await repo.upsertSwipeSelectionWithStore(
          store, root.id, 'msg-a2', 1
        );
        const counts: ConversationRecordCounts =
          await repo.getRecordCounts('chat-1');
        expect(counts.totalSwipeCandidateCount).assertEqual(2);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 21. removeByChatId =====
    it('remove_by_chat_id', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-1', 0);
        await repo.upsertSwipeSelectionWithStore(
          store, root.id, 'msg-a', 0
        );
        await repo.removeByChatIdWithStore(store, 'chat-1');
        expect(await rowCount(store, TABLE_CONVERSATION_BRANCHES)).assertEqual(0);
        expect(await rowCount(store, TABLE_CHAT_BRANCH_STATE)).assertEqual(0);
        expect(await rowCount(store, TABLE_CONVERSATION_BRANCH_MESSAGES)).assertEqual(0);
        expect(await rowCount(store, TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS)).assertEqual(0);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 22. ResultSet 全路径关闭 =====
    it('resultset_closed_on_all_paths', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        // Query non-existent branch - should return null and close ResultSet
        const branch: ConversationBranch | null = await repo.getBranch('nonexistent');
        expect(branch === null).assertTrue();
        // Query non-existent root
        const root: ConversationBranch | null = await repo.getRootBranch('nonexistent');
        expect(root === null).assertTrue();
        // Query non-existent active
        const active: ConversationBranch | null = await repo.getActiveBranch('nonexistent');
        expect(active === null).assertTrue();
        // List empty branches
        const branches: ConversationBranchSummary[] = await repo.listBranches('nonexistent');
        expect(branches.length).assertEqual(0);
        // List empty message links
        const links: BranchMessageLink[] = await repo.listMessageLinks('nonexistent');
        expect(links.length).assertEqual(0);
        // Get non-existent swipe selection
        const sel: BranchSwipeSelection | null = await repo.getSwipeSelection('nonexistent', 'nonexistent');
        expect(sel === null).assertTrue();
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 23. 错误不含正文 =====
    it('errors_do_not_contain_content', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const root: ConversationBranch =
          await repo.createRootBranchWithStore(store, 'chat-secret');
        await repo.insertMessageLinkWithStore(store, root.id, 'msg-secret-content', 0);
        // Trigger errors and verify error messages don't contain content
        let errMsg: string = '';
        try {
          await repo.createRootBranchWithStore(store, 'chat-secret');
        } catch (e) {
          errMsg = (e as Error).message;
        }
        expect(errMsg.indexOf('msg-secret-content') < 0).assertTrue();
        expect(errMsg.indexOf('chat-secret') < 0).assertTrue();
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 24. 不影响 Character =====
    it('does_not_affect_characters', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        // Insert a character
        const charBucket: relationalStore.ValuesBucket = {};
        charBucket[COLUMN_ID] = 'char-1';
        charBucket[COLUMN_NAME] = 'TestChar';
        charBucket[COLUMN_CREATED_AT] = 1000;
        charBucket[COLUMN_UPDATED_AT] = 1000;
        await store.insert(TABLE_CHARACTERS, charBucket);
        // Do branch operations
        await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.removeByChatIdWithStore(store, 'chat-1');
        // Verify character still exists
        expect(await rowCount(store, TABLE_CHARACTERS)).assertEqual(1);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 25. 不影响 Lorebook =====
    it('does_not_affect_lorebooks', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        // Insert a lorebook
        const lbBucket: relationalStore.ValuesBucket = {};
        lbBucket[COLUMN_LOREBOOK_ID] = 'lb-1';
        lbBucket[COLUMN_LOREBOOK_NAME] = 'TestLorebook';
        lbBucket[COLUMN_LOREBOOK_DESCRIPTION] = '';
        lbBucket[COLUMN_LOREBOOK_ENABLED] = 1;
        lbBucket[COLUMN_LOREBOOK_CREATED_AT] = 1000;
        lbBucket[COLUMN_LOREBOOK_UPDATED_AT] = 1000;
        await store.insert(TABLE_LOREBOOKS, lbBucket);
        // Do branch operations
        await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.removeByChatIdWithStore(store, 'chat-1');
        // Verify lorebook still exists
        expect(await rowCount(store, TABLE_LOREBOOKS)).assertEqual(1);
      } finally {
        await cleanupRepo();
      }
    });

    // ===== 26. 不影响 Preset =====
    it('does_not_affect_presets', 0, async () => {
      const repo: ConversationBranchRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        // Insert a preset
        const presetBucket: relationalStore.ValuesBucket = {};
        presetBucket[COLUMN_PRESET_ID] = 'preset-1';
        presetBucket[COLUMN_PRESET_NAME] = 'TestPreset';
        presetBucket[COLUMN_PRESET_SYSTEM_PROMPT] = 'system';
        presetBucket[COLUMN_PRESET_TEMPERATURE] = 0.7;
        presetBucket[COLUMN_PRESET_CREATED_AT] = 1000;
        presetBucket[COLUMN_PRESET_UPDATED_AT] = 1000;
        await store.insert(TABLE_PROMPT_PRESETS, presetBucket);
        // Do branch operations
        await repo.createRootBranchWithStore(store, 'chat-1');
        await repo.removeByChatIdWithStore(store, 'chat-1');
        // Verify preset still exists
        expect(await rowCount(store, TABLE_PROMPT_PRESETS)).assertEqual(1);
      } finally {
        await cleanupRepo();
      }
    });
  });
}
