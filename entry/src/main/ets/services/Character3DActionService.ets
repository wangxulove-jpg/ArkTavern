/**
 * Character3DActionService 3D 动作业务服务
 *
 * T-3D.6A: 独立于模型的动作资产管理与绑定。
 *
 * 职责:
 * - 动作文件存储(应用私有目录 files/character_actions/{actionId}/)
 * - 动作资产元数据持久化(Preferences 存 JSON,不存二进制)
 * - 动作导入流程(文件验证 → 解析 → 骨骼识别 → 兼容性检查 → 保存)
 * - 动作绑定管理(per-model + global default)
 * - 动作资产 CRUD
 * - 不直接操作 Scene(由 AnimationController 调用 Scene.load)
 * - 不读取聊天正文 / Prompt / API Key
 *
 * 持久化设计:
 * - 文件:files/character_actions/{actionId}/action.glb + metadata.json
 * - Preferences key:character_3d_action_assets_index(JSON array of assetIds)
 * - Preferences key:character_3d_action_asset_<id>(JSON of Character3DActionAsset)
 * - Preferences key:character_3d_action_bindings_<modelId>(JSON array of bindings)
 * - Preferences key:character_3d_action_bindings_global(JSON array of global bindings)
 *
 * 三种动作复用策略(对应任务规格第六章):
 * - 策略一(模型内置动画):完全支持,通过 EmbeddedGlb + ActionCompatibility.EmbeddedOnly 标记
 * - 策略二(同骨骼复用):SDK 不支持跨模型应用动画,标记为 MetadataOnly
 * - 策略三(Humanoid 重定向):SDK 不支持运行时重定向,标记为 MetadataOnly
 *
 * 第一版实际运行时只支持:
 * - 模型内置动画(通过 Scene.animations[index] 播放)
 * - 外部动作文件的元数据保存和预览(实际播放由 AnimationController 决定)
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import http from '@ohos.net.http';
import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import { GltfValidator, GltfValidationResult } from '../parser/GltfValidator';
import { GltfAnimationParser, GltfAnimationParseResult } from '../parser/GltfAnimationParser';
import {
  Character3DActionAsset,
  Character3DActionBinding,
  AnimationClipInfo,
  generateActionId,
  createDefaultActionAsset,
  sanitizeSpeed,
  serializeActionAsset,
  deserializeActionAsset,
  serializeActionBinding,
  deserializeActionBinding,
  ACTION_FILE_MAX_SIZE_BYTES,
  ACTION_MAX_CLIP_COUNT,
  ACTION_MAX_CHANNEL_COUNT,
  ACTION_MAX_DURATION_MS,
  ACTION_SPEED_DEFAULT
} from '../models/character3d/Character3DActionAsset';
import {
  ActionSourceFormat,
  ActionCompatibility,
  SkeletonProfile,
  CompatibilityLevel
} from '../models/character3d/HumanoidBone';
import { mapBones, checkBoneCompatibility } from '../models/character3d/HumanoidBoneMapper';
import { Character3DActionSlot, parseActionSlot } from '../models/character3d/Character3DActionSlot';
import {
  BuiltInActionManifest,
  BuiltInActionEntry,
  parseBuiltInManifest,
  BUILTIN_ACTION_RAWFILE_DIR,
  BUILTIN_MANIFEST_FILE_NAME,
  BUILTIN_PACK_FILE_NAME,
  BUILTIN_PREVIEW_FILE_NAME
} from '../models/character3d/BuiltInActionManifest';
import { ActionDisplayPreferenceStore } from './ActionDisplayPreferenceStore';
import { ActionPlaybackPreferenceStore } from './ActionPlaybackPreferenceStore';

const LOG_TAG: string = 'Character3DActionService';

const ACTION_DIR: string = 'character_actions';
const ACTION_FILE_NAME: string = 'action.glb';
const METADATA_FILE_NAME: string = 'metadata.json';
const SOURCE_VRMA_NAME: string = 'optional_source.vrma';

const PREF_KEY_ASSETS_INDEX: string = 'character_3d_action_assets_index';
const PREF_KEY_ASSET_PREFIX: string = 'character_3d_action_asset_';
const PREF_KEY_BINDINGS_PREFIX: string = 'character_3d_action_bindings_';
const PREF_KEY_GLOBAL_BINDINGS: string = 'character_3d_action_bindings_global';

// T-3D.6C: 内置动作专用 Preferences key(与用户导入动作分离)
const PREF_KEY_BUILTIN_INDEX: string = 'character_3d_builtin_action_index';
const PREF_KEY_BUILTIN_ASSET_PREFIX: string = 'character_3d_builtin_action_asset_';
// 内置动作 GLB 包在沙盒中的共享目录(所有内置动作共享一个 GLB 文件)
const BUILTIN_PACK_SANDBOX_DIR: string = 'character_actions/builtin_pack';
const BUILTIN_PACK_SANDBOX_RELATIVE_PATH: string = BUILTIN_PACK_SANDBOX_DIR + '/' + BUILTIN_PACK_FILE_NAME;

/**
 * 动作导入请求(用户选择文件后传入)。
 */
export interface ActionImportRequest {
  /** 源文件 URI(DocumentViewPicker 返回) */
  sourceUri: string;
  /** 源文件名(用于显示和格式识别) */
  sourceFileName: string;
}

/**
 * 动作导入预处理结果(选择 Clip 前的预览信息)。
 */
export interface ActionImportPreview {
  /** 是否可导入 */
  canImport: boolean;
  /** 错误信息(不可导入时) */
  errorMessage: string;
  /** 源文件名 */
  sourceFileName: string;
  /** 来源格式 */
  sourceFormat: ActionSourceFormat;
  /** 所有 Clip 列表 */
  clips: AnimationClipInfo[];
  /** 所有节点名列表 */
  nodeNames: string[];
  /** 是否包含骨骼蒙皮 */
  hasSkins: boolean;
  /** 识别到的骨骼 Profile */
  skeletonProfile: SkeletonProfile;
  /** 兼容等级 */
  compatibilityLevel: CompatibilityLevel;
  /** 缺失的必需骨骼名列表 */
  missingRequiredBones: string[];
  /** 临时文件路径(已复制到临时目录,等待用户确认后移动到正式目录) */
  tempFilePath: string;
}

/**
 * 动作导入确认请求(用户选择 Clip 后传入)。
 */
export interface ActionImportConfirm {
  /** 导入预览(来自 importActionPreview) */
  preview: ActionImportPreview;
  /** 用户选择的 Clip 索引 */
  selectedClipIndex: number;
  /** 用户选择的动作槽位 */
  targetSlot: Character3DActionSlot;
  /** 是否循环播放 */
  loop: boolean;
  /** 播放速度 */
  speed: number;
  /** 显示名(用户可编辑) */
  displayName: string;
}

/**
 * 动作资产列表条目(用于 UI 显示)。
 */
export interface ActionAssetListItem {
  /** 动作资产 */
  asset: Character3DActionAsset;
  /** 文件是否存在 */
  fileExists: boolean;
}

/**
 * 临时文件复制结果(临时路径 + 文件 buffer)。
 */
interface TempCopyResult {
  path: string;
  buffer: ArrayBuffer;
}

/**
 * 动作资产可更新字段(部分字段可选)。
 */
