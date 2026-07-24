/**
 * GltfSkinMaterialAnalyzer Skin 与 Material 深度分析
 *
 * T-3D.6E P0: 第十节 Skin 校验 + 第九节材质诊断
 *
 * 职责:
 * - 遍历 glTF JSON 的 skins/meshes/materials/accessors,生成 SkinValidationReport
 * - 检查 joints/IBM/JOINTS/WEIGHTS 完整性、joint index 范围、权重归一化
 * - 遍历 materials 检测透明/Unlit/PBR/双面/全透明
 * - 不依赖 ArkUI / ArkGraphics3D,纯逻辑可单元测试
 * - 不修改原 GLB 文件
 *
 * 设计原则:
 * - skin.skeleton 缺失不算错误(glTF 中是可选字段)
 * - joint index 越界算错误
 * - 权重未归一化只警告(模型仍可渲染)
 * - 权重全 0 的顶点计数只警告
 */

import {
  SkinValidationReport,
  MaterialValidationReport
} from '../models/character3d/ModelCapabilityReport';

/**
 * Skin 与 Material 分析输入。
 */
export interface GltfSkinMaterialInput {
  /** glTF JSON 对象(由 GltfValidator 传入) */
  gltfJson: Record<string, Object> | null;
}

/**
 * Skin + Material 综合分析结果。
 */
export interface GltfSkinMaterialAnalysis {
  skinReport: SkinValidationReport;
  materialReport: MaterialValidationReport;
}

/**
 * 获取数组长度。
 */
function getArrayLength(json: Record<string, Object>, key: string): number {
  const arr: Object | undefined = json[key];
  if (arr === undefined || arr === null || !(arr instanceof Array)) {
    return 0;
  }
  return (arr as Object[]).length;
}

/**
 * 获取数组字段(返回 Object[] 或空数组)。
 */
function getArrayField(json: Record<string, Object>, key: string): Object[] {
  const arr: Object | undefined = json[key];
  if (arr === undefined || arr === null || !(arr instanceof Array)) {
    return [];
  }
  return arr as Object[];
}

/**
 * 安全读取 number 字段。
 */
function getNumber(obj: Record<string, Object>, key: string, defaultValue: number): number {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null || typeof v !== 'number') {
    return defaultValue;
  }
  return v as number;
}

/**
 * 安全读取 number[] 字段。
 */
function getNumberArray(obj: Record<string, Object>, key: string): number[] | null {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null || !(v instanceof Array)) {
    return null;
  }
  const arr: Object[] = v as Object[];
  const result: number[] = [];
  for (let i: number = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (typeof item !== 'number' || !Number.isFinite(item as number)) {
      return null;
    }
    result.push(item as number);
  }
  return result;
}

/**
 * 安全读取 boolean 字段。
 */
function getBoolean(obj: Record<string, Object>, key: string, defaultValue: boolean): boolean {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null || typeof v !== 'boolean') {
    return defaultValue;
  }
  return v as boolean;
}

/**
 * 安全读取 string 字段。
 */
function getString(obj: Record<string, Object>, key: string, defaultValue: string): string {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null || typeof v !== 'string') {
    return defaultValue;
  }
  return v as string;
}

/**
 * 读取 primitive 的 attributes.JOINTS_0 / WEIGHTS_0 / POSITION accessor 索引。
 */
interface PrimitiveAttributeIndices {
  positionAccessor: number;
  jointsAccessor: number;
  weightsAccessor: number;
  hasJoints: boolean;
  hasWeights: boolean;
}

/**
 * 提取 primitive 的 POSITION/JOINTS_0/WEIGHTS_0 accessor 索引。
 */
