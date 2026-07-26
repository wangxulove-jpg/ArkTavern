/**
 * RetargetInvariantTest 重定向不变量测试
 *
 * T-4.2G-A1: 验证 HumanoidRetargetor 的核心不变量。
 *
 * 测试项:
 *  1. Identity Delta:source 动画旋转 == source rest 旋转时,target 必须保持 rest
 *     - 断言 sourceDelta == Identity(sourceDeltaAngleDeg ≈ 0)
 *     - 断言 targetAnimatedRotation == targetRestRotation
 *     - Target 为 T Pose 时,UpperArm 仍为 T Pose(不变为下垂)
 *  2. Source Arms-Down → Target T-Pose:Source 双臂下垂,Target T Pose
 *     - 无动作时 Target 必须保持 T Pose
 *     - UpperArm Rotation == Target Rest
 *  3. RightLowerArm 单侧动作:只旋转 Source RightLowerArm
 *     - Target RightUpperArm 继续基于 T Pose(不变)
 *     - Target RightLowerArm 产生动作(变化)
 *     - Left Arm 不变化
 *  4. T Pose 连续应用 Identity Delta 不漂移:连续 10 次
 *     - UpperArm 不逐次下垂
 *     - 停止后仍精确恢复 T Pose
 *
 * 不依赖 ArkUI / ArkGraphics3D / 文件系统,可独立运行。
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
  oneVector3Value
} from '../models/character3d/HumanoidMotionClip';
import {
  retargetPose,
  computeWorldRestRotations,
  RetargetResult,
  AxisCorrectionStat,
  quaternionRotationAngleDeg
} from '../services/HumanoidRetargetor';
import { quaternionEqual, quaternionToEulerDeg } from '../utils/QuaternionUtil';

const LOG_TAG: string = 'RetargetInvariantTest';

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
export class RetargetInvariantTest {
  static runAllTests(): TestSuiteResult {
    const results: TestResult[] = [];
    results.push(RetargetInvariantTest.test01_IdentityDelta());
    results.push(RetargetInvariantTest.test02_SourceArmsDown_TargetTPose());
    results.push(RetargetInvariantTest.test03_RightLowerArmSingleBoneMotion());
    results.push(RetargetInvariantTest.test04_TPoseNoDrift());

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
    Logger.info(LOG_TAG, '==== RetargetInvariant Test Suite: '
      + passed + '/' + results.length + ' passed, ' + failed + ' failed ====');
    return suite;
  }

  // ========== 辅助构造 ==========

  /**
   * 构造 T Pose UpperArm 旋转(X 轴旋转 90°,使双臂水平展开)。
   *
   * 在 glTF 坐标系中:
   * - 左臂沿 -X 方向延伸,UpperArm 绕 X 轴旋转 -90° 使手臂水平向左
   * - 右臂沿 +X 方向延伸,UpperArm 绕 X 轴旋转 +90° 使手臂水平向右
   *
   * 四元数:X 轴旋转 θ 的四元数为 (sin(θ/2), 0, 0, cos(θ/2))
   *
   * @param isLeft true 表示左臂(-90°),false 表示右臂(+90°)
   */
  private static tPoseUpperArmRotation(isLeft: boolean): QuaternionValue {
    const halfRad: number = (90.0 * Math.PI / 180.0) / 2.0;
    const sinV: number = Math.sin(halfRad);
    const cosV: number = Math.cos(halfRad);
    return isLeft
      ? { x: -sinV, y: 0, z: 0, w: cosV }
      : { x: sinV, y: 0, z: 0, w: cosV };
  }

  /**
   * 构造 RightLowerArm 弯曲旋转(绕 X 轴旋转 -45°,模拟前臂向上弯曲)。
   */
  private static lowerArmBendRotation(): QuaternionValue {
    const halfRad: number = (45.0 * Math.PI / 180.0) / 2.0;
    const sinV: number = Math.sin(halfRad);
    const cosV: number = Math.cos(halfRad);
    return { x: -sinV, y: 0, z: 0, w: cosV };
  }

  /**
   * 构造完整的 T Pose Rest Pose(头朝上、双臂水平展开)。
   *
   * 骨骼层级与 translation(局部,相对父骨骼):
   * - Hips (root) at (0, 0.9, 0)
   *   - Spine at (0, 0.1, 0)
   *     - Chest at (0, 0.1, 0)
   *       - UpperChest at (0, 0.05, 0)
   *         - Neck at (0, 0.05, 0)
   *           - Head at (0, 0.1, 0)
   *         - LeftShoulder at (-0.05, 0.05, 0)
   *           - LeftUpperArm at (0, 0.05, 0) [rotation: X轴 -90°]
   *             - LeftLowerArm at (0, -0.25, 0)
   *               - LeftHand at (0, -0.25, 0)
   *         - RightShoulder at (0.05, 0.05, 0)
   *           - RightUpperArm at (0, 0.05, 0) [rotation: X轴 +90°]
   *             - RightLowerArm at (0, -0.25, 0)
   *               - RightHand at (0, -0.25, 0)
   */
  private static buildTPoseRestPose(): HumanoidRestPose {
    const rest: HumanoidRestPose = createEmptyRestPose();
    rest.modelHeight = 1.7;
    rest.hipsHeight = 0.9;

    const identity: QuaternionValue = identityQuaternionValue();
    const oneScale: Vector3Value = oneVector3Value();

    // 中轴骨骼
    rest.bones.set(HumanoidBone.Hips, {
      localPosition: { x: 0, y: 0.9, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.Spine, {
      localPosition: { x: 0, y: 0.1, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.Chest, {
      localPosition: { x: 0, y: 0.1, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.UpperChest, {
      localPosition: { x: 0, y: 0.05, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.Neck, {
      localPosition: { x: 0, y: 0.05, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.Head, {
      localPosition: { x: 0, y: 0.1, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });

    // 左臂(T Pose:UpperArm X 轴 -90°)
    rest.bones.set(HumanoidBone.LeftShoulder, {
      localPosition: { x: -0.05, y: 0.05, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.LeftUpperArm, {
      localPosition: { x: 0, y: 0.05, z: 0 },
      localRotation: RetargetInvariantTest.tPoseUpperArmRotation(true),
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.LeftLowerArm, {
      localPosition: { x: 0, y: -0.25, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.LeftHand, {
      localPosition: { x: 0, y: -0.25, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });

    // 右臂(T Pose:UpperArm X 轴 +90°)
    rest.bones.set(HumanoidBone.RightShoulder, {
      localPosition: { x: 0.05, y: 0.05, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.RightUpperArm, {
      localPosition: { x: 0, y: 0.05, z: 0 },
      localRotation: RetargetInvariantTest.tPoseUpperArmRotation(false),
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.RightLowerArm, {
      localPosition: { x: 0, y: -0.25, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });
    rest.bones.set(HumanoidBone.RightHand, {
      localPosition: { x: 0, y: -0.25, z: 0 },
      localRotation: identity,
      localScale: oneScale
    });

    return rest;
  }

  /**
   * 构造 Arms-Down Rest Pose(双臂下垂,UpperArm 旋转为 identity)。
   *
   * 与 T Pose 唯一区别:UpperArm.localRotation = identity(而非 X 轴 ±90°)。
   */
  private static buildArmsDownRestPose(): HumanoidRestPose {
    const rest: HumanoidRestPose = RetargetInvariantTest.buildTPoseRestPose();
    // 修改 UpperArm 旋转为 identity(双臂下垂)
    const leftUpperArm: BoneRestTransform | undefined = rest.bones.get(HumanoidBone.LeftUpperArm);
    const rightUpperArm: BoneRestTransform | undefined = rest.bones.get(HumanoidBone.RightUpperArm);
    if (leftUpperArm !== undefined) {
      leftUpperArm.localRotation = identityQuaternionValue();
    }
    if (rightUpperArm !== undefined) {
      rightUpperArm.localRotation = identityQuaternionValue();
    }
    return rest;
  }

  /**
   * 构造 sourcePose:所有骨骼的 rotation == sourceRest.localRotation(即 Identity Delta)。
   *
   * 这模拟"无动画"或"动画第 0 帧恰好等于 Rest Pose"的场景。
   */
  private static buildIdentityDeltaPose(sourceRest: HumanoidRestPose): HumanoidPose {
    const pose: HumanoidPose = createEmptyPose();
    sourceRest.bones.forEach((rest: BoneRestTransform, bone: HumanoidBone) => {
      pose.bones.set(bone, {
        bone: bone,
        rotation: rest.localRotation,
        translation: rest.localPosition
      });
    });
    return pose;
  }

  /**
   * 构造 sourcePose:仅 RightLowerArm 旋转,其他骨骼保持 Rest。
   *
   * @param sourceRest 源 Rest Pose
   * @param rightLowerArmRotation RightLowerArm 的旋转值
   */
  private static buildSingleBoneMotionPose(
    sourceRest: HumanoidRestPose,
    rightLowerArmRotation: QuaternionValue
  ): HumanoidPose {
    const pose: HumanoidPose = RetargetInvariantTest.buildIdentityDeltaPose(sourceRest);
    const rlaPose: BonePose | undefined = pose.bones.get(HumanoidBone.RightLowerArm);
    if (rlaPose !== undefined) {
      rlaPose.rotation = rightLowerArmRotation;
    } else {
      pose.bones.set(HumanoidBone.RightLowerArm, {
        bone: HumanoidBone.RightLowerArm,
        rotation: rightLowerArmRotation,
        translation: sourceRest.bones.get(HumanoidBone.RightLowerArm)?.localPosition ?? { x: 0, y: 0, z: 0 }
      });
    }
    return pose;
  }

  /**
   * 获取四元数的旋转角度(度)。
   * 用于诊断 UpperArm 是否仍为 T Pose(应接近 90°)。
   */
  private static rotationAngleDeg(q: QuaternionValue): number {
    return quaternionRotationAngleDeg(q);
  }

  /**
   * 获取四元数的欧拉角 X 分量(度)。
   * 用于诊断 UpperArm 是否仍为 T Pose(X 应接近 ±90°)。
   */
  private static eulerXDeg(q: QuaternionValue): number {
    const euler: number[] = quaternionToEulerDeg(q);
    return euler[0];
  }

  // ========== 测试用例 ==========

  /**
   * 测试 1:Identity Delta
   *
   * 构造 sourceAnimatedRotation == sourceRestRotation 的场景,
   * 断言:
   * - sourceDelta == Identity(sourceDeltaAngleDeg ≈ 0)
   * - targetAnimatedRotation == targetRestRotation
   * - Target 为 T Pose 时,UpperArm 仍为 T Pose(不变为下垂)
   */
  private static test01_IdentityDelta(): TestResult {
    const testName: string = 'test01_IdentityDelta';

    // Source: Arms-Down
    const sourceRest: HumanoidRestPose = RetargetInvariantTest.buildArmsDownRestPose();
    // Target: T Pose
    const targetRest: HumanoidRestPose = RetargetInvariantTest.buildTPoseRestPose();
    // Source Pose: 与 Source Rest 相同(Identity Delta)
    const sourcePose: HumanoidPose = RetargetInvariantTest.buildIdentityDeltaPose(sourceRest);

    // 计算 source world rest map
    const sourceWorldRestMap = computeWorldRestRotations(sourceRest);

    // 执行重定向
    const result: RetargetResult = retargetPose(
      sourcePose,
      sourceRest,
      targetRest,
      sourceWorldRestMap,
      RootMotionMode.HipsOnly,
      null
    );

    // 断言 1:所有有动画的骨骼的 sourceDeltaAngleDeg ≈ 0
    let deltaOk: boolean = true;
    let deltaMsg: string = '';
    for (let i: number = 0; i < result.axisCorrectionStats.length; i++) {
      const stat: AxisCorrectionStat = result.axisCorrectionStats[i];
      if (stat.sourceDeltaAngleDeg > 0.01) {
        deltaOk = false;
        deltaMsg = 'bone ' + stat.bone + ' sourceDeltaAngleDeg='
          + stat.sourceDeltaAngleDeg.toFixed(3) + ' (expected ~0)';
        break;
      }
    }
    if (!deltaOk) {
      return { name: testName, passed: false, message: 'Identity Delta 断言失败: ' + deltaMsg };
    }

    // 断言 2:target UpperArm 仍为 T Pose(与 targetRest 相同)
    const leftUpperArmRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.LeftUpperArm);
    const rightUpperArmRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.RightUpperArm);
    const leftUpperArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.LeftUpperArm);
    const rightUpperArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.RightUpperArm);

    if (leftUpperArmRot === undefined || rightUpperArmRot === undefined
      || leftUpperArmRest === undefined || rightUpperArmRest === undefined) {
      return { name: testName, passed: false, message: 'UpperArm 旋转数据缺失' };
    }

    const leftMatch: boolean = quaternionEqual(leftUpperArmRot, leftUpperArmRest.localRotation, 1e-5);
    const rightMatch: boolean = quaternionEqual(rightUpperArmRot, rightUpperArmRest.localRotation, 1e-5);

    if (!leftMatch || !rightMatch) {
      const leftEuler: number = RetargetInvariantTest.eulerXDeg(leftUpperArmRot);
      const rightEuler: number = RetargetInvariantTest.eulerXDeg(rightUpperArmRot);
      const leftRestEuler: number = RetargetInvariantTest.eulerXDeg(leftUpperArmRest.localRotation);
      const rightRestEuler: number = RetargetInvariantTest.eulerXDeg(rightUpperArmRest.localRotation);
      return {
        name: testName,
        passed: false,
        message: 'UpperArm 不匹配 T Pose: leftX=' + leftEuler.toFixed(1)
          + '° (rest=' + leftRestEuler.toFixed(1) + '°)'
          + ', rightX=' + rightEuler.toFixed(1)
          + '° (rest=' + rightRestEuler.toFixed(1) + '°)'
      };
    }

    Logger.info(LOG_TAG, testName + ': PASS (Identity Delta 保持 T Pose, '
      + 'appliedBones=' + result.appliedBoneCount
      + ', changedBones=' + result.changedBoneCount + ')');
    return { name: testName, passed: true, message: 'Identity Delta 保持 T Pose' };
  }

  /**
   * 测试 2:Source Arms-Down → Target T-Pose
   *
   * Source Rest 为双臂下垂,Target Rest 为 T Pose。
   * 无动作时:
   * - Target 不得下垂
   * - UpperArm Rotation == Target Rest(X 轴 ±90°)
   */
  private static test02_SourceArmsDown_TargetTPose(): TestResult {
    const testName: string = 'test02_SourceArmsDown_TargetTPose';

    // Source: Arms-Down(UpperArm 旋转 = identity)
    const sourceRest: HumanoidRestPose = RetargetInvariantTest.buildArmsDownRestPose();
    // Target: T Pose(UpperArm 旋转 = X轴 ±90°)
    const targetRest: HumanoidRestPose = RetargetInvariantTest.buildTPoseRestPose();
    // Source Pose: 与 Source Rest 相同(无动画)
    const sourcePose: HumanoidPose = RetargetInvariantTest.buildIdentityDeltaPose(sourceRest);

    const sourceWorldRestMap = computeWorldRestRotations(sourceRest);

    const result: RetargetResult = retargetPose(
      sourcePose,
      sourceRest,
      targetRest,
      sourceWorldRestMap,
      RootMotionMode.HipsOnly,
      null
    );

    // 断言:Target UpperArm 仍为 T Pose(X 轴 ±90°)
    const leftUpperArmRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.LeftUpperArm);
    const rightUpperArmRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.RightUpperArm);
    const leftUpperArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.LeftUpperArm);
    const rightUpperArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.RightUpperArm);

    if (leftUpperArmRot === undefined || rightUpperArmRot === undefined
      || leftUpperArmRest === undefined || rightUpperArmRest === undefined) {
      return { name: testName, passed: false, message: 'UpperArm 旋转数据缺失' };
    }

    // 检查 UpperArm 旋转角度接近 90°(T Pose 标志)
    const leftAngle: number = RetargetInvariantTest.rotationAngleDeg(leftUpperArmRot);
    const rightAngle: number = RetargetInvariantTest.rotationAngleDeg(rightUpperArmRot);
    const leftRestAngle: number = RetargetInvariantTest.rotationAngleDeg(leftUpperArmRest.localRotation);
    const rightRestAngle: number = RetargetInvariantTest.rotationAngleDeg(rightUpperArmRest.localRotation);

    // 上臂旋转角度应接近 90°(T Pose),不得接近 0°(下垂)
    if (leftAngle < 80.0 || rightAngle < 80.0) {
      return {
        name: testName,
        passed: false,
        message: 'UpperArm 角度过小(疑似下垂): left=' + leftAngle.toFixed(1)
          + '°, right=' + rightAngle.toFixed(1) + '° (expected ~90°)'
      };
    }

    // 检查 targetAnimatedRotation == targetRestRotation
    const leftMatch: boolean = quaternionEqual(leftUpperArmRot, leftUpperArmRest.localRotation, 1e-5);
    const rightMatch: boolean = quaternionEqual(rightUpperArmRot, rightUpperArmRest.localRotation, 1e-5);

    if (!leftMatch || !rightMatch) {
      return {
        name: testName,
        passed: false,
        message: 'UpperArm 不匹配 Target Rest: leftMatch=' + leftMatch
          + ', rightMatch=' + rightMatch
          + ', leftAngle=' + leftAngle.toFixed(1) + '° (rest=' + leftRestAngle.toFixed(1) + '°)'
          + ', rightAngle=' + rightAngle.toFixed(1) + '° (rest=' + rightRestAngle.toFixed(1) + '°)'
      };
    }

    Logger.info(LOG_TAG, testName + ': PASS (Source Arms-Down → Target T-Pose 保持, '
      + 'leftAngle=' + leftAngle.toFixed(1) + '°, rightAngle=' + rightAngle.toFixed(1) + '°)');
    return {
      name: testName,
      passed: true,
      message: 'Source Arms-Down → Target T-Pose 保持 (left=' + leftAngle.toFixed(1)
        + '°, right=' + rightAngle.toFixed(1) + '°)'
    };
  }

  /**
   * 测试 3:RightLowerArm 单侧动作
   *
   * 只旋转 Source RightLowerArm(绕 X 轴 -45°,模拟前臂弯曲)。
   * 断言:
   * - Target RightUpperArm 继续 based on T Pose(不变)
   * - Target RightLowerArm 产生动作(变化)
   * - Left Arm 不变化
   * - 不出现整个手臂被拉回双臂下垂姿态
   */
  private static test03_RightLowerArmSingleBoneMotion(): TestResult {
    const testName: string = 'test03_RightLowerArmSingleBoneMotion';

    // Source: Arms-Down
    const sourceRest: HumanoidRestPose = RetargetInvariantTest.buildArmsDownRestPose();
    // Target: T Pose
    const targetRest: HumanoidRestPose = RetargetInvariantTest.buildTPoseRestPose();

    // Source Pose:仅 RightLowerArm 旋转(绕 X 轴 -45°)
    const bendRotation: QuaternionValue = RetargetInvariantTest.lowerArmBendRotation();
    const sourcePose: HumanoidPose = RetargetInvariantTest.buildSingleBoneMotionPose(sourceRest, bendRotation);

    const sourceWorldRestMap = computeWorldRestRotations(sourceRest);

    const result: RetargetResult = retargetPose(
      sourcePose,
      sourceRest,
      targetRest,
      sourceWorldRestMap,
      RootMotionMode.HipsOnly,
      null
    );

    // 断言 1:Target RightUpperArm 仍为 T Pose(不变)
    const rightUpperArmRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.RightUpperArm);
    const rightUpperArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.RightUpperArm);
    if (rightUpperArmRot === undefined || rightUpperArmRest === undefined) {
      return { name: testName, passed: false, message: 'RightUpperArm 数据缺失' };
    }
    const ruaMatch: boolean = quaternionEqual(rightUpperArmRot, rightUpperArmRest.localRotation, 1e-5);
    const ruaAngle: number = RetargetInvariantTest.rotationAngleDeg(rightUpperArmRot);
    if (!ruaMatch) {
      return {
        name: testName,
        passed: false,
        message: 'RightUpperArm 应保持 T Pose 不变: angle=' + ruaAngle.toFixed(1)
          + '° (expected ~90°)'
      };
    }

    // 断言 2:Target RightLowerArm 产生变化(不等于 Rest)
    const rightLowerArmRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.RightLowerArm);
    const rightLowerArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.RightLowerArm);
    if (rightLowerArmRot === undefined || rightLowerArmRest === undefined) {
      return { name: testName, passed: false, message: 'RightLowerArm 数据缺失' };
    }
    const rlaChanged: boolean = !quaternionEqual(rightLowerArmRot, rightLowerArmRest.localRotation, 1e-5);
    const rlaAngle: number = RetargetInvariantTest.rotationAngleDeg(rightLowerArmRot);
    if (!rlaChanged) {
      return {
        name: testName,
        passed: false,
        message: 'RightLowerArm 应产生弯曲动作,但旋转角度未变化: angle=' + rlaAngle.toFixed(1) + '°'
      };
    }

    // 断言 3:Left UpperArm / Left LowerArm 不变化(仍为 T Pose Rest)
    const leftUpperArmRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.LeftUpperArm);
    const leftLowerArmRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.LeftLowerArm);
    const leftUpperArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.LeftUpperArm);
    const leftLowerArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.LeftLowerArm);
    if (leftUpperArmRot === undefined || leftLowerArmRot === undefined
      || leftUpperArmRest === undefined || leftLowerArmRest === undefined) {
      return { name: testName, passed: false, message: 'Left Arm 数据缺失' };
    }
    const luaMatch: boolean = quaternionEqual(leftUpperArmRot, leftUpperArmRest.localRotation, 1e-5);
    const llaMatch: boolean = quaternionEqual(leftLowerArmRot, leftLowerArmRest.localRotation, 1e-5);
    if (!luaMatch || !llaMatch) {
      return {
        name: testName,
        passed: false,
        message: 'Left Arm 应保持不变: luaMatch=' + luaMatch + ', llaMatch=' + llaMatch
      };
    }

    Logger.info(LOG_TAG, testName + ': PASS (RightLowerArm 单侧动作, '
      + 'RUA angle=' + ruaAngle.toFixed(1) + '° (T Pose), '
      + 'RLA angle=' + rlaAngle.toFixed(1) + '° (changed), '
      + 'Left Arm unchanged)');
    return {
      name: testName,
      passed: true,
      message: 'RightLowerArm 单侧动作: RUA=' + ruaAngle.toFixed(1)
        + '°, RLA=' + rlaAngle.toFixed(1) + '°, Left unchanged'
    };
  }

  /**
   * 测试 4:T Pose 连续应用 Identity Delta 不漂移
   *
   * 连续 10 次应用 Identity Delta(模拟循环播放空动作)。
   * 断言:
   * - UpperArm 不逐次下垂
   * - Quaternion 不累积
   * - 停止后仍精确恢复 T Pose
   */
  private static test04_TPoseNoDrift(): TestResult {
    const testName: string = 'test04_TPoseNoDrift';

    // Source: Arms-Down
    const sourceRest: HumanoidRestPose = RetargetInvariantTest.buildArmsDownRestPose();
    // Target: T Pose
    const targetRest: HumanoidRestPose = RetargetInvariantTest.buildTPoseRestPose();
    // Source Pose:Identity Delta
    const sourcePose: HumanoidPose = RetargetInvariantTest.buildIdentityDeltaPose(sourceRest);

    const sourceWorldRestMap = computeWorldRestRotations(sourceRest);

    // 记录初始 UpperArm Rest 旋转(作为基准)
    const leftUpperArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.LeftUpperArm);
    const rightUpperArmRest: BoneRestTransform | undefined = targetRest.bones.get(HumanoidBone.RightUpperArm);
    if (leftUpperArmRest === undefined || rightUpperArmRest === undefined) {
      return { name: testName, passed: false, message: 'UpperArm Rest 数据缺失' };
    }
    const leftRestAngle: number = RetargetInvariantTest.rotationAngleDeg(leftUpperArmRest.localRotation);
    const rightRestAngle: number = RetargetInvariantTest.rotationAngleDeg(rightUpperArmRest.localRotation);

    // 连续 10 次应用 Identity Delta
    const ITERATIONS: number = 10;
    let lastLeftRot: QuaternionValue = leftUpperArmRest.localRotation;
    let lastRightRot: QuaternionValue = rightUpperArmRest.localRotation;
    for (let i: number = 0; i < ITERATIONS; i++) {
      const result: RetargetResult = retargetPose(
        sourcePose,
        sourceRest,
        targetRest,
        sourceWorldRestMap,
        RootMotionMode.HipsOnly,
        null
      );
      const leftRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.LeftUpperArm);
      const rightRot: QuaternionValue | undefined = result.rotations.get(HumanoidBone.RightUpperArm);
      if (leftRot === undefined || rightRot === undefined) {
        return { name: testName, passed: false, message: '迭代 ' + i + ' UpperArm 数据缺失' };
      }
      // 检查是否累积漂移(每次结果应与 Rest 相同,也与上次相同)
      const leftMatchRest: boolean = quaternionEqual(leftRot, leftUpperArmRest.localRotation, 1e-5);
      const rightMatchRest: boolean = quaternionEqual(rightRot, rightUpperArmRest.localRotation, 1e-5);
      const leftMatchPrev: boolean = quaternionEqual(leftRot, lastLeftRot, 1e-5);
      const rightMatchPrev: boolean = quaternionEqual(rightRot, lastRightRot, 1e-5);
      if (!leftMatchRest || !rightMatchRest || !leftMatchPrev || !rightMatchPrev) {
        const leftAngle: number = RetargetInvariantTest.rotationAngleDeg(leftRot);
        const rightAngle: number = RetargetInvariantTest.rotationAngleDeg(rightRot);
        return {
          name: testName,
          passed: false,
          message: '迭代 ' + i + ' 漂移: left=' + leftAngle.toFixed(3)
            + '° (rest=' + leftRestAngle.toFixed(3) + '°)'
            + ', right=' + rightAngle.toFixed(3)
            + '° (rest=' + rightRestAngle.toFixed(3) + '°)'
            + ', matchRest(L/R)= ' + leftMatchRest + '/' + rightMatchRest
            + ', matchPrev(L/R)= ' + leftMatchPrev + '/' + rightMatchPrev
        };
      }
      lastLeftRot = leftRot;
      lastRightRot = rightRot;
    }

    // 最终检查:仍精确恢复 T Pose
    const finalLeftMatch: boolean = quaternionEqual(lastLeftRot, leftUpperArmRest.localRotation, 1e-5);
    const finalRightMatch: boolean = quaternionEqual(lastRightRot, rightUpperArmRest.localRotation, 1e-5);
    if (!finalLeftMatch || !finalRightMatch) {
      return {
        name: testName,
        passed: false,
        message: '连续 ' + ITERATIONS + ' 次后未恢复 T Pose: '
          + 'leftMatch=' + finalLeftMatch + ', rightMatch=' + finalRightMatch
      };
    }

    Logger.info(LOG_TAG, testName + ': PASS (' + ITERATIONS + ' 次 Identity Delta 无漂移, '
      + 'left=' + RetargetInvariantTest.rotationAngleDeg(lastLeftRot).toFixed(3)
      + '°, right=' + RetargetInvariantTest.rotationAngleDeg(lastRightRot).toFixed(3) + '°)');
    return {
      name: testName,
      passed: true,
      message: ITERATIONS + ' 次 Identity Delta 无漂移, UpperArm 仍为 T Pose'
    };
  }
}
