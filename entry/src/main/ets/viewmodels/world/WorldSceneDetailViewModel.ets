/**
 * WorldSceneDetailViewModel 场景详情页 ViewModel(W-SCENE-1B)
 *
 * 职责:
 * - 根据 sceneId 加载场景 + 地点 + 当前地点 Active 角色实例(含角色卡解析)
 * - 加载场景消息列表(按 sequenceNumber ASC)
 * - 结束场景(调用 WorldSceneService.endScene)
 * - 手动写入 User / Character / Narrator 消息
 * - 角色名称解析:实例存在且 Character 存在 → Character.name;实例存在但 Character 缺失 → displayNameSnapshot;实例已移除 → "已移除角色"
 * - 处理页面快速切换(expectedSceneId + loadOperationId)和销毁(disposed)
 * - 写操作防重复(operationId + isSaving + isEnding)
 *
 * 依赖方向:
 * Page → ViewModel → Repository(只读) / CharacterService(只读 getById) / WorldSceneService(写入)
 *
 * 不在 ArkUI Builder 中查询数据库。
 */

import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { CharacterService } from '../../services/CharacterService';
import { WorldSceneService } from '../../services/world/WorldSceneService';
import { Logger } from '../../utils/Logger';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import { WorldConversationSession, WorldConversationSessionStatus, deserializeParticipantSnapshots } from '../../models/world/WorldConversationSession';
import {
  WorldSceneMessage,
  WorldSceneMessageSenderType,
  WorldSceneMessageVisibility,
  WorldSceneMessageStatus
} from '../../models/world/WorldSceneMessage';
import { Character } from '../../models/Character';
import { DatabaseError } from '../../models/DatabaseError';
import { mapWorldSceneErrorToMessage } from './WorldSceneErrorMapper';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';
import {
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  WORLD_SCENE_DETAIL_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from './WorldUiModels';

const LOG_TAG: string = 'WorldSceneDetailViewModel';

/** 场景详情页加载状态 */
export enum WorldSceneDetailLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

/** 角色实例解析后的 UI 模型 */
export interface SceneCharacterUiModel {
  readonly instanceId: string;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly isActive: boolean;
  readonly characterCardMissing: boolean;
}

export interface SceneMessageUiModel {
  readonly id: string;
  readonly sequenceNumber: number;
  readonly senderType: WorldSceneMessageSenderType;
  readonly senderDisplayName: string;
  readonly senderInstanceId: string;
  readonly content: string;
  readonly visibility: WorldSceneMessageVisibility;
  readonly messageStatus: string;
  readonly recipientNames: string[];
  readonly witnessNames: string[];
  readonly replyTargetNames: string[];
  readonly createdAt: number;
  readonly senderRemoved: boolean;
}

/** 场景详情 UI 模型 */
export interface WorldSceneDetailUiModel {
  readonly sceneId: string;
  readonly worldId: string;
  readonly worldName: string;
  readonly worldStatus: WorldStatus;
  readonly locationId: string;
  readonly locationName: string;
  readonly locationStatus: WorldLocationStatus;
  readonly sceneStatus: WorldSceneStatus;
  readonly startedAt: number;
  readonly endedAt: number;
  readonly characters: SceneCharacterUiModel[];
  readonly messages: SceneMessageUiModel[];
  readonly sessions: SessionListItemUiModel[];
}

export interface SessionListItemUiModel {
  readonly sessionId: string;
  readonly sequenceNumber: number;
  readonly status: WorldConversationSessionStatus;
  readonly participantCount: number;
  readonly createdAt: number;
}

/** 手动消息表单输入 */
export interface UserMessageFormInput {
  readonly content: string;
  readonly visibility: WorldSceneMessageVisibility;
  readonly recipientInstanceIds: string[];
  readonly replyTargetInstanceIds: string[];
}

export interface CharacterMessageFormInput {
  readonly senderInstanceId: string;
  readonly content: string;
  readonly visibility: WorldSceneMessageVisibility;
  readonly recipientInstanceIds: string[];
}

export interface NarratorMessageFormInput {
  readonly content: string;
  readonly witnessInstanceIds: string[];
}

export interface SaveMessageResult {
  readonly success: boolean;
  readonly errorMessage: string;
}

export class WorldSceneDetailViewModel {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly characterService: CharacterService;
  private readonly sceneService: WorldSceneService;

  state: WorldSceneDetailLoadState = WorldSceneDetailLoadState.Loading;
  errorMessage: string = '';
  detail: WorldSceneDetailUiModel | null = null;

  private expectedSceneId: string = '';
  private loadOperationId: number = 0;
  private operationId: number = 0;
  isSaving: boolean = false;
  isEnding: boolean = false;
  private disposed: boolean = false;
  readonly instanceShortId: string;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sceneRepo: WorldSceneRepository,
    messageRepo: WorldSceneMessageRepository,
    sessionRepo: WorldConversationSessionRepository,
    characterService: CharacterService,
    sceneService: WorldSceneService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.sceneRepo = sceneRepo;
    this.messageRepo = messageRepo;
    this.sessionRepo = sessionRepo;
    this.characterService = characterService;
    this.sceneService = sceneService;
    this.instanceShortId = WorldSceneDetailViewModel.generateShortId();
  }

  private static generateShortId(): string {
    const ts: number = Date.now();
    const tail: number = Math.floor(ts % 0xffff);
    return tail.toString(16).padStart(4, '0');
  }

  activate(): void {
    if (this.disposed) {
      this.disposed = false;
      Logger.info(LOG_TAG, 'activate: vmInstance=' + this.instanceShortId);
    }
  }

  setSceneId(sceneId: string): void {
    if (this.expectedSceneId !== sceneId) {
      this.expectedSceneId = sceneId;
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  expectedSceneIdOfPage(): string {
    return this.expectedSceneId;
  }

  async loadSnapshot(sceneId: string): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'loadSnapshot skipped: disposed vmInstance=' + this.instanceShortId);
      return;
    }
    this.expectedSceneId = sceneId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;
    const targetSceneId: string = sceneId;

    this.state = WorldSceneDetailLoadState.Loading;
    this.errorMessage = '';

    try {
      const scene: WorldScene | null = await this.sceneRepo.getById(targetSceneId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (scene === null) {
        this.state = WorldSceneDetailLoadState.NotFound;
        return;
      }

      const world: World | null = await this.worldRepo.getById(scene.worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.state = WorldSceneDetailLoadState.NotFound;
        return;
      }

      const location: WorldLocation | null = await this.locationRepo.getById(scene.locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const locationName: string = location !== null ? location.name : '(地点已删除)';
      const locationStatus: WorldLocationStatus = location !== null
        ? location.status as WorldLocationStatus : WorldLocationStatus.Archived;

      // 加载当前地点全部角色实例
      const instances: WorldCharacterInstance[] = await this.safeListInstancesAtLocation(scene.worldId, scene.locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 加载场景消息
      const messages: WorldSceneMessage[] = await this.safeListMessages(targetSceneId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 收集全部需要解析的 characterId
      const characterIdSet: Set<string> = new Set<string>();
      for (let i = 0; i < instances.length; i++) {
        if (instances[i].characterId.length > 0) {
          characterIdSet.add(instances[i].characterId);
        }
      }
      // 消息中的 sender / recipient / witness / replyTarget 是 instanceId,需要先解析为 instance → characterId
      // 但历史消息中的实例可能已被移除,我们只解析当前存在的实例
      const instanceMap: Map<string, WorldCharacterInstance> = new Map<string, WorldCharacterInstance>();
      for (let i = 0; i < instances.length; i++) {
        instanceMap.set(instances[i].id, instances[i]);
        if (instances[i].characterId.length > 0) {
          characterIdSet.add(instances[i].characterId);
        }
      }
      // 同时收集消息中引用的 instanceId(可能已被移除)
      for (let i = 0; i < messages.length; i++) {
        const m: WorldSceneMessage = messages[i];
        if (m.senderCharacterInstanceId !== undefined && !instanceMap.has(m.senderCharacterInstanceId)) {
          // 历史消息中 sender 实例可能已移除,尝试加载
          const histInst: WorldCharacterInstance | null =
            await this.safeGetInstance(m.senderCharacterInstanceId);
          if (histInst !== null) {
            instanceMap.set(histInst.id, histInst);
            if (histInst.characterId.length > 0) {
              characterIdSet.add(histInst.characterId);
            }
          }
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 批量解析角色卡
      const characterMap: Map<string, Character | null> = new Map<string, Character | null>();
      const characterIds: string[] = Array.from(characterIdSet);
      for (let i = 0; i < characterIds.length; i++) {
        if (operationId !== this.loadOperationId || this.disposed) {
          return;
        }
        const id: string = characterIds[i];
        try {
          const c: Character | null = await this.characterService.getById(id);
          characterMap.set(id, c);
        } catch (e) {
          Logger.warn(LOG_TAG, 'characterService.getById failed: ' + this.safeErrorCategory(e)
            + ', charShortId=' + this.shortId(id));
          characterMap.set(id, null);
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 构建角色实例 UI 模型
      const characterUiModels: SceneCharacterUiModel[] = new Array<SceneCharacterUiModel>(instances.length);
      for (let i = 0; i < instances.length; i++) {
        const inst: WorldCharacterInstance = instances[i];
        const character: Character | null | undefined = characterMap.get(inst.characterId);
        const characterCardMissing: boolean = character === null || character === undefined;
        const displayName: string = !characterCardMissing && character !== null && character !== undefined
          ? character.name : inst.displayNameSnapshot;
        const avatarUri: string = !characterCardMissing && character !== null && character !== undefined
          ? character.avatarUri : '';
        characterUiModels[i] = {
          instanceId: inst.id,
          displayName: displayName,
          avatarUri: avatarUri,
          isActive: inst.isActive,
          characterCardMissing: characterCardMissing
        };
      }

      // 构建消息 UI 模型
      const messageUiModels: SceneMessageUiModel[] = new Array<SceneMessageUiModel>(messages.length);
      for (let i = 0; i < messages.length; i++) {
        const m: WorldSceneMessage = messages[i];
        messageUiModels[i] = {
          id: m.id,
          sequenceNumber: m.sequenceNumber,
          senderType: m.senderType,
          senderDisplayName: this.resolveInstanceDisplayName(m.senderCharacterInstanceId, instanceMap, characterMap),
          senderInstanceId: m.senderCharacterInstanceId !== undefined ? m.senderCharacterInstanceId : '',
          content: m.content,
          visibility: m.visibility,
          messageStatus: m.status,
          recipientNames: this.resolveInstanceNames(m.recipientCharacterInstanceIds, instanceMap, characterMap),
          witnessNames: this.resolveInstanceNames(m.witnessCharacterInstanceIds, instanceMap, characterMap),
          replyTargetNames: this.resolveInstanceNames(m.replyTargetCharacterInstanceIds, instanceMap, characterMap),
          createdAt: m.createdAt,
          senderRemoved: m.senderCharacterInstanceId !== undefined
            && !instanceMap.has(m.senderCharacterInstanceId)
        };
      }

      const sessions: WorldConversationSession[] = await this.safeListSessions(targetSceneId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const sessionUiModels: SessionListItemUiModel[] = [];
      for (let i = 0; i < sessions.length; i++) {
        const s: WorldConversationSession = sessions[i];
        let pCount: number = 0;
        try {
          pCount = deserializeParticipantSnapshots(s.participantSnapshotJson).length;
        } catch (e) {
          pCount = 0;
        }
        sessionUiModels.push({
          sessionId: s.id,
          sequenceNumber: s.sequenceNumber,
          status: s.status as WorldConversationSessionStatus,
          participantCount: pCount,
          createdAt: s.createdAt
        });
      }

      const uiModel: WorldSceneDetailUiModel = {
        sceneId: scene.id,
        worldId: world.id,
        worldName: world.name,
        worldStatus: world.status as WorldStatus,
        locationId: scene.locationId,
        locationName: locationName,
        locationStatus: locationStatus,
        sceneStatus: scene.status as WorldSceneStatus,
        startedAt: scene.startedAt,
        endedAt: scene.endedAt !== undefined ? scene.endedAt : 0,
        characters: characterUiModels,
        messages: messageUiModels,
        sessions: sessionUiModels
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.detail = uiModel;
      this.state = WorldSceneDetailLoadState.Ready;
      Logger.info(LOG_TAG, 'loadSnapshot done: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', state=ready, messageCount=' + messageUiModels.length.toString()
        + ', sceneShortId=' + this.shortId(targetSceneId));
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', ' + this.safeErrorCategory(e)
        + ', sceneShortId=' + this.shortId(targetSceneId));
      this.errorMessage = '场景详情加载失败,请重试';
      this.state = WorldSceneDetailLoadState.Error;
    }
  }

  /** 结束场景。返回是否成功 + 错误消息 */
  async endScene(): Promise<SaveMessageResult> {
    if (this.isEnding) {
      Logger.warn(LOG_TAG, 'endScene skipped: isEnding');
      return { success: false, errorMessage: '正在处理,请稍候' };
    }
    if (this.expectedSceneId.length === 0) {
      return { success: false, errorMessage: '场景未加载' };
    }
    this.isEnding = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.sceneService.endScene(this.expectedSceneId);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' };
      }
      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return { success: true, errorMessage: '' };
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' };
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'endScene failed: ' + this.safeErrorCategory(e)
        + ', sceneShortId=' + this.shortId(this.expectedSceneId));
      return { success: false, errorMessage: msg };
    } finally {
      if (opId === this.operationId) {
        this.isEnding = false;
      }
    }
  }

  /** 添加 User 消息 */
  async addUserMessage(input: UserMessageFormInput): Promise<SaveMessageResult> {
    if (this.isSaving) {
      Logger.warn(LOG_TAG, 'addUserMessage skipped: isSaving');
      return { success: false, errorMessage: '正在处理,请稍候' };
    }
    if (this.expectedSceneId.length === 0) {
      return { success: false, errorMessage: '场景未加载' };
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.sceneService.addUserMessage({
        sceneId: this.expectedSceneId,
        content: input.content,
        visibility: input.visibility,
        recipientCharacterInstanceIds: input.recipientInstanceIds.length > 0 ? input.recipientInstanceIds : undefined,
        replyTargetCharacterInstanceIds: input.replyTargetInstanceIds.length > 0 ? input.replyTargetInstanceIds : undefined
      });
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' };
      }
      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return { success: true, errorMessage: '' };
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' };
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'addUserMessage failed: ' + this.safeErrorCategory(e)
        + ', sceneShortId=' + this.shortId(this.expectedSceneId));
      return { success: false, errorMessage: msg };
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /** 添加 Character 消息 */
  async addCharacterMessage(input: CharacterMessageFormInput): Promise<SaveMessageResult> {
    if (this.isSaving) {
      Logger.warn(LOG_TAG, 'addCharacterMessage skipped: isSaving');
      return { success: false, errorMessage: '正在处理,请稍候' };
    }
    if (this.expectedSceneId.length === 0) {
      return { success: false, errorMessage: '场景未加载' };
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.sceneService.addCharacterMessage({
        sceneId: this.expectedSceneId,
        senderCharacterInstanceId: input.senderInstanceId,
        content: input.content,
        visibility: input.visibility,
        recipientCharacterInstanceIds: input.recipientInstanceIds.length > 0 ? input.recipientInstanceIds : undefined
      });
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' };
      }
      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return { success: true, errorMessage: '' };
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' };
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'addCharacterMessage failed: ' + this.safeErrorCategory(e)
        + ', sceneShortId=' + this.shortId(this.expectedSceneId));
      return { success: false, errorMessage: msg };
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  /** 添加 Narrator 消息 */
  async addNarratorMessage(input: NarratorMessageFormInput): Promise<SaveMessageResult> {
    if (this.isSaving) {
      Logger.warn(LOG_TAG, 'addNarratorMessage skipped: isSaving');
      return { success: false, errorMessage: '正在处理,请稍候' };
    }
    if (this.expectedSceneId.length === 0) {
      return { success: false, errorMessage: '场景未加载' };
    }
    this.isSaving = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.sceneService.addNarratorMessage({
        sceneId: this.expectedSceneId,
        content: input.content,
        witnessCharacterInstanceIds: input.witnessInstanceIds.length > 0 ? input.witnessInstanceIds : undefined
      });
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' };
      }
      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return { success: true, errorMessage: '' };
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' };
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'addNarratorMessage failed: ' + this.safeErrorCategory(e)
        + ', sceneShortId=' + this.shortId(this.expectedSceneId));
      return { success: false, errorMessage: msg };
    } finally {
      if (opId === this.operationId) {
        this.isSaving = false;
      }
    }
  }

  dispose(): void {
    this.disposed = true;
    Logger.info(LOG_TAG, 'dispose: vmInstance=' + this.instanceShortId);
  }

  // ===== 私有辅助 =====

  private async safeListInstancesAtLocation(worldId: string, locationId: string): Promise<WorldCharacterInstance[]> {
    try {
      return await this.instanceRepo.listByLocation(worldId, locationId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByLocation(instances) failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async safeListMessages(sceneId: string): Promise<WorldSceneMessage[]> {
    try {
      return await this.messageRepo.listByScene(sceneId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByScene(messages) failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async safeListSessions(sceneId: string): Promise<WorldConversationSession[]> {
    try {
      return await this.sessionRepo.listBySceneId(sceneId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listBySceneId(sessions) failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async safeGetInstance(instanceId: string): Promise<WorldCharacterInstance | null> {
    try {
      return await this.instanceRepo.getById(instanceId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'getById(instance) failed: ' + this.safeErrorCategory(e));
      return null;
    }
  }

  /** 递增刷新令牌,通知世界详情页和本页刷新 */
  private bumpRefreshTokens(): void {
    const detailToken: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, detailToken + 1);
    const sceneToken: number = AppStorage.get<number>(WORLD_SCENE_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_SCENE_DETAIL_REFRESH_TOKEN_KEY, sceneToken + 1);
  }

  /** 解析单个实例显示名称 */
  private resolveInstanceDisplayName(
    instanceId: string | undefined,
    instanceMap: Map<string, WorldCharacterInstance>,
    characterMap: Map<string, Character | null>
  ): string {
    if (instanceId === undefined || instanceId.length === 0) {
      if (instanceId === undefined) {
        return '';
      }
      return '';
    }
    const inst: WorldCharacterInstance | undefined = instanceMap.get(instanceId);
    if (inst === undefined) {
      return '已移除角色';
    }
    const character: Character | null | undefined = characterMap.get(inst.characterId);
    if (character !== null && character !== undefined) {
      return character.name;
    }
    return inst.displayNameSnapshot;
  }

  /** 解析多个实例显示名称 */
  private resolveInstanceNames(
    instanceIds: string[] | undefined,
    instanceMap: Map<string, WorldCharacterInstance>,
    characterMap: Map<string, Character | null>
  ): string[] {
    if (instanceIds === undefined || instanceIds.length === 0) {
      return [];
    }
    const names: string[] = [];
    for (let i = 0; i < instanceIds.length; i++) {
      names.push(this.resolveInstanceDisplayName(instanceIds[i], instanceMap, characterMap));
    }
    return names;
  }

  private resolveErrorMessage(e: Object): string {
    const sceneMsg: string = mapWorldSceneErrorToMessage(e);
    if (sceneMsg !== '操作失败,请重试') {
      return sceneMsg;
    }
    const stateMsg: string = mapWorldStateErrorToMessage(e);
    if (stateMsg !== '操作失败,请重试') {
      return stateMsg;
    }
    return '操作失败,请重试';
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

/** 格式化场景时间戳(复用 WorldUiModels.formatWorldTimestamp) */
export function formatSceneTimestamp(ts: number): string {
  return formatWorldTimestamp(ts);
}
