/**
 * ChatMessage 聊天消息模型
 *
 * 定义通用的聊天消息结构。
 * 当前只是通用消息模型,不加入 Character、Lorebook、Swipe 等后续字段。
 *
 * 要求:
 * - 不加入 ArkUI 状态装饰器
 * - 不依赖 ViewModel
 * - 不使用 any
 */

import { ChatRole } from './ChatRole';

/**
 * 聊天消息模型。
 */
export interface ChatMessage {
  /** 消息唯一标识 */
  readonly id: string;
  /** 消息角色 */
  readonly role: ChatRole;
  /** 消息内容 */
  readonly content: string;
  /** 创建时间(毫秒时间戳) */
  readonly createdAt: number;
  /** 更新时间(可选,毫秒时间戳) */
  readonly updatedAt?: number;
  /** 是否正在流式生成中 */
  readonly isStreaming?: boolean;
  /** 错误信息(生成失败时) */
  readonly errorMessage?: string;
}

/**
 * 创建聊天消息。
 * @param id 消息唯一标识
 * @param role 消息角色
 * @param content 消息内容
 * @param createdAt 创建时间(毫秒时间戳)
 * @returns ChatMessage 实例
 */
export function createChatMessage(
  id: string,
  role: ChatRole,
  content: string,
  createdAt: number
): ChatMessage {
  return {
    id: id,
    role: role,
    content: content,
    createdAt: createdAt
  };
}
