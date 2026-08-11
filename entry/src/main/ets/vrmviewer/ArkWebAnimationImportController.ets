import { Logger } from '../utils/Logger';
/**
 * ArkWebAnimationImportController — VRMA 动画文件导入控制器 (Phase 3A)
 *
 * 职责:
 * - 调用 HarmonyOS 系统文件选择器 (DocumentViewPicker) 选择 .vrma 文件
 * - 校验扩展名 (大小写不敏感, 仅接受 .vrma, 拒绝 .vrma.zip / 无扩展名 / 目录)
 * - 原子复制到受控缓存目录 (<cacheDir>/vrm-animations/)
 * - 缓存文件名使用 <resourceId>.vrma (不信任用户文件名)
 * - 写入流程: 创建目录 → 写入 .part → 验证字节数 > 0 → rename .part → finalPath
 * - 失败时: 关闭文件、删除 .part、不覆盖之前成功动画资源
 * - 竞态保护 (operationGeneration)
 *
 * 不做的事:
 * - 不把 .vrma 交给 ViewerModelLoader / loadPreparedModelResource / 模型 Provider
 * - 不解析 VRMA 内容 (由 JavaScript GLTFLoader + VRMAnimationLoaderPlugin 完成)
 * - 不向 UI / JavaScript 暴露 cachePath / 原始 URI / 绝对路径
 *
 * Reference:
 * - ArkWebFileImportController (Phase 1D-1): 复用选择器配置 / URI 读取 / 流式复制模式
 * - AGENTS.md Phase 3A §九~§十 规范
 *
 * 缓存生命周期策略 (与模型导入一致):
 * - 页面销毁: 保留当前缓存文件 (避免短暂切换丢失)
 * - 明确清除 (clearCurrentFile): 删除当前缓存文件
 * - 新文件成功: 删除旧缓存文件
 * - 复制失败: 保留旧缓存文件
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

/**
 * 动画导入状态机。
 *
 * 与 ModelImportState 解耦: 动画导入独立于模型导入。
 */
export enum AnimationImportState {
  IDLE = 'IDLE',
  PICKING = 'PICKING',
  COPYING = 'COPYING',
  READY = 'READY',
  CANCELLED = 'CANCELLED',
  FAILED = 'FAILED',
  DISPOSED = 'DISPOSED'
}

/**
 * 动画导入错误码 (与 ArkWebAnimationErrorCode 对齐前缀 ANIMATION_)。
 */
export class AnimationImportErrorCode {
  public static readonly IMPORT_CONTROLLER_DISPOSED: string = 'ANIMATION_IMPORT_CONTROLLER_DISPOSED';
  public static readonly PICKER_FAILED: string = 'ANIMATION_PICKER_FAILED';
  public static readonly UNSUPPORTED_ANIMATION_FORMAT: string = 'ANIMATION_UNSUPPORTED_FORMAT';
  public static readonly SOURCE_OPEN_FAILED: string = 'ANIMATION_SOURCE_OPEN_FAILED';
  public static readonly FILE_EMPTY: string = 'ANIMATION_FILE_EMPTY';
  public static readonly TARGET_CREATE_FAILED: string = 'ANIMATION_TARGET_CREATE_FAILED';
  public static readonly FILE_READ_FAILED: string = 'ANIMATION_FILE_READ_FAILED';
  public static readonly FILE_WRITE_FAILED: string = 'ANIMATION_FILE_WRITE_FAILED';
  public static readonly FILE_COPY_INCOMPLETE: string = 'ANIMATION_FILE_COPY_INCOMPLETE';
  public static readonly STALE_IMPORT_RESULT: string = 'ANIMATION_STALE_IMPORT_RESULT';
}

/**
 * 受控缓存子目录名 (相对于 context.cacheDir)。
 *
 * 独立于模型缓存 (vrm-imports),避免污染模型目录。
 */
export const ANIMATION_CACHE_SUBDIR: string = 'vrm-animations';

