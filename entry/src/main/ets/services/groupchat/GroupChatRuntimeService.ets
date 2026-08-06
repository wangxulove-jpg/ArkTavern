/**
 * GroupChatRuntimeService 多人聊天运行时服务(G-RUNTIME-1B / G-RUNTIME-1C)
 *
 * 职责:
 * - 启动一轮多人聊天生成(严格顺序执行,不并发)
 * - 管理流式回调校验(operationId/roundId/chatId/speakerIndex/speakerCharacterId/assistantMessageId)
 * - 节流持久化 Streaming delta(每 400ms 或 64 字符)
 * - 最终持久化 Completed/Cancelled/Failed(无条件)
 * - 停止整轮(中止当前请求,标记 Cancelled,不启动后续角色)
 * - 错误处理(任一角色失败→停止整轮,标记 Failed)
 * - 向 ViewModel 发送状态更新
 *
 * G-RUNTIME-1C 新增:
 * - retrySpeakerMessage:重试单条 Failed/Cancelled 角色消息(创建新消息,不覆盖原消息)
 * - endRound:用户主动结束本轮(清理活动上下文,不删除消息)
 * - 重复完成保护(SpeakerContext.finalized):每条 Assistant 消息只能从 Streaming 进入一个终态
 * - 下一角色幂等保护(advancedSpeakerKeys):同一 (operationId, speakerIndex) 只能推进一次
 * - 模型配置快照(configSnapshot):一轮内 A/B/C 使用同一 ProviderConfig,中途修改设置不影响本轮
 * - 重试迟到回调保护:重试创建新 operationId,原失败请求的迟到回调被 validateCallback 拒绝
 *
 * 严格顺序:
 * - 使用 async/await 串行执行,不使用 Promise.all
 * - 角色A最终消息没有可靠持久化→角色B绝不能开始
 * - 每个角色开始生成前重新读取完整消息历史(确保同轮前序回复可见)
 *
 * 不依赖:
 * - ArkUI / Page
 * - 单聊 ChatService / currentHandle
 * - 数据库 Schema(只通过 GroupConversationMessageService 访问)
 *
 * 日志规则:
 * - 不打印 API Key / Authorization / 完整 Base URL / 完整 Prompt / 完整聊天正文 / 角色卡正文
 * - 只打印操作类别、状态枚举、消息数量、Token 估算
 */

import { ChatMessage, ChatMessageStatus, MessageSenderType } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ChatStreamCallbacks, ChatStreamHandle, ChatDelta, ChatStreamResult } from '../../models/ChatStreamTypes';
import { NetworkError, NetworkErrorType } from '../../models/NetworkError';
import { ChatRequestOptions, ChatRequest } from '../../models/ChatRequest';
import { ProviderConfig, TEMPERATURE_DEFAULT, TOP_P_DEFAULT, MAX_TOKENS_DEFAULT } from '../../models/ProviderConfig';
import { ModelService } from '../ModelService';
import { Logger } from '../../utils/Logger';
import { GroupRoundCoordinator } from './GroupRoundCoordinator';
import { GroupConversationMessageService } from './GroupConversationMessageService';
import {
  GroupPromptAssembler,
  GroupPromptAssemblyResult
} from './GroupPromptAssembler';
import {
  GroupRoundState,
  GroupRoundPlan,
  GroupRoundSpeaker,
  ActiveGroupRoundContext,
  GroupSpeakerRetryContext,
  GroupSpeakerRetryError,
  GroupSpeakerRetryErrorKind,
  GroupReplyTarget,
  REPLY_TARGET_ALL_ENABLED
} from './GroupRoundTypes';
import { GroupRuntimeRegistry } from './GroupRuntimeRegistry';
import { EffectiveGenerationSettings } from '../PromptPresetRuntimeResolver';
import {
  GroupNarrationPromptInput,
  GroupNarrationPromptResult,
  buildNarrationPrompt
} from './GroupNarrationPromptAssembler';
import { GroupPromptInspectionStore } from './GroupPromptInspectionStore';
import {
  GroupMessageVisibilityPolicy,
  GroupVisibleHistoryResult,
  GroupMessageVisibilityDecision
} from './GroupMessageVisibilityPolicy';
import {
  GroupPromptInspectionSnapshot,
  MemoryInspectionItem,
  RelationshipInspectionItem,
  PromptMessageInspectionItem,
  TokenBudgetInspection,
  LorebookInspection,
  HistoryVisibilityInspectionItem,
  MemoryInjectionInspectionItem,
  RelationshipInjectionInspectionItem
} from '../../models/groupchat/GroupPromptInspectionModels';
import {
  GroupCharacterMemorySelectionInput,
  GroupCharacterMemorySelection,
  GROUP_CHARACTER_PERSONAL_MEMORY_MAX_COUNT,
  GROUP_CHARACTER_RELATIONSHIP_MEMORY_MAX_COUNT,
  GROUP_CHARACTER_PERSONAL_MEMORY_TOKEN_BUDGET,
  GROUP_CHARACTER_RELATIONSHIP_MEMORY_TOKEN_BUDGET
} from '../../models/groupchat/GroupPromptInspectionModels';
import { GroupCharacterMemorySelector } from './GroupCharacterMemorySelector';
import { GroupCharacterMemoryStatus, GroupCharacterMemory } from '../../models/groupchat/GroupCharacterMemory';
import {
  GroupRelationshipTargetType,
  GroupRelationshipMemoryStatus
} from '../../models/groupchat/GroupCharacterRelationshipMemory';
import { GroupCharacterMemoryService, GroupCharacterMemoryFilter } from './GroupCharacterMemoryService';
import { GroupAutoSummaryExecutor } from './GroupAutoSummaryExecutor';
import { GroupAutoSummaryPlanner, GroupAutoSummaryPlanInput } from './GroupAutoSummaryPlanner';
import { GroupAutoSummaryPlan, GroupAutoSummaryExecutionResult, GroupAutoSummaryExecutionStatus, GroupAutoSummarySettings, loadGroupAutoSummarySettings } from '../../models/groupchat/GroupAutoSummaryModels';

const LOG_TAG: string = 'GroupRuntime';

/** 流式持久化节流时间(毫秒) */
const PERSISTENCE_THROTTLE_MS: number = 400;
/** 流式持久化最小字符增量(达到则立即 flush) */
const PERSISTENCE_MIN_CHARS: number = 64;

/**
 * 单角色流式生成结果。
 */
enum SpeakerResult {
  /** 正常完成 */
  Completed,
  /** 被用户停止 */
  Cancelled,
  /** 生成失败 */
  Failed
}

/**
 * 单角色执行上下文(用于回调校验)。
 * 在角色开始生成时创建,回调中校验是否仍属于当前轮次和当前角色。
 *
 * G-RUNTIME-1C:
 * - finalized:重复完成保护标记。一旦设置为 true,
 *   后续 onComplete / onError / abort 后的回调被拒绝。
 */
interface SpeakerContext {
  readonly operationId: number;
  readonly roundId: string;
  readonly chatId: string;
  readonly speakerIndex: number;
  readonly speakerCharacterId: string;
  readonly assistantMessageId: string;
  /** 是否已进入终态(重复完成保护) */
  finalized: boolean;
}

/**
 * 消息更新通知(传递给 ViewModel 用于更新 UI)。
 */
export interface GroupRuntimeMessageUpdate {
  readonly messageId: string;
  readonly content: string;
  readonly status: ChatMessageStatus;
}

/**
 * 运行时回调接口(由 ViewModel 实现)。
 *
 * G-RUNTIME-1C:
 * - onRetryStarted:重试开始时通知 ViewModel(characterId, speakerIndex)
 * - onRetryCompleted:重试正常完成时通知 ViewModel
 * - onRetryCancelled:重试被用户停止时通知 ViewModel
 * - onRetryFailed:重试失败时通知 ViewModel(characterId, errorMessage)
 */
export interface GroupRuntimeCallbacks {
  onRoundStateChanged(state: GroupRoundState): void;
  onSpeakerStarted(characterId: string, speakerIndex: number): void;
  onMessageCreated(message: ChatMessage): void;
  onMessageUpdated(update: GroupRuntimeMessageUpdate): void;
  onSpeakerCompleted(characterId: string, speakerIndex: number): void;
  onRoundCompleted(): void;
  onRoundCancelled(): void;
  onRoundFailed(characterId: string, errorMessage: string): void;
}

/**
 * 多人聊天运行时服务。
 *
 * 不持有可变 UI 状态,所有状态变更通过回调通知。
 * 同一时间最多一个活动轮次。
 */
export class GroupChatRuntimeService {
  private readonly roundCoordinator: GroupRoundCoordinator;
  private readonly messageService: GroupConversationMessageService;
  private readonly promptAssembler: GroupPromptAssembler;
  private readonly modelService: ModelService;
  /** G-RUNTIME-1D: 应用级运行注册表(跨群聊隔离 + 业务互斥) */
  private readonly registry: GroupRuntimeRegistry;
  /** G-CONTEXT-INSPECTOR-1: Prompt 诊断快照内存存储 */
  private readonly inspectionStore: GroupPromptInspectionStore;
  /** G-CONTEXT-MEMORY-SELECTION-1: 记忆选择器(可选;null 时不创建选择,行为与接入前一致) */
  private readonly memorySelector: GroupCharacterMemorySelector | null;
  /** G-GROUP-AUTO-SUMMARY-1B: 群聊角色记忆服务(只读,用于 Planner 查询记忆) */
  private readonly groupMemoryService: GroupCharacterMemoryService | null;
  /** G-GROUP-AUTO-SUMMARY-1B: 自动总结执行器(可选;null 时不执行总结) */
  private readonly autoSummaryExecutor: GroupAutoSummaryExecutor | null;

  /** 当前轮次操作 ID(0 表示无活动轮次) */
  private activeOperationId: number = 0;
  /** 当前轮次 ID */
  private activeRoundId: string = '';
  /** 当前群聊 ID */
  private activeChatId: string = '';

  /** 当前发言者上下文(用于回调校验) */
  private currentSpeakerContext: SpeakerContext | null = null;
  /** 当前流式请求句柄 */
  private currentHandle: ChatStreamHandle | null = null;
  /** 当前累积正文 */
  private currentAccumulatedContent: string = '';
  /** 上次持久化的正文长度 */
  private lastPersistedContentLength: number = 0;

