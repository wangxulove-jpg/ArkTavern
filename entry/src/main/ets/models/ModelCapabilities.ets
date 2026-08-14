/**
 * ModelCapabilities 内置模型能力表(v8.2)
 *
 * 根据模型名(modelName)返回该模型的上下文窗口与输出能力上限。
 * 用于:
 * - 在 ProviderConfig.contextWindow 未显式配置时提供兜底
 * - 在 ContextBudgetViewModel 中作为 clampReserved 的上限
 * - 在 ContextBudgetPage 中显示"模型上下文上限"
 *
 * 设计原则:
 * - 纯函数,无状态,无副作用
 * - 不依赖 ProviderConfig / Preferences / ArkUI
 * - 模型名匹配大小写不敏感
 * - 未知模型返回 null(由调用方使用默认值)
 *
 * 旧模型名兼容:
 * - deepseek-chat:按 DeepSeek-V4-Flash 非思考模式处理
 * - deepseek-reasoner:按 DeepSeek-V4-Flash 思考模式处理
 */

/**
 * 模型能力描述。
 */
export interface ModelCapability {
  /** 模型上下文窗口上限(Token) */
  readonly contextWindow: number;
  /** 最大输出 Token 上限 */
  readonly maxOutputTokensLimit: number;
  /** 是否支持思考模式 */
  readonly supportsThinkingMode: boolean;
}

/**
 * DeepSeek-V4-Flash 能力(也用于兼容 deepseek-chat / deepseek-reasoner)。
 */
const DEEPSEEK_V4_FLASH_CAPABILITY: ModelCapability = {
  contextWindow: 1000000,
  maxOutputTokensLimit: 384000,
  supportsThinkingMode: true
};

/**
 * 小米 MiMo-V2.5-Pro 能力(1M 上下文,最大输出 128K,支持深度思考)。
 */
const MIMO_V25_PRO_CAPABILITY: ModelCapability = {
  contextWindow: 1000000,
  maxOutputTokensLimit: 128000,
  supportsThinkingMode: true
};

/**
 * 小米 MiMo-V2.5 多模态能力(1M 上下文,最大输出按 V2.5 系列 128K)。
 */
const MIMO_V25_CAPABILITY: ModelCapability = {
  contextWindow: 1000000,
  maxOutputTokensLimit: 128000,
  supportsThinkingMode: true
};

/**
 * 根据模型名返回能力描述。
 * 未知模型返回 null。
 */
export function getModelCapability(modelName: string): ModelCapability | null {
  if (modelName.length === 0) {
    return null;
  }
  const lower: string = modelName.toLowerCase();
  // DeepSeek-V4-Flash 主名
  if (lower === 'deepseek-v4-flash') {
    return DEEPSEEK_V4_FLASH_CAPABILITY;
  }
  // 旧模型名兼容
  if (lower === 'deepseek-chat') {
    // 按 DeepSeek-V4-Flash 非思考模式处理
    return {
      contextWindow: DEEPSEEK_V4_FLASH_CAPABILITY.contextWindow,
      maxOutputTokensLimit: DEEPSEEK_V4_FLASH_CAPABILITY.maxOutputTokensLimit,
      supportsThinkingMode: false
    };
  }
  if (lower === 'deepseek-reasoner') {
    // 按 DeepSeek-V4-Flash 思考模式处理
    return DEEPSEEK_V4_FLASH_CAPABILITY;
  }
  // 小米 MiMo V2.5 系列(1M 上下文,最大输出 128K)
  if (lower === 'mimo-v2.5-pro') {
    return MIMO_V25_PRO_CAPABILITY;
  }
  if (lower === 'mimo-v2.5') {
    return MIMO_V25_CAPABILITY;
  }
  return null;
}

/**
 * 判断模型是否在能力表中(用于 ContextBudgetPage 显示)。
 */
export function isModelSupported(modelName: string): boolean {
  return getModelCapability(modelName) !== null;
}
