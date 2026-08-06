import { nowMillis } from '../../utils/Time';

export const WORLD_CONVERSATION_SESSION_ID_PREFIX: string = 'world-conversation-session-';

export enum WorldConversationSessionStatus {
  Active = 'active',
  Ended = 'ended'
}

export interface ParticipantSnapshot {
  readonly characterInstanceId: string;
  readonly displayName: string;
  readonly locationId: string;
}

export interface WorldConversationSession {
  readonly id: string;
  readonly worldId: string;
  readonly sceneId: string;
  readonly sequenceNumber: number;
  readonly status: WorldConversationSessionStatus;
  readonly participantSnapshotJson: string;
  readonly playerDisplayNameSnapshot: string;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface CreateWorldConversationSessionOptions {
  readonly id: string;
  readonly worldId: string;
  readonly sceneId: string;
  readonly sequenceNumber: number;
  readonly status?: WorldConversationSessionStatus;
  readonly participantSnapshotJson?: string;
  readonly playerDisplayNameSnapshot?: string;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

const VALID_SESSION_STATUSES: Set<string> = new Set<string>([
  WorldConversationSessionStatus.Active,
  WorldConversationSessionStatus.Ended
]);

export function isWorldConversationSessionStatus(value: string): boolean {
  return VALID_SESSION_STATUSES.has(value);
}

export function createWorldConversationSessionRecord(
  options: CreateWorldConversationSessionOptions
): WorldConversationSession {
  if (options.id === '') {
    throw new Error('WorldConversationSession: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldConversationSession: worldId empty');
  }
  if (options.sceneId === '') {
    throw new Error('WorldConversationSession: sceneId empty');
  }
  if (!Number.isFinite(options.sequenceNumber) || !Number.isInteger(options.sequenceNumber) || options.sequenceNumber < 0) {
    throw new Error('WorldConversationSession: sequenceNumber invalid');
  }
  const status: WorldConversationSessionStatus = options.status !== undefined
    ? options.status : WorldConversationSessionStatus.Active;
  if (!isWorldConversationSessionStatus(status)) {
    throw new Error(`WorldConversationSession: status invalid: ${status}`);
  }
  const participantSnapshotJson: string = options.participantSnapshotJson !== undefined
    ? options.participantSnapshotJson : '[]';
  const playerDisplayNameSnapshot: string = options.playerDisplayNameSnapshot !== undefined
    ? options.playerDisplayNameSnapshot : '';
  const now: number = nowMillis();
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const updatedAt: number = options.updatedAt !== undefined ? options.updatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldConversationSession: createdAt invalid');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw new Error('WorldConversationSession: updatedAt invalid');
  }
  return {
    id: options.id,
    worldId: options.worldId,
    sceneId: options.sceneId,
    sequenceNumber: options.sequenceNumber,
    status: status,
    participantSnapshotJson: participantSnapshotJson,
    playerDisplayNameSnapshot: playerDisplayNameSnapshot,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}
