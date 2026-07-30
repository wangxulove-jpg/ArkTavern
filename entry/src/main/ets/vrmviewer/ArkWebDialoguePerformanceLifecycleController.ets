/**
 * ArkWebDialoguePerformanceLifecycleController — 对话演出生命周期控制器 (Phase 3F-3)
 *
 * 职责:
 *   - 把"助手最终消息完成"事件接入演出链路
 *   - 维护生命周期代次 (lifecycleGeneration),使旧异步结果失效
 *   - 同一 turnId 最多执行一次演出
 *   - 新消息替换旧演出 (先 stop,再 execute)
 *   - 用户中断 / 页面销毁时停止当前演出
 *   - 映射或演出失败不影响文本消息显示 (返回 false,不抛异常)
 *
 * 不实现:
 *   - 真实 AI 接口 / 网络请求 / WebSocket
 *   - 自然语言解析 / Markdown 解析
 *   - JSON 安全校验 (由 Mapper 负责)
 *   - 动作加载 / 姿势应用 / 表情映射 / 演出恢复计时器 (由 PerformanceController 负责)
 *
 * 安全约束:
 *   - 调用方只传 turnId / performanceHintJson / activeModelId
 *   - 不得传完整提示词 / 聊天历史 / 文件路径 / Provider URL / Three.js 对象 / 原始模型数据
 *   - Mapper 通过构造函数注入,本控制器不重新实现映射逻辑
 *   - Runtime 通过依赖接口注入,本控制器不直接调用 PerformanceController 内部方法
 *
 * Reference:
 *   - AGENTS.md Phase 3F-3 §生命周期控制器 / §最终消息规则 / §中断规则
 *   - ArkWebDialoguePerformanceMapper.ets (mapJson)
 *   - ArkWebAvatarPerformanceController.ets (executeCommand / stopPerformance)
 *   - ArkWebAvatarPerformanceTypes.ets (ArkWebAvatarPerformanceCommand)
 */

import {
  ArkWebAvatarPerformanceCommand,
  ArkWebPerformanceState
} from './ArkWebAvatarPerformanceTypes';
import { ArkWebDialoguePerformanceMapper } from './ArkWebDialoguePerformanceMapper';
import { ArkWebDialoguePerformanceMappingResult } from './ArkWebDialoguePerformanceTypes';

/**
 * 对话演出生命周期状态。
 *
 * 状态流转:
 *   IDLE → MAPPING → EXECUTING → ACTIVE → COMPLETED
 *   IDLE → COMPLETED_WITHOUT_PERFORMANCE (空 Hint)
 *   任意 → FAILED (映射或执行失败)
 *   任意 → CANCELLED (用户中断 / 新消息 / 页面销毁)
 *   任意 → DISPOSED (页面销毁,不可恢复)
 */
export enum ArkWebDialogueLifecycleState {
  IDLE = 'IDLE',
  MAPPING = 'MAPPING',
  EXECUTING = 'EXECUTING',
  ACTIVE = 'ACTIVE',
  COMPLETED = 'COMPLETED',
  COMPLETED_WITHOUT_PERFORMANCE = 'COMPLETED_WITHOUT_PERFORMANCE',
  FAILED = 'FAILED',
  CANCELLED = 'CANCELLED',
  DISPOSED = 'DISPOSED'
}

/**
 * 对话演出生命周期 Runtime 依赖接口。
 *
 * VrmViewerPage 用现有 PerformanceController 实现这两个方法,
 * 注入到 LifecycleController,避免直接依赖具体类。
 *
 * 所有属性均为函数类型 (非方法), 以便 VrmViewerPage 用对象字面量 + 箭头函数创建
 * (ArkTS 不允许对象字面量包含方法, arkts-no-untyped-obj-literals)。
 */
export interface ArkWebDialoguePerformanceLifecycleRuntime {
  /** 停止当前演出 (对应 PerformanceController.stopPerformance) */
  stopPerformance: () => Promise<boolean>;
  /** 执行演出命令 (对应 PerformanceController.executeCommand) */
  executePerformance: (command: ArkWebAvatarPerformanceCommand) => Promise<boolean>;
}

