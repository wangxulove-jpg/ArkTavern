/**
 * HumanoidProvider 统一人形骨骼访问接口
 *
 * T-4.0: VRM First Architecture
 *
 * 设计目标:T-4.0 起,动作系统永远不直接操作 Bone Name,
 * 统一通过 HumanoidProvider 访问标准人形骨骼。
 *
 * 数据来源优先级:
 * 1. VRM HumanBones(VRM 显式映射,confidence=1.0)
 * 2. Manual Mapping(手动映射/表面点选)
 * 3. Auto Mapping(名称推断,置信度最低)
 *
 * 本接口仅提供"查询"能力,不提供"修改"能力。
 * 修改映射通过 HumanoidMappingPage / VRMImporter 落盘后重新构建 Provider。
 *
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/spec/core/#humanoid
 */

import { HumanoidBone, REQUIRED_BONES, ALL_STANDARD_BONES } from '../models/character3d/HumanoidBone';
import { VrmHumanoid, VrmHumanoidBone } from '../models/character3d/vrm/VrmHumanoid';
import { ManualHumanoidMapping, HumanoidJointBinding, BoneMappingMethod } from '../models/character3d/ManualHumanoidMapping';

/**
 * 单个骨骼查询结果。
 */
export interface HumanoidBoneQueryResult {
  /** 目标标准骨骼 */
  target: HumanoidBone;
  /** glTF 节点索引(-1 表示未映射) */
  nodeIndex: number;
  /** 节点名称(空表示未知) */
  nodeName: string;
  /** 映射来源 */
  source: HumanoidMappingSource;
  /** 置信度 0~1 */
  confidence: number;
  /** 是否已映射 */
  mapped: boolean;
}

/**
 * 骨骼映射来源。
 */
export enum HumanoidMappingSource {
  /** VRM 显式映射(最高优先级) */
  VrmExplicit = 'VrmExplicit',
  /** 手动骨骼树选择 */
  ManualTree = 'ManualTree',
  /** 手动表面点选 */
  ManualSurface = 'ManualSurface',
  /** 手动(旧格式,未区分树/表面) */
  Manual = 'Manual',
  /** 自动名称匹配(最低优先级) */
  Auto = 'Auto',
  /** 未映射 */
  None = 'None'
}

/**
 * HumanoidProvider 构建输入。
 */
export interface HumanoidProviderInput {
  /** VRM Humanoid 映射(非 VRM 或无 humanoid 为 null) */
  vrmHumanoid: VrmHumanoid | null;
  /** 手动映射(普通 GLB 回退方案) */
  manualMapping: ManualHumanoidMapping | null;
  /** 自动映射结果(nodeIndex by bone name) */
  autoMapping: Map<HumanoidBone, number> | null;
}

/**
 * HumanoidProvider 统一人形骨骼访问器。
 *
 * 不可变快照:构建后所有查询基于构建时的映射状态。
 */
export class HumanoidProvider {
  /** bone → queryResult 缓存 */
  private readonly boneMap: Map<HumanoidBone, HumanoidBoneQueryResult> = new Map();
  /** 总映射数 */
  private readonly mappedCount: number;
  /** 必需骨骼映射数 */
  private readonly requiredMappedCount: number;
  /** 最高优先级来源 */
  private readonly primarySource: HumanoidMappingSource;

  constructor(input: HumanoidProviderInput) {
    // 按优先级填充:VRM > Manual(Surface/Tree/Manual) > Auto
    // 先放 Auto(最低),再放 Manual(覆盖 Auto),再放 VRM(覆盖 Manual)
    if (input.autoMapping !== null) {
      input.autoMapping.forEach((nodeIndex: number, bone: HumanoidBone) => {
        this.boneMap.set(bone, {
          target: bone,
          nodeIndex: nodeIndex,
          nodeName: '',
          source: HumanoidMappingSource.Auto,
          confidence: 0.7,
          mapped: true
        });
      });
    }
    if (input.manualMapping !== null) {
      for (let i: number = 0; i < input.manualMapping.joints.length; i++) {
        const binding: HumanoidJointBinding = input.manualMapping.joints[i];
        const source: HumanoidMappingSource = HumanoidProvider.toSource(binding.mappingMethod);
        this.boneMap.set(binding.targetJoint, {
          target: binding.targetJoint,
          nodeIndex: binding.sourceNodeIndex,
          nodeName: binding.sourceBoneName,
          source: source,
          confidence: binding.confidence,
          mapped: true
        });
      }
    }
    if (input.vrmHumanoid !== null && input.vrmHumanoid.valid) {
      for (let i: number = 0; i < input.vrmHumanoid.bones.length; i++) {
        const vbone: VrmHumanoidBone = input.vrmHumanoid.bones[i];
        this.boneMap.set(vbone.target, {
          target: vbone.target,
          nodeIndex: vbone.nodeIndex,
          nodeName: vbone.nodeName,
          source: HumanoidMappingSource.VrmExplicit,
          confidence: 1.0,
          mapped: true
        });
      }
    }

    // 统计
    let mapped: number = 0;
    let requiredMapped: number = 0;
    let hasVrm: boolean = false;
    let hasManual: boolean = false;
    let hasAuto: boolean = false;
    this.boneMap.forEach((result: HumanoidBoneQueryResult) => {
      if (result.mapped) {
        mapped++;
        if (HumanoidProvider.isRequired(result.target)) {
          requiredMapped++;
        }
        if (result.source === HumanoidMappingSource.VrmExplicit) {
          hasVrm = true;
        } else if (result.source === HumanoidMappingSource.ManualTree
          || result.source === HumanoidMappingSource.ManualSurface
          || result.source === HumanoidMappingSource.Manual) {
          hasManual = true;
        } else if (result.source === HumanoidMappingSource.Auto) {
          hasAuto = true;
        }
      }
    });
    this.mappedCount = mapped;
    this.requiredMappedCount = requiredMapped;
    if (hasVrm) {
      this.primarySource = HumanoidMappingSource.VrmExplicit;
    } else if (hasManual) {
      this.primarySource = HumanoidMappingSource.Manual;
    } else if (hasAuto) {
      this.primarySource = HumanoidMappingSource.Auto;
    } else {
      this.primarySource = HumanoidMappingSource.None;
    }
  }

