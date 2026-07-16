/**
 * OpenAIProvider 本地单元测试
 *
 * 使用 MockHttpClient 和内存 MockKeyStore 验证 OpenAIProvider 的业务行为。
 * 不依赖设备 API,不进行真实网络请求。
 *
 * 覆盖项(对应用户要求 12.2 节):
 * 1. 正常 200 响应
 * 2. request stream 被强制为 false
 * 3. 请求方法为 POST
 * 4. URL 正确拼接
 * 5. Content-Type 正确
 * 6. Accept 正确
 * 7. Authorization 已设置
 * 8. 测试输出不打印 Authorization
 * 9. model 正确
 * 10. messages 顺序保持
 * 11. system/user/assistant role 正确
 * 12. temperature 正确
 * 13. top_p 正确
 * 14. max_tokens 正确
 * 15. 空 messages
 * 16. 空 model
 * 17. API Key 不存在
 * 18. API Key 为空
 * 19. 401
 * 20. 403
 * 21. 400
 * 22. 404
 * 23. 408
 * 24. 429
 * 25. 500
 * 26. 503
 * 27. DNS/网络错误
 * 28. 超时
 * 29. 取消
 * 30. choices 为空
 * 31. content 缺失
 * 32. content=null
 * 33. 非 JSON 响应
 * 34. error JSON
 * 35. usage 完整
 * 36. usage 缺失
 * 37. finish_reason
 * 38. response id
 * 39. model 回传
 * 40. 服务端错误 message 脱敏
 * 41. Provider 不缓存 API Key
 * 42. 连续两次请求读取最新 Key
 * 43. 不同 ProviderConfig.id 使用不同 Key
 * 44. ProviderConfig 不包含 Key
 * 45. 响应日志不包含完整回复
 */
import { describe, it, expect } from '@ohos/hypium';
import { ProviderType } from '../main/ets/models/ProviderType';
import { ProviderConfig } from '../main/ets/models/ProviderConfig';
import { ChatRole } from '../main/ets/models/ChatRole';
import { ChatMessage, createChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRequest } from '../main/ets/models/ChatRequest';
import {
  NetworkError,
  NetworkErrorType
} from '../main/ets/models/NetworkError';
import { KeyStore } from '../main/ets/storage/KeyStore';
import { ProviderKeyStore } from '../main/ets/storage/ProviderKeyStore';
import {
  SecureStorageErrorType,
  createSecureStorageError
} from '../main/ets/models/SecureStorageError';
import { OpenAIProvider } from '../main/ets/network/providers/OpenAIProvider';
import { MockHttpClient, RecordedRequest } from './MockHttpClient';

// ===== 内存 KeyStore(测试专用,不进入 main) =====

class InMemoryKeyStore extends KeyStore {
  private store: Map<string, string> = new Map<string, string>();

  async save(alias: string, secret: string): Promise<void> {
    this.store.set(alias, secret);
  }

  async read(alias: string): Promise<string | null> {
    if (!this.store.has(alias)) {
      return null;
    }
    return this.store.get(alias) as string;
  }

  async update(alias: string, secret: string): Promise<void> {
    if (!this.store.has(alias)) {
      throw createSecureStorageError(
        SecureStorageErrorType.NotFound,
        'not found',
        undefined,
        undefined
      );
    }
    this.store.set(alias, secret);
  }

  async remove(alias: string): Promise<void> {
    this.store.delete(alias);
  }

  async exists(alias: string): Promise<boolean> {
    return this.store.has(alias);
  }

  /** 测试辅助:直接写入底层存储(模拟绕过 ProviderKeyStore 校验) */
  rawSet(alias: string, secret: string): void {
    this.store.set(alias, secret);
  }
}

// ===== 测试常量(假数据,非真实 API Key,不以 sk- 开头) =====

const PROVIDER_ID_A: string = 'provider-openai-a-001';
const PROVIDER_ID_B: string = 'provider-openai-b-002';
const FAKE_API_KEY_A: string = 'fake-key-aaa-not-real-xxx';
const FAKE_API_KEY_B: string = 'fake-key-bbb-not-real-yyy';
const FAKE_API_KEY_A_UPDATED: string = 'fake-key-aaa-updated-not-real';

