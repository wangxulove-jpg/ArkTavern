/**
 * GroupAutoSummaryPlanner 群聊角色自动记忆总结窗口规划器(G-GROUP-AUTO-SUMMARY-1A / 1B)
 *
 * 本文件包含两个纯逻辑类:
 * - GroupAutoSummaryPolicy: 自动总结触发策略
 * - GroupAutoSummaryPlanner: 每角色独立总结窗口规划
 *
 * 1B 修改:
 * - 多条 Active self_summary_v1 不再永久停止,改为生成立场 LEGACY_CONSOLIDATION_REQUIRED 计划
 * - 扩展 GroupAutoSummaryPlan 的 activeSummaryIds/Contents/Hashes/Count/requiresConsolidation 字段
 * - 旧总结输入预算计算:computeLegacySummaryInputBudget + estimateMessagesTokens
 *
 * 触发策略(第一版统一):
 * 自动总结已开启
 * 并且 自上次成功总结后:
 * - 新增可见 Completed 消息数量 >= 12
 *   或
 * - 新增可见内容估算 Token >= 2200
 * 并且
 * - 至少包含 1 条用户消息
 * - 至少包含 1 条角色可见的 Assistant/Character 消息
 */

import { ChatMessage } from '../../models/ChatMessage';
import { GroupCharacterMemory, GroupCharacterMemoryOrigin, GroupCharacterMemoryStatus } from '../../models/groupchat/GroupCharacterMemory';
import { GroupAutoSummarySettings, GroupAutoSummaryDetailLevel, GroupAutoSummaryPlan } from '../../models/groupchat/GroupAutoSummaryModels';
import { GroupMessageVisibilityPolicy } from './GroupMessageVisibilityPolicy';
import { estimateMessagesTokens } from '../TokenCounter';
import { nowMillis } from '../../utils/Time';

/** 滚动总结来源类型标识(与 GroupCharacterSelfSummaryService 一致) */
const SOURCE_TYPE_SELF_SUMMARY_V1: string = 'self_summary_v1';

// ===== GroupAutoSummaryPolicy:触发策略(纯逻辑,无状态) =====

/** 触发策略原因枚举 */
export enum GroupAutoSummaryIneligibleReason {
  /** 自动总结开关已关闭 */
  AUTO_SUMMARY_DISABLED = 'auto_summary_disabled',
  /** 没有新增可见消息 */
  NO_NEW_MESSAGES = 'no_new_messages',
  /** 未达到消息数 / Token 阈值 */
  BELOW_THRESHOLD = 'below_threshold',
  /** 新增窗口中缺少用户消息 */
  NO_USER_MESSAGE = 'no_user_message',
  /** 新增窗口中缺少角色可见消息 */
  NO_CHARACTER_MESSAGE = 'no_character_message',
  /** 当前存在多条 Active self_summary_v1(不合并,不选一条,停止规划) */
  MULTIPLE_ACTIVE_SELF_SUMMARIES = 'multiple_active_self_summaries',
  /** 上次总结边界消息已删除且无法恢复,不得盲目重新总结 */
  BOUNDARY_MESSAGE_MISSING = 'boundary_message_missing'
}

/** 触发策略输入(已完成可见性过滤与增量窗口构建后的统计) */
export interface GroupAutoSummaryPolicyInput {
  readonly enabled: boolean;
  readonly completedVisibleMessageCount: number;
  readonly userMessageCount: number;
  readonly characterMessageCount: number;
  readonly narrationMessageCount: number;
  readonly estimatedInputTokens: number;
}

/** 触发策略判定结果 */
export interface GroupAutoSummaryPolicyResult {
  readonly eligible: boolean;
  /** eligible 为 false 时的原因(空字符串表示已触发) */
  readonly ineligibleReason: GroupAutoSummaryIneligibleReason | '';
}

/** 自动总结触发策略(纯逻辑,无状态) */
export class GroupAutoSummaryPolicy {
  /** 新增可见 Completed 消息数量阈值 */
  static readonly MESSAGE_COUNT_THRESHOLD: number = 12;
  /** 新增可见内容估算 Token 阈值 */
  static readonly TOKEN_THRESHOLD: number = 2200;

