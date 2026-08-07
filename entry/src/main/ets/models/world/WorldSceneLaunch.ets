import { WorldScene } from './WorldScene';
import { WorldConversationSession } from './WorldConversationSession';
import { WorldCharacterInstance } from './WorldCharacterInstance';
import { WorldLocation } from './WorldLocation';

export enum WorldSceneLaunchErrorKind {
  WorldNotFound,
  WorldNotActive,
  LocationNotFound,
  LocationArchived,
  SceneAlreadyActive,
  SceneAlreadyEnded,
  NoEligibleParticipants,
  ParticipantNotFound,
  ParticipantWorldMismatch,
  ParticipantInactive,
  ParticipantLocationMismatch,
  ActiveSessionAlreadyExists,
  PlayerProfileNotFound,
  DuplicateParticipant,
  PreviousSessionNotFound,
  PreviousSessionWorldMismatch,
  PreviousSessionSceneMismatch,
  PreviousSessionNotEnded,
  Internal
}

export class WorldSceneLaunchError extends Error {
  readonly kind: WorldSceneLaunchErrorKind;

  constructor(kind: WorldSceneLaunchErrorKind, message: string) {
    super(message);
    this.name = 'WorldSceneLaunchError';
    this.kind = kind;
  }

  static worldNotFound(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.WorldNotFound, '世界不存在');
  }

  static worldNotActive(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.WorldNotActive, '世界未激活');
  }

  static locationNotFound(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.LocationNotFound, '地点不存在');
  }

  static locationArchived(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.LocationArchived, '地点已归档');
  }

  static sceneAlreadyActive(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.SceneAlreadyActive, '该地点已有进行中的场景');
  }

  static sceneAlreadyEnded(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.SceneAlreadyEnded, '场景已结束,不能新建会话');
  }

  static noEligibleParticipants(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.NoEligibleParticipants, '该地点没有可参与的角色');
  }

  static participantNotFound(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.ParticipantNotFound, '角色实例不存在');
  }

  static participantWorldMismatch(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.ParticipantWorldMismatch, '角色实例不属于该世界');
  }

  static participantInactive(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.ParticipantInactive, '角色实例未激活');
  }

  static participantLocationMismatch(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.ParticipantLocationMismatch, '角色实例不在当前地点');
  }

  static activeSessionAlreadyExists(sessionId: string): WorldSceneLaunchError {
    return new WorldSceneLaunchError(
      WorldSceneLaunchErrorKind.ActiveSessionAlreadyExists,
      `该场景已有进行中的会话: ${sessionId.substring(0, 8)}`
    );
  }

  static playerProfileNotFound(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.PlayerProfileNotFound, '该世界无玩家档案');
  }

  static duplicateParticipant(id: string): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.DuplicateParticipant, `重复参与者: ${id.substring(0, 8)}`);
  }

  static previousSessionNotFound(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.PreviousSessionNotFound, '前序会话不存在');
  }

  static previousSessionWorldMismatch(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.PreviousSessionWorldMismatch, '前序会话不属于该世界');
  }

  static previousSessionSceneMismatch(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.PreviousSessionSceneMismatch, '前序会话不属于该场景');
  }

  static previousSessionNotEnded(): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.PreviousSessionNotEnded, '前序会话尚未结束');
  }

  static internal(message: string): WorldSceneLaunchError {
    return new WorldSceneLaunchError(WorldSceneLaunchErrorKind.Internal, message);
  }
}

export interface WorldSceneLaunchEligibleParticipant {
  readonly characterInstanceId: string;
  readonly displayNameSnapshot: string;
}

export interface WorldSceneLaunchSnapshot {
  readonly worldId: string;
  readonly locationId: string;
  readonly locationName: string;
  readonly existingActiveScene: WorldScene | null;
  readonly existingActiveSession: WorldConversationSession | null;
  readonly eligibleParticipants: WorldSceneLaunchEligibleParticipant[];
}

export interface WorldSceneLaunchTarget {
  readonly worldId: string;
  readonly locationId: string;
  readonly participantCharacterInstanceIds: string[];
  readonly previousSessionId?: string;
}

export interface WorldSceneLaunchResult {
  readonly scene: WorldScene;
  readonly session: WorldConversationSession;
  readonly isNewScene: boolean;
  readonly isNewSession: boolean;
}
