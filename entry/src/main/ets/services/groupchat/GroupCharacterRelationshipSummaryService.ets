/**
 * GroupCharacterRelationshipSummaryService 多人角色关系与经历手动总结服务
 *
 * G-MEMORY-AUTO-1B 引入。职责仅限于:
 * - 收集 owner 角色 A 在群聊中可见的有效消息(effectiveMessages)
 * - 识别关系对象白名单(用户 + 群聊其他角色)
 * - 构建严格 JSON Prompt(从 A 的视角总结 A 与其他对象的关系)
 * - 调用 ModelService(复用单聊 rolling 总结的调用参数)
 * - 严格 JSON 解析 + 候选校验(白名单 / 来源消息归属 / 字段非空)
 * - 计算 sourceHash(稳定哈希,防止重复创建)
 * - 返回待审核候选列表(draft)
 *
 * 不负责(本阶段禁止):
 * - 自动调度 / 轮次监听 / 后台队列
 * - Prompt 注入 / GroupPromptAssembler 修改
 * - 数据库写入(由 GroupCharacterRelationshipMemoryService.approveRelationshipSummary 负责)
 * - 数据库迁移 / 候选批次表
 *
 * 可见消息规则(任务第十六节):
 * 有效输入 = A 自己的消息 + A 可见的用户消息 + A 可见的角色 B 消息
 *
 * A 自己的消息:
 * - senderType === 'character'
 * - senderCharacterId === A
 * - status === Completed
 * - content 非空
 *
 * 用户公开消息(visibility='public'):
 * - senderType === 'user'
 * - visibility === 'public'
 * - status === Completed
 * - content 非空
 * - participantIds 非空 → 检查是否包含 A
 * - participantIds 缺失/为空 → 默认可见(公开消息兼容规则)
 *
 * 用户私聊 A:
 * - senderType === 'user'
 * - visibility === 'private'
 * - recipientCharacterIds 包含 A
 * - status === Completed
 * - content 非空
 *
 * 角色 B 公开消息:
 * - senderType === 'character'
 * - senderCharacterId !== A
 * - visibility === 'public'
 * - status === Completed
 * - content 非空
 * - 公开角色消息按公开语义对当前群聊成员可见
 *
 * 角色 B 私聊 A:
 * - senderType === 'character'
 * - senderCharacterId !== A
 * - visibility === 'private'
 * - recipientCharacterIds 包含 A
 * - status === Completed
 * - content 非空
 *
 * 排除:
 * - Failed / Cancelled / Streaming / 空内容
 * - 旁白消息(senderType='narrator' 或 visibility='narrator')
 * - 当前角色不可见的私聊
 * - 系统状态消息 / 错误卡片 / UI 状态
 *
 * sourceHash:
 * - 输入:ownerCharacterId + 按 sequenceNumber ASC 拼接的 message.id + senderType
 *   + senderCharacterId + visibility + content
 * - 算法:djb2 变体(确定性、非加密,无第三方依赖)
 * - 同一 groupConversationId + ownerCharacterId + sourceHash + sourceType='relationship_summary_v1'
 *   已存在时,不得再次调用模型
 *
 * 日志安全:
 * - 允许:owner 角色 short ID、来源消息数量、sourceHash 前 8 位、候选数量、总结开始/完成/失败
 * - 禁止:完整角色发言、完整 Prompt、完整模型输出、API Key、完整 ID
 */

import { ChatMessage, ChatMessageStatus, MessageSenderType, MessageVisibility } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ChatRequest } from '../../models/ChatRequest';
import { ChatResponse } from '../../models/ChatResponse';
import { ProviderConfig } from '../../models/ProviderConfig';
import {
  ModelServiceError,
  ModelServiceErrorType
} from '../../models/ModelServiceError';
import { ModelService } from '../ModelService';
import { GroupConversationMessageService } from './GroupConversationMessageService';
import { GroupConversationPersistenceService } from './GroupConversationPersistenceService';
import { GroupCharacterRelationshipMemoryService } from './GroupCharacterRelationshipMemoryService';
import {
  GroupCharacterRelationshipMemory,
  GroupRelationshipTargetType,
  isGroupRelationshipTargetType,
  isRelationshipImportance,
  RELATIONSHIP_USER_TARGET_ID,
  SOURCE_TYPE_RELATIONSHIP_SUMMARY_V1
} from '../../models/groupchat/GroupCharacterRelationshipMemory';
import { Character } from '../../models/Character';
import { ChatParticipant } from '../../models/ChatParticipant';
import { CharacterService } from '../CharacterService';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'GroupCharRelSummary';

