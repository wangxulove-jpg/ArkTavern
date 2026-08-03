/**
 * GroupRoundTypes 多人聊天轮次运行时类型(G-RUNTIME-1A / G-RUNTIME-1B / G-RUNTIME-1C / G-CONTROL-1)
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
 *
 * G-RUNTIME-1C:
 * - 新增 GroupSpeakerRetryContext:重试单角色的运行时上下文
 * - 新增 GroupSpeakerRetryError:重试前置校验失败异常
 * - 重试不进入新一轮次,但复用原 roundId / generationBatchId
 * - 重试创建新 operationId / assistantMessageId / ChatStreamHandle
 * - 重试只生成一次,不自动继续后续角色
 *
 * G-CONTROL-2A:
 * - GroupReplyTargetMode 扩展为 AllEnabled / SelectedCharacters(多目标)
 * - 原 SingleCharacter 统一为 SelectedCharacters([characterId])
 * - GroupRoundPlan.replyTarget 记录本轮回复目标
 * - SelectedCharacters 模式下 speakers 只含目标角色(按 speakerOrder 排序)
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
 * 回复目标模式(G-CONTROL-2A)。
 *
 * - AllEnabled:所有启用且有效成员按 speakerOrder 依次回复(默认)
 * - SelectedCharacters:仅由用户指定的 1～N 个角色按 speakerOrder 回复
 *
 * G-CONTROL-2A:原 SingleCharacter 已统一为 SelectedCharacters([characterId])。
 * 正式运行时不维护三套分支,单目标视为多目标的特例。
 */
export enum GroupReplyTargetMode {
  AllEnabled = 'all_enabled',
  SelectedCharacters = 'selected_characters'
}

/**
 * 回复目标(G-CONTROL-2A)。
 *
 * 运行时始终使用 characterId,角色名称只用于 UI 显示。
 * SelectedCharacters 模式下 characterIds 非空(length >= 1)。
 *
 * 规则:
 * - ID 不为空
 * - ID 不重复
 * - 顺序不代表生成顺序(生成顺序始终由 speakerOrder 决定)
 * - 第一版最多 8 个目标,不超过当前群聊有效启用成员数
 */
export interface GroupReplyTarget {
  readonly mode: GroupReplyTargetMode;
  /** SelectedCharacters 模式下的目标角色 ID 列表;AllEnabled 模式为空数组 */
  readonly characterIds: string[];
}

/** 默认全员回复目标 */
export const REPLY_TARGET_ALL_ENABLED: GroupReplyTarget = {
  mode: GroupReplyTargetMode.AllEnabled,
  characterIds: []
};

/**
 * 构造指定角色回复目标(G-CONTROL-2A)。
 * 自动去重和过滤空 ID。
 */
export function selectedCharactersReplyTarget(characterIds: string[]): GroupReplyTarget {
  const seen: Set<string> = new Set<string>();
  const result: string[] = [];
  for (let i = 0; i < characterIds.length; i++) {
    const id: string = characterIds[i];
    if (id.length === 0) {
      continue;
    }
    if (seen.has(id)) {
      continue;
    }
    seen.add(id);
    result.push(id);
  }
  return { mode: GroupReplyTargetMode.SelectedCharacters, characterIds: result };
}

/**
 * 判断目标是否为单角色(SelectedCharacters 且 length=1)。
 * 用于兼容 G-CONTROL-1 单角色 UI 显示逻辑。
 */
export function isSingleCharacterTarget(target: GroupReplyTarget): boolean {
  return target.mode === GroupReplyTargetMode.SelectedCharacters
    && target.characterIds.length === 1;
}

/**
 * 判断目标是否为多角色(SelectedCharacters 且 length>1)。
 */
export function isMultiCharacterTarget(target: GroupReplyTarget): boolean {
  return target.mode === GroupReplyTargetMode.SelectedCharacters
    && target.characterIds.length > 1;
}

