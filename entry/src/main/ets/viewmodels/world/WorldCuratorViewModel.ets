import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldCharacterMemoryRepository } from '../../repositories/world/WorldCharacterMemoryRepository';
import { WorldEventRepository } from '../../repositories/world/WorldEventRepository';
import { CharacterService } from '../../services/CharacterService';
import { World } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldScene } from '../../models/world/WorldScene';
import { WorldSceneMessage } from '../../models/world/WorldSceneMessage';
import { WorldCharacterMemory } from '../../models/world/WorldCharacterMemory';
import { WorldEvent } from '../../models/world/WorldEvent';
import { Character } from '../../models/Character';
import { formatWorldTimestamp } from './WorldUiModels';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldCuratorViewModel';

export enum CuratorLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

export enum CuratorTab {
  Overview = 'overview',
  Issues = 'issues',
  Suggestions = 'suggestions',
  AuditLog = 'audit_log'
}

export enum ConsistencyRiskLevel {
  Info = 'info',
  Notice = 'notice',
  Warning = 'warning',
  Critical = 'critical'
}

export interface CuratorSummaryUiModel {
  readonly worldName: string;
  readonly characterCount: number;
  readonly locationCount: number;
  readonly sceneCount: number;
  readonly memoryCount: number;
  readonly pendingCheckCount: number;
}

export interface CuratorOverviewItemUiModel {
  readonly category: string;
  readonly total: number;
  readonly valid: number;
  readonly missingRef: number;
  readonly pendingCheck: number;
}

export interface ConsistencyIssueUiModel {
  readonly id: string;
  readonly issueType: string;
  readonly issueTypeLabel: string;
  readonly riskLevel: ConsistencyRiskLevel;
  readonly riskLabel: string;
  readonly description: string;
  readonly affectedCharacterId: string;
  readonly affectedCharacterName: string;
  readonly affectedLocationId: string;
  readonly affectedLocationName: string;
  readonly affectedSceneId: string;
  readonly affectedRecordId: string;
  readonly discoveredAt: number;
  readonly discoveredAtLabel: string;
  readonly checkMethod: string;
}

export interface CuratorSnapshotUiModel {
  readonly summary: CuratorSummaryUiModel;
  readonly overviewItems: CuratorOverviewItemUiModel[];
  readonly issues: ConsistencyIssueUiModel[];
}

export class WorldCuratorViewModel {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly memoryRepo: WorldCharacterMemoryRepository;
  private readonly eventRepo: WorldEventRepository;
  private readonly characterService: CharacterService;

