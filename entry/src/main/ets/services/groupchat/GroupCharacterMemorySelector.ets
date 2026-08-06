/**
 * GroupCharacterMemorySelector 群聊角色记忆选择器(G-CONTEXT-MEMORY-SELECTION-1)
 *
 * 职责:
 * - 为"当前群聊 + 当前 Speaker"生成 GroupCharacterMemorySelection
 * - 个人记忆检索 / 所有权防御校验 / 状态过滤 / 去重 / 排序 / 数量与 Token 预算
 * - 关系记忆所有权与方向校验 / 可靠相关目标选择 / 反向关系诊断
 * - 完整记录每条记录的选择与排除原因(仅供检查器展示)
 *
 * 核心约束:
 * - 只选择 status=Active 且正文非空的个人记忆,只选择 ownerCharacterId=当前角色的关系
 * - 不选择其他角色 / 其他群聊 / Archived / 反向关系
 * - 相关角色仅来自输入中的可靠结构化 ID,不得通过显示名称猜测
 * - 无可靠目标时安全降级:只选择 owner→user
 * - 选择结果不注入最终 Prompt,不持久化
 *
 * 不负责:
 * - 向量检索 / RAG / LLM 重排序 / 分词服务 / 网络检索(本阶段明确不做)
 * - 修改数据库 / 升级 DATABASE_VERSION
 * - 调用 Provider / 改变 Provider 请求
 *
 * 日志安全:
 * - 不打印记忆正文 / 关系正文 / 关键词全文 / 完整 ID
 * - buildSafeDiagnosticSummary 仅返回计数与排除原因统计
 */

import { GroupCharacterMemoryRepository } from '../../repositories/groupchat/GroupCharacterMemoryRepository';
import { GroupCharacterRelationshipMemoryRepository } from '../../repositories/groupchat/GroupCharacterRelationshipMemoryRepository';
import {
  GroupCharacterMemory,
  GroupCharacterMemoryOrigin,
  GroupCharacterMemoryStatus
} from '../../models/groupchat/GroupCharacterMemory';
import {
  GroupCharacterRelationshipMemory,
  GroupRelationshipTargetType,
  GroupRelationshipMemoryStatus
} from '../../models/groupchat/GroupCharacterRelationshipMemory';
import { estimateTextTokens } from '../TokenCounter';
import {
  GroupCharacterMemorySelectionInput,
  GroupCharacterMemorySelection,
  SelectedPersonalMemory,
  ExcludedPersonalMemory,
  SelectedRelationshipMemory,
  ExcludedRelationshipMemory,
  GroupCharacterMemoryExclusionReason,
  GroupCharacterRelationshipExclusionReason,
  RelationshipSelectionTargetSource,
  GroupRelationshipTargetCandidate,
  GROUP_CHARACTER_PERSONAL_MEMORY_MAX_COUNT,
  GROUP_CHARACTER_RELATIONSHIP_MEMORY_MAX_COUNT,
  GROUP_CHARACTER_PERSONAL_MEMORY_TOKEN_BUDGET,
  GROUP_CHARACTER_RELATIONSHIP_MEMORY_TOKEN_BUDGET
} from '../../models/groupchat/GroupPromptInspectionModels';

/** 排序中间结构:个人记忆 */
interface RankedMemory {
  readonly memory: GroupCharacterMemory;
  readonly keywordHitCount: number;
  readonly manualPriority: boolean;
}

/** 排序中间结构:关系记忆 */
interface RankedRelationship {
  readonly memory: GroupCharacterRelationshipMemory;
  readonly relevantTarget: boolean;
  readonly userRelationship: boolean;
  /** G-CONTEXT-MEMORY-SELECTION-1B: 选择目标来源 */
  readonly source: RelationshipSelectionTargetSource;
}

export class GroupCharacterMemorySelector {
  private readonly memoryRepository: GroupCharacterMemoryRepository;
  private readonly relationshipRepository: GroupCharacterRelationshipMemoryRepository;

  constructor(
    memoryRepository: GroupCharacterMemoryRepository,
    relationshipRepository: GroupCharacterRelationshipMemoryRepository
  ) {
    this.memoryRepository = memoryRepository;
    this.relationshipRepository = relationshipRepository;
  }