/**
 * 对话演出生命周期控制器。
 *
 * 使用方式:
 *   1. 页面 aboutToAppear 创建实例,传入 Mapper 和 Runtime
 *   2. 助手最终消息完成时调用 submitFinalAssistantResult()
 *   3. 用户中断 / 新消息开始 / 页面销毁时调用 cancelCurrent()
 *   4. 页面 aboutToDisappear 调用 dispose()
 *
 * 线程安全:
 *   - 所有方法串行执行 (ArkTS 单线程事件循环)
 *   - 异步结果通过 lifecycleGeneration 检查有效性
 */
export class ArkWebDialoguePerformanceLifecycleController {
  /** Mapper 实例 (构造函数注入,不重新实现校验) */
  private mapper: ArkWebDialoguePerformanceMapper | null;
  /** Runtime 依赖 (构造函数注入) */
  private runtime: ArkWebDialoguePerformanceLifecycleRuntime | null;

  /** 生命周期代次 (每次 submit / cancel / dispose 自增) */
  private lifecycleGeneration: number = 0;
  /** 最后一次 submit 的 turnId (用于去重) */
  private lastSubmittedTurnId: string = '';
  /** 当前在处理的 turnId */
  private currentTurnId: string = '';
  /** 当前在处理的 commandId */
  private currentCommandId: string = '';
  /** 当前生命周期状态 */
  private currentState: ArkWebDialogueLifecycleState = ArkWebDialogueLifecycleState.IDLE;
  /** 最近一次映射是否降级 */
  private mappingDegraded: boolean = false;
  /** 最近一次映射警告 */
  private mappingWarnings: string = '';
  /** 最后错误码 */
  private lastErrorCode: string = '';
  /** 最后错误消息 */
  private lastErrorMessage: string = '';
  /** 是否已销毁 */
  private disposed: boolean = false;

  constructor(
    mapper: ArkWebDialoguePerformanceMapper | null,
    runtime: ArkWebDialoguePerformanceLifecycleRuntime | null
  ) {
    this.mapper = mapper;
    this.runtime = runtime;
  }

  /** 获取当前生命周期状态。 */
  getState(): ArkWebDialogueLifecycleState {
    return this.currentState;
  }

  /** 获取当前 lifecycleGeneration。 */
  getLifecycleGeneration(): number {
    return this.lifecycleGeneration;
  }

  /** 获取最近一次 submit 的 turnId。 */
  getLastSubmittedTurnId(): string {
    return this.lastSubmittedTurnId;
  }

  /** 获取当前在处理的 turnId。 */
  getCurrentTurnId(): string {
    return this.currentTurnId;
  }

  /** 获取当前 commandId。 */
  getCurrentCommandId(): string {
    return this.currentCommandId;
  }

  /** 获取最近一次映射是否降级。 */
  getMappingDegraded(): boolean {
    return this.mappingDegraded;
  }

  /** 获取最近一次映射警告。 */
  getMappingWarnings(): string {
    return this.mappingWarnings;
  }

  /** 获取最后错误码。 */
  getLastErrorCode(): string {
    return this.lastErrorCode;
  }

  /** 获取最后错误消息。 */
  getLastErrorMessage(): string {
    return this.lastErrorMessage;
  }

  /** 是否已销毁。 */
  isDisposed(): boolean {
    return this.disposed;
  }

