/**
 * AvatarOrientationCalibrationStore Avatar 方向校准存储服务
 *
 * T-4.2G: 按 avatarId 隔离持久化 AvatarOrientationCalibration。
 *
 * 职责:
 * - 通过 AppPreferences 持久化 AvatarOrientationCalibration
 * - 按 avatarId 隔离(每个 Avatar 独立配置)
 * - sourceSha256 在 load 时校验,不匹配返回标志由调用方决定
 * - 提供 save/load/delete/has 四个核心能力
 * - 不缓存值,每次直接读写 Preferences
 * - 不读取聊天 / Prompt / API Key
 *
 * 持久化设计:
 * - key: character_3d_avatar_calibration_<avatarId>
 * - value: JSON 字符串(AvatarOrientationCalibration 序列化)
 * - 同一 avatarId 同时只保存一份校准
 * - 重新导入不同 SHA 时,load 返回 calibration 但 sourceSha256Matched=false
 *
 * 优先级(由 ViewModel 实现):
 *   Manual Override
 *   → Cached Auto Result
 *   → New Auto Analysis
 *   → Safe Default
 *
 * 不依赖 ArkUI/ArkGraphics3D,纯逻辑 + Preferences。
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import {
  AvatarOrientationCalibration,
  serializeCalibration,
  deserializeCalibration,
  createDefaultCalibration
} from '../models/character3d/AvatarOrientationCalibration';

const LOG_TAG: string = 'AvatarOrientationCalibrationStore';

/** Preferences key 前缀:方向校准(per-avatar) */
const PREF_KEY_AVATAR_CALIBRATION_PREFIX: string = 'character_3d_avatar_calibration_';

/**
 * Avatar 方向校准存储服务。
 */
export class AvatarOrientationCalibrationStore {
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * 构造 Preferences key(按 avatarId 隔离)。
   *
   * avatarId 中的非法字符(非 [a-zA-Z0-9._-])替换为 '_',保证 key 合法。
   */
  private buildKey(avatarId: string): string {
    const safe: string = avatarId.replace(/[^a-zA-Z0-9._-]/g, '_');
    return PREF_KEY_AVATAR_CALIBRATION_PREFIX + safe;
  }

  /**
   * 保存方向校准。
   *
   * @param calibration 待保存的校准(必须包含 avatarId)
   * @returns 保存成功返回 true,失败返回 false
   */
  async save(calibration: AvatarOrientationCalibration): Promise<boolean> {
    if (calibration.avatarId.length === 0) {
      Logger.warn(LOG_TAG, 'save rejected: avatarId is empty');
      return false;
    }
    try {
      const json: string = serializeCalibration(calibration);
      const key: string = this.buildKey(calibration.avatarId);
      await this.preferences.putString(key, json);
      Logger.info(LOG_TAG, 'save ok: avatarId=' + calibration.avatarId.substring(0, 8)
        + ', mode=' + calibration.mode
        + ', isManual=' + calibration.isManualOverride);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'save failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 加载方向校准(按 avatarId)。
   *
   * 流程:
   * 1. 读取 Preferences JSON
   * 2. 反序列化为 AvatarOrientationCalibration
   * 3. 检查 sourceSha256 是否匹配
   *    - 匹配:返回校准,sourceSha256Matched=true
   *    - 不匹配:返回校准但 sourceSha256Matched=false(由调用方决定是否重新分析)
   *    - 文件不存在或解析失败:返回 null
   *
   * @param avatarId Avatar ID
   * @param expectedSourceSha256 期望的 sourceSha256(用于检测文件变化)
   * @returns 加载结果(包含 calibration 和 sourceSha256Matched 标志)
   */
  async load(
    avatarId: string,
    expectedSourceSha256: string
  ): Promise<AvatarOrientationCalibrationLoadResult> {
    if (avatarId.length === 0) {
      return { calibration: null, sourceSha256Matched: false };
    }
    try {
      const key: string = this.buildKey(avatarId);
      const json: string = await this.preferences.getString(key, '');
      if (json.length === 0) {
        return { calibration: null, sourceSha256Matched: false };
      }
      const calibration: AvatarOrientationCalibration | null = deserializeCalibration(json);
      if (calibration === null) {
        Logger.warn(LOG_TAG, 'load failed: deserialize returned null');
        return { calibration: null, sourceSha256Matched: false };
      }
      // 检查 sourceSha256
      const shaMatched: boolean = expectedSourceSha256.length === 0
        || calibration.sourceSha256 === expectedSourceSha256;
      Logger.info(LOG_TAG, 'load ok: avatarId=' + avatarId.substring(0, 8)
        + ', mode=' + calibration.mode
        + ', shaMatched=' + shaMatched);
      return {
        calibration: calibration,
        sourceSha256Matched: shaMatched
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'load failed: ' + (e as Error)?.message);
      return { calibration: null, sourceSha256Matched: false };
    }
  }

  /**
   * 删除方向校准(按 avatarId)。
   *
   * @param avatarId Avatar ID
   */
  async delete(avatarId: string): Promise<void> {
    if (avatarId.length === 0) {
      return;
    }
    try {
      const key: string = this.buildKey(avatarId);
      await this.preferences.delete(key);
      Logger.info(LOG_TAG, 'delete ok: avatarId=' + avatarId.substring(0, 8));
    } catch (e) {
      Logger.warn(LOG_TAG, 'delete failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 检查方向校准是否存在(按 avatarId)。
   *
   * @param avatarId Avatar ID
   * @returns 存在返回 true,不存在或读取失败返回 false
   */
  async has(avatarId: string): Promise<boolean> {
    if (avatarId.length === 0) {
      return false;
    }
    try {
      const key: string = this.buildKey(avatarId);
      return await this.preferences.has(key);
    } catch (e) {
      Logger.warn(LOG_TAG, 'has failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 加载或创建默认校准(便利方法)。
   *
   * - 若存在已保存校准且 sha 匹配:返回已保存校准
   * - 若存在但 sha 不匹配:返回已保存校准(但 sourceSha256Matched=false,调用方应重新分析)
   * - 若不存在:返回默认校准(Normal 模式,无校正)
   *
   * @param avatarId Avatar ID
   * @param expectedSourceSha256 期望的 sourceSha256
   * @returns 加载结果(默认校准或已保存校准)
   */
  async loadOrCreateDefault(
    avatarId: string,
    expectedSourceSha256: string
  ): Promise<AvatarOrientationCalibrationLoadResult> {
    const result: AvatarOrientationCalibrationLoadResult = await this.load(avatarId, expectedSourceSha256);
    if (result.calibration !== null) {
      return result;
    }
    // 返回默认校准(不保存,由调用方在分析后保存)
    return {
      calibration: createDefaultCalibration(avatarId, expectedSourceSha256),
      sourceSha256Matched: false
    };
  }
}

/**
 * 加载结果。
 */
export interface AvatarOrientationCalibrationLoadResult {
  /** 加载到的校准(失败为 null) */
  calibration: AvatarOrientationCalibration | null;
  /** sourceSha256 是否匹配(模型文件内容是否一致) */
  sourceSha256Matched: boolean;
}
