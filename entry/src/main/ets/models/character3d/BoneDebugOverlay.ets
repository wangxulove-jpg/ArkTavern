/**
 * BoneDebugOverlay 骨架可视化数据模型
 *
 * T-3D.6E P3: 骨骼可视化前置数据结构(第二十节)。
 *
 * 职责:
 * - 计算骨架连线和节点位置(世界坐标)
 * - 标记选中骨骼、已映射骨骼状态
 * - 提供 BoneOverlayNode/BoneOverlayEdge 数据(供 ArkGraphics 或 Canvas 投影使用)
 * - 不依赖 ArkUI/ArkGraphics3D,纯逻辑可单元测试
 *
 * 设计原则:
 * - 不影响原模型材质(只是数据计算,不修改 Scene)
 * - 可开关(由 UI 调用方决定是否渲染)
 * - 选中骨骼高亮(通过 highlight 标记)
 * - 自动映射骨骼与手动映射骨骼状态不同(通过 mappingMethod 区分)
 * - 骨架线随模型旋转、缩放、平移(由调用方传入 worldMatrix)
 * - 不逐帧重建完整 Scene(数据缓存,只在 mapping 变化时重建)
 * - 页面退出时释放资源(由调用方清理)
 *
 * 渲染策略(由调用方实现):
 * - 小型球体关节点
 * - 细圆柱骨骼(父子 joint 之间)
 * - 不同状态使用不同颜色:
 *   - 普通关节: 白色
 *   - 选中关节: 黄色
 *   - 自动映射关节: 绿色
 *   - 手动映射关节: 蓝色
 *   - 必需缺失关节: 红色(警告)
 *
 * 不实现 ArkGraphics 集成(留给下一阶段,HumanoidMappingPage 当前无 3D 预览)。
 */

import {
  ManualHumanoidMapping,
  HumanoidJointBinding,
  BoneMappingMethod,
  SkeletonRestPose,
  Vec3
} from './ManualHumanoidMapping';
import { HumanoidBone, REQUIRED_BONES } from './HumanoidBone';

/** 骨骼节点可视状态 */
export enum BoneOverlayNodeState {
  /** 普通关节(未映射) */
  Normal = 'Normal',
  /** 选中关节 */
  Selected = 'Selected',
  /** 自动映射关节 */
  AutoMapped = 'AutoMapped',
  /** 手动映射关节 */
  ManualMapped = 'ManualMapped',
  /** 必需关节缺失(警告) */
  RequiredMissing = 'RequiredMissing'
}

/** 骨骼连线可视状态 */
export enum BoneOverlayEdgeState {
  /** 普通连线(父子 joint) */
  Normal = 'Normal',
  /** 选中关节相关连线 */
  Highlighted = 'Highlighted',
  /** 已映射关节链连线 */
  Mapped = 'Mapped'
}

/** 骨骼节点可视数据(一个 joint) */
export interface BoneOverlayNode {
  /** 节点索引 */
  nodeIndex: number;
  /** 节点名 */
  name: string;
  /** 世界坐标位置(从 rest pose worldMatrix 提取的平移) */
  worldPosition: Vec3;
  /** 父节点索引(-1 为根) */
  parentIndex: number;
  /** 状态 */
  state: BoneOverlayNodeState;
  /** 如果已映射,对应的标准关节名 */
  mappedBoneName: string;
  /** 颜色(根据 state 计算) */
  color: string;
  /** 球体半径(根据 state 计算,选中时更大) */
  radius: number;
}

/** 骨骼连线可视数据(父子 joint 之间) */
export interface BoneOverlayEdge {
  /** 起点 nodeIndex */
  fromIndex: number;
  /** 终点 nodeIndex */
  toIndex: number;
  /** 起点世界坐标 */
  fromPosition: Vec3;
  /** 终点世界坐标 */
  toPosition: Vec3;
  /** 状态 */
  state: BoneOverlayEdgeState;
  /** 颜色(根据 state 计算) */
  color: string;
  /** 圆柱半径(根据 state 计算,选中时更粗) */
  radius: number;
}

/** 骨架可视数据快照 */
export interface BoneOverlaySnapshot {
  /** 节点列表 */
  nodes: BoneOverlayNode[];
  /** 连线列表 */
  edges: BoneOverlayEdge[];
  /** 生成时间戳 */
  generatedAt: number;
}

/** 颜色常量 */
const COLOR_NORMAL: string = '#ffffff';
const COLOR_SELECTED: string = '#ffeb3b';
const COLOR_AUTO_MAPPED: string = '#28a745';
const COLOR_MANUAL_MAPPED: string = '#007DFF';
const COLOR_REQUIRED_MISSING: string = '#dc3545';
const COLOR_EDGE_NORMAL: string = '#bbbbbb';
const COLOR_EDGE_HIGHLIGHTED: string = '#ffeb3b';
const COLOR_EDGE_MAPPED: string = '#28a745';

