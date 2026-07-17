/**
 * MockChatSwipeDeps ChatService Swipe 测试共享 Mock
 *
 * T-6.3 新增测试用的共享 Mock 依赖。
 * 仅存在于 test 目录,不进入 main 代码,不进入 HAP。
 *
 * 提供:
 * - MockSwipeModelService:支持 streamChat、fireDelta/fireComplete/fireError、throwOnStream
 * - MockSwipePersistenceService:候选 CRUD + 调用计数
 * - MockChatPersistenceServiceForSwipe:消息/会话持久化 + 调用计数
 *
 * 安全要求:
 * - 不包含真实 API Key
 * - 不记录请求体原文
 */

import { ChatMessage, ChatMessageStatus } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import { ChatMessageSource } from '../main/ets/models/ChatMessageSource';
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
import { PersistedChatSession } from '../main/ets/models/PersistedChatSession';
import { Chat } from '../main/ets/models/Chat';
import {
  MessageSwipeSummary,
  MessageSwipeState,
  MessageSwipeGroup,
  MessageSwipeCandidate,
  MessageSwipeCandidateUpdates,
  CreateSwipeCandidateOptions,
  createSwipeCandidate,
  updateSwipeCandidate
} from '../main/ets/models/MessageSwipe';
import { nowMillis } from '../main/ets/utils/Time';

// ===== Mock ModelService =====

class ControllableStreamHandle implements ChatStreamHandle {
  aborted: boolean = false;
  state: ChatStreamState = ChatStreamState.Idle;

  abort(): void {
    this.aborted = true;
  }

  getState(): ChatStreamState {
    return this.state;
  }
}

export class MockSwipeModelService {
  streamChatCallCount: number = 0;
  lastMessages: ChatMessage[] | null = null;
  lastOptions: ChatRequestOptions | null = null;
  currentConfig: ProviderConfig | null = null;
  throwOnStream: Error | null = null;
  private pendingCallbacks: ChatStreamCallbacks | null = null;
  private pendingHandle: ControllableStreamHandle | null = null;

  setCurrentConfig(config: ProviderConfig | null): void {
    this.currentConfig = config;
  }

  getCurrentConfig(): ProviderConfig | null {
    return this.currentConfig;
  }

  streamCurrentChat(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    this.streamChatCallCount++;
    this.lastMessages = messages;
    this.lastOptions = options;
    if (this.throwOnStream !== null) {
      throw this.throwOnStream;
    }
    this.pendingCallbacks = callbacks;
    this.pendingHandle = new ControllableStreamHandle();
    this.pendingHandle.state = ChatStreamState.Streaming;
    return this.pendingHandle;
  }

  fireDelta(content: string, sequence: number): void {
    if (this.pendingCallbacks !== null) {
      const delta: ChatDelta = {
        content: content,
        accumulatedContent: undefined,
        finishReason: undefined,
        sequence: sequence
      };
      this.pendingCallbacks.onDelta(delta);
    }
  }

  fireComplete(content: string = ''): void {
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

  reset(): void {
    this.streamChatCallCount = 0;
    this.lastMessages = null;
    this.lastOptions = null;
    this.pendingCallbacks = null;
    this.pendingHandle = null;
    this.throwOnStream = null;
  }
}

// ===== Mock MessageSwipePersistenceService =====

export class MockSwipePersistenceService {
  private groups: Map<string, { group: MessageSwipeGroup; candidates: MessageSwipeCandidate[] }> = new Map();
  private summariesByChatId: Map<string, MessageSwipeSummary[]> = new Map();

  appendCandidateCallCount: number = 0;
  updateCandidateCallCount: number = 0;
  activateCandidateCallCount: number = 0;
  listSwipeSummariesCallCount: number = 0;
  normalizeInterruptedCallCount: number = 0;
  lastAppendedOptions: CreateSwipeCandidateOptions | null = null;
  lastActivatedMessageId: string = '';
  lastActivatedIndex: number = -1;
  lastUpdatedMessageId: string = '';
  lastUpdatedIndex: number = -1;
  lastUpdatedUpdates: MessageSwipeCandidateUpdates | null = null;
  appendShouldFail: boolean = false;

  reset(): void {
    this.groups.clear();
    this.summariesByChatId.clear();
    this.appendCandidateCallCount = 0;
    this.updateCandidateCallCount = 0;
    this.activateCandidateCallCount = 0;
    this.listSwipeSummariesCallCount = 0;
    this.normalizeInterruptedCallCount = 0;
    this.lastAppendedOptions = null;
    this.lastActivatedMessageId = '';
    this.lastActivatedIndex = -1;
    this.lastUpdatedMessageId = '';
    this.lastUpdatedIndex = -1;
    this.lastUpdatedUpdates = null;
    this.appendShouldFail = false;
  }

  setSummariesForChat(chatId: string, summaries: MessageSwipeSummary[]): void {
    this.summariesByChatId.set(chatId, summaries);
  }

  setState(assistantMessageId: string, group: MessageSwipeGroup, candidates: MessageSwipeCandidate[]): void {
    this.groups.set(assistantMessageId, { group: group, candidates: candidates });
  }

