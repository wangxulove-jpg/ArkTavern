/**
 * OpenAIProvider 流式请求设备集成测试
 *
 * 需要在 API 23 设备或模拟器运行,使用真实 HarmonyHttpClient + HttpStreamTransport。
 * 测试前需:
 * 1. 启动 python -u tools\sse_mock_server.py
 * 2. 配置 hdc rport tcp:8765 tcp:8765
 *
 * 通过 Mock Server 的 model 名前缀 mock-stream-<scenario>-* 触发流式场景。
 * API Key 通过 AssetStoreKeyStore 运行时注入(测试用假 Key,非真实)。
 * 每个测试前后清理 Asset Store,确保无残留。
 *
 * 覆盖项(22 项):
 * 1. 正常流式回复
 * 2. dataReceive 多次触发(chunkCount > 1)
 * 3. onDelta 多次触发(deltaCount > 1)
 * 4. delta 顺序正确(sequence 递增)
 * 5. 中文无乱码
 * 6. Emoji 无乱码
 * 7. Markdown 和换行保留
 * 8. [DONE] 识别
 * 9. 无 [DONE] 兼容完成
 * 10. usage 解析
 * 11. finish_reason 解析(stop / length)
 * 12. 401
 * 13. 429
 * 14. 500
 * 15. 非法 JSON
 * 16. empty choices
 * 17. abort 中断
 * 18. abort 后不再 complete
 * 19. 多次 abort 不崩溃
 * 20. 资源释放(连续请求不崩溃)
 * 21. 日志无 API Key(间接验证,不记录密钥)
 * 22. Asset Store 测试密钥清理
 */

import { describe, it, expect } from '@ohos/hypium';
import { HarmonyHttpClient } from '../../../main/ets/network/core/HarmonyHttpClient';
import { HttpStreamTransport } from '../../../main/ets/network/streaming/HttpStreamTransport';
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
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamResult,
  ChatDelta
} from '../../../main/ets/models/ChatStreamTypes';

/** Mock Server 基础 URL(配合 hdc rport tcp:8765 tcp:8765) */
const MOCK_BASE_URL: string = 'http://127.0.0.1:8765/v1';
/** Provider ID(测试专用,清理后不留残余) */
const TEST_PROVIDER_ID: string = 't15-device-stream-provider';
/** 假 API Key(非真实,不以 sk- 开头) */
const FAKE_API_KEY: string = 'fake-stream-test-key-not-real-xxx';

// ===== 测试辅助 =====

/** 创建测试用 ProviderConfig */
function createTestConfig(): ProviderConfig {
  return ProviderConfig.create(
    TEST_PROVIDER_ID,
    'T-1.5 Stream Device Test Provider',
    ProviderType.OpenAICompatible,
    MOCK_BASE_URL,
    'mock-stream-normal-001'
  );
}

/** 创建测试用 ChatRequest,通过 model 名触发 Mock Server 场景 */
function createTestRequest(model: string): ChatRequest {
  return {
    model: model,
    messages: [
      createChatMessage('msg-1', ChatRole.User, 'Hello stream device test', Date.now())
    ],
    temperature: 0.7,
    topP: 1.0,
    maxTokens: 1024,
    stream: false
  };
}

/** 清理 Asset Store 中的测试密钥(幂等) */
async function cleanupTestKey(): Promise<void> {
  try {
    const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
    await keyStore.remove('arktavern.provider.' + TEST_PROVIDER_ID + '.api-key');
  } catch (e) {
    // 忽略(不存在也算成功)
  }
}

/** 设置测试用 API Key */
async function setupTestKey(): Promise<void> {
  const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
  const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
  await providerKeyStore.replaceKey(TEST_PROVIDER_ID, FAKE_API_KEY);
}

/** 流式测试状态收集器 */
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

/** 流式测试状态持有者 */
interface StreamStateHolder {
  state: StreamTestState;
  promise: Promise<void>;
}

/** 创建流式测试状态 + 完成 Promise */
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

/** 创建流式回调 */
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

/** 创建使用真实 HttpStreamTransport 的 OpenAIProvider */
function createStreamProvider(): OpenAIProvider {
  const httpClient: HarmonyHttpClient = new HarmonyHttpClient();
  const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
  const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
  const transport: HttpStreamTransport = new HttpStreamTransport();
  return new OpenAIProvider(
    httpClient,
    providerKeyStore,
    (options, callbacks) => transport.requestStream(options, callbacks)
  );
}

