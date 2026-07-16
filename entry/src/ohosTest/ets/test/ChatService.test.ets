/**
 * ChatService 设备集成测试
 *
 * 使用可控 Mock ModelService 验证 ChatService 的状态机与消息管理行为。
 * 不依赖 Mock Server,所有场景通过注入 mock 实现。
 *
 * 覆盖项(36 项):
 * 1. 发送正常消息
 * 2. 用户消息立即加入列表
 * 3. Assistant 占位消息立即创建
 * 4. 多个 delta 按顺序拼接
 * 5. 中文回复
 * 6. Emoji 回复
 * 7. 换行保留
 * 8. 完成后 isStreaming=false
 * 9. stop 调用 abort
 * 10. stop 后不再追加 delta
 * 11. stop 保留已有回复
 * 12. 空输入拒绝
 * 13. 仅空白输入拒绝
 * 14. 无当前配置拒绝
 * 15. 配置 disabled
 * 16. API Key 缺失
 * 17. 401
 * 18. 429
 * 19. Timeout
 * 20. Network
 * 21. Server
 * 22. Parse
 * 23. 不允许并发发送
 * 24. clear 清空消息
 * 25. clear 生成中先 abort
 * 26. dispose 停止请求
 * 27. 连续发送保持消息顺序
 * 28. 页面退出不接受迟到回调
 * 29. dispose 后 sendMessage 抛 Error(不可复用)
 * 30. onMessagesChanged 每次返回新数组引用
 * 31. delta 更新后返回新 ChatMessage 对象
 * 32. 仅 onComplete.content 有内容时回填
 * 33. complete 内容与 delta 不一致时以 complete 为准
 * 34. 空回复映射为 Failed
 * 35. 部分回复后失败保留内容
 * 36. stop 后 Assistant 标记为 Cancelled
 */

import { describe, it, expect } from '@ohos/hypium';
import { ChatService, ChatState, ChatServiceCallbacks } from '../../../main/ets/services/ChatService';
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatRequestOptions } from '../../../main/ets/models/ChatRequest';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState,
  ChatDelta,
  ChatStreamResult
} from '../../../main/ets/models/ChatStreamTypes';
import { NetworkError, NetworkErrorType, createNetworkError } from '../../../main/ets/models/NetworkError';

// ===== Mock ModelService =====

/** 可控流式句柄,支持注入 abort 行为 */
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

/** 可控 ModelService,支持注入流式回调 */
class MockModelService {
  streamChatCallCount: number = 0;
  lastMessages: ChatMessage[] | null = null;
  private pendingCallbacks: ChatStreamCallbacks | null = null;
  private pendingHandle: ControllableStreamHandle | null = null;
  /** 注入错误(在 streamCurrentChat 调用时同步抛出) */
  throwError: Error | null = null;

  streamCurrentChat(
    messages: ChatMessage[],
    _options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    this.streamChatCallCount++;
    this.lastMessages = messages;
    if (this.throwError !== null) {
      throw this.throwError;
    }
    this.pendingCallbacks = callbacks;
    this.pendingHandle = new ControllableStreamHandle();
    this.pendingHandle.state = ChatStreamState.Streaming;
    return this.pendingHandle;
  }

  /** 触发一个 delta */
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

  /** 触发多个 delta */
  fireDeltas(contents: string[]): void {
    for (let i = 0; i < contents.length; i++) {
      this.fireDelta(contents[i], i);
    }
  }

  /** 触发完成 */
  fireComplete(): void {
    if (this.pendingCallbacks !== null) {
      const result: ChatStreamResult = {
        content: '',
        finishReason: 'stop',
        model: 'mock-model',
        chunkCount: 3,
        eventCount: 3,
        deltaCount: 3,
        receivedDone: true
      };
      this.pendingCallbacks.onComplete(result);
    }
  }

  /** 触发完成并携带最终 content(用于测试 complete 回填) */
  fireCompleteWithContent(content: string): void {
    if (this.pendingCallbacks !== null) {
      const result: ChatStreamResult = {
        content: content,
        finishReason: 'stop',
        model: 'mock-model',
        chunkCount: 3,
        eventCount: 3,
        deltaCount: 3,
        receivedDone: true
      };
      this.pendingCallbacks.onComplete(result);
    }
  }

