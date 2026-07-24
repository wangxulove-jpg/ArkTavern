/**
 * VrmHumanoidPipelineTest VRM Humanoid 闭环管线测试
 *
 * T-4.1 A6-A11: VRM 显式骨骼映射闭环测试
 *
 * 职责:
 * - 验证 VrmDeclared 映射方法(BoneMappingMethod.VrmDeclared)
 * - 验证无效 nodeIndex 处理(跳过 + warning)
 * - 验证未知骨骼 key 处理(parseVrmHumanoidBoneKey 返回 null)
 * - 验证重复骨骼处理(跳过 + duplicate 计数)
 * - 验证 VRM 显式映射优先于名称匹配
 * - 验证旧 0 缓存重建逻辑(VRM_HUMANOID_PARSER_VERSION)
 * - 验证 VrmAsset 保存和重新读取(序列化 + 反序列化)
 *
 * 与 VrmParserTest 互补:
 * - VrmParserTest 覆盖基础解析(test01-test20)
 * - 本测试聚焦 T-4.1 新增的 VrmHumanoidResolver + VrmDeclared 闭环
 *
 * 不依赖 ArkUI / ArkGraphics3D / 文件系统,可独立运行。
 */

import { VrmVersion } from '../models/character3d/vrm/VrmVersion';
import { HumanoidBone, BoneMappingResult } from '../models/character3d/HumanoidBone';
import { BoneMappingMethod } from '../models/character3d/ManualHumanoidMapping';
import { parseVrmHumanoidBoneKey } from '../parser/VrmBoneKeyParser';
import { parseVrmHumanoid } from '../parser/VrmHumanoidMapper';
import {
  resolveVrmHumanoid,
  vrmParseResultToBoneMappingResult,
  VrmHumanoidParseResult,
  VRM_HUMANOID_PARSER_VERSION
} from '../parser/VrmHumanoidResolver';
import {
  serializeVrmAsset,
  deserializeVrmAsset
} from '../storage/VrmMetaStore';
import { importVrm, VrmImporterInput } from '../parser/VRMImporter';
import {
  HumanoidProvider,
  HumanoidProviderInput,
  HumanoidMappingSource
} from '../services/HumanoidProvider';
import { VrmAsset } from '../models/character3d/vrm/VrmAsset';
import { VrmHumanoid, VrmHumanoidBone } from '../models/character3d/vrm/VrmHumanoid';

/** 单项测试结果 */
export interface PipelineTestResult {
  name: string;
  passed: boolean;
  message: string;
}

/** 全部测试结果汇总 */
export interface PipelineTestSuiteResult {
  total: number;
  passed: number;
  failed: number;
  results: PipelineTestResult[];
}

/**
 * 测试入口。
 */
export function runVrmHumanoidPipelineTests(): PipelineTestSuiteResult {
  return VrmHumanoidPipelineTestSuite.runAllTests();
}

/**
 * VRM Humanoid 闭环管线测试套件。
 */
class VrmHumanoidPipelineTestSuite {
  static runAllTests(): PipelineTestSuiteResult {
    const results: PipelineTestResult[] = [];
    results.push(VrmHumanoidPipelineTestSuite.test01_VrmDeclaredBindingMethod());
    results.push(VrmHumanoidPipelineTestSuite.test02_InvalidNodeIndexSkipped());
    results.push(VrmHumanoidPipelineTestSuite.test03_UnknownBoneKeyReturnsNull());
    results.push(VrmHumanoidPipelineTestSuite.test04_DuplicateBoneSkipped());
    results.push(VrmHumanoidPipelineTestSuite.test05_VrmExplicitOverAutoNameMatch());
    results.push(VrmHumanoidPipelineTestSuite.test06_ParserVersionConstant());
    results.push(VrmHumanoidPipelineTestSuite.test07_VrmAssetSerializeDeserialize());
    results.push(VrmHumanoidPipelineTestSuite.test08_BoneMappingResultPersistRoundtrip());
    results.push(VrmHumanoidPipelineTestSuite.test09_StaleZeroCacheRebuildDecision());
    results.push(VrmHumanoidPipelineTestSuite.test10_Vrm0xArrayFormatParsed());

    let passed: number = 0;
    let failed: number = 0;
    for (let i: number = 0; i < results.length; i++) {
      if (results[i].passed) {
        passed++;
      } else {
        failed++;
      }
    }
    return {
      total: results.length,
      passed: passed,
      failed: failed,
      results: results
    };
  }

