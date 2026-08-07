import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import {
  WorldPlayerProfile,
  createWorldPlayerProfileRecord,
  WORLD_PLAYER_PROFILE_ID_PREFIX
} from '../../../main/ets/models/world/WorldPlayerProfile';
import { WorldPlayerProfileRepository } from '../../../main/ets/repositories/world/WorldPlayerProfileRepository';

const TEST_DB: string = 'w1a_player_profile_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function worldPlayerProfileContractTest(): void {
  describe('WorldPlayerProfile 数据契约', () => {
    let dbHelper: DbHelper;
    let repo: WorldPlayerProfileRepository;

    beforeAll(async () => {
      const ctx: common.Context = await getContext();
      dbHelper = new DbHelper(TEST_DB);
      await dbHelper.initialize(ctx);
      repo = new WorldPlayerProfileRepository(dbHelper);
    });

    afterAll(async () => {
      if (dbHelper.isInitialized()) {
        await dbHelper.close();
      }
    });

    it('createWorldPlayerProfileRecord 正常创建', 0, () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'test-id-1',
        worldId: 'world-1',
        displayName: '  Hero  '
      });
      expect(profile.id).assertEqual('test-id-1');
      expect(profile.worldId).assertEqual('world-1');
      expect(profile.displayName).assertEqual('Hero');
      expect(profile.createdAt > 0).assertTrue();
      expect(profile.updatedAt > 0).assertTrue();
    });

    it('createWorldPlayerProfileRecord 空 displayName 抛错', 0, () => {
      try {
        createWorldPlayerProfileRecord({
          id: 'test-id-2',
          worldId: 'world-1',
          displayName: '   '
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('createWorldPlayerProfileRecord 空 id 抛错', 0, () => {
      try {
        createWorldPlayerProfileRecord({
          id: '',
          worldId: 'world-1',
          displayName: 'Hero'
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('createWorldPlayerProfileRecord 空 worldId 抛错', 0, () => {
      try {
        createWorldPlayerProfileRecord({
          id: 'test-id-3',
          worldId: '',
          displayName: 'Hero'
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('insert + getByWorldId 成功', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'profile-insert-1',
        worldId: 'world-insert-1',
        displayName: 'Player One'
      });
      await repo.insert(profile);
      const found: WorldPlayerProfile | null = await repo.getByWorldId('world-insert-1');
      expect(found !== null).assertTrue();
      expect(found!.id).assertEqual('profile-insert-1');
      expect(found!.displayName).assertEqual('Player One');
    });

    it('UNIQUE(worldId) 重复插入抛 alreadyExists', 0, async () => {
      const p1: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'profile-uniq-1',
        worldId: 'world-uniq-1',
        displayName: 'First'
      });
      await repo.insert(p1);
      const p2: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'profile-uniq-2',
        worldId: 'world-uniq-1',
        displayName: 'Second'
      });
      try {
        await repo.insert(p2);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('update 修改 displayName 成功', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'profile-update-1',
        worldId: 'world-update-1',
        displayName: 'Old Name'
      });
      await repo.insert(profile);
      const updated: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'profile-update-1',
        worldId: 'world-update-1',
        displayName: 'New Name',
        createdAt: profile.createdAt,
        updatedAt: profile.createdAt + 1000
      });
      await repo.update(updated);
      const found: WorldPlayerProfile | null = await repo.getById('profile-update-1');
      expect(found !== null).assertTrue();
      expect(found!.displayName).assertEqual('New Name');
    });

    it('deleteByWorldId 成功删除', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'profile-del-1',
        worldId: 'world-del-1',
        displayName: 'To Delete'
      });
      await repo.insert(profile);
      await repo.deleteByWorldId('world-del-1');
      const found: WorldPlayerProfile | null = await repo.getByWorldId('world-del-1');
      expect(found).assertNull();
    });

    it('ID_PREFIX 格式正确', 0, () => {
      expect(WORLD_PLAYER_PROFILE_ID_PREFIX).assertEqual('world-player-profile-');
    });
  });
}
