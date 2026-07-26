/**
 * SourceRetargetDiagnosticCollector Source 重定向基准诊断采集器
 *
 * T-4.2G-A4: 采集三套姿态(Source Rest / Source Animated / Target Rest)的完整数据,
 * 并计算动画第 0 帧与 Source Rest 的逐骨骼 Delta,用于诊断重定向基准是否一致。
 *
 * 任务背景:
 *   T-4.2G-A3 的 error=0 只证明 Target Skeleton 与 Target Avatar Bone 重合,
 *   不证明 Source Animation 到 Target Avatar 的重定向正确。
 *   本模块专门采集 Source 侧数据,回答:
 *     1. Source Rest Pose 来自哪里(GLB nodes TRS / 动画第 0 帧 / 硬编码)
 *     2. 动画第 0 帧与 Source Rest 的 UpperArm/LowerArm Delta 是否合理
 *     3. Source Rest Pose 是 T Pose / A Pose / Arms-Down
 *     4. 是否混用了不同骨架的 Rest Pose
 *
 * 三套姿态:
 *   A. Source Bind/Rest Pose:从 sourceRestPose(HumanoidRestPose)计算
 *      - sourceRestLocalRotation:restPose.bones[bone].localRotation
 *      - sourceRestWorldRotation:从根累乘 localRotation
 *      - sourceRestWorldPosition:从根累乘 localPosition + parentWorldRotation
 *
 *   B. Source Animation Frame(t=0/0.5s/1.0s):从 sampleMotionClip + sourceRestPose 计算
 *      - sourceAnimatedLocalRotation:sampleMotionClip 返回的 rotation
 *      - sourceAnimatedWorldRotation:从根累乘(animated localRotation + rest localPosition)
 *      - sourceAnimatedWorldPosition:从根累乘(animated translation + rest localPosition)
 *
 *   C. Target Rest Pose:从 targetRestPose(HumanoidRestPose)计算
 *      - targetRestLocalRotation:restPose.bones[bone].localRotation
 *      - targetRestWorldRotation:从根累乘 localRotation
 *      - targetRestWorldPosition:从根累乘 localPosition + parentWorldRotation
 *
 * 第 0 帧 Delta:
 *   firstFrameDelta = inverse(sourceRestLocalRotation) × sourceFrame0LocalRotation
 *   重点输出 UpperArm 和 LowerArm 的角度
 *
 * 不依赖 ArkGraphics3D,纯逻辑可单元测试。
 */

import {
  HumanoidMotionClip,
  HumanoidPose,
  HumanoidRestPose,
  BoneRestTransform,
  BonePose,
  QuaternionValue,
  Vector3Value,
  RootMotionMode,
  identityQuaternionValue,
  zeroVector3Value
} from '../models/character3d/HumanoidMotionClip';
import { HumanoidBone, ALL_STANDARD_BONES } from '../models/character3d/HumanoidBone';
import { sampleMotionClip } from './HumanoidMotionSampler';
import {
  findParentBone,
  quaternionRotationAngleDeg,
  retargetPose,
  RetargetResult,
  computeWorldRestRotations
} from './HumanoidRetargetor';
import {
  quaternionMultiply,
  quaternionInverse,
  quaternionNormalize,
  quaternionToEulerDeg
} from '../utils/QuaternionUtil';
import {
  rotateVectorByQuaternion,
  vectorSubtract,
  vectorCross,
  vectorNormalize,
  vectorDot,
  vectorLength
} from '../utils/SceneNodeTransformUtil';
import {
  classifyRestPose as classifyRestPoseByWorldPos
} from './RestPoseClassifier';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'SrcRetargetDiag';

/**
 * T-4.2G-A4: 诊断用关键骨骼列表(10 个)。
 *
 * 任务要求采集:
 *   Hips, Chest,
 *   LeftUpperArm, LeftLowerArm, LeftHand,
 *   RightUpperArm, RightLowerArm, RightHand,
 *   LeftUpperLeg, RightUpperLeg
 */
const DIAGNOSTIC_BONES: HumanoidBone[] = [
  HumanoidBone.Hips,
  HumanoidBone.Chest,
  HumanoidBone.LeftUpperArm,
  HumanoidBone.LeftLowerArm,
  HumanoidBone.LeftHand,
  HumanoidBone.RightUpperArm,
  HumanoidBone.RightLowerArm,
  HumanoidBone.RightHand,
  HumanoidBone.LeftUpperLeg,
  HumanoidBone.RightUpperLeg
];

/**
 * 单根骨骼的世界变换快照。
 */
export interface BoneWorldSnapshot {
  bone: HumanoidBone;
  /** 局部旋转(四元数) */
  localRotation: QuaternionValue;
  /** 局部位置(向量) */
  localPosition: Vector3Value;
  /** 世界旋转(从根累乘) */
  worldRotation: QuaternionValue;
  /** 世界位置(从根累乘) */
  worldPosition: Vector3Value;
}

/**
 * 一套姿态的完整快照(所有诊断骨骼)。
 */
export interface PoseSnapshot {
  /** 姿态标签(SourceRest / SourceAnimated_t0 / TargetRest 等) */
  label: string;
  /** bone → 世界快照 */
  bones: Map<HumanoidBone, BoneWorldSnapshot>;
}

/**
 * 单根骨骼的第 0 帧 Delta。
 */
export interface FirstFrameDeltaStat {
  bone: HumanoidBone;
  /** sourceRestLocalRotation */
  restLocal: QuaternionValue;
  /** sourceFrame0LocalRotation */
  frame0Local: QuaternionValue;
  /** firstFrameDelta = inverse(restLocal) × frame0Local */
  delta: QuaternionValue;
  /** delta 的旋转角度(度) */
  deltaAngleDeg: number;
  /** restLocal 的欧拉角(度) */
  restEulerDeg: number[];
  /** frame0Local 的欧拉角(度) */
  frame0EulerDeg: number[];
}

/**
 * 三套姿态完整诊断结果。
 */
export interface FullDiagnosticSnapshot {
  /** Source Rest Pose 快照 */
  sourceRest: PoseSnapshot;
  /** Source Animated t=0 快照 */
  sourceAnimatedT0: PoseSnapshot;
  /** Source Animated t=0.5s 快照(若 duration >= 0.5) */
  sourceAnimatedT05: PoseSnapshot | null;
  /** Source Animated t=1.0s 快照(若 duration >= 1.0) */
  sourceAnimatedT10: PoseSnapshot | null;
  /** Target Rest Pose 快照 */
  targetRest: PoseSnapshot;
  /** 第 0 帧 Delta 统计(所有诊断骨骼) */
  firstFrameDeltas: FirstFrameDeltaStat[];
  /** 动画 duration(秒) */
  durationSeconds: number;
  /** Source Rest Pose 来源说明 */
  sourceRestOrigin: string;
  /** Source Rest Pose 分类(T Pose / A Pose / ArmsDown / Unknown) */
  sourceRestClassification: string;
  /** Target Rest Pose 分类 */
  targetRestClassification: string;
}

/**
 * 计算一套 Rest Pose 的世界变换(所有诊断骨骼)。
 *
 * 算法:
 *   按 ALL_STANDARD_BONES 层级顺序遍历,
 *   worldRot[bone] = worldRot[parent] × localRot[bone]
 *   worldPos[bone] = worldPos[parent] + rotate(worldRot[parent], localPos[bone] × worldScale[parent])
 *   (本函数忽略 scale,假定 scale=1;若需要可扩展)
 *
 * @param restPose Rest Pose
 * @param label 快照标签
 * @returns Pose 快照(只包含 DIAGNOSTIC_BONES 中的骨骼)
 */
