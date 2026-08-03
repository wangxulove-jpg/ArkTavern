/**
 * World 世界模式根模型
 *
 * W-DATA-1A 引入。表示一个独立的世界模式数据域根。
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 *
 * 设计:
 * - World 是独立数据域,不复用 chats / messages / chat_participants
 * - World 仅持有世界级元信息,动态状态由 WorldCharacterInstance / WorldEvent 等承载
 * - status 仅区分 active / archived,不表达世界内部运行态
 *
 * 持久化到 worlds 表。
 */

import { nowMillis } from '../../utils/Time';

export enum WorldStatus {
  Active = 'active',
  Archived = 'archived'
}

export const WORLD_ID_PREFIX: string = 'world-';

export interface World {
  /** 世界 ID(以 'world-' 前缀开头) */
  readonly id: string;
  /** 世界名称 */
  readonly name: string;
  /** 世界设定摘要 */
  readonly description: string;
  /** 状态:active / archived */
  readonly status: WorldStatus;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateWorldOptions {
  readonly id: string;
  readonly name: string;
  readonly description?: string;
  readonly status?: WorldStatus;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

/**
 * 校验字符串是否为合法 WorldStatus。
 */
export function isWorldStatus(value: string): boolean {
  return value === WorldStatus.Active || value === WorldStatus.Archived;
}

/**
 * 创建 World 记录。
 * - id 不能为空
 * - name 不能为空
 * - description 默认空字符串
 * - status 默认 Active
 * - createdAt / updatedAt 默认当前时间
 */
export function createWorldRecord(options: CreateWorldOptions): World {
  if (options.id === '') {
    throw new Error('World: id empty');
  }
  if (options.name === '') {
    throw new Error('World: name empty');
  }
  const now: number = nowMillis();
  return {
    id: options.id,
    name: options.name,
    description: options.description !== undefined ? options.description : '',
    status: options.status !== undefined ? options.status : WorldStatus.Active,
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}
