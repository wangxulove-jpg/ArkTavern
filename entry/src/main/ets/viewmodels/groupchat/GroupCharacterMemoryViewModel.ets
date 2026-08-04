/**
 * GroupCharacterMemoryViewModel 多人聊天角色记忆页 ViewModel(G-MEMORY-1A)
 *
 * 职责:
 * - 根据 groupConversationId + characterId 加载群聊标题、角色信息、成员状态、记忆列表
 * - 创建 / 编辑 / 归档 / 恢复 / 删除 手动记忆(调用 GroupCharacterMemoryService)
 * - 处理页面切换(expectedGroupConversationId + expectedCharacterId + loadOperationId)和销毁(disposed)
 * - 写操作防重复(operationId + isSaving + isDeleting)
 * - 角色名称解析:Character 存在→Character.name;缺失→"角色已删除"
 * - 成员状态判定:查询当前群聊参与者,判断角色是 当前成员/已停用/已移出/角色卡缺失
 *
 * 所有权语义:
 * - 记忆严格属于 (groupConversationId, characterId) 二元组
 * - 角色被移出群聊时记忆保留,可在本页面继续查看与编辑现有记忆
 * - 但已移出成员不允许新增记忆(canCreateMemory=false),Service 会拒绝并返回 ParticipantNotFound
 * - 角色卡缺失时记忆仍保留,UI 安全降级显示"角色已删除"
 *
 * 不负责(本阶段禁止):
 * - AI 自动提取记忆 / Prompt 注入 / 检索排序
 * - 直接调用 Repository 的写入方法(只走 Service)
 * - 交互记忆自动失效管理(留给 G-MEMORY-1B / G-MEMORY-1C)
 *
 * 依赖方向:
 * Page → ViewModel → GroupConversationPersistenceService(只读) /
 *                    CharacterService(只读 getById) /
 *                    GroupCharacterMemoryService(写入)
 *
 * 日志安全:不记录完整记忆正文 / 完整 ID / SQL,仅记录操作类型、origin、importance、
 * status、数量、operationId、截断短 ID。
 */

import { GroupConversationPersistenceService } from '../../services/groupchat/GroupConversationPersistenceService';
import { CharacterService } from '../../services/CharacterService';
import {
  GroupCharacterMemoryService,
  GroupCharacterMemoryFilter,
  CreateManualGroupMemoryInput,
  UpdateManualGroupMemoryInput,
  UpdateApprovedSelfSummaryInput,
  mapGroupCharacterMemoryErrorToMessage,
  DEFAULT_IMPORTANCE,
  IMPORTANCE_MIN,
  IMPORTANCE_MAX
} from '../../services/groupchat/GroupCharacterMemoryService';
import {
  GroupCharacterSelfSummaryService,
  SelfSummaryDraft,
  SelfSummaryResult,
  SelfSummaryApproveResult
} from '../../services/groupchat/GroupCharacterSelfSummaryService';
import { Logger } from '../../utils/Logger';
import { Chat } from '../../models/Chat';
import { ChatParticipant } from '../../models/ChatParticipant';
import { Character } from '../../models/Character';
import {
  GroupCharacterMemory,
  GroupCharacterMemoryOrigin,
  GroupCharacterMemoryStatus,
  GROUP_CHARACTER_MEMORY_TITLE_MAX,
  GROUP_CHARACTER_MEMORY_CONTENT_MAX,
  parseKeywordsFromText
} from '../../models/groupchat/GroupCharacterMemory';
import { DatabaseError } from '../../models/DatabaseError';
import { DELETED_CHARACTER_NAME } from './GroupChatUiModels';

const LOG_TAG: string = 'GroupCharacterMemoryViewModel';

/** 记忆页加载状态 */
export enum GroupCharacterMemoryLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

/** 记忆筛选 */
export enum GroupCharacterMemoryListFilter {
  All = 'all',
  Active = 'active',
  Archived = 'archived'
}

/**
 * 角色在当前群聊中的成员状态。
 * 用于头部显示和判断是否允许新增记忆。
 */
export enum GroupCharacterMemberStatus {
  /** 当前成员(participant 存在且 isEnabled=true) */
  ActiveMember = 'active_member',
  /** 已停用成员(participant 存在但 isEnabled=false) */
  DisabledMember = 'disabled_member',
  /** 已移出群聊(participant 不存在,但记忆仍保留) */
  RemovedMember = 'removed_member',
  /** 角色卡缺失(Character 不存在) */
  CharacterMissing = 'character_missing'
}

/** 角色头部 UI 模型 */
export interface GroupCharacterMemoryHeaderUiModel {
  readonly groupConversationId: string;
  readonly groupTitle: string;
  readonly characterId: string;
  readonly displayName: string;
  readonly fallbackName: string;
  readonly avatarUri: string;
  readonly memberStatus: GroupCharacterMemberStatus;
  readonly memberStatusLabel: string;
  readonly memoryCount: number;
  /** 是否允许新增手动记忆(仅当前成员允许) */
  readonly canCreateMemory: boolean;
}

