import { Logger } from '../utils/Logger';
/**
 * ArkWebModelImportStateStore — 导入模型元数据持久化(Phase 1D-2C-1)
 *
 * 职责:
 * - 把 ArkWebFileImportController 产出的 ImportedModelFile 元数据持久化到 Preferences
 * - 页面重进后恢复元数据,并重新校验缓存文件存在性与大小
 * - 用户点击"清除缓存"或检测到损坏记录时清除 Preferences
 *
 * 安全约束:
 * - 只持久化白名单字段(见 PersistedModelFile)
 * - 禁止持久化 sourceUri / 文件描述符 / Provider 内部对象 / resourceUrl / opaque id /
 *   ProbeResult / LoadResult
 * - cachePath 只允许保存在应用内部 Preferences,不得传给 JavaScript / ArkWeb 页面 / UI 文本 / 日志
 *
 * 持久化时机:
 * - 缓存文件完整复制
 * - rename .part 成功
 * - 文件大小验证通过
 * 之后调用 save()
 *
 * 恢复时安全验证:
 * - schemaVersion 正确
 * - cachePath 位于 <context.cacheDir>/vrm-imports/
 * - 路径不存在 ..
 * - 文件存在
 * - 文件不是目录
 * - stat.size === saved.size
 * - size > 0
 * - extension 为 vrm/glb/gltf
 * - MIME 与扩展名一致
 * - gltfDependencyState 合法
 *
 * Reference:
 * - AGENTS.md Phase 1D-2C-1 §五 / §六 / §七 / §八
 * - SDK: @kit.ArkData preferences (API 23)
 * - SDK: @kit.CoreFileKit fileIo (stat / access)
 */

import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  GltfDependencyState,
  ImportedModelFile,
  ModelFileType
} from './ArkWebModelImportTypes';
import { CACHE_SUBDIR } from './ArkWebModelImportTypes';

/**
 * 持久化记录的 schema 版本。
 * 字段结构变更时递增,旧版本记录视为损坏,直接清除。
 */
const PERSIST_SCHEMA_VERSION: number = 1;

/**
 * 持久化的字段白名单(ImportedModelFile 子集)。
 *
 * 禁止持久化字段:
 * - sourceUri(用户原始 URI,可能含敏感路径)
 * - 文件描述符(运行时资源,无意义)
 * - Provider 内部对象 / resourceUrl / opaque resource id
 * - ProbeResult / LoadResult(运行时状态,与当前 ArkWeb 实例绑定)
 */
interface PersistedModelFile {
  /** 持久化记录 schema 版本。 */
  schemaVersion: number;
  /** 唯一 ID(时间戳+代次,便于日志追踪)。 */
  id: string;
  /** 用户可读显示名(已做安全清理)。 */
  displayName: string;
  /** 小写扩展名(不含点)。 */
  extension: string;
  /** 文件类型枚举。 */
  fileType: string;
  /** MIME 类型(根据扩展名统一生成)。 */
  mimeType: string;
  /** 受控缓存绝对路径(<cacheDir>/vrm-imports/<timestamp>-<gen>.<ext>)。 */
  cachePath: string;
  /** 文件大小(字节)。 */
  size: number;
  /** 创建时间戳(ms)。 */
  createdAt: number;
  /** glTF 外部依赖预检状态。 */
  gltfDependencyState: string;
  /** glTF 外部依赖 URI 列表(仅 .gltf 文件)。 */
  gltfExternalUris: string[];
}

/**
 * 恢复失败原因(用于页面提示与日志记录)。
 */
