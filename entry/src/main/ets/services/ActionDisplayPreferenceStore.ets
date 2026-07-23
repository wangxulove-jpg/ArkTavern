/**
 * ActionDisplayPreferenceStore 动作显示偏好存储
 *
 * T-3D.6C: 存储用户对动作的显示偏好(别名、隐藏状态)。
 * 内置动作的别名和隐藏状态保存在 Preferences,清除后恢复默认。
 *
 * 不存储动作二进制数据,不存储 API Key。
 */

import { AppPreferences } from '../storage/AppPreferences';

const PREF_KEY_BUILTIN_ALIASES: string = 'builtin_action_aliases';
const PREF_KEY_HIDDEN_ACTIONS: string = 'hidden_builtin_actions';

/**
 * 别名映射(ID → 自定义名)。
 */
export interface AliasEntry {
  id: string;
  alias: string;
}

/**
 * 动作显示偏好存储。
 */
export class ActionDisplayPreferenceStore {
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * 获取动作的自定义显示名(别名)。
   * 不存在时返回空字符串。
   */
  async getAlias(actionId: string): Promise<string> {
    const entries: AliasEntry[] = await this.loadAliasEntries();
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].id === actionId) {
        return entries[i].alias;
      }
    }
    return '';
  }

  /**
   * 设置动作别名。
   * 空字符串或纯空白将被拒绝。
   */
  async setAlias(actionId: string, displayName: string): Promise<void> {
    const trimmed: string = displayName.trim();
    if (trimmed.length === 0) {
      return;
    }
    if (trimmed.length > 30) {
      return;
    }
    const entries: AliasEntry[] = await this.loadAliasEntries();
    let found: boolean = false;
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].id === actionId) {
        entries[i].alias = trimmed;
        found = true;
        break;
      }
    }
    if (!found) {
      entries.push({ id: actionId, alias: trimmed } as AliasEntry);
    }
    await this.saveAliasEntries(entries);
  }

  /**
   * 移除动作别名(恢复默认名)。
   */
  async removeAlias(actionId: string): Promise<void> {
    const entries: AliasEntry[] = await this.loadAliasEntries();
    const newEntries: AliasEntry[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].id !== actionId) {
        newEntries.push(entries[i]);
      }
    }
    await this.saveAliasEntries(newEntries);
  }

  /**
   * 获取所有别名映射。
   * 返回 AliasEntry 数组,调用方通过遍历查找。
   */
  async getAllAliases(): Promise<AliasEntry[]> {
    return this.loadAliasEntries();
  }

  /**
   * 判断动作是否被隐藏。
   */
  async isHidden(actionId: string): Promise<boolean> {
    const ids: string[] = await this.loadHiddenIds();
    for (let i: number = 0; i < ids.length; i++) {
      if (ids[i] === actionId) {
        return true;
      }
    }
    return false;
  }

  /**
   * 设置动作隐藏状态。
   */
  async setHidden(actionId: string, hidden: boolean): Promise<void> {
    const ids: string[] = await this.loadHiddenIds();
    const newIds: string[] = [];
    let existed: boolean = false;
    for (let i: number = 0; i < ids.length; i++) {
      if (ids[i] === actionId) {
        existed = true;
        if (hidden) {
          newIds.push(ids[i]);
        }
      } else {
        newIds.push(ids[i]);
      }
    }
    if (hidden && !existed) {
      newIds.push(actionId);
    }
    await this.saveHiddenIds(newIds);
  }

  /**
   * 获取所有隐藏的 actionId 集合。
   */
  async getHiddenIds(): Promise<Set<string>> {
    const arr: string[] = await this.loadHiddenIds();
    const result: Set<string> = new Set();
    for (let i: number = 0; i < arr.length; i++) {
      result.add(arr[i]);
    }
    return result;
  }

  /**
   * 清除所有别名和隐藏状态。
   */
  async clearAll(): Promise<void> {
    await this.preferences.putString(PREF_KEY_BUILTIN_ALIASES, '[]');
    await this.preferences.putString(PREF_KEY_HIDDEN_ACTIONS, '[]');
  }

  private async loadAliasEntries(): Promise<AliasEntry[]> {
    const json: string = await this.preferences.getString(PREF_KEY_BUILTIN_ALIASES, '[]');
    try {
      const obj: Object = JSON.parse(json);
      if (!(obj instanceof Array)) {
        return [];
      }
      const arr: Object[] = obj as Object[];
      const result: AliasEntry[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        const item: Record<string, Object> = arr[i] as Record<string, Object>;
        const id: string = String(item['id'] ?? '');
        const alias: string = String(item['alias'] ?? '');
        if (id.length > 0 && alias.length > 0) {
          result.push({ id: id, alias: alias } as AliasEntry);
        }
      }
      return result;
    } catch (e) {
      return [];
    }
  }

  private async saveAliasEntries(entries: AliasEntry[]): Promise<void> {
    await this.preferences.putString(PREF_KEY_BUILTIN_ALIASES, JSON.stringify(entries));
  }

  private async loadHiddenIds(): Promise<string[]> {
    const json: string = await this.preferences.getString(PREF_KEY_HIDDEN_ACTIONS, '[]');
    try {
      const obj: Object = JSON.parse(json);
      if (!(obj instanceof Array)) {
        return [];
      }
      const arr: Object[] = obj as Object[];
      const result: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        const id: string = String(arr[i]);
        if (id.length > 0) {
          result.push(id);
        }
      }
      return result;
    } catch (e) {
      return [];
    }
  }

  private async saveHiddenIds(ids: string[]): Promise<void> {
    await this.preferences.putString(PREF_KEY_HIDDEN_ACTIONS, JSON.stringify(ids));
  }
}
