import { WorldCharacterMemoryRepository } from '../../repositories/world/WorldCharacterMemoryRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { CharacterService } from '../../services/CharacterService';
import {
  WorldCharacterMemory,
  WorldCharacterMemoryType,
  WorldCharacterMemoryOrigin,
  WorldCharacterMemoryStatus
} from '../../models/world/WorldCharacterMemory';
import { WorldScene } from '../../models/world/WorldScene';
import {
  WorldSceneMessage,
  WorldSceneMessageSenderType
} from '../../models/world/WorldSceneMessage';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldLocation } from '../../models/world/WorldLocation';
import { World } from '../../models/world/World';
import { Character } from '../../models/Character';
import { formatWorldTimestamp } from './WorldUiModels';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldMemoryEvidenceViewModel';

export enum EvidenceLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

export interface EvidenceHeaderUiModel {
  readonly memoryId: string;
  readonly memoryContent: string;
  readonly memoryType: WorldCharacterMemoryType;
  readonly memoryTypeLabel: string;
  readonly memoryStatus: WorldCharacterMemoryStatus;
  readonly memoryStatusLabel: string;
  readonly ownerInstanceId: string;
  readonly ownerDisplayName: string;
}

export interface EvidenceSourceUiModel {
  readonly worldId: string;
  readonly worldName: string;
  readonly locationId: string;
  readonly locationName: string;
  readonly locationMissing: boolean;
  readonly sceneId: string;
  readonly sceneName: string;
  readonly sceneMissing: boolean;
  readonly sceneStartedAt: number;
  readonly sceneStartedAtLabel: string;
  readonly sourceType: string;
  readonly sourceTypeLabel: string;
}

export interface EvidenceMessageUiModel {
  readonly messageId: string;
  readonly speakerType: string;
  readonly speakerInstanceId: string;
  readonly speakerName: string;
  readonly speakerMissing: boolean;
  readonly locationName: string;
  readonly sceneId: string;
  readonly sentAt: number;
  readonly sentAtLabel: string;
  readonly visibility: string;
  readonly visibilityLabel: string;
  readonly participantNames: string[];
  readonly content: string;
  readonly status: string;
  readonly isOriginalEvidence: boolean;
}

export interface EvidenceSnapshotUiModel {
  readonly header: EvidenceHeaderUiModel;
  readonly source: EvidenceSourceUiModel;
  readonly messages: EvidenceMessageUiModel[];
  readonly hasSourceData: boolean;
  readonly noSourceMessage: string;
}

export class WorldMemoryEvidenceViewModel {
  private readonly memoryRepo: WorldCharacterMemoryRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly worldRepo: WorldRepository;
  private readonly characterService: CharacterService;

  state: EvidenceLoadState = EvidenceLoadState.Loading;
  errorMessage: string = '';
  snapshot: EvidenceSnapshotUiModel | null = null;
  private disposed: boolean = false;

  constructor(
    memoryRepo: WorldCharacterMemoryRepository,
    sceneRepo: WorldSceneRepository,
    messageRepo: WorldSceneMessageRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    locationRepo: WorldLocationRepository,
    worldRepo: WorldRepository,
    characterService: CharacterService
  ) {
    this.memoryRepo = memoryRepo;
    this.sceneRepo = sceneRepo;
    this.messageRepo = messageRepo;
    this.instanceRepo = instanceRepo;
    this.locationRepo = locationRepo;
    this.worldRepo = worldRepo;
    this.characterService = characterService;
  }

  dispose(): void {
    this.disposed = true;
  }