  getCandidateCount(assistantMessageId: string): number {
    const state = this.groups.get(assistantMessageId);
    if (state === undefined) {
      return 0;
    }
    return state.candidates.length;
  }

  async listSwipeSummariesByChatId(chatId: string): Promise<MessageSwipeSummary[]> {
    this.listSwipeSummariesCallCount++;
    return this.summariesByChatId.get(chatId)?.slice() ?? [];
  }

  async normalizeInterruptedCandidates(_chatId: string): Promise<number> {
    this.normalizeInterruptedCallCount++;
    return 0;
  }

  async appendCandidate(
    assistantMessageId: string,
    options: CreateSwipeCandidateOptions,
    activate: boolean
  ): Promise<MessageSwipeState> {
    this.appendCandidateCallCount++;
    this.lastAppendedOptions = options;
    if (this.appendShouldFail) {
      throw new Error('appendCandidate mock failed');
    }

    const existing = this.groups.get(assistantMessageId);
    let candidates: MessageSwipeCandidate[];
    let group: MessageSwipeGroup;

    if (existing === undefined) {
      const now: number = nowMillis();
      group = {
        assistantMessageId: assistantMessageId,
        chatId: 'chat-mock',
        activeCandidateIndex: 0,
        createdAt: now,
        updatedAt: now
      };
      candidates = [];
    } else {
      group = existing.group;
      candidates = [...existing.candidates];
    }

    const newIndex: number = candidates.length;
    const candidate: MessageSwipeCandidate = createSwipeCandidate(
      assistantMessageId,
      newIndex,
      {
        content: options.content,
        status: options.status,
        errorMessage: options.errorMessage,
        isStreaming: options.isStreaming,
        createdAt: options.createdAt
      }
    );
    candidates.push(candidate);

    if (activate) {
      group = {
        assistantMessageId: group.assistantMessageId,
        chatId: group.chatId,
        activeCandidateIndex: newIndex,
        createdAt: group.createdAt,
        updatedAt: nowMillis()
      };
    }

    this.groups.set(assistantMessageId, { group: group, candidates: candidates });
    return { group: group, candidates: candidates };
  }

  async updateCandidate(
    assistantMessageId: string,
    candidateIndex: number,
    updates: MessageSwipeCandidateUpdates
  ): Promise<MessageSwipeState> {
    this.updateCandidateCallCount++;
    this.lastUpdatedMessageId = assistantMessageId;
    this.lastUpdatedIndex = candidateIndex;
    this.lastUpdatedUpdates = updates;

    const existing = this.groups.get(assistantMessageId);
    if (existing === undefined) {
      const now: number = nowMillis();
      const group: MessageSwipeGroup = {
        assistantMessageId: assistantMessageId,
        chatId: 'chat-mock',
        activeCandidateIndex: candidateIndex,
        createdAt: now,
        updatedAt: now
      };
      const candidate: MessageSwipeCandidate = createSwipeCandidate(
        assistantMessageId,
        candidateIndex,
        {
          content: updates.content,
          status: updates.status,
          errorMessage: updates.errorMessage,
          isStreaming: updates.isStreaming
        }
      );
      this.groups.set(assistantMessageId, { group: group, candidates: [candidate] });
      return { group: group, candidates: [candidate] };
    }

    const updatedCandidates: MessageSwipeCandidate[] = existing.candidates.map(
      (c: MessageSwipeCandidate): MessageSwipeCandidate => {
        if (c.candidateIndex === candidateIndex) {
          return updateSwipeCandidate(c, updates);
        }
        return c;
      }
    );
    this.groups.set(assistantMessageId, { group: existing.group, candidates: updatedCandidates });
    return { group: existing.group, candidates: updatedCandidates };
  }

  async activateCandidate(
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<MessageSwipeState> {
    this.activateCandidateCallCount++;
    this.lastActivatedMessageId = assistantMessageId;
    this.lastActivatedIndex = candidateIndex;

    const existing = this.groups.get(assistantMessageId);
    if (existing === undefined) {
      const now: number = nowMillis();
      const group: MessageSwipeGroup = {
        assistantMessageId: assistantMessageId,
        chatId: 'chat-mock',
        activeCandidateIndex: candidateIndex,
        createdAt: now,
        updatedAt: now
      };
      this.groups.set(assistantMessageId, { group: group, candidates: [] });
      return { group: group, candidates: [] };
    }

    const updatedGroup: MessageSwipeGroup = {
      assistantMessageId: existing.group.assistantMessageId,
      chatId: existing.group.chatId,
      activeCandidateIndex: candidateIndex,
      createdAt: existing.group.createdAt,
      updatedAt: nowMillis()
    };
    this.groups.set(assistantMessageId, { group: updatedGroup, candidates: existing.candidates });
    return { group: updatedGroup, candidates: existing.candidates };
  }
}

// ===== Mock ChatPersistenceService =====

export class MockChatPersistenceServiceForSwipe {
  private sessions: Map<string, PersistedChatSession> = new Map();
  updateChatTimestampCallCount: number = 0;
  updateMessageCallCount: number = 0;
  updateChatActivityCallCount: number = 0;
  appendUserAndStreamingAssistantCallCount: number = 0;
  createSessionWithFirstMessageCallCount: number = 0;
  openLatestSessionCallCount: number = 0;
  listSessionsForContextCallCount: number = 0;
  deleteSessionCallCount: number = 0;

