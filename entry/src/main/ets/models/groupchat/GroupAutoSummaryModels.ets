/**
 * GroupAutoSummaryModels 群聊角色自动记忆总结模型(G-GROUP-AUTO-SUMMARY-1A / 1B)
 *
 * 1A 职责:
 * - 定义自动总结详细程度档位(简洁 / 中等 / 详细)
 * - 定义按群聊独立的自动总结设置(开关 + 档位)
 * - 定义每角色独立的自动总结计划(GroupAutoSummaryPlan)
 * - 档位规格:输出目标字数 + maxOutputTokens
 * - 设置持久化:按群聊独立保存到 Preferences
 *
 * 1B 新增:
 * - 执行状态枚举 GroupAutoSummaryExecutionStatus
 * - 执行输入/输出类型 GroupAutoSummaryExecutionInput / GroupAutoSummaryExecutionResult
 * - 输出硬上限常量 OUTPUT_HARD_CAP_*
 * - 旧总结输入预算常量 LEGACY_SUMMARY_INPUT_BUDGET_FRACTION
 * - 幂等哈希计算 computeSummaryInputHash
 * - Plan 扩展字段:activeSummaryIds/Contents/Hashes/Count(旧数据归并)
 *
 * 不修改数据库 Schema / DATABASE_VERSION。
 */

import { ChatMessage } from '../ChatMessage';
import { ProviderConfig } from '../ProviderConfig';
import { GroupUserIdentitySnapshot } from './GroupUserIdentitySnapshot';
import { preferences } from '@kit.ArkData';

/** 自动总结详细程度档位 */
export enum GroupAutoSummaryDetailLevel {
  /** 简洁:保留最关键事实、承诺和未完成事项 */
  Concise = 'concise',
  /** 中等:保留主要事件、重要细节、用户信息和关系互动事实 */
  Medium = 'medium',
  /** 详细:保留较完整事件脉络、重要细节和长期连续性 */
  Detailed = 'detailed'
}

/** 自动总结设置(按群聊独立) */
export interface GroupAutoSummarySettings {
  readonly enabled: boolean;
  readonly detailLevel: GroupAutoSummaryDetailLevel;
}

/** 设置默认值:关闭 + 中等 */
export const GROUP_AUTO_SUMMARY_DEFAULT_ENABLED: boolean = false;
export const GROUP_AUTO_SUMMARY_DEFAULT_DETAIL_LEVEL: GroupAutoSummaryDetailLevel =
  GroupAutoSummaryDetailLevel.Medium;

/** 档位规格 */
export interface GroupAutoSummaryLevelSpec {
  readonly detailLevel: GroupAutoSummaryDetailLevel;
  readonly label: string;
  readonly targetMinChars: number;
  readonly targetMaxChars: number;
  readonly maxOutputTokens: number;
}

const CONCISE_SPEC: GroupAutoSummaryLevelSpec = {
  detailLevel: GroupAutoSummaryDetailLevel.Concise,
  label: '简洁',
  targetMinChars: 150,
  targetMaxChars: 300,
  maxOutputTokens: 256
};

const MEDIUM_SPEC: GroupAutoSummaryLevelSpec = {
  detailLevel: GroupAutoSummaryDetailLevel.Medium,
  label: '中等',
  targetMinChars: 350,
  targetMaxChars: 700,
  maxOutputTokens: 512
};

const DETAILED_SPEC: GroupAutoSummaryLevelSpec = {
  detailLevel: GroupAutoSummaryDetailLevel.Detailed,
  label: '详细',
  targetMinChars: 700,
  targetMaxChars: 1400,
  maxOutputTokens: 1024
};

/** 获取指定档位规格 */
export function getGroupAutoSummaryLevelSpec(
  level: GroupAutoSummaryDetailLevel
): GroupAutoSummaryLevelSpec {
  if (level === GroupAutoSummaryDetailLevel.Concise) {
    return CONCISE_SPEC;
  }
  if (level === GroupAutoSummaryDetailLevel.Detailed) {
    return DETAILED_SPEC;
  }
  return MEDIUM_SPEC;
}

