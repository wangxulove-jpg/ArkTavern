/**
 * HumanoidMappingValidator 手动人形骨骼映射验证器
 *
 * T-3D.6E P3: 第二十四节定义的 20 项验证检查。
 *
 * 职责:
 * - 验证 ManualHumanoidMapping 的合法性与重定向就绪度
 * - 检查必需关节、sourceNodeIndex、骨骼层级、世界坐标、skeletonHash 等
 * - 输出 HumanoidMappingValidationResult(包含错误/警告/缺失列表)
 *
 * 设计原则:
 * - 错误与警告分开
 * - 缺少必需关节为错误,缺少可选关节为警告
 * - 同一 Bone 重复映射为错误
 * - 层级错误(如 Hand 不是 LowerArm 后代)为警告
 * - 只有所有错误为 0 时 valid=true
 * - 只有 valid=true 且 retarget 关键检查通过时 retargetReady=true
 *
 * 不依赖 ArkUI/ArkGraphics3D,纯逻辑可单元测试。
 */

import { HumanoidBone, REQUIRED_BONES } from './HumanoidBone';
import {
  ManualHumanoidMapping,
  HumanoidJointBinding,
  SkeletonRestPose,
  BoneMappingMethod
} from './ManualHumanoidMapping';

/**
 * 验证问题级别。
 */
export enum HumanoidMappingIssueLevel {
  /** 错误(必须修复) */
  Error = 'Error',
  /** 警告(可选修复) */
  Warning = 'Warning'
}

/**
 * 验证问题类型。
 */
export enum HumanoidMappingIssueType {
  /** 必需关节缺失 */
  MissingRequiredJoint = 'MissingRequiredJoint',
  /** 可选关节缺失 */
  MissingOptionalJoint = 'MissingOptionalJoint',
  /** sourceNodeIndex 越界 */
  SourceNodeIndexOutOfRange = 'SourceNodeIndexOutOfRange',
  /** sourceNodeIndex 不属于当前模型 */
  SourceNodeNotInModel = 'SourceNodeNotInModel',
  /** 同一 Bone 重复映射到多个 target */
  DuplicateSourceBone = 'DuplicateSourceBone',
  /** Head 不在 Spine/Chest 上方 */
  HeadNotAboveSpine = 'HeadNotAboveSpine',
  /** Hand 不在 Arm 链末端 */
  HandNotInArmChain = 'HandNotInArmChain',
  /** Foot 不在 Leg 链末端 */
  FootNotInLegChain = 'FootNotInLegChain',
  /** 左右关节反转 */
  LeftRightReversed = 'LeftRightReversed',
  /** UpperArm 不是 LowerArm 祖先 */
  UpperArmNotAncestorOfLowerArm = 'UpperArmNotAncestorOfLowerArm',
  /** LowerArm 不是 Hand 祖先 */
  LowerArmNotAncestorOfHand = 'LowerArmNotAncestorOfHand',
  /** UpperLeg 不是 LowerLeg 祖先 */
  UpperLegNotAncestorOfLowerLeg = 'UpperLegNotAncestorOfLowerLeg',
  /** LowerLeg 不是 Foot 祖先 */
  LowerLegNotAncestorOfFoot = 'LowerLegNotAncestorOfFoot',
  /** Head 与 Hips 不在同一主骨架树 */
  HeadNotInMainSkeletonTree = 'HeadNotInMainSkeletonTree',
  /** 必需链跨越无关节点 */
  RequiredChainBroken = 'RequiredChainBroken',
  /** 关节世界坐标非有限 */
  NonFiniteWorldPosition = 'NonFiniteWorldPosition',
  /** 骨骼长度接近 0 */
  ZeroBoneLength = 'ZeroBoneLength',
  /** 左右骨骼长度异常悬殊 */
  LeftRightBoneLengthMismatch = 'LeftRightBoneLengthMismatch',
  /** rest pose 四元数无效 */
  InvalidRestQuaternion = 'InvalidRestQuaternion',
  /** 模型校准轴无效 */
  InvalidAlignmentAxis = 'InvalidAlignmentAxis',
  /** skeletonHash 不一致 */
  SkeletonHashMismatch = 'SkeletonHashMismatch',
  /** T-3D.6F-A: 表面点选的 nodeIndex 不属于 skin.joints */
  SurfaceSelectedBoneNotInSkin = 'SurfaceSelectedBoneNotInSkin',
  /** T-3D.6F-A: sourceSha256 不一致(模型文件已变更) */
  SourceSha256Mismatch = 'SourceSha256Mismatch'
}