  state: CuratorLoadState = CuratorLoadState.Loading;
  errorMessage: string = '';
  snapshot: CuratorSnapshotUiModel | null = null;
  private disposed: boolean = false;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sceneRepo: WorldSceneRepository,
    messageRepo: WorldSceneMessageRepository,
    memoryRepo: WorldCharacterMemoryRepository,
    eventRepo: WorldEventRepository,
    characterService: CharacterService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.sceneRepo = sceneRepo;
    this.messageRepo = messageRepo;
    this.memoryRepo = memoryRepo;
    this.eventRepo = eventRepo;
    this.characterService = characterService;
  }

  dispose(): void {
    this.disposed = true;
  }

  async loadSnapshot(worldId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.state = CuratorLoadState.Loading;
    this.errorMessage = '';

    try {
      const world: World | null = await this.worldRepo.getById(worldId);
      if (this.disposed) {
        return;
      }
      if (world === null) {
        this.state = CuratorLoadState.NotFound;
        return;
      }

      const locations: WorldLocation[] = await this.locationRepo.listByWorld(worldId);
      if (this.disposed) {
        return;
      }
      const locationMap: Map<string, WorldLocation> = new Map<string, WorldLocation>();
      let activeLocations: number = 0;
      for (let i = 0; i < locations.length; i++) {
        locationMap.set(locations[i].id, locations[i]);
        if (locations[i].status === 'active') {
          activeLocations++;
        }
      }

      const instances: WorldCharacterInstance[] = await this.instanceRepo.listByWorld(worldId);
      if (this.disposed) {
        return;
      }
      const instanceMap: Map<string, WorldCharacterInstance> = new Map<string, WorldCharacterInstance>();
      let activeInstances: number = 0;
      let instancesMissingLocation: number = 0;
      const characterCache: Map<string, string> = new Map<string, string>();
      for (let i = 0; i < instances.length; i++) {
        instanceMap.set(instances[i].id, instances[i]);
        if (instances[i].isActive) {
          activeInstances++;
        }
        if (instances[i].currentLocationId !== undefined
          && instances[i].currentLocationId!.length > 0
          && !locationMap.has(instances[i].currentLocationId!)) {
          instancesMissingLocation++;
        }
        if (!characterCache.has(instances[i].characterId)) {
          try {
            const ch: Character | null = await this.characterService.getById(instances[i].characterId);
            characterCache.set(instances[i].characterId, ch !== null ? ch.name : instances[i].displayNameSnapshot);
          } catch (e) {
            characterCache.set(instances[i].characterId, instances[i].displayNameSnapshot);
          }
        }
      }
      if (this.disposed) {
        return;
      }

      const scenes: WorldScene[] = await this.sceneRepo.listByWorld(worldId);
      if (this.disposed) {
        return;
      }
      const sceneMap: Map<string, WorldScene> = new Map<string, WorldScene>();
      let activeScenes: number = 0;
      let scenesMissingLocation: number = 0;
      for (let i = 0; i < scenes.length; i++) {
        sceneMap.set(scenes[i].id, scenes[i]);
        if (scenes[i].status === 'active') {
          activeScenes++;
        }
        if (!locationMap.has(scenes[i].locationId)) {
          scenesMissingLocation++;
        }
      }

      let totalMessages: number = 0;
      let messagesMissingScene: number = 0;
      let messagesMissingSender: number = 0;
      for (let i = 0; i < scenes.length; i++) {
        try {
          const msgs: WorldSceneMessage[] = await this.messageRepo.listByScene(scenes[i].id);
          totalMessages += msgs.length;
          for (let j = 0; j < msgs.length; j++) {
            if (msgs[j].senderCharacterInstanceId !== undefined
              && msgs[j].senderCharacterInstanceId!.length > 0
              && !instanceMap.has(msgs[j].senderCharacterInstanceId!)) {
              messagesMissingSender++;
            }
          }
        } catch (e) {
          continue;
        }
      }
      if (this.disposed) {
        return;
      }

      let allMemories: WorldCharacterMemory[] = [];
      try {
        allMemories = await this.memoryRepo.listByCharacterInstance('__world_all__');
      } catch (e) {
        allMemories = [];
      }
      if (allMemories.length === 0) {
        const memListPerInstance: WorldCharacterMemory[][] = [];
        for (let i = 0; i < instances.length; i++) {
          try {
            const m: WorldCharacterMemory[] =
              await this.memoryRepo.listByCharacterInstance(instances[i].id);
            for (let j = 0; j < m.length; j++) {
              if (m[j].worldId === worldId) {
                allMemories.push(m[j]);
              }
            }
          } catch (e) {
            continue;
          }
        }
      }
      if (this.disposed) {
        return;
      }

      let memoryWorldMismatch: number = 0;
      let memoryOwnerMissing: number = 0;
      let memoryMissingScene: number = 0;
      let memoryMissingLocation: number = 0;
      const sourceMessageIds: Map<string, number> = new Map<string, number>();
      for (let i = 0; i < allMemories.length; i++) {
        const m: WorldCharacterMemory = allMemories[i];
        if (m.worldId !== worldId) {
          memoryWorldMismatch++;
        }
        if (!instanceMap.has(m.characterInstanceId)) {
          memoryOwnerMissing++;
        }
        if (m.sourceSceneId !== undefined && m.sourceSceneId!.length > 0
          && !sceneMap.has(m.sourceSceneId!)) {
          memoryMissingScene++;
        }
        if (m.sourceLocationId !== undefined && m.sourceLocationId!.length > 0
          && !locationMap.has(m.sourceLocationId!)) {
          memoryMissingLocation++;
        }
        if (m.sourceMessageId !== undefined && m.sourceMessageId!.length > 0) {
          const count: number | undefined = sourceMessageIds.get(m.sourceMessageId!);
          if (count !== undefined) {
            sourceMessageIds.set(m.sourceMessageId!, count + 1);
          } else {
            sourceMessageIds.set(m.sourceMessageId!, 1);
          }
        }
      }
      let duplicateSourceRefCount: number = 0;
      const smKeys: string[] = Array.from(sourceMessageIds.keys());
      for (let i = 0; i < smKeys.length; i++) {
        if (sourceMessageIds.get(smKeys[i])! > 1) {
          duplicateSourceRefCount++;
        }
      }

      const events: WorldEvent[] = await this.eventRepo.listByWorld(worldId);
      if (this.disposed) {
        return;
      }

      const pendingCheckCount: number = memoryWorldMismatch + memoryOwnerMissing
        + memoryMissingScene + memoryMissingLocation + duplicateSourceRefCount
        + scenesMissingLocation + instancesMissingLocation + messagesMissingSender;

      const summary: CuratorSummaryUiModel = {
        worldName: world.name,
        characterCount: instances.length,
        locationCount: locations.length,
        sceneCount: scenes.length,
        memoryCount: allMemories.length,
        pendingCheckCount: pendingCheckCount
      };

      const overviewItems: CuratorOverviewItemUiModel[] = [
        {
          category: '角色实例',
          total: instances.length,
          valid: activeInstances,
          missingRef: instancesMissingLocation,
          pendingCheck: memoryOwnerMissing
        },
        {
          category: '地点',
          total: locations.length,
          valid: activeLocations,
          missingRef: 0,
          pendingCheck: 0
        },
        {
          category: '场景',
          total: scenes.length,
          valid: activeScenes,
          missingRef: scenesMissingLocation,
          pendingCheck: memoryMissingScene
        },
        {
          category: '消息',
          total: totalMessages,
          valid: totalMessages - messagesMissingSender,
          missingRef: messagesMissingSender,
          pendingCheck: 0
        },
        {
          category: '记忆',
          total: allMemories.length,
          valid: allMemories.length - memoryWorldMismatch - memoryOwnerMissing,
          missingRef: memoryMissingLocation,
          pendingCheck: memoryWorldMismatch + memoryOwnerMissing + duplicateSourceRefCount
        },
        {
          category: '关系',
          total: 0,
          valid: 0,
          missingRef: 0,
          pendingCheck: 0
        },
        {
          category: '事件',
          total: events.length,
          valid: events.length,
          missingRef: 0,
          pendingCheck: 0
        }
      ];

      const issues: ConsistencyIssueUiModel[] = [];
      const now: number = Date.now();

      for (let i = 0; i < allMemories.length; i++) {
        const m: WorldCharacterMemory = allMemories[i];
        const ownerInst: WorldCharacterInstance | undefined = instanceMap.get(m.characterInstanceId);
        const ownerName: string = ownerInst !== undefined
          ? (characterCache.get(ownerInst.characterId) ?? ownerInst.displayNameSnapshot)
          : '已移除角色';
        if (m.worldId !== worldId) {
          issues.push({
            id: 'world-mismatch-' + m.id,
            issueType: 'MEMORY_WORLD_MISMATCH',
            issueTypeLabel: '记忆世界归属不匹配',
            riskLevel: ConsistencyRiskLevel.Critical,
            riskLabel: '严重',
            description: '记忆 worldId 指向其他世界',
            affectedCharacterId: m.characterInstanceId,
            affectedCharacterName: ownerName,
            affectedLocationId: '',
            affectedLocationName: '',
            affectedSceneId: '',
            affectedRecordId: m.worldId,
            discoveredAt: now,
            discoveredAtLabel: formatWorldTimestamp(now),
            checkMethod: '规则检查:worldId 匹配'
          });
        }
        if (!instanceMap.has(m.characterInstanceId)) {
          issues.push({
            id: 'owner-missing-' + m.id,
            issueType: 'MISSING_CHARACTER_INSTANCE',
            issueTypeLabel: '记忆所有者不存在',
            riskLevel: ConsistencyRiskLevel.Critical,
            riskLabel: '严重',
            description: '记忆 characterInstanceId 对应的角色实例不存在',
            affectedCharacterId: m.characterInstanceId,
            affectedCharacterName: '已移除角色',
            affectedLocationId: '',
            affectedLocationName: '',
            affectedSceneId: '',
            affectedRecordId: m.characterInstanceId,
            discoveredAt: now,
            discoveredAtLabel: formatWorldTimestamp(now),
            checkMethod: '规则检查:characterInstanceId 存在性'
          });
        }
        if (m.sourceSceneId !== undefined && m.sourceSceneId!.length > 0
          && !sceneMap.has(m.sourceSceneId!)) {
          issues.push({
            id: 'missing-scene-' + m.id,
            issueType: 'MISSING_SOURCE_SCENE',
            issueTypeLabel: '来源场景缺失',
            riskLevel: ConsistencyRiskLevel.Warning,
            riskLabel: '警告',
            description: '记忆的来源场景不存在',
            affectedCharacterId: m.characterInstanceId,
            affectedCharacterName: ownerName,
            affectedLocationId: '',
            affectedLocationName: '',
            affectedSceneId: m.sourceSceneId!,
            affectedRecordId: m.sourceSceneId!,
            discoveredAt: now,
            discoveredAtLabel: formatWorldTimestamp(now),
            checkMethod: '规则检查:sourceSceneId 存在性'
          });
        }
        if (m.sourceLocationId !== undefined && m.sourceLocationId!.length > 0
          && !locationMap.has(m.sourceLocationId!)) {
          issues.push({
            id: 'missing-location-' + m.id,
            issueType: 'MISSING_LOCATION',
            issueTypeLabel: '来源地点缺失',
            riskLevel: ConsistencyRiskLevel.Notice,
            riskLabel: '提醒',
            description: '记忆的来源地点不存在',
            affectedCharacterId: m.characterInstanceId,
            affectedCharacterName: ownerName,
            affectedLocationId: m.sourceLocationId!,
            affectedLocationName: '地点已删除',
            affectedSceneId: '',
            affectedRecordId: m.sourceLocationId!,
            discoveredAt: now,
            discoveredAtLabel: formatWorldTimestamp(now),
            checkMethod: '规则检查:sourceLocationId 存在性'
          });
        }
      }

      for (let i = 0; i < smKeys.length; i++) {
        if (sourceMessageIds.get(smKeys[i])! > 1) {
          issues.push({
            id: 'dup-source-' + smKeys[i],
            issueType: 'DUPLICATE_SOURCE_REFERENCE',
            issueTypeLabel: '重复来源引用',
            riskLevel: ConsistencyRiskLevel.Notice,
            riskLabel: '提醒',
            description: '同一来源消息被多条记忆引用',
            affectedCharacterId: '',
            affectedCharacterName: '',
            affectedLocationId: '',
            affectedLocationName: '',
            affectedSceneId: '',
            affectedRecordId: smKeys[i],
            discoveredAt: now,
            discoveredAtLabel: formatWorldTimestamp(now),
            checkMethod: '规则检查:sourceMessageId 唯一性'
          });
        }
      }

      for (let i = 0; i < scenes.length; i++) {
        if (!locationMap.has(scenes[i].locationId)) {
          issues.push({
            id: 'scene-missing-loc-' + scenes[i].id,
            issueType: 'ORPHAN_SCENE_MESSAGE',
            issueTypeLabel: '场景地点缺失',
            riskLevel: ConsistencyRiskLevel.Warning,
            riskLabel: '警告',
            description: '场景所属地点不存在',
            affectedCharacterId: '',
            affectedCharacterName: '',
            affectedLocationId: scenes[i].locationId,
            affectedLocationName: '地点已删除',
            affectedSceneId: scenes[i].id,
            affectedRecordId: scenes[i].locationId,
            discoveredAt: now,
            discoveredAtLabel: formatWorldTimestamp(now),
            checkMethod: '规则检查:scene.locationId 存在性'
          });
        }
      }

      const snapshot: CuratorSnapshotUiModel = {
        summary: summary,
        overviewItems: overviewItems,
        issues: issues
      };

      if (this.disposed) {
        return;
      }
      this.snapshot = snapshot;
      this.state = CuratorLoadState.Ready;
    } catch (e) {
      if (this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: ' + (e as Error).message);
      this.errorMessage = '档案管理员数据加载失败';
      this.state = CuratorLoadState.Error;
    }
  }
}
