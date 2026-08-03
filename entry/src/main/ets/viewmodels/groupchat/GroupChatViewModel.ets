/**
 * GroupChatViewModel 多人聊天主页面状态管理(G-DATA-1B / G-RUNTIME-1A / G-RUNTIME-1B)
 *
 * 职责:
 * - 从 GroupConversationPersistenceService 读取真实群聊详情
 * - 加载有序成员并映射为 UI DTO
 * - 从 GroupConversationMessageService 读取真实历史消息
 * - 发送用户消息(写入 messages 表,生成 generationBatchId)
 * - 调用 GroupRoundCoordinator 建立本轮计划
 * - 调用 GroupChatRuntimeService 启动严格顺序流式生成
 * - 实现 GroupRuntimeCallbacks 接收运行时状态更新
 * - 提供停止本轮能力
 * - 处理缺失角色
 * - 提供重命名能力(更多菜单内联)
 * - 提供清空消息能力
 *
 * 不依赖:
 * - GroupChatPreviewStore
 * - ChatService 的发送/停止逻辑
 * - 单聊 ActiveGenerationContext
 * - Provider / SSE
 *
 * 发送链:
 *   防止重复点击(isSending)
 *   → 创建 generationBatchId
 *   → appendUserMessage(事务:Message + Chat 时间戳)
 *   → 追加到 messages 列表
 *   → prepareRound(建立本轮快照)
 *   → startRound(严格顺序流式生成)
 *   → onMessageCreated / onMessageUpdated / onSpeakerCompleted
 *   → onRoundCompleted / onRoundCancelled / onRoundFailed
 *
 * 失败处理:
 *   - 消息写入失败:保留输入内容,显示错误,不创建轮次
 *   - 轮次规划失败:消息已写入数据库,保留消息,显示"无法开始本轮"
 *   - 生成失败:roundState=Failed,roundErrorMessage 显示失败角色
 *
 * 并发保护:
 *   - isSending 防止重复点击
 *   - isGenerating 生成期间禁止再次发送
 *   - loadOperationId 防止页面离开后异步返回覆盖另一 Chat
 *   - currentChatId 校验当前操作的 Chat
 *   - 离开页面时调用 disposeWithStop 停止整轮
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
  GroupRoundState,
  GroupRoundPlan,
  GroupRoundPlanError,
  GroupRoundPlanErrorKind
} from '../../services/groupchat/GroupRoundTypes';
import {
  GroupChatRuntimeService,
  GroupRuntimeCallbacks,
  GroupRuntimeMessageUpdate
} from '../../services/groupchat/GroupChatRuntimeService';
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
  GroupMemberRuntimeState,
  GroupMemberRuntimeUiModel,
  DELETED_CHARACTER_NAME,
  USER_MESSAGE_SENDER_NAME
} from './GroupChatUiModels';

const LOG_TAG: string = 'GroupChatVM';

@Observed
export class GroupChatViewModel implements GroupRuntimeCallbacks {
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

  /** 本轮状态(G-RUNTIME-1B) */
  roundState: GroupRoundState = GroupRoundState.Idle;
  /** 当前发言者索引 */
  currentSpeakerIndex: number = -1;
  /** 当前发言者角色 ID */
  currentSpeakerCharacterId: string = '';
  /** 已完成发言者数 */
  completedSpeakerCount: number = 0;
  /** 总发言者数 */
  totalSpeakerCount: number = 0;
  /** 是否正在生成 */
  isGenerating: boolean = false;
  /** 是否正在停止 */
  isStopping: boolean = false;
  /** 本轮错误消息(生成失败时显示) */
  roundErrorMessage: string = '';
  /** 成员运行时状态列表 */
  memberRuntimeStates: GroupMemberRuntimeUiModel[] = [];

  private readonly groupService: GroupConversationPersistenceService;
  private readonly messageService: GroupConversationMessageService;
  private readonly roundCoordinator: GroupRoundCoordinator;
  private readonly runtimeService: GroupChatRuntimeService;
  private readonly characterService: CharacterService;
  /** 防止页面离开后异步返回覆盖另一 Chat */
  private loadOperationId: number = 0;
  private disposed: boolean = false;

  constructor() {
    this.groupService = AppServices.getGroupConversationPersistenceService();
    this.messageService = AppServices.getGroupConversationMessageService();
    this.roundCoordinator = AppServices.getGroupRoundCoordinator();
    this.runtimeService = AppServices.getGroupChatRuntimeService();
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
   *   → startRound(严格顺序流式生成)
   *   → 清空输入框
   *
   * 失败处理:
   *   - 消息写入失败:保留 inputText,显示错误,不创建轮次
   *   - 轮次规划失败:消息已写入,保留消息,显示"无法开始本轮",
   *     不回滚已发送消息
   *   - 生成失败:由 onError 回调处理,设置 roundErrorMessage
   */
  async sendUserMessage(content: string): Promise<void> {
    if (this.disposed || this.isSending || this.isGenerating) {
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
    this.roundErrorMessage = '';
    const opId: number = this.loadOperationId;
    const roundId: string = generateUuid();
    let preparedPlan: GroupRoundPlan | null = null;
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

      // 建立本轮计划
      try {
        preparedPlan = await this.roundCoordinator.prepareRound(
          this.chatId, written.id, roundId
        );
        if (this.disposed || opId !== this.loadOperationId) {
          return;
        }
        this.lastPreparedRound = preparedPlan;
        Logger.info(LOG_TAG, 'round prepared speakers=' + String(preparedPlan.speakers.length));
      } catch (planErr) {
        // 轮次规划失败:消息已写入,不回滚
        if (planErr instanceof GroupRoundPlanError) {
          this.errorMessage = this.mapPlanError(planErr.kind);
        } else {
          this.errorMessage = '无法开始本轮';
        }
        Logger.error(LOG_TAG, 'prepareRound failed: ' + String(planErr));
        return;
      }

      // 启动严格顺序流式生成
      if (this.disposed || opId !== this.loadOperationId || preparedPlan === null) {
        return;
      }
      this.totalSpeakerCount = preparedPlan.speakers.length;
      this.completedSpeakerCount = 0;
      this.currentSpeakerIndex = -1;
      this.currentSpeakerCharacterId = '';
      this.roundState = GroupRoundState.Ready;
      this.isGenerating = true;
      this.refreshMemberRuntimeStates();

      try {
        await this.runtimeService.startRound(preparedPlan, this);
      } catch (e) {
        Logger.error(LOG_TAG, 'startRound failed: ' + String(e));
        this.roundState = GroupRoundState.Failed;
        this.roundErrorMessage = '生成启动失败';
        this.isGenerating = false;
        this.refreshMemberRuntimeStates();
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
   * 停止本轮。
   *
   * 规则:
   * - 立即使 operationId 失效
   * - 中止当前 Provider 请求
   * - 当前 Streaming AI 消息标记 Cancelled(保留部分正文)
   * - 不启动后续角色
   * - 状态变为 Cancelled
   * - 迟到回调被拒绝
   */
  async stopRound(): Promise<void> {
    if (this.disposed || !this.isGenerating || this.isStopping) {
      return;
    }
    this.isStopping = true;
    Logger.info(LOG_TAG, 'stopRound requested');
    try {
      await this.runtimeService.stopRound();
    } catch (e) {
      Logger.error(LOG_TAG, 'stopRound failed: ' + String(e));
    } finally {
      this.isStopping = false;
      this.isGenerating = false;
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
   * 页面离开时调用,停止整轮并清理活动上下文。
   *
   * 规则:
   * - 如果正在生成,先停止整轮(abort 当前请求,标记 Cancelled)
   * - 然后清理轮次协调器活动上下文
   * - 阻止后续角色启动
   * - 阻止迟到回调更新 UI
   *
   * 不抛错,不返回值。
   */
  async disposeWithStop(): Promise<void> {
    this.disposed = true;
    if (this.isGenerating) {
      try {
        await this.runtimeService.stopRound();
      } catch (e) {
        Logger.warn(LOG_TAG, 'disposeWithStop stopRound failed: ' + String(e));
      }
    }
    this.isGenerating = false;
    this.isStopping = false;
    this.roundCoordinator.dispose();
  }

  /**
   * 同步释放(不停止轮次,仅清理协调器)。
   * 仅在已确认无活动轮次时使用。
   */
  dispose(): void {
    this.disposed = true;
    this.roundCoordinator.dispose();
  }

  // ===== GroupRuntimeCallbacks 实现 =====

  /** 整轮状态变更 */
  onRoundStateChanged(state: GroupRoundState): void {
    if (this.disposed) {
      return;
    }
    this.roundState = state;
    Logger.info(LOG_TAG, 'onRoundStateChanged state=' + state);
  }

  /** 单个发言者开始生成 */
  onSpeakerStarted(characterId: string, speakerIndex: number): void {
    if (this.disposed) {
      return;
    }
    this.currentSpeakerCharacterId = characterId;
    this.currentSpeakerIndex = speakerIndex;
    this.refreshMemberRuntimeStates();
    Logger.info(LOG_TAG, 'onSpeakerStarted idx=' + String(speakerIndex));
  }

  /** 新 AI 消息已创建(追加到列表) */
  onMessageCreated(message: ChatMessage): void {
    if (this.disposed) {
      return;
    }
    const uiMsg: GroupMessageUiModel = this.mapRuntimeMessageToUiSync(message);
    this.messages = this.messages.concat([uiMsg]);
    this.messageState = GroupMessageListState.Ready;
  }

  /** 消息内容更新(流式 delta 或最终状态) */
  onMessageUpdated(update: GroupRuntimeMessageUpdate): void {
    if (this.disposed) {
      return;
    }
    const newMessages: GroupMessageUiModel[] = [];
    for (let i = 0; i < this.messages.length; i++) {
      const m: GroupMessageUiModel = this.messages[i];
      if (m.id === update.messageId) {
        newMessages.push({
          id: m.id,
          role: m.role,
          content: update.content,
          status: update.status,
          senderCharacterId: m.senderCharacterId,
          senderName: m.senderName,
          senderAvatarUri: m.senderAvatarUri,
          characterExists: m.characterExists,
          generationBatchId: m.generationBatchId,
          sequenceNumber: m.sequenceNumber,
          createdAt: m.createdAt,
          updatedAt: m.updatedAt
        });
      } else {
        newMessages.push(m);
      }
    }
    this.messages = newMessages;
  }

  /** 单个发言者完成 */
  onSpeakerCompleted(characterId: string, speakerIndex: number): void {
    if (this.disposed) {
      return;
    }
    this.completedSpeakerCount = speakerIndex + 1;
    this.refreshMemberRuntimeStates();
    Logger.info(LOG_TAG, 'onSpeakerCompleted idx=' + String(speakerIndex));
  }

  /** 整轮完成 */
  onRoundCompleted(): void {
    if (this.disposed) {
      return;
    }
    this.roundState = GroupRoundState.Completed;
    this.isGenerating = false;
    this.isStopping = false;
    this.currentSpeakerIndex = -1;
    this.currentSpeakerCharacterId = '';
    this.refreshMemberRuntimeStates();
    Logger.info(LOG_TAG, 'onRoundCompleted');
  }

  /** 整轮取消 */
  onRoundCancelled(): void {
    if (this.disposed) {
      return;
    }
    this.roundState = GroupRoundState.Cancelled;
    this.isGenerating = false;
    this.isStopping = false;
    this.refreshMemberRuntimeStates();
    Logger.info(LOG_TAG, 'onRoundCancelled');
  }

  /** 整轮失败 */
  onRoundFailed(characterId: string, errorMessage: string): void {
    if (this.disposed) {
      return;
    }
    this.roundState = GroupRoundState.Failed;
    this.isGenerating = false;
    this.isStopping = false;
    this.roundErrorMessage = errorMessage;
    this.refreshMemberRuntimeStates();
    Logger.info(LOG_TAG, 'onRoundFailed charId=' + characterId);
  }

  // ===== 内部辅助 =====

  /**
   * 刷新成员运行时状态列表。
   *
   * 规则:
   * - 未生成或整轮结束:所有成员 Idle
   * - 生成中:
   *   - speakerIndex < currentSpeakerIndex:Completed
   *   - speakerIndex === currentSpeakerIndex:Generating
   *   - speakerIndex > currentSpeakerIndex:Waiting
   * - Cancelled:当前角色 Cancelled,后续 Waiting
   * - Failed:当前角色 Failed,后续 Waiting
   */
  private refreshMemberRuntimeStates(): void {
    if (this.detail === null) {
      this.memberRuntimeStates = [];
      return;
    }
    const members: GroupMemberUiModel[] = this.detail.members;
    const result: GroupMemberRuntimeUiModel[] = [];
    // 仅启用的成员才参与本轮发言,按 speakerOrder 排序
    const enabledMembers: GroupMemberUiModel[] = members
      .filter((m: GroupMemberUiModel): boolean => m.isEnabled && m.characterExists)
      .sort((a: GroupMemberUiModel, b: GroupMemberUiModel): number =>
        a.speakerOrder - b.speakerOrder
      );

    const isGenerating: boolean = this.isGenerating
      && (this.roundState === GroupRoundState.Generating
        || this.roundState === GroupRoundState.Ready);

    for (let i = 0; i < enabledMembers.length; i++) {
      const m: GroupMemberUiModel = enabledMembers[i];
      let runtimeState: GroupMemberRuntimeState = GroupMemberRuntimeState.Idle;
      if (isGenerating) {
        if (i < this.currentSpeakerIndex) {
          runtimeState = GroupMemberRuntimeState.Completed;
        } else if (i === this.currentSpeakerIndex) {
          runtimeState = GroupMemberRuntimeState.Generating;
        } else {
          runtimeState = GroupMemberRuntimeState.Waiting;
        }
      } else if (this.roundState === GroupRoundState.Completed) {
        runtimeState = GroupMemberRuntimeState.Completed;
      } else if (this.roundState === GroupRoundState.Cancelled) {
        if (i < this.currentSpeakerIndex) {
          runtimeState = GroupMemberRuntimeState.Completed;
        } else if (i === this.currentSpeakerIndex) {
          runtimeState = GroupMemberRuntimeState.Cancelled;
        } else {
          runtimeState = GroupMemberRuntimeState.Idle;
        }
      } else if (this.roundState === GroupRoundState.Failed) {
        if (i < this.currentSpeakerIndex) {
          runtimeState = GroupMemberRuntimeState.Completed;
        } else if (i === this.currentSpeakerIndex) {
          runtimeState = GroupMemberRuntimeState.Failed;
        } else {
          runtimeState = GroupMemberRuntimeState.Idle;
        }
      }
      result.push({
        characterId: m.characterId,
        name: m.name,
        avatarUri: m.avatarUri,
        speakerIndex: i,
        runtimeState: runtimeState,
        characterExists: m.characterExists
      });
    }
    this.memberRuntimeStates = result;
  }

  /**
   * 将运行时 ChatMessage 同步映射为 UI 消息(用于 onMessageCreated)。
   * 角色信息从 detail.members 中查找(发言者必然是当前群聊的启用成员)。
   */
  private mapRuntimeMessageToUiSync(msg: ChatMessage): GroupMessageUiModel {
    const senderType: MessageSenderType =
      msg.senderType !== undefined ? msg.senderType : 'user';
    if (senderType === 'character') {
      const charId: string = msg.senderCharacterId !== undefined ? msg.senderCharacterId : '';
      // 从 detail.members 中查找角色(同步)
      let name: string = DELETED_CHARACTER_NAME;
      let avatarUri: string | undefined = undefined;
      let characterExists: boolean = false;
      if (this.detail !== null && charId.length > 0) {
        for (let i = 0; i < this.detail.members.length; i++) {
          const m: GroupMemberUiModel = this.detail.members[i];
          if (m.characterId === charId) {
            name = m.name;
            avatarUri = m.avatarUri;
            characterExists = m.characterExists;
            break;
          }
        }
      }
      return {
        id: msg.id,
        role: msg.role,
        content: msg.content,
        status: msg.status !== undefined ? msg.status : ChatMessageStatus.Streaming,
        senderCharacterId: charId.length > 0 ? charId : undefined,
        senderName: name,
        senderAvatarUri: avatarUri,
        characterExists: characterExists,
        generationBatchId: msg.generationBatchId,
        sequenceNumber: 0,
        createdAt: msg.createdAt,
        updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : msg.createdAt
      };
    }
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
