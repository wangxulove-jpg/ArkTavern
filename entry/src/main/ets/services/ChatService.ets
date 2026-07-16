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
 *
 * 状态机:Idle → Sending → Streaming → Completed/Cancelled/Failed
 * - Completed/Cancelled/Failed 为终态,不可再转换
 * - 迟到回调(delta/complete/error)在终态后忽略
 */

import { ModelService } from './ModelService';
import { ChatMessage, createChatMessage } from '../models/ChatMessage';
import { ChatRequest } from '../models/ChatRequest';
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
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatService';

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

/**
 * 聊天服务。
 */
export class ChatService {
  private messages: ChatMessage[] = [];
  private state: ChatState = ChatState.Idle;
  private currentHandle: ChatStreamHandle | null = null;
  private disposed: boolean = false;
  private readonly modelService: ModelService;

  constructor(modelService: ModelService) {
    this.modelService = modelService;
  }

  /**
   * 发送用户消息并开始流式生成。
   */
  async sendMessage(userContent: string, callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (userContent.trim().length === 0) {
      return;
    }
    if (this.state !== ChatState.Idle && this.state !== ChatState.Completed
      && this.state !== ChatState.Cancelled && this.state !== ChatState.Failed) {
      return;
    }

    Logger.info(LOG_TAG, 'sendMessage start');

    // 创建用户消息
    const userMsg: ChatMessage = createChatMessage(
      'msg-' + generateUuid(), ChatRole.User, userContent, Date.now()
    );
    this.messages.push(userMsg);
    this.setState(ChatState.Sending, callbacks);
    callbacks.onMessagesChanged(this.messages.slice());

    // 创建空 Assistant 占位消息
    const assistantId: string = 'msg-' + generateUuid();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true
    };
    this.messages.push(assistantMsg);
    callbacks.onMessagesChanged(this.messages.slice());

    const request: ChatRequest = {
      model: '__from_config__',
      messages: this.messages.slice(),
      temperature: 0.7,
      topP: 1.0,
      maxTokens: 1024,
      stream: true
    };

    const streamCallbacks: ChatStreamCallbacks = {
      onDelta: (delta: ChatDelta): void => {
        if (this.disposed || this.state !== ChatState.Streaming) {
          return;
        }
        this.appendDelta(assistantId, delta.content, callbacks);
      },
      onComplete: (result: ChatStreamResult): void => {
        if (this.disposed) {
          return;
        }
        this.finalizeAssistant(assistantId, result.content, false, undefined, callbacks);
        this.setState(ChatState.Completed, callbacks);
        Logger.info(LOG_TAG, 'sendMessage completed');
      },
      onError: (error: NetworkError): void => {
        if (this.disposed) {
          return;
        }
        if (this.state === ChatState.Cancelled) {
          return;
        }
        this.finalizeAssistant(assistantId, '', false, error.message, callbacks);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError(error.message);
        Logger.info(LOG_TAG, 'sendMessage failed: ' + error.message);
      }
    };

    try {
      this.currentHandle = this.modelService.streamChat(request, streamCallbacks);
      this.setState(ChatState.Streaming, callbacks);
    } catch (e) {
      this.finalizeAssistant(assistantId, '', false, String(e), callbacks);
      this.setState(ChatState.Failed, callbacks);
      callbacks.onError(String(e));
    }
  }

  /**
   * 停止当前生成。
   * 保留已生成文本,标记为已停止。
   */
  stopGeneration(): void {
    if (this.currentHandle !== null) {
      Logger.info(LOG_TAG, 'stopGeneration');
      this.currentHandle.abort();
      this.currentHandle = null;
    }
    if (this.state === ChatState.Sending || this.state === ChatState.Streaming) {
      this.setState(ChatState.Cancelled, null);
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
    this.setState(ChatState.Idle, null);
    Logger.info(LOG_TAG, 'clearConversation');
  }

  /**
   * 获取当前消息列表(副本)。
   */
  getMessages(): ChatMessage[] {
    return this.messages.slice();
  }

  /**
   * 释放资源,停止当前请求。
   */
  dispose(): void {
    this.disposed = true;
    if (this.currentHandle !== null) {
      this.currentHandle.abort();
      this.currentHandle = null;
    }
    this.messages = [];
    this.state = ChatState.Idle;
    Logger.info(LOG_TAG, 'dispose');
  }

  // ===== 内部方法 =====

  private setState(state: ChatState, callbacks: ChatServiceCallbacks | null): void {
    if (this.state === state) {
      return;
    }
    this.state = state;
    if (callbacks !== null) {
      callbacks.onStateChanged(state);
    }
  }

  private appendDelta(assistantId: string, delta: string, callbacks: ChatServiceCallbacks): void {
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].id === assistantId) {
        const updated: ChatMessage = {
          id: this.messages[i].id,
          role: this.messages[i].role,
          content: this.messages[i].content + delta,
          createdAt: this.messages[i].createdAt,
          updatedAt: Date.now(),
          isStreaming: true
        };
        this.messages[i] = updated;
        callbacks.onMessagesChanged(this.messages.slice());
        return;
      }
    }
  }

  private finalizeAssistant(
    assistantId: string,
    content: string,
    streaming: boolean,
    errorMessage: string | undefined,
    callbacks: ChatServiceCallbacks
  ): void {
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].id === assistantId) {
        const finalContent: string = content.length > 0 ? content : this.messages[i].content;
        const updated: ChatMessage = {
          id: this.messages[i].id,
          role: this.messages[i].role,
          content: finalContent,
          createdAt: this.messages[i].createdAt,
          updatedAt: Date.now(),
          isStreaming: streaming,
          errorMessage: errorMessage
        };
        this.messages[i] = updated;
        callbacks.onMessagesChanged(this.messages.slice());
        return;
      }
    }
  }
}