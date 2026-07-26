/**
 * HumanoidRetargetor 人形动作重定向算法
 *
 * T-4.2E: 将源骨架动画重定向到目标 VRM 骨架。
 * T-4.2F: 引入父空间 delta 转换(A Pose / T Pose 差异校正)。
 * T-4.2G: 引入方向校准(Alignment Transform + 左右镜像)。
 * T-4.2G-fix: 修复层级动画世界旋转传递(父骨骼动画影响子骨骼)。
 *
 * 核心算法(T-4.2G-fix 正确层级传递):
 *   按 ALL_STANDARD_BONES 层级顺序遍历(父骨骼先于子骨骼处理),
 *   维护 source/target 动画世界旋转 map,确保子骨骼的世界旋转
 *   正确反映父骨骼的动画。
 *
 *   sourceRestWorldRot[bone]  = sourceParentWorldRest × sourceRestLocalRot
 *   sourceAnimWorldRot[bone]  = sourceParentWorldAnim × sourceAnimLocalRot
 *   worldDelta = inverse(sourceRestWorldRot) × sourceAnimWorldRot
 *
 *   alignedWorldDelta = alignmentRotation × worldDelta × inverse(alignmentRotation)
 *
 *   targetRestWorldRot[bone]  = targetParentWorldRest × targetRestLocalRot
 *   targetAnimWorldRot[bone]  = targetRestWorldRot × alignedWorldDelta
 *   targetAnimLocalRot[bone]  = inverse(targetParentWorldAnim) × targetAnimWorldRot
 *
 * 不变量:
 *   当 sourceAnimatedRotation == sourceRestRotation 时,
 *   worldDelta = identity,
 *   targetAnimWorldRot == targetRestWorldRot,
 *   targetAnimLocalRot == targetRestLocalRot
 *
 * Hips 位移:
 *   sourceDeltaPosition = sourceAnimatedHipsPosition - sourceRestHipsPosition
 *   heightRatio = targetModelHeight / sourceModelHeight
 *   targetHipsPosition = targetRestHipsPosition + sourceDeltaPosition × heightRatio
 *
 * 本轮不处理:
 * - Scale
 * - 手指/眼睛/下巴/脚趾
 * - IK
 *
 * 不依赖 ArkGraphics3D / ArkUI,纯逻辑可单元测试。
 */

import {
  HumanoidPose,
  HumanoidRestPose,
  BoneRestTransform,
  QuaternionValue,
  Vector3Value,
  RootMotionMode,
  identityQuaternionValue,
  zeroVector3Value
} from '../models/character3d/HumanoidMotionClip';
import { HumanoidBone, ALL_STANDARD_BONES } from '../models/character3d/HumanoidBone';
import {
  quaternionMultiply,
  quaternionInverse,
  quaternionEqual,
  quaternionNormalize
} from '../utils/QuaternionUtil';
import {
  AvatarOrientationCalibration,
  EffectiveCalibrationParams,
  resolveEffectiveCalibration,
  yawToQuaternion,
  getLeftRightBoneSwapMap,
  isLeftRightBone
} from '../models/character3d/AvatarOrientationCalibration';

/**
 * 重定向结果:每根骨骼的目标局部变换。
 */
export interface RetargetResult {
  /** bone → 目标局部旋转(应用动画后) */
  rotations: Map<HumanoidBone, QuaternionValue>;
  /** bone → 目标局部位移(应用动画后,仅 Hips) */
  translations: Map<HumanoidBone, Vector3Value>;
  /** 实际应用的骨骼数 */
  appliedBoneCount: number;
  /** 旋转相较 Rest Pose 发生变化的骨骼数 */
  changedBoneCount: number;
  /** 发生变化的骨骼名(用于日志) */
  changedBones: HumanoidBone[];
  /** 跳过的骨骼及原因 */
  skippedBones: string[];
  /** T-4.2F: 轴校正诊断信息(每个骨骼的 sourceDelta/worldDelta 摘要) */
  axisCorrectionStats: AxisCorrectionStat[];
}

/**
 * T-4.2F: 轴校正诊断信息(用于分段日志)。
 */
