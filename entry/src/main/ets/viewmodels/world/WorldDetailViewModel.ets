/**
 * WorldDetailViewModel 世界详情页 ViewModel(W-UI-1)
 *
 * 职责:
 * - 根据 worldId 一次性加载 World / Locations / Edges / CharacterInstances / 最近 Events
 * - 批量解析 Character(CharacterService.getById,角色卡缺失安全降级)
 * - 批量解析当前位置名称(地点缺失安全降级)
 * - 检测异常边(端点缺失 / 自连接 / worldId 不一致)
 * - 映射详情 UI 状态 WorldDetailUiModel
 * - 处理 World 不存在 / 角色卡缺失 / 地点缺失 / 空数据 / 加载错误
 * - 处理页面快速切换(expectedWorldId + loadOperationId)和销毁(disposed)
 *
 * 依赖方向:
 * Page → ViewModel → Repository / CharacterService(只读)
 *
 * 不调用 WorldStateService 的写方法。
 * 不在 ArkUI Builder 中查询数据库。
 */

import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../repositories/world/WorldLocationEdgeRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldEventRepository } from '../../repositories/world/WorldEventRepository';
import { CharacterService } from '../../services/CharacterService';
import { Logger } from '../../utils/Logger';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldLocationEdge } from '../../models/world/WorldLocationEdge';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldEvent } from '../../models/world/WorldEvent';
import { Character } from '../../models/Character';
import { DatabaseError } from '../../models/DatabaseError';
import {
  WorldDetailUiModel,
  WorldSummaryUiModel,
  WorldLocationUiModel,
  WorldEdgeUiModel,
  WorldCharacterInstanceUiModel,
  WorldEventUiModel,
  WorldDetailLoadState,
  localizeWorldEventType
} from './WorldUiModels';

const LOG_TAG: string = 'WorldDetailViewModel';

/** 最近事件上限(W-UI-1 规范:最近 20 条) */
const MAX_RECENT_EVENTS: number = 20;

export class WorldDetailViewModel {
  /** 世界仓储(只读) */
  private readonly worldRepository: WorldRepository;
  /** 地点仓储(只读) */
  private readonly locationRepository: WorldLocationRepository;
  /** 边仓储(只读) */
  private readonly edgeRepository: WorldLocationEdgeRepository;
  /** 角色实例仓储(只读) */
  private readonly characterInstanceRepository: WorldCharacterInstanceRepository;
  /** 事件仓储(只读) */
  private readonly eventRepository: WorldEventRepository;
  /** 角色服务(只读,用于 getById 解析角色卡) */
  private readonly characterService: CharacterService;

  /** 当前加载状态 */
  state: WorldDetailLoadState = WorldDetailLoadState.Loading;
  /** 用户可见的安全错误消息(空字符串表示无错误) */
  errorMessage: string = '';
  /** 世界详情 UI 模型(Ready 时非空) */
  detail: WorldDetailUiModel | null = null;

  /** 当前页面绑定的 worldId(由 setWorldId 写入,防止快速切换时旧请求覆盖) */
  private expectedWorldId: string = '';
  /** 当前加载操作 ID(每次 loadSnapshot 自增,拒绝旧请求覆盖新请求) */
  private loadOperationId: number = 0;
  /** 页面是否已销毁 */
  private disposed: boolean = false;

  constructor(
    worldRepository: WorldRepository,
    locationRepository: WorldLocationRepository,
    edgeRepository: WorldLocationEdgeRepository,
    characterInstanceRepository: WorldCharacterInstanceRepository,
    eventRepository: WorldEventRepository,
    characterService: CharacterService
  ) {
    this.worldRepository = worldRepository;
    this.locationRepository = locationRepository;
    this.edgeRepository = edgeRepository;
    this.characterInstanceRepository = characterInstanceRepository;
    this.eventRepository = eventRepository;
    this.characterService = characterService;
  }

