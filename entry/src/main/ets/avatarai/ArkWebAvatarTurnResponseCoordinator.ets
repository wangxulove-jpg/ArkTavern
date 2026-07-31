/**
 * ArkWebAvatarTurnResponseCoordinator — Phase 4D-1
 *
 * 逐轮 Avatar 回应协调器。
 *
 * 职责:
 *   - 接收 ArkWebAvatarFinalTurn, 按优先级选择唯一回应来源
 *   - 同一 turnId 去重 (最多 64 个缓存, LRU)
 *   - 本地兜底通过 ArkWebAvatarChatBridge.publishFinalResult 提交
 *   - 记录最后回应来源和结果供 AI 面板显示
 *   - 不解析助手正文 (TEXT_CONTENT_PARSING: NO)
 *
 * 优先级 (高 → 低):
 *   1. NATIVE_TOOL: nativeAvatarToolAttempted=true (即使 executed=false)
 *      → 不执行 Hint, 不执行本地兜底
 *      → 可执行轻量恢复 (恢复默认姿势, 保持镜头)
 *   2. STRUCTURED_HINT: performanceHintJson 非空且 nativeAvatarToolAttempted=false
 *      → 执行 Hint (通过现有 onAssistantMessageFinalized 路径)
 *      → 不执行本地兜底
 *   3. LOCAL_FALLBACK: 两者都没有, 且 everyTurnResponseEnabled=true
 *      → 执行本地兜底 (LIGHT 强度, 保持镜头)
 *   4. NONE: 每轮回应关闭
 *
 * 镜头保持规则:
 *   - LOCAL_FALLBACK 不修改 shotControlMode / cameraZoomMultiplier / 当前手动镜头
 *   - LOCAL_FALLBACK 使用 returnPolicy=KEEP 或 DEFAULT_POSE, 不强制脸部特写
 *   - 手动镜头模式 (MANUAL_FULL_BODY / MANUAL_FACE_RESET_VIEW) 永远优先
 *
 * 异步执行:
 *   - 使用 responseGeneration 队列, 旧结果不得覆盖新 Turn 状态
 *   - 提交失败只记录日志, 不阻塞聊天文本显示
 */

import { Logger } from '../utils/Logger';
import { ArkWebAvatarChatBridge } from '../services/avatar/ArkWebAvatarChatBridge';
import {
  ArkWebAvatarChatFinalResult,
  ArkWebAvatarChatFinalResultSource
} from '../services/avatar/ArkWebAvatarChatBridgeTypes';
import {
  ArkWebAvatarFinalTurn,
  ArkWebAvatarTurnResponseSource,
  ArkWebAvatarTurnResponseIntensity,
  ArkWebAvatarTurnResponseResult,
  ArkWebAvatarLocalFallbackConfig,
  DEFAULT_LOCAL_FALLBACK_CONFIG,
  TURN_RESPONSE_CACHE_LIMIT,
  LOCAL_FALLBACK_EXPRESSION_ONLY_COMMAND,
  LOCAL_FALLBACK_DEFAULT_POSE_COMMAND,
  buildLocalFallbackAnimationCommand,
  DIALOGUE_LOCAL_FALLBACK_SOURCE,
  ArkWebAvatarTurnResponseResultConst
} from './ArkWebAvatarTurnResponseTypes';

const LOG_TAG: string = 'AvatarTurnResponseCoordinator';

/**
 * 能力快照提供器 (用于判断默认动作/表情是否仍可用)。
 *
 * 返回当前 Avatar 能力快照, null 表示未就绪。
 */
export interface ArkWebAvatarCapabilitySnapshotProvider {
  /** 获取当前能力快照 (同步, 可能为 null) */
  getCapabilitySnapshot(): Object | null;
}

/**
 * Coordinator 依赖注入参数。
 */
