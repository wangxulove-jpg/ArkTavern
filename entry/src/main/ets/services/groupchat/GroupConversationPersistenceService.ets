/**
 * GroupConversationPersistenceService 多人聊天持久化服务(G-DATA-1A)
 *
 * 职责:
 * - 多人聊天的创建、列表、重命名、成员管理、删除
 * - 通过 DbHelper 事务保证关键操作的原子性
 * - 调用 GroupConversationRules 集中校验参与者规则
 *
 * 不负责:
 * - AI 生成(不调用 ModelService / Provider / SSE)
 * - 消息创建(不创建用户消息 / AI 消息 / 开场白)
 * - Branch / Swipe / Memory(多人聊天本阶段不接入)
 * - UI 状态管理
 *
 * 事务边界:
 * - createGroupConversation: 一个事务(Chat + 全部 Participant)
 * - replaceParticipantOrder: 一个事务(删除旧 Participant + 写入新 Participant)
 * - setParticipantEnabled: 单行 UPDATE(不需事务)
 * - addParticipant: 一个事务(校验 + 插入)
 * - removeParticipant: 一个事务(校验 + 删除 + 重排序)
 * - deleteGroupConversation: 复用 ChatPersistenceOperations.removeChatWithMessages
 *
 * 日志规则:
 * - 不打印完整 Chat ID / Character ID / SQL
 * - 不打印角色卡正文
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { ChatRepository } from '../../repositories/ChatRepository';
import { ChatParticipantRepository } from '../../repositories/ChatParticipantRepository';
import { CharacterRepository } from '../../repositories/CharacterRepository';
import { ChatPersistenceOperations } from '../../repositories/ChatPersistenceOperations';
import { Chat, createChat, updateChat } from '../../models/Chat';
import { ChatParticipant } from '../../models/ChatParticipant';
import { ConversationMode } from '../../models/ConversationMode';
import { DatabaseError } from '../../models/DatabaseError';
import { nowMillis } from '../../utils/Time';
import { Logger } from '../../utils/Logger';
import {
  TABLE_CHAT_PARTICIPANTS,
  COLUMN_CHAT_ID,
  COLUMN_CHARACTER_ID,
  COLUMN_IS_ENABLED,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  validateParticipantCharacterIds,
  buildOrderedParticipants,
  MIN_PARTICIPANT_COUNT,
  MAX_PARTICIPANT_COUNT,
  MIN_ENABLED_COUNT
} from './GroupConversationRules';
import { GroupRuntimeRegistry } from './GroupRuntimeRegistry';

const LOG_TAG: string = 'GroupConvPersist';

export class GroupConversationPersistenceService {
  private readonly dbHelper: DbHelper;
  private readonly chatRepository: ChatRepository;
  private readonly participantRepository: ChatParticipantRepository;
  private readonly characterRepository: CharacterRepository;
  private readonly chatPersistenceOperations: ChatPersistenceOperations;
  /** G-RUNTIME-1D: 应用级运行注册表(成员修改 / 删除互斥) */
  private readonly registry: GroupRuntimeRegistry;

  constructor(
    dbHelper: DbHelper,
    chatRepository: ChatRepository,
    participantRepository: ChatParticipantRepository,
    characterRepository: CharacterRepository,
    chatPersistenceOperations: ChatPersistenceOperations,
    registry: GroupRuntimeRegistry
  ) {
    this.dbHelper = dbHelper;
    this.chatRepository = chatRepository;
    this.participantRepository = participantRepository;
    this.characterRepository = characterRepository;
    this.chatPersistenceOperations = chatPersistenceOperations;
    this.registry = registry;
  }

  /**
   * 创建多人聊天(事务)。
   *
   * 验证:
   * - title.trim() 非空
   * - 角色数量 2~8
   * - 角色 ID 不重复、非空
   * - 全部角色真实存在
   *
   * 事务内:
   * - 创建 Chat(conversationMode=Group, characterId=null)
   * - 创建全部 ChatParticipant(speakerOrder 按数组顺序, isEnabled=true)
   *
   * 不创建:消息 / Branch / Swipe / Memory / 开场白。
   * 任一步失败全部回滚。
   */
  async createGroupConversation(
    title: string,
    orderedCharacterIds: string[]
  ): Promise<Chat> {
    const trimmedTitle: string = title.trim();
    if (trimmedTitle.length === 0) {
      throw DatabaseError.invalidData('group title empty');
    }
    validateParticipantCharacterIds(orderedCharacterIds);
    // 校验全部角色真实存在
    await this.ensureCharactersExist(orderedCharacterIds);

    const sortOrder: number = await this.nextSortOrder();
    const chat: Chat = createChat({
      title: trimmedTitle,
      conversationMode: ConversationMode.Group,
      sortOrder: sortOrder
      // characterId 留空(Group 模式不绑定单一角色)
    });

    const now: number = nowMillis();
    const participants: ChatParticipant[] = buildOrderedParticipants(
      chat.id, orderedCharacterIds, now
    );

    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.chatRepository.insertWithStore(store, chat);
          await this.participantRepository.insertManyWithStore(store, participants);
        },
        'group_conversation_create'
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      Logger.error(LOG_TAG, 'createGroupConversation failed: ' + String(err));
      throw DatabaseError.transactionFailed('createGroupConversation');
    }
    return chat;
  }

  /**
   * 列出全部多人聊天(未归档,按默认排序)。
   */
  async listGroupConversations(): Promise<Chat[]> {
    return await this.chatRepository.listGroupChats({ limit: 200, offset: 0 });
  }

  /**
   * 读取指定多人聊天(G-MEMORY-1A)。
   * - 仅返回 ConversationMode=Group 的 Chat
   * - 不存在或非 Group 模式返回 null
   * 仅供记忆页头部展示群聊名称,不做权限校验。
   */
  async getGroupConversation(chatId: string): Promise<Chat | null> {
    if (chatId === '') {
      return null;
    }
    const chat: Chat | null = await this.chatRepository.getById(chatId);
    if (chat === null) {
      return null;
    }
    if (chat.conversationMode !== ConversationMode.Group) {
      return null;
    }
    return chat;
  }

  /**
   * 读取指定多人聊天的参与者(按 speaker_order ASC)。
   */
  async getParticipants(chatId: string): Promise<ChatParticipant[]> {
    return await this.participantRepository.listByChatId(chatId);
  }

  /**
   * 重命名多人聊天(仅修改 title)。
   * - title.trim() 非空
   * - 不存在抛错
   * - 不修改 characterId / conversationMode / 参与者
   */
  async renameGroupConversation(
    chatId: string,
    title: string
  ): Promise<void> {
    const trimmed: string = title.trim();
    if (trimmed.length === 0) {
      throw DatabaseError.invalidData('group title empty');
    }
    const existing: Chat | null = await this.chatRepository.getById(chatId);
    if (existing === null) {
      throw DatabaseError.notFound('group chat not found');
    }
    if (existing.conversationMode !== ConversationMode.Group) {
      throw DatabaseError.invalidData('chat is not group mode');
    }
    if (existing.title === trimmed) {
      return;
    }
    const updated: Chat = updateChat(existing, { title: trimmed });
    await this.chatRepository.update(updated);
  }

  /**
   * 替换参与者顺序(事务)。
   *
   * 规则:
   * - 角色集合必须与当前一致(仅调整顺序)
   * - 顺序从 0 连续排列
   * - 事务内:删除该 Chat 的全部 participant 行 → 按新顺序重新写入
   * - 保留原有 isEnabled 状态(根据旧 participant 映射)
   */
  async replaceParticipantOrder(
    chatId: string,
    orderedCharacterIds: string[]
  ): Promise<void> {
    // G-RUNTIME-1D: 业务层互斥(生成中禁止调整顺序)
    this.registry.assertChatMutable(chatId);
    validateParticipantCharacterIds(orderedCharacterIds);

    const existing: Chat | null = await this.chatRepository.getById(chatId);
    if (existing === null) {
      throw DatabaseError.notFound('group chat not found');
    }
    if (existing.conversationMode !== ConversationMode.Group) {
      throw DatabaseError.invalidData('chat is not group mode');
    }

    const oldParticipants: ChatParticipant[] =
      await this.participantRepository.listByChatId(chatId);

    // 校验角色集合不变
    const oldCharIds: Set<string> = new Set(
      oldParticipants.map((p: ChatParticipant): string => p.characterId)
    );
    const newCharIds: Set<string> = new Set(orderedCharacterIds);
    if (oldCharIds.size !== newCharIds.size) {
      throw DatabaseError.invalidData('participant set changed');
    }
    const newCharIdArray: string[] = orderedCharacterIds;
    for (let i = 0; i < newCharIdArray.length; i++) {
      if (!oldCharIds.has(newCharIdArray[i])) {
        throw DatabaseError.invalidData('participant set changed');
      }
    }

    // 构建新参与者列表,保留旧 isEnabled 状态
    const enabledMap: Map<string, boolean> = new Map();
    for (let i = 0; i < oldParticipants.length; i++) {
      enabledMap.set(oldParticipants[i].characterId, oldParticipants[i].isEnabled);
    }
    const now: number = nowMillis();
    const newParticipants: ChatParticipant[] = orderedCharacterIds.map(
      (charId: string, index: number): ChatParticipant => {
        const stored: boolean | undefined = enabledMap.get(charId);
        const isEnabled: boolean = stored !== undefined ? stored : true;
        return {
          chatId: chatId,
          characterId: charId,
          speakerOrder: index,
          isEnabled: isEnabled,
          createdAt: now,
          updatedAt: now
        };
      }
    );

    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.participantRepository.replaceAllWithStore(
            store, chatId, newParticipants
          );
        },
        'group_conversation_replace_participants'
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      Logger.error(LOG_TAG, 'replaceParticipantOrder failed: ' + String(err));
      throw DatabaseError.transactionFailed('replaceParticipantOrder');
    }
  }

  /**
   * 设置单个参与者启用/停用。
   *
   * 规则:
   * - 阻止启用成员数下降到 2 以下
   * - 不存在抛 NotFound
   */
  async setParticipantEnabled(
    chatId: string,
    characterId: string,
    enabled: boolean
  ): Promise<void> {
    // G-RUNTIME-1D: 业务层互斥(生成中禁止启用/停用)
    this.registry.assertChatMutable(chatId);
    const participants: ChatParticipant[] =
      await this.participantRepository.listByChatId(chatId);

    const target: ChatParticipant | undefined = participants.find(
      (p: ChatParticipant): boolean => p.characterId === characterId
    );
    if (target === undefined) {
      throw DatabaseError.notFound('participant not found');
    }

    if (!enabled) {
      // 阻止启用数 < 2
      const enabledCount: number = participants.filter(
        (p: ChatParticipant): boolean => p.isEnabled
      ).length;
      if (enabledCount <= MIN_ENABLED_COUNT) {
        throw DatabaseError.invalidData(
          `enabled participants would drop below ${MIN_ENABLED_COUNT}`
        );
      }
    }

    // 状态未变化时直接返回
    if (target.isEnabled === enabled) {
      return;
    }

    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.updateParticipantEnabledWithStore(store, chatId, characterId, enabled);
        },
        'group_conversation_update_enabled'
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      Logger.error(LOG_TAG, 'setParticipantEnabled failed: ' + String(err));
      throw DatabaseError.transactionFailed('setParticipantEnabled');
    }
  }

  /**
   * 添加参与者到末尾。
   *
   * 规则:
   * - 当前成员 < 8
   * - 角色真实存在
   * - 角色尚未加入
   * - 新增到末尾(speakerOrder = 当前最大 + 1)
   * - 默认启用
   */
  async addParticipant(
    chatId: string,
    characterId: string
  ): Promise<void> {
    if (characterId === '') {
      throw DatabaseError.invalidData('characterId empty');
    }
    // G-RUNTIME-1D: 业务层互斥(生成中禁止添加成员)
    this.registry.assertChatMutable(chatId);

    const existing: Chat | null = await this.chatRepository.getById(chatId);
    if (existing === null) {
      throw DatabaseError.notFound('group chat not found');
    }
    if (existing.conversationMode !== ConversationMode.Group) {
      throw DatabaseError.invalidData('chat is not group mode');
    }

    const participants: ChatParticipant[] =
      await this.participantRepository.listByChatId(chatId);

    if (participants.length >= MAX_PARTICIPANT_COUNT) {
      throw DatabaseError.invalidData(
        `participants count >= ${MAX_PARTICIPANT_COUNT}`
      );
    }

    // 角色已加入
    const alreadyJoined: boolean = participants.some(
      (p: ChatParticipant): boolean => p.characterId === characterId
    );
    if (alreadyJoined) {
      throw DatabaseError.alreadyExists('participant already joined');
    }

    // 校验角色真实存在
    const characterExists: boolean = (await this.characterRepository.getById(characterId)) !== null;
    if (!characterExists) {
      throw DatabaseError.notFound('character not found');
    }

    const maxOrder: number = participants.reduce(
      (max: number, p: ChatParticipant): number => p.speakerOrder > max ? p.speakerOrder : max,
      -1
    );
    const now: number = nowMillis();
    const newParticipant: ChatParticipant = {
      chatId: chatId,
      characterId: characterId,
      speakerOrder: maxOrder + 1,
      isEnabled: true,
      createdAt: now,
      updatedAt: now
    };

    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.participantRepository.insertManyWithStore(store, [newParticipant]);
        },
        'group_conversation_add_participant'
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      Logger.error(LOG_TAG, 'addParticipant failed: ' + String(err));
      throw DatabaseError.transactionFailed('addParticipant');
    }
  }

  /**
   * 移除参与者。
   *
   * 规则:
   * - 阻止总成员数下降到 2 以下
   * - 移除后重排序,保证 speakerOrder 从 0 连续
   * - 不删除该角色过去发送的消息
   * - 不删除角色卡
   * - 不影响其他群聊中的成员关系
   */
  async removeParticipant(
    chatId: string,
    characterId: string
  ): Promise<void> {
    if (characterId === '') {
      throw DatabaseError.invalidData('characterId empty');
    }
    // G-RUNTIME-1D: 业务层互斥(生成中禁止移除成员)
    this.registry.assertChatMutable(chatId);

    const participants: ChatParticipant[] =
      await this.participantRepository.listByChatId(chatId);

    if (participants.length <= MIN_PARTICIPANT_COUNT) {
      throw DatabaseError.invalidData(
        `participants count <= ${MIN_PARTICIPANT_COUNT}`
      );
    }

    const target: ChatParticipant | undefined = participants.find(
      (p: ChatParticipant): boolean => p.characterId === characterId
    );
    if (target === undefined) {
      throw DatabaseError.notFound('participant not found');
    }

    // 构建移除后的新参与者列表(保留剩余成员的 isEnabled,重排 speakerOrder)
    const remaining: ChatParticipant[] = participants
      .filter((p: ChatParticipant): boolean => p.characterId !== characterId)
      .sort((a: ChatParticipant, b: ChatParticipant): number =>
        a.speakerOrder - b.speakerOrder
      );
    const now: number = nowMillis();
    const reordered: ChatParticipant[] = remaining.map(
      (p: ChatParticipant, index: number): ChatParticipant => {
        return {
          chatId: p.chatId,
          characterId: p.characterId,
          speakerOrder: index,
          isEnabled: p.isEnabled,
          createdAt: p.createdAt,
          updatedAt: now
        };
      }
    );

    // 移除后仍需满足至少 2 个启用
    const enabledAfterRemove: number = reordered.filter(
      (p: ChatParticipant): boolean => p.isEnabled
    ).length;
    if (enabledAfterRemove < MIN_ENABLED_COUNT) {
      throw DatabaseError.invalidData(
        `enabled participants would drop below ${MIN_ENABLED_COUNT}`
      );
    }

    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.participantRepository.replaceAllWithStore(
            store, chatId, reordered
          );
        },
        'group_conversation_remove_participant'
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      Logger.error(LOG_TAG, 'removeParticipant failed: ' + String(err));
      throw DatabaseError.transactionFailed('removeParticipant');
    }
  }

  /**
   * 删除多人聊天(复用现有删除事务链 + chat_participants 清理)。
   * - 调用 ChatPersistenceOperations.removeChatWithMessages
   * - 该方法在同一事务中清理:
   *   Branch / Memory / Swipe / Messages / chat_participants / Chat
   * - 幂等:不存在的 Chat 不抛错
   */
  async deleteGroupConversation(chatId: string): Promise<void> {
    // G-RUNTIME-1D: 业务层互斥(生成中禁止删除当前群聊)
    // 其他未运行群聊仍可删除,因为运行锁按 chatId 判断。
    this.registry.assertChatMutable(chatId);
    await this.chatPersistenceOperations.removeChatWithMessages(chatId);
  }

  // ===== 内部方法 =====

  /**
   * 校验全部角色 ID 真实存在。
   * 任一不存在抛 NotFound。
   */
  private async ensureCharactersExist(characterIds: string[]): Promise<void> {
    for (let i = 0; i < characterIds.length; i++) {
      const exists: boolean = (await this.characterRepository.getById(characterIds[i])) !== null;
      if (!exists) {
        throw DatabaseError.notFound('character not found');
      }
    }
  }

  /**
   * 在事务内更新单个参与者启用状态(避免嵌套事务)。
   */
  private async updateParticipantEnabledWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    characterId: string,
    enabled: boolean
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_IS_ENABLED] = enabled ? 1 : 0;
    bucket[COLUMN_UPDATED_AT] = nowMillis();

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_PARTICIPANTS);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_CHARACTER_ID, characterId);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `participant.updateEnabled: ${String(err)}`
      );
    }
    if (affected === 0) {
      throw DatabaseError.notFound('participant not found');
    }
  }

  /**
   * 计算下一个 sort_order(用于新建群聊时分配)。
   */
  private async nextSortOrder(): Promise<number> {
    const max: number = await this.chatRepository.getMaxSortOrder();
    return max < 0 ? 0 : max + 1;
  }
}
