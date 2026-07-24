/**
 * HumanoidMappingTest 手动人形骨骼映射单元测试
 *
 * T-3D.6E P3: 第三十二节单元测试(18 项)
 *
 * 职责:
 * - 对 ManualHumanoidMapping 数据结构做断言测试
 * - 对 setJointBinding/removeJointBinding/clearAllBindings 做断言测试
 * - 对 refreshMappingStats 做断言测试
 * - 对 computeSkeletonHash/isSkeletonHashMatched 做断言测试
 * - 对 serializeManualMapping/deserializeManualMapping 做断言测试
 * - 对 validateHumanoidMapping 做断言测试
 * - 不依赖 ArkUI / ArkGraphics3D / 文件系统,可独立运行
 * - 通过 Logger 输出测试结果
 *
 * 测试项(共 18 项,对应 T-3D.6E 第三十二节):
 *  1. 保存一个关节
 *  2. 替换关节
 *  3. 取消关节
 *  4. 重复 source bone(同一 sourceNodeIndex 映射到两个 target)
 *  5. 缺少必需关节
 *  6. 缺少可选关节
 *  7. 左右反转
 *  8. Arm 层级错误(UpperArm 不是 LowerArm 祖先)
 *  9. Leg 层级错误(UpperLeg 不是 LowerLeg 祖先)
 * 10. Head 不在 Spine 链
 * 11. sourceNodeIndex 越界
 * 12. skeletonHash 变化
 * 13. 模型重新导入后映射复用(SHA 相同)
 * 14. 模型变化后要求重新验证(skeletonHash 不一致)
 * 15. 保存并重新读取(序列化/反序列化)
 * 16. 清空映射
 * 17. 自动映射后手动修正
 * 18. 对称骨骼建议(LeftUpperArm/RightUpperArm 检查)
 */

import { Logger } from '../utils/Logger';
import {
  HumanoidBone,
  REQUIRED_BONES,
  ALL_STANDARD_BONES
} from '../models/character3d/HumanoidBone';
import {
  ManualHumanoidMapping,
  HumanoidJointBinding,
  BoneMappingMethod,
  SkeletonRestPose,
  SkeletonHashInput,
  createEmptyManualMapping,
  setJointBinding,
  removeJointBinding,
  clearAllBindings,
  refreshMappingStats,
  serializeManualMapping,
  deserializeManualMapping,
  computeSkeletonHash,
  isSkeletonHashMatched,
  normalizeBoneName
} from '../models/character3d/ManualHumanoidMapping';
import {
  HumanoidMappingValidationResult,
  HumanoidMappingValidatorInput,
  HumanoidMappingIssueType,
  validateHumanoidMapping
} from '../models/character3d/HumanoidMappingValidator';

const LOG_TAG: string = 'HumanoidMappingTest';

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

/** 测试用可选骨骼(ALL_STANDARD_BONES 中除 REQUIRED_BONES 外的) */
const OPTIONAL_BONES: HumanoidBone[] = computeOptionalBonesForTest();

/** 测试用模型 node 总数 */
const TEST_TOTAL_NODE_COUNT: number = 100;

/**
 * 测试入口。
 */
