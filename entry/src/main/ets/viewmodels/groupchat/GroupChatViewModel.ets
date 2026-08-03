/**
 * GroupChatViewModel 多人聊天主页面状态管理(G-DATA-1B / G-RUNTIME-1A)
 *
 * 职责:
 * - 从 GroupConversationPersistenceService 读取真实群聊详情
 * - 加载有序成员并映射为 UI DTO
 * - 从 GroupConversationMessageService 读取真实历史消息
 * - 发送用户消息(写入 messages 表,生成 generationBatchId)
 * - 调用 GroupRoundCoordinator 建立本轮计划(本阶段只到 Ready)
 * - 处理缺失角色
 * - 提供重命名能力(更多菜单内联)
 * - 提供清空消息能力
 *
 * 不依赖:
 * - GroupChatPreviewStore
 * - ChatService / ModelService / Provider / SSE
 * - 单聊 ActiveGenerationContext
 *
 * 本阶段不实现:
 * - 多人 AI 生成(不创建 AI 消息)
 * - 流式输出
 * - 停止 / 重试 / 跳过
 *
 * 发送链:
 *   防止重复点击(isSending)
 *   → 创建 generationBatchId
 *   → appendUserMessage(事务:Message + Chat 时间戳)
 *   → 追加到 messages 列表
 *   → prepareRound(建立本轮快照)
 *   → 更新 lastPreparedRound
 *   → 清空输入框
 *
 * 失败处理:
 *   - 消息写入失败:保留输入内容,显示错误,不创建轮次
 *   - 轮次规划失败:消息已写入数据库,保留消息,显示"无法开始本轮"
 *
 * 并发保护:
 *   - isSending 防止重复点击
 *   - loadOperationId 防止页面离开后异步返回覆盖另一 Chat
 *   - currentChatId 校验当前操作的 Chat
 */

import { Chat } from '../../models/Chat';
import { ChatParticipant } from '../../models/ChatParticipant';
import { Character } from '../../models/Character';
import { ChatMessage, ChatMessageStatus, MessageSenderType } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { GroupConversationPersistenceService } from '../../services/groupchat/GroupConversationPersistenceService';
import { GroupConversationMessageService } from '../../services/groupchat/GroupConversationMessageService';
import { GroupRoundCoordinator } from '../../services/groupchat/GroupRoundCoordinator';
import {
  GroupRoundPlan,
  GroupRoundPlanError,
  GroupRoundPlanErrorKind
} from '../../services/groupchat/GroupRoundTypes';
import { CharacterService } from '../../services/CharacterService';
import { AppServices } from '../../services/AppServices';
import { Logger } from '../../utils/Logger';
import { generateUuid } from '../../utils/Uuid';
import {
  GroupConversationDetailUiModel,
  GroupMemberUiModel,
  GroupMessageUiModel,
  GroupChatDetailState,
  GroupMessageListState,
  DELETED_CHARACTER_NAME,
  USER_MESSAGE_SENDER_NAME
} from './GroupChatUiModels';

const LOG_TAG: string = 'GroupChatVM';

@Observed
export class GroupChatViewModel {
  /** 当前群聊 ID */
  chatId: string = '';
  /** 群聊详情(Ready 状态下非 null) */
  detail: GroupConversationDetailUiModel | null = null;
  /** 页面状态 */
  state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 是否正在重命名 */
  isRenaming: boolean = false;
  /** 消息列表 */
  messages: GroupMessageUiModel[] = [];
  /** 消息列表状态 */
  messageState: GroupMessageListState = GroupMessageListState.Loading;
  /** 输入框文本 */
  inputText: string = '';
  /** 是否正在发送(防止重复点击) */
  isSending: boolean = false;
  /** 最后一次建立的轮次计划(Ready 后保留,调试用) */
  lastPreparedRound: GroupRoundPlan | null = null;
  /** 用户可读的错误提示(发送失败 / 轮次规划失败) */
  errorMessage: string = '';

