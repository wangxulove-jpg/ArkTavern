/**
 * GroupCharacterMemorySelector 本地单元测试(MEMSEL-01 ~ MEMSEL-26)
 *
 * 覆盖群聊角色个人记忆与方向关系的隔离检索、筛选、排序、去重与预算。
 * 使用真实 GroupCharacterMemorySelector + Fake 内存 Repository(继承真实 Repository,
 * 仅替换查询方法,不复制生产算法)。
 *
 * 核心断言:
 * - 只选择当前群聊 + 当前角色的 Active 非空记忆
 * - 跨角色 / 跨群聊 / 反向关系不进入选择
 * - 排序:Manual > 关键词命中 > importance > updatedAt > id
 * - 去重:id / sourceHash / sourceMessageId+sourceType
 * - 数量与 Token 预算;查询失败安全降级
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupCharacterMemorySelector } from '../main/ets/services/groupchat/GroupCharacterMemorySelector';
import { GroupCharacterMemoryRepository } from '../main/ets/repositories/groupchat/GroupCharacterMemoryRepository';
import { GroupCharacterRelationshipMemoryRepository } from '../main/ets/repositories/groupchat/GroupCharacterRelationshipMemoryRepository';
import { DbHelper } from '../main/ets/database/DbHelper';
import {
  GroupCharacterMemory,
  GroupCharacterMemoryOrigin,
  GroupCharacterMemoryStatus,
  createGroupCharacterMemoryRecord
} from '../main/ets/models/groupchat/GroupCharacterMemory';
import {
  GroupCharacterRelationshipMemory,
  GroupRelationshipTargetType,
  GroupRelationshipMemoryStatus,
  createGroupCharacterRelationshipMemoryRecord
} from '../main/ets/models/groupchat/GroupCharacterRelationshipMemory';
import {
  GroupCharacterMemorySelectionInput,
  GroupCharacterMemorySelection,
  GroupCharacterMemoryExclusionReason,
  GroupCharacterRelationshipExclusionReason,
  RelationshipSelectionTargetSource,
  GroupRelationshipTargetCandidate
} from '../main/ets/models/groupchat/GroupPromptInspectionModels';

const CHAT_1: string = 'chat-1';
const CHAT_2: string = 'chat-2';
const CHAR_A: string = 'char-a';
const CHAR_B: string = 'char-b';
const CHAR_C: string = 'char-c';

const SOURCE_TYPE_SELF_SUMMARY_V1: string = 'self_summary_v1';

// ===== Fake Repository(内存,继承真实 Repository 以匹配类型) =====

class FakeMemoryRepo extends GroupCharacterMemoryRepository {
  private items: GroupCharacterMemory[] = [];
  failQuery: boolean = false;
  /** 模拟 Repository 返回错误 owner / 其他群聊记录(防御测试用) */
  bypassFilter: boolean = false;

  constructor() {
    super(new DbHelper('mem-sel-selector-test'));
  }

  setMemories(items: GroupCharacterMemory[]): void {
    this.items = items.slice();
  }

  setFailQuery(fail: boolean): void {
    this.failQuery = fail;
  }

  async listByCharacter(
    groupConversationId: string,
    characterId: string
  ): Promise<GroupCharacterMemory[]> {
    if (this.failQuery) {
      throw new Error('mock listByCharacter failed');
    }
    const result: GroupCharacterMemory[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const m = this.items[i];
      if (this.bypassFilter
        || (m.groupConversationId === groupConversationId && m.characterId === characterId)) {
        result.push(m);
      }
    }
    return result;
  }
}

class FakeRelationshipRepo extends GroupCharacterRelationshipMemoryRepository {
  private items: GroupCharacterRelationshipMemory[] = [];
  failOwnerQuery: boolean = false;
  failTargetQuery: boolean = false;

  constructor() {
    super(new DbHelper('mem-sel-selector-test'));
  }

  setRelationships(items: GroupCharacterRelationshipMemory[]): void {
    this.items = items.slice();
  }

  setFailOwnerQuery(fail: boolean): void {
    this.failOwnerQuery = fail;
  }

  setFailTargetQuery(fail: boolean): void {
    this.failTargetQuery = fail;
  }

  async listByOwner(
    groupConversationId: string,
    ownerCharacterId: string
  ): Promise<GroupCharacterRelationshipMemory[]> {
    if (this.failOwnerQuery) {
      throw new Error('mock listByOwner failed');
    }
    const result: GroupCharacterRelationshipMemory[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const r = this.items[i];
      if (r.groupConversationId === groupConversationId && r.ownerCharacterId === ownerCharacterId) {
        result.push(r);
      }
    }
    return result;
  }

