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
 * - expressionAliases: Phase 3E-2 表情别名映射 (业务 expressionId → 模型真实 expressionName)
 *   旧模型记录缺少字段时兼容为空对象。
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
  /** Phase 3E-2: 表情别名映射 (业务 expressionId → 模型真实 expressionName)。旧记录缺失时兼容为空对象。 */
  expressionAliases: Record<string, string>;
}

/**
 * 资产清单数据 (library.json 序列化结构)。
 *
 * 本阶段:
 * - schemaVersion = 1
 * - models 数组 (可含 0..N 条记录)
 * - animations 数组 (Phase 3C-1 起支持多 VRMA 持久化)
 * - defaultIdleActionId (Phase 3C-2 起支持默认待机标记, 空字符串表示无默认)
 * - poses 数组 (Phase 3D-1 起支持 JSON 姿势持久化)
 * - defaultPoseId (Phase 3D-3 起支持默认姿势标记, 空字符串表示无默认)
 *
 * schemaVersion 保持 1: defaultPoseId 字段向后兼容, 旧清单缺失该字段时视为空字符串。
 */
export interface ArkWebAvatarAssetLibraryData {
  schemaVersion: number;
  activeModelId: string;
  models: ArkWebAvatarModelAsset[];
  animations: ArkWebAvatarAnimationAsset[];
  defaultIdleActionId: string;
  poses: ArkWebAvatarPoseAsset[];
  /** Phase 3D-3: 默认姿势 poseId (空字符串表示无默认, 旧清单缺失时兼容为空)。 */
  defaultPoseId: string;
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

/**
 * 动画管理操作错误码 (Phase 3C-2)。
 * 覆盖重命名 / 删除 / 默认待机标记操作。
 */
export class AnimationManagementErrorCode {
  /** 动作不存在 (actionId 在清单中找不到)。 */
  static readonly ANIMATION_NOT_FOUND: string = 'ANIMATION_NOT_FOUND';
  /** 重命名名称无效 (trim 后为空或长度超过 64)。 */
  static readonly ANIMATION_RENAME_NAME_INVALID: string = 'ANIMATION_RENAME_NAME_INVALID';
  /** 删除时文件 rename 到 .deleting 失败。 */
  static readonly ANIMATION_DELETE_RENAME_FAILED: string = 'ANIMATION_DELETE_RENAME_FAILED';
  /** 删除时清单写入失败 (回滚: 将 .deleting rename 回原文件)。 */
  static readonly ANIMATION_DELETE_LIBRARY_WRITE_FAILED: string = 'ANIMATION_DELETE_LIBRARY_WRITE_FAILED';
  /** 删除后清理 .deleting 文件失败 (清单已更新, 文件残留)。 */
  static readonly ANIMATION_DELETE_CLEANUP_FAILED: string = 'ANIMATION_DELETE_CLEANUP_FAILED';
  /** 默认待机 actionId 无效 (不在 animations 中且非空字符串)。 */
  static readonly ANIMATION_DEFAULT_IDLE_INVALID: string = 'ANIMATION_DEFAULT_IDLE_INVALID';
  /** 默认待机标记更新时清单写入失败。 */
  static readonly ANIMATION_DEFAULT_IDLE_WRITE_FAILED: string = 'ANIMATION_DEFAULT_IDLE_WRITE_FAILED';
}

/**
 * 持久化姿势资产记录 (Phase 3D-1)。
 *
 * 字段:
 * - poseId: 唯一标识 (pose_<timestamp>_<random>)
 * - displayName: 用户可读显示名 (来自用户文件名,已做安全清理)
 * - relativePath: 相对 filesDir/avatar-assets/ 的路径 (如 "poses/pose_xxx.json")
 * - byteLength: 文件大小 (字节)
 * - format: JSON 姿势格式标识 (固定为 "json")
 * - createdAt: 创建时间戳 (ms)
 * - updatedAt: 更新时间戳 (ms)
 *
 * 禁止字段:
 * - absolutePath
 * - cachePath
 * - sourceUri
 * - ArkWeb URL
 * - 文件描述符
 *
 * 本阶段不保存骨骼数据, 只保存文件元数据;
 * 骨骼数据通过 PersistentPoseStore 解析 .json 文件获得。
 */
export interface ArkWebAvatarPoseAsset {
  poseId: string;
  displayName: string;
  relativePath: string;
  byteLength: number;
  format: string;
  createdAt: number;
  updatedAt: number;
}

/**
 * 持久化姿势资产错误码 (Phase 3D-1)。
 */
export class PersistentPoseErrorCode {
  /** PersistentPoseStore 已销毁。 */
  static readonly POSE_STORE_DISPOSED: string = 'POSE_STORE_DISPOSED';
  /** AssetLibrary 未初始化或已销毁。 */
  static readonly POSE_STORE_LIBRARY_INVALID: string = 'POSE_STORE_LIBRARY_INVALID';
  /** 源文件打开失败。 */
  static readonly POSE_SOURCE_OPEN_FAILED: string = 'POSE_SOURCE_OPEN_FAILED';
  /** 源文件为空 (size === 0)。 */
  static readonly POSE_FILE_EMPTY: string = 'POSE_FILE_EMPTY';
  /** 目标 .part 文件创建失败。 */
  static readonly POSE_TARGET_CREATE_FAILED: string = 'POSE_TARGET_CREATE_FAILED';
  /** 复制过程读取失败。 */
  static readonly POSE_FILE_READ_FAILED: string = 'POSE_FILE_READ_FAILED';
  /** 复制过程写入失败。 */
  static readonly POSE_FILE_WRITE_FAILED: string = 'POSE_FILE_WRITE_FAILED';
  /** 复制不完整 (写入字节数与源大小不一致)。 */
  static readonly POSE_FILE_COPY_INCOMPLETE: string = 'POSE_FILE_COPY_INCOMPLETE';
  /** rename .part → 最终文件失败。 */
  static readonly POSE_RENAME_FAILED: string = 'POSE_RENAME_FAILED';
  /** 清单写入失败 (回滚: 删除新姿势文件)。 */
  static readonly POSE_LIBRARY_WRITE_FAILED: string = 'POSE_LIBRARY_WRITE_FAILED';
  /** JSON 解析失败。 */
  static readonly POSE_JSON_PARSE_FAILED: string = 'POSE_JSON_PARSE_FAILED';
  /** JSON 根节点不是对象。 */
  static readonly POSE_JSON_ROOT_NOT_OBJECT: string = 'POSE_JSON_ROOT_NOT_OBJECT';
  /** JSON 结构不支持 (无可识别的骨骼或姿势数据对象)。 */
  static readonly POSE_JSON_SCHEMA_UNSUPPORTED: string = 'POSE_JSON_SCHEMA_UNSUPPORTED';
}

/**
 * 姿势导入错误码 (Phase 3D-1)。
 */
export class PoseImportErrorCode {
  /** 文件扩展名不是 .json。 */
  static readonly POSE_IMPORT_EXTENSION_INVALID: string = 'POSE_IMPORT_EXTENSION_INVALID';
  /** 文件名为空。 */
  static readonly POSE_IMPORT_FILENAME_EMPTY: string = 'POSE_IMPORT_FILENAME_EMPTY';
  /** 文件名为目录或包含路径分隔符。 */
  static readonly POSE_IMPORT_FILENAME_INVALID: string = 'POSE_IMPORT_FILENAME_INVALID';
  /** 文件为空。 */
  static readonly POSE_IMPORT_FILE_EMPTY: string = 'POSE_IMPORT_FILE_EMPTY';
  /** JSON 解析失败。 */
  static readonly POSE_IMPORT_JSON_PARSE_FAILED: string = 'POSE_IMPORT_JSON_PARSE_FAILED';
  /** JSON 结构不支持。 */
  static readonly POSE_IMPORT_JSON_UNSUPPORTED: string = 'POSE_IMPORT_JSON_UNSUPPORTED';
}

/**
 * 默认姿势管理错误码 (Phase 3D-3)。
 *
 * 覆盖:
 * - 设置/取消默认姿势时的清单写入失败
 * - 默认姿势自动恢复流程中的各阶段失败
 *
 * 失败策略: 默认姿势恢复失败不修改 ViewerState / ModelState,
 * 保留手动选择和应用姿势功能, 只显示一次非阻塞提示。
 */
export class DefaultPoseErrorCode {
  /** 默认姿势 poseId 在清单 poses 中找不到 (POSE_DEFAULT_NOT_FOUND)。 */
  static readonly POSE_DEFAULT_NOT_FOUND: string = 'POSE_DEFAULT_NOT_FOUND';
  /** 默认姿势文件不存在 (POSE_DEFAULT_FILE_MISSING)。 */
  static readonly POSE_DEFAULT_FILE_MISSING: string = 'POSE_DEFAULT_FILE_MISSING';
  /** 默认姿势 JSON 解析失败 (POSE_DEFAULT_PARSE_FAILED)。 */
  static readonly POSE_DEFAULT_PARSE_FAILED: string = 'POSE_DEFAULT_PARSE_FAILED';
  /** 默认姿势应用失败 (POSE_DEFAULT_APPLY_FAILED)。 */
  static readonly POSE_DEFAULT_APPLY_FAILED: string = 'POSE_DEFAULT_APPLY_FAILED';
  /** 默认姿势恢复代次过期 (POSE_DEFAULT_RESTORE_STALE)。 */
  static readonly POSE_DEFAULT_RESTORE_STALE: string = 'POSE_DEFAULT_RESTORE_STALE';
  /** 默认姿势标记更新时清单写入失败。 */
  static readonly POSE_DEFAULT_WRITE_FAILED: string = 'POSE_DEFAULT_WRITE_FAILED';
}

/**
 * 默认姿势恢复状态机 (Phase 3D-3)。
 *
 * 状态流转:
 *   IDLE → WAITING_MODEL → LOADING → APPLYING → READY
 *   IDLE → EMPTY (defaultPoseId 为空)
 *   任意 → FAILED (恢复失败, 不影响 ViewerState / ModelState)
 *   任意 → DISPOSED (页面销毁)
 */
export enum DefaultPoseRestoreState {
  IDLE = 'IDLE',
  WAITING_MODEL = 'WAITING_MODEL',
  LOADING = 'LOADING',
  APPLYING = 'APPLYING',
  READY = 'READY',
  EMPTY = 'EMPTY',
  FAILED = 'FAILED',
  DISPOSED = 'DISPOSED'
}

/**
 * 表情别名固定业务 ID (Phase 3E-2)。
 *
 * 这 6 个 ID 是业务层固定语义,所有模型使用相同 ID。
 * 不同模型仍只使用其真实存在的 Expression,通过 expressionAliases 映射。
 *
 * 不得假定模型一定支持其中任何项;无法解析时返回 EXPRESSION_ALIAS_NOT_RESOLVED。
 */
export class ArkWebExpressionAliasBusinessId {
  static readonly NEUTRAL: string = 'neutral';
  static readonly HAPPY: string = 'happy';
  static readonly ANGRY: string = 'angry';
  static readonly SAD: string = 'sad';
  static readonly RELAXED: string = 'relaxed';
  static readonly SURPRISED: string = 'surprised';

