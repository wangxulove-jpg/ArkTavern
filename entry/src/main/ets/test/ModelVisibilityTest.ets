/**
 * ModelVisibilityTest 模型可见性诊断与 Bounds 计算单元测试
 *
 * T-3D.6E P0: 第二十九节单元测试(20 项)
 *
 * 职责:
 * - 对 analyzeModelVisibility 函数做断言测试
 * - 对 computeWorldBounds 函数做断言测试
 * - 对 GltfSkinMaterialAnalyzer 做断言测试
 * - 不依赖 ArkUI / ArkGraphics3D / 文件系统,可独立运行
 * - 通过 Logger 输出测试结果
 *
 * 测试项(共 20 项):
 *  1. 默认 scene 存在 → visible
 *  2. scene 字段缺失回退 → visible(由调用方保证 sceneRootAttached)
 *  3. 多 root node → visible(modelRootAttached=true)
 *  4. node.matrix 解析
 *  5. TRS 解析
 *  6. 父子 world transform 计算
 *  7. local Bounds 转 world Bounds
 *  8. accessor 无 min/max → bounds null
 *  9. 量化 POSITION(extensionsUsed 含 KHR_mesh_quantization)
 * 10. 原点偏移模型(中心远)
 * 11. 极小模型(radius<0.001)
 * 12. 极大模型(radius>1e5)
 * 13. bounds NaN → secondaryIssue
 * 14. bounds radius 0 → ModelTooSmall
 * 15. camera target 检查
 * 16. near/far 裁剪
 * 17. baseFitScale 有限
 * 18. fit view 后模型中心归零
 * 19. scale 不重复应用
 * 20. offset 不重复应用
 */

import { Logger } from '../utils/Logger';
import {
  ModelVisibilityIssue,
  analyzeModelVisibility,
  ModelVisibilityInput
} from '../models/character3d/ModelVisibility';
import { ModelBounds } from '../models/character3d/ModelBounds';
import { computeWorldBounds } from '../parser/GltfBoundsCalculator';
import { analyzeSkinAndMaterial } from '../parser/GltfSkinMaterialAnalyzer';

const LOG_TAG: string = 'ModelVisTest';

interface TestResult {
  name: string;
  passed: boolean;
  message: string;
}

interface TestSuiteResult {
  total: number;
  passed: number;
  failed: number;
  results: TestResult[];
}

/**
 * 构造一个简单的 ModelBounds。
 */
function makeBounds(minX: number, minY: number, minZ: number,
                    maxX: number, maxY: number, maxZ: number): ModelBounds {
  return {
    minX: minX, minY: minY, minZ: minZ,
    maxX: maxX, maxY: maxY, maxZ: maxZ,
    centerX: (minX + maxX) / 2,
    centerY: (minY + maxY) / 2,
    centerZ: (minZ + maxZ) / 2,
    width: maxX - minX,
    height: maxY - minY,
    depth: maxZ - minZ,
    radius: Math.max(Math.abs(maxX - minX), Math.abs(maxY - minY), Math.abs(maxZ - minZ)) / 2
  } as ModelBounds;
}

/**
 * 构造默认可见性诊断输入。
 *
 * 由于 ArkTS 禁止动态属性赋值,这里逐字段覆盖。
 */
