/**
 * ModelVisibility 模型可见性诊断
 *
 * T-3D.6E P0: 查清并修复"模型导入成功但不可见"
 *
 * 职责:
 * - 定义 ModelVisibilityIssue 枚举(27 种不可见原因)
 * - 定义 ModelVisibilityReport 接口
 * - 提供 analyzeModelVisibility 函数,根据 Scene 状态/Bounds/相机参数推断不可见原因
 * - 输出 suggestedAction 用户建议
 * - 不依赖 ArkUI / ArkGraphics3D,纯逻辑可单元测试
 *
 * 不修改原模型文件,不掩盖问题,只输出诊断结论。
 */

import { ModelBounds } from './ModelBounds';

/**
 * T-3D.6E: 模型不可见原因枚举。
 */
export enum ModelVisibilityIssue {
  /** 无问题,模型可见 */
  None = 0,
  /** Scene 未选择 */
  SceneNotSelected = 1,
  /** Scene 根节点未挂载 */
  SceneRootNotAttached = 2,
  /** 模型根节点未挂载 */
  ModelRootNotAttached = 3,
  /** 没有可渲染 mesh */
  NoRenderableMesh = 4,
  /** mesh 节点被隐藏 */
  MeshNodesHidden = 5,
  /** 节点 transform 非法 */
  InvalidNodeTransform = 6,
  /** world matrix 非法 */
  InvalidWorldMatrix = 7,
  /** Bounds 非法 */
  InvalidBounds = 8,
  /** Bounds 为零尺寸 */
  ZeroBounds = 9,
  /** Bounds 在错误空间计算 */
  BoundsCalculatedInWrongSpace = 10,
  /** 原点远离几何中心 */
  OriginFarFromGeometry = 11,
  /** 模型过小 */
  ModelTooSmall = 12,
  /** 模型过大 */
  ModelTooLarge = 13,
  /** 相机未朝向模型 */
  CameraNotFacingModel = 14,
  /** 相机进入模型内部 */
  CameraInsideModel = 15,
  /** near plane 裁剪 */
  NearPlaneClipping = 16,
  /** far plane 裁剪 */
  FarPlaneClipping = 17,
  /** scale 被应用两次 */
  ScaleAppliedTwice = 18,
  /** scale 未应用 */
  ScaleNotApplied = 19,
  /** offset 被应用两次 */
  OffsetAppliedTwice = 20,
  /** 材质完全透明 */
  MaterialFullyTransparent = 21,
  /** 背面剔除 */
  BackFaceCulled = 22,
  /** 负 scale 导致 winding 反转 */
  NegativeScaleWinding = 23,
  /** 不支持的材质 */
  UnsupportedMaterial = 24,
  /** skin 矩阵非法 */
  InvalidSkinMatrices = 25,
  /** joint 权重非法 */
  InvalidJointWeights = 26,
  /** 动画把模型移走 */
  AnimationMovedModelAway = 27,
  /** 量化 POSITION 不支持 */
  QuantizedPositionUnsupported = 28,
  /** ArkGraphics 节点未渲染 */
  ArkGraphicsNodeNotRendered = 29,
  /** 未知原因 */
  Unknown = 30
}

/**
 * T-3D.6E: 模型可见性诊断报告。
 */
export interface ModelVisibilityReport {
  /** 是否可见 */
  visible: boolean;
  /** 主要问题 */
  primaryIssue: ModelVisibilityIssue;
  /** 次要问题列表 */
  secondaryIssues: ModelVisibilityIssue[];
  /** 可渲染 mesh 数量 */
  renderableMeshCount: number;
  /** 可见 mesh 数量 */
  visibleMeshCount: number;
  /** Bounds 是否有效 */
  boundsValid: boolean;
  /** Bounds 中心(模型坐标) */
  boundsCenter: Vec3;
  /** Bounds 半径 */
  boundsRadius: number;
  /** 相机距离 */
  cameraDistance: number;
  /** 建议操作 */
  suggestedAction: string;
  /** 警告列表 */
  warnings: string[];
}

/**
 * 3D 向量。
 */
export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

/**
 * analyzeModelVisibility 输入参数。
 */
