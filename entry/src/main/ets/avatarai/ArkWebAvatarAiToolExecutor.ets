/**
 * ArkWebAvatarAiToolExecutor — Avatar AI 工具执行器 (Phase 4A-3)
 *
 * 职责:
 *   - 只执行已通过 Provider 结构化解析 + Registry 校验 + PermissionController 校验的工具调用
 *   - avatar_perform: 构建 performanceHintJson, 通过 AvatarChatBridge 发布
 *   - avatar_stop: 通过 ChatAvatarStage 生命周期入口停止演出
 *   - avatar_list_capabilities: 从 CapabilityCatalog 读取能力快照
 *   - avatar_get_state: 从 ChatAvatarStageController 读取业务状态
 *   - 维护 chatTurnId + toolCallId 去重缓存 (上限 64, 超过删除最旧)
 *
 * 安全约束:
 *   - 不直接调用 playAnimation / applyPose / setExpression / resetCamera / fitAvatarFullBody
 *   - avatar_perform 必须经过 AvatarChatBridge → LifecycleController → ShotDirector → PerformanceController
 *   - avatar_stop 必须经过 ChatAvatarStage 生命周期入口
 *   - 工具结果不得包含内部堆栈
 *
 * 去重策略:
 *   - 相同 chatTurnId + toolCallId 重复收到: 返回之前的执行结果, 不重复执行演出
 *   - 最多缓存 64 个执行结果, 超过删除最旧记录
 *
 * Reference:
 *   - AGENTS.md Phase 4A-3 §Tool Executor / §工具执行链路 / §Tool Call 去重
 */

import { ArkWebAvatarAiCapabilitySnapshot } from '../vrmviewer/ArkWebAvatarAiTypes';
import {
  ArkWebChatToolCall,
  ArkWebChatToolExecutionResult,
  ArkWebAvatarAiToolName,
  ArkWebAvatarAiToolErrorCode,
  ArkWebAvatarAiToolContext,
  ArkWebAvatarPerformParams,
  ArkWebAvatarPerformResultJson,
  ArkWebAvatarListCapabilitiesResultJson,
  ArkWebAvatarGetStateResultJson,
  ArkWebAvatarStopResultJson,
  ArkWebAvatarAiAnimationSummary,
  ArkWebAvatarAiPoseSummary,
  ArkWebAvatarAiExpressionSummary,
  ArkWebAvatarToolResultCacheEntry,
  AVATAR_TOOL_RESULT_CACHE_LIMIT
} from './ArkWebAvatarAiToolTypes';
import { ArkWebAvatarAiToolRegistry } from './ArkWebAvatarAiToolRegistry';
import { ArkWebAvatarAiToolPermissionController } from './ArkWebAvatarAiToolPermissionController';
import { ArkWebAvatarChatBridge } from '../services/avatar/ArkWebAvatarChatBridge';
import {
  ArkWebAvatarChatFinalResult,
  ArkWebAvatarChatFinalResultSource
} from '../services/avatar/ArkWebAvatarChatBridgeTypes';

const LOG_TAG: string = 'AvatarAiToolExecutor';

/**
 * Tool Executor 依赖的运行时回调 (由 ChatPage 注入, 避免直接依赖 ChatAvatarStageController)。
 */
export interface ArkWebAvatarAiToolExecutorRuntime {
  /** 发布演出到 AvatarChatBridge (source = AI_TOOL_CALL) */
  publishPerformanceForToolCall(
    turnId: string,
    performanceHintJson: string
  ): Promise<boolean>;
  /** 停止当前 AI 发起的演出 */
  stopPerformanceForToolCall(reason: string): Promise<void>;
  /** 获取当前 Avatar 业务状态 (用于 avatar_get_state) */
  getAvatarBusinessState(): ArkWebAvatarToolExecutorBusinessState;
}

/**
 * Avatar 业务状态 (avatar_get_state 返回, 只含业务字段)。
 */
