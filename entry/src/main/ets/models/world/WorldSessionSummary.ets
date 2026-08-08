import { nowMillis } from '../../utils/Time';

export const WORLD_SESSION_SUMMARY_ID_PREFIX: string = 'world-session-summary-';

export enum WorldSessionSummaryVisibilityScope {
  SharedPublic = 'shared_public'
}

export interface WorldSessionSummary {
  readonly id: string;
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly version: number;
  readonly visibilityScope: WorldSessionSummaryVisibilityScope;
  readonly content: string;
  readonly sourceMessageIdsJson: string;
  readonly sourceMessageCount: number;
  readonly participantSnapshotJson: string;
  readonly playerDisplayNameSnapshot: string;
  readonly locationId: string;
  readonly promptVersion: string;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface CreateWorldSessionSummaryOptions {
  readonly id: string;
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly version: number;
  readonly visibilityScope?: WorldSessionSummaryVisibilityScope;
  readonly content: string;
  readonly sourceMessageIdsJson: string;
  readonly sourceMessageCount: number;
  readonly participantSnapshotJson: string;
  readonly playerDisplayNameSnapshot: string;
  readonly locationId: string;
  readonly promptVersion: string;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

export interface WorldSessionSummarySourceMessage {
  readonly id: string;
  readonly senderType: string;
  readonly senderCharacterInstanceId: string | undefined;
  readonly visibility: string;
  readonly content: string;
  readonly participantCharacterInstanceIds: string[] | undefined;
  readonly witnessCharacterInstanceIds: string[] | undefined;
}

export interface WorldSessionSummarySourceSnapshot {
  readonly sessionId: string;
  readonly sceneId: string;
  readonly worldId: string;
  readonly locationId: string;
  readonly playerDisplayNameSnapshot: string;
  readonly participantSnapshotJson: string;
  readonly sourceMessages: ReadonlyArray<WorldSessionSummarySourceMessage>;
  readonly sourceMessageIds: ReadonlyArray<string>;
  readonly sourceMessageCount: number;
}

const VALID_VISIBILITY_SCOPES: Set<string> = new Set<string>([
  WorldSessionSummaryVisibilityScope.SharedPublic
]);

export function isWorldSessionSummaryVisibilityScope(value: string): boolean {
  return VALID_VISIBILITY_SCOPES.has(value);
}

export function createWorldSessionSummaryRecord(
  options: CreateWorldSessionSummaryOptions
): WorldSessionSummary {
  if (options.id === '') {
    throw new Error('WorldSessionSummary: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldSessionSummary: worldId empty');
  }
  if (options.sceneId === '') {
    throw new Error('WorldSessionSummary: sceneId empty');
  }
  if (options.sessionId === '') {
    throw new Error('WorldSessionSummary: sessionId empty');
  }
  if (!Number.isFinite(options.version) || !Number.isInteger(options.version) || options.version < 1) {
    throw new Error('WorldSessionSummary: version must be positive integer');
  }
  const visibilityScope: WorldSessionSummaryVisibilityScope = options.visibilityScope !== undefined
    ? options.visibilityScope : WorldSessionSummaryVisibilityScope.SharedPublic;
  if (!isWorldSessionSummaryVisibilityScope(visibilityScope)) {
    throw new Error(`WorldSessionSummary: visibilityScope invalid: ${visibilityScope}`);
  }
  if (options.locationId === '') {
    throw new Error('WorldSessionSummary: locationId empty');
  }
  if (options.promptVersion === '') {
    throw new Error('WorldSessionSummary: promptVersion empty');
  }
  if (!Number.isFinite(options.sourceMessageCount) || !Number.isInteger(options.sourceMessageCount) || options.sourceMessageCount < 0) {
    throw new Error('WorldSessionSummary: sourceMessageCount invalid');
  }
  const now: number = nowMillis();
  const createdAt: number = options.createdAt !== undefined ? options.createdAt : now;
  const updatedAt: number = options.updatedAt !== undefined ? options.updatedAt : now;
  if (!isValidTimestamp(createdAt)) {
    throw new Error('WorldSessionSummary: createdAt invalid');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw new Error('WorldSessionSummary: updatedAt invalid');
  }
  return {
    id: options.id,
    worldId: options.worldId,
    sceneId: options.sceneId,
    sessionId: options.sessionId,
    version: options.version,
    visibilityScope: visibilityScope,
    content: options.content,
    sourceMessageIdsJson: options.sourceMessageIdsJson,
    sourceMessageCount: options.sourceMessageCount,
    participantSnapshotJson: options.participantSnapshotJson,
    playerDisplayNameSnapshot: options.playerDisplayNameSnapshot,
    locationId: options.locationId,
    promptVersion: options.promptVersion,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}
