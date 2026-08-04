/**
 * WorldSceneManageViewModel 场景管理页 ViewModel(W-SCENE-1B)
 *
 * 职责:
 * - 根据 worldId 加载世界 + 全部地点 + 每个地点的 Active Scene 和 Ended Scene 数量
 * - 开始场景(调用 WorldSceneService.startScene)
 * - 提供地点场景视图供页面渲染
 * - 处理页面快速切换(expectedWorldId + loadOperationId)和销毁(disposed)
 * - 写操作防重复(operationId + isStarting)
 *
 * 依赖方向:
 * Page → ViewModel → Repository(只读) / WorldSceneService(写入)
 *
 * 不在 ArkUI Builder 中查询数据库。
 */

import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneService } from '../../services/world/WorldSceneService';
import { Logger } from '../../utils/Logger';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import { DatabaseError } from '../../models/DatabaseError';
import { mapWorldSceneErrorToMessage } from './WorldSceneErrorMapper';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';
import {
  WORLD_DETAIL_REFRESH_TOKEN_KEY
} from './WorldUiModels';

const LOG_TAG: string = 'WorldSceneManageViewModel';

/** 场景管理页加载状态 */
export enum WorldSceneManageLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

/** 地点场景视图模型 */
export interface LocationSceneUiModel {
  readonly locationId: string;
  readonly locationName: string;
  readonly locationStatus: WorldLocationStatus;
  readonly activeScene: WorldScene | null;
  readonly endedSceneCount: number;
}

/** 场景管理页 UI 模型 */
export interface WorldSceneManageUiModel {
  readonly worldId: string;
  readonly worldName: string;
  readonly worldStatus: WorldStatus;
  readonly locations: LocationSceneUiModel[];
}

/** startScene 操作结果 */
export interface StartSceneResult {
  readonly success: boolean;
  readonly errorMessage: string;
}

export class WorldSceneManageViewModel {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly sceneService: WorldSceneService;

  state: WorldSceneManageLoadState = WorldSceneManageLoadState.Loading;
  errorMessage: string = '';
  detail: WorldSceneManageUiModel | null = null;

