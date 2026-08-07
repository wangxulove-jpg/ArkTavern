import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import {
  WorldPlayerProfile,
  createWorldPlayerProfileRecord
} from '../../../main/ets/models/world/WorldPlayerProfile';
import { WorldPlayerProfileRepository } from '../../../main/ets/repositories/world/WorldPlayerProfileRepository';

const TEST_DB: string = 'w2a1_player_profile_repo_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

export default function playerProfileRepositoryContractTest(): void {
  describe('PLAYERCHAR-15~24 WorldPlayerProfileRepository 数据契约(W2A1)', () => {
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

    it('PLAYERCHAR-15 插入含 persona 的档案并读取', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-1',
        worldId: 'w-repo-1',
        displayName: 'Hero',
        persona: 'A mysterious wanderer'
      });
      await repo.insert(profile);
      const loaded: WorldPlayerProfile | null = await repo.getById('ppr-1');
      expect(loaded !== null).assertTrue();
      expect(loaded!.persona).assertEqual('A mysterious wanderer');
    });

    it('PLAYERCHAR-16 插入含 publicIdentity 的档案并读取', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-2',
        worldId: 'w-repo-2',
        displayName: 'Knight',
        publicIdentity: 'Order of the Shield'
      });
      await repo.insert(profile);
      const loaded: WorldPlayerProfile | null = await repo.getByWorldId('w-repo-2');
      expect(loaded !== null).assertTrue();
      expect(loaded!.publicIdentity).assertEqual('Order of the Shield');
    });

    it('PLAYERCHAR-17 插入含 privateIdentity 的档案并读取', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-3',
        worldId: 'w-repo-3',
        displayName: 'Rogue',
        privateIdentity: 'Thieves Guild member'
      });
      await repo.insert(profile);
      const loaded: WorldPlayerProfile | null = await repo.getById('ppr-3');
      expect(loaded !== null).assertTrue();
      expect(loaded!.privateIdentity).assertEqual('Thieves Guild member');
    });

    it('PLAYERCHAR-18 插入含 currentLocationId 的档案并读取', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-4',
        worldId: 'w-repo-4',
        displayName: 'Wizard',
        currentLocationId: 'loc-tower'
      });
      await repo.insert(profile);
      const loaded: WorldPlayerProfile | null = await repo.getById('ppr-4');
      expect(loaded !== null).assertTrue();
      expect(loaded!.currentLocationId).assertEqual('loc-tower');
    });

    it('PLAYERCHAR-19 插入不含 currentLocationId 的档案读取为 undefined', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-5',
        worldId: 'w-repo-5',
        displayName: 'Wanderer'
      });
      await repo.insert(profile);
      const loaded: WorldPlayerProfile | null = await repo.getById('ppr-5');
      expect(loaded !== null).assertTrue();
      expect(loaded!.currentLocationId === undefined).assertTrue();
    });

    it('PLAYERCHAR-20 更新 persona 字段', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-6',
        worldId: 'w-repo-6',
        displayName: 'Healer',
        persona: 'Original'
      });
      await repo.insert(profile);
      const updated: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-6',
        worldId: 'w-repo-6',
        displayName: 'Healer',
        persona: 'Updated',
        createdAt: profile.createdAt
      });
      await repo.update(updated);
      const loaded: WorldPlayerProfile | null = await repo.getById('ppr-6');
      expect(loaded !== null).assertTrue();
      expect(loaded!.persona).assertEqual('Updated');
    });

    it('PLAYERCHAR-21 更新 currentLocationId 从 undefined 到有值', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-7',
        worldId: 'w-repo-7',
        displayName: 'Scout'
      });
      await repo.insert(profile);
      const updated: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-7',
        worldId: 'w-repo-7',
        displayName: 'Scout',
        currentLocationId: 'loc-camp',
        createdAt: profile.createdAt
      });
      await repo.update(updated);
      const loaded: WorldPlayerProfile | null = await repo.getById('ppr-7');
      expect(loaded !== null).assertTrue();
      expect(loaded!.currentLocationId).assertEqual('loc-camp');
    });

    it('PLAYERCHAR-22 更新 currentLocationId 从有值到 undefined', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-8',
        worldId: 'w-repo-8',
        displayName: 'Bard',
        currentLocationId: 'loc-inn'
      });
      await repo.insert(profile);
      const updated: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-8',
        worldId: 'w-repo-8',
        displayName: 'Bard',
        createdAt: profile.createdAt
      });
      await repo.update(updated);
      const loaded: WorldPlayerProfile | null = await repo.getById('ppr-8');
      expect(loaded !== null).assertTrue();
      expect(loaded!.currentLocationId === undefined).assertTrue();
    });

    it('PLAYERCHAR-23 省略新字段插入后读取默认值', 0, async () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-9',
        worldId: 'w-repo-9',
        displayName: 'Default'
      });
      await repo.insert(profile);
      const loaded: WorldPlayerProfile | null = await repo.getById('ppr-9');
      expect(loaded !== null).assertTrue();
      expect(loaded!.persona).assertEqual('');
      expect(loaded!.publicIdentity).assertEqual('');
      expect(loaded!.privateIdentity).assertEqual('');
      expect(loaded!.currentLocationId === undefined).assertTrue();
    });

    it('PLAYERCHAR-24 事务内 insertWithStore + getByWorldIdWithStore 读取新字段', 0, async () => {
      const store = dbHelper.getStore();
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'ppr-10',
        worldId: 'w-repo-10',
        displayName: 'TxHero',
        persona: 'TxPersona',
        publicIdentity: 'TxPublic',
        privateIdentity: 'TxPrivate',
        currentLocationId: 'loc-tx'
      });
      await dbHelper.runInTransaction(
        async (): Promise<void> => {
          await repo.insertWithStore(store, profile);
        },
        'world_character_add'
      );
      const loaded: WorldPlayerProfile | null = await repo.getByWorldIdWithStore(store, 'w-repo-10');
      expect(loaded !== null).assertTrue();
      expect(loaded!.persona).assertEqual('TxPersona');
      expect(loaded!.publicIdentity).assertEqual('TxPublic');
      expect(loaded!.privateIdentity).assertEqual('TxPrivate');
      expect(loaded!.currentLocationId).assertEqual('loc-tx');
    });
  });
}
