/**
 * VrmParserTest VRM 解析器单元测试
 *
 * T-4.0: VRM First Architecture
 *
 * 职责:
 * - 测试 VrmExtensionParser(VRM 0.x / 1.0 / 非 VRM 检测)
 * - 测试 VrmMetaExtractor(VRM 1.0 / 0.x 元信息解析)
 * - 测试 VrmHumanoidMapper(显式骨骼映射)
 * - 测试 VrmExpressionParser(表情预设)
 * - 测试 VrmLookAtParser(视线配置)
 * - 测试 VrmSpringBoneParser(物理骨骼)
 * - 测试 VrmFirstPersonParser(第一人称配置)
 * - 测试 VRMImporter(编排器)
 * - 测试 HumanoidProvider(VRM 优先级)
 * - 测试 ModelCapabilityReport VRM 维度
 * - 测试 VrmMetaStore 序列化
 *
 * 使用合成 glTF JSON 数据,不依赖真实 VRM 文件。
 * 测试通过 Logger 输出结果,集成到 Character3DPocPage Debug 入口。
 *
 * 不依赖 ArkUI / ArkGraphics3D / 文件系统,可独立运行。
 */

import { Logger } from '../utils/Logger';
import { VrmVersion, isVrm } from '../models/character3d/vrm/VrmVersion';
import { VrmAsset, createEmptyVrmAsset } from '../models/character3d/vrm/VrmAsset';
import {
  detectVrmExtension,
  getObject,
  getString,
  getNumber,
  getBoolean,
  getStringArray,
  getNumberArray,
  getObjectArray,
  getObjectEntries
} from '../parser/VrmExtensionParser';
import { extractVrmMeta } from '../parser/VrmMetaExtractor';
import { parseVrmHumanoid } from '../parser/VrmHumanoidMapper';
import { parseVrmExpressions } from '../parser/VrmExpressionParser';
import { parseVrmLookAt } from '../parser/VrmLookAtParser';
import { parseVrmSpringBone } from '../parser/VrmSpringBoneParser';
import { parseVrmFirstPerson } from '../parser/VrmFirstPersonParser';
import { importVrm, VrmImporterInput } from '../parser/VRMImporter';
import {
  HumanoidProvider,
  HumanoidProviderInput,
  HumanoidMappingSource
} from '../services/HumanoidProvider';
import { HumanoidBone, REQUIRED_BONES } from '../models/character3d/HumanoidBone';
import {
  ModelCapabilityInput,
  analyzeModelCapability,
  analyzeVrmCapability,
  createEmptyVrmCapabilityReport,
  getVrmVersionText,
  getVrmCapabilitySummary,
  CapabilityState
} from '../models/character3d/ModelCapabilityReport';
import { serializeVrmAsset, deserializeVrmAsset } from '../storage/VrmMetaStore';

/** 单项测试结果 */
export interface VrmTestResult {
  name: string;
  passed: boolean;
  message: string;
}

/** 全部测试结果汇总 */
export interface VrmTestSuiteResult {
  total: number;
  passed: number;
  failed: number;
  results: VrmTestResult[];
}

/**
 * 测试入口。
 */
export function runVrmParserTests(): VrmTestSuiteResult {
  return VrmParserTestSuite.runAllTests();
}

/**
 * VRM 解析器测试套件(类封装,避免嵌套函数)。
 */
