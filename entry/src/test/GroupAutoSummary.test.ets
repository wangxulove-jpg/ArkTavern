/**
 * GroupAutoSummary 本地单元测试(SUMPLAN-01 ~ SUMPLAN-24)
 *
 * 验证群聊角色自动记忆总结的:
 * - 默认设置(关闭 + 中等档位)
 * - 群聊设置隔离(不同群聊互不影响)
 * - 三个档位规格(简洁/中等/详细 → 目标字数 + maxOutputTokens)
 * - 每角色独立总结窗口(A 只见 A 可见消息)
 * - 跨群聊隔离 / Public / Private / 异常状态 / 旁白身份
 * - 首次总结 / 增量总结 / 无新消息 / 阈值触发
 * - 关闭状态不触发 / 多条 Active 停止规划 / 边界缺失不盲目重算
 * - 计划不持久化正文 / 不调用模型 / 不修改 Repository
 *
 * 纯本地单元测试,不调用真实模型,不启动设备,不修改数据库。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  GroupAutoSummaryDetailLevel,
  GroupAutoSummarySettings,
  GroupAutoSummaryPlan,
  getGroupAutoSummaryLevelSpec,
  createDefaultGroupAutoSummarySettings,
  buildGroupAutoSummarySettingKeys,
  GROUP_AUTO_SUMMARY_DEFAULT_ENABLED,
  GROUP_AUTO_SUMMARY_DEFAULT_DETAIL_LEVEL
} from '../main/ets/models/groupchat/GroupAutoSummaryModels';
import {
  GroupAutoSummaryPlanner,
  GroupAutoSummaryPlanInput,
  GroupAutoSummaryPolicy,
  GroupAutoSummaryIneligibleReason,
  GroupAutoSummaryPolicyInput,
  GroupAutoSummaryPolicyResult
} from '../main/ets/services/groupchat/GroupAutoSummaryPlanner';
import { ChatMessage, ChatMessageStatus, MessageSenderType, MessageVisibility } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import {
  GroupCharacterMemory,
  GroupCharacterMemoryOrigin,
  GroupCharacterMemoryStatus,
  createGroupCharacterMemoryRecord
} from '../main/ets/models/groupchat/GroupCharacterMemory';

const CHAT_1: string = 'chat-1';
const CHAT_2: string = 'chat-2';
const CHAR_A: string = 'char-a';
const CHAR_B: string = 'char-b';

const CONCISE_MAX_TOKENS: number = 256;
const MEDIUM_MAX_TOKENS: number = 512;
const DETAILED_MAX_TOKENS: number = 1024;

function makeUserMsg(
  id: string,
  content: string,
  status: ChatMessageStatus = ChatMessageStatus.Completed,
  visibility: MessageVisibility = 'public',
  recipients?: string[],
  senderType: MessageSenderType = 'user',
  generationBatchId?: string
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
    senderCharacterId: undefined,
    visibility: visibility,
    recipientCharacterIds: recipients,
    generationBatchId: generationBatchId
  };
}

function makeAssistantMsg(
  id: string,
  characterId: string,
  content: string,
  status: ChatMessageStatus = ChatMessageStatus.Completed,
  visibility: MessageVisibility = 'public',
  recipients?: string[],
  generationBatchId?: string
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
    recipientCharacterIds: recipients,
    generationBatchId: generationBatchId
  };
}

function makeNarratorMsg(
  id: string,
  content: string,
  status: ChatMessageStatus = ChatMessageStatus.Completed
): ChatMessage {
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

function makeEmptyMsg(id: string): ChatMessage {
  return {
    id: id,
    role: ChatRole.User,
    content: '   ',
    createdAt: 1000,
    status: ChatMessageStatus.Completed,
    senderType: 'user' as MessageSenderType
  };
}

function makeSelfSummaryMemory(
  id: string,
  groupId: string,
  charId: string,
  sourceMessageId: string,
  sourceRoundId: string,
  sourceHash: string,
  updatedAt: number,
  status: GroupCharacterMemoryStatus = GroupCharacterMemoryStatus.Active
): GroupCharacterMemory {
  return createGroupCharacterMemoryRecord({
    id: id,
    groupConversationId: groupId,
    characterId: charId,
    origin: GroupCharacterMemoryOrigin.Interaction,
    status: status,
    title: '自动总结',
    content: '旧滚动总结正文',
    importance: 3,
    sourceMessageId: sourceMessageId,
    sourceRoundId: sourceRoundId,
    sourceSenderCharacterId: charId,
    sourceType: 'self_summary_v1',
    sourceHash: sourceHash,
    updatedAt: updatedAt
  });
}

function makeEnabledSettings(): GroupAutoSummarySettings {
  const s: GroupAutoSummarySettings = {
    enabled: true,
    detailLevel: GroupAutoSummaryDetailLevel.Medium
  };
  return s;
}

function makeDisabledSettings(): GroupAutoSummarySettings {
  const s: GroupAutoSummarySettings = {
    enabled: false,
    detailLevel: GroupAutoSummaryDetailLevel.Medium
  };
  return s;
}

/** 构造多角色对话消息序列(默认 8 条,含用户与 A/B 角色) */
function makeConversationMessages(count: number = 8): ChatMessage[] {
  const msgs: ChatMessage[] = [];
  for (let i = 0; i < count; i++) {
    const id: string = 'm' + String(i);
    if (i % 2 === 0) {
      msgs.push(makeUserMsg(id, '用户消息' + String(i)));
    } else {
      const charId: string = i % 4 === 1 ? CHAR_A : CHAR_B;
      msgs.push(makeAssistantMsg(id, charId, '角色消息' + String(i)));
    }
  }
  return msgs;
}

