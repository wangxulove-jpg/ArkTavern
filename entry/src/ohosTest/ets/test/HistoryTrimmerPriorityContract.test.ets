import { describe, it, expect } from '@ohos/hypium';
import { HistoryTrimmer } from '../../../main/ets/services/HistoryTrimmer';
import { TokenCounter } from '../../../main/ets/services/TokenCounter';
import { ChatMessage } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../../main/ets/models/ChatMessageSource';

function makeMsg(
  id: string,
  role: ChatRole,
  content: string,
  source: ChatMessageSource | undefined
): ChatMessage {
  return {
    id: id,
    role: role,
    content: content,
    createdAt: 0,
    source: source
  };
}

export default function historyTrimmerPriorityContractTest(): void {
  describe('HistoryTrimmer Priority 契约', () => {
    const counter: TokenCounter = new TokenCounter();
    const trimmer: HistoryTrimmer = new HistoryTrimmer(counter);

    it('TRIM-01 CrossSessionContext 先于 Conversation 被裁剪', 0, () => {
      const cs1: ChatMessage = makeMsg('cs1', ChatRole.System, 'Cross-session summary 1', ChatMessageSource.CrossSessionContext);
      const cs2: ChatMessage = makeMsg('cs2', ChatRole.System, 'Cross-session summary 2', ChatMessageSource.CrossSessionContext);
      const u1: ChatMessage = makeMsg('u1', ChatRole.User, 'Hello', ChatMessageSource.Conversation);
      const a1: ChatMessage = makeMsg('a1', ChatRole.Assistant, 'Hi there', ChatMessageSource.Conversation);
      const u2: ChatMessage = makeMsg('u2', ChatRole.User, 'How are you', ChatMessageSource.Conversation);
      const a2: ChatMessage = makeMsg('a2', ChatRole.Assistant, 'Fine thanks', ChatMessageSource.Conversation);
      const messages: ChatMessage[] = [cs1, cs2, u1, a1, u2, a2];

      const fullTokens: number = counter.estimateMessages(messages);
      const budget: number = counter.estimateMessages([u1, a1, u2, a2]);

      const result = trimmer.trim(messages, { availableInputTokens: budget });

      expect(result.removedMessageIds.indexOf('cs1') >= 0
        || result.removedMessageIds.indexOf('cs2') >= 0).assertTrue();

      expect(result.removedMessageIds.indexOf('u2')).assertEqual(-1);
      expect(result.removedMessageIds.indexOf('a2')).assertEqual(-1);
    });

    it('TRIM-02 最近 Conversation 不在 CrossSession 之前被裁剪', 0, () => {
      const cs1: ChatMessage = makeMsg('cs1', ChatRole.System, 'Summary text here', ChatMessageSource.CrossSessionContext);
      const u1: ChatMessage = makeMsg('u1', ChatRole.User, 'Hello', ChatMessageSource.Conversation);
      const a1: ChatMessage = makeMsg('a1', ChatRole.Assistant, 'Reply', ChatMessageSource.Conversation);
      const messages: ChatMessage[] = [cs1, u1, a1];

      const fullTokens: number = counter.estimateMessages(messages);
      const budget: number = counter.estimateMessages([u1, a1]);

      const result = trimmer.trim(messages, { availableInputTokens: budget });

      expect(result.removedMessageIds.length).assertEqual(1);
      expect(result.removedMessageIds[0]).assertEqual('cs1');
    });

    it('TRIM-03 CrossSession 耗尽后才裁剪 oldest Conversation', 0, () => {
      const cs1: ChatMessage = makeMsg('cs1', ChatRole.System, 'Summary 1', ChatMessageSource.CrossSessionContext);
      const u1: ChatMessage = makeMsg('u1', ChatRole.User, 'First user message', ChatMessageSource.Conversation);
      const a1: ChatMessage = makeMsg('a1', ChatRole.Assistant, 'First reply', ChatMessageSource.Conversation);
      const u2: ChatMessage = makeMsg('u2', ChatRole.User, 'Second user message', ChatMessageSource.Conversation);
      const a2: ChatMessage = makeMsg('a2', ChatRole.Assistant, 'Second reply', ChatMessageSource.Conversation);
      const messages: ChatMessage[] = [cs1, u1, a1, u2, a2];

      const onlyLast: ChatMessage[] = [a2];
      const budget: number = counter.estimateMessages(onlyLast);

      const result = trimmer.trim(messages, { availableInputTokens: budget });

      const cs1Idx: number = result.removedMessageIds.indexOf('cs1');
      const u1Idx: number = result.removedMessageIds.indexOf('u1');
      expect(cs1Idx >= 0).assertTrue();
      expect(u1Idx >= 0).assertTrue();
      expect(cs1Idx < u1Idx).assertTrue();
    });

    it('TRIM-04 Protected sources 不被裁剪', 0, () => {
      const sys: ChatMessage = makeMsg('sys', ChatRole.System, 'System prompt', undefined);
      const mem: ChatMessage = makeMsg('mem', ChatRole.System, 'Core memory', ChatMessageSource.MemoryCore);
      const u1: ChatMessage = makeMsg('u1', ChatRole.User, 'Hello', ChatMessageSource.Conversation);
      const a1: ChatMessage = makeMsg('a1', ChatRole.Assistant, 'Reply', ChatMessageSource.Conversation);
      const messages: ChatMessage[] = [sys, mem, u1, a1];

      const budget: number = 1;

      const result = trimmer.trim(messages, { availableInputTokens: budget });

      expect(result.removedMessageIds.indexOf('sys')).assertEqual(-1);
      expect(result.removedMessageIds.indexOf('mem')).assertEqual(-1);
    });

    it('TRIM-05 最后一条消息受保护', 0, () => {
      const u1: ChatMessage = makeMsg('u1', ChatRole.User, 'Hello', ChatMessageSource.Conversation);
      const a1: ChatMessage = makeMsg('a1', ChatRole.Assistant, 'Reply', ChatMessageSource.Conversation);
      const u2: ChatMessage = makeMsg('u2', ChatRole.User, 'Latest', ChatMessageSource.Conversation);
      const messages: ChatMessage[] = [u1, a1, u2];

      const budget: number = 1;

      const result = trimmer.trim(messages, { availableInputTokens: budget });

      expect(result.removedMessageIds.indexOf('u2')).assertEqual(-1);
    });
  });
}