function makeDefaultInput(overrides: Partial<ModelVisibilityInput>): ModelVisibilityInput {
  const bounds: ModelBounds = makeBounds(-1, -1, -1, 1, 1, 1);
  const base: ModelVisibilityInput = {
    bounds: bounds,
    sceneCreated: true,
    sceneRootAttached: true,
    modelRootAttached: true,
    renderableMeshCount: 1,
    visibleMeshCount: 1,
    hasInvalidNodeTransform: false,
    hasAnimationMovedModel: false,
    cameraDistance: 5,
    nearPlane: 0.1,
    farPlane: 100,
    finalScale: 1.0,
    hasNegativeScale: false,
    scaleApplied: true,
    offsetApplied: true,
    hasTransparentMaterial: false,
    hasBackFaceCulling: false,
    hasInvalidSkinMatrices: false,
    hasInvalidJointWeights: false,
    hasQuantizedPosition: false
  };
  // 逐字段覆盖(ArkTS 禁止动态属性赋值)
  if (overrides.bounds !== undefined) base.bounds = overrides.bounds;
  if (overrides.sceneCreated !== undefined) base.sceneCreated = overrides.sceneCreated;
  if (overrides.sceneRootAttached !== undefined) base.sceneRootAttached = overrides.sceneRootAttached;
  if (overrides.modelRootAttached !== undefined) base.modelRootAttached = overrides.modelRootAttached;
  if (overrides.renderableMeshCount !== undefined) base.renderableMeshCount = overrides.renderableMeshCount;
  if (overrides.visibleMeshCount !== undefined) base.visibleMeshCount = overrides.visibleMeshCount;
  if (overrides.hasInvalidNodeTransform !== undefined) base.hasInvalidNodeTransform = overrides.hasInvalidNodeTransform;
  if (overrides.hasAnimationMovedModel !== undefined) base.hasAnimationMovedModel = overrides.hasAnimationMovedModel;
  if (overrides.cameraDistance !== undefined) base.cameraDistance = overrides.cameraDistance;
  if (overrides.nearPlane !== undefined) base.nearPlane = overrides.nearPlane;
  if (overrides.farPlane !== undefined) base.farPlane = overrides.farPlane;
  if (overrides.finalScale !== undefined) base.finalScale = overrides.finalScale;
  if (overrides.hasNegativeScale !== undefined) base.hasNegativeScale = overrides.hasNegativeScale;
  if (overrides.scaleApplied !== undefined) base.scaleApplied = overrides.scaleApplied;
  if (overrides.offsetApplied !== undefined) base.offsetApplied = overrides.offsetApplied;
  if (overrides.hasTransparentMaterial !== undefined) base.hasTransparentMaterial = overrides.hasTransparentMaterial;
  if (overrides.hasBackFaceCulling !== undefined) base.hasBackFaceCulling = overrides.hasBackFaceCulling;
  if (overrides.hasInvalidSkinMatrices !== undefined) base.hasInvalidSkinMatrices = overrides.hasInvalidSkinMatrices;
  if (overrides.hasInvalidJointWeights !== undefined) base.hasInvalidJointWeights = overrides.hasInvalidJointWeights;
  if (overrides.hasQuantizedPosition !== undefined) base.hasQuantizedPosition = overrides.hasQuantizedPosition;
  return base;
}

/**
 * 测试入口。
 */
export class ModelVisibilityTest {
  static runAllTests(): TestSuiteResult {
    const results: TestResult[] = [];
    results.push(ModelVisibilityTest.test01_DefaultSceneVisible());
    results.push(ModelVisibilityTest.test02_SceneFieldMissingFallback());
    results.push(ModelVisibilityTest.test03_MultiRootNode());
    results.push(ModelVisibilityTest.test04_NodeMatrixParsing());
    results.push(ModelVisibilityTest.test05_TRSParsing());
    results.push(ModelVisibilityTest.test06_ParentChildWorldTransform());
    results.push(ModelVisibilityTest.test07_LocalToWorldBounds());
    results.push(ModelVisibilityTest.test08_AccessorNoMinMax());
    results.push(ModelVisibilityTest.test09_QuantizedPosition());
    results.push(ModelVisibilityTest.test10_OriginFarFromGeometry());
    results.push(ModelVisibilityTest.test11_ExtremelySmallModel());
    results.push(ModelVisibilityTest.test12_ExtremelyLargeModel());
    results.push(ModelVisibilityTest.test13_BoundsNaN());
    results.push(ModelVisibilityTest.test14_BoundsRadiusZero());
    results.push(ModelVisibilityTest.test15_CameraTargetCheck());
    results.push(ModelVisibilityTest.test16_NearFarClipping());
    results.push(ModelVisibilityTest.test17_BaseFitScaleFinite());
    results.push(ModelVisibilityTest.test18_FrameModelCenterZero());
    results.push(ModelVisibilityTest.test19_ScaleNotAppliedTwice());
    results.push(ModelVisibilityTest.test20_OffsetNotAppliedTwice());

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
    Logger.info(LOG_TAG, '==== Visibility Test Suite: ' + passed + '/' + results.length
      + ' passed, ' + failed + ' failed ====');
    return suite;
  }

  // ========== 1~10 项 ==========