  async loadEvidence(memoryId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.state = EvidenceLoadState.Loading;
    this.errorMessage = '';

    try {
      const memory: WorldCharacterMemory | null = await this.memoryRepo.getById(memoryId);
      if (this.disposed) {
        return;
      }
      if (memory === null) {
        this.state = EvidenceLoadState.NotFound;
        return;
      }

      let ownerName: string = '未记录';
      if (memory.characterInstanceId.length > 0) {
        const ownerInst: WorldCharacterInstance | null =
          await this.instanceRepo.getById(memory.characterInstanceId);
        if (ownerInst !== null) {
          try {
            const ownerChar: Character | null =
              await this.characterService.getById(ownerInst.characterId);
            ownerName = ownerChar !== null ? ownerChar.name : ownerInst.displayNameSnapshot;
          } catch (e) {
            ownerName = ownerInst.displayNameSnapshot;
          }
        }
      }
      if (this.disposed) {
        return;
      }

      const header: EvidenceHeaderUiModel = {
        memoryId: memory.id,
        memoryContent: memory.content,
        memoryType: memory.type,
        memoryTypeLabel: this.typeLabel(memory.type),
        memoryStatus: memory.status,
        memoryStatusLabel: this.statusLabel(memory.status),
        ownerInstanceId: memory.characterInstanceId,
        ownerDisplayName: ownerName
      };

      let worldName: string = '未记录';
      let worldMissing: boolean = false;
      if (memory.worldId.length > 0) {
        const w: World | null = await this.worldRepo.getById(memory.worldId);
        if (w !== null) {
          worldName = w.name;
        } else {
          worldMissing = true;
        }
      }
      if (this.disposed) {
        return;
      }

      let locationName: string = '未记录';
      let locationMissing: boolean = false;
      if (memory.sourceLocationId !== undefined && memory.sourceLocationId.length > 0) {
        const loc: WorldLocation | null =
          await this.locationRepo.getById(memory.sourceLocationId);
        if (loc !== null) {
          locationName = loc.name;
        } else {
          locationMissing = true;
        }
      }
      if (this.disposed) {
        return;
      }

      let sceneName: string = '未记录';
      let sceneMissing: boolean = false;
      let sceneStartedAt: number = 0;
      let sceneLocationName: string = '未记录';
      if (memory.sourceSceneId !== undefined && memory.sourceSceneId.length > 0) {
        const scene: WorldScene | null =
          await this.sceneRepo.getById(memory.sourceSceneId);
        if (scene !== null) {
          sceneStartedAt = scene.startedAt;
          const sceneLoc: WorldLocation | null =
            await this.locationRepo.getById(scene.locationId);
          sceneName = sceneLoc !== null ? sceneLoc.name : '未知地点';
          sceneLocationName = sceneLoc !== null ? sceneLoc.name : '未知地点';
        } else {
          sceneMissing = true;
        }
      }
      if (this.disposed) {
        return;
      }

      const sourceType: string = memory.origin;
      const source: EvidenceSourceUiModel = {
        worldId: memory.worldId,
        worldName: worldName,
        locationId: memory.sourceLocationId !== undefined ? memory.sourceLocationId : '',
        locationName: locationName,
        locationMissing: locationMissing,
        sceneId: memory.sourceSceneId !== undefined ? memory.sourceSceneId : '',
        sceneName: sceneName,
        sceneMissing: sceneMissing,
        sceneStartedAt: sceneStartedAt,
        sceneStartedAtLabel: sceneStartedAt > 0 ? formatWorldTimestamp(sceneStartedAt) : '',
        sourceType: sourceType,
        sourceTypeLabel: sourceType === WorldCharacterMemoryOrigin.SceneMessage ? '场景消息' : '手动创建'
      };

      const evidenceMessages: EvidenceMessageUiModel[] = [];
      let hasSourceData: boolean = false;

      if (memory.sourceSceneId !== undefined && memory.sourceSceneId.length > 0
        && !sceneMissing) {
        try {
          const sceneMsgs: WorldSceneMessage[] =
            await this.messageRepo.listByScene(memory.sourceSceneId);
          const instCache: Map<string, string> = new Map<string, string>();
          for (let i = 0; i < sceneMsgs.length; i++) {
            const msg: WorldSceneMessage = sceneMsgs[i];
            let speakerName: string = '未记录';
            let speakerMissing: boolean = false;
            if (msg.senderType === WorldSceneMessageSenderType.Character
              && msg.senderCharacterInstanceId !== undefined) {
              const cached: string | undefined = instCache.get(msg.senderCharacterInstanceId);
              if (cached !== undefined) {
                speakerName = cached;
              } else {
                const inst: WorldCharacterInstance | null =
                  await this.instanceRepo.getById(msg.senderCharacterInstanceId);
                if (inst !== null) {
                  try {
                    const ch: Character | null =
                      await this.characterService.getById(inst.characterId);
                    speakerName = ch !== null ? ch.name : inst.displayNameSnapshot;
                  } catch (e) {
                    speakerName = inst.displayNameSnapshot;
                  }
                  instCache.set(msg.senderCharacterInstanceId, speakerName);
                } else {
                  speakerMissing = true;
                  speakerName = '角色已移除';
                }
              }
            } else if (msg.senderType === WorldSceneMessageSenderType.User) {
              speakerName = '玩家';
            } else {
              speakerName = '旁白';
            }
            const participantNames: string[] = [];
            if (msg.participantCharacterInstanceIds !== undefined) {
              for (let j = 0; j < msg.participantCharacterInstanceIds!.length; j++) {
                const pid: string = msg.participantCharacterInstanceIds![j];
                const pName: string | undefined = instCache.get(pid);
                if (pName !== undefined) {
                  participantNames.push(pName);
                } else {
                  const pInst: WorldCharacterInstance | null =
                    await this.instanceRepo.getById(pid);
                  if (pInst !== null) {
                    try {
                      const pCh: Character | null =
                        await this.characterService.getById(pInst.characterId);
                      const name: string = pCh !== null ? pCh.name : pInst.displayNameSnapshot;
                      participantNames.push(name);
                      instCache.set(pid, name);
                    } catch (e) {
                      participantNames.push(pInst.displayNameSnapshot);
                      instCache.set(pid, pInst.displayNameSnapshot);
                    }
                  }
                }
              }
            }
            const isTarget: boolean = msg.id === memory.sourceMessageId;
            evidenceMessages.push({
              messageId: msg.id,
              speakerType: msg.senderType,
              speakerInstanceId: msg.senderCharacterInstanceId !== undefined
                ? msg.senderCharacterInstanceId : '',
              speakerName: speakerName,
              speakerMissing: speakerMissing,
              locationName: sceneLocationName,
              sceneId: msg.sceneId,
              sentAt: msg.createdAt,
              sentAtLabel: formatWorldTimestamp(msg.createdAt),
              visibility: msg.visibility,
              visibilityLabel: this.visibilityLabel(msg.visibility),
              participantNames: participantNames,
              content: msg.content,
              status: msg.status,
              isOriginalEvidence: isTarget
            });
            hasSourceData = true;
          }
        } catch (e) {
          Logger.warn(LOG_TAG, 'loadSceneMessages failed: ' + (e as Error).message);
        }
      }

      const noSourceMessage: string = hasSourceData
        ? '' : '这条记忆没有可追溯的原始消息记录';

      const snapshot: EvidenceSnapshotUiModel = {
        header: header,
        source: source,
        messages: evidenceMessages,
        hasSourceData: hasSourceData,
        noSourceMessage: noSourceMessage
      };

      if (this.disposed) {
        return;
      }
      this.snapshot = snapshot;
      this.state = EvidenceLoadState.Ready;
    } catch (e) {
      if (this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadEvidence failed: ' + (e as Error).message);
      this.errorMessage = '证据数据加载失败';
      this.state = EvidenceLoadState.Error;
    }
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
}


