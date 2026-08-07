import { describe, it, expect } from '@ohos/hypium';
import {
  computeBillboardLayout,
  computeBillboardOffsets,
  computeFocusTarget,
  computeViewportForFocus,
  BillboardLayout,
  BillboardOffset,
  FocusTarget,
  ImmersiveMapViewport
} from '../main/ets/viewmodels/world/WorldImmersiveMapLayout';
import { WorldCharacterInstanceUiModel } from '../main/ets/viewmodels/world/WorldUiModels';
import { WorldLocationMapPlacement } from '../main/ets/models/world/WorldLocationMapPlacement';

function makeChar(id: string, locId: string, active: boolean): WorldCharacterInstanceUiModel {
  return {
    id: id,
    characterId: 'char-' + id,
    displayName: 'Char' + id,
    isActive: active,
    currentLocationId: locId,
    currentLocationName: locId,
    locationMissing: false,
    characterCardMissing: false,
    avatarUri: '',
    fallbackName: 'C',
    createdAt: 1000
  };
}

function makePlacement(locationId: string, x: number, y: number): WorldLocationMapPlacement {
  return {
    id: 'world-map-placement-test-' + locationId,
    worldId: 'w1',
    locationId: locationId,
    positionX: x,
    positionY: y,
    positionZ: 0,
    rotationX: 0,
    rotationY: 0,
    rotationZ: 0,
    scale: 1,
    createdAt: 1000,
    updatedAt: 1000
  };
}

export default function mapBillboardLayoutTest(): void {
  describe('MapBillboardLayout', () => {
    it('MAPUI-15_computeBillboardOffsets_0_returns_empty', 0, () => {
      const offsets: BillboardOffset[] = computeBillboardOffsets(0);
      expect(offsets.length).assertEqual(0);
    });

    it('MAPUI-16_computeBillboardOffsets_1_returns_centered', 0, () => {
      const offsets: BillboardOffset[] = computeBillboardOffsets(1);
      expect(offsets.length).assertEqual(1);
      expect(offsets[0].dx).assertEqual(0);
      expect(offsets[0].dy).assertEqual(0);
    });

    it('MAPUI-17_computeBillboardOffsets_2_returns_spread', 0, () => {
      const offsets: BillboardOffset[] = computeBillboardOffsets(2);
      expect(offsets.length).assertEqual(2);
      expect(offsets[0].dx < 0).assertTrue();
      expect(offsets[1].dx > 0).assertTrue();
    });

    it('MAPUI-18_computeBillboardOffsets_3_returns_arc', 0, () => {
      const offsets: BillboardOffset[] = computeBillboardOffsets(3);
      expect(offsets.length).assertEqual(3);
    });

    it('MAPUI-19_computeBillboardOffsets_4_returns_two_rows', 0, () => {
      const offsets: BillboardOffset[] = computeBillboardOffsets(4);
      expect(offsets.length).assertEqual(4);
    });

    it('MAPUI-20_computeBillboardLayout_filters_by_location', 0, () => {
      const chars: WorldCharacterInstanceUiModel[] = [
        makeChar('i1', 'locA', true),
        makeChar('i2', 'locB', true),
        makeChar('i3', 'locA', false)
      ];
      const layout: BillboardLayout = computeBillboardLayout('locA', chars);
      expect(layout.visibleCharacters.length).assertEqual(3);
      expect(layout.overflowCount).assertEqual(0);
    });

    it('MAPUI-21_computeBillboardLayout_overflow_when_exceeds_max', 0, () => {
      const chars: WorldCharacterInstanceUiModel[] = [];
      for (let i: number = 0; i < 7; i++) {
        chars.push(makeChar('i' + i.toString(), 'locA', i === 0));
      }
      const layout: BillboardLayout = computeBillboardLayout('locA', chars);
      expect(layout.visibleCharacters.length).assertEqual(4);
      expect(layout.overflowCount).assertEqual(3);
    });

    it('MAPUI-22_computeBillboardLayout_empty_when_no_chars', 0, () => {
      const layout: BillboardLayout = computeBillboardLayout('locA', []);
      expect(layout.visibleCharacters.length).assertEqual(0);
      expect(layout.overflowCount).assertEqual(0);
    });
  });
}
