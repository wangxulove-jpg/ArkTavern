import { nowMillis } from '../../utils/Time';

export const WORLD_CHARACTER_LOCATION_HISTORY_ID_PREFIX: string = 'world-loc-hist-';

export enum TransitionKind {
  Placement = 'placement',
  Unplacement = 'unplacement',
  Relocation = 'relocation',
  Travel = 'travel',
  Removal = 'removal'
}

export enum InitiatorType {
  User = 'user',
  AI = 'ai',
  System = 'system'
}

const VALID_TRANSITION_KINDS: Set<string> = new Set<string>([
  TransitionKind.Placement,
  TransitionKind.Unplacement,
  TransitionKind.Relocation,
  TransitionKind.Travel,
  TransitionKind.Removal
]);

const VALID_INITIATOR_TYPES: Set<string> = new Set<string>([
  InitiatorType.User,
  InitiatorType.AI,
  InitiatorType.System
]);

export function isTransitionKind(value: string): boolean {
  return VALID_TRANSITION_KINDS.has(value);
}

export function isInitiatorType(value: string): boolean {
  return VALID_INITIATOR_TYPES.has(value);
}

export interface WorldCharacterLocationHistory {
  readonly id: string;
  readonly worldId: string;
  readonly characterInstanceId: string;
  readonly transitionKind: TransitionKind;
  readonly fromLocationId: string;
  readonly toLocationId: string;
  readonly initiatorType: InitiatorType;
  readonly edgeId: string;
  readonly directionLabel: string;
  readonly createdAt: number;
}

export interface CreateWorldCharacterLocationHistoryOptions {
  readonly id: string;
  readonly worldId: string;
  readonly characterInstanceId: string;
  readonly transitionKind: TransitionKind;
  readonly fromLocationId?: string;
  readonly toLocationId?: string;
  readonly initiatorType?: InitiatorType;
  readonly edgeId?: string;
  readonly directionLabel?: string;
  readonly createdAt?: number;
}

export function createWorldCharacterLocationHistoryRecord(
  options: CreateWorldCharacterLocationHistoryOptions
): WorldCharacterLocationHistory {
  if (options.id === '') {
    throw new Error('WorldCharacterLocationHistory: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldCharacterLocationHistory: worldId empty');
  }
  if (options.characterInstanceId === '') {
    throw new Error('WorldCharacterLocationHistory: characterInstanceId empty');
  }
  if (!isTransitionKind(options.transitionKind)) {
    throw new Error(`WorldCharacterLocationHistory: transitionKind invalid: ${options.transitionKind}`);
  }
  const now: number = nowMillis();
  return {
    id: options.id,
    worldId: options.worldId,
    characterInstanceId: options.characterInstanceId,
    transitionKind: options.transitionKind,
    fromLocationId: options.fromLocationId !== undefined ? options.fromLocationId : '',
    toLocationId: options.toLocationId !== undefined ? options.toLocationId : '',
    initiatorType: options.initiatorType !== undefined ? options.initiatorType : InitiatorType.User,
    edgeId: options.edgeId !== undefined ? options.edgeId : '',
    directionLabel: options.directionLabel !== undefined ? options.directionLabel : '',
    createdAt: options.createdAt !== undefined ? options.createdAt : now
  };
}
