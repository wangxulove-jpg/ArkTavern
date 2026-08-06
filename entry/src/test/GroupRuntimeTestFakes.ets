/**
 * GroupRuntimeTestFakes 多人 Runtime 本地单元测试共享 Fake
 *
 * 用途:
 * - 为 GroupRuntimeRegistry / GroupRoundCoordinator / GroupChatRuntimeService /
 *   GroupConversationMessageService / GroupConversationPersistenceService /
 *   ChatPersistenceOperations 的本地单元测试提供可控边界依赖。
 *
 * 原则:
 * - 不复制生产算法,只替换边界依赖(ModelService / MessageService /
 *   PersistenceService / Repository / DbHelper / PromptAssembler / CharacterService)
 * - 支持调用计数、abort 计数、手动触发 onStart/onDelta/onComplete/onError
 * - abort 后仍可模拟迟到回调
 * - 每个测试创建新实例,不依赖全局残留状态
 *
 * 安全:
 * - 不含 API Key / Authorization / Base URL
 * - 测试正文使用固定无敏感 fixture(delta-a / delta-b / complete-value)
 */

import { ChatMessage, ChatMessageStatus, mergeChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import { Chat } from '../main/ets/models/Chat';
import { ChatParticipant } from '../main/ets/models/ChatParticipant';
import { Character } from '../main/ets/models/Character';
import { ConversationMode } from '../main/ets/models/ConversationMode';
import { ChatRequestOptions } from '../main/ets/models/ChatRequest';
import { ProviderConfig } from '../main/ets/models/ProviderConfig';
import { ProviderType } from '../main/ets/models/ProviderType';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState,
  ChatDelta,
  ChatStreamResult
} from '../main/ets/models/ChatStreamTypes';
import { NetworkError, NetworkErrorType, createNetworkError } from '../main/ets/models/NetworkError';
import { MessageSenderType, MessageVisibility } from '../main/ets/models/ChatMessage';
import { EffectiveGenerationSettings } from '../main/ets/services/PromptPresetRuntimeResolver';
import { GroupPromptAssemblyResult } from '../main/ets/services/groupchat/GroupPromptAssembler';
import { GroupRoundState } from '../main/ets/services/groupchat/GroupRoundTypes';

// ===== 可控 Promise =====

/**
 * 可控 Promise。测试显式调用 resolve / reject 推进异步流程。
 */
export class Deferred<T> {
  private resolver: ((value: T) => void) | null = null;
  private rejector: ((reason: Object) => void) | null = null;
  private inner: Promise<T>;
  private completed: boolean = false;

  constructor() {
    this.inner = new Promise<T>((resolve: (v: T) => void, reject: (r: Object) => void): void => {
      this.resolver = resolve;
      this.rejector = reject;
    });
  }

  get promise(): Promise<T> {
    return this.inner;
  }

  isSettled(): boolean {
    return this.completed;
  }

  resolve(value: T): void {
    if (!this.completed && this.resolver !== null) {
      this.completed = true;
      this.resolver(value);
    }
  }

  reject(reason: Object): void {
    if (!this.completed && this.rejector !== null) {
      this.completed = true;
      this.rejector(reason);
    }
  }
}

/** 让微任务队列 flush(多个 setTimeout 周期,确保 async 链完整推进)。 */
export async function flushMicrotasks(): Promise<void> {
  for (let i = 0; i < 5; i++) {
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 0);
    });
  }
}

// ===== 可控 Stream Handle =====

/**
 * 可控流式句柄。abort 只计数,不触发 onError(Cancelled),
 * 由调用方(runtime 测试)决定何时模拟迟到回调。
 */
export class FakeStreamHandle {
  abortCount: number = 0;
  aborted: boolean = false;
  state: ChatStreamState = ChatStreamState.Streaming;
  callbacks: ChatStreamCallbacks | null = null;

  abort(): void {
    this.abortCount++;
    this.aborted = true;
    this.state = ChatStreamState.Cancelled;
  }

  getState(): ChatStreamState {
    return this.state;
  }
}

/** 记录一次流式请求(回调 + 句柄)。 */
export interface FakeStreamRecord {
  readonly callbacks: ChatStreamCallbacks;
  readonly handle: FakeStreamHandle;
  readonly messages: ChatMessage[];
  readonly options: ChatRequestOptions;
}