/** 球体半径常量 */
const RADIUS_NORMAL: number = 0.01;
const RADIUS_SELECTED: number = 0.02;
const RADIUS_MAPPED: number = 0.015;

/** 圆柱半径常量 */
const EDGE_RADIUS_NORMAL: number = 0.003;
const EDGE_RADIUS_HIGHLIGHTED: number = 0.006;
const EDGE_RADIUS_MAPPED: number = 0.005;

/**
 * 构建骨架可视数据快照。
 *
 * 输入:
 * - restPoses: 所有节点的 rest pose(含 worldMatrix)
 * - mapping: 当前手动映射(可能为 null)
 * - selectedNodeIndex: 当前选中的源骨骼节点索引(-1 表示未选中)
 *
 * 输出:
 * - BoneOverlaySnapshot,包含节点和连线列表,可直接用于渲染
 *
 * 性能:
 * - 一次遍历构建所有节点
 * - 一次遍历构建所有连线
 * - 不缓存,由调用方决定重建时机
 * - Grace 524 joints 仍可在毫秒级完成
 *
 * @param restPoses rest pose 列表
 * @param mapping 手动映射(可能为 null)
 * @param selectedNodeIndex 选中节点索引(-1 未选中)
 * @param parentIndices 父节点索引数组(可选,若提供则用于构建连线)
 */
export function buildBoneOverlaySnapshot(
  restPoses: SkeletonRestPose[],
  mapping: ManualHumanoidMapping | null,
  selectedNodeIndex: number,
  parentIndices: number[]
): BoneOverlaySnapshot {
  const nodes: BoneOverlayNode[] = [];
  const edges: BoneOverlayEdge[] = [];

  // 构建 nodeIndex -> binding 映射
  const nodeToBinding: Map<number, HumanoidJointBinding> = new Map();
  if (mapping !== null) {
    for (let i: number = 0; i < mapping.joints.length; i++) {
      nodeToBinding.set(mapping.joints[i].sourceNodeIndex, mapping.joints[i]);
    }
  }

  // 构建必需骨骼集合(用于检测缺失)
  const requiredBones: Set<HumanoidBone> = new Set();
  for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
    requiredBones.add(REQUIRED_BONES[i]);
  }

  // 构建已映射的 sourceNodeIndex 集合(用于高亮连线)
  const mappedNodeIndices: Set<number> = new Set();
  if (mapping !== null) {
    for (let i: number = 0; i < mapping.joints.length; i++) {
      mappedNodeIndices.add(mapping.joints[i].sourceNodeIndex);
    }
  }

  // 1. 构建节点
  for (let i: number = 0; i < restPoses.length; i++) {
    const pose: SkeletonRestPose = restPoses[i];
    const worldPos: Vec3 = extractWorldPosition(pose);
    const binding: HumanoidJointBinding | undefined = nodeToBinding.get(pose.nodeIndex);
    const isSelected: boolean = pose.nodeIndex === selectedNodeIndex;
    const isMapped: boolean = binding !== undefined;
    const isAuto: boolean = isMapped && binding !== undefined
      && binding.mappingMethod === BoneMappingMethod.Auto;
    const isManual: boolean = isMapped && binding !== undefined
      && binding.mappingMethod === BoneMappingMethod.Manual;

    let state: BoneOverlayNodeState = BoneOverlayNodeState.Normal;
    let color: string = COLOR_NORMAL;
    let radius: number = RADIUS_NORMAL;
    let mappedBoneName: string = '';

    if (isSelected) {
      state = BoneOverlayNodeState.Selected;
      color = COLOR_SELECTED;
      radius = RADIUS_SELECTED;
    } else if (isAuto) {
      state = BoneOverlayNodeState.AutoMapped;
      color = COLOR_AUTO_MAPPED;
      radius = RADIUS_MAPPED;
    } else if (isManual) {
      state = BoneOverlayNodeState.ManualMapped;
      color = COLOR_MANUAL_MAPPED;
      radius = RADIUS_MAPPED;
    }

    if (binding !== undefined) {
      mappedBoneName = binding.targetJoint;
    }

    nodes.push({
      nodeIndex: pose.nodeIndex,
      name: '', // rest pose 不持有 name,由调用方填充
      worldPosition: worldPos,
      parentIndex: pose.parentNodeIndex,
      state: state,
      color: color,
      radius: radius,
      mappedBoneName: mappedBoneName
    });
  }

  // 2. 构建连线(使用 parentIndices 或 restPoses.parentNodeIndex)
  for (let i: number = 0; i < restPoses.length; i++) {
    const pose: SkeletonRestPose = restPoses[i];
    let parentIdx: number = -1;
    if (parentIndices.length > pose.nodeIndex) {
      parentIdx = parentIndices[pose.nodeIndex];
    } else if (pose.parentNodeIndex >= 0) {
      parentIdx = pose.parentNodeIndex;
    }
    if (parentIdx < 0) {
      continue; // 根节点,无连线
    }
    // 查找父节点位置
    const parentPose: SkeletonRestPose | undefined = findRestPose(restPoses, parentIdx);
    if (parentPose === undefined) {
      continue;
    }
    const fromPos: Vec3 = extractWorldPosition(parentPose);
    const toPos: Vec3 = extractWorldPosition(pose);
    const isSelectedEdge: boolean = pose.nodeIndex === selectedNodeIndex
      || parentIdx === selectedNodeIndex;
    const isMappedEdge: boolean = mappedNodeIndices.has(pose.nodeIndex)
      && mappedNodeIndices.has(parentIdx);

    let edgeState: BoneOverlayEdgeState = BoneOverlayEdgeState.Normal;
    let edgeColor: string = COLOR_EDGE_NORMAL;
    let edgeRadius: number = EDGE_RADIUS_NORMAL;
    if (isSelectedEdge) {
      edgeState = BoneOverlayEdgeState.Highlighted;
      edgeColor = COLOR_EDGE_HIGHLIGHTED;
      edgeRadius = EDGE_RADIUS_HIGHLIGHTED;
    } else if (isMappedEdge) {
      edgeState = BoneOverlayEdgeState.Mapped;
      edgeColor = COLOR_EDGE_MAPPED;
      edgeRadius = EDGE_RADIUS_MAPPED;
    }

    edges.push({
      fromIndex: parentIdx,
      toIndex: pose.nodeIndex,
      fromPosition: fromPos,
      toPosition: toPos,
      state: edgeState,
      color: edgeColor,
      radius: edgeRadius
    });
  }

  return {
    nodes: nodes,
    edges: edges,
    generatedAt: Date.now()
  };
}