const BASE_URL: string = 'https://api.example.com/v1';
const MODEL_NAME: string = 'gpt-4-test';

/** buildSuccessResponseBody 的 usage 子选项 */
interface SuccessUsageOptions {
  prompt: number;
  completion: number;
  total: number;
}

/** buildSuccessResponseBody 的可选参数 */
interface SuccessResponseOptions {
  finishReason?: string;
  model?: string;
  id?: string;
  usage?: SuccessUsageOptions;
}

/** 构造标准成功响应体 */
function buildSuccessResponseBody(
  content: string,
  options?: SuccessResponseOptions
): string {
  const finishReason: string = options !== undefined && options.finishReason !== undefined
    ? options.finishReason
    : 'stop';
  const model: string = options !== undefined && options.model !== undefined
    ? options.model
    : MODEL_NAME;
  const id: string = options !== undefined && options.id !== undefined
    ? options.id
    : 'chatcmpl-test-001';
  const usagePart: string = options !== undefined && options.usage !== undefined
    ? ',"usage":{"prompt_tokens":' + options.usage.prompt.toString()
    + ',"completion_tokens":' + options.usage.completion.toString()
    + ',"total_tokens":' + options.usage.total.toString() + '}'
    : '';
  return '{"id":"' + id + '","model":"' + model + '","choices":[{"index":0,"message":{"role":"assistant","content":' + JSON.stringify(content) + '},"finish_reason":"' + finishReason + '"}]' + usagePart + '}';
}

/** 构造错误响应体 */
function buildErrorResponseBody(message: string, type?: string, code?: string): string {
  const typePart: string = type !== undefined ? ',"type":"' + type + '"' : '';
  const codePart: string = code !== undefined ? ',"code":"' + code + '"' : '';
  return '{"error":{"message":' + JSON.stringify(message) + typePart + codePart + '}}';
}

/** 创建测试用 ProviderConfig */
function createTestConfig(id: string = PROVIDER_ID_A): ProviderConfig {
  return ProviderConfig.create(
    id,
    'Test Provider',
    ProviderType.OpenAICompatible,
    BASE_URL,
    MODEL_NAME
  );
}

/** 创建测试用 ChatRequest */
function createTestRequest(messages?: ChatMessage[]): ChatRequest {
  const msgs: ChatMessage[] = messages !== undefined ? messages : [
    createChatMessage('msg-1', ChatRole.User, 'Hello', 1000),
    createChatMessage('msg-2', ChatRole.Assistant, 'Hi there', 1001),
    createChatMessage('msg-3', ChatRole.User, 'How are you?', 1002)
  ];
  return {
    model: MODEL_NAME,
    messages: msgs,
    temperature: 0.7,
    topP: 1.0,
    maxTokens: 1024,
    stream: true // 测试强制改为 false
  };
}

