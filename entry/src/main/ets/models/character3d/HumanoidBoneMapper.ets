/**
 * HumanoidBoneMapper 人形骨骼识别与映射
 *
 * T-3D.6A: 根据节点名称识别骨骼 Profile 并建立标准骨骼映射。
 *
 * 支持识别的 Profile:
 * - VRM 0.x Humanoid(基于 VRM 0.x 规范的骨骼名)
 * - VRM 1.0 Humanoid(基于 VRM 1.0 规范的骨骼名)
 * - Mixamo 命名(Mixamo 常见命名)
 * - ArkTavern 标准命名(与 HumanoidBone 枚举一致)
 * - 常见英文 Humanoid 命名(混合命名)
 *
 * 不确定的高风险骨骼不做自动映射,confidence 较低。
 *
 * 必需骨骼缺失时降级为 PartialHumanoid;无任何匹配骨骼时降级为 StaticOnly。
 */

import {
  HumanoidBone,
  SkeletonProfile,
  CompatibilityLevel,
  HumanoidBoneMapping,
  BoneMappingResult,
  REQUIRED_BONES,
  ALL_STANDARD_BONES
} from './HumanoidBone';

/**
 * 骨骼名称映射条目(用于查表)。
 */
interface BoneNameEntry {
  /** 标准骨骼 */
  standard: HumanoidBone;
  /** 该 Profile 下可能的节点名(小写比较) */
  names: string[];
}

/**
 * Profile 候选项(用于 PROFILE_CANDIDATES 列表)。
 */
interface ProfileCandidate {
  profile: SkeletonProfile;
  entries: BoneNameEntry[];
}

/**
 * 单个骨骼匹配结果(在节点名列表中查找最佳匹配)。
 */
interface BoneMatchResult {
  nodeName: string;
  /** T-4.1: 节点索引(来自 nodeNames 数组下标) */
  nodeIndex: number;
  confidence: number;
}

/**
 * Profile 匹配结果(使用指定 Profile 匹配骨骼的输出)。
 */
interface ProfileMatchResult {
  mappings: HumanoidBoneMapping[];
  matchCount: number;
  usedNodeNames: Set<string>;
}

/**
 * 骨骼兼容性检查结果。
 */
interface BoneCompatibilityResult {
  direct: boolean;
  mapped: boolean;
  commonCount: number;
  missingInAction: string[];
}

/**
 * VRM 0.x Humanoid 骨骼命名表。
 * 参考: https://vrm.dev/vrm0/
 */
const VRM0_BONE_NAMES: BoneNameEntry[] = [
  { standard: HumanoidBone.Hips, names: ['hips'] },
  { standard: HumanoidBone.Spine, names: ['spine'] },
  { standard: HumanoidBone.Chest, names: ['chest'] },
  { standard: HumanoidBone.UpperChest, names: ['upperchest', 'upper_chest'] },
  { standard: HumanoidBone.Neck, names: ['neck'] },
  { standard: HumanoidBone.Head, names: ['head'] },
  { standard: HumanoidBone.LeftShoulder, names: ['leftshoulder', 'left_shoulder'] },
  { standard: HumanoidBone.LeftUpperArm, names: ['leftupperarm', 'left_upperarm', 'left_upper_arm'] },
  { standard: HumanoidBone.LeftLowerArm, names: ['leftlowerarm', 'left_lowerarm', 'left_lower_arm', 'leftforearm', 'left_forearm'] },
  { standard: HumanoidBone.LeftHand, names: ['lefthand', 'left_hand'] },
  { standard: HumanoidBone.RightShoulder, names: ['rightshoulder', 'right_shoulder'] },
  { standard: HumanoidBone.RightUpperArm, names: ['rightupperarm', 'right_upperarm', 'right_upper_arm'] },
  { standard: HumanoidBone.RightLowerArm, names: ['rightlowerarm', 'right_lowerarm', 'right_lower_arm', 'rightforearm', 'right_forearm'] },
  { standard: HumanoidBone.RightHand, names: ['righthand', 'right_hand'] },
  { standard: HumanoidBone.LeftUpperLeg, names: ['leftupperleg', 'left_upperleg', 'left_upper_leg', 'leftupleg', 'left_upleg'] },
  { standard: HumanoidBone.LeftLowerLeg, names: ['leftlowerleg', 'left_lowerleg', 'left_lower_leg', 'leftleg', 'left_leg'] },
  { standard: HumanoidBone.LeftFoot, names: ['leftfoot', 'left_foot'] },
  { standard: HumanoidBone.LeftToes, names: ['lefttoes', 'left_toes', 'lefttoe', 'left_toe'] },
  { standard: HumanoidBone.RightUpperLeg, names: ['rightupperleg', 'right_upperleg', 'right_upper_leg', 'rightupleg', 'right_upleg'] },
  { standard: HumanoidBone.RightLowerLeg, names: ['rightlowerleg', 'right_lowerleg', 'right_lower_leg', 'rightleg', 'right_leg'] },
  { standard: HumanoidBone.RightFoot, names: ['rightfoot', 'right_foot'] },
  { standard: HumanoidBone.RightToes, names: ['righttoes', 'right_toes', 'righttoe', 'right_toe'] },
  { standard: HumanoidBone.LeftEye, names: ['lefteye', 'left_eye'] },
  { standard: HumanoidBone.RightEye, names: ['righteye', 'right_eye'] },
  { standard: HumanoidBone.Jaw, names: ['jaw'] }
];

