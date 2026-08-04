/**
 * WorldCharacterMemoryError 世界角色记忆业务错误
 *
 * W-MEMORY-1A 引入。由 WorldCharacterMemoryService 在事务业务规则校验失败时抛出。
 * 纯错误模型,不依赖 ArkUI / RDB / 页面。
 *
 * 安全规则:
 * - 用户可见 message 不包含完整 World/Character/Location/Memory ID、SQL、堆栈、内部表名
 * - 日志输出由 Service 层负责截断短 ID,本模型不携带原始 ID
 */

export enum WorldCharacterMemoryErrorKind {
  WorldNotFound,
  CharacterInstanceNotFound,
  CharacterInstanceNotInWorld,
  MemoryNotFound,
  MemoryWorldMismatch,
  MemoryContentEmpty,
  MemoryContentTooLong,
  InvalidMemoryType,
  InvalidImportance,
  LocationNotFound,
  LocationNotInWorld,
  InvalidOperation,
  Internal
}

export class WorldCharacterMemoryError extends Error {
  readonly kind: WorldCharacterMemoryErrorKind;

  constructor(kind: WorldCharacterMemoryErrorKind, message: string) {
    super(message);
    this.name = 'WorldCharacterMemoryError';
    this.kind = kind;
  }

  static worldNotFound(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(WorldCharacterMemoryErrorKind.WorldNotFound, '世界不存在');
  }

  static characterInstanceNotFound(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(
      WorldCharacterMemoryErrorKind.CharacterInstanceNotFound, '角色实例不存在');
  }

  static characterInstanceNotInWorld(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(
      WorldCharacterMemoryErrorKind.CharacterInstanceNotInWorld, '角色实例不属于该世界');
  }

  static memoryNotFound(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(WorldCharacterMemoryErrorKind.MemoryNotFound, '记忆不存在');
  }

  static memoryWorldMismatch(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(
      WorldCharacterMemoryErrorKind.MemoryWorldMismatch, '记忆不属于该世界或实例');
  }

  static memoryContentEmpty(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(
      WorldCharacterMemoryErrorKind.MemoryContentEmpty, '记忆正文不能为空');
  }

  static memoryContentTooLong(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(
      WorldCharacterMemoryErrorKind.MemoryContentTooLong, '记忆正文超过长度上限');
  }

  static invalidMemoryType(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(
      WorldCharacterMemoryErrorKind.InvalidMemoryType, '记忆类型不合法');
  }

  static invalidImportance(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(
      WorldCharacterMemoryErrorKind.InvalidImportance, '重要度必须在 1 到 5 之间');
  }

  static locationNotFound(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(
      WorldCharacterMemoryErrorKind.LocationNotFound, '地点不存在');
  }

  static locationNotInWorld(): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(
      WorldCharacterMemoryErrorKind.LocationNotInWorld, '地点不属于该世界');
  }

  static invalidOperation(message: string): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(WorldCharacterMemoryErrorKind.InvalidOperation, message);
  }

  static internal(message: string): WorldCharacterMemoryError {
    return new WorldCharacterMemoryError(WorldCharacterMemoryErrorKind.Internal, message);
  }
}

export function isWorldCharacterMemoryError(e: Error | Object): boolean {
  return e instanceof WorldCharacterMemoryError;
}