/** 记忆卡片 UI 模型(已本地化来源/状态) */
export interface GroupCharacterMemoryItemUiModel {
  readonly id: string;
  readonly origin: GroupCharacterMemoryOrigin;
  readonly originLabel: string;
  readonly status: GroupCharacterMemoryStatus;
  readonly statusLabel: string;
  readonly title: string;
  readonly content: string;
  readonly contentPreview: string;
  readonly importance: number;
  readonly keywords: string[];
  readonly keywordsText: string;
  readonly sourceSummary: string;
  readonly isInteraction: boolean;
  readonly isInvalidated: boolean;
  /** G-MEMORY-AUTO-1A-FIX-2: 是否为自动总结记忆(sourceType='self_summary_v1') */
  readonly isSelfSummary: boolean;
  /** 是否可编辑(Manual 或 self_summary_v1 且非 Invalidated) */
  readonly canEdit: boolean;
  /** 是否可归档(Manual 或 self_summary_v1 且非 Invalidated) */
  readonly canArchive: boolean;
  /** 是否可删除(仅 Manual) */
  readonly canDelete: boolean;
  readonly createdAt: number;
  readonly createdAtLabel: string;
  readonly updatedAt: number;
  readonly updatedAtLabel: string;
}

/** 记忆页 UI 快照 */
export interface GroupCharacterMemorySnapshotUiModel {
  readonly header: GroupCharacterMemoryHeaderUiModel;
  readonly memories: GroupCharacterMemoryItemUiModel[];
}

/** 创建记忆表单输入 */
export interface CreateGroupMemoryFormInput {
  readonly title: string;
  readonly content: string;
  readonly importance: number;
  readonly keywordsText: string;
}

/** 编辑记忆表单输入 */
export interface UpdateGroupMemoryFormInput {
  readonly memoryId: string;
  readonly title: string;
  readonly content: string;
  readonly importance: number;
  readonly keywordsText: string;
}

/** 写操作结果 */
export interface GroupMemorySaveResult {
  readonly success: boolean;
  readonly errorMessage: string;
}

export class GroupCharacterMemoryViewModel {
  private readonly groupPersistenceService: GroupConversationPersistenceService;
  private readonly characterService: CharacterService;
  private readonly memoryService: GroupCharacterMemoryService;
  private readonly summaryService: GroupCharacterSelfSummaryService | null;

  state: GroupCharacterMemoryLoadState = GroupCharacterMemoryLoadState.Loading;
  errorMessage: string = '';
  snapshot: GroupCharacterMemorySnapshotUiModel | null = null;

  private expectedGroupConversationId: string = '';
  private expectedCharacterId: string = '';
  private loadOperationId: number = 0;
  private operationId: number = 0;
  private disposed: boolean = false;
  isSaving: boolean = false;
  isDeleting: boolean = false;
  readonly instanceShortId: string;

  // G-MEMORY-AUTO-1A 自动总结状态
  // - isSummarizing: prepare/regenerate 进行中(按钮禁用)
  // - isApprovingSummary: 批准保存进行中(按钮禁用,审核窗口保持打开)
  // - summaryDraft: 当前审核 draft(null 表示无审核窗口)
  // - summaryError: 总结相关错误(非空时页面 actionError 显示)
  // - summaryOperationId: 防止迟到结果覆盖另一个角色页面
  isSummarizing: boolean = false;
  isApprovingSummary: boolean = false;
  summaryDraft: SelfSummaryDraft | null = null;
  summaryError: string = '';
  private summaryOperationId: number = 0;

  constructor(
    groupPersistenceService: GroupConversationPersistenceService,
    characterService: CharacterService,
    memoryService: GroupCharacterMemoryService,
    summaryService: GroupCharacterSelfSummaryService | null = null
  ) {
    this.groupPersistenceService = groupPersistenceService;
    this.characterService = characterService;
    this.memoryService = memoryService;
    this.summaryService = summaryService;
    this.instanceShortId = GroupCharacterMemoryViewModel.generateShortId();
  }

  private static generateShortId(): string {
    const ts: number = Date.now();
    const tail: number = Math.floor(ts % 0xffff);
    return tail.toString(16).padStart(4, '0');
  }

  activate(): void {
    if (this.disposed) {
      this.disposed = false;
      Logger.info(LOG_TAG, 'activate: vmInstance=' + this.instanceShortId);
    }
  }

  dispose(): void {
    this.disposed = true;
    // 使进行中的总结结果失效,迟到结果不覆盖另一个角色页面
    this.summaryOperationId = this.summaryOperationId + 1;
    this.isSummarizing = false;
    this.isApprovingSummary = false;
    this.summaryDraft = null;
    this.summaryError = '';
    Logger.info(LOG_TAG, 'dispose: vmInstance=' + this.instanceShortId);
  }