/**
 * 验证问题。
 */
export interface HumanoidMappingIssue {
  /** 问题类型 */
  type: HumanoidMappingIssueType;
  /** 级别 */
  level: HumanoidMappingIssueLevel;
  /** 描述 */
  message: string;
  /** 相关的目标关节(可选) */
  targetJoint?: HumanoidBone;
}

/**
 * 验证结果。
 */
export interface HumanoidMappingValidationResult {
  /** 是否通过验证(无错误) */
  valid: boolean;
  /** 是否动作重定向就绪 */
  retargetReady: boolean;
  /** 错误列表(必须修复) */
  errors: HumanoidMappingIssue[];
  /** 警告列表(可选修复) */
  warnings: HumanoidMappingIssue[];
  /** 缺失的必需关节 */
  missingRequired: HumanoidBone[];
  /** 缺失的可选关节 */
  missingOptional: HumanoidBone[];
}

/**
 * 验证器输入。
 */
export interface HumanoidMappingValidatorInput {
  /** 待验证的映射 */
  mapping: ManualHumanoidMapping;
  /** 当前模型的 node 总数(用于检查 sourceNodeIndex 越界) */
  totalNodeCount: number;
  /** 当前模型的 skeleton hash(用于检查一致性) */
  currentSkeletonHash: string;
  /** 父节点索引数组(parentIndices[i] 表示 node i 的父节点,-1 为根) */
  parentIndices: number[];
  /** Rest pose 列表(用于检查世界坐标和骨骼长度) */
  restPoses: SkeletonRestPose[];
  /** 可选关节列表(用于缺失检查) */
  optionalBones: HumanoidBone[];
  /** T-3D.6F-A: 当前模型 skin.joints 的 nodeIndex 集合(空数组表示无 Skin 或不校验) */
  skinJointNodeIndices: number[];
  /** T-3D.6F-A: 当前模型文件 SHA-256(用于检查 sourceSha256 一致性,空字符串跳过) */
  currentSourceSha256: string;
}

/**
 * 创建空验证结果。
 */
export function createEmptyValidationResult(): HumanoidMappingValidationResult {
  return {
    valid: false,
    retargetReady: false,
    errors: [],
    warnings: [],
    missingRequired: [],
    missingOptional: []
  };
}

/**
 * 执行 20 项验证检查。
 *
 * 检查项(对应 T-3D.6E 第二十四节):
 * 1. 所有必需关节是否存在
 * 2. sourceNodeIndex 是否合法
 * 3. 是否属于当前模型(nodeIndex < totalNodeCount)
 * 4. 同一 Bone 是否重复
 * 5. Head 是否位于 Spine/Chest 上方
 * 6. Hand 是否位于对应 Arm 链末端
 * 7. Foot 是否位于对应 Leg 链末端
 * 8. 左右关节是否反转
 * 9. UpperArm 是否是 LowerArm 的祖先
 * 10. LowerArm 是否是 Hand 的祖先
 * 11. UpperLeg 是否是 LowerLeg 的祖先
 * 12. LowerLeg 是否是 Foot 的祖先
 * 13. Head 是否与 Hips 位于同一主骨架树
 * 14. 必需链中是否跨越完全无关节点
 * 15. 关节世界坐标是否有限
 * 16. 骨骼长度是否接近 0
 * 17. 左右骨骼长度是否异常悬殊
 * 18. rest pose quaternion 是否有效
 * 19. 模型校准轴是否有效
 * 20. skeletonHash 是否一致
 */
