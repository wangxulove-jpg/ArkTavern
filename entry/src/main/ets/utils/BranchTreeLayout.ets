/**
 * BranchTreeLayout 分支树布局计算工具(T-6.4B-1.1)
 *
 * 根据 ConversationBranchSummary 列表构造父子树并计算每个节点的 (x, y) 坐标。
 *
 * 布局策略(简单稳定,不做复杂图算法):
 * 1. 根据 parentBranchId 构造树;
 * 2. Root depth = 0, Child depth = parent depth + 1;
 * 3. 每个 depth 为一行,同层节点横向排列;
 * 4. 同层节点按 createdAt 升序排列(稳定排序);
 * 5. 节点固定宽度 / 高度;
 * 6. 层间保留足够垂直间距,同层节点保留足够水平间距;
 * 7. 每层水平居中于父节点组(简化版:整层居中)。
 *
 * 不依赖 ArkUI / Repository / Service。
 */

import { ConversationBranchSummary } from '../models/ConversationBranch';
import {
  BranchMapNodeLayout,
  BranchTreeLayoutResult,
  BranchTreeEdge
} from '../models/BranchMapNodeLayout';

/** 节点固定宽度(vp) */
const NODE_WIDTH: number = 180;
/** T-6.4B-1.2: 节点固定高度(vp),增大以容纳 fork User 预览 + Assistant 预览 */
const NODE_HEIGHT: number = 112;
/** 同层节点水平间距(vp) */
const SIBLING_GAP: number = 24;
/** 层间垂直间距(vp) */
const DEPTH_GAP: number = 64;
/** 画布边距(vp) */
const CANVAS_PADDING: number = 32;

interface TreeNode {
  summary: ConversationBranchSummary;
  children: TreeNode[];
  depth: number;
}

/**
 * 计算分支树布局。
 *
 * @param branches 所有 Branch 摘要
 * @returns 布局结果(节点位置 + 连接线 + 画布尺寸)
 */
export function computeBranchTreeLayout(
  branches: ConversationBranchSummary[]
): BranchTreeLayoutResult {
  if (branches.length === 0) {
    return {
      nodes: [],
      canvasWidth: CANVAS_PADDING * 2,
      canvasHeight: CANVAS_PADDING * 2,
      edges: []
    };
  }

  // 1. 构造树
  const nodeMap: Map<string, TreeNode> = new Map<string, TreeNode>();
  const roots: TreeNode[] = [];

  // 第一遍:创建所有 TreeNode
  for (let i = 0; i < branches.length; i++) {
    const summary: ConversationBranchSummary = branches[i];
    nodeMap.set(summary.id, {
      summary: summary,
      children: [],
      depth: 0
    });
  }

  // 第二遍:建立父子关系
  for (let i = 0; i < branches.length; i++) {
    const summary: ConversationBranchSummary = branches[i];
    const node: TreeNode | undefined = nodeMap.get(summary.id);
    if (node === undefined) {
      continue;
    }
    if (summary.parentBranchId === undefined || summary.parentBranchId === null
      || summary.parentBranchId.length === 0) {
      roots.push(node);
    } else {
      const parent: TreeNode | undefined = nodeMap.get(summary.parentBranchId);
      if (parent !== undefined) {
        parent.children.push(node);
      } else {
        // 父节点缺失,作为 Root 处理(数据完整性兜底)
        roots.push(node);
      }
    }
  }

  // 2. 计算 depth + 同层排序(按 createdAt 升序)
  assignDepth(roots, 0);

  // 3. 按 depth 分层
  const layers: TreeNode[][] = [];
  collectLayers(roots, layers);

  // 4. 计算每层节点位置
  const nodes: BranchMapNodeLayout[] = [];
  const edges: BranchTreeEdge[] = [];
  let maxLayerWidth: number = 0;

  for (let d = 0; d < layers.length; d++) {
    const layer: TreeNode[] = layers[d];
    // 同层按 createdAt 升序(稳定排序)
    layer.sort((a: TreeNode, b: TreeNode): number => {
      return a.summary.createdAt - b.summary.createdAt;
    });

    const layerWidth: number = layer.length * NODE_WIDTH
      + (layer.length - 1) * SIBLING_GAP;
    if (layerWidth > maxLayerWidth) {
      maxLayerWidth = layerWidth;
    }

    for (let i = 0; i < layer.length; i++) {
      const node: TreeNode = layer[i];
      const x: number = CANVAS_PADDING + i * (NODE_WIDTH + SIBLING_GAP);
      const y: number = CANVAS_PADDING + d * (NODE_HEIGHT + DEPTH_GAP);

      nodes.push({
        branchId: node.summary.id,
        parentBranchId: node.summary.parentBranchId !== undefined
          && node.summary.parentBranchId !== null
          ? node.summary.parentBranchId
          : '',
        depth: node.depth,
        x: x,
        y: y,
        width: NODE_WIDTH,
        height: NODE_HEIGHT,
        siblingIndex: i,
        siblingCount: layer.length
      });

      // 生成连接线(父底部中心 → 子顶部中心)
      if (node.summary.parentBranchId !== undefined
        && node.summary.parentBranchId !== null
        && node.summary.parentBranchId.length > 0) {
        const parentLayout: BranchMapNodeLayout | undefined =
          findNodeLayout(nodes, node.summary.parentBranchId);
        if (parentLayout !== undefined) {
          edges.push({
            parentBranchId: node.summary.parentBranchId,
            childBranchId: node.summary.id,
            startX: parentLayout.x + parentLayout.width / 2,
            startY: parentLayout.y + parentLayout.height,
            endX: x + NODE_WIDTH / 2,
            endY: y
          });
        }
      }
    }
  }

  const canvasWidth: number = maxLayerWidth + CANVAS_PADDING * 2;
  const canvasHeight: number = layers.length * (NODE_HEIGHT + DEPTH_GAP)
    - DEPTH_GAP + CANVAS_PADDING * 2;

  return {
    nodes: nodes,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    edges: edges
  };
}

function assignDepth(nodes: TreeNode[], depth: number): void {
  for (let i = 0; i < nodes.length; i++) {
    nodes[i].depth = depth;
    assignDepth(nodes[i].children, depth + 1);
  }
}

function collectLayers(nodes: TreeNode[], layers: TreeNode[][]): void {
  for (let i = 0; i < nodes.length; i++) {
    const node: TreeNode = nodes[i];
    while (layers.length <= node.depth) {
      layers.push([]);
    }
    layers[node.depth].push(node);
    collectLayers(node.children, layers);
  }
}

function findNodeLayout(
  nodes: BranchMapNodeLayout[],
  branchId: string
): BranchMapNodeLayout | undefined {
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i].branchId === branchId) {
      return nodes[i];
    }
  }
  return undefined;
}

/**
 * 获取节点固定宽度。
 */
export function getNodeWidth(): number {
  return NODE_WIDTH;
}

/**
 * 获取节点固定高度。
 */
export function getNodeHeight(): number {
  return NODE_HEIGHT;
}