class VrmParserTestSuite {
  static runAllTests(): VrmTestSuiteResult {
    const results: VrmTestResult[] = [];
    // 1. 扩展检测
    results.push(VrmParserTestSuite.test01_DetectNonVrm());
    results.push(VrmParserTestSuite.test02_DetectVrm1());
    results.push(VrmParserTestSuite.test03_DetectVrm0x());
    // 2. Meta 解析
    results.push(VrmParserTestSuite.test04_ExtractVrm1Meta());
    results.push(VrmParserTestSuite.test05_ExtractVrm0xMeta());
    // 3. Humanoid 解析
    results.push(VrmParserTestSuite.test06_ParseVrm1Humanoid());
    results.push(VrmParserTestSuite.test07_ParseVrm0xHumanoid());
    results.push(VrmParserTestSuite.test08_HumanoidMissingRequired());
    // 4. Expression 解析
    results.push(VrmParserTestSuite.test09_ParseVrm1Expressions());
    // 5. LookAt 解析
    results.push(VrmParserTestSuite.test10_ParseVrm1LookAt());
    // 6. SpringBone 解析
    results.push(VrmParserTestSuite.test11_ParseVrm1SpringBone());
    // 7. FirstPerson 解析
    results.push(VrmParserTestSuite.test12_ParseVrm1FirstPerson());
    // 8. VRMImporter 编排
    results.push(VrmParserTestSuite.test13_ImporterNonVrm());
    results.push(VrmParserTestSuite.test14_ImporterVrm1Full());
    // 9. HumanoidProvider
    results.push(VrmParserTestSuite.test15_ProviderVrmPriority());
    results.push(VrmParserTestSuite.test16_ProviderVrmOnly());
    // 10. Capability 报告
    results.push(VrmParserTestSuite.test17_CapabilityNonVrm());
    results.push(VrmParserTestSuite.test18_CapabilityVrmDimensions());
    // 11. 序列化
    results.push(VrmParserTestSuite.test19_SerializeDeserialize());
    results.push(VrmParserTestSuite.test20_DeserializeInvalidJson());

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
  ): VrmTestResult {
    if (condition) {
      return { name: name, passed: true, message: '' };
    }
    return { name: name, passed: false, message: detail };
  }

  // ==================== 1. 扩展检测 ====================

  /** 1. 非 VRM 文件检测 */
  private static test01_DetectNonVrm(): VrmTestResult {
    const gltfJson: Record<string, Object> = {
      'asset': { 'version': '2.0' },
      'extensions': { 'KHR_materials_pbrSpecularGlossiness': {} }
    };
    const detection = detectVrmExtension(gltfJson);
    const ok: boolean = !detection.isVrm && detection.version === VrmVersion.NonVrm;
    return VrmParserTestSuite.buildResult(
      '01_DetectNonVrm', ok,
      'isVrm=' + detection.isVrm + ', version=' + detection.version
    );
  }

  /** 2. VRM 1.0 检测 */
  private static test02_DetectVrm1(): VrmTestResult {
    const gltfJson: Record<string, Object> = {
      'asset': { 'version': '2.0' },
      'extensions': {
        'VRMC_vrm': {
          'specVersion': '1.0',
          'humanoid': { 'humanBones': {} }
        }
      },
      'extensionsUsed': ['VRMC_vrm', 'VRMC_materials_mtoon']
    };
    const detection = detectVrmExtension(gltfJson);
    const ok: boolean = detection.isVrm
      && detection.version === VrmVersion.Vrm1
      && detection.vrmcVrm !== null
      && detection.hasMToonMaterial;
    return VrmParserTestSuite.buildResult(
      '02_DetectVrm1', ok,
      'isVrm=' + detection.isVrm + ', version=' + detection.version
      + ', mtoon=' + detection.hasMToonMaterial
    );
  }

  /** 3. VRM 0.x 检测 */
  private static test03_DetectVrm0x(): VrmTestResult {
    const gltfJson: Record<string, Object> = {
      'asset': { 'version': '2.0' },
      'extensions': {
        'VRM': {
          'meta': { 'title': 'Test', 'version': '0.51' }
        }
      }
    };
    const detection = detectVrmExtension(gltfJson);
    const ok: boolean = detection.isVrm
      && detection.version === VrmVersion.Vrm0x
      && detection.vrm0Extension !== null;
    return VrmParserTestSuite.buildResult(
      '03_DetectVrm0x', ok,
      'isVrm=' + detection.isVrm + ', version=' + detection.version
    );
  }

