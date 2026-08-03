/**
 * GroupChatSettingsViewModel 群聊设置状态管理(G-DATA-1B / G-RUNTIME-1A)
 *
 * 职责:
 * - 读取真实群聊信息(标题)
 * - 调用 GroupConversationPersistenceService 重命名
 * - 调用 GroupConversationPersistenceService 删除群聊
 * - 调用 GroupConversationMessageService 清空群聊消息(G-RUNTIME-1A)
 *
 * 不依赖:
 * - GroupChatPreviewStore
 * - GroupFailurePolicy(本阶段无正式 Schema,不持久化)
 *
 * 本阶段不持久化:
 * - 失败处理策略
 * - 自动回复模式
 * - 连续聊天
 * - 随机回复
 */

import { Chat } from '../../models/Chat';
import { GroupConversationPersistenceService } from '../../services/groupchat/GroupConversationPersistenceService';
import { GroupConversationMessageService } from '../../services/groupchat/GroupConversationMessageService';
import { GroupChatRuntimeService } from '../../services/groupchat/GroupChatRuntimeService';
import { AppServices } from '../../services/AppServices';
import { Logger } from '../../utils/Logger';
import { GroupChatDetailState } from './GroupChatUiModels';

const LOG_TAG: string = 'GroupChatSettingsVM';

@Observed
export class GroupChatSettingsViewModel {
  /** 当前群聊 ID */
  chatId: string = '';
  /** 当前群聊标题 */
  title: string = '';
  /** 详情页状态 */
  state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 是否正在重命名 */
  isRenaming: boolean = false;
  /** 是否正在删除 */
  isDeleting: boolean = false;
  /** 是否正在清空消息 */
  isClearing: boolean = false;
  /** G-RUNTIME-1C: 是否正在生成(生成中禁止清空/删除) */
  isGenerating: boolean = false;

  private readonly groupService: GroupConversationPersistenceService;
  private readonly messageService: GroupConversationMessageService;
  private readonly runtimeService: GroupChatRuntimeService;
  private disposed: boolean = false;

  constructor() {
    this.groupService = AppServices.getGroupConversationPersistenceService();
    this.messageService = AppServices.getGroupConversationMessageService();
    this.runtimeService = AppServices.getGroupChatRuntimeService();
  }

  /** 加载群聊信息 */
  async load(chatId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.chatId = chatId;
    this.state = GroupChatDetailState.Loading;
    try {
      const chats: Chat[] = await this.groupService.listGroupConversations();
      let target: Chat | null = null;
      for (let i = 0; i < chats.length; i++) {
        if (chats[i].id === chatId) {
          target = chats[i];
          break;
        }
      }
      if (target === null) {
        this.state = GroupChatDetailState.NotFound;
        return;
      }
      this.title = target.title;
      this.state = GroupChatDetailState.Ready;
    } catch (e) {
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
      this.state = GroupChatDetailState.Error;
    }
  }

  /**
   * 重命名群聊。
   * @param newTitle 新名称
   */
  async rename(newTitle: string): Promise<void> {
    if (this.disposed || this.isRenaming) {
      return;
    }
    const trimmed: string = newTitle.trim();
    if (trimmed.length === 0) {
      throw new Error('名称不能为空');
    }
    this.isRenaming = true;
    try {
      await this.groupService.renameGroupConversation(this.chatId, trimmed);
      this.title = trimmed;
    } finally {
      this.isRenaming = false;
    }
  }

  /**
   * G-RUNTIME-1C: 刷新生成状态(供页面 aboutToAppear 调用)。
   * 生成中禁止清空/删除。
   */
  refreshGeneratingState(): void {
    this.isGenerating = this.runtimeService.isRunning();
  }

  /** 删除群聊 */
  async delete(): Promise<void> {
    if (this.disposed || this.isDeleting) {
      return;
    }
    // G-RUNTIME-1C: Service 层互斥,生成中禁止删除
    if (this.runtimeService.isRunning()) {
      throw new Error('生成中无法删除群聊');
    }
    this.isDeleting = true;
    try {
      await this.groupService.deleteGroupConversation(this.chatId);
    } catch (e) {
      Logger.error(LOG_TAG, 'delete failed: ' + String(e));
      throw new Error(String(e));
    } finally {
      this.isDeleting = false;
    }
  }

  /**
   * 清空群聊消息(G-RUNTIME-1A / G-RUNTIME-1C)。
   *
   * 规则:
   * - 只删除该群聊的 messages
   * - 不删除 Chat / Participants / Character / 群聊名称 / 成员顺序
   * - 复用 GroupConversationMessageService.clearMessages
   * - G-RUNTIME-1C: 生成中禁止清空(Service 层互斥)
   *
   * @returns 删除的消息条数
   */
  async clearMessages(): Promise<number> {
    if (this.disposed || this.isClearing) {
      return 0;
    }
    if (this.chatId.length === 0) {
      return 0;
    }
    // G-RUNTIME-1C: Service 层互斥,生成中禁止清空
    if (this.runtimeService.isRunning()) {
      throw new Error('生成中无法清空消息');
    }
    this.isClearing = true;
    try {
      const deleted: number = await this.messageService.clearMessages(this.chatId);
      Logger.info(LOG_TAG, 'clearMessages ok count=' + String(deleted));
      return deleted;
    } catch (e) {
      Logger.error(LOG_TAG, 'clearMessages failed: ' + String(e));
      throw new Error(String(e));
    } finally {
      this.isClearing = false;
    }
  }

  dispose(): void {
    this.disposed = true;
  }
}