export interface ArkWebAvatarTurnResponseCoordinatorParams {
  /** Bridge 实例 (应用级单例, 不 dispose) */
  bridge: ArkWebAvatarChatBridge;
  /** 能力快照提供器 (可选, 用于验证默认动作可用性) */
  capabilitySnapshotProvider: ArkWebAvatarCapabilitySnapshotProvider | null;
}

/**
 * 逐轮 Avatar 回应协调器。
 *
 * 生命周期:
 *   - ChatPage aboutToAppear 时创建
 *   - ChatPage aboutToDisappear 时 dispose
 *   - 不持有应用级单例的销毁权 (Bridge)
 */
export class ArkWebAvatarTurnResponseCoordinator {
  private bridge: ArkWebAvatarChatBridge;
  private capabilitySnapshotProvider: ArkWebAvatarCapabilitySnapshotProvider | null;
  private disposed: boolean = false;

  /** 已处理 turnId 集合 (去重 + LRU) */
  private processedTurnIds: string[] = [];
  /** turnId → 回应结果映射 */
  private resultByTurnId: Map<string, ArkWebAvatarTurnResponseResult> = new Map();

  /** 本地兜底配置 */
  private fallbackConfig: ArkWebAvatarLocalFallbackConfig = DEFAULT_LOCAL_FALLBACK_CONFIG;

  /** 最后回应来源 (供 AI 面板显示) */
  private lastResponseSource: ArkWebAvatarTurnResponseSource = ArkWebAvatarTurnResponseResultConst.SOURCE_NONE;
  /** 最后回应结果 (供 AI 面板显示) */
  private lastResponseResult: ArkWebAvatarTurnResponseResult | null = null;

  constructor(params: ArkWebAvatarTurnResponseCoordinatorParams) {
    this.bridge = params.bridge;
    this.capabilitySnapshotProvider = params.capabilitySnapshotProvider;
  }

  /**
   * 设置本地兜底配置 (由 AI 面板调用)。
   */
  setFallbackConfig(config: ArkWebAvatarLocalFallbackConfig): void {
    this.fallbackConfig = {
      everyTurnResponseEnabled: config.everyTurnResponseEnabled,
      defaultResponseAnimationId: config.defaultResponseAnimationId,
      defaultResponseExpressionId: config.defaultResponseExpressionId
    };
    Logger.info(LOG_TAG, `setFallbackConfig: enabled=${config.everyTurnResponseEnabled}` +
      ` anim=${config.defaultResponseAnimationId}` +
      ` expr=${config.defaultResponseExpressionId}`);
  }

  /**
   * 获取本地兜底配置。
   */
  getFallbackConfig(): ArkWebAvatarLocalFallbackConfig {
    return this.fallbackConfig;
  }

  /**
   * 获取最后回应来源 (供 AI 面板显示)。
   */
  getLastResponseSource(): ArkWebAvatarTurnResponseSource {
    return this.lastResponseSource;
  }

  /**
   * 获取最后回应结果 (供 AI 面板显示)。
   */
  getLastResponseResult(): ArkWebAvatarTurnResponseResult | null {
    return this.lastResponseResult;
  }