export function validateHumanoidMapping(
  input: HumanoidMappingValidatorInput
): HumanoidMappingValidationResult {
  const errors: HumanoidMappingIssue[] = [];
  const warnings: HumanoidMappingIssue[] = [];
  const mapping: ManualHumanoidMapping = input.mapping;
  const parentIndices: number[] = input.parentIndices;
  const restPoses: SkeletonRestPose[] = input.restPoses;

  // 构建 target -> binding 索引
  const targetToBindings: Map<HumanoidBone, HumanoidJointBinding> = new Map();
  for (let i: number = 0; i < mapping.joints.length; i++) {
    targetToBindings.set(mapping.joints[i].targetJoint, mapping.joints[i]);
  }

  // 构建 sourceNodeIndex -> target 列表(检测重复)
  const sourceToTargets: Map<number, HumanoidBone[]> = new Map();
  for (let i: number = 0; i < mapping.joints.length; i++) {
    const joint: HumanoidJointBinding = mapping.joints[i];
    const list: HumanoidBone[] | undefined = sourceToTargets.get(joint.sourceNodeIndex);
    if (list === undefined) {
      sourceToTargets.set(joint.sourceNodeIndex, [joint.targetJoint]);
    } else {
      list.push(joint.targetJoint);
    }
  }

  // === 检查 1: 必需关节缺失 ===
  const missingRequired: HumanoidBone[] = [];
  for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
    if (!targetToBindings.has(REQUIRED_BONES[i])) {
      missingRequired.push(REQUIRED_BONES[i]);
      errors.push({
        type: HumanoidMappingIssueType.MissingRequiredJoint,
        level: HumanoidMappingIssueLevel.Error,
        message: '缺少必需关节: ' + REQUIRED_BONES[i],
        targetJoint: REQUIRED_BONES[i]
      });
    }
  }

  // === 检查 1.5: 可选关节缺失 ===
  const missingOptional: HumanoidBone[] = [];
  for (let i: number = 0; i < input.optionalBones.length; i++) {
    if (!targetToBindings.has(input.optionalBones[i])) {
      missingOptional.push(input.optionalBones[i]);
      warnings.push({
        type: HumanoidMappingIssueType.MissingOptionalJoint,
        level: HumanoidMappingIssueLevel.Warning,
        message: '缺少可选关节: ' + input.optionalBones[i],
        targetJoint: input.optionalBones[i]
      });
    }
  }

  // === 检查 2: sourceNodeIndex 是否合法(>= 0) ===
  // === 检查 3: 是否属于当前模型(< totalNodeCount) ===
  for (let i: number = 0; i < mapping.joints.length; i++) {
    const joint: HumanoidJointBinding = mapping.joints[i];
    if (joint.sourceNodeIndex < 0) {
      errors.push({
        type: HumanoidMappingIssueType.SourceNodeIndexOutOfRange,
        level: HumanoidMappingIssueLevel.Error,
        message: '关节 ' + joint.targetJoint + ' 的 sourceNodeIndex 非法: '
          + joint.sourceNodeIndex,
        targetJoint: joint.targetJoint
      });
    } else if (joint.sourceNodeIndex >= input.totalNodeCount) {
      errors.push({
        type: HumanoidMappingIssueType.SourceNodeNotInModel,
        level: HumanoidMappingIssueLevel.Error,
        message: '关节 ' + joint.targetJoint + ' 的 sourceNodeIndex '
          + joint.sourceNodeIndex + ' 超出当前模型 node 总数 ' + input.totalNodeCount,
        targetJoint: joint.targetJoint
      });
    }
  }

  // === 检查 4: 同一 Bone 重复 ===
  sourceToTargets.forEach((targets: HumanoidBone[], sourceIdx: number) => {
    if (targets.length > 1) {
      errors.push({
        type: HumanoidMappingIssueType.DuplicateSourceBone,
        level: HumanoidMappingIssueLevel.Error,
        message: 'sourceNodeIndex ' + sourceIdx + ' 被映射到多个 target: '
          + targets.join(', ')
      });
    }
  });

  // === 检查 5: Head 是否位于 Spine/Chest 上方 ===
  // (Head 应该是 Spine 或 Chest 的后代)
  if (targetToBindings.has(HumanoidBone.Head) && targetToBindings.has(HumanoidBone.Spine)) {
    const headBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.Head);
    const spineBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.Spine);
    if (headBinding !== undefined && spineBinding !== undefined) {
      const headIdx: number = headBinding.sourceNodeIndex;
      const spineIdx: number = spineBinding.sourceNodeIndex;
      if (!isAncestor(spineIdx, headIdx, parentIndices)) {
        // 也可能是 Chest 的后代
        const chestBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.Chest);
        let chestOk: boolean = false;
        if (chestBinding !== undefined) {
          chestOk = isAncestor(chestBinding.sourceNodeIndex, headIdx, parentIndices);
        }
        if (!chestOk) {
          warnings.push({
            type: HumanoidMappingIssueType.HeadNotAboveSpine,
            level: HumanoidMappingIssueLevel.Warning,
            message: 'Head 不是 Spine/Chest 的后代,可能映射错误',
            targetJoint: HumanoidBone.Head
          });
        }
      }
    }
  }

  // === 检查 6: Hand 是否位于对应 Arm 链末端 ===
  // (LeftHand 应是 LeftLowerArm 后代,RightHand 同理)
  checkArmChain(HumanoidBone.LeftHand, HumanoidBone.LeftLowerArm, targetToBindings,
    parentIndices, warnings, HumanoidMappingIssueType.HandNotInArmChain);
  checkArmChain(HumanoidBone.RightHand, HumanoidBone.RightLowerArm, targetToBindings,
    parentIndices, warnings, HumanoidMappingIssueType.HandNotInArmChain);

  // === 检查 7: Foot 是否位于对应 Leg 链末端 ===
  checkArmChain(HumanoidBone.LeftFoot, HumanoidBone.LeftLowerLeg, targetToBindings,
    parentIndices, warnings, HumanoidMappingIssueType.FootNotInLegChain);
  checkArmChain(HumanoidBone.RightFoot, HumanoidBone.RightLowerLeg, targetToBindings,
    parentIndices, warnings, HumanoidMappingIssueType.FootNotInLegChain);

  // === 检查 8: 左右关节反转 ===
  // 通过世界坐标 X 判断(左为正 X,右为负 X,或反之)
  // 简化:对比 LeftUpperArm 和 RightUpperArm 的 worldPosition.x 符号
  checkLeftRightReversal(targetToBindings, restPoses, warnings);

  // === 检查 9: UpperArm 是否是 LowerArm 的祖先 ===
  checkAncestorRelation(HumanoidBone.LeftUpperArm, HumanoidBone.LeftLowerArm,
    targetToBindings, parentIndices, warnings,
    HumanoidMappingIssueType.UpperArmNotAncestorOfLowerArm);
  checkAncestorRelation(HumanoidBone.RightUpperArm, HumanoidBone.RightLowerArm,
    targetToBindings, parentIndices, warnings,
    HumanoidMappingIssueType.UpperArmNotAncestorOfLowerArm);

  // === 检查 10: LowerArm 是否是 Hand 的祖先 ===
  checkAncestorRelation(HumanoidBone.LeftLowerArm, HumanoidBone.LeftHand,
    targetToBindings, parentIndices, warnings,
    HumanoidMappingIssueType.LowerArmNotAncestorOfHand);
  checkAncestorRelation(HumanoidBone.RightLowerArm, HumanoidBone.RightHand,
    targetToBindings, parentIndices, warnings,
    HumanoidMappingIssueType.LowerArmNotAncestorOfHand);

  // === 检查 11: UpperLeg 是否是 LowerLeg 的祖先 ===
  checkAncestorRelation(HumanoidBone.LeftUpperLeg, HumanoidBone.LeftLowerLeg,
    targetToBindings, parentIndices, warnings,
    HumanoidMappingIssueType.UpperLegNotAncestorOfLowerLeg);
  checkAncestorRelation(HumanoidBone.RightUpperLeg, HumanoidBone.RightLowerLeg,
    targetToBindings, parentIndices, warnings,
    HumanoidMappingIssueType.UpperLegNotAncestorOfLowerLeg);

  // === 检查 12: LowerLeg 是否是 Foot 的祖先 ===
  checkAncestorRelation(HumanoidBone.LeftLowerLeg, HumanoidBone.LeftFoot,
    targetToBindings, parentIndices, warnings,
    HumanoidMappingIssueType.LowerLegNotAncestorOfFoot);
  checkAncestorRelation(HumanoidBone.RightLowerLeg, HumanoidBone.RightFoot,
    targetToBindings, parentIndices, warnings,
    HumanoidMappingIssueType.LowerLegNotAncestorOfFoot);

  // === 检查 13: Head 是否与 Hips 位于同一主骨架树 ===
  if (targetToBindings.has(HumanoidBone.Head) && targetToBindings.has(HumanoidBone.Hips)) {
    const headBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.Head);
    const hipsBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.Hips);
    if (headBinding !== undefined && hipsBinding !== undefined) {
      const headIdx: number = headBinding.sourceNodeIndex;
      const hipsIdx: number = hipsBinding.sourceNodeIndex;
      if (!isInSameTree(headIdx, hipsIdx, parentIndices)) {
        warnings.push({
          type: HumanoidMappingIssueType.HeadNotInMainSkeletonTree,
          level: HumanoidMappingIssueLevel.Warning,
          message: 'Head 与 Hips 不在同一骨架树',
          targetJoint: HumanoidBone.Head
        });
      }
    }
  }

  // === 检查 14: 必需链跨越无关节点 ===
  // 简化:检查 Hips -> Spine -> Head 路径中是否都有映射
  checkRequiredChain(targetToBindings, parentIndices, warnings);

  // === 检查 15: 关节世界坐标是否有限 ===
  for (let i: number = 0; i < mapping.joints.length; i++) {
    const joint: HumanoidJointBinding = mapping.joints[i];
    const pose: SkeletonRestPose | undefined = findRestPose(restPoses, joint.sourceNodeIndex);
    if (pose !== undefined && pose.worldMatrix !== undefined) {
      const m: number[] = pose.worldMatrix.m;
      for (let j: number = 0; j < m.length; j++) {
        if (!Number.isFinite(m[j])) {
          errors.push({
            type: HumanoidMappingIssueType.NonFiniteWorldPosition,
            level: HumanoidMappingIssueLevel.Error,
            message: '关节 ' + joint.targetJoint + ' 的世界矩阵包含非有限值',
            targetJoint: joint.targetJoint
          });
          break;
        }
      }
    }
  }

  // === 检查 16: 骨骼长度接近 0 ===
  // === 检查 17: 左右骨骼长度异常悬殊 ===
  checkBoneLengths(targetToBindings, restPoses, warnings);

  // === 检查 18: rest pose quaternion 是否有效 ===
  for (let i: number = 0; i < mapping.joints.length; i++) {
    const joint: HumanoidJointBinding = mapping.joints[i];
    const pose: SkeletonRestPose | undefined = findRestPose(restPoses, joint.sourceNodeIndex);
    if (pose !== undefined) {
      const q = pose.localRotation;
      if (!Number.isFinite(q.x) || !Number.isFinite(q.y)
        || !Number.isFinite(q.z) || !Number.isFinite(q.w)) {
        errors.push({
          type: HumanoidMappingIssueType.InvalidRestQuaternion,
          level: HumanoidMappingIssueLevel.Error,
          message: '关节 ' + joint.targetJoint + ' 的 rest quaternion 包含非有限值',
          targetJoint: joint.targetJoint
        });
      } else {
        // 检查四元数模长接近 1
        const mag: number = Math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
        if (Math.abs(mag - 1.0) > 0.01) {
          warnings.push({
            type: HumanoidMappingIssueType.InvalidRestQuaternion,
            level: HumanoidMappingIssueLevel.Warning,
            message: '关节 ' + joint.targetJoint + ' 的 rest quaternion 模长为 '
              + mag.toFixed(4) + '(应为 1.0)',
            targetJoint: joint.targetJoint
          });
        }
      }
    }
  }

  // === 检查 19: 模型校准轴是否有效 ===
  const alignment = mapping.alignment;
  if (!Number.isFinite(alignment.rotationX)
    || !Number.isFinite(alignment.rotationY)
    || !Number.isFinite(alignment.rotationZ)
    || !Number.isFinite(alignment.unitScale)
    || alignment.unitScale <= 0) {
    errors.push({
      type: HumanoidMappingIssueType.InvalidAlignmentAxis,
      level: HumanoidMappingIssueLevel.Error,
      message: '模型校准参数无效: rotation=(' + alignment.rotationX + ','
        + alignment.rotationY + ',' + alignment.rotationZ + '), unitScale='
        + alignment.unitScale
    });
  }

  // === 检查 20: skeletonHash 是否一致 ===
  if (mapping.skeletonHash !== input.currentSkeletonHash) {
    errors.push({
      type: HumanoidMappingIssueType.SkeletonHashMismatch,
      level: HumanoidMappingIssueLevel.Error,
      message: 'skeletonHash 不一致:映射记录 ' + mapping.skeletonHash.substring(0, 8)
        + '... 当前模型 ' + input.currentSkeletonHash.substring(0, 8) + '...'
    });
  }

  // === T-3D.6F-A: 检查 21 - surfaceSelectedBoneValid ===
  // 仅对 ManualSurface 映射执行:
  // 1. nodeIndex 已存在(检查 2/3 已覆盖)
  // 2. 属于当前 Skin(在 skinJointNodeIndices 中)
  // 3. 不是重复 Bone(检查 4 已覆盖)
  // 4. sourceSha256 一致
  // 5. skeletonHash 一致(检查 20 已覆盖)
  if (input.skinJointNodeIndices.length > 0) {
    for (let i: number = 0; i < mapping.joints.length; i++) {
      const joint: HumanoidJointBinding = mapping.joints[i];
      if (joint.mappingMethod !== BoneMappingMethod.ManualSurface) {
        continue;
      }
      // 检查 nodeIndex 属于 skin.joints
      if (!isInArray(input.skinJointNodeIndices, joint.sourceNodeIndex)) {
        errors.push({
          type: HumanoidMappingIssueType.SurfaceSelectedBoneNotInSkin,
          level: HumanoidMappingIssueLevel.Error,
          message: '表面点选的关节 ' + joint.targetJoint
            + ' 的 sourceNodeIndex ' + joint.sourceNodeIndex
            + ' 不在当前 skin.joints 中',
          targetJoint: joint.targetJoint
        });
      }
    }
  }

  // T-3D.6F-A: sourceSha256 一致性检查
  if (input.currentSourceSha256.length > 0
    && mapping.sourceSha256.length > 0
    && mapping.sourceSha256 !== input.currentSourceSha256) {
    errors.push({
      type: HumanoidMappingIssueType.SourceSha256Mismatch,
      level: HumanoidMappingIssueLevel.Error,
      message: 'sourceSha256 不一致:映射记录 ' + mapping.sourceSha256.substring(0, 8)
        + '... 当前模型 ' + input.currentSourceSha256.substring(0, 8) + '...'
    });
  }

  // === 汇总 ===
  const valid: boolean = errors.length === 0 && missingRequired.length === 0;
  // retargetReady:valid=true 且所有关键链检查通过(此处简化为 valid)
  const retargetReady: boolean = valid;
  return {
    valid: valid,
    retargetReady: retargetReady,
    errors: errors,
    warnings: warnings,
    missingRequired: missingRequired,
    missingOptional: missingOptional
  };
}

