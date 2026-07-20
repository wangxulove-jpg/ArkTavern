/**
 * ChatService 聊天服务
 * (T-6.3 Mainline Stability Regression & Recovery Hardening)
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
 * 生成类型(T-6.3):
 * - NormalResponse: 首次 Assistant 回复,走 ChatPersistenceService
 * - SwipeCandidate: 候选回复,走 MessageSwipePersistenceService
 * - 所有异步路径基于统一 ActiveGenerationContext 判断迟到回调
 * - 清理上下文前必须完成最终状态持久化
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
import { PromptPresetService } from './PromptPresetService';
import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { ConversationBranchPersistenceService, EditedBranchGenerationTarget } from './ConversationBranchPersistenceService';
import {
  ConversationBranch,
  ConversationBranchSummary,
  ConversationRecordCounts
} from '../models/ConversationBranch';
import {
  MessageSwipeSummary,
  MessageSwipeCandidateUpdates,
  MessageSwipeState,
  MAX_SWIPE_CANDIDATES
} from '../models/MessageSwipe';
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
import { MacroContext } from '../models/MacroContext';
import { ProviderConfig } from '../models/ProviderConfig';
import { TokenBudget, DEFAULT_CONTEXT_WINDOW, DEFAULT_RESERVED_OUTPUT_TOKENS } from '../models/TokenBudget';
import { HistoryTrimResult } from '../models/HistoryTrimResult';
import { PersistedChatSession } from '../models/PersistedChatSession';
import { Chat } from '../models/Chat';
import {
  PromptPresetRequestSnapshot,
  EffectiveGenerationSettings,
  resolveEffectiveGenerationSettings,
  createSnapshotWithoutPreset,
  createSnapshotWithPreset
} from './PromptPresetRuntimeResolver';
import { PromptPreset } from '../models/PromptPreset';
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

/**
 * 生成类型(T-6.3 / T-6.4B-1.2):
 * - NormalResponse: 普通生成,持久化走 ChatPersistenceService.updateMessage
 * - SwipeCandidate: 候选生成,持久化走 MessageSwipePersistenceService.updateCandidate
 * - BranchRegeneration: 重新生成新分支,持久化走 ChatPersistenceService.updateMessage(新 Assistant 在新 Branch 中)
 */
export enum ChatGenerationKind {
  NormalResponse = 'NormalResponse',
  SwipeCandidate = 'SwipeCandidate',
  BranchRegeneration = 'BranchRegeneration'
}

/**
 * 活动生成上下文(T-6.3 / T-6.4B-1.2)。
 * 一次请求生命周期内不可变。所有异步回调通过 operationId + 关键字段联合判断迟到。
 * 不持久化,不记录完整 ID。
 */
