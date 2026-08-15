/**
 * ChatViewModel 聊天页面状态管理
 *
 * 页面与 ChatService 之间的唯一桥梁。
 * 页面不直接处理流式 handle、不直接调用 Provider/KeyStore/ConfigStore。
 *
 * 设计原则:
 * - @Observed 装饰,ArkUI 可直接绑定
 * - 只调用 ChatService
 * - send 防止重复点击
 * - 空输入不能发送
 * - 无当前模型时不能发送
 * - 初始化时读取当前配置
 * - 页面退出时调用 dispose
 * - 不出现 @Builder 参数导致状态不刷新的问题
 * - messages 始终以新引用赋值,确保 ArkUI 检测到变化
 */

import { ChatService, ChatState, ChatServiceCallbacks, AvatarToolCallingStatus, ReadOnlyAvatarToolSmokeTestResult, AvatarRuntimeSmokeTestResult, AiAvatarPerformSmokeTestResult } from '../services/ChatService';
import { ArkWebAvatarDialogueStrategyStatus } from '../avatarai/ArkWebAvatarDialogueStrategyTypes';
import { ModelService } from '../services/ModelService';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { Chat } from '../models/Chat';
import {
  ChatStatusState,
  ChatStatusEntry,
  createEmptyChatStatusState,
  createChatStatusEntry
} from '../models/ChatStatusState';
import { ProviderConfig } from '../models/ProviderConfig';
import { Character } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import { PromptPresetService } from '../services/PromptPresetService';
import { PromptPreset } from '../models/PromptPreset';
import { Logger } from '../utils/Logger';
import { MessageSwipeSummary } from '../models/MessageSwipe';
import { TokenBudget } from '../models/TokenBudget';
import { CacheUsageStats } from '../models/ChatStreamTypes';
import {
  ConversationBranchSummary,
  ConversationRecordCounts
} from '../models/ConversationBranch';
import { ArkWebAvatarChatBridge } from '../services/avatar/ArkWebAvatarChatBridge';
import {
  ArkWebAvatarChatFinalResult,
  ArkWebAvatarChatFinalResultSource
} from '../services/avatar/ArkWebAvatarChatBridgeTypes';
import { ArkWebAvatarAiToolRegistry } from '../avatarai/ArkWebAvatarAiToolRegistry';
import { ArkWebAvatarAiToolPermissionController } from '../avatarai/ArkWebAvatarAiToolPermissionController';
import {
  ArkWebAvatarAiToolExecutor,
  ArkWebAvatarAiToolExecutorRuntime
} from '../avatarai/ArkWebAvatarAiToolExecutor';
import { ArkWebAvatarAiCapabilitySnapshot } from '../vrmviewer/ArkWebAvatarAiTypes';
import { ArkWebAvatarDialogueStrategyBuilder } from '../avatarai/ArkWebAvatarDialogueStrategyBuilder';
import { ArkWebAvatarDialogueSessionState } from '../avatarai/ArkWebAvatarDialogueSessionState';
import { ArkWebAvatarDialogueRhythmPolicy } from '../avatarai/ArkWebAvatarDialogueRhythmPolicy';
import { ArkWebAvatarToolIntegrationParams } from '../avatarai/ArkWebAvatarToolIntegration';
import { ArkWebAvatarTurnResponseCoordinator, ArkWebAvatarCapabilitySnapshotProvider } from '../avatarai/ArkWebAvatarTurnResponseCoordinator';
import {
  ArkWebAvatarFinalTurn,
  ArkWebAvatarLocalFallbackConfig,
  ArkWebAvatarTurnResponseResult
} from '../avatarai/ArkWebAvatarTurnResponseTypes';
import {
  ProviderInfoSnapshot,
  NativeToolCallingProbeResult
} from '../avatarai/NativeToolCallingCapability';

const LOG_TAG: string = 'ChatViewModel';

/**
 * Phase 4D-8: 把函数式 snapshotProvider 适配为 Coordinator 所需的接口。
 *
 * ArkWebAvatarToolIntegrationParams.snapshotProvider 是一个函数,
 * 而 Coordinator 需要实现 ArkWebAvatarCapabilitySnapshotProvider 接口的对象,
 * 用此 class 做一次薄包装。
 */
class CapabilitySnapshotProviderAdapter implements ArkWebAvatarCapabilitySnapshotProvider {
  private readonly fn: () => ArkWebAvatarAiCapabilitySnapshot | null;

  constructor(fn: () => ArkWebAvatarAiCapabilitySnapshot | null) {
    this.fn = fn;
  }

  getCapabilitySnapshot(): Object | null {
    const snapshot: ArkWebAvatarAiCapabilitySnapshot | null = this.fn();
    if (snapshot === null) {
      return null;
    }
    return snapshot;
  }
}

@Observed
export class ChatViewModel {
  messages: ChatMessage[] = [];
  /** 当前会话角色状态(CHAT-STATUS-1A) */
  statusState: ChatStatusState = createEmptyChatStatusState();
  inputText: string = '';
  isGenerating: boolean = false;
  statusMessage: string = '';
  errorMessage: string = '';
  currentModelName: string = '';
  /** 当前角色名称(无角色时为空) */
  characterName: string = '';
  /** 当前预设名称(无预设时为空) */
  currentPresetName: string = '';
  hasCurrentModel: boolean = false;
  canRegenerate: boolean = false;
  /** 用户是否主动上滑(用于控制自动滚动) */
  userScrolledUp: boolean = false;
  /** 复制提示 */
  copyToast: string = '';
  /** 会话初始化中(从数据库加载历史或创建新会话) */
  isInitializing: boolean = true;
  /** 会话已就绪(可发送/重新生成) */
  isSessionReady: boolean = false;
  /** 会话初始化失败错误信息(空表示无错误) */
  initError: string = '';
  /** Swipe 摘要列表 */
  swipeSummaries: MessageSwipeSummary[] = [];
  /** Swipe 操作进行中 */
  isSwipeOperating: boolean = false;
  /** Swipe 操作错误信息(空表示无错误) */
  swipeError: string = '';

  // ===== T-4.5 会话列表状态 =====
  /** 当前上下文的会话列表 */
  sessions: Chat[] = [];
  /** 是否显示会话列表面板 */
  showSessionList: boolean = false;
  /** 会话列表加载中 */
  isLoadingSessions: boolean = false;
  /** 会话操作进行中(新建/切换/删除) */
  isSessionOperating: boolean = false;
  /** 会话操作错误信息(空表示无错误) */
  sessionError: string = '';
  /** 待删除的会话 id(确认对话框使用) */
  pendingDeleteChatId: string = '';
  /** 是否显示删除会话确认对话框 */
  showDeleteSessionConfirm: boolean = false;

  // ===== T-6.4B-1 Branch 状态 =====
  /** 当前会话的 Branch 摘要列表 */
  branches: ConversationBranchSummary[] = [];
  /** 当前活动 Branch ID */
  activeBranchId: string = '';
  /** Branch 记录数量统计 */
  recordCounts: ConversationRecordCounts | undefined = undefined;
  /** Branch 操作进行中(创建 Child / 切换) */
  isBranchOperating: boolean = false;
  /** 是否显示 Branch 列表面板 */
  showBranchList: boolean = false;

  private chatService: ChatService;
  private modelService: ModelService;
  private characterService: CharacterService;
  private promptPresetService: PromptPresetService;
  private disposed: boolean = false;
  /**
   * Phase 4D-1: 逐轮 Avatar 回应协调器。
   *
   * 生命周期: 由 ChatViewModel 持有, 在 dispose 时销毁。
   * 职责: 按优先级选择每 Turn 的唯一 Avatar 回应来源 (Native Tool > Structured Hint > Local Fallback)。
   */
  private turnResponseCoordinator: ArkWebAvatarTurnResponseCoordinator | null = null;

