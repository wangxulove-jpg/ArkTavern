/**
 * OpenAIProvider 设备集成测试
 *
 * 需要在模拟器或真机运行,使用 HarmonyHttpClient 真实 HTTP 客户端。
 * 测试前需启动 tools/sse_mock_server.py 并配置 hdc rport tcp:8765 tcp:8765。
 *
 * 测试分两类:
 * A. 本地 Mock Server 测试:
 *    1. 正常返回
 *    2. 401
 *    3. 429
 *    4. 500
 *    5. 非法 JSON
 *    6. choices 为空
 *    7. usage 完整
 *    8. Provider 解析正确
 *
 * B. 真实 OpenAI-compatible 测试端点:
 *    标记为手工待执行(不硬编码 Key)。
 *
 * 注意:默认测试地址为 http://127.0.0.1:8765(配合 hdc rport tcp:8765 tcp:8765)。
 * API Key 通过运行时 AssetStoreKeyStore 注入(测试用假 Key)。
 */

import { describe, it, expect } from '@ohos/hypium';
import { HarmonyHttpClient } from '../../../main/ets/network/core/HarmonyHttpClient';
import { OpenAIProvider } from '../../../main/ets/network/providers/OpenAIProvider';
import { ProviderType } from '../../../main/ets/models/ProviderType';
import { ProviderConfig } from '../../../main/ets/models/ProviderConfig';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { createChatMessage } from '../../../main/ets/models/ChatMessage';
import { ChatRequest } from '../../../main/ets/models/ChatRequest';
import {
  NetworkError,
  NetworkErrorType
} from '../../../main/ets/models/NetworkError';
import { ProviderKeyStore } from '../../../main/ets/storage/ProviderKeyStore';
import { AssetStoreKeyStore } from '../../../main/ets/storage/AssetStoreKeyStore';

/** Mock Server 基础 URL */
const MOCK_BASE_URL: string = 'http://127.0.0.1:8765/v1';
/** Mock Server Chat Completions 路径(相对 /v1 已在 baseUrl 中) */
/** Provider ID(测试专用,清理后不留残余) */
const TEST_PROVIDER_ID: string = 't14-device-openai-provider';
/** 假 API Key(非真实,不以 sk- 开头) */
const FAKE_API_KEY: string = 'fake-test-key-not-real-xxx-aaa';
/** 模型名 */
const TEST_MODEL: string = 'gpt-4-test';

/** 创建测试用 ProviderConfig */
function createTestConfig(baseUrl: string = MOCK_BASE_URL): ProviderConfig {
  return ProviderConfig.create(
    TEST_PROVIDER_ID,
    'T-1.4 Device Test Provider',
    ProviderType.OpenAICompatible,
    baseUrl,
    TEST_MODEL
  );
}

/** 创建测试用 ChatRequest,可通过 model 参数触发 Mock Server 场景 */
function createTestRequest(model: string = TEST_MODEL): ChatRequest {
  return {
    model: model,
    messages: [
      createChatMessage('msg-1', ChatRole.User, 'Hello from device test', Date.now())
    ],
    temperature: 0.7,
    topP: 1.0,
    maxTokens: 1024,
    stream: false
  };
}

/**
 * 测试前清理 Asset Store 中的测试数据,避免历史残留影响。
 */
async function cleanupTestKey(): Promise<void> {
  try {
    const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
    await keyStore.remove('arktavern.provider.' + TEST_PROVIDER_ID + '.api-key');
  } catch (e) {
    // 忽略(不存在也算成功)
  }
}

/**
 * 设置测试用 API Key。
 */
async function setupTestKey(): Promise<void> {
  const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
  const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
  await providerKeyStore.replaceKey(TEST_PROVIDER_ID, FAKE_API_KEY);
}

