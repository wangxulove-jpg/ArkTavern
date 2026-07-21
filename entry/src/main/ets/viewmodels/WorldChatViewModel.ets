/**
 * WorldChatViewModel 多人世界聊天 ViewModel
 *
 * 职责:
 * - 初始化多人聊天会话(委托 MultiPersonChatService.initialize)
 * - 加载历史消息(按当前 branch)
 * - 加载成员/角色信息(头像、名称、在场状态)
 * - 加载场景信息
 * - 发送用户消息(委托 MultiPersonChatService.sendUserMessage)
 * - 停止生成(委托 MultiPersonChatService.stopGeneration)
 * - 切换回复模式 / 场景 / 指定角色
 * - 维护流式生成状态(累积文本、当前角色)
 * - 页面退出时 dispose
 *
 * 不负责:
 * - 单角色聊天(走 ChatViewModel)
 * - 角色卡管理(走 CharacterListViewModel)
 * - 成员管理(走 WorldMembersViewModel)
 * - 关系/记忆页面展示(单独页面)
 */

import {
  ChatMessage,
  ChatMessageStatus,
  MessageSenderType,
  MessageVisibility,
  createChatMessage
} from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { Character } from '../models/Character';
import { Chat } from '../models/Chat';
import {
  World,
  WorldReplyMode
} from '../models/World';
import { WorldScene } from '../models/WorldScene';
import { WorldChatLink } from '../models/WorldChatLink';
import {
  WorldService,
  WorldMemberView
} from '../services/WorldService';
import {
  MultiPersonChatService,
  MultiPersonChatState,
  MultiPersonStreamCallbacks,
  MultiPersonSendOptions,
  MultiPersonSessionInfo
} from '../services/MultiPersonChatService';
import { CharacterService } from '../services/CharacterService';
import { MessageRepository } from '../repositories/MessageRepository';
import { ConversationBranchRepository } from '../repositories/ConversationBranchRepository';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldChatViewModel';

/** 回复模式显示文本 */
export function replyModeLabel(mode: WorldReplyMode): string {
  switch (mode) {
    case 'designated': return '指定角色';
    case 'auto_director': return '自动导演';
    case 'all_respond': return '全员回应';
    case 'narrator_only': return '仅旁白';
    default: return mode;
  }
}

/**
 * v11 私聊:发送范围类型。
 * - 'public': 公开发言,所有在场角色可见
 * - 'private': 私下交谈,仅 recipientCharacterIds 可见
 * - 'narrator': 旁白动作,作为场景描述处理
 */
export type SendScope = 'public' | 'private' | 'narrator';

/** 聊天消息展示项(含角色信息) */
export interface WorldChatMessageItem {
  readonly message: ChatMessage;
  /** 发送者类型 */
  readonly senderType: MessageSenderType;
  /** 发送者角色 ID(角色消息时非空) */
  readonly senderCharacterId: string;
  /** 关联角色(已删除则为 null) */
  readonly character: Character | null;
  /** 角色是否已删除 */
  readonly isCharacterDeleted: boolean;
  /** 显示名称 */
  readonly displayName: string;
  /** 头像 URI */
  readonly avatarUri: string;
}

/** 顶部展示的在场成员(用于头像组) */
export interface PresentMemberAvatar {
  readonly characterId: string;
  readonly character: Character | null;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly muted: boolean;
}

@Observed
export class WorldChatViewModel {
  // ===== 会话状态 =====
  chatId: string = '';
  worldId: string = '';
  branchId: string = '';
  currentSceneId: string = '';
  replyMode: WorldReplyMode = 'auto_director';

  // ===== 数据 =====
  messages: WorldChatMessageItem[] = [];
  presentMembers: PresentMemberAvatar[] = [];
  allMembers: WorldMemberView[] = [];
  scenes: WorldScene[] = [];
  currentScene: WorldScene | null = null;
  world: World | null = null;
  chat: Chat | null = null;