  // ===== 流式 UI 节流(避免高频 delta 在同一事件循环 tick 内被 ArkUI 合并) =====
  /** setTimeout 句柄,-1 表示无 pending flush */
  private flushTimerId: number = -1;
  /** 上次 flush 时间戳(ms) */
  private lastFlushTime: number = 0;
  /** 节流间隔(ms):首次立即 flush,后续在此间隔内合并。
   *  16ms ≈ 一帧(60fps),保证每帧最多 flush 一次,既流畅又不过载 */
  private static readonly FLUSH_INTERVAL_MS: number = 16;

  /**
   * UI 状态同步回调。
   *
   * ArkUI 中 @State 持有 @Observed 对象时,ForEach 对内部数组属性变化的
   * 响应式刷新不完整。通过回调将状态同步到 ChatPage 的独立 @State 变量,
   * 确保 ForEach 能检测到数据源引用变化并重新渲染。
   */
  onMessagesUpdate?: (messages: ChatMessage[]) => void;

  /**
   * CHAT-STATUS-1A: 角色状态更新回调。
   * ChatPage 绑定此回调,把最新状态同步到独立 @State 变量以驱动状态卡片刷新。
   */
  onStatusUpdate?: (state: ChatStatusState) => void;

  constructor(
    chatService: ChatService,
    modelService: ModelService,
    characterService: CharacterService,
    promptPresetService: PromptPresetService
  ) {
    this.chatService = chatService;
    this.modelService = modelService;
    this.characterService = characterService;
    this.promptPresetService = promptPresetService;
    // Phase 4D-1: 初始化逐轮 Avatar 回应协调器
    // - 复用应用级 Bridge 单例
    // - capabilitySnapshotProvider 设为 null, 由 AI 面板后续注入
    // - 生命周期跟随 ChatViewModel, dispose 时销毁
    this.turnResponseCoordinator = new ArkWebAvatarTurnResponseCoordinator({
      bridge: ArkWebAvatarChatBridge.getInstance(),
      capabilitySnapshotProvider: null
    });
  }

  get canSend(): boolean {
    return !this.busy && this.hasCurrentModel && this.inputText.trim().length > 0
      && this.isSessionReady;
  }

  get canStop(): boolean {
    return this.isGenerating;
  }

  /**
   * T-6.3: 统一忙碌状态。
   * busy = isGenerating || isSwipeOperating || isBranchOperating
   * 会话操作(isSessionOperating)单独保护 createNewSession/selectSession/confirmDeleteSession。
   * T-6.4B-1: 增加 isBranchOperating 互斥。
   * 忙碌时禁用:Send / Regenerate / 左右 Swipe / Branch 切换 / Chat 删除 / Chat 切换 / 新建 Chat
   */
  get busy(): boolean {
    return this.isGenerating || this.isSwipeOperating || this.isBranchOperating;
  }

  /**
   * 异步初始化会话。
   *
   * 流程:
   * 1. 加载模型配置
   * 2. 加载角色(优先用 characterId,否则用全局当前角色)
   * 3. 调用 chatService.initializeSession(character) 从数据库恢复或创建新会话
   * 4. 同步 messages 到 ViewModel
   *
   * characterId 用于"为指定角色创建新对话"场景(如角色卡 Tab 左滑"新建对话"):
   * - 仅用该 ID 加载 Character 对象传给 ChatService.initializeSession
   * - 不修改全局当前角色(CharacterSelectionStore)
   * - 不影响其他 Tab 对全局当前角色的读取
   *
   * 初始化期间:
   * - isInitializing = true
   * - isSessionReady = false
   * - 禁止发送、重新生成
   *
   * 初始化成功:
   * - isInitializing = false
   * - isSessionReady = true
   * - messages 从 chatService 同步
   *
   * 初始化失败:
   * - isInitializing = false
   * - isSessionReady = false
   * - initError 设置错误信息
   * - 页面显示错误但不崩溃
   *
   * @param characterId 可选角色 ID。传入时按该 ID 加载角色;不传时用全局当前角色
   * @param forceNew 可选,true 时强制创建新会话(不恢复最近会话),用于"新建对话"入口
   */
  async initialize(characterId?: string, forceNew: boolean = false): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isInitializing = true;
    this.isSessionReady = false;
    this.initError = '';