export enum ImportStateRestoreError {
  /** Preferences 读取失败。 */
  PREFS_READ_FAILED = 'PREFS_READ_FAILED',
  /** JSON 解析失败。 */
  JSON_PARSE_FAILED = 'JSON_PARSE_FAILED',
  /** schemaVersion 不匹配。 */
  SCHEMA_VERSION_MISMATCH = 'SCHEMA_VERSION_MISMATCH',
  /** cachePath 不在受控缓存目录下。 */
  CACHE_PATH_OUT_OF_DIRECTORY = 'CACHE_PATH_OUT_OF_DIRECTORY',
  /** cachePath 包含 .. 路径穿越。 */
  CACHE_PATH_TRAVERSAL = 'CACHE_PATH_TRAVERSAL',
  /** 缓存文件不存在。 */
  CACHE_FILE_NOT_FOUND = 'CACHE_FILE_NOT_FOUND',
  /** cachePath 指向目录而非文件。 */
  CACHE_PATH_IS_DIRECTORY = 'CACHE_PATH_IS_DIRECTORY',
  /** stat.size 与 saved.size 不一致。 */
  CACHE_SIZE_MISMATCH = 'CACHE_SIZE_MISMATCH',
  /** 文件大小为 0。 */
  CACHE_SIZE_ZERO = 'CACHE_SIZE_ZERO',
  /** 扩展名不在白名单。 */
  EXTENSION_INVALID = 'EXTENSION_INVALID',
  /** MIME 与扩展名不一致。 */
  MIME_MISMATCH = 'MIME_MISMATCH',
  /** gltfDependencyState 非法。 */
  GLTF_DEPENDENCY_STATE_INVALID = 'GLTF_DEPENDENCY_STATE_INVALID',
  /** 字段缺失或类型错误。 */
  FIELD_INVALID = 'FIELD_INVALID',
}

/**
 * 导入状态恢复结果。
 */
export interface ImportStateRestoreResult {
  /** 恢复成功时为 ImportedModelFile,失败时为 null。 */
  file: ImportedModelFile | null;
  /** 失败原因(成功时为空字符串)。 */
  errorCode: string;
  /** 失败详情(成功时为空字符串)。 */
  errorMessage: string;
}

/**
 * 导入状态持久化存储。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例,传入 UIAbilityContext
 * 2. 成功导入文件并完成受控缓存复制后调用 save()
 * 3. 页面重进后调用 restore() 恢复元数据
 * 4. 用户点击"清除缓存"或检测到损坏记录时调用 clear()
 * 5. 页面 aboutToDisappear 调用 dispose()(不清除记录)
 */
export class ArkWebModelImportStateStore {
  /** Preferences 文件名(独立于 AppPreferences 的 arktavern_settings)。 */
  private static readonly STORE_NAME: string = 'ark_tavern_vrm_import_state';
  /** 存储键名。 */
  private static readonly STORAGE_KEY: string = 'current_imported_model';

