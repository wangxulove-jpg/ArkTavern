import { nowMillis } from '../../utils/Time';

export const WORLD_CHARACTER_MEMORY_ENTRY_ID_PREFIX: string = 'world-character-memory-entry-';

export enum WorldCharacterMemoryKind {
  EpisodicSession = 'episodic_session'
}

export enum WorldCharacterMemoryEntryStatus {
  Active = 'active',
  Superseded = 'superseded',
  Rejected = 'rejected'
}

export interface WorldCharacterMemoryEntry {
  readonly id: string;
  readonly worldId: string;
  readonly ownerCharacterInstanceId: string;
  readonly memoryKind: WorldCharacterMemoryKind;
  readonly sourceSceneId: string;
  readonly sourceSessionId: string;
  readonly sourceLocationId: string;
  readonly version: number;
  readonly memoryText: string;
  readonly sourceMessageIdsJson: string;
  readonly sourceMessageCount: number;
  readonly sourceParticipantInstanceIdsJson: string;
  readonly sourceWitnessInstanceIdsJson: string;
  readonly ownerDisplayNameSnapshot: string;
  readonly playerDisplayNameSnapshot: string;
  readonly confidence: number;
  readonly status: WorldCharacterMemoryEntryStatus;
  readonly promptVersion: string;
  readonly providerId: string | undefined;
  readonly modelId: string | undefined;
  readonly supersedesMemoryId: string | undefined;
  readonly createdAt: number;
  readonly statusUpdatedAt: number;
}

export interface CreateWorldCharacterMemoryEntryOptions {
  readonly id: string;
  readonly worldId: string;
  readonly ownerCharacterInstanceId: string;
  readonly memoryKind: WorldCharacterMemoryKind;
  readonly sourceSceneId: string;
  readonly sourceSessionId: string;
  readonly sourceLocationId: string;
  readonly version: number;
  readonly memoryText: string;
  readonly sourceMessageIdsJson: string;
  readonly sourceMessageCount: number;
  readonly sourceParticipantInstanceIdsJson: string;
  readonly sourceWitnessInstanceIdsJson: string;
  readonly ownerDisplayNameSnapshot: string;
  readonly playerDisplayNameSnapshot: string;
  readonly confidence: number;
  readonly promptVersion: string;
  readonly providerId?: string;
  readonly modelId?: string;
  readonly supersedesMemoryId?: string;
  readonly createdAt?: number;
  readonly statusUpdatedAt?: number;
}

export interface WorldCharacterMemorySourceMessage {
  readonly messageId: string;
  readonly sequenceNumber: number;
  readonly senderKind: string;
  readonly senderCharacterInstanceId: string | undefined;
  readonly senderDisplayNameSnapshot: string;
  readonly visibility: string;
  readonly recipientCharacterInstanceIds: string[] | undefined;
  readonly participantCharacterInstanceIds: string[] | undefined;
  readonly witnessCharacterInstanceIds: string[] | undefined;
  readonly content: string;
  readonly createdAt: number;
}

export interface WorldCharacterMemorySourceSnapshot {
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly locationId: string;
  readonly ownerCharacterInstanceId: string;
  readonly ownerDisplayNameSnapshot: string;
  readonly playerDisplayNameSnapshot: string;
  readonly participantCharacterInstanceIds: string[];
  readonly messages: ReadonlyArray<WorldCharacterMemorySourceMessage>;
  readonly sourceMessageIds: ReadonlyArray<string>;
  readonly sourceMessageCount: number;
  readonly sourceWitnessCharacterInstanceIds: string[];
}

const VALID_KINDS: Set<string> = new Set<string>([
  WorldCharacterMemoryKind.EpisodicSession
]);

const VALID_STATUSES: Set<string> = new Set<string>([
  WorldCharacterMemoryEntryStatus.Active,
  WorldCharacterMemoryEntryStatus.Superseded,
  WorldCharacterMemoryEntryStatus.Rejected
]);

export function isWorldCharacterMemoryKind(value: string): boolean {
  return VALID_KINDS.has(value);
}

export function isWorldCharacterMemoryEntryStatus(value: string): boolean {
  return VALID_STATUSES.has(value);
}

