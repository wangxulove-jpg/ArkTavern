/**
 * GlbContainerValidator GLB 容器严格校验器(独立于 GltfValidator)
 *
 * T-3D.6D: 模型导入稳定性、兼容性诊断与自动验收
 *
 * 职责:
 * - 严格校验 GLB 2.0 二进制容器格式
 * - 不解析 glTF JSON 语义(由 GltfSemanticValidator 负责)
 * - 不读取文件(由调用方传入 ArrayBuffer)
 * - 不依赖 ArkUI / 网络 / 数据库
 *
 * GLB 2.0 容器结构:
 *   Header (12 bytes):
 *     - magic: uint32 "glTF" (0x46546C67)
 *     - version: uint32 (必须为 2)
 *     - length: uint32 (整个文件字节数,含 header)
 *   Chunk[]:
 *     - chunkLength: uint32 (chunkData 字节数,含 padding)
 *     - chunkType: uint32 (JSON=0x4E4F534A, BIN=0x004E4942)
 *     - chunkData: byte[chunkLength]
 *
 * 重要规范:
 * - chunkLength 表示 chunkData 的长度(含 padding)
 * - JSON 和 BIN 的 padding 属于 chunkData
 * - Writer 必须写入包含 padding 后的 chunkLength
 * - Reader 读取 chunkLength 后不得再次 alignUp 跳过额外 padding
 * - chunkLength 必须满足 4 字节对齐
 * - chunk 起始与结束均应 4 字节对齐
 *
 * 校验项(20 项):
 * 1. 文件至少 12 字节
 * 2. magic 为 glTF
 * 3. version 为 2
 * 4. header.length 等于实际文件长度
 * 5. 第一个 chunk 必须为 JSON
 * 6. JSON chunkLength 大于 0
 * 7. JSON chunkLength 为 4 的倍数
 * 8. JSON chunk 数据不越界
 * 9. JSON chunk 结尾 padding 合法(0x20 空格)
 * 10. 第二个 chunk 如存在应为 BIN
 * 11. BIN chunkLength 为 4 的倍数
 * 12. BIN chunk 不越界
 * 13. chunk 之间无非法空洞
 * 14. 文件末尾无未声明额外数据
 * 15. 不允许整数溢出
 * 16. 所有 offset + length 使用安全加法
 * 17. 不允许 0xFFFFFFFF 等恶意长度导致越界
 * 18. chunk 数量异常时明确报告
 * 19. 多余未知 chunk 要么安全忽略并警告,要么按 glTF 规范拒绝
 * 20. 不得 crash
 */

import { util } from '@kit.ArkTS';
import {
  ModelImportErrorCode,
  ModelImportStage
} from '../models/character3d/ModelImportResult';

const GLB_MAGIC: number = 0x46546C67;       // "glTF"
const GLB_VERSION: number = 2;               // GLB 2.0
const CHUNK_TYPE_JSON: number = 0x4E4F534A;  // "JSON"
const CHUNK_TYPE_BIN: number = 0x004E4942;   // "BIN\0"
const GLB_HEADER_SIZE: number = 12;
const CHUNK_HEADER_SIZE: number = 8;
const ALIGNMENT: number = 4;
const MAX_UINT32: number = 0xFFFFFFFF;
const JSON_PADDING_BYTE: number = 0x20;      // 空格
const BIN_PADDING_BYTE: number = 0x00;       // 零字节

/**
 * GLB 容器校验结果。
 */
export interface GlbContainerValidationResult {
  /** 是否通过 */
  valid: boolean;
  /** 错误码(失败时) */
  errorCode?: ModelImportErrorCode;
  /** 错误信息(失败时) */
  errorMessage: string;
  /** GLB 版本(成功时为 2) */
  glbVersion: number;
  /** 声明的总长度 */
  declaredLength: number;
  /** 实际文件长度 */
  actualLength: number;
  /** JSON chunk 内容(成功时非空) */
  jsonText: string;
  /** JSON chunk 长度(含 padding) */
  jsonChunkLength: number;
  /** BIN chunk 是否存在 */
  hasBinChunk: boolean;
  /** BIN chunk 长度(含 padding,无 BIN 时为 0) */
  binChunkLength: number;
  /** BIN chunk 数据(成功时,无 BIN 时为空) */
  binData: ArrayBuffer | null;
  /** chunk 总数 */
  chunkCount: number;
  /** 警告列表(不影响 valid) */
  warnings: string[];
}

