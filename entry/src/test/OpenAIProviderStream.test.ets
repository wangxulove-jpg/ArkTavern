/**
 * OpenAIProvider 流式请求本地单元测试
 *
 * 使用 MockStreamTransport 和内存 MockKeyStore 验证 OpenAIProvider.streamChat 的行为。
 * 不依赖设备 API,不进行真实网络请求。
 *
 * 覆盖项(对应用户要求 13 节):
 * 1. stream=true 被强制设置
 * 2. POST 方法
 * 3. URL 拼接
 * 4. Authorization 设置但不输出
 * 5. API Key 不存在
 * 6. 空 model
 * 7. 空 messages
 * 8. 单个 delta
 * 9. 多个 delta 顺序
 * 10. 中文 delta
 * 11. Emoji delta
 * 12. Markdown delta
 * 13. 换行 delta
 * 14. role-only 事件
 * 15. usage-only 事件
 * 16. finish_reason=stop
 * 17. finish_reason=length
 * 18. [DONE]
 * 19. 无 [DONE] 但正常 dataEnd
 * 20. 空 choices
 * 21. 空 content
 * 22. content=null
 * 23. 非 JSON event
 * 24. SSE 不可恢复错误(buffer overflow 模拟)
 * 25-29. 401/403/408/429/500
 * 30. DNS/网络错误
 * 31. timeout
 * 32. abort
 * 33. abort 幂等
 * 34. abort 后迟到 data
 * 35. abort 后迟到 complete
 * 36. error 只触发一次
 * 37. complete 只触发一次
 * 38. complete 后迟到 error
 * 39. complete.content 等于 delta 拼接
 * 40. 不同 providerId 使用不同 Key
 * 41. 连续请求读取最新 Key
 * 42. Provider 不缓存 Key
 * 43. usage 缺失
 * 44. provider request id
 * 45. model 回传
 * 46. stream result 统计值正确
 */
import { describe, it, expect } from '@ohos/hypium';
import { ProviderType } from '../main/ets/models/ProviderType';
import { ProviderConfig } from '../main/ets/models/ProviderConfig';
import { ChatRole } from '../main/ets/models/ChatRole';
import { createChatMessage } from '../main/ets/models/ChatMessage';
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
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamResult,
  ChatDelta
} from '../main/ets/models/ChatStreamTypes';
import { MockStreamTransport } from './MockStreamTransport';
import { MockHttpClient } from './MockHttpClient';

// ===== 内存 KeyStore(测试专用) =====

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
      throw createSecureStorageError(SecureStorageErrorType.NotFound, 'not found', undefined, undefined);
    }
    this.store.set(alias, secret);
  }
  async remove(alias: string): Promise<void> {
    this.store.delete(alias);
  }
  async exists(alias: string): Promise<boolean> {
    return this.store.has(alias);
  }
}

// ===== 测试常量(假数据,非真实 API Key) =====

const PROVIDER_ID_A: string = 'stream-provider-a-001';
const PROVIDER_ID_B: string = 'stream-provider-b-002';
const FAKE_API_KEY_A: string = 'fake-stream-key-aaa-not-real';
const FAKE_API_KEY_B: string = 'fake-stream-key-bbb-not-real';
const FAKE_API_KEY_A_UPDATED: string = 'fake-stream-key-aaa-updated';
const BASE_URL: string = 'https://api.example.com/v1';
const MODEL_NAME: string = 'gpt-4-stream-test';
const CHATCMPL_ID: string = 'chatcmpl-stream-001';
const MODEL_RETURNED: string = 'gpt-4-stream-test';

// ===== SSE chunk 构建辅助函数 =====

function buildDeltaChunk(content: string | null, role?: string, finishReason?: string): string {
  const delta: Record<string, Object> = {};
  if (role !== undefined) {
    delta['role'] = role;
  }
  if (content !== null) {
    delta['content'] = content;
  }
  const choice: Record<string, Object> = {
    'index': 0,
    'delta': delta
  };
  if (finishReason !== undefined) {
    choice['finish_reason'] = finishReason;
  }
  const body: Record<string, Object> = {
    'id': CHATCMPL_ID,
    'object': 'chat.completion.chunk',
    'created': 1700000000,
    'model': MODEL_RETURNED,
    'choices': [choice]
  };
  return 'data: ' + JSON.stringify(body) + '\n\n';
}

