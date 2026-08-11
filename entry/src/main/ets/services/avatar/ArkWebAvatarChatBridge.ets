import { Logger } from '../../utils/Logger';
/**
 * ArkWebAvatarChatBridge — Avatar ↔ 聊天应用级桥接器 (Phase 4A-2)
 *
 * 职责:
 *   - 维护 chat endpoint 和 avatar endpoint 注册表
 *   - 接收单人聊天页面发布的最终助手消息结果
 *   - 在 Avatar endpoint 未注册时入队 (有界,最大 8 条)
 *   - Avatar endpoint 注册后按顺序消费 pending 队列
 *   - 相同 turnId 去重 (DUPLICATE_TURN_POLICY:IGNORE)
 *   - 维护状态机 (DISCONNECTED / CHAT_READY / AVATAR_READY / CONNECTED / DISPOSED)
 *   - 暴露给 AI Tab 读取真实连接状态 / 待处理数量 / 最后接收 turnId
 *
 * 不实现:
 *   - 网络请求 / WebSocket / 文件轮询 / setInterval
 *   - 数据库 / 系统剪贴板 / 全局字符串事件
 *   - 真实 AI Tool Calling
 *   - 演出执行 (由 VrmViewerPage 的 handler 通过 LifecycleController 完成)
 *
 * 线程安全:
 *   - 所有方法串行执行 (ArkTS 单线程事件循环)
 *   - 异步投递通过 await + try/catch 隔离错误
 *
 * 错误隔离:
 *   - Bridge / Avatar 演出失败不影响聊天文本显示
 *   - 聊天页面只记录轻量日志,不弹出阻塞式错误
 *
 * 生命周期:
 *   - 应用级单例 (getInstance),应用整体退出才 dispose
 *   - 聊天页面 / VrmViewerPage 只 register/unregister,不 dispose
 *
 * Reference:
 *   - AGENTS.md Phase 4A-2 §应用级桥接器 / §Bridge 状态 / §无 Avatar 消费者时
 *   - ArkWebAvatarChatBridgeTypes.ets (类型定义)
 *   - ArkWebDialoguePerformanceLifecycleController.ets (下游消费)
 */
import {
  ArkWebAvatarChatBridgeState,
  ArkWebAvatarChatEndpointHandler,
  ArkWebAvatarChatFinalResult,
  ArkWebAvatarChatBridgeErrorCode,
  ARKWEB_AVATAR_CHAT_QUEUE_LIMIT
} from './ArkWebAvatarChatBridgeTypes';

/**
 * Avatar endpoint 注册项。
 *
 * 同时持有 endpointId 和 handler,便于覆盖注册 / 注销。
 */
interface AvatarEndpointEntry {
  readonly endpointId: string;
  readonly handler: ArkWebAvatarChatEndpointHandler;
}

/**
 * Avatar ↔ 聊天应用级桥接器 (单例)。
 *
 * 使用方式:
 *   - 聊天页面 aboutToAppear: getInstance().registerChatEndpoint(endpointId)
 *   - 聊天页面 aboutToDisappear: getInstance().unregisterChatEndpoint(endpointId)
 *   - 助手最终消息完成: getInstance().publishFinalResult(result)
 *   - VrmViewerPage aboutToAppear: getInstance().registerAvatarEndpoint(endpointId, handler)
 *   - VrmViewerPage disposeViewer: getInstance().unregisterAvatarEndpoint(endpointId)
 *   - 应用退出: getInstance().dispose()
 */
export class ArkWebAvatarChatBridge {
  private static instance: ArkWebAvatarChatBridge | null = null;

