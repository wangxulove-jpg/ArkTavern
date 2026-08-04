/**
 * WorldLocationSceneSheetViewModel 地点人物弹窗 ViewModel(W-UX-1)
 *
 * 职责:
 * - 根据 worldId + locationId 重新读取真实数据(Location / 当前人物 / Active Scene / Ended Scene 数量)
 * - 提供进入对话能力:无 Active Scene 时调用 startScene,有 Active Scene 时直接返回 sceneId
 * - 不缓存旧地点数据,每次 open 都重新读取
 * - 处理快速切换不同地点(expectedWorldId/expectedLocationId + loadOperationId)
 *
 * 依赖方向:
 * Sheet(Page 内嵌) → ViewModel → Repository(只读) / WorldSceneService(startScene 写入)
 *
 * 日志安全:不记录完整 ID / 描述 / SQL,仅记录操作类型、数量、状态、截断短 ID。
 */

import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneService } from '../../services/world/WorldSceneService';
import { CharacterService } from '../../services/CharacterService';
import { Logger } from '../../utils/Logger';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import { Character } from '../../models/Character';
import { mapWorldSceneErrorToMessage } from './WorldSceneErrorMapper';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';

const LOG_TAG: string = 'WorldLocationSceneSheetViewModel';

/** 弹窗加载状态 */
export enum LocationSheetLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

/** 地点人物 UI 模型 */
export interface SheetCharacterUiModel {
  readonly instanceId: string;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly isActive: boolean;
  readonly characterCardMissing: boolean;
}

/** 弹窗 UI 模型 */
export interface LocationSheetUiModel {
  readonly worldId: string;
  readonly worldStatus: WorldStatus;
  readonly locationId: string;
  readonly locationName: string;
  readonly locationDescription: string;
  readonly locationStatus: WorldLocationStatus;
  readonly characters: SheetCharacterUiModel[];
  readonly activeScene: WorldScene | null;
  readonly endedSceneCount: number;
  /** 是否允许创建新场景(World 和 Location 均 Active) */
  readonly canStartScene: boolean;
}

/** 进入对话结果 */
export interface EnterSceneResult {
  readonly success: boolean;
  readonly sceneId: string;
  readonly errorMessage: string;
}

export class WorldLocationSceneSheetViewModel {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly sceneService: WorldSceneService;
  private readonly characterService: CharacterService;

  state: LocationSheetLoadState = LocationSheetLoadState.Loading;
  errorMessage: string = '';
  detail: LocationSheetUiModel | null = null;

  private expectedWorldId: string = '';
  private expectedLocationId: string = '';
  private loadOperationId: number = 0;
  /** startScene 防重复 */
  isStarting: boolean = false;
  private disposed: boolean = false;
  readonly instanceShortId: string;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sceneRepo: WorldSceneRepository,
    sceneService: WorldSceneService,
    characterService: CharacterService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.sceneRepo = sceneRepo;
    this.sceneService = sceneService;
    this.characterService = characterService;
    this.instanceShortId = WorldLocationSceneSheetViewModel.generateShortId();
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

  expectedWorldIdOfPage(): string {
    return this.expectedWorldId;
  }

  expectedLocationIdOfPage(): string {
    return this.expectedLocationId;
  }

