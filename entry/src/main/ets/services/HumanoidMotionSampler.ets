/**
 * HumanoidMotionSampler CPU 动画采样器
 *
 * T-4.2E: 在 CPU 上对 HumanoidMotionClip 进行时间采样。
 *
 * 职责:
 * - 给定 clip 和 timeSeconds,返回所有骨骼的采样姿态
 * - 旋转:Quaternion SLERP
 * - 位移:Vector3 线性插值
 * - STEP:保持前一个关键帧值
 * - 时间处理:loop=time%duration,once=clamp(0,duration)
 *
 * 边界情况:
 * - 0 个关键帧:返回 null(无动画)
 * - 1 个关键帧:返回该帧值
 * - time < 第一个关键帧:返回第一个关键帧值
 * - time > 最后一个关键帧:返回最后一个关键帧值
 * - 重复时间:取第一个匹配
 * - 非法 quaternion:归一化,若仍非法返回 identity
 *
 * 不依赖 ArkGraphics3D / ArkUI,纯逻辑可单元测试。
 */

import {
  HumanoidMotionClip,
  HumanoidBoneTrack,
  QuaternionKeyframe,
  Vector3Keyframe,
  HumanoidPose,
  BonePose,
  AnimationInterpolation,
  QuaternionValue,
  Vector3Value,
  createEmptyPose,
  identityQuaternionValue,
  zeroVector3Value
} from '../models/character3d/HumanoidMotionClip';
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import {
  quaternionSlerp,
  quaternionNormalize,
  quaternionIsValid
} from '../utils/QuaternionUtil';

/**
 * 关键帧区间查找结果。
 */
interface KeyframeInterval {
  /** 前一个关键帧索引 */
  k0: number;
  /** 后一个关键帧索引 */
  k1: number;
  /** 插值参数 [0,1] */
  t: number;
}

/**
 * 采样 clip 在指定时间的姿态。
 *
 * @param clip 动作 clip
 * @param timeSeconds 时间(秒)
 * @returns 采样姿态;clip 为 null 时返回空姿态
 */
export function sampleMotionClip(
  clip: HumanoidMotionClip | null,
  timeSeconds: number
): HumanoidPose {
  const pose: HumanoidPose = createEmptyPose();
  if (clip === null) {
    return pose;
  }

  // 时间处理
  let t: number = timeSeconds;
  const duration: number = clip.durationSeconds;
  if (duration <= 0) {
    // 时长为 0,直接返回第一帧
    t = 0;
  } else if (clip.loop) {
    t = timeSeconds % duration;
    if (t < 0) {
      t += duration;
    }
  } else {
    // once: clamp
    if (t < 0) {
      t = 0;
    } else if (t > duration) {
      t = duration;
    }
  }

  // 对每根骨骼采样
  for (let i: number = 0; i < clip.tracks.length; i++) {
    const track: HumanoidBoneTrack = clip.tracks[i];
    const rotation: QuaternionValue | null = sampleRotation(track, t);
    const translation: Vector3Value | null = sampleTranslation(track, t);
    const bonePose: BonePose = {
      bone: track.bone,
      rotation: rotation,
      translation: translation
    };
    pose.bones.set(track.bone, bonePose);
  }

  return pose;
}

/**
 * 采样旋转轨道。
 */
function sampleRotation(track: HumanoidBoneTrack, time: number): QuaternionValue | null {
  const keys: QuaternionKeyframe[] = track.rotationKeys;
  if (keys.length === 0) {
    return null;
  }
  if (keys.length === 1) {
    return sanitizeQuaternion(keys[0].value);
  }

  // 找到 time 所在的关键帧区间
  const interval: KeyframeInterval = findKeyframeInterval(keys, time);

  if (track.rotationInterpolation === AnimationInterpolation.Step) {
    // STEP:保持前一个关键帧值
    return sanitizeQuaternion(keys[interval.k0].value);
  }

  // LINEAR:SLERP
  if (interval.k0 === interval.k1) {
    return sanitizeQuaternion(keys[interval.k0].value);
  }
  const q0: QuaternionValue = keys[interval.k0].value;
  const q1: QuaternionValue = keys[interval.k1].value;
  const result: QuaternionValue = quaternionSlerp(q0, q1, interval.t);
  return sanitizeQuaternion(result);
}

