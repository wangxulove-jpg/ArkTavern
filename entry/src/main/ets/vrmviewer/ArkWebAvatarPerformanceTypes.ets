/**
 * ArkWebAvatarPerformanceTypes — 统一角色演出指令类型 (Phase 3F-1)
 *
 * 职责:
 *   - 定义统一演出命令 ArkWebAvatarPerformanceCommand
 *   - 定义演出状态机 ArkWebPerformanceState
 *   - 定义运行时回调接口 ArkWebAvatarPerformanceRuntime
 *   - 定义错误码 PerformanceErrorCode
 *   - 提供命令校验函数 validatePerformanceCommand
 *
 * 设计原则:
 *   - AI / 调用方只能传业务 ID (actionId / poseId / expressionId)
 *   - 严禁传文件路径 / relativePath / resourceId / Provider URL /
 *     Three.js 对象 / 骨骼数据 / Expression 实例
 *   - 本阶段只支持 interruptPolicy = REPLACE
 *   - 不实现 AI 接口 / 自然语言解析 / 演出队列 / CrossFade / 动作混合
 *
 * 状态流转:
 *   IDLE → RESOLVING → APPLYING → ACTIVE → RESTORING → IDLE
 *   任意 → FAILED (可由新命令重新进入 RESOLVING)
 *   任意 → DISPOSED (页面销毁,不可恢复)
 *
 * Reference:
 *   - AGENTS.md Phase 3F-1 §统一命令类型
 *   - ArkWebAvatarAssetTypes.ets (actionId / poseId 业务 ID 定义)
 *   - ArkWebExpressionAliasBusinessId (固定业务表情 ID)
 */

import { ArkWebExpressionAliasBusinessId } from './ArkWebAvatarAssetTypes';

/**
 * 演出动作类型。
 *
 * - animation: 播放一个已有动作 (motionId = actionId)
 * - pose: 应用一个已有姿势 (motionId = poseId)
 * - none: 不加载动作或姿势, 只设置临时表情
 */
export type ArkWebPerformanceMotionType =
  'animation' | 'pose' | 'none';

/**
 * 中断策略。
 *
 * 本阶段只支持 REPLACE: 新命令替换当前演出。
 * 后续阶段可能增加 QUEUE / IGNORE 等策略。
 */
export type ArkWebPerformanceInterruptPolicy =
  'REPLACE';

/**
 * 到期恢复策略。
 *
 * - DEFAULT_POSE: 停止动画 + 取消临时表情 + 恢复 defaultPoseId (无则 resetPose)
 * - RESET: 停止动画 + 取消临时表情 + resetPose
 * - KEEP: 不停止动作或姿势, 只结束 PerformanceController 的 ACTIVE 状态
 *         (临时表情仍按其自身 duration 恢复)
 */
export type ArkWebPerformanceReturnPolicy =
  'DEFAULT_POSE' | 'RESET' | 'KEEP';

/**
 * 演出状态机。
 */
export enum ArkWebPerformanceState {
  /** 初始状态 / 已恢复 */
  IDLE = 'IDLE',
  /** 正在解析资源 ID (查找动作 / 姿势 / 别名) */
  RESOLVING = 'RESOLVING',
  /** 正在应用动作 / 姿势 / 表情 */
  APPLYING = 'APPLYING',
  /** 演出进行中, 等待到期 */
  ACTIVE = 'ACTIVE',
  /** 正在恢复默认状态 */
  RESTORING = 'RESTORING',
  /** 应用失败 (可由新命令重新进入 RESOLVING) */
  FAILED = 'FAILED',
  /** 已销毁, 不可恢复 */
  DISPOSED = 'DISPOSED'
}

/**
 * 演出错误码。
 */
