/**
 * GlbContainerAndSemanticTest GLB 容器与 glTF 语义校验单元测试
 *
 * T-3D.6D: 模型导入稳定性、兼容性诊断与自动验收
 *
 * 职责:
 * - 对 GlbContainerValidator 做断言测试(15 项)
 * - 对 GltfSemanticValidator 做断言测试(12 项)
 * - 对 ModelInspector 做断言测试(8 项)
 * - 不依赖 ArkUI / ArkGraphics3D / 文件系统,可独立运行
 * - 通过 Logger 输出测试结果
 *
 * 测试项:
 * GLB 容器(15 项):
 *  1. 正常 GLB(仅 JSON)
 *  2. 正常 GLB(JSON + BIN)
 *  3. 文件小于 12 字节
 *  4. magic 错误
 *  5. version 错误
 *  6. declared length 不匹配
 *  7. JSON chunk 缺失
 *  8. JSON chunk 类型错误(第一个为 BIN)
 *  9. JSON chunkLength 非 4 对齐
 * 10. JSON chunk 越界
 * 11. BIN chunk 越界
 * 12. chunkLength = 0xFFFFFFFF
 * 13. 文件末尾多余数据
 * 14. 空 JSON
 * 15. 多个 JSON chunk
 *
 * glTF 语义(12 项):
 * 16. asset 缺失
 * 17. asset.version 错误
 * 18. bufferView 越界
 * 19. accessor 越界
 * 20. primitive 缺 POSITION
 * 21. indices 越界
 * 22. node children 越界
 * 23. skin joints 越界
 * 24. required extension 不支持
 * 25. extensionsUsed 未知扩展(只警告)
 * 26. image bufferView 越界
 * 27. 正常 GLB 通过
 *
 * ModelInspector(8 项):
 * 28. 基础统计(scene/node/mesh)
 * 29. primitive 计数
 * 30. joint 去重计数
 * 31. morph target 计数
 * 32. 灯光计数(KHR_lights_punctual)
 * 33. 材质类型检测(PBR/Transparent/Unlit)
 * 34. 外部资源检测
 * 35. 扩展分类(DirectlySupported/Convertible/Unsupported)
 */

import { Logger } from '../utils/Logger';
import {
  GlbContainerValidator,
  GlbContainerValidationResult
} from '../parser/GlbContainerValidator';
import {
  GltfSemanticValidator,
  GltfSemanticValidationResult
} from '../parser/GltfSemanticValidator';
import { ModelInspector } from '../parser/ModelInspector';
import {
  ModelImportErrorCode
} from '../models/character3d/ModelImportResult';

const LOG_TAG: string = 'GlbSemanticTest';

/** 单项测试结果 */
interface TestResult {
  name: string;
  passed: boolean;
  message: string;
}

/** 全部测试结果汇总 */
interface TestSuiteResult {
  total: number;
  passed: number;
  failed: number;
  results: TestResult[];
}

/**
 * GLB 二进制构建器(测试用)。
 *
 * GLB 2.0 结构:
 *   Header (12 bytes): magic + version + length
 *   Chunk[]: chunkLength + chunkType + chunkData(4 字节对齐)
 *
 * chunkLength 表示 chunkData 的长度(含 padding),必须为 4 的倍数。
 */
class GlbBuilder {
  private jsonText: string = '';
  private binData: ArrayBuffer | null = null;
  private jsonChunkType: number = 0x4E4F534A;  // "JSON"
  private binChunkType: number = 0x004E4942;   // "BIN\0"
  private jsonChunkLengthOverride: number = -1;  // -1 表示自动计算
  private binChunkLengthOverride: number = -1;
  private jsonChunkTypeOverride: number = -1;    // -1 表示使用默认
  private firstChunkTypeOverride: number = -1;   // -1 表示使用 JSON
  private trailingExtraBytes: number = 0;
  private headerLengthOverride: number = -1;
  private headerMagicOverride: number = -1;
  private headerVersionOverride: number = -1;
  private skipJsonChunk: boolean = false;
  private duplicateJsonChunk: boolean = false;
  private chunkLengthFFFFFFFF: boolean = false;

