/**
 * ArkWebAvatarTurnResponseTypes — Phase 4D-1
 *
 * 逐轮 Avatar 回应协调器类型定义。
 *
 * 职责:
 *   - 定义 ArkWebAvatarFinalTurn 输入类型
 *   - 定义 ArkWebAvatarTurnResponseSource 回应来源
 *   - 定义 ArkWebAvatarTurnResponseResult 回应结果
 *   - 定义 ArkWebAvatarTurnResponseConfig 配置
 *
 * 设计原则:
 *   - 每个助手最终 Turn 最多选择一个主要回应来源
 *   - 优先级: NATIVE_TOOL > STRUCTURED_HINT > LOCAL_FALLBACK > NONE
 *   - 同一 turnId 去重 (最多 64 个缓存)
 *   - 本地兜底保持当前镜头, 不强制脸部特写
 *   - Native Tool 即使执行失败也视为该 Turn 已选择 Native Tool 路径
 */

/**
 * 助手最终 Turn 输入 (由 ChatService.finalizeAssistantTurn 构造)。
 */
export interface ArkWebAvatarFinalTurn {
  /** 对话轮次 ID (来自真实 assistantMessageId, 稳定) */
  turnId: string;
  /** 消息完成时间戳 (ms) */
  finalizedAt: number;

  /**
   * 本轮是否尝试过原生 Avatar Tool Calling。
   * true 表示 Provider 返回了结构化 tool_calls 且包含 Avatar 工具。
   * 即使执行失败也为 true (已选择 Native Tool 路径)。
   */
  nativeAvatarToolAttempted: boolean;
  /**
   * 本轮原生 Avatar Tool Calling 是否真实执行成功。
   * true 表示工具执行器返回成功 (不等同于演出可见)。
   */
  nativeAvatarToolExecuted: boolean;

  /**
   * Provider 返回的结构化 performanceHintJson (可为空字符串)。
   * 仅在 nativeAvatarToolAttempted=false 时参与选择。
   */
  performanceHintJson: string;
  /** 发布来源标识 (SINGLE_CHAT / CHAT_AI_PANEL 等) */
  source: string;
}

/**
 * 回应来源类型。
 *
 * 优先级 (高 → 低):
 *   1. NATIVE_TOOL: 原生 AI Tool Calling 产生的 avatar_perform
 *   2. STRUCTURED_HINT: Provider 返回的独立结构化 performanceHintJson
 *   3. LOCAL_FALLBACK: 本地安全兜底回应
 *   4. NONE: 不产生回应 (例如每轮回应关闭)
 */
export type ArkWebAvatarTurnResponseSource =
  | 'NATIVE_TOOL'
  | 'STRUCTURED_HINT'
  | 'LOCAL_FALLBACK'
  | 'NONE';

/**
 * 回应强度等级。
 *
 * - LIGHT: 本地兜底, 轻量表情或默认姿势微回应
 * - NORMAL: 结构化 Hint, 正常演出
 * - EMPHATIC: Native Tool, 由现有命令决定
 */
export type ArkWebAvatarTurnResponseIntensity =
  | 'LIGHT'
  | 'NORMAL'
  | 'EMPHATIC';

/**
 * 逐轮回应结果。
 */
export interface ArkWebAvatarTurnResponseResult {
  /** 对话轮次 ID */
  turnId: string;
  /** 选择的回应来源 */
  responseSource: ArkWebAvatarTurnResponseSource;
  /** 回应强度 */
  intensity: ArkWebAvatarTurnResponseIntensity;
  /** 是否已提交到 Bridge/Lifecycle (true=已提交, false=被去重或关闭) */
  submitted: boolean;
  /** 提交时间戳 (ms) */
  submittedAt: number;
  /** Bridge/Lifecycle 是否接受 (true=接受, false=拒绝) */
  accepted: boolean;
  /** 真实执行结果 (accepted=true 时由 Lifecycle 回填) */
  executed: boolean;
  /** 命令 ID (由 Lifecycle 生成) */
  commandId: string;
  /** Lifecycle 状态 */
  lifecycleState: string;
  /** 动作类型 (animation / pose / expression / none) */
  motionType: string;
  /** 动作 ID */
  motionId: string;
  /** 表情 ID */
  expressionId: string;
  /** 错误码 */
  errorCode: string;
  /** 错误消息 */
  errorMessage: string;
}

/**
 * 本地兜底配置 (由 AI 面板设置)。
 */
