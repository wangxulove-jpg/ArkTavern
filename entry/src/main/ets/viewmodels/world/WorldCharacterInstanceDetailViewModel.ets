/**
 * WorldCharacterInstanceDetailViewModel 角色实例详情 ViewModel(W-UI-1B → W2A2)
 *
 * 职责:
 * - 加载角色实例(WorldCharacterInstanceRepository.getById)
 * - 解析角色卡(CharacterService.getById)
 * - 解析世界名称(WorldRepository.getById)
 * - 解析地点名称(WorldLocationRepository.getById)
 * - 映射 UI 模型
 * - 从地图撤下角色(WorldStateService.unplaceCharacter)
 * - 调整位置(WorldStateService.forceMoveCharacter,管理员位置调整,不检查 Edge)
 * - 从世界移除(WorldStateService.removeCharacterFromWorld)
 * - 放置到地点(WorldStateService.placeCharacter)
 * - 加载世界 Active 地点列表(用于位置调整/放置选择)
 *
 * 依赖方向:Page → ViewModel → Repository(只读) + CharacterService(只读) + WorldStateService(写)
 */

import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldStateService } from '../../services/world/WorldStateService';
import { WorldCharacterMovementService, TravelOption } from '../../services/world/WorldCharacterMovementService';
import { WorldPerceptionService } from '../../services/world/WorldPerceptionService';
import { CharacterService } from '../../services/CharacterService';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { Character } from '../../models/Character';
import { Logger } from '../../utils/Logger';
import { WorldInstanceDetailLoadState, WorldCharacterInstanceDetailUiModel } from './WorldUiModels';
import { ActiveLocationOptionUiModel } from './WorldCharacterManageViewModel';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';
import { mapWorldMovementErrorToMessage } from './WorldMovementErrorMapper';

const LOG_TAG: string = 'WorldCharInstanceDetailVM';

export class WorldCharacterInstanceDetailViewModel {
  private readonly instanceRepository: WorldCharacterInstanceRepository;
  private readonly worldRepository: WorldRepository;
  private readonly locationRepository: WorldLocationRepository;
  private readonly stateService: WorldStateService;
  private readonly movementService: WorldCharacterMovementService;
  private readonly perceptionService: WorldPerceptionService;
  private readonly characterService: CharacterService;

  loadState: WorldInstanceDetailLoadState = WorldInstanceDetailLoadState.Loading;
  errorMessage: string = '';
  detail: WorldCharacterInstanceDetailUiModel | null = null;
  activeLocations: ActiveLocationOptionUiModel[] = [];
  travelOptions: TravelOption[] = [];
  coPresentDisplayNames: string[] = [];
  isTravelling: boolean = false;

  isOperating: boolean = false;

  private disposed: boolean = false;
  private boundInstanceId: string = '';
  readonly instanceShortId: string;

  constructor(
    instanceRepository: WorldCharacterInstanceRepository,
    worldRepository: WorldRepository,
    locationRepository: WorldLocationRepository,
    stateService: WorldStateService,
    movementService: WorldCharacterMovementService,
    perceptionService: WorldPerceptionService,
    characterService: CharacterService
  ) {
    this.instanceRepository = instanceRepository;
    this.worldRepository = worldRepository;
    this.locationRepository = locationRepository;
    this.stateService = stateService;
    this.movementService = movementService;
    this.perceptionService = perceptionService;
    this.characterService = characterService;
    this.instanceShortId = WorldCharacterInstanceDetailViewModel.generateShortId();
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
  }

