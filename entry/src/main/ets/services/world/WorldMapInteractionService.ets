/**
 * WorldMapInteractionService 地图交互业务服务(W1D)
 *
 * 职责:
 * - 加载地图快照(world + locations + edges + placements + characters)
 * - 保存地点放置(单次数据库写入,失败不静默)
 * - 跨世界放置验证(world exists, location exists, location.worldId==worldId, placement.worldId==worldId)
 *
 * 不依赖 ModelService / Provider / PromptBuilder / Runtime。
 */

import { DbHelper } from '../../database/DbHelper';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../repositories/world/WorldLocationEdgeRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldLocationMapPlacementRepository } from '../../repositories/world/WorldLocationMapPlacementRepository';
import { CharacterService } from '../CharacterService';
import { WorldLocationMapPlacement, createWorldLocationMapPlacementRecord, WORLD_MAP_PLACEMENT_ID_PREFIX } from '../../models/world/WorldLocationMapPlacement';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldLocationEdge } from '../../models/world/WorldLocationEdge';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { Character } from '../../models/Character';
import { DatabaseError } from '../../models/DatabaseError';
import { Logger } from '../../utils/Logger';
import {
  WorldDetailUiModel,
  WorldSummaryUiModel,
  WorldLocationUiModel,
  WorldEdgeUiModel,
  WorldCharacterInstanceUiModel,
  WorldDetailLoadState
} from '../../viewmodels/world/WorldUiModels';

import { MapInteractionPort } from '../../viewmodels/world/WorldImmersiveMapViewModel';

const LOG_TAG: string = 'WorldMapInteractionService';

export interface MapSnapshotResult {
  readonly world: World;
  readonly locations: WorldLocation[];
  readonly edges: WorldLocationEdge[];
  readonly instances: WorldCharacterInstance[];
  readonly placements: WorldLocationMapPlacement[];
  readonly characterMap: Map<string, Character | null>;
}

export interface SavePlacementResult {
  readonly success: boolean;
  readonly placement: WorldLocationMapPlacement | null;
  readonly errorMessage: string;
}

export class WorldMapInteractionService implements MapInteractionPort {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly edgeRepo: WorldLocationEdgeRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly placementRepo: WorldLocationMapPlacementRepository;
  private readonly characterService: CharacterService;
  private readonly dbHelper: DbHelper;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    edgeRepo: WorldLocationEdgeRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    placementRepo: WorldLocationMapPlacementRepository,
    characterService: CharacterService,
    dbHelper: DbHelper
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.edgeRepo = edgeRepo;
    this.instanceRepo = instanceRepo;
    this.placementRepo = placementRepo;
    this.characterService = characterService;
    this.dbHelper = dbHelper;
  }

  async loadMapSnapshot(worldId: string): Promise<MapSnapshotResult> {
    const world: World | null = await this.worldRepo.getById(worldId);
    if (world === null) {
      throw DatabaseError.notFound('WorldMapInteractionService.loadMapSnapshot: world not found');
    }
    const locations: WorldLocation[] = await this.safeListLocations(worldId);
    const edges: WorldLocationEdge[] = await this.safeListEdges(worldId);
    const instances: WorldCharacterInstance[] = await this.safeListInstances(worldId);
    const placements: WorldLocationMapPlacement[] = await this.safeListPlacements(worldId);
    const characterMap: Map<string, Character | null> = await this.buildCharacterMap(instances);
    return {
      world: world,
      locations: locations,
      edges: edges,
      instances: instances,
      placements: placements,
      characterMap: characterMap
    };
  }

  async saveLocationPlacement(
    worldId: string,
    locationId: string,
    positionX: number,
    positionY: number,
    positionZ: number
  ): Promise<SavePlacementResult> {
    try {
      const world: World | null = await this.worldRepo.getById(worldId);
      if (world === null) {
        return { success: false, placement: null, errorMessage: '世界不存在' };
      }
      const location: WorldLocation | null = await this.locationRepo.getById(locationId);
      if (location === null) {
        return { success: false, placement: null, errorMessage: '地点不存在' };
      }
      if (location.worldId !== worldId) {
        return { success: false, placement: null, errorMessage: '地点不属于该世界' };
      }
      const existing: WorldLocationMapPlacement | null =
        await this.placementRepo.getByWorldAndLocation(worldId, locationId);
      let placement: WorldLocationMapPlacement;
      if (existing !== null) {
        placement = {
          id: existing.id,
          worldId: worldId,
          locationId: locationId,
          positionX: positionX,
          positionY: positionY,
          positionZ: positionZ,
          rotationX: existing.rotationX,
          rotationY: existing.rotationY,
          rotationZ: existing.rotationZ,
          scale: existing.scale,
          createdAt: existing.createdAt,
          updatedAt: Date.now()
        };
      } else {
        placement = createWorldLocationMapPlacementRecord({
          id: WORLD_MAP_PLACEMENT_ID_PREFIX + Date.now().toString() + '-' + locationId.substring(locationId.length - 8),
          worldId: worldId,
          locationId: locationId,
          positionX: positionX,
          positionY: positionY,
          positionZ: positionZ
        });
      }
      await this.dbHelper.runInTransaction(async (store): Promise<void> => {
        await this.placementRepo.upsertWithStore(store, placement);
      }, 'world_map_placement_upsert');
      Logger.info(LOG_TAG, 'saveLocationPlacement: ok, locShortId=' + this.shortId(locationId));
      return { success: true, placement: placement, errorMessage: '' };
    } catch (e) {
      const msg: string = this.safeErrorCategory(e);
      Logger.error(LOG_TAG, 'saveLocationPlacement failed: ' + msg);
      return { success: false, placement: null, errorMessage: '保存失败,请重试' };
    }
  }

  private async safeListLocations(worldId: string): Promise<WorldLocation[]> {
    try {
      return await this.locationRepo.listByWorld(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorld(locations) failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async safeListEdges(worldId: string): Promise<WorldLocationEdge[]> {
    try {
      return await this.edgeRepo.listByWorld(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorld(edges) failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async safeListInstances(worldId: string): Promise<WorldCharacterInstance[]> {
    try {
      return await this.instanceRepo.listByWorld(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorld(instances) failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async safeListPlacements(worldId: string): Promise<WorldLocationMapPlacement[]> {
    try {
      return await this.placementRepo.listByWorldId(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listByWorldId(placements) failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async buildCharacterMap(instances: WorldCharacterInstance[]): Promise<Map<string, Character | null>> {
    const characterMap: Map<string, Character | null> = new Map<string, Character | null>();
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < instances.length; i++) {
      const cid: string = instances[i].characterId;
      if (cid.length > 0 && !seen.has(cid)) {
        seen.add(cid);
        try {
          const c: Character | null = await this.characterService.getById(cid);
          characterMap.set(cid, c);
        } catch (e) {
          characterMap.set(cid, null);
        }
      }
    }
    return characterMap;
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
