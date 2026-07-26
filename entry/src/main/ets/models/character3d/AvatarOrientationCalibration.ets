/**
 * AvatarOrientationCalibration Avatar 方向校准领域模型
 *
 * T-4.2G: 为每个 Avatar 提供方向校准数据结构,支持:
 * - 自动检测(Root Facing / Forward Inversion / Left-Right Mirroring)
 * - 手动覆盖(Auto / Normal / RotateY180 / MirrorLeftRight / MirrorLeftRightAndRotateY180 / Custom)
 * - 持久化(按 avatarId 隔离)
 *
 * 数据流:
 *   AvatarOrientationAnalyzer.analyze(sourceRest, targetRest)
 *   → AvatarOrientationAnalysis(selectedMode, confidence, candidateScores)
 *   → 用户手动覆盖
 *   → AvatarOrientationCalibration(持久化)
 *   → 注入 HumanoidRetargetor 作为 Alignment Transform
 *
 * 不依赖 ArkUI / ArkGraphics3D,纯逻辑可单元测试。
 */

import { HumanoidBone } from './HumanoidBone';
import { QuaternionValue } from './HumanoidMotionClip';

/**
 * 方向校准模式。
 */
export enum AvatarOrientationMode {
  /** 自动检测(运行时由 Analyzer 决定) */
  Auto = 'Auto',
  /** 正常无校正 */
  Normal = 'Normal',
  /** 根节点 Y 轴旋转 180°(模型背对镜头) */
  RotateY180 = 'RotateY180',
  /** 左右镜像(交换左右骨骼映射 + 镜像旋转) */
  MirrorLeftRight = 'MirrorLeftRight',
  /** 左右镜像 + Y 轴旋转 180° */
  MirrorLeftRightAndRotateY180 = 'MirrorLeftRightAndRotateY180',
  /** 自定义(用户手动设置 yawOffset / swapLeftRight / invertForward) */
  Custom = 'Custom'
}

/**
 * 自动检测置信度。
 */
export enum OrientationConfidence {
  /** 高置信度(>0.8) */
  High = 'High',
  /** 中等置信度(0.5~0.8) */
  Medium = 'Medium',
  /** 低置信度(<0.5) */
  Low = 'Low',
  /** 未知(无法分析) */
  Unknown = 'Unknown'
}

/**
 * 候选模式评分。
 */
export interface OrientationCandidateScore {
  /** 候选模式 */
  mode: AvatarOrientationMode;
  /** 综合评分(0.0~1.0) */
  score: number;
  /** 评分理由码 */
  reasonCode: string;
}

/**
 * 自动分析结果。
 */
export interface AvatarOrientationAnalysis {
  /** 选中的模式 */
  selectedMode: AvatarOrientationMode;
  /** 置信度 */
  confidence: OrientationConfidence;
  /** 所有候选评分 */
  candidateScores: OrientationCandidateScore[];
  /** 综合理由码 */
  reasonCode: string;
  /** 估算的 Yaw 偏移(度,-180~180) */
  yawOffsetDeg: number;
  /** 是否需要左右镜像 */
  swapLeftRight: boolean;
  /** 是否需要反转 Forward */
  invertForward: boolean;
}

/**
 * 持久化的方向校准数据。
 */
export interface AvatarOrientationCalibration {
  /** Avatar ID(UUID v4) */
  avatarId: string;
  /** 模型文件 SHA-256(用于失效判断) */
  sourceSha256: string;
  /** 校准模式 */
  mode: AvatarOrientationMode;
  /** 自动检测到的模式(mode=Auto 或 Manual override 时参考) */
  autoDetectedMode: AvatarOrientationMode;
  /** 自动检测置信度 */
  autoConfidence: OrientationConfidence;
  /** Yaw 偏移(度,-180~180) */
  yawOffsetDeg: number;
  /** 是否交换左右骨骼 */
  swapLeftRight: boolean;
  /** 是否反转 Forward */
  invertForward: boolean;
  /** 自动检测理由码(简短描述) */
  autoReasonCode: string;
  /** 是否为手动覆盖(mode !== Auto) */
  isManualOverride: boolean;
  /** 最后更新时间(毫秒时间戳) */
  updatedAt: number;
}

