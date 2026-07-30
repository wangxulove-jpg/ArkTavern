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
import { PromptBuilder, PromptBuildContext, PromptBuildResult, MemoryLayersInjection } from './PromptBuilder';
import { TokenCounter } from './TokenCounter';
import { HistoryTrimmer } from './HistoryTrimmer';
import { RecentMessageSelector } from './RecentMessageSelector';
import { ChatPersistenceService } from './ChatPersistenceService';
import { ChatBackgroundService } from './ChatBackgroundService';
import { PromptPresetService } from './PromptPresetService';
import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { ConversationBranchPersistenceService, EditedBranchGenerationTarget } from './ConversationBranchPersistenceService';
import { MemoryService } from './MemoryService';
import { ContextBudgetService } from './ContextBudgetService';
import { AppPreferences } from '../storage/AppPreferences';
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
import { ChatMessage, ChatMessageStatus, createChatMessage, mergeChatMessage } from '../models/ChatMessage';
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
import {
  calculateSafetyMargin,
  DEFAULT_RECENT_WINDOW_TARGET,
  MIN_COMPLETE_TURNS
} from '../models/ContextBudgetConfig';
import { ContextHistorySelection } from '../models/ContextHistorySelection';
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
import {
  ArkWebAvatarAiToolRegistry,
} from '../avatarai/ArkWebAvatarAiToolRegistry';
import {
  ArkWebAvatarAiToolPermissionController,
} from '../avatarai/ArkWebAvatarAiToolPermissionController';
import {
  ArkWebAvatarAiToolExecutor,
  ArkWebAvatarAiToolExecutorRuntime,
  ArkWebAvatarToolExecutorBusinessState,
} from '../avatarai/ArkWebAvatarAiToolExecutor';
import {
  ArkWebChatToolDefinition,
  ArkWebChatToolCall,
  ArkWebChatToolExecutionResult,
  ArkWebAvatarAiToolContext,
  ArkWebAvatarAiCapabilitySnapshot,
  ArkWebAvatarAiToolName,
  ArkWebAvatarAiToolErrorCode,
  ArkWebAvatarAiToolPermissionModeConst,
  AVATAR_TOOL_MAX_ROUNDS,
  AVATAR_TOOL_MAX_CALLS_PER_TURN,
} from '../avatarai/ArkWebAvatarAiToolTypes';
import {
  ArkWebAvatarDialogueStrategyBuilder,
} from '../avatarai/ArkWebAvatarDialogueStrategyBuilder';
import {
  ArkWebAvatarDialogueStrategyInput,
  ArkWebAvatarDialogueStrategyResult,
  ArkWebAvatarDialogueStrategyStatus,
  AVATAR_DIALOGUE_STRATEGY_VERSION,
  AVATAR_STRATEGY_MAX_PERFORM_PER_TURN,
  ArkWebAvatarDialogueStrategyModeConst,
} from '../avatarai/ArkWebAvatarDialogueStrategyTypes';
import {
  ArkWebAvatarDialogueSessionState,
} from '../avatarai/ArkWebAvatarDialogueSessionState';
import {
  ArkWebAvatarDialogueRhythmPolicy,
  AVATAR_DIALOGUE_RHYTHM_POLICY_VERSION,
} from '../avatarai/ArkWebAvatarDialogueRhythmPolicy';
import {
  NativeToolCallingSupport,
  NativeToolCallingSupportConst,
  NativeToolCallingDecisionSource,
  NativeToolCallingDecisionSourceConst,
  NativeToolCallingErrorCode,
  NativeToolCallingErrorCodeConst,
  NativeToolCallingProbeResult,
  NativeToolCallingProbeTool,
  NATIVE_TOOL_PROBE_TOOL_NAME,
  NATIVE_TOOL_PROBE_TOOL_DESCRIPTION,
  NATIVE_TOOL_PROBE_TOOL_PARAMETERS_JSON,
  AvatarToolIntegrationState,
  AvatarToolIntegrationStateConst,
  ProviderInfoSnapshot,
  ValidateProbeToolCallResult,
  createInitialProbeResult,
  buildNativeToolCallingProbeTool,
  generateProbeToken,
  validateProbeToolCall
} from '../avatarai/NativeToolCallingCapability';

const LOG_TAG: string = 'ChatService';

/** 启动阶段超时(毫秒),收到首个 onStart/onDelta/onComplete/onError 后清除 */
const START_TIMEOUT_MS: number = 15000;

/** 默认用户名(本阶段固定值,后续可扩展为用户设置) */
const DEFAULT_USER_NAME: string = 'User';

/** 全局用户称呼 Preferences key(v9 引入,存储在 AppPreferences 中的字符串) */
export const GLOBAL_USER_NAME_KEY: string = 'global_user_name';

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
  /**
   * Phase 4A-2: 助手最终消息完成回调 (可选,最小透传)。
   *
   * 触发时机: onComplete 内,文本消息已 finalizeAssistant + persistFinalAssistant 完成
   *           (或同步段已更新),state 切换到 Completed 之前/之后均安全。
   *
   * 用途: ChatViewModel 实现此回调,把结果发布到应用级 Avatar 桥接器,
   *       供 VrmViewerPage 经 LifecycleController 消费演出。
   *
   * 不修改: 请求 URL / 请求体 / API Key / 流式解析协议 / 重试 / 重新生成。
   *         本回调只透传 assistantMessageId + performanceHintJson。
   *
   * @param assistantMessageId 真实助手消息 ID (作为 turnId 使用)
   * @param performanceHintJson 可选 Hint JSON (无则空字符串)
   */
  onAssistantMessageFinalized?: (
    assistantMessageId: string,
    performanceHintJson: string
  ) => void;
}

/**
 * Phase 4A-3: Avatar Tool Calling 状态 (供 UI 显示)。
 *
 * Phase 4A-3R 扩展:
 *   - integrationState: Tool Integration 接线状态 (CONNECTED/NOT_CONNECTED/FAILED/DISPOSED)
 *   - nativeToolCallingSupport: 原生 Tool Calling 四态支持状态
 *   - decisionSource: 判断来源
 *   - probeErrorCode: 探测失败错误码
 *   - probeErrorMessage: 探测失败错误信息
 *   - providerType / providerDisplayName / currentModelId: 当前 Provider 信息 (不含敏感字段)
 */
export interface AvatarToolCallingStatus {
  /** 当前 Provider 是否支持原生 Tool Calling (Phase 4A-3R: 仅作 PROVIDER_DECLARATION 参考, 真实状态看 nativeToolCallingSupport) */
  providerSupported: boolean;
  /** 当前权限模式 (DENY / READ_ONLY / CONTROL_THIS_CHAT) */
  permissionMode: string;
  /** 注入的工具数量 */
  toolCount: number;
  /** 当前模型能力是否就绪 (Avatar 能力, 与 Provider 工具支持独立) */
  capabilityReady: boolean;
  /** 最后工具名称 */
  lastToolName: string;
  /** 最后工具结果 (简短) */
  lastToolResult: string;
  /** 最后错误 */
  lastToolError: string;
  /** Phase 4A-3R: Tool Integration 接线状态 */
  integrationState: string;
  /** Phase 4A-3R: 原生 Tool Calling 四态支持状态 (SUPPORTED/UNSUPPORTED/UNKNOWN/MISCONFIGURED) */
  nativeToolCallingSupport: string;
  /** Phase 4A-3R: 判断来源 (RUNTIME_PROBE/PROVIDER_DECLARATION/STATIC_REGISTRY/UNKNOWN) */
  decisionSource: string;
  /** Phase 4A-3R: 探测失败错误码 (空字符串表示未探测或成功) */
  probeErrorCode: string;
  /** Phase 4A-3R: 探测失败错误信息 */
  probeErrorMessage: string;
  /** Phase 4A-3R: Provider 类型 (openai/deepseek/openrouter/claude/gemini) */
  providerType: string;
  /** Phase 4A-3R: Provider 显示名称 (用户配置) */
  providerDisplayName: string;
  /** Phase 4A-3R: 当前模型 ID */
  currentModelId: string;
}

/**
 * Phase 4A-3R: 只读 Avatar 工具烟雾测试返回结果。
 */
export interface ReadOnlyAvatarToolSmokeTestResult {
  success: boolean;
  errorCode: string;
  errorMessage: string;
  finalTextSnippet: string;
  toolCallId: string;
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
  /**
   * RecentMessageSelector 最近原始消息窗口选择器(v8.3 Phase 2)。
   * - 在 PromptBuilder 之前筛选最近窗口,去重已被记忆覆盖的旧原文
   * - 无状态,可被多个 ChatService 共享
   * - 为 null 时回退到旧行为(把全部 sourceMessages 传给 PromptBuilder)
   */
  private readonly recentMessageSelector: RecentMessageSelector | null;
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
  /** 最后一次构建的请求消息(用于 UI 上下文占用估算,可能与实际发送的裁剪后消息不同) */
  private lastBuiltRequestMessages: ChatMessage[] | undefined = undefined;

  // ===== 持久化状态 =====
  /** 当前会话 id(未初始化时为 undefined) */
  private currentChatId: string | undefined = undefined;
  /** 当前会话 Chat 对象(用于读取 userNameOverride 等字段) */
  private currentChat: Chat | null = null;
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
  /** ChatBackgroundService(用于读取 per-chat 思考强度) */
  private readonly chatBackgroundService: ChatBackgroundService | null;
  /** MemoryService 长期记忆业务服务(v8,用于注入摘要和触发增量总结) */
  private readonly memoryService: MemoryService | null;
  /** ContextBudgetService per-chat 上下文预算服务(v8.1,覆盖 effectiveSettings) */
  private readonly contextBudgetService: ContextBudgetService | null;
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

  /** AppPreferences(用于读取全局用户称呼,v9 引入) */
  private readonly appPreferences: AppPreferences | null;

  // ===== Phase 4A-3: Avatar Tool Calling 集成 =====
  /** Avatar 工具注册表 (可选, 未注入时不启用 Tool Calling) */
  private avatarToolRegistry: ArkWebAvatarAiToolRegistry | null = null;
  /** Avatar 工具权限控制器 (可选) */
  private avatarPermissionController: ArkWebAvatarAiToolPermissionController | null = null;
  /** Avatar 工具执行器 (可选) */
  private avatarToolExecutor: ArkWebAvatarAiToolExecutor | null = null;
  /** Avatar 工具执行运行时回调 (可选, 由 ChatPage 注入) */
  private avatarExecutorRuntime: ArkWebAvatarAiToolExecutorRuntime | null = null;
  /** 能力快照提供器 (可选, 由 ChatPage 注入, 返回当前模型能力) */
  private avatarSnapshotProvider: (() => ArkWebAvatarAiCapabilitySnapshot | null) | null = null;
  /** 当前 Provider 是否支持原生 Tool Calling (每次请求开始时刷新) */
  private currentProviderSupportsToolCalling: boolean = false;

  // ===== Phase 4A-3R: Native Tool Calling 四态支持 =====
  /**
   * Phase 4A-3R: Tool Integration 接线状态。
   *
   * - NOT_CONNECTED: ChatPage 未调用 setAvatarToolIntegration (初始值)
   * - CONNECTED: 已调用 setAvatarToolIntegration, 所有依赖已注入
   * - FAILED: 接线抛出异常
   * - DISPOSED: 页面已 aboutToDisappear, Integration 已 dispose
   */
  private avatarToolIntegrationState: string = 'NOT_CONNECTED';
  /**
   * Phase 4A-3R: 原生 Tool Calling 四态支持状态。
   *
   * - UNKNOWN: 默认初始值, 尚未实际验证
   * - SUPPORTED: 真实探测成功
   * - UNSUPPORTED: Provider 或模型明确拒绝 tools
   * - MISCONFIGURED: 本地 Integration / Adapter / Parser 缺失
   */
  private nativeToolCallingSupport: string = 'UNKNOWN';
  /** Phase 4A-3R: 判断来源 (RUNTIME_PROBE / PROVIDER_DECLARATION / STATIC_REGISTRY / UNKNOWN) */
  private nativeToolCallingDecisionSource: string = 'UNKNOWN';
  /** Phase 4A-3R: 探测失败错误码 (空字符串表示未探测或成功) */
  private nativeToolCallingProbeErrorCode: string = '';
  /** Phase 4A-3R: 探测失败错误信息 */
  private nativeToolCallingProbeErrorMessage: string = '';
  /** Phase 4A-3R: 最近一次探测结果 (null 表示尚未探测) */
  private lastProbeResult: NativeToolCallingProbeResult | null = null;

