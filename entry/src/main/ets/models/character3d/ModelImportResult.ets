/**
 * ModelImportResult 3D 模型导入统一结果类型
 *
 * T-3D.6D: 模型导入稳定性、兼容性诊断与自动验收
 *
 * 职责:
 * - 定义导入阶段枚举(ModelImportStage)
 * - 定义兼容性级别(ModelCompatibilityLevel)
 * - 定义导入错误码(ModelImportErrorCode)
 * - 定义统一导入结果(ModelImportResult)
 * - 定义模型扫描结果(ModelInspectionResult)
 * - 提供错误码到用户文案的映射
 *
 * 不包含业务逻辑(由 Character3DService / CompatibilityService 实现)。
 * 所有枚举与接口均为纯数据,可独立单元测试。
 *
 * 设计原则:
 * - 禁止不同页面各自拼接错误文本
 * - 所有用户提示从统一错误映射生成
 * - 只统计真实存在的数据,不得凭文件名猜测模型类型
 */

import { GltfModelInfo } from '../../parser/GltfValidator';

/**
 * 导入阶段(状态机)。
 */
export enum ModelImportStage {
  /** 空闲 */
  Idle = 0,
  /** 正在选择文件 */
  SelectingFile = 1,
  /** 正在复制文件到沙箱 */
  CopyingFile = 2,
  /** 正在计算文件指纹 */
  HashingFile = 3,
  /** 正在校验 GLB 容器 */
  ValidatingContainer = 4,
  /** 正在解析 glTF JSON */
  ParsingJson = 5,
  /** 正在扫描扩展 */
  InspectingExtensions = 6,
  /** 正在检查兼容性 */
  CheckingCompatibility = 7,
  /** 正在解码 meshopt */
  DecodingMeshopt = 8,
  /** 正在重建 GLB */
  RebuildingGlb = 9,
  /** 正在验证转换后 GLB */
  ValidatingConvertedGlb = 10,
  /** 正在加载 Scene */
  LoadingScene = 11,
  /** 正在计算 Bounds */
  ComputingBounds = 12,
  /** 正在生成预览 */
  CreatingPreview = 13,
  /** 正在持久化模型记录 */
  PersistingRecord = 14,
  /** 导入完成 */
  Completed = 15,
  /** 已取消 */
  Cancelled = 16,
  /** 失败 */
  Failed = 17
}

/**
 * 模型兼容性级别。
 */
export enum ModelCompatibilityLevel {
  /** 完全支持,可直接加载 */
  FullySupported = 0,
  /** 转换后支持(如 meshopt) */
  SupportedAfterConversion = 1,
  /** 部分支持(如纹理缺失但几何可显示) */
  PartiallySupported = 2,
  /** 仅可显示(无交互) */
  DisplayOnly = 3,
  /** 不支持(必需扩展不可转换) */
  Unsupported = 4,
  /** 文件损坏 */
  Corrupted = 5
}

/**
 * 导入错误码。
 *
 * 按 GLB 容器 → glTF 语义 → meshopt → ArkGraphics → 持久化 顺序分类。
 */
