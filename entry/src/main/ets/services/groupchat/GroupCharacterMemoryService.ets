/**
 * GroupCharacterMemoryService 多人聊天角色记忆业务服务
 *
 * 职责(G-MEMORY-1A):
 * - 多人聊天每角色独立记忆的唯一正式写入口
 * - 手动创建 / 编辑 / 归档 / 恢复 / 删除
 * - 跨表归属校验:GroupConversation 存在 / Character 存在 /
 *   ChatParticipant(groupConversationId, characterId) 当前存在
 * - 软历史引用:Character 缺失时记忆仍保留(本阶段不级联删除)
 *
 * 不负责(本阶段禁止):
 * - AI 自动提取记忆 / 模型总结 / 轮次结束自动生成记忆
 * - 每条消息自动写记忆
 * - Prompt 注入 / 记忆检索排序算法 / 向量数据库 / Embedding
 * - 交互记忆自动失效管理(留给 G-MEMORY-1B / G-MEMORY-1C)
 * - 把记忆注入 GroupPromptAssembler
 *
 * 事务规则:
 * - 所有跨表操作使用 DbHelper.runInTransaction
 * - 事务内只调用 Repository 的 *WithStore 方法,不调用普通方法(避免嵌套事务)
 *
 * 依赖方向:
 * - ChatRepository(只读 getByIdWithStore)
 * - CharacterRepository(只读 getByIdWithStore)
 * - ChatParticipantRepository(只读 listByChatIdWithStore)
 * - GroupCharacterMemoryRepository(写入)
 * - DbHelper(事务)
 *
 * 日志安全:
 * - 不记录完整记忆正文 / 完整 ID / SQL 参数 / 数据库路径
 * - 仅记录操作类型、origin、importance、status、数量、截断短 ID
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { ChatRepository } from '../../repositories/ChatRepository';
import { CharacterRepository } from '../../repositories/CharacterRepository';
import { ChatParticipantRepository } from '../../repositories/ChatParticipantRepository';
import { GroupCharacterMemoryRepository, UpsertRollingSummaryPayload } from '../../repositories/groupchat/GroupCharacterMemoryRepository';
import { Chat } from '../../models/Chat';
import { Character } from '../../models/Character';
import { ChatParticipant } from '../../models/ChatParticipant';
import {
  GroupCharacterMemory,
  GroupCharacterMemoryOrigin,
  GroupCharacterMemoryStatus,
  GROUP_CHARACTER_MEMORY_ID_PREFIX,
  GROUP_CHARACTER_MEMORY_TITLE_MAX,
  GROUP_CHARACTER_MEMORY_CONTENT_MAX,
  GROUP_CHARACTER_MEMORY_IMPORTANCE_MIN,
  GROUP_CHARACTER_MEMORY_IMPORTANCE_MAX,
  GROUP_CHARACTER_MEMORY_IMPORTANCE_DEFAULT,
  isGroupCharacterMemoryImportance,
  normalizeKeywords,
  parseKeywordsFromText,
  createGroupCharacterMemoryRecord
} from '../../models/groupchat/GroupCharacterMemory';
import {
  GroupCharacterMemoryError,
  GroupCharacterMemoryErrorKind,
  isGroupCharacterMemoryError
} from '../../models/groupchat/GroupCharacterMemoryError';
import { DatabaseError } from '../../models/DatabaseError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'GroupCharacterMemoryService';

/** 手动记忆创建输入 */
export interface CreateManualGroupMemoryInput {
  readonly groupConversationId: string;
  readonly characterId: string;
  readonly title: string;
  readonly content: string;
  readonly importance: number;
  /** 关键词文本(逗号分隔,Service 内部解析) */
  readonly keywordsText?: string;
  /** 关键词列表(若提供,优先于 keywordsText) */
  readonly keywords?: string[];
}

/** 手动记忆更新输入 */
export interface UpdateManualGroupMemoryInput {
  readonly memoryId: string;
  readonly title: string;
  readonly content: string;
  readonly importance: number;
  readonly keywordsText?: string;
  readonly keywords?: string[];
}

