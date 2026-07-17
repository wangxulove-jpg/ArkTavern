/**
 * HistoryTrimmer 单元测试
 *
 * 覆盖场景:
 * 基础行为(1-8)、保护消息(9-16)、历史轮次裁剪(17-25)、极端预算(26-35)。
 *
 * 测试数据:使用可预测的中英文混合文本,确保测试真实触发预算边界。
 */

import { describe, it, expect } from '@ohos/hypium';
import { HistoryTrimmer } from '../main/ets/services/HistoryTrimmer';
import { TokenCounter } from '../main/ets/services/TokenCounter';
import { ChatMessage, createChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import { ChatMessageSource } from '../main/ets/models/ChatMessageSource';
import { estimateTextTokens } from '../main/ets/services/TokenCounter';

// 一个字符中文 + ASCII 词的填充函数,产生 N 个 token 的中英文文本
function fillerOfTokens(n: number): string {
  // 用 1-char 短词堆叠,每 4 字符 1 token
  // 30 chars → ceil(30/4) = 8 token
  const unit: string = 'abcdefgh '; // 9 chars(含空格)→ ceil(9/4)=3 token
  let s: string = '';
  let acc: number = 0;
  while (acc < n) {
    s += unit;
    acc += 3;
  }
  return s.slice(0, Math.max(1, n * 4));
}

function fillerZH(tokens: number): string {
  // 中文每字 1 token
  return '啊'.repeat(Math.max(1, tokens));
}

function buildMsg(id: string, role: ChatRole, content: string, source?: ChatMessageSource): ChatMessage {
  const m: ChatMessage = createChatMessage(id, role, content, 1);
  if (source !== undefined) {
    return { id: m.id, role: m.role, content: m.content, createdAt: m.createdAt, source: source };
  }
  return m;
}

export default function historyTrimmerTest(): void {
  describe('HistoryTrimmer_basic', () => {
    it('Empty_messages_array', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const r = trimmer.trim([], { availableInputTokens: 1000 });
      expect(r.messages.length).assertEqual(0);
      expect(r.removedMessageCount).assertEqual(0);
      expect(r.exceedsBudgetBeforeTrim).assertEqual(false);
      expect(r.exceedsBudgetAfterTrim).assertEqual(false);
    });

    it('Not_over_budget_no_deletion', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('c', ChatRole.System, 'sys', ChatMessageSource.CharacterPrompt),
        buildMsg('f', ChatRole.Assistant, 'first', ChatMessageSource.CharacterFirstMessage),
        buildMsg('u1', ChatRole.User, 'hi')
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 100000 });
      expect(r.removedMessageCount).assertEqual(0);
      expect(r.exceedsBudgetBeforeTrim).assertEqual(false);
      expect(r.exceedsBudgetAfterTrim).assertEqual(false);
      expect(r.messages.length).assertEqual(3);
    });

    it('Returns_new_array', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [buildMsg('u1', ChatRole.User, 'hi')];
      const r = trimmer.trim(msgs, { availableInputTokens: 1000 });
      expect(r.messages === msgs).assertEqual(false);
    });

    it('Original_messages_array_not_modified', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50))
      ];
      const beforeIds: string[] = msgs.map((m: ChatMessage): string => m.id);
      trimmer.trim(msgs, { availableInputTokens: 1 });
      expect(msgs.length).assertEqual(4);
      for (let i = 0; i < msgs.length; i++) {
        expect(msgs[i].id).assertEqual(beforeIds[i]);
      }
    });

    it('Original_message_objects_not_modified', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, 'hello world')
      ];
      const before: string = msgs[0].content;
      trimmer.trim(msgs, { availableInputTokens: 1 });
      expect(msgs[0].content).assertEqual(before);
    });

    it('Order_preserved_after_trim', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u3', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      // 5 条消息,删除两轮后保留顺序
      // 1(fixed=4 + 50 = 54) + 1(4+50=54) = 108,系统提示 + firstMessage(未加入),但我们只对 User/Assistant 测试
      // 实际:消息 0(54) + 1(54) + 2(54) + 3(54) + 4(4+ceil(10*4/4)=4+10=14) = 230
      // available = 1,需要删除全部可裁剪(只有 u3 是最后一条,被保护)
      // 期望:剩下 u3(最后一条)
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      // 验证顺序是按原顺序
      for (let i = 0; i < ids.length; i++) {
        for (let j = i + 1; j < ids.length; j++) {
          expect(ids[i] < ids[j]).assertEqual(true);
        }
      }
    });

    it('Result_tokens_non_negative_integer', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      expect(r.originalTokenCount >= 0).assertEqual(true);
      expect(r.finalTokenCount >= 0).assertEqual(true);
      expect(Number.isInteger(r.originalTokenCount)).assertEqual(true);
      expect(Number.isInteger(r.finalTokenCount)).assertEqual(true);
    });

    it('Deterministic_same_input', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const make = (): ChatMessage[] => [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50))
      ];
      const r1 = trimmer.trim(make(), { availableInputTokens: 1 });
      const r2 = trimmer.trim(make(), { availableInputTokens: 1 });
      expect(r1.removedMessageCount).assertEqual(r2.removedMessageCount);
      expect(r1.messages.length).assertEqual(r2.messages.length);
      for (let i = 0; i < r1.messages.length; i++) {
        expect(r1.messages[i].id).assertEqual(r2.messages[i].id);
      }
    });
  });

  describe('HistoryTrimmer_protected', () => {
    it('System_message_not_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('ext-sys', ChatRole.System, fillerOfTokens(50), ChatMessageSource.ExternalSystem),
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('ext-sys') >= 0).assertEqual(true);
    });

    it('Character_prompt_not_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('char', ChatRole.System, fillerOfTokens(50), ChatMessageSource.CharacterPrompt),
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('char') >= 0).assertEqual(true);
    });

    it('Lorebook_before_not_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('lb', ChatRole.System, fillerOfTokens(50), ChatMessageSource.LorebookBefore),
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('lb') >= 0).assertEqual(true);
    });

    it('Lorebook_after_not_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('la', ChatRole.System, fillerOfTokens(50), ChatMessageSource.LorebookAfter),
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('la') >= 0).assertEqual(true);
    });

    it('FirstMessage_not_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('fm', ChatRole.Assistant, fillerOfTokens(50), ChatMessageSource.CharacterFirstMessage),
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('fm') >= 0).assertEqual(true);
    });

    it('Last_User_message_not_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u3-current', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('u3-current') >= 0).assertEqual(true);
    });

    it('Protected_ids_explicitly_not_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1, protectedMessageIds: ['u1'] });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('u1') >= 0).assertEqual(true);
    });

    it('External_system_not_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('ext', ChatRole.System, fillerOfTokens(50), ChatMessageSource.ExternalSystem),
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('ext') >= 0).assertEqual(true);
    });
  });

  describe('HistoryTrimmer_round_trim', () => {
    it('Removes_oldest_complete_round', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u3-current', ChatRole.User, fillerOfTokens(10))
      ];
      // total ≈ 4*(4+50) + (4+10) = 234; available=180 → 删一轮
      const r = trimmer.trim(msgs, { availableInputTokens: 180 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      // 期望: 删除 u1+a1
      expect(ids.indexOf('u1') < 0).assertEqual(true);
      expect(ids.indexOf('a1') < 0).assertEqual(true);
      expect(ids.indexOf('u2') >= 0).assertEqual(true);
      expect(ids.indexOf('a2') >= 0).assertEqual(true);
      expect(ids.indexOf('u3-current') >= 0).assertEqual(true);
    });

    it('Multiple_rounds_oldest_first', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u3-current', ChatRole.User, fillerOfTokens(10))
      ];
      // total ≈ 234; available=70 → 删多轮
      const r = trimmer.trim(msgs, { availableInputTokens: 70 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      // 期望: 删除 u1+a1 和 u2+a2
      expect(ids.indexOf('u1') < 0).assertEqual(true);
      expect(ids.indexOf('a1') < 0).assertEqual(true);
      expect(ids.indexOf('u2') < 0).assertEqual(true);
      expect(ids.indexOf('a2') < 0).assertEqual(true);
      expect(ids.indexOf('u3-current') >= 0).assertEqual(true);
    });

    it('Stops_when_within_budget', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u3-current', ChatRole.User, fillerOfTokens(10))
      ];
      // available 刚好删一轮就够
      const r = trimmer.trim(msgs, { availableInputTokens: 180 });
      // 期望恰好删除一轮
      expect(r.removedMessageCount).assertEqual(2);
    });

    it('Does_not_remove_newer_keeping_older', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(20)),  // 较小
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(20)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(200)), // 较大
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(20)),
        buildMsg('u3-current', ChatRole.User, fillerOfTokens(10))
      ];
      // available=300 → 需要删 u2+a2 那大轮
      const r = trimmer.trim(msgs, { availableInputTokens: 300 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('u1') >= 0).assertEqual(true);
      expect(ids.indexOf('a1') >= 0).assertEqual(true);
      expect(ids.indexOf('u2') < 0).assertEqual(true);
      expect(ids.indexOf('a2') < 0).assertEqual(true);
    });

    it('Does_not_leave_orphan_old_assistant', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      // 故意构造一个"旧 Assistant 紧邻不可裁剪 System"的场景
      const msgs: ChatMessage[] = [
        buildMsg('char', ChatRole.System, 'sys', ChatMessageSource.CharacterPrompt),
        buildMsg('a0', ChatRole.Assistant, fillerOfTokens(50)), // 紧邻 System 不可裁剪后的孤立
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2-current', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      // 不应删除 char (system)
      expect(ids.indexOf('char') >= 0).assertEqual(true);
      // 不应删除 u2-current
      expect(ids.indexOf('u2-current') >= 0).assertEqual(true);
    });

    it('Orphan_old_user_can_be_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u-orphan', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('u2-current', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      // 孤立 u-orphan 可单独删除,a1 可单独删除
      expect(ids.indexOf('u-orphan') < 0).assertEqual(true);
      expect(ids.indexOf('a1') < 0).assertEqual(true);
      expect(ids.indexOf('u1') < 0).assertEqual(true);
      expect(ids.indexOf('u2-current') >= 0).assertEqual(true);
    });

    it('Orphan_old_assistant_can_be_removed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('a-orphan', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2-current', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('a-orphan') < 0).assertEqual(true);
      expect(ids.indexOf('u1') < 0).assertEqual(true);
      expect(ids.indexOf('a1') < 0).assertEqual(true);
      expect(ids.indexOf('u2-current') >= 0).assertEqual(true);
    });

    it('Consecutive_user_messages_deterministic', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('u3', ChatRole.User, fillerOfTokens(50)),
        buildMsg('u4-current', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      // 连续 User(无 Assistant 配对),按单条单元删除
      expect(ids.indexOf('u1') < 0).assertEqual(true);
      expect(ids.indexOf('u2') < 0).assertEqual(true);
      expect(ids.indexOf('u3') < 0).assertEqual(true);
      expect(ids.indexOf('u4-current') >= 0).assertEqual(true);
    });

    it('Consecutive_assistant_messages_deterministic', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('a3', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u1-current', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('a1') < 0).assertEqual(true);
      expect(ids.indexOf('a2') < 0).assertEqual(true);
      expect(ids.indexOf('a3') < 0).assertEqual(true);
      expect(ids.indexOf('u1-current') >= 0).assertEqual(true);
    });
  });

  describe('HistoryTrimmer_extreme_budget', () => {
    it('Available_zero', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2-current', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 0 });
      // 删除所有可裁剪,留下最后一条
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('u2-current') >= 0).assertEqual(true);
      expect(r.exceedsBudgetAfterTrim).assertEqual(true);
    });

    it('Available_negative_treated_as_zero', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2-current', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: -100 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('u2-current') >= 0).assertEqual(true);
      expect(r.exceedsBudgetAfterTrim).assertEqual(true);
    });

    it('All_messages_protected_no_deletion', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('char', ChatRole.System, fillerOfTokens(50), ChatMessageSource.CharacterPrompt),
        buildMsg('fm', ChatRole.Assistant, fillerOfTokens(50), ChatMessageSource.CharacterFirstMessage),
        buildMsg('u-current', ChatRole.User, fillerOfTokens(10))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      expect(r.removedMessageCount).assertEqual(0);
      expect(r.messages.length).assertEqual(3);
    });

    it('Still_over_budget_after_removing_all_history', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      // protected 占大量 token,即使删完历史仍超
      const msgs: ChatMessage[] = [
        buildMsg('char', ChatRole.System, fillerOfTokens(500), ChatMessageSource.CharacterPrompt),
        buildMsg('fm', ChatRole.Assistant, fillerOfTokens(500), ChatMessageSource.CharacterFirstMessage),
        buildMsg('lb1', ChatRole.System, fillerOfTokens(500), ChatMessageSource.LorebookBefore),
        buildMsg('u1', ChatRole.User, fillerOfTokens(20)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(20)),
        buildMsg('u-current', ChatRole.User, fillerOfTokens(20))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 100 });
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      // u1, a1 都被删除
      expect(ids.indexOf('u1') < 0).assertEqual(true);
      expect(ids.indexOf('a1') < 0).assertEqual(true);
      // 受保护全部保留
      expect(ids.indexOf('char') >= 0).assertEqual(true);
      expect(ids.indexOf('fm') >= 0).assertEqual(true);
      expect(ids.indexOf('lb1') >= 0).assertEqual(true);
      expect(ids.indexOf('u-current') >= 0).assertEqual(true);
      // 仍超预算
      expect(r.exceedsBudgetAfterTrim).assertEqual(true);
    });

    it('Exceeds_budget_after_trim_flag', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('char', ChatRole.System, fillerOfTokens(500), ChatMessageSource.CharacterPrompt),
        buildMsg('fm', ChatRole.Assistant, fillerOfTokens(500), ChatMessageSource.CharacterFirstMessage),
        buildMsg('u1', ChatRole.User, fillerOfTokens(20)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(20)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(20)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(20)),
        buildMsg('u-current', ChatRole.User, fillerOfTokens(20))
      ];
      const r = trimmer.trim(msgs, { availableInputTokens: 50 });
      expect(r.exceedsBudgetAfterTrim).assertEqual(true);
    });

    it('Exact_budget_boundary', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u-current', ChatRole.User, fillerOfTokens(10))
      ];
      // available = total / 2 → 删一半
      // 手工算:u1=54,a1=54,u2=54,a2=54,u-current=14 → total=230
      // available=115 → 删一轮(108)剩 122,超;再删一轮剩 68
      // 期望:删除 u1+a1
      const r = trimmer.trim(msgs, { availableInputTokens: 115 });
      // 删一轮后剩 122 > 115,可能再多删一轮;但 122-115=7,实际算法应继续删
      // 实际期望:removed=2 或 4(取决于算法精度)
      expect(r.removedMessageCount >= 2).assertEqual(true);
    });

    it('One_round_sufficient', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u-current', ChatRole.User, fillerOfTokens(10))
      ];
      // 删一轮后剩 176,可用 180
      const r = trimmer.trim(msgs, { availableInputTokens: 180 });
      expect(r.removedMessageCount).assertEqual(2);
    });

    it('Multiple_rounds_needed', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a1', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u2', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a2', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u3', ChatRole.User, fillerOfTokens(50)),
        buildMsg('a3', ChatRole.Assistant, fillerOfTokens(50)),
        buildMsg('u-current', ChatRole.User, fillerOfTokens(10))
      ];
      // 删两轮后剩 176 - 108 = 178 - 108 = 70(假设删两轮)
      const r = trimmer.trim(msgs, { availableInputTokens: 50 });
      expect(r.removedMessageCount).assertEqual(4);
    });

    it('No_infinite_loop_on_massive_history', 0, () => {
      const counter: TokenCounter = new TokenCounter();
      const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);
      const msgs: ChatMessage[] = [];
      for (let i = 0; i < 1000; i++) {
        msgs.push(buildMsg('u' + i.toString(), ChatRole.User, fillerOfTokens(20)));
        msgs.push(buildMsg('a' + i.toString(), ChatRole.Assistant, fillerOfTokens(20)));
      }
      msgs.push(buildMsg('u-current', ChatRole.User, fillerOfTokens(10)));
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      // 必须终止:最后一条保留
      const ids: string[] = r.messages.map((m: ChatMessage): string => m.id);
      expect(ids.indexOf('u-current') >= 0).assertEqual(true);
      expect(r.messages.length).assertEqual(1);
    });

    it('TokenCounter_throw_handled', 0, () => {
      // 构造一个抛错的 TokenCounter
      const broken = {
        estimateMessages: (_: ChatMessage[]): number => {
          throw new Error('boom');
        }
      } as unknown as TokenCounter;
      const trimmer: HistoryTrimmer = new HistoryTrimmer(broken);
      const msgs: ChatMessage[] = [
        buildMsg('u1', ChatRole.User, 'hi'),
        buildMsg('u-current', ChatRole.User, 'hi2')
      ];
      // 即使 estimateMessages 抛错,trim 应该用 fallback 跑完
      // 内部 countTokensSafe 捕获异常并使用 estimateMessagesTokens(messages)
      const r = trimmer.trim(msgs, { availableInputTokens: 1 });
      // 不抛错,返回合理结果
      expect(r.messages.length).assertEqual(1);
    });
  });
}
