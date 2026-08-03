/**
 * GroupChatUiModels 多人聊天正式 UI 数据模型(G-DATA-1B / G-RUNTIME-1A)
 *
 * 职责:
 * - 定义只服务于多人 UI 的 DTO,隔离数据库实体与 ArkUI 页面状态
 * - 集中定义跨页面路由 Key
 * - 集中定义页面状态枚举
 *
 * 不依赖:
 * - 数据库实体(Chat / ChatParticipant / Character)
 * - GroupChatPreviewModels(预览模型)
 * - ArkUI 装饰器
 *
 * 规则:
 * - 全部 readonly
 * - 不使用 any
 * - 缺失角色标记 characterExists=false,页面显示"角色已删除"
 */

import { ChatRole } from '../../models/ChatRole';
import { ChatMessageStatus } from '../../models/ChatMessage';

/** AppStorage 中待进入的群聊 ID(由首页/创建页写入,GroupChatPage 读取) */
export const PENDING_GROUP_CHAT_ID_KEY: string = 'pendingGroupChatId';

/** 多人聊天列表页状态 */
export enum GroupChatListState {
  Loading = 'loading',
  Ready = 'ready',
  Empty = 'empty',
  Error = 'error'
}

/** 多人聊天详情页状态 */
export enum GroupChatDetailState {
  Loading = 'loading',
  Ready = 'ready',
  NotFound = 'not_found',
  Error = 'error'
}

/** 角色选择页状态 */
export enum CharacterPickState {
  Loading = 'loading',
  Ready = 'ready',
  Empty = 'empty',
  Error = 'error'
}

/** 群聊成员 UI 模型 */
export interface GroupMemberUiModel {
  /** 角色 ID */
  readonly characterId: string;
  /** 角色名称(缺失角色显示"角色已删除") */
  readonly name: string;
  /** 头像 URI(缺失角色为空字符串,由 CharacterImageView 显示占位) */
  readonly avatarUri: string;
  /** 角色描述摘要(缺失角色为空) */
  readonly description: string;
  /** 发言顺序(从 0 开始) */
  readonly speakerOrder: number;
  /** 是否启用 */
  readonly isEnabled: boolean;
  /** 角色是否真实存在(false 表示角色已被删除) */
  readonly characterExists: boolean;
}

/** 群聊列表项 UI 模型 */
export interface GroupConversationListItemUiModel {
  readonly chatId: string;
  readonly title: string;
  /** 有序成员列表(全部成员,含停用) */
  readonly members: GroupMemberUiModel[];
  readonly memberCount: number;
  /** 最后消息预览(本阶段无真实多人消息,固定"还没有消息") */
  readonly lastMessagePreview: string;
  readonly updatedAt: number;
}

/** 群聊详情 UI 模型 */
export interface GroupConversationDetailUiModel {
  readonly chatId: string;
  readonly title: string;
  /** 有序成员列表(全部成员,含停用) */
  readonly members: GroupMemberUiModel[];
}

/**
 * 多人聊天消息 UI 模型(G-RUNTIME-1A / G-CONTROL-1 / G-CONTROL-2A)。
 *
 * 字段映射规则:
 * - 用户消息:senderCharacterId 为空,显示"我",右对齐
 * - AI 角色消息:通过 senderCharacterId 读取 Character,显示角色头像和名称,左对齐
 * - 已删除角色:显示"角色已删除",使用默认头像,保留历史消息正文
 *
 * G-CONTROL-2A:
 * - replyTargetCharacterIds:回复目标角色 ID 列表(用户消息)
 *   - 空数组:全员回复(默认)
 *   - 非空数组:仅指定角色按 speakerOrder 回复
 * - replyTargetNames:目标角色显示名称列表(与 IDs 一一对应,
 *   已删除角色显示"角色已删除"),用于用户消息下方标签
 *
 * 历史兼容:
 * - 旧 G-CONTROL-1 单角色消息迁移后 replyTargetCharacterIds 长度为 1
 * - 旧全员消息 replyTargetCharacterIds 为空数组
 */
