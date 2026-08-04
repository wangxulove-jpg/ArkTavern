/**
 * WorldLocationGraphLayout 地点节点关系图确定性布局算法(W-UI-1)
 *
 * 纯逻辑布局,不依赖 ArkUI / Repository / 数据库 / Context。
 * 由 WorldDetailViewModel 调用,输入已映射的 UI 模型,输出节点坐标和边坐标。
 *
 * 布局策略(确定性,无随机性,无物理模拟):
 * 1. 按 createdAt ASC 排序地点(由 Repository 保证,本算法再次保险排序)
 * 2. 构建无向邻接关系(忽略异常边)
 * 3. 排除异常边:端点不存在 / 自连接 / worldId 不一致 / 完全重复
 * 4. 找出所有连通分量,每个分量选第一个 Active 地点作根节点;
 *    若该分量无 Active 节点,选第一个节点
 * 5. BFS 分层,同层节点按 createdAt ASC
 * 6. 多个连通分量依次纵向堆叠
 * 7. 无连接节点放在独立区域(最下方)
 * 8. 生成稳定 x/y UI 坐标
 *
 * 输出坐标语义:
 * - 节点 x/y 为左上角坐标
 * - 边 fromX/fromY 为起点节点底部中心,toX/toY 为终点节点顶部中心
 */

import { WorldLocationUiModel, WorldEdgeUiModel } from './WorldUiModels';
import { WorldLocationStatus } from '../../models/world/WorldLocation';

/** 节点布局结果 */
export interface WorldLocationNodeLayout {
  readonly locationId: string;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  readonly depth: number;
  /** 在同层中的索引(0 起) */
  readonly layerIndex: number;
}

/** 边布局结果(已解析端点坐标) */
export interface WorldLocationEdgeLayout {
  readonly edgeId: string;
  readonly fromLocationId: string;
  readonly toLocationId: string;
  readonly fromX: number;
  readonly fromY: number;
  readonly toX: number;
  readonly toY: number;
  readonly isBidirectional: boolean;
  readonly isEnabled: boolean;
}

/** 完整图布局结果 */
export interface WorldLocationGraphLayout {
  readonly nodes: WorldLocationNodeLayout[];
  readonly edges: WorldLocationEdgeLayout[];
  readonly canvasWidth: number;
  readonly canvasHeight: number;
  readonly anomalousEdgeCount: number;
}

/** BFS 队列项(内部使用) */
interface BfsQueueItem {
  id: string;
  depth: number;
}

/** 布局常量(单位 vp) */
const NODE_WIDTH: number = 140;
const NODE_HEIGHT: number = 80;
const H_GAP: number = 28;
const V_GAP: number = 64;
const PADDING: number = 24;
const COMPONENT_GAP: number = 36;

/**
 * 计算地点节点关系图的确定性布局。
 *
 * @param locations 已按 createdAt ASC 排序的地点列表(本算法会再次保险排序)
 * @param edges 边列表(可能包含异常边,本算法会过滤)
 * @returns WorldLocationGraphLayout
 */
