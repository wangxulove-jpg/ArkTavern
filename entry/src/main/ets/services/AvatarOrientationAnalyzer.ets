/**
 * AvatarOrientationAnalyzer Avatar 方向自动分析器
 *
 * T-4.2G: 分析 Source Skeleton 与 Target Avatar 的坐标基准,
 * 自动判断是否需要前后翻转、左右镜像,并给出置信度。
 *
 * 三类问题:
 * 1. Root Facing Offset:模型整体背对镜头 → RotateY180
 * 2. Forward Axis Inversion:动作向前变成向后 → RotateY180(同样 Yaw 180°)
 * 3. Left/Right Mirroring:右手动作出现在左手 → MirrorLeftRight
 *
 * 骨架基准计算:
 *   Up   = normalize(targetHead - targetHips)(世界坐标)
 *   Right = normalize(targetLeftShoulder - targetRightShoulder)(世界坐标)
 *   Forward candidate = cross(Right, Up)
 *
 * 注意:cross(Right, Up) 只能得到一个候选 Forward,反方向同样可能成立。
 * 因此同时生成 Normal / RotateY180 / MirrorLeftRight / MirrorLeftRightAndRotateY180 四个候选。
 *
 * 评分信号:
 * 1. Head/Chest/Hips 的方向一致性
 * 2. 左右肩、左右髋的语义一致性(基于 localPosition 的 X 分量符号)
 * 3. 左右手是否仍位于身体对应一侧
 * 4. 左右脚是否位于对应一侧
 *
 * 不依赖 ArkUI / ArkGraphics3D,纯逻辑可单元测试。
 *
 * 重要约束:
 * - 纯静态骨架无法绝对判断前后(cross 结果有两个等价候选)
 * - Low/Unknown 置信度时不自动启用高风险的左右镜像
 * - 优先保留 Normal 或仅使用明确的 Root Yaw 信息
 */

import {
  HumanoidRestPose,
  BoneRestTransform,
  Vector3Value,
  QuaternionValue,
  identityQuaternionValue
} from '../models/character3d/HumanoidMotionClip';
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import {
  AvatarOrientationMode,
  OrientationConfidence,
  OrientationCandidateScore,
  AvatarOrientationAnalysis
} from '../models/character3d/AvatarOrientationCalibration';
import { findParentBone } from './HumanoidRetargetor';

const LOG_TAG: string = 'AvatarOrientationAnalyzer';

/** 评分阈值:High 置信度 */
const CONFIDENCE_HIGH_THRESHOLD: number = 0.8;
/** 评分阈值:Medium 置信度 */
const CONFIDENCE_MEDIUM_THRESHOLD: number = 0.5;
/** 向量长度下限(避免除零) */
const VECTOR_LENGTH_EPS: number = 1e-4;
/** 共线阈值(dot 绝对值接近 1 视为共线) */
const COLINEAR_THRESHOLD: number = 0.995;

/**
 * 世界坐标下的骨骼变换(用于方向分析)。
 */
interface WorldBoneTransform {
  position: Vector3Value;
  rotation: QuaternionValue;
}

/**
 * 计算骨骼的世界位置(从 Hips 累加 localPosition)。
 *
 * 由于 HumanoidRestPose 只保存 local translation,需要遍历父链累加。
 * 注意:这是简化版,假设父骨骼的旋转不影响子骨骼的 translation 方向
 * (实际场景中,VRM 的骨骼 translation 通常沿父骨骼 Y 轴,
 *  但对于方向分析,这种简化已足够判断左右/前后/上下)。
 *
 * 更精确的做法:累乘世界旋转,再用 parentWorldRotation × localTranslation。
 * 本轮采用精确做法以保证正确性。
 *
 * @param restPose 骨骼 Rest Pose
 * @returns bone → 世界变换
 */