  // ===== 输入 / 生成状态 =====
  inputText: string = '';
  isGenerating: boolean = false;
  statusMessage: string = '';
  errorMessage: string = '';
  streamingPreview: string = '';
  /** 指定角色回复的目标角色 ID */
  designatedCharacterId: string = '';
  /** 是否显示指定角色选择器 */
  showDesignatedPicker: boolean = false;
  /** 是否显示回复模式选择器 */
  showReplyModePicker: boolean = false;
  /** 是否显示场景选择器 */
  showScenePicker: boolean = false;

  // ===== v11 私聊:发送范围状态 =====
  /** 当前发送范围(默认公开) */
  sendScope: SendScope = 'public';
  /** 私聊目标角色 ID 列表 */
  privateRecipientIds: string[] = [];
  /** 是否显示发送范围选择面板 */
  showScopePicker: boolean = false;
  /** 是否显示私聊目标角色多选面板 */
  showPrivateRecipientPicker: boolean = false;

  // ===== 初始化状态 =====
  isInitializing: boolean = true;
  isSessionReady: boolean = false;
  initError: string = '';

  /**
   * 页面订阅回调(参照 ChatViewModel.onMessagesUpdate 模式)。
   * ViewModel 状态变化时主动推送给页面,避免页面 @State 与 ViewModel 不同步。
   */
  onMessagesUpdate?: (messages: WorldChatMessageItem[]) => void;
  onStreamingUpdate?: (preview: string) => void;
  onStateUpdate?: () => void;

  private readonly multiPersonChatService: MultiPersonChatService;
  private readonly worldService: WorldService;
  private readonly characterService: CharacterService;
  private readonly messageRepository: MessageRepository;
  private readonly branchRepository: ConversationBranchRepository;
  private disposed: boolean = false;
  /** 流式预览节流:最后 flush 时间戳 */
  private lastStreamFlushTime: number = 0;
  /** 流式预览节流:pending flush 的 timer id */
  private streamFlushTimerId: number = -1;
  private static readonly STREAM_FLUSH_INTERVAL_MS: number = 50;

  constructor(
    multiPersonChatService: MultiPersonChatService,
    worldService: WorldService,
    characterService: CharacterService,
    messageRepository: MessageRepository,
    branchRepository: ConversationBranchRepository
  ) {
    this.multiPersonChatService = multiPersonChatService;
    this.worldService = worldService;
    this.characterService = characterService;
    this.messageRepository = messageRepository;
    this.branchRepository = branchRepository;
  }

  /**
   * 初始化多人聊天会话。
   * - 委托 MultiPersonChatService.initialize
   * - 加载历史消息(按当前 branch)
   * - 加载成员/场景信息
   */
  async initialize(chatId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.chatId = chatId;
    this.isInitializing = true;
    this.initError = '';
    try {
      const sessionInfo: MultiPersonSessionInfo =
        await this.multiPersonChatService.initialize(chatId);
      this.worldId = sessionInfo.worldId;
      this.branchId = sessionInfo.branchId;
      this.currentSceneId = sessionInfo.currentSceneId;
      this.replyMode = sessionInfo.replyMode;

      await Promise.all([
        this.loadWorldAndChat(),
        this.loadMembers(),
        this.loadScenes(),
        this.loadMessages()
      ]);

      this.isSessionReady = true;
    } catch (e) {
      this.initError = '初始化会话失败: ' + String(e);
      Logger.error(LOG_TAG, 'initialize failed: ' + String(e));
    } finally {
      this.isInitializing = false;
    }
  }

  /** 加载世界与会话信息 */
  private async loadWorldAndChat(): Promise<void> {
    this.world = await this.worldService.getWorld(this.worldId);
    const link: WorldChatLink | null = await this.worldService.getChatLink(this.chatId);
    if (link !== null) {
      this.replyMode = link.replyMode;
    }
  }

  /** 加载成员 + 角色信息 */
  private async loadMembers(): Promise<void> {
    const views: WorldMemberView[] = await this.worldService.listMembers(this.worldId);
    this.allMembers = views;
    // 在场头像组
    const present: PresentMemberAvatar[] = [];
    for (let i = 0; i < views.length; i++) {
      const v: WorldMemberView = views[i];
      if (!v.member.enabled || !v.member.present) {
        continue;
      }
      const ch: Character | null = v.character;
      present.push({
        characterId: v.member.characterId,
        character: ch,
        displayName: ch !== null ? ch.name : '未知角色',
        avatarUri: ch !== null ? ch.avatarUri : '',
        muted: v.member.muted
      });
    }
    this.presentMembers = present;
  }