  /**
   * 助手最终 Turn 完成时调用 (核心入口)。
   *
   * 流程:
   *   1. 去重检查 (同一 turnId 只处理一次)
   *   2. 优先级选择回应来源
   *   3. 根据来源执行:
   *      - NATIVE_TOOL: 不提交 (已由 Tool Executor 执行), 可选轻量恢复
   *      - STRUCTURED_HINT: 不提交 (已由 onAssistantMessageFinalized 提交)
   *      - LOCAL_FALLBACK: 提交本地兜底演出命令到 Bridge
   *      - NONE: 不提交
   *   4. 记录结果到缓存
   *   5. 更新 lastResponseSource / lastResponseResult
   *
   * @param turn 助手最终 Turn 输入
   * @returns 回应结果
   */
  async onAssistantTurnFinalized(
    turn: ArkWebAvatarFinalTurn
  ): Promise<ArkWebAvatarTurnResponseResult> {
    if (this.disposed) {
      return this.buildResult(turn.turnId,
        ArkWebAvatarTurnResponseResultConst.SOURCE_NONE,
        ArkWebAvatarTurnResponseResultConst.INTENSITY_LIGHT,
        false, 0, false, false, '', 'DISPOSED', '', '', '',
        'COORDINATOR_DISPOSED', 'coordinator disposed');
    }

    // 1. 去重检查
    if (this.resultByTurnId.has(turn.turnId)) {
      const existing: ArkWebAvatarTurnResponseResult | undefined = this.resultByTurnId.get(turn.turnId);
      if (existing !== undefined) {
        Logger.warn(LOG_TAG, `onAssistantTurnFinalized duplicate turnId=${turn.turnId}, ignore`);
        return existing;
      }
    }

    // 2. 优先级选择
    const source: ArkWebAvatarTurnResponseSource = this.selectResponseSource(turn);
    const intensity: ArkWebAvatarTurnResponseIntensity = this.selectIntensity(source);

    Logger.info(LOG_TAG, `onAssistantTurnFinalized turnId=${turn.turnId}` +
      ` source=${source} intensity=${intensity}` +
      ` nativeAttempted=${turn.nativeAvatarToolAttempted}` +
      ` nativeExecuted=${turn.nativeAvatarToolExecuted}` +
      ` hintLen=${turn.performanceHintJson.length}`);

    // 3. 执行
    let result: ArkWebAvatarTurnResponseResult;
    if (source === ArkWebAvatarTurnResponseResultConst.SOURCE_NATIVE_TOOL) {
      // Native Tool 已由 Tool Executor 执行, 这里只记录结果
      // 不再提交第二主要动作, 可选轻量恢复 (保持镜头)
      result = this.buildResult(turn.turnId, source, intensity,
        true, Date.now(), turn.nativeAvatarToolExecuted, turn.nativeAvatarToolExecuted,
        '', 'NATIVE_TOOL_EXECUTED', '', '', '',
        '', '');
    } else if (source === ArkWebAvatarTurnResponseResultConst.SOURCE_STRUCTURED_HINT) {
      // Structured Hint 已由 onAssistantMessageFinalized 路径提交到 Bridge
      // Coordinator 不重复提交, 只记录选择
      result = this.buildResult(turn.turnId, source, intensity,
        true, Date.now(), true, false,
        '', 'HINT_SUBMITTED_BY_CALLBACK', '', '', '',
        '', '');
    } else if (source === ArkWebAvatarTurnResponseResultConst.SOURCE_LOCAL_FALLBACK) {
      // 本地兜底: 提交演出命令到 Bridge
      result = await this.executeLocalFallback(turn.turnId);
    } else {
      // NONE: 每轮回应关闭
      result = this.buildResult(turn.turnId, source, intensity,
        false, 0, false, false,
        '', 'NONE', '', '', '',
        '', '');
    }

    // 4. 记录到缓存
    this.recordResult(turn.turnId, result);

    // 5. 更新最后状态
    this.lastResponseSource = source;
    this.lastResponseResult = result;

    return result;
  }

  /**
   * 优先级选择回应来源。
   *
   * 规则:
   *   - nativeAvatarToolAttempted=true → NATIVE_TOOL (即使 executed=false)
   *   - performanceHintJson 非空且 native 未尝试 → STRUCTURED_HINT
   *   - everyTurnResponseEnabled=true → LOCAL_FALLBACK
   *   - 否则 → NONE
   */
  private selectResponseSource(turn: ArkWebAvatarFinalTurn): ArkWebAvatarTurnResponseSource {
    // 优先级 1: Native Tool (即使失败也占用该 Turn 的主要回应)
    if (turn.nativeAvatarToolAttempted) {
      return ArkWebAvatarTurnResponseResultConst.SOURCE_NATIVE_TOOL;
    }
    // 优先级 2: Structured Hint
    if (turn.performanceHintJson.length > 0) {
      return ArkWebAvatarTurnResponseResultConst.SOURCE_STRUCTURED_HINT;
    }
    // 优先级 3: Local Fallback
    if (this.fallbackConfig.everyTurnResponseEnabled) {
      return ArkWebAvatarTurnResponseResultConst.SOURCE_LOCAL_FALLBACK;
    }
    // 优先级 4: None
    return ArkWebAvatarTurnResponseResultConst.SOURCE_NONE;
  }

