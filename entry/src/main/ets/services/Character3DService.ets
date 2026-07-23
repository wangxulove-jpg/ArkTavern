/**
 * Character3DService 3D 模型业务服务
 *
 * 临时开发测试: T-3D.2 模型导入与资源保存;T-3D.3 模型兼容性检测;T-3D.4A Bounds 与扩展检测
 *
 * 职责:
 * - 协调 Model3DAssetStore(文件操作)与 AppPreferences(路径持久化)
 * - 提供 importModel / getConfig / clearModel 三个核心能力
 * - T-3D.3: 导入时调用 GltfValidator 验证 GLB 格式,返回模型摘要信息
 * - T-3D.4A: 导入时检查 unsupportedRequiredExtensions,拒绝不支持的模型
 * - T-3D.4A: 显示配置按 modelId 隔离,新模型首次导入使用 Bounds 自适应默认配置
 * - T-3D.4A: 提供 computeAutoFitConfig 根据 GltfModelInfo 计算自适应视角
 * - 不直接操作 Scene(由 ViewModel 调用 Scene.load)
 * - 不读取聊天正文 / Prompt / API Key
 *
 * 持久化设计:
 * - Preferences key: character_3d_model_uri(全局,单模型 PoC)
 * - Preferences key: character_3d_model_display_name(显示用文件名)
 * - Preferences key: character_3d_display_config_<modelId>(per-model 显示配置)
 * - modelId 使用 displayName(稳定标识,同一文件名视为同一模型配置)
 *
 * 数据流:
 * - 导入: picker URI → Model3DAssetStore.saveModel → 沙箱 URI → GltfValidator 验证 → Preferences
 * - 读取: Preferences → 沙箱 URI + 显示名 → ViewModel 加载
 * - 清除: Preferences 删除 → Model3DAssetStore.deleteModelByUri
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Model3DAssetStore } from '../storage/Model3DAssetStore';
import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import { GltfValidator, GltfModelInfo, GltfValidationResult } from '../parser/GltfValidator';
import {
  Character3DDisplayConfig,
  createDefaultDisplayConfig,
  sanitizeDisplayConfig,
  serializeDisplayConfig,
  deserializeDisplayConfig,
  isDisplayConfigEqual
} from '../models/character3d/Character3DDisplayConfig';
import { computeBoundsFromGltf, computeAutoFitDisplayConfig } from '../models/character3d/ModelBounds';
import { Character3DModelCompatibilityService } from './Character3DModelCompatibilityService';
import {
  ModelCompatibilityStatus,
  ModelConversionMode,
  ModelConversionProgress,
  ModelConversionResult,
  ModelCompatibilityAnalysis,
  getConversionStageMessage
} from '../models/character3d/ModelCompatibility';

const LOG_TAG: string = 'Character3DService';

/** Preferences key:当前 3D 模型文件 URI(空字符串表示未导入) */
const PREF_KEY_MODEL_URI: string = 'character_3d_model_uri';
/** Preferences key:当前 3D 模型显示名(用于 UI 展示) */
const PREF_KEY_MODEL_DISPLAY_NAME: string = 'character_3d_model_display_name';
/** Preferences key 前缀:3D 模型显示配置(per-model,后接 modelId) */
const PREF_KEY_DISPLAY_CONFIG_PREFIX: string = 'character_3d_display_config_';
/** 内置测试模型文件名(rawfile 目录下) */
const RAWFILE_TEST_MODEL_NAME: string = 'test_model.glb';
/** 内置测试模型显示名 */
const RAWFILE_TEST_MODEL_DISPLAY_NAME: string = '测试模型(TestCube)';

/**
 * 3D 模型配置(从 Preferences 读取的快照)
 */
export interface Character3DModelConfig {
  /** 模型文件 URI(空字符串表示未导入,使用程序化几何体) */
  modelUri: string;
  /** 显示名(用于 UI 展示,空字符串表示未导入) */
  displayName: string;
  /** 模型文件是否仍然存在(URI 非空但文件丢失时为 false) */
  fileExists: boolean;
}

