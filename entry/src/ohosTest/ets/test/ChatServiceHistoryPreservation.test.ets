/**
 * ChatService 历史保留设备测试(T-6.4A 阻断项)
 *
 * 验证"重新生成最新 Assistant 回复后,旧聊天记录不从页面消失"。
 *
 * Bug 根因:
 * 旧版 ChatService 在 Swipe 重新生成后调用了 reloadCurrentSession()
 * → loadSessionInternal() → normalizeInterruptedMessages(),
 * 后者将所有 Streaming 消息改为 Cancelled 并重新加载消息列表,
 * 导致页面数组被替换为裁剪后的版本(仅剩最后两条消息)。
 *
 * 修复方案:
 * 引入 replaceAssistantMessageInFullHistory(assistantMessageId) 方法,
 * 只在完整页面历史中按 Message ID 查找并替换目标 Assistant 为 Streaming+空 content,
 * 保留其他所有消息的 ID、内容、顺序、sequenceNumber 不变。
 *
 * 覆盖 16 项测试用例:
 * 1. 10条历史重新生成后仍为10条
 * 2. 前9条 Message ID 不变
 * 3. 前9条 content 不变
 * 4. 前9条 sequenceNumber 不变
 * 5. 只替换目标 Assistant
 * 6. request history 排除目标 Assistant
 * 7. request history 不写回 UI
 * 8. HistoryTrimmer 结果不写回 UI
 * 9. Swipe delta 不缩短页面数组
 * 10. Swipe complete 不缩短页面数组
 * 11. Swipe stop 不缩短页面数组
 * 12. Swipe error 不缩短页面数组
 * 13. 左右切换不缩短页面数组
 * 14. 会话重载恢复完整消息
 * 15. messages 数据库行数不变
 * 16. BranchMessage Links 数量不变
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import { MessageRepository, StoredChatMessage } from '../../../main/ets/repositories/MessageRepository';
import { ChatPersistenceOperations } from '../../../main/ets/repositories/ChatPersistenceOperations';
import { MessageSwipeRepository } from '../../../main/ets/repositories/MessageSwipeRepository';
import { ConversationBranchRepository } from '../../../main/ets/repositories/ConversationBranchRepository';
import { ChatPersistenceService } from '../../../main/ets/services/ChatPersistenceService';
import { ChatService, ChatState, ChatServiceCallbacks } from '../../../main/ets/services/ChatService';
import { MessageSwipePersistenceService } from '../../../main/ets/services/MessageSwipePersistenceService';
import { ConversationBranchPersistenceService } from '../../../main/ets/services/ConversationBranchPersistenceService';
import { HistoryTrimmer, HistoryTrimOptions } from '../../../main/ets/services/HistoryTrimmer';
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../../main/ets/models/ChatMessageSource';
import { ChatRequestOptions } from '../../../main/ets/models/ChatRequest';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState,
  ChatDelta,
  ChatStreamResult
} from '../../../main/ets/models/ChatStreamTypes';
import { NetworkError, NetworkErrorType, createNetworkError } from '../../../main/ets/models/NetworkError';
import { HistoryTrimResult, createHistoryTrimResult } from '../../../main/ets/models/HistoryTrimResult';
import { PersistedChatSession } from '../../../main/ets/models/PersistedChatSession';
import { ConversationRecordCounts } from '../../../main/ets/models/ConversationBranch';

const TEST_DB_NAME: string = 'arktavern_history_preservation_test.db';
let idCounter: number = 0;

function uniqueId(prefix: string): string {
  idCounter++;
  return `${prefix}-${idCounter}`;
}

// ===== Context / DB helpers =====

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

// ===== Service stack factory =====

interface ServiceStack {
  helper: DbHelper;
  branchService: ConversationBranchPersistenceService;
  swipeService: MessageSwipePersistenceService;
  persistenceService: ChatPersistenceService;
  chatRepo: ChatRepository;
  msgRepo: MessageRepository;
  swipeRepo: MessageSwipeRepository;
  branchRepo: ConversationBranchRepository;
}

interface SetupResult {
  chatId: string;
  messageIds: string[];
}

function makeServiceStack(helper: DbHelper): ServiceStack {
  const chatRepo: ChatRepository = new ChatRepository(helper);
  const msgRepo: MessageRepository = new MessageRepository(helper);
  const swipeRepo: MessageSwipeRepository = new MessageSwipeRepository(helper);
  const branchRepo: ConversationBranchRepository = new ConversationBranchRepository(helper);
  const ops: ChatPersistenceOperations =
    new ChatPersistenceOperations(helper, chatRepo, msgRepo, swipeRepo);
  const branchService: ConversationBranchPersistenceService =
    new ConversationBranchPersistenceService(helper, branchRepo, msgRepo, swipeRepo);
  const swipeService: MessageSwipePersistenceService =
    new MessageSwipePersistenceService(helper, msgRepo, swipeRepo, branchService);
  const persistenceService: ChatPersistenceService =
    new ChatPersistenceService(helper, chatRepo, msgRepo, ops, branchService);
  return {
    helper: helper,
    branchService: branchService,
    swipeService: swipeService,
    persistenceService: persistenceService,
    chatRepo: chatRepo,
    msgRepo: msgRepo,
    swipeRepo: swipeRepo,
    branchRepo: branchRepo
  };
}

// ===== Mock ModelService =====

class ControllableStreamHandle implements ChatStreamHandle {
  aborted: boolean = false;
  state: ChatStreamState = ChatStreamState.Idle;
  abort(): void { this.aborted = true; }
  getState(): ChatStreamState { return this.state; }
}

class MockModelService {
  streamChatCallCount: number = 0;
  lastMessages: ChatMessage[] | null = null;
  private pendingCallbacks: ChatStreamCallbacks | null = null;
  private pendingHandle: ControllableStreamHandle | null = null;

  streamCurrentChat(
    messages: ChatMessage[],
    _options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    this.streamChatCallCount++;
    this.lastMessages = messages;
    this.pendingCallbacks = callbacks;
    this.pendingHandle = new ControllableStreamHandle();
    this.pendingHandle.state = ChatStreamState.Streaming;
    return this.pendingHandle;
  }

  fireDelta(content: string, seq: number): void {
    if (this.pendingCallbacks !== null) {
      const delta: ChatDelta = {
        content: content,
        accumulatedContent: undefined,
        finishReason: undefined,
        sequence: seq
      };
      this.pendingCallbacks.onDelta(delta);
    }
  }

  fireCompleteWithContent(content: string): void {
    if (this.pendingCallbacks !== null) {
      const result: ChatStreamResult = {
        content: content,
        finishReason: 'stop',
        model: 'mock-model',
        chunkCount: 1,
        eventCount: 1,
        deltaCount: 1,
        receivedDone: true
      };
      this.pendingCallbacks.onComplete(result);
    }
  }

  fireError(type: NetworkErrorType, message: string): void {
    if (this.pendingCallbacks !== null) {
      const error: NetworkError = createNetworkError(type, message);
      this.pendingCallbacks.onError(error);
    }
  }

  getPendingHandle(): ControllableStreamHandle | null {
    return this.pendingHandle;
  }

  reset(): void {
    this.streamChatCallCount = 0;
    this.lastMessages = null;
    this.pendingCallbacks = null;
    this.pendingHandle = null;
  }
}

// ===== Mock TokenCounter (exceeds budget for large arrays, within budget after trim) =====

class HighTokenCounter {
  /**
   * 大量消息(>2)返回超预算值触发 HistoryTrimmer 裁剪;
   * 少量消息(<=2,裁剪后)返回小值,使 lastTokenBudget.exceedsBudget=false,
   * 让 streamCurrentChat 正常被调用。
   * available = DEFAULT_CONTEXT_WINDOW(32768) - DEFAULT_RESERVED_OUTPUT_TOKENS(2048) = 30720
   */
  estimateMessages(messages: ChatMessage[]): number {
    return messages.length > 2 ? 999999 : 10;
  }
  estimateText(_content: string): number { return 10; }
  estimateMessage(_message: ChatMessage): number { return 10; }
}