  /**
   * 选择回应强度。
   */
  private selectIntensity(source: ArkWebAvatarTurnResponseSource): ArkWebAvatarTurnResponseIntensity {
    switch (source) {
      case ArkWebAvatarTurnResponseResultConst.SOURCE_LOCAL_FALLBACK:
        return ArkWebAvatarTurnResponseResultConst.INTENSITY_LIGHT;
      case ArkWebAvatarTurnResponseResultConst.SOURCE_STRUCTURED_HINT:
        return ArkWebAvatarTurnResponseResultConst.INTENSITY_NORMAL;
      case ArkWebAvatarTurnResponseResultConst.SOURCE_NATIVE_TOOL:
        return ArkWebAvatarTurnResponseResultConst.INTENSITY_EMPHATIC;
      default:
        return ArkWebAvatarTurnResponseResultConst.INTENSITY_LIGHT;
    }
  }

  /**
   * 执行本地兜底回应。
   *
   * 选择顺序:
   *   1. 用户配置了默认动作且能力仍存在 → animation + 可选表情
   *   2. 没有动作, 但配置了可用表情 → expression-only (保持镜头)
   *   3. 两者都没有 → 恢复默认姿势 (最轻量, 不重新加载模型)
   *
   * 所有命令通过 Bridge.publishFinalResult 提交, source=DIALOGUE_LOCAL_FALLBACK。
   * 不直接调用底层 Runtime, 不修改镜头。
   */
  private async executeLocalFallback(turnId: string): Promise<ArkWebAvatarTurnResponseResult> {
    const hintJson: string = this.buildLocalFallbackHintJson();
    const submittedAt: number = Date.now();

    const result: ArkWebAvatarChatFinalResult = {
      turnId: turnId,
      performanceHintJson: hintJson,
      finalizedAt: submittedAt,
      source: DIALOGUE_LOCAL_FALLBACK_SOURCE
    };

    try {
      const accepted: boolean = await this.bridge.publishFinalResult(result);
      if (!accepted) {
        Logger.warn(LOG_TAG, `executeLocalFallback rejected: turnId=${turnId}`);
        return this.buildResult(turnId,
          ArkWebAvatarTurnResponseResultConst.SOURCE_LOCAL_FALLBACK,
          ArkWebAvatarTurnResponseResultConst.INTENSITY_LIGHT,
          true, submittedAt, false, false,
          '', 'BRIDGE_REJECTED', '', '', '',
          'LOCAL_FALLBACK_BRIDGE_REJECTED', 'bridge rejected local fallback');
      }
      Logger.info(LOG_TAG, `executeLocalFallback submitted: turnId=${turnId} hintLen=${hintJson.length}`);
      return this.buildResult(turnId,
        ArkWebAvatarTurnResponseResultConst.SOURCE_LOCAL_FALLBACK,
        ArkWebAvatarTurnResponseResultConst.INTENSITY_LIGHT,
        true, submittedAt, true, false,
        '', 'LOCAL_FALLBACK_SUBMITTED', '', '', '',
        '', '');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.warn(LOG_TAG, `executeLocalFallback threw: turnId=${turnId} err=${msg}`);
      return this.buildResult(turnId,
        ArkWebAvatarTurnResponseResultConst.SOURCE_LOCAL_FALLBACK,
        ArkWebAvatarTurnResponseResultConst.INTENSITY_LIGHT,
        true, submittedAt, false, false,
        '', 'LOCAL_FALLBACK_THREW', '', '', '',
        'LOCAL_FALLBACK_THREW', msg);
    }
  }

