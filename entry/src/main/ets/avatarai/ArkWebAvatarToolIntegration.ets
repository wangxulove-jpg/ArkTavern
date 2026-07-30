/**
 * ArkWebAvatarToolIntegration.ets — Phase 4A-3R
 *
 * Avatar Tool Integration 生命周期辅助类。
 *
 * 职责:
 *   - 在 ChatPage aboutToAppear 时创建并装配:
 *     ArkWebAvatarAiToolRegistry
 *     ArkWebAvatarAiToolPermissionController
 *     ArkWebAvatarAiToolExecutor
 *     ArkWebAvatarDialogueStrategyBuilder
 *     ArkWebAvatarDialogueSessionState
 *     ArkWebAvatarDialogueRhythmPolicy
 *   - 通过 snapshotProvider 回调复用 ChatAvatarStage 的 CapabilityCatalog
 *   - 通过 runtime 回调复用 ChatAvatarStage 的 publishPerformanceFromPanel / cancelPerformance
 *   - 不创建第二套 Avatar Runtime (模型加载器 / 动画加载器 / PerformanceController / ShotDirector)
 *   - 在 ChatPage aboutToDisappear 时 dispose
 *
 * 不持有:
 *   - AvatarChatBridge (应用级单例, 不 dispose)
 *   - 持久化 AssetLibrary (应用级, 不 dispose)
 *
 * 设计原则:
 *   - 一页一实例: 每次进入 ChatPage 创建新的 Integration, 退出时 dispose
 *   - 不缓存: 重新进入页面必须重新接线
 *   - 不共享: 跨页面共享通过应用级单例 (Bridge), 不通过 Integration
 */

import { ArkWebAvatarAiToolRegistry } from './ArkWebAvatarAiToolRegistry';
import { ArkWebAvatarAiToolPermissionController } from './ArkWebAvatarAiToolPermissionController';
import {
  ArkWebAvatarAiToolExecutor,
  ArkWebAvatarAiToolExecutorRuntime,
  ArkWebAvatarToolPerformanceExecutionResult,
  ArkWebAvatarToolExecutorBusinessState
} from './ArkWebAvatarAiToolExecutor';
import { ArkWebAvatarDialogueStrategyBuilder } from './ArkWebAvatarDialogueStrategyBuilder';
import { ArkWebAvatarDialogueSessionState } from './ArkWebAvatarDialogueSessionState';
import { ArkWebAvatarDialogueRhythmPolicy } from './ArkWebAvatarDialogueRhythmPolicy';
import {
  ArkWebAvatarAiCapabilitySnapshot
} from '../vrmviewer/ArkWebAvatarAiTypes';
import {
  AvatarToolIntegrationState,
  AvatarToolIntegrationStateConst
} from './NativeToolCallingCapability';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ArkWebAvatarToolIntegration';

/**
 * Integration 持有的运行时回调集合 (由 ChatPage 注入)。
 *
 * - snapshotProvider: 返回当前 Avatar 能力快照 (复用 StageController.getCapabilitySnapshot 的同步缓存)
 * - publishPerformanceForToolCall: 发布 AI 工具调用演出 (复用 StageController.publishPerformanceFromPanel)
 * - publishPerformanceForToolCallAndWait: 发布并等待真实执行结果 (复用 StageController.publishPerformanceFromPanelAndWait)
 * - stopPerformanceForToolCall: 停止 AI 工具调用演出 (复用 StageController.cancelPerformance)
 * - getAvatarBusinessState: 返回 Avatar 业务状态 (复用 StageController.getRuntimeSnapshot)
 *
 * 所有回调都由 ChatPage 提供实现, Integration 不直接访问 StageController。
 */
export interface ArkWebAvatarToolIntegrationRuntime extends ArkWebAvatarAiToolExecutorRuntime {
  /** 能力快照提供器 (同步返回缓存, 不触发异步请求) */
  snapshotProvider: () => ArkWebAvatarAiCapabilitySnapshot | null;
}

/**
 * ArkWebAvatarToolIntegrationRuntime 的 class 实现。
 *
 * ArkTS 严格模式 (arkts-no-untyped-obj-literals) 不允许直接用对象字面量赋值给
 * 包含可选函数成员的 interface。ChatPage 通过此 class 构造 runtime 实例。
 */
export class ArkWebAvatarToolIntegrationRuntimeImpl implements ArkWebAvatarToolIntegrationRuntime {
  private readonly _snapshotProvider: () => ArkWebAvatarAiCapabilitySnapshot | null;
  private readonly _publishPerformanceForToolCall: (turnId: string, hintJson: string) => Promise<boolean>;
  private readonly _publishPerformanceForToolCallAndWait: (turnId: string, hintJson: string) => Promise<ArkWebAvatarToolPerformanceExecutionResult>;
  private readonly _stopPerformanceForToolCall: (reason: string) => Promise<void>;
  private readonly _getAvatarBusinessState: () => ArkWebAvatarToolExecutorBusinessState;

