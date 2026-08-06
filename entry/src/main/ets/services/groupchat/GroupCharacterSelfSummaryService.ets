/**
 * GroupCharacterSelfSummaryService 多人角色自身发言手动总结服务
 *
 * G-MEMORY-AUTO-1A 引入,G-MEMORY-AUTO-1A-FIX 扩展消息过滤范围。职责仅限于:
 * - 读取并过滤当前角色自己发送的已完成消息 + 当前角色可见的用户发言
 * - 确定增量范围(上次已批准自动总结之后的新有效消息)
 * - 计算 sourceHash(稳定摘要,防止重复创建)
 * - 判断是否重复
 * - 构建总结 Prompt(角色自身发言 + 可见用户发言)
 * - 调用 ModelService(复用单聊 rolling 总结的调用参数)
 * - 返回待审核结果(draft)
 * - 批准后调用 GroupCharacterMemoryService.createInteractionMemory
 *
 * 不负责(本阶段禁止):
 * - 自动调度 / 轮次监听 / 后台队列
 * - Prompt 注入 / 关系总结 / 经历总结
 * - 数据库迁移 / 候选批次表
 *
 * 复用单聊方式(参考 MemoryService.regenerateSummary):
 * - ModelService.getCurrentConfig() 获取当前 ProviderConfig
 * - ModelService.sendChat() 非流式调用
 * - temperature = 0.3 / topP = 0.9 / maxTokens = 1024 / stream = false
 * - 输出纯文本摘要(不超过 500 字)
 * 不直接调用 MemoryService / MemoryPersistenceService,不写单聊表。
 *
 * 消息过滤规则(G-MEMORY-AUTO-1A-FIX 扩展):
 * 有效输入 = 当前角色自身消息 + 当前角色可见的用户消息
 *
 * 角色自身消息:
 * - senderType === 'character'
 * - senderCharacterId === 当前 characterId
 * - status === ChatMessageStatus.Completed
 * - content.trim().length > 0
 *
 * 用户公开消息(visibility='public'):
 * - senderType === 'user'
 * - visibility === 'public'
 * - status === Completed
 * - content.trim() 非空
 * - participantIds 非空 → 检查是否包含当前 characterId
 * - participantIds 缺失/为空 → 默认可见(公开消息对所有群聊成员可见,
 *   GroupConversationMessageService.appendUserMessage 从未填入 participantIds)
 *
 * 用户私聊消息(visibility='private'):
 * - senderType === 'user'
 * - visibility === 'private'
 * - recipientCharacterIds 包含当前 characterId
 * - status === Completed
 * - content.trim() 非空
 *
 * 排除:
 * - 其他 AI 角色消息(senderType='character' && senderCharacterId !== 当前 characterId)
 * - 旁白消息(senderType='narrator' 或 visibility='narrator')
 * - 当前角色不可见的私聊
 * - Streaming / Failed / Cancelled / 空内容
 *
 * replyTargetCharacterIds 不影响可见性(任务第八节):
 * - 公开消息按 visibility='public' + participantIds 判断
 * - 私聊消息只按 recipientCharacterIds 判断
 *
 * 排序:listMessages 已按 sequenceNumber ASC 返回,数组顺序即 sequenceNumber 顺序
 *
 * sourceType 仍为 'self_summary_v1'(保持兼容,不迁移)
 * 其语义已扩展为"角色自身及其可见用户互动总结"
 *
 * sourceHash(G-MEMORY-AUTO-1A-FIX 扩展):
 * - 输入:按 sequenceNumber ASC 拼接的 message.id + senderType + senderCharacterId
 *   + visibility + content
 * - 算法:djb2 变体(确定性、非加密,无第三方依赖)
 * - 同一 groupConversationId + characterId + sourceHash + sourceType='self_summary_v1'
 *   已存在时,不得再次调用模型
 *
 * 日志安全(任务第二十三节):
 * - 允许:目标角色短 ID、来源消息数量、sourceHash 前 8 位、总结开始/完成/失败
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
import {
  GroupCharacterMemoryService,
  GroupCharacterMemoryFilter,
  CreateInteractionMemoryInput
} from './GroupCharacterMemoryService';
import { UpsertRollingSummaryPayload } from '../../repositories/groupchat/GroupCharacterMemoryRepository';
import {
  GroupCharacterMemory,
  GroupCharacterMemoryOrigin,
  GroupCharacterMemoryStatus,
  createGroupCharacterMemoryRecord
} from '../../models/groupchat/GroupCharacterMemory';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'GroupCharSelfSummary';

/** 自动总结来源类型标识(写入 source_type 字段) */
export const SOURCE_TYPE_SELF_SUMMARY_V1: string = 'self_summary_v1';

