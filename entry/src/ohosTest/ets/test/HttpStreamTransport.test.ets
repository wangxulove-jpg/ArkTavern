/**
 * HttpStreamTransport 设备集成测试
 *
 * 需要在模拟器或真机运行,依赖 @ohos.net.http。
 * 测试前需启动 tools/sse_mock_server.py。
 *
 * 验证:
 * 1. 请求成功建立
 * 2. dataReceive 在 dataEnd 之前多次触发
 * 3. 收到至少 3 次独立 dataReceive
 * 4. 中文无乱码
 * 5. Emoji 无乱码
 * 6. [DONE] 被识别
 * 7. dataEnd 只触发一次
 * 8. abort 能停止接收
 * 9. 再次 abort 不崩溃
 *
 * 注意:默认测试地址为 http://10.0.2.2:8765/sse(模拟器访问宿主机)。
 * 真机测试时需替换为实际局域网地址。
 */

import { describe, it, expect } from '@ohos/hypium';
import { HttpStreamTransport, TransportRequestOptions, TransportAbortHandle } from '../../../main/ets/network/streaming/HttpStreamTransport';
import { TransportCallbacks } from '../../../main/ets/network/streaming/StreamTransportTypes';
import { SseParser } from '../../../main/ets/network/streaming/SseParser';
import { SseEvent } from '../../../main/ets/network/streaming/SseTypes';
import { NetworkErrorType } from '../../../main/ets/models/NetworkError';

/**
 * 测试 URL 集中配置(仅此一处,便于不同环境切换):
 * - 真机 + hdc rport tcp:8765 tcp:8765:http://127.0.0.1:8765/sse(当前)
 * - HarmonyOS 模拟器(宿主机映射):http://10.0.2.2:8765/sse
 * - 真机 + WiFi(手机与 PC 同网段):http://<PC局域网IPv4>:8765/sse
 */
const SSE_TEST_URL: string = 'http://127.0.0.1:8765/sse';

