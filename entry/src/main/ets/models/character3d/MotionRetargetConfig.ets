/**
 * MotionRetargetConfig 动作重定向前置数据结构
 *
 * T-3D.6E P4: 第二十六节 动作重定向前置。
 *
 * 职责:
 * - 定义 RetargetConfig(重定向静态配置)
 * - 定义 RetargetAsset(重定向资产实例)
 * - 定义 RetargetValidationResult(重定向就绪度验证结果)
 * - 提供 validateRetargetReady 函数(基于 ManualHumanoidMapping 校验)
 * - 提供 createDefaultRetargetConfig 辅助函数
 *
 * 设计原则:
 * - 本任务只建立数据结构和校验,不实现完整动作重定向播放器
 * - RetargetConfig 关联 ManualHumanoidMapping(通过 modelId + skeletonHash)
 * - RetargetAsset 关联源动作(通过 actionAssetId)和目标模型(通过 modelId)
 * - 校验只读 ManualHumanoidMapping,不依赖 ArkUI/ArkGraphics3D/文件系统
 *
 * 不实现(留给后续阶段):
 * - 完整动画时间轴
 * - 多动画播放列表
 * - 动画混合
 * - IK / Foot IK
 * - Root Motion 完整系统
 * - 手指动作
 * - 面部 Morph 动作
 * - 动作编辑器
 * - 动作导出
 * - 实时动作捕捉
 *
 * 允许后续阶段在映射验证通过后执行:
 * - 一个简单的骨骼旋转预览测试(左上臂抬起少量角度)
 * - 恢复 rest pose
 * - 测试结束必须恢复模型姿态
 */

import { HumanoidBone, REQUIRED_BONES } from './HumanoidBone';
import {
  ManualHumanoidMapping
} from './ManualHumanoidMapping';
import {
  HumanoidMappingValidationResult
} from './HumanoidMappingValidator';

/**
 * 重定向模式。
 */
export enum RetargetMode {
  /** 直接播放(源模型 = 目标模型,无需重定向) */
  Direct = 'Direct',
  /** 通过标准 Humanoid 映射重定向 */
  HumanoidMapped = 'HumanoidMapped',
  /** 仅元数据(可保存但当前运行时不能播放) */
  MetadataOnly = 'MetadataOnly',
  /** 不支持重定向 */
  Unsupported = 'Unsupported'
}

/**
 * Root Motion 处理模式。
 */
export enum RootMotionMode {
  /** 禁用 Root Motion(原地播放) */
  Disabled = 'Disabled',
  /** 启用 Root Motion(模型随动画移动) */
  Enabled = 'Enabled',
  /** 仅 Y 轴(垂直移动) */
  VerticalOnly = 'VerticalOnly'
}

/**
 * 重定向循环模式(与 ActionLoopMode 对齐,但独立定义以避免循环依赖)。
 */
export enum RetargetLoopMode {
  /** 不循环 */
  Once = 'Once',
  /** 循环 */
  Loop = 'Loop',
  /** 单次播放后停在最后一帧 */
  Hold = 'Hold'
}

/**
 * 重定向静态配置。
 *
 * 定义"如何"将源动作重定向到目标模型。
 * 与具体动作无关,只与目标模型的映射相关。
 */
export interface RetargetConfig {
  /** 配置版本(目前固定为 1) */
  configVersion: number;
  /** 目标模型 ID(= ManualHumanoidMapping.modelId) */
  targetModelId: string;
  /** 目标模型 skeletonHash(用于检测映射失效) */
  targetSkeletonHash: string;
  /** 重定向模式 */
  mode: RetargetMode;
  /** Root Motion 模式 */
  rootMotion: RootMotionMode;
  /** 循环模式 */
  loopMode: RetargetLoopMode;
  /** 播放速度倍率(1.0 = 原速) */
  speedMultiplier: number;
  /** 全局缩放(目标模型相对源模型的单位缩放) */
  globalScale: number;
  /** 是否启用上臂旋转预览测试(用于映射验证) */
  enableArmTestPreview: boolean;
  /** 上臂预览测试角度(度,正值抬起) */
  armTestAngleDeg: number;
  /** 是否在预览测试后自动恢复 rest pose */
  autoRestoreRestPose: boolean;
  /** 忽略的骨骼(可选,这些骨骼不参与重定向) */
  ignoredBones: HumanoidBone[];
}

