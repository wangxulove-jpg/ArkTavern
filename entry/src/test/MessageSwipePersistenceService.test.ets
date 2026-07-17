/**
 * MessageSwipePersistenceService 本地单元测试
 *
 * 使用 mock DbHelper、mock MessageRepository 和 mock MessageSwipeRepository 进行隔离测试。
 * 覆盖:
 * - getSwipeState 不存在/存在
 * - ensureSwipeState 角色校验(User 拒绝)
 * - ensureSwipeState 来源校验(CharacterFirstMessage/ExternalSystem/PromptPresetSystem 拒绝)
 * - ensureSwipeState 消息不存在抛 NotFound
 * - updateCandidate/activateCandidate 索引校验
 * - 输入对象不修改
 * - removeSwipeState 幂等
 * - removeByChatId 委托
 */

import { describe, it, expect } from '@ohos/hypium';
import { MessageSwipePersistenceService } from '../../main/ets/services/MessageSwipePersistenceService';
import { DbHelper } from '../../main/ets/database/DbHelper';
import { MessageRepository } from '../../main/ets/repositories/MessageRepository';
import { MessageSwipeRepository } from '../../main/ets/repositories/MessageSwipeRepository';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate,
  MessageSwipeState,
  CreateSwipeCandidateOptions,
  MessageSwipeCandidateUpdates,
  MAX_SWIPE_CANDIDATES,
  createSwipeCandidate,
  updateSwipeCandidate
} from '../../main/ets/models/MessageSwipe';
import { ChatMessage, ChatMessageStatus } from '../../main/ets/models/ChatMessage';
import { ChatRole } from '../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../main/ets/models/ChatMessageSource';
import { DatabaseError } from '../../main/ets/models/DatabaseError';

// ===== Mock DbHelper =====

class MockDbHelper {
  async runInTransaction<T>(callback: (store: Object) => Promise<T>): Promise<T> {
    return await callback({});
  }
}

// ===== Mock MessageRepository =====

class MockMessageRepository {
  private messages: Map<string, ChatMessage> = new Map();
  private chatIdMap: Map<string, string> = new Map();

  addMessage(id: string, message: ChatMessage, chatId: string): void {
    this.messages.set(id, message);
    this.chatIdMap.set(id, chatId);
  }

  clear(): void {
    this.messages.clear();
    this.chatIdMap.clear();
  }

  async getById(id: string): Promise<ChatMessage | null> {
    return this.messages.get(id) ?? null;
  }

  async getChatIdByMessageId(messageId: string): Promise<string | null> {
    return this.chatIdMap.get(messageId) ?? null;
  }
}

// ===== Mock MessageSwipeRepository =====

class MockMessageSwipeRepository {
  private groups: Map<string, MessageSwipeGroup> = new Map();
  private candidatesMap: Map<string, MessageSwipeCandidate[]> = new Map();
  private insertGroupCalls: number = 0;
  private insertCandidateCalls: number = 0;

  clear(): void {
    this.groups.clear();
    this.candidatesMap.clear();
    this.insertGroupCalls = 0;
    this.insertCandidateCalls = 0;
  }

  addState(group: MessageSwipeGroup, candidates: MessageSwipeCandidate[]): void {
    this.groups.set(group.assistantMessageId, group);
    this.candidatesMap.set(group.assistantMessageId, [...candidates]);
  }

  getInsertGroupCallCount(): number {
    return this.insertGroupCalls;
  }

  getInsertCandidateCallCount(): number {
    return this.insertCandidateCalls;
  }

  async getGroup(assistantMessageId: string): Promise<MessageSwipeGroup | null> {
    return this.groups.get(assistantMessageId) ?? null;
  }

  async listCandidates(assistantMessageId: string): Promise<MessageSwipeCandidate[]> {
    return this.candidatesMap.get(assistantMessageId) ?? [];
  }

  async getGroupWithStore(store: Object, assistantMessageId: string): Promise<MessageSwipeGroup | null> {
    return this.groups.get(assistantMessageId) ?? null;
  }