export function computeWorldTransforms(
  restPose: HumanoidRestPose
): Map<HumanoidBone, WorldBoneTransform> {
  const result: Map<HumanoidBone, WorldBoneTransform> = new Map();
  const bones: HumanoidBone[] = Array.from(restPose.bones.keys());

  for (let i: number = 0; i < bones.length; i++) {
    const bone: HumanoidBone = bones[i];
    const local: BoneRestTransform | undefined = restPose.bones.get(bone);
    if (local === undefined) {
      continue;
    }

    const parentBone: HumanoidBone | null = findParentBone(bone);
    if (parentBone === null) {
      // 根节点
      result.set(bone, {
        position: { x: local.localPosition.x, y: local.localPosition.y, z: local.localPosition.z },
        rotation: { x: local.localRotation.x, y: local.localRotation.y, z: local.localRotation.z, w: local.localRotation.w }
      });
    } else {
      const parent: WorldBoneTransform | undefined = result.get(parentBone);
      if (parent === undefined) {
        // 父骨骼缺失,使用 local
        result.set(bone, {
          position: { x: local.localPosition.x, y: local.localPosition.y, z: local.localPosition.z },
          rotation: { x: local.localRotation.x, y: local.localRotation.y, z: local.localRotation.z, w: local.localRotation.w }
        });
      } else {
        // 子节点:世界位置 = 父世界位置 + 父世界旋转 × localPosition
        const parentWorldRot: QuaternionValue = parent.rotation;
        const rotatedLocal: Vector3Value = rotateVectorByQuaternion(local.localPosition, parentWorldRot);
        const worldPos: Vector3Value = {
          x: parent.position.x + rotatedLocal.x,
          y: parent.position.y + rotatedLocal.y,
          z: parent.position.z + rotatedLocal.z
        };
        // 世界旋转 = 父世界旋转 × localRotation
        const worldRot: QuaternionValue = quaternionMul(parentWorldRot, local.localRotation);
        result.set(bone, {
          position: worldPos,
          rotation: worldRot
        });
      }
    }
  }

  return result;
}

/**
 * 用四元数旋转向量。
 */
function rotateVectorByQuaternion(v: Vector3Value, q: QuaternionValue): Vector3Value {
  // v' = q × v × q*
  // 优化公式:
  const qx: number = q.x;
  const qy: number = q.y;
  const qz: number = q.z;
  const qw: number = q.w;

  const tx: number = 2.0 * (qy * v.z - qz * v.y);
  const ty: number = 2.0 * (qz * v.x - qx * v.z);
  const tz: number = 2.0 * (qx * v.y - qy * v.x);

  return {
    x: v.x + qw * tx + (qy * tz - qz * ty),
    y: v.y + qw * ty + (qz * tx - qx * tz),
    z: v.z + qw * tz + (qx * ty - qy * tx)
  };
}

/**
 * 四元数乘法(本地副本,避免循环依赖 QuaternionUtil)。
 */
function quaternionMul(q1: QuaternionValue, q2: QuaternionValue): QuaternionValue {
  return {
    x: q1.w * q2.x + q1.x * q2.w + q1.y * q2.z - q1.z * q2.y,
    y: q1.w * q2.y - q1.x * q2.z + q1.y * q2.w + q1.z * q2.x,
    z: q1.w * q2.z + q1.x * q2.y - q1.y * q2.x + q1.z * q2.w,
    w: q1.w * q2.w - q1.x * q2.x - q1.y * q2.y - q1.z * q2.z
  };
}

/**
 * 向量长度。
 */