/** 复用单聊 rolling 总结参数(参考 MemoryService.regenerateSummary) */
const SUMMARY_TEMPERATURE: number = 0.3;
const SUMMARY_TOP_P: number = 0.9;
const SUMMARY_MAX_TOKENS: number = 1024;
const SUMMARY_STREAM: boolean = false;

/** 总结 draft 默认值 */
const DEFAULT_DRAFT_TITLE: string = '自动总结';
const DEFAULT_DRAFT_IMPORTANCE: number = 3;

/** 总结错误类型(任务第二十二节) */
export enum SelfSummaryErrorKind {
  /** 没有新的角色发言 */
  NoNewMessages = 'no_new_messages',
  /** 这些发言已总结过(sourceHash 重复) */
  AlreadySummarized = 'already_summarized',
  /** 没有可用模型配置 */
  NoModelConfig = 'no_model_config',
  /** 模型认证失败(API Key 缺失或无效) */
  ModelAuthFailed = 'model_auth_failed',
  /** 网络失败 */
  NetworkFailed = 'network_failed',
  /** 模型返回空内容 */
  EmptyResponse = 'empty_response',
  /** 保存失败 */
  SaveFailed = 'save_failed',
  /** 内部错误 */
  Internal = 'internal'
}

/** 总结来源信息(不可变) */
export interface SelfSummarySource {
  /** 本批来源消息(按 sequenceNumber ASC 排序,包含角色自身消息 + 可见用户消息) */
  readonly messages: ChatMessage[];
  /** 本批最后一条有效消息 ID(可能是用户消息或角色消息) */
  readonly sourceMessageId: string;
  /** 本批最后一条消息 generationBatchId(可能为空,用户消息无此字段) */
  readonly sourceRoundId: string;
  /** 稳定哈希 */
  readonly sourceHash: string;
  /** 当前角色 ID */
  readonly characterId: string;
  /** 当前群聊 ID */
  readonly groupConversationId: string;
  /** 角色名称(用于 Prompt) */
  readonly characterName: string;
  /** 群聊标题(用于 Prompt) */
  readonly groupTitle: string;
  /** 来源消息起始 sequenceNumber(数组索引 + 1,用于 UI 显示) */
  readonly startSequence: number;
  /** 来源消息结束 sequenceNumber(数组索引 + 1,用于 UI 显示) */
  readonly endSequence: number;
  /** 本批用户消息数量(G-MEMORY-AUTO-1A-FIX) */
  readonly userMessageCount: number;
  /** 本批角色自身消息数量(G-MEMORY-AUTO-1A-FIX) */
  readonly characterMessageCount: number;
}

/** 总结 draft(待审核) */
export interface SelfSummaryDraft {
  /** 来源信息(不可变,重新生成时保持不变) */
  readonly source: SelfSummarySource;
  /** 摘要标题(默认 '自动总结',用户可编辑) */
  readonly title: string;
  /** 模型生成的摘要正文(用户可编辑) */
  readonly content: string;
  /** 重要度(默认 3,用户可调整) */
  readonly importance: number;
  /** 关键词(默认空,用户可填写) */
  readonly keywords: string[];
}

/** prepare/regenerate 返回结果 */
export interface SelfSummaryResult {
  readonly success: boolean;
  readonly draft?: SelfSummaryDraft;
  readonly errorKind?: SelfSummaryErrorKind;
  readonly errorMessage?: string;
}

/** approve 返回结果 */
export interface SelfSummaryApproveResult {
  readonly success: boolean;
  readonly errorMessage: string;
}

/** 模型错误映射结果(内部使用) */
interface ModelErrorMapping {
  readonly kind: SelfSummaryErrorKind;
  readonly msg: string;
}

