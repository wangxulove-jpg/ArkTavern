/**
 * MultiPersonChatService 多人世界聊天编排服务
 *
 * 职责:
 * - 多人世界会话初始化(加载 world / members / scene / chat link / root branch)
 * - 用户消息持久化(senderType='user')
 * - 多人 Prompt 构建(委托 MultiPersonPromptBuilder)
 * - 模型流式请求(委托 ModelService.streamCurrentChat)
 * - 结构化响应解析(委托 MultiPersonResponseParser)
 * - 整轮原子持久化(同一 generationBatchId 的多条消息)
 * - 场景更新 / 关系更新 / 记忆事件(尽力而为,不阻塞消息保存)
 * - 失败回滚(整轮不保存半轮消息)
 * - 停止生成(abort 流 + 失效旧回调)
 *
 * 不负责:
 * - 单角色聊天(走 ChatService)
 * - 角色卡管理(走 CharacterService)
 * - 分支 fork / swipe 切换(走 ConversationBranchPersistenceService)
 *
 * 规则:
 * - 每轮生成使用唯一 generationBatchId 关联多条消息
 * - JSON 解析失败 / 校验失败 / 用户停止 → 整轮不保存
 * - 关系 / 记忆更新失败 → 不回滚消息,记录日志
 * - 不打印消息正文 / 角色ID / chatId / 关系字段
 * - 不替用户说话(模型返回 user 消息时整轮拒绝)
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { WorldService } from './WorldService';
import { WorldRelationshipService } from './WorldRelationshipService';
import { WorldMemoryService, GenerateRoundMemoryInput, RoundMemoryResult } from './WorldMemoryService';
import { SpeakerScheduler, SpeakerCandidate } from './SpeakerScheduler';
import {
  MultiPersonPromptBuilder,
  SingleCharacterPromptInput,
  NarratorPromptInput
} from './MultiPersonPromptBuilder';
import { MultiPersonResponseParser } from './MultiPersonResponseParser';
import { MessageRepository } from '../repositories/MessageRepository';
import { ChatRepository } from '../repositories/ChatRepository';
import { CharacterRepository } from '../repositories/CharacterRepository';
import { ConversationBranchRepository } from '../repositories/ConversationBranchRepository';
import { ModelService } from './ModelService';
import {
  ChatMessage,
  ChatMessageStatus,
  MessageVisibility,
  createChatMessage
} from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatDelta,
  ChatStreamResult
} from '../models/ChatStreamTypes';
import { ChatRequestOptions } from '../models/ChatRequest';
import { MAX_TOKENS_DEFAULT } from '../models/ProviderConfig';
import { NetworkError } from '../models/NetworkError';
import { World, WorldReplyMode } from '../models/World';
import { WorldMember } from '../models/WorldMember';
import { WorldScene } from '../models/WorldScene';
import { WorldChatLink } from '../models/WorldChatLink';
import { Character } from '../models/Character';
import {
  CharacterUserRelationship,
  CharacterRelationship
} from '../models/WorldRelationship';
import { WorldMemoryEvent, WorldPrivateMemory } from '../models/WorldMemory';
import { DatabaseError } from '../models/DatabaseError';
import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MultiPersonChatService';
const RECENT_MESSAGES_LIMIT: number = 20;

/**
 * 多人聊天状态。
 */
export enum MultiPersonChatState {
  Idle = 'Idle',
  Streaming = 'Streaming',
  Completed = 'Completed',
  Cancelled = 'Cancelled',
  Failed = 'Failed'
}

/**
 * 发送用户消息的选项。
 */
export interface MultiPersonSendOptions {
  readonly userMessage: string;
  /** 覆盖当前回复模式(可选) */
  readonly replyMode?: WorldReplyMode;
  /** 指定角色回复模式的角色 ID */
  readonly designatedCharacterId?: string;
  /** 自动导演模式最大发言者数(默认 2) */
  readonly maxSpeakers?: number;
  /**
   * 用户消息可见范围(v11 私聊引入)。
   * - 'public': 公开发言,所有在场角色可知(默认)
   * - 'private': 私下交谈,仅 recipientCharacterIds 可知
   * - 'narrator': 旁白动作,作为场景描述处理
   */
  readonly visibility?: MessageVisibility;
  /**
   * 私聊目标角色 ID 列表(visibility='private' 时必填)。
   * 私聊模式下,发言候选角色仅限此列表。
   */
  readonly recipientCharacterIds?: string[];
  /**
   * 旁白动作参与者 ID 列表(visibility='narrator' 时使用)。
   * 默认为空,空时视为所有在场角色可见。
   */
  readonly participantIds?: string[];
  /**
   * 旁白动作目击者 ID 列表(visibility='narrator' 时使用)。
   */
  readonly witnessIds?: string[];
}

/**
 * 流式回调。
 */
export interface MultiPersonStreamCallbacks {
  onStart?: () => void;
  /** 流式增量(当前角色累积原始文本,未解析) */
  onDelta: (accumulatedText: string) => void;
  /** 单条消息已完整生成并持久化(新架构:多角色逐个生成时每完成一个就回调) */
  onMessageReady?: (message: ChatMessage) => void;
  /** 某个角色开始生成(新架构) */
  onCharacterStart?: (characterId: string, characterName: string) => void;
  /** 整轮完成时返回所有持久化消息列表(向后兼容) */
  onComplete: (messages: ChatMessage[]) => void;
  onError: (message: string) => void;
  onStateChanged?: (state: MultiPersonChatState) => void;
}

/**
 * 会话初始化结果。
 */
export interface MultiPersonSessionInfo {
  readonly chatId: string;
  readonly worldId: string;
  readonly branchId: string;
  readonly currentSceneId: string;
  readonly replyMode: WorldReplyMode;
}

