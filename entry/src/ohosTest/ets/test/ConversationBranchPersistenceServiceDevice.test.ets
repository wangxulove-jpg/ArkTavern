/**
 * ConversationBranchPersistenceService 设备测试(29 项,T-6.4A)
 *
 * 覆盖 ensureRootBranch / getActiveBranch / listBranches / getRecordCounts /
 * loadActiveBranchMessages / forkAtMessage / appendMessageToActiveBranch /
 * updateActiveBranchSwipeSelection / removeByChatIdWithStore 的完整行为:
 *
 * 1. ensureRootBranch 幂等
 * 2. 新 Chat Root 创建
 * 3. Active Branch 查询
 * 4. append Message 到 Active Branch
 * 5. position 自动连续(0,1,2)
 * 6. fork User Message
 * 7. fork Assistant Message
 * 8. 复制前缀 Links(0..forkPosition)
 * 9. 不复制后续 Links
 * 10. 原 Branch 保留全部 Links
 * 11. 不复制 Message 实体
 * 12. 复制 SwipeSelections
 * 13. 指定 Candidate 覆盖选择
 * 14. 不存在 Candidate 拒绝
 * 15. Message 不属于来源 Branch 拒绝
 * 16. 不同 Chat Branch 拒绝
 * 17. Child 自动成为 Active
 * 18. Root 保持存在
 * 19. loadActiveBranchMessages 顺序正确
 * 20. Branch Candidate 投影正确
 * 21. 原 Branch Candidate 选择不变
 * 22. currentBranchMessageCount 正确
 * 23. totalUniqueMessageCount 正确
 * 24. totalBranchCount 正确
 * 25. Chat 删除清理
 * 26. 并发创建 Root 不重复
 * 27. 事务失败全部回滚
 * 28. 输入对象不修改
 * 29. 日志不含正文
 *
 * 使用独立测试数据库 arktavern_branch_persistence_test.db
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import { MessageRepository } from '../../../main/ets/repositories/MessageRepository';
import { MessageSwipeRepository } from '../../../main/ets/repositories/MessageSwipeRepository';
import { ConversationBranchRepository } from '../../../main/ets/repositories/ConversationBranchRepository';
import { ConversationBranchPersistenceService } from '../../../main/ets/services/ConversationBranchPersistenceService';
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../../main/ets/models/ChatMessageSource';
import { Chat, createChat } from '../../../main/ets/models/Chat';
import { DatabaseError, DatabaseErrorType } from '../../../main/ets/models/DatabaseError';
import {
  ConversationBranch,
  BranchMessageLink,
  BranchSwipeSelection,
  ConversationRecordCounts
} from '../../../main/ets/models/ConversationBranch';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate,
  createSwipeCandidate
} from '../../../main/ets/models/MessageSwipe';
import {
  TABLE_CONVERSATION_BRANCHES,
  TABLE_CHAT_BRANCH_STATE,
  TABLE_CONVERSATION_BRANCH_MESSAGES,
  TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS,
  TABLE_MESSAGES
} from '../../../main/ets/database/DatabaseConstants';

const TEST_DB_NAME: string = 'arktavern_branch_persistence_test.db';
let idCounter: number = 0;

function uniqueId(prefix: string): string {
  idCounter++;
  return `${prefix}-${idCounter}`;
}

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function deleteTestDb(ctx: common.Context): Promise<void> {
  try {
    await relationalStore.deleteRdbStore(ctx, TEST_DB_NAME);
  } catch (e) {
    /* best-effort */
  }
}

async function makeHelper(): Promise<DbHelper> {
  const ctx: common.Context = await getContext();
  await deleteTestDb(ctx);
  const helper: DbHelper = new DbHelper(TEST_DB_NAME);
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
  await deleteTestDb(ctx);
}

function makeMessage(
  id: string,
  role: ChatRole,
  content: string,
  status?: ChatMessageStatus,
  source?: ChatMessageSource
): ChatMessage {
  const resolvedStatus: ChatMessageStatus =
    status !== undefined ? status : ChatMessageStatus.Completed;
  return {
    id: id,
    role: role,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    status: resolvedStatus,
    isStreaming: resolvedStatus === ChatMessageStatus.Streaming,
    source: source
  };
}

