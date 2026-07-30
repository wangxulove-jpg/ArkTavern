/**
 * ArkWebAvatarDialogueRhythmPolicy — Avatar 对话演出节奏策略 (Phase 4C-2)
 *
 * 职责:
 *   - 实现固定策略 BALANCED_V1 的软决策逻辑
 *   - 判断是否建议跳过当前 avatar_perform (节奏限制)
 *   - 判断是否为相同活动演出 no-op (ACTIVE 且参数完全相同)
 *   - 提供策略版本和规则文本常量
 *
 * 不做的事:
 *   - 不强制阻止 AI 调用工具 (硬限制由 Executor 处理)
 *   - 不解析聊天正文判断是否需要演出
 *   - 不增加新的 Tool 参数
 *   - 不修改 Provider Tool Calling 协议
 *   - 不修改 VRM JavaScript Runtime
 *
 * 策略规则 (BALANCED_V1):
 *   1. 普通自动演出间隔: 至少间隔 1 个没有演出的助手 Turn
 *   2. 连续演出限制: consecutivePerformanceTurns >= 2 → 建议跳过
 *   3. 相同动作: 最近 3 次成功演出内重复 → 建议跳过 (除非用户明确要求, 但本策略不解析正文)
 *   4. 相同表情: 连续两个助手 Turn 重复 → 建议跳过
 *   5. 当前演出 ACTIVE 且新参数完全相同 → no-op (返回 success, 不重播)
 *   6. 当前演出 ACTIVE / TRANSITIONING / PLAYING 时: 建议保持, 不调用 avatar_perform
 *   7. 失败后: 最近一次失败为 CAPABILITY_NOT_FOUND → 建议跳过相同参数
 *
 * Reference:
 *   - AGENTS.md Phase 4C-2 §第二部分 演出节奏策略 / §第四部分 硬性安全约束
 */

import {
  ArkWebAvatarDialogueRhythmDecision,
  createEmptyRhythmDecision
} from './ArkWebAvatarDialogueSessionStateTypes';
import { ArkWebAvatarDialogueStateSnapshot } from './ArkWebAvatarDialogueSessionStateTypes';
import { ArkWebAvatarDialoguePerformanceRecord } from './ArkWebAvatarDialogueSessionStateTypes';

/**
 * 节奏策略版本标识 (固定 BALANCED_V1)。
 */
export const AVATAR_DIALOGUE_RHYTHM_POLICY_VERSION: string = 'BALANCED_V1';

/**
 * 节奏策略模式 (固定 BALANCED)。
 */
export const AVATAR_DIALOGUE_RHYTHM_POLICY_MODE: string = 'BALANCED';

/**
 * 最小自动演出间隔 (无演出的助手 Turn 数)。
 *
 * 普通自动演出后, 至少间隔 1 个没有演出的助手 Turn, 再考虑下一次自动演出。
 */
export const MIN_AUTOMATIC_PERFORMANCE_GAP: number = 1;

/**
 * 最大连续演出 Turn 数。
 *
 * consecutivePerformanceTurns >= 此值时, 下一 Turn 默认建议不调用 avatar_perform。
 */
export const MAX_CONSECUTIVE_PERFORMANCE_TURNS: number = 2;

/**
 * 相同动作重复检查窗口 (最近 N 次成功演出)。
 *
 * 相同 motionType + motionId 不要在最近 3 次成功演出中重复选择。
 */
export const SAME_MOTION_REPEAT_WINDOW: number = 3;

/**
 * Avatar 演出节奏策略 (BALANCED_V1)。
 *
 * 无状态, 可被多个 ChatPage 实例共享 (但本阶段每个 ChatPage 持有一个实例)。
 */
