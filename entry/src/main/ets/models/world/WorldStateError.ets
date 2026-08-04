/**
 * WorldStateError 世界模式业务错误
 *
 * W-DATA-1B 引入。由 WorldStateService 在事务业务规则校验失败时抛出。
 * 纯错误模型,不依赖 ArkUI / RDB / 页面。
 *
 * 安全规则:
 * - 用户可见 message 不包含完整 World/Character/Location ID、SQL、堆栈、内部表名
 * - worldReferenceCount 仅用于 CharacterReferencedByWorld 场景的数量提示,不含 ID
 * - 日志输出由 Service 层负责截断短 ID,本模型不携带原始 ID
 */

export enum WorldStateErrorKind {
  WorldNotFound,
  WorldArchived,
  WorldNameEmpty,
  LocationNotFound,
  LocationNotInWorld,
  LocationNameEmpty,
  DuplicateLocation,
  LocationHasCharacters,
  LocationHasScenes,
  EdgeNotFound,
  EdgeWorldMismatch,
  EdgeSelfConnection,
  EdgeConflict,
  CharacterNotFound,
  CharacterAlreadyInWorld,
  CharacterInstanceNotFound,
  CharacterInstanceInactive,
  CharacterNotPlaced,
  CharacterAlreadyAtLocation,
  NoEnabledPath,
  InvalidOperation,
  Internal
}

export class WorldStateError extends Error {
  readonly kind: WorldStateErrorKind;

  constructor(kind: WorldStateErrorKind, message: string) {
    super(message);
    this.name = 'WorldStateError';
    this.kind = kind;
  }

  static worldNotFound(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.WorldNotFound, '世界不存在');
  }

  static worldArchived(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.WorldArchived, '世界已归档,不能修改其内容');
  }

  static worldNameEmpty(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.WorldNameEmpty, '世界名称不能为空');
  }

  static locationNotFound(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.LocationNotFound, '地点不存在');
  }

  static locationNotInWorld(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.LocationNotInWorld, '地点不属于该世界');
  }

  static locationNameEmpty(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.LocationNameEmpty, '地点名称不能为空');
  }

  static duplicateLocation(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.DuplicateLocation, '同名地点已存在');
  }

  static locationHasCharacters(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.LocationHasCharacters, '地点上仍有角色,无法归档或删除');
  }

  static locationHasScenes(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.LocationHasScenes, '该地点已有场景历史,不能永久删除;可以将地点归档');
  }

  static edgeNotFound(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.EdgeNotFound, '连接不存在');
  }

  static edgeWorldMismatch(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.EdgeWorldMismatch, '连接的地点不属于同一世界');
  }

  static edgeSelfConnection(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.EdgeSelfConnection, '不能创建起点和终点相同的连接');
  }

  static edgeConflict(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.EdgeConflict, '已存在冲突的连接');
  }

  static characterNotFound(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.CharacterNotFound, '角色不存在');
  }

  static characterAlreadyInWorld(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.CharacterAlreadyInWorld, '该角色已在此世界中');
  }

  static characterInstanceNotFound(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.CharacterInstanceNotFound, '角色实例不存在');
  }

  static characterInstanceInactive(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.CharacterInstanceInactive, '角色实例未激活');
  }

  static characterNotPlaced(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.CharacterNotPlaced, '角色尚未放置到任何地点');
  }

  static characterAlreadyAtLocation(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.CharacterAlreadyAtLocation, '角色已在该地点');
  }

  static noEnabledPath(): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.NoEnabledPath, '当前地点到目标地点没有可通行的连接');
  }

  static invalidOperation(message: string): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.InvalidOperation, message);
  }

  static internal(message: string): WorldStateError {
    return new WorldStateError(WorldStateErrorKind.Internal, message);
  }
}

export function isWorldStateError(e: Error | Object): boolean {
  return e instanceof WorldStateError;
}

/**
 * CharacterReferencedByWorldError
 *
 * 当 Character 被任意 WorldCharacterInstance 引用时,CharacterService.remove 抛出此错误。
 * W-DATA-1B 角色删除引用保护。
 *
 * - worldReferenceCount: 引用该角色的世界角色实例数量(跨全部 World),可用于用户提示,不含 ID
 * - message: 用户可见提示,不含内部 ID / SQL / 堆栈
 */
export class CharacterReferencedByWorldError extends Error {
  readonly worldReferenceCount: number;

  constructor(worldReferenceCount: number) {
    super('该角色正在世界模式中使用,请先从相关世界移除角色');
    this.name = 'CharacterReferencedByWorldError';
    this.worldReferenceCount = worldReferenceCount;
  }
}

export function isCharacterReferencedByWorldError(e: Error | Object): boolean {
  return e instanceof CharacterReferencedByWorldError;
}
