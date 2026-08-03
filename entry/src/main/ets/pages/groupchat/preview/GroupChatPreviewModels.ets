/**
 * GroupChatPreviewModels 多人聊天静态预览模型
 *
 * G-UI-1 阶段专用:仅用于 UI 原型,不写入正式领域模型目录(models/)。
 * 不参与数据库、Provider、Service。
 *
 * 后续 G-DATA-1 接入真实数据时,本文件将被替换为正式领域模型,
 * 届时删除本文件并迁移到 models/。
 *
 * 说明:字段未使用 readonly,以便预览状态容器(GroupChatPreviewStore)
 * 通过 clone 后修改副本的方式实现状态更新(ArkTS 不支持对象展开)。
 */

/** 成员在本轮中的预览状态 */
export enum GroupMemberPreviewStatus {
  /** 等待发言 */
  Waiting = 'waiting',
  /** 正在生成回复 */
  Generating = 'generating',
  /** 已完成回复 */
  Completed = 'completed',
  /** 回复失败 */
  Failed = 'failed',
  /** 在本群聊中已停用 */
  Disabled = 'disabled'
}

/** 本轮整体预览状态 */
export enum GroupRoundPreviewStatus {
  /** 空闲,等待用户发送 */
  Idle = 'idle',
  /** 正在按顺序生成 */
  Generating = 'generating',
  /** 本轮全部完成 */
  Completed = 'completed',
  /** 用户手动停止 */
  Cancelled = 'cancelled',
  /** 本轮失败 */
  Failed = 'failed'
}

/** 回复方式(本阶段仅支持顺序回复) */
export enum GroupReplyMode {
  /** 按成员顺序依次回复 */
  Sequential = 'sequential'
}

/** 失败处理方式 */
export enum GroupFailurePolicy {
  /** 停止整轮 */
  StopRound = 'stop_round',
  /** 跳过失败成员并继续 */
  SkipAndContinue = 'skip_and_continue'
}

/** 预览角色(静态,不来自数据库) */
export interface GroupChatPreviewCharacter {
  id: string;
  name: string;
  description: string;
  avatarUri: string;
}

/** 群聊成员(基于预览角色 + 顺序 + 状态) */
export interface GroupChatPreviewMember {
  id: string;
  characterId: string;
  name: string;
  avatarUri: string;
  order: number;
  status: GroupMemberPreviewStatus;
  enabled: boolean;
}

/** 单条预览消息 */
export interface GroupChatPreviewMessage {
  id: string;
  /** 发送者类型:user=用户,character=角色 */
  senderKind: 'user' | 'character';
  /** 角色消息时的角色 ID(用户消息为空) */
  senderCharacterId: string;
  /** 发送者显示名称 */
  senderName: string;
  /** 头像 URI(用户消息为空) */
  avatarUri: string;
  /** 消息正文 */
  content: string;
  /** 消息状态:streaming / completed / cancelled / failed */
  status: string;
  /** 创建时间戳(ms) */
  createdAt: number;
  /** 更新时间戳(ms) */
  updatedAt: number;
}

/** 群聊会话预览 */
export interface GroupChatPreviewSession {
  id: string;
  title: string;
  members: GroupChatPreviewMember[];
  messages: GroupChatPreviewMessage[];
  roundStatus: GroupRoundPreviewStatus;
  /** 当前正在生成的成员 order(无生成时为 -1) */
  currentGeneratingOrder: number;
  /** 本轮已完成回复的成员数 */
  completedCount: number;
  /** 本轮应回复的成员总数 */
  totalCount: number;
  /** 回复方式 */
  replyMode: GroupReplyMode;
  /** 失败处理方式 */
  failurePolicy: GroupFailurePolicy;
  /** 更新时间戳(ms) */
  updatedAt: number;
}
