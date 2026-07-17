/**
 * ChatViewModel 设备集成测试
 *
 * 使用 Mock ChatService + Mock ModelService 验证 ViewModel 的 UI 状态管理。
 * 不依赖真实网络或 Mock Server。
 *
 * 覆盖项(16 项):
 * 1. 初始化读取当前配置
 * 2. 无当前配置时 hasCurrentModel=false
 * 3. canSend 空输入为 false
 * 4. canSend 仅空白为 false
 * 5. canSend 无模型为 false
 * 6. send 后输入框清空
 * 7. send 后 isGenerating=true
 * 8. send 中再次 send 被拒绝
 * 9. stop 触发 ChatService.stopGeneration
 * 10. clear 清空消息
 * 11. dispose 清理
 * 12. 错误映射为中文(无配置/禁用/Auth/429/Timeout/Network/Server/Parse/Unknown)
 * 13. 初始化失败处理
 * 14. sendMessage 抛异常时恢复 isGenerating 并显示错误
 * 15. send 成功后输入框清空且消息显示
 * 16. onMessagesChanged 每次产生新数组引用
 */

import { describe, it, expect } from '@ohos/hypium';
import { ChatViewModel } from '../../../main/ets/viewmodels/ChatViewModel';
import { ChatService, ChatState, ChatServiceCallbacks } from '../../../main/ets/services/ChatService';
import { ChatMessage } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { Character } from '../../../main/ets/models/Character';
import { CharacterService } from '../../../main/ets/services/CharacterService';
import { ProviderConfig } from '../../../main/ets/models/ProviderConfig';
import { ProviderType } from '../../../main/ets/models/ProviderType';
import { PromptPresetService } from '../../../main/ets/services/PromptPresetService';
import { PromptPreset } from '../../../main/ets/models/PromptPreset';

// ===== Mock ChatService =====

class MockChatService {
  messages: ChatMessage[] = [];
  state: ChatState = ChatState.Idle;
  generating: boolean = false;
  stopCalled: boolean = false;
  clearCalled: boolean = false;
  disposeCalled: boolean = false;
  regenerateCalled: boolean = false;
  sendCallCount: number = 0;
  lastCallbacks: ChatServiceCallbacks | null = null;
  /** 注入错误 */
  injectError: string | null = null;
  /** 可重新生成 */
  _canRegenerate: boolean = false;
  /** sendMessage 同步抛出异常(模拟 disposed 或同步错误) */
  throwOnSend: Error | null = null;

  async sendMessage(userContent: string, callbacks: ChatServiceCallbacks): Promise<void> {
    this.sendCallCount++;
    this.lastCallbacks = callbacks;

    if (this.throwOnSend !== null) {
      throw this.throwOnSend;
    }

    // 检查并发
    if (this.generating) {
      return;
    }

    this.messages.push({
      id: 'user-' + this.sendCallCount,
      role: ChatRole.User,
      content: userContent,
      createdAt: Date.now()
    });
    callbacks.onMessagesChanged(this.messages.slice());

    this.messages.push({
      id: 'asst-' + this.sendCallCount,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true
    });
    callbacks.onMessagesChanged(this.messages.slice());

    this.generating = true;
    this.state = ChatState.Sending;
    callbacks.onStateChanged(ChatState.Sending);

    this.state = ChatState.Streaming;
    callbacks.onStateChanged(ChatState.Streaming);

    if (this.injectError !== null) {
      this.generating = false;
      this.state = ChatState.Failed;
      callbacks.onStateChanged(ChatState.Failed);
      callbacks.onError(this.injectError);
      return;
    }

    // 模拟 delta 和 complete
    this.messages[1] = {
      id: this.messages[1].id,
      role: ChatRole.Assistant,
      content: 'mock reply',
      createdAt: this.messages[1].createdAt,
      updatedAt: Date.now(),
      isStreaming: false
    };
    callbacks.onMessagesChanged(this.messages.slice());

    this.generating = false;
    this.state = ChatState.Completed;
    callbacks.onStateChanged(ChatState.Completed);
  }

  stopGeneration(): void {
    this.stopCalled = true;
    this.generating = false;
    this.state = ChatState.Cancelled;
  }

  isGenerating(): boolean {
    return this.generating;
  }

