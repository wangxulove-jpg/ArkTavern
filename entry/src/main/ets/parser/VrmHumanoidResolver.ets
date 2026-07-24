/**
 * VrmHumanoidResolver VRM Humanoid 解析结果与转换
 *
 * T-4.1 A6: VRM 显式映射解析结果。
 *
 * 职责:
 * - 将 VrmHumanoid(VRM 扩展解析产物)转换为 HumanoidJointBinding[](带 VrmDeclared 标记)
 * - 生成 VrmHumanoidParseResult 摘要(声明数/有效数/无效数/重复数)
 * - 将 VRM 映射转换为 BoneMappingResult(兼容旧 UI 和持久化)
 *
 * VRM 显式映射是模型作者的声明,confidence=1.0,不是算法猜测。
 */

import { HumanoidBone, REQUIRED_BONES, BoneMappingResult, HumanoidBoneMapping, SkeletonProfile, CompatibilityLevel } from '../models/character3d/HumanoidBone';
import { HumanoidJointBinding, BoneMappingMethod } from '../models/character3d/ManualHumanoidMapping';
import { VrmHumanoid, VrmHumanoidBone } from '../models/character3d/vrm/VrmHumanoid';
import { VrmVersion, isVrm } from '../models/character3d/vrm/VrmVersion';
import { VrmAsset } from '../models/character3d/vrm/VrmAsset';
import { parseVrmHumanoidBoneKey } from './VrmBoneKeyParser';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'VrmHumanoidResolver';

/** VRM Humanoid 解析器版本(缓存失效用) */
export const VRM_HUMANOID_PARSER_VERSION: number = 1;

/**
 * VRM Humanoid 解析结果。
 */
export interface VrmHumanoidParseResult {
  /** 是否检测到 VRM */
  detected: boolean;
  /** VRM 版本 */
  version: VrmVersion;
  /** 声明的骨骼总数(含无效/重复/未知) */
  declaredBoneCount: number;
  /** 有效骨骼数(成功映射到 HumanoidBone 且 nodeIndex 合法) */
  validBoneCount: number;
  /** 无效骨骼数(nodeIndex 越界或未知键) */
  invalidBoneCount: number;
  /** 重复骨骼数(同一 HumanoidBone 被多次声明) */
  duplicateBoneCount: number;
  /** 生成的绑定列表 */
  bindings: HumanoidJointBinding[];
  /** 缺失的必需骨骼 */
  missingRequired: HumanoidBone[];
  /** 警告信息 */
  warnings: string[];
}

/**
 * 将 VrmHumanoid 转换为 HumanoidJointBinding[](带 VrmDeclared 标记)。
 *
 * @param vrmHumanoid VRM Humanoid 解析结果
 * @param nodeNames glTF 节点名称列表(用于填充 sourceBoneName)
 * @param nodeCount glTF 节点总数(用于校验 nodeIndex)
 * @returns VrmHumanoidParseResult
 */