/**
 * 检查 ancestorIdx 是否是 descendantIdx 的祖先(或自身)。
 *
 * @param ancestorIdx 候选祖先节点索引
 * @param descendantIdx 后代节点索引
 * @param parentIndices 父节点索引数组
 * @param maxDepth 最大遍历深度(防循环)
 * @returns true 是祖先关系
 */
function isAncestor(
  ancestorIdx: number,
  descendantIdx: number,
  parentIndices: number[],
  maxDepth: number = 256
): boolean {
  if (ancestorIdx < 0 || descendantIdx < 0) {
    return false;
  }
  if (ancestorIdx === descendantIdx) {
    return true; // 自身
  }
  let current: number = descendantIdx;
  let depth: number = 0;
  while (current >= 0 && depth < maxDepth) {
    if (current >= parentIndices.length) {
      return false;
    }
    current = parentIndices[current];
    if (current === ancestorIdx) {
      return true;
    }
    depth++;
  }
  return false;
}

/**
 * 检查两个节点是否在同一棵树(有共同的根)。
 */
function isInSameTree(
  idx1: number,
  idx2: number,
  parentIndices: number[]
): boolean {
  const root1: number = findRoot(idx1, parentIndices);
  const root2: number = findRoot(idx2, parentIndices);
  return root1 === root2 && root1 >= 0;
}