function setupService(helper: DbHelper): ConversationBranchPersistenceService {
  const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
  const msgRepo: MessageRepository = new MessageRepository(helper);
  const swipeRepo: MessageSwipeRepository = new MessageSwipeRepository(helper);
  return new ConversationBranchPersistenceService(helper, branchRepo, msgRepo, swipeRepo);
}

async function createChatInDb(helper: DbHelper, chatId: string, title: string): Promise<Chat> {
  const chatRepo: ChatRepository = new ChatRepository(helper);
  const chat: Chat = createChat({ id: chatId, title: title, createdAt: 1000 });
  await chatRepo.insert(chat);
  return chat;
}

async function insertMessage(
  helper: DbHelper,
  chatId: string,
  message: ChatMessage,
  sequenceNumber: number
): Promise<void> {
  const msgRepo: MessageRepository = new MessageRepository(helper);
  await msgRepo.insert(message, chatId, sequenceNumber);
}

async function insertSwipeData(
  helper: DbHelper,
  assistantMessageId: string,
  chatId: string,
  candidateContents: string[]
): Promise<void> {
  const store: relationalStore.RdbStore = helper.getStore();
  const swipeRepo: MessageSwipeRepository = new MessageSwipeRepository(helper);
  const now: number = 1000;
  const group: MessageSwipeGroup = {
    assistantMessageId: assistantMessageId,
    chatId: chatId,
    activeCandidateIndex: 0,
    createdAt: now,
    updatedAt: now
  };
  await swipeRepo.insertGroupWithStore(store, group);
  for (let i = 0; i < candidateContents.length; i++) {
    const candidate: MessageSwipeCandidate = createSwipeCandidate(
      assistantMessageId, i,
      {
        content: candidateContents[i],
        status: ChatMessageStatus.Completed,
        isStreaming: false,
        createdAt: now
      }
    );
    await swipeRepo.insertCandidateWithStore(store, candidate);
  }
}

async function rowCount(
  store: relationalStore.RdbStore, table: string
): Promise<number> {
  const rs: relationalStore.ResultSet = await store.querySql(
    `SELECT COUNT(*) AS cnt FROM ${table}`
  );
  try {
    if (rs.goToFirstRow()) {
      const ci: number = rs.getColumnIndex('cnt');
      if (ci >= 0) {
        return rs.getLong(ci);
      }
    }
    return 0;
  } finally {
    try {
      rs.close();
    } catch (e) {
      /* ignore */
    }
  }
}

