/**
 * Model3DAssetStore 3D 模型资源文件管理
 *
 * 临时开发测试: T-3D.2 模型导入与资源保存
 * T-3D.5A: VRM 支持(.vrm 保存为 .glb 渲染副本)
 *
 * 职责:
 * - 将用户选择的 GLB/GLTF/VRM 文件复制到应用私有目录 models3d/
 * - 生成安全文件名,VRM 文件使用 .glb 渲染副本(ArkGraphics 3D 可能不支持 .vrm 后缀)
 * - 删除模型文件
 * - 不存储模型路径到自身(由 Character3DService 通过 Preferences 管理)
 *
 * 约束:
 * - 不依赖 ArkUI
 * - 不依赖网络/数据库
 * - 使用 @kit.CoreFileKit 进行文件操作
 * - 单文件大小上限 100MB(GLB 通常比头像大)
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'Model3DAssetStore';
const MODEL_DIR: string = 'models3d';
const MODEL_PREFIX: string = 'model3d_';
/** 支持的 3D 模型扩展名(小写,含点) */
const SUPPORTED_EXTENSIONS: string[] = ['.glb', '.gltf', '.vrm'];
/** 渲染副本扩展名映射(VRM 本质是 GLB,但 ArkGraphics 3D 可能不接受 .vrm 后缀) */
const RENDER_EXTENSION_MAP: Map<string, string> = new Map<string, string>([
  ['.vrm', '.glb']
]);
/** 默认扩展名(无法识别时使用) */
const DEFAULT_EXTENSION: string = '.glb';
/** 文件大小上限 100MB */
const MAX_FILE_SIZE: number = 100 * 1024 * 1024;

export class Model3DAssetStore {
  private baseDir: string = '';
  private initialized: boolean = false;