  /** 触发错误 */
  fireError(type: NetworkErrorType, message: string): void {
    if (this.pendingCallbacks !== null) {
      const error: NetworkError = createNetworkError(type, message);
      this.pendingCallbacks.onError(error);
    }
  }

  /** 获取 pending 句柄 */
  getPendingHandle(): ControllableStreamHandle | null {
    return this.pendingHandle;
  }

  reset(): void {
    this.streamChatCallCount = 0;
    this.lastMessages = null;
    this.pendingCallbacks = null;
    this.pendingHandle = null;
    this.throwError = null;
  }
}

// ===== 测试辅助 =====

interface StateCollector {
  messages: ChatMessage[];
  states: ChatState[];
  errors: string[];
  messageChangeCount: number;
}

function createCollector(): StateCollector {
  return {
    messages: [],
    states: [],
    errors: [],
    messageChangeCount: 0
  };
}

function createCallbacks(collector: StateCollector): ChatServiceCallbacks {
  return {
    onMessagesChanged: (messages: ChatMessage[]): void => {
      collector.messages = messages;
      collector.messageChangeCount++;
    },
    onStateChanged: (state: ChatState): void => {
      collector.states.push(state);
    },
    onError: (message: string): void => {
      collector.errors.push(message);
    }
  };
}

// ===== 测试套件 =====

interface ServiceFixture {
  mockMs: MockModelService;
  service: ChatService;
}

function createService(): ServiceFixture {
  const mockMs: MockModelService = new MockModelService();
  const service: ChatService = new ChatService(
    mockMs as Object as import('../../../main/ets/services/ModelService').ModelService
  );
  const fixture: ServiceFixture = { mockMs: mockMs, service: service };
  return fixture;
}