export interface AxisCorrectionStat {
  bone: HumanoidBone;
  /** sourceDelta 的旋转角度(度) */
  sourceDeltaAngleDeg: number;
  /** worldDelta 的旋转角度(度,应与 sourceDeltaAngleDeg 相同) */
  worldDeltaAngleDeg: number;
  /** targetAppliedRotation 的旋转角度(度) */
  targetAppliedAngleDeg: number;
  /** targetRestRotation 的旋转角度(度) */
  targetRestAngleDeg: number;
  /** 是否相较 rest pose 发生变化 */
  changed: boolean;
}

/**
 * 执行重定向。
 *
 * T-4.2G-fix: 修复层级动画世界旋转传递。
 *   - 按 ALL_STANDARD_BONES 层级顺序遍历(父骨骼先于子骨骼)
 *   - 维护 sourceAnimWorldRotMap:source 每根骨骼的动画后世界旋转
 *   - 维护 targetAnimWorldRotMap:target 每根骨骼的动画后世界旋转
 *   - worldDelta = inverse(sourceRestWorldRot) × sourceAnimWorldRot
 *   - targetAnimLocalRot = inverse(targetParentWorldAnim) × targetAnimWorldRot
 *
 * T-4.2G Alignment Transform 接入位置:
 *   step 1: sourceAnimWorldRot = sourceParentWorldAnim × sourceAnimLocalRot
 *   step 2: worldDelta = inverse(sourceRestWorldRot) × sourceAnimWorldRot
 *   step 3: alignedWorldDelta = alignmentRotation × worldDelta × inverse(alignmentRotation)  ← T-4.2G
 *   step 4: targetAnimWorldRot = targetRestWorldRot × alignedWorldDelta
 *   step 5: targetAnimLocalRot = inverse(targetParentWorldAnim) × targetAnimWorldRot
 *
 * 左右镜像处理:
 *   - source 侧按原始 bone 计算(保持 source 层级)
 *   - target 侧用 effectiveBone(对侧)存储和计算
 *   - 镜像只应用一次(在 target 侧交换骨骼,source 侧不交换)
 *   - ALL_STANDARD_BONES 顺序保证:Left 侧先处理(映射到 target Right),
 *     然后 Right 侧处理(映射到 target Left),target 父骨骼已就绪
 *
 * @param sourcePose 源骨架采样姿态(来自 HumanoidMotionSampler)
 * @param sourceRestPose 源骨架 Rest Pose(来自 GLB nodes 默认 TRS)
 * @param targetRestPose 目标骨架 Rest Pose(来自目标 SceneNode 加载时保存)
 * @param sourceWorldRestMap 源骨架每根骨骼的 rest 世界旋转(预计算)
 * @param rootMotionMode Hips 位移模式
 * @param calibration T-4.2G 方向校准(可选,为 null 时无校正)
 * @returns 重定向结果
 */