// ===== Fake ModelService =====

/**
 * Fake ModelService。实现 GroupChatRuntimeService 调用的:
 * getCurrentConfig / streamChatWithConfig / streamCurrentChat。
 * 记录全部流式请求,支持对指定序号流触发 delta/complete/error。
 */
export class FakeModelService {
  streamCallCount: number = 0;
  currentConfig: ProviderConfig | null = null;
  private streamRecords: FakeStreamRecord[] = [];

  reset(): void {
    this.streamCallCount = 0;
    this.currentConfig = null;
    this.streamRecords = [];
  }

  getCurrentConfig(): ProviderConfig | null {
    return this.currentConfig;
  }

  streamChatWithConfig(
    _config: ProviderConfig,
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    return this.openStream(messages, options, callbacks);
  }

  streamCurrentChat(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    return this.openStream(messages, options, callbacks);
  }

  private openStream(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    this.streamCallCount++;
    const handle: FakeStreamHandle = new FakeStreamHandle();
    handle.callbacks = callbacks;
    this.streamRecords.push({
      callbacks: callbacks,
      handle: handle,
      messages: messages,
      options: options
    });
    return handle as Object as ChatStreamHandle;
  }

  streamCount(): number {
    return this.streamRecords.length;
  }

  recordAt(index: number): FakeStreamRecord {
    return this.streamRecords[index];
  }

  lastRecord(): FakeStreamRecord {
    return this.streamRecords[this.streamRecords.length - 1];
  }

  fireDeltaAt(index: number, content: string): void {
    const rec: FakeStreamRecord = this.streamRecords[index];
    const delta: ChatDelta = {
      content: content,
      accumulatedContent: undefined,
      finishReason: undefined,
      sequence: 0
    };
    rec.callbacks.onDelta(delta);
  }

  fireDeltaOnLast(content: string): void {
    this.fireDeltaAt(this.streamRecords.length - 1, content);
  }

  fireCompleteAt(index: number, content: string): void {
    const rec: FakeStreamRecord = this.streamRecords[index];
    const result: ChatStreamResult = {
      content: content,
      finishReason: 'stop',
      model: 'mock-model',
      chunkCount: 1,
      eventCount: 1,
      deltaCount: content.length > 0 ? 1 : 0,
      receivedDone: true
    };
    rec.callbacks.onComplete(result);
  }

  fireCompleteOnLast(content: string): void {
    this.fireCompleteAt(this.streamRecords.length - 1, content);
  }

  fireErrorAt(index: number, type: NetworkErrorType, message: string): void {
    const rec: FakeStreamRecord = this.streamRecords[index];
    const error: NetworkError = createNetworkError(type, message);
    rec.callbacks.onError(error);
  }

  fireErrorOnLast(type: NetworkErrorType, message: string): void {
    this.fireErrorAt(this.streamRecords.length - 1, type, message);
  }

  /** abort 后继续模拟迟到回调(验证隔离)。 */
  fireLateDeltaAt(index: number, content: string): void {
    this.fireDeltaAt(index, content);
  }

  fireLateCompleteAt(index: number, content: string): void {
    this.fireCompleteAt(index, content);
  }

  fireLateErrorAt(index: number, type: NetworkErrorType, message: string): void {
    this.fireErrorAt(index, type, message);
  }
}

// ===== Fake GroupConversationMessageService =====

/**
 * Fake 多人消息服务。行为与真实服务一致的关键点:
 * - appendStreamingAssistantMessage 创建 Streaming 消息并返回
 * - finalizeAssistantMessageIfTerminal 仅当当前状态为 Streaming 才终结
 * - listMessages 按插入顺序返回
 */
export class FakeGroupMessageService {
  private chatMessages: Map<string, ChatMessage[]> = new Map();
  private byId: Map<string, ChatMessage> = new Map();
  listMessagesCallCount: number = 0;
  appendCallCount: number = 0;
  updateStreamingCount: number = 0;
  finalizeCallCount: number = 0;
  recoverCallCount: number = 0;
  getByIdCallCount: number = 0;
  getChatIdCallCount: number = 0;
  private msgSeq: number = 0;
  failAppend: boolean = false;
  failListMessages: boolean = false;

