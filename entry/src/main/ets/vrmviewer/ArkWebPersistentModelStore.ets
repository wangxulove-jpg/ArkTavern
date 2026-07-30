/**
 * ArkWebPersistentModelStore — 持久化模型存储 (Phase 3B)
 *
 * 职责 (AGENTS.md Phase 3B §十六):
 * - 导入文件到 filesDir/avatar-assets/models/
 * - 验证文件 (非空 / 大小)
 * - 生成 modelId (model_<timestamp>_<random>)
 * - 生成 resourceId (可与 modelId 相同)
 * - 创建 relativePath (models/<modelId>.vrm)
 * - 原子复制模型 (.part → rename)
 * - 构造 ArkWebAvatarModelAsset
 * - 删除失败的临时文件
 * - 读取模型文件信息
 * - 将模型记录交给 AssetLibrary 提交
 *
 * 持久目录 (AGENTS.md Phase 3B §四):
 * - <context.filesDir>/avatar-assets/models/
 * - 目标文件: <modelId>.vrm
 * - 临时文件: <modelId>.vrm.part
 *
 * 安全约束:
 * - modelId 只包含 a-z A-Z 0-9 _ -
 * - 不使用原始文件名
 * - 不包含路径分隔符
 * - 相对路径必须以 "models/" 开头
 *
 * 原子复制流程 (AGENTS.md Phase 3B §十六):
 * 1. 打开源 URI (只读)
 * 2. stat 获取源文件大小
 * 3. 校验非空
 * 4. 创建 .part 临时文件
 * 5. 分块复制 (64 KiB 缓冲)
 * 6. 验证写入大小
 * 7. rename .part → 最终文件
 * 8. 构造 ArkWebAvatarModelAsset
 *
 * 失败处理:
 * - 关闭文件描述符
 * - 删除 .part 临时文件
 * - 不覆盖已有模型文件
 *
 * Reference:
 * - SDK: @kit.CoreFileKit fileIo (open / read / write / rename / stat / mkdir)
 * - SDK: @kit.CoreFileKit picker (DocumentViewPicker)
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import {
  ArkWebAvatarModelAsset,
  ArkWebAvatarAssetLibraryData
} from './ArkWebAvatarAssetTypes';
import {
  ArkWebAvatarAssetLibrary,
  AVATAR_ASSETS_DIR_NAME,
  MODELS_SUBDIR_NAME
} from './ArkWebAvatarAssetLibrary';

/**
 * 复制缓冲区大小: 64 KiB。
 */
const PERSISTENT_COPY_BUFFER_SIZE: number = 64 * 1024;

/**
 * modelId 长度 (model_ 前缀 + 13 位时间戳 + 1 个 _ + 8 位随机 = 28)
 */
const MODEL_ID_RANDOM_LENGTH: number = 8;

/**
 * 持久化模型存储。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例,传入 UIAbilityContext 和 AssetLibrary
 * 2. 用户选择文件后调用 importModel(sourceUri, displayName, extension)
 * 3. 成功返回 ArkWebAvatarModelAsset,失败返回 null (查看 lastError)
 * 4. 页面 aboutToDisappear 调用 dispose()
 */
export class ArkWebPersistentModelStore {
  /** 应用上下文 (用于 filesDir)。 */
  private readonly context: common.UIAbilityContext;
  /** 资产清单 (单一所有者)。 */
  private readonly assetLibrary: ArkWebAvatarAssetLibrary;
  /** 模型目录绝对路径 (<filesDir>/avatar-assets/models)。 */
  private readonly modelsDir: string;
  /** 是否已销毁。 */
  private disposed: boolean = false;
  /** 最近一次错误消息。 */
  private lastError: string = '';

  constructor(context: common.UIAbilityContext, assetLibrary: ArkWebAvatarAssetLibrary) {
    this.context = context;
    this.assetLibrary = assetLibrary;
    this.modelsDir = assetLibrary.getModelsDir();
  }

  /** 获取最近一次错误消息。 */
  getLastError(): string {
    return this.lastError;
  }

