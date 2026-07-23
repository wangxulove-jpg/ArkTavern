/**
 * Character3DActionManagerViewModel 3D 动作管理视图模型
 *
 * T-3D.6C: 三列卡片式动作管理页面的业务逻辑层。
 *
 * 职责:
 * - 加载所有动作(内置 + 用户导入)
 * - 合并用户别名和隐藏状态
 * - 筛选和搜索
 * - 重命名(内置动作别名 / 导入动作 displayName)
 * - 隐藏/恢复内置动作
 * - 删除导入动作(解除绑定 + 清理文件)
 * - 模型兼容性检查
 *
 * 不直接操作 UI 状态,不引用具体页面类。
 */

import { Character3DActionService, ActionAssetListItem } from '../services/Character3DActionService';
import { Character3DService, Character3DModelConfig } from '../services/Character3DService';
import { ActionDisplayPreferenceStore, AliasEntry } from '../services/ActionDisplayPreferenceStore';
import { ActionPlaybackPreferenceStore } from '../services/ActionPlaybackPreferenceStore';
import {
  Character3DActionAsset,
  Character3DActionBinding,
  ActionLoopMode,
  resolveLoop,
  loopModeToLabel
} from '../models/character3d/Character3DActionAsset';
import {
  Character3DActionSlot,
  ActionSlotInfo,
  getAllSlotInfos
} from '../models/character3d/Character3DActionSlot';
import {
  ActionSourceKind,
  ActionCategory,
  ActionFilter
} from '../models/character3d/UnifiedActionItem';
import {
  SkeletonProfile,
  CompatibilityLevel
} from '../models/character3d/HumanoidBone';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'Char3DActionMgrVM';

/**
 * 卡片展示用动作项(合并了别名和隐藏状态)。
 */
export interface ActionCardItem {
  /** 稳定 ID */
  id: string;
  /** 显示名(优先:别名 > 默认名 > Clip 名) */
  displayName: string;
  /** 默认显示名(重命名前的原始名) */
  defaultDisplayName: string;
  /** Clip 名称 */
  clipName: string;
  /** Clip 索引 */
  clipIndex: number;
  /** 来源类型 */
  sourceKind: ActionSourceKind;
  /** 时长(毫秒) */
  durationMs: number;
  /** 是否循环(资产默认值,来自 manifest) */
  loop: boolean;
  /** T-3D.6C-C: 用户循环模式偏好(UseDefault=跟随默认,Loop=强制循环,PlayOnce=强制单次) */
  loopMode: ActionLoopMode;
  /** 分类 */
  category: ActionCategory;
  /** 排序序号 */
  sortOrder: number;
  /** 是否隐藏 */
  hidden: boolean;
  /** 是否已绑定到槽位 */
  boundSlot: Character3DActionSlot | null;
  /** 骨骼 Profile */
  skeletonProfile: SkeletonProfile;
  /** 兼容等级 */
  compatibilityLevel: CompatibilityLevel;
  /** 文件是否存在 */
  fileExists: boolean;
  /** 是否内置 */
  isBuiltIn: boolean;
  /** 原始资产 */
  asset: Character3DActionAsset;
}

/**
 * 当前模型信息摘要。
 */
export interface ModelSummary {
  /** 是否有模型 */
  hasModel: boolean;
  /** 模型名 */
  displayName: string;
  /** 模型 URI */
  modelUri: string;
  /** 文件是否存在 */
  fileExists: boolean;
  /** 动画数量 */
  animationCount: number;
  /** 骨骼节点数 */
  nodeCount: number;
  /** 骨骼 Profile */
  skeletonProfile: SkeletonProfile;
  /** 兼容等级 */
  compatibilityLevel: CompatibilityLevel;
  /** 是否兼容内置动作(Direct) */
  builtinActionCompatible: boolean;
}

export class Character3DActionManagerViewModel {
  private actionService: Character3DActionService;
  private model3DService: Character3DService;
  private displayPrefStore: ActionDisplayPreferenceStore;
  private playbackPrefStore: ActionPlaybackPreferenceStore;

  constructor(
    actionService: Character3DActionService,
    model3DService: Character3DService
  ) {
    this.actionService = actionService;
    this.model3DService = model3DService;
    this.displayPrefStore = actionService.getDisplayPreferenceStore();
    this.playbackPrefStore = actionService.getPlaybackPreferenceStore();
  }