  // ==================== 2. Meta 解析 ====================

  /** 4. VRM 1.0 Meta 解析 */
  private static test04_ExtractVrm1Meta(): VrmTestResult {
    const vrmcVrm: Record<string, Object> = {
      'specVersion': '1.0',
      'meta': {
        'name': 'TestAvatar',
        'version': '1.0',
        'authors': ['Author1', 'Author2'],
        'copyrightInformation': 'Copyright 2024',
        'contactInformation': 'test@example.com',
        'references': ['https://example.com'],
        'thumbnailImage': 0,
        'allowExcessivelyViolentUsage': true,
        'allowExcessivelySexualUsage': false,
        'commercialUsage': 'personalNonProfit',
        'creditNotation': 'required',
        'allowRedistribution': false
      }
    };
    const meta = extractVrmMeta(VrmVersion.Vrm1, vrmcVrm, null);
    const ok: boolean = meta.name === 'TestAvatar'
      && meta.authors.length === 2
      && meta.authors[0] === 'Author1'
      && meta.copyrightInformation === 'Copyright 2024'
      && meta.thumbnailImageIndex === 0
      && meta.allowExcessivelyViolentUsage === true
      && meta.allowExcessivelySexualUsage === false;
    return VrmParserTestSuite.buildResult(
      '04_ExtractVrm1Meta', ok,
      'name=' + meta.name + ', authors=' + meta.authors.length
      + ', thumbnail=' + meta.thumbnailImageIndex
    );
  }

  /** 5. VRM 0.x Meta 解析 */
  private static test05_ExtractVrm0xMeta(): VrmTestResult {
    const vrm0Ext: Record<string, Object> = {
      'meta': {
        'title': 'OldAvatar',
        'version': '0.51',
        'author': 'OldAuthor',
        'contactInformation': 'old@example.com',
        'allowedUserName': 'Everyone',
        'violentUsageName': 'Allow',
        'sexualUsageName': 'Disallow'
      }
    };
    const meta = extractVrmMeta(VrmVersion.Vrm0x, null, vrm0Ext);
    const ok: boolean = meta.name === 'OldAvatar'
      && meta.authors.length === 1
      && meta.authors[0] === 'OldAuthor';
    return VrmParserTestSuite.buildResult(
      '05_ExtractVrm0xMeta', ok,
      'name=' + meta.name + ', authors=' + meta.authors.length
    );
  }

  // ==================== 3. Humanoid 解析 ====================

  /** 6. VRM 1.0 Humanoid 解析 */
  private static test06_ParseVrm1Humanoid(): VrmTestResult {
    const vrmcVrm: Record<string, Object> = {
      'specVersion': '1.0',
      'humanoid': {
        'humanBones': {
          'hips': { 'node': 0, 'useDefaultValues': true },
          'spine': { 'node': 1, 'useDefaultValues': true },
          'head': { 'node': 5, 'useDefaultValues': true },
          'leftUpperArm': { 'node': 10, 'useDefaultValues': true },
          'rightUpperArm': { 'node': 20, 'useDefaultValues': true }
        }
      }
    };
    const nodeNames: string[] = ['hips', 'spine', 'chest', 'neck', 'upperChest', 'head',
      'leftShoulder', 'leftUpperArm', 'leftLowerArm', 'leftHand',
      'leftUpperArm_node', 'rightShoulder', 'rightUpperArm', 'rightLowerArm', 'rightHand',
      'leftUpperLeg', 'leftLowerLeg', 'leftFoot',
      'rightUpperLeg', 'rightLowerLeg', 'rightFoot'];
    const humanoid = parseVrmHumanoid(VrmVersion.Vrm1, vrmcVrm, null, nodeNames, 25);
    const ok: boolean = humanoid.valid
      && humanoid.bones.length === 5
      && humanoid.mappedRequiredCount >= 2; // hips + head 或其他
    return VrmParserTestSuite.buildResult(
      '06_ParseVrm1Humanoid', ok,
      'valid=' + humanoid.valid + ', bones=' + humanoid.bones.length
      + ', required=' + humanoid.mappedRequiredCount
    );
  }