/**
 * 序列化用的 JSON 结构(Plain Object,避免 ArkTS 的 arkts-no-untyped-obj-literals 限制)。
 */
interface CalibrationJson {
  avatarId: string;
  sourceSha256: string;
  mode: string;
  autoDetectedMode: string;
  autoConfidence: string;
  yawOffsetDeg: number;
  swapLeftRight: boolean;
  invertForward: boolean;
  autoReasonCode: string;
  isManualOverride: boolean;
  updatedAt: number;
}

/**
 * 创建默认校准(Normal 模式,无校正)。
 */
export function createDefaultCalibration(
  avatarId: string,
  sourceSha256: string
): AvatarOrientationCalibration {
  return {
    avatarId: avatarId,
    sourceSha256: sourceSha256,
    mode: AvatarOrientationMode.Auto,
    autoDetectedMode: AvatarOrientationMode.Normal,
    autoConfidence: OrientationConfidence.Unknown,
    yawOffsetDeg: 0,
    swapLeftRight: false,
    invertForward: false,
    autoReasonCode: 'default',
    isManualOverride: false,
    updatedAt: Date.now()
  };
}

/**
 * 判断模式是否需要 Yaw 180° 旋转。
 */
export function modeNeedsRotateY180(mode: AvatarOrientationMode): boolean {
  return mode === AvatarOrientationMode.RotateY180
    || mode === AvatarOrientationMode.MirrorLeftRightAndRotateY180;
}

/**
 * 判断模式是否需要左右镜像。
 */
export function modeNeedsMirrorLeftRight(mode: AvatarOrientationMode): boolean {
  return mode === AvatarOrientationMode.MirrorLeftRight
    || mode === AvatarOrientationMode.MirrorLeftRightAndRotateY180;
}

/**
 * 实际生效的校准参数(将 Auto/Custom 等模式解析为具体 yaw/swap/invert)。
 */
export interface EffectiveCalibrationParams {
  /** Yaw 偏移角度(度) */
  yawOffsetDeg: number;
  /** 是否交换左右骨骼 */
  swapLeftRight: boolean;
  /** 是否反转 Forward */
  invertForward: boolean;
}

/**
 * 解析实际生效的校准参数(将 Auto/Custom 等模式解析为具体 yaw/swap/invert)。
 *
 * 优先级:
 * 1. Manual Override(mode !== Auto):使用用户设置的 yaw/swap/invert
 * 2. Auto 模式:使用 autoDetectedMode 对应的默认值
 *
 * @param calibration 校准数据
 * @returns EffectiveCalibrationParams
 */
export function resolveEffectiveCalibration(
  calibration: AvatarOrientationCalibration
): EffectiveCalibrationParams {
  if (calibration.isManualOverride && calibration.mode === AvatarOrientationMode.Custom) {
    // Custom 模式:直接使用用户设置的参数
    const customParams: EffectiveCalibrationParams = {
      yawOffsetDeg: calibration.yawOffsetDeg,
      swapLeftRight: calibration.swapLeftRight,
      invertForward: calibration.invertForward
    };
    return customParams;
  }

  const effectiveMode: AvatarOrientationMode =
    calibration.mode === AvatarOrientationMode.Auto
      ? calibration.autoDetectedMode
      : calibration.mode;

  const params: EffectiveCalibrationParams = {
    yawOffsetDeg: modeNeedsRotateY180(effectiveMode) ? 180.0 : 0.0,
    swapLeftRight: modeNeedsMirrorLeftRight(effectiveMode),
    invertForward: modeNeedsRotateY180(effectiveMode)
  };
  return params;
}

/**
 * 序列化为 JSON 字符串(持久化用)。
 */
export function serializeCalibration(calibration: AvatarOrientationCalibration): string {
  const obj: CalibrationJson = {
    avatarId: calibration.avatarId,
    sourceSha256: calibration.sourceSha256,
    mode: calibration.mode,
    autoDetectedMode: calibration.autoDetectedMode,
    autoConfidence: calibration.autoConfidence,
    yawOffsetDeg: calibration.yawOffsetDeg,
    swapLeftRight: calibration.swapLeftRight,
    invertForward: calibration.invertForward,
    autoReasonCode: calibration.autoReasonCode,
    isManualOverride: calibration.isManualOverride,
    updatedAt: calibration.updatedAt
  };
  return JSON.stringify(obj);
}

