/**
 * ChatViewModel Swipe 操作本地测试
 *
 * 使用 MockChatServiceForSwipe(内存模拟)验证 ChatViewModel 的 Swipe 状态管理:
 * - summary 查询委托
 * - canOperateSwipe 判断
 * - swipePrevious / swipeNext 调用 Service
 * - regenerateAsNewCandidate 调用 Service
 * - 操作 Loading 与失败恢复
 * - 连续点击保护
 * - summary 与 messages 新数组引用
 * - 生成中按钮禁用
 * - 错误文案安全
 *
 * 不依赖真实数据库,所有场景通过注入 mock 实现。
 *
 * 覆盖 14 项。
 */

import { describe, it, expect } from '@ohos/hypium';
import { ChatViewModel } from '../main/ets/viewmodels/ChatViewModel';
import { ChatService, ChatServiceCallbacks, ChatState } from '../main/ets/services/ChatService';
import { ModelService } from '../main/ets/services/ModelService';
import { CharacterService } from '../main/ets/services/CharacterService';
import { ChatMessage, ChatMessageStatus } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import { MessageSwipeSummary } from '../main/ets/models/MessageSwipe';
import { ProviderConfig } from '../main/ets/models/ProviderConfig';
import { ProviderType } from '../main/ets/models/ProviderType';
import { Character } from '../main/ets/models/Character';

// ===== Mock ChatService =====

class MockChatServiceForSwipe {
  private swipeSummariesData: MessageSwipeSummary[] = [];
  private messagesData: ChatMessage[] = [];
  canOperateSwipeResult: boolean = false;
  canRegen: boolean = false;
  generating: boolean = false;
  disposed: boolean = false;
  previousCallCount: number = 0;
  nextCallCount: number = 0;
  generateCallCount: number = 0;
  throwOnPrevious: Error | null = null;
  throwOnNext: Error | null = null;
  throwOnGenerate: Error | null = null;
  lastActivateMessageId: string = '';

  setSwipeSummaries(summaries: MessageSwipeSummary[]): void {
    this.swipeSummariesData = summaries.slice();
  }

  setMessages(msgs: ChatMessage[]): void {
    this.messagesData = msgs.slice();
  }

  getSwipeSummaries(): MessageSwipeSummary[] {
    return this.swipeSummariesData.slice();
  }

  getSwipeSummary(assistantMessageId: string): MessageSwipeSummary | undefined {
    for (let i = 0; i < this.swipeSummariesData.length; i++) {
      if (this.swipeSummariesData[i].assistantMessageId === assistantMessageId) {
        return this.swipeSummariesData[i];
      }
    }
    return undefined;
  }

  canOperateSwipe(_assistantMessageId: string): boolean {
    return this.canOperateSwipeResult;
  }

  async activatePreviousCandidate(assistantMessageId: string): Promise<void> {
    this.previousCallCount++;
    this.lastActivateMessageId = assistantMessageId;
    if (this.throwOnPrevious !== null) {
      throw this.throwOnPrevious;
    }
    // 模拟切换后的摘要变更(activeCandidateIndex 递减)
    this.swipeSummariesData = this.swipeSummariesData.map(
      (s: MessageSwipeSummary): MessageSwipeSummary => {
        if (s.assistantMessageId === assistantMessageId) {
          return {
            assistantMessageId: s.assistantMessageId,
            activeCandidateIndex: s.activeCandidateIndex - 1,
            candidateCount: s.candidateCount,
            isGeneratingCandidate: false
          };
        }
        return s;
      }
    );
  }

  async activateNextCandidate(assistantMessageId: string): Promise<void> {
    this.nextCallCount++;
    this.lastActivateMessageId = assistantMessageId;
    if (this.throwOnNext !== null) {
      throw this.throwOnNext;
    }
    // 模拟切换后的摘要变更(activeCandidateIndex 递增)
    this.swipeSummariesData = this.swipeSummariesData.map(
      (s: MessageSwipeSummary): MessageSwipeSummary => {
        if (s.assistantMessageId === assistantMessageId) {
          return {
            assistantMessageId: s.assistantMessageId,
            activeCandidateIndex: s.activeCandidateIndex + 1,
            candidateCount: s.candidateCount,
            isGeneratingCandidate: false
          };
        }
        return s;
      }
    );
  }

