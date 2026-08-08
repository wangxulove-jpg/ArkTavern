import { nowMillis } from '../../utils/Time';

export const WORLD_KNOWN_EVENT_ENTRY_ID_PREFIX: string = 'world-known-event-';

export enum WorldKnownEventSourceKind {
  EvidenceWitness = 'evidence_witness'
}

export enum WorldKnownEventEntryStatus {
  Active = 'active',
  Rejected = 'rejected'
}

export enum WorldKnownEventErrorKind {
  UnknownWitness = 'unknown_witness',
  StaleExtraction = 'stale_extraction',
  EmptyEvidenceMessageIds = 'empty_evidence_message_ids',
  DuplicateIdentity = 'duplicate_identity'
}

const VALID_SOURCE_KINDS: Set<string> = new Set<string>([
  WorldKnownEventSourceKind.EvidenceWitness
]);

const VALID_STATUSES: Set<string> = new Set<string>([
  WorldKnownEventEntryStatus.Active,
  WorldKnownEventEntryStatus.Rejected
]);

export function isWorldKnownEventSourceKind(value: string): boolean {
  return VALID_SOURCE_KINDS.has(value);
}

export function isWorldKnownEventEntryStatus(value: string): boolean {
  return VALID_STATUSES.has(value);
}

export interface WorldKnownEventEntry {
  readonly id: string;
  readonly worldId: string;
  readonly ownerCharacterInstanceId: string;
  readonly eventId: string;
  readonly extractionRunId: string;
  readonly knowledgeSourceKind: WorldKnownEventSourceKind;
  readonly sourceSessionId: string;
  readonly knowledgeSourceMessageIdsJson: string;
  readonly status: WorldKnownEventEntryStatus;
  readonly createdAt: number;
  readonly statusUpdatedAt: number;
}

export interface CreateWorldKnownEventEntryOptions {
  readonly id: string;
  readonly worldId: string;
  readonly ownerCharacterInstanceId: string;
  readonly eventId: string;
  readonly extractionRunId: string;
  readonly knowledgeSourceKind: WorldKnownEventSourceKind;
  readonly sourceSessionId: string;
  readonly knowledgeSourceMessageIdsJson: string;
  readonly status?: WorldKnownEventEntryStatus;
  readonly createdAt?: number;
  readonly statusUpdatedAt?: number;
}

export interface WorldKnownEventDerivationResult {
  readonly entry: WorldKnownEventEntry;
  readonly isExisting: boolean;
}

export interface WorldKnownEventBatchDerivationResult {
  readonly derived: WorldKnownEventDerivationResult[];
  readonly skippedWitnessIds: string[];
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

export function createWorldKnownEventEntryRecord(
  options: CreateWorldKnownEventEntryOptions
): WorldKnownEventEntry {
  if (options.id === '') {
    throw new Error('WorldKnownEventEntry: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldKnownEventEntry: worldId empty');
  }
  if (options.ownerCharacterInstanceId === '') {
    throw new Error('WorldKnownEventEntry: ownerCharacterInstanceId empty');
  }
  if (options.eventId === '') {
    throw new Error('WorldKnownEventEntry: eventId empty');
  }
  if (options.extractionRunId === '') {
    throw new Error('WorldKnownEventEntry: extractionRunId empty');
  }
  if (!isWorldKnownEventSourceKind(options.knowledgeSourceKind)) {
    throw new Error(`WorldKnownEventEntry: knowledgeSourceKind invalid: ${options.knowledgeSourceKind}`);
  }
  if (options.sourceSessionId === '') {
    throw new Error('WorldKnownEventEntry: sourceSessionId empty');
  }
  if (options.knowledgeSourceMessageIdsJson === '') {
    throw new Error('WorldKnownEventEntry: knowledgeSourceMessageIdsJson empty');
  }
  const status: WorldKnownEventEntryStatus = options.status !== undefined
    ? options.status : WorldKnownEventEntryStatus.Active;
  if (!isWorldKnownEventEntryStatus(status)) {
    throw new Error(`WorldKnownEventEntry: status invalid: ${status}`);
  }
  const now: number = nowMillis();
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const statusUpdatedAt: number = options.statusUpdatedAt !== undefined ? options.statusUpdatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldKnownEventEntry: createdAt invalid');
  }
  if (!isValidTimestamp(statusUpdatedAt)) {
    throw new Error('WorldKnownEventEntry: statusUpdatedAt invalid');
  }
  return {
    id: options.id,
    worldId: options.worldId,
    ownerCharacterInstanceId: options.ownerCharacterInstanceId,
    eventId: options.eventId,
    extractionRunId: options.extractionRunId,
    knowledgeSourceKind: options.knowledgeSourceKind,
    sourceSessionId: options.sourceSessionId,
    knowledgeSourceMessageIdsJson: options.knowledgeSourceMessageIdsJson,
    status: status,
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}

export function validateKnowledgeSourceMessageIds(json: string): string[] {
  if (json === '') {
    return [];
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(json);
  } catch (_e) {
    return [];
  }
  if (!Array.isArray(parsed)) {
    return [];
  }
  const arr: Object[] = parsed as Object[];
  const result: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (typeof item === 'string') {
      const str: string = item as string;
      if (str !== '') {
        result.push(str);
      }
    }
  }
  return result;
}
