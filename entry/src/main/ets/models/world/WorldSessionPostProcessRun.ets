import { nowMillis } from '../../utils/Time';

export const WORLD_SESSION_POST_PROCESS_RUN_ID_PREFIX: string = 'world-post-process-run-';

export const WORLD_SESSION_POST_PROCESS_PIPELINE_VERSION: string = 'world-session-post-process-v1';

export enum WorldSessionPostProcessRunStatus {
  Pending = 'pending',
  Running = 'running',
  Completed = 'completed',
  CompletedWithErrors = 'completed_with_errors'
}

export enum WorldSessionPostProcessStepStatus {
  Pending = 'pending',
  Running = 'running',
  Succeeded = 'succeeded',
  Skipped = 'skipped',
  Failed = 'failed'
}

export enum WorldSessionPostProcessResultCode {
  Generated = 'generated',
  Existing = 'existing',
  NoPublicContent = 'no_public_content',
  NoVisibleEvidence = 'no_visible_evidence',
  ZeroEvents = 'zero_events',
  Derived = 'derived',
  ZeroKnownEvents = 'zero_known_events',
  NoChange = 'no_change',
  SkippedDependency = 'skipped_dependency',
  BatchTooLarge = 'batch_too_large'
}

export enum WorldSessionPostProcessErrorKind {
  SourceInvalid = 'source_invalid',
  DependencyFailed = 'dependency_failed',
  NoModelConfiguration = 'no_model_configuration',
  ModelRequestFailed = 'model_request_failed',
  ModelCancelled = 'model_cancelled',
  InvalidModelOutput = 'invalid_model_output',
  SourceChanged = 'source_changed',
  PersistenceFailed = 'persistence_failed',
  BatchTooLarge = 'batch_too_large',
  RevisionConflict = 'revision_conflict',
  InvalidParticipantSnapshot = 'invalid_participant_snapshot',
  Unknown = 'unknown'
}

const VALID_RUN_STATUSES: Set<string> = new Set<string>([
  WorldSessionPostProcessRunStatus.Pending,
  WorldSessionPostProcessRunStatus.Running,
  WorldSessionPostProcessRunStatus.Completed,
  WorldSessionPostProcessRunStatus.CompletedWithErrors
]);

const VALID_STEP_STATUSES: Set<string> = new Set<string>([
  WorldSessionPostProcessStepStatus.Pending,
  WorldSessionPostProcessStepStatus.Running,
  WorldSessionPostProcessStepStatus.Succeeded,
  WorldSessionPostProcessStepStatus.Skipped,
  WorldSessionPostProcessStepStatus.Failed
]);

const VALID_RESULT_CODES: Set<string> = new Set<string>([
  WorldSessionPostProcessResultCode.Generated,
  WorldSessionPostProcessResultCode.Existing,
  WorldSessionPostProcessResultCode.NoPublicContent,
  WorldSessionPostProcessResultCode.NoVisibleEvidence,
  WorldSessionPostProcessResultCode.ZeroEvents,
  WorldSessionPostProcessResultCode.Derived,
  WorldSessionPostProcessResultCode.ZeroKnownEvents,
  WorldSessionPostProcessResultCode.NoChange,
  WorldSessionPostProcessResultCode.SkippedDependency,
  WorldSessionPostProcessResultCode.BatchTooLarge
]);

const VALID_ERROR_KINDS: Set<string> = new Set<string>([
  WorldSessionPostProcessErrorKind.SourceInvalid,
  WorldSessionPostProcessErrorKind.DependencyFailed,
  WorldSessionPostProcessErrorKind.NoModelConfiguration,
  WorldSessionPostProcessErrorKind.ModelRequestFailed,
  WorldSessionPostProcessErrorKind.ModelCancelled,
  WorldSessionPostProcessErrorKind.InvalidModelOutput,
  WorldSessionPostProcessErrorKind.SourceChanged,
  WorldSessionPostProcessErrorKind.PersistenceFailed,
  WorldSessionPostProcessErrorKind.BatchTooLarge,
  WorldSessionPostProcessErrorKind.RevisionConflict,
  WorldSessionPostProcessErrorKind.InvalidParticipantSnapshot,
  WorldSessionPostProcessErrorKind.Unknown
]);

const SUMMARY_RESULT_CODES: Set<string> = new Set<string>([
  WorldSessionPostProcessResultCode.Generated,
  WorldSessionPostProcessResultCode.Existing,
  WorldSessionPostProcessResultCode.NoPublicContent
]);

