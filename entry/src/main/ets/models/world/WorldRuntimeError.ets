

export enum WorldRuntimeErrorKind {
  WorldNotFound,
  SceneNotFound,
  SceneEnded,
  SessionNotFound,
  SessionEnded,
  SessionWorldMismatch,
  SessionSceneMismatch,
  SessionLocationMismatch,
  UnsupportedParticipantCount,
  ParticipantNotFound,
  ParticipantWorldMismatch,
  ParticipantLocationMismatch,
  CharacterNotFound,
  PlayerProfileNotFound,
  RuntimeBusy,
  EmptyUserMessage,
  ModelRequestFailed,
  ModelCancelled,
  StaleOperation,
  MessagePersistenceFailed,
  ParticipantSnapshotEmpty,
  ParticipantInactive,
  SpeakerCharacterNotFound,
  SpeakerEmptyResponse,
  RoundInterrupted,
  InvalidBatchState,
  ContextUnavailable
}

export class WorldRuntimeError extends Error {
  readonly kind: WorldRuntimeErrorKind;

  constructor(kind: WorldRuntimeErrorKind, message: string) {
    super(message);
    this.name = 'WorldRuntimeError';
    this.kind = kind;
  }

  static worldNotFound(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.WorldNotFound, '世界不存在');
  }

  static sceneNotFound(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.SceneNotFound, '场景不存在');
  }

  static sceneEnded(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.SceneEnded, '场景已结束,不允许生成');
  }

  static sessionNotFound(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.SessionNotFound, '会话不存在');
  }

  static sessionEnded(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.SessionEnded, '会话已结束,不允许生成');
  }

  static sessionWorldMismatch(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.SessionWorldMismatch, '会话不属于该世界');
  }

  static sessionSceneMismatch(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.SessionSceneMismatch, '会话不属于该场景');
  }

  static sessionLocationMismatch(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.SessionLocationMismatch, '会话地点不一致');
  }

  static unsupportedParticipantCount(count: number): WorldRuntimeError {
    return new WorldRuntimeError(
      WorldRuntimeErrorKind.UnsupportedParticipantCount,
      '仅支持单角色会话,当前参与者数=' + count.toString()
    );
  }

  static participantNotFound(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.ParticipantNotFound, '角色实例不存在');
  }

  static participantWorldMismatch(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.ParticipantWorldMismatch, '角色实例不属于该世界');
  }

  static participantLocationMismatch(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.ParticipantLocationMismatch, '角色实例不在会话地点');
  }

  static characterNotFound(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.CharacterNotFound, '角色卡不存在');
  }

  static playerProfileNotFound(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.PlayerProfileNotFound, '该世界无玩家档案');
  }

  static runtimeBusy(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.RuntimeBusy, '当前会话正在生成中');
  }

  static emptyUserMessage(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.EmptyUserMessage, '用户消息不能为空');
  }

  static modelRequestFailed(detail: string): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.ModelRequestFailed, '模型请求失败: ' + detail);
  }

  static modelCancelled(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.ModelCancelled, '模型请求已取消');
  }

  static staleOperation(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.StaleOperation, '过期的操作,回调已丢弃');
  }

  static messagePersistenceFailed(detail: string): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.MessagePersistenceFailed, '消息持久化失败: ' + detail);
  }

  static participantSnapshotEmpty(): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.ParticipantSnapshotEmpty, '会话参与者快照为空');
  }

  static participantInactive(displayName: string): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.ParticipantInactive,
      '参与者已停用: ' + displayName);
  }

  static speakerCharacterNotFound(instanceId: string): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.SpeakerCharacterNotFound,
      '发言角色卡缺失: ' + instanceId);
  }

  static speakerEmptyResponse(speakerName: string): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.SpeakerEmptyResponse,
      '角色回复为空: ' + speakerName);
  }

  static roundInterrupted(reason: string): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.RoundInterrupted,
      '轮次中断: ' + reason);
  }

  static invalidBatchState(detail: string): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.InvalidBatchState,
      '批次状态无效: ' + detail);
  }

  static contextUnavailable(category: string): WorldRuntimeError {
    return new WorldRuntimeError(WorldRuntimeErrorKind.ContextUnavailable,
      '跨会话上下文不可用: ' + category);
  }
}