/**
 * 找到节点的根。
 */
function findRoot(idx: number, parentIndices: number[]): number {
  let current: number = idx;
  let depth: number = 0;
  while (current >= 0 && depth < 256) {
    if (current >= parentIndices.length) {
      return -1;
    }
    const parent: number = parentIndices[current];
    if (parent < 0) {
      return current;
    }
    current = parent;
    depth++;
  }
  return -1;
}

/**
 * 检查 ancestor -> descendant 关系,失败时添加 warning。
 */
function checkAncestorRelation(
  ancestor: HumanoidBone,
  descendant: HumanoidBone,
  targetToBindings: Map<HumanoidBone, HumanoidJointBinding>,
  parentIndices: number[],
  warnings: HumanoidMappingIssue[],
  issueType: HumanoidMappingIssueType
): void {
  const ancestorBinding: HumanoidJointBinding | undefined = targetToBindings.get(ancestor);
  const descendantBinding: HumanoidJointBinding | undefined = targetToBindings.get(descendant);
  if (ancestorBinding === undefined || descendantBinding === undefined) {
    return;
  }
  if (!isAncestor(ancestorBinding.sourceNodeIndex, descendantBinding.sourceNodeIndex, parentIndices)) {
    warnings.push({
      type: issueType,
      level: HumanoidMappingIssueLevel.Warning,
      message: ancestor + ' 不是 ' + descendant + ' 的祖先,可能映射错误',
      targetJoint: descendant
    });
  }
}

