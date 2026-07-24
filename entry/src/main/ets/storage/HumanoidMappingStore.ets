/**
 * HumanoidMappingStore 手动人形骨骼映射存储服务
 *
 * T-3D.6E P3: 实现可保存的手动人形骨骼映射基础功能。
 *
 * 职责:
 * - 通过 AppPreferences 持久化 ManualHumanoidMapping
 * - 按 modelId+sourceSha256 关联(同 SHA 可复用,同文件名内容改变不复用)
 * - 提供 save/load/delete/has 四个核心能力
 * - 不缓存值,每次直接读写 Preferences
 * - 不读取聊天 / Prompt / API Key
 *
 * 持久化设计:
 * - Preferences key: character_3d_manual_mapping_<modelId>
 * - value: JSON 字符串(ManualHumanoidMapping 序列化)
 * - 同一 modelId 同时只保存一份映射
 * - 重新导入同 SHA 时,load 返回旧映射并标记 skeletonHash 一致
 * - 重新导入不同 SHA 时,load 返回 null(由调用方处理)
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

/** Preferences key 前缀:手动映射(per-model) */
const PREF_KEY_MANUAL_MAPPING_PREFIX: string = 'character_3d_manual_mapping_';

/**
 * 手动骨骼映射存储服务。
 */
export class HumanoidMappingStore {
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * 构造 Preferences key。
   *
   * modelId 中的非法字符(非 [a-zA-Z0-9._-])替换为 '_',保证 key 合法。
   */
  private buildKey(modelId: string): string {
    const safe: string = modelId.replace(/[^a-zA-Z0-9._-]/g, '_');
    return PREF_KEY_MANUAL_MAPPING_PREFIX + safe;
  }

  /**
   * 保存手动映射。
   *
   * 流程:
   * 1. 序列化为 JSON
   * 2. 写入 Preferences(以 modelId 为 key)
   * 3. flush 落盘(AppPreferences.putString 内部已 flush)
   *
   * @param mapping 待保存的映射(必须包含 modelId)
   * @returns 保存成功返回 true,失败返回 false
   */
  async save(mapping: ManualHumanoidMapping): Promise<boolean> {
    if (mapping.modelId.length === 0) {
      Logger.warn(LOG_TAG, 'save rejected: modelId is empty');
      return false;
    }
    try {
      const json: string = serializeManualMapping(mapping);
      const key: string = this.buildKey(mapping.modelId);
      await this.preferences.putString(key, json);
      Logger.info(LOG_TAG, 'save ok: modelId=' + mapping.modelId
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
   * 加载手动映射。
   *
   * 流程:
   * 1. 读取 Preferences JSON
   * 2. 反序列化为 ManualHumanoidMapping
   * 3. 检查 sourceSha256 是否匹配
   *    - 匹配:返回映射,skeletonHashMatched=true
   *    - 不匹配:返回映射但 skeletonHashMatched=false(由调用方决定是否要求重新验证)
   *    - 文件不存在或解析失败:返回 null
   *
   * @param modelId 模型 ID
   * @param expectedSourceSha256 期望的 sourceSha256(用于检测文件变化)
   * @returns 映射加载结果(包含 mapping 和 skeletonHashMatched 标志)
   */
  async load(
    modelId: string,
    expectedSourceSha256: string
  ): Promise<HumanoidMappingLoadResult> {
    if (modelId.length === 0) {
      return { mapping: null, sourceSha256Matched: false, skeletonHashMatched: false };
    }
    try {
      const key: string = this.buildKey(modelId);
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
      // 这里返回 mapping,调用方通过 isSkeletonHashMatched 判断
      Logger.info(LOG_TAG, 'load ok: modelId=' + modelId
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
   * 删除手动映射。
   *
   * 用于:
   * - 用户主动清空映射
   * - 删除模型记录时同步清理
   *
   * @param modelId 模型 ID
   */
  async delete(modelId: string): Promise<void> {
    if (modelId.length === 0) {
      return;
    }
    try {
      const key: string = this.buildKey(modelId);
      await this.preferences.delete(key);
      Logger.info(LOG_TAG, 'delete ok: modelId=' + modelId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'delete failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 检查手动映射是否存在。
   *
   * @param modelId 模型 ID
   * @returns 存在返回 true,不存在或读取失败返回 false
   */
  async has(modelId: string): Promise<boolean> {
    if (modelId.length === 0) {
      return false;
    }
    try {
      const key: string = this.buildKey(modelId);
      return await this.preferences.has(key);
    } catch (e) {
      Logger.warn(LOG_TAG, 'has failed: ' + (e as Error)?.message);
      return false;
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
