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
import { ChatMessageSource } from './ChatMessageSource';

/**
 * Assistant 消息状态。
 */
export enum ChatMessageStatus {
  /** 流式生成中 */
  Streaming = 'streaming',
  /** 已完成 */
  Completed = 'completed',
  /** 已取消(用户停止) */
  Cancelled = 'cancelled',
  /** 生成失败 */
  Failed = 'failed'
}

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
  /** 是否正在流式生成中(与 status 字段冗余,保留兼容) */
  readonly isStreaming?: boolean;
  /** 错误信息(生成失败时) */
  readonly errorMessage?: string;
  /** Assistant 消息状态 */
  readonly status?: ChatMessageStatus;
  /**
   * 消息来源(可选,内部辅助标记)。
   * - PromptBuilder 输出的临时消息会标注 source
   * - ChatService.messages 中的持久化消息无此字段(默认 Conversation)
   * - HistoryTrimmer 据此判断哪些消息可裁剪
   * - 不会写入网络请求 JSON(Provider 不识别)
   */
  readonly source?: ChatMessageSource;
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