  /** 7. VRM 0.x Humanoid 解析(数组格式,node 字段为节点索引) */
  private static test07_ParseVrm0xHumanoid(): VrmTestResult {
    // T-4.1 A4: VRM 0.x humanBones 是数组,每项 { bone, node, useDefaultValues }
    // bone 是标准骨骼语义键,node 是 glTF 节点索引(直接使用,不通过名称反查)
    const vrm0Ext: Record<string, Object> = {
      'humanoid': {
        'humanBones': [
          { 'bone': 'hips', 'node': 0, 'useDefaultValues': true },
          { 'bone': 'spine', 'node': 1, 'useDefaultValues': true },
          { 'bone': 'head', 'node': 2, 'useDefaultValues': true }
        ]
      }
    };
    const nodeNames: string[] = [
      'J_Bip_C_Hips', 'J_Bip_C_Spine', 'J_Bip_C_Head',
      'other1', 'other2'
    ];
    const humanoid = parseVrmHumanoid(VrmVersion.Vrm0x, null, vrm0Ext, nodeNames, 5);
    const ok: boolean = humanoid.valid
      && humanoid.bones.length === 3
      && humanoid.bones[0].nodeIndex === 0
      && humanoid.bones[0].nodeName === 'J_Bip_C_Hips'
      && humanoid.bones[2].nodeIndex === 2
      && humanoid.bones[2].nodeName === 'J_Bip_C_Head';
    return VrmParserTestSuite.buildResult(
      '07_ParseVrm0xHumanoid', ok,
      'valid=' + humanoid.valid + ', bones=' + humanoid.bones.length
      + ', headNode=' + humanoid.bones[2].nodeIndex
      + ', headName=' + humanoid.bones[2].nodeName
    );
  }

  /** 8. 缺失必需骨骼检测 */
  private static test08_HumanoidMissingRequired(): VrmTestResult {
    const vrmcVrm: Record<string, Object> = {
      'specVersion': '1.0',
      'humanoid': {
        'humanBones': {
          'head': { 'node': 0 }
          // 缺失 hips, spine, leftUpperArm, rightUpperArm, leftUpperLeg, rightUpperLeg
        }
      }
    };
    const humanoid = parseVrmHumanoid(VrmVersion.Vrm1, vrmcVrm, null, ['head'], 1);
    const ok: boolean = humanoid.valid
      && humanoid.missingRequired.length === REQUIRED_BONES.length - 1; // 只 head 映射了
    return VrmParserTestSuite.buildResult(
      '08_HumanoidMissingRequired', ok,
      'missing=' + humanoid.missingRequired.length + ', expected=' + (REQUIRED_BONES.length - 1)
    );
  }

  // ==================== 4. Expression 解析 ====================

  /** 9. VRM 1.0 Expression 解析 */
  private static test09_ParseVrm1Expressions(): VrmTestResult {
    const vrmcVrm: Record<string, Object> = {
      'specVersion': '1.0',
      'expressions': {
        'preset': {
          'happy': {
            'morphTargetBinds': [
              { 'node': 0, 'index': 0, 'weight': 1.0 }
            ]
          },
          'blink': {
            'morphTargetBinds': [
              { 'node': 1, 'index': 1, 'weight': 1.0 }
            ]
          }
        },
        'custom': {
          'CustomExpr': {
            'morphTargetBinds': []
          }
        }
      }
    };
    const exprSet = parseVrmExpressions(VrmVersion.Vrm1, vrmcVrm, null);
    const ok: boolean = exprSet.valid
      && exprSet.expressions.length >= 2;
    return VrmParserTestSuite.buildResult(
      '09_ParseVrm1Expressions', ok,
      'valid=' + exprSet.valid + ', count=' + exprSet.expressions.length
    );
  }

