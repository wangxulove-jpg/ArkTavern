/**
 * AvatarLibraryViewModel Avatar 模型库 ViewModel
 *
 * T-4.1 阶段 B: 多 Avatar 模型库 UI 状态管理
 *
 * 职责:
 * - 加载 Avatar 列表 + 当前激活 ID
 * - 调用 AvatarLibraryService 完成 导入/切换/重命名/删除
 * - 通知 UI 刷新(通过 onListChanged / onActiveChanged 回调)
 * - 不直接操作 UI 组件 / 网络 / Preferences
 *
 * 使用方式:
 * - aboutToAppear 调用 initialize()
 * - UI 通过 refreshList() 重新加载列表
 * - 操作完成后回调触发 UI 刷新
 */

import { AvatarRecord } from '../storage/AvatarLibraryStore';
import {
  AvatarLibraryService,
  AvatarSaveResult
} from '../services/AvatarLibraryService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'AvatarLibraryVM';

/**
 * Avatar 列表项(UI 友好格式)。
 */
export interface AvatarListItem {
  /** AvatarRecord 原始数据 */
  record: AvatarRecord;
  /** 是否当前激活 */
  isActive: boolean;
  /** VRM 标签文案(如 'VRM 1.0' / 'VRM 0.x' / '非 VRM') */
  vrmLabel: string;
  /** 骨骼摘要文案(如 '骨骼 25/55' 或 '无骨骼') */
  boneSummary: string;
  /** 导入时间文案(如 '2026-07-24 15:30') */
  importedAtLabel: string;
}

/**
 * Avatar 模型库 ViewModel。
 */
export class AvatarLibraryViewModel {
  private service: AvatarLibraryService | null = null;
  /** 当前列表(按导入时间升序) */
  private items: AvatarListItem[] = [];
  /** 当前激活 avatarId */
  private activeAvatarId: string = '';
  /** 是否正在加载 */
  private loading: boolean = false;
  /** 错误信息(空表示无错误) */
  private errorMessage: string = '';

  /** 列表变更回调 */
  onListChanged: ((items: AvatarListItem[]) => void) | null = null;
  /** 激活变更回调 */
  onActiveChanged: ((activeAvatarId: string) => void) | null = null;
  /** 加载状态变更回调 */
  onLoadingChanged: ((loading: boolean) => void) | null = null;
  /** 错误回调 */
  onError: ((message: string) => void) | null = null;

  /**
   * 注入 AvatarLibraryService(由 Page 在 aboutToAppear 时调用)。
   */
  setService(service: AvatarLibraryService): void {
    this.service = service;
  }

  /**
   * 初始化:加载列表 + 激活 ID。
   */
  async initialize(): Promise<void> {
    if (this.service === null) {
      this.setError('AvatarLibraryService 未注入');
      return;
    }
    await this.refreshList();
  }

  /**
   * 重新加载列表 + 激活 ID,触发 UI 刷新。
   */
  async refreshList(): Promise<void> {
    if (this.service === null) {
      return;
    }
    this.setLoading(true);
    try {
      const records: AvatarRecord[] = await this.service.listAvatars();
      this.activeAvatarId = await this.service.getActiveAvatarId();
      this.items = this.buildListItems(records, this.activeAvatarId);
      this.fireListChanged();
      this.fireActiveChanged();
    } catch (e) {
      this.setError('加载列表失败: ' + (e as Error)?.message);
    } finally {
      this.setLoading(false);
    }
  }

  /**
   * 从源 URI 导入新 Avatar。
   * 导入成功后自动设为激活(由 service 内部处理),并刷新列表。
   *
   * @returns 入库结果;失败时返回 null
   */
  async importAvatar(sourceUri: string, displayName: string): Promise<AvatarSaveResult | null> {
    if (this.service === null) {
      this.setError('AvatarLibraryService 未注入');
      return null;
    }
    this.setLoading(true);
    try {
      const result: AvatarSaveResult =
        await this.service.saveAvatarFromUri(sourceUri, displayName, true);
      await this.refreshList();
      Logger.info(LOG_TAG, 'importAvatar ok: name=' + result.record.displayName);
      return result;
    } catch (e) {
      this.setError('导入失败: ' + (e as Error)?.message);
      return null;
    } finally {
      this.setLoading(false);
    }
  }

  /**
   * 从 rawfile 导入测试 Avatar(用于 PoC 验证)。
   */
  async importAvatarFromRawfile(
    rawfileName: string, displayName: string
  ): Promise<AvatarSaveResult | null> {
    if (this.service === null) {
      return null;
    }
    this.setLoading(true);
    try {
      const result: AvatarSaveResult =
        await this.service.saveAvatarFromRawfile(rawfileName, displayName, true);
      await this.refreshList();
      return result;
    } catch (e) {
      this.setError('导入失败: ' + (e as Error)?.message);
      return null;
    } finally {
      this.setLoading(false);
    }
  }

