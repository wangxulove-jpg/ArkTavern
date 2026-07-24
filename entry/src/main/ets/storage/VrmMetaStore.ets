/**
 * VrmMetaStore VRM 元数据持久化存储
 *
 * T-4.0: VRM First Architecture
 *
 * 职责:
 * - 通过 AppPreferences 持久化 VrmAsset(按 sourceSha256 关联)
 * - 提供 save/load/delete/has 四个核心能力
 * - 不缓存值,每次直接读写 Preferences
 * - 不读取聊天 / Prompt / API Key
 *
 * 持久化设计:
 * - Preferences key: character_3d_vrm_asset_<sourceSha256Prefix>
 * - value: JSON 字符串(VrmAsset 序列化)
 * - 按 sourceSha256 前 16 位作为 key(避免过长 key)
 * - 重新导入同 SHA 时,load 返回缓存的 VrmAsset
 * - 重新导入不同 SHA 时,旧 key 自动失效(由调用方删除)
 *
 * 注意:
 * - VrmAsset 包含完整的 VRM 解析产物(meta/humanoid/expressions/lookAt/springBone/firstPerson)
 * - 序列化使用 JSON.stringify,枚举值序列化为字符串
 * - 反序列化使用 JSON.parse + 类型断言,枚举字段保持字符串形式
 *
 * 不依赖 ArkUI/ArkGraphics3D,纯逻辑 + Preferences。
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import { VrmAsset } from '../models/character3d/vrm/VrmAsset';
import { isVrm } from '../models/character3d/vrm/VrmVersion';

const LOG_TAG: string = 'VrmMetaStore';

/** Preferences key 前缀:VRM 资产(per-sourceSha256) */
const PREF_KEY_VRM_ASSET_PREFIX: string = 'character_3d_vrm_asset_';

/** sourceSha256 key 前缀长度(避免过长 key) */
const SHA256_KEY_LENGTH: number = 16;

/**
 * VRM 资产存储服务。
 */
export class VrmMetaStore {
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * 构造 Preferences key。
   *
   * 使用 sourceSha256 前 16 位作为 key 后缀,保证 key 长度合理。
   * sourceSha256 中的非法字符(非 [a-zA-Z0-9._-])替换为 '_'。
   */
  private buildKey(sourceSha256: string): string {
    const prefix: string = sourceSha256.length > SHA256_KEY_LENGTH
      ? sourceSha256.substring(0, SHA256_KEY_LENGTH)
      : sourceSha256;
    const safe: string = prefix.replace(/[^a-zA-Z0-9._-]/g, '_');
    return PREF_KEY_VRM_ASSET_PREFIX + safe;
  }

  /**
   * 保存 VRM 资产。
   *
   * @param asset VRM 资产(必须包含 sourceSha256)
   * @returns 保存成功返回 true,失败返回 false
   */
  async save(asset: VrmAsset): Promise<boolean> {
    if (!isVrm(asset.version)) {
      Logger.warn(LOG_TAG, 'save rejected: not VRM');
      return false;
    }
    if (asset.sourceSha256.length === 0) {
      Logger.warn(LOG_TAG, 'save rejected: sourceSha256 is empty');
      return false;
    }
    try {
      const json: string = serializeVrmAsset(asset);
      const key: string = this.buildKey(asset.sourceSha256);
      await this.preferences.putString(key, json);
      Logger.info(LOG_TAG, 'save ok: version=' + asset.version
        + ', meta=' + asset.meta.name
        + ', bones=' + asset.humanoid.bones.length
        + ', expressions=' + asset.expressions.expressions.length
        + ', springJoints=' + asset.springBone.totalJointCount);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'save failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 加载 VRM 资产。
   *
   * @param sourceSha256 模型文件 SHA-256
   * @returns VRM 资产(不存在或解析失败返回 null)
   */
  async load(sourceSha256: string): Promise<VrmAsset | null> {
    if (sourceSha256.length === 0) {
      return null;
    }
    try {
      const key: string = this.buildKey(sourceSha256);
      const json: string = await this.preferences.getString(key, '');
      if (json.length === 0) {
        return null;
      }
      const asset: VrmAsset | null = deserializeVrmAsset(json);
      if (asset === null) {
        Logger.warn(LOG_TAG, 'load parse failed');
        return null;
      }
      Logger.info(LOG_TAG, 'load ok: version=' + asset.version
        + ', meta=' + asset.meta.name
        + ', bones=' + asset.humanoid.bones.length);
      return asset;
    } catch (e) {
      Logger.warn(LOG_TAG, 'load failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * 删除 VRM 资产。
   *
   * @param sourceSha256 模型文件 SHA-256
   */
  async delete(sourceSha256: string): Promise<void> {
    if (sourceSha256.length === 0) {
      return;
    }
    try {
      const key: string = this.buildKey(sourceSha256);
      await this.preferences.delete(key);
      Logger.info(LOG_TAG, 'delete ok');
    } catch (e) {
      Logger.warn(LOG_TAG, 'delete failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 检查 VRM 资产是否存在。
   */
  async has(sourceSha256: string): Promise<boolean> {
    if (sourceSha256.length === 0) {
      return false;
    }
    try {
      const key: string = this.buildKey(sourceSha256);
      return await this.preferences.has(key);
    } catch (e) {
      return false;
    }
  }
}

/**
 * 序列化 VrmAsset 为 JSON 字符串。
 *
 * 枚举字段(VrmVersion/VrmCommercialUsage 等)序列化为字符串,
 * 反序列化时通过 as 断言恢复类型。
 */
export function serializeVrmAsset(asset: VrmAsset): string {
  return JSON.stringify(asset);
}

/**
 * 从 JSON 字符串反序列化 VrmAsset。
 *
 * @returns 解析失败返回 null
 */
export function deserializeVrmAsset(json: string): VrmAsset | null {
  try {
    const obj: Object = JSON.parse(json);
    if (obj === null) {
      return null;
    }
    const asset: VrmAsset = obj as VrmAsset;
    // 基本字段校验
    if (asset.version === undefined || asset.sourceSha256 === undefined) {
      return null;
    }
    // 非 VRM 不应通过此存储返回
    if (!isVrm(asset.version)) {
      return null;
    }
    return asset;
  } catch (e) {
    return null;
  }
}
