/**
 * WorldImmersiveMapLayout 沉浸式地图纯逻辑布局辅助(W1D)
 *
 * 职责:
 * - 世界坐标 ↔ 屏幕坐标转换(含视口偏移和缩放)
 * - 缩放钳制(MIN_ZOOM ~ MAX_ZOOM)
 * - positionZ → boundedVisualFactor(缩放/不透明度/zIndex),禁止 NaN/Infinity/零/负缩放
 * - 焦点目标计算(选中地点居中)
 * - 边端点屏幕坐标(基于节点屏幕位置)
 * - 角色布告板偏移排列(1=居中,2=左右,3=弧形,4+=环绕/两行,最多显示+溢出计数)
 *
 * 不依赖 ArkUI / Repository / 数据库 / Context。
 */

import { WorldLocationUiModel, WorldEdgeUiModel, WorldCharacterInstanceUiModel } from './WorldUiModels';
import { WorldLocationMapPlacement } from '../../models/world/WorldLocationMapPlacement';
import { WorldLocationNodeLayout, WorldLocationEdgeLayout, computeWorldLocationGraphLayout } from './WorldLocationGraphLayout';

const MIN_ZOOM: number = 0.65;
const MAX_ZOOM: number = 1.80;
const DEFAULT_ZOOM: number = 1.0;
const NODE_VISUAL_WIDTH: number = 140;
const NODE_VISUAL_HEIGHT: number = 80;
const BILLBOARD_AVATAR_SIZE: number = 22;
const BILLBOARD_MAX_VISIBLE: number = 4;
const DEPTH_Z_MIN: number = -5;
const DEPTH_Z_MAX: number = 5;
const DEPTH_SCALE_MIN: number = 0.6;
const DEPTH_SCALE_MAX: number = 1.15;
const DEPTH_OPACITY_MIN: number = 0.5;
const DEPTH_OPACITY_MAX: number = 1.0;

export interface ImmersiveMapViewport {
  offsetX: number;
  offsetY: number;
  zoom: number;
}

export interface BoundedVisualFactor {
  readonly scale: number;
  readonly opacity: number;
  readonly zIndex: number;
}

export interface MapNodeScreenLayout {
  readonly locationId: string;
  readonly screenX: number;
  readonly screenY: number;
  readonly visualFactor: BoundedVisualFactor;
  readonly placement: WorldLocationMapPlacement | null;
}

export interface MapEdgeScreenLayout {
  readonly edgeId: string;
  readonly fromScreenX: number;
  readonly fromScreenY: number;
  readonly toScreenX: number;
  readonly toScreenY: number;
  readonly isBidirectional: boolean;
  readonly isEnabled: boolean;
}

export interface BillboardOffset {
  readonly dx: number;
  readonly dy: number;
}

export interface BillboardLayout {
  readonly visibleCharacters: BillboardCharacterSlot[];
  readonly overflowCount: number;
}

export interface BillboardCharacterSlot {
  readonly instanceId: string;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly fallbackName: string;
  readonly isActive: boolean;
  readonly dx: number;
  readonly dy: number;
}

export interface FocusTarget {
  readonly worldX: number;
  readonly worldY: number;
}

export interface ImmersiveMapLayout {
  readonly nodes: MapNodeScreenLayout[];
  readonly edges: MapEdgeScreenLayout[];
  readonly canvasWidth: number;
  readonly canvasHeight: number;
  readonly viewport: ImmersiveMapViewport;
}

export function clampZoom(zoom: number): number {
  if (!Number.isFinite(zoom)) {
    return DEFAULT_ZOOM;
  }
  if (zoom < MIN_ZOOM) {
    return MIN_ZOOM;
  }
  if (zoom > MAX_ZOOM) {
    return MAX_ZOOM;
  }
  return zoom;
}

export function createDefaultViewport(): ImmersiveMapViewport {
  return { offsetX: 0, offsetY: 0, zoom: DEFAULT_ZOOM };
}

export function worldToScreen(
  worldX: number,
  worldY: number,
  viewport: ImmersiveMapViewport
): number[] {
  const sx: number = worldX * viewport.zoom + viewport.offsetX;
  const sy: number = worldY * viewport.zoom + viewport.offsetY;
  return [sx, sy];
}

export function screenToWorld(
  screenX: number,
  screenY: number,
  viewport: ImmersiveMapViewport
): number[] {
  const wx: number = (screenX - viewport.offsetX) / viewport.zoom;
  const wy: number = (screenY - viewport.offsetY) / viewport.zoom;
  return [wx, wy];
}