  setTarget(groupConversationId: string, characterId: string): void {
    if (this.expectedGroupConversationId !== groupConversationId
      || this.expectedCharacterId !== characterId) {
      this.expectedGroupConversationId = groupConversationId;
      this.expectedCharacterId = characterId;
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  expectedGroupConversationIdOfPage(): string {
    return this.expectedGroupConversationId;
  }

  expectedCharacterIdOfPage(): string {
    return this.expectedCharacterId;
  }

  /**
   * 加载记忆页快照。每次 onPageShow 和写操作完成后调用。
   */
  async loadSnapshot(
    groupConversationId: string,
    characterId: string,
    filter: GroupCharacterMemoryListFilter
  ): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'loadSnapshot skipped: disposed vmInstance=' + this.instanceShortId);
      return;
    }
    this.expectedGroupConversationId = groupConversationId;
    this.expectedCharacterId = characterId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;

    this.state = GroupCharacterMemoryLoadState.Loading;
    this.errorMessage = '';

    try {
      // 1. 校验群聊存在
      const chat: Chat | null =
        await this.groupPersistenceService.getGroupConversation(groupConversationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (chat === null) {
        this.state = GroupCharacterMemoryLoadState.NotFound;
        return;
      }
      const groupTitle: string = chat.title;

      // 2. 解析角色卡
      let character: Character | null = null;
      if (characterId.length > 0) {
        try {
          character = await this.characterService.getById(characterId);
        } catch (e) {
          Logger.warn(LOG_TAG, 'characterService.getById failed: ' + this.safeErrorCategory(e));
          character = null;
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const characterMissing: boolean = character === null;
      const displayName: string = !characterMissing && character !== null
        ? character.name : DELETED_CHARACTER_NAME;
      const avatarUri: string = !characterMissing && character !== null
        ? character.avatarUri : '';

      // 3. 查询当前群聊参与者,判定成员状态
      let participants: ChatParticipant[] = [];
      try {
        participants = await this.groupPersistenceService.getParticipants(groupConversationId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'getParticipants failed: ' + this.safeErrorCategory(e));
        participants = [];
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const memberStatus: GroupCharacterMemberStatus = this.resolveMemberStatus(
        characterId, characterMissing, participants
      );
      const canCreateMemory: boolean = memberStatus === GroupCharacterMemberStatus.ActiveMember;
      Logger.info(LOG_TAG, 'loadSnapshot: characterId=' + characterId
        + ' characterMissing=' + characterMissing
        + ' participants.length=' + participants.length
        + ' memberStatus=' + memberStatus
        + ' canCreateMemory=' + canCreateMemory);

      // 4. 加载记忆列表
      const memoryFilter: GroupCharacterMemoryFilter = this.toServiceFilter(filter);
      let memories: GroupCharacterMemory[] = [];
      try {
        memories = await this.memoryService.listByCharacter(
          groupConversationId, characterId, memoryFilter
        );
      } catch (e) {
        Logger.warn(LOG_TAG, 'listByCharacter failed: ' + this.safeErrorCategory(e));
        memories = [];
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 5. 记忆总数(不受筛选影响)
      let memoryCount: number = 0;
      try {
        memoryCount = await this.memoryService.countByCharacter(groupConversationId, characterId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'countByCharacter failed: ' + this.safeErrorCategory(e));
        memoryCount = memories.length;
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 6. 构建 UI 模型
      const header: GroupCharacterMemoryHeaderUiModel = {
        groupConversationId: groupConversationId,
        groupTitle: groupTitle,
        characterId: characterId,
        displayName: displayName,
        fallbackName: DELETED_CHARACTER_NAME,
        avatarUri: avatarUri,
        memberStatus: memberStatus,
        memberStatusLabel: this.memberStatusLabel(memberStatus),
        memoryCount: memoryCount,
        canCreateMemory: canCreateMemory
      };

      const memoryItems: GroupCharacterMemoryItemUiModel[] =
        new Array<GroupCharacterMemoryItemUiModel>(memories.length);
      for (let i = 0; i < memories.length; i++) {
        memoryItems[i] = this.buildMemoryItem(memories[i]);
      }

      const snapshot: GroupCharacterMemorySnapshotUiModel = {
        header: header,
        memories: memoryItems
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.snapshot = snapshot;
      this.state = GroupCharacterMemoryLoadState.Ready;
      Logger.info(LOG_TAG, 'loadSnapshot done: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', state=ready, memoryCount=' + memoryItems.length.toString()
        + ', characterShortId=' + this.shortId(characterId));
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', ' + this.safeErrorCategory(e)
        + ', characterShortId=' + this.shortId(characterId));
      this.errorMessage = '记忆数据加载失败,请重试';
      this.state = GroupCharacterMemoryLoadState.Error;
    }
  }

  /** 创建手动记忆 */
  async createMemory(input: CreateGroupMemoryFormInput): Promise<GroupMemorySaveResult> {
    if (this.isSaving) {
      Logger.warn(LOG_TAG, 'createMemory skipped: isSaving');
      return { success: false, errorMessage: '正在处理,请稍候' } as GroupMemorySaveResult;
    }
    if (this.expectedGroupConversationId.length === 0 || this.expectedCharacterId.length === 0) {
      return { success: false, errorMessage: '目标未加载' } as GroupMemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const serviceInput: CreateManualGroupMemoryInput = {
        groupConversationId: this.expectedGroupConversationId,
        characterId: this.expectedCharacterId,
        title: input.title,
        content: input.content,
        importance: input.importance,
        keywordsText: input.keywordsText
      };
      await this.memoryService.createManualMemory(serviceInput);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      Logger.info(LOG_TAG, 'createMemory ok: importance=' + input.importance.toString()
        + ', characterShortId=' + this.shortId(this.expectedCharacterId));
      return { success: true, errorMessage: '' } as GroupMemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'createMemory failed: ' + this.safeErrorCategory(e)
        + ', importance=' + input.importance.toString()
        + ', characterShortId=' + this.shortId(this.expectedCharacterId));
      return { success: false, errorMessage: msg } as GroupMemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /** 编辑手动记忆 */
  async updateMemory(input: UpdateGroupMemoryFormInput): Promise<GroupMemorySaveResult> {
    if (this.isSaving) {
      Logger.warn(LOG_TAG, 'updateMemory skipped: isSaving');
      return { success: false, errorMessage: '正在处理,请稍候' } as GroupMemorySaveResult;
    }
    if (input.memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as GroupMemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const serviceInput: UpdateManualGroupMemoryInput = {
        memoryId: input.memoryId,
        title: input.title,
        content: input.content,
        importance: input.importance,
        keywordsText: input.keywordsText
      };
      await this.memoryService.updateManualMemory(serviceInput);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      Logger.info(LOG_TAG, 'updateMemory ok: importance=' + input.importance.toString()
        + ', memoryShortId=' + this.shortId(input.memoryId));
      return { success: true, errorMessage: '' } as GroupMemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'updateMemory failed: ' + this.safeErrorCategory(e)
        + ', importance=' + input.importance.toString()
        + ', memoryShortId=' + this.shortId(input.memoryId));
      return { success: false, errorMessage: msg } as GroupMemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /** 归档 / 恢复记忆 */
  async setMemoryArchived(
    memoryId: string,
    archived: boolean
  ): Promise<GroupMemorySaveResult> {
    if (this.isSaving || this.isDeleting) {
      Logger.warn(LOG_TAG, 'setMemoryArchived skipped: busy');
      return { success: false, errorMessage: '正在处理,请稍候' } as GroupMemorySaveResult;
    }
    if (memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as GroupMemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.memoryService.setManualMemoryArchived(memoryId, archived);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      Logger.info(LOG_TAG, 'setMemoryArchived ok: archived=' + archived.toString()
        + ', memoryShortId=' + this.shortId(memoryId));
      return { success: true, errorMessage: '' } as GroupMemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'setMemoryArchived failed: ' + this.safeErrorCategory(e)
        + ', memoryShortId=' + this.shortId(memoryId));
      return { success: false, errorMessage: msg } as GroupMemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /**
   * 修改已批准的自动总结记忆(G-MEMORY-AUTO-1A-FIX-2)。
   *
   * 仅允许 origin=Interaction && sourceType='self_summary_v1' 且非 Invalidated。
   * 修改字段:title / content / importance / keywords
   * 保留字段:groupConversationId / characterId / origin / source_* / createdAt
   *
   * 输入复用 UpdateGroupMemoryFormInput(与手动编辑表单结构一致),
   * 内部转换为 UpdateApprovedSelfSummaryInput 调用 Service。
   */
  async updateApprovedSelfSummary(
    input: UpdateGroupMemoryFormInput
  ): Promise<GroupMemorySaveResult> {
    if (this.isSaving) {
      Logger.warn(LOG_TAG, 'updateApprovedSelfSummary skipped: isSaving');
      return { success: false, errorMessage: '正在处理,请稍候' } as GroupMemorySaveResult;
    }
    if (input.memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as GroupMemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const keywords: string[] = parseKeywordsFromText(input.keywordsText);
      const serviceInput: UpdateApprovedSelfSummaryInput = {
        memoryId: input.memoryId,
        title: input.title,
        content: input.content,
        importance: input.importance,
        keywords: keywords
      };
      await this.memoryService.updateApprovedSelfSummaryMemory(serviceInput);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      Logger.info(LOG_TAG, 'updateApprovedSelfSummary ok: importance=' + input.importance.toString()
        + ', memoryShortId=' + this.shortId(input.memoryId));
      return { success: true, errorMessage: '' } as GroupMemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'updateApprovedSelfSummary failed: ' + this.safeErrorCategory(e)
        + ', importance=' + input.importance.toString()
        + ', memoryShortId=' + this.shortId(input.memoryId));
      return { success: false, errorMessage: msg } as GroupMemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /**
   * 归档 / 恢复已批准的自动总结记忆(G-MEMORY-AUTO-1A-FIX-2)。
   *
   * 仅允许 origin=Interaction && sourceType='self_summary_v1'。
   * 仅允许 Active ↔ Archived 双向切换,Invalidated 不可恢复。
   */
  async setApprovedSelfSummaryArchived(
    memoryId: string,
    archived: boolean
  ): Promise<GroupMemorySaveResult> {
    if (this.isSaving || this.isDeleting) {
      Logger.warn(LOG_TAG, 'setApprovedSelfSummaryArchived skipped: busy');
      return { success: false, errorMessage: '正在处理,请稍候' } as GroupMemorySaveResult;
    }
    if (memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as GroupMemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.memoryService.setApprovedSelfSummaryArchived(memoryId, archived);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      Logger.info(LOG_TAG, 'setApprovedSelfSummaryArchived ok: archived=' + archived.toString()
        + ', memoryShortId=' + this.shortId(memoryId));
      return { success: true, errorMessage: '' } as GroupMemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'setApprovedSelfSummaryArchived failed: ' + this.safeErrorCategory(e)
        + ', memoryShortId=' + this.shortId(memoryId));
      return { success: false, errorMessage: msg } as GroupMemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /** 永久删除记忆 */
  async deleteMemory(memoryId: string): Promise<GroupMemorySaveResult> {
    if (this.isDeleting) {
      Logger.warn(LOG_TAG, 'deleteMemory skipped: isDeleting');
      return { success: false, errorMessage: '正在处理,请稍候' } as GroupMemorySaveResult;
    }
    if (memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as GroupMemorySaveResult;
    }
    this.isDeleting = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.memoryService.deleteManualMemory(memoryId);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      Logger.info(LOG_TAG, 'deleteMemory ok: memoryShortId=' + this.shortId(memoryId));
      return { success: true, errorMessage: '' } as GroupMemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'deleteMemory failed: ' + this.safeErrorCategory(e)
        + ', memoryShortId=' + this.shortId(memoryId));
      return { success: false, errorMessage: msg } as GroupMemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isDeleting = false;
      }
    }
  }

  /**
   * 删除已批准的自动总结记忆。
   * 仅允许 origin=Interaction && sourceType='self_summary_v1' && status!=Invalidated。
   * Invalidated 记忆不可删除。
   */
  async deleteApprovedSelfSummary(memoryId: string): Promise<GroupMemorySaveResult> {
    if (this.isDeleting) {
      Logger.warn(LOG_TAG, 'deleteApprovedSelfSummary skipped: isDeleting');
      return { success: false, errorMessage: '正在处理,请稍候' } as GroupMemorySaveResult;
    }
    if (memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as GroupMemorySaveResult;
    }
    this.isDeleting = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.memoryService.deleteApprovedSelfSummaryMemory(memoryId);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      Logger.info(LOG_TAG, 'deleteApprovedSelfSummary ok: memoryShortId=' + this.shortId(memoryId));
      return { success: true, errorMessage: '' } as GroupMemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'deleteApprovedSelfSummary failed: ' + this.safeErrorCategory(e)
        + ', memoryShortId=' + this.shortId(memoryId));
      return { success: false, errorMessage: msg } as GroupMemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isDeleting = false;
      }
    }
  }

  // ===== G-MEMORY-AUTO-1A 自动总结 =====

  /**
   * 准备自动总结 draft(用户点击"自动总结"按钮)。
   *
   * 流程:
   * 1. 校验 summaryService / 目标加载
   * 2. 防重复点击(isSummarizing)
   * 3. 从 snapshot 解析角色名称和群聊标题(供 Prompt 使用)
   * 4. 调用 summaryService.prepareSelfSummary
   * 5. 成功:写入 summaryDraft,页面打开审核窗口
   * 6. 失败:写入 summaryError,不打开审核窗口
   *
   * 防迟到:summaryOperationId 在 dispose / 角色切换 / 新调用时递增。
   */
  async prepareSelfSummary(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.isSummarizing || this.isApprovingSummary) {
      Logger.warn(LOG_TAG, 'prepareSelfSummary skipped: busy');
      return;
    }
    if (this.summaryService === null) {
      this.summaryError = '总结服务未初始化';
      return;
    }
    if (this.expectedGroupConversationId.length === 0
      || this.expectedCharacterId.length === 0) {
      this.summaryError = '目标未加载';
      return;
    }

    const snapshot: GroupCharacterMemorySnapshotUiModel | null = this.snapshot;
    if (snapshot === null) {
      this.summaryError = '记忆数据未加载,请稍候';
      return;
    }
    const characterName: string = snapshot.header.displayName;
    const groupTitle: string = snapshot.header.groupTitle;

    this.isSummarizing = true;
    this.summaryError = '';
    this.summaryOperationId = this.summaryOperationId + 1;
    const opId: number = this.summaryOperationId;
    const expectedCharId: string = this.expectedCharacterId;
    const expectedGroupId: string = this.expectedGroupConversationId;

    try {
      const result: SelfSummaryResult = await this.summaryService.prepareSelfSummary(
        expectedGroupId, expectedCharId, characterName, groupTitle
      );
      // 防迟到:opId 不匹配或已 dispose,丢弃结果
      if (opId !== this.summaryOperationId || this.disposed) {
        Logger.info(LOG_TAG, 'prepareSelfSummary late result dropped');
        return;
      }
      // 防角色切换:expected 改变则丢弃
      if (expectedCharId !== this.expectedCharacterId
        || expectedGroupId !== this.expectedGroupConversationId) {
        Logger.info(LOG_TAG, 'prepareSelfSummary target changed, drop');
        return;
      }
      if (result.success) {
        this.summaryDraft = result.draft ?? null;
        Logger.info(LOG_TAG, 'prepareSelfSummary ok: charShort=' + this.shortId(expectedCharId));
      } else {
        this.summaryError = result.errorMessage ?? '总结失败,请稍后重试';
        Logger.warn(LOG_TAG, 'prepareSelfSummary failed: kind=' + (result.errorKind ?? '')
          + ' charShort=' + this.shortId(expectedCharId));
      }
    } catch (e) {
      if (opId !== this.summaryOperationId || this.disposed) {
        return;
      }
      this.summaryError = '总结失败,请稍后重试';
      Logger.warn(LOG_TAG, 'prepareSelfSummary exception: ' + this.safeErrorCategory(e));
    } finally {
      if (opId === this.summaryOperationId) {
        this.isSummarizing = false;
      }
    }
  }

  /**
   * 重新生成摘要(用户点击"重新生成"按钮)。
   * 使用同一批来源消息再次调用模型,不写数据库。
   * 保留用户已编辑的 title/importance/keywords,只替换 content。
   */
  async regenerateSelfSummary(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.isSummarizing || this.isApprovingSummary) {
      Logger.warn(LOG_TAG, 'regenerateSelfSummary skipped: busy');
      return;
    }
    if (this.summaryService === null || this.summaryDraft === null) {
      return;
    }

    this.isSummarizing = true;
    this.summaryError = '';
    this.summaryOperationId = this.summaryOperationId + 1;
    const opId: number = this.summaryOperationId;
    const currentDraft: SelfSummaryDraft = this.summaryDraft;

    try {
      const result: SelfSummaryResult =
        await this.summaryService.regenerateSelfSummary(currentDraft);
      if (opId !== this.summaryOperationId || this.disposed) {
        return;
      }
      if (result.success) {
        this.summaryDraft = result.draft ?? null;
        Logger.info(LOG_TAG, 'regenerateSelfSummary ok');
      } else {
        this.summaryError = result.errorMessage ?? '重新生成失败,请稍后重试';
        Logger.warn(LOG_TAG, 'regenerateSelfSummary failed: kind=' + (result.errorKind ?? ''));
      }
    } catch (e) {
      if (opId !== this.summaryOperationId || this.disposed) {
        return;
      }
      this.summaryError = '重新生成失败,请稍后重试';
      Logger.warn(LOG_TAG, 'regenerateSelfSummary exception: ' + this.safeErrorCategory(e));
    } finally {
      if (opId === this.summaryOperationId) {
        this.isSummarizing = false;
      }
    }
  }

  /**
   * 批准保存 draft(用户点击"批准保存"按钮)。
   * 调用 summaryService.approveSelfSummary 写入 group_character_memories。
   * 保存失败时不修改 draft,用户编辑内容不丢失,审核窗口保持打开。
   */
  async approveSelfSummary(
    editedTitle: string,
    editedContent: string,
    editedImportance: number,
    editedKeywords: string[]
  ): Promise<GroupMemorySaveResult> {
    if (this.disposed) {
      return { success: false, errorMessage: '页面已失效' } as GroupMemorySaveResult;
    }
    if (this.isApprovingSummary || this.isSummarizing) {
      return { success: false, errorMessage: '正在处理,请稍候' } as GroupMemorySaveResult;
    }
    if (this.summaryService === null || this.summaryDraft === null) {
      return { success: false, errorMessage: '没有待审核的摘要' } as GroupMemorySaveResult;
    }

    this.isApprovingSummary = true;
    this.summaryError = '';
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    const currentDraft: SelfSummaryDraft = this.summaryDraft;

    try {
      const result: SelfSummaryApproveResult = await this.summaryService.approveSelfSummary(
        currentDraft,
        editedTitle,
        editedContent,
        editedImportance,
        editedKeywords
      );
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      if (result.success) {
        // 清空 draft,关闭审核窗口
        this.summaryDraft = null;
        Logger.info(LOG_TAG, 'approveSelfSummary ok');
        return { success: true, errorMessage: '' } as GroupMemorySaveResult;
      }
      // 保存失败:保持 draft,用户编辑内容不丢失
      this.summaryError = result.errorMessage;
      return { success: false, errorMessage: result.errorMessage } as GroupMemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as GroupMemorySaveResult;
      }
      const msg: string = '保存失败,请重试';
      this.summaryError = msg;
      Logger.warn(LOG_TAG, 'approveSelfSummary exception: ' + this.safeErrorCategory(e));
      return { success: false, errorMessage: msg } as GroupMemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isApprovingSummary = false;
      }
    }
  }

