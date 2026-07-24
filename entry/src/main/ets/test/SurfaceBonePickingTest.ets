/**
 * SurfaceBonePickingTest 表面点选骨骼推断单元测试
 *
 * T-3D.6F-A: 测试 ray-triangle 求交和 Bone 候选评分算法。
 *
 * 测试覆盖:
 * 1. ray-triangle 求交(命中/未命中/平行)
 * 2. screenToWorldRay 中心射线方向
 * 3. inferCandidates 单 Bone 主导
 * 4. inferCandidates 空 weights
 * 5. inferCandidates 非法 joint index 聚合行为
 * 6. inferCandidates Top5 排序
 * 7. inferCandidates 重复 Bone 聚合
 * 8. setModelTransform + invalidate 缓存行为
 * 9. 未预处理时 pickBone 返回空
 * 10. 未命中时 inferCandidates 返回空
 */

import { SurfaceBonePickingService, WorldTriangle } from '../services/SurfaceBonePickingService';
import {
  Ray3D,
  RayHitResult,
  BoneClickCandidate,
  SurfacePickingInput,
  createEmptyHitResult
} from '../models/character3d/SurfaceBoneCandidate';

/** 单项测试结果 */
export interface SurfacePickingTestResult {
  name: string;
  passed: boolean;
  message: string;
}

/** 全部测试结果汇总 */
export interface SurfacePickingTestSuiteResult {
  total: number;
  passed: number;
  failed: number;
  results: SurfacePickingTestResult[];
}

/**
 * 构造测试用 WorldTriangle。
 */
function makeTriangle(
  j0: number[], w0: number[],
  j1: number[], w1: number[],
  j2: number[], w2: number[]
): WorldTriangle {
  return {
    v0X: 0, v0Y: 0, v0Z: 0,
    v1X: 1, v1Y: 0, v1Z: 0,
    v2X: 0, v2Y: 0, v2Z: 1,
    j0: j0, w0: w0,
    j1: j1, w1: w1,
    j2: j2, w2: w2,
    primitiveIndex: 0
  };
}

/**
 * 测试入口。
 *
 * @returns 测试结果汇总
 */
export function runSurfaceBonePickingTests(): SurfacePickingTestSuiteResult {
  return SurfaceBonePickingTest.runAllTests();
}

/**
 * 表面点选测试套件(类封装,避免嵌套函数)。
 */
class SurfaceBonePickingTest {
  static runAllTests(): SurfacePickingTestSuiteResult {
    const results: SurfacePickingTestResult[] = [];
    results.push(SurfaceBonePickingTest.test01_RayTriangleHit());
    results.push(SurfaceBonePickingTest.test02_RayTriangleMiss());
    results.push(SurfaceBonePickingTest.test03_RayTriangleParallel());
    results.push(SurfaceBonePickingTest.test04_SingleBoneDominant());
    results.push(SurfaceBonePickingTest.test05_EmptyWeights());
    results.push(SurfaceBonePickingTest.test06_InvalidJointIndex());
    results.push(SurfaceBonePickingTest.test07_Top5Sort());
    results.push(SurfaceBonePickingTest.test08_DuplicateBoneAggregate());
    results.push(SurfaceBonePickingTest.test09_ScreenToWorldRayCenter());
    results.push(SurfaceBonePickingTest.test10_InvalidateCache());
    results.push(SurfaceBonePickingTest.test11_PickBoneWithoutPrepare());
    results.push(SurfaceBonePickingTest.test12_InferCandidatesNoHit());

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
  ): SurfacePickingTestResult {
    if (condition) {
      return { name: name, passed: true, message: '' };
    }
    return { name: name, passed: false, message: detail };
  }

  /** 1. ray-triangle 命中 */
  private static test01_RayTriangleHit(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const ray: Ray3D = {
      originX: 0.25, originY: 1, originZ: 0.25,
      dirX: 0, dirY: -1, dirZ: 0
    };
    const t: number = svc.rayTriangleIntersect(ray, 0, 0, 0, 1, 0, 0, 0, 0, 1);
    return SurfaceBonePickingTest.buildResult(
      '01_RayTriangleHit', t > 0.99 && t < 1.01, 't=' + t
    );
  }

  /** 2. ray-triangle 未命中(超出三角形) */
  private static test02_RayTriangleMiss(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const ray: Ray3D = {
      originX: 5, originY: 1, originZ: 5,
      dirX: 0, dirY: -1, dirZ: 0
    };
    const t: number = svc.rayTriangleIntersect(ray, 0, 0, 0, 1, 0, 0, 0, 0, 1);
    return SurfaceBonePickingTest.buildResult(
      '02_RayTriangleMiss', t < 0, 't=' + t
    );
  }

