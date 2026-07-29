/**
 * ArkWebPersistentAnimationStore — 持久化动画存储 (Phase 3C-1)
 *
 * 职责:
 * - 导入 .vrma 到 filesDir/avatar-assets/animations/
 * - 验证文件 (非空 / 大小)
 * - 生成 actionId (action_<timestamp>_<random>)
 * - 生成 resourceId (可与 actionId 相同)
 * - 创建 relativePath (animations/<actionId>.vrma)
 * - 原子复制动画 (.vrma.part → rename)
 * - 构造 ArkWebAvatarAnimationAsset
 * - 删除失败的临时文件
 * - 提交到 AssetLibrary (appendAnimation)
 * - 清单写入失败时回滚: 删除新动画文件
 * - 解析持久资源绝对路径
 *
 * 持久目录:
 * - <context.filesDir>/avatar-assets/animations/
 * - 目标文件: <actionId>.vrma
 * - 临时文件: <actionId>.vrma.part
 *
 * 安全约束:
 * - actionId 只包含 a-z A-Z 0-9 _ -
 * - 不使用原始文件名
 * - 不包含路径分隔符
 * - 相对路径必须以 "animations/" 开头
 *
 * 原子复制流程:
 * 1. 打开源 URI (只读)
 * 2. stat 获取源文件大小
 * 3. 校验非空
 * 4. 创建 .part 临时文件
 * 5. 分块复制 (64 KiB 缓冲)
 * 6. 验证写入大小
 * 7. rename .part → 最终文件
 * 8. 构造 ArkWebAvatarAnimationAsset
 * 9. 提交到 AssetLibrary.appendAnimation
 * 10. 清单失败 → 删除新动画文件 (回滚)
 *
 * 失败处理:
 * - 关闭文件描述符
 * - 删除 .part 临时文件
 * - 不覆盖已有动画文件
 * - 清单写入失败时删除本次新复制的动画文件
 *
 * Reference:
 * - ArkWebPersistentModelStore (Phase 3B): 复用复制 / .part / rename 模式
 * - AGENTS.md Phase 3C-1 §三~§五 规范
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import {
  ArkWebAvatarAnimationAsset,
  PersistentAnimationErrorCode,
  AnimationManagementErrorCode
} from './ArkWebAvatarAssetTypes';
import {
  ArkWebAvatarAssetLibrary,
  ANIMATIONS_SUBDIR_NAME
} from './ArkWebAvatarAssetLibrary';
import { VRMA_MIME_TYPE } from './ArkWebAnimationImportController';

/**
 * 复制缓冲区大小: 64 KiB。
 */
const PERSISTENT_ANIM_COPY_BUFFER_SIZE: number = 64 * 1024;

/**
 * actionId 随机部分长度。
 */
const ACTION_ID_RANDOM_LENGTH: number = 8;

/**
 * 持久化动画存储。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例,传入 UIAbilityContext 和 AssetLibrary
 * 2. 用户选择文件后调用 importAnimation(sourceUri, displayName, extension)
 * 3. 成功返回 ArkWebAvatarAnimationAsset,失败返回 null (查看 lastError)
 * 4. 页面 aboutToDisappear 调用 dispose()
 */
export class ArkWebPersistentAnimationStore {
  /** 应用上下文 (用于 filesDir)。 */
  private readonly context: common.UIAbilityContext;
  /** 资产库 (单一所有者, 由页面注入)。 */
  private readonly assetLibrary: ArkWebAvatarAssetLibrary;
  /** 动画目录绝对路径。 */
  private readonly animationsDir: string;
  /** 最近一次错误消息。 */
  private lastError: string = '';
  /** 是否已销毁。 */
  private disposed: boolean = false;

  constructor(context: common.UIAbilityContext, assetLibrary: ArkWebAvatarAssetLibrary) {
    this.context = context;
    this.assetLibrary = assetLibrary;
    this.animationsDir = assetLibrary.getAnimationsDir();
  }

  /** 获取最近一次错误消息。 */
  getLastError(): string {
    return this.lastError;
  }

  /** 是否已销毁。 */
  isDisposed(): boolean {
    return this.disposed;
  }

  /**
   * 获取动画目录绝对路径 (filesDir/avatar-assets/animations)。
   */
  getAnimationsDir(): string {
    return this.animationsDir;
  }

