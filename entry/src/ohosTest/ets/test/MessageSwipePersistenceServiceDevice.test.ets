/**
 * MessageSwipePersistenceService 设备测试(33 项)
 *
 * 覆盖 ensureSwipeState / appendCandidate / updateCandidate / activateCandidate /
 * removeSwipeState / removeByChatId 的完整行为:
 *
 * 1. 旧 Assistant ensure 创建 Group
 * 2. Candidate 0 等于当前 Message
 * 3. ensure 重复调用幂等
 * 4. User 消息拒绝
 * 5. CharacterFirstMessage 拒绝
 * 6. ExternalSystem 拒绝
 * 7. PromptPresetSystem 拒绝
 * 8. append 自动使用下一个 index
 * 9. append inactive 不修改 Message
 * 10. append active 更新 Message
 * 11. update inactive 不修改 Message
 * 12. update active 同步 Message
 * 13. activate Candidate 0
 * 14. activate Candidate 1
 * 15. activate 不存在候选失败
 * 16. 切换后 MessageRepository 立即返回目标内容
 * 17. 激活 Streaming Candidate
 * 18. Streaming→Completed 同步
 * 19. Streaming→Cancelled 同步
 * 20. Streaming→Failed 同步
 * 21. Message ID 不变
 * 22. sequenceNumber 不变
 * 23. role/source 不变
 * 24. messages 行数不增加
 * 25. 达到 8 个候选
 * 26. 第 9 个拒绝
 * 27. 并发 ensure 不重复
 * 28. 并发 append 不产生重复索引
 * 29. Chat 删除同步删除所有 Swipe
 * 30. Chat 删除失败全部回滚
 * 31. 其他 Chat Swipe 不受影响
 * 32. 输入对象不修改
 * 33. 日志不含候选内容
 *
 * 使用独立测试数据库 arktavern_swipe_persistence_test.db
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import { MessageRepository, MessageInsertRecord } from '../../../main/ets/repositories/MessageRepository';
import { MessageSwipeRepository } from '../../../main/ets/repositories/MessageSwipeRepository';
import { MessageSwipePersistenceService } from '../../../main/ets/services/MessageSwipePersistenceService';
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../../main/ets/models/ChatMessageSource';
import { Chat, createChat } from '../../../main/ets/models/Chat';
import { DatabaseError, DatabaseErrorType } from '../../../main/ets/models/DatabaseError';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate,
  MessageSwipeState,
  CreateSwipeCandidateOptions,
  MessageSwipeCandidateUpdates,
  MAX_SWIPE_CANDIDATES,
  createSwipeCandidate,
  isValidCandidateIndex
} from '../../../main/ets/models/MessageSwipe';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_MESSAGE_SWIPE_CANDIDATES,
  COLUMN_ID,
  COLUMN_CHAT_ID,
  COLUMN_ROLE,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_ERROR_MESSAGE,
  COLUMN_IS_STREAMING,
  COLUMN_SOURCE,
  COLUMN_SWIPE_ASSISTANT_MESSAGE_ID,
  COLUMN_SWIPE_CANDIDATE_INDEX,
  COLUMN_SWIPE_CANDIDATE_ID
} from '../../../main/ets/database/DatabaseConstants';

const TEST_DB_NAME: string = 'arktavern_swipe_persistence_test.db';
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

function makeStreamingMessage(
  id: string,
  role: ChatRole,
  content: string
): ChatMessage {
  return makeMessage(id, role, content, ChatMessageStatus.Streaming);
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
  const chat: Chat = createChat({ id: chatId, title: 'Test Chat', createdAt: 1000 });
  await chatRepo.insert(chat);
  const message: ChatMessage = makeMessage(msgId, ChatRole.Assistant, content, status, source);
  await msgRepo.insert(message, chatId, 1);
  const result: ChatAndMessageResult = { chatId: chatId, messageId: msgId };
  return result;
}

/**
 * 创建 Chat 并插入一条指定 role 的消息(用于非 Assistant 测试)。
 */