export function computeWorldLocationGraphLayout(
  locations: WorldLocationUiModel[],
  edges: WorldEdgeUiModel[]
): WorldLocationGraphLayout {
  // 1. 地点去重与排序(createdAt ASC,id ASC 兜底)
  const sortedLocations: WorldLocationUiModel[] = sortLocationsSafely(locations);

  // 2. 构建 id → 索引映射
  const idToLocation: Map<string, WorldLocationUiModel> = new Map();
  for (let i: number = 0; i < sortedLocations.length; i++) {
    const loc: WorldLocationUiModel = sortedLocations[i];
    idToLocation.set(loc.id, loc);
  }

  // 3. 过滤异常边,得到用于布局的有效边
  const validEdges: WorldEdgeUiModel[] = [];
  const anomalousEdges: WorldEdgeUiModel[] = [];
  const seenEdgeKeys: Set<string> = new Set<string>();
  for (let i: number = 0; i < edges.length; i++) {
    const edge: WorldEdgeUiModel = edges[i];
    if (isAnomalousEdge(edge, idToLocation)) {
      anomalousEdges.push(edge);
      continue;
    }
    // 完全重复(fromId→toId)的边只保留第一条
    const key: string = edge.fromLocationId + '->' + edge.toLocationId;
    if (seenEdgeKeys.has(key)) {
      anomalousEdges.push(edge);
      continue;
    }
    seenEdgeKeys.add(key);
    validEdges.push(edge);
  }

  // 4. 构建无向邻接关系(只在有效边的端点间)
  const adjacency: Map<string, Set<string>> = new Map<string, Set<string>>();
  for (let i: number = 0; i < sortedLocations.length; i++) {
    adjacency.set(sortedLocations[i].id, new Set<string>());
  }
  for (let i: number = 0; i < validEdges.length; i++) {
    const edge: WorldEdgeUiModel = validEdges[i];
    const fromSet: Set<string> | undefined = adjacency.get(edge.fromLocationId);
    const toSet: Set<string> | undefined = adjacency.get(edge.toLocationId);
    if (fromSet !== undefined && toSet !== undefined) {
      fromSet.add(edge.toLocationId);
      toSet.add(edge.fromLocationId);
    }
  }

  // 5. 找出无连接节点
  const isolatedIds: string[] = [];
  const connectedIds: string[] = [];
  for (let i: number = 0; i < sortedLocations.length; i++) {
    const loc: WorldLocationUiModel = sortedLocations[i];
    const neighbors: Set<string> | undefined = adjacency.get(loc.id);
    if (neighbors === undefined || neighbors.size === 0) {
      isolatedIds.push(loc.id);
    } else {
      connectedIds.push(loc.id);
    }
  }

  // 6. 对 connectedIds 做连通分量分组
  const visited: Set<string> = new Set<string>();
  const components: string[][] = [];
  for (let i: number = 0; i < connectedIds.length; i++) {
    const startId: string = connectedIds[i];
    if (visited.has(startId)) {
      continue;
    }
    const component: string[] = bfsCollectComponent(startId, adjacency, visited);
    if (component.length > 0) {
      components.push(component);
    }
  }

  // 7. 为每个分量布局:返回节点坐标
  const nodeLayouts: WorldLocationNodeLayout[] = [];
  let currentY: number = PADDING;

  // 7.1 连通分量依次纵向排列
  for (let c: number = 0; c < components.length; c++) {
    const component: string[] = components[c];
    const componentLayout: ComponentLayout = layoutComponent(component, idToLocation, adjacency);
    for (let i: number = 0; i < componentLayout.nodes.length; i++) {
      const node: WorldLocationNodeLayout = componentLayout.nodes[i];
      nodeLayouts.push({
        locationId: node.locationId,
        x: node.x,
        y: node.y + currentY,
        width: node.width,
        height: node.height,
        depth: node.depth,
        layerIndex: node.layerIndex
      });
    }
    currentY = currentY + componentLayout.height + COMPONENT_GAP;
  }

  // 7.2 无连接节点放在独立区域
  if (isolatedIds.length > 0) {
    // 重新按 createdAt ASC 排序(已在 sortedLocations 中保持顺序)
    const isolatedLayerY: number = currentY;
    for (let i: number = 0; i < isolatedIds.length; i++) {
      const id: string = isolatedIds[i];
      const x: number = PADDING + i * (NODE_WIDTH + H_GAP);
      nodeLayouts.push({
        locationId: id,
        x: x,
        y: isolatedLayerY,
        width: NODE_WIDTH,
        height: NODE_HEIGHT,
        depth: 0,
        layerIndex: i
      });
    }
    const isolatedRowHeight: number = NODE_HEIGHT;
    currentY = currentY + isolatedRowHeight + COMPONENT_GAP;
  }

  // 8. 计算画布尺寸
  let canvasWidth: number = PADDING * 2;
  let canvasHeight: number = currentY - COMPONENT_GAP; // 减去末尾多余 gap
  if (canvasHeight < 0) {
    canvasHeight = 0;
  }
  for (let i: number = 0; i < nodeLayouts.length; i++) {
    const nodeRight: number = nodeLayouts[i].x + nodeLayouts[i].width;
    const nodeBottom: number = nodeLayouts[i].y + nodeLayouts[i].height;
    if (nodeRight > canvasWidth - PADDING) {
      canvasWidth = nodeRight + PADDING;
    }
    if (nodeBottom > canvasHeight) {
      canvasHeight = nodeBottom + PADDING;
    }
  }

  // 9. 构建边布局(基于有效边)
  const nodeMap: Map<string, WorldLocationNodeLayout> = new Map<string, WorldLocationNodeLayout>();
  for (let i: number = 0; i < nodeLayouts.length; i++) {
    nodeMap.set(nodeLayouts[i].locationId, nodeLayouts[i]);
  }
  const edgeLayouts: WorldLocationEdgeLayout[] = [];
  for (let i: number = 0; i < validEdges.length; i++) {
    const edge: WorldEdgeUiModel = validEdges[i];
    const fromNode: WorldLocationNodeLayout | undefined = nodeMap.get(edge.fromLocationId);
    const toNode: WorldLocationNodeLayout | undefined = nodeMap.get(edge.toLocationId);
    if (fromNode === undefined || toNode === undefined) {
      continue;
    }
    edgeLayouts.push({
      edgeId: edge.id,
      fromLocationId: edge.fromLocationId,
      toLocationId: edge.toLocationId,
      fromX: fromNode.x + fromNode.width / 2,
      fromY: fromNode.y + fromNode.height,
      toX: toNode.x + toNode.width / 2,
      toY: toNode.y,
      isBidirectional: edge.isBidirectional,
      isEnabled: edge.isEnabled
    });
  }

  return {
    nodes: nodeLayouts,
    edges: edgeLayouts,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    anomalousEdgeCount: anomalousEdges.length
  };
}

