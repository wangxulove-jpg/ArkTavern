/**
 * ArkWebAvatarAssetTypes — 持久化资产目录类型定义 (Phase 3B)
 *
 * 定义:
 * - 资产清单 schema (library.json)
 * - 模型资产记录
 * - 恢复状态机
 * - 恢复结果
 * - 错误码
 *
 * 本阶段范围:
 * - schemaVersion = 1
 * - 仅处理 models 数组
 * - animations / poses 固定为空数组 (Phase 3C 实现)
 *
 * 安全约束:
 * - 资产清单禁止保存绝对路径 / 原始 URI / cachePath / ArkWeb URL / 文件描述符
 * - 运行时绝对路径必须通过 filesDir + relativePath 重新构造
 * - 禁止向 UI 返回 absolutePath / cachePath / 原始 URI / 文件描述符
 */

/**
 * 资产清单 schema 版本。
 * 字段结构变更时递增,旧版本视为不支持。
 */
export const ASSET_LIBRARY_SCHEMA_VERSION: number = 1;

/**
 * 持久化模型资产记录。
 *
 * 字段:
 * - modelId: 唯一标识 (model_<timestamp>_<random>)
 * - resourceId: Provider 资源 ID (可与 modelId 相同)
 * - displayName: 用户可读显示名 (来自用户文件名,已做安全清理)
 * - relativePath: 相对 filesDir/avatar-assets/ 的路径 (如 "models/model_xxx.vrm")
 * - mimeType: MIME 类型 (model/gltf-binary / model/gltf+json)
 * - byteLength: 文件大小 (字节)
 * - createdAt: 创建时间戳 (ms)
 * - updatedAt: 更新时间戳 (ms)
 *
 * 禁止字段:
 * - absolutePath
 * - cachePath
 * - sourceUri
 * - ArkWeb URL
 * - 文件描述符
 */
export interface ArkWebAvatarModelAsset {
  modelId: string;
  resourceId: string;
  displayName: string;
  relativePath: string;
  mimeType: string;
  byteLength: number;
  createdAt: number;
  updatedAt: number;
}

/**
 * 资产清单数据 (library.json 序列化结构)。
 *
 * 本阶段:
 * - schemaVersion = 1
 * - models 数组 (可含 0..N 条记录)
 * - animations 数组 (Phase 3C-1 起支持多 VRMA 持久化)
 * - poses 固定为空数组 (Phase 3C 后续阶段实现)
 */
export interface ArkWebAvatarAssetLibraryData {
  schemaVersion: number;
  activeModelId: string;
  models: ArkWebAvatarModelAsset[];
  animations: ArkWebAvatarAnimationAsset[];
  poses: Object[];
}

/**
 * 持久化动画资产记录 (Phase 3C-1)。
 *
 * 字段:
 * - actionId: 唯一标识 (action_<timestamp>_<random>)
 * - resourceId: Provider 资源 ID (可与 actionId 相同)
 * - displayName: 用户可读显示名 (来自用户文件名,已做安全清理)
 * - relativePath: 相对 filesDir/avatar-assets/ 的路径 (如 "animations/action_xxx.vrma")
 * - mimeType: MIME 类型 (model/gltf-binary)
 * - byteLength: 文件大小 (字节)
 * - createdAt: 创建时间戳 (ms)
 * - updatedAt: 更新时间戳 (ms)
 *
 * 禁止字段:
 * - absolutePath
 * - cachePath
 * - sourceUri
 * - ArkWeb URL
 * - 文件描述符
 */
export interface ArkWebAvatarAnimationAsset {
  actionId: string;
  resourceId: string;
  displayName: string;
  relativePath: string;
  mimeType: string;
  byteLength: number;
  createdAt: number;
  updatedAt: number;
}

/**
 * 模型恢复状态机。
 *
 * 状态流转:
 *   IDLE → READING_LIBRARY → MIGRATING → VALIDATING → REGISTERING → LOADING → READY
 *   IDLE → READING_LIBRARY → EMPTY (无 active model)
 *   任意 → FAILED (恢复失败)
 *   任意 → DISPOSED (页面销毁)
 */
