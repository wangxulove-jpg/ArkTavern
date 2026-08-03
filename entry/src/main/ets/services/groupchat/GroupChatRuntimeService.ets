/**
 * GroupChatRuntimeService 多人聊天运行时服务(G-RUNTIME-1B)
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

import { ChatMessage, ChatMessageStatus } from '../../models/ChatMessage';
import { ChatStreamCallbacks, ChatStreamHandle, ChatDelta, ChatStreamResult } from '../../models/ChatStreamTypes';
import { NetworkError, NetworkErrorType } from '../../models/NetworkError';
import { ChatRequestOptions } from '../../models/ChatRequest';
import { TEMPERATURE_DEFAULT, TOP_P_DEFAULT, MAX_TOKENS_DEFAULT } from '../../models/ProviderConfig';
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
  ActiveGroupRoundContext
} from './GroupRoundTypes';
import { EffectiveGenerationSettings } from '../PromptPresetRuntimeResolver';

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
 */
interface SpeakerContext {
  readonly operationId: number;
  readonly roundId: string;
  readonly chatId: string;
  readonly speakerIndex: number;
  readonly speakerCharacterId: string;
  readonly assistantMessageId: string;
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
  /** 节流持久化定时器 ID */
  private persistenceTimerId: number = -1;
  /** 当前流式 Promise 的 resolver(用于 stopRound 解除阻塞) */
  private currentStreamResolver: ((result: SpeakerResult) => void) | null = null;

  constructor(
    roundCoordinator: GroupRoundCoordinator,
    messageService: GroupConversationMessageService,
    promptAssembler: GroupPromptAssembler,
    modelService: ModelService
  ) {
    this.roundCoordinator = roundCoordinator;
    this.messageService = messageService;
    this.promptAssembler = promptAssembler;
    this.modelService = modelService;
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

    // 进入 Generating
    const ctx: ActiveGroupRoundContext = this.roundCoordinator.beginGeneration(plan);
    this.activeOperationId = ctx.operationId;
    this.activeRoundId = ctx.roundId;
    this.activeChatId = ctx.chatId;
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

        // 推进到下一个发言者
        currentCtx = this.roundCoordinator.advanceSpeaker(operationId);
      }

      // 全部发言者完成
      if (this.isRoundActive(operationId)) {
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
   */
  async stopRound(): Promise<void> {
    if (!this.isRunning()) {
      return;
    }

    const operationId: number = this.activeOperationId;
    const ctx: SpeakerContext | null = this.currentSpeakerContext;

    Logger.info(LOG_TAG, 'stopRound opId=' + String(operationId));

    // 1. 使 operationId 失效(迟到回调被拒绝)
    this.activeOperationId = 0;

    // 2. 清除节流定时器
    this.clearPersistenceTimer();

    // 3. 中止当前请求
    if (this.currentHandle !== null) {
      this.currentHandle.abort();
      this.currentHandle = null;
    }

    // 4. 最终持久化当前消息为 Cancelled(保留部分正文)
    if (ctx !== null) {
      try {
        await this.messageService.finalizeAssistantMessage(
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

    Logger.info(LOG_TAG, 'stopRound done opId=' + String(operationId));
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
    try {
      history = await this.messageService.listMessages(ctx.chatId);
    } catch (e) {
      Logger.error(LOG_TAG, 'listMessages failed: ' + String(e));
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
        await this.messageService.finalizeAssistantMessage(
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
      assistantMessageId: assistantMessage.id
    };
    this.currentSpeakerContext = speakerCtx;
    this.currentAccumulatedContent = '';
    this.lastPersistedContentLength = 0;

    // 6. 通知消息已创建
    callbacks.onMessageCreated(assistantMessage);

    // 7. 构建 Prompt
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
        messages: history
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

    // 8. 启动流式请求并等待完成
    return await this.streamForSpeaker(speakerCtx, promptResult, callbacks);
  }

  /**
   * 启动流式请求并等待完成。
   */
  private async streamForSpeaker(
    speakerCtx: SpeakerContext,
    promptResult: GroupPromptAssemblyResult,
    callbacks: GroupRuntimeCallbacks
  ): Promise<SpeakerResult> {
    const settings: EffectiveGenerationSettings = promptResult.effectiveSettings;
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
      + ' tokens=' + String(promptResult.estimatedTokens));

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
            this.currentAccumulatedContent = accumulated;
          } else if (delta.content.length > 0) {
            this.currentAccumulatedContent = this.currentAccumulatedContent + delta.content;
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
          if (!this.validateCallback(speakerCtx)) {
            return;
          }
          // 同步清除 resolver,防止 stopRound 干扰
          const resolver: ((r: SpeakerResult) => void) | null = this.currentStreamResolver;
          this.currentStreamResolver = null;
          this.currentHandle = null;

          // 确定最终正文
          const finalContent: string = result.content.length > 0
            ? result.content
            : this.currentAccumulatedContent;
          this.currentAccumulatedContent = finalContent;

          // 最终持久化为 Completed
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
          if (!this.validateCallback(speakerCtx)) {
            return;
          }
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
      this.currentHandle = this.modelService.streamCurrentChat(
        promptResult.requestMessages,
        options,
        streamCallbacks
      );
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
   */
  private validateCallback(ctx: SpeakerContext): boolean {
    if (this.currentSpeakerContext === null) {
      return false;
    }
    const current: SpeakerContext = this.currentSpeakerContext;
    return this.activeOperationId === ctx.operationId
      && this.activeOperationId === current.operationId
      && this.activeRoundId === ctx.roundId
      && this.activeRoundId === current.roundId
      && this.activeChatId === ctx.chatId
      && this.activeChatId === current.chatId
      && current.speakerIndex === ctx.speakerIndex
      && current.speakerCharacterId === ctx.speakerCharacterId
      && current.assistantMessageId === ctx.assistantMessageId;
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

    // 无条件持久化最终正文和状态
    try {
      await this.messageService.finalizeAssistantMessage(
        ctx.assistantMessageId,
        content,
        status
      );
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

  /**
   * 清理轮次级别状态(在整轮结束后调用)。
   */
  private cleanupRound(): void {
    this.cleanupSpeaker();
    this.activeOperationId = 0;
    this.activeRoundId = '';
    this.activeChatId = '';
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
}
