/**
 * ManualHumanoidMapping 手动人形骨骼映射数据结构
 *
 * T-3D.6E P3: 实现可保存的手动人形骨骼映射基础功能。
 *
 * 职责:
 * - 定义 HumanoidJointBinding(单关节映射绑定)
 * - 定义 ManualHumanoidMapping(完整手动映射数据)
 * - 定义 SkeletonHash 输入与计算函数
 * - 定义 SkeletonRestPose(关节 rest pose 快照)
 * - 定义 ModelAlignmentConfig(模型基础姿态和坐标校准)
 * - 定义 AxisDirection 枚举
 * - 提供映射创建、更新、序列化辅助函数
 *
 * 设计原则:
 * - skeletonHash 由 joint 数量/名称/父子/IBM count 等生成,模型变化则失效
 * - 映射按 modelId+sourceSha256 关联,同 SHA 可复用
 * - rest pose 用于动作重定向前置,不在此处播放动画
 * - alignment 是模型校准(非相机视角),用于骨骼空间判断
 *
 * 不依赖 ArkUI/ArkGraphics3D,纯逻辑可单元测试。
 */

import { HumanoidBone } from './HumanoidBone';

/**
 * 轴方向。
 */
export enum AxisDirection {
  PositiveX = 'PositiveX',
  NegativeX = 'NegativeX',
  PositiveY = 'PositiveY',
  NegativeY = 'NegativeY',
  PositiveZ = 'PositiveZ',
  NegativeZ = 'NegativeZ'
}

/**
 * 3D 向量。
 */
export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

/**
 * 四元数。
 */
export interface Quat {
  x: number;
  y: number;
  z: number;
  w: number;
}

/**
 * 4x4 矩阵(列主序,与 glTF 一致)。
 */
export interface Mat4 {
  m: number[]; // 长度 16
}

/**
 * 单关节映射绑定。
 */
export interface HumanoidJointBinding {
  /** 目标标准关节 */
  targetJoint: HumanoidBone;
  /** 源节点索引(glTF nodes 数组下标) */
  sourceNodeIndex: number;
  /** 源骨骼名(原始 name,用于 UI 显示) */
  sourceBoneName: string;
  /** 映射方式:auto/manual */
  mappingMethod: BoneMappingMethod;
  /** 置信度(0.0~1.0,manual 时为 1.0) */
  confidence: number;
  /** rest pose 局部旋转(可选,用于重定向校正) */
  restLocalRotation?: Quat;
  /** rest pose 世界位置(可选,用于空间校验) */
  restWorldPosition?: Vec3;
}

/**
 * 映射方式。
 *
 * - Auto: 自动骨骼名匹配
 * - Manual: 手动骨骼树选择(历史值,语义等同 ManualTree)
 * - ManualTree: 手动从骨骼树选择
 * - ManualSurface: 手动从模型表面点选推断
 */
export enum BoneMappingMethod {
  Auto = 'Auto',
  Manual = 'Manual',
  ManualTree = 'ManualTree',
  ManualSurface = 'ManualSurface'
}

/**
 * 模型基础姿态和坐标校准。
 *
 * 这是模型校准,不是相机视角。
 * 用于骨骼空间判断和后续动作重定向。
 */
export interface ModelAlignmentConfig {
  /** X 轴旋转(度) */
  rotationX: number;
  /** Y 轴旋转(度) */
  rotationY: number;
  /** Z 轴旋转(度) */
  rotationZ: number;
  /** 中心偏移 X */
  centerOffsetX: number;
  /** 中心偏移 Y */
  centerOffsetY: number;
  /** 中心偏移 Z */
  centerOffsetZ: number;
  /** 单位缩放(1.0 表示原模型单位) */
  unitScale: number;
  /** 地面偏移(脚底 Y 坐标) */
  groundOffset: number;
  /** 前向轴(模型正面方向) */
  forwardAxis: AxisDirection;
  /** 上向轴(模型头顶方向) */
  upAxis: AxisDirection;
}

/**
 * Skeleton rest pose 单关节数据。
 */
export interface SkeletonRestPose {
  /** 节点索引 */
  nodeIndex: number;
  /** 父节点索引(-1 表示根) */
  parentNodeIndex: number;
  /** 局部平移 */
  localTranslation: Vec3;
  /** 局部旋转 */
  localRotation: Quat;
  /** 局部缩放 */
  localScale: Vec3;
  /** 世界矩阵 */
  worldMatrix: Mat4;
  /** inverse bind matrix(可选,skin joint 才有) */
  inverseBindMatrix?: Mat4;
}