  reset(): void {
    this.chatMessages.clear();
    this.byId.clear();
    this.listMessagesCallCount = 0;
    this.appendCallCount = 0;
    this.updateStreamingCount = 0;
    this.finalizeCallCount = 0;
    this.recoverCallCount = 0;
    this.getByIdCallCount = 0;
    this.getChatIdCallCount = 0;
    this.msgSeq = 0;
    this.failAppend = false;
    this.failListMessages = false;
  }

  setHistory(chatId: string, messages: ChatMessage[]): void {
    this.chatMessages.set(chatId, messages.slice());
    for (let i = 0; i < messages.length; i++) {
      this.byId.set(messages[i].id, messages[i]);
    }
  }

  async listMessages(chatId: string): Promise<ChatMessage[]> {
    this.listMessagesCallCount++;
    if (this.failListMessages) {
      throw new Error('mock listMessages failed');
    }
    const list: ChatMessage[] = this.chatMessages.get(chatId) ?? [];
    return list.slice();
  }

  async appendStreamingAssistantMessage(
    chatId: string,
    characterId: string,
    generationBatchId: string
  ): Promise<ChatMessage> {
    this.appendCallCount++;
    if (this.failAppend) {
      throw new Error('mock append failed');
    }
    this.msgSeq++;
    const msg: ChatMessage = makeGroupAssistantMessage(
      'aid-' + this.msgSeq.toString(),
      characterId,
      generationBatchId,
      ChatMessageStatus.Streaming,
      '',
      chatId
    );
    this.store(chatId, msg);
    return msg;
  }

  async updateStreamingAssistantMessage(messageId: string, content: string): Promise<void> {
    this.updateStreamingCount++;
    const existing: ChatMessage | null = this.byId.get(messageId) ?? null;
    if (existing !== null) {
      this.byId.set(messageId, mergeChatMessage(existing, {
        content: content,
        updatedAt: 2000
      }));
    }
  }

  async finalizeAssistantMessageIfTerminal(
    messageId: string,
    content: string,
    status: ChatMessageStatus,
    _errorMessage?: string
  ): Promise<boolean> {
    this.finalizeCallCount++;
    const existing: ChatMessage | null = this.byId.get(messageId) ?? null;
    if (existing === null || existing.status !== ChatMessageStatus.Streaming) {
      return false;
    }
    const updated: ChatMessage = mergeChatMessage(existing, {
      content: content,
      status: status,
      isStreaming: false,
      updatedAt: 2000
    });
    this.byId.set(messageId, updated);
    // 同步 chatMessages 中的引用
    const chatId: string = existing.generationBatchId !== undefined ? 'chat-group-a' : 'chat-group-a';
    const list: ChatMessage[] = this.chatMessages.get(chatId) ?? [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === messageId) {
        list[i] = updated;
        break;
      }
    }
    this.chatMessages.set(chatId, list);
    return true;
  }

  async getMessageById(messageId: string): Promise<ChatMessage | null> {
    this.getByIdCallCount++;
    return this.byId.get(messageId) ?? null;
  }

  async getChatIdByMessageId(messageId: string): Promise<string | null> {
    this.getChatIdCallCount++;
    const m: ChatMessage | null = this.byId.get(messageId) ?? null;
    return m !== null ? 'chat-group-a' : null;
  }

  async recoverInterruptedMessages(_chatId: string): Promise<number> {
    this.recoverCallCount++;
    return 0;
  }

  /** 获取当前存储的消息状态(测试断言用)。 */
  getStatus(messageId: string): ChatMessageStatus | undefined {
    const m: ChatMessage | null = this.byId.get(messageId) ?? null;
    return m !== null && m !== undefined ? m.status : undefined;
  }

  getContent(messageId: string): string {
    const m: ChatMessage | null = this.byId.get(messageId) ?? null;
    return m !== null ? m.content : '';
  }

  getMessages(chatId: string): ChatMessage[] {
    const list: ChatMessage[] = this.chatMessages.get(chatId) ?? [];
    return list.slice();
  }

  private store(chatId: string, msg: ChatMessage): void {
    const list: ChatMessage[] = this.chatMessages.get(chatId) ?? [];
    list.push(msg);
    this.chatMessages.set(chatId, list);
    this.byId.set(msg.id, msg);
  }
}

