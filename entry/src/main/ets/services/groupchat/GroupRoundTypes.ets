/**
 * GroupRoundTypes 多人聊天轮次运行时类型(G-RUNTIME-1A / G-RUNTIME-1B)
 *
 * 职责:
 * - 定义多人聊天一轮回复所需的纯运行时类型
 * - 不依赖数据库 / ArkUI / Provider
 * - 不持久化(持久化字段写入 messages.generation_batch_id)
 *
 * 设计:
 * - generationBatchId 既是消息批次 ID,也是一轮 ID
 * - operationId 用于使旧轮次失效,避免迟到回调覆盖新状态
 * - 状态链:Idle → Planning → Ready → Generating → Completed/Cancelled/Failed
 *
 * 规则:
 * - 同一时间最多一个活动轮次
 * - 本轮成员快照建立后,本轮期间成员顺序与集合不变
 * - 已删除角色不进入 speakers
 * - 禁用成员不进入 speakers
 * - speakerIndex 从 0 连续
 */

/**
 * 多人轮次状态。
 *
 * - Idle:无活动轮次
 * - Planning:正在构建轮次计划(读取参与者、校验)
 * - Ready:计划已就绪,等待启动生成
 * - Generating:正在生成 AI 回复(严格顺序)
 * - Completed:本轮全部完成
 * - Cancelled:用户取消
 * - Failed:生成失败
 */
export enum GroupRoundState {
  Idle = 'idle',
  Planning = 'planning',
  Ready = 'ready',
  Generating = 'generating',
  Completed = 'completed',
  Cancelled = 'cancelled',
  Failed = 'failed'
}

/**
 * 本轮发言者(运行时快照中的一个角色槽位)。
 */
export interface GroupRoundSpeaker {
  /** 角色 ID */
  readonly characterId: string;
  /** 发言顺序(从 0 开始,与 speakerOrder 一致) */
  readonly speakerIndex: number;
}

/**
 * 轮次计划(Ready 状态的不可变快照)。
 *
 * 一旦建立,本轮期间成员顺序与集合不变。
 * 后续修改群聊成员只影响下一轮。
 */
export interface GroupRoundPlan {
  /** 操作 ID(用于使旧轮次失效) */
  readonly operationId: number;
  /** 轮次 ID(等同 generationBatchId) */
  readonly roundId: string;
  /** 所属群聊 ID */
  readonly chatId: string;
  /** 触发本轮的用户消息 ID */
  readonly userMessageId: string;
  /** 有序发言者列表(已排除停用与已删除角色) */
  readonly speakers: GroupRoundSpeaker[];
  /** 计划建立时间(毫秒) */
  readonly createdAt: number;
}

/**
 * 活动轮次上下文(Generating 阶段使用)。
 *
 * 在 Generating 期间持续存在,
 * 用于校验 delta / complete / error / stop 回调是否属于当前轮次。
 */
export interface ActiveGroupRoundContext {
  /** 操作 ID(与 GroupRoundPlan.operationId 对应) */
  readonly operationId: number;
  /** 轮次 ID */
  readonly roundId: string;
  /** 所属群聊 ID */
  readonly chatId: string;
  /** 触发本轮的用户消息 ID */
  readonly userMessageId: string;
  /** 有序发言者列表 */
  readonly speakers: GroupRoundSpeaker[];
  /** 当前发言者索引(Generating 阶段推进) */
  readonly currentSpeakerIndex: number;
  /** 当前发言者角色 ID */
  readonly currentSpeakerCharacterId: string;
  /** 当前 AI 消息 ID(Generating 阶段写入) */
  readonly currentAssistantMessageId?: string;
}

/**
 * 轮次规划失败原因。
 */
export enum GroupRoundPlanErrorKind {
  /** 群聊不存在 */
  ChatNotFound = 'chat_not_found',
  /** 不是群聊 */
  NotGroupChat = 'not_group_chat',
  /** 启用成员不足 2 人 */
  InsufficientEnabledMembers = 'insufficient_enabled_members',
  /** 可用角色不足 2 人(排除已删除角色后) */
  InsufficientAvailableSpeakers = 'insufficient_available_speakers',
  /** 用户消息不存在 */
  UserMessageNotFound = 'user_message_not_found',
  /** 当前已有活动轮次 */
  ActiveRoundExists = 'active_round_exists',
  /** 内部错误 */
  Internal = 'internal'
}

/**
 * 轮次规划失败异常(纯运行时,不持久化)。
 */
export class GroupRoundPlanError extends Error {
  readonly kind: GroupRoundPlanErrorKind;

  constructor(kind: GroupRoundPlanErrorKind, message: string) {
    super(message);
    this.name = 'GroupRoundPlanError';
    this.kind = kind;
  }
}