  /** 加载场景列表 */
  private async loadScenes(): Promise<void> {
    this.scenes = await this.worldService.listScenes(this.worldId);
    if (this.currentSceneId.length > 0) {
      this.currentScene = await this.worldService.getScene(this.currentSceneId);
    }
  }

  /** 加载历史消息(按当前 branch) */
  private async loadMessages(): Promise<void> {
    if (this.branchId.length === 0) {
      this.messages = [];
      return;
    }
    const messageIds: string[] = await this.branchRepository.listMessageIds(this.branchId);
    if (messageIds.length === 0) {
      this.messages = [];
      return;
    }
    // v11 修复:listByChat 默认 limit=50,会截断旧消息导致新消息查不到。
    // 改为按 branch 中的 messageIds 批量查询,确保所有 branch 消息都能被加载。
    const ordered: ChatMessage[] = [];
    for (let i = 0; i < messageIds.length; i++) {
      const m: ChatMessage | null = await this.messageRepository.getById(messageIds[i]);
      if (m !== null) {
        ordered.push(m);
      }
    }
    // v11 调试:打印最后一条消息的关键信息(不打印正文)
    if (ordered.length > 0) {
      const last: ChatMessage = ordered[ordered.length - 1];
      Logger.info(LOG_TAG, 'loadMessages count=' + ordered.length
        + ' lastId=' + last.id.substring(0, 8)
        + ' lastSenderType=' + last.senderType
        + ' lastVisibility=' + (last.visibility !== undefined ? last.visibility : 'undefined'));
    }
    this.messages = await this.buildMessageItems(ordered);
  }

  /** 将 ChatMessage 列表转换为展示项 */
  private async buildMessageItems(messages: ChatMessage[]): Promise<WorldChatMessageItem[]> {
    const items: WorldChatMessageItem[] = [];
    for (let i = 0; i < messages.length; i++) {
      const m: ChatMessage = messages[i];
      const senderType: MessageSenderType = m.senderType !== undefined ? m.senderType : 'character';
      const senderCharacterId: string = m.senderCharacterId !== undefined ? m.senderCharacterId : '';
      let character: Character | null = null;
      let isDeleted: boolean = false;
      if (senderCharacterId.length > 0) {
        try {
          character = await this.characterService.getById(senderCharacterId);
          isDeleted = character === null;
        } catch (e) {
          isDeleted = true;
        }
      }
      let displayName: string = '';
      let avatarUri: string = '';
      if (senderType === 'user') {
        displayName = this.world !== null && this.world.userIdentity.userName.length > 0
          ? this.world.userIdentity.userName
          : '我';
      } else if (senderType === 'narrator') {
        displayName = '旁白';
      } else if (character !== null) {
        displayName = character.name;
        avatarUri = character.avatarUri;
      } else {
        displayName = '未知角色';
      }
      items.push({
        message: m,
        senderType: senderType,
        senderCharacterId: senderCharacterId,
        character: character,
        isCharacterDeleted: isDeleted,
        displayName: displayName,
        avatarUri: avatarUri
      });
    }
    return items;
  }

