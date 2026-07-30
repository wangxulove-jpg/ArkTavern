/**
 * ArkWebAvatarShotDirector — Avatar 镜头导演 (Phase 4B-2)
 *
 * 职责:
 * - 根据演出命令决定目标镜头 (FULL_BODY / FACE_RESET_VIEW)
 * - 平滑切换镜头 (复用现有 smoothResetCamera / fitAvatarFullBody)
 * - 维护 generation 防止旧异步结果覆盖新状态
 * - 管理表情恢复定时器 (仅 expression-only 命令)
 * - 模型 READY / Stage 重新显示 / 停止演出 / 演出失败时恢复 FULL_BODY
 *
 * 禁止:
 * - 直接调用 ArkWebVrmViewerController (必须通过 ArkWebAvatarShotRuntime)
 * - 头部 BoundingBox / 脸部骨骼 / 眼睛位置计算
 * - 硬编码第二套脸部相机坐标
 * - setInterval / requestAnimationFrame / 第二个相机 Frame Loop
 * - 修改 model.scene.position / scale / 骨骼
 *
 * 镜头来源:
 * - FULL_BODY → runtime.transitionToFullBody() (复用 fitAvatarFullBody)
 * - FACE_RESET_VIEW → runtime.transitionToResetView() (复用 smoothResetCamera)
 */

import {
  ArkWebAvatarShot,
  ArkWebAvatarShotDirectorState,
  ArkWebAvatarShotRuntime,
  ArkWebAvatarShotRuntimeSnapshot,
  ShotDirectorErrorCode,
  resolveTargetShot
} from './ArkWebAvatarShotDirectorTypes';
import { ArkWebAvatarPerformanceCommand } from './ArkWebAvatarPerformanceTypes';

const LOG_TAG: string = 'ShotDirector';

/**
 * 表情恢复定时器默认时长上限 (毫秒)。
 * 仅用于防御异常 command.durationMs, 实际时长以 command.durationMs 为准。
 */
const EXPRESSION_RETURN_TIMER_MAX_MS: number = 30000;

/**
 * Avatar 镜头导演。
 *
 * 单一职责: 管理两个固定镜头之间的平滑切换, 不负责演出执行。
 *
 * 生命周期:
 * 1. prepareForCommand(command) → 决定目标镜头 → 平滑切换 → 返回成功/失败
 * 2. 演出执行 (由 ChatAvatarStageController 调用 PerformanceController)
 * 3. 表情到期 → transitionToFullBody('EXPRESSION_COMPLETED')
 * 4. 停止/失败/模型重载/Stage 重显示 → transitionToFullBody(reason)
 * 5. dispose() → 清除定时器, 取消过渡, state = DISPOSED
 */
export class ArkWebAvatarShotDirector {
  /** 镜头 generation, 每次新请求递增, 用于过期旧异步结果 */
  private shotGeneration: number = 0;
  /** 当前镜头 (IDLE 表示尚未初始化) */
  private currentShot: ArkWebAvatarShot = 'FULL_BODY';
  /** 请求中镜头 (TRANSITIONING 时非空) */
  private requestedShot: ArkWebAvatarShot = 'FULL_BODY';
  /** 当前状态 */
  private state: ArkWebAvatarShotDirectorState = 'IDLE';

  /** 表情恢复定时器 ID (-1 表示无) */
  private expressionReturnTimer: number = -1;
  /** 表情恢复定时器关联的 commandId (诊断用) */
  private expressionReturnCommandId: string = '';

  /** 最近过渡原因 */
  private lastTransitionReason: string = '';
  /** 最近错误码 */
  private lastErrorCode: string = '';
  /** 最近错误信息 */
  private lastErrorMessage: string = '';

  /** 是否已销毁 */
  private disposed: boolean = false;

  /** 运行时回调 (由 ChatAvatarStageController 注入) */
  private runtime: ArkWebAvatarShotRuntime;

  /**
   * 构造函数。
   *
   * @param runtime 镜头运行时回调
   */
  constructor(runtime: ArkWebAvatarShotRuntime) {
    this.runtime = runtime;
  }

  // ===== 公开接口 =====