export class GroupCharacterSelfSummaryService {
  private readonly messageService: GroupConversationMessageService;
  private readonly memoryService: GroupCharacterMemoryService;
  private readonly modelService: ModelService;

  constructor(
    messageService: GroupConversationMessageService,
    memoryService: GroupCharacterMemoryService,
    modelService: ModelService
  ) {
    this.messageService = messageService;
    this.memoryService = memoryService;
    this.modelService = modelService;
  }

  /**
   * 准备自动总结 draft。
   *
   * 流程:
   * 1. 读取群聊全部消息(listMessages,已按 sequenceNumber ASC 排序)
   * 2. 查找上次已批准自动总结进度
   * 3. 过滤并收集增量有效消息(角色自身消息 + 可见用户消息)
   * 4. 无新消息 → NoNewMessages / AlreadySummarized
   * 5. 计算 sourceHash,检查重复 → AlreadySummarized
   * 6. 构建 Prompt,调用模型
   * 7. 返回 draft
   *
   * 不写数据库。不修改任何现有数据。
   */
  async prepareSelfSummary(
    groupConversationId: string,
    characterId: string,
    characterName: string,
    groupTitle: string
  ): Promise<SelfSummaryResult> {
    if (groupConversationId.length === 0 || characterId.length === 0) {
      return {
        success: false,
        errorKind: SelfSummaryErrorKind.Internal,
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
        errorKind: SelfSummaryErrorKind.Internal,
        errorMessage: '读取群聊消息失败,请重试'
      };
    }

    // 2. 查找上次已批准自动总结进度 + 检查 sourceHash 重复
    let existingMemories: GroupCharacterMemory[] = [];
    try {
      existingMemories = await this.memoryService.listByCharacter(
        groupConversationId, characterId, GroupCharacterMemoryFilter.All
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'prepare listByCharacter failed: ' + safeErrorCategory(e));
      // 不阻塞:继续按"无上次进度"处理
      existingMemories = [];
    }

    const lastProgress: GroupCharacterMemory | null =
      this.findLastSelfSummaryProgress(existingMemories);

    // 3. 过滤并收集增量有效消息(角色自身 + 可见用户)
    const incrementalMessages: ChatMessage[] = this.collectIncrementalMessages(
      allMessages, characterId, lastProgress
    );

    if (incrementalMessages.length === 0) {
      // 区分:无任何有效发言 vs 已全部总结
      if (lastProgress !== null) {
        return {
          success: false,
          errorKind: SelfSummaryErrorKind.AlreadySummarized,
          errorMessage: '这些发言已经总结过了'
        };
      }
      return {
        success: false,
        errorKind: SelfSummaryErrorKind.NoNewMessages,
        errorMessage: '没有新的可总结内容'
      };
    }

    // 4. 计算 sourceHash(覆盖所有有效消息)
    const sourceHash: string = computeSourceHash(incrementalMessages);

    // 5. 检查 sourceHash 重复(防止重复创建)
    const existing: GroupCharacterMemory | null =
      this.findExistingBySourceHash(existingMemories, sourceHash);
    if (existing !== null) {
      Logger.info(LOG_TAG, 'prepare duplicate sourceHash=' + sourceHash.substring(0, 10)
        + ' charShort=' + shortId(characterId));
      return {
        success: false,
        errorKind: SelfSummaryErrorKind.AlreadySummarized,
        errorMessage: '这些发言已经总结过了'
      };
    }

    // 6. 构建来源信息
    // 统计用户消息 / 角色消息数量
    let userMessageCount: number = 0;
    let characterMessageCount: number = 0;
    for (let i = 0; i < incrementalMessages.length; i++) {
      const senderType: MessageSenderType =
        incrementalMessages[i].senderType !== undefined
          ? incrementalMessages[i].senderType! : 'user';
      if (senderType === 'character') {
        characterMessageCount++;
      } else if (senderType === 'user') {
        userMessageCount++;
      }
    }

    // 本批最后一条有效消息(可能是用户消息或角色消息)
    const lastMessage: ChatMessage = incrementalMessages[incrementalMessages.length - 1];
    const sourceRoundId: string = lastMessage.generationBatchId !== undefined
      ? lastMessage.generationBatchId : '';
    const startSequence: number = findMessageIndex(allMessages, incrementalMessages[0].id) + 1;
    const endSequence: number = findMessageIndex(allMessages, lastMessage.id) + 1;

    const source: SelfSummarySource = {
      messages: incrementalMessages,
      sourceMessageId: lastMessage.id,
      sourceRoundId: sourceRoundId,
      sourceHash: sourceHash,
      characterId: characterId,
      groupConversationId: groupConversationId,
      characterName: characterName,
      groupTitle: groupTitle,
      startSequence: startSequence,
      endSequence: endSequence,
      userMessageCount: userMessageCount,
      characterMessageCount: characterMessageCount
    };

    Logger.info(LOG_TAG, 'prepare calling model: msgCount=' + incrementalMessages.length
      + ' userMsg=' + userMessageCount + ' charMsg=' + characterMessageCount
      + ' sourceHash=' + sourceHash.substring(0, 10)
      + ' charShort=' + shortId(characterId));

    // 7. 调用模型生成摘要
    const generationResult: SelfSummaryResult = await this.callModelForSummary(source);
    if (!generationResult.success) {
      return generationResult;
    }

    const draft: SelfSummaryDraft = {
      source: source,
      title: DEFAULT_DRAFT_TITLE,
      content: generationResult.draft!.content,
      importance: DEFAULT_DRAFT_IMPORTANCE,
      keywords: []
    };
    return { success: true, draft: draft };
  }