  // ===== Phase 4C-1: Avatar 对话演出策略集成 =====
  /**
   * Phase 4C-1: Avatar 对话演出策略 Builder (可选, 由 ChatPage 注入)。
   *
   * - 当 Avatar Tool Calling 可用时, 在 buildRequestMessages 中构建策略系统指令
   * - 策略作为独立 system message 注入, 不修改角色卡 / 世界书 / 预设
   * - 策略只参与当前请求, 不持久化
   */
  private avatarDialogueStrategyBuilder: ArkWebAvatarDialogueStrategyBuilder | null = null;
  /**
   * Phase 4C-2: Avatar 对话演出会话状态 (可选, 由 ChatPage 注入)。
   *
   * - 只在当前 ChatPage 生命周期内保存, 不写入数据库 / Preferences / 角色卡 / 聊天消息
   * - 助手最终回复完成时递增 assistantTurnIndex (流式 token / tool result 中间轮次不递增)
   * - avatar_perform 真实执行完成后回写演出记录 (Bridge accepted 不等于成功)
   * - avatar_stop 真实执行完成后重置当前状态为 IDLE
   * - 策略 Builder 注入 buildStateSummary() 到 system message
   * - AI 面板显示 getRhythmStatusText() 简洁节奏状态
   */
  private avatarDialogueSessionState: ArkWebAvatarDialogueSessionState | null = null;
  /**
   * Phase 4C-2: Avatar 对话演出节奏策略 (可选, 由 ChatPage 注入)。
   *
   * - 实现 BALANCED_V1 软决策 (不强制阻止 AI 调用工具)
   * - 由 Tool Executor 在 executePerform 中评估 no-op 保护
   * - 不解析聊天正文判断是否需要演出
   */
  private avatarDialogueRhythmPolicy: ArkWebAvatarDialogueRhythmPolicy | null = null;
  /**
   * Phase 4C-1: 最近一次构建的策略结果 (供 UI 显示状态摘要)。
   *
   * 每次请求开始时刷新, 失败时为 null。
   */
  private lastAvatarStrategyResult: ArkWebAvatarDialogueStrategyResult | null = null;
  /**
   * Phase 4A-3: 当前 Turn 是否已执行原生 Avatar Tool Call。
   *
   * - true 时, 助手最终完成回调忽略 performanceHintJson
   * - 优先级: 原生 Tool Calling > performanceHintJson metadata > 无演出
   * - 在 sendMessage/regenerate 开始时重置为 false
   */
  private nativeAvatarToolExecutedForTurn: boolean = false;
  /**
   * Phase 4A-3: 当前 Turn 已执行的工具轮次。
   *
   * - 每次工具结果回传后递增
   * - 超过 AVATAR_TOOL_MAX_ROUNDS (3) 时停止执行工具, 允许 AI 返回文本错误说明
   */
  private avatarToolRoundCount: number = 0;
  /**
   * Phase 4A-3: 当前 Turn 已执行的工具调用总数 (跨轮次累计)。
   *
   * - 超过 AVATAR_TOOL_MAX_CALLS_PER_TURN (4) 时停止执行工具
   */
  private avatarToolCallCountForTurn: number = 0;
  /**
   * Phase 4A-3: 当前 Turn 缓存的工具调用和结果 (用于工具结果回传)。
   *
   * - 每次轮次完成后清空 priorToolCalls/toolResults 之前的缓存
   * - 在 Tool Calling 循环中传递给下一轮请求
   */
  private pendingToolResultsForNextRound: ArkWebChatToolExecutionResult[] = [];
  private pendingToolCallsForNextRound: ArkWebChatToolCall[] = [];

  constructor(
    modelService: ModelService,
    lorebookService: LorebookService | null = null,
    promptBuilder: PromptBuilder | null = null,
    tokenCounter: TokenCounter | null = null,
    historyTrimmer: HistoryTrimmer | null = null,
    persistenceService: ChatPersistenceService | null = null,
    promptPresetService: PromptPresetService | null = null,
    swipePersistenceService: MessageSwipePersistenceService | null = null,
    branchPersistenceService: ConversationBranchPersistenceService | null = null,
    chatBackgroundService: ChatBackgroundService | null = null,
    memoryService: MemoryService | null = null,
    contextBudgetService: ContextBudgetService | null = null,
    appPreferences: AppPreferences | null = null,
    recentMessageSelector: RecentMessageSelector | null = null
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
    this.chatBackgroundService = chatBackgroundService;
    this.memoryService = memoryService;
    this.contextBudgetService = contextBudgetService;
    this.appPreferences = appPreferences;
    this.recentMessageSelector = recentMessageSelector;
  }

  /**
   * Phase 4A-3: 注入 Avatar Tool Calling 集成组件。
   *
   * 由 ChatPage 在 aboutToAppear 时调用, 注入:
   * - Registry: 工具定义和参数校验
   * - PermissionController: 权限模式管理
   * - Executor: 工具执行
   * - Runtime: Avatar 业务状态读取和演出发布回调
   * - SnapshotProvider: 当前模型能力快照
   *
   * 任一为 null 时不启用 Avatar Tool Calling, 普通聊天保持原行为。
   *
   * @param registry 工具注册表
   * @param permissionController 权限控制器
   * @param executor 工具执行器
   * @param runtime 执行运行时回调
   * @param snapshotProvider 能力快照提供器
   * @param strategyBuilder 对话演出策略 Builder (Phase 4C-1, 可选)
   * @param sessionState 对话演出会话状态 (Phase 4C-2, 可选)
   * @param rhythmPolicy 对话演出节奏策略 (Phase 4C-2, 可选)
   */
  setAvatarToolIntegration(
    registry: ArkWebAvatarAiToolRegistry | null,
    permissionController: ArkWebAvatarAiToolPermissionController | null,
    executor: ArkWebAvatarAiToolExecutor | null,
    runtime: ArkWebAvatarAiToolExecutorRuntime | null,
    snapshotProvider: (() => ArkWebAvatarAiCapabilitySnapshot | null) | null,
    strategyBuilder: ArkWebAvatarDialogueStrategyBuilder | null = null,
    sessionState: ArkWebAvatarDialogueSessionState | null = null,
    rhythmPolicy: ArkWebAvatarDialogueRhythmPolicy | null = null
  ): void {
    this.avatarToolRegistry = registry;
    this.avatarPermissionController = permissionController;
    this.avatarToolExecutor = executor;
    this.avatarExecutorRuntime = runtime;
    this.avatarSnapshotProvider = snapshotProvider;
    this.avatarDialogueStrategyBuilder = strategyBuilder;
    this.avatarDialogueSessionState = sessionState;
    this.avatarDialogueRhythmPolicy = rhythmPolicy;
    // Phase 4A-3R: 更新 Integration 接线状态
    if (registry !== null
      && permissionController !== null
      && executor !== null
      && runtime !== null
      && snapshotProvider !== null) {
      this.avatarToolIntegrationState = AvatarToolIntegrationStateConst.CONNECTED;
      Logger.info(LOG_TAG, 'setAvatarToolIntegration: state=CONNECTED');
    } else {
      this.avatarToolIntegrationState = AvatarToolIntegrationStateConst.NOT_CONNECTED;
      Logger.info(LOG_TAG, 'setAvatarToolIntegration: state=NOT_CONNECTED (some deps null)');
    }
  }

  /**
   * Phase 4A-3R: 清空 Avatar Tool Integration (页面退出时调用)。
   *
   * - 权限恢复 DENY
   * - 清空所有依赖引用
   * - 接线状态变为 DISPOSED
   * - 不停止用户手动发起的演出 (由 StageController 负责)
   * - 不 dispose 应用级 Bridge / AssetLibrary
   */
  clearAvatarToolIntegration(): void {
    // 权限恢复 DENY
    if (this.avatarPermissionController !== null) {
      try {
        this.avatarPermissionController.setPermissionMode('DENY', (): void => {});
      } catch (e) {
        Logger.warn(LOG_TAG, 'clearAvatarToolIntegration: setPermissionMode DENY failed: ' + String(e));
      }
    }
    this.avatarToolRegistry = null;
    this.avatarPermissionController = null;
    this.avatarToolExecutor = null;
    this.avatarExecutorRuntime = null;
    this.avatarSnapshotProvider = null;
    this.avatarDialogueStrategyBuilder = null;
    this.avatarDialogueSessionState = null;
    this.avatarDialogueRhythmPolicy = null;
    this.avatarToolIntegrationState = AvatarToolIntegrationStateConst.DISPOSED;
    // 重置 Provider 支持状态为 UNKNOWN (下次进入页面重新探测)
    this.currentProviderSupportsToolCalling = false;
    this.nativeToolCallingSupport = NativeToolCallingSupportConst.UNKNOWN;
    this.nativeToolCallingDecisionSource = NativeToolCallingDecisionSourceConst.UNKNOWN;
    this.nativeToolCallingProbeErrorCode = '';
    this.nativeToolCallingProbeErrorMessage = '';
    this.lastProbeResult = null;
    Logger.info(LOG_TAG, 'clearAvatarToolIntegration: state=DISPOSED');
  }

  /**
   * Phase 4A-3R: 获取 Tool Integration 接线状态。
   */
  getAvatarToolIntegrationState(): string {
    return this.avatarToolIntegrationState;
  }

  /**
   * Phase 4A-3R: 获取原生 Tool Calling 四态支持状态。
   */
  getNativeToolCallingSupport(): string {
    return this.nativeToolCallingSupport;
  }

  /**
   * Phase 4A-3R: 获取最近一次探测结果 (null 表示尚未探测)。
   */
  getNativeToolCallingProbeResult(): NativeToolCallingProbeResult | null {
    return this.lastProbeResult;
  }

