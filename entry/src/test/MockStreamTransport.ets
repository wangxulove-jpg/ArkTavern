/**
 * MockStreamTransport 本地测试用流式传输 Mock
 *
 * 仅存在于 test 目录,不进入 main 代码,不进入 HAP。
 * 实现 StreamLauncher 函数签名,可配置返回的 SSE chunks、状态码、错误,
 * 并可模拟主动取消。
 *
 * 支持两种模式:
 * 1. 自动模式(默认):launch 同步触发 onHeaders → onData* → onComplete
 * 2. 手动模式(setAutoTrigger(false)):测试手动调用 trigger* 方法,
 *    用于 abort 测试或精确控制流程。
 *
 * 安全要求:
 * - 不记录 Authorization 值
 * - 不记录请求 Body 原文
 * - 仅记录请求方法、URL、是否设置 Authorization、stream 字段值
 */

import {
  TransportRequestOptions,
  TransportAbortHandle
} from '../main/ets/network/streaming/HttpStreamTransport';
import { TransportCallbacks } from '../main/ets/network/streaming/StreamTransportTypes';
import { NetworkError } from '../main/ets/models/NetworkError';

/**
 * Mock 记录的流式请求信息(供测试断言)。
 * 不包含 Authorization 值、Body 原文。
 */
export interface RecordedStreamRequest {
  /** HTTP 方法 */
  readonly method: string;
  /** 完整 URL */
  readonly url: string;
  /** 是否设置了 Authorization 头(不记录值) */
  readonly hasAuthorization: boolean;
  /** Authorization 前缀(如 "Bearer ",不含 token) */
  readonly authorizationPrefix: string | undefined;
  /** Content-Type 头 */
  readonly contentType: string | undefined;
  /** Accept 头 */
  readonly accept: string | undefined;
  /** 请求体 JSON 解析后的对象(测试需要时读取) */
  readonly parsedBody: Record<string, Object> | undefined;
  /** stream 字段值(true/false/undefined) */
  readonly streamValue: boolean | undefined;
  /** 连接超时(毫秒) */
  readonly connectTimeoutMs: number | undefined;
  /** 读取超时(毫秒) */
  readonly readTimeoutMs: number | undefined;
}

/**
 * 测试用流式传输 Mock。
 *
 * 使用方式:
 * 1. 创建实例
 * 2. 配置 setChunks / setStatusCode / setError / setAutoTrigger
 * 3. 将 transport.launch 传入 OpenAIProvider 构造函数
 * 4. 调用 provider.streamChat 后,通过 getLastRequest / trigger* 断言
 */
export class MockStreamTransport {
  /** 待发送的 SSE chunks */
  private chunks: string[] = [];
  /** HTTP 状态码(headersReceive) */
  private statusCode: number = 200;
  /** 错误模式(非 null 时触发 onError) */
  private error: NetworkError | null = null;
  /** 是否自动触发回调(true=自动,false=手动) */
  private autoTrigger: boolean = true;

  /** 最近一次请求记录 */
  private lastRequest: RecordedStreamRequest | null = null;
  /** 当前活跃的回调(手动模式使用) */
  private currentCallbacks: TransportCallbacks | null = null;
  /** 当前的中止句柄(手动模式使用) */
  private currentHandle: MockStreamAbortHandle | null = null;

  /**
   * 设置待发送的 SSE chunks(自动模式下按顺序触发 onData)。
   * @param chunks SSE 数据块数组
   */
  setChunks(chunks: string[]): void {
    this.chunks = chunks;
  }

  /**
   * 设置 HTTP 状态码(headersReceive)。
   * @param code 状态码
   */
  setStatusCode(code: number): void {
    this.statusCode = code;
  }

  /**
   * 设置错误(非 null 时 launcher 触发 onError 而非正常流程)。
   * @param error 网络错误
   */
  setError(error: NetworkError): void {
    this.error = error;
  }

  /**
   * 设置是否自动触发回调。
   * @param auto true=自动触发,false=手动触发
   */
  setAutoTrigger(auto: boolean): void {
    this.autoTrigger = auto;
  }

  /**
   * 获取最近一次请求记录。
   * @returns 请求记录,无请求时返回 null
   */
  getLastRequest(): RecordedStreamRequest | null {
    return this.lastRequest;
  }

  /**
   * 重置 Mock 状态。
   */
  reset(): void {
    this.chunks = [];
    this.statusCode = 200;
    this.error = null;
    this.autoTrigger = true;
    this.lastRequest = null;
    this.currentCallbacks = null;
    this.currentHandle = null;
  }

  /**
   * StreamLauncher 实现。
   * 记录请求,返回中止句柄。
   * 自动模式下同步触发回调链;手动模式下等待测试调用 trigger*。
   *
   * @param options 请求选项
   * @param callbacks 流式回调
   * @returns 中止句柄
   */
  launch(options: TransportRequestOptions, callbacks: TransportCallbacks): TransportAbortHandle {
    // 记录请求
    this.lastRequest = this.recordRequest(options);
    this.currentCallbacks = callbacks;
    this.currentHandle = new MockStreamAbortHandle();

    if (this.autoTrigger) {
      this.runAutoSequence(callbacks);
    }

    return this.currentHandle;
  }

