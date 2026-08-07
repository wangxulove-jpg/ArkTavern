import { describe, it, expect } from '@ohos/hypium';
import {
  WorldLocationMapPlacement,
  createWorldLocationMapPlacementRecord,
  validatePlacementNumbers,
  WORLD_MAP_PLACEMENT_ID_PREFIX
} from '../../../main/ets/models/world/WorldLocationMapPlacement';

export default function mapPlacementModelContractTest(): void {
  describe('MAPCONTRACT 模型契约', () => {

    it('MAPCONTRACT-01 createWorldLocationMapPlacementRecord 正常创建含默认值', 0, () => {
      const p: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: 'world-map-placement-aaa',
        worldId: 'world-1',
        locationId: 'loc-1',
        positionX: 1.0,
        positionY: 2.0,
        positionZ: 3.0
      });
      expect(p.id).assertEqual('world-map-placement-aaa');
      expect(p.worldId).assertEqual('world-1');
      expect(p.locationId).assertEqual('loc-1');
      expect(p.positionX).assertEqual(1.0);
      expect(p.positionY).assertEqual(2.0);
      expect(p.positionZ).assertEqual(3.0);
      expect(p.rotationX).assertEqual(0);
      expect(p.rotationY).assertEqual(0);
      expect(p.rotationZ).assertEqual(0);
      expect(p.scale).assertEqual(1);
      expect(p.createdAt > 0).assertTrue();
      expect(p.updatedAt > 0).assertTrue();
    });

    it('MAPCONTRACT-02 createWorldLocationMapPlacementRecord 显式 rotation 和 scale', 0, () => {
      const p: WorldLocationMapPlacement = createWorldLocationMapPlacementRecord({
        id: 'world-map-placement-bbb',
        worldId: 'world-1',
        locationId: 'loc-1',
        positionX: 0,
        positionY: 0,
        positionZ: 0,
        rotationX: 1.57,
        rotationY: -0.5,
        rotationZ: 3.14,
        scale: 2.5
      });
      expect(p.rotationX).assertEqual(1.57);
      expect(p.rotationY).assertEqual(-0.5);
      expect(p.rotationZ).assertEqual(3.14);
      expect(p.scale).assertEqual(2.5);
    });

    it('MAPCONTRACT-03 ID 前缀为 world-map-placement-', 0, () => {
      expect(WORLD_MAP_PLACEMENT_ID_PREFIX).assertEqual('world-map-placement-');
    });

    it('MAPCONTRACT-04 空 id 抛错', 0, () => {
      try {
        createWorldLocationMapPlacementRecord({
          id: '',
          worldId: 'world-1',
          locationId: 'loc-1',
          positionX: 0,
          positionY: 0,
          positionZ: 0
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('MAPCONTRACT-05 空 worldId 抛错', 0, () => {
      try {
        createWorldLocationMapPlacementRecord({
          id: 'world-map-placement-1',
          worldId: '',
          locationId: 'loc-1',
          positionX: 0,
          positionY: 0,
          positionZ: 0
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('MAPCONTRACT-06 空 locationId 抛错', 0, () => {
      try {
        createWorldLocationMapPlacementRecord({
          id: 'world-map-placement-1',
          worldId: 'world-1',
          locationId: '',
          positionX: 0,
          positionY: 0,
          positionZ: 0
        });
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('MAPCONTRACT-07 NaN positionX 抛错', 0, () => {
      try {
        validatePlacementNumbers(NaN, 0, 0, 0, 0, 0, 1);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('MAPCONTRACT-08 Infinity positionY 抛错', 0, () => {
      try {
        validatePlacementNumbers(0, Infinity, 0, 0, 0, 0, 1);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('MAPCONTRACT-09 -Infinity rotationZ 抛错', 0, () => {
      try {
        validatePlacementNumbers(0, 0, 0, 0, 0, -Infinity, 1);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('MAPCONTRACT-10 scale = 0 抛错', 0, () => {
      try {
        validatePlacementNumbers(0, 0, 0, 0, 0, 0, 0);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('MAPCONTRACT-11 scale 为负数抛错', 0, () => {
      try {
        validatePlacementNumbers(0, 0, 0, 0, 0, 0, -1.5);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });

    it('MAPCONTRACT-12 scale 为 NaN 抛错', 0, () => {
      try {
        validatePlacementNumbers(0, 0, 0, 0, 0, 0, NaN);
        expect(true).assertFalse();
      } catch (err) {
        expect(true).assertTrue();
      }
    });
  });
}