/**
 * 从 JSON 字符串反序列化。
 *
 * @returns 校准数据;解析失败返回 null
 */
export function deserializeCalibration(json: string): AvatarOrientationCalibration | null {
  try {
    const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    const avatarId: string = (obj['avatarId'] ?? '') as string;
    if (avatarId.length === 0) {
      return null;
    }
    return {
      avatarId: avatarId,
      sourceSha256: (obj['sourceSha256'] ?? '') as string,
      mode: parseMode((obj['mode'] ?? 'Auto') as string),
      autoDetectedMode: parseMode((obj['autoDetectedMode'] ?? 'Normal') as string),
      autoConfidence: parseConfidence((obj['autoConfidence'] ?? 'Unknown') as string),
      yawOffsetDeg: (obj['yawOffsetDeg'] ?? 0) as number,
      swapLeftRight: (obj['swapLeftRight'] ?? false) as boolean,
      invertForward: (obj['invertForward'] ?? false) as boolean,
      autoReasonCode: (obj['autoReasonCode'] ?? '') as string,
      isManualOverride: (obj['isManualOverride'] ?? false) as boolean,
      updatedAt: (obj['updatedAt'] ?? 0) as number
    };
  } catch (_e) {
    return null;
  }
}

/**
 * 解析模式字符串(容错)。
 */
function parseMode(value: string): AvatarOrientationMode {
  switch (value) {
    case 'Auto':
      return AvatarOrientationMode.Auto;
    case 'Normal':
      return AvatarOrientationMode.Normal;
    case 'RotateY180':
      return AvatarOrientationMode.RotateY180;
    case 'MirrorLeftRight':
      return AvatarOrientationMode.MirrorLeftRight;
    case 'MirrorLeftRightAndRotateY180':
      return AvatarOrientationMode.MirrorLeftRightAndRotateY180;
    case 'Custom':
      return AvatarOrientationMode.Custom;
    default:
      return AvatarOrientationMode.Auto;
  }
}

/**
 * 解析置信度字符串(容错)。
 */
function parseConfidence(value: string): OrientationConfidence {
  switch (value) {
    case 'High':
      return OrientationConfidence.High;
    case 'Medium':
      return OrientationConfidence.Medium;
    case 'Low':
      return OrientationConfidence.Low;
    case 'Unknown':
      return OrientationConfidence.Unknown;
    default:
      return OrientationConfidence.Unknown;
  }
}

/**
 * 应用手动覆盖,生成新的校准数据。
 *
 * @param base 基础校准(通常来自自动检测或上次保存)
 * @param mode 用户选择的新模式
 * @param customYaw Custom 模式下的 yaw 偏移(度)
 * @param customSwap Custom 模式下的左右交换
 * @param customInvert Custom 模式下的 Forward 反转
 */
export function applyManualOverride(
  base: AvatarOrientationCalibration,
  mode: AvatarOrientationMode,
  customYaw: number,
  customSwap: boolean,
  customInvert: boolean
): AvatarOrientationCalibration {
  const isCustom: boolean = mode === AvatarOrientationMode.Custom;
  const yaw: number = isCustom ? clampYaw(customYaw) : 0;
  const swap: boolean = isCustom ? customSwap : false;
  const invert: boolean = isCustom ? customInvert : false;

  return {
    avatarId: base.avatarId,
    sourceSha256: base.sourceSha256,
    mode: mode,
    autoDetectedMode: base.autoDetectedMode,
    autoConfidence: base.autoConfidence,
    yawOffsetDeg: yaw,
    swapLeftRight: swap,
    invertForward: invert,
    autoReasonCode: base.autoReasonCode,
    isManualOverride: mode !== AvatarOrientationMode.Auto,
    updatedAt: Date.now()
  };
}

/**
 * 将 Yaw 角度限制到 [-180, 180]。
 */
export function clampYaw(yawDeg: number): number {
  let v: number = yawDeg % 360.0;
  if (v > 180.0) {
    v -= 360.0;
  } else if (v < -180.0) {
    v += 360.0;
  }
  return v;
}

