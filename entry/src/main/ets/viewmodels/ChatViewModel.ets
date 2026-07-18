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

import { ChatService, ChatState, ChatServiceCallbacks } from '../services/ChatService';
import { ModelService } from '../services/ModelService';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { Chat } from '../models/Chat';
import { ProviderConfig } from '../models/ProviderConfig';
import { Character } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import { PromptPresetService } from '../services/PromptPresetService';
import { PromptPreset } from '../models/PromptPreset';
import { Logger } from '../utils/Logger';
import { MessageSwipeSummary } from '../models/MessageSwipe';

const LOG_TAG: string = 'ChatViewModel';

@Observed
export class ChatViewModel {
  messages: ChatMessage[] = [];
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

  private chatService: ChatService;
  private modelService: ModelService;
  private characterService: CharacterService;
  private promptPresetService: PromptPresetService;
  private disposed: boolean = false;

  /**
   * UI 状态同步回调。
   *
   * ArkUI 中 @State 持有 @Observed 对象时,ForEach 对内部数组属性变化的
   * 响应式刷新不完整。通过回调将状态同步到 ChatPage 的独立 @State 变量,
   * 确保 ForEach 能检测到数据源引用变化并重新渲染。
   */
  onMessagesUpdate?: (messages: ChatMessage[]) => void;

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
   * busy = isGenerating || isSwipeOperating
   * 会话操作(isSessionOperating)单独保护 createNewSession/selectSession/confirmDeleteSession。
   * 忙碌时禁用:Send / Regenerate / 左右 Swipe / Chat 删除 / Chat 切换 / 新建 Chat
   */
  get busy(): boolean {
    return this.isGenerating || this.isSwipeOperating;
  }

  /**
   * 异步初始化会话。
   *
   * 流程:
   * 1. 加载模型配置
   * 2. 加载当前角色
   * 3. 调用 chatService.initializeSession(character) 从数据库恢复或创建新会话
   * 4. 同步 messages 到 ViewModel
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
   */
  async initialize(): Promise<void> {
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

    // 2. 加载当前角色
    let character: Character | null = null;
    try {
      character = await this.characterService.getCurrentCharacter();
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
        character !== null ? character : undefined
      );
      // 4. 同步 messages 到 ViewModel(创建新数组引用)
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
      this.isSessionReady = true;
      this.canRegenerate = this.chatService.canRegenerate();
      Logger.info(LOG_TAG, 'session ready chatId=' + this.chatService.getCurrentChatId()
        + ' messages=' + this.messages.length.toString());
    } catch (e) {
      // 只显示一次用户可读文案,不拼接底层错误信息(可能含敏感数据)
      const msg: string = e instanceof Error ? e.message : String(e);
      this.initError = '会话初始化失败,请重试';
      Logger.error(LOG_TAG, 'initializeSession failed: ' + msg);
    } finally {
      this.isInitializing = false;
    }

    Logger.info(LOG_TAG, 'initialize currentModelName=' + this.currentModelName
      + ' ready=' + this.isSessionReady.toString());
  }

  async send(): Promise<void> {
    if (this.disposed || !this.canSend) {
      return;
    }
    const content: string = this.inputText;
    if (content.trim().length === 0) {
      return;
    }
    Logger.info(LOG_TAG, 'send');
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
    Logger.info(LOG_TAG, 'Regenerate | viewmodel_enter');
    Logger.info(LOG_TAG, 'SwipeRuntime | stage=regenerate_enter');
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
  }

  clear(): void {
    this.chatService.clearConversation();
    this.messages = [];
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = false;
    this.canRegenerate = false;
    this.userScrolledUp = false;
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
    Logger.info(LOG_TAG, 'Regenerate | ui_click');
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
      const preset: PromptPreset | null = await this.promptPresetService.getCurrentPreset();
      this.currentPresetName = preset !== null ? preset.name : '';
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

  dispose(): void {
    this.disposed = true;
    this.chatService.dispose();
    Logger.info(LOG_TAG, 'dispose');
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
        // 始终创建新引用,确保 ArkUI @Observed 检测到变化
        this.messages = [...messages];
        this.swipeSummaries = this.chatService.getSwipeSummaries();
        this.canRegenerate = this.chatService.canRegenerate();
        // 同步到 ChatPage 的独立 @State 变量,确保 ForEach 响应式刷新
        // (ArkUI 中 @State 持有 @Observed 对象时,ForEach 对内部数组属性
        //  变化的响应式刷新不完整,实测日志:ForEachNode skip mark dirty)
        if (this.onMessagesUpdate !== undefined) {
          this.onMessagesUpdate([...this.messages]);
        }
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
      }
    };
  }

  private updateStateFromChatState(state: ChatState): void {
    switch (state) {
      case ChatState.Sending:
        this.isGenerating = true;
        this.statusMessage = '发送中…';
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
        break;
      case ChatState.Cancelled:
        this.isGenerating = false;
        this.statusMessage = '已停止';
        this.canRegenerate = this.chatService.canRegenerate();
        this.swipeSummaries = this.chatService.getSwipeSummaries();
        break;
      case ChatState.Failed:
        this.isGenerating = false;
        this.statusMessage = '';
        this.canRegenerate = this.chatService.canRegenerate();
        this.swipeSummaries = this.chatService.getSwipeSummaries();
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
