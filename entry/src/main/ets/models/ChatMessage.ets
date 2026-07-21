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
 * 消息发送者类型(v10 多人世界引入)。
 * - user: 用户消息
 * - character: 角色消息(senderCharacterId 必填)
 * - narrator: 旁白/系统描述
 */
export type MessageSenderType = 'user' | 'character' | 'narrator';

/**
 * 消息可见范围(v11 多人世界私聊引入)。
 * - public: 公开发言,当前所有在场角色可知
 * - private: 私下交谈,仅 recipientCharacterIds 中的角色可知
 * - narrator: 旁白动作,作为场景描述处理,知情范围由参与者/目击者判断
 */
export type MessageVisibility = 'public' | 'private' | 'narrator';

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
  /**
   * 发送者类型(v10 多人世界引入)。
   * - 'user': 用户消息(默认,旧消息兼容)
   * - 'character': 角色消息,senderCharacterId 必填
   * - 'narrator': 旁白消息
   */
  readonly senderType?: MessageSenderType;
  /** 角色消息时填入 character.id;user/narrator 消息留空 */
  readonly senderCharacterId?: string;
  /** 所属场景 ID(v10 多人世界,可选) */
  readonly sceneId?: string;
  /** 生成批次 ID(同一轮多角色消息共享同一批次) */
  readonly generationBatchId?: string;
  /**
   * 消息可见范围(v11 私聊引入,可选,默认 'public')。
   * - 'public': 公开发言
   * - 'private': 私下交谈(仅 recipientCharacterIds 可见)
   * - 'narrator': 旁白动作
   */
  readonly visibility?: MessageVisibility;
  /**
   * 私聊目标角色 ID 列表(v11 私聊引入)。
   * 仅 visibility='private' 时有效;为空表示公开消息或旁白消息。
   */
  readonly recipientCharacterIds?: string[];
  /**
   * 参与者角色 ID 列表(v11 私聊引入)。
   * 包含用户(以 'user' 占位)与所有参与该消息的角色。
   * 用于记忆事件的 participantIds 字段。
   */
  readonly participantIds?: string[];
  /**
   * 目击者角色 ID 列表(v11 私聊引入)。
   * 用于旁白动作或私聊被目击的场景,默认为空。
   */
  readonly witnessIds?: string[];
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
