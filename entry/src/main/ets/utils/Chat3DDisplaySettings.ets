/**
 * Chat3DDisplaySettings 聊天页 3D 显示开关设置
 *
 * T-3D.5: 单人聊天页 3D 展示接入与设置开关
 *
 * 职责:
 * - 管理"显示 3D 角色模型"全局开关(默认关闭)
 * - 通过 AppPreferences 持久化(key: chat_enable_character_3d)
 * - 不存储 API Key / Character / Message 等业务数据
 * - 不访问 RDB / Asset Store / Network
 *
 * 通知机制:
 * - 写入后通过 AppStorage.setOrCreate('chat3dConfigVersion', v+1) 通知监听方
 * - ChatPage 通过 @StorageProp('chat3dConfigVersion') + @Watch 监听变更
 *
 * 错误处理:
 * - Preferences 读取失败时默认关闭(安全降级)
 * - Preferences 写入失败时抛出异常,由调用方决定是否提示用户
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from './Logger';

const LOG_TAG: string = 'Chat3DSettings';

/** Preferences key:是否在聊天页显示 3D 角色模型 */
export const PREF_KEY_CHAT_ENABLE_3D: string = 'chat_enable_character_3d';
/** Preferences key:3D 区域占聊天页可用高度比例 */
export const PREF_KEY_CHAT_3D_PANEL_RATIO: string = 'chat_character_3d_panel_ratio';
/** Preferences key:旋转灵敏度(0.2 ~ 2.0,1.0 = 标准) */
export const PREF_KEY_CHAT_3D_ROTATION_SENSITIVITY: string = 'chat_character_3d_rotation_sensitivity';

/** 默认值:关闭(安全降级,避免无模型时显示空白) */
export const DEFAULT_CHAT_ENABLE_3D: boolean = false;
/** 默认 3D 区域占比(40%) */
export const DEFAULT_CHAT_3D_PANEL_RATIO: number = 0.40;
/** 默认旋转灵敏度(1.0 = 标准) */
export const DEFAULT_CHAT_3D_ROTATION_SENSITIVITY: number = 1.0;

/** Panel Ratio 范围 */
export const PANEL_RATIO_MIN: number = 0.25;
export const PANEL_RATIO_MAX: number = 0.65;
/** 旋转灵敏度范围 */
export const ROTATION_SENSITIVITY_MIN: number = 0.2;
export const ROTATION_SENSITIVITY_MAX: number = 2.0;

/** AppStorage 通知 key(每次写入后递增) */
export const CHAT_3D_CONFIG_VERSION_KEY: string = 'chat3dConfigVersion';

export class Chat3DDisplaySettings {
  private preferences: AppPreferences;
  /** 内存缓存(避免每次读取都访问 Preferences) */
  private cachedEnabled: boolean = DEFAULT_CHAT_ENABLE_3D;
  /** T-3D.5B: 3D 区域占比缓存 */
  private cachedPanelRatio: number = DEFAULT_CHAT_3D_PANEL_RATIO;
  /** T-3D.5B: 旋转灵敏度缓存 */
  private cachedRotationSensitivity: number = DEFAULT_CHAT_3D_ROTATION_SENSITIVITY;
  /** 是否已加载 */
  private loaded: boolean = false;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * 从 Preferences 加载设置。
   * 应在 AppServices.initialize 中调用。
   * 读取失败时回退到默认值。
   */
  async load(): Promise<void> {
    try {
      this.cachedEnabled = await this.preferences.getBoolean(
        PREF_KEY_CHAT_ENABLE_3D, DEFAULT_CHAT_ENABLE_3D
      );
      // AppPreferences 不提供 getNumber,用 getString + parseFloat 实现
      const panelRatioStr: string = await this.preferences.getString(
        PREF_KEY_CHAT_3D_PANEL_RATIO, DEFAULT_CHAT_3D_PANEL_RATIO.toString()
      );
      this.cachedPanelRatio = sanitizePanelRatio(parseFloat(panelRatioStr));
      const rotSensStr: string = await this.preferences.getString(
        PREF_KEY_CHAT_3D_ROTATION_SENSITIVITY, DEFAULT_CHAT_3D_ROTATION_SENSITIVITY.toString()
      );
      this.cachedRotationSensitivity = sanitizeRotationSensitivity(parseFloat(rotSensStr));
      this.loaded = true;
      Logger.info(LOG_TAG, 'load: enabled=' + this.cachedEnabled
        + ', panelRatio=' + this.cachedPanelRatio
        + ', rotSens=' + this.cachedRotationSensitivity);
    } catch (e) {
      // Preferences 异常时回退到默认值(安全降级)
      this.cachedEnabled = DEFAULT_CHAT_ENABLE_3D;
      this.cachedPanelRatio = DEFAULT_CHAT_3D_PANEL_RATIO;
      this.cachedRotationSensitivity = DEFAULT_CHAT_3D_ROTATION_SENSITIVITY;
      this.loaded = true;
      Logger.warn(LOG_TAG, 'load failed, fallback to default: ' + (e as Error)?.message);
    }
  }