  /**
   * 执行完整选择流程。
   * 输入校验失败抛错;查询失败安全降级(selected=[]),不影响生成流程。
   */
  async select(input: GroupCharacterMemorySelectionInput): Promise<GroupCharacterMemorySelection> {
    if (input.groupConversationId.trim().length === 0) {
      throw new Error('GroupCharacterMemorySelector: groupConversationId empty');
    }
    if (input.ownerCharacterId.trim().length === 0) {
      throw new Error('GroupCharacterMemorySelector: ownerCharacterId empty');
    }
    const groupId: string = input.groupConversationId;
    const ownerId: string = input.ownerCharacterId;
    const userMessage: string = input.currentUserMessage !== undefined ? input.currentUserMessage : '';
    const visibleMessageIds: string[] =
      input.visibleMessageIds !== undefined ? input.visibleMessageIds.slice() : [];
    const participantCharacterIds: string[] =
      input.participantCharacterIds !== undefined ? input.participantCharacterIds.slice() : [];
    const rawCandidates: GroupRelationshipTargetCandidate[] =
      input.relationshipTargetCandidates !== undefined
        ? input.relationshipTargetCandidates.slice() : [];
    // G-CONTEXT-MEMORY-SELECTION-1B: 只接受可靠结构化来源。
    // 候选来源为 REPLY_TARGET_DERIVED 的不得作为关系目标(仅诊断标记)。
    // 候选为空数组是正常状态(无可靠目标 → 只选 owner→user)。
    const explicitTargets: string[] = [];
    const replyTargetDerivedIds: string[] = [];
    const invalidCandidateIds: string[] = [];
    for (let i = 0; i < rawCandidates.length; i++) {
      const c: GroupRelationshipTargetCandidate = rawCandidates[i];
      const charId: string = c.characterId !== undefined ? c.characterId : '';
      if (charId.trim().length === 0 || charId === ownerId) {
        invalidCandidateIds.push(charId);
        continue;
      }
      if (c.source === RelationshipSelectionTargetSource.REPLY_TARGET_DERIVED) {
        replyTargetDerivedIds.push(charId);
        continue;
      }
      if (c.source !== RelationshipSelectionTargetSource.EXPLICIT_STRUCTURED_TARGET) {
        invalidCandidateIds.push(charId);
        continue;
      }
      if (arrayContains(participantCharacterIds, charId)) {
        explicitTargets.push(charId);
      } else {
        invalidCandidateIds.push(charId);
      }
    }
    const hasReliableTargets: boolean = explicitTargets.length > 0;
    const personalMax: number = input.personalMemoryMaxCount > 0
      ? input.personalMemoryMaxCount : GROUP_CHARACTER_PERSONAL_MEMORY_MAX_COUNT;
    const relationshipMax: number = input.relationshipMemoryMaxCount > 0
      ? input.relationshipMemoryMaxCount : GROUP_CHARACTER_RELATIONSHIP_MEMORY_MAX_COUNT;
    const personalTokenBudget: number = input.personalMemoryTokenBudget > 0
      ? input.personalMemoryTokenBudget : GROUP_CHARACTER_PERSONAL_MEMORY_TOKEN_BUDGET;
    const relationshipTokenBudget: number = input.relationshipMemoryTokenBudget > 0
      ? input.relationshipMemoryTokenBudget : GROUP_CHARACTER_RELATIONSHIP_MEMORY_TOKEN_BUDGET;
    const includeUser: boolean = input.includeUserRelationship;

    // ===== 1. 个人记忆检索与分类 =====
    let rawMemories: GroupCharacterMemory[] = [];
    let personalQueryFailed: boolean = false;
    try {
      rawMemories = await this.memoryRepository.listByCharacter(groupId, ownerId);
    } catch (e) {
      personalQueryFailed = true;
      rawMemories = [];
    }

    const allPersonal: GroupCharacterMemory[] = [];
    const excludedPersonal: ExcludedPersonalMemory[] = [];
    const eligiblePersonal: GroupCharacterMemory[] = [];
    if (!personalQueryFailed) {
      for (let i = 0; i < rawMemories.length; i++) {
        const m: GroupCharacterMemory = rawMemories[i];
        if (m.groupConversationId !== groupId) {
          excludedPersonal.push(buildExcludedPersonalMemory(
            m, GroupCharacterMemoryExclusionReason.EXCLUDED_CHAT_MISMATCH, '', 0
          ));
          continue;
        }
        if (m.characterId !== ownerId) {
          excludedPersonal.push(buildExcludedPersonalMemory(
            m, GroupCharacterMemoryExclusionReason.EXCLUDED_OWNER_MISMATCH, '', 0
          ));
          continue;
        }
        allPersonal.push(m);
        if (m.status !== GroupCharacterMemoryStatus.Active) {
          excludedPersonal.push(buildExcludedPersonalMemory(
            m, GroupCharacterMemoryExclusionReason.EXCLUDED_ARCHIVED, '', estimateMemoryTokens(m)
          ));
          continue;
        }
        if (m.content.trim().length === 0) {
          excludedPersonal.push(buildExcludedPersonalMemory(
            m, GroupCharacterMemoryExclusionReason.EXCLUDED_EMPTY_CONTENT, '', 0
          ));
          continue;
        }
        eligiblePersonal.push(m);
      }
    }

    // ===== 2. 个人记忆排序 + 去重 + 预算 =====
    const ranked: RankedMemory[] = [];
    for (let i = 0; i < eligiblePersonal.length; i++) {
      const m: GroupCharacterMemory = eligiblePersonal[i];
      ranked.push({
        memory: m,
        keywordHitCount: countKeywordHits(m.keywords, userMessage),
        manualPriority: m.origin === GroupCharacterMemoryOrigin.Manual
      });
    }
    ranked.sort(compareRankedMemory);

    const seenIds: Map<string, string> = new Map<string, string>();
    const seenHashes: Map<string, string> = new Map<string, string>();
    const seenSources: Map<string, string> = new Map<string, string>();
    const dedupedMemories: RankedMemory[] = [];
    for (let i = 0; i < ranked.length; i++) {
      const r: RankedMemory = ranked[i];
      const m: GroupCharacterMemory = r.memory;
      const duplicateOf: string = findMemoryDuplicate(m, seenIds, seenHashes, seenSources);
      if (duplicateOf.length > 0) {
        excludedPersonal.push(buildExcludedPersonalMemory(
          m, GroupCharacterMemoryExclusionReason.EXCLUDED_DUPLICATE, duplicateOf, estimateMemoryTokens(m)
        ));
        continue;
      }
      seenIds.set(m.id, m.id);
      if (m.sourceHash !== undefined && m.sourceHash.length > 0) {
        seenHashes.set(m.sourceHash, m.id);
      }
      if (m.sourceMessageId !== undefined && m.sourceMessageId.length > 0
        && m.sourceType !== undefined && m.sourceType.length > 0) {
        seenSources.set(m.sourceMessageId + '|' + m.sourceType, m.id);
      }
      dedupedMemories.push(r);
    }

    const selectedPersonal: SelectedPersonalMemory[] = [];
    let personalCumulative: number = 0;
    for (let i = 0; i < dedupedMemories.length; i++) {
      const r: RankedMemory = dedupedMemories[i];
      const tokens: number = estimateMemoryTokens(r.memory);
      if (selectedPersonal.length >= personalMax) {
        excludedPersonal.push(buildExcludedPersonalMemory(
          r.memory, GroupCharacterMemoryExclusionReason.EXCLUDED_COUNT_BUDGET, '', tokens
        ));
        continue;
      }
      if (personalCumulative + tokens > personalTokenBudget) {
        excludedPersonal.push(buildExcludedPersonalMemory(
          r.memory, GroupCharacterMemoryExclusionReason.EXCLUDED_TOKEN_BUDGET, '', tokens
        ));
        continue;
      }
      personalCumulative += tokens;
      selectedPersonal.push(buildSelectedPersonalMemory(
        r, selectedPersonal.length + 1, personalCumulative, tokens
      ));
    }

    // ===== 3. 拥有关系检索与分类 =====
    let rawOwned: GroupCharacterRelationshipMemory[] = [];
    let relationshipQueryFailed: boolean = false;
    try {
      rawOwned = await this.relationshipRepository.listByOwner(groupId, ownerId);
    } catch (e) {
      relationshipQueryFailed = true;
      rawOwned = [];
    }

    const allOwned: GroupCharacterRelationshipMemory[] = [];
    const excludedRelationships: ExcludedRelationshipMemory[] = [];
    const relationshipCandidates: GroupCharacterRelationshipMemory[] = [];
    if (!relationshipQueryFailed) {
      for (let i = 0; i < rawOwned.length; i++) {
        const rel: GroupCharacterRelationshipMemory = rawOwned[i];
        if (rel.groupConversationId !== groupId) {
          excludedRelationships.push(buildExcludedRelationship(
            rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_CHAT_MISMATCH, '', 0
          ));
          continue;
        }
        if (rel.ownerCharacterId !== ownerId) {
          excludedRelationships.push(buildExcludedRelationship(
            rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_OWNER_MISMATCH, '', 0
          ));
          continue;
        }
        allOwned.push(rel);
        if (!isValidTargetType(rel.targetType) || rel.targetId.trim().length === 0) {
          excludedRelationships.push(buildExcludedRelationship(
            rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_INVALID_TARGET, '', 0
          ));
          continue;
        }
        if (rel.targetType === GroupRelationshipTargetType.Character
          && rel.targetId === ownerId) {
          excludedRelationships.push(buildExcludedRelationship(
            rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_SELF_TARGET, '', 0
          ));
          continue;
        }
        if (rel.status !== GroupRelationshipMemoryStatus.Active) {
          excludedRelationships.push(buildExcludedRelationship(
            rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_ARCHIVED, '',
            estimateRelationshipTokens(rel)
          ));
          continue;
        }
        relationshipCandidates.push(rel);
      }
    }

    // ===== 4. 关系可选择性判定 + 排序 + 去重 + 预算 =====
    // G-CONTEXT-MEMORY-SELECTION-1B:
    // - owner→user:默认候选(includeUserRelationship=true 时)
    // - owner→character:仅当存在 EXPLICIT_STRUCTURED_TARGET 候选且目标在当前成员快照中
    // - 无可靠目标 → EXCLUDED_NO_RELIABLE_TARGET
    // - replyTarget 派生候选 → EXCLUDED_REPLY_TARGET_NOT_RELATION_TARGET
    const selectableRelationships: RankedRelationship[] = [];
    for (let i = 0; i < relationshipCandidates.length; i++) {
      const rel: GroupCharacterRelationshipMemory = relationshipCandidates[i];
      const isCharacterRel: boolean = rel.targetType === GroupRelationshipTargetType.Character;
      const isUserRel: boolean = rel.targetType === GroupRelationshipTargetType.User;
      if (isUserRel && !includeUser) {
        excludedRelationships.push(buildExcludedRelationship(
          rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_UNRELATED_TARGET, '',
          estimateRelationshipTokens(rel)
        ));
        continue;
      }
      if (isUserRel) {
        selectableRelationships.push({
          memory: rel,
          relevantTarget: false,
          userRelationship: true,
          source: RelationshipSelectionTargetSource.USER_RELATION_DEFAULT
        });
        continue;
      }
      // 角色关系:必须命中可靠结构化候选
      if (arrayContains(invalidCandidateIds, rel.targetId)) {
        excludedRelationships.push(buildExcludedRelationship(
          rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_INVALID_TARGET, '',
          estimateRelationshipTokens(rel)
        ));
        continue;
      }
      if (arrayContains(explicitTargets, rel.targetId)) {
        selectableRelationships.push({
          memory: rel,
          relevantTarget: true,
          userRelationship: false,
          source: RelationshipSelectionTargetSource.EXPLICIT_STRUCTURED_TARGET
        });
        continue;
      }
      if (arrayContains(replyTargetDerivedIds, rel.targetId)) {
        excludedRelationships.push(buildExcludedRelationship(
          rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_REPLY_TARGET_NOT_RELATION_TARGET, '',
          estimateRelationshipTokens(rel)
        ));
        continue;
      }
      if (!hasReliableTargets) {
        excludedRelationships.push(buildExcludedRelationship(
          rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET, '',
          estimateRelationshipTokens(rel)
        ));
        continue;
      }
      excludedRelationships.push(buildExcludedRelationship(
        rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_UNRELATED_TARGET, '',
        estimateRelationshipTokens(rel)
      ));
    }
    selectableRelationships.sort(compareRankedRelationship);

    const relSeenIds: Map<string, string> = new Map<string, string>();
    const relSeenHashes: Map<string, string> = new Map<string, string>();
    const dedupedRelationships: RankedRelationship[] = [];
    for (let i = 0; i < selectableRelationships.length; i++) {
      const r: RankedRelationship = selectableRelationships[i];
      const rel: GroupCharacterRelationshipMemory = r.memory;
      const duplicateOf: string = findRelationshipDuplicate(rel, relSeenIds, relSeenHashes);
      if (duplicateOf.length > 0) {
        excludedRelationships.push(buildExcludedRelationship(
          rel, GroupCharacterRelationshipExclusionReason.EXCLUDED_DUPLICATE, duplicateOf,
          estimateRelationshipTokens(rel)
        ));
        continue;
      }
      relSeenIds.set(rel.id, rel.id);
      if (rel.sourceHash.length > 0) {
        relSeenHashes.set(rel.sourceHash, rel.id);
      }
      dedupedRelationships.push(r);
    }

    const selectedRelationships: SelectedRelationshipMemory[] = [];
    let relationshipCumulative: number = 0;
    for (let i = 0; i < dedupedRelationships.length; i++) {
      const r: RankedRelationship = dedupedRelationships[i];
      const tokens: number = estimateRelationshipTokens(r.memory);
      if (selectedRelationships.length >= relationshipMax) {
        excludedRelationships.push(buildExcludedRelationship(
          r.memory, GroupCharacterRelationshipExclusionReason.EXCLUDED_COUNT_BUDGET, '', tokens
        ));
        continue;
      }
      if (relationshipCumulative + tokens > relationshipTokenBudget) {
        excludedRelationships.push(buildExcludedRelationship(
          r.memory, GroupCharacterRelationshipExclusionReason.EXCLUDED_TOKEN_BUDGET, '', tokens
        ));
        continue;
      }
      relationshipCumulative += tokens;
      selectedRelationships.push(buildSelectedRelationship(
        r, selectedRelationships.length + 1, relationshipCumulative, tokens
      ));
    }

    // ===== 5. 反向关系查询(仅诊断) =====
    let reverseRelationships: GroupCharacterRelationshipMemory[] = [];
    let reverseQueryFailed: boolean = false;
    try {
      const rawReverse: GroupCharacterRelationshipMemory[] =
        await this.relationshipRepository.listByTarget(groupId, ownerId);
      for (let i = 0; i < rawReverse.length; i++) {
        const rel: GroupCharacterRelationshipMemory = rawReverse[i];
        if (rel.groupConversationId === groupId
          && rel.targetType === GroupRelationshipTargetType.Character
          && rel.targetId === ownerId) {
          reverseRelationships.push(rel);
        }
      }
    } catch (e) {
      reverseQueryFailed = true;
      reverseRelationships = [];
    }

    // ===== 6. 汇总结果 =====
    const result: GroupCharacterMemorySelection = {
      groupConversationId: groupId,
      ownerCharacterId: ownerId,
      allPersonalMemories: allPersonal,
      eligiblePersonalMemories: eligiblePersonal,
      selectedPersonalMemories: selectedPersonal,
      excludedPersonalMemories: excludedPersonal,
      allOwnedRelationships: allOwned,
      selectedRelationships: selectedRelationships,
      excludedRelationships: excludedRelationships,
      reverseRelationships: reverseRelationships,
      personalEstimatedTokens: personalCumulative,
      relationshipEstimatedTokens: relationshipCumulative,
      personalQueryFailed: personalQueryFailed,
      relationshipQueryFailed: relationshipQueryFailed,
      reverseQueryFailed: reverseQueryFailed,
      createdAt: Date.now()
    };
    return result;
  }