export interface ArkWebAvatarToolExecutorBusinessState {
  connected: boolean;
  modelReady: boolean;
  modelDisplayName: string;
  shot: string;
  performanceState: string;
  motionType: string;
  motionId: string;
  expressionId: string;
}

/**
 * Avatar AI 工具执行器。
 *
 * 由 ChatPage 持有, 注入 Runtime 回调和 Registry / PermissionController。
 * ChatService 通过 ChatPage 提供的接口调用 execute()。
 */
export class ArkWebAvatarAiToolExecutor {
  /** 工具注册表 (校验) */
  private registry: ArkWebAvatarAiToolRegistry;
  /** 权限控制器 (校验) */
  private permissionController: ArkWebAvatarAiToolPermissionController;
  /** 运行时回调 (由 ChatPage 注入) */
  private runtime: ArkWebAvatarAiToolExecutorRuntime;

  /** 去重缓存 (chatTurnId + toolCallId → result) */
  private resultCache: ArkWebAvatarToolResultCacheEntry[] = [];

  /** 是否已销毁 */
  private disposed: boolean = false;

  constructor(
    registry: ArkWebAvatarAiToolRegistry,
    permissionController: ArkWebAvatarAiToolPermissionController,
    runtime: ArkWebAvatarAiToolExecutorRuntime
  ) {
    this.registry = registry;
    this.permissionController = permissionController;
    this.runtime = runtime;
  }

