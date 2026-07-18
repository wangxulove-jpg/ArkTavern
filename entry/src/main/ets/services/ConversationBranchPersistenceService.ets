/**
 * ConversationBranchPersistenceService(T-6.4A)
 *
 * 职责:
 * - 协调 ConversationBranchRepository / MessageRepository / MessageSwipeRepository
 * - 提供 Branch 级业务接口:ensureRootBranch / forkAtMessage / loadActiveBranchMessages /
 *   appendMessageToActiveBranch / updateActiveBranchSwipeSelection / getRecordCounts / listBranches
 * - 通过 DbHelper 事务保证跨表写入的原子性
 *
 * 不依赖:
 * - ArkUI / 页面
 * - Provider / PromptBuilder / ChatService
 *
 * 设计原则:
 * - WithStore 方法组合,避免嵌套事务
 * - 不修改 Message 实体(只通过 BranchMessageLink 关联)
 * - 不复制 Candidate 正文(只保存 BranchSwipeSelection 选择)
 * - 不删除原 Branch 后续消息
 * - 活动 Branch 的 Candidate 投影只用于当前 Branch 加载,不影响其他 Branch
 * - 日志只记录操作类型和数量,不记录正文 / 完整 ID / SQL
 *
 * 物化兼容(T-6.4A 阶段):
 * - 当前活动 Branch 的 SwipeSelection 与 message_swipe_groups.active_candidate_index 同步
 * - 非活动 Branch 的选择只保存在 BranchSwipeSelection
 * - 切换 Branch 时由 T-6.4B 重新物化对应 Candidate
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import {
  ConversationBranchRepository,
  V5IntegrityReport
} from '../repositories/ConversationBranchRepository';
import { MessageRepository } from '../repositories/MessageRepository';
import { MessageSwipeRepository } from '../repositories/MessageSwipeRepository';
import {
  ConversationBranch,
  BranchMessageLink,
  BranchSwipeSelection,
  ConversationBranchSummary,
  ConversationRecordCounts
} from '../models/ConversationBranch';
import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { MessageSwipeCandidate } from '../models/MessageSwipe';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ConvBranchSvc';

/**
 * 判断消息是否为可建立 Swipe 的 Assistant 消息。
 * 与 MessageSwipePersistenceService 保持一致。
 */
function isSwipeableAssistant(message: ChatMessage): boolean {
  if (message.role !== ChatRole.Assistant) {
    return false;
  }
  const source: ChatMessageSource | undefined = message.source;
  if (source === undefined) {
    return true;
  }
  return source === ChatMessageSource.Conversation;
}

/**
 * 用 Candidate 的内容投影 ChatMessage(不可变更新)。
 * 只覆盖 content / status / errorMessage / isStreaming / updatedAt,
 * 保留 id / role / createdAt / source / sequenceNumber。
 */
function projectMessageWithCandidate(
  message: ChatMessage,
  candidate: MessageSwipeCandidate
): ChatMessage {
  return {
    id: message.id,
    role: message.role,
    content: candidate.content,
    createdAt: message.createdAt,
    updatedAt: candidate.updatedAt !== undefined ? candidate.updatedAt : candidate.createdAt,
    isStreaming: candidate.isStreaming,
    errorMessage: candidate.errorMessage,
    status: candidate.status,
    source: message.source
  };
}

export class ConversationBranchPersistenceService {
  private readonly dbHelper: DbHelper;
  private readonly branchRepository: ConversationBranchRepository;
  private readonly messageRepository: MessageRepository;
  private readonly swipeRepository: MessageSwipeRepository;

  constructor(
    dbHelper: DbHelper,
    branchRepository: ConversationBranchRepository,
    messageRepository: MessageRepository,
    swipeRepository: MessageSwipeRepository
  ) {
    this.dbHelper = dbHelper;
    this.branchRepository = branchRepository;
    this.messageRepository = messageRepository;
    this.swipeRepository = swipeRepository;
  }

  // ===== Root Branch =====