/** 复用单聊 rolling 总结参数(参考 MemoryService.regenerateSummary) */
const SUMMARY_TEMPERATURE: number = 0.3;
const SUMMARY_TOP_P: number = 0.9;
const SUMMARY_MAX_TOKENS: number = 1536;
const SUMMARY_STREAM: boolean = false;

/** 关系总结错误类型 */
export enum RelationshipSummaryErrorKind {
  /** 没有有效消息可总结 */
  NoEffectiveMessages = 'no_effective_messages',
  /** 这些消息已总结过(sourceHash 重复) */
  AlreadySummarized = 'already_summarized',
  /** 没有可用模型配置 */
  NoModelConfig = 'no_model_config',
  /** 模型认证失败 */
  ModelAuthFailed = 'model_auth_failed',
  /** 网络失败 */
  NetworkFailed = 'network_failed',
  /** 模型返回空内容 */
  EmptyResponse = 'empty_response',
  /** JSON 解析失败或候选全部无效 */
  NoValidCandidates = 'no_valid_candidates',
  /** 内部错误 */
  Internal = 'internal'
}

/** 关系候选(待审核) */
export interface RelationshipCandidate {
  readonly targetType: GroupRelationshipTargetType;
  readonly targetId: string;
  readonly experienceSummary: string;
  readonly attitudeSummary: string;
  readonly relationshipSummary: string;
  readonly importance: number;
  readonly keywords: string[];
  readonly sourceMessageIds: string[];
}

/** 关系总结来源信息(不可变) */
export interface RelationshipSummarySource {
  /** 本批来源消息(按 sequenceNumber ASC 排序) */
  readonly messages: ChatMessage[];
  /** 稳定哈希 */
  readonly sourceHash: string;
  /** 当前 owner 角色 ID */
  readonly characterId: string;
  /** 当前群聊 ID */
  readonly groupConversationId: string;
  /** owner 角色名称(用于 Prompt) */
  readonly characterName: string;
  /** 群聊标题(用于 Prompt) */
  readonly groupTitle: string;
  /** 关系对象白名单(用户 + 其他角色) */
  readonly targetWhitelist: ReadonlyArray<RelationshipTargetWhitelistEntry>;
}

/** 关系对象白名单条目 */
export interface RelationshipTargetWhitelistEntry {
  readonly targetType: GroupRelationshipTargetType;
  readonly targetId: string;
  readonly targetName: string;
}

/** 总结 draft(待审核) */
export interface RelationshipSummaryDraft {
  readonly source: RelationshipSummarySource;
  /** 候选列表(已通过白名单与来源校验) */
  readonly candidates: RelationshipCandidate[];
}

/** prepare 返回结果 */
export interface RelationshipSummaryResult {
  readonly success: boolean;
  readonly draft?: RelationshipSummaryDraft;
  readonly errorKind?: RelationshipSummaryErrorKind;
  readonly errorMessage?: string;
}

/** 模型错误映射结果(内部使用) */
interface ModelErrorMapping {
  readonly kind: RelationshipSummaryErrorKind;
  readonly msg: string;
}

export class GroupCharacterRelationshipSummaryService {
  private readonly messageService: GroupConversationMessageService;
  private readonly groupPersistenceService: GroupConversationPersistenceService;
  private readonly characterService: CharacterService;
  private readonly relationshipMemoryService: GroupCharacterRelationshipMemoryService;
  private readonly modelService: ModelService;

  constructor(
    messageService: GroupConversationMessageService,
    groupPersistenceService: GroupConversationPersistenceService,
    characterService: CharacterService,
    relationshipMemoryService: GroupCharacterRelationshipMemoryService,
    modelService: ModelService
  ) {
    this.messageService = messageService;
    this.groupPersistenceService = groupPersistenceService;
    this.characterService = characterService;
    this.relationshipMemoryService = relationshipMemoryService;
    this.modelService = modelService;
  }

  /**
   * 准备关系总结 draft。
   *
   * 流程:
   * 1. 校验群聊存在
   * 2. 读取群聊全部消息(listMessages,已按 sequenceNumber ASC 排序)
   * 3. 过滤并收集 effectiveMessages(A 自身 + A 可见用户 + A 可见其他角色)
   * 4. 无有效消息 → NoEffectiveMessages
   * 5. 计算 sourceHash,检查重复 → AlreadySummarized
   * 6. 构建对象白名单(用户 + 群聊其他角色)
   * 7. 构建 Prompt,调用模型
   * 8. 严格 JSON 解析 + 候选校验
   * 9. 返回 draft
   *
   * 不写数据库。不修改任何现有数据。
   */
  async prepareRelationshipSummary(
    groupConversationId: string,
    characterId: string,
    characterName: string,
    groupTitle: string
  ): Promise<RelationshipSummaryResult> {
    if (groupConversationId.length === 0 || characterId.length === 0) {
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.Internal,
        errorMessage: '目标未加载'
      };
    }