  setJson(json: string): GlbBuilder {
    this.jsonText = json;
    return this;
  }

  setBin(bin: ArrayBuffer | null): GlbBuilder {
    this.binData = bin;
    return this;
  }

  setJsonChunkLengthOverride(len: number): GlbBuilder {
    this.jsonChunkLengthOverride = len;
    return this;
  }

  setBinChunkLengthOverride(len: number): GlbBuilder {
    this.binChunkLengthOverride = len;
    return this;
  }

  setFirstChunkType(chunkType: number): GlbBuilder {
    this.firstChunkTypeOverride = chunkType;
    return this;
  }

  setTrailingExtraBytes(n: number): GlbBuilder {
    this.trailingExtraBytes = n;
    return this;
  }

  setHeaderLengthOverride(len: number): GlbBuilder {
    this.headerLengthOverride = len;
    return this;
  }

  setHeaderMagicOverride(magic: number): GlbBuilder {
    this.headerMagicOverride = magic;
    return this;
  }

  setHeaderVersionOverride(version: number): GlbBuilder {
    this.headerVersionOverride = version;
    return this;
  }

  setSkipJsonChunk(skip: boolean): GlbBuilder {
    this.skipJsonChunk = skip;
    return this;
  }

  setDuplicateJsonChunk(dup: boolean): GlbBuilder {
    this.duplicateJsonChunk = dup;
    return this;
  }

  setChunkLengthFFFFFFFF(use: boolean): GlbBuilder {
    this.chunkLengthFFFFFFFF = use;
    return this;
  }

  /**
   * 构建完整的 GLB ArrayBuffer。
   */
  build(): ArrayBuffer {
    // 1. 准备 JSON chunk data(4 字节对齐,用 0x20 padding)
    const jsonBytes: Uint8Array = GlbBuilder.encodeUtf8(this.jsonText);
    const jsonPaddedLen: number = GlbBuilder.align4(jsonBytes.length);
    const jsonPadded: Uint8Array = new Uint8Array(jsonPaddedLen);
    jsonPadded.set(jsonBytes);
    for (let i: number = jsonBytes.length; i < jsonPaddedLen; i++) {
      jsonPadded[i] = 0x20;  // 空格 padding
    }

    // 2. 准备 BIN chunk data(4 字节对齐,用 0x00 padding)
    let binPadded: Uint8Array = new Uint8Array(0);
    let hasBin: boolean = false;
    if (this.binData !== null) {
      hasBin = true;
      const binBytes: Uint8Array = new Uint8Array(this.binData);
      const binPaddedLen: number = GlbBuilder.align4(binBytes.length);
      binPadded = new Uint8Array(binPaddedLen);
      binPadded.set(binBytes);
      // 0x00 padding(已在初始化时设置)
    }

    // 3. 计算总长度
    let totalLength: number = 12;  // header
    if (!this.skipJsonChunk) {
      totalLength += 8 + jsonPadded.length;  // chunk header + data
      if (this.duplicateJsonChunk) {
        totalLength += 8 + jsonPadded.length;
      }
    }
    if (hasBin) {
      totalLength += 8 + binPadded.length;
    }
    totalLength += this.trailingExtraBytes;

    // 4. 构建 buffer
    const buffer: ArrayBuffer = new ArrayBuffer(totalLength);
    const view: DataView = new DataView(buffer);
    const u8: Uint8Array = new Uint8Array(buffer);

    // Header
    const magic: number = this.headerMagicOverride >= 0 ? this.headerMagicOverride : 0x46546C67;
    const version: number = this.headerVersionOverride >= 0 ? this.headerVersionOverride : 2;
    const headerLength: number = this.headerLengthOverride >= 0 ? this.headerLengthOverride : totalLength;
    view.setUint32(0, magic, true);
    view.setUint32(4, version, true);
    view.setUint32(8, headerLength, true);

    let offset: number = 12;

    // 第一个 chunk(默认为 JSON,可覆盖为 BIN)
    if (!this.skipJsonChunk) {
      const firstChunkType: number = this.firstChunkTypeOverride >= 0
        ? this.firstChunkTypeOverride : this.jsonChunkType;
      const jsonChunkLen: number = this.jsonChunkLengthOverride >= 0
        ? this.jsonChunkLengthOverride : jsonPadded.length;
      if (this.chunkLengthFFFFFFFF) {
        view.setUint32(offset, 0xFFFFFFFF, true);
      } else {
        view.setUint32(offset, jsonChunkLen, true);
      }
      view.setUint32(offset + 4, firstChunkType, true);
      u8.set(jsonPadded.subarray(0, Math.min(jsonChunkLen, jsonPadded.length)), offset + 8);
      offset += 8 + jsonPadded.length;

      // 可选:重复 JSON chunk
      if (this.duplicateJsonChunk) {
        view.setUint32(offset, jsonPadded.length, true);
        view.setUint32(offset + 4, this.jsonChunkType, true);
        u8.set(jsonPadded, offset + 8);
        offset += 8 + jsonPadded.length;
      }
    }

    // 第二个 chunk(BIN)
    if (hasBin) {
      const binChunkLen: number = this.binChunkLengthOverride >= 0
        ? this.binChunkLengthOverride : binPadded.length;
      if (this.chunkLengthFFFFFFFF) {
        view.setUint32(offset, 0xFFFFFFFF, true);
      } else {
        view.setUint32(offset, binChunkLen, true);
      }
      view.setUint32(offset + 4, this.binChunkType, true);
      u8.set(binPadded.subarray(0, Math.min(binChunkLen, binPadded.length)), offset + 8);
      offset += 8 + binPadded.length;
    }

    // 尾部额外字节
    // (已在初始化为 0,无需额外操作)

    return buffer;
  }