  /**
   * 判定是否满足自动总结触发条件。
   *
   * @param input 窗口统计(由 Planner 基于每角色可见性构建)
   * @returns eligible + 不触发原因
   */
  static evaluate(input: GroupAutoSummaryPolicyInput): GroupAutoSummaryPolicyResult {
    // 1. 开关关闭:即使达到阈值也不触发
    if (!input.enabled) {
      return {
        eligible: false,
        ineligibleReason: GroupAutoSummaryIneligibleReason.AUTO_SUMMARY_DISABLED
      };
    }

    // 2. 无新消息
    if (input.completedVisibleMessageCount === 0) {
      return {
        eligible: false,
        ineligibleReason: GroupAutoSummaryIneligibleReason.NO_NEW_MESSAGES
      };
    }

    // 3. 最小内容要求:至少 1 条用户消息
    if (input.userMessageCount === 0) {
      return {
        eligible: false,
        ineligibleReason: GroupAutoSummaryIneligibleReason.NO_USER_MESSAGE
      };
    }

    // 4. 最小内容要求:至少 1 条角色可见消息(旁白不计)
    if (input.characterMessageCount === 0) {
      return {
        eligible: false,
        ineligibleReason: GroupAutoSummaryIneligibleReason.NO_CHARACTER_MESSAGE
      };
    }

    // 5. 阈值:消息数或 Token 任一达标即可
    const reachedMessageThreshold: boolean =
      input.completedVisibleMessageCount >= GroupAutoSummaryPolicy.MESSAGE_COUNT_THRESHOLD;
    const reachedTokenThreshold: boolean =
      input.estimatedInputTokens >= GroupAutoSummaryPolicy.TOKEN_THRESHOLD;
    if (!reachedMessageThreshold && !reachedTokenThreshold) {
      return {
        eligible: false,
        ineligibleReason: GroupAutoSummaryIneligibleReason.BELOW_THRESHOLD
      };
    }

    return {
      eligible: true,
      ineligibleReason: ''
    };
  }
}

// ===== GroupAutoSummaryPlanner:总结窗口规划(纯逻辑,无状态) =====

/** Planner 输入 */
export interface GroupAutoSummaryPlanInput {
  readonly groupConversationId: string;
  readonly ownerCharacterId: string;
  readonly settings: GroupAutoSummarySettings;
  /** 群聊全部消息(已按 sequenceNumber ASC) */
  readonly allMessages: ChatMessage[];
  /** 该角色在当前群聊的全部记忆 */
  readonly memories: GroupCharacterMemory[];
}