export interface ActionAssetUpdates {
  displayName?: string;
  speed?: number;
  loop?: boolean;
  enabled?: boolean;
}

/**
 * 动作与模型兼容性摘要。
 */
interface ActionModelCompatibility {
  direct: boolean;
  mapped: boolean;
  commonCount: number;
}

export class Character3DActionService {
  private readonly preferences: AppPreferences;
  private readonly appContext: common.Context;
  private readonly baseDir: string;
  private initialized: boolean = false;
  // T-3D.6C: 内置动作显示偏好存储(别名/隐藏)
  private displayPrefStore: ActionDisplayPreferenceStore;
  // T-3D.6C-C: 动作播放偏好存储(循环模式覆盖)
  private playbackPrefStore: ActionPlaybackPreferenceStore;
  // T-3D.6C: 内置动作清单缓存(避免重复读取 rawfile)
  private builtinManifestCache: BuiltInActionManifest | null = null;
  // T-3D.6C: 内置动作资产缓存(避免每次都读 Preferences)
  private builtinAssetsCache: Character3DActionAsset[] | null = null;
  // T-3D.6C: 内置动作包是否已缓存到沙盒
  private builtinPackCached: boolean = false;

  constructor(context: common.Context, preferences: AppPreferences) {
    this.appContext = context;
    this.preferences = preferences;
    this.baseDir = context.filesDir + '/' + ACTION_DIR;
    this.displayPrefStore = new ActionDisplayPreferenceStore(preferences);
    this.playbackPrefStore = new ActionPlaybackPreferenceStore(preferences);
  }

  /**
   * 初始化,创建动作目录。
   *
   * T-3D.6C: 同时触发内置动作注册(异步,不阻塞初始化)。
   */
  initialize(): void {
    try {
      if (!fileIo.accessSync(this.baseDir)) {
        fileIo.mkdirSync(this.baseDir, true);
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'initialize mkdir failed: ' + String(e));
    }
    this.initialized = true;
    // T-3D.6B: 开发阶段定位应用沙盒路径(发布前移除)
    Logger.info(LOG_TAG, 'init ok: filesDir=' + this.appContext.filesDir);
    // T-3D.6C: 异步注册内置动作(不阻塞初始化,失败不影响应用启动)
    this.registerBuiltInAssets().catch((e: Error): void => {
      Logger.error(LOG_TAG, 'registerBuiltInAssets failed: ' + e.message);
    });
  }

  /**
   * T-3D.6C: 获取动作显示偏好存储(供 ViewModel 调用)。
   */
  getDisplayPreferenceStore(): ActionDisplayPreferenceStore {
    return this.displayPrefStore;
  }

  /**
   * T-3D.6C-C: 获取动作播放偏好存储(循环模式覆盖,供 ViewModel 调用)。
   */
  getPlaybackPreferenceStore(): ActionPlaybackPreferenceStore {
    return this.playbackPrefStore;
  }

  /**
   * T-3D.6C: 注册内置动作资产(从 rawfile 读取 manifest)。
   *
   * 流程:
   * 1. 读取 rawfile/actions/default_ai/default_ai_action_pack.json
   * 2. 解析为 BuiltInActionManifest
   * 3. 为每个动作创建 Character3DActionAsset(isBuiltIn=true,稳定 ID)
   * 4. 持久化到内置动作专用 Preferences key
   * 5. 缓存到内存
   *
   * 即使 Preferences 被清空,本方法也能从 rawfile 重建内置动作。
   */
  async registerBuiltInAssets(): Promise<void> {
    try {
      // 1. 读取 rawfile manifest
      const manifest: BuiltInActionManifest | null = await this.loadBuiltInManifest();
      if (manifest === null) {
        Logger.error(LOG_TAG, 'registerBuiltInAssets: manifest is null, abort');
        return;
      }
      this.builtinManifestCache = manifest;
      Logger.info(LOG_TAG, 'registerBuiltInAssets: manifest loaded, actions=' + manifest.actions.length);

      // 2. 为每个动作创建资产对象
      const assets: Character3DActionAsset[] = [];
      const profile: SkeletonProfile = this.parseSkeletonProfileString(manifest.skeletonProfile);
      for (let i: number = 0; i < manifest.actions.length; i++) {
        const entry: BuiltInActionEntry = manifest.actions[i];
        const asset: Character3DActionAsset = this.createBuiltInAssetFromEntry(entry, i, profile);
        assets.push(asset);
      }

      // 3. 持久化到 Preferences(每次启动都覆盖,确保与 rawfile 一致)
      await this.saveBuiltInAssets(assets);

      // 4. 缓存到内存
      this.builtinAssetsCache = assets;
      Logger.info(LOG_TAG, 'registerBuiltInAssets: ok, count=' + assets.length);
    } catch (e) {
      Logger.error(LOG_TAG, 'registerBuiltInAssets exception: ' + (e as Error)?.message);
    }
  }