const MEMORY_RESULT_CODES: Set<string> = new Set<string>([
  WorldSessionPostProcessResultCode.Generated,
  WorldSessionPostProcessResultCode.Existing,
  WorldSessionPostProcessResultCode.NoVisibleEvidence
]);

const EVENT_RESULT_CODES: Set<string> = new Set<string>([
  WorldSessionPostProcessResultCode.Generated,
  WorldSessionPostProcessResultCode.Existing,
  WorldSessionPostProcessResultCode.ZeroEvents
]);

const KNOWN_EVENT_RESULT_CODES: Set<string> = new Set<string>([
  WorldSessionPostProcessResultCode.Derived,
  WorldSessionPostProcessResultCode.ZeroKnownEvents
]);

const RELATIONSHIP_RESULT_CODES: Set<string> = new Set<string>([
  WorldSessionPostProcessResultCode.Generated,
  WorldSessionPostProcessResultCode.Existing,
  WorldSessionPostProcessResultCode.NoChange
]);

export function isValidRunStatus(value: string): boolean {
  return VALID_RUN_STATUSES.has(value);
}

export function isValidStepStatus(value: string): boolean {
  return VALID_STEP_STATUSES.has(value);
}

export function isValidResultCode(value: string): boolean {
  return VALID_RESULT_CODES.has(value);
}

export function isValidErrorKind(value: string): boolean {
  return VALID_ERROR_KINDS.has(value);
}

export function isSummaryResultCode(code: string): boolean {
  return SUMMARY_RESULT_CODES.has(code);
}

export function isMemoryResultCode(code: string): boolean {
  return MEMORY_RESULT_CODES.has(code);
}

export function isEventResultCode(code: string): boolean {
  return EVENT_RESULT_CODES.has(code);
}

export function isKnownEventResultCode(code: string): boolean {
  return KNOWN_EVENT_RESULT_CODES.has(code);
}

export function isRelationshipResultCode(code: string): boolean {
  return RELATIONSHIP_RESULT_CODES.has(code);
}

export interface WorldSessionPostProcessStepState {
  readonly status: WorldSessionPostProcessStepStatus;
  readonly resultCode: WorldSessionPostProcessResultCode | undefined;
  readonly errorKind: WorldSessionPostProcessErrorKind | undefined;
  readonly updatedAt: number;
}

export interface WorldSessionPostProcessOwnerState {
  readonly ownerCharacterInstanceId: string;
  readonly status: WorldSessionPostProcessStepStatus;
  readonly resultCode: WorldSessionPostProcessResultCode | undefined;
  readonly errorKind: WorldSessionPostProcessErrorKind | undefined;
  readonly updatedAt: number;
}

export interface WorldSessionPostProcessRelationshipPairState {
  readonly ownerCharacterInstanceId: string;
  readonly targetCharacterInstanceId: string;
  readonly status: WorldSessionPostProcessStepStatus;
  readonly resultCode: WorldSessionPostProcessResultCode | undefined;
  readonly errorKind: WorldSessionPostProcessErrorKind | undefined;
  readonly updatedAt: number;
}

export interface WorldSessionPostProcessState {
  readonly participantCharacterInstanceIds: string[];
  readonly summary: WorldSessionPostProcessStepState;
  readonly memories: WorldSessionPostProcessOwnerState[];
  readonly eventExtraction: WorldSessionPostProcessStepState;
  readonly knownEvents: WorldSessionPostProcessStepState;
  readonly relationships: WorldSessionPostProcessRelationshipPairState[];
}