/**
 * VRM 1.0 Humanoid 骨骼命名表(与 VRM 0.x 基本一致,部分命名规范化)。
 * 参考: https://vrm.dev/vrm1/
 */
const VRM1_BONE_NAMES: BoneNameEntry[] = VRM0_BONE_NAMES;

/**
 * Mixamo 呸骼命名表。
 * 参考: https://www.mixamo.com/
 * Mixamo 命名通常为 Head/Hips/Spine/Spine1/Spine2/LeftArm/LeftForeArm/RightArm/RightForeArm 等。
 */
const MIXAMO_BONE_NAMES: BoneNameEntry[] = [
  { standard: HumanoidBone.Hips, names: ['hips', 'mixamorig:hips', 'mixamorighips'] },
  { standard: HumanoidBone.Spine, names: ['spine', 'spine0', 'mixamorig:spine'] },
  { standard: HumanoidBone.Chest, names: ['spine1', 'chest', 'mixamorig:spine1'] },
  { standard: HumanoidBone.UpperChest, names: ['spine2', 'upperchest', 'mixamorig:spine2'] },
  { standard: HumanoidBone.Neck, names: ['neck', 'mixamorig:neck'] },
  { standard: HumanoidBone.Head, names: ['head', 'mixamorig:head'] },
  { standard: HumanoidBone.LeftShoulder, names: ['leftshoulder', 'mixamorig:leftshoulder'] },
  { standard: HumanoidBone.LeftUpperArm, names: ['leftarm', 'leftupperarm', 'mixamorig:leftarm'] },
  { standard: HumanoidBone.LeftLowerArm, names: ['leftforearm', 'leftlowerarm', 'mixamorig:leftforearm'] },
  { standard: HumanoidBone.LeftHand, names: ['lefthand', 'mixamorig:lefthand'] },
  { standard: HumanoidBone.RightShoulder, names: ['rightshoulder', 'mixamorig:rightshoulder'] },
  { standard: HumanoidBone.RightUpperArm, names: ['rightarm', 'rightupperarm', 'mixamorig:rightarm'] },
  { standard: HumanoidBone.RightLowerArm, names: ['rightforearm', 'rightlowerarm', 'mixamorig:rightforearm'] },
  { standard: HumanoidBone.RightHand, names: ['righthand', 'mixamorig:righthand'] },
  { standard: HumanoidBone.LeftUpperLeg, names: ['leftupleg', 'leftupperleg', 'mixamorig:leftupleg'] },
  { standard: HumanoidBone.LeftLowerLeg, names: ['leftleg', 'leftlowerleg', 'mixamorig:leftleg'] },
  { standard: HumanoidBone.LeftFoot, names: ['leftfoot', 'mixamorig:leftfoot'] },
  { standard: HumanoidBone.LeftToes, names: ['lefttoebase', 'lefttoes', 'mixamorig:lefttoebase'] },
  { standard: HumanoidBone.RightUpperLeg, names: ['rightupleg', 'rightupperleg', 'mixamorig:rightupleg'] },
  { standard: HumanoidBone.RightLowerLeg, names: ['rightleg', 'rightlowerleg', 'mixamorig:rightleg'] },
  { standard: HumanoidBone.RightFoot, names: ['rightfoot', 'mixamorig:rightfoot'] },
  { standard: HumanoidBone.RightToes, names: ['righttoebase', 'righttoes', 'mixamorig:righttoebase'] },
  { standard: HumanoidBone.LeftEye, names: ['lefteye', 'mixamorig:lefteye'] },
  { standard: HumanoidBone.RightEye, names: ['righteye', 'mixamorig:righteye'] },
  { standard: HumanoidBone.Jaw, names: ['jaw'] }
];

/**
 * ArkTavern 标准命名(与 HumanoidBone 枚举值一致)。
 */