  private static buildResult(
    name: string, condition: boolean, detail: string = ''
  ): PipelineTestResult {
    if (condition) {
      return { name: name, passed: true, message: '' };
    }
    return { name: name, passed: false, message: detail };
  }

  /**
   * 用 JSON.parse 构建 Record<string, Object>(避免 ArkTS 嵌套对象字面量限制)。
   */
  private static parseJson(json: string): Record<string, Object> {
    return JSON.parse(json) as Record<string, Object>;
  }

  // ==================== 1. VrmDeclared 映射方法 ====================

  /** 1. resolveVrmHumanoid 输出的 binding 必须是 VrmDeclared */
  private static test01_VrmDeclaredBindingMethod(): PipelineTestResult {
    const vrmcVrm: Record<string, Object> = VrmHumanoidPipelineTestSuite.parseJson(
      '{"specVersion":"1.0","humanoid":{"humanBones":{'
      + '"hips":{"node":0,"useDefaultValues":true},'
      + '"head":{"node":5,"useDefaultValues":true}'
      + '}}}');
    const nodeNames: string[] = ['hips_node', 'n1', 'n2', 'n3', 'n4', 'head_node'];
    const humanoid = parseVrmHumanoid(VrmVersion.Vrm1, vrmcVrm, null, nodeNames, 6);
    const parseResult: VrmHumanoidParseResult = resolveVrmHumanoid(humanoid, nodeNames, 6);

    const ok: boolean = parseResult.validBoneCount === 2
      && parseResult.bindings.length === 2
      && parseResult.bindings[0].mappingMethod === BoneMappingMethod.VrmDeclared
      && parseResult.bindings[1].mappingMethod === BoneMappingMethod.VrmDeclared
      && parseResult.bindings[0].confidence === 1.0;
    return VrmHumanoidPipelineTestSuite.buildResult(
      '01_VrmDeclaredBindingMethod', ok,
      'valid=' + parseResult.validBoneCount + ', bindings=' + parseResult.bindings.length
      + ', method=' + (parseResult.bindings.length > 0 ? parseResult.bindings[0].mappingMethod : 'N/A')
    );
  }

  // ==================== 2. 无效 nodeIndex 处理 ====================

  /** 2. nodeIndex 越界时跳过并记录 warning */
  private static test02_InvalidNodeIndexSkipped(): PipelineTestResult {
    const vrmcVrm: Record<string, Object> = VrmHumanoidPipelineTestSuite.parseJson(
      '{"specVersion":"1.0","humanoid":{"humanBones":{'
      + '"hips":{"node":0,"useDefaultValues":true},'
      + '"head":{"node":99,"useDefaultValues":true}'
      + '}}}');
    const nodeNames: string[] = ['hips', 'n1', 'n2', 'n3', 'n4'];
    const humanoid = parseVrmHumanoid(VrmVersion.Vrm1, vrmcVrm, null, nodeNames, 5);
    const parseResult: VrmHumanoidParseResult = resolveVrmHumanoid(humanoid, nodeNames, 5);

    const ok: boolean = parseResult.validBoneCount === 1
      && parseResult.bindings.length === 1
      && parseResult.bindings[0].targetJoint === HumanoidBone.Hips;
    return VrmHumanoidPipelineTestSuite.buildResult(
      '02_InvalidNodeIndexSkipped', ok,
      'valid=' + parseResult.validBoneCount + ', expected=1'
    );
  }

  // ==================== 3. 未知骨骼 key 处理 ====================

  /** 3. parseVrmHumanoidBoneKey 未知键返回 null */
  private static test03_UnknownBoneKeyReturnsNull(): PipelineTestResult {
    const known: HumanoidBone | null = parseVrmHumanoidBoneKey('leftUpperArm');
    const unknown1: HumanoidBone | null = parseVrmHumanoidBoneKey('unknownBone');
    const unknown2: HumanoidBone | null = parseVrmHumanoidBoneKey('');
    const caseInsensitive: HumanoidBone | null = parseVrmHumanoidBoneKey('LeftUpperArm');

    const ok: boolean = known === HumanoidBone.LeftUpperArm
      && unknown1 === null
      && unknown2 === null
      && caseInsensitive === HumanoidBone.LeftUpperArm;
    return VrmHumanoidPipelineTestSuite.buildResult(
      '03_UnknownBoneKeyReturnsNull', ok,
      'known=' + known + ', unknown1=' + unknown1 + ', caseInsensitive=' + caseInsensitive
    );
  }

