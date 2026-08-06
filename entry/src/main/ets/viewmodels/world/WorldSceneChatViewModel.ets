/**
 * WorldSceneChatViewModel 世界场景共享对话页 ViewModel(W-UX-1)
 *
 * 职责:
 * - 根据 sceneId 加载场景 + 地点 + 当前地点角色(实时,人物栏按当前地点状态)
 * - 加载场景消息列表(按 sequenceNumber ASC,共享时间线)
 * - 用户公开消息发送(含回复目标)
 * - 用户私下消息发送
 * - 手动角色发言 / 旁白(从更多菜单弹出)
 * - 结束场景
 * - 角色名称解析:实例+Character 存在→Character.name;实例存在+Character 缺失→displayNameSnapshot;实例已移除→"已移除角色"
 * - 处理页面切换(expectedSceneId + loadOperationId)和销毁(disposed)
 * - 写操作防重复(operationId + isSending + isEnding)
 *
 * 依赖方向:
 * Page → ViewModel → Repository(只读) / CharacterService(只读 getById) / WorldSceneService(写入)
 *
 * 日志安全:不记录完整消息正文 / ID 数组 / SQL,仅记录操作类型、visibility、sequenceNumber、数量、截断短 ID。
 */

import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { CharacterService } from '../../services/CharacterService';
import { WorldSceneService } from '../../services/world/WorldSceneService';
import { Logger } from '../../utils/Logger';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
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

const LOG_TAG: string = 'WorldSceneChatViewModel';

/** 聊天页加载状态 */
export enum WorldSceneChatLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

/** 角色实例解析后的 UI 模型(用于人物栏) */
export interface ChatCharacterUiModel {
  readonly instanceId: string;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly fallbackName: string;
  readonly isActive: boolean;
  readonly characterCardMissing: boolean;
}

/** 消息 UI 模型 */
export interface ChatMessageUiModel {
  readonly id: string;
  readonly sequenceNumber: number;
  readonly senderType: WorldSceneMessageSenderType;
  readonly senderDisplayName: string;
  readonly senderInstanceId: string;
  readonly senderAvatarUri: string;
  readonly senderFallbackName: string;
  readonly content: string;
  readonly visibility: WorldSceneMessageVisibility;
  readonly messageStatus: string;
  readonly recipientNames: string[];
  readonly witnessNames: string[];
  readonly replyTargetNames: string[];
  readonly createdAt: number;
  readonly senderRemoved: boolean;
}

/** 聊天页 UI 模型 */
export interface WorldSceneChatUiModel {
  readonly sceneId: string;
  readonly sceneName: string;
  readonly worldId: string;
  readonly worldName: string;
  readonly worldStatus: WorldStatus;
  readonly locationId: string;
  readonly locationName: string;
  readonly locationStatus: WorldLocationStatus;
  readonly sceneStatus: WorldSceneStatus;
  readonly startedAt: number;
  readonly endedAt: number;
  readonly participantCount: number;
  readonly characters: ChatCharacterUiModel[];
  readonly messages: ChatMessageUiModel[];
}

/** 用户消息表单输入 */
export interface ChatUserMessageInput {
  readonly content: string;
  readonly visibility: WorldSceneMessageVisibility;
  readonly recipientInstanceIds: string[];
  readonly replyTargetInstanceIds: string[];
}

/** 角色消息表单输入 */
export interface ChatCharacterMessageInput {
  readonly senderInstanceId: string;
  readonly content: string;
  readonly visibility: WorldSceneMessageVisibility;
  readonly recipientInstanceIds: string[];
}

/** 旁白消息表单输入 */
export interface ChatNarratorMessageInput {
  readonly content: string;
  readonly witnessInstanceIds: string[];
}

/** 写操作结果 */
export interface ChatSaveResult {
  readonly success: boolean;
  readonly errorMessage: string;
}

export class WorldSceneChatViewModel {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly characterService: CharacterService;
  private readonly sceneService: WorldSceneService;

  state: WorldSceneChatLoadState = WorldSceneChatLoadState.Loading;
  errorMessage: string = '';
  detail: WorldSceneChatUiModel | null = null;

  private expectedSceneId: string = '';
  private loadOperationId: number = 0;
  private operationId: number = 0;
  isSending: boolean = false;
  isStarting: boolean = false;
  isEnding: boolean = false;
  private disposed: boolean = false;
  readonly instanceShortId: string;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sceneRepo: WorldSceneRepository,
    messageRepo: WorldSceneMessageRepository,
    characterService: CharacterService,
    sceneService: WorldSceneService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.sceneRepo = sceneRepo;
    this.messageRepo = messageRepo;
    this.characterService = characterService;
    this.sceneService = sceneService;
    this.instanceShortId = WorldSceneChatViewModel.generateShortId();
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

