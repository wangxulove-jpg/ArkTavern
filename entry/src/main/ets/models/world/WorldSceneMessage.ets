/**
 * WorldSceneMessage 世界场景消息模型
 *
 * W-SCENE-1A 引入。场景消息是世界模式独立的消息流,不复用 chats / messages。
 *
 * 枚举独立定义,不直接依赖聊天模块枚举。
 *
 * 字段语义:
 * - senderCharacterInstanceId:
 *   - senderType=character 时必须非空,保存 WorldCharacterInstance.id
 *   - senderType=user/narrator 时必须为空
 * - visibility:
 *   - Public:当前地点公开消息,recipientCharacterInstanceIds 必须为空
 *   - Private:指定角色实例可知的私下消息,recipientCharacterInstanceIds 必须非空
 *   - Narrator:旁白或动作,recipientCharacterInstanceIds 必须为空,
 *     witnessCharacterInstanceIds 表示哪些角色感知(允许为空,表示仅用户主持者知道)
 * - participantCharacterInstanceIds:该消息或未来一轮的角色实例参与者快照
 *   不得加入 'user' 占位符
 * - replyTargetCharacterInstanceIds:仅表示公开用户消息希望哪些世界角色实例回复。
 *   只允许 senderType=user && visibility=public 时非空。与私聊接收者严格分离。
 * - generationBatchId:用于未来把同一轮多个角色回复关联起来,本阶段只存储和查询。
 * - sequenceNumber:每个 Scene 独立排序,UNIQUE(scene_id, sequence_number)。
 *
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 * 持久化到 world_scene_messages 表。
 */

import { nowMillis } from '../../utils/Time';

export enum WorldSceneMessageSenderType {
  User = 'user',
  Character = 'character',
  Narrator = 'narrator'
}

export enum WorldSceneMessageVisibility {
  Public = 'public',
  Private = 'private',
  Narrator = 'narrator'
}

export enum WorldSceneMessageStatus {
  Streaming = 'streaming',
  Completed = 'completed',
  Cancelled = 'cancelled',
  Failed = 'failed'
}

export const WORLD_SCENE_MESSAGE_ID_PREFIX: string = 'world-scene-msg-';

export interface WorldSceneMessage {
  /** 消息 ID(以 'world-scene-msg-' 前缀开头) */
  readonly id: string;
  /** 所属世界 ID */
  readonly worldId: string;
  /** 所属场景 ID */
  readonly sceneId: string;

  /** 发送者类型 */
  readonly senderType: WorldSceneMessageSenderType;
  /** 发送者角色实例 ID(仅 senderType=character 时非空) */
  readonly senderCharacterInstanceId?: string;

  /** 消息正文 */
  readonly content: string;
  /** 场景内序号(每 Scene 独立,UNIQUE(scene_id, sequence_number)) */
  readonly sequenceNumber: number;
  /** 消息状态 */
  readonly status: WorldSceneMessageStatus;
  /** 生成批次 ID(可空,用于关联同一轮多个角色回复) */
  readonly generationBatchId?: string;

  /** 可见范围 */
  readonly visibility: WorldSceneMessageVisibility;
  /** 私聊接收者角色实例 ID 列表(仅 Private 时非空) */
  readonly recipientCharacterInstanceIds?: string[];
  /** 参与者角色实例 ID 快照 */
  readonly participantCharacterInstanceIds?: string[];
  /** 旁白感知者角色实例 ID 列表(仅 Narrator 时允许) */
  readonly witnessCharacterInstanceIds?: string[];
  /** 公开用户消息希望哪些角色实例回复(仅 user+public 时允许) */
  readonly replyTargetCharacterInstanceIds?: string[];

  readonly sessionId?: string;
  readonly locationId?: string;