async function createChatAndMessageWithRole(
  helper: DbHelper,
  msgId: string,
  role: ChatRole,
  content: string,
  source?: ChatMessageSource
): Promise<ChatAndMessageResult> {
  const chatRepo: ChatRepository = new ChatRepository(helper);
  const msgRepo: MessageRepository = new MessageRepository(helper);
  const chatId: string = uniqueId('chat');
  const chat: Chat = createChat({ id: chatId, title: 'Test Chat', createdAt: 1000 });
  await chatRepo.insert(chat);
  const message: ChatMessage = makeMessage(msgId, role, content, ChatMessageStatus.Completed, source);
  await msgRepo.insert(message, chatId, 1);
  const result: ChatAndMessageResult = { chatId: chatId, messageId: msgId };
  return result;
}

/**
 * 获取原始 RdbStore。
 */
async function getStore(): Promise<relationalStore.RdbStore> {
  const ctx: common.Context = await getContext();
  const config: relationalStore.StoreConfig = {
    name: TEST_DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  return await relationalStore.getRdbStore(ctx, config);
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

export default function messageSwipePersistenceServiceDeviceTest(): void {
  describe('MessageSwipePersistenceServiceDeviceTest', () => {

    // ===== 1. ensureSwipeState =====

    it('ensure_creates_group_for_old_assistant', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'Hello, world!'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        const state: MessageSwipeState = await service.ensureSwipeState(messageId);
        expect(state.group.assistantMessageId).assertEqual(messageId);
        expect(state.group.chatId).assertEqual(chatId);
        expect(state.group.activeCandidateIndex).assertEqual(0);
        expect(state.candidates.length).assertEqual(1);
        expect(state.candidates[0].candidateIndex).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('candidate_zero_equals_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const content: string = 'Original assistant response';
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), content
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        const state: MessageSwipeState = await service.ensureSwipeState(messageId);
        expect(state.candidates[0].content).assertEqual(content);
        expect(state.candidates[0].status).assertEqual(ChatMessageStatus.Completed);
        expect(state.candidates[0].isStreaming).assertEqual(false);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('ensure_idempotent', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'content'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        const first: MessageSwipeState = await service.ensureSwipeState(messageId);
        const second: MessageSwipeState = await service.ensureSwipeState(messageId);
        expect(second.group.assistantMessageId).assertEqual(first.group.assistantMessageId);
        expect(second.group.activeCandidateIndex).assertEqual(first.group.activeCandidateIndex);
        expect(second.candidates.length).assertEqual(1);
        expect(second.candidates[0].candidateIndex).assertEqual(0);
        // 验证数据库只有一条 group
        const store: relationalStore.RdbStore = helper.getStore();
        const groupCount: number = await rowCount(store, TABLE_MESSAGE_SWIPE_GROUPS);
        expect(groupCount).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('ensure_rejects_user_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndMessageWithRole(
          helper, uniqueId('msg'), ChatRole.User, 'user message'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        let threw: boolean = false;
        let errorType: number = -1;
        try {
          await service.ensureSwipeState(messageId);
        } catch (e) {
          threw = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('ensure_rejects_character_first_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'first message',
          ChatMessageStatus.Completed, ChatMessageSource.CharacterFirstMessage
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        let threw: boolean = false;
        let errorType: number = -1;
        try {
          await service.ensureSwipeState(messageId);
        } catch (e) {
          threw = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('ensure_rejects_external_system', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'external system',
          ChatMessageStatus.Completed, ChatMessageSource.ExternalSystem
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        let threw: boolean = false;
        let errorType: number = -1;
        try {
          await service.ensureSwipeState(messageId);
        } catch (e) {
          threw = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('ensure_rejects_prompt_preset_system', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        // PromptPresetSystem 不可通过 MessageRepository 持久化,直接插入 SQL
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgId: string = uniqueId('msg');
        const chatId: string = uniqueId('chat');
        const chat: Chat = createChat({ id: chatId, title: 'Test', createdAt: 1000 });
        await chatRepo.insert(chat);
        const store: relationalStore.RdbStore = helper.getStore();
        const vb: relationalStore.ValuesBucket = {};
        vb[COLUMN_ID] = msgId;
        vb[COLUMN_CHAT_ID] = chatId;
        vb[COLUMN_ROLE] = 'assistant';
        vb[COLUMN_CONTENT] = 'prompt preset system';
        vb[COLUMN_STATUS] = 'completed';
        vb[COLUMN_CREATED_AT] = 1000;
        vb[COLUMN_UPDATED_AT] = 1000;
        vb[COLUMN_SEQUENCE_NUMBER] = 1;
        vb[COLUMN_IS_STREAMING] = 0;
        vb[COLUMN_SOURCE] = 'promptPresetSystem';
        await store.insert(TABLE_MESSAGES, vb);

        const service: MessageSwipePersistenceService = setupService(helper);
        let threw: boolean = false;
        let errorType: number = -1;
        try {
          await service.ensureSwipeState(msgId);
        } catch (e) {
          threw = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. appendCandidate =====

    it('append_auto_increments_index', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const opts: CreateSwipeCandidateOptions = {
          content: 'candidate 1',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        const state: MessageSwipeState = await service.appendCandidate(messageId, opts, false);
        // 应有 2 个候选: index 0(原始) + index 1(新)
        expect(state.candidates.length).assertEqual(2);
        const indexes: number[] = state.candidates.map(c => c.candidateIndex).sort();
        expect(indexes[0]).assertEqual(0);
        expect(indexes[1]).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('append_inactive_does_not_modify_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const originalContent: string = 'original content';
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), originalContent
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const opts: CreateSwipeCandidateOptions = {
          content: 'new candidate',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, false);
        // 验证 messages 表内容未变
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(originalContent);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('append_active_updates_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const newContent: string = 'active candidate content';
        const opts: CreateSwipeCandidateOptions = {
          content: newContent,
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, true);
        // 验证 messages 表已更新
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(newContent);
        expect(reloaded!.status).assertEqual(ChatMessageStatus.Completed);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. updateCandidate =====

    it('update_inactive_does_not_modify_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const originalContent: string = 'original';
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), originalContent
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加一个候选但不激活
        const opts: CreateSwipeCandidateOptions = {
          content: 'candidate 1',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, false);
        // 更新非活跃候选(index 1)
        const updates: MessageSwipeCandidateUpdates = {
          content: 'updated candidate 1',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        const state: MessageSwipeState = await service.updateCandidate(messageId, 1, updates);
        // 候选内容应更新
        const c1: MessageSwipeCandidate | undefined = state.candidates.find(c => c.candidateIndex === 1);
        expect(c1 !== undefined).assertTrue();
        expect(c1!.content).assertEqual('updated candidate 1');
        // messages 表应不变
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(originalContent);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('update_active_syncs_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 更新活跃候选(index 0)
        const newContent: string = 'updated active content';
        const updates: MessageSwipeCandidateUpdates = {
          content: newContent,
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.updateCandidate(messageId, 0, updates);
        // messages 表应同步更新
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(newContent);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. activateCandidate =====

    it('activate_candidate_zero', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const originalContent: string = 'original';
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), originalContent
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加一个候选
        const opts: CreateSwipeCandidateOptions = {
          content: 'candidate 1',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, true);
        // 切回 Candidate 0
        const state: MessageSwipeState = await service.activateCandidate(messageId, 0);
        expect(state.group.activeCandidateIndex).assertEqual(0);
        // messages 表应恢复原始内容
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(originalContent);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('activate_candidate_one', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const newContent: string = 'candidate 1 content';
        const opts: CreateSwipeCandidateOptions = {
          content: newContent,
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, false);
        // 激活 Candidate 1
        const state: MessageSwipeState = await service.activateCandidate(messageId, 1);
        expect(state.group.activeCandidateIndex).assertEqual(1);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(newContent);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('activate_nonexistent_candidate_fails', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        let threw: boolean = false;
        let errorType: number = -1;
        try {
          await service.activateCandidate(messageId, 99);
        } catch (e) {
          threw = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(threw).assertTrue();
        // 不存在的候选应报告 InvalidData
        expect(errorType === DatabaseErrorType.InvalidData ||
               errorType === DatabaseErrorType.NotFound).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('message_repository_returns_after_activate', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const originalContent: string = 'original';
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), originalContent
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const c1Content: string = 'candidate 1';
        await service.appendCandidate(messageId, { content: c1Content, status: ChatMessageStatus.Completed, isStreaming: false }, false);
        // 激活 Candidate 1
        await service.activateCandidate(messageId, 1);
        // 通过 MessageRepository 立即查询
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const afterActivate: ChatMessage | null = await msgRepo.getById(messageId);
        expect(afterActivate !== null).assertTrue();
        expect(afterActivate!.content).assertEqual(c1Content);
        // 切回 Candidate 0
        await service.activateCandidate(messageId, 0);
        const afterSwitchBack: ChatMessage | null = await msgRepo.getById(messageId);
        expect(afterSwitchBack !== null).assertTrue();
        expect(afterSwitchBack!.content).assertEqual(originalContent);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. Streaming lifecycle =====

    it('activate_streaming_candidate', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const streamingContent: string = 'partial streaming...';
        // 追加 Streaming 候选并激活
        const opts: CreateSwipeCandidateOptions = {
          content: streamingContent,
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        };
        await service.appendCandidate(messageId, opts, true);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual(streamingContent);
        expect(reloaded!.status).assertEqual(ChatMessageStatus.Streaming);
        expect(reloaded!.isStreaming).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('streaming_to_completed_syncs', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加 Streaming 候选并激活
        const opts: CreateSwipeCandidateOptions = {
          content: 'partial',
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        };
        await service.appendCandidate(messageId, opts, true);
        // 更新为 Completed
        const updates: MessageSwipeCandidateUpdates = {
          content: 'final content',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.updateCandidate(messageId, 1, updates);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.content).assertEqual('final content');
        expect(reloaded!.status).assertEqual(ChatMessageStatus.Completed);
        expect(reloaded!.isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('streaming_to_cancelled_syncs', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const opts: CreateSwipeCandidateOptions = {
          content: 'partial',
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        };
        await service.appendCandidate(messageId, opts, true);
        const updates: MessageSwipeCandidateUpdates = {
          content: 'partial',
          status: ChatMessageStatus.Cancelled,
          isStreaming: false
        };
        await service.updateCandidate(messageId, 1, updates);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.status).assertEqual(ChatMessageStatus.Cancelled);
        expect(reloaded!.isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('streaming_to_failed_syncs', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const opts: CreateSwipeCandidateOptions = {
          content: 'partial',
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        };
        await service.appendCandidate(messageId, opts, true);
        const errorMsg: string = 'API timeout';
        const updates: MessageSwipeCandidateUpdates = {
          content: 'partial',
          status: ChatMessageStatus.Failed,
          isStreaming: false,
          errorMessage: errorMsg
        };
        await service.updateCandidate(messageId, 1, updates);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.status).assertEqual(ChatMessageStatus.Failed);
        expect(reloaded!.isStreaming).assertFalse();
        expect(reloaded!.errorMessage).assertEqual(errorMsg);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. Message integrity =====

    it('message_id_unchanged', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const msgId: string = uniqueId('msg');
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(helper, msgId, 'original');
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const opts: CreateSwipeCandidateOptions = {
          content: 'new',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, true);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.id).assertEqual(msgId);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('sequence_number_unchanged', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const msgId: string = uniqueId('msg');
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(helper, msgId, 'original');
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const opts: CreateSwipeCandidateOptions = {
          content: 'new',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, true);
        // 查询原始 sequence_number
        const store: relationalStore.RdbStore = helper.getStore();
        const sql: string =
          `SELECT ${COLUMN_SEQUENCE_NUMBER} FROM ${TABLE_MESSAGES} WHERE ${COLUMN_ID} = ?`;
        const rs = await store.querySql(sql, [messageId]);
        try {
          expect(rs.goToFirstRow()).assertTrue();
          const seq: number = rs.getLong(rs.getColumnIndex(COLUMN_SEQUENCE_NUMBER));
          expect(seq).assertEqual(1);
        } finally {
          rs.close();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('role_source_unchanged', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const msgId: string = uniqueId('msg');
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(helper, msgId, 'original');
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const opts: CreateSwipeCandidateOptions = {
          content: 'new',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, true);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const reloaded: ChatMessage | null = await msgRepo.getById(messageId);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.role).assertEqual(ChatRole.Assistant);
        // source 应为 undefined(原始 message 未设置 source)
        expect(reloaded!.source === undefined).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('messages_row_count_not_increased', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(helper, uniqueId('msg'), 'original');
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        const opts: CreateSwipeCandidateOptions = {
          content: 'new',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, true);
        const store: relationalStore.RdbStore = helper.getStore();
        const count: number = await rowCount(store, TABLE_MESSAGES);
        expect(count).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. Candidate limit =====

    it('max_candidates_reached', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加到 MAX_SWIPE_CANDIDATES - 1 个(已有 index 0,再追加 7 个)
        for (let i = 1; i < MAX_SWIPE_CANDIDATES; i++) {
          const opts: CreateSwipeCandidateOptions = {
            content: 'candidate ' + i.toString(),
            status: ChatMessageStatus.Completed,
            isStreaming: false
          };
          await service.appendCandidate(messageId, opts, false);
        }
        const state: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(state !== null).assertTrue();
        expect(state!.candidates.length).assertEqual(MAX_SWIPE_CANDIDATES);
        // 验证索引连续 0..7
        const indexes: number[] = state!.candidates.map(c => c.candidateIndex).sort();
        for (let i = 0; i < MAX_SWIPE_CANDIDATES; i++) {
          expect(indexes[i]).assertEqual(i);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('ninth_candidate_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 填充到 MAX_SWIPE_CANDIDATES 个
        for (let i = 1; i < MAX_SWIPE_CANDIDATES; i++) {
          await service.appendCandidate(messageId, {
            content: 'candidate ' + i.toString(),
            status: ChatMessageStatus.Completed,
            isStreaming: false
          }, false);
        }
        // 第 9 个应拒绝
        let threw: boolean = false;
        let errorType: number = -1;
        try {
          await service.appendCandidate(messageId, {
            content: 'overflow',
            status: ChatMessageStatus.Completed,
            isStreaming: false
          }, false);
        } catch (e) {
          threw = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
        // 验证候选数量未增加
        const state: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(state !== null).assertTrue();
        expect(state!.candidates.length).assertEqual(MAX_SWIPE_CANDIDATES);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 8. Concurrency =====

    it('concurrent_ensure_no_duplicate', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        // 并发两次 ensureSwipeState
        const results: MessageSwipeState[] = await Promise.all([
          service.ensureSwipeState(messageId),
          service.ensureSwipeState(messageId)
        ]);
        // 两者都应成功返回
        expect(results.length).assertEqual(2);
        expect(results[0].candidates.length).assertEqual(1);
        expect(results[1].candidates.length).assertEqual(1);
        // 数据库只有一条 group
        const store: relationalStore.RdbStore = helper.getStore();
        const groupCount: number = await rowCount(store, TABLE_MESSAGE_SWIPE_GROUPS);
        expect(groupCount).assertEqual(1);
        const candidateCount: number = await rowCount(store, TABLE_MESSAGE_SWIPE_CANDIDATES);
        expect(candidateCount).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('concurrent_append_no_duplicate_index', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 并发追加两个候选
        const results: PromiseSettledResult<MessageSwipeState>[] = await Promise.allSettled([
          service.appendCandidate(messageId, {
            content: 'concurrent A',
            status: ChatMessageStatus.Completed,
            isStreaming: false
          }, false),
          service.appendCandidate(messageId, {
            content: 'concurrent B',
            status: ChatMessageStatus.Completed,
            isStreaming: false
          }, false)
        ]);
        // 至少一个应成功
        const fulfilled: PromiseSettledResult<MessageSwipeState>[] =
          results.filter(r => r.status === 'fulfilled');
        expect(fulfilled.length >= 1).assertTrue();
        // 验证索引不重复
        const state: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(state !== null).assertTrue();
        const indexes: number[] = state!.candidates.map(c => c.candidateIndex).sort();
        for (let i = 0; i < indexes.length; i++) {
          if (i > 0) {
            expect(indexes[i] !== indexes[i - 1]).assertTrue();
          }
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 9. Chat deletion =====

    it('remove_by_chat_id_cascades', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 追加一个候选
        await service.appendCandidate(messageId, {
          content: 'candidate',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        }, false);
        // 删除 Chat 的 Swipe 数据
        const removed: number = await service.removeByChatId(chatId);
        expect(removed >= 1).assertTrue();
        const state: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(state === null).assertTrue();
        // messages 表不受影响
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const msg: ChatMessage | null = await msgRepo.getById(messageId);
        expect(msg !== null).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('remove_by_chat_id_rolls_back_on_failure', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const chatId: string = chatMsgResult.chatId;
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 用事务包裹,在删除后回滚
        let threw: boolean = false;
        try {
          await helper.runInTransaction(
            async (store: relationalStore.RdbStore): Promise<void> => {
              await service.removeByChatIdWithStore(store, chatId);
              // 抛出异常触发回滚
              throw new Error('simulated failure');
            }
          );
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
        // 验证 Swipe 数据仍在
        const state: MessageSwipeState | null = await service.getSwipeState(messageId);
        expect(state !== null).assertTrue();
        // messages 表也不受影响
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const msg: ChatMessage | null = await msgRepo.getById(messageId);
        expect(msg !== null).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('other_chat_swipe_unaffected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        // 创建两个 Chat 各有一条消息
        const chatId1: string = uniqueId('chat');
        const chatId2: string = uniqueId('chat');
        const msgId1: string = uniqueId('msg');
        const msgId2: string = uniqueId('msg');
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        await chatRepo.insert(createChat({ id: chatId1, title: 'Chat 1', createdAt: 1000 }));
        await chatRepo.insert(createChat({ id: chatId2, title: 'Chat 2', createdAt: 1000 }));
        await msgRepo.insert(makeMessage(msgId1, ChatRole.Assistant, 'msg1'), chatId1, 1);
        await msgRepo.insert(makeMessage(msgId2, ChatRole.Assistant, 'msg2'), chatId2, 1);
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(msgId1);
        await service.ensureSwipeState(msgId2);
        // 删除 Chat 1 的 Swipe
        const removed: number = await service.removeByChatId(chatId1);
        expect(removed >= 1).assertTrue();
        // Chat 2 的 Swipe 应不受影响
        const state2: MessageSwipeState | null = await service.getSwipeState(msgId2);
        expect(state2 !== null).assertTrue();
        expect(state2!.candidates.length).assertEqual(1);
        // Chat 1 的 Swipe 应已删除
        const state1: MessageSwipeState | null = await service.getSwipeState(msgId1);
        expect(state1 === null).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 10. Safety =====

    it('input_objects_not_modified', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        // 记录原始 options
        const opts: CreateSwipeCandidateOptions = {
          content: 'test content',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        const optsSnapshot: string = JSON.stringify(opts);
        await service.ensureSwipeState(messageId);
        await service.appendCandidate(messageId, opts, false);
        // options 对象不应被修改
        expect(JSON.stringify(opts)).assertEqual(optsSnapshot);
        // 验证 updateCandidate 不修改输入
        const updates: MessageSwipeCandidateUpdates = {
          content: 'updated',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        const updatesSnapshot: string = JSON.stringify(updates);
        await service.updateCandidate(messageId, 0, updates);
        expect(JSON.stringify(updates)).assertEqual(updatesSnapshot);
      } finally {
        await cleanupHelper(helper);
      }
    });

    it('log_does_not_contain_candidate_content', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const sensitiveContent: string = 'SuperSecretCandidateContent!@#$%';
        const chatMsgResult: ChatAndMessageResult = await createChatAndAssistantMessage(
          helper, uniqueId('msg'), 'original'
        );
        const messageId: string = chatMsgResult.messageId;
        const service: MessageSwipePersistenceService = setupService(helper);
        await service.ensureSwipeState(messageId);
        // 插入包含敏感内容的候选
        const opts: CreateSwipeCandidateOptions = {
          content: sensitiveContent,
          status: ChatMessageStatus.Completed,
          isStreaming: false
        };
        await service.appendCandidate(messageId, opts, false);
        // 触发错误(如重复插入 group)并检查错误消息不包含敏感内容
        let caught: boolean = false;
        let msg: string = '';
        try {
          // 再次调用 ensureSwipeState 不会触发错误(幂等)
          // 所以我们直接通过 repository 触发约束错误
          const swipeRepo: MessageSwipeRepository = new MessageSwipeRepository(helper);
          const group: MessageSwipeGroup = {
            assistantMessageId: messageId,
            chatId: 'chat-other',
            activeCandidateIndex: 0,
            createdAt: 1000,
            updatedAt: 1000
          };
          // 直接插入会因唯一约束失败
          await swipeRepo.insertGroup(group);
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            msg = e.message + ' ' + e.causeMessage;
          } else if (e instanceof Error) {
            msg = e.message;
          }
        }
        expect(caught).assertTrue();
        // 错误消息不应包含敏感内容
        expect(msg.indexOf(sensitiveContent) < 0).assertTrue();
        // 错误消息不应包含 SQL 关键词
        expect(msg.indexOf('SQL') < 0).assertTrue();
        expect(msg.indexOf('INSERT') < 0).assertTrue();
        expect(msg.indexOf('SELECT') < 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}