export function computeRestPoseWorldSnapshot(
  restPose: HumanoidRestPose,
  label: string
): PoseSnapshot {
  const snapshot: PoseSnapshot = { label: label, bones: new Map<HumanoidBone, BoneWorldSnapshot>() };

  // 先计算所有骨骼的 world transform(用 Map 缓存,避免重复计算)
  const worldRotMap: Map<HumanoidBone, QuaternionValue> = new Map();
  const worldPosMap: Map<HumanoidBone, Vector3Value> = new Map();

  for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
    const bone: HumanoidBone = ALL_STANDARD_BONES[i];
    const rest: BoneRestTransform | undefined = restPose.bones.get(bone);
    const localRot: QuaternionValue = rest !== undefined ? rest.localRotation : identityQuaternionValue();
    const localPos: Vector3Value = rest !== undefined ? rest.localPosition : zeroVector3Value();

    const parentBone: HumanoidBone | null = findParentBone(bone);
    if (parentBone === null) {
      // 根节点
      worldRotMap.set(bone, quaternionNormalize(localRot));
      worldPosMap.set(bone, { x: localPos.x, y: localPos.y, z: localPos.z });
    } else {
      const parentWorldRot: QuaternionValue = worldRotMap.get(parentBone) ?? identityQuaternionValue();
      const parentWorldPos: Vector3Value = worldPosMap.get(parentBone) ?? zeroVector3Value();
      // worldRot = parentWorldRot × localRot
      const worldRot: QuaternionValue = quaternionNormalize(quaternionMultiply(parentWorldRot, localRot));
      // worldPos = parentWorldPos + rotate(parentWorldRot, localPos)
      const rotated: Vector3Value = rotateVectorByQuaternion(localPos, parentWorldRot);
      const worldPos: Vector3Value = {
        x: parentWorldPos.x + rotated.x,
        y: parentWorldPos.y + rotated.y,
        z: parentWorldPos.z + rotated.z
      };
      worldRotMap.set(bone, worldRot);
      worldPosMap.set(bone, worldPos);
    }
  }

  // 只采集 DIAGNOSTIC_BONES
  for (let i: number = 0; i < DIAGNOSTIC_BONES.length; i++) {
    const bone: HumanoidBone = DIAGNOSTIC_BONES[i];
    const rest: BoneRestTransform | undefined = restPose.bones.get(bone);
    const localRot: QuaternionValue = rest !== undefined ? rest.localRotation : identityQuaternionValue();
    const localPos: Vector3Value = rest !== undefined ? rest.localPosition : zeroVector3Value();
    const worldRot: QuaternionValue = worldRotMap.get(bone) ?? identityQuaternionValue();
    const worldPos: Vector3Value = worldPosMap.get(bone) ?? zeroVector3Value();
    snapshot.bones.set(bone, {
      bone: bone,
      localRotation: localRot,
      localPosition: localPos,
      worldRotation: worldRot,
      worldPosition: worldPos
    });
  }

  return snapshot;
}

/**
 * 计算一套 Animated Pose 的世界变换(所有诊断骨骼)。
 *
 * 算法:
 *   对每根骨骼,若 pose.bones[bone].rotation 非 null,使用 animated rotation;
 *   否则使用 restPose.bones[bone].localRotation。
 *   对 Hips,若 pose.bones[Hips].translation 非 null,使用 animated translation;
 *   否则使用 restPose.bones[Hips].localPosition。
 *   然后按层级累乘计算 world transform。
 *
 * @param restPose Rest Pose(用于补全缺失的动画数据)
 * @param animatedPose 采样得到的动画姿态
 * @param label 快照标签
 * @returns Pose 快照
 */
export function computeAnimatedPoseWorldSnapshot(
  restPose: HumanoidRestPose,
  animatedPose: HumanoidPose,
  label: string
): PoseSnapshot {
  const snapshot: PoseSnapshot = { label: label, bones: new Map<HumanoidBone, BoneWorldSnapshot>() };

  // 先计算所有骨骼的 world transform
  const worldRotMap: Map<HumanoidBone, QuaternionValue> = new Map();
  const worldPosMap: Map<HumanoidBone, Vector3Value> = new Map();

  for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
    const bone: HumanoidBone = ALL_STANDARD_BONES[i];
    const rest: BoneRestTransform | undefined = restPose.bones.get(bone);
    const restLocalRot: QuaternionValue = rest !== undefined ? rest.localRotation : identityQuaternionValue();
    const restLocalPos: Vector3Value = rest !== undefined ? rest.localPosition : zeroVector3Value();

    const bonePose: BonePose | undefined = animatedPose.bones.get(bone);
    // 动画旋转:若 pose 有 rotation,使用 pose;否则使用 rest
    const animLocalRot: QuaternionValue = (bonePose !== undefined && bonePose.rotation !== null)
      ? bonePose.rotation
      : restLocalRot;
    // 动画位移:仅 Hips 可能非 null
    const animLocalPos: Vector3Value = (bonePose !== undefined && bonePose.translation !== null)
      ? bonePose.translation
      : restLocalPos;

    const parentBone: HumanoidBone | null = findParentBone(bone);
    if (parentBone === null) {
      worldRotMap.set(bone, quaternionNormalize(animLocalRot));
      worldPosMap.set(bone, { x: animLocalPos.x, y: animLocalPos.y, z: animLocalPos.z });
    } else {
      const parentWorldRot: QuaternionValue = worldRotMap.get(parentBone) ?? identityQuaternionValue();
      const parentWorldPos: Vector3Value = worldPosMap.get(parentBone) ?? zeroVector3Value();
      const worldRot: QuaternionValue = quaternionNormalize(quaternionMultiply(parentWorldRot, animLocalRot));
      const rotated: Vector3Value = rotateVectorByQuaternion(animLocalPos, parentWorldRot);
      const worldPos: Vector3Value = {
        x: parentWorldPos.x + rotated.x,
        y: parentWorldPos.y + rotated.y,
        z: parentWorldPos.z + rotated.z
      };
      worldRotMap.set(bone, worldRot);
      worldPosMap.set(bone, worldPos);
    }
  }

  // 只采集 DIAGNOSTIC_BONES
  for (let i: number = 0; i < DIAGNOSTIC_BONES.length; i++) {
    const bone: HumanoidBone = DIAGNOSTIC_BONES[i];
    const rest: BoneRestTransform | undefined = restPose.bones.get(bone);
    const restLocalRot: QuaternionValue = rest !== undefined ? rest.localRotation : identityQuaternionValue();
    const restLocalPos: Vector3Value = rest !== undefined ? rest.localPosition : zeroVector3Value();
    const bonePose: BonePose | undefined = animatedPose.bones.get(bone);
    const animLocalRot: QuaternionValue = (bonePose !== undefined && bonePose.rotation !== null)
      ? bonePose.rotation
      : restLocalRot;
    const animLocalPos: Vector3Value = (bonePose !== undefined && bonePose.translation !== null)
      ? bonePose.translation
      : restLocalPos;
    const worldRot: QuaternionValue = worldRotMap.get(bone) ?? identityQuaternionValue();
    const worldPos: Vector3Value = worldPosMap.get(bone) ?? zeroVector3Value();
    snapshot.bones.set(bone, {
      bone: bone,
      localRotation: animLocalRot,
      localPosition: animLocalPos,
      worldRotation: worldRot,
      worldPosition: worldPos
    });
  }

  return snapshot;
}

/**
 * 计算动画第 0 帧与 Source Rest 的逐骨骼 Delta。
 *
 * firstFrameDelta = inverse(sourceRestLocalRotation) × sourceFrame0LocalRotation
 *
 * 重点输出 UpperArm 和 LowerArm 的角度,用于判断:
 *   - 若 UpperArm delta > 20°~30°,说明动画第 0 帧不是 Source Rest,
 *     或 Source Rest 与该动作不属于同一骨架基准
 *
 * @param sourceRest Source Rest Pose
 * @param sourceFrame0Pose 动画第 0 帧采样
 * @returns Delta 统计(所有诊断骨骼)
 */