  /** 3. ray-triangle 平行(不命中) */
  private static test03_RayTriangleParallel(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const ray: Ray3D = {
      originX: 0, originY: 1, originZ: 0,
      dirX: 1, dirY: 0, dirZ: 0
    };
    const t: number = svc.rayTriangleIntersect(ray, 0, 0, 0, 1, 0, 0, 0, 0, 1);
    return SurfaceBonePickingTest.buildResult(
      '03_RayTriangleParallel', t < 0, 't=' + t
    );
  }

  /** 4. inferCandidates 单 Bone 主导 */
  private static test04_SingleBoneDominant(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const hit: RayHitResult = createEmptyHitResult();
    hit.hit = true;
    hit.triangleIndex = 0;
    const triangles: WorldTriangle[] = [
      makeTriangle(
        [12, 15, -1, -1], [0.8, 0.2, 0, 0],
        [12, 15, -1, -1], [0.7, 0.3, 0, 0],
        [12, 15, -1, -1], [0.9, 0.1, 0, 0]
      )
    ];
    const candidates: BoneClickCandidate[] = svc.inferCandidates(hit, triangles);
    const ok: boolean = candidates.length === 2
      && candidates[0].nodeIndex === 12
      && candidates[0].vertexCount === 3
      && Math.abs(candidates[0].averageWeight - 0.8) < 0.01;
    return SurfaceBonePickingTest.buildResult(
      '04_SingleBoneDominant', ok,
      'len=' + candidates.length
      + ', first=' + (candidates.length > 0 ? candidates[0].nodeIndex : -1)
      + ', count=' + (candidates.length > 0 ? candidates[0].vertexCount : -1)
      + ', avg=' + (candidates.length > 0 ? candidates[0].averageWeight : -1)
    );
  }

  /** 5. 空 weights(全 0) */
  private static test05_EmptyWeights(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const hit: RayHitResult = createEmptyHitResult();
    hit.hit = true;
    hit.triangleIndex = 0;
    const triangles: WorldTriangle[] = [
      makeTriangle(
        [-1, -1, -1, -1], [0, 0, 0, 0],
        [-1, -1, -1, -1], [0, 0, 0, 0],
        [-1, -1, -1, -1], [0, 0, 0, 0]
      )
    ];
    const candidates: BoneClickCandidate[] = svc.inferCandidates(hit, triangles);
    return SurfaceBonePickingTest.buildResult(
      '05_EmptyWeights', candidates.length === 0, 'count=' + candidates.length
    );
  }

  /** 6. 非法 joint index 聚合行为(范围校验由调用方) */
  private static test06_InvalidJointIndex(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const hit: RayHitResult = createEmptyHitResult();
    hit.hit = true;
    hit.triangleIndex = 0;
    const triangles: WorldTriangle[] = [
      makeTriangle(
        [999, -1, -1, -1], [1.0, 0, 0, 0],
        [999, -1, -1, -1], [1.0, 0, 0, 0],
        [999, -1, -1, -1], [1.0, 0, 0, 0]
      )
    ];
    const candidates: BoneClickCandidate[] = svc.inferCandidates(hit, triangles);
    const ok: boolean = candidates.length === 1 && candidates[0].nodeIndex === 999;
    return SurfaceBonePickingTest.buildResult(
      '06_InvalidJointIndex', ok, 'count=' + candidates.length
    );
  }

  /** 7. Top5 排序(构造 6 个不同 Bone,验证最多 5 个且降序) */
  private static test07_Top5Sort(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const hit: RayHitResult = createEmptyHitResult();
    hit.hit = true;
    hit.triangleIndex = 0;
    const triangles: WorldTriangle[] = [
      makeTriangle(
        [1, 2, 3, 4], [0.3, 0.25, 0.2, 0.15],
        [5, 6, 1, 2], [0.05, 0.1, 0.5, 0.4],
        [3, 4, 5, 6], [0.3, 0.25, 0.2, 0.15]
      )
    ];
    const candidates: BoneClickCandidate[] = svc.inferCandidates(hit, triangles);
    const countOk: boolean = candidates.length <= 5;
    let sortOk: boolean = true;
    if (candidates.length < 2) {
      sortOk = false;
    } else {
      sortOk = candidates[0].score >= candidates[1].score;
    }
    return SurfaceBonePickingTest.buildResult(
      '07_Top5Sort', countOk && sortOk,
      'count=' + candidates.length
      + ', s0=' + (candidates.length > 0 ? candidates[0].score : -1)
      + ', s1=' + (candidates.length > 1 ? candidates[1].score : -1)
    );
  }