  /**
   * 设为当前激活。
   */
  async setActive(avatarId: string): Promise<boolean> {
    if (this.service === null) {
      return false;
    }
    this.setLoading(true);
    try {
      await this.service.setActiveAvatar(avatarId);
      await this.refreshList();
      return true;
    } catch (e) {
      this.setError('切换激活失败: ' + (e as Error)?.message);
      return false;
    } finally {
      this.setLoading(false);
    }
  }

  /**
   * 重命名。
   */
  async rename(avatarId: string, newDisplayName: string): Promise<boolean> {
    if (this.service === null) {
      return false;
    }
    if (newDisplayName.length === 0) {
      this.setError('名称不能为空');
      return false;
    }
    try {
      await this.service.renameAvatar(avatarId, newDisplayName);
      await this.refreshList();
      return true;
    } catch (e) {
      this.setError('重命名失败: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 删除。
   */
  async delete(avatarId: string): Promise<boolean> {
    if (this.service === null) {
      return false;
    }
    this.setLoading(true);
    try {
      await this.service.deleteAvatar(avatarId);
      await this.refreshList();
      return true;
    } catch (e) {
      this.setError('删除失败: ' + (e as Error)?.message);
      return false;
    } finally {
      this.setLoading(false);
    }
  }

  /**
   * 清空全部 Avatar(开发测试/用户重置)。
   */
  async clearAll(): Promise<boolean> {
    if (this.service === null) {
      return false;
    }
    this.setLoading(true);
    try {
      await this.service.clearAllAvatars();
      await this.refreshList();
      return true;
    } catch (e) {
      this.setError('清空失败: ' + (e as Error)?.message);
      return false;
    } finally {
      this.setLoading(false);
    }
  }

  /**
   * 获取当前列表(不重新加载)。
   */
  getItems(): AvatarListItem[] {
    return this.items;
  }

  /**
   * 获取当前激活 avatarId。
   */
  getActiveAvatarId(): string {
    return this.activeAvatarId;
  }

  /**
   * 是否正在加载。
   */
  isLoading(): boolean {
    return this.loading;
  }

  /**
   * 构造列表项(含 UI 友好文案)。
   */
  private buildListItems(records: AvatarRecord[], activeId: string): AvatarListItem[] {
    const items: AvatarListItem[] = [];
    for (let i = 0; i < records.length; i++) {
      const r: AvatarRecord = records[i];
      items.push({
        record: r,
        isActive: r.avatarId === activeId,
        vrmLabel: this.buildVrmLabel(r),
        boneSummary: this.buildBoneSummary(r),
        importedAtLabel: this.formatTime(r.importedAt)
      });
    }
    return items;
  }

  private buildVrmLabel(r: AvatarRecord): string {
    if (!r.isVrm) {
      return '非 VRM';
    }
    if (r.vrmVersion === 'Vrm1') {
      return 'VRM 1.0';
    }
    if (r.vrmVersion === 'Vrm0x') {
      return 'VRM 0.x';
    }
    return 'VRM';
  }

  private buildBoneSummary(r: AvatarRecord): string {
    if (!r.isVrm) {
      return '无 VRM 骨骼';
    }
    return '骨骼 ' + r.validHumanBoneCount + '/' + r.declaredHumanBoneCount;
  }

  private formatTime(timestamp: number): string {
    if (timestamp <= 0) {
      return '未知时间';
    }
    const d: Date = new Date(timestamp);
    const y: number = d.getFullYear();
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    const h: number = d.getHours();
    const min: number = d.getMinutes();
    const pad = (n: number): string => n < 10 ? '0' + n : '' + n;
    return y + '-' + pad(m) + '-' + pad(day) + ' ' + pad(h) + ':' + pad(min);
  }

  private setLoading(loading: boolean): void {
    this.loading = loading;
    if (this.onLoadingChanged !== null) {
      this.onLoadingChanged(loading);
    }
  }

  private setError(message: string): void {
    this.errorMessage = message;
    Logger.error(LOG_TAG, 'setError: ' + message);
    if (this.onError !== null) {
      this.onError(message);
    }
  }

  private fireListChanged(): void {
    if (this.onListChanged !== null) {
      this.onListChanged(this.items);
    }
  }

  private fireActiveChanged(): void {
    if (this.onActiveChanged !== null) {
      this.onActiveChanged(this.activeAvatarId);
    }
  }
}
