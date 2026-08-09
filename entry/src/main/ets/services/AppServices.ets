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
import { RecentMessageSelector } from './RecentMessageSelector';
import { DbHelper } from '../database/DbHelper';
import { DatabaseError } from '../models/DatabaseError';
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
import { ChatMemoryRepository } from '../repositories/ChatMemoryRepository';
import { MemoryPersistenceService } from './MemoryPersistenceService';
import { MemoryService } from './MemoryService';
import { ForkChatService } from './ForkChatService';
import { ContextBudgetService } from './ContextBudgetService';
import { ChatService } from './ChatService';
import { ChatPersistenceService } from './ChatPersistenceService';
import { ChatBackgroundService } from './ChatBackgroundService';
import { ModelService } from './ModelService';
import { DefaultProviderFactory } from './ProviderFactory';
import { HttpClient } from '../network/core/HttpClient';
import { HarmonyHttpClient } from '../network/core/HarmonyHttpClient';
import { MarketCacheStore } from './market/MarketCacheStore';
import { MarketImportedMapStore } from './market/MarketImportedMapStore';
import { MarketService } from './market/MarketService';
import { MarketImportService } from './market/MarketImportService';
import { MarketTranslationService } from './market/MarketTranslationService';
import { PromptPresetListViewModel } from '../viewmodels/PromptPresetListViewModel';
import { PromptPresetEditViewModel } from '../viewmodels/PromptPresetEditViewModel';
import { ChatSessionListViewModel } from '../viewmodels/ChatSessionListViewModel';
import { ChatTextStyleSettings } from '../utils/ChatTextStyleSettings';
import { ChatArchiveService } from './ChatArchiveService';
import { ChatArchiveImportService } from './ChatArchiveImportService';
import { ChatArchiveViewModel } from '../viewmodels/ChatArchiveViewModel';
import { ChatParticipantRepository } from '../repositories/ChatParticipantRepository';
import { GroupConversationPersistenceService } from './groupchat/GroupConversationPersistenceService';
import { GroupConversationMessageService } from './groupchat/GroupConversationMessageService';
import { GroupRoundCoordinator } from './groupchat/GroupRoundCoordinator';
import { GroupPromptAssembler } from './groupchat/GroupPromptAssembler';
import { GroupChatRuntimeService } from './groupchat/GroupChatRuntimeService';
import { GroupRuntimeRegistry } from './groupchat/GroupRuntimeRegistry';
import { GroupCharacterMemoryRepository } from '../repositories/groupchat/GroupCharacterMemoryRepository';
import { GroupCharacterRelationshipMemoryRepository } from '../repositories/groupchat/GroupCharacterRelationshipMemoryRepository';
import { GroupCharacterMemoryService } from './groupchat/GroupCharacterMemoryService';
import { GroupCharacterSelfSummaryService } from './groupchat/GroupCharacterSelfSummaryService';
import { GroupCharacterRelationshipMemoryService } from './groupchat/GroupCharacterRelationshipMemoryService';
import { GroupCharacterRelationshipSummaryService } from './groupchat/GroupCharacterRelationshipSummaryService';
import { GroupPromptInspectionStore } from './groupchat/GroupPromptInspectionStore';
import { GroupCharacterMemorySelector } from './groupchat/GroupCharacterMemorySelector';
import { WorldRepository } from '../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../repositories/world/WorldLocationEdgeRepository';
import { WorldCharacterInstanceRepository } from '../repositories/world/WorldCharacterInstanceRepository';
import { WorldEventRepository } from '../repositories/world/WorldEventRepository';
import { WorldSceneRepository } from '../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../repositories/world/WorldSceneMessageRepository';
import { WorldCharacterMemoryRepository } from '../repositories/world/WorldCharacterMemoryRepository';
import { WorldCharacterMemoryEntryRepository } from '../repositories/world/WorldCharacterMemoryEntryRepository';
import { WorldPlayerProfileRepository } from '../repositories/world/WorldPlayerProfileRepository';
import { WorldConversationSessionRepository } from '../repositories/world/WorldConversationSessionRepository';
import { WorldSessionSummaryRepository } from '../repositories/world/WorldSessionSummaryRepository';
import { WorldLocationMapPlacementRepository } from '../repositories/world/WorldLocationMapPlacementRepository';
import { WorldCharacterLocationHistoryRepository } from '../repositories/world/WorldCharacterLocationHistoryRepository';
import { WorldStateService } from './world/WorldStateService';
import { WorldSceneService } from './world/WorldSceneService';
import { WorldCharacterMemoryService } from './world/WorldCharacterMemoryService';
import { WorldCharacterMemoryStoreService } from './world/WorldCharacterMemoryStoreService';
import { WorldCharacterMemoryPromptAssembler } from './world/WorldCharacterMemoryPromptAssembler';
import { WorldCharacterMemoryGenerationService } from './world/WorldCharacterMemoryGenerationService';
import { WorldCharacterMovementService } from './world/WorldCharacterMovementService';
import { WorldEventExtractionRunRepository, WorldEventEntryRepository } from '../repositories/world/WorldEventExtractionRepository';
import { WorldKnownEventEntryRepository } from '../repositories/world/WorldKnownEventEntryRepository';
import { WorldDirectionalRelationshipEntryRepository } from '../repositories/world/WorldDirectionalRelationshipEntryRepository';
import { WorldSessionPostProcessRunRepository } from '../repositories/world/WorldSessionPostProcessRunRepository';
import { WorldEventStoreService } from './world/WorldEventStoreService';
import { WorldKnownEventStoreService } from './world/WorldKnownEventStoreService';
import { WorldDirectionalRelationshipStoreService } from './world/WorldDirectionalRelationshipStoreService';
import { WorldSessionPostProcessRunStoreService } from './world/WorldSessionPostProcessRunStoreService';
import { WorldSessionPostProcessingOrchestrator } from './world/WorldSessionPostProcessingOrchestrator';
import { WorldDirectionalRelationshipPromptAssembler } from './world/WorldDirectionalRelationshipPromptAssembler';
import { WorldDirectionalRelationshipGenerationService } from './world/WorldDirectionalRelationshipGenerationService';
import { WorldEventExtractionPromptAssembler } from './world/WorldEventExtractionPromptAssembler';
import { WorldEventExtractionGenerationService } from './world/WorldEventExtractionGenerationService';
import { WorldPerceptionService } from './world/WorldPerceptionService';
import { WorldConversationSessionService } from './world/WorldConversationSessionService';
import { WorldSessionSummaryStoreService } from './world/WorldSessionSummaryStoreService';
import { WorldSessionSummaryPromptAssembler } from './world/WorldSessionSummaryPromptAssembler';
import { WorldSessionSummaryGenerationService } from './world/WorldSessionSummaryGenerationService';
import { WorldCrossSessionContextService } from './world/WorldCrossSessionContextService';
import { WorldMapInteractionService } from './world/WorldMapInteractionService';
import { WorldSceneLaunchService } from './world/WorldSceneLaunchService';
import { WorldSceneMessageService } from './world/WorldSceneMessageService';
import { WorldRuntimeRegistry } from './world/WorldRuntimeRegistry';
import { WorldScenePromptAssembler } from './world/WorldScenePromptAssembler';
import { WorldSceneRuntimeService } from './world/WorldSceneRuntimeService';
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
  /** RecentMessageSelector 最近原始消息窗口选择器(v8.3 Phase 2,不对页面公开) */
  private readonly recentMessageSelector: RecentMessageSelector;
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
  /** ChatMemoryRepository 长期记忆仓储(不对页面公开,v8) */
  private readonly chatMemoryRepository: ChatMemoryRepository;
  /** MemoryPersistenceService 长期记忆持久化服务(不对页面公开,v8) */
  private readonly memoryPersistenceService: MemoryPersistenceService;
  /** MemoryService 长期记忆业务服务(增量总结、过期标记,v8) */
  private readonly memoryService: MemoryService;
  /** ForkChatService 从分支创建独立对话服务(不对页面公开,v8) */
  private readonly forkChatService: ForkChatService;
  /** ContextBudgetService per-chat 上下文预算服务(v8.1) */
  private contextBudgetService: ContextBudgetService | null = null;
  /** ChatBackgroundService 聊天背景图服务(导入图片 + 模糊度 + 暗化)。在 initialize 中创建。 */
  private chatBackgroundService: ChatBackgroundService | null = null;
  /** 市场服务(Chub 公共只读浏览 + 搜索 + 详情 + 下载) */
  readonly marketService: MarketService;
  /** 市场导入服务(需要 context,在 initialize 中创建) */
  private marketImportService: MarketImportService | null = null;
  /** 市场翻译服务(复用 ModelService,在 initialize 中创建) */
  private marketTranslationService: MarketTranslationService | null = null;
  /** 应用 Context,用于 ChatBackgroundService 等需要 filesDir 的服务 */
  private appContext: common.Context | null = null;
  
  /** ChatTextStyleSettings 聊天文本样式设置(v11 富文本) */
  readonly chatTextStyleSettings: ChatTextStyleSettings;
  /** ChatArchiveService 聊天归档导出服务(T-CHAT.1) */
  private chatArchiveService: ChatArchiveService | null = null;
  /** ChatArchiveImportService 聊天归档导入服务(T-CHAT.1) */
  private chatArchiveImportService: ChatArchiveImportService | null = null;
  /** ChatParticipantRepository 多人聊天参与者仓储(G-DATA-1A,不对页面公开) */
  private readonly chatParticipantRepository: ChatParticipantRepository;
  /** GroupConversationPersistenceService 多人聊天持久化服务(G-DATA-1A,不对页面公开) */
  private readonly groupConversationPersistenceService: GroupConversationPersistenceService;
  /** GroupConversationMessageService 多人聊天消息服务(G-RUNTIME-1A,不对页面公开) */
  private readonly groupConversationMessageService: GroupConversationMessageService;
  /** GroupRoundCoordinator 多人聊天轮次协调器(G-RUNTIME-1A,不对页面公开) */
  private readonly groupRoundCoordinator: GroupRoundCoordinator;
  /** GroupPromptAssembler 多人聊天单角色 Prompt 构建器(G-RUNTIME-1B,不对页面公开) */
  private readonly groupPromptAssembler: GroupPromptAssembler;
  /** GroupChatRuntimeService 多人聊天运行时服务(G-RUNTIME-1B,不对页面公开) */
  private readonly groupChatRuntimeService: GroupChatRuntimeService;
  /** GroupRuntimeRegistry 多人聊天运行注册表(G-RUNTIME-1D 应用级运行锁,不对页面公开) */
  private readonly groupRuntimeRegistry: GroupRuntimeRegistry;
  /** GroupCharacterMemoryRepository 多人聊天角色记忆仓储(G-MEMORY-1A,记忆 CRUD) */
  private readonly groupCharacterMemoryRepository: GroupCharacterMemoryRepository;
  /** GroupCharacterMemoryService 多人聊天角色记忆业务服务(G-MEMORY-1A,记忆唯一正式写入口) */
  private readonly groupCharacterMemoryService: GroupCharacterMemoryService;
  /** GroupCharacterSelfSummaryService 多人角色自身发言手动总结服务(G-MEMORY-AUTO-1A) */
  private readonly groupCharacterSelfSummaryService: GroupCharacterSelfSummaryService;
  /** GroupCharacterRelationshipMemoryRepository 多人角色关系记忆仓储(G-MEMORY-AUTO-1B,关系记忆 CRUD) */
  private readonly groupCharacterRelationshipMemoryRepository: GroupCharacterRelationshipMemoryRepository;
  /** GroupCharacterRelationshipMemoryService 多人角色关系记忆业务服务(G-MEMORY-AUTO-1B,关系记忆唯一正式写入口) */
  private readonly groupCharacterRelationshipMemoryService: GroupCharacterRelationshipMemoryService;
  /** GroupCharacterRelationshipSummaryService 多人角色关系与经历手动总结服务(G-MEMORY-AUTO-1B) */
  private readonly groupCharacterRelationshipSummaryService: GroupCharacterRelationshipSummaryService;

  /** G-CONTEXT-INSPECTOR-1: Prompt 诊断快照内存存储 */
  private readonly groupPromptInspectionStore: GroupPromptInspectionStore;
  /** WorldRepository 世界仓储(W-DATA-1A,不对页面公开) */
  private readonly worldRepository: WorldRepository;
  /** WorldLocationRepository 世界地点仓储(W-DATA-1A,不对页面公开) */
  private readonly worldLocationRepository: WorldLocationRepository;
  /** WorldLocationEdgeRepository 世界地点边仓储(W-DATA-1A,不对页面公开) */
  private readonly worldLocationEdgeRepository: WorldLocationEdgeRepository;
  /** WorldCharacterInstanceRepository 世界角色实例仓储(W-DATA-1A,不对页面公开) */
  private readonly worldCharacterInstanceRepository: WorldCharacterInstanceRepository;
  /** WorldEventRepository 世界事件仓储(W-DATA-1A,不对页面公开) */
  private readonly worldEventRepository: WorldEventRepository;
  /** WorldSceneRepository 世界场景仓储(W-SCENE-1A,不对页面公开) */
  private readonly worldSceneRepository: WorldSceneRepository;
  /** WorldSceneMessageRepository 世界场景消息仓储(W-SCENE-1A,不对页面公开) */
  private readonly worldSceneMessageRepository: WorldSceneMessageRepository;
  /** WorldCharacterMemoryRepository 世界角色记忆仓储(W-MEMORY-1A,记忆 CRUD) */
  private readonly worldCharacterMemoryRepository: WorldCharacterMemoryRepository;
  /** WorldCharacterMemoryEntryRepository 世界角色主观记忆条目仓储(W5B1,记忆条目 CRUD) */
  private readonly worldCharacterMemoryEntryRepository: WorldCharacterMemoryEntryRepository;
  /** WorldPlayerProfileRepository 世界玩家档案仓储(W1A-WORLD-CORE-STORE) */
  private readonly worldPlayerProfileRepository: WorldPlayerProfileRepository;
  /** WorldConversationSessionRepository 世界会话仓储(W1A-WORLD-CORE-STORE) */
  private readonly worldConversationSessionRepository: WorldConversationSessionRepository;
  /** WorldSessionSummaryRepository 世界会话摘要仓储(W5A1-WORLD-SESSION-SUMMARY-STORE) */
  private readonly worldSessionSummaryRepository: WorldSessionSummaryRepository;
  /** WorldLocationMapPlacementRepository 世界地点地图放置仓储(W1C-WORLD-MAP-CONTRACT) */
  private readonly worldLocationMapPlacementRepository: WorldLocationMapPlacementRepository;
  /** WorldCharacterLocationHistoryRepository 世界角色地点历史仓储(W4A,地点变更历史 CRUD) */
  private readonly worldCharacterLocationHistoryRepository: WorldCharacterLocationHistoryRepository;
  /** WorldStateService 世界模式状态业务服务(W-DATA-1B,世界基础数据唯一正式写入口) */
  private readonly worldStateService: WorldStateService;
  /** WorldSceneService 世界场景业务服务(W-SCENE-1B,场景和场景消息唯一正式写入口) */
  private readonly worldSceneService: WorldSceneService;
  /** WorldCharacterMemoryService 世界角色记忆业务服务(W-MEMORY-1A,记忆唯一正式写入口) */
  private readonly worldCharacterMemoryService: WorldCharacterMemoryService;
  /** WorldCharacterMemoryStoreService 世界角色主观记忆存储服务(W5B1,记忆条目唯一正式写入口) */
  private readonly worldCharacterMemoryStoreService: WorldCharacterMemoryStoreService;
  /** WorldCharacterMemoryPromptAssembler 世界角色主观记忆Prompt构建器(W5B2) */
  private readonly worldCharacterMemoryPromptAssembler: WorldCharacterMemoryPromptAssembler;
  /** WorldCharacterMemoryGenerationService 世界角色主观记忆AI生成服务(W5B2) */
  private readonly worldCharacterMemoryGenerationService: WorldCharacterMemoryGenerationService;
  /** WorldCharacterMovementService 世界角色移动业务服务(W4A,位置变更唯一正式写入口) */
  private readonly worldCharacterMovementService: WorldCharacterMovementService;
  /** WorldPerceptionService 世界感知服务(W4B,当前客观共处状态查询) */
  private readonly worldPerceptionService: WorldPerceptionService;
  /** WorldConversationSessionService 世界会话生命周期服务(W1B2,会话唯一正式写入口) */
  private readonly worldConversationSessionService: WorldConversationSessionService;
  /** WorldMapInteractionService 地图交互业务服务(W1D,地图快照加载+放置保存) */
  private readonly worldMapInteractionService: WorldMapInteractionService;
  /** WorldSceneLaunchService 场景启动业务服务(W2B1,Scene+Session 原子创建) */
  private readonly worldSceneLaunchService: WorldSceneLaunchService;
  /** WorldSceneMessageService 世界场景消息业务服务(W3A1,Runtime唯一正式消息写入入口) */
  private readonly worldSceneMessageService: WorldSceneMessageService;
  /** WorldRuntimeRegistry 世界运行时操作注册表(W3A1,单例,运行中操作管理) */
  private readonly worldRuntimeRegistry: WorldRuntimeRegistry;
  /** WorldScenePromptAssembler 世界场景Prompt构建器(W3A1,单角色Prompt装配) */
  private readonly worldScenePromptAssembler: WorldScenePromptAssembler;
  /** WorldSceneRuntimeService 世界场景运行时服务(W3A1,单角色AI生成核心) */
  private readonly worldSceneRuntimeService: WorldSceneRuntimeService;
  /** WorldSessionSummaryStoreService 世界会话摘要存储服务(W5A1,摘要唯一正式写入口) */
  private readonly worldSessionSummaryStoreService: WorldSessionSummaryStoreService;
  /** WorldSessionSummaryPromptAssembler 世界会话摘要Prompt构建器(W5A2) */
  private readonly worldSessionSummaryPromptAssembler: WorldSessionSummaryPromptAssembler;
  /** WorldSessionSummaryGenerationService 世界会话摘要生成服务(W5A2) */
  private readonly worldSessionSummaryGenerationService: WorldSessionSummaryGenerationService;
  /** WorldCrossSessionContextService 世界跨Session上下文选择器(W5C1) */
  private readonly worldCrossSessionContextService: WorldCrossSessionContextService;
  /** WorldEventExtractionRunRepository 世界事件提取运行仓储(W6A1) */
  private readonly worldEventExtractionRunRepository: WorldEventExtractionRunRepository;
  /** WorldEventEntryRepository 世界事件条目仓储(W6A1) */
  private readonly worldEventEntryRepository: WorldEventEntryRepository;
  /** WorldKnownEventEntryRepository 世界已知事件条目仓储(W6B1) */
  private readonly worldKnownEventEntryRepository: WorldKnownEventEntryRepository;
  /** WorldDirectionalRelationshipEntryRepository 世界方向性关系条目仓储(W6C1) */
  private readonly worldDirectionalRelationshipEntryRepository: WorldDirectionalRelationshipEntryRepository;
  /** WorldSessionPostProcessRunRepository 世界会话后处理运行仓储(W7A) */
  private readonly worldSessionPostProcessRunRepository: WorldSessionPostProcessRunRepository;
  /** WorldEventStoreService 世界事件提取存储服务(W6A1) */
  private readonly worldEventStoreService: WorldEventStoreService;
  /** WorldEventExtractionPromptAssembler 世界事件提取Prompt构建器(W6A2) */
  private readonly worldEventExtractionPromptAssembler: WorldEventExtractionPromptAssembler;
  /** WorldEventExtractionGenerationService 世界事件提取AI生成服务(W6A2) */
  private readonly worldEventExtractionGenerationService: WorldEventExtractionGenerationService;
  /** WorldKnownEventStoreService 世界已知事件存储服务(W6B1) */
  private readonly worldKnownEventStoreService: WorldKnownEventStoreService;
  /** WorldDirectionalRelationshipStoreService 世界方向性关系存储服务(W6C1) */
  private readonly worldDirectionalRelationshipStoreService: WorldDirectionalRelationshipStoreService;
  /** WorldDirectionalRelationshipPromptAssembler 世界方向性关系Prompt构建器(W6C2) */
  private readonly worldDirectionalRelationshipPromptAssembler: WorldDirectionalRelationshipPromptAssembler;
  /** WorldDirectionalRelationshipGenerationService 世界方向性关系AI生成服务(W6C2) */
  private readonly worldDirectionalRelationshipGenerationService: WorldDirectionalRelationshipGenerationService;
  /** WorldSessionPostProcessRunStoreService 世界会话后处理运行存储服务(W7A) */
  private readonly worldSessionPostProcessRunStoreService: WorldSessionPostProcessRunStoreService;
  /** WorldSessionPostProcessingOrchestrator 世界会话后处理编排器(W7B) */
  private readonly worldSessionPostProcessingOrchestrator: WorldSessionPostProcessingOrchestrator;

  /**
   * 私有构造,组装全部依赖。
   * 不保存 Context,仅用于初始化 Preferences。
   */
  private constructor() {
    this.appPreferences = new AppPreferences();
    this.chatTextStyleSettings = new ChatTextStyleSettings(this.appPreferences);
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
    // LorebookRepository 必须在 CharacterService 之前创建,以支持角色卡 character_book 自动导入
    this.lorebookRepository = new LorebookRepository(this.dbHelper);
    // W-DATA-1B: 世界 Repository 必须在 CharacterService 之前创建,
    // 以便将 WorldCharacterInstanceRepository 注入 CharacterService 实现角色删除引用保护。
    // 所有世界 Repository 仅依赖 DbHelper,不依赖任何 Service,不会形成循环。
    this.worldRepository = new WorldRepository(this.dbHelper);
    this.worldLocationRepository = new WorldLocationRepository(this.dbHelper);
    this.worldLocationEdgeRepository = new WorldLocationEdgeRepository(this.dbHelper);
    this.worldCharacterInstanceRepository = new WorldCharacterInstanceRepository(this.dbHelper);
    this.worldEventRepository = new WorldEventRepository(this.dbHelper);
    // W-SCENE-1A: 世界场景与场景消息仓储,仅依赖 DbHelper,不依赖任何 Service,不会形成循环。
    this.worldSceneRepository = new WorldSceneRepository(this.dbHelper);
    this.worldSceneMessageRepository = new WorldSceneMessageRepository(this.dbHelper);
    // W-MEMORY-1A: 世界角色记忆仓储,仅依赖 DbHelper,不依赖任何 Service,不会形成循环。
    this.worldCharacterMemoryRepository = new WorldCharacterMemoryRepository(this.dbHelper);
    // W5B1: 世界角色主观记忆条目仓储,仅依赖 DbHelper,不依赖任何 Service。
    this.worldCharacterMemoryEntryRepository = new WorldCharacterMemoryEntryRepository(this.dbHelper);
    // W1A-WORLD-CORE-STORE: 世界玩家档案与会话仓储,仅依赖 DbHelper,不依赖任何 Service,不会形成循环。
    this.worldPlayerProfileRepository = new WorldPlayerProfileRepository(this.dbHelper);
    this.worldConversationSessionRepository = new WorldConversationSessionRepository(this.dbHelper);
    // W5A1: 世界会话摘要仓储,仅依赖 DbHelper,不依赖任何 Service。
    this.worldSessionSummaryRepository = new WorldSessionSummaryRepository(this.dbHelper);
    // W1C-WORLD-MAP-CONTRACT: 世界地点地图放置仓储,仅依赖 DbHelper,不依赖任何 Service。
    this.worldLocationMapPlacementRepository = new WorldLocationMapPlacementRepository(this.dbHelper);
    // W4A: 世界角色地点历史仓储,仅依赖 DbHelper,不依赖任何 Service。
    this.worldCharacterLocationHistoryRepository = new WorldCharacterLocationHistoryRepository(this.dbHelper);
    // W6A1: 世界事件提取运行与条目仓储,仅依赖 DbHelper,不依赖任何 Service。
    this.worldEventExtractionRunRepository = new WorldEventExtractionRunRepository(this.dbHelper);
    this.worldEventEntryRepository = new WorldEventEntryRepository(this.dbHelper);
    // W6B1: 世界已知事件条目仓储,仅依赖 DbHelper,不依赖任何 Service。
    this.worldKnownEventEntryRepository = new WorldKnownEventEntryRepository(this.dbHelper);
    // W6C1: 世界方向性关系条目仓储,仅依赖 DbHelper,不依赖任何 Service。
    this.worldDirectionalRelationshipEntryRepository = new WorldDirectionalRelationshipEntryRepository(this.dbHelper);
    // W7A: 世界会话后处理运行仓储,仅依赖 DbHelper,不依赖任何 Service。
    this.worldSessionPostProcessRunRepository = new WorldSessionPostProcessRunRepository(this.dbHelper);
    this.characterService = new CharacterService(
      this.characterRepository,
      this.characterSelectionStore,
      characterAssetStore,
      this.lorebookRepository,
      this.worldCharacterInstanceRepository
    );
    // W-MEMORY-1A: 世界角色记忆业务服务(记忆唯一正式写入口)。
    // 依赖 5 个世界 Repository(只读 WithStore) + MemoryRepository(写入) + DbHelper。
    // 不依赖 CharacterService / Page / ViewModel,无构造循环。
    // 在 WorldStateService 之前创建,以便注入 WorldStateService 实现级联删除。
    this.worldCharacterMemoryService = new WorldCharacterMemoryService(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldCharacterInstanceRepository,
      this.worldSceneRepository,
      this.worldSceneMessageRepository,
      this.worldCharacterMemoryRepository,
      this.dbHelper
    );
    // W4A: 世界角色移动业务服务(位置变更唯一正式写入口)。
    // 依赖 6 个世界 Repository(只读/写入) + HistoryRepository(写入) + DbHelper。
    // 不依赖 WorldStateService,无构造循环。
    // 在 WorldStateService 之前创建,以便注入 WorldStateService 实现 History 委托。
    this.worldCharacterMovementService = new WorldCharacterMovementService(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldLocationEdgeRepository,
      this.worldCharacterInstanceRepository,
      this.worldConversationSessionRepository,
      this.worldCharacterLocationHistoryRepository,
      this.dbHelper
    );
    this.worldPerceptionService = new WorldPerceptionService(
      this.worldCharacterInstanceRepository
    );
    // W-DATA-1B / W-SCENE-1A: 世界模式状态业务服务(世界基础数据唯一正式写入口)。
    // 依赖 7 个世界 Repository + MemoryService(级联删除) + MovementService(History委托)
    //   + CharacterService(只读 getById) + DbHelper。
    // CharacterService 已注入 worldCharacterInstanceRepository,但 WorldStateService
    // 不调用 CharacterService.remove 等写方法,无构造循环。
    this.worldStateService = new WorldStateService(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldLocationEdgeRepository,
      this.worldCharacterInstanceRepository,
      this.worldEventRepository,
      this.worldSceneRepository,
      this.worldSceneMessageRepository,
      this.worldConversationSessionRepository,
      this.worldSessionSummaryRepository,
      this.worldPlayerProfileRepository,
      this.worldLocationMapPlacementRepository,
      this.worldCharacterMemoryService,
      this.worldCharacterMemoryEntryRepository,
      this.worldCharacterMovementService,
      this.worldEventExtractionRunRepository,
      this.worldEventEntryRepository,
      this.worldKnownEventEntryRepository,
      this.worldDirectionalRelationshipEntryRepository,
      this.worldSessionPostProcessRunRepository,
      this.characterService,
      this.dbHelper
    );
    // W-SCENE-1B: 世界场景业务服务(场景和场景消息唯一正式写入口)。
    // 依赖 6 个世界 Repository + DbHelper,不依赖 CharacterService / Page / ViewModel。
    // 在 WorldStateService 之后创建,无构造循环。
    this.worldSceneService = new WorldSceneService(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldCharacterInstanceRepository,
      this.worldSceneRepository,
      this.worldSceneMessageRepository,
      this.worldEventRepository,
      this.dbHelper
    );
    // W1B2: 世界会话生命周期业务服务(会话唯一正式写入口)。
    // 依赖 5 个世界 Repository + DbHelper,不依赖 CharacterService / Page / ViewModel。
    // 在 WorldStateService 之后创建,无构造循环。
    this.worldConversationSessionService = new WorldConversationSessionService(
      this.worldRepository,
      this.worldPlayerProfileRepository,
      this.worldSceneRepository,
      this.worldCharacterInstanceRepository,
      this.worldConversationSessionRepository,
      this.dbHelper
    );
    this.worldMapInteractionService = new WorldMapInteractionService(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldLocationEdgeRepository,
      this.worldCharacterInstanceRepository,
      this.worldLocationMapPlacementRepository,
      this.characterService,
      this.dbHelper
    );
    this.worldSceneLaunchService = new WorldSceneLaunchService(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldCharacterInstanceRepository,
      this.worldPlayerProfileRepository,
      this.worldSceneRepository,
      this.worldConversationSessionRepository,
      this.worldSceneService,
      this.worldConversationSessionService,
      this.dbHelper
    );
    // W3A1: 世界场景消息服务(Runtime唯一正式消息写入入口)
    this.worldSceneMessageService = new WorldSceneMessageService(
      this.worldSceneRepository,
      this.worldConversationSessionRepository,
      this.worldSceneMessageRepository,
      this.dbHelper
    );
    // W3A1: 运行时操作注册表(单例)
    this.worldRuntimeRegistry = new WorldRuntimeRegistry();
    this.lorebookSelectionStore = new LorebookSelectionStore(this.appPreferences);
    this.characterMigrationService = new CharacterMigrationService(
      this.characterStore,
      this.characterRepository,
      this.characterSelectionStore,
      this.appPreferences
    );
    // Lorebook 仅作迁移源,由 AppServices 直接管理
    this.lorebookStore = new LorebookStore();
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
    // W5C1: 世界跨Session上下文选择器。
    // 依赖 SummaryRepo + MemoryEntryRepo + SessionRepo + SceneRepo + DbHelper。
    // 必须在 worldScenePromptAssembler 之前构造(W5C2 注入依赖)。
    this.worldCrossSessionContextService = new WorldCrossSessionContextService(
      this.worldSessionSummaryRepository,
      this.worldCharacterMemoryEntryRepository,
      this.worldConversationSessionRepository,
      this.worldSceneRepository,
      this.dbHelper
    );
    // W3A1: Prompt构建器(依赖通用PromptBuilder/Lorebook/Preset/ModelService/TokenCounter/HistoryTrimmer/W5C1 ContextService)
    this.worldScenePromptAssembler = new WorldScenePromptAssembler(
      this.promptBuilder,
      this.lorebookService,
      this.promptPresetService,
      this.modelService,
      this.tokenCounter,
      this.historyTrimmer,
      this.worldCrossSessionContextService
    );
    // W3A1: 运行时核心服务(依赖所有世界Repository + CharacterService + ModelService + MessageService + Registry + PromptAssembler)
    this.worldSceneRuntimeService = new WorldSceneRuntimeService(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldSceneRepository,
      this.worldConversationSessionRepository,
      this.worldCharacterInstanceRepository,
      this.worldPlayerProfileRepository,
      this.worldSceneMessageRepository,
      this.characterService,
      this.modelService,
      this.worldSceneMessageService,
      this.worldRuntimeRegistry,
      this.worldScenePromptAssembler
    );
    // W5A1: 世界会话摘要存储服务(摘要唯一正式写入口)。
    // 依赖 SummaryRepo + SessionRepo + SceneMessageRepo + SceneRepo + DbHelper。
    // 不依赖 ModelService,不调用 AI 模型。仅负责准备源数据与持久化已完成的摘要。
    this.worldSessionSummaryStoreService = new WorldSessionSummaryStoreService(
      this.worldSessionSummaryRepository,
      this.worldConversationSessionRepository,
      this.worldSceneMessageRepository,
      this.worldSceneRepository,
      this.dbHelper
    );
    // W5B1: 世界角色主观记忆存储服务(记忆条目唯一正式写入口)。
    // 依赖 MemoryEntryRepo + SessionRepo + SceneMessageRepo + CharacterInstanceRepo + DbHelper。
    // 不调用 AI 模型。仅负责准备源数据与持久化已完成的记忆。
    this.worldCharacterMemoryStoreService = new WorldCharacterMemoryStoreService(
      this.worldCharacterMemoryEntryRepository,
      this.worldConversationSessionRepository,
      this.worldSceneMessageRepository,
      this.worldCharacterInstanceRepository,
      this.dbHelper
    );
    // W5B2: 世界角色主观记忆Prompt构建器。
    // 依赖 WorldRepo + LocationRepo + SceneRepo(只读公共元数据)。
    // 不调用 ModelService / Repository 写入 / 保存 Memory。
    this.worldCharacterMemoryPromptAssembler = new WorldCharacterMemoryPromptAssembler(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldSceneRepository
    );
    // W5B2: 世界角色主观记忆AI生成服务。
    // 依赖 StoreService + PromptAssembler + ModelService + SessionRepo。
    // 对每个 owner 独立 Model request，顺序执行。
    this.worldCharacterMemoryGenerationService = new WorldCharacterMemoryGenerationService(
      this.worldCharacterMemoryStoreService,
      this.worldCharacterMemoryPromptAssembler,
      this.modelService,
      this.worldConversationSessionRepository
    );
    // W5A2: 世界会话摘要Prompt构建器。
    // 依赖 WorldRepo + LocationRepo + SceneRepo(只读公共元数据)。
    this.worldSessionSummaryPromptAssembler = new WorldSessionSummaryPromptAssembler(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldSceneRepository
    );
    // W5A2: 世界会话摘要生成服务(AI摘要生成+幂等+regenerate)。
    // 依赖 StoreService + PromptAssembler + ModelService。
    this.worldSessionSummaryGenerationService = new WorldSessionSummaryGenerationService(
      this.worldSessionSummaryStoreService,
      this.worldSessionSummaryPromptAssembler,
      this.modelService
    );
    // W6A1: 世界事件提取存储服务(事件提取运行+条目唯一正式写入口)。
    // 依赖 ExtractionRunRepo + EventEntryRepo + SessionSummaryRepo + SceneMessageRepo + SessionRepo + DbHelper。
    this.worldEventStoreService = new WorldEventStoreService(
      this.worldEventExtractionRunRepository,
      this.worldEventEntryRepository,
      this.worldSessionSummaryRepository,
      this.worldConversationSessionRepository,
      this.worldSceneMessageRepository,
      this.worldSceneRepository,
      this.dbHelper
    );
    // W6A2: 世界事件提取Prompt构建器(依赖 WorldRepo + LocationRepo + SceneRepo 只读公共元数据)。
    this.worldEventExtractionPromptAssembler = new WorldEventExtractionPromptAssembler(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldSceneRepository
    );
    // W6A2: 世界事件提取AI生成服务(依赖 StoreService + PromptAssembler + ModelService)。
    this.worldEventExtractionGenerationService = new WorldEventExtractionGenerationService(
      this.worldEventStoreService,
      this.worldEventExtractionPromptAssembler,
      this.modelService
    );
    // W6B1: 世界已知事件存储服务(已知事件条目唯一正式写入口)。
    // 依赖 KnownEventEntryRepo + ExtractionRunRepo + EventEntryRepo + DbHelper。
    this.worldKnownEventStoreService = new WorldKnownEventStoreService(
      this.worldKnownEventEntryRepository,
      this.worldEventExtractionRunRepository,
      this.worldEventEntryRepository,
      this.dbHelper
    );
    // W6C1: 世界方向性关系存储服务(关系条目唯一正式写入口)。
    // 依赖 RelationshipEntryRepo + SessionRepo(participant display-name authority) + MemoryStoreService(owner-visible evidence authority) + DbHelper。
    // 不调用 ModelService,不复制第二套 visibility filter。
    this.worldDirectionalRelationshipStoreService = new WorldDirectionalRelationshipStoreService(
      this.worldDirectionalRelationshipEntryRepository,
      this.worldConversationSessionRepository,
      this.worldCharacterMemoryStoreService,
      this.dbHelper
    );
    // W6C2: 世界方向性关系Prompt构建器。
    // 依赖 WorldRepo + LocationRepo + SceneRepo(只读公共元数据)。
    this.worldDirectionalRelationshipPromptAssembler = new WorldDirectionalRelationshipPromptAssembler(
      this.worldRepository,
      this.worldLocationRepository,
      this.worldSceneRepository
    );
    // W6C2: 世界方向性关系AI生成服务(逐 Owner→Target 独立请求)。
    // 依赖 StoreService + PromptAssembler + ModelService + SessionRepo。
    this.worldDirectionalRelationshipGenerationService = new WorldDirectionalRelationshipGenerationService(
      this.worldDirectionalRelationshipStoreService,
      this.worldDirectionalRelationshipPromptAssembler,
      this.modelService,
      this.worldConversationSessionRepository
    );
    // W7A: 世界会话后处理运行存储服务(运行唯一正式写入口)。
    // 依赖 RunRepo + SessionRepo + DbHelper。不调用 AI 模型。
    this.worldSessionPostProcessRunStoreService = new WorldSessionPostProcessRunStoreService(
      this.worldSessionPostProcessRunRepository,
      this.worldConversationSessionRepository,
      this.dbHelper
    );
    // W7B: 世界会话后处理编排器(End Session 后非阻塞触发 + World 重进恢复)。
    // 依赖 RunStoreService + SessionService + 全部 Generation Service + EventStoreService。
    // 不直接调用网络,不直接操作数据库,通过各 Service 间接执行。
    this.worldSessionPostProcessingOrchestrator = new WorldSessionPostProcessingOrchestrator(
      this.worldSessionPostProcessRunStoreService,
      this.worldConversationSessionService,
      this.worldSessionSummaryGenerationService,
      this.worldCharacterMemoryGenerationService,
      this.worldEventExtractionGenerationService,
      this.worldKnownEventStoreService,
      this.worldDirectionalRelationshipGenerationService,
      this.worldEventStoreService
    );
    // v8.3 Phase 2: 最近原始消息窗口选择器(去重 + 窗口 + 完整轮次)
    this.recentMessageSelector = new RecentMessageSelector(this.tokenCounter);
    // 持久化层组合:全部 Repository 共享同一 DbHelper 实例
    this.chatRepository = new ChatRepository(this.dbHelper);
    this.messageRepository = new MessageRepository(this.dbHelper);
    this.messageSwipeRepository = new MessageSwipeRepository(this.dbHelper);
    // T-6.4A: ConversationBranch 服务(单例,共享同一 DbHelper)
    this.conversationBranchRepository = new ConversationBranchRepository(this.dbHelper);
    this.chatMemoryRepository = new ChatMemoryRepository(this.dbHelper);
    this.memoryPersistenceService = new MemoryPersistenceService(
      this.dbHelper, this.chatMemoryRepository
    );
    this.conversationBranchPersistenceService = new ConversationBranchPersistenceService(
      this.dbHelper,
      this.conversationBranchRepository,
      this.messageRepository,
      this.messageSwipeRepository,
      this.memoryPersistenceService
    );
    this.chatPersistenceOperations = new ChatPersistenceOperations(
      this.dbHelper,
      this.chatRepository,
      this.messageRepository,
      this.messageSwipeRepository,
      this.conversationBranchPersistenceService,
      this.memoryPersistenceService,
      // G-DATA-1A: 注入 ChatParticipantRepository,使删除 Chat 时同步清理 chat_participants
      new ChatParticipantRepository(this.dbHelper),
      // G-MEMORY-1A: 注入 GroupCharacterMemoryRepository,使删除群聊时同事务级联清理
      // group_character_memories。Repository 仅依赖 DbHelper,不依赖任何 Service,不会形成循环。
      new GroupCharacterMemoryRepository(this.dbHelper),
      // G-MEMORY-AUTO-1B: 注入 GroupCharacterRelationshipMemoryRepository,使删除群聊时
      // 同事务级联清理 group_character_relationship_memories。Repository 仅依赖 DbHelper。
      new GroupCharacterRelationshipMemoryRepository(this.dbHelper)
    );
    // v8: MemoryService(依赖 ModelService + MemoryPersistenceService)
    this.memoryService = new MemoryService(
      this.memoryPersistenceService,
      this.modelService
    );
    // v8: ForkChatService(从分支创建独立对话)
    this.forkChatService = new ForkChatService(
      this.dbHelper,
      this.chatRepository,
      this.messageRepository,
      this.messageSwipeRepository,
      this.conversationBranchRepository,
      this.chatMemoryRepository,
      this.memoryPersistenceService
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
    // G-DATA-1A: 多人聊天持久化底座
    // ChatParticipantRepository 与注入到 ChatPersistenceOperations 的不是同一实例,
    // 但共享同一 DbHelper,事务内通过 WithStore 方法操作同一 RdbStore,行为一致。
    this.chatParticipantRepository = new ChatParticipantRepository(this.dbHelper);
    // G-RUNTIME-1D: 应用级多人聊天运行注册表(单例,所有多人 Service 共享同一实例)
    // 必须在 groupConversationPersistenceService / groupConversationMessageService /
    // groupChatRuntimeService 之前创建,因为这三个 Service 构造时即注入 registry。
    this.groupRuntimeRegistry = new GroupRuntimeRegistry();
    this.groupConversationPersistenceService = new GroupConversationPersistenceService(
      this.dbHelper,
      this.chatRepository,
      this.chatParticipantRepository,
      this.characterRepository,
      this.chatPersistenceOperations,
      this.groupRuntimeRegistry
    );
    // G-RUNTIME-1A: 多人聊天消息持久化与轮次协调器
    // 依赖已创建的 chatRepository / messageRepository / groupConversationPersistenceService / characterService
    this.groupConversationMessageService = new GroupConversationMessageService(
      this.dbHelper,
      this.chatRepository,
      this.messageRepository,
      this.groupRuntimeRegistry
    );
    this.groupRoundCoordinator = new GroupRoundCoordinator(
      this.groupConversationPersistenceService,
      this.characterService
    );
    // G-RUNTIME-1B: 多人聊天运行时(严格顺序流式生成)
    // 复用已创建的 roundCoordinator / messageService / modelService
    // 以及 promptBuilder / historyTrimmer / tokenCounter / lorebookService / characterService / promptPresetService
    this.groupPromptAssembler = new GroupPromptAssembler(
      this.promptBuilder,
      this.historyTrimmer,
      this.tokenCounter,
      this.lorebookService,
      this.characterService,
      this.promptPresetService,
      this.modelService
    );
    // G-CONTEXT-INSPECTOR-1 / G-CONTEXT-PERSIST-1: Prompt 诊断快照存储(内存 + AppPreferences)
    this.groupPromptInspectionStore = new GroupPromptInspectionStore(this.appPreferences);
    // G-CONTEXT-MEMORY-SELECTION-1: 记忆选择器依赖的两个 Repository 提前创建(仅依赖 DbHelper)
    this.groupCharacterMemoryRepository = new GroupCharacterMemoryRepository(this.dbHelper);
    this.groupCharacterRelationshipMemoryRepository =
      new GroupCharacterRelationshipMemoryRepository(this.dbHelper);
    this.groupChatRuntimeService = new GroupChatRuntimeService(
      this.groupRoundCoordinator,
      this.groupConversationMessageService,
      this.groupPromptAssembler,
      this.modelService,
      this.groupRuntimeRegistry,
      this.groupPromptInspectionStore,
      new GroupCharacterMemorySelector(
        this.groupCharacterMemoryRepository,
        this.groupCharacterRelationshipMemoryRepository
      )
    );
    // G-MEMORY-1A: 多人聊天每角色独立记忆 Service。
    // Service 依赖 chatRepository(只读 getByIdWithStore) + characterRepository(只读 getByIdWithStore)
    // + chatParticipantRepository(只读 listByChatIdWithStore) + memoryRepo(写入) + dbHelper(事务)。
    // 不调用 GroupChatRuntimeService / GroupPromptAssembler / ModelService,
    // 不影响多人聊天发送/Streaming/严格顺序/回复目标/@角色/停止整轮/重试等现有功能。
    // 群聊删除级联清理已通过 ChatPersistenceOperations 注入 memoryRepo 实现,
    // 此处 Service 仅用于手动记忆 CRUD,不参与群聊删除流程。
    this.groupCharacterMemoryService = new GroupCharacterMemoryService(
      this.chatRepository,
      this.characterRepository,
      this.chatParticipantRepository,
      this.groupCharacterMemoryRepository,
      this.dbHelper
    );
    // G-MEMORY-AUTO-1A: 多人角色自身发言手动总结服务
    // 依赖 messageService(只读 listMessages) + memoryService(只读 listByCharacter / 写入 createInteractionMemory)
    //   + modelService(只读 getCurrentConfig / sendChat)。
    // 不依赖 ChatPage / ViewModel / Runtime,无构造循环。
    // 不修改单聊 MemoryService,仅参考其调用参数。
    this.groupCharacterSelfSummaryService = new GroupCharacterSelfSummaryService(
      this.groupConversationMessageService,
      this.groupCharacterMemoryService,
      this.modelService
    );
    // G-MEMORY-AUTO-1B: 多人角色关系记忆 Service + SummaryService。
    // MemoryService 依赖 chatRepository(只读 getByIdWithStore) + characterRepository(只读 getByIdWithStore)
    //   + relationshipRepo(写入) + dbHelper(事务)。不校验 ChatParticipant(成员移除后关系保留)。
    // SummaryService 依赖 messageService(只读 listMessages) + groupPersistenceService(只读 getParticipants)
    //   + characterService(只读 getById 解析白名单) + relationshipMemoryService(只读 listByOwner 检查重复)
    //   + modelService(只读 getCurrentConfig / sendChat)。
    // 不依赖 ChatPage / ViewModel / Runtime,无构造循环。
    this.groupCharacterRelationshipMemoryService = new GroupCharacterRelationshipMemoryService(
      this.chatRepository,
      this.characterRepository,
      this.groupCharacterRelationshipMemoryRepository,
      this.dbHelper
    );
    this.groupCharacterRelationshipSummaryService = new GroupCharacterRelationshipSummaryService(
      this.groupConversationMessageService,
      this.groupConversationPersistenceService,
      this.characterService,
      this.groupCharacterRelationshipMemoryService,
      this.modelService
    );
    // 市场服务(Chub 公共浏览 + 搜索 + 详情 + 下载)
    // 使用独立的 HarmonyHttpClient 实例(非流式),不与流式 Provider 共享
    const marketHttpClient: HttpClient = new HarmonyHttpClient();
    const marketCacheStore: MarketCacheStore = new MarketCacheStore(this.appPreferences);
    const marketImportedMapStore: MarketImportedMapStore = new MarketImportedMapStore(this.appPreferences);
    this.marketService = new MarketService(marketHttpClient, marketCacheStore, marketImportedMapStore);
    // W-DATA-1A/B: 世界模式数据域 Repository 与 WorldStateService 已在 CharacterService 之前创建
    // ChatBackgroundService 在 initialize 中 context 就绪后创建
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
    const services: AppServices = new AppServices();
    AppServices.instance = services;
    // 保存 Context(用于 ChatBackgroundService 等需要 filesDir 的服务)
    // EntryAbility.onCreate 始终传入 UIAbilityContext,这里直接保存为 common.Context。
    services.appContext = context;
    AppServices.readyPromise = services.modelService.initialize(context)
      .then((): Promise<void> => services.appPreferences.initialize(context))
      .then(async (): Promise<void> => {
        await services.chatTextStyleSettings.load();
      })
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
      .then(async (): Promise<void> => {
        // G-CONTEXT-PERSIST-1: 恢复 Prompt 诊断快照(appPreferences 已就绪)
        await services.groupPromptInspectionStore.restore();
      })
      .then((): void => {
        // 创建 ChatBackgroundService(需要已初始化的 appPreferences + appContext)
        if (services.appContext !== null) {
          services.chatBackgroundService = new ChatBackgroundService(
            services.appContext, services.appPreferences);
        } else {
          Logger.warn(LOG_TAG, 'appContext is null, chatBackgroundService not created');
        }
        // 创建 ContextBudgetService(只需 appPreferences)
        services.contextBudgetService = new ContextBudgetService(services.appPreferences);
        // 创建 MarketImportService(需要 appContext 写入临时 PNG 文件)
        if (services.appContext !== null) {
          services.marketImportService = new MarketImportService(
            services.marketService,
            services.characterService,
            services.marketService.getImportedMapStore(),
            services.appContext
          );
        } else {
          Logger.warn(LOG_TAG, 'appContext is null, marketImportService not created');
        }
        // 创建 MarketTranslationService(复用 ModelService + MarketCacheStore)
        services.marketTranslationService = new MarketTranslationService(
          services.modelService,
          services.marketService.getCacheStore()
        );
        // 创建 ChatArchiveService(T-CHAT.1 聊天归档导出,只需 Repository)
        services.chatArchiveService = new ChatArchiveService(
          services.chatRepository,
          services.messageRepository,
          services.messageSwipeRepository,
          services.conversationBranchRepository,
          services.characterRepository
        );
        // 创建 ChatArchiveImportService(T-CHAT.1 聊天归档导入,只需 Repository + DbHelper)
        services.chatArchiveImportService = new ChatArchiveImportService(
          services.dbHelper,
          services.chatRepository,
          services.messageRepository,
          services.messageSwipeRepository,
          services.conversationBranchRepository,
          services.characterRepository
        );
        Logger.warn(LOG_TAG, 'AppServices initialized');
      })
      .catch((e: Object): void => {
        Logger.error(LOG_TAG, 'initialize failed: ' + (e as Error).message);
        AppServices.instance = null;
        AppServices.readyPromise = null;
        // W-MEMORY-1A-FIX: 保留 DatabaseError 类型信息(如 UnsupportedVersion),
        // 让上层可识别高版本不兼容错误并显示安全提示,而非触发重建兜底。
        if (e instanceof DatabaseError) {
          throw e;
        }
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
   * 获取 MemoryService 实例(v8 长期记忆业务服务)。
   * 用于 MemoryManagementPage 等页面查询/编辑/清除当前 Branch Memory。
   */
  static getMemoryService(): MemoryService {
    return AppServices.getInstance().memoryService;
  }

  /**
   * 获取 MemoryPersistenceService 实例(v8 长期记忆持久化服务)。
   * 仅供 ChatService / ConversationBranchPersistenceService 等内部服务使用。
   */
  static getMemoryPersistenceService(): MemoryPersistenceService {
    return AppServices.getInstance().memoryPersistenceService;
  }

  /**
   * 获取 ForkChatService 实例(v8 从分支创建独立对话)。
   * 用于 ChatMessageActionSheet / BranchMapPage 等触发"从此处创建独立对话"。
   */
  static getForkChatService(): ForkChatService {
    return AppServices.getInstance().forkChatService;
  }

  /**
   * 获取 ContextBudgetService 实例(v8.1 per-chat 上下文预算服务)。
   * @throws Error 当未初始化或服务创建失败时
   */
  static getContextBudgetService(): ContextBudgetService {
    const service: ContextBudgetService | null = AppServices.getInstance().contextBudgetService;
    if (service === null) {
      throw new Error('ContextBudgetService not initialized');
    }
    return service;
  }

  /**
   * 获取 TokenCounter 实例(v8.1 上下文占用估算)。
   * 用于 ContextBudgetViewModel 在页面侧重新估算分段 Token。
   */
  static getTokenCounter(): TokenCounter {
    return AppServices.getInstance().tokenCounter;
  }

  /**
   * 获取 ChatPersistenceService 实例。
   * 用于"对话记录"Tab 等不需要完整 ChatService 的场景(只查询会话列表 / 重命名)。
   */
  static getChatPersistenceService(): ChatPersistenceService {
    return AppServices.getInstance().chatPersistenceService;
  }

  /**
   * 获取 ChatBackgroundService 实例。
   * 用于聊天界面背景图导入、读取、删除。
   * 如果初始化时 appContext 不可用,返回 null。
   */
  static getChatBackgroundService(): ChatBackgroundService | null {
    return AppServices.getInstance().chatBackgroundService;
  }

  /**
   * 获取 MarketService 实例。
   * 用于市场 Tab 浏览、搜索、详情查看、PNG/JSON 下载。
   */
  static getMarketService(): MarketService {
    return AppServices.getInstance().marketService;
  }

  /**
   * 获取 MarketImportService 实例。
   * 用于市场角色卡导入(校验重复 + 下载 + 调用现有 CharacterService 导入流程)。
   * 如果初始化时 appContext 不可用,返回 null。
   */
  static getMarketImportService(): MarketImportService | null {
    return AppServices.getInstance().marketImportService;
  }

  /**
   * 获取 MarketTranslationService 实例。
   * 用于市场角色卡预览字段的中文翻译(复用 ModelService)。
   * 初始化完成后始终可用(无外部依赖)。
   */
  static getMarketTranslationService(): MarketTranslationService | null {
    return AppServices.getInstance().marketTranslationService;
  }

  /**
   * 获取 AppPreferences 实例(v9 引入)。
   * 用于 AppSettingsPage 等页面读写全局用户称呼等通用 KV 配置。
   */
  static getAppPreferences(): AppPreferences {
    return AppServices.getInstance().appPreferences;
  }

  /**
   * 创建 ChatSessionListViewModel 实例。
   * 用于"对话记录"Tab 展示全部会话 + 角色信息 + 最后消息摘要 + 重命名。
   */
  static createChatSessionListViewModel(): ChatSessionListViewModel {
    const services: AppServices = AppServices.getInstance();
    return new ChatSessionListViewModel(
      services.chatPersistenceService,
      services.characterService
    );
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
      services.conversationBranchPersistenceService,
      services.chatBackgroundService,
      services.memoryService,
      services.contextBudgetService,
      services.appPreferences,
      services.recentMessageSelector
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

  /**
   * 获取 ChatArchiveService 实例(T-CHAT.1 聊天归档导出)。
   * 用于导出单个对话或角色全部对话。
   */
  static getChatArchiveService(): ChatArchiveService {
    const service: ChatArchiveService | null = AppServices.getInstance().chatArchiveService;
    if (service === null) {
      throw new Error('ChatArchiveService not initialized');
    }
    return service;
  }

  /**
   * 获取 ChatArchiveImportService 实例(T-CHAT.1 聊天归档导入)。
   * 用于从 .arktchat.json 文件导入对话。
   */
  static getChatArchiveImportService(): ChatArchiveImportService {
    const service: ChatArchiveImportService | null = AppServices.getInstance().chatArchiveImportService;
    if (service === null) {
      throw new Error('ChatArchiveImportService not initialized');
    }
    return service;
  }

  /**
   * 创建 ChatArchiveViewModel 实例(T-CHAT.1 聊天归档导入导出)。
   * 用于 ChatPage / ChatSessionRootView 触发导出与导入。
   * 每次调用返回新实例,内部封装文件选择器与 Service 调用。
   */
  static createChatArchiveViewModel(): ChatArchiveViewModel {
    const archiveService: ChatArchiveService = AppServices.getChatArchiveService();
    const importService: ChatArchiveImportService = AppServices.getChatArchiveImportService();
    return new ChatArchiveViewModel(archiveService, importService);
  }

  /**
   * 获取 GroupConversationPersistenceService 实例(G-DATA-1A 多人聊天持久化服务)。
   * 用于多人聊天创建、列表、重命名、成员管理、删除等正式数据操作。
   * 本阶段(G-DATA-1A)不接入静态多人 UI,UI 接入留到 G-DATA-1B。
   */
  static getGroupConversationPersistenceService(): GroupConversationPersistenceService {
    return AppServices.getInstance().groupConversationPersistenceService;
  }

  /**
   * 获取 ChatParticipantRepository 实例(G-DATA-1A 多人聊天参与者仓储)。
   * 仅供 GroupConversationPersistenceService 等内部服务使用,不对页面公开。
   */
  static getChatParticipantRepository(): ChatParticipantRepository {
    return AppServices.getInstance().chatParticipantRepository;
  }

  /**
   * 获取 GroupConversationMessageService 实例(G-RUNTIME-1A 多人聊天消息服务)。
   * 用于多人聊天消息读取、用户消息写入、清空、中断恢复。
   * 页面通过 ViewModel 间接使用,不直接调用。
   */
  static getGroupConversationMessageService(): GroupConversationMessageService {
    return AppServices.getInstance().groupConversationMessageService;
  }

  /**
   * 获取 GroupRoundCoordinator 实例(G-RUNTIME-1A 多人聊天轮次协调器)。
   * 用于建立本轮成员快照、管理 operationId、校验活动轮次。
   * 本阶段不接入 Provider,只到 Ready 状态。
   */
  static getGroupRoundCoordinator(): GroupRoundCoordinator {
    return AppServices.getInstance().groupRoundCoordinator;
  }

  /**
   * 获取 GroupPromptAssembler 实例(G-RUNTIME-1B 多人聊天单角色 Prompt 构建器)。
   * 用于为当前发言角色单独构建模型请求上下文,实现角色隔离。
   * 页面通过 ViewModel 间接使用,不直接调用。
   */
  static getGroupPromptAssembler(): GroupPromptAssembler {
    return AppServices.getInstance().groupPromptAssembler;
  }

  /**
   * 获取 GroupChatRuntimeService 实例(G-RUNTIME-1B 多人聊天运行时服务)。
   * 用于启动一轮多人聊天生成、停止整轮、查询运行状态。
   * 页面通过 ViewModel 间接使用,不直接调用。
   */
  static getGroupChatRuntimeService(): GroupChatRuntimeService {
    return AppServices.getInstance().groupChatRuntimeService;
  }

  /**
   * 获取 GroupCharacterMemoryRepository 实例(G-MEMORY-1A 多人聊天角色记忆仓储)。
   * 用于 group_character_memories 表的 CRUD 操作。
   * 页面与 ViewModel 不直接调用,留待 GroupCharacterMemoryService 使用。
   */
  static getGroupCharacterMemoryRepository(): GroupCharacterMemoryRepository {
    return AppServices.getInstance().groupCharacterMemoryRepository;
  }

  /**
   * 获取 GroupCharacterMemoryService 实例(G-MEMORY-1A 多人聊天角色记忆业务服务)。
   * 是当前多人聊天每角色独立手动记忆的唯一正式写入口。
   * 所有页面与 ViewModel 必须通过此方法获取同一个 GroupCharacterMemoryService。
   */
  static getGroupCharacterMemoryService(): GroupCharacterMemoryService {
    return AppServices.getInstance().groupCharacterMemoryService;
  }

  /**
   * 获取 GroupCharacterSelfSummaryService 实例(G-MEMORY-AUTO-1A 多人角色自身发言手动总结服务)。
   * 仅由 GroupCharacterMemoryViewModel 在 aboutToAppear 中获取并注入。
   * 不直接暴露给 Page / Repository / 单聊代码。
   */
  static getGroupCharacterSelfSummaryService(): GroupCharacterSelfSummaryService {
    return AppServices.getInstance().groupCharacterSelfSummaryService;
  }

  /**
   * 获取 GroupCharacterRelationshipMemoryService 实例
   * (G-MEMORY-AUTO-1B 多人角色关系记忆业务服务)。
   * 是当前多人角色定向关系记忆的唯一正式写入口。
   * 所有页面与 ViewModel 必须通过此方法获取同一个 GroupCharacterRelationshipMemoryService。
   */
  static getGroupCharacterRelationshipMemoryService(): GroupCharacterRelationshipMemoryService {
    return AppServices.getInstance().groupCharacterRelationshipMemoryService;
  }

  /**
   * 获取 GroupCharacterRelationshipSummaryService 实例
   * (G-MEMORY-AUTO-1B 多人角色关系与经历手动总结服务)。
   * 仅由 GroupCharacterMemoryViewModel 在 aboutToAppear 中获取并注入。
   * 不直接暴露给 Page / Repository / 单聊代码。
   */
  static getGroupCharacterRelationshipSummaryService(): GroupCharacterRelationshipSummaryService {
    return AppServices.getInstance().groupCharacterRelationshipSummaryService;
  }

  /**
   * 获取 GroupPromptInspectionStore 实例(G-CONTEXT-INSPECTOR-1 Prompt 诊断快照)。
   */
  static getGroupPromptInspectionStore(): GroupPromptInspectionStore {
    return AppServices.getInstance().groupPromptInspectionStore;
  }

  /**
   * 获取 WorldRepository 实例(W-DATA-1A 世界仓储)。
   * 用于 worlds 表的 CRUD 操作。本阶段不接入 UI,仅完成数据层注册。
   * 页面与 ViewModel 不直接调用,留待 W-DATA-1B WorldStateService 使用。
   */
  static getWorldRepository(): WorldRepository {
    return AppServices.getInstance().worldRepository;
  }

  /**
   * 获取 WorldLocationRepository 实例(W-DATA-1A 世界地点仓储)。
   * 用于 world_locations 表的 CRUD 操作。
   */
  static getWorldLocationRepository(): WorldLocationRepository {
    return AppServices.getInstance().worldLocationRepository;
  }

  /**
   * 获取 WorldLocationEdgeRepository 实例(W-DATA-1A 世界地点边仓储)。
   * 用于 world_location_edges 表的 CRUD 操作。
   */
  static getWorldLocationEdgeRepository(): WorldLocationEdgeRepository {
    return AppServices.getInstance().worldLocationEdgeRepository;
  }

  /**
   * 获取 WorldCharacterInstanceRepository 实例(W-DATA-1A 世界角色实例仓储)。
   * 用于 world_character_instances 表的 CRUD 操作。
   */
  static getWorldCharacterInstanceRepository(): WorldCharacterInstanceRepository {
    return AppServices.getInstance().worldCharacterInstanceRepository;
  }

  /**
   * 获取 WorldEventRepository 实例(W-DATA-1A 世界事件仓储)。
   * 用于 world_events 表的 CRUD 操作(主要为 insert / 查询 / 事务删除)。
   */
  static getWorldEventRepository(): WorldEventRepository {
    return AppServices.getInstance().worldEventRepository;
  }

  /**
   * 获取 WorldSceneRepository 实例(W-SCENE-1A 世界场景仓储)。
   * 用于 world_scenes 表的 CRUD 操作。本阶段不接入 UI,仅完成数据层注册。
   * 页面与 ViewModel 不直接调用,留待 W-SCENE-1B WorldSceneService 使用。
   */
  static getWorldSceneRepository(): WorldSceneRepository {
    return AppServices.getInstance().worldSceneRepository;
  }

  /**
   * 获取 WorldSceneMessageRepository 实例(W-SCENE-1A 世界场景消息仓储)。
   * 用于 world_scene_messages 表的 CRUD 操作与 Streaming 条件更新。
   * 页面与 ViewModel 不直接调用,留待 W-SCENE-1B WorldSceneService 使用。
   */
  static getWorldSceneMessageRepository(): WorldSceneMessageRepository {
    return AppServices.getInstance().worldSceneMessageRepository;
  }

  /**
   * 获取 WorldStateService 实例(W-DATA-1B 世界模式状态业务服务)。
   * 是当前世界基础数据(World / Location / Edge / CharacterInstance)的唯一正式写入口。
   * 所有页面与未来 ViewModel 必须通过此方法获取同一个 WorldStateService。
   */
  static getWorldStateService(): WorldStateService {
    return AppServices.getInstance().worldStateService;
  }

  /**
   * 获取 WorldSceneService 实例(W-SCENE-1B 世界场景业务服务)。
   * 是当前世界场景(Scene)和场景消息(SceneMessage)的唯一正式写入口。
   * 所有页面与 ViewModel 必须通过此方法获取同一个 WorldSceneService。
   */
  static getWorldSceneService(): WorldSceneService {
    return AppServices.getInstance().worldSceneService;
  }

  /**
   * 获取 WorldCharacterMemoryService 实例(W-MEMORY-1A 世界角色记忆业务服务)。
   * 是当前世界角色实例独立长期记忆的唯一正式写入口。
   * 所有页面与 ViewModel 必须通过此方法获取同一个 WorldCharacterMemoryService。
   */
  static getWorldCharacterMemoryService(): WorldCharacterMemoryService {
    return AppServices.getInstance().worldCharacterMemoryService;
  }

  /**
   * 获取 WorldCharacterMemoryRepository 实例(W-MEMORY-1A 世界角色记忆仓储)。
   * 用于 world_character_memories 表的 CRUD 操作。
   * 页面与 ViewModel 不直接调用,留待 W-MEMORY-1A WorldCharacterMemoryService 使用。
   */
  static getWorldCharacterMemoryRepository(): WorldCharacterMemoryRepository {
    return AppServices.getInstance().worldCharacterMemoryRepository;
  }

  /**
   * 获取 WorldCharacterMemoryEntryRepository 实例(W5B1 世界角色主观记忆条目仓储)。
   * 用于 world_character_memory_entries 表的 CRUD 操作。
   * 页面与 ViewModel 不直接调用,留待 WorldCharacterMemoryStoreService 使用。
   */
  static getWorldCharacterMemoryEntryRepository(): WorldCharacterMemoryEntryRepository {
    return AppServices.getInstance().worldCharacterMemoryEntryRepository;
  }

  /**
   * 获取 WorldCharacterMemoryStoreService 实例(W5B1 世界角色主观记忆存储服务)。
   * 是世界角色主观记忆条目的唯一正式写入口。
   * 所有页面与 ViewModel 必须通过此方法获取同一个 WorldCharacterMemoryStoreService。
   */
  static getWorldCharacterMemoryStoreService(): WorldCharacterMemoryStoreService {
    return AppServices.getInstance().worldCharacterMemoryStoreService;
  }

  /**
   * 获取 WorldCharacterMemoryPromptAssembler 实例(W5B2 世界角色主观记忆Prompt构建器)。
   * 所有页面与 ViewModel 必须通过此方法获取同一个实例。
   */
  static getWorldCharacterMemoryPromptAssembler(): WorldCharacterMemoryPromptAssembler {
    return AppServices.getInstance().worldCharacterMemoryPromptAssembler;
  }

  /**
   * 获取 WorldCharacterMemoryGenerationService 实例(W5B2 世界角色主观记忆AI生成服务)。
   * 对每个 owner 独立 Model request，owner isolation 永久保持。
   */
  static getWorldCharacterMemoryGenerationService(): WorldCharacterMemoryGenerationService {
    return AppServices.getInstance().worldCharacterMemoryGenerationService;
  }

  /**
   * 获取 WorldPlayerProfileRepository 实例(W1A-WORLD-CORE-STORE 世界玩家档案仓储)。
   * 用于 world_player_profiles 表的 CRUD 操作。
   * 页面与 ViewModel 不直接调用,留待后续 Service 使用。
   */
  static getWorldPlayerProfileRepository(): WorldPlayerProfileRepository {
    return AppServices.getInstance().worldPlayerProfileRepository;
  }

  /**
   * 获取 WorldConversationSessionRepository 实例(W1A-WORLD-CORE-STORE 世界会话仓储)。
   * 用于 world_conversation_sessions 表的 CRUD 操作。
   * 页面与 ViewModel 不直接调用,留待后续 Service 使用。
   */
  static getWorldConversationSessionRepository(): WorldConversationSessionRepository {
    return AppServices.getInstance().worldConversationSessionRepository;
  }

  /**
   * 获取 WorldConversationSessionService 实例(W1B2 世界会话生命周期服务)。
   * 是当前世界会话(startSession / endSession)的唯一正式写入口。
   * 所有页面与 ViewModel 必须通过此方法获取同一个 WorldConversationSessionService。
   */
  static getWorldConversationSessionService(): WorldConversationSessionService {
    return AppServices.getInstance().worldConversationSessionService;
  }

  static getWorldMapInteractionService(): WorldMapInteractionService {
    return AppServices.getInstance().worldMapInteractionService;
  }

  static getWorldSceneLaunchService(): WorldSceneLaunchService {
    return AppServices.getInstance().worldSceneLaunchService;
  }

  static getWorldSceneMessageService(): WorldSceneMessageService {
    return AppServices.getInstance().worldSceneMessageService;
  }

  static getWorldRuntimeRegistry(): WorldRuntimeRegistry {
    return AppServices.getInstance().worldRuntimeRegistry;
  }

  static getWorldScenePromptAssembler(): WorldScenePromptAssembler {
    return AppServices.getInstance().worldScenePromptAssembler;
  }

  static getWorldSceneRuntimeService(): WorldSceneRuntimeService {
    return AppServices.getInstance().worldSceneRuntimeService;
  }

  /**
   * 获取 WorldCharacterMovementService 实例(W4A 世界角色移动业务服务)。
   * 是当前世界角色位置变更(Travel/Placement/Unplacement/Relocation)的唯一正式写入口。
   * 所有页面与 ViewModel 必须通过此方法获取同一个 WorldCharacterMovementService。
   */
  static getWorldCharacterMovementService(): WorldCharacterMovementService {
    return AppServices.getInstance().worldCharacterMovementService;
  }

  static getWorldPerceptionService(): WorldPerceptionService {
    return AppServices.getInstance().worldPerceptionService;
  }

  static getWorldSessionSummaryStoreService(): WorldSessionSummaryStoreService {
    return AppServices.getInstance().worldSessionSummaryStoreService;
  }

  static getWorldSessionSummaryGenerationService(): WorldSessionSummaryGenerationService {
    return AppServices.getInstance().worldSessionSummaryGenerationService;
  }

  static getWorldCrossSessionContextService(): WorldCrossSessionContextService {
    return AppServices.getInstance().worldCrossSessionContextService;
  }

  /**
   * 获取 WorldLocationMapPlacementRepository 实例(W1C-WORLD-MAP-CONTRACT)。
   * 仅供 WorldStateService / WorldConversationSessionService 等内部服务使用,不对页面公开。
   */
  static getWorldLocationMapPlacementRepository(): WorldLocationMapPlacementRepository {
    return AppServices.getInstance().worldLocationMapPlacementRepository;
  }

  static getWorldEventExtractionRunRepository(): WorldEventExtractionRunRepository {
    return AppServices.getInstance().worldEventExtractionRunRepository;
  }

  static getWorldEventEntryRepository(): WorldEventEntryRepository {
    return AppServices.getInstance().worldEventEntryRepository;
  }

  static getWorldEventStoreService(): WorldEventStoreService {
    return AppServices.getInstance().worldEventStoreService;
  }

  static getWorldEventExtractionPromptAssembler(): WorldEventExtractionPromptAssembler {
    return AppServices.getInstance().worldEventExtractionPromptAssembler;
  }

  static getWorldEventExtractionGenerationService(): WorldEventExtractionGenerationService {
    return AppServices.getInstance().worldEventExtractionGenerationService;
  }

  static getWorldSessionPostProcessingOrchestrator(): WorldSessionPostProcessingOrchestrator {
    return AppServices.getInstance().worldSessionPostProcessingOrchestrator;
  }
}