/**
 * VrmBoneKeyParser VRM 骨骼键统一转换
 *
 * T-4.1 A5: 统一骨骼键转换。
 *
 * VRM humanBones 的 key 是 lowerCamelCase 标准骨骼名(如 "leftUpperArm"),
 * 本函数将其映射到内部 HumanoidBone 枚举。
 *
 * 规则:
 * - trim 空白
 * - 大小写规范化(lowerCamelCase)
 * - 明确键表,不支持模糊 includes
 * - 未知键返回 null
 *
 * VRM 0.x 和 1.0 使用相同的骨骼键名(lowerCamelCase)。
 */

import { HumanoidBone } from '../models/character3d/HumanoidBone';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'VrmBoneKeyParser';

/**
 * VRM 骨骼键 → HumanoidBone 映射表。
 *
 * VRM 0.x 和 1.0 均使用 lowerCamelCase 键名。
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/spec/core/#humanoid.humanBones
 * - VRM 0.x: https://vrm.dev/vrm0/unihumanoid.html
 */
const VRM_BONE_KEY_MAP: Map<string, HumanoidBone> = buildVrmBoneKeyMap();

function buildVrmBoneKeyMap(): Map<string, HumanoidBone> {
  const m: Map<string, HumanoidBone> = new Map();
  // 核心骨骼
  m.set('hips', HumanoidBone.Hips);
  m.set('spine', HumanoidBone.Spine);
  m.set('chest', HumanoidBone.Chest);
  m.set('upperchest', HumanoidBone.UpperChest);
  m.set('neck', HumanoidBone.Neck);
  m.set('head', HumanoidBone.Head);
  // 左臂
  m.set('leftshoulder', HumanoidBone.LeftShoulder);
  m.set('leftupperarm', HumanoidBone.LeftUpperArm);
  m.set('leftlowerarm', HumanoidBone.LeftLowerArm);
  m.set('lefthand', HumanoidBone.LeftHand);
  // 右臂
  m.set('rightshoulder', HumanoidBone.RightShoulder);
  m.set('rightupperarm', HumanoidBone.RightUpperArm);
  m.set('rightlowerarm', HumanoidBone.RightLowerArm);
  m.set('righthand', HumanoidBone.RightHand);
  // 左腿
  m.set('leftupperleg', HumanoidBone.LeftUpperLeg);
  m.set('leftlowerleg', HumanoidBone.LeftLowerLeg);
  m.set('leftfoot', HumanoidBone.LeftFoot);
  m.set('lefttoes', HumanoidBone.LeftToes);
  // 右腿
  m.set('rightupperleg', HumanoidBone.RightUpperLeg);
  m.set('rightlowerleg', HumanoidBone.RightLowerLeg);
  m.set('rightfoot', HumanoidBone.RightFoot);
  m.set('righttoes', HumanoidBone.RightToes);
  // 头部
  m.set('lefteye', HumanoidBone.LeftEye);
  m.set('righteye', HumanoidBone.RightEye);
  m.set('jaw', HumanoidBone.Jaw);
  return m;
}

/**
 * 将 VRM 骨骼键转换为 HumanoidBone 枚举。
 *
 * 处理步骤:
 * 1. trim 空白
 * 2. 转小写
 * 3. 查表
 *
 * @param key VRM 骨骼键(如 "leftUpperArm", "hips", "LeftUpperArm")
 * @returns HumanoidBone 枚举,未知键返回 null
 */
export function parseVrmHumanoidBoneKey(key: string): HumanoidBone | null {
  if (key.length === 0) {
    return null;
  }
  // trim + 小写规范化
  const normalized: string = key.trim().toLowerCase();
  const bone: HumanoidBone | undefined = VRM_BONE_KEY_MAP.get(normalized);
  if (bone === undefined) {
    Logger.warn(LOG_TAG, 'unknown VRM bone key: ' + key);
    return null;
  }
  return bone;
}

/**
 * 判断 VRM 骨骼键是否为标准(非扩展)骨骼。
 *
 * 扩展骨骼(手指等)不在 HumanoidBone 枚举中,仅记录不进入标准映射。
 *
 * @param key VRM 骨骼键
 * @returns true 表示是标准骨骼
 */
export function isStandardVrmBoneKey(key: string): boolean {
  if (key.length === 0) {
    return false;
  }
  const normalized: string = key.trim().toLowerCase();
  return VRM_BONE_KEY_MAP.has(normalized);
}