/** 交互记忆创建输入(G-MEMORY-AUTO-1A 自动总结等交互来源) */
export interface CreateInteractionMemoryInput {
  readonly groupConversationId: string;
  readonly characterId: string;
  readonly title: string;
  readonly content: string;
  readonly importance: number;
  readonly keywords?: string[];
  readonly sourceMessageId: string;
  readonly sourceRoundId?: string;
  readonly sourceSenderCharacterId: string;
  readonly sourceType: string;
  readonly sourceHash: string;
}

/** 修改已批准自动总结记忆输入(G-MEMORY-AUTO-1A-FIX-2) */
export interface UpdateApprovedSelfSummaryInput {
  readonly memoryId: string;
  readonly title: string;
  readonly content: string;
  readonly importance: number;
  readonly keywords?: string[];
}

export class GroupCharacterMemoryService {
  private readonly chatRepo: ChatRepository;
  private readonly characterRepo: CharacterRepository;
  private readonly participantRepo: ChatParticipantRepository;
  private readonly memoryRepo: GroupCharacterMemoryRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    chatRepo: ChatRepository,
    characterRepo: CharacterRepository,
    participantRepo: ChatParticipantRepository,
    memoryRepo: GroupCharacterMemoryRepository,
    dbHelper: DbHelper
  ) {
    this.chatRepo = chatRepo;
    this.characterRepo = characterRepo;
    this.participantRepo = participantRepo;
    this.memoryRepo = memoryRepo;
    this.dbHelper = dbHelper;
  }

  /** 获取单条记忆(只读,不走事务) */
  async getById(memoryId: string): Promise<GroupCharacterMemory | null> {
    if (memoryId === '') {
      throw GroupCharacterMemoryError.memoryNotFound();
    }
    return await this.memoryRepo.getById(memoryId);
  }

  /**
   * 列出指定角色在某群聊的全部记忆(全部 / Active / Archived 由调用方决定筛选)。
   * 不走事务,直接读取。
   */
  async listByCharacter(
    groupConversationId: string,
    characterId: string,
    filter: GroupCharacterMemoryFilter
  ): Promise<GroupCharacterMemory[]> {
    if (groupConversationId === '') {
      throw GroupCharacterMemoryError.groupNotFound();
    }
    if (characterId === '') {
      throw GroupCharacterMemoryError.characterNotFound();
    }
    if (filter === GroupCharacterMemoryFilter.Active) {
      return await this.memoryRepo.listActiveByCharacter(groupConversationId, characterId);
    }
    if (filter === GroupCharacterMemoryFilter.Archived) {
      return await this.memoryRepo.listArchivedByCharacter(groupConversationId, characterId);
    }
    return await this.memoryRepo.listByCharacter(groupConversationId, characterId);
  }

  /** 统计记忆数量(只读) */
  async countByCharacter(
    groupConversationId: string,
    characterId: string
  ): Promise<number> {
    if (groupConversationId === '' || characterId === '') {
      return 0;
    }
    return await this.memoryRepo.countByCharacter(groupConversationId, characterId);
  }

  /**
   * 创建手动记忆。
   * 事务内校验:GroupConversation 存在 → Character 存在 →
   *   ChatParticipant(groupConversationId, characterId) 当前存在 → 插入记忆。
   * 固定 origin=Manual / status=Active / source_*=undefined。
   *
   * 注意:参与者校验为"当前存在",但移除成员后记忆保留。
   * 此校验仅用于"防止用户给未加入的角色创建记忆",
   * 不影响"已移除角色在数据库中保留的历史记忆"。
   */
  async createManualMemory(
    input: CreateManualGroupMemoryInput
  ): Promise<GroupCharacterMemory> {
    validateTitle(input.title);
    validateContent(input.content);
    validateImportance(input.importance);
    const keywords: string[] = resolveKeywords(input.keywords, input.keywordsText);

    const memoryId: string = GROUP_CHARACTER_MEMORY_ID_PREFIX + generateUuid();
    const now: number = nowMillis();

    let result: GroupCharacterMemory | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        // 1. 校验群聊存在
        const chat: Chat | null = await this.chatRepo.getByIdWithStore(store, input.groupConversationId);
        if (chat === null) {
          throw GroupCharacterMemoryError.groupNotFound();
        }
        // 2. 校验角色存在
        const character: Character | null =
          await this.characterRepo.getByIdWithStore(store, input.characterId);
        if (character === null) {
          throw GroupCharacterMemoryError.characterNotFound();
        }
        // 3. 校验参与者当前存在(防止给未加入的角色创建记忆)
        const participants: ChatParticipant[] =
          await this.participantRepo.listByChatIdWithStore(store, input.groupConversationId);
        let found: boolean = false;
        for (let i = 0; i < participants.length; i++) {
          if (participants[i].characterId === input.characterId) {
            found = true;
            break;
          }
        }
        if (!found) {
          throw GroupCharacterMemoryError.participantNotFound();
        }

        const memory: GroupCharacterMemory = createGroupCharacterMemoryRecord({
          id: memoryId,
          groupConversationId: input.groupConversationId,
          characterId: input.characterId,
          origin: GroupCharacterMemoryOrigin.Manual,
          status: GroupCharacterMemoryStatus.Active,
          title: normalizeTitle(input.title),
          content: normalizeContent(input.content),
          importance: input.importance,
          keywords: keywords,
          createdAt: now,
          updatedAt: now
        });
        await this.memoryRepo.insertWithStore(store, memory);
        result = memory;
      },
      'group_character_memory_create'
    );
    if (result === null) {
      throw GroupCharacterMemoryError.internal('事务未产生结果');
    }
    const created: GroupCharacterMemory = result;
    Logger.info(LOG_TAG, 'createManualMemory: importance=' + created.importance
      + ' keywords=' + String(created.keywords.length)
      + ' id=' + shortId(created.id));
    return created;
  }

  /**
   * 创建交互记忆(G-MEMORY-AUTO-1A 自动总结批准保存入口)。
   *
   * 与 createManualMemory 区别:
   * - origin = Interaction(自动总结等交互来源)
   * - status = Active
   * - 必须提供 sourceMessageId / sourceSenderCharacterId / sourceType / sourceHash
   * - sourceSenderCharacterId 必须等于 characterId(来源角色匹配当前角色)
   * - 不校验 ChatParticipant 当前存在(角色可能已移出群聊,但历史消息仍可总结)
   * - 仍校验 GroupConversation 和 Character 存在
   *
   * 严格校验:
   * - title 非空且不超过长度上限
   * - content 非空且不超过长度上限
   * - importance 1-5
   * - sourceMessageId 非空
   * - sourceSenderCharacterId 非空且 === characterId
   * - sourceType 非空
   * - sourceHash 非空
   *
   * Interaction 记忆仍然只读:
   * - 不能通过 updateManualMemory 修改(拒绝非 Manual)
   * - 不能通过 deleteManualMemory 删除(拒绝非 Manual)
   * - 不能通过 setManualMemoryArchived 归档(拒绝非 Manual)
   * - 用户只能在批准前编辑 draft
   */
  async createInteractionMemory(input: CreateInteractionMemoryInput): Promise<GroupCharacterMemory> {
    validateTitle(input.title);
    validateContent(input.content);
    validateImportance(input.importance);
    if (input.sourceMessageId === '') {
      throw GroupCharacterMemoryError.internal('sourceMessageId empty');
    }
    if (input.sourceSenderCharacterId === '') {
      throw GroupCharacterMemoryError.internal('sourceSenderCharacterId empty');
    }
    if (input.sourceSenderCharacterId !== input.characterId) {
      throw GroupCharacterMemoryError.internal('sourceSenderCharacterId mismatch');
    }
    if (input.sourceType === '') {
      throw GroupCharacterMemoryError.internal('sourceType empty');
    }
    if (input.sourceHash === '') {
      throw GroupCharacterMemoryError.internal('sourceHash empty');
    }
    const keywords: string[] = resolveKeywords(input.keywords, undefined);

    const memoryId: string = GROUP_CHARACTER_MEMORY_ID_PREFIX + generateUuid();
    const now: number = nowMillis();

    let result: GroupCharacterMemory | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        // 1. 校验群聊存在
        const chat: Chat | null = await this.chatRepo.getByIdWithStore(store, input.groupConversationId);
        if (chat === null) {
          throw GroupCharacterMemoryError.groupNotFound();
        }
        // 2. 校验角色存在(角色卡缺失时拒绝创建,与 createManualMemory 一致)
        const character: Character | null =
          await this.characterRepo.getByIdWithStore(store, input.characterId);
        if (character === null) {
          throw GroupCharacterMemoryError.characterNotFound();
        }
        // 3. 不校验 participant 当前存在
        //    自动总结基于历史消息,角色可能已移出群聊但历史发言仍可总结

        const memory: GroupCharacterMemory = createGroupCharacterMemoryRecord({
          id: memoryId,
          groupConversationId: input.groupConversationId,
          characterId: input.characterId,
          origin: GroupCharacterMemoryOrigin.Interaction,
          status: GroupCharacterMemoryStatus.Active,
          title: normalizeTitle(input.title),
          content: normalizeContent(input.content),
          importance: input.importance,
          keywords: keywords,
          sourceMessageId: input.sourceMessageId,
          sourceRoundId: input.sourceRoundId,
          sourceSenderCharacterId: input.sourceSenderCharacterId,
          sourceType: input.sourceType,
          sourceHash: input.sourceHash,
          createdAt: now,
          updatedAt: now
        });
        await this.memoryRepo.insertWithStore(store, memory);
        result = memory;
      },
      'group_character_memory_create'
    );
    if (result === null) {
      throw GroupCharacterMemoryError.internal('事务未产生结果');
    }
    const created: GroupCharacterMemory = result;
    Logger.info(LOG_TAG, 'createInteractionMemory: importance=' + created.importance
      + ' keywords=' + String(created.keywords.length)
      + ' sourceType=' + created.sourceType
      + ' id=' + shortId(created.id));
    return created;
  }

  /**
   * 1C:原子原地更新滚动总结(保持 id + createdAt,不产生 Archived 膨胀)。
   *
   * 0 条 Active → 插入
   * 1 条 Active → 原地更新(同一 id + createdAt)
   * ≥2 条 Active → canonical 原地更新 + 归档其余
   *
   * @returns archivedCount(本次归档的旧 Active 数量)
   */
  async upsertRollingSelfSummaryAtomically(payload: UpsertRollingSummaryPayload): Promise<number> {
    let archivedCount: number = 0;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const chat: Chat | null = await this.chatRepo.getByIdWithStore(store, payload.groupConversationId);
        if (chat === null) {
          throw GroupCharacterMemoryError.groupNotFound();
        }
        const character: Character | null =
          await this.characterRepo.getByIdWithStore(store, payload.characterId);
        if (character === null) {
          throw GroupCharacterMemoryError.characterNotFound();
        }
        const result = await this.memoryRepo.upsertRollingSelfSummaryWithStore(store, payload);
        archivedCount = result.archivedCount;
      },
      'group_auto_summary_replace'
    );
    Logger.info(LOG_TAG, 'upsertRollingSelfSummaryAtomically: archived=' + String(archivedCount)
      + ' charShort=' + shortId(payload.characterId));
    return archivedCount;
  }

  /**
   * 1B 旧方法(已废弃,1C 改为内部调用 upsertRollingSelfSummaryAtomically)。
   */
  async replaceActiveSelfSummaryAtomically(newMemory: GroupCharacterMemory): Promise<number> {
    const payload: UpsertRollingSummaryPayload = {
      groupConversationId: newMemory.groupConversationId,
      characterId: newMemory.characterId,
      title: newMemory.title,
      content: newMemory.content,
      importance: newMemory.importance,
      keywords: newMemory.keywords,
      sourceMessageId: newMemory.sourceMessageId !== undefined ? newMemory.sourceMessageId : '',
      sourceRoundId: newMemory.sourceRoundId,
      sourceSenderCharacterId: newMemory.sourceSenderCharacterId !== undefined
        ? newMemory.sourceSenderCharacterId : '',
      sourceHash: newMemory.sourceHash !== undefined ? newMemory.sourceHash : '',
      updatedAt: newMemory.updatedAt
    };
    return await this.upsertRollingSelfSummaryAtomically(payload);
  }

  /**
   * 编辑手动记忆。
   * 允许修改:title / content / importance / keywords
   * 不得修改:groupConversationId / characterId / origin / source_* / createdAt
   * 如果目标记忆不是 Manual,拒绝修改(交互记忆由来源管理,留给 G-MEMORY-1B)。
   */
  async updateManualMemory(
    input: UpdateManualGroupMemoryInput
  ): Promise<GroupCharacterMemory> {
    validateTitle(input.title);
    validateContent(input.content);
    validateImportance(input.importance);
    const keywords: string[] = resolveKeywords(input.keywords, input.keywordsText);

    let result: GroupCharacterMemory | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: GroupCharacterMemory | null =
          await this.memoryRepo.getByIdWithStore(store, input.memoryId);
        if (existing === null) {
          throw GroupCharacterMemoryError.memoryNotFound();
        }
        if (existing.origin !== GroupCharacterMemoryOrigin.Manual) {
          throw GroupCharacterMemoryError.interactionMemoryReadOnly();
        }
        const updated: GroupCharacterMemory = createGroupCharacterMemoryRecord({
          id: existing.id,
          groupConversationId: existing.groupConversationId,
          characterId: existing.characterId,
          origin: existing.origin,
          status: existing.status,
          title: normalizeTitle(input.title),
          content: normalizeContent(input.content),
          importance: input.importance,
          keywords: keywords,
          sourceMessageId: existing.sourceMessageId,
          sourceRoundId: existing.sourceRoundId,
          sourceSenderCharacterId: existing.sourceSenderCharacterId,
          sourceType: existing.sourceType,
          sourceHash: existing.sourceHash,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.memoryRepo.updateWithStore(store, updated);
        result = updated;
      },
      'group_character_memory_update'
    );
    if (result === null) {
      throw GroupCharacterMemoryError.internal('事务未产生结果');
    }
    const updatedMemory: GroupCharacterMemory = result;
    Logger.info(LOG_TAG, 'updateManualMemory: id=' + shortId(updatedMemory.id)
      + ' importance=' + updatedMemory.importance
      + ' keywords=' + String(updatedMemory.keywords.length));
    return updatedMemory;
  }

  /**
   * 归档 / 恢复记忆。
   * 只允许 Manual 记忆执行 Active ↔ Archived 双向切换。
   * 不得把 Invalidated 恢复为 Active(交互记忆来源失效管理留给 G-MEMORY-1B)。
   * 也不允许把 Active/Archived 改为 Invalidated(Invalidated 仅由来源失效逻辑创建)。
   */
  async setManualMemoryArchived(
    memoryId: string,
    archived: boolean
  ): Promise<GroupCharacterMemory> {
    let result: GroupCharacterMemory | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: GroupCharacterMemory | null =
          await this.memoryRepo.getByIdWithStore(store, memoryId);
        if (existing === null) {
          throw GroupCharacterMemoryError.memoryNotFound();
        }
        if (existing.origin !== GroupCharacterMemoryOrigin.Manual) {
          throw GroupCharacterMemoryError.interactionMemoryReadOnly();
        }
        if (existing.status === GroupCharacterMemoryStatus.Invalidated) {
          throw GroupCharacterMemoryError.invalidStatusTransition('已失效记忆不能恢复为活跃');
        }
        const targetStatus: GroupCharacterMemoryStatus = archived
          ? GroupCharacterMemoryStatus.Archived : GroupCharacterMemoryStatus.Active;
        if (existing.status === targetStatus) {
          result = existing;
          return;
        }
        // 仅允许 Active ↔ Archived 切换
        if (existing.status === GroupCharacterMemoryStatus.Active
          && targetStatus === GroupCharacterMemoryStatus.Archived) {
          // OK
        } else if (existing.status === GroupCharacterMemoryStatus.Archived
          && targetStatus === GroupCharacterMemoryStatus.Active) {
          // OK
        } else {
          throw GroupCharacterMemoryError.invalidStatusTransition('仅允许活跃与已归档之间切换');
        }
        const updated: GroupCharacterMemory = createGroupCharacterMemoryRecord({
          id: existing.id,
          groupConversationId: existing.groupConversationId,
          characterId: existing.characterId,
          origin: existing.origin,
          status: targetStatus,
          title: existing.title,
          content: existing.content,
          importance: existing.importance,
          keywords: existing.keywords,
          sourceMessageId: existing.sourceMessageId,
          sourceRoundId: existing.sourceRoundId,
          sourceSenderCharacterId: existing.sourceSenderCharacterId,
          sourceType: existing.sourceType,
          sourceHash: existing.sourceHash,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.memoryRepo.updateWithStore(store, updated);
        result = updated;
      },
      'group_character_memory_archive'
    );
    if (result === null) {
      throw GroupCharacterMemoryError.internal('事务未产生结果');
    }
    const archivedMemory: GroupCharacterMemory = result;
    Logger.info(LOG_TAG, 'setManualMemoryArchived: id=' + shortId(archivedMemory.id)
      + ' archived=' + archived + ' status=' + archivedMemory.status);
    return archivedMemory;
  }

  /**
   * 永久删除手动记忆。
   * 只允许删除 Manual 记忆。
   * Interaction 记忆未来默认由来源有效性管理,不能通过本阶段 UI 删除。
   */
  async deleteManualMemory(memoryId: string): Promise<void> {
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: GroupCharacterMemory | null =
          await this.memoryRepo.getByIdWithStore(store, memoryId);
        if (existing === null) {
          throw GroupCharacterMemoryError.memoryNotFound();
        }
        if (existing.origin !== GroupCharacterMemoryOrigin.Manual) {
          throw GroupCharacterMemoryError.interactionMemoryReadOnly();
        }
        await this.memoryRepo.deleteByIdWithStore(store, memoryId);
      },
      'group_character_memory_delete'
    );
    Logger.info(LOG_TAG, 'deleteManualMemory: id=' + shortId(memoryId));
  }

  // ===== G-MEMORY-AUTO-1A-FIX-2: 自动总结记忆修改与归档 =====

  /**
   * 修改已批准的自动总结记忆(G-MEMORY-AUTO-1A-FIX-2)。
   *
   * 与 updateManualMemory 区别:
   * - 只允许 origin=Interaction && sourceType='self_summary_v1' && status!=Invalidated
   * - 只修改 title/content/importance/keywords
   * - 保留全部来源字段(sourceMessageId/sourceRoundId/sourceSenderCharacterId/sourceType/sourceHash)
   * - 保留 createdAt
   * - 更新 updatedAt
   *
   * 不允许:
   * - 修改来源字段
   * - 修改 origin
   * - 修改 status(用 setApprovedSelfSummaryArchived)
   * - 伪装成 Manual
   */
  async updateApprovedSelfSummaryMemory(
    input: UpdateApprovedSelfSummaryInput
  ): Promise<GroupCharacterMemory> {
    validateTitle(input.title);
    validateContent(input.content);
    validateImportance(input.importance);
    const keywords: string[] = resolveKeywords(input.keywords, undefined);

    let result: GroupCharacterMemory | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: GroupCharacterMemory | null =
          await this.memoryRepo.getByIdWithStore(store, input.memoryId);
        if (existing === null) {
          throw GroupCharacterMemoryError.memoryNotFound();
        }
        // 严格校验:必须是 Interaction + self_summary_v1 + 非 Invalidated
        if (existing.origin !== GroupCharacterMemoryOrigin.Interaction) {
          throw GroupCharacterMemoryError.interactionMemoryReadOnly();
        }
        if (existing.sourceType !== 'self_summary_v1') {
          throw GroupCharacterMemoryError.interactionMemoryReadOnly();
        }
        if (existing.status === GroupCharacterMemoryStatus.Invalidated) {
          throw GroupCharacterMemoryError.invalidStatusTransition('已失效记忆不能修改');
        }
        // 更新:只改 title/content/importance/keywords,保留来源字段
        const updated: GroupCharacterMemory = createGroupCharacterMemoryRecord({
          id: existing.id,
          groupConversationId: existing.groupConversationId,
          characterId: existing.characterId,
          origin: existing.origin,
          status: existing.status,
          title: normalizeTitle(input.title),
          content: normalizeContent(input.content),
          importance: input.importance,
          keywords: keywords,
          sourceMessageId: existing.sourceMessageId,
          sourceRoundId: existing.sourceRoundId,
          sourceSenderCharacterId: existing.sourceSenderCharacterId,
          sourceType: existing.sourceType,
          sourceHash: existing.sourceHash,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.memoryRepo.updateWithStore(store, updated);
        result = updated;
      },
      'group_character_memory_update'
    );
    if (result === null) {
      throw GroupCharacterMemoryError.internal('事务未产生结果');
    }
    const updatedMemory: GroupCharacterMemory = result;
    Logger.info(LOG_TAG, 'updateApprovedSelfSummaryMemory: id=' + shortId(updatedMemory.id)
      + ' importance=' + updatedMemory.importance
      + ' keywords=' + String(updatedMemory.keywords.length));
    return updatedMemory;
  }

  /**
   * 归档/恢复已批准的自动总结记忆(G-MEMORY-AUTO-1A-FIX-2)。
   *
   * 规则:
   * - 只允许 origin=Interaction && sourceType='self_summary_v1'
   * - 只允许 Active ↔ Archived 双向切换
   * - 不得把 Invalidated 恢复为 Active
   * - 不得把 Active/Archived 改为 Invalidated
   */
  async setApprovedSelfSummaryArchived(
    memoryId: string,
    archived: boolean
  ): Promise<GroupCharacterMemory> {
    let result: GroupCharacterMemory | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: GroupCharacterMemory | null =
          await this.memoryRepo.getByIdWithStore(store, memoryId);
        if (existing === null) {
          throw GroupCharacterMemoryError.memoryNotFound();
        }
        if (existing.origin !== GroupCharacterMemoryOrigin.Interaction) {
          throw GroupCharacterMemoryError.interactionMemoryReadOnly();
        }
        if (existing.sourceType !== 'self_summary_v1') {
          throw GroupCharacterMemoryError.interactionMemoryReadOnly();
        }
        if (existing.status === GroupCharacterMemoryStatus.Invalidated) {
          throw GroupCharacterMemoryError.invalidStatusTransition('已失效记忆不能恢复为活跃');
        }
        const targetStatus: GroupCharacterMemoryStatus = archived
          ? GroupCharacterMemoryStatus.Archived : GroupCharacterMemoryStatus.Active;
        if (existing.status === targetStatus) {
          result = existing;
          return;
        }
        // 仅允许 Active ↔ Archived 切换
        if (existing.status === GroupCharacterMemoryStatus.Active
          && targetStatus === GroupCharacterMemoryStatus.Archived) {
          // OK
        } else if (existing.status === GroupCharacterMemoryStatus.Archived
          && targetStatus === GroupCharacterMemoryStatus.Active) {
          // OK
        } else {
          throw GroupCharacterMemoryError.invalidStatusTransition('仅允许活跃与已归档之间切换');
        }
        const updated: GroupCharacterMemory = createGroupCharacterMemoryRecord({
          id: existing.id,
          groupConversationId: existing.groupConversationId,
          characterId: existing.characterId,
          origin: existing.origin,
          status: targetStatus,
          title: existing.title,
          content: existing.content,
          importance: existing.importance,
          keywords: existing.keywords,
          sourceMessageId: existing.sourceMessageId,
          sourceRoundId: existing.sourceRoundId,
          sourceSenderCharacterId: existing.sourceSenderCharacterId,
          sourceType: existing.sourceType,
          sourceHash: existing.sourceHash,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.memoryRepo.updateWithStore(store, updated);
        result = updated;
      },
      'group_character_memory_archive'
    );
    if (result === null) {
      throw GroupCharacterMemoryError.internal('事务未产生结果');
    }
    const archivedMemory: GroupCharacterMemory = result;
    Logger.info(LOG_TAG, 'setApprovedSelfSummaryArchived: id=' + shortId(archivedMemory.id)
      + ' archived=' + archived + ' status=' + archivedMemory.status);
    return archivedMemory;
  }

  /**
   * 删除已批准的自动总结记忆。
   *
   * 仅允许 origin=Interaction && sourceType='self_summary_v1' && status!=Invalidated。
   * Invalidated 记忆不可删除(保留失效痕迹,防止误删历史失效记录)。
   *
   * 删除后:
   * - 记忆记录从数据库移除
   * - 不影响增量总结进度(sourceMessageId 进度由 GroupCharacterSelfSummaryService 管理)
   * - 下一次总结不会重复生成已删除的内容(基于 sourceMessageId 增量)
   */
  async deleteApprovedSelfSummaryMemory(memoryId: string): Promise<void> {
    if (memoryId.length === 0) {
      throw GroupCharacterMemoryError.memoryNotFound();
    }
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: GroupCharacterMemory | null =
          await this.memoryRepo.getByIdWithStore(store, memoryId);
        if (existing === null) {
          throw GroupCharacterMemoryError.memoryNotFound();
        }
        // 严格校验:必须是 Interaction + self_summary_v1 + 非 Invalidated
        if (existing.origin !== GroupCharacterMemoryOrigin.Interaction) {
          throw GroupCharacterMemoryError.interactionMemoryReadOnly();
        }
        if (existing.sourceType !== 'self_summary_v1') {
          throw GroupCharacterMemoryError.interactionMemoryReadOnly();
        }
        if (existing.status === GroupCharacterMemoryStatus.Invalidated) {
          throw GroupCharacterMemoryError.invalidStatusTransition('已失效记忆不能删除');
        }
        await this.memoryRepo.deleteByIdWithStore(store, memoryId);
      },
      'group_character_memory_delete'
    );
    Logger.info(LOG_TAG, 'deleteApprovedSelfSummaryMemory: id=' + shortId(memoryId));
  }

  /**
   * 仅供 ChatPersistenceOperations.removeChatWithMessages 内部调用:
   * 在同一事务内删除该群聊全部角色记忆(级联清理)。
   * 不在此方法做事务包装(由调用方持有事务)。
   * 幂等:不存在返回 0,不抛错。
   */
  async deleteByGroupWithStore(
    store: relationalStore.RdbStore,
    groupConversationId: string
  ): Promise<void> {
    await this.memoryRepo.deleteByGroupWithStore(store, groupConversationId);
  }
}