export function retargetPose(
  sourcePose: HumanoidPose,
  sourceRestPose: HumanoidRestPose,
  targetRestPose: HumanoidRestPose,
  sourceWorldRestMap: Map<HumanoidBone, QuaternionValue>,
  rootMotionMode: RootMotionMode,
  calibration: AvatarOrientationCalibration | null = null
): RetargetResult {
  const rotations: Map<HumanoidBone, QuaternionValue> = new Map();
  const translations: Map<HumanoidBone, Vector3Value> = new Map();
  const changedBones: HumanoidBone[] = [];
  const skippedBones: string[] = [];
  const axisCorrectionStats: AxisCorrectionStat[] = [];
  let appliedCount: number = 0;

  // T-4.2G: 解析校准参数
  const defaultParams: EffectiveCalibrationParams = {
    yawOffsetDeg: 0,
    swapLeftRight: false,
    invertForward: false
  };
  const calibrationEffective: EffectiveCalibrationParams = calibration !== null
    ? resolveEffectiveCalibration(calibration)
    : defaultParams;

  // T-4.2G: 构建 Alignment Rotation(Yaw 旋转 + Forward 反转)
  const alignmentRotation: QuaternionValue = yawToQuaternion(calibrationEffective.yawOffsetDeg);
  const alignmentRotationInverse: QuaternionValue = quaternionInverse(alignmentRotation);

  // T-4.2G: 左右骨骼交换映射(仅在 swapLeftRight=true 时使用)
  const swapMap: Map<HumanoidBone, HumanoidBone> | null = calibrationEffective.swapLeftRight
    ? getLeftRightBoneSwapMap()
    : null;

  // T-4.2G-fix: 计算 target 的 rest 世界旋转 map
  const targetWorldRestMap: Map<HumanoidBone, QuaternionValue> = computeWorldRestRotations(targetRestPose);

  // T-4.2G-fix: 维护 source/target 动画世界旋转 map(按层级顺序填充)
  const sourceAnimWorldRotMap: Map<HumanoidBone, QuaternionValue> = new Map();
  const targetAnimWorldRotMap: Map<HumanoidBone, QuaternionValue> = new Map();

  // T-4.2G-fix: 按 ALL_STANDARD_BONES 层级顺序遍历(父骨骼先于子骨骼)
  for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
    const bone: HumanoidBone = ALL_STANDARD_BONES[i];

    // 获取源姿态(可能没有动画,跳过输出但仍需计算 world rotation)
    const bonePose = sourcePose.bones.get(bone);
    // 获取源 Rest Pose
    const sourceRest: BoneRestTransform | undefined = sourceRestPose.bones.get(bone);
    if (sourceRest === undefined) {
      // source 中没有该骨骼的 rest,无法计算世界旋转,跳过
      continue;
    }

    // T-4.2G: 若启用左右镜像,source 侧按原始 bone 计算,target 侧用 effectiveBone
    const effectiveBone: HumanoidBone = (swapMap !== null && isLeftRightBone(bone))
      ? (swapMap.get(bone) ?? bone)
      : bone;

    // 获取目标 Rest Pose(使用 effectiveBone)
    const targetRest: BoneRestTransform | undefined = targetRestPose.bones.get(effectiveBone);
    if (targetRest === undefined) {
      if (bonePose !== undefined) {
        skippedBones.push(effectiveBone + ': targetRest missing');
      }
      continue;
    }

    // ===== 计算 source 动画世界旋转 =====
    const sourceRestLocalRot: QuaternionValue = sourceRest.localRotation;
    const sourceAnimLocalRot: QuaternionValue = (bonePose !== undefined && bonePose.rotation !== null)
      ? bonePose.rotation
      : sourceRestLocalRot;

    // source 父骨骼
    const sourceParentBone: HumanoidBone | null = findParentBone(bone);
    const sourceParentWorldRest: QuaternionValue = sourceParentBone !== null
      ? (sourceWorldRestMap.get(sourceParentBone) ?? identityQuaternionValue())
      : identityQuaternionValue();
    // T-4.2G-fix: source 父骨骼的动画世界旋转(用动画值而非 rest 值)
    const sourceParentWorldAnim: QuaternionValue = sourceParentBone !== null
      ? (sourceAnimWorldRotMap.get(sourceParentBone) ?? sourceParentWorldRest)
      : identityQuaternionValue();

    // sourceRestWorldRot = sourceParentWorldRest × sourceRestLocalRot
    const sourceRestWorldRot: QuaternionValue = sourceWorldRestMap.get(bone) ?? sourceRestLocalRot;
    // sourceAnimWorldRot = sourceParentWorldAnim × sourceAnimLocalRot
    const sourceAnimWorldRot: QuaternionValue = quaternionNormalize(
      quaternionMultiply(sourceParentWorldAnim, sourceAnimLocalRot)
    );
    sourceAnimWorldRotMap.set(bone, sourceAnimWorldRot);

    // ===== 计算 worldDelta =====
    // worldDelta = inverse(sourceRestWorldRot) × sourceAnimWorldRot
    const sourceRestWorldRotInverse: QuaternionValue = quaternionInverse(sourceRestWorldRot);
    const worldDelta: QuaternionValue = quaternionMultiply(sourceRestWorldRotInverse, sourceAnimWorldRot);

    // ===== T-4.2G: 应用 Alignment Transform =====
    // alignedWorldDelta = alignmentRotation × worldDelta × inverse(alignmentRotation)
    const alignedWorldDelta: QuaternionValue = quaternionNormalize(
      quaternionMultiply(
        quaternionMultiply(alignmentRotation, worldDelta),
        alignmentRotationInverse
      )
    );

    // ===== 计算 target 动画世界旋转 =====
    const targetRestLocalRot: QuaternionValue = targetRest.localRotation;
    // target 父骨骼(使用 effectiveBone 的父骨骼)
    const targetParentBone: HumanoidBone | null = findParentBone(effectiveBone);
    const targetParentWorldRest: QuaternionValue = targetParentBone !== null
      ? (targetWorldRestMap.get(targetParentBone) ?? identityQuaternionValue())
      : identityQuaternionValue();
    // T-4.2G-fix: target 父骨骼的动画世界旋转(用动画值而非 rest 值)
    const targetParentWorldAnim: QuaternionValue = targetParentBone !== null
      ? (targetAnimWorldRotMap.get(targetParentBone) ?? targetParentWorldRest)
      : identityQuaternionValue();

    // targetRestWorldRot = targetParentWorldRest × targetRestLocalRot
    const targetRestWorldRot: QuaternionValue = targetWorldRestMap.get(effectiveBone) ?? targetRestLocalRot;
    // targetAnimWorldRot = targetRestWorldRot × alignedWorldDelta
    const targetAnimWorldRot: QuaternionValue = quaternionNormalize(
      quaternionMultiply(targetRestWorldRot, alignedWorldDelta)
    );
    targetAnimWorldRotMap.set(effectiveBone, targetAnimWorldRot);

    // ===== 计算 target 动画局部旋转 =====
    // targetAnimLocalRot = inverse(targetParentWorldAnim) × targetAnimWorldRot
    const targetParentWorldAnimInverse: QuaternionValue = quaternionInverse(targetParentWorldAnim);
    const targetAnimLocalRot: QuaternionValue = quaternionNormalize(
      quaternionMultiply(targetParentWorldAnimInverse, targetAnimWorldRot)
    );

    // ===== 输出结果 =====
    if (bonePose !== undefined && bonePose.rotation !== null) {
      rotations.set(effectiveBone, targetAnimLocalRot);
      appliedCount++;

      // 计算诊断角度
      const sourceDeltaAngle: number = quaternionRotationAngleDeg(worldDelta);
      const worldDeltaAngle: number = quaternionRotationAngleDeg(alignedWorldDelta);
      const targetAppliedAngle: number = quaternionRotationAngleDeg(targetAnimLocalRot);
      const targetRestAngle: number = quaternionRotationAngleDeg(targetRestLocalRot);
      const changed: boolean = !quaternionEqual(targetAnimLocalRot, targetRestLocalRot, 1e-5);

      if (changed) {
        changedBones.push(effectiveBone);
      }

      axisCorrectionStats.push({
        bone: effectiveBone,
        sourceDeltaAngleDeg: sourceDeltaAngle,
        worldDeltaAngleDeg: worldDeltaAngle,
        targetAppliedAngleDeg: targetAppliedAngle,
        targetRestAngleDeg: targetRestAngle,
        changed: changed
      });
    } else {
      // 无旋转动画,使用 Rest Pose(仍需记录 world rotation 以供子骨骼使用)
      rotations.set(effectiveBone, targetRestLocalRot);
    }

    // ===== Hips 位移重定向(Hips 是中轴骨骼,镜像时 effectiveBone === bone) =====
    if (bone === HumanoidBone.Hips && bonePose !== undefined && bonePose.translation !== null) {
      if (rootMotionMode === RootMotionMode.Locked) {
        // 锁定:使用 target Rest 位移
        translations.set(effectiveBone, targetRest.localPosition);
      } else {
        // HipsOnly / Full:应用位移增量(按身高缩放)
        let sourceDeltaPos: Vector3Value = {
          x: bonePose.translation.x - sourceRest.localPosition.x,
          y: bonePose.translation.y - sourceRest.localPosition.y,
          z: bonePose.translation.z - sourceRest.localPosition.z
        };

        // T-4.2G: 左右镜像时,Hips 位移 X 分量取反(左右翻转)
        if (calibrationEffective.swapLeftRight) {
          sourceDeltaPos = {
            x: -sourceDeltaPos.x,
            y: sourceDeltaPos.y,
            z: sourceDeltaPos.z
          };
        }

        // T-4.2G: Forward 反转时,Hips 位移 Z 分量取反
        if (calibrationEffective.invertForward) {
          sourceDeltaPos = {
            x: sourceDeltaPos.x,
            y: sourceDeltaPos.y,
            z: -sourceDeltaPos.z
          };
        }

        const sourceHeight: number = sourceRestPose.modelHeight > 0 ? sourceRestPose.modelHeight : 1.4;
        const targetHeight: number = targetRestPose.modelHeight > 0 ? targetRestPose.modelHeight : 1.4;
        const heightRatio: number = targetHeight / sourceHeight;

        let scaledDelta: Vector3Value;
        if (rootMotionMode === RootMotionMode.HipsOnly) {
          // HipsOnly:锁定过大的 X/Z 位移(原地动作)
          scaledDelta = {
            x: Math.abs(sourceDeltaPos.x) > 0.1 ? 0 : sourceDeltaPos.x * heightRatio,
            y: sourceDeltaPos.y * heightRatio,
            z: Math.abs(sourceDeltaPos.z) > 0.1 ? 0 : sourceDeltaPos.z * heightRatio
          };
        } else {
          // Full:完整应用
          scaledDelta = {
            x: sourceDeltaPos.x * heightRatio,
            y: sourceDeltaPos.y * heightRatio,
            z: sourceDeltaPos.z * heightRatio
          };
        }

        const targetHipsPos: Vector3Value = {
          x: targetRest.localPosition.x + scaledDelta.x,
          y: targetRest.localPosition.y + scaledDelta.y,
          z: targetRest.localPosition.z + scaledDelta.z
        };
        translations.set(effectiveBone, targetHipsPos);
      }
    }
  }

  return {
    rotations: rotations,
    translations: translations,
    appliedBoneCount: appliedCount,
    changedBoneCount: changedBones.length,
    changedBones: changedBones,
    skippedBones: skippedBones,
    axisCorrectionStats: axisCorrectionStats
  };
}

