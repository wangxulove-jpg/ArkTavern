/**
 * GroupPromptInspectionModels 群聊 Prompt 诊断快照模型(G-CONTEXT-INSPECTOR-1)
 *
 * 职责:
 * - 定义单角色 Prompt 生成时的诊断快照数据结构
 * - 纯只读诊断,不改变任何业务语义
 * - 快照仅存内存,不持久化
 * - 不记录 API Key / Authorization / 敏感信息
 *
 * 约束:
 * - 当前群聊记忆尚未注入 Prompt,快照必须如实反映(stored>0, selected>=0, injected=0)
 * - 反向关系(B→A)只读显示,标记"不会作为 A 的关系注入"
 * - 不得修改数据库 Schema,不得升级 DATABASE_VERSION
 *
 * G-CONTEXT-MEMORY-SELECTION-1:
 * - memorySelection 保存最近一次真实选择结果(仅内存,不持久化)
 * - 从持久化恢复的快照 memorySelection 为空,页面显示"尚无选择记录"
 */

import { GroupCharacterMemory } from './GroupCharacterMemory';
import { GroupCharacterRelationshipMemory } from './GroupCharacterRelationshipMemory';

/** 记忆诊断项 */
export interface MemoryInspectionItem {
  readonly id: string;
  readonly title: string;
  readonly content: string;
  readonly importance: number;
  readonly origin: string;
  readonly status: string;
  readonly keywords: string[];
  readonly selected: boolean;
  readonly injected: boolean;
}

/** 关系诊断项 */
export interface RelationshipInspectionItem {
  readonly id: string;
  readonly ownerCharacterId: string;
  readonly ownerCharacterName: string;
  readonly targetId: string;
  readonly targetType: string;
  readonly targetName: string;
  readonly direction: string;
  readonly experienceSummary: string;
  readonly attitudeSummary: string;
  readonly relationshipSummary: string;
  readonly importance: number;
  readonly status: string;
  readonly selected: boolean;
  readonly injected: boolean;
  readonly isReverse: boolean;
}

/** Prompt 消息诊断项 */
export interface PromptMessageInspectionItem {
  readonly role: string;
  readonly contentPreview: string;
  readonly estimatedTokens: number;
  readonly category: string;
}

/** G-CONTEXT-VISIBILITY-1: 原始历史消息可见性诊断项 */
export interface HistoryVisibilityInspectionItem {
  readonly messageId: string;
  readonly senderType: string;
  readonly senderCharacterId: string;
  readonly status: string;
  readonly visibility: string;
  readonly recipientCharacterIds: string[];
  readonly replyTargetCharacterIds: string[];
  /** 完整正文(仅本地页面显示,不持久化) */
  readonly content: string;
  readonly visibleToCurrentCharacter: boolean;
  readonly decisionReason: string;
  /** 是否进入最终 Prompt(经过可见性过滤 + 裁剪后仍在 requestMessages) */
  readonly enteredFinalPrompt: boolean;
}

/** G-CONTEXT-VISIBILITY-1: 可见性过滤统计 */
export interface VisibilitySummaryInspection {
  readonly inputCount: number;
  readonly includedCount: number;
  readonly excludedCount: number;
  /** reason -> 数量(仅枚举值,无正文) */
  readonly reasonCounts: Record<string, number>;
}

/** Token 预算诊断 */
export interface TokenBudgetInspection {
  readonly contextWindow: number;
  readonly availableInputTokens: number;
  readonly estimatedTotalTokens: number;
  readonly usagePercent: number;
  readonly totalMessagesBeforeTrim: number;
  readonly totalMessagesAfterTrim: number;
  readonly trimmedMessageCount: number;
}

/** Lorebook 诊断 */
export interface LorebookInspection {
  readonly globalLorebookLoaded: boolean;
  readonly characterLorebookLoaded: boolean;
  readonly matchedEntryCount: number;
}

/** 完整 Prompt 诊断快照 */
export interface GroupPromptInspectionSnapshot {
  readonly snapshotId: string;
  readonly groupConversationId: string;
  readonly speakerCharacterId: string;
  readonly speakerCharacterName: string;
  readonly roundId: string;
  readonly capturedAt: number;

  readonly memories: MemoryInspectionItem[];
  readonly totalMemoriesStored: number;
  readonly totalMemoriesActive: number;
  readonly totalMemoriesSelected: number;
  readonly totalMemoriesInjected: number;

  readonly relationships: RelationshipInspectionItem[];
  readonly totalRelationshipsStored: number;
  readonly totalRelationshipsActive: number;
  readonly totalRelationshipsSelected: number;
  readonly totalRelationshipsInjected: number;
  readonly reverseRelationships: RelationshipInspectionItem[];

