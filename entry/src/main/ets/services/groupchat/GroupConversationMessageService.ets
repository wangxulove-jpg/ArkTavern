/**
 * GroupConversationMessageService 多人聊天消息持久化服务(G-RUNTIME-1A)
 *
 * 职责:
 * - 读取群聊真实历史消息(按 sequenceNumber ASC)
 * - 写入用户消息(事务:Message + Chat 时间戳)
 * - 清空群聊消息(复用 MessageRepository.removeByChatId)
 * - 恢复中断消息(Streaming → Cancelled)
 *
 * 不负责:
 * - AI 生成(不创建 AI 消息,不调用 Provider)
 * - 轮次计划(由 GroupRoundCoordinator 负责)
 * - Branch / Swipe(多人聊天本阶段不接入)
 * - UI 状态管理
 *
 * 数据隔离:
 * - 通过 ChatRepository.getById + conversationMode 校验,只允许 Group Chat 写入
 * - 不复用单聊 ChatService.appendMessage(避免依赖 Branch)
 * - 直接使用 MessageRepository,事务内同时更新 Chat 时间戳
 *
 * 字段约定:
 * - 用户消息:role=User, status=Completed, senderType='user',
 *   senderCharacterId=null(留空), generationBatchId=本轮 ID
 * - AI 消息:下一阶段创建
 * - visibility 默认 'public'(本阶段全部公开)
 *
 * 日志规则:
 * - 不打印完整 Chat ID / Message ID / 正文
 * - 只打印消息数量、状态、操作类别
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { ChatRepository } from '../../repositories/ChatRepository';
import { MessageRepository, StoredChatMessage, MessagePageOptions } from '../../repositories/MessageRepository';
import { Chat } from '../../models/Chat';
import { ChatMessage, ChatMessageStatus, MessageSenderType, MessageVisibility } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ConversationMode } from '../../models/ConversationMode';
import { DatabaseError } from '../../models/DatabaseError';
import { nowMillis } from '../../utils/Time';
import { generateUuid } from '../../utils/Uuid';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'GroupConvMsg';
const LIST_MESSAGES_LIMIT: number = 200;

export class GroupConversationMessageService {
  private readonly dbHelper: DbHelper;
  private readonly chatRepository: ChatRepository;
  private readonly messageRepository: MessageRepository;

  constructor(
    dbHelper: DbHelper,
    chatRepository: ChatRepository,
    messageRepository: MessageRepository
  ) {
    this.dbHelper = dbHelper;
    this.chatRepository = chatRepository;
    this.messageRepository = messageRepository;
  }

  /**
   * 读取群聊全部消息(按 sequenceNumber ASC)。
   *
   * 规则:
   * - 调用前会先 recoverInterruptedMessages,把残留 Streaming 转为 Cancelled
   * - 不混入预览消息
   * - 不读取其他 Chat 的消息
   */
  async listMessages(chatId: string): Promise<ChatMessage[]> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    await this.recoverInterruptedMessages(chatId);
    const options: MessagePageOptions = {
      limit: LIST_MESSAGES_LIMIT,
      offset: 0,
      ascending: true
    };
    const records: StoredChatMessage[] =
      await this.messageRepository.listRecordsByChat(chatId, options);
    const messages: ChatMessage[] = records.map(
      (rec: StoredChatMessage): ChatMessage => rec.message
    );
    return messages;
  }

  /**
   * 追加用户消息(事务)。
   *
   * 验证:
   * - chatId 对应的 Chat 存在
   * - Chat.conversationMode === Group
   * - content.trim() 非空
   *
   * 事务内:
   * - 计算 next sequenceNumber = max + 1
   * - 插入 Message(role=User, status=Completed, senderType='user',
   *   senderCharacterId=null, generationBatchId=传入的批次 ID)
   * - 更新 Chat.lastMessageAt 和 updatedAt
   *
   * @returns 写入的 ChatMessage(含分配的 id)
   */
  async appendUserMessage(
    chatId: string,
    content: string,
    generationBatchId: string
  ): Promise<ChatMessage> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const trimmed: string = content.trim();
    if (trimmed.length === 0) {
      throw DatabaseError.invalidData('content empty');
    }
    if (generationBatchId === '') {
      throw DatabaseError.invalidData('generationBatchId empty');
    }

    const chat: Chat | null = await this.chatRepository.getById(chatId);
    if (chat === null) {
      throw DatabaseError.notFound('group chat not found');
    }
    if (chat.conversationMode !== ConversationMode.Group) {
      throw DatabaseError.invalidData('chat is not group mode');
    }

    const now: number = nowMillis();
    const messageId: string = generateUuid();
    const message: ChatMessage = {
      id: messageId,
      role: ChatRole.User,
      content: trimmed,
      createdAt: now,
      updatedAt: now,
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      senderType: 'user' as MessageSenderType,
      senderCharacterId: undefined,
      generationBatchId: generationBatchId,
      visibility: 'public' as MessageVisibility
    };

    const maxSeq: number = await this.messageRepository.getMaxSequenceNumber(chatId);
    const nextSeq: number = maxSeq + 1;

    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.messageRepository.insertWithStore(store, message, chatId, nextSeq);
          await this.chatRepository.updateLastMessageAtWithStore(store, chatId, now, now);
        },
        'group_message_append_user'
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      Logger.error(LOG_TAG, 'appendUserMessage failed: ' + String(err));
      throw DatabaseError.transactionFailed('appendUserMessage');
    }
    return message;
  }

  /**
   * 清空群聊全部消息。
   *
   * 规则:
   * - 只删除该群聊的 messages
   * - 不删除 Chat / Participants / Character / 群聊名称 / 成员顺序
   * - 不调用单聊的 Branch / Swipe 清理链(多人聊天本阶段无 Branch)
   * - 幂等:不存在的群聊或无消息返回 0
   *
   * @returns 删除的消息条数
   */
  async clearMessages(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const chat: Chat | null = await this.chatRepository.getById(chatId);
    if (chat === null) {
      throw DatabaseError.notFound('group chat not found');
    }
    if (chat.conversationMode !== ConversationMode.Group) {
      throw DatabaseError.invalidData('chat is not group mode');
    }
    const deleted: number = await this.messageRepository.removeByChatId(chatId);
    Logger.info(LOG_TAG, 'clearMessages removed count=' + String(deleted));
    return deleted;
  }

  /**
   * 恢复中断消息。
   *
   * 将指定群聊中 status=Streaming 的消息转为 Cancelled。
   * - 不删除正文
   * - 不自动重新请求
   * - 不影响其他群聊
   * - 不修改单聊的中断恢复规则
   */
  async recoverInterruptedMessages(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    return await this.messageRepository.normalizeInterruptedMessages(chatId);
  }
}