export interface ModelVisibilityInput {
  /** 模型 Bounds(可为 null) */
  bounds: ModelBounds | null;
  /** Scene 是否已创建 */
  sceneCreated: boolean;
  /** Scene 根节点是否已挂载(ArkGraphics scene.root 是否非 null) */
  sceneRootAttached: boolean;
  /** ModelRoot 是否已挂载 */
  modelRootAttached: boolean;
  /** 可渲染 mesh 数量(primitiveCount 或 meshCount) */
  renderableMeshCount: number;
  /** 可见 mesh 数量(未被隐藏) */
  visibleMeshCount: number;
  /** 是否存在节点 transform 非法 */
  hasInvalidNodeTransform: boolean;
  /** 是否存在动画把模型移走 */
  hasAnimationMovedModel: boolean;
  /** 相机距离 */
  cameraDistance: number;
  /** near plane */
  nearPlane: number;
  /** far plane */
  farPlane: number;
  /** 模型最终 scale */
  finalScale: number;
  /** 是否存在负 scale */
  hasNegativeScale: boolean;
  /** 是否应用了 scale */
  scaleApplied: boolean;
  /** 是否应用了 offset */
  offsetApplied: boolean;
  /** 是否检测到透明材质 */
  hasTransparentMaterial: boolean;
  /** 是否检测到背面剔除 */
  hasBackFaceCulling: boolean;
  /** 是否存在 skin 矩阵非法 */
  hasInvalidSkinMatrices: boolean;
  /** 是否存在 joint 权重非法 */
  hasInvalidJointWeights: boolean;
  /** 是否量化 POSITION */
  hasQuantizedPosition: boolean;
}

/**
 * T-3D.6E: 分析模型可见性并返回诊断报告。
 *
 * 诊断顺序:
 * 1. Scene/ModelRoot 挂载状态
 * 2. 可渲染 mesh 存在性
 * 3. Bounds 有效性
 * 4. 相机裁剪
 * 5. Scale/Offset 应用
 * 6. 材质/Skin/动画问题
 *
 * @param input 可见性诊断输入
 * @returns ModelVisibilityReport
 */