/** 自动总结计划构建器。无状态纯逻辑。 */
export class GroupAutoSummaryPlanner {
  /**
   * 构建单角色自动总结计划。
   *
   * 流程:
   * 1. 定位 self_summary_v1 记录,检查多条 Active(异常则停止规划)
   * 2. 确定上次总结边界(sourceMessageId 优先,sourceRoundId 兜底)
   * 3. 边界消息缺失且无法恢复 → BOUNDARY_MESSAGE_MISSING(不盲目重算)
   * 4. 从边界之后按 owner 可见性过滤,构建候选窗口
   * 5. 统计用户 / 角色 / 旁白消息数量与估算 Token
   * 6. 调用 GroupAutoSummaryPolicy 判定 eligible
   */
  static buildPlan(input: GroupAutoSummaryPlanInput): GroupAutoSummaryPlan {
    const groupConversationId: string = input.groupConversationId;
    const ownerCharacterId: string = input.ownerCharacterId;
    const createdAt: number = nowMillis();

    // 1. 定位 self_summary_v1 记录
    const summaries: GroupCharacterMemory[] = [];
    for (let i = 0; i < input.memories.length; i++) {
      const m: GroupCharacterMemory = input.memories[i];
      if (m.origin === GroupCharacterMemoryOrigin.Interaction
        && m.sourceType === SOURCE_TYPE_SELF_SUMMARY_V1
        && m.status !== GroupCharacterMemoryStatus.Invalidated) {
        summaries.push(m);
      }
    }

    // 多条 Active → 1B:不再停止规划,改为收集全部旧总结用于归并
    const activeSummaries: GroupCharacterMemory[] = summaries.filter(
      (m: GroupCharacterMemory): boolean => m.status === GroupCharacterMemoryStatus.Active
    );
    // 按 updatedAt ASC 排序(旧→新),同时间按 id ASC
    activeSummaries.sort(
      (a: GroupCharacterMemory, b: GroupCharacterMemory): number => {
        if (a.updatedAt !== b.updatedAt) {
          return a.updatedAt - b.updatedAt;
        }
        if (a.id < b.id) {
          return -1;
        }
        if (a.id > b.id) {
          return 1;
        }
        return 0;
      }
    );

    const activeIds: string[] = [];
    const activeContents: string[] = [];
    const activeSourceHashes: string[] = [];
    for (let i = 0; i < activeSummaries.length; i++) {
      activeIds.push(activeSummaries[i].id);
      activeContents.push(activeSummaries[i].content);
      const sh: string | undefined = activeSummaries[i].sourceHash;
      activeSourceHashes.push(sh !== undefined ? sh : '');
    }

    // 最近一次总结(updatedAt 最新,用于边界与诊断)
    const previousSummary: GroupCharacterMemory | null =
      GroupAutoSummaryPlanner.findLatestSummary(summaries);

    // 2. 确定增量起点
    let startIdx: number = 0;
    if (previousSummary !== null) {
      const boundaryResolved: number =
        GroupAutoSummaryPlanner.resolveBoundaryStartIndex(
          input.allMessages, previousSummary
        );
      if (boundaryResolved < 0) {
        // 边界消息缺失且无法恢复:不盲目重新总结
        return GroupAutoSummaryPlanner.buildIneligiblePlan(
          groupConversationId,
          ownerCharacterId,
          input.settings,
          GroupAutoSummaryIneligibleReason.BOUNDARY_MESSAGE_MISSING,
          summaries,
          createdAt
        );
      }
      startIdx = boundaryResolved;
    }

    // 3. 边界之后的消息按 owner 可见性过滤(复用 GroupMessageVisibilityPolicy)
    const windowSlice: ChatMessage[] = input.allMessages.slice(startIdx);
    const visibleMessages: ChatMessage[] =
      GroupMessageVisibilityPolicy.filterVisible(windowSlice, ownerCharacterId).includedMessages;

    // 4. 统计
    let userCount: number = 0;
    let characterCount: number = 0;
    let narrationCount: number = 0;
    const candidateIds: string[] = [];
    for (let i = 0; i < visibleMessages.length; i++) {
      const msg: ChatMessage = visibleMessages[i];
      candidateIds.push(msg.id);
      const senderType: string = msg.senderType !== undefined ? msg.senderType! : 'user';
      if (senderType === 'user') {
        userCount++;
      } else if (senderType === 'character') {
        characterCount++;
      } else if (senderType === 'narrator') {
        narrationCount++;
      }
    }

    const estimatedInputTokens: number = estimateMessagesTokens(visibleMessages);
    const firstId: string = candidateIds.length > 0 ? candidateIds[0] : '';
    const lastId: string = candidateIds.length > 0 ? candidateIds[candidateIds.length - 1] : '';

    // 5. 触发判定
    const policyInput: GroupAutoSummaryPolicyInput = {
      enabled: input.settings.enabled,
      completedVisibleMessageCount: visibleMessages.length,
      userMessageCount: userCount,
      characterMessageCount: characterCount,
      narrationMessageCount: narrationCount,
      estimatedInputTokens: estimatedInputTokens
    };
    const policyResult: GroupAutoSummaryPolicyResult =
      GroupAutoSummaryPolicy.evaluate(policyInput);

    // 6. 组装计划
    const previousMemoryId: string = previousSummary !== null ? previousSummary.id : '';
    const previousContent: string = previousSummary !== null ? previousSummary.content : '';
    const previousBoundaryMessageId: string =
      previousSummary !== null && previousSummary.sourceMessageId !== undefined
        ? previousSummary.sourceMessageId : '';
    const previousBoundaryRoundId: string =
      previousSummary !== null && previousSummary.sourceRoundId !== undefined
        ? previousSummary.sourceRoundId : '';
    const previousUpdatedAt: number = previousSummary !== null ? previousSummary.updatedAt : 0;
    const previousSourceHash: string =
      previousSummary !== null && previousSummary.sourceHash !== undefined
        ? previousSummary.sourceHash : '';

    const plan: GroupAutoSummaryPlan = {
      groupConversationId: groupConversationId,
      ownerCharacterId: ownerCharacterId,
      detailLevel: input.settings.detailLevel,
      previousSummaryMemoryId: previousMemoryId,
      previousSummaryContent: previousContent,
      previousSummaryBoundaryMessageId: previousBoundaryMessageId,
      previousSummaryBoundaryRoundId: previousBoundaryRoundId,
      previousSummaryUpdatedAt: previousUpdatedAt,
      previousSummarySourceHash: previousSourceHash,
      activeSummaryIds: activeIds,
      activeSummaryContents: activeContents,
      activeSummarySourceHashes: activeSourceHashes,
      activeSummaryCount: activeSummaries.length,
      requiresConsolidation: activeSummaries.length > 1,
      candidateMessages: visibleMessages,
      candidateMessageIds: candidateIds,
      firstCandidateMessageId: firstId,
      lastCandidateMessageId: lastId,
      completedVisibleMessageCount: visibleMessages.length,
      userMessageCount: userCount,
      characterMessageCount: characterCount,
      narrationMessageCount: narrationCount,
      estimatedInputTokens: estimatedInputTokens,
      eligible: policyResult.eligible,
      ineligibleReason: policyResult.ineligibleReason,
      createdAt: createdAt
    };
    return plan;
  }

