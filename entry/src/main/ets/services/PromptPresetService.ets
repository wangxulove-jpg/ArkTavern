/**
 * PromptPresetService 业务服务
 *
 * 职责:
 * - PromptPreset 的 CRUD 业务编排
 * - 当前 Preset 选择管理
 * - 删除当前 Preset 时清空选择
 * - 不存在的当前 Preset 自动清空
 *
 * 不负责:
 * - ChatService / PromptBuilder / Provider 请求参数接入(T-6.1B)
 * - 管理 UI
 * - 导入导出
 * - 自动创建默认 Preset
 * - 从现有模型设置迁移 Preset
 *
 * 安全:
 * - 错误不泄露 systemPrompt 或完整 Preset ID
 * - 日志不输出 Preset name / description / systemPrompt
 */

import { PromptPresetRepository } from '../repositories/PromptPresetRepository';
import { PromptPresetSelectionStore } from '../storage/PromptPresetSelectionStore';
import {
  PromptPreset,
  CreatePromptPresetOptions,
  PromptPresetUpdates,
  createPromptPreset,
  updatePromptPreset,
  validatePromptPreset
} from '../models/PromptPreset';
import { DatabaseError, DatabaseErrorType } from '../models/DatabaseError';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptPresetService';

export class PromptPresetService {
  private readonly repository: PromptPresetRepository;
  private readonly selectionStore: PromptPresetSelectionStore;

  constructor(
    repository: PromptPresetRepository,
    selectionStore: PromptPresetSelectionStore
  ) {
    this.repository = repository;
    this.selectionStore = selectionStore;
  }

  async initialize(): Promise<void> {
    Logger.info(LOG_TAG, 'initialize');
    await this.selectionStore.initialize();
    Logger.info(LOG_TAG, 'initialize ok');
  }

  async list(): Promise<PromptPreset[]> {
    return await this.repository.list();
  }

  async getById(id: string): Promise<PromptPreset | null> {
    return await this.repository.getById(id);
  }

  async create(options: CreatePromptPresetOptions): Promise<PromptPreset> {
    const preset: PromptPreset = createPromptPreset(options);
    await this.repository.insert(preset);
    Logger.info(LOG_TAG, 'create success');
    return preset;
  }

  async update(id: string, updates: PromptPresetUpdates): Promise<PromptPreset> {
    const existing: PromptPreset | null = await this.repository.getById(id);
    if (existing === null) {
      throw DatabaseError.notFound('preset.update');
    }
    const updated: PromptPreset = updatePromptPreset(existing, updates);
    await this.repository.update(updated);
    Logger.info(LOG_TAG, 'update success');
    return updated;
  }

  async remove(id: string): Promise<void> {
    // 幂等:先检查是否存在
    const exists: boolean = await this.repository.exists(id);
    if (!exists) {
      return;
    }
    await this.repository.remove(id);
    Logger.info(LOG_TAG, 'remove success');

    // 如果删除的是当前 Preset,清空选择
    const currentId: string | null = await this.selectionStore.getCurrentPresetId();
    if (currentId === id) {
      await this.selectionStore.setCurrentPresetId(null);
      Logger.info(LOG_TAG, 'current selection cleared');
    }
  }

  async getCurrentPresetId(): Promise<string | null> {
    return await this.selectionStore.getCurrentPresetId();
  }

  async getCurrentPreset(): Promise<PromptPreset | null> {
    const id: string | null = await this.selectionStore.getCurrentPresetId();
    if (id === null) {
      return null;
    }
    const preset: PromptPreset | null = await this.repository.getById(id);
    if (preset === null) {
      // 当前 ID 指向不存在的 Preset,清空选择
      await this.selectionStore.setCurrentPresetId(null);
      Logger.info(LOG_TAG, 'current selection cleared (preset not found)');
      return null;
    }
    return preset;
  }

  async setCurrentPresetId(id: string | null): Promise<void> {
    if (id === null) {
      await this.selectionStore.setCurrentPresetId(null);
      Logger.info(LOG_TAG, 'current selection updated');
      return;
    }
    // 验证 Preset 存在
    const exists: boolean = await this.repository.exists(id);
    if (!exists) {
      throw DatabaseError.notFound('preset.setCurrent');
    }
    await this.selectionStore.setCurrentPresetId(id);
    Logger.info(LOG_TAG, 'current selection updated');
  }
}