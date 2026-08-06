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
import {
  GroupReplyTargetModeSetting,
  loadGroupReplyTargetMode,
  persistGroupReplyTargetMode,
  loadGroupNarrationEnabled,
  persistGroupNarrationEnabled,
  loadGroupNarrationMaxTokens,
  persistGroupNarrationMaxTokens
} from '../../utils/GroupReplyModeSetting';
import { GroupChatDetailState } from './GroupChatUiModels';
import {
  GroupAutoSummaryDetailLevel,
  GroupAutoSummarySettings,
  loadGroupAutoSummarySettings,
  persistGroupAutoSummaryEnabled,
  persistGroupAutoSummaryDetailLevel
} from '../../models/groupchat/GroupAutoSummaryModels';
import {
  GroupUserIdentitySnapshot,
  persistGroupUserIdentitySettings,
  loadGroupUserIdentitySettings
} from '../../models/groupchat/GroupUserIdentitySnapshot';

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
  /** GROUP-CHAT-TARGET-1: @角色回复模式 */
  replyTargetMode: string = 'one_shot';
  /** GROUP-NARRATION-1A: 旁白开关 */
  narrationEnabled: boolean = false;
  /** GROUP-NARRATION-1A: 旁白最大 token 数 */
  narrationMaxTokens: number = 256;
  /** G-GROUP-AUTO-SUMMARY-1A: 自动记忆总结开关 */
  autoSummaryEnabled: boolean = false;
  /** G-GROUP-AUTO-SUMMARY-1A: 自动总结详细程度档位 */
  autoSummaryDetailLevel: GroupAutoSummaryDetailLevel = GroupAutoSummaryDetailLevel.Medium;
  /** G-GROUP-USER-IDENTITY-1: 当前群聊的用户显示名称(空=使用全局设置) */
  userName: string = '';

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
      // GROUP-CHAT-TARGET-1: 加载 @角色回复模式
      this.replyTargetMode = await loadGroupReplyTargetMode(chatId);
      // GROUP-NARRATION-1A: 加载旁白开关
      this.narrationEnabled = await loadGroupNarrationEnabled(chatId);
      this.narrationMaxTokens = await loadGroupNarrationMaxTokens(chatId);
      // G-GROUP-AUTO-SUMMARY-1A: 加载自动记忆总结设置
      const autoSummarySettings: GroupAutoSummarySettings =
        await loadGroupAutoSummarySettings(chatId);
      this.autoSummaryEnabled = autoSummarySettings.enabled;
      this.autoSummaryDetailLevel = autoSummarySettings.detailLevel;
      // G-GROUP-USER-IDENTITY-1: 加载该群聊的用户名称
      try {
        const snap: GroupUserIdentitySnapshot = await loadGroupUserIdentitySettings(chatId);
        this.userName = snap.displayName;
      } catch (_e) {
        this.userName = '';
      }
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

  /**
   * GROUP-CHAT-TARGET-1: 设置并持久化 @角色回复模式。
   * @param mode 'one_shot' | 'persistent'
   */
  setAndPersistReplyTargetMode(mode: string): void {
    this.replyTargetMode = mode;
    if (this.chatId.length > 0) {
      persistGroupReplyTargetMode(this.chatId, mode === 'persistent' ? 'persistent' : 'one_shot');
    }
  }

  /**
   * GROUP-NARRATION-1A: 设置并持久化旁白开关。
   */
  setAndPersistNarrationEnabled(enabled: boolean): void {
    this.narrationEnabled = enabled;
    if (this.chatId.length > 0) {
      persistGroupNarrationEnabled(this.chatId, enabled);
    }
  }

  setAndPersistNarrationMaxTokens(tokens: number): void {
    this.narrationMaxTokens = tokens;
    if (this.chatId.length > 0) {
      persistGroupNarrationMaxTokens(this.chatId, tokens);
    }
  }

  /**
   * G-GROUP-AUTO-SUMMARY-1A: 设置并持久化自动记忆总结开关。
   * 按群聊独立保存,不同群聊互不影响。
   * 关闭后不生成新的自动总结;已保存旧总结继续保留。
   */
  setAndPersistAutoSummaryEnabled(enabled: boolean): void {
    this.autoSummaryEnabled = enabled;
    if (this.chatId.length > 0) {
      persistGroupAutoSummaryEnabled(this.chatId, enabled);
    }
  }

  /**
   * G-GROUP-AUTO-SUMMARY-1A: 设置并持久化自动总结档位。
   * 切换档位只影响下一次成功总结。
   */
  setAndPersistAutoSummaryDetailLevel(level: GroupAutoSummaryDetailLevel): void {
    this.autoSummaryDetailLevel = level;
    if (this.chatId.length > 0) {
      persistGroupAutoSummaryDetailLevel(this.chatId, level);
    }
  }

  /**
   * G-GROUP-USER-IDENTITY-1: 设置并持久化该群聊的用户显示名称。
   * 空字符串表示"使用全局设置"。
   */
  setAndPersistUserName(name: string): void {
    const trimmed: string = name.trim();
    this.userName = trimmed;
    if (this.chatId.length > 0) {
      persistGroupUserIdentitySettings(this.chatId, trimmed, '');
    }
  }
}