  /**
   * 手动触发 onHeaders 回调。
   */
  triggerHeaders(): void {
    if (this.currentCallbacks === null || this.currentHandle === null) {
      return;
    }
    if (this.currentHandle.isAborted()) {
      return;
    }
    if (this.currentCallbacks.onHeaders !== undefined) {
      this.currentCallbacks.onHeaders(this.statusCode, new Map<string, string>());
    }
  }

  /**
   * 手动触发 onData 回调(发送一个 chunk)。
   * @param chunk 数据块
   */
  triggerData(chunk: string): void {
    if (this.currentCallbacks === null || this.currentHandle === null) {
      return;
    }
    if (this.currentHandle.isAborted()) {
      return;
    }
    this.currentCallbacks.onData(chunk, chunk.length);
  }

  /**
   * 手动触发 onData 回调,发送 setChunks 中下一个 chunk。
   */
  triggerNextChunk(): void {
    if (this.chunks.length === 0) {
      return;
    }
    const chunk: string = this.chunks.shift() as string;
    this.triggerData(chunk);
  }

  /**
   * 手动触发 onComplete 回调。
   */
  triggerComplete(): void {
    if (this.currentCallbacks === null || this.currentHandle === null) {
      return;
    }
    if (this.currentHandle.isAborted()) {
      return;
    }
    this.currentCallbacks.onComplete(this.statusCode);
  }

  /**
   * 手动触发 onError 回调。
   * @param error 网络错误
   */
  triggerError(error: NetworkError): void {
    if (this.currentCallbacks === null || this.currentHandle === null) {
      return;
    }
    if (this.currentHandle.isAborted()) {
      return;
    }
    this.currentCallbacks.onError(error);
  }

  /**
   * 自动模式:同步触发回调链。
   * 错误模式 → onError;否则 → onHeaders → onData* → onComplete。
   */
  private runAutoSequence(callbacks: TransportCallbacks): void {
    if (this.currentHandle === null) {
      return;
    }
    const handle: MockStreamAbortHandle = this.currentHandle;

    // 错误模式
    if (this.error !== null) {
      if (!handle.isAborted()) {
        callbacks.onError(this.error);
      }
      return;
    }

    // onHeaders
    if (handle.isAborted()) {
      return;
    }
    if (callbacks.onHeaders !== undefined) {
      callbacks.onHeaders(this.statusCode, new Map<string, string>());
    }

    // onData *
    for (let i = 0; i < this.chunks.length; i++) {
      if (handle.isAborted()) {
        return;
      }
      const chunk: string = this.chunks[i];
      callbacks.onData(chunk, chunk.length);
    }

    // onComplete
    if (handle.isAborted()) {
      return;
    }
    callbacks.onComplete(this.statusCode);
  }

  /**
   * 记录请求信息(脱敏后)。
   */
  private recordRequest(options: TransportRequestOptions): RecordedStreamRequest {
    const headers: Map<string, string> | undefined = options.headers;
    let contentType: string | undefined = undefined;
    let accept: string | undefined = undefined;
    let hasAuthorization: boolean = false;
    let authorizationPrefix: string | undefined = undefined;

    if (headers !== undefined) {
      contentType = headers.get('Content-Type');
      accept = headers.get('Accept');
      const auth: string | undefined = headers.get('Authorization');
      if (auth !== undefined && auth.length > 0) {
        hasAuthorization = true;
        const spaceIdx: number = auth.indexOf(' ');
        authorizationPrefix = spaceIdx > 0 ? auth.substring(0, spaceIdx + 1) : auth;
      }
    }

    // 解析请求体
    let parsedBody: Record<string, Object> | undefined = undefined;
    let streamValue: boolean | undefined = undefined;
    if (options.body !== undefined && options.body.length > 0) {
      try {
        const parsed: Object = JSON.parse(options.body);
        const record: Record<string, Object> = parsed as Record<string, Object>;
        parsedBody = record;
        const streamVal: Object | undefined = record['stream'];
        if (typeof streamVal === 'boolean') {
          streamValue = streamVal as boolean;
        }
      } catch (e) {
        // 非 JSON,忽略
      }
    }

    return {
      method: options.method,
      url: options.url,
      hasAuthorization: hasAuthorization,
      authorizationPrefix: authorizationPrefix,
      contentType: contentType,
      accept: accept,
      parsedBody: parsedBody,
      streamValue: streamValue,
      connectTimeoutMs: options.connectTimeoutMs,
      readTimeoutMs: options.readTimeoutMs
    };
  }
}

/**
 * Mock 流式中止句柄。
 */
class MockStreamAbortHandle implements TransportAbortHandle {
  private aborted: boolean = false;

  abort(): void {
    this.aborted = true;
  }

  isAborted(): boolean {
    return this.aborted;
  }
}