export function computeFirstFrameDeltas(
  sourceRest: HumanoidRestPose,
  sourceFrame0Pose: HumanoidPose
): FirstFrameDeltaStat[] {
  const stats: FirstFrameDeltaStat[] = [];

  for (let i: number = 0; i < DIAGNOSTIC_BONES.length; i++) {
    const bone: HumanoidBone = DIAGNOSTIC_BONES[i];
    const rest: BoneRestTransform | undefined = sourceRest.bones.get(bone);
    if (rest === undefined) {
      continue;
    }
    const restLocal: QuaternionValue = rest.localRotation;

    const bonePose: BonePose | undefined = sourceFrame0Pose.bones.get(bone);
    const frame0Local: QuaternionValue = (bonePose !== undefined && bonePose.rotation !== null)
      ? bonePose.rotation
      : restLocal;

    // firstFrameDelta = inverse(restLocal) × frame0Local
    const restInverse: QuaternionValue = quaternionInverse(restLocal);
    const delta: QuaternionValue = quaternionNormalize(quaternionMultiply(restInverse, frame0Local));
    const deltaAngle: number = quaternionRotationAngleDeg(delta);
    const restEuler: number[] = quaternionToEulerDeg(restLocal);
    const frame0Euler: number[] = quaternionToEulerDeg(frame0Local);

    stats.push({
      bone: bone,
      restLocal: restLocal,
      frame0Local: frame0Local,
      delta: delta,
      deltaAngleDeg: deltaAngle,
      restEulerDeg: restEuler,
      frame0EulerDeg: frame0Euler
    });
  }

  return stats;
}

/**
 * 计算所有 ALL_STANDARD_BONES 的 worldPosition Map(用于 RestPoseClassifier)。
 *
 * RestPoseClassifier 需要完整骨骼层级(尤其是 LeftShoulder/RightShoulder/Chest/Head)
 * 才能正确计算手臂方向与身体 Up 的夹角。DIAGNOSTIC_BONES 不包含 Shoulder,
 * 因此本函数独立计算所有 ALL_STANDARD_BONES 的 worldPosition。
 *
 * 算法与 computeRestPoseWorldSnapshot 内部一致:
 *   worldRot[bone] = worldRot[parent] × localRot[bone]
 *   worldPos[bone] = worldPos[parent] + rotate(worldRot[parent], localPos[bone])
 *
 * @param restPose Rest Pose
 * @returns bone → worldPosition(包含 ALL_STANDARD_BONES)
 */
function computeAllBoneWorldPositions(
  restPose: HumanoidRestPose
): Map<HumanoidBone, Vector3Value> {
  const worldRotMap: Map<HumanoidBone, QuaternionValue> = new Map();
  const worldPosMap: Map<HumanoidBone, Vector3Value> = new Map();

  for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
    const bone: HumanoidBone = ALL_STANDARD_BONES[i];
    const rest: BoneRestTransform | undefined = restPose.bones.get(bone);
    const localRot: QuaternionValue = rest !== undefined ? rest.localRotation : identityQuaternionValue();
    const localPos: Vector3Value = rest !== undefined ? rest.localPosition : zeroVector3Value();

    const parentBone: HumanoidBone | null = findParentBone(bone);
    if (parentBone === null) {
      worldRotMap.set(bone, quaternionNormalize(localRot));
      worldPosMap.set(bone, { x: localPos.x, y: localPos.y, z: localPos.z });
    } else {
      const parentWorldRot: QuaternionValue = worldRotMap.get(parentBone) ?? identityQuaternionValue();
      const parentWorldPos: Vector3Value = worldPosMap.get(parentBone) ?? zeroVector3Value();
      const worldRot: QuaternionValue = quaternionNormalize(quaternionMultiply(parentWorldRot, localRot));
      const rotated: Vector3Value = rotateVectorByQuaternion(localPos, parentWorldRot);
      const worldPos: Vector3Value = {
        x: parentWorldPos.x + rotated.x,
        y: parentWorldPos.y + rotated.y,
        z: parentWorldPos.z + rotated.z
      };
      worldRotMap.set(bone, worldRot);
      worldPosMap.set(bone, worldPos);
    }
  }

  return worldPosMap;
}

/**
 * 采集完整三套姿态诊断快照。
 *
 * @param clip 动作 clip
 * @param sourceRestPose Source Rest Pose(来自 GLB nodes TRS)
 * @param targetRestPose Target Rest Pose(来自 Avatar SceneNode)
 * @returns 完整诊断快照
 */
export function collectFullDiagnosticSnapshot(
  clip: HumanoidMotionClip,
  sourceRestPose: HumanoidRestPose,
  targetRestPose: HumanoidRestPose
): FullDiagnosticSnapshot {
  // A. Source Rest
  const sourceRest: PoseSnapshot = computeRestPoseWorldSnapshot(sourceRestPose, 'SourceRest');

  // B. Source Animated t=0
  const poseT0: HumanoidPose = sampleMotionClip(clip, 0);
  const sourceAnimatedT0: PoseSnapshot = computeAnimatedPoseWorldSnapshot(
    sourceRestPose, poseT0, 'SourceAnimated_t0'
  );

  // B. Source Animated t=0.5s(若 duration >= 0.5)
  let sourceAnimatedT05: PoseSnapshot | null = null;
  if (clip.durationSeconds >= 0.5) {
    const poseT05: HumanoidPose = sampleMotionClip(clip, 0.5);
    sourceAnimatedT05 = computeAnimatedPoseWorldSnapshot(
      sourceRestPose, poseT05, 'SourceAnimated_t05'
    );
  }

  // B. Source Animated t=1.0s(若 duration >= 1.0)
  let sourceAnimatedT10: PoseSnapshot | null = null;
  if (clip.durationSeconds >= 1.0) {
    const poseT10: HumanoidPose = sampleMotionClip(clip, 1.0);
    sourceAnimatedT10 = computeAnimatedPoseWorldSnapshot(
      sourceRestPose, poseT10, 'SourceAnimated_t10'
    );
  }

  // C. Target Rest
  const targetRest: PoseSnapshot = computeRestPoseWorldSnapshot(targetRestPose, 'TargetRest');

  // 第 0 帧 Delta
  const firstFrameDeltas: FirstFrameDeltaStat[] = computeFirstFrameDeltas(sourceRestPose, poseT0);

  // 分类(T-4.2G-A4 修复: 改用基于 worldPosition 的 RestPoseClassifier,
  //  旧实现基于 UpperArm localEuler X 会因父骨骼累积旋转而误判 ArmsDown)
  const sourceWorldPositions: Map<HumanoidBone, Vector3Value> = computeAllBoneWorldPositions(sourceRestPose);
  const targetWorldPositions: Map<HumanoidBone, Vector3Value> = computeAllBoneWorldPositions(targetRestPose);
  const sourceRestClassification: string = classifyRestPoseByWorldPos(sourceWorldPositions).type;
  const targetRestClassification: string = classifyRestPoseByWorldPos(targetWorldPositions).type;

  return {
    sourceRest: sourceRest,
    sourceAnimatedT0: sourceAnimatedT0,
    sourceAnimatedT05: sourceAnimatedT05,
    sourceAnimatedT10: sourceAnimatedT10,
    targetRest: targetRest,
    firstFrameDeltas: firstFrameDeltas,
    durationSeconds: clip.durationSeconds,
    sourceRestOrigin: 'GLB nodes default TRS (parsed by parseSourceRestPose, not animation frame 0)',
    sourceRestClassification: sourceRestClassification,
    targetRestClassification: targetRestClassification
  };
}

/**
 * 格式化四元数为字符串。
 */
function fmtQuat(q: QuaternionValue): string {
  return '(' + q.x.toFixed(3) + ',' + q.y.toFixed(3) + ',' + q.z.toFixed(3) + ',' + q.w.toFixed(3) + ')';
}

/**
 * 格式化向量为字符串。
 */
function fmtVec3(v: Vector3Value): string {
  return '(' + v.x.toFixed(4) + ',' + v.y.toFixed(4) + ',' + v.z.toFixed(4) + ')';
}

/**
 * 格式化欧拉角为字符串。
 */
function fmtEuler(euler: number[]): string {
  return '(' + euler[0].toFixed(1) + ',' + euler[1].toFixed(1) + ',' + euler[2].toFixed(1) + ')';
}