// ===== Fake GroupConversationPersistenceService(Coordinator 使用) =====

/**
 * Fake 群聊持久化服务(供 GroupRoundCoordinator / MUT / DEL 测试)。
 * 实现 Coordinator 调用的 listGroupConversations / getParticipants。
 */
export class FakeGroupPersistenceService {
  chats: Chat[] = [];
  participantsByChat: Map<string, ChatParticipant[]> = new Map();
  listChatsCallCount: number = 0;
  getParticipantsCallCount: number = 0;

  reset(): void {
    this.chats = [];
    this.participantsByChat.clear();
    this.listChatsCallCount = 0;
    this.getParticipantsCallCount = 0;
  }

  async listGroupConversations(): Promise<Chat[]> {
    this.listChatsCallCount++;
    return this.chats.slice();
  }

  async getParticipants(chatId: string): Promise<ChatParticipant[]> {
    this.getParticipantsCallCount++;
    const list: ChatParticipant[] = this.participantsByChat.get(chatId) ?? [];
    return list.slice();
  }
}

// ===== Fake CharacterService =====

/**
 * Fake 角色服务。Coordinator 通过 getById 校验角色存在。
 */
export class FakeCharacterService {
  characters: Map<string, Character> = new Map();
  getByIdCallCount: number = 0;

  reset(): void {
    this.characters.clear();
    this.getByIdCallCount = 0;
  }

  async getById(characterId: string): Promise<Character | null> {
    this.getByIdCallCount++;
    return this.characters.get(characterId) ?? null;
  }
}

// ===== Fake PromptAssembler =====

/** assemble 上下文形状(Fake 用,字段与 GroupPromptAssemblyContext 一致)。 */
export interface FakeAssemblyContext {
  chatId: string;
  roundId: string;
  speakerCharacterId: string;
  participantCharacterIds: string[];
  messages: ChatMessage[];
  replyTarget?: Object;
}

/**
 * Fake 群聊 Prompt 构建器。记录每次 assemble 的 speakerCharacterId。
 */
export class FakePromptAssembler {
  lastSpeakerCharacterId: string = '';
  assembleCallCount: number = 0;
  failAssemble: boolean = false;
  characters: Map<string, Character> = new Map();

  reset(): void {
    this.lastSpeakerCharacterId = '';
    this.assembleCallCount = 0;
    this.failAssemble = false;
    this.characters.clear();
  }

  async assemble(context: FakeAssemblyContext): Promise<GroupPromptAssemblyResult> {
    this.assembleCallCount++;
    this.lastSpeakerCharacterId = context.speakerCharacterId;
    if (this.failAssemble) {
      throw new Error('mock assemble failed');
    }
    const character: Character | null = this.characters.get(context.speakerCharacterId) ?? null;
    const settings: EffectiveGenerationSettings = {
      temperature: 0.7,
      topP: 1.0,
      maxOutputTokens: 128,
      contextWindow: 8192
    };
    return {
      requestMessages: context.messages.slice(),
      character: character,
      presetSystemPrompt: '',
      effectiveSettings: settings,
      estimatedTokens: 100,
      matchedLorebookCount: 0,
      preTrimMessageCount: context.messages.length,
      postTrimMessageCount: context.messages.length,
      availableInputTokens: 6144,
      groupConstraintText: '',
      participantNames: [],
      replyTargetMode: 'all_enabled'
    };
  }
}

// ===== Runtime 回调收集器 =====

/** Speaker 开始/完成回调信息。 */
export interface SpeakerCallbackInfo {
  characterId: string;
  index: number;
}

/** 消息更新回调信息。 */
export interface MessageUpdateInfo {
  messageId: string;
  status: ChatMessageStatus;
  content: string;
}

/** 失败回调信息。 */
export interface RoundFailedInfo {
  characterId: string;
  message: string;
}

/**
 * 收集 GroupRuntimeCallbacks 全部回调,用于断言回调次数与顺序。
 */