export interface WorldSessionPostProcessRun {
  readonly id: string;
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly pipelineVersion: string;
  readonly status: WorldSessionPostProcessRunStatus;
  readonly stateJson: string;
  readonly attemptCount: number;
  readonly revision: number;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly completedAt: number | undefined;
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

export function createInitialPostProcessState(
  participantCharacterInstanceIds: string[],
  now: number
): WorldSessionPostProcessState {
  const pendingStep: WorldSessionPostProcessStepState = {
    status: WorldSessionPostProcessStepStatus.Pending,
    resultCode: undefined,
    errorKind: undefined,
    updatedAt: now
  };
  const memories: WorldSessionPostProcessOwnerState[] = [];
  for (let i = 0; i < participantCharacterInstanceIds.length; i++) {
    const ownerId: string = participantCharacterInstanceIds[i];
    const ownerState: WorldSessionPostProcessOwnerState = {
      ownerCharacterInstanceId: ownerId,
      status: WorldSessionPostProcessStepStatus.Pending,
      resultCode: undefined,
      errorKind: undefined,
      updatedAt: now
    };
    memories.push(ownerState);
  }
  const relationships: WorldSessionPostProcessRelationshipPairState[] = [];
  for (let i = 0; i < participantCharacterInstanceIds.length; i++) {
    for (let j = 0; j < participantCharacterInstanceIds.length; j++) {
      if (i !== j) {
        const pairState: WorldSessionPostProcessRelationshipPairState = {
          ownerCharacterInstanceId: participantCharacterInstanceIds[i],
          targetCharacterInstanceId: participantCharacterInstanceIds[j],
          status: WorldSessionPostProcessStepStatus.Pending,
          resultCode: undefined,
          errorKind: undefined,
          updatedAt: now
        };
        relationships.push(pairState);
      }
    }
  }
  return {
    participantCharacterInstanceIds: participantCharacterInstanceIds,
    summary: pendingStep,
    memories: memories,
    eventExtraction: pendingStep,
    knownEvents: pendingStep,
    relationships: relationships
  };
}

export function serializePostProcessState(state: WorldSessionPostProcessState): string {
  const obj: Record<string, Object> = {};
  obj['participantCharacterInstanceIds'] = state.participantCharacterInstanceIds;
  obj['summary'] = serializeStepState(state.summary);
  obj['memories'] = serializeOwnerStates(state.memories);
  obj['eventExtraction'] = serializeStepState(state.eventExtraction);
  obj['knownEvents'] = serializeStepState(state.knownEvents);
  obj['relationships'] = serializePairStates(state.relationships);
  return JSON.stringify(obj);
}

function serializeStepState(step: WorldSessionPostProcessStepState): Record<string, Object> {
  const obj: Record<string, Object> = {};
  obj['status'] = step.status;
  if (step.resultCode !== undefined) {
    obj['resultCode'] = step.resultCode;
  }
  if (step.errorKind !== undefined) {
    obj['errorKind'] = step.errorKind;
  }
  obj['updatedAt'] = step.updatedAt;
  return obj;
}

function serializeOwnerStates(owners: WorldSessionPostProcessOwnerState[]): Record<string, Object>[] {
  const arr: Record<string, Object>[] = [];
  for (let i = 0; i < owners.length; i++) {
    const owner: WorldSessionPostProcessOwnerState = owners[i];
    const obj: Record<string, Object> = {};
    obj['ownerCharacterInstanceId'] = owner.ownerCharacterInstanceId;
    obj['status'] = owner.status;
    if (owner.resultCode !== undefined) {
      obj['resultCode'] = owner.resultCode;
    }
    if (owner.errorKind !== undefined) {
      obj['errorKind'] = owner.errorKind;
    }
    obj['updatedAt'] = owner.updatedAt;
    arr.push(obj);
  }
  return arr;
}

function serializePairStates(pairs: WorldSessionPostProcessRelationshipPairState[]): Record<string, Object>[] {
  const arr: Record<string, Object>[] = [];
  for (let i = 0; i < pairs.length; i++) {
    const pair: WorldSessionPostProcessRelationshipPairState = pairs[i];
    const obj: Record<string, Object> = {};
    obj['ownerCharacterInstanceId'] = pair.ownerCharacterInstanceId;
    obj['targetCharacterInstanceId'] = pair.targetCharacterInstanceId;
    obj['status'] = pair.status;
    if (pair.resultCode !== undefined) {
      obj['resultCode'] = pair.resultCode;
    }
    if (pair.errorKind !== undefined) {
      obj['errorKind'] = pair.errorKind;
    }
    obj['updatedAt'] = pair.updatedAt;
    arr.push(obj);
  }
  return arr;
}

export function parsePostProcessState(json: string): WorldSessionPostProcessState {
  let parsed: Object;
  try {
    parsed = JSON.parse(json);
  } catch (_e) {
    throw new Error('WorldSessionPostProcessState: failed to parse JSON');
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error('WorldSessionPostProcessState: root is not an object');
  }
  const root: Record<string, Object> = parsed as Record<string, Object>;

  const pIdsObj: Object | undefined = root['participantCharacterInstanceIds'];
  if (!Array.isArray(pIdsObj)) {
    throw new Error('WorldSessionPostProcessState: participantCharacterInstanceIds not array');
  }
  const participantIds: string[] = parseStringArray(pIdsObj as Object[], 'participantCharacterInstanceIds');
  if (participantIds.length === 0) {
    throw new Error('WorldSessionPostProcessState: participantCharacterInstanceIds empty');
  }
  const idSet: Set<string> = new Set<string>();
  for (let i = 0; i < participantIds.length; i++) {
    if (idSet.has(participantIds[i])) {
      throw new Error('WorldSessionPostProcessState: duplicate participant ID');
    }
    idSet.add(participantIds[i]);
  }

  const summary: WorldSessionPostProcessStepState = parseStepState(root['summary'], 'summary', SUMMARY_RESULT_CODES);

  const memoriesObj: Object | undefined = root['memories'];
  if (!Array.isArray(memoriesObj)) {
    throw new Error('WorldSessionPostProcessState: memories not array');
  }
  const memories: WorldSessionPostProcessOwnerState[] = parseOwnerStates(
    memoriesObj as Object[], participantIds, MEMORY_RESULT_CODES
  );

  const eventExtraction: WorldSessionPostProcessStepState = parseStepState(
    root['eventExtraction'], 'eventExtraction', EVENT_RESULT_CODES
  );

  const knownEvents: WorldSessionPostProcessStepState = parseStepState(
    root['knownEvents'], 'knownEvents', KNOWN_EVENT_RESULT_CODES
  );

  const relObj: Object | undefined = root['relationships'];
  if (!Array.isArray(relObj)) {
    throw new Error('WorldSessionPostProcessState: relationships not array');
  }
  const relationships: WorldSessionPostProcessRelationshipPairState[] = parsePairStates(
    relObj as Object[], participantIds, RELATIONSHIP_RESULT_CODES
  );

  return {
    participantCharacterInstanceIds: participantIds,
    summary: summary,
    memories: memories,
    eventExtraction: eventExtraction,
    knownEvents: knownEvents,
    relationships: relationships
  };
}

function parseStringArray(arr: Object[], fieldName: string): string[] {
  const result: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    if (typeof arr[i] !== 'string') {
      throw new Error(`WorldSessionPostProcessState: ${fieldName}[${i}] not string`);
    }
    const s: string = arr[i] as string;
    if (s === '') {
      throw new Error(`WorldSessionPostProcessState: ${fieldName}[${i}] empty`);
    }
    result.push(s);
  }
  return result;
}

