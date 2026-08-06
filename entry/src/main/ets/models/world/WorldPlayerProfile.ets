import { nowMillis } from '../../utils/Time';

export const WORLD_PLAYER_PROFILE_ID_PREFIX: string = 'world-player-profile-';

export interface WorldPlayerProfile {
  readonly id: string;
  readonly worldId: string;
  readonly displayName: string;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface CreateWorldPlayerProfileOptions {
  readonly id: string;
  readonly worldId: string;
  readonly displayName: string;
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
  return {
    id: options.id,
    worldId: options.worldId,
    displayName: trimmed,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}