  /**
   * 关闭审核窗口(用户点击"取消"或遮罩)。
   * 保存中不允许关闭(防止中断)。总结中允许关闭但丢弃 draft。
   */
  clearSummaryDraft(): void {
    if (this.isApprovingSummary) {
      return;
    }
    this.summaryDraft = null;
    this.summaryError = '';
  }

  /** 当前 draft 来源消息数量(供 UI 显示) */
  summarySourceCount(): number {
    return this.summaryDraft !== null ? this.summaryDraft.source.messages.length : 0;
  }

  /** 当前 draft 来源用户消息数量(G-MEMORY-AUTO-1A-FIX,供 UI 显示) */
  summaryUserMessageCount(): number {
    return this.summaryDraft !== null ? this.summaryDraft.source.userMessageCount : 0;
  }

  /** 当前 draft 来源角色自身消息数量(G-MEMORY-AUTO-1A-FIX,供 UI 显示) */
  summaryCharacterMessageCount(): number {
    return this.summaryDraft !== null ? this.summaryDraft.source.characterMessageCount : 0;
  }

  /** 当前 draft 来源起始 sequence(供 UI 显示) */
  summarySourceStartSequence(): number {
    return this.summaryDraft !== null ? this.summaryDraft.source.startSequence : 0;
  }

