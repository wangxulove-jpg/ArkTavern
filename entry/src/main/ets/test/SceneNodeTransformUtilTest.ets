/**
 * SceneNodeTransformUtilTest 向量与旋转数学单元测试
 *
 * T-4.2G-A2: 验证 SceneNodeTransformUtil 中的纯数学函数。
 *
 * 注意:computeNodeWorldTransform 依赖 ArkGraphics3D 的 Node 类,
 *      无法在 host 单元测试中运行,本测试只覆盖纯数学函数。
 *
 * 测试项(共 10 项):
 *  1. vectorSubtract / vectorAdd / vectorScale 基础运算
 *  2. vectorDot / vectorCross 点积叉积
 *  3. vectorLength / vectorNormalize 归一化
 *  4. vectorNormalize 零向量保护
 *  5. rotateVectorByQuaternion:Identity 不改变向量
 *  6. rotateVectorByQuaternion:绕 Y 轴 90° 旋转 X 轴
 *  7. rotateVectorByQuaternion:绕 Z 轴 180° 翻转 Y 轴
 *  8. rotationFromYAxisToDirection:同向返回 Identity
 *  9. rotationFromYAxisToDirection:反向返回 Z 轴 180°
 * 10. rotationFromYAxisToDirection:任意方向正确旋转
 *
 * 不依赖 ArkUI / ArkGraphics3D / 文件系统,可独立运行。
 */

import { Logger } from '../utils/Logger';
import { Vector3Value, QuaternionValue } from '../models/character3d/HumanoidMotionClip';
import {
  vectorSubtract,
  vectorAdd,
  vectorScale,
  vectorDot,
  vectorCross,
  vectorLength,
  vectorNormalize,
  rotateVectorByQuaternion,
  rotationFromYAxisToDirection
} from '../utils/SceneNodeTransformUtil';
import { quaternionIdentity } from '../utils/QuaternionUtil';

const LOG_TAG: string = 'SceneNodeTransformUtilTest';

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

/** 浮点比较容差 */
const EPS: number = 1e-5;

/**
 * 测试入口。
 */
export class SceneNodeTransformUtilTest {
  static runAllTests(): TestSuiteResult {
    const results: TestResult[] = [];
    results.push(SceneNodeTransformUtilTest.test01_BasicVectorOps());
    results.push(SceneNodeTransformUtilTest.test02_DotAndCross());
    results.push(SceneNodeTransformUtilTest.test03_LengthAndNormalize());
    results.push(SceneNodeTransformUtilTest.test04_NormalizeZeroVector());
    results.push(SceneNodeTransformUtilTest.test05_RotateByIdentity());
    results.push(SceneNodeTransformUtilTest.test06_RotateY90_XtoZ());
    results.push(SceneNodeTransformUtilTest.test07_RotateZ180_FlipY());
    results.push(SceneNodeTransformUtilTest.test08_RotationFromY_SameDirection());
    results.push(SceneNodeTransformUtilTest.test09_RotationFromY_OppositeDirection());
    results.push(SceneNodeTransformUtilTest.test10_RotationFromY_ArbitraryDirection());

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
    Logger.info(LOG_TAG, '==== SceneNodeTransformUtil Test Suite: '
      + passed + '/' + results.length + ' passed, ' + failed + ' failed ====');
    return suite;
  }

  // ========== 辅助 ==========

  private static approxEqual(a: number, b: number, eps: number = EPS): boolean {
    return Math.abs(a - b) < eps;
  }

  private static vectorApproxEqual(a: Vector3Value, b: Vector3Value, eps: number = EPS): boolean {
    return SceneNodeTransformUtilTest.approxEqual(a.x, b.x, eps)
      && SceneNodeTransformUtilTest.approxEqual(a.y, b.y, eps)
      && SceneNodeTransformUtilTest.approxEqual(a.z, b.z, eps);
  }

  private static quaternionApproxEqual(a: QuaternionValue, b: QuaternionValue, eps: number = EPS): boolean {
    return SceneNodeTransformUtilTest.approxEqual(a.x, b.x, eps)
      && SceneNodeTransformUtilTest.approxEqual(a.y, b.y, eps)
      && SceneNodeTransformUtilTest.approxEqual(a.z, b.z, eps)
      && SceneNodeTransformUtilTest.approxEqual(a.w, b.w, eps);
  }

  // ========== 测试用例 ==========