  /**
   * 导入动画文件到持久目录。
   *
   * 流程:
   * 1. 校验状态
   * 2. 生成 actionId / resourceId
   * 3. 打开源 URI
   * 4. stat 获取大小,校验非空
   * 5. 创建 .part 文件
   * 6. 分块复制
   * 7. 验证写入大小
   * 8. 关闭 FD
   * 9. rename .part → 最终文件
   * 10. 构造资产记录
   * 11. 提交到 AssetLibrary.appendAnimation
   * 12. 清单失败 → 删除新动画文件 (回滚)
   *
   * @param sourceUri 源文件 URI (来自 Picker)
   * @param displayName 用户可读显示名
   * @param extension 扩展名 (固定为 'vrma')
   * @returns 资产记录; 失败返回 null
   */
  async importAnimation(
    sourceUri: string,
    displayName: string,
    extension: string
  ): Promise<ArkWebAvatarAnimationAsset | null> {
    if (this.disposed) {
      this.lastError = PersistentAnimationErrorCode.ANIMATION_STORE_DISPOSED;
      return null;
    }
    if (this.assetLibrary.isDisposed()) {
      this.lastError = PersistentAnimationErrorCode.ANIMATION_STORE_LIBRARY_INVALID;
      return null;
    }

    const actionId: string = this.generateActionId();
    const resourceId: string = actionId; // resourceId 与 actionId 一致
    const fileName: string = `${actionId}.${extension}`;
    const finalPath: string = `${this.animationsDir}/${fileName}`;
    const partPath: string = `${finalPath}.part`;

    let sourceFile: fileIo.File | null = null;
    let targetFile: fileIo.File | null = null;
    let sourceSize: number = 0;
    let writtenTotal: number = 0;
    let renameDone: boolean = false;

    try {
      // 1. 打开源文件 (只读)
      try {
        sourceFile = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentAnimationErrorCode.ANIMATION_SOURCE_OPEN_FAILED}: ${msg}`;
        return null;
      }

      // 2. stat 获取大小
      try {
        const stat: fileIo.Stat = await fileIo.stat(sourceFile.fd);
        sourceSize = stat.size;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentAnimationErrorCode.ANIMATION_SOURCE_OPEN_FAILED}: ${msg}`;
        return null;
      }

      // 3. 校验非空
      if (sourceSize <= 0) {
        this.lastError = PersistentAnimationErrorCode.ANIMATION_FILE_EMPTY;
        return null;
      }

      // 4. 创建 .part 文件
      try {
        targetFile = await fileIo.open(
          partPath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
        );
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentAnimationErrorCode.ANIMATION_TARGET_CREATE_FAILED}: ${msg}`;
        return null;
      }

      // 5. 分块复制
      const buffer: ArrayBuffer = new ArrayBuffer(PERSISTENT_ANIM_COPY_BUFFER_SIZE);
      writtenTotal = 0;
      try {
        while (writtenTotal < sourceSize) {
          const remaining: number = sourceSize - writtenTotal;
          const readLen: number = remaining < PERSISTENT_ANIM_COPY_BUFFER_SIZE
            ? remaining : PERSISTENT_ANIM_COPY_BUFFER_SIZE;
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
            this.lastError = `${PersistentAnimationErrorCode.ANIMATION_FILE_WRITE_FAILED}: ` +
              `写入不完整 (期望 ${bytesRead}, 实际 ${bytesWritten})`;
            return null;
          }
          writtenTotal += bytesWritten;
        }
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentAnimationErrorCode.ANIMATION_FILE_READ_FAILED}: ${msg}`;
        return null;
      }

      // 6. 验证写入大小
      if (writtenTotal !== sourceSize) {
        this.lastError = `${PersistentAnimationErrorCode.ANIMATION_FILE_COPY_INCOMPLETE}: ` +
          `源 ${sourceSize} 字节, 已写入 ${writtenTotal} 字节`;
        return null;
      }

      // 7. 关闭 FD (rename 前必须关闭)
      await this.closeFile(sourceFile);
      sourceFile = null;
      await this.closeFile(targetFile);
      targetFile = null;