export class ArkWebAvatarDialogueRhythmPolicy {
  /**
   * 评估当前演出请求是否应跳过或 no-op。
   *
   * @param snapshot 当前会话状态快照
   * @param motionType 请求的 motionType (animation / pose / none)
   * @param motionId 请求的 motionId (可为空)
   * @param expressionId 请求的 expressionId (可为空)
   * @returns 决策结果 (suggestSkipPerform / isNoOp / 原因)
   */
  evaluate(
    snapshot: ArkWebAvatarDialogueStateSnapshot,
    motionType: string,
    motionId: string,
    expressionId: string
  ): ArkWebAvatarDialogueRhythmDecision {
    const decision: ArkWebAvatarDialogueRhythmDecision = createEmptyRhythmDecision();

    // 规则 5: 当前演出 ACTIVE 且新参数完全相同 → no-op
    if (this.isCurrentPerformanceActive(snapshot)
      && this.isSameParams(snapshot, motionType, motionId, expressionId)) {
      decision.isNoOp = true;
      decision.noOpReason = 'Avatar performance is already active with identical parameters.';
      return decision;
    }

    // 规则 6: 当前演出仍在进行 → 建议保持 (除非参数明显不同)
    if (this.isCurrentPerformanceActive(snapshot)
      && !this.isSameParams(snapshot, motionType, motionId, expressionId)) {
      // 当前演出 ACTIVE 但新参数不同: 不建议跳过 (允许替换)
      // 但若 recentPerformances 显示连续 2 个 Turn 都在替换演出, 建议跳过
      if (snapshot.consecutivePerformanceTurns >= MAX_CONSECUTIVE_PERFORMANCE_TURNS) {
        decision.suggestSkipPerform = true;
        decision.skipReason = `Consecutive performance turns (${snapshot.consecutivePerformanceTurns}) reached limit (${MAX_CONSECUTIVE_PERFORMANCE_TURNS}).`;
        return decision;
      }
      return decision;
    }

    // 规则 2: 连续演出限制
    if (snapshot.consecutivePerformanceTurns >= MAX_CONSECUTIVE_PERFORMANCE_TURNS) {
      decision.suggestSkipPerform = true;
      decision.skipReason = `Consecutive performance turns (${snapshot.consecutivePerformanceTurns}) reached limit (${MAX_CONSECUTIVE_PERFORMANCE_TURNS}).`;
      return decision;
    }

    // 规则 1: 普通自动演出间隔
    if (snapshot.turnsSinceLastPerformance < MIN_AUTOMATIC_PERFORMANCE_GAP
      && snapshot.turnsSinceLastPerformance >= 0
      && snapshot.lastSuccessfulPerformance !== null) {
      decision.suggestSkipPerform = true;
      decision.skipReason = `Minimum gap (${MIN_AUTOMATIC_PERFORMANCE_GAP}) not reached, turns since last performance=${snapshot.turnsSinceLastPerformance}.`;
      return decision;
    }

    // 规则 3: 相同动作最近 3 次成功演出内重复
    if (motionType !== 'none' && motionId.length > 0) {
      if (this.isMotionInRecentSuccesses(snapshot, motionType, motionId, SAME_MOTION_REPEAT_WINDOW)) {
        decision.suggestSkipPerform = true;
        decision.skipReason = `Same motion (${motionType}/${motionId}) appeared in recent ${SAME_MOTION_REPEAT_WINDOW} successful performances.`;
        return decision;
      }
    }

    // 规则 4: 相同表情连续两个助手 Turn 重复
    if (motionType === 'none' && expressionId.length > 0) {
      if (this.isExpressionRepeatedInLastTurn(snapshot, expressionId)) {
        decision.suggestSkipPerform = true;
        decision.skipReason = `Same expression (${expressionId}) repeated on consecutive assistant turns.`;
        return decision;
      }
      // 如果当前 Avatar 已保持该表情, 也不需要再次调用相同 expression-only 演出
      if (snapshot.currentExpressionId === expressionId
        && this.isCurrentPerformanceActive(snapshot)) {
        decision.isNoOp = true;
        decision.noOpReason = `Avatar already holds expression ${expressionId}.`;
        return decision;
      }
    }

    // 规则 7: 失败后策略 — 最近一次失败为 CAPABILITY_NOT_FOUND 且参数相同
    if (this.isLastFailureCapabilityNotFound(snapshot, motionType, motionId, expressionId)) {
      decision.suggestSkipPerform = true;
      decision.skipReason = 'Last failure was CAPABILITY_NOT_FOUND with same parameters; do not retry with same IDs.';
      return decision;
    }

    return decision;
  }