  // ==================== 5. LookAt 解析 ====================

  /** 10. VRM 1.0 LookAt 解析 */
  private static test10_ParseVrm1LookAt(): VrmTestResult {
    const vrmcVrm: Record<string, Object> = {
      'specVersion': '1.0',
      'lookAt': {
        'type': 'expression',
        'offsetFromHeadBone': [0, 0.06, 0],
        'rangeMapHorizontalInner': { 'inputMaxValue': 15, 'outputScale': 1 },
        'rangeMapHorizontalOuter': { 'inputMaxValue': 30, 'outputScale': 1 },
        'rangeMapVerticalDown': { 'inputMaxValue': 10, 'outputScale': 1 },
        'rangeMapVerticalUp': { 'inputMaxValue': 10, 'outputScale': 1 }
      }
    };
    const lookAt = parseVrmLookAt(VrmVersion.Vrm1, vrmcVrm, null, 5);
    const ok: boolean = lookAt.valid
      && lookAt.type === 'expression' as Object
      && lookAt.offsetFromHeadBone.length === 3
      && lookAt.rangeMapHorizontalInner !== null;
    return VrmParserTestSuite.buildResult(
      '10_ParseVrm1LookAt', ok,
      'valid=' + lookAt.valid + ', offset=' + lookAt.offsetFromHeadBone.length
    );
  }

  // ==================== 6. SpringBone 解析 ====================

  /** 11. VRM 1.0 SpringBone 解析 */
  private static test11_ParseVrm1SpringBone(): VrmTestResult {
    const vrmcSpringBone: Record<string, Object> = {
      'colliders': [
        { 'node': 30, 'shape': { 'sphere': { 'offset': [0, 0, 0], 'radius': 0.05 } } }
      ],
      'colliderGroups': [
        { 'name': 'BodyColliders', 'colliders': [0] }
      ],
      'springs': [
        {
          'name': 'HairSpring',
          'joints': [
            { 'node': 40, 'hitRadius': 0.02, 'stiffness': 1.0, 'gravityPower': 0.5, 'gravityFromStartBone': [0, -1, 0], 'dragForce': 0.4 },
            { 'node': 41, 'hitRadius': 0.02, 'stiffness': 1.0, 'gravityPower': 0.5, 'gravityFromStartBone': [0, -1, 0], 'dragForce': 0.4 }
          ],
          'colliderGroups': [0]
        }
      ]
    };
    const springBone = parseVrmSpringBone(VrmVersion.Vrm1, vrmcSpringBone, null);
    const ok: boolean = springBone.valid
      && springBone.colliders.length === 1
      && springBone.springs.length === 1
      && springBone.totalJointCount === 2;
    return VrmParserTestSuite.buildResult(
      '11_ParseVrm1SpringBone', ok,
      'valid=' + springBone.valid + ', joints=' + springBone.totalJointCount
      + ', springs=' + springBone.springs.length
    );
  }

  // ==================== 7. FirstPerson 解析 ====================

  /** 12. VRM 1.0 FirstPerson 解析 */
  private static test12_ParseVrm1FirstPerson(): VrmTestResult {
    const vrmcVrm: Record<string, Object> = {
      'specVersion': '1.0',
      'firstPerson': {
        'meshAnnotations': [
          { 'node': 0, 'firstPersonFlag': 'auto', 'thirdPersonFlag': 'auto' },
          { 'node': 1, 'firstPersonFlag': 'firstPersonOnly', 'thirdPersonFlag': 'thirdPersonOnly' }
        ]
      }
    };
    const firstPerson = parseVrmFirstPerson(VrmVersion.Vrm1, vrmcVrm, null, 5);
    const ok: boolean = firstPerson.valid
      && firstPerson.meshAnnotations.length === 2;
    return VrmParserTestSuite.buildResult(
      '12_ParseVrm1FirstPerson', ok,
      'valid=' + firstPerson.valid + ', annotations=' + firstPerson.meshAnnotations.length
    );
  }

