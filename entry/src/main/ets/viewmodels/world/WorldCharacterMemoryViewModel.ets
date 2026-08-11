import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldEventRepository } from '../../repositories/world/WorldEventRepository';
import { CharacterService } from '../../services/CharacterService';
import {
  WorldCharacterMemoryService,
  WorldCharacterMemoryFilter,
  CreateManualWorldMemoryInput,
  UpdateWorldMemoryInput
} from '../../services/world/WorldCharacterMemoryService';
import { WorldCharacterMemoryStoreService } from '../../services/world/WorldCharacterMemoryStoreService';
import {
  WorldCharacterMemoryEntry,
  WorldCharacterMemoryEntryStatus
} from '../../models/world/WorldCharacterMemoryEntry';
import { Logger } from '../../utils/Logger';
import { World } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import { WorldSceneMessage, WorldSceneMessageSenderType, WorldSceneMessageStatus } from '../../models/world/WorldSceneMessage';
import { WorldEvent, WorldEventType } from '../../models/world/WorldEvent';
import { Character } from '../../models/Character';
import {
  WorldCharacterMemory,
  WorldCharacterMemoryType,
  WorldCharacterMemoryOrigin,
  WorldCharacterMemoryStatus
} from '../../models/world/WorldCharacterMemory';
import { DatabaseError } from '../../models/DatabaseError';
import { mapWorldMemoryErrorToMessage } from './WorldMemoryErrorMapper';
import { formatWorldTimestamp } from './WorldUiModels';

const LOG_TAG: string = 'WorldCharacterMemoryViewModel';

export enum WorldCharacterMemoryLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

export enum WorldCharacterMemoryListFilter {
  All = 'all',
  Active = 'active',
  Archived = 'archived',
  Manual = 'manual',
  Scene = 'scene'
}

export enum ArchiveTab {
  Memory = 'memory',
  Activity = 'activity',
  Relationship = 'relationship',
  Diagnostic = 'diagnostic'
}

export interface MemoryCharacterHeaderUiModel {
  readonly worldId: string;
  readonly worldName: string;
  readonly characterInstanceId: string;
  readonly displayName: string;
  readonly fallbackName: string;
  readonly avatarUri: string;
  readonly isActive: boolean;
  readonly characterCardMissing: boolean;
  readonly currentLocationId: string;
  readonly currentLocationName: string;
  readonly locationMissing: boolean;
  readonly memoryCount: number;
  readonly lastActivityTime: number;
  readonly instanceId: string;
  readonly characterId: string;
}

export interface CharacterSwitcherItemUiModel {
  readonly instanceId: string;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly fallbackName: string;
  readonly isActive: boolean;
}

export interface MemoryLocationOptionUiModel {
  readonly id: string;
  readonly name: string;
  readonly status: string;
}

export interface MemoryItemUiModel {
  readonly id: string;
  readonly type: WorldCharacterMemoryType;
  readonly typeLabel: string;
  readonly origin: WorldCharacterMemoryOrigin;
  readonly originLabel: string;
  readonly status: WorldCharacterMemoryStatus;
  readonly statusLabel: string;
  readonly content: string;
  readonly importance: number;
  readonly sourceLocationId: string;
  readonly sourceLocationName: string;
  readonly sourceLocationMissing: boolean;
  readonly sourceSceneId: string;
  readonly sourceSceneName: string;
  readonly sourceSceneMissing: boolean;
  readonly sourceMessageId: string;
  readonly sourceMessageMissing: boolean;
  readonly sourceSummary: string;
  readonly occurredAt: number;
  readonly occurredAtLabel: string;
  readonly createdAt: number;
  readonly createdAtLabel: string;
  readonly updatedAt: number;
  readonly updatedAtLabel: string;
  readonly worldId: string;
  readonly characterInstanceId: string;
  readonly hasEvidence: boolean;
}

export interface ActivitySceneUiModel {
  readonly sceneId: string;
  readonly locationName: string;
  readonly locationMissing: boolean;
  readonly startedAt: number;
  readonly startedAtLabel: string;
  readonly endedAt: number;
  readonly endedAtLabel: string;
  readonly status: WorldSceneStatus;
  readonly statusLabel: string;
  readonly messageCount: number;
  readonly participantCount: number;
  readonly characterSpoke: boolean;
}

export interface ActivityMessageUiModel {
  readonly messageId: string;
  readonly sceneId: string;
  readonly locationName: string;
  readonly locationMissing: boolean;
  readonly sentAt: number;
  readonly sentAtLabel: string;
  readonly contentPreview: string;
  readonly visibility: string;
  readonly visibilityLabel: string;
  readonly coParticipantNames: string[];
}

export interface ActivityMoveUiModel {
  readonly eventId: string;
  readonly fromLocationName: string;
  readonly fromLocationMissing: boolean;
  readonly toLocationName: string;
  readonly toLocationMissing: boolean;
  readonly occurredAt: number;
  readonly occurredAtLabel: string;
}

/** 活动时间线条目类型 */
export type ActivityTimelineKind = 'message' | 'move' | 'scene';

