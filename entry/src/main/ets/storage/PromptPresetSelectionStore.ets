/**
 * PromptPresetSelectionStore 当前 Preset 选择存储
 *
 * 职责:
 * - 读取/设置/清空当前 Preset ID
 * - 不保存 Preset 实体、systemPrompt、参数
 * - 不依赖 RDB
 * - 不依赖页面
 *
 * 约束:
 * - 设置非空 ID 前由 PromptPresetService 验证 Repository 中存在
 * - null 表示不使用 Preset,继续使用当前既有行为
 * - 不自动生成默认 ID
 */

import { AppPreferences } from './AppPreferences';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptPresetSelectionStore';
const KEY_CURRENT_PRESET_ID: string = 'current_prompt_preset_id_v1';

export class PromptPresetSelectionStore {
  private readonly prefs: AppPreferences;
  private initialized: boolean = false;

  constructor(prefs: AppPreferences) {
    this.prefs = prefs;
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    Logger.info(LOG_TAG, 'initialize');
    this.initialized = true;
    Logger.info(LOG_TAG, 'initialize ok');
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('PromptPresetSelectionStore not initialized');
    }
  }

  async getCurrentPresetId(): Promise<string | null> {
    this.requireInit();
    try {
      const raw: string = await this.prefs.getString(KEY_CURRENT_PRESET_ID, '');
      if (raw.length === 0) {
        return null;
      }
      return raw;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getCurrentPresetId failed: ' + String(e));
      return null;
    }
  }

  async setCurrentPresetId(id: string | null): Promise<void> {
    this.requireInit();
    if (id !== null && id.length > 0) {
      await this.prefs.putString(KEY_CURRENT_PRESET_ID, id);
    } else {
      await this.prefs.putString(KEY_CURRENT_PRESET_ID, '');
    }
    Logger.info(LOG_TAG, 'setCurrentPresetId ok');
  }

  async clear(): Promise<void> {
    this.requireInit();
    await this.prefs.putString(KEY_CURRENT_PRESET_ID, '');
    Logger.info(LOG_TAG, 'clear ok');
  }
}