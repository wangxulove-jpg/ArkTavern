import { describe, it, expect } from '@ohos/hypium';
import {
  WorldCharacterInstance,
  createWorldCharacterInstanceRecord
} from '../../../main/ets/models/world/WorldCharacterInstance';

export default function characterInstanceModelContractTest(): void {
  describe('PLAYERCHAR-09~14 WorldCharacterInstance 模型契约(W2A1)', () => {
    it('PLAYERCHAR-09 创建含 currentGoal 的实例', 0, () => {
      const instance: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-1',
        worldId: 'w-1',
        characterId: 'char-1',
        displayNameSnapshot: 'Alice',
        currentGoal: 'Find the lost artifact'
      });
      expect(instance.currentGoal).assertEqual('Find the lost artifact');
    });

    it('PLAYERCHAR-10 创建含 mapIconStyle 的实例', 0, () => {
      const instance: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-2',
        worldId: 'w-1',
        characterId: 'char-2',
        displayNameSnapshot: 'Bob',
        mapIconStyle: 'pin-red'
      });
      expect(instance.mapIconStyle).assertEqual('pin-red');
    });

    it('PLAYERCHAR-11 省略新增字段时 currentGoal 默认空字符串', 0, () => {
      const instance: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-3',
        worldId: 'w-1',
        characterId: 'char-3',
        displayNameSnapshot: 'Carol'
      });
      expect(instance.currentGoal).assertEqual('');
      expect(instance.mapIconStyle === undefined).assertTrue();
    });

    it('PLAYERCHAR-12 currentGoal 空字符串允许', 0, () => {
      const instance: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-4',
        worldId: 'w-1',
        characterId: 'char-4',
        displayNameSnapshot: 'Dave',
        currentGoal: ''
      });
      expect(instance.currentGoal).assertEqual('');
    });

    it('PLAYERCHAR-13 mapIconStyle undefined 允许', 0, () => {
      const instance: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-5',
        worldId: 'w-1',
        characterId: 'char-5',
        displayNameSnapshot: 'Eve',
        mapIconStyle: undefined
      });
      expect(instance.mapIconStyle === undefined).assertTrue();
    });

    it('PLAYERCHAR-14 创建无 currentLocationId 的实例(未放置)', 0, () => {
      const instance: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-6',
        worldId: 'w-1',
        characterId: 'char-6',
        displayNameSnapshot: 'Frank'
      });
      expect(instance.currentLocationId === undefined).assertTrue();
      expect(instance.isActive).assertTrue();
    });
  });
}
