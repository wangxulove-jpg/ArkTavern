/**
 * HumanoidMappingStore 手动人形骨骼映射存储服务
 *
 * T-3D.6E P3: 实现可保存的手动人形骨骼映射基础功能。
 * T-4.2B: 缓存隔离改为按 avatarId(替代旧 modelId),避免同名模型冲突。
 *
 * 职责:
 * - 通过 AppPreferences 持久化 ManualHumanoidMapping
 * - T-4.2B: 按 avatarId 隔离(每个 Avatar 独立缓存)
 * - sourceSha256 + skeletonHash 在 load 时校验,不匹配返回标志由调用方决定
 * - 提供 save/load/delete/has 四个核心能力
 * - 提供 loadLegacyByModelId/deleteLegacyByModelId 用于旧缓存迁移
 * - 不缓存值,每次直接读写 Preferences
 * - 不读取聊天 / Prompt / API Key
 *
 * 持久化设计:
 * - T-4.2B 新 key: character_3d_avatar_mapping_<avatarId>
 * - 旧 key(已废弃): character_3d_manual_mapping_<modelId>
 * - value: JSON 字符串(ManualHumanoidMapping 序列化)
 * - 同一 avatarId 同时只保存一份映射
 * - 重新导入同 SHA 时,load 返回旧映射并标记 skeletonHash 一致
 * - 重新导入不同 SHA 时,load 返回 mapping 但 sourceSha256Matched=false
 *
 * 不依赖 ArkUI/ArkGraphics3D,纯逻辑 + Preferences。
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import {
  ManualHumanoidMapping,
  serializeManualMapping,
  deserializeManualMapping
} from '../models/character3d/ManualHumanoidMapping';

const LOG_TAG: string = 'HumanoidMappingStore';

/** T-4.2B: Preferences key 前缀:手动映射(per-avatar,新) */
const PREF_KEY_AVATAR_MAPPING_PREFIX: string = 'character_3d_avatar_mapping_';
/** T-4.2B: 旧 Preferences key 前缀(已废弃,仅用于迁移读取) */
const PREF_KEY_LEGACY_MANUAL_MAPPING_PREFIX: string = 'character_3d_manual_mapping_';

/**
 * 手动骨骼映射存储服务。
 */
export class HumanoidMappingStore {
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * T-4.2B: 构造新 Preferences key(按 avatarId 隔离)。
   *
   * avatarId 中的非法字符(非 [a-zA-Z0-9._-])替换为 '_',保证 key 合法。
   */
  private buildKey(avatarId: string): string {
    const safe: string = avatarId.replace(/[^a-zA-Z0-9._-]/g, '_');
    return PREF_KEY_AVATAR_MAPPING_PREFIX + safe;
  }

  /**
   * T-4.2B: 构造旧 Preferences key(按 modelId,已废弃)。
   *
   * 仅用于 loadLegacyByModelId / deleteLegacyByModelId 迁移逻辑。
   */
  private buildLegacyKey(modelId: string): string {
    const safe: string = modelId.replace(/[^a-zA-Z0-9._-]/g, '_');
    return PREF_KEY_LEGACY_MANUAL_MAPPING_PREFIX + safe;
  }