/** 活动时间线条目(合并发言/移动/场景生命周期,按时间倒序) */
export interface ActivityTimelineItemUiModel {
  readonly id: string;
  readonly kind: ActivityTimelineKind;
  readonly occurredAt: number;
  readonly occurredAtLabel: string;
  readonly locationName: string;
  readonly locationMissing: boolean;
  /** 摘要行:如「发言 · 小草」「移动到「港口」」「场景开始」 */
  readonly headline: string;
  /** 在场人物(消息类) */
  readonly coParticipantNames: string[];
  /** 内容预览(消息类) */
  readonly contentPreview: string;
  /** 完整内容(消息类,点击展开) */
  readonly fullContent: string;
  readonly visibilityLabel: string;
}

/** 世界AI整理的自动记忆条目(WorldCharacterMemoryEntry) */
export interface AutoMemoryUiModel {
  readonly memoryId: string;
  readonly version: number;
  readonly confidence: number;
  readonly memoryText: string;
  readonly sourceLocationName: string;
  readonly sourceLocationMissing: boolean;
  readonly createdAtLabel: string;
  readonly statusLabel: string;
}

export enum DiagnosticRiskLevel {
  Info = 'info',
  Notice = 'notice',
  Warning = 'warning',
  Critical = 'critical'
}

export interface DiagnosticIssueUiModel {
  readonly id: string;
  readonly issueType: string;
  readonly riskLevel: DiagnosticRiskLevel;
  readonly description: string;
  readonly affectedMemoryId: string;
  readonly affectedRecordId: string;
}

export interface DiagnosticSummaryUiModel {
  readonly totalMemories: number;
  readonly withSourceCount: number;
  readonly withoutSourceCount: number;
  readonly archivedCount: number;
  readonly duplicateSourceMessageCount: number;
  readonly ownerMismatchCount: number;
  readonly worldMismatchCount: number;
  readonly missingSceneRefCount: number;
  readonly missingMessageRefCount: number;
  readonly missingLocationRefCount: number;
  readonly missingCharacterRefCount: number;
  readonly issues: DiagnosticIssueUiModel[];
}

export interface WorldCharacterMemorySnapshotUiModel {
  readonly header: MemoryCharacterHeaderUiModel;
  readonly memories: MemoryItemUiModel[];
  readonly autoMemories: AutoMemoryUiModel[];
  readonly locationOptions: MemoryLocationOptionUiModel[];
  readonly characterSwitcherItems: CharacterSwitcherItemUiModel[];
  readonly timeline: ActivityTimelineItemUiModel[];
  readonly diagnostic: DiagnosticSummaryUiModel;
}

export interface CreateMemoryFormInput {
  readonly content: string;
  readonly type: WorldCharacterMemoryType;
  readonly importance: number;
  readonly sourceLocationId?: string;
  readonly occurredAt?: number;
}

export interface UpdateMemoryFormInput {
  readonly memoryId: string;
  readonly content: string;
  readonly type: WorldCharacterMemoryType;
  readonly importance: number;
  readonly sourceLocationId?: string;
  readonly occurredAt?: number;
}

export interface MemorySaveResult {
  readonly success: boolean;
  readonly errorMessage: string;
}

export class WorldCharacterMemoryViewModel {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly eventRepo: WorldEventRepository;
  private readonly characterService: CharacterService;
  private readonly memoryService: WorldCharacterMemoryService;
  private readonly memoryStoreService: WorldCharacterMemoryStoreService;

  state: WorldCharacterMemoryLoadState = WorldCharacterMemoryLoadState.Loading;
  errorMessage: string = '';
  snapshot: WorldCharacterMemorySnapshotUiModel | null = null;