  async generateAlternativeCandidate(): Promise<void> {
    this.generateCallCount++;
    if (this.throwOnGenerate !== null) {
      throw this.throwOnGenerate;
    }
  }

  getState(): ChatState {
    return ChatState.Idle;
  }

  getMessages(): ChatMessage[] {
    return this.messagesData.slice();
  }

  isGenerating(): boolean {
    return this.generating;
  }

  canRegenerate(): boolean {
    return this.canRegen;
  }

  async initializeSession(_character?: Character): Promise<void> {
    // no-op
  }

  async sendMessage(_content: string, _callbacks: ChatServiceCallbacks): Promise<void> {
    this.generating = true;
  }

  async regenerateLastResponse(_callbacks: ChatServiceCallbacks): Promise<void> {
    this.generating = true;
  }

  stopGeneration(): void {
    this.generating = false;
  }

  clearConversation(): void {
    this.messagesData = [];
  }

  dispose(): void {
    this.disposed = true;
  }
}

// ===== Mock ModelService / CharacterService =====

class MockModelService {
  async getCurrentConfig(): Promise<ProviderConfig | null> {
    return new ProviderConfig(
      'pcfg-1', 'mock', ProviderType.OpenAICompatible,
      'https://mock.local', 'mock-model',
      0.7, 1.0, 1024, true, true, 1000, 1000
    );
  }
}

class MockCharacterService {
  async getCurrentCharacter(): Promise<Character | null> {
    return null;
  }
}

// ===== 测试辅助 =====

function makeSummary(
  assistantMessageId: string,
  activeCandidateIndex: number,
  candidateCount: number,
  isGeneratingCandidate: boolean = false
): MessageSwipeSummary {
  return {
    assistantMessageId: assistantMessageId,
    activeCandidateIndex: activeCandidateIndex,
    candidateCount: candidateCount,
    isGeneratingCandidate: isGeneratingCandidate
  };
}

function makeAssistantMsg(id: string, content: string): ChatMessage {
  return {
    id: id,
    role: ChatRole.Assistant,
    content: content,
    createdAt: 1000,
    isStreaming: false,
    status: ChatMessageStatus.Completed
  };
}

function makeViewModel(mock?: MockChatServiceForSwipe): ChatViewModel {
  const ms: MockChatServiceForSwipe = mock !== undefined ? mock : new MockChatServiceForSwipe();
  const modelService: MockModelService = new MockModelService();
  const characterService: MockCharacterService = new MockCharacterService();
  const vm: ChatViewModel = new ChatViewModel(
    ms as Object as ChatService,
    modelService as Object as ModelService,
    characterService as Object as CharacterService
  );
  vm.isSessionReady = true;
  return vm;
}

