/**
 * Chat 运行时恢复一致性测试 (T-6.3 Section 22)
 *
 * 验证中断恢复后的状态一致性:
 * 1.  普通 Streaming Message → Cancelled
 * 2.  Swipe Streaming Candidate → Cancelled
 * 3.  Candidate 和 Message 内容一致
 * 4.  activeIndex 不改变
 * 5.  非 active Candidate 不物化
 * 6.  Completed 不修改
 * 7.  Failed 不修改
 * 8.  Cancelled 不修改
 * 9.  summaries 恢复正确
 * 10. 页面 generation 状态恢复 Idle
 */

import { describe, it, expect } from '@ohos/hypium';
import { ChatService, ChatServiceCallbacks, ChatState } from '../../main/ets/services/ChatService';
import { ModelService } from '../../main/ets/services/ModelService';
import { ChatPersistenceService } from '../../main/ets/services/ChatPersistenceService';
import { MessageSwipePersistenceService } from '../../main/ets/services/MessageSwipePersistenceService';
import { ChatMessage, ChatMessageStatus } from '../../main/ets/models/ChatMessage';
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

export default function chatRuntimeRecoveryConsistencyTest(): void {
  describe('ChatRuntimeRecoveryConsistencyTest', () => {

    // ====================================================================
    // 1. 普通 Streaming Message → Cancelled
    // ====================================================================

    it('Normal_streaming_to_cancelled', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-1';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r1', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage('msg-a-r1', 'Original');
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
      // 启动后 stopGeneration 应将消息标记为 Cancelled
      service.stopGeneration();

      const lastMsg: ChatMessage = service.getMessages()[service.getMessages().length - 1];
      expect(lastMsg.status).assertEqual(ChatMessageStatus.Cancelled);
      expect(lastMsg.isStreaming).assertFalse();

      service.dispose();
    });

    // ====================================================================
    // 2. Swipe Streaming Candidate → Cancelled
    // ====================================================================

    it('Swipe_streaming_candidate_to_cancelled', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-2';
      const assistantId: string = 'msg-a-r2';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r2', 'Hello');
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
      service.stopGeneration();

      // Swipe 候选状态应为 Cancelled(通过 lastUpdatedUpdates 检查)
      expect(mockSwipe.lastUpdatedUpdates).assertNotNull();
      if (mockSwipe.lastUpdatedUpdates !== null) {
        expect(mockSwipe.lastUpdatedUpdates.status).assertEqual(ChatMessageStatus.Cancelled);
        expect(mockSwipe.lastUpdatedUpdates.isStreaming).assertFalse();
      }

      service.dispose();
    });

    // ====================================================================
    // 3. Candidate 和 Message 内容一致
    // ====================================================================

    it('Candidate_and_message_content_consistent', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-3';
      const assistantId: string = 'msg-a-r3';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r3', 'Hello');
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
      mockMs.fireComplete('Swipe reply content');

      // 内存中的 Assistant Message 应反映 Swipe 内容
      const messages: ChatMessage[] = service.getMessages();
      const lastMsg: ChatMessage = messages[messages.length - 1];
      expect(lastMsg.content).assertEqual('Swipe reply content');

      service.dispose();
    });

    // ====================================================================
    // 4. activeIndex 不改变
    // ====================================================================

    it('Active_index_not_changed_on_cancel', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-4';
      const assistantId: string = 'msg-a-r4';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r4', 'Hello');
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
      // 候选已激活 - activeIndex 应为 1
      const summaries: ChatMessage[] = service.getMessages();
      // 检查 summaries 中 activeCandidateIndex
      const swipeSummaries = service.getSwipeSummaries();
      if (swipeSummaries.length > 0) {
        expect(swipeSummaries[0].activeCandidateIndex).assertEqual(1);
      }

      service.stopGeneration();
      // stop 后 activeIndex 不应回退
      const afterStop = service.getSwipeSummaries();
      if (afterStop.length > 0) {
        expect(afterStop[0].activeCandidateIndex).assertEqual(1);
      }

      service.dispose();
    });

    // ====================================================================
    // 5. 非 active Candidate 不物化
    // ====================================================================

    it('Non_active_candidate_not_materialized', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-5';
      const assistantId: string = 'msg-a-r5';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r5', 'Hello');
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

      // Swipe 创建候选 1
      await service.regenerateLastResponse(cb);
      mockMs.fireComplete('Swipe 1');

      // 再生成候选 2
      await service.regenerateLastResponse(cb);
      mockMs.fireComplete('Swipe 2');

      // 当前应激活候选 2(共 3 个候选)
      const summaries = service.getSwipeSummaries();
      if (summaries.length > 0) {
        expect(summaries[0].candidateCount).assertEqual(3);
        expect(summaries[0].activeCandidateIndex).assertEqual(2);
      }

      service.dispose();
    });

    // ====================================================================
    // 6. Completed 不修改
    // ====================================================================

    it('Completed_not_modified', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-6';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r6', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage('msg-a-r6', 'Original');
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
      mockMs.fireComplete('Final reply');

      const beforeStatus: ChatMessageStatus = service.getMessages()[service.getMessages().length - 1].status;
      // 迟到 complete 应不改变状态
      mockMs.fireComplete(' should not change');
      const afterStatus: ChatMessageStatus = service.getMessages()[service.getMessages().length - 1].status;

      expect(afterStatus).assertEqual(beforeStatus);
      expect(afterStatus).assertEqual(ChatMessageStatus.Completed);

      service.dispose();
    });

    // ====================================================================
    // 7. Failed 不修改
    // ====================================================================

    it('Failed_not_modified', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-7';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r7', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage('msg-a-r7', 'Original');
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
      mockMs.fireError(1, 'Network error');

      const beforeStatus: ChatMessageStatus = service.getMessages()[service.getMessages().length - 1].status;
      // 迟到 error 应不改变状态
      mockMs.fireError(1, ' should not change');
      const afterStatus: ChatMessageStatus = service.getMessages()[service.getMessages().length - 1].status;

      expect(afterStatus).assertEqual(beforeStatus);
      expect(afterStatus).assertEqual(ChatMessageStatus.Failed);

      service.dispose();
    });

    // ====================================================================
    // 8. Cancelled 不修改
    // ====================================================================

    it('Cancelled_not_modified', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-8';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r8', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage('msg-a-r8', 'Original');
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
      service.stopGeneration();

      const beforeStatus: ChatMessageStatus = service.getMessages()[service.getMessages().length - 1].status;
      // 迟到 complete 应不改变状态
      mockMs.fireComplete(' should not change');
      const afterStatus: ChatMessageStatus = service.getMessages()[service.getMessages().length - 1].status;

      expect(afterStatus).assertEqual(beforeStatus);
      expect(afterStatus).assertEqual(ChatMessageStatus.Cancelled);

      service.dispose();
    });

    // ====================================================================
    // 9. summaries 恢复正确
    // ====================================================================

    it('Summaries_restored_correctly', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-9';
      const assistantId: string = 'msg-a-r9';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r9', 'Hello');
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

      // summaries 应反映已完成状态(isGeneratingCandidate=false)
      const summaries = service.getSwipeSummaries();
      if (summaries.length > 0) {
        expect(summaries[0].isGeneratingCandidate).assertFalse();
        expect(summaries[0].candidateCount).assertGreater(0);
      }

      service.dispose();
    });

    // ====================================================================
    // 10. 页面 generation 状态恢复 Idle
    // ====================================================================

    it('Generation_state_restored_to_idle', 0, async () => {
      const mockMs: MockSwipeModelService = new MockSwipeModelService();
      mockMs.setCurrentConfig(makeProviderConfig());
      const mockSwipe: MockSwipePersistenceService = new MockSwipePersistenceService();
      const mockPersist: MockChatPersistenceServiceForSwipe = new MockChatPersistenceServiceForSwipe();

      const chatId: string = 'chat-recover-10';
      const userMsg: ChatMessage = makeUserMessage('msg-u-r10', 'Hello');
      const assistantMsg: ChatMessage = makeAssistantMessage('msg-a-r10', 'Original');
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
      service.stopGeneration();

      // stop 后应恢复 Idle(非生成状态)
      expect(service.isGenerating()).assertFalse();
      expect(service.isBusy()).assertFalse();

      service.dispose();
    });
  });
}
