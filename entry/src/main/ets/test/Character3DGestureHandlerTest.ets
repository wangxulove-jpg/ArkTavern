/**
 * Character3DGestureHandlerTest 手势状态机模拟 pointer 单元测试
 *
 * 临时开发测试: T-3D.5D PoC 与聊天页 3D 手势统一及大倍率缩放
 *
 * 职责:
 * - 对 Character3DGestureHandler 做模拟 pointer 序列断言测试
 * - 不依赖 ArkUI UITest 真实多指能力,使用程序构造 TouchPointData[]
 * - 覆盖:单指旋转 / 双指缩放 / 最大倍率 / 累计缩放 / 最小倍率 /
 *   双指平移 / 高倍率平移 / 模式互斥 / 双指转单指 / Cancel / 非法值 /
 *   PoC 与聊天页一致性
 * - 通过 Logger 输出测试结果,供开发期验证
 *
 * 工程环境说明:
 * - 工程 无 ohosTest 目录(Test Runner 环境限制)
 * - 本文件作为纯逻辑测试保留,供未来集成测试框架使用
 * - 调用 Character3DGestureHandlerTest.runAllTests() 可执行全部测试
 *
 * 测试项(共 14 项):
 * 1. 单指旋转
 * 2. 双指放大
 * 3. 达到最大倍率(20.0)
 * 4. 连续多次放大(累计 1→4→12→20)
 * 5. 最小倍率(0.10)
 * 6. 双指平移
 * 7. 高倍率平移(zoom=10)
 * 8. 模式互斥(先缩放后平移)
 * 9. 模式互斥(先平移后缩放)
 * 10. 双指转单指抑制
 * 11. Cancel(SingleRotate 状态)
 * 12. Cancel(TwoFingerScale 状态)
 * 13. 非法值(viewport=0 / NaN / Infinity / 重复 ID)
 * 14. PoC 与聊天页一致性(相同输入相同输出)
 */

import { Logger } from '../utils/Logger';
import {
  Character3DGestureHandler,
  GestureState,
  TouchPhase,
  TouchPointData,
  GestureCallbacks,
  GestureConfigSnapshot
} from '../models/character3d/Character3DGestureHandler';
import {
  VIEWER_ZOOM_FACTOR_MIN,
  VIEWER_ZOOM_FACTOR_MAX,
  VIEWER_ZOOM_FACTOR_DEFAULT
} from '../models/character3d/Character3DDisplayConfig';

const LOG_TAG: string = 'GestureTest';

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

/** 测试用视口宽高 */
const TEST_VIEWPORT_W: number = 1000;
const TEST_VIEWPORT_H: number = 1000;
const TEST_CAMERA_DIST: number = 5.0;

/**
 * 手势输出捕获器:收集 GestureCallbacks 的所有输出。
 * 用于断言手势处理结果。
 */
class GestureOutputCapture {
  yawAccum: number = 0;
  pitchAccum: number = 0;
  zoomFactor: number = VIEWER_ZOOM_FACTOR_DEFAULT;
  offsetX: number = 0;
  offsetY: number = 0;
  gestureEndCount: number = 0;

  reset(): void {
    this.yawAccum = 0;
    this.pitchAccum = 0;
    this.zoomFactor = VIEWER_ZOOM_FACTOR_DEFAULT;
    this.offsetX = 0;
    this.offsetY = 0;
    this.gestureEndCount = 0;
  }

  asCallbacks(): GestureCallbacks {
    return {
      onRotate: (deltaYawDeg: number, deltaPitchDeg: number): void => {
        this.yawAccum += deltaYawDeg;
        this.pitchAccum += deltaPitchDeg;
      },
      onSetOffset: (offsetX: number, offsetY: number): void => {
        this.offsetX = offsetX;
        this.offsetY = offsetY;
      },
      onSetZoomFactor: (zoomFactor: number): void => {
        this.zoomFactor = zoomFactor;
      },
      onGestureEnd: (): void => {
        this.gestureEndCount++;
      }
    };
  }

  asConfig(): GestureConfigSnapshot {
    return {
      zoomFactor: this.zoomFactor,
      offsetX: this.offsetX,
      offsetY: this.offsetY
    };
  }
}

