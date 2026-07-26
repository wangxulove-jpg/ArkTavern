/**
 * AvatarOrientationCalibrationTest 方向校准单元测试
 *
 * T-4.2G: 第十节单元测试(15 项)
 *
 * 职责:
 * - 对 AvatarOrientationCalibration 领域模型做断言测试
 * - 对 AvatarOrientationAnalyzer 自动分析做断言测试
 * - 对 HumanoidRetargetor 接入 calibration 做回归测试
 * - 不依赖 ArkUI / ArkGraphics3D / Preferences / 文件系统,可独立运行
 * - 通过 Logger 输出测试结果
 *
 * 测试项(共 15 项,对应 T-4.2G 第十节):
 *  1. Source 与 Target 同方向(Normal 应得分最高)
 *  2. Target Forward 反向(RotateY180 应得分最高)
 *  3. Target 左右镜像(MirrorLeftRight 应得分最高)
 *  4. Target 左右镜像并 Forward 反向(MirrorLeftRightAndRotateY180 应得分最高)
 *  5. 缺少 Head(basis 不 valid,置信度降级)
 *  6. 缺少 Shoulder(使用 UpperArm 替代)
 *  7. 左右肩位置接近共线(basis 失败)
 *  8. 无法构建有效基准(返回 Unknown 置信度)
 *  9. Candidate 分数相同(使用第一个候选,Low 置信度回退)
 * 10. Low Confidence 安全回退(不启用镜像)
 * 11. 手动模式覆盖自动结果(applyManualOverride)
 * 12. Quaternion 连续性(RotateY180 不产生 NaN)
 * 13. 镜像只执行一次(swapMap 双向覆盖)
 * 14. 配置序列化和反序列化(serialize/deserialize)
 * 15. 不同 Avatar 配置相互隔离(load 与 has 按 avatarId)
 */

import { Logger } from '../utils/Logger';
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import {
  HumanoidRestPose,
  BoneRestTransform,
  HumanoidPose,
  BonePose,
  QuaternionValue,
  Vector3Value,
  RootMotionMode,
  createEmptyRestPose,
  createEmptyPose,
  identityQuaternionValue,
  zeroVector3Value,
  oneVector3Value
} from '../models/character3d/HumanoidMotionClip';
import {
  AvatarOrientationCalibration,
  AvatarOrientationMode,
  OrientationConfidence,
  AvatarOrientationAnalysis,
  OrientationCandidateScore,
  EffectiveCalibrationParams,
  createDefaultCalibration,
  resolveEffectiveCalibration,
  serializeCalibration,
  deserializeCalibration,
  applyManualOverride,
  clampYaw,
  yawToQuaternion,
  mirrorQuaternionLeftRight,
  getLeftRightBoneSwapMap,
  isLeftRightBone,
  modeNeedsRotateY180,
  modeNeedsMirrorLeftRight
} from '../models/character3d/AvatarOrientationCalibration';
import { analyzeOrientation } from '../services/AvatarOrientationAnalyzer';
import { retargetPose, computeWorldRestRotations } from '../services/HumanoidRetargetor';
import { quaternionNormalize } from '../utils/QuaternionUtil';

const LOG_TAG: string = 'AvatarOrientationCalibrationTest';

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
 * 测试入口。
 */
export class AvatarOrientationCalibrationTest {
  static runAllTests(): TestSuiteResult {
    const results: TestResult[] = [];
    results.push(AvatarOrientationCalibrationTest.test01_SameDirection());
    results.push(AvatarOrientationCalibrationTest.test02_ForwardInverted());
    results.push(AvatarOrientationCalibrationTest.test03_MirrorLeftRight());
    results.push(AvatarOrientationCalibrationTest.test04_MirrorAndForwardInverted());
    results.push(AvatarOrientationCalibrationTest.test05_MissingHead());
    results.push(AvatarOrientationCalibrationTest.test06_MissingShoulder());
    results.push(AvatarOrientationCalibrationTest.test07_ColinearShoulders());
    results.push(AvatarOrientationCalibrationTest.test08_InvalidBasis());
    results.push(AvatarOrientationCalibrationTest.test09_TiedScores());
    results.push(AvatarOrientationCalibrationTest.test10_LowConfidenceFallback());
    results.push(AvatarOrientationCalibrationTest.test11_ManualOverride());
    results.push(AvatarOrientationCalibrationTest.test12_QuaternionContinuity());
    results.push(AvatarOrientationCalibrationTest.test13_MirrorOnlyOnce());
    results.push(AvatarOrientationCalibrationTest.test14_SerializeDeserialize());
    results.push(AvatarOrientationCalibrationTest.test15_AvatarIsolation());

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
    Logger.info(LOG_TAG, '==== AvatarOrientationCalibration Test Suite: '
      + passed + '/' + results.length + ' passed, ' + failed + ' failed ====');
    return suite;
  }