  // ==================== 8. VRMImporter 编排 ====================

  /** 13. 非 VRM 文件 Importer 返回空资产 */
  private static test13_ImporterNonVrm(): VrmTestResult {
    const gltfJson: Record<string, Object> = {
      'asset': { 'version': '2.0' }
    };
    const input: VrmImporterInput = {
      gltfJson: gltfJson,
      sourceSha256: 'abc123',
      nodeNames: [],
      nodeCount: 0,
      meshCount: 0,
      materialCount: 0,
      imageCount: 0
    };
    const result = importVrm(input);
    const ok: boolean = !result.isVrm
      && result.asset.version === VrmVersion.NonVrm
      && !result.asset.valid;
    return VrmParserTestSuite.buildResult(
      '13_ImporterNonVrm', ok,
      'isVrm=' + result.isVrm + ', valid=' + result.asset.valid
    );
  }

  /** 14. VRM 1.0 完整导入 */
  private static test14_ImporterVrm1Full(): VrmTestResult {
    const gltfJson: Record<string, Object> = {
      'asset': { 'version': '2.0' },
      'extensions': {
        'VRMC_vrm': {
          'specVersion': '1.0',
          'meta': {
            'name': 'FullTestAvatar',
            'version': '1.0',
            'authors': ['TestAuthor']
          },
          'humanoid': {
            'humanBones': {
              'hips': { 'node': 0 },
              'spine': { 'node': 1 },
              'head': { 'node': 5 },
              'leftUpperArm': { 'node': 10 },
              'rightUpperArm': { 'node': 20 },
              'leftUpperLeg': { 'node': 15 },
              'rightUpperLeg': { 'node': 25 }
            }
          },
          'expressions': {
            'preset': {
              'happy': { 'morphTargetBinds': [] }
            }
          },
          'lookAt': {
            'type': 'expression',
            'offsetFromHeadBone': [0, 0.06, 0],
            'rangeMapHorizontalInner': { 'inputMaxValue': 15, 'outputScale': 1 }
          },
          'firstPerson': {
            'meshAnnotations': []
          }
        },
        'VRMC_springBone': {
          'springs': []
        }
      },
      'extensionsUsed': ['VRMC_vrm', 'VRMC_springBone', 'VRMC_materials_mtoon']
    };
    const nodeNames: string[] = [];
    for (let i: number = 0; i < 30; i++) {
      nodeNames.push('node_' + i);
    }
    const input: VrmImporterInput = {
      gltfJson: gltfJson,
      sourceSha256: 'sha_test_123',
      nodeNames: nodeNames,
      nodeCount: 30,
      meshCount: 5,
      materialCount: 3,
      imageCount: 2
    };
    const result = importVrm(input);
    const ok: boolean = result.isVrm
      && result.asset.valid
      && result.asset.version === VrmVersion.Vrm1
      && result.asset.meta.name === 'FullTestAvatar'
      && result.asset.humanoid.valid
      && result.asset.humanoid.bones.length === 7
      && result.asset.hasMToonMaterial;
    return VrmParserTestSuite.buildResult(
      '14_ImporterVrm1Full', ok,
      'isVrm=' + result.isVrm + ', valid=' + result.asset.valid
      + ', bones=' + result.asset.humanoid.bones.length
      + ', mtoon=' + result.asset.hasMToonMaterial
    );
  }

  // ==================== 9. HumanoidProvider ====================

