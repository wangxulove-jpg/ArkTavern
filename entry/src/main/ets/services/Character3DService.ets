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
import {
  computeBoundsFromGltf,
  computeAutoFitDisplayConfig,
  analyzeBoundsAnomalies,
  BoundsAnomalyReport
} from '../models/character3d/ModelBounds';
import { Character3DModelCompatibilityService } from './Character3DModelCompatibilityService';
import {
  ModelCompatibilityStatus,
  ModelConversionMode,
  ModelConversionProgress,
  ModelConversionResult,
  ModelCompatibilityAnalysis,
  getConversionStageMessage
} from '../models/character3d/ModelCompatibility';
import { ModelImportDiagnostics, ModelImportDiagnosticReport } from '../parser/ModelImportDiagnostics';
import {
  ModelImportErrorCode,
  ModelImportStage,
  ModelInspectionResult,
  getErrorMessage
} from '../models/character3d/ModelImportResult';
import {
  ModelCapabilityReport,
  ModelCapabilityInput,
  analyzeModelCapability
} from '../models/character3d/ModelCapabilityReport';
import { BoneMappingResult } from '../models/character3d/HumanoidBone';
import { mapBones } from '../models/character3d/HumanoidBoneMapper';
import { VrmAsset } from '../models/character3d/vrm/VrmAsset';
import { VrmVersion, isVrm } from '../models/character3d/vrm/VrmVersion';
import { importVrm } from '../parser/VRMImporter';
import { detectVrm } from '../parser/VrmDetector';
import {
  resolveVrmHumanoid,
  vrmParseResultToBoneMappingResult,
  VrmHumanoidParseResult
} from '../parser/VrmHumanoidResolver';
import { computeSha256Base64 } from '../utils/ShaUtil';

const LOG_TAG: string = 'Character3DService';

/** Preferences key:当前 3D 模型文件 URI(空字符串表示未导入) */
const PREF_KEY_MODEL_URI: string = 'character_3d_model_uri';
/** Preferences key:当前 3D 模型显示名(用于 UI 展示) */
const PREF_KEY_MODEL_DISPLAY_NAME: string = 'character_3d_model_display_name';
/** Preferences key 前缀:3D 模型显示配置(per-model,后接 modelId) */
const PREF_KEY_DISPLAY_CONFIG_PREFIX: string = 'character_3d_display_config_';
/** T-3D.6E: Preferences key:当前模型能力分层报告(JSON 字符串,全局单模型) */
const PREF_KEY_CAPABILITY_REPORT: string = 'character_3d_capability_report';
/** T-4.2C: Preferences key 前缀:按 Avatar 隔离的能力报告(后接 avatarId_sourceSha256 前 16 位) */
const PREF_KEY_CAPABILITY_REPORT_AVATAR_PREFIX: string = 'character_3d_cap_report_avatar_';
/** T-3D.6E: Preferences key:当前模型自动骨骼映射结果(JSON 字符串) */
const PREF_KEY_BONE_MAPPING: string = 'character_3d_bone_mapping';
/** T-4.1: Preferences key:VRM 资产 JSON(按 sourceSha256 前 16 位区分) */
const PREF_KEY_VRM_ASSET_PREFIX: string = 'character_3d_vrm_asset_';
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
 * T-4.1: VRM 与骨骼映射综合解析结果(resolveVrmAndBoneMapping 内部使用)。
 */
interface VrmAndBoneMappingResult {
  vrmAsset: VrmAsset | null;
  boneMapping: BoneMappingResult;
  isVrm: boolean;
  vrmVersion: VrmVersion;
  declaredHumanBoneCount: number;
  validHumanBoneCount: number;
  providerSource: string;
}

/**
 * T-4.1 A10: VRM 重解析结果(供 HumanoidMappingViewModel 使用)。
 */
