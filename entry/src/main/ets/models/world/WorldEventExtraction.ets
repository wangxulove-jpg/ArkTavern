import { nowMillis } from '../../utils/Time';

export const WORLD_EVENT_EXTRACTION_RUN_ID_PREFIX: string = 'world-event-extraction-run-';
export const WORLD_EVENT_ENTRY_ID_PREFIX: string = 'world-event-entry-';

export enum WorldEventExtractionRunStatus {
  Active = 'active',
  Superseded = 'superseded',
  Rejected = 'rejected'
}

export enum WorldEventEntryStatus {
  Active = 'active',
  Rejected = 'rejected'
}

export enum WorldEventKind {
  Action = 'action',
  Decision = 'decision',
  Commitment = 'commitment',
  StateChange = 'state_change',
  Discovery = 'discovery',
  Outcome = 'outcome',
  Other = 'other'
}

const VALID_RUN_STATUSES: Set<string> = new Set<string>([
  WorldEventExtractionRunStatus.Active,
  WorldEventExtractionRunStatus.Superseded,
  WorldEventExtractionRunStatus.Rejected
]);

const VALID_ENTRY_STATUSES: Set<string> = new Set<string>([
  WorldEventEntryStatus.Active,
  WorldEventEntryStatus.Rejected
]);

const VALID_EVENT_KINDS: Set<string> = new Set<string>([
  WorldEventKind.Action,
  WorldEventKind.Decision,
  WorldEventKind.Commitment,
  WorldEventKind.StateChange,
  WorldEventKind.Discovery,
  WorldEventKind.Outcome,
  WorldEventKind.Other
]);

export function isWorldEventExtractionRunStatus(value: string): boolean {
  return VALID_RUN_STATUSES.has(value);
}

export function isWorldEventEntryStatus(value: string): boolean {
  return VALID_ENTRY_STATUSES.has(value);
}

export function isWorldEventKind(value: string): boolean {
  return VALID_EVENT_KINDS.has(value);
}

export interface WorldEventExtractionRun {
  readonly id: string;
  readonly worldId: string;
  readonly sourceSceneId: string;
  readonly sourceSessionId: string;
  readonly sourceLocationId: string;
  readonly version: number;
  readonly sourceSummaryId: string;
  readonly sourceSummaryVersion: number;
  readonly sourceMessageIdsJson: string;
  readonly sourceMessageCount: number;
  readonly participantInstanceIdsJson: string;
  readonly playerDisplayNameSnapshot: string;
  readonly status: WorldEventExtractionRunStatus;
  readonly promptVersion: string;
  readonly providerId: string | undefined;
  readonly modelId: string | undefined;
  readonly createdAt: number;
  readonly statusUpdatedAt: number;
}

export interface CreateWorldEventExtractionRunOptions {
  readonly id: string;
  readonly worldId: string;
  readonly sourceSceneId: string;
  readonly sourceSessionId: string;
  readonly sourceLocationId: string;
  readonly version: number;
  readonly sourceSummaryId: string;
  readonly sourceSummaryVersion: number;
  readonly sourceMessageIdsJson: string;
  readonly sourceMessageCount: number;
  readonly participantInstanceIdsJson: string;
  readonly playerDisplayNameSnapshot: string;
  readonly status?: WorldEventExtractionRunStatus;
  readonly promptVersion: string;
  readonly providerId?: string;
  readonly modelId?: string;
  readonly createdAt?: number;
  readonly statusUpdatedAt?: number;
}

export interface WorldEventEntry {
  readonly id: string;
  readonly worldId: string;
  readonly extractionRunId: string;
  readonly sourceSceneId: string;
  readonly sourceSessionId: string;
  readonly sourceLocationId: string;
  readonly eventOrdinal: number;
  readonly eventKind: WorldEventKind;
  readonly eventText: string;
  readonly actorInstanceIdsJson: string;
  readonly playerInvolved: boolean;
  readonly evidenceMessageIdsJson: string;
  readonly witnessInstanceIdsJson: string;
  readonly confidence: number;
  readonly status: WorldEventEntryStatus;
  readonly createdAt: number;
  readonly statusUpdatedAt: number;
}