  /**
   * 准备镜头 (演出执行前调用)。
   *
   * 流程:
   * 1. 解析命令对应的目标镜头
   * 2. 命令非法 → 记录错误, 返回 false (不阻塞演出, 但镜头不切换)
   * 3. 已处于目标镜头 → no-op, 返回 true
   * 4. 平滑切换到目标镜头
   * 5. 仅 expression-only 命令设置表情恢复定时器
   *
   * @param command 演出命令
   * @returns 镜头准备是否成功
   */
  async prepareForCommand(command: ArkWebAvatarPerformanceCommand): Promise<boolean> {
    if (this.disposed) {
      this.recordError(ShotDirectorErrorCode.SHOT_DIRECTOR_DISPOSED, 'director disposed');
      return false;
    }

    const targetShot: ArkWebAvatarShot | null = resolveTargetShot(command);
    if (targetShot === null) {
      this.recordError(ShotDirectorErrorCode.SHOT_COMMAND_INVALID,
        `invalid command: motionType=${command.motionType} expressionId="${command.expressionId}"`);
      return false;
    }

    // 清除旧表情恢复定时器 (新命令可能不需要表情恢复)
    this.clearExpressionReturnTimer();

    // 切换镜头
    const ok: boolean = await this.transitionToShot(targetShot, `PREPARE_COMMAND:${command.commandId}`);
    if (!ok) {
      return false;
    }

    // 仅 expression-only 命令设置表情恢复定时器
    // (animation/pose 带表情时不设置, 保持 FULL_BODY)
    if (command.motionType === 'none' && command.expressionId.length > 0) {
      this.scheduleExpressionReturn(command.commandId, command.durationMs);
    }

    return true;
  }

  /**
   * 演出停止时调用 (恢复 FULL_BODY)。
   *
   * @param reason 停止原因
   */
  async onPerformanceStopped(reason: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.clearExpressionReturnTimer();
    await this.transitionToFullBody(`STOP:${reason}`);
  }

  /**
   * 演出失败时调用 (恢复 FULL_BODY)。
   *
   * @param reason 失败原因
   */
  async onPerformanceFailed(reason: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.clearExpressionReturnTimer();
    await this.transitionToFullBody(`FAILED:${reason}`);
  }

  /**
   * 模型 READY 时调用 (执行 FULL_BODY 构图)。
   *
   * 即使 currentShot 字段为 FULL_BODY, 也必须重新执行 fitAvatarFullBody,
   * 因为模型重新加载后相机位置可能已变化。
   */
  async onModelReady(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.clearExpressionReturnTimer();
    // 强制重新执行 FULL_BODY (不使用 no-op 优化)
    await this.executeFullBody('MODEL_READY');
  }

  /**
   * Stage 从隐藏切换为显示时调用 (恢复 FULL_BODY, 不恢复隐藏前的脸部镜头)。
   */
  async onStageVisible(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.clearExpressionReturnTimer();
    // 强制重新执行 FULL_BODY (不使用 no-op 优化)
    await this.executeFullBody('STAGE_VISIBLE');
  }

  /**
   * 平滑切换到全身镜头。
   *
   * 已处于 FULL_BODY 时 no-op (除非强制)。
   *
   * @param reason 切换原因
   */
  async transitionToFullBody(reason: string): Promise<boolean> {
    return await this.transitionToShot('FULL_BODY', reason);
  }

  /**
   * 平滑切换到脸部 (重置) 镜头。
   *
   * 已处于 FACE_RESET_VIEW 时 no-op。
   *
   * @param reason 切换原因
   */
  async transitionToFaceResetView(reason: string): Promise<boolean> {
    return await this.transitionToShot('FACE_RESET_VIEW', reason);
  }

  /**
   * 销毁 (清除定时器, 取消过渡, 不执行可见过渡)。
   *
   * 页面销毁时调用, 禁止旧异步结果提交。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.shotGeneration++;
    this.clearExpressionReturnTimer();
    // 取消正在进行的过渡 (不等待 Promise, 页面正在销毁)
    this.runtime.cancelCameraTransition('DISPOSED').catch((): void => {});
    this.state = 'DISPOSED';
    console.info(LOG_TAG, 'dispose');
  }

  /**
   * 获取运行时快照 (供 AI 面板诊断显示)。
   */
  getRuntimeSnapshot(): ArkWebAvatarShotRuntimeSnapshot {
    return {
      state: this.state,
      currentShot: this.currentShot,
      requestedShot: this.requestedShot,
      shotGeneration: this.shotGeneration,
      lastTransitionReason: this.lastTransitionReason,
      lastErrorCode: this.lastErrorCode,
      lastErrorMessage: this.lastErrorMessage,
      hasExpressionReturnTimer: this.expressionReturnTimer !== -1,
      expressionReturnCommandId: this.expressionReturnCommandId
    };
  }