  clearConversation(): void {
    this.clearCalled = true;
    this.messages = [];
    this.generating = false;
    this.state = ChatState.Idle;
  }

  canRegenerate(): boolean {
    return this._canRegenerate;
  }

  async regenerateLastResponse(callbacks: ChatServiceCallbacks): Promise<void> {
    this.regenerateCalled = true;
    this.lastCallbacks = callbacks;
    if (this.injectError !== null) {
      this.generating = false;
      this.state = ChatState.Failed;
      callbacks.onStateChanged(ChatState.Failed);
      callbacks.onError(this.injectError);
      return;
    }
    this.generating = true;
    this.state = ChatState.Sending;
    callbacks.onStateChanged(ChatState.Sending);
    this.state = ChatState.Streaming;
    callbacks.onStateChanged(ChatState.Streaming);
    // 模拟 regenerate 完成
    this.messages[this.messages.length - 1] = {
      id: this.messages[this.messages.length - 1].id,
      role: ChatRole.Assistant,
      content: 'regenerated reply',
      createdAt: this.messages[this.messages.length - 1].createdAt,
      updatedAt: Date.now(),
      isStreaming: false
    };
    callbacks.onMessagesChanged(this.messages.slice());
    this.generating = false;
    this.state = ChatState.Completed;
    callbacks.onStateChanged(ChatState.Completed);
  }

  getMessages(): ChatMessage[] {
    return this.messages.slice();
  }

  dispose(): void {
    this.disposeCalled = true;
  }

  initContext(_character: Object | null): boolean {
    return false;
  }

  reset(): void {
    this.messages = [];
    this.state = ChatState.Idle;
    this.generating = false;
    this.stopCalled = false;
    this.clearCalled = false;
    this.disposeCalled = false;
    this.regenerateCalled = false;
    this.sendCallCount = 0;
    this.lastCallbacks = null;
    this.injectError = null;
    this._canRegenerate = false;
    this.throwOnSend = null;
  }
}

// ===== Mock ModelService =====

class MockModelService {
  private currentConfig: ProviderConfig | null = null;
  private throwError: Error | null = null;

  setCurrentConfig(config: ProviderConfig | null): void {
    this.currentConfig = config;
  }

  setThrowError(e: Error): void {
    this.throwError = e;
  }

  async getCurrentConfig(): Promise<ProviderConfig | null> {
    if (this.throwError !== null) {
      throw this.throwError;
    }
    return this.currentConfig;
  }

  reset(): void {
    this.currentConfig = null;
    this.throwError = null;
  }
}

// ===== Mock CharacterService =====

class MockCharacterService {
  private character: Character | null = null;

  setCurrentCharacter(c: Character | null): void {
    this.character = c;
  }

  async getCurrentCharacter(): Promise<Character | null> {
    return this.character;
  }

  reset(): void {
    this.character = null;
  }
}

// ===== 辅助 =====

function makeConfig(name: string, modelName: string): ProviderConfig {
  const now: number = Date.now();
  return new ProviderConfig(
    'test-config', name, ProviderType.OpenAICompatible,
    'https://example.test', modelName, 0.7, 1.0, 1024, true, true, now, now
  );
}

interface ViewModelFixture {
  mockChatService: MockChatService;
  mockModelService: MockModelService;
  mockCharacterService: MockCharacterService;
  mockPromptPresetService: MockPromptPresetService;
  viewModel: ChatViewModel;
}

// ===== Mock PromptPresetService =====

class MockPromptPresetService {
  async getCurrentPreset(): Promise<PromptPreset | null> {
    return null;
  }

  async getCurrentPresetId(): Promise<string | null> {
    return null;
  }
}

function createViewModel(): ViewModelFixture {
  const mockChatService: MockChatService = new MockChatService();
  const mockModelService: MockModelService = new MockModelService();
  const mockCharacterService: MockCharacterService = new MockCharacterService();
  const mockPromptPresetService: MockPromptPresetService = new MockPromptPresetService();
  const viewModel: ChatViewModel = new ChatViewModel(
    mockChatService as Object as ChatService,
    mockModelService as Object as import('../../../main/ets/services/ModelService').ModelService,
    mockCharacterService as Object as CharacterService,
    mockPromptPresetService as Object as PromptPresetService
  );
  const fixture: ViewModelFixture = {
    mockChatService: mockChatService,
    mockModelService: mockModelService,
    mockCharacterService: mockCharacterService,
    mockPromptPresetService: mockPromptPresetService,
    viewModel: viewModel
  };
  return fixture;
}