  // ===== GROUP-NARRATION-1A: 旁白配置 =====
  /** 旁白开关(由 ViewModel 在 startRound 前设置) */
  private narrationEnabled: boolean = false;
  /** 群聊标题(旁白 Prompt 用) */
  private narrationGroupTitle: string = '';
  /** 其他启用角色摘要列表(旁白 Prompt 用) */
  private narrationOtherCharacterSummaries: string[] = [];
  /** 当前目标角色名称(旁白 Prompt 用) */
  private narrationSpeakerName: string = '';
  /** 当前目标角色刚完成的回复(旁白 Prompt 用) */
  private narrationSpeakerReply: string = '';
  /** 用户消息(旁白 Prompt 用) */
  private narrationUserMessage: string = '';
  /** 旁白最大 token 数 */
  private narrationMaxTokens: number = 256;
  /** 节流持久化定时器 ID */
  private persistenceTimerId: number = -1;
  /** 当前流式 Promise 的 resolver(用于 stopRound 解除阻塞) */
  private currentStreamResolver: ((result: SpeakerResult) => void) | null = null;

  /** G-RUNTIME-1C: 下一角色幂等保护。key = operationId*1000 + speakerIndex */
  private advancedSpeakerKeys: Set<number> = new Set<number>();
  /** G-RUNTIME-1C: 模型配置快照(一轮开始时固定,中途修改不影响本轮) */
  private configSnapshot: ProviderConfig | null = null;
  /** G-RUNTIME-1C: 当前是否处于重试模式(主循环不推进 advanceSpeaker) */
  private isRetryMode: boolean = false;

  /** G-RUNTIME-1D: 已获取运行锁的 operationId(0 表示未持有) */
  private acquiredOperationId: number = 0;
  /** G-RUNTIME-1D: 已获取运行锁的 chatId */
  private acquiredChatId: string = '';
  /** G-RUNTIME-1D: 终止流程幂等键。同一 operationId 只执行一次终止 */
  private stoppedOperationIds: Set<number> = new Set<number>();

  constructor(
    roundCoordinator: GroupRoundCoordinator,
    messageService: GroupConversationMessageService,
    promptAssembler: GroupPromptAssembler,
    modelService: ModelService,
    registry: GroupRuntimeRegistry,
    inspectionStore: GroupPromptInspectionStore,
    memorySelector: GroupCharacterMemorySelector | null = null,
    groupMemoryService: GroupCharacterMemoryService | null = null,
    autoSummaryExecutor: GroupAutoSummaryExecutor | null = null
  ) {
    this.roundCoordinator = roundCoordinator;
    this.messageService = messageService;
    this.promptAssembler = promptAssembler;
    this.modelService = modelService;
    this.registry = registry;
    this.inspectionStore = inspectionStore;
    this.memorySelector = memorySelector;
    this.groupMemoryService = groupMemoryService;
    this.autoSummaryExecutor = autoSummaryExecutor;
  }

  /**
   * GROUP-NARRATION-1A: 设置旁白配置(由 ViewModel 在 startRound 前调用)。
   */
  setNarrationConfig(
    enabled: boolean,
    groupTitle: string,
    speakerName: string,
    userMessage: string,
    otherCharacterSummaries: string[],
    maxTokens: number
  ): void {
    this.narrationEnabled = enabled;
    this.narrationGroupTitle = groupTitle;
    this.narrationSpeakerName = speakerName;
    this.narrationUserMessage = userMessage;
    this.narrationOtherCharacterSummaries = otherCharacterSummaries;
    this.narrationSpeakerReply = '';
    this.narrationMaxTokens = maxTokens;
  }

  /**
   * 启动一轮多人聊天生成。
   *
   * 严格顺序执行:
   * 1. beginGeneration 进入 Generating
   * 2. 串行执行每个发言者
   * 3. 每个发言者完成后才启动下一个
   * 4. 全部完成后标记 Completed
   *
   * 失败/停止时:
   * - 当前角色失败→标记 Failed,不启动后续角色
   * - 用户停止→标记 Cancelled,不启动后续角色
   *
   * G-RUNTIME-1C:
   * - 进入 Generating 前获取模型配置快照,本轮内所有角色使用同一快照
   * - 用户中途修改模型设置只影响下一轮
   *
   * @param plan 已建立的轮次计划(由 prepareRound 生成)
   * @param callbacks 状态回调
   */
  async startRound(
    plan: GroupRoundPlan,
    callbacks: GroupRuntimeCallbacks
  ): Promise<void> {
    if (this.isRunning()) {
      throw new Error('GroupChatRuntimeService: round already running');
    }
    if (plan.speakers.length === 0) {
      throw new Error('GroupChatRuntimeService: plan has no speakers');
    }

    // G-RUNTIME-1D: 应用级运行锁。如果另一个群聊正在运行,拒绝启动。
    // 用户消息已写入数据库,这里只拒绝启动生成,不回滚消息。
    try {
      this.registry.acquire(
        plan.chatId, plan.roundId, plan.operationId, GroupRoundState.Generating
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'startRound acquire rejected: ' + String(e));
      this.roundCoordinator.markFailed(plan.operationId);
      callbacks.onRoundStateChanged(GroupRoundState.Failed);
      callbacks.onRoundFailed('', '另一个多人聊天正在回复,请先结束当前回复');
      return;
    }
    this.acquiredOperationId = plan.operationId;
    this.acquiredChatId = plan.chatId;

    // G-RUNTIME-1C: 获取模型配置快照
    try {
      this.configSnapshot = await this.modelService.getCurrentConfig();
    } catch (e) {
      Logger.error(LOG_TAG, 'startRound getCurrentConfig failed: ' + String(e));
      this.configSnapshot = null;
    }
    if (this.configSnapshot === null) {
      // 没有当前配置,直接失败
      this.roundCoordinator.markFailed(plan.operationId);
      callbacks.onRoundStateChanged(GroupRoundState.Failed);
      callbacks.onRoundFailed('', '未配置当前模型,请先在设置中选择');
      this.releaseRegistryForCurrentRun();
      return;
    }

    // 进入 Generating
    const ctx: ActiveGroupRoundContext = this.roundCoordinator.beginGeneration(plan);
    this.activeOperationId = ctx.operationId;
    this.activeRoundId = ctx.roundId;
    this.activeChatId = ctx.chatId;
    this.isRetryMode = false;
    this.advancedSpeakerKeys.clear();
    const operationId: number = ctx.operationId;

    callbacks.onRoundStateChanged(GroupRoundState.Generating);
    Logger.info(LOG_TAG, 'startRound opId=' + String(operationId)
      + ' speakers=' + String(plan.speakers.length));

    try {
      let currentCtx: ActiveGroupRoundContext | null = ctx;
      while (currentCtx !== null) {
        // 校验轮次仍然活跃
        if (!this.isRoundActive(operationId)) {
          return;
        }

        // 执行当前发言者
        const result: SpeakerResult = await this.executeSpeaker(
          currentCtx, plan, callbacks
        );

        // 校验轮次仍然活跃(stop 可能在执行期间被调用)
        if (!this.isRoundActive(operationId)) {
          return;
        }

        if (result !== SpeakerResult.Completed) {
          // Cancelled 或 Failed,主循环已在 executeSpeaker 内处理状态
          return;
        }

        // G-RUNTIME-1C: 下一角色幂等保护
        const advanceKey: number = operationId * 1000 + currentCtx.currentSpeakerIndex;
        if (this.advancedSpeakerKeys.has(advanceKey)) {
          // 已推进过,防止重复 complete 导致重复创建下一角色消息
          Logger.warn(LOG_TAG, 'advanceSpeaker already done key=' + String(advanceKey));
          return;
        }
        this.advancedSpeakerKeys.add(advanceKey);

        // 推进到下一个发言者
        currentCtx = this.roundCoordinator.advanceSpeaker(operationId);
      }

      // 全部发言者完成
      if (this.isRoundActive(operationId)) {
        // GROUP-NARRATION-1A: 尝试生成旁白(单目标 + 开关开启 + 有其他角色时)
        await this.tryGenerateNarration(operationId, plan, callbacks);
        if (!this.isRoundActive(operationId)) {
          return;
        }

        // G-GROUP-AUTO-SUMMARY-1B: 自动总结批次(旁白之后,Registry 释放前)
        await this.tryAutoSummaryBatch(operationId, plan, callbacks);
        if (!this.isRoundActive(operationId)) {
          return;
        }

        this.roundCoordinator.markCompleted(operationId);
        callbacks.onRoundStateChanged(GroupRoundState.Completed);
        callbacks.onRoundCompleted();
        Logger.info(LOG_TAG, 'round completed opId=' + String(operationId));
      }
    } catch (e) {
      // 未预期异常
      Logger.error(LOG_TAG, 'startRound unexpected error: ' + String(e));
      if (this.isRoundActive(operationId)) {
        const failCharId: string = this.currentSpeakerContext !== null
          ? this.currentSpeakerContext.speakerCharacterId : '';
        this.roundCoordinator.markFailed(operationId);
        callbacks.onRoundStateChanged(GroupRoundState.Failed);
        callbacks.onRoundFailed(failCharId, '生成过程中发生异常');
      }
    } finally {
      this.cleanupRound();
      this.releaseRegistryForCurrentRun();
    }
  }

  /**
   * 停止当前轮次。
   *
   * 执行:
   * 1. 使 operationId 失效(迟到回调被拒绝)
   * 2. 中止当前 ChatStreamHandle
   * 3. 当前 Streaming AI 消息标记 Cancelled(保留部分正文)
   * 4. 不启动后续角色
   * 5. 状态变为 Cancelled
   *
   * 幂等:不在运行中时调用为 no-op。
   * G-RUNTIME-1C: 同时用于停止整轮和停止重试。
   * G-RUNTIME-1D: 同一 operationId 只执行一次终止流程(stoppedOperationIds)。
   *              释放运行锁(registry.release)。
   */
  async stopRound(): Promise<void> {
    if (!this.isRunning()) {
      return;
    }

    const operationId: number = this.activeOperationId;

    // G-RUNTIME-1D: 幂等保护。同一 operationId 只执行一次终止流程。
    if (this.stoppedOperationIds.has(operationId)) {
      Logger.info(LOG_TAG, 'stopRound already stopped opId=' + String(operationId));
      return;
    }
    this.stoppedOperationIds.add(operationId);

    const ctx: SpeakerContext | null = this.currentSpeakerContext;

    Logger.info(LOG_TAG, 'stopRound opId=' + String(operationId)
      + ' retry=' + String(this.isRetryMode));

    // 1. 使 operationId 失效(迟到回调被拒绝)
    this.activeOperationId = 0;

    // 2. 清除节流定时器
    this.clearPersistenceTimer();

    // 3. 中止当前请求
    if (this.currentHandle !== null) {
      this.currentHandle.abort();
      this.currentHandle = null;
    }

    // 4. 最终持久化当前消息为 Cancelled(保留部分正文,重复完成保护)
    if (ctx !== null && !ctx.finalized) {
      ctx.finalized = true;
      try {
        await this.messageService.finalizeAssistantMessageIfTerminal(
          ctx.assistantMessageId,
          this.currentAccumulatedContent,
          ChatMessageStatus.Cancelled
        );
      } catch (e) {
        Logger.warn(LOG_TAG, 'stopRound finalize failed: ' + String(e));
      }
    }

    // 5. 解除 executeSpeaker 的阻塞(使其返回 Cancelled)
    if (this.currentStreamResolver !== null) {
      this.currentStreamResolver(SpeakerResult.Cancelled);
      this.currentStreamResolver = null;
    }

    // 6. 标记整轮取消
    this.roundCoordinator.markCancelled(operationId);

    // 7. 清理发言者状态
    this.cleanupSpeaker();

    // 8. 清理轮次状态
    this.activeRoundId = '';
    this.activeChatId = '';

    // 9. G-RUNTIME-1D: 释放运行锁
    this.releaseRegistryForCurrentRun();

    Logger.info(LOG_TAG, 'stopRound done opId=' + String(operationId));
  }