  // ===== 内部实现 =====

  /**
   * 平滑切换到指定镜头。
   *
   * 重复镜头规则: 已处于目标镜头时 no-op, 直接返回成功。
   * (模型重载/Stage 重显示使用 executeFullBody 强制重新构图)
   *
   * @param targetShot 目标镜头
   * @param reason 切换原因
   */
  private async transitionToShot(
    targetShot: ArkWebAvatarShot,
    reason: string
  ): Promise<boolean> {
    if (this.disposed) {
      this.recordError(ShotDirectorErrorCode.SHOT_DIRECTOR_DISPOSED, 'director disposed');
      return false;
    }

    // 重复镜头 no-op
    if (this.currentShot === targetShot && this.state !== 'TRANSITIONING') {
      console.info(LOG_TAG, `no-op: already at ${targetShot}, reason=${reason}`);
      this.lastTransitionReason = reason;
      return true;
    }

    // 前置检查: 模型必须 READY
    if (!this.runtime.isModelReady()) {
      this.recordError(ShotDirectorErrorCode.SHOT_CAMERA_NOT_READY, 'model not ready');
      return false;
    }

    // 前置检查: Stage 尺寸必须有效 (FULL_BODY 需要)
    if (targetShot === 'FULL_BODY' && !this.runtime.isStageSizeValid()) {
      this.recordError(ShotDirectorErrorCode.SHOT_CAMERA_NOT_READY, 'stage size invalid');
      return false;
    }

    // 新 generation, 取消旧过渡
    this.shotGeneration++;
    const generation: number = this.shotGeneration;
    this.requestedShot = targetShot;
    this.state = 'TRANSITIONING';
    this.lastTransitionReason = reason;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';

    // 取消正在进行的旧过渡
    try {
      await this.runtime.cancelCameraTransition(`NEW_SHOT:${reason}`);
    } catch (e) {
      console.warn(LOG_TAG, 'cancelCameraTransition threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }

    // generation 检查 (cancelCameraTransition 期间可能已发起新请求)
    if (generation !== this.shotGeneration || this.disposed) {
      console.info(LOG_TAG, 'stale: generation changed during cancelCameraTransition');
      return false;
    }

    // 执行镜头切换
    let ok: boolean = false;
    try {
      if (targetShot === 'FULL_BODY') {
        ok = await this.runtime.transitionToFullBody();
      } else {
        ok = await this.runtime.transitionToResetView();
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.recordError(ShotDirectorErrorCode.SHOT_TRANSITION_FAILED, `threw: ${msg}`);
      return false;
    }

    // generation 检查 (异步完成后可能已发起新请求)
    if (generation !== this.shotGeneration || this.disposed) {
      console.info(LOG_TAG, 'stale: generation changed during transition');
      // 不更新 currentShot, 旧结果忽略
      return false;
    }

    if (!ok) {
      this.recordError(ShotDirectorErrorCode.SHOT_TRANSITION_FAILED,
        `runtime returned false for ${targetShot}`);
      this.state = 'FAILED';
      return false;
    }

    // 成功: 提交新镜头
    this.currentShot = targetShot;
    this.state = targetShot === 'FULL_BODY' ? 'FULL_BODY' : 'FACE_RESET_VIEW';
    console.info(LOG_TAG, `transition ok: ${targetShot}, reason=${reason}`);
    return true;
  }

  /**
   * 强制重新执行 FULL_BODY 构图 (忽略 no-op 优化)。
   *
   * 用于模型 READY / Stage 重新显示场景:
   * 即使 currentShot 字段为 FULL_BODY, 也必须重新调用 fitAvatarFullBody,
   * 因为模型重新加载后相机位置可能已变化。
   *
   * @param reason 原因
   */
  private async executeFullBody(reason: string): Promise<boolean> {
    if (this.disposed) {
      this.recordError(ShotDirectorErrorCode.SHOT_DIRECTOR_DISPOSED, 'director disposed');
      return false;
    }

    // 前置检查
    if (!this.runtime.isModelReady()) {
      this.recordError(ShotDirectorErrorCode.SHOT_CAMERA_NOT_READY, 'model not ready');
      return false;
    }
    if (!this.runtime.isStageSizeValid()) {
      this.recordError(ShotDirectorErrorCode.SHOT_CAMERA_NOT_READY, 'stage size invalid');
      return false;
    }

    this.shotGeneration++;
    const generation: number = this.shotGeneration;
    this.requestedShot = 'FULL_BODY';
    this.state = 'TRANSITIONING';
    this.lastTransitionReason = reason;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';

    // 取消旧过渡
    try {
      await this.runtime.cancelCameraTransition(`NEW_SHOT:${reason}`);
    } catch (e) {
      console.warn(LOG_TAG, 'cancelCameraTransition threw: ' +
        (e instanceof Error ? e.message : String(e)));
    }

    if (generation !== this.shotGeneration || this.disposed) {
      return false;
    }

    let ok: boolean = false;
    try {
      ok = await this.runtime.transitionToFullBody();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.recordError(ShotDirectorErrorCode.SHOT_TRANSITION_FAILED, `threw: ${msg}`);
      return false;
    }

    if (generation !== this.shotGeneration || this.disposed) {
      return false;
    }

    if (!ok) {
      this.recordError(ShotDirectorErrorCode.SHOT_TRANSITION_FAILED,
        'runtime returned false for FULL_BODY');
      this.state = 'FAILED';
      return false;
    }

    this.currentShot = 'FULL_BODY';
    this.state = 'FULL_BODY';
    console.info(LOG_TAG, `executeFullBody ok, reason=${reason}`);
    return true;
  }

  /**
   * 设置表情恢复定时器。
   *
   * 仅在 expression-only 命令 (motionType=none + expressionId 非空) 时调用。
   * 到期后检查 generation, 切换回 FULL_BODY。
   *
   * @param commandId 关联的 commandId (诊断用)
   * @param durationMs 定时时长 (毫秒)
   */
  private scheduleExpressionReturn(commandId: string, durationMs: number): void {
    this.clearExpressionReturnTimer();
    // 防御异常时长
    const safeDuration: number = Math.max(100, Math.min(durationMs, EXPRESSION_RETURN_TIMER_MAX_MS));
    this.expressionReturnCommandId = commandId;
    const generation: number = this.shotGeneration;
    console.info(LOG_TAG,
      `scheduleExpressionReturn: commandId=${commandId} duration=${safeDuration}ms gen=${generation}`);
    this.expressionReturnTimer = setTimeout((): void => {
      this.onExpressionReturnTimerFired(generation, commandId);
    }, safeDuration);
  }

  /**
   * 表情恢复定时器触发回调。
   *
   * 检查 generation, 若已过期则忽略 (新命令/停止/重载已清除定时器)。
   */
  private onExpressionReturnTimerFired(generation: number, commandId: string): void {
    this.expressionReturnTimer = -1;
    this.expressionReturnCommandId = '';
    if (this.disposed) {
      return;
    }
    if (generation !== this.shotGeneration) {
      console.info(LOG_TAG,
        `expression return timer stale: gen=${generation} current=${this.shotGeneration} commandId=${commandId}`);
      return;
    }
    console.info(LOG_TAG, `expression return: commandId=${commandId}`);
    // 平滑恢复 FULL_BODY
    this.transitionToFullBody('EXPRESSION_COMPLETED').catch((e: Object): void => {
      console.warn(LOG_TAG, 'expression return transitionToFullBody threw: ' +
        (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * 清除表情恢复定时器。
   */
  private clearExpressionReturnTimer(): void {
    if (this.expressionReturnTimer !== -1) {
      clearTimeout(this.expressionReturnTimer);
      this.expressionReturnTimer = -1;
      this.expressionReturnCommandId = '';
    }
  }

  /**
   * 记录错误。
   */
  private recordError(code: string, message: string): void {
    this.lastErrorCode = code;
    this.lastErrorMessage = message;
    console.warn(LOG_TAG, `error: ${code} - ${message}`);
  }
}