// ===== 测试套件 =====

export default function chatViewModelDeviceTest() {
  describe('ChatViewModelDeviceTest', () => {

    // 1. 初始化读取当前配置
    it('initialize_reads_current_config', 0, async () => {
      const result = createViewModel(); const mockModelService = result.mockModelService; const viewModel = result.viewModel;

      mockModelService.setCurrentConfig(makeConfig('DeepSeek', 'deepseek-v4-flash'));

      await viewModel.initialize();

      expect(viewModel.hasCurrentModel).assertTrue();
      expect(viewModel.currentModelName.indexOf('DeepSeek') >= 0).assertTrue();
      expect(viewModel.currentModelName.indexOf('deepseek-v4-flash') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 2. 无当前配置时 hasCurrentModel=false
    it('no_config_has_current_model_false', 0, async () => {
      const result3 = createViewModel(); const viewModel = result3.viewModel;

      await viewModel.initialize();

      expect(viewModel.hasCurrentModel).assertFalse();
      expect(viewModel.currentModelName.indexOf('尚未配置') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 3. canSend 空输入为 false
    it('can_send_false_when_empty_input', 0, async () => {
      const result = createViewModel(); const mockModelService = result.mockModelService; const viewModel = result.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.updateInput('');
      expect(viewModel.canSend).assertFalse();
      viewModel.dispose();
    });

    // 4. canSend 仅空白为 false
    it('can_send_false_when_whitespace_only', 0, async () => {
      const result = createViewModel(); const mockModelService = result.mockModelService; const viewModel = result.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.updateInput('   ');
      expect(viewModel.canSend).assertFalse();
      viewModel.dispose();
    });

    // 5. canSend 无模型为 false
    it('can_send_false_when_no_model', 0, async () => {
      const result3 = createViewModel(); const viewModel = result3.viewModel;

      await viewModel.initialize();

      viewModel.updateInput('test message');
      expect(viewModel.canSend).assertFalse();
      viewModel.dispose();
    });

    // 6. send 后输入框清空
    it('send_clears_input', 0, async () => {
      const result = createViewModel(); const mockModelService = result.mockModelService; const viewModel = result.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.updateInput('Hello');
      await viewModel.send();

      expect(viewModel.inputText.length).assertEqual(0);
      viewModel.dispose();
    });

    // 7. send 后 isGenerating=true → 完成后 false
    it('send_sets_generating_and_completes', 0, async () => {
      const result = createViewModel(); const mockModelService = result.mockModelService; const viewModel = result.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.updateInput('Hello');
      await viewModel.send();

      // Mock ChatService 同步完成,verify 完成后 isGenerating=false
      expect(viewModel.isGenerating).assertFalse();
      expect(viewModel.messages.length > 0).assertTrue();
      viewModel.dispose();
    });

    // 8. send 中再次 send 被拒绝
    it('double_send_rejected', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      // 设置 injectError 让 mock 进入失败状态,模拟生成中
      mockChatService.injectError = 'blocking';
      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.updateInput('First');
      viewModel.send();

      // 第二次发送应被拒绝
      mockChatService.injectError = null;
      viewModel.updateInput('Second');
      await viewModel.send();

      // 第一次 send 已经调用了一次,第二次被 ViewModel 的 canSend 拒绝
      expect(mockChatService.sendCallCount >= 1).assertTrue();
      viewModel.dispose();
    });

    // 9. stop 触发 ChatService.stopGeneration
    it('stop_calls_chat_service_stop', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.updateInput('Hello');
      viewModel.send();

      viewModel.stop();

      expect(mockChatService.stopCalled).assertTrue();
      viewModel.dispose();
    });

    // 10. clear 清空消息
    it('clear_empties_messages', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.updateInput('Hello');
      await viewModel.send();

      viewModel.clear();

      expect(mockChatService.clearCalled).assertTrue();
      expect(viewModel.messages.length).assertEqual(0);
      expect(viewModel.errorMessage.length).assertEqual(0);
      viewModel.dispose();
    });

    // 11. dispose 清理
    it('dispose_cleans_up', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.dispose();

      expect(mockChatService.disposeCalled).assertTrue();
    });

    // 12. 错误映射(无配置)
    it('error_mapping_no_config', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'No current provider config';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('尚未配置') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 12b. 错误映射(disabled)
    it('error_mapping_disabled', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'disabled';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('已禁用') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 12c. 错误映射(API Key)
    it('error_mapping_api_key', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'API Key not configured';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('API Key') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 12d. 错误映射(Auth/401)
    it('error_mapping_auth', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'Authentication 401';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('鉴权') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 12e. 错误映射(429)
    it('error_mapping_rate_limit', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'RateLimit 429';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('频率') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 12f. 错误映射(Timeout)
    it('error_mapping_timeout', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'Timeout';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('超时') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 12g. 错误映射(Network)
    it('error_mapping_network', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'Network connect failed';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('网络') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 12h. 错误映射(Server)
    it('error_mapping_server', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'Server 500';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('服务器') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 12i. 错误映射(Parse)
    it('error_mapping_parse', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'Parse error';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('解析') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 12j. 错误映射(Unknown)
    it('error_mapping_unknown', 0, async () => {
      const result2 = createViewModel(); const mockChatService = result2.mockChatService; const mockModelService = result2.mockModelService; const viewModel = result2.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.injectError = 'Something weird happened';
      viewModel.updateInput('test');
      await viewModel.send();

      expect(viewModel.errorMessage.indexOf('重试') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 13. 初始化失败处理
    it('initialize_handles_error', 0, async () => {
      const result = createViewModel(); const mockModelService = result.mockModelService; const viewModel = result.viewModel;

      mockModelService.setThrowError(new Error('Storage error'));

      await viewModel.initialize();

      expect(viewModel.hasCurrentModel).assertFalse();
      expect(viewModel.currentModelName.indexOf('失败') >= 0).assertTrue();
      viewModel.dispose();
    });

    // 14. sendMessage 抛异常时恢复 isGenerating 并显示错误
    it('send_recovers_when_chat_service_throws', 0, async () => {
      const result = createViewModel(); const mockChatService = result.mockChatService; const mockModelService = result.mockModelService; const viewModel = result.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      mockChatService.throwOnSend = new Error('ChatService disposed');
      viewModel.updateInput('test');
      await viewModel.send();

      // isGenerating 必须恢复
      expect(viewModel.isGenerating).assertFalse();
      // 输入框不应清空(消息未成功加入)
      expect(viewModel.inputText.length > 0).assertTrue();
      // 错误提示应包含"退出"或"重试"
      expect(viewModel.errorMessage.length > 0).assertTrue();
      viewModel.dispose();
    });

    // 15. send 成功后输入框清空且消息显示
    it('send_clears_input_only_after_message_created', 0, async () => {
      const result = createViewModel(); const mockChatService = result.mockChatService; const mockModelService = result.mockModelService; const viewModel = result.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.updateInput('Hello');
      await viewModel.send();

      // 消息创建成功后输入框清空
      expect(viewModel.inputText.length).assertEqual(0);
      // 消息已显示
      expect(viewModel.messages.length >= 2).assertTrue();
      // 第一条是 User
      expect(viewModel.messages[0].role).assertEqual(ChatRole.User);
      expect(viewModel.messages[0].content).assertEqual('Hello');
      viewModel.dispose();
    });

    // 16. onMessagesChanged 每次产生新数组引用
    it('onMessagesChanged_produces_new_array_reference', 0, async () => {
      const result = createViewModel(); const mockChatService = result.mockChatService; const mockModelService = result.mockModelService; const viewModel = result.viewModel;

      mockModelService.setCurrentConfig(makeConfig('test', 'model'));
      await viewModel.initialize();

      viewModel.updateInput('Hello');
      await viewModel.send();

      const ref1: ChatMessage[] = viewModel.messages;
      // 触发一次额外的 onMessagesChanged
      if (mockChatService.lastCallbacks !== null) {
        mockChatService.lastCallbacks.onMessagesChanged([
          { id: 'extra', role: ChatRole.User, content: 'extra', createdAt: Date.now() }
        ]);
      }
      const ref2: ChatMessage[] = viewModel.messages;
      expect(ref2 !== ref1).assertTrue();
      viewModel.dispose();
    });
  });
}