export enum ArkWebModelRestoreState {
  IDLE = 'IDLE',
  READING_LIBRARY = 'READING_LIBRARY',
  MIGRATING = 'MIGRATING',
  VALIDATING = 'VALIDATING',
  REGISTERING = 'REGISTERING',
  LOADING = 'LOADING',
  READY = 'READY',
  EMPTY = 'EMPTY',
  FAILED = 'FAILED',
  DISPOSED = 'DISPOSED'
}

/**
 * 模型恢复结果。
 *
 * 禁止向 UI 返回:
 * - absolutePath
 * - cachePath
 * - 原始 URI
 * - 文件描述符
 */
export interface ArkWebModelRestoreResult {
  state: ArkWebModelRestoreState;
  activeModelId: string;
  displayName: string;
  byteLength: number;
  migratedFromLegacyCache: boolean;
  errorCode: string;
  errorMessage: string;
}

/**
 * 资产清单错误码。
 */
export class AssetLibraryErrorCode {
  /** 资产目录创建失败。 */
  static readonly ASSET_LIBRARY_DIRECTORY_FAILED: string = 'ASSET_LIBRARY_DIRECTORY_FAILED';
  /** library.json 读取失败 (IO 错误)。 */
  static readonly ASSET_LIBRARY_READ_FAILED: string = 'ASSET_LIBRARY_READ_FAILED';
  /** library.json JSON 解析失败。 */
  static readonly ASSET_LIBRARY_PARSE_FAILED: string = 'ASSET_LIBRARY_PARSE_FAILED';
  /** schemaVersion 不支持。 */
  static readonly ASSET_LIBRARY_VERSION_UNSUPPORTED: string = 'ASSET_LIBRARY_VERSION_UNSUPPORTED';
  /** library.json 字段缺失或类型错误。 */
  static readonly ASSET_LIBRARY_FIELD_INVALID: string = 'ASSET_LIBRARY_FIELD_INVALID';
  /** library.json 原子写入失败 (.part 创建 / rename)。 */
  static readonly ASSET_LIBRARY_WRITE_FAILED: string = 'ASSET_LIBRARY_WRITE_FAILED';
  /** library.json 临时文件为空。 */
  static readonly ASSET_LIBRARY_PART_EMPTY: string = 'ASSET_LIBRARY_PART_EMPTY';
  /** 损坏清单重命名失败。 */
  static readonly ASSET_LIBRARY_CORRUPT_RENAME_FAILED: string = 'ASSET_LIBRARY_CORRUPT_RENAME_FAILED';
  /** AssetLibrary 已销毁。 */
  static readonly ASSET_LIBRARY_DISPOSED: string = 'ASSET_LIBRARY_DISPOSED';
}

/**
 * 模型恢复错误码。
 */
export class ModelRestoreErrorCode {
  /** 资产清单缺失或读取失败。 */
  static readonly MODEL_RESTORE_LIBRARY_MISSING: string = 'MODEL_RESTORE_LIBRARY_MISSING';
  /** activeModelId 为空或 models 中无对应记录。 */
  static readonly MODEL_RESTORE_ACTIVE_MODEL_MISSING: string = 'MODEL_RESTORE_ACTIVE_MODEL_MISSING';
  /** 模型文件不存在。 */
  static readonly MODEL_RESTORE_FILE_MISSING: string = 'MODEL_RESTORE_FILE_MISSING';
  /** 模型文件为空 (size === 0)。 */
  static readonly MODEL_RESTORE_FILE_EMPTY: string = 'MODEL_RESTORE_FILE_EMPTY';
  /** 实际文件大小与清单记录不一致。 */
  static readonly MODEL_RESTORE_FILE_SIZE_MISMATCH: string = 'MODEL_RESTORE_FILE_SIZE_MISMATCH';
  /** relativePath 不安全 (含 .. 或不在 models/ 下)。 */
  static readonly MODEL_RESTORE_PATH_INVALID: string = 'MODEL_RESTORE_PATH_INVALID';
  /** Provider 注册资源失败。 */
  static readonly MODEL_RESTORE_PROVIDER_FAILED: string = 'MODEL_RESTORE_PROVIDER_FAILED';
  /** 模型加载失败 (loadPreparedModelResource 失败)。 */
  static readonly MODEL_RESTORE_LOAD_FAILED: string = 'MODEL_RESTORE_LOAD_FAILED';
  /** 恢复代次过期 (restoreGeneration 不匹配)。 */
  static readonly MODEL_RESTORE_STALE: string = 'MODEL_RESTORE_STALE';
  /** 页面已销毁。 */
  static readonly MODEL_RESTORE_DISPOSED: string = 'MODEL_RESTORE_DISPOSED';
  /** 恢复流程已在进行中。 */
  static readonly MODEL_RESTORE_IN_PROGRESS: string = 'MODEL_RESTORE_IN_PROGRESS';
  /** Viewer 未 READY。 */
  static readonly MODEL_RESTORE_VIEWER_NOT_READY: string = 'MODEL_RESTORE_VIEWER_NOT_READY';
}

