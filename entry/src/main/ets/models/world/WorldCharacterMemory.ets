/**
 * WorldCharacterMemory 世界角色实例独立长期记忆模型
 *
 * W-MEMORY-1A 引入。表示某个 WorldCharacterInstance 在某个 World 中的独立长期记忆。
 *
 * 所有权:
 * - 记忆严格属于 WorldCharacterInstance(characterInstanceId)
 * - 不属于 Character 模板、WorldLocation、WorldScene、Chat、Lorebook
 * - 角色从地点 A 移动到地点 B:实例 ID 不变 → 记忆保持
 * - 实例从世界移除:同事务删除该实例全部记忆
 * - 删除 World:同事务删除该 World 全部记忆
 *
 * 来源字段语义(软历史引用):
 * - sourceSceneId / sourceMessageId:仅 origin=SceneMessage 时存在;本阶段 UI 不创建
 * - sourceLocationId:记忆发生在哪里,可空;不表示角色当前位置
 * - 来源引用失效时记忆仍保留,UI 安全降级显示"地点已删除"等
 *
 * 本阶段 UI 创建的记忆固定:
 * - origin = Manual
 * - status = Active
 *
 * SceneMessage origin 为下一阶段自动提取保留,本阶段不通过 UI 创建。
 *
 * 持久化到 world_character_memories 表(V17)。
 */

import { nowMillis } from '../../utils/Time';

/** 记忆类型 */
export enum WorldCharacterMemoryType {
  /** 角色经历过的具体事件 */
  Episodic = 'episodic',
  /** 角色认为成立的事实或认知 */
  Semantic = 'semantic',
  /** 角色对经历的总结、判断或长期看法 */
  Reflection = 'reflection'
}

/** 记忆来源 */
export enum WorldCharacterMemoryOrigin {
  /** 用户手动创建(本阶段唯一来源) */
  Manual = 'manual',
  /** 从场景消息自动提取(下一阶段保留,本阶段不创建) */
  SceneMessage = 'scene_message'
}

/** 记忆状态 */
export enum WorldCharacterMemoryStatus {
  /** 活跃(默认) */
  Active = 'active',
  /** 已归档(仍保留来源和正文) */
  Archived = 'archived'
}

export const WORLD_CHARACTER_MEMORY_ID_PREFIX: string = 'world-character-memory-';

/** 重要度下限(含) */
export const WORLD_CHARACTER_MEMORY_IMPORTANCE_MIN: number = 1;
/** 重要度上限(含) */
export const WORLD_CHARACTER_MEMORY_IMPORTANCE_MAX: number = 5;
/** 正文长度上限 */
export const WORLD_CHARACTER_MEMORY_CONTENT_MAX: number = 2000;

export interface WorldCharacterMemory {
  /** 记忆 ID(以 'world-character-memory-' 前缀开头) */
  readonly id: string;
  /** 所属世界 ID */
  readonly worldId: string;
  /** 所属角色实例 ID(记忆所有者) */
  readonly characterInstanceId: string;

  /** 记忆类型 */
  readonly type: WorldCharacterMemoryType;
  /** 记忆来源 */
  readonly origin: WorldCharacterMemoryOrigin;
  /** 记忆状态 */
  readonly status: WorldCharacterMemoryStatus;

  /** 记忆正文 */
  readonly content: string;
  /** 重要度(1-5) */
  readonly importance: number;

