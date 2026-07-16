/**
 * MockHttpClient 本地测试用 HTTP 客户端 Mock
 *
 * 仅存在于 test 目录,不进入 main 代码,不进入 HAP。
 * 实现 HttpClient 接口,可配置返回状态码、Header、Body,
 * 并可模拟网络错误、超时、取消。
 *
 * 安全要求:
 * - 不记录 Authorization 到测试输出
 * - 不记录请求 Body 原文
 * - 仅记录请求方法、URL 路径(不含查询参数)用于断言
 *
 * 不模拟 Asset Store 密码学。
 */
import {
  HttpClient,
  HttpMethod,
  HttpHeaders,
  HttpRequestOptions,
  HttpResponse,
  StreamCallbacks,
  AbortHandle
} from '../main/ets/network/core/HttpClient';
import {
  NetworkError,
  NetworkErrorType,
  createNetworkError
} from '../main/ets/models/NetworkError';

/**
 * Mock 客户端记录的请求信息(供测试断言)。
 * 不包含 Authorization、Body 原文。
 */
export interface RecordedRequest {
  /** HTTP 方法 */
  readonly method: HttpMethod;
  /** URL 路径(去除查询参数,仅用于日志和断言) */
  readonly urlPath: string;
  /** 完整 URL(测试需要时可读取,但不打印到日志) */
  readonly url: string;
  /** Content-Type 头(可选) */
  readonly contentType: string | undefined;
  /** Accept 头(可选) */
  readonly accept: string | undefined;
  /** 是否设置了 Authorization 头(不记录值) */
  readonly hasAuthorization: boolean;
  /** Authorization 前缀(如 "Bearer ",不含 token 部分) */
  readonly authorizationPrefix: string | undefined;
  /** 是否强制 stream=false */
  readonly streamForcedFalse: boolean;
  /** 请求体 JSON 解析后的对象(测试需要时读取) */
  readonly parsedBody: Record<string, Object> | undefined;
  /** 请求体原始字符串(测试需要时读取,不打印) */
  readonly rawBody: string | undefined;
  /** 连接超时(毫秒) */
  readonly connectTimeoutMs: number | undefined;
  /** 读取超时(毫秒) */
  readonly readTimeoutMs: number | undefined;
}

/**
 * Mock 响应配置。
 */
export interface MockResponseConfig {
  /** HTTP 状态码 */
  readonly statusCode: number;
  /** 响应头 */
  readonly headers?: HttpHeaders;
  /** 响应体字符串 */
  readonly body: string;
}

/**
 * Mock 错误配置。
 */
export type MockErrorMode =
  | 'none'
  | 'network'
  | 'timeout'
  | 'cancelled';

/**
 * 测试用 HTTP 客户端 Mock 实现。
 *
 * 使用方式:
 * 1. 创建实例
 * 2. 配置 setResponse / setErrorMode
 * 3. 传入 OpenAIProvider
 * 4. 调用 sendChat 后,通过 getLastRequest / recordCount 断言
 */
export class MockHttpClient implements HttpClient {
  /** 待返回的响应配置 */
  private nextResponse: MockResponseConfig = {
    statusCode: 200,
    body: ''
  };
  /** 错误模式 */
  private errorMode: MockErrorMode = 'none';
  /** 历史记录(按时间顺序) */
  private readonly history: RecordedRequest[] = [];
  /** 自定义响应队列(按顺序消费,优先级高于 nextResponse) */
  private readonly responseQueue: MockResponseConfig[] = [];

  /**
   * 设置下一次(及后续)请求的返回响应。
   * 如果调用 queueResponse,则优先消费队列。
   * @param config 响应配置
   */
  setResponse(config: MockResponseConfig): void {
    this.nextResponse = config;
  }

  /**
   * 排队响应。request 调用按顺序消费队列,队列为空后回落到 nextResponse。
   * @param config 响应配置
   */
  queueResponse(config: MockResponseConfig): void {
    this.responseQueue.push(config);
  }

  /**
   * 设置错误模式。
   * @param mode 错误模式
   */
  setErrorMode(mode: MockErrorMode): void {
    this.errorMode = mode;
  }

  /**
   * 获取最近一次请求的记录。
   * 不包含 Authorization 值,不包含请求 Body 原文(只含解析后的对象)。
   * @returns 最近一次请求记录,无请求时返回 undefined
   */
  getLastRequest(): RecordedRequest | undefined {
    if (this.history.length === 0) {
      return undefined;
    }
    return this.history[this.history.length - 1];
  }

