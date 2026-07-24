/**
 * GltfValidator GLB/GLTF 模型格式验证器
 *
 * 临时开发测试: T-3D.3 模型兼容性检测;T-3D.4A Bounds 与扩展检测
 *
 * 职责:
 * - 验证 GLB 2.0 文件头(magic + version + length)
 * - 验证 GLB chunk 结构(JSON chunk + BIN chunk)
 * - 解析 GLTF JSON 必需字段(asset.version)
 * - 提取模型摘要信息(网格/材质/动画/节点/相机数量)
 * - T-3D.4A: 从 POSITION accessor 聚合 min/max 计算 Bounds
 * - T-3D.4A: 检查 extensionsUsed / extensionsRequired,识别不支持的必需扩展
 * - 不读取文件(由调用方传入 ArrayBuffer)
 * - 不依赖 ArkUI / 网络 / 数据库
 *
 * 验证规则:
 * - 文件至少 20 字节(12 header + 8 JSON chunk header + 最小 JSON)
 * - magic 必须为 0x46546C67 ("glTF")
 * - version 必须为 2(GLB 2.0)
 * - length 必须等于 buffer.byteLength
 * - 第一个 chunk 必须是 JSON(0x4E4F534A)
 * - JSON 必须可解析且包含 asset.version
 * - BIN chunk(0x004E4942)可选但推荐
 * - T-3D.4A: 必需扩展若包含不支持项,valid=true 但 unsupportedRequiredExtensions 非空
 *   (由调用方决定是否拒绝;PoC 默认在 service 层拒绝)
 *
 * 不验证的内容(留给 Scene.load):
 * - bufferView/accessor 的具体数据偏移
 * - 纹理图片是否存在
 * - 动画通道是否有效
 */

import { util } from '@kit.ArkTS';
import { computeWorldBounds } from './GltfBoundsCalculator';

const GLB_MAGIC: number = 0x46546C67;       // "glTF"
const GLB_VERSION: number = 2;               // GLB 2.0
const CHUNK_TYPE_JSON: number = 0x4E4F534A;  // "JSON"
const CHUNK_TYPE_BIN: number = 0x004E4942;   // "BIN\0"
const GLB_HEADER_SIZE: number = 12;
const CHUNK_HEADER_SIZE: number = 8;

/**
 * 当前 HarmonyOS ArkGraphics3D 不支持的必需扩展黑名单。
 * 模型若 required 这些扩展,导入阶段必须拒绝(无法自动转换)。
 *
 * T-3D.6C-C: EXT_meshopt_compression 和 KHR_mesh_quantization
 * 已从黑名单移至 CONVERTIBLE_EXTENSIONS,由 Character3DModelCompatibilityService
 * 自动转换为标准 GLB 后再加载。
 */
const UNSUPPORTED_REQUIRED_EXTENSIONS: string[] = [
  'KHR_draco_mesh_compression',
  'KHR_texture_basisu'
];

/**
 * T-3D.6C-C: 可转换的扩展列表。
 *
 * 这些扩展虽然 ArkGraphics 不直接支持,但可以通过预处理管线
 * 转换为标准 GLB 2.0 格式:
 * - EXT_meshopt_compression: 通过 meshoptimizer 解码器还原为未压缩 bufferView
 * - KHR_mesh_quantization: 先测试 ArkGraphics 是否原生支持,不支持则反量化
 *
 * 识别为可转换后,不再立即拒绝,而是由 Character3DModelCompatibilityService 处理。
 */
const CONVERTIBLE_EXTENSIONS: string[] = [
  'EXT_meshopt_compression',
  'KHR_mesh_quantization'
];

/**
 * GLTF 模型摘要信息。
 */