  private readonly groupService: GroupConversationPersistenceService;
  private readonly messageService: GroupConversationMessageService;
  private readonly roundCoordinator: GroupRoundCoordinator;
  private readonly characterService: CharacterService;
  /** 防止页面离开后异步返回覆盖另一 Chat */
  private loadOperationId: number = 0;
  private disposed: boolean = false;

  constructor() {
    this.groupService = AppServices.getGroupConversationPersistenceService();
    this.messageService = AppServices.getGroupConversationMessageService();
    this.roundCoordinator = AppServices.getGroupRoundCoordinator();
    this.characterService = AppServices.getCharacterService();
  }

  /**
   * 加载群聊详情和消息。
   * @param chatId 群聊 ID
   */
  async load(chatId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.chatId = chatId;
    this.state = GroupChatDetailState.Loading;
    this.loadOperationId = this.loadOperationId + 1;
    const opId: number = this.loadOperationId;
    try {
      const chats: Chat[] = await this.groupService.listGroupConversations();
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      let target: Chat | null = null;
      for (let i = 0; i < chats.length; i++) {
        if (chats[i].id === chatId) {
          target = chats[i];
          break;
        }
      }
      if (target === null) {
        this.detail = null;
        this.messages = [];
        this.messageState = GroupMessageListState.Empty;
        this.state = GroupChatDetailState.NotFound;
        return;
      }
      const members: GroupMemberUiModel[] = await this.loadMembers(chatId);
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      this.detail = {
        chatId: chatId,
        title: target.title,
        members: members
      };
      this.state = GroupChatDetailState.Ready;
      // 加载消息
      await this.reloadMessages();
    } catch (e) {
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      this.state = GroupChatDetailState.Error;
    }
  }

  /**
   * 重新加载消息列表(从数据库)。
   * 页面重新显示或发送消息后调用。
   */
  async reloadMessages(): Promise<void> {
    if (this.disposed || this.chatId.length === 0) {
      return;
    }
    this.messageState = GroupMessageListState.Loading;
    const opId: number = this.loadOperationId;
    try {
      const rawMessages: ChatMessage[] =
        await this.messageService.listMessages(this.chatId);
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      if (rawMessages.length === 0) {
        this.messages = [];
        this.messageState = GroupMessageListState.Empty;
        return;
      }
      // 批量加载相关角色(用于 AI 消息显示名称)
      const charMap: Map<string, Character | null> = await this.loadCharactersForMessages(rawMessages);
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      const uiMessages: GroupMessageUiModel[] = rawMessages.map(
        (msg: ChatMessage): GroupMessageUiModel => this.mapMessageToUi(msg, charMap)
      );
      this.messages = uiMessages;
      this.messageState = GroupMessageListState.Ready;
    } catch (e) {
      Logger.error(LOG_TAG, 'reloadMessages failed: ' + String(e));
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      this.messageState = GroupMessageListState.Error;
    }
  }