/** 判断字符串是否为合法档位 */
export function isGroupAutoSummaryDetailLevel(value: string): boolean {
  return value === GroupAutoSummaryDetailLevel.Concise
    || value === GroupAutoSummaryDetailLevel.Medium
    || value === GroupAutoSummaryDetailLevel.Detailed;
}

/** 创建默认设置(关闭 + 中等) */
export function createDefaultGroupAutoSummarySettings(): GroupAutoSummarySettings {
  const settings: GroupAutoSummarySettings = {
    enabled: GROUP_AUTO_SUMMARY_DEFAULT_ENABLED,
    detailLevel: GROUP_AUTO_SUMMARY_DEFAULT_DETAIL_LEVEL
  };
  return settings;
}

// ===== 设置持久化(按群聊独立,复用现有群聊设置持久化方式) =====

const STORE_NAME: string = 'ArkTavernSettings';
const AUTO_SUMMARY_KEY_PREFIX: string = 'group_auto_summary_';
const AUTO_SUMMARY_LEVEL_KEY_PREFIX: string = 'group_auto_summary_level_';

/** 生成按群聊独立的设置 key(供测试与持久化复用,保证群聊间互不影响) */
export interface GroupAutoSummarySettingKeys {
  readonly enabledKey: string;
  readonly levelKey: string;
}

export function buildGroupAutoSummarySettingKeys(groupConversationId: string): GroupAutoSummarySettingKeys {
  const keys: GroupAutoSummarySettingKeys = {
    enabledKey: AUTO_SUMMARY_KEY_PREFIX + groupConversationId,
    levelKey: AUTO_SUMMARY_LEVEL_KEY_PREFIX + groupConversationId
  };
  return keys;
}

/** 加载指定群聊的自动总结设置,异常或不存在时返回默认(关闭 + 中等) */
export async function loadGroupAutoSummarySettings(
  groupConversationId: string
): Promise<GroupAutoSummarySettings> {
  if (groupConversationId.length === 0) {
    return createDefaultGroupAutoSummarySettings();
  }
  try {
    const ctx: Context = getContext();
    const prefs: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    const keys: GroupAutoSummarySettingKeys = buildGroupAutoSummarySettingKeys(groupConversationId);
    const enabledRaw: number = (prefs.getSync(keys.enabledKey, 0)) as number;
    const levelRaw: string = (prefs.getSync(keys.levelKey, GroupAutoSummaryDetailLevel.Medium)) as string;
    const enabled: boolean = enabledRaw === 1;
    const detailLevel: GroupAutoSummaryDetailLevel =
      isGroupAutoSummaryDetailLevel(levelRaw)
        ? (levelRaw as GroupAutoSummaryDetailLevel)
        : GroupAutoSummaryDetailLevel.Medium;
    const settings: GroupAutoSummarySettings = {
      enabled: enabled,
      detailLevel: detailLevel
    };
    return settings;
  } catch (e) {
    return createDefaultGroupAutoSummarySettings();
  }
}

/** 持久化指定群聊的自动总结开关 */
export function persistGroupAutoSummaryEnabled(
  groupConversationId: string,
  enabled: boolean
): void {
  if (groupConversationId.length === 0) {
    return;
  }
  try {
    const ctx: Context = getContext();
    preferences.getPreferences(ctx, STORE_NAME).then((prefs: preferences.Preferences): void => {
      const keys: GroupAutoSummarySettingKeys = buildGroupAutoSummarySettingKeys(groupConversationId);
      prefs.put(keys.enabledKey, enabled ? 1 : 0);
      prefs.flush();
    }).catch((): void => {
      // silently ignore
    });
  } catch (e) {
    // silently ignore
  }
}

/** 持久化指定群聊的自动总结档位 */
export function persistGroupAutoSummaryDetailLevel(
  groupConversationId: string,
  detailLevel: GroupAutoSummaryDetailLevel
): void {
  if (groupConversationId.length === 0) {
    return;
  }
  try {
    const ctx: Context = getContext();
    preferences.getPreferences(ctx, STORE_NAME).then((prefs: preferences.Preferences): void => {
      const keys: GroupAutoSummarySettingKeys = buildGroupAutoSummarySettingKeys(groupConversationId);
      prefs.put(keys.levelKey, detailLevel);
      prefs.flush();
    }).catch((): void => {
      // silently ignore
    });
  } catch (e) {
    // silently ignore
  }
}

