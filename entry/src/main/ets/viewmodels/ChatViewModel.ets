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
import { ProviderConfig } from '../models/ProviderConfig';
import { Character } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import { Logger } from '../utils/Logger';

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

  private chatService: ChatService;
  private modelService: ModelService;
  private characterService: CharacterService;
  private disposed: boolean = false;

  /**
   * UI 状态同步回调。
   *
   * ArkUI 中 @State 持有 @Observed 对象时,ForEach 对内部数组属性变化的
   * 响应式刷新不完整。通过回调将状态同步到 ChatPage 的独立 @State 变量,
   * 确保 ForEach 能检测到数据源引用变化并重新渲染。
   */
  onMessagesUpdate?: (messages: ChatMessage[]) => void;

  constructor(chatService: ChatService, modelService: ModelService, characterService: CharacterService) {
    this.chatService = chatService;
    this.modelService = modelService;
    this.characterService = characterService;
  }

  get canSend(): boolean {
    return !this.isGenerating && this.hasCurrentModel && this.inputText.trim().length > 0
      && this.isSessionReady;
  }

  get canStop(): boolean {
    return this.isGenerating;
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
      const msg: string = e instanceof Error ? e.message : String(e);
      this.initError = '会话初始化失败: ' + msg;
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
    if (this.disposed || this.isGenerating || !this.canRegenerate || !this.isSessionReady) {
      return;
    }
    Logger.info(LOG_TAG, 'regenerate');
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
        break;
      case ChatState.Cancelled:
        this.isGenerating = false;
        this.statusMessage = '已停止';
        this.canRegenerate = this.chatService.canRegenerate();
        break;
      case ChatState.Failed:
        this.isGenerating = false;
        this.statusMessage = '';
        this.canRegenerate = this.chatService.canRegenerate();
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
