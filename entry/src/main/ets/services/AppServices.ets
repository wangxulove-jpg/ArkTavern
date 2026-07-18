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
import { CharacterSelectionStore } from '../storage/CharacterSelectionStore';
import { CharacterAssetStore } from '../storage/CharacterAssetStore';
import { LorebookStore } from '../storage/LorebookStore';
import { LorebookSelectionStore } from '../storage/LorebookSelectionStore';
import { CharacterService } from './CharacterService';
import { CharacterMigrationService } from './CharacterMigrationService';
import { LorebookService } from './LorebookService';
import { LorebookMigrationService } from './LorebookMigrationService';
import { MacroReplacer } from './MacroReplacer';
import { PromptBuilder } from './PromptBuilder';
import { TokenCounter } from './TokenCounter';
import { HistoryTrimmer } from './HistoryTrimmer';
import { DbHelper } from '../database/DbHelper';
import { ChatRepository } from '../repositories/ChatRepository';
import { MessageRepository } from '../repositories/MessageRepository';
import { MessageSwipeRepository } from '../repositories/MessageSwipeRepository';
import { ChatPersistenceOperations } from '../repositories/ChatPersistenceOperations';
import { CharacterRepository } from '../repositories/CharacterRepository';
import { LorebookRepository } from '../repositories/LorebookRepository';
import { PromptPresetRepository } from '../repositories/PromptPresetRepository';
import { ConversationBranchRepository } from '../repositories/ConversationBranchRepository';
import { PromptPresetSelectionStore } from '../storage/PromptPresetSelectionStore';
import { PromptPresetService } from './PromptPresetService';
import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { ConversationBranchPersistenceService } from './ConversationBranchPersistenceService';
import { ChatService } from './ChatService';
import { ChatPersistenceService } from './ChatPersistenceService';
import { ModelService } from './ModelService';
import { DefaultProviderFactory } from './ProviderFactory';
import { PromptPresetListViewModel } from '../viewmodels/PromptPresetListViewModel';
import { PromptPresetEditViewModel } from '../viewmodels/PromptPresetEditViewModel';
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
  /** DbHelper 数据库底座(不对页面公开) */
  private readonly dbHelper: DbHelper;
  /** ChatRepository 聊天仓储(不对页面公开) */
  private readonly chatRepository: ChatRepository;
  /** MessageRepository 消息仓储(不对页面公开) */
  private readonly messageRepository: MessageRepository;
  /** ChatPersistenceOperations 联合事务操作(不对页面公开) */
  private readonly chatPersistenceOperations: ChatPersistenceOperations;
  /** ChatPersistenceService 聊天持久化协调服务(不对页面公开) */
  private readonly chatPersistenceService: ChatPersistenceService;
  /** MessageSwipeRepository 消息候选仓储(不对页面公开) */
  private readonly messageSwipeRepository: MessageSwipeRepository;
  /** MessageSwipePersistenceService 消息候选持久化服务(不对页面公开) */
  private readonly messageSwipePersistenceService: MessageSwipePersistenceService;
  /** CharacterRepository 角色仓储(不对页面公开) */
  private readonly characterRepository: CharacterRepository;
  /** LorebookRepository 世界书仓储(不对页面公开) */
  private readonly lorebookRepository: LorebookRepository;
  /** CharacterSelectionStore 当前角色选择(不对页面公开) */
  private readonly characterSelectionStore: CharacterSelectionStore;
  /** LorebookSelectionStore 当前世界书选择(不对页面公开) */
  private readonly lorebookSelectionStore: LorebookSelectionStore;
  /** AppPreferences(不对页面公开) */
  private readonly appPreferences: AppPreferences;
  /** CharacterMigrationService(不对页面公开) */
  private readonly characterMigrationService: CharacterMigrationService;
  /** LorebookMigrationService(不对页面公开) */
  private readonly lorebookMigrationService: LorebookMigrationService;
  /** CharacterStore(仅用于迁移,不对页面公开) */
  private readonly characterStore: CharacterStore;
  /** LorebookStore(仅用作迁移源,不对页面公开) */
  private readonly lorebookStore: LorebookStore;
  /** PromptPresetRepository(不对页面公开) */
  private readonly promptPresetRepository: PromptPresetRepository;
  /** PromptPresetSelectionStore(不对页面公开) */
  private readonly promptPresetSelectionStore: PromptPresetSelectionStore;
  /** PromptPresetService(不对页面公开,T-6.1B 接入 Chat 后暴露) */
  private readonly promptPresetService: PromptPresetService;
  /** ConversationBranchRepository 对话分支仓储(不对页面公开,T-6.4A) */
  private readonly conversationBranchRepository: ConversationBranchRepository;
  /** ConversationBranchPersistenceService 对话分支持久化服务(不对页面公开,T-6.4A) */
  private readonly conversationBranchPersistenceService: ConversationBranchPersistenceService;

  /**
   * 私有构造,组装全部依赖。
   * 不保存 Context,仅用于初始化 Preferences。
   */
  private constructor() {
    this.appPreferences = new AppPreferences();
    const configStore: ProviderConfigStore = new ProviderConfigStore(this.appPreferences);
    const assetKeyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
    const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(assetKeyStore);
    const factory: DefaultProviderFactory = new DefaultProviderFactory(providerKeyStore);
    this.modelService = new ModelService(configStore, providerKeyStore, factory);
    this.characterStore = new CharacterStore();
    const characterAssetStore: CharacterAssetStore = new CharacterAssetStore();
    this.characterSelectionStore = new CharacterSelectionStore();
    this.dbHelper = new DbHelper();
    // CharacterRepository 使用与 Chat 相同的 DbHelper
    this.characterRepository = new CharacterRepository(this.dbHelper);
    this.characterService = new CharacterService(
      this.characterRepository,
      this.characterSelectionStore,
      characterAssetStore
    );
    this.lorebookSelectionStore = new LorebookSelectionStore(this.appPreferences);
    this.characterMigrationService = new CharacterMigrationService(
      this.characterStore,
      this.characterRepository,
      this.characterSelectionStore,
      this.appPreferences
    );
    // Lorebook 仅作迁移源,由 AppServices 直接管理
    this.lorebookStore = new LorebookStore();
    // LorebookRepository 使用同一 DbHelper
    this.lorebookRepository = new LorebookRepository(this.dbHelper);
    // LorebookService 使用 Repository + SelectionStore
    this.lorebookService = new LorebookService(
      this.lorebookRepository,
      this.lorebookSelectionStore
    );
    this.lorebookMigrationService = new LorebookMigrationService(
      this.lorebookStore,
      this.lorebookRepository,
      this.lorebookSelectionStore,
      this.appPreferences
    );
    // PromptPreset 领域组装
    this.promptPresetRepository = new PromptPresetRepository(this.dbHelper);
    this.promptPresetSelectionStore = new PromptPresetSelectionStore(this.appPreferences);
    this.promptPresetService = new PromptPresetService(
      this.promptPresetRepository,
      this.promptPresetSelectionStore
    );
    const macroReplacer: MacroReplacer = new MacroReplacer();
    this.promptBuilder = new PromptBuilder(this.lorebookService, macroReplacer);
    this.tokenCounter = new TokenCounter();
    this.historyTrimmer = new HistoryTrimmer(this.tokenCounter);
    // 持久化层组合:全部 Repository 共享同一 DbHelper 实例
    this.chatRepository = new ChatRepository(this.dbHelper);
    this.messageRepository = new MessageRepository(this.dbHelper);
    this.messageSwipeRepository = new MessageSwipeRepository(this.dbHelper);
    // T-6.4A: ConversationBranch 服务(单例,共享同一 DbHelper)
    this.conversationBranchRepository = new ConversationBranchRepository(this.dbHelper);
    this.conversationBranchPersistenceService = new ConversationBranchPersistenceService(
      this.dbHelper,
      this.conversationBranchRepository,
      this.messageRepository,
      this.messageSwipeRepository
    );
    this.chatPersistenceOperations = new ChatPersistenceOperations(
      this.dbHelper,
      this.chatRepository,
      this.messageRepository,
      this.messageSwipeRepository,
      this.conversationBranchPersistenceService
    );
    this.chatPersistenceService = new ChatPersistenceService(
      this.dbHelper,
      this.chatRepository,
      this.messageRepository,
      this.chatPersistenceOperations,
      this.conversationBranchPersistenceService
    );
    this.messageSwipePersistenceService = new MessageSwipePersistenceService(
      this.dbHelper,
      this.messageRepository,
      this.messageSwipeRepository,
      this.conversationBranchPersistenceService
    );
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
      .then((): Promise<void> => services.appPreferences.initialize(context))
      .then((): Promise<void> => services.dbHelper.initialize(context))
      .then((): Promise<void> => services.characterService.initialize(context))
      .then((): Promise<void> => services.characterStore.initialize(context))
      .then(async (): Promise<void> => {
        await services.characterMigrationService.migrateIfNeeded();
      })
      .then((): Promise<void> => services.lorebookStore.initialize(context))
      .then(async (): Promise<void> => {
        await services.lorebookMigrationService.migrateIfNeeded();
      })
      .then((): Promise<void> => services.lorebookService.initialize())
      .then((): Promise<void> => services.promptPresetService.initialize())
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
   * 获取 PromptPresetService 实例(T-6.1B 接入 Chat 后使用)。
   */
  static getPromptPresetService(): PromptPresetService {
    return AppServices.getInstance().promptPresetService;
  }

  /**
   * 获取 ConversationBranchPersistenceService 实例(T-6.4B-1.1)。
   * 用于 BranchMapPage 加载 Branch 列表和切换 Active Branch,无需创建完整 ChatService。
   */
  static getBranchPersistenceService(): ConversationBranchPersistenceService {
    return AppServices.getInstance().conversationBranchPersistenceService;
  }

  /**
   * 创建新的 ChatService 实例。
   * 每次 ChatPage 进入时调用,保证生命周期独立。
   * 内部完成 ModelService、LorebookService、PromptBuilder、TokenCounter、HistoryTrimmer、
   * ChatPersistenceService 的依赖注入。
   *
   * 持久化服务为应用级共享实例(自身无页面状态),所有 ChatService 共用。
   * DbHelper 必须在 initialize() 完成后才允许 ChatService 加载会话,
   * 调用方需通过 AppServices.whenReady() 等待初始化完成后再创建 ChatService。
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
      services.historyTrimmer,
      services.chatPersistenceService,
      services.promptPresetService,
      services.messageSwipePersistenceService,
      services.conversationBranchPersistenceService
    );
  }

  /**
   * 创建 PromptPresetListViewModel 实例。
   */
  static createPromptPresetListViewModel(): PromptPresetListViewModel {
    const services: AppServices = AppServices.getInstance();
    return new PromptPresetListViewModel(services.promptPresetService);
  }

  /**
   * 创建 PromptPresetEditViewModel 实例。
   * @param presetId 编辑已有 Preset 时传入 ID,新建时传入 undefined
   */
  static createPromptPresetEditViewModel(presetId?: string): PromptPresetEditViewModel {
    const services: AppServices = AppServices.getInstance();
    return new PromptPresetEditViewModel(services.promptPresetService);
  }
}