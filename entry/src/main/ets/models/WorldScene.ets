/**
 * WorldScene 世界场景模型
 *
 * 表示世界中的一个具体场景(地点 + 时间)。
 * - 场景切换时,离场角色不应知道离场期间事件
 * - presentCharacterIds 记录场景在场角色
 * - status: 'active' 当前 / 'archived' 历史
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

export type WorldSceneStatus = 'active' | 'archived';

export interface WorldScene {
  readonly id: string;
  readonly worldId: string;
  readonly name: string;
  readonly location: string;
  readonly timeDescription: string;
  readonly description: string;
  readonly presentCharacterIds: string[];
  readonly importantObjects: string[];
  readonly status: WorldSceneStatus;
  readonly createdAt: number;
}

export interface CreateWorldSceneOptions {
  readonly id?: string;
  readonly worldId: string;
  readonly name?: string;
  readonly location?: string;
  readonly timeDescription?: string;
  readonly description?: string;
  readonly presentCharacterIds?: string[];
  readonly importantObjects?: string[];
  readonly status?: WorldSceneStatus;
  readonly createdAt?: number;
}

export interface WorldSceneUpdates {
  readonly name?: string;
  readonly location?: string;
  readonly timeDescription?: string;
  readonly description?: string;
  readonly presentCharacterIds?: string[];
  readonly importantObjects?: string[];
  readonly status?: WorldSceneStatus;
}

export function createWorldScene(options: CreateWorldSceneOptions): WorldScene {
  const now: number = nowMillis();
  return {
    id: options.id !== undefined ? options.id : generateUuid(),
    worldId: options.worldId,
    name: options.name !== undefined ? options.name : '',
    location: options.location !== undefined ? options.location : '',
    timeDescription: options.timeDescription !== undefined ? options.timeDescription : '',
    description: options.description !== undefined ? options.description : '',
    presentCharacterIds: options.presentCharacterIds !== undefined
      ? [...options.presentCharacterIds] : [],
    importantObjects: options.importantObjects !== undefined
      ? [...options.importantObjects] : [],
    status: options.status !== undefined ? options.status : 'active',
    createdAt: options.createdAt !== undefined ? options.createdAt : now
  };
}

export function updateWorldScene(
  scene: WorldScene,
  updates: WorldSceneUpdates
): WorldScene {
  return {
    id: scene.id,
    worldId: scene.worldId,
    name: updates.name !== undefined ? updates.name : scene.name,
    location: updates.location !== undefined ? updates.location : scene.location,
    timeDescription: updates.timeDescription !== undefined
      ? updates.timeDescription : scene.timeDescription,
    description: updates.description !== undefined ? updates.description : scene.description,
    presentCharacterIds: updates.presentCharacterIds !== undefined
      ? [...updates.presentCharacterIds] : scene.presentCharacterIds,
    importantObjects: updates.importantObjects !== undefined
      ? [...updates.importantObjects] : scene.importantObjects,
    status: updates.status !== undefined ? updates.status : scene.status,
    createdAt: scene.createdAt
  };
}

export function parseSceneStatus(value: string): WorldSceneStatus {
  if (value === 'active' || value === 'archived') {
    return value;
  }
  return 'active';
}
