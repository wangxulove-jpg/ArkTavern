/**
 * HumanoidBone 人形骨骼标准与映射
 *
 * T-3D.6A: 定义标准 Humanoid 骨骼枚举和骨骼映射模型。
 *
 * 支持识别的骨骼 Profile:
 * - VRM 0.x Humanoid
 * - VRM 1.0 Humanoid
 * - Mixamo 命名
 * - 常见英文 Humanoid 命名
 * - ArkTavern 标准命名
 *
 * 不确定的高风险骨骼不做自动映射。
 */

/**
 * 标准人形骨骼枚举。
 */
export enum HumanoidBone {
  /** 髋部(根骨骼) */
  Hips = 'Hips',
  /** 脊椎 */
  Spine = 'Spine',
  /** 胸部 */
  Chest = 'Chest',
  /** 上胸部 */
  UpperChest = 'UpperChest',
  /** 颈部 */
  Neck = 'Neck',
  /** 头部 */
  Head = 'Head',

  /** 左肩 */
  LeftShoulder = 'LeftShoulder',
  /** 左大臂 */
  LeftUpperArm = 'LeftUpperArm',
  /** 左小臂 */
  LeftLowerArm = 'LeftLowerArm',
  /** 左手 */
  LeftHand = 'LeftHand',

  /** 右肩 */
  RightShoulder = 'RightShoulder',
  /** 右大臂 */
  RightUpperArm = 'RightUpperArm',
  /** 右小臂 */
  RightLowerArm = 'RightLowerArm',
  /** 右手 */
  RightHand = 'RightHand',

  /** 左大腿 */
  LeftUpperLeg = 'LeftUpperLeg',
  /** 左小腿 */
  LeftLowerLeg = 'LeftLowerLeg',
  /** 左脚 */
  LeftFoot = 'LeftFoot',
  /** 左脚趾 */
  LeftToes = 'LeftToes',

  /** 右大腿 */
  RightUpperLeg = 'RightUpperLeg',
  /** 右小腿 */
  RightLowerLeg = 'RightLowerLeg',
  /** 右脚 */
  RightFoot = 'RightFoot',
  /** 右脚趾 */
  RightToes = 'RightToes',

  /** 左眼(可选) */
  LeftEye = 'LeftEye',
  /** 右眼(可选) */
  RightEye = 'RightEye',
  /** 下巴(可选) */
  Jaw = 'Jaw'
}

/**
 * 骨骼 Profile 类型。
 */
export enum SkeletonProfile {
  /** VRM 0.x Humanoid */
  VRM0 = 'VRM0',
  /** VRM 1.0 Humanoid */
  VRM1 = 'VRM1',
  /** Mixamo 命名 */
  Mixamo = 'Mixamo',
  /** ArkTavern 标准命名 */
  ArkTavern = 'ArkTavern',
  /** 未知/无法识别 */
  Unknown = 'Unknown'
}

/**
 * 模型兼容等级。
 */
export enum CompatibilityLevel {
  /** 具备完整人形骨骼,可使用统一身体动作 */
  FullHumanoid = 'FullHumanoid',
  /** 缺少部分骨骼,基础身体动作可播放,精细动作降级 */
  PartialHumanoid = 'PartialHumanoid',
  /** 只能播放模型自身携带的动画 */
  EmbeddedOnly = 'EmbeddedOnly',
  /** 没有骨骼或蒙皮,只能静态展示 */
  StaticOnly = 'StaticOnly',
  /** 无法解析或结构不受支持 */
  Unsupported = 'Unsupported'
}

/**
 * 骨骼映射条目。
 */
export interface HumanoidBoneMapping {
  /** Profile 标识 */
  profileId: SkeletonProfile;
  /** 模型标识 */
  modelId: string;
  /** 标准骨骼名 */
  standardBone: HumanoidBone;
  /** 模型中的源节点名 */
  sourceNodeName: string;
  /** 映射置信度(0.0~1.0) */
  confidence: number;
  /** 是否为必需骨骼 */
  required: boolean;
  /** 映射是否有效 */
  valid: boolean;
}

/**
 * 骨骼映射结果。
 */
export interface BoneMappingResult {
  /** 识别到的 Profile */
  profile: SkeletonProfile;
  /** 所有映射条目 */
  mappings: HumanoidBoneMapping[];
  /** 忺缺的关键骨骼列表 */
  missingRequired: HumanoidBone[];
  /** 兼容等级 */
  compatibility: CompatibilityLevel;
  /** 节点名称列表(从 GLB 解析) */
  nodeNames: string[];
}

/**
 * 必需骨骼列表(缺少则降级为 PartialHumanoid)。
 */
export const REQUIRED_BONES: HumanoidBone[] = [
  HumanoidBone.Hips,
  HumanoidBone.Spine,
  HumanoidBone.Head,
  HumanoidBone.LeftUpperArm,
  HumanoidBone.RightUpperArm,
  HumanoidBone.LeftUpperLeg,
  HumanoidBone.RightUpperLeg
];

/**
 * 所有标准骨骼列表(有序)。
 */
export const ALL_STANDARD_BONES: HumanoidBone[] = [
  HumanoidBone.Hips,
  HumanoidBone.Spine,
  HumanoidBone.Chest,
  HumanoidBone.UpperChest,
  HumanoidBone.Neck,
  HumanoidBone.Head,
  HumanoidBone.LeftShoulder,
  HumanoidBone.LeftUpperArm,
  HumanoidBone.LeftLowerArm,
  HumanoidBone.LeftHand,
  HumanoidBone.RightShoulder,
  HumanoidBone.RightUpperArm,
  HumanoidBone.RightLowerArm,
  HumanoidBone.RightHand,
  HumanoidBone.LeftUpperLeg,
  HumanoidBone.LeftLowerLeg,
  HumanoidBone.LeftFoot,
  HumanoidBone.LeftToes,
  HumanoidBone.RightUpperLeg,
  HumanoidBone.RightLowerLeg,
  HumanoidBone.RightFoot,
  HumanoidBone.RightToes,
  HumanoidBone.LeftEye,
  HumanoidBone.RightEye,
  HumanoidBone.Jaw
];

/**
 * 动作来源格式。
 */
export enum ActionSourceFormat {
  /** 模型内置 GLB 动画 */
  EmbeddedGlb = 'EmbeddedGlb',
  /** 外部 GLB 动画文件 */
  ExternalGlb = 'ExternalGlb',
  /** GLTF 格式(依赖外部文件) */
  Gltf = 'Gltf',
  /** VRM Animation 格式 */
  Vrma = 'Vrma',
  /** 未知格式 */
  Unknown = 'Unknown'
}

/**
 * 动作兼容性检查结果。
 */
export enum ActionCompatibility {
  /** 完全一致骨骼,可直接播放 */
  Direct = 'Direct',
  /** 可通过标准 Humanoid 映射 */
  Mapped = 'Mapped',
  /** 只能在原模型中播放 */
  EmbeddedOnly = 'EmbeddedOnly',
  /** 可以保存,但当前运行时不能播放 */
  MetadataOnly = 'MetadataOnly',
  /** 无法使用 */
  Unsupported = 'Unsupported'
}