  async listCandidatesWithStore(store: Object, assistantMessageId: string): Promise<MessageSwipeCandidate[]> {
    return this.candidatesMap.get(assistantMessageId) ?? [];
  }

  async insertGroupWithStore(store: Object, group: MessageSwipeGroup): Promise<void> {
    this.groups.set(group.assistantMessageId, group);
    this.candidatesMap.set(group.assistantMessageId, []);
    this.insertGroupCalls++;
  }

  async insertCandidateWithStore(store: Object, candidate: MessageSwipeCandidate): Promise<void> {
    const list: MessageSwipeCandidate[] = this.candidatesMap.get(candidate.assistantMessageId) ?? [];
    list.push(candidate);
    this.candidatesMap.set(candidate.assistantMessageId, list);
    this.insertCandidateCalls++;
  }

  async countCandidates(assistantMessageId: string): Promise<number> {
    const list: MessageSwipeCandidate[] = this.candidatesMap.get(assistantMessageId) ?? [];
    return list.length;
  }

  async getMaxCandidateIndex(assistantMessageId: string): Promise<number> {
    const list: MessageSwipeCandidate[] = this.candidatesMap.get(assistantMessageId) ?? [];
    if (list.length === 0) {
      return -1;
    }
    let max: number = -1;
    for (const c of list) {
      if (c.candidateIndex > max) {
        max = c.candidateIndex;
      }
    }
    return max;
  }

  async updateGroupActiveIndexWithStore(
    store: Object,
    assistantMessageId: string,
    activeCandidateIndex: number,
    updatedAt: number
  ): Promise<void> {
    const existing: MessageSwipeGroup | undefined = this.groups.get(assistantMessageId);
    if (existing !== undefined) {
      this.groups.set(assistantMessageId, {
        assistantMessageId: existing.assistantMessageId,
        chatId: existing.chatId,
        activeCandidateIndex: activeCandidateIndex,
        createdAt: existing.createdAt,
        updatedAt: updatedAt
      });
    }
  }

