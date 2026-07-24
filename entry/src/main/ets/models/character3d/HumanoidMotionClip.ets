/**
 * HumanoidMotionClip 人形动作中间格式
 *
 * T-4.2E: 从 GLB 动画解析出的标准骨骼关键帧数据。
 *
 * 设计目标:
 * - 与源模型节点名/索引解耦,只保留 HumanoidBone 标识
 * - 运行时重定向只依赖 HumanoidBone,不依赖 J_Bip_R_UpperArm 等源模型专属名
 * - 纯数据结构,不依赖 ArkGraphics3D / ArkUI,可单元测试
 *
 * 数据流:
 *   GLB animation channel
 *   → source node name
 *   → HumanoidBone(通过名称直接映射或 HumanoidBoneMapper)
 *   → HumanoidBoneTrack(保留 sourceNodeIndex/Name 用于调试)
 *
 * 运行时:
 *   HumanoidMotionSampler.sample(clip, time) → HumanoidPose
 *   → HumanoidRetargetor.retarget(sourcePose, sourceRest, targetRest)
 *   → 写入目标 SceneNode.rotation/position
 */

import { HumanoidBone } from './HumanoidBone';

/**
 * 四元数值 {x, y, z, w}。
 * 独立于 ArkGraphics3D 的 Quaternion,便于纯逻辑测试。
 */
export interface QuaternionValue {
  x: number;
  y: number;
  z: number;
  w: number;
}

/**
 * 三维向量值。
 * 独立于 ArkGraphics3D 的 Position3,便于纯逻辑测试。
 */
export interface Vector3Value {
  x: number;
  y: number;
  z: number;
}

/**
 * 旋转关键帧(四元数)。
 */
export interface QuaternionKeyframe {
  /** 时间(秒) */
  time: number;
  /** 旋转值(四元数) */
  value: QuaternionValue;
}

/**
 * 位移关键帧(三维向量)。
 */
export interface Vector3Keyframe {
  /** 时间(秒) */
  time: number;
  /** 位移值 */
  value: Vector3Value;
}

/**
 * 单根骨骼的动画轨道。
 *
 * 一根骨骼可能包含 rotation/translation/scale 三种轨道,
 * 每种轨道的关键帧数量和时间点可能不同(glTF 规范允许)。
 */
export interface HumanoidBoneTrack {
  /** 目标标准骨骼 */
  bone: HumanoidBone;
  /** 源节点索引(glTF nodeIndex,用于调试) */
  sourceNodeIndex: number;
  /** 源节点名(用于调试和映射验证) */
  sourceNodeName: string;
  /** 旋转关键帧(可能为空数组) */
  rotationKeys: QuaternionKeyframe[];
  /** 位移关键帧(可能为空数组) */
  translationKeys: Vector3Keyframe[];
  /** 缩放关键帧(本轮不使用,仅保留) */
  scaleKeys: Vector3Keyframe[];
  /** 旋转插值类型 */
  rotationInterpolation: AnimationInterpolation;
  /** 位移插值类型 */
  translationInterpolation: AnimationInterpolation;
}

/**
 * 插值类型。
 */
export enum AnimationInterpolation {
  /** 线性插值 */
  Linear = 'LINEAR',
  /** 阶跃插值(保持前一个关键帧值) */
  Step = 'STEP',
  /** 三次样条插值(本轮暂不支持,遇到则报错) */
  CubicSpline = 'CUBICSPLINE'
}

/**
 * 动作中间格式 Clip。
 */
export interface HumanoidMotionClip {
  /** Clip 唯一标识(通常为 actionId) */
  id: string;
  /** Clip 名称(如 AT_Wave) */
  name: string;
  /** 时长(秒) */
  durationSeconds: number;
  /** 是否循环 */
  loop: boolean;
  /** 所有骨骼轨道 */
  tracks: HumanoidBoneTrack[];
  /** 源骨架哈希(用于缓存和映射验证) */
  sourceSkeletonHash: string;
  /** 源模型身高(用于 Hips 位移缩放) */
  sourceHeight: number;
  /** 解析过程中的警告信息 */
  warnings: string[];
}

/**
 * 单根骨骼的 Rest Pose 变换。
 */
export interface BoneRestTransform {
  /** 局部位移 */
  localPosition: Vector3Value;
  /** 局部旋转 */
  localRotation: QuaternionValue;
  /** 局部缩放 */
  localScale: Vector3Value;
}

/**
 * Humanoid Rest Pose。
 *
 * 保存每根骨骼在动作应用前的局部变换。
 * 停止动作时用于恢复,避免姿态污染。
 */
export interface HumanoidRestPose {
  /** bone → rest transform */
  bones: Map<HumanoidBone, BoneRestTransform>;
  /** Hips 高度(Y 分量,用于身高缩放) */
  hipsHeight: number;
  /** 模型总高度(头顶到脚底) */
  modelHeight: number;
}

/**
 * 采样后的单根骨骼姿态。
 */
export interface BonePose {
  /** 骨骼标识 */
  bone: HumanoidBone;
  /** 采样得到的局部旋转(无动画时为 null) */
  rotation: QuaternionValue | null;
  /** 采样得到的局部位移(无动画时为 null) */
  translation: Vector3Value | null;
}

/**
 * 采样后的完整姿态(所有骨骼)。
 */
export interface HumanoidPose {
  /** bone → pose */
  bones: Map<HumanoidBone, BonePose>;
}

/**
 * Hips 位移处理模式。
 */
export enum RootMotionMode {
  /** 锁定 Hips 位移(不应用动画位移) */
  Locked = 'Locked',
  /** 仅应用 Hips 位移(按身高缩放) */
  HipsOnly = 'HipsOnly',
  /** 完全应用 Hips 位移 */
  Full = 'Full'
}

/**
 * 创建空的 HumanoidPose。
 */
export function createEmptyPose(): HumanoidPose {
  return { bones: new Map<HumanoidBone, BonePose>() };
}

/**
 * 创建空的 HumanoidRestPose。
 */
export function createEmptyRestPose(): HumanoidRestPose {
  return {
    bones: new Map<HumanoidBone, BoneRestTransform>(),
    hipsHeight: 0,
    modelHeight: 0
  };
}

/**
 * 创建单位四元数值。
 */
export function identityQuaternionValue(): QuaternionValue {
  return { x: 0, y: 0, z: 0, w: 1 };
}

/**
 * 创建零向量值。
 */
export function zeroVector3Value(): Vector3Value {
  return { x: 0, y: 0, z: 0 };
}

/**
 * 创建单位缩放向量值。
 */
export function oneVector3Value(): Vector3Value {
  return { x: 1, y: 1, z: 1 };
}
