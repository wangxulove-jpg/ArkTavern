/**
 * ModelService 设备集成测试
 * 验证 ModelService 对 ProviderConfigStore / ProviderKeyStore / AiProvider 的编排行为。
 * 使用 ControllableKeyStore(内存可控)和 MockProviderFactory 避免真实 Asset Store 和网络依赖。
 * 测试项共 20 项,覆盖 CRUD、事务回滚、Provider 路由、流式代理、临时 Key 清理等。
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
  ModelServiceError,
  ModelServiceErrorType,
  isModelServiceError
} from '../../../main/ets/models/ModelServiceError';
import {
  SecureStorageErrorType,
  createSecureStorageError
} from '../../../main/ets/models/SecureStorageError';

// ===== 测试常量(均为假数据,非真实 API Key) =====

const TEST_PREFS_NAME: string = 'arktavern_test_model_service';
const PROVIDER_A: string = 't16-ms-a';
const PROVIDER_B: string = 't16-ms-b';
const PROVIDER_CLAUDE: string = 't16-ms-claude';
const PROVIDER_GEMINI: string = 't16-ms-gemini';
const PROVIDER_DISABLED: string = 't16-ms-disabled';
const FAKE_KEY_A: string = 'sk-fakemskeyanotrealxxx';
const FAKE_KEY_B: string = 'sk-fakemskeybnotrealyyy';
const FAKE_KEY_TEMP: string = 'sk-fakemskeytempnotrealzzz';

// ===== Mock 类 =====

/** 可控内存 KeyStore,支持注入失败 */
class ControllableKeyStore extends KeyStore {
  private store: Map<string, string> = new Map<string, string>();
  failOnSave: boolean = false;
  failOnRemove: boolean = false;
  async save(alias: string, secret: string): Promise<void> {
    if (this.failOnSave) {
      throw createSecureStorageError(SecureStorageErrorType.PlatformError, 'mock save failure');
    }
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
    if (this.failOnRemove) {
      throw createSecureStorageError(SecureStorageErrorType.PlatformError, 'mock remove failure');
    }
    this.store.delete(alias);
  }
  async exists(alias: string): Promise<boolean> { return this.store.has(alias); }
  peek(alias: string): string | null {
    const v: string | undefined = this.store.get(alias);
    return v !== undefined ? v : null;
  }
  reset(): void {
    this.store.clear();
    this.failOnSave = false;
    this.failOnRemove = false;
  }
}

class MockStreamHandle implements ChatStreamHandle {
  abort(): void {}
  getState(): ChatStreamState { return ChatStreamState.Completed; }
}

/** Mock AiProvider,记录调用并返回可配置结果 */
class MockAiProvider extends AiProvider {
  sendChatCalls: number = 0;
  streamChatCalls: number = 0;
  lastSendChatConfigId: string = '';
  lastStreamChatConfigId: string = '';
  sendChatResponse: ChatResponse = createChatResponse('mock-reply', { finishReason: 'stop', model: 'mock-model' });
  sendChatError: NetworkError | null = null;
  async sendChat(config: ProviderConfig, _request: ChatRequest): Promise<ChatResponse> {
    this.sendChatCalls++;
    this.lastSendChatConfigId = config.id;
    if (this.sendChatError !== null) { throw this.sendChatError; }
    return this.sendChatResponse;
  }
  streamChat(config: ProviderConfig, _request: ChatRequest, callbacks: ChatStreamCallbacks): ChatStreamHandle {
    this.streamChatCalls++;
    this.lastStreamChatConfigId = config.id;
    if (callbacks.onStart !== undefined) { callbacks.onStart(); }
    const delta: ChatDelta = {
      content: 'mock-delta', accumulatedContent: 'mock-delta', finishReason: 'stop', sequence: 0
    };
    callbacks.onDelta(delta);
    const result: ChatStreamResult = {
      content: 'mock-delta', finishReason: 'stop', model: 'mock-model',
      chunkCount: 1, eventCount: 1, deltaCount: 1, receivedDone: true
    };
    callbacks.onComplete(result);
    return new MockStreamHandle();
  }
}