    Logger.info(LOG_TAG, 'prepare: charShort=' + shortId(characterId)
      + ' groupShort=' + shortId(groupConversationId));

    // 1. 读取群聊全部消息(已按 sequenceNumber ASC 排序)
    let allMessages: ChatMessage[] = [];
    try {
      allMessages = await this.messageService.listMessages(groupConversationId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'prepare listMessages failed: ' + safeErrorCategory(e));
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.Internal,
        errorMessage: '读取群聊消息失败,请重试'
      };
    }

    // 2. 过滤并收集 effectiveMessages
    const effectiveMessages: ChatMessage[] = this.collectEffectiveMessages(allMessages, characterId);

    if (effectiveMessages.length === 0) {
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.NoEffectiveMessages,
        errorMessage: '没有可总结的有效消息'
      };
    }

    // 3. 计算 sourceHash(覆盖 ownerCharacterId + 所有有效消息)
    const sourceHash: string = computeRelationshipSourceHash(characterId, effectiveMessages);

    // 4. 检查 sourceHash 重复(防止重复创建)
    const existingMemories: GroupCharacterRelationshipMemory[] =
      await this.relationshipMemoryService.listByOwner(groupConversationId, characterId);
    if (this.hasExistingBySourceHash(existingMemories, sourceHash)) {
      Logger.info(LOG_TAG, 'prepare duplicate sourceHash=' + sourceHash.substring(0, 10)
        + ' charShort=' + shortId(characterId));
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.AlreadySummarized,
        errorMessage: '这些消息已经总结过了'
      };
    }

    // 5. 构建对象白名单(用户 + 群聊其他角色)
    let participants: ChatParticipant[] = [];
    try {
      participants = await this.groupPersistenceService.getParticipants(groupConversationId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'prepare getParticipants failed: ' + safeErrorCategory(e));
      participants = [];
    }

    const targetWhitelist: RelationshipTargetWhitelistEntry[] =
      await this.buildTargetWhitelist(characterId, participants, effectiveMessages);

    if (targetWhitelist.length === 0) {
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.NoEffectiveMessages,
        errorMessage: '没有可总结的关系对象'
      };
    }

    // 6. 构建来源信息
    const source: RelationshipSummarySource = {
      messages: effectiveMessages,
      sourceHash: sourceHash,
      characterId: characterId,
      groupConversationId: groupConversationId,
      characterName: characterName,
      groupTitle: groupTitle,
      targetWhitelist: targetWhitelist
    };

    Logger.info(LOG_TAG, 'prepare calling model: msgCount=' + effectiveMessages.length
      + ' targetCount=' + targetWhitelist.length
      + ' sourceHash=' + sourceHash.substring(0, 10)
      + ' charShort=' + shortId(characterId));

    // 7. 调用模型生成候选
    const generationResult: RelationshipSummaryResult = await this.callModelForSummary(source);
    if (!generationResult.success) {
      return generationResult;
    }

    const draft: RelationshipSummaryDraft = {
      source: source,
      candidates: generationResult.draft!.candidates
    };
    return { success: true, draft: draft };
  }

  // ===== 内部方法 =====

  /**
   * 调用模型生成关系候选。
   */
  private async callModelForSummary(
    source: RelationshipSummarySource
  ): Promise<RelationshipSummaryResult> {
    // 解析当前 Provider 配置
    let config: ProviderConfig | null;
    try {
      config = await this.modelService.getCurrentConfig();
    } catch (e) {
      Logger.warn(LOG_TAG, 'getCurrentConfig failed: ' + safeErrorCategory(e));
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.NoModelConfig,
        errorMessage: '没有可用的模型配置'
      };
    }
    if (config === null) {
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.NoModelConfig,
        errorMessage: '没有可用的模型配置'
      };
    }
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.NoModelConfig,
        errorMessage: '当前模型名称为空,请先配置模型'
      };
    }

    // 构建 Prompt
    const promptMessages: ChatMessage[] = buildRelationshipSummaryPrompt(source);

    const request: ChatRequest = {
      model: modelName,
      messages: promptMessages,
      temperature: SUMMARY_TEMPERATURE,
      topP: SUMMARY_TOP_P,
      maxTokens: SUMMARY_MAX_TOKENS,
      stream: SUMMARY_STREAM
    };

    let response: ChatResponse;
    try {
      response = await this.modelService.sendChat(request);
    } catch (e) {
      const mapped: ModelErrorMapping = mapModelError(e);
      Logger.warn(LOG_TAG, 'sendChat failed: kind=' + mapped.kind
        + ' charShort=' + shortId(source.characterId));
      return {
        success: false,
        errorKind: mapped.kind,
        errorMessage: mapped.msg
      } as RelationshipSummaryResult;
    }

    const content: string = response.content.trim();
    if (content.length === 0) {
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.EmptyResponse,
        errorMessage: '模型返回空内容,请重试'
      };
    }

    // 严格 JSON 解析 + 候选校验
    const candidates: RelationshipCandidate[] = parseAndValidateCandidates(
      content,
      source.targetWhitelist,
      source.messages
    );

    if (candidates.length === 0) {
      Logger.info(LOG_TAG, 'no valid candidates: charShort=' + shortId(source.characterId));
      return {
        success: false,
        errorKind: RelationshipSummaryErrorKind.NoValidCandidates,
        errorMessage: '没有形成明确的关系记忆'
      };
    }

    Logger.info(LOG_TAG, 'parse ok: candidateCount=' + candidates.length
      + ' charShort=' + shortId(source.characterId));
    const tempDraft: RelationshipSummaryDraft = {
      source: source,
      candidates: candidates
    };
    return { success: true, draft: tempDraft };
  }

  /**
   * 过滤并收集 effectiveMessages(owner 自身 + owner 可见用户 + owner 可见其他角色)。
   *
   * 排序:listMessages 已按 sequenceNumber ASC 返回,数组顺序即 sequenceNumber 顺序
   */
  private collectEffectiveMessages(
    allMessages: ChatMessage[],
    ownerCharacterId: string
  ): ChatMessage[] {
    const result: ChatMessage[] = [];
    for (let i = 0; i < allMessages.length; i++) {
      const msg: ChatMessage = allMessages[i];
      // 状态过滤:只接受 Completed
      if (msg.status !== ChatMessageStatus.Completed) {
        continue;
      }
      // 内容过滤:非空
      if (msg.content.trim().length === 0) {
        continue;
      }
      // 可见性过滤(关系总结专用)
      if (!isMessageVisibleForRelationship(msg, ownerCharacterId)) {
        continue;
      }
      result.push(msg);
    }
    return result;
  }

  /**
   * 检查 sourceHash 是否已存在(防止重复创建)。
   */
  private hasExistingBySourceHash(
    memories: GroupCharacterRelationshipMemory[],
    sourceHash: string
  ): boolean {
    for (let i = 0; i < memories.length; i++) {
      if (memories[i].sourceHash === sourceHash) {
        return true;
      }
    }
    return false;
  }

  /**
   * 构建关系对象白名单。
   * - 用户固定 'user'
   * - 群聊其他角色(participants 中除 owner 外的 Character.id)
   *
   * 若角色卡已删除,从 effectiveMessages 中仍可见的角色 ID 也加入白名单
   * (用 ID 作为名称,UI 安全降级显示)
   */
  private async buildTargetWhitelist(
    ownerCharacterId: string,
    participants: ChatParticipant[],
    effectiveMessages: ChatMessage[]
  ): Promise<RelationshipTargetWhitelistEntry[]> {
    const result: RelationshipTargetWhitelistEntry[] = [];
    const seenIds: Set<string> = new Set<string>();

    // 1. 用户(固定)
    result.push({
      targetType: GroupRelationshipTargetType.User,
      targetId: RELATIONSHIP_USER_TARGET_ID,
      targetName: '用户'
    });

    // 2. 群聊其他角色(从 participants 读取)
    for (let i = 0; i < participants.length; i++) {
      const p: ChatParticipant = participants[i];
      if (p.characterId === ownerCharacterId) {
        continue;
      }
      if (seenIds.has(p.characterId)) {
        continue;
      }
      seenIds.add(p.characterId);
      let name: string = '';
      try {
        const c: Character | null = await this.characterService.getById(p.characterId);
        name = c !== null ? c.name : '';
      } catch (e) {
        name = '';
      }
      result.push({
        targetType: GroupRelationshipTargetType.Character,
        targetId: p.characterId,
        targetName: name.length > 0 ? name : '角色已删除'
      });
    }

    // 3. 从 effectiveMessages 中补充其他角色(可能已移除但仍出现在历史消息中)
    for (let i = 0; i < effectiveMessages.length; i++) {
      const msg: ChatMessage = effectiveMessages[i];
      const senderType: MessageSenderType =
        msg.senderType !== undefined ? msg.senderType! : 'user';
      if (senderType !== 'character') {
        continue;
      }
      const senderId: string =
        msg.senderCharacterId !== undefined ? msg.senderCharacterId! : '';
      if (senderId === '' || senderId === ownerCharacterId) {
        continue;
      }
      if (seenIds.has(senderId)) {
        continue;
      }
      seenIds.add(senderId);
      let name: string = '';
      try {
        const c: Character | null = await this.characterService.getById(senderId);
        name = c !== null ? c.name : '';
      } catch (e) {
        name = '';
      }
      result.push({
        targetType: GroupRelationshipTargetType.Character,
        targetId: senderId,
        targetName: name.length > 0 ? name : '角色已删除'
      });
    }

    return result;
  }
}

