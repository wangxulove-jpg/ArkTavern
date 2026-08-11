import { Logger } from '../utils/Logger';
/**
 * ArkWebAvatarDialogueSessionState — Avatar 对话演出会话状态管理 (Phase 4C-2)
 *
 * 职责:
 *   - 维护当前 ChatPage 生命周期内的 Avatar 演出历史和当前状态
 *   - 在真实 Lifecycle 执行完成后写入演出记录 (Bridge accepted 不等于成功)
 *   - 在助手最终回复完成时递增 assistantTurnIndex (流式 token / tool result 中间轮次不递增)
 *   - 生成状态快照供策略 Builder 注入到 system message
 *   - 生成简洁节奏状态供 AI 面板显示
 *   - 手动 AI 面板操作 (CHAT_AI_PANEL) 不计入自动演出节奏
 *
 * 不做的事:
 *   - 不写入数据库 / Preferences / 角色卡 / 聊天消息
 *   - 不解析聊天正文判断是否需要演出
 *   - 不强制阻止 AI 调用工具 (硬限制由 Executor 处理)
 *   - 不暴露路径 / URL / resourceId / generation / 相机坐标 / Debug 堆栈
 *
 * 生命周期:
 *   - ChatPage aboutToAppear → 创建 SessionState
 *   - 助手最终回复完成 → incrementAssistantTurn()
 *   - avatar_perform 真实执行完成 → recordPerformance()
 *   - avatar_stop 真实执行完成 → recordStop()
 *   - 策略 Builder → getSnapshot()
 *   - AI 面板 → getRhythmStatusText()
 *   - ChatPage aboutToDisappear → dispose()
 *
 * Reference:
 *   - AGENTS.md Phase 4C-2 §第一部分 / §Turn 计数 / §第五部分 Tool Executor 状态回写
 */

import {
  AVATAR_DIALOGUE_SESSION_HISTORY_LIMIT,
  AVATAR_DIALOGUE_STATE_SUMMARY_MAX_LENGTH,
  ArkWebAvatarDialoguePerformanceSourceConst,
  ArkWebAvatarDialoguePerformanceRecord,
  ArkWebAvatarDialogueStateSnapshot
} from './ArkWebAvatarDialogueSessionStateTypes';

/**
 * Avatar 对话演出会话状态。
 *
 * 每个 ChatPage 实例持有一个 SessionState, 页面退出时 dispose。
 * 状态只在内存中, 不持久化。
 */
export class ArkWebAvatarDialogueSessionState {
  /** 当前助手 Turn 序号 (从 0 开始, 完成第一次最终回复后变为 1) */
  private assistantTurnIndex: number = 0;

  /** 当前 Avatar 业务状态 (IDLE / ACTIVE / TRANSITIONING / FAILED) */
  private currentPerformanceState: string = 'IDLE';

  /** 当前演出业务字段 (motionType / motionId / expressionId) */
  private currentMotionType: string = 'none';
  private currentMotionId: string = '';
  private currentExpressionId: string = '';

  /** 最近演出记录 (按时间升序, 最多 8 条, 含成功和失败) */
  private recentPerformances: ArkWebAvatarDialoguePerformanceRecord[] = [];

  /** 最近一次成功演出 (null 表示尚无成功演出) */
  private lastSuccessfulPerformance: ArkWebAvatarDialoguePerformanceRecord | null = null;

  /** 连续演出 Turn 数 (无演出 Turn 重置为 0) */
  private consecutivePerformanceTurns: number = 0;

  /** 距上次演出的 Turn 数 (每完成一个助手 Turn +1, 演出时重置为 0) */
  private turnsSinceLastPerformance: number = 0;

  /** 当前 Turn 是否已记录演出 (用于在 incrementAssistantTurn 时判断是否连续演出) */
  private currentTurnHasPerformance: boolean = false;

  /** 是否已销毁 */
  private disposed: boolean = false;

  // ===== Turn 计数 =====