export class MultiPersonChatService {
  private readonly dbHelper: DbHelper;
  private readonly worldService: WorldService;
  private readonly worldRelationshipService: WorldRelationshipService;
  private readonly worldMemoryService: WorldMemoryService;
  private readonly messageRepository: MessageRepository;
  private readonly chatRepository: ChatRepository;
  private readonly characterRepository: CharacterRepository;
  private readonly branchRepository: ConversationBranchRepository;
  private readonly modelService: ModelService;
  private readonly promptBuilder: MultiPersonPromptBuilder;
  private readonly responseParser: MultiPersonResponseParser;
  private readonly speakerScheduler: SpeakerScheduler;

  // 会话状态
  private chatId: string = '';
  private worldId: string = '';
  private branchId: string = '';
  private currentSceneId: string = '';
  private replyMode: WorldReplyMode = 'auto_director';

  // 生成状态
  private state: MultiPersonChatState = MultiPersonChatState.Idle;
  private generationOperationId: number = 0;
  private currentStreamHandle: ChatStreamHandle | null = null;
  private disposed: boolean = false;

  constructor(
    dbHelper: DbHelper,
    worldService: WorldService,
    worldRelationshipService: WorldRelationshipService,
    worldMemoryService: WorldMemoryService,
    messageRepository: MessageRepository,
    chatRepository: ChatRepository,
    characterRepository: CharacterRepository,
    branchRepository: ConversationBranchRepository,
    modelService: ModelService,
    promptBuilder: MultiPersonPromptBuilder,
    responseParser: MultiPersonResponseParser,
    speakerScheduler: SpeakerScheduler
  ) {
    this.dbHelper = dbHelper;
    this.worldService = worldService;
    this.worldRelationshipService = worldRelationshipService;
    this.worldMemoryService = worldMemoryService;
    this.messageRepository = messageRepository;
    this.chatRepository = chatRepository;
    this.characterRepository = characterRepository;
    this.branchRepository = branchRepository;
    this.modelService = modelService;
    this.promptBuilder = promptBuilder;
    this.responseParser = responseParser;
    this.speakerScheduler = speakerScheduler;
  }