  reset(): void {
    this.sessions.clear();
    this.updateChatTimestampCallCount = 0;
    this.updateMessageCallCount = 0;
    this.updateChatActivityCallCount = 0;
    this.appendUserAndStreamingAssistantCallCount = 0;
    this.createSessionWithFirstMessageCallCount = 0;
    this.openLatestSessionCallCount = 0;
    this.listSessionsForContextCallCount = 0;
    this.deleteSessionCallCount = 0;
  }

  setSession(chatId: string, messages: ChatMessage[], maxSequenceNumber: number): void {
    this.sessions.set(chatId, {
      chat: {
        id: chatId,
        characterId: undefined,
        title: '',
        createdAt: 1000,
        updatedAt: 1000,
        lastMessageAt: 0,
        isArchived: false
      },
      messages: messages.slice(),
      maxSequenceNumber: maxSequenceNumber
    });
  }

  updateSessionMessages(chatId: string, messages: ChatMessage[]): void {
    const existing = this.sessions.get(chatId);
    if (existing !== undefined) {
      this.sessions.set(chatId, {
        chat: existing.chat,
        messages: messages.slice(),
        maxSequenceNumber: existing.maxSequenceNumber
      });
    }
  }

  async loadSession(chatId: string): Promise<PersistedChatSession | null> {
    return this.sessions.get(chatId) ?? null;
  }

  async updateChatTimestamp(_chatId: string, _timestamp: number): Promise<void> {
    this.updateChatTimestampCallCount++;
  }

  async updateMessage(_chatId: string, _message: ChatMessage): Promise<void> {
    this.updateMessageCallCount++;
  }

  async updateChatActivity(_chatId: string, _timestamp: number): Promise<void> {
    this.updateChatActivityCallCount++;
  }

  async appendUserAndStreamingAssistant(
    _chatId: string,
    _userMsg: ChatMessage,
    _assistantMsg: ChatMessage
  ): Promise<{ assistantSequenceNumber: number }> {
    this.appendUserAndStreamingAssistantCallCount++;
    return { assistantSequenceNumber: 1 };
  }

  async createSessionWithFirstMessage(
    _characterId: string | undefined,
    _title: string | undefined,
    _firstMsg: ChatMessage
  ): Promise<PersistedChatSession> {
    this.createSessionWithFirstMessageCallCount++;
    const chatId: string = 'chat-' + this.createSessionWithFirstMessageCallCount.toString();
    const session: PersistedChatSession = {
      chat: {
        id: chatId,
        characterId: _characterId,
        title: '',
        createdAt: 1000,
        updatedAt: 1000,
        lastMessageAt: 0,
        isArchived: false
      },
      messages: [_firstMsg],
      maxSequenceNumber: 1
    };
    this.sessions.set(chatId, session);
    return session;
  }

  async openLatestSession(_characterId: string | undefined): Promise<PersistedChatSession | null> {
    this.openLatestSessionCallCount++;
    return null;
  }

  async listSessionsForContext(_characterId: string | undefined, _limit: number = 50): Promise<Chat[]> {
    this.listSessionsForContextCallCount++;
    const chats: Chat[] = [];
    this.sessions.forEach((session: PersistedChatSession): void => {
      chats.push(session.chat);
    });
    return chats;
  }

  async deleteSession(_chatId: string): Promise<void> {
    this.deleteSessionCallCount++;
    this.sessions.delete(_chatId);
  }
}

// ===== 辅助工厂 =====

export function makeProviderConfig(contextWindow: number = 32768): ProviderConfig {
  return new ProviderConfig(
    'pcfg-test', 'mock', ProviderType.OpenAICompatible,
    'https://mock.local', 'mock-model',
    0.7, 1.0, 1024,
    true, true, 1000, 1000,
    contextWindow
  );
}

export function makeUserMessage(id: string, content: string): ChatMessage {
  return {
    id: id,
    role: ChatRole.User,
    content: content,
    createdAt: 1000,
    isStreaming: false,
    status: ChatMessageStatus.Completed,
    source: ChatMessageSource.Conversation
  };
}

export function makeAssistantMessage(id: string, content: string): ChatMessage {
  return {
    id: id,
    role: ChatRole.Assistant,
    content: content,
    createdAt: 1000,
    isStreaming: false,
    status: ChatMessageStatus.Completed,
    source: ChatMessageSource.Conversation
  };
}

// ===== 状态收集器 =====

export interface StateCollector {
  messages: ChatMessage[];
  states: number[];
  errors: string[];
}

export function createCollector(): StateCollector {
  return { messages: [], states: [], errors: [] };
}