/** 分量内部布局结果(原点已对齐到 0,0) */
interface ComponentLayout {
  readonly nodes: WorldLocationNodeLayout[];
  readonly height: number;
}

/**
 * 对单个连通分量做 BFS 分层布局。
 * 根节点:第一个 Active 地点;若无 Active,用分量中第一个节点。
 */
function layoutComponent(
  component: string[],
  idToLocation: Map<string, WorldLocationUiModel>,
  adjacency: Map<string, Set<string>>
): ComponentLayout {
  // 1. 选择根节点
  const rootId: string = pickComponentRoot(component, idToLocation);

  // 2. BFS 分层
  // layers: depth → 该层 locationId 数组(按 createdAt ASC)
  const layers: string[][] = [];
  const visited: Set<string> = new Set<string>();
  const queue: Array<BfsQueueItem> = new Array<BfsQueueItem>();
  const rootItem: BfsQueueItem = { id: rootId, depth: 0 };
  queue.push(rootItem);
  visited.add(rootId);

  while (queue.length > 0) {
    const head: BfsQueueItem | undefined = queue.shift();
    if (head === undefined) {
      break;
    }
    const id: string = head.id;
    const depth: number = head.depth;
    while (layers.length <= depth) {
      layers.push([]);
    }
    layers[depth].push(id);

    const neighbors: Set<string> | undefined = adjacency.get(id);
    if (neighbors === undefined) {
      continue;
    }
    // 收集邻居并按 createdAt ASC 排序
    const neighborIds: string[] = [];
    neighbors.forEach((neighborId: string): void => {
      if (!visited.has(neighborId)) {
        neighborIds.push(neighborId);
      }
    });
    neighborIds.sort((a: string, b: string): number => {
      const locA: WorldLocationUiModel | undefined = idToLocation.get(a);
      const locB: WorldLocationUiModel | undefined = idToLocation.get(b);
      if (locA === undefined || locB === undefined) {
        return a < b ? -1 : (a > b ? 1 : 0);
      }
      if (locA.createdAt !== locB.createdAt) {
        return locA.createdAt - locB.createdAt;
      }
      return a < b ? -1 : (a > b ? 1 : 0);
    });
    for (let i: number = 0; i < neighborIds.length; i++) {
      const neighborId: string = neighborIds[i];
      if (!visited.has(neighborId)) {
        visited.add(neighborId);
        const neighborItem: BfsQueueItem = { id: neighborId, depth: depth + 1 };
        queue.push(neighborItem);
      }
    }
  }

  // 3. 把分层转换为节点坐标
  // 实际宽度:每层节点数最多的那一层决定画布宽度
  let maxLayerSize: number = 1;
  for (let i: number = 0; i < layers.length; i++) {
    if (layers[i].length > maxLayerSize) {
      maxLayerSize = layers[i].length;
    }
  }
  const layerTotalWidth: number = maxLayerSize * NODE_WIDTH + (maxLayerSize - 1) * H_GAP;

  const nodes: WorldLocationNodeLayout[] = [];
  for (let depth: number = 0; depth < layers.length; depth++) {
    const layerIds: string[] = layers[depth];
    const layerWidth: number = layerIds.length * NODE_WIDTH + (layerIds.length - 1) * H_GAP;
    const startX: number = PADDING + (layerTotalWidth - layerWidth) / 2;
    const y: number = PADDING + depth * (NODE_HEIGHT + V_GAP);
    for (let i: number = 0; i < layerIds.length; i++) {
      const id: string = layerIds[i];
      const x: number = startX + i * (NODE_WIDTH + H_GAP);
      nodes.push({
        locationId: id,
        x: x,
        y: y,
        width: NODE_WIDTH,
        height: NODE_HEIGHT,
        depth: depth,
        layerIndex: i
      });
    }
  }

  const height: number = layers.length * NODE_HEIGHT + (layers.length - 1) * V_GAP + PADDING * 2;
  return { nodes: nodes, height: height };
}

