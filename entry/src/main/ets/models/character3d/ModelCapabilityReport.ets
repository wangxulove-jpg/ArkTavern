/**
 * ModelCapabilityReport 模型能力分层报告
 *
 * T-3D.6E P1: 彻底拆分"兼容"的含义
 * T-4.0: 新增 VRM 维度(Expression/LookAt/SpringBone/FirstPerson/MToon/VRM)
 *
 * 职责:
 * - 定义 CapabilityState 枚举(单一能力状态)
 * - 定义 HumanoidMappingState 枚举(人形映射状态)
 * - 定义 ModelCapabilityWarning 接口(分层警告)
 * - 定义 ModelCapabilityReport 接口(多维度能力报告)
 * - 定义 SkinValidationReport 接口(Skin 数据校验)
 * - 定义 MaterialValidationReport 接口(材质校验)
 * - 定义 VrmCapabilityReport 接口(VRM 扩展能力报告)
 * - 提供 analyzeModelCapability 函数,综合各维度生成报告
 * - 提供 analyzeVrmCapability 函数,从 VrmAsset 生成 VRM 维度报告
 * - 提供各状态的中文文案
 *
 * 设计原则:
 * - 自动映射失败只能影响 humanoidAutoMapping
 * - 不得影响 sceneLoadable / geometryRenderable / skeletonPresent
 * - 模型可显示但骨骼未映射时不得使用红色"模型不兼容"
 * - 所有状态独立可读,UI 可分别显示
 * - VRM 维度独立评估,非 VRM 文件全部为 NotPresent
 *
 * 不依赖 ArkUI / ArkGraphics3D,纯逻辑可单元测试。
 */

import { GltfModelInfo } from '../../parser/GltfValidator';
import { ModelInspectionResult } from './ModelImportResult';
import { HumanoidBone, REQUIRED_BONES } from './HumanoidBone';
import { BoneMappingResult, SkeletonProfile, CompatibilityLevel } from './HumanoidBone';
import { analyzeSkinAndMaterial } from '../../parser/GltfSkinMaterialAnalyzer';
import { VrmAsset } from './vrm/VrmAsset';
import { VrmVersion, isVrm } from './vrm/VrmVersion';

/**
 * 单一能力状态。
 */
export enum CapabilityState {
  /** 完全支持 */
  Supported = 'Supported',
  /** 部分支持(如材质缺失但几何可显示) */
  PartiallySupported = 'PartiallySupported',
  /** 不支持 */
  Unsupported = 'Unsupported',
  /** 当前模型不包含此能力(如无 Skin) */
  NotPresent = 'NotPresent',
  /** 未评估或信息不足 */
  Unknown = 'Unknown'
}

/**
 * 人形骨骼映射状态。
 */
export enum HumanoidMappingState {
  /** 未评估 */
  NotEvaluated = 'NotEvaluated',
  /** 无骨架,无法映射 */
  NoSkeleton = 'NoSkeleton',
  /** 自动映射完整(必需骨骼全部匹配) */
  AutoMapped = 'AutoMapped',
  /** 自动映射部分成功 */
  PartiallyMapped = 'PartiallyMapped',
  /** 自动匹配失败,需要手动匹配 */
  NeedsManualMapping = 'NeedsManualMapping',
  /** 已完成手动映射 */
  ManualMapped = 'ManualMapped',
  /** 映射无效(校验失败) */
  InvalidMapping = 'InvalidMapping'
}

/**
 * 能力警告。
 */
export interface ModelCapabilityWarning {
  /** 警告维度 */
  dimension: CapabilityDimension;
  /** 警告内容 */
  message: string;
}

/**
 * 能力维度(用于警告归类)。
 */
export enum CapabilityDimension {
  Container = 'Container',
  Semantic = 'Semantic',
  Scene = 'Scene',
  Geometry = 'Geometry',
  Material = 'Material',
  Texture = 'Texture',
  Skeleton = 'Skeleton',
  Skin = 'Skin',
  Animation = 'Animation',
  HumanoidMapping = 'HumanoidMapping',
  Retargeting = 'Retargeting',
  // T-4.0 VRM 维度
  Vrm = 'Vrm',
  Expression = 'Expression',
  LookAt = 'LookAt',
  SpringBone = 'SpringBone',
  FirstPerson = 'FirstPerson',
  MToon = 'MToon',
  NodeConstraint = 'NodeConstraint'
}