  /**
   * 初始化多人会话。
   * 加载 chat link / world / scene / root branch,确保 branch 存在并设为 active。
   */
  async initialize(chatId: string): Promise<MultiPersonSessionInfo> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('chatId empty');
    }
    const link: WorldChatLink | null = await this.worldService.getChatLink(chatId);
    if (link === null) {
      throw DatabaseError.notFound('world chat link not found');
    }
    const world: World | null = await this.worldService.getWorld(link.worldId);
    if (world === null) {
      throw DatabaseError.notFound('world not found');
    }
    const sceneId: string = link.currentSceneId !== null ? link.currentSceneId : '';
    if (sceneId.length === 0) {
      throw DatabaseError.invalidData('currentSceneId empty');
    }
    // 确保 root branch 存在并设为 active
    const branchId: string = await this.ensureRootBranch(chatId);

    this.chatId = chatId;
    this.worldId = link.worldId;
    this.branchId = branchId;
    this.currentSceneId = sceneId;
    this.replyMode = link.replyMode;

    Logger.info(LOG_TAG, 'initialize ok');
    return {
      chatId: chatId,
      worldId: this.worldId,
      branchId: this.branchId,
      currentSceneId: this.currentSceneId,
      replyMode: this.replyMode
    };
  }

  /**
   * 设置当前回复模式。
   */
  async setReplyMode(mode: WorldReplyMode): Promise<void> {
    await this.worldService.updateChatReplyMode(this.chatId, mode);
    this.replyMode = mode;
  }

  /**
   * 设置当前场景。
   */
  async setCurrentScene(sceneId: string): Promise<void> {
    await this.worldService.setChatCurrentScene(this.chatId, sceneId);
    this.currentSceneId = sceneId;
  }

  /**
   * 发送用户消息并触发生成。
   * 流程:
   * 1. 校验状态 / 选项
   * 2. 持久化用户消息
   * 3. 加载上下文(成员 / 关系 / 记忆 / 最近消息)
   * 4. 调度发言者
   * 5. 构建 Prompt
   * 6. 流式请求
   * 7. 完成后解析 + 原子持久化
   */
  sendUserMessage(
    options: MultiPersonSendOptions,
    callbacks: MultiPersonStreamCallbacks
  ): void {
    if (this.disposed) {
      callbacks.onError('service disposed');
      return;
    }
    if (this.chatId.length === 0) {
      callbacks.onError('session not initialized');
      return;
    }
    if (this.state !== MultiPersonChatState.Idle
      && this.state !== MultiPersonChatState.Completed
      && this.state !== MultiPersonChatState.Cancelled
      && this.state !== MultiPersonChatState.Failed) {
      callbacks.onError('generation in progress');
      return;
    }
    if (options.userMessage.length === 0) {
      callbacks.onError('userMessage empty');
      return;
    }

    this.generationOperationId++;
    const operationId: number = this.generationOperationId;
    const isCurrent = (): boolean => operationId === this.generationOperationId;

    const effectiveReplyMode: WorldReplyMode =
      options.replyMode !== undefined ? options.replyMode : this.replyMode;
    const designatedCharacterId: string =
      options.designatedCharacterId !== undefined ? options.designatedCharacterId : '';
    const maxSpeakers: number =
      options.maxSpeakers !== undefined ? options.maxSpeakers : 2;

    // v11 私聊字段提取与校验
    const visibility: MessageVisibility =
      options.visibility !== undefined ? options.visibility : 'public';
    const recipientCharacterIds: string[] =
      options.recipientCharacterIds !== undefined ? [...options.recipientCharacterIds] : [];
    const participantIds: string[] =
      options.participantIds !== undefined ? [...options.participantIds] : [];
    const witnessIds: string[] =
      options.witnessIds !== undefined ? [...options.witnessIds] : [];
    if (visibility === 'private' && recipientCharacterIds.length === 0) {
      callbacks.onError('私聊必须选择至少一名目标角色');
      return;
    }
    if (visibility !== 'private' && recipientCharacterIds.length > 0) {
      callbacks.onError('仅私聊模式可设置目标角色');
      return;
    }

    this.setState(MultiPersonChatState.Streaming, callbacks);

    // 异步执行完整流程
    this.executeGeneration(
      options.userMessage,
      effectiveReplyMode,
      designatedCharacterId,
      maxSpeakers,
      visibility,
      recipientCharacterIds,
      participantIds,
      witnessIds,
      operationId,
      isCurrent,
      callbacks
    ).then((): void => {
      // 流程完成
    }, (err: Object): void => {
      if (!isCurrent()) {
        return;
      }
      Logger.error(LOG_TAG, 'generation failed: ' + (err as Error).message);
      this.setState(MultiPersonChatState.Failed, callbacks);
      callbacks.onError((err as Error).message);
    });
  }

  /**
   * 停止生成。
   * - abort 流式请求
   * - 递增 operationId 失效旧回调
   * - 不保存半轮消息
   */
  stopGeneration(): void {
    if (this.state !== MultiPersonChatState.Streaming) {
      return;
    }
    this.generationOperationId++;
    Logger.info(LOG_TAG, 'stopGeneration abort');
    if (this.currentStreamHandle !== null) {
      try {
        this.currentStreamHandle.abort();
      } catch (e) {
        // 忽略 abort 异常
      }
      this.currentStreamHandle = null;
    }
    this.setState(MultiPersonChatState.Cancelled, null);
  }

  /**
   * 释放资源。
   * - 标记 disposed
   * - abort 任何进行中的流
   * - 后续回调被忽略
   */
  dispose(): void {
    this.disposed = true;
    this.generationOperationId++;
    if (this.currentStreamHandle !== null) {
      try {
        this.currentStreamHandle.abort();
      } catch (e) {
        // 忽略
      }
      this.currentStreamHandle = null;
    }
  }

  getState(): MultiPersonChatState {
    return this.state;
  }

  // ===== 内部实现 =====

  private async executeGeneration(
    userMessage: string,
    replyMode: WorldReplyMode,
    designatedCharacterId: string,
    maxSpeakers: number,
    visibility: MessageVisibility,
    recipientCharacterIds: string[],
    participantIds: string[],
    witnessIds: string[],
    operationId: number,
    isCurrent: () => boolean,
    callbacks: MultiPersonStreamCallbacks
  ): Promise<void> {
    // 1. 持久化用户消息(携带 v11 visibility/recipient/participant/witness 字段)
    const userMessageId: string = generateUuid();
    const now: number = nowMillis();
    const baseUserMsg: ChatMessage = createChatMessage(userMessageId, ChatRole.User, userMessage, now);
    const userMsg: ChatMessage = {
      id: baseUserMsg.id,
      role: baseUserMsg.role,
      content: baseUserMsg.content,
      createdAt: baseUserMsg.createdAt,
      status: ChatMessageStatus.Completed,
      isStreaming: false,
      source: ChatMessageSource.Conversation,
      senderType: 'user',
      sceneId: this.currentSceneId,
      visibility: visibility,
      recipientCharacterIds: visibility === 'private' ? recipientCharacterIds : undefined,
      participantIds: visibility === 'narrator' && participantIds.length > 0 ? participantIds : undefined,
      witnessIds: visibility === 'narrator' && witnessIds.length > 0 ? witnessIds : undefined
    };
    let userSequence: number = await this.messageRepository.getMaxSequenceNumber(this.chatId);
    await this.messageRepository.insert(userMsg, this.chatId, userSequence + 1);
    // 链接到 branch
    await this.linkMessageToBranch(userMessageId);
    // 更新 chat 活跃时间
    await this.chatRepository.updateLastMessageAt(this.chatId, now, now);

    if (!isCurrent()) {
      return;
    }

    // 2. 加载世界 / 成员 / 场景
    const world: World | null = await this.worldService.getWorld(this.worldId);
    if (world === null) {
      throw new Error('world not found');
    }
    if (!isCurrent()) return;

    const members: WorldMember[] = await this.worldService.listMembers(this.worldId)
      .then((views) => views.map((v) => v.member));
    if (!isCurrent()) return;

    const scene: WorldScene | null = await this.worldService.getScene(this.currentSceneId);
    if (!isCurrent()) return;

    const recentMessages: ChatMessage[] = await this.loadRecentMessages();
    if (!isCurrent()) return;

    // 3. 仅旁白模式:单独走旁白生成流程
    if (replyMode === 'narrator_only') {
      await this.executeNarratorGeneration(
        world, scene, members, recentMessages, userMessage,
        visibility, recipientCharacterIds,
        operationId, isCurrent, callbacks
      );
      return;
    }

    // 4. 调度发言者
    // v11 私聊模式:候选池限制为 recipientCharacterIds 中的角色
    // v11 旁白动作模式:不限制候选池(角色可对旁白动作做公开回应)
    const schedulerMembers: WorldMember[] = visibility === 'private'
      ? members.filter((m: WorldMember) => recipientCharacterIds.indexOf(m.characterId) >= 0)
      : members;
    if (visibility === 'private' && schedulerMembers.length === 0) {
      throw new Error('私聊目标角色均不在世界成员中');
    }

    // v11 私聊 + designated 模式:若 designatedCharacterId 不在私聊目标中,
    // 自动调整为 recipientCharacterIds[0],避免 SpeakerScheduler 找不到指定角色而返回空候选。
    // 符合用户需求:"私聊状态下,指定角色只能选择私聊目标角色"。
    let effectiveDesignatedCharacterId: string = designatedCharacterId;
    if (visibility === 'private' && replyMode === 'designated') {
      if (recipientCharacterIds.indexOf(designatedCharacterId) < 0) {
        effectiveDesignatedCharacterId = recipientCharacterIds[0];
        Logger.info(LOG_TAG, 'private+designated: adjust designatedCharacterId to first recipient');
      }
    }

    const userRelationships: Map<string, CharacterUserRelationship> = new Map();
    for (let i = 0; i < schedulerMembers.length; i++) {
      const m = schedulerMembers[i];
      const rel = await this.worldRelationshipService.getUserRelationship(
        this.worldId, this.chatId, this.branchId, m.characterId
      );
      if (rel !== null) {
        userRelationships.set(m.characterId, rel);
      }
    }
    if (!isCurrent()) return;

    const candidates: SpeakerCandidate[] = this.speakerScheduler.schedule({
      replyMode: replyMode,
      designatedCharacterId: effectiveDesignatedCharacterId,
      members: schedulerMembers,
      scene: scene,
      recentMessages: recentMessages,
      userRelationships: userRelationships,
      maxSpeakers: maxSpeakers
    });
    if (candidates.length === 0) {
      throw new Error(visibility === 'private'
        ? '私聊目标角色均不可发言(可能已离场或被静音)'
        : 'no candidate speakers available');
    }
    if (!isCurrent()) return;

    // 5. 加载候选角色卡 + 在场角色卡
    const candidateCharacterIds: string[] = candidates.map((c) => c.characterId);
    const candidateCharacters: Character[] = [];
    const candidateMembers: WorldMember[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const cid = candidates[i].characterId;
      const ch: Character | null = await this.characterRepository.getById(cid);
      if (ch !== null) {
        candidateCharacters.push(ch);
      }
      const mem = members.find((m) => m.characterId === cid);
      if (mem !== undefined) {
        candidateMembers.push(mem);
      }
    }
    if (!isCurrent()) return;

    // 在场角色卡(让当前角色识别其他在场角色)
    const presentMembers: WorldMember[] = members.filter((m) => m.enabled && m.present);
    const presentCharacters: Character[] = [];
    for (let i = 0; i < presentMembers.length; i++) {
      const ch: Character | null = await this.characterRepository.getById(presentMembers[i].characterId);
      if (ch !== null) {
        presentCharacters.push(ch);
      }
    }
    if (!isCurrent()) return;

    // 6. 逐个候选角色依次生成
    const generationBatchId: string = generateUuid();
    const persistedMessages: ChatMessage[] = [];
    const sameRoundPreviousMessages: ChatMessage[] = [];

    for (let i = 0; i < candidateCharacters.length; i++) {
      if (!isCurrent()) {
        // 已停止或被替换:保留前面已完整生成的消息,不继续后续角色
        Logger.info(LOG_TAG, `executeGeneration stopped at character ${i}/${candidateCharacters.length}`);
        break;
      }
      const currentCharacter: Character = candidateCharacters[i];
      const currentMember: WorldMember | undefined = candidateMembers[i];
      if (currentMember === undefined) {
        Logger.warn(LOG_TAG, `skip candidate ${i}: member not found`);
        continue;
      }

      // 通知 ViewModel:某个角色开始生成
      if (callbacks.onCharacterStart !== undefined) {
        try {
          callbacks.onCharacterStart(currentCharacter.id, currentCharacter.name);
        } catch (e) {
          // 忽略回调异常
        }
      }

      // 加载当前角色的关系和记忆(单独加载,避免串角色)
      const userRel: CharacterUserRelationship | null =
        await this.worldRelationshipService.getUserRelationship(
          this.worldId, this.chatId, this.branchId, currentCharacter.id
        );
      if (!isCurrent()) break;

      const charRels: Map<string, CharacterRelationship> = new Map();
      for (let j = 0; j < presentCharacters.length; j++) {
        const otherId = presentCharacters[j].id;
        if (otherId === currentCharacter.id) continue;
        const rel = await this.worldRelationshipService.getCharacterRelationship(
          this.worldId, this.chatId, this.branchId, currentCharacter.id, otherId
        );
        if (rel !== null) {
          charRels.set(currentCharacter.id + '>' + otherId, rel);
        }
      }
      if (!isCurrent()) break;

      const visibleEvents: WorldMemoryEvent[] =
        await this.worldMemoryService.listVisibleEventsForCharacter(
          this.worldId, this.chatId, this.branchId, currentCharacter.id
        );
      if (!isCurrent()) break;

      const privateMems: WorldPrivateMemory[] =
        await this.worldMemoryService.listPrivateMemoriesForCharacter(
          this.worldId, this.chatId, this.branchId, currentCharacter.id
        );
      if (!isCurrent()) break;

      // v11 私聊可见性过滤:仅注入当前角色有权可见的消息
      //   - public 消息:所有角色可见
      //   - private 消息:仅 recipientCharacterIds 中的角色可见(当前角色必须在列表中)
      //   - narrator 消息:仅注入旁白可见范围(目前与 public 同等处理,旁白逻辑单独走 executeNarratorGeneration)
      const visibleRecentMessages: ChatMessage[] =
        filterMessagesForCharacter(recentMessages, currentCharacter.id);
      const visibleSameRoundMessages: ChatMessage[] =
        filterMessagesForCharacter(sameRoundPreviousMessages, currentCharacter.id);

      // 构建当前角色的 Prompt
      const promptInput: SingleCharacterPromptInput = {
        world: world,
        userIdentity: world.userIdentity,
        scene: scene,
        character: currentCharacter,
        member: currentMember,
        presentMembers: presentMembers,
        presentCharacters: presentCharacters,
        userRelationship: userRel,
        characterRelationships: charRels,
        visibleEvents: visibleEvents,
        privateMemories: privateMems,
        recentMessages: visibleRecentMessages,
        userMessage: userMessage,
        sameRoundPreviousMessages: visibleSameRoundMessages
      };
      const promptResult = this.promptBuilder.buildSingleCharacterPrompt(promptInput);

      // 流式请求(单角色)
      const characterMessage: ChatMessage | null = await this.streamSingleCharacter(
        currentCharacter,
        promptResult.messages,
        operationId,
        isCurrent,
        callbacks
      ).catch((err: Object): ChatMessage | null => {
        if (!isCurrent()) {
          // 已停止,不算失败
          return null;
        }
        Logger.error(LOG_TAG, `character ${i} stream failed: ` + (err as Error).message);
        // 单个角色失败:整轮失败,不继续后续角色
        this.setState(MultiPersonChatState.Failed, callbacks);
        callbacks.onError((err as Error).message);
        return null;
      });

      if (!isCurrent()) {
        // 停止或被替换:不保存残缺消息,保留已完整的
        break;
      }
      if (characterMessage === null) {
        // 失败:已通知 onError,直接退出循环
        return;
      }

      // 持久化这一条角色消息
      // v11 私聊模式:角色回复也标记为 private,recipientCharacterIds 与用户消息一致
      //   - 让其他私聊目标可见(多角色私聊时,A 的回复 B 能看到)
      //   - 让未参与角色在后续 Prompt 过滤中看不到这条回复
      const charVisibility: MessageVisibility = visibility === 'private' ? 'private' : 'public';
      const charRecipientIds: string[] | undefined = visibility === 'private' ? recipientCharacterIds : undefined;
      const persistedMsg: ChatMessage = await this.persistSingleCharacterMessage(
        characterMessage.content,
        currentCharacter.id,
        generationBatchId,
        charVisibility,
        charRecipientIds
      );
      persistedMessages.push(persistedMsg);
      // 加入同轮前序消息,供下一个角色参考
      sameRoundPreviousMessages.push(persistedMsg);

      // 通知 ViewModel:单条消息已就绪
      if (callbacks.onMessageReady !== undefined) {
        try {
          callbacks.onMessageReady(persistedMsg);
        } catch (e) {
          // 忽略回调异常
        }
      }

      // 清空流式预览(准备下一个角色)
      callbacks.onDelta('');
    }

    if (!isCurrent()) {
      // 停止:保留已生成的消息,状态由 stopGeneration 设置
      Logger.info(LOG_TAG, `executeGeneration interrupted, kept ${persistedMessages.length} messages`);
      return;
    }

    // 7. 整轮完成
    try {
      const finalNow: number = nowMillis();
      await this.chatRepository.updateLastMessageAt(this.chatId, finalNow, finalNow);
    } catch (e) {
      // 忽略
    }
    this.setState(MultiPersonChatState.Completed, callbacks);
    callbacks.onComplete(persistedMessages);

    // 8. 异步触发本轮记忆总结(不阻塞 onComplete,失败仅记录日志)
    // v11 私聊模式:只生成目标角色私人记忆,不创建公共事件
    this.triggerMemoryGeneration(
      userMessage,
      persistedMessages,
      candidateCharacters,
      presentCharacters,
      visibility,
      recipientCharacterIds
    );
  }

  /**
   * 异步触发本轮记忆总结。
   * - 收集本轮消息(用户消息 + 角色消息)
   * - 调用 WorldMemoryService.generateMemoriesForRound
   * - 失败仅记录日志,不影响主流程
   * - 不打印记忆正文
   * - v11 私聊模式:跳过公共事件生成,只为目标角色生成私人记忆
   */
  private triggerMemoryGeneration(
    userMessage: string,
    persistedMessages: ChatMessage[],
    speakerCharacters: Character[],
    presentCharacters: Character[],
    visibility: MessageVisibility,
    recipientCharacterIds: string[]
  ): void {
    // 异步执行,不 await,不阻塞 onComplete
    void this.doMemoryGeneration(
      userMessage, persistedMessages, speakerCharacters, presentCharacters,
      visibility, recipientCharacterIds
    ).catch((e: Object): void => {
      // 仅记录日志,不向上抛
      Logger.warn(LOG_TAG, `triggerMemoryGeneration uncaught: ${(e as Error).message}`);
    });
  }

  private async doMemoryGeneration(
    userMessage: string,
    persistedMessages: ChatMessage[],
    speakerCharacters: Character[],
    presentCharacters: Character[],
    visibility: MessageVisibility,
    recipientCharacterIds: string[]
  ): Promise<void> {
    try {
      // 构造本轮消息列表(用户消息 + 角色消息,按生成顺序)
      const now: number = nowMillis();
      const userMsg: ChatMessage = createChatMessage(
        'round-user-msg', ChatRole.User, userMessage, now
      );
      const roundMessages: ChatMessage[] = [userMsg, ...persistedMessages];

      // v11 私聊模式:只为目标角色生成私人记忆,不创建公共事件
      //   - 目标角色列表 = recipientCharacterIds(确保只为目标角色生成)
      //   - presentCharacters 传空数组,让 WorldMemoryService 跳过公共事件生成
      //   - speakerCharacters 限制为 recipientCharacterIds 中的发言角色
      const isPrivate: boolean = visibility === 'private';
      const effectiveSpeakers: Character[] = isPrivate
        ? speakerCharacters.filter((c: Character) => recipientCharacterIds.indexOf(c.id) >= 0)
        : speakerCharacters;
      const effectivePresent: Character[] = isPrivate ? [] : presentCharacters;

      const input: GenerateRoundMemoryInput = {
        worldId: this.worldId,
        chatId: this.chatId,
        branchId: this.branchId,
        sceneId: this.currentSceneId,
        roundMessages: roundMessages,
        speakerCharacters: effectiveSpeakers,
        presentCharacters: effectivePresent
      };
      const result: RoundMemoryResult = await this.worldMemoryService.generateMemoriesForRound(input);
      Logger.info(
        LOG_TAG,
        `memoryGeneration done private=${isPrivate} public=${result.publicEventCreated} private=${result.privateMemoriesCreated} failed=${result.failed}`
      );
    } catch (e) {
      Logger.warn(LOG_TAG, `doMemoryGeneration failed: ${(e as Error).message}`);
    }
  }

  /**
   * 单角色流式生成。
   * 返回完整正文文本(已去除角色名前缀和代码块标记),尚未持久化。
   */
  private streamSingleCharacter(
    character: Character,
    promptMessages: ChatMessage[],
    operationId: number,
    isCurrent: () => boolean,
    callbacks: MultiPersonStreamCallbacks
  ): Promise<ChatMessage | null> {
    return new Promise<ChatMessage | null>((resolve, reject): void => {
      if (!isCurrent()) {
        resolve(null);
        return;
      }
      const accumulatedText: string[] = [''];
      const requestOptions: ChatRequestOptions = {
        temperature: 0.75,  // 角色扮演需要适当随机性
        topP: 0.9,
        maxTokens: MAX_TOKENS_DEFAULT,
        stream: true
      };

      const streamCallbacks: ChatStreamCallbacks = {
        onStart: (): void => {
          if (!isCurrent()) return;
          if (callbacks.onStart !== undefined) {
            callbacks.onStart();
          }
        },
        onDelta: (delta: ChatDelta): void => {
          if (!isCurrent()) return;
          accumulatedText[0] += delta.content;
          callbacks.onDelta(accumulatedText[0]);
        },
        onComplete: (result: ChatStreamResult): void => {
          if (!isCurrent()) {
            resolve(null);
            return;
          }
          const fullText: string = result.content.length > 0
            ? result.content
            : accumulatedText[0];
          // 去除可能的角色名前缀和代码块标记(模型可能仍偶尔加上)
          const cleaned: string = stripCharacterNamePrefix(fullText, character.name);
          if (cleaned.trim().length === 0) {
            reject(new Error(`角色 ${character.name} 返回空内容`));
            return;
          }
          // 构造未持久化的 ChatMessage(调用方负责持久化)
          const msgId: string = generateUuid();
          const baseMsg: ChatMessage = createChatMessage(msgId, ChatRole.Assistant, cleaned, nowMillis());
          const msg: ChatMessage = {
            id: baseMsg.id,
            role: baseMsg.role,
            content: baseMsg.content,
            createdAt: baseMsg.createdAt,
            status: ChatMessageStatus.Completed,
            isStreaming: false,
            source: ChatMessageSource.Conversation,
            senderType: 'character',
            senderCharacterId: character.id,
            sceneId: this.currentSceneId
          };
          Logger.info(LOG_TAG, `streamSingleCharacter ok charId=${character.id} len=${cleaned.length}`);
          resolve(msg);
        },
        onError: (error: NetworkError): void => {
          if (!isCurrent()) {
            resolve(null);
            return;
          }
          Logger.error(LOG_TAG, `streamSingleCharacter error: ${error.message}`);
          reject(new Error(error.message));
        }
      };

      this.currentStreamHandle = this.modelService.streamCurrentChat(
        promptMessages,
        requestOptions,
        streamCallbacks
      );
    });
  }

  /**
   * 持久化单条角色消息(单事务)。
   * v11 私聊模式下,角色回复也携带 visibility='private' + recipientCharacterIds,
   * 让其他私聊目标可见,未参与角色在 Prompt 过滤中看不到。
   */
  private async persistSingleCharacterMessage(
    content: string,
    characterId: string,
    generationBatchId: string,
    visibility: MessageVisibility,
    recipientCharacterIds: string[] | undefined
  ): Promise<ChatMessage> {
    const now: number = nowMillis();
    const messageId: string = generateUuid();
    const baseMsg: ChatMessage = createChatMessage(messageId, ChatRole.Assistant, content, now);
    const msg: ChatMessage = {
      id: baseMsg.id,
      role: baseMsg.role,
      content: baseMsg.content,
      createdAt: baseMsg.createdAt,
      status: ChatMessageStatus.Completed,
      isStreaming: false,
      source: ChatMessageSource.Conversation,
      senderType: 'character',
      senderCharacterId: characterId,
      sceneId: this.currentSceneId,
      generationBatchId: generationBatchId,
      visibility: visibility,
      recipientCharacterIds: recipientCharacterIds
    };
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const maxSeq: number = await this.messageRepository.getMaxSequenceNumber(this.chatId);
        const maxPos: number = await this.branchRepository.getMaxPositionWithStore(store, this.branchId);
        Logger.info(LOG_TAG, 'persistSingleCharacterMessage branchId=' + this.branchId.substring(0, 8)
          + ' msgId=' + messageId.substring(0, 8)
          + ' maxSeq=' + maxSeq + ' maxPos=' + maxPos
          + ' vis=' + visibility);
        await this.messageRepository.insertWithStore(store, msg, this.chatId, maxSeq + 1);
        await this.branchRepository.insertMessageLinkWithStore(
          store, this.branchId, messageId, maxPos + 1
        );
      }
    );
    return msg;
  }

  /**
   * 旁白模式单独生成流程。
   * v11 私聊模式下走仅旁白回复:旁白本身不应知道私聊内容,recentMessages 已在外层持久化时携带 visibility,
   * 这里通过 filterMessagesForNarrator 过滤掉 private 消息避免泄露。
   */
  private async executeNarratorGeneration(
    world: World,
    scene: WorldScene | null,
    members: WorldMember[],
    recentMessages: ChatMessage[],
    userMessage: string,
    visibility: MessageVisibility,
    recipientCharacterIds: string[],
    operationId: number,
    isCurrent: () => boolean,
    callbacks: MultiPersonStreamCallbacks
  ): Promise<void> {
    // 通知"旁白"开始
    if (callbacks.onCharacterStart !== undefined) {
      try {
        callbacks.onCharacterStart('', '旁白');
      } catch (e) {
        // 忽略
      }
    }

    // 加载在场角色卡
    const presentMembers: WorldMember[] = members.filter((m) => m.enabled && m.present);
    const presentCharacters: Character[] = [];
    for (let i = 0; i < presentMembers.length; i++) {
      const ch: Character | null = await this.characterRepository.getById(presentMembers[i].characterId);
      if (ch !== null) {
        presentCharacters.push(ch);
      }
    }
    if (!isCurrent()) return;

    // 加载公共/场景记忆
    const allEvents: WorldMemoryEvent[] = await this.worldMemoryService.listEventsByBranch(
      this.worldId, this.chatId, this.branchId
    );
    if (!isCurrent()) return;
    const publicMemories: WorldMemoryEvent[] = allEvents.filter(
      (e) => e.visibility === 'public' && e.enabled
    );
    const sceneMemories: WorldMemoryEvent[] = allEvents.filter(
      (e) => e.sceneId === this.currentSceneId && e.enabled
    );

    // v11 旁白不应知道私聊内容:过滤掉 private 消息
    const narratorVisibleMessages: ChatMessage[] = filterMessagesForNarrator(recentMessages);

    const promptInput: NarratorPromptInput = {
      world: world,
      userIdentity: world.userIdentity,
      scene: scene,
      presentMembers: presentMembers,
      presentCharacters: presentCharacters,
      publicMemories: publicMemories,
      sceneMemories: sceneMemories,
      recentMessages: narratorVisibleMessages,
      userMessage: userMessage
    };
    const promptResult = this.promptBuilder.buildNarratorPrompt(promptInput);

    // 流式请求(旁白)
    const narratorText: string | null = await new Promise<string | null>((resolve, reject): void => {
      if (!isCurrent()) {
        resolve(null);
        return;
      }
      const accumulatedText: string[] = [''];
      const requestOptions: ChatRequestOptions = {
        temperature: 0.7,
        topP: 0.9,
        maxTokens: MAX_TOKENS_DEFAULT,
        stream: true
      };
      const streamCallbacks: ChatStreamCallbacks = {
        onStart: (): void => {
          if (!isCurrent()) return;
          if (callbacks.onStart !== undefined) {
            callbacks.onStart();
          }
        },
        onDelta: (delta: ChatDelta): void => {
          if (!isCurrent()) return;
          accumulatedText[0] += delta.content;
          callbacks.onDelta(accumulatedText[0]);
        },
        onComplete: (result: ChatStreamResult): void => {
          if (!isCurrent()) {
            resolve(null);
            return;
          }
          const fullText: string = result.content.length > 0
            ? result.content
            : accumulatedText[0];
          resolve(fullText);
        },
        onError: (error: NetworkError): void => {
          if (!isCurrent()) {
            resolve(null);
            return;
          }
          Logger.error(LOG_TAG, `narrator stream error: ${error.message}`);
          reject(new Error(error.message));
        }
      };
      this.currentStreamHandle = this.modelService.streamCurrentChat(
        promptResult.messages,
        requestOptions,
        streamCallbacks
      );
    }).catch((err: Object): string | null => {
      if (!isCurrent()) {
        return null;
      }
      Logger.error(LOG_TAG, 'narrator stream failed: ' + (err as Error).message);
      this.setState(MultiPersonChatState.Failed, callbacks);
      callbacks.onError((err as Error).message);
      return null;
    });

    if (!isCurrent()) {
      return;
    }
    if (narratorText === null) {
      // 失败:已通知 onError
      return;
    }

    const cleaned: string = narratorText.trim();
    if (cleaned.length === 0) {
      this.setState(MultiPersonChatState.Failed, callbacks);
      callbacks.onError('旁白返回空内容');
      return;
    }

    // 持久化 narrator 消息
    const generationBatchId: string = generateUuid();
    const persistedMsg: ChatMessage = await this.persistNarratorMessage(cleaned, generationBatchId);

    if (callbacks.onMessageReady !== undefined) {
      try {
        callbacks.onMessageReady(persistedMsg);
      } catch (e) {
        // 忽略
      }
    }

    try {
      const finalNow: number = nowMillis();
      await this.chatRepository.updateLastMessageAt(this.chatId, finalNow, finalNow);
    } catch (e) {
      // 忽略
    }
    this.setState(MultiPersonChatState.Completed, callbacks);
    callbacks.onComplete([persistedMsg]);
  }

  /**
   * 持久化单条旁白消息(单事务)。
   */
  private async persistNarratorMessage(
    content: string,
    generationBatchId: string
  ): Promise<ChatMessage> {
    const now: number = nowMillis();
    const messageId: string = generateUuid();
    const baseMsg: ChatMessage = createChatMessage(messageId, ChatRole.System, content, now);
    const msg: ChatMessage = {
      id: baseMsg.id,
      role: baseMsg.role,
      content: baseMsg.content,
      createdAt: baseMsg.createdAt,
      status: ChatMessageStatus.Completed,
      isStreaming: false,
      source: ChatMessageSource.Conversation,
      senderType: 'narrator',
      sceneId: this.currentSceneId,
      generationBatchId: generationBatchId
    };
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const maxSeq: number = await this.messageRepository.getMaxSequenceNumber(this.chatId);
        const maxPos: number = await this.branchRepository.getMaxPositionWithStore(store, this.branchId);
        await this.messageRepository.insertWithStore(store, msg, this.chatId, maxSeq + 1);
        await this.branchRepository.insertMessageLinkWithStore(
          store, this.branchId, messageId, maxPos + 1
        );
      }
    );
    return msg;
  }

  /**
   * 加载最近消息(用于 Prompt 上下文)。
   */
  private async loadRecentMessages(): Promise<ChatMessage[]> {
    const messages: ChatMessage[] = await this.messageRepository.listByChat(
      this.chatId,
      { limit: RECENT_MESSAGES_LIMIT, ascending: false }
    );
    // 反转为时间正序
    return messages.reverse();
  }

  /**
   * 确保 root branch 存在并设为 active。
   */
  private async ensureRootBranch(chatId: string): Promise<string> {
    let branchId: string = '';
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const root = await this.branchRepository.getRootBranchWithStore(store, chatId);
        if (root !== null) {
          branchId = root.id;
        } else {
          const newRoot = await this.branchRepository.createRootBranchWithStore(store, chatId);
          branchId = newRoot.id;
        }
        // 确保设为 active
        await this.branchRepository.setActiveBranchWithStore(store, chatId, branchId);
      }
    );
    return branchId;
  }

  /**
   * 链接消息到当前 branch。
   */
  private async linkMessageToBranch(messageId: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const maxPos: number = await this.branchRepository.getMaxPositionWithStore(store, this.branchId);
    Logger.info(LOG_TAG, 'linkMessageToBranch branchId=' + this.branchId.substring(0, 8)
      + ' msgId=' + messageId.substring(0, 8)
      + ' maxPos=' + maxPos);
    await this.branchRepository.insertMessageLinkWithStore(
      store, this.branchId, messageId, maxPos + 1
    );
  }

  private setState(
    state: MultiPersonChatState,
    callbacks: MultiPersonStreamCallbacks | null
  ): void {
    this.state = state;
    if (callbacks !== null && callbacks.onStateChanged !== undefined) {
      try {
        callbacks.onStateChanged(state);
      } catch (e) {
        // 忽略回调异常
      }
    }
  }
}