const ARKTAVERN_BONE_NAMES: BoneNameEntry[] = ALL_STANDARD_BONES.map((bone: HumanoidBone) => {
  return { standard: bone, names: [String(bone).toLowerCase()] } as BoneNameEntry;
});

/**
 * 候选 Profile 列表(按识别优先级排序)。
 * VRM/Mixamo 优先识别,最后 ArkTavern。
 */
const PROFILE_CANDIDATES: ProfileCandidate[] = [
  { profile: SkeletonProfile.VRM0, entries: VRM0_BONE_NAMES },
  { profile: SkeletonProfile.VRM1, entries: VRM1_BONE_NAMES },
  { profile: SkeletonProfile.Mixamo, entries: MIXAMO_BONE_NAMES },
  { profile: SkeletonProfile.ArkTavern, entries: ARKTAVERN_BONE_NAMES }
];

/**
 * 将节点名称规范化为小写(用于查表)。
 * 去除前后空白;保留内部字符(空格/下划线/冒号都保留)。
 */
function normalizeNodeName(name: string): string {
  return name.trim().toLowerCase();
}

/**
 * 判断字符串是否包含子串(大小写不敏感)。
 */
function containsIgnoreCase(source: string, target: string): boolean {
  return source.indexOf(target) >= 0;
}

/**
 * 计算映射置信度。
 * - 完全相等:1.0
 * - 节点名包含骨骼名:0.8
 * - 仅前缀匹配(Mixamorig:):0.7
 * - 其他:0.5
 */
function computeConfidence(nodeName: string, expectedNames: string[]): number {
  const normalized: string = normalizeNodeName(nodeName);
  for (let i: number = 0; i < expectedNames.length; i++) {
    const expected: string = expectedNames[i];
    if (normalized === expected) {
      return 1.0;
    }
  }
  for (let i: number = 0; i < expectedNames.length; i++) {
    const expected: string = expectedNames[i];
    if (containsIgnoreCase(normalized, expected)) {
      // 命名包含 mixamorig 前缀
      if (containsIgnoreCase(normalized, 'mixamo')) {
        return 0.7;
      }
      return 0.8;
    }
  }
  return 0.0;
}

/**
 * 在节点名列表中查找匹配某骨骼的节点。
 * 返回 { nodeName, confidence } 或 null。
 */
function findBestMatch(
  bone: HumanoidBone,
  entry: BoneNameEntry,
  nodeNames: string[],
  usedNodeNames: Set<string>
): BoneMatchResult | null {
  let best: BoneMatchResult | null = null;
  for (let i: number = 0; i < nodeNames.length; i++) {
    const nodeName: string = nodeNames[i];
    if (usedNodeNames.has(nodeName)) {
      continue;
    }
    const confidence: number = computeConfidence(nodeName, entry.names);
    if (confidence === 0.0) {
      continue;
    }
    if (best === null || confidence > best.confidence) {
      best = { nodeName: nodeName, nodeIndex: i, confidence: confidence };
    }
  }
  return best;
}

/**
 * 尝试用指定 Profile 匹配骨骼。
 * 返回该 Profile 的映射条目列表和匹配到的节点数。
 */
function matchWithProfile(
  profile: SkeletonProfile,
  entries: BoneNameEntry[],
  nodeNames: string[],
  modelId: string
): ProfileMatchResult {
  const mappings: HumanoidBoneMapping[] = [];
  const usedNodeNames: Set<string> = new Set<string>();
  let matchCount: number = 0;

  for (let i: number = 0; i < entries.length; i++) {
    const entry: BoneNameEntry = entries[i];
    const isRequired: boolean = REQUIRED_BONES.indexOf(entry.standard) >= 0;
    const best: BoneMatchResult | null =
      findBestMatch(entry.standard, entry, nodeNames, usedNodeNames);
    if (best === null) {
      // 未找到匹配节点:required 骨骼标记为 invalid,非 required 骨骼不添加映射
      if (isRequired) {
        mappings.push({
          profileId: profile,
          modelId: modelId,
          standardBone: entry.standard,
          sourceNodeName: '',
          sourceNodeIndex: -1,
          confidence: 0.0,
          required: true,
          valid: false
        });
      }
      continue;
    }
    usedNodeNames.add(best.nodeName);
    matchCount++;
    mappings.push({
      profileId: profile,
      modelId: modelId,
      standardBone: entry.standard,
      sourceNodeName: best.nodeName,
      sourceNodeIndex: best.nodeIndex,
      confidence: best.confidence,
      required: isRequired,
      valid: true
    });
  }

  return { mappings: mappings, matchCount: matchCount, usedNodeNames: usedNodeNames };
}

