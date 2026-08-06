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
import { Logger } from '../../utils/Logger';
import { World } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import { WorldSceneMessage, WorldSceneMessageSenderType } from '../../models/world/WorldSceneMessage';
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
  readonly locationOptions: MemoryLocationOptionUiModel[];
  readonly characterSwitcherItems: CharacterSwitcherItemUiModel[];
  readonly activityScenes: ActivitySceneUiModel[];
  readonly activityMessages: ActivityMessageUiModel[];
  readonly activityMoves: ActivityMoveUiModel[];
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
    memoryService: WorldCharacterMemoryService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.sceneRepo = sceneRepo;
    this.messageRepo = messageRepo;
    this.eventRepo = eventRepo;
    this.characterService = characterService;
    this.memoryService = memoryService;
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

      const activityScenes: ActivitySceneUiModel[] = [];
      const relevantSceneIds: Set<string> = new Set<string>();
      for (let i = 0; i < worldScenes.length; i++) {
        const scene: WorldScene = worldScenes[i];
        try {
          const msgs: WorldSceneMessage[] = await this.messageRepo.listByScene(scene.id);
          let charSpoke: boolean = false;
          let participantIds: Set<string> = new Set<string>();
          for (let j = 0; j < msgs.length; j++) {
            if (msgs[j].senderCharacterInstanceId === characterInstanceId) {
              charSpoke = true;
            }
            if (msgs[j].participantCharacterInstanceIds !== undefined) {
              for (let k = 0; k < msgs[j].participantCharacterInstanceIds!.length; k++) {
                participantIds.add(msgs[j].participantCharacterInstanceIds![k]);
              }
            }
          }
          if (charSpoke || participantIds.has(characterInstanceId)) {
            relevantSceneIds.add(scene.id);
            const locInfo: WorldLocation | undefined = locationMap.get(scene.locationId);
            const endedAtVal: number = scene.endedAt !== undefined ? scene.endedAt : 0;
            activityScenes.push({
              sceneId: scene.id,
              locationName: locInfo !== undefined ? locInfo.name : '',
              locationMissing: locInfo === undefined,
              startedAt: scene.startedAt,
              startedAtLabel: formatWorldTimestamp(scene.startedAt),
              endedAt: endedAtVal,
              endedAtLabel: endedAtVal > 0 ? formatWorldTimestamp(endedAtVal) : '',
              status: scene.status,
              statusLabel: scene.status === WorldSceneStatus.Active ? '进行中' : '已结束',
              messageCount: msgs.length,
              participantCount: participantIds.size,
              characterSpoke: charSpoke
            });
            if (scene.updatedAt > lastActivityTime) {
              lastActivityTime = scene.updatedAt;
            }
          }
        } catch (e) {
          continue;
        }
      }
      activityScenes.sort((a: ActivitySceneUiModel, b: ActivitySceneUiModel) => {
        return b.startedAt - a.startedAt;
      });
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      const activityMessages: ActivityMessageUiModel[] = [];
      for (let i = 0; i < activityScenes.length && i < 20; i++) {
        const ascene: ActivitySceneUiModel = activityScenes[i];
        try {
          const msgs: WorldSceneMessage[] = await this.messageRepo.listByScene(ascene.sceneId);
          for (let j = 0; j < msgs.length; j++) {
            if (msgs[j].senderCharacterInstanceId === characterInstanceId) {
              const locInfo: WorldLocation | undefined = locationMap.get(ascene.sceneId.length > 0
                ? (sceneCache.has(ascene.sceneId)
                  ? sceneCache.get(ascene.sceneId)!.locationId
                  : '')
                : '');
              const locName: string = locInfo !== undefined ? locInfo.name : ascene.locationName;
              const locMissing: boolean = locInfo === undefined && ascene.locationMissing;
              const coNames: string[] = [];
              if (msgs[j].participantCharacterInstanceIds !== undefined) {
                for (let k = 0; k < msgs[j].participantCharacterInstanceIds!.length; k++) {
                  const pid: string = msgs[j].participantCharacterInstanceIds![k];
                  if (pid !== characterInstanceId) {
                    const pInst: WorldCharacterInstance | undefined =
                      worldInstances.find((inst: WorldCharacterInstance) => inst.id === pid);
                    if (pInst !== undefined) {
                      const pChar: Character | null | undefined =
                        instanceCharacterCache.get(pInst.characterId);
                      coNames.push(pChar !== null && pChar !== undefined
                        ? pChar.name : pInst.displayNameSnapshot);
                    }
                  }
                }
              }
              const preview: string = msgs[j].content.length > 80
                ? msgs[j].content.substring(0, 80) + '…'
                : msgs[j].content;
              activityMessages.push({
                messageId: msgs[j].id,
                sceneId: ascene.sceneId,
                locationName: locName,
                locationMissing: locMissing,
                sentAt: msgs[j].createdAt,
                sentAtLabel: formatWorldTimestamp(msgs[j].createdAt),
                contentPreview: preview,
                visibility: msgs[j].visibility,
                visibilityLabel: this.visibilityLabel(msgs[j].visibility),
                coParticipantNames: coNames
              });
              if (msgs[j].createdAt > lastActivityTime) {
                lastActivityTime = msgs[j].createdAt;
              }
            }
          }
        } catch (e) {
          continue;
        }
      }
      activityMessages.sort((a: ActivityMessageUiModel, b: ActivityMessageUiModel) => {
        return b.sentAt - a.sentAt;
      });
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      const activityMoves: ActivityMoveUiModel[] = [];
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
            activityMoves.push({
              eventId: events[i].id,
              fromLocationName: fromLoc !== undefined ? fromLoc.name : '',
              fromLocationMissing: fromLoc === undefined
                && events[i].sourceLocationId !== undefined,
              toLocationName: toLoc !== undefined ? toLoc.name : '',
              toLocationMissing: toLoc === undefined
                && events[i].targetLocationId !== undefined,
              occurredAt: events[i].occurredAt,
              occurredAtLabel: formatWorldTimestamp(events[i].occurredAt)
            });
          }
        }
      } catch (e) {
        // ignored
      }
      activityMoves.sort((a: ActivityMoveUiModel, b: ActivityMoveUiModel) => {
        return b.occurredAt - a.occurredAt;
      });
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
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
        locationOptions: locationOptions,
        characterSwitcherItems: switcherItems,
        activityScenes: activityScenes,
        activityMessages: activityMessages,
        activityMoves: activityMoves,
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