export interface VrmReparseResult {
  /** 是否 VRM */
  isVrm: boolean;
  /** VRM 版本 */
  vrmVersion: VrmVersion;
  /** VRM 资产(非 VRM 时为 null) */
  vrmAsset: VrmAsset | null;
  /** 骨骼映射结果 */
  boneMapping: BoneMappingResult | null;
  /** VRM 声明骨骼数 */
  declaredHumanBoneCount: number;
  /** VRM 有效骨骼数 */
  validHumanBoneCount: number;
  /** HumanoidProvider 来源 */
  providerSource: string;
  /** 错误信息(空表示成功) */
  error: string;
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
  /** T-3D.6D: 详细扫描结果(到达扫描阶段后非空) */
  inspection: ModelInspectionResult | null;
  /** T-3D.6D: 导入过程中的警告列表(含 Bounds 异常、扩展警告等) */
  warnings: string[];
  /** T-3D.6D: 是否命中已有缓存(重复导入相同 sourceSha256) */
  fromCache: boolean;
  /** T-3D.6E: 模型能力分层报告(12 维度,UI 可分别显示) */
  capabilityReport: ModelCapabilityReport | null;
  /** T-3D.6E: 自动骨骼映射结果(无骨架时为 null) */
  boneMapping: BoneMappingResult | null;
  /** T-4.1: 是否 VRM 模型 */
  isVrm: boolean;
  /** T-4.1: VRM 版本(NonVrm 时为 NonVrm) */
  vrmVersion: VrmVersion;
  /** T-4.1: VRM 资产(非 VRM 时为 null) */
  vrmAsset: VrmAsset | null;
  /** T-4.1: VRM 声明骨骼数 */
  declaredHumanBoneCount: number;
  /** T-4.1: VRM 有效骨骼数 */
  validHumanBoneCount: number;
  /** T-4.1: HumanoidProvider 来源(VrmDeclared/ManualOverride/AutoDetected/None) */
  humanoidProviderSource: string;
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
   * T-3D.6F-A: 读取当前模型 GLB 文件的 ArrayBuffer(用于表面点选)。
   *
   * @returns GLB ArrayBuffer,模型不存在时返回 null
   */
  async getGlbBuffer(): Promise<ArrayBuffer | null> {
    try {
      const config: Character3DModelConfig = await this.getConfig();
      if (config.modelUri.length === 0 || !config.fileExists) {
        return null;
      }
      return await this.readModelFile(config.modelUri);
    } catch (e) {
      Logger.warn(LOG_TAG, 'getGlbBuffer failed: ' + (e as Error)?.message);
      return null;
    }
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
   * 3. T-3D.6D: 调用 ModelImportDiagnostics 做容器+语义+扫描严格诊断
   * 4. T-3D.4A: 检查 unsupportedRequiredExtensions,若有则拒绝并清理
   * 5. T-3D.6C-C: 检查 convertibleRequiredExtensions,若有则调用兼容性预处理
   * 6. 验证失败:删除已保存文件,抛出包含详细原因的错误
   * 7. 验证成功:删除旧模型文件,将新 URI + 显示名写入 Preferences
   * 8. T-3D.4A: 计算自适应显示配置并保存为该 modelId 的默认配置(若该 modelId 首次导入)
   * 9. T-3D.6D: 计算 Bounds 异常警告(极小/极大/原点偏移/NaN)
   *
   * @param sourceUri DocumentViewPicker 返回的源 URI
   * @param onProgress T-3D.6C-C 转换进度回调(可选)
   * @param keepOldModel T-4.1 阶段 B: 是否保留旧模型文件(AvatarLibraryService 导入多模型时传 true,
   *        避免删除前一个 Avatar 的模型文件;默认 false 保持向后兼容)
   * @returns 导入结果(包含模型摘要信息和自适应配置)
   */
  async importModel(
    sourceUri: string,
    onProgress?: (progress: ModelConversionProgress) => void,
    keepOldModel: boolean = false
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
    let inspection: ModelInspectionResult | null = null;
    const importWarnings: string[] = [];
    let fromCache: boolean = false;
    // T-4.1: gltfJson(转换后优先),供 VRM 检测和骨骼解析使用
    let effectiveGltfJson: Record<string, Object> | null = null;
    try {
      const buffer: ArrayBuffer = await this.readModelFile(newUri);

      // T-3D.6D: 严格诊断(GLB 容器 + glTF 语义 + 结构扫描)
      // GltfValidator 仍作为主验证器(向后兼容),诊断器作为补充校验
      const diagnostics: ModelImportDiagnosticReport = ModelImportDiagnostics.diagnose(buffer);
      if (!diagnostics.passed) {
        await this.assetStore.deleteModelByUri(newUri);
        const errCode: ModelImportErrorCode = diagnostics.errorCode ?? ModelImportErrorCode.Unknown;
        const userMsg: string = getErrorMessage(errCode);
        Logger.error(LOG_TAG, 'importModel diagnostics failed: code=' + errCode
          + ', msg=' + diagnostics.diagnosticMessage);
        throw new Error(userMsg + '(' + diagnostics.diagnosticMessage + ')');
      }
      inspection = diagnostics.inspection;
      for (let i: number = 0; i < diagnostics.warnings.length; i++) {
        importWarnings.push(diagnostics.warnings[i]);
      }

      const result: GltfValidationResult = GltfValidator.validate(buffer);
      if (!result.valid) {
        // 验证失败:删除已保存文件,抛出清晰错误
        await this.assetStore.deleteModelByUri(newUri);
        Logger.error(LOG_TAG, 'importModel validation failed: ' + result.errorMessage);
        throw new Error('模型格式无效: ' + result.errorMessage);
      }
      modelInfo = result.modelInfo;
      // T-4.1: 保留原始 gltfJson(优先使用转换后的,转换会移除压缩扩展但保留 VRM 扩展)
      effectiveGltfJson = result.gltfJson;
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
        fromCache = conversionResult !== null && conversionResult.fromCache;
        // 重新读取转换后的 modelInfo(扩展已移除,Bounds 可能变化)
        const convertedBuffer: ArrayBuffer = await this.readModelFile(loadableUri);
        const convertedValidation: GltfValidationResult = GltfValidator.validate(convertedBuffer);
        if (convertedValidation.valid) {
          modelInfo = convertedValidation.modelInfo;
          // T-4.1: 转换后 VRM 扩展仍然保留(仅移除 meshopt/quantization),
          // 使用转换后的 gltfJson 进行 VRM 检测更准确
          effectiveGltfJson = convertedValidation.gltfJson;
        }
        Logger.info(LOG_TAG, 'importModel converted, loadableUri=' + loadableUri
          + ', removed=[' + (conversionResult !== null ? conversionResult.removedExtensions.join(',') : '')
          + '], fromCache=' + fromCache);
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

    // T-3D.6D: 检测 Bounds 异常并追加警告
    const bounds = computeBoundsFromGltf(modelInfo);
    const anomalyReport: BoundsAnomalyReport = analyzeBoundsAnomalies(bounds);
    if (anomalyReport.hasAnomaly) {
      for (let i: number = 0; i < anomalyReport.warnings.length; i++) {
        importWarnings.push(anomalyReport.warnings[i]);
      }
      Logger.info(LOG_TAG, 'importModel bounds anomaly: '
        + anomalyReport.anomalyTypes.join(','));
    }

    // 读取旧 URI(用于稍后删除旧文件)
    const oldUri: string = await this.preferences.getString(PREF_KEY_MODEL_URI, '');

    // 写入 Preferences(使用转换后的 URI)
    await this.preferences.putString(PREF_KEY_MODEL_URI, loadableUri);
    await this.preferences.putString(PREF_KEY_MODEL_DISPLAY_NAME, displayName);

    // 删除旧文件(失败不影响导入结果)
    // T-4.1 阶段 B: keepOldModel=true 时跳过(AvatarLibraryService 导入多模型时使用)
    if (!keepOldModel && oldUri.length > 0 && oldUri !== loadableUri && oldUri !== newUri) {
      try {
        await this.assetStore.deleteModelByUri(oldUri);
      } catch (e) {
        Logger.warn(LOG_TAG, 'delete old model failed: ' + (e as Error)?.message);
      }
    }

    // T-3D.4A: 计算自适应显示配置并保存为该 modelId 的默认配置
    const autoFitConfig: Character3DDisplayConfig = this.computeAutoFitConfig(modelInfo);
    await this.ensureModelDefaultConfig(displayName, autoFitConfig);

    // T-4.1: VRM 显式骨骼闭环 + 能力分层报告
    // 优先使用 VRM 显式 HumanBones(VrmDeclared),非 VRM 或 VRM 无效骨骼时回退到名称匹配
    let boneMapping: BoneMappingResult | null = null;
    let capabilityReport: ModelCapabilityReport | null = null;
    let vrmAsset: VrmAsset | null = null;
    let isVrm: boolean = false;
    let vrmVersion: VrmVersion = VrmVersion.NonVrm;
    let declaredHumanBoneCount: number = 0;
    let validHumanBoneCount: number = 0;
    let humanoidProviderSource: string = 'None';
    try {
      const sourceSha: string = compatibilityAnalysis !== null ? compatibilityAnalysis.sourceSha256 : '';
      const vrmAndBone = this.resolveVrmAndBoneMapping(
        effectiveGltfJson, modelInfo, displayName, sourceSha
      );
      boneMapping = vrmAndBone.boneMapping;
      vrmAsset = vrmAndBone.vrmAsset;
      isVrm = vrmAndBone.isVrm;
      vrmVersion = vrmAndBone.vrmVersion;
      declaredHumanBoneCount = vrmAndBone.declaredHumanBoneCount;
      validHumanBoneCount = vrmAndBone.validHumanBoneCount;
      humanoidProviderSource = vrmAndBone.providerSource;

      // T-4.1: 持久化 VRM 资产(供 HumanoidMappingViewModel 读取)
      if (vrmAsset !== null) {
        await this.saveVrmAsset(vrmAsset);
      }

      const hasRenderableMesh: boolean = modelInfo.meshCount > 0;
      const capabilityInput: ModelCapabilityInput = {
        modelInfo: modelInfo,
        gltfJson: null,
        inspection: inspection,
        boneMapping: boneMapping,
        sceneLoaded: false,
        hasRenderableMesh: hasRenderableMesh,
        hasManualMapping: false,
        manualMappingValid: false,
        vrmAsset: vrmAsset
      };
      capabilityReport = analyzeModelCapability(capabilityInput);
      await this.preferences.putString(
        PREF_KEY_CAPABILITY_REPORT, JSON.stringify(capabilityReport)
      );
      await this.preferences.putString(
        PREF_KEY_BONE_MAPPING, JSON.stringify(boneMapping)
      );
      Logger.info(LOG_TAG, 'importModel capability: skeleton='
        + capabilityReport.skeletonPresent
        + ', autoMap=' + capabilityReport.humanoidAutoMapping
        + ', motion=' + capabilityReport.motionRetargeting
        + ', isVrm=' + isVrm
        + ', vrmVersion=' + vrmVersion
        + ', validBones=' + validHumanBoneCount
        + ', providerSource=' + humanoidProviderSource);
    } catch (e) {
      Logger.warn(LOG_TAG, 'importModel capability analysis failed: '
        + (e as Error)?.message);
    }

    Logger.info(LOG_TAG, 'importModel ok, displayName=' + displayName
      + ', converted=' + (conversionResult !== null)
      + ', warnings=' + importWarnings.length);
    return {
      modelUri: loadableUri,
      displayName: displayName,
      modelInfo: modelInfo,
      autoFitConfig: autoFitConfig,
      compatibilityAnalysis: compatibilityAnalysis,
      conversionResult: conversionResult,
      sourceSha256: compatibilityAnalysis !== null ? compatibilityAnalysis.sourceSha256 : '',
      inspection: inspection,
      warnings: importWarnings,
      fromCache: fromCache,
      capabilityReport: capabilityReport,
      boneMapping: boneMapping,
      isVrm: isVrm,
      vrmVersion: vrmVersion,
      vrmAsset: vrmAsset,
      declaredHumanBoneCount: declaredHumanBoneCount,
      validHumanBoneCount: validHumanBoneCount,
      humanoidProviderSource: humanoidProviderSource
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
    await this.preferences.delete(PREF_KEY_CAPABILITY_REPORT);
    await this.preferences.delete(PREF_KEY_BONE_MAPPING);
    Logger.info(LOG_TAG, 'clearModel ok');
  }

  /**
   * T-4.1 阶段 B: 将已存在于沙箱的模型文件设为当前激活模型(不复制文件,不重新验证)。
   *
   * 用途:AvatarLibraryService.setActiveAvatar 切换激活模型时调用,
   * 模型文件已在首次导入时复制到沙箱,此处仅更新 Preferences 指针。
   *
   * 与 importModel 的区别:
   * - 不调用 saveModel(不复制文件)
   * - 不调用 GltfValidator(不重新验证)
   * - 不调用 VRM 解析(不重新解析骨骼)
   * - 清空 capabilityReport 和 boneMapping(避免显示前一个模型的过期数据)
   *
   * 副作用:capabilityReport 和 boneMapping 被清空,
   * HumanoidMappingPage 打开时会显示"未检测到";如需完整元数据,
   * 用户可在该页面重新触发自动匹配。
   *
   * @param modelUri 沙箱模型文件 URI(file:// 开头,必须已存在)
   * @param displayName 显示名
   */
  async setCurrentModelByUri(modelUri: string, displayName: string): Promise<void> {
    if (modelUri.length === 0) {
      throw new Error('modelUri must not be empty');
    }
    if (!this.assetStore.exists(modelUri)) {
      throw new Error('模型文件不存在: ' + displayName);
    }
    await this.preferences.putString(PREF_KEY_MODEL_URI, modelUri);
    await this.preferences.putString(PREF_KEY_MODEL_DISPLAY_NAME, displayName);
    // 清空能力报告和骨骼映射(属于前一个模型,避免显示过期数据)
    await this.preferences.delete(PREF_KEY_CAPABILITY_REPORT);
    await this.preferences.delete(PREF_KEY_BONE_MAPPING);
    Logger.info(LOG_TAG, 'setCurrentModelByUri ok: name=' + displayName);
  }

  /**
   * T-3D.6E: 读取持久化的能力分层报告。
   *
   * @returns ModelCapabilityReport 或 null(未导入或解析失败)
   */
  async getCapabilityReport(): Promise<ModelCapabilityReport | null> {
    try {
      const json: string = await this.preferences.getString(PREF_KEY_CAPABILITY_REPORT, '');
      if (json.length === 0) {
        return null;
      }
      return JSON.parse(json) as ModelCapabilityReport;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getCapabilityReport failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * T-4.2C: 读取按 Avatar 隔离的能力报告。
   *
   * 与 getCapabilityReport() 的区别:
   * - getCapabilityReport 读取全局键,切换 Avatar 时被清空
   * - 本方法按 avatarId + sourceSha256 读取,跨 Avatar 切换不丢失
   *
   * @param avatarId Avatar ID
   * @param sourceSha256 模型文件 SHA-256
   * @returns ModelCapabilityReport 或 null(未生成或解析失败)
   */
  async getCapabilityReportForAvatar(
    avatarId: string,
    sourceSha256: string
  ): Promise<ModelCapabilityReport | null> {
    if (avatarId.length === 0) {
      return null;
    }
    try {
      const shaPart: string = sourceSha256.length > 0 ? sourceSha256.substring(0, 16) : 'nosha';
      const key: string = PREF_KEY_CAPABILITY_REPORT_AVATAR_PREFIX + avatarId + '_' + shaPart;
      const json: string = await this.preferences.getString(key, '');
      if (json.length === 0) {
        return null;
      }
      return JSON.parse(json) as ModelCapabilityReport;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getCapabilityReportForAvatar failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * T-4.2C: 保存按 Avatar 隔离的能力报告。
   */
  async saveCapabilityReportForAvatar(
    avatarId: string,
    sourceSha256: string,
    report: ModelCapabilityReport
  ): Promise<void> {
    if (avatarId.length === 0) {
      return;
    }
    try {
      const shaPart: string = sourceSha256.length > 0 ? sourceSha256.substring(0, 16) : 'nosha';
      const key: string = PREF_KEY_CAPABILITY_REPORT_AVATAR_PREFIX + avatarId + '_' + shaPart;
      await this.preferences.putString(key, JSON.stringify(report));
    } catch (e) {
      Logger.warn(LOG_TAG, 'saveCapabilityReportForAvatar failed: ' + (e as Error)?.message);
    }
  }

  /**
   * T-4.2C: 为指定 Avatar 的模型生成能力报告(按需生成,不依赖全局当前模型)。
   *
   * 流程:
   * 1. 读取模型文件并验证 GLB
   * 2. 执行 ModelInspector 扫描
   * 3. 解析 VRM + 骨骼映射
   * 4. 调用 analyzeModelCapability 生成报告
   * 5. 按 avatarId + sourceSha256 持久化
   *
   * @param modelUri 沙箱模型文件 URI(file://...)
   * @param displayName 显示名
   * @param sourceSha256 模型文件 SHA-256
   * @param avatarId Avatar ID
   * @returns ModelCapabilityReport 或 null(生成失败)
   */
  async generateCapabilityReportForAvatar(
    modelUri: string,
    displayName: string,
    sourceSha256: string,
    avatarId: string
  ): Promise<ModelCapabilityReport | null> {
    if (modelUri.length === 0 || avatarId.length === 0) {
      return null;
    }
    try {
      Logger.info(LOG_TAG, 'generateCapabilityReportForAvatar: avatarId=' + avatarId.substring(0, 8)
        + ', name=' + displayName);

      // 1. 读取并验证 GLB
      const buffer: ArrayBuffer = await this.readModelFile(modelUri);
      const result: GltfValidationResult = GltfValidator.validate(buffer);
      if (!result.valid || result.gltfJson === null) {
        Logger.warn(LOG_TAG, 'generateCapabilityReportForAvatar: GLB invalid');
        return null;
      }
      const modelInfo: GltfModelInfo = result.modelInfo;

      // 2. 扫描模型(使用 ModelImportDiagnostics 获取 inspection)
      let inspection: ModelInspectionResult | null = null;
      try {
        const diagnostics: ModelImportDiagnosticReport = ModelImportDiagnostics.diagnose(buffer);
        inspection = diagnostics.inspection;
      } catch (e) {
        Logger.warn(LOG_TAG, 'generateCapabilityReportForAvatar diagnostics failed: '
          + (e as Error)?.message);
      }

      // 3. 解析 VRM + 骨骼映射
      const vrmAndBone = this.resolveVrmAndBoneMapping(
        result.gltfJson, modelInfo, displayName, sourceSha256
      );
      if (vrmAndBone.vrmAsset !== null) {
        await this.saveVrmAsset(vrmAndBone.vrmAsset);
      }

      // 4. 生成能力报告
      const hasRenderableMesh: boolean = modelInfo.meshCount > 0;
      const capabilityInput: ModelCapabilityInput = {
        modelInfo: modelInfo,
        gltfJson: null,
        inspection: inspection,
        boneMapping: vrmAndBone.boneMapping,
        sceneLoaded: false,
        hasRenderableMesh: hasRenderableMesh,
        hasManualMapping: false,
        manualMappingValid: false,
        vrmAsset: vrmAndBone.vrmAsset
      };
      const report: ModelCapabilityReport = analyzeModelCapability(capabilityInput);

      // 5. 持久化(按 avatarId + sourceSha256)
      await this.saveCapabilityReportForAvatar(avatarId, sourceSha256, report);

      Logger.info(LOG_TAG, 'generateCapabilityReportForAvatar ok: skeleton='
        + report.skeletonPresent
        + ', autoMap=' + report.humanoidAutoMapping
        + ', motion=' + report.motionRetargeting
        + ', isVrm=' + vrmAndBone.isVrm
        + ', validBones=' + vrmAndBone.validHumanBoneCount);
      return report;
    } catch (e) {
      Logger.error(LOG_TAG, 'generateCapabilityReportForAvatar failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * T-3D.6E: 读取持久化的自动骨骼映射结果。
   *
   * @returns BoneMappingResult 或 null(未导入或解析失败)
   */
  async getBoneMapping(): Promise<BoneMappingResult | null> {
    try {
      const json: string = await this.preferences.getString(PREF_KEY_BONE_MAPPING, '');
      if (json.length === 0) {
        return null;
      }
      return JSON.parse(json) as BoneMappingResult;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getBoneMapping failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * T-4.1: 读取持久化的 VRM 资产。
   *
   * @param sourceSha256 模型文件 SHA-256
   * @returns VrmAsset 或 null
   */
  async getVrmAsset(sourceSha256: string): Promise<VrmAsset | null> {
    if (sourceSha256.length === 0) {
      return null;
    }
    try {
      const key: string = PREF_KEY_VRM_ASSET_PREFIX + sourceSha256.substring(0, 16);
      const json: string = await this.preferences.getString(key, '');
      if (json.length === 0) {
        return null;
      }
      return JSON.parse(json) as VrmAsset;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getVrmAsset failed: ' + (e as Error)?.message);
      return null;
    }
  }

  /**
   * T-4.1: 持久化 VRM 资产。
   */
  async saveVrmAsset(asset: VrmAsset): Promise<void> {
    if (!isVrm(asset.version) || asset.sourceSha256.length === 0) {
      return;
    }
    try {
      const key: string = PREF_KEY_VRM_ASSET_PREFIX + asset.sourceSha256.substring(0, 16);
      await this.preferences.putString(key, JSON.stringify(asset));
    } catch (e) {
      Logger.warn(LOG_TAG, 'saveVrmAsset failed: ' + (e as Error)?.message);
    }
  }

  /**
   * T-4.1 A10: 为当前模型重新解析 VRM Humanoid(用于"读取 VRM 标准骨骼"按钮)。
   *
   * 流程:
   * 1. 读取当前模型 URI
   * 2. 读取文件并验证 GLB → 获取 gltfJson
   * 3. 按内容检测 VRM
   * 4. 解析 HumanBones → 生成 VrmDeclared bindings(含 nodeIndex)
   * 5. 持久化 boneMapping 和 vrmAsset
   *
   * @returns VRM 重解析结果;非 VRM 或失败时返回 isVrm=false
   */
  async reparseVrmForCurrentModel(): Promise<VrmReparseResult> {
    const config: Character3DModelConfig = await this.getConfig();
    if (config.modelUri.length === 0 || !config.fileExists) {
      return {
        isVrm: false, vrmVersion: VrmVersion.NonVrm, vrmAsset: null,
        boneMapping: null, declaredHumanBoneCount: 0, validHumanBoneCount: 0,
        providerSource: 'None', error: '当前未导入模型'
      };
    }
    try {
      const buffer: ArrayBuffer = await this.readModelFile(config.modelUri);
      const result: GltfValidationResult = GltfValidator.validate(buffer);
      if (!result.valid || result.gltfJson === null) {
        return {
          isVrm: false, vrmVersion: VrmVersion.NonVrm, vrmAsset: null,
          boneMapping: null, declaredHumanBoneCount: 0, validHumanBoneCount: 0,
          providerSource: 'None', error: '模型文件无法解析'
        };
      }
      const vrmAndBone = this.resolveVrmAndBoneMapping(
        result.gltfJson, result.modelInfo, config.displayName, ''
      );
      // 持久化
      if (vrmAndBone.vrmAsset !== null) {
        await this.saveVrmAsset(vrmAndBone.vrmAsset);
      }
      if (vrmAndBone.boneMapping !== null) {
        await this.preferences.putString(
          PREF_KEY_BONE_MAPPING, JSON.stringify(vrmAndBone.boneMapping)
        );
      }
      Logger.info(LOG_TAG, 'reparseVrmForCurrentModel: isVrm=' + vrmAndBone.isVrm
        + ', validBones=' + vrmAndBone.validHumanBoneCount
        + ', providerSource=' + vrmAndBone.providerSource);
      return {
        isVrm: vrmAndBone.isVrm,
        vrmVersion: vrmAndBone.vrmVersion,
        vrmAsset: vrmAndBone.vrmAsset,
        boneMapping: vrmAndBone.boneMapping,
        declaredHumanBoneCount: vrmAndBone.declaredHumanBoneCount,
        validHumanBoneCount: vrmAndBone.validHumanBoneCount,
        providerSource: vrmAndBone.providerSource,
        error: ''
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'reparseVrmForCurrentModel error: ' + (e as Error)?.message);
      return {
        isVrm: false, vrmVersion: VrmVersion.NonVrm, vrmAsset: null,
        boneMapping: null, declaredHumanBoneCount: 0, validHumanBoneCount: 0,
        providerSource: 'None', error: (e as Error)?.message ?? 'unknown'
      };
    }
  }

  /**
   * T-4.2B: 为指定 URI 的模型重新解析 VRM Humanoid,不依赖全局 config。
   *
   * 与 reparseVrmForCurrentModel 的区别:
   * - 不读取全局 PREF_KEY_MODEL_URI,直接使用传入的 modelUri
   * - 不写入全局 PREF_KEY_BONE_MAPPING,避免覆盖其他 Avatar 的缓存
   * - VRM 资产仍按 sourceSha256 持久化(可跨 Avatar 复用)
   *
   * 用于 HumanoidMappingPage 按指定 avatarId 加载模型的场景。
   *
   * @param modelUri 沙箱模型文件 URI(file://...)
   * @param displayName 显示名(用于 BoneMappingResult.modelId)
   * @param sourceSha256 模型文件 SHA-256(用于 VRM 资产持久化)
   * @returns VRM 重解析结果;非 VRM 或失败时返回 isVrm=false
   */
  async reparseVrmForUri(
    modelUri: string,
    displayName: string,
    sourceSha256: string
  ): Promise<VrmReparseResult> {
    if (modelUri.length === 0) {
      return {
        isVrm: false, vrmVersion: VrmVersion.NonVrm, vrmAsset: null,
        boneMapping: null, declaredHumanBoneCount: 0, validHumanBoneCount: 0,
        providerSource: 'None', error: 'modelUri 为空'
      };
    }
    try {
      const buffer: ArrayBuffer = await this.readModelFile(modelUri);
      const result: GltfValidationResult = GltfValidator.validate(buffer);
      if (!result.valid || result.gltfJson === null) {
        return {
          isVrm: false, vrmVersion: VrmVersion.NonVrm, vrmAsset: null,
          boneMapping: null, declaredHumanBoneCount: 0, validHumanBoneCount: 0,
          providerSource: 'None', error: '模型文件无法解析'
        };
      }
      const vrmAndBone = this.resolveVrmAndBoneMapping(
        result.gltfJson, result.modelInfo, displayName, sourceSha256
      );
      // 仅持久化 VRM 资产(按 sourceSha256 隔离,可跨 Avatar 复用)
      // 不写入全局 PREF_KEY_BONE_MAPPING,避免覆盖其他 Avatar 缓存
      if (vrmAndBone.vrmAsset !== null) {
        await this.saveVrmAsset(vrmAndBone.vrmAsset);
      }
      Logger.info(LOG_TAG, 'reparseVrmForUri: isVrm=' + vrmAndBone.isVrm
        + ', validBones=' + vrmAndBone.validHumanBoneCount
        + ', providerSource=' + vrmAndBone.providerSource
        + ', name=' + displayName);
      return {
        isVrm: vrmAndBone.isVrm,
        vrmVersion: vrmAndBone.vrmVersion,
        vrmAsset: vrmAndBone.vrmAsset,
        boneMapping: vrmAndBone.boneMapping,
        declaredHumanBoneCount: vrmAndBone.declaredHumanBoneCount,
        validHumanBoneCount: vrmAndBone.validHumanBoneCount,
        providerSource: vrmAndBone.providerSource,
        error: ''
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'reparseVrmForUri error: ' + (e as Error)?.message);
      return {
        isVrm: false, vrmVersion: VrmVersion.NonVrm, vrmAsset: null,
        boneMapping: null, declaredHumanBoneCount: 0, validHumanBoneCount: 0,
        providerSource: 'None', error: (e as Error)?.message ?? 'unknown'
      };
    }
  }

  /**
   * T-4.1: 解析 VRM 并生成骨骼映射。
   *
   * 核心集成点:将 VRMImporter 接入导入流程。
   * - 检测 VRM 身份(按内容,非后缀)
   * - 调用 VRMImporter 解析 VrmAsset
   * - 将 VrmHumanoid 转换为 BoneBindingResult(confidence=1.0)
   * - 非 VRM 或 VRM 无有效骨骼时回退到 mapBones
   *
   * @param gltfJson glTF JSON 对象
   * @param modelInfo 模型摘要信息
   * @param displayName 显示名(modelId)
   * @param sourceSha256 模型文件 SHA-256(可能为空)
   * @returns VRM 解析结果 + 骨骼映射 + Provider 来源
   */
  private resolveVrmAndBoneMapping(
    gltfJson: Record<string, Object> | null,
    modelInfo: GltfModelInfo,
    displayName: string,
    sourceSha256: string
  ): VrmAndBoneMappingResult {
    let vrmAsset: VrmAsset | null = null;
    let isVrm: boolean = false;
    let vrmVersion: VrmVersion = VrmVersion.NonVrm;
    let declaredHumanBoneCount: number = 0;
    let validHumanBoneCount: number = 0;
    let providerSource: string = 'None';

    // 尝试 VRM 解析(按内容检测,非后缀)
    if (gltfJson !== null) {
      try {
        const vrmDetection = detectVrm(gltfJson);
        if (vrmDetection.isVrm) {
          isVrm = true;
          vrmVersion = vrmDetection.version;
          Logger.info(LOG_TAG, 'VRM detected by content: version=' + vrmVersion
            + ', specVersion=' + vrmDetection.specVersion
            + ', exporter=' + vrmDetection.exporterVersion);

          const vrmResult = importVrm({
            gltfJson: gltfJson,
            sourceSha256: sourceSha256,
            nodeNames: modelInfo.nodeNames,
            nodeCount: modelInfo.nodeCount,
            meshCount: modelInfo.meshCount,
            materialCount: modelInfo.materialCount,
            imageCount: 0
          });

          if (vrmResult.isVrm && vrmResult.asset.valid) {
            vrmAsset = vrmResult.asset;
            // 解析 VRM Humanoid 为 HumanoidJointBinding[]
            const parseResult: VrmHumanoidParseResult = resolveVrmHumanoid(
              vrmResult.asset.humanoid,
              modelInfo.nodeNames,
              modelInfo.nodeCount
            );
            declaredHumanBoneCount = parseResult.declaredBoneCount;
            validHumanBoneCount = parseResult.validBoneCount;

            if (parseResult.validBoneCount > 0) {
              // VRM 有效,使用 VRM 映射
              providerSource = 'VrmDeclared';
              const vrmBoneMapping: BoneMappingResult = vrmParseResultToBoneMappingResult(
                parseResult, modelInfo.nodeNames, displayName
              );
              Logger.info(LOG_TAG, 'VRM humanoid mapping: valid=' + validHumanBoneCount
                + ', declared=' + declaredHumanBoneCount
                + ', providerSource=VrmDeclared');
              return {
                vrmAsset: vrmAsset,
                boneMapping: vrmBoneMapping,
                isVrm: isVrm,
                vrmVersion: vrmVersion,
                declaredHumanBoneCount: declaredHumanBoneCount,
                validHumanBoneCount: validHumanBoneCount,
                providerSource: providerSource
              };
            } else {
              Logger.warn(LOG_TAG, 'VRM detected but no valid humanoid bones, fallback to mapBones');
            }
          } else if (vrmResult.error.length > 0) {
            Logger.warn(LOG_TAG, 'VRM parse error: ' + vrmResult.error);
          }
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'VRM detection failed: ' + (e as Error)?.message);
      }
    }

    // 非 VRM 或 VRM 无有效骨骼:回退到旧的名称匹配
    const boneMapping: BoneMappingResult = mapBones(
      modelInfo.nodeNames, displayName, modelInfo.hasSkins
    );
    providerSource = boneMapping.mappings.length > 0 ? 'AutoDetected' : 'None';

    return {
      vrmAsset: vrmAsset,
      boneMapping: boneMapping,
      isVrm: isVrm,
      vrmVersion: vrmVersion,
      declaredHumanBoneCount: declaredHumanBoneCount,
      validHumanBoneCount: validHumanBoneCount,
      providerSource: providerSource
    };
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
   * T-3D.6D: 集成 ModelImportDiagnostics 进行严格诊断,检测 Bounds 异常并生成警告。
   *
   * @param fileName rawfile 中的文件名(如 'teacher-love.glb')
   * @param displayName 显示名(用于 UI 和 modelId 隔离)
   * @param keepOldModel T-4.1 阶段 B: 是否保留旧模型文件(AvatarLibraryService 导入多模型时传 true)
   * @returns 导入结果
   */
  async importFromRawfileByName(
    fileName: string, displayName: string, keepOldModel: boolean = false
  ): Promise<Character3DImportResult> {
    if (fileName.length === 0) {
      throw new Error('fileName must not be empty');
    }
    // 读取旧 URI(用于稍后删除旧文件)
    const oldUri: string = await this.preferences.getString(PREF_KEY_MODEL_URI, '');

    // 从 rawfile 读取模型
    const buffer: ArrayBuffer = await this.readRawfileToBuffer(fileName);
    // T-4.2E-Closeout: 计算 SHA-256(修复历史 rawfile 导入返回空 SHA 的问题)
    const sourceSha256: string = computeSha256Base64(buffer);
    Logger.info(LOG_TAG, 'importFromRawfileByName: rawfile read, size=' + buffer.byteLength
      + ', sha=' + (sourceSha256.length > 0 ? sourceSha256.substring(0, 8) : 'empty'));

    // T-3D.6D: 严格诊断(GLB 容器 + glTF 语义 + 结构扫描)
    let inspection: ModelInspectionResult | null = null;
    const importWarnings: string[] = [];
    const diagnostics: ModelImportDiagnosticReport = ModelImportDiagnostics.diagnose(buffer);
    if (!diagnostics.passed) {
      const errCode: ModelImportErrorCode = diagnostics.errorCode ?? ModelImportErrorCode.Unknown;
      const userMsg: string = getErrorMessage(errCode);
      Logger.error(LOG_TAG, 'importFromRawfileByName diagnostics failed: code=' + errCode
        + ', msg=' + diagnostics.diagnosticMessage);
      throw new Error(userMsg + '(' + diagnostics.diagnosticMessage + ')');
    }
    inspection = diagnostics.inspection;
    for (let i: number = 0; i < diagnostics.warnings.length; i++) {
      importWarnings.push(diagnostics.warnings[i]);
    }

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
    // T-4.1 阶段 B: keepOldModel=true 时跳过(AvatarLibraryService 导入多模型时使用)
    if (!keepOldModel && oldUri.length > 0 && oldUri !== newUri) {
      try {
        await this.assetStore.deleteModelByUri(oldUri);
      } catch (e) {
        Logger.warn(LOG_TAG, 'delete old model failed: ' + (e as Error)?.message);
      }
    }

    // T-3D.4A: 计算自适应配置并保存为该 modelId 默认配置
    const autoFitConfig: Character3DDisplayConfig = this.computeAutoFitConfig(modelInfo);

    // T-3D.6D: 检测 Bounds 异常并追加警告
    const bounds = computeBoundsFromGltf(modelInfo);
    const anomalyReport: BoundsAnomalyReport = analyzeBoundsAnomalies(bounds);
    if (anomalyReport.hasAnomaly) {
      for (let i: number = 0; i < anomalyReport.warnings.length; i++) {
        importWarnings.push(anomalyReport.warnings[i]);
      }
      Logger.info(LOG_TAG, 'importFromRawfileByName bounds anomaly: '
        + anomalyReport.anomalyTypes.join(','));
    }

    await this.ensureModelDefaultConfig(displayName, autoFitConfig);

    // T-4.1: VRM 显式骨骼闭环(rawfile 路径同样集成)
    let boneMapping: BoneMappingResult | null = null;
    let capabilityReport: ModelCapabilityReport | null = null;
    let vrmAsset: VrmAsset | null = null;
    let isVrm: boolean = false;
    let vrmVersion: VrmVersion = VrmVersion.NonVrm;
    let declaredHumanBoneCount: number = 0;
    let validHumanBoneCount: number = 0;
    let humanoidProviderSource: string = 'None';
    try {
      // T-4.2E-Closeout: 使用计算得到的 SHA(而非空字符串)
      const vrmAndBone = this.resolveVrmAndBoneMapping(
        result.gltfJson, modelInfo, displayName, sourceSha256
      );
      boneMapping = vrmAndBone.boneMapping;
      vrmAsset = vrmAndBone.vrmAsset;
      isVrm = vrmAndBone.isVrm;
      vrmVersion = vrmAndBone.vrmVersion;
      declaredHumanBoneCount = vrmAndBone.declaredHumanBoneCount;
      validHumanBoneCount = vrmAndBone.validHumanBoneCount;
      humanoidProviderSource = vrmAndBone.providerSource;

      if (vrmAsset !== null) {
        await this.saveVrmAsset(vrmAsset);
      }

      const hasRenderableMesh: boolean = modelInfo.meshCount > 0;
      const capabilityInput: ModelCapabilityInput = {
        modelInfo: modelInfo,
        gltfJson: null,
        inspection: inspection,
        boneMapping: boneMapping,
        sceneLoaded: false,
        hasRenderableMesh: hasRenderableMesh,
        hasManualMapping: false,
        manualMappingValid: false,
        vrmAsset: vrmAsset
      };
      capabilityReport = analyzeModelCapability(capabilityInput);
      await this.preferences.putString(
        PREF_KEY_CAPABILITY_REPORT, JSON.stringify(capabilityReport)
      );
      await this.preferences.putString(
        PREF_KEY_BONE_MAPPING, JSON.stringify(boneMapping)
      );
      Logger.info(LOG_TAG, 'importFromRawfileByName capability: isVrm=' + isVrm
        + ', vrmVersion=' + vrmVersion
        + ', validBones=' + validHumanBoneCount
        + ', providerSource=' + humanoidProviderSource);
    } catch (e) {
      Logger.warn(LOG_TAG, 'importFromRawfileByName capability analysis failed: '
        + (e as Error)?.message);
    }

    Logger.info(LOG_TAG, 'importFromRawfileByName ok, name=' + displayName
      + ', warnings=' + importWarnings.length);
    return {
      modelUri: newUri,
      displayName: displayName,
      modelInfo: modelInfo,
      autoFitConfig: autoFitConfig,
      compatibilityAnalysis: null,
      conversionResult: null,
      sourceSha256: sourceSha256,
      inspection: inspection,
      warnings: importWarnings,
      fromCache: false,
      capabilityReport: capabilityReport,
      boneMapping: boneMapping,
      isVrm: isVrm,
      vrmVersion: vrmVersion,
      vrmAsset: vrmAsset,
      declaredHumanBoneCount: declaredHumanBoneCount,
      validHumanBoneCount: validHumanBoneCount,
      humanoidProviderSource: humanoidProviderSource
    };
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