export function analyzeModelVisibility(input: ModelVisibilityInput): ModelVisibilityReport {
  const report: ModelVisibilityReport = {
    visible: true,
    primaryIssue: ModelVisibilityIssue.None,
    secondaryIssues: [],
    renderableMeshCount: input.renderableMeshCount,
    visibleMeshCount: input.visibleMeshCount,
    boundsValid: input.bounds !== null,
    boundsCenter: input.bounds !== null
      ? { x: input.bounds.centerX, y: input.bounds.centerY, z: input.bounds.centerZ }
      : { x: 0, y: 0, z: 0 },
    boundsRadius: input.bounds !== null ? input.bounds.radius : 0,
    cameraDistance: input.cameraDistance,
    suggestedAction: '',
    warnings: []
  };

  // 1. Scene/ModelRoot 检查
  if (!input.sceneCreated) {
    report.visible = false;
    report.primaryIssue = ModelVisibilityIssue.SceneNotSelected;
    report.suggestedAction = 'Scene 未创建,请检查 GLB 文件是否包含有效 scene。';
    return report;
  }
  if (!input.sceneRootAttached) {
    report.visible = false;
    report.primaryIssue = ModelVisibilityIssue.SceneRootNotAttached;
    report.suggestedAction = 'Scene 根节点未挂载,请检查 ArkGraphics scene.root 是否有效。';
    return report;
  }
  if (!input.modelRootAttached) {
    report.visible = false;
    report.primaryIssue = ModelVisibilityIssue.ModelRootNotAttached;
    report.suggestedAction = '模型根节点未挂载到 Scene,请点击"适配视图"重新定位。';
    return report;
  }

  // 2. 可渲染 mesh 检查
  if (input.renderableMeshCount === 0) {
    report.visible = false;
    report.primaryIssue = ModelVisibilityIssue.NoRenderableMesh;
    report.suggestedAction = '模型无可渲染几何,请检查 GLB 是否包含 mesh primitive。';
    return report;
  }
  if (input.visibleMeshCount === 0 && input.renderableMeshCount > 0) {
    report.visible = false;
    report.primaryIssue = ModelVisibilityIssue.MeshNodesHidden;
    report.suggestedAction = '所有 mesh 节点被隐藏,请检查节点 visible 字段。';
    return report;
  }

  // 3. 节点 transform 非法
  if (input.hasInvalidNodeTransform) {
    report.secondaryIssues.push(ModelVisibilityIssue.InvalidNodeTransform);
    report.warnings.push('检测到节点 transform 非法(NaN/Infinity),已跳过该节点。');
  }

  // 4. Bounds 有效性
  if (input.bounds === null) {
    report.secondaryIssues.push(ModelVisibilityIssue.InvalidBounds);
    report.warnings.push('模型 Bounds 无效(POSITION accessor 缺失 min/max),使用默认配置。');
    report.suggestedAction = 'Bounds 无效,使用默认配置。点击"适配视图"尝试重新计算。';
  } else {
    const b: ModelBounds = input.bounds;
    // 检查极小/极大
    if (b.radius < 1e-3) {
      report.secondaryIssues.push(ModelVisibilityIssue.ModelTooSmall);
      report.warnings.push('模型尺寸极小(radius=' + b.radius.toFixed(6) + '),已自动适配。');
    }
    if (b.radius > 1e5) {
      report.secondaryIssues.push(ModelVisibilityIssue.ModelTooLarge);
      report.warnings.push('模型尺寸极大(radius=' + b.radius.toFixed(3) + '),已自动适配。');
    }
    // 原点远离几何中心
    const centerLen: number = Math.sqrt(b.centerX * b.centerX + b.centerY * b.centerY + b.centerZ * b.centerZ);
    if (Number.isFinite(centerLen) && b.radius > 0 && centerLen / b.radius >= 10) {
      report.secondaryIssues.push(ModelVisibilityIssue.OriginFarFromGeometry);
      report.warnings.push('模型原点距离几何中心较远,查看时已自动居中。');
    }
  }

  // 5. 相机裁剪检查
  if (input.bounds !== null) {
    const r: number = input.bounds.radius * input.finalScale;
    const dist: number = input.cameraDistance;
    if (Number.isFinite(dist) && Number.isFinite(r) && r > 0) {
      // near plane 裁剪:相机进入模型或近切面切掉模型
      if (dist - r < input.nearPlane) {
        report.secondaryIssues.push(ModelVisibilityIssue.NearPlaneClipping);
        report.warnings.push('模型可能被 near plane 裁剪(near=' + input.nearPlane
          + ', dist-r=' + (dist - r).toFixed(3) + ')。');
      }
      // far plane 裁剪:模型超出 far plane
      if (dist + r > input.farPlane) {
        report.secondaryIssues.push(ModelVisibilityIssue.FarPlaneClipping);
        report.warnings.push('模型可能被 far plane 裁剪(far=' + input.farPlane
          + ', dist+r=' + (dist + r).toFixed(3) + ')。');
      }
      // 相机进入模型
      if (dist < r * 0.5) {
        report.secondaryIssues.push(ModelVisibilityIssue.CameraInsideModel);
        report.warnings.push('相机可能进入模型内部(dist=' + dist.toFixed(3) + ', r=' + r.toFixed(3) + ')。');
      }
    }
  }

  // 6. Scale/Offset 应用检查
  if (!input.scaleApplied) {
    report.secondaryIssues.push(ModelVisibilityIssue.ScaleNotApplied);
    report.warnings.push('scale 未应用到模型,可能导致模型过小或过大。');
  }
  if (input.hasNegativeScale) {
    report.secondaryIssues.push(ModelVisibilityIssue.NegativeScaleWinding);
    report.warnings.push('检测到负 scale,可能导致 winding 反,模型背面被剔除。');
  }

  // 7. 材质问题
  if (input.hasTransparentMaterial) {
    report.secondaryIssues.push(ModelVisibilityIssue.MaterialFullyTransparent);
    report.warnings.push('检测到透明材质,可能模型完全透明。');
  }
  if (input.hasBackFaceCulling) {
    report.secondaryIssues.push(ModelVisibilityIssue.BackFaceCulled);
    report.warnings.push('检测到背面剔除,可能模型被剔除。');
  }

  // 8. Skin 问题
  if (input.hasInvalidSkinMatrices) {
    report.secondaryIssues.push(ModelVisibilityIssue.InvalidSkinMatrices);
    report.warnings.push('检测到 skin 矩阵非法,蒙皮可能渲染异常。');
  }
  if (input.hasInvalidJointWeights) {
    report.secondaryIssues.push(ModelVisibilityIssue.InvalidJointWeights);
    report.warnings.push('检测到 joint 权重非法,蒙皮可能渲染异常。');
  }

  // 9. 动画问题
  if (input.hasAnimationMovedModel) {
    report.secondaryIssues.push(ModelVisibilityIssue.AnimationMovedModelAway);
    report.warnings.push('检测到动画可能把模型移出视野,导入后默认显示 rest pose。');
  }

  // 10. 量化 POSITION
  if (input.hasQuantizedPosition) {
    report.secondaryIssues.push(ModelVisibilityIssue.QuantizedPositionUnsupported);
    report.warnings.push('检测到量化 POSITION,若 ArkGraphics 不支持可能导致渲染异常。');
  }

  // 设置 suggestedAction
  if (report.primaryIssue === ModelVisibilityIssue.None && report.secondaryIssues.length > 0) {
    report.suggestedAction = '点击"适配视图"重新定位,或打开"加载诊断"查看原因。';
  } else if (report.primaryIssue === ModelVisibilityIssue.None) {
    report.suggestedAction = '';
  }

  return report;
}

