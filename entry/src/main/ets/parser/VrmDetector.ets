/**
 * VrmDetector VRM 身份检测器(按内容识别,非后缀)
 *
 * T-4.1 A2: VRM 身份必须按内容识别。
 *
 * 不得只根据文件后缀识别 VRM。
 * Model3DAssetStore 可能把 .vrm 复制为 .glb,
 * 必须读取 GLB JSON 根级扩展判断。
 *
 * 识别规则:
 * 1. 存在 VRMC_vrm → VRM 1.0
 * 2. 存在 VRM → VRM 0.x
 * 3. .glb 后缀但存在 VRM 扩展 → 仍然是 VRM
 * 4. .vrm 后缀但不存在任何 VRM 扩展 → InvalidVrm
 * 5. 同时存在 VRM 和 VRMC_vrm → 警告并优先 VRMC_vrm
 */

import { VrmVersion } from '../models/character3d/vrm/VrmVersion';
import { detectVrmExtension } from './VrmExtensionParser';
import { getString } from './VrmExtensionParser';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'VrmDetector';

/**
 * VRM 检测结果(增强版)。
 */
export interface VrmDetectionResult {
  /** 是否 VRM */
  isVrm: boolean;
  /** VRM 版本 */
  version: VrmVersion;
  /** 是否存在 VRM 0.x 扩展(extensions.VRM) */
  hasVrm0Extension: boolean;
  /** 是否存在 VRM 1.0 扩展(extensions.VRMC_vrm) */
  hasVrm1Extension: boolean;
  /** VRM 规范版本字符串(如 "1.0", "0.51"),无法确定时为空 */
  specVersion: string;
  /** 导出器版本(如 "UniVRM-0.108.0", "VRM-1.0-Exporter"),无法确定时为空 */
  exporterVersion: string;
  /** 警告列表 */
  warnings: string[];
}

/**
 * 按内容检测 VRM 身份。
 *
 * @param gltfJson glTF JSON 对象(来自 GLB 解析)
 * @returns VRM 检测结果
 */
export function detectVrm(gltfJson: Record<string, Object>): VrmDetectionResult {
  const detection = detectVrmExtension(gltfJson);
  const warnings: string[] = [];

  const hasVrm0: boolean = detection.vrm0Extension !== null;
  const hasVrm1: boolean = detection.vrmcVrm !== null;

  // 同时存在 VRM 0.x 和 1.0 → 警告并优先 1.0
  if (hasVrm0 && hasVrm1) {
    warnings.push('同时存在 VRM 和 VRMC_vrm 扩展,优先使用 VRMC_vrm(1.0)');
  }

  // 提取 specVersion 和 exporterVersion
  let specVersion: string = '';
  let exporterVersion: string = '';
  if (hasVrm1 && detection.vrmcVrm !== null) {
    specVersion = getString(detection.vrmcVrm, 'specVersion');
    const meta: Record<string, Object> | null = detection.vrmcVrm['meta'] !== undefined
      ? detection.vrmcVrm['meta'] as Record<string, Object> : null;
    if (meta !== null) {
      exporterVersion = getString(meta, 'exporterVersion');
    }
  } else if (hasVrm0 && detection.vrm0Extension !== null) {
    // VRM 0.x 没有显式 specVersion,从 meta.version 提取
    const meta: Record<string, Object> | null = detection.vrm0Extension['meta'] !== undefined
      ? detection.vrm0Extension['meta'] as Record<string, Object> : null;
    if (meta !== null) {
      specVersion = getString(meta, 'version');
      exporterVersion = getString(meta, 'exporterVersion');
    }
  }

  const result: VrmDetectionResult = {
    isVrm: detection.isVrm,
    version: detection.version,
    hasVrm0Extension: hasVrm0,
    hasVrm1Extension: hasVrm1,
    specVersion: specVersion,
    exporterVersion: exporterVersion,
    warnings: warnings
  };

  Logger.info(LOG_TAG, 'detectVrm: isVrm=' + result.isVrm
    + ', version=' + result.version
    + ', hasVrm0=' + result.hasVrm0Extension
    + ', hasVrm1=' + result.hasVrm1Extension
    + ', specVersion=' + result.specVersion
    + ', exporter=' + result.exporterVersion
    + ', warnings=' + result.warnings.length);

  return result;
}
