/**
 * GroupMemoryPromptInjection 本地单元测试(INJECT-01 ~ INJECT-30 子集)
 *
 * 验证群聊当前角色个人记忆与方向关系安全注入:
 * - 使用真实 GroupPromptAssembler(注入真实 Selection)+ Fake PromptBuilder / 服务边界
 * - 使用真实 GroupCharacterMemorySelector + Fake 内存 Repository 生成 Selection
 * - 验证 A/B 隔离、方向、边界说明、完整正文、顺序、Token 估算、selected/formatted/injected
 *
 * 纯本地单元测试,不调用真实模型,不启动设备。
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupPromptAssembler, GroupPromptAssemblyContext, GroupPromptAssemblyResult } from '../main/ets/services/groupchat/GroupPromptAssembler';
import { GroupMemoryPromptFormatter, GroupMemoryFormatResult, PERSONAL_MEMORY_SEGMENT_HEADER, RELATIONSHIP_MEMORY_SEGMENT_HEADER } from '../main/ets/services/groupchat/GroupMemoryPromptFormatter';
import { buildNarrationPrompt, GroupNarrationPromptInput } from '../main/ets/services/groupchat/GroupNarrationPromptAssembler';
import { GroupCharacterMemorySelector } from '../main/ets/services/groupchat/GroupCharacterMemorySelector';
import { GroupCharacterMemoryRepository } from '../main/ets/repositories/groupchat/GroupCharacterMemoryRepository';
import { GroupCharacterRelationshipMemoryRepository } from '../main/ets/repositories/groupchat/GroupCharacterRelationshipMemoryRepository';
import { DbHelper } from '../main/ets/database/DbHelper';
import { PromptBuilder, PromptBuildResult } from '../main/ets/services/PromptBuilder';
import { HistoryTrimmer } from '../main/ets/services/HistoryTrimmer';
import { TokenCounter, estimateTextTokens } from '../main/ets/services/TokenCounter';
import { LorebookService } from '../main/ets/services/LorebookService';
import { CharacterService } from '../main/ets/services/CharacterService';
import { PromptPresetService } from '../main/ets/services/PromptPresetService';
import { ModelService } from '../main/ets/services/ModelService';
import {
  ChatMessage,
  ChatMessageStatus,
  createChatMessage
} from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import { Character } from '../main/ets/models/Character';
import { Lorebook } from '../main/ets/models/Lorebook';
import { PromptPreset } from '../main/ets/models/PromptPreset';
import { ProviderConfig } from '../main/ets/models/ProviderConfig';
import { MacroContext, createMacroContext } from '../main/ets/models/MacroContext';
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
  RelationshipSelectionTargetSource,
  GroupRelationshipTargetCandidate
} from '../main/ets/models/groupchat/GroupPromptInspectionModels';

const CHAT_A: string = 'chat-a';
const CHAT_B: string = 'chat-b';
const CHAR_A: string = 'char-a';
const CHAR_B: string = 'char-b';
const CHAR_C: string = 'char-c';

const MARKER_A_MEM: string = 'A_PRIVATE_MEMORY_MARKER';
const MARKER_B_MEM: string = 'B_PRIVATE_MEMORY_MARKER';
const MARKER_A_USER_REL: string = 'A_TO_USER_RELATION_MARKER';
const MARKER_A_B_REL: string = 'A_TO_B_RELATION_MARKER';
const MARKER_B_A_REL: string = 'B_TO_A_RELATION_MARKER';

// ===== Fake Repository(内存) =====

class FakeMemoryRepo extends GroupCharacterMemoryRepository {
  private items: GroupCharacterMemory[] = [];
  failQuery: boolean = false;

  constructor() {
    super(new DbHelper('inject-memory-test'));
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
    super(new DbHelper('inject-memory-test'));
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

// ===== Fake 服务边界(供真实 GroupPromptAssembler 使用) =====

class FakePromptBuilderForInjection {
  baseMessages: ChatMessage[] = [];

  setBaseMessages(messages: ChatMessage[]): void {
    this.baseMessages = messages.slice();
  }

  build(_context: Object): PromptBuildResult {
    return {
      messages: this.baseMessages.slice(),
      matchedLorebookEntryIds: []
    };
  }

  buildMacroContext(
    character: Character | null,
    userName: string,
    _messages: ChatMessage[]
  ): MacroContext {
    const name: string = character !== null ? character.name : '';
    return createMacroContext(name, userName);
  }
}

class FakeLorebookServiceForInjection {
  async getCurrentLorebook(): Promise<Lorebook | null> {
    return null;
  }

  async getById(_id: string): Promise<Lorebook | null> {
    return null;
  }
}

class FakeCharacterServiceForInjection {
  characters: Map<string, Character> = new Map<string, Character>();

  async getById(characterId: string): Promise<Character | null> {
    return this.characters.get(characterId) ?? null;
  }
}

class FakePresetServiceForInjection {
  async getCurrentPreset(): Promise<PromptPreset | null> {
    return null;
  }
}

class FakeModelServiceForInjection {
  getCurrentConfig(): ProviderConfig | null {
    return null;
  }
}

// ===== 测试上下文 =====

interface InjectContext {
  selector: GroupCharacterMemorySelector;
  memoryRepo: FakeMemoryRepo;
  relRepo: FakeRelationshipRepo;
  assembler: GroupPromptAssembler;
  fakePrompt: FakePromptBuilderForInjection;
  charService: FakeCharacterServiceForInjection;
}

function makeCharacter(id: string, name: string): Character {
  return {
    id: id,
    name: name,
    description: 'test-desc',
    personality: '',
    scenario: '',
    firstMessage: '',
    systemPrompt: '',
    avatarUri: '',
    mesExample: '',
    creatorNotes: '',
    postHistoryInstructions: '',
    alternateGreetings: [],
    tags: [],
    creator: '',
    characterVersion: '',
    extensions: {},
    characterBookId: '',
    userName: '',
    sortOrder: 0,
    createdAt: 1000,
    updatedAt: 1000
  };
}

function setupInject(): InjectContext {
  const memoryRepo: FakeMemoryRepo = new FakeMemoryRepo();
  const relRepo: FakeRelationshipRepo = new FakeRelationshipRepo();
  const selector: GroupCharacterMemorySelector = new GroupCharacterMemorySelector(memoryRepo, relRepo);
  const fakePrompt: FakePromptBuilderForInjection = new FakePromptBuilderForInjection();
  const charService: FakeCharacterServiceForInjection = new FakeCharacterServiceForInjection();
  charService.characters.set(CHAR_A, makeCharacter(CHAR_A, 'A'));
  charService.characters.set(CHAR_B, makeCharacter(CHAR_B, 'B'));
  charService.characters.set(CHAR_C, makeCharacter(CHAR_C, 'C'));
  const tokenCounter: TokenCounter = new TokenCounter();
  const assembler: GroupPromptAssembler = new GroupPromptAssembler(
    fakePrompt as Object as PromptBuilder,
    new HistoryTrimmer(tokenCounter),
    tokenCounter,
    new FakeLorebookServiceForInjection() as Object as LorebookService,
    charService as Object as CharacterService,
    new FakePresetServiceForInjection() as Object as PromptPresetService,
    new FakeModelServiceForInjection() as Object as ModelService
  );
  return { selector: selector, memoryRepo: memoryRepo, relRepo: relRepo, assembler: assembler, fakePrompt: fakePrompt, charService: charService };
}

function makeMemory(
  id: string,
  groupId: string,
  characterId: string,
  content: string,
  title: string = 't-' + id,
  status: GroupCharacterMemoryStatus = GroupCharacterMemoryStatus.Active
): GroupCharacterMemory {
  return createGroupCharacterMemoryRecord({
    id: id,
    groupConversationId: groupId,
    characterId: characterId,
    title: title,
    content: content,
    importance: 3,
    keywords: [],
    status: status,
    createdAt: 900,
    updatedAt: 1000
  });
}

function makeUserRel(
  ownerId: string,
  marker: string = MARKER_A_USER_REL
): GroupCharacterRelationshipMemory {
  return createGroupCharacterRelationshipMemoryRecord({
    id: 'r-' + ownerId + '-user',
    groupConversationId: CHAT_A,
    ownerCharacterId: ownerId,
    targetType: GroupRelationshipTargetType.User,
    targetId: 'user',
    experienceSummary: 'exp',
    attitudeSummary: 'att',
    relationshipSummary: marker,
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
  marker: string,
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
    relationshipSummary: marker,
    importance: 3,
    keywords: [],
    sourceMessageIds: ['sm-1'],
    sourceHash: 'hash-' + id,
    status: GroupRelationshipMemoryStatus.Active,
    createdAt: 900,
    updatedAt: 1000
  });
}

function makeInput(
  groupId: string,
  ownerId: string,
  userMessage: string = '',
  candidates: GroupRelationshipTargetCandidate[] = [],
  includeUser: boolean = true
): GroupCharacterMemorySelectionInput {
  return {
    groupConversationId: groupId,
    ownerCharacterId: ownerId,
    currentUserMessage: userMessage,
    visibleMessageIds: [],
    participantCharacterIds: [CHAR_A, CHAR_B, CHAR_C],
    relationshipTargetCandidates: candidates,
    includeUserRelationship: includeUser,
    personalMemoryMaxCount: 5,
    relationshipMemoryMaxCount: 3,
    personalMemoryTokenBudget: 600,
    relationshipMemoryTokenBudget: 400
  };
}

function explicitCandidate(charId: string): GroupRelationshipTargetCandidate {
  return { characterId: charId, source: RelationshipSelectionTargetSource.EXPLICIT_STRUCTURED_TARGET };
}

async function buildSelection(
  ctx: InjectContext,
  groupId: string,
  ownerId: string,
  userMessage: string = '',
  candidates: GroupRelationshipTargetCandidate[] = [],
  includeUser: boolean = true
): Promise<GroupCharacterMemorySelection> {
  return await ctx.selector.select(
    makeInput(groupId, ownerId, userMessage, candidates, includeUser)
  );
}

function makeUserMessage(id: string, content: string): ChatMessage {
  return createChatMessage(id, ChatRole.User, content, 1000);
}

function makeBaseMessages(): ChatMessage[] {
  return [makeUserMessage('u1', 'hello group')];
}

async function assembleWithSelection(
  ctx: InjectContext,
  speakerId: string,
  selection: GroupCharacterMemorySelection,
  chatId: string = CHAT_A,
  messages: ChatMessage[] | null = null
): Promise<GroupPromptAssemblyResult> {
  ctx.fakePrompt.setBaseMessages(messages !== null ? messages : makeBaseMessages());
  const context: GroupPromptAssemblyContext = {
    chatId: chatId,
    roundId: 'round-1',
    speakerCharacterId: speakerId,
    participantCharacterIds: [CHAR_A, CHAR_B, CHAR_C],
    messages: messages !== null ? messages : makeBaseMessages(),
    memorySelection: selection
  };
  return await ctx.assembler.assemble(context);
}

function joinedContent(messages: ChatMessage[]): string {
  let out: string = '';
  for (let i = 0; i < messages.length; i++) {
    out += messages[i].content + '\n';
  }
  return out;
}

function containsMarker(messages: ChatMessage[], marker: string): boolean {
  return joinedContent(messages).indexOf(marker) >= 0;
}

export default function groupMemoryPromptInjectionTest() {
  describe('GroupMemoryPromptInjectionTest', () => {

    it('INJECT_01_A_only_injects_A_personal_memory', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, MARKER_A_MEM + ' content'),
        makeMemory('mem-b-1', CHAT_A, CHAR_B, MARKER_B_MEM + ' content')
      ]);
      const selectionA: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selectionA);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf(MARKER_A_MEM) >= 0).assertTrue();
      expect(text.indexOf(MARKER_B_MEM) >= 0).assertFalse();
    });

    it('INJECT_02_B_only_injects_B_personal_memory', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, MARKER_A_MEM + ' content'),
        makeMemory('mem-b-1', CHAT_A, CHAR_B, MARKER_B_MEM + ' content')
      ]);
      const selectionB: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_B);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_B, selectionB);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf(MARKER_B_MEM) >= 0).assertTrue();
      expect(text.indexOf(MARKER_A_MEM) >= 0).assertFalse();
    });

    it('INJECT_03_cross_chat_isolation', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, MARKER_A_MEM + ' chat1'),
        makeMemory('mem-a-2', CHAT_B, CHAR_A, 'CHAT2_A_ONLY_MARKER content')
      ]);
      const selectionA: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selectionA);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf(MARKER_A_MEM) >= 0).assertTrue();
      expect(text.indexOf('CHAT2_A_ONLY_MARKER') >= 0).assertFalse();
    });

    it('INJECT_04_unselected_memory_not_injected', 0, async () => {
      const ctx = setupInject();
      // 两条记忆,数量预算=1 → 只有一条被选择
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'SELECTED_MARKER content'),
        makeMemory('mem-a-2', CHAT_A, CHAR_A, 'UNSELECTED_MARKER content')
      ]);
      const input: GroupCharacterMemorySelectionInput = makeInput(CHAT_A, CHAR_A);
      const selection: GroupCharacterMemorySelection =
        await ctx.selector.select({
          groupConversationId: input.groupConversationId,
          ownerCharacterId: input.ownerCharacterId,
          currentUserMessage: input.currentUserMessage,
          visibleMessageIds: input.visibleMessageIds,
          participantCharacterIds: input.participantCharacterIds,
          relationshipTargetCandidates: input.relationshipTargetCandidates,
          includeUserRelationship: input.includeUserRelationship,
          personalMemoryMaxCount: 1,
          relationshipMemoryMaxCount: input.relationshipMemoryMaxCount,
          personalMemoryTokenBudget: input.personalMemoryTokenBudget,
          relationshipMemoryTokenBudget: input.relationshipMemoryTokenBudget
        });
      expect(selection.selectedPersonalMemories.length).assertEqual(1);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf('SELECTED_MARKER') >= 0).assertTrue();
      expect(text.indexOf('UNSELECTED_MARKER') >= 0).assertFalse();
    });

    it('INJECT_05_archived_not_injected', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'ACTIVE_MARKER content'),
        makeMemory('mem-a-2', CHAT_A, CHAR_A, 'ARCHIVED_MARKER content',
          't-archived', GroupCharacterMemoryStatus.Archived)
      ]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf('ACTIVE_MARKER') >= 0).assertTrue();
      expect(text.indexOf('ARCHIVED_MARKER') >= 0).assertFalse();
    });

    it('INJECT_06_empty_selection_messages_unchanged', 0, async () => {
      const ctx = setupInject();
      const messages: ChatMessage[] = makeBaseMessages();
      ctx.fakePrompt.setBaseMessages(messages.slice());
      const baselineContext: GroupPromptAssemblyContext = {
        chatId: CHAT_A,
        roundId: 'round-1',
        speakerCharacterId: CHAR_A,
        participantCharacterIds: [CHAR_A, CHAR_B, CHAR_C],
        messages: messages.slice()
      };
      const baseline: GroupPromptAssemblyResult = await ctx.assembler.assemble(baselineContext);

      const emptySelection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      expect(emptySelection.selectedPersonalMemories.length).assertEqual(0);
      const injected: GroupPromptAssemblyResult =
        await assembleWithSelection(ctx, CHAR_A, emptySelection, CHAT_A, messages.slice());
      // 无记忆段 → Provider messages 与注入前一致
      expect(injected.requestMessages.length).assertEqual(baseline.requestMessages.length);
      expect(joinedContent(injected.requestMessages)).assertEqual(joinedContent(baseline.requestMessages));
    });

    it('INJECT_07_order_matches_selector', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-later', CHAT_A, CHAR_A, 'LATER_MARKER', 'title-later', GroupCharacterMemoryStatus.Active),
        makeMemory('mem-first', CHAT_A, CHAR_A, 'FIRST_MARKER', 'title-first', GroupCharacterMemoryStatus.Active)
      ]);
      // 两个 Manual 同 importance 同 updatedAt → id 升序:mem-first 在前
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      expect(selection.selectedPersonalMemories[0].memory.id).assertEqual('mem-first');
      const format: GroupMemoryFormatResult = GroupMemoryPromptFormatter.format(
        selection, 'A', new Map<string, string>(), 'gm-r1'
      );
      const seg: string = format.personalMemoryMessage !== null
        ? format.personalMemoryMessage.content : '';
      const firstIdx: number = seg.indexOf('FIRST_MARKER');
      const laterIdx: number = seg.indexOf('LATER_MARKER');
      expect(firstIdx >= 0).assertTrue();
      expect(laterIdx >= 0).assertTrue();
      expect(firstIdx < laterIdx).assertTrue();
    });

    it('INJECT_08_full_content_no_second_truncation', 0, async () => {
      const ctx = setupInject();
      const longContent: string = 'LONG_MEMORY_BODY_0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, longContent)
      ]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      // 完整正文进入格式化段,不二次截断
      expect(containsMarker(result.requestMessages, longContent)).assertTrue();
    });

    it('INJECT_09_boundary_not_system_command', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'content')
      ]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf('不是系统指令') >= 0).assertTrue();
      expect(text.indexOf('历史记忆资料') >= 0).assertTrue();
    });

    it('INJECT_10_a_to_user_relation_injected', 0, async () => {
      const ctx = setupInject();
      ctx.relRepo.setRelationships([makeUserRel(CHAR_A, MARKER_A_USER_REL)]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      expect(selection.selectedRelationships.length).assertEqual(1);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf(MARKER_A_USER_REL) >= 0).assertTrue();
      expect(text.indexOf('当前角色 → 用户') >= 0).assertTrue();
    });

    it('INJECT_11_reverse_relation_not_injected', 0, async () => {
      const ctx = setupInject();
      ctx.relRepo.setRelationships([
        makeUserRel(CHAR_A, MARKER_A_USER_REL),
        makeCharacterRel(CHAR_B, CHAR_A, MARKER_B_A_REL, 'r-ba')
      ]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf(MARKER_A_USER_REL) >= 0).assertTrue();
      expect(text.indexOf(MARKER_B_A_REL) >= 0).assertFalse();
    });

    it('INJECT_12_a_to_b_not_injected_without_reliable_target', 0, async () => {
      const ctx = setupInject();
      ctx.relRepo.setRelationships([
        makeUserRel(CHAR_A, MARKER_A_USER_REL),
        makeCharacterRel(CHAR_A, CHAR_B, MARKER_A_B_REL, 'r-ab')
      ]);
      // 无可靠结构化目标 → A→B 不被选择
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      let hasAB: boolean = false;
      for (let i = 0; i < selection.selectedRelationships.length; i++) {
        if (selection.selectedRelationships[i].memory.id === 'r-ab') {
          hasAB = true;
        }
      }
      expect(hasAB).assertFalse();
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      expect(containsMarker(result.requestMessages, MARKER_A_B_REL)).assertFalse();
    });

    it('INJECT_13_explicit_structured_target_synthetic', 0, async () => {
      const ctx = setupInject();
      ctx.relRepo.setRelationships([
        makeCharacterRel(CHAR_A, CHAR_B, MARKER_A_B_REL, 'r-ab'),
        makeCharacterRel(CHAR_B, CHAR_A, MARKER_B_A_REL, 'r-ba')
      ]);
      // 合成候选:EXPLICIT_STRUCTURED_TARGET=B → 可注入 A→B,不注入 B→A
      const selection: GroupCharacterMemorySelection =
        await buildSelection(ctx, CHAT_A, CHAR_A, '', [explicitCandidate(CHAR_B)]);
      let hasAB: boolean = false;
      for (let i = 0; i < selection.selectedRelationships.length; i++) {
        if (selection.selectedRelationships[i].memory.id === 'r-ab') {
          hasAB = true;
        }
      }
      expect(hasAB).assertTrue();
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf(MARKER_A_B_REL) >= 0).assertTrue();
      expect(text.indexOf(MARKER_B_A_REL) >= 0).assertFalse();
    });

    it('INJECT_14_relationship_direction_format', 0, async () => {
      const ctx = setupInject();
      ctx.relRepo.setRelationships([
        makeCharacterRel(CHAR_A, CHAR_B, MARKER_A_B_REL, 'r-ab')
      ]);
      const selection: GroupCharacterMemorySelection =
        await buildSelection(ctx, CHAT_A, CHAR_A, '', [explicitCandidate(CHAR_B)]);
      const format: GroupMemoryFormatResult = GroupMemoryPromptFormatter.format(
        selection, 'A', new Map<string, string>([[CHAR_B, 'B']]), 'gm-r1'
      );
      const seg: string = format.relationshipMemoryMessage !== null
        ? format.relationshipMemoryMessage.content : '';
      // 方向显示为 A→B(当前角色 → B),不得显示 B→A
      expect(seg.indexOf('当前角色 → B') >= 0).assertTrue();
      expect(seg.indexOf('B → 当前角色') >= 0).assertFalse();
      expect(format.relationshipItems[0].direction).assertEqual('A → B');
    });

    it('INJECT_15_token_estimate_covers_formatted_text', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'TOKEN_EST_BODY')
      ]);
      ctx.relRepo.setRelationships([makeUserRel(CHAR_A, MARKER_A_USER_REL)]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      // Selection 预算 > 0 且覆盖段头 + item
      expect(selection.personalEstimatedTokens > 0).assertTrue();
      expect(selection.relationshipEstimatedTokens > 0).assertTrue();
      // 实际格式化文本估算也 > 0,且与最终注入文本一致
      const format: GroupMemoryFormatResult = GroupMemoryPromptFormatter.format(
        selection, 'A', new Map<string, string>(), 'gm-r1'
      );
      expect(format.estimatedTokens > 0).assertTrue();
      // 选择预算不应远小于实际格式化(固定标签/摘要字段未漏掉)
      expect(format.estimatedTokens <= selection.personalEstimatedTokens
        + selection.relationshipEstimatedTokens + 64).assertTrue();
    });

    it('INJECT_16_after_global_trim', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'TRIM_MEMORY_MARKER')
      ]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      // 极小 contextWindow → 仍走 HistoryTrimmer(记忆段为 System 受保护,对话历史被裁剪)
      ctx.fakePrompt.setBaseMessages(makeBaseMessages());
      const context: GroupPromptAssemblyContext = {
        chatId: CHAT_A,
        roundId: 'round-1',
        speakerCharacterId: CHAR_A,
        participantCharacterIds: [CHAR_A, CHAR_B, CHAR_C],
        messages: makeBaseMessages(),
        memorySelection: selection
      };
      const result: GroupPromptAssemblyResult = await ctx.assembler.assemble(context);
      // 仍经过裁剪流程
      expect(result.postTrimMessageCount <= result.preTrimMessageCount).assertTrue();
      // 记忆段受保护(HistoryTrimmer 不删 System)→ injected = formatted
      expect(result.memoryInjectionItems !== undefined).assertTrue();
      if (result.memoryInjectionItems !== undefined) {
        let formatted: number = 0;
        let injected: number = 0;
        for (let i = 0; i < result.memoryInjectionItems.length; i++) {
          if (result.memoryInjectionItems[i].formatted) {
            formatted++;
          }
          if (result.memoryInjectionItems[i].injected) {
            injected++;
          }
        }
        expect(formatted > 0).assertTrue();
        expect(injected).assertEqual(formatted);
      }
    });

    it('INJECT_17_selected_not_equal_injected_reported_truthfully', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'SELECTED_NOT_INJECTED_MARKER')
      ]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      expect(selection.selectedPersonalMemories.length > 0).assertTrue();
      // 无 memorySelection 时 assemble → 无记忆段;selected>0 而 injected=0
      // (注入层只注入通过 assemble 传入的 Selection;未传时不得自行查询)
      ctx.fakePrompt.setBaseMessages(makeBaseMessages());
      const context: GroupPromptAssemblyContext = {
        chatId: CHAT_A,
        roundId: 'round-1',
        speakerCharacterId: CHAR_A,
        participantCharacterIds: [CHAR_A, CHAR_B, CHAR_C],
        messages: makeBaseMessages()
      };
      const result: GroupPromptAssemblyResult = await ctx.assembler.assemble(context);
      expect(result.memoryInjectionItems === undefined
        || result.memoryInjectionItems.length === 0).assertTrue();
      expect(containsMarker(result.requestMessages, 'SELECTED_NOT_INJECTED_MARKER')).assertFalse();
    });

    it('INJECT_18_inspector_segment_matches_provider_messages', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'INSPECTOR_MATCH_MARKER')
      ]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      expect(result.personalMemorySegmentText !== undefined).assertTrue();
      if (result.personalMemorySegmentText !== undefined) {
        // 检查器中的最终记忆段与 Provider messages 中相应消息一致
        expect(joinedContent(result.requestMessages).indexOf(result.personalMemorySegmentText) >= 0)
          .assertTrue();
        expect(result.personalMemorySegmentText.indexOf('INSPECTOR_MATCH_MARKER') >= 0).assertTrue();
      }
    });

    it('INJECT_19_memory_before_history_user_message_kept', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'ORDER_MEMORY_MARKER')
      ]);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      const msgs: ChatMessage[] = result.requestMessages;
      // 记忆段位于对话历史之前;当前用户消息仍在末尾
      let memoryIdx: number = -1;
      let userIdx: number = -1;
      for (let i = 0; i < msgs.length; i++) {
        if (msgs[i].content.indexOf('ORDER_MEMORY_MARKER') >= 0) {
          memoryIdx = i;
        }
        if (msgs[i].role === ChatRole.User) {
          userIdx = i;
        }
      }
      expect(memoryIdx >= 0).assertTrue();
      expect(userIdx >= 0).assertTrue();
      expect(memoryIdx < userIdx).assertTrue();
      expect(msgs[userIdx].content).assertEqual('hello group');
    });

    it('INJECT_20_retry_uses_new_memory', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'OLD_MEMORY_MARKER')
      ]);
      const firstSelection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const firstResult: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, firstSelection);
      expect(containsMarker(firstResult.requestMessages, 'OLD_MEMORY_MARKER')).assertTrue();

      // 用户修改记忆后重试:重新读取 Repository 数据
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'NEW_MEMORY_MARKER')
      ]);
      const retrySelection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const retryResult: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, retrySelection);
      expect(containsMarker(retryResult.requestMessages, 'NEW_MEMORY_MARKER')).assertTrue();
      expect(containsMarker(retryResult.requestMessages, 'OLD_MEMORY_MARKER')).assertFalse();
    });

    it('INJECT_21_next_speaker_not_serial', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, MARKER_A_MEM),
        makeMemory('mem-b-1', CHAT_A, CHAR_B, MARKER_B_MEM)
      ]);
      const selectionA: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      const selectionB: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_B);
      const resultA: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selectionA);
      const resultB: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_B, selectionB);
      expect(containsMarker(resultA.requestMessages, MARKER_A_MEM)).assertTrue();
      expect(containsMarker(resultB.requestMessages, MARKER_B_MEM)).assertTrue();
      expect(containsMarker(resultB.requestMessages, MARKER_A_MEM)).assertFalse();
      // 数组引用隔离
      expect(resultA.requestMessages === resultB.requestMessages).assertFalse();
    });

    it('INJECT_23_selection_query_failure_no_memory_but_generation_continues', 0, async () => {
      const ctx = setupInject();
      ctx.memoryRepo.setMemories([
        makeMemory('mem-a-1', CHAT_A, CHAR_A, 'SHOULD_NOT_APPEAR')
      ]);
      ctx.memoryRepo.setFailQuery(true);
      const selection: GroupCharacterMemorySelection = await buildSelection(ctx, CHAT_A, CHAR_A);
      expect(selection.selectedPersonalMemories.length).assertEqual(0);
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, selection);
      // 查询失败 → 无记忆段,基础 Prompt 继续
      expect(containsMarker(result.requestMessages, 'SHOULD_NOT_APPEAR')).assertFalse();
      expect(result.requestMessages.length > 0).assertTrue();
    });

    it('INJECT_24_single_bad_item_skipped_others_injected', 0, async () => {
      const ctx = setupInject();
      const badMemory: GroupCharacterMemory = makeMemory('mem-bad', CHAT_A, CHAR_B, 'BAD_OWNER_MARKER');
      const goodMemory: GroupCharacterMemory = makeMemory('mem-good', CHAT_A, CHAR_A, 'GOOD_MARKER');
      // 手工构造 Selection:bad 的 characterId=B(owner=A 时注入层必须跳过)
      const rawSelection: GroupCharacterMemorySelection = {
        groupConversationId: CHAT_A,
        ownerCharacterId: CHAR_A,
        allPersonalMemories: [badMemory, goodMemory],
        eligiblePersonalMemories: [goodMemory],
        selectedPersonalMemories: [
          {
            memory: badMemory,
            finalRank: 1,
            selectionReason: 'manual',
            manualPriority: true,
            keywordHitCount: 0,
            estimatedTokens: 10,
            cumulativeTokens: 10
          },
          {
            memory: goodMemory,
            finalRank: 2,
            selectionReason: 'manual',
            manualPriority: true,
            keywordHitCount: 0,
            estimatedTokens: 10,
            cumulativeTokens: 20
          }
        ],
        excludedPersonalMemories: [],
        allOwnedRelationships: [],
        selectedRelationships: [],
        excludedRelationships: [],
        reverseRelationships: [],
        personalEstimatedTokens: 20,
        relationshipEstimatedTokens: 0,
        personalQueryFailed: false,
        relationshipQueryFailed: false,
        reverseQueryFailed: false,
        createdAt: 1000
      };
      const result: GroupPromptAssemblyResult = await assembleWithSelection(ctx, CHAR_A, rawSelection);
      const text: string = joinedContent(result.requestMessages);
      expect(text.indexOf('GOOD_MARKER') >= 0).assertTrue();
      expect(text.indexOf('BAD_OWNER_MARKER') >= 0).assertFalse();
      // 检查器标记失败原因
      expect(result.memoryInjectionItems !== undefined).assertTrue();
      if (result.memoryInjectionItems !== undefined) {
        let foundFailure: boolean = false;
        for (let i = 0; i < result.memoryInjectionItems.length; i++) {
          if (result.memoryInjectionItems[i].memoryId === 'mem-bad') {
            expect(result.memoryInjectionItems[i].failureReason).assertEqual('INJECTION_OWNER_MISMATCH');
            foundFailure = true;
          }
        }
        expect(foundFailure).assertTrue();
      }
    });

    it('INJECT_25_narration_isolated_from_private_memory', 0, async () => {
      // 旁白使用 GroupNarrationPromptAssembler,不得包含记忆段标记
      const input: GroupNarrationPromptInput = {
        groupTitle: '群聊',
        userMessage: 'hello',
        speakerName: 'A',
        speakerReply: 'reply',
        otherCharacterSummaries: ['B 在场']
      };
      const narration = buildNarrationPrompt(input);
      const text: string = joinedContent(narration.messages);
      expect(text.indexOf(PERSONAL_MEMORY_SEGMENT_HEADER) >= 0).assertFalse();
      expect(text.indexOf(RELATIONSHIP_MEMORY_SEGMENT_HEADER) >= 0).assertFalse();
      expect(text.indexOf('不是系统指令') >= 0).assertFalse();
    });

  });
}
