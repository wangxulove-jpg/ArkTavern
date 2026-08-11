import { Logger } from '../utils/Logger';
/**
 * ArkWebAvatarPerformanceController — 统一角色演出控制器 (Phase 3F-1)
 *
 * 职责:
 *   - 接收 ArkWebAvatarPerformanceCommand 统一演出指令
 *   - 验证资源 ID 存在 (actionId / poseId)
 *   - 按 REPLACE 策略替换当前演出 (generation++ 取消旧任务)
 *   - 调用 Runtime 回调执行动作 / 姿势 / 临时表情
 *   - 演出进行中不自动停止, 由用户点击停止或新命令替换
 *   - 页面销毁时清理, 不删除任何持久化数据
 *
 * 不做的事:
 *   - 不复制动作 / 姿势 / 表情底层实现
 *   - 不直接创建 GLTFLoader / AnimationMixer / VRMAnimationClip /
 *     VRM Humanoid Node / VRM ExpressionManager / ArkWeb Provider
 *   - 不实现 AI 接口 / 自然语言解析 / 演出队列 / CrossFade / 动作混合
 *   - 不新增 Frame Loop / setInterval / 轮询计时
 *   - 不使用 setTimeout 自动停止动画 (已移除定时恢复逻辑)
 *
 * generation 防过期:
 *   - 每条新命令: performanceGeneration++
 *   - 取消旧临时表情 (Runtime.cancelTemporaryExpression)
 *   - 停止旧动画 (Runtime.stopAnimation)
 *   - 旧异步结果提交前必须检查 generation
 *
 * 停止策略:
 *   - 动画循环播放或播放一遍, 由循环播放开关控制 (setAnimationLoop)
 *   - 用户点击停止或点击同一动作 → stopAnimation + 恢复默认姿势
 *   - 新命令替换 → 停止旧动画, 应用新动画
 *   - 表情与动画独立播放, 互不影响
 *
 * Reference:
 *   - AGENTS.md Phase 3F-1 §演出控制器 / §REPLACE 规则
 *   - ArkWebAvatarPerformanceTypes.ets
 */

import {
  ArkWebAvatarPerformanceCommand,
  ArkWebAvatarPerformanceRuntime,
  ArkWebPerformanceState,
  ArkWebPerformanceResult,
  ArkWebPerformanceDebugState,
  PerformanceErrorCode,
  validatePerformanceCommand
} from './ArkWebAvatarPerformanceTypes';
import { ArkWebAvatarAnimationAsset, ArkWebAvatarPoseAsset } from './ArkWebAvatarAssetTypes';
import { ArkWebAvatarAssetLibrary } from './ArkWebAvatarAssetLibrary';

/**
 * 演出控制器。
 *
 * 使用方式:
 *   1. 页面 aboutToAppear 创建实例, 注入 AssetLibrary 和 Runtime 回调
 *   2. 调用 executeCommand(cmd) 执行演出
 *   3. 调用 stopPerformance() 提前停止
 *   4. 调用 getDebugState() 获取调试状态
 *   5. 页面销毁前调用 dispose()
 */
export class ArkWebAvatarPerformanceController {
  /** @type {ArkWebPerformanceState} */
  private _state: ArkWebPerformanceState = ArkWebPerformanceState.IDLE;
  /** 演出代次 (每次新命令 / 取消 / dispose 自增, 用于让旧 timeout 失效) */
  private performanceGeneration: number = 0;
  /** 当前命令 ID (空字符串表示无活动命令) */
  private currentCommandId: string = '';
  /** 当前动作类型 */
  private currentMotionType: string = '';
  /** 当前动作 ID (actionId / poseId) */
  private currentMotionId: string = '';
  /** 当前表情业务 ID */
  private currentExpressionId: string = '';
  /** 当前表情权重 */
  private currentExpressionWeight: number = 0;
  /** 到期时间戳 (0 表示无活动 timeout) */
  private expiresAt: number = 0;
  /** 当前 returnPolicy (记录用, 不再用于自动恢复) */
  private currentReturnPolicy: string = 'DEFAULT_POSE';
  /** 最近一次错误码 */
  private lastErrorCode: string = '';
  /** 最近一次错误消息 */
  private lastErrorMessage: string = '';
  /** 是否已销毁 */
  private _disposed: boolean = false;