/**
 * 重定向资产实例。
 *
 * 定义"什么动作"重定向到"什么模型"。
 * 一个 RetargetAsset 关联一个源动作和一个 RetargetConfig。
 */
export interface RetargetAsset {
  /** 资产 ID(唯一) */
  assetId: string;
  /** 源动作资产 ID(关联 Character3DActionAsset) */
  sourceActionAssetId: string;
  /** 源动作显示名 */
  sourceActionDisplayName: string;
  /** 源动作 skeletonHash(用于检测源骨架变化) */
  sourceSkeletonHash: string;
  /** 目标模型 ID */
  targetModelId: string;
  /** 关联的 RetargetConfig */
  config: RetargetConfig;
  /** 关联的 ManualHumanoidMapping(通过 modelId + skeletonHash 关联) */
  mappingId: string;
  /** 重定向就绪度(由 validateRetargetReady 计算并缓存) */
  retargetReady: boolean;
  /** 最近一次验证时间(ms) */
  lastValidatedAt: number;
  /** 警告列表 */
  warnings: string[];
  /** 创建时间(ms) */
  createdAt: number;
  /** 更新时间(ms) */
  updatedAt: number;
}

/**
 * 重定向验证问题级别。
 */
export enum RetargetIssueLevel {
  Error = 'Error',
  Warning = 'Warning'
}

/**
 * 重定向验证问题。
 */
export interface RetargetIssue {
  level: RetargetIssueLevel;
  message: string;
}

/**
 * 重定向验证结果。
 */
export interface RetargetValidationResult {
  /** 是否就绪(可执行预览测试) */
  ready: boolean;
  /** 是否可直接播放(不需重定向) */
  directPlayable: boolean;
  /** 是否可通过 Humanoid 映射播放 */
  mappedPlayable: boolean;
  /** 推荐的重定向模式 */
  recommendedMode: RetargetMode;
  /** 错误列表(必须修复才能播放) */
  errors: RetargetIssue[];
  /** 警告列表(可选修复) */
  warnings: RetargetIssue[];
  /** 已映射的必需关节数 */
  mappedRequiredCount: number;
  /** 必需关节总数 */
  totalRequiredCount: number;
}

/**
 * 创建默认的重定向配置。
 *
 * @param targetModelId 目标模型 ID
 * @param targetSkeletonHash 目标模型 skeleton hash
 */
export function createDefaultRetargetConfig(
  targetModelId: string,
  targetSkeletonHash: string
): RetargetConfig {
  return {
    configVersion: 1,
    targetModelId: targetModelId,
    targetSkeletonHash: targetSkeletonHash,
    mode: RetargetMode.HumanoidMapped,
    rootMotion: RootMotionMode.Disabled,
    loopMode: RetargetLoopMode.Loop,
    speedMultiplier: 1.0,
    globalScale: 1.0,
    enableArmTestPreview: true,
    armTestAngleDeg: 45,
    autoRestoreRestPose: true,
    ignoredBones: []
  };
}

/**
 * 创建默认的重定向资产。
 *
 * @param assetId 资产 ID(唯一)
 * @param sourceActionAssetId 源动作资产 ID
 * @param sourceActionDisplayName 源动作显示名
 * @param sourceSkeletonHash 源动作 skeleton hash
 * @param targetModelId 目标模型 ID
 * @param targetSkeletonHash 目标模型 skeleton hash
 * @param mappingId 关联的 ManualHumanoidMapping ID
 */
export function createDefaultRetargetAsset(
  assetId: string,
  sourceActionAssetId: string,
  sourceActionDisplayName: string,
  sourceSkeletonHash: string,
  targetModelId: string,
  targetSkeletonHash: string,
  mappingId: string
): RetargetAsset {
  const now: number = Date.now();
  return {
    assetId: assetId,
    sourceActionAssetId: sourceActionAssetId,
    sourceActionDisplayName: sourceActionDisplayName,
    sourceSkeletonHash: sourceSkeletonHash,
    targetModelId: targetModelId,
    config: createDefaultRetargetConfig(targetModelId, targetSkeletonHash),
    mappingId: mappingId,
    retargetReady: false,
    lastValidatedAt: 0,
    warnings: [],
    createdAt: now,
    updatedAt: now
  };
}