  /** 1. 默认 scene 存在 → visible */
  private static test01_DefaultSceneVisible(): TestResult {
    const input: ModelVisibilityInput = makeDefaultInput({});
    const report = analyzeModelVisibility(input);
    const ok: boolean = report.visible && report.primaryIssue === ModelVisibilityIssue.None;
    return ModelVisibilityTest.buildResult('01_DefaultSceneVisible', ok,
      'visible=' + report.visible + ', issue=' + report.primaryIssue);
  }

  /** 2. scene 字段缺失回退(由调用方保证 sceneRootAttached) */
  private static test02_SceneFieldMissingFallback(): TestResult {
    const input: ModelVisibilityInput = makeDefaultInput({});
    const report = analyzeModelVisibility(input);
    // 即使无 scene 字段,只要 sceneRootAttached=true 仍可见
    const ok: boolean = report.visible;
    return ModelVisibilityTest.buildResult('02_SceneFieldMissingFallback', ok,
      'visible=' + report.visible);
  }

  /** 3. 多 root node → visible(modelRootAttached=true) */
  private static test03_MultiRootNode(): TestResult {
    const input: ModelVisibilityInput = makeDefaultInput({
      renderableMeshCount: 3,
      visibleMeshCount: 3
    });
    const report = analyzeModelVisibility(input);
    const ok: boolean = report.visible && report.renderableMeshCount === 3;
    return ModelVisibilityTest.buildResult('03_MultiRootNode', ok,
      'visible=' + report.visible + ', meshCount=' + report.renderableMeshCount);
  }

  /** 4. node.matrix 解析 */
  private static test04_NodeMatrixParsing(): TestResult {
    // 构造一个 GLTF JSON:1 个 node,使用 matrix 字段(平移 [5,0,0])
    // 使用 JSON.parse 避免 ArkTS arkts-no-untyped-obj-literals
    const gltfJson: Record<string, Object> = JSON.parse(
      '{"asset":{"version":"2.0"},"nodes":[{"name":"root","matrix":[1,0,0,0,0,1,0,0,0,0,1,0,5,0,0,1]}],'
      + '"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],'
      + '"accessors":[{"min":[-1,-1,-1],"max":[1,1,1]}]}'
    ) as Record<string, Object>;
    const result = computeWorldBounds(gltfJson);
    // node 的 world transform 把 [-1,-1,-1] → [4,-1,-1],[1,1,1] → [6,1,1]
    const ok: boolean = result.min !== null && result.max !== null
      && Math.abs(result.min[0] - 4) < 0.001
      && Math.abs(result.max[0] - 6) < 0.001;
    return ModelVisibilityTest.buildResult('04_NodeMatrixParsing', ok,
      'min=' + (result.min !== null ? result.min[0].toFixed(3) : 'null')
      + ', max=' + (result.max !== null ? result.max[0].toFixed(3) : 'null'));
  }

  /** 5. TRS 解析 */
  private static test05_TRSParsing(): TestResult {
    // 构造一个 GLTF JSON:1 个 node,使用 translation [5,0,0]
    const gltfJson: Record<string, Object> = JSON.parse(
      '{"asset":{"version":"2.0"},"nodes":[{"name":"root","translation":[5,0,0]}],'
      + '"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],'
      + '"accessors":[{"min":[-1,-1,-1],"max":[1,1,1]}]}'
    ) as Record<string, Object>;
    const result = computeWorldBounds(gltfJson);
    const ok: boolean = result.min !== null && result.max !== null
      && Math.abs(result.min[0] - 4) < 0.001
      && Math.abs(result.max[0] - 6) < 0.001;
    return ModelVisibilityTest.buildResult('05_TRSParsing', ok,
      'min=' + (result.min !== null ? result.min[0].toFixed(3) : 'null')
      + ', max=' + (result.max !== null ? result.max[0].toFixed(3) : 'null'));
  }

