/**
 * ModelImportDiagnostics 3D 模型导入统一诊断入口
 *
 * T-3D.6D: 模型导入稳定性、兼容性诊断与自动验收
 *
 * 职责:
 * - 整合 GlbContainerValidator + GltfSemanticValidator + ModelInspector
 * - 在导入流程中作为单一诊断入口
 * - 生成 ModelImportDiagnosticReport 供调用方使用
 * - 不依赖 ArkUI / 网络 / 文件系统
 * - 失败时返回明确的 ModelImportErrorCode
 *
 * 调用关系:
 * Character3DService.importModel
 *   → ModelImportDiagnostics.diagnose(buffer)
 *     → GlbContainerValidator.validate(buffer)
 *     → GltfSemanticValidator.validate(jsonText, binLength)
 *     → ModelInspector.inspect(jsonText, binLength, fileSize)
 *   → 根据诊断结果决定继续导入或返回错误
 *
 * 设计原则:
 * - 不修改 GltfValidator(保持向后兼容)
 * - 容器校验失败 → 直接返回对应错误码
 * - 语义校验失败 → 直接返回对应错误码
 * - 扫描结果附加到 Character3DImportResult.warnings
 */

import {
  GlbContainerValidator,
  GlbContainerValidationResult
} from './GlbContainerValidator';
import {
  GltfSemanticValidator,
  GltfSemanticValidationResult
} from './GltfSemanticValidator';
import { ModelInspector } from './ModelInspector';
import {
  ModelImportErrorCode,
  ModelInspectionResult
} from '../models/character3d/ModelImportResult';

/**
 * 诊断报告。
 */
export interface ModelImportDiagnosticReport {
  /** 是否通过诊断(可继续导入流程) */
  passed: boolean;
  /** 失败时的错误码(passed=true 时为 undefined) */
  errorCode?: ModelImportErrorCode;
  /** 失败时的诊断信息(passed=true 时为空字符串) */
  diagnosticMessage: string;
  /** 模型扫描结果(到达 InspectingExtensions 阶段后非空) */
  inspection: ModelInspectionResult | null;
  /** 解析出的 JSON 文本(供后续 meshopt 转换使用,可能为空) */
  jsonText: string;
  /** 实际 BIN 长度(无 BIN 时为 0) */
  binLength: number;
  /** 警告列表(不影响 passed) */
  warnings: string[];
}

/**
 * 模型导入统一诊断器。
 *
 * 调用顺序:
 * 1. GlbContainerValidator 严格校验 GLB 容器
 * 2. 从容器结果中提取 jsonText 和 binLength
 * 3. GltfSemanticValidator 校验 glTF JSON 语义
 * 4. ModelInspector 生成详细扫描结果
 * 5. 任意步骤失败立即返回对应错误码
 */
export class ModelImportDiagnostics {
  /**
   * 执行完整诊断。
   *
   * @param buffer GLB 文件二进制内容
   * @returns 诊断报告
   */
  static diagnose(buffer: ArrayBuffer): ModelImportDiagnosticReport {
    // 1. GLB 容器严格校验
    const containerResult: GlbContainerValidationResult = GlbContainerValidator.validate(buffer);
    if (!containerResult.valid) {
      return {
        passed: false,
        errorCode: containerResult.errorCode,
        diagnosticMessage: containerResult.errorMessage,
        inspection: null,
        jsonText: '',
        binLength: 0,
        warnings: []
      } as ModelImportDiagnosticReport;
    }

    const jsonText: string = containerResult.jsonText;
    const binLength: number = containerResult.binChunkLength;

    // 2. glTF 语义校验
    const semanticResult: GltfSemanticValidationResult =
      GltfSemanticValidator.validate(jsonText, binLength);
    if (!semanticResult.valid) {
      return {
        passed: false,
        errorCode: semanticResult.errorCode,
        diagnosticMessage: semanticResult.errorMessage,
        inspection: null,
        jsonText: jsonText,
        binLength: binLength,
        warnings: semanticResult.warnings
      } as ModelImportDiagnosticReport;
    }

    // 3. 模型结构扫描
    const inspection: ModelInspectionResult = ModelInspector.inspect(
      jsonText, binLength, buffer.byteLength
    );

    // 4. 合并警告
    const warnings: string[] = [];
    for (let i: number = 0; i < semanticResult.warnings.length; i++) {
      warnings.push(semanticResult.warnings[i]);
    }
    for (let i: number = 0; i < inspection.warnings.length; i++) {
      warnings.push(inspection.warnings[i]);
    }

    return {
      passed: true,
      diagnosticMessage: '',
      inspection: inspection,
      jsonText: jsonText,
      binLength: binLength,
      warnings: warnings
    } as ModelImportDiagnosticReport;
  }
}
