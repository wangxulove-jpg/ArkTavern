/**
 * ChatService 聊天服务
 *
 * 管理一次临时对话的消息列表与流式生成生命周期。
 * 页面只通过 ChatViewModel 访问,不直接调用此服务。
 *
 * 设计原则:
 * - 只通过 ModelService 发送请求,不直接操作 Provider/KeyStore/ConfigStore
 * - 不缓存 API Key
 * - 不记录用户消息或模型回复全文到日志
 * - 同一时间只允许一个生成请求
 * - 不依赖 ArkUI 页面实例
 * - 不使用全局单例、不使用 any
 * - 生命周期跟随 ChatPage,dispose 后不可复用
 *
 * 状态机:Idle → Sending → Streaming → Completed/Cancelled/Failed
 * - Completed/Cancelled/Failed 为终态,不可再转换
 * - 迟到回调(delta/complete/error)在终态后忽略
 *
 * 不可变更新:
 * - 每次更新创建新的 ChatMessage 对象和新的 messages 数组
 * - 不原地修改数组元素
 * - 回调始终传递新数组副本
 */

import { ModelService } from './ModelService';
import { LorebookService } from './LorebookService';
import { PromptBuilder, PromptBuildContext, PromptBuildResult } from './PromptBuilder';
import { TokenCounter } from './TokenCounter';
import { HistoryTrimmer } from './HistoryTrimmer';
import { ChatPersistenceService } from './ChatPersistenceService';
import { ChatMessage, ChatMessageStatus, createChatMessage } from '../models/ChatMessage';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatRequestOptions } from '../models/ChatRequest';
import { ChatRole } from '../models/ChatRole';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState,
  ChatDelta,
  ChatStreamResult,
  isStreamTerminalState
} from '../models/ChatStreamTypes';
import { NetworkError } from '../models/NetworkError';
import { Character } from '../models/Character';
import { Lorebook } from '../models/Lorebook';
import { MacroContext, createMacroContext } from '../models/MacroContext';
import { ProviderConfig } from '../models/ProviderConfig';
import { TokenBudget, DEFAULT_CONTEXT_WINDOW, DEFAULT_RESERVED_OUTPUT_TOKENS } from '../models/TokenBudget';
import { HistoryTrimResult } from '../models/HistoryTrimResult';
import { PersistedChatSession } from '../models/PersistedChatSession';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatService';

/** 启动阶段超时(毫秒),收到首个 onStart/onDelta/onComplete/onError 后清除 */
const START_TIMEOUT_MS: number = 15000;

/** 默认用户名(本阶段固定值,后续可扩展为用户设置) */
const DEFAULT_USER_NAME: string = 'User';

/** delta 持久化节流间隔(毫秒) */
const PERSISTENCE_THROTTLE_MS: number = 400;

/** delta 持久化触发的最小字符增量 */
const PERSISTENCE_MIN_CHARS: number = 64;

/**
 * 聊天状态枚举。
 */
export enum ChatState {
  Idle = 'Idle',
  Sending = 'Sending',
  Streaming = 'Streaming',
  Completed = 'Completed',
  Cancelled = 'Cancelled',
  Failed = 'Failed'
}

/**
 * 聊天服务回调。
 */
export interface ChatServiceCallbacks {
  /** 消息列表变更 */
  onMessagesChanged: (messages: ChatMessage[]) => void;
  /** 状态变更 */
  onStateChanged: (state: ChatState) => void;
  /** 错误消息 */
  onError: (message: string) => void;
}

/** 默认流式请求选项 */
const DEFAULT_OPTIONS: ChatRequestOptions = {
  temperature: 0.7,
  topP: 1.0,
  maxTokens: 1024,
  stream: true
};

/**
 * 聊天服务。
 * 生命周期跟随 ChatPage,dispose 后不可复用。
 */
export class ChatService {
  private messages: ChatMessage[] = [];
  private state: ChatState = ChatState.Idle;
  private currentHandle: ChatStreamHandle | null = null;
  private currentAssistantId: string | null = null;
  private disposed: boolean = false;
  private startTimerId: number = -1;
  private readonly modelService: ModelService;
  private readonly lorebookService: LorebookService | null;
  private readonly promptBuilder: PromptBuilder | null;
  private readonly tokenCounter: TokenCounter | null;
  private readonly historyTrimmer: HistoryTrimmer | null;
  private readonly persistenceService: ChatPersistenceService | null;
  /** 当前角色(用于 PromptBuilder 构建) */
  private character: Character | null = null;
  /** 最近一次使用的回调(用于 stopGeneration/clearConversation 通知状态) */
  private lastCallbacks: ChatServiceCallbacks | null = null;
  /** 最近一次 Prompt 构建后的 Token 预算(只读,用于页面查询) */
  private lastTokenBudget: TokenBudget | undefined = undefined;
  /** 最近一次历史裁剪结果(只读) */
  private lastHistoryTrimResult: HistoryTrimResult | undefined = undefined;