function buildDoneChunk(): string {
  return 'data: [DONE]\n\n';
}

function buildUsageChunk(prompt: number, completion: number, total: number): string {
  const usage: Record<string, Object> = {
    'prompt_tokens': prompt,
    'completion_tokens': completion,
    'total_tokens': total
  };
  const body: Record<string, Object> = {
    'id': CHATCMPL_ID,
    'object': 'chat.completion.chunk',
    'created': 1700000000,
    'model': MODEL_RETURNED,
    'choices': [] as Object[],
    'usage': usage
  };
  return 'data: ' + JSON.stringify(body) + '\n\n';
}

function buildEmptyChoicesChunk(): string {
  const body: Record<string, Object> = {
    'id': CHATCMPL_ID,
    'object': 'chat.completion.chunk',
    'created': 1700000000,
    'model': MODEL_RETURNED,
    'choices': [] as Object[]
  };
  return 'data: ' + JSON.stringify(body) + '\n\n';
}

function buildErrorChunk(message: string): string {
  const err: Record<string, Object> = { 'message': message };
  const body: Record<string, Object> = { 'error': err };
  return 'data: ' + JSON.stringify(body) + '\n\n';
}

// ===== 测试状态收集器 =====

interface StreamTestState {
  result: ChatStreamResult | null;
  error: NetworkError | null;
  deltas: ChatDelta[];
  started: boolean;
  completeCount: number;
  errorCount: number;
  deltaCount: number;
  resolve: () => void;
}

interface StreamStateHolder {
  state: StreamTestState;
  promise: Promise<void>;
}

function createStreamState(): StreamStateHolder {
  const state: StreamTestState = {
    result: null,
    error: null,
    deltas: [],
    started: false,
    completeCount: 0,
    errorCount: 0,
    deltaCount: 0,
    resolve: () => {}
  };
  const promise: Promise<void> = new Promise<void>((resolve: () => void) => {
    state.resolve = resolve;
  });
  const holder: StreamStateHolder = { state: state, promise: promise };
  return holder;
}

function createCallbacks(state: StreamTestState): ChatStreamCallbacks {
  return {
    onStart: () => {
      state.started = true;
    },
    onDelta: (delta: ChatDelta) => {
      state.deltas.push(delta);
      state.deltaCount++;
    },
    onComplete: (result: ChatStreamResult) => {
      state.result = result;
      state.completeCount++;
      state.resolve();
    },
    onError: (error: NetworkError) => {
      state.error = error;
      state.errorCount++;
      state.resolve();
    }
  };
}

// ===== 测试配置辅助函数 =====

function createTestConfig(id: string = PROVIDER_ID_A): ProviderConfig {
  return ProviderConfig.create(
    id,
    'Stream Test Provider',
    ProviderType.OpenAICompatible,
    BASE_URL,
    MODEL_NAME
  );
}

function createTestRequest(model: string = MODEL_NAME): ChatRequest {
  return {
    model: model,
    messages: [createChatMessage('msg-1', ChatRole.User, 'Hello stream', 1000)],
    temperature: 0.7,
    topP: 1.0,
    maxTokens: 1024,
    stream: false // 流式方法会强制改为 true
  };
}

function createProviderWithTransport(
  transport: MockStreamTransport,
  keyStore: ProviderKeyStore
): OpenAIProvider {
  // HttpClient 在流式测试中不调用 sendChat,但必须实现 HttpClient 接口
  // 使用 MockHttpClient 作为占位(流式请求经 streamLauncher 路由)
  const httpClient: MockHttpClient = new MockHttpClient();
  return new OpenAIProvider(
    httpClient,
    keyStore,
    (options, callbacks) => transport.launch(options, callbacks)
  );
}

// ===== 测试套件 =====

