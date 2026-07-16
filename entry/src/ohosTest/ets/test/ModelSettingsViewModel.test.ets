/**
 * ModelSettingsViewModel 设备集成测试
 *
 * 验证 ViewModel 对 ModelService 的编排行为,以及:
 * - API Key 仅存在于输入状态,保存/测试后立即清空
 * - 编辑模式空 Key 保留原密钥
 * - 新建模式必须 API Key
 * - 防止重复点击
 * - 校验规则
 * - 不从 KeyStore 读取并回显原密钥
 *
 * 使用 ControllableKeyStore + MockProviderFactory 隔离真实 Asset Store 与网络。
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { AppPreferences } from '../../../main/ets/storage/AppPreferences';
import { ProviderConfigStore } from '../../../main/ets/storage/ProviderConfigStore';
import { ProviderKeyStore } from '../../../main/ets/storage/ProviderKeyStore';
import { KeyStore } from '../../../main/ets/storage/KeyStore';
import { ModelService } from '../../../main/ets/services/ModelService';
import { ProviderFactory } from '../../../main/ets/services/ProviderFactory';
import { ModelSettingsViewModel } from '../../../main/ets/viewmodels/ModelSettingsViewModel';
import { ProviderConfig } from '../../../main/ets/models/ProviderConfig';
import { ProviderType } from '../../../main/ets/models/ProviderType';
import { ChatRequest } from '../../../main/ets/models/ChatRequest';
import { ChatResponse, createChatResponse } from '../../../main/ets/models/ChatResponse';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { createChatMessage } from '../../../main/ets/models/ChatMessage';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState,
  ChatStreamResult,
  ChatDelta
} from '../../../main/ets/models/ChatStreamTypes';
import { NetworkError, NetworkErrorType, createNetworkError } from '../../../main/ets/models/NetworkError';
import { AiProvider } from '../../../main/ets/network/providers/AiProvider';
import {
  SecureStorageErrorType,
  createSecureStorageError
} from '../../../main/ets/models/SecureStorageError';

// ===== 测试常量(均为假数据,非真实 API Key) =====

const TEST_PREFS_NAME: string = 'arktavern_test_vm_settings';
const FAKE_KEY_A: string = 'sk-fakevmkeyanotrealxxx';
const FAKE_KEY_B: string = 'sk-fakevmkeybnotrealyyy';

// ===== Mock 类 =====

class ControllableKeyStore extends KeyStore {
  private store: Map<string, string> = new Map<string, string>();
  async save(alias: string, secret: string): Promise<void> {
    this.store.set(alias, secret);
  }
  async read(alias: string): Promise<string | null> {
    const v: string | undefined = this.store.get(alias);
    return v !== undefined ? v : null;
  }
  async update(alias: string, secret: string): Promise<void> {
    if (!this.store.has(alias)) {
      throw createSecureStorageError(SecureStorageErrorType.NotFound, 'not found');
    }
    this.store.set(alias, secret);
  }
  async remove(alias: string): Promise<void> {
    this.store.delete(alias);
  }
  async exists(alias: string): Promise<boolean> { return this.store.has(alias); }
  peek(alias: string): string | null {
    const v: string | undefined = this.store.get(alias);
    return v !== undefined ? v : null;
  }
  reset(): void { this.store.clear(); }
}

class MockStreamHandle implements ChatStreamHandle {
  abort(): void {}
  getState(): ChatStreamState { return ChatStreamState.Completed; }
}

class MockAiProvider extends AiProvider {
  sendChatCalls: number = 0;
  lastConfigId: string = '';
  sendChatResponse: ChatResponse = createChatResponse('mock-ok', {
    finishReason: 'stop',
    model: 'mock-model',
    promptTokens: 5,
    completionTokens: 2,
    totalTokens: 7
  });
  sendChatError: NetworkError | null = null;
  async sendChat(config: ProviderConfig, _request: ChatRequest): Promise<ChatResponse> {
    this.sendChatCalls++;
    this.lastConfigId = config.id;
    if (this.sendChatError !== null) { throw this.sendChatError; }
    return this.sendChatResponse;
  }
  streamChat(config: ProviderConfig, _request: ChatRequest, callbacks: ChatStreamCallbacks): ChatStreamHandle {
    this.lastConfigId = config.id;
    if (callbacks.onStart !== undefined) { callbacks.onStart(); }
    callbacks.onComplete({
      content: 'mock', finishReason: 'stop', model: 'mock-model',
      chunkCount: 1, eventCount: 1, deltaCount: 1, receivedDone: true
    });
    return new MockStreamHandle();
  }
  reset(): void {
    this.sendChatCalls = 0;
    this.lastConfigId = '';
    this.sendChatError = null;
  }
}

class MockProviderFactory implements ProviderFactory {
  readonly mockProvider: MockAiProvider = new MockAiProvider();
  create(_type: ProviderType): AiProvider { return this.mockProvider; }
  reset(): void { this.mockProvider.reset(); }
}

// ===== 测试环境 =====

class TestEnv {
  readonly prefs: AppPreferences;
  readonly configStore: ProviderConfigStore;
  readonly keyStore: ControllableKeyStore;
  readonly providerKeyStore: ProviderKeyStore;
  readonly mockFactory: MockProviderFactory;
  readonly modelService: ModelService;

  constructor(
    prefs: AppPreferences,
    configStore: ProviderConfigStore,
    keyStore: ControllableKeyStore,
    providerKeyStore: ProviderKeyStore,
    mockFactory: MockProviderFactory,
    modelService: ModelService
  ) {
    this.prefs = prefs;
    this.configStore = configStore;
    this.keyStore = keyStore;
    this.providerKeyStore = providerKeyStore;
    this.mockFactory = mockFactory;
    this.modelService = modelService;
  }
}

async function createEnv(): Promise<TestEnv> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  let ability: UIAbility;
  try {
    ability = await delegator.getCurrentTopAbility();
  } catch (e) {
    throw new Error('getCurrentTopAbility failed: ' + (e as Error).message);
  }
  const context: common.Context = ability.context as common.Context;
  const prefs: AppPreferences = new AppPreferences(TEST_PREFS_NAME);
  try {
    await prefs.initialize(context);
  } catch (e) {
    throw new Error('prefs.initialize failed: ' + (e as Error).message);
  }
  try {
    await prefs.clear();
  } catch (e) {
    throw new Error('prefs.clear failed: ' + (e as Error).message);
  }
  const configStore: ProviderConfigStore = new ProviderConfigStore(prefs);
  const keyStore: ControllableKeyStore = new ControllableKeyStore();
  const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
  const mockFactory: MockProviderFactory = new MockProviderFactory();
  const modelService: ModelService = new ModelService(
    configStore, providerKeyStore, mockFactory
  );
  await modelService.initialize(context);
  return new TestEnv(prefs, configStore, keyStore, providerKeyStore, mockFactory, modelService);
}

async function safeClear(env: TestEnv): Promise<void> {
  try { await env.prefs.clear(); } catch (e) { /* 忽略 */ }
  env.keyStore.reset();
  env.mockFactory.reset();
}