export class HumanoidMappingTest {
  static runAllTests(): TestSuiteResult {
    const results: TestResult[] = [];
    results.push(HumanoidMappingTest.test01_SaveOneJoint());
    results.push(HumanoidMappingTest.test02_ReplaceJoint());
    results.push(HumanoidMappingTest.test03_UnbindJoint());
    results.push(HumanoidMappingTest.test04_DuplicateSourceBone());
    results.push(HumanoidMappingTest.test05_MissingRequiredJoint());
    results.push(HumanoidMappingTest.test06_MissingOptionalJoint());
    results.push(HumanoidMappingTest.test07_LeftRightReversed());
    results.push(HumanoidMappingTest.test08_ArmHierarchyError());
    results.push(HumanoidMappingTest.test09_LegHierarchyError());
    results.push(HumanoidMappingTest.test10_HeadNotInSpineChain());
    results.push(HumanoidMappingTest.test11_SourceNodeIndexOutOfRange());
    results.push(HumanoidMappingTest.test12_SkeletonHashChanged());
    results.push(HumanoidMappingTest.test13_ReuseMappingAfterReimport());
    results.push(HumanoidMappingTest.test14_RequiresRevalidationAfterModelChange());
    results.push(HumanoidMappingTest.test15_SerializeAndDeserialize());
    results.push(HumanoidMappingTest.test16_ClearAllMappings());
    results.push(HumanoidMappingTest.test17_AutoThenManualOverride());
    results.push(HumanoidMappingTest.test18_SymmetricBoneSuggestion());

    let passed: number = 0;
    let failed: number = 0;
    for (let i: number = 0; i < results.length; i++) {
      if (results[i].passed) {
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
    Logger.info(LOG_TAG, '==== HumanoidMapping Test Suite: ' + passed + '/' + results.length
      + ' passed, ' + failed + ' failed ====');
    return suite;
  }

  // ========== 1~6 项:基础增删改 ==========

  /** 1. 保存一个关节 */
  private static test01_SaveOneJoint(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    const binding: HumanoidJointBinding = {
      targetJoint: HumanoidBone.Hips,
      sourceNodeIndex: 5,
      sourceBoneName: 'mixamorig:Hips',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    };
    const replaced: HumanoidJointBinding | null = setJointBinding(mapping, binding);
    const ok: boolean = replaced === null && mapping.joints.length === 1
      && mapping.joints[0].targetJoint === HumanoidBone.Hips
      && mapping.joints[0].sourceNodeIndex === 5;
    return HumanoidMappingTest.buildResult('01_SaveOneJoint', ok,
      'joints=' + mapping.joints.length + ', replaced=' + (replaced !== null));
  }

  /** 2. 替换关节(同 target 重新绑定) */
  private static test02_ReplaceJoint(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    const b1: HumanoidJointBinding = {
      targetJoint: HumanoidBone.Head,
      sourceNodeIndex: 10,
      sourceBoneName: 'head_old',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    };
    setJointBinding(mapping, b1);
    const b2: HumanoidJointBinding = {
      targetJoint: HumanoidBone.Head,
      sourceNodeIndex: 20,
      sourceBoneName: 'head_new',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    };
    const replaced: HumanoidJointBinding | null = setJointBinding(mapping, b2);
    const ok: boolean = replaced !== null && replaced.sourceNodeIndex === 10
      && mapping.joints.length === 1
      && mapping.joints[0].sourceNodeIndex === 20;
    return HumanoidMappingTest.buildResult('02_ReplaceJoint', ok,
      'joints=' + mapping.joints.length + ', replacedSourceIdx='
      + (replaced !== null ? replaced.sourceNodeIndex : -1));
  }

  /** 3. 取消关节 */
  private static test03_UnbindJoint(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    const binding: HumanoidJointBinding = {
      targetJoint: HumanoidBone.Spine,
      sourceNodeIndex: 7,
      sourceBoneName: 'spine',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    };
    setJointBinding(mapping, binding);
    const removed: HumanoidJointBinding | null = removeJointBinding(mapping, HumanoidBone.Spine);
    const ok: boolean = removed !== null && mapping.joints.length === 0;
    return HumanoidMappingTest.buildResult('03_UnbindJoint', ok,
      'joints=' + mapping.joints.length + ', removedTarget='
      + (removed !== null ? removed.targetJoint : 'null'));
  }

  /** 4. 重复 source bone(同一 sourceNodeIndex 自动解除旧 target) */
  private static test04_DuplicateSourceBone(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    const b1: HumanoidJointBinding = {
      targetJoint: HumanoidBone.LeftUpperArm,
      sourceNodeIndex: 30,
      sourceBoneName: 'upperarm_l',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    };
    setJointBinding(mapping, b1);
    // 将同一个 sourceNodeIndex=30 映射到另一个 target
    const b2: HumanoidJointBinding = {
      targetJoint: HumanoidBone.RightUpperArm,
      sourceNodeIndex: 30,
      sourceBoneName: 'upperarm_r',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    };
    setJointBinding(mapping, b2);
    // 旧 LeftUpperArm 应被解除
    let leftStillMapped: boolean = false;
    for (let i: number = 0; i < mapping.joints.length; i++) {
      if (mapping.joints[i].targetJoint === HumanoidBone.LeftUpperArm) {
        leftStillMapped = true;
        break;
      }
    }
    const ok: boolean = !leftStillMapped && mapping.joints.length === 1
      && mapping.joints[0].targetJoint === HumanoidBone.RightUpperArm;
    return HumanoidMappingTest.buildResult('04_DuplicateSourceBone', ok,
      'joints=' + mapping.joints.length + ', leftStillMapped=' + leftStillMapped);
  }

  /** 5. 缺少必需关节 */
  private static test05_MissingRequiredJoint(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    // 只映射一个非必需关节
    const binding: HumanoidJointBinding = {
      targetJoint: HumanoidBone.LeftEye,
      sourceNodeIndex: 1,
      sourceBoneName: 'eye_l',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    };
    setJointBinding(mapping, binding);
    refreshMappingStats(mapping, REQUIRED_BONES, OPTIONAL_BONES);
    const ok: boolean = mapping.requiredMissing.length === REQUIRED_BONES.length;
    return HumanoidMappingTest.buildResult('05_MissingRequiredJoint', ok,
      'requiredMissing=' + mapping.requiredMissing.length
      + ' (expected=' + REQUIRED_BONES.length + ')');
  }

  /** 6. 缺少可选关节 */
  private static test06_MissingOptionalJoint(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    // 映射所有必需关节
    for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
      const binding: HumanoidJointBinding = {
        targetJoint: REQUIRED_BONES[i],
        sourceNodeIndex: i,
        sourceBoneName: REQUIRED_BONES[i].toLowerCase(),
        mappingMethod: BoneMappingMethod.Manual,
        confidence: 1.0
      };
      setJointBinding(mapping, binding);
    }
    refreshMappingStats(mapping, REQUIRED_BONES, OPTIONAL_BONES);
    // requiredMissing 应为 0,optionalMissing 应 > 0
    const ok: boolean = mapping.requiredMissing.length === 0
      && mapping.optionalMissing.length > 0;
    return HumanoidMappingTest.buildResult('06_MissingOptionalJoint', ok,
      'requiredMissing=' + mapping.requiredMissing.length
      + ', optionalMissing=' + mapping.optionalMissing.length);
  }

  // ========== 7~11 项:验证器 ==========

  /** 7. 左右反转(Left/Right 上臂世界 X 同号) */
  private static test07_LeftRightReversed(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    // 构造 Left/Right 上臂都映射到 X 正坐标
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.LeftUpperArm,
      sourceNodeIndex: 0,
      sourceBoneName: 'upperarm_l',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.RightUpperArm,
      sourceNodeIndex: 1,
      sourceBoneName: 'upperarm_r',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    const restPoses: SkeletonRestPose[] = [
      HumanoidMappingTest.makeRestPose(0, -1, 0.5, 0, 0),
      HumanoidMappingTest.makeRestPose(1, -1, 0.5, 0, 0) // 同号 X
    ];
    const input: HumanoidMappingValidatorInput = {
      mapping: mapping,
      totalNodeCount: TEST_TOTAL_NODE_COUNT,
      currentSkeletonHash: 'hash-a',
      parentIndices: [-1, -1],
      restPoses: restPoses,
      optionalBones: OPTIONAL_BONES,
      skinJointNodeIndices: [],
      currentSourceSha256: ''
    };
    const result: HumanoidMappingValidationResult = validateHumanoidMapping(input);
    let hasReversalWarning: boolean = false;
    for (let i: number = 0; i < result.warnings.length; i++) {
      if (result.warnings[i].type === HumanoidMappingIssueType.LeftRightReversed) {
        hasReversalWarning = true;
        break;
      }
    }
    return HumanoidMappingTest.buildResult('07_LeftRightReversed', hasReversalWarning,
      'hasReversalWarning=' + hasReversalWarning + ', warnings=' + result.warnings.length);
  }

  /** 8. Arm 层级错误(UpperArm 不是 LowerArm 祖先) */
  private static test08_ArmHierarchyError(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.LeftUpperArm,
      sourceNodeIndex: 10,
      sourceBoneName: 'upperarm_l',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.LeftLowerArm,
      sourceNodeIndex: 20,
      sourceBoneName: 'lowerarm_l',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    // parentIndices[20]=5,不是 10,所以 UpperArm 不是 LowerArm 祖先
    const parentIndices: number[] = [];
    for (let i: number = 0; i < 30; i++) {
      parentIndices.push(-1);
    }
    parentIndices[20] = 5;
    const input: HumanoidMappingValidatorInput = {
      mapping: mapping,
      totalNodeCount: TEST_TOTAL_NODE_COUNT,
      currentSkeletonHash: 'hash-a',
      parentIndices: parentIndices,
      restPoses: [],
      optionalBones: OPTIONAL_BONES,
      skinJointNodeIndices: [],
      currentSourceSha256: ''
    };
    const result: HumanoidMappingValidationResult = validateHumanoidMapping(input);
    let hasHierarchyWarning: boolean = false;
    for (let i: number = 0; i < result.warnings.length; i++) {
      if (result.warnings[i].type === HumanoidMappingIssueType.UpperArmNotAncestorOfLowerArm) {
        hasHierarchyWarning = true;
        break;
      }
    }
    return HumanoidMappingTest.buildResult('08_ArmHierarchyError', hasHierarchyWarning,
      'hasHierarchyWarning=' + hasHierarchyWarning + ', warnings=' + result.warnings.length);
  }

  /** 9. Leg 层级错误(UpperLeg 不是 LowerLeg 祖先) */
  private static test09_LegHierarchyError(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.LeftUpperLeg,
      sourceNodeIndex: 30,
      sourceBoneName: 'upperleg_l',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.LeftLowerLeg,
      sourceNodeIndex: 40,
      sourceBoneName: 'lowerleg_l',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    // parentIndices[40]=5,不是 30
    const parentIndices: number[] = [];
    for (let i: number = 0; i < 50; i++) {
      parentIndices.push(-1);
    }
    parentIndices[40] = 5;
    const input: HumanoidMappingValidatorInput = {
      mapping: mapping,
      totalNodeCount: TEST_TOTAL_NODE_COUNT,
      currentSkeletonHash: 'hash-a',
      parentIndices: parentIndices,
      restPoses: [],
      optionalBones: OPTIONAL_BONES,
      skinJointNodeIndices: [],
      currentSourceSha256: ''
    };
    const result: HumanoidMappingValidationResult = validateHumanoidMapping(input);
    let hasHierarchyWarning: boolean = false;
    for (let i: number = 0; i < result.warnings.length; i++) {
      if (result.warnings[i].type === HumanoidMappingIssueType.UpperLegNotAncestorOfLowerLeg) {
        hasHierarchyWarning = true;
        break;
      }
    }
    return HumanoidMappingTest.buildResult('09_LegHierarchyError', hasHierarchyWarning,
      'hasHierarchyWarning=' + hasHierarchyWarning + ', warnings=' + result.warnings.length);
  }

  /** 10. Head 不在 Spine 链 */
  private static test10_HeadNotInSpineChain(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.Spine,
      sourceNodeIndex: 1,
      sourceBoneName: 'spine',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.Head,
      sourceNodeIndex: 50,
      sourceBoneName: 'head',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    // Head(50) 的祖先是 5,不是 Spine(1)
    const parentIndices: number[] = [];
    for (let i: number = 0; i < 60; i++) {
      parentIndices.push(-1);
    }
    parentIndices[50] = 5;
    const input: HumanoidMappingValidatorInput = {
      mapping: mapping,
      totalNodeCount: TEST_TOTAL_NODE_COUNT,
      currentSkeletonHash: 'hash-a',
      parentIndices: parentIndices,
      restPoses: [],
      optionalBones: OPTIONAL_BONES,
      skinJointNodeIndices: [],
      currentSourceSha256: ''
    };
    const result: HumanoidMappingValidationResult = validateHumanoidMapping(input);
    let hasHeadWarning: boolean = false;
    for (let i: number = 0; i < result.warnings.length; i++) {
      if (result.warnings[i].type === HumanoidMappingIssueType.HeadNotAboveSpine) {
        hasHeadWarning = true;
        break;
      }
    }
    return HumanoidMappingTest.buildResult('10_HeadNotInSpineChain', hasHeadWarning,
      'hasHeadWarning=' + hasHeadWarning + ', warnings=' + result.warnings.length);
  }

  /** 11. sourceNodeIndex 越界 */
  private static test11_SourceNodeIndexOutOfRange(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.Head,
      sourceNodeIndex: 999, // 越界
      sourceBoneName: 'head',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    const input: HumanoidMappingValidatorInput = {
      mapping: mapping,
      totalNodeCount: TEST_TOTAL_NODE_COUNT,
      currentSkeletonHash: 'hash-a',
      parentIndices: [],
      restPoses: [],
      optionalBones: OPTIONAL_BONES,
      skinJointNodeIndices: [],
      currentSourceSha256: ''
    };
    const result: HumanoidMappingValidationResult = validateHumanoidMapping(input);
    let hasOutOfRangeError: boolean = false;
    for (let i: number = 0; i < result.errors.length; i++) {
      if (result.errors[i].type === HumanoidMappingIssueType.SourceNodeNotInModel) {
        hasOutOfRangeError = true;
        break;
      }
    }
    return HumanoidMappingTest.buildResult('11_SourceNodeIndexOutOfRange', hasOutOfRangeError,
      'hasOutOfRangeError=' + hasOutOfRangeError + ', errors=' + result.errors.length);
  }

  // ========== 12~14 项:skeletonHash ==========

  /** 12. skeletonHash 变化(验证失败) */
  private static test12_SkeletonHashChanged(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-old');
    const input: HumanoidMappingValidatorInput = {
      mapping: mapping,
      totalNodeCount: TEST_TOTAL_NODE_COUNT,
      currentSkeletonHash: 'hash-new', // 不一致
      parentIndices: [],
      restPoses: [],
      optionalBones: OPTIONAL_BONES,
      skinJointNodeIndices: [],
      currentSourceSha256: ''
    };
    const result: HumanoidMappingValidationResult = validateHumanoidMapping(input);
    let hasHashError: boolean = false;
    for (let i: number = 0; i < result.errors.length; i++) {
      if (result.errors[i].type === HumanoidMappingIssueType.SkeletonHashMismatch) {
        hasHashError = true;
        break;
      }
    }
    return HumanoidMappingTest.buildResult('12_SkeletonHashChanged', hasHashError,
      'hasHashError=' + hasHashError + ', errors=' + result.errors.length);
  }

  /** 13. 模型重新导入后映射复用(SHA 相同 → hash 相同 → 可复用) */
  private static test13_ReuseMappingAfterReimport(): TestResult {
    const hashInput: SkeletonHashInput = {
      jointCount: 3,
      jointNames: ['Hips', 'Spine', 'Head'],
      parentIndices: [-1, 0, 1],
      inverseBindMatrixCount: 3
    };
    const hash1: string = computeSkeletonHash(hashInput);
    const hash2: string = computeSkeletonHash(hashInput);
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', hash1);
    const ok: boolean = hash1 === hash2 && isSkeletonHashMatched(mapping, hash2);
    return HumanoidMappingTest.buildResult('13_ReuseMappingAfterReimport', ok,
      'hash1=' + hash1.substring(0, 8) + '..., hash2=' + hash2.substring(0, 8)
      + '..., matched=' + isSkeletonHashMatched(mapping, hash2));
  }

  /** 14. 模型变化后要求重新验证(joint 数量变化 → hash 不同) */
  private static test14_RequiresRevalidationAfterModelChange(): TestResult {
    const hashInput1: SkeletonHashInput = {
      jointCount: 3,
      jointNames: ['Hips', 'Spine', 'Head'],
      parentIndices: [-1, 0, 1],
      inverseBindMatrixCount: 3
    };
    const hashInput2: SkeletonHashInput = {
      jointCount: 4, // 变化
      jointNames: ['Hips', 'Spine', 'Chest', 'Head'],
      parentIndices: [-1, 0, 1, 2],
      inverseBindMatrixCount: 4
    };
    const hash1: string = computeSkeletonHash(hashInput1);
    const hash2: string = computeSkeletonHash(hashInput2);
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', hash1);
    const ok: boolean = hash1 !== hash2 && !isSkeletonHashMatched(mapping, hash2);
    return HumanoidMappingTest.buildResult('14_RequiresRevalidationAfterModelChange', ok,
      'hash1=' + hash1.substring(0, 8) + '..., hash2=' + hash2.substring(0, 8)
      + '..., matched=' + isSkeletonHashMatched(mapping, hash2));
  }

  // ========== 15~18 项:序列化与综合 ==========

  /** 15. 保存并重新读取(序列化/反序列化) */
  private static test15_SerializeAndDeserialize(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.Hips,
      sourceNodeIndex: 5,
      sourceBoneName: 'hips',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.Head,
      sourceNodeIndex: 10,
      sourceBoneName: 'head',
      mappingMethod: BoneMappingMethod.Auto,
      confidence: 0.9
    });
    refreshMappingStats(mapping, REQUIRED_BONES, OPTIONAL_BONES);
    const json: string = serializeManualMapping(mapping);
    const restored: ManualHumanoidMapping | null = deserializeManualMapping(json);
    let ok: boolean = false;
    let jointCount: number = 0;
    let hashValue: string = 'null';
    if (restored !== null) {
      jointCount = restored.joints.length;
      hashValue = restored.skeletonHash;
      ok = restored.joints.length === 2
        && restored.joints[0].targetJoint === HumanoidBone.Hips
        && restored.joints[1].targetJoint === HumanoidBone.Head
        && restored.skeletonHash === 'hash-a';
    }
    return HumanoidMappingTest.buildResult('15_SerializeAndDeserialize', ok,
      'restoredJoints=' + jointCount + ', hash=' + hashValue);
  }

  /** 16. 清空映射 */
  private static test16_ClearAllMappings(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.Hips,
      sourceNodeIndex: 5,
      sourceBoneName: 'hips',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.Head,
      sourceNodeIndex: 10,
      sourceBoneName: 'head',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    clearAllBindings(mapping);
    const ok: boolean = mapping.joints.length === 0
      && mapping.autoMappedCount === 0
      && mapping.manualMappedCount === 0
      && !mapping.valid
      && !mapping.retargetReady;
    return HumanoidMappingTest.buildResult('16_ClearAllMappings', ok,
      'joints=' + mapping.joints.length + ', valid=' + mapping.valid);
  }

  /** 17. 自动映射后手动修正(替换 auto 为 manual) */
  private static test17_AutoThenManualOverride(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    // 先自动映射
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.Head,
      sourceNodeIndex: 10,
      sourceBoneName: 'head_auto',
      mappingMethod: BoneMappingMethod.Auto,
      confidence: 0.7
    });
    refreshMappingStats(mapping, REQUIRED_BONES, OPTIONAL_BONES);
    const autoCount1: number = mapping.autoMappedCount;
    // 手动修正(同 target)
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.Head,
      sourceNodeIndex: 15,
      sourceBoneName: 'head_manual',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    refreshMappingStats(mapping, REQUIRED_BONES, OPTIONAL_BONES);
    const ok: boolean = autoCount1 === 1
      && mapping.autoMappedCount === 0
      && mapping.manualMappedCount === 1
      && mapping.joints.length === 1
      && mapping.joints[0].sourceNodeIndex === 15
      && mapping.joints[0].mappingMethod === BoneMappingMethod.Manual;
    return HumanoidMappingTest.buildResult('17_AutoThenManualOverride', ok,
      'autoBefore=' + autoCount1 + ', autoAfter=' + mapping.autoMappedCount
      + ', manualAfter=' + mapping.manualMappedCount);
  }

  /** 18. 对称骨骼建议(左右上臂均映射,左右不冲突) */
  private static test18_SymmetricBoneSuggestion(): TestResult {
    const mapping: ManualHumanoidMapping = createEmptyManualMapping('modelA', 'sha-a', 'hash-a');
    // Left/Right 上臂映射到不同的 sourceNodeIndex(正常对称)
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.LeftUpperArm,
      sourceNodeIndex: 10,
      sourceBoneName: 'upperarm_l',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    setJointBinding(mapping, {
      targetJoint: HumanoidBone.RightUpperArm,
      sourceNodeIndex: 20,
      sourceBoneName: 'upperarm_r',
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    });
    // 不同 sourceNodeIndex → 不冲突
    let hasDuplicateError: boolean = false;
    // 构造简化输入做验证
    const input: HumanoidMappingValidatorInput = {
      mapping: mapping,
      totalNodeCount: TEST_TOTAL_NODE_COUNT,
      currentSkeletonHash: 'hash-a',
      parentIndices: [],
      restPoses: [],
      optionalBones: OPTIONAL_BONES,
      skinJointNodeIndices: [],
      currentSourceSha256: ''
    };
    const result: HumanoidMappingValidationResult = validateHumanoidMapping(input);
    for (let i: number = 0; i < result.errors.length; i++) {
      if (result.errors[i].type === HumanoidMappingIssueType.DuplicateSourceBone) {
        hasDuplicateError = true;
        break;
      }
    }
    // 验证 normalizeBoneName 能正确处理 left/right 前缀
    const normLeft: string = normalizeBoneName('upperarm_l');
    const normRight: string = normalizeBoneName('upperarm_r');
    const nameOk: boolean = normLeft !== normRight;
    const ok: boolean = !hasDuplicateError && nameOk;
    return HumanoidMappingTest.buildResult('18_SymmetricBoneSuggestion', ok,
      'hasDuplicateError=' + hasDuplicateError
      + ', normLeft=' + normLeft + ', normRight=' + normRight);
  }

  // ========== 辅助函数 ==========

  /**
   * 构造一个 rest pose(用于世界坐标测试)。
   */
  private static makeRestPose(
    nodeIndex: number,
    parentNodeIndex: number,
    x: number,
    y: number,
    z: number
  ): SkeletonRestPose {
    const m: number[] = [
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      x, y, z, 1
    ];
    return {
      nodeIndex: nodeIndex,
      parentNodeIndex: parentNodeIndex,
      localTranslation: { x: x, y: y, z: z },
      localRotation: { x: 0, y: 0, z: 0, w: 1 },
      localScale: { x: 1, y: 1, z: 1 },
      worldMatrix: { m: m }
    };
  }

  /**
   * 构造测试结果。
   */
  private static buildResult(name: string, passed: boolean, message: string): TestResult {
    Logger.info(LOG_TAG, name + ': ' + (passed ? 'PASS' : 'FAIL') + ' - ' + message);
    return {
      name: name,
      passed: passed,
      message: message
    };
  }
}

/**
 * 计算测试用可选骨骼列表(ALL_STANDARD_BONES 中除 REQUIRED_BONES 外的)。
 */
function computeOptionalBonesForTest(): HumanoidBone[] {
  const optional: HumanoidBone[] = [];
  for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
    if (REQUIRED_BONES.indexOf(ALL_STANDARD_BONES[i]) < 0) {
      optional.push(ALL_STANDARD_BONES[i]);
    }
  }
  return optional;
}