  /**
   * 获取所有请求记录。
   * @returns 请求记录数组(只读视图)
   */
  getAllRequests(): RecordedRequest[] {
    return this.history;
  }

  /**
   * 已记录的请求数量。
   */
  get recordCount(): number {
    return this.history.length;
  }

  /**
   * 重置 Mock 状态(响应配置、错误模式、历史记录)。
   */
  reset(): void {
    this.nextResponse = { statusCode: 200, body: '' };
    this.errorMode = 'none';
    this.history.length = 0;
    this.responseQueue.length = 0;
  }

  /**
   * 发送 HTTP 请求(Mock 实现)。
   * @param options 请求选项
   * @returns HTTP 响应 Promise
   */
  request(options: HttpRequestOptions): Promise<HttpResponse> {
    const record: RecordedRequest = this.recordRequest(options);
    this.history.push(record);

    if (this.errorMode === 'network') {
      const err: NetworkError = createNetworkError(
        NetworkErrorType.Network,
        'Mock network error',
        { causeMessage: 'Mock network error' }
      );
      return Promise.reject<HttpResponse>(err);
    }
    if (this.errorMode === 'timeout') {
      const err: NetworkError = createNetworkError(
        NetworkErrorType.Timeout,
        'Mock timeout error',
        { causeMessage: 'Mock timeout error' }
      );
      return Promise.reject<HttpResponse>(err);
    }
    if (this.errorMode === 'cancelled') {
      const err: NetworkError = createNetworkError(
        NetworkErrorType.Cancelled,
        'Mock cancelled error'
      );
      return Promise.reject<HttpResponse>(err);
    }

    // 优先消费队列
    const queued: MockResponseConfig | undefined = this.responseQueue.shift();
    const config: MockResponseConfig = queued !== undefined ? queued : this.nextResponse;

    const headers: HttpHeaders = config.headers !== undefined
      ? config.headers
      : new Map<string, string>();

    const response: HttpResponse = {
      statusCode: config.statusCode,
      headers: headers,
      body: config.body
    };
    return Promise.resolve<HttpResponse>(response);
  }

  /**
   * 发送流式请求(Mock 不支持)。
   * @param options 请求选项
   * @param callbacks 流式回调
   * @returns 中止句柄
   */
  requestStream(_options: HttpRequestOptions, callbacks: StreamCallbacks): AbortHandle {
    callbacks.onError(createNetworkError(
      NetworkErrorType.Unknown,
      'MockHttpClient does not support streaming'
    ));
    return new MockNoopAbortHandle();
  }

  /**
   * 记录请求信息(脱敏后)。
   */
  private recordRequest(options: HttpRequestOptions): RecordedRequest {
    const headers: HttpHeaders | undefined = options.headers;
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
        // 仅记录前缀(如 "Bearer "),不含 token 内容
        const spaceIdx: number = auth.indexOf(' ');
        authorizationPrefix = spaceIdx > 0 ? auth.substring(0, spaceIdx + 1) : auth;
      }
    }

    // 解析请求体
    let parsedBody: Record<string, Object> | undefined = undefined;
    let rawBody: string | undefined = undefined;
    let streamForcedFalse: boolean = false;
    if (options.body !== undefined && options.body.length > 0) {
      rawBody = options.body;
      try {
        const parsed: Object = JSON.parse(options.body);
        const record: Record<string, Object> = parsed as Record<string, Object>;
        parsedBody = record;
        const streamVal: Object | undefined = record['stream'];
        if (streamVal === false) {
          streamForcedFalse = true;
        }
      } catch (e) {
        // 非 JSON,忽略
      }
    }

    return {
      method: options.method,
      urlPath: extractPath(options.url),
      url: options.url,
      contentType: contentType,
      accept: accept,
      hasAuthorization: hasAuthorization,
      authorizationPrefix: authorizationPrefix,
      streamForcedFalse: streamForcedFalse,
      parsedBody: parsedBody,
      rawBody: rawBody,
      connectTimeoutMs: options.connectTimeoutMs,
      readTimeoutMs: options.readTimeoutMs
    };
  }
}

/**
 * 从 URL 中提取路径(去除查询参数)。
 * @param url 完整 URL
 * @returns 路径部分
 */
function extractPath(url: string): string {
  const queryIdx: number = url.indexOf('?');
  if (queryIdx > 0) {
    return url.substring(0, queryIdx);
  }
  return url;
}

/**
 * 空操作的中止句柄(Mock)。
 */
class MockNoopAbortHandle implements AbortHandle {
  abort(): void {
    // no-op
  }
  isAborted(): boolean {
    return false;
  }
}