export interface RuntimeCallbackLog {
  states: GroupRoundState[];
  speakerStarted: SpeakerCallbackInfo[];
  speakerCompleted: SpeakerCallbackInfo[];
  messageCreated: ChatMessage[];
  messageUpdated: MessageUpdateInfo[];
  roundCompleted: number;
  roundCancelled: number;
  roundFailed: RoundFailedInfo[];
}

export function createRuntimeCallbackLog(): RuntimeCallbackLog {
  return {
    states: [],
    speakerStarted: [],
    speakerCompleted: [],
    messageCreated: [],
    messageUpdated: [],
    roundCompleted: 0,
    roundCancelled: 0,
    roundFailed: []
  };
}

// ===== Fake DbHelper / RdbStore(MessageService / Persistence 使用) =====

/**
 * 可控 RdbStore。记录 update 调用与写入的 status/content。
 * 可选绑定 FakeMessageRepository:update 写入 status 时同步更新消息仓库(模拟真实 DB 行更新)。
 */
export class FakeRdbStore {
  updateCallCount: number = 0;
  lastStatusWritten: string = '';
  lastContentWritten: string = '';
  affectedRows: number = 1;
  failUpdate: boolean = false;
  beginCount: number = 0;
  commitCount: number = 0;
  rollbackCount: number = 0;
  messageRepo: FakeMessageRepository | null = null;

  attachMessageRepo(repo: FakeMessageRepository): void {
    this.messageRepo = repo;
  }

  update(bucket: Record<string, Object>, _predicates: Object): Promise<number> {
    this.updateCallCount++;
    const status: Object | undefined = bucket['status'];
    if (status !== undefined) {
      this.lastStatusWritten = String(status);
      // 同步消息仓库:把当前 Streaming 的消息终结为写入的 status(对应真实 DB 行更新)
      if (this.messageRepo !== null) {
        const statusStr: string = String(status);
        let mapped: ChatMessageStatus = ChatMessageStatus.Completed;
        if (statusStr === 'cancelled') {
          mapped = ChatMessageStatus.Cancelled;
        } else if (statusStr === 'failed') {
          mapped = ChatMessageStatus.Failed;
        }
        const contentStr: string = String(bucket['content'] ?? '');
        this.messageRepo.finalizeStreaming(mapped, contentStr);
      }
    }
    const content: Object | undefined = bucket['content'];
    if (content !== undefined) {
      this.lastContentWritten = String(content);
    }
    if (this.failUpdate) {
      return Promise.reject(new Error('mock store update failed'));
    }
    return Promise.resolve(this.affectedRows);
  }

  beginTransaction(): void {
    this.beginCount++;
  }

  commit(): void {
    this.commitCount++;
  }

  rollBack(): void {
    this.rollbackCount++;
  }
}

/**
 * Fake DbHelper。runInTransaction 直接执行回调(不模拟真实事务回滚;
 * 真实事务语义在 ohosTest 中验证)。
 */
export class FakeDbHelper {
  store: FakeRdbStore;
  failTransaction: boolean = false;

  constructor(store: FakeRdbStore) {
    this.store = store;
  }

  getStore(): Object {
    return this.store;
  }

  async runInTransaction(
    action: (store: Object) => Promise<void>,
    _operation?: string
  ): Promise<void> {
    if (this.failTransaction) {
      throw new Error('mock transaction begin failed');
    }
    await action(this.store);
  }
}

// ===== Fake Repository(MessageService 使用) =====

/**
 * Fake ChatRepository。getById 返回预置 Chat(用于 group 模式校验)。
 */
export class FakeChatRepository {
  chatById: Map<string, Chat> = new Map();
  getByIdCallCount: number = 0;
  removeWithStoreCallCount: number = 0;

  reset(): void {
    this.chatById.clear();
    this.getByIdCallCount = 0;
    this.removeWithStoreCallCount = 0;
  }

  async getById(id: string): Promise<Chat | null> {
    this.getByIdCallCount++;
    return this.chatById.get(id) ?? null;
  }

  async listGroupChats(): Promise<Chat[]> {
    const result: Chat[] = [];
    this.chatById.forEach((chat: Chat): void => {
      if (chat.conversationMode === ConversationMode.Group) {
        result.push(chat);
      }
    });
    return result;
  }

  async removeWithStore(_store: Object, _id: string): Promise<void> {
    this.removeWithStoreCallCount++;
  }
}

