/**
 * WorldSceneManageViewModel 历史会话页 ViewModel(W-UI-1C 重构)
 *
 * 职责:
 * - 根据 worldId 加载世界 + 全部场景(扁平列表,非按地点分组)
 * - 每个场景加载:地点名称、状态、开始/结束时间、消息数量、参与角色数量
 * - 搜索(按场景名称或地点名称)
 * - 筛选(全部/活动中/已结束)
 * - 开始场景(调用 WorldSceneService.startScene)
 * - 基于 Ended Scene 创建新场景(不修改旧 Scene,不复制旧消息)
 *
 * 依赖方向:Page → ViewModel → Repository(只读) / WorldSceneService(写入)
 */

import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldSceneService } from '../../services/world/WorldSceneService';
import { Logger } from '../../utils/Logger';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import { DatabaseError } from '../../models/DatabaseError';
import { mapWorldSceneErrorToMessage } from './WorldSceneErrorMapper';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';
import {
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from './WorldUiModels';

const LOG_TAG: string = 'WorldSceneManageViewModel';

export enum WorldSceneManageLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

/** 历史会话卡片 UI 模型 */
export interface HistorySceneCardUiModel {
  readonly sceneId: string;
  readonly worldId: string;
  readonly locationId: string;
  readonly locationName: string;
  readonly sceneStatus: WorldSceneStatus;
  readonly startedAt: number;
  readonly endedAt: number;
  readonly messageCount: number;
  readonly participantCount: number;
  readonly participantAvatars: string[];
  readonly participantFallbackNames: string[];
  readonly lastMessageTime: number;
  readonly sceneName: string;
}

/** 历史会话页 UI 模型 */
export interface WorldSceneManageUiModel {
  readonly worldId: string;
  readonly worldName: string;
  readonly worldStatus: WorldStatus;
  readonly scenes: HistorySceneCardUiModel[];
}

export interface StartSceneResult {
  readonly success: boolean;
  readonly errorMessage: string;
  readonly sceneId: string;
}

export class WorldSceneManageViewModel {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly sceneService: WorldSceneService;

  state: WorldSceneManageLoadState = WorldSceneManageLoadState.Loading;
  errorMessage: string = '';
  detail: WorldSceneManageUiModel | null = null;

  isStarting: boolean = false;

  private expectedWorldId: string = '';
  private loadOperationId: number = 0;
  private operationId: number = 0;
  private disposed: boolean = false;
  readonly instanceShortId: string;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    sceneRepo: WorldSceneRepository,
    messageRepo: WorldSceneMessageRepository,
    sceneService: WorldSceneService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.sceneRepo = sceneRepo;
    this.messageRepo = messageRepo;
    this.sceneService = sceneService;
    this.instanceShortId = WorldSceneManageViewModel.generateShortId();
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

  setWorldId(worldId: string): void {
    if (this.expectedWorldId !== worldId) {
      this.expectedWorldId = worldId;
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  expectedWorldIdOfPage(): string {
    return this.expectedWorldId;
  }

  async loadSnapshot(worldId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.expectedWorldId = worldId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;

    this.state = WorldSceneManageLoadState.Loading;
    this.errorMessage = '';

    try {
      const world: World | null = await this.worldRepo.getById(worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.state = WorldSceneManageLoadState.NotFound;
        return;
      }

      const locations: WorldLocation[] = await this.safeListLocations(worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const locationMap: Map<string, WorldLocation> = new Map<string, WorldLocation>();
      for (let i: number = 0; i < locations.length; i++) {
        locationMap.set(locations[i].id, locations[i]);
      }

      const scenes: WorldScene[] = await this.sceneRepo.listByWorld(worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 按开始时间降序排列(最新在前)
      const sortedScenes: WorldScene[] = scenes.slice().sort(
        (a: WorldScene, b: WorldScene): number => b.startedAt - a.startedAt
      );

      const sceneCards: HistorySceneCardUiModel[] = new Array<HistorySceneCardUiModel>(sortedScenes.length);
      for (let i: number = 0; i < sortedScenes.length; i++) {
        if (operationId !== this.loadOperationId || this.disposed) {
          return;
        }
        const sc: WorldScene = sortedScenes[i];
        const loc: WorldLocation | undefined = locationMap.get(sc.locationId);
        const locName: string = loc !== undefined ? loc.name : '(地点已删除)';

        let messageCount: number = 0;
        let lastMessageTime: number = 0;
        try {
          const msgs = await this.messageRepo.listByScene(sc.id);
          if (operationId !== this.loadOperationId || this.disposed) {
            return;
          }
          messageCount = msgs.length;
          if (msgs.length > 0) {
            lastMessageTime = msgs[msgs.length - 1].createdAt;
          }
        } catch (e) {
          Logger.warn(LOG_TAG, 'listByScene failed: ' + this.safeErrorCategory(e));
        }

        sceneCards[i] = {
          sceneId: sc.id,
          worldId: sc.worldId,
          locationId: sc.locationId,
          locationName: locName,
          sceneStatus: sc.status as WorldSceneStatus,
          startedAt: sc.startedAt,
          endedAt: sc.endedAt !== undefined ? sc.endedAt : 0,
          messageCount: messageCount,
          participantCount: 0,
          participantAvatars: [],
          participantFallbackNames: [],
          lastMessageTime: lastMessageTime,
          sceneName: locName + ' · 会话'
        };
      }

      const uiModel: WorldSceneManageUiModel = {
        worldId: world.id,
        worldName: world.name,
        worldStatus: world.status as WorldStatus,
        scenes: sceneCards
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.detail = uiModel;
      this.state = WorldSceneManageLoadState.Ready;
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: ' + this.safeErrorCategory(e));
      this.errorMessage = '历史会话数据加载失败';
      this.state = WorldSceneManageLoadState.Error;
    }
  }

  async startScene(locationId: string): Promise<StartSceneResult> {
    if (this.isStarting) {
      return { success: false, errorMessage: '正在处理,请稍候', sceneId: '' } as StartSceneResult;
    }
    if (this.expectedWorldId.length === 0) {
      return { success: false, errorMessage: '世界未加载', sceneId: '' } as StartSceneResult;
    }
    this.isStarting = true;
    this.operationId = this.operationId + 1;
    const opId: number = this.operationId;
    try {
      const scene: WorldScene = await this.sceneService.startScene(this.expectedWorldId, locationId);
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期', sceneId: '' } as StartSceneResult;
      }
      this.bumpRefreshToken();
      await this.loadSnapshot(this.expectedWorldId);
      return { success: true, errorMessage: '', sceneId: scene.id } as StartSceneResult;
    } catch (e) {
      if (opId !== this.operationId || this.disposed) {
        return { success: false, errorMessage: '操作已过期', sceneId: '' } as StartSceneResult;
      }
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'startScene failed: ' + this.safeErrorCategory(e));
      return { success: false, errorMessage: msg, sceneId: '' } as StartSceneResult;
    } finally {
      if (opId === this.operationId) {
        this.isStarting = false;
      }
    }
  }

  dispose(): void {
    this.disposed = true;
  }

  private async safeListLocations(worldId: string): Promise<WorldLocation[]> {
    try {
      return await this.locationRepo.listByWorld(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorld(locations) failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private bumpRefreshToken(): void {
    const current: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, current + 1);
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