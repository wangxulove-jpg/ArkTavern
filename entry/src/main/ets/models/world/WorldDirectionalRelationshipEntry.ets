import { nowMillis } from '../../utils/Time';

export const WORLD_DIRECTIONAL_RELATIONSHIP_ENTRY_ID_PREFIX: string = 'world-dir-rel-';

export enum WorldDirectionalRelationshipEntryStatus {
  Active = 'active',
  Superseded = 'superseded',
  Rejected = 'rejected'
}

export enum WorldDirectionalRelationshipErrorKind {
  OwnerEqualsTarget = 'owner_equals_target',
  OwnerNotParticipant = 'owner_not_participant',
  TargetNotParticipant = 'target_not_participant',
  EmptyEvidenceMessageIds = 'empty_evidence_message_ids',
  EvidenceNotInSource = 'evidence_not_in_source',
  EmptyRelationshipText = 'empty_relationship_text',
  ConfidenceInvalid = 'confidence_invalid',
  SourceChanged = 'source_changed',
  StaleEntry = 'stale_entry',
  MultipleActive = 'multiple_active'
}

const VALID_STATUSES: Set<string> = new Set<string>([
  WorldDirectionalRelationshipEntryStatus.Active,
  WorldDirectionalRelationshipEntryStatus.Superseded,
  WorldDirectionalRelationshipEntryStatus.Rejected
]);

export function isWorldDirectionalRelationshipEntryStatus(value: string): boolean {
  return VALID_STATUSES.has(value);
}

export interface WorldDirectionalRelationshipEntry {
  readonly id: string;
  readonly worldId: string;
  readonly ownerCharacterInstanceId: string;
  readonly targetCharacterInstanceId: string;
  readonly version: number;
  readonly relationshipText: string;
  readonly confidence: number;
  readonly sourceSceneId: string;
  readonly sourceSessionId: string;
  readonly sourceLocationId: string;
  readonly evidenceMessageIdsJson: string;
  readonly ownerDisplayNameSnapshot: string;
  readonly targetDisplayNameSnapshot: string;
  readonly promptVersion: string;
  readonly providerId: string | undefined;
  readonly modelId: string | undefined;
  readonly supersedesRelationshipId: string | undefined;
  readonly status: WorldDirectionalRelationshipEntryStatus;
  readonly createdAt: number;
  readonly statusUpdatedAt: number;
}

export interface CreateWorldDirectionalRelationshipEntryOptions {
  readonly id: string;
  readonly worldId: string;
  readonly ownerCharacterInstanceId: string;
  readonly targetCharacterInstanceId: string;
  readonly version: number;
  readonly relationshipText: string;
  readonly confidence: number;
  readonly sourceSceneId: string;
  readonly sourceSessionId: string;
  readonly sourceLocationId: string;
  readonly evidenceMessageIdsJson: string;
  readonly ownerDisplayNameSnapshot: string;
  readonly targetDisplayNameSnapshot: string;
  readonly promptVersion: string;
  readonly providerId?: string;
  readonly modelId?: string;
  readonly supersedesRelationshipId?: string;
  readonly status?: WorldDirectionalRelationshipEntryStatus;
  readonly createdAt?: number;
  readonly statusUpdatedAt?: number;
}

