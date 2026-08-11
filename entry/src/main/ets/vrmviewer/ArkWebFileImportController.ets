import { Logger } from '../utils/Logger';
/**
 * ArkWebFileImportController — 模型文件导入控制器(Phase 1D-1)
 *
 * 职责:
 * - 调用 HarmonyOS 系统文件选择器(DocumentViewPicker)
 * - 校验模型文件扩展名(.vrm / .glb / .gltf)
 * - 原子复制到受控缓存目录(<cacheDir>/vrm-imports/)
 * - GLTF 外部依赖预检(.gltf 文件轻量 JSON 分析)
 * - 导入状态机与错误处理
 * - 竞态保护(operationGeneration)
 *
 * 本阶段不实现:
 * - 把文件传给 ArkWeb(Phase 1D-2)
 * - JavaScript loadModel Bridge(Phase 1D-2)
 * - Object URL / Base64 传输
 * - 动画文件选择
 *
 * Reference:
 * - HarmonyOS SDK API 23: @ohos.file.picker / @ohos.file.fs
 * - AGENTS.md Phase 1D-1 规范
 *
 * 缓存生命周期策略:
 * - 页面销毁:保留当前缓存文件(避免短暂切换丢失)
 * - 明确清除(clearCurrentFile):删除当前缓存文件
 * - 新文件成功:删除旧缓存文件
 * - 复制失败:保留旧缓存文件
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import {
  ModelImportState,
  ModelFileType,
  GltfDependencyState,
  ImportedModelFile,
  ModelImportErrorCode,
  PICKER_FILE_SUFFIX_FILTERS,
  COPY_BUFFER_SIZE,
  CACHE_SUBDIR
} from './ArkWebModelImportTypes';

/**
 * 模型文件导入控制器。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例,传入 UIAbilityContext
 * 2. 用户点击"导入模型"按钮时调用 pickModelFile()
 * 3. 成功后通过 getCurrentFile() 获取导入结果
 * 4. 页面 aboutToDisappear 调用 dispose()
 */