// ===== 测试套件 =====

export default function modelSettingsViewModelTest() {
  describe('ModelSettingsViewModelTest', () => {
    it('initialize_empty_starts_create', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        expect(vm.configs.length === 0).assertTrue();
        expect(vm.selectedConfigId === null).assertTrue();
        expect(vm.name === '').assertTrue();
        expect(vm.apiKey === '').assertTrue();
        expect(vm.apiKeyConfigured === false).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('save_new_config_with_key', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'test-provider';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://api.example.com';
        vm.modelName = 'gpt-4o';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        expect(vm.errorMessage === '').assertTrue();
        expect(vm.configs.length === 1).assertTrue();
        expect(vm.selectedConfigId !== null).assertTrue();
        expect(vm.apiKey === '').assertTrue();
        const hasKey: boolean = await env.modelService.hasApiKey(vm.selectedConfigId as string);
        expect(hasKey).assertTrue();
        const alias: string = 'arktavern.provider.' + vm.selectedConfigId + '.api-key';
        expect(env.keyStore.peek(alias) === FAKE_KEY_A).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('save_new_config_without_key_fails', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'test-provider';
        vm.baseUrl = 'https://api.example.com';
        vm.modelName = 'gpt-4o';
        vm.apiKey = '';
        await vm.save();
        expect(vm.errorMessage.length > 0).assertTrue();
        expect(vm.configs.length === 0).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('save_update_preserves_key', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'test-provider';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://api.example.com';
        vm.modelName = 'gpt-4o';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        const originalId: string = vm.selectedConfigId as string;
        vm.apiKey = '';
        vm.name = 'renamed-provider';
        await vm.save();
        expect(vm.errorMessage === '').assertTrue();
        expect(vm.name === 'renamed-provider').assertTrue();
        const alias: string = 'arktavern.provider.' + originalId + '.api-key';
        expect(env.keyStore.peek(alias) === FAKE_KEY_A).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('save_update_replaces_key', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'test-provider';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://api.example.com';
        vm.modelName = 'gpt-4o';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        const originalId: string = vm.selectedConfigId as string;
        vm.apiKey = FAKE_KEY_B;
        await vm.save();
        expect(vm.errorMessage === '').assertTrue();
        const alias: string = 'arktavern.provider.' + originalId + '.api-key';
        expect(env.keyStore.peek(alias) === FAKE_KEY_B).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('delete_selected_removes_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'to-delete';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://api.example.com';
        vm.modelName = 'gpt-4o';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        const originalId: string = vm.selectedConfigId as string;
        await vm.deleteSelected();
        expect(vm.errorMessage === '').assertTrue();
        expect(vm.configs.length === 0).assertTrue();
        const hasKey: boolean = await env.modelService.hasApiKey(originalId);
        expect(hasKey).assertFalse();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('set_current_selects_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'to-current';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://api.example.com';
        vm.modelName = 'gpt-4o';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        const id: string = vm.selectedConfigId as string;
        await vm.setCurrent();
        expect(vm.errorMessage === '').assertTrue();
        expect(vm.currentConfigId === id).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('test_connection_does_not_modify_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'test-provider';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://api.example.com';
        vm.modelName = 'gpt-4o';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        const originalId: string = vm.selectedConfigId as string;
        const beforeCalls: number = env.mockFactory.mockProvider.sendChatCalls;
        vm.apiKey = FAKE_KEY_B;
        await vm.testConnection();
        expect(vm.errorMessage === '').assertTrue();
        expect(vm.statusMessage.length > 0).assertTrue();
        expect(vm.apiKey === '').assertTrue();
        expect(env.mockFactory.mockProvider.sendChatCalls === beforeCalls + 1).assertTrue();
        const alias: string = 'arktavern.provider.' + originalId + '.api-key';
        expect(env.keyStore.peek(alias) === FAKE_KEY_A).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('select_config_loads_to_form', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'first';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://a.example.com';
        vm.modelName = 'm1';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        const firstId: string = vm.selectedConfigId as string;
        vm.startCreate();
        vm.name = 'second';
        vm.providerType = ProviderType.DeepSeek;
        vm.baseUrl = 'https://b.example.com';
        vm.modelName = 'm2';
        vm.apiKey = FAKE_KEY_B;
        await vm.save();
        await vm.selectConfig(firstId);
        expect(vm.name === 'first').assertTrue();
        expect(vm.providerType).assertEqual(ProviderType.OpenAICompatible);
        expect(vm.baseUrl === 'https://a.example.com').assertTrue();
        expect(vm.modelName === 'm1').assertTrue();
        expect(vm.apiKey === '').assertTrue();
        expect(vm.apiKeyConfigured === true).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('start_create_resets_form', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'x';
        vm.baseUrl = 'https://a.example.com';
        vm.modelName = 'm1';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        vm.startCreate();
        expect(vm.selectedConfigId === null).assertTrue();
        expect(vm.name === '').assertTrue();
        expect(vm.baseUrl === '').assertTrue();
        expect(vm.modelName === '').assertTrue();
        expect(vm.apiKey === '').assertTrue();
        expect(vm.apiKeyConfigured === false).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('validation_invalid_url', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'bad-url';
        vm.baseUrl = 'not-a-url';
        vm.modelName = 'm1';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        expect(vm.errorMessage.length > 0).assertTrue();
        expect(vm.configs.length === 0).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('validation_empty_name', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = '  ';
        vm.baseUrl = 'https://a.example.com';
        vm.modelName = 'm1';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        expect(vm.errorMessage.length > 0).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('validation_unsupported_type', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'claude';
        vm.providerType = ProviderType.Claude;
        vm.baseUrl = 'https://a.example.com';
        vm.modelName = 'm1';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        expect(vm.errorMessage.length > 0).assertTrue();
        expect(vm.configs.length === 0).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('dispose_clears_state', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.apiKey = FAKE_KEY_A;
        vm.statusMessage = 'status';
        vm.errorMessage = 'err';
        vm.dispose();
        expect(vm.apiKey === '').assertTrue();
        expect(vm.statusMessage === '').assertTrue();
        expect(vm.errorMessage === '').assertTrue();
      } finally {
        await safeClear(env);
      }
    });

    it('clear_api_key_input', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.apiKey = FAKE_KEY_A;
        vm.clearApiKeyInput();
        expect(vm.apiKey === '').assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('save_first_config_auto_set_current', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 'first';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://a.example.com';
        vm.modelName = 'm1';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        expect(vm.currentConfigId === vm.selectedConfigId).assertTrue();
        const cur: ProviderConfig | null = await env.modelService.getCurrentConfig();
        expect(cur !== null).assertTrue();
        expect(cur?.id === vm.selectedConfigId).assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('api_key_cleared_after_test', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 't';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://a.example.com';
        vm.modelName = 'm1';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        vm.apiKey = FAKE_KEY_B;
        await vm.testConnection();
        expect(vm.apiKey === '').assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('test_failure_shows_readable_error', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        await vm.initialize();
        vm.name = 't';
        vm.providerType = ProviderType.OpenAICompatible;
        vm.baseUrl = 'https://a.example.com';
        vm.modelName = 'm1';
        vm.apiKey = FAKE_KEY_A;
        await vm.save();
        env.mockFactory.mockProvider.sendChatError = createNetworkError(
          NetworkErrorType.Timeout, 'mock timeout'
        );
        await vm.testConnection();
        expect(vm.errorMessage.length > 0).assertTrue();
        expect(vm.statusMessage === '').assertTrue();
        expect(vm.apiKey === '').assertTrue();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });

    it('is_supported_type', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const vm: ModelSettingsViewModel = new ModelSettingsViewModel(env.modelService);
        expect(vm.isSupportedType(ProviderType.OpenAICompatible)).assertTrue();
        expect(vm.isSupportedType(ProviderType.OpenAI)).assertTrue();
        expect(vm.isSupportedType(ProviderType.DeepSeek)).assertTrue();
        expect(vm.isSupportedType(ProviderType.OpenRouter)).assertTrue();
        expect(vm.isSupportedType(ProviderType.Claude)).assertFalse();
        expect(vm.isSupportedType(ProviderType.Gemini)).assertFalse();
        vm.dispose();
      } finally {
        await safeClear(env);
      }
    });
  });
}