  /** 全部允许的业务 ID。 */
  static readonly ALL: string[] = ['neutral', 'happy', 'angry', 'sad', 'relaxed', 'surprised'];

  /** 判断 expressionId 是否为合法业务 ID。 */
  static isValid(expressionId: string): boolean {
    return typeof expressionId === 'string' && ArkWebExpressionAliasBusinessId.ALL.indexOf(expressionId) !== -1;
  }
}

/**
 * 表情别名管理错误码 (Phase 3E-2)。
 *
 * 覆盖:
 * - 设置/取消别名映射时的清单写入失败
 * - modelId 不存在 / expressionId 非法 / expressionName 非空校验失败
 *
 * 失败策略: 别名操作失败不修改 ViewerState / ModelState / AnimationState / PoseState。
 */
export class ExpressionAliasErrorCode {
  /** modelId 在清单 models 中找不到。 */
  static readonly EXPRESSION_ALIAS_MODEL_NOT_FOUND: string = 'EXPRESSION_ALIAS_MODEL_NOT_FOUND';
  /** expressionId 不属于固定业务 ID (neutral/happy/angry/sad/relaxed/surprised)。 */
  static readonly EXPRESSION_ALIAS_BUSINESS_ID_INVALID: string = 'EXPRESSION_ALIAS_BUSINESS_ID_INVALID';
  /** expressionName 为空或非字符串。 */
  static readonly EXPRESSION_ALIAS_NAME_INVALID: string = 'EXPRESSION_ALIAS_NAME_INVALID';
  /** 清单写入失败。 */
  static readonly EXPRESSION_ALIAS_WRITE_FAILED: string = 'EXPRESSION_ALIAS_WRITE_FAILED';
  /** AssetLibrary 已销毁。 */
  static readonly EXPRESSION_ALIAS_DISPOSED: string = 'EXPRESSION_ALIAS_DISPOSED';
}