  /** chat endpoint ID 集合 (允许多个,任一存在即视为 CHAT_READY) */
  private chatEndpointIds: Set<string> = new Set<string>();
  /** avatar endpoint 注册项 (单一,覆盖式注册) */
  private avatarEndpoint: AvatarEndpointEntry | null = null;
  /** 待处理结果队列 (按 finalizedAt 升序,相同 turnId 去重) */
  private pendingResults: ArkWebAvatarChatFinalResult[] = [];
  /** 已发布 turnId 集合 (用于 publishFinalResult 去重) */
  private publishedTurnIds: Set<string> = new Set<string>();
  /** 当前状态 */
  private currentState: ArkWebAvatarChatBridgeState = ArkWebAvatarChatBridgeState.DISCONNECTED;
  /** 是否已销毁 */
  private disposed: boolean = false;
  /** 最后接收 turnId (供 AI Tab 显示) */
  private lastReceivedTurnId: string = '';
  /** 最后接收时间 (供 AI Tab 显示) */
  private lastReceivedAt: number = 0;
  /** 最后错误码 (供 AI Tab / 调试显示) */
  private lastErrorCode: string = '';
  /** 最后错误消息 (供 AI Tab / 调试显示) */
  private lastErrorMessage: string = '';
  /** 是否正在消费 pending 队列 (避免递归触发) */
  private consuming: boolean = false;

  private constructor() {
    // 单例,外部不得 new
  }

  /** 获取单例。 */
  static getInstance(): ArkWebAvatarChatBridge {
    if (ArkWebAvatarChatBridge.instance === null) {
      ArkWebAvatarChatBridge.instance = new ArkWebAvatarChatBridge();
    }
    return ArkWebAvatarChatBridge.instance;
  }

  /**
   * 注册聊天端点。
   *
   * 多个聊天页面实例可同时注册 (用不同 endpointId),
   * 任一存在即视为 CHAT_READY。
   *
   * @param endpointId 稳定页面实例 ID (如 'chat-page-<uuid>')
   */
  registerChatEndpoint(endpointId: string): void {
    if (this.disposed) {
      this.recordError(
        ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_BRIDGE_DISPOSED,
        'Bridge 已销毁,无法注册 chat endpoint');
      return;
    }
    if (endpointId.length === 0) {
      this.recordError(
        ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_TURN_ID_INVALID,
        'endpointId 为空');
      return;
    }
    this.chatEndpointIds.add(endpointId);
    this.refreshState();
    Logger.debug(`registerChatEndpoint id=${endpointId} state=${this.currentState}`);
  }

  /**
   * 注销聊天端点。
   *
   * @param endpointId 之前注册的 endpointId
   */
  unregisterChatEndpoint(endpointId: string): void {
    if (this.disposed) {
      return;
    }
    this.chatEndpointIds.delete(endpointId);
    this.refreshState();
    Logger.debug(`unregisterChatEndpoint id=${endpointId} state=${this.currentState}`);
  }