function parseStepState(
  obj: Object | undefined,
  path: string,
  allowedResults: Set<string>
): WorldSessionPostProcessStepState {
  if (obj === undefined || obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
    throw new Error(`WorldSessionPostProcessState: ${path} invalid`);
  }
  const rec: Record<string, Object> = obj as Record<string, Object>;
  const status: string = parseEnumField(rec, 'status', path, VALID_STEP_STATUSES);
  const resultCode: string | undefined = parseOptionalEnumField(rec, 'resultCode', path, VALID_RESULT_CODES);
  const errorKind: string | undefined = parseOptionalEnumField(rec, 'errorKind', path, VALID_ERROR_KINDS);
  const updatedAt: number = parseTimestampField(rec, 'updatedAt', path);
  validateStepInvariants(status, resultCode, errorKind, path, allowedResults);
  return {
    status: status as WorldSessionPostProcessStepStatus,
    resultCode: resultCode as WorldSessionPostProcessResultCode | undefined,
    errorKind: errorKind as WorldSessionPostProcessErrorKind | undefined,
    updatedAt: updatedAt
  };
}

function parseOwnerStates(
  arr: Object[],
  participantIds: string[],
  allowedResults: Set<string>
): WorldSessionPostProcessOwnerState[] {
  if (arr.length !== participantIds.length) {
    throw new Error(`WorldSessionPostProcessState: memories length ${arr.length} != participants ${participantIds.length}`);
  }
  const result: WorldSessionPostProcessOwnerState[] = [];
  const seenOwners: Set<string> = new Set<string>();
  for (let i = 0; i < arr.length; i++) {
    if (typeof arr[i] !== 'object' || arr[i] === null || Array.isArray(arr[i])) {
      throw new Error(`WorldSessionPostProcessState: memories[${i}] invalid`);
    }
    const rec: Record<string, Object> = arr[i] as Record<string, Object>;
    const ownerId: string = parseStringField(rec, 'ownerCharacterInstanceId', `memories[${i}]`);
    if (ownerId !== participantIds[i]) {
      throw new Error(`WorldSessionPostProcessState: memories[${i}].ownerCharacterInstanceId order mismatch`);
    }
    if (seenOwners.has(ownerId)) {
      throw new Error(`WorldSessionPostProcessState: memories[${i}] duplicate owner`);
    }
    seenOwners.add(ownerId);
    const status: string = parseEnumField(rec, 'status', `memories[${i}]`, VALID_STEP_STATUSES);
    const resultCode: string | undefined = parseOptionalEnumField(rec, 'resultCode', `memories[${i}]`, VALID_RESULT_CODES);
    const errorKind: string | undefined = parseOptionalEnumField(rec, 'errorKind', `memories[${i}]`, VALID_ERROR_KINDS);
    const updatedAt: number = parseTimestampField(rec, 'updatedAt', `memories[${i}]`);
    validateStepInvariants(status, resultCode, errorKind, `memories[${i}]`, allowedResults);
    result.push({
      ownerCharacterInstanceId: ownerId,
      status: status as WorldSessionPostProcessStepStatus,
      resultCode: resultCode as WorldSessionPostProcessResultCode | undefined,
      errorKind: errorKind as WorldSessionPostProcessErrorKind | undefined,
      updatedAt: updatedAt
    });
  }
  return result;
}