/**
 * Skin 数据校验报告。
 *
 * T-3D.6E 第十节:重点检查 joints/IBM/JOINTS/WEIGHTS。
 */
export interface SkinValidationReport {
  /** skin 总数 */
  skinCount: number;
  /** 有效 skin 数量 */
  validSkinCount: number;
  /** joint 总数(去重前) */
  jointCount: number;
  /** inverseBindMatrix 数量 */
  inverseBindMatrixCount: number;
  /** 含 skin 的 mesh 数量 */
  meshWithSkinCount: number;
  /** 缺失 WEIGHTS 的 mesh 数量 */
  meshesMissingWeights: number;
  /** 缺失 JOINTS 的 mesh 数量 */
  meshesMissingJoints: number;
  /** 非法 joint 索引数量 */
  invalidJointIndexCount: number;
  /** 非法权重数量 */
  invalidWeightCount: number;
  /** 全零权重顶点数量 */
  zeroWeightVertexCount: number;
  /** 未归一化权重顶点数量 */
  nonNormalizedWeightVertexCount: number;
  /** 警告列表 */
  warnings: string[];
}

/**
 * 材质校验报告。
 */
export interface MaterialValidationReport {
  /** 材质总数 */
  materialCount: number;
  /** 透明材质数量(BLEND/MASK) */
  transparentMaterialCount: number;
  /** unlit 材质数量 */
  unlitMaterialCount: number;
  /** PBR 材质数量 */
  pbrMaterialCount: number;
  /** 完全透明材质数量(baseColorFactor.a=0) */
  fullyTransparentCount: number;
  /** 缺失纹理的材质数量 */
  missingTextureCount: number;
  /** 警告列表 */
  warnings: string[];
}

/**
 * VRM 扩展能力报告(T-4.0 新增)。
 *
 * 非 VRM 文件所有字段为 NotPresent/0/null。
 * VRM 文件根据 VrmAsset 填充。
 *
 * 注意:SpringBone/LookAt/Expression 仅"已解析",Runtime 待后续实现。
 */
export interface VrmCapabilityReport {
  /** 是否 VRM 文件 */
  isVrm: boolean;
  /** VRM 版本(NonVrm/Vrm0x/Vrm1) */
  vrmVersion: VrmVersion;
  /** VRM 解析是否整体成功 */
  vrmParsed: CapabilityState;
  /** Expression 能力(已解析的表情数量) */
  expression: CapabilityState;
  /** LookAt 能力(已解析的视线配置) */
  lookAt: CapabilityState;
  /** SpringBone 能力(已解析的物理骨骼,Runtime Pending) */
  springBone: CapabilityState;
  /** FirstPerson 能力(已解析的第一人称配置) */
  firstPerson: CapabilityState;
  /** MToon 材质扩展 */
  mtoonMaterial: CapabilityState;
  /** NodeConstraint 扩展 */
  nodeConstraint: CapabilityState;
  /** VRM Humanoid 显式映射(优先级高于 auto/manual) */
  vrmHumanoid: CapabilityState;

  /** 表情数量 */
  expressionCount: number;
  /** Blink 表情数 */
  blinkExpressionCount: number;
  /** LipSync 表情数 */
  lipSyncExpressionCount: number;
  /** SpringBone 关节总数 */
  springBoneJointCount: number;
  /** SpringBone 链(spring)数量 */
  springBoneSpringCount: number;
  /** SpringBone 碰撞体数量 */
  springBoneColliderCount: number;
  /** FirstPerson 网格标注数 */
  firstPersonAnnotationCount: number;
  /** VRM Humanoid 已映射骨骼数 */
  vrmHumanoidBoneCount: number;
  /** VRM Humanoid 必需骨骼映射数 */
  vrmHumanoidRequiredMapped: number;

  /** VRM 解析错误(空表示无错误) */
  vrmParseError: string;
}

/**
 * 模型能力分层报告。
 *
 * 12 个维度独立评估,UI 可分别显示。
 * T-4.0: 新增 vrm 字段(VrmCapabilityReport)。
 */