/**
 * 导入结果(包含验证后的模型信息)。
 */
export interface Character3DImportResult {
  /** 新的沙箱 URI */
  modelUri: string;
  /** 显示名 */
  displayName: string;
  /** GLTF 模型摘要信息(验证失败时为空字段) */
  modelInfo: GltfModelInfo;
  /** T-3D.4A: 该模型的自适应默认显示配置(基于 Bounds 计算) */
  autoFitConfig: Character3DDisplayConfig;
  /** T-3D.6C-C: 兼容性分析结果(无可转换扩展时为 null) */
  compatibilityAnalysis: ModelCompatibilityAnalysis | null;
  /** T-3D.6C-C: 转换结果(未执行转换时为 null) */
  conversionResult: ModelConversionResult | null;
  /** T-3D.6C-C3: 原始文件 SHA-256(用于加载验证标记,无转换时为空) */
  sourceSha256: string;
}

export class Character3DService {
  private readonly assetStore: Model3DAssetStore;
  private readonly preferences: AppPreferences;
  private readonly appContext: common.Context;
  /** T-3D.6C-C: 模型兼容性预处理服务(可选,通过 setter 注入避免循环依赖) */
  private compatibilityService: Character3DModelCompatibilityService | null = null;

  constructor(context: common.Context, preferences: AppPreferences) {
    this.assetStore = new Model3DAssetStore();
    this.assetStore.initialize(context);
    this.preferences = preferences;
    this.appContext = context;
  }

  /**
   * T-3D.6C-C: 注入模型兼容性预处理服务。
   * 在 AppServices.initialize 中创建 compatibilityService 后调用。
   */
  setCompatibilityService(service: Character3DModelCompatibilityService): void {
    this.compatibilityService = service;
  }

  /**
   * T-3D.6C-C3: 标记当前模型缓存为已加载验证(ArkGraphics 加载成功后调用)。
   */
  async markModelLoadVerified(sourceSha256: string): Promise<void> {
    if (this.compatibilityService === null || sourceSha256.length === 0) {
      return;
    }
    await this.compatibilityService.markCacheLoadVerified(sourceSha256);
  }

  /**
   * T-3D.6C-C3: 失效当前模型缓存(ArkGraphics 加载失败后调用)。
   */
  async invalidateModelCache(inputPath: string): Promise<void> {
    if (this.compatibilityService === null) {
      return;
    }
    await this.compatibilityService.invalidateCacheForInput(inputPath);
  }

  /**
   * 读取当前 3D 模型配置。
   * 未导入时返回 { modelUri: '', displayName: '', fileExists: false }。
   */
  async getConfig(): Promise<Character3DModelConfig> {
    const uri: string = await this.preferences.getString(PREF_KEY_MODEL_URI, '');
    const name: string = await this.preferences.getString(PREF_KEY_MODEL_DISPLAY_NAME, '');
    if (uri.length === 0) {
      return { modelUri: '', displayName: '', fileExists: false };
    }
    const exists: boolean = this.assetStore.exists(uri);
    if (!exists) {
      Logger.warn(LOG_TAG, 'model file missing, uri recorded but file gone');
    }
    return { modelUri: uri, displayName: name, fileExists: exists };
  }