  /**
   * 测试 1:基础向量运算(subtract/add/scale)
   */
  private static test01_BasicVectorOps(): TestResult {
    const testName: string = 'test01_BasicVectorOps';
    const a: Vector3Value = { x: 1, y: 2, z: 3 };
    const b: Vector3Value = { x: 4, y: 5, z: 6 };

    const sub: Vector3Value = vectorSubtract(a, b);
    const add: Vector3Value = vectorAdd(a, b);
    const scaled: Vector3Value = vectorScale(a, 2.0);

    const subOk: boolean = SceneNodeTransformUtilTest.vectorApproxEqual(sub, { x: -3, y: -3, z: -3 });
    const addOk: boolean = SceneNodeTransformUtilTest.vectorApproxEqual(add, { x: 5, y: 7, z: 9 });
    const scaleOk: boolean = SceneNodeTransformUtilTest.vectorApproxEqual(scaled, { x: 2, y: 4, z: 6 });

    if (!subOk || !addOk || !scaleOk) {
      return {
        name: testName,
        passed: false,
        message: '基础运算错误: sub=(' + sub.x + ',' + sub.y + ',' + sub.z
          + '), add=(' + add.x + ',' + add.y + ',' + add.z
          + '), scaled=(' + scaled.x + ',' + scaled.y + ',' + scaled.z + ')'
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS');
    return { name: testName, passed: true, message: '基础向量运算正确' };
  }

  /**
   * 测试 2:点积与叉积
   */
  private static test02_DotAndCross(): TestResult {
    const testName: string = 'test02_DotAndCross';
    const a: Vector3Value = { x: 1, y: 0, z: 0 };
    const b: Vector3Value = { x: 0, y: 1, z: 0 };

    const dot: number = vectorDot(a, b); // 期望 0
    const cross: Vector3Value = vectorCross(a, b); // 期望 (0, 0, 1)

    const dotOk: boolean = SceneNodeTransformUtilTest.approxEqual(dot, 0.0);
    const crossOk: boolean = SceneNodeTransformUtilTest.vectorApproxEqual(cross, { x: 0, y: 0, z: 1 });

    if (!dotOk || !crossOk) {
      return {
        name: testName,
        passed: false,
        message: '点积/叉积错误: dot=' + dot
          + ', cross=(' + cross.x + ',' + cross.y + ',' + cross.z + ')'
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS');
    return { name: testName, passed: true, message: '点积叉积正确' };
  }

  /**
   * 测试 3:长度与归一化
   */
  private static test03_LengthAndNormalize(): TestResult {
    const testName: string = 'test03_LengthAndNormalize';
    const v: Vector3Value = { x: 3, y: 4, z: 0 };
    const len: number = vectorLength(v); // 期望 5
    const n: Vector3Value = vectorNormalize(v); // 期望 (0.6, 0.8, 0)

    const lenOk: boolean = SceneNodeTransformUtilTest.approxEqual(len, 5.0);
    const nOk: boolean = SceneNodeTransformUtilTest.vectorApproxEqual(n, { x: 0.6, y: 0.8, z: 0 });
    const nLen: number = vectorLength(n);
    const nLenOk: boolean = SceneNodeTransformUtilTest.approxEqual(nLen, 1.0);

    if (!lenOk || !nOk || !nLenOk) {
      return {
        name: testName,
        passed: false,
        message: '长度/归一化错误: len=' + len
          + ', n=(' + n.x + ',' + n.y + ',' + n.z
          + '), nLen=' + nLen
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS');
    return { name: testName, passed: true, message: '长度归一化正确' };
  }

  /**
   * 测试 4:零向量归一化保护
   */
  private static test04_NormalizeZeroVector(): TestResult {
    const testName: string = 'test04_NormalizeZeroVector';
    const zero: Vector3Value = { x: 0, y: 0, z: 0 };
    const n: Vector3Value = vectorNormalize(zero);

    const ok: boolean = SceneNodeTransformUtilTest.vectorApproxEqual(n, { x: 0, y: 0, z: 0 });
    if (!ok) {
      return {
        name: testName,
        passed: false,
        message: '零向量归一化应返回零向量: n=(' + n.x + ',' + n.y + ',' + n.z + ')'
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS');
    return { name: testName, passed: true, message: '零向量保护正确' };
  }

  /**
   * 测试 5:Identity 四元数旋转不改变向量
   */
  private static test05_RotateByIdentity(): TestResult {
    const testName: string = 'test05_RotateByIdentity';
    const v: Vector3Value = { x: 1, y: 2, z: 3 };
    const q: QuaternionValue = quaternionIdentity();
    const r: Vector3Value = rotateVectorByQuaternion(v, q);

    const ok: boolean = SceneNodeTransformUtilTest.vectorApproxEqual(r, v);
    if (!ok) {
      return {
        name: testName,
        passed: false,
        message: 'Identity 旋转应不变: r=(' + r.x + ',' + r.y + ',' + r.z + ')'
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS');
    return { name: testName, passed: true, message: 'Identity 旋转正确' };
  }

  /**
   * 测试 6:绕 Y 轴 90° 旋转 X 轴 → Z 轴
   *
   * q = (0, sin(45°), 0, cos(45°)) = (0, 0.7071, 0, 0.7071)
   * v = (1, 0, 0)
   * 期望 r ≈ (0, 0, -1)
   *
   * 注:右手坐标系,Y 轴 90° 旋转 X 轴到 -Z 方向。
   */
  private static test06_RotateY90_XtoZ(): TestResult {
    const testName: string = 'test06_RotateY90_XtoZ';
    const halfRad: number = (90.0 * Math.PI / 180.0) / 2.0;
    const sinV: number = Math.sin(halfRad);
    const cosV: number = Math.cos(halfRad);
    const q: QuaternionValue = { x: 0, y: sinV, z: 0, w: cosV };
    const v: Vector3Value = { x: 1, y: 0, z: 0 };
    const r: Vector3Value = rotateVectorByQuaternion(v, q);

    const ok: boolean = SceneNodeTransformUtilTest.vectorApproxEqual(r, { x: 0, y: 0, z: -1 });
    if (!ok) {
      return {
        name: testName,
        passed: false,
        message: 'Y90° 旋转 X 轴错误: r=(' + r.x + ',' + r.y + ',' + r.z + ')'
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS (X→-Z)');
    return { name: testName, passed: true, message: 'Y 轴 90° 旋转正确' };
  }

  /**
   * 测试 7:绕 Z 轴 180° 翻转 Y 轴
   *
   * q = (0, 0, sin(90°), cos(90°)) = (0, 0, 1, 0)
   * v = (0, 1, 0)
   * 期望 r ≈ (0, -1, 0)
   */
  private static test07_RotateZ180_FlipY(): TestResult {
    const testName: string = 'test07_RotateZ180_FlipY';
    const q: QuaternionValue = { x: 0, y: 0, z: 1, w: 0 };
    const v: Vector3Value = { x: 0, y: 1, z: 0 };
    const r: Vector3Value = rotateVectorByQuaternion(v, q);

    const ok: boolean = SceneNodeTransformUtilTest.vectorApproxEqual(r, { x: 0, y: -1, z: 0 });
    if (!ok) {
      return {
        name: testName,
        passed: false,
        message: 'Z180° 翻转 Y 轴错误: r=(' + r.x + ',' + r.y + ',' + r.z + ')'
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS (Y→-Y)');
    return { name: testName, passed: true, message: 'Z 轴 180° 旋转正确' };
  }

  /**
   * 测试 8:rotationFromYAxisToDirection - 同向返回 Identity
   */
  private static test08_RotationFromY_SameDirection(): TestResult {
    const testName: string = 'test08_RotationFromY_SameDirection';
    const dir: Vector3Value = { x: 0, y: 1, z: 0 };
    const q: QuaternionValue = rotationFromYAxisToDirection(dir);
    const expected: QuaternionValue = quaternionIdentity();

    const ok: boolean = SceneNodeTransformUtilTest.quaternionApproxEqual(q, expected);
    if (!ok) {
      return {
        name: testName,
        passed: false,
        message: '同向应返回 Identity: q=(' + q.x + ',' + q.y + ',' + q.z + ',' + q.w + ')'
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS');
    return { name: testName, passed: true, message: '同向返回 Identity 正确' };
  }

  /**
   * 测试 9:rotationFromYAxisToDirection - 反向返回 Z 轴 180°
   */
  private static test09_RotationFromY_OppositeDirection(): TestResult {
    const testName: string = 'test09_RotationFromY_OppositeDirection';
    const dir: Vector3Value = { x: 0, y: -1, z: 0 };
    const q: QuaternionValue = rotationFromYAxisToDirection(dir);
    const expected: QuaternionValue = { x: 0, y: 0, z: 1, w: 0 };

    const ok: boolean = SceneNodeTransformUtilTest.quaternionApproxEqual(q, expected);
    if (!ok) {
      return {
        name: testName,
        passed: false,
        message: '反向应返回 (0,0,1,0): q=(' + q.x + ',' + q.y + ',' + q.z + ',' + q.w + ')'
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS');
    return { name: testName, passed: true, message: '反向返回 Z 轴 180° 正确' };
  }

  /**
   * 测试 10:rotationFromYAxisToDirection - 任意方向正确旋转
   *
   * 将 +Y 旋转到 +X 方向,期望:
   * - 旋转轴 = Y × X = (0,0,-1)
   * - 旋转角 = 90°
   * - q = (0, 0, -sin(45°), cos(45°)) = (0, 0, -0.7071, 0.7071)
   */
  private static test10_RotationFromY_ArbitraryDirection(): TestResult {
    const testName: string = 'test10_RotationFromY_ArbitraryDirection';
    const dir: Vector3Value = { x: 1, y: 0, z: 0 };
    const q: QuaternionValue = rotationFromYAxisToDirection(dir);
    const halfRad: number = (90.0 * Math.PI / 180.0) / 2.0;
    const sinV: number = Math.sin(halfRad);
    const cosV: number = Math.cos(halfRad);
    const expected: QuaternionValue = { x: 0, y: 0, z: -sinV, w: cosV };

    const ok: boolean = SceneNodeTransformUtilTest.quaternionApproxEqual(q, expected);
    if (!ok) {
      return {
        name: testName,
        passed: false,
        message: 'Y→X 旋转错误: q=(' + q.x + ',' + q.y + ',' + q.z + ',' + q.w
          + '), expected=(' + expected.x + ',' + expected.y + ',' + expected.z + ',' + expected.w + ')'
      };
    }
    Logger.info(LOG_TAG, testName + ': PASS (Y→X via Z-)');
    return { name: testName, passed: true, message: '任意方向旋转正确' };
  }
}