export interface ModelCapabilityReport {
  /** 容器(GLB 头)是否有效 */
  containerValid: CapabilityState;
  /** glTF 语义是否有效 */
  semanticValid: CapabilityState;
  /** Scene 能否加载 */
  sceneLoadable: CapabilityState;
  /** 几何是否可渲染 */
  geometryRenderable: CapabilityState;
  /** 材质是否可渲染 */
  materialRenderable: CapabilityState;
  /** 纹理是否可渲染 */
  textureRenderable: CapabilityState;
  /** 骨架是否存在(基于 glTF Skin 判断) */
  skeletonPresent: CapabilityState;
  /** Skin 数据是否有效 */
  skinValid: CapabilityState;
  /** 是否存在动画 */
  animationPresent: CapabilityState;
  /** 动画是否可播放 */
  animationPlayable: CapabilityState;
  /** 自动人形映射状态 */
  humanoidAutoMapping: HumanoidMappingState;
  /** 手动人形映射状态 */
  humanoidManualMapping: HumanoidMappingState;
  /** 动作重定向就绪状态 */
  motionRetargeting: CapabilityState;

  /** Skin 校验详细报告 */
  skinReport: SkinValidationReport;
  /** 材质校验详细报告 */
  materialReport: MaterialValidationReport;

  /** 自动映射详情(若已评估) */
  autoMappingResult: BoneMappingResult | null;

  /** T-4.0: VRM 扩展能力报告(非 VRM 为全 NotPresent) */
  vrm: VrmCapabilityReport;

  /** 警告列表 */
  warnings: ModelCapabilityWarning[];

  /** 一句话摘要(供 UI 卡片显示) */
  summary: string;
}

/**
 * analyzeModelCapability 输入参数。
 */
export interface ModelCapabilityInput {
  /** GltfModelInfo(主验证结果) */
  modelInfo: GltfModelInfo | null;
  /** glTF JSON 对象(用于 Skin/Material 深度分析,可选) */
  gltfJson: Record<string, Object> | null;
  /** 模型扫描结果(若已执行) */
  inspection: ModelInspectionResult | null;
  /** 骨骼自动映射结果(若已执行) */
  boneMapping: BoneMappingResult | null;
  /** 是否已加载 ArkGraphics Scene */
  sceneLoaded: boolean;
  /** 是否检测到可渲染 mesh */
  hasRenderableMesh: boolean;
  /** 手动映射是否存在(由外部存储查询) */
  hasManualMapping: boolean;
  /** 手动映射是否已通过验证 */
  manualMappingValid: boolean;
  /** T-4.0: VRM 资产(非 VRM 文件传 null) */
  vrmAsset: VrmAsset | null;
}

/**
 * 创建空的 Skin 校验报告。
 */
export function createEmptySkinReport(): SkinValidationReport {
  return {
    skinCount: 0,
    validSkinCount: 0,
    jointCount: 0,
    inverseBindMatrixCount: 0,
    meshWithSkinCount: 0,
    meshesMissingWeights: 0,
    meshesMissingJoints: 0,
    invalidJointIndexCount: 0,
    invalidWeightCount: 0,
    zeroWeightVertexCount: 0,
    nonNormalizedWeightVertexCount: 0,
    warnings: []
  };
}

/**
 * 创建空的材质校验报告。
 */
export function createEmptyMaterialReport(): MaterialValidationReport {
  return {
    materialCount: 0,
    transparentMaterialCount: 0,
    unlitMaterialCount: 0,
    pbrMaterialCount: 0,
    fullyTransparentCount: 0,
    missingTextureCount: 0,
    warnings: []
  };
}

/**
 * 创建空的 VRM 能力报告(非 VRM 文件使用)。
 */
export function createEmptyVrmCapabilityReport(): VrmCapabilityReport {
  return {
    isVrm: false,
    vrmVersion: VrmVersion.NonVrm,
    vrmParsed: CapabilityState.NotPresent,
    expression: CapabilityState.NotPresent,
    lookAt: CapabilityState.NotPresent,
    springBone: CapabilityState.NotPresent,
    firstPerson: CapabilityState.NotPresent,
    mtoonMaterial: CapabilityState.NotPresent,
    nodeConstraint: CapabilityState.NotPresent,
    vrmHumanoid: CapabilityState.NotPresent,
    expressionCount: 0,
    blinkExpressionCount: 0,
    lipSyncExpressionCount: 0,
    springBoneJointCount: 0,
    springBoneSpringCount: 0,
    springBoneColliderCount: 0,
    firstPersonAnnotationCount: 0,
    vrmHumanoidBoneCount: 0,
    vrmHumanoidRequiredMapped: 0,
    vrmParseError: ''
  };
}