  // ==================== 4. 重复骨骼处理 ====================

  /** 4. 同一 HumanoidBone 被多次声明时,后者跳过并计入 duplicateBoneCount */
  private static test04_DuplicateBoneSkipped(): PipelineTestResult {
    const nodeNames: string[] = ['hips', 'n1', 'n2', 'n3', 'n4', 'head'];
    // 手动构造重复:hips 声明两次
    const hips1: VrmHumanoidBone = {
      target: HumanoidBone.Hips,
      vrmBoneName: 'hips',
      nodeIndex: 0,
      nodeName: 'hips',
      useDefaultValues: true,
      confidence: 1.0
    };
    const hips2: VrmHumanoidBone = {
      target: HumanoidBone.Hips,
      vrmBoneName: 'hips_dup',
      nodeIndex: 1,
      nodeName: 'n1',
      useDefaultValues: true,
      confidence: 1.0
    };
    const head: VrmHumanoidBone = {
      target: HumanoidBone.Head,
      vrmBoneName: 'head',
      nodeIndex: 5,
      nodeName: 'head',
      useDefaultValues: true,
      confidence: 1.0
    };
    const duplicated: VrmHumanoid = {
      version: VrmVersion.Vrm1,
      bones: [hips1, hips2, head],
      extendedBones: [],
      totalMappedCount: 3,
      mappedRequiredCount: 2,
      missingRequired: [],
      missingOptional: [],
      valid: true,
      humanoidHash: 'test_dup_hash'
    };
    const parseResult: VrmHumanoidParseResult = resolveVrmHumanoid(duplicated, nodeNames, 6);

    const ok: boolean = parseResult.validBoneCount === 2
      && parseResult.duplicateBoneCount === 1
      && parseResult.warnings.length >= 1;
    return VrmHumanoidPipelineTestSuite.buildResult(
      '04_DuplicateBoneSkipped', ok,
      'valid=' + parseResult.validBoneCount + ', duplicate=' + parseResult.duplicateBoneCount
      + ', warnings=' + parseResult.warnings.length
    );
  }

  // ==================== 5. VRM 显式映射优先于名称匹配 ====================

  /** 5. HumanoidProvider 中 VRM 显式映射覆盖 Auto 名称匹配 */
  private static test05_VrmExplicitOverAutoNameMatch(): PipelineTestResult {
    const vrmcVrm: Record<string, Object> = VrmHumanoidPipelineTestSuite.parseJson(
      '{"specVersion":"1.0","humanoid":{"humanBones":{'
      + '"head":{"node":5}'
      + '}}}');
    const nodeNames: string[] = ['n0', 'n1', 'n2', 'n3', 'n4', 'head_vrm'];
    const vrmHumanoid = parseVrmHumanoid(VrmVersion.Vrm1, vrmcVrm, null, nodeNames, 10);

    // Auto 映射:head → node 99(应被 VRM 覆盖)
    const autoMapping: Map<HumanoidBone, number> = new Map();
    autoMapping.set(HumanoidBone.Head, 99);

    const input: HumanoidProviderInput = {
      vrmHumanoid: vrmHumanoid,
      manualMapping: null,
      autoMapping: autoMapping
    };
    const provider = new HumanoidProvider(input);
    const head = provider.getHead();

    const ok: boolean = head.mapped
      && head.source === HumanoidMappingSource.VrmExplicit
      && head.nodeIndex === 5
      && head.confidence === 1.0;
    return VrmHumanoidPipelineTestSuite.buildResult(
      '05_VrmExplicitOverAutoNameMatch', ok,
      'source=' + head.source + ', node=' + head.nodeIndex + ', conf=' + head.confidence
    );
  }

  // ==================== 6. 解析器版本常量 ====================

  /** 6. VRM_HUMANOID_PARSER_VERSION 存在且 > 0(用于缓存失效) */
  private static test06_ParserVersionConstant(): PipelineTestResult {
    const ok: boolean = VRM_HUMANOID_PARSER_VERSION > 0;
    return VrmHumanoidPipelineTestSuite.buildResult(
      '06_ParserVersionConstant', ok,
      'version=' + VRM_HUMANOID_PARSER_VERSION
    );
  }