/**
 * 去除模型可能输出的角色名前缀、代码块标记、解释性前缀。
 *
 * 新架构下模型应只输出正文,但保险起见做清理:
 * 1. 去除 markdown 代码块标记 ```json...``` 或 ```...```
 * 2. 去除 "角色名: " 或 "角色名：" 前缀
 * 3. 去除开头的解释性前缀行(如"好的,这是XX的回复:")
 *
 * 不做更激进的格式转换,保留正文原样。
 */
function stripCharacterNamePrefix(text: string, characterName: string): string {
  if (text.length === 0) {
    return text;
  }
  let result: string = text;

  // 1. 去除 markdown 代码块标记
  if (result.includes('```')) {
    const startIdx: number = result.indexOf('```');
    if (startIdx >= 0) {
      let contentStart: number = startIdx + 3;
      // 跳过语言标识行(如 json、JSON)
      const newlineAfterStart: number = result.indexOf('\n', contentStart);
      if (newlineAfterStart >= 0) {
        const langLine: string = result.substring(contentStart, newlineAfterStart).trim();
        if (langLine.length > 0 && langLine.length < 20) {
          contentStart = newlineAfterStart + 1;
        }
      }
      const endIdx: number = result.indexOf('```', contentStart);
      if (endIdx > contentStart) {
        result = result.substring(contentStart, endIdx);
      } else {
        result = result.substring(contentStart);
      }
    }
  }

  // 2. 去除 "角色名: " 或 "角色名：" 前缀
  const trimmedStart: string = result.trimStart();
  if (characterName.length > 0 && trimmedStart.startsWith(characterName)) {
    const afterName: string = trimmedStart.substring(characterName.length).trimStart();
    if (afterName.startsWith(':') || afterName.startsWith('：')) {
      result = afterName.substring(1).trimStart();
    }
  }

  // 3. 去除开头的解释性前缀行(如"好的,这是XX的回复:")
  const firstNewline: number = result.indexOf('\n');
  if (firstNewline > 0 && firstNewline < 100) {
    const firstLine: string = result.substring(0, firstNewline).trim();
    if (firstLine.length > 0 && firstLine.length < 50
      && (firstLine.includes('好的') || firstLine.includes('以下是')
        || firstLine.includes('这是') || firstLine.includes('的回复'))) {
      result = result.substring(firstNewline + 1);
    }
  }

  return result.trim();
}