  /**
   * 发送用户消息。
   *
   * 链路:
   *   防止重复点击(isSending)
   *   → 创建 generationBatchId
   *   → appendUserMessage(事务)
   *   → 追加到 messages 列表
   *   → prepareRound(建立本轮快照)
   *   → 更新 lastPreparedRound
   *   → 清空输入框
   *
   * 失败处理:
   *   - 消息写入失败:保留 inputText,显示错误,不创建轮次
   *   - 轮次规划失败:消息已写入,保留消息,显示"无法开始本轮",
   *     不回滚已发送消息
   */
  async sendUserMessage(content: string): Promise<void> {
    if (this.disposed || this.isSending) {
      return;
    }
    const trimmed: string = content.trim();
    if (trimmed.length === 0) {
      return;
    }
    if (this.chatId.length === 0) {
      return;
    }
    this.isSending = true;
    this.errorMessage = '';
    const opId: number = this.loadOperationId;
    const roundId: string = generateUuid();
    try {
      const written: ChatMessage = await this.messageService.appendUserMessage(
        this.chatId, trimmed, roundId
      );
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      // 追加到消息列表(用户消息)
      const uiMsg: GroupMessageUiModel = {
        id: written.id,
        role: written.role,
        content: written.content,
        status: written.status !== undefined ? written.status : ChatMessageStatus.Completed,
        senderCharacterId: undefined,
        senderName: USER_MESSAGE_SENDER_NAME,
        senderAvatarUri: undefined,
        characterExists: true,
        generationBatchId: written.generationBatchId,
        sequenceNumber: 0,
        createdAt: written.createdAt,
        updatedAt: written.updatedAt !== undefined ? written.updatedAt : written.createdAt
      };
      this.messages = this.messages.concat([uiMsg]);
      if (this.messages.length > 0) {
        this.messageState = GroupMessageListState.Ready;
      }
      // 清空输入框(消息成功写入后)
      this.inputText = '';

      // 建立本轮计划(本阶段只到 Ready,不进入 Generating)
      try {
        const plan: GroupRoundPlan = await this.roundCoordinator.prepareRound(
          this.chatId, written.id, roundId
        );
        if (this.disposed || opId !== this.loadOperationId) {
          return;
        }
        this.lastPreparedRound = plan;
        Logger.info(LOG_TAG, 'round prepared speakers=' + String(plan.speakers.length));
      } catch (planErr) {
        // 轮次规划失败:消息已写入,不回滚
        if (planErr instanceof GroupRoundPlanError) {
          this.errorMessage = this.mapPlanError(planErr.kind);
        } else {
          this.errorMessage = '无法开始本轮';
        }
        Logger.error(LOG_TAG, 'prepareRound failed: ' + String(planErr));
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'sendUserMessage failed: ' + String(e));
      // 消息写入失败:保留 inputText,显示错误
      this.errorMessage = '发送失败';
    } finally {
      this.isSending = false;
    }
  }

  /**
   * 清空群聊消息。
   * 调用 GroupConversationMessageService.clearMessages,然后重新加载。
   */
  async clearMessages(): Promise<void> {
    if (this.disposed || this.chatId.length === 0) {
      return;
    }
    try {
      await this.messageService.clearMessages(this.chatId);
      if (this.disposed) {
        return;
      }
      this.messages = [];
      this.lastPreparedRound = null;
      this.messageState = GroupMessageListState.Empty;
      Logger.info(LOG_TAG, 'clearMessages ok');
    } catch (e) {
      Logger.error(LOG_TAG, 'clearMessages failed: ' + String(e));
      throw new Error(String(e));
    }
  }

  /**
   * 重命名群聊。
   * @param newTitle 新名称(trim 后非空)
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
      // 重命名后重新加载详情
      await this.load(this.chatId);
    } finally {
      this.isRenaming = false;
    }
  }

  /**
   * 页面释放时调用,清理轮次协调器活动上下文。
   * 不抛错,不返回值。
   */
  dispose(): void {
    this.disposed = true;
    this.roundCoordinator.dispose();
  }

  /** 加载有序成员并映射为 UI 模型(缺失角色不抛错) */
  private async loadMembers(chatId: string): Promise<GroupMemberUiModel[]> {
    const participants: ChatParticipant[] = await this.groupService.getParticipants(chatId);
    const charMap: Map<string, Character | null> = new Map();
    for (let i = 0; i < participants.length; i++) {
      const charId: string = participants[i].characterId;
      if (!charMap.has(charId)) {
        try {
          const c: Character | null = await this.characterService.getById(charId);
          charMap.set(charId, c);
        } catch (e) {
          charMap.set(charId, null);
        }
      }
    }
    const result: GroupMemberUiModel[] = [];
    for (let i = 0; i < participants.length; i++) {
      const p: ChatParticipant = participants[i];
      const c: Character | null = charMap.get(p.characterId) ?? null;
      result.push({
        characterId: p.characterId,
        name: c !== null ? c.name : DELETED_CHARACTER_NAME,
        avatarUri: c !== null ? c.avatarUri : '',
        description: c !== null ? c.description : '',
        speakerOrder: p.speakerOrder,
        isEnabled: p.isEnabled,
        characterExists: c !== null
      });
    }
    return result;
  }

