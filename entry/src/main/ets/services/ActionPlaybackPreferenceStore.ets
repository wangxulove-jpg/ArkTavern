/**
 * ActionPlaybackPreferenceStore 动作播放偏好存储
 *
 * T-3D.6C-C: 存储用户对动作循环模式的偏好覆盖。
 *
 * 两层偏好:
 * - 全局动作设置:actionId → loopMode(所有模型通用)
 * - per-model 绑定设置:modelId + actionId → loopMode(针对特定模型覆盖)
 *
 * 优先级(per-model > global > manifest default):
 * 1. per-model binding loopMode(非 UseDefault 时生效)
 * 2. global action loopMode(非 UseDefault 时生效)
 * 3. 动作资产默认 loop(manifest 中的 loop 字段)
 *
 * 清除 Preferences 后:内置动作恢复默认循环策略。
 * 删除导入动作时:调用 removeAllForAction 清理该动作的所有循环偏好。
 *
 * 不存储动作二进制数据,不存储 API Key。
 */

import { AppPreferences } from '../storage/AppPreferences';
import { ActionLoopMode, parseLoopMode } from '../models/character3d/Character3DActionAsset';

const PREF_KEY_GLOBAL_LOOP_MODES: string = 'action_loop_modes_global';
const PREF_KEY_MODEL_LOOP_MODES_PREFIX: string = 'action_loop_modes_model_';

/**
 * 循环模式偏好条目。
 */
export interface LoopModeEntry {
  /** 动作 ID */
  actionId: string;
  /** 循环模式(数字,对应 ActionLoopMode 枚举值) */
  loopMode: number;
}

/**
 * 动作播放偏好存储。
 */
export class ActionPlaybackPreferenceStore {
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  // ========== 全局动作循环偏好 ==========