/**
 * 输出完整诊断日志(三套姿态 + 第 0 帧 Delta + Rest Pose 分类)。
 *
 * 日志格式:
 *   === SourceRetargetDiagnosticSnapshot ===
 *   sourceRestOrigin: GLB nodes default TRS ...
 *   sourceRestClassification: TPose / APose / ArmsDown
 *   targetRestClassification: TPose / APose / ArmsDown
 *   duration: 2.000s
 *
 *   [SourceRest]
 *     Hips localRot=... localPos=... worldRot=... worldPos=...
 *     ...
 *
 *   [SourceAnimated_t0]
 *     ...
 *
 *   [SourceAnimated_t05] (if duration >= 0.5)
 *     ...
 *
 *   [SourceAnimated_t10] (if duration >= 1.0)
 *     ...
 *
 *   [TargetRest]
 *     ...
 *
 *   [FirstFrameDelta] (t=0 vs SourceRest)
 *     Hips delta=0.0deg restEuler=... frame0Euler=...
 *     RightUpperArm delta=12.3deg restEuler=... frame0Euler=...
 *     RightLowerArm delta=45.6deg restEuler=... frame0Euler=...
 *     ...
 *
 *   maxDeltaBone=RightUpperArm maxDelta=12.3deg
 *
 * @param snapshot 诊断快照
 */
export function logFullDiagnosticSnapshot(snapshot: FullDiagnosticSnapshot): void {
  Logger.info(LOG_TAG, '=== SourceRetargetDiagnosticSnapshot ===');
  Logger.info(LOG_TAG, 'sourceRestOrigin: ' + snapshot.sourceRestOrigin);
  Logger.info(LOG_TAG, 'sourceRestClassification: ' + snapshot.sourceRestClassification);
  Logger.info(LOG_TAG, 'targetRestClassification: ' + snapshot.targetRestClassification);
  Logger.info(LOG_TAG, 'duration: ' + snapshot.durationSeconds.toFixed(3) + 's');

  // 输出 Pose 快照
  const snapshots: PoseSnapshot[] = [snapshot.sourceRest, snapshot.sourceAnimatedT0];
  if (snapshot.sourceAnimatedT05 !== null) {
    snapshots.push(snapshot.sourceAnimatedT05);
  }
  if (snapshot.sourceAnimatedT10 !== null) {
    snapshots.push(snapshot.sourceAnimatedT10);
  }
  snapshots.push(snapshot.targetRest);

  for (let s: number = 0; s < snapshots.length; s++) {
    const pose: PoseSnapshot = snapshots[s];
    Logger.info(LOG_TAG, '[' + pose.label + ']');
    const boneKeys: HumanoidBone[] = Array.from(pose.bones.keys());
    for (let i: number = 0; i < boneKeys.length; i++) {
      const bone: HumanoidBone = boneKeys[i];
      const snap: BoneWorldSnapshot | undefined = pose.bones.get(bone);
      if (snap === undefined) {
        continue;
      }
      const localEuler: number[] = quaternionToEulerDeg(snap.localRotation);
      const worldEuler: number[] = quaternionToEulerDeg(snap.worldRotation);
      Logger.info(LOG_TAG, '  ' + bone
        + ' localRot=' + fmtQuat(snap.localRotation)
        + ' localEuler=' + fmtEuler(localEuler)
        + ' localPos=' + fmtVec3(snap.localPosition)
        + ' worldRot=' + fmtQuat(snap.worldRotation)
        + ' worldEuler=' + fmtEuler(worldEuler)
        + ' worldPos=' + fmtVec3(snap.worldPosition));
    }
  }

  // 输出第 0 帧 Delta
  Logger.info(LOG_TAG, '[FirstFrameDelta] (t=0 vs SourceRest)');
  let maxDeltaBone: HumanoidBone | null = null;
  let maxDelta: number = 0;
  for (let i: number = 0; i < snapshot.firstFrameDeltas.length; i++) {
    const stat: FirstFrameDeltaStat = snapshot.firstFrameDeltas[i];
    Logger.info(LOG_TAG, '  ' + stat.bone
      + ' delta=' + stat.deltaAngleDeg.toFixed(2) + 'deg'
      + ' restEuler=' + fmtEuler(stat.restEulerDeg)
      + ' frame0Euler=' + fmtEuler(stat.frame0EulerDeg));
    if (stat.deltaAngleDeg > maxDelta) {
      maxDelta = stat.deltaAngleDeg;
      maxDeltaBone = stat.bone;
    }
  }
  if (maxDeltaBone !== null) {
    Logger.info(LOG_TAG, 'maxDeltaBone=' + maxDeltaBone + ' maxDelta=' + maxDelta.toFixed(2) + 'deg');
  }

  // 重点输出 UpperArm / LowerArm 的 Delta
  const focusBones: HumanoidBone[] = [
    HumanoidBone.LeftUpperArm,
    HumanoidBone.LeftLowerArm,
    HumanoidBone.RightUpperArm,
    HumanoidBone.RightLowerArm
  ];
  Logger.info(LOG_TAG, '[FocusBonesDelta] UpperArm/LowerArm');
  for (let i: number = 0; i < focusBones.length; i++) {
    const bone: HumanoidBone = focusBones[i];
    for (let j: number = 0; j < snapshot.firstFrameDeltas.length; j++) {
      if (snapshot.firstFrameDeltas[j].bone === bone) {
        const stat: FirstFrameDeltaStat = snapshot.firstFrameDeltas[j];
        const flag: string = stat.deltaAngleDeg > 20 ? ' *** >20deg (suspicious)' : '';
        Logger.info(LOG_TAG, '  ' + bone
          + ' delta=' + stat.deltaAngleDeg.toFixed(2) + 'deg'
          + ' restEuler=' + fmtEuler(stat.restEulerDeg)
          + ' frame0Euler=' + fmtEuler(stat.frame0EulerDeg)
          + flag);
        break;
      }
    }
  }

  Logger.info(LOG_TAG, '=== SourceRetargetDiagnosticSnapshot End ===');
}

/**
 * 检查诊断结果是否表明存在重定向基准问题。
 *
 * 判断标准:
 *   - UpperArm 或 LowerArm 的第 0 帧 Delta > 30deg
 *   - Source Rest 分类与 Target Rest 分类不一致(例如 Source=ArmsDown, Target=TPose)
 *
 * @param snapshot 诊断快照
 * @returns 问题描述数组(空数组表示无问题)
 */
export function diagnoseRetargetBaseline(snapshot: FullDiagnosticSnapshot): string[] {
  const issues: string[] = [];

  // 检查 UpperArm / LowerArm Delta
  const focusBones: HumanoidBone[] = [
    HumanoidBone.LeftUpperArm,
    HumanoidBone.LeftLowerArm,
    HumanoidBone.RightUpperArm,
    HumanoidBone.RightLowerArm
  ];
  for (let i: number = 0; i < focusBones.length; i++) {
    const bone: HumanoidBone = focusBones[i];
    for (let j: number = 0; j < snapshot.firstFrameDeltas.length; j++) {
      if (snapshot.firstFrameDeltas[j].bone === bone) {
        const stat: FirstFrameDeltaStat = snapshot.firstFrameDeltas[j];
        if (stat.deltaAngleDeg > 30) {
          issues.push(bone + ' firstFrameDelta=' + stat.deltaAngleDeg.toFixed(2)
            + 'deg > 30deg (animation frame 0 is NOT source rest pose, or rest pose mismatch)');
        } else if (stat.deltaAngleDeg > 20) {
          issues.push(bone + ' firstFrameDelta=' + stat.deltaAngleDeg.toFixed(2)
            + 'deg > 20deg (suspicious, may indicate rest pose mismatch)');
        }
        break;
      }
    }
  }

  // 检查 Rest Pose 分类一致性
  if (snapshot.sourceRestClassification !== snapshot.targetRestClassification) {
    issues.push('Rest pose classification mismatch: source=' + snapshot.sourceRestClassification
      + ', target=' + snapshot.targetRestClassification
      + ' (retargetor should handle this via worldDelta, but verify visually)');
  }

  return issues;
}