  /**
   * 批量加载消息中引用的角色(用于 AI 消息显示名称)。
   * 用户消息无 senderCharacterId,跳过。
   */
  private async loadCharactersForMessages(
    messages: ChatMessage[]
  ): Promise<Map<string, Character | null>> {
    const charIds: Set<string> = new Set<string>();
    for (let i = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      if (msg.senderCharacterId !== undefined && msg.senderCharacterId.length > 0) {
        charIds.add(msg.senderCharacterId);
      }
    }
    const result: Map<string, Character | null> = new Map<string, Character | null>();
    const ids: string[] = Array.from(charIds);
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      try {
        const c: Character | null = await this.characterService.getById(id);
        result.set(id, c);
      } catch (e) {
        result.set(id, null);
      }
    }
    return result;
  }

  /**
   * 将数据库消息映射为 UI 消息。
   * - 用户消息:senderName="我",characterExists=true
   * - AI 消息:通过 senderCharacterId 查 Character
   *   - 存在:显示角色名和头像
   *   - 不存在:显示"角色已删除",characterExists=false
   */
  private mapMessageToUi(
    msg: ChatMessage,
    charMap: Map<string, Character | null>
  ): GroupMessageUiModel {
    const senderType: MessageSenderType =
      msg.senderType !== undefined ? msg.senderType : 'user';
    if (senderType === 'character') {
      const charId: string = msg.senderCharacterId !== undefined ? msg.senderCharacterId : '';
      const c: Character | null = charMap.get(charId) ?? null;
      return {
        id: msg.id,
        role: msg.role,
        content: msg.content,
        status: msg.status !== undefined ? msg.status : ChatMessageStatus.Completed,
        senderCharacterId: charId.length > 0 ? charId : undefined,
        senderName: c !== null ? c.name : DELETED_CHARACTER_NAME,
        senderAvatarUri: c !== null ? c.avatarUri : undefined,
        characterExists: c !== null,
        generationBatchId: msg.generationBatchId,
        sequenceNumber: 0,
        createdAt: msg.createdAt,
        updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : msg.createdAt
      };
    }
    // 用户消息 / narrator
    return {
      id: msg.id,
      role: msg.role,
      content: msg.content,
      status: msg.status !== undefined ? msg.status : ChatMessageStatus.Completed,
      senderCharacterId: undefined,
      senderName: USER_MESSAGE_SENDER_NAME,
      senderAvatarUri: undefined,
      characterExists: true,
      generationBatchId: msg.generationBatchId,
      sequenceNumber: 0,
      createdAt: msg.createdAt,
      updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : msg.createdAt
    };
  }

  /** 将轮次规划错误类型映射为用户可读文案 */
  private mapPlanError(kind: GroupRoundPlanErrorKind): string {
    switch (kind) {
      case GroupRoundPlanErrorKind.ChatNotFound:
        return '群聊不存在';
      case GroupRoundPlanErrorKind.NotGroupChat:
        return '不是多人聊天';
      case GroupRoundPlanErrorKind.InsufficientEnabledMembers:
        return '启用成员不足 2 人';
      case GroupRoundPlanErrorKind.InsufficientAvailableSpeakers:
        return '可用角色不足 2 人';
      case GroupRoundPlanErrorKind.UserMessageNotFound:
        return '用户消息不存在';
      case GroupRoundPlanErrorKind.ActiveRoundExists:
        return '当前已有活动轮次';
      case GroupRoundPlanErrorKind.Internal:
      default:
        return '无法开始本轮';
    }
  }
}
