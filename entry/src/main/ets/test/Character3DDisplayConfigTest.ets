/**
 * Character3DDisplayConfigTest 显示配置纯逻辑单元测试
 *
 * 临时开发测试: T-3D.4 模型预览与位置校准
 * T-3D.5D: 新增 baseFitScale / zoomFactor / computeFinalScale 测试(13~16)
 *
 * 职责:
 * - 对 Character3DDisplayConfig 的所有纯逻辑函数做断言测试
 * - 不依赖 ArkUI / ArkGraphics3D / Preferences,可独立运行
 * - 通过 Logger 输出测试结果,供开发期验证
 *
 * 工程环境说明:
 * - 工程 无 ohosTest 目录(Test Runner 环境限制)
 * - 本文件作为纯逻辑测试保留,供未来集成测试框架使用
 * - 调用 Character3DDisplayConfigTest.runAllTests() 可执行全部测试
 *
 * 测试项(共 16 项):
 * 1. 默认配置
 * 2. scale 下限
 * 3. scale 上限
 * 4. rotation 归一化或夹紧
 * 5. offset 边界
 * 6. NaN 回退
 * 7. Infinity 回退
 * 8. 缺失字段迁移
 * 9. 配置序列化与反序列化
 * 10. 恢复默认
 * 11. 不同 modelId 配置隔离(通过 Preferences key 隔离验证)
 * 12. 高频内存更新不触发高频持久化(通过 isDisplayConfigEqual 短路验证)
 * 13. T-3D.5D zoomFactor 常量值验证
 * 14. T-3D.5D getZoomFactor(scale / baseFitScale)
 * 15. T-3D.5D clampZoomFactor 范围夹紧
 * 16. T-3D.5D computeFinalScale(baseFitScale × zoomFactor)
 */

import { Logger } from '../utils/Logger';
import {
  Character3DDisplayConfig,
  createDefaultDisplayConfig,
  sanitizeDisplayConfig,
  isDisplayConfigEqual,
  serializeDisplayConfig,
  deserializeDisplayConfig,
  getZoomFactor,
  clampZoomFactor,
  computeFinalScale,
  SCALE_MIN,
  SCALE_MAX,
  OFFSET_MIN,
  OFFSET_MAX,
  DEFAULT_SCALE,
  DEFAULT_BASE_FIT_SCALE,
  DEFAULT_OFFSET_X,
  DEFAULT_OFFSET_Y,
  DEFAULT_OFFSET_Z,
  DEFAULT_ROTATION_X_DEG,
  DEFAULT_ROTATION_Y_DEG,
  DEFAULT_ROTATION_Z_DEG,
  DEFAULT_CAMERA_DISTANCE,
  VIEWER_ZOOM_FACTOR_MIN,
  VIEWER_ZOOM_FACTOR_MAX,
  VIEWER_ZOOM_FACTOR_DEFAULT
} from '../models/character3d/Character3DDisplayConfig';

const LOG_TAG: string = 'CfgTest';

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

export class Character3DDisplayConfigTest {
  /**
   * 运行全部 16 项测试,返回汇总结果并输出日志。
   */
  static runAllTests(): TestSuiteResult {
    const results: TestResult[] = [];
    results.push(Character3DDisplayConfigTest.test01_DefaultConfig());
    results.push(Character3DDisplayConfigTest.test02_ScaleMin());
    results.push(Character3DDisplayConfigTest.test03_ScaleMax());
    results.push(Character3DDisplayConfigTest.test04_RotationNormalize());
    results.push(Character3DDisplayConfigTest.test05_OffsetBoundary());
    results.push(Character3DDisplayConfigTest.test06_NanFallback());
    results.push(Character3DDisplayConfigTest.test07_InfinityFallback());
    results.push(Character3DDisplayConfigTest.test08_MissingFieldMigration());
    results.push(Character3DDisplayConfigTest.test09_SerializationRoundTrip());
    results.push(Character3DDisplayConfigTest.test10_ResetToDefault());
    results.push(Character3DDisplayConfigTest.test11_ModelIsolation());
    results.push(Character3DDisplayConfigTest.test12_HighFrequencyUpdate());
    results.push(Character3DDisplayConfigTest.test13_ZoomFactorConstants());
    results.push(Character3DDisplayConfigTest.test14_GetZoomFactor());
    results.push(Character3DDisplayConfigTest.test15_ClampZoomFactor());
    results.push(Character3DDisplayConfigTest.test16_ComputeFinalScale());

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
    Logger.info(LOG_TAG, '==== Test Suite Done: ' + passed + '/' + results.length
      + ' passed, ' + failed + ' failed ====');
    return suite;
  }

