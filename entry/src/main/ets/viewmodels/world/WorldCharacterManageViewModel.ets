/**
 * WorldCharacterManageViewModel 世界角色管理 ViewModel(W-CONTROL-1A → W2A2)
 *
 * 职责:
 * - 加载已加入世界的角色实例列表(WorldCharacterInstanceRepository.listByWorld)
 * - 加载可加入的候选角色(CharacterService.list,过滤已加入的)
 * - 加载世界下的 Active 地点列表(用于初始放置选择)
 * - 添加角色到世界(WorldStateService.addCharacterToWorld)
 * - 添加角色并立即放置(addCharacterToWorld + placeCharacter)
 * - 设置初始地点(WorldStateService.placeCharacter)
 * - 启用/停用实例(WorldStateService.setCharacterInstanceActive)
 * - 从世界移除实例(WorldStateService.removeCharacterFromWorld)
 * - 从地图撤下角色(WorldStateService.unplaceCharacter)
 *
 * 依赖方向:Page → ViewModel → WorldStateService(写) + Repository(只读)
 */

import { WorldStateService } from '../../services/world/WorldStateService';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { CharacterService } from '../../services/CharacterService';
import { Character } from '../../models/Character';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { Logger } from '../../utils/Logger';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';

const LOG_TAG: string = 'WorldCharacterManageViewModel';

/** 加载状态 */
export enum WorldCharacterManageLoadState {
  Loading = 'loading',
  Ready = 'ready',
  NotFound = 'not_found',
  Error = 'error'
}

/** 已加入世界的角色实例 UI 模型 */
export interface WorldCharacterInstanceManageUiModel {
  readonly id: string;
  readonly characterId: string;
  readonly displayName: string;
  readonly isActive: boolean;
  readonly currentLocationId: string;
  readonly currentLocationName: string;
  readonly characterCardMissing: boolean;
  readonly avatarUri: string;
  readonly fallbackName: string;
}

/** 可加入世界的候选角色 UI 模型 */
export interface CandidateCharacterUiModel {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly avatarUri: string;
  readonly fallbackName: string;
}

/** Active 地点选项 */
export interface ActiveLocationOptionUiModel {
  readonly id: string;
  readonly name: string;
}

export class WorldCharacterManageViewModel {
  private readonly stateService: WorldStateService;
  private readonly locationRepository: WorldLocationRepository;
  private readonly instanceRepository: WorldCharacterInstanceRepository;
  private readonly characterService: CharacterService;

  private boundWorldId: string;

  loadState: WorldCharacterManageLoadState = WorldCharacterManageLoadState.Loading;
  /** 已加入的角色实例列表 */
  instances: WorldCharacterInstanceManageUiModel[] = [];
  /** 可加入的候选角色列表 */
  candidates: CandidateCharacterUiModel[] = [];
  /** Active 地点选项 */
  activeLocations: ActiveLocationOptionUiModel[] = [];
  /** 世界是否有 Active 地点(决定"暂不放置/放置到地点"选择) */
  hasLocations: boolean = false;
  /** 未放置角色数量(已加入但 currentLocationId 为空) */
  unplacedCount: number = 0;
  /** 用户可见错误 */
  errorMessage: string = '';

  /** 操作中状态(用于禁用按钮) */
  isSaving: boolean = false;
  /** 删除中状态 */
  isDeleting: boolean = false;

  /** 操作 ID(防重复 / 拒绝迟到结果) */
  private loadOperationId: number = 0;
  /** 页面是否已销毁(aboutToDisappear 时置 true,onPageShow/refreshToken 时通过 activate 恢复) */
  private disposed: boolean = false;
  /** ViewModel 实例短标识(日志用) */
  readonly instanceShortId: string;

  constructor(
    stateService: WorldStateService,
    locationRepository: WorldLocationRepository,
    instanceRepository: WorldCharacterInstanceRepository,
    characterService: CharacterService,
    worldId: string
  ) {
    this.stateService = stateService;
    this.locationRepository = locationRepository;
    this.instanceRepository = instanceRepository;
    this.characterService = characterService;
    this.boundWorldId = worldId;
    this.instanceShortId = WorldCharacterManageViewModel.generateShortId();
  }