  /**
   * 获取当前开关状态。
   * 未加载时返回默认值(关闭)。
   */
  isEnabled(): boolean {
    return this.cachedEnabled;
  }

  /**
   * 设置开关状态并持久化。
   * 写入成功后通过 AppStorage 通知监听方。
   *
   * @param enabled true=开启,false=关闭
   * @throws Error 当 Preferences 写入失败时
   */
  async setEnabled(enabled: boolean): Promise<void> {
    if (this.cachedEnabled === enabled && this.loaded) {
      // 短路:值未变化,不重复写盘
      return;
    }
    await this.preferences.putBoolean(PREF_KEY_CHAT_ENABLE_3D, enabled);
    this.cachedEnabled = enabled;
    this.loaded = true;
    // 通知监听方(ChatPage 通过 @StorageProp 监听)
    const v: number = AppStorage.get<number>(CHAT_3D_CONFIG_VERSION_KEY) ?? 0;
    AppStorage.setOrCreate<number>(CHAT_3D_CONFIG_VERSION_KEY, v + 1);
    Logger.info(LOG_TAG, 'setEnabled: ' + enabled + ', notified version=' + (v + 1));
  }

  /**
   * 是否已加载(用于测试验证)。
   */
  isLoaded(): boolean {
    return this.loaded;
  }

  // ===== T-3D.5B: 3D 区域占比 =====

  /**
   * 获取 3D 区域占比(0.25 ~ 0.65)。
   */
  getPanelRatio(): number {
    return this.cachedPanelRatio;
  }

  /**
   * 设置 3D 区域占比并持久化。
   * 非法值会被夹紧到 [PANEL_RATIO_MIN, PANEL_RATIO_MAX]。
   */
  async setPanelRatio(ratio: number): Promise<void> {
    const safe: number = sanitizePanelRatio(ratio);
    if (this.cachedPanelRatio === safe && this.loaded) {
      return;
    }
    await this.preferences.putString(PREF_KEY_CHAT_3D_PANEL_RATIO, safe.toString());
    this.cachedPanelRatio = safe;
    this.notifyChanged();
    Logger.info(LOG_TAG, 'setPanelRatio: ' + safe);
  }

  // ===== T-3D.5B: 旋转灵敏度 =====

  /**
   * 获取旋转灵敏度(0.2 ~ 2.0,1.0 = 标准)。
   */
  getRotationSensitivity(): number {
    return this.cachedRotationSensitivity;
  }

  /**
   * 设置旋转灵敏度并持久化。
   * 非法值会被夹紧到 [ROTATION_SENSITIVITY_MIN, ROTATION_SENSITIVITY_MAX]。
   */
  async setRotationSensitivity(sensitivity: number): Promise<void> {
    const safe: number = sanitizeRotationSensitivity(sensitivity);
    if (this.cachedRotationSensitivity === safe && this.loaded) {
      return;
    }
    await this.preferences.putString(PREF_KEY_CHAT_3D_ROTATION_SENSITIVITY, safe.toString());
    this.cachedRotationSensitivity = safe;
    this.notifyChanged();
    Logger.info(LOG_TAG, 'setRotationSensitivity: ' + safe);
  }

  /**
   * 通知监听方配置变更。
   */
  private notifyChanged(): void {
    const v: number = AppStorage.get<number>(CHAT_3D_CONFIG_VERSION_KEY) ?? 0;
    AppStorage.setOrCreate<number>(CHAT_3D_CONFIG_VERSION_KEY, v + 1);
  }
}

/**
 * 夹紧 panel ratio 到合法范围,NaN/Infinity 回退默认。
 */
function sanitizePanelRatio(ratio: number): number {
  if (!Number.isFinite(ratio)) {
    return DEFAULT_CHAT_3D_PANEL_RATIO;
  }
  if (ratio < PANEL_RATIO_MIN) {
    return PANEL_RATIO_MIN;
  }
  if (ratio > PANEL_RATIO_MAX) {
    return PANEL_RATIO_MAX;
  }
  return ratio;
}

/**
 * 夹紧 rotation sensitivity 到合法范围,NaN/Infinity 回退默认。
 */
function sanitizeRotationSensitivity(sensitivity: number): number {
  if (!Number.isFinite(sensitivity) || sensitivity <= 0) {
    return DEFAULT_CHAT_3D_ROTATION_SENSITIVITY;
  }
  if (sensitivity < ROTATION_SENSITIVITY_MIN) {
    return ROTATION_SENSITIVITY_MIN;
  }
  if (sensitivity > ROTATION_SENSITIVITY_MAX) {
    return ROTATION_SENSITIVITY_MAX;
  }
  return sensitivity;
}