/**
 * 计算缺失的必需骨骼。
 */
function computeMissingRequired(mappings: HumanoidBoneMapping[]): HumanoidBone[] {
  const missing: HumanoidBone[] = [];
  for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
    const required: HumanoidBone = REQUIRED_BONES[i];
    let found: boolean = false;
    for (let j: number = 0; j < mappings.length; j++) {
      if (mappings[j].standardBone === required && mappings[j].valid) {
        found = true;
        break;
      }
    }
    if (!found) {
      missing.push(required);
    }
  }
  return missing;
}

/**
 * 根据匹配结果计算兼容等级。
 */
function computeCompatibility(
  matchCount: number,
  missingRequired: HumanoidBone[],
  hasAnySkinOrBone: boolean
): CompatibilityLevel {
  if (matchCount === 0) {
    if (hasAnySkinOrBone) {
      return CompatibilityLevel.EmbeddedOnly;
    }
    return CompatibilityLevel.StaticOnly;
  }
  if (missingRequired.length === 0) {
    return CompatibilityLevel.FullHumanoid;
  }
  // 部分必需骨骼缺失
  if (missingRequired.length >= 4) {
    return CompatibilityLevel.EmbeddedOnly;
  }
  return CompatibilityLevel.PartialHumanoid;
}

/**
 * 执行骨骼识别与映射。
 *
 * 算法:
 * 1. 遍历候选 Profile(VRM0/VRM1/Mixamo/ArkTavern)
 * 2. 对每个 Profile 进行骨骼名匹配,记录匹配数
 * 3. 选择匹配数最多且置信度最高的 Profile
 * 4. 计算缺失的必需骨骼
 * 5. 根据匹配结果确定兼容等级
 *
 * @param nodeNames GLB 节点名称列表
 * @param modelId 模型标识(用于映射条目)
 * @param hasSkinOrBones 是否包含骨骼蒙皮(用于区分 EmbeddedOnly 和 StaticOnly)
 * @returns BoneMappingResult
 */
export function mapBones(
  nodeNames: string[],
  modelId: string,
  hasSkinOrBones: boolean
): BoneMappingResult {
  if (nodeNames.length === 0) {
    return {
      profile: SkeletonProfile.Unknown,
      mappings: [],
      missingRequired: REQUIRED_BONES.slice(),
      compatibility: hasSkinOrBones ? CompatibilityLevel.EmbeddedOnly : CompatibilityLevel.StaticOnly,
      nodeNames: []
    };
  }

  // 尝试所有候选 Profile,选择匹配数最多者
  let bestProfile: SkeletonProfile = SkeletonProfile.Unknown;
  let bestMappings: HumanoidBoneMapping[] = [];
  let bestMatchCount: number = 0;

  for (let i: number = 0; i < PROFILE_CANDIDATES.length; i++) {
    const candidate = PROFILE_CANDIDATES[i];
    const result = matchWithProfile(
      candidate.profile, candidate.entries, nodeNames, modelId
    );
    if (result.matchCount > bestMatchCount) {
      bestMatchCount = result.matchCount;
      bestProfile = candidate.profile;
      bestMappings = result.mappings;
    }
    if (result.matchCount === REQUIRED_BONES.length && bestMatchCount > 0) {
      // 完美匹配,提前结束
      break;
    }
  }

  if (bestMatchCount === 0) {
    return {
      profile: SkeletonProfile.Unknown,
      mappings: [],
      missingRequired: REQUIRED_BONES.slice(),
      compatibility: hasSkinOrBones ? CompatibilityLevel.EmbeddedOnly : CompatibilityLevel.StaticOnly,
      nodeNames: nodeNames
    };
  }

  const missingRequired: HumanoidBone[] = computeMissingRequired(bestMappings);
  const compatibility: CompatibilityLevel = computeCompatibility(
    bestMatchCount, missingRequired, hasSkinOrBones
  );

  return {
    profile: bestProfile,
    mappings: bestMappings,
    missingRequired: missingRequired,
    compatibility: compatibility,
    nodeNames: nodeNames
  };
}

/**
 * 检查两个节点名列表的骨骼是否兼容(用于动作复用策略二)。
 *
 * 兼容性判断:
 * - 两个列表的节点名集合完全一致:Direct
 * - 都能映射到标准 Humanoid 且必需骨骼都在:Mapped
 * - 其他:不兼容
 *
 * @param modelNodeNames 模型节点名列表
 * @param actionNodeNames 动作文件节点名列表
 * @returns 兼容性结果
 */
