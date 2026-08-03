/**
 * WorldLocation 世界地点模型
 *
 * W-DATA-1A 引入。表示某个 World 下的一个地点。
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 *
 * 设计:
 * - 同一 World 内 canonicalKey 唯一(UNIQUE)
 * - canonicalKey 第一版只用于保守的精确去重(trim + 大小写统一 + 连续空白折叠)
 * - 不做模糊合并、语义近似、拼音近似、编辑距离自动合并
 * - status 仅区分 active / archived
 *
 * 持久化到 world_locations 表。
 */

import { nowMillis } from '../../utils/Time';

export enum WorldLocationStatus {
  Active = 'active',
  Archived = 'archived'
}

export const WORLD_LOCATION_ID_PREFIX: string = 'world-location-';

export interface WorldLocation {
  /** 地点 ID(以 'world-location-' 前缀开头) */
  readonly id: string;
  /** 所属世界 ID */
  readonly worldId: string;
  /** 地点名称 */
  readonly name: string;
  /** 地点描述 */
  readonly description: string;
  /** 规范化键(用于精确去重) */
  readonly canonicalKey: string;
  /** 状态:active / archived */
  readonly status: WorldLocationStatus;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateWorldLocationOptions {
  readonly id: string;
  readonly worldId: string;
  readonly name: string;
  readonly description?: string;
  readonly canonicalKey: string;
  readonly status?: WorldLocationStatus;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

/**
 * 校验字符串是否为合法 WorldLocationStatus。
 */
export function isWorldLocationStatus(value: string): boolean {
  return value === WorldLocationStatus.Active || value === WorldLocationStatus.Archived;
}

/**
 * 生成 canonicalKey。
 * 仅做保守的精确标准化:trim + 大小写统一 + 连续空白折叠。
 * 不删除"旧"/"新"等前缀,不删除"酒馆"/"房间"等后缀,不做语义近似合并。
 *
 * 例如:
 * - "  酒馆  " → "酒馆"
 * - "旧 酒馆" → "旧 酒馆"(连续空白折叠为单个空格)
 * - "Tavern" / "tavern" / "TAVERN" → "tavern"
 */
export function buildCanonicalKey(rawName: string): string {
  if (rawName.length === 0) {
    return '';
  }
  // 1. trim 首尾空白
  const trimmed: string = rawName.trim();
  if (trimmed.length === 0) {
    return '';
  }
  // 2. 统一小写(用于精确去重,不影响显示)
  const lower: string = trimmed.toLowerCase();
  // 3. 连续空白折叠为单个空格
  return lower.replace(/\s+/g, ' ');
}

/**
 * 创建 WorldLocation 记录。
 * - id / worldId / name / canonicalKey 不能为空
 * - description 默认空字符串
 * - status 默认 Active
 * - createdAt / updatedAt 默认当前时间
 */
export function createWorldLocationRecord(
  options: CreateWorldLocationOptions
): WorldLocation {
  if (options.id === '') {
    throw new Error('WorldLocation: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldLocation: worldId empty');
  }
  if (options.name === '') {
    throw new Error('WorldLocation: name empty');
  }
  if (options.canonicalKey === '') {
    throw new Error('WorldLocation: canonicalKey empty');
  }
  const now: number = nowMillis();
  return {
    id: options.id,
    worldId: options.worldId,
    name: options.name,
    description: options.description !== undefined ? options.description : '',
    canonicalKey: options.canonicalKey,
    status: options.status !== undefined ? options.status : WorldLocationStatus.Active,
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}