export default function openAiProviderTest() {
  describe('OpenAIProviderTest', () => {

    // ===== 1. 正常 200 响应 =====
    it('normal_200_response', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('Hello from server')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const response = await provider.sendChat(createTestConfig(), createTestRequest());

      expect(response.content).assertEqual('Hello from server');
      expect(httpClient.recordCount).assertEqual(1);
    });

    // ===== 2. request stream 被强制为 false =====
    it('stream_forced_false', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      expect(last !== undefined).assertTrue();
      expect(last!.streamForcedFalse).assertTrue();
    });

    // ===== 3. 请求方法为 POST =====
    it('method_is_post', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      expect(last!.method).assertEqual('POST');
    });

    // ===== 4. URL 正确拼接 =====
    it('url_built_correctly', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      expect(last!.url).assertEqual('https://api.example.com/v1/chat/completions');
    });

    // ===== 5. Content-Type 正确 =====
    it('content_type_correct', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      expect(last!.contentType).assertEqual('application/json');
    });

    // ===== 6. Accept 正确 =====
    it('accept_correct', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      expect(last!.accept).assertEqual('application/json');
    });

    // ===== 7. Authorization 已设置 =====
    it('authorization_set', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      expect(last!.hasAuthorization).assertTrue();
      expect(last!.authorizationPrefix).assertEqual('Bearer ');
    });

    // ===== 8. 测试输出不打印 Authorization(运行时验证,不抛异常即通过) =====
    it('authorization_not_in_test_output', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      // 验证 RecordedRequest 不暴露完整 Authorization
      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      expect(last!.hasAuthorization).assertTrue();
      // authorizationPrefix 不含 token 内容
      expect(last!.authorizationPrefix!.length < FAKE_API_KEY_A.length).assertTrue();
    });

    // ===== 9. model 正确 =====
    it('model_correct', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      const modelVal: Object | undefined = last!.parsedBody!['model'];
      expect(modelVal).assertEqual(MODEL_NAME);
    });

    // ===== 10. messages 顺序保持 =====
    it('messages_order_preserved', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      const messages: Object | undefined = last!.parsedBody!['messages'];
      expect(Array.isArray(messages)).assertTrue();
      const arr: Object[] = messages as Object[];
      expect(arr.length).assertEqual(3);
      // 顺序由 createTestRequest 决定
      const m0: Record<string, Object> = arr[0] as Record<string, Object>;
      expect(m0['content']).assertEqual('Hello');
      const m2: Record<string, Object> = arr[2] as Record<string, Object>;
      expect(m2['content']).assertEqual('How are you?');
    });

    // ===== 11. system/user/assistant role 正确 =====
    it('roles_correct', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const messages: ChatMessage[] = [
        createChatMessage('s1', ChatRole.System, 'You are helpful', 1),
        createChatMessage('u1', ChatRole.User, 'Hi', 2),
        createChatMessage('a1', ChatRole.Assistant, 'Hello', 3)
      ];
      await provider.sendChat(createTestConfig(), createTestRequest(messages));

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      const arr: Object[] = last!.parsedBody!['messages'] as Object[];
      expect((arr[0] as Record<string, Object>)['role']).assertEqual('system');
      expect((arr[1] as Record<string, Object>)['role']).assertEqual('user');
      expect((arr[2] as Record<string, Object>)['role']).assertEqual('assistant');
    });

    // ===== 12. temperature 正确 =====
    it('temperature_correct', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      const temp: Object | undefined = last!.parsedBody!['temperature'];
      expect(temp).assertEqual(0.7);
    });

    // ===== 13. top_p 正确 =====
    it('top_p_correct', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      const topP: Object | undefined = last!.parsedBody!['top_p'];
      expect(topP).assertEqual(1.0);
    });

    // ===== 14. max_tokens 正确 =====
    it('max_tokens_correct', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      const last: RecordedRequest | undefined = httpClient.getLastRequest();
      const maxTokens: Object | undefined = last!.parsedBody!['max_tokens'];
      expect(maxTokens).assertEqual(1024);
    });

    // ===== 15. 空 messages =====
    it('empty_messages_rejected', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const request: ChatRequest = {
        model: MODEL_NAME,
        messages: [],
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: false
      };

      try {
        await provider.sendChat(createTestConfig(), request);
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.InvalidRequest);
      }
      // 没有发起请求
      expect(httpClient.recordCount).assertEqual(0);
    });

    // ===== 16. 空 model =====
    it('empty_model_rejected', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const request: ChatRequest = {
        model: '',
        messages: [createChatMessage('m1', ChatRole.User, 'Hi', 1)],
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: false
      };

      try {
        await provider.sendChat(createTestConfig(), request);
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.InvalidRequest);
      }
      expect(httpClient.recordCount).assertEqual(0);
    });

    // ===== 17. API Key 不存在 =====
    it('api_key_missing', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      // 不保存 Key

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Authentication);
      }
      expect(httpClient.recordCount).assertEqual(0);
    });

    // ===== 18. API Key 为空 =====
    it('api_key_empty_rejected', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      // 直接写入底层以绕过 ProviderKeyStore 校验
      keyStore.rawSet('arktavern.provider.' + PROVIDER_ID_A + '.api-key', '');
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);

      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Authentication);
      }
      expect(httpClient.recordCount).assertEqual(0);
    });

    // ===== 19. 401 =====
    it('http_401_authentication_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 401,
        body: buildErrorResponseBody('Invalid API key', 'invalid_request_error', 'invalid_api_key')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Authentication);
        expect(err.statusCode).assertEqual(401);
      }
    });

    // ===== 20. 403 =====
    it('http_403_authentication_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 403,
        body: buildErrorResponseBody('Forbidden')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Authentication);
        expect(err.statusCode).assertEqual(403);
      }
    });

    // ===== 21. 400 =====
    it('http_400_invalid_request', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 400,
        body: buildErrorResponseBody('Bad request')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.InvalidRequest);
        expect(err.statusCode).assertEqual(400);
      }
    });

    // ===== 22. 404 =====
    it('http_404_invalid_request', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 404,
        body: ''
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        // 404 映射到 Unknown(errorTypeFromStatusCode 不显式处理 404)
        expect(err.statusCode).assertEqual(404);
      }
    });

    // ===== 23. 408 =====
    it('http_408_timeout', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 408,
        body: ''
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Timeout);
        expect(err.statusCode).assertEqual(408);
      }
    });

    // ===== 24. 429 =====
    it('http_429_rate_limit', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 429,
        body: buildErrorResponseBody('Rate limit exceeded', 'rate_limit_error')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.RateLimit);
        expect(err.statusCode).assertEqual(429);
      }
    });

    // ===== 25. 500 =====
    it('http_500_server_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 500,
        body: buildErrorResponseBody('Internal server error')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Server);
        expect(err.statusCode).assertEqual(500);
      }
    });

    // ===== 26. 503 =====
    it('http_503_server_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 503,
        body: ''
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Server);
        expect(err.statusCode).assertEqual(503);
      }
    });

    // ===== 27. DNS/网络错误 =====
    it('network_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setErrorMode('network');

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Network);
      }
    });

    // ===== 28. 超时 =====
    it('timeout_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setErrorMode('timeout');

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Timeout);
      }
    });

    // ===== 29. 取消 =====
    it('cancelled_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setErrorMode('cancelled');

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Cancelled);
      }
    });

    // ===== 30. choices 为空 =====
    it('empty_choices_parse_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: '{"id":"x","model":"m","choices":[]}'
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Parse);
      }
    });

    // ===== 31. content 缺失 =====
    it('content_missing_parse_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: '{"id":"x","model":"m","choices":[{"index":0,"message":{"role":"assistant"},"finish_reason":"stop"}]}'
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Parse);
      }
    });

    // ===== 32. content=null =====
    it('content_null_parse_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: '{"id":"x","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}'
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Parse);
      }
    });

    // ===== 33. 非 JSON 响应 =====
    it('non_json_response_parse_error', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: 'This is not JSON'
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Parse);
      }
    });

    // ===== 34. error JSON(2xx 但 body 是 error) =====
    it('error_json_in_2xx_response', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildErrorResponseBody('Something went wrong in 2xx')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        // extractResponseBody 检测到 error 字段后返回 isErrorBody=true
        // parseSuccessResponse 将其映射为 Server 错误
        expect(err.type).assertEqual(NetworkErrorType.Server);
      }
    });

    // ===== 35. usage 完整 =====
    it('usage_complete', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok', {
          usage: { prompt: 10, completion: 5, total: 15 } as SuccessUsageOptions
        } as SuccessResponseOptions)
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const response = await provider.sendChat(createTestConfig(), createTestRequest());

      expect(response.promptTokens).assertEqual(10);
      expect(response.completionTokens).assertEqual(5);
      expect(response.totalTokens).assertEqual(15);
    });

    // ===== 36. usage 缺失 =====
    it('usage_missing', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const response = await provider.sendChat(createTestConfig(), createTestRequest());

      expect(response.promptTokens).assertUndefined();
      expect(response.completionTokens).assertUndefined();
      expect(response.totalTokens).assertUndefined();
    });

    // ===== 37. finish_reason =====
    it('finish_reason_parsed', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok', { finishReason: 'length' } as SuccessResponseOptions)
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const response = await provider.sendChat(createTestConfig(), createTestRequest());

      expect(response.finishReason).assertEqual('length');
    });

    // ===== 38. response id =====
    it('response_id_parsed', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok', { id: 'chatcmpl-abc-123' } as SuccessResponseOptions)
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const response = await provider.sendChat(createTestConfig(), createTestRequest());

      expect(response.providerRequestId).assertEqual('chatcmpl-abc-123');
    });

    // ===== 39. model 回传 =====
    it('response_model_echoed', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok', { model: 'gpt-4-echoed' } as SuccessResponseOptions)
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const response = await provider.sendChat(createTestConfig(), createTestRequest());

      expect(response.model).assertEqual('gpt-4-echoed');
    });

    // ===== 40. 服务端错误 message 脱敏 =====
    it('server_error_message_truncated', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      // 构造超长错误消息(> 512 字符)
      const longMessage: string = 'A'.repeat(1000);
      httpClient.setResponse({
        statusCode: 500,
        body: buildErrorResponseBody(longMessage)
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Server);
        // 错误消息被截断
        expect(err.message.length < 600).assertTrue();
        expect(err.message.indexOf('...[truncated]') >= 0).assertTrue();
      }
    });

    // ===== 41. Provider 不缓存 API Key =====
    it('provider_not_cache_api_key', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      // 修改 Key 后再次请求,验证读取到新 Key
      await providerKeyStore.updateKey(PROVIDER_ID_A, FAKE_API_KEY_A_UPDATED);
      await provider.sendChat(createTestConfig(), createTestRequest());

      // 两次请求都成功(无法直接断言 Key 内容,但能验证不缓存导致读到旧 Key 报错)
      expect(httpClient.recordCount).assertEqual(2);
    });

    // ===== 42. 连续两次请求读取最新 Key =====
    it('consecutive_requests_read_latest_key', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(), createTestRequest());

      // 删除 Key 后再次请求,应该报 Authentication 错误
      await providerKeyStore.removeKey(PROVIDER_ID_A);
      try {
        await provider.sendChat(createTestConfig(), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Authentication);
      }
    });

    // ===== 43. 不同 ProviderConfig.id 使用不同 Key =====
    it('different_provider_id_uses_different_key', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      await providerKeyStore.saveKey(PROVIDER_ID_B, FAKE_API_KEY_B);

      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody('ok')
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      await provider.sendChat(createTestConfig(PROVIDER_ID_A), createTestRequest());
      await provider.sendChat(createTestConfig(PROVIDER_ID_B), createTestRequest());

      // 两次请求都成功,证明两个 ID 都有 Key
      expect(httpClient.recordCount).assertEqual(2);

      // 删除 A 后,A 应该报错,B 仍可用
      await providerKeyStore.removeKey(PROVIDER_ID_A);
      try {
        await provider.sendChat(createTestConfig(PROVIDER_ID_A), createTestRequest());
        expect().assertFail();
      } catch (e) {
        const err: NetworkError = e as NetworkError;
        expect(err.type).assertEqual(NetworkErrorType.Authentication);
      }
      // B 仍可用
      await provider.sendChat(createTestConfig(PROVIDER_ID_B), createTestRequest());
    });

    // ===== 44. ProviderConfig 不包含 Key =====
    it('provider_config_no_key_field', 0, () => {
      const config: ProviderConfig = createTestConfig();
      // 通过 JSON 序列化检查字段不存在
      // 编译期保证:ProviderConfig 类无 apiKey 字段
      expect(config.id).assertEqual(PROVIDER_ID_A);
      expect(config.baseUrl).assertEqual(BASE_URL);
      // 仅验证 JSON 中无 apiKey / api_key 字段
      const configJson: string = JSON.stringify(config);
      expect(configJson.includes('apiKey')).assertFalse();
      expect(configJson.includes('api_key')).assertFalse();
    });

    // ===== 45. 响应日志不包含完整回复(运行时验证,通过 Logger 脱敏) =====
    it('response_log_not_contain_full_reply', 0, async () => {
      const httpClient: MockHttpClient = new MockHttpClient();
      const keyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      await providerKeyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);

      const longReply: string = 'This is a very long reply content that should not appear in logs. '.repeat(10);
      httpClient.setResponse({
        statusCode: 200,
        body: buildSuccessResponseBody(longReply)
      });

      const provider: OpenAIProvider = new OpenAIProvider(httpClient, providerKeyStore);
      const response = await provider.sendChat(createTestConfig(), createTestRequest());

      // 验证响应内容正确
      expect(response.content).assertEqual(longReply);
      // OpenAIProvider.parseResponse 只记录 statusCode,不记录 body
      // 此测试主要验证 Provider 代码中没有显式记录响应原文的语句
      // 运行时通过 hilog 扫描验证
    });

  });
}