export class PerformanceErrorCode {
  /** 控制器已销毁 */
  static readonly CONTROLLER_DISPOSED: string = 'PERFORMANCE_CONTROLLER_DISPOSED';
  /** 命令整体非法 (字段缺失 / 类型错误) */
  static readonly COMMAND_INVALID: string = 'PERFORMANCE_COMMAND_INVALID';
  /** motionType 非法 (非 animation/pose/none) */
  static readonly MOTION_TYPE_INVALID: string = 'PERFORMANCE_MOTION_TYPE_INVALID';
  /** animation/pose 缺少 motionId */
  static readonly MOTION_ID_REQUIRED: string = 'PERFORMANCE_MOTION_ID_REQUIRED';
  /** durationMs 超出 100..30000 */
  static readonly DURATION_INVALID: string = 'PERFORMANCE_DURATION_INVALID';
  /** expressionWeight 超出 0..1 */
  static readonly EXPRESSION_WEIGHT_INVALID: string = 'PERFORMANCE_EXPRESSION_WEIGHT_INVALID';
  /** actionId 在 library.animations 中找不到 */
  static readonly ACTION_NOT_FOUND: string = 'PERFORMANCE_ACTION_NOT_FOUND';
  /** poseId 在 library.poses 中找不到 */
  static readonly POSE_NOT_FOUND: string = 'PERFORMANCE_POSE_NOT_FOUND';
  /** expressionId 无法解析 (无映射 + 无同名 Expression) */
  static readonly EXPRESSION_NOT_RESOLVED: string = 'PERFORMANCE_EXPRESSION_NOT_RESOLVED';
  /** 动作应用失败 (loadAnimationResource / playAnimation) */
  static readonly MOTION_APPLY_FAILED: string = 'PERFORMANCE_MOTION_APPLY_FAILED';
  /** 表情应用失败 (setTemporaryExpressionByAlias) */
  static readonly EXPRESSION_APPLY_FAILED: string = 'PERFORMANCE_EXPRESSION_APPLY_FAILED';
  /** 旧 generation 的异步结果被提交 (已被新命令取代) */
  static readonly STALE_RESULT: string = 'PERFORMANCE_STALE_RESULT';
  /** 到期恢复失败 */
  static readonly RESTORE_FAILED: string = 'PERFORMANCE_RESTORE_FAILED';
}

/**
 * 统一演出命令。
 *
 * 字段约束 (详见 validatePerformanceCommand):
 *   - commandId: 非空字符串 (调用方生成, 用于日志和 stale 检查)
 *   - motionType: animation / pose / none
 *   - motionId: animation 时为 actionId, pose 时为 poseId, none 时必须为空
 *   - expressionId: 可空, 为空时跳过表情设置
 *                   非空时必须是固定业务 ID (neutral/happy/angry/sad/relaxed/surprised)
 *   - expressionWeight: 0..1
 *   - durationMs: 100..30000
 *   - interruptPolicy: REPLACE (本阶段唯一支持)
 *   - returnPolicy: DEFAULT_POSE / RESET / KEEP
 *
 * 禁止字段 (调用方不得传入):
 *   - absolutePath / relativePath / filesDir / sourceUri / cachePath
 *   - resourceId / resourceUrl / providerUrl
 *   - bone / skeleton / node / mesh / vrm / expression 等内部对象
 */
export interface ArkWebAvatarPerformanceCommand {
  commandId: string;
  motionType: ArkWebPerformanceMotionType;
  motionId: string;
  expressionId: string;
  expressionWeight: number;
  durationMs: number;
  interruptPolicy: ArkWebPerformanceInterruptPolicy;
  returnPolicy: ArkWebPerformanceReturnPolicy;
}

/**
 * 演出运行时回调接口。
 *
 * VrmViewerPage 使用现有方法实现这些回调, 注入到 PerformanceController。
 * PerformanceController 不得直接创建 GLTFLoader / AnimationMixer / VRMAnimationClip /
 * VRM Humanoid Node / VRM ExpressionManager / ArkWeb Provider。
 */
export interface ArkWebAvatarPerformanceRuntime {
  /** 停止当前动画 (对应 arkWebController.stopAnimation) */
  stopAnimation(): Promise<boolean>;
  /** 按 actionId 加载并播放动画 (复用 loadAnimationByActionId + playAnimation 流程) */
  playAnimationById(actionId: string): Promise<boolean>;
  /** 按 poseId 应用姿势 (复用 readPoseDataAsJson + applyPose 流程) */
  applyPoseById(poseId: string): Promise<boolean>;
  /** 调用 Web 端 resetPose (清除姿势, 不影响动画) */
  resetPose(): Promise<boolean>;
  /** 恢复默认姿势 (复用 defaultPoseId + applyPose 流程; 无默认姿势时降级为 resetPose) */
  restoreDefaultPose(): Promise<boolean>;
  /** 按 expressionId 设置临时表情 (复用 setTemporaryExpressionByAlias 流程) */
  setTemporaryExpressionByAlias(
    expressionId: string,
    weight: number,
    durationMs: number
  ): Promise<boolean>;
  /** 取消当前临时表情 (对应 arkWebController.cancelTemporaryExpression) */
  cancelTemporaryExpression(): Promise<boolean>;
}

/**
 * 演出结果 (executeCommand 返回)。
 */
export interface ArkWebPerformanceResult {
  success: boolean;
  state: ArkWebPerformanceState;
  commandId: string;
  generation: number;
  expiresAt: number;
  errorCode: string;
  errorMessage: string;
}

/**
 * 演出调试状态 (供 UI 显示)。
 */