/**
 * T-3D.6E: 综合分析模型能力,生成多维度报告。
 *
 * 评估顺序:
 * 1. 容器与语义(来自 modelInfo)
 * 2. Scene 与几何(来自 sceneLoaded/hasRenderableMesh)
 * 3. 材质与纹理(来自 inspection)
 * 4. 骨架与 Skin(基于 glTF Skin 判断,不依赖名称)
 * 5. 动画(来自 inspection)
 * 6. 人形映射(来自 boneMapping)
 * 7. 动作重定向(综合判断)
 * 8. T-4.0: VRM 维度(来自 vrmAsset)
 *
 * @param input 输入参数
 * @returns ModelCapabilityReport
 */
export function analyzeModelCapability(input: ModelCapabilityInput): ModelCapabilityReport {
  const warnings: ModelCapabilityWarning[] = [];
  const modelInfo: GltfModelInfo | null = input.modelInfo;
  const inspection: ModelInspectionResult | null = input.inspection;

  // 1. 容器与语义
  const containerValid: CapabilityState = modelInfo !== null
    ? CapabilityState.Supported
    : CapabilityState.Unsupported;
  const semanticValid: CapabilityState = modelInfo !== null
    ? (modelInfo.unsupportedRequiredExtensions.length === 0
      ? CapabilityState.Supported
      : CapabilityState.Unsupported)
    : CapabilityState.Unsupported;
  if (modelInfo !== null && modelInfo.unsupportedRequiredExtensions.length > 0) {
    warnings.push({
      dimension: CapabilityDimension.Semantic,
      message: '不支持的必需扩展: ' + modelInfo.unsupportedRequiredExtensions.join(', ')
    });
  }

  // 2. Scene 与几何
  const sceneLoadable: CapabilityState = input.sceneLoaded
    ? CapabilityState.Supported
    : (modelInfo !== null ? CapabilityState.PartiallySupported : CapabilityState.Unsupported);
  const geometryRenderable: CapabilityState = input.hasRenderableMesh
    ? CapabilityState.Supported
    : (modelInfo !== null && modelInfo.meshCount > 0
      ? CapabilityState.PartiallySupported
      : CapabilityState.Unsupported);
  if (!input.hasRenderableMesh && modelInfo !== null && modelInfo.meshCount > 0) {
    warnings.push({
      dimension: CapabilityDimension.Geometry,
      message: '模型包含 mesh 定义,但 ArkGraphics 未渲染'
    });
  }

  // 3. 材质与纹理(优先使用 GltfSkinMaterialAnalyzer 深度分析,回退到 inspection)
  let materialRenderable: CapabilityState = CapabilityState.Unknown;
  let textureRenderable: CapabilityState = CapabilityState.Unknown;
  let materialReport: MaterialValidationReport = createEmptyMaterialReport();
  if (input.gltfJson !== null) {
    // T-3D.6E: 深度分析材质透明/Unlit/PBR/完全透明/纹理缺失
    const analysis = analyzeSkinAndMaterial({ gltfJson: input.gltfJson });
    materialReport = analysis.materialReport;
    if (materialReport.fullyTransparentCount > 0) {
      materialRenderable = CapabilityState.Unsupported;
      warnings.push({
        dimension: CapabilityDimension.Material,
        message: '检测到完全透明材质(baseColorFactor.a=0)'
      });
    } else if (materialReport.transparentMaterialCount > 0) {
      materialRenderable = CapabilityState.PartiallySupported;
      warnings.push({
        dimension: CapabilityDimension.Material,
        message: '检测到透明材质(BLEND/MASK),可能影响渲染顺序'
      });
    } else if (materialReport.materialCount > 0) {
      materialRenderable = CapabilityState.Supported;
    } else {
      materialRenderable = CapabilityState.NotPresent;
    }
    if (inspection !== null) {
      textureRenderable = inspection.textureCount > 0
        ? (inspection.hasExternalImages
          ? CapabilityState.Unsupported
          : CapabilityState.Supported)
        : CapabilityState.NotPresent;
      if (inspection.hasExternalImages) {
        warnings.push({
          dimension: CapabilityDimension.Texture,
          message: '模型引用外部图片,当前不支持'
        });
      }
    } else {
      textureRenderable = modelInfo !== null && modelInfo.hasTextures
        ? CapabilityState.Supported
        : CapabilityState.NotPresent;
    }
  } else if (inspection !== null) {
    materialReport.materialCount = inspection.materialCount;
    materialReport.transparentMaterialCount = inspection.hasTransparentMaterials ? 1 : 0;
    materialReport.unlitMaterialCount = inspection.hasUnlitMaterials ? 1 : 0;
    materialReport.pbrMaterialCount = inspection.hasPbrMaterials ? inspection.materialCount : 0;
    if (inspection.hasTransparentMaterials) {
      materialReport.warnings.push('检测到透明材质,可能影响渲染顺序');
    }
    materialRenderable = inspection.materialCount > 0
      ? (inspection.hasTransparentMaterials
        ? CapabilityState.PartiallySupported
        : CapabilityState.Supported)
      : CapabilityState.NotPresent;
    textureRenderable = inspection.textureCount > 0
      ? (inspection.hasExternalImages
        ? CapabilityState.Unsupported
        : CapabilityState.Supported)
      : CapabilityState.NotPresent;
    if (inspection.hasExternalImages) {
      textureRenderable = CapabilityState.Unsupported;
      warnings.push({
        dimension: CapabilityDimension.Texture,
        message: '模型引用外部图片,当前不支持'
      });
    }
  }

  // 4. 骨架与 Skin(基于 glTF Skin 判断,不依赖名称)
  let skinReport: SkinValidationReport = createEmptySkinReport();
  let skeletonPresent: CapabilityState = CapabilityState.Unknown;
  let skinValid: CapabilityState = CapabilityState.Unknown;
  if (input.gltfJson !== null) {
    // T-3D.6E: 使用深度分析报告
    const skinAnalysis = analyzeSkinAndMaterial({ gltfJson: input.gltfJson });
    skinReport = skinAnalysis.skinReport;
    if (skinReport.skinCount > 0) {
      skeletonPresent = CapabilityState.Supported;
      if (skinReport.invalidJointIndexCount > 0
        || skinReport.meshesMissingJoints > 0
        || skinReport.meshesMissingWeights > 0) {
        skinValid = CapabilityState.PartiallySupported;
        warnings.push({
          dimension: CapabilityDimension.Skin,
          message: 'Skin 数据存在结构性问题(joint index 越界或 JOINTS/WEIGHTS 不配对)'
        });
      } else {
        skinValid = CapabilityState.Supported;
      }
    } else {
      skeletonPresent = CapabilityState.NotPresent;
      skinValid = CapabilityState.NotPresent;
    }
  } else if (modelInfo !== null) {
    if (modelInfo.hasSkins) {
      skeletonPresent = CapabilityState.Supported;
      skinValid = CapabilityState.Supported;
      if (inspection !== null) {
        skinReport.skinCount = inspection.skinCount;
        skinReport.jointCount = inspection.jointCount;
        skinReport.validSkinCount = inspection.skinCount;
        skinReport.meshWithSkinCount = inspection.skinCount; // 近似
      }
    } else {
      skeletonPresent = CapabilityState.NotPresent;
      skinValid = CapabilityState.NotPresent;
    }
  }

  // 5. 动画
  let animationPresent: CapabilityState = CapabilityState.Unknown;
  let animationPlayable: CapabilityState = CapabilityState.Unknown;
  if (modelInfo !== null) {
    if (modelInfo.animationCount > 0) {
      animationPresent = CapabilityState.Supported;
      animationPlayable = CapabilityState.Supported;
    } else {
      animationPresent = CapabilityState.NotPresent;
      animationPlayable = CapabilityState.NotPresent;
    }
  }

  // 6. 人形映射
  let humanoidAutoMapping: HumanoidMappingState = HumanoidMappingState.NotEvaluated;
  let humanoidManualMapping: HumanoidMappingState = HumanoidMappingState.NotEvaluated;
  let autoMappingResult: BoneMappingResult | null = null;
  if (skeletonPresent === CapabilityState.NotPresent) {
    humanoidAutoMapping = HumanoidMappingState.NoSkeleton;
    humanoidManualMapping = HumanoidMappingState.NoSkeleton;
  } else if (skeletonPresent === CapabilityState.Supported) {
    if (input.boneMapping !== null) {
      autoMappingResult = input.boneMapping;
      if (input.boneMapping.compatibility === CompatibilityLevel.FullHumanoid) {
        humanoidAutoMapping = HumanoidMappingState.AutoMapped;
      } else if (input.boneMapping.compatibility === CompatibilityLevel.PartialHumanoid) {
        humanoidAutoMapping = HumanoidMappingState.PartiallyMapped;
      } else if (input.boneMapping.missingRequired.length >= REQUIRED_BONES.length) {
        humanoidAutoMapping = HumanoidMappingState.NeedsManualMapping;
      } else {
        humanoidAutoMapping = HumanoidMappingState.NeedsManualMapping;
      }
    } else {
      humanoidAutoMapping = HumanoidMappingState.NotEvaluated;
    }
    // 手动映射状态
    if (input.hasManualMapping) {
      humanoidManualMapping = input.manualMappingValid
        ? HumanoidMappingState.ManualMapped
        : HumanoidMappingState.InvalidMapping;
    } else {
      humanoidManualMapping = HumanoidMappingState.NeedsManualMapping;
    }
    // T-4.0: VRM 显式映射优先,若 VRM humanoid 有效则覆盖 auto/manual 状态
    if (input.vrmAsset !== null && isVrm(input.vrmAsset.version)
      && input.vrmAsset.humanoid.valid) {
      humanoidAutoMapping = HumanoidMappingState.AutoMapped;
      humanoidManualMapping = HumanoidMappingState.ManualMapped;
    }
  }

  // 7. 动作重定向
  let motionRetargeting: CapabilityState;
  if (skeletonPresent !== CapabilityState.Supported) {
    motionRetargeting = CapabilityState.Unsupported;
  } else if (humanoidManualMapping === HumanoidMappingState.ManualMapped
    || humanoidAutoMapping === HumanoidMappingState.AutoMapped) {
    motionRetargeting = CapabilityState.Supported;
  } else if (humanoidAutoMapping === HumanoidMappingState.PartiallyMapped
    || humanoidManualMapping === HumanoidMappingState.NeedsManualMapping) {
    motionRetargeting = CapabilityState.PartiallySupported;
  } else {
    motionRetargeting = CapabilityState.Unsupported;
  }

  // 8. T-4.0: VRM 维度分析
  const vrmReport: VrmCapabilityReport = analyzeVrmCapability(input.vrmAsset, warnings);

  // 摘要
  const summary: string = buildSummary(
    sceneLoadable, geometryRenderable, skeletonPresent, humanoidAutoMapping, humanoidManualMapping
  );

  return {
    containerValid: containerValid,
    semanticValid: semanticValid,
    sceneLoadable: sceneLoadable,
    geometryRenderable: geometryRenderable,
    materialRenderable: materialRenderable,
    textureRenderable: textureRenderable,
    skeletonPresent: skeletonPresent,
    skinValid: skinValid,
    animationPresent: animationPresent,
    animationPlayable: animationPlayable,
    humanoidAutoMapping: humanoidAutoMapping,
    humanoidManualMapping: humanoidManualMapping,
    motionRetargeting: motionRetargeting,
    skinReport: skinReport,
    materialReport: materialReport,
    autoMappingResult: autoMappingResult,
    vrm: vrmReport,
    warnings: warnings,
    summary: summary
  };
}