  /** 资产库 (用于查找动作 / 姿势 / 默认姿势) */
  private assetLibrary: ArkWebAvatarAssetLibrary | null;
  /** 运行时回调 (由 VrmViewerPage 实现) */
  private runtime: ArkWebAvatarPerformanceRuntime | null;

  /**
   * 构造函数。
   *
   * @param library 资产库 (允许为 null, 但 executeCommand 会返回 DISPOSED)
   * @param runtime 运行时回调 (允许为 null, 但 executeCommand 会返回 DISPOSED)
   */
  constructor(
    library: ArkWebAvatarAssetLibrary | null,
    runtime: ArkWebAvatarPerformanceRuntime | null
  ) {
    this.assetLibrary = library;
    this.runtime = runtime;
  }

  /**
   * 是否已销毁。
   */
  isDisposed(): boolean {
    return this._disposed;
  }

  /**
   * 获取当前状态。
   */
  getState(): ArkWebPerformanceState {
    return this._state;
  }

  /**
   * 执行演出命令。
   *
   * 流程:
   *   1. 检查 disposed
   *   2. 校验命令 (validatePerformanceCommand)
   *   3. REPLACE: generation++, cancelTemporaryExpression, stopAnimation
   *   4. state = RESOLVING, 记录当前命令字段
   *   5. motionType 分支:
   *      - animation: 查找 actionId → playAnimationById
   *      - pose: 查找 poseId → applyPoseById
   *      - none: 跳过动作
   *   6. expressionId 非空: setTemporaryExpressionByAlias
   *   7. state = ACTIVE (不启动定时器, 由用户或新命令停止)
   *   8. 返回结果
   *
   * 旧 generation 的异步结果通过 generation 检查被忽略。
   *
   * @returns ArkWebPerformanceResult
   */
  async executeCommand(cmd: ArkWebAvatarPerformanceCommand): Promise<ArkWebPerformanceResult> {
    if (this._disposed) {
      return this.makeFailureResult(
        PerformanceErrorCode.CONTROLLER_DISPOSED,
        'controller disposed',
        ArkWebPerformanceState.DISPOSED
      );
    }
    // 命令校验
    const validationError: string = validatePerformanceCommand(cmd);
    if (validationError.length > 0) {
      this.lastErrorCode = validationError;
      this.lastErrorMessage = `command validation failed: ${validationError}`;
      this._state = ArkWebPerformanceState.FAILED;
      return this.makeFailureResult(
        validationError,
        this.lastErrorMessage,
        ArkWebPerformanceState.FAILED
      );
    }
    if (this.assetLibrary === null || this.runtime === null) {
      this.lastErrorCode = PerformanceErrorCode.CONTROLLER_DISPOSED;
      this.lastErrorMessage = 'assetLibrary or runtime not injected';
      this._state = ArkWebPerformanceState.FAILED;
      return this.makeFailureResult(
        PerformanceErrorCode.CONTROLLER_DISPOSED,
        this.lastErrorMessage,
        ArkWebPerformanceState.FAILED
      );
    }

    // REPLACE: 取消旧任务
    const myGeneration: number = this.beginNewCommand();

    // 记录当前命令字段
    this.currentCommandId = cmd.commandId;
    this.currentMotionType = cmd.motionType;
    this.currentMotionId = cmd.motionId;
    this.currentExpressionId = cmd.expressionId;
    this.currentExpressionWeight = cmd.expressionWeight;
    this.currentReturnPolicy = cmd.returnPolicy;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    this._state = ArkWebPerformanceState.RESOLVING;

    // RESOLVING: 验证资源 ID 存在
    // motionType 分支: animation / pose / none
    if (cmd.motionType === 'animation') {
      const asset: ArkWebAvatarAnimationAsset | null =
        await this.assetLibrary.findAnimation(cmd.motionId);
      if (this.checkStaleAndReturn(myGeneration, cmd.commandId)) {
        return this.makeStaleResult();
      }
      if (asset === null) {
        return this.failWith(
          PerformanceErrorCode.ACTION_NOT_FOUND,
          `actionId not found: ${cmd.motionId}`,
          myGeneration,
          cmd.commandId
        );
      }
    } else if (cmd.motionType === 'pose') {
      const poseAsset: ArkWebAvatarPoseAsset | null =
        await this.assetLibrary.findPose(cmd.motionId);
      if (this.checkStaleAndReturn(myGeneration, cmd.commandId)) {
        return this.makeStaleResult();
      }
      if (poseAsset === null) {
        return this.failWith(
          PerformanceErrorCode.POSE_NOT_FOUND,
          `poseId not found: ${cmd.motionId}`,
          myGeneration,
          cmd.commandId
        );
      }
    } else if (cmd.motionType === 'none') {
      // none 分支: 仅表情演出, 不加载动作或姿势
      // motionId 已由 validatePerformanceCommand 校验为空字符串
    }

    // APPLYING: 应用动作或姿势
    this._state = ArkWebPerformanceState.APPLYING;
    if (cmd.motionType === 'animation') {
      const ok: boolean = await this.runtime.playAnimationById(cmd.motionId);
      if (this.checkStaleAndReturn(myGeneration, cmd.commandId)) {
        return this.makeStaleResult();
      }
      if (!ok) {
        return this.failWith(
          PerformanceErrorCode.MOTION_APPLY_FAILED,
          `playAnimationById failed: ${cmd.motionId}`,
          myGeneration,
          cmd.commandId
        );
      }
    } else if (cmd.motionType === 'pose') {
      const ok: boolean = await this.runtime.applyPoseById(cmd.motionId);
      if (this.checkStaleAndReturn(myGeneration, cmd.commandId)) {
        return this.makeStaleResult();
      }
      if (!ok) {
        return this.failWith(
          PerformanceErrorCode.MOTION_APPLY_FAILED,
          `applyPoseById failed: ${cmd.motionId}`,
          myGeneration,
          cmd.commandId
        );
      }
    } else if (cmd.motionType === 'none') {
      // none 分支: 跳过动作或姿势应用, 仅设置临时表情
    }

    // 表情设置 (失败不撤销已成功的动作)
    if (cmd.expressionId.length > 0) {
      const expOk: boolean = await this.runtime.setTemporaryExpressionByAlias(
        cmd.expressionId,
        cmd.expressionWeight,
        cmd.durationMs
      );
      if (this.checkStaleAndReturn(myGeneration, cmd.commandId)) {
        return this.makeStaleResult();
      }
      if (!expOk) {
        // 表情失败: 保持动作或姿势, 仅记录错误
        this.lastErrorCode = PerformanceErrorCode.EXPRESSION_APPLY_FAILED;
        this.lastErrorMessage = `setTemporaryExpressionByAlias failed: ${cmd.expressionId}`;
        // 不进入 FAILED 状态, 继续进入 ACTIVE (动作已成功)
        Logger.warn(`[Performance] expression apply failed but motion kept: ${cmd.expressionId}`);
      }
    }

    // ACTIVE: 演出进行中, 不自动停止 (由用户点击停止或新命令替换)
    if (this.checkStaleAndReturn(myGeneration, cmd.commandId)) {
      return this.makeStaleResult();
    }
    this._state = ArkWebPerformanceState.ACTIVE;
    this.expiresAt = 0;

    return {
      success: true,
      state: this._state,
      commandId: cmd.commandId,
      generation: myGeneration,
      expiresAt: this.expiresAt,
      errorCode: this.lastErrorCode,
      errorMessage: this.lastErrorMessage
    };
  }