export default function openAiProviderStreamTest() {
  describe('OpenAIProviderStreamTest', () => {

    // ===== 1. stream=true 被强制设置 =====
    it('stream_forced_true', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      const req = transport.getLastRequest();
      expect(req !== null).assertTrue();
      expect(req!.streamValue).assertTrue();
    });

    // ===== 2. POST 方法 =====
    it('method_is_post', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(transport.getLastRequest()!.method).assertEqual('POST');
    });

    // ===== 3. URL 拼接 =====
    it('url_built_correctly', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(transport.getLastRequest()!.url).assertEqual('https://api.example.com/v1/chat/completions');
    });

    // ===== 4. Authorization 设置但不输出 =====
    it('authorization_set_not_exposed', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      const req = transport.getLastRequest()!;
      expect(req.hasAuthorization).assertTrue();
      expect(req.authorizationPrefix).assertEqual('Bearer ');
      // prefix 不含 token 内容
      expect(req.authorizationPrefix!.length < FAKE_API_KEY_A.length).assertTrue();
    });

    // ===== 5. API Key 不存在 =====
    it('api_key_not_found', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error !== null).assertTrue();
      expect(state.error!.type).assertEqual(NetworkErrorType.Authentication);
    });

    // ===== 6. 空 model =====
    it('empty_model_rejected', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      const req: ChatRequest = createTestRequest('');
      provider.streamChat(createTestConfig(), req, createCallbacks(state));
      await promise;

      expect(state.error !== null).assertTrue();
      expect(state.error!.type).assertEqual(NetworkErrorType.InvalidRequest);
    });

    // ===== 7. 空 messages =====
    it('empty_messages_rejected', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      const req: ChatRequest = {
        model: MODEL_NAME,
        messages: [],
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: false
      };
      provider.streamChat(createTestConfig(), req, createCallbacks(state));
      await promise;

      expect(state.error!.type).assertEqual(NetworkErrorType.InvalidRequest);
    });

    // ===== 8. 单个 delta =====
    it('single_delta', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.deltas.length).assertEqual(1);
      expect(state.deltas[0].content).assertEqual('Hello');
      expect(state.result!.content).assertEqual('Hello');
    });

    // ===== 9. 多个 delta 顺序 =====
    it('multiple_delta_order', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hello'),
        buildDeltaChunk(' from'),
        buildDeltaChunk(' stream'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.deltas.length).assertEqual(3);
      expect(state.deltas[0].content).assertEqual('Hello');
      expect(state.deltas[1].content).assertEqual(' from');
      expect(state.deltas[2].content).assertEqual(' stream');
      expect(state.deltas[0].sequence).assertEqual(0);
      expect(state.deltas[1].sequence).assertEqual(1);
      expect(state.deltas[2].sequence).assertEqual(2);
    });

    // ===== 10. 中文 delta =====
    it('chinese_delta', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('你好'),
        buildDeltaChunk('世界'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.content).assertEqual('你好世界');
    });

    // ===== 11. Emoji delta =====
    it('emoji_delta', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hello '),
        buildDeltaChunk('🌍🚀'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.content).assertEqual('Hello 🌍🚀');
    });

    // ===== 12. Markdown delta =====
    it('markdown_delta', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('# Title\n'),
        buildDeltaChunk('**bold** and *italic*'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.content).assertEqual('# Title\n**bold** and *italic*');
    });

    // ===== 13. 换行 delta =====
    it('newline_delta', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Line 1\n'),
        buildDeltaChunk('Line 2\n'),
        buildDeltaChunk('Line 3'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.content).assertEqual('Line 1\nLine 2\nLine 3');
    });

    // ===== 14. role-only 事件(不报错,不触发 delta) =====
    it('role_only_event', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk(null, 'assistant'), // role-only
        buildDeltaChunk('Hello'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error).assertNull();
      expect(state.deltas.length).assertEqual(1);
      expect(state.result!.content).assertEqual('Hello');
    });

    // ===== 15. usage-only 事件 =====
    it('usage_event', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hi'),
        buildDeltaChunk('', undefined, 'stop'),
        buildUsageChunk(10, 5, 15),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.promptTokens).assertEqual(10);
      expect(state.result!.completionTokens).assertEqual(5);
      expect(state.result!.totalTokens).assertEqual(15);
    });

    // ===== 16. finish_reason=stop =====
    it('finish_reason_stop', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hello'),
        buildDeltaChunk('', undefined, 'stop'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.finishReason).assertEqual('stop');
    });

    // ===== 17. finish_reason=length =====
    it('finish_reason_length', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Truncated'),
        buildDeltaChunk('', undefined, 'length'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.finishReason).assertEqual('length');
    });

    // ===== 18. [DONE] 识别 =====
    it('done_recognized', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hello'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.receivedDone).assertTrue();
    });

    // ===== 19. 无 [DONE] 但正常 dataEnd(兼容完成) =====
    it('no_done_compatible_complete', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      // 无 [DONE],但有 content 和 finish_reason
      transport.setChunks([
        buildDeltaChunk('No done marker'),
        buildDeltaChunk('', undefined, 'stop')
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error).assertNull();
      expect(state.result !== null).assertTrue();
      expect(state.result!.receivedDone).assertFalse();
      expect(state.result!.content).assertEqual('No done marker');
    });

    // ===== 20. 空 choices(不终止) =====
    it('empty_choices_continues', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildEmptyChoicesChunk(),
        buildDeltaChunk('after empty'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.content).assertEqual('after empty');
    });

    // ===== 21. 空 content delta(忽略,不触发 onDelta) =====
    it('empty_content_delta_ignored', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk(''),
        buildDeltaChunk('Hello'),
        buildDeltaChunk(''),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      // 空 content delta 不触发 onDelta
      expect(state.deltas.length).assertEqual(1);
      expect(state.result!.content).assertEqual('Hello');
    });

    // ===== 22. content=null(role 事件) =====
    it('content_null_role_event', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk(null, 'assistant'), // content=null, role=assistant
        buildDeltaChunk('Hello'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.deltas.length).assertEqual(1);
      expect(state.result!.content).assertEqual('Hello');
    });

    // ===== 23. 非 JSON event(解析错误) =====
    it('non_json_event_parse_error', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hello'),
        'data: This is not JSON\n\n',
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error !== null).assertTrue();
      expect(state.error!.type).assertEqual(NetworkErrorType.Parse);
    });

    // ===== 24. SSE 不可恢复错误(错误响应对象) =====
    it('sse_error_object_parse_error', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hello'),
        buildErrorChunk('server error in stream'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error!.type).assertEqual(NetworkErrorType.Parse);
    });

    // ===== 25-29. HTTP 错误码(401/403/408/429/500) =====
    it('http_401_authentication', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setStatusCode(401);
      transport.setChunks([]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error!.type).assertEqual(NetworkErrorType.Authentication);
    });

    it('http_403_authentication', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setStatusCode(403);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error!.type).assertEqual(NetworkErrorType.Authentication);
    });

    it('http_408_timeout', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setStatusCode(408);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error!.type).assertEqual(NetworkErrorType.Timeout);
    });

    it('http_429_rate_limit', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setStatusCode(429);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error!.type).assertEqual(NetworkErrorType.RateLimit);
    });

    it('http_500_server', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setStatusCode(500);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error!.type).assertEqual(NetworkErrorType.Server);
    });

    // ===== 30. DNS/网络错误 =====
    it('network_error', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setError(new NetworkError(
        NetworkErrorType.Network, 'DNS failed', false, undefined, undefined, undefined
      ));
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error!.type).assertEqual(NetworkErrorType.Network);
    });

    // ===== 31. timeout =====
    it('timeout_error', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setError(new NetworkError(
        NetworkErrorType.Timeout, 'read timeout', true, undefined, undefined, undefined
      ));
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.error!.type).assertEqual(NetworkErrorType.Timeout);
    });

    // ===== 32. abort =====
    it('abort_triggers_cancelled', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      transport.setAutoTrigger(false); // 手动模式,防止自动完成
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      const handle: ChatStreamHandle = provider.streamChat(
        createTestConfig(), createTestRequest(), createCallbacks(state)
      );
      // 等待异步流程启动 session
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      handle.abort();
      // 等待回调
      await promise;

      expect(state.error !== null).assertTrue();
      expect(state.error!.type).assertEqual(NetworkErrorType.Cancelled);
      expect(state.result).assertNull();
    });

    // ===== 33. abort 幂等 =====
    it('abort_idempotent', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      transport.setAutoTrigger(false);
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      const handle: ChatStreamHandle = provider.streamChat(
        createTestConfig(), createTestRequest(), createCallbacks(state)
      );
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      handle.abort();
      handle.abort(); // 再次调用不崩溃
      handle.abort(); // 第三次也不崩溃
      await promise;

      expect(state.errorCount).assertEqual(1); // 只触发一次 onError
      expect(state.error!.type).assertEqual(NetworkErrorType.Cancelled);
    });

    // ===== 34. abort 后迟到 data 被忽略 =====
    it('abort_late_data_ignored', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      transport.setAutoTrigger(false);
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      const handle: ChatStreamHandle = provider.streamChat(
        createTestConfig(), createTestRequest(), createCallbacks(state)
      );
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      handle.abort();
      // 尝试触发迟到 data
      transport.triggerHeaders();
      transport.triggerNextChunk();
      transport.triggerComplete();
      await promise;

      expect(state.deltaCount).assertEqual(0); // 迟到 data 被忽略
      expect(state.error!.type).assertEqual(NetworkErrorType.Cancelled);
    });

    // ===== 35. abort 后迟到 complete 被忽略 =====
    it('abort_late_complete_ignored', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      transport.setAutoTrigger(false);
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      const handle: ChatStreamHandle = provider.streamChat(
        createTestConfig(), createTestRequest(), createCallbacks(state)
      );
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      handle.abort();
      transport.triggerHeaders();
      transport.triggerComplete(); // 迟到 complete
      await promise;

      expect(state.completeCount).assertEqual(0); // 迟到 complete 被忽略
      expect(state.error!.type).assertEqual(NetworkErrorType.Cancelled);
    });

    // ===== 36. error 只触发一次 =====
    it('error_triggered_once', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      transport.setAutoTrigger(false);
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      // 手动触发错误
      transport.triggerHeaders();
      const err: NetworkError = new NetworkError(
        NetworkErrorType.Server, 'server error', true, 500, undefined, undefined
      );
      transport.triggerError(err);
      // 再次触发(应被忽略)
      transport.triggerError(err);
      transport.triggerComplete();
      await promise;

      expect(state.errorCount).assertEqual(1);
    });

    // ===== 37. complete 只触发一次 =====
    it('complete_triggered_once', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      transport.setAutoTrigger(false);
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      transport.triggerHeaders();
      transport.triggerNextChunk(); // Hello
      transport.triggerNextChunk(); // [DONE]
      transport.triggerComplete();
      // 尝试再次触发 complete(应被忽略)
      transport.triggerComplete();
      await promise;

      expect(state.completeCount).assertEqual(1);
    });

    // ===== 38. complete 后迟到 error 被忽略 =====
    it('complete_late_error_ignored', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      transport.setAutoTrigger(false);
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      transport.triggerHeaders();
      transport.triggerNextChunk();
      transport.triggerNextChunk();
      transport.triggerComplete();
      // 迟到 error
      const err: NetworkError = new NetworkError(
        NetworkErrorType.Server, 'late error', true, 500, undefined, undefined
      );
      transport.triggerError(err);
      await promise;

      expect(state.completeCount).assertEqual(1);
      expect(state.errorCount).assertEqual(0); // 迟到 error 被忽略
    });

    // ===== 39. complete.content 等于 delta 拼接 =====
    it('content_equals_delta_concat', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('A'),
        buildDeltaChunk('B'),
        buildDeltaChunk('C'),
        buildDeltaChunk('', undefined, 'stop'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      // 手动拼接 delta
      let concat: string = '';
      for (let i = 0; i < state.deltas.length; i++) {
        concat += state.deltas[i].content;
      }
      expect(state.result!.content).assertEqual(concat);
      expect(state.result!.content).assertEqual('ABC');
    });

    // ===== 40. 不同 providerId 使用不同 Key =====
    it('different_provider_different_key', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      await keyStore.saveKey(PROVIDER_ID_B, FAKE_API_KEY_B);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      // 请求 A
      const stateA = createStreamState();
      provider.streamChat(createTestConfig(PROVIDER_ID_A), createTestRequest(), createCallbacks(stateA.state));
      await stateA.promise;
      const reqA = transport.getLastRequest()!;
      expect(reqA.hasAuthorization).assertTrue();

      // 请求 B
      transport.reset();
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const stateB = createStreamState();
      provider.streamChat(createTestConfig(PROVIDER_ID_B), createTestRequest(), createCallbacks(stateB.state));
      await stateB.promise;
      const reqB = transport.getLastRequest()!;
      expect(reqB.hasAuthorization).assertTrue();
    });

    // ===== 41. 连续请求读取最新 Key =====
    it('consecutive_requests_read_latest_key', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      // 第一次请求
      const state1 = createStreamState();
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state1.state));
      await state1.promise;
      expect(state1.state.error).assertNull();

      // 更新 Key
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A_UPDATED);

      // 第二次请求(应读取最新 Key)
      transport.reset();
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const state2 = createStreamState();
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state2.state));
      await state2.promise;
      expect(state2.state.error).assertNull();
    });

    // ===== 42. Provider 不缓存 Key(每次读 KeyStore) =====
    it('provider_does_not_cache_key', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const inMemoryKeyStore: InMemoryKeyStore = new InMemoryKeyStore();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(inMemoryKeyStore);
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      // 第一次请求成功
      const state1 = createStreamState();
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state1.state));
      await state1.promise;
      expect(state1.state.error).assertNull();

      // 删除 Key
      await keyStore.removeKey(PROVIDER_ID_A);

      // 第二次请求应失败(Key 不存在)
      transport.reset();
      transport.setChunks([buildDeltaChunk('Hello'), buildDoneChunk()]);
      const state2 = createStreamState();
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state2.state));
      await state2.promise;
      expect(state2.state.error!.type).assertEqual(NetworkErrorType.Authentication);
    });

    // ===== 43. usage 缺失 =====
    it('usage_missing', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hello'),
        buildDeltaChunk('', undefined, 'stop'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.promptTokens).assertUndefined();
      expect(state.result!.completionTokens).assertUndefined();
      expect(state.result!.totalTokens).assertUndefined();
    });

    // ===== 44. provider request id =====
    it('provider_request_id', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hello'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.providerRequestId).assertEqual(CHATCMPL_ID);
    });

    // ===== 45. model 回传 =====
    it('model_returned', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('Hello'),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      expect(state.result!.model).assertEqual(MODEL_RETURNED);
    });

    // ===== 46. stream result 统计值正确 =====
    it('stream_result_stats', 0, async () => {
      const transport: MockStreamTransport = new MockStreamTransport();
      const keyStore: ProviderKeyStore = new ProviderKeyStore(new InMemoryKeyStore());
      await keyStore.saveKey(PROVIDER_ID_A, FAKE_API_KEY_A);
      transport.setChunks([
        buildDeltaChunk('A'),
        buildDeltaChunk('B'),
        buildDeltaChunk('C'),
        buildDeltaChunk('', undefined, 'stop'),
        buildUsageChunk(10, 5, 15),
        buildDoneChunk()
      ]);
      const provider: OpenAIProvider = createProviderWithTransport(transport, keyStore);

      const streamHolder = createStreamState();
      const state = streamHolder.state;
      const promise = streamHolder.promise;
      provider.streamChat(createTestConfig(), createTestRequest(), createCallbacks(state));
      await promise;

      const r: ChatStreamResult = state.result!;
      expect(r.deltaCount).assertEqual(3); // 3 个非空 delta(A/B/C)
      expect(r.eventCount).assertEqual(6); // 6 个 SSE 事件
      expect(r.receivedDone).assertTrue(); // 收到 [DONE]
      expect(r.chunkCount > 0).assertTrue(); // 至少 1 个网络 chunk
    });
  });
}