export interface WorldDirectionalRelationshipPersistResult {
  readonly entry: WorldDirectionalRelationshipEntry;
  readonly isExisting: boolean;
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

export function createWorldDirectionalRelationshipEntryRecord(
  options: CreateWorldDirectionalRelationshipEntryOptions
): WorldDirectionalRelationshipEntry {
  if (options.id === '') {
    throw new Error('WorldDirectionalRelationshipEntry: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldDirectionalRelationshipEntry: worldId empty');
  }
  if (options.ownerCharacterInstanceId === '') {
    throw new Error('WorldDirectionalRelationshipEntry: ownerCharacterInstanceId empty');
  }
  if (options.targetCharacterInstanceId === '') {
    throw new Error('WorldDirectionalRelationshipEntry: targetCharacterInstanceId empty');
  }
  if (options.ownerCharacterInstanceId === options.targetCharacterInstanceId) {
    throw new Error('WorldDirectionalRelationshipEntry: owner equals target');
  }
  if (!Number.isFinite(options.version) || !Number.isInteger(options.version) || options.version < 1) {
    throw new Error('WorldDirectionalRelationshipEntry: version invalid');
  }
  if (options.relationshipText.trim() === '') {
    throw new Error('WorldDirectionalRelationshipEntry: relationshipText empty');
  }
  if (!Number.isFinite(options.confidence) || options.confidence < 0 || options.confidence > 1) {
    throw new Error('WorldDirectionalRelationshipEntry: confidence invalid');
  }
  if (options.sourceSceneId === '') {
    throw new Error('WorldDirectionalRelationshipEntry: sourceSceneId empty');
  }
  if (options.sourceSessionId === '') {
    throw new Error('WorldDirectionalRelationshipEntry: sourceSessionId empty');
  }
  if (options.sourceLocationId === '') {
    throw new Error('WorldDirectionalRelationshipEntry: sourceLocationId empty');
  }
  if (options.evidenceMessageIdsJson === '' || options.evidenceMessageIdsJson === '[]') {
    throw new Error('WorldDirectionalRelationshipEntry: evidenceMessageIdsJson empty');
  }
  if (options.ownerDisplayNameSnapshot === '') {
    throw new Error('WorldDirectionalRelationshipEntry: ownerDisplayNameSnapshot empty');
  }
  if (options.targetDisplayNameSnapshot === '') {
    throw new Error('WorldDirectionalRelationshipEntry: targetDisplayNameSnapshot empty');
  }
  if (options.promptVersion === '') {
    throw new Error('WorldDirectionalRelationshipEntry: promptVersion empty');
  }
  const status: WorldDirectionalRelationshipEntryStatus = options.status !== undefined
    ? options.status : WorldDirectionalRelationshipEntryStatus.Active;
  if (!isWorldDirectionalRelationshipEntryStatus(status)) {
    throw new Error(`WorldDirectionalRelationshipEntry: status invalid: ${status}`);
  }
  const now: number = nowMillis();
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const statusUpdatedAt: number = options.statusUpdatedAt !== undefined ? options.statusUpdatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldDirectionalRelationshipEntry: createdAt invalid');
  }
  if (!isValidTimestamp(statusUpdatedAt)) {
    throw new Error('WorldDirectionalRelationshipEntry: statusUpdatedAt invalid');
  }
  const providerId: string | undefined = options.providerId !== undefined && options.providerId !== ''
    ? options.providerId : undefined;
  const modelId: string | undefined = options.modelId !== undefined && options.modelId !== ''
    ? options.modelId : undefined;
  const supersedesRelationshipId: string | undefined =
    options.supersedesRelationshipId !== undefined && options.supersedesRelationshipId !== ''
      ? options.supersedesRelationshipId : undefined;
  return {
    id: options.id,
    worldId: options.worldId,
    ownerCharacterInstanceId: options.ownerCharacterInstanceId,
    targetCharacterInstanceId: options.targetCharacterInstanceId,
    version: options.version,
    relationshipText: options.relationshipText,
    confidence: options.confidence,
    sourceSceneId: options.sourceSceneId,
    sourceSessionId: options.sourceSessionId,
    sourceLocationId: options.sourceLocationId,
    evidenceMessageIdsJson: options.evidenceMessageIdsJson,
    ownerDisplayNameSnapshot: options.ownerDisplayNameSnapshot,
    targetDisplayNameSnapshot: options.targetDisplayNameSnapshot,
    promptVersion: options.promptVersion,
    providerId: providerId,
    modelId: modelId,
    supersedesRelationshipId: supersedesRelationshipId,
    status: status,
    createdAt: createdAt,
    statusUpdatedAt: statusUpdatedAt
  };
}

export function parseJsonIdArray(json: string): string[] {
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

export function stableDedupInSourceOrder(ids: string[]): string[] {
  const seen: Set<string> = new Set<string>();
  const result: string[] = [];
  for (let i = 0; i < ids.length; i++) {
    const id: string = ids[i];
    if (id !== '' && !seen.has(id)) {
      seen.add(id);
      result.push(id);
    }
  }
  return result;
}

export function filterBySourceOrder(
  sourceMessageIds: ReadonlyArray<string>,
  requestedIds: ReadonlyArray<string>
): string[] {
  const requestedSet: Set<string> = new Set<string>();
  for (let i = 0; i < requestedIds.length; i++) {
    const id: string = requestedIds[i];
    if (id !== '') {
      requestedSet.add(id);
    }
  }
  const result: string[] = [];
  for (let i = 0; i < sourceMessageIds.length; i++) {
    const id: string = sourceMessageIds[i];
    if (requestedSet.has(id)) {
      result.push(id);
    }
  }
  return result;
}