export default function conversationBranchPersistenceServiceDeviceTest(): void {
  describe('ConversationBranchPersistenceServiceTest', () => {

    // ===== 1. ensureRootBranch 幂等 =====

    it('ensure_root_branch_idempotent', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        const first: ConversationBranch = await service.ensureRootBranch(chatId);
        const second: ConversationBranch = await service.ensureRootBranch(chatId);
        expect(second.id).assertEqual(first.id);
        expect(second.chatId).assertEqual(chatId);
        expect(second.isRoot).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. 新 Chat Root 创建 =====

    it('new_chat_root_created', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        const root: ConversationBranch = await service.ensureRootBranch(chatId);
        expect(root.chatId).assertEqual(chatId);
        expect(root.isRoot).assertTrue();
        expect(root.parentBranchId === undefined).assertTrue();
        expect(root.forkMessageId === undefined).assertTrue();
        expect(root.id.length > 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. Active Branch 查询 =====

    it('active_branch_query', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        const root: ConversationBranch = await service.ensureRootBranch(chatId);
        const active: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(active !== null).assertTrue();
        expect(active!.id).assertEqual(root.id);
        expect(active!.isRoot).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. append Message 到 Active Branch =====

    it('append_message_to_active_branch', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const msgId: string = uniqueId('msg');
        const message: ChatMessage = makeMessage(msgId, ChatRole.User, 'hello');
        await insertMessage(helper, chatId, message, 1);
        await service.appendMessageToActiveBranch(chatId, msgId);
        const messages: ChatMessage[] = await service.loadActiveBranchMessages(chatId);
        expect(messages.length).assertEqual(1);
        expect(messages[0].id).assertEqual(msgId);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. position 自动连续(0,1,2) =====

    it('position_auto_increment', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const msgId1: string = uniqueId('msg');
        const msgId2: string = uniqueId('msg');
        const msgId3: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(msgId1, ChatRole.User, 'u1'), 1);
        await insertMessage(helper, chatId, makeMessage(msgId2, ChatRole.Assistant, 'a1'), 2);
        await insertMessage(helper, chatId, makeMessage(msgId3, ChatRole.User, 'u2'), 3);
        await service.appendMessageToActiveBranch(chatId, msgId1);
        await service.appendMessageToActiveBranch(chatId, msgId2);
        await service.appendMessageToActiveBranch(chatId, msgId3);
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const active: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(active !== null).assertTrue();
        const links: BranchMessageLink[] = await branchRepo.listMessageLinks(active!.id);
        expect(links.length).assertEqual(3);
        expect(links[0].position).assertEqual(0);
        expect(links[1].position).assertEqual(1);
        expect(links[2].position).assertEqual(2);
        expect(links[0].messageId).assertEqual(msgId1);
        expect(links[1].messageId).assertEqual(msgId2);
        expect(links[2].messageId).assertEqual(msgId3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. fork User Message =====

    it('fork_at_user_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userMsg1Id: string = uniqueId('msg');
        const assistantMsg1Id: string = uniqueId('msg');
        const userMsg2Id: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userMsg1Id, ChatRole.User, 'u1'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantMsg1Id, ChatRole.Assistant, 'a1'), 2);
        await insertMessage(helper, chatId, makeMessage(userMsg2Id, ChatRole.User, 'u2'), 3);
        await service.appendMessageToActiveBranch(chatId, userMsg1Id);
        await service.appendMessageToActiveBranch(chatId, assistantMsg1Id);
        await service.appendMessageToActiveBranch(chatId, userMsg2Id);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        const child: ConversationBranch = await service.forkAtMessage(chatId, root!.id, userMsg2Id);
        expect(child.isRoot).assertFalse();
        expect(child.parentBranchId).assertEqual(root!.id);
        expect(child.forkMessageId).assertEqual(userMsg2Id);
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const childLinks: BranchMessageLink[] = await branchRepo.listMessageLinks(child.id);
        expect(childLinks.length).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. fork Assistant Message =====

    it('fork_at_assistant_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userMsg1Id: string = uniqueId('msg');
        const assistantMsg1Id: string = uniqueId('msg');
        const userMsg2Id: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userMsg1Id, ChatRole.User, 'u1'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantMsg1Id, ChatRole.Assistant, 'a1'), 2);
        await insertMessage(helper, chatId, makeMessage(userMsg2Id, ChatRole.User, 'u2'), 3);
        await service.appendMessageToActiveBranch(chatId, userMsg1Id);
        await service.appendMessageToActiveBranch(chatId, assistantMsg1Id);
        await service.appendMessageToActiveBranch(chatId, userMsg2Id);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        const child: ConversationBranch = await service.forkAtMessage(chatId, root!.id, assistantMsg1Id);
        expect(child.forkMessageId).assertEqual(assistantMsg1Id);
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const childLinks: BranchMessageLink[] = await branchRepo.listMessageLinks(child.id);
        expect(childLinks.length).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 8. 复制前缀 Links(0..forkPosition) =====

    it('fork_copies_prefix_links', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const msgIds: string[] = [];
        for (let i = 0; i < 4; i++) {
          const mid: string = uniqueId('msg');
          msgIds.push(mid);
          const role: ChatRole = i % 2 === 0 ? ChatRole.User : ChatRole.Assistant;
          await insertMessage(helper, chatId, makeMessage(mid, role, `m${i}`), i + 1);
          await service.appendMessageToActiveBranch(chatId, mid);
        }
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        // Fork at position 2 (index 2)
        const child: ConversationBranch = await service.forkAtMessage(chatId, root!.id, msgIds[2]);
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const childLinks: BranchMessageLink[] = await branchRepo.listMessageLinks(child.id);
        expect(childLinks.length).assertEqual(3);
        expect(childLinks[0].position).assertEqual(0);
        expect(childLinks[1].position).assertEqual(1);
        expect(childLinks[2].position).assertEqual(2);
        expect(childLinks[0].messageId).assertEqual(msgIds[0]);
        expect(childLinks[1].messageId).assertEqual(msgIds[1]);
        expect(childLinks[2].messageId).assertEqual(msgIds[2]);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 9. 不复制后续 Links =====

    it('fork_does_not_copy_subsequent_links', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const msgIds: string[] = [];
        for (let i = 0; i < 4; i++) {
          const mid: string = uniqueId('msg');
          msgIds.push(mid);
          const role: ChatRole = i % 2 === 0 ? ChatRole.User : ChatRole.Assistant;
          await insertMessage(helper, chatId, makeMessage(mid, role, `m${i}`), i + 1);
          await service.appendMessageToActiveBranch(chatId, mid);
        }
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        // Fork at position 1
        const child: ConversationBranch = await service.forkAtMessage(chatId, root!.id, msgIds[1]);
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const childLinks: BranchMessageLink[] = await branchRepo.listMessageLinks(child.id);
        // Should only have positions 0 and 1, not 2 and 3
        expect(childLinks.length).assertEqual(2);
        for (let i = 0; i < childLinks.length; i++) {
          expect(childLinks[i].position <= 1).assertTrue();
          expect(childLinks[i].messageId !== msgIds[2]).assertTrue();
          expect(childLinks[i].messageId !== msgIds[3]).assertTrue();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 10. 原 Branch 保留全部 Links =====

    it('source_branch_keeps_all_links', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const msgIds: string[] = [];
        for (let i = 0; i < 4; i++) {
          const mid: string = uniqueId('msg');
          msgIds.push(mid);
          const role: ChatRole = i % 2 === 0 ? ChatRole.User : ChatRole.Assistant;
          await insertMessage(helper, chatId, makeMessage(mid, role, `m${i}`), i + 1);
          await service.appendMessageToActiveBranch(chatId, mid);
        }
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        const rootId: string = root!.id;
        await service.forkAtMessage(chatId, rootId, msgIds[1]);
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const rootLinks: BranchMessageLink[] = await branchRepo.listMessageLinks(rootId);
        expect(rootLinks.length).assertEqual(4);
        for (let i = 0; i < rootLinks.length; i++) {
          expect(rootLinks[i].position).assertEqual(i);
          expect(rootLinks[i].messageId).assertEqual(msgIds[i]);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 11. 不复制 Message 实体 =====

    it('fork_does_not_copy_message_entities', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const msgIds: string[] = [];
        for (let i = 0; i < 3; i++) {
          const mid: string = uniqueId('msg');
          msgIds.push(mid);
          const role: ChatRole = i % 2 === 0 ? ChatRole.User : ChatRole.Assistant;
          await insertMessage(helper, chatId, makeMessage(mid, role, `m${i}`), i + 1);
          await service.appendMessageToActiveBranch(chatId, mid);
        }
        const store: relationalStore.RdbStore = helper.getStore();
        const beforeCount: number = await rowCount(store, TABLE_MESSAGES);
        expect(beforeCount).assertEqual(3);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        await service.forkAtMessage(chatId, root!.id, msgIds[1]);
        const afterCount: number = await rowCount(store, TABLE_MESSAGES);
        expect(afterCount).assertEqual(beforeCount);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 12. 复制 SwipeSelections =====

    it('fork_copies_swipe_selections', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        // 创建 Swipe 数据
        await insertSwipeData(helper, assistantId, chatId, ['c0', 'c1']);
        // 设置活动 Branch 的 SwipeSelection 为 candidate 1
        await service.updateActiveBranchSwipeSelection(chatId, assistantId, 1);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        // Fork at assistant message
        const child: ConversationBranch = await service.forkAtMessage(chatId, root!.id, assistantId);
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const childSelection: BranchSwipeSelection | null =
          await branchRepo.getSwipeSelection(child.id, assistantId);
        expect(childSelection !== null).assertTrue();
        expect(childSelection!.candidateIndex).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 13. 指定 Candidate 覆盖选择 =====

    it('fork_overrides_candidate_selection', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        // 创建 Swipe 数据(candidate 0 和 1)
        await insertSwipeData(helper, assistantId, chatId, ['c0', 'c1']);
        // 设置活动 Branch 的 SwipeSelection 为 candidate 0
        await service.updateActiveBranchSwipeSelection(chatId, assistantId, 0);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        // Fork with selectedCandidateIndex=1(覆盖为 1)
        const child: ConversationBranch =
          await service.forkAtMessage(chatId, root!.id, assistantId, 1);
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const childSelection: BranchSwipeSelection | null =
          await branchRepo.getSwipeSelection(child.id, assistantId);
        expect(childSelection !== null).assertTrue();
        expect(childSelection!.candidateIndex).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 14. 不存在 Candidate 拒绝 =====

    it('fork_rejects_nonexistent_candidate', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        // 只创建 candidate 0
        await insertSwipeData(helper, assistantId, chatId, ['c0']);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        // Fork with selectedCandidateIndex=99(不存在)
        let threw: boolean = false;
        let errorType: number = -1;
        try {
          await service.forkAtMessage(chatId, root!.id, assistantId, 99);
        } catch (e) {
          threw = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType === DatabaseErrorType.InvalidData ||
               errorType === DatabaseErrorType.NotFound).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 15. Message 不属于来源 Branch 拒绝 =====

    it('fork_rejects_message_not_in_source_branch', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        // 注意:assistantId 未加入 Branch
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        // Fork at assistantId(不在 sourceBranch 中)
        let threw: boolean = false;
        let errorType: number = -1;
        try {
          await service.forkAtMessage(chatId, root!.id, assistantId);
        } catch (e) {
          threw = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType === DatabaseErrorType.NotFound).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 16. 不同 Chat Branch 拒绝 =====

    it('fork_rejects_branch_from_different_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId1: string = uniqueId('chat');
        const chatId2: string = uniqueId('chat');
        await createChatInDb(helper, chatId1, 'Chat1');
        await createChatInDb(helper, chatId2, 'Chat2');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId1);
        await service.ensureRootBranch(chatId2);
        const msgId: string = uniqueId('msg');
        await insertMessage(helper, chatId1, makeMessage(msgId, ChatRole.User, 'u'), 1);
        await service.appendMessageToActiveBranch(chatId1, msgId);
        const root2: ConversationBranch | null = await service.getActiveBranch(chatId2);
        expect(root2 !== null).assertTrue();
        // 使用 chatId1 但 sourceBranchId 属于 chatId2
        let threw: boolean = false;
        let errorType: number = -1;
        try {
          await service.forkAtMessage(chatId1, root2!.id, msgId);
        } catch (e) {
          threw = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType === DatabaseErrorType.InvalidData).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 17. Child 自动成为 Active =====

    it('child_becomes_active', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        const child: ConversationBranch = await service.forkAtMessage(chatId, root!.id, assistantId);
        const active: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(active !== null).assertTrue();
        expect(active!.id).assertEqual(child.id);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 18. Root 保持存在 =====

    it('root_branch_persists_after_fork', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        const root: ConversationBranch = await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        await service.forkAtMessage(chatId, root.id, assistantId);
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const rootBranch: ConversationBranch | null = await branchRepo.getRootBranch(chatId);
        expect(rootBranch !== null).assertTrue();
        expect(rootBranch!.id).assertEqual(root.id);
        expect(rootBranch!.isRoot).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 19. loadActiveBranchMessages 顺序正确 =====

    it('load_active_branch_messages_order', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const msgIds: string[] = [];
        for (let i = 0; i < 3; i++) {
          const mid: string = uniqueId('msg');
          msgIds.push(mid);
          const role: ChatRole = i % 2 === 0 ? ChatRole.User : ChatRole.Assistant;
          await insertMessage(helper, chatId, makeMessage(mid, role, `m${i}`), i + 1);
          await service.appendMessageToActiveBranch(chatId, mid);
        }
        const messages: ChatMessage[] = await service.loadActiveBranchMessages(chatId);
        expect(messages.length).assertEqual(3);
        expect(messages[0].id).assertEqual(msgIds[0]);
        expect(messages[1].id).assertEqual(msgIds[1]);
        expect(messages[2].id).assertEqual(msgIds[2]);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 20. Branch Candidate 投影正确 =====

    it('branch_candidate_projection', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        const originalContent: string = 'original-assistant-content';
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, originalContent), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        // 创建 Swipe 数据
        const candidate1Content: string = 'candidate-1-content';
        await insertSwipeData(helper, assistantId, chatId, ['c0', candidate1Content]);
        // 设置 SwipeSelection 为 candidate 1
        await service.updateActiveBranchSwipeSelection(chatId, assistantId, 1);
        const messages: ChatMessage[] = await service.loadActiveBranchMessages(chatId);
        expect(messages.length).assertEqual(2);
        expect(messages[1].id).assertEqual(assistantId);
        // 投影后 content 应为 candidate 1 的内容
        expect(messages[1].content).assertEqual(candidate1Content);
        expect(messages[1].content !== originalContent).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 21. 原 Branch Candidate 选择不变 =====

    it('source_branch_candidate_selection_unchanged', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        await insertSwipeData(helper, assistantId, chatId, ['c0', 'c1']);
        // 设置 root 的 SwipeSelection 为 candidate 0
        await service.updateActiveBranchSwipeSelection(chatId, assistantId, 0);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        const rootId: string = root!.id;
        // Fork with selectedCandidateIndex=1(覆盖子 Branch)
        await service.forkAtMessage(chatId, rootId, assistantId, 1);
        // 验证 root 的 SwipeSelection 仍为 0
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const rootSelection: BranchSwipeSelection | null =
          await branchRepo.getSwipeSelection(rootId, assistantId);
        expect(rootSelection !== null).assertTrue();
        expect(rootSelection!.candidateIndex).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 22. currentBranchMessageCount 正确 =====

    it('current_branch_message_count', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const msgIds: string[] = [];
        for (let i = 0; i < 3; i++) {
          const mid: string = uniqueId('msg');
          msgIds.push(mid);
          const role: ChatRole = i % 2 === 0 ? ChatRole.User : ChatRole.Assistant;
          await insertMessage(helper, chatId, makeMessage(mid, role, `m${i}`), i + 1);
          await service.appendMessageToActiveBranch(chatId, mid);
        }
        const counts: ConversationRecordCounts = await service.getRecordCounts(chatId);
        expect(counts.currentBranchMessageCount).assertEqual(3);
        // Fork at position 1, active branch changes to child with 2 messages
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        await service.forkAtMessage(chatId, root!.id, msgIds[1]);
        const countsAfterFork: ConversationRecordCounts = await service.getRecordCounts(chatId);
        expect(countsAfterFork.currentBranchMessageCount).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 23. totalUniqueMessageCount 正确 =====

    it('total_unique_message_count', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const msgIds: string[] = [];
        for (let i = 0; i < 3; i++) {
          const mid: string = uniqueId('msg');
          msgIds.push(mid);
          const role: ChatRole = i % 2 === 0 ? ChatRole.User : ChatRole.Assistant;
          await insertMessage(helper, chatId, makeMessage(mid, role, `m${i}`), i + 1);
          await service.appendMessageToActiveBranch(chatId, mid);
        }
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        await service.forkAtMessage(chatId, root!.id, msgIds[1]);
        const counts: ConversationRecordCounts = await service.getRecordCounts(chatId);
        // Fork 不复制 Message,唯一 Message 数仍为 3
        expect(counts.totalUniqueMessageCount).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 24. totalBranchCount 正确 =====

    it('total_branch_count', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const countsBefore: ConversationRecordCounts = await service.getRecordCounts(chatId);
        expect(countsBefore.totalBranchCount).assertEqual(1);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        await service.forkAtMessage(chatId, root!.id, assistantId);
        const countsAfter: ConversationRecordCounts = await service.getRecordCounts(chatId);
        expect(countsAfter.totalBranchCount).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 25. Chat 删除清理 =====

    it('chat_delete_cleans_up', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        await service.forkAtMessage(chatId, root!.id, assistantId);
        // 删除该 Chat 的全部 Branch 数据
        await helper.runInTransaction(
          async (store: relationalStore.RdbStore): Promise<void> => {
            await service.removeByChatIdWithStore(store, chatId);
          }
        );
        const store: relationalStore.RdbStore = helper.getStore();
        expect(await rowCount(store, TABLE_CONVERSATION_BRANCHES)).assertEqual(0);
        expect(await rowCount(store, TABLE_CHAT_BRANCH_STATE)).assertEqual(0);
        expect(await rowCount(store, TABLE_CONVERSATION_BRANCH_MESSAGES)).assertEqual(0);
        expect(await rowCount(store, TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS)).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 26. 并发创建 Root 不重复 =====

    it('concurrent_root_creation_no_duplicate', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        const results: PromiseSettledResult<ConversationBranch>[] = await Promise.allSettled([
          service.ensureRootBranch(chatId),
          service.ensureRootBranch(chatId)
        ]);
        const fulfilled: PromiseSettledResult<ConversationBranch>[] =
          results.filter((r: PromiseSettledResult<ConversationBranch>): boolean => r.status === 'fulfilled');
        expect(fulfilled.length >= 1).assertTrue();
        const store: relationalStore.RdbStore = helper.getStore();
        const branchCount: number = await rowCount(store, TABLE_CONVERSATION_BRANCHES);
        expect(branchCount).assertEqual(1);
        const stateCount: number = await rowCount(store, TABLE_CHAT_BRANCH_STATE);
        expect(stateCount).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 27. 事务失败全部回滚 =====

    it('transaction_failure_rolls_back', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, 'u'), 1);
        await insertMessage(helper, chatId, makeMessage(assistantId, ChatRole.Assistant, 'a'), 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        const store: relationalStore.RdbStore = helper.getStore();
        const branchCountBefore: number = await rowCount(store, TABLE_CONVERSATION_BRANCHES);
        expect(branchCountBefore).assertEqual(1);
        // 在事务中执行 fork,然后抛出异常触发回滚
        let threw: boolean = false;
        try {
          await helper.runInTransaction(
            async (s: relationalStore.RdbStore): Promise<void> => {
              await service.forkAtMessageWithStore(s, chatId, root!.id, assistantId);
              throw new Error('simulated failure');
            }
          );
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
        // 验证回滚后 Branch 数量未增加
        const branchCountAfter: number = await rowCount(store, TABLE_CONVERSATION_BRANCHES);
        expect(branchCountAfter).assertEqual(branchCountBefore);
        // 验证 Message Links 未增加
        const linkCount: number = await rowCount(store, TABLE_CONVERSATION_BRANCH_MESSAGES);
        expect(linkCount).assertEqual(2);
        // 验证 Active Branch 仍为 root
        const active: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(active !== null).assertTrue();
        expect(active!.id).assertEqual(root!.id);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 28. 输入对象不修改 =====

    it('input_objects_not_modified', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        const root: ConversationBranch = await service.ensureRootBranch(chatId);
        const rootSnapshot: string = JSON.stringify(root);
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        const userMsg: ChatMessage = makeMessage(userId, ChatRole.User, 'u');
        const assistantMsg: ChatMessage = makeMessage(assistantId, ChatRole.Assistant, 'a');
        const userMsgSnapshot: string = JSON.stringify(userMsg);
        const assistantMsgSnapshot: string = JSON.stringify(assistantMsg);
        await insertMessage(helper, chatId, userMsg, 1);
        await insertMessage(helper, chatId, assistantMsg, 2);
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        await service.forkAtMessage(chatId, root.id, assistantId);
        // 验证 root 对象未被修改
        expect(JSON.stringify(root)).assertEqual(rootSnapshot);
        // 验证原始 Message 对象未被修改
        expect(JSON.stringify(userMsg)).assertEqual(userMsgSnapshot);
        expect(JSON.stringify(assistantMsg)).assertEqual(assistantMsgSnapshot);
        // 验证再次加载的 root 仍一致
        const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
        const rootReloaded: ConversationBranch | null = await branchRepo.getBranch(root.id);
        expect(rootReloaded !== null).assertTrue();
        expect(rootReloaded!.id).assertEqual(root.id);
        expect(rootReloaded!.chatId).assertEqual(root.chatId);
        expect(rootReloaded!.isRoot).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 29. 日志不含正文 =====

    it('log_does_not_contain_content', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatId: string = uniqueId('chat');
        await createChatInDb(helper, chatId, 'Test');
        const service: ConversationBranchPersistenceService = setupService(helper);
        await service.ensureRootBranch(chatId);
        const sensitiveContent: string = 'SuperSecretMessageContent!@#$%';
        const userId: string = uniqueId('msg');
        const assistantId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(userId, ChatRole.User, sensitiveContent), 1);
        await insertMessage(
          helper, chatId,
          makeMessage(assistantId, ChatRole.Assistant, sensitiveContent),
          2
        );
        await service.appendMessageToActiveBranch(chatId, userId);
        await service.appendMessageToActiveBranch(chatId, assistantId);
        const root: ConversationBranch | null = await service.getActiveBranch(chatId);
        expect(root !== null).assertTrue();
        // 触发各种错误并验证错误消息不含敏感正文
        const errorMessages: string[] = [];

        // 1. Fork 不存在的 Candidate
        await insertSwipeData(helper, assistantId, chatId, ['c0']);
        try {
          await service.forkAtMessage(chatId, root!.id, assistantId, 99);
        } catch (e) {
          if (e instanceof DatabaseError) {
            errorMessages.push(e.message + ' ' + e.causeMessage);
          } else if (e instanceof Error) {
            errorMessages.push(e.message);
          }
        }

        // 2. Fork 不在 Branch 中的 Message
        const orphanMsgId: string = uniqueId('msg');
        await insertMessage(helper, chatId, makeMessage(orphanMsgId, ChatRole.User, 'orphan'), 3);
        try {
          await service.forkAtMessage(chatId, root!.id, orphanMsgId);
        } catch (e) {
          if (e instanceof DatabaseError) {
            errorMessages.push(e.message + ' ' + e.causeMessage);
          } else if (e instanceof Error) {
            errorMessages.push(e.message);
          }
        }

        // 3. 不同 Chat 的 Branch
        const otherChatId: string = uniqueId('chat');
        await createChatInDb(helper, otherChatId, 'Other');
        await service.ensureRootBranch(otherChatId);
        const otherRoot: ConversationBranch | null = await service.getActiveBranch(otherChatId);
        expect(otherRoot !== null).assertTrue();
        try {
          await service.forkAtMessage(chatId, otherRoot!.id, userId);
        } catch (e) {
          if (e instanceof DatabaseError) {
            errorMessages.push(e.message + ' ' + e.causeMessage);
          } else if (e instanceof Error) {
            errorMessages.push(e.message);
          }
        }

        // 验证所有错误消息不含敏感正文
        expect(errorMessages.length >= 3).assertTrue();
        for (let i = 0; i < errorMessages.length; i++) {
          expect(errorMessages[i].indexOf(sensitiveContent) < 0).assertTrue();
          expect(errorMessages[i].indexOf('SQL') < 0).assertTrue();
          expect(errorMessages[i].indexOf('INSERT') < 0).assertTrue();
          expect(errorMessages[i].indexOf('SELECT') < 0).assertTrue();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
