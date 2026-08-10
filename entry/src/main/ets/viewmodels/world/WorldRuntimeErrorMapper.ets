
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
        return '不支持的参与者数量';
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
        if (err.message.includes('未配置 Provider')) {
          return '请先在模型设置中配置 API Provider';
        }
        return '请求失败,请稍后重试';
      case WorldRuntimeErrorKind.ModelCancelled:
        return '生成已取消';
      case WorldRuntimeErrorKind.StaleOperation:
        return '操作已过期';
      case WorldRuntimeErrorKind.MessagePersistenceFailed:
        return '消息保存失败,请重试';
      case WorldRuntimeErrorKind.ParticipantSnapshotEmpty:
        return '会话无参与者';
      case WorldRuntimeErrorKind.ParticipantInactive:
        return '参与者已停用,无法生成';
      case WorldRuntimeErrorKind.SpeakerCharacterNotFound:
        return '发言角色卡缺失';
      case WorldRuntimeErrorKind.SpeakerEmptyResponse:
        return '角色回复为空';
      case WorldRuntimeErrorKind.RoundInterrupted:
        return '本轮生成已中断';
      case WorldRuntimeErrorKind.InvalidBatchState:
        return '生成状态异常,请重试';
      case WorldRuntimeErrorKind.ContextUnavailable:
        return '跨会话上下文不可用';
      default:
        return '操作失败,请重试';
    }
  }
  return '操作失败,请重试';
}