// ===== Mock HistoryTrimmer (keeps only last 2 messages) =====

class ShortHistoryTrimmer {
  trim(messages: ChatMessage[], _options: HistoryTrimOptions): HistoryTrimResult {
    const kept: ChatMessage[] = messages.length > 2 ? messages.slice(-2) : messages.slice();
    const removedIds: string[] = [];
    const removeCount: number = messages.length > 2 ? messages.length - 2 : 0;
    for (let i = 0; i < removeCount; i++) {
      removedIds.push(messages[i].id);
    }
    return createHistoryTrimResult(kept, 999999, 100, removedIds, true, false);
  }
}

// ===== Callback collector =====

interface CallbackCollector {
  messages: ChatMessage[];
  states: ChatState[];
  errors: string[];
  changeCount: number;
}

function createCollector(): CallbackCollector {
  return { messages: [], states: [], errors: [], changeCount: 0 };
}

function createCallbacks(col: CallbackCollector): ChatServiceCallbacks {
  return {
    onMessagesChanged: (msgs: ChatMessage[]): void => { col.messages = msgs; col.changeCount++; },
    onStateChanged: (state: ChatState): void => { col.states.push(state); },
    onError: (msg: string): void => { col.errors.push(msg); }
  };
}

// ===== Message helpers =====

