/**
 * RealSsePocViewModel 真实 SSE PoC ViewModel
 *
 * 临时技术验证 ViewModel,不是正式 Provider/ChatService 实现。
 * 管理真实 OpenAI-compatible Chat Completions SSE 请求的完整生命周期。
 *
 * 安全要求:
 * - API Key 仅保存在内存私有字段中,不落盘、不写入日志
 * - 页面退出时主动 abort 并清空引用
 * - 同一时刻只能存在一个活动请求
 *
 * 状态机:Idle → Validating → Connecting → Streaming → Completed/Cancelled/Failed
 */

import { HttpStreamTransport, TransportRequestOptions, TransportAbortHandle } from '../network/streaming/HttpStreamTransport';
import { TransportCallbacks, TransportState } from '../network/streaming/StreamTransportTypes';
import { SseParser } from '../network/streaming/SseParser';
import { SseEvent, SseParseResult } from '../network/streaming/SseTypes';
import { parseOpenAiDelta, OpenAiDeltaResult } from '../network/streaming/OpenAiSseDeltaParser';
import { buildChatCompletionsUrl, buildChatCompletionsBody, UrlBuildResult } from '../network/streaming/OpenAiUrlBuilder';
import { NetworkError, NetworkErrorType, createNetworkError, errorTypeFromStatusCode } from '../models/NetworkError';
import { Logger } from '../utils/Logger';

/** PoC 状态 */
export enum PocState {
  Idle = 'Idle',
  Validating = 'Validating',
  Connecting = 'Connecting',
  Streaming = 'Streaming',
  Completed = 'Completed',
  Cancelled = 'Cancelled',
  Failed = 'Failed'
}

/** PoC 更新回调(通知页面刷新) */
export interface PocUpdateCallback {
  onStateChanged(state: PocState): void;
  onChunk(count: number): void;
  onSseEvent(count: number): void;
  onDelta(replyText: string, deltaCount: number): void;
  onError(message: string): void;
}

/**
 * PocUpdateCallback 的实现类。
 * ArkTS 严格模式不允许对象字面量,使用类实现接口。
 */
export class PocCallbackImpl implements PocUpdateCallback {
  private stateFn: (s: PocState) => void;
  private chunkFn: (n: number) => void;
  private sseFn: (n: number) => void;
  private deltaFn: (t: string, n: number) => void;
  private errFn: (m: string) => void;

  constructor(
    stateFn: (s: PocState) => void,
    chunkFn: (n: number) => void,
    sseFn: (n: number) => void,
    deltaFn: (t: string, n: number) => void,
    errFn: (m: string) => void
  ) {
    this.stateFn = stateFn;
    this.chunkFn = chunkFn;
    this.sseFn = sseFn;
    this.deltaFn = deltaFn;
    this.errFn = errFn;
  }

  onStateChanged(state: PocState): void { this.stateFn(state); }
  onChunk(count: number): void { this.chunkFn(count); }
  onSseEvent(count: number): void { this.sseFn(count); }
  onDelta(replyText: string, deltaCount: number): void { this.deltaFn(replyText, deltaCount); }
  onError(message: string): void { this.errFn(message); }
}

/** 请求统计 */
export interface PocStats {
  readonly chunkCount: number;
  readonly sseEventCount: number;
  readonly deltaCount: number;
  readonly replyLength: number;
  readonly doneReceived: boolean;
}

/** HTTP 错误体最大累积长度 */
const MAX_ERROR_BODY_LENGTH: number = 2048;

/**
 * 真实 SSE PoC ViewModel。
 * API Key 仅存在内存中,不落盘、不写入日志。
 */
export class RealSsePocViewModel {
  /** API Key(仅内存,不暴露 getter) */
  private apiKey: string = '';
  /** 传输层 */
  private transport: HttpStreamTransport = new HttpStreamTransport();
  /** 中止句柄 */
  private abortHandle: TransportAbortHandle | null = null;
  /** SSE 解析器(每次请求重建) */
  private sseParser: SseParser = new SseParser();
  /** 页面回调 */
  private callback: PocUpdateCallback | null = null;

  /** 当前状态 */
  private state: PocState = PocState.Idle;
  /** 请求序列号(防止旧请求迟到回调) */
  private requestSeq: number = 0;

  /** 统计数据 */
  private chunkCount: number = 0;
  private sseEventCount: number = 0;
  private deltaCount: number = 0;
  private replyBuffer: string = '';
  private doneReceived: boolean = false;

  /** HTTP 错误处理 */
  private httpErrorCode: number = 0;
  private errorBodyBuffer: string = '';

  /**
   * 设置页面回调。
   */
  setCallback(cb: PocUpdateCallback): void {
    this.callback = cb;
  }

  /**
   * 设置 API Key(仅保存在内存中)。
   */
  setApiKey(key: string): void {
    this.apiKey = key;
  }

  /**
   * 清空 API Key。
   */
  clearApiKey(): void {
    this.apiKey = '';
  }

  /**
   * 获取当前状态。
   */
  getState(): PocState {
    return this.state;
  }