/**
 * 从 rest pose 的 worldMatrix 提取平移(世界坐标)。
 *
 * glTF 矩阵是列主序,m[12]/m[13]/m[14] 是平移分量。
 *
 * @param pose rest pose
 * @returns 世界坐标 Vec3
 */
function extractWorldPosition(pose: SkeletonRestPose): Vec3 {
  const m: number[] = pose.worldMatrix.m;
  return {
    x: m.length > 12 ? m[12] : 0,
    y: m.length > 13 ? m[13] : 0,
    z: m.length > 14 ? m[14] : 0
  };
}

/**
 * 在 rest poses 中查找指定节点。
 */
function findRestPose(
  restPoses: SkeletonRestPose[],
  nodeIndex: number
): SkeletonRestPose | undefined {
  for (let i: number = 0; i < restPoses.length; i++) {
    if (restPoses[i].nodeIndex === nodeIndex) {
      return restPoses[i];
    }
  }
  return undefined;
}

/**
 * 根据状态获取节点颜色(供调用方查询)。
 */
export function getNodeColor(state: BoneOverlayNodeState): string {
  switch (state) {
    case BoneOverlayNodeState.Selected:
      return COLOR_SELECTED;
    case BoneOverlayNodeState.AutoMapped:
      return COLOR_AUTO_MAPPED;
    case BoneOverlayNodeState.ManualMapped:
      return COLOR_MANUAL_MAPPED;
    case BoneOverlayNodeState.RequiredMissing:
      return COLOR_REQUIRED_MISSING;
    default:
      return COLOR_NORMAL;
  }
}

/**
 * 根据状态获取连线颜色。
 */
export function getEdgeColor(state: BoneOverlayEdgeState): string {
  switch (state) {
    case BoneOverlayEdgeState.Highlighted:
      return COLOR_EDGE_HIGHLIGHTED;
    case BoneOverlayEdgeState.Mapped:
      return COLOR_EDGE_MAPPED;
    default:
      return COLOR_EDGE_NORMAL;
  }
}

/**
 * 估算骨架可视数据的内存占用(用于性能监控)。
 *
 * @param snapshot 骨架快照
 * @returns 估算字节数
 */
export function estimateSnapshotSize(snapshot: BoneOverlaySnapshot): number {
  // 每个节点约 80 字节(nodeIndex 4 + name 0 + Vec3 24 + parentIndex 4 + state 16 + color 16 + radius 8 + mappedBoneName 0)
  // 每条连线约 96 字节(fromIndex 4 + toIndex 4 + Vec3 24 + Vec3 24 + state 16 + color 16 + radius 8)
  return snapshot.nodes.length * 80 + snapshot.edges.length * 96;
}
