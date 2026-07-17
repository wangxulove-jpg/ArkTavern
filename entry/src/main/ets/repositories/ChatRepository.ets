/**
 * ChatRepository
 *
 * 职责:
 * - Chat 的 CRUD 操作
 * - 列表筛选、排序、分页
 * - 提供 WithStore 内部方法供事务组合使用
 *
 * 不负责:
 * - 消息操作(见 MessageRepository)
 * - 级联删除(见 ChatPersistenceOperations)
 * - 业务逻辑
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { Chat } from '../models/Chat';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import {
  TABLE_CHATS,
  COLUMN_ID,
  COLUMN_CHARACTER_ID,
  COLUMN_TITLE,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_LAST_MESSAGE_AT,
  COLUMN_IS_ARCHIVED
} from '../database/DatabaseConstants';
import {
  intToBoolean,
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from './RepositoryMappers';

const LOG_TAG: string = 'ChatRepository';
const DEFAULT_LIMIT: number = 50;
const MAX_LIMIT: number = 200;

export interface ChatListOptions {
  readonly characterId?: string;
  readonly includeArchived?: boolean;
  readonly limit?: number;
  readonly offset?: number;
}

function chatToBucket(chat: Chat): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = chat.id;
  bucket[COLUMN_CHARACTER_ID] = chat.characterId !== undefined ? chat.characterId : null;
  bucket[COLUMN_TITLE] = chat.title;
  bucket[COLUMN_CREATED_AT] = chat.createdAt;
  bucket[COLUMN_UPDATED_AT] = chat.updatedAt;
  bucket[COLUMN_LAST_MESSAGE_AT] = chat.lastMessageAt;
  bucket[COLUMN_IS_ARCHIVED] = chat.isArchived ? 1 : 0;
  return bucket;
}

function chatFromRow(rs: relationalStore.ResultSet): Chat {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const charIdCol: number = rs.getColumnIndex(COLUMN_CHARACTER_ID);
  const characterId: string | undefined =
    charIdCol >= 0 && !rs.isColumnNull(charIdCol)
      ? rs.getString(charIdCol)
      : undefined;
  const title: string = rs.getString(rs.getColumnIndex(COLUMN_TITLE));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  const lastMessageAt: number = rs.getLong(rs.getColumnIndex(COLUMN_LAST_MESSAGE_AT));
  const isArchivedCol: number = rs.getColumnIndex(COLUMN_IS_ARCHIVED);
  const isArchived: boolean = intToBoolean(rs.getLong(isArchivedCol));
  return {
    id: id,
    characterId: characterId,
    title: title,
    createdAt: createdAt,
    updatedAt: updatedAt,
    lastMessageAt: lastMessageAt,
    isArchived: isArchived
  };
}

export class ChatRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async insert(chat: Chat): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.insertWithStore(store, chat);
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    chat: Chat
  ): Promise<void> {
    this.validateChat(chat);
    try {
      await store.insert(TABLE_CHATS, chatToBucket(chat));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('chat.insert');
      }
      throw DatabaseError.queryFailed(`chat.insert: ${extractCauseMessage(err)}`);
    }
  }

  async getById(id: string): Promise<Chat | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return chatFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async list(options?: ChatListOptions): Promise<Chat[]> {
    const includeArchived: boolean =
      options !== undefined && options.includeArchived === true;
    const limit: number =
      options !== undefined && options.limit !== undefined
        ? options.limit
        : DEFAULT_LIMIT;
    const offset: number =
      options !== undefined && options.offset !== undefined
        ? options.offset
        : 0;
    const characterId: string | undefined =
      options !== undefined && options.characterId !== undefined
        ? options.characterId
        : undefined;

    if (limit < 1 || limit > MAX_LIMIT) {
      throw DatabaseError.invalidData('limit out of range');
    }
    if (offset < 0) {
      throw DatabaseError.invalidData('offset out of range');
    }

    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    if (!includeArchived) {
      predicates.equalTo(COLUMN_IS_ARCHIVED, 0);
    }
    if (characterId !== undefined) {
      predicates.equalTo(COLUMN_CHARACTER_ID, characterId);
    }
    predicates.orderByDesc(COLUMN_LAST_MESSAGE_AT);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    predicates.limitAs(limit);
    predicates.offsetAs(offset);

    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const chats: Chat[] = [];
      while (rs.goToNextRow()) {
        chats.push(chatFromRow(rs));
      }
      return chats;
    } finally {
      rs.close();
    }
  }

  async update(chat: Chat): Promise<void> {
    this.validateChat(chat);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_CHARACTER_ID] = chat.characterId !== undefined ? chat.characterId : null;
    bucket[COLUMN_TITLE] = chat.title;
    bucket[COLUMN_UPDATED_AT] = chat.updatedAt;
    bucket[COLUMN_LAST_MESSAGE_AT] = chat.lastMessageAt;
    bucket[COLUMN_IS_ARCHIVED] = chat.isArchived ? 1 : 0;

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.equalTo(COLUMN_ID, chat.id);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`chat.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('chat.update');
    }
  }

  async remove(id: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.removeWithStore(store, id);
  }

  async removeWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`chat.remove: ${extractCauseMessage(err)}`);
    }
  }

  async setArchived(id: string, archived: boolean): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_IS_ARCHIVED] = archived ? 1 : 0;
    bucket[COLUMN_UPDATED_AT] = nowMillis();

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.equalTo(COLUMN_ID, id);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`chat.setArchived: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('chat.setArchived');
    }
  }

  async updateLastMessageAt(
    id: string,
    lastMessageAt: number,
    updatedAt: number
  ): Promise<void> {
    if (!isValidTimestamp(lastMessageAt)) {
      throw DatabaseError.invalidData('lastMessageAt invalid');
    }
    if (!isValidTimestamp(updatedAt)) {
      throw DatabaseError.invalidData('updatedAt invalid');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_LAST_MESSAGE_AT] = lastMessageAt;
    bucket[COLUMN_UPDATED_AT] = updatedAt;

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.equalTo(COLUMN_ID, id);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`chat.updateLastMessageAt: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('chat.updateLastMessageAt');
    }
  }

  async count(): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS cnt FROM ${TABLE_CHATS}`
    );
    try {
      if (rs.goToFirstRow()) {
        const ci: number = rs.getColumnIndex('cnt');
        if (ci >= 0) {
          return rs.getLong(ci);
        }
      }
      return 0;
    } finally {
      rs.close();
    }
  }

  async chatExistsWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.goToFirstRow();
    } finally {
      rs.close();
    }
  }

  private validateChat(chat: Chat): void {
    if (chat.id === '') {
      throw DatabaseError.invalidData('chat.id empty');
    }
    if (!isValidTimestamp(chat.createdAt)) {
      throw DatabaseError.invalidData('chat.createdAt invalid');
    }
    if (!isValidTimestamp(chat.updatedAt)) {
      throw DatabaseError.invalidData('chat.updatedAt invalid');
    }
    if (!isValidTimestamp(chat.lastMessageAt)) {
      throw DatabaseError.invalidData('chat.lastMessageAt invalid');
    }
  }
}