  /**
   * 安全诊断摘要(仅计数与排除原因统计)。
   * 不包含记忆正文 / 关系正文 / 关键词全文 / 完整 ID。
   */
  static buildSafeDiagnosticSummary(selection: GroupCharacterMemorySelection): string {
    const counts: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < selection.excludedPersonalMemories.length; i++) {
      const key: string = selection.excludedPersonalMemories[i].reason;
      const existing: number | undefined = counts.get(key);
      counts.set(key, existing !== undefined ? existing + 1 : 1);
    }
    for (let i = 0; i < selection.excludedRelationships.length; i++) {
      const key: string = selection.excludedRelationships[i].reason;
      const existing: number | undefined = counts.get(key);
      counts.set(key, existing !== undefined ? existing + 1 : 1);
    }
    const reasonParts: string[] = [];
    const keys: string[] = Array.from(counts.keys());
    keys.sort();
    for (let i = 0; i < keys.length; i++) {
      reasonParts.push(keys[i] + '=' + String(counts.get(keys[i])));
    }
    return 'allPersonal=' + String(selection.allPersonalMemories.length)
      + ',eligiblePersonal=' + String(selection.eligiblePersonalMemories.length)
      + ',selectedPersonal=' + String(selection.selectedPersonalMemories.length)
      + ',allRelationships=' + String(selection.allOwnedRelationships.length)
      + ',selectedRelationships=' + String(selection.selectedRelationships.length)
      + ',reverseRelationships=' + String(selection.reverseRelationships.length)
      + ',personalTokens=' + String(selection.personalEstimatedTokens)
      + ',relationshipTokens=' + String(selection.relationshipEstimatedTokens)
      + ',reasons=[' + reasonParts.join(',') + ']';
  }
}

