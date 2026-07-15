/**
 * OpenAiSseDeltaParser 本地单元测试
 *
 * 测试 OpenAI SSE delta 解析逻辑。
 * 不依赖设备 API。
 */

import { describe, it, expect } from '@ohos/hypium';
import { parseOpenAiDelta, OpenAiDeltaResult } from '../main/ets/network/streaming/OpenAiSseDeltaParser';

export default function openAiSseDeltaParserTest() {
  describe('OpenAiSseDeltaParserTest', () => {

    // 6. delta.content 正常字符串
    it('delta_content_normal', 0, () => {
      const data: string = '{"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.done).assertFalse();
      expect(r.hasContent).assertTrue();
      expect(r.content).assertEqual('Hello');
      expect(r.parseError).assertUndefined();
    });

    // 7. delta.content 为空字符串
    it('delta_content_empty_string', 0, () => {
      const data: string = '{"choices":[{"index":0,"delta":{"content":""},"finish_reason":null}]}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.done).assertFalse();
      expect(r.hasContent).assertTrue();
      expect(r.content).assertEqual('');
    });

    // 8. delta.content 为 null(首帧 role 事件)
    it('delta_content_null', 0, () => {
      const data: string = '{"choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.done).assertFalse();
      expect(r.hasContent).assertFalse();
      expect(r.content).assertEqual('');
      expect(r.parseError).assertUndefined();
    });

    // 9. delta.role 事件(无 content 字段)
    it('delta_role_only', 0, () => {
      const data: string = '{"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.done).assertFalse();
      expect(r.hasContent).assertFalse();
      expect(r.content).assertEqual('');
      expect(r.parseError).assertUndefined();
    });

    // 10. choices 为空数组
    it('choices_empty', 0, () => {
      const data: string = '{"choices":[],"id":"chatcmpl-xxx"}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.done).assertFalse();
      expect(r.hasContent).assertFalse();
      expect(r.content).assertEqual('');
      expect(r.parseError).assertUndefined();
    });

    // 11. finish_reason
    it('finish_reason', 0, () => {
      const data: string = '{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.done).assertFalse();
      expect(r.hasContent).assertFalse();
      expect(r.finishReason).assertEqual('stop');
    });

    // 12. usage-only 事件(无 choices)
    it('usage_only_event', 0, () => {
      const data: string = '{"id":"chatcmpl-xxx","model":"gpt-4o","usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.done).assertFalse();
      expect(r.hasContent).assertFalse();
      expect(r.content).assertEqual('');
      expect(r.parseError).assertUndefined();
    });

    // 13. 非 JSON data
    it('non_json_data', 0, () => {
      const data: string = 'this is not json';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.done).assertFalse();
      expect(r.hasContent).assertFalse();
      expect(r.content).assertEqual('');
      expect(r.parseError).assertEqual('Non-JSON SSE data');
    });

    // 14. [DONE]
    it('done_mark', 0, () => {
      const r: OpenAiDeltaResult = parseOpenAiDelta('[DONE]');
      expect(r.done).assertTrue();
      expect(r.hasContent).assertFalse();
      expect(r.content).assertEqual('');
      expect(r.parseError).assertUndefined();
    });

    // 14b. [DONE] 带空格
    it('done_mark_with_spaces', 0, () => {
      const r: OpenAiDeltaResult = parseOpenAiDelta('  [DONE]  ');
      expect(r.done).assertTrue();
    });

    // 15. 错误对象 JSON
    it('error_object_json', 0, () => {
      const data: string = '{"error":{"message":"Invalid API key","type":"invalid_request_error","code":"invalid_api_key"}}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.done).assertFalse();
      expect(r.hasContent).assertFalse();
      expect(r.parseError).assertEqual('Invalid API key');
    });

    // 15b. 错误对象无 message
    it('error_object_no_message', 0, () => {
      const data: string = '{"error":{"type":"server_error","code":"internal"}}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.parseError).assertEqual('Server returned error object without message');
    });

    // 16. 多段 delta 拼接顺序
    it('multi_delta_concat_order', 0, () => {
      const chunks: string[] = [
        '{"choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}',
        '{"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}',
        '{"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}',
        '{"choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}',
        '{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
        '[DONE]'
      ];

      let fullText: string = '';
      let doneSeen: boolean = false;
      let finishReason: string = '';

      for (let i = 0; i < chunks.length; i++) {
        const r: OpenAiDeltaResult = parseOpenAiDelta(chunks[i]);
        if (r.hasContent) {
          fullText += r.content;
        }
        if (r.done) {
          doneSeen = true;
        }
        if (r.finishReason !== undefined) {
          finishReason = r.finishReason;
        }
      }

      expect(fullText).assertEqual('Hello world!');
      expect(doneSeen).assertTrue();
      expect(finishReason).assertEqual('stop');
    });

    // 17. 中文 delta
    it('delta_content_chinese', 0, () => {
      const data: string = '{"choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.hasContent).assertTrue();
      expect(r.content).assertEqual('你好');
    });

    // 18. Emoji delta
    it('delta_content_emoji', 0, () => {
      const data: string = '{"choices":[{"index":0,"delta":{"content":"🌍"},"finish_reason":null}]}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.hasContent).assertTrue();
      expect(r.content).assertEqual('🌍');
    });

    // 19. 空字符串 data
    it('empty_data', 0, () => {
      const r: OpenAiDeltaResult = parseOpenAiDelta('');
      expect(r.done).assertFalse();
      expect(r.hasContent).assertFalse();
      expect(r.parseError).assertUndefined();
    });

    // 20. JSON 解析为非对象(如数组)
    it('json_array_not_object', 0, () => {
      const data: string = '[1,2,3]';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.hasContent).assertFalse();
      expect(r.parseError).assertEqual('JSON parsed to non-object');
    });

    // 21. finish_reason 为 null 字符串(容错)
    it('finish_reason_null_string', 0, () => {
      const data: string = '{"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"null"}]}';
      const r: OpenAiDeltaResult = parseOpenAiDelta(data);
      expect(r.hasContent).assertTrue();
      expect(r.content).assertEqual('hi');
      expect(r.finishReason).assertUndefined();
    });
  });
}