  /**
   * 递增助手 Turn 序号。
   *
   * 调用时机:
   *   - 真实助手最终回复完成 (ChatService.finalizeAssistantTurn)
   *   - 重新生成产生新的最终助手回复
   *
   * 不调用:
   *   - 流式 token 到达
   *   - Tool result 中间轮次
   *
   * 副作用:
   *   - assistantTurnIndex++
   *   - 如果当前 Turn 没有演出, consecutivePerformanceTurns 重置为 0
   *   - 如果当前 Turn 没有演出, turnsSinceLastPerformance++
   *   - 重置 currentTurnHasPerformance
   */
  incrementAssistantTurn(): void {
    if (this.disposed) {
      return;
    }
    this.assistantTurnIndex++;
    if (!this.currentTurnHasPerformance) {
      this.consecutivePerformanceTurns = 0;
      this.turnsSinceLastPerformance++;
    }
    this.currentTurnHasPerformance = false;
  }

  /**
   * 获取当前助手 Turn 序号。
   */
  getAssistantTurnIndex(): number {
    return this.assistantTurnIndex;
  }

  // ===== 演出记录 =====

  /**
   * 记录一次演出执行结果。
   *
   * 调用时机:
   *   - avatar_perform 真实执行成功后 (Lifecycle.executePerformance 返回 true)
   *   - avatar_perform 真实执行失败后 (Lifecycle.executePerformance 返回 false 或抛出)
   *
   * 不调用:
   *   - Provider 返回 tool call 时
   *   - 参数验证通过时
   *   - Bridge accepted 时
   *
   * CHAT_AI_PANEL 来源的演出:
   *   - 不写入 recentPerformances
   *   - 不影响 consecutivePerformanceTurns / turnsSinceLastPerformance
   *   - 仍更新当前状态字段 (currentPerformanceState 等)
   *
   * @param record 演出记录 (含 chatTurnId / toolCallId / commandId / motionType / ... / source)
   */
  recordPerformance(record: ArkWebAvatarDialoguePerformanceRecord): void {
    if (this.disposed) {
      return;
    }

    // 更新当前状态字段 (无论来源)
    this.currentMotionType = record.motionType;
    this.currentMotionId = record.motionId;
    this.currentExpressionId = record.expressionId;
    this.currentPerformanceState = record.success ? 'ACTIVE' : 'FAILED';

    // 手动 AI 面板操作不计入自动演出节奏
    if (record.source === ArkWebAvatarDialoguePerformanceSourceConst.CHAT_AI_PANEL) {
      Logger.debug(`recordPerformance: skip rhythm update for CHAT_AI_PANEL source, toolCallId=${record.toolCallId}`);
      return;
    }

    // 写入历史记录 (成功和失败均记录)
    this.recentPerformances.push(record);
    while (this.recentPerformances.length > AVATAR_DIALOGUE_SESSION_HISTORY_LIMIT) {
      this.recentPerformances.shift();
    }

    // 更新 lastSuccessfulPerformance
    if (record.success) {
      this.lastSuccessfulPerformance = record;
    }

    // 更新节奏统计
    if (!this.currentTurnHasPerformance) {
      this.consecutivePerformanceTurns++;
      this.turnsSinceLastPerformance = 0;
      this.currentTurnHasPerformance = true;
    }
  }

  /**
   * 记录 avatar_stop 执行结果。
   *
   * 调用时机:
   *   - avatar_stop 真实执行成功后
   *
   * stop 不计为一次角色演出 (不写入 recentPerformances),
   * 但重置当前状态字段为 IDLE。
   *
   * @param success 是否停止成功
   * @param source 演出来源
   */
  recordStop(success: boolean, source: string): void {
    if (this.disposed) {
      return;
    }
    if (success) {
      this.currentPerformanceState = 'IDLE';
      this.currentMotionType = 'none';
      this.currentMotionId = '';
      this.currentExpressionId = '';
    }
    // stop 不写入 recentPerformances, 不影响 consecutivePerformanceTurns
    Logger.debug(`recordStop: success=${success} source=${source}`);
  }

  // ===== 当前状态更新 =====

  /**
   * 更新当前 Avatar 业务状态 (由 Tool Executor 在执行前调用)。
   *
   * 用于在 avatar_perform 执行前刷新当前状态, 避免策略基于过期状态判断。
   *
   * @param state 当前业务状态 (IDLE / ACTIVE / TRANSITIONING / FAILED)
   * @param motionType 当前 motionType
   * @param motionId 当前 motionId
   * @param expressionId 当前 expressionId
   */
  updateCurrentState(
    state: string,
    motionType: string,
    motionId: string,
    expressionId: string
  ): void {
    if (this.disposed) {
      return;
    }
    this.currentPerformanceState = state;
    this.currentMotionType = motionType;
    this.currentMotionId = motionId;
    this.currentExpressionId = expressionId;
  }