  /**
   * 导入模型文件到持久目录。
   *
   * 流程 (AGENTS.md Phase 3B §十八):
   * 1. 验证扩展名 (vrm/glb/gltf)
   * 2. 验证 displayName 非空
   * 3. 生成 modelId 和 resourceId
   * 4. 打开源 URI
   * 5. stat 获取源文件大小
   * 6. 校验非空
   * 7. 创建 .part 临时文件
   * 8. 分块复制
   * 9. 验证写入大小
   * 10. rename .part → 最终文件
   * 11. 构造 ArkWebAvatarModelAsset
   * 12. 提交到 AssetLibrary (upsertModelAndSetActive)
   *     - 若 AssetLibrary 写入失败: 删除新模型文件,返回 null
   *
   * @param sourceUri 系统 Picker 返回的文件 URI
   * @param displayName 用户可读显示名 (已做安全清理)
   * @param extension 小写扩展名 (vrm/glb/gltf)
   * @returns 成功返回 ArkWebAvatarModelAsset;失败返回 null
   */
  async importModel(
    sourceUri: string,
    displayName: string,
    extension: string
  ): Promise<ArkWebAvatarModelAsset | null> {
    if (this.disposed) {
      this.lastError = 'PersistentModelStore disposed';
      return null;
    }
    if (extension !== 'vrm' && extension !== 'glb' && extension !== 'gltf') {
      this.lastError = `unsupported extension: ${extension}`;
      return null;
    }
    if (displayName.length === 0) {
      this.lastError = 'displayName is empty';
      return null;
    }
    if (sourceUri.length === 0) {
      this.lastError = 'sourceUri is empty';
      return null;
    }

    // 确保 AssetLibrary 已初始化 (目录和 library.json)
    const initOk: boolean = await this.assetLibrary.ensureInitialized();
    if (!initOk) {
      this.lastError = 'AssetLibrary ensureInitialized failed';
      return null;
    }

    // 生成 ID
    const modelId: string = this.generateModelId();
    const resourceId: string = modelId; // resourceId 与 modelId 相同
    const relativePath: string = `models/${modelId}.${extension}`;
    const finalPath: string = `${this.modelsDir}/${modelId}.${extension}`;
    const partPath: string = `${finalPath}.part`;
    const mimeType: string = this.getMimeType(extension);

    let sourceFile: fileIo.File | null = null;
    let targetFile: fileIo.File | null = null;
    let sourceSize: number = 0;
    let writtenTotal: number = 0;
    let copySucceeded: boolean = false;

    try {
      // 1. 打开源文件
      try {
        sourceFile = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `open source failed: ${msg}`;
        return null;
      }

      // 2. stat 获取大小
      try {
        const stat: fileIo.Stat = await fileIo.stat(sourceFile.fd);
        sourceSize = stat.size;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `stat source failed: ${msg}`;
        return null;
      }

      // 3. 校验非空
      if (sourceSize <= 0) {
        this.lastError = `source file is empty (size=${sourceSize})`;
        return null;
      }

      // 4. 创建 .part 临时文件
      try {
        targetFile = await fileIo.open(partPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `create .part failed: ${msg}`;
        return null;
      }

      // 5. 分块复制
      const buffer: ArrayBuffer = new ArrayBuffer(PERSISTENT_COPY_BUFFER_SIZE);
      writtenTotal = 0;
      try {
        while (writtenTotal < sourceSize) {
          const remaining: number = sourceSize - writtenTotal;
          const readLen: number = remaining < PERSISTENT_COPY_BUFFER_SIZE ? remaining : PERSISTENT_COPY_BUFFER_SIZE;
          const bytesRead: number = await fileIo.read(sourceFile.fd, buffer, {
            offset: writtenTotal,
            length: readLen
          });
          if (bytesRead <= 0) {
            break;
          }
          const bytesWritten: number = await fileIo.write(targetFile.fd, buffer, {
            offset: writtenTotal,
            length: bytesRead
          });
          if (bytesWritten !== bytesRead) {
            this.lastError = `write incomplete: expected ${bytesRead}, got ${bytesWritten}`;
            return null;
          }
          writtenTotal += bytesWritten;
        }
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `copy failed: ${msg}`;
        return null;
      }

      // 6. 验证写入大小
      if (writtenTotal !== sourceSize) {
        this.lastError = `copy incomplete: source ${sourceSize}, written ${writtenTotal}`;
        return null;
      }

      // 7. 关闭文件描述符 (rename 前必须关闭)
      await this.closeFile(sourceFile);
      sourceFile = null;
      await this.closeFile(targetFile);
      targetFile = null;

      // 8. rename .part → 最终文件
      try {
        await fileIo.rename(partPath, finalPath);
        copySucceeded = true;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `rename failed: ${msg}`;
        return null;
      }

      // 9. 构造 ArkWebAvatarModelAsset
      const now: number = Date.now();
      const asset: ArkWebAvatarModelAsset = {
        modelId: modelId,
        resourceId: resourceId,
        displayName: displayName,
        relativePath: relativePath,
        mimeType: mimeType,
        byteLength: sourceSize,
        createdAt: now,
        updatedAt: now,
        expressionAliases: {}
      };

      // 10. 提交到 AssetLibrary
      const commitOk: boolean = await this.assetLibrary.upsertModelAndSetActive(asset);
      if (!commitOk) {
        // AssetLibrary 写入失败: 删除新模型文件,保留旧清单
        console.warn(`[ArkWebPersistentModelStore] AssetLibrary commit failed, deleting new model file: ${modelId}`);
        await this.safeUnlink(finalPath);
        this.lastError = 'AssetLibrary commit failed (model file deleted)';
        return null;
      }

      console.info(`[ArkWebPersistentModelStore] importModel ok modelId=${modelId} size=${sourceSize} ext=${extension}`);
      return asset;
    } finally {
      // 确保所有文件描述符关闭
      if (sourceFile !== null) {
        await this.closeFile(sourceFile);
        sourceFile = null;
      }
      if (targetFile !== null) {
        await this.closeFile(targetFile);
        targetFile = null;
      }
      // 失败时清理 .part 临时文件
      if (!copySucceeded) {
        await this.safeUnlink(partPath);
      }
    }
  }

  /**
   * 从旧 cacheDir 缓存迁移模型到 filesDir 持久目录。
   *
   * 流程 (AGENTS.md Phase 3B §十九):
   * 1. 验证旧缓存文件存在
   * 2. 验证文件大小 > 0
   * 3. 复制到 filesDir 持久目录的 .part 文件
   * 4. 验证新文件
   * 5. rename
   * 6. 写入 library.json (通过 AssetLibrary)
   * 7. 设置 activeModelId
   *
   * 失败: 不删除旧缓存
   *
   * @param legacyCachePath 旧缓存绝对路径 (<cacheDir>/vrm-imports/...)
   * @param displayName 显示名
   * @param extension 扩展名
   * @param expectedSize 预期大小 (用于校验)
   * @returns 成功返回 ArkWebAvatarModelAsset;失败返回 null
   */
  async migrateFromLegacyCache(
    legacyCachePath: string,
    displayName: string,
    extension: string,
    expectedSize: number
  ): Promise<ArkWebAvatarModelAsset | null> {
    if (this.disposed) {
      this.lastError = 'PersistentModelStore disposed';
      return null;
    }
    if (extension !== 'vrm' && extension !== 'glb' && extension !== 'gltf') {
      this.lastError = `unsupported extension: ${extension}`;
      return null;
    }
    if (legacyCachePath.length === 0) {
      this.lastError = 'legacyCachePath is empty';
      return null;
    }

    // 验证旧文件存在
    let legacyExists: boolean = false;
    try {
      legacyExists = await fileIo.access(legacyCachePath);
    } catch (_e) {
      // access 抛异常视为不存在
    }
    if (!legacyExists) {
      this.lastError = `legacy cache file not found: ${legacyCachePath}`;
      return null;
    }

    // 验证大小
    let actualSize: number = 0;
    try {
      const stat: fileIo.Stat = await fileIo.stat(legacyCachePath);
      actualSize = stat.size;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastError = `legacy stat failed: ${msg}`;
      return null;
    }
    if (actualSize <= 0) {
      this.lastError = `legacy file is empty (size=${actualSize})`;
      return null;
    }
    if (expectedSize > 0 && actualSize !== expectedSize) {
      this.lastError = `legacy size mismatch: expected ${expectedSize}, actual ${actualSize}`;
      return null;
    }

    // 复用 importModel 流程 (sourceUri = legacyCachePath)
    // 注: fileIo.open 接受文件路径作为 URI
    console.info(`[ArkWebPersistentModelStore] migrateFromLegacyCache: ${legacyCachePath} size=${actualSize}`);
    return this.importModel(legacyCachePath, displayName, extension);
  }

  /**
   * 验证持久模型文件是否存在且大小匹配。
   *
   * @param relativePath 相对 avatar-assets/ 的路径 (如 "models/model_xxx.vrm")
   * @param expectedByteLength 预期大小
   * @returns 验证通过返回 true;失败返回 false (查看 lastError)
   */
  async validateModelFile(relativePath: string, expectedByteLength: number): Promise<boolean> {
    if (this.disposed) {
      this.lastError = 'PersistentModelStore disposed';
      return false;
    }
    // 安全校验 relativePath
    if (!this.isRelativePathSafe(relativePath)) {
      this.lastError = `unsafe relativePath: ${relativePath}`;
      return false;
    }
    const absolutePath: string = `${this.context.filesDir}/${AVATAR_ASSETS_DIR_NAME}/${relativePath}`;
    let exists: boolean = false;
    try {
      exists = await fileIo.access(absolutePath);
    } catch (_e) {
      // access 抛异常视为不存在
    }
    if (!exists) {
      this.lastError = `model file not found: ${relativePath}`;
      return false;
    }
    let stat: fileIo.Stat;
    try {
      stat = await fileIo.stat(absolutePath);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastError = `stat failed: ${msg}`;
      return false;
    }
    if (stat.size <= 0) {
      this.lastError = `model file is empty (size=${stat.size})`;
      return false;
    }
    if (expectedByteLength > 0 && stat.size !== expectedByteLength) {
      this.lastError = `size mismatch: expected ${expectedByteLength}, actual ${stat.size}`;
      return false;
    }
    return true;
  }

  /**
   * 获取模型文件的绝对路径 (供 Provider 注册使用)。
   *
   * 注意: 此路径只在 ArkTS 内部使用,不得传给 JavaScript / UI 文本 / 日志。
   *
   * @param relativePath 相对 avatar-assets/ 的路径
   * @returns 绝对路径;若 relativePath 不安全返回空字符串
   */
  resolveAbsolutePath(relativePath: string): string {
    if (!this.isRelativePathSafe(relativePath)) {
      return '';
    }
    return `${this.context.filesDir}/${AVATAR_ASSETS_DIR_NAME}/${relativePath}`;
  }

  /**
   * 销毁 Store。
   * - 标记 disposed
   * - 不删除模型文件 / library.json
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
  }

  /** 是否已销毁。 */
  isDisposed(): boolean {
    return this.disposed;
  }

  // ===== 内部方法 =====

  /**
   * 生成 modelId。
   * 格式: model_<timestamp>_<random>
   * - timestamp: 13 位毫秒
   * - random: 8 位十六进制 (来自 UUID)
   *
   * 只包含 a-z A-Z 0-9 _ -
   */
  private generateModelId(): string {
    const timestamp: number = Date.now();
    const uuid: string = util.generateRandomUUID(false);
    const randomPart: string = uuid.replace(/-/g, '').substring(0, MODEL_ID_RANDOM_LENGTH);
    return `model_${timestamp}_${randomPart}`;
  }

  /**
   * 根据扩展名生成 MIME 类型。
   */
  private getMimeType(extension: string): string {
    if (extension === 'gltf') {
      return 'model/gltf+json';
    }
    return 'model/gltf-binary';
  }

  /**
   * 校验 relativePath 是否安全。
   * - 必须以 "models/" 开头
   * - 不得包含 ".."
   * - 不得包含反斜杠
   * - 不得以 "/" 开头
   */
  private isRelativePathSafe(p: string): boolean {
    if (p.length === 0) {
      return false;
    }
    if (p.startsWith('/')) {
      return false;
    }
    if (!p.startsWith('models/')) {
      return false;
    }
    if (p.includes('..')) {
      return false;
    }
    if (p.includes('\\')) {
      return false;
    }
    return true;
  }

  /** 关闭文件描述符 (忽略错误)。 */
  private async closeFile(file: fileIo.File): Promise<void> {
    try {
      await fileIo.close(file);
    } catch (_e) {
      // 忽略
    }
  }

  /** 安全删除文件 (忽略错误)。 */
  private async safeUnlink(path: string): Promise<void> {
    try {
      await fileIo.unlink(path);
    } catch (_e) {
      // 忽略
    }
  }
}
