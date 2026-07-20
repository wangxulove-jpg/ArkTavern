/**
 * BranchTreeLayout 分支树布局计算工具(T-6.4B-1.1 / T-6.4B-2-R1)
 *
 * 按 forkTurnNumber(对话轮次)分层布局,确保 Branch 在 BranchMap 中的 Y 位置
 * 严格对应 fork 发生的对话轮次位置:
 *
 * - Root: forkTurnNumber=0 → 顶部
 * - 从 U1 fork: forkTurnNumber=1 → 第 1 轮位置
 * - 从 U2 fork: forkTurnNumber=2 → 第 2 轮位置
 * - 从末尾 fork: forkTurnNumber=N → 最底部
 *
 * T-6.4B-3-R1 布局策略(子树居中于父节点):
 * - 旧版按 forkTurnNumber 分组 + 整组居中于画布,导致每个层级都"挤到中间"
 * - 新版按"子树居中于父节点"布局:
 *   - Root 居中于画布顶部
 *   - 每个 Branch 的子节点(直接 parentBranchId === this.id)以该 Branch 为中心横向排列
 *   - 从任何 fork 点向下分出的子分支,在视觉上始终位于该 fork 点正下方
 *   - 多兄弟分支横向并列,中心对齐父节点
 *   - 单子分支直接放在父节点正下方
 * - 这样从任何节点向下看,其所有后代都位于该节点正下方,整齐不挤到中间
 *
 * 连接线逻辑(T-6.4B-2-R1 修正):
 * - 对每个 Branch,沿 parentBranchId 链向上查找,找到第一个
 *   forkTurnNumber < 当前 Branch forkTurnNumber 的祖先作为起点
 * - 保证所有连线都向下(低轮次 → 高轮次),无横向、无向上
 * - 同轮次的平行 Branch 之间不会有连线
 * - 从同一对话点 fork 出的多个 Branch 都会连到上方某个低 turn 祖先
 *
 * 不依赖 ArkUI / Repository / Service。
 */

import { ConversationBranchSummary } from '../models/ConversationBranch';
import {
  BranchMapNodeLayout,
  BranchTreeLayoutResult,
  BranchTreeEdge
} from '../models/BranchMapNodeLayout';
import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';
import { Logger } from './Logger';

const LOG_TAG: string = 'BranchMapLayout';

/** 节点固定宽度(vp) */
const NODE_WIDTH: number = 176;
/** 节点固定高度(vp) */
const NODE_HEIGHT: number = 112;
/** 兄弟节点之间的水平间距(vp) */
const SIBLING_GAP: number = 28;
/**
 * 轮次间垂直间距(vp)。
 * Y 坐标 = forkTurnNumber × LEVEL_GAP,严格对应对话轮次位置。
 */
const LEVEL_GAP: number = 140;
/** 画布外围 padding(vp) */
const CANVAS_PADDING: number = 28;

/**
 * 计算分支树布局(T-6.4B-3-R1 子树居中算法)。
 *
 * 算法步骤:
 * 1. 构造 children 映射(parentBranchId -> 直接子节点列表)
 * 2. 找到 Root(parentBranchId 为空)
 * 3. DFS 计算每个节点的 subtreeWidth(子树所需总宽度)
 * 4. DFS 分配 X/Y 坐标:
 *    - Y = CANVAS_PADDING + forkTurnNumber × LEVEL_GAP(按对话轮次分层)
 *    - X = 子树左边界 + (subtreeWidth - NODE_WIDTH) / 2(节点居中于自己的子树)
 *    - 子节点依次排列在父节点的子树内,父节点居中
 * 5. 生成连接线(子节点 → 第一个 turn 更小的祖先)
 *
 * @param branches 所有 Branch 摘要
 * @param displayInfos 含 forkTurnNumber 的展示信息
 * @returns 布局结果(节点位置 + 连接线 + 画布尺寸)
 */