  /** 查询单个骨骼 */
  getBone(bone: HumanoidBone): HumanoidBoneQueryResult {
    const result: HumanoidBoneQueryResult | undefined = this.boneMap.get(bone);
    if (result !== undefined) {
      return result;
    }
    return {
      target: bone,
      nodeIndex: -1,
      nodeName: '',
      source: HumanoidMappingSource.None,
      confidence: 0,
      mapped: false
    };
  }

  /** 便捷查询 */
  getHead(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.Head); }
  getHips(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.Hips); }
  getChest(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.Chest); }
  getSpine(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.Spine); }
  getNeck(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.Neck); }
  getLeftUpperArm(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.LeftUpperArm); }
  getRightUpperArm(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.RightUpperArm); }
  getLeftLowerArm(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.LeftLowerArm); }
  getRightLowerArm(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.RightLowerArm); }
  getLeftHand(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.LeftHand); }
  getRightHand(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.RightHand); }
  getLeftUpperLeg(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.LeftUpperLeg); }
  getRightUpperLeg(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.RightUpperLeg); }
  getLeftLowerLeg(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.LeftLowerLeg); }
  getRightLowerLeg(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.RightLowerLeg); }
  getLeftFoot(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.LeftFoot); }
  getRightFoot(): HumanoidBoneQueryResult { return this.getBone(HumanoidBone.RightFoot); }

  /** 已映射骨骼总数 */
  getMappedCount(): number { return this.mappedCount; }

  /** 必需骨骼已映射数(共 7 个) */
  getRequiredMappedCount(): number { return this.requiredMappedCount; }

  /** 是否所有必需骨骼已映射 */
  isRequiredComplete(): boolean { return this.requiredMappedCount === REQUIRED_BONES.length; }

  /** 主要映射来源 */
  getPrimarySource(): HumanoidMappingSource { return this.primarySource; }

  /** 是否来自 VRM 显式映射 */
  isFromVrm(): boolean { return this.primarySource === HumanoidMappingSource.VrmExplicit; }

  /** 获取所有已映射骨骼 */
  getAllMappedBones(): HumanoidBoneQueryResult[] {
    const result: HumanoidBoneQueryResult[] = [];
    this.boneMap.forEach((r: HumanoidBoneQueryResult) => {
      if (r.mapped) {
        result.push(r);
      }
    });
    return result;
  }

  /** 获取缺失的必需骨骼 */
  getMissingRequired(): HumanoidBone[] {
    const missing: HumanoidBone[] = [];
    for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
      const r: HumanoidBoneQueryResult = this.getBone(REQUIRED_BONES[i]);
      if (!r.mapped) {
        missing.push(REQUIRED_BONES[i]);
      }
    }
    return missing;
  }

  /** 获取缺失的可选骨骼 */
  getMissingOptional(): HumanoidBone[] {
    const missing: HumanoidBone[] = [];
    for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
      const bone: HumanoidBone = ALL_STANDARD_BONES[i];
      if (HumanoidProvider.isRequired(bone)) {
        continue;
      }
      const r: HumanoidBoneQueryResult = this.getBone(bone);
      if (!r.mapped) {
        missing.push(bone);
      }
    }
    return missing;
  }

  private static isRequired(bone: HumanoidBone): boolean {
    for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
      if (REQUIRED_BONES[i] === bone) {
        return true;
      }
    }
    return false;
  }

  private static toSource(method: BoneMappingMethod): HumanoidMappingSource {
    if (method === BoneMappingMethod.Auto) {
      return HumanoidMappingSource.Auto;
    }
    if (method === BoneMappingMethod.ManualTree) {
      return HumanoidMappingSource.ManualTree;
    }
    if (method === BoneMappingMethod.ManualSurface) {
      return HumanoidMappingSource.ManualSurface;
    }
    return HumanoidMappingSource.Manual;
  }
}
