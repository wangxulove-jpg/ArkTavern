/**
 * GroupCharacterMemoryError 多人聊天角色记忆业务错误
 *
 * G-MEMORY-1A 引入。由 GroupCharacterMemoryService 在事务业务规则校验失败时抛出。
 * 纯错误模型,不依赖 ArkUI / RDB / 页面。
 *
 * 安全规则:
 * - 用户可见 message 不包含完整 Group/Character/Memory ID、SQL、堆栈、内部表名
 * - 日志输出由 Service 层负责截断短 ID,本模型不携带原始 ID
 */

export enum GroupCharacterMemoryErrorKind {
  GroupNotFound,
  CharacterNotFound,
  ParticipantNotFound,
  MemoryNotFound,
  InvalidTitle,
  InvalidContent,
  InvalidImportance,
  InvalidKeywords,
  InteractionMemoryReadOnly,
  InvalidStatusTransition,
  DatabaseFailure,
  Internal
}

export class GroupCharacterMemoryError extends Error {
  readonly kind: GroupCharacterMemoryErrorKind;

  constructor(kind: GroupCharacterMemoryErrorKind, message: string) {
    super(message);
    this.name = 'GroupCharacterMemoryError';
    this.kind = kind;
  }

  static groupNotFound(): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(GroupCharacterMemoryErrorKind.GroupNotFound, '群聊不存在');
  }

  static characterNotFound(): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(
      GroupCharacterMemoryErrorKind.CharacterNotFound, '角色不存在');
  }

  static participantNotFound(): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(
      GroupCharacterMemoryErrorKind.ParticipantNotFound, '该角色未加入当前群聊');
  }

  static memoryNotFound(): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(GroupCharacterMemoryErrorKind.MemoryNotFound, '记忆不存在');
  }

  static invalidTitle(): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(
      GroupCharacterMemoryErrorKind.InvalidTitle, '记忆标题不能为空或超过长度上限');
  }

  static invalidContent(): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(
      GroupCharacterMemoryErrorKind.InvalidContent, '记忆正文不能为空或超过长度上限');
  }

  static invalidImportance(): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(
      GroupCharacterMemoryErrorKind.InvalidImportance, '重要度必须在 1 到 5 之间');
  }

  static invalidKeywords(): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(
      GroupCharacterMemoryErrorKind.InvalidKeywords, '关键词格式不合法');
  }

  static interactionMemoryReadOnly(): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(
      GroupCharacterMemoryErrorKind.InteractionMemoryReadOnly, '交互记忆由消息来源管理,不能手动编辑');
  }

  static invalidStatusTransition(message: string): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(
      GroupCharacterMemoryErrorKind.InvalidStatusTransition, message);
  }

  static databaseFailure(message: string): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(
      GroupCharacterMemoryErrorKind.DatabaseFailure, message);
  }

  static internal(message: string): GroupCharacterMemoryError {
    return new GroupCharacterMemoryError(GroupCharacterMemoryErrorKind.Internal, message);
  }
}

export function isGroupCharacterMemoryError(e: Error | Object): boolean {
  return e instanceof GroupCharacterMemoryError;
}