/**
 * Rest pose 校准快照。
 *
 * 保存导入时的 rest pose,用于动作重定向时计算骨骼偏移。
 */
export interface RestPoseCalibration {
  /** 关节 rest pose 列表 */
  joints: SkeletonRestPose[];
  /** 姿态类型(A-pose/T-pose/Unknown) */
  poseType: RestPoseType;
  /** shoulder rest offset(度,可选) */
  shoulderRestOffsetDeg?: number;
  /** arm rest rotation(度,可选) */
  armRestRotationDeg?: number;
  /** leg rest rotation(度,可选) */
  legRestRotationDeg?: number;
}

/**
 * Rest pose 类型。
 */
export enum RestPoseType {
  Unknown = 'Unknown',
  TPose = 'TPose',
  APose = 'APose',
  Custom = 'Custom'
}

/**
 * Skeleton hash 输入。
 */
export interface SkeletonHashInput {
  /** joint node 数量 */
  jointCount: number;
  /** joint 名称列表(按 skin.joints 顺序) */
  jointNames: string[];
  /** 每个 joint 的父节点索引(-1 表示根) */
  parentIndices: number[];
  /** inverse bind matrix 数量 */
  inverseBindMatrixCount: number;
}

/**
 * 完整手动映射数据。
 */
export interface ManualHumanoidMapping {
  /** Profile 版本(目前固定为 1) */
  profileVersion: number;
  /** 模型 ID(= displayName) */
  modelId: string;
  /** 模型文件 SHA-256(导入时记录) */
  sourceSha256: string;
  /** 骨架 hash(变化则映射失效) */
  skeletonHash: string;

  /** 关节映射列表 */
  joints: HumanoidJointBinding[];

  /** 模型校准 */
  alignment: ModelAlignmentConfig;

  /** Rest pose 校准(可选) */
  restPoseCalibration?: RestPoseCalibration;

  /** 自动映射数量 */
  autoMappedCount: number;
  /** 手动映射数量 */
  manualMappedCount: number;
  /** 缺失的必需关节 */
  requiredMissing: HumanoidBone[];
  /** 缺失的可选关节 */
  optionalMissing: HumanoidBone[];

  /** 映射是否有效(通过验证) */
  valid: boolean;
  /** 是否动作重定向就绪 */
  retargetReady: boolean;

  /** 警告列表 */
  warnings: string[];

  /** 创建时间(ms) */
  createdAt: number;
  /** 更新时间(ms) */
  updatedAt: number;
}

/**
 * 创建默认的空映射。
 *
 * @param modelId 模型 ID
 * @param sourceSha256 模型文件 SHA-256
 * @param skeletonHash 骨架 hash
 */
export function createEmptyManualMapping(
  modelId: string,
  sourceSha256: string,
  skeletonHash: string
): ManualHumanoidMapping {
  const now: number = Date.now();
  return {
    profileVersion: 1,
    modelId: modelId,
    sourceSha256: sourceSha256,
    skeletonHash: skeletonHash,
    joints: [],
    alignment: createDefaultAlignmentConfig(),
    autoMappedCount: 0,
    manualMappedCount: 0,
    requiredMissing: [],
    optionalMissing: [],
    valid: false,
    retargetReady: false,
    warnings: [],
    createdAt: now,
    updatedAt: now
  };
}

/**
 * 创建默认的模型校准配置。
 *
 * 默认假设:
 * - Y-up
 * - -Z 为前向(glTF 默认)
 * - 无旋转
 * - 单位缩放 1.0
 * - 地面在 Y=0
 */
export function createDefaultAlignmentConfig(): ModelAlignmentConfig {
  return {
    rotationX: 0,
    rotationY: 0,
    rotationZ: 0,
    centerOffsetX: 0,
    centerOffsetY: 0,
    centerOffsetZ: 0,
    unitScale: 1.0,
    groundOffset: 0,
    forwardAxis: AxisDirection.NegativeZ,
    upAxis: AxisDirection.PositiveY
  };
}

/**
 * 计算 skeleton hash。
 *
 * 输入:
 * - joint 数量
 * - joint 名称(归一化后)
 * - parent-child 关系
 * - inverse bind count
 *
 * 输出:SHA-256 风格的 16 进制字符串(64 字符)。
 *
 * 注意:ArkTS 标准库没有 SHA-256,这里使用简单 hash 函数。
 * 用于检测骨架结构变化,不用于密码学。
 *
 * @param input 骨架输入
 * @returns 16 进制字符串
 */
