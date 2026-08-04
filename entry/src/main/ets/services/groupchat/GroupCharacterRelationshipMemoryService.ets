/**
 * GroupCharacterRelationshipMemoryService 多人角色定向关系记忆业务服务
 *
 * 职责(G-MEMORY-AUTO-1B):
 * - 多人角色定向关系记忆的唯一正式写入口
 * - 批准候选(UPSERT):按 (groupConversationId, ownerCharacterId, targetType, targetId)
 *   唯一键写入,同一方向再次批准时 UPDATE,保留新 sourceMessageIds/sourceHash/updatedAt
 * - 修改已批准关系的可编辑字段(experience/attitude/relationship/importance/keywords)
 * - 归档 / 恢复
 * - 群聊删除级联清理(通过 ChatPersistenceOperations 同事务调用 deleteByGroupWithStore)
 *
 * 不负责(本阶段禁止):
 * - AI 自动总结 / Prompt 构建 / 模型调用(见 GroupCharacterRelationshipSummaryService)
 * - Prompt 注入 / GroupPromptAssembler 修改
 * - 轮次结束自动触发 / 后台队列
 * - 关系版本历史 / 关系图谱 / 数值系统
 *
 * 关系方向:
 * - A→B 与 B→A 完全隔离,各自一条记录(唯一键包含 owner + target)
 * - UPSERT 时只更新对应方向记录,不会交叉影响
 *
 * 成员移除:
 * - 不校验 ChatParticipant 当前存在(移除后关系记录保留)
 * - 只校验 GroupConversation 存在(群聊不存在不能保存关系)
 * - 只校验 owner Character 存在(角色卡不存在不能保存关系,但已存在的关系保留)
 *
 * 事务规则:
 * - 所有写入使用 DbHelper.runInTransaction
 * - 事务内只调用 Repository 的 *WithStore 方法
 *
 * 日志安全:
 * - 不记录完整摘要正文 / 完整 ID / SQL 参数
 * - 仅记录操作类型、targetType、importance、status、数量、截断短 ID
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { ChatRepository } from '../../repositories/ChatRepository';
import { CharacterRepository } from '../../repositories/CharacterRepository';
import { GroupCharacterRelationshipMemoryRepository } from '../../repositories/groupchat/GroupCharacterRelationshipMemoryRepository';
import { Chat } from '../../models/Chat';
import { Character } from '../../models/Character';
import {
  GroupCharacterRelationshipMemory,
  GroupRelationshipTargetType,
  GroupRelationshipMemoryStatus,
  UpdateRelationshipMemoryEditableFields,
  createGroupCharacterRelationshipMemoryRecord,
  isGroupRelationshipTargetType,
  isRelationshipImportance,
  normalizeKeywords,
  normalizeMessageIds,
  RELATIONSHIP_USER_TARGET_ID,
  GROUP_CHARACTER_RELATIONSHIP_MEMORY_ID_PREFIX,
  SOURCE_TYPE_RELATIONSHIP_SUMMARY_V1
} from '../../models/groupchat/GroupCharacterRelationshipMemory';
import {
  GroupCharacterMemoryError,
  GroupCharacterMemoryErrorKind
} from '../../models/groupchat/GroupCharacterMemoryError';
import { DatabaseError, DatabaseErrorType } from '../../models/DatabaseError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'GroupCharRelMemorySvc';

/**
 * 批准关系总结候选输入。
 * 由 ViewModel 在用户审核通过后构建,Service 调用 upsertWithStore 写入。
 */
export interface ApproveRelationshipSummaryInput {
  readonly groupConversationId: string;
  readonly ownerCharacterId: string;
  readonly targetType: GroupRelationshipTargetType;
  readonly targetId: string;
  readonly experienceSummary: string;
  readonly attitudeSummary: string;
  readonly relationshipSummary: string;
  readonly importance: number;
  readonly keywords: string[];
  readonly sourceMessageIds: string[];
  readonly sourceHash: string;
}

/** 批准结果 */
export interface ApproveRelationshipSummaryResult {
  readonly success: boolean;
  readonly memory?: GroupCharacterRelationshipMemory;
  readonly errorMessage: string;
}

/**
 * 修改已批准关系记忆的 Service 输入。
 * 包含 memoryId 和可编辑字段。
 */