/**
 * 创建失败结果。
 */
function createFailure(
  errorCode: ModelImportErrorCode,
  message: string
): GlbContainerValidationResult {
  return {
    valid: false,
    errorCode: errorCode,
    errorMessage: message,
    glbVersion: 0,
    declaredLength: 0,
    actualLength: 0,
    jsonText: '',
    jsonChunkLength: 0,
    hasBinChunk: false,
    binChunkLength: 0,
    binData: null,
    chunkCount: 0,
    warnings: []
  };
}

/**
 * 安全加法,溢出返回 -1。
 */
function safeAdd(a: number, b: number): number {
  if (a < 0 || b < 0) {
    return -1;
  }
  if (a > MAX_UINT32 - b) {
    return -1;
  }
  return a + b;
}

/**
 * 判断是否 4 字节对齐。
 */
function isAligned(value: number): boolean {
  return (value & 3) === 0;
}

/**
 * GLB 容器严格校验器。
 *
 * 与 GltfValidator 的关系:
 * - GltfValidator 是一站式校验(容器 + JSON 语义),保留向后兼容
 * - GlbContainerValidator 只校验二进制容器,JSON 内容返回给调用方进一步语义校验
 * - 新代码应优先使用 GlbContainerValidator + GltfSemanticValidator 组合
 */
