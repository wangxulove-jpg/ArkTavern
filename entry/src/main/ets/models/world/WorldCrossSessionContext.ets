import { WorldCharacterMemoryKind } from './WorldCharacterMemoryEntry';

export interface WorldCrossSessionSummaryContextItem {
  readonly summaryId: string;
  readonly sourceSessionId: string;
  readonly sourceSessionSequenceNumber: number;
  readonly sourceLocationId: string;
  readonly version: number;
  readonly summaryText: string;
  readonly participantCharacterInstanceIds: ReadonlyArray<string>;
  readonly sourceMessageIds: ReadonlyArray<string>;
  readonly createdAt: number;
}

export interface WorldCrossSessionMemoryContextItem {
  readonly memoryId: string;
  readonly ownerCharacterInstanceId: string;
  readonly sourceSessionId: string;
  readonly sourceSceneId: string;
  readonly sourceLocationId: string;
  readonly version: number;
  readonly memoryText: string;
  readonly confidence: number;
  readonly memoryKind: WorldCharacterMemoryKind;
  readonly sourceMessageIds: ReadonlyArray<string>;
  readonly createdAt: number;
}

export interface WorldCrossSessionContextSnapshot {
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly speakerCharacterInstanceId: string;
  readonly summaries: ReadonlyArray<WorldCrossSessionSummaryContextItem>;
  readonly memories: ReadonlyArray<WorldCrossSessionMemoryContextItem>;
  readonly omittedSummaryCount: number;
  readonly omittedMemoryCount: number;
}

export interface WorldCrossSessionContextRequest {
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly speakerCharacterInstanceId: string;
}

export type WorldCrossSessionContextErrorCategory =
  'DataUnavailable' |
  'InvalidState' |
  'ConsistencyError' |
  'Unauthorized' |
  'ContextUnavailable';

export class WorldCrossSessionContextError extends Error {
  readonly category: WorldCrossSessionContextErrorCategory;

  constructor(message: string, category: WorldCrossSessionContextErrorCategory) {
    super(message);
    this.category = category;
  }
}

export const MAX_SHARED_SUMMARY_ITEMS: number = 5;
export const MAX_CHARACTER_MEMORY_ITEMS: number = 10;
export const MAX_CROSS_SESSION_CONTEXT_CHARS: number = 15000;