  /**
   * T-3D.4A: 根据 modelUri 重新读取模型文件并验证,返回 GltfModelInfo。
   *
   * 用途:应用重启后从 Preferences 恢复模型时,需要重新获取模型信息(Bounds/扩展等),
   * 以支持自适应视角计算和 autoFitView。
   *
   * @param modelUri 沙箱模型文件 URI(file:// 开头)
   * @returns GltfModelInfo;读取或验证失败时返回 null
   */
  async getModelInfoByUri(modelUri: string): Promise<GltfModelInfo | null> {
    if (modelUri.length === 0) {
      return null;
    }
    try {
      const buffer: ArrayBuffer = await this.readModelFile(modelUri);
      const result: GltfValidationResult = GltfValidator.validate(buffer);
      if (!result.valid) {
        Logger.warn(LOG_TAG, 'getModelInfoByUri validation failed: ' + result.errorMessage);
        return null;
      }
      Logger.info(LOG_TAG, 'getModelInfoByUri ok: meshes=' + result.modelInfo.meshCount
        + ', animations=' + result.modelInfo.animationCount
        + ', hasBounds=' + (result.modelInfo.boundsMin !== null));
      return result.modelInfo;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getModelInfoByUri error: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * 导入模型文件。
   *
   * 流程:
   * 1. 调用 Model3DAssetStore.saveModel 复制到沙箱
   * 2. T-3D.3: 读取沙箱文件并调用 GltfValidator 验证格式
   * 3. T-3D.4A: 检查 unsupportedRequiredExtensions,若有则拒绝并清理
   * 4. T-3D.6C-C: 检查 convertibleRequiredExtensions,若有则调用兼容性预处理
   * 5. 验证失败:删除已保存文件,抛出包含详细原因的错误
   * 6. 验证成功:删除旧模型文件,将新 URI + 显示名写入 Preferences
   * 7. T-3D.4A: 计算自适应显示配置并保存为该 modelId 的默认配置(若该 modelId 首次导入)
   *
   * @param sourceUri DocumentViewPicker 返回的源 URI
   * @param onProgress T-3D.6C-C 转换进度回调(可选)
   * @returns 导入结果(包含模型摘要信息和自适应配置)
   */
  async importModel(
    sourceUri: string,
    onProgress?: (progress: ModelConversionProgress) => void
  ): Promise<Character3DImportResult> {
    if (sourceUri.length === 0) {
      throw new Error('sourceUri must not be empty');
    }
    // 复制到沙箱
    const newUri: string = await this.assetStore.saveModel(sourceUri);
    const displayName: string = this.assetStore.extractDisplayName(sourceUri);

    // T-3D.3: 读取沙箱文件验证
    let modelInfo: GltfModelInfo;
    let compatibilityAnalysis: ModelCompatibilityAnalysis | null = null;
    let conversionResult: ModelConversionResult | null = null;
    let loadableUri: string = newUri;
    try {
      const buffer: ArrayBuffer = await this.readModelFile(newUri);
      const result: GltfValidationResult = GltfValidator.validate(buffer);
      if (!result.valid) {
        // 验证失败:删除已保存文件,抛出清晰错误
        await this.assetStore.deleteModelByUri(newUri);
        Logger.error(LOG_TAG, 'importModel validation failed: ' + result.errorMessage);
        throw new Error('模型格式无效: ' + result.errorMessage);
      }
      modelInfo = result.modelInfo;
      // T-3D.4A: 检查不支持的必需扩展(不可转换)
      if (modelInfo.unsupportedRequiredExtensions.length > 0) {
        await this.assetStore.deleteModelByUri(newUri);
        const extList: string = modelInfo.unsupportedRequiredExtensions.join(', ');
        Logger.error(LOG_TAG, 'importModel rejected: unsupported required extensions: ' + extList);
        throw new Error('该模型依赖当前版本不支持的 glTF 扩展: ' + extList
          + '。请导出为不使用该压缩扩展的标准 GLB 2.0,或等待转换模块更新。');
      }
      // T-3D.6C-C: 检查可转换扩展(EXT_meshopt_compression / KHR_mesh_quantization)
      const hasConvertible: boolean = modelInfo.convertibleRequiredExtensions.length > 0
        || modelInfo.convertibleUsedExtensions.length > 0;
      if (hasConvertible) {
        if (this.compatibilityService === null) {
          await this.assetStore.deleteModelByUri(newUri);
          const extList: string = modelInfo.convertibleUsedExtensions.join(', ');
          throw new Error('模型使用压缩网格扩展(' + extList
            + '),但兼容转换服务不可用。请导出为标准 GLB 2.0。');
        }
        // 执行兼容性预处理
        const filePath: string = newUri.startsWith('file://')
          ? newUri.substring('file://'.length) : newUri;
        const mode: ModelConversionMode = await this.compatibilityService.getConversionMode();
        const loadableResult = await this.compatibilityService.getLoadablePath(filePath, mode, onProgress);
        compatibilityAnalysis = loadableResult.analysis;
        conversionResult = loadableResult.conversion;
        if (loadableResult.path.length === 0) {
          // 转换失败或被拒绝
          await this.assetStore.deleteModelByUri(newUri);
          const reason: string = conversionResult !== null
            ? conversionResult.errorMessage
            : (compatibilityAnalysis !== null ? compatibilityAnalysis.errorMessage : '转换失败');
          Logger.error(LOG_TAG, 'importModel conversion failed: ' + reason);
          throw new Error(reason);
        }
        // 转换成功:用转换后的路径
        loadableUri = 'file://' + loadableResult.path;
        // 重新读取转换后的 modelInfo(扩展已移除,Bounds 可能变化)
        const convertedBuffer: ArrayBuffer = await this.readModelFile(loadableUri);
        const convertedValidation: GltfValidationResult = GltfValidator.validate(convertedBuffer);
        if (convertedValidation.valid) {
          modelInfo = convertedValidation.modelInfo;
        }
        Logger.info(LOG_TAG, 'importModel converted, loadableUri=' + loadableUri
          + ', removed=[' + (conversionResult !== null ? conversionResult.removedExtensions.join(',') : '')
          + ']');
      }
      Logger.info(LOG_TAG, 'importModel validation ok: meshes=' + modelInfo.meshCount
        + ', materials=' + modelInfo.materialCount
        + ', animations=' + modelInfo.animationCount
        + ', nodes=' + modelInfo.nodeCount
        + ', hasBounds=' + (modelInfo.boundsMin !== null));
    } catch (e) {
      // 读取或验证异常:确保删除已保存文件
      try {
        await this.assetStore.deleteModelByUri(newUri);
      } catch (_ignore) {
        // ignore
      }
      const msg: string = (e as Error)?.message ?? 'validate failed';
      Logger.error(LOG_TAG, 'importModel validate error: ' + msg);
      throw new Error('模型验证失败: ' + msg);
    }

    // 读取旧 URI(用于稍后删除旧文件)
    const oldUri: string = await this.preferences.getString(PREF_KEY_MODEL_URI, '');

    // 写入 Preferences(使用转换后的 URI)
    await this.preferences.putString(PREF_KEY_MODEL_URI, loadableUri);
    await this.preferences.putString(PREF_KEY_MODEL_DISPLAY_NAME, displayName);

    // 删除旧文件(失败不影响导入结果)
    if (oldUri.length > 0 && oldUri !== loadableUri && oldUri !== newUri) {
      try {
        await this.assetStore.deleteModelByUri(oldUri);
      } catch (e) {
        Logger.warn(LOG_TAG, 'delete old model failed: ' + (e as Error)?.message);
      }
    }

    // T-3D.4A: 计算自适应显示配置并保存为该 modelId 的默认配置
    const autoFitConfig: Character3DDisplayConfig = this.computeAutoFitConfig(modelInfo);
    await this.ensureModelDefaultConfig(displayName, autoFitConfig);

    Logger.info(LOG_TAG, 'importModel ok, displayName=' + displayName
      + ', converted=' + (conversionResult !== null));
    return {
      modelUri: loadableUri,
      displayName: displayName,
      modelInfo: modelInfo,
      autoFitConfig: autoFitConfig,
      compatibilityAnalysis: compatibilityAnalysis,
      conversionResult: conversionResult,
      sourceSha256: compatibilityAnalysis !== null ? compatibilityAnalysis.sourceSha256 : ''
    };
  }

  /**
   * 清除当前模型(删除文件 + 清空 Preferences)。
   * 未导入时静默成功。
   */
  async clearModel(): Promise<void> {
    const uri: string = await this.preferences.getString(PREF_KEY_MODEL_URI, '');
    if (uri.length > 0) {
      try {
        await this.assetStore.deleteModelByUri(uri);
      } catch (e) {
        Logger.warn(LOG_TAG, 'clearModel delete file failed: ' + (e as Error)?.message);
      }
    }
    await this.preferences.delete(PREF_KEY_MODEL_URI);
    await this.preferences.delete(PREF_KEY_MODEL_DISPLAY_NAME);
    Logger.info(LOG_TAG, 'clearModel ok');
  }

  /**
   * 从 rawfile 加载内置测试模型(用于 T-3D.2/T-3D.3 设备验证)。
   *
   * 流程:
   * 1. 通过 resourceManager 读取 rawfile/test_model.glb 到 ArrayBuffer
   * 2. T-3D.3: 调用 GltfValidator 验证格式
   * 3. T-3D.4A: 检查 unsupportedRequiredExtensions
   * 4. 验证失败:抛出错误(不保存文件)
   * 5. 验证成功:调用 assetStore.saveModelFromBuffer 写入沙箱
   * 6. 删除旧模型文件
   * 7. 持久化新 URI + 固定显示名到 Preferences
   * 8. T-3D.4A: 计算自适应配置并保存为该 modelId 默认配置
   *
   * @returns 导入结果(包含模型摘要信息和自适应配置)
   */
  async importFromRawfile(): Promise<Character3DImportResult> {
    return this.importFromRawfileByName(RAWFILE_TEST_MODEL_NAME, RAWFILE_TEST_MODEL_DISPLAY_NAME);
  }

  /**
   * T-3D.4A: 从 rawfile 按指定文件名加载模型(用于设备验收时导入真实模型)。
   *
   * 模拟器无 root 权限,无法访问 Download 目录,改用 rawfile 方式加载真实模型。
   * 这对应任务说明"情况 C":HarmonyOS 3D API 通过私有沙箱路径加载,rawfile 作为源。
   *
   * @param fileName rawfile 中的文件名(如 'teacher-love.glb')
   * @param displayName 显示名(用于 UI 和 modelId 隔离)
   * @returns 导入结果
   */
  async importFromRawfileByName(
    fileName: string, displayName: string
  ): Promise<Character3DImportResult> {
    if (fileName.length === 0) {
      throw new Error('fileName must not be empty');
    }
    // 读取旧 URI(用于稍后删除旧文件)
    const oldUri: string = await this.preferences.getString(PREF_KEY_MODEL_URI, '');

    // 从 rawfile 读取模型
    const buffer: ArrayBuffer = await this.readRawfileToBuffer(fileName);
    Logger.info(LOG_TAG, 'importFromRawfileByName: rawfile read, size=' + buffer.byteLength);

    // T-3D.3: 验证 GLB 格式
    const result: GltfValidationResult = GltfValidator.validate(buffer);
    if (!result.valid) {
      Logger.error(LOG_TAG, 'importFromRawfileByName validation failed: ' + result.errorMessage);
      throw new Error('模型格式无效: ' + result.errorMessage);
    }
    const modelInfo: GltfModelInfo = result.modelInfo;
    // T-3D.4A: 检查不支持的必需扩展
    if (modelInfo.unsupportedRequiredExtensions.length > 0) {
      const extList: string = modelInfo.unsupportedRequiredExtensions.join(', ');
      Logger.error(LOG_TAG, 'importFromRawfileByName rejected: unsupported extensions: ' + extList);
      throw new Error('该模型依赖当前版本不支持的 glTF 扩展: ' + extList);
    }
    Logger.info(LOG_TAG, 'importFromRawfileByName validation ok: meshes=' + modelInfo.meshCount
      + ', materials=' + modelInfo.materialCount
      + ', animations=' + modelInfo.animationCount
      + ', nodes=' + modelInfo.nodeCount
      + ', hasBounds=' + (modelInfo.boundsMin !== null));

    // 写入沙箱
    const ext: string = '.glb';
    const newUri: string = await this.assetStore.saveModelFromBuffer(
      buffer, ext, displayName
    );

    // 写入 Preferences
    await this.preferences.putString(PREF_KEY_MODEL_URI, newUri);
    await this.preferences.putString(PREF_KEY_MODEL_DISPLAY_NAME, displayName);

    // 删除旧文件(失败不影响导入结果)
    if (oldUri.length > 0 && oldUri !== newUri) {
      try {
        await this.assetStore.deleteModelByUri(oldUri);
      } catch (e) {
        Logger.warn(LOG_TAG, 'delete old model failed: ' + (e as Error)?.message);
      }
    }

    // T-3D.4A: 计算自适应配置并保存为该 modelId 默认配置
    const autoFitConfig: Character3DDisplayConfig = this.computeAutoFitConfig(modelInfo);
    await this.ensureModelDefaultConfig(displayName, autoFitConfig);

    Logger.info(LOG_TAG, 'importFromRawfileByName ok, name=' + displayName);
    return {
      modelUri: newUri,
      displayName: displayName,
      modelInfo: modelInfo,
      autoFitConfig: autoFitConfig,
      compatibilityAnalysis: null,
      conversionResult: null,
      sourceSha256: ''
    } as Character3DImportResult;
  }

  /**
   * 读取沙箱中的模型文件为 ArrayBuffer(用于验证)。
   */
  private async readModelFile(modelUri: string): Promise<ArrayBuffer> {
    let path: string = modelUri;
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
    }
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
   * 通过 resourceManager 读取 rawfile 文件为 ArrayBuffer。
   */
  private async readRawfileToBuffer(fileName: string): Promise<ArrayBuffer> {
    // 使用 Promise 形式的 getRawFileContent API
    const data: Uint8Array = await this.appContext.resourceManager.getRawFileContent(fileName);
    // Uint8Array -> ArrayBuffer(显式拷贝,避免 ArrayBufferLike 类型问题)
    const ab: ArrayBuffer = new ArrayBuffer(data.byteLength);
    const view: Uint8Array = new Uint8Array(ab);
    view.set(data);
    return ab;
  }

  /**
   * T-3D.4A: 根据 GltfModelInfo 计算自适应显示配置。
   * Bounds 非法时返回全局默认配置。
   *
   * @param modelInfo GLTF 模型摘要
   * @returns 自适应显示配置
   */
  computeAutoFitConfig(modelInfo: GltfModelInfo): Character3DDisplayConfig {
    const bounds = computeBoundsFromGltf(modelInfo);
    const config: Character3DDisplayConfig = computeAutoFitDisplayConfig(bounds);
    return sanitizeDisplayConfig(config);
  }

  /**
   * T-3D.4A: 确保该 modelId 有默认配置。
   * 若该 modelId 已有保存的配置,保留用户配置;否则保存 autoFit 作为默认。
   *
   * @param modelId 模型标识(使用 displayName)
   * @param autoFitConfig 自适应默认配置
   */
  async ensureModelDefaultConfig(
    modelId: string, autoFitConfig: Character3DDisplayConfig
  ): Promise<void> {
    if (modelId.length === 0) {
      return;
    }
    try {
      const key: string = this.displayConfigKey(modelId);
      const existing: string = await this.preferences.getString(key, '');
      if (existing.length === 0) {
        // 首次导入该模型,保存 autoFit 作为默认配置
        const json: string = serializeDisplayConfig(autoFitConfig);
        await this.preferences.putString(key, json);
        Logger.info(LOG_TAG, 'ensureModelDefaultConfig: saved autofit for modelId=' + modelId);
      } else {
        Logger.info(LOG_TAG, 'ensureModelDefaultConfig: modelId=' + modelId + ' already has config');
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'ensureModelDefaultConfig failed: ' + (e as Error)?.message);
    }
  }

  /**
   * T-3D.4A: 读取指定 modelId 的显示配置。
   * 未配置或损坏时返回默认配置(全局默认,非自适应)。
   *
   * @param modelId 模型标识(使用 displayName);空字符串时返回全局默认
   * @returns 显示配置
   */
  async getDisplayConfig(modelId: string): Promise<Character3DDisplayConfig> {
    if (modelId.length === 0) {
      return createDefaultDisplayConfig();
    }
    try {
      const key: string = this.displayConfigKey(modelId);
      const json: string = await this.preferences.getString(key, '');
      if (json.length === 0) {
        return createDefaultDisplayConfig();
      }
      return deserializeDisplayConfig(json);
    } catch (e) {
      Logger.warn(LOG_TAG, 'getDisplayConfig failed, fallback: ' + (e as Error)?.message);
      return createDefaultDisplayConfig();
    }
  }

  /**
   * T-3D.4A: 保存指定 modelId 的显示配置。
   * 写入前先 sanitize,避免非法值落盘。
   * 仅当与现有配置不同时才写入,减少磁盘 IO。
   *
   * @param modelId 模型标识(使用 displayName)
   * @param config 待保存的配置(可能含非法值,会被 sanitize)
   * @returns 实际落盘的 sanitized 配置
   */
  async saveDisplayConfig(
    modelId: string, config: Character3DDisplayConfig
  ): Promise<Character3DDisplayConfig> {
    if (modelId.length === 0) {
      return sanitizeDisplayConfig(config);
    }
    const safe: Character3DDisplayConfig = sanitizeDisplayConfig(config);
    try {
      const key: string = this.displayConfigKey(modelId);
      const existing: Character3DDisplayConfig = await this.getDisplayConfig(modelId);
      if (isDisplayConfigEqual(existing, safe)) {
        return safe;
      }
      const json: string = serializeDisplayConfig(safe);
      await this.preferences.putString(key, json);
      Logger.info(LOG_TAG, 'saveDisplayConfig ok for modelId=' + modelId);
    } catch (e) {
      Logger.error(LOG_TAG, 'saveDisplayConfig failed: ' + (e as Error)?.message);
    }
    return safe;
  }

  /**
   * T-3D.4A: 重置指定 modelId 的显示配置为该模型的自适应默认值。
   * 删除该 modelId 的保存配置,下次读取时回退全局默认。
   * 若提供 modelInfo,则重新计算并保存自适应配置。
   *
   * @param modelId 模型标识
   * @param modelInfo 可选,用于重新计算自适应配置
   * @returns 重置后的配置(自适应或全局默认)
   */
  async resetDisplayConfig(
    modelId: string, modelInfo?: GltfModelInfo
  ): Promise<Character3DDisplayConfig> {
    if (modelId.length === 0) {
      return createDefaultDisplayConfig();
    }
    try {
      const key: string = this.displayConfigKey(modelId);
      await this.preferences.delete(key);
      if (modelInfo !== undefined && modelInfo !== null) {
        const autoFit: Character3DDisplayConfig = this.computeAutoFitConfig(modelInfo);
        const json: string = serializeDisplayConfig(autoFit);
        await this.preferences.putString(key, json);
        Logger.info(LOG_TAG, 'resetDisplayConfig: saved autofit for modelId=' + modelId);
        return autoFit;
      }
      Logger.info(LOG_TAG, 'resetDisplayConfig: deleted for modelId=' + modelId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'resetDisplayConfig failed: ' + (e as Error)?.message);
    }
    return createDefaultDisplayConfig();
  }

  /**
   * T-3D.4A: 构造 per-model 显示配置的 Preferences key。
   */
  private displayConfigKey(modelId: string): string {
    return PREF_KEY_DISPLAY_CONFIG_PREFIX + modelId;
  }
}