export function computeSkeletonHash(input: SkeletonHashInput): string {
  // 构建规范化字符串
  const parts: string[] = [];
  parts.push('joints:' + input.jointCount);
  parts.push('ibm:' + input.inverseBindMatrixCount);
  for (let i: number = 0; i < input.jointNames.length; i++) {
    const normalized: string = normalizeBoneName(input.jointNames[i]);
    parts.push('j' + i + ':' + normalized);
  }
  for (let i: number = 0; i < input.parentIndices.length; i++) {
    parts.push('p' + i + ':' + input.parentIndices[i]);
  }
  const combined: string = parts.join('|');

  // FNV-1a 64-bit 风格 hash(简化为 32-bit × 2)
  let h1: number = 0x811c9dc5;
  let h2: number = 0x1000193;
  for (let i: number = 0; i < combined.length; i++) {
    const c: number = combined.charCodeAt(i);
    h1 = ((h1 ^ c) * 0x01000193) >>> 0;
    h2 = ((h2 + c) * 0x100000001b3) >>> 0;
  }
  return toHex8(h1) + toHex8(h2) + toHex8(h1 >>> 16) + toHex8(h2 >>> 16)
    + toHex8((h1 ^ h2) >>> 0) + toHex8((h1 + h2) >>> 0) + toHex8(h1 >>> 24) + toHex8(h2 >>> 24);
}

/**
 * 32-bit 数字转 8 位 16 进制字符串。
 */
function toHex8(value: number): string {
  const v: number = value >>> 0;
  let s: string = '';
  const hexChars: string = '0123456789abcdef';
  for (let i: number = 0; i < 8; i++) {
    s = hexChars.charAt(v >>> (i * 4) & 0xf) + s;
  }
  return s;
}

/**
 * 骨骼名称归一化(用于 skeleton hash)。
 *
 * 规则:
 * 1. 转小写
 * 2. 删除空格/下划线/连字符/点
 * 3. 删除常见前缀:mixamorig/armature/rig/skeleton/bip/bone
 */
export function normalizeBoneName(name: string): string {
  if (name.length === 0) {
    return '';
  }
  let s: string = name.toLowerCase();
  // 删除分隔符
  s = s.replace(/[ _\-.]/g, '');
  // 删除常见前缀
  const prefixes: string[] = ['mixamorig', 'armature', 'rig', 'skeleton', 'bip', 'bone'];
  for (let i: number = 0; i < prefixes.length; i++) {
    if (s.startsWith(prefixes[i])) {
      s = s.substring(prefixes[i].length);
      break;
    }
  }
  return s;
}

/**
 * 更新映射的统计字段(autoMappedCount/manualMappedCount/requiredMissing 等)。
 *
 * 应在每次添加/移除/替换映射后调用。
 *
 * @param mapping 待更新的映射(原地修改)
 * @param requiredBones 必需骨骼列表
 * @param optionalBones 可选骨骼列表
 */
export function refreshMappingStats(
  mapping: ManualHumanoidMapping,
  requiredBones: HumanoidBone[],
  optionalBones: HumanoidBone[]
): void {
  let autoCount: number = 0;
  let manualCount: number = 0;
  // ArkTS 对 Set<enum> 支持有限,用数组查重
  const mappedTargets: HumanoidBone[] = [];
  for (let i: number = 0; i < mapping.joints.length; i++) {
    const joint: HumanoidJointBinding = mapping.joints[i];
    if (joint.mappingMethod === BoneMappingMethod.Auto) {
      autoCount++;
    } else if (joint.mappingMethod === BoneMappingMethod.Manual
      || joint.mappingMethod === BoneMappingMethod.ManualTree
      || joint.mappingMethod === BoneMappingMethod.ManualSurface) {
      manualCount++;
    }
    mappedTargets.push(joint.targetJoint);
  }
  mapping.autoMappedCount = autoCount;
  mapping.manualMappedCount = manualCount;

  // 计算缺失
  const missingRequired: HumanoidBone[] = [];
  for (let i: number = 0; i < requiredBones.length; i++) {
    if (!containsBone(mappedTargets, requiredBones[i])) {
      missingRequired.push(requiredBones[i]);
    }
  }
  const missingOptional: HumanoidBone[] = [];
  for (let i: number = 0; i < optionalBones.length; i++) {
    if (!containsBone(mappedTargets, optionalBones[i])) {
      missingOptional.push(optionalBones[i]);
    }
  }
  mapping.requiredMissing = missingRequired;
  mapping.optionalMissing = missingOptional;
  mapping.updatedAt = Date.now();
}