  /**
   * 注册 Avatar 端点。
   *
   * 单一覆盖式注册: 后注册的覆盖先注册的。
   * 注册后立即尝试消费 pending 队列 (按 finalizedAt 顺序)。
   *
   * @param endpointId 稳定页面实例 ID (如 'vrm-viewer-<uuid>')
   * @param handler 接收 ArkWebAvatarChatFinalResult 的处理函数
   */
  registerAvatarEndpoint(
    endpointId: string,
    handler: ArkWebAvatarChatEndpointHandler
  ): void {
    if (this.disposed) {
      this.recordError(
        ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_BRIDGE_DISPOSED,
        'Bridge 已销毁,无法注册 avatar endpoint');
      return;
    }
    if (endpointId.length === 0) {
      this.recordError(
        ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_TURN_ID_INVALID,
        'endpointId 为空');
      return;
    }
    this.avatarEndpoint = { endpointId, handler };
    this.refreshState();
    Logger.debug(`registerAvatarEndpoint id=${endpointId} state=${this.currentState}`);
    // 注册后立即消费 pending 队列 (不阻塞注册流程)
    this.consumePending().catch((e: Object): void => {
      Logger.warn('consumePending on register threw: ' +
        (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * 注销 Avatar 端点。
   *
   * @param endpointId 之前注册的 endpointId
   */
  unregisterAvatarEndpoint(endpointId: string): void {
    if (this.disposed) {
      return;
    }
    if (this.avatarEndpoint !== null && this.avatarEndpoint.endpointId === endpointId) {
      this.avatarEndpoint = null;
      this.refreshState();
      Logger.debug(`unregisterAvatarEndpoint id=${endpointId} state=${this.currentState}`);
    }
  }

  /**
   * 发布最终助手消息结果。
   *
   * 流程:
   *   1. disposed → 返回 false (AVATAR_CHAT_BRIDGE_DISPOSED)
   *   2. turnId 为空 → 返回 false (AVATAR_CHAT_TURN_ID_INVALID)
   *   3. 相同 turnId 已发布 → 返回 false (AVATAR_CHAT_DUPLICATE_TURN,IGNORE 策略)
   *   4. 记录到 publishedTurnIds
   *   5. 更新 lastReceivedTurnId / lastReceivedAt
   *   6. 无 Avatar endpoint → 入队 (按 finalizedAt 顺序,超过上限丢弃最旧)
   *   7. 有 Avatar endpoint → 直接调用 handler (best-effort,异常不影响返回值)
   *
   * @param result 最终助手消息结果 (只允许 turnId/performanceHintJson/finalizedAt/source)
   * @returns true 表示已接收 (含入队 / 已投递); false 表示被拒绝 (disposed / 无效 / 重复)
   */
  async publishFinalResult(result: ArkWebAvatarChatFinalResult): Promise<boolean> {
    if (this.disposed) {
      this.recordError(
        ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_BRIDGE_DISPOSED,
        'Bridge 已销毁,无法发布结果');
      return false;
    }
    if (typeof result.turnId !== 'string' || result.turnId.length === 0) {
      this.recordError(
        ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_TURN_ID_INVALID,
        'turnId 为空');
      return false;
    }
    if (this.publishedTurnIds.has(result.turnId)) {
      this.recordError(
        ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_DUPLICATE_TURN,
        `turnId=${result.turnId} 已发布,按 IGNORE 策略忽略`);
      return false;
    }
    this.publishedTurnIds.add(result.turnId);
    this.lastReceivedTurnId = result.turnId;
    this.lastReceivedAt = result.finalizedAt;
    this.clearError();

    // 无 Avatar endpoint → 入队
    if (this.avatarEndpoint === null) {
      this.enqueuePending(result);
      Logger.debug(`publishFinalResult turnId=${result.turnId} queued` +
        ` pending=${this.pendingResults.length}`);
      return true;
    }

    // 有 Avatar endpoint → 直接投递 (best-effort)
    await this.deliverToAvatar(result);
    return true;
  }

  /** 获取当前状态。 */
  getConnectionState(): string {
    return this.currentState;
  }

  /** 获取待处理消息数量。 */
  getPendingCount(): number {
    return this.pendingResults.length;
  }

  /** 获取最后接收 turnId (供 AI Tab 显示)。 */
  getLastReceivedTurnId(): string {
    return this.lastReceivedTurnId;
  }

  /** 获取最后接收时间 (供 AI Tab 显示)。 */
  getLastReceivedAt(): number {
    return this.lastReceivedAt;
  }

  /** 获取最后错误码 (供 AI Tab / 调试显示)。 */
  getLastErrorCode(): string {
    return this.lastErrorCode;
  }

  /** 获取最后错误消息 (供 AI Tab / 调试显示)。 */
  getLastErrorMessage(): string {
    return this.lastErrorMessage;
  }

  /**
   * 销毁桥接器 (仅应用退出时调用)。
   *
   * - 清空所有 endpoint 注册
   * - 清空 pending 队列
   * - 清空 publishedTurnIds (允许重新创建实例)
   * - state → DISPOSED
   *
   * 页面销毁时只调用 unregisterChatEndpoint / unregisterAvatarEndpoint,
   * 不得调用 dispose。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.chatEndpointIds.clear();
    this.avatarEndpoint = null;
    this.pendingResults = [];
    this.publishedTurnIds.clear();
    this.currentState = ArkWebAvatarChatBridgeState.DISPOSED;
    Logger.debug('Bridge disposed');
  }

  // ===== 内部方法 =====

  /**
   * 入队待处理结果。
   *
   * - 相同 turnId 去重 (publishFinalResult 已保证,这里再保险一次)
   * - 按 finalizedAt 升序插入
   * - 超过上限丢弃最旧项 (FIFO,即 finalizedAt 最小者)
   */
  private enqueuePending(result: ArkWebAvatarChatFinalResult): void {
    // 去重 (理论上不会触发,因为 publishFinalResult 已检查)
    for (let i = 0; i < this.pendingResults.length; i++) {
      if (this.pendingResults[i].turnId === result.turnId) {
        return;
      }
    }
    this.pendingResults.push(result);
    // 按 finalizedAt 升序排序
    this.pendingResults.sort(
      (a: ArkWebAvatarChatFinalResult, b: ArkWebAvatarChatFinalResult): number =>
        a.finalizedAt - b.finalizedAt
    );
    // 超过上限丢弃最旧项
    while (this.pendingResults.length > ARKWEB_AVATAR_CHAT_QUEUE_LIMIT) {
      const dropped: ArkWebAvatarChatFinalResult | undefined = this.pendingResults.shift();
      if (dropped !== undefined) {
        this.recordError(
          ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_QUEUE_FULL,
          `队列已满,丢弃最旧 turnId=${dropped.turnId}`);
      }
    }
  }

  /**
   * 消费 pending 队列。
   *
   * - 按 finalizedAt 顺序逐条投递
   * - 投递成功后从队列移除
   * - 旧 turnId 不重复投递 (publishedTurnIds 已保证)
   * - handler 异常不阻塞后续投递
   *
   * 防递归: consuming 标志位
   */
  private async consumePending(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.consuming) {
      return;
    }
    if (this.avatarEndpoint === null) {
      return;
    }
    if (this.pendingResults.length === 0) {
      return;
    }
    this.consuming = true;
    try {
      while (this.pendingResults.length > 0
        && this.avatarEndpoint !== null
        && !this.disposed) {
        const result: ArkWebAvatarChatFinalResult = this.pendingResults[0];
        await this.deliverToAvatar(result);
        // 投递后无论成功失败都从队列移除 (避免阻塞后续)
        // 失败已记录到 lastErrorCode,不重复投递
        if (this.pendingResults.length > 0
          && this.pendingResults[0].turnId === result.turnId) {
          this.pendingResults.shift();
        }
      }
    } finally {
      this.consuming = false;
    }
  }

  /**
   * 投递结果到 Avatar endpoint handler。
   *
   * - handler 抛异常 → 记录 AVATAR_CHAT_DELIVERY_FAILED,不阻塞后续
   * - handler 内部负责调用 LifecycleController (不直接调用 PerformanceController)
   */
  private async deliverToAvatar(result: ArkWebAvatarChatFinalResult): Promise<void> {
    if (this.avatarEndpoint === null) {
      this.recordError(
        ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_ENDPOINT_MISSING,
        `turnId=${result.turnId} 无 avatar endpoint,入队等待`);
      return;
    }
    try {
      await this.avatarEndpoint.handler(result);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.recordError(
        ArkWebAvatarChatBridgeErrorCode.AVATAR_CHAT_DELIVERY_FAILED,
        `turnId=${result.turnId} handler 异常: ${msg}`);
    }
  }

  /** 重新计算状态。 */
  private refreshState(): void {
    if (this.disposed) {
      this.currentState = ArkWebAvatarChatBridgeState.DISPOSED;
      return;
    }
    const hasChat: boolean = this.chatEndpointIds.size > 0;
    const hasAvatar: boolean = this.avatarEndpoint !== null;
    if (hasChat && hasAvatar) {
      this.currentState = ArkWebAvatarChatBridgeState.CONNECTED;
    } else if (hasChat) {
      this.currentState = ArkWebAvatarChatBridgeState.CHAT_READY;
    } else if (hasAvatar) {
      this.currentState = ArkWebAvatarChatBridgeState.AVATAR_READY;
    } else {
      this.currentState = ArkWebAvatarChatBridgeState.DISCONNECTED;
    }
  }

  /** 记录错误 (覆盖式,只保留最新)。 */
  private recordError(code: string, message: string): void {
    this.lastErrorCode = code;
    this.lastErrorMessage = message;
    Logger.warn(`error code=${code} msg=${message}`);
  }

  /** 清除错误。 */
  private clearError(): void {
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
  }
}