  /**
   * 发送用户消息。
   * 失败时设置 errorMessage。
   * v11 私聊:根据 sendScope 携带 visibility/recipientCharacterIds,
   * 并在发送前校验私聊目标角色仍在场、未静音、未被移除。
   */
  sendMessage(): void {
    if (this.disposed) {
      return;
    }
    if (!this.isSessionReady) {
      this.errorMessage = '会话未就绪';
      return;
    }
    if (this.isGenerating) {
      this.errorMessage = '正在生成中';
      return;
    }
    const text: string = this.inputText.trim();
    if (text.length === 0) {
      this.errorMessage = '请输入消息';
      return;
    }
    if (this.replyMode === 'designated' && this.designatedCharacterId.length === 0) {
      this.errorMessage = '请选择回复角色';
      this.showDesignatedPicker = true;
      return;
    }
    // v11 私聊范围校验
    const visibility: MessageVisibility =
      this.sendScope === 'private' ? 'private'
        : this.sendScope === 'narrator' ? 'narrator'
        : 'public';
    let recipientCharacterIds: string[] = [];
    if (visibility === 'private') {
      if (this.privateRecipientIds.length === 0) {
        this.errorMessage = '请选择至少一名私聊目标角色';
        this.showPrivateRecipientPicker = true;
        return;
      }
      // 校验目标角色仍在场、未静音、未被禁用
      const invalidNames: string[] = [];
      const validRecipientIds: string[] = [];
      for (let i = 0; i < this.privateRecipientIds.length; i++) {
        const cid: string = this.privateRecipientIds[i];
        const view: WorldMemberView | undefined =
          this.allMembers.find((v) => v.member.characterId === cid);
        if (view === undefined) {
          invalidNames.push(cid);
          continue;
        }
        if (!view.member.enabled) {
          invalidNames.push(view.character !== null ? view.character.name : cid);
          continue;
        }
        if (!view.member.present) {
          invalidNames.push((view.character !== null ? view.character.name : cid) + '(已离场)');
          continue;
        }
        if (view.member.muted) {
          invalidNames.push((view.character !== null ? view.character.name : cid) + '(已静音)');
          continue;
        }
        validRecipientIds.push(cid);
      }
      if (invalidNames.length > 0) {
        this.errorMessage = '以下目标角色无法私聊: ' + invalidNames.join('、') + ',请重新选择';
        this.showPrivateRecipientPicker = true;
        return;
      }
      recipientCharacterIds = validRecipientIds;
    }
    this.errorMessage = '';
    this.streamingPreview = '';
    this.statusMessage = '生成中...';
    this.isGenerating = true;

    const options: MultiPersonSendOptions = {
      userMessage: text,
      replyMode: this.replyMode,
      designatedCharacterId: this.replyMode === 'designated' ? this.designatedCharacterId : undefined,
      maxSpeakers: 2,
      visibility: visibility,
      recipientCharacterIds: visibility === 'private' ? recipientCharacterIds : undefined
    };

    const callbacks: MultiPersonStreamCallbacks = {
      onStart: () => {
        if (this.disposed) return;
        this.statusMessage = '生成中...';
        this.notifyStateUpdate();
      },
      onDelta: (accumulated: string) => {
        if (this.disposed) return;
        this.streamingPreview = accumulated;
        this.scheduleStreamFlush();
      },
      onCharacterStart: (characterId: string, characterName: string) => {
        if (this.disposed) return;
        this.statusMessage = characterName.length > 0
          ? `${characterName} 正在回复...`
          : '旁白生成中...';
        this.notifyStateUpdate();
      },
      onMessageReady: (message: ChatMessage) => {
        if (this.disposed) return;
        Logger.info(LOG_TAG, 'onMessageReady triggered');
        // 每条角色消息完整生成后,重新加载消息列表(替换乐观用户消息 + 追加新角色消息)
        this.loadMessages().then((): void => {
          if (this.disposed) return;
          Logger.info(LOG_TAG, 'onMessageReady loadMessages ok count=' + this.messages.length);
          this.notifyMessagesUpdate();
          this.notifyStateUpdate();
        }).catch((e: Object): void => {
          Logger.error(LOG_TAG, 'onMessageReady loadMessages failed: ' + (e as Error).message);
        });
      },
      onComplete: (persistedMessages: ChatMessage[]) => {
        if (this.disposed) return;
        Logger.info(LOG_TAG, 'onComplete triggered count=' + persistedMessages.length);
        this.isGenerating = false;
        this.streamingPreview = '';
        this.statusMessage = '';
        this.inputText = '';
        // 立即清空流式预览
        this.notifyStreamingUpdate('');
        this.notifyStateUpdate();
        // 最终刷新(确保消息列表与 DB 一致)
        this.appendPersistedMessages(persistedMessages).then((): void => {
          Logger.info(LOG_TAG, 'onComplete appendPersistedMessages ok count=' + this.messages.length);
          this.notifyMessagesUpdate();
          this.notifyStateUpdate();
        }).catch((e: Object): void => {
          Logger.error(LOG_TAG, 'onComplete appendPersistedMessages failed: ' + (e as Error).message);
        });
      },
      onError: (message: string) => {
        if (this.disposed) return;
        Logger.error(LOG_TAG, 'onError: ' + message);
        this.isGenerating = false;
        this.streamingPreview = '';
        this.statusMessage = '';
        this.errorMessage = message;
        // 重新加载以替换乐观用户消息为真实用户消息(失败时真实用户消息已持久化)
        this.loadMessages().then((): void => {
          if (this.disposed) return;
          this.notifyMessagesUpdate();
          this.notifyStreamingUpdate('');
          this.notifyStateUpdate();
        }).catch((e: Object): void => {
          Logger.error(LOG_TAG, 'onError loadMessages failed: ' + (e as Error).message);
        });
      },
      onStateChanged: (state: MultiPersonChatState) => {
        if (this.disposed) return;
        if (state === MultiPersonChatState.Cancelled) {
          this.isGenerating = false;
          this.streamingPreview = '';
          this.statusMessage = '已停止';
          // 停止后重新加载,保留已完整生成的消息,丢弃残缺消息
          this.loadMessages().then((): void => {
            if (this.disposed) return;
            this.notifyMessagesUpdate();
            this.notifyStreamingUpdate('');
            this.notifyStateUpdate();
          }).catch((e: Object): void => {
            Logger.error(LOG_TAG, 'onStateChanged loadMessages failed: ' + (e as Error).message);
          });
        }
      }
    };

    // 乐观追加用户消息到 UI(后台服务会持久化)
    this.appendOptimisticUserMessage(text);
    // 立即通知页面显示用户消息
    this.notifyMessagesUpdate();
    this.notifyStateUpdate();

    this.multiPersonChatService.sendUserMessage(options, callbacks);
  }

