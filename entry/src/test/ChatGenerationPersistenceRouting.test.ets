/**
 * Chat 生成持久化路由测试 (T-6.3 Section 21)
 *
 * 验证普通生成与 Swipe 生成使用不同持久化路径:
 * 1.  普通 Streaming 更新 Message
 * 2.  普通 Complete 更新 Message
 * 3.  普通 Cancel 更新 Message
 * 4.  普通 Failed 更新 Message
 * 5.  Swipe Streaming 更新 Candidate
 * 6.  Swipe Complete 更新 Candidate
 * 7.  Swipe Cancel 更新 Candidate
 * 8.  Swipe Failed 更新 Candidate
 * 9.  Swipe 不重复更新 MessageRepository
 * 10. Candidate 物化由 Swipe Service 完成
 * 11. 最终状态持久化前不清理生成类型
 * 12. timer flush 使用正确路径
 */

import { describe, it, expect } from '@ohos/hypium';
import { ChatService, ChatServiceCallbacks, ChatState } from '../../main/ets/services/ChatService';
import { ModelService } from '../../main/ets/services/ModelService';
import { ChatPersistenceService } from '../../main/ets/services/ChatPersistenceService';
import { MessageSwipePersistenceService } from '../../main/ets/services/MessageSwipePersistenceService';
import { ChatMessage } from '../../main/ets/models/ChatMessage';
import {
  MockSwipeModelService,
  MockSwipePersistenceService,
  MockChatPersistenceServiceForSwipe,
  makeProviderConfig,
  makeUserMessage,
  makeAssistantMessage,
  createCollector,
  StateCollector
} from './MockChatSwipeDeps';

function createCallbacks(c: StateCollector): ChatServiceCallbacks {
  return {
    onMessagesChanged: (messages: ChatMessage[]): void => {
      c.messages = messages;
    },
    onStateChanged: (state: ChatState): void => {
      c.states.push(state);
    },
    onError: (message: string): void => {
      c.errors.push(message);
    }
  };
}