/** 记忆筛选 */
export enum GroupCharacterMemoryFilter {
  All = 'all',
  Active = 'active',
  Archived = 'archived'
}

// ===== 内部校验辅助 =====

function validateTitle(title: string): void {
  const trimmed: string = title.trim();
  if (trimmed === '') {
    throw GroupCharacterMemoryError.invalidTitle();
  }
  if (trimmed.length > GROUP_CHARACTER_MEMORY_TITLE_MAX) {
    throw GroupCharacterMemoryError.invalidTitle();
  }
}

function validateContent(content: string): void {
  const trimmed: string = content.trim();
  if (trimmed === '') {
    throw GroupCharacterMemoryError.invalidContent();
  }
  if (trimmed.length > GROUP_CHARACTER_MEMORY_CONTENT_MAX) {
    throw GroupCharacterMemoryError.invalidContent();
  }
}

function validateImportance(importance: number): void {
  if (!isGroupCharacterMemoryImportance(importance)) {
    throw GroupCharacterMemoryError.invalidImportance();
  }
}

function normalizeTitle(title: string): string {
  return title.trim();
}

function normalizeContent(content: string): string {
  // 保留内部换行,仅去除首尾空白
  return content.trim();
}

function resolveKeywords(keywords?: string[], keywordsText?: string): string[] {
  if (keywords !== undefined) {
    return normalizeKeywords(keywords);
  }
  if (keywordsText !== undefined) {
    return parseKeywordsFromText(keywordsText);
  }
  return [];
}

