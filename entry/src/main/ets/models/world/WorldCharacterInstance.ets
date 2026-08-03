/**
 * WorldCharacterInstance 世界角色实例模型
 *
 * W-DATA-1A 引入。表示某个 Character 在某个 World 中的动态实例。
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 *
 * 设计:
 * - Character = 可复用角色卡模板;WorldCharacterInstance = 某个世界中的角色动态实例
 * - 同一 World 内同一 Character 最多一个实例(UNIQUE(world_id, character_id))
 * - characterId 是对 characters.id 的软引用(不使用外键级联)
 * - displayNameSnapshot 仅用于列表显示 / 引用失效诊断 / 未来安全降级显示,
 *   不是角色卡完整快照
 * - currentLocationId 可空(未指定位置)
 * - 动态状态(位置、活跃、关系、记忆等)只存放世界实例或后续世界表,
 *   不写回 characters 表
 *
 * 运行时角色设定通过 CharacterService.getById(characterId) 读取。
 *
 * 持久化到 world_character_instances 表。
 */

import { nowMillis } from '../../utils/Time';

export const WORLD_CHARACTER_ID_PREFIX: string = 'world-character-';

export interface WorldCharacterInstance {
  /** 实例 ID(以 'world-character-' 前缀开头) */
  readonly id: string;
  /** 所属世界 ID */
  readonly worldId: string;
  /** 角色 ID(软引用 characters.id) */
  readonly characterId: string;
  /** 显示名称快照(仅用于列表显示 / 失效诊断) */
  readonly displayNameSnapshot: string;
  /** 当前位置 ID(可空) */
  readonly currentLocationId?: string;
  /** 是否活跃 */
  readonly isActive: boolean;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateWorldCharacterInstanceOptions {
  readonly id: string;
  readonly worldId: string;
  readonly characterId: string;
  readonly displayNameSnapshot: string;
  readonly currentLocationId?: string;
  readonly isActive?: boolean;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

/**
 * 创建 WorldCharacterInstance 记录。
 * - id / worldId / characterId / displayNameSnapshot 不能为空
 * - currentLocationId 可空(传 undefined 或空字符串视为未指定)
 * - isActive 默认 true
 * - createdAt / updatedAt 默认当前时间
 */
export function createWorldCharacterInstanceRecord(
  options: CreateWorldCharacterInstanceOptions
): WorldCharacterInstance {
  if (options.id === '') {
    throw new Error('WorldCharacterInstance: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldCharacterInstance: worldId empty');
  }
  if (options.characterId === '') {
    throw new Error('WorldCharacterInstance: characterId empty');
  }
  if (options.displayNameSnapshot === '') {
    throw new Error('WorldCharacterInstance: displayNameSnapshot empty');
  }
  const now: number = nowMillis();
  const locationId: string | undefined =
    options.currentLocationId !== undefined && options.currentLocationId !== ''
      ? options.currentLocationId
      : undefined;
  return {
    id: options.id,
    worldId: options.worldId,
    characterId: options.characterId,
    displayNameSnapshot: options.displayNameSnapshot,
    currentLocationId: locationId,
    isActive: options.isActive !== undefined ? options.isActive : true,
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}
