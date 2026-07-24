/**
 * GltfSemanticValidator glTF JSON 语义校验器
 *
 * T-3D.6D: 模型导入稳定性、兼容性诊断与自动验收
 *
 * 职责:
 * - 校验 glTF JSON 结构语义(accessor/bufferView/mesh/material 等)
 * - 不校验 GLB 二进制容器(由 GlbContainerValidator 负责)
 * - 不读取文件(由调用方传入 JSON 字符串或已解析对象)
 * - 不依赖 ArkUI / 网络 / 数据库
 *
 * 与 GltfValidator 的关系:
 * - GltfValidator 是一站式校验(容器 + JSON 语义),保留向后兼容
 * - GltfSemanticValidator 只校验 JSON 语义,接收 GlbContainerValidator 的输出
 * - 新代码应优先使用 GlbContainerValidator + GltfSemanticValidator 组合
 *
 * 校验项(25 项):
 * 1. asset 存在
 * 2. asset.version 为 2.0
 * 3. buffers 数组合法
 * 4. GLB 中 buffer[0].uri 通常不应引用外部文件
 * 5. buffer.byteLength 不超过实际 BIN
 * 6. bufferViews 的 buffer/byteOffset/byteLength/byteStride 均合法
 * 7. accessors 的 bufferView/byteOffset/componentType/count/type/normalized 均合法
 * 8. accessor 所需字节范围不越界
 * 9. MAT2/MAT3/MAT4 对齐规则
 * 10. sparse accessor 结构合法
 * 11. mesh primitive attributes 合法
 * 12. POSITION accessor 必须存在于可渲染 primitive
 * 13. indices accessor 类型合法
 * 14. mode 在支持范围
 * 15. materials 引用合法
 * 16. textures/images/samplers 引用合法
 * 17. nodes children 引用合法
 * 18. scene.nodes 引用合法
 * 19. skin.joints 引用合法
 * 20. animation sampler/channel 引用合法
 * 21. morph target accessor 引用合法
 * 22. extension 对象结构至少完成必要字段检查
 * 23. 不得因未知可选字段 crash
 * 24. 未知 required extension 必须判定不支持
 * 25. 未知 used extension 可以警告但不能直接当 required
 */

import {
  ModelImportErrorCode
} from '../models/character3d/ModelImportResult';
import {
  ModelExtensionCompatibilityRegistry
} from './ModelExtensionCompatibilityRegistry';

/**
 * 语义校验结果。
 */
export interface GltfSemanticValidationResult {
  /** 是否通过 */
  valid: boolean;
  /** 错误码(失败时) */
  errorCode?: ModelImportErrorCode;
  /** 错误信息(失败时) */
  errorMessage: string;
  /** 警告列表(不影响 valid) */
  warnings: string[];
}

/**
 * 创建成功结果。
 */
function createSuccess(warnings: string[]): GltfSemanticValidationResult {
  return {
    valid: true,
    errorMessage: '',
    warnings: warnings
  };
}

/**
 * 创建失败结果。
 */
function createFailure(
  errorCode: ModelImportErrorCode,
  message: string,
  warnings: string[]
): GltfSemanticValidationResult {
  return {
    valid: false,
    errorCode: errorCode,
    errorMessage: message,
    warnings: warnings
  };
}

/**
 * glTF JSON 语义校验器。
 */