export default function httpStreamTransportTest() {
  describe('HttpStreamTransportTest', () => {

    // 1. 正常流式接收(完整流程)
    it('full_streaming_receive', 0, async () => {
      const transport: HttpStreamTransport = new HttpStreamTransport();
      const parser: SseParser = new SseParser();
      const events: SseEvent[] = [];
      let completeCount: number = 0;
      let dataReceiveCount: number = 0;
      let lastStatusCode: number = -1;
      const timestamps: number[] = [];

      const callbacks: TransportCallbacks = {
        onData: (chunk: string, byteLength: number) => {
          dataReceiveCount++;
          timestamps.push(Date.now());
          const result = parser.feed(chunk);
          for (let i = 0; i < result.events.length; i++) {
            events.push(result.events[i]);
          }
        },
        onComplete: (statusCode: number) => {
          completeCount++;
          lastStatusCode = statusCode;
        },
        onError: (error) => {
          // 不期望错误
        }
      };

      const options: TransportRequestOptions = {
        url: SSE_TEST_URL,
        method: 'GET',
        connectTimeoutMs: 10000,
        readTimeoutMs: 30000
      };

      const handle: TransportAbortHandle = transport.requestStream(options, callbacks);

      // 等待完成(最多 15 秒)
      await waitUntil(() => completeCount > 0, 15000);

      // 验证
      expect(dataReceiveCount >= 3).assertTrue();
      expect(completeCount).assertEqual(1);
      expect(events.length > 0).assertTrue();
      // 验证 [DONE] 被识别
      let hasDone: boolean = false;
      for (let i = 0; i < events.length; i++) {
        if (events[i].isDone) {
          hasDone = true;
          break;
        }
      }
      expect(hasDone).assertTrue();
    });

    // 2. 中文无乱码
    it('chinese_no_garble', 0, async () => {
      const transport: HttpStreamTransport = new HttpStreamTransport();
      const parser: SseParser = new SseParser();
      const events: SseEvent[] = [];
      let completeCount: number = 0;

      const callbacks: TransportCallbacks = {
        onData: (chunk: string, byteLength: number) => {
          const result = parser.feed(chunk);
          for (let i = 0; i < result.events.length; i++) {
            events.push(result.events[i]);
          }
        },
        onComplete: (statusCode: number) => {
          completeCount++;
        },
        onError: (error) => {}
      };

      const options: TransportRequestOptions = {
        url: SSE_TEST_URL,
        method: 'GET'
      };

      transport.requestStream(options, callbacks);
      await waitUntil(() => completeCount > 0, 15000);

      // 查找中文事件
      let hasChinese: boolean = false;
      for (let i = 0; i < events.length; i++) {
        if (events[i].data.includes('你好世界')) {
          hasChinese = true;
          break;
        }
      }
      expect(hasChinese).assertTrue();
    });

    // 3. Emoji 无乱码
    it('emoji_no_garble', 0, async () => {
      const transport: HttpStreamTransport = new HttpStreamTransport();
      const parser: SseParser = new SseParser();
      const events: SseEvent[] = [];
      let completeCount: number = 0;

      const callbacks: TransportCallbacks = {
        onData: (chunk: string, byteLength: number) => {
          const result = parser.feed(chunk);
          for (let i = 0; i < result.events.length; i++) {
            events.push(result.events[i]);
          }
        },
        onComplete: (statusCode: number) => {
          completeCount++;
        },
        onError: (error) => {}
      };

      const options: TransportRequestOptions = {
        url: SSE_TEST_URL,
        method: 'GET'
      };

      transport.requestStream(options, callbacks);
      await waitUntil(() => completeCount > 0, 15000);

      // 查找 Emoji 事件
      let hasEmoji: boolean = false;
      for (let i = 0; i < events.length; i++) {
        if (events[i].data.includes('🌍') && events[i].data.includes('🚀')) {
          hasEmoji = true;
          break;
        }
      }
      expect(hasEmoji).assertTrue();
    });

    // 4. abort 停止接收
    it('abort_stops_receiving', 0, async () => {
      const transport: HttpStreamTransport = new HttpStreamTransport();
      let dataReceiveCount: number = 0;
      let errorCount: number = 0;
      let cancelledReceived: boolean = false;
      let completeCount: number = 0;

      const callbacks: TransportCallbacks = {
        onData: (chunk: string, byteLength: number) => {
          dataReceiveCount++;
        },
        onComplete: (statusCode: number) => {
          completeCount++;
        },
        onError: (error) => {
          errorCount++;
          if (error.type === NetworkErrorType.Cancelled) {
            cancelledReceived = true;
          }
        }
      };

      const options: TransportRequestOptions = {
        url: SSE_TEST_URL,
        method: 'GET'
      };

      const handle: TransportAbortHandle = transport.requestStream(options, callbacks);

      // 等待收到第一个 chunk
      await waitUntil(() => dataReceiveCount > 0, 5000);

      // abort
      handle.abort();
      expect(handle.isAborted()).assertTrue();

      // 等待一段时间确保没有更多回调
      await sleep(2000);

      // 再次 abort(幂等,不崩溃)
      handle.abort();
      handle.abort();

      // 验证:不应触发 complete
      expect(completeCount).assertEqual(0);
    });

    // 5. dataReceive 时间戳记录
    it('data_receive_timestamps', 0, async () => {
      const transport: HttpStreamTransport = new HttpStreamTransport();
      const timestamps: number[] = [];
      let completeCount: number = 0;

      const callbacks: TransportCallbacks = {
        onData: (chunk: string, byteLength: number) => {
          timestamps.push(Date.now());
        },
        onComplete: (statusCode: number) => {
          completeCount++;
        },
        onError: (error) => {}
      };

      const options: TransportRequestOptions = {
        url: SSE_TEST_URL,
        method: 'GET'
      };

      transport.requestStream(options, callbacks);
      await waitUntil(() => completeCount > 0, 15000);

      // 验证:至少有 3 个时间戳
      expect(timestamps.length >= 3).assertTrue();
      // 验证:时间戳递增
      for (let i = 1; i < timestamps.length; i++) {
        expect(timestamps[i] >= timestamps[i - 1]).assertTrue();
      }
    });
  });
}

/**
 * 等待条件满足或超时。
 */
function waitUntil(condition: () => boolean, timeoutMs: number): Promise<void> {
  return new Promise<void>((resolve) => {
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

/**
 * 简单 sleep。
 */
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}