export function boundedVisualFactor(positionZ: number): BoundedVisualFactor {
  if (!Number.isFinite(positionZ)) {
    return { scale: 1.0, opacity: 1.0, zIndex: 0 };
  }
  const clampedZ: number = Math.max(DEPTH_Z_MIN, Math.min(DEPTH_Z_MAX, positionZ));
  const t: number = (clampedZ - DEPTH_Z_MIN) / (DEPTH_Z_MAX - DEPTH_Z_MIN);
  const scale: number = DEPTH_SCALE_MIN + t * (DEPTH_SCALE_MAX - DEPTH_SCALE_MIN);
  const opacity: number = DEPTH_OPACITY_MIN + t * (DEPTH_OPACITY_MAX - DEPTH_OPACITY_MIN);
  const zIndex: number = Math.round(clampedZ * 10);
  return {
    scale: Number.isFinite(scale) && scale > 0 ? scale : 1.0,
    opacity: Number.isFinite(opacity) ? opacity : 1.0,
    zIndex: zIndex
  };
}

export function computeFocusTarget(
  locationId: string,
  placements: WorldLocationMapPlacement[],
  fallbackGraphLayout: WorldLocationNodeLayout[]
): FocusTarget | null {
  for (let i: number = 0; i < placements.length; i++) {
    if (placements[i].locationId === locationId) {
      return { worldX: placements[i].positionX, worldY: placements[i].positionY };
    }
  }
  for (let i: number = 0; i < fallbackGraphLayout.length; i++) {
    if (fallbackGraphLayout[i].locationId === locationId) {
      const cx: number = fallbackGraphLayout[i].x + fallbackGraphLayout[i].width / 2;
      const cy: number = fallbackGraphLayout[i].y + fallbackGraphLayout[i].height / 2;
      return { worldX: cx, worldY: cy };
    }
  }
  return null;
}

export function computeViewportForFocus(
  target: FocusTarget,
  containerWidth: number,
  containerHeight: number,
  zoom: number
): ImmersiveMapViewport {
  const clamped: number = clampZoom(zoom);
  const offsetX: number = containerWidth / 2 - target.worldX * clamped;
  const offsetY: number = containerHeight / 2 - target.worldY * clamped;
  return { offsetX: offsetX, offsetY: offsetY, zoom: clamped };
}

export function computeBillboardLayout(
  locationId: string,
  characters: WorldCharacterInstanceUiModel[]
): BillboardLayout {
  const atLocation: WorldCharacterInstanceUiModel[] = [];
  for (let i: number = 0; i < characters.length; i++) {
    if (characters[i].currentLocationId === locationId) {
      atLocation.push(characters[i]);
    }
  }
  const visibleCount: number = Math.min(atLocation.length, BILLBOARD_MAX_VISIBLE);
  const overflowCount: number = atLocation.length > BILLBOARD_MAX_VISIBLE
    ? atLocation.length - BILLBOARD_MAX_VISIBLE : 0;
  const offsets: BillboardOffset[] = computeBillboardOffsets(visibleCount);
  const slots: BillboardCharacterSlot[] = [];
  for (let i: number = 0; i < visibleCount; i++) {
    const c: WorldCharacterInstanceUiModel = atLocation[i];
    slots.push({
      instanceId: c.id,
      displayName: c.displayName,
      avatarUri: c.avatarUri,
      fallbackName: c.fallbackName,
      isActive: c.isActive,
      dx: offsets[i].dx,
      dy: offsets[i].dy
    });
  }
  return { visibleCharacters: slots, overflowCount: overflowCount };
}

export function computeBillboardOffsets(count: number): BillboardOffset[] {
  if (count <= 0) {
    return [];
  }
  const halfAvatar: number = BILLBOARD_AVATAR_SIZE / 2;
  if (count === 1) {
    return [{ dx: 0, dy: 0 }];
  }
  if (count === 2) {
    const spread: number = halfAvatar + 2;
    return [{ dx: -spread, dy: 0 }, { dx: spread, dy: 0 }];
  }
  if (count === 3) {
    const r: number = halfAvatar + 4;
    const angles: number[] = [-Math.PI / 4, 0, Math.PI / 4];
    const result: BillboardOffset[] = [];
    for (let i: number = 0; i < 3; i++) {
      result.push({
        dx: Math.round(r * Math.cos(angles[i])),
        dy: Math.round(-r * Math.abs(Math.sin(angles[i])))
      });
    }
    return result;
  }
  const r: number = halfAvatar + 6;
  const halfCount: number = Math.ceil(count / 2);
  const result: BillboardOffset[] = [];
  for (let row: number = 0; row < 2; row++) {
    const rowCount: number = row === 0 ? halfCount : count - halfCount;
    for (let col: number = 0; col < rowCount; col++) {
      const xSpread: number = BILLBOARD_AVATAR_SIZE + 2;
      const totalWidth: number = (rowCount - 1) * xSpread;
      const dx: number = -totalWidth / 2 + col * xSpread;
      const dy: number = row === 0 ? -r : 0;
      result.push({ dx: Math.round(dx), dy: Math.round(dy) });
    }
  }
  return result;
}