export interface GltfModelInfo {
  /** glTF 版本(如 "2.0") */
  version: string;
  /** 生成器(可选,如 "Blender 3.6" ) */
  generator: string;
  /** 网格数量 */
  meshCount: number;
  /** 材质数量 */
  materialCount: number;
  /** 动画数量 */
  animationCount: number;
  /** 节点数量 */
  nodeCount: number;
  /** 相机数量 */
  cameraCount: number;
  /** 是否包含骨骼蒙皮 */
  hasSkins: boolean;
  /** 是否包含纹理 */
  hasTextures: boolean;
  /** 是否包含形变目标(morph targets) */
  hasMorphTargets: boolean;
  /** BIN chunk 是否存在 */
  hasBinChunk: boolean;
  /** BIN chunk 字节长度(无 BIN chunk 时为 0) */
  binChunkLength: number;
  /** T-3D.4A: 模型包围盒 min [minX, minY, minZ](来自 POSITION accessor 聚合,无数据时为 null) */
  boundsMin: number[] | null;
  /** T-3D.4A: 模型包围盒 max [maxX, maxY, maxZ](来自 POSITION accessor 聚合,无数据时为 null) */
  boundsMax: number[] | null;
  /** T-3D.4A: 使用的扩展列表(extensionsUsed) */
  extensionsUsed: string[];
  /** T-3D.4A: 必需的扩展列表(extensionsRequired) */
  extensionsRequired: string[];
  /** T-3D.4A: 当前运行时不支持的必需扩展列表(用于 UI 显示明确错误) */
  unsupportedRequiredExtensions: string[];
  /** T-3D.6C-C: 可转换的必需扩展列表(如 EXT_meshopt_compression,可由预处理管线转换) */
  convertibleRequiredExtensions: string[];
  /** T-3D.6C-C: 可转换的使用扩展列表(extensionsUsed 中命中 CONVERTIBLE_EXTENSIONS 的) */
  convertibleUsedExtensions: string[];
  /** T-3D.6E: 节点名称列表(用于骨骼自动映射;空字符串表示该节点无 name) */
  nodeNames: string[];
}

/**
 * 验证结果。
 */
export interface GltfValidationResult {
  /** 是否通过验证 */
  valid: boolean;
  /** 验证失败时的错误信息(成功时为空字符串) */
  errorMessage: string;
  /** 模型摘要信息(验证失败时为默认值) */
  modelInfo: GltfModelInfo;
  /** T-4.1: 解析后的 glTF JSON 对象(验证失败时为 null),供 VRMImporter 等下游使用 */
  gltfJson: Record<string, Object> | null;
}

/**
 * T-3D.4A: POSITION accessor 聚合 Bounds 结果。
 */
export interface PositionBoundsResult {
  /** 聚合后的 min [minX, minY, minZ],无数据时为 null */
  min: number[] | null;
  /** 聚合后的 max [maxX, maxY, maxZ],无数据时为 null */
  max: number[] | null;
}

/**
 * 创建空的模型信息(默认值)。
 */
function createEmptyModelInfo(): GltfModelInfo {
  return {
    version: '',
    generator: '',
    meshCount: 0,
    materialCount: 0,
    animationCount: 0,
    nodeCount: 0,
    cameraCount: 0,
    hasSkins: false,
    hasTextures: false,
    hasMorphTargets: false,
    hasBinChunk: false,
    binChunkLength: 0,
    boundsMin: null,
    boundsMax: null,
    extensionsUsed: [],
    extensionsRequired: [],
    unsupportedRequiredExtensions: [],
    convertibleRequiredExtensions: [],
    convertibleUsedExtensions: [],
    nodeNames: []
  };
}

/**
 * 创建失败结果。
 */
function createFailure(message: string): GltfValidationResult {
  return {
    valid: false,
    errorMessage: message,
    modelInfo: createEmptyModelInfo(),
    gltfJson: null
  };
}

/**
 * GLB/GLTF 验证器。
 */