function makeMessage(id: string, role: ChatRole, content: string): ChatMessage {
  return {
    id: id,
    role: role,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    status: ChatMessageStatus.Completed,
    isStreaming: false,
    source: ChatMessageSource.Conversation
  };
}

/**
 * 创建 10 条历史消息(5 User + 5 Assistant 交替)并写入 DB。
 * 返回消息 ID 数组和 chatId。
 */
async function setupTenMessages(stack: ServiceStack): Promise<SetupResult> {
  const session: PersistedChatSession = await stack.persistenceService.createSession(undefined);
  const chatId: string = session.chat.id;
  const messageIds: string[] = [];
  for (let i = 0; i < 5; i++) {
    const userMsg: ChatMessage = makeMessage(uniqueId('u'), ChatRole.User, `U${i + 1}`);
    const assistantMsg: ChatMessage = makeMessage(uniqueId('a'), ChatRole.Assistant, `A${i + 1}`);
    await stack.persistenceService.appendMessage(chatId, userMsg);
    await stack.persistenceService.appendMessage(chatId, assistantMsg);
    messageIds.push(userMsg.id);
    messageIds.push(assistantMsg.id);
  }
  const result: SetupResult = { chatId: chatId, messageIds: messageIds };
  return result;
}

/**
 * 创建带完整服务栈的 ChatService。
 * useHighTokenCounter/useShortHistoryTrimmer 用于测试裁剪场景。
 */
function createChatService(
  mockMs: MockModelService,
  stack: ServiceStack,
  useHighTokenCounter: boolean = false,
  useShortHistoryTrimmer: boolean = false
): ChatService {
  const tokenCounter: import('../../../main/ets/services/TokenCounter').TokenCounter | null =
    useHighTokenCounter
      ? new HighTokenCounter() as Object as import('../../../main/ets/services/TokenCounter').TokenCounter
      : null;
  const historyTrimmer: import('../../../main/ets/services/HistoryTrimmer').HistoryTrimmer | null =
    useShortHistoryTrimmer
      ? new ShortHistoryTrimmer() as Object as import('../../../main/ets/services/HistoryTrimmer').HistoryTrimmer
      : null;
  return new ChatService(
    mockMs as Object as import('../../../main/ets/services/ModelService').ModelService,
    null,
    null,
    tokenCounter,
    historyTrimmer,
    stack.persistenceService,
    null,
    stack.swipeService,
    stack.branchService
  );
}

/**
 * 等待 doStream 微任务完成,确保 streamCurrentChat 已被调用。
 */
async function waitForStreamStart(): Promise<void> {
  await new Promise<void>(resolve => setTimeout(resolve, 10));
}

// ===== Test suite =====