export function computeImmersiveMapLayout(
  locations: WorldLocationUiModel[],
  edges: WorldEdgeUiModel[],
  placements: WorldLocationMapPlacement[],
  characters: WorldCharacterInstanceUiModel[],
  viewport: ImmersiveMapViewport
): ImmersiveMapLayout {
  const graphLayout: WorldLocationNodeLayout[] = [];
  if (placements.length === 0) {
    const fullLayout = computeWorldLocationGraphLayout(locations, edges);
    for (let i: number = 0; i < fullLayout.nodes.length; i++) {
      graphLayout.push(fullLayout.nodes[i]);
    }
  }

  const placementMap: Map<string, WorldLocationMapPlacement> = new Map<string, WorldLocationMapPlacement>();
  for (let i: number = 0; i < placements.length; i++) {
    placementMap.set(placements[i].locationId, placements[i]);
  }

  const nodeMap: Map<string, WorldLocationNodeLayout> = new Map<string, WorldLocationNodeLayout>();
  for (let i: number = 0; i < graphLayout.length; i++) {
    nodeMap.set(graphLayout[i].locationId, graphLayout[i]);
  }

  const allLocationIds: Set<string> = new Set<string>();
  for (let i: number = 0; i < locations.length; i++) {
    allLocationIds.add(locations[i].id);
  }

  const nodeScreenLayouts: MapNodeScreenLayout[] = [];
  let canvasWidth: number = 0;
  let canvasHeight: number = 0;

  for (let i: number = 0; i < locations.length; i++) {
    const loc: WorldLocationUiModel = locations[i];
    const placement: WorldLocationMapPlacement | undefined = placementMap.get(loc.id);
    let worldX: number;
    let worldY: number;
    let positionZ: number;
    if (placement !== undefined) {
      worldX = placement.positionX;
      worldY = placement.positionY;
      positionZ = placement.positionZ;
    } else {
      const graphNode: WorldLocationNodeLayout | undefined = nodeMap.get(loc.id);
      if (graphNode !== undefined) {
        worldX = graphNode.x + graphNode.width / 2;
        worldY = graphNode.y + graphNode.height / 2;
        positionZ = 0;
      } else {
        worldX = 100 + i * 180;
        worldY = 100 + Math.floor(i / 3) * 160;
        positionZ = 0;
      }
    }
    const screen: number[] = worldToScreen(worldX, worldY, viewport);
    const vf: BoundedVisualFactor = boundedVisualFactor(positionZ);
    nodeScreenLayouts.push({
      locationId: loc.id,
      screenX: screen[0],
      screenY: screen[1],
      visualFactor: vf,
      placement: placement !== undefined ? placement : null
    });
    const right: number = screen[0] + NODE_VISUAL_WIDTH * vf.scale;
    const bottom: number = screen[1] + NODE_VISUAL_HEIGHT * vf.scale;
    if (right > canvasWidth) {
      canvasWidth = right;
    }
    if (bottom > canvasHeight) {
      canvasHeight = bottom;
    }
  }

  const nodeScreenMap: Map<string, MapNodeScreenLayout> = new Map<string, MapNodeScreenLayout>();
  for (let i: number = 0; i < nodeScreenLayouts.length; i++) {
    nodeScreenMap.set(nodeScreenLayouts[i].locationId, nodeScreenLayouts[i]);
  }

  const edgeScreenLayouts: MapEdgeScreenLayout[] = [];
  for (let i: number = 0; i < edges.length; i++) {
    const edge: WorldEdgeUiModel = edges[i];
    if (edge.isAnomalous || edge.fromLocationMissing || edge.toLocationMissing) {
      continue;
    }
    const fromNode: MapNodeScreenLayout | undefined = nodeScreenMap.get(edge.fromLocationId);
    const toNode: MapNodeScreenLayout | undefined = nodeScreenMap.get(edge.toLocationId);
    if (fromNode === undefined || toNode === undefined) {
      continue;
    }
    edgeScreenLayouts.push({
      edgeId: edge.id,
      fromScreenX: fromNode.screenX,
      fromScreenY: fromNode.screenY + NODE_VISUAL_HEIGHT * fromNode.visualFactor.scale / 2,
      toScreenX: toNode.screenX,
      toScreenY: toNode.screenY - NODE_VISUAL_HEIGHT * toNode.visualFactor.scale / 2,
      isBidirectional: edge.isBidirectional,
      isEnabled: edge.isEnabled
    });
  }

  return {
    nodes: nodeScreenLayouts,
    edges: edgeScreenLayouts,
    canvasWidth: canvasWidth + 40,
    canvasHeight: canvasHeight + 40,
    viewport: viewport
  };
}

export { MIN_ZOOM, MAX_ZOOM, DEFAULT_ZOOM, BILLBOARD_MAX_VISIBLE };