  async listByTarget(
    groupConversationId: string,
    targetCharacterId: string
  ): Promise<GroupCharacterRelationshipMemory[]> {
    if (this.failTargetQuery) {
      throw new Error('mock listByTarget failed');
    }
    const result: GroupCharacterRelationshipMemory[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const r = this.items[i];
      if (r.groupConversationId === groupConversationId
        && r.targetType === GroupRelationshipTargetType.Character
        && r.targetId === targetCharacterId) {
        result.push(r);
      }
    }
    return result;
  }
}

interface SelTestContext {
  selector: GroupCharacterMemorySelector;
  memoryRepo: FakeMemoryRepo;
  relRepo: FakeRelationshipRepo;
}

function setup(): SelTestContext {
  const memoryRepo: FakeMemoryRepo = new FakeMemoryRepo();
  const relRepo: FakeRelationshipRepo = new FakeRelationshipRepo();
  const selector: GroupCharacterMemorySelector = new GroupCharacterMemorySelector(
    memoryRepo, relRepo
  );
  return { selector: selector, memoryRepo: memoryRepo, relRepo: relRepo };
}

function makeInput(
  groupId: string,
  ownerId: string,
  userMessage: string = '',
  candidates: GroupRelationshipTargetCandidate[] = [],
  includeUser: boolean = true,
  personalMax: number = 5,
  relMax: number = 3,
  personalTokens: number = 600,
  relTokens: number = 400,
  participantIds: string[] = [CHAR_A, CHAR_B, CHAR_C]
): GroupCharacterMemorySelectionInput {
  return {
    groupConversationId: groupId,
    ownerCharacterId: ownerId,
    currentUserMessage: userMessage,
    visibleMessageIds: [],
    participantCharacterIds: participantIds,
    relationshipTargetCandidates: candidates,
    includeUserRelationship: includeUser,
    personalMemoryMaxCount: personalMax,
    relationshipMemoryMaxCount: relMax,
    personalMemoryTokenBudget: personalTokens,
    relationshipMemoryTokenBudget: relTokens
  };
}

function explicitCandidate(charId: string): GroupRelationshipTargetCandidate {
  return { characterId: charId, source: RelationshipSelectionTargetSource.EXPLICIT_STRUCTURED_TARGET };
}

function replyDerivedCandidate(charId: string): GroupRelationshipTargetCandidate {
  return { characterId: charId, source: RelationshipSelectionTargetSource.REPLY_TARGET_DERIVED };
}

function makeMemory(
  id: string,
  groupId: string,
  characterId: string,
  title: string,
  content: string,
  importance: number = 3,
  origin: GroupCharacterMemoryOrigin = GroupCharacterMemoryOrigin.Manual,
  status: GroupCharacterMemoryStatus = GroupCharacterMemoryStatus.Active,
  keywords: string[] = [],
  sourceHash?: string,
  sourceMessageId?: string,
  sourceType?: string,
  updatedAt: number = 1000
): GroupCharacterMemory {
  return createGroupCharacterMemoryRecord({
    id: id,
    groupConversationId: groupId,
    characterId: characterId,
    origin: origin,
    status: status,
    title: title,
    content: content,
    importance: importance,
    keywords: keywords,
    sourceHash: sourceHash,
    sourceMessageId: sourceMessageId,
    sourceType: sourceType,
    createdAt: 900,
    updatedAt: updatedAt
  });
}

function makeSelfSummaryMemory(
  id: string,
  groupId: string,
  characterId: string,
  title: string,
  content: string,
  importance: number = 3,
  status: GroupCharacterMemoryStatus = GroupCharacterMemoryStatus.Active
): GroupCharacterMemory {
  return makeMemory(id, groupId, characterId, title, content, importance,
    GroupCharacterMemoryOrigin.Interaction, status, [], undefined, 'sm-' + id,
    SOURCE_TYPE_SELF_SUMMARY_V1);
}

/** 原始对象构造(用于空正文 / 错误 owner 等无法通过工厂构造的边界场景) */
function makeRawMemoryRecord(
  id: string,
  groupId: string,
  characterId: string,
  content: string,
  status: GroupCharacterMemoryStatus = GroupCharacterMemoryStatus.Active
): GroupCharacterMemory {
  const m: GroupCharacterMemory = {
    id: id,
    groupConversationId: groupId,
    characterId: characterId,
    origin: GroupCharacterMemoryOrigin.Manual,
    status: status,
    title: 't-' + id,
    content: content,
    importance: 3,
    keywords: [],
    createdAt: 900,
    updatedAt: 1000
  };
  return m;
}

