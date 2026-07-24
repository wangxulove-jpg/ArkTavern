/**
 * AvatarAsset 统一虚拟形象资产抽象
 *
 * T-4.0: VRM First Architecture
 *
 * 设计原则:T-4.0 起,3D 系统从"以模型为中心"转为"以 Avatar 为中心"。
 * AvatarAsset 是所有上层(Chat/动作/AI)访问 3D 虚拟形象的统一入口。
 *
 * 封装:
 * - 模型文件 URI 与显示名
 * - VRM 资产(若为 VRM 文件)
 * - glTF 模型摘要(所有格式通用)
 * - 能力报告(扩展后含 VRM 维度)
 * - 手动骨骼映射(普通 GLB 回退方案)
 * - HumanoidProvider 接口(统一骨骼访问)
 *
 * 注意:AvatarAsset 不持有 Scene 引用(Scene 生命周期由 ViewModel 管理)。
 *       AvatarAsset 是只读快照,修改通过 Service 落盘后重新读取。
 */

import { VrmAsset, createEmptyVrmAsset } from './vrm/VrmAsset';
import { VrmVersion, isVrm } from './vrm/VrmVersion';
import { GltfModelInfo } from '../../parser/GltfValidator';
import { ModelCapabilityReport } from './ModelCapabilityReport';
import { ManualHumanoidMapping } from './ManualHumanoidMapping';

/**
 * Avatar 资产类型(源格式)。
 */
export enum AvatarAssetType {
  /** VRM 1.0 文件 */
  Vrm1 = 'Vrm1',
  /** VRM 0.x 文件 */
  Vrm0x = 'Vrm0x',
  /** 普通 GLB 文件 */
  Glb = 'Glb',
  /** 普通 glTF(.gltf + .bin,当前未直接支持,走 GLB 管线) */
  Gltf = 'Gltf',
  /** FBX(未来支持) */
  Fbx = 'Fbx',
  /** OBJ(未来支持) */
  Obj = 'Obj',
  /** 无骨架 Mesh(最低优先级) */
  StaticMesh = 'StaticMesh'
}

/**
 * Avatar 资产来源(便于 UI 展示优先级)。
 */
export const AVATAR_PRIORITY: Map<AvatarAssetType, number> = new Map([
  [AvatarAssetType.Vrm1, 5],
  [AvatarAssetType.Vrm0x, 5],
  [AvatarAssetType.Glb, 4],
  [AvatarAssetType.Gltf, 4],
  [AvatarAssetType.Fbx, 3],
  [AvatarAssetType.Obj, 2],
  [AvatarAssetType.StaticMesh, 1]
]);

/**
 * AvatarAsset 统一虚拟形象资产。
 */
export interface AvatarAsset {
  /** 唯一标识(通常为 sourceSha256 前 16 位或 modelId) */
  id: string;
  /** 模型文件沙箱 URI */
  modelUri: string;
  /** 显示名 */
  displayName: string;
  /** 文件原始 SHA-256 */
  sourceSha256: string;
  /** 资产类型 */
  assetType: AvatarAssetType;
  /** 是否 VRM */
  isVrm: boolean;

  /** VRM 资产(非 VRM 文件为空 VrmAsset) */
  vrm: VrmAsset;
  /** glTF 模型摘要(所有格式通用) */
  gltf: GltfModelInfo | null;
  /** 能力报告(含 VRM 扩展维度) */
  capability: ModelCapabilityReport | null;
  /** 手动骨骼映射(普通 GLB 回退方案;VRM 不需要) */
  manualMapping: ManualHumanoidMapping | null;

  /** 文件大小(字节) */
  fileSize: number;
  /** 导入时间戳(ms) */
  importedAt: number;
  /** 最后验证时间戳(ms,0 表示未验证) */
  lastVerifiedAt: number;
}

