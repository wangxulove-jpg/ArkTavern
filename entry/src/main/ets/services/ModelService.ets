/**
 * ModelService 业务编排服务
 *
 * 统一编排 ProviderConfigStore、ProviderKeyStore、AiProvider,
 * 为页面/ViewModel 提供单一入口的业务 API。
 *
 * 设计原则:
 * - 页面只调用 ModelService,不直接接触 Store / KeyStore / Provider
 * - 不缓存 API Key,不将 Key 写入成员变量/Preferences/日志
 * - 不依赖 ArkUI 页面或 ViewModel,不创建全局单例
 * - 所有错误转换为 ModelServiceError
 *
 * 事务策略:
 * - createConfig:先配置后密钥;密钥失败回滚配置删除
 * - updateConfig:先配置后密钥;密钥失败不回滚配置
 * - deleteConfig:先配置后密钥;密钥失败不回滚(密钥残留可接受)
 * - testConnection:不修改正式配置;临时 Key 通过临时 alias,测试后清理
 */

import { common } from '@kit.AbilityKit';
import { ProviderConfig } from '../models/ProviderConfig';
import { ChatRequest, ChatRequestOptions } from '../models/ChatRequest';
import { ChatResponse } from '../models/ChatResponse';
import { ChatMessage, createChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState
} from '../models/ChatStreamTypes';
import { NetworkError } from '../models/NetworkError';
import {
  PreferencesError,
  PreferencesErrorType,
  isPreferencesError
} from '../models/PreferencesError';
import { SecureStorageError } from '../models/SecureStorageError';
import {
  ModelServiceError,
  ModelServiceErrorType,
  createModelServiceError
} from '../models/ModelServiceError';
import { ProviderConfigStore } from '../storage/ProviderConfigStore';
import { ProviderKeyStore } from '../storage/ProviderKeyStore';
import { AiProvider } from '../network/providers/AiProvider';
import { Logger } from '../utils/Logger';
import {
  ProviderFactory,
  DefaultProviderFactory,
  isOpenAICompatibleType,
  cloneConfigWithId,
  toNetworkError,
  createUnknownNetworkError
} from './ProviderFactory';

const LOG_TAG: string = 'ModelService';
const TEST_ALIAS_PREFIX: string = '__test__.';

/**
 * ModelService 业务编排服务。
 */
export class ModelService {
  private readonly configStore: ProviderConfigStore;
  private readonly keyStore: ProviderKeyStore;
  private readonly providerFactory: ProviderFactory;
  private initialized: boolean = false;

  constructor(
    configStore: ProviderConfigStore,
    keyStore: ProviderKeyStore,
    providerFactory?: ProviderFactory
  ) {
    this.configStore = configStore;
    this.keyStore = keyStore;
    this.providerFactory = providerFactory !== undefined
      ? providerFactory
      : new DefaultProviderFactory(keyStore);
  }