  private static align4(n: number): number {
    return (n + 3) & ~3;
  }

  private static encodeUtf8(s: string): Uint8Array {
    // 简单 UTF-8 编码(支持 ASCII)
    const bytes: number[] = [];
    for (let i: number = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c < 0x80) {
        bytes.push(c);
      } else if (c < 0x800) {
        bytes.push(0xC0 | (c >> 6));
        bytes.push(0x80 | (c & 0x3F));
      } else {
        bytes.push(0xE0 | (c >> 12));
        bytes.push(0x80 | ((c >> 6) & 0x3F));
        bytes.push(0x80 | (c & 0x3F));
      }
    }
    const result: Uint8Array = new Uint8Array(bytes.length);
    for (let i: number = 0; i < bytes.length; i++) {
      result[i] = bytes[i];
    }
    return result;
  }
}

/**
 * 测试入口。
 */
export class GlbContainerAndSemanticTest {
  /**
   * 运行全部 35 项测试,返回汇总结果并输出日志。
   */
  static runAllTests(): TestSuiteResult {
    const results: TestResult[] = [];

    // GLB 容器测试(15 项)
    results.push(GlbContainerAndSemanticTest.test01_ValidJsonOnly());
    results.push(GlbContainerAndSemanticTest.test02_ValidJsonAndBin());
    results.push(GlbContainerAndSemanticTest.test03_FileTooSmall());
    results.push(GlbContainerAndSemanticTest.test04_InvalidMagic());
    results.push(GlbContainerAndSemanticTest.test05_InvalidVersion());
    results.push(GlbContainerAndSemanticTest.test06_DeclaredLengthMismatch());
    results.push(GlbContainerAndSemanticTest.test07_MissingJsonChunk());
    results.push(GlbContainerAndSemanticTest.test08_FirstChunkNotJson());
    results.push(GlbContainerAndSemanticTest.test09_JsonChunkLengthNotAligned());
    results.push(GlbContainerAndSemanticTest.test10_JsonChunkOutOfRange());
    results.push(GlbContainerAndSemanticTest.test11_BinChunkOutOfRange());
    results.push(GlbContainerAndSemanticTest.test12_ChunkLengthFFFFFFFF());
    results.push(GlbContainerAndSemanticTest.test13_TrailingExtraBytes());
    results.push(GlbContainerAndSemanticTest.test14_EmptyJson());
    results.push(GlbContainerAndSemanticTest.test15_DuplicateJsonChunk());

    // glTF 语义测试(12 项)
    results.push(GlbContainerAndSemanticTest.test16_MissingAsset());
    results.push(GlbContainerAndSemanticTest.test17_WrongAssetVersion());
    results.push(GlbContainerAndSemanticTest.test18_BufferViewOutOfRange());
    results.push(GlbContainerAndSemanticTest.test19_AccessorOutOfRange());
    results.push(GlbContainerAndSemanticTest.test20_PrimitiveMissingPosition());
    results.push(GlbContainerAndSemanticTest.test21_IndicesOutOfRange());
    results.push(GlbContainerAndSemanticTest.test22_NodeChildrenOutOfRange());
    results.push(GlbContainerAndSemanticTest.test23_SkinJointsOutOfRange());
    results.push(GlbContainerAndSemanticTest.test24_UnsupportedRequiredExtension());
    results.push(GlbContainerAndSemanticTest.test25_UnknownUsedExtensionWarning());
    results.push(GlbContainerAndSemanticTest.test26_ImageBufferViewOutOfRange());
    results.push(GlbContainerAndSemanticTest.test27_ValidGltf());

    // ModelInspector 测试(8 项)
    results.push(GlbContainerAndSemanticTest.test28_InspectionBasicStats());
    results.push(GlbContainerAndSemanticTest.test29_PrimitiveCount());
    results.push(GlbContainerAndSemanticTest.test30_JointDedupCount());
    results.push(GlbContainerAndSemanticTest.test31_MorphTargetCount());
    results.push(GlbContainerAndSemanticTest.test32_LightCount());
    results.push(GlbContainerAndSemanticTest.test33_MaterialTypeDetection());
    results.push(GlbContainerAndSemanticTest.test34_ExternalResourceDetection());
    results.push(GlbContainerAndSemanticTest.test35_ExtensionClassification());

    let passed: number = 0;
    let failed: number = 0;
    for (const r of results) {
      if (r.passed) {
        passed++;
      } else {
        failed++;
      }
    }
    const suite: TestSuiteResult = {
      total: results.length,
      passed: passed,
      failed: failed,
      results: results
    };
    Logger.info(LOG_TAG, '==== Test Suite Done: ' + passed + '/' + results.length
      + ' passed, ' + failed + ' failed ====');
    return suite;
  }