  /**
   * 确保 Chat 存在 Root Branch(幂等)。
   * - 已存在:直接返回
   * - 不存在:在事务中创建 Root Branch + chat_branch_state
   *
   * 不检查 Chat 是否存在,由调用方负责(避免与 Chat 创建事务嵌套)。
   * ChatPersistenceService.createSessionWithFirstMessage 等场景需要调用方在外部事务中
   * 使用 ensureRootBranchWithStore。
   *
   * @param chatId 所属 Chat ID
   * @returns Root Branch
   */
  async ensureRootBranch(chatId: string): Promise<ConversationBranch> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('ensureRootBranch: chatId empty');
    }
    const existing: ConversationBranch | null =
      await this.branchRepository.getRootBranch(chatId);
    if (existing !== null) {
      return existing;
    }
    let result: ConversationBranch | null = null;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          result = await this.ensureRootBranchWithStore(store, chatId);
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `ensureRootBranch: ${(err as Error).message}`
      );
    }
    return result!;
  }

  /**
   * 在给定 store 上确保 Root Branch 存在(事务内部方法)。
   * 幂等:已存在时直接返回。
   */
  async ensureRootBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ConversationBranch> {
    const existing: ConversationBranch | null =
      await this.branchRepository.getRootBranchWithStore(store, chatId);
    if (existing !== null) {
      return existing;
    }
    const branch: ConversationBranch =
      await this.branchRepository.createRootBranchWithStore(store, chatId);
    await this.branchRepository.setActiveBranchWithStore(store, chatId, branch.id);
    Logger.info(LOG_TAG, 'root created');
    return branch;
  }

  // ===== Active Branch =====

  /**
   * 获取 Chat 的当前活动 Branch。
   * 不存在返回 null。
   */
  async getActiveBranch(chatId: string): Promise<ConversationBranch | null> {
    return await this.branchRepository.getActiveBranch(chatId);
  }

  // ===== Branch 列表 =====

  /**
   * 列出 Chat 的所有 Branch 摘要。
   */
  async listBranches(chatId: string): Promise<ConversationBranchSummary[]> {
    return await this.branchRepository.listBranches(chatId);
  }

  // ===== 记录数量 =====

  /**
   * 获取 Chat 的记录数量统计。
   */
  async getRecordCounts(chatId: string): Promise<ConversationRecordCounts> {
    return await this.branchRepository.getRecordCounts(chatId);
  }

  // ===== 加载活动 Branch 消息 =====

  /**
   * 加载当前活动 Branch 的消息路径(按 position ASC)。
   *
   * 流程:
   * 1. 读取 activeBranch
   * 2. 读取该 Branch 的 Message Links(position ASC)
   * 3. 按 messageId 读取 Message(保留 id / role / createdAt / source)
   * 4. 读取该 Branch 的 SwipeSelections
   * 5. 对有选择的 Assistant,读取对应 Candidate 并投影 content / status / errorMessage / isStreaming
   * 6. 返回新数组和新对象
   *
   * 不修改 MessageRepository 返回对象。
   * 不修改 Candidate。
   * 不记录正文。
   * Message ID / role / source / sequenceNumber 保持不变。
   *
   * @param chatId 所属 Chat ID
   * @returns 投影后的消息数组(可能为空)
   */
  async loadActiveBranchMessages(chatId: string): Promise<ChatMessage[]> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('loadActiveBranchMessages: chatId empty');
    }
    // 只读操作:不开启写事务,不创建 Root Branch
    // Active State 缺失属于数据完整性问题,返回明确错误而非空数组
    const activeBranch: ConversationBranch | null =
      await this.branchRepository.getActiveBranch(chatId);
    if (activeBranch === null) {
      throw DatabaseError.notFound('loadActiveBranchMessages: branch state missing');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const links: BranchMessageLink[] =
      await this.branchRepository.listMessageLinksWithStore(store, activeBranch.id);
    if (links.length === 0) {
      return [];
    }
    // 加载该 Branch 的 SwipeSelections
    const selections: BranchSwipeSelection[] =
      await this.branchRepository.listSwipeSelectionsWithStore(store, activeBranch.id);
    const selectionMap: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < selections.length; i++) {
      selectionMap.set(selections[i].assistantMessageId, selections[i].candidateIndex);
    }
    // 按 messageId 加载并投影
    const result: ChatMessage[] = [];
    for (let i = 0; i < links.length; i++) {
      const messageId: string = links[i].messageId;
      const message: ChatMessage | null = await this.messageRepository.getById(messageId);
      if (message === null) {
        // Message 已被删除但 Link 仍存在,跳过(数据完整性问题)
        Logger.warn(LOG_TAG, 'message missing in branch path');
        continue;
      }
      // 如果是可 Swipe 的 Assistant 且有 Selection,投影 Candidate 内容
      if (isSwipeableAssistant(message) && selectionMap.has(messageId)) {
        const candidateIndex: number = selectionMap.get(messageId)!;
        const candidate: MessageSwipeCandidate | null =
          await this.swipeRepository.getCandidateWithStore(store, messageId, candidateIndex);
        if (candidate !== null) {
          const projected: ChatMessage = projectMessageWithCandidate(message, candidate);
          result.push(projected);
          continue;
        }
        // Candidate 不存在(可能被删除),回退使用 Message 本身
      }
      // 普通 Message 或无 Selection 的 Assistant:直接使用 Message
      result.push(message);
    }
    Logger.info(LOG_TAG, 'active branch messages loaded count=' + result.length.toString());
    return result;
  }

  // ===== Fork Branch =====

  /**
   * 从指定 Branch 的某条 Message 创建 Child Branch(事务)。
   *
   * 流程:
   * 1. 验证 sourceBranch 属于 chatId
   * 2. 验证 messageId 在 sourceBranch 路径内(获取 position)
   * 3. 创建 Child Branch
   * 4. 复制 sourceBranch 中 position 0..forkPosition 的全部 Message Links
   * 5. 复制这些 messageId 对应的 SwipeSelections
   * 6. 若传入 selectedCandidateIndex:
   *    - 目标必须是 Assistant Conversation
   *    - Candidate 必须存在
   *    - 覆盖新 Branch 对该 Assistant 的选择
   * 7. 将新 Branch 设置为 Active
   * 8. 提交
   *
   * 创建后:
   * - 新 Branch 的消息路径截至目标 Message
   * - 原 Branch 后续 Message 仍完整存在
   * - 原 Branch active Candidate 选择不变
   * - 不复制 Message 实体
   * - 不复制 Candidate 实体
   * - 不删除任何数据
   *
   * @param chatId 所属 Chat ID
   * @param sourceBranchId 来源 Branch ID
   * @param messageId Fork 点 Message ID
   * @param selectedCandidateIndex 可选,覆盖新 Branch 对该 Assistant 的 Candidate 选择
   * @returns 新创建的 Child Branch
   */
  async forkAtMessage(
    chatId: string,
    sourceBranchId: string,
    messageId: string,
    selectedCandidateIndex?: number
  ): Promise<ConversationBranch> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('forkAtMessage: chatId empty');
    }
    if (sourceBranchId.length === 0) {
      throw DatabaseError.invalidData('forkAtMessage: sourceBranchId empty');
    }
    if (messageId.length === 0) {
      throw DatabaseError.invalidData('forkAtMessage: messageId empty');
    }
    if (selectedCandidateIndex !== undefined) {
      if (!Number.isInteger(selectedCandidateIndex) || selectedCandidateIndex < 0) {
        throw DatabaseError.invalidData('forkAtMessage: invalid selectedCandidateIndex');
      }
    }

    let result: ConversationBranch | null = null;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          result = await this.forkAtMessageWithStore(
            store, chatId, sourceBranchId, messageId, selectedCandidateIndex
          );
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `forkAtMessage: ${(err as Error).message}`
      );
    }
    return result!;
  }

  /**
   * 在给定 store 上执行 forkAtMessage(事务内部方法)。
   */
  async forkAtMessageWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    sourceBranchId: string,
    messageId: string,
    selectedCandidateIndex?: number
  ): Promise<ConversationBranch> {
    // 1. 验证 sourceBranch 属于 chatId
    const sourceBranch: ConversationBranch | null =
      await this.branchRepository.getBranchWithStore(store, sourceBranchId);
    if (sourceBranch === null) {
      throw DatabaseError.notFound('forkAtMessage: sourceBranch not found');
    }
    if (sourceBranch.chatId !== chatId) {
      throw DatabaseError.invalidData('forkAtMessage: sourceBranch chatId mismatch');
    }
    // 2. 验证 messageId 在 sourceBranch 路径内
    const forkPosition: number =
      await this.branchRepository.getMessagePositionWithStore(store, sourceBranchId, messageId);
    if (forkPosition < 0) {
      throw DatabaseError.notFound('forkAtMessage: messageId not in sourceBranch');
    }
    // 3. 创建 Child Branch
    const childBranch: ConversationBranch =
      await this.branchRepository.createChildBranchWithStore(
        store, chatId, sourceBranchId, messageId, ''
      );
    // 4. 复制 sourceBranch 中 position 0..forkPosition 的 Message Links
    await this.branchRepository.copyMessageLinksThroughPositionWithStore(
      store, sourceBranchId, childBranch.id, forkPosition
    );
    // 5. 读取复制的 messageIds,复制对应的 SwipeSelections
    const childLinks: BranchMessageLink[] =
      await this.branchRepository.listMessageLinksWithStore(store, childBranch.id);
    const copiedMessageIds: string[] = childLinks.map(
      (link: BranchMessageLink): string => link.messageId
    );
    await this.branchRepository.copySwipeSelectionsForMessageIdsWithStore(
      store, sourceBranchId, childBranch.id, copiedMessageIds
    );
    // 6. 若传入 selectedCandidateIndex,覆盖新 Branch 对该 Assistant 的选择
    if (selectedCandidateIndex !== undefined) {
      // 验证目标 Message 是 Assistant Conversation
      const targetMessage: ChatMessage | null =
        await this.messageRepository.getById(messageId);
      if (targetMessage === null) {
        throw DatabaseError.notFound('forkAtMessage: target message not found');
      }
      if (!isSwipeableAssistant(targetMessage)) {
        throw DatabaseError.invalidData(
          'forkAtMessage: selectedCandidateIndex requires Assistant Conversation'
        );
      }
      // 验证 Candidate 存在
      const candidate: MessageSwipeCandidate | null =
        await this.swipeRepository.getCandidateWithStore(
          store, messageId, selectedCandidateIndex
        );
      if (candidate === null) {
        throw DatabaseError.invalidData('forkAtMessage: candidate not found');
      }
      // 覆盖新 Branch 对该 Assistant 的选择
      await this.branchRepository.upsertSwipeSelectionWithStore(
        store, childBranch.id, messageId, selectedCandidateIndex
      );
    }
    // 7. 将新 Branch 设置为 Active
    await this.branchRepository.setActiveBranchWithStore(store, chatId, childBranch.id);
    // 8. 触发 Branch 时间戳更新
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, childBranch.id, now);
    Logger.info(LOG_TAG, 'child created');
    return childBranch;
  }

  // ===== 新消息加入 Active Branch =====

  /**
   * 将新消息追加到当前活动 Branch(事务)。
   *
   * 流程:
   * 1. 读取 activeBranch
   * 2. 获取该 Branch 最大 position + 1
   * 3. 插入 BranchMessage Link
   * 4. 更新 Branch.updatedAt / lastMessageAt
   *
   * 不检查 Message 是否已存在(由调用方负责在 ChatPersistenceService 事务中先插入 Message)。
   * 调用方应在同一事务中使用 appendMessageToActiveBranchWithStore。
   *
   * @param chatId 所属 Chat ID
   * @param messageId 待追加的 Message ID
   */
  async appendMessageToActiveBranch(
    chatId: string,
    messageId: string
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('appendMessageToActiveBranch: chatId empty');
    }
    if (messageId.length === 0) {
      throw DatabaseError.invalidData('appendMessageToActiveBranch: messageId empty');
    }
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.appendMessageToActiveBranchWithStore(store, chatId, messageId);
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `appendMessageToActiveBranch: ${(err as Error).message}`
      );
    }
  }

  /**
   * 在给定 store 上追加 Message 到 Active Branch(事务内部方法)。
   *
   * 注意:HarmonyOS RDB 在事务内查询读不到本事务内的写入(快照隔离),
   * 因此不能在同一事务中多次调用本方法来追加多条消息 —
   * 第二次调用 getMaxPositionWithStore 仍返回事务前的 maxPosition,
   * 会触发 (branch_id, position) PRIMARY KEY 冲突。
   * 多条消息的原子追加请使用 appendMessagePairToActiveBranchWithStore。
   */
  async appendMessageToActiveBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    messageId: string
  ): Promise<void> {
    const activeBranch: ConversationBranch | null =
      await this.branchRepository.getActiveBranchWithStore(store, chatId);
    if (activeBranch === null) {
      throw DatabaseError.notFound('appendMessageToActiveBranch: active branch not found');
    }
    const maxPosition: number =
      await this.branchRepository.getMaxPositionWithStore(store, activeBranch.id);
    const nextPosition: number = maxPosition + 1;
    await this.branchRepository.insertMessageLinkWithStore(
      store, activeBranch.id, messageId, nextPosition
    );
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, activeBranch.id, now);
    Logger.info(LOG_TAG, 'message linked');
  }

  /**
   * 在给定 store 上原子追加 User + Assistant 两条 Message 到 Active Branch。
   *
   * 用于 appendUserAndStreamingAssistant 场景:
   * - 只读取一次 maxPosition(避免快照隔离导致 position 冲突)
   * - userMessage 使用 maxPosition + 1
   * - assistantMessage 使用 maxPosition + 2
   * - 只 touch 一次 Branch
   *
   * 必须在外层事务中调用,本方法不开启事务。
   */
  async appendMessagePairToActiveBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    userMessageId: string,
    assistantMessageId: string
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('appendMessagePair: chatId empty');
    }
    if (userMessageId.length === 0) {
      throw DatabaseError.invalidData('appendMessagePair: userMessageId empty');
    }
    if (assistantMessageId.length === 0) {
      throw DatabaseError.invalidData('appendMessagePair: assistantMessageId empty');
    }
    const activeBranch: ConversationBranch | null =
      await this.branchRepository.getActiveBranchWithStore(store, chatId);
    if (activeBranch === null) {
      throw DatabaseError.notFound('appendMessagePair: active branch not found');
    }
    const maxPosition: number =
      await this.branchRepository.getMaxPositionWithStore(store, activeBranch.id);
    const userPosition: number = maxPosition + 1;
    const assistantPosition: number = maxPosition + 2;
    await this.branchRepository.insertMessageLinkWithStore(
      store, activeBranch.id, userMessageId, userPosition
    );
    await this.branchRepository.insertMessageLinkWithStore(
      store, activeBranch.id, assistantMessageId, assistantPosition
    );
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, activeBranch.id, now);
    Logger.info(LOG_TAG, 'message pair linked');
  }

  /**
   * 在给定 store 上原子地创建 Root Branch 并追加 firstMessage(position=0)。
   *
   * 用于 createSessionWithFirstMessage 场景:
   * - 避免在事务中先 ensureRootBranch 再 getActiveBranch(快照隔离可能读不到 state)
   * - 直接复用 ensureRootBranchWithStore 返回的 branch,用其 id 插入 link
   * - position 固定为 0(新 Root Branch 的第一条消息)
   *
   * 必须在外层事务中调用,本方法不开启事务。
   *
   * @returns 创建的 Root Branch
   */
  async ensureRootBranchAndAppendFirstMessageWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    firstMessageId: string
  ): Promise<ConversationBranch> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('ensureRootAndAppend: chatId empty');
    }
    if (firstMessageId.length === 0) {
      throw DatabaseError.invalidData('ensureRootAndAppend: firstMessageId empty');
    }
    const branch: ConversationBranch =
      await this.ensureRootBranchWithStore(store, chatId);
    // 直接使用刚创建/获取的 branch.id,不再查询 chat_branch_state
    await this.branchRepository.insertMessageLinkWithStore(
      store, branch.id, firstMessageId, 0
    );
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, branch.id, now);
    Logger.info(LOG_TAG, 'root created with first message linked');
    return branch;
  }

  // ===== Swipe Selection 同步 =====

  /**
   * 更新当前活动 Branch 对指定 Assistant 的 Candidate 选择(事务)。
   *
   * 流程:
   * 1. 读取 activeBranch
   * 2. Upsert BranchSwipeSelection
   *
   * 不修改 message_swipe_groups.active_candidate_index(由 MessageSwipePersistenceService 物化时同步)。
   * 本方法只负责 Branch 维度的选择记录。
   *
   * @param chatId 所属 Chat ID
   * @param assistantMessageId Assistant Message ID
   * @param candidateIndex Candidate 索引(非负整数)
   */
  async updateActiveBranchSwipeSelection(
    chatId: string,
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('updateActiveBranchSwipeSelection: chatId empty');
    }
    if (assistantMessageId.length === 0) {
      throw DatabaseError.invalidData('updateActiveBranchSwipeSelection: assistantMessageId empty');
    }
    if (!Number.isInteger(candidateIndex) || candidateIndex < 0) {
      throw DatabaseError.invalidData('updateActiveBranchSwipeSelection: invalid candidateIndex');
    }
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.updateActiveBranchSwipeSelectionWithStore(
            store, chatId, assistantMessageId, candidateIndex
          );
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `updateActiveBranchSwipeSelection: ${(err as Error).message}`
      );
    }
  }

  /**
   * 在给定 store 上更新活动 Branch 的 Swipe Selection(事务内部方法)。
   */
  async updateActiveBranchSwipeSelectionWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<void> {
    const activeBranch: ConversationBranch | null =
      await this.branchRepository.getActiveBranchWithStore(store, chatId);
    if (activeBranch === null) {
      throw DatabaseError.notFound('updateActiveBranchSwipeSelection: active branch not found');
    }
    await this.branchRepository.upsertSwipeSelectionWithStore(
      store, activeBranch.id, assistantMessageId, candidateIndex
    );
    Logger.info(LOG_TAG, 'swipe selection updated');
  }

  // ===== 删除清理 =====

  /**
   * 删除指定 Chat 的全部 Branch 数据(事务内部方法)。
   * 删除顺序:SwipeSelections → MessageLinks → BranchState → Branches
   * 调用方应在删除 Chat 的事务中调用此方法。
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<void> {
    await this.branchRepository.removeByChatIdWithStore(store, chatId);
    Logger.info(LOG_TAG, 'branches removed for chat');
  }

  // ===== v5 完整性检查与修复 =====

  /**
   * 检查 v5 Branch 数据完整性(只读)。
   *
   * 用于诊断运行时 transaction failed 问题:
   * - 统计 Chat 总数、Root Branch 总数、Active State 总数
   * - 检测没有 Root 的 Chat
   * - 检测没有 Active State 的 Chat
   * - 检测 Root 重复的 Chat
   * - 检测 Active Branch 不属于 Chat 的情况
   *
   * 不修改任何数据。
   * 不记录 chatId / branchId 等敏感信息,只输出计数。
   */
  async checkV5Integrity(): Promise<V5IntegrityReport> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.branchRepository.checkV5IntegrityWithStore(store);
  }

  /**
   * 修复 v5 Branch 数据完整性(事务,幂等)。
   *
   * 仅在 checkV5Integrity 报告存在以下问题时调用:
   * - chatsWithoutRoot > 0
   * - chatsWithoutActiveState > 0
   *
   * 修复内容:
   * - 为没有 Root 的 Chat 创建 Root Branch + Active State
   * - 为没有 Active State 但有 Root 的 Chat 创建 Active State
   *
   * 不修复:
   * - 多个 Root 的 Chat(数据完整性错误,需人工处理)
   * - Active Branch 不属于 Chat 的情况(数据完整性错误)
   *
   * 不删除任何用户数据。
   * 不复制或修改 Message / Candidate。
   * 失败整体回滚。
   */
  async repairV5Integrity(): Promise<V5RepairResult> {
    let created: number = 0;
    let skipped: number = 0;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          const report: V5IntegrityReport =
            await this.branchRepository.checkV5IntegrityWithStore(store);
          if (report.chatsWithMultipleRoots > 0
            || report.chatsWithInvalidActiveBranch > 0) {
            // 数据完整性错误,不修复
            skipped = report.chatsWithoutRoot + report.chatsWithoutActiveState;
            Logger.error(LOG_TAG, 'repair skipped: data integrity error');
            return;
          }
          // 为没有 Root 的 Chat 创建 Root + Active State
          for (let i = 0; i < report.chatIdsWithoutRoot.length; i++) {
            const chatId: string = report.chatIdsWithoutRoot[i];
            await this.ensureRootBranchWithStore(store, chatId);
            created++;
          }
          // 为没有 Active State 但有 Root 的 Chat 创建 Active State
          for (let i = 0; i < report.chatIdsWithoutActiveState.length; i++) {
            const chatId: string = report.chatIdsWithoutActiveState[i];
            const root: ConversationBranch | null =
              await this.branchRepository.getRootBranchWithStore(store, chatId);
            if (root !== null) {
              await this.branchRepository.setActiveBranchWithStore(store, chatId, root.id);
              created++;
            } else {
              skipped++;
            }
          }
        },
        'v5_integrity_repair'
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `repairV5Integrity: ${(err as Error).message}`
      );
    }
    Logger.info(LOG_TAG, 'v5 integrity repaired created=' + created.toString()
      + ' skipped=' + skipped.toString());
    return {
      createdCount: created,
      skippedCount: skipped
    };
  }
}

/**
 * v5 修复结果。
 */
export interface V5RepairResult {
  readonly createdCount: number;
  readonly skippedCount: number;
}