  /**
   * 重新生成摘要(使用同一批来源消息再次调用模型)。
   * 不改变来源范围。不写数据库。新结果覆盖当前 draft。
   */
  async regenerateSelfSummary(draft: SelfSummaryDraft): Promise<SelfSummaryResult> {
    Logger.info(LOG_TAG, 'regenerate: msgCount=' + draft.source.messages.length
      + ' sourceHash=' + draft.source.sourceHash.substring(0, 10));
    const result: SelfSummaryResult = await this.callModelForSummary(draft.source);
    if (!result.success) {
      return result;
    }
    const newDraft: SelfSummaryDraft = {
      source: draft.source,
      title: draft.title,
      content: result.draft!.content,
      importance: draft.importance,
      keywords: draft.keywords
    };
    return { success: true, draft: newDraft };
  }

  /**
   * 批准保存 draft(用户审核后)。
   * 1C:使用 upsertRollingSelfSummaryAtomically 保证原地更新不膨胀。
   */
  async approveSelfSummary(
    draft: SelfSummaryDraft,
    editedTitle: string,
    editedContent: string,
    editedImportance: number,
    editedKeywords: string[]
  ): Promise<SelfSummaryApproveResult> {
    const title: string = editedTitle.trim();
    const content: string = editedContent.trim();
    if (title.length === 0) {
      return { success: false, errorMessage: '记忆标题不能为空' };
    }
    if (content.length === 0) {
      return { success: false, errorMessage: '记忆内容不能为空' };
    }

    const payload: UpsertRollingSummaryPayload = {
      groupConversationId: draft.source.groupConversationId,
      characterId: draft.source.characterId,
      title: title,
      content: content,
      importance: editedImportance,
      keywords: editedKeywords,
      sourceMessageId: draft.source.sourceMessageId,
      sourceRoundId: draft.source.sourceRoundId.length > 0
        ? draft.source.sourceRoundId : undefined,
      sourceSenderCharacterId: draft.source.characterId,
      sourceHash: draft.source.sourceHash,
      updatedAt: nowMillis()
    };

    try {
      await this.memoryService.upsertRollingSelfSummaryAtomically(payload);
      Logger.info(LOG_TAG, 'approve ok: sourceHash=' + draft.source.sourceHash.substring(0, 10)
        + ' charShort=' + shortId(draft.source.characterId));
      return { success: true, errorMessage: '' };
    } catch (e) {
      Logger.warn(LOG_TAG, 'approve failed: ' + safeErrorCategory(e)
        + ' sourceHash=' + draft.source.sourceHash.substring(0, 10));
      return { success: false, errorMessage: '保存失败,请重试' };
    }
  }

