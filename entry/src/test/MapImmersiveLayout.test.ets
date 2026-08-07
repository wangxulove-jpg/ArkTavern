import { describe, it, expect } from '@ohos/hypium';
import {
  clampZoom,
  createDefaultViewport,
  worldToScreen,
  screenToWorld,
  boundedVisualFactor,
  computeImmersiveMapLayout,
  computeFocusTarget,
  MIN_ZOOM,
  MAX_ZOOM,
  DEFAULT_ZOOM,
  ImmersiveMapViewport,
  BoundedVisualFactor,
  MapNodeScreenLayout,
  ImmersiveMapLayout
} from '../main/ets/viewmodels/world/WorldImmersiveMapLayout';
import { WorldLocationUiModel, WorldEdgeUiModel } from '../main/ets/viewmodels/world/WorldUiModels';
import { WorldLocationMapPlacement } from '../main/ets/models/world/WorldLocationMapPlacement';
import { WorldLocationStatus } from '../main/ets/models/world/WorldLocation';

function makePlacement(locationId: string, x: number, y: number, z: number): WorldLocationMapPlacement {
  return {
    id: 'world-map-placement-test-' + locationId,
    worldId: 'w1',
    locationId: locationId,
    positionX: x,
    positionY: y,
    positionZ: z,
    rotationX: 0,
    rotationY: 0,
    rotationZ: 0,
    scale: 1,
    createdAt: 1000,
    updatedAt: 1000
  };
}

function makeLocation(id: string, name: string): WorldLocationUiModel {
  return { id: id, name: name, description: '', status: WorldLocationStatus.Active, createdAt: 1000 };
}

function makeEdge(id: string, from: string, to: string): WorldEdgeUiModel {
  return {
    id: id,
    fromLocationId: from,
    toLocationId: to,
    fromLocationName: from,
    toLocationName: to,
    fromLocationMissing: false,
    toLocationMissing: false,
    directionLabel: '',
    travelDescription: '',
    isBidirectional: true,
    isEnabled: true,
    isAnomalous: false
  };
}

export default function mapImmersiveLayoutTest(): void {
  describe('MapImmersiveLayout', () => {
    it('MAPUI-01_clampZoom_clamps_below_min', 0, () => {
      expect(clampZoom(0.1)).assertEqual(MIN_ZOOM);
    });

    it('MAPUI-02_clampZoom_clamps_above_max', 0, () => {
      expect(clampZoom(5.0)).assertEqual(MAX_ZOOM);
    });

    it('MAPUI-03_clampZoom_returns_default_for_NaN', 0, () => {
      expect(clampZoom(NaN)).assertEqual(DEFAULT_ZOOM);
    });

    it('MAPUI-04_clampZoom_returns_default_for_Infinity', 0, () => {
      expect(clampZoom(Infinity)).assertEqual(DEFAULT_ZOOM);
      expect(clampZoom(-Infinity)).assertEqual(DEFAULT_ZOOM);
    });

    it('MAPUI-05_clampZoom_passes_valid_zoom', 0, () => {
      expect(clampZoom(1.0)).assertEqual(1.0);
      expect(clampZoom(0.65)).assertEqual(0.65);
      expect(clampZoom(1.80)).assertEqual(1.80);
    });

    it('MAPUI-06_worldToScreen_identity_viewport', 0, () => {
      const vp: ImmersiveMapViewport = createDefaultViewport();
      const result: number[] = worldToScreen(100, 200, vp);
      expect(result[0]).assertEqual(100);
      expect(result[1]).assertEqual(200);
    });

    it('MAPUI-07_worldToScreen_with_zoom_and_offset', 0, () => {
      const vp: ImmersiveMapViewport = { offsetX: 50, offsetY: 30, zoom: 2.0 };
      const result: number[] = worldToScreen(100, 200, vp);
      expect(result[0]).assertEqual(250);
      expect(result[1]).assertEqual(430);
    });

    it('MAPUI-08_screenToWorld_inverse_of_worldToScreen', 0, () => {
      const vp: ImmersiveMapViewport = { offsetX: 50, offsetY: 30, zoom: 2.0 };
      const screen: number[] = worldToScreen(100, 200, vp);
      const world: number[] = screenToWorld(screen[0], screen[1], vp);
      expect(world[0]).assertEqual(100);
      expect(world[1]).assertEqual(200);
    });

    it('MAPUI-09_boundedVisualFactor_zero_z_gives_mid_range', 0, () => {
      const vf: BoundedVisualFactor = boundedVisualFactor(0);
      expect(vf.scale > 0).assertTrue();
      expect(vf.opacity > 0).assertTrue();
      expect(vf.zIndex).assertEqual(0);
    });

    it('MAPUI-10_boundedVisualFactor_NaN_gives_default', 0, () => {
      const vf: BoundedVisualFactor = boundedVisualFactor(NaN);
      expect(vf.scale).assertEqual(1.0);
      expect(vf.opacity).assertEqual(1.0);
      expect(vf.zIndex).assertEqual(0);
    });

    it('MAPUI-11_boundedVisualFactor_max_z_gives_max_scale', 0, () => {
      const vf: BoundedVisualFactor = boundedVisualFactor(5);
      expect(vf.scale > 1.0).assertTrue();
      expect(vf.opacity).assertEqual(1.0);
    });

    it('MAPUI-12_boundedVisualFactor_min_z_gives_min_scale', 0, () => {
      const vf: BoundedVisualFactor = boundedVisualFactor(-5);
      expect(vf.scale < 1.0).assertTrue();
      expect(vf.opacity < 1.0).assertTrue();
    });

    it('MAPUI-13_computeImmersiveMapLayout_with_placements', 0, () => {
      const locs: WorldLocationUiModel[] = [makeLocation('l1', 'A'), makeLocation('l2', 'B')];
      const placements: WorldLocationMapPlacement[] = [
        makePlacement('l1', 100, 200, 0),
        makePlacement('l2', 400, 300, 1)
      ];
      const layout: ImmersiveMapLayout = computeImmersiveMapLayout(locs, [], placements, [], createDefaultViewport());
      expect(layout.nodes.length).assertEqual(2);
      expect(layout.edges.length).assertEqual(0);
      expect(layout.canvasWidth > 0).assertTrue();
      expect(layout.canvasHeight > 0).assertTrue();
    });

    it('MAPUI-14_computeImmersiveMapLayout_graph_fallback_when_no_placements', 0, () => {
      const locs: WorldLocationUiModel[] = [makeLocation('l1', 'A'), makeLocation('l2', 'B')];
      const edges: WorldEdgeUiModel[] = [makeEdge('e1', 'l1', 'l2')];
      const layout: ImmersiveMapLayout = computeImmersiveMapLayout(locs, edges, [], [], createDefaultViewport());
      expect(layout.nodes.length).assertEqual(2);
      expect(layout.edges.length).assertEqual(1);
    });
  });
}