  /** 当前 draft 来源结束 sequence(供 UI 显示) */
  summarySourceEndSequence(): number {
    return this.summaryDraft !== null ? this.summaryDraft.source.endSequence : 0;
  }

  /** 当前 draft 来源角色名称(供 UI 显示) */
  summarySourceCharacterName(): string {
    return this.summaryDraft !== null ? this.summaryDraft.source.characterName : '';
  }

  /** 当前 draft sourceHash 前 8 位(供 UI 显示,不暴露完整 hash) */
  summarySourceHashShort(): string {
    if (this.summaryDraft === null) {
      return '';
    }
    const hash: string = this.summaryDraft.source.sourceHash;
    return hash.length > 12 ? hash.substring(0, 12) : hash;
  }

  // ===== 私有辅助 =====

  private resolveMemberStatus(
    characterId: string,
    characterMissing: boolean,
    participants: ChatParticipant[]
  ): GroupCharacterMemberStatus {
    if (characterMissing) {
      return GroupCharacterMemberStatus.CharacterMissing;
    }
    let participant: ChatParticipant | undefined = undefined;
    for (let i = 0; i < participants.length; i++) {
      if (participants[i].characterId === characterId) {
        participant = participants[i];
        break;
      }
    }
    if (participant === undefined) {
      return GroupCharacterMemberStatus.RemovedMember;
    }
    return participant.isEnabled
      ? GroupCharacterMemberStatus.ActiveMember
      : GroupCharacterMemberStatus.DisabledMember;
  }

