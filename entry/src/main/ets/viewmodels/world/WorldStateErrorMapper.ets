/**
 * WorldStateErrorMapper 世界状态错误 → 用户安全文案映射(W-CONTROL-1A)
 *
 * 将 WorldStateErrorKind 映射为用户可理解的中文提示。
 * 不暴露:枚举原值、SQL、表名、完整 ID、堆栈。
 *
 * 依赖方向:ViewModel → WorldStateErrorMapper(纯函数)
 */

import { WorldStateError, WorldStateErrorKind, isWorldStateError } from '../../models/world/WorldStateError';

/**
 * 将错误对象映射为用户可见的安全文案。
 * - WorldStateError: 按 kind 映射为明确文案
 * - 其他错误: 返回通用"操作失败,请重试"
 */
export function mapWorldStateErrorToMessage(e: Object): string {
  if (isWorldStateError(e)) {
    const err: WorldStateError = e as WorldStateError;
    switch (err.kind) {
      case WorldStateErrorKind.WorldNotFound:
        return '世界不存在或已被删除';
      case WorldStateErrorKind.WorldArchived:
        return '世界已归档,不能修改其内容';
      case WorldStateErrorKind.WorldNameEmpty:
        return '世界名称不能为空';
      case WorldStateErrorKind.LocationNotFound:
        return '地点不存在或已被删除';
      case WorldStateErrorKind.LocationNotInWorld:
        return '地点不属于该世界';
      case WorldStateErrorKind.LocationNameEmpty:
        return '地点名称不能为空';
      case WorldStateErrorKind.DuplicateLocation:
        return '该世界中已存在同名地点';
      case WorldStateErrorKind.LocationHasCharacters:
        return '该地点仍有角色,请先移走或移除角色';
      case WorldStateErrorKind.CharacterNotFound:
        return '角色不存在或已被删除';
      case WorldStateErrorKind.CharacterAlreadyInWorld:
        return '该角色已在此世界中';
      case WorldStateErrorKind.CharacterInstanceNotFound:
        return '角色实例不存在或已被移除';
      case WorldStateErrorKind.CharacterInstanceInactive:
        return '角色实例未激活,请先启用';
      case WorldStateErrorKind.CharacterNotPlaced:
        return '角色尚未放置到任何地点';
      case WorldStateErrorKind.CharacterAlreadyAtLocation:
        return '角色已在该地点';
      case WorldStateErrorKind.InvalidOperation:
        return err.message.length > 0 ? err.message : '操作无效';
      case WorldStateErrorKind.Internal:
        return '世界数据操作失败,请重试';
      default:
        return '世界数据操作失败,请重试';
    }
  }
  return '操作失败,请重试';
}
