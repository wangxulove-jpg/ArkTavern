/**
 * WorldStateService 世界模式状态业务服务
 *
 * W-DATA-1B 引入。当前世界基础数据的唯一正式业务写入口。
 *
 * 职责:
 * - 世界、地点、连接、角色实例的事务业务规则校验与写入
 * - 状态变更与 WorldEvent 在同一数据库事务中完成
 * - 地点 canonicalKey 规范化与精确去重(不做语义模糊合并)
 * - 连接边冲突校验(精确重复 / 双向冲突 / 反向单向共存)
 * - 角色实例加入、移除、启用、停用、放置、移动、强制移动
 * - 世界硬删除的显式事务级联(不依赖 SQLite 外键)
 * - 地点删除保护(有角色时禁止删除)与归档保护(有 active 角色时禁止归档)
 *
 * 不负责(留待后续阶段):
 * - 世界 UI / 场景 / 消息 / Prompt / 运行时 / 关系 / 记忆 / AI 候选地点
 *
 * 事务规则:
 * - 所有跨表操作使用 DbHelper.runInTransaction
 * - 事务内只调用 Repository 的 *WithStore 方法,不调用普通方法(避免嵌套事务)
 * - 状态写入与事件插入在同一事务;任一失败整体回滚
 * - 不在 Repository 中创建事件,事件编排只由本 Service 负责
 *
 * 依赖方向:
 * - WorldStateService → 5 个世界 Repository + CharacterService(只读 getById) + DbHelper
 * - 不依赖 Page / ViewModel / GroupChatRuntimeService / ModelService / Provider
 *
 * 日志安全:
 * - 不记录完整 World/Character/Location ID、描述、payloadJson、SQL
 * - 仅记录操作类型、事件类型、数量、状态、截断短 ID(前 8 字符)、错误种类
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldLocationEdgeRepository } from '../../repositories/world/WorldLocationEdgeRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldEventRepository } from '../../repositories/world/WorldEventRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldCharacterMemoryService } from './WorldCharacterMemoryService';
import {
  World,
  WorldStatus,
  createWorldRecord,
  WORLD_ID_PREFIX
} from '../../models/world/World';
import {
  WorldLocation,
  WorldLocationStatus,
  buildCanonicalKey,
  createWorldLocationRecord,
  WORLD_LOCATION_ID_PREFIX
} from '../../models/world/WorldLocation';
import {
  WorldLocationEdge,
  createWorldLocationEdgeRecord,
  WORLD_EDGE_ID_PREFIX
} from '../../models/world/WorldLocationEdge';
import {
  WorldCharacterInstance,
  createWorldCharacterInstanceRecord,
  WORLD_CHARACTER_ID_PREFIX
} from '../../models/world/WorldCharacterInstance';
import {
  WorldEvent,
  WorldEventType,
  createWorldEventRecord,
  WORLD_EVENT_ID_PREFIX
} from '../../models/world/WorldEvent';
import {
  WorldScene,
  WorldSceneStatus
} from '../../models/world/WorldScene';
import { WorldStateError } from '../../models/world/WorldStateError';
import { CharacterService } from '../CharacterService';
import { Character } from '../../models/Character';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';

// 输入长度保守上限(与项目现有 Character 字段限制对齐)
const WORLD_NAME_MAX: number = 100;
const WORLD_DESCRIPTION_MAX: number = 5000;
const LOCATION_NAME_MAX: number = 100;
const LOCATION_DESCRIPTION_MAX: number = 5000;
const DIRECTION_LABEL_MAX: number = 100;
const TRAVEL_DESCRIPTION_MAX: number = 2000;
const EVENT_SUMMARY_MAX: number = 500;
const PAYLOAD_JSON_MAX: number = 8000;

/** 角色实例更新参数(updateEdge 使用) */
export interface WorldLocationEdgeUpdates {
  readonly directionLabel?: string;
  readonly travelDescription?: string;
  readonly isBidirectional?: boolean;
  readonly isEnabled?: boolean;
}

/** WorldEvent 构造参数(由 Service 在事务内调用)。 */
interface BuildEventOptions {
  readonly worldId: string;
  readonly eventType: WorldEventType;
  readonly sourceCharacterInstanceId?: string;
  readonly sourceLocationId?: string;
  readonly targetLocationId?: string;
  readonly summary: string;
  readonly payloadJson?: string;
}

