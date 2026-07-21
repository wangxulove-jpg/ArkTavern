/**
 * WorldMemory 世界记忆模型
 *
 * 多人世界记忆分为:
 * 1. 世界公共记忆(WorldMemoryEvent):所有在场角色可知
 * 2. 角色私人记忆(WorldPrivateMemory):仅角色自己可知
 *
 * 可见性分级:
 * - public: 所有角色可知
 * - participants: 仅参与事件的角色可知
 * - private: 仅 subject 角色可知
 * - narrator_only: 仅旁白可知
 *
 * 设计约束:
 * - 角色回复时只能注入:公共事实 + 自己参与/目击/被告知的事件 + 自己的私人记忆
 * - 禁止注入其他角色的私人秘密和内心评价
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

export type MemoryVisibility = 'public' | 'participants' | 'private' | 'narrator_only';

/**
 * 世界记忆事件(公共 + 受限可见)。
 */
export interface WorldMemoryEvent {
  readonly id: string;
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly sceneId: string | null;
  /** 直接参与事件的角色 */
  readonly participantIds: string[];
  /** 目击事件的角色 */
  readonly witnessIds: string[];
  /** 被告知事件的角色 */
  readonly informedCharacterIds: string[];
  /** 事件主体角色 */
  readonly subjectCharacterId: string | null;
  /** 相关角色 */
  readonly relatedCharacterIds: string[];
  readonly visibility: MemoryVisibility;
  readonly summary: string;
  readonly startMessageId: string | null;
  readonly endMessageId: string | null;
  readonly enabled: boolean;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface CreateWorldMemoryEventOptions {
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly sceneId?: string | null;
  readonly participantIds?: string[];
  readonly witnessIds?: string[];
  readonly informedCharacterIds?: string[];
  readonly subjectCharacterId?: string | null;
  readonly relatedCharacterIds?: string[];
  readonly visibility?: MemoryVisibility;
  readonly summary: string;
  readonly startMessageId?: string | null;
  readonly endMessageId?: string | null;
  readonly enabled?: boolean;
}

export function createWorldMemoryEvent(
  options: CreateWorldMemoryEventOptions
): WorldMemoryEvent {
  const now: number = nowMillis();
  return {
    id: generateUuid(),
    worldId: options.worldId,
    chatId: options.chatId,
    branchId: options.branchId,
    sceneId: options.sceneId !== undefined ? options.sceneId : null,
    participantIds: options.participantIds !== undefined ? [...options.participantIds] : [],
    witnessIds: options.witnessIds !== undefined ? [...options.witnessIds] : [],
    informedCharacterIds: options.informedCharacterIds !== undefined
      ? [...options.informedCharacterIds] : [],
    subjectCharacterId: options.subjectCharacterId !== undefined
      ? options.subjectCharacterId : null,
    relatedCharacterIds: options.relatedCharacterIds !== undefined
      ? [...options.relatedCharacterIds] : [],
    visibility: options.visibility !== undefined ? options.visibility : 'public',
    summary: options.summary,
    startMessageId: options.startMessageId !== undefined ? options.startMessageId : null,
    endMessageId: options.endMessageId !== undefined ? options.endMessageId : null,
    enabled: options.enabled !== undefined ? options.enabled : true,
    createdAt: now,
    updatedAt: now
  };
}

/**
 * 角色私人记忆(仅角色自己可知)。
 */
export interface WorldPrivateMemory {
  readonly id: string;
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly characterId: string;
  readonly sceneId: string | null;
  readonly summary: string;
  readonly startMessageId: string | null;
  readonly endMessageId: string | null;
  readonly enabled: boolean;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface CreateWorldPrivateMemoryOptions {
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly characterId: string;
  readonly sceneId?: string | null;
  readonly summary: string;
  readonly startMessageId?: string | null;
  readonly endMessageId?: string | null;
  readonly enabled?: boolean;
}

export function createWorldPrivateMemory(
  options: CreateWorldPrivateMemoryOptions
): WorldPrivateMemory {
  const now: number = nowMillis();
  return {
    id: generateUuid(),
    worldId: options.worldId,
    chatId: options.chatId,
    branchId: options.branchId,
    characterId: options.characterId,
    sceneId: options.sceneId !== undefined ? options.sceneId : null,
    summary: options.summary,
    startMessageId: options.startMessageId !== undefined ? options.startMessageId : null,
    endMessageId: options.endMessageId !== undefined ? options.endMessageId : null,
    enabled: options.enabled !== undefined ? options.enabled : true,
    createdAt: now,
    updatedAt: now
  };
}

export function parseVisibility(value: string): MemoryVisibility {
  if (value === 'public' || value === 'participants' ||
      value === 'private' || value === 'narrator_only') {
    return value;
  }
  return 'public';
}

/**
 * 判断指定角色是否可知某事件。
 * - public: 任何角色可知
 * - participants: 仅参与/目击/被告知的角色可知
 * - private: 仅 subject 角色可知
 * - narrator_only: 任何角色不可知
 */
export function canCharacterKnowEvent(
  event: WorldMemoryEvent,
  characterId: string
): boolean {
  if (event.visibility === 'public') {
    return true;
  }
  if (event.visibility === 'narrator_only') {
    return false;
  }
  if (event.visibility === 'private') {
    return event.subjectCharacterId === characterId;
  }
  // participants
  if (event.participantIds.indexOf(characterId) >= 0) {
    return true;
  }
  if (event.witnessIds.indexOf(characterId) >= 0) {
    return true;
  }
  if (event.informedCharacterIds.indexOf(characterId) >= 0) {
    return true;
  }
  return false;
}