  /**
   * 构建本地兜底演出命令 JSON。
   *
   * 选择顺序见 executeLocalFallback。
   */
  private buildLocalFallbackHintJson(): string {
    const animId: string = this.fallbackConfig.defaultResponseAnimationId;
    const exprId: string = this.fallbackConfig.defaultResponseExpressionId;

    // 1. 配置了默认动作 → animation + 可选表情
    if (animId.length > 0) {
      return buildLocalFallbackAnimationCommand(animId, exprId);
    }
    // 2. 配置了默认表情 → expression-only (保持镜头, returnPolicy=KEEP)
    if (exprId.length > 0) {
      return LOCAL_FALLBACK_EXPRESSION_ONLY_COMMAND;
    }
    // 3. 都没有 → 恢复默认姿势 (最轻量)
    return LOCAL_FALLBACK_DEFAULT_POSE_COMMAND;
  }

  /**
   * 构建回应结果。
   */
  private buildResult(
    turnId: string,
    source: ArkWebAvatarTurnResponseSource,
    intensity: ArkWebAvatarTurnResponseIntensity,
    submitted: boolean,
    submittedAt: number,
    accepted: boolean,
    executed: boolean,
    commandId: string,
    lifecycleState: string,
    motionType: string,
    motionId: string,
    expressionId: string,
    errorCode: string,
    errorMessage: string
  ): ArkWebAvatarTurnResponseResult {
    const result: ArkWebAvatarTurnResponseResult = {
      turnId: turnId,
      responseSource: source,
      intensity: intensity,
      submitted: submitted,
      submittedAt: submittedAt,
      accepted: accepted,
      executed: executed,
      commandId: commandId,
      lifecycleState: lifecycleState,
      motionType: motionType,
      motionId: motionId,
      expressionId: expressionId,
      errorCode: errorCode,
      errorMessage: errorMessage
    };
    return result;
  }

  /**
   * 记录结果到缓存 (LRU, 上限 64)。
   */
  private recordResult(turnId: string, result: ArkWebAvatarTurnResponseResult): void {
    // 已存在则更新
    if (this.resultByTurnId.has(turnId)) {
      this.resultByTurnId.set(turnId, result);
      return;
    }
    // 新增
    this.processedTurnIds.push(turnId);
    this.resultByTurnId.set(turnId, result);
    // LRU: 超过上限删除最旧
    while (this.processedTurnIds.length > TURN_RESPONSE_CACHE_LIMIT) {
      const oldest: string | undefined = this.processedTurnIds.shift();
      if (oldest !== undefined) {
        this.resultByTurnId.delete(oldest);
      }
    }
  }

  /**
   * 查询指定 turnId 的结果 (供测试使用)。
   */
  getResult(turnId: string): ArkWebAvatarTurnResponseResult | null {
    const result: ArkWebAvatarTurnResponseResult | undefined = this.resultByTurnId.get(turnId);
    return result !== undefined ? result : null;
  }

  /**
   * 查询已处理 turnId 数量。
   */
  getProcessedCount(): number {
    return this.processedTurnIds.length;
  }

  /**
   * 清空缓存 (供测试使用, 生产环境不调用)。
   */
  clearCache(): void {
    this.processedTurnIds = [];
    this.resultByTurnId.clear();
    this.lastResponseSource = ArkWebAvatarTurnResponseResultConst.SOURCE_NONE;
    this.lastResponseResult = null;
  }

  /**
   * 销毁协调器。
   *
   * - 不 dispose Bridge (应用级单例)
   * - 清空缓存
   * - 清空配置
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.processedTurnIds = [];
    this.resultByTurnId.clear();
    this.capabilitySnapshotProvider = null;
    Logger.info(LOG_TAG, 'coordinator disposed');
  }

  /**
   * 是否已销毁。
   */
  isDisposed(): boolean {
    return this.disposed;
  }
}