  /** 15. VRM 优先级高于 Manual/Auto */
  private static test15_ProviderVrmPriority(): VrmTestResult {
    // VRM humanoid: head → node 5
    const vrmHumanoid = parseVrmHumanoid(VrmVersion.Vrm1, {
      'specVersion': '1.0',
      'humanoid': {
        'humanBones': {
          'head': { 'node': 5 }
        }
      }
    }, null, ['n0', 'n1', 'n2', 'n3', 'n4', 'head_node'], 10);

    // Auto mapping: head → node 99(应该被 VRM 覆盖)
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
    return VrmParserTestSuite.buildResult(
      '15_ProviderVrmPriority', ok,
      'source=' + head.source + ', node=' + head.nodeIndex + ', conf=' + head.confidence
    );
  }

  /** 16. 仅 VRM 映射时 Provider 正常工作 */
  private static test16_ProviderVrmOnly(): VrmTestResult {
    const vrmHumanoid = parseVrmHumanoid(VrmVersion.Vrm1, {
      'specVersion': '1.0',
      'humanoid': {
        'humanBones': {
          'hips': { 'node': 0 },
          'head': { 'node': 5 },
          'leftUpperArm': { 'node': 10 }
        }
      }
    }, null, ['hips', 'n1', 'n2', 'n3', 'n4', 'head'], 15);

    const input: HumanoidProviderInput = {
      vrmHumanoid: vrmHumanoid,
      manualMapping: null,
      autoMapping: null
    };
    const provider = new HumanoidProvider(input);
    const ok: boolean = provider.isFromVrm()
      && provider.getMappedCount() === 3
      && provider.getHips().nodeIndex === 0
      && provider.getHead().nodeIndex === 5;
    return VrmParserTestSuite.buildResult(
      '16_ProviderVrmOnly', ok,
      'isVrm=' + provider.isFromVrm() + ', mapped=' + provider.getMappedCount()
    );
  }

  // ==================== 10. Capability 报告 ====================

  /** 17. 非 VRM 文件 VRM 维度全为 NotPresent */
  private static test17_CapabilityNonVrm(): VrmTestResult {
    const report = analyzeVrmCapability(null, null);
    const ok: boolean = !report.isVrm
      && report.vrmVersion === VrmVersion.NonVrm
      && report.expression === CapabilityState.NotPresent
      && report.springBone === CapabilityState.NotPresent
      && report.expressionCount === 0;
    return VrmParserTestSuite.buildResult(
      '17_CapabilityNonVrm', ok,
      'isVrm=' + report.isVrm + ', expr=' + report.expression
    );
  }