  constructor(
    snapshotProvider: () => ArkWebAvatarAiCapabilitySnapshot | null,
    publishPerformanceForToolCall: (turnId: string, hintJson: string) => Promise<boolean>,
    publishPerformanceForToolCallAndWait: (turnId: string, hintJson: string) => Promise<ArkWebAvatarToolPerformanceExecutionResult>,
    stopPerformanceForToolCall: (reason: string) => Promise<void>,
    getAvatarBusinessState: () => ArkWebAvatarToolExecutorBusinessState
  ) {
    this._snapshotProvider = snapshotProvider;
    this._publishPerformanceForToolCall = publishPerformanceForToolCall;
    this._publishPerformanceForToolCallAndWait = publishPerformanceForToolCallAndWait;
    this._stopPerformanceForToolCall = stopPerformanceForToolCall;
    this._getAvatarBusinessState = getAvatarBusinessState;
  }

  snapshotProvider(): ArkWebAvatarAiCapabilitySnapshot | null {
    return this._snapshotProvider();
  }

  publishPerformanceForToolCall(turnId: string, hintJson: string): Promise<boolean> {
    return this._publishPerformanceForToolCall(turnId, hintJson);
  }

  publishPerformanceForToolCallAndWait(turnId: string, hintJson: string): Promise<ArkWebAvatarToolPerformanceExecutionResult> {
    return this._publishPerformanceForToolCallAndWait(turnId, hintJson);
  }

  stopPerformanceForToolCall(reason: string): Promise<void> {
    return this._stopPerformanceForToolCall(reason);
  }

  getAvatarBusinessState(): ArkWebAvatarToolExecutorBusinessState {
    return this._getAvatarBusinessState();
  }
}

/**
 * buildIntegrationParams 返回的参数集合。
 *
 * - 未连接或已 dispose 时所有字段为 null
 * - 已连接时返回内部组件引用
 */
export interface ArkWebAvatarToolIntegrationParams {
  registry: ArkWebAvatarAiToolRegistry | null;
  permissionController: ArkWebAvatarAiToolPermissionController | null;
  executor: ArkWebAvatarAiToolExecutor | null;
  runtime: ArkWebAvatarAiToolExecutorRuntime | null;
  snapshotProvider: (() => ArkWebAvatarAiCapabilitySnapshot | null) | null;
  strategyBuilder: ArkWebAvatarDialogueStrategyBuilder | null;
  sessionState: ArkWebAvatarDialogueSessionState | null;
  rhythmPolicy: ArkWebAvatarDialogueRhythmPolicy | null;
}

/**
 * Avatar Tool Integration 生命周期辅助类。
 *
 * 使用方式:
 *   aboutToAppear:
 *     const integration = new ArkWebAvatarToolIntegration();
 *     integration.connect(runtime);
 *     chatService.setAvatarToolIntegration(integration.buildIntegrationParams());
 *
 *   aboutToDisappear:
 *     integration.dispose();
 *     chatService.clearAvatarToolIntegration();
 *
 * 注意:
 *   - connect() 必须在 StageController 准备好后调用 (MODEL_READY 之后)
 *   - 如果 connect() 抛出异常, state 变为 FAILED
 *   - dispose() 后所有方法 no-op
 */
export class ArkWebAvatarToolIntegration {
  private registry: ArkWebAvatarAiToolRegistry | null = null;
  private permissionController: ArkWebAvatarAiToolPermissionController | null = null;
  private executor: ArkWebAvatarAiToolExecutor | null = null;
  private strategyBuilder: ArkWebAvatarDialogueStrategyBuilder | null = null;
  private sessionState: ArkWebAvatarDialogueSessionState | null = null;
  private rhythmPolicy: ArkWebAvatarDialogueRhythmPolicy | null = null;
  private runtime: ArkWebAvatarToolIntegrationRuntime | null = null;
  private state: AvatarToolIntegrationState = AvatarToolIntegrationStateConst.NOT_CONNECTED;