  readonly createdAt: number;
  /** 记录最后更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateWorldSceneMessageOptions {
  readonly id: string;
  readonly worldId: string;
  readonly sceneId: string;
  readonly senderType: WorldSceneMessageSenderType;
  readonly senderCharacterInstanceId?: string;
  readonly content?: string;
  readonly sequenceNumber: number;
  readonly status?: WorldSceneMessageStatus;
  readonly generationBatchId?: string;
  readonly visibility?: WorldSceneMessageVisibility;
  readonly recipientCharacterInstanceIds?: string[];
  readonly participantCharacterInstanceIds?: string[];
  readonly witnessCharacterInstanceIds?: string[];
  readonly replyTargetCharacterInstanceIds?: string[];
  readonly sessionId?: string;
  readonly locationId?: string;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

const VALID_SENDER_TYPES: Set<string> = new Set<string>([
  WorldSceneMessageSenderType.User,
  WorldSceneMessageSenderType.Character,
  WorldSceneMessageSenderType.Narrator
]);

const VALID_VISIBILITIES: Set<string> = new Set<string>([
  WorldSceneMessageVisibility.Public,
  WorldSceneMessageVisibility.Private,
  WorldSceneMessageVisibility.Narrator
]);

const VALID_STATUSES: Set<string> = new Set<string>([
  WorldSceneMessageStatus.Streaming,
  WorldSceneMessageStatus.Completed,
  WorldSceneMessageStatus.Cancelled,
  WorldSceneMessageStatus.Failed
]);

const TERMINAL_STATUSES: Set<string> = new Set<string>([
  WorldSceneMessageStatus.Completed,
  WorldSceneMessageStatus.Cancelled,
  WorldSceneMessageStatus.Failed
]);

/**
 * 校验字符串是否为合法 WorldSceneMessageSenderType。
 */
export function isWorldSceneMessageSenderType(value: string): boolean {
  return VALID_SENDER_TYPES.has(value);
}

/**
 * 校验字符串是否为合法 WorldSceneMessageVisibility。
 */
export function isWorldSceneMessageVisibility(value: string): boolean {
  return VALID_VISIBILITIES.has(value);
}

/**
 * 校验字符串是否为合法 WorldSceneMessageStatus。
 */
export function isWorldSceneMessageStatus(value: string): boolean {
  return VALID_STATUSES.has(value);
}

/**
 * 校验状态是否为终态(Completed / Cancelled / Failed)。
 */
export function isTerminalStatus(value: WorldSceneMessageStatus): boolean {
  return TERMINAL_STATUSES.has(value);
}

/**
 * 创建 WorldSceneMessage 记录。
 *
 * 校验:
 * - id / worldId / sceneId 非空
 * - sequenceNumber >= 0
 * - senderType / visibility / status 合法
 * - Character sender:senderCharacterInstanceId 必须非空
 * - User/Narrator sender:senderCharacterInstanceId 必须为空
 * - Private:recipientCharacterInstanceIds 必须非空
 * - Public/Narrator:recipientCharacterInstanceIds 必须为空
 * - Narrator:允许 witnessCharacterInstanceIds
 * - Public/Private:witnessCharacterInstanceIds 默认必须为空
 * - Reply target:只允许公开 User 消息携带
 *
 * 数组字段会被规范化:过滤空字符串、去重、稳定排序。
 */
export function createWorldSceneMessageRecord(
  options: CreateWorldSceneMessageOptions
): WorldSceneMessage {
  if (options.id === '') {
    throw new Error('WorldSceneMessage: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldSceneMessage: worldId empty');
  }
  if (options.sceneId === '') {
    throw new Error('WorldSceneMessage: sceneId empty');
  }
  if (!isWorldSceneMessageSenderType(options.senderType)) {
    throw new Error(`WorldSceneMessage: senderType invalid: ${options.senderType}`);
  }
  const visibility: WorldSceneMessageVisibility = options.visibility !== undefined
    ? options.visibility : WorldSceneMessageVisibility.Public;
  if (!isWorldSceneMessageVisibility(visibility)) {
    throw new Error(`WorldSceneMessage: visibility invalid: ${visibility}`);
  }
  const status: WorldSceneMessageStatus = options.status !== undefined
    ? options.status : WorldSceneMessageStatus.Completed;
  if (!isWorldSceneMessageStatus(status)) {
    throw new Error(`WorldSceneMessage: status invalid: ${status}`);
  }
  if (!Number.isFinite(options.sequenceNumber)
    || !Number.isInteger(options.sequenceNumber)
    || options.sequenceNumber < 0) {
    throw new Error('WorldSceneMessage: sequenceNumber invalid');
  }

  // senderCharacterInstanceId 语义校验
  const senderInstanceId: string | undefined = normalizeOptionalId(options.senderCharacterInstanceId);
  if (options.senderType === WorldSceneMessageSenderType.Character) {
    if (senderInstanceId === undefined) {
      throw new Error('WorldSceneMessage: Character sender must have senderCharacterInstanceId');
    }
  } else {
    if (senderInstanceId !== undefined) {
      throw new Error('WorldSceneMessage: User/Narrator sender must not have senderCharacterInstanceId');
    }
  }

  // recipient 语义校验
  const recipientIds: string[] | undefined = normalizeIdArray(options.recipientCharacterInstanceIds);
  if (visibility === WorldSceneMessageVisibility.Private) {
    if (recipientIds === undefined || recipientIds.length === 0) {
      throw new Error('WorldSceneMessage: Private visibility requires recipientCharacterInstanceIds');
    }
  } else {
    if (recipientIds !== undefined && recipientIds.length > 0) {
      throw new Error('WorldSceneMessage: Public/Narrator visibility must not have recipientCharacterInstanceIds');
    }
  }

  // witness 语义校验
  const witnessIds: string[] | undefined = normalizeIdArray(options.witnessCharacterInstanceIds);
  if (visibility !== WorldSceneMessageVisibility.Narrator) {
    if (witnessIds !== undefined && witnessIds.length > 0) {
      throw new Error('WorldSceneMessage: witness only allowed for Narrator visibility');
    }
  }

  // reply target 语义校验:只允许公开 User 消息携带
  const replyTargetIds: string[] | undefined = normalizeIdArray(options.replyTargetCharacterInstanceIds);
  if (replyTargetIds !== undefined && replyTargetIds.length > 0) {
    if (options.senderType !== WorldSceneMessageSenderType.User
      || visibility !== WorldSceneMessageVisibility.Public) {
      throw new Error('WorldSceneMessage: replyTarget only allowed for public User message');
    }
  }

  // participant:可选,不强制非空,但不得包含 'user'
  const participantIds: string[] | undefined = normalizeIdArray(options.participantCharacterInstanceIds);
  if (participantIds !== undefined && participantIds.length > 0) {
    for (let i = 0; i < participantIds.length; i++) {
      if (participantIds[i] === 'user') {
        throw new Error("WorldSceneMessage: participant must not contain 'user'");
      }
    }
  }

  const sessionId: string | undefined = normalizeSessionId(options.sessionId);
  const locationId: string | undefined = normalizeLocationId(options.locationId);
  if (sessionId !== undefined && locationId === undefined) {
    throw new Error('WorldSceneMessage: sessionId requires locationId');
  }
  if (locationId !== undefined && sessionId === undefined) {
    throw new Error('WorldSceneMessage: locationId requires sessionId');
  }

  const now: number = nowMillis();
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const updatedAt: number = options.updatedAt !== undefined ? options.updatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldSceneMessage: createdAt invalid');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw new Error('WorldSceneMessage: updatedAt invalid');
  }