/**
 * T-4.0: 从 VrmAsset 生成 VRM 能力报告。
 *
 * 评估:
 * - vrmParsed: 整体解析成功(meta + humanoid)
 * - expression: 表情数量 > 0
 * - lookAt: lookAt.valid
 * - springBone: 关节总数 > 0(Runtime Pending)
 * - firstPerson: meshAnnotations 数量 > 0
 * - mtoonMaterial: hasMToonMaterial
 * - nodeConstraint: hasNodeConstraint
 * - vrmHumanoid: humanoid.valid
 *
 * @param asset VRM 资产(非 VRM 传 null)
 * @param warnings 警告列表(可选,传入则追加 VRM 警告)
 * @returns VRM 能力报告
 */
export function analyzeVrmCapability(
  asset: VrmAsset | null,
  warnings: ModelCapabilityWarning[] | null
): VrmCapabilityReport {
  if (asset === null || !isVrm(asset.version)) {
    return createEmptyVrmCapabilityReport();
  }

  const report: VrmCapabilityReport = {
    isVrm: true,
    vrmVersion: asset.version,
    vrmParsed: asset.valid ? CapabilityState.Supported : CapabilityState.PartiallySupported,
    expression: asset.expressions.expressions.length > 0
      ? CapabilityState.Supported : CapabilityState.NotPresent,
    lookAt: asset.lookAt.valid
      ? CapabilityState.Supported : CapabilityState.NotPresent,
    springBone: asset.springBone.totalJointCount > 0
      ? CapabilityState.PartiallySupported : CapabilityState.NotPresent, // Runtime Pending
    firstPerson: asset.firstPerson.meshAnnotations.length > 0
      ? CapabilityState.Supported : CapabilityState.NotPresent,
    mtoonMaterial: asset.hasMToonMaterial
      ? CapabilityState.Supported : CapabilityState.NotPresent,
    nodeConstraint: asset.hasNodeConstraint
      ? CapabilityState.Supported : CapabilityState.NotPresent,
    vrmHumanoid: asset.humanoid.valid
      ? CapabilityState.Supported : CapabilityState.NotPresent,
    expressionCount: asset.expressions.expressions.length,
    blinkExpressionCount: asset.expressions.blinkCount,
    lipSyncExpressionCount: asset.expressions.lipSyncCount,
    springBoneJointCount: asset.springBone.totalJointCount,
    springBoneSpringCount: asset.springBone.springs.length,
    springBoneColliderCount: asset.springBone.colliders.length,
    firstPersonAnnotationCount: asset.firstPerson.meshAnnotations.length,
    vrmHumanoidBoneCount: asset.humanoid.bones.length,
    vrmHumanoidRequiredMapped: asset.humanoid.mappedRequiredCount,
    vrmParseError: asset.parseError
  };

  // 警告
  if (warnings !== null) {
    if (!asset.valid) {
      warnings.push({
        dimension: CapabilityDimension.Vrm,
        message: 'VRM 解析不完整: ' + (asset.parseError.length > 0 ? asset.parseError : 'meta 或 humanoid 缺失')
      });
    }
    if (asset.springBone.totalJointCount > 0) {
      warnings.push({
        dimension: CapabilityDimension.SpringBone,
        message: 'SpringBone 已解析(' + asset.springBone.totalJointCount
          + ' 关节),Runtime 待后续实现'
      });
    }
    if (asset.hasMToonMaterial) {
      warnings.push({
        dimension: CapabilityDimension.MToon,
        message: '检测到 VRMC_materials_mtoon 扩展,渲染可能存在差异'
      });
    }
    if (asset.lookAt.valid) {
      warnings.push({
        dimension: CapabilityDimension.LookAt,
        message: 'LookAt 已解析,Runtime 待后续实现'
      });
    }
    if (asset.expressions.expressions.length > 0) {
      warnings.push({
        dimension: CapabilityDimension.Expression,
        message: 'Expression 已解析(' + asset.expressions.expressions.length
          + ' 个),Runtime 待后续实现'
      });
    }
  }

  return report;
}

