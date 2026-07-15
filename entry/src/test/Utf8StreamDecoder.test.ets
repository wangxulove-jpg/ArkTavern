/**
 * Utf8StreamDecoder + TransportState 本地单元测试
 *
 * 不依赖真机能力、hilog、@ohos.net.http。
 * 覆盖:
 * - UTF-8 中文跨 chunk
 * - Emoji 跨 chunk
 * - 连续多个字符边界
 * - flush 正常
 * - flush 时存在非法尾部字节
 * - abort 状态机的幂等逻辑
 * - 完成后忽略迟到回调
 * - 错误后只通知一次
 * - complete 只通知一次
 */

import { describe, it, expect } from '@ohos/hypium';
import { Utf8StreamDecoder } from '../main/ets/network/streaming/Utf8StreamDecoder';
import { TransportState, isTerminalState, canTransitionTo } from '../main/ets/network/streaming/StreamTransportTypes';

export default function utf8AndStateMachineTest() {
  describe('Utf8StreamDecoderTest', () => {
    // 1. UTF-8 中文跨 chunk
    it('chinese_across_chunks', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      // 你 = E4 BD A0, 好 = E5 A5 BD
      // 第一个 chunk 只有 E4 BD(不完整)
      const r1: string = decoder.feed(new Uint8Array([0xE4, 0xBD]));
      expect(r1).assertEqual('');
      // 第二个 chunk 补全 A0 + 完整的 好
      const r2: string = decoder.feed(new Uint8Array([0xA0, 0xE5, 0xA5, 0xBD]));
      expect(r2).assertEqual('你好');
    });

    // 2. Emoji 跨 chunk
    it('emoji_across_chunks', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      // 🌍 = F0 9F 8C 8D (4 字节)
      // 拆成两个 chunk: F0 9F | 8C 8D
      const r1: string = decoder.feed(new Uint8Array([0xF0, 0x9F]));
      expect(r1).assertEqual('');
      const r2: string = decoder.feed(new Uint8Array([0x8C, 0x8D]));
      expect(r2).assertEqual('🌍');
    });

    // 3. 连续多个字符边界
    it('multiple_chars_boundary', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      // "AB你好" = 41 42 E4 BD A0 E5 A5 BD
      // 一次性喂入
      const r: string = decoder.feed(new Uint8Array([0x41, 0x42, 0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD]));
      expect(r).assertEqual('AB你好');
    });

    // 4. flush 正常(无 pending)
    it('flush_no_pending', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      decoder.feed(new Uint8Array([0x41, 0x42]));
      const r: string = decoder.flush();
      expect(r).assertEqual('');
    });

    // 5. flush 时存在非法尾部字节(未完成序列)
    it('flush_with_incomplete_sequence', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      // 只有 E4 BD A0 的前两个字节,flush 应返回替换字符
      decoder.feed(new Uint8Array([0xE4, 0xBD]));
      const r: string = decoder.flush();
      expect(r).assertEqual('\uFFFD');
    });

    // 6. 非法起始字节
    it('invalid_leading_byte', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      // 0x80 是后续字节,不能作为起始字节
      const r: string = decoder.feed(new Uint8Array([0x80, 0x41]));
      expect(r).assertEqual('\uFFFDA');
    });

    // 7. 非法后续字节
    it('invalid_continuation_byte', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      // E4 后面应该是后续字节,但给了 0x41('A')
      const r: string = decoder.feed(new Uint8Array([0xE4, 0x41]));
      expect(r.includes('\uFFFD')).assertTrue();
      expect(r.includes('A')).assertTrue();
    });

    // 8. 过长编码(2 字节编码 ASCII)
    it('overlong_encoding_2byte', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      // C0 80 是 '/' 的过长编码(非法),输出替换字符
      const r: string = decoder.feed(new Uint8Array([0xC0, 0x80]));
      expect(r).assertEqual('\uFFFD');
    });

    // 9. 代理对范围非法
    it('surrogate_range_invalid', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      // U+D800 = ED A0 80(3 字节,非法代理对)
      const r: string = decoder.feed(new Uint8Array([0xED, 0xA0, 0x80]));
      expect(r).assertEqual('\uFFFD');
    });

    // 10. reset 后可复用
    it('reset_and_reuse', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      decoder.feed(new Uint8Array([0xE4, 0xBD])); // 不完整
      expect(decoder.getPendingLength()).assertEqual(2);
      decoder.reset();
      expect(decoder.getPendingLength()).assertEqual(0);
      const r: string = decoder.feed(new Uint8Array([0x41]));
      expect(r).assertEqual('A');
    });

    // 11. 空输入
    it('empty_input', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      const r: string = decoder.feed(new Uint8Array([]));
      expect(r).assertEqual('');
    });

    // 12. 混合 ASCII 和多字节
    it('mixed_ascii_and_multibyte', 0, () => {
      const decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
      // "Hi你好!" = 48 69 E4 BD A0 E5 A5 BD 21
      const r: string = decoder.feed(new Uint8Array([0x48, 0x69, 0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD, 0x21]));
      expect(r).assertEqual('Hi你好!');
    });
  });

  describe('TransportStateMachineTest', () => {
    // 13. abort 状态机的幂等逻辑
    it('terminal_states_are_terminal', 0, () => {
      expect(isTerminalState(TransportState.COMPLETED)).assertTrue();
      expect(isTerminalState(TransportState.ERRORED)).assertTrue();
      expect(isTerminalState(TransportState.ABORTED)).assertTrue();
      expect(isTerminalState(TransportState.IDLE)).assertFalse();
      expect(isTerminalState(TransportState.RECEIVING)).assertFalse();
    });

    // 14. 完成后忽略迟到回调(终态不可转换)
    it('completed_ignores_late_callbacks', 0, () => {
      // COMPLETED 是终态,不能转换到任何状态
      expect(canTransitionTo(TransportState.COMPLETED, TransportState.RECEIVING)).assertFalse();
      expect(canTransitionTo(TransportState.COMPLETED, TransportState.ERRORED)).assertFalse();
      expect(canTransitionTo(TransportState.COMPLETED, TransportState.ABORTED)).assertFalse();
      expect(canTransitionTo(TransportState.COMPLETED, TransportState.COMPLETED)).assertFalse();
    });

    // 15. 错误后只通知一次(ERRORED 是终态)
    it('errored_is_terminal', 0, () => {
      expect(canTransitionTo(TransportState.ERRORED, TransportState.COMPLETED)).assertFalse();
      expect(canTransitionTo(TransportState.ERRORED, TransportState.ABORTED)).assertFalse();
      expect(canTransitionTo(TransportState.ERRORED, TransportState.ERRORED)).assertFalse();
    });

    // 16. complete 只通知一次(从 RECEIVING 只能转一次到 COMPLETED)
    it('receiving_to_completed_once', 0, () => {
      expect(canTransitionTo(TransportState.RECEIVING, TransportState.COMPLETED)).assertTrue();
      // 但 COMPLETED 之后不能再转
      expect(canTransitionTo(TransportState.COMPLETED, TransportState.COMPLETED)).assertFalse();
    });

    // 17. IDLE 到 RECEIVING 合法
    it('idle_to_receiving_valid', 0, () => {
      expect(canTransitionTo(TransportState.IDLE, TransportState.RECEIVING)).assertTrue();
    });

    // 18. IDLE 不能直接到终态
    it('idle_cannot_jump_to_terminal', 0, () => {
      expect(canTransitionTo(TransportState.IDLE, TransportState.COMPLETED)).assertFalse();
      expect(canTransitionTo(TransportState.IDLE, TransportState.ERRORED)).assertFalse();
      expect(canTransitionTo(TransportState.IDLE, TransportState.ABORTED)).assertFalse();
    });

    // 19. RECEIVING 到 ABORTED 合法(abort)
    it('receiving_to_aborted_valid', 0, () => {
      expect(canTransitionTo(TransportState.RECEIVING, TransportState.ABORTED)).assertTrue();
    });

    // 20. RECEIVING 到 ERRORED 合法
    it('receiving_to_errored_valid', 0, () => {
      expect(canTransitionTo(TransportState.RECEIVING, TransportState.ERRORED)).assertTrue();
    });

    // 21. ABORTED 是终态(幂等 abort)
    it('aborted_is_terminal', 0, () => {
      expect(canTransitionTo(TransportState.ABORTED, TransportState.COMPLETED)).assertFalse();
      expect(canTransitionTo(TransportState.ABORTED, TransportState.ERRORED)).assertFalse();
      expect(canTransitionTo(TransportState.ABORTED, TransportState.ABORTED)).assertFalse();
    });
  });
}