// ===== 个人记忆排序比较器(确定性规则,无向量检索) =====
// 顺序:1. Manual 优先 2. 关键词命中更多 3. importance 更高 4. updatedAt 更新 5. id 稳定
function compareRankedMemory(a: RankedMemory, b: RankedMemory): number {
  if (a.manualPriority !== b.manualPriority) {
    return a.manualPriority ? -1 : 1;
  }
  if (a.keywordHitCount !== b.keywordHitCount) {
    return b.keywordHitCount - a.keywordHitCount;
  }
  if (a.memory.importance !== b.memory.importance) {
    return b.memory.importance - a.memory.importance;
  }
  if (a.memory.updatedAt !== b.memory.updatedAt) {
    return a.memory.updatedAt < b.memory.updatedAt ? 1 : -1;
  }
  if (a.memory.id < b.memory.id) {
    return -1;
  }
  if (a.memory.id > b.memory.id) {
    return 1;
  }
  return 0;
}

// ===== 关系记忆排序比较器 =====
// 顺序:1. 明确相关角色关系 2. owner→user 3. importance 更高 4. updatedAt 更新 5. id 稳定
function compareRankedRelationship(a: RankedRelationship, b: RankedRelationship): number {
  if (a.relevantTarget !== b.relevantTarget) {
    return a.relevantTarget ? -1 : 1;
  }
  if (a.userRelationship !== b.userRelationship) {
    return a.userRelationship ? -1 : 1;
  }
  if (a.memory.importance !== b.memory.importance) {
    return b.memory.importance - a.memory.importance;
  }
  if (a.memory.updatedAt !== b.memory.updatedAt) {
    return a.memory.updatedAt < b.memory.updatedAt ? 1 : -1;
  }
  if (a.memory.id < b.memory.id) {
    return -1;
  }
  if (a.memory.id > b.memory.id) {
    return 1;
  }
  return 0;
}