/**
 * 将 ModelVisibilityIssue 转为用户可读文案。
 */
export function getVisibilityIssueText(issue: ModelVisibilityIssue): string {
  switch (issue) {
    case ModelVisibilityIssue.None: return '无问题';
    case ModelVisibilityIssue.SceneNotSelected: return 'Scene 未选择';
    case ModelVisibilityIssue.SceneRootNotAttached: return 'Scene 根节点未挂载';
    case ModelVisibilityIssue.ModelRootNotAttached: return '模型根节点未挂载';
    case ModelVisibilityIssue.NoRenderableMesh: return '无可渲染 mesh';
    case ModelVisibilityIssue.MeshNodesHidden: return 'mesh 节点被隐藏';
    case ModelVisibilityIssue.InvalidNodeTransform: return '节点 transform 非法';
    case ModelVisibilityIssue.InvalidWorldMatrix: return 'world matrix 非法';
    case ModelVisibilityIssue.InvalidBounds: return 'Bounds 非法';
    case ModelVisibilityIssue.ZeroBounds: return 'Bounds 为零尺寸';
    case ModelVisibilityIssue.BoundsCalculatedInWrongSpace: return 'Bounds 在错误空间计算';
    case ModelVisibilityIssue.OriginFarFromGeometry: return '原点远离几何中心';
    case ModelVisibilityIssue.ModelTooSmall: return '模型过小';
    case ModelVisibilityIssue.ModelTooLarge: return '模型过大';
    case ModelVisibilityIssue.CameraNotFacingModel: return '相机未朝向模型';
    case ModelVisibilityIssue.CameraInsideModel: return '相机进入模型内部';
    case ModelVisibilityIssue.NearPlaneClipping: return 'near plane 裁剪';
    case ModelVisibilityIssue.FarPlaneClipping: return 'far plane 裁剪';
    case ModelVisibilityIssue.ScaleAppliedTwice: return 'scale 被应用两次';
    case ModelVisibilityIssue.ScaleNotApplied: return 'scale 未应用';
    case ModelVisibilityIssue.OffsetAppliedTwice: return 'offset 被应用两次';
    case ModelVisibilityIssue.MaterialFullyTransparent: return '材质完全透明';
    case ModelVisibilityIssue.BackFaceCulled: return '背面剔除';
    case ModelVisibilityIssue.NegativeScaleWinding: return '负 scale 导致 winding 反转';
    case ModelVisibilityIssue.UnsupportedMaterial: return '不支持的材质';
    case ModelVisibilityIssue.InvalidSkinMatrices: return 'skin 矩阵非法';
    case ModelVisibilityIssue.InvalidJointWeights: return 'joint 权重非法';
    case ModelVisibilityIssue.AnimationMovedModelAway: return '动画把模型移走';
    case ModelVisibilityIssue.QuantizedPositionUnsupported: return '量化 POSITION 不支持';
    case ModelVisibilityIssue.ArkGraphicsNodeNotRendered: return 'ArkGraphics 节点未渲染';
    case ModelVisibilityIssue.Unknown: return '未知原因';
    default: return '';
  }
}