export default function openAiProviderDeviceTest() {
  describe('OpenAIProviderDeviceTest', () => {

    // A.1 正常返回
    it('mock_normal_response', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
        const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
        const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

        const response = await provider.sendChat(createTestConfig(), createTestRequest());
        expect(response.content.length > 0).assertTrue();
      } finally {
        await cleanupTestKey();
      }
    });

    // A.2 401
    it('mock_401_authentication_error', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
        const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
        const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

        // 通过 model 名 mock-401-test 触发 Mock Server 401 场景
        try {
          await provider.sendChat(createTestConfig(), createTestRequest('mock-401-test'));
          expect().assertFail();
        } catch (e) {
          if (e instanceof NetworkError) {
            expect(e.type).assertEqual(NetworkErrorType.Authentication);
            expect(e.statusCode).assertEqual(401);
          } else {
            expect().assertFail();
          }
        }
      } finally {
        await cleanupTestKey();
      }
    });

    // A.3 429
    it('mock_429_rate_limit', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
        const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
        const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

        // 通过 model 名 mock-429-test 触发 Mock Server 429 场景
        try {
          await provider.sendChat(createTestConfig(), createTestRequest('mock-429-test'));
          expect().assertFail();
        } catch (e) {
          if (e instanceof NetworkError) {
            expect(e.type).assertEqual(NetworkErrorType.RateLimit);
            expect(e.statusCode).assertEqual(429);
          } else {
            expect().assertFail();
          }
        }
      } finally {
        await cleanupTestKey();
      }
    });

    // A.4 500
    it('mock_500_server_error', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
        const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
        const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

        // 通过 model 名 mock-500-test 触发 Mock Server 500 场景
        try {
          await provider.sendChat(createTestConfig(), createTestRequest('mock-500-test'));
          expect().assertFail();
        } catch (e) {
          if (e instanceof NetworkError) {
            expect(e.type).assertEqual(NetworkErrorType.Server);
            expect(e.statusCode).assertEqual(500);
          } else {
            expect().assertFail();
          }
        }
      } finally {
        await cleanupTestKey();
      }
    });

    // A.5 非法 JSON
    it('mock_invalid_json_parse_error', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
        const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
        const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

        // 通过 model 名 mock-invalid-test 触发 Mock Server invalid-json 场景
        try {
          await provider.sendChat(createTestConfig(), createTestRequest('mock-invalid-test'));
          expect().assertFail();
        } catch (e) {
          if (e instanceof NetworkError) {
            expect(e.type).assertEqual(NetworkErrorType.Parse);
          } else {
            expect().assertFail();
          }
        }
      } finally {
        await cleanupTestKey();
      }
    });

    // A.6 choices 为空
    it('mock_empty_choices_parse_error', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
        const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
        const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

        // 通过 model 名 mock-empty-test 触发 Mock Server empty-choices 场景
        try {
          await provider.sendChat(createTestConfig(), createTestRequest('mock-empty-test'));
          expect().assertFail();
        } catch (e) {
          if (e instanceof NetworkError) {
            expect(e.type).assertEqual(NetworkErrorType.Parse);
          } else {
            expect().assertFail();
          }
        }
      } finally {
        await cleanupTestKey();
      }
    });

    // A.7 usage 完整
    it('mock_usage_complete', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
        const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
        const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

        // 通过 model 名 mock-usage-test 触发 Mock Server usage 场景
        const response = await provider.sendChat(createTestConfig(), createTestRequest('mock-usage-test'));
        expect(response.promptTokens).assertEqual(10);
        expect(response.completionTokens).assertEqual(5);
        expect(response.totalTokens).assertEqual(15);
      } finally {
        await cleanupTestKey();
      }
    });

    // A.8 Provider 解析正确(验证 content、model、finishReason、id)
    it('mock_provider_parsing', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
        const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
        const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

        const response = await provider.sendChat(createTestConfig(), createTestRequest());
        expect(response.content.length > 0).assertTrue();
        // Mock 服务器默认返回 model=gpt-4-test, finish_reason=stop, id=chatcmpl-mock-001
        expect(response.model).assertEqual(TEST_MODEL);
        expect(response.finishReason).assertEqual('stop');
        expect(response.providerRequestId).assertEqual('chatcmpl-mock-001');
      } finally {
        await cleanupTestKey();
      }
    });

    // A.9 API Key 不存在
    it('api_key_not_configured', 0, async () => {
      await cleanupTestKey();
      try {
        const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
        const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
        const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

        try {
          await provider.sendChat(createTestConfig(), createTestRequest());
          expect().assertFail();
        } catch (e) {
          if (e instanceof NetworkError) {
            expect(e.type).assertEqual(NetworkErrorType.Authentication);
          } else {
            expect().assertFail();
          }
        }
      } finally {
        // 已清理
      }
    });

    // B. 真实 OpenAI-compatible 测试端点(手工待执行)
    // 标记为 manual,不自动运行
    it('manual_real_endpoint_test', 1, () => {
      // 此测试标记为 manual(level=1)
      // 真实端点测试需要:
      // 1. 配置运行时输入真实 baseUrl 和 API Key(通过 ohosTest 安全注入)
      // 2. 禁止硬编码 Key
      // 3. 测试后必须删除 Asset Store 中的测试数据
      // 由于本测试环境无法安全注入真实 Key,标记为待手工执行
      expect(true).assertTrue();
    });
  });
}