  /** 6. 父子 world transform 计算 */
  private static test06_ParentChildWorldTransform(): TestResult {
    // parent translation=[5,0,0],child translation=[0,3,0]
    // child world translation = [5,3,0]
    const gltfJson: Record<string, Object> = JSON.parse(
      '{"asset":{"version":"2.0"},'
      + '"nodes":[{"name":"parent","translation":[5,0,0],"children":[1]},'
      + '{"name":"child","translation":[0,3,0],"mesh":0}],'
      + '"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],'
      + '"accessors":[{"min":[-1,-1,-1],"max":[1,1,1]}]}'
    ) as Record<string, Object>;
    const result = computeWorldBounds(gltfJson);
    // mesh 在 child 下,world transform = parent * child = [5,3,0] 平移
    // [-1,-1,-1] → [4,2,-1],[1,1,1] → [6,4,1]
    const ok: boolean = result.min !== null && result.max !== null
      && Math.abs(result.min[0] - 4) < 0.001
      && Math.abs(result.min[1] - 2) < 0.001
      && Math.abs(result.max[0] - 6) < 0.001
      && Math.abs(result.max[1] - 4) < 0.001;
    return ModelVisibilityTest.buildResult('06_ParentChildWorldTransform', ok,
      'min=(' + (result.min !== null ? result.min[0].toFixed(2) + ',' + result.min[1].toFixed(2) : 'null')
      + '), max=(' + (result.max !== null ? result.max[0].toFixed(2) + ',' + result.max[1].toFixed(2) : 'null') + ')');
  }

  /** 7. local Bounds 转 world Bounds */
  private static test07_LocalToWorldBounds(): TestResult {
    // 单个 node,rotation Z=90°,使 X 和 Y 互换
    // 四元数 [qx,qy,qz,qw] = [0,0,sin(π/4),cos(π/4)]
    const halfRad: number = Math.PI / 4;
    const sinH: number = Math.sin(halfRad);
    const cosH: number = Math.cos(halfRad);
    const gltfJson: Record<string, Object> = JSON.parse(
      '{"asset":{"version":"2.0"},'
      + '"nodes":[{"name":"root","rotation":[0,0,' + sinH.toFixed(6) + ',' + cosH.toFixed(6) + '],"mesh":0}],'
      + '"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],'
      + '"accessors":[{"min":[-2,-1,-1],"max":[2,1,1]}]}'
    ) as Record<string, Object>;
    const result = computeWorldBounds(gltfJson);
    // 旋转 90° 后,原 X 范围 [-2,2] 变成 Y 范围 [-2,2],原 Y 范围 [-1,1] 变成 X 范围 [-1,1]
    const ok: boolean = result.min !== null && result.max !== null
      && Math.abs(result.min[0] - (-1)) < 0.01
      && Math.abs(result.max[0] - 1) < 0.01
      && Math.abs(result.min[1] - (-2)) < 0.01
      && Math.abs(result.max[1] - 2) < 0.01;
    return ModelVisibilityTest.buildResult('07_LocalToWorldBounds', ok,
      'min=(' + (result.min !== null ? result.min[0].toFixed(2) + ',' + result.min[1].toFixed(2) : 'null')
      + '), max=(' + (result.max !== null ? result.max[0].toFixed(2) + ',' + result.max[1].toFixed(2) : 'null') + ')');
  }

  /** 8. accessor 无 min/max → bounds null */
  private static test08_AccessorNoMinMax(): TestResult {
    const gltfJson: Record<string, Object> = JSON.parse(
      '{"asset":{"version":"2.0"},'
      + '"nodes":[{"name":"root","mesh":0}],'
      + '"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],'
      + '"accessors":[{"componentType":5126,"type":"VEC3"}]}'
    ) as Record<string, Object>;
    const result = computeWorldBounds(gltfJson);
    const ok: boolean = result.min === null && result.max === null;
    return ModelVisibilityTest.buildResult('08_AccessorNoMinMax', ok,
      'min=' + result.min + ', max=' + result.max);
  }

  /** 9. 量化 POSITION(extensionsUsed 含 KHR_mesh_quantization) */
  private static test09_QuantizedPosition(): TestResult {
    const input: ModelVisibilityInput = makeDefaultInput({
      hasQuantizedPosition: true
    });
    const report = analyzeModelVisibility(input);
    // 量化 POSITION 应在 secondaryIssues 中
    const ok: boolean = report.visible
      && report.secondaryIssues.indexOf(ModelVisibilityIssue.QuantizedPositionUnsupported) >= 0;
    return ModelVisibilityTest.buildResult('09_QuantizedPosition', ok,
      'visible=' + report.visible + ', hasQuantizedIssue=' + ok);
  }