/**
 * T-4.2F: 计算每根骨骼的 rest 世界旋转(用于父空间 delta 转换)。
 *
 * 遍历 HumanoidBone 标准层级,从根开始累乘 local rotation。
 * 缺失骨骼的 local rotation 视为 identity(不影响子骨骼的世界旋转)。
 *
 * @param restPose 骨骼 Rest Pose
 * @returns bone → rest 世界旋转
 */
export function computeWorldRestRotations(
  restPose: HumanoidRestPose
): Map<HumanoidBone, QuaternionValue> {
  const result: Map<HumanoidBone, QuaternionValue> = new Map();

  // 按 ALL_STANDARD_BONES 顺序遍历(父骨骼在子骨骼之前)
  for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
    const bone: HumanoidBone = ALL_STANDARD_BONES[i];
    const rest: BoneRestTransform | undefined = restPose.bones.get(bone);
    const localRot: QuaternionValue = rest !== undefined ? rest.localRotation : identityQuaternionValue();

    const parentBone: HumanoidBone | null = findParentBone(bone);
    if (parentBone === null) {
      // 根节点:world = local
      result.set(bone, quaternionNormalize(localRot));
    } else {
      // 子节点:world = parentWorld × local
      const parentWorld: QuaternionValue = result.get(parentBone) ?? identityQuaternionValue();
      const world: QuaternionValue = quaternionMultiply(parentWorld, localRot);
      result.set(bone, quaternionNormalize(world));
    }
  }

  return result;
}