/** Mock Provider 工厂,返回共享的 MockAiProvider */
class MockProviderFactory implements ProviderFactory {
  createdTypes: ProviderType[] = [];
  readonly mockProvider: MockAiProvider = new MockAiProvider();
  create(type: ProviderType): AiProvider {
    this.createdTypes.push(type);
    return this.mockProvider;
  }
  reset(): void {
    this.createdTypes = [];
    this.mockProvider.sendChatCalls = 0;
    this.mockProvider.streamChatCalls = 0;
    this.mockProvider.lastSendChatConfigId = '';
    this.mockProvider.lastStreamChatConfigId = '';
    this.mockProvider.sendChatError = null;
  }
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
  try {
    await env.prefs.clear();
  } catch (e) {
    // 忽略
  }
  env.keyStore.reset();
  env.mockFactory.reset();
}

// ===== 辅助构造 =====

function makeConfig(
  id: string,
  type: ProviderType = ProviderType.OpenAICompatible,
  enabled: boolean = true
): ProviderConfig {
  const now: number = Date.now();
  return new ProviderConfig(
    id, id + '-name', type, 'https://example.test', 'test-model',
    0.7, 1.0, 1024, true, enabled, now, now
  );
}

function makeRequest(): ChatRequest {
  return {
    model: 'test-model',
    messages: [createChatMessage('m1', ChatRole.User, 'Hi', Date.now())],
    temperature: 0.7,
    topP: 1.0,
    maxTokens: 128,
    stream: false
  };
}

// ===== 测试套件 =====