/**
 * 生成一句话摘要。
 */
function buildSummary(
  sceneLoadable: CapabilityState,
  geometryRenderable: CapabilityState,
  skeletonPresent: CapabilityState,
  humanoidAutoMapping: HumanoidMappingState,
  humanoidManualMapping: HumanoidMappingState
): string {
  // 显示状态
  let display: string;
  if (sceneLoadable === CapabilityState.Supported
    && geometryRenderable === CapabilityState.Supported) {
    display = '可正常显示';
  } else if (sceneLoadable === CapabilityState.PartiallySupported) {
    display = '已加载但当前未定位';
  } else if (geometryRenderable === CapabilityState.Unsupported) {
    display = '无可渲染几何';
  } else {
    display = '系统 3D 引擎无法加载';
  }

  // 骨架状态
  let skeleton: string;
  if (skeletonPresent === CapabilityState.Supported) {
    skeleton = '已检测到骨架';
  } else if (skeletonPresent === CapabilityState.NotPresent) {
    skeleton = '未检测到骨架';
  } else {
    skeleton = '骨架状态未知';
  }

  // 映射状态
  let mapping: string;
  if (humanoidManualMapping === HumanoidMappingState.ManualMapped) {
    mapping = '已完成手动映射';
  } else if (humanoidAutoMapping === HumanoidMappingState.AutoMapped) {
    mapping = '已自动匹配';
  } else if (humanoidAutoMapping === HumanoidMappingState.PartiallyMapped) {
    mapping = '自动匹配部分成功';
  } else if (humanoidAutoMapping === HumanoidMappingState.NeedsManualMapping) {
    mapping = '需要手动匹配';
  } else if (humanoidAutoMapping === HumanoidMappingState.NoSkeleton) {
    mapping = '无骨架,不支持动作匹配';
  } else {
    mapping = '尚未评估';
  }

  return '显示: ' + display + ' | 骨架: ' + skeleton + ' | 映射: ' + mapping;
}