/**
 * 选择连通分量的根节点:优先第一个 Active 地点,否则第一个节点。
 */
function pickComponentRoot(
  component: string[],
  idToLocation: Map<string, WorldLocationUiModel>
): string {
  for (let i: number = 0; i < component.length; i++) {
    const loc: WorldLocationUiModel | undefined = idToLocation.get(component[i]);
    if (loc !== undefined && loc.status === WorldLocationStatus.Active) {
      return component[i];
    }
  }
  return component[0];
}

/**
 * BFS 收集一个连通分量的全部节点 id(按访问顺序)。
 */
function bfsCollectComponent(
  startId: string,
  adjacency: Map<string, Set<string>>,
  visited: Set<string>
): string[] {
  const component: string[] = [];
  const queue: string[] = new Array<string>();
  queue.push(startId);
  visited.add(startId);
  while (queue.length > 0) {
    const head: string | undefined = queue.shift();
    if (head === undefined) {
      break;
    }
    component.push(head);
    const neighbors: Set<string> | undefined = adjacency.get(head);
    if (neighbors === undefined) {
      continue;
    }
    neighbors.forEach((neighborId: string): void => {
      if (!visited.has(neighborId)) {
        visited.add(neighborId);
        queue.push(neighborId);
      }
    });
  }
  return component;
}

/**
 * 判断边是否异常:端点不存在 / 自连接 / 端点缺失标记 / worldId 不一致由 ViewModel 已处理。
 * 这里基于 WorldEdgeUiModel 的 fromLocationMissing/toLocationMissing/isAnomalous 字段判断。
 */
function isAnomalousEdge(
  edge: WorldEdgeUiModel,
  idToLocation: Map<string, WorldLocationUiModel>
): boolean {
  if (edge.isAnomalous) {
    return true;
  }
  if (edge.fromLocationMissing || edge.toLocationMissing) {
    return true;
  }
  if (edge.fromLocationId === edge.toLocationId) {
    return true;
  }
  if (!idToLocation.has(edge.fromLocationId)) {
    return true;
  }
  if (!idToLocation.has(edge.toLocationId)) {
    return true;
  }
  return false;
}

/**
 * 安全排序地点(createdAt ASC,id ASC 兜底),返回新数组。
 */
function sortLocationsSafely(locations: WorldLocationUiModel[]): WorldLocationUiModel[] {
  const arr: WorldLocationUiModel[] = locations.slice();
  arr.sort((a: WorldLocationUiModel, b: WorldLocationUiModel): number => {
    if (a.createdAt !== b.createdAt) {
      return a.createdAt - b.createdAt;
    }
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
  });
  return arr;
}