  /**
   * 1C:原地更新滚动总结(供自动总结执行器调用)。
   */
  async replaceActiveSelfSummary(memory: GroupCharacterMemory): Promise<number> {
    const payload: UpsertRollingSummaryPayload = {
      groupConversationId: memory.groupConversationId,
      characterId: memory.characterId,
      title: memory.title,
      content: memory.content,
      importance: memory.importance,
      keywords: memory.keywords,
      sourceMessageId: memory.sourceMessageId !== undefined ? memory.sourceMessageId : '',
      sourceRoundId: memory.sourceRoundId,
      sourceSenderCharacterId: memory.sourceSenderCharacterId !== undefined
        ? memory.sourceSenderCharacterId : '',
      sourceHash: memory.sourceHash !== undefined ? memory.sourceHash : '',
      updatedAt: memory.updatedAt
    };
    return await this.memoryService.upsertRollingSelfSummaryAtomically(payload);
  }

  /**
   * 1C:使用 UpsertRollingSummaryPayload 原地更新(供 Executor 调用)。
   */
  async replaceActiveSelfSummaryFromPayload(payload: UpsertRollingSummaryPayload): Promise<number> {
    return await this.memoryService.upsertRollingSelfSummaryAtomically(payload);
  }

  // ===== 内部方法 =====

  /**
   * 调用模型生成摘要(复用单聊 rolling 参数)。
   */
  private async callModelForSummary(source: SelfSummarySource): Promise<SelfSummaryResult> {
    // 解析当前 Provider 配置
    let config: ProviderConfig | null;
    try {
      config = await this.modelService.getCurrentConfig();
    } catch (e) {
      Logger.warn(LOG_TAG, 'getCurrentConfig failed: ' + safeErrorCategory(e));
      return {
        success: false,
        errorKind: SelfSummaryErrorKind.NoModelConfig,
        errorMessage: '没有可用的模型配置'
      };
    }
    if (config === null) {
      return {
        success: false,
        errorKind: SelfSummaryErrorKind.NoModelConfig,
        errorMessage: '没有可用的模型配置'
      };
    }
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      return {
        success: false,
        errorKind: SelfSummaryErrorKind.NoModelConfig,
        errorMessage: '当前模型名称为空,请先配置模型'
      };
    }

