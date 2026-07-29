/**
 * ArkWebPoseImportController — JSON 姿势文件导入控制器 (Phase 3D-1)
 *
 * 职责:
 * - 调用 HarmonyOS 系统文件选择器 (DocumentViewPicker) 选择 .json 文件
 * - 校验扩展名 (大小写不敏感, 仅接受 .json, 拒绝 .json.zip / 无扩展名 / 目录)
 * - 从 URI 提取安全的显示名 (用作 displayName)
 * - 调用 PersistentPoseStore.importPose 完成持久化与 JSON 验证
 * - 竞态保护 (operationGeneration)
 *
 * 不做的事:
 * - 不解析 JSON 内容 (由 PersistentPoseStore 验证)
 * - 不应用姿势到模型 (Phase 3D-2)
 * - 不向 UI 暴露 sourceUri / 绝对路径
 *
 * Reference:
 * - ArkWebAnimationImportController (Phase 3A): 复用选择器配置 / 扩展名校验 / 显示名消毒模式
 */

import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  ArkWebAvatarPoseAsset,
  PoseImportErrorCode
} from './ArkWebAvatarAssetTypes';
import { ArkWebPersistentPoseStore } from './ArkWebPersistentPoseStore';

/**
 * 姿势导入状态机。
 */
export enum PoseImportState {
  IDLE = 'IDLE',
  PICKING = 'PICKING',
  IMPORTING = 'IMPORTING',
  READY = 'READY',
  CANCELLED = 'CANCELLED',
  FAILED = 'FAILED',
  DISPOSED = 'DISPOSED'
}

/**
 * Picker 文件后缀过滤器 (仅 .json)。
 */
export const POSE_PICKER_FILE_SUFFIX_FILTERS: string[] = ['json'];

/**
 * 姿势文件导入控制器。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例, 传入 UIAbilityContext
 * 2. 用户点击 "导入姿势" 按钮时调用 pickAndImportPose(persistentPoseStore)
 * 3. 成功返回 ArkWebAvatarPoseAsset, 失败返回 null (查看 lastError)
 * 4. 页面 aboutToDisappear 调用 dispose()
 */
export class ArkWebPoseImportController {
  /** 当前导入状态。 */
  private state: PoseImportState = PoseImportState.IDLE;
  /** 最近一次错误码 (含消息)。 */
  private lastError: string = '';
  /** 操作代次 (竞态保护)。 */
  private operationGeneration: number = 0;
  /** 是否已销毁。 */
  private disposed: boolean = false;
  /** 是否有进行中的操作 (防止并发 Picker)。 */
  private operationInProgress: boolean = false;
  /** 应用上下文 (用于 Picker 构造)。 */
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 获取当前状态。 */
  getState(): PoseImportState {
    return this.state;
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
   * 选择并导入 JSON 姿势文件。
   *
   * 流程:
   * 1. 检查状态 (已销毁 / 操作进行中)
   * 2. 显示系统文件选择器 (仅 .json)
   * 3. 用户取消 → CANCELLED (非错误)
   * 4. 校验扩展名 (大小写不敏感, 拒绝 .json.zip / 无扩展名 / 目录)
   * 5. 提取安全显示名
   * 6. 调用 PersistentPoseStore.importPose (含 .part 原子写入 + JSON 结构验证)
   * 7. 状态推进到 READY
   *
   * @returns 导入成功返回 ArkWebAvatarPoseAsset, 用户取消返回 null, 失败返回 null (查看 lastError)
   */
  async pickAndImportPose(
    persistentPoseStore: ArkWebPersistentPoseStore
  ): Promise<ArkWebAvatarPoseAsset | null> {
    if (this.disposed) {
      this.lastError = PoseImportErrorCode.POSE_IMPORT_FILENAME_INVALID;
      this.setState(PoseImportState.FAILED);
      return null;
    }
    if (this.operationInProgress) {
      return null;
    }

    this.operationInProgress = true;
    const generation: number = ++this.operationGeneration;

    try {
      // ===== 1. 显示系统文件选择器 =====
      this.setState(PoseImportState.PICKING);
      const sourceUri: string = await this.openPicker();

      if (generation !== this.operationGeneration || this.disposed) {
        return null;
      }

      // 用户取消
      if (sourceUri.length === 0) {
        this.lastError = '';
        this.setState(PoseImportState.CANCELLED);
        return null;
      }

      // ===== 2. 校验扩展名 =====
      const extension: string = this.extractExtension(sourceUri);
      if (!this.isValidExtension(extension)) {
        this.lastError = `${PoseImportErrorCode.POSE_IMPORT_EXTENSION_INVALID}: .${extension}`;
        this.setState(PoseImportState.FAILED);
        return null;
      }

      // ===== 3. 提取安全显示名 =====
      const displayName: string = this.sanitizeDisplayName(sourceUri);
      if (displayName.length === 0) {
        this.lastError = PoseImportErrorCode.POSE_IMPORT_FILENAME_EMPTY;
        this.setState(PoseImportState.FAILED);
        return null;
      }

      // ===== 4. 调用 PersistentPoseStore 完成导入 =====
      this.setState(PoseImportState.IMPORTING);
      const asset: ArkWebAvatarPoseAsset | null = await persistentPoseStore.importPose(
        sourceUri, displayName
      );

      if (generation !== this.operationGeneration || this.disposed) {
        return null;
      }

      if (asset === null) {
        // PersistentPoseStore 已设置具体错误码, 直接透传
        this.lastError = persistentPoseStore.getLastError();
        this.setState(PoseImportState.FAILED);
        return null;
      }

      this.lastError = '';
      this.setState(PoseImportState.READY);
      return asset;
    } finally {
      this.operationInProgress = false;
    }
  }

  /**
   * 销毁控制器。
   * - 标记 disposed
   * - 不删除已导入的姿势文件 (由 PersistentPoseStore 管理)
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.state = PoseImportState.DISPOSED;
  }

  // ===== 内部方法 =====

  /**
   * 调用系统文件选择器 (仅 .json)。
   * @returns 选中的文件 URI (空字符串表示用户取消)
   */
  private async openPicker(): Promise<string> {
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = POSE_PICKER_FILE_SUFFIX_FILTERS;
      options.maxSelectNumber = 1;
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return '';
      }
      return uris[0];
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastError = `${PoseImportErrorCode.POSE_IMPORT_FILENAME_INVALID}: ${msg}`;
      this.setState(PoseImportState.FAILED);
      return '';
    }
  }

  /**
   * 从 URI 中提取小写扩展名 (最后一个点之后的部分)。
   *
   * 拒绝:
   * - 无扩展名
   * - 以点开头/结尾
   * - .json.zip (取最后一段 .zip, 不匹配 .json)
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
   * 校验扩展名是否为 .json (大小写不敏感)。
   */
  private isValidExtension(ext: string): boolean {
    return ext === 'json';
  }

  /**
   * 从 URI 中提取安全的显示名。
   *
   * 防护 (与动画导入一致):
   * - 只取最后一个路径段
   * - 移除路径分隔符
   * - 移除控制字符
   * - 限制长度 (100 字符)
   * - 保留 .json 扩展名 (供 UI 显示)
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
    return name.length > 0 ? name : 'unknown.json';
  }

  /** 设置状态。 */
  private setState(state: PoseImportState): void {
    this.state = state;
  }
}
