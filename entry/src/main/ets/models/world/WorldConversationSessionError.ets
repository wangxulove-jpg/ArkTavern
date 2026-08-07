export enum SessionErrorKind {
  WorldNotFound,
  WorldNotActive,
  SceneNotFound,
  SceneWorldMismatch,
  SceneNotActive,
  PlayerProfileNotFound,
  NoParticipants,
  DuplicateParticipant,
  ParticipantNotFound,
  ParticipantWorldMismatch,
  ParticipantInactive,
  ParticipantLocationMismatch,
  ActiveSessionAlreadyExists,
  ActiveSessionDataCorrupted,
  SessionNotFound,
  SessionWorldMismatch,
  SessionSceneMismatch,
  SessionAlreadyEnded,
  PreviousSessionNotFound,
  PreviousSessionWorldMismatch,
  PreviousSessionSceneMismatch,
  PreviousSessionNotEnded,
  InvalidEndedAt,
  Internal
}

export class WorldConversationSessionError extends Error {
  readonly kind: SessionErrorKind;

  constructor(kind: SessionErrorKind, message: string) {
    super(message);
    this.name = 'WorldConversationSessionError';
    this.kind = kind;
  }

  static worldNotFound(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.WorldNotFound, '世界不存在');
  }

  static worldNotActive(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.WorldNotActive, '世界未激活,不能创建会话');
  }

  static sceneNotFound(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.SceneNotFound, '场景不存在');
  }

  static sceneWorldMismatch(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.SceneWorldMismatch, '场景不属于该世界');
  }

  static sceneNotActive(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.SceneNotActive, '场景已结束,不能创建会话');
  }

  static playerProfileNotFound(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.PlayerProfileNotFound, '该世界无玩家档案');
  }

  static noParticipants(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.NoParticipants, '至少需要一个参与者');
  }

  static duplicateParticipant(id: string): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.DuplicateParticipant, `重复参与者: ${id}`);
  }

  static participantNotFound(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.ParticipantNotFound, '角色实例不存在');
  }

  static participantWorldMismatch(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.ParticipantWorldMismatch, '角色实例不属于该世界');
  }

  static participantInactive(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.ParticipantInactive, '角色实例未激活');
  }

  static participantLocationMismatch(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.ParticipantLocationMismatch, '角色实例不在当前场景地点');
  }

  static activeSessionAlreadyExists(sessionId: string): WorldConversationSessionError {
    return new WorldConversationSessionError(
      SessionErrorKind.ActiveSessionAlreadyExists,
      `该场景已有进行中的会话: ${sessionId.substring(0, 8)}`
    );
  }

  static activeSessionDataCorrupted(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.ActiveSessionDataCorrupted, '该场景存在多个活跃会话,数据异常');
  }

  static sessionNotFound(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.SessionNotFound, '会话不存在');
  }

  static sessionWorldMismatch(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.SessionWorldMismatch, '会话不属于该世界');
  }

  static sessionSceneMismatch(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.SessionSceneMismatch, '会话场景不匹配');
  }

  static sessionAlreadyEnded(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.SessionAlreadyEnded, '会话已结束');
  }

  static previousSessionNotFound(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.PreviousSessionNotFound, '前序会话不存在');
  }

  static previousSessionWorldMismatch(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.PreviousSessionWorldMismatch, '前序会话不属于该世界');
  }

  static previousSessionSceneMismatch(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.PreviousSessionSceneMismatch, '前序会话不属于该场景');
  }

  static previousSessionNotEnded(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.PreviousSessionNotEnded, '前序会话尚未结束');
  }

  static invalidEndedAt(): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.InvalidEndedAt, '结束时间不能早于开始时间');
  }

  static internal(message: string): WorldConversationSessionError {
    return new WorldConversationSessionError(SessionErrorKind.Internal, message);
  }
}

export function isSessionError(e: Error | Object): boolean {
  return e instanceof WorldConversationSessionError;
}