  // ===== 状态快照 =====

  /**
   * 获取当前状态快照 (供策略 Builder 注入)。
   *
   * 返回的快照是只读视图, 修改快照不影响内部状态。
   */
  getSnapshot(): ArkWebAvatarDialogueStateSnapshot {
    const recentCopy: ArkWebAvatarDialoguePerformanceRecord[] = [];
    for (let i = 0; i < this.recentPerformances.length; i++) {
      recentCopy.push(this.copyRecord(this.recentPerformances[i]));
    }
    return {
      assistantTurnIndex: this.assistantTurnIndex,
      currentPerformanceState: this.currentPerformanceState,
      currentMotionType: this.currentMotionType,
      currentMotionId: this.currentMotionId,
      currentExpressionId: this.currentExpressionId,
      lastSuccessfulPerformance: this.lastSuccessfulPerformance !== null
        ? this.copyRecord(this.lastSuccessfulPerformance) : null,
      recentPerformances: recentCopy,
      consecutivePerformanceTurns: this.consecutivePerformanceTurns,
      turnsSinceLastPerformance: this.turnsSinceLastPerformance
    };
  }

  /**
   * 生成简洁节奏状态文本 (供 AI 面板显示)。
   *
   * 格式:
   *   助手轮次：12
   *   距上次演出：2 轮
   *   连续演出：0
   *   最近演出：Wave
   */
  getRhythmStatusText(): string {
    const lines: string[] = [];
    lines.push(`助手轮次：${this.assistantTurnIndex}`);
    lines.push(`距上次演出：${this.turnsSinceLastPerformance} 轮`);
    lines.push(`连续演出：${this.consecutivePerformanceTurns}`);
    if (this.lastSuccessfulPerformance !== null) {
      const motionDesc: string = this.describeMotion(this.lastSuccessfulPerformance);
      lines.push(`最近演出：${motionDesc}`);
    } else {
      lines.push('最近演出：-');
    }
    return lines.join('\n');
  }

  // ===== 状态摘要 (注入策略) =====

