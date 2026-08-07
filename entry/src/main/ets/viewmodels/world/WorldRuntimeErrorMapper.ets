
import {
  WorldRuntimeError,
  WorldRuntimeErrorKind
} from '../../models/world/WorldRuntimeError';

export function isWorldRuntimeError(e: Object): boolean {
  return e instanceof WorldRuntimeError;
}

export function mapWorldRuntimeErrorToMessage(e: Object): string {
  if (isWorldRuntimeError(e)) {
    const err: WorldRuntimeError = e as WorldRuntimeError;
    switch (err.kind) {
      case WorldRuntimeErrorKind.WorldNotFound:
        return '世界不存在或已被删除';
      case WorldRuntimeErrorKind.SceneNotFound:
        return '场景不存在或已被删除';
      case WorldRuntimeErrorKind.SceneEnded:
        return '场景已结束,不能继续对话';
      case WorldRuntimeErrorKind.SessionNotFound:
        return '会话不存在';
      case WorldRuntimeErrorKind.SessionEnded:
        return '会话已结束,不能继续对话';
      case WorldRuntimeErrorKind.SessionWorldMismatch:
        return '会话数据不一致';
      case WorldRuntimeErrorKind.SessionSceneMismatch:
        return '会话数据不一致';
      case WorldRuntimeErrorKind.SessionLocationMismatch:
        return '会话地点数据不一致';
      case WorldRuntimeErrorKind.UnsupportedParticipantCount:
        return '多人世界聊天将在下一阶段接入';
      case WorldRuntimeErrorKind.ParticipantNotFound:
        return '角色实例不存在或已被移除';
      case WorldRuntimeErrorKind.ParticipantWorldMismatch:
        return '角色实例数据不一致';
      case WorldRuntimeErrorKind.ParticipantLocationMismatch:
        return '角色不在当前地点';
      case WorldRuntimeErrorKind.CharacterNotFound:
        return '角色卡不存在';
      case WorldRuntimeErrorKind.PlayerProfileNotFound:
        return '该世界未设置玩家档案';
      case WorldRuntimeErrorKind.RuntimeBusy:
        return '当前角色正在回复中';
      case WorldRuntimeErrorKind.EmptyUserMessage:
        return '消息不能为空';
      case WorldRuntimeErrorKind.ModelRequestFailed:
        return '请求失败,请稍后重试';
      case WorldRuntimeErrorKind.ModelCancelled:
        return '生成已取消';
      case WorldRuntimeErrorKind.StaleOperation:
        return '操作已过期';
      case WorldRuntimeErrorKind.MessagePersistenceFailed:
        return '消息保存失败,请重试';
      default:
        return '操作失败,请重试';
    }
  }
  return '操作失败,请重试';
}