export interface CreateWorldEventEntryOptions {
  readonly id: string;
  readonly worldId: string;
  readonly extractionRunId: string;
  readonly sourceSceneId: string;
  readonly sourceSessionId: string;
  readonly sourceLocationId: string;
  readonly eventOrdinal: number;
  readonly eventKind: WorldEventKind;
  readonly eventText: string;
  readonly actorInstanceIdsJson: string;
  readonly playerInvolved: boolean;
  readonly evidenceMessageIdsJson: string;
  readonly witnessInstanceIdsJson: string;
  readonly confidence: number;
  readonly status?: WorldEventEntryStatus;
  readonly createdAt?: number;
  readonly statusUpdatedAt?: number;
}

export interface WorldEventSourceSnapshot {
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly locationId: string;
  readonly summaryId: string;
  readonly summaryVersion: number;
  readonly summaryText: string;
  readonly sourceMessageIds: string[];
  readonly participantCharacterInstanceIds: string[];
  readonly playerDisplayNameSnapshot: string;
  readonly messages: WorldEventSourceMessage[];
}

export interface WorldEventSourceMessage {
  readonly messageId: string;
  readonly sequenceNumber: number;
  readonly senderKind: string;
  readonly senderCharacterInstanceId: string | undefined;
  readonly senderDisplayNameSnapshot: string;
  readonly content: string;
  readonly participantCharacterInstanceIds: string[];
  readonly witnessCharacterInstanceIds: string[];
  readonly createdAt: number;
}

export interface WorldEventEntryDraft {
  readonly eventKind: WorldEventKind;
  readonly eventText: string;
  readonly actorCharacterInstanceIds: string[];
  readonly playerInvolved: boolean;
  readonly evidenceMessageIds: string[];
  readonly confidence: number;
}

export interface WorldEventExtractionResult {
  readonly run: WorldEventExtractionRun;
  readonly entries: WorldEventEntry[];
  readonly isExisting: boolean;
}