export interface GroupMessageUiModel {
  /** 消息 ID */
  readonly id: string;
  /** 消息角色(system/user/assistant) */
  readonly role: ChatRole;
  /** 消息正文 */
  readonly content: string;
  /** 消息状态(Streaming/Completed/Cancelled/Failed) */
  readonly status: ChatMessageStatus;
  /** 发言角色 ID(用户消息为空) */
  readonly senderCharacterId?: string;
  /** 发言者显示名称(用户消息为"我",AI 消息为角色名,已删除角色为"角色已删除") */
  readonly senderName: string;
  /** 发言者头像 URI(缺失或用户消息为空) */
  readonly senderAvatarUri?: string;
  /** 角色是否真实存在(false 表示已删除) */
  readonly characterExists: boolean;
  /** 生成批次 ID(一轮多人回复共享) */
  readonly generationBatchId?: string;
  /** 序列号(用于稳定排序) */
  readonly sequenceNumber: number;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
  /** G-CONTROL-2A: 回复目标角色 ID 列表(用户消息,全员回复为空数组) */
  readonly replyTargetCharacterIds: string[];
  /** G-CONTROL-2A: 目标角色显示名称列表(用户消息下方标签,全员回复为空数组) */
  readonly replyTargetNames: string[];
}

/** 多人聊天消息列表状态 */
export enum GroupMessageListState {
  Loading = 'loading',
  Ready = 'ready',
  Empty = 'empty',
  Error = 'error'
}

/**
 * 群聊成员运行时状态(G-RUNTIME-1B / G-CONTROL-1 / G-CONTROL-2A)。
 *
 * 用于成员栏显示当前角色的运行状态:
 * - Idle:未参与本轮或本轮未开始
 * - Waiting:等待前序角色完成
 * - Generating:正在生成
 * - Completed:已完成
 * - Cancelled:已取消(停止)
 * - Failed:生成失败
 * - NotParticipating:G-CONTROL-2A 有限成员轮次中未选中的启用成员
 *   (本轮不参与生成,但不是 Disabled,区别于停用成员)
 */
export enum GroupMemberRuntimeState {
  Idle = 'idle',
  Waiting = 'waiting',
  Generating = 'generating',
  Completed = 'completed',
  Cancelled = 'cancelled',
  Failed = 'failed',
  NotParticipating = 'not_participating'
}

/**
 * 群聊成员运行时 UI 模型(G-RUNTIME-1B)。
 * 在成员栏显示当前角色在本轮中的运行状态。
 */
export interface GroupMemberRuntimeUiModel {
  /** 角色 ID */
  readonly characterId: string;
  /** 角色名称(缺失角色显示"角色已删除") */
  readonly name: string;
  /** 头像 URI */
  readonly avatarUri: string;
  /** 发言顺序 */
  readonly speakerIndex: number;
  /** 运行时状态 */
  readonly runtimeState: GroupMemberRuntimeState;
  /** 角色是否真实存在 */
  readonly characterExists: boolean;
}

/** 用户消息显示名称 */
export const USER_MESSAGE_SENDER_NAME: string = '我';

/** 可添加角色 UI 模型(成员管理页"添加角色"弹窗用) */
export interface AddableCharacterUiModel {
  readonly characterId: string;
  readonly name: string;
  readonly avatarUri: string;
  readonly description: string;
}

/**
 * 格式化时间戳为 MM-DD HH:mm(与 ChatSessionListViewModel 一致)。
 */
export function formatGroupTimestamp(ts: number): string {
  if (ts <= 0) {
    return '';
  }
  const d: Date = new Date(ts);
  const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
  const day: string = d.getDate().toString().padStart(2, '0');
  const hour: string = d.getHours().toString().padStart(2, '0');
  const minute: string = d.getMinutes().toString().padStart(2, '0');
  return month + '-' + day + ' ' + hour + ':' + minute;
}

/** 缺失角色显示名称 */
export const DELETED_CHARACTER_NAME: string = '角色已删除';

/** 无消息时的固定预览文本 */
export const NO_MESSAGE_PREVIEW: string = '还没有消息';
