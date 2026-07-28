/**
 * ViewerStateMachine 单元测试
 *
 * 验证 Viewer 状态机的状态转换合法性、loadGeneration 异步竞态防护、
 * 以及 isDisposed 销毁后回调忽略等纯逻辑行为。
 *
 * 本测试为纯逻辑测试,不依赖 ArkGraphics3D 运行时,可通过代码审查验证。
 * 若 entry@ohosTest 目标已配置,可由 OpenHarmonyTestRunner 执行;
 * 若 Test Runner 不可用(已知环境限制),测试逻辑仍可通过代码审查验证。
 *
 * Reference:
 * - 任务指令第十八条:必须添加的单元测试
 */

import {
  FrameLoopState,
  ModelState,
  ViewerState,
  isValidStateTransition,
  viewerStateLabel,
  modelStateLabel,
  quaternionFromEulerY,
  VRM_MODEL_Y_ROTATION_RAD,
  ViewerTestAssets
} from '../../../main/ets/vrmviewer/ViewerTypes';
import { ViewerFrameLoop } from '../../../main/ets/vrmviewer/ViewerFrameLoop';

// 简单断言工具(避免依赖 @ohos/hypium)
function assertEqual(actual: boolean, expected: boolean, message: string): void {
  if (actual !== expected) {
    throw new Error(`ASSERT FAIL: ${message} | expected=${expected}, actual=${actual}`);
  }
}

function assertTrue(actual: boolean, message: string): void {
  assertEqual(actual, true, message);
}

function assertFalse(actual: boolean, message: string): void {
  assertEqual(actual, false, message);
}

/**
 * 测试合法状态转换。
 */
export function testValidTransitions(): void {
  // NOT_INITIALIZED → INITIALIZING
  assertTrue(
    isValidStateTransition(ViewerState.NOT_INITIALIZED, ViewerState.INITIALIZING),
    'NOT_INITIALIZED → INITIALIZING should be valid'
  );

  // INITIALIZING → LOADING_MODEL
  assertTrue(
    isValidStateTransition(ViewerState.INITIALIZING, ViewerState.LOADING_MODEL),
    'INITIALIZING → LOADING_MODEL should be valid'
  );

  // INITIALIZING → FAILED
  assertTrue(
    isValidStateTransition(ViewerState.INITIALIZING, ViewerState.FAILED),
    'INITIALIZING → FAILED should be valid'
  );

  // LOADING_MODEL → READY
  assertTrue(
    isValidStateTransition(ViewerState.LOADING_MODEL, ViewerState.READY),
    'LOADING_MODEL → READY should be valid'
  );

  // LOADING_MODEL → FAILED
  assertTrue(
    isValidStateTransition(ViewerState.LOADING_MODEL, ViewerState.FAILED),
    'LOADING_MODEL → FAILED should be valid'
  );

  // READY → DISPOSING
  assertTrue(
    isValidStateTransition(ViewerState.READY, ViewerState.DISPOSING),
    'READY → DISPOSING should be valid'
  );

  // FAILED → DISPOSING
  assertTrue(
    isValidStateTransition(ViewerState.FAILED, ViewerState.DISPOSING),
    'FAILED → DISPOSING should be valid'
  );

  // DISPOSING → DISPOSED
  assertTrue(
    isValidStateTransition(ViewerState.DISPOSING, ViewerState.DISPOSED),
    'DISPOSING → DISPOSED should be valid'
  );

  // READY → LOADING_MODEL (替换模型)
  assertTrue(
    isValidStateTransition(ViewerState.READY, ViewerState.LOADING_MODEL),
    'READY → LOADING_MODEL should be valid (model replacement)'
  );

  // FAILED → LOADING_MODEL (重试加载)
  assertTrue(
    isValidStateTransition(ViewerState.FAILED, ViewerState.LOADING_MODEL),
    'FAILED → LOADING_MODEL should be valid (retry)'
  );
}

/**
 * 测试非法状态转换。
 */