// ===== 去重 =====

function findMemoryDuplicate(
  m: GroupCharacterMemory,
  seenIds: Map<string, string>,
  seenHashes: Map<string, string>,
  seenSources: Map<string, string>
): string {
  const byId: string | undefined = seenIds.get(m.id);
  if (byId !== undefined) {
    return byId;
  }
  if (m.sourceHash !== undefined && m.sourceHash.length > 0) {
    const byHash: string | undefined = seenHashes.get(m.sourceHash);
    if (byHash !== undefined) {
      return byHash;
    }
  }
  if (m.sourceMessageId !== undefined && m.sourceMessageId.length > 0
    && m.sourceType !== undefined && m.sourceType.length > 0) {
    const key: string = m.sourceMessageId + '|' + m.sourceType;
    const bySource: string | undefined = seenSources.get(key);
    if (bySource !== undefined) {
      return bySource;
    }
  }
  return '';
}

function findRelationshipDuplicate(
  rel: GroupCharacterRelationshipMemory,
  seenIds: Map<string, string>,
  seenHashes: Map<string, string>
): string {
  const byId: string | undefined = seenIds.get(rel.id);
  if (byId !== undefined) {
    return byId;
  }
  if (rel.sourceHash.length > 0) {
    const byHash: string | undefined = seenHashes.get(rel.sourceHash);
    if (byHash !== undefined) {
      return byHash;
    }
  }
  return '';
}

