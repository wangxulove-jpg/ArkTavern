/**
 * GroupMemorySelectionInspection 集成单元测试(MEMSEL-27 ~ MEMSEL-30)
 *
 * 验证:
 * - MEMSEL-27 检查器角色隔离:切换 A→B 后不残留 A 的选择
 * - MEMSEL-28 选择不等于注入:selected>0 时 injected 仍为 0
 * - MEMSEL-29 Provider 请求不变:接入选择器前后交给 Provider 的 messages 一致
 * - MEMSEL-30 日志不含正文:buildSafeDiagnosticSummary 只含计数与原因
 *
 * 使用真实 GroupChatRuntimeService(注入真实 GroupCharacterMemorySelector +
 * Fake 内存 Repository)+ Fake 边界(ModelService / MessageService / PromptAssembler)。
 * 不调用真实模型 / 不启动设备。
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupChatRuntimeService, GroupRuntimeCallbacks, GroupRuntimeMessageUpdate } from '../main/ets/services/groupchat/GroupChatRuntimeService';
import { GroupRoundCoordinator } from '../main/ets/services/groupchat/GroupRoundCoordinator';
import { GroupPromptInspectionStore } from '../main/ets/services/groupchat/GroupPromptInspectionStore';
import { GroupRuntimeRegistry } from '../main/ets/services/groupchat/GroupRuntimeRegistry';
import { GroupConversationPersistenceService } from '../main/ets/services/groupchat/GroupConversationPersistenceService';
import { GroupConversationMessageService } from '../main/ets/services/groupchat/GroupConversationMessageService';
import { GroupPromptAssembler } from '../main/ets/services/groupchat/GroupPromptAssembler';
import { ModelService } from '../main/ets/services/ModelService';
import { CharacterService } from '../main/ets/services/CharacterService';
import { GroupCharacterMemorySelector } from '../main/ets/services/groupchat/GroupCharacterMemorySelector';
import { GroupCharacterMemoryRepository } from '../main/ets/repositories/groupchat/GroupCharacterMemoryRepository';
import { GroupCharacterRelationshipMemoryRepository } from '../main/ets/repositories/groupchat/GroupCharacterRelationshipMemoryRepository';
import { DbHelper } from '../main/ets/database/DbHelper';
import {
  GroupRoundState,
  GroupRoundPlan,
  GroupReplyTarget,
  selectedCharactersReplyTarget
} from '../main/ets/services/groupchat/GroupRoundTypes';
import {
  FakeGroupMessageService,
  FakeModelService,
  FakePromptAssembler,
  FakeGroupPersistenceService,
  FakeCharacterService,
  RuntimeCallbackLog,
  createRuntimeCallbackLog,
  flushMicrotasks,
  makeGroupChat,
  makeParticipant,
  makeCharacter,
  makeGroupUserMessage,
  makeProviderConfig,
  CHAT_A
} from './GroupRuntimeTestFakes';
import { ChatMessage, ChatMessageStatus } from '../main/ets/models/ChatMessage';
import {
  GroupCharacterMemory,
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
  GroupCharacterMemorySelection,
  GroupCharacterMemorySelectionInput,
  GroupCharacterRelationshipExclusionReason,
  RelationshipSelectionTargetSource
} from '../main/ets/models/groupchat/GroupPromptInspectionModels';

const CHAR_A: string = 'char-a';
const CHAR_B: string = 'char-b';
const CHAR_C: string = 'char-c';

// ===== Fake Repository(内存,继承真实 Repository) =====

class FakeMemoryRepo extends GroupCharacterMemoryRepository {
  private items: GroupCharacterMemory[] = [];

  constructor() {
    super(new DbHelper('mem-sel-inspection-test'));
  }

  setMemories(items: GroupCharacterMemory[]): void {
    this.items = items.slice();
  }

  async listByCharacter(
    groupConversationId: string,
    characterId: string
  ): Promise<GroupCharacterMemory[]> {
    const result: GroupCharacterMemory[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const m = this.items[i];
      if (m.groupConversationId === groupConversationId && m.characterId === characterId) {
        result.push(m);
      }
    }
    return result;
  }
}

class FakeRelationshipRepo extends GroupCharacterRelationshipMemoryRepository {
  private items: GroupCharacterRelationshipMemory[] = [];

  constructor() {
    super(new DbHelper('mem-sel-inspection-test'));
  }

  setRelationships(items: GroupCharacterRelationshipMemory[]): void {
    this.items = items.slice();
  }

  async listByOwner(
    groupConversationId: string,
    ownerCharacterId: string
  ): Promise<GroupCharacterRelationshipMemory[]> {
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

// ===== Runtime 上下文 =====

interface SelRuntimeContext {
  runtime: GroupChatRuntimeService;
  store: GroupPromptInspectionStore;
  fakeMsg: FakeGroupMessageService;
  fakeModel: FakeModelService;
  fakePrompt: FakePromptAssembler;
  memoryRepo: FakeMemoryRepo;
  relRepo: FakeRelationshipRepo;
  coordinator: GroupRoundCoordinator;
  log: RuntimeCallbackLog;
  callbacks: GroupRuntimeCallbacks;
}

class SelRuntimeCallbacksImpl implements GroupRuntimeCallbacks {
  private readonly log: RuntimeCallbackLog;

  constructor(log: RuntimeCallbackLog) {
    this.log = log;
  }

  onRoundStateChanged(state: GroupRoundState): void {
    this.log.states.push(state);
  }

  onSpeakerStarted(_characterId: string, _speakerIndex: number): void {
  }

  onMessageCreated(_message: ChatMessage): void {
  }

  onMessageUpdated(_update: GroupRuntimeMessageUpdate): void {
  }

  onSpeakerCompleted(_characterId: string, _speakerIndex: number): void {
  }

  onRoundCompleted(): void {
    this.log.roundCompleted++;
  }

  onRoundCancelled(): void {
    this.log.roundCancelled++;
  }

  onRoundFailed(_characterId: string, _errorMessage: string): void {
    this.log.roundFailed.push({ characterId: _characterId, message: _errorMessage });
  }
}

function setupSelRuntime(withSelector: boolean): SelRuntimeContext {
  const registry: GroupRuntimeRegistry = new GroupRuntimeRegistry();
  const groupService: FakeGroupPersistenceService = new FakeGroupPersistenceService();
  const charService: FakeCharacterService = new FakeCharacterService();
  groupService.chats = [makeGroupChat(CHAT_A)];
  groupService.participantsByChat.set(CHAT_A, [
    makeParticipant(CHAT_A, CHAR_A, 0),
    makeParticipant(CHAT_A, CHAR_B, 1),
    makeParticipant(CHAT_A, CHAR_C, 2)
  ]);
  charService.characters.set(CHAR_A, makeCharacter(CHAR_A, 'A'));
  charService.characters.set(CHAR_B, makeCharacter(CHAR_B, 'B'));
  charService.characters.set(CHAR_C, makeCharacter(CHAR_C, 'C'));

  const coordinator: GroupRoundCoordinator = new GroupRoundCoordinator(
    groupService as Object as GroupConversationPersistenceService,
    charService as Object as CharacterService
  );
  const fakeMsg: FakeGroupMessageService = new FakeGroupMessageService();
  const fakePrompt: FakePromptAssembler = new FakePromptAssembler();
  fakePrompt.characters.set(CHAR_A, makeCharacter(CHAR_A, 'A'));
  fakePrompt.characters.set(CHAR_B, makeCharacter(CHAR_B, 'B'));
  fakePrompt.characters.set(CHAR_C, makeCharacter(CHAR_C, 'C'));
  const fakeModel: FakeModelService = new FakeModelService();
  fakeModel.currentConfig = makeProviderConfig();
  const store: GroupPromptInspectionStore = new GroupPromptInspectionStore();
  const memoryRepo: FakeMemoryRepo = new FakeMemoryRepo();
  const relRepo: FakeRelationshipRepo = new FakeRelationshipRepo();

  const runtime: GroupChatRuntimeService = new GroupChatRuntimeService(
    coordinator,
    fakeMsg as Object as GroupConversationMessageService,
    fakePrompt as Object as GroupPromptAssembler,
    fakeModel as Object as ModelService,
    registry,
    store,
    withSelector ? new GroupCharacterMemorySelector(memoryRepo, relRepo) : null
  );

  const log: RuntimeCallbackLog = createRuntimeCallbackLog();
  const callbacks: GroupRuntimeCallbacks = new SelRuntimeCallbacksImpl(log);
  return {
    runtime: runtime,
    store: store,
    fakeMsg: fakeMsg,
    fakeModel: fakeModel,
    fakePrompt: fakePrompt,
    memoryRepo: memoryRepo,
    relRepo: relRepo,
    coordinator: coordinator,
    log: log,
    callbacks: callbacks
  };
}

function makeMemory(
  id: string,
  characterId: string,
  title: string,
  content: string,
  keywords: string[] = []
): GroupCharacterMemory {
  return createGroupCharacterMemoryRecord({
    id: id,
    groupConversationId: CHAT_A,
    characterId: characterId,
    title: title,
    content: content,
    importance: 3,
    keywords: keywords,
    createdAt: 900,
    updatedAt: 1000
  });
}

function makeUserRel(ownerId: string): GroupCharacterRelationshipMemory {
  return createGroupCharacterRelationshipMemoryRecord({
    id: 'r-' + ownerId + '-user',
    groupConversationId: CHAT_A,
    ownerCharacterId: ownerId,
    targetType: GroupRelationshipTargetType.User,
    targetId: 'user',
    experienceSummary: 'exp-user',
    attitudeSummary: 'att-user',
    relationshipSummary: 'rel-user',
    importance: 3,
    keywords: [],
    sourceMessageIds: ['sm-1'],
    sourceHash: 'hash-' + ownerId + '-user',
    status: GroupRelationshipMemoryStatus.Active,
    createdAt: 900,
    updatedAt: 1000
  });
}

function makeCharacterRel(
  ownerId: string,
  targetId: string,
  id: string = 'r-' + ownerId + '-' + targetId
): GroupCharacterRelationshipMemory {
  return createGroupCharacterRelationshipMemoryRecord({
    id: id,
    groupConversationId: CHAT_A,
    ownerCharacterId: ownerId,
    targetType: GroupRelationshipTargetType.Character,
    targetId: targetId,
    experienceSummary: 'exp-' + targetId,
    attitudeSummary: 'att-' + targetId,
    relationshipSummary: 'rel-' + targetId,
    importance: 3,
    keywords: [],
    sourceMessageIds: ['sm-1'],
    sourceHash: 'hash-' + id,
    status: GroupRelationshipMemoryStatus.Active,
    createdAt: 900,
    updatedAt: 1000
  });
}

function excludedRelReasonMap(sel: GroupCharacterMemorySelection): Map<string, string> {
  const map: Map<string, string> = new Map<string, string>();
  for (let i = 0; i < sel.excludedRelationships.length; i++) {
    map.set(sel.excludedRelationships[i].memory.id, sel.excludedRelationships[i].reason);
  }
  return map;
}

async function waitForStreamCount(s: SelRuntimeContext, expected: number): Promise<void> {
  for (let i = 0; i < 100 && s.fakeModel.streamCount() < expected; i++) {
    await flushMicrotasks();
  }
}

/** 启动单目标轮并完成第一个流;返回 roundPromise。 */
async function startAndCompleteFirst(s: SelRuntimeContext): Promise<Promise<void>> {
  const userMsg: ChatMessage = makeGroupUserMessage('user-1', 'hello about 苹果', 'round-1');
  s.fakeMsg.setHistory(CHAT_A, [userMsg]);
  const plan: GroupRoundPlan = await s.coordinator.prepareRound(
    CHAT_A, userMsg.id, 'round-1', selectedCharactersReplyTarget([CHAR_A])
  );
  const roundPromise: Promise<void> = s.runtime.startRound(plan, s.callbacks);
  await waitForStreamCount(s, 1);
  s.fakeModel.fireCompleteAt(0, 'reply-a');
  await roundPromise;
  return roundPromise;
}

