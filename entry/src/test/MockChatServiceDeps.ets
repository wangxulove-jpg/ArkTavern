/**
 * MockChatServiceDeps 本地测试用 ChatService 依赖 Mock
 *
 * 仅存在于 test 目录,不进入 main 代码,不进入 HAP。
 * 提供 MockModelService,实现 ModelService 所需方法名以供 ChatService 调用。
 *
 * 使用:
 *   const deps = new MockChatServiceDeps();
 *   const chatService = new ChatService(deps.modelService as Object as ModelService, ...);
 *   chatService.sendMessage('Hello', callbacks);
 *   deps.fireComplete();
 *
 * 安全要求:
 * - 不包含真实 API Key
 * - 不记录请求体原文
 */

import { ChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRequest, ChatRequestOptions } from '../main/ets/models/ChatRequest';
import { ChatResponse } from '../main/ets/models/ChatResponse';
import { ProviderConfig } from '../main/ets/models/ProviderConfig';
import { ChatStreamCallbacks, ChatStreamHandle, ChatStreamState, ChatDelta, ChatStreamResult } from '../main/ets/models/ChatStreamTypes';
import { NetworkError, NetworkErrorType, createNetworkError } from '../main/ets/models/NetworkError';

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

export class MockModelService {
  streamChatCallCount: number = 0;
  lastMessages: ChatMessage[] | null = null;
  lastOptions: ChatRequestOptions | null = null;
  currentConfig: ProviderConfig | null = null;
  throwOnStream: Error | null = null;
  private pendingCallbacks: ChatStreamCallbacks | null = null;
  private pendingHandle: ControllableStreamHandle | null = null;

  /** 设置当前 ProviderConfig,后续 getCurrentConfig 返回该值 */
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
