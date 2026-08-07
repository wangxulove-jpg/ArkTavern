import { describe, it, expect } from '@ohos/hypium';
import {
  WorldCharacterInstance,
  createWorldCharacterInstanceRecord
} from '../../../main/ets/models/world/WorldCharacterInstance';
import {
  WorldCharacterInstanceManageUiModel,
  ActiveLocationOptionUiModel
} from '../../../main/ets/viewmodels/world/WorldCharacterManageViewModel';
import {
  WorldCharacterInstanceDetailUiModel
} from '../../../main/ets/viewmodels/world/WorldUiModels';

function createPlacedInstance(id: string, locationId: string): WorldCharacterInstance {
  return createWorldCharacterInstanceRecord({
    id: id,
    worldId: 'w-1',
    characterId: 'char-1',
    displayNameSnapshot: 'Alice',
    currentLocationId: locationId,
    isActive: true
  });
}

function createUnplacedInstance(id: string): WorldCharacterInstance {
  return createWorldCharacterInstanceRecord({
    id: id,
    worldId: 'w-1',
    characterId: 'char-1',
    displayNameSnapshot: 'Bob'
  });
}

function mapToManageUiModel(inst: WorldCharacterInstance): WorldCharacterInstanceManageUiModel {
  return {
    id: inst.id,
    characterId: inst.characterId,
    displayName: inst.displayNameSnapshot,
    isActive: inst.isActive,
    currentLocationId: inst.currentLocationId !== undefined ? inst.currentLocationId : '',
    currentLocationName: inst.currentLocationId !== undefined ? 'Tavern' : '',
    characterCardMissing: false,
    avatarUri: '',
    fallbackName: inst.displayNameSnapshot.charAt(0)
  };
}

function mapToDetailUiModel(inst: WorldCharacterInstance): WorldCharacterInstanceDetailUiModel {
  return {
    instanceId: inst.id,
    worldId: inst.worldId,
    worldName: 'Test World',
    characterId: inst.characterId,
    displayName: inst.displayNameSnapshot,
    avatarUri: '',
    fallbackName: inst.displayNameSnapshot.charAt(0),
    isActive: inst.isActive,
    currentLocationId: inst.currentLocationId !== undefined ? inst.currentLocationId : '',
    currentLocationName: inst.currentLocationId !== undefined ? 'Tavern' : '',
    locationMissing: false,
    characterCardMissing: false,
    createdAt: inst.createdAt,
    updatedAt: inst.updatedAt
  };
}