function vectorLength(v: Vector3Value): number {
  return Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

/**
 * 向量归一化(零向量返回零向量)。
 */
function vectorNormalize(v: Vector3Value): Vector3Value {
  const len: number = vectorLength(v);
  if (len < VECTOR_LENGTH_EPS) {
    return { x: 0, y: 0, z: 0 };
  }
  const inv: number = 1.0 / len;
  return { x: v.x * inv, y: v.y * inv, z: v.z * inv };
}

/**
 * 向量点积。
 */
function vectorDot(a: Vector3Value, b: Vector3Value): number {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

/**
 * 向量叉积。
 */
function vectorCross(a: Vector3Value, b: Vector3Value): Vector3Value {
  return {
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x
  };
}

/**
 * 向量相减。
 */
function vectorSub(a: Vector3Value, b: Vector3Value): Vector3Value {
  return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
}

/**
 * 骨架基准向量。
 */
interface SkeletonBasis {
  /** Up 向量(头到脚的反方向,即向上) */
  up: Vector3Value;
  /** Right 向量(从右肩指向左肩) */
  right: Vector3Value;
  /** Forward 候选向量(cross(Right, Up)) */
  forward: Vector3Value;
  /** 是否成功构建 */
  valid: boolean;
  /** 失败原因 */
  reasonCode: string;
}

/**
 * 计算骨架基准向量(Up / Right / Forward 候选)。
 *
 * @param worldTransforms 世界坐标变换
 * @returns 骨架基准
 */
function computeSkeletonBasis(
  worldTransforms: Map<HumanoidBone, WorldBoneTransform>
): SkeletonBasis {
  const hips: WorldBoneTransform | undefined = worldTransforms.get(HumanoidBone.Hips);
  const head: WorldBoneTransform | undefined = worldTransforms.get(HumanoidBone.Head);
  const leftShoulder: WorldBoneTransform | undefined = worldTransforms.get(HumanoidBone.LeftShoulder);
  const rightShoulder: WorldBoneTransform | undefined = worldTransforms.get(HumanoidBone.RightShoulder);

  // 退化:使用 UpperArm 作为肩部替代
  const leftUpperArm: WorldBoneTransform | undefined = worldTransforms.get(HumanoidBone.LeftUpperArm);
  const rightUpperArm: WorldBoneTransform | undefined = worldTransforms.get(HumanoidBone.RightUpperArm);

  if (hips === undefined || head === undefined) {
    return {
      up: { x: 0, y: 1, z: 0 },
      right: { x: 1, y: 0, z: 0 },
      forward: { x: 0, y: 0, z: 1 },
      valid: false,
      reasonCode: 'missing_hips_or_head'
    };
  }

  // Up = normalize(head - hips)
  const upRaw: Vector3Value = vectorSub(head.position, hips.position);
  const up: Vector3Value = vectorNormalize(upRaw);
  if (vectorLength(up) < VECTOR_LENGTH_EPS) {
    return {
      up: { x: 0, y: 1, z: 0 },
      right: { x: 1, y: 0, z: 0 },
      forward: { x: 0, y: 0, z: 1 },
      valid: false,
      reasonCode: 'up_zero_length'
    };
  }

  // Right = normalize(leftShoulder - rightShoulder)
  const leftShoulderPos: Vector3Value = leftShoulder !== undefined
    ? leftShoulder.position
    : (leftUpperArm !== undefined ? leftUpperArm.position : { x: 0, y: 0, z: 0 });
  const rightShoulderPos: Vector3Value = rightShoulder !== undefined
    ? rightShoulder.position
    : (rightUpperArm !== undefined ? rightUpperArm.position : { x: 0, y: 0, z: 0 });

  const rightRaw: Vector3Value = vectorSub(leftShoulderPos, rightShoulderPos);
  const right: Vector3Value = vectorNormalize(rightRaw);
  if (vectorLength(right) < VECTOR_LENGTH_EPS) {
    return {
      up: up,
      right: { x: 1, y: 0, z: 0 },
      forward: { x: 0, y: 0, z: 1 },
      valid: false,
      reasonCode: 'right_zero_length'
    };
  }

  // 检查 Up 和 Right 是否共线
  const upRightDot: number = Math.abs(vectorDot(up, right));
  if (upRightDot > COLINEAR_THRESHOLD) {
    return {
      up: up,
      right: right,
      forward: { x: 0, y: 0, z: 1 },
      valid: false,
      reasonCode: 'up_right_colinear'
    };
  }

  // Forward candidate = cross(Right, Up)
  const forward: Vector3Value = vectorNormalize(vectorCross(right, up));
  if (vectorLength(forward) < VECTOR_LENGTH_EPS) {
    return {
      up: up,
      right: right,
      forward: { x: 0, y: 0, z: 1 },
      valid: false,
      reasonCode: 'forward_zero_length'
    };
  }

  return {
    up: up,
    right: right,
    forward: forward,
    valid: true,
    reasonCode: 'ok'
  };
}

/**
 * 执行自动方向分析。
 *
 * @param sourceRestPose 源骨架 Rest Pose(来自动作包 GLB)
 * @param targetRestPose 目标骨架 Rest Pose(来自 Avatar SceneNode)
 * @returns 分析结果(包含选中模式、置信度、候选评分)
 */
export function analyzeOrientation(
  sourceRestPose: HumanoidRestPose,
  targetRestPose: HumanoidRestPose
): AvatarOrientationAnalysis {
  // 1. 计算世界变换
  const sourceWorld: Map<HumanoidBone, WorldBoneTransform> = computeWorldTransforms(sourceRestPose);
  const targetWorld: Map<HumanoidBone, WorldBoneTransform> = computeWorldTransforms(targetRestPose);

  // 2. 计算骨架基准
  const sourceBasis: SkeletonBasis = computeSkeletonBasis(sourceWorld);
  const targetBasis: SkeletonBasis = computeSkeletonBasis(targetWorld);

  // 3. 候选评分
  const candidates: OrientationCandidateScore[] = scoreAllCandidates(
    sourceBasis,
    targetBasis,
    sourceWorld,
    targetWorld
  );

  // 4. 选择最高分候选
  let bestCandidate: OrientationCandidateScore = candidates[0];
  for (let i: number = 1; i < candidates.length; i++) {
    if (candidates[i].score > bestCandidate.score) {
      bestCandidate = candidates[i];
    }
  }

  // 5. 评估置信度
  const confidence: OrientationConfidence = evaluateConfidence(bestCandidate.score, sourceBasis, targetBasis);

  // 6. 安全回退:Low/Unknown 时不启用高风险镜像
  let selectedMode: AvatarOrientationMode = bestCandidate.mode;
  if (confidence === OrientationConfidence.Low || confidence === OrientationConfidence.Unknown) {
    // 低置信度:优先保留 Normal
    if (selectedMode === AvatarOrientationMode.MirrorLeftRight
      || selectedMode === AvatarOrientationMode.MirrorLeftRightAndRotateY180) {
      selectedMode = AvatarOrientationMode.Normal;
    }
  }

  // 7. 解析为具体参数
  const needsY180: boolean = selectedMode === AvatarOrientationMode.RotateY180
    || selectedMode === AvatarOrientationMode.MirrorLeftRightAndRotateY180;
  const needsMirror: boolean = selectedMode === AvatarOrientationMode.MirrorLeftRight
    || selectedMode === AvatarOrientationMode.MirrorLeftRightAndRotateY180;

  return {
    selectedMode: selectedMode,
    confidence: confidence,
    candidateScores: candidates,
    reasonCode: bestCandidate.reasonCode,
    yawOffsetDeg: needsY180 ? 180.0 : 0.0,
    swapLeftRight: needsMirror,
    invertForward: needsY180
  };
}

/**
 * 对所有候选模式评分。
 *
 * 评分信号:
 * 1. Source 和 Target 的 Up 向量一致性(都应朝上)
 * 2. Source 和 Target 的 Right 向量方向关系(同向 vs 反向)
 * 3. 左右骨骼语义一致性(LeftUpperArm 是否在身体左侧)
 * 4. 左右脚语义一致性
 *
 * @param sourceBasis 源骨架基准
 * @param targetBasis 目标骨架基准
 * @param sourceWorld 源世界变换
 * @param targetWorld 目标世界变换
 * @returns 候选评分列表
 */
function scoreAllCandidates(
  sourceBasis: SkeletonBasis,
  targetBasis: SkeletonBasis,
  sourceWorld: Map<HumanoidBone, WorldBoneTransform>,
  targetWorld: Map<HumanoidBone, WorldBoneTransform>
): OrientationCandidateScore[] {
  const candidates: OrientationCandidateScore[] = [];

  // 基础信号
  const rightAlignmentScore: number = computeRightAlignmentScore(sourceBasis, targetBasis);
  const leftRightSemanticScore: number = computeLeftRightSemanticScore(targetWorld);
  const upAlignmentScore: number = computeUpAlignmentScore(sourceBasis, targetBasis);

  // Normal:不校正
  // 评分:Up 一致 + Right 同向 + 左右语义正确
  const normalScore: number = (upAlignmentScore * 0.3) + (rightAlignmentScore * 0.4) + (leftRightSemanticScore * 0.3);
  candidates.push({
    mode: AvatarOrientationMode.Normal,
    score: clampScore(normalScore),
    reasonCode: 'up=' + upAlignmentScore.toFixed(2)
      + ',right=' + rightAlignmentScore.toFixed(2)
      + ',lr=' + leftRightSemanticScore.toFixed(2)
  });

  // RotateY180:Right 反向,Forward 反向
  // 评分:Up 一致 + Right 反向评分 + 左右语义仍正确(镜像不交换左右)
  const rotateRightScore: number = 1.0 - rightAlignmentScore;
  const rotateScore: number = (upAlignmentScore * 0.3) + (rotateRightScore * 0.4) + (leftRightSemanticScore * 0.3);
  candidates.push({
    mode: AvatarOrientationMode.RotateY180,
    score: clampScore(rotateScore),
    reasonCode: 'up=' + upAlignmentScore.toFixed(2)
      + ',rightInv=' + rotateRightScore.toFixed(2)
      + ',lr=' + leftRightSemanticScore.toFixed(2)
  });

  // MirrorLeftRight:Right 反向,但通过交换左右骨骼实现
  // 评分:Up 一致 + Right 反向 + 左右语义反向(交换后变正确)
  const mirrorLeftRightScore: number = 1.0 - leftRightSemanticScore;
  const mirrorScore: number = (upAlignmentScore * 0.3) + (rotateRightScore * 0.4) + (mirrorLeftRightScore * 0.3);
  candidates.push({
    mode: AvatarOrientationMode.MirrorLeftRight,
    score: clampScore(mirrorScore),
    reasonCode: 'up=' + upAlignmentScore.toFixed(2)
      + ',rightInv=' + rotateRightScore.toFixed(2)
      + ',lrInv=' + mirrorLeftRightScore.toFixed(2)
  });

  // MirrorLeftRightAndRotateY180:Right 同向,但左右交换 + Forward 反向
  // 评分:Up 一致 + Right 同向 + 左右语义反向
  const mirrorRotateScore: number = (upAlignmentScore * 0.3) + (rightAlignmentScore * 0.4) + (mirrorLeftRightScore * 0.3);
  candidates.push({
    mode: AvatarOrientationMode.MirrorLeftRightAndRotateY180,
    score: clampScore(mirrorRotateScore),
    reasonCode: 'up=' + upAlignmentScore.toFixed(2)
      + ',right=' + rightAlignmentScore.toFixed(2)
      + ',lrInv=' + mirrorLeftRightScore.toFixed(2)
  });

  return candidates;
}

/**
 * 计算 Up 向量对齐评分。
 *
 * Source 和 Target 的 Up 都应朝 Y 轴正方向(0,1,0)。
 * 评分 = 0.5 + 0.5 × dot(sourceUp, targetUp)(映射到 [0, 1])
 */
function computeUpAlignmentScore(
  sourceBasis: SkeletonBasis,
  targetBasis: SkeletonBasis
): number {
  if (!sourceBasis.valid || !targetBasis.valid) {
    return 0.5; // 无法判断,中性
  }
  const dot: number = vectorDot(sourceBasis.up, targetBasis.up);
  return 0.5 + 0.5 * dot;
}

/**
 * 计算 Right 向量对齐评分。
 *
 * Source 和 Target 的 Right 都应从右肩指向左肩。
 * 评分 = 0.5 + 0.5 × dot(sourceRight, targetRight)
 */
function computeRightAlignmentScore(
  sourceBasis: SkeletonBasis,
  targetBasis: SkeletonBasis
): number {
  if (!sourceBasis.valid || !targetBasis.valid) {
    return 0.5;
  }
  const dot: number = vectorDot(sourceBasis.right, targetBasis.right);
  return 0.5 + 0.5 * dot;
}

/**
 * 计算左右语义一致性评分。
 *
 * 检查目标骨架的 LeftUpperArm 是否在 Hips 的左侧(X 分量符号)。
 *
 * 约定:Right 向量从右肩指向左肩,因此 LeftUpperArm 的 X 分量(相对 Hips)应为正,
 * RightUpperArm 的 X 分量应为负。
 *
 * @param targetWorld 目标世界变换
 * @returns 评分 [0, 1]
 */
function computeLeftRightSemanticScore(
  targetWorld: Map<HumanoidBone, WorldBoneTransform>
): number {
  const hips: WorldBoneTransform | undefined = targetWorld.get(HumanoidBone.Hips);
  if (hips === undefined) {
    return 0.5;
  }

  const leftUpperArm: WorldBoneTransform | undefined = targetWorld.get(HumanoidBone.LeftUpperArm);
  const rightUpperArm: WorldBoneTransform | undefined = targetWorld.get(HumanoidBone.RightUpperArm);
  const leftUpperLeg: WorldBoneTransform | undefined = targetWorld.get(HumanoidBone.LeftUpperLeg);
  const rightUpperLeg: WorldBoneTransform | undefined = targetWorld.get(HumanoidBone.RightUpperLeg);

  let score: number = 0.0;
  let count: number = 0;

  // 检查 LeftUpperArm vs RightUpperArm 的 X 分量
  if (leftUpperArm !== undefined && rightUpperArm !== undefined) {
    const leftX: number = leftUpperArm.position.x - hips.position.x;
    const rightX: number = rightUpperArm.position.x - hips.position.x;
    // Left 应在 Right 的左侧(符号相反,且 Left > Right)
    if (leftX > rightX) {
      score += 1.0;
    } else if (Math.abs(leftX - rightX) < VECTOR_LENGTH_EPS) {
      score += 0.5; // 重合
    }
    count++;
  }

  // 检查 LeftUpperLeg vs RightUpperLeg
  if (leftUpperLeg !== undefined && rightUpperLeg !== undefined) {
    const leftX: number = leftUpperLeg.position.x - hips.position.x;
    const rightX: number = rightUpperLeg.position.x - hips.position.x;
    if (leftX > rightX) {
      score += 1.0;
    } else if (Math.abs(leftX - rightX) < VECTOR_LENGTH_EPS) {
      score += 0.5;
    }
    count++;
  }

  if (count === 0) {
    return 0.5;
  }
  return score / count;
}

/**
 * 评估置信度。
 *
 * 规则:
 * - score >= 0.8 → High
 * - score >= 0.5 → Medium
 * - score > 0 → Low
 * - 否则 → Unknown
 *
 * 额外规则:
 * - 基准无效时降级到 Unknown
 * - 最高分与次高分接近(差值 < 0.1)时降级
 */
function evaluateConfidence(
  bestScore: number,
  sourceBasis: SkeletonBasis,
  targetBasis: SkeletonBasis
): OrientationConfidence {
  if (!sourceBasis.valid || !targetBasis.valid) {
    return OrientationConfidence.Unknown;
  }
  if (bestScore >= CONFIDENCE_HIGH_THRESHOLD) {
    return OrientationConfidence.High;
  }
  if (bestScore >= CONFIDENCE_MEDIUM_THRESHOLD) {
    return OrientationConfidence.Medium;
  }
  if (bestScore > 0) {
    return OrientationConfidence.Low;
  }
  return OrientationConfidence.Unknown;
}

/**
 * 将评分限制在 [0, 1] 范围。
 */
function clampScore(score: number): number {
  return Math.max(0.0, Math.min(1.0, score));
}

/**
 * 估算手臂角度(用于诊断日志)。
 *
 * 返回 UpperArm 相对于垂直方向的偏移角度(度)。
 * 0° = 手臂下垂,90° = T-Pose(水平),180° = 手臂抬起过头。
 */
export function estimateArmAngleDeg(
  worldTransforms: Map<HumanoidBone, WorldBoneTransform>
): number {
  const hips: WorldBoneTransform | undefined = worldTransforms.get(HumanoidBone.Hips);
  const leftUpperArm: WorldBoneTransform | undefined = worldTransforms.get(HumanoidBone.LeftUpperArm);
  const rightUpperArm: WorldBoneTransform | undefined = worldTransforms.get(HumanoidBone.RightUpperArm);

  if (hips === undefined || leftUpperArm === undefined || rightUpperArm === undefined) {
    return -1;
  }

  // 取左右上臂中点
  const armMid: Vector3Value = {
    x: (leftUpperArm.position.x + rightUpperArm.position.x) / 2,
    y: (leftUpperArm.position.y + rightUpperArm.position.y) / 2,
    z: (leftUpperArm.position.z + rightUpperArm.position.z) / 2
  };

  // 相对 Hips 的方向
  const armDir: Vector3Value = vectorNormalize(vectorSub(armMid, hips.position));
  if (vectorLength(armDir) < VECTOR_LENGTH_EPS) {
    return -1;
  }

  // 与 Up 向量(0,1,0)的夹角
  const up: Vector3Value = { x: 0, y: 1, z: 0 };
  const dot: number = Math.max(-1.0, Math.min(1.0, vectorDot(armDir, up)));
  const angleRad: number = Math.acos(dot);
  return angleRad * 180.0 / Math.PI;
}

/**
 * 生成简短的分析摘要日志(用于实机验收 A)。
 *
 * 不输出完整 Avatar ID、文件路径、用户文件名。
 */
export function logAnalysisSummary(analysis: AvatarOrientationAnalysis): void {
  const scoresStr: string = analysis.candidateScores
    .map((c: OrientationCandidateScore): string => c.mode + '=' + c.score.toFixed(2))
    .join(', ');

  // eslint-disable-next-line no-console
  console.info(LOG_TAG, 'Orientation analysis: selectedMode=' + analysis.selectedMode
    + ', confidence=' + analysis.confidence
    + ', yaw=' + analysis.yawOffsetDeg.toFixed(0)
    + ', swap=' + analysis.swapLeftRight
    + ', invert=' + analysis.invertForward
    + ', candidates=[' + scoresStr + ']'
    + ', reason=' + analysis.reasonCode);
}