export class ArkWebFileImportController {
  /** 当前导入状态。 */
  private state: ModelImportState = ModelImportState.IDLE;
  /** 当前已导入的文件(成功后非 null)。 */
  private currentFile: ImportedModelFile | null = null;
  /** 最近一次错误消息。 */
  private lastError: string = '';
  /** 操作代次(竞态保护)。 */
  private operationGeneration: number = 0;
  /** 是否已销毁。 */
  private disposed: boolean = false;
  /** 是否有进行中的操作(防止并发 Picker)。 */
  private operationInProgress: boolean = false;
  /** 应用上下文(用于 cacheDir 和 Picker 构造)。 */
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 选择并导入模型文件。
   *
   * 流程:
   * 1. 检查状态(已销毁 / 操作进行中)
   * 2. 显示系统文件选择器
   * 3. 用户取消 → CANCELLED(非错误)
   * 4. 校验扩展名
   * 5. 原子复制到受控缓存
   * 6. GLTF 依赖预检(仅 .gltf)
   * 7. 原子替换 currentFile,删除旧缓存
   * 8. 状态推进到 READY
   *
   * @returns 导入成功返回 ImportedModelFile,用户取消返回 null,失败返回 null(查看 lastError)
   */
  async pickModelFile(): Promise<ImportedModelFile | null> {
    if (this.disposed) {
      this.lastError = ModelImportErrorCode.IMPORT_CONTROLLER_DISPOSED;
      return null;
    }
    // 防止并发操作:不允许同时启动两个 Picker
    if (this.operationInProgress) {
      // 已有操作进行中,返回当前文件(若有)
      return this.currentFile;
    }

    this.operationInProgress = true;
    const generation: number = ++this.operationGeneration;

    try {
      // ===== 1. 显示系统文件选择器 =====
      this.setState(ModelImportState.PICKING);
      const sourceUri: string = await this.openPicker();

      // 检查代次(可能在等待 Picker 期间被 dispose 或启动新操作)
      if (generation !== this.operationGeneration || this.disposed) {
        return null;
      }

      // 用户取消:空数组表示取消
      if (sourceUri.length === 0) {
        this.lastError = '';
        this.setState(ModelImportState.CANCELLED);
        return null;
      }

      // ===== 2. 校验扩展名 =====
      const extension: string = this.extractExtension(sourceUri);
      if (!this.isValidExtension(extension)) {
        this.fail(ModelImportErrorCode.UNSUPPORTED_MODEL_FORMAT,
          `不支持的模型格式: .${extension}(仅支持 .vrm / .glb / .gltf)`);
        return null;
      }

      // ===== 3. 原子复制到受控缓存 =====
      this.setState(ModelImportState.COPYING);
      const displayName: string = this.sanitizeDisplayName(sourceUri);
      const result: ImportedModelFile | null = await this.copyToCache(
        sourceUri, extension, displayName, generation
      );

      if (result === null) {
        // 复制失败,错误已在 fail() 中记录
        return null;
      }

      // 检查代次(可能在异步复制期间被 dispose)
      if (generation !== this.operationGeneration || this.disposed) {
        // 过期结果:清理临时缓存文件
        await this.safeUnlink(result.cachePath);
        this.lastError = ModelImportErrorCode.STALE_IMPORT_RESULT;
        return null;
      }

      // ===== 4. 原子替换 currentFile =====
      const oldFile: ImportedModelFile | null = this.currentFile;
      this.currentFile = result;

      // ===== 5. 删除旧缓存文件 =====
      if (oldFile !== null) {
        await this.safeUnlink(oldFile.cachePath);
      }

      this.lastError = '';
      this.setState(ModelImportState.READY);
      return result;
    } finally {
      this.operationInProgress = false;
    }
  }

  /** 获取当前状态。 */
  getState(): ModelImportState {
    return this.state;
  }

  /** 获取当前已导入的文件(未导入或已清除时为 null)。 */
  getCurrentFile(): ImportedModelFile | null {
    return this.currentFile;
  }

  /** 获取最近一次错误消息(空字符串表示无错误)。 */
  getLastError(): string {
    return this.lastError;
  }

  /**
   * 清除当前文件:删除受控缓存文件,清空 currentFile,恢复 IDLE。
   */
  async clearCurrentFile(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const oldFile: ImportedModelFile | null = this.currentFile;
    this.currentFile = null;
    if (oldFile !== null) {
      await this.safeUnlink(oldFile.cachePath);
    }
    this.lastError = '';
    this.setState(ModelImportState.IDLE);
  }

