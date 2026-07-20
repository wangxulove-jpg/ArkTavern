/**
 * Chat 聊天会话模型
 *
 * 纯数据模型,不依赖 ArkUI、RDB 或页面。
 * id 默认使用 UUID,时间默认使用统一 Time 工具。
 * 所有更新返回新对象,不修改原对象。
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

export interface Chat {
  readonly id: string;
  readonly characterId?: string;
  readonly title: string;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly lastMessageAt: number;
  readonly isArchived: boolean;
  /** 自定义排序权重(越小越靠前,v7 引入) */
  readonly sortOrder: number;
}

export interface CreateChatOptions {
  readonly id?: string;
  readonly characterId?: string;
  readonly title?: string;
  readonly createdAt?: number;
  readonly sortOrder?: number;
}

export interface ChatUpdates {
  readonly title?: string;
  readonly characterId?: string | null;
  readonly updatedAt?: number;
  readonly lastMessageAt?: number;
  readonly isArchived?: boolean;
  readonly sortOrder?: number;
}

export function createChat(options?: CreateChatOptions): Chat {
  const now: number = nowMillis();
  const id: string = options !== undefined && options.id !== undefined
    ? options.id
    : generateUuid();
  const characterId: string | undefined =
    options !== undefined && options.characterId !== undefined
      ? options.characterId
      : undefined;
  const title: string =
    options !== undefined && options.title !== undefined
      ? options.title
      : '';
  const createdAt: number =
    options !== undefined && options.createdAt !== undefined
      ? options.createdAt
      : now;
  const sortOrder: number =
    options !== undefined && options.sortOrder !== undefined
      ? options.sortOrder
      : 0;
  return {
    id: id,
    characterId: characterId,
    title: title,
    createdAt: createdAt,
    updatedAt: now,
    lastMessageAt: 0,
    isArchived: false,
    sortOrder: sortOrder
  };
}

export function updateChat(chat: Chat, updates: ChatUpdates): Chat {
  const characterId: string | undefined =
    updates.characterId !== undefined
      ? (updates.characterId === null ? undefined : updates.characterId)
      : chat.characterId;
  const title: string =
    updates.title !== undefined ? updates.title : chat.title;
  const updatedAt: number =
    updates.updatedAt !== undefined ? updates.updatedAt : nowMillis();
  const lastMessageAt: number =
    updates.lastMessageAt !== undefined ? updates.lastMessageAt : chat.lastMessageAt;
  const isArchived: boolean =
    updates.isArchived !== undefined ? updates.isArchived : chat.isArchived;
  const sortOrder: number =
    updates.sortOrder !== undefined ? updates.sortOrder : chat.sortOrder;
  return {
    id: chat.id,
    characterId: characterId,
    title: title,
    createdAt: chat.createdAt,
    updatedAt: updatedAt,
    lastMessageAt: lastMessageAt,
    isArchived: isArchived,
    sortOrder: sortOrder
  };
}
