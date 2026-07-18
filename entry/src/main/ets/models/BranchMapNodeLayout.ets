/**
 * BranchMapNodeLayout 分支树节点布局模型(T-6.4B-1.1)
 *
 * 纯 UI 布局数据,描述 Branch 节点在可滚动画布中的位置和尺寸。
 * 不依赖 ArkUI / Repository / Service。
 * 不包含 Branch 业务语义,仅用于布局计算结果传递。
 *
 * 坐标系:
 * - 原点(0,0)位于画布左上角
 * - x 轴向右,y 轴向下
 * - 单位为 vp
 */

/**
 * 分支树节点布局信息。
 */
export interface BranchMapNodeLayout {
  /** 对应 Branch ID */
  branchId: string;
  /** 父 Branch ID(Root 为空字符串) */
  parentBranchId: string;
  /** 层级深度(Root = 0) */
  depth: number;
  /** 节点左上角 x 坐标 */
  x: number;
  /** 节点左上角 y 坐标 */
  y: number;
  /** 节点宽度 */
  width: number;
  /** 节点高度 */
  height: number;
  /** 同层节点中的索引(从 0 开始) */
  siblingIndex: number;
  /** 同层节点总数 */
  siblingCount: number;
}

/**
 * 分支树整体布局结果。
 */
export interface BranchTreeLayoutResult {
  /** 所有节点布局 */
  nodes: BranchMapNodeLayout[];
  /** 画布总宽度 */
  canvasWidth: number;
  /** 画布总高度 */
  canvasHeight: number;
  /** 连接线列表(父节点底部中心 → 子节点顶部中心) */
  edges: BranchTreeEdge[];
}

/**
 * 父子连接线。
 */
export interface BranchTreeEdge {
  /** 父节点 Branch ID */
  parentBranchId: string;
  /** 子节点 Branch ID */
  childBranchId: string;
  /** 起点 x(父节点底部中心) */
  startX: number;
  /** 起点 y(父节点底部中心) */
  startY: number;
  /** 终点 x(子节点顶部中心) */
  endX: number;
  /** 终点 y(子节点顶部中心) */
  endY: number;
}