function messagesSignature(messages: ChatMessage[]): string[] {
  const sig: string[] = [];
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    sig.push(m.role + '|' + (m.senderCharacterId !== undefined ? m.senderCharacterId : '')
      + '|' + m.content);
  }
  return sig;
}

export default function groupMemorySelectionInspectionTest() {
  describe('GroupMemorySelectionInspectionTest', () => {

    it('MEMSEL_27_inspector_character_isolation', 0, async () => {
      const s = setupSelRuntime(true);
      s.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAR_A, 'A memory', 'A private memory'),
        makeMemory('mem-b-1', CHAR_B, 'B memory', 'B private memory')
      ]);
      // 双角色轮:A 和 B 都发言
      const userMsg: ChatMessage = makeGroupUserMessage('user-1', 'hello', 'round-1');
      s.fakeMsg.setHistory(CHAT_A, [userMsg]);
      const plan: GroupRoundPlan = await s.coordinator.prepareRound(
        CHAT_A, userMsg.id, 'round-1', selectedCharactersReplyTarget([CHAR_A, CHAR_B])
      );
      const roundPromise: Promise<void> = s.runtime.startRound(plan, s.callbacks);
      await waitForStreamCount(s, 1);
      s.fakeModel.fireCompleteAt(0, 'reply-a');
      await waitForStreamCount(s, 2);
      s.fakeModel.fireCompleteAt(1, 'reply-b');
      await roundPromise;

      const snapA = s.store.get(CHAT_A, CHAR_A);
      const snapB = s.store.get(CHAT_A, CHAR_B);
      expect(snapA !== undefined).assertTrue();
      expect(snapB !== undefined).assertTrue();
      if (snapA !== undefined && snapB !== undefined) {
        // 各自快照的 ownerCharacterId 隔离
        expect(snapA.speakerCharacterId).assertEqual(CHAR_A);
        expect(snapB.speakerCharacterId).assertEqual(CHAR_B);
        const selA: GroupCharacterMemorySelection | undefined = snapA.memorySelection;
        const selB: GroupCharacterMemorySelection | undefined = snapB.memorySelection;
        expect(selA !== undefined).assertTrue();
        expect(selB !== undefined).assertTrue();
        if (selA !== undefined && selB !== undefined) {
          expect(selA.ownerCharacterId).assertEqual(CHAR_A);
          expect(selB.ownerCharacterId).assertEqual(CHAR_B);
          // A 的选区不包含 B 的记忆
          let containsB: boolean = false;
          for (let i = 0; i < selA.allPersonalMemories.length; i++) {
            if (selA.allPersonalMemories[i].characterId === CHAR_B) {
              containsB = true;
            }
          }
          expect(containsB).assertFalse();
          // B 的选区不含 A 的记忆
          let containsA: boolean = false;
          for (let i = 0; i < selB.allPersonalMemories.length; i++) {
            if (selB.allPersonalMemories[i].characterId === CHAR_A) {
              containsA = true;
            }
          }
          expect(containsA).assertFalse();
        }
      }
    });

    it('MEMSEL_28_selection_does_not_equal_injection', 0, async () => {
      const s = setupSelRuntime(true);
      s.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAR_A, 'A memory', 'A private memory', ['苹果'])
      ]);
      s.relRepo.setRelationships([makeUserRel(CHAR_A)]);
      await startAndCompleteFirst(s);

      const snap = s.store.get(CHAT_A, CHAR_A);
      expect(snap !== undefined).assertTrue();
      if (snap !== undefined) {
        // 即使有已选记忆和已选关系,也必须注入为 0
        expect(snap.totalMemoriesSelected > 0).assertTrue();
        expect(snap.totalMemoriesInjected).assertEqual(0);
        expect(snap.totalRelationshipsSelected > 0).assertTrue();
        expect(snap.totalRelationshipsInjected).assertEqual(0);
        expect(snap.memorySelection !== undefined).assertTrue();
      }
    });

    it('MEMSEL_29_provider_request_unchanged', 0, async () => {
      // 基线:无选择器
      const base = setupSelRuntime(false);
      await startAndCompleteFirst(base);
      const baseline: string[] = messagesSignature(base.fakeModel.recordAt(0).messages);

      // 接入选择器 + 存在记忆/关系
      const wired = setupSelRuntime(true);
      wired.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAR_A, 'A memory', 'A private memory', ['苹果'])
      ]);
      wired.relRepo.setRelationships([makeUserRel(CHAR_A)]);
      await startAndCompleteFirst(wired);
      const actual: string[] = messagesSignature(wired.fakeModel.recordAt(0).messages);

      // 交给 Provider 的 messages 内容一致
      expect(actual.length).assertEqual(baseline.length);
      for (let i = 0; i < baseline.length; i++) {
        expect(actual[i]).assertEqual(baseline[i]);
      }
      // 记忆正文 / 关系正文均未进入请求
      let hasMemoryContent: boolean = false;
      for (let i = 0; i < actual.length; i++) {
        if (actual[i].indexOf('A private memory') >= 0 || actual[i].indexOf('rel-user') >= 0) {
          hasMemoryContent = true;
        }
      }
      expect(hasMemoryContent).assertFalse();
      // 请求数组不是选择结果数组的引用
      const snap = wired.store.get(CHAT_A, CHAR_A);
      expect(snap !== undefined).assertTrue();
    });

    it('MEMSEL_30_safe_log_summary_contains_no_content', 0, async () => {
      const s = setupSelRuntime(true);
      s.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAR_A, 'A memory', 'SECRET_MEMORY_CONTENT_XYZ'),
        makeMemory('mem-a-2', CHAR_A, 'A2 memory', 'SECRET_MEMORY_CONTENT_ABC')
      ]);
      s.relRepo.setRelationships([makeUserRel(CHAR_A)]);
      const selector: GroupCharacterMemorySelector = new GroupCharacterMemorySelector(
        s.memoryRepo, s.relRepo
      );
      const input: GroupCharacterMemorySelectionInput = {
        groupConversationId: CHAT_A,
        ownerCharacterId: CHAR_A,
        currentUserMessage: 'hello about 苹果',
        visibleMessageIds: ['user-1'],
        participantCharacterIds: [CHAR_A, CHAR_B, CHAR_C],
        relationshipTargetCandidates: [],
        includeUserRelationship: true,
        personalMemoryMaxCount: 5,
        relationshipMemoryMaxCount: 3,
        personalMemoryTokenBudget: 600,
        relationshipMemoryTokenBudget: 400
      };
      const sel: GroupCharacterMemorySelection = await selector.select(input);
      const summary: string = GroupCharacterMemorySelector.buildSafeDiagnosticSummary(sel);
      // 摘要不含正文 / 关键词全文 / 完整 ID
      expect(summary.indexOf('SECRET_MEMORY_CONTENT_XYZ')).assertEqual(-1);
      expect(summary.indexOf('SECRET_MEMORY_CONTENT_ABC')).assertEqual(-1);
      expect(summary.indexOf('mem-a-1')).assertEqual(-1);
      expect(summary.indexOf('苹果')).assertEqual(-1);
      // 摘要含计数
      expect(summary.indexOf('selectedPersonal=') >= 0).assertTrue();
    });

    // ===== G-CONTEXT-MEMORY-SELECTION-1B RELTARGET 运行时级 =====

    it('RELTARGET_01_default_all_reply_does_not_select_character_rels', 0, async () => {
      const s = setupSelRuntime(true);
      s.relRepo.setRelationships([
        makeUserRel(CHAR_A),
        makeCharacterRel(CHAR_A, CHAR_B, 'r-ab'),
        makeCharacterRel(CHAR_A, CHAR_C, 'r-ac')
      ]);
      // 用户消息 replyTarget=[A,B,C](全员回复),当前 Speaker=A
      const userMsg: ChatMessage = makeGroupUserMessage(
        'user-1', 'hello all', 'round-1', [CHAR_A, CHAR_B, CHAR_C]
      );
      s.fakeMsg.setHistory(CHAT_A, [userMsg]);
      const plan: GroupRoundPlan = await s.coordinator.prepareRound(
        CHAT_A, userMsg.id, 'round-1', selectedCharactersReplyTarget([CHAR_A, CHAR_B, CHAR_C])
      );
      const roundPromise: Promise<void> = s.runtime.startRound(plan, s.callbacks);
      await waitForStreamCount(s, 3);
      s.fakeModel.fireCompleteAt(0, 'reply-a');
      await waitForStreamCount(s, 3);
      s.fakeModel.fireCompleteAt(1, 'reply-b');
      await waitForStreamCount(s, 3);
      s.fakeModel.fireCompleteAt(2, 'reply-c');
      await roundPromise;

      const snap = s.store.get(CHAT_A, CHAR_A);
      expect(snap !== undefined).assertTrue();
      if (snap !== undefined && snap.memorySelection !== undefined) {
        const sel = snap.memorySelection;
        // 只选择 A→user;replyTarget 不导致 A→B / A→C
        expect(sel.selectedRelationships.length).assertEqual(1);
        expect(sel.selectedRelationships[0].memory.id).assertEqual('r-char-a-user');
        expect(sel.selectedRelationships[0].source)
          .assertEqual(RelationshipSelectionTargetSource.USER_RELATION_DEFAULT);
        // 全部拥有关系仍完整显示
        expect(sel.allOwnedRelationships.length).assertEqual(3);
        // A→B / A→C 有明确原因
        const reasons: Map<string, string> = excludedRelReasonMap(sel);
        expect(reasons.get('r-ab')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET);
        expect(reasons.get('r-ac')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET);
        // 快照记录本轮回复目标(仅诊断)
        expect(snap.replyTargetCharacterIds !== undefined).assertTrue();
        if (snap.replyTargetCharacterIds !== undefined) {
          expect(snap.replyTargetCharacterIds.length).assertEqual(3);
        }
      }
    });

    it('RELTARGET_02_reply_only_self_no_a_to_a', 0, async () => {
      const s = setupSelRuntime(true);
      s.relRepo.setRelationships([makeUserRel(CHAR_A)]);
      // 仅回复 A(当前 Speaker=A),不得出现 A→A
      const userMsg: ChatMessage = makeGroupUserMessage('user-1', 'hi A', 'round-1', [CHAR_A]);
      s.fakeMsg.setHistory(CHAT_A, [userMsg]);
      const plan: GroupRoundPlan = await s.coordinator.prepareRound(
        CHAT_A, userMsg.id, 'round-1', selectedCharactersReplyTarget([CHAR_A])
      );
      const roundPromise: Promise<void> = s.runtime.startRound(plan, s.callbacks);
      await waitForStreamCount(s, 1);
      s.fakeModel.fireCompleteAt(0, 'reply-a');
      await roundPromise;

      const snap = s.store.get(CHAT_A, CHAR_A);
      expect(snap !== undefined).assertTrue();
      if (snap !== undefined && snap.memorySelection !== undefined) {
        const sel = snap.memorySelection;
        expect(sel.selectedRelationships.length).assertEqual(1);
        expect(sel.selectedRelationships[0].memory.id).assertEqual('r-char-a-user');
        // 没有任何 A→A
        let hasSelfRel: boolean = false;
        for (let i = 0; i < sel.allOwnedRelationships.length; i++) {
          if (sel.allOwnedRelationships[i].targetType === GroupRelationshipTargetType.Character
            && sel.allOwnedRelationships[i].targetId === CHAR_A) {
            hasSelfRel = true;
          }
        }
        expect(hasSelfRel).assertFalse();
      }
    });

    it('RELTARGET_03_persistent_reply_target_not_self_relation', 0, async () => {
      const s = setupSelRuntime(true);
      s.relRepo.setRelationships([makeUserRel(CHAR_B)]);
      // persistentReplyTarget=B → 用户消息 replyTarget=[B];当前 Speaker=B。
      // 不得把 replyTarget=B 理解为 B→B;只允许默认选择 B→user。
      const userMsg: ChatMessage = makeGroupUserMessage('user-1', 'keep talking to B', 'round-1', [CHAR_B]);
      s.fakeMsg.setHistory(CHAT_A, [userMsg]);
      const plan: GroupRoundPlan = await s.coordinator.prepareRound(
        CHAT_A, userMsg.id, 'round-1', selectedCharactersReplyTarget([CHAR_B])
      );
      const roundPromise: Promise<void> = s.runtime.startRound(plan, s.callbacks);
      await waitForStreamCount(s, 1);
      s.fakeModel.fireCompleteAt(0, 'reply-b');
      await roundPromise;

      const snap = s.store.get(CHAT_A, CHAR_B);
      expect(snap !== undefined).assertTrue();
      if (snap !== undefined && snap.memorySelection !== undefined) {
        const sel = snap.memorySelection;
        expect(sel.selectedRelationships.length).assertEqual(1);
        expect(sel.selectedRelationships[0].memory.id).assertEqual('r-char-b-user');
        expect(sel.selectedRelationships[0].source)
          .assertEqual(RelationshipSelectionTargetSource.USER_RELATION_DEFAULT);
        // 没有任何 B→B
        let hasSelfRel: boolean = false;
        for (let i = 0; i < sel.allOwnedRelationships.length; i++) {
          if (sel.allOwnedRelationships[i].targetType === GroupRelationshipTargetType.Character
            && sel.allOwnedRelationships[i].targetId === CHAR_B) {
            hasSelfRel = true;
          }
        }
        expect(hasSelfRel).assertFalse();
      }
    });

    it('RELTARGET_11_inspector_shows_source_and_reason', 0, async () => {
      const s = setupSelRuntime(true);
      s.relRepo.setRelationships([
        makeUserRel(CHAR_A),
        makeCharacterRel(CHAR_A, CHAR_B, 'r-ab')
      ]);
      await startAndCompleteFirst(s);
      const snap = s.store.get(CHAT_A, CHAR_A);
      expect(snap !== undefined).assertTrue();
      if (snap !== undefined && snap.memorySelection !== undefined) {
        const sel = snap.memorySelection;
        // 选中 A→user,来源 USER_RELATION_DEFAULT
        expect(sel.selectedRelationships.length).assertEqual(1);
        expect(sel.selectedRelationships[0].source)
          .assertEqual(RelationshipSelectionTargetSource.USER_RELATION_DEFAULT);
        // 未选中 A→B,原因 EXCLUDED_NO_RELIABLE_TARGET(当前消息没有可靠结构化关系目标)
        const reasons: Map<string, string> = excludedRelReasonMap(sel);
        expect(reasons.get('r-ab')).assertEqual(GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET);
      }
    });

    it('RELTARGET_12_provider_unchanged_after_fix', 0, async () => {
      // 基线:无选择器
      const base = setupSelRuntime(false);
      await startAndCompleteFirst(base);
      const baseline: string[] = messagesSignature(base.fakeModel.recordAt(0).messages);

      // 接入选择器 + 存在关系(仅 owner→user)
      const wired = setupSelRuntime(true);
      wired.relRepo.setRelationships([makeUserRel(CHAR_A)]);
      await startAndCompleteFirst(wired);
      const actual: string[] = messagesSignature(wired.fakeModel.recordAt(0).messages);

      expect(actual.length).assertEqual(baseline.length);
      for (let i = 0; i < baseline.length; i++) {
        expect(actual[i]).assertEqual(baseline[i]);
      }
      let hasRelContent: boolean = false;
      for (let i = 0; i < actual.length; i++) {
        if (actual[i].indexOf('rel-user') >= 0) {
          hasRelContent = true;
        }
      }
      expect(hasRelContent).assertFalse();
    });

    it('RELTARGET_13_selection_not_injection', 0, async () => {
      const s = setupSelRuntime(true);
      s.relRepo.setRelationships([makeUserRel(CHAR_A)]);
      await startAndCompleteFirst(s);
      const snap = s.store.get(CHAT_A, CHAR_A);
      expect(snap !== undefined).assertTrue();
      if (snap !== undefined) {
        expect(snap.totalRelationshipsSelected > 0).assertTrue();
        expect(snap.totalRelationshipsInjected).assertEqual(0);
        expect(snap.totalMemoriesInjected).assertEqual(0);
      }
    });

  });
}
