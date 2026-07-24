/**
 * ModelInspector 3D 模型导入前结构扫描器
 *
 * T-3D.6D: 模型导入稳定性、兼容性诊断与自动验收
 *
 * 职责:
 * - 从 GLB 二进制 + JSON 构建 ModelInspectionResult
 * - 统计真实存在的数据(scene/node/mesh/primitive/material/texture/image/sampler/
 *   animation/skin/joint/morph/camera/light/accessor/bufferView/buffer)
 * - 分类扩展(DirectlySupported / Convertible / Unsupported)
 * - 检测材质类型(PBR / Transparent / Unlit)
 * - 检测外部资源引用(buffer.uri / image.uri 非 data:)
 * - 检测内嵌图片(data: URI 或 bufferView 引用)
 * - 不读取文件(由调用方传入 ArrayBuffer)
 * - 不依赖 ArkUI / 网络 / 数据库
 *
 * 调用顺序:
 * 1. GlbContainerValidator.validate(buffer) → 容器校验 + jsonText + binLength
 * 2. ModelInspector.inspect(jsonText, binLength, fileSizeBytes) → ModelInspectionResult
 * 3. GltfSemanticValidator.validate(jsonText, binLength) → 语义校验
 *
 * 只统计真实存在的数据,不得凭文件名猜测模型类型。
 */

import {
  ModelInspectionResult,
  createEmptyInspectionResult
} from '../models/character3d/ModelImportResult';
import {
  ModelExtensionCompatibilityRegistry
} from './ModelExtensionCompatibilityRegistry';

/**
 * 扩展常量(避免重复字符串)。
 */
const EXT_MESHOPT: string = 'EXT_meshopt_compression';
const EXT_MESH_QUANTIZATION: string = 'KHR_mesh_quantization';
const EXT_DRACO: string = 'KHR_draco_mesh_compression';
const EXT_MATERIALS_UNLIT: string = 'KHR_materials_unlit';
const EXT_LIGHTS_PUNCTUAL: string = 'KHR_lights_punctual';

/**
 * 模型结构扫描器。
 */