/**
 * Fake MessageRepository。getById / normalizeInterruptedMessages 可控。
 */
export class FakeMessageRepository {
  messageById: Map<string, ChatMessage> = new Map();
  normalizeCallCount: number = 0;
  normalizeResult: number = 0;
  removeByChatIdCallCount: number = 0;

  reset(): void {
    this.messageById.clear();
    this.normalizeCallCount = 0;
    this.normalizeResult = 0;
    this.removeByChatIdCallCount = 0;
  }

  async getById(id: string): Promise<ChatMessage | null> {
    return this.messageById.get(id) ?? null;
  }

  /** 终结当前 Streaming 消息为指定终态(由 FakeRdbStore.update 同步调用)。 */
  finalizeStreaming(status: ChatMessageStatus, content: string): void {
    const ids: string[] = Array.from(this.messageById.keys());
    for (let i = 0; i < ids.length; i++) {
      const m: ChatMessage | null = this.messageById.get(ids[i]) ?? null;
      if (m !== null && m.status === ChatMessageStatus.Streaming) {
        this.messageById.set(ids[i], mergeChatMessage(m, {
          content: content,
          status: status,
          isStreaming: false
        }));
      }
    }
  }

  async normalizeInterruptedMessages(_chatId: string): Promise<number> {
    this.normalizeCallCount++;
    return this.normalizeResult;
  }

  async removeByChatIdWithStore(_store: Object, _chatId: string): Promise<void> {
    this.removeByChatIdCallCount++;
  }
}

/** Fake SwipeRepository(删除链使用)。 */
export class FakeSwipeRepository {
  removeByChatIdCallCount: number = 0;
  async removeByChatIdWithStore(_store: Object, _chatId: string): Promise<void> {
    this.removeByChatIdCallCount++;
  }
}

/** Fake CharacterRepository(getById)。 */
export class FakeCharacterRepository {
  characterById: Map<string, Character> = new Map();
  getByIdCallCount: number = 0;

  async getById(id: string): Promise<Character | null> {
    this.getByIdCallCount++;
    return this.characterById.get(id) ?? null;
  }
}

/** Fake ChatPersistenceOperations(供 PersistenceService 删除)。 */
export class FakeChatPersistenceOperations {
  removeChatWithMessagesCallCount: number = 0;
  failDelete: boolean = false;

  async removeChatWithMessages(chatId: string): Promise<void> {
    this.removeChatWithMessagesCallCount++;
    if (this.failDelete) {
      throw new Error('mock delete failed');
    }
  }
}

// ===== Fake ParticipantRepository(PersistenceService / Delete 链使用) =====

/**
 * Fake ChatParticipantRepository。listByChatId 返回预置参与者。
 */
export class FakeParticipantRepository {
  participantsByChat: Map<string, ChatParticipant[]> = new Map();
  listCallCount: number = 0;
  insertManyCallCount: number = 0;
  replaceAllCallCount: number = 0;
  deleteByChatCallCount: number = 0;

  reset(): void {
    this.participantsByChat.clear();
    this.listCallCount = 0;
    this.insertManyCallCount = 0;
    this.replaceAllCallCount = 0;
    this.deleteByChatCallCount = 0;
  }

  async listByChatId(chatId: string): Promise<ChatParticipant[]> {
    this.listCallCount++;
    const list: ChatParticipant[] = this.participantsByChat.get(chatId) ?? [];
    return list.slice();
  }

  async insertManyWithStore(_store: Object, _participants: ChatParticipant[]): Promise<void> {
    this.insertManyCallCount++;
  }

  async replaceAllWithStore(
    _store: Object,
    _chatId: string,
    _participants: ChatParticipant[]
  ): Promise<void> {
    this.replaceAllCallCount++;
  }

  async deleteByChatIdWithStore(_store: Object, _chatId: string): Promise<void> {
    this.deleteByChatCallCount++;
  }
}

// ===== Fake 删除链依赖(ChatPersistenceOperations) =====

/** 记录某 WithStore 删除方法是否被调用(删除链各依赖共用)。 */
export class FakeDeleteDeps {
  callCount: number = 0;
  throwOnDelete: boolean = false;

