import { nowMillis } from '../../utils/Time';

export const WORLD_PLAYER_PROFILE_ID_PREFIX: string = 'world-player-profile-';

export interface WorldPlayerProfile {
  readonly id: string;
  readonly worldId: string;
  readonly displayName: string;
  /** 玩家人设(W2A1) */
  readonly persona: string;
  /** 公开身份(W2A1) */
  readonly publicIdentity: string;
  /** 私密身份(W2A1) */
  readonly privateIdentity: string;
  /** 当前位置 ID,可空表示未放置(W2A1) */
  readonly currentLocationId?: string;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface CreateWorldPlayerProfileOptions {
  readonly id: string;
  readonly worldId: string;
  readonly displayName: string;
  readonly persona?: string;
  readonly publicIdentity?: string;
  readonly privateIdentity?: string;
  readonly currentLocationId?: string;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

export function createWorldPlayerProfileRecord(
  options: CreateWorldPlayerProfileOptions
): WorldPlayerProfile {
  if (options.id === '') {
    throw new Error('WorldPlayerProfile: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldPlayerProfile: worldId empty');
  }
  const trimmed: string = options.displayName.trim();
  if (trimmed === '') {
    throw new Error('WorldPlayerProfile: displayName empty after trim');
  }
  const now: number = nowMillis();
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const updatedAt: number = options.updatedAt !== undefined ? options.updatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldPlayerProfile: createdAt invalid');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw new Error('WorldPlayerProfile: updatedAt invalid');
  }
  const locationId: string | undefined =
    options.currentLocationId !== undefined && options.currentLocationId !== ''
      ? options.currentLocationId
      : undefined;
  return {
    id: options.id,
    worldId: options.worldId,
    displayName: trimmed,
    persona: options.persona !== undefined ? options.persona : '',
    publicIdentity: options.publicIdentity !== undefined ? options.publicIdentity : '',
    privateIdentity: options.privateIdentity !== undefined ? options.privateIdentity : '',
    currentLocationId: locationId,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}