export function resolveVrmHumanoid(
  vrmHumanoid: VrmHumanoid,
  nodeNames: string[],
  nodeCount: number
): VrmHumanoidParseResult {
  const result: VrmHumanoidParseResult = {
    detected: isVrm(vrmHumanoid.version),
    version: vrmHumanoid.version,
    declaredBoneCount: vrmHumanoid.bones.length + vrmHumanoid.extendedBones.length,
    validBoneCount: 0,
    invalidBoneCount: 0,
    duplicateBoneCount: 0,
    bindings: [],
    missingRequired: [],
    warnings: []
  };

  if (!result.detected) {
    return result;
  }

  // 用于检测重复
  const seenTargets: HumanoidBone[] = [];
  const bindings: HumanoidJointBinding[] = [];

  // 处理标准骨骼
  for (let i: number = 0; i < vrmHumanoid.bones.length; i++) {
    const vrmBone: VrmHumanoidBone = vrmHumanoid.bones[i];
    // 校验 nodeIndex
    if (vrmBone.nodeIndex < 0 || vrmBone.nodeIndex >= nodeCount) {
      result.invalidBoneCount++;
      result.warnings.push('invalid nodeIndex=' + vrmBone.nodeIndex
        + ' for bone=' + vrmBone.vrmBoneName);
      continue;
    }
    // 检测重复
    if (containsBone(seenTargets, vrmBone.target)) {
      result.duplicateBoneCount++;
      result.warnings.push('duplicate bone: ' + vrmBone.vrmBoneName
        + ' → ' + vrmBone.target);
      continue;
    }
    seenTargets.push(vrmBone.target);

    const nodeName: string = vrmBone.nodeIndex < nodeNames.length
      ? nodeNames[vrmBone.nodeIndex] : '';

    const binding: HumanoidJointBinding = {
      targetJoint: vrmBone.target,
      sourceNodeIndex: vrmBone.nodeIndex,
      sourceBoneName: nodeName.length > 0 ? nodeName : ('node_' + vrmBone.nodeIndex),
      mappingMethod: BoneMappingMethod.VrmDeclared,
      confidence: 1.0
    };
    bindings.push(binding);
    result.validBoneCount++;
  }

  result.bindings = bindings;

  // 计算缺失必需骨骼
  const missingRequired: HumanoidBone[] = [];
  for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
    if (!containsBone(seenTargets, REQUIRED_BONES[i])) {
      missingRequired.push(REQUIRED_BONES[i]);
    }
  }
  result.missingRequired = missingRequired;

  Logger.info(LOG_TAG, 'resolveVrmHumanoid: version=' + result.version
    + ', declared=' + result.declaredBoneCount
    + ', valid=' + result.validBoneCount
    + ', invalid=' + result.invalidBoneCount
    + ', duplicate=' + result.duplicateBoneCount
    + ', missingRequired=' + result.missingRequired.length);

  return result;
}

/**
 * 将 VRM Humanoid 映射转换为 BoneMappingResult(兼容旧持久化和 UI)。
 *
 * VRM 映射的 confidence=1.0,profile 为 VRM0 或 VRM1。
 * 这使得旧的 applyAutoMapping 逻辑可以直接使用(阈值 0.85 通过)。
 *
 * @param parseResult VRM Humanoid 解析结果
 * @param nodeNames glTF 节点名称列表
 * @param modelId 模型 ID
 * @returns BoneMappingResult
 */
export function vrmParseResultToBoneMappingResult(
  parseResult: VrmHumanoidParseResult,
  nodeNames: string[],
  modelId: string
): BoneMappingResult {
  const mappings: HumanoidBoneMapping[] = [];
  for (let i: number = 0; i < parseResult.bindings.length; i++) {
    const b: HumanoidJointBinding = parseResult.bindings[i];
    const required: boolean = isRequiredBone(b.targetJoint);
    const mapping: HumanoidBoneMapping = {
      profileId: parseResult.version === VrmVersion.Vrm1
        ? SkeletonProfile.VRM1 : SkeletonProfile.VRM0,
      modelId: modelId,
      standardBone: b.targetJoint,
      sourceNodeName: b.sourceBoneName,
      sourceNodeIndex: b.sourceNodeIndex,
      confidence: 1.0,
      required: required,
      valid: true
    };
    mappings.push(mapping);
  }

  // 兼容等级
  let compatibility: CompatibilityLevel;
  if (parseResult.validBoneCount === 0) {
    compatibility = CompatibilityLevel.EmbeddedOnly;
  } else if (parseResult.missingRequired.length > 0) {
    compatibility = CompatibilityLevel.PartialHumanoid;
  } else {
    compatibility = CompatibilityLevel.FullHumanoid;
  }

  return {
    profile: parseResult.version === VrmVersion.Vrm1
      ? SkeletonProfile.VRM1 : SkeletonProfile.VRM0,
    mappings: mappings,
    missingRequired: parseResult.missingRequired,
    compatibility: compatibility,
    nodeNames: nodeNames
  };
}

/**
 * 判断是否为必需骨骼。
 */
function isRequiredBone(bone: HumanoidBone): boolean {
  for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
    if (REQUIRED_BONES[i] === bone) {
      return true;
    }
  }
  return false;
}

/**
 * 数组中是否包含指定骨骼。
 */
function containsBone(arr: HumanoidBone[], bone: HumanoidBone): boolean {
  for (let i: number = 0; i < arr.length; i++) {
    if (arr[i] === bone) {
      return true;
    }
  }
  return false;
}