export default function modelServiceDeviceTest() {
  describe('ModelServiceDeviceTest', () => {
    it('createConfig_with_key', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        const got: ProviderConfig | null = await env.modelService.getConfig(PROVIDER_A);
        expect(got !== null).assertTrue();
        const has: boolean = await env.modelService.hasApiKey(PROVIDER_A);
        expect(has).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('createConfig_without_key', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A));
        const got: ProviderConfig | null = await env.modelService.getConfig(PROVIDER_A);
        expect(got !== null).assertTrue();
        const has: boolean = await env.modelService.hasApiKey(PROVIDER_A);
        expect(has).assertFalse();
      } finally {
        await safeClear(env);
      }
    });
    it('createConfig_duplicate', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        let threw: boolean = false;
        try {
          await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        } catch (e) {
          threw = true;
          const err: Object = e as Object;
          expect(isModelServiceError(err)).assertTrue();
          const mse: ModelServiceError = err as ModelServiceError;
          expect(mse.type === ModelServiceErrorType.ConfigAlreadyExists).assertTrue();
        }
        expect(threw).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('createConfig_rollback_on_key_failure', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        env.keyStore.failOnSave = true;
        let threw: boolean = false;
        try {
          await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        } catch (e) {
          threw = true;
          const mse: ModelServiceError = e as ModelServiceError;
          expect(mse.type === ModelServiceErrorType.PartialFailure).assertTrue();
        }
        expect(threw).assertTrue();
        const got: ProviderConfig | null = await env.modelService.getConfig(PROVIDER_A);
        expect(got === null).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('updateConfig_preserve_key', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        const updated: ProviderConfig = makeConfig(PROVIDER_A).withUpdates('new-name');
        await env.modelService.updateConfig(updated);
        const has: boolean = await env.modelService.hasApiKey(PROVIDER_A);
        expect(has).assertTrue();
        const alias: string = 'arktavern.provider.' + PROVIDER_A + '.api-key';
        expect(env.keyStore.peek(alias) === FAKE_KEY_A).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('updateConfig_replace_key', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        const updated: ProviderConfig = makeConfig(PROVIDER_A).withUpdates('new-name');
        await env.modelService.updateConfig(updated, FAKE_KEY_B);
        const alias: string = 'arktavern.provider.' + PROVIDER_A + '.api-key';
        expect(env.keyStore.peek(alias) === FAKE_KEY_B).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('deleteConfig_removes_both', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        await env.modelService.deleteConfig(PROVIDER_A);
        const got: ProviderConfig | null = await env.modelService.getConfig(PROVIDER_A);
        expect(got === null).assertTrue();
        const has: boolean = await env.modelService.hasApiKey(PROVIDER_A);
        expect(has).assertFalse();
      } finally {
        await safeClear(env);
      }
    });
    it('deleteConfig_clears_current', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        await env.modelService.setCurrentConfig(PROVIDER_A);
        await env.modelService.deleteConfig(PROVIDER_A);
        const cur: ProviderConfig | null = await env.modelService.getCurrentConfig();
        expect(cur === null).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('sendChat_no_current_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        let threw: boolean = false;
        try {
          await env.modelService.sendChat(makeRequest());
        } catch (e) {
          threw = true;
          const mse: ModelServiceError = e as ModelServiceError;
          expect(mse.type === ModelServiceErrorType.NoCurrentConfig).assertTrue();
        }
        expect(threw).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('sendChat_disabled_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_DISABLED, ProviderType.OpenAICompatible, false), FAKE_KEY_A);
        await env.modelService.setCurrentConfig(PROVIDER_DISABLED);
        let threw: boolean = false;
        try {
          await env.modelService.sendChat(makeRequest());
        } catch (e) {
          threw = true;
          const mse: ModelServiceError = e as ModelServiceError;
          expect(mse.type === ModelServiceErrorType.ConfigDisabled).assertTrue();
        }
        expect(threw).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('sendChat_unsupported_provider', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_CLAUDE, ProviderType.Claude), FAKE_KEY_A);
        await env.modelService.setCurrentConfig(PROVIDER_CLAUDE);
        let threw: boolean = false;
        try {
          await env.modelService.sendChat(makeRequest());
        } catch (e) {
          threw = true;
          const mse: ModelServiceError = e as ModelServiceError;
          expect(mse.type === ModelServiceErrorType.UnsupportedProvider).assertTrue();
        }
        expect(threw).assertTrue();
        await env.modelService.createConfig(makeConfig(PROVIDER_GEMINI, ProviderType.Gemini), FAKE_KEY_A);
        await env.modelService.setCurrentConfig(PROVIDER_GEMINI);
        let threw2: boolean = false;
        try {
          await env.modelService.sendChat(makeRequest());
        } catch (e) {
          threw2 = true;
          const mse: ModelServiceError = e as ModelServiceError;
          expect(mse.type === ModelServiceErrorType.UnsupportedProvider).assertTrue();
        }
        expect(threw2).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('route_openai_compatible_types', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const types: ProviderType[] = [
          ProviderType.OpenAICompatible, ProviderType.OpenAI,
          ProviderType.DeepSeek, ProviderType.OpenRouter
        ];
        for (let i = 0; i < types.length; i++) {
          const id: string = 't16-route-' + i.toString();
          await env.modelService.createConfig(makeConfig(id, types[i]), FAKE_KEY_A);
          await env.modelService.setCurrentConfig(id);
          await env.modelService.sendChat(makeRequest());
          expect(env.mockFactory.mockProvider.sendChatCalls === i + 1).assertTrue();
        }
      } finally {
        await safeClear(env);
      }
    });
    it('sendChat_calls_provider', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        await env.modelService.setCurrentConfig(PROVIDER_A);
        const resp: ChatResponse = await env.modelService.sendChat(makeRequest());
        expect(env.mockFactory.mockProvider.sendChatCalls === 1).assertTrue();
        expect(env.mockFactory.mockProvider.lastSendChatConfigId === PROVIDER_A).assertTrue();
        expect(resp.content.length > 0).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('streamChat_calls_provider', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        await env.modelService.setCurrentConfig(PROVIDER_A);
        let onCompleteCalled: boolean = false;
        let receivedContent: string = '';
        const callbacks: ChatStreamCallbacks = {
          onDelta: (delta: ChatDelta): void => {
            receivedContent = delta.content;
          },
          onComplete: (_result: ChatStreamResult): void => {
            onCompleteCalled = true;
          },
          onError: (_error: NetworkError): void => {
            // 不期望
          }
        };
        const handle: ChatStreamHandle = env.modelService.streamChat(makeRequest(), callbacks);
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 200);
        });
        expect(env.mockFactory.mockProvider.streamChatCalls === 1).assertTrue();
        expect(env.mockFactory.mockProvider.lastStreamChatConfigId === PROVIDER_A).assertTrue();
        expect(onCompleteCalled).assertTrue();
        expect(receivedContent.length > 0).assertTrue();
        expect(handle.getState() === ChatStreamState.Completed).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('switch_current_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        await env.modelService.createConfig(makeConfig(PROVIDER_B), FAKE_KEY_B);
        await env.modelService.setCurrentConfig(PROVIDER_A);
        await env.modelService.sendChat(makeRequest());
        expect(env.mockFactory.mockProvider.lastSendChatConfigId === PROVIDER_A).assertTrue();
        await env.modelService.setCurrentConfig(PROVIDER_B);
        await env.modelService.sendChat(makeRequest());
        expect(env.mockFactory.mockProvider.lastSendChatConfigId === PROVIDER_B).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('no_apikey_cache', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        const has: boolean = await env.modelService.hasApiKey(PROVIDER_A);
        expect(has).assertTrue();
        await env.modelService.deleteConfig(PROVIDER_A);
        const hasAfterDelete: boolean = await env.modelService.hasApiKey(PROVIDER_A);
        expect(hasAfterDelete).assertFalse();
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_B);
        const alias: string = 'arktavern.provider.' + PROVIDER_A + '.api-key';
        expect(env.keyStore.peek(alias) === FAKE_KEY_B).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('testConnection_no_pollution', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        await env.modelService.testConnection(makeConfig(PROVIDER_A), FAKE_KEY_TEMP);
        const alias: string = 'arktavern.provider.' + PROVIDER_A + '.api-key';
        expect(env.keyStore.peek(alias) === FAKE_KEY_A).assertTrue();
        const tempAlias: string = '__test__.' + PROVIDER_A;
        const tempExists: boolean = await env.keyStore.exists(tempAlias);
        expect(tempExists).assertFalse();
      } finally {
        await safeClear(env);
      }
    });
    it('testConnection_temp_key_cleaned', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.testConnection(makeConfig(PROVIDER_A), FAKE_KEY_TEMP);
        const tempAlias: string = '__test__.' + PROVIDER_A;
        const exists: boolean = await env.keyStore.exists(tempAlias);
        expect(exists).assertFalse();
        expect(env.mockFactory.mockProvider.sendChatCalls === 1).assertTrue();
        expect(env.mockFactory.mockProvider.lastSendChatConfigId === tempAlias).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('deleteConfig_partial_failure', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        env.keyStore.failOnRemove = true;
        let threw: boolean = false;
        try {
          await env.modelService.deleteConfig(PROVIDER_A);
        } catch (e) {
          threw = true;
          const mse: ModelServiceError = e as ModelServiceError;
          expect(mse.type === ModelServiceErrorType.StorageFailure).assertTrue();
        }
        expect(threw).assertTrue();
        const got: ProviderConfig | null = await env.modelService.getConfig(PROVIDER_A);
        expect(got === null).assertTrue();
      } finally {
        await safeClear(env);
      }
    });
    it('no_sensitive_data_in_error', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await env.modelService.createConfig(makeConfig(PROVIDER_A), FAKE_KEY_A);
        env.mockFactory.mockProvider.sendChatError = createNetworkError(
          NetworkErrorType.Server, 'server error with ' + FAKE_KEY_A
        );
        await env.modelService.setCurrentConfig(PROVIDER_A);
        let caughtErr: ModelServiceError | null = null;
        try {
          await env.modelService.sendChat(makeRequest());
        } catch (e) {
          caughtErr = e as ModelServiceError;
        }
        expect(caughtErr !== null).assertTrue();
        const err: ModelServiceError = caughtErr as ModelServiceError;
        expect(err.message.includes(FAKE_KEY_A)).assertFalse();
        if (err.causeMessage !== undefined) {
          expect(err.causeMessage.includes(FAKE_KEY_A)).assertFalse();
        }
      } finally {
        await safeClear(env);
      }
    });
  });
}