  async initialize(context: common.Context): Promise<void> {
    Logger.info(LOG_TAG, 'initialize');
    try {
      await this.configStore.initialize(context);
      this.initialized = true;
      Logger.info(LOG_TAG, 'initialize ok');
    } catch (e) {
      throw this.wrapStorageError(e, 'initialize failed');
    }
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  async listConfigs(): Promise<ProviderConfig[]> {
    this.requireInitialized();
    try {
      return await this.configStore.list();
    } catch (e) {
      throw this.wrapStorageError(e, 'listConfigs failed');
    }
  }

  async getConfig(id: string): Promise<ProviderConfig | null> {
    this.requireInitialized();
    if (id.length === 0) {
      throw createModelServiceError(
        ModelServiceErrorType.ConfigNotFound, 'getConfig: id is empty'
      );
    }
    try {
      return await this.configStore.getById(id);
    } catch (e) {
      throw this.wrapStorageError(e, 'getConfig failed id=' + id);
    }
  }

  async getCurrentConfig(): Promise<ProviderConfig | null> {
    this.requireInitialized();
    try {
      return await this.configStore.getCurrent();
    } catch (e) {
      throw this.wrapStorageError(e, 'getCurrentConfig failed');
    }
  }

  /**
   * 新增 ProviderConfig,可选同时保存 API Key。
   * 事务:先配置后密钥;密钥失败回滚配置删除。
   */
  async createConfig(config: ProviderConfig, apiKey?: string): Promise<void> {
    this.requireInitialized();
    Logger.info(LOG_TAG, 'createConfig id=' + config.id);

    try {
      await this.configStore.save(config);
    } catch (e) {
      throw this.wrapCreateConfigError(e, config.id);
    }

    if (apiKey !== undefined && apiKey.length > 0) {
      try {
        await this.keyStore.saveKey(config.id, apiKey);
        Logger.info(LOG_TAG, 'createConfig ok with key id=' + config.id);
      } catch (e) {
        Logger.warn(LOG_TAG, 'createConfig key failed, rollback id=' + config.id);
        await this.rollbackConfigDelete(config.id);
        throw this.wrapKeyError(e, ModelServiceErrorType.PartialFailure,
          'createConfig key save failed, config rolled back');
      }
      return;
    }
    Logger.info(LOG_TAG, 'createConfig ok without key id=' + config.id);
  }

  /**
   * 更新 ProviderConfig,可选同时更新 API Key。
   * apiKey=undefined 保留原密钥;apiKey='' 清除密钥;apiKey 非空替换密钥。
   */
  async updateConfig(config: ProviderConfig, apiKey?: string): Promise<void> {
    this.requireInitialized();
    Logger.info(LOG_TAG, 'updateConfig id=' + config.id);

    try {
      await this.configStore.update(config);
    } catch (e) {
      throw this.wrapUpdateConfigError(e, config.id);
    }

    if (apiKey === undefined) {
      Logger.info(LOG_TAG, 'updateConfig ok, key preserved id=' + config.id);
      return;
    }

    if (apiKey.length === 0) {
      try {
        await this.keyStore.removeKey(config.id);
        Logger.info(LOG_TAG, 'updateConfig ok, key removed id=' + config.id);
      } catch (e) {
        throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
          'updateConfig key remove failed');
      }
      return;
    }

    try {
      await this.keyStore.replaceKey(config.id, apiKey);
      Logger.info(LOG_TAG, 'updateConfig ok, key replaced id=' + config.id);
    } catch (e) {
      throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
        'updateConfig key replace failed');
    }
  }

  /**
   * 删除 ProviderConfig 及其 API Key。
   * 密钥删除失败不回滚(配置已删除,密钥残留可接受)。
   */
  async deleteConfig(id: string): Promise<void> {
    this.requireInitialized();
    Logger.info(LOG_TAG, 'deleteConfig id=' + id);

    try {
      await this.configStore.remove(id);
    } catch (e) {
      throw this.wrapStorageError(e, 'deleteConfig config remove failed id=' + id);
    }

    try {
      await this.keyStore.removeKey(id);
      Logger.info(LOG_TAG, 'deleteConfig ok id=' + id);
    } catch (e) {
      throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
        'deleteConfig key remove failed, config already deleted');
    }
  }

  async setCurrentConfig(id: string): Promise<void> {
    this.requireInitialized();
    Logger.info(LOG_TAG, 'setCurrentConfig id=' + id);
    try {
      await this.configStore.setCurrentProviderId(id);
    } catch (e) {
      throw this.wrapSetCurrentError(e, id);
    }
  }

  async hasApiKey(id: string): Promise<boolean> {
    this.requireInitialized();
    try {
      return await this.keyStore.hasKey(id);
    } catch (e) {
      throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
        'hasApiKey failed id=' + id);
    }
  }

  /**
   * 使用当前配置发送非流式聊天请求。
   */
  async sendChat(request: ChatRequest): Promise<ChatResponse> {
    this.requireInitialized();
    const config: ProviderConfig = await this.resolveCurrentConfigForRequest();
    const provider: AiProvider = this.resolveProvider(config);
    Logger.info(LOG_TAG, 'sendChat providerId=' + config.id + ' model=' + request.model);
    try {
      return await provider.sendChat(config, request);
    } catch (e) {
      throw this.wrapNetworkError(e, 'sendChat failed');
    }
  }

  /**
   * 使用当前配置发送流式聊天请求。
   * 同步返回 handle,异步错误通过 callbacks.onError 传递。
   */
  streamChat(request: ChatRequest, callbacks: ChatStreamCallbacks): ChatStreamHandle {
    this.requireInitialized();
    const holder: StreamHandleHolder = createStreamHandleHolder();

    this.startStreamAsync(request, callbacks, holder).then((): void => {
      // 正常完成
    }, (err: Object): void => {
      if (!holder.fired) {
        holder.fired = true;
        const error: NetworkError = err instanceof ModelServiceError
          ? toNetworkError(err)
          : createUnknownNetworkError(String(err));
        callbacks.onError(error);
      }
    });

    return holder.handle;
  }

  /**
   * 使用当前配置发送流式聊天,ModelService 自动注入 modelName。
   * 调用方只需提供 messages 和 options,无需关心具体模型名称。
   */
  streamCurrentChat(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    this.requireInitialized();
    const holder: StreamHandleHolder = createStreamHandleHolder();

    this.startStreamWithMessagesAsync(messages, options, callbacks, holder).then((): void => {
      // 正常完成
    }, (err: Object): void => {
      if (!holder.fired) {
        holder.fired = true;
        const error: NetworkError = err instanceof ModelServiceError
          ? toNetworkError(err)
          : createUnknownNetworkError(String(err));
        callbacks.onError(error);
      }
    });

    return holder.handle;
  }

  /**
   * 测试指定配置的连接(不修改正式配置)。
   * 传入 apiKey 时使用临时 alias,测试后清理。
   */
  async testConnection(config: ProviderConfig, apiKey?: string): Promise<ChatResponse> {
    this.requireInitialized();
    Logger.info(LOG_TAG, 'testConnection id=' + config.id);

    if (!isOpenAICompatibleType(config.type)) {
      throw createModelServiceError(
        ModelServiceErrorType.UnsupportedProvider,
        'testConnection unsupported type: ' + config.type
      );
    }

    const testAlias: string = TEST_ALIAS_PREFIX + config.id;
    let savedTempKey: boolean = false;

    if (apiKey !== undefined && apiKey.length > 0) {
      try {
        await this.keyStore.removeKey(testAlias);
        await this.keyStore.saveKey(testAlias, apiKey);
        savedTempKey = true;
      } catch (e) {
        throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
          'testConnection temp key save failed');
      }
    }

    const providerConfig: ProviderConfig = savedTempKey
      ? cloneConfigWithId(config, testAlias)
      : config;

    let hasKey: boolean;
    try {
      hasKey = await this.keyStore.hasKey(providerConfig.id);
    } catch (e) {
      await this.cleanupTestKey(savedTempKey, testAlias);
      throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
        'testConnection hasKey failed');
    }
    if (!hasKey) {
      await this.cleanupTestKey(savedTempKey, testAlias);
      throw createModelServiceError(
        ModelServiceErrorType.ApiKeyMissing,
        'testConnection API Key not configured for ' + config.id
      );
    }

    const testMessage: ChatMessage = createChatMessage(
      'test-msg', ChatRole.User, 'Hi', Date.now()
    );
    const testRequest: ChatRequest = {
      model: config.modelName,
      messages: [testMessage],
      temperature: config.temperature,
      topP: config.topP,
      maxTokens: 16,
      stream: false
    };

    const provider: AiProvider = this.resolveProvider(providerConfig);
    let response: ChatResponse;
    try {
      response = await provider.sendChat(providerConfig, testRequest);
    } catch (e) {
      await this.cleanupTestKey(savedTempKey, testAlias);
      throw this.wrapNetworkError(e, 'testConnection request failed');
    }

    await this.cleanupTestKey(savedTempKey, testAlias);
    return response;
  }

  // ===== 内部方法 =====

  private async startStreamAsync(
    request: ChatRequest,
    callbacks: ChatStreamCallbacks,
    holder: StreamHandleHolder
  ): Promise<void> {
    let config: ProviderConfig;
    try {
      config = await this.resolveCurrentConfigForRequest();
    } catch (e) {
      if (!holder.fired) {
        holder.fired = true;
        const err: ModelServiceError = e instanceof ModelServiceError
          ? e
          : createModelServiceError(ModelServiceErrorType.Unknown,
            'streamChat resolve config failed', String(e));
        callbacks.onError(toNetworkError(err));
      }
      return;
    }

    const provider: AiProvider = this.resolveProvider(config);
    Logger.info(LOG_TAG, 'streamChat providerId=' + config.id + ' model=' + request.model);

    const wrappedCallbacks: ChatStreamCallbacks = {
      onStart: callbacks.onStart,
      onDelta: callbacks.onDelta,
      onComplete: callbacks.onComplete,
      onError: (error: NetworkError): void => {
        holder.fired = true;
        callbacks.onError(error);
      }
    };

    const innerHandle: ChatStreamHandle = provider.streamChat(config, request, wrappedCallbacks);
    holder.setInner(innerHandle);
  }

  private async startStreamWithMessagesAsync(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks,
    holder: StreamHandleHolder
  ): Promise<void> {
    let config: ProviderConfig;
    try {
      config = await this.resolveCurrentConfigForRequest();
    } catch (e) {
      if (!holder.fired) {
        holder.fired = true;
        const err: ModelServiceError = e instanceof ModelServiceError
          ? e
          : createModelServiceError(ModelServiceErrorType.Unknown,
            'streamCurrentChat resolve config failed', String(e));
        callbacks.onError(toNetworkError(err));
      }
      return;
    }

    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      if (!holder.fired) {
        holder.fired = true;
        const err: ModelServiceError = createModelServiceError(
          ModelServiceErrorType.InvalidConfig,
          'model name is empty for config: ' + config.id
        );
        callbacks.onError(toNetworkError(err));
      }
      return;
    }

    const request: ChatRequest = {
      model: modelName,
      messages: messages,
      temperature: options.temperature,
      topP: options.topP,
      maxTokens: options.maxTokens,
      stream: options.stream
    };

    const provider: AiProvider = this.resolveProvider(config);
    Logger.info(LOG_TAG, 'streamCurrentChat providerId=' + config.id + ' model=' + request.model);

    const wrappedCallbacks: ChatStreamCallbacks = {
      onStart: callbacks.onStart,
      onDelta: callbacks.onDelta,
      onComplete: callbacks.onComplete,
      onError: (error: NetworkError): void => {
        holder.fired = true;
        callbacks.onError(error);
      }
    };

    const innerHandle: ChatStreamHandle = provider.streamChat(config, request, wrappedCallbacks);
    holder.setInner(innerHandle);
  }

  private async resolveCurrentConfigForRequest(): Promise<ProviderConfig> {
    let current: ProviderConfig | null;
    try {
      current = await this.configStore.getCurrent();
    } catch (e) {
      throw this.wrapStorageError(e, 'resolveCurrentConfig getCurrent failed');
    }
    if (current === null) {
      throw createModelServiceError(
        ModelServiceErrorType.NoCurrentConfig, 'No current provider config selected'
      );
    }
    if (!current.enabled) {
      throw createModelServiceError(
        ModelServiceErrorType.ConfigDisabled,
        'Current provider config is disabled: ' + current.id
      );
    }
    if (!isOpenAICompatibleType(current.type)) {
      throw createModelServiceError(
        ModelServiceErrorType.UnsupportedProvider,
        'Unsupported provider type: ' + current.type
      );
    }
    return current;
  }

  private resolveProvider(config: ProviderConfig): AiProvider {
    if (!isOpenAICompatibleType(config.type)) {
      throw createModelServiceError(
        ModelServiceErrorType.UnsupportedProvider,
        'Unsupported provider type: ' + config.type
      );
    }
    return this.providerFactory.create(config.type);
  }

  private requireInitialized(): void {
    if (!this.initialized) {
      throw createModelServiceError(
        ModelServiceErrorType.NotInitialized,
        'ModelService not initialized, call initialize(context) first'
      );
    }
  }

  private async rollbackConfigDelete(id: string): Promise<void> {
    try {
      await this.configStore.remove(id);
    } catch (e) {
      Logger.warn(LOG_TAG, 'rollbackConfigDelete failed id=' + id);
    }
  }

  private async cleanupTestKey(saved: boolean, alias: string): Promise<void> {
    if (!saved) {
      return;
    }
    try {
      await this.keyStore.removeKey(alias);
    } catch (e) {
      Logger.warn(LOG_TAG, 'cleanupTestKey failed alias=' + alias);
    }
  }

  private wrapStorageError(e: Object, context: string): ModelServiceError {
    if (isPreferencesError(e)) {
      const err: PreferencesError = e as PreferencesError;
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, context, this.combineCause(err.message, err.causeMessage)
      );
    }
    if (e instanceof SecureStorageError) {
      const err: SecureStorageError = e as SecureStorageError;
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, context, this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.StorageFailure, context + ': unknown error', String(e)
    );
  }

  private combineCause(message: string, causeMessage?: string): string {
    return causeMessage !== undefined ? message + ' | cause: ' + causeMessage : message;
  }

  private wrapCreateConfigError(e: Object, id: string): ModelServiceError {
    if (isPreferencesError(e)) {
      const err: PreferencesError = e as PreferencesError;
      if (err.type === PreferencesErrorType.AlreadyExists) {
        return createModelServiceError(
          ModelServiceErrorType.ConfigAlreadyExists, 'ProviderConfig already exists: ' + id
        );
      }
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, 'createConfig save failed', this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.StorageFailure, 'createConfig save failed: unknown error', String(e)
    );
  }

  private wrapUpdateConfigError(e: Object, id: string): ModelServiceError {
    if (isPreferencesError(e)) {
      const err: PreferencesError = e as PreferencesError;
      if (err.type === PreferencesErrorType.NotFound) {
        return createModelServiceError(
          ModelServiceErrorType.ConfigNotFound, 'ProviderConfig not found: ' + id
        );
      }
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, 'updateConfig failed', this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.StorageFailure, 'updateConfig failed: unknown error', String(e)
    );
  }

  private wrapKeyError(e: Object, targetType: ModelServiceErrorType, message: string): ModelServiceError {
    if (e instanceof SecureStorageError) {
      const err: SecureStorageError = e as SecureStorageError;
      return createModelServiceError(targetType, message, this.combineCause(err.message, err.causeMessage));
    }
    return createModelServiceError(targetType, message, String(e));
  }

  private wrapSetCurrentError(e: Object, id: string): ModelServiceError {
    if (isPreferencesError(e)) {
      const err: PreferencesError = e as PreferencesError;
      if (err.type === PreferencesErrorType.InvalidSelection) {
        return createModelServiceError(
          ModelServiceErrorType.ConfigNotFound, 'setCurrentConfig: config not found: ' + id
        );
      }
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, 'setCurrentConfig failed', this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.StorageFailure, 'setCurrentConfig failed: unknown error', String(e)
    );
  }

  private wrapNetworkError(e: Object, message: string): ModelServiceError {
    if (e instanceof NetworkError) {
      const err: NetworkError = e as NetworkError;
      return createModelServiceError(
        ModelServiceErrorType.NetworkFailure, message, this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.NetworkFailure, message + ': unknown error', String(e)
    );
  }
}