  // ========== GLB 容器测试(15 项)==========

  /** 1. 正常 GLB(仅 JSON,无 BIN) */
  private static test01_ValidJsonOnly(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder().setJson(json).build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = result.valid && result.jsonText === json && !result.hasBinChunk;
    return GlbContainerAndSemanticTest.buildResult('01_ValidJsonOnly', ok,
      'valid=' + result.valid + ', hasBin=' + result.hasBinChunk + ', jsonLen=' + result.jsonText.length);
  }

  /** 2. 正常 GLB(JSON + BIN) */
  private static test02_ValidJsonAndBin(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const bin: ArrayBuffer = new ArrayBuffer(16);
    const buffer: ArrayBuffer = new GlbBuilder().setJson(json).setBin(bin).build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = result.valid && result.hasBinChunk && result.binChunkLength === 16
      && result.binData !== null;
    return GlbContainerAndSemanticTest.buildResult('02_ValidJsonAndBin', ok,
      'valid=' + result.valid + ', binLen=' + result.binChunkLength);
  }

  /** 3. 文件小于 12 字节 */
  private static test03_FileTooSmall(): TestResult {
    const buffer: ArrayBuffer = new ArrayBuffer(8);
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.FileTooSmall;
    return GlbContainerAndSemanticTest.buildResult('03_FileTooSmall', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 4. magic 错误 */
  private static test04_InvalidMagic(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setHeaderMagicOverride(0x12345678)
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.InvalidGlbMagic;
    return GlbContainerAndSemanticTest.buildResult('04_InvalidMagic', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 5. version 错误 */
  private static test05_InvalidVersion(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setHeaderVersionOverride(1)
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.UnsupportedGlbVersion;
    return GlbContainerAndSemanticTest.buildResult('05_InvalidVersion', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 6. declared length 不匹配 */
  private static test06_DeclaredLengthMismatch(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setHeaderLengthOverride(9999)
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.InvalidDeclaredLength;
    return GlbContainerAndSemanticTest.buildResult('06_DeclaredLengthMismatch', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 7. JSON chunk 缺失 */
  private static test07_MissingJsonChunk(): TestResult {
    const bin: ArrayBuffer = new ArrayBuffer(16);
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson('')  // 空 JSON,但仍会构建 chunk
      .setBin(bin)
      .setSkipJsonChunk(true)
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.MissingJsonChunk;
    return GlbContainerAndSemanticTest.buildResult('07_MissingJsonChunk', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 8. 第一个 chunk 不是 JSON */
  private static test08_FirstChunkNotJson(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setFirstChunkType(0x004E4942)  // BIN
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.InvalidJsonChunkType;
    return GlbContainerAndSemanticTest.buildResult('08_FirstChunkNotJson', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 9. JSON chunkLength 非 4 对齐 */
  private static test09_JsonChunkLengthNotAligned(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setJsonChunkLengthOverride(13)  // 非 4 对齐
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.InvalidChunkAlignment;
    return GlbContainerAndSemanticTest.buildResult('09_JsonChunkLengthNotAligned', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 10. JSON chunk 越界 */
  private static test10_JsonChunkOutOfRange(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setJsonChunkLengthOverride(1024)  // 超出文件
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.InvalidChunkAlignment;
    return GlbContainerAndSemanticTest.buildResult('10_JsonChunkOutOfRange', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 11. BIN chunk 越界 */
  private static test11_BinChunkOutOfRange(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const bin: ArrayBuffer = new ArrayBuffer(16);
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setBin(bin)
      .setBinChunkLengthOverride(2048)  // 超出文件
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.InvalidChunkAlignment;
    return GlbContainerAndSemanticTest.buildResult('11_BinChunkOutOfRange', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 12. chunkLength = 0xFFFFFFFF */
  private static test12_ChunkLengthFFFFFFFF(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setChunkLengthFFFFFFFF(true)
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.InvalidChunkAlignment;
    return GlbContainerAndSemanticTest.buildResult('12_ChunkLengthFFFFFFFF', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 13. 文件末尾多余数据(应警告,不失败) */
  private static test13_TrailingExtraBytes(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setTrailingExtraBytes(8)
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const hasWarning: boolean = result.warnings.length > 0
      && result.warnings[0].indexOf('未声明额外数据') >= 0;
    const ok: boolean = result.valid && hasWarning;
    return GlbContainerAndSemanticTest.buildResult('13_TrailingExtraBytes', ok,
      'valid=' + result.valid + ', warnings=' + result.warnings.length);
  }

  /** 14. 空 JSON(JSON chunk 长度为 0) */
  private static test14_EmptyJson(): TestResult {
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson('')  // 空 JSON
      .setJsonChunkLengthOverride(0)
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.MissingJsonChunk;
    return GlbContainerAndSemanticTest.buildResult('14_EmptyJson', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 15. 多个 JSON chunk */
  private static test15_DuplicateJsonChunk(): TestResult {
    const json: string = '{"asset":{"version":"2.0"}}';
    const buffer: ArrayBuffer = new GlbBuilder()
      .setJson(json)
      .setDuplicateJsonChunk(true)
      .build();
    const result: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.InvalidJsonChunkType;
    return GlbContainerAndSemanticTest.buildResult('15_DuplicateJsonChunk', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  // ========== glTF 语义测试(12 项)==========

  /** 16. asset 缺失 */
  private static test16_MissingAsset(): TestResult {
    const json: string = '{"scenes":[]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 0);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.MissingAssetVersion;
    return GlbContainerAndSemanticTest.buildResult('16_MissingAsset', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 17. asset.version 错误 */
  private static test17_WrongAssetVersion(): TestResult {
    const json: string = '{"asset":{"version":"1.0"}}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 0);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.UnsupportedGltfVersion;
    return GlbContainerAndSemanticTest.buildResult('17_WrongAssetVersion', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 18. bufferView 越界 */
  private static test18_BufferViewOutOfRange(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"buffers":[{"byteLength":100}],'
      + '"bufferViews":[{"buffer":5,"byteOffset":0,"byteLength":10}]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 100);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.BufferViewOutOfRange;
    return GlbContainerAndSemanticTest.buildResult('18_BufferViewOutOfRange', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 19. accessor 越界 */
  private static test19_AccessorOutOfRange(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"buffers":[{"byteLength":100}],'
      + '"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48}],'
      + '"accessors":[{"bufferView":99,"componentType":5126,"count":3,"type":"VEC3"}]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 100);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.AccessorOutOfRange;
    return GlbContainerAndSemanticTest.buildResult('19_AccessorOutOfRange', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 20. primitive 缺 POSITION */
  private static test20_PrimitiveMissingPosition(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"buffers":[{"byteLength":100}],'
      + '"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48}],'
      + '"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],'
      + '"meshes":[{"primitives":[{"attributes":{"NORMAL":0}}]}]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 100);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.MeshPrimitiveInvalid;
    return GlbContainerAndSemanticTest.buildResult('20_PrimitiveMissingPosition', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 21. indices 越界 */
  private static test21_IndicesOutOfRange(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"buffers":[{"byteLength":100}],'
      + '"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48}],'
      + '"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],'
      + '"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":99}]}]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 100);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.IndexAccessorInvalid;
    return GlbContainerAndSemanticTest.buildResult('21_IndicesOutOfRange', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 22. node children 越界 */
  private static test22_NodeChildrenOutOfRange(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"nodes":[{"children":[99]}]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 0);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.MeshPrimitiveInvalid;
    return GlbContainerAndSemanticTest.buildResult('22_NodeChildrenOutOfRange', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 23. skin joints 越界 */
  private static test23_SkinJointsOutOfRange(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"nodes":[{}],'
      + '"skins":[{"joints":[99]}]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 0);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.MeshPrimitiveInvalid;
    return GlbContainerAndSemanticTest.buildResult('23_SkinJointsOutOfRange', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 24. required extension 不支持 */
  private static test24_UnsupportedRequiredExtension(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"extensionsRequired":["KHR_draco_mesh_compression"]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 0);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.UnsupportedRequiredExtension;
    return GlbContainerAndSemanticTest.buildResult('24_UnsupportedRequiredExtension', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 25. extensionsUsed 未知扩展(应警告,不失败) */
  private static test25_UnknownUsedExtensionWarning(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"extensionsUsed":["UNKNOWN_VENDOR_extension"]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 0);
    const hasWarning: boolean = result.warnings.length > 0
      && result.warnings[0].indexOf('未知扩展') >= 0;
    const ok: boolean = result.valid && hasWarning;
    return GlbContainerAndSemanticTest.buildResult('25_UnknownUsedExtensionWarning', ok,
      'valid=' + result.valid + ', warnings=' + result.warnings.length);
  }

  /** 26. image bufferView 越界 */
  private static test26_ImageBufferViewOutOfRange(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"images":[{"bufferView":99,"mimeType":"image/png"}]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 0);
    const ok: boolean = !result.valid && result.errorCode === ModelImportErrorCode.ImageDataInvalid;
    return GlbContainerAndSemanticTest.buildResult('26_ImageBufferViewOutOfRange', ok,
      'valid=' + result.valid + ', errorCode=' + result.errorCode);
  }

  /** 27. 正常 GLB 通过 */
  private static test27_ValidGltf(): TestResult {
    const json: string = '{"asset":{"version":"2.0","generator":"test"},'
      + '"buffers":[{"byteLength":48}],'
      + '"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48,"byteStride":12}],'
      + '"accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"}],'
      + '"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],'
      + '"nodes":[{"mesh":0}],'
      + '"scenes":[{"nodes":[0]}]}';
    const result: GltfSemanticValidationResult = GltfSemanticValidator.validate(json, 48);
    const ok: boolean = result.valid;
    return GlbContainerAndSemanticTest.buildResult('27_ValidGltf', ok,
      'valid=' + result.valid + ', warnings=' + result.warnings.length);
  }

  // ========== ModelInspector 测试(8 项)==========

  /** 28. 基础统计 */
  private static test28_InspectionBasicStats(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"scenes":[{"nodes":[0]}],'
      + '"nodes":[{"mesh":0}],'
      + '"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],'
      + '"buffers":[{"byteLength":48}],'
      + '"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48}],'
      + '"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}]}';
    const result = ModelInspector.inspect(json, 48, 200);
    const ok: boolean = result.format === 'glb'
      && result.glbVersion === 2
      && result.gltfVersion === '2.0'
      && result.sceneCount === 1
      && result.nodeCount === 1
      && result.meshCount === 1
      && result.accessorCount === 1
      && result.bufferViewCount === 1
      && result.bufferCount === 1
      && result.fileSizeBytes === 200;
    return GlbContainerAndSemanticTest.buildResult('28_InspectionBasicStats', ok,
      'fmt=' + result.format + ' v=' + result.glbVersion
      + ' scene=' + result.sceneCount + ' node=' + result.nodeCount
      + ' mesh=' + result.meshCount + ' acc=' + result.accessorCount);
  }

  /** 29. primitive 计数 */
  private static test29_PrimitiveCount(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"meshes":[{"primitives":['
      + '{"attributes":{"POSITION":0}},'
      + '{"attributes":{"POSITION":0}},'
      + '{"attributes":{"POSITION":0}}'
      + ']}]}';
    const result = ModelInspector.inspect(json, 0, 100);
    const ok: boolean = result.meshCount === 1 && result.primitiveCount === 3;
    return GlbContainerAndSemanticTest.buildResult('29_PrimitiveCount', ok,
      'mesh=' + result.meshCount + ' prim=' + result.primitiveCount);
  }

  /** 30. joint 去重计数 */
  private static test30_JointDedupCount(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"nodes":[{},{},{},{}],'
      + '"skins":[{"joints":[0,1,2]},{"joints":[1,2,3]}]}';
    const result = ModelInspector.inspect(json, 0, 100);
    const ok: boolean = result.skinCount === 2 && result.jointCount === 4;
    return GlbContainerAndSemanticTest.buildResult('30_JointDedupCount', ok,
      'skin=' + result.skinCount + ' joint=' + result.jointCount);
  }

  /** 31. morph target 计数 */
  private static test31_MorphTargetCount(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"meshes":[{"primitives":['
      + '{"attributes":{"POSITION":0},"targets":[{"POSITION":1},{"NORMAL":2}]},'
      + '{"attributes":{"POSITION":0},"targets":[{"POSITION":1}]}'
      + ']}]}';
    const result = ModelInspector.inspect(json, 0, 100);
    const ok: boolean = result.morphTargetCount === 3;
    return GlbContainerAndSemanticTest.buildResult('31_MorphTargetCount', ok,
      'morph=' + result.morphTargetCount);
  }

  /** 32. 灯光计数(KHR_lights_punctual) */
  private static test32_LightCount(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"extensions":{"KHR_lights_punctual":{"lights":[{},{},{}]}}'
      + '}';
    const result = ModelInspector.inspect(json, 0, 100);
    const ok: boolean = result.lightCount === 3
      && result.directlySupportedExtensions.indexOf('KHR_lights_punctual') >= 0;
    return GlbContainerAndSemanticTest.buildResult('32_LightCount', ok,
      'light=' + result.lightCount + ' directEx=' + result.directlySupportedExtensions.length);
  }

  /** 33. 材质类型检测 */
  private static test33_MaterialTypeDetection(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"materials":['
      + '{"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,0.5]},"alphaMode":"BLEND"},'
      + '{"pbrMetallicRoughness":{},"extensions":{"KHR_materials_unlit":{}}},'
      + '{"pbrMetallicRoughness":{}}'
      + ']}';
    const result = ModelInspector.inspect(json, 0, 100);
    const ok: boolean = result.materialCount === 3
      && result.hasPbrMaterials
      && result.hasTransparentMaterials
      && result.hasUnlitMaterials;
    return GlbContainerAndSemanticTest.buildResult('33_MaterialTypeDetection', ok,
      'mat=' + result.materialCount + ' pbr=' + result.hasPbrMaterials
      + ' trans=' + result.hasTransparentMaterials + ' unlit=' + result.hasUnlitMaterials);
  }

  /** 34. 外部资源检测 */
  private static test34_ExternalResourceDetection(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"buffers":[{"byteLength":48,"uri":"external.bin"}],'
      + '"images":[{"uri":"texture.png"},{"uri":"data:image/png;base64,iVBOR"},'
      + '{"bufferView":0,"mimeType":"image/png"}]}';
    const result = ModelInspector.inspect(json, 48, 100);
    const ok: boolean = result.hasExternalBuffers
      && result.hasExternalImages
      && result.hasEmbeddedImages;
    return GlbContainerAndSemanticTest.buildResult('34_ExternalResourceDetection', ok,
      'extBuf=' + result.hasExternalBuffers + ' extImg=' + result.hasExternalImages
      + ' embed=' + result.hasEmbeddedImages);
  }

  /** 35. 扩展分类 */
  private static test35_ExtensionClassification(): TestResult {
    const json: string = '{"asset":{"version":"2.0"},'
      + '"extensionsUsed":['
      + '"KHR_materials_unlit",'
      + '"EXT_meshopt_compression",'
      + '"KHR_draco_mesh_compression",'
      + '"UNKNOWN_extension"'
      + ']}';
    const result = ModelInspector.inspect(json, 0, 100);
    const ok: boolean = result.directlySupportedExtensions.length === 1
      && result.directlySupportedExtensions[0] === 'KHR_materials_unlit'
      && result.convertibleExtensions.length === 1
      && result.convertibleExtensions[0] === 'EXT_meshopt_compression'
      && result.unsupportedExtensions.length === 1
      && result.unsupportedExtensions[0] === 'KHR_draco_mesh_compression'
      && result.hasMeshopt
      && !result.hasMeshQuantization
      && result.hasDraco;
    return GlbContainerAndSemanticTest.buildResult('35_ExtensionClassification', ok,
      'direct=' + result.directlySupportedExtensions.length
      + ' convert=' + result.convertibleExtensions.length
      + ' unsupp=' + result.unsupportedExtensions.length);
  }

  // ========== 辅助方法 ==========

  private static buildResult(name: string, passed: boolean, message: string): TestResult {
    Logger.info(LOG_TAG, name + ': ' + (passed ? 'PASS' : 'FAIL') + ' - ' + message);
    return {
      name: name,
      passed: passed,
      message: message
    };
  }
}
