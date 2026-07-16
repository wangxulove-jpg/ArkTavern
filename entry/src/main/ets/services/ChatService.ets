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
import { ChatMessage, ChatMessageStatus, createChatMessage } from '../models/ChatMessage';
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
import { Character, buildCharacterSystemContent } from '../models/Character';
import { Lorebook } from '../models/Lorebook';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatService';

/** 启动阶段超时(毫秒),收到首个 onStart/onDelta/onComplete/onError 后清除 */
const START_TIMEOUT_MS: number = 15000;

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
  /** 当前角色(用于 PromptBuilder 构建) */
  private character: Character | null = null;
  /** 最近一次使用的回调(用于 stopGeneration/clearConversation 通知状态) */
  private lastCallbacks: ChatServiceCallbacks | null = null;

  constructor(
    modelService: ModelService,
    lorebookService: LorebookService | null = null,
    promptBuilder: PromptBuilder | null = null
  ) {
    this.modelService = modelService;
    this.lorebookService = lorebookService;
    this.promptBuilder = promptBuilder;
  }

  /**
   * 初始化角色聊天上下文。
   * 有角色时:
   * - 注入 System 消息(角色 systemPrompt 或组合 prompt)
   * - 注入 firstMessage 作为 Assistant 开场消息
   * 无角色时:不做任何初始化。
   * 只在消息列表为空时生效,防止重复注入。
   *
   * @returns 是否添加了 firstMessage(用于通知页面显示开场白)
   */
  initContext(character: Character | null): boolean {
    this.character = character;
    if (this.messages.length > 0) {
      return false;
    }
    if (character === null) {
      return false;
    }
    Logger.info(LOG_TAG, 'initContext character=' + character.name);

    const systemContent: string = buildCharacterSystemContent(character);
    const newMessages: ChatMessage[] = [];

    if (systemContent.length > 0) {
      const systemMsg: ChatMessage = createChatMessage(
        'msg-' + generateUuid(), ChatRole.System, systemContent, Date.now()
      );
      newMessages.push(systemMsg);
    }

    if (character.firstMessage.length > 0) {
      const firstMsg: ChatMessage = {
        id: 'msg-' + generateUuid(),
        role: ChatRole.Assistant,
        content: character.firstMessage,
        createdAt: Date.now(),
        isStreaming: false,
        status: ChatMessageStatus.Completed
      };
      newMessages.push(firstMsg);
    }

    this.messages = newMessages;
    return character.firstMessage.length > 0;
  }

  /**
   * 发送用户消息并开始流式生成。
   * 顺序:校验 → 创建 User 消息 → 创建 Assistant 占位 → 通知 → 启动网络。
   * 即使网络启动失败,页面也必须看到 User 消息和 Failed 状态的 Assistant 气泡。
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
    const userMsg: ChatMessage = createChatMessage(
      'msg-' + generateUuid(), ChatRole.User, userContent, Date.now()
    );
    this.messages = [...this.messages, userMsg];
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 2. 创建空 Assistant 占位消息
    const assistantId: string = 'msg-' + generateUuid();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming
    };
    this.messages = [...this.messages, assistantMsg];
    this.currentAssistantId = assistantId;
    this.emitMessages(callbacks);

    // 3. 启动网络请求(失败也保留消息)
    this.doStream(assistantId, callbacks);
  }

  /**
   * 重新生成最后一条 Assistant 回复。
   * 找到最后一个 User 消息,删除其后的 Assistant 消息,重新请求。
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

    // 删除 User 之后的所有消息(创建新数组)
    this.messages = this.messages.slice(0, lastUserIdx + 1);
    this.emitMessages(callbacks);

    // 创建空 Assistant 占位消息
    const assistantId: string = 'msg-' + generateUuid();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming
    };
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
      // 将当前 Assistant 消息标记为已取消(创建新对象和新数组)
      this.markAssistant(this.currentAssistantId, ChatMessageStatus.Cancelled, undefined, undefined);
      this.emitMessages(this.lastCallbacks);
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
   * 释放资源,停止当前请求。dispose 后不可复用。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.clearStartTimer();
    if (this.currentHandle !== null) {
      this.currentHandle.abort();
      this.currentHandle = null;
    }
    this.messages = [];
    this.currentAssistantId = null;
    this.lastCallbacks = null;
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
      },
      onComplete: (result: ChatStreamResult): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        if (this.state !== ChatState.Streaming && this.state !== ChatState.Sending) {
          return;
        }
        const finalStatus: ChatMessageStatus = this.finalizeAssistant(
          assistantId, result.content, ChatMessageStatus.Completed, undefined, callbacks
        );
        this.currentAssistantId = null;
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
        this.finalizeAssistant(assistantId, '', ChatMessageStatus.Failed, error.message, callbacks);
        this.currentAssistantId = null;
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError(error.message);
        Logger.info(LOG_TAG, 'stream failed: ' + error.message);
      }
    };

    // 启动超时保护
    this.startStartTimer(assistantId, callbacks);

    // 构建请求消息(通过 PromptBuilder 统一构建)
    const requestMessages: ChatMessage[] = await this.buildRequestMessages();

    try {
      this.currentHandle = this.modelService.streamCurrentChat(requestMessages, DEFAULT_OPTIONS, streamCallbacks);
      this.setState(ChatState.Streaming, callbacks);
    } catch (e) {
      this.clearStartTimer();
      this.finalizeAssistant(assistantId, '', ChatMessageStatus.Failed, String(e), callbacks);
      this.currentAssistantId = null;
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

    const context: PromptBuildContext = {
      character: this.character !== null ? this.character : undefined,
      lorebook: lorebook,
      messages: this.messages
    };

    const result: PromptBuildResult = this.promptBuilder.build(context);
    Logger.info(LOG_TAG, 'buildRequestMessages: segments=' + result.messages.length.toString()
      + ' lorebook=' + result.matchedLorebookEntryIds.length.toString());
    return result.messages;
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
          status: status
        };
      }
      return msg;
    });
  }
}