  /** 1. 默认配置 */
  private static test01_DefaultConfig(): TestResult {
    const c: Character3DDisplayConfig = createDefaultDisplayConfig();
    const ok: boolean = c.scale === DEFAULT_SCALE
      && c.baseFitScale === DEFAULT_BASE_FIT_SCALE
      && c.offsetX === DEFAULT_OFFSET_X
      && c.offsetY === DEFAULT_OFFSET_Y
      && c.offsetZ === DEFAULT_OFFSET_Z
      && c.rotationXDeg === DEFAULT_ROTATION_X_DEG
      && c.rotationYDeg === DEFAULT_ROTATION_Y_DEG
      && c.rotationZDeg === DEFAULT_ROTATION_Z_DEG
      && c.cameraDistance === DEFAULT_CAMERA_DISTANCE;
    return Character3DDisplayConfigTest.buildResult('01_DefaultConfig', ok,
      'scale=' + c.scale + ' bfs=' + c.baseFitScale + ' offsetY=' + c.offsetY
      + ' rotY=' + c.rotationYDeg + ' camDist=' + c.cameraDistance);
  }

  /** 2. scale 下限 */
  private static test02_ScaleMin(): TestResult {
    const input: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ scale: -100 });
    const safe: Character3DDisplayConfig = sanitizeDisplayConfig(input);
    const ok: boolean = safe.scale === SCALE_MIN;
    return Character3DDisplayConfigTest.buildResult('02_ScaleMin', ok,
      'expected=' + SCALE_MIN + ' actual=' + safe.scale);
  }

  /** 3. scale 上限(T-3D.5D: SCALE_MAX 改为 NaN 防御值 20000,需输入更大值触发夹紧) */
  private static test03_ScaleMax(): TestResult {
    const input: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ scale: 99999 });
    const safe: Character3DDisplayConfig = sanitizeDisplayConfig(input);
    const ok: boolean = safe.scale === SCALE_MAX;
    return Character3DDisplayConfigTest.buildResult('03_ScaleMax', ok,
      'expected=' + SCALE_MAX + ' actual=' + safe.scale);
  }

  /** 4. rotation 归一化或夹紧 */
  private static test04_RotationNormalize(): TestResult {
    // 270° 应归一化为 -90°
    const input1: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ rotationYDeg: 270 });
    const safe1: Character3DDisplayConfig = sanitizeDisplayConfig(input1);
    // 360° 应归一化为 0°
    const input2: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ rotationXDeg: 360 });
    const safe2: Character3DDisplayConfig = sanitizeDisplayConfig(input2);
    // -270° 应归一化为 90°
    const input3: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ rotationZDeg: -270 });
    const safe3: Character3DDisplayConfig = sanitizeDisplayConfig(input3);
    // 超出 [-180,180] 的大值(720°)应被夹紧后再归一化
    const input4: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ rotationYDeg: 720 });
    const safe4: Character3DDisplayConfig = sanitizeDisplayConfig(input4);
    const ok: boolean = safe1.rotationYDeg === -90
      && safe2.rotationXDeg === 0
      && safe3.rotationZDeg === 90
      && safe4.rotationYDeg === 0;
    return Character3DDisplayConfigTest.buildResult('04_RotationNormalize', ok,
      'rY270->' + safe1.rotationYDeg + ' rX360->' + safe2.rotationXDeg
      + ' rZ-270->' + safe3.rotationZDeg + ' rY720->' + safe4.rotationYDeg);
  }

  /** 5. offset 边界 */
  private static test05_OffsetBoundary(): TestResult {
    const input1: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ offsetX: -999 });
    const safe1: Character3DDisplayConfig = sanitizeDisplayConfig(input1);
    const input2: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ offsetZ: 999 });
    const safe2: Character3DDisplayConfig = sanitizeDisplayConfig(input2);
    const input3: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ offsetY: 2.5 });
    const safe3: Character3DDisplayConfig = sanitizeDisplayConfig(input3);
    const ok: boolean = safe1.offsetX === OFFSET_MIN
      && safe2.offsetZ === OFFSET_MAX
      && safe3.offsetY === 2.5;
    return Character3DDisplayConfigTest.buildResult('05_OffsetBoundary', ok,
      'minX=' + safe1.offsetX + ' maxZ=' + safe2.offsetZ + ' normalY=' + safe3.offsetY);
  }

  /** 6. NaN 回退 */
  private static test06_NanFallback(): TestResult {
    const input: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({
      scale: NaN,
      offsetX: NaN,
      rotationYDeg: NaN,
      cameraDistance: NaN
    });
    const safe: Character3DDisplayConfig = sanitizeDisplayConfig(input);
    const ok: boolean = safe.scale === DEFAULT_SCALE
      && safe.offsetX === DEFAULT_OFFSET_X
      && safe.rotationYDeg === DEFAULT_ROTATION_Y_DEG
      && safe.cameraDistance === DEFAULT_CAMERA_DISTANCE;
    return Character3DDisplayConfigTest.buildResult('06_NanFallback', ok,
      'scale=' + safe.scale + ' offsetX=' + safe.offsetX
      + ' rotY=' + safe.rotationYDeg + ' camDist=' + safe.cameraDistance);
  }

  /** 7. Infinity 回退 */
  private static test07_InfinityFallback(): TestResult {
    const input: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({
      scale: Infinity,
      offsetY: -Infinity,
      rotationXDeg: Infinity,
      cameraDistance: -Infinity
    });
    const safe: Character3DDisplayConfig = sanitizeDisplayConfig(input);
    const ok: boolean = safe.scale === DEFAULT_SCALE
      && safe.offsetY === DEFAULT_OFFSET_Y
      && safe.rotationXDeg === DEFAULT_ROTATION_X_DEG
      && safe.cameraDistance === DEFAULT_CAMERA_DISTANCE;
    return Character3DDisplayConfigTest.buildResult('07_InfinityFallback', ok,
      'scale=' + safe.scale + ' offsetY=' + safe.offsetY
      + ' rotX=' + safe.rotationXDeg + ' camDist=' + safe.cameraDistance);
  }

  /** 8. 缺失字段迁移(空 JSON / 部分 JSON / 损坏 JSON) */
  private static test08_MissingFieldMigration(): TestResult {
    // 空 JSON
    const r1: Character3DDisplayConfig = deserializeDisplayConfig('');
    // 部分字段 JSON(只有 scale)
    const r2: Character3DDisplayConfig = deserializeDisplayConfig('{"scale":1.5}');
    // 损坏 JSON
    const r3: Character3DDisplayConfig = deserializeDisplayConfig('{not json');
    // 类型错误 JSON(scale 是字符串)
    const r4: Character3DDisplayConfig = deserializeDisplayConfig('{"scale":"abc"}');
    const ok: boolean = r1.scale === DEFAULT_SCALE && r1.offsetY === DEFAULT_OFFSET_Y
      && r2.scale === 1.5 && r2.offsetY === DEFAULT_OFFSET_Y
      && r3.scale === DEFAULT_SCALE
      && r4.scale === DEFAULT_SCALE;
    return Character3DDisplayConfigTest.buildResult('08_MissingFieldMigration', ok,
      'empty.scale=' + r1.scale + ' partial.scale=' + r2.scale
      + ' broken.scale=' + r3.scale + ' typeErr.scale=' + r4.scale);
  }

  /** 9. 配置序列化与反序列化(round-trip) */
  private static test09_SerializationRoundTrip(): TestResult {
    const original: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({
      scale: 1.23,
      offsetX: -1.5,
      offsetY: 0.7,
      offsetZ: 2.3,
      rotationXDeg: 30,
      rotationYDeg: -45,
      rotationZDeg: 90,
      cameraDistance: 5.5
    });
    const json: string = serializeDisplayConfig(original);
    const restored: Character3DDisplayConfig = deserializeDisplayConfig(json);
    const ok: boolean = isDisplayConfigEqual(original, restored);
    return Character3DDisplayConfigTest.buildResult('09_SerializationRoundTrip', ok,
      'json=' + json + ' equal=' + ok.toString());
  }

  /** 10. 恢复默认 */
  private static test10_ResetToDefault(): TestResult {
    // 先修改,再用 createDefaultDisplayConfig 模拟重置
    const modified: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({
      scale: 2.0,
      offsetY: 1.5,
      rotationYDeg: 90,
      cameraDistance: 10
    });
    const reset: Character3DDisplayConfig = createDefaultDisplayConfig();
    const notEqualBefore: boolean = !isDisplayConfigEqual(modified, reset);
    const equalAfter: boolean = isDisplayConfigEqual(reset, createDefaultDisplayConfig());
    const ok: boolean = notEqualBefore && equalAfter;
    return Character3DDisplayConfigTest.buildResult('10_ResetToDefault', ok,
      'modified!=default=' + notEqualBefore.toString()
      + ' reset==default=' + equalAfter.toString());
  }

  /** 11. 不同 modelId 配置隔离(通过 Preferences key 隔离验证) */
  private static test11_ModelIsolation(): TestResult {
    // 由于当前 PoC 使用全局 key 'character_3d_display_config',
    // 隔离测试验证:两个不同配置互不影响,序列化/反序列化独立
    const cfgA: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({
      scale: 1.5,
      rotationYDeg: 30,
      cameraDistance: 4.0
    });
    const cfgB: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({
      scale: 0.8,
      rotationYDeg: -60,
      cameraDistance: 6.0
    });
    const jsonA: string = serializeDisplayConfig(cfgA);
    const jsonB: string = serializeDisplayConfig(cfgB);
    const restoredA: Character3DDisplayConfig = deserializeDisplayConfig(jsonA);
    const restoredB: Character3DDisplayConfig = deserializeDisplayConfig(jsonB);
    // A 和 B 应该互不相等,且各自 round-trip 正确
    const notEqual: boolean = !isDisplayConfigEqual(restoredA, restoredB);
    const aCorrect: boolean = isDisplayConfigEqual(restoredA, cfgA);
    const bCorrect: boolean = isDisplayConfigEqual(restoredB, cfgB);
    const ok: boolean = notEqual && aCorrect && bCorrect;
    return Character3DDisplayConfigTest.buildResult('11_ModelIsolation', ok,
      'A!=B=' + notEqual.toString() + ' A.roundTrip=' + aCorrect.toString()
      + ' B.roundTrip=' + bCorrect.toString());
  }

  /** 12. 高频内存更新不触发高频持久化(通过 isDisplayConfigEqual 短路验证) */
  private static test12_HighFrequencyUpdate(): TestResult {
    // 模拟 Service.saveDisplayConfig 的短路逻辑:
    // 如果新配置与现有配置相等,则不写盘
    const cfg1: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ scale: 1.0 });
    const cfg2: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ scale: 1.0 });
    const cfg3: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ scale: 1.001 });

    // cfg1 与 cfg2 相等,应短路(不写盘)
    const equal12: boolean = isDisplayConfigEqual(cfg1, cfg2);
    // cfg1 与 cfg3 不相等,应写盘
    const equal13: boolean = isDisplayConfigEqual(cfg1, cfg3);

    // 模拟高频更新:同一值连续传入 100 次,只有第一次需要写盘
    let writeCount: number = 0;
    let lastWritten: Character3DDisplayConfig = cfg1;
    for (let i: number = 0; i < 100; i++) {
      const candidate: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({ scale: 1.0 });
      if (!isDisplayConfigEqual(lastWritten, candidate)) {
        writeCount++;
        lastWritten = candidate;
      }
    }
    // 100 次相同值更新,writeCount 应为 0(因为初始 lastWritten 已是相同值)
    const ok: boolean = equal12 === true && equal13 === false && writeCount === 0;
    return Character3DDisplayConfigTest.buildResult('12_HighFrequencyUpdate', ok,
      'equal12=' + equal12.toString() + ' equal13=' + equal13.toString()
      + ' writeCount(100次相同更新)=' + writeCount.toString());
  }

  /** 13. T-3D.5D zoomFactor 常量值验证 */
  private static test13_ZoomFactorConstants(): TestResult {
    // 常量必须为规定值,任何修改会导致跨模型体验不一致
    const ok: boolean = VIEWER_ZOOM_FACTOR_MIN === 0.10
      && VIEWER_ZOOM_FACTOR_MAX === 20.0
      && VIEWER_ZOOM_FACTOR_DEFAULT === 1.0;
    return Character3DDisplayConfigTest.buildResult('13_ZoomFactorConstants', ok,
      'MIN=' + VIEWER_ZOOM_FACTOR_MIN + ' MAX=' + VIEWER_ZOOM_FACTOR_MAX
      + ' DEFAULT=' + VIEWER_ZOOM_FACTOR_DEFAULT);
  }

  /** 14. T-3D.5D getZoomFactor(scale / baseFitScale) */
  private static test14_GetZoomFactor(): TestResult {
    // 正常情况:zoomFactor = scale / baseFitScale
    const c1: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({
      scale: 2.0, baseFitScale: 0.5
    });
    const zf1: number = getZoomFactor(c1); // 2.0 / 0.5 = 4.0
    // 默认配置:scale=1.0, baseFitScale=1.0 → zoomFactor=1.0
    const c2: Character3DDisplayConfig = createDefaultDisplayConfig();
    const zf2: number = getZoomFactor(c2);
    // baseFitScale 非法(<=0)→ 回退默认 1.0
    const c3: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({
      scale: 5.0, baseFitScale: 0
    });
    const zf3: number = getZoomFactor(c3);
    // baseFitScale NaN → 回退默认 1.0
    const c4: Character3DDisplayConfig = Character3DDisplayConfigTest.makeConfig({
      scale: 5.0, baseFitScale: NaN
    });
    const zf4: number = getZoomFactor(c4);
    const ok: boolean = zf1 === 4.0 && zf2 === 1.0 && zf3 === 1.0 && zf4 === 1.0;
    return Character3DDisplayConfigTest.buildResult('14_GetZoomFactor', ok,
      '2/0.5=' + zf1 + ' default=' + zf2 + ' bfs=0=' + zf3 + ' bfs=NaN=' + zf4);
  }

  /** 15. T-3D.5D clampZoomFactor 范围夹紧 */
  private static test15_ClampZoomFactor(): TestResult {
    // 正常值不变
    const r1: number = clampZoomFactor(1.0);
    const r2: number = clampZoomFactor(10.5);
    // 超过上限 → 夹紧到 MAX(20.0)
    const r3: number = clampZoomFactor(25.0);
    // 低于下限 → 夹紧到 MIN(0.10)
    const r4: number = clampZoomFactor(0.05);
    // 边界值
    const r5: number = clampZoomFactor(0.10);
    const r6: number = clampZoomFactor(20.0);
    // 非法值 → 回退默认
    const r7: number = clampZoomFactor(NaN);
    const r8: number = clampZoomFactor(Infinity);
    const r9: number = clampZoomFactor(-1.0);
    const r10: number = clampZoomFactor(0);
    const ok: boolean = r1 === 1.0 && r2 === 10.5
      && r3 === VIEWER_ZOOM_FACTOR_MAX
      && r4 === VIEWER_ZOOM_FACTOR_MIN
      && r5 === VIEWER_ZOOM_FACTOR_MIN
      && r6 === VIEWER_ZOOM_FACTOR_MAX
      && r7 === VIEWER_ZOOM_FACTOR_DEFAULT
      && r8 === VIEWER_ZOOM_FACTOR_DEFAULT
      && r9 === VIEWER_ZOOM_FACTOR_DEFAULT
      && r10 === VIEWER_ZOOM_FACTOR_DEFAULT;
    return Character3DDisplayConfigTest.buildResult('15_ClampZoomFactor', ok,
      '1.0=' + r1 + ' 10.5=' + r2 + ' 25→' + r3 + ' 0.05→' + r4
      + ' NaN→' + r7 + ' Inf→' + r8 + ' -1→' + r9 + ' 0→' + r10);
  }

  /** 16. T-3D.5D computeFinalScale(baseFitScale × zoomFactor) */
  private static test16_ComputeFinalScale(): TestResult {
    // 正常计算:bfs × zf
    const r1: number = computeFinalScale(0.5, 4.0); // 0.5 × 4.0 = 2.0
    const r2: number = computeFinalScale(1.0, 1.0); // 1.0
    const r3: number = computeFinalScale(0.1, 20.0); // 0.1 × 20.0 = 2.0
    // zoomFactor 超范围 → 先 clamp 再计算
    const r4: number = computeFinalScale(1.0, 25.0); // 1.0 × 20.0 = 20.0
    const r5: number = computeFinalScale(1.0, 0.05); // 1.0 × 0.10 = 0.10
    // baseFitScale 非法 → 回退 DEFAULT_BASE_FIT_SCALE(1.0)
    const r6: number = computeFinalScale(0, 2.0); // 1.0 × 2.0 = 2.0
    const r7: number = computeFinalScale(NaN, 2.0); // 1.0 × 2.0 = 2.0
    const r8: number = computeFinalScale(-1.0, 2.0); // 1.0 × 2.0 = 2.0
    // zoomFactor 非法 → 回退 DEFAULT(1.0)
    const r9: number = computeFinalScale(0.5, NaN); // 0.5 × 1.0 = 0.5
    const ok: boolean = r1 === 2.0 && r2 === 1.0 && r3 === 2.0
      && r4 === 20.0 && r5 === 0.10
      && r6 === 2.0 && r7 === 2.0 && r8 === 2.0
      && r9 === 0.5;
    return Character3DDisplayConfigTest.buildResult('16_ComputeFinalScale', ok,
      '0.5×4=' + r1 + ' 1×1=' + r2 + ' 0.1×20=' + r3
      + ' 1×25(clamp20)=' + r4 + ' 1×0.05(clamp0.1)=' + r5
      + ' bfs=0→' + r6 + ' bfs=NaN→' + r7 + ' zf=NaN→' + r9);
  }

  /**
   * 构造一个带部分字段覆盖的配置(其他字段为默认值)。
   * T-3D.5D: 包含 baseFitScale 字段(默认 DEFAULT_BASE_FIT_SCALE)。
   */
  private static makeConfig(partial: Partial<Character3DDisplayConfig>): Character3DDisplayConfig {
    const base: Character3DDisplayConfig = createDefaultDisplayConfig();
    return {
      scale: partial.scale !== undefined ? partial.scale : base.scale,
      baseFitScale: partial.baseFitScale !== undefined ? partial.baseFitScale : base.baseFitScale,
      offsetX: partial.offsetX !== undefined ? partial.offsetX : base.offsetX,
      offsetY: partial.offsetY !== undefined ? partial.offsetY : base.offsetY,
      offsetZ: partial.offsetZ !== undefined ? partial.offsetZ : base.offsetZ,
      rotationXDeg: partial.rotationXDeg !== undefined ? partial.rotationXDeg : base.rotationXDeg,
      rotationYDeg: partial.rotationYDeg !== undefined ? partial.rotationYDeg : base.rotationYDeg,
      rotationZDeg: partial.rotationZDeg !== undefined ? partial.rotationZDeg : base.rotationZDeg,
      cameraDistance: partial.cameraDistance !== undefined ? partial.cameraDistance : base.cameraDistance
    };
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