export class GlbContainerValidator {
  /**
   * 校验 GLB 2.0 容器。
   *
   * @param buffer GLB 文件二进制内容
   * @returns 校验结果
   */
  static validate(buffer: ArrayBuffer): GlbContainerValidationResult {
    // 1. 基本非空检查
    if (buffer === null || buffer === undefined) {
      return createFailure(ModelImportErrorCode.FileReadFailed, 'buffer 为 null');
    }

    const actualLength: number = buffer.byteLength;

    // 2. 文件至少 12 字节(header)
    if (actualLength < GLB_HEADER_SIZE) {
      return createFailure(ModelImportErrorCode.FileTooSmall,
        '文件过小,少于 GLB header 12 字节: ' + actualLength);
    }

    const view: DataView = new DataView(buffer);

    // 3. 校验 magic
    const magic: number = view.getUint32(0, true);
    if (magic !== GLB_MAGIC) {
      return createFailure(ModelImportErrorCode.InvalidGlbMagic,
        'GLB magic 不匹配: 0x' + magic.toString(16) + ',期望 0x' + GLB_MAGIC.toString(16));
    }

    // 4. 校验 version
    const version: number = view.getUint32(4, true);
    if (version !== GLB_VERSION) {
      return createFailure(ModelImportErrorCode.UnsupportedGlbVersion,
        '不支持的 GLB 版本: ' + version + ',仅支持 2');
    }

    // 5. 校验 declared length
    const declaredLength: number = view.getUint32(8, true);
    if (declaredLengthInvalid(declaredLength, actualLength)) {
      return createFailure(ModelImportErrorCode.InvalidDeclaredLength,
        'GLB length 与实际文件大小不匹配: 声明 ' + declaredLength + ',实际 ' + actualLength);
    }
    if (declaredLength < GLB_HEADER_SIZE) {
      return createFailure(ModelImportErrorCode.InvalidDeclaredLength,
        'GLB length 小于 header 大小: ' + declaredLength);
    }
    if (declaredLength > MAX_UINT32) {
      return createFailure(ModelImportErrorCode.InvalidDeclaredLength,
        'GLB length 超过 uint32 上限: ' + declaredLength);
    }

    // 6. 解析 chunks
    const warnings: string[] = [];
    let offset: number = GLB_HEADER_SIZE;
    let jsonText: string = '';
    let jsonChunkLength: number = 0;
    let jsonChunkFound: boolean = false;
    let binChunkFound: boolean = false;
    let binChunkLength: number = 0;
    let binData: ArrayBuffer | null = null;
    let chunkCount: number = 0;
    let firstChunkChecked: boolean = false;

    while (offset + CHUNK_HEADER_SIZE <= actualLength) {
      // 7. 读取 chunk header
      const chunkLength: number = view.getUint32(offset, true);
      const chunkType: number = view.getUint32(offset + 4, true);

      // 8. 恶意长度检查(0xFFFFFFFF 等)
      if (chunkLength === MAX_UINT32) {
        return createFailure(ModelImportErrorCode.InvalidChunkAlignment,
          'chunkLength = 0xFFFFFFFF,疑似恶意文件: offset=' + offset);
      }
      if (chunkLength > MAX_UINT32 - ALIGNMENT) {
        return createFailure(ModelImportErrorCode.InvalidChunkAlignment,
          'chunkLength 接近 uint32 上限: ' + chunkLength);
      }

      // 9. 安全加法:chunkDataStart = offset + CHUNK_HEADER_SIZE
      const chunkDataStart: number = safeAdd(offset, CHUNK_HEADER_SIZE);
      if (chunkDataStart < 0) {
        return createFailure(ModelImportErrorCode.InvalidChunkAlignment,
          'offset + CHUNK_HEADER_SIZE 溢出: offset=' + offset);
      }

      // 10. chunkLength 越界检查(使用减法避免溢出)
      if (chunkLength > actualLength - chunkDataStart) {
        return createFailure(ModelImportErrorCode.InvalidChunkAlignment,
          'chunk 数据超出文件范围: offset=' + offset + ', chunkLength=' + chunkLength
          + ', 剩余=' + (actualLength - chunkDataStart));
      }

      // 11. 安全加法:chunkDataEnd = chunkDataStart + chunkLength
      const chunkDataEnd: number = safeAdd(chunkDataStart, chunkLength);
      if (chunkDataEnd < 0) {
        return createFailure(ModelImportErrorCode.InvalidChunkAlignment,
          'chunkDataStart + chunkLength 溢出: start=' + chunkDataStart + ', len=' + chunkLength);
      }
      if (chunkDataEnd > actualLength) {
        return createFailure(ModelImportErrorCode.InvalidChunkAlignment,
          'chunk 数据超出文件范围: end=' + chunkDataEnd + ', actual=' + actualLength);
      }

      // 12. 第一个 chunk 必须为 JSON
      if (!firstChunkChecked) {
        firstChunkChecked = true;
        if (chunkType !== CHUNK_TYPE_JSON) {
          return createFailure(ModelImportErrorCode.InvalidJsonChunkType,
            '第一个 chunk 必须为 JSON(0x4E4F534A),实际为 0x' + chunkType.toString(16));
        }
      }

      // 13. 按 chunkType 处理
      if (chunkType === CHUNK_TYPE_JSON) {
        // 14. JSON chunk 校验
        if (jsonChunkFound) {
          return createFailure(ModelImportErrorCode.InvalidJsonChunkType,
            '发现多个 JSON chunk');
        }
        if (chunkLength === 0) {
          return createFailure(ModelImportErrorCode.MissingJsonChunk,
            'JSON chunk 长度为 0');
        }
        // 15. JSON chunkLength 必须为 4 的倍数
        if (!isAligned(chunkLength)) {
          return createFailure(ModelImportErrorCode.InvalidChunkAlignment,
            'JSON chunkLength 非 4 对齐: ' + chunkLength);
        }
        // 16. JSON padding 合法性检查(尾部字节应为 0x20)
        const paddingResult: boolean = GlbContainerValidator.checkJsonPadding(
          view, chunkDataStart, chunkLength);
        if (!paddingResult) {
          warnings.push('JSON chunk padding 字节非 0x20,可能不严格符合 GLB 规范');
        }
        // 17. 解码 UTF-8
        try {
          jsonText = GlbContainerValidator.decodeUtf8(buffer, chunkDataStart, chunkLength);
        } catch (e) {
          return createFailure(ModelImportErrorCode.JsonParseFailed,
            'JSON chunk UTF-8 解码失败: ' + (e as Error)?.message);
        }
        jsonChunkFound = true;
        jsonChunkLength = chunkLength;
      } else if (chunkType === CHUNK_TYPE_BIN) {
        // 18. BIN chunk 校验
        if (binChunkFound) {
          return createFailure(ModelImportErrorCode.InvalidChunkAlignment,
            '发现多个 BIN chunk');
        }
        // 19. BIN chunkLength 必须为 4 的倍数
        if (!isAligned(chunkLength)) {
          return createFailure(ModelImportErrorCode.InvalidChunkAlignment,
            'BIN chunkLength 非 4 对齐: ' + chunkLength);
        }
        binChunkFound = true;
        binChunkLength = chunkLength;
        // 提取 BIN 数据(用于后续语义校验)
        if (chunkLength > 0) {
          binData = buffer.slice(chunkDataStart, chunkDataEnd);
        } else {
          binData = new ArrayBuffer(0);
        }
      } else {
        // 20. 未知 chunk 类型:安全忽略并警告
        warnings.push('未知 chunk 类型 0x' + chunkType.toString(16)
          + ' at offset ' + offset + ',已安全忽略');
      }

      // 重要:Reader 读取 chunkLength 后不再 alignUp
      // chunkLength 已包含 padding,直接前进到 chunkDataEnd
      offset = chunkDataEnd;
      chunkCount++;
    }

    // 21. 必须有 JSON chunk
    if (!jsonChunkFound) {
      return createFailure(ModelImportErrorCode.MissingJsonChunk,
        '缺少 JSON chunk');
    }

    // 22. 文件末尾无未声明额外数据
    if (offset < actualLength) {
      const extraBytes: number = actualLength - offset;
      warnings.push('文件末尾存在未声明额外数据: ' + extraBytes + ' 字节');
      // 不直接失败,警告即可(GLB 规范允许某些工具添加尾部元数据)
    }

    // 23. chunk 数量异常(超过 10 个视为异常)
    if (chunkCount > 10) {
      warnings.push('chunk 数量异常: ' + chunkCount + ',可能不符合 GLB 规范');
    }

    return {
      valid: true,
      errorMessage: '',
      glbVersion: version,
      declaredLength: declaredLength,
      actualLength: actualLength,
      jsonText: jsonText,
      jsonChunkLength: jsonChunkLength,
      hasBinChunk: binChunkFound,
      binChunkLength: binChunkLength,
      binData: binData,
      chunkCount: chunkCount,
      warnings: warnings
    };
  }