export interface ActiveExtractionInfo {
  readonly run: WorldEventExtractionRun;
  readonly entries: WorldEventEntry[];
  readonly isSourceCurrent: boolean;
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

export function createWorldEventExtractionRunRecord(
  options: CreateWorldEventExtractionRunOptions
): WorldEventExtractionRun {
  if (options.id === '') {
    throw new Error('WorldEventExtractionRun: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldEventExtractionRun: worldId empty');
  }
  if (options.sourceSceneId === '') {
    throw new Error('WorldEventExtractionRun: sourceSceneId empty');
  }
  if (options.sourceSessionId === '') {
    throw new Error('WorldEventExtractionRun: sourceSessionId empty');
  }
  if (options.sourceLocationId === '') {
    throw new Error('WorldEventExtractionRun: sourceLocationId empty');
  }
  if (!Number.isFinite(options.version) || !Number.isInteger(options.version) || options.version < 1) {
    throw new Error('WorldEventExtractionRun: version must be positive integer');
  }
  if (options.sourceSummaryId === '') {
    throw new Error('WorldEventExtractionRun: sourceSummaryId empty');
  }
  if (!Number.isFinite(options.sourceSummaryVersion) || !Number.isInteger(options.sourceSummaryVersion) || options.sourceSummaryVersion < 1) {
    throw new Error('WorldEventExtractionRun: sourceSummaryVersion must be positive integer');
  }
  if (!Number.isFinite(options.sourceMessageCount) || !Number.isInteger(options.sourceMessageCount) || options.sourceMessageCount < 0) {
    throw new Error('WorldEventExtractionRun: sourceMessageCount invalid');
  }
  if (options.promptVersion === '') {
    throw new Error('WorldEventExtractionRun: promptVersion empty');
  }
  const status: WorldEventExtractionRunStatus = options.status !== undefined
    ? options.status : WorldEventExtractionRunStatus.Active;
  if (!isWorldEventExtractionRunStatus(status)) {
    throw new Error(`WorldEventExtractionRun: status invalid: ${status}`);
  }
  const now: number = nowMillis();
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const statusUpdatedAt: number = options.statusUpdatedAt !== undefined ? options.statusUpdatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldEventExtractionRun: createdAt invalid');
  }
  if (!isValidTimestamp(statusUpdatedAt)) {
    throw new Error('WorldEventExtractionRun: statusUpdatedAt invalid');
  }
  return {
    id: options.id,
    worldId: options.worldId,
    sourceSceneId: options.sourceSceneId,
    sourceSessionId: options.sourceSessionId,
    sourceLocationId: options.sourceLocationId,
    version: options.version,
    sourceSummaryId: options.sourceSummaryId,
    sourceSummaryVersion: options.sourceSummaryVersion,
    sourceMessageIdsJson: options.sourceMessageIdsJson,
    sourceMessageCount: options.sourceMessageCount,
    participantInstanceIdsJson: options.participantInstanceIdsJson,
    playerDisplayNameSnapshot: options.playerDisplayNameSnapshot,
    status: status,
    promptVersion: options.promptVersion,
    providerId: options.providerId,
    modelId: options.modelId,
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}

export function createWorldEventEntryRecord(
  options: CreateWorldEventEntryOptions
): WorldEventEntry {
  if (options.id === '') {
    throw new Error('WorldEventEntry: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldEventEntry: worldId empty');
  }
  if (options.extractionRunId === '') {
    throw new Error('WorldEventEntry: extractionRunId empty');
  }
  if (options.sourceSceneId === '') {
    throw new Error('WorldEventEntry: sourceSceneId empty');
  }
  if (options.sourceSessionId === '') {
    throw new Error('WorldEventEntry: sourceSessionId empty');
  }
  if (options.sourceLocationId === '') {
    throw new Error('WorldEventEntry: sourceLocationId empty');
  }
  if (!Number.isFinite(options.eventOrdinal) || !Number.isInteger(options.eventOrdinal) || options.eventOrdinal < 0) {
    throw new Error('WorldEventEntry: eventOrdinal must be non-negative integer');
  }
  if (!isWorldEventKind(options.eventKind)) {
    throw new Error(`WorldEventEntry: eventKind invalid: ${options.eventKind}`);
  }
  if (options.eventText.trim() === '') {
    throw new Error('WorldEventEntry: eventText empty after trim');
  }
  if (!Number.isFinite(options.confidence) || options.confidence < 0 || options.confidence > 1) {
    throw new Error('WorldEventEntry: confidence must be finite 0..1');
  }
  const status: WorldEventEntryStatus = options.status !== undefined
    ? options.status : WorldEventEntryStatus.Active;
  if (!isWorldEventEntryStatus(status)) {
    throw new Error(`WorldEventEntry: status invalid: ${status}`);
  }
  const now: number = nowMillis();
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const statusUpdatedAt: number = options.statusUpdatedAt !== undefined ? options.statusUpdatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldEventEntry: createdAt invalid');
  }
  if (!isValidTimestamp(statusUpdatedAt)) {
    throw new Error('WorldEventEntry: statusUpdatedAt invalid');
  }
  return {
    id: options.id,
    worldId: options.worldId,
    extractionRunId: options.extractionRunId,
    sourceSceneId: options.sourceSceneId,
    sourceSessionId: options.sourceSessionId,
    sourceLocationId: options.sourceLocationId,
    eventOrdinal: options.eventOrdinal,
    eventKind: options.eventKind,
    eventText: options.eventText,
    actorInstanceIdsJson: options.actorInstanceIdsJson,
    playerInvolved: options.playerInvolved,
    evidenceMessageIdsJson: options.evidenceMessageIdsJson,
    witnessInstanceIdsJson: options.witnessInstanceIdsJson,
    confidence: options.confidence,
    status: status,
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}
