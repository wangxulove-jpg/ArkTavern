import { describe, it, expect } from '@ohos/hypium';
import {
  WorldPlayerProfile,
  createWorldPlayerProfileRecord
} from '../../../main/ets/models/world/WorldPlayerProfile';

export default function playerProfileModelContractTest(): void {
  describe('PLAYERCHAR-01~08 WorldPlayerProfile 模型契约(W2A1)', () => {
    it('PLAYERCHAR-01 创建含全部字段的档案', 0, () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'pp-1',
        worldId: 'w-1',
        displayName: 'Hero',
        persona: 'A brave warrior',
        publicIdentity: 'Champion of Light',
        privateIdentity: 'Secretly afraid of spiders',
        currentLocationId: 'loc-1'
      });
      expect(profile.id).assertEqual('pp-1');
      expect(profile.worldId).assertEqual('w-1');
      expect(profile.displayName).assertEqual('Hero');
      expect(profile.persona).assertEqual('A brave warrior');
      expect(profile.publicIdentity).assertEqual('Champion of Light');
      expect(profile.privateIdentity).assertEqual('Secretly afraid of spiders');
      expect(profile.currentLocationId).assertEqual('loc-1');
      expect(profile.createdAt > 0).assertTrue();
      expect(profile.updatedAt > 0).assertTrue();
    });

    it('PLAYERCHAR-02 省略新增字段时默认为空字符串或undefined', 0, () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'pp-2',
        worldId: 'w-1',
        displayName: 'Player'
      });
      expect(profile.persona).assertEqual('');
      expect(profile.publicIdentity).assertEqual('');
      expect(profile.privateIdentity).assertEqual('');
      expect(profile.currentLocationId === undefined).assertTrue();
    });

    it('PLAYERCHAR-03 persona 空字符串允许', 0, () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'pp-3',
        worldId: 'w-1',
        displayName: 'Player',
        persona: ''
      });
      expect(profile.persona).assertEqual('');
    });

    it('PLAYERCHAR-04 publicIdentity 空字符串允许', 0, () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'pp-4',
        worldId: 'w-1',
        displayName: 'Player',
        publicIdentity: ''
      });
      expect(profile.publicIdentity).assertEqual('');
    });

    it('PLAYERCHAR-05 privateIdentity 空字符串允许', 0, () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'pp-5',
        worldId: 'w-1',
        displayName: 'Player',
        privateIdentity: ''
      });
      expect(profile.privateIdentity).assertEqual('');
    });

    it('PLAYERCHAR-06 currentLocationId 空字符串视为undefined', 0, () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'pp-6',
        worldId: 'w-1',
        displayName: 'Player',
        currentLocationId: ''
      });
      expect(profile.currentLocationId === undefined).assertTrue();
    });

    it('PLAYERCHAR-07 currentLocationId undefined 允许', 0, () => {
      const profile: WorldPlayerProfile = createWorldPlayerProfileRecord({
        id: 'pp-7',
        worldId: 'w-1',
        displayName: 'Player',
        currentLocationId: undefined
      });
      expect(profile.currentLocationId === undefined).assertTrue();
    });

    it('PLAYERCHAR-08 displayName 仍为必填(trim后非空)', 0, () => {
      try {
        createWorldPlayerProfileRecord({
          id: 'pp-8',
          worldId: 'w-1',
          displayName: '   '
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });
  });
}