export class WorldStateService {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly edgeRepo: WorldLocationEdgeRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly eventRepo: WorldEventRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly sceneMessageRepo: WorldSceneMessageRepository;
  private readonly memoryService: WorldCharacterMemoryService;
  private readonly characterService: CharacterService;
  private readonly dbHelper: DbHelper;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    edgeRepo: WorldLocationEdgeRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    eventRepo: WorldEventRepository,
    sceneRepo: WorldSceneRepository,
    sceneMessageRepo: WorldSceneMessageRepository,
    memoryService: WorldCharacterMemoryService,
    characterService: CharacterService,
    dbHelper: DbHelper
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.edgeRepo = edgeRepo;
    this.instanceRepo = instanceRepo;
    this.eventRepo = eventRepo;
    this.sceneRepo = sceneRepo;
    this.sceneMessageRepo = sceneMessageRepo;
    this.memoryService = memoryService;
    this.characterService = characterService;
    this.dbHelper = dbHelper;
  }

  // ===== 世界 =====

  /**
   * 创建世界。
   * 事务内:校验名称 → 插入 World → 插入 WorldCreated 事件。
   * 不自动创建默认地点,不自动添加角色。
   */
  async createWorld(name: string, description: string): Promise<World> {
    const normalName: string = normalizeText(name);
    if (normalName === '') {
      throw WorldStateError.worldNameEmpty();
    }
    const trimmedDesc: string = normalizeText(description);
    const finalDesc: string = truncate(trimmedDesc, WORLD_DESCRIPTION_MAX);
    const worldId: string = WORLD_ID_PREFIX + generateUuid();
    const now: number = nowMillis();
    const world: World = createWorldRecord({
      id: worldId,
      name: truncate(normalName, WORLD_NAME_MAX),
      description: finalDesc,
      status: WorldStatus.Active,
      createdAt: now,
      updatedAt: now
    });
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        await this.worldRepo.insertWithStore(store, world);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: worldId,
          eventType: WorldEventType.WorldCreated,
          summary: '世界已创建'
        }));
      },
      'world_create'
    );
    return world;
  }

  /**
   * 更新世界名称与描述。
   * 规范化后无变化时不写数据库、不创建事件,直接返回当前 World。
   */
  async updateWorld(worldId: string, name: string, description: string): Promise<World> {
    const normalName: string = normalizeText(name);
    if (normalName === '') {
      throw WorldStateError.worldNameEmpty();
    }
    const finalName: string = truncate(normalName, WORLD_NAME_MAX);
    const finalDesc: string = truncate(normalizeText(description), WORLD_DESCRIPTION_MAX);

    let result: World | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: World | null = await this.worldRepo.getByIdWithStore(store, worldId);
        if (existing === null) {
          throw WorldStateError.worldNotFound();
        }
        if (existing.name === finalName && existing.description === finalDesc) {
          result = existing;
          return;
        }
        const updated: World = createWorldRecord({
          id: existing.id,
          name: finalName,
          description: finalDesc,
          status: existing.status,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.worldRepo.updateWithStore(store, updated);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: worldId,
          eventType: WorldEventType.WorldUpdated,
          summary: '世界已更新'
        }));
        result = updated;
      },
      'world_update'
    );
    if (result === null) {
      throw WorldStateError.internal('事务未产生结果');
    }
    return result;
  }

  /**
   * 归档或重新激活世界。
   * 状态未变化时不写数据库、不创建事件。
   * 归档前检查:没有进行中的 Active Scene。
   * 归档后世界禁止新增或修改其地点、连接、角色实例和移动状态。
   * 重新激活不受此检查影响。
   */
  async setWorldArchived(worldId: string, archived: boolean): Promise<World> {
    const targetStatus: WorldStatus = archived ? WorldStatus.Archived : WorldStatus.Active;
    let result: World | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: World | null = await this.worldRepo.getByIdWithStore(store, worldId);
        if (existing === null) {
          throw WorldStateError.worldNotFound();
        }
        if (existing.status === targetStatus) {
          result = existing;
          return;
        }
        if (archived) {
          // 归档前检查:该 World 任意 Active Scene 都拒绝归档
          const activeScenes: WorldScene[] =
            await this.sceneRepo.listByStatus(existing.id, WorldSceneStatus.Active);
          if (activeScenes.length > 0) {
            throw WorldStateError.worldHasActiveScenes();
          }
        }
        const updated: World = createWorldRecord({
          id: existing.id,
          name: existing.name,
          description: existing.description,
          status: targetStatus,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.worldRepo.updateWithStore(store, updated);
        const eventType: WorldEventType = archived
          ? WorldEventType.WorldArchived : WorldEventType.WorldActivated;
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: worldId,
          eventType: eventType,
          summary: archived ? '世界已归档' : '世界已激活'
        }));
        result = updated;
      },
      'world_archive'
    );
    if (result === null) {
      throw WorldStateError.internal('事务未产生结果');
    }
    return result;
  }

  /**
   * 硬删除世界。在单一事务内显式删除全部 V16 子记录:
   * world_scene_messages → world_scenes → world_events → world_location_edges →
   * world_character_instances → world_locations → worlds。
   * 硬删除后不再保留 WorldDeleted 事件(事件属于被删除世界)。
   * 任一步失败整体回滚。
   * 不依赖 SQLite 外键级联。
   */
  async deleteWorld(worldId: string): Promise<void> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: World | null = await this.worldRepo.getByIdWithStore(store, worldId);
        if (existing === null) {
          throw WorldStateError.worldNotFound();
        }
        // V17: 先删除该 World 的全部世界角色记忆,避免留下孤立记忆。
        await this.memoryService.deleteByWorldWithStore(store, worldId);
        await this.sceneMessageRepo.deleteByWorldWithStore(store, worldId);
        await this.sceneRepo.deleteByWorldWithStore(store, worldId);
        await this.eventRepo.deleteByWorldWithStore(store, worldId);
        await this.edgeRepo.deleteByWorldWithStore(store, worldId);
        await this.instanceRepo.deleteByWorldWithStore(store, worldId);
        await this.locationRepo.deleteByWorldWithStore(store, worldId);
        await this.worldRepo.deleteByIdWithStore(store, worldId);
      },
      'world_delete'
    );
  }

  // ===== 地点 =====

  /**
   * 创建地点。
   * 事务内:World 存在且 Active → 名称非空 → 生成 canonicalKey → 同世界精确去重 → 插入 → LocationCreated 事件。
   * canonicalKey 仅做 trim + 小写 + 连续空白折叠,不做语义模糊合并。
   */
  async createLocation(worldId: string, name: string, description: string): Promise<WorldLocation> {
    const normalName: string = normalizeText(name);
    if (normalName === '') {
      throw WorldStateError.locationNameEmpty();
    }
    const canonicalKey: string = buildCanonicalKey(normalName);
    const finalName: string = truncate(normalName, LOCATION_NAME_MAX);
    const finalDesc: string = truncate(normalizeText(description), LOCATION_DESCRIPTION_MAX);
    const locationId: string = WORLD_LOCATION_ID_PREFIX + generateUuid();
    const now: number = nowMillis();
    const location: WorldLocation = createWorldLocationRecord({
      id: locationId,
      worldId: worldId,
      name: finalName,
      description: finalDesc,
      canonicalKey: canonicalKey,
      status: WorldLocationStatus.Active,
      createdAt: now,
      updatedAt: now
    });
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        await this.assertWorldActiveInTx(store, worldId);
        const dup: WorldLocation | null = await this.locationRepo.findByCanonicalKeyWithStore(
          store, worldId, canonicalKey
        );
        if (dup !== null) {
          throw WorldStateError.duplicateLocation();
        }
        await this.locationRepo.insertWithStore(store, location);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: worldId,
          eventType: WorldEventType.LocationCreated,
          sourceLocationId: locationId,
          summary: '地点已创建'
        }));
      },
      'world_location_create'
    );
    return location;
  }

  /**
   * 更新地点名称与描述。名称变化时重新计算 canonicalKey 并排除自身做唯一性校验。
   * 无变化时不写数据库、不创建事件。
   */
  async updateLocation(locationId: string, name: string, description: string): Promise<WorldLocation> {
    const normalName: string = normalizeText(name);
    if (normalName === '') {
      throw WorldStateError.locationNameEmpty();
    }
    const finalName: string = truncate(normalName, LOCATION_NAME_MAX);
    const finalDesc: string = truncate(normalizeText(description), LOCATION_DESCRIPTION_MAX);
    const newCanonicalKey: string = buildCanonicalKey(finalName);

    let result: WorldLocation | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldLocation | null = await this.locationRepo.getByIdWithStore(store, locationId);
        if (existing === null) {
          throw WorldStateError.locationNotFound();
        }
        await this.assertWorldActiveInTx(store, existing.worldId);
        if (existing.name === finalName && existing.description === finalDesc) {
          result = existing;
          return;
        }
        // canonicalKey 变化时排除自身做唯一性校验
        if (newCanonicalKey !== existing.canonicalKey) {
          const dup: WorldLocation | null = await this.locationRepo.findByCanonicalKeyWithStore(
            store, existing.worldId, newCanonicalKey
          );
          if (dup !== null && dup.id !== locationId) {
            throw WorldStateError.duplicateLocation();
          }
        }
        const updated: WorldLocation = createWorldLocationRecord({
          id: existing.id,
          worldId: existing.worldId,
          name: finalName,
          description: finalDesc,
          canonicalKey: newCanonicalKey,
          status: existing.status,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.locationRepo.updateWithStore(store, updated);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: WorldEventType.LocationUpdated,
          sourceLocationId: locationId,
          summary: '地点已更新'
        }));
        result = updated;
      },
      'world_location_update'
    );
    if (result === null) {
      throw WorldStateError.internal('事务未产生结果');
    }
    return result;
  }

  /**
   * 归档或重新激活地点。
   * 归档前检查:
   * - 没有 active WorldCharacterInstance 当前位于该地点
   * - 该地点没有进行中的 Active Scene(Ended Scene 不阻止归档)
   * 归档后禁止新增以该地点为端点的连接、禁止放置或移动角色到该地点。
   * 状态未变化时不写数据库、不创建事件。
   */
  async setLocationArchived(locationId: string, archived: boolean): Promise<WorldLocation> {
    const targetStatus: WorldLocationStatus = archived
      ? WorldLocationStatus.Archived : WorldLocationStatus.Active;
    let result: WorldLocation | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldLocation | null = await this.locationRepo.getByIdWithStore(store, locationId);
        if (existing === null) {
          throw WorldStateError.locationNotFound();
        }
        await this.assertWorldActiveInTx(store, existing.worldId);
        if (existing.status === targetStatus) {
          result = existing;
          return;
        }
        if (archived) {
          // 归档前检查:没有 active 角色位于该地点
          const instances: WorldCharacterInstance[] = await this.instanceRepo.listByLocationWithStore(
            store, existing.worldId, locationId
          );
          for (let i = 0; i < instances.length; i++) {
            if (instances[i].isActive) {
              throw WorldStateError.locationHasCharacters();
            }
          }
          // 归档前检查:该地点没有 Active Scene(Ended Scene 不阻止归档)
          const activeScene: WorldScene | null =
            await this.sceneRepo.findActiveByWorldAndLocationWithStore(
              store, existing.worldId, locationId
            );
          if (activeScene !== null) {
            throw WorldStateError.locationHasActiveScene();
          }
        }
        const updated: WorldLocation = createWorldLocationRecord({
          id: existing.id,
          worldId: existing.worldId,
          name: existing.name,
          description: existing.description,
          canonicalKey: existing.canonicalKey,
          status: targetStatus,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.locationRepo.updateWithStore(store, updated);
        const eventType: WorldEventType = archived
          ? WorldEventType.LocationArchived : WorldEventType.LocationActivated;
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: eventType,
          sourceLocationId: locationId,
          summary: archived ? '地点已归档' : '地点已激活'
        }));
        result = updated;
      },
      'world_location_archive'
    );
    if (result === null) {
      throw WorldStateError.internal('事务未产生结果');
    }
    return result;
  }

  /**
   * 删除地点。
   * 事务内:确认存在 → 确认没有角色实例位于该地点(含 inactive) →
   * 确认该地点没有场景历史(Active 或 Ended) → 删除关联 Edge →
   * 插入 LocationDeleted 事件 → 删除 Location。
   * 事件保留 sourceLocationId 软引用,即使地点随后删除。
   * 不自动移动角色,不自动清空 currentLocationId。
   * 不自动删除场景历史,也不将场景迁移到其他地点。
   * 有场景历史时拒绝永久删除,用户可将地点归档。
   */
  async deleteLocation(locationId: string): Promise<void> {
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldLocation | null = await this.locationRepo.getByIdWithStore(store, locationId);
        if (existing === null) {
          throw WorldStateError.locationNotFound();
        }
        // 删除保护:任何角色实例位于该地点(含 inactive)都禁止删除
        const count: number = await this.instanceRepo.countByCurrentLocationWithStore(store, locationId);
        if (count > 0) {
          throw WorldStateError.locationHasCharacters();
        }
        // 删除保护:该地点有任何场景历史(Active 或 Ended)都禁止永久删除
        const sceneCount: number = await this.sceneRepo.countByLocationWithStore(store, locationId);
        if (sceneCount > 0) {
          throw WorldStateError.locationHasScenes();
        }
        // 删除关联 Edge(作为起点或终点)
        await this.edgeRepo.deleteByLocationWithStore(store, locationId);
        // 插入 LocationDeleted 事件(保留 sourceLocationId 软引用)
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: WorldEventType.LocationDeleted,
          sourceLocationId: locationId,
          summary: '地点已删除'
        }));
        // 删除地点
        await this.locationRepo.deleteByIdWithStore(store, locationId);
      },
      'world_location_delete'
    );
  }

  // ===== 连接边 =====

  /**
   * 创建连接边。
   * 校验:World Active → 起点终点存在且属于该 World 且 Active → 非自连接 → 无冲突连接。
   * 冲突规则:
   * - 精确重复(from→to,任意双向标志)拒绝
   * - 已有反向双向边(to↔from)拒绝任意新建
   * - 新建双向边时,已有反向边(任意)拒绝
   * - 允许两条相反的单向边(均为 isBidirectional=false)共存
   */
  async createEdge(
    worldId: string,
    fromLocationId: string,
    toLocationId: string,
    directionLabel: string,
    travelDescription: string,
    isBidirectional: boolean
  ): Promise<WorldLocationEdge> {
    if (fromLocationId === toLocationId) {
      throw WorldStateError.edgeSelfConnection();
    }
    const finalDirection: string = truncate(normalizeText(directionLabel), DIRECTION_LABEL_MAX);
    const finalTravel: string = truncate(normalizeText(travelDescription), TRAVEL_DESCRIPTION_MAX);
    const edgeId: string = WORLD_EDGE_ID_PREFIX + generateUuid();
    const now: number = nowMillis();
    const edge: WorldLocationEdge = createWorldLocationEdgeRecord({
      id: edgeId,
      worldId: worldId,
      fromLocationId: fromLocationId,
      toLocationId: toLocationId,
      directionLabel: finalDirection,
      travelDescription: finalTravel,
      isBidirectional: isBidirectional,
      isEnabled: true,
      createdAt: now,
      updatedAt: now
    });
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        await this.assertWorldActiveInTx(store, worldId);
        const from: WorldLocation | null = await this.locationRepo.getByIdWithStore(store, fromLocationId);
        if (from === null) {
          throw WorldStateError.locationNotFound();
        }
        if (from.worldId !== worldId) {
          throw WorldStateError.locationNotInWorld();
        }
        if (from.status !== WorldLocationStatus.Active) {
          throw WorldStateError.locationNotFound();
        }
        const to: WorldLocation | null = await this.locationRepo.getByIdWithStore(store, toLocationId);
        if (to === null) {
          throw WorldStateError.locationNotFound();
        }
        if (to.worldId !== worldId) {
          throw WorldStateError.locationNotInWorld();
        }
        if (to.status !== WorldLocationStatus.Active) {
          throw WorldStateError.locationNotFound();
        }
        await this.assertNoEdgeConflictInTx(store, worldId, fromLocationId, toLocationId, isBidirectional, '');
        await this.edgeRepo.insertWithStore(store, edge);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: worldId,
          eventType: WorldEventType.EdgeCreated,
          sourceLocationId: fromLocationId,
          targetLocationId: toLocationId,
          summary: '连接已创建'
        }));
      },
      'world_edge_create'
    );
    return edge;
  }

  /**
   * 更新连接边的 directionLabel / travelDescription / isBidirectional / isEnabled。
   * 若 isBidirectional 改为 true,重新执行反向冲突检查(排除自身)。
   * 无变化时不创建事件;有变化时插入 EdgeUpdated 事件。
   */
  async updateEdge(edgeId: string, updates: WorldLocationEdgeUpdates): Promise<WorldLocationEdge> {
    let result: WorldLocationEdge | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldLocationEdge | null = await this.edgeRepo.getByIdWithStore(store, edgeId);
        if (existing === null) {
          throw WorldStateError.edgeNotFound();
        }
        await this.assertWorldActiveInTx(store, existing.worldId);
        const newDirection: string = updates.directionLabel !== undefined
          ? truncate(normalizeText(updates.directionLabel), DIRECTION_LABEL_MAX)
          : existing.directionLabel;
        const newTravel: string = updates.travelDescription !== undefined
          ? truncate(normalizeText(updates.travelDescription), TRAVEL_DESCRIPTION_MAX)
          : existing.travelDescription;
        const newBidirectional: boolean = updates.isBidirectional !== undefined
          ? updates.isBidirectional : existing.isBidirectional;
        const newEnabled: boolean = updates.isEnabled !== undefined
          ? updates.isEnabled : existing.isEnabled;

        const changed: boolean = newDirection !== existing.directionLabel
          || newTravel !== existing.travelDescription
          || newBidirectional !== existing.isBidirectional
          || newEnabled !== existing.isEnabled;
        if (!changed) {
          result = existing;
          return;
        }
        // 双向标志变化时重新校验冲突(排除自身)
        if (newBidirectional !== existing.isBidirectional) {
          await this.assertNoEdgeConflictInTx(
            store, existing.worldId, existing.fromLocationId, existing.toLocationId,
            newBidirectional, edgeId
          );
        }
        const updated: WorldLocationEdge = createWorldLocationEdgeRecord({
          id: existing.id,
          worldId: existing.worldId,
          fromLocationId: existing.fromLocationId,
          toLocationId: existing.toLocationId,
          directionLabel: newDirection,
          travelDescription: newTravel,
          isBidirectional: newBidirectional,
          isEnabled: newEnabled,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.edgeRepo.updateWithStore(store, updated);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: WorldEventType.EdgeUpdated,
          sourceLocationId: existing.fromLocationId,
          targetLocationId: existing.toLocationId,
          summary: '连接已更新'
        }));
        result = updated;
      },
      'world_edge_update'
    );
    if (result === null) {
      throw WorldStateError.internal('事务未产生结果');
    }
    return result;
  }

  /**
   * 删除连接边。事务内:确认存在 → 插入 EdgeDeleted 事件 → 删除。
   */
  async deleteEdge(edgeId: string): Promise<void> {
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldLocationEdge | null = await this.edgeRepo.getByIdWithStore(store, edgeId);
        if (existing === null) {
          throw WorldStateError.edgeNotFound();
        }
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: WorldEventType.EdgeDeleted,
          sourceLocationId: existing.fromLocationId,
          targetLocationId: existing.toLocationId,
          summary: '连接已删除'
        }));
        await this.edgeRepo.deleteByIdWithStore(store, edgeId);
      },
      'world_edge_delete'
    );
  }

  // ===== 角色实例 =====

  /**
   * 添加角色到世界。
   * 校验:World Active → Character 存在 → 同世界无该 Character 实例 →
   * (可选)初始地点存在、属于同 World、Active。
   * 创建:displayNameSnapshot = 当前 Character.name,isActive = true,
   * currentLocationId = initialLocationId 或 undefined。
   * 事务内同时插入 CharacterJoined 事件。
   */
  async addCharacterToWorld(
    worldId: string,
    characterId: string,
    initialLocationId?: string
  ): Promise<WorldCharacterInstance> {
    const character: Character | null = await this.characterService.getById(characterId);
    if (character === null) {
      throw WorldStateError.characterNotFound();
    }
    const displayNameSnapshot: string = character.name;
    const instanceId: string = WORLD_CHARACTER_ID_PREFIX + generateUuid();
    const now: number = nowMillis();
    const initialLoc: string | undefined = normalizeOptionalId(initialLocationId);
    const instance: WorldCharacterInstance = createWorldCharacterInstanceRecord({
      id: instanceId,
      worldId: worldId,
      characterId: characterId,
      displayNameSnapshot: displayNameSnapshot,
      currentLocationId: initialLoc,
      isActive: true,
      createdAt: now,
      updatedAt: now
    });
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        await this.assertWorldActiveInTx(store, worldId);
        const existing: WorldCharacterInstance | null =
          await this.instanceRepo.findByWorldAndCharacterWithStore(store, worldId, characterId);
        if (existing !== null) {
          throw WorldStateError.characterAlreadyInWorld();
        }
        if (initialLoc !== undefined) {
          const loc: WorldLocation | null = await this.locationRepo.getByIdWithStore(store, initialLoc);
          if (loc === null) {
            throw WorldStateError.locationNotFound();
          }
          if (loc.worldId !== worldId) {
            throw WorldStateError.locationNotInWorld();
          }
          if (loc.status !== WorldLocationStatus.Active) {
            throw WorldStateError.locationNotFound();
          }
        }
        await this.instanceRepo.insertWithStore(store, instance);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: worldId,
          eventType: WorldEventType.CharacterJoined,
          sourceCharacterInstanceId: instanceId,
          sourceLocationId: initialLoc,
          summary: '角色已加入世界'
        }));
      },
      'world_character_add'
    );
    return instance;
  }

  /**
   * 从世界移除角色实例。
   * V17 后:事务内顺序为 确认存在 → 插入 CharacterRemoved 事件 →
   *   删除该实例全部 world_character_memories → 删除实例。
   * 不删除正式 Character。
   * 所有删除使用同一个 RdbStore,任一步失败整体回滚,不留孤立记忆。
   */
  async removeCharacterFromWorld(instanceId: string): Promise<void> {
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, instanceId);
        if (existing === null) {
          throw WorldStateError.characterInstanceNotFound();
        }
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: WorldEventType.CharacterRemoved,
          sourceCharacterInstanceId: instanceId,
          sourceLocationId: existing.currentLocationId,
          summary: '角色已从世界移除'
        }));
        await this.memoryService.deleteByCharacterInstanceWithStore(store, instanceId);
        await this.instanceRepo.deleteByIdWithStore(store, instanceId);
      },
      'world_character_remove'
    );
  }

  /**
   * 启用或停用角色实例。
   * 停用时保留 currentLocationId,以便未来重新启用后恢复位置。
   * 世界已归档时拒绝修改。状态未变化时不写数据库、不创建事件。
   */
  async setCharacterInstanceActive(instanceId: string, active: boolean): Promise<WorldCharacterInstance> {
    let result: WorldCharacterInstance | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, instanceId);
        if (existing === null) {
          throw WorldStateError.characterInstanceNotFound();
        }
        await this.assertWorldActiveInTx(store, existing.worldId);
        if (existing.isActive === active) {
          result = existing;
          return;
        }
        const updated: WorldCharacterInstance = createWorldCharacterInstanceRecord({
          id: existing.id,
          worldId: existing.worldId,
          characterId: existing.characterId,
          displayNameSnapshot: existing.displayNameSnapshot,
          currentLocationId: existing.currentLocationId,
          isActive: active,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.instanceRepo.updateWithStore(store, updated);
        const eventType: WorldEventType = active
          ? WorldEventType.CharacterActivated : WorldEventType.CharacterDeactivated;
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: eventType,
          sourceCharacterInstanceId: instanceId,
          sourceLocationId: existing.currentLocationId,
          summary: active ? '角色已激活' : '角色已停用'
        }));
        result = updated;
      },
      'world_character_activate'
    );
    if (result === null) {
      throw WorldStateError.internal('事务未产生结果');
    }
    return result;
  }

  /**
   * 从当前 Character 重新读取名称并更新 displayNameSnapshot。
   * 不在每次查询时自动写数据库。Character 已不存在时返回明确错误。
   */
  async refreshCharacterDisplayName(instanceId: string): Promise<WorldCharacterInstance> {
    const existing: WorldCharacterInstance | null = await this.instanceRepo.getById(instanceId);
    if (existing === null) {
      throw WorldStateError.characterInstanceNotFound();
    }
    const character: Character | null = await this.characterService.getById(existing.characterId);
    if (character === null) {
      throw WorldStateError.characterNotFound();
    }
    if (character.name === existing.displayNameSnapshot) {
      return existing;
    }
    const updated: WorldCharacterInstance = createWorldCharacterInstanceRecord({
      id: existing.id,
      worldId: existing.worldId,
      characterId: existing.characterId,
      displayNameSnapshot: character.name,
      currentLocationId: existing.currentLocationId,
      isActive: existing.isActive,
      createdAt: existing.createdAt,
      updatedAt: nowMillis()
    });
    await this.instanceRepo.update(updated);
    return updated;
  }

  // ===== 移动 =====

  /**
   * 初始放置角色。仅允许 currentLocationId 为空。
   * 校验:实例存在且 Active → World Active → 目标地点存在、属于同 World、Active。
   * 初始放置不需要连接边。
   * 事务内:更新 currentLocationId → 插入 CharacterMoved 事件(sourceLocationId 为空)。
   */
  async placeCharacter(instanceId: string, locationId: string): Promise<WorldCharacterInstance> {
    let result: WorldCharacterInstance | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, instanceId);
        if (existing === null) {
          throw WorldStateError.characterInstanceNotFound();
        }
        if (!existing.isActive) {
          throw WorldStateError.characterInstanceInactive();
        }
        await this.assertWorldActiveInTx(store, existing.worldId);
        if (existing.currentLocationId !== undefined) {
          throw WorldStateError.invalidOperation('角色已放置,请使用移动');
        }
        const target: WorldLocation | null = await this.locationRepo.getByIdWithStore(store, locationId);
        if (target === null) {
          throw WorldStateError.locationNotFound();
        }
        if (target.worldId !== existing.worldId) {
          throw WorldStateError.locationNotInWorld();
        }
        if (target.status !== WorldLocationStatus.Active) {
          throw WorldStateError.locationNotFound();
        }
        const updated: WorldCharacterInstance = createWorldCharacterInstanceRecord({
          id: existing.id,
          worldId: existing.worldId,
          characterId: existing.characterId,
          displayNameSnapshot: existing.displayNameSnapshot,
          currentLocationId: locationId,
          isActive: existing.isActive,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.instanceRepo.updateWithStore(store, updated);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: WorldEventType.CharacterMoved,
          sourceCharacterInstanceId: instanceId,
          targetLocationId: locationId,
          summary: '角色已放置'
        }));
        result = updated;
      },
      'world_character_move'
    );
    if (result === null) {
      throw WorldStateError.internal('事务未产生结果');
    }
    return result;
  }

  /**
   * 正常移动角色。要求存在可通行且 isEnabled=true 的 Edge。
   * 校验:实例存在且 Active → 当前地点存在 → 目标地点存在、属于同 World、Active、≠ 当前 →
   * 存在可通行边(单向 from=当前 to=目标,或双向边两端匹配)。
   * 停用边不可通行。
   * 事务内:更新 currentLocationId → 插入 CharacterMoved 事件。
   */
  async moveCharacter(instanceId: string, targetLocationId: string): Promise<WorldCharacterInstance> {
    let result: WorldCharacterInstance | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, instanceId);
        if (existing === null) {
          throw WorldStateError.characterInstanceNotFound();
        }
        if (!existing.isActive) {
          throw WorldStateError.characterInstanceInactive();
        }
        await this.assertWorldActiveInTx(store, existing.worldId);
        if (existing.currentLocationId === undefined) {
          throw WorldStateError.characterNotPlaced();
        }
        if (existing.currentLocationId === targetLocationId) {
          throw WorldStateError.characterAlreadyAtLocation();
        }
        const target: WorldLocation | null = await this.locationRepo.getByIdWithStore(store, targetLocationId);
        if (target === null) {
          throw WorldStateError.locationNotFound();
        }
        if (target.worldId !== existing.worldId) {
          throw WorldStateError.locationNotInWorld();
        }
        if (target.status !== WorldLocationStatus.Active) {
          throw WorldStateError.locationNotFound();
        }
        // 校验可通行边
        await this.assertEnabledPathInTx(
          store, existing.worldId, existing.currentLocationId, targetLocationId
        );
        const updated: WorldCharacterInstance = createWorldCharacterInstanceRecord({
          id: existing.id,
          worldId: existing.worldId,
          characterId: existing.characterId,
          displayNameSnapshot: existing.displayNameSnapshot,
          currentLocationId: targetLocationId,
          isActive: existing.isActive,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.instanceRepo.updateWithStore(store, updated);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: WorldEventType.CharacterMoved,
          sourceCharacterInstanceId: instanceId,
          sourceLocationId: existing.currentLocationId,
          targetLocationId: targetLocationId,
          summary: '角色已移动'
        }));
        result = updated;
      },
      'world_character_move'
    );
    if (result === null) {
      throw WorldStateError.internal('事务未产生结果');
    }
    return result;
  }

  /**
   * 强制移动角色。绕过连接边校验,但仍校验:
   * 实例存在 → World Active → 目标地点属于同 World → 目标地点 Active。
   * 不要求实例 Active(可移动 inactive 实例)。payloadJson 记录 {"forced":true}。
   */
  async forceMoveCharacter(instanceId: string, targetLocationId: string): Promise<WorldCharacterInstance> {
    let result: WorldCharacterInstance | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldCharacterInstance | null =
          await this.instanceRepo.getByIdWithStore(store, instanceId);
        if (existing === null) {
          throw WorldStateError.characterInstanceNotFound();
        }
        await this.assertWorldActiveInTx(store, existing.worldId);
        const target: WorldLocation | null = await this.locationRepo.getByIdWithStore(store, targetLocationId);
        if (target === null) {
          throw WorldStateError.locationNotFound();
        }
        if (target.worldId !== existing.worldId) {
          throw WorldStateError.locationNotInWorld();
        }
        if (target.status !== WorldLocationStatus.Active) {
          throw WorldStateError.locationNotFound();
        }
        const previousLocationId: string | undefined = existing.currentLocationId;
        const updated: WorldCharacterInstance = createWorldCharacterInstanceRecord({
          id: existing.id,
          worldId: existing.worldId,
          characterId: existing.characterId,
          displayNameSnapshot: existing.displayNameSnapshot,
          currentLocationId: targetLocationId,
          isActive: existing.isActive,
          createdAt: existing.createdAt,
          updatedAt: nowMillis()
        });
        await this.instanceRepo.updateWithStore(store, updated);
        await this.eventRepo.insertWithStore(store, buildEvent({
          worldId: existing.worldId,
          eventType: WorldEventType.CharacterMoved,
          sourceCharacterInstanceId: instanceId,
          sourceLocationId: previousLocationId,
          targetLocationId: targetLocationId,
          summary: '角色已强制移动',
          payloadJson: '{"forced":true}'
        }));
        result = updated;
      },
      'world_character_move'
    );
    if (result === null) {
      throw WorldStateError.internal('事务未产生结果');
    }
    return result;
  }

  // ===== 私有校验工具 =====

  /**
   * 校验 World 存在且为 Active。不存在抛 WorldNotFound,已归档抛 WorldArchived。
   */
  private async assertWorldActiveInTx(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<World> {
    const world: World | null = await this.worldRepo.getByIdWithStore(store, worldId);
    if (world === null) {
      throw WorldStateError.worldNotFound();
    }
    if (world.status !== WorldStatus.Active) {
      throw WorldStateError.worldArchived();
    }
    return world;
  }

  /**
   * 校验不存在冲突连接。excludeEdgeId 非空时排除该边自身(用于更新场景)。
   * 冲突规则见 createEdge 注释。
   */
  private async assertNoEdgeConflictInTx(
    store: relationalStore.RdbStore,
    worldId: string,
    fromLocationId: string,
    toLocationId: string,
    isBidirectional: boolean,
    excludeEdgeId: string
  ): Promise<void> {
    // 精确重复(from→to)
    const forward: WorldLocationEdge | null = await this.edgeRepo.findExactWithStore(
      store, worldId, fromLocationId, toLocationId
    );
    if (forward !== null && forward.id !== excludeEdgeId) {
      throw WorldStateError.edgeConflict();
    }
    // 反向边(to→from)
    const reverse: WorldLocationEdge | null = await this.edgeRepo.findExactWithStore(
      store, worldId, toLocationId, fromLocationId
    );
    if (reverse !== null && reverse.id !== excludeEdgeId) {
      // 已有反向双向边:阻止任意新建
      if (reverse.isBidirectional) {
        throw WorldStateError.edgeConflict();
      }
      // 新建双向边:已有反向边(任意)均阻止
      if (isBidirectional) {
        throw WorldStateError.edgeConflict();
      }
      // 否则:两条相反单向边允许共存
    }
  }

  /**
   * 校验 currentLocationId → targetLocationId 存在可通行且启用的边。
   * 可通行:单向边 from=当前 to=目标(enabled),或双向边两端匹配(enabled)。
   * 停用边不可通行。
   */
  private async assertEnabledPathInTx(
    store: relationalStore.RdbStore,
    worldId: string,
    currentLocationId: string,
    targetLocationId: string
  ): Promise<void> {
    // 单向或双向 from=当前 to=目标
    const forward: WorldLocationEdge | null = await this.edgeRepo.findExactWithStore(
      store, worldId, currentLocationId, targetLocationId
    );
    if (forward !== null && forward.isEnabled) {
      return;
    }
    // 反向双向边 to=当前 from=目标(即可从当前→目标)
    const reverse: WorldLocationEdge | null = await this.edgeRepo.findExactWithStore(
      store, worldId, targetLocationId, currentLocationId
    );
    if (reverse !== null && reverse.isBidirectional && reverse.isEnabled) {
      return;
    }
    throw WorldStateError.noEnabledPath();
  }
}

