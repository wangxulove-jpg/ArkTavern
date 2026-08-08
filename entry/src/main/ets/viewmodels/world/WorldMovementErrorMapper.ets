import { WorldMovementError, WorldMovementErrorKind, isWorldMovementError } from '../../models/world/WorldMovementError';

export function mapWorldMovementErrorToMessage(e: Object): string {
  if (isWorldMovementError(e)) {
    const err: WorldMovementError = e as WorldMovementError;
    switch (err.kind) {
      case WorldMovementErrorKind.WorldNotFound:
        return '世界不存在或已被删除';
      case WorldMovementErrorKind.WorldArchived:
        return '世界已归档,不能移动角色';
      case WorldMovementErrorKind.CharacterInstanceNotFound:
        return '角色实例不存在或已被移除';
      case WorldMovementErrorKind.CharacterInstanceInactive:
        return '角色实例未激活,请先启用';
      case WorldMovementErrorKind.CharacterNotPlaced:
        return '角色尚未放置到任何地点,无法前往';
      case WorldMovementErrorKind.CharacterAlreadyAtLocation:
        return '角色已在该地点';
      case WorldMovementErrorKind.LocationNotFound:
        return '目标地点不存在或已被删除';
      case WorldMovementErrorKind.LocationNotInWorld:
        return '目标地点不属于该世界';
      case WorldMovementErrorKind.LocationArchived:
        return '目标地点已归档,无法前往';
      case WorldMovementErrorKind.NoEnabledPath:
        return '当前位置到目标地点没有可通行的连接';
      case WorldMovementErrorKind.EdgeDisabled:
        return '连接已停用,不可通行';
      case WorldMovementErrorKind.InvalidDirection:
        return '连接方向不允许此通行';
      case WorldMovementErrorKind.ActiveSessionConflict:
        return '角色正在活跃会话中,不能移动';
      case WorldMovementErrorKind.InvalidOperation:
        return err.message.length > 0 ? err.message : '操作无效';
      case WorldMovementErrorKind.Internal:
        return '移动操作失败,请重试';
      default:
        return '移动操作失败,请重试';
    }
  }
  return '操作失败,请重试';
}
