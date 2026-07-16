/**
 * ProviderPreset Provider 预设数据模型
 *
 * 定义各 Provider 的预设配置,包括默认 Base URL、可用模型列表等。
 * 页面只消费预设数据,不把预设保存到 Preferences。
 * 不包含 API Key 或任何敏感信息。
 *
 * 当前完整实现:DeepSeek
 * 后续可扩展:OpenAI、OpenRouter
 * OpenAI Compatible 继续使用自定义模式(无预设)。
 */

import { ProviderType } from './ProviderType';

/**
 * 模型选项。
 */
export interface ModelOption {
  /** 模型标识(保存到 ProviderConfig.modelName) */
  readonly id: string;
  /** 显示名称 */
  readonly displayName: string;
  /** 简要描述(可选) */
  readonly description?: string;
}

/**
 * Provider 预设配置。
 */
export interface ProviderPreset {
  /** Provider 类型 */
  readonly providerType: ProviderType;
  /** 显示名称 */
  readonly displayName: string;
  /** 默认 Base URL */
  readonly defaultBaseUrl: string;
  /** 可用模型列表 */
  readonly availableModels: ModelOption[];
  /** 默认模型 */
  readonly defaultModel: ModelOption;
}

/**
 * 获取 Provider 的预设配置,不存在则返回 null。
 */
export function getPreset(type: ProviderType): ProviderPreset | null {
  for (let i = 0; i < ALL_PRESETS.length; i++) {
    if (ALL_PRESETS[i].providerType === type) {
      return ALL_PRESETS[i];
    }
  }
  return null;
}

/**
 * 判断 Provider 是否有预设。
 */
export function hasPreset(type: ProviderType): boolean {
  return getPreset(type) !== null;
}

// ===== DeepSeek 预设 =====

const DEEPSEEK_MODELS: ModelOption[] = [
  {
    id: 'deepseek-v4-flash',
    displayName: 'DeepSeek V4 Flash',
    description: '快速响应,适合日常对话'
  },
  {
    id: 'deepseek-v4-pro',
    displayName: 'DeepSeek V4 Pro',
    description: '深度推理,当前按标准请求发送(思考参数后续支持)'
  }
];

const DEEPSEEK_PRESET: ProviderPreset = {
  providerType: ProviderType.DeepSeek,
  displayName: 'DeepSeek',
  // 直接设置完整端点,避免 OpenAiUrlBuilder 追加 /v1
  defaultBaseUrl: 'https://api.deepseek.com/chat/completions',
  availableModels: DEEPSEEK_MODELS,
  defaultModel: DEEPSEEK_MODELS[0]
};

// ===== 全部预设列表 =====

const ALL_PRESETS: ProviderPreset[] = [
  DEEPSEEK_PRESET
];