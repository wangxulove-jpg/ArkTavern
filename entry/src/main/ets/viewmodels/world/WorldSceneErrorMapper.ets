/**
 * WorldSceneErrorMapper 世界场景错误 → 用户安全文案映射(W-SCENE-1B)
 *
 * 将 WorldSceneErrorKind 映射为用户可理解的中文提示。
 * 不暴露:枚举原值、SQL、表名、完整 ID、堆栈、recipient/witness/participant 数组内容。
 *
 * 依赖方向:ViewModel → WorldSceneErrorMapper(纯函数)
 */

import { WorldSceneError, WorldSceneErrorKind, isWorldSceneError } from '../../models/world/WorldSceneError';

/**
 * 将错误对象映射为用户可见的安全文案。
 * - WorldSceneError: 按 kind 映射为明确文案
 * - 其他错误: 返回通用"操作失败,请重试"
 */
export function mapWorldSceneErrorToMessage(e: Object): string {
  if (isWorldSceneError(e)) {
    const err: WorldSceneError = e as WorldSceneError;
    switch (err.kind) {
      case WorldSceneErrorKind.WorldNotFound:
        return '世界不存在或已被删除';
      case WorldSceneErrorKind.WorldArchived:
        return '世界已归档,不能修改其内容';
      case WorldSceneErrorKind.LocationNotFound:
        return '地点不存在或已被删除';
      case WorldSceneErrorKind.LocationNotInWorld:
        return '地点不属于该世界';
      case WorldSceneErrorKind.LocationArchived:
        return '地点已归档,不能开始场景';
      case WorldSceneErrorKind.SceneNotFound:
        return '场景不存在或已被删除';
      case WorldSceneErrorKind.SceneAlreadyActive:
        return '该地点已有进行中的场景,请先结束当前场景';
      case WorldSceneErrorKind.SceneAlreadyEnded:
        return '场景已经结束,不能再次结束';
      case WorldSceneErrorKind.SceneNotActive:
        return '场景已结束,不能继续添加消息';
      case WorldSceneErrorKind.MessageContentEmpty:
        return '消息正文不能为空';
      case WorldSceneErrorKind.InvalidSender:
        return err.message.length > 0 ? err.message : '发送者无效';
      case WorldSceneErrorKind.InvalidVisibility:
        return err.message.length > 0 ? err.message : '消息可见范围无效';
      case WorldSceneErrorKind.RecipientRequired:
        return '私下消息必须选择接收者';
      case WorldSceneErrorKind.RecipientNotAllowed:
        return '公开消息不能指定接收者';
      case WorldSceneErrorKind.WitnessNotAllowed:
        return '目击者仅适用于旁白消息';
      case WorldSceneErrorKind.ReplyTargetNotAllowed:
        return '回复目标仅适用于公开用户消息';
      case WorldSceneErrorKind.CharacterInstanceNotFound:
        return '角色实例不存在或已被移除';
      case WorldSceneErrorKind.CharacterInstanceNotInWorld:
        return '角色实例不属于当前世界';
      case WorldSceneErrorKind.CharacterInstanceNotAtSceneLocation:
        return '角色实例不在当前场景地点';
      case WorldSceneErrorKind.CharacterInstanceInactive:
        return '角色实例未激活,不能参与新消息';
      case WorldSceneErrorKind.InvalidOperation:
        return err.message.length > 0 ? err.message : '操作无效';
      case WorldSceneErrorKind.Internal:
        return '场景数据操作失败,请重试';
      default:
        return '场景数据操作失败,请重试';
    }
  }
  return '操作失败,请重试';
}
