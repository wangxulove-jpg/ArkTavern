/**
 * ContextBudgetConfig 上下文预算配置(v8.2)
 *
 * 描述单个 Chat 的上下文预算覆盖。
 * - followModel=true 时使用 ProviderConfig 的 contextWindow / maxTokens
 * - followModel=false 时使用本配置中的自定义值
 *
 * 存储位置:AppPreferences,不进 RDB。
 *
 * v8.2 调整:
 * - DEFAULT_CUSTOM_CONTEXT_WINDOW: 32768 → 131072(128K,新 Chat 默认值)
 * - DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS: 2048 → 8192(8K)
 * - MAX_CUSTOM_CONTEXT_WINDOW: 200000 → 1000000(1M,模型硬上限)
 * - MAX_CUSTOM_RESERVED_OUTPUT_TOKENS: 32768 → 384000(DeepSeek-V4-Flash 输出能力上限)
 * - 新增 BUDGET_SAFETY_MARGIN(安全余量,用于 Token 估算误差和 Provider 包装)
 * - 新增 CONTEXT_WINDOW_PRESETS(可选档位:16K/32K/64K/128K/256K/512K/1M)
 */

/**
 * Per-chat 上下文预算配置。
 */
export interface ContextBudgetConfig {
  /** 是否跟随模型配置(默认 false,使用 customContextWindow) */
  readonly followModel: boolean;
  /** 自定义上下文窗口大小(followModel=false 时生效) */
  readonly customContextWindow: number;
  /** 自定义预留输出 Token(followModel=false 时生效) */
  readonly customReservedOutputTokens: number;
  /** 是否自动管理最近消息(超限时自动裁剪) */
  readonly autoManage: boolean;
}

/** 默认上下文窗口(128K,新 Chat 默认值) */
export const DEFAULT_CUSTOM_CONTEXT_WINDOW: number = 131072;
/** 默认预留输出 Token(8K) */
export const DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS: number = 8192;
/** 自定义上下文窗口下限 */
export const MIN_CUSTOM_CONTEXT_WINDOW: number = 4096;
/** 自定义上下文窗口上限(1M,模型硬上限,不得超过) */
export const MAX_CUSTOM_CONTEXT_WINDOW: number = 1000000;
/** 自定义预留输出下限 */
export const MIN_CUSTOM_RESERVED_OUTPUT_TOKENS: number = 256;
/** 自定义预留输出上限(384K,DeepSeek-V4-Flash 输出能力上限) */
export const MAX_CUSTOM_RESERVED_OUTPUT_TOKENS: number = 384000;

/**
 * 安全余量(Token):
 * - 用于 Token 估算误差(本地估算器与模型实际 tokenizer 差异)
 * - 用于 Provider 包装(系统消息、JSON 序列化等附加 Token)
 * - 输入可用预算 = contextWindow - reservedOutputTokens - BUDGET_SAFETY_MARGIN
 */
export const BUDGET_SAFETY_MARGIN: number = 512;

/**
 * 可选上下文窗口档位(用户可在 UI 快速选择)。
 * - 16K / 32K / 64K / 128K / 256K / 512K / 1M
 * - 不得超过 MAX_CUSTOM_CONTEXT_WINDOW(1M)
 */
export const CONTEXT_WINDOW_PRESETS: number[] = [
  16384,    // 16K
  32768,    // 32K
  65536,    // 64K
  131072,   // 128K
  262144,   // 256K
  524288,   // 512K
  1048576   // 1M
];

/**
 * 创建默认 ContextBudgetConfig。
 * v8.2:默认 followModel=false,使用 customContextWindow=128K(避免新 Chat 默认用满 1M)
 */
export function createDefaultContextBudgetConfig(): ContextBudgetConfig {
  return {
    followModel: false,
    customContextWindow: DEFAULT_CUSTOM_CONTEXT_WINDOW,
    customReservedOutputTokens: DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS,
    autoManage: true
  };
}

/**
 * 创建 ContextBudgetConfig(显式字段)。
 */
export function createContextBudgetConfig(
  followModel: boolean,
  customContextWindow: number,
  customReservedOutputTokens: number,
  autoManage: boolean
): ContextBudgetConfig {
  return {
    followModel,
    customContextWindow,
    customReservedOutputTokens,
    autoManage
  };
}
