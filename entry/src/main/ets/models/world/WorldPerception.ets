export interface WorldLocationPresenceSnapshot {
  readonly worldId: string;
  readonly locationId: string;
  readonly characterInstanceIds: string[];
  readonly capturedAt: number;
}

export interface WorldCharacterPerceptionSnapshot {
  readonly worldId: string;
  readonly characterInstanceId: string;
  readonly locationId: string;
  readonly coPresentCharacterInstanceIds: string[];
  readonly capturedAt: number;
}