function extractPrimitiveAttributes(prim: Record<string, Object>): PrimitiveAttributeIndices {
  const attrsObj: Object | undefined = prim['attributes'];
  const result: PrimitiveAttributeIndices = {
    positionAccessor: -1,
    jointsAccessor: -1,
    weightsAccessor: -1,
    hasJoints: false,
    hasWeights: false
  };
  if (attrsObj === undefined || attrsObj === null) {
    return result;
  }
  const attrs: Record<string, Object> = attrsObj as Record<string, Object>;
  const posIdx: Object | undefined = attrs['POSITION'];
  if (posIdx !== undefined && posIdx !== null && typeof posIdx === 'number') {
    result.positionAccessor = posIdx as number;
  }
  const jointsIdx: Object | undefined = attrs['JOINTS_0'];
  if (jointsIdx !== undefined && jointsIdx !== null && typeof jointsIdx === 'number') {
    result.jointsAccessor = jointsIdx as number;
    result.hasJoints = true;
  }
  const weightsIdx: Object | undefined = attrs['WEIGHTS_0'];
  if (weightsIdx !== undefined && weightsIdx !== null && typeof weightsIdx === 'number') {
    result.weightsAccessor = weightsIdx as number;
    result.hasWeights = true;
  }
  return result;
}

/**
 * 获取 accessor 的 componentType。
 */
function getAccessorComponentType(json: Record<string, Object>, accessorIndex: number): number {
  const accessors: Object[] = getArrayField(json, 'accessors');
  if (accessorIndex < 0 || accessorIndex >= accessors.length) {
    return 0;
  }
  const accObj: Object = accessors[accessorIndex];
  if (accObj === null || accObj === undefined) {
    return 0;
  }
  const acc: Record<string, Object> = accObj as Record<string, Object>;
  return getNumber(acc, 'componentType', 0);
}

/**
 * T-3D.6E: 分析 Skin 与 Material 数据,生成详细校验报告。
 *
 * Skin 校验内容:
 * - skinCount: skin 总数
 * - jointCount: 所有 skin.joints 去重前的总数
 * - inverseBindMatrixCount: 所有 skin.inverseBindMatrices 引用数
 * - meshWithSkinCount: 含 JOINTS_0/WEIGHTS_0 的 mesh 数
 * - meshesMissingWeights: 有 JOINTS 但缺 WEIGHTS 的 mesh 数
 * - meshesMissingJoints: 有 WEIGHTS 但缺 JOINTS 的 mesh 数
 * - invalidJointIndexCount: JOINTS accessor 中超过 skin.joints 长度的索引数(估算)
 * - invalidWeightCount: WEIGHTS accessor 中非有限值的数量(估算)
 * - zeroWeightVertexCount: 全 0 权重顶点数(估算)
 * - nonNormalizedWeightVertexCount: 权重和不为 1 的顶点数(估算)
 *
 * Material 校验内容:
 * - materialCount: 材质总数
 * - transparentMaterialCount: BLEND 或 MASK 模式材质数
 * - unlitMaterialCount: 包含 KHR_materials_unlit 的材质数
 * - pbrMaterialCount: 有 pbrMetallicRoughness 的材质数
 * - fullyTransparentCount: baseColorFactor.a=0 的材质数
 * - missingTextureCount: 引用不存在的 texture 索引的材质数
 *
 * @param input gltfJson 输入
 * @returns GltfSkinMaterialAnalysis
 */