  /** 通知页面:消息列表已更新 */
  private notifyMessagesUpdate(): void {
    if (this.disposed) return;
    if (this.onMessagesUpdate !== undefined) {
      this.onMessagesUpdate([...this.messages]);
    }
  }

  /** 通知页面:流式预览已更新 */
  private notifyStreamingUpdate(preview: string): void {
    if (this.disposed) return;
    if (this.onStreamingUpdate !== undefined) {
      this.onStreamingUpdate(preview);
    }
  }

  /** 通知页面:生成状态/错误信息等已更新 */
  private notifyStateUpdate(): void {
    if (this.disposed) return;
    if (this.onStateUpdate !== undefined) {
      this.onStateUpdate();
    }
  }

  /**
   * 流式预览节流 flush(参照 ChatViewModel.scheduleMessagesFlush)。
   * 高频 delta 时合并到 50ms 一次,避免 ArkUI 在同一 tick 内合并多次赋值。
   */
  private scheduleStreamFlush(): void {
    if (this.streamFlushTimerId !== -1) {
      return;
    }
    const now: number = Date.now();
    const elapsed: number = now - this.lastStreamFlushTime;
    if (elapsed >= WorldChatViewModel.STREAM_FLUSH_INTERVAL_MS) {
      this.flushStream();
    } else {
      const delay: number = WorldChatViewModel.STREAM_FLUSH_INTERVAL_MS - elapsed;
      this.streamFlushTimerId = setTimeout((): void => {
        this.flushStream();
      }, delay);
    }
  }

  private flushStream(): void {
    this.streamFlushTimerId = -1;
    this.lastStreamFlushTime = Date.now();
    if (this.disposed) return;
    this.notifyStreamingUpdate(this.streamingPreview);
  }