  /** Preferences 实例(延迟初始化)。 */
  private prefs: preferences.Preferences | null = null;
  /** 是否已销毁。 */
  private disposed: boolean = false;
  /** 应用上下文(用于 cacheDir 校验)。 */
  private readonly context: common.UIAbilityContext;
  /** 受控缓存目录绝对路径(<context.cacheDir>/vrm-imports)。 */
  private readonly importDirectory: string;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    const rawDir: string = `${context.cacheDir}/${CACHE_SUBDIR}`;
    this.importDirectory = this.normalizePath(rawDir);
  }

  /**
   * 初始化 Preferences 实例(延迟初始化,首次 save/restore 时调用)。
   */
  private async ensureInitialized(): Promise<preferences.Preferences> {
    if (this.prefs !== null) {
      return this.prefs;
    }
    this.prefs = await preferences.getPreferences(this.context, ArkWebModelImportStateStore.STORE_NAME);
    return this.prefs;
  }

  /**
   * 保存导入模型元数据。
   *
   * 持久化时机:
   * - 缓存文件完整复制
   * - rename .part 成功
   * - 文件大小验证通过
   * 之后调用。
   *
   * 如果 Preferences 保存失败:
   * - 缓存文件与当前导入仍可继续使用
   * - 页面应显示"模型已导入,但重进恢复信息保存失败"
   * - 不删除缓存文件
   *
   * @param file 已成功导入的模型文件
   * @returns 保存成功返回 true,失败返回 false(不抛异常)
   */
  async save(file: ImportedModelFile): Promise<boolean> {
    if (this.disposed) {
      return false;
    }

    const persisted: PersistedModelFile = {
      schemaVersion: PERSIST_SCHEMA_VERSION,
      id: file.id,
      displayName: file.displayName,
      extension: file.extension,
      fileType: file.fileType,
      mimeType: file.mimeType,
      cachePath: file.cachePath,
      size: file.size,
      createdAt: file.createdAt,
      gltfDependencyState: file.gltfDependencyState,
      gltfExternalUris: file.gltfExternalUris
    };

    try {
      const json: string = JSON.stringify(persisted);
      const prefs: preferences.Preferences = await this.ensureInitialized();
      await prefs.put(ArkWebModelImportStateStore.STORAGE_KEY, json);
      await prefs.flush();
      // 只记录 id / size / extension,不记录 cachePath
      Logger.debug(`[ArkWebModelImportStateStore] save ok id=${file.id} size=${file.size} ext=${file.extension}`);
      return true;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.warn(`[ArkWebModelImportStateStore] save failed: ${msg}`);
      return false;
    }
  }

  /**
   * 恢复上次导入的模型元数据。
   *
   * 恢复时安全验证(任一失败则清除记录并返回 null):
   * 1. schemaVersion 正确
   * 2. cachePath 位于 <context.cacheDir>/vrm-imports/
   * 3. 路径不存在 ..
   * 4. 文件存在
   * 5. 文件不是目录
   * 6. stat.size === saved.size
   * 7. size > 0
   * 8. extension 为 vrm/glb/gltf
   * 9. MIME 与扩展名一致
   * 10. gltfDependencyState 合法
   *
   * @returns 恢复结果(成功含 file,失败含 errorCode/errorMessage)
   */
  async restore(): Promise<ImportStateRestoreResult> {
    if (this.disposed) {
      return {
        file: null,
        errorCode: '',
        errorMessage: 'StateStore disposed'
      };
    }

    let json: string;
    try {
      const prefs: preferences.Preferences = await this.ensureInitialized();
      const value: preferences.ValueType =
        await prefs.get(ArkWebModelImportStateStore.STORAGE_KEY, '');
      if (typeof value !== 'string' || value.length === 0) {
        return {
          file: null,
          errorCode: '',
          errorMessage: ''
        };
      }
      json = value;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.warn(`[ArkWebModelImportStateStore] restore prefs read failed: ${msg}`);
      return {
        file: null,
        errorCode: ImportStateRestoreError.PREFS_READ_FAILED,
        errorMessage: `Preferences read failed: ${msg}`
      };
    }

    // 解析 JSON
    let parsed: PersistedModelFile;
    try {
      const obj: object = JSON.parse(json);
      parsed = this.coerceToPersisted(obj);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.warn(`[ArkWebModelImportStateStore] restore json parse failed: ${msg}`);
      await this.clearInternal();
      return {
        file: null,
        errorCode: ImportStateRestoreError.JSON_PARSE_FAILED,
        errorMessage: `JSON parse failed: ${msg}`
      };
    }

    // 验证字段并恢复
    const validationResult: ImportStateRestoreResult = await this.validateAndBuild(parsed);
    if (validationResult.file === null) {
      // 验证失败:清除损坏记录
      await this.clearInternal();
      Logger.warn(`[ArkWebModelImportStateStore] restore validation failed: ${validationResult.errorCode}`);
    }
    return validationResult;
  }

  /**
   * 清除 Preferences 中的导入记录。
   *
   * 调用场景:
   * - 用户点击"清除缓存"
   * - restore 检测到损坏记录
   *
   * 不删除缓存文件本身(由 ArkWebFileImportController.clearCurrentFile 负责)。
   */
  async clear(): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.clearInternal();
  }

  /**
   * 销毁 StateStore。
   *
   * - 标记 disposed
   * - 不清除 Preferences 记录(页面销毁时保留)
   * - 不关闭 Preferences 实例(由平台管理)
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.prefs = null;
  }

  // ===== 内部方法 =====

  /**
   * 把 JSON.parse 返回的 object 强制为 PersistedModelFile 结构。
   * 字段缺失或类型不匹配时抛异常。
   */
  private coerceToPersisted(obj: object): PersistedModelFile {
    const o: Record<string, Object> = obj as Record<string, Object>;
    const required: PersistedModelFile = {
      schemaVersion: this.requireNumber(o, 'schemaVersion'),
      id: this.requireString(o, 'id'),
      displayName: this.requireString(o, 'displayName'),
      extension: this.requireString(o, 'extension'),
      fileType: this.requireString(o, 'fileType'),
      mimeType: this.requireString(o, 'mimeType'),
      cachePath: this.requireString(o, 'cachePath'),
      size: this.requireNumber(o, 'size'),
      createdAt: this.requireNumber(o, 'createdAt'),
      gltfDependencyState: this.requireString(o, 'gltfDependencyState'),
      gltfExternalUris: this.requireStringArray(o, 'gltfExternalUris')
    };
    return required;
  }

  private requireNumber(o: Record<string, Object>, key: string): number {
    const v: Object | undefined = o[key];
    if (typeof v !== 'number' || !Number.isFinite(v)) {
      throw new Error(`Field ${key} missing or not a finite number`);
    }
    return v;
  }

  private requireString(o: Record<string, Object>, key: string): string {
    const v: Object | undefined = o[key];
    if (typeof v !== 'string') {
      throw new Error(`Field ${key} missing or not a string`);
    }
    return v;
  }

  private requireStringArray(o: Record<string, Object>, key: string): string[] {
    const v: Object | undefined = o[key];
    if (!Array.isArray(v)) {
      throw new Error(`Field ${key} missing or not an array`);
    }
    const arr: string[] = [];
    for (let i = 0; i < v.length; i++) {
      const item: Object = v[i];
      if (typeof item !== 'string') {
        throw new Error(`Field ${key}[${i}] not a string`);
      }
      arr.push(item);
    }
    return arr;
  }

  /**
   * 验证持久化记录并构造 ImportedModelFile。
   */
  private async validateAndBuild(p: PersistedModelFile): Promise<ImportStateRestoreResult> {
    // 1. schemaVersion
    if (p.schemaVersion !== PERSIST_SCHEMA_VERSION) {
      return this.fail(ImportStateRestoreError.SCHEMA_VERSION_MISMATCH,
        `schemaVersion=${p.schemaVersion}, expected=${PERSIST_SCHEMA_VERSION}`);
    }

    // 2. cachePath 位于受控目录下
    if (!p.cachePath.startsWith(this.importDirectory + '/')) {
      return this.fail(ImportStateRestoreError.CACHE_PATH_OUT_OF_DIRECTORY,
        `cachePath not under ${this.importDirectory}`);
    }

    // 3. 路径不存在 ..
    if (p.cachePath.includes('..')) {
      return this.fail(ImportStateRestoreError.CACHE_PATH_TRAVERSAL,
        'cachePath contains ..');
    }

    // 4/5. 文件存在且不是目录
    let exists: boolean;
    try {
      exists = await fileIo.access(p.cachePath);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      return this.fail(ImportStateRestoreError.CACHE_FILE_NOT_FOUND,
        `access failed: ${msg}`);
    }
    if (!exists) {
      return this.fail(ImportStateRestoreError.CACHE_FILE_NOT_FOUND,
        `cache file does not exist`);
    }

    // 6/7. stat.size === saved.size 且 > 0
    let stat: fileIo.Stat;
    try {
      stat = await fileIo.stat(p.cachePath);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      return this.fail(ImportStateRestoreError.CACHE_FILE_NOT_FOUND,
        `stat failed: ${msg}`);
    }
    let isDir: boolean;
    try {
      isDir = stat.isDirectory();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      return this.fail(ImportStateRestoreError.CACHE_PATH_IS_DIRECTORY,
        `isDirectory check failed: ${msg}`);
    }
    if (isDir) {
      return this.fail(ImportStateRestoreError.CACHE_PATH_IS_DIRECTORY,
        'cachePath is a directory');
    }
    if (stat.size !== p.size) {
      return this.fail(ImportStateRestoreError.CACHE_SIZE_MISMATCH,
        `stat.size=${stat.size}, saved.size=${p.size}`);
    }
    if (p.size <= 0) {
      return this.fail(ImportStateRestoreError.CACHE_SIZE_ZERO,
        `size=${p.size}`);
    }

    // 8. 扩展名白名单
    if (p.extension !== 'vrm' && p.extension !== 'glb' && p.extension !== 'gltf') {
      return this.fail(ImportStateRestoreError.EXTENSION_INVALID,
        `extension=${p.extension}`);
    }

    // 9. MIME 与扩展名一致
    const expectedMime: string = this.mimeForExtension(p.extension);
    if (p.mimeType !== expectedMime) {
      return this.fail(ImportStateRestoreError.MIME_MISMATCH,
        `mimeType=${p.mimeType}, expected=${expectedMime}`);
    }

    // 10. gltfDependencyState 合法
    if (!this.isValidGltfDependencyState(p.gltfDependencyState)) {
      return this.fail(ImportStateRestoreError.GLTF_DEPENDENCY_STATE_INVALID,
        `gltfDependencyState=${p.gltfDependencyState}`);
    }

    // 11. fileType 合法(与 extension 一致)
    const expectedFileType: ModelFileType = this.fileTypeForExtension(p.extension);
    if (p.fileType !== expectedFileType) {
      return this.fail(ImportStateRestoreError.FIELD_INVALID,
        `fileType=${p.fileType}, expected=${expectedFileType}`);
    }

    // 全部验证通过:构造 ImportedModelFile
    // 注意:sourceUri 不持久化,恢复时填空字符串
    const file: ImportedModelFile = {
      id: p.id,
      displayName: p.displayName,
      extension: p.extension,
      fileType: expectedFileType,
      mimeType: p.mimeType,
      sourceUri: '',
      cachePath: p.cachePath,
      size: p.size,
      createdAt: p.createdAt,
      gltfDependencyState: p.gltfDependencyState as GltfDependencyState,
      gltfExternalUris: p.gltfExternalUris
    };

    // 只记录 id / size / extension,不记录 cachePath
    Logger.debug(`[ArkWebModelImportStateStore] restore ok id=${file.id} size=${file.size} ext=${file.extension}`);

    return {
      file: file,
      errorCode: '',
      errorMessage: ''
    };
  }

  private fail(code: string, message: string): ImportStateRestoreResult {
    return {
      file: null,
      errorCode: code,
      errorMessage: message
    };
  }

  private mimeForExtension(ext: string): string {
    if (ext === 'gltf') {
      return 'model/gltf+json';
    }
    return 'model/gltf-binary';
  }

  private fileTypeForExtension(ext: string): ModelFileType {
    if (ext === 'vrm') {
      return ModelFileType.VRM;
    } else if (ext === 'glb') {
      return ModelFileType.GLB;
    }
    return ModelFileType.GLTF;
  }

  private isValidGltfDependencyState(s: string): boolean {
    return s === GltfDependencyState.NOT_APPLICABLE ||
      s === GltfDependencyState.SELF_CONTAINED ||
      s === GltfDependencyState.EXTERNAL_FILES_REQUIRED ||
      s === GltfDependencyState.REMOTE_RESOURCES_FOUND ||
      s === GltfDependencyState.INVALID_JSON;
  }

  /**
   * 路径规范化(去除末尾多余的 /)。
   */
  private normalizePath(p: string): string {
    if (p.length > 1 && p.charAt(p.length - 1) === '/') {
      return p.substring(0, p.length - 1);
    }
    return p;
  }

  /**
   * 内部清除(不检查 disposed)。
   */
  private async clearInternal(): Promise<void> {
    try {
      const prefs: preferences.Preferences = await this.ensureInitialized();
      await prefs.delete(ArkWebModelImportStateStore.STORAGE_KEY);
      await prefs.flush();
      Logger.debug('[ArkWebModelImportStateStore] clear ok');
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.warn(`[ArkWebModelImportStateStore] clear failed: ${msg}`);
    }
  }
}