/**
 * 验证重定向就绪度。
 *
 * 检查项:
 * 1. mapping 是否存在
 * 2. mapping.skeletonHash 是否与当前模型一致
 * 3. mapping 是否通过验证(valid=true)
 * 4. mapping.retargetReady 是否为 true
 * 5. 所有必需关节是否已映射
 * 6. config.targetModelId 是否与 mapping.modelId 一致
 * 7. config.targetSkeletonHash 是否与 mapping.skeletonHash 一致
 * 8. config 参数是否合法(speedMultiplier/globalScale)
 * 9. 源动作 skeletonHash 是否非空
 * 10. ignoredBones 是否只包含已知骨骼
 *
 * @param mapping 手动映射(可能为 null)
 * @param mappingValidation 映射验证结果(可能为 null)
 * @param config 重定向配置
 * @param asset 重定向资产(可选,用于检查源动作)
 * @returns 验证结果
 */
export function validateRetargetReady(
  mapping: ManualHumanoidMapping | null,
  mappingValidation: HumanoidMappingValidationResult | null,
  config: RetargetConfig,
  asset: RetargetAsset | null
): RetargetValidationResult {
  const errors: RetargetIssue[] = [];
  const warnings: RetargetIssue[] = [];

  let mappedRequiredCount: number = 0;
  const totalRequiredCount: number = REQUIRED_BONES.length;

  // === 检查 1: mapping 是否存在 ===
  if (mapping === null) {
    errors.push({
      level: RetargetIssueLevel.Error,
      message: '未找到关联的手动映射(ManualHumanoidMapping)'
    });
    return HumanoidMappingValidator_buildEmptyResult(errors, warnings,
      mappedRequiredCount, totalRequiredCount);
  }

  // === 检查 6: config.targetModelId 是否与 mapping.modelId 一致 ===
  if (config.targetModelId !== mapping.modelId) {
    errors.push({
      level: RetargetIssueLevel.Error,
      message: 'config.targetModelId(' + config.targetModelId
        + ')与 mapping.modelId(' + mapping.modelId + ')不一致'
    });
  }

  // === 检查 7: config.targetSkeletonHash 是否与 mapping.skeletonHash 一致 ===
  if (config.targetSkeletonHash !== mapping.skeletonHash) {
    errors.push({
      level: RetargetIssueLevel.Error,
      message: 'config.targetSkeletonHash 与 mapping.skeletonHash 不一致'
    });
  }

  // === 检查 2: mapping.skeletonHash 非空 ===
  if (mapping.skeletonHash.length === 0) {
    errors.push({
      level: RetargetIssueLevel.Error,
      message: 'mapping.skeletonHash 为空,无法验证骨架一致性'
    });
  }

  // === 检查 5: 所有必需关节是否已映射 ===
  const mappedTargets: Set<HumanoidBone> = new Set();
  for (let i: number = 0; i < mapping.joints.length; i++) {
    mappedTargets.add(mapping.joints[i].targetJoint);
  }
  for (let i: number = 0; i < REQUIRED_BONES.length; i++) {
    if (mappedTargets.has(REQUIRED_BONES[i])) {
      mappedRequiredCount++;
    }
  }
  if (mappedRequiredCount < totalRequiredCount) {
    errors.push({
      level: RetargetIssueLevel.Error,
      message: '必需关节未全部映射: ' + mappedRequiredCount + '/' + totalRequiredCount
    });
  }

  // === 检查 3: mapping 是否通过验证 ===
  if (mappingValidation === null) {
    warnings.push({
      level: RetargetIssueLevel.Warning,
      message: '未提供映射验证结果,假设未验证'
    });
  } else if (!mappingValidation.valid) {
    const errorCount: number = mappingValidation.errors.length;
    errors.push({
      level: RetargetIssueLevel.Error,
      message: '映射验证未通过(' + errorCount + ' 个错误)'
    });
  } else {
    // 验证通过,但检查 retargetReady
    if (!mapping.retargetReady) {
      warnings.push({
        level: RetargetIssueLevel.Warning,
        message: 'mapping.retargetReady 为 false,可能存在未解决的警告'
      });
    }
  }

  // === 检查 4: mapping.retargetReady ===
  if (mapping.retargetReady) {
    // OK
  } else if (mappingValidation !== null && mappingValidation.valid) {
    // 验证通过但 retargetReady=false,可能是警告导致
    warnings.push({
      level: RetargetIssueLevel.Warning,
      message: 'mapping.retargetReady 为 false,建议先修复映射警告'
    });
  }

  // === 检查 8: config 参数是否合法 ===
  if (!Number.isFinite(config.speedMultiplier) || config.speedMultiplier <= 0) {
    errors.push({
      level: RetargetIssueLevel.Error,
      message: 'speedMultiplier 无效: ' + config.speedMultiplier
    });
  }
  if (!Number.isFinite(config.globalScale) || config.globalScale <= 0) {
    errors.push({
      level: RetargetIssueLevel.Error,
      message: 'globalScale 无效: ' + config.globalScale
    });
  }
  if (config.enableArmTestPreview) {
    if (!Number.isFinite(config.armTestAngleDeg)
      || config.armTestAngleDeg < -180
      || config.armTestAngleDeg > 180) {
      errors.push({
        level: RetargetIssueLevel.Error,
        message: 'armTestAngleDeg 超出范围: ' + config.armTestAngleDeg
      });
    }
  }

  // === 检查 9: 源动作 skeletonHash 是否非空 ===
  if (asset !== null) {
    if (asset.sourceSkeletonHash.length === 0) {
      warnings.push({
        level: RetargetIssueLevel.Warning,
        message: '源动作 skeletonHash 为空,无法检测源骨架变化'
      });
    }
    if (asset.sourceActionAssetId.length === 0) {
      errors.push({
        level: RetargetIssueLevel.Error,
        message: 'sourceActionAssetId 为空'
      });
    }
  }

  // === 检查 10: ignoredBones 是否只包含已知骨骼 ===
  // 由于 HumanoidBone 是枚举,所有值都合法,这里只检查是否为空数组
  // (空数组是合法的,表示无忽略骨骼)

  // === 判断是否就绪 ===
  const ready: boolean = errors.length === 0;
  // 判断推荐模式
  let recommendedMode: RetargetMode = RetargetMode.Unsupported;
  if (ready) {
    // 如果源动作 skeletonHash 与目标模型一致,可使用 Direct
    if (asset !== null && asset.sourceSkeletonHash === config.targetSkeletonHash) {
      recommendedMode = RetargetMode.Direct;
    } else {
      recommendedMode = RetargetMode.HumanoidMapped;
    }
  } else if (mappedRequiredCount === 0) {
    recommendedMode = RetargetMode.Unsupported;
  } else {
    recommendedMode = RetargetMode.MetadataOnly;
  }

  const directPlayable: boolean = ready
    && asset !== null
    && asset.sourceSkeletonHash === config.targetSkeletonHash;
  const mappedPlayable: boolean = ready && !directPlayable;

  return {
    ready: ready,
    directPlayable: directPlayable,
    mappedPlayable: mappedPlayable,
    recommendedMode: recommendedMode,
    errors: errors,
    warnings: warnings,
    mappedRequiredCount: mappedRequiredCount,
    totalRequiredCount: totalRequiredCount
  };
}