export class GltfValidator {
  /**
   * 验证 GLB 2.0 文件格式并提取模型信息。
   *
   * @param buffer GLB 文件二进制内容
   * @returns 验证结果
   */
  static validate(buffer: ArrayBuffer): GltfValidationResult {
    if (buffer === null || buffer === undefined) {
      return createFailure('buffer 为 null');
    }
    if (buffer.byteLength < GLB_HEADER_SIZE + CHUNK_HEADER_SIZE) {
      return createFailure('文件过小,不是有效的 GLB(少于 20 字节)');
    }

    const view: DataView = new DataView(buffer);

    // 1. 验证 Header
    const magic: number = view.getUint32(0, true);
    if (magic !== GLB_MAGIC) {
      return createFailure('GLB magic 不匹配,不是有效的 glTF 文件');
    }
    const version: number = view.getUint32(4, true);
    if (version !== GLB_VERSION) {
      return createFailure('不支持的 glTF 版本: ' + version + '(仅支持 2.0)');
    }
    const totalLength: number = view.getUint32(8, true);
    if (totalLength !== buffer.byteLength) {
      return createFailure('GLB length 与实际文件大小不匹配: 声明 '
        + totalLength + ', 实际 ' + buffer.byteLength);
    }
    if (totalLength < GLB_HEADER_SIZE) {
      return createFailure('GLB length 小于 header 大小: ' + totalLength);
    }

    // 2. 解析 Chunks(GLB 规范要求第一个 chunk 必须是 JSON)
    let offset: number = GLB_HEADER_SIZE;
    let jsonChunkFound: boolean = false;
    let jsonText: string = '';
    let binChunkFound: boolean = false;
    let binChunkLength: number = 0;
    let chunkIndex: number = 0;

    while (offset + CHUNK_HEADER_SIZE <= buffer.byteLength) {
      const chunkLength: number = view.getUint32(offset, true);
      const chunkType: number = view.getUint32(offset + 4, true);
      const chunkDataStart: number = offset + CHUNK_HEADER_SIZE;
      // 整数溢出保护:chunkLength 与 chunkDataStart 相加不能回绕
      if (chunkLength > buffer.byteLength - chunkDataStart) {
        return createFailure('chunk 数据超出文件范围: offset=' + offset
          + ', length=' + chunkLength);
      }
      const chunkDataEnd: number = chunkDataStart + chunkLength;

      if (chunkDataEnd > buffer.byteLength) {
        return createFailure('chunk 数据超出文件范围: offset=' + offset
          + ', length=' + chunkLength);
      }

      if (chunkType === CHUNK_TYPE_JSON) {
        if (jsonChunkFound) {
          return createFailure('发现多个 JSON chunk');
        }
        if (chunkIndex !== 0) {
          return createFailure('JSON chunk 必须为第一个 chunk(GLB 规范)');
        }
        if (chunkLength === 0) {
          return createFailure('JSON chunk 长度为 0');
        }
        jsonChunkFound = true;
        try {
          jsonText = GltfValidator.decodeUtf8(buffer, chunkDataStart, chunkLength);
        } catch (e) {
          return createFailure('JSON chunk 解码失败: ' + (e as Error)?.message);
        }
      } else if (chunkType === CHUNK_TYPE_BIN) {
        if (binChunkFound) {
          return createFailure('发现多个 BIN chunk');
        }
        binChunkFound = true;
        binChunkLength = chunkLength;
      } else {
        // 未知 chunk 类型,跳过(GLB 规范允许)
      }

      offset = chunkDataEnd;
      chunkIndex++;
      // 4 字节对齐 padding
      while (offset < buffer.byteLength && (offset % 4) !== 0) {
        offset++;
      }
    }

    if (!jsonChunkFound) {
      return createFailure('缺少 JSON chunk');
    }

    // 3. 解析 GLTF JSON
    let gltfJson: Record<string, Object> | null = null;
    try {
      gltfJson = JSON.parse(jsonText) as Record<string, Object>;
    } catch (e) {
      return createFailure('GLTF JSON 解析失败: ' + (e as Error)?.message);
    }
    if (gltfJson === null) {
      return createFailure('GLTF JSON 解析结果为 null');
    }

    // 4. 验证必需字段
    const assetObj: Object | undefined = gltfJson['asset'];
    if (assetObj === undefined || assetObj === null) {
      return createFailure('GLTF JSON 缺少 asset 字段');
    }
    const assetRecord: Record<string, Object> = assetObj as Record<string, Object>;
    const versionStr: Object | undefined = assetRecord['version'];
    if (versionStr === undefined || versionStr === null) {
      return createFailure('GLTF asset 缺少 version 字段');
    }
    const versionString: string = String(versionStr);
    if (versionString !== '2.0') {
      return createFailure('不支持的 glTF asset.version: ' + versionString + '(仅支持 2.0)');
    }

    // 5. T-3D.4A: 提取扩展信息
    const extensionsUsed: string[] = GltfValidator.extractStringArray(gltfJson, 'extensionsUsed');
    const extensionsRequired: string[] = GltfValidator.extractStringArray(gltfJson, 'extensionsRequired');
    const unsupportedRequired: string[] = [];
    const convertibleRequired: string[] = [];
    const convertibleUsed: string[] = [];
    for (let i: number = 0; i < extensionsRequired.length; i++) {
      const ext: string = extensionsRequired[i];
      if (UNSUPPORTED_REQUIRED_EXTENSIONS.indexOf(ext) >= 0) {
        unsupportedRequired.push(ext);
      } else if (CONVERTIBLE_EXTENSIONS.indexOf(ext) >= 0) {
        convertibleRequired.push(ext);
      }
    }
    // T-3D.6C-C: 同时收集 extensionsUsed 中的可转换扩展(可能 used 但未 required)
    for (let i: number = 0; i < extensionsUsed.length; i++) {
      const ext: string = extensionsUsed[i];
      if (CONVERTIBLE_EXTENSIONS.indexOf(ext) >= 0) {
        convertibleUsed.push(ext);
      }
    }

    // 6. T-3D.4A: 从 accessors 聚合 POSITION 的 min/max(计算 Bounds)
    // T-3D.6E: 优先使用带 world transform 的世界 Bounds,失败时回退到局部 Bounds
    let boundsResult: PositionBoundsResult = computeWorldBounds(gltfJson);
    if (boundsResult.min === null || boundsResult.max === null) {
      // 回退:不应用 node transform 的局部 Bounds
      boundsResult = GltfValidator.aggregatePositionBounds(gltfJson);
    }

    // 7. 提取模型信息
    const modelInfo: GltfModelInfo = {
      version: versionString,
      generator: GltfValidator.getStringField(assetRecord, 'generator'),
      meshCount: GltfValidator.getArrayLength(gltfJson, 'meshes'),
      materialCount: GltfValidator.getArrayLength(gltfJson, 'materials'),
      animationCount: GltfValidator.getArrayLength(gltfJson, 'animations'),
      nodeCount: GltfValidator.getArrayLength(gltfJson, 'nodes'),
      cameraCount: GltfValidator.getArrayLength(gltfJson, 'cameras'),
      hasSkins: GltfValidator.getArrayLength(gltfJson, 'skins') > 0,
      hasTextures: GltfValidator.getArrayLength(gltfJson, 'textures') > 0,
      hasMorphTargets: GltfValidator.checkMorphTargets(gltfJson),
      hasBinChunk: binChunkFound,
      binChunkLength: binChunkLength,
      boundsMin: boundsResult.min,
      boundsMax: boundsResult.max,
      extensionsUsed: extensionsUsed,
      extensionsRequired: extensionsRequired,
      unsupportedRequiredExtensions: unsupportedRequired,
      convertibleRequiredExtensions: convertibleRequired,
      convertibleUsedExtensions: convertibleUsed,
      nodeNames: GltfValidator.extractNodeNames(gltfJson)
    };

    return {
      valid: true,
      errorMessage: '',
      modelInfo: modelInfo,
      gltfJson: gltfJson
    };
  }

