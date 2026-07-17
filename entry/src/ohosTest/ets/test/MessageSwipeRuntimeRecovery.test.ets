/**
 * MessageSwipeRuntimeRecovery 设备测试(10 项)
 *
 * 覆盖 normalizeInterruptedCandidates 的运行时恢复行为:
 *
 * 1. Group activeIndex 恢复
 * 2. CandidateCount 恢复
 * 3. messages 内容等于 active Candidate
 * 4. Streaming active Candidate 恢复为 Cancelled
 * 5. Candidate 和 Message 同时变为 Cancelled
 * 6. 部分 content 保留
 * 7. 非 active Streaming Candidate 不物化到 Message
 * 8. Completed Candidate 不修改
 * 9. 切换后重启保持选择
 * 10. Chat 删除后无 Swipe 残留
 *
 * 使用独立测试数据库 arktavern_swipe_recovery_test.db
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import { MessageRepository } from '../../../main/ets/repositories/MessageRepository';
import { MessageSwipeRepository } from '../../../main/ets/repositories/MessageSwipeRepository';
import { MessageSwipePersistenceService } from '../../../main/ets/services/MessageSwipePersistenceService';
import { ChatPersistenceService } from '../../../main/ets/services/ChatPersistenceService';
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../../main/ets/models/ChatMessageSource';
import { Chat, createChat } from '../../../main/ets/models/Chat';
import {
  MessageSwipeCandidate,
  MessageSwipeState,
  MessageSwipeSummary,
  CreateSwipeCandidateOptions
} from '../../../main/ets/models/MessageSwipe';
import {
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_MESSAGE_SWIPE_CANDIDATES,
  TABLE_MESSAGES,
  TABLE_CHATS
} from '../../../main/ets/database/DatabaseConstants';
import { nowMillis } from '../../../main/ets/utils/Time';
import { generateUuid } from '../../../main/ets/utils/Uuid';

const TEST_DB_NAME: string = 'arktavern_swipe_recovery_test.db';
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

async function deleteTestDbIfExists(ctx: common.Context): Promise<void> {
  try {
    const config: relationalStore.StoreConfig = {
      name: TEST_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore =
      await relationalStore.getRdbStore(ctx, config);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGE_SWIPE_CANDIDATES);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGE_SWIPE_GROUPS);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGES);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHATS);
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

function setupService(helper: DbHelper): MessageSwipePersistenceService {
  const msgRepo: MessageRepository = new MessageRepository(helper);
  const swipeRepo: MessageSwipeRepository = new MessageSwipeRepository(helper);
  return new MessageSwipePersistenceService(helper, msgRepo, swipeRepo);
}

/**
 * 创建 Chat 并插入一条 Assistant 消息的结果。
 */
interface ChatAndMessageResult {
  readonly chatId: string;
  readonly messageId: string;
}

/**
 * 创建 Chat 并插入一条 Assistant 消息,返回 chatId 和 messageId。
 */
async function createChatAndAssistantMessage(
  helper: DbHelper,
  msgId: string,
  content: string,
  status?: ChatMessageStatus,
  source?: ChatMessageSource
): Promise<ChatAndMessageResult> {
  const chatRepo: ChatRepository = new ChatRepository(helper);
  const msgRepo: MessageRepository = new MessageRepository(helper);
  const chatId: string = uniqueId('chat');
  const chat: Chat = createChat({ id: chatId, title: 'Recovery Test Chat', createdAt: 1000 });
  await chatRepo.insert(chat);
  const message: ChatMessage = makeMessage(msgId, ChatRole.Assistant, content, status, source);
  await msgRepo.insert(message, chatId, 1);
  const result: ChatAndMessageResult = { chatId: chatId, messageId: msgId };
  return result;
}

/**
 * 查询表行数。
 */
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
    try {
      rs.close();
    } catch (e) {
      /* ignore */
    }
  }
}