// ===== 私有辅助函数 =====

/**
 * 判断消息对指定 owner 角色是否可见(用于关系总结输入过滤)。
 *
 * 与 SelfSummaryService.isMessageVisibleToCharacter 不同,本函数允许其他角色的
 * 公开消息进入总结输入(因为关系总结需要 A 与 B 的互动)。
 *
 * A 自己的消息(senderType='character' && senderCharacterId===A):可见
 * 用户公开消息(visibility='public'):可见(按公开消息兼容规则)
 * 用户私聊 A(visibility='private' && recipientCharacterIds 包含 A):可见
 * 角色 B 公开消息(visibility='public'):可见
 * 角色 B 私聊 A(visibility='private' && recipientCharacterIds 包含 A):可见
 * 旁白消息:不可见
 * 当前角色不可见的私聊:不可见
 */
function isMessageVisibleForRelationship(msg: ChatMessage, ownerCharacterId: string): boolean {
  const senderType: MessageSenderType =
    msg.senderType !== undefined ? msg.senderType! : 'user';

  // 角色消息
  if (senderType === 'character') {
    // A 自己的消息:可见
    // 角色 B 的公开消息:可见
    // 角色 B 私聊 A:可见(recipientCharacterIds 包含 A)
    const visibility: MessageVisibility =
      msg.visibility !== undefined ? msg.visibility! : 'public';
    if (visibility === 'private') {
      const recipients: string[] =
        msg.recipientCharacterIds !== undefined ? msg.recipientCharacterIds : [];
      return recipients.indexOf(ownerCharacterId) >= 0;
    }
    if (visibility === 'public') {
      return true;
    }
    // visibility='narrator' 的角色消息:不可见
    return false;
  }

  // 用户消息
  if (senderType === 'user') {
    const visibility: MessageVisibility =
      msg.visibility !== undefined ? msg.visibility! : 'public';
    if (visibility === 'private') {
      const recipients: string[] =
        msg.recipientCharacterIds !== undefined ? msg.recipientCharacterIds : [];
      return recipients.indexOf(ownerCharacterId) >= 0;
    }
    if (visibility === 'public') {
      // 公开消息可见性判断(G-MEMORY-AUTO-1A-FIX-2 修复)
      // - participantIds 非空:检查是否包含 owner
      // - participantIds 缺失/为空:默认可见(公开消息对所有群聊成员可见)
      const participants: string[] =
        msg.participantIds !== undefined ? msg.participantIds : [];
      if (participants.length === 0) {
        return true;
      }
      return participants.indexOf(ownerCharacterId) >= 0;
    }
    // visibility='narrator' 的用户消息:不可见
    return false;
  }

  // narrator 或其他类型:不可见
  return false;
}