/**
 * T-4.2F: 获取骨骼的标准父骨骼。
 *
 * 层级(标准 Humanoid):
 * - Hips (root)
 *   - Spine
 *     - Chest
 *       - UpperChest
 *         - Neck
 *           - Head
 *             - LeftEye / RightEye / Jaw
 *         - LeftShoulder
 *           - LeftUpperArm
 *             - LeftLowerArm
 *               - LeftHand
 *         - RightShoulder
 *           - RightUpperArm
 *             - RightLowerArm
 *               - RightHand
 *   - LeftUpperLeg
 *     - LeftLowerLeg
 *       - LeftFoot
 *         - LeftToes
 *   - RightUpperLeg
 *     - RightLowerLeg
 *       - RightFoot
 *         - RightToes
 *
 * @returns 父骨骼,或 null(根节点)
 */
export function findParentBone(bone: HumanoidBone): HumanoidBone | null {
  switch (bone) {
    case HumanoidBone.Hips:
      return null;
    case HumanoidBone.Spine:
      return HumanoidBone.Hips;
    case HumanoidBone.Chest:
      return HumanoidBone.Spine;
    case HumanoidBone.UpperChest:
      return HumanoidBone.Chest;
    case HumanoidBone.Neck:
      return HumanoidBone.UpperChest;
    case HumanoidBone.Head:
      return HumanoidBone.Neck;
    case HumanoidBone.LeftShoulder:
      return HumanoidBone.UpperChest;
    case HumanoidBone.LeftUpperArm:
      return HumanoidBone.LeftShoulder;
    case HumanoidBone.LeftLowerArm:
      return HumanoidBone.LeftUpperArm;
    case HumanoidBone.LeftHand:
      return HumanoidBone.LeftLowerArm;
    case HumanoidBone.RightShoulder:
      return HumanoidBone.UpperChest;
    case HumanoidBone.RightUpperArm:
      return HumanoidBone.RightShoulder;
    case HumanoidBone.RightLowerArm:
      return HumanoidBone.RightUpperArm;
    case HumanoidBone.RightHand:
      return HumanoidBone.RightLowerArm;
    case HumanoidBone.LeftUpperLeg:
      return HumanoidBone.Hips;
    case HumanoidBone.LeftLowerLeg:
      return HumanoidBone.LeftUpperLeg;
    case HumanoidBone.LeftFoot:
      return HumanoidBone.LeftLowerLeg;
    case HumanoidBone.LeftToes:
      return HumanoidBone.LeftFoot;
    case HumanoidBone.RightUpperLeg:
      return HumanoidBone.Hips;
    case HumanoidBone.RightLowerLeg:
      return HumanoidBone.RightUpperLeg;
    case HumanoidBone.RightFoot:
      return HumanoidBone.RightLowerLeg;
    case HumanoidBone.RightToes:
      return HumanoidBone.RightFoot;
    case HumanoidBone.LeftEye:
      return HumanoidBone.Head;
    case HumanoidBone.RightEye:
      return HumanoidBone.Head;
    case HumanoidBone.Jaw:
      return HumanoidBone.Head;
    default:
      return null;
  }
}