/**
 * CapabilityState 中文文案。
 */
export function getCapabilityStateText(state: CapabilityState): string {
  switch (state) {
    case CapabilityState.Supported: return '可用';
    case CapabilityState.PartiallySupported: return '部分可用';
    case CapabilityState.Unsupported: return '不可用';
    case CapabilityState.NotPresent: return '不存在';
    case CapabilityState.Unknown: return '未知';
    default: return '';
  }
}

/**
 * HumanoidMappingState 中文文案。
 */
export function getHumanoidMappingStateText(state: HumanoidMappingState): string {
  switch (state) {
    case HumanoidMappingState.NotEvaluated: return '尚未评估';
    case HumanoidMappingState.NoSkeleton: return '无骨架';
    case HumanoidMappingState.AutoMapped: return '已自动匹配';
    case HumanoidMappingState.PartiallyMapped: return '自动匹配部分成功';
    case HumanoidMappingState.NeedsManualMapping: return '需要手动匹配';
    case HumanoidMappingState.ManualMapped: return '已完成手动映射';
    case HumanoidMappingState.InvalidMapping: return '映射无效';
    default: return '';
  }
}

/**
 * 动作匹配状态文案(基于 motionRetargeting)。
 */
export function getMotionRetargetingText(state: CapabilityState): string {
  switch (state) {
    case CapabilityState.Supported: return '可用于人形动作';
    case CapabilityState.PartiallySupported: return '需要完成骨骼映射';
    case CapabilityState.Unsupported: return '当前只支持静态显示';
    case CapabilityState.NotPresent: return '动画不存在';
    case CapabilityState.Unknown: return '尚未评估';
    default: return '';
  }
}

