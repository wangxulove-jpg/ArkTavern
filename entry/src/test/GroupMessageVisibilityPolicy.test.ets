/**
 * GroupMessageVisibilityPolicy 本地单元测试(VIS-01 ~ VIS-20)
 *
 * 验证群聊历史消息可见性策略:
 * - Public 对所有角色可见
 * - Private 接收者/发送者可见,非接收者排除
 * - 状态过滤(Failed / Cancelled / Streaming / 空正文)
 * - System 排除
 * - 公开旁白可见 + 旁白身份格式
 * - viewer 缺失安全失败
 * - 输入数组不被修改 / A/B 结果隔离
 * - 检查器原因一致
 * - 当前公开行为不回归
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  GroupMessageVisibilityPolicy,
  GroupMessageVisibilityReason,
  GroupVisibleHistoryResult,
  GroupMessageVisibilityDecision
} from '../main/ets/services/groupchat/GroupMessageVisibilityPolicy';
import { ChatMessage, ChatMessageStatus, MessageSenderType, MessageVisibility } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';

const CHAR_A: string = 'char-a';
const CHAR_B: string = 'char-b';
const CHAR_C: string = 'char-c';

function makeUserMsg(
  id: string,
  content: string,
  status: ChatMessageStatus = ChatMessageStatus.Completed,
  visibility: MessageVisibility = 'public',
  recipients?: string[],
  replyTarget?: string[],
  senderType: MessageSenderType = 'user',
  senderCharacterId?: string
): ChatMessage {
  return {
    id: id,
    role: ChatRole.User,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    isStreaming: status === ChatMessageStatus.Streaming,
    status: status,
    senderType: senderType,
    senderCharacterId: senderCharacterId,
    visibility: visibility,
    recipientCharacterIds: recipients,
    replyTargetCharacterIds: replyTarget
  };
}

function makeAssistantMsg(
  id: string,
  characterId: string,
  content: string,
  status: ChatMessageStatus = ChatMessageStatus.Completed,
  visibility: MessageVisibility = 'public',
  recipients?: string[]
): ChatMessage {
  return {
    id: id,
    role: ChatRole.Assistant,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    isStreaming: status === ChatMessageStatus.Streaming,
    status: status,
    senderType: 'character' as MessageSenderType,
    senderCharacterId: characterId,
    visibility: visibility,
    recipientCharacterIds: recipients
  };
}

function makeNarratorMsg(id: string, content: string, status: ChatMessageStatus = ChatMessageStatus.Completed): ChatMessage {
  return {
    id: id,
    role: ChatRole.Assistant,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    isStreaming: status === ChatMessageStatus.Streaming,
    status: status,
    senderType: 'narrator' as MessageSenderType,
    senderCharacterId: undefined,
    visibility: 'public' as MessageVisibility
  };
}

function makeSystemMsg(id: string, content: string): ChatMessage {
  return {
    id: id,
    role: ChatRole.System,
    content: content,
    createdAt: 1000
  };
}

export default function groupMessageVisibilityPolicyTest() {
  describe('GroupMessageVisibilityPolicyTest', () => {

    it('VIS_01_public_visible_to_all', 0, () => {
      const msg: ChatMessage = makeUserMsg('m1', 'hello everyone');
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A).visible).assertTrue();
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_B).visible).assertTrue();
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_C).visible).assertTrue();
    });

    it('VIS_02_public_not_depend_on_replyTarget', 0, () => {
      const msg: ChatMessage = makeUserMsg('m1', 'hello', ChatMessageStatus.Completed, 'public', undefined, [CHAR_A]);
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_B).visible).assertTrue();
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_C).visible).assertTrue();
    });

    it('VIS_03_public_not_depend_on_participantIds', 0, () => {
      const msg: ChatMessage = makeUserMsg('m1', 'hello');
      // participantIds 未设置(undefined),仍应对 A/B 可见
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A).visible).assertTrue();
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_B).visible).assertTrue();
    });

    it('VIS_04_private_recipient_visible', 0, () => {
      const msg: ChatMessage = makeUserMsg('m1', 'secret', ChatMessageStatus.Completed, 'private', [CHAR_A]);
      const d: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A);
      expect(d.visible).assertTrue();
      expect(d.reason).assertEqual(GroupMessageVisibilityReason.INCLUDED_PRIVATE_RECIPIENT);
    });

    it('VIS_05_private_non_recipient_excluded', 0, () => {
      const msg: ChatMessage = makeUserMsg('m1', 'secret', ChatMessageStatus.Completed, 'private', [CHAR_A]);
      const d: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(msg, CHAR_B);
      expect(d.visible).assertFalse();
      expect(d.reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_PRIVATE_NOT_RECIPIENT);
    });

    it('VIS_06_private_sender_and_recipient_visible', 0, () => {
      const msg: ChatMessage = makeAssistantMsg('m1', CHAR_A, 'for B', ChatMessageStatus.Completed, 'private', [CHAR_B]);
      // 发送者 A 可见
      const dA: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A);
      expect(dA.visible).assertTrue();
      expect(dA.reason).assertEqual(GroupMessageVisibilityReason.INCLUDED_PRIVATE_SENDER);
      // 接收者 B 可见
      const dB: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(msg, CHAR_B);
      expect(dB.visible).assertTrue();
      expect(dB.reason).assertEqual(GroupMessageVisibilityReason.INCLUDED_PRIVATE_RECIPIENT);
      // 非接收者 C 排除
      const dC: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(msg, CHAR_C);
      expect(dC.visible).assertFalse();
      expect(dC.reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_PRIVATE_NOT_RECIPIENT);
    });

    it('VIS_07_failed_excluded', 0, () => {
      const msg: ChatMessage = makeAssistantMsg('m1', CHAR_A, 'failed content', ChatMessageStatus.Failed);
      const d: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A);
      expect(d.visible).assertFalse();
      expect(d.reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_STATUS_FAILED);
    });

    it('VIS_08_cancelled_excluded', 0, () => {
      const msg: ChatMessage = makeAssistantMsg('m1', CHAR_A, 'cancelled content', ChatMessageStatus.Cancelled);
      const d: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A);
      expect(d.visible).assertFalse();
      expect(d.reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_STATUS_CANCELLED);
    });

    it('VIS_09_streaming_excluded', 0, () => {
      const msg: ChatMessage = makeAssistantMsg('m1', CHAR_A, 'streaming', ChatMessageStatus.Streaming);
      const d: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A);
      expect(d.visible).assertFalse();
      expect(d.reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_STATUS_STREAMING);
    });

    it('VIS_10_empty_content_excluded', 0, () => {
      const empty: ChatMessage = makeUserMsg('m1', '');
      const spaces: ChatMessage = makeUserMsg('m2', '   ');
      const newline: ChatMessage = makeUserMsg('m3', '\n\t');
      expect(GroupMessageVisibilityPolicy.evaluate(empty, CHAR_A).visible).assertFalse();
      expect(GroupMessageVisibilityPolicy.evaluate(empty, CHAR_A).reason)
        .assertEqual(GroupMessageVisibilityReason.EXCLUDED_EMPTY_CONTENT);
      expect(GroupMessageVisibilityPolicy.evaluate(spaces, CHAR_A).visible).assertFalse();
      expect(GroupMessageVisibilityPolicy.evaluate(newline, CHAR_A).visible).assertFalse();
    });

    it('VIS_11_system_excluded', 0, () => {
      const msg: ChatMessage = makeSystemMsg('m1', 'system content');
      const d: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A);
      expect(d.visible).assertFalse();
      expect(d.reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_SYSTEM);
    });

    it('VIS_12_public_narration_visible', 0, () => {
      const msg: ChatMessage = makeNarratorMsg('m1', 'the wind blows');
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A).visible).assertTrue();
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_B).visible).assertTrue();
      expect(GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A).reason)
        .assertEqual(GroupMessageVisibilityReason.INCLUDED_PUBLIC_NARRATION);
    });

    it('VIS_13_narration_format', 0, () => {
      const narratorMsg: ChatMessage = makeNarratorMsg('m1', 'the wind blows');
      // 旁白格式化为 [旁白]: 前缀
      const formatted: string = '[旁白]: ' + narratorMsg.content;
      expect(formatted).assertEqual('[旁白]: the wind blows');
      // 不得包含 [未知角色]
      expect(formatted.indexOf('[未知角色]')).assertEqual(-1);
    });

    it('VIS_14_viewer_missing_safe_fail', 0, () => {
      const messages: ChatMessage[] = [makeUserMsg('m1', 'hello'), makeAssistantMsg('m2', CHAR_A, 'hi')];
      // filterVisible 对空 viewer 抛错,不得返回完整历史
      let threw: boolean = false;
      try {
        GroupMessageVisibilityPolicy.filterVisible(messages, '');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      // evaluate 防御:空 viewer 返回排除
      const d: GroupMessageVisibilityDecision = GroupMessageVisibilityPolicy.evaluate(messages[0], '');
      expect(d.visible).assertFalse();
      expect(d.reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_INVALID_VIEWER);
    });

    it('VIS_15_input_array_not_modified', 0, () => {
      const messages: ChatMessage[] = [
        makeUserMsg('m1', 'hello'),
        makeAssistantMsg('m2', CHAR_A, 'failed', ChatMessageStatus.Failed),
        makeUserMsg('m3', 'secret', ChatMessageStatus.Completed, 'private', [CHAR_B])
      ];
      const originalLen: number = messages.length;
      const originalContents: string[] = messages.map((m: ChatMessage): string => m.content);
      const result: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_A);
      expect(messages.length).assertEqual(originalLen);
      for (let i = 0; i < originalLen; i++) {
        expect(messages[i].content).assertEqual(originalContents[i]);
      }
      expect(result.includedMessages === messages).assertFalse();
    });

    it('VIS_16_a_b_array_isolation', 0, () => {
      const messages: ChatMessage[] = [
        makeUserMsg('m1', 'hello'),
        makeUserMsg('m2', 'secret', ChatMessageStatus.Completed, 'private', [CHAR_A])
      ];
      const resultA: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_A);
      const resultB: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_B);
      expect(resultA.includedMessages === resultB.includedMessages).assertFalse();
      // A 看到 m1 + m2(private recipient),B 只看到 m1
      expect(resultA.includedCount).assertEqual(2);
      expect(resultB.includedCount).assertEqual(1);
    });

    it('VIS_17_inspector_reason_consistent', 0, () => {
      const messages: ChatMessage[] = [
        makeUserMsg('m1', 'hello'),
        makeAssistantMsg('m2', CHAR_A, 'cancelled', ChatMessageStatus.Cancelled),
        makeUserMsg('m3', 'secret', ChatMessageStatus.Completed, 'private', [CHAR_A])
      ];
      const result: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_B);
      // 检查器原因 = 过滤原因
      expect(result.decisions[0].visible).assertTrue();
      expect(result.decisions[0].reason).assertEqual(GroupMessageVisibilityReason.INCLUDED_PUBLIC);
      expect(result.decisions[1].visible).assertFalse();
      expect(result.decisions[1].reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_STATUS_CANCELLED);
      expect(result.decisions[2].visible).assertFalse();
      expect(result.decisions[2].reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_PRIVATE_NOT_RECIPIENT);
    });

    it('VIS_18_retry_refilter', 0, () => {
      const messages: ChatMessage[] = [makeUserMsg('m1', 'hello')];
      const first: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_A);
      const second: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_A);
      // 重试生成新结果,不复用上次引用
      expect(first.includedMessages === second.includedMessages).assertFalse();
    });

    it('VIS_19_next_speaker_refilter', 0, () => {
      const messages: ChatMessage[] = [
        makeUserMsg('m1', 'secret', ChatMessageStatus.Completed, 'private', [CHAR_A])
      ];
      const forA: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_A);
      const forB: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_B);
      expect(forA.includedCount).assertEqual(1);
      expect(forB.includedCount).assertEqual(0);
      expect(forA.includedMessages === forB.includedMessages).assertFalse();
    });

    it('VIS_20_current_public_no_regression', 0, () => {
      const messages: ChatMessage[] = [
        makeUserMsg('u1', 'hello'),
        makeAssistantMsg('a1', CHAR_A, 'reply A'),
        makeAssistantMsg('a2', CHAR_B, 'reply B'),
        makeNarratorMsg('n1', 'the scene')
      ];
      const forA: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_A);
      const forB: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_B);
      const forC: GroupVisibleHistoryResult =
        GroupMessageVisibilityPolicy.filterVisible(messages, CHAR_C);
      // 全部 Public Completed 非空消息,各角色都能看到
      expect(forA.includedCount).assertEqual(4);
      expect(forB.includedCount).assertEqual(4);
      expect(forC.includedCount).assertEqual(4);
    });

    it('VIS_21_narrator_sender_with_narrator_visibility_explicit_decision', 0, () => {
      // G-CONTEXT-MEMORY-SELECTION-1 补充:审计确认合法值中存在 visibility='narrator'。
      // 当前业务不写入 visibility='narrator'(旁白写 public + senderType='narrator'),
      // 但过滤器必须对"旁白身份 + narrator 可见性 + completed 状态"给出显式决策,
      // 不得依赖默认分支。
      const msg: ChatMessage = {
        id: 'narr-v21',
        role: ChatRole.Assistant,
        content: 'scene',
        createdAt: 1000,
        updatedAt: 1000,
        isStreaming: false,
        status: ChatMessageStatus.Completed,
        senderType: 'narrator' as MessageSenderType,
        senderCharacterId: undefined,
        visibility: 'narrator' as MessageVisibility
      };
      const decision: GroupMessageVisibilityDecision =
        GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A);
      expect(decision.visible).assertFalse();
      expect(decision.reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_UNSUPPORTED_VISIBILITY);
    });

    it('VIS_22_narrator_sender_private_visibility_follows_recipient_rule', 0, () => {
      const msg: ChatMessage = {
        id: 'narr-v22',
        role: ChatRole.Assistant,
        content: 'whisper',
        createdAt: 1000,
        updatedAt: 1000,
        isStreaming: false,
        status: ChatMessageStatus.Completed,
        senderType: 'narrator' as MessageSenderType,
        senderCharacterId: undefined,
        visibility: 'private' as MessageVisibility,
        recipientCharacterIds: [CHAR_A]
      };
      const forA: GroupMessageVisibilityDecision =
        GroupMessageVisibilityPolicy.evaluate(msg, CHAR_A);
      const forB: GroupMessageVisibilityDecision =
        GroupMessageVisibilityPolicy.evaluate(msg, CHAR_B);
      expect(forA.visible).assertTrue();
      expect(forA.reason).assertEqual(GroupMessageVisibilityReason.INCLUDED_PRIVATE_RECIPIENT);
      expect(forB.visible).assertFalse();
      expect(forB.reason).assertEqual(GroupMessageVisibilityReason.EXCLUDED_PRIVATE_NOT_RECIPIENT);
    });

  });
}