  /**
   * 加载地点弹窗快照。每次打开弹窗必须调用,不缓存旧数据。
   */
  async loadSnapshot(worldId: string, locationId: string): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'loadSnapshot skipped: disposed');
      return;
    }
    this.expectedWorldId = worldId;
    this.expectedLocationId = locationId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;

    this.state = LocationSheetLoadState.Loading;
    this.errorMessage = '';

    try {
      const world: World | null = await this.worldRepo.getById(worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.state = LocationSheetLoadState.NotFound;
        return;
      }

      const location: WorldLocation | null = await this.locationRepo.getById(locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (location === null) {
        this.state = LocationSheetLoadState.NotFound;
        return;
      }
      if (location.worldId !== worldId) {
        this.state = LocationSheetLoadState.NotFound;
        return;
      }

      // 加载当前地点全部角色实例
      const instances: WorldCharacterInstance[] = await this.safeListInstances(worldId, locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 批量解析角色卡
      const characterMap: Map<string, Character | null> = new Map<string, Character | null>();
      const characterIdSet: Set<string> = new Set<string>();
      for (let i = 0; i < instances.length; i++) {
        if (instances[i].characterId.length > 0) {
          characterIdSet.add(instances[i].characterId);
        }
      }
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
      const characterUiModels: SheetCharacterUiModel[] = new Array<SheetCharacterUiModel>(instances.length);
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
          isActive: inst.isActive,
          characterCardMissing: missing
        };
      }

      // 加载 Active Scene 和 Ended Scene 数量
      const activeScene: WorldScene | null = await this.safeFindActiveScene(worldId, locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const endedSceneCount: number = await this.safeCountEndedScenes(worldId, locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      const canStartScene: boolean = world.status === WorldStatus.Active
        && location.status === WorldLocationStatus.Active
        && activeScene === null;

      const uiModel: LocationSheetUiModel = {
        worldId: world.id,
        worldStatus: world.status as WorldStatus,
        locationId: location.id,
        locationName: location.name,
        locationDescription: location.description,
        locationStatus: location.status as WorldLocationStatus,
        characters: characterUiModels,
        activeScene: activeScene,
        endedSceneCount: endedSceneCount,
        canStartScene: canStartScene
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.detail = uiModel;
      this.state = LocationSheetLoadState.Ready;
      Logger.info(LOG_TAG, 'loadSnapshot done: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', state=ready, charCount=' + characterUiModels.length.toString()
        + ', hasActive=' + (activeScene !== null ? '1' : '0')
        + ', worldShortId=' + this.shortId(worldId)
        + ', locShortId=' + this.shortId(locationId));
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', ' + this.safeErrorCategory(e));
      this.errorMessage = '地点数据加载失败,请重试';
      this.state = LocationSheetLoadState.Error;
    }
  }

  /**
   * 进入对话。
   * - 已有 Active Scene:直接返回 sceneId
   * - 无 Active Scene 但可创建:调用 startScene 后返回新 sceneId
   * - 其他情况返回错误
   */
  async enterScene(): Promise<EnterSceneResult> {
    if (this.isStarting) {
      Logger.warn(LOG_TAG, 'enterScene skipped: isStarting');
      return { success: false, sceneId: '', errorMessage: '正在处理,请稍候' } as EnterSceneResult;
    }
    if (this.detail === null) {
      return { success: false, sceneId: '', errorMessage: '地点数据未加载' } as EnterSceneResult;
    }
    const detail: LocationSheetUiModel = this.detail;
    // 已有 Active Scene:直接返回
    if (detail.activeScene !== null) {
      Logger.info(LOG_TAG, 'enterScene: existing active scene, sceneShortId=' + this.shortId(detail.activeScene.id));
      return { success: true, sceneId: detail.activeScene.id, errorMessage: '' } as EnterSceneResult;
    }
    // 无 Active Scene,检查是否可创建
    if (!detail.canStartScene) {
      return { success: false, sceneId: '', errorMessage: '当前世界或地点已归档,无法开始新场景' } as EnterSceneResult;
    }

    this.isStarting = true;
    try {
      const scene: WorldScene = await this.sceneService.startScene(detail.worldId, detail.locationId);
      Logger.info(LOG_TAG, 'enterScene: started new scene, sceneShortId=' + this.shortId(scene.id));
      return { success: true, sceneId: scene.id, errorMessage: '' } as EnterSceneResult;
    } catch (e) {
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'enterScene failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(detail.worldId)
        + ', locShortId=' + this.shortId(detail.locationId));
      return { success: false, sceneId: '', errorMessage: msg } as EnterSceneResult;
    } finally {
      this.isStarting = false;
    }
  }

  // ===== 私有辅助 =====

  private async safeListInstances(worldId: string, locationId: string): Promise<WorldCharacterInstance[]> {
    try {
      return await this.instanceRepo.listByLocation(worldId, locationId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByLocation failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async safeFindActiveScene(worldId: string, locationId: string): Promise<WorldScene | null> {
    try {
      return await this.sceneRepo.findActiveByWorldAndLocation(worldId, locationId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'findActiveByWorldAndLocation failed: ' + this.safeErrorCategory(e));
      return null;
    }
  }

  private async safeCountEndedScenes(worldId: string, locationId: string): Promise<number> {
    try {
      const scenes: WorldScene[] = await this.sceneRepo.listByLocation(locationId);
      let count: number = 0;
      for (let i = 0; i < scenes.length; i++) {
        if (scenes[i].status === WorldSceneStatus.Ended) {
          count = count + 1;
        }
      }
      return count;
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByLocation(scenes) failed: ' + this.safeErrorCategory(e));
      return 0;
    }
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
