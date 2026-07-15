/**
 * OpenAiUrlBuilder 本地单元测试
 *
 * 测试 URL 组合逻辑和请求体构建。
 * 不依赖设备 API。
 */

import { describe, it, expect } from '@ohos/hypium';
import { buildChatCompletionsUrl, buildChatCompletionsBody, UrlBuildResult } from '../main/ets/network/streaming/OpenAiUrlBuilder';

export default function openAiUrlBuilderTest() {
  describe('OpenAiUrlBuilderTest', () => {

    // 1. Base URL 已带 /chat/completions
    it('url_already_has_chat_completions', 0, () => {
      const r: UrlBuildResult = buildChatCompletionsUrl('https://example.com/v1/chat/completions');
      expect(r.success).assertTrue();
      expect(r.url).assertEqual('https://example.com/v1/chat/completions');
      expect(r.error).assertEqual('');
    });

    // 2. Base URL 以 /v1 结尾
    it('url_ends_with_v1', 0, () => {
      const r: UrlBuildResult = buildChatCompletionsUrl('https://example.com/v1');
      expect(r.success).assertTrue();
      expect(r.url).assertEqual('https://example.com/v1/chat/completions');
    });

    // 3. Base URL 尾部有 /
    it('url_trailing_slash', 0, () => {
      const r1: UrlBuildResult = buildChatCompletionsUrl('https://example.com/v1/');
      expect(r1.success).assertTrue();
      expect(r1.url).assertEqual('https://example.com/v1/chat/completions');

      const r2: UrlBuildResult = buildChatCompletionsUrl('https://example.com/v1/chat/completions/');
      expect(r2.success).assertTrue();
      expect(r2.url).assertEqual('https://example.com/v1/chat/completions');

      const r3: UrlBuildResult = buildChatCompletionsUrl('https://example.com///');
      expect(r3.success).assertTrue();
      expect(r3.url).assertEqual('https://example.com/v1/chat/completions');
    });

    // 4. 非法 URL(空字符串)
    it('url_empty', 0, () => {
      const r: UrlBuildResult = buildChatCompletionsUrl('');
      expect(r.success).assertFalse();
      expect(r.error.length > 0).assertTrue();
    });

    // 5. 非 HTTP/HTTPS 协议
    it('url_non_http_protocol', 0, () => {
      const r1: UrlBuildResult = buildChatCompletionsUrl('ftp://example.com/v1');
      expect(r1.success).assertFalse();
      expect(r1.error.length > 0).assertTrue();

      const r2: UrlBuildResult = buildChatCompletionsUrl('file:///path/to/api');
      expect(r2.success).assertFalse();

      const r3: UrlBuildResult = buildChatCompletionsUrl('ws://example.com/v1');
      expect(r3.success).assertFalse();
    });

    // 6. 仅域名(无路径),追加 /v1/chat/completions
    it('url_domain_only', 0, () => {
      const r: UrlBuildResult = buildChatCompletionsUrl('https://example.com');
      expect(r.success).assertTrue();
      expect(r.url).assertEqual('https://example.com/v1/chat/completions');
    });

    // 7. HTTP 协议也允许(用于本地测试)
    it('url_http_allowed', 0, () => {
      const r: UrlBuildResult = buildChatCompletionsUrl('http://127.0.0.1:8765/v1');
      expect(r.success).assertTrue();
      expect(r.url).assertEqual('http://127.0.0.1:8765/v1/chat/completions');
    });

    // 8. 带 API 路径前缀
    it('url_with_api_prefix', 0, () => {
      const r: UrlBuildResult = buildChatCompletionsUrl('https://example.com/api/v1');
      expect(r.success).assertTrue();
      expect(r.url).assertEqual('https://example.com/api/v1/chat/completions');
    });

    // 9. 请求体构建
    it('build_request_body', 0, () => {
      const body: string = buildChatCompletionsBody('gpt-4o', 'Hello');
      expect(body.length > 0).assertTrue();
      expect(body.includes('"model":"gpt-4o"')).assertTrue();
      expect(body.includes('"stream":true')).assertTrue();
      expect(body.includes('"temperature":0.7')).assertTrue();
      expect(body.includes('"role":"user"')).assertTrue();
      expect(body.includes('"content":"Hello"')).assertTrue();
    });

    // 10. 请求体包含中文
    it('build_request_body_chinese', 0, () => {
      const body: string = buildChatCompletionsBody('deepseek-chat', '你好世界');
      expect(body.includes('你好世界')).assertTrue();
    });

    // 11. 请求体可被 JSON.parse 还原
    it('build_request_body_parseable', 0, () => {
      const body: string = buildChatCompletionsBody('test-model', 'test message');
      let parsed: Record<string, Object> = JSON.parse(body);
      expect(parsed['model']).assertEqual('test-model');
      expect(parsed['stream']).assertEqual(true);
      expect(parsed['temperature']).assertEqual(0.7);
    });
  });
}