/**
 * T-4.0: VRM 版本文案。
 */
export function getVrmVersionText(version: VrmVersion): string {
  switch (version) {
    case VrmVersion.Vrm1: return 'VRM 1.0';
    case VrmVersion.Vrm0x: return 'VRM 0.x';
    case VrmVersion.NonVrm: return '非 VRM';
    default: return '';
  }
}

/**
 * T-4.0: VRM 能力维度文案(用于 UI 展示)。
 *
 * 返回各维度的展示文案,如 "Expression: 已解析(18 个)"。
 */
export function getVrmCapabilitySummary(report: VrmCapabilityReport): string[] {
  const lines: string[] = [];
  if (!report.isVrm) {
    lines.push('非 VRM 文件');
    return lines;
  }
  lines.push('版本: ' + getVrmVersionText(report.vrmVersion));
  lines.push('解析: ' + getCapabilityStateText(report.vrmParsed));
  lines.push('Humanoid: ' + getCapabilityStateText(report.vrmHumanoid)
    + ' (' + report.vrmHumanoidBoneCount + ' 骨骼, 必需 ' + report.vrmHumanoidRequiredMapped + '/7)');
  lines.push('Expression: ' + getCapabilityStateText(report.expression)
    + ' (' + report.expressionCount + ' 个, Blink ' + report.blinkExpressionCount
    + ', LipSync ' + report.lipSyncExpressionCount + ')');
  lines.push('LookAt: ' + getCapabilityStateText(report.lookAt));
  lines.push('SpringBone: ' + getCapabilityStateText(report.springBone)
    + ' (' + report.springBoneJointCount + ' 关节, ' + report.springBoneSpringCount + ' 链, '
    + report.springBoneColliderCount + ' 碰撞体)');
  lines.push('FirstPerson: ' + getCapabilityStateText(report.firstPerson)
    + ' (' + report.firstPersonAnnotationCount + ' 标注)');
  lines.push('MToon: ' + getCapabilityStateText(report.mtoonMaterial));
  lines.push('NodeConstraint: ' + getCapabilityStateText(report.nodeConstraint));
  if (report.vrmParseError.length > 0) {
    lines.push('错误: ' + report.vrmParseError);
  }
  return lines;
}
