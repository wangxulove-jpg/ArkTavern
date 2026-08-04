/**
 * WorldMemoryErrorMapper 世界角色记忆错误 → 用户安全文案映射(W-MEMORY-1A)
 *
 * 将 WorldCharacterMemoryErrorKind 映射为用户可理解的中文提示。
 * 不暴露:枚举原值、SQL、表名、完整 ID、堆栈、记忆正文。
 *
 * 依赖方向:ViewModel → WorldMemoryErrorMapper(纯函数)
 */

import {
  WorldCharacterMemoryError,
  WorldCharacterMemoryErrorKind,
  isWorldCharacterMemoryError
} from '../../models/world/WorldCharacterMemoryError';
import { DatabaseError } from '../../models/DatabaseError';

/**
 * 将错误对象映射为用户可见的安全文案。
 * - WorldCharacterMemoryError: 按 kind 映射为明确文案
 * - DatabaseError: 通用数据库错误文案
 * - 其他错误: 返回通用"操作失败,请重试"
 */
export function mapWorldMemoryErrorToMessage(e: Object): string {
  if (isWorldCharacterMemoryError(e)) {
    const err: WorldCharacterMemoryError = e as WorldCharacterMemoryError;
    switch (err.kind) {
      case WorldCharacterMemoryErrorKind.WorldNotFound:
        return '世界不存在或已被删除';
      case WorldCharacterMemoryErrorKind.CharacterInstanceNotFound:
        return '角色实例不存在或已被移除';
      case WorldCharacterMemoryErrorKind.CharacterInstanceNotInWorld:
        return '角色实例不属于当前世界';
      case WorldCharacterMemoryErrorKind.MemoryNotFound:
        return '记忆不存在或已被删除';
      case WorldCharacterMemoryErrorKind.MemoryWorldMismatch:
        return '记忆不属于当前世界或角色';
      case WorldCharacterMemoryErrorKind.MemoryContentEmpty:
        return '记忆正文不能为空';
      case WorldCharacterMemoryErrorKind.MemoryContentTooLong:
        return '记忆正文超过长度上限';
      case WorldCharacterMemoryErrorKind.InvalidMemoryType:
        return '记忆类型不合法';
      case WorldCharacterMemoryErrorKind.InvalidImportance:
        return '重要度必须在 1 到 5 之间';
      case WorldCharacterMemoryErrorKind.LocationNotFound:
        return '地点不存在或已被删除';
      case WorldCharacterMemoryErrorKind.LocationNotInWorld:
        return '地点不属于当前世界';
      case WorldCharacterMemoryErrorKind.InvalidOperation:
        return err.message.length > 0 ? err.message : '操作无效';
      case WorldCharacterMemoryErrorKind.Internal:
        return '记忆数据操作失败,请重试';
      default:
        return '记忆数据操作失败,请重试';
    }
  }
  if (e instanceof DatabaseError) {
    return '记忆数据操作失败,请重试';
  }
  return '操作失败,请重试';
}