/**
 * 轮次计划(Ready 状态的不可变快照)。
 *
 * 一旦建立,本轮期间成员顺序与集合不变。
 * 后续修改群聊成员只影响下一轮。
 *
 * G-CONTROL-1:
 * - replyTarget 记录本轮回复目标模式
 * - SingleCharacter 模式下 speakers 只含目标角色
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
  /** G-CONTROL-2A: 回复目标(AllEnabled 或 SelectedCharacters) */
  readonly replyTarget: GroupReplyTarget;
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
  Internal = 'internal',
  /** G-CONTROL-2A: 目标角色不存在(已删除) */
  TargetCharacterNotFound = 'target_character_not_found',
  /** G-CONTROL-2A: 目标角色已不属于当前群聊 */
  TargetCharacterNotInChat = 'target_character_not_in_chat',
  /** G-CONTROL-2A: 目标角色已停用 */
  TargetCharacterNotEnabled = 'target_character_not_enabled',
  /** G-CONTROL-2A: 目标角色 ID 列表为空 */
  TargetCharacterIdsEmpty = 'target_character_ids_empty',
  /** G-CONTROL-2A: 目标角色数量超过上限 */
  TargetCharacterIdsExceedLimit = 'target_character_ids_exceed_limit'
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

// ===== G-RUNTIME-1C 重试相关类型 =====

/**
 * 单角色重试上下文(G-RUNTIME-1C)。
 *
 * 用于在原轮次已结束(Idle/Completed/Cancelled/Failed)时,
 * 对单条 Failed / Cancelled 角色消息发起一次重新生成。
 *
 * 语义:
 * - originalOperationId:原失败轮次的 operationId(用于日志追溯,不参与校验)
 * - roundId:原轮次 ID(等同 generationBatchId,新消息写入同一批次)
 * - chatId:所属群聊 ID(必须与原消息一致)
 * - speakerIndex:发言顺序(用于 UI 显示成员状态)
 * - speakerCharacterId:发言角色 ID(必须与原消息 senderCharacterId 一致)
 * - failedMessageId:被重试的原消息 ID(保留作为历史,不覆盖)
 *
 * 不变量:
 * - 新消息使用同一 roundId / generationBatchId
 * - 新消息使用新的 messageId / operationId / ChatStreamHandle
 * - 原失败消息正文不删除
 * - 重试只生成一次,完成后不自动启动后续角色
 */
export interface GroupSpeakerRetryContext {
  /** 原失败轮次的 operationId(日志追溯用) */
  readonly originalOperationId: number;
  /** 原轮次 ID(= generationBatchId) */
  readonly roundId: string;
  /** 所属群聊 ID */
  readonly chatId: string;
  /** 发言顺序(从 0 开始) */
  readonly speakerIndex: number;
  /** 发言角色 ID */
  readonly speakerCharacterId: string;
  /** 被重试的原消息 ID */
  readonly failedMessageId: string;
}

/**
 * 重试前置校验失败原因。
 */
export enum GroupSpeakerRetryErrorKind {
  /** 消息不存在 */
  MessageNotFound = 'message_not_found',
  /** 消息不属于当前群聊 */
  MessageNotInChat = 'message_not_in_chat',
  /** 不是角色消息 */
  NotCharacterMessage = 'not_character_message',
  /** 缺少 generationBatchId */
  MissingRoundId = 'missing_round_id',
  /** 消息状态不允许重试(Completed/Streaming) */
  InvalidStatusForRetry = 'invalid_status_for_retry',
  /** 当前有活动轮次,不能重试 */
  ActiveRoundExists = 'active_round_exists',
  /** 角色已被删除 */
  CharacterNotFound = 'character_not_found',
  /** 角色已不属于该群聊 */
  CharacterNotInChat = 'character_not_in_chat',
  /** 内部错误 */
  Internal = 'internal'
}

/**
 * 重试前置校验失败异常。
 */
export class GroupSpeakerRetryError extends Error {
  readonly kind: GroupSpeakerRetryErrorKind;

  constructor(kind: GroupSpeakerRetryErrorKind, message: string) {
    super(message);
    this.name = 'GroupSpeakerRetryError';
    this.kind = kind;
  }
}
