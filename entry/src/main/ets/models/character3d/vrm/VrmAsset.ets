/**
 * VrmAsset VRM 资产(组合所有 VRM 元数据)
 *
 * T-4.0: VRM First Architecture
 *
 * VRMAsset 是 VRM 文件解析后的完整产物,组合:
 * - VrmMeta(作者/许可/版本)
 * - VrmHumanoid(标准骨骼显式映射)
 * - VrmExpressionSet(表情预设)
 * - VrmLookAt(视线跟随配置)
 * - VrmSpringBoneSet(物理摆动骨骼)
 * - VrmFirstPerson(第一人称遮罩)
 *
 * Character3DService / VRMImporter 产出 VrmAsset,
 * AvatarAsset 封装 VrmAsset 作为统一抽象的一部分。
 *
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/
 */

import { VrmVersion } from './VrmVersion';
import { VrmMeta, createEmptyVrmMeta } from './VrmMeta';
import { VrmHumanoid, createEmptyVrmHumanoid } from './VrmHumanoid';
import { VrmExpressionSet, createEmptyVrmExpressionSet } from './VrmExpression';
import { VrmLookAt, createEmptyVrmLookAt } from './VrmLookAt';
import { VrmSpringBoneSet, createEmptyVrmSpringBoneSet } from './VrmSpringBone';
import { VrmFirstPerson, createEmptyVrmFirstPerson } from './VrmFirstPerson';

/**
 * VRM 资产(解析产物)。
 */
export interface VrmAsset {
  /** VRM 版本 */
  version: VrmVersion;
  /** 模型文件原始 SHA-256 */
  sourceSha256: string;
  /** glTF JSON 引用的 nodes 总数(用于校验 nodeIndex) */
  nodeCount: number;
  /** glTF JSON 引用的 meshes 总数 */
  meshCount: number;
  /** glTF JSON 引用的 materials 总数 */
  materialCount: number;
  /** glTF JSON 引用的 images 总数(用于 thumbnail) */
  imageCount: number;

  /** VRM 元信息 */
  meta: VrmMeta;
  /** VRM Humanoid 骨骼映射 */
  humanoid: VrmHumanoid;
  /** VRM 表情集 */
  expressions: VrmExpressionSet;
  /** VRM 视线配置 */
  lookAt: VrmLookAt;
  /** VRM SpringBone 配置 */
  springBone: VrmSpringBoneSet;
  /** VRM 第一人称配置 */
  firstPerson: VrmFirstPerson;

  /** 是否包含 VRMC_materials_mtoon 材质扩展 */
  hasMToonMaterial: boolean;
  /** 是否包含 VRMC_node_constraint 扩展 */
  hasNodeConstraint: boolean;

  /** 整体解析是否成功(至少 meta + humanoid 有效) */
  valid: boolean;
  /** 解析错误信息(空表示无错误) */
  parseError: string;
}

/**
 * 创建空 VRM 资产(用于非 VRM 文件或解析失败)。
 */
export function createEmptyVrmAsset(version: VrmVersion): VrmAsset {
  return {
    version: version,
    sourceSha256: '',
    nodeCount: 0,
    meshCount: 0,
    materialCount: 0,
    imageCount: 0,
    meta: createEmptyVrmMeta(version),
    humanoid: createEmptyVrmHumanoid(version),
    expressions: createEmptyVrmExpressionSet(),
    lookAt: createEmptyVrmLookAt(version),
    springBone: createEmptyVrmSpringBoneSet(version),
    firstPerson: createEmptyVrmFirstPerson(version),
    hasMToonMaterial: false,
    hasNodeConstraint: false,
    valid: false,
    parseError: ''
  };
}
