/**
 * HarmonyHttpClient 辅助函数本地单元测试
 *
 * 测试 HarmonyHttpClient.ets 中导出的纯逻辑辅助函数:
 * - extractHost:URL → host(脱敏)
 * - buildHttpOptions:统一选项 → HarmonyOS HttpRequestOptions
 * - convertBusinessError:BusinessError → NetworkError
 *
 * 不依赖设备 API(仅类型和纯函数),可在本地单元测试运行。
 * buildHttpOptions 和 convertBusinessError 引用了 @ohos.net.http 的类型,
 * 但实际只验证逻辑映射结果,不发请求。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  HttpMethod,
  HttpHeaders,
  HttpRequestOptions
} from '../main/ets/network/core/HttpClient';
import {
  NetworkErrorType
} from '../main/ets/models/NetworkError';
import {
  extractHost,
  buildHttpOptions,
  convertBusinessError
} from '../main/ets/network/core/HarmonyHttpClient';

export default function harmonyHttpClientHelpersTest() {
  describe('HarmonyHttpClientHelpersTest', () => {

    // ===== extractHost 测试 =====

    it('extractHost_https_with_path', 0, () => {
      const host: string = extractHost('https://api.example.com/v1/chat/completions');
      expect(host).assertEqual('https://api.example.com');
    });

    it('extractHost_http_no_path', 0, () => {
      const host: string = extractHost('http://localhost:8080');
      expect(host).assertEqual('http://localhost:8080');
    });

    it('extractHost_with_query_params', 0, () => {
      const host: string = extractHost('https://api.example.com/v1/chat?key=value');
      expect(host).assertEqual('https://api.example.com');
    });

    it('extractHost_no_path_with_query', 0, () => {
      const host: string = extractHost('https://api.example.com?key=value');
      expect(host).assertEqual('https://api.example.com');
    });

    it('extractHost_empty_url', 0, () => {
      const host: string = extractHost('');
      expect(host).assertEqual('[empty]');
    });

    it('extractHost_no_protocol', 0, () => {
      const host: string = extractHost('api.example.com/v1');
      expect(host).assertEqual('[unknown]');
    });

    // ===== buildHttpOptions 测试 =====

    it('buildHttpOptions_post_with_body', 0, () => {
      const headers: HttpHeaders = new Map<string, string>();
      headers.set('Content-Type', 'application/json');
      const options: HttpRequestOptions = {
        method: HttpMethod.POST,
        url: 'https://example.com',
        headers: headers,
        body: '{"key":"value"}',
        connectTimeoutMs: 30000,
        readTimeoutMs: 60000
      };

      const httpOpts = buildHttpOptions(options);
      expect(httpOpts.method).assertEqual('POST' as Object);
      expect(httpOpts.extraData).assertEqual('{"key":"value"}');
      expect(httpOpts.connectTimeout).assertEqual(30000);
      expect(httpOpts.readTimeout).assertEqual(60000);
    });

    it('buildHttpOptions_get_without_body', 0, () => {
      const options: HttpRequestOptions = {
        method: HttpMethod.GET,
        url: 'https://example.com'
      };

      const httpOpts = buildHttpOptions(options);
      expect(httpOpts.method).assertEqual('GET' as Object);
      // GET 无 body,extraData 应为 undefined
      expect(httpOpts.extraData).assertUndefined();
    });

    it('buildHttpOptions_empty_body_not_set', 0, () => {
      const options: HttpRequestOptions = {
        method: HttpMethod.POST,
        url: 'https://example.com',
        body: ''
      };

      const httpOpts = buildHttpOptions(options);
      expect(httpOpts.extraData).assertUndefined();
    });

    it('buildHttpOptions_headers_converted', 0, () => {
      const headers: HttpHeaders = new Map<string, string>();
      headers.set('Content-Type', 'application/json');
      headers.set('Authorization', 'Bearer test-token');
      const options: HttpRequestOptions = {
        method: HttpMethod.POST,
        url: 'https://example.com',
        headers: headers,
        body: '{"a":1}'
      };

      const httpOpts = buildHttpOptions(options);
      const headerObj: Record<string, string> = httpOpts.header as Record<string, string>;
      expect(headerObj['Content-Type']).assertEqual('application/json');
      expect(headerObj['Authorization']).assertEqual('Bearer test-token');
    });

    it('buildHttpOptions_no_headers', 0, () => {
      const options: HttpRequestOptions = {
        method: HttpMethod.GET,
        url: 'https://example.com'
      };

      const httpOpts = buildHttpOptions(options);
      const headerObj: Record<string, string> = httpOpts.header as Record<string, string>;
      // 空 headers 应该返回空对象,不抛错
      expect(Object.keys(headerObj).length).assertEqual(0);
    });

    // ===== convertBusinessError 测试 =====

    it('convertBusinessError_network_2300000', 0, () => {
      const err: BusinessError = {
        code: 2300000,
        message: 'network error',
        name: 'BusinessError'
      };
      const netErr = convertBusinessError(err);
      expect(netErr.type).assertEqual(NetworkErrorType.Network);
    });

    it('convertBusinessError_timeout_2300025', 0, () => {
      const err: BusinessError = {
        code: 2300025,
        message: 'timeout',
        name: 'BusinessError'
      };
      const netErr = convertBusinessError(err);
      expect(netErr.type).assertEqual(NetworkErrorType.Timeout);
    });

    it('convertBusinessError_timeout_2300026', 0, () => {
      const err: BusinessError = {
        code: 2300026,
        message: 'timeout',
        name: 'BusinessError'
      };
      const netErr = convertBusinessError(err);
      expect(netErr.type).assertEqual(NetworkErrorType.Timeout);
    });

    it('convertBusinessError_connection_refused_2300006', 0, () => {
      const err: BusinessError = {
        code: 2300006,
        message: 'connection refused',
        name: 'BusinessError'
      };
      const netErr = convertBusinessError(err);
      expect(netErr.type).assertEqual(NetworkErrorType.Network);
    });

    it('convertBusinessError_cancelled_2300023', 0, () => {
      const err: BusinessError = {
        code: 2300023,
        message: 'aborted',
        name: 'BusinessError'
      };
      const netErr = convertBusinessError(err);
      expect(netErr.type).assertEqual(NetworkErrorType.Cancelled);
    });

    it('convertBusinessError_unknown_code', 0, () => {
      const err: BusinessError = {
        code: 9999,
        message: 'unknown',
        name: 'BusinessError'
      };
      const netErr = convertBusinessError(err);
      expect(netErr.type).assertEqual(NetworkErrorType.Unknown);
    });

    it('convertBusinessError_preserves_message', 0, () => {
      const err: BusinessError = {
        code: 2300000,
        message: 'specific network error',
        name: 'BusinessError'
      };
      const netErr = convertBusinessError(err);
      expect(netErr.message).assertEqual('specific network error');
      expect(netErr.causeMessage).assertEqual('specific network error');
    });

    it('convertBusinessError_undefined_message', 0, () => {
      const err: BusinessError = {
        code: 2300000,
        message: '',
        name: 'BusinessError'
      };
      const netErr = convertBusinessError(err);
      // 空消息时使用默认值
      expect(netErr.message).assertEqual('Unknown error');
    });
  });
}
