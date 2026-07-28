/**
 * ArkWebModelImportTypes — 模型导入类型定义(Phase 1D-1)
 *
 * 定义模型文件选择与受控缓存所需的状态机、文件类型、导入结果与错误码。
 * 由 ArkWebFileImportController 与 VrmViewerPage 使用。
 *
 * 本阶段范围:
 * - 系统文件选择器(DocumentViewPicker)
 * - 模型文件类型校验(.vrm / .glb / .gltf)
 * - 受控缓存复制(原子写入)
 * - GLTF 外部依赖预检(轻量 JSON 分析)
 * - 导入状态机与错误处理
 *
 * 本阶段不实现:
 * - 把文件传给 ArkWeb(Phase 1D-2)
 * - JavaScript loadModel Bridge(Phase 1D-2)
 * - Object URL / Base64 传输
 *
 * Reference:
 * - HarmonyOS SDK API 23: @ohos.file.picker / @ohos.file.fs
 * - AGENTS.md Phase 1D-1 规范
 */

/**
 * 模型导入状态机。
 *
 * 状态流转:
 *   IDLE → PICKING → COPYING → READY     (成功)
 *   PICKING → CANCELLED                   (用户取消,非错误)
 *   PICKING / COPYING → FAILED            (失败,保留旧 currentFile)
 *   任意 → DISPOSED                       (销毁)
 */
export enum ModelImportState {
  /** 空闲,无进行中的导入操作。 */
  IDLE = 'IDLE',
  /** 正在显示系统文件选择器,等待用户选择。 */
  PICKING = 'PICKING',
  /** 用户已选择文件,正在复制到受控缓存。 */
  COPYING = 'COPYING',
  /** 文件已成功复制到受控缓存,可被后续阶段加载。 */
  READY = 'READY',
  /** 用户取消了选择(非错误)。 */
  CANCELLED = 'CANCELLED',
  /** 导入失败(选择失败 / 复制失败 / 校验失败)。 */
  FAILED = 'FAILED',
  /** 控制器已销毁。 */
  DISPOSED = 'DISPOSED'
}

/**
 * 支持的模型文件类型。
 */
export enum ModelFileType {
  /** VRM 模型(.vrm)。 */
  VRM = 'VRM',
  /** glTF 二进制模型(.glb)。 */
  GLB = 'GLB',
  /** glTF JSON 模型(.gltf,可能含外部依赖)。 */
  GLTF = 'GLTF'
}

/**
 * glTF 外部依赖预检状态(仅对 .gltf 文件有意义)。
 *
 * - VRM / GLB:始终为 NOT_APPLICABLE(二进制自包含)
 * - GLTF:根据 JSON 中 buffers[].uri 与 images[].uri 分类
 */
export enum GltfDependencyState {
  /** 不适用(.vrm / .glb 二进制自包含)。 */
  NOT_APPLICABLE = 'NOT_APPLICABLE',
  /** .gltf 文件自包含,所有资源均为 data: URI 内嵌。 */
  SELF_CONTAINED = 'SELF_CONTAINED',
  /** .gltf 文件引用了相对路径的外部 .bin 或纹理文件,后续阶段需要附属资源导入。 */
  EXTERNAL_FILES_REQUIRED = 'EXTERNAL_FILES_REQUIRED',
  /** .gltf 文件引用了 http(s):// 远程资源,后续阶段需要网络下载策略。 */
  REMOTE_RESOURCES_FOUND = 'REMOTE_RESOURCES_FOUND',
  /** .gltf 文件 JSON 解析失败。 */
  INVALID_JSON = 'INVALID_JSON'
}

/**
 * 导入的模型文件元数据。
 *
 * 由 ArkWebFileImportController.pickModelFile() 成功后构造,
 * 包含文件基本信息与缓存路径,供后续 Phase 1D-2 加载使用。
 */