    // 构建 Prompt
    const promptMessages: ChatMessage[] = buildSummaryPrompt(source);

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
      } as SelfSummaryResult;
    }

    const content: string = response.content.trim();
    if (content.length === 0) {
      return {
        success: false,
        errorKind: SelfSummaryErrorKind.EmptyResponse,
        errorMessage: '模型返回空内容,请重试'
      };
    }

    // 返回临时 draft(仅含 content,外层会补充 title/importance/keywords)
    const tempDraft: SelfSummaryDraft = {
      source: source,
      title: DEFAULT_DRAFT_TITLE,
      content: content,
      importance: DEFAULT_DRAFT_IMPORTANCE,
      keywords: []
    };
    return { success: true, draft: tempDraft };
  }

  /**
   * 查找上次已批准自动总结进度。
   * 筛选:origin=Interaction && sourceType='self_summary_v1' && status != Invalidated
   * 取 updatedAt 最新一条。
   */
  private findLastSelfSummaryProgress(
    memories: GroupCharacterMemory[]
  ): GroupCharacterMemory | null {
    let latest: GroupCharacterMemory | null = null;
    for (let i = 0; i < memories.length; i++) {
      const m: GroupCharacterMemory = memories[i];
      if (m.origin !== GroupCharacterMemoryOrigin.Interaction) {
        continue;
      }
      if (m.sourceType !== SOURCE_TYPE_SELF_SUMMARY_V1) {
        continue;
      }
      if (m.status === GroupCharacterMemoryStatus.Invalidated) {
        continue;
      }
      if (latest === null || m.updatedAt > latest.updatedAt) {
        latest = m;
      }
    }
    return latest;
  }

  /**
   * 检查 sourceHash 是否已存在(防止重复创建)。
   */
  private findExistingBySourceHash(
    memories: GroupCharacterMemory[],
    sourceHash: string
  ): GroupCharacterMemory | null {
    for (let i = 0; i < memories.length; i++) {
      const m: GroupCharacterMemory = memories[i];
      if (m.origin !== GroupCharacterMemoryOrigin.Interaction) {
        continue;
      }
      if (m.sourceType !== SOURCE_TYPE_SELF_SUMMARY_V1) {
        continue;
      }
      if (m.sourceHash === sourceHash) {
        return m;
      }
    }
    return null;
  }

  /**
   * 过滤并收集增量有效消息(角色自身消息 + 当前角色可见的用户消息)。
   *
   * G-MEMORY-AUTO-1A-FIX 扩展:不再只收集角色自身消息,而是收集:
   * - 角色自身消息(senderType='character' && senderCharacterId===characterId)
   * - 可见用户消息(senderType='user' && 对当前角色可见)
   *
   * 增量规则(任务第十二节):
   * - 上次进度 sourceMessageId 可以是用户消息或角色消息
   * - 在 allMessages 中定位 lastProgress.sourceMessageId,取其之后的所有消息
   * - 从该起点开始过滤有效消息
   * - 找不到 lastId(可能消息被删除):从当前可读取历史重新计算
   *
   * 排序:listMessages 已按 sequenceNumber ASC 返回,数组顺序即 sequenceNumber 顺序
   *
   * 仍排除:
   * - 其他 AI 角色消息(senderType='character' && senderCharacterId !== characterId)
   * - 旁白消息(senderType='narrator' 或 visibility='narrator')
   * - 当前角色不可见的私聊
   * - 无 participantIds 快照的公开消息(旧数据限制)
   * - Streaming / Failed / Cancelled / 空内容
   */
  private collectIncrementalMessages(
    allMessages: ChatMessage[],
    characterId: string,
    lastProgress: GroupCharacterMemory | null
  ): ChatMessage[] {
    // 1. 确定增量起点(基于上次进度的 sourceMessageId 在 allMessages 中的位置)
    let startIdx: number = 0;
    if (lastProgress !== null && lastProgress.sourceMessageId !== undefined
      && lastProgress.sourceMessageId.length > 0) {
      const lastId: string = lastProgress.sourceMessageId;
      let foundIdx: number = -1;
      for (let i = 0; i < allMessages.length; i++) {
        if (allMessages[i].id === lastId) {
          foundIdx = i;
          break;
        }
      }
      if (foundIdx >= 0) {
        // 从 lastId 之后开始(不含 lastId 本身,它已总结过)
        startIdx = foundIdx + 1;
      } else {
        // 找不到 lastId(可能消息被删除):从当前可读取历史重新计算
        Logger.info(LOG_TAG, 'last sourceMessageId not found, recompute from start');
        startIdx = 0;
      }
    }

    // 2. 从 startIdx 开始过滤对当前角色可见的有效消息
    const result: ChatMessage[] = [];
    for (let i = startIdx; i < allMessages.length; i++) {
      const msg: ChatMessage = allMessages[i];
      // 状态过滤:只接受 Completed
      if (msg.status !== ChatMessageStatus.Completed) {
        continue;
      }
      // 内容过滤:非空
      if (msg.content.trim().length === 0) {
        continue;
      }
      // 可见性过滤:对当前角色可见(角色自身消息 + 可见用户消息)
      if (!isMessageVisibleToCharacter(msg, characterId)) {
        continue;
      }
      result.push(msg);
    }

    return result;
  }
}

// ===== 私有辅助函数 =====

/**
 * 计算 sourceHash(稳定摘要)。
 *
 * G-MEMORY-AUTO-1A-FIX 扩展:输入覆盖所有有效消息的:
 * - message.id
 * - message.senderType
 * - message.senderCharacterId
 * - message.visibility
 * - message.content
 *
 * 按 listMessages 返回顺序(sequenceNumber ASC)拼接。
 * 算法:djb2 变体(确定性、非加密,无第三方依赖)。
 *
 * 说明:由于 ChatMessage 模型不包含 sequenceNumber 字段(该字段存在于 StoredChatMessage,
 * 但 listMessages 通过 map 丢弃),sourceHash 不直接包含 sequenceNumber。
 * 但 listMessages 已保证按 sequenceNumber ASC 排序,因此拼接顺序即 sequenceNumber 顺序,
 * 等价于按 sequenceNumber 排序后拼接。
 * message.id 唯一且不变,message.content 不变,保证同一批消息的 sourceHash 稳定。
 * 加入 senderType/senderCharacterId/visibility 后,不同用户消息会导致 hash 变化。
 */