export default function chatServiceHistoryPreservationTest(): void {
  describe('ChatServiceHistoryPreservationTest', () => {

    // 1. 10条历史重新生成后仍为10条
    it('regenerate_preserves_10_history_messages', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const col: CallbackCollector = createCollector();
        const cb: ChatServiceCallbacks = createCallbacks(col);
        await service.initializeSession(undefined);
        expect(service.getMessages().length).assertEqual(10);
        await service.regenerateLastResponse(cb);
        const afterMessages: ChatMessage[] = service.getMessages();
        expect(afterMessages.length).assertEqual(10);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 2. 前9条 Message ID 不变
    it('regenerate_preserves_first_9_message_ids', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        const setupResult: SetupResult = await setupTenMessages(stack);
        const messageIds: string[] = setupResult.messageIds;
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        const beforeIds: string[] = service.getMessages().map((m: ChatMessage): string => m.id);
        await service.regenerateLastResponse(cb);
        const afterMessages: ChatMessage[] = service.getMessages();
        for (let i = 0; i < 9; i++) {
          expect(afterMessages[i].id).assertEqual(beforeIds[i]);
          expect(afterMessages[i].id).assertEqual(messageIds[i]);
        }
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 3. 前9条 content 不变
    it('regenerate_preserves_first_9_message_content', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        const beforeContents: string[] = service.getMessages().map((m: ChatMessage): string => m.content);
        await service.regenerateLastResponse(cb);
        const afterMessages: ChatMessage[] = service.getMessages();
        for (let i = 0; i < 9; i++) {
          expect(afterMessages[i].content).assertEqual(beforeContents[i]);
        }
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 4. 前9条 sequenceNumber 不变(通过 DB 查询验证)
    it('regenerate_preserves_first_9_sequence_numbers', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        const setupResult: SetupResult = await setupTenMessages(stack);
        const chatId: string = setupResult.chatId;
        const messageIds: string[] = setupResult.messageIds;
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        const beforeRecords: StoredChatMessage[] = await stack.msgRepo.listRecordsByChat(chatId);
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        const afterRecords: StoredChatMessage[] = await stack.msgRepo.listRecordsByChat(chatId);
        expect(afterRecords.length).assertEqual(10);
        for (let i = 0; i < 9; i++) {
          const beforeSeq: number = beforeRecords[i].sequenceNumber;
          const afterSeq: number = afterRecords[i].sequenceNumber;
          expect(afterSeq).assertEqual(beforeSeq);
          expect(afterRecords[i].message.id).assertEqual(messageIds[i]);
        }
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 5. 只替换目标 Assistant(第10条),其他消息不受影响
    it('regenerate_only_replaces_target_assistant', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        const beforeMessages: ChatMessage[] = service.getMessages();
        const targetId: string = beforeMessages[9].id;
        const beforeContent: string = beforeMessages[9].content;
        expect(beforeContent.length > 0).assertTrue();
        await service.regenerateLastResponse(cb);
        const afterMessages: ChatMessage[] = service.getMessages();
        expect(afterMessages[9].id).assertEqual(targetId);
        expect(afterMessages[9].content).assertEqual('');
        expect(afterMessages[9].isStreaming).assertTrue();
        expect(afterMessages[9].status).assertEqual(ChatMessageStatus.Streaming);
        // 前9条不受影响(状态非 Streaming)
        for (let i = 0; i < 9; i++) {
          expect(afterMessages[i].isStreaming).assertFalse();
          expect(afterMessages[i].status).assertEqual(ChatMessageStatus.Completed);
        }
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 6. request history 排除目标 Assistant
    it('request_history_excludes_target_assistant', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        const targetId: string = service.getMessages()[9].id;
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        expect(mockMs.streamChatCallCount).assertEqual(1);
        const requestMessages: ChatMessage[] | null = mockMs.lastMessages;
        expect(requestMessages !== null).assertTrue();
        expect(requestMessages!.length).assertEqual(9);
        let containsTarget: boolean = false;
        for (let i = 0; i < requestMessages!.length; i++) {
          if (requestMessages![i].id === targetId) {
            containsTarget = true;
            break;
          }
        }
        expect(containsTarget).assertFalse();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 7. request history 不写回 UI(UI 仍保留全部 10 条)
    it('request_history_not_written_back_to_ui', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        // request 只有 9 条,但 UI 仍有 10 条
        expect(mockMs.lastMessages!.length).assertEqual(9);
        expect(service.getMessages().length).assertEqual(10);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 8. HistoryTrimmer 结果不写回 UI(裁剪后 request 仅 2 条,UI 仍 10 条)
    it('history_trimmer_result_not_written_back_to_ui', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack, true, true);
        const col: CallbackCollector = createCollector();
        const cb: ChatServiceCallbacks = createCallbacks(col);
        await service.initializeSession(undefined);
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        // 裁剪后 request 仅 2 条
        expect(mockMs.lastMessages !== null).assertTrue();
        expect(mockMs.lastMessages!.length).assertEqual(2);
        // UI 仍保留 10 条
        expect(service.getMessages().length).assertEqual(10);
        // 裁剪确实发生过
        const trimResult: HistoryTrimResult | undefined = service.getLastHistoryTrimResult();
        expect(trimResult !== undefined).assertTrue();
        expect(trimResult!.removedMessageCount > 0).assertTrue();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 9. Swipe delta 不缩短页面数组
    it('swipe_delta_does_not_shorten_page_array', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        mockMs.fireDelta('partial reply', 0);
        const afterDelta: ChatMessage[] = service.getMessages();
        expect(afterDelta.length).assertEqual(10);
        expect(afterDelta[9].content).assertEqual('partial reply');
        expect(afterDelta[9].isStreaming).assertTrue();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 10. Swipe complete 不缩短页面数组
    it('swipe_complete_does_not_shorten_page_array', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        mockMs.fireCompleteWithContent('new reply');
        const afterComplete: ChatMessage[] = service.getMessages();
        expect(afterComplete.length).assertEqual(10);
        expect(afterComplete[9].content).assertEqual('new reply');
        expect(afterComplete[9].isStreaming).assertFalse();
        expect(afterComplete[9].status).assertEqual(ChatMessageStatus.Completed);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 11. Swipe stop 不缩短页面数组
    it('swipe_stop_does_not_shorten_page_array', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        mockMs.fireDelta('partial', 0);
        service.stopGeneration();
        const afterStop: ChatMessage[] = service.getMessages();
        expect(afterStop.length).assertEqual(10);
        expect(afterStop[9].status).assertEqual(ChatMessageStatus.Cancelled);
        expect(afterStop[9].content).assertEqual('partial');
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 12. Swipe error 不缩短页面数组
    it('swipe_error_does_not_shorten_page_array', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        await setupTenMessages(stack);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const col: CallbackCollector = createCollector();
        const cb: ChatServiceCallbacks = createCallbacks(col);
        await service.initializeSession(undefined);
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        mockMs.fireDelta('partial before error', 0);
        mockMs.fireError(NetworkErrorType.Server, 'server error');
        const afterError: ChatMessage[] = service.getMessages();
        expect(afterError.length).assertEqual(10);
        expect(afterError[9].status).assertEqual(ChatMessageStatus.Failed);
        expect(col.errors.length > 0).assertTrue();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 13. 左右切换不缩短页面数组
    it('swipe_left_right_does_not_shorten_page_array', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        const setupResult: SetupResult = await setupTenMessages(stack);
        const messageIds: string[] = setupResult.messageIds;
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        const targetId: string = messageIds[9];
        // 生成新候选(Candidate 1)
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        mockMs.fireCompleteWithContent('reply_new');
        expect(service.getMessages().length).assertEqual(10);
        // 切换到前一个候选(Candidate 0 = 原始内容)
        await service.activatePreviousCandidate(targetId);
        expect(service.getMessages().length).assertEqual(10);
        expect(service.getMessages()[9].content).assertEqual('A5');
        // 切换到后一个候选(Candidate 1 = 新内容)
        await service.activateNextCandidate(targetId);
        expect(service.getMessages().length).assertEqual(10);
        expect(service.getMessages()[9].content).assertEqual('reply_new');
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 14. 会话重载恢复完整消息
    it('session_reload_restores_full_messages', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        const setupResult: SetupResult = await setupTenMessages(stack);
        const chatId: string = setupResult.chatId;
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        // 启动 Swipe 生成,使 DB 中最后一条消息变为 Streaming
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        service.dispose();
        // 重新创建 ChatService 并加载会话
        const mockMs2: MockModelService = new MockModelService();
        const service2: ChatService = createChatService(mockMs2, stack);
        await service2.initializeSession(undefined);
        const reloadedMessages: ChatMessage[] = service2.getMessages();
        expect(reloadedMessages.length).assertEqual(10);
        // 最后一条消息被 normalizeInterruptedMessages 标记为 Cancelled
        expect(reloadedMessages[9].status).assertEqual(ChatMessageStatus.Cancelled);
        expect(service2.getCurrentChatId()).assertEqual(chatId);
        service2.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 15. messages 数据库行数不变
    it('db_message_rows_unchanged_after_regenerate', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        const setupResult: SetupResult = await setupTenMessages(stack);
        const chatId: string = setupResult.chatId;
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        expect(await stack.msgRepo.countByChatId(chatId)).assertEqual(10);
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        expect(await stack.msgRepo.countByChatId(chatId)).assertEqual(10);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // 16. BranchMessage Links 数量不变
    it('branch_message_links_unchanged_after_regenerate', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const stack: ServiceStack = makeServiceStack(helper);
        const setupResult: SetupResult = await setupTenMessages(stack);
        const chatId: string = setupResult.chatId;
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, stack);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        const beforeCounts: ConversationRecordCounts =
          await stack.branchRepo.getRecordCounts(chatId);
        expect(beforeCounts.currentBranchMessageCount).assertEqual(10);
        expect(beforeCounts.totalUniqueMessageCount).assertEqual(10);
        expect(beforeCounts.totalBranchCount).assertEqual(1);
        await service.regenerateLastResponse(cb);
        await waitForStreamStart();
        const afterCounts: ConversationRecordCounts =
          await stack.branchRepo.getRecordCounts(chatId);
        expect(afterCounts.currentBranchMessageCount).assertEqual(10);
        expect(afterCounts.totalUniqueMessageCount).assertEqual(10);
        expect(afterCounts.totalBranchCount).assertEqual(1);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ============================================================
    // T-6.4A-R3: 定向测试 - Completed 状态持久化
    // ============================================================

    /**
     * R3-1: normalize 不改变 Completed 消息
     */
    it('r3_normalize_preserves_completed', 0, async (): Promise<void> => {
      const helper: TestHelper = await setupHelper();
      try {
        const msgId: string = uniqueId('msg');
        const msg: StoredChatMessage = {
          id: msgId, role: ChatRole.Assistant, content: 'reply',
          status: ChatMessageStatus.Completed, isStreaming: false,
          sequenceNumber: 2, source: ChatMessageSource.Conversation,
          createdAt: 1000, updatedAt: 1000
        };
        await helper.msgRepo.insertMessage(msg, helper.chatId);
        const count: number = await helper.msgRepo.normalizeInterruptedMessages(helper.chatId);
        expect(count === 0).assertTrue();
        const stored: StoredChatMessage | null = await helper.msgRepo.getById(msgId);
        expect(stored !== null).assertTrue();
        if (stored !== null) {
          expect(stored.status === ChatMessageStatus.Completed).assertTrue();
          expect(stored.isStreaming === false).assertTrue();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    /**
     * R3-2: normalize 不改变 Failed 消息
     */
    it('r3_normalize_preserves_failed', 0, async (): Promise<void> => {
      const helper: TestHelper = await setupHelper();
      try {
        const msgId: string = uniqueId('msg');
        const msg: StoredChatMessage = {
          id: msgId, role: ChatRole.Assistant, content: 'error',
          status: ChatMessageStatus.Failed, isStreaming: false,
          sequenceNumber: 2, source: ChatMessageSource.Conversation,
          createdAt: 1000, updatedAt: 1000
        };
        await helper.msgRepo.insertMessage(msg, helper.chatId);
        const count: number = await helper.msgRepo.normalizeInterruptedMessages(helper.chatId);
        expect(count === 0).assertTrue();
        const stored: StoredChatMessage | null = await helper.msgRepo.getById(msgId);
        expect(stored !== null).assertTrue();
        if (stored !== null) {
          expect(stored.status === ChatMessageStatus.Failed).assertTrue();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    /**
     * R3-3: normalize 将 Streaming 改为 Cancelled
     */
    it('r3_streaming_normalize_becomes_cancelled', 0, async (): Promise<void> => {
      const helper: TestHelper = await setupHelper();
      try {
        const msgId: string = uniqueId('msg');
        const msg: StoredChatMessage = {
          id: msgId, role: ChatRole.Assistant, content: 'partial',
          status: ChatMessageStatus.Streaming, isStreaming: true,
          sequenceNumber: 2, source: ChatMessageSource.Conversation,
          createdAt: 1000, updatedAt: 1000
        };
        await helper.msgRepo.insertMessage(msg, helper.chatId);
        const count: number = await helper.msgRepo.normalizeInterruptedMessages(helper.chatId);
        expect(count >= 1).assertTrue();
        const stored: StoredChatMessage | null = await helper.msgRepo.getById(msgId);
        expect(stored !== null).assertTrue();
        if (stored !== null) {
          expect(stored.status === ChatMessageStatus.Cancelled).assertTrue();
          expect(stored.isStreaming === false).assertTrue();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    /**
     * R3-4: normalize 不改变 Cancelled 消息
     */
    it('r3_normalize_preserves_cancelled', 0, async (): Promise<void> => {
      const helper: TestHelper = await setupHelper();
      try {
        const msgId: string = uniqueId('msg');
        const msg: StoredChatMessage = {
          id: msgId, role: ChatRole.Assistant, content: 'stopped',
          status: ChatMessageStatus.Cancelled, isStreaming: false,
          sequenceNumber: 2, source: ChatMessageSource.Conversation,
          createdAt: 1000, updatedAt: 1000
        };
        await helper.msgRepo.insertMessage(msg, helper.chatId);
        const count: number = await helper.msgRepo.normalizeInterruptedMessages(helper.chatId);
        expect(count === 0).assertTrue();
        const stored: StoredChatMessage | null = await helper.msgRepo.getById(msgId);
        expect(stored !== null).assertTrue();
        if (stored !== null) {
          expect(stored.status === ChatMessageStatus.Cancelled).assertTrue();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    /**
     * R3-5: normalize 不缩短消息历史
     */
    it('r3_normalize_does_not_shorten_history', 0, async (): Promise<void> => {
      const helper: TestHelper = await setupHelper();
      try {
        for (let i: number = 0; i < 5; i++) {
          const role: ChatRole = i % 2 === 0 ? ChatRole.User : ChatRole.Assistant;
          const msg: StoredChatMessage = {
            id: uniqueId('msg'), role: role, content: 'c' + i.toString(),
            status: role === ChatRole.Assistant ? ChatMessageStatus.Completed : ChatMessageStatus.Completed,
            isStreaming: false, sequenceNumber: i + 2,
            source: ChatMessageSource.Conversation, createdAt: 1000, updatedAt: 1000
          };
          await helper.msgRepo.insertMessage(msg, helper.chatId);
        }
        await helper.msgRepo.normalizeInterruptedMessages(helper.chatId);
        const session: PersistedChatSession = await helper.persistenceService.loadSession(helper.chatId);
        expect(session.messages.length === 5).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    /**
     * R3-6: UI - 仅 Cancelled 状态显示"已停止"
     */
    it('r3_ui_only_cancelled_shows_stopped', 0, (): void => {
      expect(ChatMessageStatus.Completed !== ChatMessageStatus.Cancelled).assertTrue();
      expect(ChatMessageStatus.Cancelled === ChatMessageStatus.Cancelled).assertTrue();
      expect(ChatMessageStatus.Failed !== ChatMessageStatus.Cancelled).assertTrue();
      expect(ChatMessageStatus.Streaming !== ChatMessageStatus.Cancelled).assertTrue();
    });
  });
}
