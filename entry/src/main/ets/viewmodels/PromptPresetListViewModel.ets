/**
 * PromptPresetListViewModel 预设列表状态管理
 *
 * 页面与 PromptPresetService 之间的唯一桥梁。
 * 不直接依赖 Repository、DbHelper 或 Preferences。
 */

import { PromptPreset } from '../models/PromptPreset';
import { PromptPresetService } from '../services/PromptPresetService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptPresetListViewModel';

@Observed
export class PromptPresetListViewModel {
  presets: PromptPreset[] = [];
  currentPresetId: string = '';
  isLoading: boolean = false;
  isOperating: boolean = false;
  errorMessage: string = '';
  showDeleteConfirm: boolean = false;
  pendingDeleteId: string = '';

  private readonly presetService: PromptPresetService;
  private disposed: boolean = false;

  constructor(presetService: PromptPresetService) {
    this.presetService = presetService;
  }

  async initialize(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    await this.refresh();
  }

  async refresh(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    try {
      this.presets = await this.presetService.list();
      const currentId: string | null = await this.presetService.getCurrentPresetId();
      this.currentPresetId = currentId !== null ? currentId : '';
    } catch (e) {
      this.errorMessage = '加载预设列表失败';
      Logger.error(LOG_TAG, 'refresh failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  async setCurrent(id: string): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.presetService.setCurrentPresetId(id);
      this.currentPresetId = id;
      Logger.info(LOG_TAG, 'setCurrent success');
    } catch (e) {
      this.errorMessage = '设置预设失败';
      Logger.error(LOG_TAG, 'setCurrent failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  async clearCurrent(): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.presetService.setCurrentPresetId(null);
      this.currentPresetId = '';
      Logger.info(LOG_TAG, 'clearCurrent success');
    } catch (e) {
      this.errorMessage = '清除预设失败';
      Logger.error(LOG_TAG, 'clearCurrent failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  requestDelete(id: string): void {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.pendingDeleteId = id;
    this.showDeleteConfirm = true;
    this.errorMessage = '';
  }

  cancelDelete(): void {
    this.pendingDeleteId = '';
    this.showDeleteConfirm = false;
  }

  async confirmDelete(id: string): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    try {
      await this.presetService.remove(id);
      this.pendingDeleteId = '';
      // 删除后刷新列表和当前选择
      await this.refresh();
      Logger.info(LOG_TAG, 'confirmDelete success');
    } catch (e) {
      this.errorMessage = '删除预设失败';
      Logger.error(LOG_TAG, 'confirmDelete failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  getPresetSummary(preset: PromptPreset): string {
    const parts: string[] = [];
    if (preset.temperature !== undefined) {
      parts.push('温度 ' + preset.temperature.toString());
    }
    if (preset.topP !== undefined) {
      parts.push('Top P ' + preset.topP.toString());
    }
    if (preset.maxOutputTokens !== undefined) {
      parts.push('输出 ' + preset.maxOutputTokens.toString());
    }
    if (preset.contextWindow !== undefined) {
      parts.push('上下文 ' + preset.contextWindow.toString());
    }
    if (parts.length === 0) {
      return '沿用当前模型参数';
    }
    return parts.join(' · ');
  }

  isCurrentPreset(id: string): boolean {
    return this.currentPresetId === id;
  }

  dispose(): void {
    this.disposed = true;
  }
}