export enum ModelImportErrorCode {
  /** 用户主动取消 */
  UserCancelled = 0,
  /** 文件打开失败 */
  FileOpenFailed = 1,
  /** 文件读取失败 */
  FileReadFailed = 2,
  /** 文件过小 */
  FileTooSmall = 3,
  /** GLB magic 不匹配 */
  InvalidGlbMagic = 4,
  /** 不支持的 GLB 版本 */
  UnsupportedGlbVersion = 5,
  /** 声明的总长度与实际不符 */
  InvalidDeclaredLength = 6,
  /** chunk 对齐非法 */
  InvalidChunkAlignment = 7,
  /** 缺少 JSON chunk */
  MissingJsonChunk = 8,
  /** JSON chunk 类型错误 */
  InvalidJsonChunkType = 9,
  /** JSON 解析失败 */
  JsonParseFailed = 10,
  /** 缺少 asset.version */
  MissingAssetVersion = 11,
  /** 不支持的 glTF 版本 */
  UnsupportedGltfVersion = 12,
  /** 缺少 buffer */
  MissingBuffer = 13,
  /** 缺少 BIN chunk */
  MissingBinChunk = 14,
  /** buffer.byteLength 与实际 BIN 不匹配 */
  BufferLengthMismatch = 15,
  /** bufferView 越界 */
  BufferViewOutOfRange = 16,
  /** accessor 越界 */
  AccessorOutOfRange = 17,
  /** sparse accessor 非法 */
  SparseAccessorInvalid = 18,
  /** mesh primitive 非法 */
  MeshPrimitiveInvalid = 19,
  /** index accessor 类型非法 */
  IndexAccessorInvalid = 20,
  /** 图片数据非法 */
  ImageDataInvalid = 21,
  /** 不支持的图片格式 */
  UnsupportedImageFormat = 22,
  /** 纹理引用非法 */
  TextureReferenceInvalid = 23,
  /** 材质引用非法 */
  MaterialReferenceInvalid = 24,
  /** meshopt 元数据非法 */
  MeshoptMetadataInvalid = 25,
  /** meshopt 解码失败 */
  MeshoptDecodeFailed = 26,
  /** 转换后 GLB 非法 */
  ConvertedGlbInvalid = 27,
  /** 不支持的必需扩展 */
  UnsupportedRequiredExtension = 28,
  /** ArkGraphics 解析失败 */
  ArkGraphicsParseFailed = 29,
  /** Scene 创建失败 */
  SceneCreationFailed = 30,
  /** 空 Scene */
  EmptyScene = 31,
  /** Bounds 非法 */
  InvalidBounds = 32,
  /** 模型不可见 */
  ModelNotVisible = 33,
  /** 内存不足 */
  MemoryInsufficient = 34,
  /** 缓存写入失败 */
  CacheWriteFailed = 35,
  /** 数据库写入失败 */
  DatabaseWriteFailed = 36,
  /** 导入过程中取消 */
  CancelledDuringImport = 37,
  /** 未知错误 */
  Unknown = 99
}

/**
 * 模型扫描结果(导入前结构扫描)。
 *
 * 所有字段只统计真实存在的数据,不得凭文件名猜测。
 */
export interface ModelInspectionResult {
  /** 文件格式 */
  format: 'glb' | 'gltf' | 'unknown';
  /** GLB 版本(无则 undefined) */
  glbVersion?: number;
  /** glTF 版本字符串(如 "2.0") */
  gltfVersion?: string;
  /** 文件字节数 */
  fileSizeBytes: number;

  /** scene 数量 */
  sceneCount: number;
  /** node 数量 */
  nodeCount: number;
  /** mesh 数量 */
  meshCount: number;
  /** primitive 数量 */
  primitiveCount: number;
  /** 材质数量 */
  materialCount: number;
  /** 纹理数量 */
  textureCount: number;
  /** 图片数量 */
  imageCount: number;
  /** sampler 数量 */
  samplerCount: number;

  /** 动画数量 */
  animationCount: number;
  /** skin 数量 */
  skinCount: number;
  /** joint 总数(所有 skin 聚合) */
  jointCount: number;
  /** morph target 数量 */
  morphTargetCount: number;
  /** 相机数量 */
  cameraCount: number;
  /** 灯光数量(KHR_lights_punctual) */
  lightCount: number;

  /** accessor 数量 */
  accessorCount: number;
  /** bufferView 数量 */
  bufferViewCount: number;
  /** buffer 数量 */
  bufferCount: number;

  /** extensionsUsed 列表 */
  usedExtensions: string[];
  /** extensionsRequired 列表 */
  requiredExtensions: string[];
  /** 直接支持的扩展(ArkGraphics 原生) */
  directlySupportedExtensions: string[];
  /** 可转换的扩展(如 EXT_meshopt_compression) */
  convertibleExtensions: string[];
  /** 不支持的扩展 */
  unsupportedExtensions: string[];