  /**
   * 提交最终助手消息结果。
   *
   * 流程:
   *   1. 验证 turnId 非空
   *   2. 相同 turnId 已提交则忽略 (返回 false)
   *   3. lifecycleGeneration++
   *   4. 停止上一条演出
   *   5. performanceHintJson 为空 → COMPLETED_WITHOUT_PERFORMANCE (返回 true)
   *   6. 调用 Mapper.mapJson()
   *   7. accepted=false → FAILED (返回 false,不影响消息显示)
   *   8. accepted=true → 调用 Runtime.executePerformance()
   *   9. 提交状态前检查 generation
   *   10. 成功后 ACTIVE (返回 true)
   *
   * 流式 token / partial message / 思考过程不得调用此方法。
   *
   * @param turnId 对话轮次 ID (非空)
   * @param performanceHintJson AI 返回的 Hint JSON (可为空字符串)
   * @param activeModelId 当前激活模型 ID (保留参数,本阶段不使用)
   * @returns true 表示已处理 (含空 Hint 的 COMPLETED_WITHOUT_PERFORMANCE); false 表示被忽略或失败
   */
  async submitFinalAssistantResult(
    turnId: string,
    performanceHintJson: string,
    activeModelId: string
  ): Promise<boolean> {
    if (this.disposed) {
      return false;
    }

    // 1. 验证 turnId 非空
    if (typeof turnId !== 'string' || turnId.length === 0) {
      this.lastErrorCode = 'DIALOGUE_LIFECYCLE_TURN_ID_EMPTY';
      this.lastErrorMessage = 'turnId 为空';
      this.currentState = ArkWebDialogueLifecycleState.FAILED;
      return false;
    }

    // 2. 相同 turnId 已提交则忽略
    if (this.lastSubmittedTurnId === turnId) {
      return false;
    }

    // 3. lifecycleGeneration++
    this.lifecycleGeneration++;
    const myGeneration: number = this.lifecycleGeneration;
    this.lastSubmittedTurnId = turnId;
    this.currentTurnId = turnId;
    this.currentCommandId = '';
    this.mappingDegraded = false;
    this.mappingWarnings = '';
    this.lastErrorCode = '';
    this.lastErrorMessage = '';

    // 4. 停止上一条演出 (best-effort,不阻塞流程)
    if (this.runtime !== null) {
      try {
        await this.runtime.stopPerformance();
      } catch (e) {
        // 停止失败不影响后续流程
        console.warn('[DialogueLifecycle] stopPerformance threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
      if (this.disposed || this.lifecycleGeneration !== myGeneration) {
        return false;
      }
    }

    // 5. performanceHintJson 为空 → COMPLETED_WITHOUT_PERFORMANCE
    if (typeof performanceHintJson !== 'string' || performanceHintJson.length === 0) {
      this.currentState = ArkWebDialogueLifecycleState.COMPLETED_WITHOUT_PERFORMANCE;
      return true;
    }

    // 6. 调用 Mapper.mapJson()
    if (this.mapper === null) {
      this.lastErrorCode = 'DIALOGUE_LIFECYCLE_MAPPER_NULL';
      this.lastErrorMessage = 'Mapper 未注入';
      this.currentState = ArkWebDialogueLifecycleState.FAILED;
      return false;
    }

    this.currentState = ArkWebDialogueLifecycleState.MAPPING;
    let mappingResult: ArkWebDialoguePerformanceMappingResult;
    try {
      mappingResult = await this.mapper.mapJson(performanceHintJson);
    } catch (e) {
      this.lastErrorCode = 'DIALOGUE_LIFECYCLE_MAPPER_THREW';
      this.lastErrorMessage = e instanceof Error ? e.message : String(e);
      this.currentState = ArkWebDialogueLifecycleState.FAILED;
      return false;
    }

    // 9. 提交状态前检查 generation
    if (this.disposed || this.lifecycleGeneration !== myGeneration) {
      return false;
    }

    // 7. accepted=false → FAILED (不影响消息显示)
    if (!mappingResult.accepted) {
      this.lastErrorCode = mappingResult.errorCode;
      this.lastErrorMessage = mappingResult.errorMessage;
      this.currentState = ArkWebDialogueLifecycleState.FAILED;
      return false;
    }

    if (mappingResult.command === undefined) {
      this.lastErrorCode = 'DIALOGUE_LIFECYCLE_COMMAND_MISSING';
      this.lastErrorMessage = '映射结果 command 为空';
      this.currentState = ArkWebDialogueLifecycleState.FAILED;
      return false;
    }

    // 记录映射警告 / 降级
    this.mappingDegraded = mappingResult.degraded;
    if (mappingResult.warnings.length > 0) {
      this.mappingWarnings = mappingResult.warnings.join('; ');
    }
    this.currentCommandId = mappingResult.command.commandId;

    // 8. 调用 Runtime.executePerformance()
    if (this.runtime === null) {
      this.lastErrorCode = 'DIALOGUE_LIFECYCLE_RUNTIME_NULL';
      this.lastErrorMessage = 'Runtime 未注入';
      this.currentState = ArkWebDialogueLifecycleState.FAILED;
      return false;
    }

    this.currentState = ArkWebDialogueLifecycleState.EXECUTING;
    let execOk: boolean = false;
    try {
      execOk = await this.runtime.executePerformance(mappingResult.command);
    } catch (e) {
      this.lastErrorCode = 'DIALOGUE_LIFECYCLE_EXECUTE_THREW';
      this.lastErrorMessage = e instanceof Error ? e.message : String(e);
      this.currentState = ArkWebDialogueLifecycleState.FAILED;
      return false;
    }

    // 9. 提交状态前检查 generation
    if (this.disposed || this.lifecycleGeneration !== myGeneration) {
      return false;
    }

    // 10. 成功后 ACTIVE
    if (execOk) {
      this.currentState = ArkWebDialogueLifecycleState.ACTIVE;
      return true;
    }
    this.lastErrorCode = 'DIALOGUE_LIFECYCLE_EXECUTE_FAILED';
    this.lastErrorMessage = 'PerformanceController.executeCommand 返回 false';
    this.currentState = ArkWebDialogueLifecycleState.FAILED;
    return false;
  }

  /**
   * 中断当前演出。
   *
   * 触发场景:
   *   - 用户发送新消息
   *   - 用户点击停止生成
   *   - 新的助手最终消息开始处理
   *   - 页面销毁 (dispose 内部调用)
   *
   * 执行:
   *   1. lifecycleGeneration++
   *   2. 停止 PerformanceController (best-effort)
   *   3. state = CANCELLED
   *
   * 旧异步结果不得更新当前状态 (通过 generation 检查)。
   *
   * @param reason 中断原因 (仅日志)
   */
  async cancelCurrent(reason: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.lifecycleGeneration++;
    this.currentTurnId = '';
    this.currentCommandId = '';
    if (this.runtime !== null) {
      try {
        await this.runtime.stopPerformance();
      } catch (e) {
        console.warn('[DialogueLifecycle] cancelCurrent stopPerformance threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
    }
    this.currentState = ArkWebDialogueLifecycleState.CANCELLED;
    console.info('[DialogueLifecycle] cancelCurrent reason=' + reason);
  }

  /**
   * 销毁控制器。
   *
   * 顺序 (页面销毁):
   *   LifecycleController.dispose()
   *   → PerformanceController.dispose()
   *   → Mapper.dispose()
   *
   * 本方法只销毁 LifecycleController 自身:
   *   1. disposed = true
   *   2. lifecycleGeneration++
   *   3. 停止当前演出 (best-effort)
   *   4. state = DISPOSED
   *   5. 清空 mapper / runtime 引用
   *
   * 不删除: 动作资产 / 姿势资产 / 表情别名 / 默认姿势 / library.json
   * (由 PerformanceController / Mapper 各自的 dispose 保证)
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.lifecycleGeneration++;
    this.currentTurnId = '';
    this.currentCommandId = '';
    // best-effort 停止演出 (不等待,不抛异常)
    if (this.runtime !== null) {
      try {
        this.runtime.stopPerformance().then((_ok: boolean): void => {
          // 忽略结果
        }).catch((_e: Object): void => {
          // 忽略错误
        });
      } catch (_e) {
        // 忽略同步异常
      }
    }
    this.currentState = ArkWebDialogueLifecycleState.DISPOSED;
    this.mapper = null;
    this.runtime = null;
  }
}