/**
 * v11 私聊可见性过滤:为指定角色过滤消息列表。
 *
 * 规则:
 * - public 消息:所有角色可见,保留。
 * - private 消息:仅当当前角色 ID 出现在 recipientCharacterIds 中时保留。
 *   - 用户作为消息 sender 时,recipientCharacterIds 表示目标角色列表,目标角色可见。
 *   - 角色作为消息 sender 时(多角色私聊场景),recipientCharacterIds 表示同一私聊会话参与者列表,
 *     所有参与者(包括发言者本人)均可见,未参与者不可见。
 * - narrator 消息:作为场景描述,默认对所有在场角色可见(与 public 同等处理),
 *   细粒度的 participantIds/witnessIds 判断由调用方按需扩展,此处保持简化。
 * - 未设置 visibility 的旧消息视为 public,保留。
 *
 * 注意:过滤仅基于消息上的 visibility/recipientCharacterIds 元数据,
 * 不依赖外部 world/scene 状态,确保调用简单且可重复验证。
 */
function filterMessagesForCharacter(
  messages: ChatMessage[],
  characterId: string
): ChatMessage[] {
  const result: ChatMessage[] = [];
  for (let i = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i];
    const visibility: MessageVisibility = msg.visibility !== undefined ? msg.visibility : 'public';
    if (visibility === 'public' || visibility === 'narrator') {
      result.push(msg);
      continue;
    }
    if (visibility === 'private') {
      const recipients: string[] = msg.recipientCharacterIds !== undefined ? msg.recipientCharacterIds : [];
      if (recipients.indexOf(characterId) >= 0) {
        result.push(msg);
      }
      // 未在 recipientCharacterIds 中的角色:丢弃,不注入 Prompt
      continue;
    }
    // 未知 visibility 值:保守起见保留(向后兼容)
    result.push(msg);
  }
  return result;
}

/**
 * v11 旁白可见性过滤:为旁白生成过滤消息列表。
 *
 * 规则:
 * - public 消息:旁白可见,保留。
 * - narrator 消息:旁白可见,保留。
 * - private 消息:旁白不应知道私聊内容,丢弃。
 * - 未设置 visibility 的旧消息视为 public,保留。
 *
 * 注意:旁白作为"全知叙述者"角色,默认可见所有公开与场景信息,
 * 但严格隔离私聊内容,避免旁白在叙述中泄露用户与角色的私密对话。
 */
function filterMessagesForNarrator(messages: ChatMessage[]): ChatMessage[] {
  const result: ChatMessage[] = [];
  for (let i = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i];
    const visibility: MessageVisibility = msg.visibility !== undefined ? msg.visibility : 'public';
    if (visibility === 'private') {
      // 旁白不可见私聊消息
      continue;
    }
    result.push(msg);
  }
  return result;
}