  /** 是否使用 meshopt */
  hasMeshopt: boolean;
  /** 是否使用网格量化 */
  hasMeshQuantization: boolean;
  /** 是否使用 Draco */
  hasDraco: boolean;
  /** 是否引用外部 buffer */
  hasExternalBuffers: boolean;
  /** 是否引用外部图片 */
  hasExternalImages: boolean;
  /** 是否内嵌图片(data URI 或 bufferView) */
  hasEmbeddedImages: boolean;
  /** 是否有透明材质(BLEND/MASK) */
  hasTransparentMaterials: boolean;
  /** 是否有 unlit 材质 */
  hasUnlitMaterials: boolean;
  /** 是否有 PBR 材质 */
  hasPbrMaterials: boolean;

  /** 声明的 BIN 长度(GLB header) */
  declaredBinLength?: number;
  /** 实际 BIN 长度 */
  actualBinLength?: number;

  /** 警告列表 */
  warnings: string[];
}

/**
 * 统一导入结果。
 *
 * 所有导入路径(用户点击 / Debug 自动测试 / rawfile)必须返回此类型。
 * 禁止页面层拼接错误文本。
 */
export interface ModelImportResult {
  /** 是否成功 */
  success: boolean;
  /** 当前阶段(成功时为 Completed,取消时为 Cancelled,失败时为 Failed) */
  stage: ModelImportStage;
  /** 兼容性级别 */
  compatibility: ModelCompatibilityLevel;
  /** 错误码(成功时为 undefined) */
  errorCode?: ModelImportErrorCode;
  /** 用户可见文案(从错误码映射生成) */
  userMessage: string;
  /** 诊断信息(开发期日志,不含敏感数据) */
  diagnosticMessage?: string;
  /** 模型扫描结果(到达 InspectingExtensions 阶段后非空) */
  modelInfo?: ModelInspectionResult;
  /** 原始文件 SHA-256(到达 HashingFile 阶段后非空) */
  sourceSha256?: string;
  /** 缓存路径(命中缓存或转换完成后非空) */
  cachedPath?: string;
  /** 是否经过转换 */
  converted: boolean;
  /** 警告列表(不影响 success) */
  warnings: string[];
}

/**
 * 创建默认的空扫描结果。
 */
export function createEmptyInspectionResult(): ModelInspectionResult {
  return {
    format: 'unknown',
    fileSizeBytes: 0,
    sceneCount: 0,
    nodeCount: 0,
    meshCount: 0,
    primitiveCount: 0,
    materialCount: 0,
    textureCount: 0,
    imageCount: 0,
    samplerCount: 0,
    animationCount: 0,
    skinCount: 0,
    jointCount: 0,
    morphTargetCount: 0,
    cameraCount: 0,
    lightCount: 0,
    accessorCount: 0,
    bufferViewCount: 0,
    bufferCount: 0,
    usedExtensions: [],
    requiredExtensions: [],
    directlySupportedExtensions: [],
    convertibleExtensions: [],
    unsupportedExtensions: [],
    hasMeshopt: false,
    hasMeshQuantization: false,
    hasDraco: false,
    hasExternalBuffers: false,
    hasExternalImages: false,
    hasEmbeddedImages: false,
    hasTransparentMaterials: false,
    hasUnlitMaterials: false,
    hasPbrMaterials: false,
    warnings: []
  };
}

/**
 * 创建失败结果。
 */
export function createFailureResult(
  stage: ModelImportStage,
  errorCode: ModelImportErrorCode,
  diagnosticMessage: string,
  sourceSha256?: string
): ModelImportResult {
  return {
    success: false,
    stage: stage,
    compatibility: ModelCompatibilityLevel.Corrupted,
    errorCode: errorCode,
    userMessage: getErrorMessage(errorCode),
    diagnosticMessage: diagnosticMessage,
    sourceSha256: sourceSha256,
    converted: false,
    warnings: []
  };
}