interface ActiveGenerationContext {
  /** 生成操作标识,用于拒绝迟到回调 */
  readonly operationId: number;
  /** 生成类型(普通 / Swipe / BranchRegeneration) */
  readonly kind: ChatGenerationKind;
  /** 所属 chatId(用于跨会话污染防护) */
  readonly chatId: string;
  /** 目标 Assistant 消息 ID */
  readonly assistantMessageId: string;
  /** Swipe 候选索引(仅 SwipeCandidate 类型时存在) */
  readonly swipeCandidateIndex?: number;
  /** 目标 Branch ID(仅 BranchRegeneration 类型时存在) */
  readonly branchId?: string;
  /** Fork User Message ID(仅 BranchRegeneration 类型时存在) */
  readonly forkMessageId?: string;
}

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
  private readonly promptPresetService: PromptPresetService | null;
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
  /** T-6.4A-R6: 当前在飞的 Swipe Candidate 持久化 Promise(delta 或 final),
   * 用于串行化 updateCandidate 调用,防止嵌套事务 */
  private pendingSwipePersistPromise: Promise<void> | null = null;

  /** MessageSwipePersistenceService 消息候选持久化服务 */
  private readonly swipePersistenceService: MessageSwipePersistenceService | null;
  /** ConversationBranchPersistenceService 对话分支持久化服务(T-6.4A,用于活动 Branch 加载) */
  private readonly branchPersistenceService: ConversationBranchPersistenceService | null;
  /** 当前会话的 Swipe 摘要列表 */
  private swipeSummaries: MessageSwipeSummary[] = [];
  /** 当前生成操作标识(用于阻止迟到回调),每次启动/停止递增 */
  private generationOperationId: number = 0;
  /**
   * 当前活动生成上下文(T-6.3)。
   * - 覆盖 NormalResponse 和 SwipeCandidate 两种生成
   * - 在最终状态持久化后才由 clearActiveGeneration 清除
   * - 迟到回调通过 isCurrentGeneration 判断
   */
  private activeGeneration: ActiveGenerationContext | null = null;
  /** 最后一条非 firstMessage 的 Assistant 消息 ID(用于判断可 Swipe 范围) */
  private lastAssistantMessageId: string = '';
  /** Swipe 浏览/切换操作进行中(用于互斥) */
  private swipeOperationInProgress: boolean = false;

  // ===== T-6.4B-1 Branch 状态 =====
  /** 当前会话的 Branch 摘要列表 */
  private branches: ConversationBranchSummary[] = [];
  /** 当前活动 Branch ID */
  private activeBranchId: string = '';
  /** 当前会话的 Branch 记录数量统计 */
  private recordCounts: ConversationRecordCounts | undefined = undefined;
  /** Branch 操作进行中(创建 Child / 切换),用于与生成 / Swipe / 会话操作互斥 */
  private branchOperationInProgress: boolean = false;

  constructor(
    modelService: ModelService,
    lorebookService: LorebookService | null = null,
    promptBuilder: PromptBuilder | null = null,
    tokenCounter: TokenCounter | null = null,
    historyTrimmer: HistoryTrimmer | null = null,
    persistenceService: ChatPersistenceService | null = null,
    promptPresetService: PromptPresetService | null = null,
    swipePersistenceService: MessageSwipePersistenceService | null = null,
    branchPersistenceService: ConversationBranchPersistenceService | null = null
  ) {
    this.modelService = modelService;
    this.lorebookService = lorebookService;
    this.promptBuilder = promptBuilder;
    this.tokenCounter = tokenCounter;
    this.historyTrimmer = historyTrimmer;
    this.persistenceService = persistenceService;
    this.promptPresetService = promptPresetService;
    this.swipePersistenceService = swipePersistenceService;
    this.branchPersistenceService = branchPersistenceService;
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
  async initializeSession(character?: Character, forceNew: boolean = false): Promise<void> {
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
    const promise: Promise<void> = this.doInitializeSession(character, forceNew);
    this.initializingPromise = promise;
    try {
      await promise;
    } finally {
      this.initializingPromise = null;
    }
  }

  private async doInitializeSession(character?: Character, forceNew: boolean = false): Promise<void> {
    this.character = character !== undefined ? character : null;

    // 无持久化服务:回退到同步 initContext
    if (this.persistenceService === null) {
      this.initContext(this.character);
      return;
    }

    const characterId: string | undefined =
      this.character !== null ? this.character.id : undefined;
    try {
      // forceNew=true:跳过 openLatestSession,直接创建新会话(角色卡"新建对话"入口)
      let session: PersistedChatSession | null = null;
      if (!forceNew) {
        session = await this.persistenceService.openLatestSession(characterId);
      }

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

      // 加载 Swipe summaries
      if (this.swipePersistenceService !== null && this.currentChatId !== undefined) {
        this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
        // 规范化中断的 Streaming Candidate
        const normalizedCount: number = await this.swipePersistenceService.normalizeInterruptedCandidates(this.currentChatId);
        if (normalizedCount > 0) {
          // 重新加载 messages(因中断 Candidate 可能已修改 messages)
          const session2: PersistedChatSession | null =
            await this.persistenceService.loadSession(this.currentChatId);
          if (session2 !== null) {
            this.messages = session2.messages.slice();
            this.currentSequenceNumber = session2.maxSequenceNumber;
          }
          // 重新加载 summaries
          this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
        }
      }
      // 更新 lastAssistantMessageId
      this.updateLastAssistantMessageId();
      // T-6.4B-1: 加载 Branch 状态(branches / activeBranchId / recordCounts)
      await this.refreshBranchState();

      this.contextInitialized = true;
    } catch (e) {
      // 保留原始错误类型(如 DatabaseError),不重复包装用户文案前缀
      // ViewModel 负责显示一次用户可读文案
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'initializeSession failed: ' + msg);
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(msg);
    }
  }

  /**
   * 创建新会话并注入 firstMessage(如果有角色且 firstMessage 非空)。
   * 默认 title 使用角色名(无角色时为"新对话",由 persistenceService 兜底)。
   *
   * V2 字段支持:
   * - 若角色有 firstMessage 且有 alternateGreetings:
   *   - firstMessage 作为 Candidate 0
   *   - alternateGreetings[i] 作为 Candidate 1..N(不激活,默认显示 firstMessage)
   *   - 用户后续可通过 Swipe 切换开场白
   */
  private async createNewSession(characterId?: string): Promise<void> {
    if (this.persistenceService === null) {
      return;
    }

    const hasFirstMessage: boolean =
      this.character !== null && this.character.firstMessage.length > 0;
    // 默认 title 优先用角色名(规范:名称=角色名),无角色时传 undefined 由 persistence 兜底为"新对话"
    const defaultTitle: string | undefined =
      this.character !== null && this.character.name.length > 0
        ? this.character.name
        : undefined;

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
          characterId, defaultTitle, firstMsg
        );
      this.currentChatId = session.chat.id;
      this.messages = [firstMsg];
      this.currentSequenceNumber = 1;

      // V2: 初始化 alternate_greetings 作为 Swipe 候选 1..N
      // firstMessage 已作为 Candidate 0 的内容,不需要额外 activate
      await this.initializeAlternateGreetingsAsSwipeCandidates(firstMsg.id);
    } else {
      const session: PersistedChatSession =
        await this.persistenceService.createSession(characterId, defaultTitle);
      this.currentChatId = session.chat.id;
      this.messages = [];
      this.currentSequenceNumber = 0;
    }
  }

  /**
   * 将角色的 alternateGreetings 初始化为 firstMessage 的 Swipe 候选。
   * - 调用 ensureSwipeState 创建 Candidate 0(firstMessage 已是消息内容)
   * - 对每个 alternateGreeting 调用 appendCandidate(activate=false)作为 Candidate 1..N
   * - 失败不阻塞会话创建,仅记录 warning
   *
   * @param firstMessageId firstMessage 的消息 ID
   */
  private async initializeAlternateGreetingsAsSwipeCandidates(
    firstMessageId: string
  ): Promise<void> {
    if (this.swipePersistenceService === null) {
      return;
    }
    if (this.character === null) {
      return;
    }
    const greetings: string[] = this.character.alternateGreetings;
    if (greetings.length === 0) {
      return;
    }
    try {
      // ensureSwipeState 创建 Group + Candidate 0(以 firstMessage 内容)
      await this.swipePersistenceService.ensureSwipeState(firstMessageId);
      // 逐个追加 alternateGreeting 作为 Candidate 1..N,不 activate(默认显示 firstMessage)
      for (let i = 0; i < greetings.length; i++) {
        const greeting: string = greetings[i];
        if (greeting.trim().length === 0) {
          continue;
        }
        try {
          await this.swipePersistenceService.appendCandidate(
            firstMessageId,
            {
              content: greeting,
              status: ChatMessageStatus.Completed,
              isStreaming: false
            },
            false // activate=false,保持 firstMessage 为当前显示
          );
        } catch (e) {
          // 单条追加失败不阻塞其他条目
          Logger.warn(LOG_TAG, 'init alternate_greeting failed idx=' + String(i)
            + ': ' + (e instanceof Error ? e.message : String(e)));
        }
      }
      Logger.info(LOG_TAG, 'alternate_greetings initialized count=' + String(greetings.length));
    } catch (e) {
      Logger.warn(LOG_TAG, 'initializeAlternateGreetings failed: '
        + (e instanceof Error ? e.message : String(e)));
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
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'sendMessage rejected: busy state=' + this.state);
      return;
    }

    Logger.info(LOG_TAG, 'generation start kind=normal');
    this.lastCallbacks = callbacks;
    this.generationOperationId++;

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
    // 建立 NormalResponse 活动上下文
    this.activeGeneration = {
      operationId: this.generationOperationId,
      kind: ChatGenerationKind.NormalResponse,
      chatId: this.currentChatId !== undefined ? this.currentChatId : '',
      assistantMessageId: assistantId
    };
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 5. 启动网络请求(失败也保留消息)
    this.doStream(assistantId, callbacks, this.activeGeneration);
  }

  /**
   * 重新生成最后一条 Assistant 回复(T-6.4B-1.2: 创建 Conversation Branch)。
   *
   * 不再创建 MessageSwipeCandidate,改为:
   * 1. 找到目标 Assistant 前一条 User 消息作为 fork point
   * 2. 创建新的 Conversation Branch(同级或子级)
   * 3. 新 Branch 继承 fork point 之前及本身的路径,不继承旧 Assistant
   * 4. 在新 Branch 中创建新的 Streaming Assistant Message
   * 5. 启动 Provider,流式内容只写入新 Assistant Message
   * 6. 原 Branch、原 Assistant Message、原 Candidate 数据保持不变
   *
   * T-6.3: 与 send / swipe browse / session op 互斥(通过 isBusy)。
   */
  async regenerateLastResponse(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed, cannot regenerate');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'regenerateLastResponse rejected: busy state=' + this.state
        + ' swipeOp=' + this.swipeOperationInProgress.toString()
        + ' sessionOp=' + this.sessionOperationInProgress.toString());
      return;
    }
    if (!this.canRegenerate()) {
      return;
    }

    Logger.info(LOG_TAG, 'regenerate start (branch mode)');
    this.lastCallbacks = callbacks;
    await this.regenerateAsBranch(callbacks);
  }

  /**
   * T-6.4B-1.2: 重新生成为新 Conversation Branch。
   *
   * 流程:
   * 1. 找到目标 Assistant 前一条 User 消息作为 fork point
   * 2. 判断同级 Branch:
   *    - 当前 Active Branch 的 forkMessageId === forkUserMessageId → 同级
   *      (parent = activeBranch.parentBranchId)
   *    - 否则 → 子级 (parent = activeBranch.id)
   * 3. 创建新的 Streaming Assistant Message
   * 4. 调用 forkForRegeneration 在单一事务中创建新 Branch + 复制 Links + 插入 Assistant
   * 5. 重载 messages / swipeSummaries / branchState
   * 6. 建立 BranchRegeneration ActiveGenerationContext
   * 7. 调用 doStream 启动 Provider
   *
   * 失败处理:
   * - 事务失败:不创建半成品 Branch,不启动 Provider,不修改当前 Active Branch
   * - 显示错误提示
   *
   * 不修改:
   * - 原 Branch 的 Message Link
   * - 原 Assistant Message
   * - 旧 MessageSwipeCandidate 数据
   */
  private async regenerateAsBranch(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (this.lastAssistantMessageId.length === 0) {
      callbacks.onError('没有可重新生成的回复');
      return;
    }

    const chatId: string = this.currentChatId;
    const targetAssistantId: string = this.lastAssistantMessageId;

    // 1. 在 this.messages 中找到目标 Assistant,并向前查找最近的 User 消息
    let assistantIndex: number = -1;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].id === targetAssistantId) {
        assistantIndex = i;
        break;
      }
    }
    if (assistantIndex < 0) {
      callbacks.onError('找不到目标回复');
      return;
    }
    let forkUserMessageId: string = '';
    for (let i = assistantIndex - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        forkUserMessageId = this.messages[i].id;
        break;
      }
    }
    if (forkUserMessageId.length === 0) {
      callbacks.onError('找不到原始用户消息');
      return;
    }

    // 2. 获取当前 Active Branch(完整 ConversationBranch,含 forkMessageId / parentBranchId)
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 3. 判断同级或子级
    //    同级条件:当前 Active Branch 非 Root 且 forkMessageId 等于本次 forkUserMessageId
    //    (即当前 Branch 也是从同一个 User 消息创建的再生分支)
    let parentBranchId: string;
    if (!activeBranch.isRoot
      && activeBranch.forkMessageId !== undefined
      && activeBranch.forkMessageId === forkUserMessageId) {
      // 同级:新 Branch 的 parent = 当前 Branch 的 parent
      parentBranchId = activeBranch.parentBranchId !== undefined
        ? activeBranch.parentBranchId : activeBranch.id;
    } else {
      // 子级:新 Branch 的 parent = 当前 Active Branch
      parentBranchId = activeBranch.id;
    }

    await this.forkAndStreamFromUser(
      chatId, activeBranch.id, parentBranchId, forkUserMessageId, callbacks
    );
  }

  /**
   * T-6.4B-1.2 / T-6.4B-2 公共:从指定 User Message fork 新 Branch 并启动流式生成。
   *
   * 调用方负责:
   * - 校验 disposed / isBusy / persistenceService / branchPersistenceService
   * - 解析 forkUserMessageId(从 lastAssistant 前找,或直接传入历史 User 消息 ID)
   * - 解析 parentBranchId(同级 vs 子级,基于 activeBranch.forkMessageId)
   *
   * 本方法负责:
   * 1. 创建新 Streaming Assistant Message
   * 2. 调用 forkForRegeneration 在单一事务中创建 Branch + 复制 Links + 插入 Assistant
   * 3. 重载 messages / swipeSummaries / branchState
   * 4. 建立 BranchRegeneration ActiveGenerationContext
   * 5. 调用 doStream 启动 Provider
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  private async forkAndStreamFromUser(
    chatId: string,
    sourceBranchId: string,
    parentBranchId: string,
    forkUserMessageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    // 1. 创建新的 Streaming Assistant Message
    this.generationOperationId++;
    const operationId: number = this.generationOperationId;
    const newAssistantId: string = 'msg-' + generateUuid();
    const newAssistantMessage: ChatMessage = {
      id: newAssistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 2. 占用 Branch 操作互斥锁(保护事务 + reload 期间不被并发)
    this.branchOperationInProgress = true;
    let newBranchSummary: ConversationBranchSummary;
    try {
      newBranchSummary = await this.branchPersistenceService!.forkForRegeneration(
        chatId,
        sourceBranchId,
        parentBranchId,
        forkUserMessageId,
        newAssistantMessage
      );
      Logger.info(LOG_TAG, 'ConversationBranch | regeneration branch created');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'forkAndStreamFromUser forkForRegeneration failed: ' + msg);
      this.branchOperationInProgress = false;
      callbacks.onError('创建分支失败,请重试');
      return;
    }

    // 3. 事务成功,重载内存状态(新 Branch 已成为 Active)
    try {
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'forkAndStreamFromUser reload failed: ' + msg);
      // Branch 已创建,继续执行生成,UI 状态可能与 DB 不一致但可恢复
    }

    // 4. 建立 BranchRegeneration 活动上下文
    this.activeGeneration = {
      operationId: operationId,
      kind: ChatGenerationKind.BranchRegeneration,
      chatId: chatId,
      assistantMessageId: newAssistantId,
      branchId: newBranchSummary.id,
      forkMessageId: forkUserMessageId
    };

    // 5. 设置当前 Assistant ID 和持久化追踪
    this.currentAssistantId = newAssistantId;
    this.lastPersistedContentLength = 0;
    this.pendingPersistAssistantId = newAssistantId;

    // 6. 释放 Branch 操作锁(后续通过 isBusy / activeGeneration 互斥)
    this.branchOperationInProgress = false;

    // 7. 进入 Sending 状态,通知 UI
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 8. 启动 Provider
    Logger.info(LOG_TAG, 'Regenerate | provider_started (branch mode)');
    this.doStream(newAssistantId, callbacks, this.activeGeneration);
  }

  /**
   * 是否可重新生成。
   */
  canRegenerate(): boolean {
    if (this.state === ChatState.Sending || this.state === ChatState.Streaming) {
      return false;
    }
    // 至少有一条非 firstMessage 的 Assistant 消息
    return this.lastAssistantMessageId.length > 0;
  }

  /**
   * 停止当前生成。
   * T-6.3: 统一迟到回调防护,持久化最终 Cancelled 状态后才清理上下文。
   * 幂等:连续调用两次不会重复标记或写入。
   */
  stopGeneration(): void {
    // 捕获当前 operationId,用于清理时校验
    const expectedOperationId: number = this.generationOperationId;
    this.clearStartTimer();
    // 递增操作标识,拒绝后续迟到回调
    this.generationOperationId++;
    if (this.currentHandle !== null) {
      Logger.info(LOG_TAG, 'stopGeneration abort');
      this.currentHandle.abort();
      this.currentHandle = null;
    }
    if (this.state === ChatState.Sending || this.state === ChatState.Streaming) {
      const ctx: ActiveGenerationContext | null = this.activeGeneration;
      const kind: string = ctx !== null ? ctx.kind : 'unknown';
      // 不调用 flushPersistence() — persistFinalAssistant 已包含完整最终状态,
      // 避免与 persistFinalAssistant 嵌套事务冲突(T-6.4A-R3)
      // 将当前 Assistant 消息标记为已取消(创建新对象和新数组)
      this.markAssistant(this.currentAssistantId, ChatMessageStatus.Cancelled, undefined, undefined);
      this.emitMessages(this.lastCallbacks);
      Logger.info(LOG_TAG, 'GenerationFinal | kind=' + kind + ' stage=callback_stop');
      // 持久化最终 Cancelled 状态,完成后才清理上下文
      this.persistFinalAssistant(this.currentAssistantId).then((): void => {
        Logger.info(LOG_TAG, 'GenerationFinal | kind=' + kind + ' stage=message_cancelled_persisted');
        Logger.info(LOG_TAG, 'generation finalized status=cancelled');
        // Swipe 候选处理:更新摘要生成标志
        if (ctx !== null && ctx.kind === ChatGenerationKind.SwipeCandidate) {
          this.updateSwipeSummaryGeneratingFlag(false);
        }
        // 更新 Chat 活跃时间(完成一次新生成)
        this.persistChatActivity();
        // 持久化后才清理活动上下文
        this.clearActiveGeneration(expectedOperationId);
        Logger.info(LOG_TAG, 'GenerationFinal | kind=' + kind + ' stage=context_cleared');
        this.currentAssistantId = null;
        this.setState(ChatState.Cancelled, this.lastCallbacks);
      }).catch((_e: Object): void => {
        this.clearActiveGeneration(expectedOperationId);
        this.currentAssistantId = null;
        this.setState(ChatState.Cancelled, this.lastCallbacks);
      });
    }
  }

  /**
   * 是否正在生成。
   */
  isGenerating(): boolean {
    return this.state === ChatState.Sending || this.state === ChatState.Streaming;
  }

  /**
   * 是否正在执行 Swipe 浏览/切换操作(非生成)。
   * T-6.3: 用于和生成互斥。
   */
  isSwipeOperating(): boolean {
    return this.swipeOperationInProgress;
  }

  /**
   * 是否处于忙碌状态(生成中或 Swipe 操作中或会话操作中或 Branch 操作中)。
   * T-6.3: 统一忙碌判断,Service 层保护,不依赖按钮禁用。
   * T-6.4B-1: 增加 branchOperationInProgress 互斥。
   */
  isBusy(): boolean {
    return this.isGenerating()
      || this.swipeOperationInProgress
      || this.sessionOperationInProgress
      || this.branchOperationInProgress;
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

  // ===== T-4.5 多会话操作 =====

  /** 会话操作进行中(防止并发新建/切换/删除) */
  private sessionOperationInProgress: boolean = false;

  /**
   * 列出当前聊天上下文下的会话。
   * - 有角色:使用 character.id 精确查询
   * - 无角色:查询 character_id IS NULL(仅普通助手会话)
   * - 始终排除 archived
   * - 排序:last_message_at DESC → updated_at DESC → id ASC
   * - 默认最多 50 条
   *
   * @returns 会话列表(可能为空)。无 persistenceService 时返回空数组。
   */
  async listSessions(): Promise<Chat[]> {
    if (this.persistenceService === null) {
      return [];
    }
    const characterId: string | undefined =
      this.character !== null ? this.character.id : undefined;
    return await this.persistenceService.listSessionsForContext(characterId);
  }

  /**
   * 新建会话。
   *
   * 流程:
   * 1. 校验:未生成、未在执行其他会话操作
   * 2. flush pending persistence
   * 3. 使用当前角色上下文创建新 Chat
   * 4. 有角色 firstMessage 时只创建一次
   * 5. 设置新的 currentChatId、currentSequenceNumber
   * 6. 用新数组替换 messages
   * 7. 通知 onMessagesChanged
   * 8. 清除上一次生成状态、错误状态和 Token 统计
   *
   * 不会:清空旧 Chat 数据 / 复用旧 chatId / 把旧 messages 写入新 Chat / 重复插入 firstMessage。
   *
   * @throws Error 生成中或会话操作进行中,或持久化失败
   */
  async startNewSession(): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isGenerating()) {
      throw new Error('请先停止当前回复');
    }
    if (this.sessionOperationInProgress) {
      throw new Error('会话操作进行中,请稍候');
    }
    if (this.swipeOperationInProgress) {
      throw new Error('请先完成当前 Swipe 操作');
    }
    this.sessionOperationInProgress = true;
    try {
      this.flushPersistence();
      const characterId: string | undefined =
        this.character !== null ? this.character.id : undefined;
      await this.createNewSession(characterId);
      this.lastTokenBudget = undefined;
      this.lastHistoryTrimResult = undefined;
      this.currentAssistantId = null;
      this.swipeSummaries = [];
      this.lastAssistantMessageId = '';
      this.activeGeneration = null;
      // T-6.4B-1: 新建会话后刷新 Branch 状态
      await this.refreshBranchState();
      this.setState(ChatState.Idle, this.lastCallbacks);
      this.emitMessages(this.lastCallbacks);
      Logger.info(LOG_TAG, 'startNewSession ok');
    } finally {
      this.sessionOperationInProgress = false;
    }
  }

  /**
   * 切换到指定会话。
   *
   * 流程:
   * 1. 校验:未生成、未在执行其他会话操作
   * 2. 验证 chatId 非空
   * 3. 相同 chatId 直接返回(不重复加载、不重复 firstMessage)
   * 4. flush pending persistence
   * 5. 加载目标会话(自动 normalize interrupted Streaming)
   * 6. 验证目标会话属于当前角色或普通助手上下文
   * 7. 替换 currentChatId、currentSequenceNumber、messages
   * 8. 通知页面更新
   * 9. 清除旧会话的 UI 临时状态
   *
   * 不会:自动发起模型请求 / 信任列表传入的 Chat 对象(在 Service 层再次校验)。
   *
   * @param chatId 目标会话 id
   * @throws Error 生成中、会话操作进行中、chatId 无效、目标不存在、目标不属于当前上下文
   */
  async switchSession(chatId: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isGenerating()) {
      throw new Error('请先停止当前回复');
    }
    if (this.sessionOperationInProgress) {
      throw new Error('会话操作进行中,请稍候');
    }
    if (this.swipeOperationInProgress) {
      throw new Error('请先完成当前 Swipe 操作');
    }
    if (chatId.length === 0) {
      throw new Error('会话 id 为空');
    }
    this.sessionOperationInProgress = true;
    try {
      if (this.currentChatId === chatId) {
        Logger.info(LOG_TAG, 'switchSession same chatId, skip');
        return;
      }
      this.flushPersistence();
      await this.switchToSessionInternal(chatId);
      this.lastTokenBudget = undefined;
      this.lastHistoryTrimResult = undefined;
      this.currentAssistantId = null;
      this.activeGeneration = null;
      this.setState(ChatState.Idle, this.lastCallbacks);
      this.emitMessages(this.lastCallbacks);
    } finally {
      this.sessionOperationInProgress = false;
    }
  }

  /**
   * 删除指定会话。
   *
   * - 删除非当前会话:删除 Chat 和 Message(事务),当前页面消息不变
   * - 删除当前会话:删除后按以下顺序回退:
   *   1. 查询当前上下文剩余会话
   *   2. 存在则加载最近一条
   *   3. 不存在则立即创建一条新会话(有角色 firstMessage 时加入)
   *   4. 页面立即更新为新会话消息
   *
   * @param chatId 待删除的会话 id
   * @throws Error 生成中、会话操作进行中、删除失败
   */
  async deleteSession(chatId: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isGenerating()) {
      throw new Error('请先停止当前回复');
    }
    if (this.sessionOperationInProgress) {
      throw new Error('会话操作进行中,请稍候');
    }
    if (this.swipeOperationInProgress) {
      throw new Error('请先完成当前 Swipe 操作');
    }
    if (chatId.length === 0) {
      throw new Error('会话 id 为空');
    }
    if (this.persistenceService === null) {
      throw new Error('persistenceService unavailable');
    }
    this.sessionOperationInProgress = true;
    try {
      await this.persistenceService.deleteSession(chatId);
      Logger.info(LOG_TAG, 'deleteSession ok');

      if (chatId === this.currentChatId) {
        // 删除的是当前会话:查询剩余,自动切换或新建
        const characterId: string | undefined =
          this.character !== null ? this.character.id : undefined;
        const remaining: Chat[] =
          await this.persistenceService.listSessionsForContext(characterId, 50);
        if (remaining.length > 0) {
          // 列表已按 last_message_at DESC 排序,首条为最近会话
          await this.switchToSessionInternal(remaining[0].id);
        } else {
          // 无剩余会话,创建新会话
          await this.createNewSession(characterId);
        }
        this.lastTokenBudget = undefined;
        this.lastHistoryTrimResult = undefined;
        this.currentAssistantId = null;
        this.activeGeneration = null;
        // T-6.4B-1: 删除会话后刷新 Branch 状态
        await this.refreshBranchState();
        this.setState(ChatState.Idle, this.lastCallbacks);
        this.emitMessages(this.lastCallbacks);
      }
    } finally {
      this.sessionOperationInProgress = false;
    }
  }

  /**
   * 是否正在执行会话操作(新建/切换/删除)。
   * 用于页面禁用按钮。
   */
  isSessionOperationInProgress(): boolean {
    return this.sessionOperationInProgress;
  }

  /**
   * 内部:切换到指定会话并替换当前状态(不持锁,由调用方持锁)。
   * 验证目标会话属于当前角色或普通助手上下文。
   */
  private async switchToSessionInternal(chatId: string): Promise<void> {
    if (this.persistenceService === null) {
      throw new Error('persistenceService unavailable');
    }
    const session: PersistedChatSession | null =
      await this.persistenceService.loadSession(chatId);
    if (session === null) {
      throw new Error('会话不存在或已删除');
    }
    // 验证上下文归属
    const expectedCharId: string | undefined =
      this.character !== null ? this.character.id : undefined;
    const actualCharId: string | undefined = session.chat.characterId;
    if (expectedCharId !== actualCharId) {
      throw new Error('目标会话不属于当前聊天上下文');
    }
    this.currentChatId = session.chat.id;
    this.messages = session.messages.slice();
    this.currentSequenceNumber = session.maxSequenceNumber;
    // 加载 Swipe summaries
    this.swipeSummaries = [];
    this.lastAssistantMessageId = '';
    if (this.swipePersistenceService !== null && this.currentChatId !== undefined) {
      this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
    }
    this.updateLastAssistantMessageId();
    // T-6.4B-1: 切换会话后刷新 Branch 状态
    await this.refreshBranchState();
    Logger.info(LOG_TAG, 'switchSession ok messages=' + this.messages.length.toString());
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
    const hadActiveGeneration: boolean = this.activeGeneration !== null;
    const wasGenerating: boolean = this.isGenerating();
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
    this.activeGeneration = null;
    this.swipeSummaries = [];
    this.state = ChatState.Idle;
    if (wasGenerating) {
      Logger.info(LOG_TAG, 'SessionCleanup | action=cancel reason=active_streaming');
    } else if (hadActiveGeneration) {
      Logger.info(LOG_TAG, 'SessionCleanup | action=skip reason=already_completed');
    } else {
      Logger.info(LOG_TAG, 'SessionCleanup | action=skip reason=no_active_generation');
    }
    Logger.info(LOG_TAG, 'dispose');
  }

  // ===== 内部方法 =====

  /**
   * T-6.3 / T-6.4B-1.2: 统一迟到回调判断。
   * 检查 operationId、kind、chatId、assistantMessageId、(Swipe 时)candidateIndex、
   * (BranchRegeneration 时)branchId 和 forkMessageId。
   * 所有异步路径(delta / scheduled flush / immediate flush / complete / error / stop 后剩余回调
   * / Provider start 失败处理)必须调用本方法。
   */
  private isCurrentGeneration(context: ActiveGenerationContext): boolean {
    const current: ActiveGenerationContext | null = this.activeGeneration;
    if (current === null) {
      return false;
    }
    if (current.operationId !== context.operationId) {
      return false;
    }
    if (current.kind !== context.kind) {
      return false;
    }
    if (current.chatId !== context.chatId) {
      return false;
    }
    if (current.assistantMessageId !== context.assistantMessageId) {
      return false;
    }
    // Swipe 类型需校验 candidateIndex
    if (context.kind === ChatGenerationKind.SwipeCandidate) {
      const ctxIdx: number | undefined = context.swipeCandidateIndex;
      const curIdx: number | undefined = current.swipeCandidateIndex;
      if (ctxIdx !== curIdx) {
        return false;
      }
    }
    // BranchRegeneration 类型需校验 branchId 和 forkMessageId
    if (context.kind === ChatGenerationKind.BranchRegeneration) {
      if (current.branchId !== context.branchId) {
        return false;
      }
      if (current.forkMessageId !== context.forkMessageId) {
        return false;
      }
    }
    return true;
  }

  /**
   * T-6.3: 统一活动生成状态清理。
   * 只有 operationId 匹配时才能清理(防止迟到清理污染下一次生成)。
   * 顺序要求:调用方必须先 persist 最终状态后再调用本方法。
   * 本方法清除:persistence timer、activeGeneration、pending buffer、生成中 UI 状态标记。
   * 幂等:同一 operationId 多次调用安全。
   */
  private clearActiveGeneration(expectedOperationId: number): void {
    const current: ActiveGenerationContext | null = this.activeGeneration;
    if (current === null) {
      return;
    }
    if (current.operationId !== expectedOperationId) {
      return;
    }
    if (current.kind === ChatGenerationKind.SwipeCandidate) {
      Logger.info(LOG_TAG, 'Regenerate | state_cleared');
    }
    this.clearPersistenceTimer();
    this.pendingPersistAssistantId = null;
    this.pendingSwipePersistPromise = null;
    this.activeGeneration = null;
  }

  private async doStream(
    assistantId: string,
    callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext
  ): Promise<void> {
    // 捕获本次请求的 operationId,用于迟到回调判断
    const operationId: number = context.operationId;

    // 内部辅助:判断当前回调是否仍属于本次生成
    const isCurrent = (): boolean => {
      return this.isCurrentGeneration(context);
    };

    // 内部辅助:Provider start 失败 / 同步异常的统一处理。
    // 必须在标记 Failed 前完成最终状态持久化,然后再清理上下文。
    const handleStartFailure = (errorMessage: string): void => {
      // 上下文已被 stop 或新请求替换时,直接退出,避免污染新请求
      if (!isCurrent()) {
        Logger.warn(LOG_TAG, 'start failure ignored: stale context');
        return;
      }
      // 不调用 flushPersistence() — persistFinalAssistant 已包含完整最终状态,
      // 避免与 persistFinalAssistant 嵌套事务冲突(T-6.4A-R3)
      // 标记 Assistant 为 Failed(同时更新内存消息和 Swipe 候选,路由基于 activeGeneration.kind)
      this.finalizeAssistant(
        assistantId, '', ChatMessageStatus.Failed, errorMessage, callbacks
      );
      this.currentAssistantId = null;
      Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_start_failure');
      // 持久化最终 Failed 状态,完成后才清理上下文
      this.persistFinalAssistant(assistantId).then((): void => {
        Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_failed_persisted');
        Logger.info(LOG_TAG, 'generation finalized status=failed');
        // Swipe:更新摘要生成标志
        if (context.kind === ChatGenerationKind.SwipeCandidate) {
          this.updateSwipeSummaryGeneratingFlag(false);
        }
        // 更新 Chat 活跃时间
        this.persistChatActivity();
        // 清理活动上下文(仅当仍是本次 operationId)
        this.clearActiveGeneration(operationId);
        Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=context_cleared');
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError(errorMessage);
      }).catch((_e: Object): void => {
        this.clearActiveGeneration(operationId);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError(errorMessage);
      });
    };

    const streamCallbacks: ChatStreamCallbacks = {
      onStart: (): void => {
        this.clearStartTimer();
        Logger.info(LOG_TAG, 'onStart');
      },
      onDelta: (delta: ChatDelta): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        if (this.state !== ChatState.Streaming) {
          return;
        }
        if (!isCurrent()) {
          Logger.warn(LOG_TAG, 'stale callback ignored type=delta');
          return;
        }
        // T-6.4B-Closeout: 移除 delta 级 Regenerate 高频日志
        this.appendDelta(assistantId, delta.content, callbacks);
        // 节流持久化 delta(路由基于 activeGeneration.kind)
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
        if (!isCurrent()) {
          Logger.warn(LOG_TAG, 'stale callback ignored type=complete');
          return;
        }
        // 不调用 flushPersistence() — persistFinalAssistant 已包含完整最终状态,
        // 避免与 persistFinalAssistant 嵌套事务冲突(T-6.4A-R3)
        const finalStatus: ChatMessageStatus = this.finalizeAssistant(
          assistantId, result.content, ChatMessageStatus.Completed, undefined, callbacks
        );
        this.currentAssistantId = null;
        Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_complete');
        // 持久化最终状态,完成后才清理上下文(防止 Completed 被 normalize 误转为 Cancelled)
        this.persistFinalAssistant(assistantId).then((): void => {
          Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_completed_persisted');
          Logger.info(LOG_TAG, 'generation finalized status=completed');
          // Swipe:更新摘要生成标志
          if (context.kind === ChatGenerationKind.SwipeCandidate) {
            Logger.info(LOG_TAG, 'Regenerate | completed');
            Logger.info(LOG_TAG, 'SwipeRuntime | stage=final_persist_complete');
            this.updateSwipeSummaryGeneratingFlag(false);
          }
          // 更新 Chat 活跃时间(完成一次新生成)
          this.persistChatActivity();
          // 清理活动上下文(最终状态持久化完成后才清理)
          this.clearActiveGeneration(operationId);
          Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=context_cleared');
          // 更新 lastAssistantMessageId(setState 前更新,确保 onStateChanged 读到正确值)
          this.updateLastAssistantMessageId();
          // 空回复时 finalizeAssistant 返回 Failed,state 也应为 Failed
          if (finalStatus === ChatMessageStatus.Failed) {
            this.setState(ChatState.Failed, callbacks);
            callbacks.onError('模型返回了空回复,请重试');
          } else {
            this.setState(ChatState.Completed, callbacks);
          }
          Logger.info(LOG_TAG, 'stream completed deltaCount=' + result.deltaCount);
        }).catch((_e: Object): void => {
          // 持久化失败时仍清理上下文,避免状态卡死
          this.clearActiveGeneration(operationId);
          this.updateLastAssistantMessageId();
          if (context.kind === ChatGenerationKind.SwipeCandidate) {
            // Swipe 持久化失败:DB Candidate 仍为 Streaming,重载后变为 Cancelled
            Logger.warn(LOG_TAG, 'SwipeRuntime | stage=final_persist_failed');
            this.setState(ChatState.Failed, callbacks);
            callbacks.onError('候选回复持久化失败,请重试');
          } else if (finalStatus === ChatMessageStatus.Failed) {
            this.setState(ChatState.Failed, callbacks);
            callbacks.onError('模型返回了空回复,请重试');
          } else {
            this.setState(ChatState.Completed, callbacks);
          }
        });
      },
      onError: (error: NetworkError): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        // stopGeneration 已将状态置为 Cancelled,迟到的 onError 忽略
        if (this.state === ChatState.Cancelled) {
          return;
        }
        if (!isCurrent()) {
          Logger.warn(LOG_TAG, 'stale callback ignored type=error');
          return;
        }
        // 不调用 flushPersistence() — persistFinalAssistant 已包含完整最终状态,
        // 避免与 persistFinalAssistant 嵌套事务冲突(T-6.4A-R3)
        this.finalizeAssistant(
          assistantId, '', ChatMessageStatus.Failed, error.message, callbacks
        );
        this.currentAssistantId = null;
        Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_error');
        // 持久化最终 Failed 状态,完成后才清理上下文
        this.persistFinalAssistant(assistantId).then((): void => {
          Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_failed_persisted');
          Logger.info(LOG_TAG, 'generation finalized status=failed');
          // Swipe:更新摘要生成标志
          if (context.kind === ChatGenerationKind.SwipeCandidate) {
            Logger.info(LOG_TAG, 'Regenerate | failed');
            this.updateSwipeSummaryGeneratingFlag(false);
          }
          // 更新 Chat 活跃时间
          this.persistChatActivity();
          // 清理活动上下文
          this.clearActiveGeneration(operationId);
          Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=context_cleared');
          this.setState(ChatState.Failed, callbacks);
          callbacks.onError(error.message);
          Logger.info(LOG_TAG, 'stream failed: ' + error.message);
        }).catch((_e: Object): void => {
          this.clearActiveGeneration(operationId);
          this.setState(ChatState.Failed, callbacks);
          callbacks.onError(error.message);
        });
      }
    };

    // 启动超时保护(携带 context 用于迟到 timer 判断)
    this.startStartTimer(assistantId, callbacks, context);

    // 创建请求级 Preset 快照(每次请求开始时读取一次)
    let snapshot: PromptPresetRequestSnapshot;
    try {
      snapshot = await this.createPresetRequestSnapshot();
    } catch (e) {
      this.clearStartTimer();
      handleStartFailure(e instanceof Error ? e.message : String(e));
      return;
    }

    // 构建请求消息(通过 PromptBuilder 统一构建)
    // Swipe 候选生成时排除目标 Assistant(不将其当前正文作为历史)
    // T-6.4B-1.2: BranchRegeneration 也排除新空 Assistant(避免把空回复作为历史)
    const excludeId: string | undefined =
      (context.kind === ChatGenerationKind.SwipeCandidate
        || context.kind === ChatGenerationKind.BranchRegeneration)
        ? assistantId : undefined;
    let requestMessages: ChatMessage[];
    try {
      requestMessages = await this.buildRequestMessages(snapshot.presetSystemPrompt, excludeId);
    } catch (e) {
      this.clearStartTimer();
      handleStartFailure(String(e));
      return;
    }

    // 计算 Token 预算 → 超预算则裁剪 → 重算预算
    await this.updateRequestPlan(requestMessages, snapshot.generationSettings);

    // 固定段超预算时阻止 Provider 启动
    if (this.lastTokenBudget !== undefined && this.lastTokenBudget.exceedsBudget) {
      this.clearStartTimer();
      handleStartFailure('输入超出上下文窗口,请缩短对话或清除预设');
      return;
    }

    // 构建生效的请求选项(Preset 覆盖模型配置)
    const effectiveOptions: ChatRequestOptions = {
      temperature: snapshot.generationSettings.temperature !== undefined
        ? snapshot.generationSettings.temperature
        : DEFAULT_OPTIONS.temperature,
      topP: snapshot.generationSettings.topP !== undefined
        ? snapshot.generationSettings.topP
        : DEFAULT_OPTIONS.topP,
      maxTokens: snapshot.generationSettings.maxOutputTokens !== undefined
        ? snapshot.generationSettings.maxOutputTokens
        : DEFAULT_OPTIONS.maxTokens,
      stream: true
    };

    try {
      const planMessages: ChatMessage[] = this.lastHistoryTrimResult !== undefined
        ? this.lastHistoryTrimResult.messages
        : requestMessages;
      this.currentHandle = this.modelService.streamCurrentChat(
        planMessages, effectiveOptions, streamCallbacks
      );
      this.setState(ChatState.Streaming, callbacks);
    } catch (e) {
      this.clearStartTimer();
      handleStartFailure(String(e));
    }
  }

  /**
   * 创建请求级 Preset 快照。
   *
   * 每次 sendMessage/regenerate 开始时调用一次。
   * 读取当前 Preset,与模型配置合并为 EffectiveGenerationSettings。
   *
   * 读取失败规则:
   * - 当前 ID 不存在:清空选择,返回 null(使用模型配置)
   * - Repository 读取异常:抛出错误,阻止请求
   * - Preset 数据损坏:抛出错误,阻止请求
   *
   * @returns 请求快照
   * @throws Error 无法读取当前预设或数据损坏
   */
  private async createPresetRequestSnapshot(): Promise<PromptPresetRequestSnapshot> {
    // 1. 获取模型配置作为基准
    let baseTemperature: number | undefined = undefined;
    let baseTopP: number | undefined = undefined;
    let baseMaxOutputTokens: number | undefined = undefined;
    let baseContextWindow: number | undefined = undefined;
    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config !== null) {
        baseTemperature = config.temperature;
        baseTopP = config.topP;
        baseMaxOutputTokens = config.maxTokens;
        baseContextWindow = config.contextWindow;
      }
    } catch (e) {
      // 配置获取失败:使用空 base,后续由 DEFAULT_OPTIONS 兜底
      Logger.warn(LOG_TAG, 'createPresetRequestSnapshot getCurrentConfig failed: '
        + (e instanceof Error ? e.message : String(e)));
    }
    const base: EffectiveGenerationSettings = {
      temperature: baseTemperature,
      topP: baseTopP,
      maxOutputTokens: baseMaxOutputTokens,
      contextWindow: baseContextWindow
    };

    // 2. 获取当前 Preset
    if (this.promptPresetService === null) {
      Logger.info(LOG_TAG, 'preset snapshot resolved enabled=false');
      return createSnapshotWithoutPreset(
        resolveEffectiveGenerationSettings(base)
      );
    }

    let preset: PromptPreset | null = null;
    try {
      preset = await this.promptPresetService.getCurrentPreset();
    } catch (e) {
      // Repository 读取失败:阻止请求
      throw new Error('无法读取当前提示词预设，请重试');
    }

    if (preset === null) {
      Logger.info(LOG_TAG, 'preset snapshot resolved enabled=false');
      return createSnapshotWithoutPreset(
        resolveEffectiveGenerationSettings(base)
      );
    }

    // 3. 合并参数
    let settings: EffectiveGenerationSettings;
    try {
      settings = resolveEffectiveGenerationSettings(base, preset);
    } catch (e) {
      // 数据损坏:阻止请求
      throw new Error('无法读取当前提示词预设，请重试');
    }

    Logger.info(LOG_TAG, 'preset snapshot resolved enabled=true');
    return createSnapshotWithPreset(preset, settings);
  }

  /**
   * 构建请求消息列表(通过 PromptBuilder 统一构建)。
   *
   * 角色、世界书和聊天历史由 PromptBuilder 按固定顺序组装。
   * 世界书内容不会写入 this.messages。
   * 无 PromptBuilder 或无角色时,返回原始消息列表(跳过 System 消息)。
   *
   * V2 字段支持:
   * - character.mesExample:作为 DialogueExamples 段(由 PromptBuilder 处理)
   * - character.postHistoryInstructions:作为 PostHistory 段(由 PromptBuilder 处理)
   * - character.systemPrompt + {{original}}:由 PromptBuilder 处理
   * - character.characterBookId:加载关联 Lorebook 作为 characterBook 参与匹配
   *
   * @param presetSystemPrompt Preset 附加 System Prompt(可选,已宏替换)
   */
  private async buildRequestMessages(
    presetSystemPrompt?: string,
    excludeMessageId?: string
  ): Promise<ChatMessage[]> {
    // 确定用于构建 Prompt 的消息列表
    let sourceMessages: ChatMessage[];
    if (excludeMessageId !== undefined && excludeMessageId.length > 0) {
      // 排除目标 Assistant(候选生成时使用)
      sourceMessages = [];
      for (let i = 0; i < this.messages.length; i++) {
        if (this.messages[i].id !== excludeMessageId) {
          sourceMessages.push(this.messages[i]);
        }
      }
    } else {
      sourceMessages = this.messages;
    }

    if (this.promptBuilder === null) {
      // 无 PromptBuilder:跳过 System 消息,保留 User/Assistant
      const filtered: ChatMessage[] = [];
      for (let i = 0; i < sourceMessages.length; i++) {
        if (sourceMessages[i].role !== ChatRole.System) {
          filtered.push(sourceMessages[i]);
        }
      }
      return filtered;
    }

    // 获取当前全局世界书
    let lorebook: Lorebook | undefined = undefined;
    if (this.lorebookService !== null) {
      lorebook = await this.lorebookService.getCurrentLorebook() ?? undefined;
    }

    // 加载角色专属世界书(通过 characterBookId)
    let characterBook: Lorebook | undefined = undefined;
    if (this.character !== null
      && this.character.characterBookId.length > 0
      && this.lorebookService !== null) {
      try {
        const book: Lorebook | null = await this.lorebookService.getById(
          this.character.characterBookId
        );
        if (book !== null) {
          characterBook = book;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load character_book failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // 通过 PromptBuilder.buildMacroContext 构建宏替换上下文
    // (包含 description / personality / scenario / mesExample / lastMessage / originalContent)
    const macroContext: MacroContext = this.promptBuilder.buildMacroContext(
      this.character,
      DEFAULT_USER_NAME,
      sourceMessages
    );

    const context: PromptBuildContext = {
      character: this.character !== null ? this.character : undefined,
      lorebook: lorebook,
      characterBook: characterBook,
      messages: sourceMessages,
      macroContext: macroContext,
      presetSystemPrompt: presetSystemPrompt
      // enablePostHistoryInstructions 默认为 true
      // 后续可由 Preset 配置控制
    };

    const result: PromptBuildResult = this.promptBuilder.build(context);
    Logger.info(LOG_TAG, 'buildRequestMessages: segments=' + result.messages.length.toString()
      + ' lorebook=' + result.matchedLorebookEntryIds.length.toString()
      + (excludeMessageId !== undefined ? ' excluded=1' : ''));
    return result.messages;
  }

  /**
   * 统一更新请求计划:计算 Token 预算,若超预算则裁剪,再重算预算。
   * 失败不抛出,仅清空结果并记录安全日志。
   *
   * 记录中只输出 messages 数、Token 数与超预算标志,不记录任何消息内容。
   *
   * @param requestMessages PromptBuilder 输出的请求消息
   * @param effectiveSettings 生效的生成参数(含 contextWindow 和 maxOutputTokens)
   */
  private async updateRequestPlan(
    requestMessages: ChatMessage[],
    effectiveSettings: EffectiveGenerationSettings
  ): Promise<void> {
    if (this.tokenCounter === null) {
      // 无 TokenCounter:跳过,使用原始请求消息
      this.lastTokenBudget = undefined;
      this.lastHistoryTrimResult = undefined;
      return;
    }

    let contextWindow: number = DEFAULT_CONTEXT_WINDOW;
    let reserved: number = DEFAULT_RESERVED_OUTPUT_TOKENS;

    // 从 effectiveSettings 获取 contextWindow
    if (effectiveSettings.contextWindow !== undefined) {
      contextWindow = effectiveSettings.contextWindow;
    }

    // 从 effectiveSettings 获取 maxOutputTokens(预留输出)
    if (effectiveSettings.maxOutputTokens !== undefined &&
      effectiveSettings.maxOutputTokens > 0) {
      reserved = effectiveSettings.maxOutputTokens;
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
   * T-6.3: 定时器触发时通过 isCurrentGeneration 校验,避免污染下一次生成。
   */
  private startStartTimer(
    assistantId: string,
    callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext
  ): void {
    this.clearStartTimer();
    this.startTimerId = setTimeout((): void => {
      this.startTimerId = -1;
      if (this.disposed) {
        return;
      }
      if (this.state !== ChatState.Sending && this.state !== ChatState.Streaming) {
        return;
      }
      // 上下文已被 stop 或新请求替换:迟到 timer 不处理
      if (!this.isCurrentGeneration(context)) {
        Logger.warn(LOG_TAG, 'stale callback ignored type=startTimer');
        return;
      }
      Logger.warn(LOG_TAG, 'start timeout fired');
      if (this.currentHandle !== null) {
        this.currentHandle.abort();
        this.currentHandle = null;
      }
      // flush 任何 pending delta
      this.flushPersistence();
      this.finalizeAssistant(
        assistantId, '', ChatMessageStatus.Failed, '请求启动超时,请重试', callbacks
      );
      this.currentAssistantId = null;
      Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_start_timeout');
      // 持久化最终 Failed 状态,完成后才清理上下文
      this.persistFinalAssistant(assistantId).then((): void => {
        Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_failed_persisted');
        Logger.info(LOG_TAG, 'generation finalized status=failed');
        // Swipe:更新摘要生成标志
        if (context.kind === ChatGenerationKind.SwipeCandidate) {
          this.updateSwipeSummaryGeneratingFlag(false);
        }
        // 更新 Chat 活跃时间
        this.persistChatActivity();
        // 清理活动上下文
        this.clearActiveGeneration(context.operationId);
        Logger.info(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=context_cleared');
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('请求启动超时,请重试');
      }).catch((_e: Object): void => {
        this.clearActiveGeneration(context.operationId);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('请求启动超时,请重试');
      });
    }, START_TIMEOUT_MS);
  }

  private clearStartTimer(): void {
    if (this.startTimerId !== -1) {
      clearTimeout(this.startTimerId);
      this.startTimerId = -1;
    }
  }

  private setState(state: ChatState, callbacks: ChatServiceCallbacks | null): void {
    if (this.disposed) {
      return;
    }
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
   * T-6.3: 不在此方法内同步 Swipe 候选,候选持久化由 persistFinalAssistant 统一路由。
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
    if (this.persistenceService === null && this.swipePersistenceService === null) {
      return;
    }
    if (this.currentChatId === undefined) {
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
   * T-6.3: 路由基于 activeGeneration.kind
   *   - SwipeCandidate → MessageSwipePersistenceService.updateCandidate
   *   - NormalResponse / 无活动生成 → ChatPersistenceService.updateMessage
   */
  private flushPersistence(): void {
    this.clearPersistenceTimer();
    if (this.currentChatId === undefined) {
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

    const ctx: ActiveGenerationContext | null = this.activeGeneration;
    if (ctx !== null
      && ctx.kind === ChatGenerationKind.SwipeCandidate
      && this.swipePersistenceService !== null
      && ctx.swipeCandidateIndex !== undefined) {
      // 路由到 swipe 候选持久化
      const updates: MessageSwipeCandidateUpdates = {
        content: msg.content,
        status: ChatMessageStatus.Streaming,
        isStreaming: true
      };
      // T-6.4A-R6: 串行化 delta persist,防止与 final persist 嵌套事务
      const deltaP: Promise<void> = this.swipePersistenceService.updateCandidate(
        ctx.assistantMessageId,
        ctx.swipeCandidateIndex,
        updates
      ).then((): void => {
        // delta persist ok
      }).catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'swipe delta persist failed: '
          + (e instanceof Error ? e.message : String(e)));
      });
      // 链接到 pendingSwipePersistPromise 尾部,确保串行
      if (this.pendingSwipePersistPromise !== null) {
        this.pendingSwipePersistPromise = this.pendingSwipePersistPromise.then((): Promise<void> => deltaP);
      } else {
        this.pendingSwipePersistPromise = deltaP;
      }
      Logger.info(LOG_TAG, 'persistence route kind=swipe');
    } else if (this.persistenceService !== null) {
      // 正常持久化
      this.persistenceService.updateMessage(this.currentChatId, msg).catch(
        (e: Object): void => {
          Logger.warn(LOG_TAG, 'delta persist failed: '
            + (e instanceof Error ? e.message : String(e)));
        }
      );
      Logger.info(LOG_TAG, 'persistence route kind=normal');
    }
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
   * T-6.3: 路由基于 activeGeneration.kind
   *   - SwipeCandidate → MessageSwipePersistenceService.updateCandidate
   *   - NormalResponse / 无活动生成 → ChatPersistenceService.updateMessage
   *
   * 注意:调用方必须在 persist 完成后才调用 clearActiveGeneration。
   */
  private persistFinalAssistant(assistantId: string | null): Promise<void> {
    if (assistantId === null) {
      return Promise.resolve();
    }
    if (this.currentChatId === undefined) {
      return Promise.resolve();
    }
    const msg: ChatMessage | undefined = this.findMessageById(assistantId);
    if (msg === undefined) {
      return Promise.resolve();
    }
    this.lastPersistedContentLength = msg.content.length;
    this.pendingPersistAssistantId = null;

    // T-6.4A-R6: 停止后续 persistence timer,防止 delta flush 与 final persist 并发
    this.clearPersistenceTimer();
    // 异步写入,1 次重试,返回 Promise 供调用方等待
    // Swipe 路径:先等待在飞的 delta persist 完成,再开始唯一 final 事务
    const pending: Promise<void> | null = this.pendingSwipePersistPromise;
    if (pending !== null) {
      this.pendingSwipePersistPromise = null;
      return pending.then((): Promise<void> => this.persistWithRetry(msg, 1));
    }
    return this.persistWithRetry(msg, 1);
  }

  private persistWithRetry(msg: ChatMessage, retriesLeft: number): Promise<void> {
    if (this.currentChatId === undefined) {
      return Promise.resolve();
    }
    const chatId: string = this.currentChatId;
    const ctx: ActiveGenerationContext | null = this.activeGeneration;

    if (ctx !== null
      && ctx.kind === ChatGenerationKind.SwipeCandidate
      && this.swipePersistenceService !== null
      && ctx.swipeCandidateIndex !== undefined) {
      // 路由到 swipe 候选持久化(不再额外更新 MessageRepository,
      // 候选物化由 Swipe Service 在 activateCandidate 中完成)
      const updates: MessageSwipeCandidateUpdates = {
        content: msg.content,
        status: msg.status ?? ChatMessageStatus.Completed,
        errorMessage: msg.errorMessage !== undefined ? msg.errorMessage : undefined,
        isStreaming: msg.isStreaming ?? false
      };
      Logger.info(LOG_TAG, 'persistence route kind=swipe');
      return this.swipePersistenceService.updateCandidate(
        ctx.assistantMessageId,
        ctx.swipeCandidateIndex,
        updates
      ).then((): void => {
        Logger.info(LOG_TAG, 'swipe final persist ok');
      }).catch((e: Object): Promise<void> => {
        const msg2: string = e instanceof Error ? e.message : String(e);
        if (retriesLeft > 0) {
          Logger.warn(LOG_TAG, 'swipe final persist retry: ' + msg2);
          return this.persistWithRetry(msg, retriesLeft - 1);
        }
        Logger.warn(LOG_TAG, 'swipe final persist failed: ' + msg2);
        Logger.info(LOG_TAG, 'SwipeRuntime | stage=final_persist_failed');
        return Promise.reject(new Error('swipe final persist failed'));
      });
    } else if (this.persistenceService !== null) {
      // 正常持久化
      Logger.info(LOG_TAG, 'persistence route kind=normal');
      return this.persistenceService.updateMessage(chatId, msg).then((): void => {
        Logger.info(LOG_TAG, 'final persist ok');
      }).catch((e: Object): Promise<void> => {
        const msg2: string = e instanceof Error ? e.message : String(e);
        if (retriesLeft > 0) {
          Logger.warn(LOG_TAG, 'final persist retry: ' + msg2);
          return this.persistWithRetry(msg, retriesLeft - 1);
        }
        Logger.warn(LOG_TAG, 'final persist failed: ' + msg2);
        return Promise.resolve();
      });
    }
    return Promise.resolve();
  }

  /**
   * 更新 Chat 活跃时间(异步,不等待)。
   * 同时更新 lastMessageAt 和 updatedAt。
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
   * 仅更新 Chat 的 updatedAt(不修改 lastMessageAt)。
   * 用于 Swipe 切换候选等不改变对话内容的操作。
   */
  private persistChatTimestamp(): void {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    this.persistenceService.updateChatTimestamp(this.currentChatId, Date.now()).catch(
      (e: Object): void => {
        Logger.warn(LOG_TAG, 'chat timestamp persist failed: '
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

  /**
   * 更新 lastAssistantMessageId 为最后一条 Assistant 消息 ID。
   *
   * V2 行为:
   * - 优先查找 Conversation 类型(或 undefined)的 Assistant 消息
   * - 若无,则查找 CharacterFirstMessage 类型的 Assistant 消息
   *   (允许 firstMessage 成为 Swipe 目标,用于切换 alternate_greetings)
   */
  private updateLastAssistantMessageId(): void {
    this.lastAssistantMessageId = '';
    // 第一遍:优先查找 Conversation 类型
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const msg: ChatMessage = this.messages[i];
      if (msg.role === ChatRole.Assistant &&
        (msg.source === undefined || msg.source === ChatMessageSource.Conversation)) {
        this.lastAssistantMessageId = msg.id;
        return;
      }
    }
    // 第二遍:无 Conversation 类型时,查找 CharacterFirstMessage 类型
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const msg: ChatMessage = this.messages[i];
      if (msg.role === ChatRole.Assistant &&
        msg.source === ChatMessageSource.CharacterFirstMessage) {
        this.lastAssistantMessageId = msg.id;
        return;
      }
    }
  }

  // ===== Swipe 公开方法 =====

  /**
   * 获取当前会话的 Swipe 摘要列表(副本)。
   */
  getSwipeSummaries(): MessageSwipeSummary[] {
    return this.swipeSummaries.slice();
  }

  /**
   * 获取指定 Assistant 消息的 Swipe 摘要。
   */
  getSwipeSummary(assistantMessageId: string): MessageSwipeSummary | undefined {
    return this.getSummaryForMessage(assistantMessageId);
  }

  /**
   * 判断指定 Assistant 消息是否可操作 Swipe。
   * 只允许非生成状态下操作最后一条 Assistant 消息。
   */
  canOperateSwipe(assistantMessageId: string): boolean {
    if (this.isGenerating()) {
      return false;
    }
    if (assistantMessageId !== this.lastAssistantMessageId) {
      return false;
    }
    return true;
  }

  /**
   * 激活前一个候选。
   * T-6.3: 与生成 / session op / 其他 swipe 操作互斥(swipeOperationInProgress)。
   * 仅更新 updatedAt(不修改 lastMessageAt),避免会话反复置顶。
   */
  async activatePreviousCandidate(assistantMessageId: string): Promise<void> {
    if (!this.canOperateSwipe(assistantMessageId)) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'activatePreviousCandidate rejected: busy');
      return;
    }
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    if (summary === undefined) {
      return;
    }
    const newIndex: number = summary.activeCandidateIndex - 1;
    if (newIndex < 0) {
      return;
    }
    this.swipeOperationInProgress = true;
    try {
      await this.swipePersistenceService.activateCandidate(assistantMessageId, newIndex);
      // 重新加载 messages
      await this.reloadCurrentSession();
      // 重新加载 summaries
      this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
      this.updateLastAssistantMessageId();
      // 仅更新 updatedAt,不修改 lastMessageAt
      this.persistChatTimestamp();
      this.emitMessages(this.lastCallbacks);
      Logger.info(LOG_TAG, 'SwipeRuntime | stage=candidate_activated');
    } finally {
      this.swipeOperationInProgress = false;
    }
  }

  /**
   * 激活下一个候选。
   * T-6.3: 与生成 / session op / 其他 swipe 操作互斥(swipeOperationInProgress)。
   * 仅更新 updatedAt(不修改 lastMessageAt),避免会话反复置顶。
   */
  async activateNextCandidate(assistantMessageId: string): Promise<void> {
    if (!this.canOperateSwipe(assistantMessageId)) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'activateNextCandidate rejected: busy');
      return;
    }
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    if (summary === undefined) {
      return;
    }
    const newIndex: number = summary.activeCandidateIndex + 1;
    if (newIndex >= summary.candidateCount) {
      return;
    }
    this.swipeOperationInProgress = true;
    try {
      await this.swipePersistenceService.activateCandidate(assistantMessageId, newIndex);
      // 重新加载 messages
      await this.reloadCurrentSession();
      // 重新加载 summaries
      this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
      this.updateLastAssistantMessageId();
      // 仅更新 updatedAt,不修改 lastMessageAt
      this.persistChatTimestamp();
      this.emitMessages(this.lastCallbacks);
      Logger.info(LOG_TAG, 'SwipeRuntime | stage=candidate_activated');
    } finally {
      this.swipeOperationInProgress = false;
    }
  }

  /**
   * 为最后一条 Assistant 消息生成新的候选回复。
   * 内部创建 Streaming 候选,启动流式请求。
   *
   * T-6.3:
   * - 创建 SwipeCandidate ActiveGenerationContext(包含 candidateIndex)
   * - 与 normal send / swipe browse / session op 互斥(swipeOperationInProgress)
   * - 启动失败时通过 doStream 的 handleStartFailure 统一处理
   * - 持久化走 MessageSwipePersistenceService(由 flushPersistence/persistWithRetry 路由)
   */
  async generateAlternativeCandidate(): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    Logger.info(LOG_TAG, 'Regenerate | service_enter');
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | busy');
      return;
    }
    if (this.lastAssistantMessageId.length === 0) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | missing_assistant_message');
      return;
    }
    if (this.swipePersistenceService === null) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | missing_swipe_state');
      return;
    }
    if (this.lastCallbacks === null) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | missing_callbacks');
      return;
    }
    Logger.info(LOG_TAG, 'Regenerate | eligibility_allowed');

    Logger.info(LOG_TAG, 'Regenerate | operation_context_created');
    this.generationOperationId++;
    // 占用 swipe 操作互斥锁(保护 appendCandidate + reloadCurrentSession 期间不被并发)
    this.swipeOperationInProgress = true;

    const assistantMessageId: string = this.lastAssistantMessageId;
    const operationId: number = this.generationOperationId;
    const chatId: string = this.currentChatId !== undefined ? this.currentChatId : '';

    // 检查候选数量上限
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    let nextIndex: number = 0;
    if (summary !== undefined) {
      nextIndex = summary.candidateCount;
      if (nextIndex >= MAX_SWIPE_CANDIDATES) {
        Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | candidate_limit');
        this.swipeOperationInProgress = false;
        this.lastCallbacks.onError('该回复已达到候选数量上限');
        return;
      }
    }

    // 创建新候选(Streaming)并激活
    // T-6.4A-R6: 必须使用 appendCandidate 实际返回的 newIndex,
    // 不能使用 nextIndex(当 summary===undefined 时 nextIndex=0,
    // 但 ensureSwipeState 会先创建 Candidate 0,appendCandidate 实际创建 Candidate 1)
    let actualNewIndex: number = nextIndex;
    try {
      await this.swipePersistenceService.appendCandidate(
        assistantMessageId,
        {
          content: '',
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        },
        true // activate
      );
      // T-6.4A-R6: appendCandidate 返回的 candidates 可能是事务内旧快照,
      // 不包含刚插入的 Candidate。事务已提交,重新查询获取最新数据。
      const freshState: MessageSwipeState | null =
        await this.swipePersistenceService.getSwipeState(assistantMessageId);
      if (freshState !== null) {
        let maxIdx: number = 0;
        for (let i = 0; i < freshState.candidates.length; i++) {
          if (freshState.candidates[i].candidateIndex > maxIdx) {
            maxIdx = freshState.candidates[i].candidateIndex;
          }
        }
        actualNewIndex = maxIdx;
      }
      Logger.info(LOG_TAG, 'Regenerate | candidate_created');
      Logger.info(LOG_TAG, 'SwipeRuntime | stage=candidate_created');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'Regenerate | failed | appendCandidate: ' + msg);
      this.swipeOperationInProgress = false;
      this.lastCallbacks.onError('创建候选回复失败: ' + msg);
      return;
    }

    // 更新 swipeSummaries(使用 actualNewIndex)
    if (summary !== undefined) {
      this.swipeSummaries = this.swipeSummaries.map(
        (s: MessageSwipeSummary): MessageSwipeSummary => {
          if (s.assistantMessageId === assistantMessageId) {
            return {
              assistantMessageId: s.assistantMessageId,
              activeCandidateIndex: actualNewIndex,
              candidateCount: actualNewIndex + 1,
              isGeneratingCandidate: true
            };
          }
          return s;
        }
      );
    } else {
      this.swipeSummaries.push({
        assistantMessageId: assistantMessageId,
        activeCandidateIndex: actualNewIndex,
        candidateCount: actualNewIndex + 1,
        isGeneratingCandidate: true
      });
    }

    // 建立 SwipeCandidate 活动上下文(替代旧 ActiveSwipeGeneration)
    this.activeGeneration = {
      operationId: operationId,
      kind: ChatGenerationKind.SwipeCandidate,
      chatId: chatId,
      assistantMessageId: assistantMessageId,
      swipeCandidateIndex: actualNewIndex
    };

    // 候选创建 + summary 更新完成,释放 swipe 操作锁;
    // 后续生成期间通过 activeGeneration 与 isBusy()(state=Sending/Streaming)互斥
    this.swipeOperationInProgress = false;

    // T-6.4A: 不再调用 reloadCurrentSession()。
    // 原因:reloadCurrentSession → loadSessionInternal → normalizeInterruptedMessages
    // 会把刚物化的 Streaming 候选改为 Cancelled,导致 DB 与内存状态不一致,
    // 重新进入页面时目标 Assistant 显示为空内容(旧历史"消失"Bug 根因)。
    // 正确做法:直接在完整内存历史中替换目标 Assistant 为 Streaming + 空 content,
    // 保留所有其他消息不变。
    this.replaceAssistantMessageInFullHistory(assistantMessageId);

    // 更新状态
    this.currentAssistantId = assistantMessageId;
    this.setState(ChatState.Sending, this.lastCallbacks);
    this.emitMessages(this.lastCallbacks);

    // 启动流式请求(携带 SwipeCandidate 上下文)
    this.lastPersistedContentLength = 0;
    this.pendingPersistAssistantId = assistantMessageId;
    Logger.info(LOG_TAG, 'Regenerate | provider_started');
    this.doStream(assistantMessageId, this.lastCallbacks, this.activeGeneration);
  }

  // ===== Swipe 内部辅助方法 =====

  /**
   * 获取指定消息的 Swipe 摘要。
   */
  private getSummaryForMessage(messageId: string): MessageSwipeSummary | undefined {
    for (let i = 0; i < this.swipeSummaries.length; i++) {
      if (this.swipeSummaries[i].assistantMessageId === messageId) {
        return this.swipeSummaries[i];
      }
    }
    return undefined;
  }

  /**
   * 更新 Swipe 摘要中的 isGeneratingCandidate 标志。
   * T-6.3: 基于当前 activeGeneration(必须为 SwipeCandidate)定位目标 Assistant。
   */
  private updateSwipeSummaryGeneratingFlag(isGenerating: boolean): void {
    const ctx: ActiveGenerationContext | null = this.activeGeneration;
    if (ctx === null || ctx.kind !== ChatGenerationKind.SwipeCandidate) {
      return;
    }
    const targetId: string = ctx.assistantMessageId;
    this.swipeSummaries = this.swipeSummaries.map(
      (s: MessageSwipeSummary): MessageSwipeSummary => {
        if (s.assistantMessageId === targetId) {
          return {
            assistantMessageId: s.assistantMessageId,
            activeCandidateIndex: s.activeCandidateIndex,
            candidateCount: s.candidateCount,
            isGeneratingCandidate: isGenerating
          };
        }
        return s;
      }
    );
  }

  /**
   * 从数据库重新加载当前会话的全部消息。
   */
  private async reloadCurrentSession(): Promise<void> {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const session: PersistedChatSession | null =
      await this.persistenceService.loadSession(this.currentChatId);
    if (session !== null) {
      this.messages = session.messages.slice();
      this.currentSequenceNumber = session.maxSequenceNumber;
    }
  }

  /**
   * T-6.4A: 在完整页面历史中按 Message ID 查找目标 Assistant,
   * 只替换该消息为 Streaming + 空 content(用于重新生成候选),
   * 保留所有其他消息的 ID、内容、顺序、sequenceNumber 不变。
   *
   * 要求:
   * 1. 在完整页面历史中按 Message ID 查找;
   * 2. 只替换一项;
   * 3. 保留其他所有项;
   * 4. 返回新数组引用;
   * 5. 找不到时抛安全错误;
   * 6. 不使用请求裁剪后的数组更新 UI。
   */
  private replaceAssistantMessageInFullHistory(assistantMessageId: string): void {
    let found: boolean = false;
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === assistantMessageId) {
        found = true;
        return {
          id: msg.id,
          role: msg.role,
          content: '',
          createdAt: msg.createdAt,
          updatedAt: Date.now(),
          isStreaming: true,
          errorMessage: undefined,
          status: ChatMessageStatus.Streaming,
          source: msg.source
        };
      }
      return msg;
    });
    if (!found) {
      throw new Error('replaceAssistantMessageInFullHistory: target assistant not found');
    }
  }

  // ===== T-6.4B-1 Branch 公开方法 =====

  /**
   * 获取 Branch 列表(副本)。
   */
  getBranches(): ConversationBranchSummary[] {
    return this.branches.slice();
  }

  /**
   * 获取当前活动 Branch ID。
   */
  getActiveBranchId(): string {
    return this.activeBranchId;
  }

  /**
   * 获取 Branch 记录数量统计。
   */
  getRecordCounts(): ConversationRecordCounts | undefined {
    return this.recordCounts;
  }

  /**
   * 是否正在执行 Branch 操作(创建 Child / 切换)。
   */
  isBranchOperating(): boolean {
    return this.branchOperationInProgress;
  }

  /**
   * 判断指定 Assistant 消息是否可"从此处继续"创建 Child Branch。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = Assistant
   * - source = Conversation 或 undefined(兼容)
   * - 不是 CharacterFirstMessage
   * - status = Completed
   * - 不是当前正在生成的消息
   * - 位于当前 messages 列表中
   */
  canContinueFromAssistant(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    if (this.currentAssistantId !== null && this.currentAssistantId === messageId) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.Assistant) {
      return false;
    }
    if (msg.source === ChatMessageSource.CharacterFirstMessage) {
      return false;
    }
    if (msg.source !== undefined && msg.source !== ChatMessageSource.Conversation) {
      return false;
    }
    if (msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    return true;
  }

  /**
   * 刷新 Branch 状态(branches / activeBranchId / recordCounts)。
   * 在 initializeSession 完成后以及 Branch 操作后调用。
   * 失败不抛异常,仅记录 warning。
   */
  async refreshBranchState(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.branchPersistenceService === null) {
      return;
    }
    if (this.currentChatId === undefined) {
      return;
    }
    try {
      const chatId: string = this.currentChatId;
      const branches: ConversationBranchSummary[] =
        await this.branchPersistenceService.listBranches(chatId);
      const activeBranch: ConversationBranch | null =
        await this.branchPersistenceService.getActiveBranch(chatId);
      const counts: ConversationRecordCounts =
        await this.branchPersistenceService.getRecordCounts(chatId);
      this.branches = branches;
      this.activeBranchId = activeBranch !== null ? activeBranch.id : '';
      this.recordCounts = counts;
      Logger.info(LOG_TAG, 'ConversationBranch | counts loaded'
        + ' branches=' + branches.length.toString()
        + ' msgs=' + counts.totalUniqueMessageCount.toString());
    } catch (e) {
      Logger.warn(LOG_TAG, 'refreshBranchState failed: '
        + (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * 从历史 Assistant 创建 Child Branch(从此处继续)。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化
   * 2. 校验消息可继续(canContinueFromAssistant)
   * 3. 获取当前 Active Branch
   * 4. 获取该 Assistant 在当前 Branch 中选中的 Candidate index(若有)
   * 5. 调用 forkAtMessage 创建 Child Branch(自动成为 Active)
   * 6. 重新加载 messages / swipeSummaries / branches / recordCounts
   * 7. 创建新的 messages 数组引用
   * 8. 通知 UI
   *
   * 不会:
   * - 删除原 Branch 后续消息
   * - 复制 Message / Candidate 实体
   * - 原地修改 messages 数组
   * - 自动开始 Provider 请求
   * - 自动插入空 User 消息
   *
   * @param messageId 目标历史 Assistant 消息 ID
   * @param callbacks 回调集合
   */
  async continueFromAssistant(
    messageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'continueFromAssistant rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canContinueFromAssistant(messageId)) {
      Logger.warn(LOG_TAG, 'continueFromAssistant rejected: invalid message');
      callbacks.onError('该消息无法继续');
      return;
    }

    this.branchOperationInProgress = true;
    this.lastCallbacks = callbacks;
    try {
      const chatId: string = this.currentChatId;
      // 1. 获取当前 Active Branch
      const activeBranch: ConversationBranch | null =
        await this.branchPersistenceService.getActiveBranch(chatId);
      if (activeBranch === null) {
        throw new Error('当前会话无活动分支');
      }
      // 2. 获取该 Assistant 在当前 Branch 中选中的 Candidate index
      //    (用于 forkAtMessage 覆盖新 Branch 的选择,保留来源 Branch 当前显示的 Candidate)
      const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(messageId);
      const selectedCandidateIndex: number | undefined =
        summary !== undefined ? summary.activeCandidateIndex : undefined;
      // 3. 调用 forkAtMessage 创建 Child Branch(自动成为 Active)
      await this.branchPersistenceService.forkAtMessage(
        chatId,
        activeBranch.id,
        messageId,
        selectedCandidateIndex
      );
      Logger.info(LOG_TAG, 'ConversationBranch | child created');
      // 4. 重新加载 messages / swipeSummaries / branchState
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
      // 5. 通知 UI(新数组引用)
      this.setState(ChatState.Idle, callbacks);
      this.emitMessages(callbacks);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'continueFromAssistant failed: ' + msg);
      callbacks.onError('创建分支失败,请重试');
    } finally {
      this.branchOperationInProgress = false;
    }
  }

  /**
   * T-6.4B-2: 判断指定 User 消息是否可"从此处生成新回复"创建 Branch。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = User
   * - status = Completed(或 undefined,兼容旧数据)
   * - 不是当前正在生成的消息(currentAssistantId 只可能是 Assistant,User 永远不匹配)
   * - 位于当前 messages 列表中(即位于当前 Active Branch)
   * - 该 User 消息之后存在 Assistant 回复或后续消息(即不是最新一条尚未生成回复的 User)
   *   通过 indexOf(msg) < messages.length - 1 判断
   */
  canGenerateFromUserMessage(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.User) {
      return false;
    }
    if (msg.status !== undefined && msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    // 必须有后续消息(后面存在 Assistant 回复或后续历史)
    // 最新一条尚未生成 Assistant 的 User 消息不显示该操作
    const idx: number = this.messages.indexOf(msg);
    if (idx < 0 || idx >= this.messages.length - 1) {
      return false;
    }
    return true;
  }

  /**
   * T-6.4B-3: 判断指定历史 Assistant 消息是否可"重新生成此回复"。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = Assistant
   * - source = Conversation 或 undefined(兼容旧数据)
   * - status = Completed
   * - 不是 CharacterFirstMessage
   * - 不是当前正在生成的消息(currentAssistantId)
   * - 位于当前 messages 列表中(即位于当前 Active Branch)
   * - 前面存在对应的 User 消息(基于当前 Branch 有序路径向前查找)
   */
  canRegenerateAssistantMessage(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    if (this.currentAssistantId !== null && this.currentAssistantId === messageId) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.Assistant) {
      return false;
    }
    if (msg.source === ChatMessageSource.CharacterFirstMessage) {
      return false;
    }
    if (msg.source !== undefined && msg.source !== ChatMessageSource.Conversation) {
      return false;
    }
    if (msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    // 基于当前 Active Branch 有序路径向前查找最近的 User
    const idx: number = this.messages.indexOf(msg);
    if (idx <= 0) {
      return false;
    }
    let hasPrevUser: boolean = false;
    for (let i = idx - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        hasPrevUser = true;
        break;
      }
    }
    return hasPrevUser;
  }

  /**
   * T-6.4B-3: 历史 Assistant "重新生成此回复"。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化、消息可重新生成
   * 2. 在当前 Active Branch 有序路径中定位目标 Assistant
   * 3. 向前查找最近的 User 消息作为 fork point
   * 4. 判断同级或子级 parentBranchId(复用 T-6.4B-1.2 规则)
   * 5. 调用 forkAndStreamFromUser 创建 Branch + Streaming Assistant + 启动 Provider
   *
   * 与"从此处继续"的区别:
   * - fork point 是目标 Assistant 前面的 User(不是 Assistant 本身)
   * - 新 Branch 不保留目标 Assistant 和后续历史
   * - 自动调用 Provider 生成新 Assistant
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  async regenerateAssistantMessage(
    messageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'regenerateAssistantMessage rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canRegenerateAssistantMessage(messageId)) {
      Logger.warn(LOG_TAG, 'regenerateAssistantMessage rejected: invalid message');
      callbacks.onError('该消息无法重新生成');
      return;
    }

    const chatId: string = this.currentChatId;
    this.lastCallbacks = callbacks;

    // 1. 在当前 Active Branch 有序路径中定位目标 Assistant
    let assistantIndex: number = -1;
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        assistantIndex = i;
        break;
      }
    }
    if (assistantIndex < 0) {
      callbacks.onError('找不到目标回复');
      return;
    }

    // 2. 向前查找最近的 User 消息作为 fork point
    let forkUserMessageId: string = '';
    for (let i = assistantIndex - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        forkUserMessageId = this.messages[i].id;
        break;
      }
    }
    if (forkUserMessageId.length === 0) {
      callbacks.onError('找不到原始用户消息');
      return;
    }

    // 3. 获取当前 Active Branch(完整 ConversationBranch,含 forkMessageId / parentBranchId)
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 4. 判断同级或子级(复用 T-6.4B-1.2 规则)
    //    同级条件:当前 Active Branch 非 Root 且 forkMessageId 等于本次 forkUserMessageId
    let parentBranchId: string;
    if (!activeBranch.isRoot
      && activeBranch.forkMessageId !== undefined
      && activeBranch.forkMessageId === forkUserMessageId) {
      parentBranchId = activeBranch.parentBranchId !== undefined
        ? activeBranch.parentBranchId : activeBranch.id;
    } else {
      parentBranchId = activeBranch.id;
    }

    Logger.info(LOG_TAG, 'regenerateAssistantMessage | start');
    await this.forkAndStreamFromUser(
      chatId, activeBranch.id, parentBranchId, forkUserMessageId, callbacks
    );
  }

  /**
   * T-6.4B-2: 从历史 User 消息生成新回复(创建新 Branch 并自动启动 Provider)。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化、消息可生成
   * 2. 获取当前 Active Branch
   * 3. 判断同级或子级 parentBranchId(复用 T-6.4B-1.2 规则)
   * 4. 调用 forkAndStreamFromUser 创建 Branch + Streaming Assistant + 启动 Provider
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  async generateFromUserMessage(
    userMessageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'generateFromUserMessage rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canGenerateFromUserMessage(userMessageId)) {
      Logger.warn(LOG_TAG, 'generateFromUserMessage rejected: invalid message');
      callbacks.onError('该消息无法生成新回复');
      return;
    }

    const chatId: string = this.currentChatId;
    this.lastCallbacks = callbacks;

    // 1. 获取当前 Active Branch(完整 ConversationBranch,含 forkMessageId / parentBranchId)
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 2. 判断同级或子级(复用 T-6.4B-1.2 规则)
    //    同级条件:当前 Active Branch 非 Root 且 forkMessageId 等于本次 userMessageId
    let parentBranchId: string;
    if (!activeBranch.isRoot
      && activeBranch.forkMessageId !== undefined
      && activeBranch.forkMessageId === userMessageId) {
      parentBranchId = activeBranch.parentBranchId !== undefined
        ? activeBranch.parentBranchId : activeBranch.id;
    } else {
      parentBranchId = activeBranch.id;
    }

    Logger.info(LOG_TAG, 'generateFromUserMessage | start');
    await this.forkAndStreamFromUser(
      chatId, activeBranch.id, parentBranchId, userMessageId, callbacks
    );
  }

  /**
   * T-6.4B-3.1: 判断指定历史 User 消息是否可"编辑"。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = User
   * - status = Completed 或 undefined(兼容旧数据)
   * - content 非空
   * - 位于当前 messages 列表中(即位于当前 Active Branch)
   * - 后面存在消息(目标 User 不是最新一条)
   * - 前面存在消息(目标 User 不是第一条,有 anchor)
   */
  canEditUserMessage(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.User) {
      return false;
    }
    if (msg.status !== undefined && msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    if (msg.content.length === 0) {
      return false;
    }
    const idx: number = this.messages.indexOf(msg);
    if (idx <= 0) {
      // idx <= 0:第一条消息无 anchor,或不在列表
      return false;
    }
    if (idx >= this.messages.length - 1) {
      // 最新一条 User(后面无消息),不可编辑
      return false;
    }
    return true;
  }

  /**
   * T-6.4B-3.1: 编辑历史 User Message 并创建新 Branch + Streaming Assistant。
   *
   * 流程:
   * 1. 校验:未忙碌、服务可用、会话已初始化、消息可编辑、编辑内容非空且不同
   * 2. 在当前 Active Branch 有序路径中定位目标 User 和 anchor(前一条消息)
   * 3. 判断同级或子级 parentBranchId(基于 activeBranch.forkMessageId == anchorMessageId)
   * 4. 创建新的 Completed User Message(编辑后内容)和 Streaming Assistant Message
   * 5. 调用 editUserAndForkWithAssistant 原子事务
   * 6. 重载 messages / swipeSummaries / branchState
   * 7. 建立 BranchRegeneration ActiveGenerationContext
   * 8. 调用 doStream 启动 Provider
   *
   * 与"从此处生成新回复"的区别:
   * - 编辑:fork point = anchor(原 User 前一条),创建新 User,不继承原 User
   * - 从此处生成新回复:fork point = 原 User,继承原 User,只替换后面的 Assistant
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  async editUserMessageAndGenerate(
    messageId: string,
    editedContent: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'editUserMessageAndGenerate rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canEditUserMessage(messageId)) {
      Logger.warn(LOG_TAG, 'editUserMessageAndGenerate rejected: invalid message');
      callbacks.onError('该消息无法编辑');
      return;
    }
    const trimmedContent: string = editedContent.trim();
    if (trimmedContent.length === 0) {
      callbacks.onError('编辑内容不能为空');
      return;
    }

    const chatId: string = this.currentChatId;
    this.lastCallbacks = callbacks;

    // 1. 在当前 Active Branch 有序路径中定位目标 User
    let userIndex: number = -1;
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        userIndex = i;
        break;
      }
    }
    if (userIndex <= 0) {
      callbacks.onError('找不到目标用户消息');
      return;
    }

    // 2. anchor = 目标 User 前一条消息(任何角色,通常是 Assistant 或 CharacterFirstMessage)
    const anchorMessageId: string = this.messages[userIndex - 1].id;

    // 3. 获取当前 Active Branch
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 4. 判断同级或子级
    //    同级条件:当前 Active Branch 非 Root 且 forkMessageId 等于本次 anchorMessageId
    //    (即当前 Branch 也是从同一个 anchor fork 出的编辑/再生分支)
    let parentBranchId: string;
    if (!activeBranch.isRoot
      && activeBranch.forkMessageId !== undefined
      && activeBranch.forkMessageId === anchorMessageId) {
      parentBranchId = activeBranch.parentBranchId !== undefined
        ? activeBranch.parentBranchId : activeBranch.id;
    } else {
      parentBranchId = activeBranch.id;
    }

    // 5. 创建新的 Completed User Message 和 Streaming Assistant Message
    this.generationOperationId++;
    const operationId: number = this.generationOperationId;
    const newUserMessage: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.User,
      content: trimmedContent,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation
    };
    const newAssistantMessage: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 6. 调用原子事务创建 Branch + 新 User + 新 Assistant
    this.branchOperationInProgress = true;
    let editResult: EditedBranchGenerationTarget;
    try {
      editResult = await this.branchPersistenceService!.editUserAndForkWithAssistant(
        chatId,
        activeBranch.id,
        parentBranchId,
        messageId,
        anchorMessageId,
        newUserMessage,
        newAssistantMessage
      );
      Logger.info(LOG_TAG, 'ConversationBranch | edit branch created');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'editUserMessageAndGenerate failed: ' + msg);
      this.branchOperationInProgress = false;
      callbacks.onError('创建分支失败,请重试');
      return;
    }

    // 7. 事务成功,重载内存状态(新 Branch 已成为 Active)
    try {
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'editUserMessageAndGenerate reload failed: ' + msg);
      // Branch 已创建,继续执行生成,UI 状态可能与 DB 不一致但可恢复
    }

    // 8. 建立 BranchRegeneration 活动上下文
    this.activeGeneration = {
      operationId: operationId,
      kind: ChatGenerationKind.BranchRegeneration,
      chatId: chatId,
      assistantMessageId: editResult.newAssistantMessageId,
      branchId: editResult.newBranchId,
      forkMessageId: anchorMessageId
    };

    // 9. 设置当前 Assistant ID 和持久化追踪
    this.currentAssistantId = editResult.newAssistantMessageId;
    this.lastPersistedContentLength = 0;
    this.pendingPersistAssistantId = editResult.newAssistantMessageId;

    // 10. 释放 Branch 操作锁
    this.branchOperationInProgress = false;

    // 11. 进入 Sending 状态,通知 UI
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 12. 启动 Provider
    Logger.info(LOG_TAG, 'Edit | provider_started (branch mode)');
    this.doStream(editResult.newAssistantMessageId, callbacks, this.activeGeneration);
  }

  /**
   * 切换 Active Branch 到 targetBranchId。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化
   * 2. 调用 switchActiveBranch(事务内物化 Candidate 到 messages 并同步 group active index)
   * 3. 重新加载 messages / swipeSummaries / branches / recordCounts
   * 4. 通知 UI
   *
   * @param targetBranchId 目标 Branch ID
   * @param callbacks 回调集合
   */
  async switchBranch(
    targetBranchId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'switchBranch rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (targetBranchId.length === 0) {
      callbacks.onError('目标分支无效');
      return;
    }
    if (targetBranchId === this.activeBranchId) {
      // 已是当前分支,无操作
      return;
    }

    this.branchOperationInProgress = true;
    this.lastCallbacks = callbacks;
    try {
      const chatId: string = this.currentChatId;
      await this.branchPersistenceService.switchActiveBranch(chatId, targetBranchId);
      Logger.info(LOG_TAG, 'ConversationBranch | branch switched');
      // 重新加载
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
      this.setState(ChatState.Idle, callbacks);
      this.emitMessages(callbacks);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'switchBranch failed: ' + msg);
      callbacks.onError('切换分支失败,请重试');
    } finally {
      this.branchOperationInProgress = false;
    }
  }

  /**
   * T-6.4B-1.1: 外部 Branch 切换后重新加载当前会话。
   *
   * 当 BranchMapPage 通过 branchPersistenceService.switchActiveBranch 切换 Active Branch 后,
   * ChatPage 的 ChatService 需要重新从数据库加载消息和 Branch 状态。
   * 此方法不执行 switchActiveBranch(已由外部完成),只做 reload + 通知 UI。
   *
   * 流程:
   * 1. 重新加载 messages(从 DB,含 Active Branch 的 Candidate 投影)
   * 2. 重新加载 swipeSummaries
   * 3. 更新 lastAssistantMessageId
   * 4. 刷新 Branch 状态(branches / activeBranchId / recordCounts)
   * 5. 通知 UI(新数组引用)
   *
   * @param callbacks 回调集合
   */
  async reloadAfterExternalBranchChange(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.currentChatId === undefined) {
      return;
    }
    try {
      await this.reloadCurrentSession();
      Logger.info(LOG_TAG, 'reloadAfterExternalBranchChange | messages='
        + this.messages.length.toString());
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
      this.setState(ChatState.Idle, callbacks);
      this.emitMessages(callbacks);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'reloadAfterExternalBranchChange failed: ' + msg);
      callbacks.onError('重新加载会话失败');
    }
  }
}