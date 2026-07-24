/**
 * VrmHumanoid VRM Humanoid 骨骼映射
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 在 extensions.VRMC_vrm.humanoid.humanBones(1.0)或
 * extensions.VRM.humanoid.humanBones(0.x)中显式声明了标准骨骼到节点索引的映射。
 * 这是 VRM 优于普通 GLB 的核心:无需名称推断。
 *
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/spec/core/#humanoid
 * - VRM 0.x: https://vrm.dev/vrm0/unihumanoid.html
 */

import { HumanoidBone } from '../HumanoidBone';
import { VrmVersion } from './VrmVersion';

/**
 * VRM 1.0 标准骨骼名(VRM 1.0 使用 lowerCamelCase)。
 *
 * 用于将 VRMC_vrm.humanoid.humanBones 的 key 映射到内部 HumanoidBone 枚举。
 */
export const VRM1_HUMANOID_BONE_KEYS: string[] = [
  'hips', 'spine', 'chest', 'upperChest', 'neck', 'head',
  'leftShoulder', 'leftUpperArm', 'leftLowerArm', 'leftHand',
  'rightShoulder', 'rightUpperArm', 'rightLowerArm', 'rightHand',
  'leftUpperLeg', 'leftLowerLeg', 'leftFoot', 'leftToes',
  'rightUpperLeg', 'rightLowerLeg', 'rightFoot', 'rightToes',
  'leftEye', 'rightEye', 'jaw'
];

/**
 * VRM 0.x 标准骨骼名(VRM 0.x 使用小写下划线风格)。
 */
export const VRM0_HUMANOID_BONE_KEYS: string[] = VRM1_HUMANOID_BONE_KEYS;

/**
 * VRM 0.x 扩展骨骼(fingers 等,暂不完整支持,仅记录)。
 */
export const VRM0_EXTENDED_BONE_KEYS: string[] = [
  'leftThumbProximal', 'leftThumbIntermediate', 'leftThumbDistal',
  'leftIndexProximal', 'leftIndexIntermediate', 'leftIndexDistal',
  'leftMiddleProximal', 'leftMiddleIntermediate', 'leftMiddleDistal',
  'leftRingProximal', 'leftRingIntermediate', 'leftRingDistal',
  'leftLittleProximal', 'leftLittleIntermediate', 'leftLittleDistal',
  'rightThumbProximal', 'rightThumbIntermediate', 'rightThumbDistal',
  'rightIndexProximal', 'rightIndexIntermediate', 'rightIndexDistal',
  'rightMiddleProximal', 'rightMiddleIntermediate', 'rightMiddleDistal',
  'rightRingProximal', 'rightRingIntermediate', 'rightRingDistal',
  'rightLittleProximal', 'rightLittleIntermediate', 'rightLittleDistal'
];

/**
 * 单个 VRM Humanoid 骨骼绑定。
 */
export interface VrmHumanoidBone {
  /** 内部标准骨骼枚举 */
  target: HumanoidBone;
  /** VRM 原始骨骼名(如 "leftUpperArm") */
  vrmBoneName: string;
  /** glTF 节点索引(VRM1: node 字段;VRM0: 通过 bone 名称解析) */
  nodeIndex: number;
  /** 节点名称(解析得到,VRM0: bone 字段;VRM1: nodes[nodeIndex].name) */
  nodeName: string;
  /** 是否使用默认值(VRM 规范字段,影响 rest pose) */
  useDefaultValues: boolean;
  /** 置信度(1.0 = VRM 显式映射,完全可信) */
  confidence: number;
}

/**
 * VRM Humanoid 映射结果。
 */
export interface VrmHumanoid {
  /** VRM 版本 */
  version: VrmVersion;
  /** 标准骨骼绑定列表(24 个 HumanoidBone 中已找到的) */
  bones: VrmHumanoidBone[];
  /** 扩展骨骼绑定列表(fingers 等,VRM0 专有,仅记录不进入标准枚举) */
  extendedBones: VrmHumanoidBone[];
  /** 缺失的必需骨骼(7 个) */
  missingRequired: HumanoidBone[];
  /** 缺失的可选骨骼 */
  missingOptional: HumanoidBone[];
  /** 已映射必需骨骼数 */
  mappedRequiredCount: number;
  /** 总映射数 */
  totalMappedCount: number;
  /** 解析是否成功(VRM 扩展存在且至少 1 个骨骼被映射) */
  valid: boolean;
  /** 原始 humanBones JSON 哈希(用于校验) */
  humanoidHash: string;
}

/**
 * 创建空 VRM Humanoid 映射。
 */
export function createEmptyVrmHumanoid(version: VrmVersion): VrmHumanoid {
  return {
    version: version,
    bones: [],
    extendedBones: [],
    missingRequired: [],
    missingOptional: [],
    mappedRequiredCount: 0,
    totalMappedCount: 0,
    valid: false,
    humanoidHash: ''
  };
}
