/**
 * GroupRuntimeRegistry 多人聊天运行注册表(G-RUNTIME-1D)
 *
 * 职责:
 * - 应用级多人生成运行锁(整个应用同时最多一个多人轮次)
 * - 跨群聊隔离(群聊 A 运行时,群聊 B 无法启动新轮次)
 * - 业务 Service 层互斥校验(assertChatMutable)
 * - 迟到回调隔离辅助校验
 *
 * 不依赖:
 * - Page / ViewModel
 * - Repository / ModelService / Provider
 * - ArkUI
 *
 * 依赖方向:
 *   GroupRuntimeRegistry
 *     ↑
 *     ├── GroupChatRuntimeService(acquire / release / validate)
 *     ├── GroupConversationPersistenceService(assertChatMutable)
 *     └── GroupConversationMessageService(assertChatMutable)
 *
 * 日志规则:
 * - 不打印完整 Chat ID / Character ID / Message ID
 * - 只打印操作类别、状态、截断短 ID
 */

import { GroupRoundState } from './GroupRoundTypes';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'GroupRuntimeReg';

/**
 * 运行时快照(只读)。
 */
export interface GroupRuntimeSnapshot {
  readonly chatId: string;
  readonly roundId: string;
  readonly operationId: number;
  readonly state: GroupRoundState;
}

/**
 * 应用级多人聊天运行注册表。
 *
 * 单例,由 AppServices 持有,所有多人 Service 共享同一实例。
 *
 * 规则:
 * - 整个应用同时最多一个多人运行上下文
 * - 相同运行可以更新自己的状态(updateState)
 * - 不同 chatId 尝试 acquire 必须失败
 * - 不同 operationId 不得释放当前新运行
 *
 * 线程安全:
 * - ArkTS 单线程事件循环,无需锁
 * - 所有方法同步执行,无 async
 */
export class GroupRuntimeRegistry {
  private chatId: string = '';
  private roundId: string = '';
  private operationId: number = 0;
  private state: GroupRoundState = GroupRoundState.Idle;

  /**
   * 是否有任意群聊正在运行。
   */
  isAnyGroupRunning(): boolean {
    return this.operationId > 0;
  }

  /**
   * 指定群聊是否正在运行。
   */
  isChatRunning(chatId: string): boolean {
    return this.operationId > 0 && this.chatId === chatId;
  }

  /**
   * 获取当前运行的群聊 ID(无运行时为 undefined)。
   */
  getRunningChatId(): string | undefined {
    if (this.operationId > 0) {
      return this.chatId;
    }
    return undefined;
  }

  /**
   * 获取当前运行快照(无运行时为 undefined)。
   */
  getSnapshot(): GroupRuntimeSnapshot | undefined {
    if (this.operationId === 0) {
      return undefined;
    }
    return {
      chatId: this.chatId,
      roundId: this.roundId,
      operationId: this.operationId,
      state: this.state
    };
  }

  /**
   * 获取当前运行状态(无运行时为 Idle)。
   */
  getState(): GroupRoundState {
    if (this.operationId === 0) {
      return GroupRoundState.Idle;
    }
    return this.state;
  }

  /**
   * 获取当前运行的 operationId(无运行时为 0)。
   */
  getOperationId(): number {
    return this.operationId;
  }

  /**
   * 获取当前运行的 roundId(无运行时为空字符串)。
   */
  getRoundId(): string {
    return this.roundId;
  }

  /**
   * 获取当前运行的 chatId(无运行时为空字符串)。
   */
  getChatId(): string {
    return this.chatId;
  }

  /**
   * 获取运行上下文。
   * 用于 RuntimeService 校验回调是否属于当前运行。
   *
   * @returns 如果 operationId/chatId/roundId 匹配当前运行返回 true
   */
  isCurrentRun(chatId: string, roundId: string, operationId: number): boolean {
    return this.operationId > 0
      && this.operationId === operationId
      && this.chatId === chatId
      && this.roundId === roundId;
  }

  /**
   * 获取运行上下文(chatId + operationId 校验,不校验 roundId)。
   * 用于 release 等不需要 roundId 的场景。
   */
  isCurrentRunByOp(chatId: string, operationId: number): boolean {
    return this.operationId > 0
      && this.operationId === operationId
      && this.chatId === chatId;
  }

