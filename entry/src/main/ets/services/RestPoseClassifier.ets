/**
 * RestPoseClassifier 基于 World Position 的姿态分类器
 *
 * T-4.2G-A2: 取代之前基于 UpperArm 本地欧拉角的判断方式。
 *
 * 根据任务要求,分类必须基于 Target Avatar 的实际 World Position:
 * - LeftShoulder → LeftLowerArm/Hand 方向
 * - RightShoulder → RightLowerArm/Hand 方向
 * - Hips → Chest/Head 作为身体 Up 方向
 * - 计算手臂方向与身体 Up 的夹角
 *
 * 分类结果:
 * - TPose:双臂水平展开(夹角 ≈ 90°)
 * - APose:双臂斜下展开(夹角 ≈ 45°)
 * - ArmsDown:双臂自然下垂(夹角 ≈ 0°)
 * - Custom:其他姿态
 * - Unknown:数据缺失,无法判断
 *
 * 重要约束:
 * - 自动识别结果必须记录置信度
 * - 不能根据分类直接用固定角度覆盖所有模型
 * - 仅用于诊断和 UI 显示,不替代真实骨骼数据
 */

import { HumanoidBone } from '../models/character3d/HumanoidBone';
import { Vector3Value } from '../models/character3d/HumanoidMotionClip';
import {
  vectorSubtract,
  vectorNormalize,
  vectorDot,
  vectorLength
} from '../utils/SceneNodeTransformUtil';

/**
 * 姿态类型。
 */
export enum RestPoseType {
  Unknown = 'Unknown',
  TPose = 'TPose',
  APose = 'APose',
  ArmsDown = 'ArmsDown',
  Custom = 'Custom'
}

/**
 * 分类结果。
 */
export interface RestPoseClassification {
  /** 姿态类型 */
  type: RestPoseType;
  /** 置信度 [0, 1] */
  confidence: number;
  /** 左臂角度(度,UpperArm 方向与身体 Up 的夹角) */
  leftArmAngleDeg: number;
  /** 右臂角度(度) */
  rightArmAngleDeg: number;
  /** 平均臂角(度) */
  avgArmAngleDeg: number;
  /** 诊断信息 */
  message: string;
}

/** 角度阈值:TPose 判定(±15°) */
const TPOSE_ANGLE_MIN: number = 75.0;
const TPOSE_ANGLE_MAX: number = 105.0;
/** 角度阈值:APose 判定(±15°) */
const APOSE_ANGLE_MIN: number = 30.0;
const APOSE_ANGLE_MAX: number = 60.0;
/** 角度阈值:ArmsDown 判定(≤20°) */
const ARMS_DOWN_ANGLE_MAX: number = 20.0;
/** 向量长度下限(避免除零) */
const VECTOR_LENGTH_EPS: number = 1e-4;

/**
 * 根据骨骼 World Position 进行姿态分类。
 *
 * 算法:
 * 1. bodyUp = normalize(Chest - Hips)(若 Chest 缺失,使用 Head - Hips)
 * 2. leftArmDir = normalize(LeftHand - LeftShoulder)(若 Hand 缺失,使用 LowerArm - Shoulder)
 * 3. rightArmDir = normalize(RightHand - RightShoulder)
 * 4. leftAngle = acos(dot(leftArmDir, bodyUp)) * 180/PI
 * 5. rightAngle = acos(dot(rightArmDir, bodyUp)) * 180/PI
 * 6. 根据 avgAngle 分类
 *
 * @param worldPositions 骨骼 World Position 映射
 * @returns 分类结果
 */