export interface ImportedModelFile {
  /** 唯一 ID(时间戳+代次,便于日志追踪)。 */
  id: string;
  /** 用户可读的显示名(来自用户选择的文件名,已做安全清理)。 */
  displayName: string;
  /** 小写扩展名(不含点,如 'vrm' / 'glb' / 'gltf')。 */
  extension: string;
  /** 文件类型枚举。 */
  fileType: ModelFileType;
  /** MIME 类型(根据扩展名统一生成,不依赖系统返回)。 */
  mimeType: string;
  /** 系统 Picker 返回的原始 URI(仅用于日志,不直接传给 ArkWeb)。 */
  sourceUri: string;
  /** 受控缓存中的绝对路径(<cacheDir>/vrm-imports/<timestamp>-<gen>.<ext>)。 */
  cachePath: string;
  /** 文件大小(字节,由 stat 获取)。 */
  size: number;
  /** 创建时间戳(ms)。 */
  createdAt: number;
  /** glTF 外部依赖预检状态(VRM/GLB 为 NOT_APPLICABLE)。 */
  gltfDependencyState: GltfDependencyState;
  /** glTF 外部依赖 URI 列表(仅 .gltf 文件,VRM/GLB 为空)。 */
  gltfExternalUris: string[];
}

/**
 * 模型导入错误码。
 */
export class ModelImportErrorCode {
  /** 系统 Picker 不可用(如 context 不正确)。 */
  static readonly PICKER_NOT_AVAILABLE: string = 'PICKER_NOT_AVAILABLE';
  /** Picker 调用失败(抛异常)。 */
  static readonly PICKER_FAILED: string = 'PICKER_FAILED';
  /** 用户取消选择(非错误,但需区分)。 */
  static readonly SELECTION_CANCELLED: string = 'SELECTION_CANCELLED';
  /** 不支持的模型格式(扩展名不在白名单)。 */
  static readonly UNSUPPORTED_MODEL_FORMAT: string = 'UNSUPPORTED_MODEL_FORMAT';
  /** 文件为空(size === 0)。 */
  static readonly FILE_EMPTY: string = 'FILE_EMPTY';
  /** 打开源 URI 失败。 */
  static readonly SOURCE_OPEN_FAILED: string = 'SOURCE_OPEN_FAILED';
  /** 创建缓存目录失败。 */
  static readonly CACHE_DIRECTORY_FAILED: string = 'CACHE_DIRECTORY_FAILED';
  /** 创建目标临时文件失败。 */
  static readonly TARGET_CREATE_FAILED: string = 'TARGET_CREATE_FAILED';
  /** 读取源文件失败。 */
  static readonly FILE_READ_FAILED: string = 'FILE_READ_FAILED';
  /** 写入目标文件失败。 */
  static readonly FILE_WRITE_FAILED: string = 'FILE_WRITE_FAILED';
  /** 复制后大小不匹配(writtenBytes !== sourceSize)。 */
  static readonly FILE_COPY_INCOMPLETE: string = 'FILE_COPY_INCOMPLETE';
  /** glTF JSON 解析失败。 */
  static readonly GLTF_JSON_INVALID: string = 'GLTF_JSON_INVALID';
  /** 导入结果已过期(竞态保护,operationGeneration 不匹配)。 */
  static readonly STALE_IMPORT_RESULT: string = 'STALE_IMPORT_RESULT';
  /** 导入控制器已销毁。 */
  static readonly IMPORT_CONTROLLER_DISPOSED: string = 'IMPORT_CONTROLLER_DISPOSED';
}

/**
 * 模型导入错误对象。
 */
export interface ModelImportError {
  /** 错误码,见 ModelImportErrorCode。 */
  code: string;
  /** 错误发生时的状态。 */
  phase: ModelImportState;
  /** 错误消息。 */
  message: string;
  /** 是否可恢复(用户可重试)。 */
  recoverable: boolean;
}

/**
 * 支持的模型扩展名白名单(小写,不含点)。
 */
export const SUPPORTED_MODEL_EXTENSIONS: string[] = ['vrm', 'glb', 'gltf'];

/**
 * Picker 文件后缀过滤器(传给 DocumentSelectOptions.fileSuffixFilters)。
 */
export const PICKER_FILE_SUFFIX_FILTERS: string[] = ['vrm', 'glb', 'gltf'];

/**
 * 复制缓冲区大小:64 KiB。
 *
 * VRM 文件通常 5-15 MB,64 KiB 缓冲区在内存占用与 IO 次数间取得平衡。
 */
export const COPY_BUFFER_SIZE: number = 64 * 1024;

/**
 * 受控缓存子目录名(相对于 context.cacheDir)。
 */
export const CACHE_SUBDIR: string = 'vrm-imports';