  /** 来源场景 ID(可空,仅 origin=SceneMessage 时存在) */
  readonly sourceSceneId?: string;
  /** 来源场景消息 ID(可空,仅 origin=SceneMessage 时存在) */
  readonly sourceMessageId?: string;
  /** 来源地点 ID(可空,表示记忆发生地点,不表示角色当前位置) */
  readonly sourceLocationId?: string;
  /** 发生时间(可空,毫秒时间戳) */
  readonly occurredAt?: number;

  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateWorldCharacterMemoryOptions {
  readonly id: string;
  readonly worldId: string;
  readonly characterInstanceId: string;
  readonly type: WorldCharacterMemoryType;
  readonly origin?: WorldCharacterMemoryOrigin;
  readonly status?: WorldCharacterMemoryStatus;
  readonly content: string;
  readonly importance: number;
  readonly sourceSceneId?: string;
  readonly sourceMessageId?: string;
  readonly sourceLocationId?: string;
  readonly occurredAt?: number;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

/**
 * 创建 WorldCharacterMemory 记录。
 * - id / worldId / characterInstanceId / content 不能为空
 * - type 必须为合法枚举值
 * - importance 必须在 [1, 5] 范围内
 * - origin 默认 Manual
 * - status 默认 Active
 * - createdAt / updatedAt 默认当前时间
 * - 可选字段 undefined 或空字符串视为未指定
 */
export function createWorldCharacterMemoryRecord(
  options: CreateWorldCharacterMemoryOptions
): WorldCharacterMemory {
  if (options.id === '') {
    throw new Error('WorldCharacterMemory: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldCharacterMemory: worldId empty');
  }
  if (options.characterInstanceId === '') {
    throw new Error('WorldCharacterMemory: characterInstanceId empty');
  }
  if (!isWorldCharacterMemoryType(options.type)) {
    throw new Error('WorldCharacterMemory: invalid type');
  }
  if (options.content === '') {
    throw new Error('WorldCharacterMemory: content empty');
  }
  if (!isWorldCharacterMemoryImportance(options.importance)) {
    throw new Error('WorldCharacterMemory: importance out of range');
  }
  const now: number = nowMillis();
  const origin: WorldCharacterMemoryOrigin = options.origin !== undefined
    ? options.origin : WorldCharacterMemoryOrigin.Manual;
  const status: WorldCharacterMemoryStatus = options.status !== undefined
    ? options.status : WorldCharacterMemoryStatus.Active;
  return {
    id: options.id,
    worldId: options.worldId,
    characterInstanceId: options.characterInstanceId,
    type: options.type,
    origin: origin,
    status: status,
    content: options.content,
    importance: options.importance,
    sourceSceneId: normalizeOptionalId(options.sourceSceneId),
    sourceMessageId: normalizeOptionalId(options.sourceMessageId),
    sourceLocationId: normalizeOptionalId(options.sourceLocationId),
    occurredAt: normalizeOptionalTimestamp(options.occurredAt),
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}

/** 判断字符串是否为合法 WorldCharacterMemoryType */
export function isWorldCharacterMemoryType(value: string): boolean {
  return value === WorldCharacterMemoryType.Episodic
    || value === WorldCharacterMemoryType.Semantic
    || value === WorldCharacterMemoryType.Reflection;
}

/** 判断字符串是否为合法 WorldCharacterMemoryOrigin */
export function isWorldCharacterMemoryOrigin(value: string): boolean {
  return value === WorldCharacterMemoryOrigin.Manual
    || value === WorldCharacterMemoryOrigin.SceneMessage;
}

/** 判断字符串是否为合法 WorldCharacterMemoryStatus */
export function isWorldCharacterMemoryStatus(value: string): boolean {
  return value === WorldCharacterMemoryStatus.Active
    || value === WorldCharacterMemoryStatus.Archived;
}

/** 判断数值是否为合法重要度 [1, 5] */
export function isWorldCharacterMemoryImportance(value: number): boolean {
  return Number.isInteger(value)
    && value >= WORLD_CHARACTER_MEMORY_IMPORTANCE_MIN
    && value <= WORLD_CHARACTER_MEMORY_IMPORTANCE_MAX;
}

/** 规范化可选 ID:undefined 或空字符串视为未指定 */
function normalizeOptionalId(value?: string): string | undefined {
  if (value === undefined || value === '') {
    return undefined;
  }
  return value;
}

/** 规范化可选时间戳:undefined 或非正数视为未指定 */
function normalizeOptionalTimestamp(value?: number): number | undefined {
  if (value === undefined || !Number.isFinite(value) || value <= 0) {
    return undefined;
  }
  return value;
}