  /**
   * 获取策略版本。
   */
  getVersion(): string {
    return AVATAR_DIALOGUE_RHYTHM_POLICY_VERSION;
  }

  /**
   * 获取策略模式。
   */
  getMode(): string {
    return AVATAR_DIALOGUE_RHYTHM_POLICY_MODE;
  }

  // ===== 内部辅助 =====

  /**
   * 判断当前演出是否处于活动状态 (ACTIVE / TRANSITIONING / PLAYING)。
   */
  private isCurrentPerformanceActive(snapshot: ArkWebAvatarDialogueStateSnapshot): boolean {
    const state: string = snapshot.currentPerformanceState;
    return state === 'ACTIVE' || state === 'TRANSITIONING' || state === 'PLAYING';
  }

  /**
   * 判断请求参数与当前演出是否完全相同。
   */
  private isSameParams(
    snapshot: ArkWebAvatarDialogueStateSnapshot,
    motionType: string,
    motionId: string,
    expressionId: string
  ): boolean {
    return snapshot.currentMotionType === motionType
      && snapshot.currentMotionId === motionId
      && snapshot.currentExpressionId === expressionId;
  }

  /**
   * 判断指定 motion 是否出现在最近 N 次成功演出中。
   */
  private isMotionInRecentSuccesses(
    snapshot: ArkWebAvatarDialogueStateSnapshot,
    motionType: string,
    motionId: string,
    windowSize: number
  ): boolean {
    let count: number = 0;
    // 从最新到最旧遍历
    for (let i = snapshot.recentPerformances.length - 1; i >= 0; i--) {
      const rec: ArkWebAvatarDialoguePerformanceRecord = snapshot.recentPerformances[i];
      if (!rec.success) {
        continue;
      }
      if (rec.motionType === motionType && rec.motionId === motionId) {
        return true;
      }
      count++;
      if (count >= windowSize) {
        break;
      }
    }
    return false;
  }

  /**
   * 判断指定表情是否在最近一个助手 Turn 重复。
   */
  private isExpressionRepeatedInLastTurn(
    snapshot: ArkWebAvatarDialogueStateSnapshot,
    expressionId: string
  ): boolean {
    if (snapshot.recentPerformances.length === 0) {
      return false;
    }
    // 找到最近一次成功演出
    for (let i = snapshot.recentPerformances.length - 1; i >= 0; i--) {
      const rec: ArkWebAvatarDialoguePerformanceRecord = snapshot.recentPerformances[i];
      if (!rec.success) {
        continue;
      }
      // 如果最近一次成功演出是 expression-only 且 expressionId 相同
      if (rec.motionType === 'none' && rec.expressionId === expressionId) {
        return true;
      }
      // 如果最近一次成功演出包含表情且 expressionId 相同, 也视为重复
      if (rec.expressionId === expressionId && expressionId.length > 0) {
        return true;
      }
      // 找到最近一次成功演出就停止
      break;
    }
    return false;
  }

  /**
   * 判断最近一次失败是否为 CAPABILITY_NOT_FOUND 且参数相同。
   */
  private isLastFailureCapabilityNotFound(
    snapshot: ArkWebAvatarDialogueStateSnapshot,
    motionType: string,
    motionId: string,
    expressionId: string
  ): boolean {
    if (snapshot.recentPerformances.length === 0) {
      return false;
    }
    // 找到最近一次失败
    for (let i = snapshot.recentPerformances.length - 1; i >= 0; i--) {
      const rec: ArkWebAvatarDialoguePerformanceRecord = snapshot.recentPerformances[i];
      if (rec.success) {
        continue;
      }
      // 找到最近一次失败
      if (rec.errorCode === 'AVATAR_TOOL_CAPABILITY_NOT_FOUND'
        && rec.motionType === motionType
        && rec.motionId === motionId
        && rec.expressionId === expressionId) {
        return true;
      }
      // 找到最近一次失败就停止 (即使不是 CAPABILITY_NOT_FOUND)
      break;
    }
    return false;
  }
}