  // ===== 持久化状态 =====
  /** 当前会话 id(未初始化时为 undefined) */
  private currentChatId: string | undefined = undefined;
  /** 当前会话的最大 sequenceNumber(空会话为 0) */
  private currentSequenceNumber: number = 0;
  /** 会话是否已初始化 */
  private contextInitialized: boolean = false;
  /** 初始化进行中的 Promise(防止并发) */
  private initializingPromise: Promise<void> | null = null;

  // ===== 流式 delta 持久化节流 =====
  /** 节流定时器 id */
  private persistenceTimerId: number = -1;
  /** 上次持久化时的 Assistant content 长度 */
  private lastPersistedContentLength: number = 0;
  /** 待持久化的 Assistant id */
  private pendingPersistAssistantId: string | null = null;

  constructor(
    modelService: ModelService,
    lorebookService: LorebookService | null = null,
    promptBuilder: PromptBuilder | null = null,
    tokenCounter: TokenCounter | null = null,
    historyTrimmer: HistoryTrimmer | null = null,
    persistenceService: ChatPersistenceService | null = null
  ) {
    this.modelService = modelService;
    this.lorebookService = lorebookService;
    this.promptBuilder = promptBuilder;
    this.tokenCounter = tokenCounter;
    this.historyTrimmer = historyTrimmer;
    this.persistenceService = persistenceService;
  }

  /**
   * 初始化角色聊天上下文(无持久化版本)。
   * 有角色时:
   * - 注入 firstMessage 作为 Assistant 开场消息
   * - Character System Prompt 由 PromptBuilder 在每次发送/重新生成时动态生成,
   *   不存储到 this.messages(避免与 PromptBuilder 重复注入)
   * 无角色时:不做任何初始化。
   * 只在消息列表为空时生效,防止重复注入。
   *
   * 此方法不访问数据库,用于无 persistenceService 的场景(如旧测试)。
   * 新代码应使用 initializeSession()。
   *
   * @returns 是否添加了 firstMessage(用于通知页面显示开场白)
   */
  initContext(character: Character | null): boolean {
    this.character = character;
    this.contextInitialized = true;
    if (this.messages.length > 0) {
      return false;
    }
    if (character === null) {
      return false;
    }
    Logger.info(LOG_TAG, 'initContext character=' + character.name);

    const newMessages: ChatMessage[] = [];

    if (character.firstMessage.length > 0) {
      const firstMsg: ChatMessage = {
        id: 'msg-' + generateUuid(),
        role: ChatRole.Assistant,
        content: character.firstMessage,
        createdAt: Date.now(),
        isStreaming: false,
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.CharacterFirstMessage
      };
      newMessages.push(firstMsg);
    }

    this.messages = newMessages;
    return character.firstMessage.length > 0;
  }

