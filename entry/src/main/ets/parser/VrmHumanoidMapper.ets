/**
 * VrmHumanoidMapper VRM Humanoid 骨骼映射解析器
 *
 * T-4.0: VRM First Architecture
 *
 * 从 VRMC_vrm.humanoid.humanBones(VRM 1.0)或 VRM.humanoid.humanBones(VRM 0.x)
 * 提取显式骨骼映射,生成 VrmHumanoid。
 *
 * VRM 1.0:humanBones[key] = { node: number, useDefaultValues: boolean }
 *   key 是 lowerCamelCase 骨骼名(如 "leftUpperArm"),node 是 glTF 节点索引
 * VRM 0.x:humanBones = [ { bone: string, node: number, useDefaultValues: boolean, ... } ]
 *   bone 是标准骨骼语义键(如 "hips"),node 是 glTF 节点索引(直接使用,不通过名称反查)
 *
 * 这是 VRM 优于普通 GLB 的核心:显式映射,无需名称推断,confidence=1.0。
 */

import { HumanoidBone, REQUIRED_BONES, ALL_STANDARD_BONES } from '../models/character3d/HumanoidBone';
import { VrmVersion } from '../models/character3d/vrm/VrmVersion';
import {
  VrmHumanoid,
  VrmHumanoidBone,
  createEmptyVrmHumanoid,
  VRM1_HUMANOID_BONE_KEYS,
  VRM0_EXTENDED_BONE_KEYS
} from '../models/character3d/vrm/VrmHumanoid';
import {
  getObject,
  getObjectEntries,
  getObjectArray,
  getNumber,
  getBoolean,
  getString,
  VrmObjectEntry
} from './VrmExtensionParser';
import { parseVrmHumanoidBoneKey } from './VrmBoneKeyParser';

/**
 * T-4.1 A5: 统一骨骼键转换。
 *
 * 所有 VRM 骨骼键(lowerCamelCase)→ HumanoidBone 枚举的转换
 * 统一由 VrmBoneKeyParser.parseVrmHumanoidBoneKey 处理,
 * 本文件不再维护独立的映射表,避免两处真值。
 */

/**
 * 解析 VRM Humanoid 骨骼映射。
 *
 * @param version VRM 版本
 * @param vrmcVrm VRMC_vrm 扩展对象(VRM 1.0)
 * @param vrm0Extension VRM 扩展对象(VRM 0.x)
 * @param nodeNames glTF 节点名称数组(VRM 0.x 用于 bone 名反查索引;VRM 1.0 用于记录节点名)
 * @param nodeCount glTF 节点总数(用于校验 nodeIndex 范围)
 * @returns VRM Humanoid 映射
 */
export function parseVrmHumanoid(
  version: VrmVersion,
  vrmcVrm: Record<string, Object> | null,
  vrm0Extension: Record<string, Object> | null,
  nodeNames: string[],
  nodeCount: number
): VrmHumanoid {
  if (version === VrmVersion.Vrm1 && vrmcVrm !== null) {
    return parseVrm1Humanoid(vrmcVrm, nodeNames, nodeCount);
  }
  if (version === VrmVersion.Vrm0x && vrm0Extension !== null) {
    return parseVrm0Humanoid(vrm0Extension, nodeNames, nodeCount);
  }
  return createEmptyVrmHumanoid(version);
}

/**
 * 解析 VRM 1.0 Humanoid(VRMC_vrm.humanoid.humanBones)。
 *
 * VRM 1.0 的 humanBones 是对象:
 *   { "hips": { "node": 1 }, "head": { "node": 8 }, ... }
 * key 是 lowerCamelCase 标准骨骼名,node 是 glTF 节点索引。
 *
 * T-4.1 A3: 不根据 nodes[node].name 猜测骨骼语义,
 * VRM humanBones 的 key 是模型作者的显式声明,是第一优先级真值。
 */
function parseVrm1Humanoid(
  vrmcVrm: Record<string, Object>,
  nodeNames: string[],
  nodeCount: number
): VrmHumanoid {
  const result: VrmHumanoid = createEmptyVrmHumanoid(VrmVersion.Vrm1);
  const humanoidObj: Record<string, Object> | null = getObject(vrmcVrm, 'humanoid');
  if (humanoidObj === null) {
    return result;
  }
  const humanBonesObj: Record<string, Object> | null = getObject(humanoidObj, 'humanBones');
  if (humanBonesObj === null) {
    return result;
  }

  const entries: VrmObjectEntry[] = getObjectEntries(humanBonesObj);
  const bones: VrmHumanoidBone[] = [];
  const extendedBones: VrmHumanoidBone[] = [];

  for (let i: number = 0; i < entries.length; i++) {
    const entry: VrmObjectEntry = entries[i];
    const vrmBoneName: string = entry.key;
    const boneDef: Record<string, Object> = entry.value;

    // T-4.1 A5: 统一使用 parseVrmHumanoidBoneKey 转换骨骼键
    const target: HumanoidBone | null = parseVrmHumanoidBoneKey(vrmBoneName);
    // node 字段是 glTF 节点索引(显式声明,非名称查找)
    const nodeIndex: number = getNumber(boneDef, 'node', -1);
    const useDefaultValues: boolean = getBoolean(boneDef, 'useDefaultValues', true);

    // 校验 nodeIndex
    if (nodeIndex < 0 || nodeIndex >= nodeCount) {
      continue;
    }
    // 节点名来自 nodes[nodeIndex].name(仅用于显示,不用于映射判断)
    const nodeName: string = nodeIndex < nodeNames.length ? nodeNames[nodeIndex] : '';

    const vrmBone: VrmHumanoidBone = {
      target: target !== null ? target : HumanoidBone.Head, // 扩展骨骼占位,下方分流
      vrmBoneName: vrmBoneName,
      nodeIndex: nodeIndex,
      nodeName: nodeName,
      useDefaultValues: useDefaultValues,
      confidence: 1.0
    };

    if (target !== null) {
      vrmBone.target = target;
      bones.push(vrmBone);
    } else {
      // 扩展骨骼(fingers 等),仅记录
      extendedBones.push(vrmBone);
    }
  }

  result.bones = bones;
  result.extendedBones = extendedBones;
  result.totalMappedCount = bones.length;
  result.missingRequired = computeMissingRequired(bones);
  result.missingOptional = computeMissingOptional(bones);
  result.mappedRequiredCount = REQUIRED_BONES.length - result.missingRequired.length;
  result.valid = bones.length > 0;
  return result;
}

