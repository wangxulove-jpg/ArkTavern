/**
 * ModelSettingsViewModel 模型设置 ViewModel
 *
 * 管理模型配置页面的状态与操作,作为页面与 ModelService 之间的唯一桥梁。
 * 页面只通过本 ViewModel 调用 ModelService,不直接接触 ProviderConfigStore / KeyStore / Provider。
 *
 * 设计原则:
 * - 不依赖具体 ArkUI 页面实例
 * - 不使用全局单例
 * - 不使用 any
 * - API Key 仅存在于输入状态(apiKey 字段),保存或测试完成后立即清空
 * - 不从 KeyStore 读取并回显原密钥;已有密钥只显示"已配置"
 * - 编辑配置但不输入新 Key 时,保留旧 Key
 * - 新建配置必须要求 API Key
 * - 防止重复点击保存、删除和测试连接
 *
 * 状态机:
 * - selectedConfigId === null:新建模式
 * - selectedConfigId !== null:编辑模式(编辑已有配置)
 */

import { ModelService } from '../services/ModelService';
import { ProviderConfig } from '../models/ProviderConfig';
import {
  ProviderType
} from '../models/ProviderType';
import { ChatResponse } from '../models/ChatResponse';
import {
  ModelServiceError,
  ModelServiceErrorType,
  isModelServiceError
} from '../models/ModelServiceError';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';
import {
  TEMPERATURE_DEFAULT,
  TOP_P_DEFAULT,
  MAX_TOKENS_DEFAULT,
  STREAM_DEFAULT,
  ENABLED_DEFAULT,
  TEMPERATURE_MIN,
  TEMPERATURE_MAX,
  TOP_P_MIN,
  TOP_P_MAX,
  MAX_TOKENS_MIN,
  MAX_TOKENS_MAX
} from '../models/ProviderConfig';

const LOG_TAG: string = 'ModelSettingsVM';

/**
 * 表单校验结果。
 */
interface ValidationResult {
  readonly valid: boolean;
  readonly message: string;
}

/**
 * 模型设置 ViewModel。
 * 使用 @Observed 装饰,使页面能响应字段变更。
 */
@Observed
export class ModelSettingsViewModel {
  // ===== 列表状态 =====
  configs: ProviderConfig[] = [];
  currentConfigId: string | null = null;

  // ===== 表单状态 =====
  selectedConfigId: string | null = null;
  name: string = '';
  providerType: ProviderType = ProviderType.OpenAICompatible;
  baseUrl: string = '';
  modelName: string = '';
  apiKey: string = '';
  temperature: number = TEMPERATURE_DEFAULT;
  topP: number = TOP_P_DEFAULT;
  maxTokens: number = MAX_TOKENS_DEFAULT;
  stream: boolean = STREAM_DEFAULT;
  enabled: boolean = ENABLED_DEFAULT;
  apiKeyConfigured: boolean = false;

  // ===== 交互状态 =====
  isLoading: boolean = false;
  isSaving: boolean = false;
  isTesting: boolean = false;
  statusMessage: string = '';
  errorMessage: string = '';

  private modelService: ModelService;

  constructor(modelService: ModelService) {
    this.modelService = modelService;
  }

