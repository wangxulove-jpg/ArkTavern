/**
 * WorldCharacterAnalysisPreviewViewModel 角色分析预览 ViewModel(W-UI-1B)
 *
 * 职责:
 * - 加载角色卡(CharacterService.getById)
 * - 加载世界信息(WorldRepository.getById)
 * - 加载世界 Active 地点列表(WorldLocationRepository.listByWorld)
 * - 生成确定性本地预览(不调用 ModelService / AI)
 * - 确认加入世界(WorldStateService.addCharacterToWorld)
 *
 * 依赖方向:Page → ViewModel → WorldStateService(写) + Repository(只读) + CharacterService(只读)
 *
 * 不修改原 Character。
 */

import { CharacterService } from '../../services/CharacterService';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldStateService } from '../../services/world/WorldStateService';
import { Character } from '../../models/Character';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { Logger } from '../../utils/Logger';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';
import {
  CharacterAnalysisPreviewUiModel,
  CharacterPreviewLoadState
} from './WorldUiModels';

const LOG_TAG: string = 'WorldCharAnalysisPreviewVM';

export class WorldCharacterAnalysisPreviewViewModel {
  private readonly characterService: CharacterService;
  private readonly worldRepository: WorldRepository;
  private readonly locationRepository: WorldLocationRepository;
  private readonly stateService: WorldStateService;

  private boundWorldId: string = '';
  private boundCharacterId: string = '';

  loadState: CharacterPreviewLoadState = CharacterPreviewLoadState.Loading;
  errorMessage: string = '';
  preview: CharacterAnalysisPreviewUiModel | null = null;
  isJoining: boolean = false;

  /** Active 地点选项 */
  activeLocationIds: string[] = [];
  activeLocationNames: string[] = [];
  /** 用户选中的地点 ID(空字符串 = 暂不设置) */
  selectedLocationId: string = '';

  private disposed: boolean = false;
  readonly instanceShortId: string;

  constructor(
    characterService: CharacterService,
    worldRepository: WorldRepository,
    locationRepository: WorldLocationRepository,
    stateService: WorldStateService
  ) {
    this.characterService = characterService;
    this.worldRepository = worldRepository;
    this.locationRepository = locationRepository;
    this.stateService = stateService;
    this.instanceShortId = WorldCharacterAnalysisPreviewViewModel.generateShortId();
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

  async loadPreview(worldId: string, characterId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.boundWorldId = worldId;
    this.boundCharacterId = characterId;
    this.loadState = CharacterPreviewLoadState.Loading;
    this.errorMessage = '';

    try {
      const character: Character | null = await this.characterService.getById(characterId);
      if (this.disposed) {
        return;
      }
      if (character === null) {
        this.loadState = CharacterPreviewLoadState.NotFound;
        return;
      }

      const locations: WorldLocation[] = await this.locationRepository.listByWorld(worldId);
      if (this.disposed) {
        return;
      }

      const activeLocIds: string[] = [];
      const activeLocNames: string[] = [];
      for (let i: number = 0; i < locations.length; i++) {
        if (locations[i].status === WorldLocationStatus.Active) {
          activeLocIds.push(locations[i].id);
          activeLocNames.push(locations[i].name);
        }
      }
      this.activeLocationIds = activeLocIds;
      this.activeLocationNames = activeLocNames;

      const tagsList: string[] = character.tags;
      const suggestedIdentity: string = this.buildSuggestedIdentity(character);
      const suggestedLocationId: string = activeLocIds.length > 0 ? activeLocIds[0] : '';
      const suggestedLocationName: string = activeLocNames.length > 0 ? activeLocNames[0] : '';
      this.selectedLocationId = suggestedLocationId;

      const iconStyle: string = '圆形头像 · 暖金色描边';
      const initialState: string = character.firstMessage.length > 0
        ? '已具备开场白,可直接进入场景'
        : '无开场白,需手动指定首个消息';
      const initialGoal: string = character.scenario.length > 0
        ? '基于角色设定场景,在世界中找到初始行动方向'
        : '尚未设定角色场景,可在后续编辑中补充';

      this.preview = {
        characterId: character.id,
        characterName: character.name,
        avatarUri: character.avatarUri,
        fallbackName: character.name.length > 0 ? character.name.charAt(0) : '?',
        description: character.description,
        personality: character.personality,
        scenario: character.scenario,
        tags: tagsList,
        suggestedWorldIdentity: suggestedIdentity,
        suggestedLocationId: suggestedLocationId,
        suggestedLocationName: suggestedLocationName,
        iconStyle: iconStyle,
        initialState: initialState,
        initialGoal: initialGoal
      };
      this.loadState = CharacterPreviewLoadState.Ready;
    } catch (e) {
      if (this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadPreview failed: ' + this.safeErrorCategory(e));
      this.loadState = CharacterPreviewLoadState.Error;
      this.errorMessage = '角色分析预览加载失败,请重试';
    }
  }

  /** 确认加入世界 */
  async confirmJoinWorld(): Promise<boolean> {
    if (this.disposed || this.isJoining) {
      return false;
    }
    if (this.boundWorldId.length === 0 || this.boundCharacterId.length === 0) {
      return false;
    }
    this.isJoining = true;
    this.errorMessage = '';
    try {
      await this.stateService.addCharacterToWorld(
        this.boundWorldId, this.boundCharacterId
      );
      if (this.disposed) {
        return false;
      }
      return true;
    } catch (e) {
      if (this.disposed) {
        return false;
      }
      Logger.error(LOG_TAG, 'confirmJoinWorld failed: ' + this.safeErrorCategory(e));
      this.errorMessage = mapWorldStateErrorToMessage(e);
      return false;
    } finally {
      if (!this.disposed) {
        this.isJoining = false;
      }
    }
  }

  clearError(): void {
    this.errorMessage = '';
  }

  private buildSuggestedIdentity(character: Character): string {
    if (character.personality.length > 0) {
      const firstSentence: number = character.personality.indexOf('。');
      if (firstSentence > 0 && firstSentence < 60) {
        return character.personality.substring(0, firstSentence + 1);
      }
      return character.personality.substring(0, Math.min(character.personality.length, 60));
    }
    if (character.description.length > 0) {
      return character.description.substring(0, Math.min(character.description.length, 60));
    }
    return character.name + ' · 等待在世界中登场';
  }

  private safeErrorCategory(e: Object): string {
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }
}