  /**
   * 提前停止当前演出。
   *
   * 行为:
   *   - performanceGeneration++
   *   - cancelTemporaryExpression
   *   - stopAnimation
   *   - resetPose (不恢复默认姿势)
   *   - state = IDLE
   *
   * @returns 成功返回 true; 已销毁返回 false
   */
  async stopPerformance(): Promise<boolean> {
    if (this._disposed) {
      return false;
    }
    this.beginNewCommand();
    this.clearCurrentCommandFields();
    this._state = ArkWebPerformanceState.IDLE;
    return true;
  }

  /**
   * 获取调试状态。
   */
  getDebugState(): ArkWebPerformanceDebugState {
    return {
      state: this._state,
      performanceGeneration: this.performanceGeneration,
      currentCommandId: this.currentCommandId,
      currentMotionType: this.currentMotionType,
      currentMotionId: this.currentMotionId,
      currentExpressionId: this.currentExpressionId,
      currentExpressionWeight: this.currentExpressionWeight,
      expiresAt: this.expiresAt,
      restoreTimerActive: false,
      lastErrorCode: this.lastErrorCode,
      lastErrorMessage: this.lastErrorMessage
    };
  }

  /**
   * 销毁控制器。
   *
   * 行为:
   *   - performanceGeneration++
   *   - cancelTemporaryExpression (best-effort, 不等待)
   *   - stopAnimation (best-effort, 不等待)
   *   - state = DISPOSED
   *   - 不删除动作文件 / 姿势文件 / 表情别名 / library.json
   */
  dispose(): void {
    if (this._disposed) {
      return;
    }
    this._disposed = true;
    this.performanceGeneration++;
    this.currentCommandId = '';
    this.currentMotionType = '';
    this.currentMotionId = '';
    this.currentExpressionId = '';
    this.currentExpressionWeight = 0;
    this.expiresAt = 0;
    this.currentReturnPolicy = 'DEFAULT_POSE';
    this._state = ArkWebPerformanceState.DISPOSED;

    // best-effort 清理 (不等待, 不抛错)
    if (this.runtime !== null) {
      try {
        this.runtime.cancelTemporaryExpression().catch((_e: Object) => {});
      } catch (e) {
        Logger.warn('[Performance] dispose cancelTemporaryExpression threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
      try {
        this.runtime.stopAnimation().catch((_e: Object) => {});
      } catch (e) {
        Logger.warn('[Performance] dispose stopAnimation threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
    }
    this.assetLibrary = null;
    this.runtime = null;
  }

  // ===== 内部方法 =====

  /**
   * 开始新命令: 取消旧任务, 自增 generation。
   *
   * @returns 新 generation
   */
  private beginNewCommand(): number {
    this.performanceGeneration++;
    this.expiresAt = 0;
    // best-effort 取消旧临时表情和停止旧动画 (不等待, 不阻塞新命令)
    if (this.runtime !== null) {
      try {
        this.runtime.cancelTemporaryExpression().catch((_e: Object) => {});
      } catch (e) {
        Logger.warn('[Performance] beginNewCommand cancelTemporaryExpression threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
      try {
        this.runtime.stopAnimation().catch((_e: Object) => {});
      } catch (e) {
        Logger.warn('[Performance] beginNewCommand stopAnimation threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
    }
    return this.performanceGeneration;
  }

  /**
   * 检查 generation 是否过期; 过期则返回 true。
   */
  private checkStaleAndReturn(generation: number, commandId: string): boolean {
    if (generation !== this.performanceGeneration) {
      // stale result 静默忽略(高频保护逻辑,默认不记录)
      return true;
    }
    return false;
  }

  /**
   * 清空当前命令字段 (保留 lastError*)。
   */
  private clearCurrentCommandFields(): void {
    this.currentCommandId = '';
    this.currentMotionType = '';
    this.currentMotionId = '';
    this.currentExpressionId = '';
    this.currentExpressionWeight = 0;
    this.expiresAt = 0;
    this.currentReturnPolicy = 'DEFAULT_POSE';
  }

  /**
   * 标记失败并返回失败结果。
   */
  private failWith(
    errorCode: string,
    errorMessage: string,
    generation: number,
    commandId: string
  ): ArkWebPerformanceResult {
    this.lastErrorCode = errorCode;
    this.lastErrorMessage = errorMessage;
    this._state = ArkWebPerformanceState.FAILED;
    return {
      success: false,
      state: ArkWebPerformanceState.FAILED,
      commandId: commandId,
      generation: generation,
      expiresAt: 0,
      errorCode: errorCode,
      errorMessage: errorMessage
    };
  }

  /**
   * 构造失败结果 (不修改状态, 用于 disposed 等情况)。
   */
  private makeFailureResult(
    errorCode: string,
    errorMessage: string,
    state: ArkWebPerformanceState
  ): ArkWebPerformanceResult {
    return {
      success: false,
      state: state,
      commandId: '',
      generation: this.performanceGeneration,
      expiresAt: 0,
      errorCode: errorCode,
      errorMessage: errorMessage
    };
  }

  /**
   * 构造 stale 结果。
   */
  private makeStaleResult(): ArkWebPerformanceResult {
    return {
      success: false,
      state: this._state,
      commandId: '',
      generation: this.performanceGeneration,
      expiresAt: 0,
      errorCode: PerformanceErrorCode.STALE_RESULT,
      errorMessage: 'stale result ignored due to generation mismatch'
    };
  }
}