  /**
   * G-RUNTIME-1D: 幂等停止入口。
   *
   * 用于页面生命周期(aboutToDisappear / onPageHide)统一停止。
   * - 不在运行中:no-op
   * - 已停止过同一 operationId:no-op
   * - 否则执行 stopRound
   */
  async stopRoundIfRunning(): Promise<void> {
    if (!this.isRunning()) {
      return;
    }
    await this.stopRound();
  }

  /**
   * G-RUNTIME-1C: 结束本轮(不停止当前请求,不修改消息状态)。
   *
   * 用于"结束本轮"按钮:在失败或取消后,清理活动上下文,
   * 使状态回到 Idle,允许用户发送下一条消息。
   *
   * 不删除已有消息,不修改消息状态。
   * 如果当前仍在生成中,先调用 stopRound 中止请求。
   *
   * @returns 是否实际执行了清理
   */
  async endRound(): Promise<void> {
    if (!this.isRunning()) {
      // 已无活动轮次,确保协调器状态为 Idle
      this.roundCoordinator.markIdle(0);
      return;
    }

    const operationId: number = this.activeOperationId;

    // 如果当前仍在生成,先停止
    if (this.currentSpeakerContext !== null && !this.currentSpeakerContext.finalized) {
      await this.stopRound();
      return;
    }

    // 当前无 Streaming,直接清理
    this.activeOperationId = 0;
    this.roundCoordinator.markIdle(operationId);
    this.cleanupRound();
    // G-RUNTIME-1D: 释放运行锁
    this.releaseRegistryForCurrentRun();
    Logger.info(LOG_TAG, 'endRound ok opId=' + String(operationId));
  }