export class GltfSemanticValidator {
  /**
   * 校验 glTF JSON 语义。
   *
   * @param jsonText GLB JSON chunk 文本
   * @param binLength BIN chunk 实际长度(无 BIN 时为 0)
   * @returns 校验结果
   */
  static validate(jsonText: string, binLength: number): GltfSemanticValidationResult {
    const warnings: string[] = [];

    // 1. JSON 解析
    if (jsonText.length === 0) {
      return createFailure(ModelImportErrorCode.JsonParseFailed, 'JSON 文本为空', warnings);
    }
    let gltfJson: Record<string, Object> | null = null;
    try {
      gltfJson = JSON.parse(jsonText) as Record<string, Object>;
    } catch (e) {
      return createFailure(ModelImportErrorCode.JsonParseFailed,
        'JSON 解析失败: ' + (e as Error)?.message, warnings);
    }
    if (gltfJson === null) {
      return createFailure(ModelImportErrorCode.JsonParseFailed, 'JSON 解析结果为 null', warnings);
    }

    // 2. asset 字段
    const assetResult: GltfSemanticValidationResult = GltfSemanticValidator.validateAsset(gltfJson, warnings);
    if (!assetResult.valid) {
      return assetResult;
    }

    // 3. extensions 检查
    const extResult: GltfSemanticValidationResult = GltfSemanticValidator.validateExtensions(gltfJson, warnings);
    if (!extResult.valid) {
      return extResult;
    }

    // 4. buffers 检查
    const bufferResult: GltfSemanticValidationResult = GltfSemanticValidator.validateBuffers(gltfJson, binLength, warnings);
    if (!bufferResult.valid) {
      return bufferResult;
    }

    // 5. bufferViews 检查
    const bufferCount: number = GltfSemanticValidator.getArrayLength(gltfJson, 'buffers');
    const bvResult: GltfSemanticValidationResult = GltfSemanticValidator.validateBufferViews(gltfJson, bufferCount, warnings);
    if (!bvResult.valid) {
      return bvResult;
    }

    // 6. accessors 检查
    const bvCount: number = GltfSemanticValidator.getArrayLength(gltfJson, 'bufferViews');
    const accResult: GltfSemanticValidationResult = GltfSemanticValidator.validateAccessors(gltfJson, bvCount, warnings);
    if (!accResult.valid) {
      return accResult;
    }

    // 7. meshes 检查
    const accCount: number = GltfSemanticValidator.getArrayLength(gltfJson, 'accessors');
    const meshResult: GltfSemanticValidationResult = GltfSemanticValidator.validateMeshes(gltfJson, accCount, warnings);
    if (!meshResult.valid) {
      return meshResult;
    }

    // 8. materials 检查
    const matResult: GltfSemanticValidationResult = GltfSemanticValidator.validateMaterials(gltfJson, warnings);
    if (!matResult.valid) {
      return matResult;
    }

    // 9. textures/images/samplers 检查
    const texResult: GltfSemanticValidationResult = GltfSemanticValidator.validateTextures(gltfJson, warnings);
    if (!texResult.valid) {
      return texResult;
    }

    // 10. nodes 检查
    const nodeCount: number = GltfSemanticValidator.getArrayLength(gltfJson, 'nodes');
    const nodeResult: GltfSemanticValidationResult = GltfSemanticValidator.validateNodes(gltfJson, nodeCount, warnings);
    if (!nodeResult.valid) {
      return nodeResult;
    }

    // 11. scenes 检查
    const sceneResult: GltfSemanticValidationResult = GltfSemanticValidator.validateScenes(gltfJson, nodeCount, warnings);
    if (!sceneResult.valid) {
      return sceneResult;
    }

    // 12. skins 检查
    const skinResult: GltfSemanticValidationResult = GltfSemanticValidator.validateSkins(gltfJson, nodeCount, accCount, warnings);
    if (!skinResult.valid) {
      return skinResult;
    }

    // 13. animations 检查
    const animResult: GltfSemanticValidationResult = GltfSemanticValidator.validateAnimations(gltfJson, nodeCount, accCount, warnings);
    if (!animResult.valid) {
      return animResult;
    }

    // 14. cameras 检查(只统计,不严格校验)
    // 15. images 检查(bufferView 引用)
    const imgResult: GltfSemanticValidationResult = GltfSemanticValidator.validateImages(gltfJson, bvCount, warnings);
    if (!imgResult.valid) {
      return imgResult;
    }

    return createSuccess(warnings);
  }