  /** 乐观追加用户消息(立即显示在 UI 上) */
  private appendOptimisticUserMessage(text: string): void {
    const optimisticId: string = 'optimistic-' + Date.now().toString();
    const optimisticCreatedAt: number = Date.now();
    const baseMsg: ChatMessage = createChatMessage(optimisticId, ChatRole.User, text, optimisticCreatedAt);
    // v11 私聊:乐观消息也携带 visibility/recipientCharacterIds,确保 UI 立即显示标识
    const visibility: MessageVisibility =
      this.sendScope === 'private' ? 'private'
        : this.sendScope === 'narrator' ? 'narrator'
        : 'public';
    const optimistic: ChatMessage = {
      id: baseMsg.id,
      role: baseMsg.role,
      content: baseMsg.content,
      createdAt: baseMsg.createdAt,
      status: ChatMessageStatus.Completed,
      isStreaming: false,
      source: ChatMessageSource.Conversation,
      senderType: 'user',
      senderCharacterId: '',
      sceneId: this.currentSceneId,
      generationBatchId: '',
      visibility: visibility,
      recipientCharacterIds: visibility === 'private' ? [...this.privateRecipientIds] : undefined
    };
    const item: WorldChatMessageItem = {
      message: optimistic,
      senderType: 'user',
      senderCharacterId: '',
      character: null,
      isCharacterDeleted: false,
      displayName: this.world !== null && this.world.userIdentity.userName.length > 0
        ? this.world.userIdentity.userName
        : '我',
      avatarUri: ''
    };
    this.messages = [...this.messages, item];
  }

  /** 追加持久化的角色/旁白消息 */
  private async appendPersistedMessages(persisted: ChatMessage[]): Promise<void> {
    if (persisted.length === 0) {
      await this.loadMessages();
      return;
    }
    // 重新加载以获取正确顺序(包含真实用户消息 + 持久化的角色消息)
    await this.loadMessages();
  }

  /** 停止生成 */
  stopGeneration(): void {
    if (this.disposed) {
      return;
    }
    this.multiPersonChatService.stopGeneration();
    this.isGenerating = false;
    this.streamingPreview = '';
    this.statusMessage = '已停止';
  }