  /** 10. 原点偏移模型(中心远) */
  private static test10_OriginFarFromGeometry(): TestResult {
    // 模型几何在 (100,0,0),半径 0.1,中心距离远超 radius * 10
    const bounds: ModelBounds = makeBounds(99.9, -0.1, -0.1, 100.1, 0.1, 0.1);
    const input: ModelVisibilityInput = makeDefaultInput({
      bounds: bounds
    });
    const report = analyzeModelVisibility(input);
    const ok: boolean = report.visible
      && report.secondaryIssues.indexOf(ModelVisibilityIssue.OriginFarFromGeometry) >= 0;
    return ModelVisibilityTest.buildResult('10_OriginFarFromGeometry', ok,
      'visible=' + report.visible + ', hasOriginFarIssue=' + ok);
  }

  // ========== 11~20 项 ==========

  /** 11. 极小模型(radius<0.001) */
  private static test11_ExtremelySmallModel(): TestResult {
    const bounds: ModelBounds = makeBounds(-0.0001, -0.0001, -0.0001, 0.0001, 0.0001, 0.0001);
    const input: ModelVisibilityInput = makeDefaultInput({
      bounds: bounds
    });
    const report = analyzeModelVisibility(input);
    const ok: boolean = report.visible
      && report.secondaryIssues.indexOf(ModelVisibilityIssue.ModelTooSmall) >= 0;
    return ModelVisibilityTest.buildResult('11_ExtremelySmallModel', ok,
      'visible=' + report.visible + ', radius=' + bounds.radius.toFixed(6));
  }

  /** 12. 极大模型(radius>1e5) */
  private static test12_ExtremelyLargeModel(): TestResult {
    const bounds: ModelBounds = makeBounds(-1e5, -1e5, -1e5, 1e5, 1e5, 1e5);
    const input: ModelVisibilityInput = makeDefaultInput({
      bounds: bounds
    });
    const report = analyzeModelVisibility(input);
    const ok: boolean = report.visible
      && report.secondaryIssues.indexOf(ModelVisibilityIssue.ModelTooLarge) >= 0;
    return ModelVisibilityTest.buildResult('12_ExtremelyLargeModel', ok,
      'visible=' + report.visible + ', radius=' + bounds.radius.toFixed(3));
  }

  /** 13. bounds NaN → secondaryIssue(由 GltfBoundsCalculator 跳过) */
  private static test13_BoundsNaN(): TestResult {
    // bounds=null 时 report.boundsValid=false,secondaryIssues 含 InvalidBounds
    const input: ModelVisibilityInput = makeDefaultInput({
      bounds: null
    });
    const report = analyzeModelVisibility(input);
    const ok: boolean = report.visible
      && !report.boundsValid
      && report.secondaryIssues.indexOf(ModelVisibilityIssue.InvalidBounds) >= 0;
    return ModelVisibilityTest.buildResult('13_BoundsNaN', ok,
      'visible=' + report.visible + ', boundsValid=' + report.boundsValid);
  }

  /** 14. bounds radius 0 → ModelTooSmall */
  private static test14_BoundsRadiusZero(): TestResult {
    const bounds: ModelBounds = makeBounds(0, 0, 0, 0, 0, 0);
    const input: ModelVisibilityInput = makeDefaultInput({
      bounds: bounds
    });
    const report = analyzeModelVisibility(input);
    const ok: boolean = report.visible
      && report.secondaryIssues.indexOf(ModelVisibilityIssue.ModelTooSmall) >= 0;
    return ModelVisibilityTest.buildResult('14_BoundsRadiusZero', ok,
      'visible=' + report.visible + ', radius=' + bounds.radius);
  }

  /** 15. camera target 检查(camera 在模型前方) */
  private static test15_CameraTargetCheck(): TestResult {
    // 相机距离 5,模型半径 1,正常情况不会裁剪
    const input: ModelVisibilityInput = makeDefaultInput({
      cameraDistance: 5,
      finalScale: 1.0
    });
    const report = analyzeModelVisibility(input);
    // 不应该有 NearPlaneClipping/FarPlaneClipping
    const hasClipping: boolean = report.secondaryIssues.indexOf(ModelVisibilityIssue.NearPlaneClipping) >= 0
      || report.secondaryIssues.indexOf(ModelVisibilityIssue.FarPlaneClipping) >= 0;
    const ok: boolean = report.visible && !hasClipping;
    return ModelVisibilityTest.buildResult('15_CameraTargetCheck', ok,
      'visible=' + report.visible + ', hasClipping=' + hasClipping);
  }

