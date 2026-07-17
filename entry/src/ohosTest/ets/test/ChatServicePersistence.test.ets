/**
 * ChatService 持久化集成设备测试
 *
 * 验证 ChatService 与 ChatPersistenceService 的协作行为。
 * 使用独立测试数据库 arktavern_repository_test.db,前后清理,不发起网络请求。
 *
 * 覆盖 20 项:
 * 1-7: initializeSession 创建/恢复/幂等/并发 + getCurrentChatId + isSessionReady
 * 8-11: sendMessage/regenerate 持久化与失败路径(不启动网络)
 * 12-13: stopGeneration, dispose 清理 timer
 * 14-15: 消息数组新引用, firstMessage 持久化
 * 16-17: 角色隔离, initContext 兼容旧路径
 * 18-20: initializeSession 失败抛错, canRegenerate, getMessages 副本
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import { MessageRepository } from '../../../main/ets/repositories/MessageRepository';
import { ChatPersistenceOperations } from '../../../main/ets/repositories/ChatPersistenceOperations';
import {
  ChatPersistenceService,
  AppendUserAndAssistantResult
} from '../../../main/ets/services/ChatPersistenceService';
import {
  ChatService,
  ChatState,
  ChatServiceCallbacks
} from '../../../main/ets/services/ChatService';
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../../main/ets/models/ChatMessageSource';
import { Character, createCharacter } from '../../../main/ets/models/Character';
import { Chat } from '../../../main/ets/models/Chat';
import { DatabaseError } from '../../../main/ets/models/DatabaseError';
import { PersistedChatSession } from '../../../main/ets/models/PersistedChatSession';
import { ChatRequestOptions } from '../../../main/ets/models/ChatRequest';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState
} from '../../../main/ets/models/ChatStreamTypes';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES
} from '../../../main/ets/database/DatabaseConstants';

const REPO_TEST_DB_NAME: string = 'arktavern_repository_test.db';
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
      name: REPO_TEST_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore =
      await relationalStore.getRdbStore(ctx, config);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGES);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHATS);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHARACTERS);
    await store.close();
  } catch (e) {
    /* best-effort cleanup */
  }
}