  readonly promptMessages: PromptMessageInspectionItem[];
  readonly tokenBudget: TokenBudgetInspection;
  readonly lorebook: LorebookInspection;

  /** G-CONTEXT-VISIBILITY-1: 原始历史可见性诊断(仅本地页面显示,不持久化;从持久化恢复时为空) */
  readonly historyVisibility?: HistoryVisibilityInspectionItem[];
  /** G-CONTEXT-VISIBILITY-1: 可见性过滤统计(持久化恢复时默认空) */
  readonly visibilitySummary?: VisibilitySummaryInspection;

  /** G-CONTEXT-MEMORY-SELECTION-1: 最近一次真实记忆选择(仅内存,不持久化;从持久化恢复时为空) */
  readonly memorySelection?: GroupCharacterMemorySelection;

  /** G-CONTEXT-PROMPT-INJECTION-1: 已格式化个人记忆数(仅内存) */
  readonly totalMemoriesFormatted?: number;
  /** G-CONTEXT-PROMPT-INJECTION-1: 已格式化关系数(仅内存) */
  readonly totalRelationshipsFormatted?: number;
  /** G-CONTEXT-PROMPT-INJECTION-1: 最终注入的个人记忆 System 段完整正文(仅内存,空字符串表示未注入) */
  readonly personalMemorySegmentText?: string;
  /** G-CONTEXT-PROMPT-INJECTION-1: 最终注入的关系 System 段完整正文(仅内存) */
  readonly relationshipMemorySegmentText?: string;
  /** G-CONTEXT-PROMPT-INJECTION-1: 每条已选个人记忆的 selected/formatted/injected 状态(仅内存) */
  readonly memoryInjectionItems?: MemoryInjectionInspectionItem[];
  /** G-CONTEXT-PROMPT-INJECTION-1: 每条已选关系的 selected/formatted/injected 状态(仅内存) */
  readonly relationshipInjectionItems?: RelationshipInjectionInspectionItem[];

  /** G-CONTEXT-MEMORY-SELECTION-1B: 本轮回复目标角色 ID 列表(仅诊断,不用于选择关系记忆) */
  readonly replyTargetCharacterIds?: string[];

  readonly presetSystemPromptPreview: string;
  readonly groupConstraintPreview: string;
  readonly replyTargetMode: string;
  readonly participantNames: string[];
}

// ===== G-CONTEXT-PROMPT-INJECTION-1 记忆注入诊断 =====

/** 单条个人记忆注入状态(selected / formatted / injected) */
export interface MemoryInjectionInspectionItem {
  readonly memoryId: string;
  readonly title: string;
  /** 完整正文(仅本地页面显示,不持久化) */
  readonly content: string;
  readonly selected: boolean;
  readonly formatted: boolean;
  readonly injected: boolean;
  /** 最终 Prompt 中所在消息索引(-1 表示未注入) */
  readonly messageIndex: number;
  /** 防御校验/格式化失败原因(空字符串 = 正常;如 INJECTION_OWNER_MISMATCH / FORMAT_FAILED) */
  readonly failureReason: string;
  readonly estimatedTokens: number;
}

/** 单条关系注入状态 */
export interface RelationshipInjectionInspectionItem {
  readonly relationshipId: string;
  readonly direction: string;
  readonly targetId: string;
  readonly targetType: string;
  readonly experienceSummary: string;
  readonly attitudeSummary: string;
  readonly relationshipSummary: string;
  readonly selected: boolean;
  readonly formatted: boolean;
  readonly injected: boolean;
  readonly messageIndex: number;
  /** 选择目标来源(USER_RELATION_DEFAULT / EXPLICIT_STRUCTURED_TARGET) */
  readonly source: string;
  readonly failureReason: string;
  readonly estimatedTokens: number;
}

// ===== G-CONTEXT-MEMORY-SELECTION-1 记忆选择模型 =====

/** 个人记忆默认最大选择条数 */
export const GROUP_CHARACTER_PERSONAL_MEMORY_MAX_COUNT: number = 5;
/** 关系记忆默认最大选择条数 */
export const GROUP_CHARACTER_RELATIONSHIP_MEMORY_MAX_COUNT: number = 3;
/** 个人记忆默认 Token 预算(估算值,非精确 tokenizer) */
export const GROUP_CHARACTER_PERSONAL_MEMORY_TOKEN_BUDGET: number = 600;
/** 关系记忆默认 Token 预算(估算值,非精确 tokenizer) */
export const GROUP_CHARACTER_RELATIONSHIP_MEMORY_TOKEN_BUDGET: number = 400;

