/**
 * SseParser 本地单元测试
 *
 * 不依赖真机能力、hilog、@ohos.net.http、rcp 或第三方库。
 * 所有测试可重复执行,测试之间不共享可变状态(每个 it 创建新 SseParser)。
 */

import { describe, it, expect } from '@ohos/hypium';
import { SseParser } from '../main/ets/network/streaming/SseParser';
import { SseEvent, SseParseResult } from '../main/ets/network/streaming/SseTypes';

export default function sseParserTest() {
  describe('SseParserTest', () => {

    // 1. 单个完整 data 事件
    it('single_complete_data_event', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('data: hello\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.errors.length).assertEqual(0);
      expect(r.events[0].data).assertEqual('hello');
      expect(r.events[0].isDone).assertFalse();
    });

    // 2. 一个 chunk 中多个事件
    it('multiple_events_in_one_chunk', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('data: first\n\ndata: second\n\n');
      expect(r.events.length).assertEqual(2);
      expect(r.events[0].data).assertEqual('first');
      expect(r.events[1].data).assertEqual('second');
    });

    // 3. 一个事件拆成两个 chunk
    it('event_split_across_two_chunks', 0, () => {
      const p: SseParser = new SseParser();
      let r: SseParseResult = p.feed('data: {"choices":[{"del');
      expect(r.events.length).assertEqual(0);
      r = p.feed('ta":{"content":"你"}}]}\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('{"choices":[{"delta":{"content":"你"}}]}');
    });

    // 4. 一个事件拆成三个以上 chunk
    it('event_split_across_three_plus_chunks', 0, () => {
      const p: SseParser = new SseParser();
      let r: SseParseResult = p.feed('data: ');
      expect(r.events.length).assertEqual(0);
      r = p.feed('line1');
      expect(r.events.length).assertEqual(0);
      r = p.feed('line2');
      expect(r.events.length).assertEqual(0);
      r = p.feed('\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('line1line2');
    });

    // 5. chunk 边界拆在 \r\n 中间
    it('chunk_boundary_between_cr_and_lf', 0, () => {
      const p: SseParser = new SseParser();
      // 第一片:data: hello\r — \r 单独出现被识别为行尾,消费 'data: hello'
      let r: SseParseResult = p.feed('data: hello\r');
      expect(r.events.length).assertEqual(0);
      // 第二片:\n — 作为空行,触发 dispatch
      r = p.feed('\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('hello');
    });

    // 6. 多行 data 合并
    it('multi_line_data_merged', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('data: line one\ndata: line two\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('line one\nline two');
    });

    // 7. event + data
    it('event_and_data', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('event: ping\ndata: pong\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].event).assertEqual('ping');
      expect(r.events[0].data).assertEqual('pong');
    });

    // 8. id + data
    it('id_and_data', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('id: 42\ndata: hello\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].id).assertEqual('42');
      expect(r.events[0].data).assertEqual('hello');
    });

    // 9. 合法 retry
    it('valid_retry', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('retry: 3000\ndata: hello\n\n');
      expect(r.errors.length).assertEqual(0);
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].retry).assertEqual(3000);
    });

    // 10. 非法 retry
    it('invalid_retry', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('retry: abc\ndata: hello\n\n');
      expect(r.errors.length).assertEqual(1);
      expect(r.errors[0].recoverable).assertTrue();
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('hello');
    });

    // 11. 注释行
    it('comment_line', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed(': this is a comment\ndata: hello\n\n');
      expect(r.errors.length).assertEqual(0);
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('hello');
    });

    // 12. 未知字段
    it('unknown_field_ignored', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('foo: bar\ndata: hello\n\n');
      expect(r.errors.length).assertEqual(0);
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('hello');
    });

    // 13. 空 data
    it('empty_data', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('data:\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('');
    });

    // 14. 中文内容
    it('chinese_content', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('data: 你好,世界!\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('你好,世界!');
    });

    // 15. Emoji 内容
    it('emoji_content', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('data: Hello 🌍🚀\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('Hello 🌍🚀');
    });

    // 16. JSON 字符串作为 data,但不解析 JSON
    it('json_string_as_data_not_parsed', 0, () => {
      const p: SseParser = new SseParser();
      const json: string = '{"choices":[{"delta":{"content":"hi"}}]}';
      const r: SseParseResult = p.feed('data: ' + json + '\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual(json);
      expect(r.events[0].isDone).assertFalse();
    });

    // 17. data: [DONE]
    it('data_done_mark', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('data: [DONE]\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].isDone).assertTrue();
      expect(r.events[0].data).assertEqual('[DONE]');
    });

    // 18. [DONE] 前后空格
    it('done_with_surrounding_spaces', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('data:   [DONE]   \n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].isDone).assertTrue();
    });

    // 19. finish 处理无最终空行的完整事件
    it('finish_complete_event_without_trailing_newline', 0, () => {
      const p: SseParser = new SseParser();
      p.feed('data: hello\n');
      const r: SseParseResult = p.finish();
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('hello');
      expect(r.errors.length).assertEqual(0);
    });

    // 20. finish 处理不完整事件
    it('finish_incomplete_event', 0, () => {
      const p: SseParser = new SseParser();
      p.feed('data: hel');
      const r: SseParseResult = p.finish();
      // 不完整但仍有 data 行,finish 应尝试作为最后事件
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('hel');
    });

    // 21. reset 后重新使用
    it('reset_and_reuse', 0, () => {
      const p: SseParser = new SseParser();
      p.feed('data: first\n\n');
      expect(p.getBufferedLength()).assertEqual(0);
      p.feed('data: partial');
      expect(p.getBufferedLength() > 0).assertTrue();
      p.reset();
      expect(p.getBufferedLength()).assertEqual(0);
      const r: SseParseResult = p.feed('data: second\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('second');
    });

    // 22. 超过最大缓冲限制
    it('exceed_max_buffer', 0, () => {
      const p: SseParser = new SseParser();
      // 构造超长不闭合数据(70006 字符 > 65536)
      let big: string = 'data: ';
      for (let i = 0; i < 70000; i++) {
        big += 'x';
      }
      const r: SseParseResult = p.feed(big);
      expect(r.errors.length).assertEqual(1);
      expect(r.errors[0].recoverable).assertFalse();
      expect(p.getBufferedLength()).assertEqual(0);
      // 重置后可继续使用
      const r2: SseParseResult = p.feed('data: ok\n\n');
      expect(r2.events.length).assertEqual(1);
    });

    // 23. 一个异常事件之后仍可解析正常事件
    it('recover_after_error_event', 0, () => {
      const p: SseParser = new SseParser();
      const r1: SseParseResult = p.feed('retry: abc\ndata: bad\n\n');
      expect(r1.errors.length).assertEqual(1);
      expect(r1.events.length).assertEqual(1);
      const r2: SseParseResult = p.feed('data: good\n\n');
      expect(r2.errors.length).assertEqual(0);
      expect(r2.events.length).assertEqual(1);
      expect(r2.events[0].data).assertEqual('good');
    });

    // 24. 连续空行
    it('consecutive_blank_lines', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed('data: hello\n\n\n\n\n');
      expect(r.events.length).assertEqual(1);
      expect(r.events[0].data).assertEqual('hello');
    });

    // 25. 仅注释、不产生事件
    it('only_comments_no_events', 0, () => {
      const p: SseParser = new SseParser();
      const r: SseParseResult = p.feed(': comment 1\n: comment 2\n\n');
      expect(r.events.length).assertEqual(0);
      expect(r.errors.length).assertEqual(0);
    });
  });
}