export default function messageSwipeRuntimeRecoveryTest(): void {
  describe('MessageSwipeRuntimeRecoveryTest', () => {

    // ===== 1. Group activeIndex 恢复 =====

    it('active_index_preserved_after_normalize', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original content'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        // 创建 Group + Candidate 0
        const initial: MessageSwipeState = await service.ensureSwipeState(messageId);
        expect(initial.group.activeCandidateIndex).assertEqual(0);
        // 追加一个候选并激活,把 activeIndex 变为 1
        const opts: CreateSwipeCandidateOptions = {
          content: 'candidate 1 content',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, true);
        // 验证 activeIndex 已变为 1
        const before: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(before !== null).assertTrue();
        expect(before!.group.activeCandidateIndex).assertEqual(1);
        // 执行 normalizeInterruptedCandidates(无 Streaming,不应修改任何内容)
        const handled: number = await service.normalizeInterruptedCandidates(chatId);
        expect(handled).assertEqual(0);
        // activeIndex 应保持不变
        const after: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(after !== null).assertTrue();
        expect(after!.group.activeCandidateIndex).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. CandidateCount 恢复 =====

    it('candidate_count_preserved_after_normalize', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加 3 个候选(共 4 个: index 0 + 1 + 2 + 3)
        for (let i = 1; i <= 3; i++) {
          await service.appendCandidate(messageId, {
            content: 'candidate ' + i.toString(),
            status: ChatMessageStatus.Completed,
            isStreaming: false
          }, false);
        }
        const before: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(before !== null).assertTrue();
        expect(before!.candidates.length).assertEqual(4);
        // normalize 不应删除任何候选
        const handled: number = await service.normalizeInterruptedCandidates(chatId);
        expect(handled).assertEqual(0);
        const after: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(after !== null).assertTrue();
        expect(after!.candidates.length).assertEqual(4);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. messages 内容等于 active Candidate =====

    it('message_content_equals_active_candidate_after_normalize', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original content'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加一个候选并激活
        const activeContent: string = 'I am the active candidate';
        await service.appendCandidate(messageId, {
          content: activeContent,
          status: ChatMessageStatus.Completed,
          isStreaming: false
        }, true);
        // normalize(无 Streaming)
        await service.normalizeInterruptedCandidates(chatId);
        // messages 表内容应等于 active Candidate
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(activeContent);
        // 验证 active Candidate 索引为 1(content 为 activeContent)
        const state: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(state !== null).assertTrue();
        const activeCand: MessageSwipeCandidate | undefined = state!.candidates.find(
          (c: MessageSwipeCandidate): boolean =>
            c.candidateIndex === state!.group.activeCandidateIndex
        );
        expect(activeCand !== undefined).assertTrue();
        expect(activeCand!.content).assertEqual(activeContent);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. Streaming active Candidate 恢复为 Cancelled =====

    it('streaming_active_candidate_cancelled_after_normalize', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加一个 Streaming 候选并激活(模拟中断的流)
        const partialContent: string = 'Partial streaming response...';
        await service.appendCandidate(messageId, {
          content: partialContent,
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        }, true);
        // 验证当前是 Streaming
        const before: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(before !== null).assertTrue();
        expect(before!.group.activeCandidateIndex).assertEqual(1);
        const activeBefore: MessageSwipeCandidate | undefined = before!.candidates.find(
          (c: MessageSwipeCandidate): boolean => c.candidateIndex === 1
        );
        expect(activeBefore !== undefined).assertTrue();
        expect(activeBefore!.status).assertEqual(ChatMessageStatus.Streaming);
        // 执行 normalize
        const handled: number = await service.normalizeInterruptedCandidates(chatId);
        expect(handled).assertEqual(1);
        // 验证 Candidate 已变为 Cancelled
        const after: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(after !== null).assertTrue();
        const activeAfter: MessageSwipeCandidate | undefined = after!.candidates.find(
          (c: MessageSwipeCandidate): boolean => c.candidateIndex === 1
        );
        expect(activeAfter !== undefined).assertTrue();
        expect(activeAfter!.status).assertEqual(ChatMessageStatus.Cancelled);
        expect(activeAfter!.isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. Candidate 和 Message 同时变为 Cancelled =====

    it('candidate_and_message_both_cancelled_after_normalize', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加 Streaming 候选并激活
        const partialContent: string = 'Partial content that should be preserved';
        await service.appendCandidate(messageId, {
          content: partialContent,
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        }, true);
        // 执行 normalize
        await service.normalizeInterruptedCandidates(chatId);
        // Candidate 应变为 Cancelled
        const state: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(state !== null).assertTrue();
        const cancelledCandidate: MessageSwipeCandidate | undefined = state!.candidates.find(
          (c: MessageSwipeCandidate): boolean => c.candidateIndex === 1
        );
        expect(cancelledCandidate !== undefined).assertTrue();
        expect(cancelledCandidate!.status).assertEqual(ChatMessageStatus.Cancelled);
        expect(cancelledCandidate!.isStreaming).assertFalse();
        // messages 表也应变为 Cancelled
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.status).assertEqual(ChatMessageStatus.Cancelled);
        expect(reloaded!.isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. 部分 content 保留 =====

    it('partial_content_preserved_after_normalize', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加 Streaming 候选并激活,模拟已收到部分内容
        const partialContent: string = 'This is a partial streaming response that was interrupted';
        await service.appendCandidate(messageId, {
          content: partialContent,
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        }, true);
        // 执行 normalize
        await service.normalizeInterruptedCandidates(chatId);
        // 部分内容应保留在 Candidate 中
        const state: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(state !== null).assertTrue();
        const cancelledCandidate: MessageSwipeCandidate | undefined = state!.candidates.find(
          (c: MessageSwipeCandidate): boolean => c.candidateIndex === 1
        );
        expect(cancelledCandidate !== undefined).assertTrue();
        expect(cancelledCandidate!.content).assertEqual(partialContent);
        // 部分内容也应保留在 messages 表中
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(partialContent);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. 非 active Streaming Candidate 不物化到 Message =====

    it('inactive_streaming_candidate_not_materialized', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const originalContent: string = 'original active content';
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), originalContent
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加一个非活跃的 Streaming 候选(不激活)
        const streamingContent: string = 'streaming content that should not appear in message';
        await service.appendCandidate(messageId, {
          content: streamingContent,
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        }, false);
        // 验证 Candidate 1 存在且为 Streaming
        const before: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(before !== null).assertTrue();
        expect(before!.group.activeCandidateIndex).assertEqual(0); // 仍为 index 0
        const inactiveCandidate: MessageSwipeCandidate | undefined = before!.candidates.find(
          (c: MessageSwipeCandidate): boolean => c.candidateIndex === 1
        );
        expect(inactiveCandidate !== undefined).assertTrue();
        expect(inactiveCandidate!.status).assertEqual(ChatMessageStatus.Streaming);
        // 执行 normalize
        const handled: number = await service.normalizeInterruptedCandidates(chatId);
        // normalize 只检查 active Candidate(即 index 0),index 0 为 Completed,所以不应处理
        expect(handled).assertEqual(0);
        // messages 表内容应仍为原始内容(未物化 Streaming 候选)
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(originalContent);
        // 非 active Streaming Candidate 应保持 Streaming 不变
        const after: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(after !== null).assertTrue();
        const inactiveAfter: MessageSwipeCandidate | undefined = after!.candidates.find(
          (c: MessageSwipeCandidate): boolean => c.candidateIndex === 1
        );
        expect(inactiveAfter !== undefined).assertTrue();
        expect(inactiveAfter!.status).assertEqual(ChatMessageStatus.Streaming);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 8. Completed Candidate 不修改 =====

    it('completed_candidate_not_modified_by_normalize', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const completedContent: string = 'This is a completed response';
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), completedContent
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加一个 Completed 候选
        await service.appendCandidate(messageId, {
          content: 'another completed candidate',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        }, false);
        // 执行 normalize(无 Streaming,不应修改任何内容)
        const handled: number = await service.normalizeInterruptedCandidates(chatId);
        expect(handled).assertEqual(0);
        // 所有 Candidate 应保持 Completed
        const state: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(state !== null).assertTrue();
        for (let i = 0; i < state!.candidates.length; i++) {
          const c: MessageSwipeCandidate = state!.candidates[i];
          expect(c.status).assertEqual(ChatMessageStatus.Completed);
          expect(c.isStreaming).assertFalse();
        }
        // messages 表内容应不变
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(completedContent);
        expect(reloaded!.status).assertEqual(ChatMessageStatus.Completed);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 9. 切换后重启保持选择 =====

    it('candidate_selection_preserved_after_reload', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const originalContent: string = 'original candidate';
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), originalContent
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加一个候选(不激活)
        const switchedContent: string = 'switched candidate content';
        await service.appendCandidate(messageId, {
          content: switchedContent,
          status: ChatMessageStatus.Completed,
          isStreaming: false
        }, false);
        // 切换到 Candidate 1
        await service.activateCandidate(messageId, 1);
        // 模拟"重启"——重新查询 Swipe 状态
        const afterSwitch: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(afterSwitch !== null).assertTrue();
        // 选择应保持为 Candidate 1
        expect(afterSwitch!.group.activeCandidateIndex).assertEqual(1);
        // messages 表应反映 Candidate 1 的内容
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(switchedContent);
        // 再执行 normalize(无 Streaming),选择应不受影响
        const handled: number = await service.normalizeInterruptedCandidates(chatId);
        expect(handled).assertEqual(0);
        const afterNormalize: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(afterNormalize !== null).assertTrue();
        expect(afterNormalize!.group.activeCandidateIndex).assertEqual(1);
        const reloadedAfter: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloadedAfter !== null).assertTrue();
        expect(reloadedAfter!.content).assertEqual(switchedContent);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 10. Chat 删除后无 Swipe 残留 =====

    it('no_swipe_data_after_chat_deletion', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const msgId: string = uniqueId('msg');
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, msgId, 'original'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加一个候选
        await service.appendCandidate(messageId, {
          content: 'another candidate',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        }, false);
        // 验证 Swipe 数据存在
        const before: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(before !== null).assertTrue();
        // 删除 Chat 及其所有关联数据
        const chatRepo: ChatRepository = new ChatRepository(helper);
        await chatRepo.remove(chatId);
        // 删除 Chat 后手动清理 Swipe 数据
        await service.removeByChatId(chatId);
        // 验证 Swipe 数据已清除
        const after: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(after === null).assertTrue();
        // 验证 Swipe 表数据也为空
        const store: relationalStore.RdbStore = helper.getStore();
        const groupCount: number = await rowCount(store, TABLE_MESSAGE_SWIPE_GROUPS);
        expect(groupCount).assertEqual(0);
        const candidateCount: number = await rowCount(store, TABLE_MESSAGE_SWIPE_CANDIDATES);
        expect(candidateCount).assertEqual(0);
        // messages 表应不受影响(消息本身保留)
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const msg: ChatMessage | null = await msgRepo.getById(messageId);
        expect(msg !== null).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}