function parsePairStates(
  arr: Object[],
  participantIds: string[],
  allowedResults: Set<string>
): WorldSessionPostProcessRelationshipPairState[] {
  const expectedCount: number = participantIds.length * (participantIds.length - 1);
  if (arr.length !== expectedCount) {
    throw new Error(`WorldSessionPostProcessState: relationships length ${arr.length} != expected ${expectedCount}`);
  }
  const result: WorldSessionPostProcessRelationshipPairState[] = [];
  const seenPairs: Set<string> = new Set<string>();
  let pairIdx: number = 0;
  for (let i = 0; i < participantIds.length; i++) {
    for (let j = 0; j < participantIds.length; j++) {
      if (i === j) {
        continue;
      }
      const expectedOwner: string = participantIds[i];
      const expectedTarget: string = participantIds[j];
      const pairKey: string = expectedOwner + '→' + expectedTarget;
      if (pairIdx >= arr.length) {
        throw new Error(`WorldSessionPostProcessState: relationships missing pair ${pairKey}`);
      }
      if (typeof arr[pairIdx] !== 'object' || arr[pairIdx] === null || Array.isArray(arr[pairIdx])) {
        throw new Error(`WorldSessionPostProcessState: relationships[${pairIdx}] invalid`);
      }
      const rec: Record<string, Object> = arr[pairIdx] as Record<string, Object>;
      const ownerId: string = parseStringField(rec, 'ownerCharacterInstanceId', `relationships[${pairIdx}]`);
      const targetId: string = parseStringField(rec, 'targetCharacterInstanceId', `relationships[${pairIdx}]`);
      if (ownerId !== expectedOwner || targetId !== expectedTarget) {
        throw new Error(`WorldSessionPostProcessState: relationships[${pairIdx}] order mismatch expected ${pairKey}`);
      }
      if (ownerId === targetId) {
        throw new Error(`WorldSessionPostProcessState: relationships[${pairIdx}] owner==target`);
      }
      const pairId: string = ownerId + '→' + targetId;
      if (seenPairs.has(pairId)) {
        throw new Error(`WorldSessionPostProcessState: relationships[${pairIdx}] duplicate pair`);
      }
      seenPairs.add(pairId);
      const status: string = parseEnumField(rec, 'status', `relationships[${pairIdx}]`, VALID_STEP_STATUSES);
      const resultCode: string | undefined = parseOptionalEnumField(rec, 'resultCode', `relationships[${pairIdx}]`, VALID_RESULT_CODES);
      const errorKind: string | undefined = parseOptionalEnumField(rec, 'errorKind', `relationships[${pairIdx}]`, VALID_ERROR_KINDS);
      const updatedAt: number = parseTimestampField(rec, 'updatedAt', `relationships[${pairIdx}]`);
      validateStepInvariants(status, resultCode, errorKind, `relationships[${pairIdx}]`, allowedResults);
      result.push({
        ownerCharacterInstanceId: ownerId,
        targetCharacterInstanceId: targetId,
        status: status as WorldSessionPostProcessStepStatus,
        resultCode: resultCode as WorldSessionPostProcessResultCode | undefined,
        errorKind: errorKind as WorldSessionPostProcessErrorKind | undefined,
        updatedAt: updatedAt
      });
      pairIdx++;
    }
  }
  return result;
}