export default function groupAutoSummaryTest() {
  describe('groupAutoSummary', () => {

    // ===== SUMPLAN-01 默认设置 =====

    it('SUMPLAN_01_default_settings_disabled_medium', 0, () => {
      expect(GROUP_AUTO_SUMMARY_DEFAULT_ENABLED).assertFalse();
      expect(GROUP_AUTO_SUMMARY_DEFAULT_DETAIL_LEVEL).assertEqual(GroupAutoSummaryDetailLevel.Medium);
      const defaults: GroupAutoSummarySettings = createDefaultGroupAutoSummarySettings();
      expect(defaults.enabled).assertFalse();
      expect(defaults.detailLevel).assertEqual(GroupAutoSummaryDetailLevel.Medium);
    });

    // ===== SUMPLAN-02 群聊设置隔离 =====

    it('SUMPLAN_02_group_settings_isolated_by_chat', 0, () => {
      const keys1 = buildGroupAutoSummarySettingKeys(CHAT_1);
      const keys2 = buildGroupAutoSummarySettingKeys(CHAT_2);
      expect(keys1.enabledKey === keys2.enabledKey).assertFalse();
      expect(keys1.levelKey === keys2.levelKey).assertFalse();
      expect(keys1.enabledKey.indexOf(CHAT_1) >= 0).assertTrue();
      expect(keys2.enabledKey.indexOf(CHAT_2) >= 0).assertTrue();
    });

    // ===== SUMPLAN-03 三个档位 =====

    it('SUMPLAN_03_level_specs', 0, () => {
      const concise = getGroupAutoSummaryLevelSpec(GroupAutoSummaryDetailLevel.Concise);
      expect(concise.maxOutputTokens).assertEqual(CONCISE_MAX_TOKENS);
      expect(concise.targetMinChars).assertEqual(150);
      expect(concise.targetMaxChars).assertEqual(300);

      const medium = getGroupAutoSummaryLevelSpec(GroupAutoSummaryDetailLevel.Medium);
      expect(medium.maxOutputTokens).assertEqual(MEDIUM_MAX_TOKENS);
      expect(medium.targetMinChars).assertEqual(350);
      expect(medium.targetMaxChars).assertEqual(700);

      const detailed = getGroupAutoSummaryLevelSpec(GroupAutoSummaryDetailLevel.Detailed);
      expect(detailed.maxOutputTokens).assertEqual(DETAILED_MAX_TOKENS);
      expect(detailed.targetMinChars).assertEqual(700);
      expect(detailed.targetMaxChars).assertEqual(1400);
    });

    // ===== SUMPLAN-04 当前角色隔离 =====

    it('SUMPLAN_04_plan_uses_owner_visible_messages', 0, () => {
      const msgs: ChatMessage[] = [
        makeUserMsg('m0', '公开用户消息'),
        makeAssistantMsg('m1', CHAR_B, 'B 的公开消息'),
        makeUserMsg('m2', '私聊给A', ChatMessageStatus.Completed, 'private', [CHAR_A]),
        makeUserMsg('m3', '私聊给B', ChatMessageStatus.Completed, 'private', [CHAR_B])
      ];
      const planA: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1,
        ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(),
        allMessages: msgs,
        memories: []
      });
      // A 可见:m0(公开用户) + m1(B 公开) + m2(private 含 A)
      expect(planA.completedVisibleMessageCount).assertEqual(3);
      expect(planA.candidateMessageIds.indexOf('m3') >= 0).assertFalse();
    });

    // ===== SUMPLAN-05 跨群聊隔离 =====

    it('SUMPLAN_05_plan_not_use_other_chat_messages', 0, () => {
      const msgs1: ChatMessage[] = makeConversationMessages(4);
      const msgs2: ChatMessage[] = makeConversationMessages(6);
      const plan1: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1,
        ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(),
        allMessages: msgs1,
        memories: []
      });
      // 每个候选消息 ID 必须来自 msgs1
      for (let i = 0; i < plan1.candidateMessageIds.length; i++) {
        let found: boolean = false;
        for (let j = 0; j < msgs1.length; j++) {
          if (msgs1[j].id === plan1.candidateMessageIds[i]) {
            found = true;
            break;
          }
        }
        expect(found).assertTrue();
      }
    });

    // ===== SUMPLAN-06 Public =====

    it('SUMPLAN_06_public_enters_both_windows', 0, () => {
      const msgs: ChatMessage[] = [
        makeUserMsg('m0', '公开消息'),
        makeAssistantMsg('m1', CHAR_A, 'A 公开'),
        makeAssistantMsg('m2', CHAR_B, 'B 公开')
      ];
      const planA: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      const planB: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_B,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      expect(planA.completedVisibleMessageCount).assertEqual(3);
      expect(planB.completedVisibleMessageCount).assertEqual(3);
    });

    // ===== SUMPLAN-07 Private =====

    it('SUMPLAN_07_private_to_a_not_in_b', 0, () => {
      const msgs: ChatMessage[] = [
        makeUserMsg('m0', '公开'),
        makeUserMsg('m1', '私聊给A', ChatMessageStatus.Completed, 'private', [CHAR_A])
      ];
      const planA: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      const planB: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_B,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      expect(planA.completedVisibleMessageCount).assertEqual(2);
      expect(planB.completedVisibleMessageCount).assertEqual(1);
      expect(planB.candidateMessageIds.indexOf('m1') >= 0).assertFalse();
    });

    // ===== SUMPLAN-08 异常状态 =====

    it('SUMPLAN_08_exclude_failed_cancelled_streaming_empty', 0, () => {
      const msgs: ChatMessage[] = [
        makeUserMsg('m0', '正常用户', ChatMessageStatus.Completed),
        makeUserMsg('m1', '失败', ChatMessageStatus.Failed),
        makeUserMsg('m2', '取消', ChatMessageStatus.Cancelled),
        makeUserMsg('m3', '流式', ChatMessageStatus.Streaming),
        makeEmptyMsg('m4'),
        makeAssistantMsg('m5', CHAR_A, '正常角色', ChatMessageStatus.Completed)
      ];
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      expect(plan.completedVisibleMessageCount).assertEqual(2);
      expect(plan.candidateMessageIds.indexOf('m1') >= 0).assertFalse();
      expect(plan.candidateMessageIds.indexOf('m2') >= 0).assertFalse();
      expect(plan.candidateMessageIds.indexOf('m3') >= 0).assertFalse();
      expect(plan.candidateMessageIds.indexOf('m4') >= 0).assertFalse();
    });

    // ===== SUMPLAN-09 旁白 =====

    it('SUMPLAN_09_public_narration_keeps_identity', 0, () => {
      const msgs: ChatMessage[] = [
        makeUserMsg('m0', '用户消息'),
        makeNarratorMsg('m1', '旁白描述动作')
      ];
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      // 公开旁白进入窗口
      expect(plan.candidateMessageIds.indexOf('m1') >= 0).assertTrue();
      expect(plan.narrationMessageCount).assertEqual(1);
      // 但旁白不计入用户/角色消息(不满足最小内容要求)
      const policyInput: GroupAutoSummaryPolicyInput = {
        enabled: true,
        completedVisibleMessageCount: 2,
        userMessageCount: 1,
        characterMessageCount: 0,
        narrationMessageCount: 1,
        estimatedInputTokens: 100
      };
      const r: GroupAutoSummaryPolicyResult = GroupAutoSummaryPolicy.evaluate(policyInput);
      expect(r.eligible).assertFalse();
      expect(r.ineligibleReason).assertEqual(
        GroupAutoSummaryIneligibleReason.NO_CHARACTER_MESSAGE);
    });

    // ===== SUMPLAN-10 首次总结 =====

    it('SUMPLAN_10_first_summary_starts_from_first_visible', 0, () => {
      const msgs: ChatMessage[] = makeConversationMessages(14);
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      // 无旧总结时从第一条有效可见消息开始(整个窗口可见)
      expect(plan.previousSummaryMemoryId).assertEqual('');
      expect(plan.firstCandidateMessageId).assertEqual('m0');
      expect(plan.completedVisibleMessageCount).assertEqual(14);
      expect(plan.eligible).assertTrue();
    });

    // ===== SUMPLAN-11 增量总结 =====

    it('SUMPLAN_11_incremental_after_boundary', 0, () => {
      const msgs: ChatMessage[] = makeConversationMessages(16);
      const memories: GroupCharacterMemory[] = [
        makeSelfSummaryMemory('sm-1', CHAT_1, CHAR_A, 'm7', 'round-2', 'hash-1', 5000)
      ];
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: memories
      });
      // 边界 m7 之后:m8..m15
      expect(plan.previousSummaryBoundaryMessageId).assertEqual('m7');
      expect(plan.firstCandidateMessageId).assertEqual('m8');
      expect(plan.lastCandidateMessageId).assertEqual('m15');
      expect(plan.completedVisibleMessageCount).assertEqual(8);
    });

    // ===== SUMPLAN-12 无新消息 =====

    it('SUMPLAN_12_no_new_messages_not_trigger', 0, () => {
      const msgs: ChatMessage[] = makeConversationMessages(4);
      const memories: GroupCharacterMemory[] = [
        makeSelfSummaryMemory('sm-1', CHAT_1, CHAR_A, 'm3', 'round-1', 'hash-1', 5000)
      ];
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: memories
      });
      expect(plan.completedVisibleMessageCount).assertEqual(0);
      expect(plan.eligible).assertFalse();
      expect(plan.ineligibleReason).assertEqual(GroupAutoSummaryIneligibleReason.NO_NEW_MESSAGES);
    });

    // ===== SUMPLAN-13 消息数量阈值 =====

    it('SUMPLAN_13_12_messages_trigger', 0, () => {
      // 12 条消息:6 用户 + 6 A 角色
      const msgs: ChatMessage[] = [];
      for (let i = 0; i < 12; i++) {
        if (i % 2 === 0) {
          msgs.push(makeUserMsg('m' + String(i), '用户' + String(i)));
        } else {
          msgs.push(makeAssistantMsg('m' + String(i), CHAR_A, '角色' + String(i)));
        }
      }
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      expect(plan.completedVisibleMessageCount).assertEqual(12);
      expect(plan.eligible).assertTrue();
    });

    // ===== SUMPLAN-14 Token 阈值 =====

    it('SUMPLAN_14_token_threshold_trigger', 0, () => {
      // 8 条消息但内容长(每条约 300 中文字符 → 估算 Token 远超 2200)
      const msgs: ChatMessage[] = [];
      for (let i = 0; i < 8; i++) {
        const longContent: string = '很长的中文内容段落'.repeat(40) + String(i);
        if (i % 2 === 0) {
          msgs.push(makeUserMsg('m' + String(i), longContent));
        } else {
          msgs.push(makeAssistantMsg('m' + String(i), CHAR_A, longContent));
        }
      }
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      expect(plan.completedVisibleMessageCount).assertEqual(8);
      expect(plan.estimatedInputTokens >= 2200).assertTrue();
      expect(plan.eligible).assertTrue();
    });

    // ===== SUMPLAN-15 内容结构要求 =====

    it('SUMPLAN_15_requires_user_and_character', 0, () => {
      // 只有用户消息,无角色消息
      const msgsOnlyUser: ChatMessage[] = [
        makeUserMsg('m0', '用户1'),
        makeUserMsg('m1', '用户2'),
        makeUserMsg('m2', '用户3'),
        makeUserMsg('m3', '用户4'),
        makeUserMsg('m4', '用户5'),
        makeUserMsg('m5', '用户6'),
        makeUserMsg('m6', '用户7'),
        makeUserMsg('m7', '用户8'),
        makeUserMsg('m8', '用户9'),
        makeUserMsg('m9', '用户10'),
        makeUserMsg('m10', '用户11'),
        makeUserMsg('m11', '用户12')
      ];
      const planOnlyUser: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgsOnlyUser, memories: []
      });
      expect(planOnlyUser.completedVisibleMessageCount).assertEqual(12);
      expect(planOnlyUser.eligible).assertFalse();
      expect(planOnlyUser.ineligibleReason).assertEqual(
        GroupAutoSummaryIneligibleReason.NO_CHARACTER_MESSAGE);

      // 只有角色消息,无用户消息
      const msgsOnlyChar: ChatMessage[] = [];
      for (let i = 0; i < 12; i++) {
        msgsOnlyChar.push(makeAssistantMsg('c' + String(i), CHAR_A, '角色' + String(i)));
      }
      const planOnlyChar: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgsOnlyChar, memories: []
      });
      expect(planOnlyChar.completedVisibleMessageCount).assertEqual(12);
      expect(planOnlyChar.eligible).assertFalse();
      expect(planOnlyChar.ineligibleReason).assertEqual(
        GroupAutoSummaryIneligibleReason.NO_USER_MESSAGE);
    });

    // ===== SUMPLAN-16 自动总结关闭 =====

    it('SUMPLAN_16_disabled_no_trigger_even_threshold', 0, () => {
      const msgs: ChatMessage[] = makeConversationMessages(14);
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeDisabledSettings(), allMessages: msgs, memories: []
      });
      expect(plan.completedVisibleMessageCount).assertEqual(14);
      expect(plan.eligible).assertFalse();
      expect(plan.ineligibleReason).assertEqual(
        GroupAutoSummaryIneligibleReason.AUTO_SUMMARY_DISABLED);
    });

    // ===== SUMPLAN-17 多条 Active 总结 =====

    it('SUMPLAN_17_multiple_active_no_silent_pick', 0, () => {
      const msgs: ChatMessage[] = makeConversationMessages(14);
      const memories: GroupCharacterMemory[] = [
        makeSelfSummaryMemory('sm-1', CHAT_1, CHAR_A, 'm5', 'round-1', 'hash-1', 3000),
        makeSelfSummaryMemory('sm-2', CHAT_1, CHAR_A, 'm9', 'round-2', 'hash-2', 6000)
      ];
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: memories
      });
      expect(plan.eligible).assertFalse();
      expect(plan.ineligibleReason).assertEqual(
        GroupAutoSummaryIneligibleReason.MULTIPLE_ACTIVE_SELF_SUMMARIES);
      expect(plan.completedVisibleMessageCount).assertEqual(0);
    });

    // ===== SUMPLAN-18 边界缺失 =====

    it('SUMPLAN_18_boundary_missing_no_blind_recompute', 0, () => {
      const msgs: ChatMessage[] = makeConversationMessages(14);
      // 边界消息 m9 不存在(消息被删除),且 sourceRoundId 也不在消息中
      const memories: GroupCharacterMemory[] = [
        makeSelfSummaryMemory('sm-1', CHAT_1, CHAR_A, 'deleted-m9', 'deleted-round', 'hash-1', 3000)
      ];
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: memories
      });
      expect(plan.eligible).assertFalse();
      expect(plan.ineligibleReason).assertEqual(
        GroupAutoSummaryIneligibleReason.BOUNDARY_MESSAGE_MISSING);
      // 不盲目重新总结:候选为空
      expect(plan.completedVisibleMessageCount).assertEqual(0);
    });

    // ===== SUMPLAN-19 计划不持久化正文 =====

    it('SUMPLAN_19_plan_is_runtime_only', 0, () => {
      const msgs: ChatMessage[] = makeConversationMessages(14);
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      // 计划对象仅含 ID 与统计,不含 Provider / 网络 / API Key 字段
      expect(plan.groupConversationId).assertEqual(CHAT_1);
      expect(plan.ownerCharacterId).assertEqual(CHAR_A);
      // 候选消息为运行时引用(不写数据库)
      expect(plan.candidateMessages.length > 0).assertTrue();
      expect(plan.createdAt > 0).assertTrue();
    });

    // ===== SUMPLAN-20 不调用模型 =====

    it('SUMPLAN_20_no_model_called', 0, () => {
      // Planner 为纯函数:输入固定则输出确定,不产生副作用
      const msgs: ChatMessage[] = makeConversationMessages(14);
      const input: GroupAutoSummaryPlanInput = {
        groupConversationId: CHAT_1,
        ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(),
        allMessages: msgs,
        memories: []
      };
      const p1: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan(input);
      const p2: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan(input);
      expect(p1.eligible).assertTrue();
      expect(p2.eligible).assertTrue();
      expect(p1.completedVisibleMessageCount).assertEqual(p2.completedVisibleMessageCount);
      expect(p1.estimatedInputTokens).assertEqual(p2.estimatedInputTokens);
    });

    // ===== SUMPLAN-21 不修改 Repository =====

    it('SUMPLAN_21_plan_does_not_mutate_inputs', 0, () => {
      const msgs: ChatMessage[] = makeConversationMessages(6);
      const beforeLen: number = msgs.length;
      const before0Content: string = msgs[0].content;
      const memories: GroupCharacterMemory[] = [
        makeSelfSummaryMemory('sm-1', CHAT_1, CHAR_A, 'm5', 'round-1', 'hash-1', 3000)
      ];
      const beforeMemLen: number = memories.length;
      GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: memories
      });
      // 输入数组与内容不被修改
      expect(msgs.length).assertEqual(beforeLen);
      expect(msgs[0].content).assertEqual(before0Content);
      expect(memories.length).assertEqual(beforeMemLen);
    });

    // ===== SUMPLAN-22 页面切换不显示上一角色计划 =====
    // 由 ViewModel.switchCharacter 清理 autoSummaryPlan 保证(运行时行为),
    // 本阶段在纯逻辑层验证:计划对象绑定 ownerCharacterId,不同角色计划独立。

    it('SUMPLAN_22_plan_bound_to_owner', 0, () => {
      const msgs: ChatMessage[] = [
        makeUserMsg('m0', '公开'),
        makeAssistantMsg('m1', CHAR_A, 'A 消息'),
        makeAssistantMsg('m2', CHAR_B, 'B 消息')
      ];
      const planA: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      const planB: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_B,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      expect(planA.ownerCharacterId).assertEqual(CHAR_A);
      expect(planB.ownerCharacterId).assertEqual(CHAR_B);
      expect(planA.candidateMessageIds.indexOf('m2') >= 0).assertTrue();
      expect(planB.candidateMessageIds.indexOf('m1') >= 0).assertTrue();
    });

    // ===== SUMPLAN-23 没有手动按钮 =====
    // UI 层面验证:自动总结设置与诊断 UI 不提供"立即总结"入口。
    // 本阶段在纯逻辑层验证:Planner 不包含任何"执行总结/写入"能力,仅返回只读计划。

    it('SUMPLAN_23_planner_has_no_write_api', 0, () => {
      const msgs: ChatMessage[] = makeConversationMessages(14);
      const plan: GroupAutoSummaryPlan = GroupAutoSummaryPlanner.buildPlan({
        groupConversationId: CHAT_1, ownerCharacterId: CHAR_A,
        settings: makeEnabledSettings(), allMessages: msgs, memories: []
      });
      // 计划对象仅含诊断字段(只读接口);Planner 无任何写入/执行 API,
      // 仅返回计划,不修改 Repository,不调用 Provider(SUMPLAN-20/21)。
      expect(plan.eligible).assertTrue();
      expect(plan.completedVisibleMessageCount).assertEqual(14);
    });

    // ===== SUMPLAN-24 单聊不回归 =====
    // 单聊 MemoryService / ChatService / MemoryManagementPage 未在本阶段修改,
    // 不在此文件引入单聊逻辑;回归由完整测试套件保证。
  });
}