  // ==================== 7. VrmAsset 序列化/反序列化 ====================

  /** 7. VrmAsset 通过 serializeVrmAsset/deserializeVrmAsset 完整往返 */
  private static test07_VrmAssetSerializeDeserialize(): PipelineTestResult {
    const gltfJson: Record<string, Object> = VrmHumanoidPipelineTestSuite.parseJson(
      '{"asset":{"version":"2.0"},'
      + '"extensions":{"VRMC_vrm":{'
      + '"specVersion":"1.0",'
      + '"meta":{"name":"PipelineTestAvatar","version":"1.0","authors":["Tester"]},'
      + '"humanoid":{"humanBones":{'
      + '"hips":{"node":0},"spine":{"node":1},"head":{"node":5},'
      + '"leftUpperArm":{"node":10},"rightUpperArm":{"node":20},'
      + '"leftUpperLeg":{"node":15},"rightUpperLeg":{"node":25}'
      + '}}}},'
      + '"extensionsUsed":["VRMC_vrm"]}');
    const nodeNames: string[] = [];
    for (let i: number = 0; i < 30; i++) {
      nodeNames.push('node_' + i);
    }
    const input: VrmImporterInput = {
      gltfJson: gltfJson,
      sourceSha256: 'sha_pipeline_test',
      nodeNames: nodeNames,
      nodeCount: 30,
      meshCount: 1,
      materialCount: 1,
      imageCount: 0
    };
    const vrmResult = importVrm(input);
    if (!vrmResult.isVrm || !vrmResult.asset.valid) {
      return VrmHumanoidPipelineTestSuite.buildResult(
        '07_VrmAssetSerializeDeserialize', false,
        'VRM import failed: isVrm=' + vrmResult.isVrm + ', valid=' + vrmResult.asset.valid
      );
    }

    const json: string = serializeVrmAsset(vrmResult.asset);
    const restored: VrmAsset | null = deserializeVrmAsset(json);

    const ok: boolean = restored !== null
      && restored!.valid
      && restored!.version === VrmVersion.Vrm1
      && restored!.meta.name === 'PipelineTestAvatar'
      && restored!.humanoid.valid
      && restored!.humanoid.bones.length === 7
      && restored!.sourceSha256 === 'sha_pipeline_test';
    return VrmHumanoidPipelineTestSuite.buildResult(
      '07_VrmAssetSerializeDeserialize', ok,
      'restored=' + (restored !== null) + ', bones=' + (restored !== null ? restored.humanoid.bones.length : 0)
    );
  }

  // ==================== 8. BoneMappingResult JSON 持久化往返 ====================

  /** 8. vrmParseResultToBoneMappingResult 输出可 JSON.stringify/parse 往返 */
  private static test08_BoneMappingResultPersistRoundtrip(): PipelineTestResult {
    const vrmcVrm: Record<string, Object> = VrmHumanoidPipelineTestSuite.parseJson(
      '{"specVersion":"1.0","humanoid":{"humanBones":{'
      + '"hips":{"node":0},'
      + '"head":{"node":5}'
      + '}}}');
    const nodeNames: string[] = ['hips', 'n1', 'n2', 'n3', 'n4', 'head'];
    const humanoid = parseVrmHumanoid(VrmVersion.Vrm1, vrmcVrm, null, nodeNames, 6);
    const parseResult: VrmHumanoidParseResult = resolveVrmHumanoid(humanoid, nodeNames, 6);
    const boneMapping = vrmParseResultToBoneMappingResult(parseResult, nodeNames, 'test_model');

    const json: string = JSON.stringify(boneMapping);
    const restored: BoneMappingResult = JSON.parse(json) as BoneMappingResult;

    const ok: boolean = restored.mappings.length === 2
      && restored.mappings[0].sourceNodeIndex === 0
      && restored.mappings[0].confidence === 1.0
      && restored.mappings[1].sourceNodeIndex === 5;
    return VrmHumanoidPipelineTestSuite.buildResult(
      '08_BoneMappingResultPersistRoundtrip', ok,
      'mappings=' + restored.mappings.length + ', hipNode=' + restored.mappings[0].sourceNodeIndex
    );
  }