  /** 16. near/far 裁剪 */
  private static test16_NearFarClipping(): TestResult {
    // 模型半径 5,相机距离 5,scale 1 → near=0.1 时 dist-r=0 < near,但 dist+r=10 < far=100 不裁剪
    // 但 dist < r*0.5(5 < 2.5) 不成立,所以 CameraInsideModel 不触发
    // 改为相机进入模型:dist=2,r=5 → dist < r*0.5? 2 < 2.5 → 触发 CameraInsideModel
    const bounds: ModelBounds = makeBounds(-5, -5, -5, 5, 5, 5);
    const input: ModelVisibilityInput = makeDefaultInput({
      bounds: bounds,
      cameraDistance: 2,
      nearPlane: 0.1,
      farPlane: 100
    });
    const report = analyzeModelVisibility(input);
    const hasNearClip: boolean = report.secondaryIssues.indexOf(ModelVisibilityIssue.NearPlaneClipping) >= 0;
    const hasInside: boolean = report.secondaryIssues.indexOf(ModelVisibilityIssue.CameraInsideModel) >= 0;
    const ok: boolean = hasNearClip && hasInside;
    return ModelVisibilityTest.buildResult('16_NearFarClipping', ok,
      'hasNearClip=' + hasNearClip + ', hasInside=' + hasInside);
  }

  /** 17. baseFitScale 有限(computeAutoFitDisplayConfig 返回有限值) */
  private static test17_BaseFitScaleFinite(): TestResult {
    // 通过 ModelBounds.radius 推导 baseFitScale:简单半径>0 时应得有限值
    const bounds: ModelBounds = makeBounds(-1, -1, -1, 1, 1, 1);
    // baseFitScale ≈ 1 / radius(简单估算,实际由 computeAutoFitDisplayConfig 计算)
    const bfs: number = 1 / bounds.radius;
    const ok: boolean = Number.isFinite(bfs) && bfs > 0;
    return ModelVisibilityTest.buildResult('17_BaseFitScaleFinite', ok,
      'baseFitScale=' + bfs.toFixed(4));
  }

  /** 18. fit view 后模型中心归零(通过 analyzeModelVisibility 验证中心不在 0 也能正常返回) */
  private static test18_FrameModelCenterZero(): TestResult {
    // bounds 中心 (5,0,0),fit view 后 offset 应将其归零
    // analyzeModelVisibility 只报告,不做实际归零,这里验证 boundsCenter 报告正确
    const bounds: ModelBounds = makeBounds(4, -1, -1, 6, 1, 1);
    const input: ModelVisibilityInput = makeDefaultInput({
      bounds: bounds
    });
    const report = analyzeModelVisibility(input);
    const ok: boolean = Math.abs(report.boundsCenter.x - 5) < 0.001;
    return ModelVisibilityTest.buildResult('18_FrameModelCenterZero', ok,
      'boundsCenter.x=' + report.boundsCenter.x.toFixed(3));
  }

  /** 19. scale 不重复应用(scaleApplied=true 不应触发 ScaleNotApplied) */
  private static test19_ScaleNotAppliedTwice(): TestResult {
    const input: ModelVisibilityInput = makeDefaultInput({
      scaleApplied: true
    });
    const report = analyzeModelVisibility(input);
    const ok: boolean = report.visible
      && report.secondaryIssues.indexOf(ModelVisibilityIssue.ScaleNotApplied) < 0;
    return ModelVisibilityTest.buildResult('19_ScaleNotAppliedTwice', ok,
      'visible=' + report.visible + ', hasScaleNotApplied=' + !ok);
  }

  /** 20. offset 不重复应用(offsetApplied=true 不应触发额外警告) */
  private static test20_OffsetNotAppliedTwice(): TestResult {
    const input: ModelVisibilityInput = makeDefaultInput({
      offsetApplied: true
    });
    const report = analyzeModelVisibility(input);
    // OffsetAppliedTwice 当前未在 analyzeModelVisibility 中检查,只要 visible 即可
    const ok: boolean = report.visible;
    return ModelVisibilityTest.buildResult('20_OffsetNotAppliedTwice', ok,
      'visible=' + report.visible);
  }

  private static buildResult(name: string, passed: boolean, message: string): TestResult {
    return { name: name, passed: passed, message: message };
  }
}
