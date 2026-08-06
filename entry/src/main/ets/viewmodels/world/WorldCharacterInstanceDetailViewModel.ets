/**
 * WorldCharacterInstanceDetailViewModel 角色实例详情 ViewModel(W-UI-1B)
 *
 * 职责:
 * - 加载角色实例(WorldCharacterInstanceRepository.getById)
 * - 解析角色卡(CharacterService.getById)
 * - 解析世界名称(WorldRepository.getById)
 * - 解析地点名称(WorldLocationRepository.getById)
 * - 映射 UI 模型
 *
 * 依赖方向:Page → ViewModel → Repository(只读) + CharacterService(只读)
 */

import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { CharacterService } from '../../services/CharacterService';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { Character } from '../../models/Character';
import { Logger } from '../../utils/Logger';
import { WorldInstanceDetailLoadState, WorldCharacterInstanceDetailUiModel } from './WorldUiModels';

const LOG_TAG: string = 'WorldCharInstanceDetailVM';

export class WorldCharacterInstanceDetailViewModel {
  private readonly instanceRepository: WorldCharacterInstanceRepository;
  private readonly worldRepository: WorldRepository;
  private readonly locationRepository: WorldLocationRepository;
  private readonly characterService: CharacterService;

  loadState: WorldInstanceDetailLoadState = WorldInstanceDetailLoadState.Loading;
  errorMessage: string = '';
  detail: WorldCharacterInstanceDetailUiModel | null = null;

  private disposed: boolean = false;
  readonly instanceShortId: string;

  constructor(
    instanceRepository: WorldCharacterInstanceRepository,
    worldRepository: WorldRepository,
    locationRepository: WorldLocationRepository,
    characterService: CharacterService
  ) {
    this.instanceRepository = instanceRepository;
    this.worldRepository = worldRepository;
    this.locationRepository = locationRepository;
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
    } catch (e) {
      if (this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: ' + this.safeErrorCategory(e));
      this.loadState = WorldInstanceDetailLoadState.Error;
      this.errorMessage = '角色实例详情加载失败,请重试';
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