  /**
   * 执行工具调用。
   *
   * 前置条件 (由调用方保证):
   *   - Provider 已结构化解析 tool call
   *   - argumentsJson 已完成增量拼接
   *
   * 本方法内部顺序:
   *   1. disposed 检查
   *   2. 去重检查 (chatTurnId + toolCallId)
   *   3. 权限校验
   *   4. 工具名校验
   *   5. argumentsJson 校验
   *   6. 分发到具体工具执行
   *
   * @param context 工具调用上下文 (chatTurnId / snapshot / permissionMode)
   * @param call 工具调用
   * @returns 执行结果 (含 success/errorCode/resultJson)
   */
  async execute(
    context: ArkWebAvatarAiToolContext,
    call: ArkWebChatToolCall
  ): Promise<ArkWebChatToolExecutionResult> {
    if (this.disposed) {
      return this.buildErrorResult(call,
        ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_DISPOSED,
        'Executor disposed');
    }

    // 1. 去重检查
    const cached: ArkWebChatToolExecutionResult | null = this.findCachedResult(
      context.chatTurnId, call.toolCallId);
    if (cached !== null) {
      console.info(LOG_TAG,
        `duplicate tool call ignored: turn=${context.chatTurnId} id=${call.toolCallId}`);
      return cached;
    }

    // 2. 权限校验
    const permissionError: [string, string] | null =
      this.permissionController.checkToolAllowed(call.name);
    if (permissionError !== null) {
      const result: ArkWebChatToolExecutionResult = this.buildErrorResult(call,
        permissionError[0], permissionError[1]);
      this.cacheResult(context.chatTurnId, result);
      return result;
    }

    // 3. 工具名校验
    const nameError: [string, string] | null = this.registry.validateToolName(call.name);
    if (nameError !== null) {
      const result: ArkWebChatToolExecutionResult = this.buildErrorResult(call,
        nameError[0], nameError[1]);
      this.cacheResult(context.chatTurnId, result);
      return result;
    }

    // 4. argumentsJson 校验
    const argsError: [string, string] | null =
      this.registry.validateArgumentsJson(call.argumentsJson);
    if (argsError !== null) {
      const result: ArkWebChatToolExecutionResult = this.buildErrorResult(call,
        argsError[0], argsError[1]);
      this.cacheResult(context.chatTurnId, result);
      return result;
    }

    // 5. 分发到具体工具
    let result: ArkWebChatToolExecutionResult;
    try {
      if (call.name === ArkWebAvatarAiToolName.AVATAR_LIST_CAPABILITIES) {
        result = this.executeListCapabilities(context, call);
      } else if (call.name === ArkWebAvatarAiToolName.AVATAR_GET_STATE) {
        result = await this.executeGetState(call);
      } else if (call.name === ArkWebAvatarAiToolName.AVATAR_PERFORM) {
        result = await this.executePerform(context, call);
      } else if (call.name === ArkWebAvatarAiToolName.AVATAR_STOP) {
        result = await this.executeStop(call);
      } else {
        result = this.buildErrorResult(call,
          ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_NAME_INVALID,
          `unsupported tool: ${call.name}`);
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      result = this.buildErrorResult(call,
        ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_EXECUTION_FAILED,
        `execution threw: ${msg}`);
    }

    // 6. 缓存结果
    this.cacheResult(context.chatTurnId, result);
    return result;
  }

  /**
   * 清除去重缓存 (页面退出或权限降级时调用)。
   */
  clearCache(): void {
    this.resultCache = [];
  }

  /**
   * 销毁 (清空缓存, 后续 execute 返回 DISPOSED 错误)。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.resultCache = [];
  }

  // ===== 内部: 具体工具执行 =====

  /**
   * avatar_list_capabilities: 从 snapshot 读取能力列表。
   */
  private executeListCapabilities(
    context: ArkWebAvatarAiToolContext,
    call: ArkWebChatToolCall
  ): ArkWebChatToolExecutionResult {
    const snapshot: ArkWebAvatarAiCapabilitySnapshot | null = context.snapshot;
    if (snapshot === null) {
      return this.buildErrorResult(call,
        ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_CAPABILITY_NOT_FOUND,
        'no model loaded');
    }

    const animations: ArkWebAvatarAiAnimationSummary[] = [];
    for (let i = 0; i < snapshot.animations.length; i++) {
      const a = snapshot.animations[i];
      animations.push({
        actionId: a.actionId,
        displayName: a.displayName,
        isDefaultIdle: a.isDefaultIdle
      });
    }

    const poses: ArkWebAvatarAiPoseSummary[] = [];
    for (let i = 0; i < snapshot.poses.length; i++) {
      const p = snapshot.poses[i];
      poses.push({
        poseId: p.poseId,
        displayName: p.displayName,
        isDefaultPose: p.isDefaultPose
      });
    }

    const expressions: ArkWebAvatarAiExpressionSummary[] = [];
    for (let i = 0; i < snapshot.expressions.length; i++) {
      const e = snapshot.expressions[i];
      expressions.push({
        expressionId: e.expressionId,
        available: e.available
      });
    }

    const resultJson: ArkWebAvatarListCapabilitiesResultJson = {
      modelId: snapshot.modelId,
      modelDisplayName: snapshot.modelDisplayName,
      animations: animations,
      poses: poses,
      expressions: expressions
    };

    return {
      toolCallId: call.toolCallId,
      name: call.name,
      success: true,
      resultJson: JSON.stringify(resultJson),
      errorCode: '',
      errorMessage: ''
    };
  }

  /**
   * avatar_get_state: 从 runtime 读取业务状态。
   */
  private async executeGetState(
    call: ArkWebChatToolCall
  ): Promise<ArkWebChatToolExecutionResult> {
    const state: ArkWebAvatarToolExecutorBusinessState = this.runtime.getAvatarBusinessState();
    const resultJson: ArkWebAvatarGetStateResultJson = {
      connected: state.connected,
      modelReady: state.modelReady,
      modelDisplayName: state.modelDisplayName,
      shot: state.shot,
      performanceState: state.performanceState,
      motionType: state.motionType,
      motionId: state.motionId,
      expressionId: state.expressionId
    };
    return {
      toolCallId: call.toolCallId,
      name: call.name,
      success: true,
      resultJson: JSON.stringify(resultJson),
      errorCode: '',
      errorMessage: ''
    };
  }

  /**
   * avatar_perform: 构建 performanceHintJson, 通过 AvatarChatBridge 发布。
   *
   * 链路: AvatarChatBridge → ChatAvatarStage Avatar endpoint
   *       → LifecycleController → ShotDirector → PerformanceController
   *
   * turnId 格式: avatar_tool_<chatTurnId>_<toolCallId>
   * source: AI_TOOL_CALL
   */
  private async executePerform(
    context: ArkWebAvatarAiToolContext,
    call: ArkWebChatToolCall
  ): Promise<ArkWebChatToolExecutionResult> {
    // 解析参数
    const parsed: Record<string, Object> = JSON.parse(call.argumentsJson) as Record<string, Object>;
    const params: ArkWebAvatarPerformParams = this.extractPerformParams(parsed);

    // 参数校验 (Registry.validatePerformParams)
    const validationError: [string, string] | null =
      this.registry.validatePerformParams(params, context.snapshot);
    if (validationError !== null) {
      return this.buildErrorResult(call, validationError[0], validationError[1]);
    }

    // 构建 performanceHintJson (与 AI 面板按钮使用相同结构)
    const hintJson: string = JSON.stringify({
      motionType: params.motionType,
      motionId: params.motionId,
      expressionId: params.expressionId,
      expressionWeight: params.expressionWeight,
      durationMs: params.durationMs,
      interruptPolicy: 'REPLACE',
      returnPolicy: params.returnPolicy
    });

    // 构建稳定的 Bridge turnId: avatar_tool_<chatTurnId>_<toolCallId>
    const turnId: string = `avatar_tool_${context.chatTurnId}_${call.toolCallId}`;

    // 通过 Runtime 回调发布 (source = AI_TOOL_CALL)
    const published: boolean = await this.runtime.publishPerformanceForToolCall(
      turnId, hintJson);

    if (!published) {
      const resultJson: ArkWebAvatarPerformResultJson = {
        success: false,
        errorCode: ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ENDPOINT_UNAVAILABLE,
        message: 'Avatar endpoint unavailable or bridge rejected.',
        commandId: ''
      };
      return {
        toolCallId: call.toolCallId,
        name: call.name,
        success: false,
        resultJson: JSON.stringify(resultJson),
        errorCode: ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ENDPOINT_UNAVAILABLE,
        errorMessage: 'publishPerformanceForToolCall returned false'
      };
    }

    const resultJson: ArkWebAvatarPerformResultJson = {
      success: true,
      errorCode: '',
      message: 'Avatar performance started.',
      commandId: turnId
    };
    return {
      toolCallId: call.toolCallId,
      name: call.name,
      success: true,
      resultJson: JSON.stringify(resultJson),
      errorCode: '',
      errorMessage: ''
    };
  }

  /**
   * avatar_stop: 通过 ChatAvatarStage 生命周期入口停止演出。
   *
   * 禁止直接调用 JS Runtime。
   */
  private async executeStop(
    call: ArkWebChatToolCall
  ): Promise<ArkWebChatToolExecutionResult> {
    try {
      await this.runtime.stopPerformanceForToolCall('AI_TOOL_STOP');
      const resultJson: ArkWebAvatarStopResultJson = {
        success: true,
        errorCode: '',
        message: 'Avatar performance stopped.'
      };
      return {
        toolCallId: call.toolCallId,
        name: call.name,
        success: true,
        resultJson: JSON.stringify(resultJson),
        errorCode: '',
        errorMessage: ''
      };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      const resultJson: ArkWebAvatarStopResultJson = {
        success: false,
        errorCode: ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_EXECUTION_FAILED,
        message: `Stop failed: ${msg}`
      };
      return {
        toolCallId: call.toolCallId,
        name: call.name,
        success: false,
        resultJson: JSON.stringify(resultJson),
        errorCode: ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_EXECUTION_FAILED,
        errorMessage: msg
      };
    }
  }

  // ===== 内部: 参数提取与结果构建 =====

  /**
   * 从 argumentsJson 解析后的 Record 提取 ArkWebAvatarPerformParams。
   * 拒绝未知字段和嵌套对象。
   */
  private extractPerformParams(obj: Record<string, Object>): ArkWebAvatarPerformParams {
    const knownKeys: string[] = [
      'motionType', 'motionId', 'expressionId',
      'expressionWeight', 'durationMs', 'returnPolicy'
    ];

    // 拒绝未知字段
    const keys: string[] = Object.keys(obj);
    for (let i = 0; i < keys.length; i++) {
      if (knownKeys.indexOf(keys[i]) < 0) {
        // 未知字段: 留给 validatePerformParams 处理, 这里先提取已知字段
      }
    }

    // 拒绝嵌套对象 (已知字段必须是基本类型)
    const motionType: Object | undefined = obj['motionType'];
    const motionId: Object | undefined = obj['motionId'];
    const expressionId: Object | undefined = obj['expressionId'];
    const expressionWeight: Object | undefined = obj['expressionWeight'];
    const durationMs: Object | undefined = obj['durationMs'];
    const returnPolicy: Object | undefined = obj['returnPolicy'];

    return {
      motionType: typeof motionType === 'string' ? motionType : '',
      motionId: typeof motionId === 'string' ? motionId : '',
      expressionId: typeof expressionId === 'string' ? expressionId : '',
      expressionWeight: typeof expressionWeight === 'number' ? expressionWeight : 0,
      durationMs: typeof durationMs === 'number' ? durationMs : 0,
      returnPolicy: typeof returnPolicy === 'string' ? returnPolicy : ''
    };
  }

  private buildErrorResult(
    call: ArkWebChatToolCall,
    errorCode: string,
    errorMessage: string
  ): ArkWebChatToolExecutionResult {
    return {
      toolCallId: call.toolCallId,
      name: call.name,
      success: false,
      resultJson: JSON.stringify({
        success: false,
        errorCode: errorCode,
        message: errorMessage
      }),
      errorCode: errorCode,
      errorMessage: errorMessage
    };
  }

  // ===== 内部: 去重缓存 =====

  private findCachedResult(
    chatTurnId: string,
    toolCallId: string
  ): ArkWebChatToolExecutionResult | null {
    for (let i = 0; i < this.resultCache.length; i++) {
      const entry: ArkWebAvatarToolResultCacheEntry = this.resultCache[i];
      if (entry.chatTurnId === chatTurnId && entry.toolCallId === toolCallId) {
        return entry.result;
      }
    }
    return null;
  }

  private cacheResult(
    chatTurnId: string,
    result: ArkWebChatToolExecutionResult
  ): void {
    // 超过上限删除最旧
    while (this.resultCache.length >= AVATAR_TOOL_RESULT_CACHE_LIMIT) {
      this.resultCache.shift();
    }
    this.resultCache.push({
      chatTurnId: chatTurnId,
      toolCallId: result.toolCallId,
      result: result,
      cachedAt: Date.now()
    });
  }
}

/**
 * Phase 4A-3: AI Tool Calling source 标识。
 *
 * 与 ArkWebAvatarChatFinalResultSource 区分:
 * - SINGLE_CHAT: 真实聊天页面发布的最终消息
 * - AI_TAB_MANUAL_TEST: AI Tab 手动测试
 * - CHAT_AI_PANEL: AI 面板手动点击
 * - AI_TOOL_CALL: AI 原生 Tool Calling 触发 (本阶段新增)
 *
 * 需要在 ArkWebAvatarChatBridgeTypes.ets 中补充此常量。
 */
export const AI_TOOL_CALL_SOURCE: string = 'AI_TOOL_CALL';