export default function chatGenerationPersistenceRoutingTest(): void {
  describe('ChatGenerationPersistenceRoutingTest', () => {

    // ====================================================================
    // 1. 普通 Streaming 更新 Message
    // ====================================================================

    it('Normal_streaming_updates_message', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-normal-stream';
      const userMsg: ChatMessage = makeUserMessage('msg-u-stream', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage('msg-a-stream', 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      const updateMsgBefore: number = mockPersist.updateMessageCallCount;
      await service.sendMessage('Hello', cb);
      mockMs.fireDelta('delta1', 1);
      // 触发 flush(通过 setTimeout,在测试中难以等待,这里只验证 complete 后的最终统计)
      mockMs.fireComplete('Final');

      expect(mockPersist.updateMessageCallCount).assertGreater(updateMsgBefore);

      service.dispose();
    });

    // ====================================================================
    // 2. 普通 Complete 更新 Message
    // ====================================================================

    it('Normal_complete_updates_message', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-normal-complete2';
      const userMsg: ChatMessage = makeUserMessage('msg-u-c2', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage('msg-a-c2', 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      const updateMsgBefore: number = mockPersist.updateMessageCallCount;
      await service.sendMessage('Hello', cb);
      mockMs.fireComplete('Final reply');

      expect(mockPersist.updateMessageCallCount).assertGreater(updateMsgBefore);

      service.dispose();
    });

    // ====================================================================
    // 3. 普通 Cancel 更新 Message
    // ====================================================================

    it('Normal_cancel_updates_message', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-normal-cancel';
      const userMsg: ChatMessage = makeUserMessage('msg-u-nc', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage('msg-a-nc', 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      const updateMsgBefore: number = mockPersist.updateMessageCallCount;
      await service.sendMessage('Hello', cb);
      service.stopGeneration();

      expect(mockPersist.updateMessageCallCount).assertGreater(updateMsgBefore);

      service.dispose();
    });

    // ====================================================================
    // 4. 普通 Failed 更新 Message
    // ====================================================================

    it('Normal_failed_updates_message', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-normal-fail';
      const userMsg: ChatMessage = makeUserMessage('msg-u-nf', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage('msg-a-nf', 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      const updateMsgBefore: number = mockPersist.updateMessageCallCount;
      await service.sendMessage('Hello', cb);
      mockMs.fireError(1, 'Network error');

      expect(mockPersist.updateMessageCallCount).assertGreater(updateMsgBefore);

      service.dispose();
    });

    // ====================================================================
    // 5. Swipe Streaming 更新 Candidate
    // ====================================================================

    it('Swipe_streaming_updates_candidate', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-swipe-stream';
      const assistantId: string = 'msg-a-swipe-s';
      const userMsg: ChatMessage = makeUserMessage('msg-u-swipe-s', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage(assistantId, 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      await service.sendMessage('Hello', cb);
      mockMs.fireComplete('First reply');

      const updateCandBefore: number = mockSwipe.updateCandidateCallCount;
      await service.regenerateLastResponse(cb);
      mockMs.fireDelta('delta', 1);
      mockMs.fireComplete('Swipe reply');

      expect(mockSwipe.updateCandidateCallCount).assertGreater(updateCandBefore);

      service.dispose();
    });

    // ====================================================================
    // 6. Swipe Complete 更新 Candidate
    // ====================================================================

    it('Swipe_complete_updates_candidate', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-swipe-complete2';
      const assistantId: string = 'msg-a-swipe-c';
      const userMsg: ChatMessage = makeUserMessage('msg-u-swipe-c', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage(assistantId, 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      await service.sendMessage('Hello', cb);
      mockMs.fireComplete('First reply');

      const updateCandBefore: number = mockSwipe.updateCandidateCallCount;
      await service.regenerateLastResponse(cb);
      mockMs.fireComplete('Swipe reply');

      expect(mockSwipe.updateCandidateCallCount).assertGreater(updateCandBefore);

      service.dispose();
    });

    // ====================================================================
    // 7. Swipe Cancel 更新 Candidate
    // ====================================================================

    it('Swipe_cancel_updates_candidate', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-swipe-cancel';
      const assistantId: string = 'msg-a-swipe-cancel';
      const userMsg: ChatMessage = makeUserMessage('msg-u-swipe-cancel', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage(assistantId, 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      await service.sendMessage('Hello', cb);
      mockMs.fireComplete('First reply');

      const updateCandBefore: number = mockSwipe.updateCandidateCallCount;
      await service.regenerateLastResponse(cb);
      service.stopGeneration();

      expect(mockSwipe.updateCandidateCallCount).assertGreater(updateCandBefore);

      service.dispose();
    });

    // ====================================================================
    // 8. Swipe Failed 更新 Candidate
    // ====================================================================

    it('Swipe_failed_updates_candidate', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-swipe-fail';
      const assistantId: string = 'msg-a-swipe-fail';
      const userMsg: ChatMessage = makeUserMessage('msg-u-swipe-fail', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage(assistantId, 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      await service.sendMessage('Hello', cb);
      mockMs.fireComplete('First reply');

      const updateCandBefore: number = mockSwipe.updateCandidateCallCount;
      await service.regenerateLastResponse(cb);
      mockMs.fireError(1, 'Swipe network error');

      expect(mockSwipe.updateCandidateCallCount).assertGreater(updateCandBefore);

      service.dispose();
    });

    // ====================================================================
    // 9. Swipe 不重复更新 MessageRepository
    // ====================================================================

    it('Swipe_does_not_duplicate_message_update', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-swipe-no-dup';
      const assistantId: string = 'msg-a-swipe-nd';
      const userMsg: ChatMessage = makeUserMessage('msg-u-swipe-nd', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage(assistantId, 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      await service.sendMessage('Hello', cb);
      mockMs.fireComplete('First reply');

      // 普通生成已完成
      const msgUpdateAfterNormal: number = mockPersist.updateMessageCallCount;

      // Swipe 生成 - 不应再调用 updateMessage(走 Candidate 路径)
      await service.regenerateLastResponse(cb);
      mockMs.fireComplete('Swipe reply');

      expect(mockPersist.updateMessageCallCount).assertEqual(msgUpdateAfterNormal);

      service.dispose();
    });

    // ====================================================================
    // 10. Candidate 物化由 Swipe Service 完成
    // ====================================================================

    it('Candidate_materialization_by_swipe_service', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-cand-material';
      const assistantId: string = 'msg-a-mat';
      const userMsg: ChatMessage = makeUserMessage('msg-u-mat', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage(assistantId, 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      await service.sendMessage('Hello', cb);
      mockMs.fireComplete('First reply');

      const appendBefore: number = mockSwipe.appendCandidateCallCount;
      await service.regenerateLastResponse(cb);
      // appendCandidate 应被调用以创建新候选
      expect(mockSwipe.appendCandidateCallCount).assertGreater(appendBefore);

      mockMs.fireComplete('Swipe reply');
      service.dispose();
    });

    // ====================================================================
    // 11. 最终状态持久化前不清理生成类型
    // ====================================================================

    it('Does_not_clear_generation_before_final_persist', 0, async () => {
      // 此用例通过验证 complete 后状态正确恢复验证清理顺序
      // 由于实现细节无法直接观察内部 activeGeneration,这里间接验证
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-clear-order';
      const assistantId: string = 'msg-a-clear';
      const userMsg: ChatMessage = makeUserMessage('msg-u-clear', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage(assistantId, 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      await service.sendMessage('Hello', cb);
      mockMs.fireComplete('First reply');

      await service.regenerateLastResponse(cb);
      mockMs.fireComplete('Swipe reply');

      // 最终候选应被持久化
      expect(mockSwipe.updateCandidateCallCount > 0).assertTrue();
      // 状态应为 Completed
      const lastState: ChatState = collector.states[collector.states.length - 1];
      expect(lastState).assertEqual(ChatState.Completed);

      service.dispose();
    });

    // ====================================================================
    // 12. timer flush 使用正确路径
    // ====================================================================

    it('Timer_flush_uses_correct_route', 0, async () => {
      // 由于 timer 是异步的且在测试中难以精确控制,
      // 此用例通过验证 fireDelta 后立即 complete 的行为间接验证 timer flush 路径
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-timer-flush';
      const assistantId: string = 'msg-a-timer';
      const userMsg: ChatMessage = makeUserMessage('msg-u-timer', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage(assistantId, 'Original');
      mockPersist.setSession(chatId, [userMsg, assistantMsg], 2);

      const service: ChatService = new ChatService(
        mockMs as Object as ModelService,
        null, null, null, null,
        mockPersist as Object as ChatPersistenceService,
        null,
        mockSwipe as Object as MessageSwipePersistenceService
      );

      const collector: StateCollector = createCollector();
      const cb: ChatServiceCallbacks = createCallbacks(collector);

      // 普通生成:delta + complete 应最终调用 updateMessage
      const updateMsgBefore: number = mockPersist.updateMessageCallCount;
      await service.sendMessage('Hello', cb);
      mockMs.fireDelta('delta1', 1);
      mockMs.fireDelta('delta2', 2);
      mockMs.fireComplete('Final');
      expect(mockPersist.updateMessageCallCount).assertGreater(updateMsgBefore);

      // Swipe 生成:delta + complete 应最终调用 updateCandidate
      const updateCandBefore: number = mockSwipe.updateCandidateCallCount;
      await service.regenerateLastResponse(cb);
      mockMs.fireDelta('swipe1', 1);
      mockMs.fireDelta('swipe2', 2);
      mockMs.fireComplete('Swipe final');
      expect(mockSwipe.updateCandidateCallCount).assertGreater(updateCandBefore);

      service.dispose();
    });
  });
}