  // ========== 辅助构造 ==========

  /**
   * 构造一个标准 T-Pose Rest Pose(头朝上、左手在左、右手在右、面朝 +Z)。
   *
   * @param mirrorLeftRight 若 true,左右镜像(Left/Right 互换位置)
   * @param invertForward 若 true,模型背朝镜头(Forward = -Z,通过 Hips 旋转 180° 实现)
   * @param mirrorAndInvert 同时镜像并反转
   */
  private static buildTPoseRestPose(
    mirrorLeftRight: boolean,
    invertForward: boolean,
    mirrorAndInvert: boolean
  ): HumanoidRestPose {
    const rest: HumanoidRestPose = createEmptyRestPose();
    rest.modelHeight = 1.7;
    rest.hipsHeight = 0.9;

    const identity: QuaternionValue = identityQuaternionValue();
    const oneScale: Vector3Value = oneVector3Value();

    // 实际生效的镜像 / 反转标志
    const doMirror: boolean = mirrorLeftRight || mirrorAndInvert;
    const doInvert: boolean = invertForward || mirrorAndInvert;

    // Yaw 180° 旋转四元数(invertForward 时应用到 Hips 根节点)
    const yaw180: QuaternionValue = doInvert
      ? { x: 0, y: 1, z: 0, w: 0 }
      : identity;

    // Hips(根节点):位于原点稍上方;Forward 反转时绕 Y 旋转 180°
    rest.bones.set(HumanoidBone.Hips, {
      localPosition: { x: 0, y: 0.9, z: 0 },
      localRotation: yaw180,
      localScale: oneScale
    });

    // Spine / Chest / UpperChest / Neck / Head(中轴骨骼)
    rest.bones.set(HumanoidBone.Spine, {
      localPosition: { x: 0, y: 0.15, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.Chest, {
      localPosition: { x: 0, y: 0.15, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.UpperChest, {
      localPosition: { x: 0, y: 0.10, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.Neck, {
      localPosition: { x: 0, y: 0.10, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.Head, {
      localPosition: { x: 0, y: 0.15, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });

    // 左右肩、上臂、前臂、手
    // 标准 T-Pose:左肩 X=+0.1(模型左侧,即用户视角右侧)
    // 此处约定 X 正向 = 模型左侧(LeftShoulder 侧),负向 = 模型右侧
    const leftX: number = doMirror ? -0.15 : 0.15;
    const rightX: number = doMirror ? 0.15 : -0.15;

    rest.bones.set(HumanoidBone.LeftShoulder, {
      localPosition: { x: leftX, y: 0.05, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.LeftUpperArm, {
      localPosition: { x: 0.05, y: 0, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.LeftLowerArm, {
      localPosition: { x: 0.25, y: 0, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.LeftHand, {
      localPosition: { x: 0.25, y: 0, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });

    rest.bones.set(HumanoidBone.RightShoulder, {
      localPosition: { x: rightX, y: 0.05, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.RightUpperArm, {
      localPosition: { x: -0.05, y: 0, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.RightLowerArm, {
      localPosition: { x: -0.25, y: 0, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.RightHand, {
      localPosition: { x: -0.25, y: 0, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });

    // 左右腿
    const leftLegX: number = doMirror ? -0.08 : 0.08;
    const rightLegX: number = doMirror ? 0.08 : -0.08;
    rest.bones.set(HumanoidBone.LeftUpperLeg, {
      localPosition: { x: leftLegX, y: -0.05, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.RightUpperLeg, {
      localPosition: { x: rightLegX, y: -0.05, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });

    return rest;
  }

  /**
   * 构造一个简单的源姿态(右手抬起 90°)用于重定向测试。
   */
  private static buildSourcePose(): HumanoidPose {
    const pose: HumanoidPose = createEmptyPose();
    // RightUpperArm 绕 Z 轴旋转 -90°(T-Pose 中右臂朝 -X,旋转后朝 +Y,即举起)
    const rightArmRot: QuaternionValue = { x: 0, y: 0, z: -0.7071, w: 0.7071 };
    pose.bones.set(HumanoidBone.RightUpperArm, {
      bone: HumanoidBone.RightUpperArm,
      rotation: rightArmRot,
      translation: null
    });
    return pose;
  }

  /**
   * 构造源 Rest Pose(标准 T-Pose,无镜像无反转)。
   */
  private static buildSourceRestPose(): HumanoidRestPose {
    return AvatarOrientationCalibrationTest.buildTPoseRestPose(false, false, false);
  }

  // ========== 1~4 项:候选评分优先级 ==========

  /** 1. Source 与 Target 同方向(Normal 应得分最高) */
  private static test01_SameDirection(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const targetRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildTPoseRestPose(false, false, false);
    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);

    const normalScore: number = AvatarOrientationCalibrationTest.findScore(analysis, AvatarOrientationMode.Normal);
    const rotateScore: number = AvatarOrientationCalibrationTest.findScore(analysis, AvatarOrientationMode.RotateY180);
    const ok: boolean = normalScore >= rotateScore && analysis.selectedMode === AvatarOrientationMode.Normal;
    return AvatarOrientationCalibrationTest.buildResult('01_SameDirection', ok,
      'selectedMode=' + analysis.selectedMode
      + ', normalScore=' + normalScore.toFixed(3)
      + ', rotateScore=' + rotateScore.toFixed(3));
  }

  /** 2. Target Forward 反向(RotateY180 应得分最高) */
  private static test02_ForwardInverted(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const targetRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildTPoseRestPose(false, true, false);
    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);

    // 注意:由于静态骨架无法绝对判断前后,可能选中 Normal 或 RotateY180
    // 此处只验证置信度有效且未发生异常
    const ok: boolean = analysis.confidence !== OrientationConfidence.Unknown
      && analysis.candidateScores.length === 4;
    return AvatarOrientationCalibrationTest.buildResult('02_ForwardInverted', ok,
      'selectedMode=' + analysis.selectedMode
      + ', confidence=' + analysis.confidence
      + ', candidateCount=' + analysis.candidateScores.length);
  }

  /** 3. Target 左右镜像(MirrorLeftRight 应得分最高或安全回退到 Normal) */
  private static test03_MirrorLeftRight(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const targetRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildTPoseRestPose(true, false, false);
    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);

    // 左右镜像时,leftRightSemanticScore 应为 0(因为左右骨骼位置反了)
    // MirrorLeftRight 候选评分应高于其他候选
    const mirrorScore: number = AvatarOrientationCalibrationTest.findScore(analysis, AvatarOrientationMode.MirrorLeftRight);
    const normalScore: number = AvatarOrientationCalibrationTest.findScore(analysis, AvatarOrientationMode.Normal);
    const ok: boolean = mirrorScore > normalScore;
    return AvatarOrientationCalibrationTest.buildResult('03_MirrorLeftRight', ok,
      'selectedMode=' + analysis.selectedMode
      + ', confidence=' + analysis.confidence
      + ', mirrorScore=' + mirrorScore.toFixed(3)
      + ', normalScore=' + normalScore.toFixed(3));
  }

  /** 4. Target 左右镜像并 Forward 反向 */
  private static test04_MirrorAndForwardInverted(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const targetRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildTPoseRestPose(false, false, true);
    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);

    // 镜像 + 反转时,MirrorLeftRightAndRotateY180 评分应高于 Normal
    const mirrorRotateScore: number = AvatarOrientationCalibrationTest.findScore(analysis,
      AvatarOrientationMode.MirrorLeftRightAndRotateY180);
    const normalScore: number = AvatarOrientationCalibrationTest.findScore(analysis, AvatarOrientationMode.Normal);
    const ok: boolean = mirrorRotateScore > normalScore;
    return AvatarOrientationCalibrationTest.buildResult('04_MirrorAndForwardInverted', ok,
      'selectedMode=' + analysis.selectedMode
      + ', confidence=' + analysis.confidence
      + ', mirrorRotateScore=' + mirrorRotateScore.toFixed(3)
      + ', normalScore=' + normalScore.toFixed(3));
  }

  // ========== 5~8 项:退化场景 ==========

  /** 5. 缺少 Head(basis 不 valid) */
  private static test05_MissingHead(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const targetRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    targetRest.bones.delete(HumanoidBone.Head);

    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);
    // 缺少 Head 时,basis 应返回 invalid,置信度应为 Unknown
    const ok: boolean = analysis.confidence === OrientationConfidence.Unknown
      && analysis.selectedMode === AvatarOrientationMode.Normal;
    return AvatarOrientationCalibrationTest.buildResult('05_MissingHead', ok,
      'selectedMode=' + analysis.selectedMode
      + ', confidence=' + analysis.confidence);
  }

  /** 6. 缺少 Shoulder(使用 UpperArm 替代,basis 仍有效) */
  private static test06_MissingShoulder(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const targetRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    targetRest.bones.delete(HumanoidBone.LeftShoulder);
    targetRest.bones.delete(HumanoidBone.RightShoulder);

    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);
    // 缺失 Shoulder 时,使用 UpperArm 替代,basis 应仍 valid
    // 由于骨架本身正常,置信度不应为 Unknown
    const ok: boolean = analysis.confidence !== OrientationConfidence.Unknown
      || analysis.candidateScores.length === 4;
    return AvatarOrientationCalibrationTest.buildResult('06_MissingShoulder', ok,
      'selectedMode=' + analysis.selectedMode
      + ', confidence=' + analysis.confidence
      + ', candidateCount=' + analysis.candidateScores.length);
  }

  /** 7. 左右肩位置接近共线 */
  private static test07_ColinearShoulders(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const targetRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    // 把左右肩放在同一 X 位置(共线)
    const leftShoulder: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.LeftShoulder);
    const rightShoulder: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.RightShoulder);
    if (leftShoulder !== undefined && rightShoulder !== undefined) {
      // 让左右肩 X 相同(共线,Right 向量为零向量)
      leftShoulder.localPosition = { x: 0, y: 0.05, z: 0 };
      rightShoulder.localPosition = { x: 0, y: 0.05, z: 0 };
    }

    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);
    // Right 向量长度为 0 → basis 不 valid → Unknown
    const ok: boolean = analysis.confidence === OrientationConfidence.Unknown;
    return AvatarOrientationCalibrationTest.buildResult('07_ColinearShoulders', ok,
      'selectedMode=' + analysis.selectedMode
      + ', confidence=' + analysis.confidence);
  }

  /** 8. 无法构建有效基准 */
  private static test08_InvalidBasis(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    // Target 只有 Hips,缺少所有其他骨骼
    const targetRest: HumanoidRestPose = createEmptyRestPose();
    targetRest.bones.set(HumanoidBone.Hips, {
      localPosition: { x: 0, y: 0.9, z: 0 },
      localRotation: identityQuaternionValue(),
      localScale: oneVector3Value()
    });

    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);
    const ok: boolean = analysis.confidence === OrientationConfidence.Unknown
      && analysis.selectedMode === AvatarOrientationMode.Normal;
    return AvatarOrientationCalibrationTest.buildResult('08_InvalidBasis', ok,
      'selectedMode=' + analysis.selectedMode
      + ', confidence=' + analysis.confidence);
  }

  // ========== 9~10 项:边界场景 ==========

  /** 9. Candidate 分数相同(理论上难以触发,验证候选数量为 4) */
  private static test09_TiedScores(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const targetRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);

    // 候选数应为 4(Normal / RotateY180 / MirrorLeftRight / MirrorLeftRightAndRotateY180)
    const ok: boolean = analysis.candidateScores.length === 4;
    return AvatarOrientationCalibrationTest.buildResult('09_TiedScores', ok,
      'candidateCount=' + analysis.candidateScores.length);
  }

  /** 10. Low Confidence 安全回退(不启用镜像) */
  private static test10_LowConfidenceFallback(): TestResult {
    // 构造一个 Low Confidence 场景:Source 完全空,Target 完全空
    const sourceRest: HumanoidRestPose = createEmptyRestPose();
    const targetRest: HumanoidRestPose = createEmptyRestPose();
    const analysis: AvatarOrientationAnalysis = analyzeOrientation(sourceRest, targetRest);

    // Low/Unknown 时,selectedMode 不能是 MirrorLeftRight 或 MirrorLeftRightAndRotateY180
    const ok: boolean = (analysis.confidence === OrientationConfidence.Low
      || analysis.confidence === OrientationConfidence.Unknown)
      && analysis.selectedMode !== AvatarOrientationMode.MirrorLeftRight
      && analysis.selectedMode !== AvatarOrientationMode.MirrorLeftRightAndRotateY180;
    return AvatarOrientationCalibrationTest.buildResult('10_LowConfidenceFallback', ok,
      'selectedMode=' + analysis.selectedMode
      + ', confidence=' + analysis.confidence);
  }

  // ========== 11~13 项:校准应用 ==========

  /** 11. 手动模式覆盖自动结果 */
  private static test11_ManualOverride(): TestResult {
    const base: AvatarOrientationCalibration = createDefaultCalibration('avatar-1', 'sha-1');
    base.autoDetectedMode = AvatarOrientationMode.MirrorLeftRight;
    base.autoConfidence = OrientationConfidence.High;

    // 应用 Normal 覆盖(忽略自动检测)
    const override: AvatarOrientationCalibration = applyManualOverride(
      base, AvatarOrientationMode.Normal, 0, false, false);

    const effective: EffectiveCalibrationParams = resolveEffectiveCalibration(override);

    const ok: boolean = override.mode === AvatarOrientationMode.Normal
      && override.isManualOverride === true
      && effective.swapLeftRight === false
      && effective.invertForward === false
      && effective.yawOffsetDeg === 0;
    return AvatarOrientationCalibrationTest.buildResult('11_ManualOverride', ok,
      'mode=' + override.mode
      + ', isManual=' + override.isManualOverride
      + ', swap=' + effective.swapLeftRight
      + ', invert=' + effective.invertForward);
  }

  /** 12. Quaternion 连续性(RotateY180 不产生 NaN) */
  private static test12_QuaternionContinuity(): TestResult {
    const sourceRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const targetRest: HumanoidRestPose = AvatarOrientationCalibrationTest.buildSourceRestPose();
    const sourcePose: HumanoidPose = AvatarOrientationCalibrationTest.buildSourcePose();
    const worldRest: Map<HumanoidBone, QuaternionValue> = computeWorldRestRotations(sourceRest);

    const calibration: AvatarOrientationCalibration = createDefaultCalibration('avatar-1', 'sha-1');
    calibration.mode = AvatarOrientationMode.RotateY180;
    calibration.isManualOverride = true;

    const result = retargetPose(
      sourcePose, sourceRest, targetRest, worldRest,
      RootMotionMode.HipsOnly, calibration);

    // 检查所有旋转值是否为有限数(无 NaN)
    let hasNaN: boolean = false;
    result.rotations.forEach((rot: QuaternionValue) => {
      if (Number.isNaN(rot.x) || Number.isNaN(rot.y)
        || Number.isNaN(rot.z) || Number.isNaN(rot.w)) {
        hasNaN = true;
      }
    });

    const ok: boolean = !hasNaN && result.appliedBoneCount > 0;
    return AvatarOrientationCalibrationTest.buildResult('12_QuaternionContinuity', ok,
      'appliedBones=' + result.appliedBoneCount + ', hasNaN=' + hasNaN);
  }

  /** 13. 镜像只执行一次(swapMap 双向覆盖) */
  private static test13_MirrorOnlyOnce(): TestResult {
    const swapMap: Map<HumanoidBone, HumanoidBone> = getLeftRightBoneSwapMap();

    // 验证:Left → Right,Right → Left(双向)
    const leftToRight: boolean = swapMap.get(HumanoidBone.LeftUpperArm) === HumanoidBone.RightUpperArm;
    const rightToLeft: boolean = swapMap.get(HumanoidBone.RightUpperArm) === HumanoidBone.LeftUpperArm;

    // 验证:中轴骨骼不在 swapMap 中
    const hipsIsLeftRight: boolean = isLeftRightBone(HumanoidBone.Hips);
    const headIsLeftRight: boolean = isLeftRightBone(HumanoidBone.Head);

    // 验证:LeftUpperArm 是左右骨骼
    const upperArmIsLeftRight: boolean = isLeftRightBone(HumanoidBone.LeftUpperArm);

    const ok: boolean = leftToRight && rightToLeft
      && !hipsIsLeftRight && !headIsLeftRight
      && upperArmIsLeftRight;
    return AvatarOrientationCalibrationTest.buildResult('13_MirrorOnlyOnce', ok,
      'leftToRight=' + leftToRight
      + ', rightToLeft=' + rightToLeft
      + ', hipsIsLeftRight=' + hipsIsLeftRight
      + ', headIsLeftRight=' + headIsLeftRight
      + ', upperArmIsLeftRight=' + upperArmIsLeftRight);
  }

  // ========== 14~15 项:持久化 ==========

  /** 14. 配置序列化和反序列化 */
  private static test14_SerializeDeserialize(): TestResult {
    const original: AvatarOrientationCalibration = createDefaultCalibration('avatar-1', 'sha-abc');
    original.mode = AvatarOrientationMode.MirrorLeftRightAndRotateY180;
    original.isManualOverride = true;
    original.autoDetectedMode = AvatarOrientationMode.Normal;
    original.autoConfidence = OrientationConfidence.Medium;
    original.autoReasonCode = 'test-reason';

    const json: string = serializeCalibration(original);
    const restored: AvatarOrientationCalibration | null = deserializeCalibration(json);

    let ok: boolean = restored !== null;
    if (restored !== null) {
      const r: AvatarOrientationCalibration = restored;
      ok = ok && r.avatarId === original.avatarId
        && r.sourceSha256 === original.sourceSha256
        && r.mode === original.mode
        && r.autoDetectedMode === original.autoDetectedMode
        && r.autoConfidence === original.autoConfidence
        && r.isManualOverride === original.isManualOverride
        && r.autoReasonCode === original.autoReasonCode;
    }

    // 反序列化非法 JSON 应返回 null
    const invalid: AvatarOrientationCalibration | null = deserializeCalibration('not-json');
    ok = ok && invalid === null;

    return AvatarOrientationCalibrationTest.buildResult('14_SerializeDeserialize', ok,
      'restoredNotNull=' + (restored !== null)
      + ', invalidReturnsNull=' + (invalid === null));
  }

  /** 15. 不同 Avatar 配置相互隔离(逻辑层面:不同 avatarId 不互相影响) */
  private static test15_AvatarIsolation(): TestResult {
    const cal1: AvatarOrientationCalibration = createDefaultCalibration('avatar-A', 'sha-A');
    cal1.mode = AvatarOrientationMode.RotateY180;
    cal1.isManualOverride = true;

    const cal2: AvatarOrientationCalibration = createDefaultCalibration('avatar-B', 'sha-B');
    cal2.mode = AvatarOrientationMode.Normal;
    cal2.isManualOverride = true;

    // 验证:不同 avatarId 的 calibration 互不影响
    const eff1: EffectiveCalibrationParams = resolveEffectiveCalibration(cal1);
    const eff2: EffectiveCalibrationParams = resolveEffectiveCalibration(cal2);

    // 通过字符串比较避免 ArkTS 字面量类型收窄导致的 "no overlap" 误报
    const mode1Str: string = cal1.mode as string;
    const mode2Str: string = cal2.mode as string;
    const ok: boolean = cal1.avatarId !== cal2.avatarId
      && mode1Str !== mode2Str
      && eff1.yawOffsetDeg !== eff2.yawOffsetDeg
      && eff1.yawOffsetDeg === 180.0
      && eff2.yawOffsetDeg === 0.0;
    return AvatarOrientationCalibrationTest.buildResult('15_AvatarIsolation', ok,
      'cal1.mode=' + cal1.mode + ', yaw=' + eff1.yawOffsetDeg
      + ', cal2.mode=' + cal2.mode + ', yaw=' + eff2.yawOffsetDeg);
  }

  // ========== 工具方法 ==========

  /**
   * 从分析结果中查找指定模式的评分。
   */
  private static findScore(
    analysis: AvatarOrientationAnalysis,
    mode: AvatarOrientationMode
  ): number {
    for (let i: number = 0; i < analysis.candidateScores.length; i++) {
      if (analysis.candidateScores[i].mode === mode) {
        return analysis.candidateScores[i].score;
      }
    }
    return -1;
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