  /**
   * 获取统计数据。
   */
  getStats(): PocStats {
    return {
      chunkCount: this.chunkCount,
      sseEventCount: this.sseEventCount,
      deltaCount: this.deltaCount,
      replyLength: this.replyBuffer.length,
      doneReceived: this.doneReceived
    };
  }

  /**
   * 获取当前回复文本。
   */
  getReplyText(): string {
    return this.replyBuffer;
  }

  /**
   * 是否可以停止(Connecting 或 Streaming 状态)。
   */
  canStop(): boolean {
    return this.state === PocState.Connecting || this.state === PocState.Streaming;
  }

  /**
   * 是否可以开始(非 Streaming/Connecting 状态)。
   */
  canStart(): boolean {
    return this.state !== PocState.Streaming && this.state !== PocState.Connecting;
  }

  /**
   * 发起 SSE 请求。
   * @param baseUrl Base URL
   * @param model 模型名称
   * @param message 用户测试消息
   */
  start(baseUrl: string, model: string, message: string): void {
    // 同一时刻只能存在一个活动请求
    if (!this.canStart()) {
      return;
    }

    this.setState(PocState.Validating);

    // 验证输入
    if (this.apiKey.length === 0) {
      this.fail('API Key is empty');
      return;
    }
    if (model.trim().length === 0) {
      this.fail('Model is empty');
      return;
    }

    const urlResult: UrlBuildResult = buildChatCompletionsUrl(baseUrl);
    if (!urlResult.success) {
      this.fail(urlResult.error);
      return;
    }

    // 准备请求
    this.requestSeq++;
    const seq: number = this.requestSeq;
    this.resetRequestData();
    this.setState(PocState.Connecting);

    // 构建请求
    const body: string = buildChatCompletionsBody(model.trim(), message);
    const headers: Map<string, string> = new Map<string, string>();
    headers.set('Content-Type', 'application/json');
    headers.set('Accept', 'text/event-stream');
    headers.set('Authorization', 'Bearer ' + this.apiKey);

    const options: TransportRequestOptions = {
      url: urlResult.url,
      method: 'POST',
      headers: headers,
      body: body,
      connectTimeoutMs: 15000,
      readTimeoutMs: 60000
    };

    Logger.info('SSE PoC request starting', 'Authorization set');

    const callbacks: TransportCallbacks = {
      onHeaders: (statusCode: number, headers: Map<string, string>): void => {
        if (seq !== this.requestSeq) {
          return; // 旧请求迟到回调
        }
        Logger.info('SSE PoC headers received', 'code=' + statusCode);
        if (statusCode >= 400) {
          this.httpErrorCode = statusCode;
          this.errorBodyBuffer = '';
        }
      },
      onData: (chunk: string, byteLength: number): void => {
        if (seq !== this.requestSeq) {
          return;
        }
        if (this.state === PocState.Connecting) {
          this.setState(PocState.Streaming);
        }

        this.chunkCount++;
        this.notifyChunk();

        if (this.httpErrorCode > 0) {
          // 错误响应,累积 body
          this.errorBodyBuffer += chunk;
          if (this.errorBodyBuffer.length > MAX_ERROR_BODY_LENGTH) {
            this.errorBodyBuffer = this.errorBodyBuffer.substring(0, MAX_ERROR_BODY_LENGTH);
          }
          return;
        }

        // 正常 SSE 数据,通过 SseParser 解析
        this.processSseChunk(chunk);
      },
      onComplete: (statusCode: number): void => {
        if (seq !== this.requestSeq) {
          return;
        }
        Logger.info('SSE PoC complete', 'code=' + statusCode + ' chunks=' + this.chunkCount + ' events=' + this.sseEventCount);

        if (this.httpErrorCode > 0) {
          // HTTP 错误
          this.handleHttpError(this.httpErrorCode, this.errorBodyBuffer);
          this.releaseTransport();
          return;
        }

        // 正常完成
        this.handleSseFinish();
        this.releaseTransport();

        if (this.state !== PocState.Cancelled && this.state !== PocState.Failed) {
          this.setState(PocState.Completed);
        }
      },
      onError: (error: NetworkError): void => {
        if (seq !== this.requestSeq) {
          return;
        }
        Logger.warn('SSE PoC error', 'type=' + error.type + ' code=' + error.statusCode);
        this.fail(this.networkErrorToMessage(error));
        this.releaseTransport();
      }
    };

    this.abortHandle = this.transport.requestStream(options, callbacks);
  }

  /**
   * 停止当前请求(用户主动取消)。
   */
  stop(): void {
    if (!this.canStop()) {
      return;
    }
    Logger.info('SSE PoC user abort');
    if (this.abortHandle !== null) {
      this.abortHandle.abort();
    }
    this.setState(PocState.Cancelled);
    this.releaseTransport();
  }

  /**
   * 页面退出时清理(主动 abort + 清空 Key)。
   */
  cleanup(): void {
    if (this.abortHandle !== null) {
      this.abortHandle.abort();
    }
    this.releaseTransport();
    this.clearApiKey();
    this.callback = null;
  }