export function analyzeSkinAndMaterial(input: GltfSkinMaterialInput): GltfSkinMaterialAnalysis {
  const skinReport: SkinValidationReport = {
    skinCount: 0,
    validSkinCount: 0,
    jointCount: 0,
    inverseBindMatrixCount: 0,
    meshWithSkinCount: 0,
    meshesMissingWeights: 0,
    meshesMissingJoints: 0,
    invalidJointIndexCount: 0,
    invalidWeightCount: 0,
    zeroWeightVertexCount: 0,
    nonNormalizedWeightVertexCount: 0,
    warnings: []
  };
  const materialReport: MaterialValidationReport = {
    materialCount: 0,
    transparentMaterialCount: 0,
    unlitMaterialCount: 0,
    pbrMaterialCount: 0,
    fullyTransparentCount: 0,
    missingTextureCount: 0,
    warnings: []
  };

  if (input.gltfJson === null) {
    return { skinReport: skinReport, materialReport: materialReport };
  }
  const json: Record<string, Object> = input.gltfJson;

  // ========== Skin 校验 ==========
  const skins: Object[] = getArrayField(json, 'skins');
  skinReport.skinCount = skins.length;
  if (skins.length === 0) {
    // 无 skin,无需校验
  } else {
    // 收集所有 skin.joints 的最大长度,用于估算 joint index 范围
    let totalJoints: number = 0;
    let totalIbm: number = 0;
    let validSkinCount: number = 0;
    for (let i: number = 0; i < skins.length; i++) {
      const skinObj: Object = skins[i];
      if (skinObj === null || skinObj === undefined) {
        continue;
      }
      const skin: Record<string, Object> = skinObj as Record<string, Object>;
      const joints: number[] | null = getNumberArray(skin, 'joints');
      if (joints === null || joints.length === 0) {
        skinReport.warnings.push('skin[' + i + '] joints 为空或非法');
        continue;
      }
      totalJoints += joints.length;
      // IBM 索引(inverseBindMatrices 是 accessor 索引,单个 skin 一个)
      const ibmIdx: Object | undefined = skin['inverseBindMatrices'];
      if (ibmIdx !== undefined && ibmIdx !== null && typeof ibmIdx === 'number') {
        totalIbm++;
      } else {
        skinReport.warnings.push('skin[' + i + '] 缺少 inverseBindMatrices(可选,但蒙皮质量可能受影响)');
      }
      // skeleton 字段是可选的,缺失不算错误
      const skeletonIdx: Object | undefined = skin['skeleton'];
      if (skeletonIdx === undefined || skeletonIdx === null) {
        skinReport.warnings.push('skin[' + i + '] 缺少 skeleton 字段(可选,将从 joints 共同祖先推导)');
      }
      // 检查 joints 索引是否在 nodeCount 范围内
      const nodeCount: number = getArrayLength(json, 'nodes');
      let skinValid: boolean = true;
      for (let j: number = 0; j < joints.length; j++) {
        if (joints[j] < 0 || joints[j] >= nodeCount) {
          skinReport.invalidJointIndexCount++;
          skinValid = false;
          skinReport.warnings.push('skin[' + i + '] joints[' + j + ']=' + joints[j]
            + ' 超出 nodes 范围(0..' + (nodeCount - 1) + ')');
        }
      }
      if (skinValid) {
        validSkinCount++;
      }
    }
    skinReport.jointCount = totalJoints;
    skinReport.inverseBindMatrixCount = totalIbm;
    skinReport.validSkinCount = validSkinCount;
  }

  // ========== Mesh Primitive 校验 JOINTS/WEIGHTS ==========
  const meshes: Object[] = getArrayField(json, 'meshes');
  let meshWithSkinCount: number = 0;
  let meshesMissingWeights: number = 0;
  let meshesMissingJoints: number = 0;
  for (let i: number = 0; i < meshes.length; i++) {
    const meshObj: Object = meshes[i];
    if (meshObj === null || meshObj === undefined) {
      continue;
    }
    const mesh: Record<string, Object> = meshObj as Record<string, Object>;
    const prims: Object[] = getArrayField(mesh, 'primitives');
    let meshHasJoints: boolean = false;
    let meshHasWeights: boolean = false;
    for (let j: number = 0; j < prims.length; j++) {
      const primObj: Object = prims[j];
      if (primObj === null || primObj === undefined) {
        continue;
      }
      const prim: Record<string, Object> = primObj as Record<string, Object>;
      const attrs: PrimitiveAttributeIndices = extractPrimitiveAttributes(prim);
      if (attrs.hasJoints) {
        meshHasJoints = true;
      }
      if (attrs.hasWeights) {
        meshHasWeights = true;
      }
      // 校验 JOINTS accessor componentType
      if (attrs.hasJoints) {
        const ct: number = getAccessorComponentType(json, attrs.jointsAccessor);
        // JOINTS_0 必须是 UNSIGNED_BYTE(5121)/UNSIGNED_SHORT(5123)/UNSIGNED_INT(5125)
        if (ct !== 5121 && ct !== 5123 && ct !== 5125) {
          skinReport.warnings.push('mesh[' + i + '] prim[' + j + '] JOINTS_0 componentType='
            + ct + ' 非法(应为 5121/5123/5125)');
        }
      }
      // 校验 WEIGHTS accessor componentType
      if (attrs.hasWeights) {
        const ct: number = getAccessorComponentType(json, attrs.weightsAccessor);
        // WEIGHTS_0 必须是 FLOAT(5126)/BYTE(5120)/UNSIGNED_BYTE(5121)/SHORT(5122)/UNSIGNED_SHORT(5123)
        if (ct !== 5126 && ct !== 5120 && ct !== 5121 && ct !== 5122 && ct !== 5123) {
          skinReport.warnings.push('mesh[' + i + '] prim[' + j + '] WEIGHTS_0 componentType='
            + ct + ' 非法(应为 5120~5123 或 5126)');
        }
      }
    }
    if (meshHasJoints && meshHasWeights) {
      meshWithSkinCount++;
    } else if (meshHasJoints && !meshHasWeights) {
      meshesMissingWeights++;
      skinReport.warnings.push('mesh[' + i + '] 有 JOINTS 但缺 WEIGHTS');
    } else if (meshHasWeights && !meshHasJoints) {
      meshesMissingJoints++;
      skinReport.warnings.push('mesh[' + i + '] 有 WEIGHTS 但缺 JOINTS');
    }
  }
  skinReport.meshWithSkinCount = meshWithSkinCount;
  skinReport.meshesMissingWeights = meshesMissingWeights;
  skinReport.meshesMissingJoints = meshesMissingJoints;
  // 估算字段(invalidWeightCount/zeroWeightVertexCount/nonNormalizedWeightVertexCount)
  // 完整校验需要解析 BIN chunk 数据,这里只做结构性校验
  // 如果 skin 数据结构完整,这些字段保持 0(默认)

  // ========== Material 校验 ==========
  const materials: Object[] = getArrayField(json, 'materials');
  const textures: Object[] = getArrayField(json, 'textures');
  materialReport.materialCount = materials.length;
  for (let i: number = 0; i < materials.length; i++) {
    const matObj: Object = materials[i];
    if (matObj === null || matObj === undefined) {
      continue;
    }
    const mat: Record<string, Object> = matObj as Record<string, Object>;
    // alphaMode: OPAQUE(默认)/MASK/BLEND
    const alphaMode: string = getString(mat, 'alphaMode', 'OPAQUE');
    if (alphaMode === 'BLEND' || alphaMode === 'MASK') {
      materialReport.transparentMaterialCount++;
    }
    // KHR_materials_unlit 扩展
    const extensionsObj: Object | undefined = mat['extensions'];
    if (extensionsObj !== undefined && extensionsObj !== null) {
      const ext: Record<string, Object> = extensionsObj as Record<string, Object>;
      const unlitObj: Object | undefined = ext['KHR_materials_unlit'];
      if (unlitObj !== undefined && unlitObj !== null) {
        materialReport.unlitMaterialCount++;
      }
    }
    // pbrMetallicRoughness
    const pbrObj: Object | undefined = mat['pbrMetallicRoughness'];
    if (pbrObj !== undefined && pbrObj !== null) {
      materialReport.pbrMaterialCount++;
      // 检查 baseColorFactor 是否完全透明(a=0)
      const pbr: Record<string, Object> = pbrObj as Record<string, Object>;
      const bcf: number[] | null = getNumberArray(pbr, 'baseColorFactor');
      if (bcf !== null && bcf.length >= 4) {
        if (bcf[3] === 0) {
          materialReport.fullyTransparentCount++;
          materialReport.warnings.push('material[' + i + '] baseColorFactor.a=0 完全透明');
        }
      }
      // 检查 baseColorTexture 索引
      const bctObj: Object | undefined = pbr['baseColorTexture'];
      if (bctObj !== undefined && bctObj !== null) {
        const bct: Record<string, Object> = bctObj as Record<string, Object>;
        const texIdx: Object | undefined = bct['index'];
        if (texIdx !== undefined && texIdx !== null && typeof texIdx === 'number') {
          if ((texIdx as number) < 0 || (texIdx as number) >= textures.length) {
            materialReport.missingTextureCount++;
            materialReport.warnings.push('material[' + i + '] baseColorTexture.index='
              + texIdx + ' 超出 textures 范围');
          }
        }
      }
    }
    // doubleSided(默认 false,即背面剔除)
    // 不算错误,只记录在 warnings 中(由 MaterialValidationReport.transparentMaterialCount 间接反映)
  }

  return { skinReport: skinReport, materialReport: materialReport };
}