  // ==================== 9. 旧 0 缓存重建决策 ====================

  /** 9. 模拟旧 0 缓存(isVrm=true 但 bindingCount=0)应触发重建决策 */
  private static test09_StaleZeroCacheRebuildDecision(): PipelineTestResult {
    // 模拟旧缓存:VRM 检测为 true,但 bindingCount=0(旧自动匹配未识别)
    const staleCacheInfo: StaleCacheInfo = {
      isVrm: true,
      bindingCount: 0,
      mappingSource: 'AutoDetected',
      parserVersion: 0
    };
    const needsRebuild: boolean = staleCacheInfo.isVrm
      && (staleCacheInfo.bindingCount === 0
        || staleCacheInfo.mappingSource === 'AutoDetected'
        || staleCacheInfo.parserVersion < VRM_HUMANOID_PARSER_VERSION);

    // 模拟新缓存:VRM 检测为 true,bindingCount>0,VrmDeclared,parserVersion=CURRENT
    const freshCacheInfo: StaleCacheInfo = {
      isVrm: true,
      bindingCount: 7,
      mappingSource: 'VrmDeclared',
      parserVersion: VRM_HUMANOID_PARSER_VERSION
    };
    const freshNeedsRebuild: boolean = freshCacheInfo.isVrm
      && (freshCacheInfo.bindingCount === 0
        || freshCacheInfo.mappingSource === 'AutoDetected'
        || freshCacheInfo.parserVersion < VRM_HUMANOID_PARSER_VERSION);

    const ok: boolean = needsRebuild && !freshNeedsRebuild;
    return VrmHumanoidPipelineTestSuite.buildResult(
      '09_StaleZeroCacheRebuildDecision', ok,
      'staleRebuild=' + needsRebuild + ', freshRebuild=' + freshNeedsRebuild
    );
  }

  // ==================== 10. VRM 0.x 数组格式解析 ====================

  /** 10. VRM 0.x humanBones 数组格式正确解析(node 字段为节点索引) */
  private static test10_Vrm0xArrayFormatParsed(): PipelineTestResult {
    const vrm0Ext: Record<string, Object> = VrmHumanoidPipelineTestSuite.parseJson(
      '{"humanoid":{"humanBones":['
      + '{"bone":"hips","node":0,"useDefaultValues":true},'
      + '{"bone":"spine","node":1,"useDefaultValues":true},'
      + '{"bone":"head","node":2,"useDefaultValues":true},'
      + '{"bone":"leftUpperArm","node":10,"useDefaultValues":true},'
      + '{"bone":"rightUpperArm","node":20,"useDefaultValues":true},'
      + '{"bone":"leftUpperLeg","node":15,"useDefaultValues":true},'
      + '{"bone":"rightUpperLeg","node":25,"useDefaultValues":true}'
      + ']}}');
    const nodeNames: string[] = [];
    for (let i: number = 0; i < 30; i++) {
      nodeNames.push('J_Bip_node_' + i);
    }
    const humanoid = parseVrmHumanoid(VrmVersion.Vrm0x, null, vrm0Ext, nodeNames, 30);
    const parseResult: VrmHumanoidParseResult = resolveVrmHumanoid(humanoid, nodeNames, 30);

    const ok: boolean = parseResult.detected
      && parseResult.version === VrmVersion.Vrm0x
      && parseResult.validBoneCount === 7
      && parseResult.missingRequired.length === 0
      && parseResult.bindings[0].mappingMethod === BoneMappingMethod.VrmDeclared
      && parseResult.bindings[0].sourceNodeIndex === 0
      && parseResult.bindings[2].sourceNodeIndex === 2
      && parseResult.bindings[2].sourceBoneName === 'J_Bip_node_2';
    return VrmHumanoidPipelineTestSuite.buildResult(
      '10_Vrm0xArrayFormatParsed', ok,
      'valid=' + parseResult.validBoneCount + ', missing=' + parseResult.missingRequired.length
      + ', headNode=' + parseResult.bindings[2].sourceNodeIndex
    );
  }
}

/**
 * 旧缓存信息(模拟 T-4.1 A11 缓存校验)。
 */
interface StaleCacheInfo {
  isVrm: boolean;
  bindingCount: number;
  mappingSource: string;
  parserVersion: number;
}