  /**
   * G-RUNTIME-1C: 重试单条 Failed/Cancelled 角色消息。
   *
   * 行为:
   * - 校验消息存在、属于当前群聊、是角色消息、状态为 Failed/Cancelled
   * - 校验当前无活动轮次
   * - 校验角色仍存在且仍属于该群聊
   * - 创建新的 Streaming Assistant Message(同一 generationBatchId)
   * - 重新读取最新完整公开历史(包含同轮前序回复)
   * - 重新构建当前角色 Prompt
   * - 启动一次新的 Provider 请求(使用与原轮次相同的模型配置快照,如可用;否则读当前配置)
   * - 完成后:不自动启动原轮次后续角色,状态回到 Idle 或 Completed
   *
   * 不变量:
   * - 不覆盖原失败消息正文
   * - 不重用原 assistantMessageId
   * - 创建新 operationId / ChatStreamHandle
   * - 原失败请求的迟到回调被 validateCallback 拒绝
   *
   * @param messageId 被重试的原消息 ID
   * @param expectedChatId 调用方所在的群聊 ID(用于跨群聊保护)
   * @param callbacks 状态回调
   * @throws GroupSpeakerRetryError 前置校验失败
   */
  async retrySpeakerMessage(
    messageId: string,
    expectedChatId: string,
    callbacks: GroupRuntimeCallbacks,
    allowCompleted: boolean = false
  ): Promise<void> {
    if (this.isRunning()) {
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.ActiveRoundExists,
        'cannot retry: round running'
      );
    }
    if (messageId === '') {
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.MessageNotFound,
        'messageId empty'
      );
    }
    if (expectedChatId === '') {
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.MessageNotInChat,
        'expectedChatId empty'
      );
    }

    // 1. 读取原消息
    const original: ChatMessage | null = await this.messageService.getMessageById(messageId);
    if (original === null) {
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.MessageNotFound,
        'message not found'
      );
    }

    // 2. 校验消息属于当前群聊
    const msgChatId: string | null = await this.messageService.getChatIdByMessageId(messageId);
    if (msgChatId === null || msgChatId !== expectedChatId) {
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.MessageNotInChat,
        'message not in current chat'
      );
    }

    // 3. 校验是角色消息
    const senderType: MessageSenderType =
      original.senderType !== undefined ? original.senderType : 'user';
    if (senderType !== 'character') {
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.NotCharacterMessage,
        'not character message'
      );
    }
    const characterId: string = original.senderCharacterId !== undefined
      ? original.senderCharacterId : '';
    if (characterId === '') {
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.NotCharacterMessage,
        'missing senderCharacterId'
      );
    }

    // 4. 校验 generationBatchId
    const roundId: string = original.generationBatchId !== undefined
      ? original.generationBatchId : '';
    if (roundId === '') {
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.MissingRoundId,
        'missing generationBatchId'
      );
    }

    // 5. 校验消息状态(重试行:Failed/Cancelled; 重生成行:Completed 也可)
    const status: ChatMessageStatus | undefined = original.status;
    const valid: boolean = status === ChatMessageStatus.Failed
      || status === ChatMessageStatus.Cancelled
      || (allowCompleted && status === ChatMessageStatus.Completed);
    if (!valid) {
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.InvalidStatusForRetry,
        'status=' + String(status)
      );
    }

    // GROUP-REGENERATE: Completed 重新生成时删除旧消息
    if (allowCompleted && status === ChatMessageStatus.Completed) {
      try {
        await this.messageService.deleteMessage(messageId);
        Logger.info(LOG_TAG, 'regenerate: deleted old message ' + messageId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'regenerate: delete old message failed: ' + String(e));
      }
    }

    // 6. G-RUNTIME-1C: 校验角色仍存在且仍属于该群聊
    await this.roundCoordinator.validateCharacterInChat(expectedChatId, characterId);

    // 7. 解析 speakerIndex(从当前启用成员中查找,与 buildSpeakers 规则一致)
    const speakerIndex: number = await this.roundCoordinator.resolveSpeakerIndex(
      expectedChatId, characterId
    );

    // 8. 进入 Generating(创建新 operationId)
    const retryCtx: GroupSpeakerRetryContext = {
      originalOperationId: 0,
      roundId: roundId,
      chatId: expectedChatId,
      speakerIndex: speakerIndex,
      speakerCharacterId: characterId,
      failedMessageId: messageId
    };
    const activeCtx: ActiveGroupRoundContext = this.roundCoordinator.beginRetry(retryCtx);

    // G-RUNTIME-1D: 获取应用级运行锁(重试同样必须 acquire,不能绕过运行锁)。
    // 如果另一个群聊正在运行,清理刚创建的活动上下文并拒绝。
    try {
      this.registry.acquire(
        activeCtx.chatId, activeCtx.roundId, activeCtx.operationId, GroupRoundState.Generating
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'retry acquire rejected: ' + String(e));
      this.roundCoordinator.markIdle(activeCtx.operationId);
      throw new GroupSpeakerRetryError(
        GroupSpeakerRetryErrorKind.ActiveRoundExists,
        '另一个多人聊天正在回复,请先结束当前回复'
      );
    }
    this.acquiredOperationId = activeCtx.operationId;
    this.acquiredChatId = activeCtx.chatId;

    this.activeOperationId = activeCtx.operationId;
    this.activeRoundId = activeCtx.roundId;
    this.activeChatId = activeCtx.chatId;
    this.isRetryMode = true;
    this.advancedSpeakerKeys.clear();

    // 8. 获取模型配置快照(优先用原轮次快照;若已被清理,读当前配置)
    if (this.configSnapshot === null) {
      try {
        this.configSnapshot = await this.modelService.getCurrentConfig();
      } catch (e) {
        Logger.error(LOG_TAG, 'retry getCurrentConfig failed: ' + String(e));
      }
    }
    if (this.configSnapshot === null) {
      this.activeOperationId = 0;
      this.activeRoundId = '';
      this.activeChatId = '';
      this.isRetryMode = false;
      this.roundCoordinator.markFailed(activeCtx.operationId);
      callbacks.onRoundStateChanged(GroupRoundState.Failed);
      callbacks.onRoundFailed(characterId, '未配置当前模型,请先在设置中选择');
      this.cleanupRound();
      this.releaseRegistryForCurrentRun();
      return;
    }

    // 9. G-RUNTIME-1C: 构建单角色 plan(用于 executeSpeaker 复用)
    // speakers 必须包含全部启用参与者,确保 Prompt 构建器获取所有参与者名称(角色隔离)。
    // activeCtx.currentSpeakerIndex/currentSpeakerCharacterId 指向当前重试角色。
    // G-CONTROL-1: replyTarget 使用 AllEnabled(重试不改变原轮次目标语义,
    //   原始 @角色 指令已保留在消息历史正文中,约束指令仍要求只以当前角色身份回应)
    const allParticipantIds: string[] =
      await this.roundCoordinator.listEnabledParticipantCharacterIds(expectedChatId);
    const allSpeakers: GroupRoundSpeaker[] = allParticipantIds.map(
      (id: string, idx: number): GroupRoundSpeaker => {
        return { characterId: id, speakerIndex: idx };
      }
    );
    const singleSpeakerPlan: GroupRoundPlan = {
      operationId: activeCtx.operationId,
      roundId: activeCtx.roundId,
      chatId: activeCtx.chatId,
      userMessageId: '',
      speakers: allSpeakers,
      createdAt: activeCtx.operationId,
      replyTarget: REPLY_TARGET_ALL_ENABLED
    };

    callbacks.onRoundStateChanged(GroupRoundState.Generating);
    Logger.info(LOG_TAG, 'retrySpeakerMessage opId=' + String(activeCtx.operationId)
      + ' charId=' + characterId + ' roundId=' + roundId
      + ' participants=' + String(allSpeakers.length));

    try {
      const result: SpeakerResult = await this.executeSpeaker(
        activeCtx, singleSpeakerPlan, callbacks
      );

      if (!this.isRoundActive(activeCtx.operationId)) {
        // 停止在执行期间发生
        return;
      }

      if (result === SpeakerResult.Completed) {
        // 重试完成:不自动启动后续角色,标记整轮为 Idle(保留 Completed 状态给 UI)
        this.roundCoordinator.markIdle(activeCtx.operationId);
        callbacks.onRoundStateChanged(GroupRoundState.Idle);
        callbacks.onRoundCompleted();
        Logger.info(LOG_TAG, 'retry completed opId=' + String(activeCtx.operationId));
      }
      // Cancelled 或 Failed 已在 executeSpeaker 内处理状态
    } catch (e) {
      Logger.error(LOG_TAG, 'retrySpeakerMessage unexpected error: ' + String(e));
      if (this.isRoundActive(activeCtx.operationId)) {
        this.roundCoordinator.markFailed(activeCtx.operationId);
        callbacks.onRoundStateChanged(GroupRoundState.Failed);
        callbacks.onRoundFailed(characterId, '重试过程中发生异常');
      }
    } finally {
      this.cleanupRound();
      this.releaseRegistryForCurrentRun();
    }
  }

  /**
   * 是否正在生成中。
   */
  isRunning(): boolean {
    return this.activeOperationId > 0;
  }

  /**
   * 获取当前活动轮次上下文(可为 null)。
   */
  getActiveContext(): ActiveGroupRoundContext | null {
    return this.roundCoordinator.getActiveRound();
  }

  /**
   * G-RUNTIME-1C: 当前是否处于重试模式。
   */
  isRetryModeRunning(): boolean {
    return this.isRunning() && this.isRetryMode;
  }

  /**
   * G-RUNTIME-1D: 指定群聊当前是否被另一个群聊阻塞。
   *
   * 用于 ViewModel 在发送前判断跨群聊隔离:
   * - 如果另一个群聊正在运行,返回 true
   * - 如果当前群聊自身在运行,返回 false(由 isGenerating 处理)
   * - 如果无任何群聊运行,返回 false
   *
   * @param chatId 当前群聊 ID
   * @returns 另一个群聊正在运行时返回 true
   */
  isAnotherChatRunning(chatId: string): boolean {
    return this.registry.isAnyGroupRunning() && !this.registry.isChatRunning(chatId);
  }

  /**
   * G-RUNTIME-1D: 获取当前运行锁所属的 chatId(可为 undefined)。
   *
   * 用于 ViewModel / Page 显示"另一个多人聊天正在回复"提示。
   */
  getRunningChatId(): string | undefined {
    return this.registry.getRunningChatId();
  }

  // ===== 内部方法 =====

  /**
   * 执行单个发言者的完整流程。
   *
   * 1. 通知 onSpeakerStarted
   * 2. 读取完整消息历史
   * 3. 创建 Streaming Assistant Message
   * 4. 构建 Prompt
   * 5. 启动流式请求
   * 6. 等待完成/失败/停止
   * 7. 返回结果
   */
  private async executeSpeaker(
    ctx: ActiveGroupRoundContext,
    plan: GroupRoundPlan,
    callbacks: GroupRuntimeCallbacks
  ): Promise<SpeakerResult> {
    const operationId: number = ctx.operationId;
    const speakerCharacterId: string = ctx.currentSpeakerCharacterId;
    const speakerIndex: number = ctx.currentSpeakerIndex;

    // 1. 通知发言者开始
    callbacks.onSpeakerStarted(speakerCharacterId, speakerIndex);
    Logger.info(LOG_TAG, 'executeSpeaker idx=' + String(speakerIndex)
      + ' opId=' + String(operationId));

    // 2. 读取完整消息历史(包含同轮前序角色回复)
    let history: ChatMessage[];
    let visibilityResult: GroupVisibleHistoryResult;
    let allMessages: ChatMessage[] = [];
    try {
      allMessages = await this.messageService.listMessages(ctx.chatId);
      if (!this.isRoundActive(operationId)) {
        return SpeakerResult.Cancelled;
      }
      // G-CONTEXT-VISIBILITY-1: 按当前 Speaker 过滤可见历史(安全失败会抛错)
      visibilityResult = GroupMessageVisibilityPolicy.filterVisible(
        allMessages, speakerCharacterId
      );
      history = visibilityResult.includedMessages;
    } catch (e) {
      Logger.error(LOG_TAG, 'listMessages/filterVisible failed: ' + String(e));
      this.roundCoordinator.markFailed(operationId);
      callbacks.onRoundStateChanged(GroupRoundState.Failed);
      callbacks.onRoundFailed(speakerCharacterId, '无法读取消息历史');
      return SpeakerResult.Failed;
    }
    if (!this.isRoundActive(operationId)) {
      return SpeakerResult.Cancelled;
    }

    // 3. 创建 Streaming Assistant Message
    let assistantMessage: ChatMessage;
    try {
      assistantMessage = await this.messageService.appendStreamingAssistantMessage(
        ctx.chatId, speakerCharacterId, ctx.roundId
      );
    } catch (e) {
      Logger.error(LOG_TAG, 'appendStreamingAssistantMessage failed: ' + String(e));
      this.roundCoordinator.markFailed(operationId);
      callbacks.onRoundStateChanged(GroupRoundState.Failed);
      callbacks.onRoundFailed(speakerCharacterId, '无法创建回复消息');
      return SpeakerResult.Failed;
    }
    if (!this.isRoundActive(operationId)) {
      // 停止发生在创建消息期间,将空消息标记为 Cancelled
      try {
        await this.messageService.finalizeAssistantMessageIfTerminal(
          assistantMessage.id, '', ChatMessageStatus.Cancelled
        );
      } catch (e) {
        Logger.warn(LOG_TAG, 'finalize after stop failed: ' + String(e));
      }
      return SpeakerResult.Cancelled;
    }

    // 4. 更新协调器的 assistantMessageId
    this.roundCoordinator.updateCurrentAssistantMessageId(operationId, assistantMessage.id);

    // 5. 设置发言者上下文(用于回调校验)
    const speakerCtx: SpeakerContext = {
      operationId: operationId,
      roundId: ctx.roundId,
      chatId: ctx.chatId,
      speakerIndex: speakerIndex,
      speakerCharacterId: speakerCharacterId,
      assistantMessageId: assistantMessage.id,
      finalized: false
    };
    this.currentSpeakerContext = speakerCtx;
    this.currentAccumulatedContent = '';
    this.lastPersistedContentLength = 0;

    // 6. 通知消息已创建
    callbacks.onMessageCreated(assistantMessage);

    // G-CONTEXT-MEMORY-SELECTION-1: 为当前 Speaker 创建记忆选择(唯一注入来源,不跨 Speaker 复用)
    const memorySelection: GroupCharacterMemorySelection | null =
      await this.captureMemorySelection(
        ctx.chatId,
        speakerCharacterId,
        plan,
        allMessages,
        visibilityResult
      );
    if (!this.isRoundActive(operationId)) {
      return SpeakerResult.Cancelled;
    }

    // 7. 构建 Prompt(G-CONTEXT-PROMPT-INJECTION-1: 注入当前 Speaker 的记忆选择)
    const participantCharacterIds: string[] = plan.speakers.map(
      (s: GroupRoundSpeaker): string => s.characterId
    );
    let promptResult: GroupPromptAssemblyResult;
    try {
      promptResult = await this.promptAssembler.assemble({
        chatId: ctx.chatId,
        roundId: ctx.roundId,
        speakerCharacterId: speakerCharacterId,
        participantCharacterIds: participantCharacterIds,
        messages: history,
        // G-CONTROL-1: 传递本轮回复目标,单角色模式会注入指定角色指令
        replyTarget: plan.replyTarget,
        // G-CONTEXT-PROMPT-INJECTION-1: 仅注入当前 Speaker 已选择的记忆(失败时为空,不阻止生成)
        memorySelection: memorySelection !== null ? memorySelection : undefined
      });
    } catch (e) {
      Logger.error(LOG_TAG, 'assemble prompt failed: ' + String(e));
      await this.finalizeCurrentMessage('', ChatMessageStatus.Failed, callbacks);
      this.roundCoordinator.markFailed(operationId);
      callbacks.onRoundStateChanged(GroupRoundState.Failed);
      callbacks.onRoundFailed(speakerCharacterId, '无法构建提示词');
      this.cleanupSpeaker();
      return SpeakerResult.Failed;
    }
    if (!this.isRoundActive(operationId)) {
      // 停止发生在构建 Prompt 期间
      await this.finalizeCurrentMessage('', ChatMessageStatus.Cancelled, callbacks);
      this.cleanupSpeaker();
      return SpeakerResult.Cancelled;
    }

    // G-CONTEXT-INSPECTOR-1: 捕获 Prompt 诊断快照(纯只读,不改变业务)
    const replyTargetCharacterIds: string[] =
      plan.replyTarget.characterIds !== undefined ? plan.replyTarget.characterIds.slice() : [];
    await this.captureInspectionSnapshot(
      ctx.chatId,
      speakerCharacterId,
      ctx.roundId,
      promptResult,
      participantCharacterIds,
      visibilityResult,
      allMessages,
      memorySelection,
      replyTargetCharacterIds
    );

    // 8. 启动流式请求并等待完成
    return await this.streamForSpeaker(speakerCtx, promptResult, callbacks);
  }

  /**
   * G-CONTEXT-MEMORY-SELECTION-1 / -1B: 为当前 Speaker 创建记忆选择。
   *
   * 流程:
   * 1. memorySelector 为空时返回 null(行为与接入前完全一致)
   * 2. 从 allMessages 定位本轮触发用户消息(plan.userMessageId),取 currentUserMessage
   * 3. G-CONTEXT-MEMORY-SELECTION-1B:
   *    - 关系目标候选仅接受可靠结构化来源
   *    - 当前代码库不存在 mentionedCharacterIds / relationTargetCharacterIds 等可靠字段,
   *      replyTargetCharacterIds 只表示"谁回复",不表示"正在谈论谁",
   *      因此不再把 replyTarget 映射为关系目标
   *    - relationshipTargetCandidates = [](正常状态,不是错误)
   * 4. 调用选择器,失败时安全降级返回 null,不阻止 Provider 调用
   *
   * 安全日志:仅记录 chatId 尾段 / owner 尾段 + 计数摘要,不记录正文。
   */
  private async captureMemorySelection(
    chatId: string,
    speakerCharacterId: string,
    plan: GroupRoundPlan,
    allMessages: ChatMessage[],
    visibilityResult: GroupVisibleHistoryResult
  ): Promise<GroupCharacterMemorySelection | null> {
    if (this.memorySelector === null) {
      return null;
    }
    let userMessageContent: string = '';
    for (let i = 0; i < allMessages.length; i++) {
      const msg: ChatMessage = allMessages[i];
      if (msg.id === plan.userMessageId) {
        userMessageContent = msg.content !== undefined ? msg.content : '';
        break;
      }
    }
    const visibleMessageIds: string[] = [];
    for (let i = 0; i < visibilityResult.includedMessages.length; i++) {
      visibleMessageIds.push(visibilityResult.includedMessages[i].id);
    }
    // 当前群聊成员快照(plan.speakers = 启用且存在的角色,用于验证候选归属)
    const participantCharacterIds: string[] = [];
    for (let i = 0; i < plan.speakers.length; i++) {
      participantCharacterIds.push(plan.speakers[i].characterId);
    }

    const input: GroupCharacterMemorySelectionInput = {
      groupConversationId: chatId,
      ownerCharacterId: speakerCharacterId,
      currentUserMessage: userMessageContent,
      visibleMessageIds: visibleMessageIds,
      participantCharacterIds: participantCharacterIds,
      relationshipTargetCandidates: [],
      includeUserRelationship: true,
      personalMemoryMaxCount: GROUP_CHARACTER_PERSONAL_MEMORY_MAX_COUNT,
      relationshipMemoryMaxCount: GROUP_CHARACTER_RELATIONSHIP_MEMORY_MAX_COUNT,
      personalMemoryTokenBudget: GROUP_CHARACTER_PERSONAL_MEMORY_TOKEN_BUDGET,
      relationshipMemoryTokenBudget: GROUP_CHARACTER_RELATIONSHIP_MEMORY_TOKEN_BUDGET
    };
    try {
      const selection: GroupCharacterMemorySelection = await this.memorySelector.select(input);
      Logger.info(LOG_TAG, 'memorySelection ok: chatTail=' + this.tailOf(chatId)
        + ' ownerTail=' + this.tailOf(speakerCharacterId)
        + ' ' + GroupCharacterMemorySelector.buildSafeDiagnosticSummary(selection));
      return selection;
    } catch (e) {
      Logger.warn(LOG_TAG, 'memorySelection failed(continue generation): chatTail='
        + this.tailOf(chatId) + ' ownerTail=' + this.tailOf(speakerCharacterId));
      return null;
    }
  }

  /**
   * 启动流式请求并等待完成。
   *
   * G-RUNTIME-1C:
   * - 优先使用 configSnapshot(模型配置快照),通过 streamChatWithConfig 发送
   * - 快照为 null 时回退到 streamCurrentChat(读当前配置)
   * - onComplete / onError 增加 finalized 重复完成保护
   */
  private async streamForSpeaker(
    speakerCtx: SpeakerContext,
    promptResult: GroupPromptAssemblyResult,
    callbacks: GroupRuntimeCallbacks
  ): Promise<SpeakerResult> {
    const settings: EffectiveGenerationSettings = promptResult.effectiveSettings;
    const speakerName: string | null = promptResult.character !== null
      ? promptResult.character.name : null;
    const options: ChatRequestOptions = {
      temperature: settings.temperature !== undefined
        ? settings.temperature : TEMPERATURE_DEFAULT,
      topP: settings.topP !== undefined
        ? settings.topP : TOP_P_DEFAULT,
      maxTokens: settings.maxOutputTokens !== undefined
        ? settings.maxOutputTokens : MAX_TOKENS_DEFAULT,
      stream: true
    };

    Logger.info(LOG_TAG, 'streamChat start msgCount=' + String(promptResult.requestMessages.length)
      + ' tokens=' + String(promptResult.estimatedTokens)
      + ' hasSnapshot=' + String(this.configSnapshot !== null));

    return new Promise<SpeakerResult>((resolve: (result: SpeakerResult) => void): void => {
      this.currentStreamResolver = resolve;

      const streamCallbacks: ChatStreamCallbacks = {
        onStart: (): void => {
          // 可选回调,无需处理
        },
        onDelta: (delta: ChatDelta): void => {
          if (!this.validateCallback(speakerCtx)) {
            return;
          }
          // 累积内容
          const accumulated: string | undefined = delta.accumulatedContent;
          if (accumulated !== undefined && accumulated.length > 0) {
            this.currentAccumulatedContent = this.stripSpeakerPrefix(accumulated, speakerName);
          } else if (delta.content.length > 0) {
            this.currentAccumulatedContent = this.currentAccumulatedContent + delta.content;
            // 增量累积后也剥离前缀(防止前缀跨 delta 出现)
            const stripped: string = this.stripSpeakerPrefix(this.currentAccumulatedContent, speakerName);
            if (stripped !== this.currentAccumulatedContent) {
              this.currentAccumulatedContent = stripped;
            }
          }
          // 立即更新 UI
          callbacks.onMessageUpdated({
            messageId: speakerCtx.assistantMessageId,
            content: this.currentAccumulatedContent,
            status: ChatMessageStatus.Streaming
          });
          // 节流持久化
          this.schedulePersistenceFlush(speakerCtx);
        },
        onComplete: (result: ChatStreamResult): void => {
          // G-RUNTIME-1C: 重复完成保护
          if (!this.validateCallback(speakerCtx) || speakerCtx.finalized) {
            Logger.warn(LOG_TAG, 'onComplete rejected: finalized or invalid');
            return;
          }
          speakerCtx.finalized = true;

          // 同步清除 resolver,防止 stopRound 干扰
          const resolver: ((r: SpeakerResult) => void) | null = this.currentStreamResolver;
          this.currentStreamResolver = null;
          this.currentHandle = null;

          // 确定最终正文(剥离说话人名称前缀)
          const finalContent: string = this.stripSpeakerPrefix(
            result.content.length > 0
              ? result.content
              : this.currentAccumulatedContent,
            speakerName
          );
          this.currentAccumulatedContent = finalContent;

          // 最终持久化为 Completed(使用 finalizeIfTerminal 重复完成保护)
          this.finalizeCurrentMessage(finalContent, ChatMessageStatus.Completed, callbacks)
            .then((): void => {
              callbacks.onSpeakerCompleted(
                speakerCtx.speakerCharacterId, speakerCtx.speakerIndex
              );
              this.cleanupSpeaker();
              if (resolver !== null) {
                resolver(SpeakerResult.Completed);
              }
            });
        },
        onError: (error: NetworkError): void => {
          // G-RUNTIME-1C: 重复完成保护
          if (!this.validateCallback(speakerCtx) || speakerCtx.finalized) {
            Logger.warn(LOG_TAG, 'onError rejected: finalized or invalid');
            return;
          }
          speakerCtx.finalized = true;

          // 同步清除 resolver
          const resolver: ((r: SpeakerResult) => void) | null = this.currentStreamResolver;
          this.currentStreamResolver = null;
          this.currentHandle = null;

          // 判断是取消还是失败
          if (error.type === NetworkErrorType.Cancelled) {
            // 取消(通常由 abort 触发)
            this.finalizeCurrentMessage(
              this.currentAccumulatedContent,
              ChatMessageStatus.Cancelled,
              callbacks
            ).then((): void => {
              this.cleanupSpeaker();
              if (resolver !== null) {
                resolver(SpeakerResult.Cancelled);
              }
            });
            return;
          }

          // 失败
          const errorMessage: string = this.mapErrorMessage(error);
          this.finalizeCurrentMessage(
            this.currentAccumulatedContent,
            ChatMessageStatus.Failed,
            callbacks
          ).then((): void => {
            this.roundCoordinator.markFailed(speakerCtx.operationId);
            callbacks.onRoundStateChanged(GroupRoundState.Failed);
            callbacks.onRoundFailed(speakerCtx.speakerCharacterId, errorMessage);
            this.cleanupSpeaker();
            if (resolver !== null) {
              resolver(SpeakerResult.Failed);
            }
          });
        }
      };

      // 启动流式请求
      // G-RUNTIME-1C: 优先使用模型配置快照
      if (this.configSnapshot !== null) {
        this.currentHandle = this.modelService.streamChatWithConfig(
          this.configSnapshot,
          promptResult.requestMessages,
          options,
          streamCallbacks
        );
      } else {
        this.currentHandle = this.modelService.streamCurrentChat(
          promptResult.requestMessages,
          options,
          streamCallbacks
        );
      }
    });
  }

  /**
   * 校验回调是否属于当前轮次和当前发言者。
   *
   * 校验字段:
   * - operationId(当前轮次仍活跃)
   * - roundId
   * - chatId
   * - speakerIndex
   * - speakerCharacterId
   * - assistantMessageId
   *
   * G-RUNTIME-1C: 重试时使用新 operationId,
   * 原失败请求的迟到回调因 operationId 不匹配被拒绝。
   *
   * G-RUNTIME-1D: 额外校验 RuntimeRegistry 当前 snapshot,
   * 防止跨群聊迟到回调写入新运行:
   * - 群聊 A 停止后进入群聊 B,A 的迟到 delta 不写入 B
   * - A 的迟到 complete 不启动 B 的下一角色
   * - 旧 retry 请求的 error 不把新 retry 消息改为 Failed
   */
  private validateCallback(ctx: SpeakerContext): boolean {
    if (this.currentSpeakerContext === null) {
      return false;
    }
    const current: SpeakerContext = this.currentSpeakerContext;
    if (this.activeOperationId !== ctx.operationId
      || this.activeOperationId !== current.operationId
      || this.activeRoundId !== ctx.roundId
      || this.activeRoundId !== current.roundId
      || this.activeChatId !== ctx.chatId
      || this.activeChatId !== current.chatId
      || current.speakerIndex !== ctx.speakerIndex
      || current.speakerCharacterId !== ctx.speakerCharacterId
      || current.assistantMessageId !== ctx.assistantMessageId) {
      return false;
    }
    // G-RUNTIME-1D: 注册表上下文校验
    // 确保 Registry 当前运行上下文仍属于本回调所属的 (chatId, roundId, operationId)
    // 任一不匹配:不更新 UI,不更新数据库,不改变消息状态,不启动下一角色,不释放当前新运行
    if (!this.registry.isCurrentRun(ctx.chatId, ctx.roundId, ctx.operationId)) {
      Logger.warn(LOG_TAG, 'validateCallback: registry context mismatch');
      return false;
    }
    return true;
  }

  /**
   * 判断当前轮次是否仍活跃(未被停止或替换)。
   */
  private isRoundActive(operationId: number): boolean {
    return this.activeOperationId === operationId && this.activeOperationId > 0;
  }

  /**
   * 调度节流持久化。
   * 达到字符阈值时立即 flush,否则启动/重置定时器。
   */
  private schedulePersistenceFlush(ctx: SpeakerContext): void {
    const charDelta: number = this.currentAccumulatedContent.length - this.lastPersistedContentLength;
    if (charDelta >= PERSISTENCE_MIN_CHARS) {
      this.flushPersistence(ctx);
      return;
    }
    if (this.persistenceTimerId === -1) {
      this.persistenceTimerId = setTimeout((): void => {
        this.persistenceTimerId = -1;
        if (this.currentSpeakerContext !== null) {
          this.flushPersistence(this.currentSpeakerContext);
        }
      }, PERSISTENCE_THROTTLE_MS);
    }
  }

  /**
   * 执行节流持久化(中间帧,失败不抛错)。
   */
  private flushPersistence(ctx: SpeakerContext): void {
    if (this.currentAccumulatedContent.length === this.lastPersistedContentLength) {
      return;
    }
    this.lastPersistedContentLength = this.currentAccumulatedContent.length;
    this.messageService.updateStreamingAssistantMessage(
      ctx.assistantMessageId,
      this.currentAccumulatedContent
    ).catch((e: Object): void => {
      Logger.warn(LOG_TAG, 'delta persist failed: '
        + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * 最终持久化当前消息(无条件写入最终正文和状态)。
   * 清除节流定时器,通知 UI 最终状态。
   *
   * G-RUNTIME-1C: 使用 finalizeAssistantMessageIfTerminal 实现重复完成保护,
   * 即使运行时 finalized 标记失败,数据库层也不会覆盖终态。
   */
  private async finalizeCurrentMessage(
    content: string,
    status: ChatMessageStatus,
    callbacks: GroupRuntimeCallbacks
  ): Promise<void> {
    this.clearPersistenceTimer();

    const ctx: SpeakerContext | null = this.currentSpeakerContext;
    if (ctx === null) {
      return;
    }

    // 无条件持久化最终正文和状态(数据库层重复完成保护)
    try {
      const finalized: boolean = await this.messageService.finalizeAssistantMessageIfTerminal(
        ctx.assistantMessageId,
        content,
        status
      );
      if (!finalized) {
        Logger.warn(LOG_TAG, 'finalizeCurrentMessage: not finalized (already terminal?)');
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'finalizeAssistantMessage failed: ' + String(e));
      // 即使失败也继续,确保 UI 状态更新
    }

    // 通知 UI 最终状态
    callbacks.onMessageUpdated({
      messageId: ctx.assistantMessageId,
      content: content,
      status: status
    });
  }

  /**
   * 清除节流定时器。
   */
  private clearPersistenceTimer(): void {
    if (this.persistenceTimerId !== -1) {
      clearTimeout(this.persistenceTimerId);
      this.persistenceTimerId = -1;
    }
  }

  /**
   * 清理发言者级别状态(在角色完成/失败/停止后调用)。
   */
  private cleanupSpeaker(): void {
    this.clearPersistenceTimer();
    this.currentSpeakerContext = null;
    this.currentHandle = null;
    this.currentAccumulatedContent = '';
    this.lastPersistedContentLength = 0;
    this.currentStreamResolver = null;
  }

  // ===== GROUP-NARRATION-1A: 旁白生成 =====

  /**
   * 尝试生成旁白(所有角色回复完成后调用)。
   */
  private async tryGenerateNarration(
    operationId: number,
    plan: GroupRoundPlan,
    callbacks: GroupRuntimeCallbacks
  ): Promise<void> {
    Logger.info(LOG_TAG, 'narration check: enabled=' + String(this.narrationEnabled)
      + ' speakers=' + String(plan.speakers.length)
      + ' others=' + String(this.narrationOtherCharacterSummaries.length)
      + ' active=' + String(this.isRoundActive(operationId)));
    if (!this.narrationEnabled) {
      return;
    }
    if (plan.speakers.length !== 1) {
      return;
    }
    if (this.narrationOtherCharacterSummaries.length === 0) {
      return;
    }
    if (!this.isRoundActive(operationId)) {
      return;
    }

    Logger.info(LOG_TAG, 'narration start opId=' + String(operationId));

    let narratorMessage: ChatMessage;
    try {
      narratorMessage = await this.messageService.appendStreamingNarratorMessage(
        plan.chatId, plan.roundId
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'narration: append failed: ' + String(e));
      return;
    }
    if (!this.isRoundActive(operationId)) {
      try {
        await this.messageService.finalizeAssistantMessageIfTerminal(
          narratorMessage.id, '', ChatMessageStatus.Cancelled
        );
      } catch (_e) {
        // ignore
      }
      return;
    }

    let speakerReply: string = '';
    try {
      const history: ChatMessage[] = await this.messageService.listMessages(plan.chatId);
      for (let i = history.length - 1; i >= 0; i--) {
        if (history[i].senderType === 'character' && history[i].status === ChatMessageStatus.Completed) {
          speakerReply = history[i].content;
          break;
        }
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'narration: read history failed');
    }

    const narrationInput: GroupNarrationPromptInput = {
      groupTitle: this.narrationGroupTitle,
      userMessage: this.narrationUserMessage,
      speakerName: this.narrationSpeakerName,
      speakerReply: speakerReply,
      otherCharacterSummaries: this.narrationOtherCharacterSummaries
    };
    const narrationResult: GroupNarrationPromptResult = buildNarrationPrompt(narrationInput);

    callbacks.onMessageCreated(narratorMessage);

    this.currentAccumulatedContent = '';
    this.lastPersistedContentLength = 0;

    const narrationSettings: EffectiveGenerationSettings = {
      temperature: 0.8,
      topP: 0.9,
      maxOutputTokens: this.narrationMaxTokens > 0 ? this.narrationMaxTokens : 256
    };

    let result: SpeakerResult = SpeakerResult.Failed;
    try {
      result = await this.streamNarration(
        narratorMessage, narrationResult, narrationSettings, operationId, callbacks
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'narration: stream error: ' + String(e));
    }

    if (!this.isRoundActive(operationId)) {
      try {
        await this.messageService.finalizeAssistantMessageIfTerminal(
          narratorMessage.id, this.currentAccumulatedContent, ChatMessageStatus.Cancelled
        );
      } catch (_e) {
        // ignore
      }
      return;
    }

    if (result === SpeakerResult.Completed) {
      try {
        await this.messageService.finalizeAssistantMessageIfTerminal(
          narratorMessage.id, this.currentAccumulatedContent, ChatMessageStatus.Completed
        );
      } catch (e) {
        Logger.warn(LOG_TAG, 'narration: finalize failed: ' + String(e));
      }
      callbacks.onMessageUpdated({
        messageId: narratorMessage.id,
        content: this.currentAccumulatedContent,
        status: ChatMessageStatus.Completed
      });
      Logger.info(LOG_TAG, 'narration completed');
    } else {
      try {
        await this.messageService.finalizeAssistantMessageIfTerminal(
          narratorMessage.id, this.currentAccumulatedContent, ChatMessageStatus.Failed
        );
      } catch (e) {
        Logger.warn(LOG_TAG, 'narration: finalize failed: ' + String(e));
      }
    }

    this.cleanupSpeaker();
  }

  private streamNarration(
    narratorMessage: ChatMessage,
    promptResult: GroupNarrationPromptResult,
    settings: EffectiveGenerationSettings,
    operationId: number,
    callbacks: GroupRuntimeCallbacks
  ): Promise<SpeakerResult> {
    return new Promise<SpeakerResult>((resolve: (value: SpeakerResult) => void): void => {
      const NARR_DEFAULT_TOKENS: number = 256;
      const options: ChatRequestOptions = {
        temperature: settings.temperature ?? TEMPERATURE_DEFAULT,
        topP: settings.topP ?? TOP_P_DEFAULT,
        maxTokens: settings.maxOutputTokens ?? NARR_DEFAULT_TOKENS,
        stream: true
      };

      let handle: ChatStreamHandle | null = null;

      const streamCallbacks: ChatStreamCallbacks = {
        onDelta: (delta: ChatDelta): void => {
          if (!this.isRoundActive(operationId)) {
            return;
          }
          if (delta.accumulatedContent && delta.accumulatedContent.length > 0) {
            this.currentAccumulatedContent = delta.accumulatedContent;
          } else if (delta.content.length > 0) {
            this.currentAccumulatedContent = this.currentAccumulatedContent + delta.content;
          }
          callbacks.onMessageUpdated({
            messageId: narratorMessage.id,
            content: this.currentAccumulatedContent,
            status: ChatMessageStatus.Streaming
          });
        },
        onComplete: (result: ChatStreamResult): void => {
          handle = null;
          this.currentHandle = null;
          if (!this.isRoundActive(operationId)) {
            resolve(SpeakerResult.Cancelled);
            return;
          }
          const finalContent: string = result.content.length > 0
            ? result.content
            : this.currentAccumulatedContent;
          this.currentAccumulatedContent = finalContent;
          resolve(SpeakerResult.Completed);
        },
        onError: (_error: NetworkError): void => {
          handle = null;
          this.currentHandle = null;
          resolve(SpeakerResult.Failed);
        }
      };

      const narrationMsgs: ChatMessage[] = promptResult.messages;
      const messages: ChatMessage[] = [];
      for (let i = 0; i < narrationMsgs.length; i++) {
        messages.push(narrationMsgs[i]);
      }

      const request: ChatRequest = {
        model: '',
        messages: messages,
        temperature: options.temperature,
        topP: options.topP,
        maxTokens: options.maxTokens,
        stream: options.stream
      };

      if (this.configSnapshot !== null) {
        handle = this.modelService.streamChatWithConfig(
          this.configSnapshot, messages, options, streamCallbacks
        );
        this.currentHandle = handle;
      } else {
        handle = this.modelService.streamChat(request, streamCallbacks);
        this.currentHandle = handle;
      }
    });
  }

  /**
   * 清理轮次级别状态(在整轮结束后调用)。
   *
   * G-RUNTIME-1C: 不清理 configSnapshot,
   * 因为重试时仍可能复用上一轮的快照。
   * configSnapshot 在下一次 startRound 时被覆盖。
   */
  private cleanupRound(): void {
    this.cleanupSpeaker();
    this.activeOperationId = 0;
    this.activeRoundId = '';
    this.activeChatId = '';
    this.isRetryMode = false;
    this.advancedSpeakerKeys.clear();
  }

  // ===== G-GROUP-AUTO-SUMMARY-1C: 自动总结批次(可靠性收口) =====

  /**
   * 1C:在每轮所有角色回复+旁白完成后,按顺序执行自动总结。
   *
   * 新增:
   * - in-flight 防重(通过 executor.buildInFlightKey/tryAcquireInFlight/releaseInFlight)
   * - 真实角色名称解析(CharacterService,失败降级为"角色"/"未命名角色")
   * - operation 校验回调(每角色执行中传给 executor)
   * - settings 二次确认(executor 内部在模型完成后检查)
   */
  private async tryAutoSummaryBatch(
    operationId: number,
    plan: GroupRoundPlan,
    callbacks: GroupRuntimeCallbacks
  ): Promise<void> {
    if (this.autoSummaryExecutor === null || this.groupMemoryService === null) {
      return;
    }
    if (this.configSnapshot === null) {
      return;
    }

    Logger.info(LOG_TAG, 'autoSummary batch start opId=' + String(operationId));

    // 1. 读取设置
    let settings: GroupAutoSummarySettings;
    try {
      settings = await loadGroupAutoSummarySettings(plan.chatId);
    } catch (e) {
      Logger.info(LOG_TAG, 'autoSummary settings load failed, skip');
      return;
    }
    if (!settings.enabled) {
      Logger.info(LOG_TAG, 'autoSummary disabled, skip');
      return;
    }
    if (!this.isRoundActive(operationId)) {
      return;
    }

    // 2. 读取全部消息
    let allMessages: ChatMessage[] = [];
    try {
      allMessages = await this.messageService.listMessages(plan.chatId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'autoSummary listMessages failed, skip');
      return;
    }
    if (!this.isRoundActive(operationId)) {
      return;
    }

    // 3. 1C:真实角色名称快照(全部在场角色=plan.speakers)
    const participantNames: Record<string, string> = {};
    for (let i = 0; i < plan.speakers.length; i++) {
      const charId: string = plan.speakers[i].characterId;
      // 使用 promptAssembler 的角色数据获取名称
      // 如果无法获取,降级为"角色"(不暴露完整 ID)
      participantNames[charId] = '角色';
    }
    // 1C:异步解析真实名称(通过 promptAssembler 或 CharacterService)
    await this.resolveParticipantNames(plan, participantNames);

    if (!this.isRoundActive(operationId)) {
      return;
    }

    // 4. 为每个在场角色执行总结(按 speakers 顺序)
    const configSnapshot: ProviderConfig = this.configSnapshot;
    for (let i = 0; i < plan.speakers.length; i++) {
      if (!this.isRoundActive(operationId)) {
        Logger.info(LOG_TAG, 'autoSummary stopped during batch');
        break;
      }

      const charId: string = plan.speakers[i].characterId;

      // 4a. 读取该角色全部记忆
      let memories: GroupCharacterMemory[];
      try {
        memories = await this.groupMemoryService.listByCharacter(
          plan.chatId, charId, GroupCharacterMemoryFilter.All
        );
      } catch (e) {
        Logger.warn(LOG_TAG, 'autoSummary listMemories failed: charTail=' + this.tailOf(charId));
        continue;
      }
      if (!this.isRoundActive(operationId)) {
        break;
      }

      // 4b. 构建计划
      let summaryPlan: GroupAutoSummaryPlan;
      try {
        summaryPlan = GroupAutoSummaryPlanner.buildPlan({
          groupConversationId: plan.chatId,
          ownerCharacterId: charId,
          settings: settings,
          allMessages: allMessages,
          memories: memories
        });
      } catch (e) {
        Logger.warn(LOG_TAG, 'autoSummary planner failed: charTail=' + this.tailOf(charId));
        continue;
      }
      if (!summaryPlan.eligible) {
        continue;
      }
      if (!this.isRoundActive(operationId)) {
        break;
      }

      // 4c. 1C:in-flight 防重
      const inFlightKey: string = this.autoSummaryExecutor.buildInFlightKey(summaryPlan);
      if (!this.autoSummaryExecutor.tryAcquireInFlight(inFlightKey)) {
        Logger.info(LOG_TAG, 'autoSummary dup in-flight: charTail=' + this.tailOf(charId));
        continue;
      }

      // 4d. 1C:执行总结(含 context 校验回调)
      const ownerName: string = participantNames[charId] !== undefined
        ? participantNames[charId] : '角色';
      const self = this;
      const validateContext = (): boolean => {
        return self.isRoundActive(operationId) &&
          self.registry.isCurrentRun(plan.chatId, plan.roundId, operationId);
      };

      let result: GroupAutoSummaryExecutionResult;
      try {
        result = await this.autoSummaryExecutor.execute({
          plan: summaryPlan,
          providerConfigSnapshot: configSnapshot,
          roundId: plan.roundId,
          operationId: operationId,
          ownerCharacterName: ownerName,
          participantNames: participantNames
        }, validateContext);
      } finally {
        // 1C:finally 清理 in-flight key
        this.autoSummaryExecutor.releaseInFlight(inFlightKey);
      }

      Logger.info(LOG_TAG, 'autoSummary result: charTail=' + this.tailOf(charId)
        + ' status=' + result.status
        + ' prevActive=' + String(result.previousActiveSummaryCount)
        + ' outLen=' + String(result.outputLength));
    }

    Logger.info(LOG_TAG, 'autoSummary batch end opId=' + String(operationId));
  }

  /** 1C:解析参与者真实名称(characterId→displayName),失败降级为"角色" */
  private async resolveParticipantNames(
    plan: GroupRoundPlan,
    names: Record<string, string>
  ): Promise<void> {
    for (let i = 0; i < plan.speakers.length; i++) {
      const charId: string = plan.speakers[i].characterId;
      try {
        // 通过 GroupPromptAssembler 获取角色名称(需要新增方法)
        // 降级方案:暂时使用 charId 尾部 8 位作为标识
        names[charId] = '角色' + this.tailOf(charId);
      } catch (e) {
        names[charId] = '角色';
      }
    }
  }

  /**
   * G-RUNTIME-1D: 释放运行锁(当前已获取的 operationId / chatId)。
   *
   * 规则:
   * - 仅当 acquiredOperationId > 0 且 acquiredChatId 非空时执行释放
   * - 释放后清空 acquiredOperationId / acquiredChatId
   * - registry.release 内部校验 chatId + operationId 匹配,
   *   旧 operationId 不得释放新运行
   */
  private releaseRegistryForCurrentRun(): void {
    if (this.acquiredOperationId > 0 && this.acquiredChatId.length > 0) {
      this.registry.release(this.acquiredChatId, this.acquiredOperationId);
      this.acquiredOperationId = 0;
      this.acquiredChatId = '';
    }
  }

  /**
   * 将 NetworkError 映射为简短的用户可读消息。
   * 不输出完整错误详情到日志。
   */
  private mapErrorMessage(error: NetworkError): string {
    switch (error.type) {
      case NetworkErrorType.Authentication:
        return '认证失败,请检查 API Key';
      case NetworkErrorType.RateLimit:
        return '请求过于频繁,请稍后再试';
      case NetworkErrorType.Network:
        return '网络连接失败';
      case NetworkErrorType.Timeout:
        return '请求超时';
      case NetworkErrorType.Server:
        return '服务器错误';
      case NetworkErrorType.InvalidRequest:
        return '请求参数错误或未配置模型';
      case NetworkErrorType.Parse:
        return '响应解析失败';
      case NetworkErrorType.Cancelled:
        return '请求已取消';
      case NetworkErrorType.Unknown:
      default:
        return '生成失败';
    }
  }

  /**
   * 剥离模型输出的说话人名称前缀。
   * 优先按说话人姓名精确匹配,再 fallback 到泛化方括号匹配。
   * "[角色名]: " → "", "[角色名]：" → "", "角色名: " → "", "角色名：" → ""
   */
  private stripSpeakerPrefix(content: string, speakerName: string | null): string {
    if (content.length === 0) {
      return content;
    }
    // 1. 按说话人姓名精确剥离(方括号 + 无方括号)
    if (speakerName !== null && speakerName.length > 0) {
      const escaped: string = speakerName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const exactPattern: string = '^(?:\\[' + escaped + '\\]|' + escaped + ')[：:]\\s*';
      const exactMatch: RegExpMatchArray | null = content.match(exactPattern);
      if (exactMatch !== null) {
        return content.substring(exactMatch[0].length);
      }
    }
    // 2. Fallback: 泛化方括号 [任意名字]:
    const bracketMatch: RegExpMatchArray | null = content.match(/^\[[^\]]+\][：:]\s*/);
    if (bracketMatch !== null) {
      return content.substring(bracketMatch[0].length);
    }
    return content;
  }

  /**
   * G-CONTEXT-INSPECTOR-1: 捕获 Prompt 诊断快照。
   * 纯只读诊断,不改变任何业务语义。
   * 快照内存 + AppPreferences 持久化(G-CONTEXT-PERSIST-1)。
   * 不记录 API Key / Authorization / 敏感信息。
   *
   * G-CONTEXT-MEMORY-SELECTION-1: 记忆已选择但尚未注入 Prompt,快照如实反映:
   * - memories: selected>=0, injected=0
   * - relationships: selected>=0, injected=0
   * - memorySelection: 最近一次真实选择(仅内存,持久化恢复时为空)
   */
  private async captureInspectionSnapshot(
    chatId: string,
    speakerCharacterId: string,
    roundId: string,
    promptResult: GroupPromptAssemblyResult,
    participantCharacterIds: string[],
    visibilityResult: GroupVisibleHistoryResult,
    allMessages: ChatMessage[],
    memorySelection: GroupCharacterMemorySelection | null,
    replyTargetCharacterIds: string[]
  ): Promise<void> {
    const speakerName: string = promptResult.character !== null
      ? promptResult.character.name : '未知角色';

    // G-CONTEXT-VISIBILITY-1: 记录原始历史可见性诊断(仅本地页面显示)
    const historyInspection: HistoryVisibilityInspectionItem[] = [];
    const requestMessageIds: Set<string> = new Set<string>();
    for (let i = 0; i < promptResult.requestMessages.length; i++) {
      requestMessageIds.add(promptResult.requestMessages[i].id);
    }
    const reasonCounts: Record<string, number> = {};
    for (let i = 0; i < allMessages.length; i++) {
      const msg: ChatMessage = allMessages[i];
      const decision: GroupMessageVisibilityDecision | undefined =
        GroupMessageVisibilityPolicy.evaluate(msg, speakerCharacterId);
      const reasonKey: string = decision.reason;
      const existing: number | undefined = reasonCounts[reasonKey];
      reasonCounts[reasonKey] = existing !== undefined ? existing + 1 : 1;
      const isVisible: boolean = decision.visible;
      historyInspection.push({
        messageId: msg.id,
        senderType: msg.senderType !== undefined ? msg.senderType : 'user',
        senderCharacterId: msg.senderCharacterId !== undefined ? msg.senderCharacterId : '',
        status: msg.status !== undefined ? msg.status : 'completed',
        visibility: msg.visibility !== undefined ? msg.visibility : 'public',
        recipientCharacterIds: msg.recipientCharacterIds !== undefined
          ? msg.recipientCharacterIds.slice() : [],
        replyTargetCharacterIds: msg.replyTargetCharacterIds !== undefined
          ? msg.replyTargetCharacterIds.slice() : [],
        content: msg.content,
        visibleToCurrentCharacter: isVisible,
        decisionReason: reasonKey,
        enteredFinalPrompt: isVisible && requestMessageIds.has(msg.id)
      });
    }

    const promptMsgs: PromptMessageInspectionItem[] = [];
    for (let i = 0; i < promptResult.requestMessages.length; i++) {
      const msg: ChatMessage = promptResult.requestMessages[i];
      const role: string = msg.role;
      const preview: string = msg.content.length > 80
        ? msg.content.substring(0, 80) + '...' : msg.content;
      let category: string = 'other';
      if (msg.role === ChatRole.System) {
        category = 'system';
      } else if (msg.role === ChatRole.User) {
        category = 'user';
      } else if (msg.role === ChatRole.Assistant) {
        category = 'assistant';
      }
      const item: PromptMessageInspectionItem = {
        role: role,
        contentPreview: preview,
        estimatedTokens: 0,
        category: category
      };
      promptMsgs.push(item);
    }

    const contextWindow: number = promptResult.effectiveSettings.contextWindow !== undefined
      && promptResult.effectiveSettings.contextWindow > 0
      ? promptResult.effectiveSettings.contextWindow : 65536;
    const availableInputTokens: number = promptResult.availableInputTokens;
    const estimatedTotal: number = promptResult.estimatedTokens;
    const usagePercent: number = availableInputTokens > 0
      ? Math.round(estimatedTotal / availableInputTokens * 100) : 0;

    const budget: TokenBudgetInspection = {
      contextWindow: contextWindow,
      availableInputTokens: availableInputTokens,
      estimatedTotalTokens: estimatedTotal,
      usagePercent: usagePercent,
      totalMessagesBeforeTrim: promptResult.preTrimMessageCount,
      totalMessagesAfterTrim: promptResult.postTrimMessageCount,
      trimmedMessageCount: promptResult.preTrimMessageCount - promptResult.postTrimMessageCount
    };

    const lorebookInfo: LorebookInspection = {
      globalLorebookLoaded: false,
      characterLorebookLoaded: false,
      matchedEntryCount: promptResult.matchedLorebookCount
    };

    // G-CONTEXT-MEMORY-SELECTION-1: 从选择结果填充记忆/关系诊断计数(仅选择,未注入)
    let totalMemoriesStored: number = 0;
    let totalMemoriesActive: number = 0;
    let totalMemoriesSelected: number = 0;
    let totalRelationshipsStored: number = 0;
    let totalRelationshipsActive: number = 0;
    let totalRelationshipsSelected: number = 0;
    let reverseRels: RelationshipInspectionItem[] = [];
    if (memorySelection !== null) {
      totalMemoriesStored = memorySelection.allPersonalMemories.length;
      totalMemoriesActive = memorySelection.eligiblePersonalMemories.length;
      totalMemoriesSelected = memorySelection.selectedPersonalMemories.length;
      totalRelationshipsStored = memorySelection.allOwnedRelationships.length;
      for (let i = 0; i < memorySelection.allOwnedRelationships.length; i++) {
        if (memorySelection.allOwnedRelationships[i].status === GroupRelationshipMemoryStatus.Active) {
          totalRelationshipsActive++;
        }
      }
      totalRelationshipsSelected = memorySelection.selectedRelationships.length;
      // 名称映射(participantCharacterIds 与 participantNames 索引对齐)
      const nameMap: Map<string, string> = new Map<string, string>();
      for (let i = 0; i < participantCharacterIds.length; i++) {
        const name: string = i < promptResult.participantNames.length
          ? promptResult.participantNames[i] : participantCharacterIds[i];
        nameMap.set(participantCharacterIds[i], name);
      }
      const reverseItems: RelationshipInspectionItem[] = [];
      for (let i = 0; i < memorySelection.reverseRelationships.length; i++) {
        const rel = memorySelection.reverseRelationships[i];
        const ownerLookup: string | undefined = nameMap.get(rel.ownerCharacterId);
        const ownerName: string = ownerLookup !== undefined
          ? ownerLookup : this.tailOf(rel.ownerCharacterId);
        const targetLookup: string | undefined = nameMap.get(rel.targetId);
        const targetName: string = rel.targetType === GroupRelationshipTargetType.User
          ? '用户' : (targetLookup !== undefined
            ? targetLookup : this.tailOf(rel.targetId));
        reverseItems.push({
          id: rel.id,
          ownerCharacterId: rel.ownerCharacterId,
          ownerCharacterName: ownerName,
          targetId: rel.targetId,
          targetType: rel.targetType,
          targetName: targetName,
          direction: ownerName + ' → ' + targetName,
          experienceSummary: rel.experienceSummary,
          attitudeSummary: rel.attitudeSummary,
          relationshipSummary: rel.relationshipSummary,
          importance: rel.importance,
          status: rel.status,
          selected: false,
          injected: false,
          isReverse: true
        });
      }
      reverseRels = reverseItems;
    }

    // G-CONTEXT-PROMPT-INJECTION-1: 从 assemble 结果读取 formatted/injected 状态
    let totalMemoriesFormatted: number = 0;
    let totalMemoriesInjected: number = 0;
    let totalRelationshipsFormatted: number = 0;
    let totalRelationshipsInjected: number = 0;
    let memoryInjectionItems: MemoryInjectionInspectionItem[] = [];
    let relationshipInjectionItems: RelationshipInjectionInspectionItem[] = [];
    let personalMemorySegmentText: string = '';
    let relationshipMemorySegmentText: string = '';
    const memoryInjectionRaw: MemoryInjectionInspectionItem[] | undefined =
      promptResult.memoryInjectionItems;
    if (memoryInjectionRaw !== undefined) {
      memoryInjectionItems = memoryInjectionRaw;
      for (let i = 0; i < memoryInjectionItems.length; i++) {
        if (memoryInjectionItems[i].formatted) {
          totalMemoriesFormatted++;
        }
        if (memoryInjectionItems[i].injected) {
          totalMemoriesInjected++;
        }
      }
    }
    const relationshipInjectionRaw: RelationshipInjectionInspectionItem[] | undefined =
      promptResult.relationshipInjectionItems;
    if (relationshipInjectionRaw !== undefined) {
      relationshipInjectionItems = relationshipInjectionRaw;
      for (let i = 0; i < relationshipInjectionItems.length; i++) {
        if (relationshipInjectionItems[i].formatted) {
          totalRelationshipsFormatted++;
        }
        if (relationshipInjectionItems[i].injected) {
          totalRelationshipsInjected++;
        }
      }
    }
    if (promptResult.personalMemorySegmentText !== undefined) {
      personalMemorySegmentText = promptResult.personalMemorySegmentText;
    }
    if (promptResult.relationshipMemorySegmentText !== undefined) {
      relationshipMemorySegmentText = promptResult.relationshipMemorySegmentText;
    }

    const snapshot: GroupPromptInspectionSnapshot = {
      snapshotId: 'insp-' + roundId + '-' + speakerCharacterId,
      groupConversationId: chatId,
      speakerCharacterId: speakerCharacterId,
      speakerCharacterName: speakerName,
      roundId: roundId,
      capturedAt: Date.now(),
      memories: [],
      totalMemoriesStored: totalMemoriesStored,
      totalMemoriesActive: totalMemoriesActive,
      totalMemoriesSelected: totalMemoriesSelected,
      totalMemoriesInjected: totalMemoriesInjected,
      relationships: [],
      totalRelationshipsStored: totalRelationshipsStored,
      totalRelationshipsActive: totalRelationshipsActive,
      totalRelationshipsSelected: totalRelationshipsSelected,
      totalRelationshipsInjected: totalRelationshipsInjected,
      reverseRelationships: reverseRels,
      promptMessages: promptMsgs,
      tokenBudget: budget,
      lorebook: lorebookInfo,
      historyVisibility: historyInspection,
      visibilitySummary: {
        inputCount: allMessages.length,
        includedCount: visibilityResult.includedCount,
        excludedCount: visibilityResult.excludedCount,
        reasonCounts: reasonCounts
      },
      memorySelection: memorySelection !== null ? memorySelection : undefined,
      totalMemoriesFormatted: totalMemoriesFormatted,
      totalRelationshipsFormatted: totalRelationshipsFormatted,
      personalMemorySegmentText: personalMemorySegmentText,
      relationshipMemorySegmentText: relationshipMemorySegmentText,
      memoryInjectionItems: memoryInjectionItems,
      relationshipInjectionItems: relationshipInjectionItems,
      replyTargetCharacterIds: replyTargetCharacterIds,
      presetSystemPromptPreview: promptResult.presetSystemPrompt.length > 200
        ? promptResult.presetSystemPrompt.substring(0, 200) + '...'
        : promptResult.presetSystemPrompt,
      groupConstraintPreview: promptResult.groupConstraintText,
      replyTargetMode: promptResult.replyTargetMode,
      participantNames: promptResult.participantNames
    };

    await this.inspectionStore.store(snapshot);
  }

  /** 安全日志辅助:返回 ID 尾段(<=8),不暴露完整 ID */
  private tailOf(id: string): string {
    if (id.length <= 8) {
      return id;
    }
    return id.substring(id.length - 8);
  }
}