export interface ArkWebAvatarLocalFallbackConfig {
  /** 每轮 Avatar 回应开关 (默认 true) */
  everyTurnResponseEnabled: boolean;
  /** 默认回应动作 ID (CapabilityCatalog 中真实 actionId, 可为空字符串) */
  defaultResponseAnimationId: string;
  /** 默认回应表情 ID (neutral/happy/relaxed 或空字符串) */
  defaultResponseExpressionId: string;
}

/**
 * 本地兜底默认配置常量。
 */
export const DEFAULT_LOCAL_FALLBACK_CONFIG: ArkWebAvatarLocalFallbackConfig = {
  everyTurnResponseEnabled: true,
  defaultResponseAnimationId: '',
  defaultResponseExpressionId: 'relaxed'
};

/**
 * 已处理 Turn 缓存上限。
 *
 * 超过上限删除最旧记录 (LRU)。
 */
export const TURN_RESPONSE_CACHE_LIMIT: number = 64;

/**
 * 本地兜底演出命令结构 (用于 JSON 序列化)。
 *
 * ArkTS 要求对象字面量必须对应到显式声明的 class 或 interface,
 * 因此定义此 interface 替代 Record<string, Object>。
 */
export interface ArkWebAvatarLocalFallbackCommand {
  version: number;
  motionType: string;
  motionId: string;
  expressionId: string;
  expressionWeight: number;
  durationMs: number;
  returnPolicy: string;
}

/**
 * 本地兜底演出命令: 仅表情 (轻量, 保持镜头)。
 */
const LOCAL_FALLBACK_EXPRESSION_ONLY_CMD: ArkWebAvatarLocalFallbackCommand = {
  version: 1,
  motionType: 'none',
  motionId: '',
  expressionId: 'relaxed',
  expressionWeight: 0.7,
  durationMs: 1800,
  returnPolicy: 'KEEP'
};
export const LOCAL_FALLBACK_EXPRESSION_ONLY_COMMAND: string = JSON.stringify(LOCAL_FALLBACK_EXPRESSION_ONLY_CMD);

/**
 * 本地兜底演出命令: 默认动作 + 可选表情。
 */
export function buildLocalFallbackAnimationCommand(
  animationId: string,
  expressionId: string
): string {
  const cmd: ArkWebAvatarLocalFallbackCommand = {
    version: 1,
    motionType: 'animation',
    motionId: animationId,
    expressionId: expressionId,
    expressionWeight: 1,
    durationMs: 2500,
    returnPolicy: 'DEFAULT_POSE'
  };
  return JSON.stringify(cmd);
}

/**
 * 本地兜底演出命令: 恢复默认姿势 (最轻量, 不重新加载模型)。
 *
 * 使用 neutral 表情 + DEFAULT_POSE returnPolicy:
 *   - expressionId='neutral' 保证 Mapper 接受 (motionType=none + expressionId 非空)
 *   - expressionWeight=0.3 轻量中性回应
 *   - returnPolicy=DEFAULT_POSE 在表情到期后恢复默认姿势
 *   - durationMs=1200 短持续时间
 */
const LOCAL_FALLBACK_DEFAULT_POSE_CMD: ArkWebAvatarLocalFallbackCommand = {
  version: 1,
  motionType: 'none',
  motionId: '',
  expressionId: 'neutral',
  expressionWeight: 0.3,
  durationMs: 1200,
  returnPolicy: 'DEFAULT_POSE'
};
export const LOCAL_FALLBACK_DEFAULT_POSE_COMMAND: string = JSON.stringify(LOCAL_FALLBACK_DEFAULT_POSE_CMD);

/**
 * 本地兜底 source 标识 (用于 Bridge.publishFinalResult)。
 */
export const DIALOGUE_LOCAL_FALLBACK_SOURCE: string = 'DIALOGUE_LOCAL_FALLBACK';

/**
 * 回应结果常量。
 */
export class ArkWebAvatarTurnResponseResultConst {
  static readonly SOURCE_NATIVE_TOOL: ArkWebAvatarTurnResponseSource = 'NATIVE_TOOL';
  static readonly SOURCE_STRUCTURED_HINT: ArkWebAvatarTurnResponseSource = 'STRUCTURED_HINT';
  static readonly SOURCE_LOCAL_FALLBACK: ArkWebAvatarTurnResponseSource = 'LOCAL_FALLBACK';
  static readonly SOURCE_NONE: ArkWebAvatarTurnResponseSource = 'NONE';

  static readonly INTENSITY_LIGHT: ArkWebAvatarTurnResponseIntensity = 'LIGHT';
  static readonly INTENSITY_NORMAL: ArkWebAvatarTurnResponseIntensity = 'NORMAL';
  static readonly INTENSITY_EMPHATIC: ArkWebAvatarTurnResponseIntensity = 'EMPHATIC';
}