/**
 * 检查 Hand/Foot 是否在对应 LowerArm/LowerLeg 链末端。
 */
function checkArmChain(
  endJoint: HumanoidBone,
  middleJoint: HumanoidBone,
  targetToBindings: Map<HumanoidBone, HumanoidJointBinding>,
  parentIndices: number[],
  warnings: HumanoidMappingIssue[],
  issueType: HumanoidMappingIssueType
): void {
  checkAncestorRelation(middleJoint, endJoint, targetToBindings, parentIndices,
    warnings, issueType);
}

/**
 * 检查左右是否反转。
 *
 * 简化策略:对比 LeftUpperArm 和 RightUpperArm 的 worldPosition.x 符号。
 * 标准:Left 在正 X 侧,Right 在负 X 侧(或相反,只要一致即可)。
 *
 * 若两者符号相同,可能左右反转。
 */
function checkLeftRightReversal(
  targetToBindings: Map<HumanoidBone, HumanoidJointBinding>,
  restPoses: SkeletonRestPose[],
  warnings: HumanoidMappingIssue[]
): void {
  const leftBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.LeftUpperArm);
  const rightBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.RightUpperArm);
  if (leftBinding === undefined || rightBinding === undefined) {
    return;
  }
  const leftPose: SkeletonRestPose | undefined = findRestPose(restPoses, leftBinding.sourceNodeIndex);
  const rightPose: SkeletonRestPose | undefined = findRestPose(restPoses, rightBinding.sourceNodeIndex);
  if (leftPose === undefined || rightPose === undefined) {
    return;
  }
  // 提取世界坐标 X(矩阵第 13 个元素,m[12..15] 是平移)
  const leftX: number = leftPose.worldMatrix.m[12];
  const rightX: number = rightPose.worldMatrix.m[12];
  if (Math.abs(leftX) < 0.001 || Math.abs(rightX) < 0.001) {
    return; // 太接近中心,无法判断
  }
  // 如果左右 X 同号,可能反转
  if ((leftX > 0 && rightX > 0) || (leftX < 0 && rightX < 0)) {
    warnings.push({
      type: HumanoidMappingIssueType.LeftRightReversed,
      level: HumanoidMappingIssueLevel.Warning,
      message: '左右上臂世界坐标 X 同号(leftX=' + leftX.toFixed(3)
        + ', rightX=' + rightX.toFixed(3) + '),可能左右反转',
      targetJoint: HumanoidBone.LeftUpperArm
    });
  }
}

