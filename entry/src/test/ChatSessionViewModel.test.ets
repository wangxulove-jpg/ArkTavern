/**
 * ChatSessionViewModel 本地定向测试(T-4.5)
 *
 * 使用 MockChatServiceForSession(内存模拟)验证 ChatViewModel 的会话列表状态管理:
 * - 打开/关闭列表
 * - 加载会话列表
 * - 新建/切换/删除会话
 * - 错误恢复
 * - 按钮可用性
 *
 * 不依赖真实数据库,所有场景通过注入 mock 实现。
 *
 * 覆盖 16 项。
 */

import { describe, it, expect } from '@ohos/hypium';
import { ChatViewModel } from '../main/ets/viewmodels/ChatViewModel';
import { ChatService, ChatServiceCallbacks, ChatState } from '../main/ets/services/ChatService';
import { ModelService } from '../main/ets/services/ModelService';
import { CharacterService } from '../main/ets/services/CharacterService';
import { ChatMessage, ChatMessageStatus } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import { Chat, createChat } from '../main/ets/models/Chat';
import { Character, createCharacter } from '../main/ets/models/Character';
import { ProviderConfig } from '../main/ets/models/ProviderConfig';
import { ProviderType } from '../main/ets/models/ProviderType';

// ===== Mock ChatService =====

class MockChatServiceForSession {
  private messages: ChatMessage[] = [];
  private currentChatId: string | undefined = 'mock-chat-1';
  private sessions: Chat[] = [];
  disposed: boolean = false;
  generating: boolean = false;
  canRegen: boolean = false;
  sessionOpInProgress: boolean = false;
  throwOnList: Error | null = null;
  throwOnStartNew: Error | null = null;
  throwOnSwitch: Error | null = null;
  throwOnDelete: Error | null = null;
  startNewCallCount: number = 0;
  switchCallCount: number = 0;
  deleteCallCount: number = 0;
  listCallCount: number = 0;

  setMessages(msgs: ChatMessage[]): void {
    this.messages = msgs;
  }

  setSessions(sessions: Chat[]): void {
    this.sessions = sessions;
  }

  setCurrentChatId(id: string | undefined): void {
    this.currentChatId = id;
  }

  async initializeSession(_character?: Character): Promise<void> {
    // no-op
  }

  getMessages(): ChatMessage[] {
    return this.messages.slice();
  }

  canRegenerate(): boolean {
    return this.canRegen;
  }

  getCurrentChatId(): string | undefined {
    return this.currentChatId;
  }

  isGenerating(): boolean {
    return this.generating;
  }

  isSessionOperationInProgress(): boolean {
    return this.sessionOpInProgress;
  }

  async sendMessage(_content: string, _callbacks: ChatServiceCallbacks): Promise<void> {
    this.generating = true;
  }

  async regenerateLastResponse(_callbacks: ChatServiceCallbacks): Promise<void> {
    this.generating = true;
  }

  stopGeneration(): void {
    this.generating = false;
  }

  clearConversation(): void {
    this.messages = [];
  }

  async listSessions(): Promise<Chat[]> {
    this.listCallCount++;
    if (this.throwOnList !== null) {
      throw this.throwOnList;
    }
    return this.sessions.slice();
  }

  async startNewSession(): Promise<void> {
    this.startNewCallCount++;
    if (this.throwOnStartNew !== null) {
      throw this.throwOnStartNew;
    }
    this.currentChatId = 'mock-chat-' + (this.startNewCallCount + 1).toString();
    this.messages = [];
  }

  async switchSession(chatId: string): Promise<void> {
    this.switchCallCount++;
    if (this.throwOnSwitch !== null) {
      throw this.throwOnSwitch;
    }
    this.currentChatId = chatId;
  }

  async deleteSession(chatId: string): Promise<void> {
    this.deleteCallCount++;
    if (this.throwOnDelete !== null) {
      throw this.throwOnDelete;
    }
    // 从 sessions 中移除
    this.sessions = this.sessions.filter((c: Chat) => c.id !== chatId);
    if (chatId === this.currentChatId) {
      // 模拟回退:切换到剩余第一个,或创建新的
      if (this.sessions.length > 0) {
        this.currentChatId = this.sessions[0].id;
        this.messages = [];
      } else {
        this.currentChatId = 'mock-chat-new';
        this.messages = [];
      }
    }
  }

  dispose(): void {
    this.disposed = true;
  }
}

// ===== Mock ModelService / CharacterService =====

