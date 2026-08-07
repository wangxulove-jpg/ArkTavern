import { describe, it, expect } from '@ohos/hypium';
import {
  WorldImmersiveMapViewModel,
  MapEditMode,
  MapLoadState,
  MapInteractionPort
} from '../main/ets/viewmodels/world/WorldImmersiveMapViewModel';
import {
  MapSnapshotResult,
  SavePlacementResult
} from '../main/ets/services/world/WorldMapInteractionService';
import { WorldLocationMapPlacement } from '../main/ets/models/world/WorldLocationMapPlacement';
import { World, WorldStatus } from '../main/ets/models/world/World';
import { WorldLocation, WorldLocationStatus } from '../main/ets/models/world/WorldLocation';
import { Character } from '../main/ets/models/Character';

class FakeInteractionService implements MapInteractionPort {
  private snapshotResult: MapSnapshotResult | null = null;
  private saveResult: SavePlacementResult = { success: true, placement: null, errorMessage: '' };
  private loadError: Error | null = null;

  setSnapshot(result: MapSnapshotResult): void {
    this.snapshotResult = result;
  }

  setSaveResult(result: SavePlacementResult): void {
    this.saveResult = result;
  }

  setLoadError(err: Error): void {
    this.loadError = err;
  }

  async loadMapSnapshot(worldId: string): Promise<MapSnapshotResult> {
    if (this.loadError !== null) {
      throw this.loadError;
    }
    if (this.snapshotResult !== null) {
      return this.snapshotResult;
    }
    return {
      world: { id: worldId, name: 'TestWorld', description: '', status: WorldStatus.Active, createdAt: 1000, updatedAt: 1000 },
      locations: [],
      edges: [],
      instances: [],
      placements: [],
      characterMap: new Map<string, Character | null>()
    };
  }

  async saveLocationPlacement(
    worldId: string,
    locationId: string,
    positionX: number,
    positionY: number,
    positionZ: number
  ): Promise<SavePlacementResult> {
    return this.saveResult;
  }
}

function makeWorld(id: string): World {
  return { id: id, name: 'World' + id, description: '', status: WorldStatus.Active, createdAt: 1000, updatedAt: 1000 };
}

function makeLocation(id: string, worldId: string): WorldLocation {
  return {
    id: id, worldId: worldId, name: 'Loc' + id, description: '',
    canonicalKey: 'canonical-' + id,
    status: WorldLocationStatus.Active, createdAt: 1000, updatedAt: 1000
  };
}

