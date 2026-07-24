/**
 * VrmSpringBone VRM SpringBone 物理摆动骨骼
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 1.0: extensions.VRMC_springBone
 *   - colliders: [{ node, shape: { sphere | capsule } }]
 *   - colliderGroups: [{ name, colliders: [colliderIndex] }]
 *   - springs: [{ name, joints: [{ node, hitRadius, stiffness, gravityPower, gravityFromStartBone, dragForce, center }], colliderGroups: [groupIndex] }]
 * VRM 0.x: extensions.VRM.secondaryAnimation
 *   - boneGroups: [{ bones, center, colliderGroups, dragForce, gravityPower, gravityDir, stiffiness, hitRadius }]
 *   - colliderGroups: [{ node, colliders: [{ offset, radius }] }]
 *
 * 本任务仅解析保存,不实现物理模拟 Runtime。
 *
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/spec/springBone/
 * - VRM 0.x: https://vrm.dev/vrm0/springbone.html
 */

import { VrmVersion } from './VrmVersion';

/**
 * 碰撞体形状类型。
 */
export enum VrmColliderShapeType {
  /** 球体碰撞体 */
  Sphere = 'sphere',
  /** 胶囊体碰撞体(VRM1 专有) */
  Capsule = 'capsule'
}

/**
 * 碰撞体形状参数。
 */
export interface VrmColliderShape {
  /** 形状类型 */
  type: VrmColliderShapeType;
  /** 偏移 [x, y, z](相对节点) */
  offset: number[];
  /** 半径 */
  radius: number;
  /** 胶囊尾端偏移 [x, y, z](仅 capsule) */
  tail: number[] | null;
}

/**
 * 碰撞体定义。
 */
export interface VrmCollider {
  /** glTF 节点索引 */
  nodeIndex: number;
  /** 碰撞体形状 */
  shape: VrmColliderShape;
}

/**
 * 碰撞体组。
 */
export interface VrmColliderGroup {
  /** 组名 */
  name: string;
  /** 包含的碰撞体索引列表(指向 colliders 数组) */
  colliderIndices: number[];
}

/**
 * SpringBone 关节(单个骨骼节点)。
 */
export interface VrmSpringBoneJoint {
  /** glTF 节点索引 */
  nodeIndex: number;
  /** 碰撞检测半径 */
  hitRadius: number;
  /** 刚度(回复力) */
  stiffness: number;
  /** 重力强度 */
  gravityPower: number;
  /** 重力方向相对起始骨骼(VRM1: gravityFromStartBone;VRM0: gravityDir 归一化后) */
  gravityFromStartBone: number[];
  /** 阻力 */
  dragForce: number;
  /** 中心节点索引(VRM0: center;-1 表示无) */
  centerNodeIndex: number;
}

/**
 * 单条 SpringBone 链(spring)。
 */
export interface VrmSpring {
  /** 链名 */
  name: string;
  /** 关节列表(按链顺序) */
  joints: VrmSpringBoneJoint[];
  /** 关联的碰撞体组索引列表 */
  colliderGroupIndices: number[];
}

/**
 * VRM SpringBone 配置集合。
 */
export interface VrmSpringBoneSet {
  /** VRM 版本 */
  version: VrmVersion;
  /** 所有碰撞体 */
  colliders: VrmCollider[];
  /** 碰撞体组 */
  colliderGroups: VrmColliderGroup[];
  /** 弹簧链列表 */
  springs: VrmSpring[];
  /** 关节总数 */
  totalJointCount: number;
  /** 解析是否成功 */
  valid: boolean;
  /** 原始 springBone JSON 哈希 */
  springBoneHash: string;
}

/**
 * 创建空 SpringBone 配置。
 */
export function createEmptyVrmSpringBoneSet(version: VrmVersion): VrmSpringBoneSet {
  return {
    version: version,
    colliders: [],
    colliderGroups: [],
    springs: [],
    totalJointCount: 0,
    valid: false,
    springBoneHash: ''
  };
}