function parseStringField(rec: Record<string, Object>, field: string, path: string): string {
  const val: Object | undefined = rec[field];
  if (typeof val !== 'string') {
    throw new Error(`WorldSessionPostProcessState: ${path}.${field} missing or not string`);
  }
  const s: string = val as string;
  if (s === '') {
    throw new Error(`WorldSessionPostProcessState: ${path}.${field} empty`);
  }
  return s;
}

function parseEnumField(rec: Record<string, Object>, field: string, path: string, validSet: Set<string>): string {
  const val: Object | undefined = rec[field];
  if (typeof val !== 'string') {
    throw new Error(`WorldSessionPostProcessState: ${path}.${field} missing or not string`);
  }
  const s: string = val as string;
  if (!validSet.has(s)) {
    throw new Error(`WorldSessionPostProcessState: ${path}.${field} invalid value: ${s}`);
  }
  return s;
}

function parseOptionalEnumField(rec: Record<string, Object>, field: string, path: string, validSet: Set<string>): string | undefined {
  const val: Object | undefined = rec[field];
  if (val === undefined) {
    return undefined;
  }
  if (typeof val !== 'string') {
    throw new Error(`WorldSessionPostProcessState: ${path}.${field} not string`);
  }
  const s: string = val as string;
  if (!validSet.has(s)) {
    throw new Error(`WorldSessionPostProcessState: ${path}.${field} invalid value: ${s}`);
  }
  return s;
}

function parseTimestampField(rec: Record<string, Object>, field: string, path: string): number {
  const val: Object | undefined = rec[field];
  if (typeof val !== 'number') {
    throw new Error(`WorldSessionPostProcessState: ${path}.${field} missing or not number`);
  }
  const n: number = val as number;
  if (!isValidTimestamp(n)) {
    throw new Error(`WorldSessionPostProcessState: ${path}.${field} invalid timestamp`);
  }
  return n;
}

function validateStepInvariants(
  status: string,
  resultCode: string | undefined,
  errorKind: string | undefined,
  path: string,
  allowedResults: Set<string>
): void {
  if (status === WorldSessionPostProcessStepStatus.Succeeded) {
    if (resultCode === undefined) {
      throw new Error(`WorldSessionPostProcessState: ${path} Succeeded without resultCode`);
    }
    if (!allowedResults.has(resultCode)) {
      throw new Error(`WorldSessionPostProcessState: ${path} Succeeded with invalid resultCode: ${resultCode}`);
    }
    if (errorKind !== undefined) {
      throw new Error(`WorldSessionPostProcessState: ${path} Succeeded with errorKind`);
    }
  } else if (status === WorldSessionPostProcessStepStatus.Skipped) {
    if (resultCode === undefined) {
      throw new Error(`WorldSessionPostProcessState: ${path} Skipped without resultCode`);
    }
    if (!allowedResults.has(resultCode)) {
      throw new Error(`WorldSessionPostProcessState: ${path} Skipped with invalid resultCode: ${resultCode}`);
    }
    if (errorKind !== undefined) {
      throw new Error(`WorldSessionPostProcessState: ${path} Skipped with errorKind`);
    }
  } else if (status === WorldSessionPostProcessStepStatus.Failed) {
    if (errorKind === undefined) {
      throw new Error(`WorldSessionPostProcessState: ${path} Failed without errorKind`);
    }
  } else if (status === WorldSessionPostProcessStepStatus.Pending) {
    if (resultCode !== undefined) {
      throw new Error(`WorldSessionPostProcessState: ${path} Pending with resultCode`);
    }
    if (errorKind !== undefined) {
      throw new Error(`WorldSessionPostProcessState: ${path} Pending with errorKind`);
    }
  } else if (status === WorldSessionPostProcessStepStatus.Running) {
    if (resultCode !== undefined) {
      throw new Error(`WorldSessionPostProcessState: ${path} Running with resultCode`);
    }
  }
}