// ===== 关键词匹配(确定性,简单子串) =====

function countKeywordHits(keywords: string[], userMessage: string): number {
  if (userMessage.length === 0 || keywords.length === 0) {
    return 0;
  }
  const needle: string = userMessage.toLowerCase();
  let hits: number = 0;
  for (let i = 0; i < keywords.length; i++) {
    const kw: string = keywords[i].trim().toLowerCase();
    if (kw.length === 0) {
      continue;
    }
    if (needle.indexOf(kw) >= 0) {
      hits++;
    }
  }
  return hits;
}

// ===== Token 估算(保守估算值,非精确 tokenizer) =====

function estimateMemoryTokens(m: GroupCharacterMemory): number {
  return estimateTextTokens(m.title) + estimateTextTokens(m.content) + 4;
}

function estimateRelationshipTokens(rel: GroupCharacterRelationshipMemory): number {
  return estimateTextTokens(rel.experienceSummary)
    + estimateTextTokens(rel.attitudeSummary)
    + estimateTextTokens(rel.relationshipSummary) + 8;
}

// ===== 工具函数 =====

function isValidTargetType(targetType: GroupRelationshipTargetType): boolean {
  return targetType === GroupRelationshipTargetType.User
    || targetType === GroupRelationshipTargetType.Character;
}

