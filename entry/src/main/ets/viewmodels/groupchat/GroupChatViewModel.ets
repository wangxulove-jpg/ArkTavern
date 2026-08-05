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
  GroupRoundPlanErrorKind,
  GroupSpeakerRetryError,
  GroupSpeakerRetryErrorKind,
  GroupReplyTarget,
  GroupReplyTargetMode,
  REPLY_TARGET_ALL_ENABLED,
  selectedCharactersReplyTarget
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
  GroupReplyTargetModeSetting,
  loadGroupReplyTargetMode,
  persistGroupReplyTargetMode,
  loadGroupNarrationEnabled,
  loadGroupNarrationMaxTokens
} from '../../utils/GroupReplyModeSetting';
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

/**
 * G-CONTROL-2A: 回复目标角色数量上限。
 * 与 GroupRoundCoordinator.MAX_REPLY_TARGETS 保持一致,
 * 在 ViewModel 层提前拦截,避免 prepareRound 才报错。
 */
const MAX_REPLY_TARGETS: number = 8;

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
  /** G-RUNTIME-1C: 是否正在重试(防止重复点击重试按钮) */
  isRetrying: boolean = false;
  /** G-RUNTIME-1C: 是否正在结束本轮(防止重复点击结束本轮) */
  isEndingRound: boolean = false;
  /** 本轮错误消息(生成失败时显示) */
  roundErrorMessage: string = '';
  /** 成员运行时状态列表 */
  memberRuntimeStates: GroupMemberRuntimeUiModel[] = [];
  /**
   * G-UI-ALIGN-1: 当前活动轮次 ID(供 UI 追踪轮次切换)。
   *
   * - Idle/Completed/Cancelled/Failed 后保留最近一轮 ID,便于 UI 判断"同一轮次内已收起"
   * - 新一轮 sendUserMessage/retrySpeakerMessage 启动时更新为新 roundId
   * - 页面通过比对 currentRoundId 变化识别"新轮次开始",从而允许成员栏重新展开
   * - 不持久化,仅用于 UI 状态机判断,不影响业务逻辑
   */
  currentRoundId: string = '';

  /**
   * G-CONTROL-2A: 当前输入草稿的回复目标。
   *
   * 规则:
   * - 进入群聊:默认 AllEnabled(characterIds=[])
   * - 发送成功:重置为 AllEnabled
   * - 发送失败:保留目标选择
   * - 用户主动取消:恢复 AllEnabled
   * - 切换群聊:清空旧群聊目标(load 时重置)
   * - 不跨群聊共享
   * - 生成期间:禁止更改
   * - 目标成员被移除或停用:发送前重新校验
   *
   * 多目标:
   * - SelectedCharacters 模式下 characterIds 长度 1~8
   * - ID 顺序不代表生成顺序(生成顺序始终由 speakerOrder 决定)
   */
  selectedReplyTarget: GroupReplyTarget = REPLY_TARGET_ALL_ENABLED;
  /** G-CONTROL-2A: 选中目标成员 UI 模型(用于 Chip 显示,顺序与 selectedReplyTarget.characterIds 一致) */
  selectedReplyTargetMembers: GroupMemberUiModel[] = [];
  /** G-CONTROL-2A: @选择器可见性 */
  isMentionPickerVisible: boolean = false;
  /** G-CONTROL-2A: @选择器过滤文本(@ 后输入的文字) */
  mentionQuery: string = '';
  /** G-CONTROL-2A: @选择器候选成员(已启用且存在的成员) */
  mentionCandidates: GroupMemberUiModel[] = [];

  /**
   * GROUP-CHAT-TARGET-1: 持续回复目标角色 ID。
   *
   * - null 表示默认全员回复
   * - 页面退出群聊后不持久化
   * - 不写数据库/Preferences/Chat 模型
   * - 切换群聊时清除
   * - 角色失效时自动清除
   */
  persistentReplyTargetCharacterId: string = '';
  /**
   * GROUP-CHAT-TARGET-1: @角色回复模式(按群聊持久化)。
   * - 'one_shot': @角色仅影响当前消息,发送后恢复全员
   * - 'persistent': @角色直接切换持续目标,后续消息默认由该角色回复
   * 默认 'one_shot'。
   */
  replyTargetMode: string = 'one_shot';
  /** GROUP-NARRATION-1A: 旁白开关(按群聊持久化,默认关闭) */
  narrationEnabled: boolean = false;
  /** GROUP-NARRATION-1A: 旁白最大 token 数 */
  narrationMaxTokens: number = 256;

  /**
   * GROUP-CHAT-TARGET-1: 仅下一次发送使用的临时目标。
   *
   * - 发送成功提交用户消息后立即清除
   * - 优先级高于 persistentReplyTargetCharacterId
   * - 不跨消息保留
   */
  pendingOneShotReplyTargetCharacterId: string = '';

  /**
   * UI 状态同步回调(G-RUNTIME-1C-FIX)。
   *
   * ArkUI 中 @State 持有 @Observed 对象时,ForEach 对内部数组属性变化的
   * 响应式刷新不完整。通过回调将消息列表同步到 GroupChatPage,
   * 使页面立即调用 syncRenderStates 更新 GroupMessageRenderState,
   * 确保 Streaming delta / Complete / Cancelled / Failed 即时刷新到 UI,
   * 无需等待 200ms 轮询。
   *
   * 与单聊 ChatViewModel.onMessagesUpdate 采用相同模式。
   */
  onMessagesUpdate?: (messages: GroupMessageUiModel[]) => void;

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
    // G-CONTROL-2A: 切换群聊时清空旧群聊的草稿目标(不跨群聊共享)
    // 同一群聊重新加载(如重命名后)保留草稿目标
    if (this.chatId !== chatId) {
      this.selectedReplyTarget = REPLY_TARGET_ALL_ENABLED;
      this.selectedReplyTargetMembers = [];
      this.isMentionPickerVisible = false;
      this.mentionQuery = '';
      this.mentionCandidates = [];
      // GROUP-CHAT-TARGET-1: 切换群聊时清除持续/临时目标,防止跨群聊串线
      this.persistentReplyTargetCharacterId = '';
      this.pendingOneShotReplyTargetCharacterId = '';
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
        this.notifyMessagesUpdate();
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
        this.notifyMessagesUpdate();
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
      this.notifyMessagesUpdate();
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
   *   → G-CONTROL-2A: 校验 selectedReplyTarget,构建 replyTargetCharacterIds
   *   → 创建 generationBatchId
   *   → appendUserMessage(事务,携带 replyTargetCharacterIds)
   *   → 追加到 messages 列表(含 replyTarget 标签)
   *   → prepareRound(建立本轮快照,携带 replyTarget)
   *   → startRound(严格顺序流式生成)
   *   → 清空输入框
   *   → G-CONTROL-2A: 发送成功后重置 selectedReplyTarget 为 AllEnabled
   *
   * 失败处理:
   *   - 目标校验失败:不写入消息,保留 inputText 和目标选择,显示错误
   *   - 消息写入失败:保留 inputText,保留目标选择,显示错误,不创建轮次
   *   - 轮次规划失败:消息已写入,保留消息,显示"无法开始本轮",
   *     不回滚已发送消息(目标选择已重置)
   *   - 生成失败:由 onError 回调处理,设置 roundErrorMessage
   */
  async sendUserMessage(content: string): Promise<void> {
    Logger.info(LOG_TAG, 'sendUserMessage start disposed=' + String(this.disposed)
      + ' isSending=' + String(this.isSending)
      + ' isGenerating=' + String(this.isGenerating));
    if (this.disposed || this.isSending || this.isGenerating) {
      Logger.warn(LOG_TAG, 'sendUserMessage skip: busy/disposed');
      return;
    }
    const trimmed: string = content.trim();
    if (trimmed.length === 0) {
      Logger.warn(LOG_TAG, 'sendUserMessage skip: content empty');
      return;
    }
    if (this.chatId.length === 0) {
      Logger.warn(LOG_TAG, 'sendUserMessage skip: chatId empty');
      return;
    }
    // G-RUNTIME-1D: 跨群聊隔离检查
    if (this.runtimeService.isAnotherChatRunning(this.chatId)) {
      Logger.warn(LOG_TAG, 'sendUserMessage skip: another chat running');
      this.errorMessage = '另一个多人聊天正在回复,请先结束当前回复';
      return;
    }
    // GROUP-CHAT-TARGET-1: 发送前校验持续目标有效性(可能已被停用/移除/删除)
    // 失效时自动清除并显示提示,继续走默认全员逻辑
    this.validateAndClearInvalidPersistentTarget();

    // GROUP-CHAT-TARGET-1: 发送前解析回复目标快照(优先级: 仅本次 > 持续对话 > 多选草稿 > 全员)
    // 快照固定后不再在运行中重新读取,确保本轮由同一角色完成
    const replyTarget: GroupReplyTarget = this.resolveReplyTargetSnapshot();
    const replyTargetIds: string[] = this.validateAndBuildReplyTargetIds(replyTarget);
    Logger.info(LOG_TAG, 'sendUserMessage targetMode=' + replyTarget.mode
      + ' targets=' + String(replyTargetIds.length)
      + ' oneShot=' + this.pendingOneShotReplyTargetCharacterId
      + ' persistent=' + this.persistentReplyTargetCharacterId);
    if (replyTarget.mode === GroupReplyTargetMode.SelectedCharacters
      && replyTargetIds.length === 0) {
      // 校验失败,errorMessage 已在 validateAndBuildReplyTargetIds 中设置
      // 保留 inputText 和目标选择,不发送
      Logger.warn(LOG_TAG, 'sendUserMessage skip: reply target validation failed');
      return;
    }
    this.isSending = true;
    this.errorMessage = '';
    this.roundErrorMessage = '';
    // G-RUNTIME-1D: 每轮状态完整复位(不继承上一轮的任何状态)
    this.isStopping = false;
    this.isRetrying = false;
    this.isEndingRound = false;
    const opId: number = this.loadOperationId;
    const roundId: string = generateUuid();
    // G-UI-ALIGN-1: 记录当前轮次 ID,供 UI 追踪轮次切换(成员栏展开/收起状态机)
    this.currentRoundId = roundId;
    let preparedPlan: GroupRoundPlan | null = null;
    try {
      const written: ChatMessage = await this.messageService.appendUserMessage(
        this.chatId, trimmed, roundId, replyTargetIds
      );
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      // G-CONTROL-2A: 解析目标角色名称(用于 UI 标签)
      const replyTargetNames: string[] = replyTargetIds.length > 0
        ? replyTargetIds.map((id: string): string => this.findMemberNameById(id))
        : [];
      // 追加到消息列表(用户消息,含目标标签)
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
        updatedAt: written.updatedAt !== undefined ? written.updatedAt : written.createdAt,
        replyTargetCharacterIds: replyTargetIds,
        replyTargetNames: replyTargetNames,
        senderType: 'user'
      };
      this.messages = this.messages.concat([uiMsg]);
      this.notifyMessagesUpdate();
      if (this.messages.length > 0) {
        this.messageState = GroupMessageListState.Ready;
      }
      // 清空输入框(消息成功写入后)
      this.inputText = '';
      // G-CONTROL-2A: 发送成功后重置目标选择(用户消息已写入,目标已记录)
      // 失败时(prepareRound/startRound 失败)不恢复目标,因为消息已发送
      this.selectedReplyTarget = REPLY_TARGET_ALL_ENABLED;
      this.selectedReplyTargetMembers = [];
      // GROUP-CHAT-TARGET-1: 发送成功后清除仅本次临时目标(推荐提交用户消息后立即清除)
      this.pendingOneShotReplyTargetCharacterId = '';

      // 建立本轮计划(G-CONTROL-2A: 携带 replyTarget)
      try {
        preparedPlan = await this.roundCoordinator.prepareRound(
          this.chatId, written.id, roundId, replyTarget
        );
        if (this.disposed || opId !== this.loadOperationId) {
          return;
        }
        this.lastPreparedRound = preparedPlan;
        Logger.info(LOG_TAG, 'round prepared speakers=' + String(preparedPlan.speakers.length)
          + ' mode=' + replyTarget.mode);
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

      // GROUP-NARRATION-1A: 设置旁白配置(generateNarration 时使用)
      this.runtimeService.setNarrationConfig(
        this.narrationEnabled && replyTargetIds.length === 1,
        this.detail !== null ? this.detail.title : '',
        replyTargetIds.length === 1 ? this.findMemberNameById(replyTargetIds[0]) : '',
        trimmed,
        this.buildOtherCharacterSummaries(replyTargetIds),
        this.narrationMaxTokens
      );

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
      // G-CONTROL-2A: 保留 selectedReplyTarget(发送失败时目标选择不重置)
      this.errorMessage = '发送失败';
    } finally {
      this.isSending = false;
    }
  }

  /**
   * G-RUNTIME-1D: 是否有另一个群聊正在运行。
   *
   * 用于页面显示"另一个多人聊天正在回复"提示和禁用输入。
   * - 当前群聊自身在运行:返回 false(由 isGenerating 处理)
   * - 另一个群聊在运行:返回 true
   * - 无任何群聊运行:返回 false
   */
  isAnotherChatRunning(): boolean {
    if (this.chatId.length === 0) {
      return false;
    }
    return this.runtimeService.isAnotherChatRunning(this.chatId);
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
   * G-RUNTIME-1C: 重试单条 Failed/Cancelled 角色消息。
   *
   * 行为:
   * - 调用 GroupChatRuntimeService.retrySpeakerMessage
   * - 创建新的 Streaming 消息(同一 generationBatchId)
   * - 重试期间 isGenerating=true, isRetrying=true
   * - 防止重复点击(isRetrying)
   * - 生命周期保护:检查 disposed / loadOperationId / chatId
   *
   * 失败处理:
   * - 前置校验失败(GroupSpeakerRetryError):显示对应错误文案
   * - 生成失败:由 onRoundFailed 回调处理
   *
   * @param messageId 被重试的原消息 ID
   */
  async retrySpeakerMessage(messageId: string): Promise<void> {
    if (this.disposed || this.isGenerating || this.isRetrying) {
      return;
    }
    if (messageId.length === 0 || this.chatId.length === 0) {
      return;
    }
    // G-RUNTIME-1D: 跨群聊隔离检查
    if (this.runtimeService.isAnotherChatRunning(this.chatId)) {
      this.errorMessage = '另一个多人聊天正在回复,请先结束当前回复';
      return;
    }
    this.isRetrying = true;
    this.errorMessage = '';
    this.roundErrorMessage = '';
    // G-RUNTIME-1D: 每轮状态完整复位(不继承上一轮的任何状态)
    this.isStopping = false;
    this.isEndingRound = false;
    this.currentSpeakerIndex = -1;
    this.currentSpeakerCharacterId = '';
    this.completedSpeakerCount = 0;
    const opId: number = this.loadOperationId;
    const expectedChatId: string = this.chatId;
    // G-UI-ALIGN-1: 重试视为新一轮次触发,更新 currentRoundId 让 UI 成员栏可重新展开
    // 复用被重试消息的 generationBatchId 作为轮次标识(重试不创建新批次)
    const retryRoundId: string = 'retry_' + messageId;
    this.currentRoundId = retryRoundId;
    Logger.info(LOG_TAG, 'retrySpeakerMessage requested msgId=' + messageId);
    try {
      // 重试视为一次生成,进入 Generating 状态
      this.isGenerating = true;
      this.roundState = GroupRoundState.Generating;
      this.refreshMemberRuntimeStates();
      await this.runtimeService.retrySpeakerMessage(messageId, expectedChatId, this);
    } catch (e) {
      Logger.error(LOG_TAG, 'retrySpeakerMessage failed: ' + String(e));
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      if (e instanceof GroupSpeakerRetryError) {
        this.errorMessage = this.mapRetryError(e.kind);
      } else {
        this.errorMessage = '重试失败';
      }
      this.isGenerating = false;
      this.roundState = GroupRoundState.Idle;
      this.refreshMemberRuntimeStates();
    } finally {
      this.isRetrying = false;
    }
  }

  /**
   * GROUP-REGENERATE: 重新生成指定的角色消息(允许 Completed 状态)。
   */
  async regenerateSpeakerMessage(messageId: string): Promise<void> {
    if (this.disposed || this.isGenerating || this.isRetrying) {
      return;
    }
    if (messageId.length === 0 || this.chatId.length === 0) {
      return;
    }
    if (this.runtimeService.isAnotherChatRunning(this.chatId)) {
      this.errorMessage = '另一个多人聊天正在回复,请先结束当前回复';
      return;
    }
    this.isRetrying = true;
    this.errorMessage = '';
    this.roundErrorMessage = '';
    this.isStopping = false;
    this.isEndingRound = false;
    this.currentSpeakerIndex = -1;
    this.currentSpeakerCharacterId = '';
    this.completedSpeakerCount = 0;
    // 立即从 UI 列表移除旧消息(DB 删除由 RuntimeService 处理)
    this.messages = this.messages.filter((m: GroupMessageUiModel): boolean => m.id !== messageId);
    this.notifyMessagesUpdate();
    const opId: number = this.loadOperationId;
    const expectedChatId: string = this.chatId;
    const retryRoundId: string = 'retry_' + messageId;
    this.currentRoundId = retryRoundId;
    Logger.info(LOG_TAG, 'regenerateSpeakerMessage msgId=' + messageId);
    try {
      this.isGenerating = true;
      this.roundState = GroupRoundState.Generating;
      this.refreshMemberRuntimeStates();
      await this.runtimeService.retrySpeakerMessage(messageId, expectedChatId, this, true);
    } catch (e) {
      Logger.error(LOG_TAG, 'regenerateSpeakerMessage failed: ' + String(e));
      if (this.disposed || opId !== this.loadOperationId) {
        return;
      }
      if (e instanceof GroupSpeakerRetryError) {
        this.errorMessage = this.mapRetryError(e.kind);
      } else {
        this.errorMessage = '重新生成失败';
      }
      this.isGenerating = false;
      this.roundState = GroupRoundState.Idle;
      this.refreshMemberRuntimeStates();
    } finally {
      this.isRetrying = false;
    }
  }

  /**
   * GROUP-REGENERATE: 判断角色消息是否可以重新生成。
   */
  canRegenerateMessage(msg: GroupMessageUiModel): boolean {
    if (msg.role === ChatRole.User) {
      return false;
    }
    if (msg.senderCharacterId === undefined || msg.senderCharacterId.length === 0) {
      return false;
    }
    if (!msg.characterExists) {
      return false;
    }
    if (this.isGenerating || this.isRetrying || this.isEndingRound) {
      return false;
    }
    return true;
  }

  /**
   * G-RUNTIME-1C: 结束本轮。
   *
   * 用于失败或取消后点击"结束本轮":
   * - 失效 operationId
   * - 清理活动上下文
   * - 不创建后续角色消息
   * - 输入区恢复
   * - 本轮状态保持 Failed 或 Cancelled(不改为 Completed)
   *
   * 如果当前仍在生成中,先调用 stopRound 中止请求。
   */
  async endRound(): Promise<void> {
    if (this.disposed || this.isEndingRound) {
      return;
    }
    this.isEndingRound = true;
    Logger.info(LOG_TAG, 'endRound requested');
    try {
      await this.runtimeService.endRound();
    } catch (e) {
      Logger.error(LOG_TAG, 'endRound failed: ' + String(e));
    } finally {
      this.isEndingRound = false;
      this.isGenerating = false;
      this.isStopping = false;
      this.currentSpeakerIndex = -1;
      this.currentSpeakerCharacterId = '';
      this.refreshMemberRuntimeStates();
    }
  }

  /**
   * G-RUNTIME-1C: 判断消息是否可以重试。
   *
   * 条件:
   * - 不是用户消息(role !== User)
   * - senderCharacterId 存在(角色消息)
   * - 状态为 Failed 或 Cancelled
   * - 当前无活动轮次(!isGenerating)
   * - 角色仍存在(characterExists)
   *
   * @param msg 消息 UI 模型
   * @returns 是否可以重试
   */
  canRetryMessage(msg: GroupMessageUiModel): boolean {
    if (msg.role === ChatRole.User) {
      return false;
    }
    if (msg.senderCharacterId === undefined || msg.senderCharacterId.length === 0) {
      return false;
    }
    if (msg.status !== ChatMessageStatus.Failed && msg.status !== ChatMessageStatus.Cancelled) {
      return false;
    }
    if (!msg.characterExists) {
      return false;
    }
    if (this.isGenerating || this.isRetrying || this.isEndingRound) {
      return false;
    }
    return true;
  }

  /**
   * 清空群聊消息。
   *
   * G-RUNTIME-1C: 生成或重试期间禁止清空消息(Service 层互斥)。
   * 调用 GroupConversationMessageService.clearMessages,然后重新加载。
   */
  async clearMessages(): Promise<void> {
    if (this.disposed || this.chatId.length === 0) {
      return;
    }
    // Service 层互斥:生成/重试/停止/结束本轮期间禁止清空
    if (this.runtimeService.isRunning()) {
      this.errorMessage = '生成中无法清空消息';
      throw new Error('生成中无法清空消息');
    }
    try {
      await this.messageService.clearMessages(this.chatId);
      if (this.disposed) {
        return;
      }
      this.messages = [];
      this.notifyMessagesUpdate();
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
   * G-RUNTIME-1D: 使用幂等停止入口 stopRoundIfRunning,
   * 避免 aboutToDisappear / onPageHide 重复 stop。
   *
   * 规则:
   * - 调用 stopRoundIfRunning(内部幂等,同一 operationId 只停止一次)
   * - 清理轮次协调器活动上下文
   * - 阻止后续角色启动
   * - 阻止迟到回调更新 UI
   * - runtimeService 的数据库终态保存仍会完成
   *
   * 不抛错,不返回值。
   */
  async disposeWithStop(): Promise<void> {
    this.disposed = true;
    // GROUP-CHAT-TARGET-1: 清除持续/临时目标(页面离开时清除)
    this.persistentReplyTargetCharacterId = '';
    this.pendingOneShotReplyTargetCharacterId = '';
    // G-RUNTIME-1D: 幂等停止(无论 ViewModel.isGenerating 是否为 true,
    // 都调用 stopRoundIfRunning,由 runtimeService 判断是否实际停止)
    try {
      await this.runtimeService.stopRoundIfRunning();
    } catch (e) {
      Logger.warn(LOG_TAG, 'disposeWithStop stopRoundIfRunning failed: ' + String(e));
    }
    this.isGenerating = false;
    this.isStopping = false;
    this.isRetrying = false;
    this.isEndingRound = false;
    this.roundCoordinator.dispose();
  }

  /**
   * 同步释放(不停止轮次,仅清理协调器)。
   * 仅在已确认无活动轮次时使用。
   */
  dispose(): void {
    this.disposed = true;
    // GROUP-CHAT-TARGET-1: 清除持续/临时目标
    this.persistentReplyTargetCharacterId = '';
    this.pendingOneShotReplyTargetCharacterId = '';
    this.roundCoordinator.dispose();
  }

  /**
   * 通知 UI 消息列表已更新(G-RUNTIME-1C-FIX)。
   *
   * 每次 this.messages 赋值后调用,触发 GroupChatPage 立即执行 syncRenderStates,
   * 保证 Streaming delta / Complete / Cancelled / Failed 即时反映到页面,
   * 不依赖 200ms 轮询。
   */
  private notifyMessagesUpdate(): void {
    if (this.disposed) {
      return;
    }
    if (this.onMessagesUpdate !== undefined) {
      this.onMessagesUpdate([...this.messages]);
    }
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
    this.notifyMessagesUpdate();
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
          updatedAt: m.updatedAt,
          // G-CONTROL-2A: 保留用户消息目标标签(更新时不应丢失)
          replyTargetCharacterIds: m.replyTargetCharacterIds,
          replyTargetNames: m.replyTargetNames,
          senderType: m.senderType
        });
      } else {
        newMessages.push(m);
      }
    }
    this.messages = newMessages;
    this.notifyMessagesUpdate();
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
   * - 生成中(全员轮次):
   *   - speakerIndex < currentSpeakerIndex:Completed
   *   - speakerIndex === currentSpeakerIndex:Generating
   *   - speakerIndex > currentSpeakerIndex:Waiting
   * - 生成中(有限成员轮次 SelectedCharacters):
   *   - 目标角色:Generating/Completed(根据 currentSpeakerIndex)
   *   - 非目标启用成员:NotParticipating(本轮不参与)
   * - Cancelled:当前角色 Cancelled,后续 Idle
   * - Failed:当前角色 Failed,后续 Idle
   *
   * G-CONTROL-2A: 有限成员轮次中,非目标启用成员显示 NotParticipating,
   * 避免被误认为"等待回复"。目标集合使用 lastPreparedRound.replyTarget.characterIds。
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

    // G-CONTROL-2A: 判断是否为有限成员轮次(SelectedCharacters)
    const isLimitedRound: boolean = this.lastPreparedRound !== null
      && this.lastPreparedRound.replyTarget.mode === GroupReplyTargetMode.SelectedCharacters;
    // 构建目标角色 ID 集合(用于判断非目标启用成员显示 NotParticipating)
    const targetSet: Set<string> = new Set<string>();
    if (isLimitedRound && this.lastPreparedRound !== null) {
      const ids: string[] = this.lastPreparedRound.replyTarget.characterIds;
      for (let i = 0; i < ids.length; i++) {
        targetSet.add(ids[i]);
      }
    }

    const isGenerating: boolean = this.isGenerating
      && (this.roundState === GroupRoundState.Generating
        || this.roundState === GroupRoundState.Ready);

    // 有限成员轮次的"轮次上下文"包括 Generating/Completed/Cancelled/Failed
    // 这些状态下非目标启用成员显示 NotParticipating
    const inRoundContext: boolean = isGenerating
      || this.roundState === GroupRoundState.Completed
      || this.roundState === GroupRoundState.Cancelled
      || this.roundState === GroupRoundState.Failed;

    for (let i = 0; i < enabledMembers.length; i++) {
      const m: GroupMemberUiModel = enabledMembers[i];
      let runtimeState: GroupMemberRuntimeState = GroupMemberRuntimeState.Idle;

      // G-CONTROL-2A: 有限成员轮次中,非目标启用成员显示 NotParticipating
      const isTarget: boolean = isLimitedRound && targetSet.has(m.characterId);
      if (inRoundContext && isLimitedRound && !isTarget) {
        runtimeState = GroupMemberRuntimeState.NotParticipating;
      } else if (isGenerating) {
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
   *
   * G-CONTROL-2A: AI 消息(replyTarget 字段为空数组,只有用户消息有目标标签)。
   * 用户消息场景在 sendUserMessage 中单独构建,不走此方法。
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
        updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : msg.createdAt,
        replyTargetCharacterIds: [],
        replyTargetNames: [],
        senderType: 'character'
      };
    }
    if (senderType === 'narrator') {
      return {
        id: msg.id,
        role: msg.role,
        content: msg.content,
        status: msg.status !== undefined ? msg.status : ChatMessageStatus.Streaming,
        senderCharacterId: undefined,
        senderName: '旁白',
        senderAvatarUri: undefined,
        characterExists: true,
        generationBatchId: msg.generationBatchId,
        sequenceNumber: 0,
        createdAt: msg.createdAt,
        updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : msg.createdAt,
        replyTargetCharacterIds: [],
        replyTargetNames: [],
        senderType: 'narrator'
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
      updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : msg.createdAt,
      replyTargetCharacterIds: [],
      replyTargetNames: [],
      senderType: 'user'
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
   * 批量加载消息中引用的角色(用于 AI 消息显示名称 + G-CONTROL-2A 用户消息目标标签)。
   *
   * 收集范围:
   * - AI 消息的 senderCharacterId
   * - 用户消息的 replyTargetCharacterIds(G-CONTROL-2A 多角色回复目标)
   *
   * 历史兼容:
   * - 旧 G-CONTROL-1 数据迁移后 replyTargetCharacterIds 已包含原单角色 ID
   * - 旧全员消息 replyTargetCharacterIds 为 undefined,跳过
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
      // G-CONTROL-2A: 加载 replyTargetCharacterIds 对应的角色(用于用户消息目标标签)
      if (msg.replyTargetCharacterIds !== undefined) {
        for (let j = 0; j < msg.replyTargetCharacterIds.length; j++) {
          const rid: string = msg.replyTargetCharacterIds[j];
          if (rid.length > 0) {
            charIds.add(rid);
          }
        }
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
   *
   * G-CONTROL-2A:
   * - 解析 msg.replyTargetCharacterIds 为 replyTargetCharacterIds / replyTargetNames
   * - 支持多目标(数组完整保留)
   * - 角色已删除时对应名称显示"角色已删除"
   * - 全员回复(replyTargetCharacterIds 为空/undefined)两个字段均为空数组
   */
  private mapMessageToUi(
    msg: ChatMessage,
    charMap: Map<string, Character | null>
  ): GroupMessageUiModel {
    // G-CONTROL-2A: 解析 replyTargetCharacterIds 为多目标字段
    const replyTargetCharacterIds: string[] = [];
    const replyTargetNames: string[] = [];
    if (msg.replyTargetCharacterIds !== undefined) {
      for (let i = 0; i < msg.replyTargetCharacterIds.length; i++) {
        const targetId: string = msg.replyTargetCharacterIds[i];
        if (targetId.length === 0) {
          continue;
        }
        replyTargetCharacterIds.push(targetId);
        const c: Character | null = charMap.get(targetId) ?? null;
        replyTargetNames.push(c !== null ? c.name : DELETED_CHARACTER_NAME);
      }
    }

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
        updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : msg.createdAt,
        replyTargetCharacterIds: replyTargetCharacterIds,
        replyTargetNames: replyTargetNames,
        senderType: 'character'
      };
    }
    if (senderType === 'narrator') {
      return {
        id: msg.id,
        role: msg.role,
        content: msg.content,
        status: msg.status !== undefined ? msg.status : ChatMessageStatus.Completed,
        senderCharacterId: undefined,
        senderName: '旁白',
        senderAvatarUri: undefined,
        characterExists: true,
        generationBatchId: msg.generationBatchId,
        sequenceNumber: 0,
        createdAt: msg.createdAt,
        updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : msg.createdAt,
        replyTargetCharacterIds: [],
        replyTargetNames: [],
        senderType: 'narrator'
      };
    }
    // 用户消息
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
      updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : msg.createdAt,
      replyTargetCharacterIds: replyTargetCharacterIds,
      replyTargetNames: replyTargetNames,
      senderType: 'user'
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
      case GroupRoundPlanErrorKind.TargetCharacterNotFound:
        return '该角色已删除';
      case GroupRoundPlanErrorKind.TargetCharacterNotInChat:
        return '该角色已不在当前群聊';
      case GroupRoundPlanErrorKind.TargetCharacterNotEnabled:
        return '该角色已停用';
      case GroupRoundPlanErrorKind.TargetCharacterIdsEmpty:
        return '目标角色无效';
      case GroupRoundPlanErrorKind.TargetCharacterIdsExceedLimit:
        return '目标角色数量超过上限';
      case GroupRoundPlanErrorKind.Internal:
      default:
        return '无法开始本轮';
    }
  }

  // ===== G-CONTROL-2A 回复目标选择 =====

  /**
   * G-CONTROL-2A: 发送前校验目标角色并构建 replyTargetCharacterIds。
   *
   * 校验规则(仅 SelectedCharacters 模式):
   * - characterIds 非空(length >= 1)
   * - 数量不超过 MAX_REPLY_TARGETS
   * - 每个目标角色仍存在(detail.members 中且 characterExists=true)
   * - 每个目标角色已启用(isEnabled=true)
   * - 任一目标失效即拒绝整次发送(不部分发送)
   *
   * 校验失败时设置 errorMessage 并返回空数组。
   * AllEnabled 模式返回空数组(不写入全部成员 ID,空数组表示全员)。
   *
   * @returns replyTargetCharacterIds(AllEnabled 为空数组,SelectedCharacters 为去重后的有效 ID 列表)
   */
  private validateAndBuildReplyTargetIds(replyTarget: GroupReplyTarget): string[] {
    if (replyTarget.mode === GroupReplyTargetMode.SelectedCharacters) {
      const targetIds: string[] = replyTarget.characterIds;
      if (targetIds.length === 0) {
        this.errorMessage = '目标角色无效';
        return [];
      }
      if (targetIds.length > MAX_REPLY_TARGETS) {
        this.errorMessage = '最多选择 ' + String(MAX_REPLY_TARGETS) + ' 个角色';
        return [];
      }
      if (this.detail === null) {
        this.errorMessage = '群聊信息未加载';
        return [];
      }
      // 逐个校验目标角色(任一失效即拒绝整次发送)
      const validIds: string[] = [];
      for (let i = 0; i < targetIds.length; i++) {
        const id: string = targetIds[i];
        const member: GroupMemberUiModel | null = this.findMemberById(id);
        if (member === null) {
          this.errorMessage = '部分目标角色已不在当前群聊';
          return [];
        }
        if (!member.characterExists) {
          this.errorMessage = '部分目标角色已删除';
          return [];
        }
        if (!member.isEnabled) {
          this.errorMessage = '部分目标角色已停用';
          return [];
        }
        validIds.push(id);
      }
      return validIds;
    }
    // AllEnabled 模式:返回空数组(表示全员回复)
    return [];
  }

  /**
   * G-CONTROL-2A: 点击成员栏角色,切换回复目标(多选)。
   *
   * 行为:
   * - 当前目标已包含该角色:从目标集合中移除该角色
   *   - 移除后目标为空:恢复 AllEnabled
   * - 当前目标不包含该角色(AllEnabled 或 SelectedCharacters):加入目标集合
   *
   * 校验:
   * - 角色必须存在(characterExists=true)
   * - 角色必须启用(isEnabled=true)
   * - 生成中不允许切换目标
   * - 目标数量不超过 MAX_REPLY_TARGETS
   *
   * 目标点击顺序不代表生成顺序(生成顺序始终由 speakerOrder 决定)。
   *
   * @param characterId 被点击的角色 ID
   * @returns 是否成功切换(校验失败返回 false,errorMessage 已设置)
   */
  toggleMemberReplyTarget(characterId: string): boolean {
    if (this.disposed || this.isGenerating) {
      return false;
    }
    if (characterId === '' || this.detail === null) {
      return false;
    }
    const member: GroupMemberUiModel | null = this.findMemberById(characterId);
    if (member === null) {
      this.errorMessage = '该角色已不在当前群聊';
      return false;
    }
    if (!member.characterExists) {
      this.errorMessage = '该角色已删除';
      return false;
    }
    if (!member.isEnabled) {
      this.errorMessage = '该角色已停用';
      return false;
    }
    // 多选切换逻辑
    if (this.selectedReplyTarget.mode === GroupReplyTargetMode.SelectedCharacters) {
      const currentIds: string[] = this.selectedReplyTarget.characterIds;
      const index: number = currentIds.indexOf(characterId);
      if (index >= 0) {
        // 已选中:移除该目标
        const newIds: string[] = currentIds.filter((id: string): boolean => id !== characterId);
        if (newIds.length === 0) {
          // 移除后目标为空:恢复 AllEnabled
          this.selectedReplyTarget = REPLY_TARGET_ALL_ENABLED;
          this.selectedReplyTargetMembers = [];
        } else {
          this.selectedReplyTarget = selectedCharactersReplyTarget(newIds);
          this.selectedReplyTargetMembers =
            this.selectedReplyTargetMembers.filter((m: GroupMemberUiModel): boolean =>
              m.characterId !== characterId
            );
        }
      } else {
        // 未选中:添加目标
        if (currentIds.length >= MAX_REPLY_TARGETS) {
          this.errorMessage = '最多选择 ' + String(MAX_REPLY_TARGETS) + ' 个角色';
          return false;
        }
        const newIds: string[] = [...currentIds, characterId];
        this.selectedReplyTarget = selectedCharactersReplyTarget(newIds);
        this.selectedReplyTargetMembers = [...this.selectedReplyTargetMembers, member];
      }
    } else {
      // AllEnabled -> SelectedCharacters(添加第一个目标)
      this.selectedReplyTarget = selectedCharactersReplyTarget([characterId]);
      this.selectedReplyTargetMembers = [member];
    }
    this.errorMessage = '';
    return true;
  }

  /**
   * G-CONTROL-2A: 取消所有回复目标,恢复 AllEnabled。
   */
  clearReplyTarget(): void {
    this.selectedReplyTarget = REPLY_TARGET_ALL_ENABLED;
    this.selectedReplyTargetMembers = [];
  }

  // ===== GROUP-CHAT-TARGET-1 持续对话与仅本次目标 =====

  /**
   * GROUP-CHAT-TARGET-1: 设置仅本次回复目标。
   *
   * - 校验角色有效性
   * - 不影响 persistentReplyTargetCharacterId
   * - 发送成功后自动清除
   *
   * @param characterId 目标角色 ID
   * @returns 是否成功(校验失败返回 false,errorMessage 已设置)
   */
  setOneShotReplyTarget(characterId: string): boolean {
    if (this.disposed || this.isGenerating) {
      return false;
    }
    if (characterId === '' || this.detail === null) {
      return false;
    }
    const member: GroupMemberUiModel | null = this.findMemberById(characterId);
    if (member === null) {
      this.errorMessage = '该角色已不在当前群聊';
      return false;
    }
    if (!member.characterExists) {
      this.errorMessage = '该角色已删除';
      return false;
    }
    if (!member.isEnabled) {
      this.errorMessage = '该角色已停用';
      return false;
    }
    this.pendingOneShotReplyTargetCharacterId = characterId;
    this.errorMessage = '';
    return true;
  }

  /**
   * GROUP-CHAT-TARGET-1: 设置持续对话目标。
   *
   * - 校验角色有效性
   * - 替换旧持续目标(直接切换)
   * - 同时清除 pendingOneShot(持续模式优先时不需要临时目标)
   *
   * @param characterId 目标角色 ID
   * @returns 是否成功(校验失败返回 false,errorMessage 已设置)
   */
  setPersistentReplyTarget(characterId: string): boolean {
    if (this.disposed || this.isGenerating) {
      return false;
    }
    if (characterId === '' || this.detail === null) {
      return false;
    }
    const member: GroupMemberUiModel | null = this.findMemberById(characterId);
    if (member === null) {
      this.errorMessage = '该角色已不在当前群聊';
      return false;
    }
    if (!member.characterExists) {
      this.errorMessage = '该角色已删除';
      return false;
    }
    if (!member.isEnabled) {
      this.errorMessage = '该角色已停用';
      return false;
    }
    this.persistentReplyTargetCharacterId = characterId;
    this.pendingOneShotReplyTargetCharacterId = '';
    this.errorMessage = '';
    return true;
  }

  /**
   * GROUP-CHAT-TARGET-1: 取消持续对话目标。
   *
   * - 恢复默认全员回复
   * - 下一条消息恢复全员顺序回复
   * - 不弹出确认框
   * - 不删除任何历史消息
   */
  clearPersistentReplyTarget(): void {
    this.persistentReplyTargetCharacterId = '';
  }

  /**
   * GROUP-CHAT-TARGET-1: 查找持续目标角色名称(用于 UI 状态条显示)。
   *
   * @returns 角色名称或空字符串
   */
  findPersistentTargetMemberName(): string {
    if (this.persistentReplyTargetCharacterId.length === 0) {
      return '';
    }
    return this.findMemberNameById(this.persistentReplyTargetCharacterId);
  }

  /**
   * GROUP-CHAT-TARGET-1: 查找持续目标角色头像 URI。
   */
  findPersistentTargetMemberAvatarUri(): string {
    if (this.persistentReplyTargetCharacterId.length === 0) {
      return '';
    }
    const m: GroupMemberUiModel | null = this.findMemberById(this.persistentReplyTargetCharacterId);
    return m !== null ? m.avatarUri : '';
  }

  /**
   * GROUP-CHAT-TARGET-1: 查找仅本次目标角色名称。
   */
  findOneShotTargetMemberName(): string {
    if (this.pendingOneShotReplyTargetCharacterId.length === 0) {
      return '';
    }
    return this.findMemberNameById(this.pendingOneShotReplyTargetCharacterId);
  }

  /**
   * GROUP-CHAT-TARGET-1: 加载当前群聊的 @角色回复模式。
   * 应从 GroupChatPage.aboutToAppear 调用。
   */
  async loadReplyTargetMode(): Promise<void> {
    if (this.chatId.length === 0) {
      return;
    }
    this.replyTargetMode = await loadGroupReplyTargetMode(this.chatId);
    this.narrationEnabled = await loadGroupNarrationEnabled(this.chatId);
    this.narrationMaxTokens = await loadGroupNarrationMaxTokens(this.chatId);
    // 模式切换为仅回复一次时，清除旧的持续目标防止残留
    if (this.replyTargetMode === 'one_shot') {
      this.persistentReplyTargetCharacterId = '';
    }
  }

  /**
   * GROUP-CHAT-TARGET-1: 设置并持久化当前群聊的 @角色回复模式。
   * @param mode 'one_shot' | 'persistent'
   */
  setAndPersistReplyTargetMode(mode: string): void {
    this.replyTargetMode = mode;
    if (this.chatId.length > 0) {
      persistGroupReplyTargetMode(this.chatId, mode === 'persistent' ? 'persistent' : 'one_shot');
    }
  }

  /**
   * GROUP-NARRATION-1A: 构建其他在场角色摘要(用于旁白 Prompt)。
   * 排除 replyTargetIds 中的角色。
   */
  buildOtherCharacterSummaries(excludeIds: string[]): string[] {
    if (this.detail === null) {
      return [];
    }
    const excludeSet: Set<string> = new Set<string>();
    for (let i = 0; i < excludeIds.length; i++) {
      excludeSet.add(excludeIds[i]);
    }
    const summaries: string[] = [];
    for (let i = 0; i < this.detail.members.length; i++) {
      const m: GroupMemberUiModel = this.detail.members[i];
      if (excludeSet.has(m.characterId)) {
        continue;
      }
      if (!m.isEnabled || !m.characterExists) {
        continue;
      }
      let summary: string = m.name;
      if (m.description.length > 0) {
        summary = summary + '：' + m.description;
      }
      summaries.push(summary);
    }
    return summaries;
  }

  /**
   * GROUP-CHAT-TARGET-1: 校验持续目标角色是否仍有效。
   *
   * 如果角色被移除、禁用或 Character 缺失:
   * - 自动清除持续目标
   * - 恢复默认全员回复
   * - 设置 errorMessage 显示轻量提示
   *
   * @returns true 表示有效或无持续目标;false 表示已自动清除
   */
  validateAndClearInvalidPersistentTarget(): boolean {
    if (this.persistentReplyTargetCharacterId.length === 0) {
      return true;
    }
    if (this.detail === null) {
      this.persistentReplyTargetCharacterId = '';
      return false;
    }
    const member: GroupMemberUiModel | null =
      this.findMemberById(this.persistentReplyTargetCharacterId);
    if (member === null) {
      this.persistentReplyTargetCharacterId = '';
      this.errorMessage = '持续对话角色已不在当前群聊,已恢复全员回复';
      return false;
    }
    if (!member.characterExists) {
      this.persistentReplyTargetCharacterId = '';
      this.errorMessage = '持续对话角色已删除,已恢复全员回复';
      return false;
    }
    if (!member.isEnabled) {
      this.persistentReplyTargetCharacterId = '';
      this.errorMessage = '持续对话角色已停用,已恢复全员回复';
      return false;
    }
    return true;
  }

  /**
   * GROUP-CHAT-TARGET-1: 发送前解析回复目标快照。
   *
   * 优先级:
   * 1. pendingOneShotReplyTargetCharacterId 非空 → SelectedCharacters([oneShot])
   * 2. persistentReplyTargetCharacterId 非空 → SelectedCharacters([persistent])
   * 3. selectedReplyTarget(multi-select 草稿)→ 原样
   * 4. REPLY_TARGET_ALL_ENABLED(默认全员)
   *
   * 此方法在 sendUserMessage 开头调用一次,返回值作为本轮固定快照,
   * 不在 Runtime 执行过程中重新读取。
   *
   * @returns 解析后的 GroupReplyTarget 快照
   */
  private resolveReplyTargetSnapshot(): GroupReplyTarget {
    if (this.pendingOneShotReplyTargetCharacterId.length > 0) {
      return selectedCharactersReplyTarget([this.pendingOneShotReplyTargetCharacterId]);
    }
    if (this.persistentReplyTargetCharacterId.length > 0) {
      return selectedCharactersReplyTarget([this.persistentReplyTargetCharacterId]);
    }
    return this.selectedReplyTarget;
  }

  /**
   * G-CONTROL-1: 打开 @选择器,构建候选成员列表。
   *
   * 候选规则:
   * - 当前群聊成员
   * - 已启用(isEnabled=true)
   * - 角色仍存在(characterExists=true)
   *
   * @param query 初始过滤文本(@ 后的文字,可为空)
   */
  openMentionPicker(query: string): void {
    if (this.disposed || this.detail === null) {
      this.isMentionPickerVisible = false;
      this.mentionCandidates = [];
      return;
    }
    this.mentionQuery = query;
    this.mentionCandidates = this.filterMentionCandidates(query);
    this.isMentionPickerVisible = this.mentionCandidates.length > 0;
  }

  /**
   * G-CONTROL-1: 更新 @选择器过滤文本。
   */
  updateMentionQuery(query: string): void {
    this.mentionQuery = query;
    this.mentionCandidates = this.filterMentionCandidates(query);
    this.isMentionPickerVisible = this.mentionCandidates.length > 0;
  }

  /**
   * G-CONTROL-1: 关闭 @选择器。
   */
  closeMentionPicker(): void {
    this.isMentionPickerVisible = false;
    this.mentionQuery = '';
  }

  /**
   * G-CONTROL-2A: 选择 @角色(多选)。
   *
   * 行为:
   * - 将该角色加入目标集合(若已存在则不重复添加,关闭选择器)
   * - 关闭 @选择器
   * - 返回要插入的正文字符串(@角色名 + 空格)
   *
   * 多次 @处理:
   * - 已选中的角色再次选择:不重复添加,仅关闭选择器(返回空,不插入 @文字)
   * - 未选中的角色:加入目标集合,返回 @角色名 + 空格
   * - 目标数量达上限:设置 errorMessage,不添加,关闭选择器
   *
   * 目标点击顺序不代表生成顺序(生成顺序始终由 speakerOrder 决定)。
   *
   * @param characterId 被选择的角色 ID
   * @returns 要插入的正文字符串(@角色名 + 空格);已选中或失败返回空字符串
   */
  selectMentionTarget(characterId: string): string {
    if (this.disposed || this.detail === null) {
      return '';
    }
    const member: GroupMemberUiModel | null = this.findMemberById(characterId);
    if (member === null || !member.characterExists || !member.isEnabled) {
      return '';
    }
    // 多选逻辑
    if (this.selectedReplyTarget.mode === GroupReplyTargetMode.SelectedCharacters) {
      const currentIds: string[] = this.selectedReplyTarget.characterIds;
      if (currentIds.indexOf(characterId) >= 0) {
        // 已选中:不重复添加,关闭选择器
        this.closeMentionPicker();
        return '';
      }
      if (currentIds.length >= MAX_REPLY_TARGETS) {
        this.errorMessage = '最多选择 ' + String(MAX_REPLY_TARGETS) + ' 个角色';
        this.closeMentionPicker();
        return '';
      }
      const newIds: string[] = [...currentIds, characterId];
      this.selectedReplyTarget = selectedCharactersReplyTarget(newIds);
      this.selectedReplyTargetMembers = [...this.selectedReplyTargetMembers, member];
    } else {
      // AllEnabled -> SelectedCharacters(第一个目标)
      this.selectedReplyTarget = selectedCharactersReplyTarget([characterId]);
      this.selectedReplyTargetMembers = [member];
    }
    this.closeMentionPicker();
    return '@' + member.name + ' ';
  }

  /**
   * G-CONTROL-1: 过滤 @选择器候选成员。
   * 按名称模糊匹配(大小写不敏感)。
   */
  private filterMentionCandidates(query: string): GroupMemberUiModel[] {
    if (this.detail === null) {
      return [];
    }
    const q: string = query.trim().toLowerCase();
    return this.detail.members.filter((m: GroupMemberUiModel): boolean => {
      if (!m.isEnabled || !m.characterExists) {
        return false;
      }
      if (q.length === 0) {
        return true;
      }
      return m.name.toLowerCase().includes(q);
    });
  }

  /**
   * G-CONTROL-1: 根据 characterId 查找成员(同步,从 detail.members)。
   * @returns 成员模型或 null(未找到)
   */
  private findMemberById(characterId: string): GroupMemberUiModel | null {
    if (characterId.length === 0 || this.detail === null) {
      return null;
    }
    for (let i = 0; i < this.detail.members.length; i++) {
      if (this.detail.members[i].characterId === characterId) {
        return this.detail.members[i];
      }
    }
    return null;
  }

  /**
   * G-CONTROL-1: 根据 characterId 查找成员名称。
   * @returns 成员名称或空字符串(未找到)
   */
  private findMemberNameById(characterId: string): string {
    const m: GroupMemberUiModel | null = this.findMemberById(characterId);
    return m !== null ? m.name : '';
  }

  /** G-RUNTIME-1C: 将重试错误类型映射为用户可读文案 */
  private mapRetryError(kind: GroupSpeakerRetryErrorKind): string {
    switch (kind) {
      case GroupSpeakerRetryErrorKind.MessageNotFound:
        return '消息不存在,无法重试';
      case GroupSpeakerRetryErrorKind.MessageNotInChat:
        return '消息不属于当前群聊';
      case GroupSpeakerRetryErrorKind.NotCharacterMessage:
        return '只能重试角色回复';
      case GroupSpeakerRetryErrorKind.MissingRoundId:
        return '消息缺少轮次信息';
      case GroupSpeakerRetryErrorKind.InvalidStatusForRetry:
        return '当前消息状态不允许重试';
      case GroupSpeakerRetryErrorKind.ActiveRoundExists:
        return '当前正在生成,请稍后重试';
      case GroupSpeakerRetryErrorKind.CharacterNotFound:
        return '角色已被删除,无法重试';
      case GroupSpeakerRetryErrorKind.CharacterNotInChat:
        return '角色已不在群聊中,无法重试';
      case GroupSpeakerRetryErrorKind.Internal:
      default:
        return '重试失败';
    }
  }
}