/**
 * 创建取消结果。
 */
export function createCancelledResult(stage: ModelImportStage): ModelImportResult {
  return {
    success: false,
    stage: ModelImportStage.Cancelled,
    compatibility: ModelCompatibilityLevel.Unsupported,
    errorCode: ModelImportErrorCode.UserCancelled,
    userMessage: '已取消导入。',
    converted: false,
    warnings: []
  };
}

/**
 * 错误码到用户文案的统一映射。
 *
 * 禁止页面层各自拼接错误文本。
 */
export function getErrorMessage(code: ModelImportErrorCode): string {
  switch (code) {
    case ModelImportErrorCode.UserCancelled: return '已取消导入。';
    case ModelImportErrorCode.FileOpenFailed: return '无法打开模型文件。';
    case ModelImportErrorCode.FileReadFailed: return '读取模型文件失败。';
    case ModelImportErrorCode.FileTooSmall: return '文件过小,不是有效的 GLB。';
    case ModelImportErrorCode.InvalidGlbMagic: return '这不是有效的 GLB 文件。';
    case ModelImportErrorCode.UnsupportedGlbVersion: return '不支持的 GLB 版本,仅支持 2.0。';
    case ModelImportErrorCode.InvalidDeclaredLength: return 'GLB 声明的长度与实际文件大小不匹配。';
    case ModelImportErrorCode.InvalidChunkAlignment: return 'GLB chunk 对齐非法,文件可能损坏。';
    case ModelImportErrorCode.MissingJsonChunk: return 'GLB 缺少必须的 JSON 数据块。';
    case ModelImportErrorCode.InvalidJsonChunkType: return 'GLB 第一个 chunk 必须为 JSON。';
    case ModelImportErrorCode.JsonParseFailed: return 'GLB JSON 解析失败,文件可能损坏。';
    case ModelImportErrorCode.MissingAssetVersion: return 'glTF 缺少 asset.version 字段。';
    case ModelImportErrorCode.UnsupportedGltfVersion: return '不支持的 glTF 版本,仅支持 2.0。';
    case ModelImportErrorCode.MissingBuffer: return 'glTF 缺少 buffer 定义。';
    case ModelImportErrorCode.MissingBinChunk: return 'GLB 缺少 BIN 数据块。';
    case ModelImportErrorCode.BufferLengthMismatch: return 'buffer.byteLength 与实际 BIN 长度不匹配。';
    case ModelImportErrorCode.BufferViewOutOfRange: return 'bufferView 越界,文件可能损坏。';
    case ModelImportErrorCode.AccessorOutOfRange: return 'accessor 越界,文件可能损坏。';
    case ModelImportErrorCode.SparseAccessorInvalid: return 'sparse accessor 结构非法。';
    case ModelImportErrorCode.MeshPrimitiveInvalid: return 'mesh primitive 结构非法。';
    case ModelImportErrorCode.IndexAccessorInvalid: return 'index accessor 类型非法。';
    case ModelImportErrorCode.ImageDataInvalid: return '图片数据非法。';
    case ModelImportErrorCode.UnsupportedImageFormat: return '模型包含当前系统不支持的纹理格式,几何可能可以显示。';
    case ModelImportErrorCode.TextureReferenceInvalid: return '纹理引用非法。';
    case ModelImportErrorCode.MaterialReferenceInvalid: return '材质引用非法。';
    case ModelImportErrorCode.MeshoptMetadataInvalid: return 'meshopt 扩展元数据非法。';
    case ModelImportErrorCode.MeshoptDecodeFailed:
      return '模型使用 meshopt 压缩,但解码失败。文件可能损坏或使用了当前版本不支持的压缩参数。';
    case ModelImportErrorCode.ConvertedGlbInvalid: return '转换后的 GLB 校验失败。';
    case ModelImportErrorCode.UnsupportedRequiredExtension:
      return '模型要求当前版本不支持的扩展。';
    case ModelImportErrorCode.ArkGraphicsParseFailed:
      return '模型结构检查通过,但系统 3D 引擎无法解析该模型。';
    case ModelImportErrorCode.SceneCreationFailed: return '创建 3D 场景失败。';
    case ModelImportErrorCode.EmptyScene: return '模型不包含可渲染内容。';
    case ModelImportErrorCode.InvalidBounds:
      return '模型已加载,但未得到有效的几何边界,暂时无法显示。';
    case ModelImportErrorCode.ModelNotVisible: return '模型加载成功但不可见,可能尺寸异常。';
    case ModelImportErrorCode.MemoryInsufficient: return '内存不足,无法加载模型。';
    case ModelImportErrorCode.CacheWriteFailed: return '缓存写入失败。';
    case ModelImportErrorCode.DatabaseWriteFailed: return '保存模型记录失败。';
    case ModelImportErrorCode.CancelledDuringImport: return '已取消导入。';
    case ModelImportErrorCode.Unknown: return '导入失败,原因未知。';
    default: return '导入失败。';
  }
}