export function computeBranchTreeLayout(
  branches: ConversationBranchSummary[],
  displayInfos: BranchMapDisplayInfo[]
): BranchTreeLayoutResult {
  if (branches.length === 0) {
    return {
      nodes: [],
      canvasWidth: CANVAS_PADDING * 2,
      canvasHeight: CANVAS_PADDING * 2,
      edges: []
    };
  }

  // 0. 构造 branchId → forkTurnNumber 映射
  const turnNumberMap: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < displayInfos.length; i++) {
    const info: BranchMapDisplayInfo = displayInfos[i];
    turnNumberMap.set(info.branchId, info.forkTurnNumber);
  }

  // 1. 构造 children 映射(parentBranchId -> 直接子节点列表)
  //    每个 Branch 的直接子节点 = parentBranchId === this.id 的所有 Branch
  const childrenMap: Map<string, ConversationBranchSummary[]> = new Map<string, ConversationBranchSummary[]>();
  const rootBranches: ConversationBranchSummary[] = [];
  for (let i = 0; i < branches.length; i++) {
    const summary: ConversationBranchSummary = branches[i];
    const parentId: string | undefined = summary.parentBranchId;
    if (parentId === undefined || parentId.length === 0) {
      rootBranches.push(summary);
    } else {
      let children: ConversationBranchSummary[] | undefined = childrenMap.get(parentId);
      if (children === undefined) {
        children = [];
        childrenMap.set(parentId, children);
      }
      children.push(summary);
    }
  }

  // 2. 每个 children 数组按 createdAt 升序排序(稳定布局)
  const childrenKeys: string[] = Array.from(childrenMap.keys());
  for (let i = 0; i < childrenKeys.length; i++) {
    const children: ConversationBranchSummary[] | undefined = childrenMap.get(childrenKeys[i]);
    if (children === undefined) {
      continue;
    }
    children.sort((a: ConversationBranchSummary, b: ConversationBranchSummary): number => {
      return a.createdAt - b.createdAt;
    });
  }
  // Root 也按 createdAt 排序(理论上只有一个 Root,容错处理)
  rootBranches.sort((a: ConversationBranchSummary, b: ConversationBranchSummary): number => {
    return a.createdAt - b.createdAt;
  });

  // 3. DFS 计算每个节点的 subtreeWidth
  //    subtreeWidth = max(NODE_WIDTH, sum(子节点 subtreeWidth) + (子节点数-1) × SIBLING_GAP)
  const subtreeWidthMap: Map<string, number> = new Map<string, number>();

  const computeSubtreeWidth = (branchId: string): number => {
    const existing: number | undefined = subtreeWidthMap.get(branchId);
    if (existing !== undefined) {
      return existing;
    }
    const children: ConversationBranchSummary[] | undefined = childrenMap.get(branchId);
    if (children === undefined || children.length === 0) {
      const w: number = NODE_WIDTH;
      subtreeWidthMap.set(branchId, w);
      return w;
    }
    let total: number = 0;
    for (let i = 0; i < children.length; i++) {
      total += computeSubtreeWidth(children[i].id);
    }
    total += (children.length - 1) * SIBLING_GAP;
    const w: number = total > NODE_WIDTH ? total : NODE_WIDTH;
    subtreeWidthMap.set(branchId, w);
    return w;
  };

  // 预计算所有节点的 subtreeWidth(从 Root 开始递归会覆盖整个树)
  for (let i = 0; i < branches.length; i++) {
    computeSubtreeWidth(branches[i].id);
  }

  // 4. DFS 分配 X/Y 坐标
  //    每个节点:
  //    - Y = CANVAS_PADDING + forkTurnNumber × LEVEL_GAP
  //    - X = leftX + (subtreeWidth - NODE_WIDTH) / 2(居中于自己的子树)
  //    子节点依次从 leftX 开始排列,每个占用自己的 subtreeWidth + SIBLING_GAP
  const layoutMap: Map<string, BranchMapNodeLayout> = new Map<string, BranchMapNodeLayout>();
  const nodes: BranchMapNodeLayout[] = [];
  let maxTurn: number = 0;

  const layoutNode = (branch: ConversationBranchSummary, leftX: number, depth: number): void => {
    const subtreeWidth: number = subtreeWidthMap.get(branch.id) ?? NODE_WIDTH;
    const turnNum: number | undefined = turnNumberMap.get(branch.id);
    const turn: number = turnNum !== undefined ? turnNum : 0;
    if (turn > maxTurn) {
      maxTurn = turn;
    }
    const y: number = CANVAS_PADDING + turn * LEVEL_GAP;
    const x: number = leftX + (subtreeWidth - NODE_WIDTH) / 2;

    const children: ConversationBranchSummary[] | undefined = childrenMap.get(branch.id);
    const siblingCount: number = children !== undefined ? children.length : 0;

    const layout: BranchMapNodeLayout = {
      branchId: branch.id,
      parentBranchId: branch.parentBranchId !== undefined
        ? branch.parentBranchId : '',
      depth: depth,
      forkTurnNumber: turn,
      currentMaxTurn: turn,
      x: x,
      y: y,
      width: NODE_WIDTH,
      height: NODE_HEIGHT,
      siblingIndex: 0,
      siblingCount: siblingCount
    };
    nodes.push(layout);
    layoutMap.set(layout.branchId, layout);

    // 递归布局子节点:子节点依次从 leftX 开始排列
    if (children !== undefined && children.length > 0) {
      let childLeftX: number = leftX;
      for (let i = 0; i < children.length; i++) {
        const child: ConversationBranchSummary = children[i];
        const childSubtreeWidth: number = subtreeWidthMap.get(child.id) ?? NODE_WIDTH;
        layoutNode(child, childLeftX, depth + 1);
        childLeftX += childSubtreeWidth + SIBLING_GAP;
      }
    }
  };

  // 从所有 Root 开始布局(Root 们横向并列在画布顶部)
  let currentLeftX: number = CANVAS_PADDING;
  for (let i = 0; i < rootBranches.length; i++) {
    const root: ConversationBranchSummary = rootBranches[i];
    const rootSubtreeWidth: number = subtreeWidthMap.get(root.id) ?? NODE_WIDTH;
    layoutNode(root, currentLeftX, 0);
    currentLeftX += rootSubtreeWidth + SIBLING_GAP;
  }

  // 5. 生成 edges(智能查找父节点,保证连线始终向下)
  //    对每个 Branch,沿 parentBranchId 链向上查找,找到第一个
  //    forkTurnNumber < 当前 Branch forkTurnNumber 的祖先作为起点。
  const edges: BranchTreeEdge[] = [];
  for (let i = 0; i < nodes.length; i++) {
    const nodeLayout: BranchMapNodeLayout = nodes[i];
    if (nodeLayout.parentBranchId.length === 0) {
      continue; // Root 无入射连线
    }
    let currentParentId: string = nodeLayout.parentBranchId;
    let parentLayout: BranchMapNodeLayout | undefined = undefined;
    let safety: number = 0;
    while (currentParentId.length > 0 && safety < 100) {
      safety++;
      const candidate: BranchMapNodeLayout | undefined = layoutMap.get(currentParentId);
      if (candidate === undefined) {
        break;
      }
      if (candidate.forkTurnNumber < nodeLayout.forkTurnNumber) {
        parentLayout = candidate;
        break;
      }
      currentParentId = candidate.parentBranchId;
    }
    if (parentLayout === undefined) {
      continue;
    }
    edges.push({
      parentBranchId: parentLayout.branchId,
      childBranchId: nodeLayout.branchId,
      startX: parentLayout.x + parentLayout.width / 2,
      startY: parentLayout.y + parentLayout.height,
      endX: nodeLayout.x + nodeLayout.width / 2,
      endY: nodeLayout.y
    });
  }

  // 6. 计算画布尺寸
  //    画布宽度 = 所有 Root 的子树宽度总和 + Root 之间的间距 + 两侧 padding
  let totalRootWidth: number = 0;
  for (let i = 0; i < rootBranches.length; i++) {
    const w: number = subtreeWidthMap.get(rootBranches[i].id) ?? NODE_WIDTH;
    totalRootWidth += w;
  }
  if (rootBranches.length > 1) {
    totalRootWidth += (rootBranches.length - 1) * SIBLING_GAP;
  }
  const contentWidth: number = Math.max(totalRootWidth + CANVAS_PADDING * 2, NODE_WIDTH + CANVAS_PADDING * 2);

  const contentHeight: number = CANVAS_PADDING * 2
    + (maxTurn + 1) * NODE_HEIGHT
    + maxTurn * (LEVEL_GAP - NODE_HEIGHT);

  Logger.info(LOG_TAG, 'nodes=' + nodes.length.toString()
    + ' roots=' + rootBranches.length.toString()
    + ' maxTurn=' + maxTurn.toString()
    + ' orphanNodes=0');
  Logger.info(LOG_TAG, 'layout_ready width=' + Math.ceil(contentWidth).toString()
    + ' height=' + Math.ceil(contentHeight).toString()
    + ' edges=' + edges.length.toString());

  return {
    nodes: nodes,
    canvasWidth: contentWidth,
    canvasHeight: contentHeight,
    edges: edges
  };
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
