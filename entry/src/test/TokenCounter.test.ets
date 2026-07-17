/**
 * TokenCounter 单元测试
 *
 * 覆盖:
 * 1. 空文本返回 0
 * 2. 纯英文短文本
 * 3. 连续英文单词估算
 * 4. 纯中文文本不会按四字符一个 Token 低估
 * 5. 中英文混合文本
 * 6. 数字文本
 * 7. 标点符号计数
 * 8. 连续空格处理
 * 9. 换行文本
 * 10. 单个 Emoji 按完整 code point 处理
 * 11. 多个 Emoji
 * 12. 未配对代理字符不会崩溃
 * 13. 结果始终为非负整数
 * 14. 相同文本多次估算一致
 * 15. 原始字符串未修改
 * 16. 单条消息包含固定开销
 * 17. 多条消息为各消息之和加结尾开销
 * 18. 空消息数组返回结尾开销或 0
 * 19. 原始消息数组未修改
 * 20. 原始消息对象未修改
 *
 * TokenBudget 字段测试:
 * 21. 正常预算计算
 * 22. 输入未超出预算
 * 23. 输入恰好等于预算
 * 24. 输入超出预算
 * 25. contextWindow 为 0
 * 26. contextWindow 为负数
 * 27. reservedOutputTokens 为负数
 * 28. reservedOutputTokens 大于 contextWindow
 * 29. remainingInputTokens 可为负数
 * 30. exceedsBudget 计算正确
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  TokenCounter,
  estimateTextTokens,
  estimateMessageTokens,
  estimateMessagesTokens
} from '../main/ets/services/TokenCounter';
import { ChatMessage, createChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import {
  TokenBudget,
  createTokenBudget,
  DEFAULT_CONTEXT_WINDOW,
  DEFAULT_RESERVED_OUTPUT_TOKENS
} from '../main/ets/models/TokenBudget';

const MESSAGE_FIXED: number = 4;
const PROMPT_TRAILING: number = 2;

function makeMsg(id: string, content: string, role: ChatRole = ChatRole.User): ChatMessage {
  return createChatMessage(id, role, content, 1000);
}

export default function tokenCounterTest(): void {
  describe('TokenCounter_text', () => {
    it('Empty_text_returns_zero', 0, () => {
      expect(estimateTextTokens('')).assertEqual(0);
    });

    it('Short_english_text', 0, () => {
      // "Hi" → 1 word (2 chars) → ceil(2/4) = 1
      expect(estimateTextTokens('Hi')).assertEqual(1);
    });

    it('Continuous_english_words', 0, () => {
      // "HelloWorld" → 10 chars → ceil(10/4) = 3
      expect(estimateTextTokens('HelloWorld')).assertEqual(3);
    });

    it('Chinese_text_not_underestimated', 0, () => {
      // 4 个 CJK → 4 Token(每个 1 Token)
      const t: number = estimateTextTokens('你好世界');
      expect(t).assertEqual(4);
      // 关键:不能被除以 4 后为 1
      expect(t > 1).assertEqual(true);
    });

    it('Mixed_chinese_english', 0, () => {
      // "Hello 你好" → "Hello" 5 chars → ceil(5/4)=2;空格 1; "你好" 2 CJK → 2; total 5
      expect(estimateTextTokens('Hello 你好')).assertEqual(5);
    });

    it('Number_text', 0, () => {
      // "12345" → 5 chars → ceil(5/4) = 2
      expect(estimateTextTokens('12345')).assertEqual(2);
    });

    it('Punctuation_counted', 0, () => {
      // "!!!" → 3
      expect(estimateTextTokens('!!!')).assertEqual(3);
    });

    it('Consecutive_spaces_handled', 0, () => {
      // 3 个连续空格 → 每个 1 Token(简化策略)
      expect(estimateTextTokens('   ')).assertEqual(3);
    });

    it('Newline_text', 0, () => {
      // "a\nb" → "a" 1, "\n" 1, "b" 1 → 3
      expect(estimateTextTokens('a\nb')).assertEqual(3);
    });

    it('Single_emoji_full_codepoint', 0, () => {
      // "🌍" → 1 完整 code point → 1 Token
      expect(estimateTextTokens('🌍')).assertEqual(1);
    });

    it('Multiple_emoji', 0, () => {
      // "🌍🚀" → 2 code points → 2 Token
      expect(estimateTextTokens('🌍🚀')).assertEqual(2);
    });

    it('Unpaired_surrogate_does_not_crash', 0, () => {
      // 0xD83D 是高代理(未配对),应作为独立 code point 计 1 Token
      const orphanHigh: string = String.fromCharCode(0xD83D);
      const t: number = estimateTextTokens(orphanHigh);
      expect(t >= 1).assertEqual(true);

      // 0xDC00 是低代理(未配对),应作为独立 code point 计 1 Token
      const orphanLow: string = String.fromCharCode(0xDC00);
      const t2: number = estimateTextTokens(orphanLow);
      expect(t2 >= 1).assertEqual(true);
    });

    it('Result_is_non_negative_integer', 0, () => {
      const cases: string[] = ['', 'a', '你好', '🌍', '   ', '\n\n', 'A1!'];
      for (let i = 0; i < cases.length; i++) {
        const v: number = estimateTextTokens(cases[i]);
        expect(v >= 0).assertEqual(true);
        expect(Number.isInteger(v)).assertEqual(true);
      }
    });

    it('Same_text_yields_same_result_repeatedly', 0, () => {
      const a: number = estimateTextTokens('Hello world 你好🌍');
      const b: number = estimateTextTokens('Hello world 你好🌍');
      const c: number = estimateTextTokens('Hello world 你好🌍');
      expect(a).assertEqual(b);
      expect(b).assertEqual(c);
    });

    it('Original_string_not_modified', 0, () => {
      const original: string = 'Hello 你好🌍 !!!';
      const snapshot: string = original;
      estimateTextTokens(original);
      expect(original).assertEqual(snapshot);
      expect(original.length).assertEqual(snapshot.length);
    });
  });

  describe('TokenCounter_message_and_prompt', () => {
    it('Single_message_includes_fixed_overhead', 0, () => {
      const m: ChatMessage = makeMsg('m1', 'Hi');
      // "Hi" → 1, + 4 fixed = 5
      expect(estimateMessageTokens(m)).assertEqual(MESSAGE_FIXED + 1);
    });

    it('Multiple_messages_sum_plus_trailing', 0, () => {
      const msgs: ChatMessage[] = [
        makeMsg('m1', 'Hi'),
        makeMsg('m2', 'Hello'),
        makeMsg('m3', '你好')
      ];
      // m1: 4+1=5, m2: 4+ceil(5/4)=4+2=6, m3: 4+2=6, sum=17, +trailing 2 = 19
      expect(estimateMessagesTokens(msgs)).assertEqual(5 + 6 + 6 + PROMPT_TRAILING);
    });

    it('Empty_messages_array_returns_trailing_or_zero', 0, () => {
      // 空数组不附加结尾开销(消息数 = 0)
      expect(estimateMessagesTokens([])).assertEqual(0);
    });

    it('Original_messages_array_not_modified', 0, () => {
      const msgs: ChatMessage[] = [
        makeMsg('m1', 'Hi'),
        makeMsg('m2', '你好')
      ];
      const beforeLength: number = msgs.length;
      const beforeContent0: string = msgs[0].content;
      const beforeContent1: string = msgs[1].content;
      estimateMessagesTokens(msgs);
      expect(msgs.length).assertEqual(beforeLength);
      expect(msgs[0].content).assertEqual(beforeContent0);
      expect(msgs[1].content).assertEqual(beforeContent1);
    });

    it('Original_message_objects_not_modified', 0, () => {
      const m: ChatMessage = makeMsg('m1', 'Hi');
      const beforeId: string = m.id;
      const beforeRole: ChatRole = m.role;
      const beforeContent: string = m.content;
      const beforeCreated: number = m.createdAt;
      estimateMessageTokens(m);
      expect(m.id).assertEqual(beforeId);
      expect(m.role).assertEqual(beforeRole);
      expect(m.content).assertEqual(beforeContent);
      expect(m.createdAt).assertEqual(beforeCreated);
    });
  });

  describe('TokenCounter_service_class', () => {
    it('Class_delegates_to_free_functions', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const m: ChatMessage = makeMsg('m1', 'Hi');
      const msgs: ChatMessage[] = [m, makeMsg('m2', 'Hello')];

      expect(counter.estimateText('Hi')).assertEqual(estimateTextTokens('Hi'));
      expect(counter.estimateMessage(m)).assertEqual(estimateMessageTokens(m));
      expect(counter.estimateMessages(msgs)).assertEqual(estimateMessagesTokens(msgs));
    });
  });

  describe('TokenBudget_calculation', () => {
    it('Normal_budget_calculation', 0, () => {
      const b: TokenBudget = createTokenBudget(1000, 32768, 2048);
      expect(b.contextWindow).assertEqual(32768);
      expect(b.reservedOutputTokens).assertEqual(2048);
      expect(b.availableInputTokens).assertEqual(30720);
      expect(b.estimatedInputTokens).assertEqual(1000);
      expect(b.remainingInputTokens).assertEqual(29720);
      expect(b.exceedsBudget).assertEqual(false);
    });

    it('Under_budget', 0, () => {
      const b: TokenBudget = createTokenBudget(100, 32768, 2048);
      expect(b.exceedsBudget).assertEqual(false);
      expect(b.remainingInputTokens > 0).assertEqual(true);
    });

    it('Exactly_equal_to_budget', 0, {
      // available = 100, estimated = 100 → remaining = 0, exceeds = false
      const b: TokenBudget = createTokenBudget(100, 200, 100);
      expect(b.availableInputTokens).assertEqual(100);
      expect(b.remainingInputTokens).assertEqual(0);
      expect(b.exceedsBudget).assertEqual(false);
    });

    it('Exceeds_budget', 0, () => {
      const b: TokenBudget = createTokenBudget(50000, 32768, 2048);
      expect(b.exceedsBudget).assertEqual(true);
    });

    it('ContextWindow_zero', 0, () => {
      const b: TokenBudget = createTokenBudget(100, 0, 0);
      expect(b.contextWindow).assertEqual(0);
      expect(b.availableInputTokens).assertEqual(0);
      expect(b.exceedsBudget).assertEqual(true);
    });

    it('ContextWindow_negative_treated_as_zero', 0, () => {
      const b: TokenBudget = createTokenBudget(100, -10, 0);
      expect(b.contextWindow).assertEqual(0);
      expect(b.availableInputTokens).assertEqual(0);
      expect(b.exceedsBudget).assertEqual(true);
    });

    it('ReservedOutput_negative_treated_as_zero', 0, () => {
      const b: TokenBudget = createTokenBudget(100, 32768, -100);
      expect(b.reservedOutputTokens).assertEqual(0);
      expect(b.availableInputTokens).assertEqual(32768);
      expect(b.exceedsBudget).assertEqual(false);
    });

    it('ReservedOutput_greater_than_contextWindow', 0, () => {
      const b: TokenBudget = createTokenBudget(100, 1000, 5000);
      expect(b.reservedOutputTokens).assertEqual(5000);
      expect(b.availableInputTokens).assertEqual(0);
      expect(b.exceedsBudget).assertEqual(true);
    });

    it('RemainingInputTokens_can_be_negative', 0, () => {
      const b: TokenBudget = createTokenBudget(99999, 32768, 2048);
      expect(b.remainingInputTokens < 0).assertEqual(true);
      expect(b.exceedsBudget).assertEqual(true);
    });

    it('ExceedsBudget_flag_correctness', 0, () => {
      const under: TokenBudget = createTokenBudget(100, 1000, 100);
      const over: TokenBudget = createTokenBudget(1000, 1000, 100);
      expect(under.exceedsBudget).assertEqual(false);
      expect(over.exceedsBudget).assertEqual(true);
    });

    it('Default_constants', 0, () => {
      expect(DEFAULT_CONTEXT_WINDOW).assertEqual(32768);
      expect(DEFAULT_RESERVED_OUTPUT_TOKENS).assertEqual(2048);
    });
  });
}