  /**
   * 加载所有动作卡片数据(内置 + 导入,合并别名和隐藏状态)。
   *
   * @param modelId 当前模型 ID(用于查询绑定状态)
   * @param includeHidden 是否包含隐藏动作
   */
  async loadAllActionCards(
    modelId: string,
    includeHidden: boolean
  ): Promise<ActionCardItem[]> {
    // 1. 加载所有动作资产
    const allAssets: ActionAssetListItem[] = await this.actionService.listAllActionAssets();
    // 2. 加载别名映射
    const aliasEntries: AliasEntry[] = await this.displayPrefStore.getAllAliases();
    // 3. 加载隐藏集合
    const hiddenIds: Set<string> = await this.displayPrefStore.getHiddenIds();
    // 4. 加载当前模型的绑定
    const bindings: Character3DActionBinding[] = await this.actionService.getBindings(modelId);
    const boundActionIds: Set<string> = new Set();
    for (let i: number = 0; i < bindings.length; i++) {
      if (bindings[i].actionAssetId.length > 0) {
        boundActionIds.add(bindings[i].actionAssetId);
      }
    }
    // 5. 合并为卡片数据
    const cards: ActionCardItem[] = [];
    for (let i: number = 0; i < allAssets.length; i++) {
      const item: ActionAssetListItem = allAssets[i];
      const asset: Character3DActionAsset = item.asset;
      const isBuiltIn: boolean = asset.isBuiltIn;
      const hidden: boolean = hiddenIds.has(asset.id);
      // 隐藏动作过滤
      if (hidden && !includeHidden) {
        continue;
      }
      // 显示名:别名 > 默认名 > Clip 名(遍历别名列表查找)
      let alias: string = '';
      for (let j: number = 0; j < aliasEntries.length; j++) {
        if (aliasEntries[j].id === asset.id) {
          alias = aliasEntries[j].alias;
          break;
        }
      }
      const displayName: string = alias.length > 0 ? alias : asset.displayName;
      // 来源类型
      const sourceKind: ActionSourceKind = isBuiltIn
        ? ActionSourceKind.BuiltIn
        : ActionSourceKind.Imported;
      // 分类(内置动作从 manifest 来,导入动作为 Other)
      const category: ActionCategory = isBuiltIn
        ? this.parseCategoryFromAsset(asset)
        : ActionCategory.Other;
      // 绑定状态
      let boundSlot: Character3DActionSlot | null = null;
      if (boundActionIds.has(asset.id)) {
        for (let j: number = 0; j < bindings.length; j++) {
          if (bindings[j].actionAssetId === asset.id) {
            boundSlot = bindings[j].slot;
            break;
          }
        }
      }
      cards.push({
        id: asset.id,
        displayName: displayName,
        defaultDisplayName: asset.displayName,
        clipName: asset.clipName,
        clipIndex: asset.clipIndex,
        sourceKind: sourceKind,
        durationMs: asset.durationMs,
        loop: asset.loop,
        loopMode: ActionLoopMode.UseDefault,
        category: category,
        sortOrder: isBuiltIn ? asset.clipIndex : 1000 + i,
        hidden: hidden,
        boundSlot: boundSlot,
        skeletonProfile: asset.skeletonProfile,
        compatibilityLevel: asset.compatibilityLevel,
        fileExists: item.fileExists,
        isBuiltIn: isBuiltIn,
        asset: asset
      } as ActionCardItem);
    }
    // 6. T-3D.6C-C: 批量读取循环模式偏好(per-model + global)
    for (let i: number = 0; i < cards.length; i++) {
      const card: ActionCardItem = cards[i];
      const mode: ActionLoopMode = await this.playbackPrefStore.resolveEffectiveLoopMode(modelId, card.id);
      card.loopMode = mode;
    }
    // 7. 排序:内置动作按 sortOrder,导入动作在后
    cards.sort((a: ActionCardItem, b: ActionCardItem): number => {
      return a.sortOrder - b.sortOrder;
    });
    return cards;
  }

  /**
   * T-3D.6C-C: 解析动作的最终循环布尔值(供预览/播放使用)。
   *
   * 优先级:per-model binding loopMode → global action loopMode → asset.loop
   */
  getEffectiveLoop(card: ActionCardItem): boolean {
    return resolveLoop(card.loopMode, card.loop);
  }