  /**
   * 初始化,创建模型目录。
   */
  initialize(context: common.Context): void {
    const filesDir: string = context.filesDir;
    this.baseDir = filesDir + '/' + MODEL_DIR;
    try {
      if (!fileIo.accessSync(this.baseDir)) {
        fileIo.mkdirSync(this.baseDir, true);
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'initialize mkdir failed: ' + String(e));
    }
    this.initialized = true;
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('Model3DAssetStore not initialized');
    }
  }

  /**
   * 从源 URI 提取小写扩展名(含点)。无法识别时返回 DEFAULT_EXTENSION。
   *
   * T-3D.5A: VRM 文件返回 .glb(渲染副本扩展名),因为 ArkGraphics 3D 可能不接受 .vrm 后缀。
   * VRM 本质是 GLB,内容相同,只是后缀不同。保存时使用 .glb 后缀,不修改二进制内容。
   *
   * 处理场景:
   * - 标准 URI:file:///path/to/model.glb -> ".glb"
   * - 带 query 参数:/path/model.gltf?token=xxx -> ".gltf"
   * - VRM 文件:/path/model.vrm -> ".glb"(渲染副本)
   * - 无扩展名或不在支持列表:/path/model -> ".glb"
   * - 大写扩展名:MODEL.GLB -> ".glb"
   */
  private extractExtension(sourceUri: string): string {
    let path: string = sourceUri;
    const queryIdx: number = path.indexOf('?');
    if (queryIdx >= 0) {
      path = path.substring(0, queryIdx);
    }
    const fragIdx: number = path.indexOf('#');
    if (fragIdx >= 0) {
      path = path.substring(0, fragIdx);
    }
    const lastSlash: number = path.lastIndexOf('/');
    const filename: string = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    const lastDot: number = filename.lastIndexOf('.');
    if (lastDot < 0 || lastDot === filename.length - 1) {
      return DEFAULT_EXTENSION;
    }
    const ext: string = filename.substring(lastDot).toLowerCase();
    if (SUPPORTED_EXTENSIONS.indexOf(ext) < 0) {
      return DEFAULT_EXTENSION;
    }
    // T-3D.5A: VRM 文件使用 .glb 渲染副本扩展名
    const renderExt: string | undefined = RENDER_EXTENSION_MAP.get(ext);
    if (renderExt !== undefined) {
      return renderExt;
    }
    return ext;
  }

  /**
   * 从源 URI 提取文件名(不含扩展名),用于显示。
   * 失败时返回 '未知模型'。
   */
  extractDisplayName(sourceUri: string): string {
    let path: string = sourceUri;
    const queryIdx: number = path.indexOf('?');
    if (queryIdx >= 0) {
      path = path.substring(0, queryIdx);
    }
    const fragIdx: number = path.indexOf('#');
    if (fragIdx >= 0) {
      path = path.substring(0, fragIdx);
    }
    const lastSlash: number = path.lastIndexOf('/');
    const filename: string = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    const lastDot: number = filename.lastIndexOf('.');
    if (lastDot <= 0) {
      return filename.length > 0 ? filename : '未知模型';
    }
    return filename.substring(0, lastDot);
  }

  /**
   * 复制 3D 模型文件到应用私有目录。
   *
   * 文件名格式:model3d_<timestamp>.<ext>
   * - ext 保留源文件扩展名(glb/gltf),不在支持列表时默认 .glb
   * - 每次保存生成新文件名,避免覆盖
   * - 旧文件由调用方通过 deleteModelByUri 显式删除
   *
   * @param sourceUri 源文件 URI(DocumentViewPicker 返回)
   * @returns 新的模型文件 URI(file://<绝对路径>)
   */
  async saveModel(sourceUri: string): Promise<string> {
    this.requireInit();
    const timestamp: number = Date.now();
    const ext: string = this.extractExtension(sourceUri);
    const destPath: string = this.baseDir + '/' + MODEL_PREFIX + timestamp + ext;
    try {
      const srcFile: fileIo.File = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(srcFile.fd);
      if (stat.size > MAX_FILE_SIZE) {
        fileIo.closeSync(srcFile);
        throw new Error('模型文件过大,不能超过 100MB');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(srcFile.fd, buffer);
      fileIo.closeSync(srcFile);

      this.writeBufferToPath(buffer, destPath);
      Logger.info(LOG_TAG, 'saveModel ok: ' + ext + ', size=' + stat.size);
      return 'file://' + destPath;
    } catch (e) {
      Logger.error(LOG_TAG, 'saveModel failed: ' + String(e));
      throw new Error('保存模型失败: ' + String(e));
    }
  }

  /**
   * 从 ArrayBuffer 保存模型(用于 rawfile 测试模型导入)。
   *
   * @param buffer 模型文件二进制内容
   * @param ext 文件扩展名(含点,如 '.glb')
   * @param displayName 用于日志的显示名(不含扩展名)
   * @returns 新的模型文件 URI(file://<绝对路径>)
   */
  async saveModelFromBuffer(
    buffer: ArrayBuffer, ext: string, displayName: string
  ): Promise<string> {
    this.requireInit();
    if (buffer.byteLength > MAX_FILE_SIZE) {
      throw new Error('模型文件过大,不能超过 100MB');
    }
    const normalizedExt: string = this.normalizeExtension(ext);
    const timestamp: number = Date.now();
    const destPath: string = this.baseDir + '/' + MODEL_PREFIX + timestamp + normalizedExt;
    try {
      this.writeBufferToPath(buffer, destPath);
      Logger.info(LOG_TAG, 'saveModelFromBuffer ok: name=' + displayName
        + ', size=' + buffer.byteLength);
      return 'file://' + destPath;
    } catch (e) {
      Logger.error(LOG_TAG, 'saveModelFromBuffer failed: ' + String(e));
      throw new Error('保存模型失败: ' + String(e));
    }
  }

  /**
   * 将 buffer 写入目标路径(内部复用)。
   */
  private writeBufferToPath(buffer: ArrayBuffer, destPath: string): void {
    const destFile: fileIo.File = fileIo.openSync(destPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    fileIo.writeSync(destFile.fd, buffer);
    fileIo.closeSync(destFile);
  }

  /**
   * 规范化扩展名:确保以点开头且在支持列表中。
   * T-3D.5A: VRM 扩展名转换为 .glb(渲染副本)。
   */
  private normalizeExtension(ext: string): string {
    if (ext.length === 0) {
      return DEFAULT_EXTENSION;
    }
    let normalized: string = ext;
    if (!normalized.startsWith('.')) {
      normalized = '.' + normalized;
    }
    normalized = normalized.toLowerCase();
    if (SUPPORTED_EXTENSIONS.indexOf(normalized) < 0) {
      return DEFAULT_EXTENSION;
    }
    // T-3D.5A: VRM 文件使用 .glb 渲染副本扩展名
    const renderExt: string | undefined = RENDER_EXTENSION_MAP.get(normalized);
    if (renderExt !== undefined) {
      return renderExt;
    }
    return normalized;
  }

  /**
   * 按精确 URI 删除模型文件。
   * 文件不存在时静默成功。
   *
   * @param modelUri 完整的 file:// URI
   */
  async deleteModelByUri(modelUri: string): Promise<void> {
    this.requireInit();
    if (modelUri.length === 0) {
      return;
    }
    let path: string = modelUri;
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
    }
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'deleteModelByUri ignored: ' + String(e));
    }
  }

  /**
   * 检查指定 URI 的文件是否仍然存在。
   * 用于 Preferences 中保留了 URI 但文件已被外部删除的情况。
   */
  exists(modelUri: string): boolean {
    if (modelUri.length === 0) {
      return false;
    }
    let path: string = modelUri;
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
    }
    try {
      return fileIo.accessSync(path);
    } catch (_e) {
      return false;
    }
  }
}
