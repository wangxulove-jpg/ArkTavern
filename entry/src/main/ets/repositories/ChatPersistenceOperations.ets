/**
 * ChatPersistenceOperations
 *
 * 职责:
 * - 提供 Chat 与 Message 的联合事务操作
 * - removeChatWithMessages: 在一个事务中同时删除 Chat 及其所有 Message
 *
 * 不负责:
 * - 单表 CRUD(见 ChatRepository / MessageRepository)
 * - 业务逻辑
 *
 * 规则:
 * - 使用 DbHelper.runInTransaction 保证原子性
 * - 任一步失败全部回滚
 * - 删除不存在 Chat 时保持幂等(不抛错)
 * - 通过 WithStore 内部方法操作,避免嵌套事务
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatRepository } from './ChatRepository';
import { MessageRepository } from './MessageRepository';
import { DatabaseError } from '../models/DatabaseError';
import { extractCauseMessage } from './RepositoryMappers';

export class ChatPersistenceOperations {
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
   * 在一个事务中:
   * 1. 删除指定 Chat 的所有 Message
   * 2. 删除 Chat 本身
   *
   * 任一步失败全部回滚。
   * 删除不存在 Chat 时保持幂等(不抛错)。
   */
  async removeChatWithMessages(chatId: string): Promise<void> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          // 先删消息(幂等,不存在返回 0)
          await this.messageRepository.removeByChatIdWithStore(store, chatId);
          // 再删 Chat(幂等,不存在不抛错)
          await this.chatRepository.removeWithStore(store, chatId);
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `removeChatWithMessages: ${extractCauseMessage(err)}`
      );
    }
  }
}