// ==================== T-4.2G-A4B: 单骨骼轴测试 + Basis 比较 ====================

/**
 * T-4.2G-A4B: 单骨骼轴测试输入轴枚举。
 *
 * 用于单骨骼纯逻辑输入测试,对 Source Rest Pose 分别施加 X/Y/Z 轴 ±30°(UpperArm) 或 ±45°(LowerArm)。
 */
export enum TestAxis {
  X = 'X',
  Y = 'Y',
  Z = 'Z'
}

/**
 * T-4.2G-A4B: 单骨骼轴测试用例定义。
 */
export interface SingleBoneAxisTestCase {
  /** 测试骨骼 */
  bone: HumanoidBone;
  /** 旋转轴 */
  axis: TestAxis;
  /** 旋转角度(度,带符号) */
  angleDeg: number;
}

/**
 * T-4.2G-A4B: 单骨骼轴测试结果。
 */
export interface SingleBoneAxisTestResult {
  /** 测试用例 */
  testCase: SingleBoneAxisTestCase;
  /** 输入的 sourceDelta(local space) */
  sourceDelta: QuaternionValue;
  /** sourceDelta 角度(度,应等于 |angleDeg|) */
  sourceDeltaAngleDeg: number;
  /** 应用 retargetPose 后的 target 局部旋转 */
  targetAppliedLocalRot: QuaternionValue;
  /** target Rest 局部旋转(对照) */
  targetRestLocalRot: QuaternionValue;
  /** target 实际旋转角度(度) */
  targetAppliedAngleDeg: number;
  /** target 相对 Rest 的旋转角度(度,应接近 |angleDeg|) */
  targetRelativeAngleDeg: number;
  /** target 相对 Rest 的旋转欧拉角(度) */
  targetRelativeEulerDeg: number[];
  /** target 实际弯曲方向的语义描述(抬臂/前摆/后摆/屈肘等) */
  targetSemanticDirection: string;
  /** 是否符合人体语义 */
  isAnatomicallyValid: boolean;
}

/**
 * T-4.2G-A4B: 构造绕指定轴旋转指定角度的四元数。
 *
 * @param axis X / Y / Z
 * @param angleDeg 角度(度,带符号)
 * @returns 单位四元数
 */
function quaternionFromAxisAngle(axis: TestAxis, angleDeg: number): QuaternionValue {
  const halfRad: number = (angleDeg * Math.PI / 180.0) / 2.0;
  const s: number = Math.sin(halfRad);
  const c: number = Math.cos(halfRad);
  if (axis === TestAxis.X) {
    return { x: s, y: 0, z: 0, w: c };
  } else if (axis === TestAxis.Y) {
    return { x: 0, y: s, z: 0, w: c };
  } else {
    return { x: 0, y: 0, z: s, w: c };
  }
}

/**
 * T-4.2G-A4B: 根据 target 相对旋转的欧拉角推断弯曲方向语义。
 *
 * 约定(基于 VRM/gltf Y-up, Right-handed):
 *   UpperArm(右臂):
 *     - X 负方向(−X): 抬臂(arm raises sideways, abduction)
 *     - Y 正方向(+Y): 前摆(arm swings forward, flexion)
 *     - Y 负方向(−Y): 后摆(arm swings backward, extension)
 *   LowerArm(右肘):
 *     - X 正方向(+X): 屈肘(elbow flexion, 内侧弯曲)
 *
 * 注意:此语义判断基于 VRM 右臂坐标系,左臂符号相反。
 *
 * @param bone 测试骨骼
 * @param euler 相对旋转欧拉角 [x, y, z](度)
 * @returns 语义描述字符串
 */
function inferSemanticDirection(bone: HumanoidBone, euler: number[]): string {
  const x: number = euler[0];
  const y: number = euler[1];
  const z: number = euler[2];
  const threshold: number = 5.0; // 5° 阈值

  if (bone === HumanoidBone.RightUpperArm) {
    if (Math.abs(x) > threshold && x < 0) {
      return '抬臂(abduction, X=' + x.toFixed(1) + ')';
    }
    if (Math.abs(y) > threshold && y > 0) {
      return '前摆(flexion, Y=' + y.toFixed(1) + ')';
    }
    if (Math.abs(y) > threshold && y < 0) {
      return '后摆(extension, Y=' + y.toFixed(1) + ')';
    }
    if (Math.abs(z) > threshold) {
      return '绕长轴旋转(twist, Z=' + z.toFixed(1) + ') *** 可疑';
    }
    return '无明显方向(|x|=' + Math.abs(x).toFixed(1) + ',|y|=' + Math.abs(y).toFixed(1) + ')';
  } else if (bone === HumanoidBone.RightLowerArm) {
    if (Math.abs(x) > threshold && x > 0) {
      return '屈肘(elbow flexion, X=' + x.toFixed(1) + ')';
    }
    if (Math.abs(x) > threshold && x < 0) {
      return '反关节(elbow hyperextension, X=' + x.toFixed(1) + ') *** 可疑';
    }
    if (Math.abs(z) > threshold) {
      return '绕长轴旋转代替屈肘(twist, Z=' + z.toFixed(1) + ') *** 可疑';
    }
    return '无明显方向(|x|=' + Math.abs(x).toFixed(1) + ',|y|=' + Math.abs(y).toFixed(1) + ')';
  } else if (bone === HumanoidBone.LeftUpperArm) {
    // 左臂符号相反
    if (Math.abs(x) > threshold && x > 0) {
      return '抬臂(abduction, X=' + x.toFixed(1) + ')';
    }
    if (Math.abs(y) > threshold && y > 0) {
      return '前摆(flexion, Y=' + y.toFixed(1) + ')';
    }
    if (Math.abs(y) > threshold && y < 0) {
      return '后摆(extension, Y=' + y.toFixed(1) + ')';
    }
    if (Math.abs(z) > threshold) {
      return '绕长轴旋转(twist, Z=' + z.toFixed(1) + ') *** 可疑';
    }
    return '无明显方向(|x|=' + Math.abs(x).toFixed(1) + ',|y|=' + Math.abs(y).toFixed(1) + ')';
  } else if (bone === HumanoidBone.LeftLowerArm) {
    if (Math.abs(x) > threshold && x < 0) {
      return '屈肘(elbow flexion, X=' + x.toFixed(1) + ')';
    }
    if (Math.abs(x) > threshold && x > 0) {
      return '反关节(elbow hyperextension, X=' + x.toFixed(1) + ') *** 可疑';
    }
    if (Math.abs(z) > threshold) {
      return '绕长轴旋转代替屈肘(twist, Z=' + z.toFixed(1) + ') *** 可疑';
    }
    return '无明显方向(|x|=' + Math.abs(x).toFixed(1) + ',|y|=' + Math.abs(y).toFixed(1) + ')';
  }
  return '未识别骨骼';
}

/**
 * T-4.2G-A4B: 判断是否符合人体语义。
 *
 * 规则:
 *   - UpperArm: 抬臂/前摆/后摆为有效;绕长轴旋转为可疑
 *   - LowerArm: 屈肘为有效;反关节/绕长轴旋转代替屈肘为可疑
 *
 * @param semanticDirection 语义描述
 * @returns true 表示符合人体语义
 */
function isAnatomicallyValidDirection(semanticDirection: string): boolean {
  return semanticDirection.indexOf('*** 可疑') < 0;
}

/**
 * T-4.2G-A4B: 单骨骼轴测试默认用例集(12 组)。
 *
 * RightUpperArm: X/Y/Z 各 ±30°(6 组)
 * RightLowerArm: X/Y/Z 各 ±45°(6 组)
 */