function computeSourceHash(messages: ChatMessage[]): string {
  const parts: string[] = [];
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
  return 'sm-' + hash.toString(16).padStart(8, '0');
}

/**
 * 判断消息对指定角色是否可见(用于自动总结输入过滤)。
 *
 * G-MEMORY-AUTO-1A-FIX 引入,G-MEMORY-AUTO-1A-FIX-2 修复公开消息可见性。
 *
 * 角色自身消息(senderType='character'):
 * - senderCharacterId === characterId → 可见
 * - senderCharacterId !== characterId → 不可见(其他 AI 角色消息)
 *
 * 用户消息(senderType='user'):
 * - visibility='private':要求 recipientCharacterIds 包含 characterId(严格隔离)
 * - visibility='public':
 *   - participantIds 非空 → 检查是否包含 characterId(新数据有可靠快照)
 *   - participantIds 缺失/为空 → 默认可见(G-MEMORY-AUTO-1A-FIX-2 修复)
 *     原因:GroupConversationMessageService.appendUserMessage 从未填入 participantIds,
 *     DB 中该字段为 NULL。公开消息语义上对所有群聊成员可见,
 *     当前角色在该群聊中有记忆页面说明角色存在,因此允许读取公开用户消息。
 * - visibility='narrator':不可见(用户旁白,本阶段不处理)
 *
 * 旁白消息(senderType='narrator'):不可见(本阶段不处理)
 *
 * replyTargetCharacterIds 不影响可见性(任务第八节):
 * - 公开消息按 visibility='public' 判断
 * - 私聊消息只按 recipientCharacterIds 判断
 * - 不得用 replyTargetCharacterIds 扩大可见范围
 */
function isMessageVisibleToCharacter(msg: ChatMessage, characterId: string): boolean {
  const senderType: MessageSenderType =
    msg.senderType !== undefined ? msg.senderType! : 'user';

  // 角色消息
  if (senderType === 'character') {
    return msg.senderCharacterId === characterId;
  }

  // 用户消息
  if (senderType === 'user') {
    const visibility: MessageVisibility =
      msg.visibility !== undefined ? msg.visibility! : 'public';
    if (visibility === 'private') {
      // 私聊:要求 recipientCharacterIds 包含当前角色(严格隔离)
      const recipients: string[] =
        msg.recipientCharacterIds !== undefined ? msg.recipientCharacterIds : [];
      return recipients.indexOf(characterId) >= 0;
    }
    if (visibility === 'public') {
      // 公开消息可见性判断(G-MEMORY-AUTO-1A-FIX-2 修复)
      // - participantIds 非空:检查是否包含 characterId(新数据有可靠快照)
      // - participantIds 缺失/为空:默认可见(公开消息对所有群聊成员可见)
      const participants: string[] =
        msg.participantIds !== undefined ? msg.participantIds : [];
      if (participants.length === 0) {
        // participantIds 缺失(当前 GroupConversationMessageService 从未填入)
        // 公开消息语义上对所有群聊成员可见,当前角色在该群聊中存在记忆页面
        return true;
      }
      // participantIds 存在:检查是否包含当前角色
      return participants.indexOf(characterId) >= 0;
    }
    // visibility='narrator' 的用户消息:不可见
    return false;
  }

  // narrator 或其他类型:不可见
  return false;
}

/**
 * 在全部消息列表中定位指定 messageId 的索引(返回 -1 表示未找到)。
 */
function findMessageIndex(messages: ChatMessage[], messageId: string): number {
  for (let i = 0; i < messages.length; i++) {
    if (messages[i].id === messageId) {
      return i;
    }
  }
  return -1;
}

/**
 * 构建总结 Prompt。
 *
 * G-MEMORY-AUTO-1A-FIX 修改:System Prompt 明确允许两类内容:
 * - 用户对该角色可见的发言
 * - 该角色自己的发言
 * 禁止其他 AI 角色发言、推测其他角色想法、补充输入外事实。
 */