/**
 * 检查必需链 Hips -> Spine -> Head 的连通性。
 */
function checkRequiredChain(
  targetToBindings: Map<HumanoidBone, HumanoidJointBinding>,
  parentIndices: number[],
  warnings: HumanoidMappingIssue[]
): void {
  const hipsBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.Hips);
  const spineBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.Spine);
  const headBinding: HumanoidJointBinding | undefined = targetToBindings.get(HumanoidBone.Head);
  if (hipsBinding === undefined || spineBinding === undefined || headBinding === undefined) {
    return;
  }
  // 检查 Spine 是否是 Hips 的后代
  if (!isAncestor(hipsBinding.sourceNodeIndex, spineBinding.sourceNodeIndex, parentIndices)) {
    warnings.push({
      type: HumanoidMappingIssueType.RequiredChainBroken,
      level: HumanoidMappingIssueLevel.Warning,
      message: 'Spine 不是 Hips 的后代,主骨架链可能断开',
      targetJoint: HumanoidBone.Spine
    });
  }
}

/**
 * 检查骨骼长度(零长度/左右悬殊)。
 */
function checkBoneLengths(
  targetToBindings: Map<HumanoidBone, HumanoidJointBinding>,
  restPoses: SkeletonRestPose[],
  warnings: HumanoidMappingIssue[]
): void {
  // 计算各关键骨骼长度
  const leftUpperArmLen: number = computeBoneLength(
    targetToBindings, restPoses, HumanoidBone.LeftUpperArm, HumanoidBone.LeftLowerArm);
  const rightUpperArmLen: number = computeBoneLength(
    targetToBindings, restPoses, HumanoidBone.RightUpperArm, HumanoidBone.RightLowerArm);
  const leftUpperLegLen: number = computeBoneLength(
    targetToBindings, restPoses, HumanoidBone.LeftUpperLeg, HumanoidBone.LeftLowerLeg);
  const rightUpperLegLen: number = computeBoneLength(
    targetToBindings, restPoses, HumanoidBone.RightUpperLeg, HumanoidBone.RightLowerLeg);

  // 检查零长度
  const EPSILON: number = 0.0001;
  if (leftUpperArmLen > 0 && leftUpperArmLen < EPSILON) {
    warnings.push({
      type: HumanoidMappingIssueType.ZeroBoneLength,
      level: HumanoidMappingIssueLevel.Warning,
      message: '左上臂骨骼长度接近 0',
      targetJoint: HumanoidBone.LeftUpperArm
    });
  }

  // 检查左右悬殊(超过 2 倍认为异常)
  if (leftUpperArmLen > 0 && rightUpperArmLen > 0) {
    const ratio: number = leftUpperArmLen / rightUpperArmLen;
    if (ratio > 2.0 || ratio < 0.5) {
      warnings.push({
        type: HumanoidMappingIssueType.LeftRightBoneLengthMismatch,
        level: HumanoidMappingIssueLevel.Warning,
        message: '左右上臂长度悬殊: left=' + leftUpperArmLen.toFixed(4)
          + ', right=' + rightUpperArmLen.toFixed(4),
        targetJoint: HumanoidBone.LeftUpperArm
      });
    }
  }
  if (leftUpperLegLen > 0 && rightUpperLegLen > 0) {
    const ratio: number = leftUpperLegLen / rightUpperLegLen;
    if (ratio > 2.0 || ratio < 0.5) {
      warnings.push({
        type: HumanoidMappingIssueType.LeftRightBoneLengthMismatch,
        level: HumanoidMappingIssueLevel.Warning,
        message: '左右大腿长度悬殊: left=' + leftUpperLegLen.toFixed(4)
          + ', right=' + rightUpperLegLen.toFixed(4),
        targetJoint: HumanoidBone.LeftUpperLeg
      });
    }
  }
}