/**
 * 关系选择目标来源(G-CONTEXT-MEMORY-SELECTION-1B)。
 *
 * 核心语义:
 * - replyTargetCharacterIds = 哪些角色负责回复(只能控制谁调用 Provider)
 * - relationshipTargetCharacterIds = 当前 Speaker 正在形成或调用关系认知的对象
 * 二者不得混用。replyTarget 派生的候选仅作为诊断标记(REPLY_TARGET_DERIVED),
 * 不得成为可靠选择来源。
 */
export enum RelationshipSelectionTargetSource {
  /** 用户关系默认来源(owner→user),第一版唯一稳定的角色关系来源 */
  USER_RELATION_DEFAULT = 'user_relation_default',
  /** 显式结构化关系目标(来自语义明确的可靠结构化字段,如 mentionedCharacterIds) */
  EXPLICIT_STRUCTURED_TARGET = 'explicit_structured_target',
  /** 回复目标派生的候选(禁止作为关系来源;仅用于诊断显示被拒绝的原因) */
  REPLY_TARGET_DERIVED = 'reply_target_derived'
}

/** 单个关系目标候选(带来源标记) */
export interface GroupRelationshipTargetCandidate {
  readonly characterId: string;
  readonly source: RelationshipSelectionTargetSource;
}

/**
 * 群聊角色记忆选择输入。
 * - groupConversationId / ownerCharacterId 不得为空
 * - 数组字段由调用方传入,选择器内部复制,不保留页面可变状态引用
 * - 不持久化,不包含 Provider / API Key
 * - participantCharacterIds:当前群聊成员快照(用于验证候选属于当前群聊)
 * - relationshipTargetCandidates:仅来自可靠结构化来源;无可靠来源时为空数组(正常状态)
 */
export interface GroupCharacterMemorySelectionInput {
  readonly groupConversationId: string;
  readonly ownerCharacterId: string;
  readonly currentUserMessage: string;
  /** 当前角色可见历史消息 ID 列表(本阶段不用于排序,仅契约) */
  readonly visibleMessageIds: string[];
  /** 当前群聊成员快照(启用且存在的角色 ID 列表) */
  readonly participantCharacterIds: string[];
  /** 可靠结构化关系目标候选(不允许用 replyTarget 派生) */
  readonly relationshipTargetCandidates: GroupRelationshipTargetCandidate[];
  /** 是否将 owner→user 作为优先候选 */
  readonly includeUserRelationship: boolean;
  readonly personalMemoryMaxCount: number;
  readonly relationshipMemoryMaxCount: number;
  readonly personalMemoryTokenBudget: number;
  readonly relationshipMemoryTokenBudget: number;
}

/** 个人记忆排除原因 */
export enum GroupCharacterMemoryExclusionReason {
  /** 状态非 Active(Archived / Invalidated) */
  EXCLUDED_ARCHIVED = 'excluded_archived',
  /** 正文 trim 后为空 */
  EXCLUDED_EMPTY_CONTENT = 'excluded_empty_content',
  /** 记录 characterId != 当前 owner(所有权防御) */
  EXCLUDED_OWNER_MISMATCH = 'excluded_owner_mismatch',
  /** 记录 groupConversationId != 当前群聊(跨群聊防御) */
  EXCLUDED_CHAT_MISMATCH = 'excluded_chat_mismatch',
  /** 与已保留记录重复(id / sourceHash / sourceMessageId+sourceType) */
  EXCLUDED_DUPLICATE = 'excluded_duplicate',
  /** 超过最大条数预算 */
  EXCLUDED_COUNT_BUDGET = 'excluded_count_budget',
  /** 超过 Token 预算 */
  EXCLUDED_TOKEN_BUDGET = 'excluded_token_budget',
  /** 排序后被更高优先级记录挤掉(第一版保留原因) */
  EXCLUDED_LOWER_PRIORITY = 'excluded_lower_priority',
  /** 查询失败,整体安全降级 */
  EXCLUDED_QUERY_FAILED = 'excluded_query_failed'
}