function arrayContains(list: string[], value: string): boolean {
  for (let i = 0; i < list.length; i++) {
    if (list[i] === value) {
      return true;
    }
  }
  return false;
}

// ===== 结果构建 =====

function buildSelectedPersonalMemory(
  r: RankedMemory,
  finalRank: number,
  cumulativeTokens: number,
  estimatedTokens: number
): SelectedPersonalMemory {
  const tags: string[] = [];
  if (r.manualPriority) {
    tags.push('manual');
  }
  if (r.keywordHitCount > 0) {
    tags.push('keyword:' + r.keywordHitCount.toString());
  }
  tags.push('importance:' + r.memory.importance.toString());
  const item: SelectedPersonalMemory = {
    memory: r.memory,
    finalRank: finalRank,
    selectionReason: tags.join(','),
    manualPriority: r.manualPriority,
    keywordHitCount: r.keywordHitCount,
    estimatedTokens: estimatedTokens,
    cumulativeTokens: cumulativeTokens
  };
  return item;
}

function buildExcludedPersonalMemory(
  m: GroupCharacterMemory,
  reason: GroupCharacterMemoryExclusionReason,
  duplicateOfMemoryId: string,
  estimatedTokens: number
): ExcludedPersonalMemory {
  const item: ExcludedPersonalMemory = {
    memory: m,
    reason: reason,
    duplicateOfMemoryId: duplicateOfMemoryId,
    estimatedTokens: estimatedTokens
  };
  return item;
}

function buildSelectedRelationship(
  r: RankedRelationship,
  finalRank: number,
  cumulativeTokens: number,
  estimatedTokens: number
): SelectedRelationshipMemory {
  const tags: string[] = [];
  if (r.relevantTarget) {
    tags.push('related_target');
  }
  if (r.userRelationship) {
    tags.push('owner_user');
  }
  tags.push('importance:' + r.memory.importance.toString());
  const item: SelectedRelationshipMemory = {
    memory: r.memory,
    finalRank: finalRank,
    selectionReason: tags.join(','),
    source: r.source,
    estimatedTokens: estimatedTokens,
    cumulativeTokens: cumulativeTokens
  };
  return item;
}

function buildExcludedRelationship(
  rel: GroupCharacterRelationshipMemory,
  reason: GroupCharacterRelationshipExclusionReason,
  duplicateOfId: string,
  estimatedTokens: number
): ExcludedRelationshipMemory {
  const item: ExcludedRelationshipMemory = {
    memory: rel,
    reason: reason,
    duplicateOfId: duplicateOfId,
    estimatedTokens: estimatedTokens
  };
  return item;
}