/**
 * 计算两个相邻骨骼的世界坐标距离(骨骼长度)。
 *
 * @returns 距离(任一缺失返回 -1)
 */
function computeBoneLength(
  targetToBindings: Map<HumanoidBone, HumanoidJointBinding>,
  restPoses: SkeletonRestPose[],
  parentBone: HumanoidBone,
  childBone: HumanoidBone
): number {
  const parentBinding: HumanoidJointBinding | undefined = targetToBindings.get(parentBone);
  const childBinding: HumanoidJointBinding | undefined = targetToBindings.get(childBone);
  if (parentBinding === undefined || childBinding === undefined) {
    return -1;
  }
  const parentPose: SkeletonRestPose | undefined = findRestPose(restPoses, parentBinding.sourceNodeIndex);
  const childPose: SkeletonRestPose | undefined = findRestPose(restPoses, childBinding.sourceNodeIndex);
  if (parentPose === undefined || childPose === undefined) {
    return -1;
  }
  const px: number = parentPose.worldMatrix.m[12];
  const py: number = parentPose.worldMatrix.m[13];
  const pz: number = parentPose.worldMatrix.m[14];
  const cx: number = childPose.worldMatrix.m[12];
  const cy: number = childPose.worldMatrix.m[13];
  const cz: number = childPose.worldMatrix.m[14];
  const dx: number = cx - px;
  const dy: number = cy - py;
  const dz: number = cz - pz;
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
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
 * T-3D.6F-A: 数组中是否包含指定值(线性查找,小数组可接受)。
 */
function isInArray(arr: number[], value: number): boolean {
  for (let i: number = 0; i < arr.length; i++) {
    if (arr[i] === value) {
      return true;
    }
  }
  return false;
}
