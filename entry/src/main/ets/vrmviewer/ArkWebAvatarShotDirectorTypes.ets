/**
 * ArkWebAvatarShotDirectorTypes — Avatar Shot Director 类型定义 (Phase 4B-2)
 *
 * 设计依据:
 * - docs/vrm/ARKWEB_FIGURE_PORT_CHECKPOINT.md Phase 4B-2
 * - 固定镜头规则: 只支持 FULL_BODY / FACE_RESET_VIEW
 * - FACE_RESET_VIEW 复用现有重置按钮的相机方法 (smoothResetCamera)
 * - FULL_BODY 复用现有 fitAvatarFullBody
 *
 * 禁止:
 * - 头部 BoundingBox 计算
 * - 脸部骨骼/眼睛位置计算
 * - 硬编码第二套脸部相机坐标
 * - 第二个相机 Frame Loop
 */

import { ArkWebAvatarPerformanceCommand } from './ArkWebAvatarPerformanceTypes';

/**
 * 业务镜头类型。
 *
 * 只支持两个固定镜头:
 * - FULL_BODY: 全身构图, 复用 fitAvatarFullBody (Phase 4B-1 已有)
 * - FACE_RESET_VIEW: 脸部视角, 复用重置按钮的 smoothResetCamera (Figure 基准)
 *
 * 禁止扩展第三个镜头类型。禁止硬编码自定义脸部坐标。
 */
export type ArkWebAvatarShot = 'FULL_BODY' | 'FACE_RESET_VIEW';

/**
 * Shot Director 状态机。
 *
 * - IDLE: 初始状态 / 无活动镜头
 * - TRANSITIONING: 正在平滑切换镜头
 * - FULL_BODY: 当前为全身镜头
 * - FACE_RESET_VIEW: 当前为脸部 (重置) 镜头
 * - FAILED: 镜头切换失败 (不阻塞聊天文本)
 * - DISPOSED: 已销毁
 */
export type ArkWebAvatarShotDirectorState =
  'IDLE'
  | 'TRANSITIONING'
  | 'FULL_BODY'
  | 'FACE_RESET_VIEW'
  | 'FAILED'
  | 'DISPOSED';

/**
 * 镜头运行时回调接口。
 *
 * 由 ArkWebChatAvatarStageController 实现, 包装 ArkWebVrmViewerController 的相机方法。
 * ShotDirector 通过此接口调用相机, 不直接持有 ArkWebVrmViewerController。
 *
 * 要求:
 * - transitionToFullBody: 调用 fitAvatarFullBody (Phase 4B-1 已有)
 * - transitionToResetView: 调用 smoothResetCamera (与重置按钮相同)
 * - cancelCameraTransition: 调用 cancelCameraTransition (取消正在进行的过渡)
 * - isModelReady: 检查当前模型是否 READY (镜头切换前提)
 * - isStageSizeValid: 检查 Stage 尺寸是否有效 (FULL_BODY 前提)
 */
export interface ArkWebAvatarShotRuntime {
  /** 平滑切换到全身构图 (调用 fitAvatarFullBody) */
  transitionToFullBody(): Promise<boolean>;
  /** 平滑切换到重置视角 (调用 smoothResetCamera, 与重置按钮相同) */
  transitionToResetView(): Promise<boolean>;
  /** 取消正在进行的相机过渡 */
  cancelCameraTransition(reason: string): Promise<boolean>;
  /** 检查当前模型是否 READY */
  isModelReady(): boolean;
  /** 检查 Stage 尺寸是否有效 (>0) */
  isStageSizeValid(): boolean;
}

/**
 * 镜头错误码。
 */
export class ShotDirectorErrorCode {
  /** ShotDirector 已销毁 */
  static readonly SHOT_DIRECTOR_DISPOSED: string = 'SHOT_DIRECTOR_DISPOSED';
  /** 演出命令非法 (motionType 不合法) */
  static readonly SHOT_COMMAND_INVALID: string = 'SHOT_COMMAND_INVALID';
  /** 相机未就绪 (Viewer 未 READY / 模型未加载) */
  static readonly SHOT_CAMERA_NOT_READY: string = 'SHOT_CAMERA_NOT_READY';
  /** 镜头过渡失败 (Web 端返回失败) */
  static readonly SHOT_TRANSITION_FAILED: string = 'SHOT_TRANSITION_FAILED';
  /** 旧 generation 结果过期, 被忽略 */
  static readonly SHOT_STALE_RESULT: string = 'SHOT_STALE_RESULT';
}

/**
 * 镜头运行时快照 (供 AI 面板诊断显示)。
 */
export interface ArkWebAvatarShotRuntimeSnapshot {
  /** 当前状态 */
  state: ArkWebAvatarShotDirectorState;
  /** 当前镜头 */
  currentShot: ArkWebAvatarShot;
  /** 请求中镜头 (TRANSITIONING 时) */
  requestedShot: ArkWebAvatarShot;
  /** 当前 generation */
  shotGeneration: number;
  /** 最近过渡原因 */
  lastTransitionReason: string;
  /** 最近错误码 */
  lastErrorCode: string;
  /** 最近错误信息 */
  lastErrorMessage: string;
  /** 是否存在表情恢复定时器 */
  hasExpressionReturnTimer: boolean;
  /** 表情恢复定时器关联的 commandId */
  expressionReturnCommandId: string;
}

/**
 * 判断演出命令对应的目标镜头。
 *
 * 规则:
 * - motionType = animation → FULL_BODY (动画过程保持全身可见)
 * - motionType = pose → FULL_BODY (姿势应用后保持全身可见)
 * - motionType = none + expressionId 非空 → FACE_RESET_VIEW (仅表情时切到脸部)
 * - motionType = none + expressionId 为空 → 非法 (返回 null)
 *
 * 动画/姿势带表情仍为 FULL_BODY (不进入脸部视角)。
 *
 * @param command 演出命令
 * @returns 目标镜头, 命令非法时返回 null
 */
export function resolveTargetShot(
  command: ArkWebAvatarPerformanceCommand
): ArkWebAvatarShot | null {
  const motionType: string = command.motionType;
  if (motionType === 'animation' || motionType === 'pose') {
    return 'FULL_BODY';
  }
  if (motionType === 'none') {
    if (command.expressionId.length > 0) {
      return 'FACE_RESET_VIEW';
    }
    return null;
  }
  return null;
}
