/**
 * ModelCompatibility 3D 模型兼容性状态与转换配置
 *
 * T-3D.6C-C: 识别 GLB 模型的扩展兼容状态,支持自动转换压缩网格格式。
 *
 * 职责:
 * - 定义模型兼容状态枚举(ModelCompatibilityStatus)
 * - 定义用户转换偏好(ModelConversionMode)
 * - 定义转换结果与进度回调类型
 *
 * 不包含具体转换逻辑(由 Character3DModelCompatibilityService 实现)。
 */

/**
 * T-3D.6C-C: 模型兼容状态。
 *
 * DirectSupported: ArkGraphics 可直接加载,无需转换。
 * Convertible: 依赖可转换扩展(EXT_meshopt_compression / KHR_mesh_quantization),需要预处理。
 * Converting: 转换进行中(UI 进度显示)。
 * Converted: 转换已完成,输出标准 GLB 可直接加载。
 * Unsupported: 依赖不可转换的扩展(如 KHR_draco_mesh_compression),必须拒绝。
 * ConversionFailed: 转换过程中出错(解码失败、重建失败、验证失败等)。
 */
export enum ModelCompatibilityStatus {
  /** ArkGraphics 可直接加载 */
  DirectSupported = 0,
  /** 依赖可转换扩展,需要预处理 */
  Convertible = 1,
  /** 转换进行中 */
  Converting = 2,
  /** 转换已完成 */
  Converted = 3,
  /** 依赖不可转换的扩展 */
  Unsupported = 4,
  /** 转换失败 */
  ConversionFailed = 5
}

/**
 * T-3D.6C-C: 用户转换偏好(设置页"模型兼容转换")。
 *
 * Auto: 检测到可转换扩展后直接转换(默认)。
 * Ask: 导入前弹窗询问用户是否转换。
 * Off: 关闭自动转换,保持严格失败行为并显示重新导出建议。
 */
export enum ModelConversionMode {
  /** 自动转换 */
  Auto = 0,
  /** 导入前询问 */
  Ask = 1,
  /** 关闭转换 */
  Off = 2
}

/**
 * T-3D.6C-C: 转换进度阶段。
 */
export enum ModelConversionStage {
  /** 正在读取模型 */
  Reading = 0,
  /** 正在检查扩展 */
  CheckingExtensions = 1,
  /** 正在解压网格 */
  DecompressingMesh = 2,
  /** 正在转换量化属性 */
  Dequantizing = 3,
  /** 正在重建 GLB */
  RebuildingGlb = 4,
  /** 正在验证转换结果 */
  Validating = 5,
  /** 正在加载模型 */
  Loading = 6,
  /** 完成 */
  Done = 7,
  /** 失败 */
  Failed = 8
}

/**
 * T-3D.6C-C: 转换进度信息(用于 UI 显示)。
 */
export interface ModelConversionProgress {
  /** 当前阶段 */
  stage: ModelConversionStage;
  /** 进度百分比 0-100(估算) */
  percent: number;
  /** 阶段描述文案 */
  message: string;
}

/**
 * T-3D.6C-C: 模型兼容性分析结果(导入前)。
 */
export interface ModelCompatibilityAnalysis {
  /** 兼容状态 */
  status: ModelCompatibilityStatus;
  /** 检测到的可转换扩展(extensionsUsed 命中) */
  convertibleExtensions: string[];
  /** 检测到的必需可转换扩展(extensionsRequired 命中) */
  convertibleRequiredExtensions: string[];
  /** 检测到的不支持扩展(不可转换) */
  unsupportedExtensions: string[];
  /** 原始 GLB 字节长度 */
  sourceByteLength: number;
  /** 原始文件 SHA-256(用于缓存键) */
  sourceSha256: string;
  /** 分析错误信息(失败时非空) */
  errorMessage: string;
}

/**
 * T-3D.6C-C: 模型转换结果。
 */
export interface ModelConversionResult {
  /** 是否成功 */
  success: boolean;
  /** 兼容状态(成功时为 Converted,失败时为 ConversionFailed) */
  status: ModelCompatibilityStatus;
  /** 转换后的 GLB 文件路径(成功时非空) */
  outputPath: string;
  /** 转换后的 GLB 字节长度 */
  outputByteLength: number;
  /** 转换后移除的扩展列表 */
  removedExtensions: string[];
  /** 转换后保留的扩展列表(如 KHR_mesh_quantization 若 ArkGraphics 原生支持) */
  retainedExtensions: string[];
  /** 转换警告信息(不影响成功) */
  warnings: string[];
  /** 失败时的错误信息 */
  errorMessage: string;
  /** 是否使用了缓存(命中缓存时为 true) */
  fromCache: boolean;
}

/**
 * T-3D.6C-C: 转换缓存元数据(conversion.json)。
 */
export interface ConversionCacheMetadata {
  /** 原始文件 SHA-256 */
  sourceSha256: string;
  /** 转换器版本 */
  converterVersion: string;
  /** meshoptimizer 库版本 */
  meshoptimizerVersion: string;
  /** 原始扩展列表 */
  sourceExtensions: string[];
  /** 移除的扩展列表 */
  removedExtensions: string[];
  /** 输出文件 SHA-256 */
  outputSha256: string;
  /** 转换时间(毫秒时间戳) */
  convertedAt: number;
  /** 转换警告 */
  warnings: string[];
  /** 解码的 bufferView 数量 */
  decodedBufferViewCount: number;
  /** T-3D.6C-C3: ArkGraphics 真机加载是否已验证成功(仅 true 时缓存才有效) */
  loadVerified: boolean;
}

/**
 * 当前转换器版本(缓存失效用)。
 */
export const MODEL_CONVERTER_VERSION: string = '1.1.0';

/**
 * meshoptimizer 库版本(缓存失效用)。
 * 与 src/meshoptimizer.h 中 MESHOPTIMIZER_VERSION 宏对应。
 */
export const MESHOPTIMIZER_VERSION: string = '0.22';

/**
 * 可转换扩展常量(与 GltfValidator 内部保持一致)。
 */
export const CONVERTIBLE_EXTENSIONS: string[] = [
  'EXT_meshopt_compression',
  'KHR_mesh_quantization'
];

/**
 * 转换阶段对应的 UI 文案。
 */
export function getConversionStageMessage(stage: ModelConversionStage): string {
  switch (stage) {
    case ModelConversionStage.Reading: return '正在读取模型…';
    case ModelConversionStage.CheckingExtensions: return '正在检查扩展…';
    case ModelConversionStage.DecompressingMesh: return '正在解压网格…';
    case ModelConversionStage.Dequantizing: return '正在转换量化属性…';
    case ModelConversionStage.RebuildingGlb: return '正在重建 GLB…';
    case ModelConversionStage.Validating: return '正在验证转换结果…';
    case ModelConversionStage.Loading: return '正在加载模型…';
    case ModelConversionStage.Done: return '转换完成';
    case ModelConversionStage.Failed: return '转换失败';
    default: return '';
  }
}

/**
 * 获取兼容状态的显示文案。
 */
export function getCompatibilityStatusMessage(status: ModelCompatibilityStatus): string {
  switch (status) {
    case ModelCompatibilityStatus.DirectSupported: return '可直接加载';
    case ModelCompatibilityStatus.Convertible: return '需要兼容转换';
    case ModelCompatibilityStatus.Converting: return '正在转换';
    case ModelCompatibilityStatus.Converted: return '已转换';
    case ModelCompatibilityStatus.Unsupported: return '不支持的格式';
    case ModelCompatibilityStatus.ConversionFailed: return '转换失败';
    default: return '';
  }
}