  private memberStatusLabel(status: GroupCharacterMemberStatus): string {
    if (status === GroupCharacterMemberStatus.ActiveMember) {
      return '当前成员';
    }
    if (status === GroupCharacterMemberStatus.DisabledMember) {
      return '已停用成员';
    }
    if (status === GroupCharacterMemberStatus.RemovedMember) {
      return '已移出群聊';
    }
    return '角色卡缺失';
  }

  private toServiceFilter(filter: GroupCharacterMemoryListFilter): GroupCharacterMemoryFilter {
    if (filter === GroupCharacterMemoryListFilter.Active) {
      return GroupCharacterMemoryFilter.Active;
    }
    if (filter === GroupCharacterMemoryListFilter.Archived) {
      return GroupCharacterMemoryFilter.Archived;
    }
    return GroupCharacterMemoryFilter.All;
  }

  private buildMemoryItem(memory: GroupCharacterMemory): GroupCharacterMemoryItemUiModel {
    const isInteraction: boolean = memory.origin === GroupCharacterMemoryOrigin.Interaction;
    const isInvalidated: boolean = memory.status === GroupCharacterMemoryStatus.Invalidated;
    const isSelfSummary: boolean = isInteraction
      && memory.sourceType === 'self_summary_v1';
    const contentPreview: string = memory.content.length > 80
      ? memory.content.substring(0, 80) + '...' : memory.content;
    const keywordsText: string = memory.keywords.length > 0
      ? memory.keywords.join(', ') : '';
    // G-MEMORY-AUTO-1A-FIX-2: 权限规则
    // - Manual: 可编辑/可归档/可删除
    // - self_summary_v1 且非 Invalidated: 可编辑/可归档/可删除
    // - 其他 Interaction: 只读
    // - Invalidated: 只读
    const canEdit: boolean = memory.origin === GroupCharacterMemoryOrigin.Manual
      || (isSelfSummary && !isInvalidated);
    const canArchive: boolean = canEdit;
    const canDelete: boolean = canEdit;
    return {
      id: memory.id,
      origin: memory.origin,
      originLabel: this.originLabel(memory.origin, memory.sourceType !== undefined ? memory.sourceType : ''),
      status: memory.status,
      statusLabel: this.statusLabel(memory.status),
      title: memory.title,
      content: memory.content,
      contentPreview: contentPreview,
      importance: memory.importance,
      keywords: memory.keywords,
      keywordsText: keywordsText,
      sourceSummary: this.buildSourceSummary(memory),
      isInteraction: isInteraction,
      isInvalidated: isInvalidated,
      isSelfSummary: isSelfSummary,
      canEdit: canEdit,
      canArchive: canArchive,
      canDelete: canDelete,
      createdAt: memory.createdAt,
      createdAtLabel: this.formatTimestamp(memory.createdAt),
      updatedAt: memory.updatedAt,
      updatedAtLabel: this.formatTimestamp(memory.updatedAt)
    };
  }