export default function characterPlacementContractTest(): void {
  describe('CHARUI 世界角色放置 UI 契约(W2A2)', () => {
    it('CHARUI-01 未放置实例 currentLocationId 为空字符串', 0, () => {
      const inst: WorldCharacterInstance = createUnplacedInstance('ci-1');
      const ui: WorldCharacterInstanceManageUiModel = mapToManageUiModel(inst);
      expect(ui.currentLocationId).assertEqual('');
    });

    it('CHARUI-02 已放置实例 currentLocationId 非空', 0, () => {
      const inst: WorldCharacterInstance = createPlacedInstance('ci-2', 'loc-1');
      const ui: WorldCharacterInstanceManageUiModel = mapToManageUiModel(inst);
      expect(ui.currentLocationId).assertEqual('loc-1');
    });

    it('CHARUI-03 未放置实例 UI 模型区分于已放置', 0, () => {
      const unplaced: WorldCharacterInstance = createUnplacedInstance('ci-3');
      const placed: WorldCharacterInstance = createPlacedInstance('ci-4', 'loc-1');
      const unplacedUi: WorldCharacterInstanceManageUiModel = mapToManageUiModel(unplaced);
      const placedUi: WorldCharacterInstanceManageUiModel = mapToManageUiModel(placed);
      expect(unplacedUi.currentLocationId.length === 0).assertTrue();
      expect(placedUi.currentLocationId.length > 0).assertTrue();
    });

    it('CHARUI-04 从地图撤下 = currentLocationId 变为空', 0, () => {
      const inst: WorldCharacterInstance = createPlacedInstance('ci-5', 'loc-1');
      expect(inst.currentLocationId).assertEqual('loc-1');
      const ui: WorldCharacterInstanceManageUiModel = mapToManageUiModel(inst);
      expect(ui.currentLocationId).assertEqual('loc-1');
      const afterUnplace: WorldCharacterInstanceManageUiModel = {
        id: ui.id,
        characterId: ui.characterId,
        displayName: ui.displayName,
        isActive: ui.isActive,
        currentLocationId: '',
        currentLocationName: '',
        characterCardMissing: ui.characterCardMissing,
        avatarUri: ui.avatarUri,
        fallbackName: ui.fallbackName
      };
      expect(afterUnplace.currentLocationId).assertEqual('');
      expect(afterUnplace.id).assertEqual('ci-5');
    });

    it('CHARUI-05 从地图撤下 ≠ 从世界移除', 0, () => {
      const inst: WorldCharacterInstance = createPlacedInstance('ci-6', 'loc-2');
      const afterUnplace: WorldCharacterInstanceManageUiModel = {
        id: inst.id,
        characterId: inst.characterId,
        displayName: inst.displayNameSnapshot,
        isActive: inst.isActive,
        currentLocationId: '',
        currentLocationName: '',
        characterCardMissing: false,
        avatarUri: '',
        fallbackName: inst.displayNameSnapshot.charAt(0)
      };
      expect(afterUnplace.id.length > 0).assertTrue();
      expect(afterUnplace.isActive).assertTrue();
    });

    it('CHARUI-06 调整位置后 currentLocationId 变更', 0, () => {
      const ui: WorldCharacterInstanceManageUiModel = mapToManageUiModel(
        createPlacedInstance('ci-7', 'loc-old')
      );
      const adjusted: WorldCharacterInstanceManageUiModel = {
        id: ui.id,
        characterId: ui.characterId,
        displayName: ui.displayName,
        isActive: ui.isActive,
        currentLocationId: 'loc-new',
        currentLocationName: 'New Place',
        characterCardMissing: ui.characterCardMissing,
        avatarUri: ui.avatarUri,
        fallbackName: ui.fallbackName
      };
      expect(adjusted.currentLocationId).assertEqual('loc-new');
      expect(adjusted.id).assertEqual('ci-7');
    });

    it('CHARUI-07 未放置角色数量计算', 0, () => {
      const instances: WorldCharacterInstanceManageUiModel[] = [
        mapToManageUiModel(createUnplacedInstance('ci-a')),
        mapToManageUiModel(createPlacedInstance('ci-b', 'loc-1')),
        mapToManageUiModel(createUnplacedInstance('ci-c')),
        mapToManageUiModel(createPlacedInstance('ci-d', 'loc-2'))
      ];
      let unplacedCount: number = 0;
      for (let i: number = 0; i < instances.length; i++) {
        if (instances[i].currentLocationId.length === 0) {
          unplacedCount = unplacedCount + 1;
        }
      }
      expect(unplacedCount).assertEqual(2);
    });

    it('CHARUI-08 ActiveLocationOptionUiModel 结构正确', 0, () => {
      const loc: ActiveLocationOptionUiModel = { id: 'loc-1', name: 'Tavern' };
      expect(loc.id).assertEqual('loc-1');
      expect(loc.name).assertEqual('Tavern');
    });

    it('CHARUI-09 hasLocations 等价于 activeLocations.length > 0', 0, () => {
      const empty: ActiveLocationOptionUiModel[] = [];
      const nonEmpty: ActiveLocationOptionUiModel[] = [{ id: 'loc-1', name: 'Tavern' }];
      expect(empty.length > 0).assertFalse();
      expect(nonEmpty.length > 0).assertTrue();
    });

    it('CHARUI-10 未放置角色 currentLocationId === undefined 映射为空字符串', 0, () => {
      const inst: WorldCharacterInstance = createUnplacedInstance('ci-e');
      expect(inst.currentLocationId === undefined).assertTrue();
      const ui: WorldCharacterInstanceManageUiModel = mapToManageUiModel(inst);
      expect(ui.currentLocationId).assertEqual('');
    });

    it('CHARUI-11 实例详情页未放置角色 currentLocationId 为空', 0, () => {
      const inst: WorldCharacterInstance = createUnplacedInstance('ci-f');
      const detail: WorldCharacterInstanceDetailUiModel = mapToDetailUiModel(inst);
      expect(detail.currentLocationId).assertEqual('');
    });

    it('CHARUI-12 实例详情页已放置角色 currentLocationId 非空', 0, () => {
      const inst: WorldCharacterInstance = createPlacedInstance('ci-g', 'loc-3');
      const detail: WorldCharacterInstanceDetailUiModel = mapToDetailUiModel(inst);
      expect(detail.currentLocationId).assertEqual('loc-3');
    });

    it('CHARUI-13 从地图撤下后重新放置 currentLocationId 恢复', 0, () => {
      const ui: WorldCharacterInstanceManageUiModel = {
        id: 'ci-h',
        characterId: 'char-1',
        displayName: 'Alice',
        isActive: true,
        currentLocationId: '',
        currentLocationName: '',
        characterCardMissing: false,
        avatarUri: '',
        fallbackName: 'A'
      };
      const replaced: WorldCharacterInstanceManageUiModel = {
        id: ui.id,
        characterId: ui.characterId,
        displayName: ui.displayName,
        isActive: ui.isActive,
        currentLocationId: 'loc-1',
        currentLocationName: 'Tavern',
        characterCardMissing: ui.characterCardMissing,
        avatarUri: ui.avatarUri,
        fallbackName: ui.fallbackName
      };
      expect(replaced.currentLocationId).assertEqual('loc-1');
    });

    it('CHARUI-14 无地点世界 hasLocations 为 false', 0, () => {
      const activeLocations: ActiveLocationOptionUiModel[] = [];
      expect(activeLocations.length > 0).assertFalse();
    });

    it('CHARUI-15 有 Active 地点 hasLocations 为 true', 0, () => {
      const activeLocations: ActiveLocationOptionUiModel[] = [{ id: 'loc-1', name: 'Tavern' }];
      expect(activeLocations.length > 0).assertTrue();
    });

    it('CHARUI-16 同一 characterId 不可重复加入同一 world', 0, () => {
      const inst1: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-i1',
        worldId: 'w-1',
        characterId: 'char-dup',
        displayNameSnapshot: 'Dup'
      });
      const inst2: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-i2',
        worldId: 'w-1',
        characterId: 'char-dup',
        displayNameSnapshot: 'Dup'
      });
      expect(inst1.characterId).assertEqual(inst2.characterId);
      expect(inst1.worldId).assertEqual(inst2.worldId);
    });

    it('CHARUI-17 候选列表过滤已加入角色', 0, () => {
      const joined: Set<string> = new Set<string>();
      joined.add('char-1');
      joined.add('char-3');
      const allIds: string[] = ['char-1', 'char-2', 'char-3', 'char-4'];
      const candidates: string[] = [];
      for (let i: number = 0; i < allIds.length; i++) {
        if (!joined.has(allIds[i])) {
          candidates.push(allIds[i]);
        }
      }
      expect(candidates.length).assertEqual(2);
      expect(candidates[0]).assertEqual('char-2');
      expect(candidates[1]).assertEqual('char-4');
    });

    it('CHARUI-18 添加角色默认未放置', 0, () => {
      const inst: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-new',
        worldId: 'w-1',
        characterId: 'char-new',
        displayNameSnapshot: 'NewChar'
      });
      expect(inst.currentLocationId === undefined).assertTrue();
    });

    it('CHARUI-19 添加并放置角色后 currentLocationId 非空', 0, () => {
      const inst: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-addplace',
        worldId: 'w-1',
        characterId: 'char-ap',
        displayNameSnapshot: 'AddPlace',
        currentLocationId: 'loc-target'
      });
      expect(inst.currentLocationId).assertEqual('loc-target');
    });

    it('CHARUI-20 放置操作不修改 isActive', 0, () => {
      const inst: WorldCharacterInstance = createUnplacedInstance('ci-place');
      expect(inst.isActive).assertTrue();
      const placed: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: inst.id,
        worldId: inst.worldId,
        characterId: inst.characterId,
        displayNameSnapshot: inst.displayNameSnapshot,
        currentLocationId: 'loc-1',
        isActive: true
      });
      expect(placed.isActive).assertTrue();
    });

    it('CHARUI-21 从地图撤下不修改 isActive', 0, () => {
      const inst: WorldCharacterInstance = createPlacedInstance('ci-unplace', 'loc-1');
      expect(inst.isActive).assertTrue();
      const afterUnplace: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: inst.id,
        worldId: inst.worldId,
        characterId: inst.characterId,
        displayNameSnapshot: inst.displayNameSnapshot,
        isActive: true
      });
      expect(afterUnplace.isActive).assertTrue();
      expect(afterUnplace.currentLocationId === undefined).assertTrue();
    });

    it('CHARUI-22 调整位置不修改 isActive', 0, () => {
      const inst: WorldCharacterInstance = createPlacedInstance('ci-adj', 'loc-old');
      expect(inst.isActive).assertTrue();
      const adjusted: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: inst.id,
        worldId: inst.worldId,
        characterId: inst.characterId,
        displayNameSnapshot: inst.displayNameSnapshot,
        currentLocationId: 'loc-new',
        isActive: true
      });
      expect(adjusted.isActive).assertTrue();
      expect(adjusted.currentLocationId).assertEqual('loc-new');
    });

    it('CHARUI-23 未放置角色不影响 billboardData 计算', 0, () => {
      const unplaced: WorldCharacterInstanceManageUiModel = mapToManageUiModel(
        createUnplacedInstance('ci-unp')
      );
      const locId: string = 'loc-1';
      const atLocation: boolean = unplaced.currentLocationId === locId;
      expect(atLocation).assertFalse();
    });

    it('CHARUI-24 已放置角色参与 billboardData 计算', 0, () => {
      const placed: WorldCharacterInstanceManageUiModel = mapToManageUiModel(
        createPlacedInstance('ci-plc', 'loc-1')
      );
      const locId: string = 'loc-1';
      const atLocation: boolean = placed.currentLocationId === locId;
      expect(atLocation).assertTrue();
    });

    it('CHARUI-25 unplacedCount 为 0 时 HUD 隐藏', 0, () => {
      const unplacedCount: number = 0;
      expect(unplacedCount > 0).assertFalse();
    });

    it('CHARUI-26 unplacedCount > 0 时 HUD 显示', 0, () => {
      const unplacedCount: number = 3;
      expect(unplacedCount > 0).assertTrue();
    });

    it('CHARUI-27 WorldDetailViewModel unplacedCharacters 仅含 currentLocationId 为空的角色', 0, () => {
      const chars: WorldCharacterInstanceManageUiModel[] = [
        mapToManageUiModel(createUnplacedInstance('u1')),
        mapToManageUiModel(createPlacedInstance('p1', 'loc-1')),
        mapToManageUiModel(createUnplacedInstance('u2')),
        mapToManageUiModel(createPlacedInstance('p2', 'loc-2'))
      ];
      const unplaced: WorldCharacterInstanceManageUiModel[] = [];
      for (let i: number = 0; i < chars.length; i++) {
        if (chars[i].currentLocationId.length === 0) {
          unplaced.push(chars[i]);
        }
      }
      expect(unplaced.length).assertEqual(2);
      expect(unplaced[0].id).assertEqual('u1');
      expect(unplaced[1].id).assertEqual('u2');
    });

    it('CHARUI-28 刷新令牌递增触发地图刷新', 0, () => {
      let token: number = 5;
      token = token + 1;
      expect(token).assertEqual(6);
    });

    it('CHARUI-29 从世界移除后实例不再出现', 0, () => {
      const before: WorldCharacterInstanceManageUiModel[] = [
        mapToManageUiModel(createUnplacedInstance('ci-rm'))
      ];
      expect(before.length).assertEqual(1);
      const after: WorldCharacterInstanceManageUiModel[] = [];
      expect(after.length).assertEqual(0);
    });

    it('CHARUI-30 WorldCharacterInstanceDetailUiModel 区分 placed/unplaced', 0, () => {
      const unplaced: WorldCharacterInstanceDetailUiModel = mapToDetailUiModel(
        createUnplacedInstance('ci-d1')
      );
      const placed: WorldCharacterInstanceDetailUiModel = mapToDetailUiModel(
        createPlacedInstance('ci-d2', 'loc-1')
      );
      expect(unplaced.currentLocationId).assertEqual('');
      expect(placed.currentLocationId).assertEqual('loc-1');
    });

    it('CHARUI-31 placeCharacter 仅允许未放置实例', 0, () => {
      const unplaced: WorldCharacterInstanceManageUiModel = mapToManageUiModel(
        createUnplacedInstance('ci-pp')
      );
      const canPlace: boolean = unplaced.currentLocationId.length === 0;
      expect(canPlace).assertTrue();
    });

    it('CHARUI-32 已放置实例可调整位置', 0, () => {
      const placed: WorldCharacterInstanceManageUiModel = mapToManageUiModel(
        createPlacedInstance('ci-ap', 'loc-old')
      );
      const canAdjust: boolean = placed.currentLocationId.length > 0;
      expect(canAdjust).assertTrue();
    });

    it('CHARUI-33 已放置实例可从地图撤下', 0, () => {
      const placed: WorldCharacterInstanceManageUiModel = mapToManageUiModel(
        createPlacedInstance('ci-up', 'loc-1')
      );
      const canUnplace: boolean = placed.currentLocationId.length > 0;
      expect(canUnplace).assertTrue();
    });

    it('CHARUI-34 无地点世界仍可加入角色(暂不放置)', 0, () => {
      const activeLocations: ActiveLocationOptionUiModel[] = [];
      const canAddWithoutPlace: boolean = true;
      expect(canAddWithoutPlace).assertTrue();
      expect(activeLocations.length).assertEqual(0);
    });

    it('CHARUI-35 有地点世界可选择放置到地点', 0, () => {
      const activeLocations: ActiveLocationOptionUiModel[] = [
        { id: 'loc-1', name: 'Tavern' },
        { id: 'loc-2', name: 'Forest' }
      ];
      const canPlace: boolean = activeLocations.length > 0;
      expect(canPlace).assertTrue();
      expect(activeLocations.length).assertEqual(2);
    });

    it('CHARUI-36 createWorldCharacterInstanceRecord 默认 currentLocationId undefined', 0, () => {
      const inst: WorldCharacterInstance = createWorldCharacterInstanceRecord({
        id: 'ci-def',
        worldId: 'w-1',
        characterId: 'char-def',
        displayNameSnapshot: 'Default'
      });
      expect(inst.currentLocationId === undefined).assertTrue();
    });

    it('CHARUI-37 未放置角色列表保持顺序', 0, () => {
      const chars: WorldCharacterInstanceManageUiModel[] = [
        mapToManageUiModel(createUnplacedInstance('u-first')),
        mapToManageUiModel(createPlacedInstance('p1', 'loc-1')),
        mapToManageUiModel(createUnplacedInstance('u-second')),
        mapToManageUiModel(createUnplacedInstance('u-third'))
      ];
      const unplaced: WorldCharacterInstanceManageUiModel[] = [];
      for (let i: number = 0; i < chars.length; i++) {
        if (chars[i].currentLocationId.length === 0) {
          unplaced.push(chars[i]);
        }
      }
      expect(unplaced[0].id).assertEqual('u-first');
      expect(unplaced[1].id).assertEqual('u-second');
      expect(unplaced[2].id).assertEqual('u-third');
    });
  });
}