  /**
   * 重新激活 ViewModel。
   *
   * router.pushUrl 覆盖页面时 aboutToDisappear 可能触发并 dispose,
   * 返回页面后(onPageShow / manageRefreshToken 回调)调用此方法恢复,
   * 确保移动角色返回后角色管理页能正常刷新当前位置。
   *
   * 幂等:已激活时调用无副作用。
   */
  activate(): void {
    if (this.disposed) {
      this.disposed = false;
      Logger.info(LOG_TAG, 'activate: vmInstance=' + this.instanceShortId);
    }
  }

  private static generateShortId(): string {
    const ts: number = Date.now();
    const tail: number = Math.floor(ts % 0xffff);
    return tail.toString(16).padStart(4, '0');
  }

  /** 加载世界角色管理快照 */
  async loadSnapshot(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.boundWorldId.length === 0) {
      this.loadState = WorldCharacterManageLoadState.NotFound;
      return;
    }
    this.loadState = WorldCharacterManageLoadState.Loading;
    this.loadOperationId = this.loadOperationId + 1;
    const opId: number = this.loadOperationId;
    try {
      // 1. 加载已加入的角色实例
      const instancesResult: WorldCharacterInstance[] =
        await this.instanceRepository.listByWorld(this.boundWorldId);
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 2. 加载世界下全部 Active 地点
      const locationsResult: WorldLocation[] =
        await this.locationRepository.listByWorld(this.boundWorldId);
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 3. 批量解析角色卡(去重 characterId)
      const characterIdSet: Set<string> = new Set<string>();
      for (let i: number = 0; i < instancesResult.length; i++) {
        const cid: string = instancesResult[i].characterId;
        if (cid.length > 0) {
          characterIdSet.add(cid);
        }
      }
      const characterMap: Map<string, Character | null> = new Map<string, Character | null>();
      const characterIds: string[] = Array.from(characterIdSet);
      for (let i: number = 0; i < characterIds.length; i++) {
        if (opId !== this.loadOperationId || this.disposed) {
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
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 4. 构造地点查找表
      const locationMap: Map<string, WorldLocation> = new Map<string, WorldLocation>();
      for (let i: number = 0; i < locationsResult.length; i++) {
        locationMap.set(locationsResult[i].id, locationsResult[i]);
      }

      // 5. 映射已加入角色实例 UI 模型
      const instanceUiModels: WorldCharacterInstanceManageUiModel[] =
        new Array<WorldCharacterInstanceManageUiModel>(instancesResult.length);
      const joinedCharacterIdSet: Set<string> = new Set<string>();
      for (let i: number = 0; i < instancesResult.length; i++) {
        const inst: WorldCharacterInstance = instancesResult[i];
        joinedCharacterIdSet.add(inst.characterId);
        const character: Character | null | undefined = characterMap.get(inst.characterId);
        const characterCardMissing: boolean = character === null || character === undefined;
        const displayName: string = !characterCardMissing && character !== null && character !== undefined
          ? character.name
          : inst.displayNameSnapshot;
        const avatarUri: string = !characterCardMissing && character !== null && character !== undefined
          ? character.avatarUri
          : '';
        // 解析当前位置名称
        let currentLocationName: string = '';
        if (inst.currentLocationId !== undefined && inst.currentLocationId.length > 0) {
          const loc: WorldLocation | undefined = locationMap.get(inst.currentLocationId);
          currentLocationName = loc !== undefined ? loc.name : '(未知地点)';
        }
        instanceUiModels[i] = {
          id: inst.id,
          characterId: inst.characterId,
          displayName: displayName,
          isActive: inst.isActive,
          currentLocationId: inst.currentLocationId !== undefined ? inst.currentLocationId : '',
          currentLocationName: currentLocationName,
          characterCardMissing: characterCardMissing,
          avatarUri: avatarUri,
          fallbackName: displayName.length > 0 ? displayName.charAt(0) : '?'
        };
      }
      this.instances = instanceUiModels;

      // 6. Active 地点选项(用于初始放置选择)
      const activeLocationOptions: ActiveLocationOptionUiModel[] = [];
      for (let i: number = 0; i < locationsResult.length; i++) {
        if (locationsResult[i].status === WorldLocationStatus.Active) {
          activeLocationOptions.push({
            id: locationsResult[i].id,
            name: locationsResult[i].name
          });
        }
      }
      this.activeLocations = activeLocationOptions;
      this.hasLocations = activeLocationOptions.length > 0;

      // 7. 统计未放置角色
      let unplaced: number = 0;
      for (let i: number = 0; i < instanceUiModels.length; i++) {
        if (instanceUiModels[i].currentLocationId.length === 0) {
          unplaced = unplaced + 1;
        }
      }
      this.unplacedCount = unplaced;

      // 8. 加载全部角色并过滤已加入的,得到候选列表
      const allCharacters: Character[] = await this.characterService.list();
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }
      const candidateUiModels: CandidateCharacterUiModel[] = [];
      for (let i: number = 0; i < allCharacters.length; i++) {
        const c: Character = allCharacters[i];
        if (joinedCharacterIdSet.has(c.id)) {
          continue;
        }
        candidateUiModels.push({
          id: c.id,
          name: c.name,
          description: c.description,
          avatarUri: c.avatarUri,
          fallbackName: c.name.length > 0 ? c.name.charAt(0) : '?'
        });
      }
      this.candidates = candidateUiModels;

      this.loadState = WorldCharacterManageLoadState.Ready;
    } catch (e) {
      if (opId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: ' + this.safeErrorCategory(e));
      this.loadState = WorldCharacterManageLoadState.Error;
      this.errorMessage = '世界角色数据加载失败,请重试';
    }
  }

  /**
   * 添加角色到世界(W2A1:不再强制初始地点,角色创建后为未放置状态)。
   * @param characterId 角色 ID
   */
  async addCharacterToWorld(
    characterId: string
  ): Promise<boolean> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return false;
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      await this.stateService.addCharacterToWorld(
        this.boundWorldId, characterId
      );
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'addCharacterToWorld failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isSaving = false;
      }
    }
  }

  /**
   * 添加角色到世界并立即放置到指定地点(W2A2)。
   * 先 addCharacterToWorld,成功后 placeCharacter。
   * @param characterId 角色 ID
   * @param locationId 目标地点 ID
   */
  async addAndPlaceCharacter(
    characterId: string,
    locationId: string
  ): Promise<boolean> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return false;
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      const instance: WorldCharacterInstance =
        await this.stateService.addCharacterToWorld(this.boundWorldId, characterId);
      if (this.disposed) {
        return false;
      }
      await this.stateService.placeCharacter(instance.id, locationId);
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'addAndPlaceCharacter failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isSaving = false;
      }
    }
  }

  /** 从地图撤下角色(仅清空 currentLocationId,保留实例) */
  async unplaceCharacter(instanceId: string): Promise<boolean> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return false;
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      await this.stateService.unplaceCharacter(instanceId);
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'unplaceCharacter failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isSaving = false;
      }
    }
  }

  /** 设置角色初始地点(仅允许 currentLocationId 为空时) */
  async placeCharacter(instanceId: string, locationId: string): Promise<boolean> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return false;
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      await this.stateService.placeCharacter(instanceId, locationId);
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'placeCharacter failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isSaving = false;
      }
    }
  }

  /** 启用或停用角色实例 */
  async setInstanceActive(instanceId: string, active: boolean): Promise<boolean> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return false;
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      await this.stateService.setCharacterInstanceActive(instanceId, active);
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'setInstanceActive failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isSaving = false;
      }
    }
  }

  /** 从世界移除角色实例 */
  async removeCharacterFromWorld(instanceId: string): Promise<boolean> {
    if (this.disposed || this.isSaving || this.isDeleting) {
      return false;
    }
    this.isDeleting = true;
    this.errorMessage = '';
    try {
      await this.stateService.removeCharacterFromWorld(instanceId);
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot();
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'removeCharacterFromWorld failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isDeleting = false;
      }
    }
  }

  /** 清除错误消息 */
  clearError(): void {
    this.errorMessage = '';
  }

  /** 标记页面已销毁(返回页面后需通过 activate 恢复) */
  dispose(): void {
    this.disposed = true;
    Logger.info(LOG_TAG, 'dispose: vmInstance=' + this.instanceShortId);
  }

  /** 安全错误分类(日志用,不含 SQL) */
  private safeErrorCategory(e: Object): string {
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }
}