  /**
   * 占用运行锁。
   *
   * 规则:
   * - 如果当前无运行(operationId === 0):占用成功
   * - 如果当前运行属于同一 chatId 且同一 operationId:允许(幂等更新状态)
   * - 如果当前运行属于同一 chatId 但不同 operationId:抛错(旧运行未释放)
   * - 如果当前运行属于不同 chatId:抛错(跨群聊冲突)
   *
   * @param chatId 群聊 ID
   * @param roundId 轮次 ID
   * @param operationId 操作 ID(必须 > 0)
   * @param state 初始状态
   * @throws Error 如果另一个群聊正在运行或旧运行未释放
   */
  acquire(
    chatId: string,
    roundId: string,
    operationId: number,
    state: GroupRoundState
  ): void {
    if (chatId.length === 0) {
      throw new Error('GroupRuntimeRegistry.acquire: chatId empty');
    }
    if (operationId <= 0) {
      throw new Error('GroupRuntimeRegistry.acquire: operationId <= 0');
    }
    if (this.operationId > 0) {
      // 已有运行:检查是否同一 chatId + 同一 operationId(幂等更新)
      if (this.chatId !== chatId) {
        throw new Error('GroupRuntimeRegistry.acquire: another group chat is running');
      }
      if (this.operationId !== operationId) {
        throw new Error('GroupRuntimeRegistry.acquire: old run not released');
      }
      // 幂等更新状态
      this.state = state;
      Logger.info(LOG_TAG, 'acquire update opId=' + String(operationId)
        + ' state=' + state);
      return;
    }
    // 无运行:占用
    this.chatId = chatId;
    this.roundId = roundId;
    this.operationId = operationId;
    this.state = state;
    Logger.info(LOG_TAG, 'acquire ok opId=' + String(operationId)
      + ' state=' + state);
  }

  /**
   * 释放运行锁。
   *
   * 规则:
   * - chatId 和 operationId 必须匹配当前运行
   * - 旧 operationId 不得释放新运行
   * - 无运行时调用为 no-op
   *
   * @param chatId 群聊 ID
   * @param operationId 操作 ID
   */
  release(chatId: string, operationId: number): void {
    if (this.operationId === 0) {
      // 无运行,no-op
      return;
    }
    if (this.chatId !== chatId || this.operationId !== operationId) {
      // 不匹配:迟到释放,拒绝
      Logger.warn(LOG_TAG, 'release rejected: mismatch'
        + ' curOp=' + String(this.operationId)
        + ' reqOp=' + String(operationId));
      return;
    }
    Logger.info(LOG_TAG, 'release ok opId=' + String(operationId)
      + ' state=' + this.state);
    this.chatId = '';
    this.roundId = '';
    this.operationId = 0;
    this.state = GroupRoundState.Idle;
  }

  /**
   * 更新当前运行状态(不改变 operationId/chatId/roundId)。
   *
   * 用于 RuntimeService 在轮次推进时同步状态到 Registry。
   *
   * @param chatId 群聊 ID(校验)
   * @param operationId 操作 ID(校验)
   * @param state 新状态
   */
  updateState(
    chatId: string,
    operationId: number,
    state: GroupRoundState
  ): void {
    if (this.operationId === 0) {
      return;
    }
    if (this.chatId !== chatId || this.operationId !== operationId) {
      return;
    }
    this.state = state;
  }

  /**
   * 断言指定群聊当前可变(未在运行中)。
   *
   * 用于业务 Service 层互斥:
   * - replaceParticipantOrder
   * - setParticipantEnabled
   * - addParticipant
   * - removeParticipant
   * - deleteGroupConversation
   * - clearMessages
   *
   * 运行时内部消息写入(appendStreamingAssistantMessage / finalize 等)
   * 不调用此方法。
   *
   * @param chatId 群聊 ID
   * @throws Error 如果该群聊正在运行
   */
  assertChatMutable(chatId: string): void {
    if (chatId.length === 0) {
      return;
    }
    if (this.operationId > 0 && this.chatId === chatId) {
      throw new Error('当前多人聊天正在回复,请先停止本轮');
    }
  }

  /**
   * 强制清理(仅用于页面销毁 / 应用重置)。
   * 不校验 operationId,直接清空。
   */
  forceClear(): void {
    if (this.operationId > 0) {
      Logger.warn(LOG_TAG, 'forceClear opId=' + String(this.operationId));
    }
    this.chatId = '';
    this.roundId = '';
    this.operationId = 0;
    this.state = GroupRoundState.Idle;
  }
}
