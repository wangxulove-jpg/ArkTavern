/**
 * AppServices 应用服务组装根
 *
 * 最小组合根,在应用启动时使用稳定 Context 组装全部底层依赖。
 * 页面与 ViewModel 通过 AppServices.getInstance().modelService 访问业务能力,
 * 不自行 new 全套依赖。
 *
 * 设计原则:
 * - 不实现复杂 DI 框架,仅做静态组装
 * - 不保存 Context 引用(仅用于初始化,初始化后丢弃)
 * - 不持有可变业务状态(仅持有服务实例引用)
 * - 不作为 Service Locator:只暴露 modelService,不提供通用 get(name)
 * - 初始化幂等:重复调用返回同一 Promise
 *
 * 生命周期:
 * - EntryAbility.onCreate 调用 AppServices.initialize(context) 启动初始化
 * - 页面 aboutToAppear 调用 AppServices.whenReady() 等待初始化完成
 * - AppServices.getInstance() 在初始化完成后返回实例
 */

import { common } from '@kit.AbilityKit';
import { AppPreferences } from '../storage/AppPreferences';
import { ProviderConfigStore } from '../storage/ProviderConfigStore';
import { AssetStoreKeyStore } from '../storage/AssetStoreKeyStore';
import { ProviderKeyStore } from '../storage/ProviderKeyStore';
import { CharacterStore } from '../storage/CharacterStore';
import { CharacterAssetStore } from '../storage/CharacterAssetStore';
import { LorebookStore } from '../storage/LorebookStore';
import { CharacterService } from './CharacterService';
import { LorebookService } from './LorebookService';
import { MacroReplacer } from './MacroReplacer';
import { PromptBuilder } from './PromptBuilder';
import { TokenCounter } from './TokenCounter';
import { HistoryTrimmer } from './HistoryTrimmer';
import { ChatService } from './ChatService';
import { ModelService } from './ModelService';
import { DefaultProviderFactory } from './ProviderFactory';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'AppServices';

/**
 * 应用服务组装根。
 * 仅暴露 modelService 供上层使用,不提供通用 Service Locator 查询。
 * ChatService 由 ChatPage 按页面生命周期创建,不在应用级保存单例。
 */
export class AppServices {
  private static instance: AppServices | null = null;
  private static readyPromise: Promise<void> | null = null;

  /** ModelService 业务编排服务(唯一对外暴露的服务) */
  readonly modelService: ModelService;
  /** CharacterService 角色服务 */
  readonly characterService: CharacterService;
  /** LorebookService 世界书服务 */
  readonly lorebookService: LorebookService;
  /** PromptBuilder 提示词构建器 */
  readonly promptBuilder: PromptBuilder;
  /** TokenCounter 上下文 Token 估算服务(不对页面公开) */
  private readonly tokenCounter: TokenCounter;
  /** HistoryTrimmer 历史裁剪服务(不对页面公开) */
  private readonly historyTrimmer: HistoryTrimmer;

  /**
   * 私有构造,组装全部依赖。
   * 不保存 Context,仅用于初始化 Preferences。
   */
  private constructor() {
    const prefs: AppPreferences = new AppPreferences();
    const configStore: ProviderConfigStore = new ProviderConfigStore(prefs);
    const assetKeyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
    const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(assetKeyStore);
    const factory: DefaultProviderFactory = new DefaultProviderFactory(providerKeyStore);
    this.modelService = new ModelService(configStore, providerKeyStore, factory);
    const characterStore: CharacterStore = new CharacterStore();
    const characterAssetStore: CharacterAssetStore = new CharacterAssetStore();
    this.characterService = new CharacterService(characterStore, characterAssetStore);
    const lorebookStore: LorebookStore = new LorebookStore();
    this.lorebookService = new LorebookService(lorebookStore);
    const macroReplacer: MacroReplacer = new MacroReplacer();
    this.promptBuilder = new PromptBuilder(this.lorebookService, macroReplacer);
    this.tokenCounter = new TokenCounter();
    this.historyTrimmer = new HistoryTrimmer(this.tokenCounter);
  }

  /**
   * 初始化应用服务。
   * 幂等:重复调用返回同一 Promise。
   * 初始化失败时清理实例,允许后续重试。
   *
   * @param context ApplicationContext 或 UIAbility Context(稳定 Context,不保存)
   * @returns 初始化完成的 Promise
   */
  static initialize(context: common.Context): Promise<void> {
    if (AppServices.readyPromise !== null) {
      return AppServices.readyPromise;
    }
    Logger.info(LOG_TAG, 'initialize start');
    const services: AppServices = new AppServices();
    AppServices.instance = services;
    AppServices.readyPromise = services.modelService.initialize(context)
      .then((): Promise<void> => services.characterService.initialize(context))
      .then((): Promise<void> => services.lorebookService.initialize(context))
      .then((): void => {
        Logger.info(LOG_TAG, 'initialize ok');
      })
      .catch((e: Object): void => {
        Logger.error(LOG_TAG, 'initialize failed: ' + (e as Error).message);
        AppServices.instance = null;
        AppServices.readyPromise = null;
        throw new Error('AppServices initialize failed: ' + (e as Error).message);
      });
    return AppServices.readyPromise;
  }

  /**
   * 等待初始化完成。
   * 页面在 aboutToAppear 中调用此方法,确保 modelService 可用。
   *
   * @returns 初始化完成的 Promise
   * @throws Error 当未调用 initialize 时
   */
  static whenReady(): Promise<void> {
    if (AppServices.readyPromise === null) {
      return Promise.reject(new Error('AppServices not initialized, call initialize(context) first'));
    }
    return AppServices.readyPromise;
  }

  /**
   * 获取已初始化的 AppServices 实例。
   * 必须在 whenReady() 完成后调用。
   *
   * @returns AppServices 实例
   * @throws Error 当未初始化时
   */
  static getInstance(): AppServices {
    if (AppServices.instance === null) {
      throw new Error('AppServices not initialized');
    }
    return AppServices.instance;
  }

  /**
   * 判断是否已开始初始化(不代表已完成)。
   * @returns 已调用 initialize 返回 true
   */
  static isStarted(): boolean {
    return AppServices.instance !== null;
  }

  /**
   * 获取 ModelService 实例。
   */
  static getModelService(): ModelService {
    return AppServices.getInstance().modelService;
  }

  /**
   * 获取 CharacterService 实例。
   */
  static getCharacterService(): CharacterService {
    return AppServices.getInstance().characterService;
  }

  /**
   * 获取 LorebookService 实例。
   */
  static getLorebookService(): LorebookService {
    return AppServices.getInstance().lorebookService;
  }

  /**
   * 创建新的 ChatService 实例。
   * 每次 ChatPage 进入时调用,保证生命周期独立。
   * 内部完成 ModelService、LorebookService、PromptBuilder、TokenCounter、HistoryTrimmer 的依赖注入。
   *
   * @returns 新创建的 ChatService 实例
   */
  static createChatService(): ChatService {
    const services: AppServices = AppServices.getInstance();
    return new ChatService(
      services.modelService,
      services.lorebookService,
      services.promptBuilder,
      services.tokenCounter,
      services.historyTrimmer
    );
  }
}
