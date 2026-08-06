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
 * - 当前群聊记忆尚未注入 Prompt,快照必须如实反映(stored>0, selected=0, injected=0)
 * - 反向关系(B→A)只读显示,标记"不会作为 A 的关系注入"
 * - 不得修改数据库 Schema,不得升级 DATABASE_VERSION
 */

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

  readonly presetSystemPromptPreview: string;
  readonly groupConstraintPreview: string;
  readonly replyTargetMode: string;
  readonly participantNames: string[];
}
