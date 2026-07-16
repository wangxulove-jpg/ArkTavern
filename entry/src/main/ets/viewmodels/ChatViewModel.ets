/**
 * ChatViewModel 聊天 ViewModel
 *
 * 管理聊天页面的 UI 状态,作为 ChatPage 与 ChatService 之间的唯一桥梁。
 *
 * 设计原则:
 * - 只调用 ChatService,不直接操作 ModelService/Provider/KeyStore
 * - 页面不直接处理流式 handle
 * - 防重复发送、空输入拒绝
 * - 初始化时读取当前配置信息
 * - 退出时调用 dispose
 * - 不使用全局单例、不使用 any
 * - 不通过 @Builder 参数传递 ViewModel(直接 @State 绑定)
 */

import { ChatService, ChatState, ChatServiceCallbacks } from '../services/ChatService';
import { ChatMessage } from '../models/ChatMessage';
import { ModelService } from '../services/ModelService';
import { ProviderConfig } from '../models/ProviderConfig';
import { Logger } from '../utils/Logger';
import { NetworkErrorType } from '../models/NetworkError';

const LOG_TAG: string = 'ChatVM';

/**
 * 聊天 ViewModel。
 * 使用 @Observed 装饰,使页面能响应字段变更。
 */
@Observed
export class ChatViewModel {
  // ===== 消息 =====
  messages: ChatMessage[] = [];

  // ===== 输入 =====
  inputText: string = '';

  // ===== 状态 =====
  isGenerating: boolean = false;
  statusMessage: string = '';
  errorMessage: string = '';

  // ===== 模型信息 =====
  currentModelName: string = '';
  hasCurrentModel: boolean = false;

  // ===== 计算属性 =====
  get canSend(): boolean {
    return !this.isGenerating && this.hasCurrentModel && this.inputText.trim().length > 0;
  }

  private chatService: ChatService;
  private modelService: ModelService;
  private disposed: boolean = false;

  constructor(chatService: ChatService, modelService: ModelService) {
    this.chatService = chatService;
    this.modelService = modelService;
  }

  async initialize(): Promise<void> {
    Logger.info(LOG_TAG, 'initialize');
    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config !== null) {
        this.hasCurrentModel = true;
        this.currentModelName = config.name + ' · ' + config.modelName;
      } else {
        this.hasCurrentModel = false;
        this.currentModelName = '尚未配置模型';
      }
    } catch (e) {
      this.hasCurrentModel = false;
      this.currentModelName = '加载模型配置失败';
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
    Logger.info(LOG_TAG, 'send');
    this.inputText = '';
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = true;

    const callbacks: ChatServiceCallbacks = {
      onMessagesChanged: (messages: ChatMessage[]): void => {
        if (this.disposed) {
          return;
        }
        this.messages = messages;
      },
      onStateChanged: (state: ChatState): void => {
        if (this.disposed) {
          return;
        }
        switch (state) {
          case ChatState.Sending:
            this.isGenerating = true;
            this.statusMessage = '正在发送…';
            break;
          case ChatState.Streaming:
            this.isGenerating = true;
            this.statusMessage = '';
            break;
          case ChatState.Completed:
            this.isGenerating = false;
            this.statusMessage = '';
            break;
          case ChatState.Cancelled:
            this.isGenerating = false;
            this.statusMessage = '';
            break;
          case ChatState.Failed:
            this.isGenerating = false;
            this.statusMessage = '';
            break;
          case ChatState.Idle:
            this.isGenerating = false;
            this.statusMessage = '';
            break;
        }
      },
      onError: (message: string): void => {
        if (this.disposed) {
          return;
        }
        this.errorMessage = this.toUserError(message);
        this.isGenerating = false;
      }
    };

    try {
      await this.chatService.sendMessage(content, callbacks);
    } catch (e) {
      if (this.disposed) {
        return;
      }
      this.errorMessage = this.toUserError(String(e));
      this.isGenerating = false;
    }
  }

  stop(): void {
    if (this.disposed) {
      return;
    }
    Logger.info(LOG_TAG, 'stop');
    this.chatService.stopGeneration();
  }

  clear(): void {
    if (this.disposed) {
      return;
    }
    Logger.info(LOG_TAG, 'clear');
    this.chatService.clearConversation();
    this.messages = [];
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = false;
  }

  updateInput(value: string): void {
    this.inputText = value;
  }

  dispose(): void {
    this.disposed = true;
    this.chatService.dispose();
    Logger.info(LOG_TAG, 'dispose');
  }

  /**
   * 前往模型设置(由页面调用路径跳转)。
   */
  goToModelSettings(): void {
    // 页面处理路径跳转,ViewModel 仅提供语义方法
  }

  private toUserError(message: string): string {
    if (message.includes('No current provider config')) {
      return '尚未配置模型,请前往模型设置';
    }
    if (message.includes('disabled')) {
      return '当前模型已禁用,请前往模型设置切换';
    }
    if (message.includes('hasApiKey') || message.includes('API Key')) {
      return 'API Key 未配置,请前往模型设置配置';
    }
    if (message.includes('Unsupported provider')) {
      return '当前 Provider 类型暂未支持';
    }
    if (message.includes('Authentication') || message.includes('401') || message.includes('auth')) {
      return '鉴权失败,请检查 API Key 是否正确';
    }
    if (message.includes('RateLimit') || message.includes('429')) {
      return '请求频率过高,请稍后重试';
    }
    if (message.includes('Timeout') || message.includes('timeout')) {
      return '请求超时,请检查网络或 Base URL';
    }
    if (message.includes('Network') || message.includes('network') || message.includes('connect')) {
      return '网络连接失败,请检查网络或 Base URL';
    }
    if (message.includes('Server') || message.includes('500') || message.includes('502')) {
      return '服务器错误,请稍后重试';
    }
    if (message.includes('Parse') || message.includes('parse')) {
      return '响应解析失败,请确认 Base URL 正确';
    }
    if (message.includes('model name is empty') || message.includes('model name')) {
      return '模型名称未配置,请前往模型设置选择具体模型';
    }
    if (message.includes('Cancelled') || message.includes('cancel')) {
      return '已取消';
    }
    return '请求失败,请重试';
  }
}