export default function chatServiceDeviceTest() {
  describe('ChatServiceDeviceTest', () => {

    // 1. 发送正常消息
    it('send_normal_message', 0, async () => {
      const svc = createService();
      const mockMs = svc.mockMs;
      const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('Hello', callbacks);
      mockMs.fireDeltas(['Hello', ' ', 'World']);
      mockMs.fireComplete();

      expect(collector.messages.length).assertEqual(2);
      expect(collector.messages[0].role).assertEqual(ChatRole.User);
      expect(collector.messages[0].content).assertEqual('Hello');
      expect(collector.messages[1].role).assertEqual(ChatRole.Assistant);
      expect(collector.messages[1].content).assertEqual('Hello World');
      expect(collector.messages[1].isStreaming).assertEqual(false);
      expect(collector.states.indexOf(ChatState.Completed) >= 0).assertTrue();
    });

    // 2+3. 用户消息立即加入列表 + Assistant 占位消息立即创建
    it('user_and_assistant_messages_created_immediately', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      const promise: Promise<void> = service.sendMessage('test', callbacks);

      // 在 fireDelta 之前,消息已创建
      expect(collector.messages.length).assertEqual(2);
      expect(collector.messages[0].role).assertEqual(ChatRole.User);
      expect(collector.messages[0].content).assertEqual('test');
      expect(collector.messages[1].role).assertEqual(ChatRole.Assistant);
      expect(collector.messages[1].content).assertEqual('');
      expect(collector.messages[1].isStreaming).assertEqual(true);

      mockMs.fireComplete();
      await promise;
      service.dispose();
    });

    // 4. 多个 delta 按顺序拼接
    it('multiple_deltas_concatenated_in_order', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('Hi', callbacks);
      mockMs.fireDelta('A', 0);
      mockMs.fireDelta('B', 1);
      mockMs.fireDelta('C', 2);
      mockMs.fireComplete();

      expect(collector.messages[1].content).assertEqual('ABC');
      service.dispose();
    });

    // 5. 中文回复
    it('chinese_reply', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('你好', callbacks);
      mockMs.fireDelta('你好', 0);
      mockMs.fireDelta('世界', 1);
      mockMs.fireComplete();

      expect(collector.messages[1].content).assertEqual('你好世界');
      service.dispose();
    });

    // 6. Emoji 回复
    it('emoji_reply', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('emoji', callbacks);
      mockMs.fireDelta('Hello ', 0);
      mockMs.fireDelta('🌍🚀🎉', 1);
      mockMs.fireComplete();

      expect(collector.messages[1].content).assertEqual('Hello 🌍🚀🎉');
      service.dispose();
    });

    // 7. 换行保留
    it('newline_preserved', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('newline', callbacks);
      mockMs.fireDelta('Line 1\n', 0);
      mockMs.fireDelta('Line 2\n', 1);
      mockMs.fireDelta('Line 3', 2);
      mockMs.fireComplete();

      expect(collector.messages[1].content).assertEqual('Line 1\nLine 2\nLine 3');
      service.dispose();
    });

    // 8. 完成后 isStreaming=false
    it('streaming_ends_on_complete', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireDelta('reply', 0);
      mockMs.fireComplete();

      expect(collector.messages[1].isStreaming).assertEqual(false);
      expect(service.isGenerating()).assertFalse();
      service.dispose();
    });

    // 9. stop 调用 abort
    it('stop_calls_abort', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireDelta('partial', 0);

      const handle: ControllableStreamHandle | null = mockMs.getPendingHandle();
      expect(handle !== null).assertTrue();

      service.stopGeneration();

      expect(handle!.aborted).assertTrue();
      service.dispose();
    });

    // 10. stop 后不再追加 delta
    it('no_delta_after_stop', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireDelta('before stop', 0);

      service.stopGeneration();

      // 迟到 delta 应被忽略
      mockMs.fireDelta('after stop', 1);

      expect(collector.messages[1].content).assertEqual('before stop');
      expect(collector.messages[1].content.indexOf('after stop') < 0).assertTrue();
      service.dispose();
    });

    // 11. stop 保留已有回复
    it('stop_preserves_existing_content', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireDelta('saved content', 0);

      service.stopGeneration();

      expect(collector.messages[1].content).assertEqual('saved content');
      expect(collector.messages.length).assertEqual(2);
      service.dispose();
    });

    // 12. 空输入拒绝
    it('empty_input_rejected', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('', callbacks);

      expect(mockMs.streamChatCallCount).assertEqual(0);
      expect(collector.messages.length).assertEqual(0);
      service.dispose();
    });

    // 13. 仅空白输入拒绝
    it('whitespace_only_input_rejected', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('  ', callbacks);

      expect(mockMs.streamChatCallCount).assertEqual(0);
      expect(collector.messages.length).assertEqual(0);
      service.dispose();
    });

    // 14. 无当前配置拒绝(由 ModelService 抛出)
    it('no_current_config_error', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      mockMs.throwError = new Error('No current provider config');

      await service.sendMessage('test', callbacks);

      expect(collector.errors.length > 0).assertTrue();
      expect(collector.messages[1].errorMessage !== undefined).assertTrue();
      service.dispose();
    });

    // 15. 配置 disabled
    it('config_disabled_error', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      mockMs.throwError = new Error('Current provider config is disabled');

      await service.sendMessage('test', callbacks);

      expect(collector.errors.length > 0).assertTrue();
      expect(collector.errors[0].indexOf('disabled') >= 0).assertTrue();
      service.dispose();
    });

    // 16. API Key 缺失
    it('api_key_missing_error', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      mockMs.throwError = new Error('API Key not configured');

      await service.sendMessage('test', callbacks);

      expect(collector.errors.length > 0).assertTrue();
      service.dispose();
    });

    // 17. 401
    it('auth_401_error', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireError(NetworkErrorType.Authentication, 'Invalid API Key');

      expect(collector.errors.length > 0).assertTrue();
      expect(collector.errors[0].indexOf('Authentication') >= 0
        || collector.errors[0].indexOf('Invalid') >= 0).assertTrue();
      service.dispose();
    });

    // 18. 429
    it('rate_limit_429_error', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireError(NetworkErrorType.RateLimit, 'Too many requests');

      expect(collector.errors.length > 0).assertTrue();
      expect(collector.errors[0].indexOf('RateLimit') >= 0
        || collector.errors[0].indexOf('many') >= 0).assertTrue();
      service.dispose();
    });

    // 19. Timeout
    it('timeout_error', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireError(NetworkErrorType.Timeout, 'Request timed out');

      expect(collector.errors.length > 0).assertTrue();
      expect(collector.errors[0].indexOf('Timeout') >= 0
        || collector.errors[0].indexOf('timed') >= 0).assertTrue();
      service.dispose();
    });

    // 20. Network
    it('network_error', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireError(NetworkErrorType.Network, 'Connection refused');

      expect(collector.errors.length > 0).assertTrue();
      service.dispose();
    });

    // 21. Server
    it('server_error', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireError(NetworkErrorType.Server, 'Internal server error');

      expect(collector.errors.length > 0).assertTrue();
      service.dispose();
    });

    // 22. Parse
    it('parse_error', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireError(NetworkErrorType.Parse, 'Invalid JSON response');

      expect(collector.errors.length > 0).assertTrue();
      service.dispose();
    });

    // 23. 不允许并发发送
    it('concurrent_send_rejected', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('first', callbacks);

      expect(service.isGenerating()).assertTrue();

      const collector2 = createCollector();
      const callbacks2 = createCallbacks(collector2);
      await service.sendMessage('second', callbacks2);

      expect(mockMs.streamChatCallCount).assertEqual(1);
      expect(collector2.messages.length).assertEqual(0);
      service.dispose();
    });

    // 24. clear 清空消息
    it('clear_empties_messages', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireComplete();

      service.clearConversation();
      const messages: ChatMessage[] = service.getMessages();
      expect(messages.length).assertEqual(0);
      service.dispose();
    });

    // 25. clear 生成中先 abort
    it('clear_during_generation_aborts', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireDelta('partial', 0);

      const handle: ControllableStreamHandle | null = mockMs.getPendingHandle();
      expect(handle !== null).assertTrue();

      service.clearConversation();

      expect(handle!.aborted).assertTrue();
      expect(service.getMessages().length).assertEqual(0);
      service.dispose();
    });

    // 26. dispose 停止请求
    it('dispose_stops_request', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      const handle: ControllableStreamHandle | null = mockMs.getPendingHandle();
      expect(handle !== null).assertTrue();

      service.dispose();

      expect(handle!.aborted).assertTrue();
      expect(service.getMessages().length).assertEqual(0);
    });

    // 27. 连续发送保持消息顺序
    it('consecutive_sends_maintain_order', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('User 1', callbacks);
      mockMs.fireDelta('Reply 1', 0);
      mockMs.fireComplete();

      expect(collector.messages.length).assertEqual(2);
      expect(collector.messages[0].content).assertEqual('User 1');
      expect(collector.messages[1].content).assertEqual('Reply 1');

      mockMs.reset();
      await service.sendMessage('User 2', callbacks);
      mockMs.fireDelta('Reply 2', 0);
      mockMs.fireComplete();

      expect(collector.messages.length).assertEqual(4);
      expect(collector.messages[0].content).assertEqual('User 1');
      expect(collector.messages[1].content).assertEqual('Reply 1');
      expect(collector.messages[2].content).assertEqual('User 2');
      expect(collector.messages[3].content).assertEqual('Reply 2');
      service.dispose();
    });

    // 28. 页面退出不接受迟到回调
    it('disposed_ignores_late_callbacks', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireDelta('before dispose', 0);

      service.dispose();

      mockMs.fireDelta('after dispose', 1);
      mockMs.fireComplete();

      expect(service.getMessages().length).assertEqual(0);
    });

    // 29. dispose 后 sendMessage 抛 Error(不可复用)
    it('disposed_service_send_throws', 0, async () => {
      const svc = createService(); const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      service.dispose();

      let threw: boolean = false;
      try {
        await service.sendMessage('test', callbacks);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(collector.messages.length).assertEqual(0);
    });

    // 30. onMessagesChanged 每次返回新数组引用
    it('onMessagesChanged_returns_new_array_reference', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);

      // sendMessage 内部触发两次 onMessagesChanged(user + assistant)
      // 加上初始空数组,至少 2 次回调
      expect(collector.messageChangeCount >= 2).assertTrue();

      // 记录当前数组引用
      const firstRef: ChatMessage[] = collector.messages;

      mockMs.fireDelta('A', 0);
      const secondRef: ChatMessage[] = collector.messages;
      expect(secondRef !== firstRef).assertTrue();

      mockMs.fireDelta('B', 1);
      const thirdRef: ChatMessage[] = collector.messages;
      expect(thirdRef !== secondRef).assertTrue();

      mockMs.fireComplete();
      const finalRef: ChatMessage[] = collector.messages;
      expect(finalRef !== thirdRef).assertTrue();

      service.dispose();
    });

    // 31. delta 更新后返回新 ChatMessage 对象
    it('delta_returns_new_chat_message_object', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);

      const placeholder: ChatMessage = collector.messages[1];
      const placeholderIdentity: ChatMessage = placeholder;

      mockMs.fireDelta('delta content', 0);

      const updated: ChatMessage = collector.messages[1];
      // 不同对象引用
      expect(updated !== placeholderIdentity).assertTrue();
      // 内容已更新
      expect(updated.content).assertEqual('delta content');
      // 原对象未被修改(不可变)
      expect(placeholder.content).assertEqual('');
      service.dispose();
    });

    // 32. 仅 onComplete.content 有内容时回填
    it('complete_content_backfills_empty_assistant', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);

      // 不触发任何 delta,直接 complete 且携带最终内容
      mockMs.fireCompleteWithContent('final content from complete');

      expect(collector.messages[1].content).assertEqual('final content from complete');
      expect(collector.messages[1].isStreaming).assertEqual(false);
      expect(collector.messages[1].status).assertEqual(ChatMessageStatus.Completed);
      expect(service.isGenerating()).assertFalse();
      service.dispose();
    });

    // 33. complete 内容与 delta 不一致时以 complete 为准
    it('complete_content_overrides_inconsistent_delta', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);

      // delta 拼接出 A
      mockMs.fireDelta('DeltaA', 0);
      expect(collector.messages[1].content).assertEqual('DeltaA');

      // complete 携带不同的最终内容,应覆盖
      mockMs.fireCompleteWithContent('FinalContent');

      expect(collector.messages[1].content).assertEqual('FinalContent');
      expect(collector.messages[1].status).assertEqual(ChatMessageStatus.Completed);
      service.dispose();
    });

    // 34. 空回复映射为 Failed
    it('empty_reply_mapped_to_failed', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);

      // 既无 delta,complete.content 也为空
      mockMs.fireComplete();

      expect(collector.messages[1].content).assertEqual('');
      expect(collector.messages[1].status).assertEqual(ChatMessageStatus.Failed);
      expect(collector.messages[1].errorMessage !== undefined).assertTrue();
      expect(collector.messages[1].errorMessage!.indexOf('空回复') >= 0).assertTrue();
      expect(service.isGenerating()).assertFalse();
      expect(collector.states.indexOf(ChatState.Failed) >= 0).assertTrue();
      service.dispose();
    });

    // 35. 部分回复后失败保留内容
    it('partial_reply_failure_preserves_content', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireDelta('partial ', 0);
      mockMs.fireDelta('reply', 1);

      // 失败
      mockMs.fireError(NetworkErrorType.Network, 'Connection lost');

      // 内容保留
      expect(collector.messages[1].content).assertEqual('partial reply');
      expect(collector.messages[1].status).assertEqual(ChatMessageStatus.Failed);
      expect(collector.messages[1].isStreaming).assertEqual(false);
      expect(collector.messages[1].errorMessage !== undefined).assertTrue();
      expect(service.isGenerating()).assertFalse();
      expect(collector.errors.length > 0).assertTrue();
      service.dispose();
    });

    // 36. stop 后 Assistant 标记为 Cancelled
    it('stop_marks_assistant_cancelled', 0, async () => {
      const svc = createService(); const mockMs = svc.mockMs; const service = svc.service;
      const collector = createCollector();
      const callbacks = createCallbacks(collector);

      await service.sendMessage('test', callbacks);
      mockMs.fireDelta('partial', 0);

      service.stopGeneration();

      // getMessages 返回的 assistant 应为 Cancelled 状态
      const msgs: ChatMessage[] = service.getMessages();
      expect(msgs.length).assertEqual(2);
      expect(msgs[1].status).assertEqual(ChatMessageStatus.Cancelled);
      expect(msgs[1].isStreaming).assertEqual(false);
      expect(service.isGenerating()).assertFalse();
      expect(collector.states.indexOf(ChatState.Cancelled) >= 0).assertTrue();
      service.dispose();
    });
  });
}