/**
 * 计算 sourceHash(稳定摘要)。
 *
 * 输入:ownerCharacterId + 按 sequenceNumber ASC 拼接的:
 * - message.id
 * - message.senderType
 * - message.senderCharacterId
 * - message.visibility
 * - message.content
 *
 * 算法:djb2 变体(确定性、非加密,无第三方依赖)。
 */
function computeRelationshipSourceHash(
  ownerCharacterId: string,
  messages: ChatMessage[]
): string {
  const parts: string[] = [];
  parts.push('owner:' + ownerCharacterId);
  for (let i = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i];
    parts.push(msg.id);
    parts.push(msg.senderType !== undefined ? msg.senderType : 'user');
    parts.push(msg.senderCharacterId !== undefined ? msg.senderCharacterId : '');
    parts.push(msg.visibility !== undefined ? msg.visibility : 'public');
    parts.push(msg.content);
  }
  const input: string = parts.join('\u0001');
  // djb2 变体
  let hash: number = 5381;
  for (let i = 0; i < input.length; i++) {
    hash = ((hash * 33) ^ input.charCodeAt(i)) >>> 0;
  }
  return 'rm-' + hash.toString(16).padStart(8, '0');
}

/**
 * 构建关系总结 Prompt(严格 JSON 输出)。
 */