/** 关系记忆排除原因 */
export enum GroupCharacterRelationshipExclusionReason {
  /** 反向关系(B→A),仅诊断,不选择 */
  EXCLUDED_REVERSE_RELATIONSHIP = 'excluded_reverse_relationship',
  /** 目标不在可靠相关角色列表,或系统持有可靠目标但可证明 B 不相关 */
  EXCLUDED_UNRELATED_TARGET = 'excluded_unrelated_target',
  /** 当前没有可靠的结构化关系目标,owner→character 一律不选择 */
  EXCLUDED_NO_RELIABLE_TARGET = 'excluded_no_reliable_target',
  /** 候选来源是回复目标(replyTarget),回复目标不等于关系目标 */
  EXCLUDED_REPLY_TARGET_NOT_RELATION_TARGET = 'excluded_reply_target_not_relation_target',
  /** 状态非 Active */
  EXCLUDED_ARCHIVED = 'excluded_archived',
  /** ownerCharacterId 与当前角色不符(所有权防御) */
  EXCLUDED_OWNER_MISMATCH = 'excluded_owner_mismatch',
  /** groupConversationId 与当前群聊不符(跨群聊防御) */
  EXCLUDED_CHAT_MISMATCH = 'excluded_chat_mismatch',
  /** 目标为自己(A→A,防御,正常数据不应存在) */
  EXCLUDED_SELF_TARGET = 'excluded_self_target',
  /** targetType / targetId 无效,或候选角色不属于当前群聊成员快照 */
  EXCLUDED_INVALID_TARGET = 'excluded_invalid_target',
  /** 超过最大条数预算 */
  EXCLUDED_COUNT_BUDGET = 'excluded_count_budget',
  /** 超过 Token 预算 */
  EXCLUDED_TOKEN_BUDGET = 'excluded_token_budget',
  /** 重复记录 */
  EXCLUDED_DUPLICATE = 'excluded_duplicate',
  /** 查询失败,整体安全降级 */
  EXCLUDED_QUERY_FAILED = 'excluded_query_failed'
}

/** 已选择个人记忆(附带排序与诊断字段) */
export interface SelectedPersonalMemory {
  readonly memory: GroupCharacterMemory;
  /** 最终排名(从 1 开始) */
  readonly finalRank: number;
  /** 选择原因标签(manual / keyword / importance 等组合,不含正文) */
  readonly selectionReason: string;
  readonly manualPriority: boolean;
  readonly keywordHitCount: number;
  readonly estimatedTokens: number;
  readonly cumulativeTokens: number;
}

/** 未选择个人记忆(含排除原因) */
export interface ExcludedPersonalMemory {
  readonly memory: GroupCharacterMemory;
  readonly reason: GroupCharacterMemoryExclusionReason;
  /** 重复记录时指向被保留的记录 ID(非重复为空字符串) */
  readonly duplicateOfMemoryId: string;
  readonly estimatedTokens: number;
}

/** 已选择关系记忆 */
export interface SelectedRelationshipMemory {
  readonly memory: GroupCharacterRelationshipMemory;
  readonly finalRank: number;
  /** 选择原因标签(related_target / owner_user 等组合) */
  readonly selectionReason: string;
  /** 选择目标来源(G-CONTEXT-MEMORY-SELECTION-1B) */
  readonly source: RelationshipSelectionTargetSource;
  readonly estimatedTokens: number;
  readonly cumulativeTokens: number;
}

/** 未选择关系记忆(含排除原因) */
export interface ExcludedRelationshipMemory {
  readonly memory: GroupCharacterRelationshipMemory;
  readonly reason: GroupCharacterRelationshipExclusionReason;
  /** 重复记录时指向被保留的记录 ID(非重复为空字符串) */
  readonly duplicateOfId: string;
  readonly estimatedTokens: number;
}

/**
 * 群聊角色记忆选择结果。
 * 仅用于检查器诊断,不得注入最终 Prompt,不得持久化。
 */
export interface GroupCharacterMemorySelection {
  readonly groupConversationId: string;
  readonly ownerCharacterId: string;

  /** 全部个人记忆(仅当前群聊 + 当前角色,含 Active/Archived,仅供检查器展示) */
  readonly allPersonalMemories: GroupCharacterMemory[];
  /** 符合选择条件的个人记忆(Active 且正文非空) */
  readonly eligiblePersonalMemories: GroupCharacterMemory[];
  readonly selectedPersonalMemories: SelectedPersonalMemory[];
  readonly excludedPersonalMemories: ExcludedPersonalMemory[];

  /** 全部拥有关系(仅 ownerCharacterId=当前角色,含 Active/Archived) */
  readonly allOwnedRelationships: GroupCharacterRelationshipMemory[];
  readonly selectedRelationships: SelectedRelationshipMemory[];
  readonly excludedRelationships: ExcludedRelationshipMemory[];

  /** 反向关系(B→A / C→A),仅诊断,不进入 selectedRelationships */
  readonly reverseRelationships: GroupCharacterRelationshipMemory[];

  readonly personalEstimatedTokens: number;
  readonly relationshipEstimatedTokens: number;

  /** 个人记忆查询是否失败(失败时 selected=[] 安全降级) */
  readonly personalQueryFailed: boolean;
  /** 拥有关系查询是否失败(失败时 selected=[] 安全降级) */
  readonly relationshipQueryFailed: boolean;
  /** 反向关系查询是否失败(仅诊断区显示错误) */
  readonly reverseQueryFailed: boolean;

  readonly createdAt: number;
}