// ===== 模块级纯工具函数 =====

/** trim 文本(不截断,截断由调用方决定)。 */
function normalizeText(value: string): string {
  return value.trim();
}

/** 截断到最大长度。 */
function truncate(value: string, max: number): string {
  if (value.length <= max) {
    return value;
  }
  return value.substring(0, max);
}

/** 规范化可选 ID:undefined 或空字符串视为未指定。 */
function normalizeOptionalId(value?: string): string | undefined {
  if (value === undefined || value === '') {
    return undefined;
  }
  return value;
}

/**
 * 构造 WorldEvent 记录(自动生成 id 与时间戳)。
 * summary / payloadJson 会被截断到安全上限。
 * 仅由 WorldStateService 在事务内调用,字段语义清晰,不使用重载。
 */
function buildEvent(options: BuildEventOptions): WorldEvent {
  return createWorldEventRecord({
    id: WORLD_EVENT_ID_PREFIX + generateUuid(),
    worldId: options.worldId,
    eventType: options.eventType,
    sourceCharacterInstanceId: options.sourceCharacterInstanceId,
    sourceLocationId: options.sourceLocationId,
    targetLocationId: options.targetLocationId,
    summary: truncate(options.summary, EVENT_SUMMARY_MAX),
    payloadJson: options.payloadJson !== undefined
      ? truncate(options.payloadJson, PAYLOAD_JSON_MAX)
      : undefined,
    occurredAt: nowMillis(),
    createdAt: nowMillis()
  });
}