/**
 * GroupAutoSummaryPlan 每角色独立的自动总结计划。
 *
 * 1A:只定义计划与可行性验证。
 * 1B:扩展 activeSummaryIds/Contents/Hashes/Count 字段,
 *    支持对多条旧 Active 总结的安全归并。
 */
export interface GroupAutoSummaryPlan {
  readonly groupConversationId: string;
  readonly ownerCharacterId: string;
  readonly detailLevel: GroupAutoSummaryDetailLevel;

  /** 上一次成功总结记忆 ID(空字符串表示尚无) */
  readonly previousSummaryMemoryId: string;
  /** 上一次成功总结正文(空字符串表示尚无) */
  readonly previousSummaryContent: string;
  /** 上次成功总结边界消息 ID(作为增量游标) */
  readonly previousSummaryBoundaryMessageId: string;
  /** 上次成功总结边界轮次 ID */
  readonly previousSummaryBoundaryRoundId: string;
  /** 上次成功总结 updatedAt(0 表示尚无,供诊断显示) */
  readonly previousSummaryUpdatedAt: number;
  /** 上次成功总结 sourceHash(空字符串表示尚无) */
  readonly previousSummarySourceHash: string;

  /** 1B:所有 Active self_summary_v1 记忆 ID(空数组=0条) */
  readonly activeSummaryIds: string[];
  /** 1B:所有 Active self_summary_v1 正文(与 IDs 同序) */
  readonly activeSummaryContents: string[];
  /** 1B:所有 Active self_summary_v1 sourceHash(与 IDs 同序) */
  readonly activeSummarySourceHashes: string[];
  /** 1B:Active 总结数量(0/1/≥2) */
  readonly activeSummaryCount: number;
  /** 1B:是否需要旧数据归并(activeSummaryCount > 1) */
  readonly requiresConsolidation: boolean;

  /** 本次候选消息(对 owner 可见的 Completed 消息,仅运行时持有) */
  readonly candidateMessages: ChatMessage[];
  /** 候选消息 ID 列表 */
  readonly candidateMessageIds: string[];
  /** 第一条候选消息 ID(空表示无候选) */
  readonly firstCandidateMessageId: string;
  /** 最后一条候选消息 ID(空表示无候选) */
  readonly lastCandidateMessageId: string;

  readonly completedVisibleMessageCount: number;
  readonly userMessageCount: number;
  readonly characterMessageCount: number;
  readonly narrationMessageCount: number;
  /** 候选消息估算 Token(estimateMessagesTokens) */
  readonly estimatedInputTokens: number;

  readonly eligible: boolean;
  readonly ineligibleReason: string;
  readonly createdAt: number;
}

// ===== 1B: 执行状态与结果类型 =====

/** 自动总结执行状态 */
export enum GroupAutoSummaryExecutionStatus {
  SUCCESS = 'success',
  SKIPPED_DISABLED = 'skipped_disabled',
  SKIPPED_BELOW_THRESHOLD = 'skipped_below_threshold',
  ALREADY_SUMMARIZED = 'already_summarized',
  LEGACY_CONSOLIDATION_REQUIRED = 'legacy_consolidation_required',
  LEGACY_SUMMARY_INPUT_TOO_LARGE = 'legacy_summary_input_too_large',
  MODEL_FAILED = 'model_failed',
  EMPTY_OUTPUT = 'empty_output',
  OUTPUT_TOO_LONG = 'output_too_long',
  SAVE_FAILED = 'save_failed',
  STOPPED = 'stopped',
  PLANNER_FAILED = 'planner_failed',
  SETTINGS_DISABLED_AT_CHECK = 'settings_disabled_at_check',
  DUPLICATE_IN_FLIGHT = 'duplicate_in_flight',
  STALE_OPERATION = 'stale_operation',
  ACTIVE_SUMMARY_INVARIANT_FAILED = 'active_summary_invariant_failed'
}