  /**
   * 恢复上次导入的文件(Phase 1D-2C-1)。
   *
   * 由 VrmViewerPage 在 aboutToAppear 中调用,从 ArkWebModelImportStateStore
   * 恢复的 ImportedModelFile 注入到当前控制器,使后续 Provider 注册与探测
   * 可直接复用现有缓存文件,无需用户重新选择。
   *
   * 要求:
   * - disposed 时拒绝
   * - operationInProgress 时拒绝
   * - 不复制文件(缓存文件已在 <cacheDir>/vrm-imports/)
   * - 不重新读取 sourceUri(恢复时 sourceUri 为空字符串)
   * - 验证扩展名与 cachePath
   * - 原子设置 currentFile
   * - state = READY
   * - lastError = ''
   *
   * 不得把 restore 当成一次系统 Picker 操作。
   *
   * @param file 从 StateStore 恢复的文件元数据(已通过安全验证)
   * @returns true 表示恢复成功;false 表示拒绝(disposed / operationInProgress / 验证失败)
   */
  restoreCurrentFile(file: ImportedModelFile): boolean {
    if (this.disposed) {
      Logger.warn('[ArkWebFileImportController] restoreCurrentFile rejected: disposed');
      return false;
    }
    if (this.operationInProgress) {
      Logger.warn('[ArkWebFileImportController] restoreCurrentFile rejected: operation in progress');
      return false;
    }

    // 验证 file 字段
    if (file === null || file === undefined) {
      Logger.warn('[ArkWebFileImportController] restoreCurrentFile rejected: file is null');
      return false;
    }
    if (file.extension !== 'vrm' && file.extension !== 'glb' && file.extension !== 'gltf') {
      Logger.warn(`[ArkWebFileImportController] restoreCurrentFile rejected: invalid extension=${file.extension}`);
      return false;
    }
    if (file.cachePath.length === 0) {
      Logger.warn('[ArkWebFileImportController] restoreCurrentFile rejected: cachePath empty');
      return false;
    }
    if (file.cachePath.includes('..')) {
      Logger.warn('[ArkWebFileImportController] restoreCurrentFile rejected: cachePath contains ..');
      return false;
    }
    // cachePath 必须位于 <cacheDir>/vrm-imports/ 下
    const expectedDir: string = `${this.context.cacheDir}/${CACHE_SUBDIR}`;
    if (!file.cachePath.startsWith(expectedDir + '/')) {
      Logger.warn('[ArkWebFileImportController] restoreCurrentFile rejected: cachePath not under import directory');
      return false;
    }
    if (file.size <= 0) {
      Logger.warn(`[ArkWebFileImportController] restoreCurrentFile rejected: size=${file.size}`);
      return false;
    }

    // 原子设置 currentFile(不删除旧文件,因为旧文件可能就是同一个恢复文件)
    this.currentFile = file;
    this.lastError = '';
    this.setState(ModelImportState.READY);
    Logger.debug(`[ArkWebFileImportController] restoreCurrentFile ok id=${file.id} size=${file.size} ext=${file.extension}`);
    return true;
  }