  return {
    id: options.id,
    worldId: options.worldId,
    sceneId: options.sceneId,
    senderType: options.senderType,
    senderCharacterInstanceId: senderInstanceId,
    content: options.content !== undefined ? options.content : '',
    sequenceNumber: options.sequenceNumber,
    status: status,
    generationBatchId: normalizeOptionalId(options.generationBatchId),
    visibility: visibility,
    recipientCharacterInstanceIds: recipientIds,
    participantCharacterInstanceIds: participantIds,
    witnessCharacterInstanceIds: witnessIds,
    replyTargetCharacterInstanceIds: replyTargetIds,
    sessionId: sessionId,
    locationId: locationId,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 规范化 ID 数组:过滤空字符串、去重、稳定排序。
 * 空数组或全空输入返回 undefined(表示未指定)。
 */
export function normalizeIdArray(ids: string[] | undefined): string[] | undefined {
  if (ids === undefined) {
    return undefined;
  }
  const seen: Set<string> = new Set<string>();
  const result: string[] = [];
  for (let i = 0; i < ids.length; i++) {
    const id: string = ids[i];
    if (id === '') {
      continue;
    }
    if (seen.has(id)) {
      continue;
    }
    seen.add(id);
    result.push(id);
  }
  // 稳定排序(按字符串升序),保证写入 JSON 一致
  result.sort();
  return result.length > 0 ? result : undefined;
}

function normalizeOptionalId(value: string | undefined): string | undefined {
  if (value === undefined || value === '') {
    return undefined;
  }
  return value;
}

function normalizeSessionId(value: string | undefined): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  const trimmed: string = value.trim();
  if (trimmed === '') {
    throw new Error('WorldSceneMessage: sessionId empty after trim');
  }
  return trimmed;
}

function normalizeLocationId(value: string | undefined): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  const trimmed: string = value.trim();
  if (trimmed === '') {
    throw new Error('WorldSceneMessage: locationId empty after trim');
  }
  return trimmed;
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}
