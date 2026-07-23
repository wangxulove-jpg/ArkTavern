/**
 * Character3DModelCompatibilityService 3D 模型兼容性预处理管线
 *
 * T-3D.6C-C: 识别并自动转换使用压缩网格扩展的 GLB 模型。
 *
 * 职责:
 * 1. 读取 GLB Header 和 JSON Chunk
 * 2. 识别 extensionsUsed / extensionsRequired
 * 3. 判断是否需要转换(DirectSupported / Convertible / Unsupported)
 * 4. 检查转换缓存(SHA-256 + 转换器版本)
 * 5. 调用 NAPI meshopt 解码器转换 EXT_meshopt_compression
 * 6. 验证转换结果(重新运行 GltfValidator)
 * 7. 返回可加载路径(原始路径或转换后路径)
 *
 * 流程(规格第九章):
 * 用户选择文件 → 复制到沙箱 → 检查 GLB 2.0 → 解析扩展
 * → 自动转换 → 验证转换结果 → 写入模型私有目录 → ArkGraphics 加载
 *
 * 绝对禁止(规格第八章):
 * - 从 extensionsRequired/extensionsUsed 直接删除扩展名
 * - 删除 accessor/bufferView 的 extensions 字段
 * - 忽略错误后直接交给 ArkGraphics
 * - 改文件后缀
 * - 声称转换成功但仍使用原压缩 buffer
 * - 丢弃蒙皮、动画或 Morph Target
 *
 * 转换缓存(规格第十五章):
 * files/models3d/converted/{sha256}/
 *   ├── model.standard.glb
 *   └── conversion.json
 *
 * 缓存键:原始文件 SHA-256 + 转换器版本
 * 导入相同模型时:校验缓存 → 缓存有效则直接使用 → 无效才重新转换
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { GltfValidator, GltfValidationResult, GltfModelInfo } from '../parser/GltfValidator';
import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
// T-3D.6C-C 阶段 3: 导入 Native meshopt 解码器模块
import { decodeMeshoptGlb, MeshoptDecodeResult } from 'libmodel_converter.so';
import {
  ModelCompatibilityStatus,
  ModelConversionMode,
  ModelConversionStage,
  ModelConversionProgress,
  ModelCompatibilityAnalysis,
  ModelConversionResult,
  ConversionCacheMetadata,
  CONVERTIBLE_EXTENSIONS,
  MODEL_CONVERTER_VERSION,
  MESHOPTIMIZER_VERSION,
  getConversionStageMessage
} from '../models/character3d/ModelCompatibility';

const LOG_TAG: string = 'Char3DModelCompat';

/**
 * 转换缓存目录名(位于 models3d/ 下)。
 */
const CONVERTED_DIR: string = 'converted';

/**
 * 转换后模型文件名。
 */
const CONVERTED_MODEL_FILENAME: string = 'model.standard.glb';

/**
 * 转换缓存元数据文件名。
 */
const CONVERSION_METADATA_FILENAME: string = 'conversion.json';

/**
 * Preferences key:用户转换偏好模式。
 */
const PREF_KEY_CONVERSION_MODE: string = 'model_conversion_mode';

/**
 * 转换进度回调类型。
 */
export type ConversionProgressCallback = (progress: ModelConversionProgress) => void;

/**
 * getLoadablePath 返回结果。
 */
export interface LoadablePathResult {
  /** 可加载路径(失败时为空字符串) */
  path: string;
  /** 兼容性分析结果 */
  analysis: ModelCompatibilityAnalysis;
  /** 转换结果(未执行转换时为 null) */
  conversion: ModelConversionResult | null;
}

/**
 * 3D 模型兼容性预处理服务。
 */
export class Character3DModelCompatibilityService {
  private baseDir: string = '';
  private convertedDir: string = '';
  private initialized: boolean = false;
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * 初始化,创建转换缓存目录。
   */
  initialize(context: common.Context): void {
    this.baseDir = context.filesDir + '/models3d';
    this.convertedDir = this.baseDir + '/' + CONVERTED_DIR;
    try {
      if (!fileIo.accessSync(this.convertedDir)) {
        fileIo.mkdirSync(this.convertedDir, true);
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'initialize mkdir failed: ' + String(e));
    }
    this.initialized = true;
    Logger.info(LOG_TAG, 'initialized, convertedDir=' + this.convertedDir);
  }