function buildRelationshipSummaryPrompt(source: RelationshipSummarySource): ChatMessage[] {
  const systemPrompt: string =
    '你正在从角色 A 的视角总结 A 与其他对象的关系。\n\n' +
    '只能使用提供的消息。\n' +
    '不得补充未出现的事实。\n' +
    '不得推测对方未表达的想法。\n' +
    '不得把一方态度当作双方共同态度。\n' +
    '不得因为同处群聊就创建关系。\n' +
    '没有明确互动或态度时,不输出候选。\n\n' +
    '字段要求:\n' +
    '- experienceSummary:双方发生过什么,或 owner 明确知道对方经历过什么\n' +
    '- attitudeSummary:owner 对对方的态度,或 owner 知道对方明确表达过的态度\n' +
    '  需要区分 "A 认为..." 与 "B 曾明确表示..." \n' +
    '- relationshipSummary:当前关系的谨慎概括\n' +
    '  例如 "A 将 B 视为值得合作但仍需观察的同伴"\n' +
    '  不得输出 "永远的朋友"、"命中注定"、"绝对忠诚" 等夸张表达\n' +
    '  除非消息有明确证据\n\n' +
    '输出要求(严格 JSON,不要代码块,不要解释):\n' +
    '{\n' +
    '  "relationships": [\n' +
    '    {\n' +
    '      "targetType": "user" 或 "character",\n' +
    '      "targetId": "对象 ID(必须来自白名单)",\n' +
    '      "experienceSummary": "...",\n' +
    '      "attitudeSummary": "...",\n' +
    '      "relationshipSummary": "...",\n' +
    '      "importance": 1 到 5 的整数,\n' +
    '      "keywords": ["关键词1", "关键词2"],\n' +
    '      "sourceMessageIds": ["消息 ID(必须来自输入)"]\n' +
    '    }\n' +
    '  ]\n' +
    '}\n\n' +
    '若没有形成明确的关系记忆,输出 {"relationships": []}';

  const whitelistText: string = formatWhitelist(source.targetWhitelist);
  const userContent: string =
    '角色 A:' + source.characterName + '(ID: ' + source.characterId + ')\n' +
    '群聊:' + source.groupTitle + '\n\n' +
    '可识别的对象白名单:\n' + whitelistText + '\n\n' +
    '以下是 ' + source.characterName + ' 可见的消息:\n\n' +
    formatMessagesForPrompt(source.messages, source.characterName) + '\n\n' +
    '请从 ' + source.characterName + ' 的视角输出关系候选 JSON:';

  const systemMessage: ChatMessage = {
    id: 'group-relationship-summary-system',
    role: ChatRole.System,
    content: systemPrompt,
    createdAt: 0
  };
  const userMessage: ChatMessage = {
    id: 'group-relationship-summary-user',
    role: ChatRole.User,
    content: userContent,
    createdAt: 0
  };
  return [systemMessage, userMessage];
}

function formatWhitelist(whitelist: ReadonlyArray<RelationshipTargetWhitelistEntry>): string {
  const parts: string[] = [];
  for (let i = 0; i < whitelist.length; i++) {
    const entry: RelationshipTargetWhitelistEntry = whitelist[i];
    parts.push('- targetType=' + entry.targetType
      + ', targetId=' + entry.targetId
      + ', name=' + entry.targetName);
  }
  return parts.join('\n');
}

function formatMessagesForPrompt(messages: ChatMessage[], ownerName: string): string {
  const parts: string[] = [];
  for (let i = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i];
    const time: string = formatTimestamp(msg.createdAt);
    const senderType: MessageSenderType =
      msg.senderType !== undefined ? msg.senderType! : 'user';
    const senderId: string =
      msg.senderCharacterId !== undefined ? msg.senderCharacterId! : '';
    const visibility: MessageVisibility =
      msg.visibility !== undefined ? msg.visibility! : 'public';
    let speaker: string;
    if (senderType === 'character') {
      speaker = senderId === '' ? '未知角色' : '角色 ' + shortId(senderId);
    } else if (senderType === 'user') {
      speaker = '用户';
    } else {
      speaker = '旁白';
    }
    parts.push('[消息 ' + (i + 1).toString() + ']');
    parts.push('消息ID:' + msg.id);
    parts.push('说话者:' + speaker);
    parts.push('可见范围:' + visibility);
    parts.push('时间:' + time);
    parts.push('内容:' + msg.content);
    parts.push('');
  }
  return parts.join('\n');
}