    // 1. 加载模型配置
    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config !== null && config.enabled) {
        this.hasCurrentModel = true;
        this.currentModelName = config.name + ' · ' + config.modelName;
      } else if (config !== null && !config.enabled) {
        this.hasCurrentModel = false;
        this.currentModelName = '模型已禁用';
      } else {
        this.hasCurrentModel = false;
        this.currentModelName = '尚未配置模型';
      }
    } catch (e) {
      this.hasCurrentModel = false;
      this.currentModelName = '加载配置失败';
      Logger.error(LOG_TAG, 'initialize model config failed: ' + String(e));
    }

    // 2. 加载角色:优先用 characterId,否则用全局当前角色
    let character: Character | null = null;
    try {
      if (characterId !== undefined && characterId.length > 0) {
        character = await this.characterService.getById(characterId);
      } else {
        character = await this.characterService.getCurrentCharacter();
      }
      if (character !== null) {
        this.characterName = character.name;
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'load character failed: ' + String(e));
    }

    // 2.5. 加载当前预设名称
    await this.refreshCurrentPresetName();

    // 3. 异步初始化会话(从数据库恢复或创建新会话)
    try {
      await this.chatService.initializeSession(
        character !== null ? character : undefined,
        forceNew
      );
      // 4. 同步 messages 到 ViewModel(创建新数组引用)
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
      this.syncStatusState();
      this.isSessionReady = true;
      this.canRegenerate = this.chatService.canRegenerate();
      // T-6.4B-1: 同步 Branch 状态(branches / activeBranchId / recordCounts)
      await this.refreshBranchState();
    } catch (e) {
      // 只显示一次用户可读文案,不拼接底层错误信息(可能含敏感数据)
      const msg: string = e instanceof Error ? e.message : String(e);
      this.initError = '会话初始化失败,请重试';
      Logger.error(LOG_TAG, 'initializeSession failed: ' + msg);
    } finally {
      this.isInitializing = false;
    }
  }

  async send(): Promise<void> {
    if (this.disposed || !this.canSend) {
      return;
    }
    const content: string = this.inputText;
    if (content.trim().length === 0) {
      return;
    }
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = true;
    this.canRegenerate = false;
    this.userScrolledUp = false;

    const callbacks: ChatServiceCallbacks = this.createCallbacks();

    try {
      await this.chatService.sendMessage(content, callbacks);
      // User 消息成功加入列表后再清空输入框
      this.inputText = '';
    } catch (e) {
      // sendMessage 抛出异常(disposed 或同步错误)时恢复状态
      this.isGenerating = false;
      this.errorMessage = this.toUserError(String(e));
      this.statusMessage = '';
      Logger.error(LOG_TAG, 'send failed: ' + String(e));
    }
  }

  async regenerate(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.busy) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | busy');
      return;
    }
    if (!this.canRegenerate) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | cannot_regenerate');
      return;
    }
    if (!this.isSessionReady) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | session_not_ready');
      return;
    }
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = true;
    this.canRegenerate = false;
    this.userScrolledUp = false;

    const callbacks: ChatServiceCallbacks = this.createCallbacks();

    try {
      await this.chatService.regenerateLastResponse(callbacks);
    } catch (e) {
      this.isGenerating = false;
      this.errorMessage = this.toUserError(String(e));
      this.statusMessage = '';
      Logger.error(LOG_TAG, 'regenerate failed: ' + String(e));
    }
  }

  stop(): void {
    this.chatService.stopGeneration();
    this.isGenerating = false;
    this.statusMessage = '已停止';
    this.canRegenerate = this.chatService.canRegenerate();
    // 终态: 立即强制 flush
    this.flushMessagesNow();
  }

  clear(): void {
    this.chatService.clearConversation();
    this.messages = [];
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = false;
    this.canRegenerate = false;
    this.userScrolledUp = false;
    // 终态: 立即强制 flush(clear 立刻清空,无需等待节流)
    this.flushMessagesNow();
    // 同步清空到 ChatPage 的独立 @State 变量
    if (this.onMessagesUpdate !== undefined) {
      this.onMessagesUpdate([]);
    }
  }

  updateInput(value: string): void {
    this.inputText = value;
  }

  // ===== Swipe 方法 =====

  /**
   * 获取指定消息的 Swipe 摘要。
   * 返回 undefined 表示该消息无可操作 Swipe 或不存在。
   */
  getSwipeSummary(messageId: string): MessageSwipeSummary | undefined {
    return this.chatService.getSwipeSummary(messageId);
  }

  /**
   * 判断指定 Assistant 消息是否可操作 Swipe。
   * 生成中、Swipe 操作中、会话未就绪时均不可操作。
   */
  canOperateSwipe(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && this.isSessionReady
      && this.chatService.canOperateSwipe(messageId);
  }

  /**
   * 切换到前一个候选回复。
   * 成功切换后同步 messages 与 swipeSummaries。
   */
  async swipePrevious(messageId: string): Promise<void> {
    if (this.disposed || this.isGenerating || this.isSwipeOperating) {
      return;
    }
    this.isSwipeOperating = true;
    this.swipeError = '';
    try {
      await this.chatService.activatePreviousCandidate(messageId);
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.swipeError = this.toUserError(String(e));
      Logger.error(LOG_TAG, 'swipePrevious failed: ' + String(e));
    } finally {
      this.isSwipeOperating = false;
    }
  }

  /**
   * 切换到后一个候选回复。
   * 成功切换后同步 messages 与 swipeSummaries。
   */
  async swipeNext(messageId: string): Promise<void> {
    if (this.disposed || this.isGenerating || this.isSwipeOperating) {
      return;
    }
    this.isSwipeOperating = true;
    this.swipeError = '';
    try {
      await this.chatService.activateNextCandidate(messageId);
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.swipeError = this.toUserError(String(e));
      Logger.error(LOG_TAG, 'swipeNext failed: ' + String(e));
    } finally {
      this.isSwipeOperating = false;
    }
  }

  /**
   * 将当前最后一条回复作为新候选重新生成。
   * 使用 ChatService 内部 callbacks 同步状态变化。
   */
  async regenerateAsNewCandidate(): Promise<void> {
    await this.regenerate();
  }

  // ===== T-4.5 会话列表方法 =====

  /**
   * 打开会话列表面板。
   * 进入 Loading,加载完成后填充 sessions。
   */
  async openSessionList(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.showSessionList = true;
    this.sessionError = '';
    await this.refreshSessions();
  }

  /** 关闭会话列表面板(不取消已发起的删除确认) */
  closeSessionList(): void {
    this.showSessionList = false;
    // 关闭面板时不清除 sessionError,避免关闭瞬间闪错误提示
  }

  /** 刷新当前预设名称。页面恢复时调用。 */
  async refreshCurrentPresetName(): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      const presets: PromptPreset[] = await this.promptPresetService.getSelectedPresets();
      const names: string[] = [];
      for (let i = 0; i < presets.length; i++) {
        names.push(presets[i].name);
      }
      this.currentPresetName = names.join('、');
    } catch (e) {
      this.currentPresetName = '';
      Logger.warn(LOG_TAG, 'refresh preset name failed: ' + String(e));
    }
  }

  /** 刷新会话列表 */
  async refreshSessions(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoadingSessions = true;
    try {
      this.sessions = await this.chatService.listSessions();
    } catch (e) {
      this.sessionError = '加载会话列表失败';
      Logger.error(LOG_TAG, 'refreshSessions failed: ' + String(e));
    } finally {
      this.isLoadingSessions = false;
    }
  }

  /** 新建会话 */
  async createNewSession(): Promise<void> {
    if (this.disposed || this.isSessionOperating || this.busy) {
      return;
    }
    this.isSessionOperating = true;
    this.sessionError = '';
    try {
      await this.chatService.startNewSession();
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
      this.canRegenerate = this.chatService.canRegenerate();
      this.syncBranchState();
      this.syncStatusState();
      this.errorMessage = '';
      this.statusMessage = '';
      await this.refreshSessions();
    } catch (e) {
      this.sessionError = this.toSessionOpError(String(e));
      Logger.error(LOG_TAG, 'createNewSession failed: ' + String(e));
    } finally {
      this.isSessionOperating = false;
    }
  }

  /** 选择并切换到指定会话 */
  async selectSession(chatId: string): Promise<void> {
    if (this.disposed || this.isSessionOperating || this.busy) {
      return;
    }
    if (chatId.length === 0) {
      return;
    }
    if (this.isCurrentSession(chatId)) {
      this.showSessionList = false;
      return;
    }
    this.isSessionOperating = true;
    this.sessionError = '';
    try {
      await this.chatService.switchSession(chatId);
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
      this.canRegenerate = this.chatService.canRegenerate();
      this.syncBranchState();
      this.syncStatusState();
      this.errorMessage = '';
      this.statusMessage = '';
      this.showSessionList = false;
      await this.refreshSessions();
    } catch (e) {
      this.sessionError = this.toSessionOpError(String(e));
      Logger.error(LOG_TAG, 'selectSession failed: ' + String(e));
    } finally {
      this.isSessionOperating = false;
    }
  }

  /** 请求删除会话(显示确认对话框) */
  requestDeleteSession(chatId: string): void {
    if (this.disposed || this.isSessionOperating || this.busy) {
      return;
    }
    if (chatId.length === 0) {
      return;
    }
    this.pendingDeleteChatId = chatId;
    this.showDeleteSessionConfirm = true;
    this.sessionError = '';
  }

  /** 取消删除会话 */
  cancelDeleteSession(): void {
    this.pendingDeleteChatId = '';
    this.showDeleteSessionConfirm = false;
  }

  /** 确认删除会话 */
  async confirmDeleteSession(): Promise<void> {
    if (this.disposed || this.isSessionOperating || this.busy) {
      return;
    }
    const chatId: string = this.pendingDeleteChatId;
    if (chatId.length === 0) {
      this.showDeleteSessionConfirm = false;
      return;
    }
    this.isSessionOperating = true;
    this.showDeleteSessionConfirm = false;
    try {
      await this.chatService.deleteSession(chatId);
      // 删除可能切换了当前会话,同步 messages
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
      this.canRegenerate = this.chatService.canRegenerate();
      this.syncBranchState();
      this.syncStatusState();
      this.errorMessage = '';
      this.statusMessage = '';
      this.pendingDeleteChatId = '';
      await this.refreshSessions();
    } catch (e) {
      this.sessionError = this.toSessionOpError(String(e));
      this.pendingDeleteChatId = '';
      Logger.error(LOG_TAG, 'confirmDeleteSession failed: ' + String(e));
    } finally {
      this.isSessionOperating = false;
    }
  }

  /** 判断指定会话是否为当前会话 */
  isCurrentSession(chatId: string): boolean {
    const currentId: string | undefined = this.chatService.getCurrentChatId();
    return currentId !== undefined && currentId === chatId;
  }

  /** 会话操作按钮是否可用(生成中或操作中禁用) */
  get canOperateSessions(): boolean {
    return !this.isGenerating && !this.isSessionOperating && this.isSessionReady;
  }

  /** 获取会话标题(空 title 显示"新对话") */
  getSessionTitle(chat: Chat): string {
    return chat.title.length > 0 ? chat.title : '新对话';
  }

  /** 获取会话副标题(格式化更新时间) */
  getSessionSubtitle(chat: Chat): string {
    const ts: number = chat.lastMessageAt > 0 ? chat.lastMessageAt : chat.updatedAt;
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    const hour: string = d.getHours().toString().padStart(2, '0');
    const minute: string = d.getMinutes().toString().padStart(2, '0');
    return month + '-' + day + ' ' + hour + ':' + minute;
  }

  /** 将 ChatService 抛出的错误转换为用户可读的会话操作错误 */
  private toSessionOpError(message: string): string {
    if (message.includes('请先停止当前回复')) {
      return '请先停止当前回复';
    }
    if (message.includes('会话操作进行中')) {
      return '操作进行中,请稍候';
    }
    if (message.includes('会话不存在') || message.includes('已删除')) {
      return '会话不存在或已删除';
    }
    if (message.includes('不属于当前聊天上下文')) {
      return '会话不属于当前上下文';
    }
    if (message.includes('会话 id 为空')) {
      return '会话 id 无效';
    }
    return '会话操作失败,请重试';
  }

  /** 获取消息的状态显示文本 */
  getMessageStatusText(message: ChatMessage): string {
    if (message.role !== ChatRole.Assistant) {
      return '';
    }
    if (message.status === ChatMessageStatus.Streaming) {
      return '生成中…';
    }
    if (message.status === ChatMessageStatus.Cancelled) {
      return '已停止';
    }
    if (message.status === ChatMessageStatus.Failed) {
      return message.errorMessage !== undefined ? message.errorMessage : '生成失败';
    }
    return '';
  }

  /** 获取消息状态是否异常 */
  isMessageStatusError(message: ChatMessage): boolean {
    return message.status === ChatMessageStatus.Cancelled
      || message.status === ChatMessageStatus.Failed;
  }

  // ===== T-6.4B-1 Branch 方法 =====

  /**
   * 从 ChatService 同步 Branch 状态到 ViewModel。
   * 在会话操作和 Branch 操作后调用。
   */
  private syncBranchState(): void {
    this.branches = this.chatService.getBranches();
    this.activeBranchId = this.chatService.getActiveBranchId();
    this.recordCounts = this.chatService.getRecordCounts();
  }

  /**
   * CHAT-STATUS-1A: 从 ChatService 同步当前会话角色状态到 ViewModel 并通知 UI。
   * 会话初始化 / 新建 / 切换 / 删除后调用。
   */
  private syncStatusState(): void {
    this.statusState = this.chatService.getChatStatusState();
    if (this.onStatusUpdate !== undefined) {
      this.onStatusUpdate(this.statusState);
    }
  }

  /**
   * 刷新 Branch 状态(调用 ChatService.refreshBranchState 后同步)。
   */
  async refreshBranchState(): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.chatService.refreshBranchState();
    this.syncBranchState();
  }

  /**
   * 判断指定 Assistant 消息是否可"从此处继续"创建 Child Branch。
   * 生成中、Swipe 操作中、Branch 操作中、会话未就绪时均不可操作。
   */
  canContinueFromAssistant(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && !this.isBranchOperating
      && this.isSessionReady
      && this.chatService.canContinueFromAssistant(messageId);
  }

  /**
   * 从历史 Assistant 创建 Child Branch(从此处继续)。
   * 成功后同步 messages / swipeSummaries / branches / recordCounts。
   * 失败时通过 errorMessage 显示错误,不清空聊天。
   */
  async continueFromAssistant(messageId: string): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (!this.canContinueFromAssistant(messageId)) {
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.continueFromAssistant(messageId, callbacks);
      // 同步状态(回调可能已更新 messages,但 branches/recordCounts 需单独同步)
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '创建分支失败,请重试';
      Logger.error(LOG_TAG, 'continueFromAssistant failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  /**
   * T-6.4B-2: 判断指定 User 消息是否可"从此处生成新回复"。
   * 生成中、Swipe/Branch 操作中、会话未就绪时均不可操作。
   */
  canGenerateFromUserMessage(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && !this.isBranchOperating
      && this.isSessionReady
      && this.chatService.canGenerateFromUserMessage(messageId);
  }

  /**
   * T-6.4B-2: 从历史 User 消息生成新回复。
   * 创建新 Branch(同级或子级),在新 Branch 中创建 Streaming Assistant,启动 Provider。
   * 失败时通过 errorMessage 显示错误,不清空聊天。
   */
  async generateFromUserMessage(messageId: string): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (!this.canGenerateFromUserMessage(messageId)) {
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.generateFromUserMessage(messageId, callbacks);
      // 同步状态(回调可能已更新 messages,但 branches/recordCounts 需单独同步)
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '创建分支失败,请重试';
      Logger.error(LOG_TAG, 'generateFromUserMessage failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  /**
   * T-6.4B-3: 判断指定历史 Assistant 消息是否可"重新生成此回复"。
   * 生成中、Swipe 操作中、Branch 操作中、会话未就绪时均不可操作。
   */
  canRegenerateAssistantMessage(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && !this.isBranchOperating
      && this.isSessionReady
      && this.chatService.canRegenerateAssistantMessage(messageId);
  }

  /**
   * T-6.4B-3: 历史 Assistant "重新生成此回复"。
   * fork point 为目标 Assistant 前面的 User,新 Branch 不保留目标 Assistant 和后续历史,
   * 自动调用 Provider 生成新 Assistant。
   * 失败时通过 errorMessage 显示错误,不清空聊天。
   */
  async regenerateAssistantMessage(messageId: string): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (!this.canRegenerateAssistantMessage(messageId)) {
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.regenerateAssistantMessage(messageId, callbacks);
      // 同步状态(回调可能已更新 messages,但 branches/recordCounts 需单独同步)
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '创建分支失败,请重试';
      Logger.error(LOG_TAG, 'regenerateAssistantMessage failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  /**
   * T-6.4B-3.1: 判断指定历史 User 消息是否可"编辑"。
   * 生成中、Swipe 操作中、Branch 操作中、会话未就绪时均不可操作。
   */
  canEditUserMessage(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && !this.isBranchOperating
      && this.isSessionReady
      && this.chatService.canEditUserMessage(messageId);
  }

  /**
   * T-6.4B-3.1: 编辑历史 User Message 并创建新 Branch + Streaming Assistant。
   * fork point 为原 User 前一条消息(anchor),新 Branch 不继承原 User,
   * 插入编辑后的新 User 和新 Streaming Assistant,自动调用 Provider。
   * 失败时通过 errorMessage 显示错误,不清空聊天。
   */
  async editUserMessageAndGenerate(
    messageId: string,
    editedContent: string
  ): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (!this.canEditUserMessage(messageId)) {
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.editUserMessageAndGenerate(messageId, editedContent, callbacks);
      // 同步状态(回调可能已更新 messages,但 branches/recordCounts 需单独同步)
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '创建分支失败,请重试';
      Logger.error(LOG_TAG, 'editUserMessageAndGenerate failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  /**
   * 切换 Active Branch 到 targetBranchId。
   * 成功后同步 messages / swipeSummaries / branches / recordCounts,关闭列表面板。
   * 失败时通过 errorMessage 显示错误,保持当前页面数据不变。
   */
  async switchBranch(branchId: string): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (branchId.length === 0) {
      return;
    }
    if (branchId === this.activeBranchId) {
      this.showBranchList = false;
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.switchBranch(branchId, callbacks);
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      this.showBranchList = false;
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '切换分支失败,请重试';
      Logger.error(LOG_TAG, 'switchBranch failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  /** 打开 Branch 列表面板 */
  openBranchList(): void {
    if (this.disposed) {
      return;
    }
    this.showBranchList = true;
  }

  /** 关闭 Branch 列表面板 */
  closeBranchList(): void {
    this.showBranchList = false;
  }

  /** 获取 Branch 显示名称(Root 显示"主分支",Child 显示"分支") */
  getBranchDisplayName(branch: ConversationBranchSummary): string {
    return branch.isRoot ? '主分支' : '分支';
  }

  /** 获取 Branch 副标题(消息数 + 活动标识) */
  getBranchSubtitle(branch: ConversationBranchSummary): string {
    return branch.messageCount.toString() + ' 条消息'
      + (branch.isActive ? ' · 当前' : '');
  }

  /** 获取顶部 Branch 状态摘要文本 */
  getBranchStatusText(): string {
    if (this.recordCounts === undefined) {
      return '';
    }
    const current: number = this.recordCounts.currentBranchMessageCount;
    const total: number = this.recordCounts.totalUniqueMessageCount;
    const branches: number = this.recordCounts.totalBranchCount;
    return '当前分支 ' + current.toString() + ' 条 · 全部消息 ' + total.toString()
      + ' 条 · ' + branches.toString() + ' 个分支';
  }

  /**
   * T-6.4B-1.1: 获取当前会话 ID(供 BranchMapPage 导航使用)。
   */
  getCurrentChatId(): string | undefined {
    return this.chatService.getCurrentChatId();
  }

  /**
   * v9: 获取当前会话的对话级用户称呼覆盖(空字符串表示无覆盖)。
   * UI 在设置面板显示当前覆盖值,空字符串表示"跟随角色或全局"。
   */
  getCurrentChatUserNameOverride(): string {
    const chat: Chat | null = this.chatService.getCurrentChat();
    return chat !== null ? chat.userNameOverride : '';
  }

  /**
   * v9: 解析当前生效的用户称呼。
   * 优先级:对话覆盖 > 角色设置 > 全局设置 > 'User'。
   * UI 顶部可显示此值。
   */
  async getResolvedUserName(): Promise<string> {
    return await this.chatService.resolveUserName();
  }

  /**
   * v9: 更新当前会话的对话级用户称呼覆盖。
   * - 非空字符串:写入覆盖(仅影响当前会话)
   * - null 或空字符串:清空覆盖(回退到角色或全局)
   *
   * @param override 新的覆盖值(null 或空字符串表示清空)
   * @throws Error 当无活跃会话或更新失败时
   */
  async updateUserNameOverride(override: string | null): Promise<void> {
    await this.chatService.updateCurrentChatUserNameOverride(override);
  }

  // ===== CHAT-STATUS-1A: 角色状态字段操作 =====

  /**
   * 请求下一次回复重新生成/优化角色状态字段(由"AI 生成"按钮调用)。
   */
  requestStatusFieldGeneration(): void {
    this.chatService.requestStatusFieldGeneration();
  }

  /**
   * CHAT-STATUS-1A: 立即生成/优化角色状态字段(独立一次性请求,不写入聊天历史)。
   * @returns 是否成功生成并更新了状态
   */
  async generateStatusFields(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    const result: ChatStatusState | null = await this.chatService.generateStatusFieldsNow();
    if (result === null) {
      return false;
    }
    this.statusState = result;
    if (this.onStatusUpdate !== undefined) {
      this.onStatusUpdate(result);
    }
    return true;
  }

  /**
   * 手动添加状态字段(用户字段,fromUser=true, 默认未锁定)。
   * 同名已存在时忽略。
   */
  addStatusField(name: string): void {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return;
    }
    const entries: ChatStatusEntry[] = this.statusState.entries.slice();
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].name === trimmed) {
        return;
      }
    }
    entries.push(createChatStatusEntry(trimmed, '', true, false));
    this.chatService.updateStatusState({ entries: entries });
    this.syncStatusState();
  }

  /** 删除指定状态字段。 */
  removeStatusField(name: string): void {
    const next: ChatStatusEntry[] = [];
    const entries: ChatStatusEntry[] = this.statusState.entries;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].name !== name) {
        next.push(entries[i]);
      }
    }
    this.chatService.updateStatusState({ entries: next });
    this.syncStatusState();
  }

  /** 重命名状态字段。 */
  renameStatusField(oldName: string, newName: string): void {
    const trimmed: string = newName.trim();
    if (trimmed.length === 0 || trimmed === oldName) {
      return;
    }
    const next: ChatStatusEntry[] = [];
    const entries: ChatStatusEntry[] = this.statusState.entries;
    for (let i = 0; i < entries.length; i++) {
      const e: ChatStatusEntry = entries[i];
      if (e.name === oldName) {
        next.push(createChatStatusEntry(trimmed, e.value, e.fromUser, e.locked));
      } else {
        next.push(e);
      }
    }
    this.chatService.updateStatusState({ entries: next });
    this.syncStatusState();
  }

  /** 设置字段锁定状态(锁定后 AI 未输出也保留)。 */
  setStatusFieldLocked(name: string, locked: boolean): void {
    const next: ChatStatusEntry[] = [];
    const entries: ChatStatusEntry[] = this.statusState.entries;
    for (let i = 0; i < entries.length; i++) {
      const e: ChatStatusEntry = entries[i];
      if (e.name === name) {
        next.push(createChatStatusEntry(e.name, e.value, e.fromUser, locked));
      } else {
        next.push(e);
      }
    }
    this.chatService.updateStatusState({ entries: next });
    this.syncStatusState();
  }

  /** 手动修改字段值。 */
  setStatusFieldValue(name: string, value: string): void {
    const next: ChatStatusEntry[] = [];
    const entries: ChatStatusEntry[] = this.statusState.entries;
    for (let i = 0; i < entries.length; i++) {
      const e: ChatStatusEntry = entries[i];
      if (e.name === name) {
        next.push(createChatStatusEntry(e.name, value, e.fromUser, e.locked));
      } else {
        next.push(e);
      }
    }
    this.chatService.updateStatusState({ entries: next });
    this.syncStatusState();
  }

  /**
   * v8.1: 获取最近一次构建的请求消息(用于 UI 上下文占用估算)。
   * 反映实际发送给模型的消息(裁剪后)。
   */
  getLastBuiltRequestMessages(): ChatMessage[] | undefined {
    return this.chatService.getLastBuiltRequestMessages();
  }

  /**
   * v8.1: 获取最近一次构建的 TokenBudget(用于 UI 上下文占用显示)。
   */
  getLastTokenBudget(): TokenBudget | undefined {
    return this.chatService.getLastTokenBudget();
  }

  /**
   * T-7.x: 获取最近一次请求的缓存命中统计(DeepSeek 前缀缓存,供 UI 展示)。
   */
  getLastCacheStats(): CacheUsageStats | undefined {
    return this.chatService.getLastCacheStats();
  }

  /** T-6.4B-1.1: 是否已 dispose(供 onPop 回调安全检查) */
  get isDisposed(): boolean {
    return this.disposed;
  }

  /**
   * T-6.4B-1.1: 外部 Branch 切换后重新加载当前会话。
   *
   * 从 BranchMapPage 返回后调用,重新从数据库加载消息、SwipeSummary、Branch 状态。
   * 不执行 switchActiveBranch(已由 BranchMapPage 完成)。
   */
  async reloadAfterBranchChange(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const callbacks: ChatServiceCallbacks = this.createCallbacks();
    await this.chatService.reloadAfterExternalBranchChange(callbacks);
    this.messages = [...this.chatService.getMessages()];
    this.swipeSummaries = this.chatService.getSwipeSummaries();
    this.syncBranchState();
    this.canRegenerate = this.chatService.canRegenerate();
    if (this.onMessagesUpdate !== undefined) {
      this.onMessagesUpdate([...this.messages]);
    }
  }

  // ===== Phase 4A-3: Avatar Tool Calling 权限控制 (UI 调用入口) =====

  /**
   * Phase 4A-3: 获取 Avatar Tool Calling 状态 (供 AI 面板显示)。
   *
   * 返回 Provider 支持情况、当前权限模式、注入工具数量、能力是否就绪、
   * 最后工具名/结果/错误。
   */
  getAvatarToolCallingStatus(): AvatarToolCallingStatus {
    return this.chatService.getAvatarToolCallingStatus();
  }

  /**
   * Phase 4A-3: 设置 Avatar Tool Calling 权限模式。
   *
   * 权限降级时停止当前 AI 发起的演出, 不影响用户手动发起的演出。
   * 权限模式会持久化到 AppPreferences, 跨页面生命周期保持 (Phase 4D-6)。
   *
   * @param mode 'DENY' / 'READ_ONLY' / 'CONTROL_THIS_CHAT'
   */
  setAvatarPermissionMode(mode: string): void {
    this.chatService.setAvatarPermissionMode(mode);
  }

  /**
   * Phase 4D-6: 从 AppPreferences 加载 Avatar Tool 权限模式。
   *
   * 在 connectAvatarToolIntegration 后调用, 恢复上次的权限选择。
   * 跨页面生命周期保持权限状态。
   *
   * @returns 实际生效的权限模式
   */
  async loadAvatarPermissionMode(): Promise<string> {
    return this.chatService.loadAvatarPermissionMode();
  }

  /**
   * Phase 4D-7: 设置 Avatar 动画循环播放开关。
   *
   * enabled=true 时 avatar_perform 强制 returnPolicy=KEEP, 动画持续循环。
   * 持久化到 AppPreferences, 跨页面生命周期保持。
   *
   * 同时同步给 turnResponseCoordinator: LOCAL_FALLBACK 兜底路径不走 Executor,
   * 需由 Coordinator 自行根据此标志选择 returnPolicy=KEEP / DEFAULT_POSE。
   */
  setAvatarLoopAnimation(enabled: boolean): void {
    this.chatService.setAvatarLoopAnimation(enabled);
    if (this.turnResponseCoordinator !== null) {
      this.turnResponseCoordinator.setLoopAnimationMode(enabled);
    }
  }

  /**
   * Phase 4D-7: 从 AppPreferences 加载循环播放开关。
   *
   * 加载后同步给 turnResponseCoordinator, 确保页面初始化时 Coordinator 状态与持久化一致。
   *
   * @returns 实际生效的开关状态
   */
  async loadAvatarLoopAnimation(): Promise<boolean> {
    const enabled: boolean = await this.chatService.loadAvatarLoopAnimation();
    if (this.turnResponseCoordinator !== null) {
      this.turnResponseCoordinator.setLoopAnimationMode(enabled);
    }
    return enabled;
  }

  /**
   * Phase 4D-8: 设置"每次回复必调用动作"开关。
   *
   * enabled=true 时策略改为 REQUIRED, AI 每次回复必须调用 avatar_perform。
   * 持久化到 AppPreferences, 跨页面生命周期保持。
   *
   * 同时同步给 turnResponseCoordinator: 当 AI 未调用工具走 LOCAL_FALLBACK 兜底时,
   * 从能力快照选首个可用动画播放, 确保每次回复都有可见动画。
   */
  setAvatarAlwaysPerform(enabled: boolean): void {
    this.chatService.setAvatarAlwaysPerform(enabled);
    if (this.turnResponseCoordinator !== null) {
      this.turnResponseCoordinator.setAlwaysPerformMode(enabled);
    }
  }

  /**
   * Phase 4D-8: 从 AppPreferences 加载"每次回复必调用动作"开关。
   *
   * 加载后同步给 turnResponseCoordinator, 确保页面初始化时 Coordinator 状态与持久化一致。
   *
   * @returns 实际生效的开关状态
   */
  async loadAvatarAlwaysPerform(): Promise<boolean> {
    const enabled: boolean = await this.chatService.loadAvatarAlwaysPerform();
    if (this.turnResponseCoordinator !== null) {
      this.turnResponseCoordinator.setAlwaysPerformMode(enabled);
    }
    return enabled;
  }

  /**
   * Phase 4C-1: 获取 Avatar 对话演出策略状态摘要。
   *
   * 返回策略版本 / 模式 / 是否已注入 / 当前权限 / Provider 支持 / 能力数量 / 每 Turn 上限 / 最近错误。
   * 不包含完整系统提示词。
   */
  getAvatarDialogueStrategyStatus(): ArkWebAvatarDialogueStrategyStatus {
    return this.chatService.getAvatarDialogueStrategyStatus();
  }

  /**
   * Phase 4C-2: 获取 Avatar 对话演出节奏状态文本 (供 AI 面板简洁显示)。
   *
   * 返回多行文本:
   *   助手轮次：12
   *   距上次演出：2 轮
   *   连续演出：0
   *   最近演出：Wave
   *
   * 未注入 SessionState 时返回空字符串 (UI 隐藏该区块)。
   * 不展示完整 Prompt, 不暴露路径 / URL / resourceId。
   */
  getAvatarRhythmStatusText(): string {
    return this.chatService.getAvatarRhythmStatusText();
  }

  /**
   * Phase 4C-2: 获取 Avatar 对话演出节奏策略版本 (供 UI 显示)。
   *
   * 返回 BALANCED_V1 或空字符串 (未注入时)。
   */
  getAvatarRhythmPolicyVersion(): string {
    return this.chatService.getAvatarRhythmPolicyVersion();
  }

  /**
   * Phase 4C-2: 销毁 Avatar 对话演出会话状态 (页面 aboutToDisappear 时调用)。
   *
   * - 清空会话演出历史和当前状态
   * - 不停止用户手动发起的演出 (由 Stage 控制器负责)
   * - 不写入数据库 / Preferences / 聊天消息
   */
  disposeAvatarDialogueSessionState(): void {
    this.chatService.disposeAvatarDialogueSessionState();
  }

  // ===== Phase 4A-3R: Avatar Tool Integration 生命周期与探测 =====

  /**
   * Phase 4A-3R: 设置 Avatar Tool Integration (页面进入时调用)。
   *
   * 透传到 ChatService.setAvatarToolIntegration。
   * 任一参数为 null 时不启用 Avatar Tool Calling, 普通聊天保持原行为。
   *
   * Phase 4D-8: 同时把 snapshotProvider 注入到 turnResponseCoordinator,
   * 使 alwaysPerformMode 兜底能从能力快照选首个可用动画播放。
   */
  setAvatarToolIntegration(params: ArkWebAvatarToolIntegrationParams): void {
    this.chatService.setAvatarToolIntegration(
      params.registry,
      params.permissionController,
      params.executor,
      params.runtime,
      params.snapshotProvider,
      params.strategyBuilder,
      params.sessionState,
      params.rhythmPolicy
    );
    if (this.turnResponseCoordinator !== null) {
      if (params.snapshotProvider !== null) {
        const fn: () => ArkWebAvatarAiCapabilitySnapshot | null = params.snapshotProvider;
        this.turnResponseCoordinator.setCapabilitySnapshotProvider(
          new CapabilitySnapshotProviderAdapter(fn)
        );
      } else {
        this.turnResponseCoordinator.setCapabilitySnapshotProvider(null);
      }
    }
  }

  /**
   * Phase 4A-3R: 清空 Avatar Tool Integration (页面退出时调用)。
   *
   * - 权限恢复 DENY
   * - 清空所有依赖引用
   * - 接线状态变为 DISPOSED
   *
   * Phase 4D-8: 同时清空 Coordinator 的 capabilitySnapshotProvider。
   */
  clearAvatarToolIntegration(): void {
    this.chatService.clearAvatarToolIntegration();
    if (this.turnResponseCoordinator !== null) {
      this.turnResponseCoordinator.setCapabilitySnapshotProvider(null);
    }
  }

  /**
   * Phase 4A-3R: 获取 Tool Integration 接线状态。
   *
   * 返回: 'CONNECTED' / 'NOT_CONNECTED' / 'FAILED' / 'DISPOSED'
   */
  getAvatarToolIntegrationState(): string {
    return this.chatService.getAvatarToolIntegrationState();
  }

  /**
   * Phase 4A-3R: 获取原生 Tool Calling 四态支持状态。
   *
   * 返回: 'SUPPORTED' / 'UNSUPPORTED' / 'UNKNOWN' / 'MISCONFIGURED'
   */
  getNativeToolCallingSupport(): string {
    return this.chatService.getNativeToolCallingSupport();
  }

  /**
   * Phase 4A-3R: 获取当前 Provider 信息快照 (异步)。
   *
   * 返回: { providerType, providerDisplayName, currentModelId } (不含敏感字段)
   */
  async getProviderInfoSnapshot(): Promise<ProviderInfoSnapshot> {
    return this.chatService.getProviderInfoSnapshot();
  }

  /**
   * Phase 4A-3R: 探测当前 Provider 是否真正支持原生 Tool Calling。
   *
   * - 用户主动点击"测试 Tool Calling"按钮时调用
   * - 不写入聊天历史 / 消息数据库 / Avatar 演出历史
   * - 成功: nativeToolCallingSupport = SUPPORTED
   * - 失败: 返回详细错误码 (不会只显示"测试失败")
   */
  async probeNativeToolCalling(): Promise<NativeToolCallingProbeResult> {
    return this.chatService.probeNativeToolCalling();
  }

  /**
   * Phase 4D-2: 加载持久化的探测结果 (如有)。
   *
   * 在页面进入 / Tool Integration 接线完成时调用。
   * 仅当持久化记录有效 (adapter 版本匹配、Provider+Model 未变、未过期) 时恢复状态。
   *
   * @returns true=已加载有效记录, false=无记录或已失效
   */
  async loadPersistedProbeResult(): Promise<boolean> {
    return this.chatService.loadPersistedProbeResult();
  }

  /**
   * Phase 4D-2: 清除当前 Provider+Model 的持久化探测记录。
   *
   * 在用户主动清除验证记录时调用。
   */
  async clearPersistedProbeResult(): Promise<void> {
    await this.chatService.clearPersistedProbeResult();
  }

  /**
   * Phase 4A-3R: 运行只读 Avatar 工具烟雾测试 (avatar_get_state)。
   *
   * 前置条件: nativeToolCallingSupport === SUPPORTED 且权限为 READ_ONLY / CONTROL_THIS_CHAT。
   * 不播放动作, 不修改模型, 不写入聊天历史。
   */
  async runReadOnlyAvatarToolSmokeTest(): Promise<ReadOnlyAvatarToolSmokeTestResult> {
    return this.chatService.runReadOnlyAvatarToolSmokeTest();
  }

  /**
   * Phase 4D-4: Avatar 动画运行时测试 (不经过 AI Provider)。
   *
   * 直接构造 avatar_perform 工具调用, 测试 Tool Executor → Bridge → Lifecycle → PLAYING 链路。
   * 前置条件: 权限为 CONTROL_THIS_CHAT 且有可用动画。
   * 不经过 Provider, 不要求 nativeToolCallingSupport === SUPPORTED。
   */
  async runAvatarRuntimeSmokeTest(): Promise<AvatarRuntimeSmokeTestResult> {
    return this.chatService.runAvatarRuntimeSmokeTest();
  }

  /**
   * Phase 4D-5: Provider AI 动画调用测试 (经过真实 AI Provider)。
   *
   * 通过发送特定提示词, 让 AI 返回 avatar_perform 工具调用, 测试完整端到端链路:
   *   ChatService 请求 → Provider 收到 tools → Provider 返回 avatar_perform
   *   → Tool Executor → AvatarChatBridge → LifecycleController → PLAYING
   *
   * 前置条件:
   *   - Tool Integration 已连接
   *   - nativeToolCallingSupport === SUPPORTED
   *   - 权限为 CONTROL_THIS_CHAT
   *   - 有可用动画
   *
   * 与 runAvatarRuntimeSmokeTest 的区别: 经过真实 AI Provider, toolCallId 由 Provider 分配。
   * 与 runReadOnlyAvatarToolSmokeTest 的区别: 测试 avatar_perform (演出工具), 会实际播放动画。
   */
  async runAiAvatarPerformSmokeTest(): Promise<AiAvatarPerformSmokeTestResult> {
    return this.chatService.runAiAvatarPerformSmokeTest();
  }

  dispose(): void {
    this.disposed = true;
    // 清理 pending flush,避免页面退出后回调到旧组件
    if (this.flushTimerId !== -1) {
      clearTimeout(this.flushTimerId);
      this.flushTimerId = -1;
    }
    // Phase 4D-1: 销毁逐轮回应协调器
    // - 清空 turnId 缓存, 避免旧 Turn 延迟执行
    // - 不 dispose Bridge (应用级单例)
    if (this.turnResponseCoordinator !== null) {
      this.turnResponseCoordinator.dispose();
      this.turnResponseCoordinator = null;
    }
    this.chatService.dispose();
  }

  // ===== 流式 UI 节流实现 =====

  /**
   * 调度一次 onMessagesUpdate flush。
   *
   * 策略:leading + trailing throttle
   * - 首次调用(距上次 >= FLUSH_INTERVAL_MS)立即 flush
   * - 后续在间隔内的调用合并为一次延迟 flush
   * - 始终用 this.messages(最新状态),避免与 clear/切换会话等直接调用冲突
   */
  private scheduleMessagesFlush(): void {
    if (this.flushTimerId !== -1) {
      // 已有 pending flush,本次调用被合并,等待 flush 时读取最新 this.messages
      return;
    }
    const now: number = Date.now();
    const elapsed: number = now - this.lastFlushTime;
    if (elapsed >= ChatViewModel.FLUSH_INTERVAL_MS) {
      // 立即 flush
      this.flushMessages();
    } else {
      // 延迟到间隔结束后 flush
      const delay: number = ChatViewModel.FLUSH_INTERVAL_MS - elapsed;
      this.flushTimerId = setTimeout((): void => {
        this.flushMessages();
      }, delay);
    }
  }

  /**
   * 执行一次 flush,将最新 this.messages 同步到 ChatPage @State。
   */
  private flushMessages(): void {
    this.flushTimerId = -1;
    this.lastFlushTime = Date.now();
    if (this.disposed) {
      return;
    }
    if (this.onMessagesUpdate !== undefined) {
      this.onMessagesUpdate([...this.messages]);
    }
  }

  /**
   * 强制立即 flush(用于终态等不能等待节流的场景)。
   * - 清除 pending flush timer
   * - 立即执行一次 flush,确保最新 content/status/isStreaming 同步到 UI
   */
  private flushMessagesNow(): void {
    if (this.flushTimerId !== -1) {
      clearTimeout(this.flushTimerId);
      this.flushTimerId = -1;
    }
    this.flushMessages();
  }

  // ===== 内部方法 =====

  /**
   * 创建 ChatService 回调集合。
   * 所有回调都检查 disposed 状态,确保页面退出后不更新旧实例。
   */
  private createCallbacks(): ChatServiceCallbacks {
    return {
      onMessagesChanged: (messages: ChatMessage[]): void => {
        if (this.disposed) {
          return;
        }
        // 直接引用 ChatService 产生的新数组(不可变更新保证不会原地修改)。
        // 避免每次 delta 复制完整数组。
        this.messages = messages;
        // delta 期间不重新计算 swipeSummaries / canRegenerate:
        // - swipeSummaries 只在 Swipe 数据变化/消息完成/分支切换时更新(由终态回调统一处理)
        // - canRegenerate 只在状态变化/消息完成后更新
        // 避免高频 delta 重复扫描全历史
        this.scheduleMessagesFlush();
      },
      onStateChanged: (state: ChatState): void => {
        if (this.disposed) {
          return;
        }
        this.updateStateFromChatState(state);
      },
      onError: (message: string): void => {
        if (this.disposed) {
          return;
        }
        this.errorMessage = this.toUserError(message);
        this.statusMessage = '';
      },
      // CHAT-STATUS-1A: 角色状态变更(会话加载 / AI 合并更新 / 字段操作)
      onStatusChanged: (state: ChatStatusState): void => {
        if (this.disposed) {
          return;
        }
        this.statusState = state;
        if (this.onStatusUpdate !== undefined) {
          this.onStatusUpdate(state);
        }
      },
      // Phase 4A-2: 助手最终消息完成 → 发布到 ArkWebAvatarChatBridge
      // - turnId 使用真实 assistantMessageId (符合"来自真实消息 ID"约束)
      // - performanceHintJson 来自 ChatStreamResult.performanceHintJson 透传字段
      // - 发布失败不影响聊天文本显示 (Bridge 内部 best-effort)
      // - 不解析聊天正文生成动作 (TEXT_CONTENT_PARSING: NO)
      // - 流式 token 期间不触发 (ChatService 只在 onComplete 调用此回调)
      onAssistantMessageFinalized: (
        assistantMessageId: string,
        performanceHintJson: string,
        nativeAvatarToolAttempted: boolean,
        nativeAvatarToolExecuted: boolean
      ): void => {
        if (this.disposed) {
          return;
        }
        if (assistantMessageId.length === 0) {
          Logger.warn(LOG_TAG, 'onAssistantMessageFinalized ignored: empty assistantMessageId');
          return;
        }

        // Phase 4D-1: 通过 Coordinator 做优先级选择
        // - NATIVE_TOOL: 跳过 Hint 和 Fallback (Coordinator 不重复提交)
        // - STRUCTURED_HINT: 提交 hintJson 到 Bridge (现有路径)
        // - LOCAL_FALLBACK: 提交本地兜底演出命令到 Bridge (Coordinator 内部提交)
        // - NONE: 不提交 (每轮回应关闭)
        if (this.turnResponseCoordinator !== null) {
          const turn: ArkWebAvatarFinalTurn = {
            turnId: assistantMessageId,
            finalizedAt: Date.now(),
            nativeAvatarToolAttempted: nativeAvatarToolAttempted,
            nativeAvatarToolExecuted: nativeAvatarToolExecuted,
            performanceHintJson: performanceHintJson,
            source: ArkWebAvatarChatFinalResultSource.SINGLE_CHAT
          };
          // 异步执行,不阻塞 ChatService.onComplete 流程
          // 失败只记录轻量日志,不弹出阻塞式错误
          this.turnResponseCoordinator!.onAssistantTurnFinalized(turn).then((res: ArkWebAvatarTurnResponseResult) => {
            // 如果是 STRUCTURED_HINT, 需要由这里提交到 Bridge (Coordinator 不重复提交 Hint)
            if (res.responseSource === 'STRUCTURED_HINT' && res.submitted) {
              const bridgeResult: ArkWebAvatarChatFinalResult = {
                turnId: assistantMessageId,
                performanceHintJson: performanceHintJson,
                finalizedAt: Date.now(),
                source: ArkWebAvatarChatFinalResultSource.SINGLE_CHAT
              };
              ArkWebAvatarChatBridge.getInstance().publishFinalResult(bridgeResult).then((ok: boolean) => {
                if (!ok) {
                  Logger.warn(LOG_TAG,
                    `publishFinalResult rejected turnId=${assistantMessageId} (Bridge state or invalid input)`);
                }
              }).catch((e: Object): void => {
                Logger.warn(LOG_TAG, 'publishFinalResult threw: ' +
                  (e instanceof Error ? e.message : String(e)));
              });
            }
          }).catch((e: Object): void => {
            Logger.warn(LOG_TAG, 'onAssistantTurnFinalized threw: ' +
              (e instanceof Error ? e.message : String(e)));
          });
        } else {
          // Coordinator 未注入 (旧路径兜底): 直接提交 hintJson 到 Bridge
          const result: ArkWebAvatarChatFinalResult = {
            turnId: assistantMessageId,
            performanceHintJson: performanceHintJson,
            finalizedAt: Date.now(),
            source: ArkWebAvatarChatFinalResultSource.SINGLE_CHAT
          };
          ArkWebAvatarChatBridge.getInstance().publishFinalResult(result).then((ok: boolean) => {
            if (!ok) {
              Logger.warn(LOG_TAG,
                `publishFinalResult rejected turnId=${assistantMessageId} (Bridge state or invalid input)`);
            }
          }).catch((e: Object): void => {
            Logger.warn(LOG_TAG, 'publishFinalResult threw: ' +
              (e instanceof Error ? e.message : String(e)));
          });
        }
      }
    };
  }

  private updateStateFromChatState(state: ChatState): void {
    switch (state) {
      case ChatState.Sending:
        this.isGenerating = true;
        this.statusMessage = '发送中…';
        // T-6.4B-1.2: 重新生成创建新 Branch 后立即同步 Branch 状态,
        // 确保 UI 显示正确的分支数
        this.syncBranchState();
        break;
      case ChatState.Streaming:
        this.isGenerating = true;
        this.statusMessage = '生成中…';
        break;
      case ChatState.Completed:
        this.isGenerating = false;
        this.statusMessage = '';
        this.canRegenerate = this.chatService.canRegenerate();
        this.swipeSummaries = this.chatService.getSwipeSummaries();
        // T-6.4B-1.2: 生成完成后同步 Branch 状态(新 Branch 已持久化)
        this.syncBranchState();
        // 终态: 立即强制 flush,确保最终 content/status/isStreaming 同步到 UI
        this.flushMessagesNow();
        break;
      case ChatState.Cancelled:
        this.isGenerating = false;
        this.statusMessage = '已停止';
        this.canRegenerate = this.chatService.canRegenerate();
        this.swipeSummaries = this.chatService.getSwipeSummaries();
        this.syncBranchState();
        // 终态: 立即强制 flush
        this.flushMessagesNow();
        break;
      case ChatState.Failed:
        this.isGenerating = false;
        this.statusMessage = '';
        this.canRegenerate = this.chatService.canRegenerate();
        this.swipeSummaries = this.chatService.getSwipeSummaries();
        this.syncBranchState();
        // 终态: 立即强制 flush
        this.flushMessagesNow();
        break;
      default:
        break;
    }
  }

  private toUserError(message: string): string {
    if (message.includes('No current provider config') || message.includes('尚未配置')) {
      return '尚未配置模型,请前往模型设置';
    }
    if (message.includes('disabled')) {
      return '当前模型已禁用,请前往模型设置';
    }
    if (message.includes('model name is empty') || message.includes('model name')) {
      return '模型名称未配置,请前往模型设置选择具体模型';
    }
    if (message.includes('API Key') || message.includes('api key') || message.includes('apiKey')) {
      return 'API Key 未配置,请前往模型设置';
    }
    if (message.includes('Authentication') || message.includes('401') || message.includes('Unauthorized')) {
      return '鉴权失败,请检查 API Key 是否正确';
    }
    if (message.includes('RateLimit') || message.includes('429')) {
      return '请求频率过高,请稍后重试';
    }
    if (message.includes('Timeout') || message.includes('timeout') || message.includes('超时')) {
      return '请求超时,请检查网络后重试';
    }
    if (message.includes('Network') || message.includes('connect') || message.includes('ECONNREFUSED')) {
      return '网络连接失败,请检查网络设置';
    }
    if (message.includes('Server') || message.includes('500') || message.includes('502') || message.includes('503')) {
      return '服务器错误,请稍后重试';
    }
    if (message.includes('Parse') || message.includes('parse') || message.includes('Invalid JSON')) {
      return '响应解析失败,请重试';
    }
    if (message.includes('Cancelled') || message.includes('cancel')) {
      return '已取消';
    }
    if (message.includes('空回复')) {
      return '模型返回了空回复,请重试';
    }
    if (message.includes('disposed')) {
      return '页面已退出,请重新进入';
    }
    return '请求失败,请重试';
  }
}