async function makeHelper(): Promise<DbHelper> {
  const helper: DbHelper = new DbHelper(REPO_TEST_DB_NAME, []);
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

function makePersistenceService(helper: DbHelper): ChatPersistenceService {
  const chatRepo: ChatRepository = new ChatRepository(helper);
  const msgRepo: MessageRepository = new MessageRepository(helper);
  const ops: ChatPersistenceOperations =
    new ChatPersistenceOperations(helper, chatRepo, msgRepo);
  return new ChatPersistenceService(helper, chatRepo, msgRepo, ops);
}

function makeCharacter(id: string, name: string, firstMessage: string = ''): Character {
  return createCharacter(id, name, '', '', '', firstMessage, '', '');
}

function makeMessage(id: string, role: ChatRole, content: string): ChatMessage {
  return {
    id: id, role: role, content: content, createdAt: 1000, updatedAt: 1000,
    status: ChatMessageStatus.Completed, isStreaming: false, source: ChatMessageSource.Conversation
  };
}

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

function emptyCallbacks(): ChatServiceCallbacks {
  return {
    onMessagesChanged: (_msgs: ChatMessage[]): void => {},
    onStateChanged: (_state: ChatState): void => {},
    onError: (_msg: string): void => {}
  };
}

class ControllableStreamHandle implements ChatStreamHandle {
  aborted: boolean = false;
  state: ChatStreamState = ChatStreamState.Idle;
  abort(): void { this.aborted = true; }
  getState(): ChatStreamState { return this.state; }
}

class MockModelService {
  streamChatCallCount: number = 0;
  private pendingCallbacks: ChatStreamCallbacks | null = null;

  streamCurrentChat(
    _messages: ChatMessage[],
    _options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    this.streamChatCallCount++;
    this.pendingCallbacks = callbacks;
    const handle: ControllableStreamHandle = new ControllableStreamHandle();
    handle.state = ChatStreamState.Streaming;
    return handle;
  }

  fireDelta(content: string, seq: number): void {
    if (this.pendingCallbacks !== null) {
      this.pendingCallbacks.onDelta({
        content: content,
        accumulatedContent: undefined,
        finishReason: undefined,
        sequence: seq
      });
    }
  }

  fireCompleteWithContent(content: string): void {
    if (this.pendingCallbacks !== null) {
      this.pendingCallbacks.onComplete({
        content: content,
        finishReason: 'stop',
        model: 'mock-model',
        chunkCount: 1,
        eventCount: 1,
        deltaCount: 1,
        receivedDone: true
      });
    }
  }

  reset(): void {
    this.streamChatCallCount = 0;
    this.pendingCallbacks = null;
  }
}

class FailingPersistenceService extends ChatPersistenceService {
  failOpenLatest: boolean = false;
  failAppend: boolean = false;
  failReplace: boolean = false;

  constructor(helper: DbHelper) {
    const chatRepo: ChatRepository = new ChatRepository(helper);
    const msgRepo: MessageRepository = new MessageRepository(helper);
    const ops: ChatPersistenceOperations =
      new ChatPersistenceOperations(helper, chatRepo, msgRepo);
    super(helper, chatRepo, msgRepo, ops);
  }

  async openLatestSession(characterId?: string): Promise<PersistedChatSession | null> {
    if (this.failOpenLatest) {
      throw DatabaseError.queryFailed('stub: openLatestSession failed');
    }
    return await super.openLatestSession(characterId);
  }

  async appendUserAndStreamingAssistant(
    chatId: string,
    userMessage: ChatMessage,
    assistantMessage: ChatMessage
  ): Promise<AppendUserAndAssistantResult> {
    if (this.failAppend) {
      throw DatabaseError.queryFailed('stub: append failed');
    }
    return await super.appendUserAndStreamingAssistant(chatId, userMessage, assistantMessage);
  }

  async replaceMessagesAfterUserAndAppend(
    chatId: string,
    userMessageId: string,
    assistantMessage: ChatMessage
  ): Promise<number> {
    if (this.failReplace) {
      throw DatabaseError.queryFailed('stub: replace failed');
    }
    return await super.replaceMessagesAfterUserAndAppend(chatId, userMessageId, assistantMessage);
  }
}

function createChatService(
  mockMs: MockModelService,
  persistenceService: ChatPersistenceService | null
): ChatService {
  return new ChatService(
    mockMs as Object as import('../../../main/ets/services/ModelService').ModelService,
    null,
    null,
    null,
    null,
    persistenceService
  );
}

export default function chatServicePersistenceDeviceTest(): void {
  describe('ChatServicePersistenceDeviceTest', () => {
    // 1. initializeSession 无历史时创建新 Chat
    it('initSession_creates_new_chat_when_no_history', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const service: ChatService = createChatService(new MockModelService(), ps);
        expect(service.isSessionReady()).assertFalse();
        await service.initializeSession(undefined);
        expect(service.isSessionReady()).assertTrue();
        const chatId: string | undefined = service.getCurrentChatId();
        expect(chatId !== undefined).assertTrue();
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chat: Chat | null = await chatRepo.getById(chatId!);
        expect(chat !== null).assertTrue();
        expect(await msgRepo.countByChatId(chatId!)).assertEqual(0);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 2. initializeSession 无角色时创建普通 Chat
    it('initSession_creates_plain_chat_without_character', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const service: ChatService = createChatService(new MockModelService(), ps);
        await service.initializeSession(undefined);
        const chatId: string = service.getCurrentChatId()!;
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const chat: Chat | null = await chatRepo.getById(chatId);
        expect(chat !== null).assertTrue();
        expect(chat!.characterId === undefined).assertTrue();
        expect(chat!.title.length > 0).assertTrue();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 3. initializeSession 恢复历史 messages
    it('initSession_restores_history_messages', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const character: Character = makeCharacter(uniqueId('char'), 'Alice');
        const session: PersistedChatSession = await ps.createSession(character.id);
        const chatId: string = session.chat.id;
        await ps.appendMessage(chatId, makeMessage(uniqueId('msg'), ChatRole.User, 'Hi'));
        await ps.appendMessage(chatId, makeMessage(uniqueId('msg'), ChatRole.Assistant, 'Hello!'));
        const service: ChatService = createChatService(new MockModelService(), ps);
        await service.initializeSession(character);
        expect(service.getCurrentChatId()).assertEqual(chatId);
        const msgs: ChatMessage[] = service.getMessages();
        expect(msgs.length).assertEqual(2);
        expect(msgs[0].role).assertEqual(ChatRole.User);
        expect(msgs[0].content).assertEqual('Hi');
        expect(msgs[1].role).assertEqual(ChatRole.Assistant);
        expect(msgs[1].content).assertEqual('Hello!');
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 4. initializeSession 幂等
    it('initSession_idempotent', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const service: ChatService = createChatService(new MockModelService(), ps);
        await service.initializeSession(undefined);
        const chatId1: string | undefined = service.getCurrentChatId();
        expect(chatId1 !== undefined).assertTrue();
        await service.initializeSession(undefined);
        const chatId2: string | undefined = service.getCurrentChatId();
        expect(chatId2).assertEqual(chatId1);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 5. initializeSession 并发保护
    it('initSession_concurrent_protection', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const service: ChatService = createChatService(new MockModelService(), ps);
        await Promise.all([
          service.initializeSession(undefined),
          service.initializeSession(undefined)
        ]);
        expect(service.isSessionReady()).assertTrue();
        const chatId: string | undefined = service.getCurrentChatId();
        expect(chatId !== undefined).assertTrue();
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const chat: Chat | null = await chatRepo.getById(chatId!);
        expect(chat !== null).assertTrue();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 6. getCurrentChatId 正确
    it('getCurrentChatId_correct_after_init', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const service: ChatService = createChatService(new MockModelService(), ps);
        expect(service.getCurrentChatId()).assertEqual(undefined);
        await service.initializeSession(undefined);
        const chatId: string | undefined = service.getCurrentChatId();
        expect(chatId !== undefined).assertTrue();
        expect(chatId!.length > 0).assertTrue();
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const chat: Chat | null = await chatRepo.getById(chatId!);
        expect(chat !== null).assertTrue();
        expect(chat!.id).assertEqual(chatId);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 7. isSessionReady 正确
    it('isSessionReady_transitions_correctly', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const service: ChatService = createChatService(new MockModelService(), ps);
        expect(service.isSessionReady()).assertFalse();
        await service.initializeSession(undefined);
        expect(service.isSessionReady()).assertTrue();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 8. sendMessage 持久化 User + Streaming Assistant
    it('sendMessage_persists_user_and_assistant', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, ps);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        const chatId: string = service.getCurrentChatId()!;
        await service.sendMessage('Hello DB', cb);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        expect(await msgRepo.countByChatId(chatId)).assertEqual(2);
        const dbMsgs: ChatMessage[] = await msgRepo.listByChat(chatId);
        expect(dbMsgs.length).assertEqual(2);
        expect(dbMsgs[0].role).assertEqual(ChatRole.User);
        expect(dbMsgs[0].content).assertEqual('Hello DB');
        expect(dbMsgs[1].role).assertEqual(ChatRole.Assistant);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 9. sendMessage 持久化失败时不启动网络请求
    it('sendMessage_persist_failure_no_network', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: FailingPersistenceService = new FailingPersistenceService(helper);
        ps.failAppend = true;
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, ps);
        const col: CallbackCollector = createCollector();
        const cb: ChatServiceCallbacks = createCallbacks(col);
        await service.initializeSession(undefined);
        await service.sendMessage('test', cb);
        expect(mockMs.streamChatCallCount).assertEqual(0);
        expect(col.states.indexOf(ChatState.Failed) >= 0).assertTrue();
        expect(col.errors.length > 0).assertTrue();
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = service.getCurrentChatId()!;
        expect(await msgRepo.countByChatId(chatId)).assertEqual(0);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 10. regenerateLastResponse 持久化并重启流
    it('regenerate_persists_and_restarts_stream', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, ps);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        await service.sendMessage('first', cb);
        mockMs.fireDelta('reply1', 0);
        mockMs.fireCompleteWithContent('reply1');
        expect(mockMs.streamChatCallCount).assertEqual(1);
        expect(service.canRegenerate()).assertTrue();
        await service.regenerateLastResponse(cb);
        expect(mockMs.streamChatCallCount).assertEqual(2);
        mockMs.fireCompleteWithContent('reply2');
        const msgs: ChatMessage[] = service.getMessages();
        expect(msgs.length).assertEqual(2);
        expect(msgs[0].role).assertEqual(ChatRole.User);
        expect(msgs[1].role).assertEqual(ChatRole.Assistant);
        expect(msgs[1].content).assertEqual('reply2');
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 11. regenerateLastResponse 持久化失败时不启动网络请求
    it('regenerate_persist_failure_no_network', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: FailingPersistenceService = new FailingPersistenceService(helper);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, ps);
        const col: CallbackCollector = createCollector();
        const cb: ChatServiceCallbacks = createCallbacks(col);
        await service.initializeSession(undefined);
        await service.sendMessage('first', cb);
        mockMs.fireDelta('reply1', 0);
        mockMs.fireCompleteWithContent('reply1');
        expect(mockMs.streamChatCallCount).assertEqual(1);
        ps.failReplace = true;
        await service.regenerateLastResponse(cb);
        expect(mockMs.streamChatCallCount).assertEqual(1);
        expect(col.states.indexOf(ChatState.Failed) >= 0).assertTrue();
        expect(col.errors.length > 0).assertTrue();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 12. stopGeneration 后 state=Cancelled
    it('stopGeneration_sets_cancelled_state', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, ps);
        const col: CallbackCollector = createCollector();
        const cb: ChatServiceCallbacks = createCallbacks(col);
        await service.initializeSession(undefined);
        await service.sendMessage('test', cb);
        mockMs.fireDelta('partial', 0);
        service.stopGeneration();
        expect(col.states.indexOf(ChatState.Cancelled) >= 0).assertTrue();
        expect(service.isGenerating()).assertFalse();
        const msgs: ChatMessage[] = service.getMessages();
        expect(msgs.length).assertEqual(2);
        expect(msgs[1].status).assertEqual(ChatMessageStatus.Cancelled);
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 13. dispose 清理 persistenceTimer,后续 sendMessage 抛错
    it('dispose_clears_persistence_timer', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, ps);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        await service.sendMessage('test', cb);
        mockMs.fireDelta('partial content', 0);
        service.dispose();
        let threw: boolean = false;
        try {
          await service.sendMessage('after dispose', cb);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 14. messages 始终是新数组引用
    it('messages_always_new_array_reference', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, ps);
        const refs: ChatMessage[][] = [];
        const cb: ChatServiceCallbacks = {
          onMessagesChanged: (msgs: ChatMessage[]): void => { refs.push(msgs); },
          onStateChanged: (_state: ChatState): void => {},
          onError: (_msg: string): void => {}
        };
        await service.initializeSession(undefined);
        await service.sendMessage('test', cb);
        mockMs.fireDelta('A', 0);
        mockMs.fireCompleteWithContent('A');
        expect(refs.length >= 3).assertTrue();
        let allDifferent: boolean = true;
        for (let i = 1; i < refs.length; i++) {
          if (refs[i] === refs[i - 1]) {
            allDifferent = false;
            break;
          }
        }
        expect(allDifferent).assertTrue();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 15. firstMessage 通过 createSessionWithFirstMessage 持久化
    it('firstMessage_persisted_via_createSessionWithFirstMessage', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const service: ChatService = createChatService(new MockModelService(), ps);
        const character: Character = makeCharacter(uniqueId('char'), 'Alice', 'Hello there!');
        await service.initializeSession(character);
        const chatId: string = service.getCurrentChatId()!;
        const msgRepo: MessageRepository = new MessageRepository(helper);
        expect(await msgRepo.countByChatId(chatId)).assertEqual(1);
        const dbMsgs: ChatMessage[] = await msgRepo.listByChat(chatId);
        expect(dbMsgs[0].role).assertEqual(ChatRole.Assistant);
        expect(dbMsgs[0].content).assertEqual('Hello there!');
        const msgs: ChatMessage[] = service.getMessages();
        expect(msgs.length).assertEqual(1);
        expect(msgs[0].content).assertEqual('Hello there!');
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 16. 普通 Chat 与角色 Chat 隔离
    it('character_chats_are_isolated', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const charA: Character = makeCharacter(uniqueId('char'), 'Alice', 'Hi from A');
        const charB: Character = makeCharacter(uniqueId('char'), 'Bob', 'Hi from B');
        const svcA: ChatService = createChatService(new MockModelService(), ps);
        await svcA.initializeSession(charA);
        const chatIdA: string = svcA.getCurrentChatId()!;
        await svcA.sendMessage('msg to A', emptyCallbacks());
        svcA.dispose();
        const svcB: ChatService = createChatService(new MockModelService(), ps);
        await svcB.initializeSession(charB);
        const chatIdB: string = svcB.getCurrentChatId()!;
        expect(chatIdA !== chatIdB).assertTrue();
        const bMsgs: ChatMessage[] = svcB.getMessages();
        expect(bMsgs.length).assertEqual(1);
        expect(bMsgs[0].content).assertEqual('Hi from B');
        svcB.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 17. initContext 兼容旧路径(无 persistenceService)
    it('initContext_legacy_path_without_persistence', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, null);
        const character: Character = makeCharacter(uniqueId('char'), 'Alice', 'Greeting!');
        const added: boolean = service.initContext(character);
        expect(added).assertTrue();
        const msgs: ChatMessage[] = service.getMessages();
        expect(msgs.length).assertEqual(1);
        expect(msgs[0].role).assertEqual(ChatRole.Assistant);
        expect(msgs[0].content).assertEqual('Greeting!');
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 18. initializeSession 失败抛出错误
    it('initializeSession_failure_throws', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: FailingPersistenceService = new FailingPersistenceService(helper);
        ps.failOpenLatest = true;
        const service: ChatService = createChatService(new MockModelService(), ps);
        let threw: boolean = false;
        let errMsg: string = '';
        try {
          await service.initializeSession(undefined);
        } catch (e) {
          threw = true;
          errMsg = e instanceof Error ? e.message : String(e);
        }
        expect(threw).assertTrue();
        expect(errMsg.indexOf('会话初始化失败') >= 0).assertTrue();
        expect(service.isSessionReady()).assertFalse();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 19. canRegenerate 在 Completed 状态为 true
    it('canRegenerate_true_when_completed', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, ps);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        expect(service.canRegenerate()).assertFalse();
        await service.sendMessage('test', cb);
        mockMs.fireCompleteWithContent('reply');
        expect(service.canRegenerate()).assertTrue();
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // 20. getMessages 返回副本
    it('getMessages_returns_copy', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const ps: ChatPersistenceService = makePersistenceService(helper);
        const mockMs: MockModelService = new MockModelService();
        const service: ChatService = createChatService(mockMs, ps);
        const cb: ChatServiceCallbacks = createCallbacks(createCollector());
        await service.initializeSession(undefined);
        await service.sendMessage('test', cb);
        mockMs.fireCompleteWithContent('reply');
        const msgs1: ChatMessage[] = service.getMessages();
        const originalLen: number = msgs1.length;
        msgs1.push(makeMessage(uniqueId('hack'), ChatRole.User, 'injected'));
        msgs1[0] = makeMessage('tampered', ChatRole.System, 'tampered');
        const msgs2: ChatMessage[] = service.getMessages();
        expect(msgs2.length).assertEqual(originalLen);
        expect(msgs2[0].role).assertEqual(ChatRole.User);
        expect(msgs2[0].content).assertEqual('test');
        service.dispose();
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