  private expectedWorldId: string = '';
  private expectedCharacterInstanceId: string = '';
  private loadOperationId: number = 0;
  private operationId: number = 0;
  private disposed: boolean = false;
  isSaving: boolean = false;
  isDeleting: boolean = false;
  readonly instanceShortId: string;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sceneRepo: WorldSceneRepository,
    messageRepo: WorldSceneMessageRepository,
    eventRepo: WorldEventRepository,
    characterService: CharacterService,
    memoryService: WorldCharacterMemoryService,
    memoryStoreService: WorldCharacterMemoryStoreService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.sceneRepo = sceneRepo;
    this.messageRepo = messageRepo;
    this.eventRepo = eventRepo;
    this.characterService = characterService;
    this.memoryService = memoryService;
    this.memoryStoreService = memoryStoreService;
    this.instanceShortId = WorldCharacterMemoryViewModel.generateShortId();
  }

  private static generateShortId(): string {
    const ts: number = Date.now();
    const tail: number = Math.floor(ts % 0xffff);
    return tail.toString(16).padStart(4, '0');
  }

  activate(): void {
    if (this.disposed) {
      this.disposed = false;
    }
  }

  dispose(): void {
    this.disposed = true;
  }

  setTarget(worldId: string, characterInstanceId: string): void {
    if (this.expectedWorldId !== worldId
      || this.expectedCharacterInstanceId !== characterInstanceId) {
      this.expectedWorldId = worldId;
      this.expectedCharacterInstanceId = characterInstanceId;
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  expectedWorldIdOfPage(): string {
    return this.expectedWorldId;
  }

  expectedCharacterInstanceIdOfPage(): string {
    return this.expectedCharacterInstanceId;
  }

  async loadSnapshot(
    worldId: string,
    characterInstanceId: string,
    filter: WorldCharacterMemoryListFilter
  ): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.expectedWorldId = worldId;
    this.expectedCharacterInstanceId = characterInstanceId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;

    this.state = WorldCharacterMemoryLoadState.Loading;
    this.errorMessage = '';

    try {
      const world: World | null = await this.worldRepo.getById(worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.state = WorldCharacterMemoryLoadState.NotFound;
        return;
      }

      const instance: WorldCharacterInstance | null =
        await this.instanceRepo.getById(characterInstanceId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (instance === null) {
        this.state = WorldCharacterMemoryLoadState.NotFound;
        return;
      }
      if (instance.worldId !== worldId) {
        this.state = WorldCharacterMemoryLoadState.NotFound;
        return;
      }

      let character: Character | null = null;
      if (instance.characterId.length > 0) {
        try {
          character = await this.characterService.getById(instance.characterId);
        } catch (e) {
          character = null;
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const characterMissing: boolean = character === null;
      const displayName: string = !characterMissing && character !== null
        ? character.name : instance.displayNameSnapshot;
      const avatarUri: string = !characterMissing && character !== null
        ? character.avatarUri : '';

      let currentLocationName: string = '';
      let locationMissing: boolean = false;
      if (instance.currentLocationId !== undefined && instance.currentLocationId.length > 0) {
        try {
          const loc: WorldLocation | null =
            await this.locationRepo.getById(instance.currentLocationId);
          if (loc !== null) {
            currentLocationName = loc.name;
          } else {
            locationMissing = true;
          }
        } catch (e) {
          locationMissing = true;
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      let locations: WorldLocation[] = [];
      try {
        locations = await this.locationRepo.listByWorld(worldId);
      } catch (e) {
        locations = [];
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      const locationMap: Map<string, WorldLocation> = new Map<string, WorldLocation>();
      for (let i = 0; i < locations.length; i++) {
        locationMap.set(locations[i].id, locations[i]);
      }

      const memoryFilter: WorldCharacterMemoryFilter = this.toServiceFilter(filter);
      let memories: WorldCharacterMemory[] = [];
      try {
        memories = await this.memoryService.listByCharacterInstance(characterInstanceId, memoryFilter);
      } catch (e) {
        memories = [];
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      let allMemories: WorldCharacterMemory[] = [];
      try {
        allMemories = await this.memoryService.listByCharacterInstance(
          characterInstanceId, WorldCharacterMemoryFilter.All);
      } catch (e) {
        allMemories = memories;
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      let memoryCount: number = 0;
      try {
        memoryCount = await this.memoryService.countByCharacterInstance(characterInstanceId);
      } catch (e) {
        memoryCount = allMemories.length;
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      let worldInstances: WorldCharacterInstance[] = [];
      try {
        worldInstances = await this.instanceRepo.listByWorld(worldId);
      } catch (e) {
        worldInstances = [];
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      const instanceCharacterCache: Map<string, Character | null> = new Map<string, Character | null>();
      const switcherItems: CharacterSwitcherItemUiModel[] = [];
      for (let i = 0; i < worldInstances.length; i++) {
        const inst: WorldCharacterInstance = worldInstances[i];
        let char: Character | null | undefined = instanceCharacterCache.get(inst.characterId);
        if (char === undefined) {
          try {
            char = await this.characterService.getById(inst.characterId);
          } catch (e) {
            char = null;
          }
          instanceCharacterCache.set(inst.characterId, char);
        }
        const iName: string = char !== null ? char.name : inst.displayNameSnapshot;
        const iAvatar: string = char !== null ? char.avatarUri : '';
        const iFallback: string = inst.displayNameSnapshot;
        switcherItems.push({
          instanceId: inst.id,
          displayName: iName,
          avatarUri: iAvatar,
          fallbackName: iFallback,
          isActive: inst.isActive
        });
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      let lastActivityTime: number = instance.updatedAt;

      let worldScenes: WorldScene[] = [];
      try {
        worldScenes = await this.sceneRepo.listByWorld(worldId);
      } catch (e) {
        worldScenes = [];
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      const sceneCache: Map<string, WorldScene> = new Map<string, WorldScene>();
      for (let i = 0; i < worldScenes.length; i++) {
        sceneCache.set(worldScenes[i].id, worldScenes[i]);
      }

      // ===== 统一活动时间线(发言 / 移动 / 场景生命周期,按时间倒序) =====
      const timeline: ActivityTimelineItemUiModel[] = [];
      const relevantSceneIds: Set<string> = new Set<string>();

      // 1. 场景生命周期条目
      for (let i = 0; i < worldScenes.length; i++) {
        const scene: WorldScene = worldScenes[i];
        try {
          const msgs: WorldSceneMessage[] = await this.messageRepo.listByScene(scene.id);
          let charConnected: boolean = false;
          for (let j = 0; j < msgs.length; j++) {
            if (this.isMessageConnectedToCharacter(msgs[j], characterInstanceId)) {
              charConnected = true;
              break;
            }
          }
          if (!charConnected) {
            continue;
          }
          relevantSceneIds.add(scene.id);
          const locInfo: WorldLocation | undefined = locationMap.get(scene.locationId);
          const locName: string = locInfo !== undefined ? locInfo.name : '(地点已删除)';
          const locMissing: boolean = locInfo === undefined;
          timeline.push({
            id: 'scene-start-' + scene.id,
            kind: 'scene',
            occurredAt: scene.startedAt,
            occurredAtLabel: formatWorldTimestamp(scene.startedAt),
            locationName: locName,
            locationMissing: locMissing,
            headline: '场景开始',
            coParticipantNames: [],
            contentPreview: '',
            fullContent: '',
            visibilityLabel: ''
          });
          const endedAtVal: number = scene.endedAt !== undefined ? scene.endedAt : 0;
          if (endedAtVal > 0) {
            timeline.push({
              id: 'scene-end-' + scene.id,
              kind: 'scene',
              occurredAt: endedAtVal,
              occurredAtLabel: formatWorldTimestamp(endedAtVal),
              locationName: locName,
              locationMissing: locMissing,
              headline: '场景结束',
              coParticipantNames: [],
              contentPreview: '',
              fullContent: '',
              visibilityLabel: ''
            });
          }
          if (scene.updatedAt > lastActivityTime) {
            lastActivityTime = scene.updatedAt;
          }
        } catch (e) {
          continue;
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 2. 消息条目(该角色发言 / 在场 / 旁白可见)
      const relevantSceneIdList: string[] = Array.from(relevantSceneIds);
      for (let i = 0; i < relevantSceneIdList.length; i++) {
        try {
          const msgs: WorldSceneMessage[] = await this.messageRepo.listByScene(relevantSceneIdList[i]);
          const scene: WorldScene | undefined = sceneCache.get(relevantSceneIdList[i]);
          for (let j = 0; j < msgs.length; j++) {
            const msg: WorldSceneMessage = msgs[j];
            const role: string = this.roleLabelForMessage(msg, characterInstanceId);
            if (role === '') {
              continue;
            }
            const locId: string = scene !== undefined ? scene.locationId : '';
            const locInfo: WorldLocation | undefined = locId !== '' ? locationMap.get(locId) : undefined;
            const locName: string = locInfo !== undefined ? locInfo.name : '(地点已删除)';
            const locMissing: boolean = locInfo === undefined;
            const senderName: string = this.senderNameForMessage(msg, characterInstanceId,
              worldInstances, instanceCharacterCache);
            const coNames: string[] = this.coParticipantNames(msg, characterInstanceId,
              worldInstances, instanceCharacterCache);
            const content: string = msg.content;
            const preview: string = content.length > 60 ? content.substring(0, 60) + '…' : content;
            timeline.push({
              id: msg.id,
              kind: 'message',
              occurredAt: msg.createdAt,
              occurredAtLabel: formatWorldTimestamp(msg.createdAt),
              locationName: locName,
              locationMissing: locMissing,
              headline: role + (senderName.length > 0 ? ' · ' + senderName : ''),
              coParticipantNames: coNames,
              contentPreview: preview,
              fullContent: content,
              visibilityLabel: this.visibilityLabel(msg.visibility)
            });
            if (msg.createdAt > lastActivityTime) {
              lastActivityTime = msg.createdAt;
            }
          }
        } catch (e) {
          continue;
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 3. 移动条目
      try {
        const events: WorldEvent[] = await this.eventRepo.listByWorld(worldId);
        for (let i = 0; i < events.length; i++) {
          if (events[i].eventType === WorldEventType.CharacterMoved
            && events[i].sourceCharacterInstanceId === characterInstanceId) {
            const fromLoc: WorldLocation | undefined =
              events[i].sourceLocationId !== undefined
                ? locationMap.get(events[i].sourceLocationId!) : undefined;
            const toLoc: WorldLocation | undefined =
              events[i].targetLocationId !== undefined
                ? locationMap.get(events[i].targetLocationId!) : undefined;
            const toName: string = toLoc !== undefined ? toLoc.name : '(未知)';
            timeline.push({
              id: 'move-' + events[i].id,
              kind: 'move',
              occurredAt: events[i].occurredAt,
              occurredAtLabel: formatWorldTimestamp(events[i].occurredAt),
              locationName: toName,
              locationMissing: toLoc === undefined,
              headline: '移动到「' + toName + '」',
              coParticipantNames: [],
              contentPreview: '',
              fullContent: '',
              visibilityLabel: ''
            });
          }
        }
      } catch (e) {
        // ignored
      }
      timeline.sort((a: ActivityTimelineItemUiModel, b: ActivityTimelineItemUiModel) => {
        return b.occurredAt - a.occurredAt;
      });
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 4. 世界AI整理的自动记忆条目
      let autoMemories: AutoMemoryUiModel[] = [];
      try {
        const entries: WorldCharacterMemoryEntry[] =
          await this.memoryStoreService.listActiveMemoriesForOwner(worldId, characterInstanceId);
        for (let i = 0; i < entries.length; i++) {
          const entry: WorldCharacterMemoryEntry = entries[i];
          const locInfo: WorldLocation | undefined = locationMap.get(entry.sourceLocationId);
          autoMemories.push({
            memoryId: entry.id,
            version: entry.version,
            confidence: entry.confidence,
            memoryText: entry.memoryText,
            sourceLocationName: locInfo !== undefined ? locInfo.name : '(地点已删除)',
            sourceLocationMissing: locInfo === undefined,
            createdAtLabel: formatWorldTimestamp(entry.createdAt),
            statusLabel: entry.status === WorldCharacterMemoryEntryStatus.Active ? '活跃' : entry.status
          });
        }
      } catch (e) {
        autoMemories = [];
      }

      const diagnostic: DiagnosticSummaryUiModel =
        this.buildDiagnostic(allMemories, worldId, characterInstanceId,
          worldInstances, sceneCache, locationMap);

      const header: MemoryCharacterHeaderUiModel = {
        worldId: world.id,
        worldName: world.name,
        characterInstanceId: instance.id,
        displayName: displayName,
        fallbackName: instance.displayNameSnapshot,
        avatarUri: avatarUri,
        isActive: instance.isActive,
        characterCardMissing: characterMissing,
        currentLocationId: instance.currentLocationId !== undefined ? instance.currentLocationId : '',
        currentLocationName: currentLocationName,
        locationMissing: locationMissing,
        memoryCount: memoryCount,
        lastActivityTime: lastActivityTime,
        instanceId: instance.id,
        characterId: instance.characterId
      };

      const locationOptions: MemoryLocationOptionUiModel[] =
        new Array<MemoryLocationOptionUiModel>(locations.length);
      for (let i = 0; i < locations.length; i++) {
        locationOptions[i] = {
          id: locations[i].id,
          name: locations[i].name,
          status: locations[i].status
        };
      }

      const memoryItems: MemoryItemUiModel[] = new Array<MemoryItemUiModel>(memories.length);
      for (let i = 0; i < memories.length; i++) {
        memoryItems[i] = this.buildMemoryItem(memories[i], locationMap, sceneCache);
      }

      const snapshot: WorldCharacterMemorySnapshotUiModel = {
        header: header,
        memories: memoryItems,
        autoMemories: autoMemories,
        locationOptions: locationOptions,
        characterSwitcherItems: switcherItems,
        timeline: timeline,
        diagnostic: diagnostic
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.snapshot = snapshot;
      this.state = WorldCharacterMemoryLoadState.Ready;
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.errorMessage = '记忆数据加载失败,请重试';
      this.state = WorldCharacterMemoryLoadState.Error;
    }
  }

  async createMemory(input: CreateMemoryFormInput): Promise<MemorySaveResult> {
    if (this.isSaving) {
      return { success: false, errorMessage: '正在处理,请稍候' } as MemorySaveResult;
    }
    if (this.expectedWorldId.length === 0 || this.expectedCharacterInstanceId.length === 0) {
      return { success: false, errorMessage: '目标未加载' } as MemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const serviceInput: CreateManualWorldMemoryInput = {
        worldId: this.expectedWorldId,
        characterInstanceId: this.expectedCharacterInstanceId,
        content: input.content,
        type: input.type,
        importance: input.importance,
        sourceLocationId: input.sourceLocationId,
        occurredAt: input.occurredAt
      };
      await this.memoryService.createManualMemory(serviceInput);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      return { success: true, errorMessage: '' } as MemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      return { success: false, errorMessage: msg } as MemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  async updateMemory(input: UpdateMemoryFormInput): Promise<MemorySaveResult> {
    if (this.isSaving) {
      return { success: false, errorMessage: '正在处理,请稍候' } as MemorySaveResult;
    }
    if (input.memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as MemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const serviceInput: UpdateWorldMemoryInput = {
        memoryId: input.memoryId,
        content: input.content,
        type: input.type,
        importance: input.importance,
        sourceLocationId: input.sourceLocationId,
        occurredAt: input.occurredAt
      };
      await this.memoryService.updateMemory(serviceInput);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      return { success: true, errorMessage: '' } as MemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      return { success: false, errorMessage: msg } as MemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  async setMemoryArchived(
    memoryId: string,
    archived: boolean
  ): Promise<MemorySaveResult> {
    if (this.isSaving || this.isDeleting) {
      return { success: false, errorMessage: '正在处理,请稍候' } as MemorySaveResult;
    }
    if (memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as MemorySaveResult;
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.memoryService.setMemoryArchived(memoryId, archived);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      return { success: true, errorMessage: '' } as MemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      return { success: false, errorMessage: msg } as MemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  async deleteMemory(memoryId: string): Promise<MemorySaveResult> {
    if (this.isDeleting) {
      return { success: false, errorMessage: '正在处理,请稍候' } as MemorySaveResult;
    }
    if (memoryId.length === 0) {
      return { success: false, errorMessage: '记忆未选定' } as MemorySaveResult;
    }
    this.isDeleting = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.memoryService.deleteMemory(memoryId);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      return { success: true, errorMessage: '' } as MemorySaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as MemorySaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      return { success: false, errorMessage: msg } as MemorySaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isDeleting = false;
      }
    }
  }

  private toServiceFilter(filter: WorldCharacterMemoryListFilter): WorldCharacterMemoryFilter {
    if (filter === WorldCharacterMemoryListFilter.Active) {
      return WorldCharacterMemoryFilter.Active;
    }
    if (filter === WorldCharacterMemoryListFilter.Archived) {
      return WorldCharacterMemoryFilter.Archived;
    }
    if (filter === WorldCharacterMemoryListFilter.Manual) {
      return WorldCharacterMemoryFilter.All;
    }
    if (filter === WorldCharacterMemoryListFilter.Scene) {
      return WorldCharacterMemoryFilter.All;
    }
    return WorldCharacterMemoryFilter.All;
  }

  private buildMemoryItem(
    memory: WorldCharacterMemory,
    locationMap: Map<string, WorldLocation>,
    sceneMap: Map<string, WorldScene>
  ): MemoryItemUiModel {
    let sourceLocationName: string = '';
    let sourceLocationMissing: boolean = false;
    if (memory.sourceLocationId !== undefined && memory.sourceLocationId.length > 0) {
      const loc: WorldLocation | undefined = locationMap.get(memory.sourceLocationId);
      if (loc !== undefined) {
        sourceLocationName = loc.name;
      } else {
        sourceLocationMissing = true;
      }
    }
    let sourceSceneName: string = '';
    let sourceSceneMissing: boolean = false;
    if (memory.sourceSceneId !== undefined && memory.sourceSceneId.length > 0) {
      const scene: WorldScene | undefined = sceneMap.get(memory.sourceSceneId);
      if (scene !== undefined) {
        const loc: WorldLocation | undefined = locationMap.get(scene.locationId);
        sourceSceneName = loc !== undefined ? loc.name : '未知地点';
      } else {
        sourceSceneMissing = true;
      }
    }
    let sourceMessageMissing: boolean = false;
    if (memory.sourceMessageId !== undefined && memory.sourceMessageId.length > 0) {
      sourceMessageMissing = false;
    }
    const hasEvidence: boolean = memory.sourceSceneId !== undefined
      || memory.sourceMessageId !== undefined;
    const sourceSummary: string = this.buildSourceSummary(
      memory, sourceLocationName, sourceLocationMissing,
      sourceSceneName, sourceSceneMissing);
    return {
      id: memory.id,
      type: memory.type,
      typeLabel: this.typeLabel(memory.type),
      origin: memory.origin,
      originLabel: this.originLabel(memory.origin),
      status: memory.status,
      statusLabel: this.statusLabel(memory.status),
      content: memory.content,
      importance: memory.importance,
      sourceLocationId: memory.sourceLocationId !== undefined ? memory.sourceLocationId : '',
      sourceLocationName: sourceLocationName,
      sourceLocationMissing: sourceLocationMissing,
      sourceSceneId: memory.sourceSceneId !== undefined ? memory.sourceSceneId : '',
      sourceSceneName: sourceSceneName,
      sourceSceneMissing: sourceSceneMissing,
      sourceMessageId: memory.sourceMessageId !== undefined ? memory.sourceMessageId : '',
      sourceMessageMissing: sourceMessageMissing,
      sourceSummary: sourceSummary,
      occurredAt: memory.occurredAt !== undefined ? memory.occurredAt : 0,
      occurredAtLabel: memory.occurredAt !== undefined ? formatWorldTimestamp(memory.occurredAt) : '',
      createdAt: memory.createdAt,
      createdAtLabel: formatWorldTimestamp(memory.createdAt),
      updatedAt: memory.updatedAt,
      updatedAtLabel: formatWorldTimestamp(memory.updatedAt),
      worldId: memory.worldId,
      characterInstanceId: memory.characterInstanceId,
      hasEvidence: hasEvidence
    };
  }

  private buildSourceSummary(
    memory: WorldCharacterMemory,
    locationName: string,
    locationMissing: boolean,
    sceneName: string,
    sceneMissing: boolean
  ): string {
    const parts: string[] = [];
    if (memory.origin === WorldCharacterMemoryOrigin.SceneMessage) {
      if (sceneMissing) {
        parts.push('场景已删除');
      } else if (sceneName.length > 0) {
        parts.push(sceneName);
      } else {
        parts.push('场景消息');
      }
    }
    const locationId: string = memory.sourceLocationId ?? '';
    if (locationId.length > 0) {
      if (locationMissing) {
        parts.push('地点已删除');
      } else if (locationName.length > 0) {
        parts.push(locationName);
      }
    }
    return parts.join(' · ');
  }

  private buildDiagnostic(
    allMemories: WorldCharacterMemory[],
    worldId: string,
    characterInstanceId: string,
    worldInstances: WorldCharacterInstance[],
    sceneMap: Map<string, WorldScene>,
    locationMap: Map<string, WorldLocation>
  ): DiagnosticSummaryUiModel {
    let withSourceCount: number = 0;
    let withoutSourceCount: number = 0;
    let archivedCount: number = 0;
    let ownerMismatchCount: number = 0;
    let worldMismatchCount: number = 0;
    let missingSceneRefCount: number = 0;
    let missingMessageRefCount: number = 0;
    let missingLocationRefCount: number = 0;
    const sourceMessageIds: Map<string, number> = new Map<string, number>();
    const issues: DiagnosticIssueUiModel[] = [];

    for (let i = 0; i < allMemories.length; i++) {
      const m: WorldCharacterMemory = allMemories[i];
      if (m.status === WorldCharacterMemoryStatus.Archived) {
        archivedCount++;
      }
      if (m.sourceSceneId !== undefined || m.sourceMessageId !== undefined) {
        withSourceCount++;
      } else {
        withoutSourceCount++;
      }
      if (m.worldId !== worldId) {
        worldMismatchCount++;
        issues.push({
          id: 'world-mismatch-' + m.id,
          issueType: 'MEMORY_WORLD_MISMATCH',
          riskLevel: DiagnosticRiskLevel.Critical,
          description: '记忆 worldId 指向其他世界',
          affectedMemoryId: m.id,
          affectedRecordId: m.worldId
        });
      }
      if (m.characterInstanceId !== characterInstanceId) {
        ownerMismatchCount++;
        issues.push({
          id: 'owner-mismatch-' + m.id,
          issueType: 'MEMORY_OWNER_MISMATCH',
          riskLevel: DiagnosticRiskLevel.Critical,
          description: '记忆 characterInstanceId 不匹配当前角色',
          affectedMemoryId: m.id,
          affectedRecordId: m.characterInstanceId
        });
      }
      if (m.sourceSceneId !== undefined && m.sourceSceneId.length > 0) {
        if (!sceneMap.has(m.sourceSceneId)) {
          missingSceneRefCount++;
          issues.push({
            id: 'missing-scene-' + m.id,
            issueType: 'MISSING_SOURCE_SCENE',
            riskLevel: DiagnosticRiskLevel.Warning,
            description: '来源场景不存在',
            affectedMemoryId: m.id,
            affectedRecordId: m.sourceSceneId
          });
        }
      }
      if (m.sourceMessageId !== undefined && m.sourceMessageId.length > 0) {
        const count: number | undefined = sourceMessageIds.get(m.sourceMessageId);
        if (count !== undefined) {
          sourceMessageIds.set(m.sourceMessageId, count + 1);
        } else {
          sourceMessageIds.set(m.sourceMessageId, 1);
        }
      }
      if (m.sourceLocationId !== undefined && m.sourceLocationId.length > 0) {
        if (!locationMap.has(m.sourceLocationId)) {
          missingLocationRefCount++;
          issues.push({
            id: 'missing-location-' + m.id,
            issueType: 'MISSING_LOCATION',
            riskLevel: DiagnosticRiskLevel.Notice,
            description: '来源地点不存在',
            affectedMemoryId: m.id,
            affectedRecordId: m.sourceLocationId
          });
        }
      }
    }

    let duplicateSourceMessageCount: number = 0;
    const keys: string[] = Array.from(sourceMessageIds.keys());
    for (let i = 0; i < keys.length; i++) {
      if (sourceMessageIds.get(keys[i])! > 1) {
        duplicateSourceMessageCount++;
        issues.push({
          id: 'dup-source-' + keys[i],
          issueType: 'DUPLICATE_SOURCE_REFERENCE',
          riskLevel: DiagnosticRiskLevel.Notice,
          description: '同一来源消息被多条记忆引用',
          affectedMemoryId: '',
          affectedRecordId: keys[i]
        });
      }
    }

    return {
      totalMemories: allMemories.length,
      withSourceCount: withSourceCount,
      withoutSourceCount: withoutSourceCount,
      archivedCount: archivedCount,
      duplicateSourceMessageCount: duplicateSourceMessageCount,
      ownerMismatchCount: ownerMismatchCount,
      worldMismatchCount: worldMismatchCount,
      missingSceneRefCount: missingSceneRefCount,
      missingMessageRefCount: missingMessageRefCount,
      missingLocationRefCount: missingLocationRefCount,
      missingCharacterRefCount: 0,
      issues: issues
    };
  }

  private typeLabel(type: WorldCharacterMemoryType): string {
    if (type === WorldCharacterMemoryType.Episodic) {
      return '事件记忆';
    }
    if (type === WorldCharacterMemoryType.Semantic) {
      return '事实认知';
    }
    return '反思总结';
  }

  private originLabel(origin: WorldCharacterMemoryOrigin): string {
    return origin === WorldCharacterMemoryOrigin.Manual ? '手动' : '场景';
  }

  private statusLabel(status: WorldCharacterMemoryStatus): string {
    return status === WorldCharacterMemoryStatus.Active ? '活跃' : '已归档';
  }

  private visibilityLabel(v: string): string {
    if (v === 'public') {
      return '公开';
    }
    if (v === 'private') {
      return '私下';
    }
    if (v === 'narrator') {
      return '旁白';
    }
    return v;
  }

  /** 消息是否与角色相关(发言 / 参与 / 目击) */
  private isMessageConnectedToCharacter(
    msg: WorldSceneMessage,
    characterInstanceId: string
  ): boolean {
    if (msg.status !== WorldSceneMessageStatus.Completed) {
      return false;
    }
    if (msg.content.trim().length === 0) {
      return false;
    }
    if (msg.senderCharacterInstanceId === characterInstanceId) {
      return true;
    }
    if (msg.participantCharacterInstanceIds !== undefined
      && msg.participantCharacterInstanceIds.indexOf(characterInstanceId) >= 0) {
      return true;
    }
    if (msg.witnessCharacterInstanceIds !== undefined
      && msg.witnessCharacterInstanceIds.indexOf(characterInstanceId) >= 0) {
      return true;
    }
    return false;
  }

  /** 角色在该消息中的角色标签('' 表示无关;'发言' / '对话' / '旁白' / '在场') */
  private roleLabelForMessage(
    msg: WorldSceneMessage,
    characterInstanceId: string
  ): string {
    if (!this.isMessageConnectedToCharacter(msg, characterInstanceId)) {
      return '';
    }
    if (msg.senderType === WorldSceneMessageSenderType.Narrator) {
      return '旁白';
    }
    if (msg.senderCharacterInstanceId === characterInstanceId) {
      return '发言';
    }
    if (msg.senderType === WorldSceneMessageSenderType.User) {
      return '对话';
    }
    return '在场';
  }

  /** 消息发送者显示名(发言/对话时的说话人) */
  private senderNameForMessage(
    msg: WorldSceneMessage,
    characterInstanceId: string,
    worldInstances: WorldCharacterInstance[],
    instanceCharacterCache: Map<string, Character | null>
  ): string {
    if (msg.senderType === WorldSceneMessageSenderType.User) {
      return '玩家';
    }
    if (msg.senderType === WorldSceneMessageSenderType.Narrator) {
      return '旁白';
    }
    if (msg.senderCharacterInstanceId === undefined) {
      return '';
    }
    const senderId: string = msg.senderCharacterInstanceId;
    if (senderId === characterInstanceId) {
      return '本人';
    }
    for (let i = 0; i < worldInstances.length; i++) {
      if (worldInstances[i].id === senderId) {
        const pChar: Character | null | undefined = instanceCharacterCache.get(worldInstances[i].characterId);
        return pChar !== null && pChar !== undefined
          ? pChar.name : worldInstances[i].displayNameSnapshot;
      }
    }
    return '';
  }

  /** 与该消息相关的在场角色名(排除自己) */
  private coParticipantNames(
    msg: WorldSceneMessage,
    characterInstanceId: string,
    worldInstances: WorldCharacterInstance[],
    instanceCharacterCache: Map<string, Character | null>
  ): string[] {
    const result: string[] = [];
    const seen: Set<string> = new Set<string>();
    const idsToScan: string[] = [];
    if (msg.participantCharacterInstanceIds !== undefined) {
      for (let i = 0; i < msg.participantCharacterInstanceIds.length; i++) {
        idsToScan.push(msg.participantCharacterInstanceIds[i]);
      }
    }
    if (msg.witnessCharacterInstanceIds !== undefined) {
      for (let i = 0; i < msg.witnessCharacterInstanceIds.length; i++) {
        idsToScan.push(msg.witnessCharacterInstanceIds[i]);
      }
    }
    if (msg.senderType === WorldSceneMessageSenderType.Character
      && msg.senderCharacterInstanceId !== undefined) {
      idsToScan.push(msg.senderCharacterInstanceId);
    }
    for (let i = 0; i < idsToScan.length; i++) {
      const pid: string = idsToScan[i];
      if (pid === characterInstanceId || seen.has(pid)) {
        continue;
      }
      seen.add(pid);
      const pInst: WorldCharacterInstance | undefined =
        worldInstances.find((inst: WorldCharacterInstance) => inst.id === pid);
      if (pInst !== undefined) {
        const pChar: Character | null | undefined = instanceCharacterCache.get(pInst.characterId);
        result.push(pChar !== null && pChar !== undefined ? pChar.name : pInst.displayNameSnapshot);
      }
    }
    return result;
  }

  private resolveErrorMessage(e: Object): string {
    return mapWorldMemoryErrorToMessage(e);
  }

  private safeErrorCategory(e: Object): string {
    if (e instanceof DatabaseError) {
      return 'DatabaseError:' + e.type;
    }
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }

  private shortId(id: string): string {
    if (id.length <= 8) {
      return id;
    }
    return id.substring(id.length - 8);
  }
}
