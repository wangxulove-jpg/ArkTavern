/**
 * WorldScene 世界场景模型
 *
 * W-SCENE-1A 引入。表示某个 World 中某个 Location 上的一次场景。
 * 场景是世界模式独立的消息载体,不复用 chats / messages / chat_participants。
 *
 * 设计:
 * - Active: 允许后续 SceneService 写入新消息,endedAt 必须为空
 * - Ended: 场景已结束,只保留历史,endedAt 必须存在
 * - "同一地点最多一个 Active 场景"由 W-SCENE-1B WorldSceneService 保证,
 *   本阶段 Repository 不实现业务锁
 *
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 * 持久化到 world_scenes 表。
 */

import { nowMillis } from '../../utils/Time';

export enum WorldSceneStatus {
  Active = 'active',
  Ended = 'ended'
}

export const WORLD_SCENE_ID_PREFIX: string = 'world-scene-';

export interface WorldScene {
  readonly id: string;
  readonly worldId: string;
  readonly locationId: string;
  readonly title: string;
  readonly status: WorldSceneStatus;
  readonly startedAt: number;
  readonly endedAt?: number;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface CreateWorldSceneOptions {
  readonly id: string;
  readonly worldId: string;
  readonly locationId: string;
  readonly title?: string;
  readonly status?: WorldSceneStatus;
  readonly startedAt?: number;
  readonly endedAt?: number;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

export interface UpdateWorldSceneOptions {
  readonly title?: string;
  readonly status?: WorldSceneStatus;
  readonly endedAt?: number;
  readonly updatedAt?: number;
}

const VALID_SCENE_STATUSES: Set<string> = new Set<string>([
  WorldSceneStatus.Active,
  WorldSceneStatus.Ended
]);

/**
 * 校验字符串是否为合法 WorldSceneStatus。
 */
export function isWorldSceneStatus(value: string): boolean {
  return VALID_SCENE_STATUSES.has(value);
}

/**
 * 创建 WorldScene 记录。
 * - id / worldId / locationId 不能为空
 * - status 默认 Active
 * - startedAt 默认当前时间
 * - Active → endedAt 必须为空
 * - Ended → endedAt 必须存在且不早于 startedAt
 * - createdAt / updatedAt 默认当前时间
 */
export function createWorldSceneRecord(
  options: CreateWorldSceneOptions
): WorldScene {
  if (options.id === '') {
    throw new Error('WorldScene: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldScene: worldId empty');
  }
  if (options.locationId === '') {
    throw new Error('WorldScene: locationId empty');
  }
  const title: string = options.title !== undefined ? options.title.trim() : '';
  const status: WorldSceneStatus = options.status !== undefined
    ? options.status : WorldSceneStatus.Active;
  if (!isWorldSceneStatus(status)) {
    throw new Error(`WorldScene: status invalid: ${status}`);
  }
  const now: number = nowMillis();
  const startedAt: number = options.startedAt !== undefined ? options.startedAt : now;
  if (!isValidTimestamp(startedAt)) {
    throw new Error('WorldScene: startedAt invalid');
  }
  const endedAt: number | undefined = normalizeOptional(options.endedAt);
  if (status === WorldSceneStatus.Active) {
    if (endedAt !== undefined) {
      throw new Error('WorldScene: Active scene must not have endedAt');
    }
  } else {
    if (endedAt === undefined) {
      throw new Error('WorldScene: Ended scene must have endedAt');
    }
    if (!isValidTimestamp(endedAt)) {
      throw new Error('WorldScene: endedAt invalid');
    }
    if (endedAt < startedAt) {
      throw new Error('WorldScene: endedAt earlier than startedAt');
    }
  }
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const updatedAt: number = options.updatedAt !== undefined ? options.updatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldScene: createdAt invalid');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw new Error('WorldScene: updatedAt invalid');
  }
  return {
    id: options.id,
    worldId: options.worldId,
    locationId: options.locationId,
    title: title,
    status: status,
    startedAt: startedAt,
    endedAt: endedAt,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

function normalizeOptional(value: number | undefined): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (!Number.isFinite(value) || !Number.isInteger(value) || value <= 0) {
    return undefined;
  }
  return value;
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}