export default function chatViewModelSwipeTest(): void {
  describe('ChatViewModelSwipeTest', () => {

    // ===== 1. summary 查询 =====
    it('getSwipeSummary_delegates_to_service', 0, () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.setSwipeSummaries([makeSummary('msg-1', 0, 3)]);
      const vm: ChatViewModel = makeViewModel(mock);

      const result: MessageSwipeSummary | undefined = vm.getSwipeSummary('msg-1');
      expect(result !== undefined).assertEqual(true);
      expect(result!.assistantMessageId).assertEqual('msg-1');
      expect(result!.activeCandidateIndex).assertEqual(0);
      expect(result!.candidateCount).assertEqual(3);
    });

    // ===== 2. canOperateSwipe 最后一条 Assistant =====
    it('canOperateSwipe_true_for_last_assistant', 0, () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      const vm: ChatViewModel = makeViewModel(mock);

      const result: boolean = vm.canOperateSwipe('msg-last');
      expect(result).assertTrue();
    });

    // ===== 3. 历史 Assistant 返回 false =====
    it('canOperateSwipe_false_for_historical_assistant', 0, () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = false;
      const vm: ChatViewModel = makeViewModel(mock);

      const result: boolean = vm.canOperateSwipe('msg-old');
      expect(result).assertFalse();
    });

    // ===== 4. 左按钮调用 Service =====
    it('swipePrevious_calls_service_activatePreviousCandidate', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      mock.setSwipeSummaries([makeSummary('msg-1', 1, 3)]);
      mock.setMessages([makeAssistantMsg('msg-1', 'candidate')]);
      const vm: ChatViewModel = makeViewModel(mock);
      const beforeCount: number = mock.previousCallCount;

      await vm.swipePrevious('msg-1');

      expect(mock.previousCallCount).assertEqual(beforeCount + 1);
      expect(mock.lastActivateMessageId).assertEqual('msg-1');
      expect(vm.isSwipeOperating).assertFalse();
    });

    // ===== 5. 右按钮调用 Service =====
    it('swipeNext_calls_service_activateNextCandidate', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      mock.setSwipeSummaries([makeSummary('msg-1', 0, 2)]);
      mock.setMessages([makeAssistantMsg('msg-1', 'candidate')]);
      const vm: ChatViewModel = makeViewModel(mock);
      const beforeCount: number = mock.nextCallCount;

      await vm.swipeNext('msg-1');

      expect(mock.nextCallCount).assertEqual(beforeCount + 1);
      expect(mock.lastActivateMessageId).assertEqual('msg-1');
      expect(vm.isSwipeOperating).assertFalse();
    });

    // ===== 6. regenerate 调用新 Candidate 接口 =====
    it('regenerateAsNewCandidate_calls_generateAlternativeCandidate', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canRegen = true;
      const vm: ChatViewModel = makeViewModel(mock);
      vm.canRegenerate = true;
      const beforeCount: number = mock.generateCallCount;

      await vm.regenerateAsNewCandidate();

      expect(mock.generateCallCount).assertEqual(beforeCount + 1);
    });

    // ===== 7. 操作 Loading =====
    it('swipePrevious_sets_operating_flag_during_execution', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      mock.setSwipeSummaries([makeSummary('msg-1', 1, 3)]);
      mock.setMessages([makeAssistantMsg('msg-1', 'candidate')]);
      const vm: ChatViewModel = makeViewModel(mock);
      expect(vm.isSwipeOperating).assertFalse();

      // 启动操作但暂不 await,验证 flag 已设置
      const p: Promise<void> = vm.swipePrevious('msg-1');
      expect(vm.isSwipeOperating).assertTrue();

      await p;
      expect(vm.isSwipeOperating).assertFalse();
    });

    // ===== 8. 操作失败恢复 =====
    it('swipeNext_failure_restores_state_and_sets_error', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      mock.throwOnNext = new Error('network error');
      const vm: ChatViewModel = makeViewModel(mock);
      expect(vm.swipeError.length).assertEqual(0);

      await vm.swipeNext('msg-1');

      expect(vm.isSwipeOperating).assertFalse();
      expect(vm.swipeError.length > 0).assertTrue();
    });

    // ===== 9. 连续点击保护 =====
    it('repeated_swipe_click_not_duplicated', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      const vm: ChatViewModel = makeViewModel(mock);
      // 模拟第一次操作进行中
      vm.isSwipeOperating = true;

      await vm.swipePrevious('msg-1');

      expect(mock.previousCallCount).assertEqual(0);
      expect(vm.isSwipeOperating).assertTrue(); // 未被复位
    });

    // ===== 10. summary 使用新数组 =====
    it('swipeNext_updates_swipeSummaries_from_service', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      const summary: MessageSwipeSummary = makeSummary('msg-1', 0, 2);
      mock.setSwipeSummaries([summary]);
      mock.setMessages([makeAssistantMsg('msg-1', 'candidate')]);
      const vm: ChatViewModel = makeViewModel(mock);
      expect(vm.swipeSummaries.length).assertEqual(0);

      await vm.swipeNext('msg-1');

      expect(vm.swipeSummaries.length).assertEqual(1);
      expect(vm.swipeSummaries[0].assistantMessageId).assertEqual('msg-1');
      // 验证是新数组引用
      const originalRef: Object = mock.getSwipeSummaries();
      expect(vm.swipeSummaries !== originalRef).assertTrue();
    });

    // ===== 11. messages 使用新数组 =====
    it('swipePrevious_updates_messages_from_service', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      mock.setSwipeSummaries([makeSummary('msg-1', 1, 3)]);
      const msgs: ChatMessage[] = [makeAssistantMsg('msg-1', 'swiped content')];
      mock.setMessages(msgs);
      const vm: ChatViewModel = makeViewModel(mock);

      await vm.swipePrevious('msg-1');

      expect(vm.messages.length).assertEqual(1);
      expect(vm.messages[0].content).assertEqual('swiped content');
      // 验证是新数组引用
      const originalRef: Object = mock.getMessages();
      expect(vm.messages !== originalRef).assertTrue();
    });

    // ===== 12. 生成中按钮禁用 =====
    it('canOperateSwipe_false_when_isGenerating', 0, () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      const vm: ChatViewModel = makeViewModel(mock);
      expect(vm.canOperateSwipe('msg-1')).assertTrue();

      vm.isGenerating = true;

      expect(vm.canOperateSwipe('msg-1')).assertFalse();
    });

    // ===== 13. 达到上限按钮禁用 =====
    it('canOperateSwipe_false_when_service_rejects', 0, () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      // service 返回 false 表示已达上限或不可操作
      mock.canOperateSwipeResult = false;
      const vm: ChatViewModel = makeViewModel(mock);

      const result: boolean = vm.canOperateSwipe('msg-full');
      expect(result).assertFalse();
    });

    // ===== 14. 错误文案安全 =====
    it('swipeError_uses_safe_user_facing_message', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.canOperateSwipeResult = true;
      // 模拟包含敏感信息的错误
      mock.throwOnPrevious = new Error('API Key invalid for provider');
      const vm: ChatViewModel = makeViewModel(mock);

      await vm.swipePrevious('msg-1');

      expect(vm.swipeError.length > 0).assertTrue();
      // 安全错误文案不应包含原始错误中的敏感信息
      const hasSensitive: boolean = vm.swipeError.indexOf('API Key') >= 0
        || vm.swipeError.indexOf('api key') >= 0
        || vm.swipeError.indexOf('apiKey') >= 0;
      expect(hasSensitive).assertFalse();
      // 应显示用户友好的错误提示
      expect(vm.swipeError.indexOf('请求失败') >= 0).assertTrue();
    });

    // ===== 额外: regenerate 生成中跳过 =====
    it('regenerateAsNewCandidate_skipped_when_generating', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      const vm: ChatViewModel = makeViewModel(mock);
      vm.isGenerating = true;
      vm.canRegenerate = true;

      await vm.regenerateAsNewCandidate();

      expect(mock.generateCallCount).assertEqual(0);
    });

    // ===== 额外: regenerate 失败恢复 =====
    it('regenerateAsNewCandidate_failure_restores_state', 0, async () => {
      const mock: MockChatServiceForSwipe = new MockChatServiceForSwipe();
      mock.throwOnGenerate = new Error('generate failed');
      const vm: ChatViewModel = makeViewModel(mock);
      vm.canRegenerate = true;
      vm.isSessionReady = true;

      await vm.regenerateAsNewCandidate();

      expect(vm.isGenerating).assertFalse();
      expect(vm.errorMessage.length > 0).assertTrue();
    });
  });
}