function formatTimestamp(ts: number): string {
  if (!Number.isFinite(ts) || ts <= 0) {
    return '未知';
  }
  const d: Date = new Date(ts);
  const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
  const day: string = d.getDate().toString().padStart(2, '0');
  const hour: string = d.getHours().toString().padStart(2, '0');
  const minute: string = d.getMinutes().toString().padStart(2, '0');
  return month + '-' + day + ' ' + hour + ':' + minute;
}

/**
 * 严格 JSON 解析 + 候选校验。
 *
 * 校验规则:
 * - targetType 合法
 * - targetId 在白名单
 * - targetId 不是 owner(此规则在白名单构建时已保证)
 * - sourceMessageIds 非空
 * - sourceMessageIds 都属于 effectiveMessages
 * - 至少存在 experience/attitude/relationship 之一
 * - importance 1～5
 * - keywords 合法
 * - 所有字符串 trim
 *
 * 非法候选:单独丢弃
 */
function parseAndValidateCandidates(
  content: string,
  whitelist: ReadonlyArray<RelationshipTargetWhitelistEntry>,
  effectiveMessages: ChatMessage[]
): RelationshipCandidate[] {
  // 提取 JSON(可能包含 ```json 代码块或纯 JSON)
  const jsonStr: string = extractJson(content);
  if (jsonStr.length === 0) {
    Logger.warn(LOG_TAG, 'parse: no JSON found in content');
    return [];
  }

  let parsed: Object;
  try {
    parsed = JSON.parse(jsonStr);
  } catch (e) {
    Logger.warn(LOG_TAG, 'parse: JSON.parse failed');
    return [];
  }

  const relationshipsObj: Object | undefined =
    (parsed as Record<string, Object>)['relationships'];
  if (relationshipsObj === undefined || !Array.isArray(relationshipsObj)) {
    Logger.warn(LOG_TAG, 'parse: relationships not array');
    return [];
  }

  const effectiveMessageIds: Set<string> = new Set<string>();
  for (let i = 0; i < effectiveMessages.length; i++) {
    effectiveMessageIds.add(effectiveMessages[i].id);
  }

  const whitelistIds: Set<string> = new Set<string>();
  for (let i = 0; i < whitelist.length; i++) {
    whitelistIds.add(whitelist[i].targetId);
  }

  const candidates: RelationshipCandidate[] = [];
  const rawArray: Object[] = relationshipsObj as Object[];
  for (let i = 0; i < rawArray.length; i++) {
    const item: Object | undefined = rawArray[i];
    if (item === null || item === undefined) {
      continue;
    }
    const candidate: RelationshipCandidate | null = validateCandidate(
      item as Record<string, Object>,
      whitelist,
      whitelistIds,
      effectiveMessageIds
    );
    if (candidate !== null) {
      candidates.push(candidate);
    }
  }
  return candidates;
}

function extractJson(content: string): string {
  const trimmed: string = content.trim();
  // 去除可能的 ```json ... ``` 包裹
  if (trimmed.startsWith('```')) {
    const firstNewline: number = trimmed.indexOf('\n');
    if (firstNewline > 0) {
      const endMarker: number = trimmed.lastIndexOf('```');
      if (endMarker > firstNewline) {
        return trimmed.substring(firstNewline + 1, endMarker).trim();
      }
    }
  }
  // 直接 JSON
  const firstBrace: number = trimmed.indexOf('{');
  const lastBrace: number = trimmed.lastIndexOf('}');
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    return trimmed.substring(firstBrace, lastBrace + 1);
  }
  return '';
}