  /**
   * T-3D.6C-C: 设置动作循环模式。
   *
   * modelId 非空时设置 per-model 偏好,否则设置全局偏好。
   */
  async setLoopMode(modelId: string, actionId: string, mode: ActionLoopMode): Promise<boolean> {
    try {
      await this.playbackPrefStore.setLoopMode(modelId, actionId, mode);
      return true;
    } catch (e) {
      Logger.error('Char3DActionMgrVM', 'setLoopMode failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * T-3D.6C-C: 恢复默认循环模式(移除 per-model 和全局偏好)。
   */
  async resetLoopMode(modelId: string, actionId: string): Promise<boolean> {
    try {
      await this.playbackPrefStore.resetLoopMode(modelId, actionId);
      return true;
    } catch (e) {
      Logger.error('Char3DActionMgrVM', 'resetLoopMode failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * T-3D.6C-C: 获取循环模式的显示标签。
   */
  getLoopModeLabel(mode: ActionLoopMode): string {
    return loopModeToLabel(mode);
  }

  /**
   * 从资产解析分类(内置动作的 sourceFileName 包含 pack 名,无法直接分类,
   * 需要从 manifest 的 category 字段推导。这里通过 clipName 前缀推导)。
   */
  private parseCategoryFromAsset(asset: Character3DActionAsset): ActionCategory {
    // 内置动作的分类在 manifest 中定义,但 Character3DActionAsset 不保存 category
    // 通过 clipName 推导:AT_Idle/AT_Listening/AT_Thinking/AT_Speaking → base
    // AT_Greeting/AT_Wave/AT_Nod/AT_ShakeHead/AT_Apology → social
    // AT_Happy/AT_Confused/AT_Sad/AT_Angry → emotion
    // AT_TouchReaction/AT_Celebrate → reaction
    const clipName: string = asset.clipName;
    if (clipName === 'AT_Idle' || clipName === 'AT_Listening'
      || clipName === 'AT_Thinking' || clipName === 'AT_Speaking') {
      return ActionCategory.Base;
    }
    if (clipName === 'AT_Greeting' || clipName === 'AT_Wave'
      || clipName === 'AT_Nod' || clipName === 'AT_ShakeHead'
      || clipName === 'AT_Apology') {
      return ActionCategory.Social;
    }
    if (clipName === 'AT_Happy' || clipName === 'AT_Confused'
      || clipName === 'AT_Sad' || clipName === 'AT_Angry') {
      return ActionCategory.Emotion;
    }
    if (clipName === 'AT_TouchReaction' || clipName === 'AT_Celebrate') {
      return ActionCategory.Reaction;
    }
    return ActionCategory.Other;
  }

  /**
   * 筛选动作卡片。
   *
   * @param cards 所有卡片
   * @param filter 筛选条件
   * @param keyword 搜索关键词(空字符串表示不搜索)
   */
  filterActionCards(
    cards: ActionCardItem[],
    filter: ActionFilter,
    keyword: string
  ): ActionCardItem[] {
    const trimmedKeyword: string = keyword.trim().toLowerCase();
    const result: ActionCardItem[] = [];
    for (let i: number = 0; i < cards.length; i++) {
      const card: ActionCardItem = cards[i];
      // 筛选条件
      if (filter === ActionFilter.BuiltIn && !card.isBuiltIn) {
        continue;
      }
      if (filter === ActionFilter.Imported && card.isBuiltIn) {
        continue;
      }
      if (filter === ActionFilter.Loop && !card.loop) {
        continue;
      }
      if (filter === ActionFilter.Once && card.loop) {
        continue;
      }
      // 搜索关键词
      if (trimmedKeyword.length > 0) {
        const name: string = card.displayName.toLowerCase();
        const clipName: string = card.clipName.toLowerCase();
        if (!name.includes(trimmedKeyword) && !clipName.includes(trimmedKeyword)) {
          continue;
        }
      }
      result.push(card);
    }
    return result;
  }

  /**
   * 加载当前模型摘要。
   */
  async loadModelSummary(): Promise<ModelSummary> {
    const config: Character3DModelConfig = await this.model3DService.getConfig();
    if (config.modelUri.length === 0 || !config.fileExists) {
      return {
        hasModel: false,
        displayName: config.displayName,
        modelUri: config.modelUri,
        fileExists: config.fileExists,
        animationCount: 0,
        nodeCount: 0,
        skeletonProfile: SkeletonProfile.Unknown,
        compatibilityLevel: CompatibilityLevel.Unsupported,
        builtinActionCompatible: false
      } as ModelSummary;
    }
    // 解析模型信息
    let animationCount: number = 0;
    let nodeCount: number = 0;
    let hasSkins: boolean = false;
    try {
      const info = await this.model3DService.getModelInfoByUri(config.modelUri);
      if (info !== null) {
        animationCount = info.animationCount;
        nodeCount = info.nodeCount;
        hasSkins = info.hasSkins;
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadModelSummary getModelInfo failed: ' + (e as Error)?.message);
    }
    // 当前无法从 GltfModelInfo 精确推导骨骼 Profile,
    // 暂时将内置动作兼容性设为 false(仅 ArkTavernHumanoidV1 骨骼模型可应用)
    // 后续 T-3D.6D 实现骨骼识别后再启用
    const skeletonProfile: SkeletonProfile = SkeletonProfile.Unknown;
    const compatibilityLevel: CompatibilityLevel = hasSkins
      ? CompatibilityLevel.PartialHumanoid
      : CompatibilityLevel.Unsupported;
    const builtinActionCompatible: boolean = false;
    return {
      hasModel: true,
      displayName: config.displayName,
      modelUri: config.modelUri,
      fileExists: config.fileExists,
      animationCount: animationCount,
      nodeCount: nodeCount,
      skeletonProfile: skeletonProfile,
      compatibilityLevel: compatibilityLevel,
      builtinActionCompatible: builtinActionCompatible
    } as ModelSummary;
  }

  /**
   * 重命名动作(内置动作保存别名,导入动作修改 displayName)。
   *
   * @param actionId 动作 ID
   * @param newName 新名称
   * @returns 是否成功
   */
  async renameAction(actionId: string, newName: string): Promise<boolean> {
    const trimmed: string = newName.trim();
    if (trimmed.length === 0 || trimmed.length > 30) {
      return false;
    }
    try {
      if (this.actionService.isBuiltInActionId(actionId)) {
        // 内置动作:保存别名
        await this.displayPrefStore.setAlias(actionId, trimmed);
      } else {
        // 导入动作:修改 displayName
        await this.actionService.updateActionAsset(actionId, { displayName: trimmed });
      }
      Logger.info(LOG_TAG, 'renameAction ok: id=' + actionId + ', name=' + trimmed);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'renameAction failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 恢复内置动作默认名称(删除别名)。
   */
  async resetBuiltinActionName(actionId: string): Promise<boolean> {
    try {
      await this.displayPrefStore.removeAlias(actionId);
      Logger.info(LOG_TAG, 'resetBuiltinActionName ok: id=' + actionId);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'resetBuiltinActionName failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 设置内置动作隐藏状态。
   */
  async setBuiltinActionHidden(actionId: string, hidden: boolean): Promise<boolean> {
    try {
      await this.displayPrefStore.setHidden(actionId, hidden);
      Logger.info(LOG_TAG, 'setBuiltinActionHidden ok: id=' + actionId + ', hidden=' + hidden);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'setBuiltinActionHidden failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 删除导入动作(解除绑定 + 清理文件 + 删除 Preferences)。
   *
   * 内置动作不可删除,会返回 false。
   */
  async deleteImportedAction(actionId: string, modelId: string): Promise<boolean> {
    if (this.actionService.isBuiltInActionId(actionId)) {
      Logger.warn(LOG_TAG, 'deleteImportedAction rejected: builtin action, id=' + actionId);
      return false;
    }
    try {
      await this.actionService.deleteActionAsset(actionId);
      Logger.info(LOG_TAG, 'deleteImportedAction ok: id=' + actionId);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'deleteImportedAction failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 绑定动作到槽位。
   */
  async bindActionToSlot(
    actionId: string,
    slot: Character3DActionSlot,
    modelId: string
  ): Promise<boolean> {
    try {
      const asset: Character3DActionAsset | null =
        await this.actionService.getActionAsset(actionId);
      if (asset === null && this.actionService.isBuiltInActionId(actionId)) {
        // 内置动作
        const builtinAsset: Character3DActionAsset | null =
          await this.actionService.getBuiltInActionAsset(actionId);
        if (builtinAsset === null) {
          return false;
        }
        const binding: Character3DActionBinding = {
          modelId: modelId,
          slot: slot,
          actionAssetId: actionId,
          clipName: builtinAsset.clipName,
          clipIndex: builtinAsset.clipIndex,
          loop: builtinAsset.loop,
          speed: 1.0,
          updatedAt: Date.now()
        };
        await this.actionService.saveBinding(binding);
        return true;
      }
      if (asset === null) {
        return false;
      }
      const binding: Character3DActionBinding = {
        modelId: modelId,
        slot: slot,
        actionAssetId: actionId,
        clipName: asset.clipName,
        clipIndex: asset.clipIndex,
        loop: asset.loop,
        speed: 1.0,
        updatedAt: Date.now()
      };
      await this.actionService.saveBinding(binding);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'bindActionToSlot failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * 确保内置动作 GLB 包已缓存到沙盒(用于预览播放)。
   *
   * @returns 沙盒内 GLB 文件的 file:// URI
   */
  async ensureBuiltinPackReady(): Promise<string> {
    const sandboxPath: string = await this.actionService.ensureBuiltInPackCached();
    return 'file://' + sandboxPath;
  }

  /**
   * 获取所有标准槽位信息。
   */
  getAllSlotInfos(): ActionSlotInfo[] {
    return getAllSlotInfos();
  }

  /**
   * 清除内置动作所有偏好(恢复默认)。
   */
  async clearAllBuiltinPreferences(): Promise<boolean> {
    try {
      await this.actionService.clearBuiltInPreferences();
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'clearAllBuiltinPreferences failed: ' + (e as Error)?.message);
      return false;
    }
  }
}