  /**
   * 连接 Integration: 创建所有组件实例。
   *
   * - 必须在 StageController MODEL_READY 后调用, 确保 snapshotProvider 能返回有效快照
   * - 重复调用 connect() 会被忽略 (state 已为 CONNECTED)
   * - 已 dispose 后再 connect() 会被忽略 (state 为 DISPOSED)
   *
   * @param runtime 运行时回调 (由 ChatPage 注入, 复用 StageController)
   */
  connect(runtime: ArkWebAvatarToolIntegrationRuntime): void {
    if (this.state === AvatarToolIntegrationStateConst.DISPOSED) {
      Logger.warn(LOG_TAG, 'connect: already disposed, skip.');
      return;
    }
    if (this.state === AvatarToolIntegrationStateConst.CONNECTED) {
      Logger.warn(LOG_TAG, 'connect: already connected, skip.');
      return;
    }
    try {
      this.runtime = runtime;
      this.registry = new ArkWebAvatarAiToolRegistry();
      this.permissionController = new ArkWebAvatarAiToolPermissionController();
      this.strategyBuilder = new ArkWebAvatarDialogueStrategyBuilder();
      this.sessionState = new ArkWebAvatarDialogueSessionState();
      this.rhythmPolicy = new ArkWebAvatarDialogueRhythmPolicy();
      this.executor = new ArkWebAvatarAiToolExecutor(
        this.registry,
        this.permissionController,
        runtime,
        this.sessionState,
        this.rhythmPolicy
      );
      this.state = AvatarToolIntegrationStateConst.CONNECTED;
      Logger.info(LOG_TAG, 'connect: integration connected.');
    } catch (e) {
      this.state = AvatarToolIntegrationStateConst.FAILED;
      Logger.error(LOG_TAG, `connect failed: ${e instanceof Error ? e.message : String(e)}`);
      // 清理已创建的实例
      this.registry = null;
      this.permissionController = null;
      this.executor = null;
      this.strategyBuilder = null;
      this.sessionState = null;
      this.rhythmPolicy = null;
      this.runtime = null;
    }
  }

  /**
   * 获取当前接线状态。
   */
  getState(): AvatarToolIntegrationState {
    return this.state;
  }

  /**
   * 是否已连接 (所有依赖已注入, 可供 ChatService 使用)。
   */
  isConnected(): boolean {
    return this.state === AvatarToolIntegrationStateConst.CONNECTED;
  }

  /**
   * 构建 ChatService.setAvatarToolIntegration 所需的参数集合。
   *
   * - 未连接时返回全部 null, ChatService 视为未注入
   * - 已 dispose 后返回全部 null
   *
   * @returns Integration 参数集合 (registry / permissionController / executor / runtime / snapshotProvider / strategyBuilder / sessionState / rhythmPolicy)
   */
  buildIntegrationParams(): ArkWebAvatarToolIntegrationParams {
    if (!this.isConnected()) {
      const empty: ArkWebAvatarToolIntegrationParams = {
        registry: null,
        permissionController: null,
        executor: null,
        runtime: null,
        snapshotProvider: null,
        strategyBuilder: null,
        sessionState: null,
        rhythmPolicy: null
      };
      return empty;
    }
    const runtimeRef: ArkWebAvatarToolIntegrationRuntime | null = this.runtime;
    const snapshotProvider: (() => ArkWebAvatarAiCapabilitySnapshot | null) | null =
      runtimeRef !== null
        ? (): ArkWebAvatarAiCapabilitySnapshot | null => runtimeRef.snapshotProvider()
        : null;
    const params: ArkWebAvatarToolIntegrationParams = {
      registry: this.registry,
      permissionController: this.permissionController,
      executor: this.executor,
      runtime: this.runtime,
      snapshotProvider: snapshotProvider,
      strategyBuilder: this.strategyBuilder,
      sessionState: this.sessionState,
      rhythmPolicy: this.rhythmPolicy
    };
    return params;
  }

  /**
   * 直接获取 SessionState (供 ChatPage 调用 disposeAvatarDialogueSessionState)。
   */
  getSessionState(): ArkWebAvatarDialogueSessionState | null {
    return this.sessionState;
  }

  /**
   * 直接获取 PermissionController (供 ChatPage 在 aboutToDisappear 时恢复 DENY)。
   */
  getPermissionController(): ArkWebAvatarAiToolPermissionController | null {
    return this.permissionController;
  }

  /**
   * 销毁 Integration: 清空所有组件实例。
   *
   * - 不停止用户手动发起的演出 (由 StageController 负责)
   * - 不 dispose 应用级 Bridge / AssetLibrary
   * - dispose 后所有方法 no-op
   */
  dispose(): void {
    if (this.state === AvatarToolIntegrationStateConst.DISPOSED) {
      return;
    }
    // 权限恢复 DENY (避免跨页面残留)
    if (this.permissionController !== null) {
      try {
        this.permissionController.setPermissionMode('DENY', (): void => {});
      } catch (e) {
        Logger.warn(LOG_TAG, `dispose: setPermissionMode DENY failed: ${String(e)}`);
      }
    }
    // 销毁 SessionState (清空演出历史)
    if (this.sessionState !== null) {
      try {
        this.sessionState.dispose();
      } catch (e) {
        Logger.warn(LOG_TAG, `dispose: sessionState dispose failed: ${String(e)}`);
      }
    }
    this.registry = null;
    this.permissionController = null;
    this.executor = null;
    this.strategyBuilder = null;
    this.sessionState = null;
    this.rhythmPolicy = null;
    this.runtime = null;
    this.state = AvatarToolIntegrationStateConst.DISPOSED;
    Logger.info(LOG_TAG, 'dispose: integration disposed.');
  }
}