  async getCandidateWithStore(
    store: Object,
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<MessageSwipeCandidate | null> {
    const list: MessageSwipeCandidate[] = this.candidatesMap.get(assistantMessageId) ?? [];
    for (const c of list) {
      if (c.candidateIndex === candidateIndex) {
        return c;
      }
    }
    return null;
  }

  async updateCandidateWithStore(store: Object, candidate: MessageSwipeCandidate): Promise<void> {
    const list: MessageSwipeCandidate[] = this.candidatesMap.get(candidate.assistantMessageId) ?? [];
    const idx: number = list.findIndex((c: MessageSwipeCandidate): boolean => {
      return c.candidateIndex === candidate.candidateIndex;
    });
    if (idx >= 0) {
      list[idx] = candidate;
    }
  }

  async removeByAssistantMessageId(assistantMessageId: string): Promise<void> {
    this.groups.delete(assistantMessageId);
    this.candidatesMap.delete(assistantMessageId);
  }

  async removeByChatId(chatId: string): Promise<number> {
    let count: number = 0;
    const toRemove: string[] = [];
    this.groups.forEach((group: MessageSwipeGroup, key: string): void => {
      if (group.chatId === chatId) {
        toRemove.push(key);
        count++;
      }
    });
    for (const key of toRemove) {
      this.groups.delete(key);
      this.candidatesMap.delete(key);
    }
    return count;
  }
}

// ===== Helpers =====

function makeAssistantMessage(
  id: string,
  content: string,
  source?: ChatMessageSource
): ChatMessage {
  return {
    id: id,
    role: ChatRole.Assistant,
    content: content,
    createdAt: 1000,
    source: source
  };
}

function makeUserMessage(id: string, content: string): ChatMessage {
  return {
    id: id,
    role: ChatRole.User,
    content: content,
    createdAt: 1000
  };
}

function makeGroup(overrides?: Partial<MessageSwipeGroup>): MessageSwipeGroup {
  return {
    assistantMessageId: 'msg-001',
    chatId: 'chat-001',
    activeCandidateIndex: 0,
    createdAt: 1000,
    updatedAt: 2000,
    ...overrides
  };
}

function makeCandidate(overrides?: Partial<MessageSwipeCandidate>): MessageSwipeCandidate {
  return {
    id: 'cand-001',
    assistantMessageId: 'msg-001',
    candidateIndex: 0,
    content: 'Hello, world!',
    status: ChatMessageStatus.Completed,
    errorMessage: undefined,
    isStreaming: false,
    createdAt: 1000,
    updatedAt: undefined,
    ...overrides
  };
}

function createService(): {
  dbHelper: MockDbHelper;
  messageRepo: MockMessageRepository;
  swipeRepo: MockMessageSwipeRepository;
  service: MessageSwipePersistenceService;
} {
  const dbHelper: MockDbHelper = new MockDbHelper();
  const messageRepo: MockMessageRepository = new MockMessageRepository();
  const swipeRepo: MockMessageSwipeRepository = new MockMessageSwipeRepository();
  const service: MessageSwipePersistenceService = new MessageSwipePersistenceService(
    dbHelper as unknown as DbHelper,
    messageRepo as unknown as MessageRepository,
    swipeRepo as unknown as MessageSwipeRepository
  );
  return { dbHelper, messageRepo, swipeRepo, service };
}

export default function messageSwipePersistenceServiceTest(): void {
  describe('MessageSwipePersistenceServiceTest', () => {

    // ====================================================================
    // 1. getSwipeState 不存在时返回 null
    // ====================================================================

    it('getSwipeState_returns_null_when_not_exists', 0, async () => {
      const { service } = createService();
      const result: MessageSwipeState | null = await service.getSwipeState('nonexistent');
      expect(result).assertNull();
    });

    // ====================================================================
    // 2. getSwipeState 存在时返回完整状态
    // ====================================================================

    it('getSwipeState_returns_full_state_when_exists', 0, async () => {
      const { service, swipeRepo } = createService();
      const group: MessageSwipeGroup = makeGroup();
      const candidate: MessageSwipeCandidate = makeCandidate();
      swipeRepo.addState(group, [candidate]);
      const result: MessageSwipeState | null = await service.getSwipeState('msg-001');
      expect(result).assertNotNull();
      expect(result!.group.assistantMessageId).assertEqual('msg-001');
      expect(result!.candidates.length).assertEqual(1);
      expect(result!.candidates[0].content).assertEqual('Hello, world!');
    });

    // ====================================================================
    // 3. ensureSwipeState User 消息拒绝
    // ====================================================================

    it('ensureSwipeState_rejects_user_message', 0, async () => {
      const { service, messageRepo } = createService();
      const userMsg: ChatMessage = makeUserMessage('msg-user', 'Hello');
      messageRepo.addMessage('msg-user', userMsg, 'chat-001');
      try {
        await service.ensureSwipeState('msg-user');
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(10); // InvalidData
      }
    });

    // ====================================================================
    // 4. ensureSwipeState CharacterFirstMessage 拒绝
    // ====================================================================

    it('ensureSwipeState_rejects_character_first_message', 0, async () => {
      const { service, messageRepo } = createService();
      const msg: ChatMessage = makeAssistantMessage(
        'msg-cfm', 'Hello, I am your character',
        ChatMessageSource.CharacterFirstMessage
      );
      messageRepo.addMessage('msg-cfm', msg, 'chat-001');
      try {
        await service.ensureSwipeState('msg-cfm');
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(10); // InvalidData
      }
    });

    // ====================================================================
    // 5. ensureSwipeState ExternalSystem 拒绝
    // ====================================================================

    it('ensureSwipeState_rejects_external_system', 0, async () => {
      const { service, messageRepo } = createService();
      const msg: ChatMessage = makeAssistantMessage(
        'msg-extsys', 'System instruction',
        ChatMessageSource.ExternalSystem
      );
      messageRepo.addMessage('msg-extsys', msg, 'chat-001');
      try {
        await service.ensureSwipeState('msg-extsys');
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(10); // InvalidData
      }
    });

    // ====================================================================
    // 6. ensureSwipeState PromptPresetSystem 拒绝
    // ====================================================================

    it('ensureSwipeState_rejects_prompt_preset_system', 0, async () => {
      const { service, messageRepo } = createService();
      const msg: ChatMessage = makeAssistantMessage(
        'msg-pps', 'Preset system prompt',
        ChatMessageSource.PromptPresetSystem
      );
      messageRepo.addMessage('msg-pps', msg, 'chat-001');
      try {
        await service.ensureSwipeState('msg-pps');
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(10); // InvalidData
      }
    });

    // ====================================================================
    // 7. ensureSwipeState 消息不存在抛 NotFound
    // ====================================================================

    it('ensureSwipeState_throws_not_found_when_message_missing', 0, async () => {
      const { service } = createService();
      try {
        await service.ensureSwipeState('nonexistent-msg');
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(8); // NotFound
      }
    });

    // ====================================================================
    // 8. updateCandidate 非法索引拒绝(负数)
    // ====================================================================

    it('updateCandidate_rejects_negative_index', 0, async () => {
      const { service } = createService();
      const updates: MessageSwipeCandidateUpdates = { content: 'updated' };
      try {
        await service.updateCandidate('msg-001', -1, updates);
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(10); // InvalidData
      }
    });

    // ====================================================================
    // 9. updateCandidate 非法索引拒绝(小数)
    // ====================================================================

    it('updateCandidate_rejects_float_index', 0, async () => {
      const { service } = createService();
      const updates: MessageSwipeCandidateUpdates = { content: 'updated' };
      try {
        await service.updateCandidate('msg-001', 1.5, updates);
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(10); // InvalidData
      }
    });

    // ====================================================================
    // 10. activateCandidate 非法索引拒绝(负数)
    // ====================================================================

    it('activateCandidate_rejects_negative_index', 0, async () => {
      const { service } = createService();
      try {
        await service.activateCandidate('msg-001', -1);
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(10); // InvalidData
      }
    });

    // ====================================================================
    // 11. activateCandidate 非法索引拒绝(小数)
    // ====================================================================

    it('activateCandidate_rejects_float_index', 0, async () => {
      const { service } = createService();
      try {
        await service.activateCandidate('msg-001', 2.7);
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(10); // InvalidData
      }
    });

    // ====================================================================
    // 12. appendCandidate 输入对象不修改
    // ====================================================================

    it('appendCandidate_does_not_modify_input_options', 0, async () => {
      const { service, messageRepo } = createService();
      // 先准备一条合法的 Assistant 消息
      const msg: ChatMessage = makeAssistantMessage('msg-append', 'Original reply');
      messageRepo.addMessage('msg-append', msg, 'chat-001');

      const options: CreateSwipeCandidateOptions = {
        content: 'New candidate',
        status: ChatMessageStatus.Completed,
        isStreaming: false
      };
      const originalContent: string | undefined = options.content;
      const originalStatus: ChatMessageStatus | undefined = options.status;

      await service.appendCandidate('msg-append', options, false);

      expect(options.content).assertEqual(originalContent);
      expect(options.status).assertEqual(originalStatus);
    });

    // ====================================================================
    // 13. removeSwipeState 幂等
    // ====================================================================

    it('removeSwipeState_is_idempotent', 0, async () => {
      const { service, swipeRepo } = createService();
      // 先添加一个状态
      const group: MessageSwipeGroup = makeGroup();
      const candidate: MessageSwipeCandidate = makeCandidate();
      swipeRepo.addState(group, [candidate]);

      // 第一次删除
      await service.removeSwipeState('msg-001');
      const afterFirst: MessageSwipeState | null = await service.getSwipeState('msg-001');
      expect(afterFirst).assertNull();

      // 第二次删除(幂等)
      await service.removeSwipeState('msg-001');
      const afterSecond: MessageSwipeState | null = await service.getSwipeState('msg-001');
      expect(afterSecond).assertNull();
    });

    // ====================================================================
    // 14. removeByChatId 委托给 Repository
    // ====================================================================

    it('removeByChatId_delegates_to_repository', 0, async () => {
      const { service, swipeRepo } = createService();
      const group1: MessageSwipeGroup = makeGroup({ assistantMessageId: 'msg-001', chatId: 'chat-001' });
      const group2: MessageSwipeGroup = makeGroup({ assistantMessageId: 'msg-002', chatId: 'chat-001' });
      const group3: MessageSwipeGroup = makeGroup({ assistantMessageId: 'msg-003', chatId: 'chat-002' });
      swipeRepo.addState(group1, [makeCandidate({ assistantMessageId: 'msg-001' })]);
      swipeRepo.addState(group2, [makeCandidate({ assistantMessageId: 'msg-002' })]);
      swipeRepo.addState(group3, [makeCandidate({ assistantMessageId: 'msg-003' })]);

      const removed: number = await service.removeByChatId('chat-001');
      expect(removed).assertEqual(2);

      const state1: MessageSwipeState | null = await service.getSwipeState('msg-001');
      const state2: MessageSwipeState | null = await service.getSwipeState('msg-002');
      const state3: MessageSwipeState | null = await service.getSwipeState('msg-003');
      expect(state1).assertNull();
      expect(state2).assertNull();
      expect(state3).assertNotNull();
    });

    // ====================================================================
    // 15. ensureSwipeState 合法 Assistant 消息创建成功
    // ====================================================================

    it('ensureSwipeState_creates_state_for_valid_assistant_message', 0, async () => {
      const { service, messageRepo, swipeRepo } = createService();
      const msg: ChatMessage = makeAssistantMessage('msg-valid', 'Valid assistant reply');
      messageRepo.addMessage('msg-valid', msg, 'chat-001');

      const state: MessageSwipeState = await service.ensureSwipeState('msg-valid');
      expect(state).assertNotNull();
      expect(state.group.assistantMessageId).assertEqual('msg-valid');
      expect(state.group.chatId).assertEqual('chat-001');
      expect(state.group.activeCandidateIndex).assertEqual(0);
      expect(state.candidates.length).assertEqual(1);
      expect(state.candidates[0].content).assertEqual('Valid assistant reply');
      expect(state.candidates[0].candidateIndex).assertEqual(0);
    });

    // ====================================================================
    // 16. ensureSwipeState 幂等:重复调用返回相同状态
    // ====================================================================

    it('ensureSwipeState_is_idempotent', 0, async () => {
      const { service, messageRepo } = createService();
      const msg: ChatMessage = makeAssistantMessage('msg-idemp', 'Idempotent test');
      messageRepo.addMessage('msg-idemp', msg, 'chat-001');

      const state1: MessageSwipeState = await service.ensureSwipeState('msg-idemp');
      const state2: MessageSwipeState = await service.ensureSwipeState('msg-idemp');

      expect(state2.group.assistantMessageId).assertEqual('msg-idemp');
      expect(state2.candidates.length).assertEqual(1);
      // 两次返回的 group 应一致(幂等)
      expect(state2.group.activeCandidateIndex).assertEqual(state1.group.activeCandidateIndex);
    });

    // ====================================================================
    // 17. ensureSwipeState 旧数据 undefined source 视为 Conversation 通过
    // ====================================================================

    it('ensureSwipeState_accepts_undefined_source_as_conversation', 0, async () => {
      const { service, messageRepo } = createService();
      // source 为 undefined 的旧数据
      const msg: ChatMessage = {
        id: 'msg-old',
        role: ChatRole.Assistant,
        content: 'Old data without source',
        createdAt: 500
      };
      messageRepo.addMessage('msg-old', msg, 'chat-001');

      const state: MessageSwipeState = await service.ensureSwipeState('msg-old');
      expect(state).assertNotNull();
      expect(state.candidates.length).assertEqual(1);
    });
  });
}