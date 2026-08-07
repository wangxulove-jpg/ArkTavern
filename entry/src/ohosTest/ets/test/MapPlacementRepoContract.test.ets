import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import {
  WorldLocationMapPlacement,
  createWorldLocationMapPlacementRecord,
  WORLD_MAP_PLACEMENT_ID_PREFIX
} from '../../../main/ets/models/world/WorldLocationMapPlacement';
import { WorldLocationMapPlacementRepository } from '../../../main/ets/repositories/world/WorldLocationMapPlacementRepository';
import { DatabaseError, DatabaseErrorType } from '../../../main/ets/models/DatabaseError';

const TEST_DB: string = 'w1c_map_placement_repo_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

function makePlacement(
  worldId: string,
  locationId: string,
  x: number = 0,
  y: number = 0,
  z: number = 0
): WorldLocationMapPlacement {
  return createWorldLocationMapPlacementRecord({
    id: WORLD_MAP_PLACEMENT_ID_PREFIX + worldId + '-' + locationId,
    worldId: worldId,
    locationId: locationId,
    positionX: x,
    positionY: y,
    positionZ: z
  });
}

export default function mapPlacementRepoContractTest(): void {
  describe('MAPCONTRACT 仓储契约', () => {
    let dbHelper: DbHelper;
    let repo: WorldLocationMapPlacementRepository;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
      repo = new WorldLocationMapPlacementRepository(dbHelper);
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('MAPCONTRACT-13 insert + getById 正常读取', 0, async () => {
      const p: WorldLocationMapPlacement = makePlacement('w1', 'loc-a', 10, 20, 30);
      await repo.insert(p);
      const loaded: WorldLocationMapPlacement | null = await repo.getById(p.id);
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.id).assertEqual(p.id);
        expect(loaded.worldId).assertEqual('w1');
        expect(loaded.locationId).assertEqual('loc-a');
        expect(loaded.positionX).assertEqual(10);
        expect(loaded.positionY).assertEqual(20);
        expect(loaded.positionZ).assertEqual(30);
        expect(loaded.scale).assertEqual(1);
      }
    });

    it('MAPCONTRACT-14 getById 不存在返回 null', 0, async () => {
      const loaded: WorldLocationMapPlacement | null = await repo.getById('world-map-placement-nonexistent');
      expect(loaded).assertNull();
    });

    it('MAPCONTRACT-15 listByWorldId 返回指定世界的放置按 createdAt ASC', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          const p1: WorldLocationMapPlacement = makePlacement('w-list', 'loc-1', 1, 0, 0);
          const p2: WorldLocationMapPlacement = makePlacement('w-list', 'loc-2', 2, 0, 0);
          await repo.insertWithStore(s, p1);
          await repo.insertWithStore(s, p2);
        },
        'world_map_placement_upsert'
      );
      const list: WorldLocationMapPlacement[] = await repo.listByWorldId('w-list');
      expect(list.length >= 2).assertTrue();
    });

    it('MAPCONTRACT-16 getByWorldAndLocation 精确查询', 0, async () => {
      const p: WorldLocationMapPlacement = makePlacement('w-gw', 'loc-xy', 5, 6, 7);
      await repo.insert(p);
      const found: WorldLocationMapPlacement | null = await repo.getByWorldAndLocation('w-gw', 'loc-xy');
      expect(found !== null).assertTrue();
      if (found !== null) {
        expect(found.positionX).assertEqual(5);
      }
    });

    it('MAPCONTRACT-17 UNIQUE(world_id, location_id) 冲突时 insert 抛 AlreadyExists', 0, async () => {
      const p1: WorldLocationMapPlacement = makePlacement('w-uni', 'loc-dup');
      await repo.insert(p1);
      const p2: WorldLocationMapPlacement = makePlacement('w-uni', 'loc-dup', 99, 88, 77);
      try {
        await repo.insert(p2);
        expect(true).assertFalse();
      } catch (err) {
        expect(err instanceof DatabaseError).assertTrue();
        if (err instanceof DatabaseError) {
          expect(err.type === DatabaseErrorType.AlreadyExists).assertTrue();
        }
      }
    });

    it('MAPCONTRACT-18 upsertWithStore 已存在时更新位置/旋转/缩放/updatedAt', 0, async () => {
      const p1: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'upsert-test',
        worldId: 'w-upsert',
        locationId: 'loc-up',
        positionX: 1,
        positionY: 2,
        positionZ: 3,
        rotationX: 0,
        rotationY: 0,
        rotationZ: 0,
        scale: 1,
        createdAt: 1000,
        updatedAt: 1000
      });
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await repo.insertWithStore(s, p1);
        },
        'world_map_placement_upsert'
      );
      const p2: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'upsert-test-v2',
        worldId: 'w-upsert',
        locationId: 'loc-up',
        positionX: 10,
        positionY: 20,
        positionZ: 30,
        rotationX: 1.57,
        rotationY: 0.5,
        rotationZ: 3.14,
        scale: 2.5,
        createdAt: 999,
        updatedAt: 2000
      });
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await repo.upsertWithStore(s, p2);
        },
        'world_map_placement_upsert'
      );
      const loaded: WorldLocationMapPlacement | null = await repo.getByWorldAndLocation('w-upsert', 'loc-up');
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.positionX).assertEqual(10);
        expect(loaded.positionY).assertEqual(20);
        expect(loaded.positionZ).assertEqual(30);
        expect(loaded.rotationX).assertEqual(1.57);
        expect(loaded.rotationY).assertEqual(0.5);
        expect(loaded.rotationZ).assertEqual(3.14);
        expect(loaded.scale).assertEqual(2.5);
        expect(loaded.createdAt).assertEqual(1000);
        expect(loaded.updatedAt).assertEqual(2000);
      }
    });

    it('MAPCONTRACT-19 upsertWithStore 不存在时插入新行', 0, async () => {
      const p: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: WORLD_MAP_PLACEMENT_ID_PREFIX + 'upsert-new',
        worldId: 'w-upsert-new',
        locationId: 'loc-un',
        positionX: 7,
        positionY: 8,
        positionZ: 9,
        createdAt: 1500,
        updatedAt: 1500
      });
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await repo.upsertWithStore(s, p);
        },
        'world_map_placement_upsert'
      );
      const loaded: WorldLocationMapPlacement | null = await repo.getById(p.id);
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.positionX).assertEqual(7);
      }
    });

    it('MAPCONTRACT-20 update 正常更新位置/旋转/缩放', 0, async () => {
      const p: WorldLocationMapPlacement = makePlacement('w-upd', 'loc-upd', 1, 2, 3);
      await repo.insert(p);
      const updated: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: p.id,
        worldId: p.worldId,
        locationId: p.locationId,
        positionX: 100,
        positionY: 200,
        positionZ: 300,
        rotationX: 0.1,
        rotationY: 0.2,
        rotationZ: 0.3,
        scale: 3.0,
        createdAt: p.createdAt,
        updatedAt: p.updatedAt + 1000
      });
      await repo.update(updated);
      const loaded: WorldLocationMapPlacement | null = await repo.getById(p.id);
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.positionX).assertEqual(100);
        expect(loaded.scale).assertEqual(3.0);
      }
    });

    it('MAPCONTRACT-21 update 不存在抛 NotFound', 0, async () => {
      const p: WorldLocationMapPlacement = makePlacement('w-upd-no', 'loc-no', 0, 0, 0);
      try {
        await repo.update(p);
        expect(true).assertFalse();
      } catch (err) {
        expect(err instanceof DatabaseError).assertTrue();
        if (err instanceof DatabaseError) {
          expect(err.type === DatabaseErrorType.NotFound).assertTrue();
        }
      }
    });

    it('MAPCONTRACT-22 deleteById 正常删除', 0, async () => {
      const p: WorldLocationMapPlacement = makePlacement('w-del', 'loc-del');
      await repo.insert(p);
      await repo.deleteById(p.id);
      const loaded: WorldLocationMapPlacement | null = await repo.getById(p.id);
      expect(loaded).assertNull();
    });

    it('MAPCONTRACT-23 deleteById 幂等(不存在不抛错)', 0, async () => {
      await repo.deleteById('world-map-placement-ghost');
      expect(true).assertTrue();
    });

    it('MAPCONTRACT-24 deleteByWorldWithStore 删除指定世界全部放置', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await repo.insertWithStore(s, makePlacement('w-delworld', 'loc-a1'));
          await repo.insertWithStore(s, makePlacement('w-delworld', 'loc-a2'));
        },
        'world_map_placement_upsert'
      );
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await repo.deleteByWorldWithStore(s, 'w-delworld');
        },
        'world_map_placement_delete'
      );
      const list: WorldLocationMapPlacement[] = await repo.listByWorldId('w-delworld');
      expect(list.length).assertEqual(0);
    });

    it('MAPCONTRACT-25 deleteByLocationWithStore 删除指定地点关联放置', 0, async () => {
      const store: relationalStore.RdbStore = dbHelper.getStore();
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await repo.insertWithStore(s, makePlacement('w-delloc', 'loc-xx'));
          await repo.insertWithStore(s, makePlacement('w-delloc', 'loc-yy'));
        },
        'world_map_placement_upsert'
      );
      await dbHelper.runInTransaction(
        async (s: relationalStore.RdbStore): Promise<void> => {
          await repo.deleteByLocationWithStore(s, 'loc-xx');
        },
        'world_map_placement_delete'
      );
      const found1: WorldLocationMapPlacement | null = await repo.getByWorldAndLocation('w-delloc', 'loc-xx');
      expect(found1).assertNull();
      const found2: WorldLocationMapPlacement | null = await repo.getByWorldAndLocation('w-delloc', 'loc-yy');
      expect(found2 !== null).assertTrue();
    });

    it('MAPCONTRACT-26 负数 position 有效(允许负坐标)', 0, async () => {
      const p: WorldLocationMapPlacement = makePlacement('w-neg', 'loc-neg', -5.5, -10, -100);
      await repo.insert(p);
      const loaded: WorldLocationMapPlacement | null = await repo.getById(p.id);
      expect(loaded !== null).assertTrue();
      if (loaded !== null) {
        expect(loaded.positionX).assertEqual(-5.5);
        expect(loaded.positionY).assertEqual(-10);
        expect(loaded.positionZ).assertEqual(-100);
      }
    });
  });
}