/** 执行器输入(不可变) */
export interface GroupAutoSummaryExecutionInput {
  readonly plan: GroupAutoSummaryPlan;
  readonly providerConfigSnapshot: ProviderConfig;
  readonly roundId: string;
  readonly operationId: number;
  /** 用于日志安全:角色名称(非完整卡) */
  readonly ownerCharacterName: string;
  /** 用于消息格式化:参与角色名称映射 characterId→name */
  readonly participantNames: Record<string, string>;
  /** G-GROUP-USER-IDENTITY-1: 本轮唯一用户身份快照 */
  readonly userIdentity?: GroupUserIdentitySnapshot;
}

/** 执行器输出(不可变,不含完整正文/API Key) */
export interface GroupAutoSummaryExecutionResult {
  readonly groupConversationId: string;
  readonly ownerCharacterId: string;
  readonly status: GroupAutoSummaryExecutionStatus;
  readonly previousActiveSummaryCount: number;
  readonly resultingActiveSummaryCount: number;
  readonly boundaryMessageId: string;
  readonly sourceHash: string;
  readonly generatedCharacterCount: number;
  readonly estimatedInputTokens: number;
  readonly outputLength: number;
  readonly errorCode: string;
}

/** 输出硬上限(中文/日文/韩文等宽字符),超出不截断保存 */
export const OUTPUT_HARD_CAP_CONCISE: number = 500;
export const OUTPUT_HARD_CAP_MEDIUM: number = 1000;
export const OUTPUT_HARD_CAP_DETAILED: number = 1800;

/** 旧 Active 总结输入预算:contextWindow * 40%(保守,给新增消息留足空间) */
export const LEGACY_SUMMARY_INPUT_BUDGET_FRACTION: number = 0.4;

/** 获取指定档位的输出硬上限 */
export function getOutputHardCap(level: GroupAutoSummaryDetailLevel): number {
  if (level === GroupAutoSummaryDetailLevel.Concise) {
    return OUTPUT_HARD_CAP_CONCISE;
  }
  if (level === GroupAutoSummaryDetailLevel.Detailed) {
    return OUTPUT_HARD_CAP_DETAILED;
  }
  return OUTPUT_HARD_CAP_MEDIUM;
}

/** 默认 context window(Provider 未显式配置时使用) */
export const DEFAULT_CONTEXT_WINDOW: number = 65536;

/** 计算旧总结输入安全 Token 预算 */
export function computeLegacySummaryInputBudget(config: ProviderConfig): number {
  const window: number = config.contextWindow !== undefined && config.contextWindow > 0
    ? config.contextWindow : DEFAULT_CONTEXT_WINDOW;
  return Math.floor(window * LEGACY_SUMMARY_INPUT_BUDGET_FRACTION);
}

/**
 * 1B:计算总结输入幂等哈希(防止同一窗口重复调用模型)。
 *
 * 输入:promptVersion + detailLevel + groupConversationId + ownerCharacterId
 *   + activeSummaryIds.join + candidateMessageIds.join + lastCandidateMessageId
 * 不含 API Key / 正文。
 * 算法:djb2 变体(确定性,非加密)。
 */
export function computeSummaryInputHash(
  plan: GroupAutoSummaryPlan,
  promptVersion: string
): string {
  const parts: string[] = [];
  parts.push(promptVersion);
  parts.push(plan.detailLevel);
  parts.push(plan.groupConversationId);
  parts.push(plan.ownerCharacterId);
  for (let i = 0; i < plan.activeSummaryIds.length; i++) {
    parts.push(plan.activeSummaryIds[i]);
  }
  for (let i = 0; i < plan.candidateMessageIds.length; i++) {
    parts.push(plan.candidateMessageIds[i]);
  }
  parts.push(plan.lastCandidateMessageId);
  const input: string = parts.join('\u0001');
  let hash: number = 5381;
  for (let i = 0; i < input.length; i++) {
    hash = ((hash * 33) ^ input.charCodeAt(i)) >>> 0;
  }
  return 'asp-' + hash.toString(16).padStart(8, '0');
}