  /**
   * 异步初始化会话(持久化版本)。
   *
   * 流程:
   * 1. 尝试加载最近会话(openLatestSession)
   * 2. 若存在:恢复 messages 和 currentSequenceNumber
   * 3. 若不存在:创建新会话,有角色且 firstMessage 非空时注入开场白
   * 4. 标记 contextInitialized = true
   *
   * 同一 ChatService 实例只初始化一次。
   * 并发调用只执行一次,其他调用等待结果。
   * 初始化失败抛异常,页面应捕获并显示错误。
   *
   * @param character 当前角色(可选)
   */
  async initializeSession(character?: Character): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed, cannot initialize session');
    }
    if (this.contextInitialized) {
      return;
    }
    if (this.initializingPromise !== null) {
      await this.initializingPromise;
      return;
    }
    const promise: Promise<void> = this.doInitializeSession(character);
    this.initializingPromise = promise;
    try {
      await promise;
    } finally {
      this.initializingPromise = null;
    }
  }

  private async doInitializeSession(character?: Character): Promise<void> {
    this.character = character !== undefined ? character : null;

    // 无持久化服务:回退到同步 initContext
    if (this.persistenceService === null) {
      this.initContext(this.character);
      return;
    }

    const characterId: string | undefined =
      this.character !== null ? this.character.id : undefined;
    try {
      const session: PersistedChatSession | null =
        await this.persistenceService.openLatestSession(characterId);

      if (session !== null) {
        // 恢复已有会话
        this.currentChatId = session.chat.id;
        this.messages = session.messages.slice();
        this.currentSequenceNumber = session.maxSequenceNumber;
        Logger.info(LOG_TAG, 'session restored messages=' + this.messages.length.toString()
          + ' maxSeq=' + this.currentSequenceNumber.toString());
      } else {
        // 创建新会话
        await this.createNewSession(characterId);
      }
      this.contextInitialized = true;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'initializeSession failed: ' + msg);
      throw new Error('会话初始化失败: ' + msg);
    }
  }

  /**
   * 创建新会话并注入 firstMessage(如果有角色且 firstMessage 非空)。
   */
  private async createNewSession(characterId?: string): Promise<void> {
    if (this.persistenceService === null) {
      return;
    }

    const hasFirstMessage: boolean =
      this.character !== null && this.character.firstMessage.length > 0;

    if (hasFirstMessage && this.character !== null) {
      const firstMsg: ChatMessage = {
        id: 'msg-' + generateUuid(),
        role: ChatRole.Assistant,
        content: this.character.firstMessage,
        createdAt: Date.now(),
        isStreaming: false,
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.CharacterFirstMessage
      };
      const session: PersistedChatSession =
        await this.persistenceService.createSessionWithFirstMessage(
          characterId, undefined, firstMsg
        );
      this.currentChatId = session.chat.id;
      this.messages = [firstMsg];
      this.currentSequenceNumber = 1;
    } else {
      const session: PersistedChatSession =
        await this.persistenceService.createSession(characterId);
      this.currentChatId = session.chat.id;
      this.messages = [];
      this.currentSequenceNumber = 0;
    }
  }

  /**
   * 获取当前会话 id(未初始化时为 undefined)。
   */
  getCurrentChatId(): string | undefined {
    return this.currentChatId;
  }

  /**
   * 会话是否已初始化(可用于页面判断是否可发送)。
   */
  isSessionReady(): boolean {
    return this.contextInitialized;
  }

  /**
   * 发送用户消息并开始流式生成。
   * 顺序:校验 → 创建 User 消息 → 持久化 → 创建 Assistant 占位 → 持久化 → 启动网络。
   *
   * 持久化策略:
   * - 有 persistenceService 时:先持久化 User + Streaming Assistant(事务),
   *   失败则不启动网络请求,页面显示错误
   * - 无 persistenceService 时:仅更新内存(兼容旧测试)
   */
  async sendMessage(userContent: string, callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed, cannot send message');
    }
    if (userContent.trim().length === 0) {
      return;
    }
    if (this.state !== ChatState.Idle && this.state !== ChatState.Completed
      && this.state !== ChatState.Cancelled && this.state !== ChatState.Failed) {
      Logger.warn(LOG_TAG, 'sendMessage rejected: state=' + this.state);
      return;
    }

    Logger.info(LOG_TAG, 'sendMessage start');
    this.lastCallbacks = callbacks;

    // 1. 创建用户消息
    const userMsg: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.User,
      content: userContent,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation
    };

    // 2. 创建空 Assistant 占位消息
    const assistantId: string = 'msg-' + generateUuid();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 3. 持久化(如果有 persistenceService)
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        const result =
          await this.persistenceService.appendUserAndStreamingAssistant(
            this.currentChatId, userMsg, assistantMsg
          );
        this.currentSequenceNumber = result.assistantSequenceNumber;
        this.lastPersistedContentLength = 0;
        this.pendingPersistAssistantId = assistantId;
      } catch (e) {
        // 持久化失败:不启动请求,显示错误
        const msg: string = e instanceof Error ? e.message : String(e);
        Logger.error(LOG_TAG, 'sendMessage persist failed: ' + msg);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('消息保存失败,请重试');
        return;
      }
    }

    // 4. 更新内存(持久化成功后)
    this.messages = [...this.messages, userMsg, assistantMsg];
    this.currentAssistantId = assistantId;
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 5. 启动网络请求(失败也保留消息)
    this.doStream(assistantId, callbacks);
  }

  /**
   * 重新生成最后一条 Assistant 回复。
   * 找到最后一个 User 消息,删除其后的 Assistant 消息,重新请求。
   *
   * 持久化策略:
   * - 有 persistenceService 时:事务删除旧 Assistant + 创建新 Streaming Assistant
   * - 无 persistenceService 时:仅更新内存(兼容旧测试)
   */
  async regenerateLastResponse(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed, cannot regenerate');
    }
    if (!this.canRegenerate()) {
      return;
    }

    Logger.info(LOG_TAG, 'regenerate start');
    this.lastCallbacks = callbacks;

    // 找到最后一个 User 消息
    let lastUserIdx: number = -1;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        lastUserIdx = i;
        break;
      }
    }
    if (lastUserIdx < 0) {
      return;
    }
    const userMessageId: string = this.messages[lastUserIdx].id;

    // 创建空 Assistant 占位消息
    const assistantId: string = 'msg-' + generateUuid();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 持久化(事务删除旧 Assistant + 创建新 Streaming Assistant)
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        const newSeq =
          await this.persistenceService.replaceMessagesAfterUserAndAppend(
            this.currentChatId, userMessageId, assistantMsg
          );
        this.currentSequenceNumber = newSeq;
        this.lastPersistedContentLength = 0;
        this.pendingPersistAssistantId = assistantId;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        Logger.error(LOG_TAG, 'regenerate persist failed: ' + msg);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('重新生成失败,请重试');
        return;
      }
    }

    // 更新内存(持久化成功后)
    this.messages = this.messages.slice(0, lastUserIdx + 1);
    this.messages = [...this.messages, assistantMsg];
    this.currentAssistantId = assistantId;
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    this.doStream(assistantId, callbacks);
  }

  /**
   * 是否可重新生成。
   */
  canRegenerate(): boolean {
    if (this.state === ChatState.Sending || this.state === ChatState.Streaming) {
      return false;
    }
    // 至少有一个 Assistant 消息
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.Assistant) {
        return true;
      }
    }
    return false;
  }

  /**
   * 停止当前生成。
   */
  stopGeneration(): void {
    this.clearStartTimer();
    if (this.currentHandle !== null) {
      Logger.info(LOG_TAG, 'stopGeneration abort');
      this.currentHandle.abort();
      this.currentHandle = null;
    }
    if (this.state === ChatState.Sending || this.state === ChatState.Streaming) {
      // flush 任何 pending delta 持久化
      this.flushPersistence();
      // 将当前 Assistant 消息标记为已取消(创建新对象和新数组)
      this.markAssistant(this.currentAssistantId, ChatMessageStatus.Cancelled, undefined, undefined);
      this.emitMessages(this.lastCallbacks);
      // 持久化最终 Cancelled 状态
      this.persistFinalAssistant(this.currentAssistantId);
      this.currentAssistantId = null;
      this.setState(ChatState.Cancelled, this.lastCallbacks);
    }
  }

  /**
   * 是否正在生成。
   */
  isGenerating(): boolean {
    return this.state === ChatState.Sending || this.state === ChatState.Streaming;
  }

  /**
   * 清空当前对话。如正在生成先停止。
   */
  clearConversation(): void {
    if (this.isGenerating()) {
      this.stopGeneration();
    }
    this.messages = [];
    this.currentAssistantId = null;
    this.setState(ChatState.Idle, this.lastCallbacks);
    this.emitMessages(this.lastCallbacks);
    Logger.info(LOG_TAG, 'clearConversation');
  }

  /**
   * 获取当前消息列表(副本)。
   */
  getMessages(): ChatMessage[] {
    return this.messages.slice();
  }

  /**
   * 获取最近一次 Prompt 构建的 Token 预算结果。
   * 仅在执行过 sendMessage/regenerateLastResponse 后才有值。
   *
   * @returns TokenBudget 或 undefined(未执行或 Token 统计失败)
   */
  getLastTokenBudget(): TokenBudget | undefined {
    return this.lastTokenBudget;
  }

  /**
   * 获取最近一次历史裁剪结果(只读)。
   * 页面暂时不使用。
   *
   * @returns HistoryTrimResult 或 undefined(未执行或裁剪失败)
   */
  getLastHistoryTrimResult(): HistoryTrimResult | undefined {
    return this.lastHistoryTrimResult;
  }

  /**
   * 释放资源,停止当前请求。dispose 后不可复用。
   * 释放前 flush 任何 pending delta 持久化。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.clearStartTimer();
    this.clearPersistenceTimer();
    if (this.currentHandle !== null) {
      this.currentHandle.abort();
      this.currentHandle = null;
    }
    // flush 任何 pending delta(不等待 Promise,尽力而为)
    this.flushPersistenceSync();
    this.messages = [];
    this.currentAssistantId = null;
    this.lastCallbacks = null;
    this.lastTokenBudget = undefined;
    this.lastHistoryTrimResult = undefined;
    this.state = ChatState.Idle;
    Logger.info(LOG_TAG, 'dispose');
  }

  // ===== 内部方法 =====

  private async doStream(
    assistantId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    const streamCallbacks: ChatStreamCallbacks = {
      onStart: (): void => {
        this.clearStartTimer();
        Logger.info(LOG_TAG, 'onStart');
      },
      onDelta: (delta: ChatDelta): void => {
        this.clearStartTimer();
        if (this.disposed || this.state !== ChatState.Streaming) {
          return;
        }
        this.appendDelta(assistantId, delta.content, callbacks);
        // 节流持久化 delta
        this.schedulePersistenceFlush(assistantId);
      },
      onComplete: (result: ChatStreamResult): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        if (this.state !== ChatState.Streaming && this.state !== ChatState.Sending) {
          return;
        }
        // flush 任何 pending delta 持久化
        this.flushPersistence();
        const finalStatus: ChatMessageStatus = this.finalizeAssistant(
          assistantId, result.content, ChatMessageStatus.Completed, undefined, callbacks
        );
        this.currentAssistantId = null;
        // 持久化最终状态
        this.persistFinalAssistant(assistantId);
        // 更新 Chat 活跃时间
        this.persistChatActivity();
        // 空回复时 finalizeAssistant 返回 Failed,state 也应为 Failed
        if (finalStatus === ChatMessageStatus.Failed) {
          this.setState(ChatState.Failed, callbacks);
          callbacks.onError('模型返回了空回复,请重试');
        } else {
          this.setState(ChatState.Completed, callbacks);
        }
        Logger.info(LOG_TAG, 'stream completed deltaCount=' + result.deltaCount);
      },
      onError: (error: NetworkError): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        if (this.state === ChatState.Cancelled) {
          return;
        }
        // flush 任何 pending delta 持久化
        this.flushPersistence();
        this.finalizeAssistant(assistantId, '', ChatMessageStatus.Failed, error.message, callbacks);
        this.currentAssistantId = null;
        // 持久化最终 Failed 状态
        this.persistFinalAssistant(assistantId);
        // 更新 Chat 活跃时间
        this.persistChatActivity();
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError(error.message);
        Logger.info(LOG_TAG, 'stream failed: ' + error.message);
      }
    };

    // 启动超时保护
    this.startStartTimer(assistantId, callbacks);

    // 构建请求消息(通过 PromptBuilder 统一构建)
    let requestMessages: ChatMessage[];
    try {
      requestMessages = await this.buildRequestMessages();
    } catch (e) {
      this.clearStartTimer();
      this.finalizeAssistant(assistantId, '', ChatMessageStatus.Failed, String(e), callbacks);
      this.currentAssistantId = null;
      this.persistFinalAssistant(assistantId);
      this.setState(ChatState.Failed, callbacks);
      callbacks.onError(String(e));
      return;
    }

    // 计算 Token 预算 → 超预算则裁剪 → 重算预算
    await this.updateRequestPlan(requestMessages);

    try {
      const planMessages: ChatMessage[] = this.lastHistoryTrimResult !== undefined
        ? this.lastHistoryTrimResult.messages
        : requestMessages;
      this.currentHandle = this.modelService.streamCurrentChat(planMessages, DEFAULT_OPTIONS, streamCallbacks);
      this.setState(ChatState.Streaming, callbacks);
    } catch (e) {
      this.clearStartTimer();
      this.finalizeAssistant(assistantId, '', ChatMessageStatus.Failed, String(e), callbacks);
      this.currentAssistantId = null;
      this.persistFinalAssistant(assistantId);
      this.setState(ChatState.Failed, callbacks);
      callbacks.onError(String(e));
    }
  }

  /**
   * 构建请求消息列表(通过 PromptBuilder 统一构建)。
   *
   * 角色、世界书和聊天历史由 PromptBuilder 按固定顺序组装。
   * 世界书内容不会写入 this.messages。
   * 无 PromptBuilder 或无角色时,返回原始消息列表(跳过 System 消息)。
   */
  private async buildRequestMessages(): Promise<ChatMessage[]> {
    if (this.promptBuilder === null) {
      // 无 PromptBuilder:跳过 System 消息,保留 User/Assistant
      const filtered: ChatMessage[] = [];
      for (let i = 0; i < this.messages.length; i++) {
        if (this.messages[i].role !== ChatRole.System) {
          filtered.push(this.messages[i]);
        }
      }
      return filtered;
    }

    // 获取当前世界书
    let lorebook: Lorebook | undefined = undefined;
    if (this.lorebookService !== null) {
      lorebook = await this.lorebookService.getCurrentLorebook() ?? undefined;
    }

    // 构建宏替换上下文(characterName 来自角色,userName 为固定默认值)
    const macroContext: MacroContext = createMacroContext(
      this.character !== null ? this.character.name : '',
      DEFAULT_USER_NAME
    );

    const context: PromptBuildContext = {
      character: this.character !== null ? this.character : undefined,
      lorebook: lorebook,
      messages: this.messages,
      macroContext: macroContext
    };

    const result: PromptBuildResult = this.promptBuilder.build(context);
    Logger.info(LOG_TAG, 'buildRequestMessages: segments=' + result.messages.length.toString()
      + ' lorebook=' + result.matchedLorebookEntryIds.length.toString());
    return result.messages;
  }

  /**
   * 统一更新请求计划:计算 Token 预算,若超预算则裁剪,再重算预算。
   * 失败不抛出,仅清空结果并记录安全日志。
   *
   * 记录中只输出 messages 数、Token 数与超预算标志,不记录任何消息内容。
   */
  private async updateRequestPlan(requestMessages: ChatMessage[]): Promise<void> {
    if (this.tokenCounter === null) {
      // 无 TokenCounter:跳过,使用原始请求消息
      this.lastTokenBudget = undefined;
      this.lastHistoryTrimResult = undefined;
      return;
    }

    let contextWindow: number = DEFAULT_CONTEXT_WINDOW;
    let reserved: number = DEFAULT_RESERVED_OUTPUT_TOKENS;
    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config !== null) {
        if (config.contextWindow !== undefined) {
          contextWindow = config.contextWindow;
        }
        if (config.maxTokens > 0) {
          reserved = config.maxTokens;
        }
      }
    } catch (e) {
      // 配置获取失败:使用默认值继续
      Logger.warn(LOG_TAG, 'getCurrentConfig failed: ' + (e instanceof Error ? e.message : String(e)));
    }

    let available: number = contextWindow > reserved ? contextWindow - reserved : 0;
    if (available < 0) {
      available = 0;
    }

    // 1) 首次预算估算(原始 Prompt)
    let currentMessages: ChatMessage[] = requestMessages;
    let originalTokens: number = 0;
    try {
      originalTokens = this.tokenCounter.estimateMessages(currentMessages);
    } catch (e) {
      Logger.warn(LOG_TAG, 'token estimate failed: ' + (e instanceof Error ? e.message : String(e)));
      this.lastTokenBudget = undefined;
      this.lastHistoryTrimResult = undefined;
      return;
    }
    const exceedsBefore: boolean = originalTokens > available;

    // 2) 必要时调用 HistoryTrimmer
    if (exceedsBefore && this.historyTrimmer !== null) {
      let trimResult: HistoryTrimResult | undefined = undefined;
      try {
        trimResult = this.historyTrimmer.trim(currentMessages, { availableInputTokens: available });
      } catch (e) {
        Logger.warn(LOG_TAG, 'history trim failed: ' + (e instanceof Error ? e.message : String(e)));
        this.lastHistoryTrimResult = undefined;
        this.lastTokenBudget = this.makeBudget(originalTokens, contextWindow, reserved, available);
        return;
      }
      this.lastHistoryTrimResult = trimResult;
      currentMessages = trimResult.messages;
      // 输出安全裁剪统计
      Logger.info(LOG_TAG,
        'history trim: beforeMessages=' + requestMessages.length.toString()
          + ' afterMessages=' + currentMessages.length.toString()
          + ' removed=' + trimResult.removedMessageCount.toString()
          + ' beforeTokens=' + trimResult.originalTokenCount.toString()
          + ' afterTokens=' + trimResult.finalTokenCount.toString()
          + ' availableTokens=' + available.toString()
          + ' exceedsAfter=' + (trimResult.exceedsBudgetAfterTrim ? 'true' : 'false'));

      // 3) 重算 TokenBudget
      let finalTokens: number = trimResult.finalTokenCount;
      try {
        finalTokens = this.tokenCounter.estimateMessages(currentMessages);
      } catch (e) {
        // 异常时使用 trimResult 的值
        Logger.warn(LOG_TAG, 'token re-estimate failed: ' + (e instanceof Error ? e.message : String(e)));
      }
      this.lastTokenBudget = this.makeBudget(finalTokens, contextWindow, reserved, available);

      if (this.lastTokenBudget.exceedsBudget) {
        Logger.warn(LOG_TAG,
          'token budget exceeded after trim: inputTokens=' + finalTokens.toString()
            + ' availableTokens=' + available.toString());
      }
    } else {
      // 不超预算或无 HistoryTrimmer:不裁剪
      this.lastHistoryTrimResult = undefined;
      this.lastTokenBudget = this.makeBudget(originalTokens, contextWindow, reserved, available);
      this.logNormalEstimate(requestMessages.length, originalTokens, available);
    }
  }

  private logNormalEstimate(messages: number, inputTokens: number, available: number): void {
    if (inputTokens > available) {
      Logger.warn(LOG_TAG,
        'token budget exceeded: messages=' + messages.toString()
          + ' inputTokens=' + inputTokens.toString()
          + ' availableTokens=' + available.toString()
          + ' remainingTokens=' + (available - inputTokens).toString()
          + ' exceedsBudget=true');
    } else {
      Logger.info(LOG_TAG,
        'token estimate: messages=' + messages.toString()
          + ' inputTokens=' + inputTokens.toString()
          + ' availableTokens=' + available.toString()
          + ' remainingTokens=' + (available - inputTokens).toString()
          + ' exceedsBudget=false');
    }
  }

  private makeBudget(inputTokens: number, contextWindow: number, reserved: number, available: number): TokenBudget {
    const remaining: number = available - inputTokens;
    const exceeds: boolean = inputTokens > available;
    return {
      contextWindow: contextWindow,
      reservedOutputTokens: reserved,
      availableInputTokens: available,
      estimatedInputTokens: inputTokens,
      remainingInputTokens: remaining,
      exceedsBudget: exceeds
    };
  }

  /**
   * 启动阶段超时定时器。
   * 如果在 START_TIMEOUT_MS 内没有收到 onStart/onDelta/onComplete/onError,
   * 中止请求并标记为失败。
   */
  private startStartTimer(assistantId: string, callbacks: ChatServiceCallbacks): void {
    this.clearStartTimer();
    this.startTimerId = setTimeout((): void => {
      this.startTimerId = -1;
      if (this.disposed) {
        return;
      }
      if (this.state !== ChatState.Sending && this.state !== ChatState.Streaming) {
        return;
      }
      Logger.warn(LOG_TAG, 'start timeout fired');
      if (this.currentHandle !== null) {
        this.currentHandle.abort();
        this.currentHandle = null;
      }
      this.finalizeAssistant(assistantId, '', ChatMessageStatus.Failed, '请求启动超时,请重试', callbacks);
      this.currentAssistantId = null;
      this.setState(ChatState.Failed, callbacks);
      callbacks.onError('请求启动超时,请重试');
    }, START_TIMEOUT_MS);
  }

  private clearStartTimer(): void {
    if (this.startTimerId !== -1) {
      clearTimeout(this.startTimerId);
      this.startTimerId = -1;
    }
  }

  private setState(state: ChatState, callbacks: ChatServiceCallbacks | null): void {
    if (this.state === state) {
      return;
    }
    this.state = state;
    if (callbacks !== null) {
      callbacks.onStateChanged(state);
    }
  }

  /**
   * 通知消息列表变更(传递新数组副本)。
   * callbacks 为 null 时跳过(用于 dispose 后或无回调场景)。
   */
  private emitMessages(callbacks: ChatServiceCallbacks | null): void {
    if (callbacks === null) {
      return;
    }
    callbacks.onMessagesChanged([...this.messages]);
  }

  /**
   * 追加 delta 内容到指定 Assistant 消息(创建新对象和新数组)。
   */
  private appendDelta(assistantId: string, delta: string, callbacks: ChatServiceCallbacks): void {
    if (delta.length === 0) {
      return;
    }
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === assistantId) {
        return {
          id: msg.id,
          role: msg.role,
          content: msg.content + delta,
          createdAt: msg.createdAt,
          updatedAt: Date.now(),
          isStreaming: true,
          status: ChatMessageStatus.Streaming
        };
      }
      return msg;
    });
    this.emitMessages(callbacks);
  }

  /**
   * 完成 Assistant 消息(创建新对象和新数组)。
   * 空回复且状态为 Completed 时,改为 Failed。
   * @returns 最终的消息状态(用于决定 ChatService state)
   */
  private finalizeAssistant(
    assistantId: string,
    content: string,
    status: ChatMessageStatus,
    errorMessage: string | undefined,
    callbacks: ChatServiceCallbacks
  ): ChatMessageStatus {
    let resultStatus: ChatMessageStatus = status;
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === assistantId) {
        // 优先使用传入的 content(来自 onComplete),否则保留已有 delta 累积内容
        const finalContent: string = content.length > 0 ? content : msg.content;
        // 空回复检查:完成时内容为空,标记为失败
        let finalStatus: ChatMessageStatus = status;
        let finalError: string | undefined = errorMessage;
        if (finalStatus === ChatMessageStatus.Completed && finalContent.length === 0) {
          finalStatus = ChatMessageStatus.Failed;
          finalError = '模型返回了空回复,请重试';
        }
        // 失败且内容为空时,补充默认错误信息
        if (finalStatus === ChatMessageStatus.Failed && finalContent.length === 0
          && (finalError === undefined || finalError.length === 0)) {
          finalError = '生成失败,未收到回复';
        }
        resultStatus = finalStatus;
        return {
          id: msg.id,
          role: msg.role,
          content: finalContent,
          createdAt: msg.createdAt,
          updatedAt: Date.now(),
          isStreaming: false,
          errorMessage: finalError,
          status: finalStatus
        };
      }
      return msg;
    });
    this.emitMessages(callbacks);
    return resultStatus;
  }

  /**
   * 标记指定 Assistant 消息状态(创建新对象和新数组)。
   */
  private markAssistant(
    assistantId: string | null,
    status: ChatMessageStatus,
    errorMessage: string | undefined,
    _content: string | undefined
  ): void {
    if (assistantId === null) {
      return;
    }
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === assistantId) {
        return {
          id: msg.id,
          role: msg.role,
          content: msg.content,
          createdAt: msg.createdAt,
          updatedAt: Date.now(),
          isStreaming: false,
          errorMessage: errorMessage !== undefined ? errorMessage : msg.errorMessage,
          status: status,
          source: msg.source
        };
      }
      return msg;
    });
  }

  // ===== 持久化辅助方法 =====

  /**
   * 节流调度 delta 持久化。
   * - 累计 PERSISTENCE_THROTTLE_MS 毫秒或 PERSISTENCE_MIN_CHARS 字符后触发
   * - 已有定时器则不重复创建
   */
  private schedulePersistenceFlush(assistantId: string): void {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    this.pendingPersistAssistantId = assistantId;

    // 检查字符增量是否已达到阈值
    const currentMsg: ChatMessage | undefined = this.findMessageById(assistantId);
    if (currentMsg !== undefined) {
      const charDelta: number = currentMsg.content.length - this.lastPersistedContentLength;
      if (charDelta >= PERSISTENCE_MIN_CHARS) {
        // 达到字符阈值,立即 flush
        this.flushPersistence();
        return;
      }
    }

    // 未达到字符阈值,启动/重置定时器
    if (this.persistenceTimerId === -1) {
      this.persistenceTimerId = setTimeout((): void => {
        this.persistenceTimerId = -1;
        this.flushPersistence();
      }, PERSISTENCE_THROTTLE_MS);
    }
  }

  /**
   * 强制 flush 当前 pending delta 持久化(异步,不等待)。
   * 用于 onComplete/onError/stopGeneration 时确保最后一批 delta 写入。
   */
  private flushPersistence(): void {
    this.clearPersistenceTimer();
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const assistantId: string | null = this.pendingPersistAssistantId;
    if (assistantId === null) {
      return;
    }
    const msg: ChatMessage | undefined = this.findMessageById(assistantId);
    if (msg === undefined) {
      return;
    }
    // 内容长度未变化则跳过
    if (msg.content.length === this.lastPersistedContentLength) {
      return;
    }
    this.lastPersistedContentLength = msg.content.length;
    // 异步写入,不等待,失败仅记录 warning
    this.persistenceService.updateMessage(this.currentChatId, msg).catch(
      (e: Object): void => {
        Logger.warn(LOG_TAG, 'delta persist failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    );
  }

  /**
   * 同步 flush(dispose 时使用)。
   * 只清除定时器,不发起异步写入(避免 dispose 后异步回调访问已释放状态)。
   */
  private flushPersistenceSync(): void {
    this.clearPersistenceTimer();
    this.pendingPersistAssistantId = null;
  }

  private clearPersistenceTimer(): void {
    if (this.persistenceTimerId !== -1) {
      clearTimeout(this.persistenceTimerId);
      this.persistenceTimerId = -1;
    }
  }

  /**
   * 持久化 Assistant 最终状态(Completed/Cancelled/Failed)。
   * 包含 1 次立即重试,失败仅记录 warning,不阻塞流程。
   */
  private persistFinalAssistant(assistantId: string | null): void {
    if (assistantId === null) {
      return;
    }
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const msg: ChatMessage | undefined = this.findMessageById(assistantId);
    if (msg === undefined) {
      return;
    }
    this.lastPersistedContentLength = msg.content.length;
    this.pendingPersistAssistantId = null;

    // 异步写入,1 次重试
    this.persistWithRetry(msg, 1);
  }

  private persistWithRetry(msg: ChatMessage, retriesLeft: number): void {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const chatId: string = this.currentChatId;
    this.persistenceService.updateMessage(chatId, msg).then((): void => {
      Logger.info(LOG_TAG, 'final persist ok');
    }).catch((e: Object): void => {
      const msg2: string = e instanceof Error ? e.message : String(e);
      if (retriesLeft > 0) {
        Logger.warn(LOG_TAG, 'final persist retry: ' + msg2);
        this.persistWithRetry(msg, retriesLeft - 1);
      } else {
        Logger.warn(LOG_TAG, 'final persist failed: ' + msg2);
      }
    });
  }

  /**
   * 更新 Chat 活跃时间(异步,不等待)。
   */
  private persistChatActivity(): void {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    this.persistenceService.updateChatActivity(this.currentChatId, Date.now()).catch(
      (e: Object): void => {
        Logger.warn(LOG_TAG, 'chat activity persist failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    );
  }

  /**
   * 在 messages 中查找指定 id 的消息。
   */
  private findMessageById(id: string): ChatMessage | undefined {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === id) {
        return this.messages[i];
      }
    }
    return undefined;
  }
}