  /**
   * 解码 UTF-8 字节为字符串。
   * 使用 @kit.ArkTS 的 util.TextDecoder。
   */
  private static decodeUtf8(buffer: ArrayBuffer, start: number, length: number): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buffer, start, length));
  }

  /**
   * 安全获取 Record 中的 string 字段。
   */
  private static getStringField(record: Record<string, Object>, key: string): string {
    const value: Object | undefined = record[key];
    if (value === undefined || value === null) {
      return '';
    }
    return String(value);
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
   * 安全获取 GLTF JSON 中的 string 数组字段(如 extensionsUsed)。
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

  /**
   * T-3D.6E: 提取所有 node 的 name 字段(用于骨骼自动映射)。
   *
   * - nodes 数组中每个元素若有 name 字段则取其值,否则填空字符串
   * - 保持顺序与 nodes 数组一致,索引可用于查 node
   * - 不在此处做名称归一化(由 HumanoidBoneMapper 负责)
   */
  private static extractNodeNames(json: Record<string, Object>): string[] {
    const value: Object | undefined = json['nodes'];
    if (value === undefined || value === null || !(value instanceof Array)) {
      return [];
    }
    const arr: Object[] = value as Object[];
    const result: string[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      const nodeObj: Object = arr[i];
      if (nodeObj === null || nodeObj === undefined) {
        result.push('');
        continue;
      }
      const node: Record<string, Object> = nodeObj as Record<string, Object>;
      const nameObj: Object | undefined = node['name'];
      if (nameObj === undefined || nameObj === null || typeof nameObj !== 'string') {
        result.push('');
        continue;
      }
      result.push(nameObj as string);
    }
    return result;
  }

  /**
   * T-3D.4A: 从 accessors 数组中聚合所有 POSITION accessor 的 min/max。
   *
   * glTF 规范:accessor 的 min/max 是该 accessor 数据的边界。
   * POSITION accessor 的 min/max 是 [x, y, z] 三个分量的最小/最大值。
   * 多个 POSITION accessor 时,需要聚合得到整个模型的包围盒。
   *
   * 通过 primitive.attributes.POSITION 索引到 accessor,避免聚合非 POSITION accessor。
   *
   * @param json GLTF JSON
   * @returns PositionBoundsResult
   */
  private static aggregatePositionBounds(
    json: Record<string, Object>
  ): PositionBoundsResult {
    const accessorsObj: Object | undefined = json['accessors'];
    if (accessorsObj === undefined || accessorsObj === null) {
      return { min: null, max: null } as PositionBoundsResult;
    }
    if (!(accessorsObj instanceof Array)) {
      return { min: null, max: null } as PositionBoundsResult;
    }
    const accessors: Object[] = accessorsObj as Object[];

    // 收集所有被 primitive.attributes.POSITION 引用的 accessor 索引
    const positionAccessorIndices: number[] = GltfValidator.collectPositionAccessorIndices(json);
    if (positionAccessorIndices.length === 0) {
      return { min: null, max: null } as PositionBoundsResult;
    }

    let aggMin: number[] | null = null;
    let aggMax: number[] | null = null;

    for (let i: number = 0; i < positionAccessorIndices.length; i++) {
      const idx: number = positionAccessorIndices[i];
      if (idx < 0 || idx >= accessors.length) {
        continue;
      }
      const accessorObj: Object = accessors[idx];
      if (accessorObj === null || accessorObj === undefined) {
        continue;
      }
      const accessor: Record<string, Object> = accessorObj as Record<string, Object>;

      // 读取 accessor.min(应为 [x, y, z])
      const minObj: Object | undefined = accessor['min'];
      const maxObj: Object | undefined = accessor['max'];
      const minArr: number[] | null = GltfValidator.toNumberArray(minObj);
      const maxArr: number[] | null = GltfValidator.toNumberArray(maxObj);
      if (minArr === null || maxArr === null) {
        continue;
      }
      if (minArr.length < 3 || maxArr.length < 3) {
        continue;
      }

      if (aggMin === null || aggMax === null) {
        aggMin = [minArr[0], minArr[1], minArr[2]];
        aggMax = [maxArr[0], maxArr[1], maxArr[2]];
      } else {
        if (minArr[0] < aggMin[0]) { aggMin[0] = minArr[0]; }
        if (minArr[1] < aggMin[1]) { aggMin[1] = minArr[1]; }
        if (minArr[2] < aggMin[2]) { aggMin[2] = minArr[2]; }
        if (maxArr[0] > aggMax[0]) { aggMax[0] = maxArr[0]; }
        if (maxArr[1] > aggMax[1]) { aggMax[1] = maxArr[1]; }
        if (maxArr[2] > aggMax[2]) { aggMax[2] = maxArr[2]; }
      }
    }

    return { min: aggMin, max: aggMax } as PositionBoundsResult;
  }

  /**
   * 从 meshes[].primitives[].attributes.POSITION 收集所有 POSITION accessor 索引。
   */
  private static collectPositionAccessorIndices(json: Record<string, Object>): number[] {
    const meshesObj: Object | undefined = json['meshes'];
    if (meshesObj === undefined || meshesObj === null) {
      return [];
    }
    if (!(meshesObj instanceof Array)) {
      return [];
    }
    const meshes: Object[] = meshesObj as Object[];
    const indices: number[] = [];
    for (let i: number = 0; i < meshes.length; i++) {
      const mesh: Record<string, Object> = meshes[i] as Record<string, Object>;
      const primitivesObj: Object | undefined = mesh['primitives'];
      if (primitivesObj === undefined || primitivesObj === null) {
        continue;
      }
      if (!(primitivesObj instanceof Array)) {
        continue;
      }
      const primitives: Object[] = primitivesObj as Object[];
      for (let j: number = 0; j < primitives.length; j++) {
        const prim: Record<string, Object> = primitives[j] as Record<string, Object>;
        const attrsObj: Object | undefined = prim['attributes'];
        if (attrsObj === undefined || attrsObj === null) {
          continue;
        }
        const attrs: Record<string, Object> = attrsObj as Record<string, Object>;
        const posIdxObj: Object | undefined = attrs['POSITION'];
        if (posIdxObj === undefined || posIdxObj === null) {
          continue;
        }
        if (typeof posIdxObj === 'number') {
          indices.push(posIdxObj as number);
        }
      }
    }
    return indices;
  }

  /**
   * 将 Object 转为 number[](用于 accessor.min/max 解析)。
   * 失败返回 null。
   */
  private static toNumberArray(obj: Object | undefined): number[] | null {
    if (obj === undefined || obj === null) {
      return null;
    }
    if (!(obj instanceof Array)) {
      return null;
    }
    const arr: Object[] = obj as Object[];
    const result: number[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      if (typeof item === 'number') {
        result.push(item as number);
      } else {
        return null;
      }
    }
    return result;
  }

  /**
   * 检查网格是否包含形变目标(morph targets)。
   */
  private static checkMorphTargets(json: Record<string, Object>): boolean {
    const meshesObj: Object | undefined = json['meshes'];
    if (meshesObj === undefined || meshesObj === null) {
      return false;
    }
    if (!(meshesObj instanceof Array)) {
      return false;
    }
    const meshes: Object[] = meshesObj as Object[];
    for (let i: number = 0; i < meshes.length; i++) {
      const mesh: Record<string, Object> = meshes[i] as Record<string, Object>;
      const primitivesObj: Object | undefined = mesh['primitives'];
      if (primitivesObj === undefined || primitivesObj === null) {
        continue;
      }
      if (!(primitivesObj instanceof Array)) {
        continue;
      }
      const primitives: Object[] = primitivesObj as Object[];
      for (let j: number = 0; j < primitives.length; j++) {
        const prim: Record<string, Object> = primitives[j] as Record<string, Object>;
        const targets: Object | undefined = prim['targets'];
        if (targets !== undefined && targets !== null) {
          if (targets instanceof Array && targets.length > 0) {
            return true;
          }
        }
      }
    }
    return false;
  }
}