  /** 切换回复模式 */
  async setReplyMode(mode: WorldReplyMode): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      await this.multiPersonChatService.setReplyMode(mode);
      this.replyMode = mode;
      this.showReplyModePicker = false;
      if (mode !== 'designated') {
        this.designatedCharacterId = '';
        this.showDesignatedPicker = false;
      }
    } catch (e) {
      this.errorMessage = '切换回复模式失败';
      Logger.error(LOG_TAG, 'setReplyMode failed: ' + String(e));
    }
  }

  /** 设置指定角色 */
  setDesignatedCharacter(characterId: string): void {
    this.designatedCharacterId = characterId;
    this.showDesignatedPicker = false;
  }

  /** 切换当前场景 */
  async setCurrentScene(sceneId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      await this.multiPersonChatService.setCurrentScene(sceneId);
      this.currentSceneId = sceneId;
      this.currentScene = await this.worldService.getScene(sceneId);
      this.showScenePicker = false;
      // 刷新在场成员(场景切换可能改变在场状态)
      await this.loadMembers();
    } catch (e) {
      this.errorMessage = '切换场景失败';
      Logger.error(LOG_TAG, 'setCurrentScene failed: ' + String(e));
    }
  }

  /** 刷新所有数据 */
  async refresh(): Promise<void> {
    if (this.disposed || !this.isSessionReady) {
      return;
    }
    await Promise.all([
      this.loadWorldAndChat(),
      this.loadMembers(),
      this.loadScenes(),
      this.loadMessages()
    ]);
  }

  /** 打开/关闭指定角色选择器 */
  toggleDesignatedPicker(): void {
    this.showDesignatedPicker = !this.showDesignatedPicker;
  }

  /** 打开/关闭回复模式选择器 */
  toggleReplyModePicker(): void {
    this.showReplyModePicker = !this.showReplyModePicker;
  }

  /** 打开/关闭场景选择器 */
  toggleScenePicker(): void {
    this.showScenePicker = !this.showScenePicker;
  }

  // ===== v11 私聊:发送范围管理 =====

  /** 打开/关闭发送范围选择面板 */
  toggleScopePicker(): void {
    this.showScopePicker = !this.showScopePicker;
    // 关闭范围面板时,若选中私聊且未选角色,自动打开角色多选面板
    if (!this.showScopePicker && this.sendScope === 'private' && this.privateRecipientIds.length === 0) {
      this.showPrivateRecipientPicker = true;
    }
    this.notifyStateUpdate();
  }

  /** 打开/关闭私聊目标角色多选面板 */
  togglePrivateRecipientPicker(): void {
    this.showPrivateRecipientPicker = !this.showPrivateRecipientPicker;
    this.notifyStateUpdate();
  }

  /**
   * 设置发送范围。
   * - 切换到 'private' 时若未选角色,自动打开角色多选面板
   * - 切换到非 'private' 时清空目标角色列表,关闭角色多选面板
   */
  setSendScope(scope: SendScope): void {
    this.sendScope = scope;
    this.showScopePicker = false;
    if (scope === 'private') {
      // 自动打开角色多选面板(若已选角色则保持)
      if (this.privateRecipientIds.length === 0) {
        this.showPrivateRecipientPicker = true;
      }
    } else {
      // 切换到非私聊:清空目标角色,关闭角色多选面板
      this.privateRecipientIds = [];
      this.showPrivateRecipientPicker = false;
    }
    this.notifyStateUpdate();
  }

  /**
   * 切换某个私聊目标角色的选中状态(多选)。
   */
  togglePrivateRecipient(characterId: string): void {
    const idx: number = this.privateRecipientIds.indexOf(characterId);
    if (idx >= 0) {
      // 已选 -> 取消
      const next: string[] = [];
      for (let i = 0; i < this.privateRecipientIds.length; i++) {
        if (i !== idx) {
          next.push(this.privateRecipientIds[i]);
        }
      }
      this.privateRecipientIds = next;
    } else {
      // 未选 -> 选中
      this.privateRecipientIds = [...this.privateRecipientIds, characterId];
    }
    this.notifyStateUpdate();
  }

  /** 清空私聊目标角色列表 */
  clearPrivateRecipients(): void {
    this.privateRecipientIds = [];
    this.notifyStateUpdate();
  }

  /** 确认私聊目标角色选择(关闭多选面板) */
  confirmPrivateRecipients(): void {
    this.showPrivateRecipientPicker = false;
    // 若清空了目标角色,回退到公开范围
    if (this.privateRecipientIds.length === 0) {
      this.sendScope = 'public';
    }
    this.notifyStateUpdate();
  }

  /**
   * 获取当前发送范围的 UI 状态文本。
   * - public: '公开 · 所有人可见'
   * - private: '私聊 · 艾伦、绘梨衣' 或 '私聊 · 未选择目标'
   * - narrator: '旁白动作'
   */
  getScopeStatusText(): string {
    switch (this.sendScope) {
      case 'public':
        return '公开 · 所有人可见';
      case 'narrator':
        return '旁白动作';
      case 'private': {
        if (this.privateRecipientIds.length === 0) {
          return '私聊 · 未选择目标';
        }
        const names: string[] = [];
        for (let i = 0; i < this.privateRecipientIds.length; i++) {
          const cid: string = this.privateRecipientIds[i];
          const view: WorldMemberView | undefined =
            this.allMembers.find((v) => v.member.characterId === cid);
          if (view !== undefined && view.character !== null) {
            names.push(view.character.name);
          } else {
            names.push('未知角色');
          }
        }
        return '私聊 · ' + names.join('、');
      }
      default:
        return '';
    }
  }

  /**
   * 获取私聊目标角色名称列表(用于消息气泡上的"私聊给:XX"标识)。
   */
  getRecipientNames(recipientCharacterIds: string[] | undefined): string {
    if (recipientCharacterIds === undefined || recipientCharacterIds.length === 0) {
      return '';
    }
    const names: string[] = [];
    for (let i = 0; i < recipientCharacterIds.length; i++) {
      const cid: string = recipientCharacterIds[i];
      const view: WorldMemberView | undefined =
        this.allMembers.find((v) => v.member.characterId === cid);
      if (view !== undefined && view.character !== null) {
        names.push(view.character.name);
      } else {
        // 成员中找不到,尝试从 characterService 加载(异步,这里直接显示未知)
        names.push('未知角色');
      }
    }
    return names.join('、');
  }

  /** 更新输入文本 */
  updateInput(text: string): void {
    this.inputText = text;
  }

  /** 清除错误 */
  clearError(): void {
    this.errorMessage = '';
  }

  dispose(): void {
    this.disposed = true;
    this.multiPersonChatService.dispose();
    this.messages = [];
    this.presentMembers = [];
    this.allMembers = [];
  }
}