/**
 * 数组中是否包含指定骨骼。
 */
function containsBone(arr: HumanoidBone[], bone: HumanoidBone): boolean {
  for (let i: number = 0; i < arr.length; i++) {
    if (arr[i] === bone) {
      return true;
    }
  }
  return false;
}

/**
 * 查找指定标准关节的绑定。
 */
export function findJointBinding(
  mapping: ManualHumanoidMapping,
  target: HumanoidBone
): HumanoidJointBinding | null {
  for (let i: number = 0; i < mapping.joints.length; i++) {
    if (mapping.joints[i].targetJoint === target) {
      return mapping.joints[i];
    }
  }
  return null;
}

/**
 * 查找指定源节点索引是否已被映射。
 */
export function isSourceNodeMapped(
  mapping: ManualHumanoidMapping,
  sourceNodeIndex: number
): boolean {
  for (let i: number = 0; i < mapping.joints.length; i++) {
    if (mapping.joints[i].sourceNodeIndex === sourceNodeIndex) {
      return true;
    }
  }
  return false;
}

/**
 * 添加或替换关节绑定。
 *
 * - 若 target 已有绑定,先移除旧绑定
 * - 若 sourceNodeIndex 已被其他 target 使用,先解除旧映射(避免重复)
 *
 * @param mapping 待更新的映射
 * @param binding 新绑定
 * @returns 被替换的旧绑定(若无返回 null)
 */
export function setJointBinding(
  mapping: ManualHumanoidMapping,
  binding: HumanoidJointBinding
): HumanoidJointBinding | null {
  let replacedOld: HumanoidJointBinding | null = null;
  // 1. 移除同 target 的旧绑定
  for (let i: number = 0; i < mapping.joints.length; i++) {
    if (mapping.joints[i].targetJoint === binding.targetJoint) {
      replacedOld = mapping.joints[i];
      mapping.joints.splice(i, 1);
      break;
    }
  }
  // 2. 若 sourceNodeIndex 已被其他 target 使用,解除旧映射
  for (let i: number = 0; i < mapping.joints.length; i++) {
    if (mapping.joints[i].sourceNodeIndex === binding.sourceNodeIndex
      && mapping.joints[i].targetJoint !== binding.targetJoint) {
      mapping.joints.splice(i, 1);
      i--;
    }
  }
  // 3. 添加新绑定
  mapping.joints.push(binding);
  mapping.updatedAt = Date.now();
  return replacedOld;
}

/**
 * 移除指定 target 的绑定。
 *
 * @returns 被移除的绑定(若无返回 null)
 */
export function removeJointBinding(
  mapping: ManualHumanoidMapping,
  target: HumanoidBone
): HumanoidJointBinding | null {
  for (let i: number = 0; i < mapping.joints.length; i++) {
    if (mapping.joints[i].targetJoint === target) {
      const removed: HumanoidJointBinding = mapping.joints[i];
      mapping.joints.splice(i, 1);
      mapping.updatedAt = Date.now();
      return removed;
    }
  }
  return null;
}

/**
 * 清空所有映射。
 */
export function clearAllBindings(mapping: ManualHumanoidMapping): void {
  mapping.joints = [];
  mapping.autoMappedCount = 0;
  mapping.manualMappedCount = 0;
  mapping.requiredMissing = [];
  mapping.optionalMissing = [];
  mapping.valid = false;
  mapping.retargetReady = false;
  mapping.warnings = [];
  mapping.updatedAt = Date.now();
}

/**
 * 检查 skeletonHash 是否与当前模型一致。
 *
 * @returns true 一致(可继续使用映射),false 不一致(需重新验证)
 */
export function isSkeletonHashMatched(
  mapping: ManualHumanoidMapping,
  currentSkeletonHash: string
): boolean {
  return mapping.skeletonHash === currentSkeletonHash;
}

/**
 * 序列化为 JSON 字符串(用于 Preferences 持久化)。
 */
export function serializeManualMapping(mapping: ManualHumanoidMapping): string {
  return JSON.stringify(mapping);
}

/**
 * 从 JSON 字符串反序列化。
 *
 * @returns 解析失败返回 null
 */
export function deserializeManualMapping(json: string): ManualHumanoidMapping | null {
  try {
    const obj: ManualHumanoidMapping = JSON.parse(json) as ManualHumanoidMapping;
    if (obj === null || obj.profileVersion === undefined) {
      return null;
    }
    return obj;
  } catch (e) {
    return null;
  }
}