export function getDefaultSingleBoneAxisTestCases(): SingleBoneAxisTestCase[] {
  const cases: SingleBoneAxisTestCase[] = [
    // RightUpperArm ±30°
    { bone: HumanoidBone.RightUpperArm, axis: TestAxis.X, angleDeg: 30 },
    { bone: HumanoidBone.RightUpperArm, axis: TestAxis.X, angleDeg: -30 },
    { bone: HumanoidBone.RightUpperArm, axis: TestAxis.Y, angleDeg: 30 },
    { bone: HumanoidBone.RightUpperArm, axis: TestAxis.Y, angleDeg: -30 },
    { bone: HumanoidBone.RightUpperArm, axis: TestAxis.Z, angleDeg: 30 },
    { bone: HumanoidBone.RightUpperArm, axis: TestAxis.Z, angleDeg: -30 },
    // RightLowerArm ±45°
    { bone: HumanoidBone.RightLowerArm, axis: TestAxis.X, angleDeg: 45 },
    { bone: HumanoidBone.RightLowerArm, axis: TestAxis.X, angleDeg: -45 },
    { bone: HumanoidBone.RightLowerArm, axis: TestAxis.Y, angleDeg: 45 },
    { bone: HumanoidBone.RightLowerArm, axis: TestAxis.Y, angleDeg: -45 },
    { bone: HumanoidBone.RightLowerArm, axis: TestAxis.Z, angleDeg: 45 },
    { bone: HumanoidBone.RightLowerArm, axis: TestAxis.Z, angleDeg: -45 }
  ];
  return cases;
}

/**
 * T-4.2G-A4B: 对单根骨骼施加指定轴旋转,通过 retargetPose 计算目标局部旋转,返回测试结果。
 *
 * 算法:
 *   1. 构造 sourceDelta = quaternionFromAxisAngle(axis, angleDeg)
 *   2. 构造 sourceAnimatedPose:仅 testCase.bone 旋转 = sourceRestLocalRot × sourceDelta,
 *      其他骨骼保持 Rest
 *   3. 调用 retargetPose 计算 target 局部旋转
 *   4. 计算相对 Rest 的旋转 = inverse(targetRestLocalRot) × targetAppliedLocalRot
 *   5. 推断语义方向并判断是否符合人体语义
 *
 * @param sourceRestPose Source Rest Pose
 * @param targetRestPose Target Rest Pose
 * @param sourceWorldRestMap Source 世界 Rest 旋转(预计算)
 * @param testCase 测试用例
 * @returns 测试结果
 */
export function runSingleBoneAxisTest(
  sourceRestPose: HumanoidRestPose,
  targetRestPose: HumanoidRestPose,
  sourceWorldRestMap: Map<HumanoidBone, QuaternionValue>,
  testCase: SingleBoneAxisTestCase
): SingleBoneAxisTestResult {
  // 引入 retargetPose(动态 require 避免循环依赖,运行时正常解析)
  // 实际通过 import 在文件头解决,这里直接调用
  const sourceRestLocal: QuaternionValue = sourceRestPose.bones.get(testCase.bone)?.localRotation
    ?? identityQuaternionValue();
  const targetRestLocal: QuaternionValue = targetRestPose.bones.get(testCase.bone)?.localRotation
    ?? identityQuaternionValue();

  // 1. sourceDelta(local space)
  const sourceDelta: QuaternionValue = quaternionFromAxisAngle(testCase.axis, testCase.angleDeg);
  const sourceDeltaAngle: number = quaternionRotationAngleDeg(sourceDelta);

  // 2. 构造 sourceAnimatedPose:仅 testCase.bone 旋转,其他保持 Rest
  //    animated localRotation = sourceRestLocal × sourceDelta
  const animatedLocalRot: QuaternionValue = quaternionNormalize(
    quaternionMultiply(sourceRestLocal, sourceDelta)
  );

  // 构造最小 HumanoidPose(只含测试骨骼的旋转)
  const animatedPose: HumanoidPose = {
    bones: new Map<HumanoidBone, BonePose>()
  };
  animatedPose.bones.set(testCase.bone, {
    bone: testCase.bone,
    rotation: animatedLocalRot,
    translation: null
  });

  // 3. 调用 retargetPose(通过 retargetSingleBoneForTest 封装,calibration=null)
  const retargetResult: RetargetResult = retargetSingleBoneForTest(
    sourceRestPose,
    targetRestPose,
    sourceWorldRestMap,
    animatedPose
  );

  // 4. 获取 target 应用后的局部旋转
  const targetAppliedLocalRot: QuaternionValue = retargetResult.rotations.get(testCase.bone)
    ?? targetRestLocal;

  // 5. 计算相对 Rest 的旋转 = inverse(targetRestLocal) × targetAppliedLocalRot
  const targetRestInverse: QuaternionValue = quaternionInverse(targetRestLocal);
  const targetRelativeRot: QuaternionValue = quaternionNormalize(
    quaternionMultiply(targetRestInverse, targetAppliedLocalRot)
  );
  const targetRelativeAngle: number = quaternionRotationAngleDeg(targetRelativeRot);
  const targetRelativeEuler: number[] = quaternionToEulerDeg(targetRelativeRot);
  const targetAppliedAngle: number = quaternionRotationAngleDeg(targetAppliedLocalRot);

  // 6. 推断语义方向
  const semantic: string = inferSemanticDirection(testCase.bone, targetRelativeEuler);
  const valid: boolean = isAnatomicallyValidDirection(semantic);

  return {
    testCase: testCase,
    sourceDelta: sourceDelta,
    sourceDeltaAngleDeg: sourceDeltaAngle,
    targetAppliedLocalRot: targetAppliedLocalRot,
    targetRestLocalRot: targetRestLocal,
    targetAppliedAngleDeg: targetAppliedAngle,
    targetRelativeAngleDeg: targetRelativeAngle,
    targetRelativeEulerDeg: targetRelativeEuler,
    targetSemanticDirection: semantic,
    isAnatomicallyValid: valid
  };
}

/**
 * T-4.2G-A4B: 单骨骼测试用 retarget 调用封装。
 */
function retargetSingleBoneForTest(
  sourceRestPose: HumanoidRestPose,
  targetRestPose: HumanoidRestPose,
  sourceWorldRestMap: Map<HumanoidBone, QuaternionValue>,
  animatedPose: HumanoidPose
): RetargetResult {
  // calibration = null(单骨骼测试不做方向校准)
  // rootMotionMode = Locked(单骨骼测试不应用 Hips 位移)
  const result: RetargetResult = retargetPose(
    animatedPose,
    sourceRestPose,
    targetRestPose,
    sourceWorldRestMap,
    RootMotionMode.Locked,
    null
  );
  return result;
}

/**
 * T-4.2G-A4B: 批量运行单骨骼轴测试(默认 12 组)。
 *
 * @param sourceRestPose Source Rest Pose
 * @param targetRestPose Target Rest Pose
 * @param sourceWorldRestMap Source 世界 Rest 旋转
 * @param testCases 测试用例数组(默认 12 组)
 * @returns 测试结果数组
 */
export function runSingleBoneAxisTestBatch(
  sourceRestPose: HumanoidRestPose,
  targetRestPose: HumanoidRestPose,
  sourceWorldRestMap: Map<HumanoidBone, QuaternionValue>,
  testCases?: SingleBoneAxisTestCase[]
): SingleBoneAxisTestResult[] {
  const cases: SingleBoneAxisTestCase[] = testCases !== undefined
    ? testCases
    : getDefaultSingleBoneAxisTestCases();
  const results: SingleBoneAxisTestResult[] = [];
  for (let i: number = 0; i < cases.length; i++) {
    const result: SingleBoneAxisTestResult = runSingleBoneAxisTest(
      sourceRestPose, targetRestPose, sourceWorldRestMap, cases[i]
    );
    results.push(result);
  }
  return results;
}

/**
 * T-4.2G-A4B: 输出单骨骼轴测试结果到 hilog。
 */