  /**
   * 销毁控制器。
   *
   * 标记 disposed,使进行中的异步操作失效。
   * 不删除已缓存的 currentFile(页面销毁时保留缓存)。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.operationGeneration++; // 使进行中的操作失效
    this.setState(ModelImportState.DISPOSED);
  }

  // ===== 内部方法 =====

  /**
   * 调用系统文件选择器。
   * @returns 选中的文件 URI(空字符串表示用户取消)
   */
  private async openPicker(): Promise<string> {
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = PICKER_FILE_SUFFIX_FILTERS;
      options.maxSelectNumber = 1;
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return ''; // 用户取消
      }
      return uris[0];
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.fail(ModelImportErrorCode.PICKER_FAILED, `文件选择器调用失败: ${msg}`);
      return '';
    }
  }

  /**
   * 从 URI 中提取小写扩展名(最后一个点之后的部分)。
   * @returns 小写扩展名(无点),无扩展名时返回空字符串
   */
  private extractExtension(uri: string): string {
    // 去除 query 和 fragment
    let path: string = uri;
    const qIdx: number = path.indexOf('?');
    if (qIdx >= 0) {
      path = path.substring(0, qIdx);
    }
    const fIdx: number = path.indexOf('#');
    if (fIdx >= 0) {
      path = path.substring(0, fIdx);
    }
    // 取最后一个路径段
    const lastSlash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const fileName: string = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    // 取最后一个点
    const lastDot: number = fileName.lastIndexOf('.');
    if (lastDot <= 0 || lastDot === fileName.length - 1) {
      return ''; // 无扩展名或以点开头/结尾
    }
    return fileName.substring(lastDot + 1).toLowerCase();
  }

  /**
   * 校验扩展名是否在白名单中。
   */
  private isValidExtension(ext: string): boolean {
    return ext === 'vrm' || ext === 'glb' || ext === 'gltf';
  }

  /**
   * 从 URI 中提取安全的显示名。
   *
   * 防护:
   * - 只取最后一个路径段
   * - 移除路径分隔符
   * - 移除控制字符
   * - 限制长度(100 字符)
   */
  private sanitizeDisplayName(uri: string): string {
    let path: string = uri;
    const qIdx: number = path.indexOf('?');
    if (qIdx >= 0) {
      path = path.substring(0, qIdx);
    }
    const lastSlash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    let name: string = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    // URL 解码
    try {
      name = decodeURIComponent(name);
    } catch (_e) {
      // 解码失败,使用原始名
    }
    // 移除路径分隔符(防止注入)
    name = name.replace(/[/\\]/g, '');
    // 移除控制字符
    name = name.replace(/[\x00-\x1f\x7f]/g, '');
    // 限制长度
    if (name.length > 100) {
      name = name.substring(0, 100);
    }
    return name.length > 0 ? name : 'unknown';
  }

  /**
   * 生成缓存文件名(不信任用户文件名)。
   * 格式:<timestamp>-<generation>.<extension>
   */
  private generateCacheFileName(generation: number, extension: string): string {
    const timestamp: number = Date.now();
    return `${timestamp}-${generation}.${extension}`;
  }

  /**
   * 根据扩展名生成 MIME 类型。
   */
  private getMimeType(extension: string): string {
    if (extension === 'gltf') {
      return 'model/gltf+json';
    }
    // .vrm 和 .glb 都是 glTF 二进制
    return 'model/gltf-binary';
  }

  /**
   * 根据扩展名获取文件类型枚举。
   */
  private getFileType(extension: string): ModelFileType {
    if (extension === 'vrm') {
      return ModelFileType.VRM;
    } else if (extension === 'glb') {
      return ModelFileType.GLB;
    }
    return ModelFileType.GLTF;
  }

  /**
   * 原子复制文件到受控缓存目录。
   *
   * 顺序:
   * 1. 打开源 URI(只读)
   * 2. stat 获取源文件大小
   * 3. 校验非空
   * 4. 创建缓存目录
   * 5. 创建 .part 临时文件(读写)
   * 6. 分块复制(64 KiB 缓冲)
   * 7. 验证写入大小
   * 8. rename .part → 最终文件
   * 9. GLTF 依赖预检(仅 .gltf)
   * 10. 构造 ImportedModelFile
   *
   * 所有文件描述符在 finally 中关闭。
   * 失败时删除 .part 临时文件。
   */
  private async copyToCache(
    sourceUri: string,
    extension: string,
    displayName: string,
    generation: number
  ): Promise<ImportedModelFile | null> {
    const cacheDir: string = `${this.context.cacheDir}/${CACHE_SUBDIR}`;
    const cacheFileName: string = this.generateCacheFileName(generation, extension);
    const finalPath: string = `${cacheDir}/${cacheFileName}`;
    const partPath: string = `${finalPath}.part`;

    let sourceFile: fileIo.File | null = null;
    let targetFile: fileIo.File | null = null;
    let sourceSize: number = 0;
    let writtenTotal: number = 0;

    try {
      // 1. 打开源文件(只读)
      try {
        sourceFile = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(ModelImportErrorCode.SOURCE_OPEN_FAILED, `打开源文件失败: ${msg}`);
        return null;
      }

      // 2. stat 获取大小
      try {
        const stat: fileIo.Stat = await fileIo.stat(sourceFile.fd);
        sourceSize = stat.size;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(ModelImportErrorCode.SOURCE_OPEN_FAILED, `获取文件信息失败: ${msg}`);
        return null;
      }

      // 3. 校验非空
      if (sourceSize <= 0) {
        this.fail(ModelImportErrorCode.FILE_EMPTY, '文件为空(size === 0)');
        return null;
      }

      // 4. 创建缓存目录(递归)
      try {
        await fileIo.mkdir(cacheDir, true);
      } catch (e) {
        // 目录可能已存在,忽略错误
        Logger.debug('[ArkWebFileImportController] mkdir (may already exist): ' +
          (e instanceof Error ? e.message : String(e)));
      }

      // 5. 创建 .part 临时文件(读写 + 创建)
      try {
        targetFile = await fileIo.open(partPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(ModelImportErrorCode.TARGET_CREATE_FAILED, `创建缓存文件失败: ${msg}`);
        return null;
      }

      // 6. 分块复制
      const buffer: ArrayBuffer = new ArrayBuffer(COPY_BUFFER_SIZE);
      writtenTotal = 0;
      try {
        while (writtenTotal < sourceSize) {
          const remaining: number = sourceSize - writtenTotal;
          const readLen: number = remaining < COPY_BUFFER_SIZE ? remaining : COPY_BUFFER_SIZE;
          const bytesRead: number = await fileIo.read(sourceFile.fd, buffer, {
            offset: writtenTotal,
            length: readLen
          });
          if (bytesRead <= 0) {
            break; // EOF
          }
          const bytesWritten: number = await fileIo.write(targetFile.fd, buffer, {
            offset: writtenTotal,
            length: bytesRead
          });
          if (bytesWritten !== bytesRead) {
            this.fail(ModelImportErrorCode.FILE_WRITE_FAILED,
              `写入不完整: 期望 ${bytesRead}, 实际 ${bytesWritten}`);
            return null;
          }
          writtenTotal += bytesWritten;
        }
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(ModelImportErrorCode.FILE_READ_FAILED, `复制过程失败: ${msg}`);
        return null;
      }

      // 7. 验证写入大小
      if (writtenTotal !== sourceSize) {
        this.fail(ModelImportErrorCode.FILE_COPY_INCOMPLETE,
          `复制不完整: 源 ${sourceSize} 字节, 已写入 ${writtenTotal} 字节`);
        return null;
      }

      // 8. 关闭文件描述符(rename 前关闭避免锁)
      await this.closeFile(sourceFile);
      sourceFile = null;
      await this.closeFile(targetFile);
      targetFile = null;

      // 9. rename .part → 最终文件
      try {
        await fileIo.rename(partPath, finalPath);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.fail(ModelImportErrorCode.TARGET_CREATE_FAILED, `重命名缓存文件失败: ${msg}`);
        return null;
      }

      // 10. GLTF 依赖预检(仅 .gltf)
      let gltfState: GltfDependencyState = GltfDependencyState.NOT_APPLICABLE;
      let gltfUris: string[] = [];
      if (extension === 'gltf') {
        const precheck: GltfPrecheckResult = await this.precheckGltf(finalPath);
        gltfState = precheck.state;
        gltfUris = precheck.uris;
        if (gltfState === GltfDependencyState.INVALID_JSON) {
          this.fail(ModelImportErrorCode.GLTF_JSON_INVALID, 'glTF 文件 JSON 解析失败');
          // 删除已 rename 的文件
          await this.safeUnlink(finalPath);
          return null;
        }
      }

      // 11. 构造 ImportedModelFile
      const result: ImportedModelFile = {
        id: `${generation}`,
        displayName: displayName,
        extension: extension,
        fileType: this.getFileType(extension),
        mimeType: this.getMimeType(extension),
        sourceUri: sourceUri,
        cachePath: finalPath,
        size: sourceSize,
        createdAt: Date.now(),
        gltfDependencyState: gltfState,
        gltfExternalUris: gltfUris
      };

      return result;
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
      if (writtenTotal !== sourceSize) {
        await this.safeUnlink(partPath);
      }
    }
  }

  /**
   * GLTF 外部依赖预检(轻量 JSON 分析)。
   *
   * 检查 buffers[].uri 和 images[].uri:
   * - data: URI → 内嵌,不计为外部文件
   * - http:// / https:// → REMOTE_RESOURCES_FOUND
   * - 其他(相对路径) → EXTERNAL_FILES_REQUIRED
   *
   * 使用 regex 提取 URI,避免 ArkTS JSON.parse 类型问题。
   */
  private async precheckGltf(cachePath: string): Promise<GltfPrecheckResult> {
    const emptyResult: GltfPrecheckResult = {
      state: GltfDependencyState.SELF_CONTAINED,
      uris: []
    };

    let file: fileIo.File | null = null;
    try {
      // 打开缓存文件(只读)
      file = await fileIo.open(cachePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      const size: number = stat.size;

      // 读取全部内容为文本(GLTF JSON 通常较小)
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const bytesRead: number = await fileIo.read(file.fd, buffer, { length: size });
      if (bytesRead !== size) {
        return { state: GltfDependencyState.INVALID_JSON, uris: [] };
      }

      // 解码为 UTF-8 字符串
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeToString(new Uint8Array(buffer));

      // 基本 JSON 校验(首尾大括号)
      const trimmed: string = text.trim();
      if (trimmed.length === 0 || trimmed.charAt(0) !== '{' ||
          trimmed.charAt(trimmed.length - 1) !== '}') {
        return { state: GltfDependencyState.INVALID_JSON, uris: [] };
      }

      // 尝试 JSON.parse 验证有效性
      try {
        JSON.parse(text);
      } catch (_e) {
        return { state: GltfDependencyState.INVALID_JSON, uris: [] };
      }

      // 用 regex 提取所有 "uri": "..." 值
      const uris: string[] = [];
      const uriRegex: RegExp = /"uri"\s*:\s*"([^"]+)"/g;
      let match: RegExpExecArray | null = uriRegex.exec(text);
      while (match !== null) {
        if (match.length >= 2) {
          uris.push(match[1]);
        }
        match = uriRegex.exec(text);
      }

      // 分类
      let hasRemote: boolean = false;
      let hasRelative: boolean = false;
      for (let i = 0; i < uris.length; i++) {
        const u: string = uris[i];
        if (u.startsWith('data:')) {
          // 内嵌,跳过
          continue;
        } else if (u.startsWith('http://') || u.startsWith('https://')) {
          hasRemote = true;
        } else {
          hasRelative = true;
        }
      }

      let state: GltfDependencyState;
      if (hasRemote) {
        state = GltfDependencyState.REMOTE_RESOURCES_FOUND;
      } else if (hasRelative) {
        state = GltfDependencyState.EXTERNAL_FILES_REQUIRED;
      } else {
        state = GltfDependencyState.SELF_CONTAINED;
      }

      return { state: state, uris: uris };
    } catch (e) {
      Logger.warn('[ArkWebFileImportController] precheckGltf failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return { state: GltfDependencyState.INVALID_JSON, uris: [] };
    } finally {
      if (file !== null) {
        await this.closeFile(file);
      }
    }
  }

  /** 关闭文件描述符(忽略错误)。 */
  private async closeFile(file: fileIo.File): Promise<void> {
    try {
      await fileIo.close(file);
    } catch (_e) {
      // 忽略关闭错误
    }
  }

  /** 安全删除文件(忽略错误)。 */
  private async safeUnlink(path: string): Promise<void> {
    try {
      await fileIo.unlink(path);
    } catch (_e) {
      // 忽略删除错误(文件可能不存在)
    }
  }

  /** 设置状态。 */
  private setState(state: ModelImportState): void {
    this.state = state;
    Logger.debug(`[ArkWebFileImportController] state=${state}`);
  }

  /** 记录失败。 */
  private fail(code: string, message: string): void {
    this.lastError = `${code}: ${message}`;
    Logger.warn(`[ArkWebFileImportController] FAIL: ${this.lastError}`);
    this.setState(ModelImportState.FAILED);
  }
}

/**
 * GLTF 预检结果(内部使用)。
 */
interface GltfPrecheckResult {
  state: GltfDependencyState;
  uris: string[];
}