  /** 8. 重复 Bone 聚合 */
  private static test08_DuplicateBoneAggregate(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const hit: RayHitResult = createEmptyHitResult();
    hit.hit = true;
    hit.triangleIndex = 0;
    const triangles: WorldTriangle[] = [
      makeTriangle(
        [7, 8, -1, -1], [0.6, 0.4, 0, 0],
        [7, 8, -1, -1], [0.5, 0.5, 0, 0],
        [7, 8, -1, -1], [0.7, 0.3, 0, 0]
      )
    ];
    const candidates: BoneClickCandidate[] = svc.inferCandidates(hit, triangles);
    const ok: boolean = candidates.length > 0
      && candidates[0].nodeIndex === 7
      && candidates[0].vertexCount === 3
      && Math.abs(candidates[0].totalWeight - 1.8) < 0.01;
    return SurfaceBonePickingTest.buildResult(
      '08_DuplicateBoneAggregate', ok,
      'node=' + (candidates.length > 0 ? candidates[0].nodeIndex : -1)
      + ', count=' + (candidates.length > 0 ? candidates[0].vertexCount : -1)
      + ', total=' + (candidates.length > 0 ? candidates[0].totalWeight : -1)
    );
  }

  /** 9. screenToWorldRay 中心射线方向 */
  private static test09_ScreenToWorldRayCenter(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const input: SurfacePickingInput = {
      screenX: 500, screenY: 500,
      viewportWidth: 1000, viewportHeight: 1000,
      cameraPosX: 0, cameraPosY: 0, cameraPosZ: 10,
      cameraTargetX: 0, cameraTargetY: 0, cameraTargetZ: 0,
      cameraFovDeg: 45, cameraNear: 0.1, cameraFar: 100
    };
    const ray: Ray3D = svc.screenToWorldRay(input);
    const dirOk: boolean = ray.dirZ < -0.9;
    const originOk: boolean = ray.originX === 0 && ray.originY === 0 && ray.originZ === 10;
    return SurfaceBonePickingTest.buildResult(
      '09_ScreenToWorldRayCenter', dirOk && originOk,
      'dirZ=' + ray.dirZ + ', origin=' + ray.originX + ',' + ray.originY + ',' + ray.originZ
    );
  }

  /** 10. setModelTransform + invalidate 缓存行为 */
  private static test10_InvalidateCache(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    svc.setModelTransform(2.0, 1, 2, 3, 10, 20, 30);
    svc.invalidate();
    const notPrepared: boolean = !svc.isPrepared();
    const triCountZero: boolean = svc.getTriangleCount() === 0;
    return SurfaceBonePickingTest.buildResult(
      '10_InvalidateCache', notPrepared && triCountZero,
      'prepared=' + !notPrepared + ', triCount=' + svc.getTriangleCount()
    );
  }

  /** 11. 未预处理时 pickBone 返回空 */
  private static test11_PickBoneWithoutPrepare(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const input: SurfacePickingInput = {
      screenX: 500, screenY: 500,
      viewportWidth: 1000, viewportHeight: 1000,
      cameraPosX: 0, cameraPosY: 0, cameraPosZ: 10,
      cameraTargetX: 0, cameraTargetY: 0, cameraTargetZ: 0,
      cameraFovDeg: 45, cameraNear: 0.1, cameraFar: 100
    };
    const candidates: BoneClickCandidate[] = svc.pickBone(input);
    return SurfaceBonePickingTest.buildResult(
      '11_PickBoneWithoutPrepare', candidates.length === 0,
      'count=' + candidates.length
    );
  }

  /** 12. 未命中时 inferCandidates 返回空 */
  private static test12_InferCandidatesNoHit(): SurfacePickingTestResult {
    const svc: SurfaceBonePickingService = new SurfaceBonePickingService();
    const hit: RayHitResult = createEmptyHitResult();
    hit.hit = false;
    hit.triangleIndex = -1;
    const triangles: WorldTriangle[] = [
      makeTriangle(
        [1, -1, -1, -1], [1.0, 0, 0, 0],
        [1, -1, -1, -1], [1.0, 0, 0, 0],
        [1, -1, -1, -1], [1.0, 0, 0, 0]
      )
    ];
    const candidates: BoneClickCandidate[] = svc.inferCandidates(hit, triangles);
    return SurfaceBonePickingTest.buildResult(
      '12_InferCandidatesNoHit', candidates.length === 0,
      'count=' + candidates.length
    );
  }
}