function buildSummaryPrompt(source: SelfSummarySource): ChatMessage[] {
  const systemPrompt: string =
    '你正在总结指定角色与用户之间的长期记忆。\n\n' +
    '你只能使用以下两类内容:\n' +
    '1. 用户对该角色可见的发言;\n' +
    '2. 该角色自己的发言。\n\n' +
    '不得使用其他 AI 角色的发言。\n' +
    '不得推测其他 AI 角色的想法。\n' +
    '不得补充输入中不存在的事实。\n\n' +
    '总结重点:\n' +
    '- 用户告诉该角色的重要身份信息\n' +
    '- 用户的稳定喜好和要求\n' +
    '- 用户与该角色共同经历的事件\n' +
    '- 用户与该角色作出的约定\n' +
    '- 用户提出、角色回应的重要计划\n' +
    '- 角色对用户明确表达的态度\n' +
    '- 角色自己明确陈述的长期目标和经历\n\n' +
    '避免:\n' +
    '- 普通寒暄\n' +
    '- 一次性的短时指令\n' +
    '- 重复内容\n' +
    '- 无长期价值的问答\n' +
    '- 模型格式提示\n\n' +
    '输出要求:\n' +
    '- 简洁中文文本\n' +
    '- 不超过 500 字\n' +
    '- 只输出摘要正文\n' +
    '- 不输出 JSON\n' +
    '- 不输出代码块\n' +
    '- 不输出解释';

  const userContent: string =
    '角色:' + source.characterName + '\n' +
    '群聊:' + source.groupTitle + '\n\n' +
    '以下是 ' + source.characterName + ' 可见的用户发言,以及 ' + source.characterName + ' 自己的发言:\n\n' +
    formatMessagesForPrompt(source.messages, source.characterName) + '\n\n' +
    '请输出该角色的自身记忆摘要:';

  const systemMessage: ChatMessage = {
    id: 'group-self-summary-system',
    role: ChatRole.System,
    content: systemPrompt,
    createdAt: 0
  };
  const userMessage: ChatMessage = {
    id: 'group-self-summary-user',
    role: ChatRole.User,
    content: userContent,
    createdAt: 0
  };
  return [systemMessage, userMessage];
}

/**
 * 格式化消息为 Prompt 输入文本。
 *
 * G-MEMORY-AUTO-1A-FIX 修改:每条消息显示"说话者"(用户/角色名),
 * 区分用户消息与角色自身消息。
 * 不包含其他 AI 角色消息、完整角色卡、Preset、Lorebook。
 */
function formatMessagesForPrompt(messages: ChatMessage[], characterName: string): string {
  const parts: string[] = [];
  for (let i = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i];
    const time: string = formatTimestamp(msg.createdAt);
    const round: string = msg.generationBatchId !== undefined
      && msg.generationBatchId.length > 0
      ? shortId(msg.generationBatchId) : '无';
    const senderType: MessageSenderType =
      msg.senderType !== undefined ? msg.senderType! : 'user';
    const speaker: string = senderType === 'character' ? characterName : '用户';
    parts.push('[消息 ' + (i + 1).toString() + ']');
    parts.push('说话者:' + speaker);
    parts.push('时间:' + time);
    parts.push('轮次:' + round);
    parts.push('内容:' + msg.content);
    parts.push('');
  }
  return parts.join('\n');
}

/**
 * 格式化时间戳为 MM-dd HH:mm。
 */
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
 * 将 ModelServiceError 映射为 SelfSummaryErrorKind。
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
      return { kind: SelfSummaryErrorKind.NoModelConfig, msg: '没有可用的模型配置' } as ModelErrorMapping;
    }
    if (err.type === ModelServiceErrorType.ApiKeyMissing) {
      return { kind: SelfSummaryErrorKind.ModelAuthFailed, msg: '模型认证失败,请检查 API Key' } as ModelErrorMapping;
    }
    if (err.type === ModelServiceErrorType.NetworkFailure) {
      return { kind: SelfSummaryErrorKind.NetworkFailed, msg: '网络连接失败,请稍后重试' } as ModelErrorMapping;
    }
  }
  return { kind: SelfSummaryErrorKind.Internal, msg: '总结失败,请稍后重试' } as ModelErrorMapping;
}

/**
 * 安全错误分类(用于日志,不暴露敏感信息)。
 */
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

/**
 * 截断 ID 为短 ID(取后 8 位,用于日志)。
 */
function shortId(id: string): string {
  if (id.length <= 8) {
    return id;
  }
  return id.substring(id.length - 8);
}