/**
 * 手势测试台:封装 handler + capture + activePointers 管理。
 * 提供 down/move/up/cancel 便捷方法,自动维护 activePointers 列表。
 */
class GestureTestRig {
  handler: Character3DGestureHandler;
  capture: GestureOutputCapture;
  private activePointers: TouchPointData[] = [];

  constructor() {
    this.handler = new Character3DGestureHandler();
    this.capture = new GestureOutputCapture();
    this.handler.setCallbacks(this.capture.asCallbacks());
    this.handler.setViewport(TEST_VIEWPORT_W, TEST_VIEWPORT_H);
    this.handler.setCameraDistance(TEST_CAMERA_DIST);
  }

  /** 模拟手指按下 */
  down(p: TouchPointData): void {
    this.activePointers.push(p);
    this.handler.handleTouch(TouchPhase.Down, this.activePointers.slice(), p.id, this.capture.asConfig());
  }

  /** 模拟手指移动(更新指定 id 的位置) */
  move(updates: TouchPointData[]): void {
    // 更新 activePointers 中对应 id 的位置
    for (let i = 0; i < updates.length; i++) {
      const u: TouchPointData = updates[i];
      for (let j = 0; j < this.activePointers.length; j++) {
        if (this.activePointers[j].id === u.id) {
          this.activePointers[j] = u;
          break;
        }
      }
    }
    this.handler.handleTouch(TouchPhase.Move, this.activePointers.slice(), -1, this.capture.asConfig());
  }

  /** 模拟手指抬起 */
  up(id: number): void {
    // 从 activePointers 中移除
    for (let i = 0; i < this.activePointers.length; i++) {
      if (this.activePointers[i].id === id) {
        this.activePointers.splice(i, 1);
        break;
      }
    }
    this.handler.handleTouch(TouchPhase.Up, this.activePointers.slice(), id, this.capture.asConfig());
  }

  /** 模拟触摸取消 */
  cancel(): void {
    this.activePointers = [];
    this.handler.handleTouch(TouchPhase.Cancel, [], -1, this.capture.asConfig());
  }

  /** 设置初始 zoomFactor(用于高倍率测试) */
  setZoomFactor(zf: number): void {
    this.capture.zoomFactor = zf;
    this.handler.updateCurrentConfig(this.capture.asConfig());
  }

  /** 重置(保留 handler 实例,清空状态) */
  resetState(): void {
    this.activePointers = [];
    this.capture.reset();
  }

  getState(): GestureState {
    return this.handler.getState();
  }

  getZoomFactor(): number {
    return this.handler.getZoomFactor();
  }
}

/**
 * 浮点近似比较(允许 1e-4 误差)。
 */
function approxEqual(a: number, b: number, eps: number = 1e-4): boolean {
  return Math.abs(a - b) < eps;
}