  reset(): void {
    this.callCount = 0;
    this.throwOnDelete = false;
  }

  async removeByChatIdWithStore(_store: Object, _chatId: string): Promise<void> {
    this.callCount++;
    if (this.throwOnDelete) {
      throw new Error('mock delete failed');
    }
  }

  async deleteByGroupWithStore(_store: Object, _chatId: string): Promise<void> {
    this.callCount++;
    if (this.throwOnDelete) {
      throw new Error('mock delete failed');
    }
  }
}

/**
 * 组装删除链 Fake 集合,便于按序断言调用范围。
 */
export class FakeDeleteChain {
  branch = new FakeDeleteDeps();
  memory = new FakeDeleteDeps();
  swipe = new FakeDeleteDeps();
  message = new FakeDeleteDeps();
  groupMemory = new FakeDeleteDeps();
  groupRelMemory = new FakeDeleteDeps();
  participant = new FakeParticipantRepository();
  chat = new FakeChatRepository();

  reset(): void {
    this.branch.reset();
    this.memory.reset();
    this.swipe.reset();
    this.message.reset();
    this.groupMemory.reset();
    this.groupRelMemory.reset();
    this.participant.reset();
    this.chat.reset();
  }
}

// ===== Fixture 工厂 =====

export const CHAT_A: string = 'chat-group-a';
export const CHAT_B: string = 'chat-group-b';

export function makeGroupChat(id: string, title: string = 'test'): Chat {
  return {
    id: id,
    characterId: undefined,
    title: title,
    createdAt: 1000,
    updatedAt: 1000,
    lastMessageAt: 0,
    isArchived: false,
    userNameOverride: '',
    sortOrder: 0,
    conversationMode: ConversationMode.Group
  };
}

export function makeParticipant(
  chatId: string,
  characterId: string,
  speakerOrder: number,
  isEnabled: boolean = true
): ChatParticipant {
  return {
    chatId: chatId,
    characterId: characterId,
    speakerOrder: speakerOrder,
    isEnabled: isEnabled,
    createdAt: 1000,
    updatedAt: 1000
  };
}

export function makeCharacter(id: string, name: string): Character {
  return {
    id: id,
    name: name,
    description: 'test-desc',
    personality: '',
    scenario: '',
    firstMessage: '',
    systemPrompt: '',
    avatarUri: '',
    mesExample: '',
    creatorNotes: '',
    postHistoryInstructions: '',
    alternateGreetings: [],
    tags: [],
    creator: '',
    characterVersion: '',
    extensions: {},
    characterBookId: '',
    userName: '',
    sortOrder: 0,
    createdAt: 1000,
    updatedAt: 1000
  };
}

export function makeGroupUserMessage(
  id: string,
  content: string,
  generationBatchId: string,
  replyTargetCharacterIds?: string[]
): ChatMessage {
  return {
    id: id,
    role: ChatRole.User,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    isStreaming: false,
    status: ChatMessageStatus.Completed,
    senderType: 'user' as MessageSenderType,
    senderCharacterId: undefined,
    generationBatchId: generationBatchId,
    visibility: 'public' as MessageVisibility,
    replyTargetCharacterIds: replyTargetCharacterIds
  };
}

export function makeGroupAssistantMessage(
  id: string,
  characterId: string,
  generationBatchId: string,
  status: ChatMessageStatus,
  content: string,
  chatId: string = CHAT_A
): ChatMessage {
  return {
    id: id,
    role: ChatRole.Assistant,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    isStreaming: status === ChatMessageStatus.Streaming,
    status: status,
    senderType: 'character' as MessageSenderType,
    senderCharacterId: characterId,
    generationBatchId: generationBatchId,
    visibility: 'public' as MessageVisibility
  };
}

export function makeProviderConfig(): ProviderConfig {
  return new ProviderConfig(
    'cfg-test',
    'test',
    ProviderType.OpenAICompatible,
    'https://mock.local',
    'mock-model',
    0.7,
    1.0,
    1024,
    true,
    true,
    1000,
    1000,
    8192
  );
}

export function makeChatRequestOptions(): ChatRequestOptions {
  return {
    temperature: 0.7,
    topP: 1.0,
    maxTokens: 1024,
    stream: true
  };
}