export class ModelInspector {
  /**
   * 扫描 GLB JSON 文本与 BIN 长度,构建 ModelInspectionResult。
   *
   * @param jsonText GLB JSON chunk 文本(已通过容器校验)
   * @param binLength BIN chunk 实际长度(无 BIN 时为 0)
   * @param fileSizeBytes 文件总字节数(用于报告)
   * @returns 模型扫描结果(只统计真实存在的数据)
   */
  static inspect(
    jsonText: string,
    binLength: number,
    fileSizeBytes: number
  ): ModelInspectionResult {
    const result: ModelInspectionResult = createEmptyInspectionResult();
    result.format = 'glb';
    result.glbVersion = 2;
    result.fileSizeBytes = fileSizeBytes;
    result.declaredBinLength = binLength;
    result.actualBinLength = binLength;

    // JSON 解析失败时返回空结果(format 仍为 'glb')
    let gltfJson: Record<string, Object> | null = null;
    try {
      gltfJson = JSON.parse(jsonText) as Record<string, Object>;
    } catch (_e) {
      result.warnings.push('JSON 解析失败,无法统计结构');
      return result;
    }
    if (gltfJson === null) {
      result.warnings.push('JSON 解析结果为 null,无法统计结构');
      return result;
    }

    // asset 版本
    const assetObj: Object | undefined = gltfJson['asset'];
    if (assetObj !== undefined && assetObj !== null) {
      const asset: Record<string, Object> = assetObj as Record<string, Object>;
      const versionObj: Object | undefined = asset['version'];
      if (versionObj !== undefined && versionObj !== null) {
        result.gltfVersion = String(versionObj);
      }
    }

    // 基础统计
    result.sceneCount = ModelInspector.getArrayLength(gltfJson, 'scenes');
    result.nodeCount = ModelInspector.getArrayLength(gltfJson, 'nodes');
    result.meshCount = ModelInspector.getArrayLength(gltfJson, 'meshes');
    result.materialCount = ModelInspector.getArrayLength(gltfJson, 'materials');
    result.textureCount = ModelInspector.getArrayLength(gltfJson, 'textures');
    result.imageCount = ModelInspector.getArrayLength(gltfJson, 'images');
    result.samplerCount = ModelInspector.getArrayLength(gltfJson, 'samplers');
    result.animationCount = ModelInspector.getArrayLength(gltfJson, 'animations');
    result.skinCount = ModelInspector.getArrayLength(gltfJson, 'skins');
    result.cameraCount = ModelInspector.getArrayLength(gltfJson, 'cameras');
    result.accessorCount = ModelInspector.getArrayLength(gltfJson, 'accessors');
    result.bufferViewCount = ModelInspector.getArrayLength(gltfJson, 'bufferViews');
    result.bufferCount = ModelInspector.getArrayLength(gltfJson, 'buffers');

    // primitive 数量(遍历 meshes.primitives)
    result.primitiveCount = ModelInspector.countPrimitives(gltfJson);

    // joint 总数(所有 skin.joints 聚合,去重)
    result.jointCount = ModelInspector.countTotalJoints(gltfJson);

    // morph target 数量(遍历 meshes.primitives.targets)
    result.morphTargetCount = ModelInspector.countMorphTargets(gltfJson);

    // 灯光数量(KHR_lights_punctual)
    result.lightCount = ModelInspector.countLights(gltfJson);

    // 扩展分类
    const extensionsUsed: string[] = ModelInspector.extractStringArray(gltfJson, 'extensionsUsed');
    const extensionsRequired: string[] = ModelInspector.extractStringArray(gltfJson, 'extensionsRequired');
    result.usedExtensions = extensionsUsed;
    result.requiredExtensions = extensionsRequired;
    for (let i: number = 0; i < extensionsUsed.length; i++) {
      const ext: string = extensionsUsed[i];
      if (ModelExtensionCompatibilityRegistry.isDirectlySupported(ext)) {
        result.directlySupportedExtensions.push(ext);
      } else if (ModelExtensionCompatibilityRegistry.isConvertible(ext)) {
        result.convertibleExtensions.push(ext);
      } else if (ModelExtensionCompatibilityRegistry.isUnsupported(ext)) {
        result.unsupportedExtensions.push(ext);
      }
    }

    // 扩展标记
    result.hasMeshopt = extensionsUsed.indexOf(EXT_MESHOPT) >= 0;
    result.hasMeshQuantization = extensionsUsed.indexOf(EXT_MESH_QUANTIZATION) >= 0;
    result.hasDraco = extensionsUsed.indexOf(EXT_DRACO) >= 0;

    // 外部资源引用检测
    result.hasExternalBuffers = ModelInspector.hasExternalBuffers(gltfJson);
    result.hasExternalImages = ModelInspector.hasExternalImages(gltfJson);
    result.hasEmbeddedImages = ModelInspector.hasEmbeddedImages(gltfJson);

    // 材质分析
    const matAnalysis: MaterialAnalysis = ModelInspector.analyzeMaterials(gltfJson);
    result.hasPbrMaterials = matAnalysis.hasPbr;
    result.hasTransparentMaterials = matAnalysis.hasTransparent;
    result.hasUnlitMaterials = matAnalysis.hasUnlit;

    return result;
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

  /**
   * 统计 primitive 数量(遍历所有 mesh 的 primitives)。
   */
  private static countPrimitives(json: Record<string, Object>): number {
    const meshesObj: Object | undefined = json['meshes'];
    if (meshesObj === undefined || !(meshesObj instanceof Array)) {
      return 0;
    }
    const meshes: Object[] = meshesObj as Object[];
    let count: number = 0;
    for (let i: number = 0; i < meshes.length; i++) {
      const mesh: Record<string, Object> = meshes[i] as Record<string, Object>;
      const primsObj: Object | undefined = mesh['primitives'];
      if (primsObj instanceof Array) {
        count += (primsObj as Object[]).length;
      }
    }
    return count;
  }

  /**
   * 统计所有 skin 的 joint 总数(去重)。
   */
  private static countTotalJoints(json: Record<string, Object>): number {
    const skinsObj: Object | undefined = json['skins'];
    if (skinsObj === undefined || !(skinsObj instanceof Array)) {
      return 0;
    }
    const skins: Object[] = skinsObj as Object[];
    const jointSet: Set<number> = new Set<number>();
    for (let i: number = 0; i < skins.length; i++) {
      const skin: Record<string, Object> = skins[i] as Record<string, Object>;
      const jointsObj: Object | undefined = skin['joints'];
      if (jointsObj instanceof Array) {
        const joints: Object[] = jointsObj as Object[];
        for (let j: number = 0; j < joints.length; j++) {
          const joint: Object = joints[j];
          if (typeof joint === 'number') {
            jointSet.add(joint as number);
          }
        }
      }
    }
    return jointSet.size;
  }

  /**
   * 统计 morph target 数量(遍历所有 primitive 的 targets)。
   *
   * morph target 数量 = 所有 primitive.targets 数组长度之和。
   * 一个 primitive 的 targets 是一个数组,每个元素是一个 {POSITION, NORMAL, TANGENT} 对象。
   */
  private static countMorphTargets(json: Record<string, Object>): number {
    const meshesObj: Object | undefined = json['meshes'];
    if (meshesObj === undefined || !(meshesObj instanceof Array)) {
      return 0;
    }
    const meshes: Object[] = meshesObj as Object[];
    let count: number = 0;
    for (let i: number = 0; i < meshes.length; i++) {
      const mesh: Record<string, Object> = meshes[i] as Record<string, Object>;
      const primsObj: Object | undefined = mesh['primitives'];
      if (!(primsObj instanceof Array)) {
        continue;
      }
      const prims: Object[] = primsObj as Object[];
      for (let j: number = 0; j < prims.length; j++) {
        const prim: Record<string, Object> = prims[j] as Record<string, Object>;
        const targetsObj: Object | undefined = prim['targets'];
        if (targetsObj instanceof Array) {
          count += (targetsObj as Object[]).length;
        }
      }
    }
    return count;
  }

  /**
   * 统计灯光数量(KHR_lights_punctual 扩展)。
   */
  private static countLights(json: Record<string, Object>): number {
    const extensionsObj: Object | undefined = json['extensions'];
    if (extensionsObj === undefined || extensionsObj === null) {
      return 0;
    }
    const extensions: Record<string, Object> = extensionsObj as Record<string, Object>;
    const lightsObj: Object | undefined = extensions[EXT_LIGHTS_PUNCTUAL];
    if (lightsObj === undefined || lightsObj === null) {
      return 0;
    }
    const lights: Record<string, Object> = lightsObj as Record<string, Object>;
    const lightsArrayObj: Object | undefined = lights['lights'];
    if (lightsArrayObj instanceof Array) {
      return (lightsArrayObj as Object[]).length;
    }
    return 0;
  }

  /**
   * 检测是否存在外部 buffer 引用(buffer.uri 非 data:)。
   */
  private static hasExternalBuffers(json: Record<string, Object>): boolean {
    const buffersObj: Object | undefined = json['buffers'];
    if (buffersObj === undefined || !(buffersObj instanceof Array)) {
      return false;
    }
    const buffers: Object[] = buffersObj as Object[];
    for (let i: number = 0; i < buffers.length; i++) {
      const buf: Record<string, Object> = buffers[i] as Record<string, Object>;
      const uriObj: Object | undefined = buf['uri'];
      if (uriObj !== undefined && typeof uriObj === 'string') {
        const uri: string = uriObj as string;
        if (!uri.startsWith('data:')) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 检测是否存在外部图片引用(image.uri 非 data:)。
   */
  private static hasExternalImages(json: Record<string, Object>): boolean {
    const imagesObj: Object | undefined = json['images'];
    if (imagesObj === undefined || !(imagesObj instanceof Array)) {
      return false;
    }
    const images: Object[] = imagesObj as Object[];
    for (let i: number = 0; i < images.length; i++) {
      const img: Record<string, Object> = images[i] as Record<string, Object>;
      const uriObj: Object | undefined = img['uri'];
      if (uriObj !== undefined && typeof uriObj === 'string') {
        const uri: string = uriObj as string;
        if (!uri.startsWith('data:')) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 检测是否存在内嵌图片(data: URI 或 bufferView 引用)。
   */
  private static hasEmbeddedImages(json: Record<string, Object>): boolean {
    const imagesObj: Object | undefined = json['images'];
    if (imagesObj === undefined || !(imagesObj instanceof Array)) {
      return false;
    }
    const images: Object[] = imagesObj as Object[];
    for (let i: number = 0; i < images.length; i++) {
      const img: Record<string, Object> = images[i] as Record<string, Object>;
      const uriObj: Object | undefined = img['uri'];
      if (uriObj !== undefined && typeof uriObj === 'string') {
        const uri: string = uriObj as string;
        if (uri.startsWith('data:')) {
          return true;
        }
      }
      const bvObj: Object | undefined = img['bufferView'];
      if (bvObj !== undefined && typeof bvObj === 'number') {
        return true;
      }
    }
    return false;
  }

  /**
   * 分析材质类型。
   *
   * - PBR: 有 pbrMetallicRoughness 字段
   * - Transparent: alphaMode = BLEND 或 MASK,或 baseColorFactor[3] < 1.0
   * - Unlit: 使用 KHR_materials_unlit 扩展
   */
  private static analyzeMaterials(json: Record<string, Object>): MaterialAnalysis {
    const result: MaterialAnalysis = {
      hasPbr: false,
      hasTransparent: false,
      hasUnlit: false
    };
    const materialsObj: Object | undefined = json['materials'];
    if (materialsObj === undefined || !(materialsObj instanceof Array)) {
      return result;
    }
    const materials: Object[] = materialsObj as Object[];
    for (let i: number = 0; i < materials.length; i++) {
      const mat: Record<string, Object> = materials[i] as Record<string, Object>;

      // PBR 检测
      if (mat['pbrMetallicRoughness'] !== undefined) {
        result.hasPbr = true;
      }

      // 透明材质检测
      const alphaModeObj: Object | undefined = mat['alphaMode'];
      if (alphaModeObj !== undefined && typeof alphaModeObj === 'string') {
        const alphaMode: string = alphaModeObj as string;
        if (alphaMode === 'BLEND' || alphaMode === 'MASK') {
          result.hasTransparent = true;
        }
      }
      // baseColorFactor alpha < 1.0
      const pbrObj: Object | undefined = mat['pbrMetallicRoughness'];
      if (pbrObj !== undefined && pbrObj !== null) {
        const pbr: Record<string, Object> = pbrObj as Record<string, Object>;
        const bcfObj: Object | undefined = pbr['baseColorFactor'];
        if (bcfObj instanceof Array) {
          const bcf: Object[] = bcfObj as Object[];
          if (bcf.length >= 4 && typeof bcf[3] === 'number') {
            const alpha: number = bcf[3] as number;
            if (alpha < 1.0) {
              result.hasTransparent = true;
            }
          }
        }
      }

      // Unlit 检测
      const extObj: Object | undefined = mat['extensions'];
      if (extObj !== undefined && extObj !== null) {
        const ext: Record<string, Object> = extObj as Record<string, Object>;
        if (ext[EXT_MATERIALS_UNLIT] !== undefined) {
          result.hasUnlit = true;
        }
      }
    }
    return result;
  }
}

/**
 * 材质分析结果(内部类型)。
 */
interface MaterialAnalysis {
  hasPbr: boolean;
  hasTransparent: boolean;
  hasUnlit: boolean;
}
