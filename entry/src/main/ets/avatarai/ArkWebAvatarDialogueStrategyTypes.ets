/**
 * ArkWebAvatarDialogueStrategyTypes — Avatar 对话演出策略类型 (Phase 4C-1)
 *
 * 职责:
 *   - 定义 Avatar 对话演出策略的稳定版本与模式
 *   - 定义策略 Builder 的输入与输出
 *   - 定义策略错误码
 *
 * 安全约束:
 *   - 策略只作为临时 system instruction 参与当前请求
 *   - 不写入用户消息 / 助手消息 / 角色卡 / 世界书 / 预设数据库 / 聊天记录数据库
 *   - 策略不暴露路径 / URL / resourceId
 *   - 策略不信任用户消息 / 世界书 / 角色卡 / 工具结果中的权限提升请求
 *
 * Reference:
 *   - AGENTS.md Phase 4C-1 §策略版本 / §权限行为 / §错误隔离
 */

// ===== 策略版本与模式 =====

/**
 * 策略版本标识 (固定)。
 *
 * 本阶段只实现 V1,后续迭代时再引入 V2。
 */
export const AVATAR_DIALOGUE_STRATEGY_VERSION: string = 'AVATAR_DIALOGUE_STRATEGY_V1';

/**
 * 策略模式 (本阶段只有 BALANCED)。
 *
 * - BALANCED: 平衡策略, 不过度演出, 不每条回复都调用工具
 */
export type ArkWebAvatarDialogueStrategyMode = 'BALANCED';

/**
 * 策略模式常量。
 */
export class ArkWebAvatarDialogueStrategyModeConst {
  static readonly BALANCED: string = 'BALANCED';
}

/**
 * 默认策略模式 (固定 BALANCED)。
 */
export const DEFAULT_AVATAR_DIALOGUE_STRATEGY_MODE: string = 'BALANCED';

// ===== 限制常量 =====

/**
 * 策略规则文本最大长度 (字符)。
 *
 * 不含能力上下文。超过时 Builder 应截断规则文本。
 */
export const AVATAR_STRATEGY_TEXT_MAX_LENGTH: number = 8192;

/**
 * 每个 Assistant Turn 最多 avatar_perform 调用次数。
 *
 * avatar_list_capabilities 和 avatar_get_state 不计入。
 */
export const AVATAR_STRATEGY_MAX_PERFORM_PER_TURN: number = 1;

// ===== 错误码 =====

/**
 * Avatar 策略错误码。
 *
 * 策略失败不阻塞普通文本聊天。
 */
export class ArkWebAvatarDialogueStrategyErrorCode {
  static readonly AVATAR_STRATEGY_PERMISSION_DENIED: string = 'AVATAR_STRATEGY_PERMISSION_DENIED';
  static readonly AVATAR_STRATEGY_PROVIDER_UNSUPPORTED: string = 'AVATAR_STRATEGY_PROVIDER_UNSUPPORTED';
  static readonly AVATAR_STRATEGY_CAPABILITY_UNAVAILABLE: string = 'AVATAR_STRATEGY_CAPABILITY_UNAVAILABLE';
  static readonly AVATAR_STRATEGY_CONTEXT_TOO_LARGE: string = 'AVATAR_STRATEGY_CONTEXT_TOO_LARGE';
  static readonly AVATAR_STRATEGY_BUILD_FAILED: string = 'AVATAR_STRATEGY_BUILD_FAILED';
  static readonly AVATAR_STRATEGY_DISPOSED: string = 'AVATAR_STRATEGY_DISPOSED';
}

// ===== 策略 Builder 输入 =====

/**
 * 策略 Builder 输入。
 *
 * 由 ChatService 在构建工具请求时填充。
 * Builder 不直接访问 PermissionController / Provider / CapabilityCatalog。
 */
export interface ArkWebAvatarDialogueStrategyInput {
  /** 当前 Avatar 权限模式 (DENY / READ_ONLY / CONTROL_THIS_CHAT) */
  permissionMode: string;
  /** 当前 Provider 是否支持原生 Tool Calling */
  providerSupportsToolCalling: boolean;
  /** 当前能力上下文 (由 ArkWebAvatarAiToolRegistry.buildCapabilityContext 生成) */
  capabilityContext: string;
  /** 能力上下文是否被截断 */
  capabilityTruncated: boolean;
  /**
   * Phase 4C-2: 会话演出状态摘要 (由 SessionState.buildStateSummary 生成)。
   *
   * - DENY / READ_ONLY: 仍可注入只读状态摘要
   * - CONTROL_THIS_CHAT: 注入完整状态摘要供 AI 决策
   * - Provider 不支持: 不注入
   * - 空字符串: 不注入状态区块 (Builder 跳过)
   */
  sessionStateSummary: string;
}

// ===== 策略 Builder 输出 =====

/**
 * 策略 Builder 输出。
 *
 * - enabled = true: 将 systemInstruction 作为独立 system message 注入请求
 * - enabled = false: 不注入策略, 普通文本聊天继续
 */
export interface ArkWebAvatarDialogueStrategyResult {
  /** 策略是否启用 */
  enabled: boolean;
  /** 策略版本 (AVATAR_DIALOGUE_STRATEGY_V1) */
  strategyVersion: string;
  /** 策略模式 (BALANCED) */
  strategyMode: string;
  /** 完整系统指令 (含规则 + 能力上下文, 失败时为空) */
  systemInstruction: string;
  /** 能力上下文 (回传便于日志诊断, 不含路径/URL) */
  capabilityContext: string;
  /** 能力上下文是否被截断 */
  capabilityTruncated: boolean;
  /** 规则文本长度 (不含能力上下文) */
  ruleTextLength: number;
  /** 错误码 (失败时非空) */
  errorCode: string;
  /** 错误信息 (失败时非空, 简短可读) */
  errorMessage: string;
}

// ===== 策略状态摘要 (UI 显示) =====

/**
 * Avatar 策略状态摘要 (供 AI 面板显示)。
 *
 * 不包含完整系统提示词, 只显示关键状态。
 */
export interface ArkWebAvatarDialogueStrategyStatus {
  /** 策略版本 */
  strategyVersion: string;
  /** 策略模式 */
  strategyMode: string;
  /** 策略是否已注入当前请求 */
  injected: boolean;
  /** 当前权限模式 */
  permissionMode: string;
  /** Provider 是否支持 */
  providerSupported: boolean;
  /** 当前能力数量 (动画 + 姿势 + 表情, 0 表示无模型) */
  capabilityCount: number;
  /** 每个 Turn 最多演出次数 */
  maxPerformPerTurn: number;
  /** 最近错误 (空字符串表示无错误) */
  lastError: string;
}