export function checkBoneCompatibility(
  modelNodeNames: string[],
  actionNodeNames: string[]
): BoneCompatibilityResult {
  const modelSet: Set<string> = new Set<string>();
  for (let i: number = 0; i < modelNodeNames.length; i++) {
    modelSet.add(normalizeNodeName(modelNodeNames[i]));
  }
  const actionSet: Set<string> = new Set<string>();
  for (let i: number = 0; i < actionNodeNames.length; i++) {
    actionSet.add(normalizeNodeName(actionNodeNames[i]));
  }

  // 计算交集
  let commonCount: number = 0;
  const missingInAction: string[] = [];
  const modelArr: string[] = Array.from(modelSet);
  for (let i: number = 0; i < modelArr.length; i++) {
    if (actionSet.has(modelArr[i])) {
      commonCount++;
    } else {
      missingInAction.push(modelArr[i]);
    }
  }

  // Direct:模型节点名集合与动作节点名集合完全一致
  const direct: boolean =
    modelSet.size === actionSet.size && commonCount === modelSet.size;

  // Mapped:两者都能映射到标准 Humanoid 且必需骨骼都在
  let mapped: boolean = false;
  if (!direct && commonCount > 0) {
    const modelResult: BoneMappingResult = mapBones(modelNodeNames, '', true);
    const actionResult: BoneMappingResult = mapBones(actionNodeNames, '', true);
    if (modelResult.compatibility === CompatibilityLevel.FullHumanoid
      && actionResult.compatibility === CompatibilityLevel.FullHumanoid) {
      // 两者都是 FullHumanoid,理论上可以重定向
      mapped = true;
    }
  }

  return {
    direct: direct,
    mapped: mapped,
    commonCount: commonCount,
    missingInAction: missingInAction
  };
}

/**
 * 获取兼容等级的中文显示名。
 */
export function getCompatibilityLevelDisplayName(level: CompatibilityLevel): string {
  switch (level) {
    case CompatibilityLevel.FullHumanoid:
      return '完整人形';
    case CompatibilityLevel.PartialHumanoid:
      return '部分人形';
    case CompatibilityLevel.EmbeddedOnly:
      return '仅内置动画';
    case CompatibilityLevel.StaticOnly:
      return '静态展示';
    case CompatibilityLevel.Unsupported:
      return '不受支持';
    default:
      return '未知';
  }
}

/**
 * 获取骨骼 Profile 的中文显示名。
 */
export function getSkeletonProfileDisplayName(profile: SkeletonProfile): string {
  switch (profile) {
    case SkeletonProfile.VRM0:
      return 'VRM 0.x';
    case SkeletonProfile.VRM1:
      return 'VRM 1.0';
    case SkeletonProfile.Mixamo:
      return 'Mixamo';
    case SkeletonProfile.ArkTavern:
      return 'ArkTavern 标准';
    case SkeletonProfile.Unknown:
      return '未知';
    default:
      return '未知';
  }
}

/**
 * 获取标准骨骼的中文显示名。
 */
export function getBoneDisplayName(bone: HumanoidBone): string {
  switch (bone) {
    case HumanoidBone.Hips: return '髋部';
    case HumanoidBone.Spine: return '脊椎';
    case HumanoidBone.Chest: return '胸部';
    case HumanoidBone.UpperChest: return '上胸部';
    case HumanoidBone.Neck: return '颈部';
    case HumanoidBone.Head: return '头部';
    case HumanoidBone.LeftShoulder: return '左肩';
    case HumanoidBone.LeftUpperArm: return '左大臂';
    case HumanoidBone.LeftLowerArm: return '左小臂';
    case HumanoidBone.LeftHand: return '左手';
    case HumanoidBone.RightShoulder: return '右肩';
    case HumanoidBone.RightUpperArm: return '右大臂';
    case HumanoidBone.RightLowerArm: return '右小臂';
    case HumanoidBone.RightHand: return '右手';
    case HumanoidBone.LeftUpperLeg: return '左大腿';
    case HumanoidBone.LeftLowerLeg: return '左小腿';
    case HumanoidBone.LeftFoot: return '左脚';
    case HumanoidBone.LeftToes: return '左脚趾';
    case HumanoidBone.RightUpperLeg: return '右大腿';
    case HumanoidBone.RightLowerLeg: return '右小腿';
    case HumanoidBone.RightFoot: return '右脚';
    case HumanoidBone.RightToes: return '右脚趾';
    case HumanoidBone.LeftEye: return '左眼';
    case HumanoidBone.RightEye: return '右眼';
    case HumanoidBone.Jaw: return '下巴';
    default: return String(bone);
  }
}