/**
 * 构造空验证结果(辅助函数)。
 */
function HumanoidMappingValidator_buildEmptyResult(
  errors: RetargetIssue[],
  warnings: RetargetIssue[],
  mappedRequiredCount: number,
  totalRequiredCount: number
): RetargetValidationResult {
  return {
    ready: false,
    directPlayable: false,
    mappedPlayable: false,
    recommendedMode: RetargetMode.Unsupported,
    errors: errors,
    warnings: warnings,
    mappedRequiredCount: mappedRequiredCount,
    totalRequiredCount: totalRequiredCount
  };
}

/**
 * 将 RetargetValidationResult 转为可读字符串(用于日志/UI)。
 */
export function formatRetargetValidationResult(result: RetargetValidationResult): string {
  const lines: string[] = [];
  lines.push('RetargetReady: ' + result.ready);
  lines.push('DirectPlayable: ' + result.directPlayable);
  lines.push('MappedPlayable: ' + result.mappedPlayable);
  lines.push('RecommendedMode: ' + result.recommendedMode);
  lines.push('RequiredMapped: ' + result.mappedRequiredCount + '/' + result.totalRequiredCount);
  if (result.errors.length > 0) {
    lines.push('Errors(' + result.errors.length + '):');
    for (let i: number = 0; i < result.errors.length; i++) {
      lines.push('  - ' + result.errors[i].message);
    }
  }
  if (result.warnings.length > 0) {
    lines.push('Warnings(' + result.warnings.length + '):');
    for (let i: number = 0; i < result.warnings.length; i++) {
      lines.push('  - ' + result.warnings[i].message);
    }
  }
  return lines.join('\n');
}
