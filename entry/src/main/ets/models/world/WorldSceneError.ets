/**
 * WorldSceneError 世界场景业务错误
 *
 * W-SCENE-1B 引入。由 WorldSceneService 在事务业务规则校验失败时抛出。
 * 纯错误模型,不依赖 ArkUI / RDB / 页面。
 *
 * 安全规则:
 * - 用户可见 message 不包含完整 World/Character/Location/Scene/Message ID
 * - 不包含 SQL、表名、堆栈
 * - 不包含 recipient/witness/participant 数组内容
 */

export enum WorldSceneErrorKind {
  WorldNotFound,
  WorldArchived,
  LocationNotFound,
  LocationNotInWorld,
  LocationArchived,
  SceneNotFound,
  SceneAlreadyActive,
  SceneAlreadyEnded,
  SceneNotActive,
  MessageContentEmpty,
  InvalidSender,
  InvalidVisibility,
  RecipientRequired,
  RecipientNotAllowed,
  WitnessNotAllowed,
  ReplyTargetNotAllowed,
  CharacterInstanceNotFound,
  CharacterInstanceNotInWorld,
  CharacterInstanceNotAtSceneLocation,
  CharacterInstanceInactive,
  InvalidOperation,
  Internal
}

export class WorldSceneError extends Error {
  readonly kind: WorldSceneErrorKind;

  constructor(kind: WorldSceneErrorKind, message: string) {
    super(message);
    this.name = 'WorldSceneError';
    this.kind = kind;
  }

  static worldNotFound(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.WorldNotFound, '世界不存在或已被删除');
  }

  static worldArchived(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.WorldArchived, '世界已归档,不能修改其内容');
  }

  static locationNotFound(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.LocationNotFound, '地点不存在或已被删除');
  }

  static locationNotInWorld(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.LocationNotInWorld, '地点不属于该世界');
  }

  static locationArchived(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.LocationArchived, '地点已归档,不能开始场景');
  }

  static sceneNotFound(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.SceneNotFound, '场景不存在或已被删除');
  }

  static sceneAlreadyActive(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.SceneAlreadyActive, '该地点已有进行中的场景,请先结束当前场景');
  }

  static sceneAlreadyEnded(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.SceneAlreadyEnded, '场景已经结束,不能再次结束');
  }

  static sceneNotActive(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.SceneNotActive, '场景已结束,不能继续添加消息');
  }

  static messageContentEmpty(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.MessageContentEmpty, '消息正文不能为空');
  }

  static invalidSender(message: string): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.InvalidSender, message);
  }

  static invalidVisibility(message: string): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.InvalidVisibility, message);
  }

  static recipientRequired(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.RecipientRequired, '私下消息必须选择接收者');
  }

  static recipientNotAllowed(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.RecipientNotAllowed, '公开消息不能指定接收者');
  }

  static witnessNotAllowed(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.WitnessNotAllowed, '目击者仅适用于旁白消息');
  }

  static replyTargetNotAllowed(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.ReplyTargetNotAllowed, '回复目标仅适用于公开用户消息');
  }

  static characterInstanceNotFound(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.CharacterInstanceNotFound, '角色实例不存在或已被移除');
  }

  static characterInstanceNotInWorld(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.CharacterInstanceNotInWorld, '角色实例不属于当前世界');
  }

  static characterInstanceNotAtSceneLocation(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.CharacterInstanceNotAtSceneLocation, '角色实例不在当前场景地点');
  }

  static characterInstanceInactive(): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.CharacterInstanceInactive, '角色实例未激活,不能参与新消息');
  }

  static invalidOperation(message: string): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.InvalidOperation, message);
  }

  static internal(message: string): WorldSceneError {
    return new WorldSceneError(WorldSceneErrorKind.Internal, message);
  }
}

export function isWorldSceneError(e: Error | Object): boolean {
  return e instanceof WorldSceneError;
}