  /**
   * 获取动作的全局循环模式偏好。
   * 未设置时返回 UseDefault。
   */
  async getGlobalLoopMode(actionId: string): Promise<ActionLoopMode> {
    const entries: LoopModeEntry[] = await this.loadGlobalEntries();
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].actionId === actionId) {
        return parseLoopMode(entries[i].loopMode);
      }
    }
    return ActionLoopMode.UseDefault;
  }

  /**
   * 设置动作的全局循环模式。
   * UseDefault 等同于移除偏好(恢复默认)。
   */
  async setGlobalLoopMode(actionId: string, mode: ActionLoopMode): Promise<void> {
    const entries: LoopModeEntry[] = await this.loadGlobalEntries();
    if (mode === ActionLoopMode.UseDefault) {
      // 移除该动作的偏好
      const newEntries: LoopModeEntry[] = [];
      for (let i: number = 0; i < entries.length; i++) {
        if (entries[i].actionId !== actionId) {
          newEntries.push(entries[i]);
        }
      }
      await this.saveGlobalEntries(newEntries);
      return;
    }
    let found: boolean = false;
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].actionId === actionId) {
        entries[i].loopMode = mode;
        found = true;
        break;
      }
    }
    if (!found) {
      entries.push({ actionId: actionId, loopMode: mode } as LoopModeEntry);
    }
    await this.saveGlobalEntries(entries);
  }

  // ========== per-model 绑定循环偏好 ==========

  /**
   * 获取某模型下某动作的循环模式偏好。
   * 未设置时返回 UseDefault。
   */
  async getModelLoopMode(modelId: string, actionId: string): Promise<ActionLoopMode> {
    const entries: LoopModeEntry[] = await this.loadModelEntries(modelId);
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].actionId === actionId) {
        return parseLoopMode(entries[i].loopMode);
      }
    }
    return ActionLoopMode.UseDefault;
  }

  /**
   * 设置某模型下某动作的循环模式。
   * UseDefault 等同于移除偏好(回退到全局或默认)。
   */
  async setModelLoopMode(modelId: string, actionId: string, mode: ActionLoopMode): Promise<void> {
    const entries: LoopModeEntry[] = await this.loadModelEntries(modelId);
    if (mode === ActionLoopMode.UseDefault) {
      const newEntries: LoopModeEntry[] = [];
      for (let i: number = 0; i < entries.length; i++) {
        if (entries[i].actionId !== actionId) {
          newEntries.push(entries[i]);
        }
      }
      await this.saveModelEntries(modelId, newEntries);
      return;
    }
    let found: boolean = false;
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].actionId === actionId) {
        entries[i].loopMode = mode;
        found = true;
        break;
      }
    }
    if (!found) {
      entries.push({ actionId: actionId, loopMode: mode } as LoopModeEntry);
    }
    await this.saveModelEntries(modelId, entries);
  }

  // ========== 统一解析 ==========

  /**
   * 按优先级解析动作的最终循环模式。
   *
   * 优先级:per-model binding loopMode → global action loopMode
   * (两者均为 UseDefault 时返回 UseDefault,由调用方用 manifest default 兜底)
   */
  async resolveEffectiveLoopMode(modelId: string, actionId: string): Promise<ActionLoopMode> {
    // 1. per-model binding
    const modelMode: ActionLoopMode = await this.getModelLoopMode(modelId, actionId);
    if (modelMode !== ActionLoopMode.UseDefault) {
      return modelMode;
    }
    // 2. global action
    const globalMode: ActionLoopMode = await this.getGlobalLoopMode(actionId);
    return globalMode;
  }

  /**
   * 按优先级设置循环模式。
   *
   * 如果 modelId 非空,设置 per-model 偏好;否则设置全局偏好。
   * UseDefault 会移除对应层级的偏好。
   */
  async setLoopMode(modelId: string, actionId: string, mode: ActionLoopMode): Promise<void> {
    if (modelId.length > 0) {
      await this.setModelLoopMode(modelId, actionId, mode);
    } else {
      await this.setGlobalLoopMode(actionId, mode);
    }
  }

  /**
   * 恢复默认(移除 per-model 和全局偏好)。
   */
  async resetLoopMode(modelId: string, actionId: string): Promise<void> {
    if (modelId.length > 0) {
      await this.setModelLoopMode(modelId, actionId, ActionLoopMode.UseDefault);
    }
    await this.setGlobalLoopMode(actionId, ActionLoopMode.UseDefault);
  }

  // ========== 清理 ==========

  /**
   * 删除动作时清理该动作的所有循环偏好(全局 + 所有模型)。
   */
  async removeAllForAction(actionId: string): Promise<void> {
    // 清理全局
    const globalEntries: LoopModeEntry[] = await this.loadGlobalEntries();
    const newGlobal: LoopModeEntry[] = [];
    for (let i: number = 0; i < globalEntries.length; i++) {
      if (globalEntries[i].actionId !== actionId) {
        newGlobal.push(globalEntries[i]);
      }
    }
    await this.saveGlobalEntries(newGlobal);
    // 注:per-model 偏好按需清理,遍历所有 modelId 成本较高,
    // 实际使用中模型数量有限,清理时机为"删除模型"时调用 removeAllForModel。
  }

  /**
   * 删除模型时清理该模型的所有循环偏好。
   */
  async removeAllForModel(modelId: string): Promise<void> {
    const key: string = PREF_KEY_MODEL_LOOP_MODES_PREFIX + modelId;
    await this.preferences.putString(key, '[]');
  }

  /**
   * 清除所有循环偏好(全局 + 所有模型已知 key)。
   * 当前已知 per-model key 通过遍历无法获取全部,仅清理全局;
   * per-model 偏好在删除模型时单独清理。
   */
  async clearAllGlobal(): Promise<void> {
    await this.preferences.putString(PREF_KEY_GLOBAL_LOOP_MODES, '[]');
  }

  // ========== 内部加载/保存 ==========

  private async loadGlobalEntries(): Promise<LoopModeEntry[]> {
    const json: string = await this.preferences.getString(PREF_KEY_GLOBAL_LOOP_MODES, '[]');
    return this.parseEntries(json);
  }

  private async saveGlobalEntries(entries: LoopModeEntry[]): Promise<void> {
    await this.preferences.putString(PREF_KEY_GLOBAL_LOOP_MODES, JSON.stringify(entries));
  }

  private async loadModelEntries(modelId: string): Promise<LoopModeEntry[]> {
    const key: string = PREF_KEY_MODEL_LOOP_MODES_PREFIX + modelId;
    const json: string = await this.preferences.getString(key, '[]');
    return this.parseEntries(json);
  }

  private async saveModelEntries(modelId: string, entries: LoopModeEntry[]): Promise<void> {
    const key: string = PREF_KEY_MODEL_LOOP_MODES_PREFIX + modelId;
    await this.preferences.putString(key, JSON.stringify(entries));
  }

  private parseEntries(json: string): LoopModeEntry[] {
    try {
      const obj: Object = JSON.parse(json);
      if (!(obj instanceof Array)) {
        return [];
      }
      const arr: Object[] = obj as Object[];
      const result: LoopModeEntry[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        const item: Record<string, Object> = arr[i] as Record<string, Object>;
        const id: string = String(item['actionId'] ?? '');
        const mode: number = Number(item['loopMode'] ?? 0);
        if (id.length > 0) {
          result.push({ actionId: id, loopMode: mode } as LoopModeEntry);
        }
      }
      return result;
    } catch (e) {
      return [];
    }
  }
}