  async loadSnapshot(instanceId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.boundInstanceId = instanceId;
    this.loadState = WorldInstanceDetailLoadState.Loading;
    this.errorMessage = '';
    try {
      const instance: WorldCharacterInstance | null =
        await this.instanceRepository.getById(instanceId);
      if (this.disposed) {
        return;
      }
      if (instance === null) {
        this.loadState = WorldInstanceDetailLoadState.NotFound;
        return;
      }

      const world: World | null = await this.worldRepository.getById(instance.worldId);
      if (this.disposed) {
        return;
      }
      const worldName: string = world !== null ? world.name : '(世界数据缺失)';

      const character: Character | null =
        await this.characterService.getById(instance.characterId);
      if (this.disposed) {
        return;
      }
      const characterCardMissing: boolean = character === null;
      const displayName: string = !characterCardMissing && character !== null
        ? character.name
        : instance.displayNameSnapshot;
      const avatarUri: string = !characterCardMissing && character !== null
        ? character.avatarUri
        : '';

      let currentLocationName: string = '';
      let locationMissing: boolean = false;
      if (instance.currentLocationId !== undefined && instance.currentLocationId.length > 0) {
        const loc: WorldLocation | null =
          await this.locationRepository.getById(instance.currentLocationId);
        if (loc === null) {
          locationMissing = true;
          currentLocationName = '(地点已删除)';
        } else {
          currentLocationName = loc.name;
        }
      }

      this.detail = {
        instanceId: instance.id,
        worldId: instance.worldId,
        worldName: worldName,
        characterId: instance.characterId,
        displayName: displayName,
        avatarUri: avatarUri,
        fallbackName: displayName.length > 0 ? displayName.charAt(0) : '?',
        isActive: instance.isActive,
        currentLocationId: instance.currentLocationId !== undefined ? instance.currentLocationId : '',
        currentLocationName: currentLocationName,
        locationMissing: locationMissing,
        characterCardMissing: characterCardMissing,
        createdAt: instance.createdAt,
        updatedAt: instance.updatedAt
      };
      this.loadState = WorldInstanceDetailLoadState.Ready;

      await this.loadActiveLocations(instance.worldId);
      await this.loadTravelOptions();
      await this.loadCoPresentInfo(instance);
    } catch (e) {
      if (this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: ' + this.safeErrorCategory(e));
      this.loadState = WorldInstanceDetailLoadState.Error;
      this.errorMessage = '角色实例详情加载失败,请重试';
    }
  }

  private async loadActiveLocations(worldId: string): Promise<void> {
    try {
      const locations: WorldLocation[] = await this.locationRepository.listByWorld(worldId);
      const options: ActiveLocationOptionUiModel[] = [];
      for (let i: number = 0; i < locations.length; i++) {
        if (locations[i].status === WorldLocationStatus.Active) {
          options.push({
            id: locations[i].id,
            name: locations[i].name
          });
        }
      }
      this.activeLocations = options;
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadActiveLocations failed: ' + this.safeErrorCategory(e));
      this.activeLocations = [];
    }
  }

  /** 前往目标地点(通过连接移动,需 Edge 可通行) */
  async travelCharacter(targetLocationId: string): Promise<boolean> {
    if (this.disposed || this.isTravelling || this.boundInstanceId.length === 0) {
      return false;
    }
    this.isTravelling = true;
    this.errorMessage = '';
    try {
      await this.movementService.travelCharacter(this.boundInstanceId, targetLocationId);
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot(this.boundInstanceId);
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'travelCharacter failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldMovementErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isTravelling = false;
      }
    }
  }

  /** 加载前往选项(来自 listTravelOptions) */
  async loadTravelOptions(): Promise<void> {
    if (this.disposed || this.boundInstanceId.length === 0) {
      this.travelOptions = [];
      return;
    }
    try {
      this.travelOptions = await this.movementService.listTravelOptions(this.boundInstanceId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadTravelOptions failed: ' + this.safeErrorCategory(e));
      this.travelOptions = [];
    }
  }

  /** 加载当前地点共处角色信息(Perception) */
  private async loadCoPresentInfo(instance: WorldCharacterInstance): Promise<void> {
    if (instance.currentLocationId === undefined || instance.currentLocationId.length === 0) {
      this.coPresentDisplayNames = [];
      return;
    }
    try {
      const snapshot = await this.perceptionService.getCharacterPerception(
        instance.worldId, instance.id, instance.currentLocationId
      );
      const names: string[] = [];
      for (let i = 0; i < snapshot.coPresentCharacterInstanceIds.length; i++) {
        const coInstanceId: string = snapshot.coPresentCharacterInstanceIds[i];
        const coInstance: WorldCharacterInstance | null =
          await this.instanceRepository.getById(coInstanceId);
        if (coInstance !== null) {
          names.push(coInstance.displayNameSnapshot);
        } else {
          names.push('(未知)');
        }
      }
      this.coPresentDisplayNames = names;
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadCoPresentInfo failed: ' + this.safeErrorCategory(e));
      this.coPresentDisplayNames = [];
    }
  }

  /** 从地图撤下角色(清空 currentLocationId,保留实例) */
  async unplaceCharacter(): Promise<boolean> {
    if (this.disposed || this.isOperating || this.boundInstanceId.length === 0) {
      return false;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.stateService.unplaceCharacter(this.boundInstanceId);
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot(this.boundInstanceId);
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
        this.isOperating = false;
      }
    }
  }

  /** 调整位置(管理员位置调整,不检查 Edge,文案用"调整位置"非"移动") */
  async adjustLocation(targetLocationId: string): Promise<boolean> {
    if (this.disposed || this.isOperating || this.boundInstanceId.length === 0) {
      return false;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.stateService.forceMoveCharacter(this.boundInstanceId, targetLocationId);
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot(this.boundInstanceId);
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'adjustLocation failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isOperating = false;
      }
    }
  }

  /** 放置到地点(仅未放置时) */
  async placeAtLocation(locationId: string): Promise<boolean> {
    if (this.disposed || this.isOperating || this.boundInstanceId.length === 0) {
      return false;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.stateService.placeCharacter(this.boundInstanceId, locationId);
      if (this.disposed) {
        return false;
      }
      await this.loadSnapshot(this.boundInstanceId);
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'placeAtLocation failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isOperating = false;
      }
    }
  }

  /** 从世界移除角色实例 */
  async removeFromWorld(): Promise<boolean> {
    if (this.disposed || this.isOperating || this.boundInstanceId.length === 0) {
      return false;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.stateService.removeCharacterFromWorld(this.boundInstanceId);
      if (this.disposed) {
        return false;
      }
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'removeFromWorld failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isOperating = false;
      }
    }
  }

  clearError(): void {
    this.errorMessage = '';
  }

  private safeErrorCategory(e: Object): string {
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }
}