  /**
   * 初始化:加载配置列表与当前选中配置。
   */
  async initialize(): Promise<void> {
    Logger.info(LOG_TAG, 'initialize');
    this.isLoading = true;
    this.errorMessage = '';
    try {
      this.configs = await this.modelService.listConfigs();
      const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
      this.currentConfigId = current !== null ? current.id : null;
      if (this.configs.length > 0) {
        const firstId: string = this.configs[0].id;
        await this.selectConfig(firstId);
      } else {
        this.startCreate();
      }
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '加载配置失败');
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 选择并加载指定配置到表单。
   * 不读取 API Key 明文,仅查询是否已配置。
   */
  async selectConfig(id: string): Promise<void> {
    Logger.info(LOG_TAG, 'selectConfig id=' + id);
    this.selectedConfigId = id;
    this.apiKey = '';
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const config: ProviderConfig | null = await this.modelService.getConfig(id);
      if (config === null) {
        this.errorMessage = '配置不存在';
        return;
      }
      this.name = config.name;
      this.providerType = config.type;
      this.baseUrl = config.baseUrl;
      this.modelName = config.modelName;
      this.temperature = config.temperature;
      this.topP = config.topP;
      this.maxTokens = config.maxTokens;
      this.stream = config.stream;
      this.enabled = config.enabled;
      this.apiKeyConfigured = await this.modelService.hasApiKey(id);
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '读取配置失败');
    }
  }

  /**
   * 进入新建模式,重置表单为默认值。
   */
  startCreate(): void {
    Logger.info(LOG_TAG, 'startCreate');
    this.selectedConfigId = null;
    this.name = '';
    this.providerType = ProviderType.OpenAICompatible;
    this.baseUrl = '';
    this.modelName = '';
    this.apiKey = '';
    this.temperature = TEMPERATURE_DEFAULT;
    this.topP = TOP_P_DEFAULT;
    this.maxTokens = MAX_TOKENS_DEFAULT;
    this.stream = STREAM_DEFAULT;
    this.enabled = ENABLED_DEFAULT;
    this.apiKeyConfigured = false;
    this.errorMessage = '';
    this.statusMessage = '';
  }

  /**
   * 保存当前表单(新建或更新)。
   * 防止重复点击。API Key 保存后立即清空。
   */
  async save(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    const validation: ValidationResult = this.validateForm();
    if (!validation.valid) {
      this.errorMessage = validation.message;
      return;
    }
    this.isSaving = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      if (this.selectedConfigId === null) {
        await this.saveNew();
      } else {
        await this.saveUpdate();
      }
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '保存失败');
    } finally {
      this.isSaving = false;
    }
  }

  /**
   * 删除当前选中的配置。
   * 防止重复点击。删除后刷新列表。
   */
  async deleteSelected(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    if (this.selectedConfigId === null) {
      this.errorMessage = '新建模式无法删除';
      return;
    }
    this.isSaving = true;
    this.errorMessage = '';
    this.statusMessage = '';
    const targetId: string = this.selectedConfigId;
    try {
      await this.modelService.deleteConfig(targetId);
      this.configs = await this.modelService.listConfigs();
      const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
      this.currentConfigId = current !== null ? current.id : null;
      if (this.configs.length > 0) {
        await this.selectConfig(this.configs[0].id);
      } else {
        this.startCreate();
      }
      this.statusMessage = '已删除';
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '删除失败');
    } finally {
      this.isSaving = false;
    }
  }

  /**
   * 将当前选中配置设为当前 Provider。
   */
  async setCurrent(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    if (this.selectedConfigId === null) {
      this.errorMessage = '请先保存配置';
      return;
    }
    if (!this.isSupportedType(this.providerType)) {
      this.errorMessage = '当前不支持的 Provider 类型';
      return;
    }
    this.isSaving = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      await this.modelService.setCurrentConfig(this.selectedConfigId);
      this.currentConfigId = this.selectedConfigId;
      this.statusMessage = '已设为当前配置';
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '设置当前配置失败');
    } finally {
      this.isSaving = false;
    }
  }

  /**
   * 测试当前表单内容的连接。
   * 使用当前表单值构造临时配置,不修改正式配置。
   * API Key 输入在测试后立即清空。
   */
  async testConnection(): Promise<void> {
    if (this.isTesting) {
      return;
    }
    const validation: ValidationResult = this.validateForm();
    if (!validation.valid) {
      this.errorMessage = validation.message;
      return;
    }
    if (!this.isSupportedType(this.providerType)) {
      this.errorMessage = '当前不支持的 Provider 类型';
      return;
    }
    this.isTesting = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const tempConfig: ProviderConfig = this.buildFormConfig(
        this.selectedConfigId !== null ? this.selectedConfigId : generateUuid()
      );
      const apiKeyParam: string | undefined = this.apiKey.length > 0 ? this.apiKey : undefined;
      const response: ChatResponse = await this.modelService.testConnection(tempConfig, apiKeyParam);
      this.statusMessage = this.formatTestResult(response);
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '连接测试失败');
    } finally {
      this.apiKey = '';
      this.isTesting = false;
    }
  }

  /**
   * 清空 API Key 输入。
   */
  clearApiKeyInput(): void {
    this.apiKey = '';
  }

  /**
   * 释放资源(页面退出时调用)。
   * 清空 API Key 输入,防止残留。
   */
  dispose(): void {
    this.apiKey = '';
    this.errorMessage = '';
    this.statusMessage = '';
  }

  /**
   * 判断 Provider 类型是否当前正式支持。
   */
  isSupportedType(type: ProviderType): boolean {
    return type === ProviderType.OpenAICompatible
      || type === ProviderType.OpenAI
      || type === ProviderType.DeepSeek
      || type === ProviderType.OpenRouter;
  }

  // ===== 内部方法 =====

  /**
   * 新建配置保存逻辑。
   * 新建必须提供 API Key。保存成功后自动选中,首次配置自动设为当前。
   */
  private async saveNew(): Promise<void> {
    const id: string = generateUuid();
    const config: ProviderConfig = this.buildFormConfig(id);
    const apiKeyToSave: string = this.apiKey;
    await this.modelService.createConfig(config, apiKeyToSave);
    this.configs = await this.modelService.listConfigs();
    const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (current === null) {
      // 首次配置自动设为当前
      await this.modelService.setCurrentConfig(id);
      this.currentConfigId = id;
    } else {
      this.currentConfigId = current.id;
    }
    await this.selectConfig(id);
    this.statusMessage = '已保存';
  }

  /**
   * 更新配置保存逻辑。
   * API Key 为空表示保留原密钥;非空表示替换。
   */
  private async saveUpdate(): Promise<void> {
    const config: ProviderConfig = this.buildFormConfig(this.selectedConfigId as string);
    const apiKeyParam: string | undefined = this.apiKey.length > 0 ? this.apiKey : undefined;
    await this.modelService.updateConfig(config, apiKeyParam);
    this.configs = await this.modelService.listConfigs();
    const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
    this.currentConfigId = current !== null ? current.id : null;
    await this.selectConfig(this.selectedConfigId as string);
    this.statusMessage = '已保存';
  }

  /**
   * 使用当前表单字段构造 ProviderConfig。
   */
  private buildFormConfig(id: string): ProviderConfig {
    const now: number = Date.now();
    return new ProviderConfig(
      id,
      this.name,
      this.providerType,
      this.baseUrl,
      this.modelName,
      this.temperature,
      this.topP,
      this.maxTokens,
      this.stream,
      this.enabled,
      now,
      now
    );
  }

  /**
   * 校验表单字段。
   * 新建模式要求 API Key 非空;编辑模式允许 API Key 为空(保留原密钥)。
   */
  private validateForm(): ValidationResult {
    if (this.name.trim().length === 0) {
      return { valid: false, message: '请输入配置名称' };
    }
    if (this.baseUrl.trim().length === 0) {
      return { valid: false, message: '请输入 Base URL' };
    }
    if (!this.isValidUrl(this.baseUrl)) {
      return { valid: false, message: 'Base URL 格式不合法' };
    }
    if (this.modelName.trim().length === 0) {
      return { valid: false, message: '请输入模型名称' };
    }
    if (this.temperature < TEMPERATURE_MIN || this.temperature > TEMPERATURE_MAX) {
      return { valid: false, message: 'Temperature 必须在 ' + TEMPERATURE_MIN + ' ~ ' + TEMPERATURE_MAX };
    }
    if (this.topP < TOP_P_MIN || this.topP > TOP_P_MAX) {
      return { valid: false, message: 'Top P 必须在 ' + TOP_P_MIN + ' ~ ' + TOP_P_MAX };
    }
    if (!Number.isInteger(this.maxTokens) || this.maxTokens < MAX_TOKENS_MIN || this.maxTokens > MAX_TOKENS_MAX) {
      return { valid: false, message: 'Max Tokens 必须为整数且在 ' + MAX_TOKENS_MIN + ' ~ ' + MAX_TOKENS_MAX };
    }
    if (!this.isSupportedType(this.providerType)) {
      return { valid: false, message: '该 Provider 类型暂未支持' };
    }
    if (this.selectedConfigId === null && this.apiKey.trim().length === 0) {
      return { valid: false, message: '新建配置必须输入 API Key' };
    }
    return { valid: true, message: '' };
  }

  /**
   * 简单 URL 格式校验(只校验协议和基本结构)。
   */
  private isValidUrl(url: string): boolean {
    if (url.startsWith('https://') && url.length > 8) {
      return true;
    }
    if (url.startsWith('http://') && url.length > 7) {
      return true;
    }
    return false;
  }

  /**
   * 格式化测试连接结果为简短状态消息。
   * 不展示完整回复正文。
   */
  private formatTestResult(response: ChatResponse): string {
    const parts: string[] = ['连接成功'];
    if (response.model !== undefined && response.model.length > 0) {
      parts.push('模型: ' + response.model);
    }
    if (response.totalTokens !== undefined) {
      parts.push('tokens: ' + response.totalTokens.toString());
    } else if (response.promptTokens !== undefined && response.completionTokens !== undefined) {
      parts.push('tokens: ' + (response.promptTokens + response.completionTokens).toString());
    }
    return parts.join(' | ');
  }

  /**
   * 将底层错误转换为用户可读消息,不暴露堆栈。
   */
  private toUserMessage(e: Object, fallback: string): string {
    if (isModelServiceError(e)) {
      const err: ModelServiceError = e as ModelServiceError;
      switch (err.type) {
        case ModelServiceErrorType.ConfigNotFound:
          return '配置不存在';
        case ModelServiceErrorType.ConfigAlreadyExists:
          return '配置已存在';
        case ModelServiceErrorType.ApiKeyMissing:
          return 'API Key 未配置';
        case ModelServiceErrorType.UnsupportedProvider:
          return '该 Provider 类型暂未支持';
        case ModelServiceErrorType.NoCurrentConfig:
          return '未选择当前配置';
        case ModelServiceErrorType.ConfigDisabled:
          return '当前配置已禁用';
        case ModelServiceErrorType.NotInitialized:
          return '服务未初始化';
        case ModelServiceErrorType.NetworkFailure:
          return '网络连接失败,请检查网络或 Base URL';
        case ModelServiceErrorType.StorageFailure:
          return '存储失败,请重试';
        case ModelServiceErrorType.PartialFailure:
          return '部分操作失败,请重试';
        default:
          return fallback;
      }
    }
    return fallback;
  }
}