function validateCandidate(
  item: Record<string, Object>,
  whitelist: ReadonlyArray<RelationshipTargetWhitelistEntry>,
  whitelistIds: Set<string>,
  effectiveMessageIds: Set<string>
): RelationshipCandidate | null {
  const targetTypeRaw: string = readStringField(item, 'targetType');
  if (!isGroupRelationshipTargetType(targetTypeRaw)) {
    return null;
  }
  const targetId: string = readStringField(item, 'targetId');
  if (targetId === '') {
    return null;
  }
  // targetId 必须在白名单
  if (!whitelistIds.has(targetId)) {
    return null;
  }
  // targetType 必须与白名单中的对应 targetId 一致
  let whitelistEntry: RelationshipTargetWhitelistEntry | null = null;
  for (let i = 0; i < whitelist.length; i++) {
    if (whitelist[i].targetId === targetId) {
      whitelistEntry = whitelist[i];
      break;
    }
  }
  if (whitelistEntry === null || whitelistEntry.targetType !== targetTypeRaw) {
    return null;
  }

  const experienceSummary: string = readStringField(item, 'experienceSummary').trim();
  const attitudeSummary: string = readStringField(item, 'attitudeSummary').trim();
  const relationshipSummary: string = readStringField(item, 'relationshipSummary').trim();
  if (experienceSummary === '' && attitudeSummary === '' && relationshipSummary === '') {
    return null;
  }

  // importance:默认 3,范围 1-5
  let importance: number = 3;
  const importanceObj: Object | undefined = item['importance'];
  if (importanceObj !== undefined) {
    const importanceNum: number = Number(importanceObj);
    if (!Number.isFinite(importanceNum)) {
      return null;
    }
    importance = Math.floor(importanceNum);
    if (!isRelationshipImportance(importance)) {
      return null;
    }
  }

  // keywords:必须为数组,所有元素为字符串
  const keywords: string[] = readStringArrayField(item, 'keywords');

  // sourceMessageIds:必须为非空数组,所有 ID 必须属于 effectiveMessages
  const sourceMessageIdsRaw: string[] = readStringArrayField(item, 'sourceMessageIds');
  if (sourceMessageIdsRaw.length === 0) {
    return null;
  }
  const validatedSourceIds: string[] = [];
  const seenIds: Set<string> = new Set<string>();
  for (let i = 0; i < sourceMessageIdsRaw.length; i++) {
    const id: string = sourceMessageIdsRaw[i].trim();
    if (id === '' || seenIds.has(id)) {
      continue;
    }
    if (!effectiveMessageIds.has(id)) {
      // 来源 ID 不属于输入集合,丢弃整个候选
      return null;
    }
    seenIds.add(id);
    validatedSourceIds.push(id);
  }
  if (validatedSourceIds.length === 0) {
    return null;
  }

  return {
    targetType: targetTypeRaw as GroupRelationshipTargetType,
    targetId: targetId,
    experienceSummary: experienceSummary,
    attitudeSummary: attitudeSummary,
    relationshipSummary: relationshipSummary,
    importance: importance,
    keywords: keywords,
    sourceMessageIds: validatedSourceIds
  };
}

function readStringField(item: Record<string, Object>, key: string): string {
  const v: Object | undefined = item[key];
  if (v === undefined || v === null) {
    return '';
  }
  return String(v);
}

function readStringArrayField(item: Record<string, Object>, key: string): string[] {
  const v: Object | undefined = item[key];
  if (v === undefined || v === null || !Array.isArray(v)) {
    return [];
  }
  const arr: Object[] = v as Object[];
  const result: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const elem: Object | undefined = arr[i];
    if (elem === null || elem === undefined) {
      continue;
    }
    result.push(String(elem));
  }
  return result;
}

/**
 * 将 ModelServiceError 映射为 RelationshipSummaryErrorKind。
 */
function mapModelError(e: Object): ModelErrorMapping {
  if (e instanceof ModelServiceError) {
    const err: ModelServiceError = e as ModelServiceError;
    if (err.type === ModelServiceErrorType.NoCurrentConfig
      || err.type === ModelServiceErrorType.ConfigDisabled
      || err.type === ModelServiceErrorType.ConfigNotFound
      || err.type === ModelServiceErrorType.NotInitialized
      || err.type === ModelServiceErrorType.UnsupportedProvider
      || err.type === ModelServiceErrorType.InvalidConfig) {
      return {
        kind: RelationshipSummaryErrorKind.NoModelConfig,
        msg: '没有可用的模型配置'
      } as ModelErrorMapping;
    }
    if (err.type === ModelServiceErrorType.ApiKeyMissing) {
      return {
        kind: RelationshipSummaryErrorKind.ModelAuthFailed,
        msg: '模型认证失败,请检查 API Key'
      } as ModelErrorMapping;
    }
    if (err.type === ModelServiceErrorType.NetworkFailure) {
      return {
        kind: RelationshipSummaryErrorKind.NetworkFailed,
        msg: '网络连接失败,请稍后重试'
      } as ModelErrorMapping;
    }
  }
  return {
    kind: RelationshipSummaryErrorKind.Internal,
    msg: '总结失败,请稍后重试'
  } as ModelErrorMapping;
}

function safeErrorCategory(e: Object): string {
  if (e instanceof ModelServiceError) {
    return 'ModelServiceError:' + (e as ModelServiceError).type;
  }
  const msg: string = (e as Error).message ?? 'unknown';
  if (msg.length > 60) {
    return 'Error:' + msg.substring(0, 60);
  }
  return 'Error:' + msg;
}

function shortId(id: string): string {
  if (id.length <= 8) {
    return id;
  }
  return id.substring(id.length - 8);
}