export function createWorldCharacterMemoryEntryRecord(
  options: CreateWorldCharacterMemoryEntryOptions
): WorldCharacterMemoryEntry {
  if (options.id === '') {
    throw new Error('WorldCharacterMemoryEntry: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldCharacterMemoryEntry: worldId empty');
  }
  if (options.ownerCharacterInstanceId === '') {
    throw new Error('WorldCharacterMemoryEntry: ownerCharacterInstanceId empty');
  }
  if (!isWorldCharacterMemoryKind(options.memoryKind)) {
    throw new Error(`WorldCharacterMemoryEntry: memoryKind invalid: ${options.memoryKind}`);
  }
  if (options.sourceSceneId === '') {
    throw new Error('WorldCharacterMemoryEntry: sourceSceneId empty');
  }
  if (options.sourceSessionId === '') {
    throw new Error('WorldCharacterMemoryEntry: sourceSessionId empty');
  }
  if (options.sourceLocationId === '') {
    throw new Error('WorldCharacterMemoryEntry: sourceLocationId empty');
  }
  if (!Number.isFinite(options.version) || !Number.isInteger(options.version) || options.version < 1) {
    throw new Error('WorldCharacterMemoryEntry: version must be positive integer');
  }
  if (options.memoryText.trim() === '') {
    throw new Error('WorldCharacterMemoryEntry: memoryText empty');
  }
  if (!Number.isFinite(options.confidence) || options.confidence < 0 || options.confidence > 1) {
    throw new Error('WorldCharacterMemoryEntry: confidence must be in [0.0, 1.0]');
  }
  if (options.promptVersion === '') {
    throw new Error('WorldCharacterMemoryEntry: promptVersion empty');
  }
  const now: number = nowMillis();
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const statusUpdatedAt: number = options.statusUpdatedAt !== undefined ? options.statusUpdatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldCharacterMemoryEntry: createdAt invalid');
  }
  if (!isValidTimestamp(statusUpdatedAt)) {
    throw new Error('WorldCharacterMemoryEntry: statusUpdatedAt invalid');
  }
  return {
    id: options.id,
    worldId: options.worldId,
    ownerCharacterInstanceId: options.ownerCharacterInstanceId,
    memoryKind: options.memoryKind,
    sourceSceneId: options.sourceSceneId,
    sourceSessionId: options.sourceSessionId,
    sourceLocationId: options.sourceLocationId,
    version: options.version,
    memoryText: options.memoryText,
    sourceMessageIdsJson: options.sourceMessageIdsJson,
    sourceMessageCount: options.sourceMessageCount,
    sourceParticipantInstanceIdsJson: options.sourceParticipantInstanceIdsJson,
    sourceWitnessInstanceIdsJson: options.sourceWitnessInstanceIdsJson,
    ownerDisplayNameSnapshot: options.ownerDisplayNameSnapshot,
    playerDisplayNameSnapshot: options.playerDisplayNameSnapshot,
    confidence: options.confidence,
    status: WorldCharacterMemoryEntryStatus.Active,
    promptVersion: options.promptVersion,
    providerId: options.providerId,
    modelId: options.modelId,
    supersedesMemoryId: options.supersedesMemoryId,
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

export enum WorldCharacterMemoryErrorKind {
  WorldNotFound = 'world_not_found',
  SceneNotFound = 'scene_not_found',
  SessionNotFound = 'session_not_found',
  SessionNotEnded = 'session_not_ended',
  OwnerNotFound = 'owner_not_found',
  OwnerWorldMismatch = 'owner_world_mismatch',
  OwnerNotSessionParticipant = 'owner_not_session_participant',
  InvalidSource = 'invalid_source',
  SourceChanged = 'source_changed',
  EmptyMemory = 'empty_memory',
  InvalidConfidence = 'invalid_confidence',
  InvalidStatusTransition = 'invalid_status_transition',
  DuplicateSourceMessageId = 'duplicate_source_message_id',
  MemoryPersistenceFailed = 'memory_persistence_failed'
}

export class WorldCharacterMemoryEntryError extends Error {
  readonly kind: WorldCharacterMemoryErrorKind;
  readonly cause: Object | null;

  constructor(kind: WorldCharacterMemoryErrorKind, message: string, cause: Object | null = null) {
    super(message);
    this.name = 'WorldCharacterMemoryEntryError';
    this.kind = kind;
    this.cause = cause;
  }
}