/**
 * 判断 AvatarAsset 是否已具备 Humanoid(无需手动映射)。
 *
 * VRM:humanoid.valid === true
 * GLB:manualMapping != null && manualMapping.valid === true
 */
export function isHumanoidReady(asset: AvatarAsset): boolean {
  if (asset.isVrm) {
    return asset.vrm.humanoid.valid;
  }
  return asset.manualMapping !== null && asset.manualMapping.valid;
}

/**
 * 获取 Avatar 资产类型字符串(用于 UI 展示)。
 */
export function getAvatarTypeLabel(assetType: AvatarAssetType): string {
  if (assetType === AvatarAssetType.Vrm1) {
    return 'VRM 1.0';
  }
  if (assetType === AvatarAssetType.Vrm0x) {
    return 'VRM 0.x';
  }
  if (assetType === AvatarAssetType.Glb) {
    return 'GLB';
  }
  if (assetType === AvatarAssetType.Gltf) {
    return 'glTF';
  }
  if (assetType === AvatarAssetType.Fbx) {
    return 'FBX';
  }
  if (assetType === AvatarAssetType.Obj) {
    return 'OBJ';
  }
  return 'Mesh';
}

/**
 * 根据 VRM 版本推导 AvatarAssetType。
 */
export function avatarTypeFromVrmVersion(version: VrmVersion): AvatarAssetType {
  if (version === VrmVersion.Vrm1) {
    return AvatarAssetType.Vrm1;
  }
  if (version === VrmVersion.Vrm0x) {
    return AvatarAssetType.Vrm0x;
  }
  return AvatarAssetType.Glb;
}

/**
 * 创建空 AvatarAsset(占位,导入前/失败时使用)。
 */
export function createEmptyAvatarAsset(): AvatarAsset {
  return {
    id: '',
    modelUri: '',
    displayName: '',
    sourceSha256: '',
    assetType: AvatarAssetType.Glb,
    isVrm: false,
    vrm: createEmptyVrmAsset(VrmVersion.NonVrm),
    gltf: null,
    capability: null,
    manualMapping: null,
    fileSize: 0,
    importedAt: 0,
    lastVerifiedAt: 0
  };
}

/**
 * 创建轻量 AvatarAsset 摘要(用于列表展示)。
 */
export interface AvatarAssetSummary {
  id: string;
  displayName: string;
  assetType: AvatarAssetType;
  typeLabel: string;
  isVrm: boolean;
  fileSize: number;
  importedAt: number;
  /** VRM 特有:作者 */
  author: string;
  /** VRM 特有:许可 */
  license: string;
  /** VRM 特有:表情数 */
  expressionCount: number;
  /** VRM 特有:SpringBone 关节数 */
  springBoneJointCount: number;
  /** VRM 特有:Humanoid 骨骼数 */
  humanoidBoneCount: number;
  /** Humanoid 是否就绪 */
  humanoidReady: boolean;
}

/**
 * 从 AvatarAsset 生成摘要。
 */
export function summarizeAvatarAsset(asset: AvatarAsset): AvatarAssetSummary {
  const author: string = asset.vrm.meta.authors.length > 0
    ? asset.vrm.meta.authors.join(', ') : '';
  const license: string = asset.vrm.meta.licenseName !== null
    ? asset.vrm.meta.licenseName
    : (asset.vrm.meta.modification !== null ? asset.vrm.meta.modification : '');
  return {
    id: asset.id,
    displayName: asset.displayName,
    assetType: asset.assetType,
    typeLabel: getAvatarTypeLabel(asset.assetType),
    isVrm: asset.isVrm,
    fileSize: asset.fileSize,
    importedAt: asset.importedAt,
    author: author,
    license: license,
    expressionCount: asset.vrm.expressions.expressions.length,
    springBoneJointCount: asset.vrm.springBone.totalJointCount,
    humanoidBoneCount: asset.vrm.humanoid.bones.length,
    humanoidReady: isHumanoidReady(asset)
  };
}