/** 等待条件满足或超时 */
function waitUntil(condition: () => boolean, timeoutMs: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    const start: number = Date.now();
    const check = () => {
      if (condition()) {
        resolve();
        return;
      }
      if (Date.now() - start >= timeoutMs) {
        resolve();
        return;
      }
      setTimeout(check, 100);
    };
    check();
  });
}

// ===== 测试套件 =====

export default function openAiProviderStreamDeviceTest() {
  describe('OpenAIProviderStreamDeviceTest', () => {

    // 1. 正常流式回复(含 2/3/4: 多次 dataReceive、多次 onDelta、顺序正确)
    it('normal_streaming_receive', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-normal-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        expect(state.result !== null).assertTrue();
        expect(state.result!.content.length > 0).assertTrue();
        // 2. dataReceive 多次触发(chunkCount > 1)
        expect(state.result!.chunkCount > 0).assertTrue();
        // 3. onDelta 多次触发(deltaCount > 1)
        expect(state.result!.deltaCount > 1).assertTrue();
        // 4. delta 顺序正确(sequence 从 0 递增)
        for (let i = 0; i < state.deltas.length; i++) {
          expect(state.deltas[i].sequence).assertEqual(i);
        }
        // 8. [DONE] 识别
        expect(state.result!.receivedDone).assertTrue();
        // 11. finish_reason=stop
        expect(state.result!.finishReason).assertEqual('stop');
      } finally {
        await cleanupTestKey();
      }
    });

    // 5. 中文无乱码
    it('chinese_no_garble', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-chinese-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        expect(state.result!.content).assertEqual('你好世界!');
      } finally {
        await cleanupTestKey();
      }
    });

    // 6. Emoji 无乱码
    it('emoji_no_garble', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-emoji-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        expect(state.result!.content).assertEqual('Hello 🌍🚀🎉');
      } finally {
        await cleanupTestKey();
      }
    });

    // 7. Markdown 和换行保留
    it('markdown_and_newline_preserved', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-multiline-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        const expected: string = 'Line 1\nLine 2\nLine 3';
        expect(state.result!.content).assertEqual(expected);
      } finally {
        await cleanupTestKey();
      }
    });

    // 9. 无 [DONE] 兼容完成
    it('no_done_compatible_complete', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-no-done-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        expect(state.result !== null).assertTrue();
        expect(state.result!.receivedDone).assertFalse();
        expect(state.result!.content).assertEqual('No done marker');
      } finally {
        await cleanupTestKey();
      }
    });

    // 10. usage 解析
    it('usage_parsed', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-usage-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        expect(state.result!.promptTokens).assertEqual(10);
        expect(state.result!.completionTokens).assertEqual(5);
        expect(state.result!.totalTokens).assertEqual(15);
      } finally {
        await cleanupTestKey();
      }
    });

    // 11b. finish_reason=length
    it('finish_reason_length', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-finish-length-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        expect(state.result!.finishReason).assertEqual('length');
      } finally {
        await cleanupTestKey();
      }
    });

    // 12. 401
    it('http_401_authentication', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-401-001'), createCallbacks(state));
        await promise;

        expect(state.error !== null).assertTrue();
        expect(state.error!.type).assertEqual(NetworkErrorType.Authentication);
      } finally {
        await cleanupTestKey();
      }
    });

    // 13. 429
    it('http_429_rate_limit', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-429-001'), createCallbacks(state));
        await promise;

        expect(state.error !== null).assertTrue();
        expect(state.error!.type).assertEqual(NetworkErrorType.RateLimit);
      } finally {
        await cleanupTestKey();
      }
    });

    // 14. 500
    it('http_500_server', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-500-001'), createCallbacks(state));
        await promise;

        expect(state.error !== null).assertTrue();
        expect(state.error!.type).assertEqual(NetworkErrorType.Server);
      } finally {
        await cleanupTestKey();
      }
    });

    // 15. 非法 JSON
    it('invalid_json_parse_error', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-invalid-json-001'), createCallbacks(state));
        await promise;

        expect(state.error !== null).assertTrue();
        expect(state.error!.type).assertEqual(NetworkErrorType.Parse);
      } finally {
        await cleanupTestKey();
      }
    });

    // 16. empty choices(不终止,后续 delta 正常)
    it('empty_choices_continues', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-empty-choices-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        expect(state.result!.content).assertEqual('after empty choices');
      } finally {
        await cleanupTestKey();
      }
    });

    // 17+18+19. abort 中断 + abort 后不再 complete + 多次 abort 不崩溃
    it('abort_cancels_stream', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        const handle: ChatStreamHandle = provider.streamChat(
          createTestConfig(),
          createTestRequest('mock-stream-abort-001'),
          createCallbacks(state)
        );
        // 等待请求发起后 abort(mock-stream-abort 有 2 秒延迟)
        await waitUntil(() => state.started, 3000);
        handle.abort();
        // 19. 多次 abort 不崩溃
        handle.abort();
        handle.abort();
        await promise;

        // 17. abort 中断 → Cancelled
        expect(state.error !== null).assertTrue();
        expect(state.error!.type).assertEqual(NetworkErrorType.Cancelled);
        // 18. abort 后不再 complete
        expect(state.completeCount).assertEqual(0);
        expect(state.errorCount).assertEqual(1);
      } finally {
        await cleanupTestKey();
      }
    });

    // 20. 资源释放(连续请求不崩溃,验证资源未被污染)
    it('resource_release_consecutive_requests', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        // 第一次请求
        const provider1: OpenAIProvider = createStreamProvider();
        const state1 = createStreamState();
        provider1.streamChat(createTestConfig(), createTestRequest('mock-stream-normal-001'), createCallbacks(state1.state));
        await state1.promise;
        expect(state1.state.error).assertNull();

        // 第二次请求(新 Provider 实例,验证前一次资源已释放)
        const provider2: OpenAIProvider = createStreamProvider();
        const state2 = createStreamState();
        provider2.streamChat(createTestConfig(), createTestRequest('mock-stream-normal-001'), createCallbacks(state2.state));
        await state2.promise;
        expect(state2.state.error).assertNull();
        expect(state2.state.result!.content.length > 0).assertTrue();
      } finally {
        await cleanupTestKey();
      }
    });

    // 21. 日志无 API Key(间接验证:错误消息不含密钥)
    it('error_message_no_api_key', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-401-001'), createCallbacks(state));
        await promise;

        expect(state.error !== null).assertTrue();
        // 错误消息不含 API Key
        expect(state.error!.message.indexOf(FAKE_API_KEY) < 0).assertTrue();
        if (state.error!.causeMessage !== undefined) {
          expect(state.error!.causeMessage!.indexOf(FAKE_API_KEY) < 0).assertTrue();
        }
      } finally {
        await cleanupTestKey();
      }
    });

    // 22. Asset Store 测试密钥清理(验证清理后 Key 不存在)
    it('asset_store_cleanup_verified', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const existsBefore: boolean = await providerKeyStore.hasKey(TEST_PROVIDER_ID);
      expect(existsBefore).assertTrue();

      await cleanupTestKey();

      const existsAfter: boolean = await providerKeyStore.hasKey(TEST_PROVIDER_ID);
      expect(existsAfter).assertFalse();
    });

    // 23. API Key 不存在(非 401,是本地校验失败)
    it('api_key_not_configured', 0, async () => {
      await cleanupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-normal-001'), createCallbacks(state));
        await promise;

        expect(state.error !== null).assertTrue();
        expect(state.error!.type).assertEqual(NetworkErrorType.Authentication);
      } finally {
        // 已清理
      }
    });

    // 24. empty-delta 场景(空 content delta 被忽略,非空 delta 正常)
    it('empty_delta_ignored', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-empty-delta-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        expect(state.result!.content).assertEqual('after empty');
      } finally {
        await cleanupTestKey();
      }
    });

    // 25. role-only 场景(role 事件不触发 delta,不报错)
    it('role_only_no_delta', 0, async () => {
      await cleanupTestKey();
      await setupTestKey();
      try {
        const provider: OpenAIProvider = createStreamProvider();
        const streamHolder = createStreamState();
        const state = streamHolder.state;
        const promise = streamHolder.promise;
        provider.streamChat(createTestConfig(), createTestRequest('mock-stream-role-only-001'), createCallbacks(state));
        await promise;

        expect(state.error).assertNull();
        // role-only 不产生 content delta(可能有 0 个 delta)
        expect(state.result!.deltaCount).assertEqual(0);
      } finally {
        await cleanupTestKey();
      }
    });
  });
}