export class Character3DGestureHandlerTest {
  /**
   * 运行全部 14 项测试,返回汇总结果并输出日志。
   */
  static runAllTests(): TestSuiteResult {
    const results: TestResult[] = [];
    results.push(Character3DGestureHandlerTest.test01_SingleRotate());
    results.push(Character3DGestureHandlerTest.test02_TwoFingerScale());
    results.push(Character3DGestureHandlerTest.test03_MaxZoomFactor());
    results.push(Character3DGestureHandlerTest.test04_CumulativeZoom());
    results.push(Character3DGestureHandlerTest.test05_MinZoomFactor());
    results.push(Character3DGestureHandlerTest.test06_TwoFingerTranslate());
    results.push(Character3DGestureHandlerTest.test07_HighZoomTranslate());
    results.push(Character3DGestureHandlerTest.test08_ModeMutexScaleFirst());
    results.push(Character3DGestureHandlerTest.test09_ModeMutexTranslateFirst());
    results.push(Character3DGestureHandlerTest.test10_TwoFingerToSingleSuppress());
    results.push(Character3DGestureHandlerTest.test11_CancelSingleRotate());
    results.push(Character3DGestureHandlerTest.test12_CancelTwoFingerScale());
    results.push(Character3DGestureHandlerTest.test13_InvalidValues());
    results.push(Character3DGestureHandlerTest.test14_PageConsistency());

    let passed: number = 0;
    let failed: number = 0;
    for (const r of results) {
      if (r.passed) {
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
    Logger.info(LOG_TAG, '==== Gesture Test Suite Done: ' + passed + '/' + results.length
      + ' passed, ' + failed + ' failed ====');
    return suite;
  }

  /** 1. 单指旋转:Down → Move(dx>0, dy>0) → Up */
  private static test01_SingleRotate(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 500, y: 500 });
    rig.move([{ id: 1, x: 560, y: 540 }]); // dx=60, dy=40
    const stateAfterMove: GestureState = rig.getState();
    const yawAfterMove: number = rig.capture.yawAccum;
    const pitchAfterMove: number = rig.capture.pitchAccum;
    rig.up(1);
    const stateAfterUp: GestureState = rig.getState();
    const ok: boolean = stateAfterMove === GestureState.SingleRotate
      && yawAfterMove > 0
      && pitchAfterMove > 0
      && stateAfterUp === GestureState.Idle;
    return Character3DGestureHandlerTest.buildResult('01_SingleRotate', ok,
      'yaw=' + yawAfterMove.toFixed(3) + ' pitch=' + pitchAfterMove.toFixed(3)
      + ' state=' + stateAfterMove + '→' + stateAfterUp);
  }