function makeRelationship(
  id: string,
  groupId: string,
  ownerId: string,
  targetType: GroupRelationshipTargetType,
  targetId: string,
  status: GroupRelationshipMemoryStatus = GroupRelationshipMemoryStatus.Active,
  importance: number = 3,
  updatedAt: number = 1000
): GroupCharacterRelationshipMemory {
  return createGroupCharacterRelationshipMemoryRecord({
    id: id,
    groupConversationId: groupId,
    ownerCharacterId: ownerId,
    targetType: targetType,
    targetId: targetId,
    experienceSummary: 'exp-' + targetId,
    attitudeSummary: 'att-' + targetId,
    relationshipSummary: 'rel-' + targetId,
    importance: importance,
    keywords: [],
    sourceMessageIds: ['sm-1'],
    sourceHash: 'hash-' + id,
    status: status,
    createdAt: 900,
    updatedAt: updatedAt
  });
}

/** A→user 关系 */
function makeUserRel(id: string, groupId: string, ownerId: string,
  status: GroupRelationshipMemoryStatus = GroupRelationshipMemoryStatus.Active): GroupCharacterRelationshipMemory {
  return makeRelationship(id, groupId, ownerId, GroupRelationshipTargetType.User, 'user', status);
}

function selectedIds(sel: GroupCharacterMemorySelection): string[] {
  const ids: string[] = [];
  for (let i = 0; i < sel.selectedPersonalMemories.length; i++) {
    ids.push(sel.selectedPersonalMemories[i].memory.id);
  }
  return ids;
}

function excludedReasonMap(sel: GroupCharacterMemorySelection): Map<string, string> {
  const map: Map<string, string> = new Map<string, string>();
  for (let i = 0; i < sel.excludedPersonalMemories.length; i++) {
    map.set(sel.excludedPersonalMemories[i].memory.id, sel.excludedPersonalMemories[i].reason);
  }
  return map;
}

function selectedRelIds(sel: GroupCharacterMemorySelection): string[] {
  const ids: string[] = [];
  for (let i = 0; i < sel.selectedRelationships.length; i++) {
    ids.push(sel.selectedRelationships[i].memory.id);
  }
  return ids;
}

function excludedRelReasonMap(sel: GroupCharacterMemorySelection): Map<string, string> {
  const map: Map<string, string> = new Map<string, string>();
  for (let i = 0; i < sel.excludedRelationships.length; i++) {
    map.set(sel.excludedRelationships[i].memory.id, sel.excludedRelationships[i].reason);
  }
  return map;
}

function containsId(ids: string[], id: string): boolean {
  for (let i = 0; i < ids.length; i++) {
    if (ids[i] === id) {
      return true;
    }
  }
  return false;
}

