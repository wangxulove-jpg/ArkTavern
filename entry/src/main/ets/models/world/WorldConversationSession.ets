import { nowMillis } from '../../utils/Time';

export const WORLD_CONVERSATION_SESSION_ID_PREFIX: string = 'world-conversation-session-';

export enum WorldConversationSessionStatus {
  Active = 'active',
  Ended = 'ended'
}

export interface WorldSessionParticipantSnapshot {
  readonly characterInstanceId: string;
  readonly displayNameSnapshot: string;
  readonly locationIdAtStart?: string;
  readonly isActiveAtStart: boolean;
  readonly joinedAt: number;
  readonly leftAt?: number;
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

export function validateParticipantSnapshots(
  participants: ReadonlyArray<WorldSessionParticipantSnapshot>
): void {
  const seenIds: Set<string> = new Set<string>();
  for (let i = 0; i < participants.length; i++) {
    const p: WorldSessionParticipantSnapshot = participants[i];
    const trimmedId: string = p.characterInstanceId.trim();
    if (trimmedId === '') {
      throw new Error('WorldSessionParticipantSnapshot: characterInstanceId empty');
    }
    if (trimmedId === 'user') {
      throw new Error('WorldSessionParticipantSnapshot: characterInstanceId must not be literal "user"');
    }
    const trimmedName: string = p.displayNameSnapshot.trim();
    if (trimmedName === '') {
      throw new Error('WorldSessionParticipantSnapshot: displayNameSnapshot empty');
    }
    if (p.locationIdAtStart !== undefined) {
      const trimmedLoc: string = p.locationIdAtStart.trim();
      if (trimmedLoc === '') {
        throw new Error('WorldSessionParticipantSnapshot: locationIdAtStart empty after trim');
      }
    }
    if (seenIds.has(trimmedId)) {
      throw new Error(`WorldSessionParticipantSnapshot: duplicate characterInstanceId=${trimmedId}`);
    }
    seenIds.add(trimmedId);
    if (!isValidTimestamp(p.joinedAt)) {
      throw new Error('WorldSessionParticipantSnapshot: joinedAt invalid');
    }
    if (p.leftAt !== undefined) {
      if (!isValidTimestamp(p.leftAt)) {
        throw new Error('WorldSessionParticipantSnapshot: leftAt invalid');
      }
      if (p.leftAt < p.joinedAt) {
        throw new Error('WorldSessionParticipantSnapshot: leftAt earlier than joinedAt');
      }
    }
  }
}

export function serializeParticipantSnapshots(
  participants: ReadonlyArray<WorldSessionParticipantSnapshot>
): string {
  const arr: Object[] = [];
  for (let i = 0; i < participants.length; i++) {
    const p: WorldSessionParticipantSnapshot = participants[i];
    const obj: Record<string, Object> = {};
    obj['characterInstanceId'] = p.characterInstanceId.trim();
    obj['displayNameSnapshot'] = p.displayNameSnapshot.trim();
    if (p.locationIdAtStart !== undefined) {
      obj['locationIdAtStart'] = p.locationIdAtStart;
    }
    obj['isActiveAtStart'] = p.isActiveAtStart;
    obj['joinedAt'] = p.joinedAt;
    if (p.leftAt !== undefined) {
      obj['leftAt'] = p.leftAt;
    }
    arr.push(obj);
  }
  return JSON.stringify(arr);
}

export function deserializeParticipantSnapshots(
  json: string
): WorldSessionParticipantSnapshot[] {
  let parsed: Object[];
  try {
    parsed = JSON.parse(json) as Object[];
  } catch (_e) {
    throw new Error('WorldSessionParticipantSnapshot: failed to parse JSON');
  }
  if (!Array.isArray(parsed)) {
    throw new Error('WorldSessionParticipantSnapshot: JSON root is not an array');
  }
  const result: WorldSessionParticipantSnapshot[] = [];
  for (let i = 0; i < parsed.length; i++) {
    const item: Object = parsed[i];
    if (typeof item !== 'object' || item === null) {
      throw new Error(`WorldSessionParticipantSnapshot: entry[${i}] is not an object`);
    }
    const record: Record<string, Object> = item as Record<string, Object>;
    const characterInstanceId: Object | undefined = record['characterInstanceId'];
    const displayNameSnapshot: Object | undefined = record['displayNameSnapshot'];
    const locationIdAtStart: Object | undefined = record['locationIdAtStart'];
    const isActiveAtStart: Object | undefined = record['isActiveAtStart'];
    const joinedAt: Object | undefined = record['joinedAt'];
    const leftAt: Object | undefined = record['leftAt'];
    if (typeof characterInstanceId !== 'string') {
      throw new Error(`WorldSessionParticipantSnapshot: entry[${i}].characterInstanceId missing or not string`);
    }
    if (typeof displayNameSnapshot !== 'string') {
      throw new Error(`WorldSessionParticipantSnapshot: entry[${i}].displayNameSnapshot missing or not string`);
    }
    if (typeof isActiveAtStart !== 'boolean') {
      throw new Error(`WorldSessionParticipantSnapshot: entry[${i}].isActiveAtStart missing or not boolean`);
    }
    if (typeof joinedAt !== 'number') {
      throw new Error(`WorldSessionParticipantSnapshot: entry[${i}].joinedAt missing or not number`);
    }
    const snapshot: WorldSessionParticipantSnapshot = {
      characterInstanceId: characterInstanceId,
      displayNameSnapshot: displayNameSnapshot,
      locationIdAtStart: typeof locationIdAtStart === 'string' ? locationIdAtStart : undefined,
      isActiveAtStart: isActiveAtStart,
      joinedAt: joinedAt,
      leftAt: typeof leftAt === 'number' ? leftAt : undefined
    };
    result.push(snapshot);
  }
  validateParticipantSnapshots(result);
  return result;
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
  let participantSnapshotJson: string;
  if (options.participantSnapshotJson !== undefined && options.participantSnapshotJson !== '') {
    const validated: WorldSessionParticipantSnapshot[] =
      deserializeParticipantSnapshots(options.participantSnapshotJson);
    participantSnapshotJson = serializeParticipantSnapshots(validated);
  } else {
    participantSnapshotJson = '[]';
  }
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
