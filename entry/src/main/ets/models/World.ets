/**
 * World 多人世界模型
 *
 * 一个 World 代表多个角色共同存在的世界设定。
 * - 每个 World 至少包含 2 个角色成员
 * - World 拥有独立的用户身份设定
 * - World 与 Chat 通过 WorldChatLink 关联
 * - 不存储消息正文,只存储世界设定
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

/**
 * 回复模式(v10 多人世界引入)。
 * - designated: 用户指定下一位回复者
 * - auto_director: 系统选择一至两位合适角色
 * - all_respond: 所有在场且未静音角色依次回应
 * - narrator_only: 仅生成场景描述
 */
export type WorldReplyMode = 'designated' | 'auto_director' | 'all_respond' | 'narrator_only';

/**
 * 用户在世界中的身份设定(只对当前世界生效)。
 */
export interface WorldUserIdentity {
  /** 用户名称 */
  readonly userName: string;
  /** 用户身份描述 */
  readonly identityDescription: string;
  /** 外貌或特征 */
  readonly appearance: string;
  /** 世界中的背景 */
  readonly background: string;
  /** 公开信息(他人可知) */
  readonly publicInfo: string;
  /** 私人信息(只有用户知道) */
  readonly privateInfo: string;
  /** 默认称呼(角色对用户的默认称呼,可被各角色覆盖) */
  readonly defaultAddressTerm: string;
}

/** 默认空身份 */
export const EMPTY_USER_IDENTITY: WorldUserIdentity = {
  userName: '',
  identityDescription: '',
  appearance: '',
  background: '',
  publicInfo: '',
  privateInfo: '',
  defaultAddressTerm: ''
};

/**
 * 多人世界模型。
 */
export interface World {
  readonly id: string;
  readonly name: string;
  readonly background: string;
  readonly initialScene: string;
  readonly userIdentity: WorldUserIdentity;
  readonly defaultReplyMode: WorldReplyMode;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface CreateWorldOptions {
  readonly id?: string;
  readonly name?: string;
  readonly background?: string;
  readonly initialScene?: string;
  readonly userIdentity?: WorldUserIdentity;
  readonly defaultReplyMode?: WorldReplyMode;
  readonly createdAt?: number;
}

export interface WorldUpdates {
  readonly name?: string;
  readonly background?: string;
  readonly initialScene?: string;
  readonly userIdentity?: WorldUserIdentity;
  readonly defaultReplyMode?: WorldReplyMode;
}

export function createWorld(options?: CreateWorldOptions): World {
  const now: number = nowMillis();
  const id: string = options !== undefined && options.id !== undefined
    ? options.id
    : generateUuid();
  const name: string = options !== undefined && options.name !== undefined
    ? options.name
    : '';
  const background: string = options !== undefined && options.background !== undefined
    ? options.background
    : '';
  const initialScene: string = options !== undefined && options.initialScene !== undefined
    ? options.initialScene
    : '';
  const userIdentity: WorldUserIdentity =
    options !== undefined && options.userIdentity !== undefined
      ? options.userIdentity
      : EMPTY_USER_IDENTITY;
  const defaultReplyMode: WorldReplyMode =
    options !== undefined && options.defaultReplyMode !== undefined
      ? options.defaultReplyMode
      : 'auto_director';
  const createdAt: number =
    options !== undefined && options.createdAt !== undefined
      ? options.createdAt
      : now;
  return {
    id: id,
    name: name,
    background: background,
    initialScene: initialScene,
    userIdentity: userIdentity,
    defaultReplyMode: defaultReplyMode,
    createdAt: createdAt,
    updatedAt: now
  };
}

export function updateWorld(world: World, updates: WorldUpdates): World {
  return {
    id: world.id,
    name: updates.name !== undefined ? updates.name : world.name,
    background: updates.background !== undefined ? updates.background : world.background,
    initialScene: updates.initialScene !== undefined ? updates.initialScene : world.initialScene,
    userIdentity: updates.userIdentity !== undefined ? updates.userIdentity : world.userIdentity,
    defaultReplyMode: updates.defaultReplyMode !== undefined
      ? updates.defaultReplyMode : world.defaultReplyMode,
    createdAt: world.createdAt,
    updatedAt: nowMillis()
  };
}

/**
 * 解析回复模式字符串。非法值回退为 auto_director。
 */
export function parseReplyMode(value: string): WorldReplyMode {
  if (value === 'designated' || value === 'auto_director' ||
      value === 'all_respond' || value === 'narrator_only') {
    return value;
  }
  return 'auto_director';
}

export function replyModeToString(mode: WorldReplyMode): string {
  return mode;
}