export interface ArkWebPerformanceDebugState {
  state: ArkWebPerformanceState;
  performanceGeneration: number;
  currentCommandId: string;
  currentMotionType: string;
  currentMotionId: string;
  currentExpressionId: string;
  currentExpressionWeight: number;
  expiresAt: number;
  restoreTimerActive: boolean;
  lastErrorCode: string;
  lastErrorMessage: string;
}

/**
 * durationMs 范围。
 */
export const PERFORMANCE_DURATION_MIN_MS: number = 100;
export const PERFORMANCE_DURATION_MAX_MS: number = 30000;

/**
 * 禁止字段白名单 (调用方不得传入)。
 */
const FORBIDDEN_COMMAND_FIELDS: string[] = [
  'absolutePath', 'relativePath', 'filesDir', 'sourceUri', 'cachePath',
  'resourceId', 'resourceUrl', 'providerUrl',
  'bone', 'skeleton', 'node', 'mesh', 'vrm', 'expression'
];

/**
 * 校验演出命令。
 *
 * 规则:
 *   - commandId 非空字符串
 *   - motionType ∈ {animation, pose, none}
 *   - motionId:
 *     - animation 时非空 (actionId)
 *     - pose 时非空 (poseId)
 *     - none 时必须为空
 *   - expressionId 可空; 非空时必须是固定业务 ID
 *   - expressionWeight ∈ [0, 1]
 *   - durationMs ∈ [100, 30000]
 *   - interruptPolicy ∈ {REPLACE}
 *   - returnPolicy ∈ {DEFAULT_POSE, RESET, KEEP}
 *   - 不得包含任何禁止字段
 *   - motionType = none 且 expressionId 为空时返回 COMMAND_INVALID
 *
 * @returns 错误码字符串; 成功返回空字符串
 */
export function validatePerformanceCommand(
  cmd: ArkWebAvatarPerformanceCommand
): string {
  if (cmd === null || typeof cmd !== 'object') {
    return PerformanceErrorCode.COMMAND_INVALID;
  }
  // commandId
  if (typeof cmd.commandId !== 'string' || cmd.commandId.length === 0) {
    return PerformanceErrorCode.COMMAND_INVALID;
  }
  // motionType
  const motionType: string = cmd.motionType;
  if (motionType !== 'animation' && motionType !== 'pose' && motionType !== 'none') {
    return PerformanceErrorCode.MOTION_TYPE_INVALID;
  }
  // motionId
  const motionId: string = cmd.motionId;
  if (motionType === 'animation' || motionType === 'pose') {
    if (typeof motionId !== 'string' || motionId.length === 0) {
      return PerformanceErrorCode.MOTION_ID_REQUIRED;
    }
  } else {
    // none
    if (typeof motionId !== 'string' || motionId.length > 0) {
      return PerformanceErrorCode.COMMAND_INVALID;
    }
  }
  // expressionId (可空)
  const expressionId: string = cmd.expressionId;
  if (typeof expressionId !== 'string') {
    return PerformanceErrorCode.COMMAND_INVALID;
  }
  if (expressionId.length > 0) {
    if (!ArkWebExpressionAliasBusinessId.isValid(expressionId)) {
      return PerformanceErrorCode.COMMAND_INVALID;
    }
  } else {
    // expressionId 为空时 motionType 必须非 none
    if (motionType === 'none') {
      return PerformanceErrorCode.COMMAND_INVALID;
    }
  }
  // expressionWeight
  const weight: number = cmd.expressionWeight;
  if (typeof weight !== 'number' || !Number.isFinite(weight) || weight < 0 || weight > 1) {
    return PerformanceErrorCode.EXPRESSION_WEIGHT_INVALID;
  }
  // durationMs
  const duration: number = cmd.durationMs;
  if (typeof duration !== 'number' || !Number.isFinite(duration)
      || duration < PERFORMANCE_DURATION_MIN_MS
      || duration > PERFORMANCE_DURATION_MAX_MS) {
    return PerformanceErrorCode.DURATION_INVALID;
  }
  // interruptPolicy
  if (cmd.interruptPolicy !== 'REPLACE') {
    return PerformanceErrorCode.COMMAND_INVALID;
  }
  // returnPolicy
  const returnPolicy: string = cmd.returnPolicy;
  if (returnPolicy !== 'DEFAULT_POSE' && returnPolicy !== 'RESET' && returnPolicy !== 'KEEP') {
    return PerformanceErrorCode.COMMAND_INVALID;
  }
  // 禁止字段
  const cmdKeys: string[] = Object.keys(cmd);
  for (let i = 0; i < cmdKeys.length; i++) {
    if (FORBIDDEN_COMMAND_FIELDS.indexOf(cmdKeys[i]) !== -1) {
      return PerformanceErrorCode.COMMAND_INVALID;
    }
  }
  return '';
}