      // 8. rename .part → 最终文件
      try {
        await fileIo.rename(partPath, finalPath);
        renameDone = true;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentAnimationErrorCode.ANIMATION_RENAME_FAILED}: ${msg}`;
        return null;
      }

      // 9. 构造资产记录
      const now: number = Date.now();
      const asset: ArkWebAvatarAnimationAsset = {
        actionId: actionId,
        resourceId: resourceId,
        displayName: displayName,
        relativePath: `${ANIMATIONS_SUBDIR_NAME}/${fileName}`,
        mimeType: VRMA_MIME_TYPE,
        byteLength: sourceSize,
        createdAt: now,
        updatedAt: now
      };

      // 10. 提交到 AssetLibrary
      const commitOk: boolean = await this.assetLibrary.appendAnimation(asset);
      if (!commitOk) {
        // 回滚: 删除新动画文件 (不删除 .part, .part 已 rename)
        await this.safeUnlink(finalPath);
        this.lastError = PersistentAnimationErrorCode.ANIMATION_LIBRARY_WRITE_FAILED;
        return null;
      }

      this.lastError = '';
      console.info(
        `[ArkWebPersistentAnimationStore] importAnimation ok: actionId=${actionId}, size=${sourceSize}`
      );
      return asset;
    } finally {
      if (sourceFile !== null) {
        await this.closeFile(sourceFile);
        sourceFile = null;
      }
      if (targetFile !== null) {
        await this.closeFile(targetFile);
        targetFile = null;
      }
      // 失败时清理 .part (rename 已完成则不清理)
      if (!renameDone) {
        await this.safeUnlink(partPath);
      }
    }
  }

  /**
   * 根据相对路径解析持久资源的绝对路径 (filesDir + relativePath)。
   *
   * 安全校验: relativePath 必须以 "animations/" 开头且不含 ..
   *
   * @returns 绝对路径; 不安全返回空字符串
   */
  resolveAbsolutePath(relativePath: string): string {
    if (relativePath.length === 0) {
      return '';
    }
    if (relativePath.startsWith('/')) {
      return '';
    }
    if (!relativePath.startsWith(`${ANIMATIONS_SUBDIR_NAME}/`)) {
      return '';
    }
    if (relativePath.includes('..') || relativePath.includes('\\')) {
      return '';
    }
    return `${this.assetLibrary.getAssetsRootDir()}/${relativePath}`;
  }

  /**
   * 删除持久化动画文件并从清单移除记录 (Phase 3C-2)。
   *
   * 原子删除流程 (规范 §删除):
   * 1. 查找资产记录, 获取 finalPath
   * 2. rename <actionId>.vrma → <actionId>.vrma.deleting
   * 3. 从清单删除记录 (removeAnimationRecord, 若是默认待机则清空)
   * 4. 清单写入失败 → rename .deleting 回原文件 (回滚)
   * 5. 删除 .deleting 文件
   *
   * @returns 成功返回 true; 失败返回 false (查看 lastError)
   */
  async deleteAnimation(actionId: string): Promise<boolean> {
    if (this.disposed) {
      this.lastError = PersistentAnimationErrorCode.ANIMATION_STORE_DISPOSED;
      return false;
    }
    if (this.assetLibrary.isDisposed()) {
      this.lastError = PersistentAnimationErrorCode.ANIMATION_STORE_LIBRARY_INVALID;
      return false;
    }

    // 1. 查找资产记录
    const asset: ArkWebAvatarAnimationAsset | null = await this.assetLibrary.findAnimation(actionId);
    if (asset === null) {
      this.lastError = AnimationManagementErrorCode.ANIMATION_NOT_FOUND;
      return false;
    }
    const finalPath: string = this.resolveAbsolutePath(asset.relativePath);
    if (finalPath.length === 0) {
      this.lastError = AnimationManagementErrorCode.ANIMATION_NOT_FOUND;
      return false;
    }
    const deletingPath: string = `${finalPath}.deleting`;

    // 2. rename .vrma → .vrma.deleting
    try {
      await fileIo.rename(finalPath, deletingPath);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastError = `${AnimationManagementErrorCode.ANIMATION_DELETE_RENAME_FAILED}: ${msg}`;
      return false;
    }

    // 3. 从清单删除记录 (若是默认待机, AssetLibrary 自动清空 defaultIdleActionId)
    const removeOk: boolean = await this.assetLibrary.removeAnimationRecord(actionId);
    if (!removeOk) {
      // 4. 回滚: rename .deleting 回原文件
      try {
        await fileIo.rename(deletingPath, finalPath);
      } catch (_e) {
        // 回滚失败: 文件停留在 .deleting 状态, 下次可手动清理
        // 不影响数据一致性 (清单未变更)
      }
      this.lastError = AnimationManagementErrorCode.ANIMATION_DELETE_LIBRARY_WRITE_FAILED;
      return false;
    }

    // 5. 删除 .deleting 文件
    try {
      await fileIo.unlink(deletingPath);
    } catch (e) {
      // 清单已更新, 文件残留 .deleting 不影响数据一致性, 仅记录警告
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[ArkWebPersistentAnimationStore] deleteAnimation cleanup failed: ${msg}`);
      this.lastError = AnimationManagementErrorCode.ANIMATION_DELETE_CLEANUP_FAILED;
      // 仍视为删除成功 (清单已更新, 文件残留)
    }

    this.lastError = '';
    console.info(`[ArkWebPersistentAnimationStore] deleteAnimation ok actionId=${actionId}`);
    return true;
  }

  /**
   * 销毁 Store。
   * - 标记 disposed
   * - 不删除 filesDir 下的动画文件
   * - 不清空 library.animations
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
  }

  // ===== 内部方法 =====

  /**
   * 生成 actionId: action_<timestamp>_<8 位 hex>。
   *
   * 使用 util.generateRandomUUID 提取前 8 位 hex,与 ArkWebAnimationImportController 一致。
   */
  private generateActionId(): string {
    const timestamp: number = Date.now();
    const uuid: string = util.generateRandomUUID(false);
    const randomPart: string = uuid.replace(/-/g, '').substring(0, ACTION_ID_RANDOM_LENGTH);
    return `action_${timestamp}_${randomPart}`;
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
