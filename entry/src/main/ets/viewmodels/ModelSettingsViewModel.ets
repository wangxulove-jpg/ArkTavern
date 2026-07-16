/**
 * ModelSettingsViewModel 模型设置 ViewModel
 *
 * 管理模型配置页面的状态与操作,作为页面与 ModelService 之间的唯一桥梁。
 *
 * 设计原则:
 * - 不依赖具体 ArkUI 页面实例
 * - 不使用全局单例、不使用 any
 * - API Key 仅存在于输入状态(apiKey 字段),保存/测试后立即清空
 * - 不从 KeyStore 读取并回显原密钥;已有密钥只显示"已配置"
 * - 编辑配置不输入新 Key 时保留旧 Key;新建必须 API Key
 * - 防止重复点击保存、删除和测试连接
 * - 支持 Provider 预设模式:DeepSeek 自动填充 URL/Model,只填 Key 即可
 *
 * 状态机:
 * - selectedConfigId === null:新建模式
 * - selectedConfigId !== null:编辑模式
 */

import { ModelService } from '../services/ModelService';
import { ProviderConfig } from '../models/ProviderConfig';
import { ProviderType } from '../models/ProviderType';
import { ChatResponse } from '../models/ChatResponse';
import {
  ModelServiceError,
  ModelServiceErrorType,
  isModelServiceError
} from '../models/ModelServiceError';
import {
  ProviderPreset,
  ModelOption,
  getPreset,
  hasPreset
} from '../models/ProviderPreset';
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

  // ===== 预设模式状态 =====
  /** 当前 Provider 的预设(无预设时为 null) */
  activePreset: ProviderPreset | null = null;
  /** 预设模式下选中的模型索引(-1 表示无) */
  selectedModelIndex: number = -1;
  /** 使用预设模式(baseUrl/modelName 自动填充,页面隐藏对应输入) */
  get isPresetMode(): boolean {
    return this.activePreset !== null;
  }

  // ===== 交互状态 =====
  isLoading: boolean = false;
  isSaving: boolean = false;
  isTesting: boolean = false;
  statusMessage: string = '';
  errorMessage: string = '';
  /** API Key 显隐切换(页面自行掩码,非系统 Password) */
  showApiKey: boolean = false;

  private modelService: ModelService;

  constructor(modelService: ModelService) {
    this.modelService = modelService;
  }

  // ===== 公共方法 =====

  async initialize(): Promise<void> {
    Logger.info(LOG_TAG, 'initialize');
    this.isLoading = true;
    this.errorMessage = '';
    try {
      this.configs = await this.modelService.listConfigs();
      const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
      this.currentConfigId = current !== null ? current.id : null;
      if (this.configs.length > 0) {
        await this.selectConfig(this.configs[0].id);
      } else {
        this.startCreate();
      }
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '加载配置失败');
    } finally {
      this.isLoading = false;
    }
  }

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
      this.populateForm(config);
      this.apiKeyConfigured = await this.modelService.hasApiKey(id);
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '读取配置失败');
    }
  }

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
    this.showApiKey = false;
    this.applyPresetForType(ProviderType.OpenAICompatible);
  }

  /**
   * 切换 Provider 类型。
   * 页面 Select onChange 时调用,自动应用预设。
   */
  onProviderTypeChange(type: ProviderType): void {
    Logger.info(LOG_TAG, 'providerType changed to ' + type);
    this.providerType = type;
    this.errorMessage = '';
    this.applyPresetForType(type);
  }

  async save(): Promise<void> {
    if (this.isSaving) {
      Logger.info(LOG_TAG, 'save blocked: already saving');
      return;
    }
    Logger.info(LOG_TAG, 'save clicked mode=' + (this.selectedConfigId === null ? 'create' : 'update'));
    this.errorMessage = '';
    this.statusMessage = '';

    const validation: ValidationResult = this.validateForm();
    if (!validation.valid) {
      Logger.info(LOG_TAG, 'save validation failed: ' + validation.message);
      this.errorMessage = validation.message;
      return;
    }
    Logger.info(LOG_TAG, 'save validation passed');

    this.isSaving = true;
    try {
      if (this.selectedConfigId === null) {
        await this.saveNew();
      } else {
        await this.saveUpdate();
      }
    } catch (e) {
      Logger.info(LOG_TAG, 'save error type=' + (isModelServiceError(e) ? (e as ModelServiceError).type : 'unknown'));
      this.errorMessage = this.toUserMessage(e, '保存失败');
    } finally {
      this.isSaving = false;
    }
  }

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
      this.showApiKey = false;
      this.isTesting = false;
    }
  }

  clearApiKeyInput(): void {
    this.apiKey = '';
    this.showApiKey = false;
  }

  dispose(): void {
    this.apiKey = '';
    this.showApiKey = false;
    this.errorMessage = '';
    this.statusMessage = '';
  }

  isSupportedType(type: ProviderType): boolean {
    return type === ProviderType.OpenAICompatible
      || type === ProviderType.OpenAI
      || type === ProviderType.DeepSeek
      || type === ProviderType.OpenRouter;
  }

  // ===== 内部方法 =====

  private populateForm(config: ProviderConfig): void {
    this.name = config.name;
    this.providerType = config.type;
    this.baseUrl = config.baseUrl;
    this.modelName = config.modelName;
    this.temperature = config.temperature;
    this.topP = config.topP;
    this.maxTokens = config.maxTokens;
    this.stream = config.stream;
    this.enabled = config.enabled;
    this.showApiKey = false;
    // 加载预设信息但不覆盖已加载的 baseUrl/modelName
    const preset: ProviderPreset | null = getPreset(config.type);
    this.activePreset = preset;
    if (preset !== null) {
      this.syncModelIndexFromName(config.modelName);
    } else {
      this.selectedModelIndex = -1;
    }
  }

  private syncModelIndexFromName(modelName: string): void {
    if (this.activePreset === null) {
      return;
    }
    const models: ModelOption[] = this.activePreset.availableModels;
    for (let i = 0; i < models.length; i++) {
      if (models[i].id === modelName) {
        this.selectedModelIndex = i;
        return;
      }
    }
    this.selectedModelIndex = -1;
  }

  /**
   * 根据 Provider 类型应用预设。
   */
  private applyPresetForType(type: ProviderType): void {
    const preset: ProviderPreset | null = getPreset(type);
    this.activePreset = preset;

    if (preset !== null) {
      this.baseUrl = preset.defaultBaseUrl;
      this.selectedModelIndex = 0;
      this.modelName = preset.defaultModel.id;
      // 自动命名
      if (this.name.length === 0 || this.name === this.modelName) {
        this.name = preset.defaultModel.displayName;
      }
    } else {
      this.selectedModelIndex = -1;
      // 从预设模式切换回自定义模式时,清空 baseUrl/modelName
      if (type !== ProviderType.DeepSeek) {
        this.baseUrl = '';
        this.modelName = '';
      }
    }
  }

  /**
   * 切换预设模式下的模型选择。
   */
  onModelSelect(index: number): void {
    if (this.activePreset === null) {
      return;
    }
    const models: ModelOption[] = this.activePreset.availableModels;
    if (index >= 0 && index < models.length) {
      this.selectedModelIndex = index;
      this.modelName = models[index].id;
      if (this.name.length === 0 || this.name === models[this.selectedModelIndex].displayName) {
        this.name = models[index].displayName;
      }
    }
  }

  private async saveNew(): Promise<void> {
    const id: string = generateUuid();
    const config: ProviderConfig = this.buildFormConfig(id);
    const apiKeyToSave: string = this.apiKey;
    Logger.info(LOG_TAG, 'saveNew id=' + id + ' type=' + config.type);
    await this.modelService.createConfig(config, apiKeyToSave);
    this.configs = await this.modelService.listConfigs();
    const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (current === null) {
      await this.modelService.setCurrentConfig(id);
      this.currentConfigId = id;
    } else {
      this.currentConfigId = current.id;
    }
    await this.selectConfig(id);
    this.apiKey = '';
    this.showApiKey = false;
    this.statusMessage = '配置保存成功';
    Logger.info(LOG_TAG, 'saveNew ok id=' + id);
  }

  private async saveUpdate(): Promise<void> {
    const config: ProviderConfig = this.buildFormConfig(this.selectedConfigId as string);
    const apiKeyParam: string | undefined = this.apiKey.length > 0 ? this.apiKey : undefined;
    Logger.info(LOG_TAG, 'saveUpdate id=' + config.id);
    await this.modelService.updateConfig(config, apiKeyParam);
    this.configs = await this.modelService.listConfigs();
    const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
    this.currentConfigId = current !== null ? current.id : null;
    await this.selectConfig(this.selectedConfigId as string);
    this.apiKey = '';
    this.showApiKey = false;
    this.statusMessage = '配置保存成功';
    Logger.info(LOG_TAG, 'saveUpdate ok id=' + config.id);
  }

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

  private validateForm(): ValidationResult {
    if (this.name.trim().length === 0) {
      return { valid: false, message: '请输入配置名称' };
    }
    if (!this.isSupportedType(this.providerType)) {
      return { valid: false, message: '该 Provider 类型暂未支持' };
    }

    if (this.isPresetMode) {
      // 预设模式:baseUrl/modelName 由预设生成,不要求用户填写,但仍需非空
      if (this.baseUrl.trim().length === 0) {
        return { valid: false, message: '预设 Base URL 未配置' };
      }
      if (this.modelName.trim().length === 0) {
        return { valid: false, message: '请选择模型' };
      }
    } else {
      // 自定义模式:要求用户填写 baseUrl 和 modelName
      if (this.baseUrl.trim().length === 0) {
        return { valid: false, message: '请输入 Base URL' };
      }
      if (!this.isValidUrl(this.baseUrl)) {
        return { valid: false, message: 'Base URL 格式不合法' };
      }
      if (this.modelName.trim().length === 0) {
        return { valid: false, message: '请输入模型名称' };
      }
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
    if (this.selectedConfigId === null && this.apiKey.trim().length === 0) {
      return { valid: false, message: '新建配置必须输入 API Key' };
    }
    return { valid: true, message: '' };
  }

  private isValidUrl(url: string): boolean {
    if (url.startsWith('https://') && url.length > 8) {
      return true;
    }
    if (url.startsWith('http://') && url.length > 7) {
      return true;
    }
    return false;
  }

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