  // ========== 用户转换偏好 ==========

  /**
   * 获取用户转换偏好(默认 Auto)。
   */
  async getConversionMode(): Promise<ModelConversionMode> {
    const value: string = await this.preferences.getString(PREF_KEY_CONVERSION_MODE,
      String(ModelConversionMode.Auto as number));
    const num: number = Number(value);
    if (num === ModelConversionMode.Ask) {
      return ModelConversionMode.Ask;
    }
    if (num === ModelConversionMode.Off) {
      return ModelConversionMode.Off;
    }
    return ModelConversionMode.Auto;
  }

  /**
   * 设置用户转换偏好。
   */
  async setConversionMode(mode: ModelConversionMode): Promise<void> {
    await this.preferences.putString(PREF_KEY_CONVERSION_MODE, String(mode as number));
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('Character3DModelCompatibilityService not initialized');
    }
  }

  /**
   * 分析模型的兼容性(不执行转换)。
   *
   * 读取文件 → 验证 GLB 2.0 → 提取扩展 → 分类状态
   *
   * @param filePath GLB 文件绝对路径(不含 file:// 前缀)
   * @returns 兼容性分析结果
   */
  async analyzeCompatibility(filePath: string): Promise<ModelCompatibilityAnalysis> {
    this.requireInit();
    const result: ModelCompatibilityAnalysis = {
      status: ModelCompatibilityStatus.Unsupported,
      convertibleExtensions: [],
      convertibleRequiredExtensions: [],
      unsupportedExtensions: [],
      sourceByteLength: 0,
      sourceSha256: '',
      errorMessage: ''
    };

    try {
      // 1. 读取文件
      const buffer: ArrayBuffer = this.readFileToBuffer(filePath);
      result.sourceByteLength = buffer.byteLength;

      // 2. 计算 SHA-256(用于缓存键)
      result.sourceSha256 = await this.computeSha256(buffer);

      // 3. 验证 GLB 格式
      const validationResult: GltfValidationResult = GltfValidator.validate(buffer);
      if (!validationResult.valid) {
        result.status = ModelCompatibilityStatus.Unsupported;
        result.errorMessage = 'GLB 验证失败: ' + validationResult.errorMessage;
        return result;
      }

      const modelInfo: GltfModelInfo = validationResult.modelInfo;

      // 4. 分类扩展
      result.convertibleExtensions = modelInfo.convertibleUsedExtensions;
      result.convertibleRequiredExtensions = modelInfo.convertibleRequiredExtensions;
      result.unsupportedExtensions = modelInfo.unsupportedRequiredExtensions;

      // 5. 判断兼容状态
      if (modelInfo.unsupportedRequiredExtensions.length > 0) {
        // 存在不可转换的必需扩展
        result.status = ModelCompatibilityStatus.Unsupported;
        result.errorMessage = '该模型依赖不可转换的扩展: '
          + modelInfo.unsupportedRequiredExtensions.join(', ');
      } else if (modelInfo.convertibleRequiredExtensions.length > 0
        || modelInfo.convertibleUsedExtensions.length > 0) {
        // 存在可转换扩展
        result.status = ModelCompatibilityStatus.Convertible;
      } else {
        // 无特殊扩展,可直接加载
        result.status = ModelCompatibilityStatus.DirectSupported;
      }

      return result;
    } catch (e) {
      result.status = ModelCompatibilityStatus.Unsupported;
      result.errorMessage = '分析失败: ' + (e as Error)?.message;
      Logger.error(LOG_TAG, 'analyzeCompatibility failed: ' + result.errorMessage);
      return result;
    }
  }

  /**
   * 检查转换缓存是否有效。
   *
   * 缓存有效条件:
   * 1. 缓存目录存在
   * 2. model.standard.glb 存在
   * 3. conversion.json 存在且可解析
   * 4. conversion.json 中的 sourceSha256 与传入的 sha256 一致
   * 5. conversion.json 中的 converterVersion 与当前版本一致
   *
   * @param sourceSha256 原始文件 SHA-256
   * @returns 缓存目录路径(有效时非空),无效时返回空字符串
   */
  async checkCache(sourceSha256: string): Promise<string> {
    this.requireInit();
    if (sourceSha256.length === 0) {
      return '';
    }
    const cacheDir: string = this.convertedDir + '/' + sourceSha256;
    const modelPath: string = cacheDir + '/' + CONVERTED_MODEL_FILENAME;
    const metadataPath: string = cacheDir + '/' + CONVERSION_METADATA_FILENAME;

    try {
      // 检查文件是否存在
      if (!fileIo.accessSync(modelPath) || !fileIo.accessSync(metadataPath)) {
        return '';
      }

      // 读取并解析元数据
      const metadata: ConversionCacheMetadata | null = this.readCacheMetadata(metadataPath);
      if (metadata === null) {
        return '';
      }

      // 校验 SHA-256 和版本
      if (metadata.sourceSha256 !== sourceSha256) {
        Logger.info(LOG_TAG, 'cache sha256 mismatch, invalid');
        return '';
      }
      if (metadata.converterVersion !== MODEL_CONVERTER_VERSION) {
        Logger.info(LOG_TAG, 'cache converter version mismatch: '
          + metadata.converterVersion + ' vs ' + MODEL_CONVERTER_VERSION);
        return '';
      }
      if (metadata.meshoptimizerVersion !== MESHOPTIMIZER_VERSION) {
        Logger.info(LOG_TAG, 'cache meshoptimizer version mismatch: '
          + metadata.meshoptimizerVersion + ' vs ' + MESHOPTIMIZER_VERSION);
        return '';
      }
      // T-3D.6C-C3: loadVerified 必须为 true 才能命中缓存
      if (!metadata.loadVerified) {
        Logger.info(LOG_TAG, 'cache loadVerified=false, invalid (ArkGraphics load not confirmed)');
        return '';
      }

      Logger.info(LOG_TAG, 'cache hit for sha256=' + sourceSha256.substring(0, 16));
      return cacheDir;
    } catch (e) {
      Logger.warn(LOG_TAG, 'checkCache failed: ' + String(e));
      return '';
    }
  }

  /**
   * 执行模型兼容转换。
   *
   * 流程:
   * 1. 检查缓存(有效则直接返回)
   * 2. 读取原始文件
   * 3. 调用 NAPI meshopt 解码器
   * 4. 验证转换结果
   * 5. 写入缓存目录
   * 6. 返回转换后路径
   *
   * @param sourceFilePath 原始 GLB 文件路径
   * @param analysis 兼容性分析结果(来自 analyzeCompatibility)
   * @param onProgress 进度回调(可选)
   * @returns 转换结果
   */
  async convertModel(
    sourceFilePath: string,
    analysis: ModelCompatibilityAnalysis,
    onProgress?: ConversionProgressCallback
  ): Promise<ModelConversionResult> {
    this.requireInit();
    const emit = (stage: ModelConversionStage, percent: number): void => {
      if (onProgress !== undefined && onProgress !== null) {
        onProgress({
          stage: stage,
          percent: percent,
          message: getConversionStageMessage(stage)
        } as ModelConversionProgress);
      }
    };

    const fail = (message: string): ModelConversionResult => {
      emit(ModelConversionStage.Failed, 0);
      return {
        success: false,
        status: ModelCompatibilityStatus.ConversionFailed,
        outputPath: '',
        outputByteLength: 0,
        removedExtensions: [],
        retainedExtensions: [],
        warnings: [],
        errorMessage: message,
        fromCache: false
      } as ModelConversionResult;
    };

    try {
      // 0. 检查缓存
      emit(ModelConversionStage.Reading, 5);
      const cacheDir: string = await this.checkCache(analysis.sourceSha256);
      if (cacheDir.length > 0) {
        const cachedModelPath: string = cacheDir + '/' + CONVERTED_MODEL_FILENAME;
        const metadata: ConversionCacheMetadata | null =
          this.readCacheMetadata(cacheDir + '/' + CONVERSION_METADATA_FILENAME);
        const cachedBuffer: ArrayBuffer = this.readFileToBuffer(cachedModelPath);
        emit(ModelConversionStage.Done, 100);
        Logger.info(LOG_TAG, 'convertModel using cache, size=' + cachedBuffer.byteLength);
        return {
          success: true,
          status: ModelCompatibilityStatus.Converted,
          outputPath: cachedModelPath,
          outputByteLength: cachedBuffer.byteLength,
          removedExtensions: metadata !== null ? metadata.removedExtensions : [],
          retainedExtensions: [],
          warnings: metadata !== null ? metadata.warnings : [],
          errorMessage: '',
          fromCache: true
        } as ModelConversionResult;
      }

      // 1. 检查扩展
      emit(ModelConversionStage.CheckingExtensions, 15);
      if (analysis.convertibleExtensions.length === 0
        && analysis.convertibleRequiredExtensions.length === 0) {
        return fail('模型无可转换扩展,无需转换');
      }

      // 2. 调用 NAPI 解码器
      emit(ModelConversionStage.DecompressingMesh, 30);
      const outputDir: string = this.convertedDir + '/' + analysis.sourceSha256;
      const outputPath: string = outputDir + '/' + CONVERTED_MODEL_FILENAME;

      // 创建缓存目录
      try {
        if (!fileIo.accessSync(outputDir)) {
          fileIo.mkdirSync(outputDir, true);
        }
      } catch (_e) {
        // 目录可能已存在
      }

      // 调用 NAPI meshopt 解码器
      const napiResult: NapiConversionResult = await this.callNapiDecoder(
        sourceFilePath, outputPath, analysis.convertibleRequiredExtensions
      );

      if (!napiResult.success) {
        return fail(napiResult.errorMessage);
      }

      // 3. 重建 GLB(NAPI 已输出标准 GLB,此处跳过量化转换阶段)
      // T-3D.6C-C 阶段一:仅解码 meshopt,保留 KHR_mesh_quantization
      emit(ModelConversionStage.RebuildingGlb, 70);

      // 4. 验证转换结果
      emit(ModelConversionStage.Validating, 80);
      const convertedBuffer: ArrayBuffer = this.readFileToBuffer(outputPath);
      // 诊断日志:输出转换后 GLB 前 64 字节十六进制
      const diagView: DataView = new DataView(convertedBuffer);
      const diagLen: number = Math.min(64, diagView.byteLength);
      let diagHex: string = '';
      for (let i: number = 0; i < diagLen; i++) {
        const b: number = diagView.getUint8(i);
        diagHex += (b < 16 ? '0' : '') + b.toString(16) + ' ';
      }
      Logger.info(LOG_TAG, 'converted GLB first ' + diagLen + ' bytes: ' + diagHex);
      Logger.info(LOG_TAG, 'converted GLB total size: ' + convertedBuffer.byteLength);
      const validation: GltfValidationResult = GltfValidator.validate(convertedBuffer);
      if (!validation.valid) {
        // 删除无效输出
        this.cleanupCacheDir(outputDir);
        return fail('转换结果验证失败: ' + validation.errorMessage);
      }

      // 确认 EXT_meshopt_compression 不再出现在实际引用中
      const convertedInfo: GltfModelInfo = validation.modelInfo;
      if (convertedInfo.convertibleUsedExtensions.indexOf('EXT_meshopt_compression') >= 0) {
        this.cleanupCacheDir(outputDir);
        return fail('转换后仍存在 EXT_meshopt_compression 引用,转换不完整');
      }

      emit(ModelConversionStage.Loading, 95);

      // 5. 计算输出 SHA-256
      const outputSha256: string = await this.computeSha256(convertedBuffer);

      // 6. 写入缓存元数据(loadVerified=false,需 ArkGraphics 加载成功后才标记 true)
      const removedExtensions: string[] = napiResult.removedExtensions;
      const retainedExtensions: string[] = convertedInfo.convertibleUsedExtensions;
      const metadata: ConversionCacheMetadata = {
        sourceSha256: analysis.sourceSha256,
        converterVersion: MODEL_CONVERTER_VERSION,
        meshoptimizerVersion: MESHOPTIMIZER_VERSION,
        sourceExtensions: analysis.convertibleExtensions,
        removedExtensions: removedExtensions,
        outputSha256: outputSha256,
        convertedAt: Date.now(),
        warnings: napiResult.warnings,
        decodedBufferViewCount: napiResult.decodedBufferViewCount,
        loadVerified: false
      } as ConversionCacheMetadata;
      this.writeCacheMetadata(outputDir + '/' + CONVERSION_METADATA_FILENAME, metadata);

      emit(ModelConversionStage.Done, 100);
      Logger.info(LOG_TAG, 'convertModel success, output=' + outputPath
        + ', size=' + convertedBuffer.byteLength
        + ', removed=[' + removedExtensions.join(',') + ']'
        + ', retained=[' + retainedExtensions.join(',') + ']');

      return {
        success: true,
        status: ModelCompatibilityStatus.Converted,
        outputPath: outputPath,
        outputByteLength: convertedBuffer.byteLength,
        removedExtensions: removedExtensions,
        retainedExtensions: retainedExtensions,
        warnings: napiResult.warnings,
        errorMessage: '',
        fromCache: false
      } as ModelConversionResult;
    } catch (e) {
      return fail('转换异常: ' + (e as Error)?.message);
    }
  }

  /**
   * 获取模型的可加载路径。
   *
   * 根据兼容性分析结果决定:
   * - DirectSupported: 返回原始路径
   * - Convertible: 执行转换后返回转换路径
   * - Unsupported: 返回空字符串
   *
   * @param filePath 原始文件路径
   * @param mode 用户转换偏好
   * @param onProgress 进度回调
   * @returns 可加载路径(失败时返回空字符串并设置 errorMessage)
   */
  async getLoadablePath(
    filePath: string,
    mode: ModelConversionMode,
    onProgress?: ConversionProgressCallback
  ): Promise<LoadablePathResult> {
    this.requireInit();

    // 1. 分析兼容性
    const analysis: ModelCompatibilityAnalysis = await this.analyzeCompatibility(filePath);

    if (analysis.status === ModelCompatibilityStatus.Unsupported) {
      return {
        path: '',
        analysis: analysis,
        conversion: null
      } as LoadablePathResult;
    }

    if (analysis.status === ModelCompatibilityStatus.DirectSupported) {
      return {
        path: filePath,
        analysis: analysis,
        conversion: null
      } as LoadablePathResult;
    }

    // Convertible: 根据用户偏好决定是否转换
    if (mode === ModelConversionMode.Off) {
      // 关闭转换:返回空,由调用方显示重新导出建议
      analysis.errorMessage = '模型使用压缩网格格式,但转换功能已关闭。'
        + '请在设置中启用模型兼容转换,或导出为标准 GLB 2.0。';
      return {
        path: '',
        analysis: analysis,
        conversion: null
      } as LoadablePathResult;
    }

    // Auto 或 Ask:执行转换
    const conversion: ModelConversionResult = await this.convertModel(
      filePath, analysis, onProgress
    );

    if (!conversion.success) {
      return {
        path: '',
        analysis: analysis,
        conversion: conversion
      } as LoadablePathResult;
    }

    return {
      path: conversion.outputPath,
      analysis: analysis,
      conversion: conversion
    } as LoadablePathResult;
  }

  /**
   * 清理指定 SHA-256 的转换缓存。
   */
  async clearCache(sourceSha256: string): Promise<void> {
    this.requireInit();
    const cacheDir: string = this.convertedDir + '/' + sourceSha256;
    this.cleanupCacheDir(cacheDir);
  }

  /**
   * 清理所有转换缓存。
   */
  async clearAllCache(): Promise<void> {
    this.requireInit();
    try {
      if (!fileIo.accessSync(this.convertedDir)) {
        return;
      }
      const entries: string[] = fileIo.listFileSync(this.convertedDir);
      for (let i: number = 0; i < entries.length; i++) {
        const dir: string = this.convertedDir + '/' + entries[i];
        this.cleanupCacheDir(dir);
      }
      Logger.info(LOG_TAG, 'clearAllCache done');
    } catch (e) {
      Logger.warn(LOG_TAG, 'clearAllCache failed: ' + String(e));
    }
  }

  // ========== 内部方法 ==========

  /**
   * 调用 NAPI meshopt 解码器。
   *
   * T-3D.6C-C 阶段 3:NAPI 模块实现后此方法生效。
   * 当前 NAPI 模块未实现时,返回明确错误。
   *
   * 实现后,此方法应:
   * 1. 调用 import 的 NAPI 模块方法 decodeMeshoptGlb(inputPath, outputPath)
   * 2. 解析返回的 { success, errorMessage, removedExtensions, warnings } 结果
   * 3. NAPI 层负责:解码 EXT_meshopt_compression bufferView、重建标准 GLB
   *
   * 禁止(规格第八章):
   * - 直接删除 extensionsRequired/extensionsUsed 中的扩展名
   * - 删除 accessor/bufferView 的 extensions 字段
   * - 忽略错误后直接交给 ArkGraphics
   */
  private async callNapiDecoder(
    inputPath: string,
    outputPath: string,
    extensions: string[]
  ): Promise<NapiConversionResult> {
    // T-3D.6C-C 阶段 3: 调用 Native meshopt 解码器
    Logger.info(LOG_TAG, 'callNapiDecoder: input=' + inputPath + ', output=' + outputPath
      + ', extensions=[' + extensions.join(',') + ']');
    try {
      const nativeResult: MeshoptDecodeResult = await decodeMeshoptGlb(inputPath, outputPath);
      // 计算移除的扩展 = sourceExtensions - remainingExtensions
      const removed: string[] = [];
      for (let i: number = 0; i < nativeResult.sourceExtensions.length; i++) {
        const ext: string = nativeResult.sourceExtensions[i];
        if (nativeResult.remainingExtensions.indexOf(ext) < 0) {
          removed.push(ext);
        }
      }
      return {
        success: nativeResult.success,
        outputPath: nativeResult.outputPath,
        decodedBufferViewCount: nativeResult.decodedBufferViewCount,
        sourceExtensions: nativeResult.sourceExtensions,
        remainingExtensions: nativeResult.remainingExtensions,
        warnings: nativeResult.warnings,
        errorCode: nativeResult.errorCode,
        errorMessage: nativeResult.errorMessage,
        removedExtensions: removed
      } as NapiConversionResult;
    } catch (e) {
      const msg: string = (e as Error)?.message ?? String(e);
      Logger.error(LOG_TAG, 'callNapiDecoder exception: ' + msg);
      return {
        success: false,
        outputPath: '',
        decodedBufferViewCount: 0,
        sourceExtensions: extensions,
        remainingExtensions: extensions,
        warnings: [],
        errorCode: 'NAPI_EXCEPTION',
        errorMessage: '调用 Native 解码器异常: ' + msg,
        removedExtensions: []
      } as NapiConversionResult;
    }
  }

  private parseStringArray(obj: Object | undefined): string[] {
    if (obj === undefined || obj === null) {
      return [];
    }
    if (!(obj instanceof Array)) {
      return [];
    }
    const arr: Object[] = obj as Object[];
    const result: string[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      result.push(String(arr[i]));
    }
    return result;
  }

  /**
   * 读取文件为 ArrayBuffer。
   */
  private readFileToBuffer(filePath: string): ArrayBuffer {
    const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      return buffer;
    } finally {
      fileIo.closeSync(file);
    }
  }

  /**
   * 计算 buffer 的 SHA-256。
   */
  private async computeSha256(buffer: ArrayBuffer): Promise<string> {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const inputData: cryptoFramework.DataBlob = {
      data: new Uint8Array(buffer)
    } as cryptoFramework.DataBlob;
    md.updateSync(inputData);
    const digestBlob: cryptoFramework.DataBlob = md.digestSync();
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.encodeToStringSync(digestBlob.data, util.Type.BASIC);
  }

  /**
   * 读取缓存元数据。
   */
  private readCacheMetadata(metadataPath: string): ConversionCacheMetadata | null {
    try {
      const file: fileIo.File = fileIo.openSync(metadataPath, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        const json: string = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer));
        const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
        return {
          sourceSha256: String(obj['sourceSha256'] ?? ''),
          converterVersion: String(obj['converterVersion'] ?? ''),
          meshoptimizerVersion: String(obj['meshoptimizerVersion'] ?? ''),
          sourceExtensions: this.parseStringArray(obj['sourceExtensions']),
          removedExtensions: this.parseStringArray(obj['removedExtensions']),
          outputSha256: String(obj['outputSha256'] ?? ''),
          convertedAt: Number(obj['convertedAt'] ?? 0),
          warnings: this.parseStringArray(obj['warnings']),
          decodedBufferViewCount: Number(obj['decodedBufferViewCount'] ?? 0),
          loadVerified: Boolean(obj['loadVerified'] ?? false)
        } as ConversionCacheMetadata;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'readCacheMetadata failed: ' + String(e));
      return null;
    }
  }

  /**
   * 写入缓存元数据。
   */
  private writeCacheMetadata(metadataPath: string, metadata: ConversionCacheMetadata): void {
    const json: string = JSON.stringify(metadata);
    const file: fileIo.File = fileIo.openSync(metadataPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, json);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /**
   * 清理缓存目录(删除目录及内容)。
   */
  private cleanupCacheDir(cacheDir: string): void {
    try {
      if (!fileIo.accessSync(cacheDir)) {
        return;
      }
      const entries: string[] = fileIo.listFileSync(cacheDir);
      for (let i: number = 0; i < entries.length; i++) {
        const filePath: string = cacheDir + '/' + entries[i];
        try {
          fileIo.unlinkSync(filePath);
        } catch (_e) {
          // ignore
        }
      }
      fileIo.rmdirSync(cacheDir);
    } catch (e) {
      Logger.warn(LOG_TAG, 'cleanupCacheDir failed: ' + String(e));
    }
  }

  /**
   * T-3D.6C-C3: 根据输入文件路径失效对应缓存。
   * 用于转换成功但 ArkGraphics 加载失败时,使该缓存不再被命中。
   */
  async invalidateCacheForInput(inputPath: string): Promise<void> {
    this.requireInit();
    try {
      const buffer: ArrayBuffer = this.readFileToBuffer(inputPath);
      const sha256: string = await this.computeSha256(buffer);
      const cacheDir: string = this.convertedDir + '/' + sha256;
      Logger.info(LOG_TAG, 'invalidateCacheForInput: sha256=' + sha256.substring(0, 16)
        + ', dir=' + cacheDir);
      this.cleanupCacheDir(cacheDir);
    } catch (e) {
      Logger.warn(LOG_TAG, 'invalidateCacheForInput failed: ' + String(e));
    }
  }

  /**
   * T-3D.6C-C3: 根据源 SHA-256 标记缓存为已加载验证。
   * 仅当 ArkGraphics 真机加载成功后调用。
   */
  async markCacheLoadVerified(sourceSha256: string): Promise<void> {
    this.requireInit();
    if (sourceSha256.length === 0) {
      return;
    }
    const cacheDir: string = this.convertedDir + '/' + sourceSha256;
    const metadataPath: string = cacheDir + '/' + CONVERSION_METADATA_FILENAME;
    const metadata: ConversionCacheMetadata | null = this.readCacheMetadata(metadataPath);
    if (metadata === null) {
      Logger.warn(LOG_TAG, 'markCacheLoadVerified: metadata not found for sha256='
        + sourceSha256.substring(0, 16));
      return;
    }
    metadata.loadVerified = true;
    this.writeCacheMetadata(metadataPath, metadata);
    Logger.info(LOG_TAG, 'markCacheLoadVerified: sha256=' + sourceSha256.substring(0, 16)
      + ' marked true');
  }
}

/**
 * NAPI 解码器返回结果(内部类型)。
 * 与 Native 层 MeshoptDecodeResult 结构对应。
 */
interface NapiConversionResult {
  success: boolean;
  outputPath: string;
  decodedBufferViewCount: number;
  sourceExtensions: string[];
  remainingExtensions: string[];
  warnings: string[];
  errorCode: string;
  errorMessage: string;
  /** 计算字段:sourceExtensions - remainingExtensions */
  removedExtensions: string[];
}