/**
 * T-4.2F: 计算四元数的旋转角度(度)。
 *
 * 对于单位四元数 q = [x, y, z, w],旋转角度 θ = 2 × acos(|w|)。
 * 用于分段日志,显示骨骼的旋转幅度。
 *
 * @param q 四元数
 * @returns 旋转角度(度,0~180)
 */
export function quaternionRotationAngleDeg(q: QuaternionValue): number {
  const wClamped: number = Math.max(-1.0, Math.min(1.0, Math.abs(q.w)));
  const angleRad: number = 2.0 * Math.acos(wClamped);
  return angleRad * 180.0 / Math.PI;
}

/**
 * 验证重定向不变量:
 * 当 sourceAnimatedRotation == sourceRestRotation 时,
 * targetAnimatedRotation == targetRestRotation。
 *
 * @returns true 表示不变量成立
 */
export function verifyRetargetInvariant(
  sourceRestRot: QuaternionValue,
  targetRestRot: QuaternionValue
): boolean {
  // 构造 sourceAnimatedRot == sourceRestRot 的场景
  const sourceRestInverse: QuaternionValue = quaternionInverse(sourceRestRot);
  const sourceDelta: QuaternionValue = quaternionMultiply(sourceRestInverse, sourceRestRot);
  const targetAnimatedRot: QuaternionValue = quaternionMultiply(targetRestRot, sourceDelta);
  const normalized: QuaternionValue = quaternionNormalize(targetAnimatedRot);

  // sourceDelta 应为 identity
  const identity: QuaternionValue = identityQuaternionValue();
  const deltaIsIdentity: boolean = quaternionEqual(sourceDelta, identity, 1e-6);
  // targetAnimatedRot 应 == targetRestRot
  const targetMatches: boolean = quaternionEqual(normalized, targetRestRot, 1e-6);

  return deltaIsIdentity && targetMatches;
}
