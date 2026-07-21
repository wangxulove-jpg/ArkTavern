/**
 * WorldChatLink 世界与会话关联
 *
 * 一个多人世界会话关联:
 * - 一个 Chat(复用现有 chats 表)
 * - 一个 World
 * - 当前场景 ID
 * - 当前回复模式(可覆盖世界默认)
 */

import { WorldReplyMode, parseReplyMode } from './World';

export interface WorldChatLink {
  readonly chatId: string;
  readonly worldId: string;
  readonly currentSceneId: string | null;
  readonly replyMode: WorldReplyMode;
}

export interface CreateWorldChatLinkOptions {
  readonly chatId: string;
  readonly worldId: string;
  readonly currentSceneId?: string | null;
  readonly replyMode?: WorldReplyMode;
}

export interface WorldChatLinkUpdates {
  readonly currentSceneId?: string | null;
  readonly replyMode?: WorldReplyMode;
}

export function createWorldChatLink(options: CreateWorldChatLinkOptions): WorldChatLink {
  return {
    chatId: options.chatId,
    worldId: options.worldId,
    currentSceneId: options.currentSceneId !== undefined ? options.currentSceneId : null,
    replyMode: options.replyMode !== undefined ? options.replyMode : 'auto_director'
  };
}

export function updateWorldChatLink(
  link: WorldChatLink,
  updates: WorldChatLinkUpdates
): WorldChatLink {
  return {
    chatId: link.chatId,
    worldId: link.worldId,
    currentSceneId: updates.currentSceneId !== undefined
      ? updates.currentSceneId : link.currentSceneId,
    replyMode: updates.replyMode !== undefined ? updates.replyMode : link.replyMode
  };
}

export function parseLinkReplyMode(value: string): WorldReplyMode {
  return parseReplyMode(value);
}