function shortId(id: string): string {
  if (id.length <= 12) {
    return id;
  }
  return id.substring(0, 8) + '…';
}

/**
 * 将 Service 抛出的错误安全映射为用户可见 message。
 * 不暴露内部枚举原值 / 表名 / SQL / 完整 ID / 堆栈。
 */
export function mapGroupCharacterMemoryErrorToMessage(e: Error): string {
  if (isGroupCharacterMemoryError(e)) {
    return e.message;
  }
  if (e instanceof DatabaseError) {
    return '记忆数据操作失败,请重试';
  }
  return '记忆操作失败,请重试';
}

/**
 * 用于暴露 GroupCharacterMemoryErrorKind 给 UI 层做错误分支(可选)。
 * 当前阶段 UI 仅使用 message。
 */
export function classifyGroupCharacterMemoryError(e: Error): GroupCharacterMemoryErrorKind {
  if (isGroupCharacterMemoryError(e)) {
    return (e as GroupCharacterMemoryError).kind;
  }
  return GroupCharacterMemoryErrorKind.Internal;
}

/** 重要度默认值(供 UI 默认填充) */
export const DEFAULT_IMPORTANCE: number = GROUP_CHARACTER_MEMORY_IMPORTANCE_DEFAULT;
export const IMPORTANCE_MIN: number = GROUP_CHARACTER_MEMORY_IMPORTANCE_MIN;
export const IMPORTANCE_MAX: number = GROUP_CHARACTER_MEMORY_IMPORTANCE_MAX;