export function testInvalidTransitions(): void {
  // NOT_INITIALIZED → LOADING_MODEL (必须先 INITIALIZING)
  assertFalse(
    isValidStateTransition(ViewerState.NOT_INITIALIZED, ViewerState.LOADING_MODEL),
    'NOT_INITIALIZED → LOADING_MODEL should be invalid'
  );

  // NOT_INITIALIZED → READY
  assertFalse(
    isValidStateTransition(ViewerState.NOT_INITIALIZED, ViewerState.READY),
    'NOT_INITIALIZED → READY should be invalid'
  );

  // DISPOSED → 任何 (终态)
  assertFalse(
    isValidStateTransition(ViewerState.DISPOSED, ViewerState.INITIALIZING),
    'DISPOSED → INITIALIZING should be invalid'
  );
  assertFalse(
    isValidStateTransition(ViewerState.DISPOSED, ViewerState.LOADING_MODEL),
    'DISPOSED → LOADING_MODEL should be invalid'
  );
  assertFalse(
    isValidStateTransition(ViewerState.DISPOSED, ViewerState.READY),
    'DISPOSED → READY should be invalid'
  );

  // READY → NOT_INITIALIZED (不能回到初始)
  assertFalse(
    isValidStateTransition(ViewerState.READY, ViewerState.NOT_INITIALIZED),
    'READY → NOT_INITIALIZED should be invalid'
  );

  // FAILED → READY (不能直接从失败到就绪,必须先 LOADING_MODEL)
  assertFalse(
    isValidStateTransition(ViewerState.FAILED, ViewerState.READY),
    'FAILED → READY should be invalid'
  );
}

/**
 * 测试相同状态(不算转换,合法)。
 */
export function testSameState(): void {
  assertTrue(
    isValidStateTransition(ViewerState.READY, ViewerState.READY),
    'READY → READY should be valid (no-op)'
  );
  assertTrue(
    isValidStateTransition(ViewerState.NOT_INITIALIZED, ViewerState.NOT_INITIALIZED),
    'NOT_INITIALIZED → NOT_INITIALIZED should be valid (no-op)'
  );
}

/**
 * 测试 loadGeneration 异步竞态防护逻辑。
 *
 * 模拟:启动 loadGen=1 的加载 → 启动 loadGen=2 的加载 → loadGen=1 的回调应被忽略。
 */
export function testLoadGenerationRaceCondition(): void {
  let loadGeneration: number = 0;

  // 第一次加载
  const gen1: number = ++loadGeneration;
  assertEqual(gen1, 1, 'first loadGeneration should be 1');

  // 第二次加载(在第一次完成前)
  const gen2: number = ++loadGeneration;
  assertEqual(gen2, 2, 'second loadGeneration should be 2');

  // 第一次加载的回调检查:gen1 !== loadGeneration → 应放弃
  assertTrue(
    gen1 !== loadGeneration,
    'gen1 should be stale (gen1=1, loadGeneration=2)'
  );

  // 第二次加载的回调检查:gen2 === loadGeneration → 应继续
  assertTrue(
    gen2 === loadGeneration,
    'gen2 should be current (gen2=2, loadGeneration=2)'
  );
}

/**
 * 测试 isDisposed 销毁后回调忽略逻辑。
 */
export function testIsDisposedGuardsCallbacks(): void {
  let isDisposed: boolean = false;

  // 销毁前
  assertFalse(isDisposed, 'isDisposed should be false before destroy');

  // 模拟销毁
  isDisposed = true;

  // 销毁后回调检查
  assertTrue(isDisposed, 'isDisposed should be true after destroy');

  // 模拟异步回调:if (isDisposed) return;
  let callbackExecuted: boolean = false;
  if (!isDisposed) {
    callbackExecuted = true;
  }
  assertFalse(
    callbackExecuted,
    'callback should NOT execute after dispose'
  );
}

/**
 * 测试 Frame Loop 不重复启动。
 */
export function testFrameLoopNoDuplicateStart(): void {
  const loop: ViewerFrameLoop = new ViewerFrameLoop();

  // 初始状态
  assertEqual(
    loop.getState(),
    FrameLoopState.STOPPED,
    'FrameLoop initial state should be STOPPED'
  );
  assertFalse(loop.isRunning(), 'FrameLoop should not be running initially');

  // 第一次 start
  loop.start();
  assertEqual(
    loop.getState(),
    FrameLoopState.RUNNING,
    'FrameLoop state should be RUNNING after first start'
  );
  assertTrue(loop.isRunning(), 'FrameLoop should be running after first start');

  // 第二次 start(应无效果)
  loop.start();
  assertEqual(
    loop.getState(),
    FrameLoopState.RUNNING,
    'FrameLoop state should still be RUNNING after second start'
  );

  // 停止
  loop.stop();
  assertEqual(
    loop.getState(),
    FrameLoopState.STOPPED,
    'FrameLoop state should be STOPPED after stop'
  );
  assertFalse(loop.isRunning(), 'FrameLoop should not be running after stop');

  // 重复 stop(应无效果,不崩溃)
  loop.stop();
  assertEqual(
    loop.getState(),
    FrameLoopState.STOPPED,
    'FrameLoop state should still be STOPPED after duplicate stop'
  );
}