  /** 当前页面绑定的 worldId */
  private expectedWorldId: string = '';
  /** 加载操作 ID(每次 loadSnapshot 自增) */
  private loadOperationId: number = 0;
  /** 写操作 ID(每次 startScene 自增,用于防重复) */
  private operationId: number = 0;
  /** 是否正在开始场景(防重复点击) */
  isStarting: boolean = false;
  /** 是否正在结束场景(防重复点击) */
  isEnding: boolean = false;
  /** 页面是否已销毁 */
  private disposed: boolean = false;
  /** ViewModel 实例短标识(日志用) */
  readonly instanceShortId: string;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    sceneRepo: WorldSceneRepository,
    sceneService: WorldSceneService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.sceneRepo = sceneRepo;
    this.sceneService = sceneService;
    this.instanceShortId = WorldSceneManageViewModel.generateShortId();
  }

  private static generateShortId(): string {
    const ts: number = Date.now();
    const tail: number = Math.floor(ts % 0xffff);
    return tail.toString(16).padStart(4, '0');
  }

  /**
   * 重新激活 ViewModel(aboutToDisappear 可能在 pushUrl 覆盖页面时触发)。
   */
  activate(): void {
    if (this.disposed) {
      this.disposed = false;
      Logger.info(LOG_TAG, 'activate: vmInstance=' + this.instanceShortId);
    }
  }

  setWorldId(worldId: string): void {
    if (this.expectedWorldId !== worldId) {
      this.expectedWorldId = worldId;
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  /** Page 读取当前绑定的 worldId(用于路由跳转等) */
  expectedWorldIdOfPage(): string {
    return this.expectedWorldId;
  }

  /**
   * 加载世界场景管理快照。
   * - World 不存在 → NotFound
   * - 加载失败保留上一份成功快照,仅切换为 Error 状态
   */
  async loadSnapshot(worldId: string): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'loadSnapshot skipped: disposed vmInstance=' + this.instanceShortId);
      return;
    }
    this.expectedWorldId = worldId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;
    const targetWorldId: string = worldId;

    this.state = WorldSceneManageLoadState.Loading;
    this.errorMessage = '';

    try {
      const world: World | null = await this.worldRepo.getById(targetWorldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.state = WorldSceneManageLoadState.NotFound;
        return;
      }

      const locations: WorldLocation[] = await this.safeListLocations(targetWorldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      const allScenes: WorldScene[] = await this.safeListScenes(targetWorldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 构建每个地点的场景视图
      const locationScenes: LocationSceneUiModel[] = new Array<LocationSceneUiModel>(locations.length);
      for (let i = 0; i < locations.length; i++) {
        const loc: WorldLocation = locations[i];
        let activeScene: WorldScene | null = null;
        let endedCount: number = 0;
        for (let j = 0; j < allScenes.length; j++) {
          const sc: WorldScene = allScenes[j];
          if (sc.locationId === loc.id) {
            if (sc.status === WorldSceneStatus.Active) {
              activeScene = sc;
            } else if (sc.status === WorldSceneStatus.Ended) {
              endedCount = endedCount + 1;
            }
          }
        }
        locationScenes[i] = {
          locationId: loc.id,
          locationName: loc.name,
          locationStatus: loc.status as WorldLocationStatus,
          activeScene: activeScene,
          endedSceneCount: endedCount
        };
      }

      const uiModel: WorldSceneManageUiModel = {
        worldId: world.id,
        worldName: world.name,
        worldStatus: world.status as WorldStatus,
        locations: locationScenes
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.detail = uiModel;
      this.state = WorldSceneManageLoadState.Ready;
      Logger.info(LOG_TAG, 'loadSnapshot done: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', state=ready, locationCount=' + locationScenes.length.toString()
        + ', worldShortId=' + this.shortId(targetWorldId));
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(targetWorldId));
      this.errorMessage = '场景数据加载失败,请重试';
      this.state = WorldSceneManageLoadState.Error;
    }
  }

  /**
   * 开始场景。成功后递增世界详情刷新令牌,触发世界详情页刷新。
   * 防重复:isStarting + operationId。
   */
  async startScene(locationId: string): Promise<StartSceneResult> {
    if (this.isStarting) {
      Logger.warn(LOG_TAG, 'startScene skipped: isStarting');
      return { success: false, errorMessage: '正在处理,请稍候' } as StartSceneResult;
    }
    if (this.expectedWorldId.length === 0) {
      return { success: false, errorMessage: '世界未加载' } as StartSceneResult;
    }
    this.isStarting = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      await this.sceneService.startScene(this.expectedWorldId, locationId);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as StartSceneResult;
      }
      // 递增刷新令牌,通知世界详情页和本页刷新
      this.bumpRefreshToken();
      // 重新加载本页快照
      await this.loadSnapshot(this.expectedWorldId);
      return { success: true, errorMessage: '' } as StartSceneResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期' } as StartSceneResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'startScene failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(this.expectedWorldId));
      return { success: false, errorMessage: msg } as StartSceneResult;
    } finally {
      if (opId === this.operationId) {
        this.isStarting = false;
      }
    }
  }

  dispose(): void {
    this.disposed = true;
    Logger.info(LOG_TAG, 'dispose: vmInstance=' + this.instanceShortId);
  }

  // ===== 私有辅助 =====

  private async safeListLocations(worldId: string): Promise<WorldLocation[]> {
    try {
      return await this.locationRepo.listByWorld(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorld(locations) failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(worldId));
      return [];
    }
  }

  private async safeListScenes(worldId: string): Promise<WorldScene[]> {
    try {
      return await this.sceneRepo.listByWorld(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorld(scenes) failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(worldId));
      return [];
    }
  }

  /** 递增世界详情页刷新令牌,通知世界详情页刷新场景状态 */
  private bumpRefreshToken(): void {
    const current: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, current + 1);
  }

  private resolveErrorMessage(e: Object): string {
    // 先尝试 WorldSceneError,再尝试 WorldStateError,最后兜底
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