  private buildSourceSummary(memory: GroupCharacterMemory): string {
    if (memory.origin === GroupCharacterMemoryOrigin.Manual) {
      return '';
    }
    const parts: string[] = [];
    if (memory.sourceType === 'self_summary_v1') {
      parts.push('自动总结');
    }
    if (memory.sourceMessageId !== undefined && memory.sourceMessageId.length > 0) {
      parts.push('来源消息');
    }
    if (memory.sourceRoundId !== undefined && memory.sourceRoundId.length > 0) {
      parts.push('来源轮次');
    }
    if (memory.status === GroupCharacterMemoryStatus.Invalidated) {
      parts.push('已失效');
    }
    return parts.join(' · ');
  }

  private originLabel(origin: GroupCharacterMemoryOrigin, sourceType: string): string {
    if (origin === GroupCharacterMemoryOrigin.Manual) {
      return '手动';
    }
    if (sourceType === 'self_summary_v1') {
      return '自动总结';
    }
    return '交互';
  }

  private statusLabel(status: GroupCharacterMemoryStatus): string {
    if (status === GroupCharacterMemoryStatus.Active) {
      return '活跃';
    }
    if (status === GroupCharacterMemoryStatus.Archived) {
      return '已归档';
    }
    return '已失效';
  }

  private formatTimestamp(ts: number): string {
    if (!Number.isFinite(ts) || ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const year: number = d.getFullYear();
    const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    const hour: string = d.getHours().toString().padStart(2, '0');
    const minute: string = d.getMinutes().toString().padStart(2, '0');
    return year + '-' + month + '-' + day + ' ' + hour + ':' + minute;
  }

  private resolveErrorMessage(e: Object): string {
    return mapGroupCharacterMemoryErrorToMessage(e as Error);
  }

  private safeErrorCategory(e: Object): string {
    if (e instanceof DatabaseError) {
      return 'DatabaseError:' + e.type;
    }
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }

  private shortId(id: string): string {
    if (id.length <= 8) {
      return id;
    }
    return id.substring(id.length - 8);
  }
}

/** 重要度范围常量(供 UI 默认填充和校验) */
export const GROUP_MEMORY_IMPORTANCE_MIN: number = IMPORTANCE_MIN;
export const GROUP_MEMORY_IMPORTANCE_MAX: number = IMPORTANCE_MAX;
export const GROUP_MEMORY_IMPORTANCE_DEFAULT: number = DEFAULT_IMPORTANCE;
export const GROUP_MEMORY_TITLE_MAX: number = GROUP_CHARACTER_MEMORY_TITLE_MAX;
export const GROUP_MEMORY_CONTENT_MAX: number = GROUP_CHARACTER_MEMORY_CONTENT_MAX;
