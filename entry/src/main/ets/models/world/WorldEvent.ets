/**
 * WorldEvent 世界事件日志模型
 *
 * W-DATA-1A 引入。表示某个 World 中的结构化事件记录。
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 *
 * 设计:
 * - WorldEvent 是结构化世界事件日志,不是聊天消息
 * - 事件默认不可更新(追加式记录)
 * - sourceSceneId / sourceMessageId 当前可空,为后续场景阶段保留关联能力
 * - payloadJson 不得存储完整角色卡 / 完整 Prompt / 聊天正文
 *
 * 持久化到 world_events 表。
 */

import { nowMillis } from '../../utils/Time';

export enum WorldEventType {
  WorldCreated = 'world_created',
  WorldUpdated = 'world_updated',
  WorldArchived = 'world_archived',
  LocationCreated = 'location_created',
  LocationUpdated = 'location_updated',
  LocationArchived = 'location_archived',
  LocationDeleted = 'location_deleted',
  EdgeCreated = 'edge_created',
  EdgeUpdated = 'edge_updated',
  EdgeDeleted = 'edge_deleted',
  CharacterJoined = 'character_joined',
  CharacterRemoved = 'character_removed'
}

export const WORLD_EVENT_ID_PREFIX: string = 'world-event-';

export interface WorldEvent {
  /** 事件 ID(以 'world-event-' 前缀开头) */
  readonly id: string;
  /** 所属世界 ID */
  readonly worldId: string;
  /** 事件类型 */
  readonly eventType: WorldEventType;
  /** 源角色实例 ID(可空) */
  readonly sourceCharacterInstanceId?: string;
  /** 源地点 ID(可空) */
  readonly sourceLocationId?: string;
  /** 目标地点 ID(可空) */
  readonly targetLocationId?: string;
  /** 源场景 ID(可空,为后续场景阶段保留) */
  readonly sourceSceneId?: string;
  /** 源消息 ID(可空,为后续场景阶段保留) */
  readonly sourceMessageId?: string;
  /** 事件摘要 */
  readonly summary: string;
  /** 结构化负载 JSON(不得存储完整角色卡 / Prompt / 聊天正文) */
  readonly payloadJson?: string;
  /** 事件发生时间(毫秒) */
  readonly occurredAt: number;
  /** 记录创建时间(毫秒) */
  readonly createdAt: number;
}

export interface CreateWorldEventOptions {
  readonly id: string;
  readonly worldId: string;
  readonly eventType: WorldEventType;
  readonly sourceCharacterInstanceId?: string;
  readonly sourceLocationId?: string;
  readonly targetLocationId?: string;
  readonly sourceSceneId?: string;
  readonly sourceMessageId?: string;
  readonly summary?: string;
  readonly payloadJson?: string;
  readonly occurredAt?: number;
  readonly createdAt?: number;
}

const VALID_EVENT_TYPES: Set<string> = new Set<string>([
  WorldEventType.WorldCreated,
  WorldEventType.WorldUpdated,
  WorldEventType.WorldArchived,
  WorldEventType.LocationCreated,
  WorldEventType.LocationUpdated,
  WorldEventType.LocationArchived,
  WorldEventType.LocationDeleted,
  WorldEventType.EdgeCreated,
  WorldEventType.EdgeUpdated,
  WorldEventType.EdgeDeleted,
  WorldEventType.CharacterJoined,
  WorldEventType.CharacterRemoved
]);

/**
 * 校验字符串是否为合法 WorldEventType。
 */
export function isWorldEventType(value: string): boolean {
  return VALID_EVENT_TYPES.has(value);
}

/**
 * 创建 WorldEvent 记录。
 * - id / worldId / eventType 不能为空
 * - summary 默认空字符串
 * - occurredAt / createdAt 默认当前时间
 * - 可空字段传 undefined 或空字符串视为未指定
 */
export function createWorldEventRecord(
  options: CreateWorldEventOptions
): WorldEvent {
  if (options.id === '') {
    throw new Error('WorldEvent: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldEvent: worldId empty');
  }
  if (!isWorldEventType(options.eventType)) {
    throw new Error(`WorldEvent: eventType invalid: ${options.eventType}`);
  }
  const now: number = nowMillis();
  return {
    id: options.id,
    worldId: options.worldId,
    eventType: options.eventType,
    sourceCharacterInstanceId: normalizeOptional(options.sourceCharacterInstanceId),
    sourceLocationId: normalizeOptional(options.sourceLocationId),
    targetLocationId: normalizeOptional(options.targetLocationId),
    sourceSceneId: normalizeOptional(options.sourceSceneId),
    sourceMessageId: normalizeOptional(options.sourceMessageId),
    summary: options.summary !== undefined ? options.summary : '',
    payloadJson: normalizeOptional(options.payloadJson),
    occurredAt: options.occurredAt !== undefined ? options.occurredAt : now,
    createdAt: options.createdAt !== undefined ? options.createdAt : now
  };
}

function normalizeOptional(value: string | undefined): string | undefined {
  if (value === undefined || value === '') {
    return undefined;
  }
  return value;
}
