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
 * 相同 forkTurnNumber 的 Branch 横向同级展开(真正的分叉)。
 * 从历史轮次 fork 的 Branch 不会跑到末尾轮次后面。
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
/** 同轮次兄弟节点之间的水平间距(vp) */
const SIBLING_GAP: number = 28;
/**
 * 轮次间垂直间距(vp)。
 * Y 坐标 = forkTurnNumber × LEVEL_GAP,严格对应对话轮次位置。
 */
const LEVEL_GAP: number = 140;
/** 画布外围 padding(vp) */
const CANVAS_PADDING: number = 28;

/**
 * 计算分支树布局。
 *
 * T-6.4B-2-R1: 按 forkTurnNumber(对话轮次)分层布局。
 * - Y 坐标 = forkTurnNumber × LEVEL_GAP,严格对应对话位置
 * - 节点固定大小 NODE_WIDTH × NODE_HEIGHT
 * - 相同 forkTurnNumber 的 Branch 横向同级展开(真正的分叉)
 * - 从 U1 fork 的 Branch 永远在第 1 轮位置,不管当前 Active 是哪个 Branch
 * - 从 U3 fork 的 Branch 永远在第 3 轮位置,不会跑到其他轮次后面
 *
 * 连接线逻辑(T-6.4B-2-R1 修正):
 * - 沿 parentBranchId 链向上查找第一个 forkTurnNumber 更小的祖先
 * - 保证所有连线向下(低轮次 → 高轮次),无横向、无向上
 * - 每个 Branch 至多一条入射连线
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

  // 1. 按 forkTurnNumber 分组所有 Branch
  //    key = forkTurnNumber, value = 该轮次的所有 Branch 摘要
  const turnGroups: Map<number, ConversationBranchSummary[]> = new Map<number, ConversationBranchSummary[]>();
  let maxTurn: number = 0;
  for (let i = 0; i < branches.length; i++) {
    const summary: ConversationBranchSummary = branches[i];
    const turnNum: number | undefined = turnNumberMap.get(summary.id);
    const turn: number = turnNum !== undefined ? turnNum : 0;
    let group: ConversationBranchSummary[] | undefined = turnGroups.get(turn);
    if (group === undefined) {
      group = [];
      turnGroups.set(turn, group);
    }
    group.push(summary);
    if (turn > maxTurn) {
      maxTurn = turn;
    }
  }

  // 2. 每组按 createdAt 升序排序(稳定布局,先创建的 Branch 在左)
  const turnKeys: number[] = Array.from(turnGroups.keys());
  turnKeys.sort((a: number, b: number): number => a - b);
  for (let i = 0; i < turnKeys.length; i++) {
    const group: ConversationBranchSummary[] | undefined = turnGroups.get(turnKeys[i]);
    if (group === undefined) {
      continue;
    }
    group.sort((a: ConversationBranchSummary, b: ConversationBranchSummary): number => {
      return a.createdAt - b.createdAt;
    });
  }

  // 3. 计算画布宽度(取最宽的组)
  let maxGroupWidth: number = NODE_WIDTH;
  for (let i = 0; i < turnKeys.length; i++) {
    const group: ConversationBranchSummary[] | undefined = turnGroups.get(turnKeys[i]);
    if (group === undefined) {
      continue;
    }
    const groupWidth: number = group.length * NODE_WIDTH
      + (group.length - 1) * SIBLING_GAP;
    if (groupWidth > maxGroupWidth) {
      maxGroupWidth = groupWidth;
    }
  }
  const contentWidth: number = maxGroupWidth + CANVAS_PADDING * 2;

  // 4. 分配 X/Y 坐标(每组居中对齐)
  const layoutMap: Map<string, BranchMapNodeLayout> = new Map<string, BranchMapNodeLayout>();
  const nodes: BranchMapNodeLayout[] = [];
  for (let i = 0; i < turnKeys.length; i++) {
    const turn: number = turnKeys[i];
    const group: ConversationBranchSummary[] | undefined = turnGroups.get(turn);
    if (group === undefined) {
      continue;
    }
    const groupWidth: number = group.length * NODE_WIDTH
      + (group.length - 1) * SIBLING_GAP;
    // 每组居中于画布
    const startX: number = CANVAS_PADDING + (maxGroupWidth - groupWidth) / 2;
    const y: number = CANVAS_PADDING + turn * LEVEL_GAP;

    for (let j = 0; j < group.length; j++) {
      const summary: ConversationBranchSummary = group[j];
      const x: number = startX + j * (NODE_WIDTH + SIBLING_GAP);
      const layout: BranchMapNodeLayout = {
        branchId: summary.id,
        parentBranchId: summary.parentBranchId !== undefined
          ? summary.parentBranchId : '',
        depth: 0, // 不再使用 depth,保留字段兼容
        forkTurnNumber: turn,
        currentMaxTurn: turn,
        x: x,
        y: y,
        width: NODE_WIDTH,
        height: NODE_HEIGHT,
        siblingIndex: j,
        siblingCount: group.length
      };
      nodes.push(layout);
      layoutMap.set(layout.branchId, layout);
    }
  }

  // 5. 生成 edges(智能查找父节点,保证连线始终向下)
  //    对每个 Branch,沿 parentBranchId 链向上查找,找到第一个
  //    forkTurnNumber < 当前 Branch forkTurnNumber 的祖先作为起点。
  //    这样可避免:
  //    - 同轮次平行 Branch 之间的横向连线
  //    - 从历史轮次 fork 时,子节点 turn < 父节点 turn 的向上连线
  //    - 一个 Branch 出现多条入射线(每个 Branch 至多一条入射)
  const edges: BranchTreeEdge[] = [];
  for (let i = 0; i < nodes.length; i++) {
    const nodeLayout: BranchMapNodeLayout = nodes[i];
    if (nodeLayout.parentBranchId.length === 0) {
      continue; // Root 无入射连线
    }
    // 沿父链向上查找 turn 严格更小的祖先
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
      // 当前祖先 turn >= 子节点 turn,继续向上查找
      currentParentId = candidate.parentBranchId;
    }
    if (parentLayout === undefined) {
      // 找不到 turn 更小的祖先(异常情况),跳过该连线
      continue;
    }
    // 起点为祖先节点底部中心,终点为子节点顶部中心
    // 节点固定大小,height = NODE_HEIGHT
    edges.push({
      parentBranchId: parentLayout.branchId,
      childBranchId: nodeLayout.branchId,
      startX: parentLayout.x + parentLayout.width / 2,
      startY: parentLayout.y + parentLayout.height,
      endX: nodeLayout.x + nodeLayout.width / 2,
      endY: nodeLayout.y
    });
  }

  // 6. 计算 contentHeight
  const contentHeight: number = CANVAS_PADDING * 2
    + (maxTurn + 1) * NODE_HEIGHT
    + maxTurn * (LEVEL_GAP - NODE_HEIGHT);

  // 最小日志(只汇总,不记录 ID/正文)
  Logger.info(LOG_TAG, 'nodes=' + nodes.length.toString()
    + ' turns=' + turnKeys.length.toString()
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