/**
 * 生成 Yaw 旋转四元数(Y 轴旋转)。
 *
 * Y 轴旋转 θ 的四元数:(0, sin(θ/2), 0, cos(θ/2))
 *
 * @param yawDeg Yaw 角度(度)
 * @returns 四元数
 */
export function yawToQuaternion(yawDeg: number): QuaternionValue {
  const halfRad: number = (yawDeg * Math.PI / 180.0) / 2.0;
  return {
    x: 0,
    y: Math.sin(halfRad),
    z: 0,
    w: Math.cos(halfRad)
  };
}

/**
 * 左右镜像四元数(X 轴和 Z 轴取反)。
 *
 * 对于 Y 轴镜像平面(左右翻转):
 * - X 分量取反(改变左右方向)
 * - Z 分量取反(改变前后)
 * - Y 和 W 保持
 *
 * 这样组合 = 镜像变换(determinant 为负)。
 *
 * @param q 原始四元数
 * @returns 镜像后的四元数
 */
export function mirrorQuaternionLeftRight(q: QuaternionValue): QuaternionValue {
  return {
    x: -q.x,
    y: q.y,
    z: -q.z,
    w: q.w
  };
}

/**
 * 左右骨骼交换映射。
 *
 * 返回 Map:原骨骼 → 镜像后的对侧骨骼。
 * 用于交换 boneNodeMap 和 sourceWorldRestMap 中的左右条目。
 */
export function getLeftRightBoneSwapMap(): Map<HumanoidBone, HumanoidBone> {
  const map: Map<HumanoidBone, HumanoidBone> = new Map();
  map.set(HumanoidBone.LeftShoulder, HumanoidBone.RightShoulder);
  map.set(HumanoidBone.LeftUpperArm, HumanoidBone.RightUpperArm);
  map.set(HumanoidBone.LeftLowerArm, HumanoidBone.RightLowerArm);
  map.set(HumanoidBone.LeftHand, HumanoidBone.RightHand);
  map.set(HumanoidBone.RightShoulder, HumanoidBone.LeftShoulder);
  map.set(HumanoidBone.RightUpperArm, HumanoidBone.LeftUpperArm);
  map.set(HumanoidBone.RightLowerArm, HumanoidBone.LeftLowerArm);
  map.set(HumanoidBone.RightHand, HumanoidBone.LeftHand);
  map.set(HumanoidBone.LeftUpperLeg, HumanoidBone.RightUpperLeg);
  map.set(HumanoidBone.LeftLowerLeg, HumanoidBone.RightLowerLeg);
  map.set(HumanoidBone.LeftFoot, HumanoidBone.RightFoot);
  map.set(HumanoidBone.LeftToes, HumanoidBone.RightToes);
  map.set(HumanoidBone.RightUpperLeg, HumanoidBone.LeftUpperLeg);
  map.set(HumanoidBone.RightLowerLeg, HumanoidBone.LeftLowerLeg);
  map.set(HumanoidBone.RightFoot, HumanoidBone.LeftFoot);
  map.set(HumanoidBone.RightToes, HumanoidBone.LeftToes);
  map.set(HumanoidBone.LeftEye, HumanoidBone.RightEye);
  map.set(HumanoidBone.RightEye, HumanoidBone.LeftEye);
  return map;
}

/**
 * 判断骨骼是否为左右对称骨骼(非中轴骨骼)。
 */
export function isLeftRightBone(bone: HumanoidBone): boolean {
  return bone === HumanoidBone.LeftShoulder
    || bone === HumanoidBone.LeftUpperArm
    || bone === HumanoidBone.LeftLowerArm
    || bone === HumanoidBone.LeftHand
    || bone === HumanoidBone.LeftUpperLeg
    || bone === HumanoidBone.LeftLowerLeg
    || bone === HumanoidBone.LeftFoot
    || bone === HumanoidBone.LeftToes
    || bone === HumanoidBone.LeftEye
    || bone === HumanoidBone.RightShoulder
    || bone === HumanoidBone.RightUpperArm
    || bone === HumanoidBone.RightLowerArm
    || bone === HumanoidBone.RightHand
    || bone === HumanoidBone.RightUpperLeg
    || bone === HumanoidBone.RightLowerLeg
    || bone === HumanoidBone.RightFoot
    || bone === HumanoidBone.RightToes
    || bone === HumanoidBone.RightEye;
}