  /** 构建不可执行计划(边界异常) */
  private static buildIneligiblePlan(
    groupConversationId: string,
    ownerCharacterId: string,
    settings: GroupAutoSummarySettings,
    reason: GroupAutoSummaryIneligibleReason,
    summaries: GroupCharacterMemory[],
    createdAt: number
  ): GroupAutoSummaryPlan {
    const previousSummary: GroupCharacterMemory | null =
      GroupAutoSummaryPlanner.findLatestSummary(summaries);
    const plan: GroupAutoSummaryPlan = {
      groupConversationId: groupConversationId,
      ownerCharacterId: ownerCharacterId,
      detailLevel: settings.detailLevel,
      previousSummaryMemoryId: previousSummary !== null ? previousSummary.id : '',
      previousSummaryContent: previousSummary !== null ? previousSummary.content : '',
      previousSummaryBoundaryMessageId:
        previousSummary !== null && previousSummary.sourceMessageId !== undefined
          ? previousSummary.sourceMessageId : '',
      previousSummaryBoundaryRoundId:
        previousSummary !== null && previousSummary.sourceRoundId !== undefined
          ? previousSummary.sourceRoundId : '',
      previousSummaryUpdatedAt: previousSummary !== null ? previousSummary.updatedAt : 0,
      previousSummarySourceHash:
        previousSummary !== null && previousSummary.sourceHash !== undefined
          ? previousSummary.sourceHash : '',
      activeSummaryIds: [],
      activeSummaryContents: [],
      activeSummarySourceHashes: [],
      activeSummaryCount: 0,
      requiresConsolidation: false,
      candidateMessages: [],
      candidateMessageIds: [],
      firstCandidateMessageId: '',
      lastCandidateMessageId: '',
      completedVisibleMessageCount: 0,
      userMessageCount: 0,
      characterMessageCount: 0,
      narrationMessageCount: 0,
      estimatedInputTokens: 0,
      eligible: false,
      ineligibleReason: reason,
      createdAt: createdAt
    };
    return plan;
  }

  /** 查找最近一次总结(updatedAt 最新,排除 Invalidated) */
  private static findLatestSummary(
    summaries: GroupCharacterMemory[]
  ): GroupCharacterMemory | null {
    let latest: GroupCharacterMemory | null = null;
    for (let i = 0; i < summaries.length; i++) {
      const m: GroupCharacterMemory = summaries[i];
      if (m.status === GroupCharacterMemoryStatus.Invalidated) {
        continue;
      }
      if (latest === null || m.updatedAt > latest.updatedAt) {
        latest = m;
      }
    }
    return latest;
  }

  /**
   * 解析增量起点索引。
   * 优先 sourceMessageId;找不到时用 sourceRoundId(generationBatchId) 定位;
   * 仍找不到返回 -1(边界缺失)。
   */
  private static resolveBoundaryStartIndex(
    allMessages: ChatMessage[],
    previousSummary: GroupCharacterMemory
  ): number {
    // 1. sourceMessageId
    const messageId: string =
      previousSummary.sourceMessageId !== undefined ? previousSummary.sourceMessageId : '';
    if (messageId.length > 0) {
      for (let i = 0; i < allMessages.length; i++) {
        if (allMessages[i].id === messageId) {
          return i + 1;
        }
      }
    }
    // 2. sourceRoundId(generationBatchId) 兜底
    const roundId: string =
      previousSummary.sourceRoundId !== undefined ? previousSummary.sourceRoundId : '';
    if (roundId.length > 0) {
      let lastIdx: number = -1;
      for (let i = 0; i < allMessages.length; i++) {
        if (allMessages[i].generationBatchId === roundId) {
          lastIdx = i;
        }
      }
      if (lastIdx >= 0) {
        return lastIdx + 1;
      }
    }
    return -1;
  }
}