export function logSingleBoneAxisTestResults(results: SingleBoneAxisTestResult[]): void {
  Logger.info(LOG_TAG, '=== T-4.2G-A4B SingleBoneAxisTest Begin (' + results.length + ' cases) ===');
  for (let i: number = 0; i < results.length; i++) {
    const r: SingleBoneAxisTestResult = results[i];
    const tc: SingleBoneAxisTestCase = r.testCase;
    Logger.info(LOG_TAG, '[' + (i + 1) + '/' + results.length + '] '
      + tc.bone + ' ' + tc.axis + (tc.angleDeg >= 0 ? '+' : '') + tc.angleDeg + 'deg'
      + ' | sourceDelta=' + r.sourceDeltaAngleDeg.toFixed(2) + 'deg'
      + ' | targetApplied=' + r.targetAppliedAngleDeg.toFixed(2) + 'deg'
      + ' | targetRelative=' + r.targetRelativeAngleDeg.toFixed(2) + 'deg'
      + ' | euler=' + fmtEuler(r.targetRelativeEulerDeg)
      + ' | semantic=' + r.targetSemanticDirection
      + ' | valid=' + r.isAnatomicallyValid);
  }
  // 汇总可疑项
  const invalidCount: number = results.filter((r: SingleBoneAxisTestResult): boolean => !r.isAnatomicallyValid).length;
  if (invalidCount > 0) {
    Logger.warn(LOG_TAG, 'SingleBoneAxisTest: ' + invalidCount + ' case(s) need review (see *** 可疑 above)');
  } else {
    Logger.info(LOG_TAG, 'SingleBoneAxisTest: all cases anatomically valid');
  }
  Logger.info(LOG_TAG, '=== T-4.2G-A4B SingleBoneAxisTest End ===');
}

// ==================== Basis 比较 ====================

/**
 * T-4.2G-A4B: 骨骼 Basis(三轴正交基)。
 *
 * 构造方法:
 *   primaryAxis   = normalize(childWorldPos - boneWorldPos)
 *   secondaryAxis = 由父骨骼方向构造(若父骨骼方向与 primary 平行,使用人体 Forward (0,0,1))
 *   thirdAxis     = cross(primary, secondary)
 *
 * 然后重新正交化 secondary = cross(third, primary)
 */
export interface BoneBasis {
  /** 骨骼名 */
  bone: HumanoidBone;
  /** 主轴(指向子骨骼,单位向量) */
  primaryAxis: Vector3Value;
  /** 次轴(由父骨骼方向或 Forward 构造,单位向量) */
  secondaryAxis: Vector3Value;
  /** 第三轴(cross(primary, secondary),单位向量) */
  thirdAxis: Vector3Value;
  /** 行列式(primary × secondary · third,应为 ±1,正=右手系,负=左手系) */
  determinant: number;
  /** handedness: 'Right' 或 'Left' */
  handedness: string;
}

/**
 * T-4.2G-A4B: Source/Target Basis 差异统计。
 */
export interface BasisDifferenceStat {
  /** 骨骼名 */
  bone: HumanoidBone;
  /** Source Basis */
  sourceBasis: BoneBasis;
  /** Target Basis */
  targetBasis: BoneBasis;
  /** primary 轴夹角(度) */
  primaryAxisAngleDeg: number;
  /** secondary 轴夹角(度) */
  secondaryAxisAngleDeg: number;
  /** third 轴夹角(度) */
  thirdAxisAngleDeg: number;
  /** 整体 Basis 差异(度,取三轴平均) */
  averageDifferenceDeg: number;
  /** 左右手系是否一致 */
  handednessMatch: boolean;
}

/**
 * T-4.2G-A4B: 计算两个单位向量之间的夹角(度)。
 */
function angleBetweenVectorsDeg(a: Vector3Value, b: Vector3Value): number {
  const dot: number = vectorDot(a, b);
  const dotClamped: number = Math.max(-1.0, Math.min(1.0, dot));
  return Math.acos(dotClamped) * 180.0 / Math.PI;
}

/**
 * T-4.2G-A4B: 获取骨骼的子骨骼(用于构造 primaryAxis)。
 *
 * 约定:
 *   UpperArm → LowerArm
 *   LowerArm → Hand
 *   其他骨骼返回 null(无法构造 primaryAxis)
 */
function getChildBone(bone: HumanoidBone): HumanoidBone | null {
  if (bone === HumanoidBone.LeftUpperArm) {
    return HumanoidBone.LeftLowerArm;
  }
  if (bone === HumanoidBone.LeftLowerArm) {
    return HumanoidBone.LeftHand;
  }
  if (bone === HumanoidBone.RightUpperArm) {
    return HumanoidBone.RightLowerArm;
  }
  if (bone === HumanoidBone.RightLowerArm) {
    return HumanoidBone.RightHand;
  }
  return null;
}

/**
 * T-4.2G-A4B: 获取骨骼的父骨骼(用于构造 secondaryAxis)。
 *
 * 若父骨骼不存在,使用人体 Forward (0,0,1)。
 */
function getParentBoneForBasis(bone: HumanoidBone): HumanoidBone | null {
  return findParentBone(bone);
}

/**
 * T-4.2G-A4B: 从 PoseSnapshot 中提取指定骨骼的世界位置。
 */
function getWorldPosition(snapshot: PoseSnapshot, bone: HumanoidBone): Vector3Value | null {
  const snap: BoneWorldSnapshot | undefined = snapshot.bones.get(bone);
  return snap !== undefined ? snap.worldPosition : null;
}

/**
 * T-4.2G-A4B: 构造骨骼的 Basis。
 *
 * @param snapshot 姿态快照(Source 或 Target)
 * @param bone 目标骨骼
 * @returns Basis 或 null(若无法构造)
 */
export function computeBoneBasis(snapshot: PoseSnapshot, bone: HumanoidBone): BoneBasis | null {
  const childBone: HumanoidBone | null = getChildBone(bone);
  if (childBone === null) {
    return null;
  }

  const boneWorld: Vector3Value | null = getWorldPosition(snapshot, bone);
  const childWorld: Vector3Value | null = getWorldPosition(snapshot, childBone);
  if (boneWorld === null || childWorld === null) {
    return null;
  }

  // primaryAxis = normalize(childWorld - boneWorld)
  const primaryRaw: Vector3Value = vectorSubtract(childWorld, boneWorld);
  const primary: Vector3Value = vectorNormalize(primaryRaw);
  if (vectorLength(primary) < 1e-6) {
    return null;
  }

  // secondaryAxis:由父骨骼方向构造
  //   parentDir = normalize(boneWorld - parentWorld)
  //   若 parentDir 与 primary 接近平行(夹角 < 5°),使用人体 Forward (0,0,1)
  //   若无父骨骼,使用 Forward (0,0,1)
  let secondaryRaw: Vector3Value = { x: 0, y: 0, z: 1 }; // 默认 Forward
  const parentBone: HumanoidBone | null = getParentBoneForBasis(bone);
  if (parentBone !== null) {
    const parentWorld: Vector3Value | null = getWorldPosition(snapshot, parentBone);
    if (parentWorld !== null) {
      const parentDir: Vector3Value = vectorNormalize(vectorSubtract(boneWorld, parentWorld));
      if (vectorLength(parentDir) > 1e-6) {
        const angleToPrimary: number = angleBetweenVectorsDeg(parentDir, primary);
        if (angleToPrimary > 5.0) {
          secondaryRaw = parentDir;
        }
        // 否则保持默认 Forward
      }
    }
  }

  // 正交化:thirdAxis = cross(primary, secondaryRaw)
  const thirdRaw: Vector3Value = vectorCross(primary, secondaryRaw);
  const third: Vector3Value = vectorNormalize(thirdRaw);
  if (vectorLength(third) < 1e-6) {
    // primary 与 secondaryRaw 平行,尝试用 Up (0,1,0) 替代
    const up: Vector3Value = { x: 0, y: 1, z: 0 };
    const thirdAlt: Vector3Value = vectorCross(primary, up);
    if (vectorLength(thirdAlt) < 1e-6) {
      // primary 也与 Up 平行,使用 Right (1,0,0)
      const right: Vector3Value = { x: 1, y: 0, z: 0 };
      thirdRaw.x = right.x;
      thirdRaw.y = right.y;
      thirdRaw.z = right.z;
    } else {
      thirdRaw.x = thirdAlt.x;
      thirdRaw.y = thirdAlt.y;
      thirdRaw.z = thirdAlt.z;
    }
    const thirdFinal: Vector3Value = vectorNormalize(thirdRaw);
    const secondaryFinal: Vector3Value = vectorNormalize(vectorCross(thirdFinal, primary));
    const det: number = vectorDot(vectorCross(primary, secondaryFinal), thirdFinal);
    return {
      bone: bone,
      primaryAxis: primary,
      secondaryAxis: secondaryFinal,
      thirdAxis: thirdFinal,
      determinant: det,
      handedness: det >= 0 ? 'Right' : 'Left'
    };
  }

  // 重新正交化 secondary = cross(third, primary)
  const secondary: Vector3Value = vectorNormalize(vectorCross(third, primary));

  // 行列式 = (primary × secondary) · third,应为 ±1
  const det: number = vectorDot(vectorCross(primary, secondary), third);

  return {
    bone: bone,
    primaryAxis: primary,
    secondaryAxis: secondary,
    thirdAxis: third,
    determinant: det,
    handedness: det >= 0 ? 'Right' : 'Left'
  };
}