  /**
   * 保存手动映射。
   *
   * 流程:
   * 1. 序列化为 JSON
   * 2. 写入 Preferences(以 avatarId 为 key)
   * 3. flush 落盘(AppPreferences.putString 内部已 flush)
   *
   * @param mapping 待保存的映射(必须包含 avatarId)
   * @returns 保存成功返回 true,失败返回 false
   */
  async save(mapping: ManualHumanoidMapping): Promise<boolean> {
    if (mapping.avatarId.length === 0) {
      Logger.warn(LOG_TAG, 'save rejected: avatarId is empty');
      return false;
    }
    try {
      const json: string = serializeManualMapping(mapping);
      const key: string = this.buildKey(mapping.avatarId);
      await this.preferences.putString(key, json);
      Logger.info(LOG_TAG, 'save ok: avatarId=' + mapping.avatarId.substring(0, 8)
        + ', joints=' + mapping.joints.length
        + ', valid=' + mapping.valid
        + ', retargetReady=' + mapping.retargetReady);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'save failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 加载手动映射(按 avatarId)。
   *
   * 流程:
   * 1. 读取 Preferences JSON
   * 2. 反序列化为 ManualHumanoidMapping
   * 3. 检查 sourceSha256 是否匹配
   *    - 匹配:返回映射,sourceSha256Matched=true
   *    - 不匹配:返回映射但 sourceSha256Matched=false(由调用方决定是否要求重新验证)
   *    - 文件不存在或解析失败:返回 null
   *
   * @param avatarId Avatar ID
   * @param expectedSourceSha256 期望的 sourceSha256(用于检测文件变化)
   * @returns 映射加载结果(包含 mapping 和 sourceSha256Matched 标志)
   */
  async load(
    avatarId: string,
    expectedSourceSha256: string
  ): Promise<HumanoidMappingLoadResult> {
    if (avatarId.length === 0) {
      return { mapping: null, sourceSha256Matched: false, skeletonHashMatched: false };
    }
    try {
      const key: string = this.buildKey(avatarId);
      const json: string = await this.preferences.getString(key, '');
      if (json.length === 0) {
        return { mapping: null, sourceSha256Matched: false, skeletonHashMatched: false };
      }
      const mapping: ManualHumanoidMapping | null = deserializeManualMapping(json);
      if (mapping === null) {
        Logger.warn(LOG_TAG, 'load failed: deserialize returned null');
        return { mapping: null, sourceSha256Matched: false, skeletonHashMatched: false };
      }
      // 检查 sourceSha256
      const shaMatched: boolean = expectedSourceSha256.length === 0
        || mapping.sourceSha256 === expectedSourceSha256;
      // skeletonHash 由调用方与当前模型实际 hash 比较(本类不持有 glTF 解析能力)
      Logger.info(LOG_TAG, 'load ok: avatarId=' + avatarId.substring(0, 8)
        + ', joints=' + mapping.joints.length
        + ', shaMatched=' + shaMatched);
      return {
        mapping: mapping,
        sourceSha256Matched: shaMatched,
        skeletonHashMatched: true // 由调用方进一步验证
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'load failed: ' + (e as Error)?.message);
      return { mapping: null, sourceSha256Matched: false, skeletonHashMatched: false };
    }
  }

  /**
   * 删除手动映射(按 avatarId)。
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
   * 检查手动映射是否存在(按 avatarId)。
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
   * T-4.2B: 按 modelId 加载旧缓存(迁移用)。
   *
   * 读取旧 key(character_3d_manual_mapping_<modelId>)下的映射。
   * 用于首次从 modelId 缓存迁移到 avatarId 缓存。
   *
   * @param modelId 旧 modelId(= displayName)
   * @param expectedSourceSha256 期望的 sourceSha256
   * @returns 旧映射加载结果;无旧缓存时 mapping 为 null
   */
  async loadLegacyByModelId(
    modelId: string,
    expectedSourceSha256: string
  ): Promise<HumanoidMappingLoadResult> {
    if (modelId.length === 0) {
      return { mapping: null, sourceSha256Matched: false, skeletonHashMatched: false };
    }
    try {
      const key: string = this.buildLegacyKey(modelId);
      const json: string = await this.preferences.getString(key, '');
      if (json.length === 0) {
        return { mapping: null, sourceSha256Matched: false, skeletonHashMatched: false };
      }
      const mapping: ManualHumanoidMapping | null = deserializeManualMapping(json);
      if (mapping === null) {
        return { mapping: null, sourceSha256Matched: false, skeletonHashMatched: false };
      }
      const shaMatched: boolean = expectedSourceSha256.length === 0
        || mapping.sourceSha256 === expectedSourceSha256;
      Logger.info(LOG_TAG, 'loadLegacyByModelId: modelId=' + modelId
        + ', joints=' + mapping.joints.length
        + ', shaMatched=' + shaMatched);
      return {
        mapping: mapping,
        sourceSha256Matched: shaMatched,
        skeletonHashMatched: true
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadLegacyByModelId failed: ' + (e as Error)?.message);
      return { mapping: null, sourceSha256Matched: false, skeletonHashMatched: false };
    }
  }

  /**
   * T-4.2B: 删除旧缓存(按 modelId)。
   *
   * 迁移成功后调用,清理旧 key。
   *
   * @param modelId 旧 modelId(= displayName)
   */
  async deleteLegacyByModelId(modelId: string): Promise<void> {
    if (modelId.length === 0) {
      return;
    }
    try {
      const key: string = this.buildLegacyKey(modelId);
      await this.preferences.delete(key);
      Logger.info(LOG_TAG, 'deleteLegacyByModelId ok: modelId=' + modelId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'deleteLegacyByModelId failed: ' + (e as Error)?.message);
    }
  }
}

/**
 * 加载结果。
 */
export interface HumanoidMappingLoadResult {
  /** 加载到的映射(失败为 null) */
  mapping: ManualHumanoidMapping | null;
  /** sourceSha256 是否匹配(模型文件内容是否一致) */
  sourceSha256Matched: boolean;
  /** skeletonHash 是否匹配(骨架结构是否一致,由调用方进一步验证) */
  skeletonHashMatched: boolean;
}
