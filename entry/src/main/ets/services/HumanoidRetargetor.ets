/**
 * HumanoidRetargetor 人形动作重定向算法
 *
 * T-4.2E: 将源骨架动画重定向到目标 VRM 骨架。
 *
 * 核心算法(本轮仅处理旋转 + Hips 位移):
 *   sourceDelta = inverse(sourceRestLocalRotation) × sourceAnimatedLocalRotation
 *   targetAnimatedLocalRotation = targetRestLocalRotation × sourceDelta
 *
 * 不变量:
 *   当 sourceAnimatedRotation == sourceRestRotation 时,
 *   targetAnimatedRotation == targetRestRotation
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
 * - 轴校正(如需要后续增加 boneAxisCorrection)
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
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import {
  quaternionMultiply,
  quaternionInverse,
  quaternionEqual,
  quaternionNormalize
} from '../utils/QuaternionUtil';

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
}

/**
 * 执行重定向。
 *
 * @param sourcePose 源骨架采样姿态(来自 HumanoidMotionSampler)
 * @param sourceRestPose 源骨架 Rest Pose(来自 GLB nodes 默认 TRS)
 * @param targetRestPose 目标骨架 Rest Pose(来自目标 SceneNode 加载时保存)
 * @param rootMotionMode Hips 位移模式
 * @returns 重定向结果
 */
export function retargetPose(
  sourcePose: HumanoidPose,
  sourceRestPose: HumanoidRestPose,
  targetRestPose: HumanoidRestPose,
  rootMotionMode: RootMotionMode
): RetargetResult {
  const rotations: Map<HumanoidBone, QuaternionValue> = new Map();
  const translations: Map<HumanoidBone, Vector3Value> = new Map();
  const changedBones: HumanoidBone[] = [];
  const skippedBones: string[] = [];
  let appliedCount: number = 0;

  // 遍历源姿态中的每根骨骼
  sourcePose.bones.forEach((bonePose, bone) => {
    // 获取目标 Rest Pose
    const targetRest: BoneRestTransform | undefined = targetRestPose.bones.get(bone);
    if (targetRest === undefined) {
      skippedBones.push(bone + ': targetRest missing');
      return;
    }

    // 获取源 Rest Pose
    const sourceRest: BoneRestTransform | undefined = sourceRestPose.bones.get(bone);
    if (sourceRest === undefined) {
      skippedBones.push(bone + ': sourceRest missing');
      return;
    }

    // ===== 旋转重定向 =====
    if (bonePose.rotation !== null) {
      const sourceAnimatedRot: QuaternionValue = bonePose.rotation;
      const sourceRestRot: QuaternionValue = sourceRest.localRotation;
      const targetRestRot: QuaternionValue = targetRest.localRotation;

      // sourceDelta = inverse(sourceRestRot) × sourceAnimatedRot
      const sourceRestInverse: QuaternionValue = quaternionInverse(sourceRestRot);
      const sourceDelta: QuaternionValue = quaternionMultiply(sourceRestInverse, sourceAnimatedRot);

      // targetAnimatedRot = targetRestRot × sourceDelta
      const targetAnimatedRot: QuaternionValue = quaternionMultiply(targetRestRot, sourceDelta);
      const normalized: QuaternionValue = quaternionNormalize(targetAnimatedRot);

      rotations.set(bone, normalized);
      appliedCount++;

      // 检测是否发生变化(相较 Rest Pose)
      if (!quaternionEqual(normalized, targetRestRot, 1e-5)) {
        changedBones.push(bone);
      }
    } else {
      // 无旋转动画,使用 Rest Pose
      rotations.set(bone, targetRest.localRotation);
    }

    // ===== Hips 位移重定向 =====
    if (bone === HumanoidBone.Hips && bonePose.translation !== null) {
      if (rootMotionMode === RootMotionMode.Locked) {
        // 锁定:使用 target Rest 位移
        translations.set(bone, targetRest.localPosition);
      } else {
        // HipsOnly / Full:应用位移增量(按身高缩放)
        const sourceDeltaPos: Vector3Value = {
          x: bonePose.translation.x - sourceRest.localPosition.x,
          y: bonePose.translation.y - sourceRest.localPosition.y,
          z: bonePose.translation.z - sourceRest.localPosition.z
        };

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
        translations.set(bone, targetHipsPos);
      }
    }
  });

  return {
    rotations: rotations,
    translations: translations,
    appliedBoneCount: appliedCount,
    changedBoneCount: changedBones.length,
    changedBones: changedBones,
    skippedBones: skippedBones
  };
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