/**
 * Picker 文件后缀过滤器 (仅 .vrma)。
 */
export const ANIMATION_PICKER_FILE_SUFFIX_FILTERS: string[] = ['vrma'];

/**
 * 复制缓冲区大小: 64 KiB (与模型导入一致)。
 */
export const ANIMATION_COPY_BUFFER_SIZE: number = 64 * 1024;

/**
 * VRMA MIME 类型 (与 .glb/.vrm 一致, 均为 glTF 二进制)。
 */
export const VRMA_MIME_TYPE: string = 'model/gltf-binary';

/**
 * 已导入的 VRMA 动画文件元数据 (ArkTS 内部使用, 包含 cachePath)。
 *
 * 传给 JavaScript 的信息只允许: publicUrl / displayName / size / mimeType / resourceId
 * (由 ArkWebAnimationResourceProvider 构造 publicResource 时剥离 cachePath)。
 */
export interface ImportedAnimationFile {
  /** 资源 ID (用作缓存文件名, 不透明)。 */
  resourceId: string;
  /** 用户可读显示名 (从 URI 提取, 已消毒)。 */
  displayName: string;
  /** 扩展名 (固定为 'vrma')。 */
  extension: string;
  /** MIME 类型 (固定为 model/gltf-binary)。 */
  mimeType: string;
  /** 原始 URI (ArkTS 内部, 不传给 JS)。 */
  sourceUri: string;
  /** 缓存绝对路径 (ArkTS 内部, 不传给 JS)。 */
  cachePath: string;
  /** 文件字节数。 */
  size: number;
  /** 创建时间戳 (ms)。 */
  createdAt: number;
}

/**
 * VRMA 动画文件导入控制器。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例, 传入 UIAbilityContext
 * 2. 用户点击 "选择 VRMA" 按钮时调用 pickAnimationFile()
 * 3. 成功后通过 getCurrentFile() 获取导入结果
 * 4. 页面 aboutToDisappear 调用 dispose()
 */
export class ArkWebAnimationImportController {
  /** 当前导入状态。 */
  private state: AnimationImportState = AnimationImportState.IDLE;
  /** 当前已导入的文件 (成功后非 null)。 */
  private currentFile: ImportedAnimationFile | null = null;
  /** 最近一次错误消息。 */
  private lastError: string = '';
  /** 操作代次 (竞态保护)。 */
  private operationGeneration: number = 0;
  /** 是否已销毁。 */
  private disposed: boolean = false;
  /** 是否有进行中的操作 (防止并发 Picker)。 */
  private operationInProgress: boolean = false;
  /** 应用上下文 (用于 cacheDir 和 Picker 构造)。 */
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 选择并导入 VRMA 动画文件。
   *
   * 流程:
   * 1. 检查状态 (已销毁 / 操作进行中)
   * 2. 显示系统文件选择器 (仅 .vrma)
   * 3. 用户取消 → CANCELLED (非错误)
   * 4. 校验扩展名 (大小写不敏感, 拒绝 .vrma.zip / 无扩展名 / 目录)
   * 5. 原子复制到受控缓存 (<resourceId>.vrma)
   * 6. 原子替换 currentFile, 删除旧缓存
   * 7. 状态推进到 READY
   *
   * @returns 导入成功返回 ImportedAnimationFile, 用户取消返回 null, 失败返回 null (查看 lastError)
   */
  async pickAnimationFile(): Promise<ImportedAnimationFile | null> {
    if (this.disposed) {
      this.lastError = AnimationImportErrorCode.IMPORT_CONTROLLER_DISPOSED;
      return null;
    }
    if (this.operationInProgress) {
      return this.currentFile;
    }

    this.operationInProgress = true;
    const generation: number = ++this.operationGeneration;

    try {
      // ===== 1. 显示系统文件选择器 =====
      this.setState(AnimationImportState.PICKING);
      const sourceUri: string = await this.openPicker();

      if (generation !== this.operationGeneration || this.disposed) {
        return null;
      }

      // 用户取消
      if (sourceUri.length === 0) {
        this.lastError = '';
        this.setState(AnimationImportState.CANCELLED);
        return null;
      }

      // ===== 2. 校验扩展名 =====
      const extension: string = this.extractExtension(sourceUri);
      if (!this.isValidExtension(extension)) {
        this.fail(AnimationImportErrorCode.UNSUPPORTED_ANIMATION_FORMAT,
          `不支持的动画格式: .${extension}(仅支持 .vrma)`);
        return null;
      }

      // ===== 3. 原子复制到受控缓存 =====
      this.setState(AnimationImportState.COPYING);
      const displayName: string = this.sanitizeDisplayName(sourceUri);
      const result: ImportedAnimationFile | null = await this.copyToCache(
        sourceUri, displayName, generation
      );

      if (result === null) {
        return null;
      }

      if (generation !== this.operationGeneration || this.disposed) {
        await this.safeUnlink(result.cachePath);
        this.lastError = AnimationImportErrorCode.STALE_IMPORT_RESULT;
        return null;
      }

      // ===== 4. 原子替换 currentFile =====
      const oldFile: ImportedAnimationFile | null = this.currentFile;
      this.currentFile = result;

      // ===== 5. 删除旧缓存文件 =====
      if (oldFile !== null) {
        await this.safeUnlink(oldFile.cachePath);
      }

      this.lastError = '';
      this.setState(AnimationImportState.READY);
      return result;
    } finally {
      this.operationInProgress = false;
    }
  }