  /**
   * 生成状态摘要 (供策略 Builder 注入到 system message)。
   *
   * 格式:
   *   [AVATAR_SESSION_STATE]
   *
   *   Assistant turn:
   *   12
   *
   *   Current performance:
   *   ACTIVE
   *
   *   Current motion:
   *   animation / action_wave
   *
   *   Current expression:
   *   happy
   *
   *   Turns since last performance:
   *   2
   *
   *   Recent successful performances:
   *   - Turn 10: animation action_wave + happy
   *   - Turn 7: expression sad
   *
   *   Recent failures:
   *   - Turn 11: action_unknown / CAPABILITY_NOT_FOUND
   *
   *   [/AVATAR_SESSION_STATE]
   *
   * 长度限制: 4096 字符, 超过时优先保留当前状态 / 最后一次成功 / 最后一次失败 / 最近 3 条,
   * 然后截断更早记录。
   */
  buildStateSummary(): string {
    const lines: string[] = [];
    lines.push('[AVATAR_SESSION_STATE]');
    lines.push('');
    lines.push('Assistant turn:');
    lines.push(`${this.assistantTurnIndex}`);
    lines.push('');
    lines.push('Current performance:');
    lines.push(this.currentPerformanceState);
    lines.push('');
    lines.push('Current motion:');
    if (this.currentMotionType === 'none' || this.currentMotionId.length === 0) {
      if (this.currentExpressionId.length > 0) {
        lines.push(`expression / ${this.currentExpressionId}`);
      } else {
        lines.push('none / -');
      }
    } else {
      const exprSuffix: string = this.currentExpressionId.length > 0
        ? ` + ${this.currentExpressionId}` : '';
      lines.push(`${this.currentMotionType} / ${this.currentMotionId}${exprSuffix}`);
    }
    lines.push('');
    lines.push('Current expression:');
    lines.push(this.currentExpressionId.length > 0 ? this.currentExpressionId : '-');
    lines.push('');
    lines.push('Turns since last performance:');
    lines.push(`${this.turnsSinceLastPerformance}`);
    lines.push('');
    lines.push('Consecutive performance turns:');
    lines.push(`${this.consecutivePerformanceTurns}`);
    lines.push('');

    // 最近成功演出
    lines.push('Recent successful performances:');
    const successRecords: ArkWebAvatarDialoguePerformanceRecord[] = [];
    for (let i = this.recentPerformances.length - 1; i >= 0; i--) {
      if (this.recentPerformances[i].success) {
        successRecords.push(this.recentPerformances[i]);
        if (successRecords.length >= 3) {
          break;
        }
      }
    }
    if (successRecords.length === 0) {
      lines.push('- (none)');
    } else {
      // 按 Turn 升序输出
      for (let i = successRecords.length - 1; i >= 0; i--) {
        lines.push(`- Turn ${successRecords[i].assistantTurnIndex}: ${this.describeMotion(successRecords[i])}`);
      }
    }
    lines.push('');

    // 最近失败
    lines.push('Recent failures:');
    const failureRecords: ArkWebAvatarDialoguePerformanceRecord[] = [];
    for (let i = this.recentPerformances.length - 1; i >= 0; i--) {
      if (!this.recentPerformances[i].success) {
        failureRecords.push(this.recentPerformances[i]);
        if (failureRecords.length >= 2) {
          break;
        }
      }
    }
    if (failureRecords.length === 0) {
      lines.push('- (none)');
    } else {
      for (let i = failureRecords.length - 1; i >= 0; i--) {
        const rec: ArkWebAvatarDialoguePerformanceRecord = failureRecords[i];
        const motionDesc: string = rec.motionType === 'none'
          ? (rec.expressionId.length > 0 ? `expression ${rec.expressionId}` : 'none')
          : `${rec.motionType} ${rec.motionId}`;
        lines.push(`- Turn ${rec.assistantTurnIndex}: ${motionDesc} / ${rec.errorCode}`);
      }
    }
    lines.push('');
    lines.push('[/AVATAR_SESSION_STATE]');

    let summary: string = lines.join('\n');
    if (summary.length > AVATAR_DIALOGUE_STATE_SUMMARY_MAX_LENGTH) {
      // 超长时优先保留头部 (当前状态) 和尾部 (最近记录)
      // 简单截断策略: 保留前 2048 + 后 2048 - 100 (省略号)
      const headLen: number = 2048;
      const tailLen: number = AVATAR_DIALOGUE_STATE_SUMMARY_MAX_LENGTH - headLen - 100;
      summary = summary.substring(0, headLen)
        + '\n...[truncated]...\n'
        + summary.substring(summary.length - tailLen);
    }
    return summary;
  }

  // ===== 内部辅助 =====

  private copyRecord(src: ArkWebAvatarDialoguePerformanceRecord): ArkWebAvatarDialoguePerformanceRecord {
    return {
      chatTurnId: src.chatTurnId,
      toolCallId: src.toolCallId,
      commandId: src.commandId,
      motionType: src.motionType,
      motionId: src.motionId,
      expressionId: src.expressionId,
      success: src.success,
      errorCode: src.errorCode,
      assistantTurnIndex: src.assistantTurnIndex,
      executedAt: src.executedAt,
      source: src.source
    };
  }

  /**
   * 描述演出记录 (用于摘要和 UI 显示)。
   * 不包含路径 / URL / resourceId。
   */
  private describeMotion(record: ArkWebAvatarDialoguePerformanceRecord): string {
    if (record.motionType === 'none') {
      if (record.expressionId.length > 0) {
        return `expression ${record.expressionId}`;
      }
      return 'none';
    }
    const exprSuffix: string = record.expressionId.length > 0
      ? ` + ${record.expressionId}` : '';
    return `${record.motionType} ${record.motionId}${exprSuffix}`;
  }

  // ===== 销毁 =====

  /**
   * 销毁 (清空所有状态)。
   *
   * 页面 aboutToDisappear 时调用。
   * 不停止当前演出 (由 Stage 控制器负责)。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.recentPerformances = [];
    this.lastSuccessfulPerformance = null;
    this.assistantTurnIndex = 0;
    this.consecutivePerformanceTurns = 0;
    this.turnsSinceLastPerformance = 0;
    this.currentTurnHasPerformance = false;
    this.currentPerformanceState = 'IDLE';
    this.currentMotionType = 'none';
    this.currentMotionId = '';
    this.currentExpressionId = '';
    Logger.debug('dispose, session state cleared');
  }
}
