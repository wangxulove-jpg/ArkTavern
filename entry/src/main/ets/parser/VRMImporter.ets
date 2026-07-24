/**
 * VRMImporter VRM 导入编排器
 *
 * T-4.0: VRM First Architecture
 *
 * 职责:
 * 1. 接收 GLB buffer + glTF JSON
 * 2. 检测 VRM 版本(detectVrmExtension)
 * 3. 编排所有 VRM 解析器(meta/humanoid/expressions/lookAt/springBone/firstPerson)
 * 4. 生成 VrmAsset
 *
 * 非 VRM 文件返回空 VrmAsset(NonVrm)。
 *
 * 本任务仅解析,不加载 Scene、不初始化 Runtime。
 */

import { VrmVersion } from '../models/character3d/vrm/VrmVersion';
import { VrmAsset, createEmptyVrmAsset } from '../models/character3d/vrm/VrmAsset';
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import { VrmHumanoid } from '../models/character3d/vrm/VrmHumanoid';
import {
  detectVrmExtension,
  VrmExtensionDetection,
  getObject
} from './VrmExtensionParser';
import { extractVrmMeta } from './VrmMetaExtractor';
import { parseVrmHumanoid } from './VrmHumanoidMapper';
import { parseVrmExpressions } from './VrmExpressionParser';
import { parseVrmLookAt } from './VrmLookAtParser';
import { parseVrmSpringBone } from './VrmSpringBoneParser';
import { parseVrmFirstPerson } from './VrmFirstPersonParser';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'VRMImporter';

/**
 * VRMImporter 输入。
 */
export interface VrmImporterInput {
  /** glTF JSON 对象 */
  gltfJson: Record<string, Object>;
  /** 模型文件 SHA-256 */
  sourceSha256: string;
  /** glTF 节点名称列表 */
  nodeNames: string[];
  /** glTF 节点总数 */
  nodeCount: number;
  /** glTF mesh 总数 */
  meshCount: number;
  /** glTF material 总数 */
  materialCount: number;
  /** glTF image 总数 */
  imageCount: number;
}

/**
 * VRMImporter 导入结果。
 */
export interface VrmImporterResult {
  /** VRM 资产(NonVrm 时为空) */
  asset: VrmAsset;
  /** 是否 VRM */
  isVrm: boolean;
  /** 导入错误信息(空表示无错误) */
  error: string;
}

/**
 * 导入 VRM 资产。
 *
 * @param input 导入输入
 * @returns 导入结果
 */
export function importVrm(input: VrmImporterInput): VrmImporterResult {
  // 1. 检测 VRM 扩展
  const detection: VrmExtensionDetection = detectVrmExtension(input.gltfJson);
  if (!detection.isVrm) {
    return {
      asset: createEmptyVrmAsset(VrmVersion.NonVrm),
      isVrm: false,
      error: ''
    };
  }

  Logger.info(LOG_TAG, 'VRM detected: version=' + detection.version);

  // 2. 创建 VrmAsset 基础结构
  const asset: VrmAsset = createEmptyVrmAsset(detection.version);
  asset.sourceSha256 = input.sourceSha256;
  asset.nodeCount = input.nodeCount;
  asset.meshCount = input.meshCount;
  asset.materialCount = input.materialCount;
  asset.imageCount = input.imageCount;
  asset.hasMToonMaterial = detection.hasMToonMaterial;
  asset.hasNodeConstraint = detection.hasNodeConstraint;

  try {
    // 3. 解析 Meta
    asset.meta = extractVrmMeta(detection.version, detection.vrmcVrm, detection.vrm0Extension);
    Logger.info(LOG_TAG, 'Meta parsed: name=' + asset.meta.name + ', authors=' + asset.meta.authors.length);

    // 4. 解析 Humanoid
    asset.humanoid = parseVrmHumanoid(
      detection.version,
      detection.vrmcVrm,
      detection.vrm0Extension,
      input.nodeNames,
      input.nodeCount
    );
    Logger.info(LOG_TAG, 'Humanoid parsed: bones=' + asset.humanoid.bones.length
      + ', required=' + asset.humanoid.mappedRequiredCount + '/' + REQUIRED_BONES_COUNT);

    // 5. 解析 Expressions
    asset.expressions = parseVrmExpressions(detection.version, detection.vrmcVrm, detection.vrm0Extension);
    Logger.info(LOG_TAG, 'Expressions parsed: ' + asset.expressions.expressions.length
      + ' (preset=' + asset.expressions.presetCount + ', custom=' + asset.expressions.customCount + ')');

    // 6. 解析 LookAt(需要 head node index)
    const headNodeIndex: number = findHeadNodeIndex(asset.humanoid);
    asset.lookAt = parseVrmLookAt(
      detection.version,
      detection.vrmcVrm,
      detection.vrm0Extension,
      headNodeIndex
    );
    Logger.info(LOG_TAG, 'LookAt parsed: type=' + asset.lookAt.type + ', valid=' + asset.lookAt.valid);

    // 7. 解析 SpringBone
    asset.springBone = parseVrmSpringBone(detection.version, detection.vrmcSpringBone, detection.vrm0Extension);
    Logger.info(LOG_TAG, 'SpringBone parsed: springs=' + asset.springBone.springs.length
      + ', joints=' + asset.springBone.totalJointCount);

    // 8. 解析 FirstPerson
    asset.firstPerson = parseVrmFirstPerson(
      detection.version,
      detection.vrmcVrm,
      detection.vrm0Extension,
      headNodeIndex
    );
    Logger.info(LOG_TAG, 'FirstPerson parsed: annotations=' + asset.firstPerson.meshAnnotations.length);

    // 9. 整体有效性(meta + humanoid 有效)
    asset.valid = asset.meta.name.length > 0 || asset.humanoid.valid;
    asset.parseError = '';

    return {
      asset: asset,
      isVrm: true,
      error: ''
    };
  } catch (e) {
    const msg: string = (e as Error)?.message || 'unknown error';
    Logger.error(LOG_TAG, 'VRM parse failed: ' + msg);
    asset.parseError = msg;
    asset.valid = false;
    return {
      asset: asset,
      isVrm: true,
      error: msg
    };
  }
}

/** 必需骨骼数(内部常量,避免循环导入) */
const REQUIRED_BONES_COUNT: number = 7;

/**
 * 从 VrmHumanoid 查找 Head 节点索引。
 */
function findHeadNodeIndex(humanoid: VrmHumanoid): number {
  for (let i: number = 0; i < humanoid.bones.length; i++) {
    if (humanoid.bones[i].target === HumanoidBone.Head) {
      return humanoid.bones[i].nodeIndex;
    }
  }
  return -1;
}