  /** 18. VRM 维度正确填充 */
  private static test18_CapabilityVrmDimensions(): VrmTestResult {
    const gltfJson: Record<string, Object> = {
      'asset': { 'version': '2.0' },
      'extensions': {
        'VRMC_vrm': {
          'specVersion': '1.0',
          'meta': { 'name': 'CapTest', 'version': '1.0', 'authors': ['A'] },
          'humanoid': {
            'humanBones': {
              'hips': { 'node': 0 },
              'spine': { 'node': 1 },
              'head': { 'node': 5 },
              'leftUpperArm': { 'node': 10 },
              'rightUpperArm': { 'node': 20 },
              'leftUpperLeg': { 'node': 15 },
              'rightUpperLeg': { 'node': 25 }
            }
          },
          'expressions': {
            'preset': {
              'happy': { 'morphTargetBinds': [] },
              'blink': { 'morphTargetBinds': [] }
            }
          },
          'lookAt': {
            'type': 'expression',
            'offsetFromHeadBone': [0, 0, 0],
            'rangeMapHorizontalInner': { 'inputMaxValue': 15, 'outputScale': 1 }
          },
          'firstPerson': {
            'meshAnnotations': [
              { 'node': 0, 'firstPersonFlag': 'auto' }
            ]
          }
        },
        'VRMC_springBone': {
          'colliders': [],
          'springs': [
            { 'name': 's1', 'joints': [{ 'node': 40 }], 'colliderGroups': [] }
          ]
        }
      },
      'extensionsUsed': ['VRMC_vrm', 'VRMC_springBone']
    };
    const nodeNames: string[] = [];
    for (let i: number = 0; i < 50; i++) {
      nodeNames.push('n' + i);
    }
    const vrmResult = importVrm({
      gltfJson: gltfJson,
      sourceSha256: 'cap_test',
      nodeNames: nodeNames,
      nodeCount: 50,
      meshCount: 1,
      materialCount: 1,
      imageCount: 0
    });
    const warnings: { dimension: string, message: string }[] = [];
    const report = analyzeVrmCapability(vrmResult.asset, warnings as { dimension: Object, message: string }[] as Object);
    const ok: boolean = report.isVrm
      && report.vrmVersion === VrmVersion.Vrm1
      && report.vrmHumanoid === CapabilityState.Supported
      && report.expression === CapabilityState.Supported
      && report.expressionCount >= 2
      && report.lookAt === CapabilityState.Supported
      && report.springBone === CapabilityState.PartiallySupported
      && report.springBoneJointCount === 1
      && report.firstPerson === CapabilityState.Supported;
    return VrmParserTestSuite.buildResult(
      '18_CapabilityVrmDimensions', ok,
      'vrm=' + report.vrmHumanoid + ', expr=' + report.expression
      + '(' + report.expressionCount + '), lookAt=' + report.lookAt
      + ', spring=' + report.springBone + '(' + report.springBoneJointCount + ')'
      + ', firstPerson=' + report.firstPerson
    );
  }

  // ==================== 11. 序列化 ====================

  /** 19. VrmAsset 序列化/反序列化往返 */
  private static test19_SerializeDeserialize(): VrmTestResult {
    const asset: VrmAsset = createEmptyVrmAsset(VrmVersion.Vrm1);
    asset.sourceSha256 = 'serialize_test_123';
    asset.nodeCount = 10;
    asset.meshCount = 2;
    asset.hasMToonMaterial = true;
    asset.valid = true;
    asset.meta.name = 'SerializeTest';
    asset.meta.authors = ['Author1'];
    asset.humanoid.valid = true;
    asset.humanoid.bones = [{
      target: HumanoidBone.Head,
      vrmBoneName: 'head',
      nodeIndex: 5,
      nodeName: 'head_node',
      useDefaultValues: true,
      confidence: 1.0
    }];

    const json: string = serializeVrmAsset(asset);
    const restored: VrmAsset | null = deserializeVrmAsset(json);
    const ok: boolean = restored !== null
      && restored.version === VrmVersion.Vrm1
      && restored.sourceSha256 === 'serialize_test_123'
      && restored.meta.name === 'SerializeTest'
      && restored.hasMToonMaterial === true
      && restored.humanoid.bones.length === 1
      && restored.humanoid.bones[0].nodeIndex === 5;
    return VrmParserTestSuite.buildResult(
      '19_SerializeDeserialize', ok,
      'restored=' + (restored !== null) + ', name=' + (restored !== null ? restored.meta.name : 'null')
    );
  }

  /** 20. 非法 JSON 反序列化返回 null */
  private static test20_DeserializeInvalidJson(): VrmTestResult {
    const invalid1: string = 'not json';
    const invalid2: string = '{"version":"NonVrm"}'; // 非 VRM 应被拒绝
    const invalid3: string = ''; // 空

    const r1: VrmAsset | null = deserializeVrmAsset(invalid1);
    const r2: VrmAsset | null = deserializeVrmAsset(invalid2);
    const r3: VrmAsset | null = deserializeVrmAsset(invalid3);

    const ok: boolean = r1 === null && r2 === null && r3 === null;
    return VrmParserTestSuite.buildResult(
      '20_DeserializeInvalidJson', ok,
      'r1=' + (r1 !== null) + ', r2=' + (r2 !== null) + ', r3=' + (r3 !== null)
    );
  }
}