function makePlacement(locationId: string, worldId: string, x: number, y: number): WorldLocationMapPlacement {
  return {
    id: 'world-map-placement-test-' + locationId,
    worldId: worldId,
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

export default function mapInteractionServiceTest(): void {
  describe('MapInteractionService', () => {
    it('MAPUI-33_ViewModel_initial_state_is_Loading', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      expect(vm.state).assertEqual(MapLoadState.Loading);
      expect(vm.editMode).assertEqual(MapEditMode.Browse);
    });

    it('MAPUI-34_ViewModel_loadSnapshot_sets_Ready', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      const world: World = makeWorld('w1');
      fake.setSnapshot({
        world: world,
        locations: [makeLocation('l1', 'w1')],
        edges: [],
        instances: [],
        placements: [],
        characterMap: new Map<string, Character | null>()
      });
      vm.loadSnapshot('w1');
      expect(vm.state).assertEqual(MapLoadState.Ready);
      expect(vm.locations.length).assertEqual(1);
    });

    it('MAPUI-35_ViewModel_loadSnapshot_maps_locations_to_Ui', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      fake.setSnapshot({
        world: makeWorld('w1'),
        locations: [makeLocation('l1', 'w1'), makeLocation('l2', 'w1')],
        edges: [],
        instances: [],
        placements: [],
        characterMap: new Map<string, Character | null>()
      });
      vm.loadSnapshot('w1');
      expect(vm.locations.length).assertEqual(2);
      expect(vm.locations[0].id).assertEqual('l1');
      expect(vm.locations[1].id).assertEqual('l2');
    });

    it('MAPUI-36_ViewModel_toggleEditMode_switches_Browse_Edit', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      expect(vm.editMode).assertEqual(MapEditMode.Browse);
      vm.toggleEditMode();
      expect(vm.editMode).assertEqual(MapEditMode.Edit);
      vm.toggleEditMode();
      expect(vm.editMode).assertEqual(MapEditMode.Browse);
    });

    it('MAPUI-37_ViewModel_zoomIn_increases_zoom', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      fake.setSnapshot({
        world: makeWorld('w1'),
        locations: [makeLocation('l1', 'w1')],
        edges: [],
        instances: [],
        placements: [],
        characterMap: new Map<string, Character | null>()
      });
      vm.loadSnapshot('w1');
      const beforeZoom: number = vm.viewport.zoom;
      vm.zoomIn();
      expect(vm.viewport.zoom > beforeZoom).assertTrue();
    });

    it('MAPUI-38_ViewModel_zoomOut_decreases_zoom', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      fake.setSnapshot({
        world: makeWorld('w1'),
        locations: [makeLocation('l1', 'w1')],
        edges: [],
        instances: [],
        placements: [],
        characterMap: new Map<string, Character | null>()
      });
      vm.loadSnapshot('w1');
      vm.zoomIn();
      const beforeZoom: number = vm.viewport.zoom;
      vm.zoomOut();
      expect(vm.viewport.zoom < beforeZoom).assertTrue();
    });

    it('MAPUI-39_ViewModel_resetViewport_restores_default', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      fake.setSnapshot({
        world: makeWorld('w1'),
        locations: [makeLocation('l1', 'w1')],
        edges: [],
        instances: [],
        placements: [],
        characterMap: new Map<string, Character | null>()
      });
      vm.loadSnapshot('w1');
      vm.panBy(100, 200);
      vm.zoomIn();
      vm.resetViewport();
      expect(vm.viewport.offsetX).assertEqual(0);
      expect(vm.viewport.offsetY).assertEqual(0);
      expect(vm.viewport.zoom).assertEqual(1.0);
    });

    it('MAPUI-40_ViewModel_panBy_updates_offset', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      fake.setSnapshot({
        world: makeWorld('w1'),
        locations: [makeLocation('l1', 'w1')],
        edges: [],
        instances: [],
        placements: [],
        characterMap: new Map<string, Character | null>()
      });
      vm.loadSnapshot('w1');
      vm.panBy(50, -30);
      expect(vm.viewport.offsetX).assertEqual(50);
      expect(vm.viewport.offsetY).assertEqual(-30);
    });

    it('MAPUI-41_ViewModel_selectLocation_sets_selectedId', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      vm.selectLocation('l1');
      expect(vm.selectedLocationId).assertEqual('l1');
      vm.deselectLocation();
      expect(vm.selectedLocationId).assertEqual('');
    });

    it('MAPUI-42_ViewModel_cancelDrag_restores_original_placement', 0, () => {
      const fake: FakeInteractionService = new FakeInteractionService();
      const vm: WorldImmersiveMapViewModel = new WorldImmersiveMapViewModel(fake);
      const placement: WorldLocationMapPlacement = makePlacement('l1', 'w1', 100, 200);
      fake.setSnapshot({
        world: makeWorld('w1'),
        locations: [makeLocation('l1', 'w1')],
        edges: [],
        instances: [],
        placements: [placement],
        characterMap: new Map<string, Character | null>()
      });
      vm.loadSnapshot('w1');
      vm.beginDrag('l1');
      vm.updateDragPosition('l1', 500, 600);
      expect(vm.placements[0].positionX).assertEqual(500);
      vm.cancelDrag();
      expect(vm.placements[0].positionX).assertEqual(100);
      expect(vm.placements[0].positionY).assertEqual(200);
    });
  });
}