  /**
   * Phase 4A-3R: 获取当前 Provider 信息快照 (不含敏感字段)。
   */
  async getProviderInfoSnapshot(): Promise<ProviderInfoSnapshot> {
    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config === null) {
        const empty: ProviderInfoSnapshot = {
          providerType: '',
          providerDisplayName: '',
          currentModelId: ''
        };
        return empty;
      }
      const snapshot: ProviderInfoSnapshot = {
        providerType: config.type,
        providerDisplayName: config.name,
        currentModelId: config.modelName
      };
      return snapshot;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getProviderInfoSnapshot failed: ' + String(e));
      const fallback: ProviderInfoSnapshot = {
        providerType: '',
        providerDisplayName: '',
        currentModelId: ''
      };
      return fallback;
    }
  }

  /**
   * Phase 4A-3: 查询当前 Avatar Tool Calling 是否可用。
   *
   * - 所有依赖已注入
   * - 当前 Provider 支持原生 Tool Calling
   * - 权限不是 DENY
   *
   * Phase 4A-3R: 增加 Integration 接线状态和 Native Tool Calling 四态 Gate
   *   - 接线状态非 CONNECTED → 返回 false
   *   - nativeToolCallingSupport 非 SUPPORTED → 返回 false (UNKNOWN 也不允许注入)
   */
  isAvatarToolCallingAvailable(): boolean {
    // Phase 4A-3R: 接线状态检查
    if (this.avatarToolIntegrationState !== AvatarToolIntegrationStateConst.CONNECTED) {
      return false;
    }
    if (this.avatarToolRegistry === null
      || this.avatarPermissionController === null
      || this.avatarToolExecutor === null
      || this.avatarExecutorRuntime === null
      || this.avatarSnapshotProvider === null) {
      return false;
    }
    if (!this.currentProviderSupportsToolCalling) {
      return false;
    }
    // Phase 4A-3R: 必须真实探测成功才能注入工具
    if (this.nativeToolCallingSupport !== NativeToolCallingSupportConst.SUPPORTED) {
      return false;
    }
    return this.avatarPermissionController.canInjectTools();
  }

  /**
   * Phase 4A-3: 获取当前 Avatar Tool Calling 状态 (供 UI 显示)。
   *
   * Phase 4A-3R: 返回 integrationState / nativeToolCallingSupport / decisionSource / probe 错误信息 / Provider 信息。
   */
  getAvatarToolCallingStatus(): AvatarToolCallingStatus {
    const supported: boolean = this.currentProviderSupportsToolCalling;
    const permissionMode: string = this.avatarPermissionController !== null
      ? this.avatarPermissionController.getPermissionMode()
      : 'DENY';
    let toolCount: number = 0;
    if (this.avatarToolRegistry !== null && this.avatarSnapshotProvider !== null) {
      const snapshot: ArkWebAvatarAiCapabilitySnapshot | null = this.avatarSnapshotProvider();
      const tools: ArkWebChatToolDefinition[] = this.avatarToolRegistry.buildToolDefinitions(
        snapshot, permissionMode);
      toolCount = tools.length;
    }
    const snapshot: ArkWebAvatarAiCapabilitySnapshot | null =
      this.avatarSnapshotProvider !== null ? this.avatarSnapshotProvider() : null;
    const capabilityReady: boolean = snapshot !== null;
    // Phase 4A-3R: 同步获取 Provider 信息 (异步方法不能用 @State, 这里用空字符串占位,
    // ChatPage 单独通过 getProviderInfoSnapshot 异步刷新)
    return {
      providerSupported: supported,
      permissionMode: permissionMode,
      toolCount: toolCount,
      capabilityReady: capabilityReady,
      lastToolName: this.lastAvatarToolName,
      lastToolResult: this.lastAvatarToolResult,
      lastToolError: this.lastAvatarToolError,
      integrationState: this.avatarToolIntegrationState,
      nativeToolCallingSupport: this.nativeToolCallingSupport,
      decisionSource: this.nativeToolCallingDecisionSource,
      probeErrorCode: this.nativeToolCallingProbeErrorCode,
      probeErrorMessage: this.nativeToolCallingProbeErrorMessage,
      providerType: '',
      providerDisplayName: '',
      currentModelId: ''
    };
  }

  /**
   * Phase 4A-3: 设置 Avatar Tool Calling 权限模式 (UI 调用)。
   *
   * - 权限降级时, 通过 LifecycleController.cancelCurrent('AI_PERMISSION_REVOKED')
   *   停止当前 AI 发起的演出 (不影响用户手动发起的演出)
   * - 权限只在当前聊天页面生命周期内保存
   *
   * @param mode 目标权限模式 (DENY / READ_ONLY / CONTROL_THIS_CHAT)
   */
  setAvatarPermissionMode(mode: string): void {
    if (this.avatarPermissionController === null) {
      return;
    }
    const oldMode: string = this.avatarPermissionController.getPermissionMode();
    this.avatarPermissionController.setPermissionMode(mode, (): void => {
      // 权限降级回调: 停止当前 AI 发起的演出
      if (this.avatarExecutorRuntime !== null) {
        try {
          this.avatarExecutorRuntime.stopPerformanceForToolCall('AI_PERMISSION_REVOKED');
        } catch (e) {
          Logger.warn(LOG_TAG, 'stopPerformanceForToolCall on downgrade threw: ' + String(e));
        }
      }
    });
    Logger.info(LOG_TAG, `setAvatarPermissionMode: ${oldMode} → ${mode}`);
  }

  /** 最近一次工具名 (UI 显示) */
  private lastAvatarToolName: string = '';
  /** 最近一次工具结果 (UI 显示, 简短) */
  private lastAvatarToolResult: string = '';
  /** 最近一次工具错误 (UI 显示) */
  private lastAvatarToolError: string = '';

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
        this.currentChat = session.chat;
        this.messages = session.messages.slice();
        this.currentSequenceNumber = session.maxSequenceNumber;
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
      this.currentChat = session.chat;
      this.messages = [firstMsg];
      this.currentSequenceNumber = 1;

      // V2: 初始化 alternate_greetings 作为 Swipe 候选 1..N
      // firstMessage 已作为 Candidate 0 的内容,不需要额外 activate
      await this.initializeAlternateGreetingsAsSwipeCandidates(firstMsg.id);
    } else {
      const session: PersistedChatSession =
        await this.persistenceService.createSession(characterId, defaultTitle);
      this.currentChatId = session.chat.id;
      this.currentChat = session.chat;
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
   * 获取当前会话 Chat 对象(未初始化时为 null)。
   * 用于 UI 读取对话级 userNameOverride 字段。
   */
  getCurrentChat(): Chat | null {
    return this.currentChat;
  }

  /**
   * 解析当前生效的用户称呼。
   *
   * 优先级(v9 引入):
   * 1. 当前会话 userNameOverride 非空 -> 使用对话级覆盖
   * 2. 当前角色 userName 非空 -> 使用角色专属称呼
   * 3. AppPreferences 中 global_user_name 非空 -> 使用全局用户称呼
   * 4. 以上均空 -> 回退到 'User'
   *
   * AppPreferences 不可用或读取失败时静默回退到 DEFAULT_USER_NAME。
   *
   * @returns 当前生效的用户称呼
   */
  async resolveUserName(): Promise<string> {
    // 1. 对话级覆盖
    if (this.currentChat !== null && this.currentChat.userNameOverride.trim().length > 0) {
      return this.currentChat.userNameOverride.trim();
    }
    // 2. 角色专属称呼
    if (this.character !== null && this.character.userName.trim().length > 0) {
      return this.character.userName.trim();
    }
    // 3. 全局用户称呼
    if (this.appPreferences !== null) {
      try {
        const globalName: string = await this.appPreferences.getString(GLOBAL_USER_NAME_KEY, '');
        if (globalName.trim().length > 0) {
          return globalName.trim();
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'resolveUserName: read global failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }
    // 4. 默认 'User'
    return DEFAULT_USER_NAME;
  }

  /**
   * 更新当前会话的对话级用户称呼覆盖。
   * - 传入非空字符串:写入并 trim
   * - 传入 null 或空字符串:清空覆盖(回退到角色或全局)
   *
   * 持久化通过 ChatPersistenceService.updateUserNameOverride 完成。
   * 内存中的 currentChat 同步更新。
   *
   * @param override 新的覆盖值(null 或空字符串表示清空)
   * @returns 更新后的 Chat 对象(无当前会话时返回 null)
   * @throws Error 当无 persistenceService 或会话不存在时
   */
  async updateCurrentChatUserNameOverride(override: string | null): Promise<Chat | null> {
    if (this.persistenceService === null) {
      throw new Error('persistenceService unavailable');
    }
    if (this.currentChatId === undefined) {
      throw new Error('当前无活跃会话');
    }
    const normalized: string = override === null ? '' : override.trim();
    const updated: Chat = await this.persistenceService.updateUserNameOverride(
      this.currentChatId, normalized
    );
    this.currentChat = updated;
    return updated;
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

    // 3.5 修正 reload 丢失的 isStreaming 状态
    // reloadCurrentSession 从数据库加载 messages,数据库不保存 isStreaming=true,
    // 导致 placeholder 的 isStreaming 被重置为 false。
    // 在 emitMessages 之前修正 placeholder 为 Streaming 状态,确保 UI 正确显示打字机效果。
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === newAssistantId) {
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          isStreaming: true,
          status: ChatMessageStatus.Streaming
        });
      }
      return msg;
    });

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
      this.currentHandle.abort();
      this.currentHandle = null;
    }
    if (this.state === ChatState.Sending || this.state === ChatState.Streaming) {
      const ctx: ActiveGenerationContext | null = this.activeGeneration;
      // 不调用 flushPersistence() — persistFinalAssistant 已包含完整最终状态,
      // 避免与 persistFinalAssistant 嵌套事务冲突(T-6.4A-R3)
      // 将当前 Assistant 消息标记为已取消(创建新对象和新数组)
      this.markAssistant(this.currentAssistantId, ChatMessageStatus.Cancelled, undefined, undefined);
      this.emitMessages(this.lastCallbacks);
      // 持久化最终 Cancelled 状态,完成后才清理上下文
      this.persistFinalAssistant(this.currentAssistantId).then((): void => {
        // Swipe 候选处理:更新摘要生成标志
        if (ctx !== null && ctx.kind === ChatGenerationKind.SwipeCandidate) {
          this.updateSwipeSummaryGeneratingFlag(false);
        }
        // 更新 Chat 活跃时间(完成一次新生成)
        this.persistChatActivity();
        // 持久化后才清理活动上下文
        this.clearActiveGeneration(expectedOperationId);
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
    this.currentChat = session.chat;
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
   * 获取最近一次构建的请求消息(用于 UI 上下文占用估算)。
   * 反映实际发送给模型的消息(若发生历史裁剪,则为裁剪后的最终消息)。
   */
  getLastBuiltRequestMessages(): ChatMessage[] | undefined {
    return this.lastBuiltRequestMessages;
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
    this.lastBuiltRequestMessages = undefined;
    this.activeGeneration = null;
    this.swipeSummaries = [];
    this.state = ChatState.Idle;
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
      Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_start_failure');
      // 持久化最终 Failed 状态,完成后才清理上下文
      this.persistFinalAssistant(assistantId).then((): void => {
        Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_failed_persisted');
        Logger.warn(LOG_TAG, 'generation finalized status=failed');
        // Swipe:更新摘要生成标志
        if (context.kind === ChatGenerationKind.SwipeCandidate) {
          this.updateSwipeSummaryGeneratingFlag(false);
        }
        // 更新 Chat 活跃时间
        this.persistChatActivity();
        // 清理活动上下文(仅当仍是本次 operationId)
        this.clearActiveGeneration(operationId);
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
      },
      onDelta: (delta: ChatDelta): void => {
        this.clearStartTimer();
        Logger.info(LOG_TAG, `onDelta entry aid=${assistantId.slice(0,8)} delta.len=${delta.content.length} state=${String(this.state)} disposed=${String(this.disposed)}`);
        if (this.disposed) {
          return;
        }
        // 允许 Sending 与 Streaming 状态处理 delta:
        // streamCurrentChat 可能在同步/微任务阶段触发首帧 delta,
        // 此时 setState(Streaming) 尚未执行(state 仍为 Sending),
        // 严格守卫会丢弃所有 delta 导致回复内容为空。
        // 对齐 onComplete(行 1502)的守卫策略。
        if (this.state !== ChatState.Streaming && this.state !== ChatState.Sending) {
          Logger.warn(LOG_TAG, `onDelta DROPPED state=${String(this.state)}`);
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
        // Phase 4A-3: 检测 Provider 原生 Tool Calling
        // - 有 toolCalls 时进入工具调用循环 (handleAvatarToolCalls)
        // - 循环未继续 (continued=false) 或无 toolCalls 时走最终完成 (finalizeAssistantTurn)
        // - 不解析聊天正文 / Markdown / JSON 代码块
        if (result.toolCalls !== undefined && result.toolCalls.length > 0) {
          this.handleAvatarToolCalls(
            result, assistantId, callbacks, context, snapshot,
            requestMessages, excludeId, perChatEffort
          ).then((continued: boolean): void => {
            if (!continued) {
              this.finalizeAssistantTurn(
                assistantId, result, callbacks, context, operationId
              );
            }
          }).catch((e: Object): void => {
            Logger.warn(LOG_TAG, 'handleAvatarToolCalls threw: ' +
              (e instanceof Error ? e.message : String(e)));
            this.finalizeAssistantTurn(
              assistantId, result, callbacks, context, operationId
            );
          });
          return;
        }
        // 无工具调用: 走最终完成流程 (统一路径, 内部处理 performanceHintJson 冲突)
        this.finalizeAssistantTurn(
          assistantId, result, callbacks, context, operationId
        );
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
        Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_error');
        // 持久化最终 Failed 状态,完成后才清理上下文
        this.persistFinalAssistant(assistantId).then((): void => {
          Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_failed_persisted');
          Logger.warn(LOG_TAG, 'generation finalized status=failed');
          // Swipe:更新摘要生成标志
          if (context.kind === ChatGenerationKind.SwipeCandidate) {
            Logger.warn(LOG_TAG, 'Regenerate | failed');
            this.updateSwipeSummaryGeneratingFlag(false);
          }
          // 更新 Chat 活跃时间
          this.persistChatActivity();
          // 清理活动上下文
          this.clearActiveGeneration(operationId);
          this.setState(ChatState.Failed, callbacks);
          callbacks.onError(error.message);
          Logger.warn(LOG_TAG, 'stream failed: ' + error.message);
        }).catch((_e: Object): void => {
          this.clearActiveGeneration(operationId);
          this.setState(ChatState.Failed, callbacks);
          callbacks.onError(error.message);
        });
      }
    };

    // 启动超时保护(携带 context 用于迟到 timer 判断)
    this.startStartTimer(assistantId, callbacks, context);

    // Phase 4A-3R 修复: 每次生成开始时刷新 Provider Tool Calling 支持状态 + 重置 Turn 临时状态
    // 缺失此调用会导致 currentProviderSupportsToolCalling 永远为 false, 工具永不注入
    await this.refreshProviderToolCallingSupport();
    this.resetAvatarToolTurnState();

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
    // 保存最近构建的请求消息,供 UI 估算上下文占用
    this.lastBuiltRequestMessages = requestMessages;

    // 计算 Token 预算 → 超预算则裁剪 → 重算预算
    await this.updateRequestPlan(requestMessages, snapshot.generationSettings);

    // 固定段超预算时阻止 Provider 启动
    if (this.lastTokenBudget !== undefined && this.lastTokenBudget.exceedsBudget) {
      this.clearStartTimer();
      handleStartFailure('输入超出上下文窗口,请缩短对话或清除预设');
      return;
    }

    // 构建生效的请求选项(Preset 覆盖模型配置)
    // 读取 per-chat 思考强度(覆盖 Provider 默认)
    let perChatEffort: string = '';
    if (this.chatBackgroundService !== null && this.currentChatId !== undefined) {
      try {
        const stored: string = await this.chatBackgroundService.getReasoningEffort(this.currentChatId);
        perChatEffort = stored;
      } catch (e) {
        Logger.warn(LOG_TAG, 'getReasoningEffort failed: ' + String(e));
      }
    }

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
      stream: true,
      reasoningEffort: perChatEffort,
      tools: this.buildAvatarToolsForRequest(),
      toolResults: [],
      priorToolCalls: []
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
   * Phase 4A-3: 构建 Avatar 工具定义列表 (注入到请求)。
   *
   * - 当前 Provider 不支持 Tool Calling → 返回 undefined
   * - 权限为 DENY → 返回 undefined
   * - 能力快照为 null → 返回空数组 (Provider 仍可正常聊天, AI 不调用工具)
   * - 否则按权限返回工具定义
   */
  private buildAvatarToolsForRequest(): ArkWebChatToolDefinition[] | undefined {
    if (!this.isAvatarToolCallingAvailable()) {
      return undefined;
    }
    if (this.avatarToolRegistry === null || this.avatarSnapshotProvider === null) {
      return undefined;
    }
    const snapshot: ArkWebAvatarAiCapabilitySnapshot | null = this.avatarSnapshotProvider();
    const permissionMode: string = this.avatarPermissionController!.getPermissionMode();
    return this.avatarToolRegistry.buildToolDefinitions(snapshot, permissionMode);
  }

  /**
   * Phase 4A-3: 刷新当前 Provider 是否支持原生 Tool Calling。
   *
   * 在每次 sendMessage/regenerate 开始时调用。
   * 失败时默认为 false (普通聊天保持原行为)。
   */
  private async refreshProviderToolCallingSupport(): Promise<void> {
    try {
      this.currentProviderSupportsToolCalling =
        await this.modelService.supportsToolCallingForCurrentProvider();
    } catch (e) {
      this.currentProviderSupportsToolCalling = false;
    }
  }

  /**
   * Phase 4A-3: 重置当前 Turn 的 Avatar Tool Calling 临时状态。
   *
   * 在 sendMessage/regenerate 开始时调用。
   */
  private resetAvatarToolTurnState(): void {
    this.nativeAvatarToolExecutedForTurn = false;
    this.avatarToolRoundCount = 0;
    this.avatarToolCallCountForTurn = 0;
    this.pendingToolResultsForNextRound = [];
    this.pendingToolCallsForNextRound = [];
    this.lastAvatarToolName = '';
    this.lastAvatarToolResult = '';
    this.lastAvatarToolError = '';
    // Phase 4C-1: 清除上一 Turn 的策略结果 (重新生成时重新构建最新能力快照)
    this.lastAvatarStrategyResult = null;
  }

  /**
   * Phase 4A-3: 处理 Provider 返回的工具调用。
   *
   * 在 onComplete 中检测到 result.toolCalls 时调用。
   *
   * 流程:
   *   1. 校验是否可执行 (Provider 支持 + 权限允许 + 未超轮次限制)
   *   2. 顺序执行每个工具调用 (禁止并行)
   *   3. 收集工具执行结果
   *   4. 递增 avatarToolRoundCount
   *   5. 构建下一轮请求 (带 toolResults + priorToolCalls)
   *   6. 启动下一轮流式请求
   *
   * 超过限制时:
   *   - 不执行工具
   *   - 以 result.content 作为最终助手文本 (允许 AI 返回错误说明)
   *   - 触发 onAssistantMessageFinalized (跳过 performanceHintJson)
   *
   * @returns true 表示已发起下一轮请求 (调用方不应再触发最终完成);
   *          false 表示未发起下一轮 (调用方继续走最终完成流程)
   */
  private async handleAvatarToolCalls(
    result: ChatStreamResult,
    assistantId: string,
    callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext,
    snapshot: PromptPresetRequestSnapshot,
    requestMessages: ChatMessage[],
    excludeId: string | undefined,
    perChatEffort: string
  ): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (this.avatarToolExecutor === null || this.avatarPermissionController === null
      || this.avatarSnapshotProvider === null || this.avatarExecutorRuntime === null) {
      return false;
    }
    const toolCalls: ArkWebChatToolCall[] | undefined = result.toolCalls;
    if (toolCalls === undefined || toolCalls.length === 0) {
      return false;
    }

    // 校验轮次限制
    if (this.avatarToolRoundCount >= AVATAR_TOOL_MAX_ROUNDS) {
      Logger.warn(LOG_TAG,
        `AvatarTool round limit reached: ${this.avatarToolRoundCount}`);
      this.lastAvatarToolError = 'AVATAR_TOOL_ROUND_LIMIT';
      // 不执行工具, 继续走最终完成流程 (允许 AI 返回文本错误说明)
      return false;
    }

    // 校验工具调用次数限制 (本次 toolCalls 数量 + 已执行数量)
    if (this.avatarToolCallCountForTurn + toolCalls.length > AVATAR_TOOL_MAX_CALLS_PER_TURN) {
      Logger.warn(LOG_TAG,
        `AvatarTool call limit exceeded: ${this.avatarToolCallCountForTurn}+${toolCalls.length}`);
      this.lastAvatarToolError = 'AVATAR_TOOL_ROUND_LIMIT';
      return false;
    }

    // 顺序执行工具调用 (禁止并行执行多个 Avatar 演出)
    const snapshotCap: ArkWebAvatarAiCapabilitySnapshot | null = this.avatarSnapshotProvider();
    const toolContext: ArkWebAvatarAiToolContext = {
      chatTurnId: assistantId,
      snapshot: snapshotCap,
      permissionMode: this.avatarPermissionController.getPermissionMode()
    };

    const executionResults: ArkWebChatToolExecutionResult[] = [];
    for (let i = 0; i < toolCalls.length; i++) {
      if (this.disposed) {
        return false;
      }
      // 权限降级检查 (CONTROL_THIS_CHAT → DENY 时阻止后续工具调用)
      if (!this.avatarPermissionController.canControlAvatar()
        && (toolCalls[i].name === ArkWebAvatarAiToolName.AVATAR_PERFORM
          || toolCalls[i].name === ArkWebAvatarAiToolName.AVATAR_STOP)) {
        const deniedResult: ArkWebChatToolExecutionResult = {
          toolCallId: toolCalls[i].toolCallId,
          name: toolCalls[i].name,
          success: false,
          resultJson: JSON.stringify({
            success: false,
            errorCode: ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_PERMISSION_DENIED,
            message: 'Permission downgraded, tool call denied.'
          }),
          errorCode: ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_PERMISSION_DENIED,
          errorMessage: 'Permission downgraded'
        };
        executionResults.push(deniedResult);
        this.lastAvatarToolName = toolCalls[i].name;
        this.lastAvatarToolError = 'PERMISSION_DENIED';
        continue;
      }

      const execResult: ArkWebChatToolExecutionResult =
        await this.avatarToolExecutor.execute(toolContext, toolCalls[i]);
      executionResults.push(execResult);
      this.avatarToolCallCountForTurn++;
      this.lastAvatarToolName = toolCalls[i].name;
      if (execResult.success) {
        this.lastAvatarToolResult = 'OK';
        this.lastAvatarToolError = '';
        // 标记本 Turn 已执行原生 Tool Call (用于 performanceHintJson 冲突策略)
        this.nativeAvatarToolExecutedForTurn = true;
      } else {
        this.lastAvatarToolResult = '';
        this.lastAvatarToolError = execResult.errorCode;
        // 工具调用失败但已被 AI 尝试: 仍视为 Tool Calling 路径, 不执行 metadata fallback
        this.nativeAvatarToolExecutedForTurn = true;
      }
    }

    // 缓存本轮工具调用和结果, 用于下一轮请求
    this.pendingToolCallsForNextRound = this.pendingToolCallsForNextRound.concat(toolCalls);
    this.pendingToolResultsForNextRound = this.pendingToolResultsForNextRound.concat(executionResults);
    this.avatarToolRoundCount++;

    // 启动下一轮请求 (带 toolResults + priorToolCalls)
    try {
      await this.continueWithToolResults(
        assistantId, callbacks, context, snapshot, requestMessages, excludeId, perChatEffort
      );
      return true;
    } catch (e) {
      Logger.warn(LOG_TAG, 'AvatarTool continueWithToolResults failed: ' + String(e));
      return false;
    }
  }

  /**
   * Phase 4A-3: 使用工具结果继续下一轮流式请求。
   *
   * 复用 doStream 的请求构建逻辑, 但在 effectiveOptions 中注入:
   * - tools: 同上一轮 (继续允许 AI 调用工具)
   * - toolResults: 上一轮工具执行结果
   * - priorToolCalls: 上一轮 AI 返回的工具调用 (用于回传 assistant tool_calls 消息)
   */
  private async continueWithToolResults(
    assistantId: string,
    callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext,
    snapshot: PromptPresetRequestSnapshot,
    requestMessages: ChatMessage[],
    excludeId: string | undefined,
    perChatEffort: string
  ): Promise<void> {
    if (this.disposed) {
      return;
    }

    // 重新计算 Token 预算 (因为增加了 tool 消息)
    await this.updateRequestPlan(requestMessages, snapshot.generationSettings);

    if (this.lastTokenBudget !== undefined && this.lastTokenBudget.exceedsBudget) {
      // 超预算: 终止 Tool Calling, 但不阻塞主流程
      Logger.warn(LOG_TAG, 'AvatarTool continue exceeded budget');
      return;
    }

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
      stream: true,
      reasoningEffort: perChatEffort,
      tools: this.buildAvatarToolsForRequest(),
      toolResults: this.pendingToolResultsForNextRound,
      priorToolCalls: this.pendingToolCallsForNextRound
    };

    // 创建新的 streamCallbacks (复用 doStream 的回调结构, 但 onComplete 内处理 toolCalls)
    const operationId: number = context.operationId;
    const isCurrent = (): boolean => this.isCurrentGeneration(context);

    const streamCallbacks: ChatStreamCallbacks = {
      onStart: (): void => {
        this.clearStartTimer();
      },
      onDelta: (delta: ChatDelta): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        if (this.state !== ChatState.Streaming && this.state !== ChatState.Sending) {
          return;
        }
        if (!isCurrent()) {
          return;
        }
        this.appendDelta(assistantId, delta.content, callbacks);
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
          return;
        }
        // 检查是否有新的工具调用 (进入下一轮)
        if (result.toolCalls !== undefined && result.toolCalls.length > 0) {
          this.handleAvatarToolCalls(
            result, assistantId, callbacks, context, snapshot, requestMessages, excludeId, perChatEffort
          ).then((continued: boolean): void => {
            if (!continued) {
              // 未继续: 走最终完成流程
              this.finalizeAssistantTurn(
                assistantId, result, callbacks, context, operationId
              );
            }
          }).catch((e: Object): void => {
            Logger.warn(LOG_TAG, 'handleAvatarToolCalls threw: ' + String(e));
            this.finalizeAssistantTurn(
              assistantId, result, callbacks, context, operationId
            );
          });
          return;
        }
        // 无工具调用: 走最终完成流程
        this.finalizeAssistantTurn(
          assistantId, result, callbacks, context, operationId
        );
      },
      onError: (error: NetworkError): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        if (this.state === ChatState.Cancelled) {
          return;
        }
        if (!isCurrent()) {
          return;
        }
        this.finalizeAssistant(
          assistantId, '', ChatMessageStatus.Failed, error.message, callbacks
        );
        this.currentAssistantId = null;
        this.persistFinalAssistant(assistantId).then((): void => {
          if (context.kind === ChatGenerationKind.SwipeCandidate) {
            this.updateSwipeSummaryGeneratingFlag(false);
          }
          this.persistChatActivity();
          this.clearActiveGeneration(operationId);
          this.setState(ChatState.Failed, callbacks);
          callbacks.onError(error.message);
        }).catch((_e: Object): void => {
          this.clearActiveGeneration(operationId);
          this.setState(ChatState.Failed, callbacks);
          callbacks.onError(error.message);
        });
      }
    };

    try {
      const planMessages: ChatMessage[] = this.lastHistoryTrimResult !== undefined
        ? this.lastHistoryTrimResult.messages
        : requestMessages;
      this.currentHandle = this.modelService.streamCurrentChat(
        planMessages, effectiveOptions, streamCallbacks
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'continueWithToolResults streamCurrentChat threw: ' + String(e));
    }
  }

  /**
   * Phase 4A-3: 助手 Turn 最终完成流程 (统一处理原生 Tool Calling 和普通完成)。
   *
   * - 若 nativeAvatarToolExecutedForTurn = true, 跳过 performanceHintJson 发布
   * - 否则正常透传 performanceHintJson
   *
   * Phase 4C-2: 递增 SessionState.assistantTurnIndex (只在真实最终回复完成时递增,
   * 流式 token / tool result 中间轮次不递增)。
   */
  private finalizeAssistantTurn(
    assistantId: string,
    result: ChatStreamResult,
    callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext,
    operationId: number
  ): void {
    if (this.disposed) {
      return;
    }
    const finalStatus: ChatMessageStatus = this.finalizeAssistant(
      assistantId, result.content, ChatMessageStatus.Completed, undefined, callbacks
    );
    this.currentAssistantId = null;

    // Phase 4C-2: 递增助手 Turn 计数 (只在真实最终回复完成时, 不在流式 token 或 tool result 中间轮次)
    // 必须在 finalizeAssistant 之后, 但在后续异步持久化之前, 保证状态一致
    if (this.avatarDialogueSessionState !== null) {
      try {
        this.avatarDialogueSessionState.incrementAssistantTurn();
      } catch (e) {
        Logger.warn(LOG_TAG, 'incrementAssistantTurn threw: ' + String(e));
      }
    }

    // Phase 4A-3: performanceHintJson 冲突策略
    // 同一 Turn 已执行原生 Avatar Tool Call 时, 忽略 performanceHintJson
    if (finalStatus !== ChatMessageStatus.Failed
      && callbacks.onAssistantMessageFinalized !== undefined) {
      try {
        let hintJson: string = '';
        if (!this.nativeAvatarToolExecutedForTurn) {
          hintJson = result.performanceHintJson ?? '';
        }
        callbacks.onAssistantMessageFinalized(assistantId, hintJson);
      } catch (e) {
        Logger.warn(LOG_TAG, 'onAssistantMessageFinalized threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
    }

    this.persistFinalAssistant(assistantId).then((): void => {
      if (context.kind === ChatGenerationKind.SwipeCandidate) {
        this.updateSwipeSummaryGeneratingFlag(false);
      }
      this.persistChatActivity();
      this.clearActiveGeneration(operationId);
      this.updateLastAssistantMessageId();
      if (finalStatus === ChatMessageStatus.Failed) {
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('模型返回了空回复,请重试');
      } else {
        this.setState(ChatState.Completed, callbacks);
      }
      if (context.kind === ChatGenerationKind.NormalResponse) {
        this.triggerMemorySummaryAsync();
      } else if (context.kind === ChatGenerationKind.SwipeCandidate) {
        this.invalidateMemoryFromMessagePosition(assistantId);
      }
    }).catch((_e: Object): void => {
      this.clearActiveGeneration(operationId);
      this.updateLastAssistantMessageId();
      if (context.kind === ChatGenerationKind.SwipeCandidate) {
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('候选回复持久化失败,请重试');
      } else if (finalStatus === ChatMessageStatus.Failed) {
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('模型返回了空回复,请重试');
      } else {
        this.setState(ChatState.Completed, callbacks);
      }
    });
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
    // 用户称呼优先级:对话覆盖 > 角色设置 > 全局设置 > 'User'
    const resolvedUserName: string = await this.resolveUserName();
    const macroContext: MacroContext = this.promptBuilder.buildMacroContext(
      this.character,
      resolvedUserName,
      sourceMessages
    );

    // 长期记忆注入(v12 多层优先,回退单段)
    // v12: 优先使用 getMultiLayerInjectionContext 获取 Core/Chapter/Rolling/Legacy 分层记忆
    // 失败或无记忆时回退到空,不影响主流程
    // v8.3 Phase 2: 同时取得 memoryEndPosition 用于 RecentMessageSelector 去重
    let memoryLayers: MemoryLayersInjection | undefined = undefined;
    let memoryEndPosition: number = -1;
    if (this.memoryService !== null && this.activeBranchId.length > 0) {
      try {
        const multi = await this.memoryService.getMultiLayerInjectionContext(this.activeBranchId);
        if (multi.enabled) {
          // v12: 使用分层注入
          memoryLayers = {
            core: multi.core,
            chapter: multi.chapter,
            rolling: multi.rolling,
            legacy: multi.legacy
          };
          memoryEndPosition = multi.endPosition;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load multi-layer memory failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // v8.3 Phase 2: 使用 RecentMessageSelector 选择最近原始消息窗口
    // - 与长期记忆范围去重:已被记忆覆盖且不在最近窗口的消息不注入原文
    // - 默认保留最近 DEFAULT_RECENT_WINDOW_TARGET(30)条
    // - 保证最近 MIN_COMPLETE_TURNS(2)完整 User+Assistant 轮次
    // - availableTokens 传一个宽松上限,让 RecentMessageSelector 主要做去重 + 窗口
    //   精确 Token 裁剪由后续 HistoryTrimmer 完成
    // - 为 null 时回退到旧行为(传全部 sourceMessages)
    let conversationMessages: ChatMessage[] = sourceMessages;
    if (this.recentMessageSelector !== null && this.tokenCounter !== null) {
      try {
        const selection: ContextHistorySelection = this.recentMessageSelector.select(
          sourceMessages,
          {
            targetCount: DEFAULT_RECENT_WINDOW_TARGET,
            minCompleteTurns: MIN_COMPLETE_TURNS,
            availableTokens: Number.MAX_SAFE_INTEGER,
            memoryEndPosition: memoryEndPosition
          }
        );
        conversationMessages = selection.recentMessages;
        if (selection.selectedCount === 0 && sourceMessages.length > 0) {
          // 选择器异常返回空:回退到 sourceMessages,避免空请求
          Logger.warn(LOG_TAG, 'RecentMessageSelector returned empty, fallback to sourceMessages');
          conversationMessages = sourceMessages;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'RecentMessageSelector failed, fallback to sourceMessages: '
          + (e instanceof Error ? e.message : String(e)));
        conversationMessages = sourceMessages;
      }
    }

    const context: PromptBuildContext = {
      character: this.character !== null ? this.character : undefined,
      lorebook: lorebook,
      characterBook: characterBook,
      messages: conversationMessages,
      macroContext: macroContext,
      presetSystemPrompt: presetSystemPrompt,
      // v12: 优先使用分层注入;memoryLayers 为 undefined 时 PromptBuilder 回退到 memorySummary(此处不传)
      memoryLayers: memoryLayers
      // enablePostHistoryInstructions 默认为 true
      // 后续可由 Preset 配置控制
    };

    const result: PromptBuildResult = this.promptBuilder.build(context);

    // Phase 4C-1: 注入 Avatar 对话演出策略 system message
    // - 策略作为独立 system message 追加到 PromptBuilder 输出的消息列表末尾的 system 段后
    // - 只在 Avatar Tool Calling 可用时注入
    // - 不修改角色卡 / 世界书 / 预设 / 用户消息 / 助手消息
    // - 不持久化, 只参与当前请求
    const finalMessages: ChatMessage[] = this.injectAvatarDialogueStrategy(result.messages);
    return finalMessages;
  }

  /**
   * Phase 4C-1: 注入 Avatar 对话演出策略 system message。
   *
   * - 策略作为独立 system message 追加到请求消息列表
   * - 只有 strategy.enabled = true 时才追加
   * - 不修改原始角色设定文本 / 世界书 / 预设
   * - 不写入用户消息 / 助手消息
   * - 不持久化到聊天数据库
   *
   * 注入位置: 在最后一个 system message 之后, 第一个 user/assistant 消息之前
   * (若找不到 system 消息, 则插入到列表头部)
   *
   * @param messages PromptBuilder 输出的消息列表
   * @returns 追加策略 system message 后的消息列表 (不修改原数组)
   */
  private injectAvatarDialogueStrategy(messages: ChatMessage[]): ChatMessage[] {
    // 刷新最近策略结果 (即使不注入也更新状态, 供 UI 显示)
    this.lastAvatarStrategyResult = this.buildAvatarDialogueStrategy();

    if (this.lastAvatarStrategyResult === null
      || !this.lastAvatarStrategyResult.enabled
      || this.lastAvatarStrategyResult.systemInstruction.length === 0) {
      // 策略未启用: 不修改消息列表
      return messages;
    }

    // 构建独立 system message (不写入数据库, 只参与当前请求)
    const strategyMessage: ChatMessage = createChatMessage(
      generateUuid(),
      ChatRole.System,
      this.lastAvatarStrategyResult.systemInstruction,
      Date.now()
    );

    // 找到最后一个 system message 的位置
    let lastSystemIndex: number = -1;
    for (let i = 0; i < messages.length; i++) {
      if (messages[i].role === ChatRole.System) {
        lastSystemIndex = i;
      } else {
        // 遇到第一个非 system 消息后停止 (system 段通常在头部)
        // 但仍继续扫描以处理中间可能存在的 system 段
      }
    }

    const result: ChatMessage[] = [];
    if (lastSystemIndex === -1) {
      // 无 system 消息: 插入到头部
      result.push(strategyMessage);
      for (let i = 0; i < messages.length; i++) {
        result.push(messages[i]);
      }
    } else {
      // 在最后一个 system message 之后插入
      for (let i = 0; i <= lastSystemIndex; i++) {
        result.push(messages[i]);
      }
      result.push(strategyMessage);
      for (let i = lastSystemIndex + 1; i < messages.length; i++) {
        result.push(messages[i]);
      }
    }
    return result;
  }

  /**
   * Phase 4C-1: 构建当前请求的 Avatar 对话演出策略。
   *
   * - 读取 Provider 支持状态 / 权限模式 / 能力快照
   * - 调用 ArkWebAvatarDialogueStrategyBuilder.build
   * - 失败时返回 null 或 enabled=false 的结果, 不阻塞普通文本聊天
   *
   * Phase 4C-2: 注入会话演出状态摘要 (buildStateSummary), 让 AI 感知
   * 当前演出状态和近期演出历史, 做出节奏感知的决策。
   *
   * - DENY / READ_ONLY: 不注入会话状态摘要 (无可用业务决策)
   * - CONTROL_THIS_CHAT: 注入完整会话状态摘要
   * - Provider 不支持: 不注入策略 (返回 enabled=false)
   *
   * @returns 策略构建结果 (null 表示 Builder 未注入)
   */
  private buildAvatarDialogueStrategy(): ArkWebAvatarDialogueStrategyResult | null {
    if (this.avatarDialogueStrategyBuilder === null) {
      return null;
    }
    if (this.avatarToolRegistry === null
      || this.avatarPermissionController === null
      || this.avatarSnapshotProvider === null) {
      return null;
    }
    // Phase 4A-3R Gate: Tool Integration 未连接或 Provider 非 SUPPORTED 时不注入策略
    // - 即使 4C-2 策略文件存在, 也不允许在未验证 Provider 支持的情况下注入
    // - 防止 UI 误显示"策略已注入"
    if (this.avatarToolIntegrationState !== AvatarToolIntegrationStateConst.CONNECTED) {
      Logger.info(LOG_TAG, `buildAvatarDialogueStrategy: skip (integrationState=${this.avatarToolIntegrationState})`);
      return null;
    }
    if (this.nativeToolCallingSupport !== NativeToolCallingSupportConst.SUPPORTED) {
      Logger.info(LOG_TAG, `buildAvatarDialogueStrategy: skip (nativeToolCallingSupport=${this.nativeToolCallingSupport})`);
      return null;
    }

    const permissionMode: string = this.avatarPermissionController.getPermissionMode();
    const snapshot: ArkWebAvatarAiCapabilitySnapshot | null = this.avatarSnapshotProvider();
    const capabilityContext: string = this.avatarToolRegistry.buildCapabilityContext(snapshot);
    const capabilityTruncated: boolean = capabilityContext.includes('...[truncated]');

    // Phase 4C-2: 注入会话演出状态摘要
    // - 只有 CONTROL_THIS_CHAT 才注入完整状态 (READ_ONLY 也可注入只读状态)
    // - DENY / Provider 不支持: 由 Builder 返回 enabled=false, 不进入此处逻辑
    let sessionStateSummary: string = '';
    if (this.avatarDialogueSessionState !== null
      && permissionMode !== ArkWebAvatarAiToolPermissionModeConst.DENY) {
      try {
        sessionStateSummary = this.avatarDialogueSessionState.buildStateSummary();
      } catch (e) {
        Logger.warn(LOG_TAG, 'buildStateSummary threw: ' + String(e));
        sessionStateSummary = '';
      }
    }

    const input: ArkWebAvatarDialogueStrategyInput = {
      permissionMode: permissionMode,
      providerSupportsToolCalling: this.currentProviderSupportsToolCalling,
      capabilityContext: capabilityContext,
      capabilityTruncated: capabilityTruncated,
      sessionStateSummary: sessionStateSummary
    };

    try {
      return this.avatarDialogueStrategyBuilder.build(input);
    } catch (e) {
      Logger.warn(LOG_TAG, 'buildAvatarDialogueStrategy threw: ' + String(e));
      return null;
    }
  }

  /**
   * Phase 4C-1: 获取 Avatar 对话演出策略状态摘要 (供 UI 显示)。
   *
   * - 策略版本 / 模式 / 是否已注入 / 当前权限 / Provider 支持 / 能力数量 / 每 Turn 上限 / 最近错误
   * - 不包含完整系统提示词
   */
  getAvatarDialogueStrategyStatus(): ArkWebAvatarDialogueStrategyStatus {
    const result: ArkWebAvatarDialogueStrategyResult | null = this.lastAvatarStrategyResult;
    const permissionMode: string = this.avatarPermissionController !== null
      ? this.avatarPermissionController.getPermissionMode()
      : 'DENY';

    let capabilityCount: number = 0;
    if (this.avatarSnapshotProvider !== null) {
      const snapshot: ArkWebAvatarAiCapabilitySnapshot | null = this.avatarSnapshotProvider();
      if (snapshot !== null) {
        capabilityCount = snapshot.animations.length
          + snapshot.poses.length
          + snapshot.expressions.length;
      }
    }

    return {
      strategyVersion: AVATAR_DIALOGUE_STRATEGY_VERSION,
      strategyMode: ArkWebAvatarDialogueStrategyModeConst.BALANCED,
      injected: result !== null && result.enabled,
      permissionMode: permissionMode,
      providerSupported: this.currentProviderSupportsToolCalling,
      capabilityCount: capabilityCount,
      maxPerformPerTurn: AVATAR_STRATEGY_MAX_PERFORM_PER_TURN,
      lastError: result !== null && !result.enabled ? result.errorMessage : ''
    };
  }

  /**
   * Phase 4C-2: 获取 Avatar 对话演出节奏状态文本 (供 AI 面板简洁显示)。
   *
   * 格式:
   *   助手轮次：12
   *   距上次演出：2 轮
   *   连续演出：0
   *   最近演出：Wave
   *
   * - 不展示完整 Prompt / 完整演出记录
   * - 不暴露路径 / URL / resourceId / generation / 相机坐标
   * - 未注入 SessionState 时返回空字符串 (UI 隐藏该区块)
   */
  getAvatarRhythmStatusText(): string {
    if (this.avatarDialogueSessionState === null) {
      return '';
    }
    try {
      return this.avatarDialogueSessionState.getRhythmStatusText();
    } catch (e) {
      Logger.warn(LOG_TAG, 'getRhythmStatusText threw: ' + String(e));
      return '';
    }
  }

  /**
   * Phase 4C-2: 获取 Avatar 对话演出节奏策略版本 (供 UI 显示)。
   *
   * 返回 BALANCED_V1 或空字符串 (未注入时)。
   */
  getAvatarRhythmPolicyVersion(): string {
    if (this.avatarDialogueRhythmPolicy === null) {
      return '';
    }
    return AVATAR_DIALOGUE_RHYTHM_POLICY_VERSION;
  }

  /**
   * Phase 4C-2: 销毁 Avatar 对话演出会话状态 (页面 aboutToDisappear 时调用)。
   *
   * - 清空会话演出历史和当前状态
   * - 不停止用户手动发起的演出 (由 Stage 控制器负责)
   * - 不影响权限控制器 / 工具执行器 (由各自 dispose 负责)
   * - 不写入数据库 / Preferences / 聊天消息
   */
  disposeAvatarDialogueSessionState(): void {
    if (this.avatarDialogueSessionState !== null) {
      try {
        this.avatarDialogueSessionState.dispose();
      } catch (e) {
        Logger.warn(LOG_TAG, 'sessionState dispose threw: ' + String(e));
      }
    }
  }

  // ===== Phase 4A-3R: 原生 Tool Calling 探测与只读烟雾测试 =====

  /**
   * Phase 4A-3R: 探测当前 Provider 是否真正支持原生 Tool Calling。
   *
   * 流程:
   *   1. 检查 Integration 接线状态 (非 CONNECTED → MISCONFIGURED)
   *   2. 检查 Provider 声明 (supportsToolCalling() = false → UNSUPPORTED)
   *   3. 构造探测工具 (ark_tool_capability_probe) 和随机 token
   *   4. 发起流式请求 (tools + tool_choice='auto')
   *   5. 检测返回是否包含结构化 tool_calls (排除正文 JSON / Markdown JSON)
   *   6. 校验 toolCallId / toolName / arguments.token
   *   7. 全部通过 → SUPPORTED; 任何一步失败 → 对应错误码
   *
   * 不写入:
   *   - 聊天历史 / 消息数据库 / 角色记忆 / 世界书 / 用户可见对话 / Avatar 演出历史
   *
   * @returns 探测结果 (包含 success / support / decisionSource / errorCode / errorMessage)
   */
  async probeNativeToolCalling(): Promise<NativeToolCallingProbeResult> {
    const probeToken: string = generateProbeToken();
    const requestId: string = `probe-${Date.now()}-${probeToken}`;
    Logger.info(LOG_TAG, `probeNativeToolCalling: start, requestId=${requestId}, token=${probeToken}`);

    // 1. Integration 接线检查
    if (this.avatarToolIntegrationState !== AvatarToolIntegrationStateConst.CONNECTED) {
      return this.buildProbeFailure(
        NativeToolCallingSupportConst.MISCONFIGURED,
        NativeToolCallingErrorCodeConst.INTEGRATION_NOT_CONNECTED,
        `Avatar Tool Integration not connected (state=${this.avatarToolIntegrationState}).`,
        0,
        requestId
      );
    }

    // 2. Provider 声明检查
    let providerDeclared: boolean = false;
    try {
      providerDeclared = await this.modelService.supportsToolCallingForCurrentProvider();
    } catch (e) {
      return this.buildProbeFailure(
        NativeToolCallingSupportConst.MISCONFIGURED,
        NativeToolCallingErrorCodeConst.PROVIDER_MISCONFIGURED,
        `Provider config resolve failed: ${e instanceof Error ? e.message : String(e)}`,
        0,
        requestId
      );
    }
    if (!providerDeclared) {
      this.currentProviderSupportsToolCalling = false;
      return this.buildProbeFailure(
        NativeToolCallingSupportConst.UNSUPPORTED,
        NativeToolCallingErrorCodeConst.PROVIDER_UNSUPPORTED,
        'Provider declared no native tool calling support (supportsToolCalling()=false).',
        0,
        requestId
      );
    }
    this.currentProviderSupportsToolCalling = true;

    // 3. 构造探测请求
    const probeTool: ArkWebChatToolDefinition = {
      name: NATIVE_TOOL_PROBE_TOOL_NAME,
      description: NATIVE_TOOL_PROBE_TOOL_DESCRIPTION,
      inputSchemaJson: NATIVE_TOOL_PROBE_TOOL_PARAMETERS_JSON
    };
    const probeNow: number = Date.now();
    const probeMessages: ChatMessage[] = [
      createChatMessage(`probe-system-${requestId}`, ChatRole.System,
        'You are a tool calling capability probe. Call the provided tool with the supplied token. Do not output the token as text.',
        probeNow),
      createChatMessage(`probe-user-${requestId}`, ChatRole.User,
        `Please call ark_tool_capability_probe with token="${probeToken}".`,
        probeNow)
    ];
    const probeOptions: ChatRequestOptions = {
      temperature: 0.0,
      topP: 1.0,
      maxTokens: 256,
      stream: true,
      tools: [probeTool]
    };

    // 4. 发起流式请求并等待结果
    let streamResult: ChatStreamResult | null = null;
    let streamError: NetworkError | null = null;
    try {
      streamResult = await new Promise<ChatStreamResult>((resolve, reject): void => {
        const callbacks: ChatStreamCallbacks = {
          onDelta: (_delta: ChatDelta): void => {
            // 探测请求忽略 delta (不写入任何状态)
          },
          onComplete: (result: ChatStreamResult): void => {
            resolve(result);
          },
          onError: (error: NetworkError): void => {
            reject(error);
          }
        };
        this.currentHandle = this.modelService.streamCurrentChat(probeMessages, probeOptions, callbacks);
      });
    } catch (e) {
      streamError = e as NetworkError;
    }

    if (streamError !== null) {
      // NetworkError 无 code 字段, 使用 statusCode (number) 转为字符串
      const errStatusCode: number | undefined = streamError!.statusCode;
      const errCode: string = errStatusCode !== undefined ? String(errStatusCode) : '';
      const errMsg: string = streamError!.message !== undefined ? streamError!.message : String(streamError);
      // HTTP 400/404 通常表示 Provider 或模型不支持 tools
      if (errCode === '400' || errCode === '404' || errCode === 'HTTP_400' || errCode === 'HTTP_404') {
        return this.buildProbeFailure(
          NativeToolCallingSupportConst.UNSUPPORTED,
          NativeToolCallingErrorCodeConst.PROVIDER_UNSUPPORTED,
          `Provider rejected tools (HTTP ${errCode}): ${errMsg}`,
          parseInt(errCode.replace('HTTP_', ''), 10) || 0,
          requestId
        );
      }
      return this.buildProbeFailure(
        NativeToolCallingSupportConst.MISCONFIGURED,
        NativeToolCallingErrorCodeConst.PROVIDER_MISCONFIGURED,
        `Probe request failed: ${errMsg} (code=${errCode})`,
        0,
        requestId
      );
    }

    if (streamResult === null) {
      return this.buildProbeFailure(
        NativeToolCallingSupportConst.MISCONFIGURED,
        NativeToolCallingErrorCodeConst.UNKNOWN_ERROR,
        'Probe returned null result.',
        0,
        requestId
      );
    }

    // 5. 检测结构化 tool_calls
    const toolCalls: ArkWebChatToolCall[] | undefined = streamResult.toolCalls;
    if (toolCalls === undefined || toolCalls.length === 0) {
      // 检查是否正文包含 JSON (拒绝文本模拟)
      const content: string = streamResult.content;
      if (content.length > 0 && (content.includes('"token"') || content.includes('ark_tool_capability_probe'))) {
        return this.buildProbeFailure(
          NativeToolCallingSupportConst.UNSUPPORTED,
          NativeToolCallingErrorCodeConst.TEXT_SIMULATION_REJECTED,
          'Provider returned tool call in text content instead of structured tool_calls.',
          0,
          requestId
        );
      }
      return this.buildProbeFailure(
        NativeToolCallingSupportConst.UNSUPPORTED,
        NativeToolCallingErrorCodeConst.MODEL_UNSUPPORTED,
        'Provider returned no structured tool_calls.',
        0,
        requestId
      );
    }

    // 6. 校验第一个 tool call (探测工具)
    const firstCall: ArkWebChatToolCall = toolCalls[0];
    const validationResult: ValidateProbeToolCallResult = validateProbeToolCall(
      firstCall.toolCallId,
      firstCall.name,
      firstCall.argumentsJson,
      probeToken
    );
    if (!validationResult.valid) {
      return this.buildProbeFailure(
        NativeToolCallingSupportConst.MISCONFIGURED,
        validationResult.errorCode,
        validationResult.errorMessage,
        0,
        requestId
      );
    }

    // 7. 全部通过, 标记 SUPPORTED
    const successResult: NativeToolCallingProbeResult = {
      success: true,
      support: NativeToolCallingSupportConst.SUPPORTED,
      decisionSource: NativeToolCallingDecisionSourceConst.RUNTIME_PROBE,
      errorCode: NativeToolCallingErrorCodeConst.UNKNOWN_ERROR,
      errorMessage: '',
      probedToolCallId: firstCall.toolCallId,
      probedToolName: firstCall.name,
      returnedToken: probeToken,
      httpStatus: 200,
      requestId: requestId,
      probedAt: Date.now()
    };
    this.lastProbeResult = successResult;
    this.nativeToolCallingSupport = NativeToolCallingSupportConst.SUPPORTED;
    this.nativeToolCallingDecisionSource = NativeToolCallingDecisionSourceConst.RUNTIME_PROBE;
    this.nativeToolCallingProbeErrorCode = '';
    this.nativeToolCallingProbeErrorMessage = '';
    Logger.info(LOG_TAG, `probeNativeToolCalling: SUCCESS, requestId=${requestId}`);
    return successResult;
  }

  /**
   * Phase 4A-3R: 构建探测失败结果并更新内部状态。
   */
  private buildProbeFailure(
    support: NativeToolCallingSupport,
    errorCode: NativeToolCallingErrorCode,
    errorMessage: string,
    httpStatus: number,
    requestId: string
  ): NativeToolCallingProbeResult {
    const result: NativeToolCallingProbeResult = {
      success: false,
      support: support,
      decisionSource: NativeToolCallingDecisionSourceConst.RUNTIME_PROBE,
      errorCode: errorCode,
      errorMessage: errorMessage,
      probedToolCallId: '',
      probedToolName: '',
      returnedToken: '',
      httpStatus: httpStatus,
      requestId: requestId,
      probedAt: Date.now()
    };
    this.lastProbeResult = result;
    this.nativeToolCallingSupport = support;
    this.nativeToolCallingDecisionSource = NativeToolCallingDecisionSourceConst.RUNTIME_PROBE;
    this.nativeToolCallingProbeErrorCode = errorCode;
    this.nativeToolCallingProbeErrorMessage = errorMessage;
    Logger.warn(LOG_TAG, `probeNativeToolCalling: FAILED, support=${support}, errorCode=${errorCode}, requestId=${requestId}`);
    return result;
  }

  /**
   * Phase 4A-3R: 运行只读 Avatar 工具烟雾测试 (avatar_get_state)。
   *
   * 前置条件:
   *   - Tool Integration 已连接
   *   - nativeToolCallingSupport === SUPPORTED
   *   - 权限为 READ_ONLY 或 CONTROL_THIS_CHAT
   *
   * 流程:
   *   1. 临时构造只读请求 (tools=[avatar_get_state], tool_choice='auto')
   *   2. 发起流式请求, 等待 Provider 返回 avatar_get_state tool call
   *   3. 通过 ToolExecutor 执行 avatar_get_state
   *   4. 将 tool result 回传 Provider 续写下一轮
   *   5. 等待 Provider 返回最终普通文本
   *
   * 不播放动作, 不修改模型, 不写入聊天历史。
   *
   * @returns 烟雾测试结果 (success / errorCode / errorMessage / finalText 摘要)
   */
  async runReadOnlyAvatarToolSmokeTest(): Promise<ReadOnlyAvatarToolSmokeTestResult> {
    Logger.info(LOG_TAG, 'runReadOnlyAvatarToolSmokeTest: start');

    // 前置条件检查
    if (this.avatarToolIntegrationState !== AvatarToolIntegrationStateConst.CONNECTED) {
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.INTEGRATION_NOT_CONNECTED,
        errorMessage: `Avatar Tool Integration not connected (state=${this.avatarToolIntegrationState}).`,
        finalTextSnippet: '',
        toolCallId: ''
      };
      return r;
    }
    if (this.nativeToolCallingSupport !== NativeToolCallingSupportConst.SUPPORTED) {
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.PROVIDER_UNSUPPORTED,
        errorMessage: `Native tool calling not supported (support=${this.nativeToolCallingSupport}). Run probe first.`,
        finalTextSnippet: '',
        toolCallId: ''
      };
      return r;
    }
    if (this.avatarToolExecutor === null || this.avatarPermissionController === null
      || this.avatarSnapshotProvider === null || this.avatarExecutorRuntime === null) {
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.INTEGRATION_NOT_CONNECTED,
        errorMessage: 'Tool executor dependencies not injected.',
        finalTextSnippet: '',
        toolCallId: ''
      };
      return r;
    }
    const permissionMode: string = this.avatarPermissionController.getPermissionMode();
    if (permissionMode !== 'READ_ONLY' && permissionMode !== 'CONTROL_THIS_CHAT') {
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.UNKNOWN_ERROR,
        errorMessage: `Permission mode must be READ_ONLY or CONTROL_THIS_CHAT (current=${permissionMode}).`,
        finalTextSnippet: '',
        toolCallId: ''
      };
      return r;
    }

    // 构造只读工具列表 (只注入 avatar_get_state)
    const snapshot: ArkWebAvatarAiCapabilitySnapshot | null = this.avatarSnapshotProvider();
    const allTools: ArkWebChatToolDefinition[] = this.avatarToolRegistry!.buildToolDefinitions(snapshot, 'READ_ONLY');
    const readOnlyTools: ArkWebChatToolDefinition[] = allTools.filter((t: ArkWebChatToolDefinition): boolean =>
      t.name === 'avatar_get_state');
    if (readOnlyTools.length === 0) {
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.UNKNOWN_ERROR,
        errorMessage: 'avatar_get_state tool not available.',
        finalTextSnippet: '',
        toolCallId: ''
      };
      return r;
    }

    // 第一轮: 发起请求, 等待 Provider 返回 tool call
    const now1: number = Date.now();
    const smokeMessages: ChatMessage[] = [
      createChatMessage(`smoke-system-${now1}`, ChatRole.System,
        'You are a tool calling smoke test. Call avatar_get_state to inspect the avatar state.', now1),
      createChatMessage(`smoke-user-${now1}`, ChatRole.User,
        'Call avatar_get_state and tell me the result.', now1)
    ];
    const smokeOptions: ChatRequestOptions = {
      temperature: 0.0,
      topP: 1.0,
      maxTokens: 512,
      stream: true,
      tools: readOnlyTools
    };

    let firstResult: ChatStreamResult | null = null;
    try {
      firstResult = await new Promise<ChatStreamResult>((resolve, reject): void => {
        const callbacks: ChatStreamCallbacks = {
          onDelta: (_delta: ChatDelta): void => {},
          onComplete: (result: ChatStreamResult): void => { resolve(result); },
          onError: (error: NetworkError): void => { reject(error); }
        };
        this.currentHandle = this.modelService.streamCurrentChat(smokeMessages, smokeOptions, callbacks);
      });
    } catch (e) {
      const err: NetworkError = e as NetworkError;
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.PROVIDER_MISCONFIGURED,
        errorMessage: `Smoke test first round failed: ${err.message !== undefined ? err.message : String(err)}`,
        finalTextSnippet: '',
        toolCallId: ''
      };
      return r;
    }

    const toolCalls: ArkWebChatToolCall[] | undefined = firstResult.toolCalls;
    if (toolCalls === undefined || toolCalls.length === 0) {
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.MODEL_UNSUPPORTED,
        errorMessage: 'Provider did not return avatar_get_state tool call.',
        finalTextSnippet: firstResult.content.substring(0, 200),
        toolCallId: ''
      };
      return r;
    }

    // 执行 avatar_get_state
    const toolCall: ArkWebChatToolCall = toolCalls[0];
    if (toolCall.name !== 'avatar_get_state') {
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.TEXT_SIMULATION_REJECTED,
        errorMessage: `Provider returned wrong tool name: ${toolCall.name}`,
        finalTextSnippet: '',
        toolCallId: toolCall.toolCallId
      };
      return r;
    }
    const toolContext: ArkWebAvatarAiToolContext = {
      chatTurnId: `smoke-${Date.now()}`,
      snapshot: snapshot,
      permissionMode: 'READ_ONLY'
    };
    let toolResult: ArkWebChatToolExecutionResult;
    try {
      toolResult = await this.avatarToolExecutor.execute(toolContext, toolCall);
    } catch (e) {
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.UNKNOWN_ERROR,
        errorMessage: `avatar_get_state execution failed: ${e instanceof Error ? e.message : String(e)}`,
        finalTextSnippet: '',
        toolCallId: toolCall.toolCallId
      };
      return r;
    }
    if (!toolResult.success) {
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: toolResult.errorCode.length > 0 ? toolResult.errorCode : NativeToolCallingErrorCodeConst.UNKNOWN_ERROR,
        errorMessage: `avatar_get_state execution failed: ${toolResult.errorMessage}`,
        finalTextSnippet: '',
        toolCallId: toolCall.toolCallId
      };
      return r;
    }

    // 第二轮: 回传 tool result, 等待最终文本
    // 注意: ChatMessage 无 toolCalls/toolCallId 字段, 此处用 priorToolCalls + toolResults 传递
    const now2: number = Date.now();
    const assistantMsg: ChatMessage = createChatMessage(
      `smoke-assistant-${now2}`, ChatRole.Assistant, '', now2);
    const toolMsg: ChatMessage = createChatMessage(
      `smoke-tool-${now2}`, ChatRole.System, toolResult.resultJson, now2);
    const secondMessages: ChatMessage[] = [
      ...smokeMessages,
      assistantMsg,
      toolMsg
    ];
    const secondOptions: ChatRequestOptions = {
      temperature: 0.0,
      topP: 1.0,
      maxTokens: 512,
      stream: true,
      tools: readOnlyTools,
      priorToolCalls: [toolCall],
      toolResults: [toolResult]
    };

    let finalResult: ChatStreamResult | null = null;
    try {
      finalResult = await new Promise<ChatStreamResult>((resolve, reject): void => {
        const callbacks: ChatStreamCallbacks = {
          onDelta: (_delta: ChatDelta): void => {},
          onComplete: (result: ChatStreamResult): void => { resolve(result); },
          onError: (error: NetworkError): void => { reject(error); }
        };
        this.currentHandle = this.modelService.streamCurrentChat(secondMessages, secondOptions, callbacks);
      });
    } catch (e) {
      const err: NetworkError = e as NetworkError;
      const r: ReadOnlyAvatarToolSmokeTestResult = {
        success: false,
        errorCode: NativeToolCallingErrorCodeConst.RESULT_CONTINUATION_MISSING,
        errorMessage: `Smoke test second round failed: ${err.message !== undefined ? err.message : String(err)}`,
        finalTextSnippet: '',
        toolCallId: toolCall.toolCallId
      };
      return r;
    }

    Logger.info(LOG_TAG, `runReadOnlyAvatarToolSmokeTest: SUCCESS, toolCallId=${toolCall.toolCallId}`);
    const okResult: ReadOnlyAvatarToolSmokeTestResult = {
      success: true,
      errorCode: '',
      errorMessage: '',
      finalTextSnippet: finalResult.content.substring(0, 200),
      toolCallId: toolCall.toolCallId
    };
    return okResult;
  }

  /**
   * 异步触发长期记忆增量总结。
   * v12: 优先调用 tryGenerateMultiLayerMemory(章节优先,回退 rolling),
   * 失败时回退到旧版 trySummarize,保证兼容性。
   * - 失败不抛出,不阻塞已完成状态
   * - 不调用 await,在后台执行
   * - 仅记录触发阶段,不记录消息内容
   */
  private triggerMemorySummaryAsync(): void {
    if (this.memoryService === null) {
      return;
    }
    if (this.currentChatId === undefined || this.currentChatId.length === 0) {
      return;
    }
    if (this.activeBranchId.length === 0) {
      return;
    }
    const chatId: string = this.currentChatId;
    const branchId: string = this.activeBranchId;
    const branchMessages: ChatMessage[] = this.messages.slice();
    // v12: 优先使用多层记忆生成(章节优先,回退 rolling)
    // 不 await:后台执行,失败仅记录日志
    this.memoryService.tryGenerateMultiLayerMemory(chatId, branchId, branchMessages)
      .then((result): void => {
        if (!result.success) {
          Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=failed'
            + (result.error !== undefined ? ' err=' + result.error : ''));
        }
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=exception: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * v12: 失效指定消息 position 之后的记忆(软失效)。
   * 用于 Swipe 切换、Swipe 候选生成完成等场景。
   * - 找到 messageId 在 this.messages 中的索引作为 position
   * - 调用 memoryService.softInvalidateFromPosition(branchId, position)
   * - 失败不阻塞,只记录 warn
   * - 不记录消息内容
   *
   * @param messageId 触发失效的消息 ID(该 position 及之后的记忆都会失效)
   */
  private invalidateMemoryFromMessagePosition(messageId: string): void {
    if (this.memoryService === null) {
      return;
    }
    if (this.activeBranchId.length === 0) {
      return;
    }
    // 查找消息 position(在 this.messages 中的索引)
    let position: number = -1;
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        position = i;
        break;
      }
    }
    if (position < 0) {
      return;
    }
    const branchId: string = this.activeBranchId;
    // 不 await:后台执行,失败仅记录日志
    this.memoryService.softInvalidateFromPosition(branchId, position)
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'MemoryInvalidate | failed: '
          + (e instanceof Error ? e.message : String(e)));
      });
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

    // v8.1: per-chat 上下文预算覆盖(由 ContextBudgetService 提供)
    // followModel=false 时,使用用户自定义值覆盖 effectiveSettings
    if (this.contextBudgetService !== null && this.currentChatId !== undefined) {
      try {
        const budget = await this.contextBudgetService.getBudget(this.currentChatId);
        if (!budget.followModel) {
          // 自定义值已在 Service 内部 clamp 到合法范围
          if (budget.customContextWindow > 0) {
            contextWindow = budget.customContextWindow;
          }
          if (budget.customReservedOutputTokens > 0) {
            reserved = budget.customReservedOutputTokens;
          }
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'contextBudgetService.getBudget failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // v8.3 Phase 2: 输入可用预算 = contextWindow - reserved - safetyMargin
    // 安全余量动态计算:
    // - 至少 MIN_SAFETY_MARGIN(1024)Token,避免小上下文窗口时余量不足
    // - 按 contextWindow 的 3% 计算,大上下文窗口时余量按比例增大
    // - 上限 MAX_SAFETY_MARGIN(8192)Token,避免超大上下文窗口(1M)时余量浪费
    // 安全余量用于 Token 估算误差和 Provider 包装(系统消息、JSON 序列化等附加 Token)
    const safetyMargin: number = calculateSafetyMargin(contextWindow);
    let available: number = contextWindow - reserved - safetyMargin;
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
      // 更新 lastBuiltRequestMessages 为裁剪后的最终消息,
      // 让 UI 上下文占用统计反映实际发送给模型的内容。
      this.lastBuiltRequestMessages = currentMessages;

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
      Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_start_timeout');
      // 持久化最终 Failed 状态,完成后才清理上下文
      this.persistFinalAssistant(assistantId).then((): void => {
        Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_failed_persisted');
        Logger.warn(LOG_TAG, 'generation finalized status=failed');
        // Swipe:更新摘要生成标志
        if (context.kind === ChatGenerationKind.SwipeCandidate) {
          this.updateSwipeSummaryGeneratingFlag(false);
        }
        // 更新 Chat 活跃时间
        this.persistChatActivity();
        // 清理活动上下文
        this.clearActiveGeneration(context.operationId);
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
   * 通知消息列表变更。
   * this.messages 已是不可变更新产生的新数组引用,直接传递避免额外复制。
   * callbacks 为 null 时跳过(用于 dispose 后或无回调场景)。
   */
  private emitMessages(callbacks: ChatServiceCallbacks | null): void {
    if (callbacks === null) {
      return;
    }
    callbacks.onMessagesChanged(this.messages);
  }

  /**
   * 追加 delta 内容到指定 Assistant 消息(创建新对象和新数组)。
   *
   * 优化:用 findIndex + slice + 替换目标元素,代替 map 全量遍历。
   * slice 浅拷贝比 map 快(不调用函数),且只对目标元素调用 mergeChatMessage。
   */
  private appendDelta(assistantId: string, delta: string, callbacks: ChatServiceCallbacks): void {
    if (delta.length === 0) {
      return;
    }
    const idx: number = this.messages.findIndex((m: ChatMessage): boolean => m.id === assistantId);
    if (idx < 0) {
      return;
    }
    const oldMsg: ChatMessage = this.messages[idx];
    // 完整不可变复制:使用 mergeChatMessage 保留所有字段
    const newMsg: ChatMessage = mergeChatMessage(oldMsg, {
      content: oldMsg.content + delta,
      updatedAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming
    });
    const newMessages: ChatMessage[] = this.messages.slice();
    newMessages[idx] = newMsg;
    this.messages = newMessages;
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
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          content: finalContent,
          updatedAt: Date.now(),
          isStreaming: false,
          errorMessage: finalError,
          status: finalStatus
        });
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
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          content: _content !== undefined ? _content : msg.content,
          updatedAt: Date.now(),
          isStreaming: false,
          errorMessage: errorMessage !== undefined ? errorMessage : msg.errorMessage,
          status: status
        });
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
    } else if (this.persistenceService !== null) {
      // 正常持久化
      this.persistenceService.updateMessage(this.currentChatId, msg).catch(
        (e: Object): void => {
          Logger.warn(LOG_TAG, 'delta persist failed: '
            + (e instanceof Error ? e.message : String(e)));
        }
      );
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
      return this.swipePersistenceService.updateCandidate(
        ctx.assistantMessageId,
        ctx.swipeCandidateIndex,
        updates
      ).then((): void => {
      }).catch((e: Object): Promise<void> => {
        const msg2: string = e instanceof Error ? e.message : String(e);
        if (retriesLeft > 0) {
          Logger.warn(LOG_TAG, 'swipe final persist retry: ' + msg2);
          return this.persistWithRetry(msg, retriesLeft - 1);
        }
        Logger.warn(LOG_TAG, 'swipe final persist failed: ' + msg2);
        Logger.warn(LOG_TAG, 'SwipeRuntime | stage=final_persist_failed');
        return Promise.reject(new Error('swipe final persist failed'));
      });
    } else if (this.persistenceService !== null) {
      // 正常持久化
      return this.persistenceService.updateMessage(chatId, msg).then((): void => {
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
      // v12: 切换候选后,失效该 Assistant position 之后的记忆(内容已变化,旧摘要可能不准确)
      // 失败不阻塞,只记录 warn
      this.invalidateMemoryFromMessagePosition(assistantMessageId);
      this.emitMessages(this.lastCallbacks);
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
      // v12: 切换候选后,失效该 Assistant position 之后的记忆(内容已变化,旧摘要可能不准确)
      // 失败不阻塞,只记录 warn
      this.invalidateMemoryFromMessagePosition(assistantMessageId);
      this.emitMessages(this.lastCallbacks);
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
      this.currentChat = session.chat;
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
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          content: '',
          updatedAt: Date.now(),
          isStreaming: true,
          errorMessage: undefined,
          status: ChatMessageStatus.Streaming
        });
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