export default function groupCharacterMemorySelectorTest() {
  describe('GroupCharacterMemorySelectorTest', () => {

    it('MEMSEL_01_current_character_full_list', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('m1', CHAT_1, CHAR_A, 'm1', 'manual active', 3),
        makeMemory('m2', CHAT_1, CHAR_A, 'm2', 'manual archived', 3,
          GroupCharacterMemoryOrigin.Manual, GroupCharacterMemoryStatus.Archived),
        makeSelfSummaryMemory('m3', CHAT_1, CHAR_A, 'm3', 'summary active', 3),
        makeSelfSummaryMemory('m4', CHAT_1, CHAR_A, 'm4', 'summary archived', 3,
          GroupCharacterMemoryStatus.Archived)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      // A 的全部列表包含 Active/Archived Manual 与 self_summary_v1
      expect(sel.allPersonalMemories.length).assertEqual(4);
      let hasActiveManual: boolean = false;
      let hasArchivedManual: boolean = false;
      let hasActiveSummary: boolean = false;
      let hasArchivedSummary: boolean = false;
      for (let i = 0; i < sel.allPersonalMemories.length; i++) {
        const m = sel.allPersonalMemories[i];
        if (m.origin === GroupCharacterMemoryOrigin.Manual
          && m.status === GroupCharacterMemoryStatus.Active) {
          hasActiveManual = true;
        }
        if (m.origin === GroupCharacterMemoryOrigin.Manual
          && m.status === GroupCharacterMemoryStatus.Archived) {
          hasArchivedManual = true;
        }
        if (m.origin === GroupCharacterMemoryOrigin.Interaction
          && m.sourceType === SOURCE_TYPE_SELF_SUMMARY_V1
          && m.status === GroupCharacterMemoryStatus.Active) {
          hasActiveSummary = true;
        }
        if (m.origin === GroupCharacterMemoryOrigin.Interaction
          && m.sourceType === SOURCE_TYPE_SELF_SUMMARY_V1
          && m.status === GroupCharacterMemoryStatus.Archived) {
          hasArchivedSummary = true;
        }
      }
      expect(hasActiveManual).assertTrue();
      expect(hasArchivedManual).assertTrue();
      expect(hasActiveSummary).assertTrue();
      expect(hasArchivedSummary).assertTrue();
    });

    it('MEMSEL_02_only_active_selected', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('m1', CHAT_1, CHAR_A, 'm1', 'active', 3),
        makeMemory('m2', CHAT_1, CHAR_A, 'm2', 'archived', 3,
          GroupCharacterMemoryOrigin.Manual, GroupCharacterMemoryStatus.Archived)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.selectedPersonalMemories.length).assertEqual(1);
      expect(sel.selectedPersonalMemories[0].memory.id).assertEqual('m1');
      const reasons: Map<string, string> = excludedReasonMap(sel);
      expect(reasons.get('m2')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_ARCHIVED);
    });

    it('MEMSEL_03_cross_character_isolation', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('ma', CHAT_1, CHAR_A, 'ma', 'a memory', 3),
        makeMemory('mb', CHAT_1, CHAR_B, 'mb', 'b memory', 3)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.allPersonalMemories.length).assertEqual(1);
      expect(sel.allPersonalMemories[0].characterId).assertEqual(CHAR_A);
      expect(containsId(selectedIds(sel), 'mb')).assertFalse();
    });

    it('MEMSEL_04_cross_chat_isolation', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('m1', CHAT_1, CHAR_A, 'm1', 'chat1 memory', 3),
        makeMemory('m2', CHAT_2, CHAR_A, 'm2', 'chat2 memory', 3)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.allPersonalMemories.length).assertEqual(1);
      expect(containsId(selectedIds(sel), 'm2')).assertFalse();
    });

    it('MEMSEL_05_ownership_defense', 0, async () => {
      const ctx = setup();
      // Repository 返回错误 owner 的记录(防御场景),选择层必须排除
      ctx.memoryRepo.bypassFilter = true;
      ctx.memoryRepo.setMemories([
        makeMemory('m1', CHAT_1, CHAR_A, 'm1', 'a memory', 3),
        makeRawMemoryRecord('m2', CHAT_1, CHAR_B, 'b memory')
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.allPersonalMemories.length).assertEqual(1);
      const reasons: Map<string, string> = excludedReasonMap(sel);
      expect(reasons.get('m2')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_OWNER_MISMATCH);
      expect(containsId(selectedIds(sel), 'm2')).assertFalse();
    });

    it('MEMSEL_06_empty_content_excluded', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeRawMemoryRecord('m-empty-1', CHAT_1, CHAR_A, ''),
        makeRawMemoryRecord('m-empty-2', CHAT_1, CHAR_A, '   '),
        makeRawMemoryRecord('m-empty-3', CHAT_1, CHAR_A, '\n\n'),
        makeMemory('m-ok', CHAT_1, CHAR_A, 'm-ok', 'content ok', 3)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(containsId(selectedIds(sel), 'm-empty-1')).assertFalse();
      expect(containsId(selectedIds(sel), 'm-empty-2')).assertFalse();
      expect(containsId(selectedIds(sel), 'm-empty-3')).assertFalse();
      const reasons: Map<string, string> = excludedReasonMap(sel);
      expect(reasons.get('m-empty-1')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_EMPTY_CONTENT);
      expect(reasons.get('m-empty-2')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_EMPTY_CONTENT);
      expect(reasons.get('m-empty-3')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_EMPTY_CONTENT);
      expect(containsId(selectedIds(sel), 'm-ok')).assertTrue();
    });

    it('MEMSEL_07_manual_before_auto_summary', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeSelfSummaryMemory('m-summary', CHAT_1, CHAR_A, 'm-summary', 'auto summary', 5),
        makeMemory('m-manual', CHAT_1, CHAR_A, 'm-manual', 'manual memory', 5)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.selectedPersonalMemories.length).assertEqual(2);
      expect(sel.selectedPersonalMemories[0].memory.id).assertEqual('m-manual');
      expect(sel.selectedPersonalMemories[0].manualPriority).assertTrue();
    });

    it('MEMSEL_08_keyword_hit_raises_rank', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('m-plain', CHAT_1, CHAR_A, 'm-plain', 'plain memory', 3,
          GroupCharacterMemoryOrigin.Manual, GroupCharacterMemoryStatus.Active, ['无关']),
        makeMemory('m-hit', CHAT_1, CHAR_A, 'm-hit', 'hit memory', 3,
          GroupCharacterMemoryOrigin.Manual, GroupCharacterMemoryStatus.Active, ['苹果'])
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '今天想吃苹果'));
      expect(sel.selectedPersonalMemories.length).assertEqual(2);
      expect(sel.selectedPersonalMemories[0].memory.id).assertEqual('m-hit');
      expect(sel.selectedPersonalMemories[0].keywordHitCount).assertEqual(1);
    });

    it('MEMSEL_09_importance_sort', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('m-low', CHAT_1, CHAR_A, 'm-low', 'low importance', 1),
        makeMemory('m-high', CHAT_1, CHAR_A, 'm-high', 'high importance', 5)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.selectedPersonalMemories[0].memory.id).assertEqual('m-high');
      expect(sel.selectedPersonalMemories[1].memory.id).assertEqual('m-low');
    });

    it('MEMSEL_10_updated_at_sort', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('m-old', CHAT_1, CHAR_A, 'm-old', 'old', 3,
          GroupCharacterMemoryOrigin.Manual, GroupCharacterMemoryStatus.Active, [], undefined, undefined,
          undefined, 1000),
        makeMemory('m-new', CHAT_1, CHAR_A, 'm-new', 'new', 3,
          GroupCharacterMemoryOrigin.Manual, GroupCharacterMemoryStatus.Active, [], undefined, undefined,
          undefined, 2000)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.selectedPersonalMemories[0].memory.id).assertEqual('m-new');
      expect(sel.selectedPersonalMemories[1].memory.id).assertEqual('m-old');
    });

    it('MEMSEL_11_id_stable_sort', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-b', CHAT_1, CHAR_A, 'mem-b', 'b', 3),
        makeMemory('mem-a', CHAT_1, CHAR_A, 'mem-a', 'a', 3),
        makeMemory('mem-c', CHAT_1, CHAR_A, 'mem-c', 'c', 3)
      ]);
      const first: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      const second: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      const ids1: string[] = selectedIds(first);
      const ids2: string[] = selectedIds(second);
      expect(ids1[0]).assertEqual('mem-a');
      expect(ids1[1]).assertEqual('mem-b');
      expect(ids1[2]).assertEqual('mem-c');
      expect(ids1[0]).assertEqual(ids2[0]);
      expect(ids1[1]).assertEqual(ids2[1]);
      expect(ids1[2]).assertEqual(ids2[2]);
    });

    it('MEMSEL_12_duplicate_id_dedup', 0, async () => {
      const ctx = setup();
      const dup1: GroupCharacterMemory =
        makeMemory('m-dup', CHAT_1, CHAR_A, 'm-dup', 'first', 5);
      const dup2: GroupCharacterMemory =
        makeMemory('m-dup', CHAT_1, CHAR_A, 'm-dup', 'second', 1);
      ctx.memoryRepo.setMemories([dup1, dup2]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.selectedPersonalMemories.length).assertEqual(1);
      const reasons: Map<string, string> = excludedReasonMap(sel);
      expect(reasons.get('m-dup')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_DUPLICATE);
    });

    it('MEMSEL_13_source_hash_dedup', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('m-h1', CHAT_1, CHAR_A, 'm-h1', 'high', 5,
          GroupCharacterMemoryOrigin.Manual, GroupCharacterMemoryStatus.Active, [], 'HASH-1'),
        makeMemory('m-h2', CHAT_1, CHAR_A, 'm-h2', 'low', 1,
          GroupCharacterMemoryOrigin.Manual, GroupCharacterMemoryStatus.Active, [], 'HASH-1')
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.selectedPersonalMemories.length).assertEqual(1);
      expect(sel.selectedPersonalMemories[0].memory.id).assertEqual('m-h1');
      const reasons: Map<string, string> = excludedReasonMap(sel);
      expect(reasons.get('m-h2')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_DUPLICATE);
      // duplicateOfMemoryId 指向保留的记录
      for (let i = 0; i < sel.excludedPersonalMemories.length; i++) {
        if (sel.excludedPersonalMemories[i].memory.id === 'm-h2') {
          expect(sel.excludedPersonalMemories[i].duplicateOfMemoryId).assertEqual('m-h1');
        }
      }
    });

    it('MEMSEL_14_source_message_dedup', 0, async () => {
      const ctx = setup();
      // 两条 self_summary_v1 记忆 sourceMessageId + sourceType 相同 → 去重
      const m1: GroupCharacterMemory = makeSelfSummaryMemory(
        'm-s1', CHAT_1, CHAR_A, 'm-s1', 'high summary', 5
      );
      const m2: GroupCharacterMemory = makeSelfSummaryMemory(
        'm-s2', CHAT_1, CHAR_A, 'm-s2', 'low summary', 1
      );
      const rebuiltM1: GroupCharacterMemory = {
        id: m1.id,
        groupConversationId: m1.groupConversationId,
        characterId: m1.characterId,
        origin: m1.origin,
        status: m1.status,
        title: m1.title,
        content: m1.content,
        importance: m1.importance,
        keywords: m1.keywords,
        sourceMessageId: 'sm-shared',
        sourceType: SOURCE_TYPE_SELF_SUMMARY_V1,
        sourceHash: m1.sourceHash,
        createdAt: m1.createdAt,
        updatedAt: m1.updatedAt
      };
      const rebuiltM2: GroupCharacterMemory = {
        id: m2.id,
        groupConversationId: m2.groupConversationId,
        characterId: m2.characterId,
        origin: m2.origin,
        status: m2.status,
        title: m2.title,
        content: m2.content,
        importance: m2.importance,
        keywords: m2.keywords,
        sourceMessageId: 'sm-shared',
        sourceType: SOURCE_TYPE_SELF_SUMMARY_V1,
        sourceHash: m2.sourceHash,
        createdAt: m2.createdAt,
        updatedAt: m2.updatedAt
      };
      ctx.memoryRepo.setMemories([rebuiltM1, rebuiltM2]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.selectedPersonalMemories.length).assertEqual(1);
      expect(sel.selectedPersonalMemories[0].memory.id).assertEqual('m-s1');
      const reasons: Map<string, string> = excludedReasonMap(sel);
      expect(reasons.get('m-s2')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_DUPLICATE);
    });

    it('MEMSEL_15_count_budget', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('m1', CHAT_1, CHAR_A, 'm1', 'one', 3),
        makeMemory('m2', CHAT_1, CHAR_A, 'm2', 'two', 3),
        makeMemory('m3', CHAT_1, CHAR_A, 'm3', 'three', 3)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [], true, 2));
      expect(sel.selectedPersonalMemories.length).assertEqual(2);
      const reasons: Map<string, string> = excludedReasonMap(sel);
      expect(reasons.get('m3')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_COUNT_BUDGET);
    });

    it('MEMSEL_16_token_budget', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([
        makeMemory('m1', CHAT_1, CHAR_A, 't1', '一二三', 3),
        makeMemory('m2', CHAT_1, CHAR_A, 't2', '一二三', 3)
      ]);
      // 每条估算 = 标题1 + 正文3 + 4 = 8;预算 11 → 第一条通过,第二条超预算
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [], true, 5, 3, 11, 400));
      expect(sel.selectedPersonalMemories.length).assertEqual(1);
      const reasons: Map<string, string> = excludedReasonMap(sel);
      expect(reasons.get('m2')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_TOKEN_BUDGET);
      expect(sel.personalEstimatedTokens).assertEqual(sel.selectedPersonalMemories[0].estimatedTokens);
    });

    it('MEMSEL_17_owner_relationship_full_list', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeUserRel('r-user', CHAT_1, CHAR_A),
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B),
        makeRelationship('r-ac', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_C)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(sel.allOwnedRelationships.length).assertEqual(3);
    });

    it('MEMSEL_18_reverse_not_selected', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeUserRel('r-au', CHAT_1, CHAR_A),
        makeRelationship('r-ba', CHAT_1, CHAR_B, GroupRelationshipTargetType.Character, CHAR_A)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(containsId(selectedRelIds(sel), 'r-ba')).assertFalse();
      expect(sel.reverseRelationships.length).assertEqual(1);
      expect(sel.reverseRelationships[0].id).assertEqual('r-ba');
    });

    it('MEMSEL_19_a_b_and_b_a_not_merged', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B),
        makeRelationship('r-ba', CHAT_1, CHAR_B, GroupRelationshipTargetType.Character, CHAR_A)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [explicitCandidate(CHAR_B)]));
      // A→B 被选择,B→A 仅在反向诊断区
      expect(containsId(selectedRelIds(sel), 'r-ab')).assertTrue();
      expect(containsId(selectedRelIds(sel), 'r-ba')).assertFalse();
      expect(sel.reverseRelationships.length).assertEqual(1);
      expect(sel.reverseRelationships[0].id).assertEqual('r-ba');
      // A 的拥有关系不包含 B→A
      let ownsBtoA: boolean = false;
      for (let i = 0; i < sel.allOwnedRelationships.length; i++) {
        if (sel.allOwnedRelationships[i].id === 'r-ba') {
          ownsBtoA = true;
        }
      }
      expect(ownsBtoA).assertFalse();
    });

    it('MEMSEL_20_owner_to_user', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeUserRel('r-au', CHAT_1, CHAR_A),
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      expect(containsId(selectedRelIds(sel), 'r-au')).assertTrue();
    });

    it('MEMSEL_21_reliable_target_selectable', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [explicitCandidate(CHAR_B)]));
      expect(containsId(selectedRelIds(sel), 'r-ab')).assertTrue();
    });

    it('MEMSEL_22_unrelated_target_excluded', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeRelationship('r-ac', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_C)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [explicitCandidate(CHAR_B)]));
      expect(containsId(selectedRelIds(sel), 'r-ac')).assertFalse();
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-ac')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_UNRELATED_TARGET);
    });

    it('MEMSEL_23_self_target_defense', 0, async () => {
      const ctx = setup();
      // A→A 属于防御性非法数据(工厂禁止创建),直接构造原始对象验证选择层排除
      const selfRel: GroupCharacterRelationshipMemory = {
        id: 'r-self',
        groupConversationId: CHAT_1,
        ownerCharacterId: CHAR_A,
        targetType: GroupRelationshipTargetType.Character,
        targetId: CHAR_A,
        experienceSummary: 'x',
        attitudeSummary: '',
        relationshipSummary: '',
        importance: 3,
        keywords: [],
        sourceMessageIds: ['s1'],
        sourceHash: 'hash-self',
        sourceType: 'relationship_summary_v1',
        status: GroupRelationshipMemoryStatus.Active,
        createdAt: 900,
        updatedAt: 1000
      };
      ctx.relRepo.setRelationships([selfRel]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [explicitCandidate(CHAR_A)]));
      expect(containsId(selectedRelIds(sel), 'r-self')).assertFalse();
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-self')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_SELF_TARGET);
    });

    it('MEMSEL_24_no_reliable_target_safe_degrades_to_user', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeUserRel('r-au', CHAT_1, CHAR_A),
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B),
        makeRelationship('r-ac', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_C)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      // 无可靠结构化目标:只选择 A→user,owner→character 全部 EXCLUDED_NO_RELIABLE_TARGET
      expect(sel.selectedRelationships.length).assertEqual(1);
      expect(sel.selectedRelationships[0].memory.id).assertEqual('r-au');
      expect(sel.selectedRelationships[0].source)
        .assertEqual(RelationshipSelectionTargetSource.USER_RELATION_DEFAULT);
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-ab')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET);
      expect(reasons.get('r-ac')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET);
    });

    it('MEMSEL_25_archived_relationship_excluded', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B,
          GroupRelationshipMemoryStatus.Archived)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [explicitCandidate(CHAR_B)]));
      expect(containsId(selectedRelIds(sel), 'r-ab')).assertFalse();
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-ab')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_ARCHIVED);
    });

    it('MEMSEL_26_query_failure_safe_degrade', 0, async () => {
      const ctx = setup();
      ctx.memoryRepo.setMemories([makeMemory('m1', CHAT_1, CHAR_A, 'm1', 'ok', 3)]);
      ctx.relRepo.setRelationships([makeUserRel('r-au', CHAT_1, CHAR_A)]);
      ctx.memoryRepo.setFailQuery(true);
      ctx.relRepo.setFailOwnerQuery(true);
      ctx.relRepo.setFailTargetQuery(true);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A));
      // 查询失败 → selected=[] 安全降级,不抛错
      expect(sel.selectedPersonalMemories.length).assertEqual(0);
      expect(sel.selectedRelationships.length).assertEqual(0);
      expect(sel.personalQueryFailed).assertTrue();
      expect(sel.relationshipQueryFailed).assertTrue();
      expect(sel.reverseQueryFailed).assertTrue();
    });

    // ===== G-CONTEXT-MEMORY-SELECTION-1B RELTARGET 关系目标来源修正 =====

    it('RELTARGET_04_reply_derived_candidate_not_relation_target', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B)
      ]);
      // 合成输入:候选来源为 REPLY_TARGET_DERIVED,必须拒绝,不得自动转为可靠来源
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [replyDerivedCandidate(CHAR_B)]));
      expect(containsId(selectedRelIds(sel), 'r-ab')).assertFalse();
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-ab'))
        .assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_REPLY_TARGET_NOT_RELATION_TARGET);
    });

    it('RELTARGET_05_no_reliable_target_only_owner_user', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeUserRel('r-au', CHAT_1, CHAR_A),
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B),
        makeRelationship('r-ac', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_C)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', []));
      expect(sel.selectedRelationships.length).assertEqual(1);
      expect(sel.selectedRelationships[0].memory.id).assertEqual('r-au');
      expect(sel.selectedRelationships[0].source)
        .assertEqual(RelationshipSelectionTargetSource.USER_RELATION_DEFAULT);
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-ab')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET);
      expect(reasons.get('r-ac')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET);
    });

    it('RELTARGET_06_explicit_structured_target_selectable', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B),
        makeRelationship('r-ac', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_C)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [explicitCandidate(CHAR_B)]));
      expect(containsId(selectedRelIds(sel), 'r-ab')).assertTrue();
      expect(containsId(selectedRelIds(sel), 'r-ac')).assertFalse();
      for (let i = 0; i < sel.selectedRelationships.length; i++) {
        if (sel.selectedRelationships[i].memory.id === 'r-ab') {
          expect(sel.selectedRelationships[i].source)
            .assertEqual(RelationshipSelectionTargetSource.EXPLICIT_STRUCTURED_TARGET);
        }
      }
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-ac')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_UNRELATED_TARGET);
    });

    it('RELTARGET_07_display_name_not_inferred', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeRelationship('r-ab', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, CHAR_B)
      ]);
      // 用户正文包含 B 的名称,但没有结构化 ID → 不得选择 A→B
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '这件事情和 角色B 有关吗?', []));
      expect(containsId(selectedRelIds(sel), 'r-ab')).assertFalse();
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-ab')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET);
    });

    it('RELTARGET_08_self_candidate_excluded', 0, async () => {
      const ctx = setup();
      const selfRel: GroupCharacterRelationshipMemory = {
        id: 'r-self',
        groupConversationId: CHAT_1,
        ownerCharacterId: CHAR_A,
        targetType: GroupRelationshipTargetType.Character,
        targetId: CHAR_A,
        experienceSummary: 'x',
        attitudeSummary: '',
        relationshipSummary: '',
        importance: 3,
        keywords: [],
        sourceMessageIds: ['s1'],
        sourceHash: 'hash-self',
        sourceType: 'relationship_summary_v1',
        status: GroupRelationshipMemoryStatus.Active,
        createdAt: 900,
        updatedAt: 1000
      };
      ctx.relRepo.setRelationships([selfRel]);
      // 即使候选错误包含 A,也必须排除并标记 EXCLUDED_SELF_TARGET
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [explicitCandidate(CHAR_A)]));
      expect(containsId(selectedRelIds(sel), 'r-self')).assertFalse();
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-self')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_SELF_TARGET);
    });

    it('RELTARGET_09_candidate_not_in_participants_excluded', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeRelationship('r-ax', CHAT_1, CHAR_A, GroupRelationshipTargetType.Character, 'char-x')
      ]);
      // 候选不属于当前群聊成员快照(participants 只有 A/B/C)
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [explicitCandidate('char-x')]));
      expect(containsId(selectedRelIds(sel), 'r-ax')).assertFalse();
      const reasons: Map<string, string> = excludedRelReasonMap(sel);
      expect(reasons.get('r-ax')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_INVALID_TARGET);
    });

    it('RELTARGET_10_reverse_only_diagnostic', 0, async () => {
      const ctx = setup();
      ctx.relRepo.setRelationships([
        makeRelationship('r-ba', CHAT_1, CHAR_B, GroupRelationshipTargetType.Character, CHAR_A)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '', [explicitCandidate(CHAR_B)]));
      expect(containsId(selectedRelIds(sel), 'r-ba')).assertFalse();
      expect(sel.reverseRelationships.length).assertEqual(1);
      expect(sel.reverseRelationships[0].id).assertEqual('r-ba');
    });

    it('RELTARGET_14_personal_memory_no_regression', 0, async () => {
      const ctx = setup();
      // 绕过 Repository 过滤,验证选择层自身仍正确隔离(跨群聊/状态防御)
      ctx.memoryRepo.bypassFilter = true;
      ctx.memoryRepo.setMemories([
        makeMemory('m-archived', CHAT_1, CHAR_A, 'm-archived', 'archived', 5,
          GroupCharacterMemoryOrigin.Manual, GroupCharacterMemoryStatus.Archived),
        makeMemory('m-manual', CHAT_1, CHAR_A, 'm-manual', 'manual memory', 1),
        makeMemory('m-summary', CHAT_1, CHAR_A, 'm-summary', 'summary memory', 5,
          GroupCharacterMemoryOrigin.Interaction, GroupCharacterMemoryStatus.Active, [], undefined,
          'sm-sum', SOURCE_TYPE_SELF_SUMMARY_V1),
        makeMemory('m-other-chat', CHAT_2, CHAR_A, 'm-other-chat', 'other chat', 5)
      ]);
      const sel: GroupCharacterMemorySelection =
        await ctx.selector.select(makeInput(CHAT_1, CHAR_A, '关于 manual 的事情', [], true, 2));
      // 跨群聊排除 / Archived 排除 / Manual 优先(即便 importance 低)
      expect(containsId(selectedIds(sel), 'm-other-chat')).assertFalse();
      expect(containsId(selectedIds(sel), 'm-archived')).assertFalse();
      expect(sel.selectedPersonalMemories.length).assertEqual(2);
      expect(sel.selectedPersonalMemories[0].memory.id).assertEqual('m-manual');
      const reasons: Map<string, string> = excludedReasonMap(sel);
      expect(reasons.get('m-archived')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_ARCHIVED);
      expect(reasons.get('m-other-chat')).assertEqual(GroupCharacterMemoryExclusionReason.EXCLUDED_CHAT_MISMATCH);
    });

  });
}