  /**
   * 设置当前页面绑定的 worldId。
   * 切换世界时调用,使进行中的旧加载结果被丢弃。
   */
  setWorldId(worldId: string): void {
    if (this.expectedWorldId !== worldId) {
      this.expectedWorldId = worldId;
      // 切换世界时使当前进行中的加载结果失效
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  /**
   * 重新加载世界详情快照。
   * - 幂等:可重复调用
   * - 使用 expectedWorldId + loadOperationId 拒绝旧请求覆盖新请求
   * - 销毁后不再更新状态
   *
   * @param worldId 要加载的世界 ID(必须与 expectedWorldId 一致才接受结果)
   */
  async loadSnapshot(worldId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    // 更新 expectedWorldId 并自增 operationId
    this.expectedWorldId = worldId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;
    const targetWorldId: string = worldId;

    this.state = WorldDetailLoadState.Loading;
    this.errorMessage = '';
    this.detail = null;

    try {
      // 1. 加载 World(不存在 → NotFound)
      const world: World | null = await this.worldRepository.getById(targetWorldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.state = WorldDetailLoadState.NotFound;
        return;
      }

      // 2. 并行加载 Locations / Edges / CharacterInstances / 最近 Events
      //    各 Repository 独立查询,失败时该部分降级为空数组,不影响整体加载
      const locationsResult: WorldLocation[] = await this.safeListLocations(targetWorldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const edgesResult: WorldLocationEdge[] = await this.safeListEdges(targetWorldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const instancesResult: WorldCharacterInstance[] = await this.safeListInstances(targetWorldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const eventsResult: WorldEvent[] = await this.safeListRecentEvents(targetWorldId, MAX_RECENT_EVENTS);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 3. 构建 locationId → WorldLocation 映射(用于边端点校验和位置名称解析)
      const locationMap: Map<string, WorldLocation> = new Map<string, WorldLocation>();
      for (let i: number = 0; i < locationsResult.length; i++) {
        locationMap.set(locationsResult[i].id, locationsResult[i]);
      }

      // 4. 批量解析角色卡(去重 characterId,逐个 getById)
      //    角色卡缺失时 characterCardMissing = true,displayName 回退到 displayNameSnapshot
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

      // 5. 映射 UI 模型
      const summary: WorldSummaryUiModel = {
        id: world.id,
        name: world.name,
        description: world.description,
        status: world.status as WorldStatus,
        locationCount: locationsResult.length,
        characterCount: instancesResult.length,
        updatedAt: world.updatedAt
      };

      const locationUiModels: WorldLocationUiModel[] = new Array<WorldLocationUiModel>(locationsResult.length);
      for (let i: number = 0; i < locationsResult.length; i++) {
        const loc: WorldLocation = locationsResult[i];
        locationUiModels[i] = {
          id: loc.id,
          name: loc.name,
          description: loc.description,
          status: loc.status as WorldLocationStatus,
          createdAt: loc.createdAt
        };
      }

      const locationUiMap: Map<string, WorldLocationUiModel> = new Map<string, WorldLocationUiModel>();
      for (let i: number = 0; i < locationUiModels.length; i++) {
        locationUiMap.set(locationUiModels[i].id, locationUiModels[i]);
      }

      // 6. 映射边 UI 模型,并统计异常边
      let anomalousEdgeCount: number = 0;
      const edgeUiModels: WorldEdgeUiModel[] = new Array<WorldEdgeUiModel>(edgesResult.length);
      for (let i: number = 0; i < edgesResult.length; i++) {
        const edge: WorldLocationEdge = edgesResult[i];
        const fromLoc: WorldLocationUiModel | undefined = locationUiMap.get(edge.fromLocationId);
        const toLoc: WorldLocationUiModel | undefined = locationUiMap.get(edge.toLocationId);
        const fromMissing: boolean = fromLoc === undefined;
        const toMissing: boolean = toLoc === undefined;
        const isSelfLoop: boolean = edge.fromLocationId === edge.toLocationId;
        const worldMismatch: boolean = edge.worldId !== targetWorldId;
        const isAnomalous: boolean = fromMissing || toMissing || isSelfLoop || worldMismatch;
        if (isAnomalous) {
          anomalousEdgeCount = anomalousEdgeCount + 1;
          Logger.warn(LOG_TAG, 'anomalous edge detected: edgeShortId=' + this.shortId(edge.id)
            + ', fromMissing=' + String(fromMissing)
            + ', toMissing=' + String(toMissing)
            + ', selfLoop=' + String(isSelfLoop)
            + ', worldMismatch=' + String(worldMismatch));
        }
        edgeUiModels[i] = {
          id: edge.id,
          fromLocationId: edge.fromLocationId,
          toLocationId: edge.toLocationId,
          fromLocationName: fromLoc !== undefined ? fromLoc.name : '',
          toLocationName: toLoc !== undefined ? toLoc.name : '',
          fromLocationMissing: fromMissing,
          toLocationMissing: toMissing,
          directionLabel: edge.directionLabel,
          travelDescription: edge.travelDescription,
          isBidirectional: edge.isBidirectional,
          isEnabled: edge.isEnabled,
          isAnomalous: isAnomalous
        };
      }

      // 7. 映射角色实例 UI 模型
      const characterUiModels: WorldCharacterInstanceUiModel[] =
        new Array<WorldCharacterInstanceUiModel>(instancesResult.length);
      for (let i: number = 0; i < instancesResult.length; i++) {
        const inst: WorldCharacterInstance = instancesResult[i];
        const character: Character | null | undefined = characterMap.get(inst.characterId);
        const characterCardMissing: boolean = character === null || character === undefined;
        // 名称规则:角色卡存在 → Character.name;角色卡缺失 → displayNameSnapshot
        const displayName: string = !characterCardMissing && character !== null && character !== undefined
          ? character.name
          : inst.displayNameSnapshot;
        const avatarUri: string = !characterCardMissing && character !== null && character !== undefined
          ? character.avatarUri
          : '';
        // 当前位置解析
        let currentLocationName: string = '';
        let locationMissing: boolean = false;
        if (inst.currentLocationId === undefined || inst.currentLocationId.length === 0) {
          // 未放置
          currentLocationName = '';
          locationMissing = false;
        } else {
          const loc: WorldLocationUiModel | undefined = locationUiMap.get(inst.currentLocationId);
          if (loc === undefined) {
            // locationId 指向不存在地点
            currentLocationName = '';
            locationMissing = true;
          } else {
            currentLocationName = loc.name;
            locationMissing = false;
          }
        }
        characterUiModels[i] = {
          id: inst.id,
          characterId: inst.characterId,
          displayName: displayName,
          isActive: inst.isActive,
          currentLocationId: inst.currentLocationId !== undefined ? inst.currentLocationId : '',
          currentLocationName: currentLocationName,
          locationMissing: locationMissing,
          characterCardMissing: characterCardMissing,
          avatarUri: avatarUri,
          fallbackName: displayName.length > 0 ? displayName.charAt(0) : '?',
          createdAt: inst.createdAt
        };
      }

      // 8. 映射最近事件 UI 模型(类型本地化,未知类型安全显示"未知世界事件")
      const eventUiModels: WorldEventUiModel[] = new Array<WorldEventUiModel>(eventsResult.length);
      for (let i: number = 0; i < eventsResult.length; i++) {
        const ev: WorldEvent = eventsResult[i];
        const localized: string = localizeWorldEventType(ev.eventType);
        if (localized === '未知世界事件') {
          Logger.warn(LOG_TAG, 'unknown event type: type=' + ev.eventType
            + ', eventShortId=' + this.shortId(ev.id));
        }
        eventUiModels[i] = {
          id: ev.id,
          eventType: ev.eventType,
          localizedType: localized,
          summary: ev.summary,
          occurredAt: ev.occurredAt
        };
      }

      // 9. 组装详情 UI 模型
      const detailModel: WorldDetailUiModel = {
        world: summary,
        edgeCount: edgeUiModels.length,
        eventCount: eventsResult.length,
        anomalousEdgeCount: anomalousEdgeCount,
        locations: locationUiModels,
        edges: edgeUiModels,
        characters: characterUiModels,
        recentEvents: eventUiModels
      };

      // 10. 二次校验:旧请求结果到达时直接丢弃
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.detail = detailModel;
      this.state = WorldDetailLoadState.Ready;
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(targetWorldId));
      this.detail = null;
      this.errorMessage = '世界数据加载失败,请重试';
      this.state = WorldDetailLoadState.Error;
    }
  }

  /**
   * 标记页面已销毁,后续 loadSnapshot / 迟到结果均不再更新状态。
   */
  dispose(): void {
    this.disposed = true;
  }

  /**
   * 安全加载地点列表(失败返回空数组,不阻塞整体加载)。
   */
  private async safeListLocations(worldId: string): Promise<WorldLocation[]> {
    try {
      return await this.locationRepository.listByWorld(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorld(locations) failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(worldId));
      return [];
    }
  }

  /**
   * 安全加载边列表(失败返回空数组,不阻塞整体加载)。
   */
  private async safeListEdges(worldId: string): Promise<WorldLocationEdge[]> {
    try {
      return await this.edgeRepository.listByWorld(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorld(edges) failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(worldId));
      return [];
    }
  }

  /**
   * 安全加载角色实例列表(失败返回空数组,不阻塞整体加载)。
   */
  private async safeListInstances(worldId: string): Promise<WorldCharacterInstance[]> {
    try {
      return await this.characterInstanceRepository.listByWorld(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorld(instances) failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(worldId));
      return [];
    }
  }

  /**
   * 安全加载最近事件(失败返回空数组,不阻塞整体加载)。
   */
  private async safeListRecentEvents(worldId: string, limit: number): Promise<WorldEvent[]> {
    try {
      return await this.eventRepository.listRecentByWorld(worldId, limit);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listRecentByWorld failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(worldId));
      return [];
    }
  }

  /**
   * 安全的错误分类(不输出 SQL / 完整错误信息)。
   */
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

  /**
   * 截断短 ID(取最后 8 字符)用于日志定位。
   */
  private shortId(id: string): string {
    if (id.length <= 8) {
      return id;
    }
    return id.substring(id.length - 8);
  }
}