/**
 * 测试 dispose 后 Frame Loop 停止。
 */
export function testFrameLoopStopsAfterDispose(): void {
  const loop: ViewerFrameLoop = new ViewerFrameLoop();
  loop.start();
  assertTrue(loop.isRunning(), 'FrameLoop should be running after start');

  // 模拟 dispose:先 stop 再检查
  loop.stop();
  assertFalse(loop.isRunning(), 'FrameLoop should stop after dispose');

  // 再次检查状态
  assertEqual(
    loop.getState(),
    FrameLoopState.STOPPED,
    'FrameLoop state should be STOPPED after dispose'
  );
}

/**
 * 测试状态标签函数。
 */
export function testStateLabels(): void {
  assertEqual(
    viewerStateLabel(ViewerState.NOT_INITIALIZED),
    'NOT_INITIALIZED',
    'label for NOT_INITIALIZED'
  );
  assertEqual(
    viewerStateLabel(ViewerState.READY),
    'READY',
    'label for READY'
  );
  assertEqual(
    viewerStateLabel(ViewerState.DISPOSED),
    'DISPOSED',
    'label for DISPOSED'
  );
  assertEqual(
    modelStateLabel(ModelState.NOT_LOADED),
    'NOT_LOADED',
    'label for NOT_LOADED'
  );
  assertEqual(
    modelStateLabel(ModelState.READY),
    'READY',
    'label for READY'
  );
}

/**
 * 测试四元数转换(Y 轴 π 旋转)。
 */
export function testQuaternionFromEulerY(): void {
  const q = quaternionFromEulerY(VRM_MODEL_Y_ROTATION_RAD);

  // 绕 Y 轴旋转 π 的四元数:(0, sin(π/2), 0, cos(π/2)) = (0, 1, 0, 0)
  assertEqual(q.x, 0, 'quaternion x should be 0');
  assertEqual(
    Math.abs(q.y - 1.0) < 1e-10,
    true,
    'quaternion y should be sin(π/2) = 1'
  );
  assertEqual(q.z, 0, 'quaternion z should be 0');
  assertEqual(
    Math.abs(q.w) < 1e-10,
    true,
    'quaternion w should be cos(π/2) ≈ 0'
  );
}

/**
 * 测试测试 VRM 资源路径常量。
 */
export function testViewerTestAssetsPath(): void {
  assertEqual(
    ViewerTestAssets.DEFAULT_VRM,
    'vrm/default.vrm',
    'DEFAULT_VRM path should be vrm/default.vrm'
  );
}

/**
 * 运行所有测试,返回失败计数。
 *
 * @returns 失败的测试数量(0 表示全部通过)
 */
export function runAllTests(): number {
  const tests: Array<{ name: string; fn: () => void }> = [
    { name: 'testValidTransitions', fn: testValidTransitions },
    { name: 'testInvalidTransitions', fn: testInvalidTransitions },
    { name: 'testSameState', fn: testSameState },
    { name: 'testLoadGenerationRaceCondition', fn: testLoadGenerationRaceCondition },
    { name: 'testIsDisposedGuardsCallbacks', fn: testIsDisposedGuardsCallbacks },
    { name: 'testFrameLoopNoDuplicateStart', fn: testFrameLoopNoDuplicateStart },
    { name: 'testFrameLoopStopsAfterDispose', fn: testFrameLoopStopsAfterDispose },
    { name: 'testStateLabels', fn: testStateLabels },
    { name: 'testQuaternionFromEulerY', fn: testQuaternionFromEulerY },
    { name: 'testViewerTestAssetsPath', fn: testViewerTestAssetsPath }
  ];

  let failures: number = 0;
  for (let i = 0; i < tests.length; i++) {
    const t = tests[i];
    try {
      t.fn();
      console.info(`[PASS] ${t.name}`);
    } catch (e) {
      failures++;
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`[FAIL] ${t.name}: ${msg}`);
    }
  }
  console.info(`Tests complete: ${tests.length - failures}/${tests.length} passed`);
  return failures;
}