  /**
   * T-3D.6C: 从 rawfile 读取内置动作清单。
   * 读取结果会被缓存,避免重复 IO。
   */
  async loadBuiltInManifest(): Promise<BuiltInActionManifest | null> {
    if (this.builtinManifestCache !== null) {
      return this.builtinManifestCache;
    }
    try {
      const manifestPath: string = BUILTIN_ACTION_RAWFILE_DIR + '/' + BUILTIN_MANIFEST_FILE_NAME;
      const data: Uint8Array = await this.appContext.resourceManager.getRawFileContent(manifestPath);
      const ab: ArrayBuffer = new ArrayBuffer(data.byteLength);
      const view: Uint8Array = new Uint8Array(ab);
      view.set(data);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const json: string = decoder.decodeToString(view);
      const manifest: BuiltInActionManifest | null = parseBuiltInManifest(json);
      if (manifest === null) {
        Logger.error(LOG_TAG, 'loadBuiltInManifest: parse failed');
        return null;
      }
      this.builtinManifestCache = manifest;
      return manifest;
    } catch (e) {
      Logger.error(LOG_TAG, 'loadBuiltInManifest failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * T-3D.6C: 根据 manifest 条目创建内置动作资产。
   *
   * 内置动作的 stableId 来自 manifest(如 builtin_idle)。
   * 所有内置动作共享同一个 GLB 文件,通过 clipIndex 区分。
   */
  private createBuiltInAssetFromEntry(entry: BuiltInActionEntry, clipIndex: number, profile: SkeletonProfile): Character3DActionAsset {
    const now: number = Date.now();
    const parsedSlot: Character3DActionSlot | null = parseActionSlot(entry.slot);
    const slotEnum: Character3DActionSlot = parsedSlot !== null ? parsedSlot : Character3DActionSlot.Custom01;
    return {
      id: entry.id,
      displayName: entry.defaultDisplayName,
      sourceFileName: BUILTIN_PACK_FILE_NAME,
      internalRelativePath: BUILTIN_PACK_SANDBOX_RELATIVE_PATH,
      sourceFormat: ActionSourceFormat.EmbeddedGlb,
      clipName: entry.clipName,
      clipIndex: clipIndex,
      slot: String(slotEnum),
      durationMs: entry.durationMs,
      loop: entry.loop,
      speed: ACTION_SPEED_DEFAULT,
      skeletonProfile: profile,
      compatibilityLevel: CompatibilityLevel.FullHumanoid,
      actionCompatibility: ActionCompatibility.Direct,
      boneMappingProfileId: '',
      allClips: [],
      createdAt: now,
      updatedAt: now,
      isBuiltIn: true,
      enabled: true
    } as Character3DActionAsset;
  }

  /**
   * T-3D.6C: 解析骨骼 Profile 字符串。
   */
  private parseSkeletonProfileString(value: string): SkeletonProfile {
    switch (value) {
      case 'VRM0': return SkeletonProfile.VRM0;
      case 'VRM1': return SkeletonProfile.VRM1;
      case 'Mixamo': return SkeletonProfile.Mixamo;
      case 'ArkTavern': return SkeletonProfile.ArkTavern;
      default: return SkeletonProfile.Unknown;
    }
  }

  /**
   * T-3D.6C: 确保内置动作 GLB 包已缓存到沙盒。
   *
   * 所有内置动作共享一个 GLB 文件,首次使用时从 rawfile 复制到:
   * filesDir/character_actions/builtin_pack/default_ai_action_pack.glb
   *
   * @returns 沙盒内 GLB 文件的绝对路径
   */
  async ensureBuiltInPackCached(): Promise<string> {
    if (this.builtinPackCached) {
      return this.appContext.filesDir + '/' + BUILTIN_PACK_SANDBOX_RELATIVE_PATH;
    }
    const sandboxPath: string = this.appContext.filesDir + '/' + BUILTIN_PACK_SANDBOX_RELATIVE_PATH;
    // 检查文件是否已存在
    let exists: boolean = false;
    try {
      exists = fileIo.accessSync(sandboxPath);
    } catch (_e) {
      exists = false;
    }
    if (!exists) {
      // 从 rawfile 读取并写入沙盒
      try {
        const rawfilePath: string = BUILTIN_ACTION_RAWFILE_DIR + '/' + BUILTIN_PACK_FILE_NAME;
        const data: Uint8Array = await this.appContext.resourceManager.getRawFileContent(rawfilePath);
        const ab: ArrayBuffer = new ArrayBuffer(data.byteLength);
        const view: Uint8Array = new Uint8Array(ab);
        view.set(data);
        // 创建目录
        const dirPath: string = this.appContext.filesDir + '/' + BUILTIN_PACK_SANDBOX_DIR;
        if (!fileIo.accessSync(dirPath)) {
          fileIo.mkdirSync(dirPath, true);
        }
        this.writeBufferToPath(ab, sandboxPath);
        Logger.info(LOG_TAG, 'ensureBuiltInPackCached: copied rawfile to sandbox, size=' + ab.byteLength);
      } catch (e) {
        throw new Error('缓存内置动作包失败: ' + (e as Error)?.message);
      }
    }
    this.builtinPackCached = true;
    return sandboxPath;
  }

  /**
   * T-3D.6C: 保存内置动作资产到 Preferences。
   */
  private async saveBuiltInAssets(assets: Character3DActionAsset[]): Promise<void> {
    const ids: string[] = [];
    for (let i: number = 0; i < assets.length; i++) {
      const id: string = assets[i].id;
      ids.push(id);
      const key: string = PREF_KEY_BUILTIN_ASSET_PREFIX + id;
      await this.preferences.putString(key, serializeActionAsset(assets[i]));
    }
    await this.preferences.putString(PREF_KEY_BUILTIN_INDEX, JSON.stringify(ids));
  }

  /**
   * T-3D.6C: 获取内置动作清单(从 Preferences 读取,失败时从 rawfile 重建)。
   */
  async listBuiltInActionAssets(): Promise<Character3DActionAsset[]> {
    if (this.builtinAssetsCache !== null) {
      return this.builtinAssetsCache;
    }
    try {
      const json: string = await this.preferences.getString(PREF_KEY_BUILTIN_INDEX, '');
      if (json.length === 0) {
        // Preferences 为空,从 rawfile 重建
        await this.registerBuiltInAssets();
        return this.builtinAssetsCache ?? [];
      }
      const obj: Object = JSON.parse(json);
      if (!(obj instanceof Array)) {
        await this.registerBuiltInAssets();
        return this.builtinAssetsCache ?? [];
      }
      const arr: Object[] = obj as Object[];
      const result: Character3DActionAsset[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        const id: string = String(arr[i]);
        const key: string = PREF_KEY_BUILTIN_ASSET_PREFIX + id;
        const assetJson: string = await this.preferences.getString(key, '');
        if (assetJson.length === 0) {
          continue;
        }
        const asset: Character3DActionAsset | null = deserializeActionAsset(assetJson);
        if (asset !== null && asset.isBuiltIn) {
          result.push(asset);
        }
      }
      // 如果 Preferences 中数据不完整,从 rawfile 重建
      if (result.length === 0) {
        await this.registerBuiltInAssets();
        return this.builtinAssetsCache ?? [];
      }
      this.builtinAssetsCache = result;
      return result;
    } catch (e) {
      Logger.warn(LOG_TAG, 'listBuiltInActionAssets failed: ' + (e as Error)?.message);
      // 失败时尝试从 rawfile 重建
      await this.registerBuiltInAssets();
      return this.builtinAssetsCache ?? [];
    }
  }

  /**
   * T-3D.6C: 获取内置动作资产(按 ID)。
   */
  async getBuiltInActionAsset(actionId: string): Promise<Character3DActionAsset | null> {
    const assets: Character3DActionAsset[] = await this.listBuiltInActionAssets();
    for (let i: number = 0; i < assets.length; i++) {
      if (assets[i].id === actionId) {
        return assets[i];
      }
    }
    return null;
  }

  /**
   * T-3D.6C: 列出所有动作资产(内置 + 用户导入)。
   *
   * 加载顺序:
   * 1. 读取 rawfile 默认 Manifest → 注册全部内置动作
   * 2. 读取用户别名和隐藏状态(由 ViewModel 处理)
   * 3. 读取用户导入动作
   * 4. 合并展示
   */
  async listAllActionAssets(): Promise<ActionAssetListItem[]> {
    this.requireInit();
    const result: ActionAssetListItem[] = [];
    // 1. 内置动作
    const builtInAssets: Character3DActionAsset[] = await this.listBuiltInActionAssets();
    for (let i: number = 0; i < builtInAssets.length; i++) {
      result.push({
        asset: builtInAssets[i],
        fileExists: true // 内置动作始终视为存在(rawfile 打包)
      } as ActionAssetListItem);
    }
    // 2. 用户导入动作
    const importedAssets: ActionAssetListItem[] = await this.listActionAssets();
    for (let i: number = 0; i < importedAssets.length; i++) {
      result.push(importedAssets[i]);
    }
    return result;
  }

  /**
   * T-3D.6C: 清除内置动作的 Preferences(用于"恢复默认"功能)。
   *
   * 清除后,下次调用 listBuiltInActionAssets 会从 rawfile 重建。
   */
  async clearBuiltInPreferences(): Promise<void> {
    try {
      const json: string = await this.preferences.getString(PREF_KEY_BUILTIN_INDEX, '');
      if (json.length > 0) {
        const obj: Object = JSON.parse(json);
        if (obj instanceof Array) {
          const arr: Object[] = obj as Object[];
          for (let i: number = 0; i < arr.length; i++) {
            const id: string = String(arr[i]);
            const key: string = PREF_KEY_BUILTIN_ASSET_PREFIX + id;
            await this.preferences.delete(key);
          }
        }
      }
      await this.preferences.delete(PREF_KEY_BUILTIN_INDEX);
      // 清除显示偏好(别名/隐藏)
      await this.displayPrefStore.clearAll();
      // T-3D.6C-C: 清除所有循环播放偏好(恢复默认循环策略)
      await this.playbackPrefStore.clearAllGlobal();
      // 清除内存缓存,触发下次从 rawfile 重建
      this.builtinAssetsCache = null;
      this.builtinManifestCache = null;
      Logger.info(LOG_TAG, 'clearBuiltInPreferences: ok');
    } catch (e) {
      Logger.warn(LOG_TAG, 'clearBuiltInPreferences failed: ' + (e as Error)?.message);
    }
  }

  /**
   * T-3D.6C: 获取内置动作预览模型 GLB 文件路径(rawfile 路径)。
   *
   * 用于卡片预览。预览模型是静态的,不包含动画。
   */
  getBuiltInPreviewRawfilePath(): string {
    return BUILTIN_ACTION_RAWFILE_DIR + '/' + BUILTIN_PREVIEW_FILE_NAME;
  }

  /**
   * T-3D.6B: 获取应用 filesDir 路径(开发模式入口用于拼接测试文件路径)。
   *
   * 仅在开发构建中使用,正式发布前可移除。
   */
  getFilesDirForDevTest(): string {
    return this.appContext.filesDir;
  }

  /**
   * T-3D.6B: 从应用沙盒内的本地路径加载动作(开发模式入口专用)。
   *
   * 与 importActionPreview 相同流程,但绕过 DocumentViewPicker,
   * 直接读取应用 filesDir 下的相对路径文件。
   *
   * @param relativePath 相对于 filesDir 的路径(如 'dev_action_test/Fox.glb')
   * @param displayName 显示名
   */
  async importActionFromLocalDevPath(relativePath: string, displayName: string): Promise<ActionImportPreview> {
    this.requireInit();
    const cleanedPath: string = relativePath.startsWith('/') ? relativePath.substring(1) : relativePath;
    const absolutePath: string = this.appContext.filesDir + '/' + cleanedPath;
    Logger.info(LOG_TAG, 'dev import: path=filesDir/' + cleanedPath + ' name=' + displayName);
    // T-3D.6B: 预创建父目录(应用有权创建自己的沙盒子目录,shell 用户无权)
    const lastSlash: number = absolutePath.lastIndexOf('/');
    if (lastSlash > 0) {
      const parentDir: string = absolutePath.substring(0, lastSlash);
      try {
        if (!fileIo.accessSync(parentDir)) {
          fileIo.mkdirSync(parentDir, true);
        }
      } catch (e) {
        Logger.error(LOG_TAG, 'dev import mkdir parent failed: ' + (e as Error)?.message);
      }
    }
    const request: ActionImportRequest = {
      sourceUri: absolutePath,
      sourceFileName: displayName
    };
    return this.importActionPreview(request);
  }

  /**
   * T-3D.6B: 返回 dev_action_test 目录的绝对路径(用于 hdc file send 推送)。
   */
  getDevTestActionDir(): string {
    return this.appContext.filesDir + '/dev_action_test';
  }

  /**
   * T-3D.6B: 检查 dev_action_test 目录下是否存在指定文件名。
   */
  checkDevTestFileExists(fileName: string): boolean {
    if (fileName.length === 0) {
      return false;
    }
    const fullPath: string = this.appContext.filesDir + '/dev_action_test/' + fileName;
    try {
      return fileIo.accessSync(fullPath);
    } catch (_e) {
      return false;
    }
  }

  /**
   * T-3D.6B: 开发模式 - 通过 HTTP 下载测试动作文件到应用沙盒。
   *
   * 用途:模拟器中 DocumentViewPicker 不可用且 hdc file send 无法写入应用沙盒时,
   * 通过应用自身的网络权限下载测试资源到 filesDir/dev_action_test/。
   *
   * 仅用于开发构建,正式发布前移除。
   *
   * @param url 下载 URL(必须是公开可访问的 HTTPS URL)
   * @param fileName 保存到沙盒的文件名
   * @returns 下载的文件绝对路径
   */
  async downloadDevTestAction(url: string, fileName: string): Promise<string> {
    this.requireInit();
    if (url.length === 0 || fileName.length === 0) {
      throw new Error('url or fileName is empty');
    }
    const devDir: string = this.appContext.filesDir + '/dev_action_test';
    try {
      if (!fileIo.accessSync(devDir)) {
        fileIo.mkdirSync(devDir, true);
      }
    } catch (e) {
      throw new Error('create devDir failed: ' + (e as Error)?.message);
    }
    const targetPath: string = devDir + '/' + fileName;
    Logger.info(LOG_TAG, 'dev download start: url=' + url);

    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const promise: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 60000
      } as http.HttpRequestOptions);
      const code: number = promise.responseCode;
      if (code !== 200) {
        throw new Error('HTTP ' + code);
      }
      const buffer: ArrayBuffer = promise.result as ArrayBuffer;
      if (buffer === null || buffer.byteLength === 0) {
        throw new Error('empty response body');
      }
      Logger.info(LOG_TAG, 'dev download ok: size=' + buffer.byteLength);
      this.writeBufferToPath(buffer, targetPath);
      return targetPath;
    } finally {
      httpRequest.destroy();
    }
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('Character3DActionService not initialized');
    }
  }

  /**
   * 步骤一:动作导入预览。
   *
   * 流程:
   * 1. 复制源文件到临时目录
   * 2. 读取文件并验证 GLB 格式(GltfValidator)
   * 3. 解析动画和节点信息(GltfAnimationParser)
   * 4. 执行骨骼识别与映射(mapBones)
   * 5. 检查兼容性
   * 6. 返回预览信息(不保存到正式目录)
   *
   * @param request 导入请求
   * @returns 预览结果
   */
  async importActionPreview(request: ActionImportRequest): Promise<ActionImportPreview> {
    this.requireInit();
    if (request.sourceUri.length === 0) {
      return this.createFailurePreview('源 URI 为空', request.sourceFileName);
    }

    // 1. 识别来源格式
    const sourceFormat: ActionSourceFormat = this.detectSourceFormat(request.sourceFileName);

    // 2. 复制到临时目录(避免修改原文件)
    let tempFilePath: string = '';
    let buffer: ArrayBuffer;
    try {
      const tempResult: TempCopyResult =
        await this.copyToTemp(request.sourceUri);
      tempFilePath = tempResult.path;
      buffer = tempResult.buffer;
    } catch (e) {
      return this.createFailurePreview(
        '读取文件失败: ' + (e as Error)?.message, request.sourceFileName
      );
    }

    // 3. 文件大小检查
    if (buffer.byteLength > ACTION_FILE_MAX_SIZE_BYTES) {
      await this.cleanupTempFile(tempFilePath);
      return this.createFailurePreview(
        '文件过大,不能超过 ' + (ACTION_FILE_MAX_SIZE_BYTES / 1024 / 1024) + 'MB',
        request.sourceFileName
      );
    }

    // 4. VRMA 格式特殊处理
    if (sourceFormat === ActionSourceFormat.Vrma) {
      // VRMA 是 VRM Animation 格式,当前 ArkGraphics 3D 不支持直接播放
      // 只完成识别和元数据保存,明确提示用户
      await this.cleanupTempFile(tempFilePath);
      return {
        canImport: false,
        errorMessage: 'VRMA 格式当前不支持直接播放(ArkGraphics 3D 限制)。已识别为 VRM Animation,可保存元数据但无法播放。',
        sourceFileName: request.sourceFileName,
        sourceFormat: sourceFormat,
        clips: [],
        nodeNames: [],
        hasSkins: false,
        skeletonProfile: SkeletonProfile.Unknown,
        compatibilityLevel: CompatibilityLevel.Unsupported,
        missingRequiredBones: [],
        tempFilePath: ''
      };
    }

    // 5. GLB 格式验证
    const validationResult: GltfValidationResult = GltfValidator.validate(buffer);
    if (!validationResult.valid) {
      await this.cleanupTempFile(tempFilePath);
      return this.createFailurePreview(
        'GLB 格式验证失败: ' + validationResult.errorMessage,
        request.sourceFileName
      );
    }

    // 6. 检查不支持的必需扩展
    if (validationResult.modelInfo.unsupportedRequiredExtensions.length > 0) {
      await this.cleanupTempFile(tempFilePath);
      const extList: string = validationResult.modelInfo.unsupportedRequiredExtensions.join(', ');
      return this.createFailurePreview(
        '该文件依赖不支持的 glTF 扩展: ' + extList,
        request.sourceFileName
      );
    }

    // 7. 解析动画和节点信息
    const parseResult: GltfAnimationParseResult = GltfAnimationParser.parse(buffer);
    if (!parseResult.valid) {
      await this.cleanupTempFile(tempFilePath);
      return this.createFailurePreview(
        '动画解析失败: ' + parseResult.errorMessage,
        request.sourceFileName
      );
    }

    // 8. Clip 数量检查
    if (parseResult.clips.length > ACTION_MAX_CLIP_COUNT) {
      await this.cleanupTempFile(tempFilePath);
      return this.createFailurePreview(
        'Clip 数量过多(' + parseResult.clips.length + '),不能超过 ' + ACTION_MAX_CLIP_COUNT,
        request.sourceFileName
      );
    }

    // 9. 通道数和时长检查
    for (let i: number = 0; i < parseResult.clips.length; i++) {
      const clip: AnimationClipInfo = parseResult.clips[i];
      if (clip.channelCount > ACTION_MAX_CHANNEL_COUNT) {
        await this.cleanupTempFile(tempFilePath);
        return this.createFailurePreview(
          'Clip ' + clip.name + ' 通道数过多(' + clip.channelCount + ')',
          request.sourceFileName
        );
      }
      if (clip.durationMs > ACTION_MAX_DURATION_MS) {
        await this.cleanupTempFile(tempFilePath);
        return this.createFailurePreview(
          'Clip ' + clip.name + ' 时长过长(' + (clip.durationMs / 1000) + '秒)',
          request.sourceFileName
        );
      }
    }

    // 10. 骨骼识别与映射
    const hasSkins: boolean = parseResult.hasSkins;
    const boneResult = mapBones(parseResult.nodeNames, '', hasSkins);

    // 11. 缺失骨骼名列表
    const missingBoneNames: string[] = boneResult.missingRequired.map((b) => String(b));

    Logger.info(LOG_TAG, 'importActionPreview ok: format=' + sourceFormat
      + ', clips=' + parseResult.clips.length
      + ', nodes=' + parseResult.nodeNames.length
      + ', profile=' + boneResult.profile
      + ', compat=' + boneResult.compatibility);

    return {
      canImport: true,
      errorMessage: '',
      sourceFileName: request.sourceFileName,
      sourceFormat: sourceFormat,
      clips: parseResult.clips,
      nodeNames: parseResult.nodeNames,
      hasSkins: hasSkins,
      skeletonProfile: boneResult.profile,
      compatibilityLevel: boneResult.compatibility,
      missingRequiredBones: missingBoneNames,
      tempFilePath: tempFilePath
    };
  }

  /**
   * 步骤二:确认导入动作。
   *
   * 流程:
   * 1. 验证用户选择的 Clip 索引
   * 2. 将临时文件移动到正式目录 files/character_actions/{actionId}/action.glb
   * 3. 写入 metadata.json
   * 4. 创建 Character3DActionAsset 并持久化
   * 5. 添加到资产索引
   * 6. 返回新创建的动作资产
   *
   * @param confirm 确认请求
   * @returns 新创建的动作资产
   */
  async confirmImportAction(confirm: ActionImportConfirm): Promise<Character3DActionAsset> {
    this.requireInit();
    const preview: ActionImportPreview = confirm.preview;
    if (!preview.canImport) {
      throw new Error('预览不可导入: ' + preview.errorMessage);
    }
    if (preview.tempFilePath.length === 0) {
      throw new Error('临时文件路径为空');
    }
    if (preview.clips.length === 0) {
      throw new Error('没有可用的 Clip');
    }
    if (confirm.selectedClipIndex < 0 || confirm.selectedClipIndex >= preview.clips.length) {
      throw new Error('选择的 Clip 索引无效: ' + confirm.selectedClipIndex);
    }

    const selectedClip: AnimationClipInfo = preview.clips[confirm.selectedClipIndex];
    const actionId: string = generateActionId();
    const actionDir: string = this.baseDir + '/' + actionId;
    const actionFilePath: string = actionDir + '/' + ACTION_FILE_NAME;
    const metadataPath: string = actionDir + '/' + METADATA_FILE_NAME;
    const internalRelativePath: string = ACTION_DIR + '/' + actionId + '/' + ACTION_FILE_NAME;

    // 1. 创建动作目录
    try {
      if (!fileIo.accessSync(actionDir)) {
        fileIo.mkdirSync(actionDir, true);
      }
    } catch (e) {
      await this.cleanupTempFile(preview.tempFilePath);
      throw new Error('创建动作目录失败: ' + String(e));
    }

    // 2. 移动临时文件到正式目录
    try {
      const buffer: ArrayBuffer = await this.readFileToBuffer(preview.tempFilePath);
      this.writeBufferToPath(buffer, actionFilePath);
      await this.cleanupTempFile(preview.tempFilePath);
    } catch (e) {
      await this.cleanupTempFile(preview.tempFilePath);
      // 清理已创建的目录
      await this.cleanupActionDir(actionId);
      throw new Error('保存动作文件失败: ' + String(e));
    }

    // 3. 创建动作资产对象
    const now: number = Date.now();
    const asset: Character3DActionAsset = createDefaultActionAsset(
      actionId,
      confirm.displayName.length > 0 ? confirm.displayName : selectedClip.name,
      preview.sourceFileName,
      internalRelativePath,
      preview.sourceFormat
    );
    asset.clipName = selectedClip.name;
    asset.clipIndex = selectedClip.index;
    asset.slot = String(confirm.targetSlot);
    asset.durationMs = selectedClip.durationMs;
    asset.loop = confirm.loop;
    asset.speed = sanitizeSpeed(confirm.speed);
    asset.skeletonProfile = preview.skeletonProfile;
    asset.compatibilityLevel = preview.compatibilityLevel;
    asset.actionCompatibility = this.computeActionCompatibility(preview);
    asset.boneMappingProfileId = ''; // 第一版不保存详细映射
    asset.allClips = preview.clips;
    asset.createdAt = now;
    asset.updatedAt = now;
    asset.isBuiltIn = false;
    asset.enabled = true;

    // 4. 写入 metadata.json
    try {
      const metadataJson: string = serializeActionAsset(asset);
      this.writeTextToPath(metadataJson, metadataPath);
    } catch (e) {
      await this.cleanupActionDir(actionId);
      throw new Error('写入 metadata 失败: ' + String(e));
    }

    // 5. 持久化到 Preferences
    try {
      const assetKey: string = PREF_KEY_ASSET_PREFIX + actionId;
      await this.preferences.putString(assetKey, serializeActionAsset(asset));
      // 添加到索引
      await this.addToAssetsIndex(actionId);
    } catch (e) {
      await this.cleanupActionDir(actionId);
      throw new Error('持久化动作资产失败: ' + String(e));
    }

    Logger.info(LOG_TAG, 'confirmImportAction ok: id=' + actionId
      + ', clip=' + selectedClip.name
      + ', slot=' + confirm.targetSlot);
    return asset;
  }

  /**
   * 取消导入(清理临时文件)。
   */
  async cancelImport(preview: ActionImportPreview): Promise<void> {
    if (preview.tempFilePath.length > 0) {
      await this.cleanupTempFile(preview.tempFilePath);
    }
  }

  /**
   * 列出所有动作资产。
   */
  async listActionAssets(): Promise<ActionAssetListItem[]> {
    this.requireInit();
    const index: string[] = await this.getAssetsIndex();
    const result: ActionAssetListItem[] = [];
    for (let i: number = 0; i < index.length; i++) {
      const id: string = index[i];
      const asset: Character3DActionAsset | null = await this.getActionAsset(id);
      if (asset === null) {
        continue;
      }
      const fileExists: boolean = this.checkActionFileExists(asset);
      result.push({ asset: asset, fileExists: fileExists } as ActionAssetListItem);
    }
    return result;
  }

  /**
   * 获取单个动作资产。
   */
  async getActionAsset(actionId: string): Promise<Character3DActionAsset | null> {
    this.requireInit();
    if (actionId.length === 0) {
      return null;
    }
    try {
      const key: string = PREF_KEY_ASSET_PREFIX + actionId;
      const json: string = await this.preferences.getString(key, '');
      if (json.length === 0) {
        return null;
      }
      return deserializeActionAsset(json);
    } catch (e) {
      Logger.warn(LOG_TAG, 'getActionAsset failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * 更新动作资产(显示名/速度/循环/启用状态)。
   */
  async updateActionAsset(
    actionId: string,
    updates: ActionAssetUpdates
  ): Promise<Character3DActionAsset | null> {
    this.requireInit();
    const asset: Character3DActionAsset | null = await this.getActionAsset(actionId);
    if (asset === null) {
      return null;
    }
    if (updates.displayName !== undefined) {
      asset.displayName = updates.displayName;
    }
    if (updates.speed !== undefined) {
      asset.speed = sanitizeSpeed(updates.speed);
    }
    if (updates.loop !== undefined) {
      asset.loop = updates.loop;
    }
    if (updates.enabled !== undefined) {
      asset.enabled = updates.enabled;
    }
    asset.updatedAt = Date.now();
    try {
      const key: string = PREF_KEY_ASSET_PREFIX + actionId;
      await this.preferences.putString(key, serializeActionAsset(asset));
      // 同步更新 metadata.json
      this.updateMetadataFile(asset);
    } catch (e) {
      Logger.error(LOG_TAG, 'updateActionAsset failed: ' + (e as Error)?.message);
    }
    return asset;
  }

  /**
   * 删除动作资产。
   * 同时清理文件和 Preferences。
   *
   * T-3D.6C: 内置动作(isBuiltIn=true)受保护,不允许删除。
   */
  async deleteActionAsset(actionId: string): Promise<void> {
    this.requireInit();
    if (actionId.length === 0) {
      return;
    }
    // T-3D.6C: 内置动作受保护
    if (this.isBuiltInActionId(actionId)) {
      Logger.warn(LOG_TAG, 'deleteActionAsset rejected: builtin action cannot be deleted, id=' + actionId);
      throw new Error('内置动作不可删除');
    }
    // 1. 读取资产信息(用于清理绑定)
    const asset: Character3DActionAsset | null = await this.getActionAsset(actionId);
    // 2. 清理绑定(所有 modelId 和 global)
    await this.removeBindingsByActionId(actionId);
    // T-3D.6C-C: 清理该动作的循环播放偏好
    await this.playbackPrefStore.removeAllForAction(actionId);
    // 3. 删除文件目录
    await this.cleanupActionDir(actionId);
    // 4. 从索引移除
    await this.removeFromAssetsIndex(actionId);
    // 5. 删除 Preferences
    try {
      const key: string = PREF_KEY_ASSET_PREFIX + actionId;
      await this.preferences.delete(key);
    } catch (e) {
      Logger.warn(LOG_TAG, 'deleteActionAsset pref failed: ' + (e as Error)?.message);
    }
    Logger.info(LOG_TAG, 'deleteActionAsset ok: id=' + actionId
      + ', slot=' + (asset !== null ? asset.slot : 'unknown'));
  }

  /**
   * T-3D.6C: 判断 actionId 是否为内置动作。
   * 内置动作 ID 以 'builtin_' 开头。
   */
  isBuiltInActionId(actionId: string): boolean {
    return actionId.startsWith('builtin_');
  }

  /**
   * 读取动作文件的完整路径(用于 Scene.load)。
   *
   * T-3D.6C: 内置动作返回共享的 pack 文件 URI。
   * 调用前需先调用 ensureBuiltInPackCached() 确保文件已就位。
   */
  getActionFileUri(actionId: string): string {
    if (this.isBuiltInActionId(actionId)) {
      // 内置动作共享一个 GLB 文件
      return 'file://' + this.appContext.filesDir + '/' + BUILTIN_PACK_SANDBOX_RELATIVE_PATH;
    }
    return 'file://' + this.baseDir + '/' + actionId + '/' + ACTION_FILE_NAME;
  }

  /**
   * T-3D.6C: 获取内置动作 GLB 包的 rawfile 路径。
   * 用于直接从 rawfile 加载(不经过沙盒缓存)。
   */
  getBuiltInPackRawfilePath(): string {
    return BUILTIN_ACTION_RAWFILE_DIR + '/' + BUILTIN_PACK_FILE_NAME;
  }

  /**
   * 检查动作文件是否存在。
   */
  checkActionFileExists(asset: Character3DActionAsset): boolean {
    const path: string = this.appContext.filesDir + '/' + asset.internalRelativePath;
    try {
      return fileIo.accessSync(path);
    } catch (_e) {
      return false;
    }
  }

  /**
   * 保存动作绑定(per-model)。
   */
  async saveBinding(binding: Character3DActionBinding): Promise<void> {
    this.requireInit();
    const bindings: Character3DActionBinding[] = await this.getBindings(binding.modelId);
    // 替换同槽位的旧绑定
    const newBindings: Character3DActionBinding[] = [];
    let found: boolean = false;
    for (let i: number = 0; i < bindings.length; i++) {
      if (bindings[i].slot === binding.slot) {
        newBindings.push(binding);
        found = true;
      } else {
        newBindings.push(bindings[i]);
      }
    }
    if (!found) {
      newBindings.push(binding);
    }
    await this.saveBindings(binding.modelId, newBindings);
  }

  /**
   * 保存全局默认绑定。
   */
  async saveGlobalBinding(binding: Character3DActionBinding): Promise<void> {
    this.requireInit();
    const bindings: Character3DActionBinding[] = await this.getGlobalBindings();
    const newBindings: Character3DActionBinding[] = [];
    let found: boolean = false;
    for (let i: number = 0; i < bindings.length; i++) {
      if (bindings[i].slot === binding.slot) {
        newBindings.push(binding);
        found = true;
      } else {
        newBindings.push(bindings[i]);
      }
    }
    if (!found) {
      newBindings.push(binding);
    }
    const json: string = JSON.stringify(newBindings.map((b: Character3DActionBinding): string => JSON.parse(serializeActionBinding(b))));
    await this.preferences.putString(PREF_KEY_GLOBAL_BINDINGS, json);
  }

  /**
   * 获取指定 modelId 的所有绑定。
   */
  async getBindings(modelId: string): Promise<Character3DActionBinding[]> {
    this.requireInit();
    if (modelId.length === 0) {
      return [];
    }
    try {
      const key: string = PREF_KEY_BINDINGS_PREFIX + modelId;
      const json: string = await this.preferences.getString(key, '');
      if (json.length === 0) {
        return [];
      }
      return this.deserializeBindingsArray(json);
    } catch (e) {
      return [];
    }
  }

  /**
   * 获取全局默认绑定。
   */
  async getGlobalBindings(): Promise<Character3DActionBinding[]> {
    this.requireInit();
    try {
      const json: string = await this.preferences.getString(PREF_KEY_GLOBAL_BINDINGS, '');
      if (json.length === 0) {
        return [];
      }
      return this.deserializeBindingsArray(json);
    } catch (e) {
      return [];
    }
  }

  /**
   * 获取指定 modelId 和 slot 的绑定。
   * 选择顺序:模型专属 → 全局默认 → null。
   */
  async getBinding(
    modelId: string, slot: Character3DActionSlot
  ): Promise<Character3DActionBinding | null> {
    this.requireInit();
    // 1. 模型专属
    if (modelId.length > 0) {
      const bindings: Character3DActionBinding[] = await this.getBindings(modelId);
      for (let i: number = 0; i < bindings.length; i++) {
        if (bindings[i].slot === slot) {
          return bindings[i];
        }
      }
    }
    // 2. 全局默认
    const globals: Character3DActionBinding[] = await this.getGlobalBindings();
    for (let i: number = 0; i < globals.length; i++) {
      if (globals[i].slot === slot) {
        return globals[i];
      }
    }
    return null;
  }

  /**
   * 删除指定 modelId 和 slot 的绑定。
   */
  async removeBinding(
    modelId: string, slot: Character3DActionSlot
  ): Promise<void> {
    this.requireInit();
    if (modelId.length === 0) {
      return;
    }
    const bindings: Character3DActionBinding[] = await this.getBindings(modelId);
    const newBindings: Character3DActionBinding[] = [];
    for (let i: number = 0; i < bindings.length; i++) {
      if (bindings[i].slot !== slot) {
        newBindings.push(bindings[i]);
      }
    }
    await this.saveBindings(modelId, newBindings);
  }

  /**
   * 删除全局默认绑定。
   */
  async removeGlobalBinding(slot: Character3DActionSlot): Promise<void> {
    this.requireInit();
    const bindings: Character3DActionBinding[] = await this.getGlobalBindings();
    const newBindings: Character3DActionBinding[] = [];
    for (let i: number = 0; i < bindings.length; i++) {
      if (bindings[i].slot !== slot) {
        newBindings.push(bindings[i]);
      }
    }
    const json: string = JSON.stringify(newBindings.map((b: Character3DActionBinding): string => JSON.parse(serializeActionBinding(b))));
    await this.preferences.putString(PREF_KEY_GLOBAL_BINDINGS, json);
  }

  /**
   * 删除指定 modelId 的所有绑定(模型删除时调用)。
   */
  async removeAllBindingsForModel(modelId: string): Promise<void> {
    this.requireInit();
    if (modelId.length === 0) {
      return;
    }
    try {
      const key: string = PREF_KEY_BINDINGS_PREFIX + modelId;
      await this.preferences.delete(key);
    } catch (e) {
      Logger.warn(LOG_TAG, 'removeAllBindingsForModel failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 检查外部动作文件与当前模型的兼容性。
   * 用于动作导入时显示兼容等级。
   */
  checkActionModelCompatibility(
    actionPreview: ActionImportPreview,
    modelNodeNames: string[]
  ): ActionModelCompatibility {
    if (actionPreview.nodeNames.length === 0 || modelNodeNames.length === 0) {
      return { direct: false, mapped: false, commonCount: 0 } as ActionModelCompatibility;
    }
    const result = checkBoneCompatibility(modelNodeNames, actionPreview.nodeNames);
    return {
      direct: result.direct,
      mapped: result.mapped,
      commonCount: result.commonCount
    } as ActionModelCompatibility;
  }

  /**
   * 检测来源格式(根据文件扩展名)。
   */
  private detectSourceFormat(fileName: string): ActionSourceFormat {
    const lowerName: string = fileName.toLowerCase();
    if (lowerName.endsWith('.glb')) {
      return ActionSourceFormat.ExternalGlb;
    }
    if (lowerName.endsWith('.gltf')) {
      return ActionSourceFormat.Gltf;
    }
    if (lowerName.endsWith('.vrma')) {
      return ActionSourceFormat.Vrma;
    }
    return ActionSourceFormat.Unknown;
  }

  /**
   * 计算动作兼容性(根据预览结果)。
   */
  private computeActionCompatibility(preview: ActionImportPreview): ActionCompatibility {
    if (preview.clips.length === 0) {
      return ActionCompatibility.Unsupported;
    }
    if (preview.sourceFormat === ActionSourceFormat.Vrma) {
      return ActionCompatibility.MetadataOnly;
    }
    // 根据骨骼兼容等级判定
    switch (preview.compatibilityLevel) {
      case CompatibilityLevel.FullHumanoid:
        // 理论上可重定向,但当前 SDK 不支持运行时重定向,标记为 MetadataOnly
        return ActionCompatibility.MetadataOnly;
      case CompatibilityLevel.PartialHumanoid:
        return ActionCompatibility.MetadataOnly;
      case CompatibilityLevel.EmbeddedOnly:
        return ActionCompatibility.EmbeddedOnly;
      case CompatibilityLevel.StaticOnly:
        return ActionCompatibility.Unsupported;
      default:
        return ActionCompatibility.MetadataOnly;
    }
  }

  /**
   * 创建失败预览。
   */
  private createFailurePreview(message: string, fileName: string): ActionImportPreview {
    return {
      canImport: false,
      errorMessage: message,
      sourceFileName: fileName,
      sourceFormat: ActionSourceFormat.Unknown,
      clips: [],
      nodeNames: [],
      hasSkins: false,
      skeletonProfile: SkeletonProfile.Unknown,
      compatibilityLevel: CompatibilityLevel.Unsupported,
      missingRequiredBones: [],
      tempFilePath: ''
    } as ActionImportPreview;
  }

  /**
   * 复制源文件到临时目录,返回临时路径和 buffer。
   */
  private async copyToTemp(sourceUri: string): Promise<TempCopyResult> {
    const tempDir: string = this.appContext.filesDir + '/temp_actions';
    try {
      if (!fileIo.accessSync(tempDir)) {
        fileIo.mkdirSync(tempDir, true);
      }
    } catch (_e) {
      // ignore
    }
    const tempPath: string = tempDir + '/import_' + Date.now() + '.glb';
    let srcFile: fileIo.File | null = null;
    try {
      srcFile = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(srcFile.fd);
      const size: number = stat.size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(srcFile.fd, buffer);
      fileIo.closeSync(srcFile);
      srcFile = null;
      this.writeBufferToPath(buffer, tempPath);
      return { path: tempPath, buffer: buffer } as TempCopyResult;
    } catch (e) {
      if (srcFile !== null) {
        try {
          fileIo.closeSync(srcFile);
        } catch (_ignore) {
          // ignore
        }
      }
      throw new Error('copyToTemp failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 清理临时文件。
   */
  private async cleanupTempFile(path: string): Promise<void> {
    if (path.length === 0) {
      return;
    }
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (_e) {
      // ignore
    }
  }

  /**
   * 清理动作目录(删除整个 actionId 目录)。
   */
  private async cleanupActionDir(actionId: string): Promise<void> {
    if (actionId.length === 0) {
      return;
    }
    const dir: string = this.baseDir + '/' + actionId;
    try {
      if (fileIo.accessSync(dir)) {
        // 删除目录下所有文件
        const names: string[] = fileIo.listFileSync(dir);
        for (let i: number = 0; i < names.length; i++) {
          const filePath: string = dir + '/' + names[i];
          try {
            fileIo.unlinkSync(filePath);
          } catch (_e) {
            // ignore
          }
        }
        fileIo.rmdirSync(dir);
      }
    } catch (_e) {
      // ignore
    }
  }

  /**
   * 读取文件到 ArrayBuffer。
   */
  private async readFileToBuffer(path: string): Promise<ArrayBuffer> {
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const size: number = stat.size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(file.fd, buffer);
      return buffer;
    } finally {
      fileIo.closeSync(file);
    }
  }

  /**
   * 写入 ArrayBuffer 到路径。
   */
  private writeBufferToPath(buffer: ArrayBuffer, path: string): void {
    const file: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    try {
      fileIo.writeSync(file.fd, buffer);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /**
   * 写入文本到路径。
   */
  private writeTextToPath(text: string, path: string): void {
    const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
    // UTF-8 单字符最多 4 字节,预分配足够空间
    const destSize: number = text.length * 4;
    const dest: Uint8Array = new Uint8Array(destSize);
    const result: util.EncodeIntoUint8ArrayInfo = encoder.encodeIntoUint8Array(text, dest);
    const written: number = result.written;
    const buffer: ArrayBuffer = new ArrayBuffer(written);
    const view: Uint8Array = new Uint8Array(buffer);
    view.set(dest.subarray(0, written));
    this.writeBufferToPath(buffer, path);
  }

  /**
   * 更新 metadata.json 文件。
   */
  private updateMetadataFile(asset: Character3DActionAsset): void {
    try {
      const path: string = this.appContext.filesDir + '/' + ACTION_DIR
        + '/' + asset.id + '/' + METADATA_FILE_NAME;
      const json: string = serializeActionAsset(asset);
      this.writeTextToPath(json, path);
    } catch (e) {
      Logger.warn(LOG_TAG, 'updateMetadataFile failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 获取资产索引。
   */
  private async getAssetsIndex(): Promise<string[]> {
    try {
      const json: string = await this.preferences.getString(PREF_KEY_ASSETS_INDEX, '');
      if (json.length === 0) {
        return [];
      }
      const obj: Object = JSON.parse(json);
      if (!(obj instanceof Array)) {
        return [];
      }
      const arr: Object[] = obj as Object[];
      const result: string[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        result.push(String(arr[i]));
      }
      return result;
    } catch (e) {
      return [];
    }
  }

  /**
   * 添加到资产索引。
   */
  private async addToAssetsIndex(actionId: string): Promise<void> {
    const index: string[] = await this.getAssetsIndex();
    if (index.indexOf(actionId) >= 0) {
      return;
    }
    index.push(actionId);
    await this.preferences.putString(PREF_KEY_ASSETS_INDEX, JSON.stringify(index));
  }

  /**
   * 从资产索引移除。
   */
  private async removeFromAssetsIndex(actionId: string): Promise<void> {
    const index: string[] = await this.getAssetsIndex();
    const newIndex: string[] = [];
    for (let i: number = 0; i < index.length; i++) {
      if (index[i] !== actionId) {
        newIndex.push(index[i]);
      }
    }
    await this.preferences.putString(PREF_KEY_ASSETS_INDEX, JSON.stringify(newIndex));
  }

  /**
   * 保存指定 modelId 的绑定列表。
   */
  private async saveBindings(modelId: string, bindings: Character3DActionBinding[]): Promise<void> {
    if (modelId.length === 0) {
      return;
    }
    const key: string = PREF_KEY_BINDINGS_PREFIX + modelId;
    const json: string = JSON.stringify(bindings.map((b: Character3DActionBinding): string => JSON.parse(serializeActionBinding(b))));
    await this.preferences.putString(key, json);
  }

  /**
   * 删除引用指定 actionId 的所有绑定。
   */
  private async removeBindingsByActionId(actionId: string): Promise<void> {
    // 全局绑定
    const globals: Character3DActionBinding[] = await this.getGlobalBindings();
    const newGlobals: Character3DActionBinding[] = [];
    let globalChanged: boolean = false;
    for (let i: number = 0; i < globals.length; i++) {
      if (globals[i].actionAssetId === actionId) {
        globalChanged = true;
      } else {
        newGlobals.push(globals[i]);
      }
    }
    if (globalChanged) {
      const json: string = JSON.stringify(newGlobals.map((b: Character3DActionBinding): string => JSON.parse(serializeActionBinding(b))));
      await this.preferences.putString(PREF_KEY_GLOBAL_BINDINGS, json);
    }
    // per-model 绑定:无法遍历所有 modelId,留待模型删除时清理
    // 实际使用时,用户删除动作时会同时通过 UI 清理绑定
  }

  /**
   * 反序列化绑定数组。
   */
  private deserializeBindingsArray(json: string): Character3DActionBinding[] {
    try {
      const obj: Object = JSON.parse(json);
      if (!(obj instanceof Array)) {
        return [];
      }
      const arr: Object[] = obj as Object[];
      const result: Character3DActionBinding[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        const itemJson: string = JSON.stringify(arr[i]);
        const binding: Character3DActionBinding | null = deserializeActionBinding(itemJson);
        if (binding !== null) {
          result.push(binding);
        }
      }
      return result;
    } catch (_e) {
      return [];
    }
  }
}
