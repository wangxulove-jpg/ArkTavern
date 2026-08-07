import { describe, it, expect } from '@ohos/hypium';
import {
  clampZoom,
  createDefaultViewport,
  computeFocusTarget,
  computeViewportForFocus,
  worldToScreen,
  screenToWorld,
  ImmersiveMapViewport,
  FocusTarget
} from '../main/ets/viewmodels/world/WorldImmersiveMapLayout';
import { WorldLocationMapPlacement } from '../main/ets/models/world/WorldLocationMapPlacement';
import { WorldLocationNodeLayout } from '../main/ets/viewmodels/world/WorldLocationGraphLayout';

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

function makeGraphNode(locationId: string, x: number, y: number): WorldLocationNodeLayout {
  return { locationId: locationId, x: x, y: y, width: 140, height: 80, depth: 0, layerIndex: 0 };
}

export default function mapViewportAndFocusTest(): void {
  describe('MapViewportAndFocus', () => {
    it('MAPUI-23_createDefaultViewport_has_zero_offset_and_zoom1', 0, () => {
      const vp: ImmersiveMapViewport = createDefaultViewport();
      expect(vp.offsetX).assertEqual(0);
      expect(vp.offsetY).assertEqual(0);
      expect(vp.zoom).assertEqual(1.0);
    });

    it('MAPUI-24_computeFocusTarget_finds_placement', 0, () => {
      const placements: WorldLocationMapPlacement[] = [
        makePlacement('l1', 100, 200),
        makePlacement('l2', 300, 400)
      ];
      const target: FocusTarget | null = computeFocusTarget('l1', placements, []);
      expect(target !== null).assertTrue();
      if (target !== null) {
        expect(target.worldX).assertEqual(100);
        expect(target.worldY).assertEqual(200);
      }
    });

    it('MAPUI-25_computeFocusTarget_falls_back_to_graph_layout', 0, () => {
      const graphNodes: WorldLocationNodeLayout[] = [
        makeGraphNode('l1', 50, 60)
      ];
      const target: FocusTarget | null = computeFocusTarget('l1', [], graphNodes);
      expect(target !== null).assertTrue();
      if (target !== null) {
        expect(target.worldX).assertEqual(50 + 70);
        expect(target.worldY).assertEqual(60 + 40);
      }
    });

    it('MAPUI-26_computeFocusTarget_returns_null_for_unknown', 0, () => {
      const target: FocusTarget | null = computeFocusTarget('unknown', [], []);
      expect(target === null).assertTrue();
    });

    it('MAPUI-27_computeFocusTarget_prefers_placement_over_graph', 0, () => {
      const placements: WorldLocationMapPlacement[] = [makePlacement('l1', 999, 888)];
      const graphNodes: WorldLocationNodeLayout[] = [makeGraphNode('l1', 50, 60)];
      const target: FocusTarget | null = computeFocusTarget('l1', placements, graphNodes);
      expect(target !== null).assertTrue();
      if (target !== null) {
        expect(target.worldX).assertEqual(999);
        expect(target.worldY).assertEqual(888);
      }
    });

    it('MAPUI-28_computeViewportForFocus_centers_target', 0, () => {
      const target: FocusTarget = { worldX: 200, worldY: 300 };
      const vp: ImmersiveMapViewport = computeViewportForFocus(target, 800, 600, 1.0);
      expect(vp.offsetX).assertEqual(800 / 2 - 200);
      expect(vp.offsetY).assertEqual(600 / 2 - 300);
      expect(vp.zoom).assertEqual(1.0);
    });

    it('MAPUI-29_computeViewportForFocus_clamps_zoom', 0, () => {
      const target: FocusTarget = { worldX: 0, worldY: 0 };
      const vp: ImmersiveMapViewport = computeViewportForFocus(target, 800, 600, 99);
      expect(vp.zoom <= 1.80).assertTrue();
    });

    it('MAPUI-30_screenToWorld_with_zoom_2', 0, () => {
      const vp: ImmersiveMapViewport = { offsetX: 0, offsetY: 0, zoom: 2.0 };
      const world: number[] = screenToWorld(200, 400, vp);
      expect(world[0]).assertEqual(100);
      expect(world[1]).assertEqual(200);
    });

    it('MAPUI-31_screenToWorld_with_offset', 0, () => {
      const vp: ImmersiveMapViewport = { offsetX: 100, offsetY: 50, zoom: 1.0 };
      const world: number[] = screenToWorld(150, 80, vp);
      expect(world[0]).assertEqual(50);
      expect(world[1]).assertEqual(30);
    });

    it('MAPUI-32_worldToScreen_screenToWorld_roundtrip_zoomed', 0, () => {
      const vp: ImmersiveMapViewport = { offsetX: 123, offsetY: -45, zoom: 1.5 };
      const wx: number = 250;
      const wy: number = 380;
      const screen: number[] = worldToScreen(wx, wy, vp);
      const back: number[] = screenToWorld(screen[0], screen[1], vp);
      expect(Math.abs(back[0] - wx) < 0.001).assertTrue();
      expect(Math.abs(back[1] - wy) < 0.001).assertTrue();
    });
  });
}