  /**
   * 清空敏感信息(API Key + 回复文本)。
   */
  clearSensitiveData(): void {
    this.clearApiKey();
    this.replyBuffer = '';
    this.errorBodyBuffer = '';
  }

  // ===== 内部方法 =====

  private setState(state: PocState): void {
    this.state = state;
    if (this.callback !== null) {
      this.callback.onStateChanged(state);
    }
  }

  private fail(message: string): void {
    Logger.warn('SSE PoC failed', message);
    this.setState(PocState.Failed);
    if (this.callback !== null) {
      this.callback.onError(message);
    }
    this.releaseTransport();
  }

  private notifyChunk(): void {
    if (this.callback !== null) {
      this.callback.onChunk(this.chunkCount);
    }
  }

  private notifySseEvent(): void {
    if (this.callback !== null) {
      this.callback.onSseEvent(this.sseEventCount);
    }
  }

  private notifyDelta(): void {
    if (this.callback !== null) {
      this.callback.onDelta(this.replyBuffer, this.deltaCount);
    }
  }

  private resetRequestData(): void {
    this.chunkCount = 0;
    this.sseEventCount = 0;
    this.deltaCount = 0;
    this.replyBuffer = '';
    this.doneReceived = false;
    this.httpErrorCode = 0;
    this.errorBodyBuffer = '';
    this.sseParser = new SseParser();
  }

  private processSseChunk(chunk: string): void {
    const result: SseParseResult = this.sseParser.feed(chunk);
    for (let i = 0; i < result.events.length; i++) {
      this.handleSseEvent(result.events[i]);
    }
  }

  private handleSseFinish(): void {
    const result: SseParseResult = this.sseParser.finish();
    for (let i = 0; i < result.events.length; i++) {
      this.handleSseEvent(result.events[i]);
    }
  }

  private handleSseEvent(evt: SseEvent): void {
    this.sseEventCount++;
    this.notifySseEvent();

    if (evt.isDone) {
      this.doneReceived = true;
      Logger.info('SSE PoC [DONE] received');
      return;
    }

    // 解析 OpenAI delta
    const delta: OpenAiDeltaResult = parseOpenAiDelta(evt.data);
    if (delta.parseError !== undefined) {
      // 记录解析错误但不终止请求
      Logger.warn('SSE PoC delta parse error', delta.parseError);
      return;
    }

    if (delta.hasContent) {
      this.replyBuffer += delta.content;
      this.deltaCount++;
      this.notifyDelta();
    }

    if (delta.done) {
      this.doneReceived = true;
    }
  }

  private handleHttpError(statusCode: number, body: string): void {
    const errorType: NetworkErrorType = errorTypeFromStatusCode(statusCode);
    let message: string = this.networkErrorTypeToMessage(errorType, statusCode);

    // 尝试从 body 中提取错误信息(限制长度)
    if (body.length > 0) {
      try {
        const parsed: Object = JSON.parse(body);
        const root: Record<string, Object> = parsed as Record<string, Object>;
        const errorObj: Object | undefined = root['error'];
        if (errorObj !== undefined && errorObj !== null && typeof errorObj === 'object') {
          const errRecord: Record<string, Object> = errorObj as Record<string, Object>;
          const msg: Object | undefined = errRecord['message'];
          if (msg !== undefined && typeof msg === 'string') {
            message = msg;
          }
        }
      } catch (e) {
        // body 不是 JSON,忽略
      }
    }

    this.fail(message);
  }

  private networkErrorToMessage(error: NetworkError): string {
    if (error.type === NetworkErrorType.Cancelled) {
      return 'Request cancelled';
    }
    if (error.type === NetworkErrorType.Timeout) {
      return 'Request timeout';
    }
    if (error.type === NetworkErrorType.Authentication) {
      return 'Authentication failed (HTTP ' + (error.statusCode ?? 0) + ')';
    }
    if (error.type === NetworkErrorType.RateLimit) {
      return 'Rate limited (HTTP 429)';
    }
    if (error.type === NetworkErrorType.Server) {
      return 'Server error (HTTP ' + (error.statusCode ?? 0) + ')';
    }
    if (error.type === NetworkErrorType.Network) {
      return 'Network connection failed';
    }
    return error.message;
  }

  private networkErrorTypeToMessage(type: NetworkErrorType, statusCode: number): string {
    switch (type) {
      case NetworkErrorType.Authentication:
        return 'Authentication failed (HTTP ' + statusCode + ')';
      case NetworkErrorType.RateLimit:
        return 'Rate limited (HTTP 429)';
      case NetworkErrorType.Server:
        return 'Server error (HTTP ' + statusCode + ')';
      case NetworkErrorType.InvalidRequest:
        return 'Invalid request (HTTP ' + statusCode + ')';
      default:
        return 'HTTP error ' + statusCode;
    }
  }

  private releaseTransport(): void {
    this.abortHandle = null;
  }
}