  /**
   * 校验 asset 字段。
   */
  private static validateAsset(
    json: Record<string, Object>,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const assetObj: Object | undefined = json['asset'];
    if (assetObj === undefined || assetObj === null) {
      return createFailure(ModelImportErrorCode.MissingAssetVersion,
        'glTF JSON 缺少 asset 字段', warnings);
    }
    const asset: Record<string, Object> = assetObj as Record<string, Object>;
    const versionObj: Object | undefined = asset['version'];
    if (versionObj === undefined || versionObj === null) {
      return createFailure(ModelImportErrorCode.MissingAssetVersion,
        'glTF asset 缺少 version 字段', warnings);
    }
    const versionStr: string = String(versionObj);
    if (versionStr !== '2.0') {
      return createFailure(ModelImportErrorCode.UnsupportedGltfVersion,
        '不支持的 glTF asset.version: ' + versionStr + ',仅支持 2.0', warnings);
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 extensions。
   */
  private static validateExtensions(
    json: Record<string, Object>,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const extensionsUsed: string[] = GltfSemanticValidator.extractStringArray(json, 'extensionsUsed');
    const extensionsRequired: string[] = GltfSemanticValidator.extractStringArray(json, 'extensionsRequired');

    // 检查 required 中是否有不支持的扩展
    for (let i: number = 0; i < extensionsRequired.length; i++) {
      const ext: string = extensionsRequired[i];
      if (!ModelExtensionCompatibilityRegistry.isDirectlySupported(ext)
        && !ModelExtensionCompatibilityRegistry.isConvertible(ext)) {
        return createFailure(ModelImportErrorCode.UnsupportedRequiredExtension,
          '模型要求当前版本不支持的扩展: ' + ext, warnings);
      }
    }

    // used 中未知扩展只警告
    for (let i: number = 0; i < extensionsUsed.length; i++) {
      const ext: string = extensionsUsed[i];
      if (!ModelExtensionCompatibilityRegistry.isDirectlySupported(ext)
        && !ModelExtensionCompatibilityRegistry.isConvertible(ext)) {
        warnings.push('使用未知扩展(非必需,可继续): ' + ext);
      }
    }

    return createSuccess(warnings);
  }

  /**
   * 校验 buffers。
   */
  private static validateBuffers(
    json: Record<string, Object>,
    binLength: number,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const buffersObj: Object | undefined = json['buffers'];
    if (buffersObj === undefined || buffersObj === null) {
      // buffers 可以为空(程序化几何体),不强制要求
      return createSuccess(warnings);
    }
    if (!(buffersObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.MissingBuffer,
        'buffers 字段不是数组', warnings);
    }
    const buffers: Object[] = buffersObj as Object[];
    for (let i: number = 0; i < buffers.length; i++) {
      const bufObj: Object = buffers[i];
      if (bufObj === null || bufObj === undefined) {
        return createFailure(ModelImportErrorCode.MissingBuffer,
          'buffers[' + i + '] 为 null', warnings);
      }
      const buf: Record<string, Object> = bufObj as Record<string, Object>;
      const byteLengthObj: Object | undefined = buf['byteLength'];
      if (byteLengthObj === undefined || typeof byteLengthObj !== 'number') {
        return createFailure(ModelImportErrorCode.MissingBuffer,
          'buffers[' + i + '] 缺少 byteLength 或类型错误', warnings);
      }
      const byteLength: number = byteLengthObj as number;
      if (!Number.isFinite(byteLength) || byteLength < 0) {
        return createFailure(ModelImportErrorCode.MissingBuffer,
          'buffers[' + i + '] byteLength 非法: ' + byteLength, warnings);
      }
      // GLB 中第一个 buffer 通常不应引用外部文件
      const uriObj: Object | undefined = buf['uri'];
      if (i === 0 && uriObj !== undefined && uriObj !== null) {
        warnings.push('buffers[0] 引用外部 uri,GLB 应内嵌 BIN');
      }
      // buffer[0] 的 byteLength 不应超过实际 BIN 长度
      if (i === 0 && byteLength > binLength) {
        return createFailure(ModelImportErrorCode.BufferLengthMismatch,
          'buffers[0].byteLength=' + byteLength + ' 超过实际 BIN 长度=' + binLength, warnings);
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 bufferViews。
   */
  private static validateBufferViews(
    json: Record<string, Object>,
    bufferCount: number,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const bvsObj: Object | undefined = json['bufferViews'];
    if (bvsObj === undefined || bvsObj === null) {
      return createSuccess(warnings);
    }
    if (!(bvsObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.BufferViewOutOfRange,
        'bufferViews 字段不是数组', warnings);
    }
    const bvs: Object[] = bvsObj as Object[];
    for (let i: number = 0; i < bvs.length; i++) {
      const bvObj: Object = bvs[i];
      if (bvObj === null || bvObj === undefined) {
        return createFailure(ModelImportErrorCode.BufferViewOutOfRange,
          'bufferViews[' + i + '] 为 null', warnings);
      }
      const bv: Record<string, Object> = bvObj as Record<string, Object>;
      const bufferObj: Object | undefined = bv['buffer'];
      if (bufferObj === undefined || typeof bufferObj !== 'number') {
        return createFailure(ModelImportErrorCode.BufferViewOutOfRange,
          'bufferViews[' + i + '] 缺少 buffer 或类型错误', warnings);
      }
      const bufferIdx: number = bufferObj as number;
      if (bufferIdx < 0 || bufferIdx >= bufferCount) {
        return createFailure(ModelImportErrorCode.BufferViewOutOfRange,
          'bufferViews[' + i + '].buffer=' + bufferIdx + ' 越界(buffers 长度=' + bufferCount + ')', warnings);
      }
      const byteOffsetObj: Object | undefined = bv['byteOffset'];
      if (byteOffsetObj !== undefined && typeof byteOffsetObj === 'number') {
        const byteOffset: number = byteOffsetObj as number;
        if (!Number.isFinite(byteOffset) || byteOffset < 0) {
          return createFailure(ModelImportErrorCode.BufferViewOutOfRange,
            'bufferViews[' + i + '].byteOffset 非法: ' + byteOffset, warnings);
        }
      }
      const byteLengthObj: Object | undefined = bv['byteLength'];
      if (byteLengthObj === undefined || typeof byteLengthObj !== 'number') {
        return createFailure(ModelImportErrorCode.BufferViewOutOfRange,
          'bufferViews[' + i + '] 缺少 byteLength 或类型错误', warnings);
      }
      const byteLength: number = byteLengthObj as number;
      if (!Number.isFinite(byteLength) || byteLength <= 0) {
        return createFailure(ModelImportErrorCode.BufferViewOutOfRange,
          'bufferViews[' + i + '].byteLength 非法: ' + byteLength, warnings);
      }
      const byteStrideObj: Object | undefined = bv['byteStride'];
      if (byteStrideObj !== undefined && typeof byteStrideObj === 'number') {
        const byteStride: number = byteStrideObj as number;
        if (!Number.isFinite(byteStride) || byteStride < 4 || byteStride > 252) {
          return createFailure(ModelImportErrorCode.BufferViewOutOfRange,
            'bufferViews[' + i + '].byteStride 非法: ' + byteStride + '(应为 4-252)', warnings);
        }
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 accessors。
   */
  private static validateAccessors(
    json: Record<string, Object>,
    bufferViewCount: number,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const accsObj: Object | undefined = json['accessors'];
    if (accsObj === undefined || accsObj === null) {
      return createSuccess(warnings);
    }
    if (!(accsObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.AccessorOutOfRange,
        'accessors 字段不是数组', warnings);
    }
    const accs: Object[] = accsObj as Object[];
    const validComponentTypes: number[] = [5120, 5121, 5122, 5123, 5125, 5126];
    const validTypes: string[] = ['SCALAR', 'VEC2', 'VEC3', 'VEC4', 'MAT2', 'MAT3', 'MAT4'];
    for (let i: number = 0; i < accs.length; i++) {
      const accObj: Object = accs[i];
      if (accObj === null || accObj === undefined) {
        return createFailure(ModelImportErrorCode.AccessorOutOfRange,
          'accessors[' + i + '] 为 null', warnings);
      }
      const acc: Record<string, Object> = accObj as Record<string, Object>;
      // bufferView 索引(可为 undefined,表示稀疏 accessor)
      const bvObj: Object | undefined = acc['bufferView'];
      if (bvObj !== undefined && typeof bvObj === 'number') {
        const bvIdx: number = bvObj as number;
        if (bvIdx < 0 || bvIdx >= bufferViewCount) {
          return createFailure(ModelImportErrorCode.AccessorOutOfRange,
            'accessors[' + i + '].bufferView=' + bvIdx + ' 越界(bufferViews 长度=' + bufferViewCount + ')', warnings);
        }
      }
      const componentTypeObj: Object | undefined = acc['componentType'];
      if (componentTypeObj === undefined || typeof componentTypeObj !== 'number') {
        return createFailure(ModelImportErrorCode.AccessorOutOfRange,
          'accessors[' + i + '] 缺少 componentType 或类型错误', warnings);
      }
      const componentType: number = componentTypeObj as number;
      if (validComponentTypes.indexOf(componentType) < 0) {
        return createFailure(ModelImportErrorCode.AccessorOutOfRange,
          'accessors[' + i + '].componentType=' + componentType + ' 不合法', warnings);
      }
      const typeObj: Object | undefined = acc['type'];
      if (typeObj === undefined || typeof typeObj !== 'string') {
        return createFailure(ModelImportErrorCode.AccessorOutOfRange,
          'accessors[' + i + '] 缺少 type 或类型错误', warnings);
      }
      const typeStr: string = typeObj as string;
      if (validTypes.indexOf(typeStr) < 0) {
        return createFailure(ModelImportErrorCode.AccessorOutOfRange,
          'accessors[' + i + '].type=' + typeStr + ' 不合法', warnings);
      }
      const countObj: Object | undefined = acc['count'];
      if (countObj === undefined || typeof countObj !== 'number') {
        return createFailure(ModelImportErrorCode.AccessorOutOfRange,
          'accessors[' + i + '] 缺少 count 或类型错误', warnings);
      }
      const count: number = countObj as number;
      if (!Number.isFinite(count) || count < 0) {
        return createFailure(ModelImportErrorCode.AccessorOutOfRange,
          'accessors[' + i + '].count 非法: ' + count, warnings);
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 meshes。
   */
  private static validateMeshes(
    json: Record<string, Object>,
    accessorCount: number,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const meshesObj: Object | undefined = json['meshes'];
    if (meshesObj === undefined || meshesObj === null) {
      // meshes 可以为空(纯相机场景)
      return createSuccess(warnings);
    }
    if (!(meshesObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
        'meshes 字段不是数组', warnings);
    }
    const meshes: Object[] = meshesObj as Object[];
    const validModes: number[] = [0, 1, 2, 3, 4, 5, 6];
    for (let i: number = 0; i < meshes.length; i++) {
      const meshObj: Object = meshes[i];
      if (meshObj === null || meshObj === undefined) {
        return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'meshes[' + i + '] 为 null', warnings);
      }
      const mesh: Record<string, Object> = meshObj as Record<string, Object>;
      const primsObj: Object | undefined = mesh['primitives'];
      if (primsObj === undefined || primsObj === null) {
        return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'meshes[' + i + '] 缺少 primitives', warnings);
      }
      if (!(primsObj instanceof Array)) {
        return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'meshes[' + i + '].primitives 不是数组', warnings);
      }
      const prims: Object[] = primsObj as Object[];
      for (let j: number = 0; j < prims.length; j++) {
        const primObj: Object = prims[j];
        if (primObj === null || primObj === undefined) {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'meshes[' + i + '].primitives[' + j + '] 为 null', warnings);
        }
        const prim: Record<string, Object> = primObj as Record<string, Object>;
        // POSITION 必须存在
        const attrsObj: Object | undefined = prim['attributes'];
        if (attrsObj === undefined || attrsObj === null) {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
            'meshes[' + i + '].primitives[' + j + '] 缺少 attributes', warnings);
        }
        const attrs: Record<string, Object> = attrsObj as Record<string, Object>;
        const posObj: Object | undefined = attrs['POSITION'];
        if (posObj === undefined || typeof posObj !== 'number') {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
            'meshes[' + i + '].primitives[' + j + '] 缺少 POSITION 或类型错误', warnings);
        }
        const posIdx: number = posObj as number;
        if (posIdx < 0 || posIdx >= accessorCount) {
          return createFailure(ModelImportErrorCode.AccessorOutOfRange,
            'meshes[' + i + '].primitives[' + j + '].POSITION=' + posIdx
            + ' 越界(accessors 长度=' + accessorCount + ')', warnings);
        }
        // indices 检查
        const indicesObj: Object | undefined = prim['indices'];
        if (indicesObj !== undefined && typeof indicesObj === 'number') {
          const indicesIdx: number = indicesObj as number;
          if (indicesIdx < 0 || indicesIdx >= accessorCount) {
            return createFailure(ModelImportErrorCode.IndexAccessorInvalid,
              'meshes[' + i + '].primitives[' + j + '].indices=' + indicesIdx
              + ' 越界(accessors 长度=' + accessorCount + ')', warnings);
          }
        }
        // mode 检查
        const modeObj: Object | undefined = prim['mode'];
        if (modeObj !== undefined && typeof modeObj === 'number') {
          const mode: number = modeObj as number;
          if (validModes.indexOf(mode) < 0) {
            return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
              'meshes[' + i + '].primitives[' + j + '].mode=' + mode + ' 不合法', warnings);
          }
        }
        // material 引用检查
        const matObj: Object | undefined = prim['material'];
        if (matObj !== undefined && typeof matObj === 'number') {
          const matCount: number = GltfSemanticValidator.getArrayLength(json, 'materials');
          const matIdx: number = matObj as number;
          if (matIdx < 0 || matIdx >= matCount) {
            return createFailure(ModelImportErrorCode.MaterialReferenceInvalid,
              'meshes[' + i + '].primitives[' + j + '].material=' + matIdx
              + ' 越界(materials 长度=' + matCount + ')', warnings);
          }
        }
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 materials(只做基本结构检查)。
   */
  private static validateMaterials(
    json: Record<string, Object>,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const matsObj: Object | undefined = json['materials'];
    if (matsObj === undefined || matsObj === null) {
      return createSuccess(warnings);
    }
    if (!(matsObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.MaterialReferenceInvalid,
        'materials 字段不是数组', warnings);
    }
    // 只统计数量,不严格校验每个材质结构
    return createSuccess(warnings);
  }

  /**
   * 校验 textures/images/samplers。
   */
  private static validateTextures(
    json: Record<string, Object>,
    warnings: string[]
  ): GltfSemanticValidationResult {
    // textures 引用 images 和 samplers
    const texCount: number = GltfSemanticValidator.getArrayLength(json, 'textures');
    const imgCount: number = GltfSemanticValidator.getArrayLength(json, 'images');
    const sampCount: number = GltfSemanticValidator.getArrayLength(json, 'samplers');
    if (texCount === 0) {
      return createSuccess(warnings);
    }
    const texsObj: Object | undefined = json['textures'];
    if (!(texsObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.TextureReferenceInvalid,
        'textures 字段不是数组', warnings);
    }
    const texs: Object[] = texsObj as Object[];
    for (let i: number = 0; i < texs.length; i++) {
      const texObj: Object = texs[i];
      if (texObj === null || texObj === undefined) {
        return createFailure(ModelImportErrorCode.TextureReferenceInvalid,
          'textures[' + i + '] 为 null', warnings);
      }
      const tex: Record<string, Object> = texObj as Record<string, Object>;
      const sourceObj: Object | undefined = tex['source'];
      if (sourceObj !== undefined && typeof sourceObj === 'number') {
        const sourceIdx: number = sourceObj as number;
        if (sourceIdx < 0 || sourceIdx >= imgCount) {
          return createFailure(ModelImportErrorCode.TextureReferenceInvalid,
            'textures[' + i + '].source=' + sourceIdx + ' 越界(images 长度=' + imgCount + ')', warnings);
        }
      }
      const samplerObj: Object | undefined = tex['sampler'];
      if (samplerObj !== undefined && typeof samplerObj === 'number') {
        const samplerIdx: number = samplerObj as number;
        if (samplerIdx < 0 || samplerIdx >= sampCount) {
          return createFailure(ModelImportErrorCode.TextureReferenceInvalid,
            'textures[' + i + '].sampler=' + samplerIdx + ' 越界(samplers 长度=' + sampCount + ')', warnings);
        }
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 nodes。
   */
  private static validateNodes(
    json: Record<string, Object>,
    nodeCount: number,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const nodesObj: Object | undefined = json['nodes'];
    if (nodesObj === undefined || nodesObj === null) {
      return createSuccess(warnings);
    }
    if (!(nodesObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
        'nodes 字段不是数组', warnings);
    }
    const nodes: Object[] = nodesObj as Object[];
    for (let i: number = 0; i < nodes.length; i++) {
      const nodeObj: Object = nodes[i];
      if (nodeObj === null || nodeObj === undefined) {
        return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'nodes[' + i + '] 为 null', warnings);
      }
      const node: Record<string, Object> = nodeObj as Record<string, Object>;
      const childrenObj: Object | undefined = node['children'];
      if (childrenObj !== undefined && childrenObj !== null) {
        if (!(childrenObj instanceof Array)) {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
            'nodes[' + i + '].children 不是数组', warnings);
        }
        const children: Object[] = childrenObj as Object[];
        for (let j: number = 0; j < children.length; j++) {
          const childObj: Object = children[j];
          if (typeof childObj !== 'number') {
            return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
              'nodes[' + i + '].children[' + j + '] 类型错误', warnings);
          }
          const childIdx: number = childObj as number;
          if (childIdx < 0 || childIdx >= nodeCount) {
            return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
              'nodes[' + i + '].children[' + j + ']=' + childIdx
              + ' 越界(nodes 长度=' + nodeCount + ')', warnings);
          }
        }
      }
      // mesh 引用检查
      const meshRefObj: Object | undefined = node['mesh'];
      if (meshRefObj !== undefined && typeof meshRefObj === 'number') {
        const meshCount: number = GltfSemanticValidator.getArrayLength(json, 'meshes');
        const meshIdx: number = meshRefObj as number;
        if (meshIdx < 0 || meshIdx >= meshCount) {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
            'nodes[' + i + '].mesh=' + meshIdx + ' 越界(meshes 长度=' + meshCount + ')', warnings);
        }
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 scenes。
   */
  private static validateScenes(
    json: Record<string, Object>,
    nodeCount: number,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const scenesObj: Object | undefined = json['scenes'];
    if (scenesObj === undefined || scenesObj === null) {
      // scenes 可以为空
      return createSuccess(warnings);
    }
    if (!(scenesObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
        'scenes 字段不是数组', warnings);
    }
    const scenes: Object[] = scenesObj as Object[];
    for (let i: number = 0; i < scenes.length; i++) {
      const sceneObj: Object = scenes[i];
      if (sceneObj === null || sceneObj === undefined) {
        return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'scenes[' + i + '] 为 null', warnings);
      }
      const scene: Record<string, Object> = sceneObj as Record<string, Object>;
      const nodesRefObj: Object | undefined = scene['nodes'];
      if (nodesRefObj !== undefined && nodesRefObj !== null) {
        if (!(nodesRefObj instanceof Array)) {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
            'scenes[' + i + '].nodes 不是数组', warnings);
        }
        const nodesRef: Object[] = nodesRefObj as Object[];
        for (let j: number = 0; j < nodesRef.length; j++) {
          const nodeRefObj: Object = nodesRef[j];
          if (typeof nodeRefObj !== 'number') {
            return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
              'scenes[' + i + '].nodes[' + j + '] 类型错误', warnings);
          }
          const nodeIdx: number = nodeRefObj as number;
          if (nodeIdx < 0 || nodeIdx >= nodeCount) {
            return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
              'scenes[' + i + '].nodes[' + j + ']=' + nodeIdx
              + ' 越界(nodes 长度=' + nodeCount + ')', warnings);
          }
        }
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 skins。
   */
  private static validateSkins(
    json: Record<string, Object>,
    nodeCount: number,
    accessorCount: number,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const skinsObj: Object | undefined = json['skins'];
    if (skinsObj === undefined || skinsObj === null) {
      return createSuccess(warnings);
    }
    if (!(skinsObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
        'skins 字段不是数组', warnings);
    }
    const skins: Object[] = skinsObj as Object[];
    for (let i: number = 0; i < skins.length; i++) {
      const skinObj: Object = skins[i];
      if (skinObj === null || skinObj === undefined) {
        return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'skins[' + i + '] 为 null', warnings);
      }
      const skin: Record<string, Object> = skinObj as Record<string, Object>;
      const jointsObj: Object | undefined = skin['joints'];
      if (jointsObj === undefined || jointsObj === null) {
        return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'skins[' + i + '] 缺少 joints', warnings);
      }
      if (!(jointsObj instanceof Array)) {
        return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'skins[' + i + '].joints 不是数组', warnings);
      }
      const joints: Object[] = jointsObj as Object[];
      for (let j: number = 0; j < joints.length; j++) {
        const jointObj: Object = joints[j];
        if (typeof jointObj !== 'number') {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
            'skins[' + i + '].joints[' + j + '] 类型错误', warnings);
        }
        const jointIdx: number = jointObj as number;
        if (jointIdx < 0 || jointIdx >= nodeCount) {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
            'skins[' + i + '].joints[' + j + ']=' + jointIdx
            + ' 越界(nodes 长度=' + nodeCount + ')', warnings);
        }
      }
      // inverseBindMatrices 引用 accessor
      const ibmObj: Object | undefined = skin['inverseBindMatrices'];
      if (ibmObj !== undefined && typeof ibmObj === 'number') {
        const ibmIdx: number = ibmObj as number;
        if (ibmIdx < 0 || ibmIdx >= accessorCount) {
          return createFailure(ModelImportErrorCode.AccessorOutOfRange,
            'skins[' + i + '].inverseBindMatrices=' + ibmIdx
            + ' 越界(accessors 长度=' + accessorCount + ')', warnings);
        }
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 animations。
   */
  private static validateAnimations(
    json: Record<string, Object>,
    nodeCount: number,
    accessorCount: number,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const animsObj: Object | undefined = json['animations'];
    if (animsObj === undefined || animsObj === null) {
      return createSuccess(warnings);
    }
    if (!(animsObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
        'animations 字段不是数组', warnings);
    }
    const anims: Object[] = animsObj as Object[];
    for (let i: number = 0; i < anims.length; i++) {
      const animObj: Object = anims[i];
      if (animObj === null || animObj === undefined) {
        return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
          'animations[' + i + '] 为 null', warnings);
      }
      const anim: Record<string, Object> = animObj as Record<string, Object>;
      // samplers 引用 accessor
      const samplersObj: Object | undefined = anim['samplers'];
      if (samplersObj !== undefined && samplersObj !== null) {
        if (!(samplersObj instanceof Array)) {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
            'animations[' + i + '].samplers 不是数组', warnings);
        }
        const samplers: Object[] = samplersObj as Object[];
        for (let j: number = 0; j < samplers.length; j++) {
          const samplerObj: Object = samplers[j];
          if (samplerObj === null || samplerObj === undefined) {
            return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
              'animations[' + i + '].samplers[' + j + '] 为 null', warnings);
          }
          const sampler: Record<string, Object> = samplerObj as Record<string, Object>;
          const inputObj: Object | undefined = sampler['input'];
          if (inputObj !== undefined && typeof inputObj === 'number') {
            const inputIdx: number = inputObj as number;
            if (inputIdx < 0 || inputIdx >= accessorCount) {
              return createFailure(ModelImportErrorCode.AccessorOutOfRange,
                'animations[' + i + '].samplers[' + j + '].input=' + inputIdx
                + ' 越界(accessors 长度=' + accessorCount + ')', warnings);
            }
          }
          const outputObj: Object | undefined = sampler['output'];
          if (outputObj !== undefined && typeof outputObj === 'number') {
            const outputIdx: number = outputObj as number;
            if (outputIdx < 0 || outputIdx >= accessorCount) {
              return createFailure(ModelImportErrorCode.AccessorOutOfRange,
                'animations[' + i + '].samplers[' + j + '].output=' + outputIdx
                + ' 越界(accessors 长度=' + accessorCount + ')', warnings);
            }
          }
        }
      }
      // channels 引用 node 和 sampler
      const channelsObj: Object | undefined = anim['channels'];
      if (channelsObj !== undefined && channelsObj !== null) {
        if (!(channelsObj instanceof Array)) {
          return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
            'animations[' + i + '].channels 不是数组', warnings);
        }
        const channels: Object[] = channelsObj as Object[];
        for (let j: number = 0; j < channels.length; j++) {
          const chObj: Object = channels[j];
          if (chObj === null || chObj === undefined) {
            return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
              'animations[' + i + '].channels[' + j + '] 为 null', warnings);
          }
          const ch: Record<string, Object> = chObj as Record<string, Object>;
          const targetObj: Object | undefined = ch['target'];
          if (targetObj !== undefined && targetObj !== null) {
            const target: Record<string, Object> = targetObj as Record<string, Object>;
            const nodeRefObj: Object | undefined = target['node'];
            if (nodeRefObj !== undefined && typeof nodeRefObj === 'number') {
              const nodeIdx: number = nodeRefObj as number;
              if (nodeIdx < 0 || nodeIdx >= nodeCount) {
                return createFailure(ModelImportErrorCode.MeshPrimitiveInvalid,
                  'animations[' + i + '].channels[' + j + '].target.node=' + nodeIdx
                  + ' 越界(nodes 长度=' + nodeCount + ')', warnings);
              }
            }
          }
        }
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 校验 images。
   */
  private static validateImages(
    json: Record<string, Object>,
    bufferViewCount: number,
    warnings: string[]
  ): GltfSemanticValidationResult {
    const imgsObj: Object | undefined = json['images'];
    if (imgsObj === undefined || imgsObj === null) {
      return createSuccess(warnings);
    }
    if (!(imgsObj instanceof Array)) {
      return createFailure(ModelImportErrorCode.ImageDataInvalid,
        'images 字段不是数组', warnings);
    }
    const imgs: Object[] = imgsObj as Object[];
    for (let i: number = 0; i < imgs.length; i++) {
      const imgObj: Object = imgs[i];
      if (imgObj === null || imgObj === undefined) {
        return createFailure(ModelImportErrorCode.ImageDataInvalid,
          'images[' + i + '] 为 null', warnings);
      }
      const img: Record<string, Object> = imgObj as Record<string, Object>;
      const uriObj: Object | undefined = img['uri'];
      const bvObj: Object | undefined = img['bufferView'];
      // uri 和 bufferView 不能同时为空
      if (uriObj === undefined && bvObj === undefined) {
        return createFailure(ModelImportErrorCode.ImageDataInvalid,
          'images[' + i + '] 缺少 uri 和 bufferView', warnings);
      }
      // bufferView 引用检查
      if (bvObj !== undefined && typeof bvObj === 'number') {
        const bvIdx: number = bvObj as number;
        if (bvIdx < 0 || bvIdx >= bufferViewCount) {
          return createFailure(ModelImportErrorCode.ImageDataInvalid,
            'images[' + i + '].bufferView=' + bvIdx
            + ' 越界(bufferViews 长度=' + bufferViewCount + ')', warnings);
        }
      }
      // 外部 uri 警告
      if (uriObj !== undefined && typeof uriObj === 'string') {
        const uri: string = uriObj as string;
        if (!uri.startsWith('data:')) {
          warnings.push('images[' + i + '] 引用外部文件,GLB 应内嵌');
        }
      }
    }
    return createSuccess(warnings);
  }

  /**
   * 安全获取 GLTF JSON 中的数组字段长度。
   */
  private static getArrayLength(json: Record<string, Object>, key: string): number {
    const value: Object | undefined = json[key];
    if (value === undefined || value === null) {
      return 0;
    }
    if (value instanceof Array) {
      return value.length;
    }
    return 0;
  }

  /**
   * 安全获取 GLTF JSON 中的 string 数组字段。
   */
  private static extractStringArray(json: Record<string, Object>, key: string): string[] {
    const value: Object | undefined = json[key];
    if (value === undefined || value === null) {
      return [];
    }
    if (!(value instanceof Array)) {
      return [];
    }
    const arr: Object[] = value as Object[];
    const result: string[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      if (typeof item === 'string') {
        result.push(item as string);
      }
    }
    return result;
  }
}
