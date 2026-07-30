/**
 * ArkWebAvatarDialogueSessionStateTypes — Avatar 对话演出会话状态类型 (Phase 4C-2)
 *
 * 职责:
 *   - 定义当前 ChatPage 生命周期内的 Avatar 演出会话状态类型
 *   - 定义演出历史记录与状态快照
 *   - 定义节奏策略决策输入
 *
 * 安全约束:
 *   - 会话状态只在当前 ChatPage 生命周期内保留, 不写入数据库 / Preferences / 角色卡 / 聊天消息
 *   - 状态摘要不包含路径 / URL / resourceId / generation / 相机坐标 / Debug 堆栈
 *   - 演出记录必须关联真实 chatTurnId + toolCallId, 不允许只用时间戳作为 Turn 标识
 *   - 手动 AI 面板操作 (CHAT_AI_PANEL) 不计入自动演出节奏历史
 *
 * Reference:
 *   - AGENTS.md Phase 4C-2 §第一部分 会话级演出状态 / §状态范围 / §Turn 计数
 */

// ===== 限制常量 =====

/**
 * 会话演出历史最大保留条数。
 *
 * 成功和失败均可记录, 超过上限时删除最旧记录。
 * 固定 8 条, 不写入数据库。
 */
export const AVATAR_DIALOGUE_SESSION_HISTORY_LIMIT: number = 8;

/**
 * 会话状态摘要最大长度 (字符)。
 *
 * 超过时优先保留: 当前状态 / 最后一次成功演出 / 最后一次失败 / 最近 3 条记录,
 * 然后截断更早记录。
 */
export const AVATAR_DIALOGUE_STATE_SUMMARY_MAX_LENGTH: number = 4096;

// ===== 演出来源 =====

/**
 * 演出触发来源标识。
 *
 * - AI_TOOL_CALL: AI 原生 Tool Calling 触发 (计入自动演出节奏)
 * - CHAT_AI_PANEL: 用户通过 AI 面板手动点击 (不计入自动演出节奏)
 * - SINGLE_CHAT: 真实聊天最终消息携带 performanceHintJson (计入自动演出节奏)
 *
 * 只有 AI_TOOL_CALL 和 SINGLE_CHAT 计入自动演出历史。
 * CHAT_AI_PANEL 来源的演出不计入节奏统计, 不写入 recentPerformances。
 */
export type ArkWebAvatarDialoguePerformanceSource =
  'AI_TOOL_CALL'
  | 'CHAT_AI_PANEL'
  | 'SINGLE_CHAT';

/**
 * 演出来源常量 (用于字符串比较)。
 */
export class ArkWebAvatarDialoguePerformanceSourceConst {
  static readonly AI_TOOL_CALL: string = 'AI_TOOL_CALL';
  static readonly CHAT_AI_PANEL: string = 'CHAT_AI_PANEL';
  static readonly SINGLE_CHAT: string = 'SINGLE_CHAT';
}

// ===== 演出记录 =====

/**
 * 单次 Avatar 演出记录。
 *
 * 在真实 Lifecycle 执行完成后写入 (不是 Bridge accepted, 也不是 Provider 返回 tool call)。
 *
 * 字段约束:
 *   - chatTurnId: 真实对话轮次 ID (assistantMessageId 或 avatar_tool_<chatTurnId>_<toolCallId>)
 *   - toolCallId: 工具调用 ID (Provider 分配, 手动面板操作使用 'panel-<timestamp>')
 *   - commandId: Lifecycle 映射后的 commandId
 *   - motionType / motionId / expressionId: 业务字段, 不含路径 / URL
 *   - success: 真实执行结果 (Lifecycle.executePerformance 返回值)
 *   - errorCode: 失败时的错误码
 *   - assistantTurnIndex: 关联的助手 Turn 序号 (从 1 开始)
 *   - executedAt: 执行完成时间戳
 */
export interface ArkWebAvatarDialoguePerformanceRecord {
  chatTurnId: string;
  toolCallId: string;
  commandId: string;

  motionType: string;
  motionId: string;
  expressionId: string;

  success: boolean;
  errorCode: string;

  assistantTurnIndex: number;
  executedAt: number;

  /** 演出来源 (AI_TOOL_CALL / CHAT_AI_PANEL / SINGLE_CHAT) */
  source: string;
}

// ===== 状态快照 =====

/**
 * Avatar 对话演出会话状态快照。
 *
 * 由 SessionState 维护, 注入到策略 Builder 用于构建状态感知上下文。
 *
 * 字段说明:
 *   - assistantTurnIndex: 当前助手 Turn 序号 (流式 token / tool result 中间轮次不增加)
 *   - currentPerformanceState: IDLE / ACTIVE / TRANSITIONING / FAILED 等
 *   - currentMotionType / currentMotionId / currentExpressionId: 当前演出业务字段
 *   - lastSuccessfulPerformance: 最近一次成功演出记录 (null 表示尚无成功演出)
 *   - recentPerformances: 最近演出记录 (最多 8 条, 含成功和失败)
 *   - consecutivePerformanceTurns: 连续演出 Turn 数 (无演出 Turn 重置为 0)
 *   - turnsSinceLastPerformance: 距上次演出的 Turn 数
 */
export interface ArkWebAvatarDialogueStateSnapshot {
  assistantTurnIndex: number;

  currentPerformanceState: string;
  currentMotionType: string;
  currentMotionId: string;
  currentExpressionId: string;

  lastSuccessfulPerformance: ArkWebAvatarDialoguePerformanceRecord | null;
  recentPerformances: ArkWebAvatarDialoguePerformanceRecord[];

  consecutivePerformanceTurns: number;
  turnsSinceLastPerformance: number;
}

// ===== 节奏策略决策 =====

/**
 * 节奏策略决策结果。
 *
 * 由 RhythmPolicy.evaluate 返回, 用于:
 *   - 判断是否跳过当前 avatar_perform (no-op 保护)
 *   - 提供 Builder 注入的状态摘要
 *
 * 本策略是软决策, 不强制阻止 AI 调用工具 (硬限制由 Executor 处理)。
 */
export interface ArkWebAvatarDialogueRhythmDecision {
  /** 当前 Turn 是否建议跳过 avatar_perform (节奏限制) */
  suggestSkipPerform: boolean;
  /** 跳过原因 (空字符串表示无建议) */
  skipReason: string;
  /** 相同演出 no-op 保护 (当前 ACTIVE 且参数完全相同) */
  isNoOp: boolean;
  /** no-op 原因 */
  noOpReason: string;
}

/**
 * 空决策 (无任何建议)。
 */
export function createEmptyRhythmDecision(): ArkWebAvatarDialogueRhythmDecision {
  return {
    suggestSkipPerform: false,
    skipReason: '',
    isNoOp: false,
    noOpReason: ''
  };
}