  dispose(): void {
    this.disposed = true;
    Logger.info(LOG_TAG, 'dispose: vmInstance=' + this.instanceShortId);
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

  /**
   * 加载聊天页快照。每次 onPageShow 和发送完成后调用。
   */
  async loadSnapshot(sceneId: string): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'loadSnapshot skipped: disposed vmInstance=' + this.instanceShortId);
      return;
    }
    this.expectedSceneId = sceneId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;
    const targetSceneId: string = sceneId;

    this.state = WorldSceneChatLoadState.Loading;
    this.errorMessage = '';

    try {
      const scene: WorldScene | null = await this.sceneRepo.getById(targetSceneId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (scene === null) {
        this.state = WorldSceneChatLoadState.NotFound;
        return;
      }

      const world: World | null = await this.worldRepo.getById(scene.worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.state = WorldSceneChatLoadState.NotFound;
        return;
      }

      const location: WorldLocation | null = await this.locationRepo.getById(scene.locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const locationName: string = location !== null ? location.name : '(地点已删除)';
      const locationStatus: WorldLocationStatus = location !== null
        ? location.status as WorldLocationStatus : WorldLocationStatus.Archived;

      // 加载当前地点全部角色实例(实时人物栏)
      const instances: WorldCharacterInstance[] = await this.safeListInstancesAtLocation(scene.worldId, scene.locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 加载场景消息
      const messages: WorldSceneMessage[] = await this.safeListMessages(targetSceneId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 收集需要解析的 characterId 和历史消息中引用的 instanceId
      const characterIdSet: Set<string> = new Set<string>();
      const instanceMap: Map<string, WorldCharacterInstance> = new Map<string, WorldCharacterInstance>();
      for (let i = 0; i < instances.length; i++) {
        instanceMap.set(instances[i].id, instances[i]);
        if (instances[i].characterId.length > 0) {
          characterIdSet.add(instances[i].characterId);
        }
      }
      // 历史消息中的实例可能已移除,尝试加载
      for (let i = 0; i < messages.length; i++) {
        const m: WorldSceneMessage = messages[i];
        if (m.senderCharacterInstanceId !== undefined && !instanceMap.has(m.senderCharacterInstanceId)) {
          const histInst: WorldCharacterInstance | null = await this.safeGetInstance(m.senderCharacterInstanceId);
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
          Logger.warn(LOG_TAG, 'characterService.getById failed: ' + this.safeErrorCategory(e));
          characterMap.set(id, null);
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 构建角色 UI 模型
      const characterUiModels: ChatCharacterUiModel[] = new Array<ChatCharacterUiModel>(instances.length);
      for (let i = 0; i < instances.length; i++) {
        const inst: WorldCharacterInstance = instances[i];
        const character: Character | null | undefined = characterMap.get(inst.characterId);
        const missing: boolean = character === null || character === undefined;
        const displayName: string = !missing && character !== null && character !== undefined
          ? character.name : inst.displayNameSnapshot;
        const avatarUri: string = !missing && character !== null && character !== undefined
          ? character.avatarUri : '';
        characterUiModels[i] = {
          instanceId: inst.id,
          displayName: displayName,
          avatarUri: avatarUri,
          fallbackName: inst.displayNameSnapshot,
          isActive: inst.isActive,
          characterCardMissing: missing
        };
      }

      // 构建消息 UI 模型
      const messageUiModels: ChatMessageUiModel[] = new Array<ChatMessageUiModel>(messages.length);
      for (let i = 0; i < messages.length; i++) {
        const m: WorldSceneMessage = messages[i];
        const senderInst: WorldCharacterInstance | undefined =
          m.senderCharacterInstanceId !== undefined ? instanceMap.get(m.senderCharacterInstanceId) : undefined;
        const senderCharacter: Character | null | undefined =
          senderInst !== undefined ? characterMap.get(senderInst.characterId) : undefined;
        const senderDisplayName: string = this.resolveInstanceDisplayName(
          m.senderCharacterInstanceId, instanceMap, characterMap);
        const senderAvatarUri: string = senderCharacter !== null && senderCharacter !== undefined
          ? senderCharacter.avatarUri
          : (senderInst !== undefined ? '' : '');
        messageUiModels[i] = {
          id: m.id,
          sequenceNumber: m.sequenceNumber,
          senderType: m.senderType,
          senderDisplayName: senderDisplayName,
          senderInstanceId: m.senderCharacterInstanceId !== undefined ? m.senderCharacterInstanceId : '',
          senderAvatarUri: senderAvatarUri,
          senderFallbackName: senderInst !== undefined ? senderInst.displayNameSnapshot : '',
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

      const activeCharCount: number = characterUiModels.filter((c: ChatCharacterUiModel): boolean => c.isActive).length;

      const uiModel: WorldSceneChatUiModel = {
        sceneId: scene.id,
        sceneName: locationName + ' · 会话',
        worldId: world.id,
        worldName: world.name,
        worldStatus: world.status as WorldStatus,
        locationId: scene.locationId,
        locationName: locationName,
        locationStatus: locationStatus,
        sceneStatus: scene.status as WorldSceneStatus,
        startedAt: scene.startedAt,
        endedAt: scene.endedAt !== undefined ? scene.endedAt : 0,
        participantCount: activeCharCount,
        characters: characterUiModels,
        messages: messageUiModels
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.detail = uiModel;
      this.state = WorldSceneChatLoadState.Ready;
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
      this.errorMessage = '场景数据加载失败,请重试';
      this.state = WorldSceneChatLoadState.Error;
    }
  }

  /** 发送 User 消息(公开或私下) */
  async addUserMessage(input: ChatUserMessageInput): Promise<ChatSaveResult> {
    if (this.isSending) {
      Logger.warn(LOG_TAG, 'addUserMessage skipped: isSending');
      return { success: false, errorMessage: '正在处理,请稍候' } as ChatSaveResult;
    }
    if (this.expectedSceneId.length === 0) {
      return { success: false, errorMessage: '场景未加载' } as ChatSaveResult;
    }
    this.isSending = true;
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
        return { success: false, errorMessage: '操作已过期' } as ChatSaveResult;
      }
      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return { success: true, errorMessage: '' } as ChatSaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as ChatSaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'addUserMessage failed: ' + this.safeErrorCategory(e)
        + ', visibility=' + input.visibility
        + ', sceneShortId=' + this.shortId(this.expectedSceneId));
      return { success: false, errorMessage: msg } as ChatSaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSending = false;
      }
    }
  }

  /** 手动添加角色消息 */
  async addCharacterMessage(input: ChatCharacterMessageInput): Promise<ChatSaveResult> {
    if (this.isSending) {
      Logger.warn(LOG_TAG, 'addCharacterMessage skipped: isSending');
      return { success: false, errorMessage: '正在处理,请稍候' } as ChatSaveResult;
    }
    if (this.expectedSceneId.length === 0) {
      return { success: false, errorMessage: '场景未加载' } as ChatSaveResult;
    }
    this.isSending = true;
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
        return { success: false, errorMessage: '操作已过期' } as ChatSaveResult;
      }
      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return { success: true, errorMessage: '' } as ChatSaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as ChatSaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'addCharacterMessage failed: ' + this.safeErrorCategory(e)
        + ', sceneShortId=' + this.shortId(this.expectedSceneId));
      return { success: false, errorMessage: msg } as ChatSaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSending = false;
      }
    }
  }

  /** 添加旁白消息 */
  async addNarratorMessage(input: ChatNarratorMessageInput): Promise<ChatSaveResult> {
    if (this.isSending) {
      Logger.warn(LOG_TAG, 'addNarratorMessage skipped: isSending');
      return { success: false, errorMessage: '正在处理,请稍候' } as ChatSaveResult;
    }
    if (this.expectedSceneId.length === 0) {
      return { success: false, errorMessage: '场景未加载' } as ChatSaveResult;
    }
    this.isSending = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.sceneService.addNarratorMessage({
        sceneId: this.expectedSceneId,
        content: input.content,
        witnessCharacterInstanceIds: input.witnessInstanceIds.length > 0 ? input.witnessInstanceIds : undefined
      });
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as ChatSaveResult;
      }
      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return { success: true, errorMessage: '' } as ChatSaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as ChatSaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'addNarratorMessage failed: ' + this.safeErrorCategory(e)
        + ', sceneShortId=' + this.shortId(this.expectedSceneId));
      return { success: false, errorMessage: msg } as ChatSaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isSending = false;
      }
    }
  }

  /** 结束场景 */
  async endScene(): Promise<ChatSaveResult> {
    if (this.isEnding) {
      Logger.warn(LOG_TAG, 'endScene skipped: isEnding');
      return { success: false, errorMessage: '正在处理,请稍候' } as ChatSaveResult;
    }
    if (this.expectedSceneId.length === 0) {
      return { success: false, errorMessage: '场景未加载' } as ChatSaveResult;
    }
    this.isEnding = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.sceneService.endScene(this.expectedSceneId);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as ChatSaveResult;
      }
      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return { success: true, errorMessage: '' } as ChatSaveResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as ChatSaveResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'endScene failed: ' + this.safeErrorCategory(e)
        + ', sceneShortId=' + this.shortId(this.expectedSceneId));
      return { success: false, errorMessage: msg } as ChatSaveResult;
    } finally {
      if (opId === this.operationId) {
        this.isEnding = false;
      }
    }
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

  private async safeGetInstance(instanceId: string): Promise<WorldCharacterInstance | null> {
    try {
      return await this.instanceRepo.getById(instanceId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'getById(instance) failed: ' + this.safeErrorCategory(e));
      return null;
    }
  }

  /** 递增刷新令牌,通知世界详情页和场景详情页刷新 */
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
export function formatChatTimestamp(ts: number): string {
  return formatWorldTimestamp(ts);
}