// ===== StreamHandleHolder =====

interface HolderState {
  inner: ChatStreamHandle | null;
}

interface StreamHandleHolder {
  fired: boolean;
  readonly handle: ChatStreamHandle;
  setInner(inner: ChatStreamHandle): void;
}

function createStreamHandleHolder(): StreamHandleHolder {
  const state: HolderState = { inner: null };
  const handle: ChatStreamHandle = new ProxyStreamHandle(state);
  return new StreamHandleHolderImpl(handle, state);
}

class ProxyStreamHandle implements ChatStreamHandle {
  private readonly state: HolderState;

  constructor(state: HolderState) {
    this.state = state;
  }

  abort(): void {
    if (this.state.inner !== null) {
      this.state.inner.abort();
    }
  }

  getState(): ChatStreamState {
    if (this.state.inner !== null) {
      return this.state.inner.getState();
    }
    return ChatStreamState.Idle;
  }
}

class StreamHandleHolderImpl implements StreamHandleHolder {
  fired: boolean = false;
  readonly handle: ChatStreamHandle;
  private readonly state: HolderState;

  constructor(handle: ChatStreamHandle, state: HolderState) {
    this.handle = handle;
    this.state = state;
  }

  setInner(inner: ChatStreamHandle): void {
    this.state.inner = inner;
  }
}