export interface UpdateRelationshipMemoryServiceInput {
  readonly memoryId: string;
  readonly experienceSummary: string;
  readonly attitudeSummary: string;
  readonly relationshipSummary: string;
  readonly importance: number;
  readonly keywords: string[];
}

export class GroupCharacterRelationshipMemoryService {
  private readonly chatRepo: ChatRepository;
  private readonly characterRepo: CharacterRepository;
  private readonly relationshipRepo: GroupCharacterRelationshipMemoryRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    chatRepo: ChatRepository,
    characterRepo: CharacterRepository,
    relationshipRepo: GroupCharacterRelationshipMemoryRepository,
    dbHelper: DbHelper
  ) {
    this.chatRepo = chatRepo;
    this.characterRepo = characterRepo;
    this.relationshipRepo = relationshipRepo;
    this.dbHelper = dbHelper;
  }

  /** 获取单条关系记忆(只读,不走事务) */
  async getById(memoryId: string): Promise<GroupCharacterRelationshipMemory | null> {
    if (memoryId === '') {
      throw GroupCharacterMemoryError.memoryNotFound();
    }
    return await this.relationshipRepo.getById(memoryId);
  }

  /** 列出指定 owner 在某群聊的全部关系记忆(只读) */
  async listByOwner(
    groupConversationId: string,
    ownerCharacterId: string
  ): Promise<GroupCharacterRelationshipMemory[]> {
    if (groupConversationId === '') {
      throw GroupCharacterMemoryError.groupNotFound();
    }
    if (ownerCharacterId === '') {
      throw GroupCharacterMemoryError.characterNotFound();
    }
    return await this.relationshipRepo.listByOwner(groupConversationId, ownerCharacterId);
  }

  /** 列出指定 owner 在某群聊的 Active 关系记忆(只读) */
  async listActiveByOwner(
    groupConversationId: string,
    ownerCharacterId: string
  ): Promise<GroupCharacterRelationshipMemory[]> {
    if (groupConversationId === '') {
      throw GroupCharacterMemoryError.groupNotFound();
    }
    if (ownerCharacterId === '') {
      throw GroupCharacterMemoryError.characterNotFound();
    }
    return await this.relationshipRepo.listActiveByOwner(groupConversationId, ownerCharacterId);
  }

  /** 统计关系数量(只读) */
  async countByOwner(
    groupConversationId: string,
    ownerCharacterId: string
  ): Promise<number> {
    if (groupConversationId === '' || ownerCharacterId === '') {
      return 0;
    }
    const list: GroupCharacterRelationshipMemory[] =
      await this.relationshipRepo.listByOwner(groupConversationId, ownerCharacterId);
    return list.length;
  }

  /**
   * 批准关系总结候选(UPSERT)。
   *
   * 流程:
   * 1. 校验输入字段非空 / targetType 合法 / importance 合法 / sourceMessageIds 非空
   * 2. 事务内校验:GroupConversation 存在 → owner Character 存在
   * 3. 构建完整 GroupCharacterRelationshipMemory(状态=Active)
   * 4. UPSERT(按唯一键 INSERT or UPDATE)
   * 5. 返回写入后的对象
   *
   * 不校验 ChatParticipant 当前存在(成员移除后仍可批准历史总结)。
   * 不校验 target Character 存在(角色卡删除后仍可保存关系,但 UI 安全降级显示)。
   */
  async approveRelationshipSummary(
    input: ApproveRelationshipSummaryInput
  ): Promise<ApproveRelationshipSummaryResult> {
    // 1. 基础字段校验
    if (input.groupConversationId === '') {
      return { success: false, errorMessage: '群聊不存在' };
    }
    if (input.ownerCharacterId === '') {
      return { success: false, errorMessage: '角色不存在' };
    }
    if (!isGroupRelationshipTargetType(input.targetType)) {
      return { success: false, errorMessage: '关系对象类型不合法' };
    }
    if (input.targetId === '') {
      return { success: false, errorMessage: '关系对象不能为空' };
    }
    if (input.targetType === GroupRelationshipTargetType.Character
      && input.targetId === input.ownerCharacterId) {
      return { success: false, errorMessage: '不能对自己建立关系' };
    }
    if (input.sourceMessageIds.length === 0) {
      return { success: false, errorMessage: '来源消息不能为空' };
    }
    if (input.sourceHash === '') {
      return { success: false, errorMessage: '来源哈希缺失' };
    }
    if (!isRelationshipImportance(input.importance)) {
      return { success: false, errorMessage: '重要度必须在 1 到 5 之间' };
    }

    const experienceTrimmed: string = input.experienceSummary.trim();
    const attitudeTrimmed: string = input.attitudeSummary.trim();
    const relationshipTrimmed: string = input.relationshipSummary.trim();
    if (experienceTrimmed === '' && attitudeTrimmed === '' && relationshipTrimmed === '') {
      return { success: false, errorMessage: '至少填写一项摘要内容' };
    }

    const memoryId: string = GROUP_CHARACTER_RELATIONSHIP_MEMORY_ID_PREFIX + generateUuid();
    const now: number = nowMillis();

    let memory: GroupCharacterRelationshipMemory;
    try {
      memory = createGroupCharacterRelationshipMemoryRecord({
        id: memoryId,
        groupConversationId: input.groupConversationId,
        ownerCharacterId: input.ownerCharacterId,
        targetType: input.targetType,
        targetId: input.targetId,
        experienceSummary: experienceTrimmed,
        attitudeSummary: attitudeTrimmed,
        relationshipSummary: relationshipTrimmed,
        importance: input.importance,
        keywords: input.keywords,
        sourceMessageIds: input.sourceMessageIds,
        sourceHash: input.sourceHash,
        sourceType: SOURCE_TYPE_RELATIONSHIP_SUMMARY_V1,
        status: GroupRelationshipMemoryStatus.Active,
        createdAt: now,
        updatedAt: now
      });
    } catch (e) {
      Logger.warn(LOG_TAG, 'approve build record failed: ' + safeErrorCategory(e));
      return { success: false, errorMessage: '关系数据不合法' };
    }

    // 2. 事务内校验 + UPSERT
    let result: GroupCharacterRelationshipMemory | null = null;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          // 校验群聊存在
          const chat: Chat | null = await this.chatRepo.getByIdWithStore(
            store, input.groupConversationId
          );
          if (chat === null) {
            throw GroupCharacterMemoryError.groupNotFound();
          }
          // 校验 owner 角色卡存在
          const ownerChar: Character | null = await this.characterRepo.getByIdWithStore(
            store, input.ownerCharacterId
          );
          if (ownerChar === null) {
            throw GroupCharacterMemoryError.characterNotFound();
          }
          // UPSERT(按唯一键)
          await this.relationshipRepo.upsertWithStore(store, memory);
          // 读取写入后的对象(可能是新建也可能是更新,统一以 UPSERT 后的 id 读回)
          // 注意:如果是 UPDATE 情况,upsertWithStore 已使用 existing.id,我们的 memory.id
          // 是新 uuid 但被忽略。需要按唯一键读回实际对象。
          const actual: GroupCharacterRelationshipMemory | null =
            await this.relationshipRepo.getByOwnerAndTargetWithStore(
              store,
              input.groupConversationId,
              input.ownerCharacterId,
              input.targetType,
              input.targetId
            );
          if (actual === null) {
            throw GroupCharacterMemoryError.internal('upsert result not found');
          }
          result = actual;
        }
      );
      if (result === null) {
        return { success: false, errorMessage: '保存失败,未获取到结果' };
      }
      Logger.info(LOG_TAG, 'approve ok: ownerShort=' + shortId(input.ownerCharacterId)
        + ' targetType=' + input.targetType
        + ' targetShort=' + shortId(input.targetId));
      return { success: true, memory: result, errorMessage: '' };
    } catch (e) {
      if (e instanceof GroupCharacterMemoryError) {
        const err: GroupCharacterMemoryError = e as GroupCharacterMemoryError;
        return { success: false, errorMessage: err.message };
      }
      Logger.warn(LOG_TAG, 'approve failed: ' + safeErrorCategory(e));
      return { success: false, errorMessage: '保存失败,请重试' };
    }
  }

  /**
   * 修改已批准关系的可编辑字段。
   * - 仅修改 experience/attitude/relationship/importance/keywords
   * - 不修改 groupConversationId/ownerCharacterId/targetType/targetId
   * - 不修改 sourceMessageIds/sourceHash/sourceType/createdAt
   * - updatedAt 更新为当前时间
   * - 失败时抛 GroupCharacterMemoryError,ViewModel 应保留用户编辑内容不关闭覆盖层
   */
  async updateRelationshipMemory(
    input: UpdateRelationshipMemoryServiceInput
  ): Promise<GroupCharacterRelationshipMemory> {
    if (input.memoryId === '') {
      throw GroupCharacterMemoryError.memoryNotFound();
    }
    if (!isRelationshipImportance(input.importance)) {
      throw GroupCharacterMemoryError.invalidImportance();
    }
    const experienceTrimmed: string = input.experienceSummary.trim();
    const attitudeTrimmed: string = input.attitudeSummary.trim();
    const relationshipTrimmed: string = input.relationshipSummary.trim();
    if (experienceTrimmed === '' && attitudeTrimmed === '' && relationshipTrimmed === '') {
      throw GroupCharacterMemoryError.invalidContent();
    }
    const keywords: string[] = normalizeKeywords(input.keywords);
    const now: number = nowMillis();

    let updated: GroupCharacterRelationshipMemory | null = null;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          updated = await this.relationshipRepo.updateEditableFieldsWithStore(
            store,
            input.memoryId,
            experienceTrimmed,
            attitudeTrimmed,
            relationshipTrimmed,
            input.importance,
            keywords,
            now
          );
        }
      );
      if (updated === null) {
        throw GroupCharacterMemoryError.internal('update result not found after transaction');
      }
      Logger.info(LOG_TAG, 'update ok: idShort=' + shortId(input.memoryId));
      return updated;
    } catch (e) {
      if (e instanceof DatabaseError) {
        if ((e as DatabaseError).type === DatabaseErrorType.NotFound) {
          throw GroupCharacterMemoryError.memoryNotFound();
        }
        throw GroupCharacterMemoryError.databaseFailure('update failed');
      }
      if (e instanceof GroupCharacterMemoryError) {
        throw e;
      }
      Logger.warn(LOG_TAG, 'update failed: ' + safeErrorCategory(e));
      throw GroupCharacterMemoryError.internal('update failed');
    }
  }

  /**
   * 归档 / 恢复关系记忆。
   * archived=true → Archived;archived=false → Active
   * Invalidated 状态的记忆不允许通过此方法恢复(安全处理)。
   */
  async setRelationshipArchived(
    memoryId: string,
    archived: boolean
  ): Promise<GroupCharacterRelationshipMemory> {
    if (memoryId === '') {
      throw GroupCharacterMemoryError.memoryNotFound();
    }
    const now: number = nowMillis();
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          // 先读取,避免把 Invalidated 改回 Active
          const existing: GroupCharacterRelationshipMemory | null =
            await this.relationshipRepo.getByIdWithStore(store, memoryId);
          if (existing === null) {
            throw GroupCharacterMemoryError.memoryNotFound();
          }
          if (!archived && existing.status === GroupRelationshipMemoryStatus.Invalidated) {
            throw GroupCharacterMemoryError.invalidStatusTransition(
              '已失效的关系不能直接恢复,请编辑后重新激活'
            );
          }
          await this.relationshipRepo.setArchivedWithStore(store, memoryId, archived, now);
        }
      );
      const result: GroupCharacterRelationshipMemory | null =
        await this.relationshipRepo.getById(memoryId);
      if (result === null) {
        throw GroupCharacterMemoryError.memoryNotFound();
      }
      Logger.info(LOG_TAG, 'setArchived ok: idShort=' + shortId(memoryId)
        + ' archived=' + archived);
      return result;
    } catch (e) {
      if (e instanceof GroupCharacterMemoryError) {
        throw e;
      }
      if (e instanceof DatabaseError) {
        if ((e as DatabaseError).type === DatabaseErrorType.NotFound) {
          throw GroupCharacterMemoryError.memoryNotFound();
        }
        throw GroupCharacterMemoryError.databaseFailure('setArchived failed');
      }
      Logger.warn(LOG_TAG, 'setArchived failed: ' + safeErrorCategory(e));
      throw GroupCharacterMemoryError.internal('setArchived failed');
    }
  }
}

// ===== 私有辅助 =====

function safeErrorCategory(e: Object): string {
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