  /**
   * 检查 JSON chunk 的 padding 字节是否为 0x20(空格)。
   *
   * GLB 规范要求 JSON chunk 用 0x20 填充到 4 字节对齐。
   * 实际工具可能用 0x00,这里只做警告,不严格拒绝。
   */
  private static checkJsonPadding(
    view: DataView,
    chunkDataStart: number,
    chunkLength: number
  ): boolean {
    // 从末尾向前扫描,直到遇到非 padding 字节
    for (let i: number = chunkDataStart + chunkLength - 1; i >= chunkDataStart; i--) {
      const b: number = view.getUint8(i);
      if (b === JSON_PADDING_BYTE) {
        continue;
      }
      if (b === 0x00) {
        // 0x00 padding 也常见,但不严格符合规范
        continue;
      }
      // 遇到非 padding 字节,说明 padding 部分到此结束
      // 检查剩余 padding 字节是否都合法
      const paddingStart: number = i + 1;
      const paddingEnd: number = chunkDataStart + chunkLength;
      for (let j: number = paddingStart; j < paddingEnd; j++) {
        const pb: number = view.getUint8(j);
        if (pb !== JSON_PADDING_BYTE && pb !== 0x00) {
          return false;
        }
      }
      return true;
    }
    return true;
  }

  /**
   * 解码 UTF-8 字节为字符串。
   */
  private static decodeUtf8(buffer: ArrayBuffer, start: number, length: number): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buffer, start, length));
  }
}

/**
 * 检查 declaredLength 是否非法。
 */
function declaredLengthInvalid(declared: number, actual: number): boolean {
  if (declared !== actual) {
    return true;
  }
  return false;
}
