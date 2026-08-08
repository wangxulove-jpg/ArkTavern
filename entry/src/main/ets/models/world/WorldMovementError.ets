export enum WorldMovementErrorKind {
  WorldNotFound,
  WorldArchived,
  CharacterInstanceNotFound,
  CharacterInstanceInactive,
  CharacterNotPlaced,
  CharacterAlreadyAtLocation,
  LocationNotFound,
  LocationNotInWorld,
  LocationArchived,
  NoEnabledPath,
  EdgeDisabled,
  InvalidDirection,
  ActiveSessionConflict,
  InvalidOperation,
  Internal
}

export class WorldMovementError extends Error {
  readonly kind: WorldMovementErrorKind;

  constructor(kind: WorldMovementErrorKind, message: string) {
    super(message);
    this.name = 'WorldMovementError';
    this.kind = kind;
  }

  static worldNotFound(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.WorldNotFound, '世界不存在');
  }

  static worldArchived(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.WorldArchived, '世界已归档,不能移动角色');
  }

  static characterInstanceNotFound(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.CharacterInstanceNotFound, '角色实例不存在');
  }

  static characterInstanceInactive(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.CharacterInstanceInactive, '角色实例未激活');
  }

  static characterNotPlaced(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.CharacterNotPlaced, '角色尚未放置到任何地点');
  }

  static characterAlreadyAtLocation(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.CharacterAlreadyAtLocation, '角色已在该地点');
  }

  static locationNotFound(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.LocationNotFound, '地点不存在');
  }

  static locationNotInWorld(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.LocationNotInWorld, '地点不属于该世界');
  }

  static locationArchived(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.LocationArchived, '目标地点已归档');
  }

  static noEnabledPath(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.NoEnabledPath, '当前地点到目标地点没有可通行的连接');
  }

  static edgeDisabled(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.EdgeDisabled, '连接已停用,不可通行');
  }

  static invalidDirection(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.InvalidDirection, '连接方向不允许此通行');
  }

  static activeSessionConflict(): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.ActiveSessionConflict, '角色正在活跃会话中,不能移动');
  }

  static invalidOperation(message: string): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.InvalidOperation, message);
  }

  static internal(message: string): WorldMovementError {
    return new WorldMovementError(WorldMovementErrorKind.Internal, message);
  }
}

export function isWorldMovementError(e: Error | Object): boolean {
  return e instanceof WorldMovementError;
}