/**
 * 旧缓存迁移错误码。
 */
export class LegacyModelMigrationErrorCode {
  /** 旧 Preferences 中无记录。 */
  static readonly LEGACY_PREFS_NO_RECORD: string = 'LEGACY_PREFS_NO_RECORD';
  /** 旧缓存文件不存在。 */
  static readonly LEGACY_CACHE_FILE_MISSING: string = 'LEGACY_CACHE_FILE_MISSING';
  /** 旧缓存文件大小不匹配。 */
  static readonly LEGACY_CACHE_SIZE_MISMATCH: string = 'LEGACY_CACHE_SIZE_MISMATCH';
  /** 迁移到 filesDir 失败。 */
  static readonly LEGACY_MIGRATE_COPY_FAILED: string = 'LEGACY_MIGRATE_COPY_FAILED';
  /** 迁移后清单写入失败。 */
  static readonly LEGACY_MIGRATE_LIBRARY_WRITE_FAILED: string = 'LEGACY_MIGRATE_LIBRARY_WRITE_FAILED';
}

/**
 * 持久化动画资产错误码 (Phase 3C-1)。
 */
export class PersistentAnimationErrorCode {
  /** PersistentAnimationStore 已销毁。 */
  static readonly ANIMATION_STORE_DISPOSED: string = 'ANIMATION_STORE_DISPOSED';
  /** AssetLibrary 未初始化或已销毁。 */
  static readonly ANIMATION_STORE_LIBRARY_INVALID: string = 'ANIMATION_STORE_LIBRARY_INVALID';
  /** 源文件打开失败。 */
  static readonly ANIMATION_SOURCE_OPEN_FAILED: string = 'ANIMATION_SOURCE_OPEN_FAILED';
  /** 源文件为空 (size === 0)。 */
  static readonly ANIMATION_FILE_EMPTY: string = 'ANIMATION_FILE_EMPTY';
  /** 目标 .part 文件创建失败。 */
  static readonly ANIMATION_TARGET_CREATE_FAILED: string = 'ANIMATION_TARGET_CREATE_FAILED';
  /** 复制过程读取失败。 */
  static readonly ANIMATION_FILE_READ_FAILED: string = 'ANIMATION_FILE_READ_FAILED';
  /** 复制过程写入失败。 */
  static readonly ANIMATION_FILE_WRITE_FAILED: string = 'ANIMATION_FILE_WRITE_FAILED';
  /** 复制不完整 (写入字节数与源大小不一致)。 */
  static readonly ANIMATION_FILE_COPY_INCOMPLETE: string = 'ANIMATION_FILE_COPY_INCOMPLETE';
  /** rename .part → 最终文件失败。 */
  static readonly ANIMATION_RENAME_FAILED: string = 'ANIMATION_RENAME_FAILED';
  /** 清单写入失败 (回滚: 删除新动画文件)。 */
  static readonly ANIMATION_LIBRARY_WRITE_FAILED: string = 'ANIMATION_LIBRARY_WRITE_FAILED';
}