  /** 2. 双指放大:距离从 200 增大到 400(ratio=2.0),zoom 1.0→2.0 */
  private static test02_TwoFingerScale(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 }); // startDist=200
    rig.move([{ id: 1, x: 300, y: 500 }, { id: 2, x: 700, y: 500 }]); // dist=400, ratio=2.0
    const stateAfterMove: GestureState = rig.getState();
    const zoomAfterMove: number = rig.capture.zoomFactor;
    const offsetUnchanged: boolean = rig.capture.offsetX === 0 && rig.capture.offsetY === 0;
    rig.up(2);
    rig.up(1);
    const ok: boolean = stateAfterMove === GestureState.TwoFingerScale
      && approxEqual(zoomAfterMove, 2.0)
      && offsetUnchanged;
    return Character3DGestureHandlerTest.buildResult('02_TwoFingerScale', ok,
      'zoom=' + zoomAfterMove.toFixed(4) + ' state=' + stateAfterMove
      + ' offsetUnchanged=' + offsetUnchanged.toString());
  }

  /** 3. 达到最大倍率:足够大的距离比例,zoom 应稳定在 20.0 */
  private static test03_MaxZoomFactor(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 450, y: 500 });
    rig.down({ id: 2, x: 550, y: 500 }); // startDist=100
    // ratio = 3000/100 = 30x → targetZoom = 30, clamp to 20.0
    rig.move([{ id: 1, x: 0, y: 500 }, { id: 2, x: 3000, y: 500 }]); // dist=3000
    const zoom1: number = rig.capture.zoomFactor;
    // 继续增大距离,zoom 仍为 20.0
    rig.move([{ id: 1, x: 0, y: 500 }, { id: 2, x: 5000, y: 500 }]); // dist=5000
    const zoom2: number = rig.capture.zoomFactor;
    // 开始合拢,zoom 立即下降
    rig.move([{ id: 1, x: 400, y: 500 }, { id: 2, x: 600, y: 500 }]); // dist=200, ratio=2x → zoom=2.0
    const zoom3: number = rig.capture.zoomFactor;
    rig.up(2);
    rig.up(1);
    const ok: boolean = zoom1 === VIEWER_ZOOM_FACTOR_MAX
      && zoom2 === VIEWER_ZOOM_FACTOR_MAX
      && approxEqual(zoom3, 2.0)
      && zoom3 < VIEWER_ZOOM_FACTOR_MAX;
    return Character3DGestureHandlerTest.buildResult('03_MaxZoomFactor', ok,
      'zoom@3000=' + zoom1.toFixed(4) + ' zoom@5000=' + zoom2.toFixed(4)
      + ' zoom@200=' + zoom3.toFixed(4));
  }

  /** 4. 连续多次放大:1→4 → 4→12 → 12→20(每次手势从当前 zoom 开始) */
  private static test04_CumulativeZoom(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();

    // 第一手势:1.0 → 4.0(ratio=4x)
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 }); // startDist=200, startZoom=1.0
    rig.move([{ id: 1, x: 0, y: 500 }, { id: 2, x: 1000, y: 500 }]); // dist=1000, ratio=5x → zoom=5.0
    // 调整为 ratio=4x: dist=800
    rig.resetState();
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 }); // startDist=200
    // 先做一次 1→4
    // 使用 ratio=4: dist=800
    rig.move([{ id: 1, x: 100, y: 500 }, { id: 2, x: 900, y: 500 }]); // dist=800, ratio=4x → zoom=4.0
    const zoom1: number = rig.capture.zoomFactor;
    rig.up(2);
    rig.up(1);

    // 第二手势:4.0 → 12.0(ratio=3x)
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 }); // startDist=200, startZoom=4.0
    rig.move([{ id: 1, x: 100, y: 500 }, { id: 2, x: 900, y: 500 }]); // dist=800, ratio=4x → zoom=16.0
    // 调整为 ratio=3x: dist=600
    rig.move([{ id: 1, x: 200, y: 500 }, { id: 2, x: 800, y: 500 }]); // dist=600, ratio=3x → zoom=12.0
    const zoom2: number = rig.capture.zoomFactor;
    rig.up(2);
    rig.up(1);

    // 第三手势:12.0 → 20.0(ratio≈1.667x, clamped)
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 }); // startDist=200, startZoom=12.0
    rig.move([{ id: 1, x: 0, y: 500 }, { id: 2, x: 1000, y: 500 }]); // dist=1000, ratio=5x → target=60, clamp=20.0
    const zoom3: number = rig.capture.zoomFactor;
    rig.up(2);
    rig.up(1);

    const ok: boolean = approxEqual(zoom1, 4.0)
      && approxEqual(zoom2, 12.0)
      && zoom3 === VIEWER_ZOOM_FACTOR_MAX;
    return Character3DGestureHandlerTest.buildResult('04_CumulativeZoom', ok,
      'g1→' + zoom1.toFixed(4) + ' g2→' + zoom2.toFixed(4) + ' g3→' + zoom3.toFixed(4));
  }

  /** 5. 最小倍率:缩小到低于范围,zoom 稳定在 0.10 */
  private static test05_MinZoomFactor(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 0, y: 500 });
    rig.down({ id: 2, x: 1000, y: 500 }); // startDist=1000, startZoom=1.0
    // ratio = 10/1000 = 0.01 → targetZoom = 0.01, clamp to 0.10
    rig.move([{ id: 1, x: 495, y: 500 }, { id: 2, x: 505, y: 500 }]); // dist=10, ratio=0.01
    const zoom1: number = rig.capture.zoomFactor;
    // 继续缩小,zoom 仍为 0.10
    rig.move([{ id: 1, x: 499, y: 500 }, { id: 2, x: 501, y: 500 }]); // dist=2, ratio=0.002
    const zoom2: number = rig.capture.zoomFactor;
    // 放大时可以立即恢复
    rig.move([{ id: 1, x: 400, y: 500 }, { id: 2, x: 600, y: 500 }]); // dist=200, ratio=0.2 → zoom=0.2
    const zoom3: number = rig.capture.zoomFactor;
    rig.up(2);
    rig.up(1);
    const ok: boolean = zoom1 === VIEWER_ZOOM_FACTOR_MIN
      && zoom2 === VIEWER_ZOOM_FACTOR_MIN
      && approxEqual(zoom3, 0.2)
      && zoom3 > VIEWER_ZOOM_FACTOR_MIN;
    return Character3DGestureHandlerTest.buildResult('05_MinZoomFactor', ok,
      'zoom@10=' + zoom1.toFixed(4) + ' zoom@2=' + zoom2.toFixed(4)
      + ' zoom@200=' + zoom3.toFixed(4));
  }

  /** 6. 双指平移:距离不变,中心移动 20px(超过阈值 14px) */
  private static test06_TwoFingerTranslate(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 }); // startDist=200, startCenter=(500,500)
    // 距离不变,中心右移 20px(> 阈值 14px)
    rig.move([{ id: 1, x: 420, y: 500 }, { id: 2, x: 620, y: 500 }]); // dist=200, center=(520,500)
    const stateAfterMove: GestureState = rig.getState();
    const zoomUnchanged: boolean = approxEqual(rig.capture.zoomFactor, 1.0);
    const offsetChanged: boolean = rig.capture.offsetX !== 0 || rig.capture.offsetY !== 0;
    rig.up(2);
    rig.up(1);
    const ok: boolean = stateAfterMove === GestureState.TwoFingerTranslate
      && zoomUnchanged
      && offsetChanged;
    return Character3DGestureHandlerTest.buildResult('06_TwoFingerTranslate', ok,
      'state=' + stateAfterMove + ' zoom=' + rig.capture.zoomFactor.toFixed(4)
      + ' offsetX=' + rig.capture.offsetX.toFixed(4) + ' offsetY=' + rig.capture.offsetY.toFixed(4));
  }

  /** 7. 高倍率平移:zoom=10 时双指平移,仍可控 */
  private static test07_HighZoomTranslate(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.setZoomFactor(10.0);
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 }); // startDist=200, startZoom=10.0
    // 距离不变,中心移动 30px
    rig.move([{ id: 1, x: 430, y: 500 }, { id: 2, x: 630, y: 500 }]); // center=(530,500)
    const stateAfterMove: GestureState = rig.getState();
    const zoomStill10: boolean = approxEqual(rig.capture.zoomFactor, 10.0);
    const offsetChanged: boolean = rig.capture.offsetX !== 0;
    rig.up(2);
    rig.up(1);
    const ok: boolean = stateAfterMove === GestureState.TwoFingerTranslate
      && zoomStill10
      && offsetChanged;
    return Character3DGestureHandlerTest.buildResult('07_HighZoomTranslate', ok,
      'state=' + stateAfterMove + ' zoom=' + rig.capture.zoomFactor.toFixed(4)
      + ' offsetX=' + rig.capture.offsetX.toFixed(4));
  }

  /** 8. 模式互斥:先改变距离(锁定 scale),再移动中心,应保持 scale */
  private static test08_ModeMutexScaleFirst(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 }); // startDist=200
    // 先改变距离(ratio=1.5x > 10% 阈值 → 锁定 scale)
    rig.move([{ id: 1, x: 350, y: 500 }, { id: 2, x: 650, y: 500 }]); // dist=300, ratio=1.5
    const stateAfterScale: GestureState = rig.getState();
    // 再移动中心(距离保持不变)
    rig.move([{ id: 1, x: 370, y: 500 }, { id: 2, x: 670, y: 500 }]); // dist=300, center=(520,500)
    const stateAfterTranslateAttempt: GestureState = rig.getState();
    rig.up(2);
    rig.up(1);
    const ok: boolean = stateAfterScale === GestureState.TwoFingerScale
      && stateAfterTranslateAttempt === GestureState.TwoFingerScale;
    return Character3DGestureHandlerTest.buildResult('08_ModeMutexScaleFirst', ok,
      'afterScale=' + stateAfterScale + ' afterTranslateAttempt=' + stateAfterTranslateAttempt);
  }

  /** 9. 模式互斥:先移动中心(锁定 translate),再改变距离,应保持 translate */
  private static test09_ModeMutexTranslateFirst(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 }); // startDist=200, startCenter=(500,500)
    // 先移动中心(>14px 阈值,距离变化 <10%)
    rig.move([{ id: 1, x: 430, y: 500 }, { id: 2, x: 630, y: 500 }]); // dist=200, center=(530,500), translateMag=30
    const stateAfterTranslate: GestureState = rig.getState();
    // 再改变距离(应保持 translate)
    rig.move([{ id: 1, x: 330, y: 500 }, { id: 2, x: 730, y: 500 }]); // dist=400, ratio=2.0
    const stateAfterScaleAttempt: GestureState = rig.getState();
    const zoomUnchanged: boolean = approxEqual(rig.capture.zoomFactor, 1.0);
    rig.up(2);
    rig.up(1);
    const ok: boolean = stateAfterTranslate === GestureState.TwoFingerTranslate
      && stateAfterScaleAttempt === GestureState.TwoFingerTranslate
      && zoomUnchanged;
    return Character3DGestureHandlerTest.buildResult('09_ModeMutexTranslateFirst', ok,
      'afterTranslate=' + stateAfterTranslate + ' afterScaleAttempt=' + stateAfterScaleAttempt
      + ' zoom=' + rig.capture.zoomFactor.toFixed(4));
  }

  /** 10. 双指转单指:两指操作后抬起一指,剩余手指移动不应旋转 */
  private static test10_TwoFingerToSingleSuppress(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 });
    // 双指缩放
    rig.move([{ id: 1, x: 300, y: 500 }, { id: 2, x: 700, y: 500 }]); // zoom=2.0
    const yawBefore: number = rig.capture.yawAccum;
    // 抬起手指 2
    rig.up(2);
    // 剩余手指 1 移动,不应旋转
    rig.move([{ id: 1, x: 100, y: 100 }]); // 大幅移动
    const yawAfter: number = rig.capture.yawAccum;
    const stateAfterMove: GestureState = rig.getState();
    // 全部抬起
    rig.up(1);
    // 新的单指手势可以旋转
    rig.down({ id: 3, x: 500, y: 500 });
    rig.move([{ id: 3, x: 560, y: 540 }]);
    const yawAfterNewGesture: number = rig.capture.yawAccum;
    rig.up(3);
    const ok: boolean = yawAfter === yawBefore
      && stateAfterMove !== GestureState.SingleRotate
      && yawAfterNewGesture > yawAfter;
    return Character3DGestureHandlerTest.buildResult('10_TwoFingerToSingleSuppress', ok,
      'yawBefore=' + yawBefore.toFixed(3) + ' yawAfterSuppressedMove=' + yawAfter.toFixed(3)
      + ' yawAfterNewGesture=' + yawAfterNewGesture.toFixed(3));
  }

  /** 11. Cancel(SingleRotate 状态):状态回到 Idle,transform 保留 */
  private static test11_CancelSingleRotate(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 500, y: 500 });
    rig.move([{ id: 1, x: 560, y: 540 }]); // 旋转
    const yawBefore: number = rig.capture.yawAccum;
    const stateBefore: GestureState = rig.getState();
    rig.cancel();
    const stateAfter: GestureState = rig.getState();
    const yawAfter: number = rig.capture.yawAccum;
    // Cancel 后可以开始新手势
    rig.down({ id: 2, x: 500, y: 500 });
    const stateNewGesture: GestureState = rig.getState();
    rig.up(2);
    const ok: boolean = stateBefore === GestureState.SingleRotate
      && stateAfter === GestureState.Idle
      && yawAfter === yawBefore
      && stateNewGesture === GestureState.SingleRotate;
    return Character3DGestureHandlerTest.buildResult('11_CancelSingleRotate', ok,
      'before=' + stateBefore + ' after=' + stateAfter
      + ' yawPreserved=' + (yawAfter === yawBefore).toString()
      + ' newGesture=' + stateNewGesture);
  }

  /** 12. Cancel(TwoFingerScale 状态):状态回到 Idle,zoom 保留 */
  private static test12_CancelTwoFingerScale(): TestResult {
    const rig: GestureTestRig = new GestureTestRig();
    rig.down({ id: 1, x: 400, y: 500 });
    rig.down({ id: 2, x: 600, y: 500 });
    rig.move([{ id: 1, x: 300, y: 500 }, { id: 2, x: 700, y: 500 }]); // zoom=2.0
    const zoomBefore: number = rig.capture.zoomFactor;
    const stateBefore: GestureState = rig.getState();
    rig.cancel();
    const stateAfter: GestureState = rig.getState();
    const zoomAfter: number = rig.capture.zoomFactor;
    const ok: boolean = stateBefore === GestureState.TwoFingerScale
      && stateAfter === GestureState.Idle
      && approxEqual(zoomAfter, zoomBefore);
    return Character3DGestureHandlerTest.buildResult('12_CancelTwoFingerScale', ok,
      'before=' + stateBefore + ' after=' + stateAfter
      + ' zoomPreserved=' + approxEqual(zoomAfter, zoomBefore).toString()
      + ' zoom=' + zoomAfter.toFixed(4));
  }

  /** 13. 非法值:viewport=0 / NaN / Infinity / 重复 ID,不 crash,不产生 NaN */
  private static test13_InvalidValues(): TestResult {
    let noCrash: boolean = true;
    let noNaN: boolean = true;

    // viewport=0
    try {
      const rig: GestureTestRig = new GestureTestRig();
      rig.handler.setViewport(0, 0);
      rig.down({ id: 1, x: 500, y: 500 });
      rig.down({ id: 2, x: 600, y: 500 });
      rig.move([{ id: 1, x: 430, y: 500 }, { id: 2, x: 630, y: 500 }]);
      rig.up(2);
      rig.up(1);
      if (!Number.isFinite(rig.capture.offsetX) || !Number.isFinite(rig.capture.offsetY)) {
        noNaN = false;
      }
    } catch (_e) {
      noCrash = false;
    }

    // 相同两指坐标(startDistance≈0)
    try {
      const rig: GestureTestRig = new GestureTestRig();
      rig.down({ id: 1, x: 500, y: 500 });
      rig.down({ id: 2, x: 500, y: 500 }); // startDist=0
      rig.move([{ id: 1, x: 400, y: 500 }, { id: 2, x: 600, y: 500 }]);
      rig.up(2);
      rig.up(1);
      if (!Number.isFinite(rig.capture.zoomFactor)) {
        noNaN = false;
      }
    } catch (_e) {
      noCrash = false;
    }

    // NaN 坐标(被 updateActivePointers 过滤)
    try {
      const rig: GestureTestRig = new GestureTestRig();
      rig.handler.handleTouch(TouchPhase.Down, [{ id: 1, x: NaN, y: 500 }], 1, {
        zoomFactor: 1.0, offsetX: 0, offsetY: 0
      });
      rig.handler.handleTouch(TouchPhase.Move, [{ id: 1, x: 600, y: 500 }], -1, {
        zoomFactor: 1.0, offsetX: 0, offsetY: 0
      });
      rig.handler.handleTouch(TouchPhase.Up, [], 1, {
        zoomFactor: 1.0, offsetX: 0, offsetY: 0
      });
    } catch (_e) {
      noCrash = false;
    }

    // Infinity 坐标
    try {
      const rig: GestureTestRig = new GestureTestRig();
      rig.handler.handleTouch(TouchPhase.Down, [{ id: 1, x: 500, y: 500 }], 1, {
        zoomFactor: 1.0, offsetX: 0, offsetY: 0
      });
      rig.handler.handleTouch(TouchPhase.Move, [{ id: 1, x: Infinity, y: 500 }], -1, {
        zoomFactor: 1.0, offsetX: 0, offsetY: 0
      });
      rig.handler.handleTouch(TouchPhase.Up, [], 1, {
        zoomFactor: 1.0, offsetX: 0, offsetY: 0
      });
    } catch (_e) {
      noCrash = false;
    }

    // 重复 pointer ID(第二根手指与第一根同 id)
    try {
      const rig: GestureTestRig = new GestureTestRig();
      rig.down({ id: 1, x: 400, y: 500 });
      rig.handler.handleTouch(TouchPhase.Down, [{ id: 1, x: 600, y: 500 }], 1, {
        zoomFactor: 1.0, offsetX: 0, offsetY: 0
      });
      rig.handler.handleTouch(TouchPhase.Up, [], 1, {
        zoomFactor: 1.0, offsetX: 0, offsetY: 0
      });
    } catch (_e) {
      noCrash = false;
    }

    const ok: boolean = noCrash && noNaN;
    return Character3DGestureHandlerTest.buildResult('13_InvalidValues', ok,
      'noCrash=' + noCrash.toString() + ' noNaN=' + noNaN.toString());
  }

  /** 14. PoC 与聊天页一致性:相同输入到两个 handler,输出应完全一致(1e-4 误差) */
  private static test14_PageConsistency(): TestResult {
    // 模拟 PoC 页 handler
    const rigA: GestureTestRig = new GestureTestRig();
    // 模拟聊天页 handler
    const rigB: GestureTestRig = new GestureTestRig();

    // 相同 pointer 序列:单指旋转 → 双指缩放到 5x → 双指平移 → 重置
    const sequence: string[] = [];

    // 1. 单指旋转
    sequence.push('rotate');
    rigA.down({ id: 1, x: 500, y: 500 });
    rigB.down({ id: 1, x: 500, y: 500 });
    rigA.move([{ id: 1, x: 560, y: 540 }]);
    rigB.move([{ id: 1, x: 560, y: 540 }]);
    rigA.up(1);
    rigB.up(1);

    // 2. 双指缩放到 5x(startDist=200, ratio=5x)
    sequence.push('scale5x');
    rigA.down({ id: 1, x: 400, y: 500 });
    rigB.down({ id: 1, x: 400, y: 500 });
    rigA.down({ id: 2, x: 600, y: 500 });
    rigB.down({ id: 2, x: 600, y: 500 });
    rigA.move([{ id: 1, x: 0, y: 500 }, { id: 2, x: 1000, y: 500 }]); // dist=1000, ratio=5x
    rigB.move([{ id: 1, x: 0, y: 500 }, { id: 2, x: 1000, y: 500 }]);
    rigA.up(2);
    rigB.up(2);
    rigA.up(1);
    rigB.up(1);

    // 3. 双指平移
    sequence.push('translate');
    rigA.down({ id: 1, x: 400, y: 500 });
    rigB.down({ id: 1, x: 400, y: 500 });
    rigA.down({ id: 2, x: 600, y: 500 });
    rigB.down({ id: 2, x: 600, y: 500 });
    rigA.move([{ id: 1, x: 430, y: 500 }, { id: 2, x: 630, y: 500 }]);
    rigB.move([{ id: 1, x: 430, y: 500 }, { id: 2, x: 630, y: 500 }]);
    rigA.up(2);
    rigB.up(2);
    rigA.up(1);
    rigB.up(1);

    // 比较最终输出
    const yawMatch: boolean = approxEqual(rigA.capture.yawAccum, rigB.capture.yawAccum);
    const pitchMatch: boolean = approxEqual(rigA.capture.pitchAccum, rigB.capture.pitchAccum);
    const zoomMatch: boolean = approxEqual(rigA.capture.zoomFactor, rigB.capture.zoomFactor);
    const offsetXMatch: boolean = approxEqual(rigA.capture.offsetX, rigB.capture.offsetX);
    const offsetYMatch: boolean = approxEqual(rigA.capture.offsetY, rigB.capture.offsetY);

    const ok: boolean = yawMatch && pitchMatch && zoomMatch && offsetXMatch && offsetYMatch;
    return Character3DGestureHandlerTest.buildResult('14_PageConsistency', ok,
      'yaw(' + rigA.capture.yawAccum.toFixed(4) + '/' + rigB.capture.yawAccum.toFixed(4) + ')'
      + ' pitch(' + rigA.capture.pitchAccum.toFixed(4) + '/' + rigB.capture.pitchAccum.toFixed(4) + ')'
      + ' zoom(' + rigA.capture.zoomFactor.toFixed(4) + '/' + rigB.capture.zoomFactor.toFixed(4) + ')'
      + ' offX(' + rigA.capture.offsetX.toFixed(4) + '/' + rigB.capture.offsetX.toFixed(4) + ')'
      + ' offY(' + rigA.capture.offsetY.toFixed(4) + '/' + rigB.capture.offsetY.toFixed(4) + ')'
      + ' seq=' + sequence.join('→'));
  }

  /**
   * 构造单项测试结果,并输出日志。
   */
  private static buildResult(name: string, passed: boolean, message: string): TestResult {
    const prefix: string = passed ? '[PASS] ' : '[FAIL] ';
    Logger.info(LOG_TAG, prefix + name + ' - ' + message);
    return {
      name: name,
      passed: passed,
      message: message
    };
  }
}