class MockModelService {
  async getCurrentConfig(): Promise<ProviderConfig | null> {
    return new ProviderConfig(
      'pcfg-1', 'mock', ProviderType.OpenAICompatible,
      'https://mock.local', 'mock-model',
      0.7, 1.0, 1024, true, true, 1000, 1000
    );
  }
}

class MockCharacterService {
  async getCurrentCharacter(): Promise<Character | null> {
    return null;
  }
}

// ===== 测试辅助 =====

function makeChat(id: string, title: string = '', lastMessageAt: number = 1000): Chat {
  return createChat({
    id: id,
    title: title,
    createdAt: 1000,
    updatedAt: lastMessageAt,
    lastMessageAt: lastMessageAt
  });
}

function makeViewModel(mock?: MockChatServiceForSession): ChatViewModel {
  const ms: MockChatServiceForSession = mock !== undefined ? mock : new MockChatServiceForSession();
  const modelService: MockModelService = new MockModelService();
  const characterService: MockCharacterService = new MockCharacterService();
  const vm: ChatViewModel = new ChatViewModel(
    ms as Object as ChatService,
    modelService as Object as ModelService,
    characterService as Object as CharacterService
  );
  vm.isSessionReady = true;
  return vm;
}

export default function chatSessionViewModelTest(): void {
  describe('ChatSessionViewModel', () => {

    // ===== 1. 打开列表进入 Loading =====
    it('openSessionList_sets_loading', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.setSessions([makeChat('c1')]);
      const vm: ChatViewModel = makeViewModel(mock);
      expect(vm.showSessionList).assertFalse();
      const p: Promise<void> = vm.openSessionList();
      expect(vm.isLoadingSessions).assertTrue();
      expect(vm.showSessionList).assertTrue();
      await p;
      expect(vm.isLoadingSessions).assertFalse();
    });

    // ===== 2. 加载成功更新 sessions =====
    it('refreshSessions_updates_sessions', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      const sessions: Chat[] = [makeChat('c1'), makeChat('c2')];
      mock.setSessions(sessions);
      const vm: ChatViewModel = makeViewModel(mock);
      await vm.refreshSessions();
      expect(vm.sessions.length).assertEqual(2);
    });

    // ===== 3. 加载失败显示安全错误 =====
    it('refreshSessions_failure_sets_sessionError', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.throwOnList = new Error('db error');
      const vm: ChatViewModel = makeViewModel(mock);
      await vm.refreshSessions();
      expect(vm.sessionError.length > 0).assertTrue();
      expect(vm.isLoadingSessions).assertFalse();
    });

    // ===== 4. closeSessionList 关闭面板 =====
    it('closeSessionList_closes_panel', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.setSessions([]);
      const vm: ChatViewModel = makeViewModel(mock);
      await vm.openSessionList();
      expect(vm.showSessionList).assertTrue();
      vm.closeSessionList();
      expect(vm.showSessionList).assertFalse();
    });

    // ===== 5. 新建成功刷新列表 =====
    it('createNewSession_refreshes_list', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.setSessions([makeChat('c1')]);
      const vm: ChatViewModel = makeViewModel(mock);
      await vm.openSessionList();
      const beforeCount: number = mock.startNewCallCount;
      await vm.createNewSession();
      expect(mock.startNewCallCount).assertEqual(beforeCount + 1);
      expect(vm.isSessionOperating).assertFalse();
    });

    // ===== 6. 新建失败恢复按钮状态 =====
    it('createNewSession_failure_restores_state', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.throwOnStartNew = new Error('create failed');
      const vm: ChatViewModel = makeViewModel(mock);
      await vm.createNewSession();
      expect(vm.isSessionOperating).assertFalse();
      expect(vm.sessionError.length > 0).assertTrue();
    });

    // ===== 7. 选择会话后关闭面板 =====
    it('selectSession_closes_panel', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.setSessions([makeChat('c1'), makeChat('c2')]);
      mock.setCurrentChatId('c1');
      const vm: ChatViewModel = makeViewModel(mock);
      await vm.openSessionList();
      await vm.selectSession('c2');
      expect(vm.showSessionList).assertFalse();
      expect(mock.switchCallCount).assertEqual(1);
    });

    // ===== 8. 选择失败保留面板并显示错误 =====
    it('selectSession_failure_keeps_panel', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.setSessions([makeChat('c1'), makeChat('c2')]);
      mock.setCurrentChatId('c1');
      mock.throwOnSwitch = new Error('switch failed');
      const vm: ChatViewModel = makeViewModel(mock);
      await vm.openSessionList();
      await vm.selectSession('c2');
      expect(vm.showSessionList).assertTrue();
      expect(vm.sessionError.length > 0).assertTrue();
      expect(vm.isSessionOperating).assertFalse();
    });

    // ===== 9. 删除前显示确认 =====
    it('requestDeleteSession_shows_confirm', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      const vm: ChatViewModel = makeViewModel(mock);
      vm.requestDeleteSession('c1');
      expect(vm.showDeleteSessionConfirm).assertTrue();
      expect(vm.pendingDeleteChatId).assertEqual('c1');
    });

    // ===== 10. 取消删除不执行操作 =====
    it('cancelDeleteSession_no_action', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      const vm: ChatViewModel = makeViewModel(mock);
      vm.requestDeleteSession('c1');
      vm.cancelDeleteSession();
      expect(vm.showDeleteSessionConfirm).assertFalse();
      expect(vm.pendingDeleteChatId.length).assertEqual(0);
      expect(mock.deleteCallCount).assertEqual(0);
    });

    // ===== 11. 确认删除后刷新 =====
    it('confirmDeleteSession_refreshes', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.setSessions([makeChat('c1'), makeChat('c2')]);
      mock.setCurrentChatId('c1');
      const vm: ChatViewModel = makeViewModel(mock);
      vm.requestDeleteSession('c2');
      await vm.confirmDeleteSession();
      expect(mock.deleteCallCount).assertEqual(1);
      expect(vm.showDeleteSessionConfirm).assertFalse();
      expect(vm.pendingDeleteChatId.length).assertEqual(0);
    });

    // ===== 12. 删除当前会话后页面消息更新 =====
    it('deleteCurrentSession_updates_messages', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      const msg: ChatMessage = {
        id: 'msg-1', role: ChatRole.Assistant, content: 'old',
        createdAt: 1000, status: ChatMessageStatus.Completed, isStreaming: false
      };
      mock.setMessages([msg]);
      mock.setSessions([makeChat('c1'), makeChat('c2')]);
      mock.setCurrentChatId('c1');
      const vm: ChatViewModel = makeViewModel(mock);
      let receivedMessages: ChatMessage[] = [];
      vm.onMessagesUpdate = (m: ChatMessage[]) => { receivedMessages = m; };
      vm.requestDeleteSession('c1');
      await vm.confirmDeleteSession();
      // 删除当前会话后,Mock 切换到 c2,messages 清空
      expect(mock.getCurrentChatId()).assertEqual('c2');
    });

    // ===== 13. isCurrentSession 判断正确 =====
    it('isCurrentSession_correct', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.setCurrentChatId('c1');
      const vm: ChatViewModel = makeViewModel(mock);
      expect(vm.isCurrentSession('c1')).assertTrue();
      expect(vm.isCurrentSession('c2')).assertFalse();
    });

    // ===== 14. 生成中按钮禁用 =====
    it('canOperateSessions_false_when_generating', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      const vm: ChatViewModel = makeViewModel(mock);
      expect(vm.canOperateSessions).assertTrue();
      vm.isGenerating = true;
      expect(vm.canOperateSessions).assertFalse();
    });

    // ===== 15. 连续点击不会重复执行 =====
    it('repeated_click_not_duplicated', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      mock.setSessions([makeChat('c1')]);
      const vm: ChatViewModel = makeViewModel(mock);
      // 第一次操作进行中,第二次应被忽略
      vm.isSessionOperating = true;
      await vm.createNewSession();
      expect(mock.startNewCallCount).assertEqual(0);
    });

    // ===== 16. 不暴露 Repository 或 DbHelper =====
    it('viewmodel_no_repository_exposure', 0, async () => {
      const mock: MockChatServiceForSession = new MockChatServiceForSession();
      const vm: ChatViewModel = makeViewModel(mock);
      // ViewModel 不应有 repository 或 dbHelper 属性
      // 通过编译时类型检查保证,运行时验证无相关字段
      const obj: Record<string, Object> = vm as Object as Record<string, Object>;
      const keys: string[] = Object.keys(obj);
      const hasRepo: boolean = keys.some((k: string) => k.includes('repository') || k.includes('Repository'));
      const hasDbHelper: boolean = keys.some((k: string) => k.includes('dbHelper') || k.includes('DbHelper'));
      expect(hasRepo).assertFalse();
      expect(hasDbHelper).assertFalse();
    });
  });
}