/**
 * 获取阶段对应的 UI 进度文案。
 */
export function getImportStageMessage(stage: ModelImportStage): string {
  switch (stage) {
    case ModelImportStage.Idle: return '';
    case ModelImportStage.SelectingFile: return '正在选择模型…';
    case ModelImportStage.CopyingFile: return '正在读取模型…';
    case ModelImportStage.HashingFile: return '正在计算文件指纹…';
    case ModelImportStage.ValidatingContainer: return '正在校验 GLB…';
    case ModelImportStage.ParsingJson: return '正在分析模型结构…';
    case ModelImportStage.InspectingExtensions: return '正在扫描扩展…';
    case ModelImportStage.CheckingCompatibility: return '正在检查兼容性…';
    case ModelImportStage.DecodingMeshopt: return '正在解码 meshopt…';
    case ModelImportStage.RebuildingGlb: return '正在生成标准 GLB…';
    case ModelImportStage.ValidatingConvertedGlb: return '正在验证转换结果…';
    case ModelImportStage.LoadingScene: return '正在加载 3D 场景…';
    case ModelImportStage.ComputingBounds: return '正在计算模型边界…';
    case ModelImportStage.CreatingPreview: return '正在生成预览…';
    case ModelImportStage.PersistingRecord: return '正在保存模型…';
    case ModelImportStage.Completed: return '导入完成。';
    case ModelImportStage.Cancelled: return '已取消导入。';
    case ModelImportStage.Failed: return '导入失败。';
    default: return '';
  }
}

/**
 * 获取阶段对应的进度百分比(0-100)。
 *
 * 用于 UI 进度条显示。如果无法获得内部细粒度进度,显示阶段对应的估算百分比,
 * 不伪造精确百分比。
 */
export function getImportStagePercent(stage: ModelImportStage): number {
  switch (stage) {
    case ModelImportStage.Idle: return 0;
    case ModelImportStage.SelectingFile: return 0;
    case ModelImportStage.CopyingFile: return 5;
    case ModelImportStage.HashingFile: return 10;
    case ModelImportStage.ValidatingContainer: return 15;
    case ModelImportStage.ParsingJson: return 25;
    case ModelImportStage.InspectingExtensions: return 30;
    case ModelImportStage.CheckingCompatibility: return 40;
    case ModelImportStage.DecodingMeshopt: return 55;
    case ModelImportStage.RebuildingGlb: return 65;
    case ModelImportStage.ValidatingConvertedGlb: return 70;
    case ModelImportStage.LoadingScene: return 80;
    case ModelImportStage.ComputingBounds: return 88;
    case ModelImportStage.CreatingPreview: return 92;
    case ModelImportStage.PersistingRecord: return 96;
    case ModelImportStage.Completed: return 100;
    case ModelImportStage.Cancelled: return 0;
    case ModelImportStage.Failed: return 0;
    default: return 0;
  }
}