/**
 * T-4.2G-A4B: 比较 Source/Target 的骨骼 Basis 差异。
 *
 * @param sourceRestSnapshot Source Rest Pose 快照
 * @param targetRestSnapshot Target Rest Pose 快照
 * @param bones 待比较的骨骼列表(默认 RightUpperArm/RightLowerArm/LeftUpperArm/LeftLowerArm)
 * @returns Basis 差异统计数组
 */
export function compareBoneBasis(
  sourceRestSnapshot: PoseSnapshot,
  targetRestSnapshot: PoseSnapshot,
  bones?: HumanoidBone[]
): BasisDifferenceStat[] {
  const targetBones: HumanoidBone[] = bones !== undefined
    ? bones
    : [
        HumanoidBone.RightUpperArm,
        HumanoidBone.RightLowerArm,
        HumanoidBone.LeftUpperArm,
        HumanoidBone.LeftLowerArm
      ];

  const stats: BasisDifferenceStat[] = [];
  for (let i: number = 0; i < targetBones.length; i++) {
    const bone: HumanoidBone = targetBones[i];
    const sourceBasis: BoneBasis | null = computeBoneBasis(sourceRestSnapshot, bone);
    const targetBasis: BoneBasis | null = computeBoneBasis(targetRestSnapshot, bone);
    if (sourceBasis === null || targetBasis === null) {
      Logger.warn(LOG_TAG, 'compareBoneBasis: ' + bone + ' basis null (source='
        + (sourceBasis !== null ? 'ok' : 'null')
        + ', target=' + (targetBasis !== null ? 'ok' : 'null') + '), skip');
      continue;
    }

    const primaryAngle: number = angleBetweenVectorsDeg(sourceBasis.primaryAxis, targetBasis.primaryAxis);
    const secondaryAngle: number = angleBetweenVectorsDeg(sourceBasis.secondaryAxis, targetBasis.secondaryAxis);
    const thirdAngle: number = angleBetweenVectorsDeg(sourceBasis.thirdAxis, targetBasis.thirdAxis);
    const avg: number = (primaryAngle + secondaryAngle + thirdAngle) / 3.0;
    const handednessMatch: boolean = sourceBasis.handedness === targetBasis.handedness;

    stats.push({
      bone: bone,
      sourceBasis: sourceBasis,
      targetBasis: targetBasis,
      primaryAxisAngleDeg: primaryAngle,
      secondaryAxisAngleDeg: secondaryAngle,
      thirdAxisAngleDeg: thirdAngle,
      averageDifferenceDeg: avg,
      handednessMatch: handednessMatch
    });
  }
  return stats;
}

/**
 * T-4.2G-A4B: 输出 Basis 比较结果到 hilog。
 */
export function logBasisDifference(stats: BasisDifferenceStat[]): void {
  Logger.info(LOG_TAG, '=== T-4.2G-A4B BasisDifference Begin (' + stats.length + ' bones) ===');
  for (let i: number = 0; i < stats.length; i++) {
    const s: BasisDifferenceStat = stats[i];
    Logger.info(LOG_TAG, '[' + s.bone + ']'
      + ' primary=' + s.primaryAxisAngleDeg.toFixed(2) + 'deg'
      + ' secondary=' + s.secondaryAxisAngleDeg.toFixed(2) + 'deg'
      + ' third=' + s.thirdAxisAngleDeg.toFixed(2) + 'deg'
      + ' avg=' + s.averageDifferenceDeg.toFixed(2) + 'deg'
      + ' handedness=' + (s.handednessMatch ? 'match' : 'MISMATCH')
      + ' | source{primary=' + fmtVec3Short(s.sourceBasis.primaryAxis)
      + ',det=' + s.sourceBasis.determinant.toFixed(3)
      + '(' + s.sourceBasis.handedness + ')}'
      + ' | target{primary=' + fmtVec3Short(s.targetBasis.primaryAxis)
      + ',det=' + s.targetBasis.determinant.toFixed(3)
      + '(' + s.targetBasis.handedness + ')}');
  }
  // 汇总可疑项
  const significantCount: number = stats.filter(
    (s: BasisDifferenceStat): boolean => s.averageDifferenceDeg > 5.0 || !s.handednessMatch
  ).length;
  if (significantCount > 0) {
    Logger.warn(LOG_TAG, 'BasisDifference: ' + significantCount
      + ' bone(s) have significant difference (>5deg or handedness mismatch)'
      + ' → worldDelta alone may NOT be sufficient, per-bone Basis Correction may be needed');
  } else {
    Logger.info(LOG_TAG, 'BasisDifference: all bones within 5deg and handedness match'
      + ' → worldDelta is sufficient, no per-bone Basis Correction needed');
  }
  Logger.info(LOG_TAG, '=== T-4.2G-A4B BasisDifference End ===');
}

/**
 * T-4.2G-A4B: 格式化向量(短格式,3 位小数)。
 */
function fmtVec3Short(v: Vector3Value): string {
  return '(' + v.x.toFixed(3) + ',' + v.y.toFixed(3) + ',' + v.z.toFixed(3) + ')';
}

/**
 * T-4.2G-A4B: 完整单骨骼轴测试 + Basis 比较诊断。
 *
 * 一次性输出:
 *   1. 12 组单骨骼轴测试结果(RightUpperArm ±30°, RightLowerArm ±45°)
 *   2. 4 根手臂骨骼的 Source/Target Basis 差异
 *
 * @param sourceRestPose Source Rest Pose
 * @param targetRestPose Target Rest Pose
 */
export function runFullBasisAndAxisDiagnostic(
  sourceRestPose: HumanoidRestPose,
  targetRestPose: HumanoidRestPose
): void {
  Logger.info(LOG_TAG, '=== T-4.2G-A4B FullBasisAndAxisDiagnostic Start ===');

  // 1. 计算 Source 世界 Rest 旋转
  const sourceWorldRestMap: Map<HumanoidBone, QuaternionValue> = computeWorldRestRotations(sourceRestPose);

  // 2. 运行 12 组单骨骼轴测试
  Logger.info(LOG_TAG, '--- SingleBoneAxisTest (12 cases) ---');
  const testResults: SingleBoneAxisTestResult[] = runSingleBoneAxisTestBatch(
    sourceRestPose, targetRestPose, sourceWorldRestMap
  );
  logSingleBoneAxisTestResults(testResults);

  // 3. 计算 Source/Target Rest Pose 快照(用于 Basis 比较)
  Logger.info(LOG_TAG, '--- BasisDifference (4 arm bones) ---');
  const sourceRestSnap: PoseSnapshot = computeRestPoseWorldSnapshot(sourceRestPose, 'SourceRest');
  const targetRestSnap: PoseSnapshot = computeRestPoseWorldSnapshot(targetRestPose, 'TargetRest');
  const basisStats: BasisDifferenceStat[] = compareBoneBasis(sourceRestSnap, targetRestSnap);
  logBasisDifference(basisStats);

  Logger.info(LOG_TAG, '=== T-4.2G-A4B FullBasisAndAxisDiagnostic End ===');
}