/**
 * 解析 VRM 0.x Humanoid(VRM.humanoid.humanBones)。
 *
 * T-4.1 A4: VRM 0.x 的 humanBones 是数组:
 *   [
 *     { "bone": "hips", "node": 1, "useDefaultValues": true },
 *     { "bone": "head", "node": 8, "useDefaultValues": true }
 *   ]
 *
 * 重点:
 * - bone 是标准人体骨骼语义(如 "hips"),不是实际节点名称
 * - node 是 glTF 节点索引(直接使用,不通过名称反查)
 * - 不得使用 bone 去 nodes[].name 中搜索
 * - 不得把 humanBones 强制转换为 Record/对象遍历
 * - 不得把数组下标当作 nodeIndex
 *
 * 正确生成:
 *   targetJoint = parseVrmHumanoidBoneKey(entry.bone)
 *   sourceNodeIndex = entry.node
 *   sourceBoneName = nodes[entry.node].name
 */
function parseVrm0Humanoid(
  vrm0Ext: Record<string, Object>,
  nodeNames: string[],
  nodeCount: number
): VrmHumanoid {
  const result: VrmHumanoid = createEmptyVrmHumanoid(VrmVersion.Vrm0x);
  const humanoidObj: Record<string, Object> | null = getObject(vrm0Ext, 'humanoid');
  if (humanoidObj === null) {
    return result;
  }

  // T-4.1 A4: VRM 0.x humanBones 是数组,用 getObjectArray 读取
  const humanBonesArr: Record<string, Object>[] = getObjectArray(humanoidObj, 'humanBones');
  if (humanBonesArr.length === 0) {
    return result;
  }

  const bones: VrmHumanoidBone[] = [];
  const extendedBones: VrmHumanoidBone[] = [];

  for (let i: number = 0; i < humanBonesArr.length; i++) {
    const boneDef: Record<string, Object> = humanBonesArr[i];

    // bone 字段是标准骨骼语义键(如 "hips","leftUpperArm")
    const boneKey: string = getString(boneDef, 'bone');
    // T-4.1 A5: 统一使用 parseVrmHumanoidBoneKey 转换骨骼键
    const target: HumanoidBone | null = parseVrmHumanoidBoneKey(boneKey);
    // node 字段是 glTF 节点索引(直接使用,不通过名称反查)
    const nodeIndex: number = getNumber(boneDef, 'node', -1);
    const useDefaultValues: boolean = getBoolean(boneDef, 'useDefaultValues', true);

    // 校验 nodeIndex
    if (nodeIndex < 0 || nodeIndex >= nodeCount) {
      continue;
    }
    // 节点名来自 nodes[nodeIndex].name(仅用于显示)
    const nodeName: string = nodeIndex < nodeNames.length ? nodeNames[nodeIndex] : '';

    const vrmBone: VrmHumanoidBone = {
      target: target !== null ? target : HumanoidBone.Head,
      vrmBoneName: boneKey,
      nodeIndex: nodeIndex,
      nodeName: nodeName,
      useDefaultValues: useDefaultValues,
      confidence: 1.0
    };

    if (target !== null) {
      vrmBone.target = target;
      bones.push(vrmBone);
    } else {
      extendedBones.push(vrmBone);
    }
  }

  result.bones = bones;
  result.extendedBones = extendedBones;
  result.totalMappedCount = bones.length;
  result.missingRequired = computeMissingRequired(bones);
  result.missingOptional = computeMissingOptional(bones);
  result.mappedRequiredCount = REQUIRED_BONES.length - result.missingRequired.length;
  result.valid = bones.length > 0;
  return result;
}

/**
 * 计算缺失的必需骨骼。
 */
function computeMissingRequired(bones: VrmHumanoidBone[]): HumanoidBone[] {
  const present: Set<HumanoidBone> = new Set();
  for (let i: number = 0; i < bones.length; i++) {
    present.add(bones[i].target);
  }
  const missing: HumanoidBone[] = [];
  for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
    if (!present.has(REQUIRED_BONES[i])) {
      missing.push(REQUIRED_BONES[i]);
    }
  }
  return missing;
}

/**
 * 计算缺失的可选骨骼。
 */
function computeMissingOptional(bones: VrmHumanoidBone[]): HumanoidBone[] {
  const present: Set<HumanoidBone> = new Set();
  for (let i: number = 0; i < bones.length; i++) {
    present.add(bones[i].target);
  }
  const requiredSet: Set<HumanoidBone> = new Set();
  for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
    requiredSet.add(REQUIRED_BONES[i]);
  }
  const missing: HumanoidBone[] = [];
  for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
    const bone: HumanoidBone = ALL_STANDARD_BONES[i];
    if (requiredSet.has(bone)) {
      continue;
    }
    if (!present.has(bone)) {
      missing.push(bone);
    }
  }
  return missing;
}