export function classifyRestPose(
  worldPositions: Map<HumanoidBone, Vector3Value>
): RestPoseClassification {
  const hips: Vector3Value | undefined = worldPositions.get(HumanoidBone.Hips);
  const chest: Vector3Value | undefined = worldPositions.get(HumanoidBone.Chest);
  const head: Vector3Value | undefined = worldPositions.get(HumanoidBone.Head);
  const leftShoulder: Vector3Value | undefined = worldPositions.get(HumanoidBone.LeftShoulder);
  const rightShoulder: Vector3Value | undefined = worldPositions.get(HumanoidBone.RightShoulder);
  const leftLowerArm: Vector3Value | undefined = worldPositions.get(HumanoidBone.LeftLowerArm);
  const rightLowerArm: Vector3Value | undefined = worldPositions.get(HumanoidBone.RightLowerArm);
  const leftHand: Vector3Value | undefined = worldPositions.get(HumanoidBone.LeftHand);
  const rightHand: Vector3Value | undefined = worldPositions.get(HumanoidBone.RightHand);

  // 数据完整性检查
  if (hips === undefined) {
    return {
      type: RestPoseType.Unknown,
      confidence: 0.0,
      leftArmAngleDeg: 0,
      rightArmAngleDeg: 0,
      avgArmAngleDeg: 0,
      message: 'Hips 缺失,无法判断姿态'
    };
  }

  // 计算 bodyUp
  const upEnd: Vector3Value | undefined = chest !== undefined ? chest : head;
  if (upEnd === undefined) {
    return {
      type: RestPoseType.Unknown,
      confidence: 0.0,
      leftArmAngleDeg: 0,
      rightArmAngleDeg: 0,
      avgArmAngleDeg: 0,
      message: 'Chest 和 Head 均缺失,无法判断身体 Up 方向'
    };
  }
  const bodyUp: Vector3Value = vectorNormalize(vectorSubtract(upEnd, hips));
  if (vectorLength(bodyUp) < VECTOR_LENGTH_EPS) {
    return {
      type: RestPoseType.Unknown,
      confidence: 0.0,
      leftArmAngleDeg: 0,
      rightArmAngleDeg: 0,
      avgArmAngleDeg: 0,
      message: 'bodyUp 向量长度为零,无法判断身体 Up 方向'
    };
  }

  // 计算左臂方向(优先 Hand,缺失时使用 LowerArm)
  const leftArmEnd: Vector3Value | undefined = leftHand !== undefined ? leftHand : leftLowerArm;
  const leftAngle: number = (leftShoulder !== undefined && leftArmEnd !== undefined)
    ? computeArmAngleDeg(leftArmEnd, leftShoulder, bodyUp)
    : -1;

  // 计算右臂方向(优先 Hand,缺失时使用 LowerArm)
  const rightArmEnd: Vector3Value | undefined = rightHand !== undefined ? rightHand : rightLowerArm;
  const rightAngle: number = (rightShoulder !== undefined && rightArmEnd !== undefined)
    ? computeArmAngleDeg(rightArmEnd, rightShoulder, bodyUp)
    : -1;

  // 至少有一侧能算出
  if (leftAngle < 0 && rightAngle < 0) {
    return {
      type: RestPoseType.Unknown,
      confidence: 0.0,
      leftArmAngleDeg: 0,
      rightArmAngleDeg: 0,
      avgArmAngleDeg: 0,
      message: '左右 Shoulder/Hand 均缺失,无法判断手臂角度'
    };
  }

  // 计算平均角度(忽略 -1)
  const validAngles: number[] = [];
  if (leftAngle >= 0) {
    validAngles.push(leftAngle);
  }
  if (rightAngle >= 0) {
    validAngles.push(rightAngle);
  }
  const avgAngle: number = validAngles.length > 0
    ? validAngles.reduce((s: number, a: number) => s + a, 0) / validAngles.length
    : 0;

  // 双侧一致性检查(若两侧都有数据,差异过大降低置信度)
  let confidence: number = 0.9;
  if (leftAngle >= 0 && rightAngle >= 0) {
    const diff: number = Math.abs(leftAngle - rightAngle);
    if (diff > 30) {
      confidence = 0.4;
    } else if (diff > 15) {
      confidence = 0.7;
    }
  } else {
    // 只有单侧数据,降低置信度
    confidence = 0.6;
  }

  // 分类
  let poseType: RestPoseType = RestPoseType.Custom;
  if (avgAngle >= TPOSE_ANGLE_MIN && avgAngle <= TPOSE_ANGLE_MAX) {
    poseType = RestPoseType.TPose;
    confidence = Math.min(1.0, confidence + 0.05);
  } else if (avgAngle >= APOSE_ANGLE_MIN && avgAngle <= APOSE_ANGLE_MAX) {
    poseType = RestPoseType.APose;
    confidence = Math.min(1.0, confidence + 0.05);
  } else if (avgAngle >= 0 && avgAngle <= ARMS_DOWN_ANGLE_MAX) {
    poseType = RestPoseType.ArmsDown;
    confidence = Math.min(1.0, confidence + 0.05);
  } else {
    poseType = RestPoseType.Custom;
  }

  return {
    type: poseType,
    confidence: confidence,
    leftArmAngleDeg: leftAngle >= 0 ? leftAngle : 0,
    rightArmAngleDeg: rightAngle >= 0 ? rightAngle : 0,
    avgArmAngleDeg: avgAngle,
    message: 'avgAngle=' + avgAngle.toFixed(1)
      + '° left=' + (leftAngle >= 0 ? leftAngle.toFixed(1) : 'N/A')
      + '° right=' + (rightAngle >= 0 ? rightAngle.toFixed(1) : 'N/A')
      + '° type=' + poseType
  };
}

/**
 * 计算单臂角度:手臂方向与身体 Up 的夹角(度)。
 *
 * @param armEnd 手臂末端位置(Hand 或 LowerArm)
 * @param shoulder 肩膀位置
 * @param bodyUp 身体 Up 方向(已归一化)
 * @returns 角度(度);-1 表示数据无效
 */
function computeArmAngleDeg(
  armEnd: Vector3Value,
  shoulder: Vector3Value,
  bodyUp: Vector3Value
): number {
  const armDir: Vector3Value = vectorNormalize(vectorSubtract(armEnd, shoulder));
  if (vectorLength(armDir) < VECTOR_LENGTH_EPS) {
    return -1;
  }
  const dot: number = vectorDot(armDir, bodyUp);
  // 限制到 [-1, 1] 避免 acos 返回 NaN
  const clampedDot: number = Math.max(-1.0, Math.min(1.0, dot));
  const angleRad: number = Math.acos(clampedDot);
  return angleRad * 180.0 / Math.PI;
}