/**
 * 采样位移轨道。
 */
function sampleTranslation(track: HumanoidBoneTrack, time: number): Vector3Value | null {
  const keys: Vector3Keyframe[] = track.translationKeys;
  if (keys.length === 0) {
    return null;
  }
  if (keys.length === 1) {
    return { x: keys[0].value.x, y: keys[0].value.y, z: keys[0].value.z };
  }

  const interval: KeyframeInterval = findKeyframeIntervalVec3(keys, time);

  if (track.translationInterpolation === AnimationInterpolation.Step) {
    return { x: keys[interval.k0].value.x, y: keys[interval.k0].value.y, z: keys[interval.k0].value.z };
  }

  // LINEAR:lerp
  if (interval.k0 === interval.k1) {
    return { x: keys[interval.k0].value.x, y: keys[interval.k0].value.y, z: keys[interval.k0].value.z };
  }
  const v0: Vector3Value = keys[interval.k0].value;
  const v1: Vector3Value = keys[interval.k1].value;
  return {
    x: v0.x + interval.t * (v1.x - v0.x),
    y: v0.y + interval.t * (v1.y - v0.y),
    z: v0.z + interval.t * (v1.z - v0.z)
  };
}

/**
 * 在四元数关键帧数组中找到 time 所在的区间。
 *
 * @returns KeyframeInterval { k0, k1, t } 其中 t 是 [0,1] 的插值参数
 */
function findKeyframeInterval(
  keys: QuaternionKeyframe[],
  time: number
): KeyframeInterval {
  // time <= 第一个关键帧
  if (time <= keys[0].time) {
    return { k0: 0, k1: 0, t: 0 };
  }
  // time >= 最后一个关键帧
  const last: number = keys.length - 1;
  if (time >= keys[last].time) {
    return { k0: last, k1: last, t: 0 };
  }
  // 二分查找
  let low: number = 0;
  let high: number = last;
  while (low < high - 1) {
    const mid: number = Math.floor((low + high) / 2);
    if (keys[mid].time <= time) {
      low = mid;
    } else {
      high = mid;
    }
  }
  // keys[low].time <= time < keys[high].time
  const t0: number = keys[low].time;
  const t1: number = keys[high].time;
  const span: number = t1 - t0;
  const t: number = span > 0 ? (time - t0) / span : 0;
  return { k0: low, k1: high, t: Math.max(0, Math.min(1, t)) };
}

/**
 * 在 Vector3 关键帧数组中找到 time 所在的区间。
 */
function findKeyframeIntervalVec3(
  keys: Vector3Keyframe[],
  time: number
): KeyframeInterval {
  if (time <= keys[0].time) {
    return { k0: 0, k1: 0, t: 0 };
  }
  const last: number = keys.length - 1;
  if (time >= keys[last].time) {
    return { k0: last, k1: last, t: 0 };
  }
  let low: number = 0;
  let high: number = last;
  while (low < high - 1) {
    const mid: number = Math.floor((low + high) / 2);
    if (keys[mid].time <= time) {
      low = mid;
    } else {
      high = mid;
    }
  }
  const t0: number = keys[low].time;
  const t1: number = keys[high].time;
  const span: number = t1 - t0;
  const t: number = span > 0 ? (time - t0) / span : 0;
  return { k0: low, k1: high, t: Math.max(0, Math.min(1, t)) };
}

/**
 * 清洗四元数:归一化,非法时返回 identity。
 */
function sanitizeQuaternion(q: QuaternionValue): QuaternionValue {
  if (!quaternionIsValid(q)) {
    // 尝试归一化
    const normalized: QuaternionValue = quaternionNormalize(q);
    if (quaternionIsValid(normalized)) {
      return normalized;
    }
    return identityQuaternionValue();
  }
  return { x: q.x, y: q.y, z: q.z, w: q.w };
}
