/**
 * TargetRestPoseCollector 目标 Rest Pose 收集器
 *
 * T-4.2E: 从 Avatar SceneNode 提取目标 VRM 骨架的 Rest Pose。
 *
 * 职责:
 * - 使用 HumanoidProvider 获取每根标准骨骼的 nodeIndex
 * - 通过 SceneNodeCollector 的 nodeIndexMap 找到对应的 SceneNode
 * - 读取 SceneNode 的 position/rotation/scale 作为 Rest Pose
 *
 * Rest Pose 来源:
 * - 优先使用 Avatar GLB nodes 默认 TRS(已在 SceneNodeCollector 中建立映射)
 * - 不能使用动画第 0 帧(除非确认第 0 帧就是 Rest Pose)
 *
 * 不依赖 ArkGraphics3D Animation,只读取 SceneNode 的静态属性。
 */

import { Node, Position3, Quaternion } from '@kit.ArkGraphics3D';
import { HumanoidProvider, HumanoidBoneQueryResult } from './HumanoidProvider';
import { findNodeByIndex } from './SceneNodeCollector';
import {
  HumanoidRestPose,
  BoneRestTransform,
  QuaternionValue,
  Vector3Value,
  createEmptyRestPose,
  identityQuaternionValue,
  zeroVector3Value,
  oneVector3Value
} from '../models/character3d/HumanoidMotionClip';
import { HumanoidBone, ALL_STANDARD_BONES } from '../models/character3d/HumanoidBone';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'TargetRestPoseCollector';

/**
 * Rest Pose 收集结果。
 */
export interface TargetRestPoseCollectResult {
  /** 是否成功 */
  success: boolean;
  /** 错误信息 */
  errorMessage: string;
  /** 目标 Rest Pose */
  restPose: HumanoidRestPose;
  /** bone → SceneNode 映射(用于播放时写入) */
  boneNodeMap: Map<HumanoidBone, Node>;
  /** 已收集骨骼数 */
  collectedCount: number;
  /** 缺失骨骼列表 */
  missingBones: HumanoidBone[];
  /** 缺失必需骨骼列表 */
  missingRequired: HumanoidBone[];
}

/**
 * 从 Avatar SceneNode 收集目标 Rest Pose。
 *
 * @param provider HumanoidProvider(来自 VRM 显式映射)
 * @param nodeIndexMap nodeIndex → SceneNode 映射(来自 SceneNodeCollector)
 * @returns 收集结果
 */
export function collectTargetRestPose(
  provider: HumanoidProvider,
  nodeIndexMap: Map<number, Node>
): TargetRestPoseCollectResult {
  const restPose: HumanoidRestPose = createEmptyRestPose();
  const boneNodeMap: Map<HumanoidBone, Node> = new Map<HumanoidBone, Node>();
  const missingBones: HumanoidBone[] = [];
  const missingRequired: HumanoidBone[] = [];
  let collectedCount: number = 0;
  let hipsY: number = 0;
  let maxY: number = 0;

  for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
    const bone: HumanoidBone = ALL_STANDARD_BONES[i];
    const query: HumanoidBoneQueryResult = provider.getBone(bone);
    if (!query.mapped || query.nodeIndex < 0) {
      missingBones.push(bone);
      if (isRequiredBone(bone)) {
        missingRequired.push(bone);
      }
      continue;
    }

    const sceneNode: Node | null = findNodeByIndex(nodeIndexMap, query.nodeIndex);
    if (sceneNode === null) {
      missingBones.push(bone);
      if (isRequiredBone(bone)) {
        missingRequired.push(bone);
      }
      continue;
    }

    // 读取 SceneNode 的 TRS
    const transform: BoneRestTransform = readNodeTransform(sceneNode);
    restPose.bones.set(bone, transform);
    boneNodeMap.set(bone, sceneNode);
    collectedCount++;

    if (bone === HumanoidBone.Hips) {
      hipsY = transform.localPosition.y;
    }
    if (transform.localPosition.y > maxY) {
      maxY = transform.localPosition.y;
    }
  }

  // 估算 modelHeight:Hips 到 Head 的距离 + 头部约 0.2m
  const hipsRest: BoneRestTransform | undefined = restPose.bones.get(HumanoidBone.Hips);
  const headRest: BoneRestTransform | undefined = restPose.bones.get(HumanoidBone.Head);
  if (hipsRest !== undefined && headRest !== undefined) {
    // 注意:这是 local translation,不是 world,只是粗略估算
    // 改进:遍历父链累加 world Y
    restPose.modelHeight = estimateModelHeight(restPose);
  } else {
    restPose.modelHeight = 1.4; // 默认身高
  }
  restPose.hipsHeight = hipsY;

  Logger.info(LOG_TAG, 'collectTargetRestPose: collected=' + collectedCount
    + ', missing=' + missingBones.length
    + ', missingRequired=' + missingRequired.length
    + ', hipsY=' + hipsY.toFixed(3)
    + ', modelHeight=' + restPose.modelHeight.toFixed(3));

  return {
    success: true,
    errorMessage: '',
    restPose: restPose,
    boneNodeMap: boneNodeMap,
    collectedCount: collectedCount,
    missingBones: missingBones,
    missingRequired: missingRequired
  };
}

/**
 * 读取 SceneNode 的 TRS 变换。
 */
function readNodeTransform(node: Node): BoneRestTransform {
  let pos: Vector3Value = zeroVector3Value();
  let rot: QuaternionValue = identityQuaternionValue();
  let scl: Vector3Value = oneVector3Value();

  try {
    const p: Position3 = node.position;
    pos = { x: p.x, y: p.y, z: p.z };
  } catch (_e) {
    // 保持默认
  }
  try {
    const q: Quaternion = node.rotation;
    rot = { x: q.x, y: q.y, z: q.z, w: q.w };
  } catch (_e) {
    // 保持默认
  }
  try {
    const s: Position3 = node.scale;
    scl = { x: s.x, y: s.y, z: s.z };
  } catch (_e) {
    // 保持默认
  }

  return {
    localPosition: pos,
    localRotation: rot,
    localScale: scl
  };
}

/**
 * 判断是否必需骨骼。
 */
function isRequiredBone(bone: HumanoidBone): boolean {
  // 必需骨骼列表(来自 HumanoidBone.REQUIRED_BONES)
  // 这里硬编码以避免循环依赖
  return bone === HumanoidBone.Hips
    || bone === HumanoidBone.Spine
    || bone === HumanoidBone.Head
    || bone === HumanoidBone.LeftUpperLeg
    || bone === HumanoidBone.RightUpperLeg
    || bone === HumanoidBone.LeftFoot
    || bone === HumanoidBone.RightFoot;
}

/**
 * 估算模型身高(Hips 到 Head 距离 + 头部 0.2m)。
 *
 * 简化版:由于 local translation 不能直接累加,这里用粗略估算。
 * 实际身高在 VRM 模型中通常已知,可从 VRM meta 读取。
 */
function estimateModelHeight(restPose: HumanoidRestPose): number {
  const hips: BoneRestTransform | undefined = restPose.bones.get(HumanoidBone.Hips);
  const head: BoneRestTransform | undefined = restPose.bones.get(HumanoidBone.Head);
  if (hips === undefined || head === undefined) {
    return 1.4;
  }
  // 粗略:Hips Y + 累加 spine/chest/neck/head 的 Y
  // 由于没有遍历父链,直接用 head.y - hips.y 作近似
  const diff: number = head.localPosition.y - hips.localPosition.y;
  if (diff > 0.5 && diff < 3.0) {
    return diff + 0.2; // 加上头部高度
  }
  return 1.4;
}