  /** 获取当前状态。 */
  getState(): AnimationImportState {
    return this.state;
  }

  /** 获取当前已导入的文件 (未导入或已清除时为 null)。 */
  getCurrentFile(): ImportedAnimationFile | null {
    return this.currentFile;
  }

  /** 获取最近一次错误消息 (空字符串表示无错误)。 */
  getLastError(): string {
    return this.lastError;
  }

  /**
   * 清除当前文件: 删除受控缓存文件, 清空 currentFile, 恢复 IDLE。
   */
  async clearCurrentFile(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const oldFile: ImportedAnimationFile | null = this.currentFile;
    this.currentFile = null;
    if (oldFile !== null) {
      await this.safeUnlink(oldFile.cachePath);
    }
    this.lastError = '';
    this.setState(AnimationImportState.IDLE);
  }

  /**
   * 销毁控制器。
   *
   * 标记 disposed, 使进行中的异步操作失效。
   * 不删除已缓存的 currentFile (页面销毁时保留缓存)。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.operationGeneration++;
    this.setState(AnimationImportState.DISPOSED);
  }

  // ===== 内部方法 =====

  /**
   * 调用系统文件选择器 (仅 .vrma)。
   * @returns 选中的文件 URI (空字符串表示用户取消)
   */
  private async openPicker(): Promise<string> {
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = ANIMATION_PICKER_FILE_SUFFIX_FILTERS;
      options.maxSelectNumber = 1;
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return '';
      }
      return uris[0];
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.fail(AnimationImportErrorCode.PICKER_FAILED, `动画文件选择器调用失败: ${msg}`);
      return '';
    }
  }

  /**
   * 从 URI 中提取小写扩展名 (最后一个点之后的部分)。
   *
   * 拒绝:
   * - 无扩展名
   * - 以点开头/结尾
   * - .vrma.zip (取最后一段 .zip, 不匹配 .vrma)
   * - 目录 (URI 无文件名)
   *
   * @returns 小写扩展名 (无点), 无扩展名时返回空字符串
   */
  private extractExtension(uri: string): string {
    let path: string = uri;
    const qIdx: number = path.indexOf('?');
    if (qIdx >= 0) {
      path = path.substring(0, qIdx);
    }
    const fIdx: number = path.indexOf('#');
    if (fIdx >= 0) {
      path = path.substring(0, fIdx);
    }
    const lastSlash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const fileName: string = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    const lastDot: number = fileName.lastIndexOf('.');
    if (lastDot <= 0 || lastDot === fileName.length - 1) {
      return '';
    }
    return fileName.substring(lastDot + 1).toLowerCase();
  }

  /**
   * 校验扩展名是否为 .vrma (大小写不敏感)。
   */
  private isValidExtension(ext: string): boolean {
    return ext === 'vrma';
  }

  /**
   * 从 URI 中提取安全的显示名。
   *
   * 防护 (与模型导入一致):
   * - 只取最后一个路径段
   * - 移除路径分隔符
   * - 移除控制字符
   * - 限制长度 (100 字符)
   */
  private sanitizeDisplayName(uri: string): string {
    let path: string = uri;
    const qIdx: number = path.indexOf('?');
    if (qIdx >= 0) {
      path = path.substring(0, qIdx);
    }
    const lastSlash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    let name: string = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    try {
      name = decodeURIComponent(name);
    } catch (_e) {
      // 解码失败, 使用原始名
    }
    name = name.replace(/[/\\]/g, '');
    name = name.replace(/[\x00-\x1f\x7f]/g, '');
    if (name.length > 100) {
      name = name.substring(0, 100);
    }
    return name.length > 0 ? name : 'unknown.vrma';
  }

  /**
   * 生成不透明资源 ID (用作缓存文件名)。
   *
   * 格式: <8 位 hex>-<时间戳 base36>
   * 示例: a3f2c9d1-l4x2z9q
   *
   * 不信任用户文件名, 因此使用生成的 ID 作为缓存文件名。
   */
  private generateResourceId(): string {
    const uuid: string = util.generateRandomUUID(false);
    const hexPart: string = uuid.replace(/-/g, '').substring(0, 8);
    const timestampPart: string = Date.now().toString(36);
    return `${hexPart}-${timestampPart}`;
  }

  /**
   * 原子复制文件到受控缓存目录。
   *
   * 顺序 (AGENTS.md Phase 3A §十):
   * 1. 打开源 URI (只读)
   * 2. stat 获取源文件大小
   * 3. 校验非空 (size > 0)
   * 4. 创建缓存目录
   * 5. 创建 .part 临时文件 (读写)
   * 6. 分块复制 (64 KiB 缓冲)
   * 7. 验证写入大小
   * 8. rename .part → 最终文件 (<resourceId>.vrma)
   * 9. 构造 ImportedAnimationFile
   *
   * 所有文件描述符在 finally 中关闭。
   * 失败时删除 .part 临时文件。
   */
  private async copyToCache(
    sourceUri: string,
    displayName: string,
    generation: number
  ): Promise<ImportedAnimationFile | null> {
    const cacheDir: string = `${this.context.cacheDir}/${ANIMATION_CACHE_SUBDIR}`;
    const resourceId: string = this.generateResourceId();
    const cacheFileName: string = `${resourceId}.vrma`;
    const finalPath: string = `${cacheDir}/${cacheFileName}`;
    const partPath: string = `${finalPath}.part`;

    let sourceFile: fileIo.File | null = null;
    let targetFile: fileIo.File | null = null;
    let sourceSize: number = 0;
    let writtenTotal: number = 0;

    try {
      // 1. 打开源文件 (只读)
      try {
        sourceFile = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(AnimationImportErrorCode.SOURCE_OPEN_FAILED, `打开源文件失败: ${msg}`);
        return null;
      }

      // 2. stat 获取大小
      try {
        const stat: fileIo.Stat = await fileIo.stat(sourceFile.fd);
        sourceSize = stat.size;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(AnimationImportErrorCode.SOURCE_OPEN_FAILED, `获取文件信息失败: ${msg}`);
        return null;
      }

      // 3. 校验非空
      if (sourceSize <= 0) {
        this.fail(AnimationImportErrorCode.FILE_EMPTY, '动画文件为空 (size === 0)');
        return null;
      }

      // 4. 创建缓存目录 (递归)
      try {
        await fileIo.mkdir(cacheDir, true);
      } catch (e) {
        Logger.debug('[ArkWebAnimationImportController] mkdir (may already exist): ' +
          (e instanceof Error ? e.message : String(e)));
      }

      // 5. 创建 .part 临时文件 (读写 + 创建)
      try {
        targetFile = await fileIo.open(partPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(AnimationImportErrorCode.TARGET_CREATE_FAILED, `创建缓存文件失败: ${msg}`);
        return null;
      }

      // 6. 分块复制
      const buffer: ArrayBuffer = new ArrayBuffer(ANIMATION_COPY_BUFFER_SIZE);
      writtenTotal = 0;
      try {
        while (writtenTotal < sourceSize) {
          const remaining: number = sourceSize - writtenTotal;
          const readLen: number = remaining < ANIMATION_COPY_BUFFER_SIZE ? remaining : ANIMATION_COPY_BUFFER_SIZE;
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
            this.fail(AnimationImportErrorCode.FILE_WRITE_FAILED,
              `写入不完整: 期望 ${bytesRead}, 实际 ${bytesWritten}`);
            return null;
          }
          writtenTotal += bytesWritten;
        }
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(AnimationImportErrorCode.FILE_READ_FAILED, `复制过程失败: ${msg}`);
        return null;
      }

      // 7. 验证写入大小
      if (writtenTotal !== sourceSize) {
        this.fail(AnimationImportErrorCode.FILE_COPY_INCOMPLETE,
          `复制不完整: 源 ${sourceSize} 字节, 已写入 ${writtenTotal} 字节`);
        return null;
      }

      // 8. 关闭文件描述符 (rename 前关闭避免锁)
      await this.closeFile(sourceFile);
      sourceFile = null;
      await this.closeFile(targetFile);
      targetFile = null;

      // 9. rename .part → 最终文件
      try {
        await fileIo.rename(partPath, finalPath);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(AnimationImportErrorCode.TARGET_CREATE_FAILED, `重命名缓存文件失败: ${msg}`);
        return null;
      }

      // 10. 构造 ImportedAnimationFile
      const result: ImportedAnimationFile = {
        resourceId: resourceId,
        displayName: displayName,
        extension: 'vrma',
        mimeType: VRMA_MIME_TYPE,
        sourceUri: sourceUri,
        cachePath: finalPath,
        size: sourceSize,
        createdAt: Date.now()
      };

      return result;
    } finally {
      if (sourceFile !== null) {
        await this.closeFile(sourceFile);
        sourceFile = null;
      }
      if (targetFile !== null) {
        await this.closeFile(targetFile);
        targetFile = null;
      }
      // 失败时清理 .part 临时文件
      if (writtenTotal !== sourceSize) {
        await this.safeUnlink(partPath);
      }
    }
  }

  /** 关闭文件描述符 (忽略错误)。 */
  private async closeFile(file: fileIo.File): Promise<void> {
    try {
      await fileIo.close(file);
    } catch (_e) {
      // 忽略关闭错误
    }
  }

  /** 安全删除文件 (忽略错误)。 */
  private async safeUnlink(path: string): Promise<void> {
    try {
      await fileIo.unlink(path);
    } catch (_e) {
      // 忽略删除错误
    }
  }

  /** 设置状态。 */
  private setState(state: AnimationImportState): void {
    this.state = state;
    Logger.debug(`[ArkWebAnimationImportController] state=${state}`);
  }

  /** 记录失败。 */
  private fail(code: string, message: string): void {
    this.lastError = `${code}: ${message}`;
    Logger.warn(`[ArkWebAnimationImportController] FAIL: ${this.lastError}`);
    this.setState(AnimationImportState.FAILED);
  }
}
