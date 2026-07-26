/**
 * SkeletonDisplayMode 骨架显示模式
 *
 * T-4.2G-A2: 详情弹窗 3D 预览的显示模式枚举。
 *
 * T-4.2G-A2 统一目标模型姿势与骨骼预览姿势:
 * - 默认模式改为 ModelOnly,避免普通用户被调试骨架干扰
 * - "源动作示意"模式明确标注为源语义,不得称为当前模型骨架
 *
 * 模式说明:
 * - ModelOnly: 仅显示当前 Avatar 模型(默认)
 * - ModelWithSkeleton: 模型 + 目标骨架叠加显示(用于验收骨架与模型关节重合度)
 * - SkeletonOnly: 仅显示目标骨架(无模型,用于诊断骨架本身)
 * - SourceActionPreview: 源动作示意(2D 卡片,基于 ActionPreviewKeyframes,
 *   展示动作源语义,不代表当前模型的默认姿势)
 */

export enum SkeletonDisplayMode {
  /** 仅模型(默认) */
  ModelOnly = 'ModelOnly',
  /** 模型 + 目标骨架叠加 */
  ModelWithSkeleton = 'ModelWithSkeleton',
  /** 仅目标骨架 */
  SkeletonOnly = 'SkeletonOnly',
  /** 源动作示意(2D 卡片) */
  SourceActionPreview = 'SourceActionPreview'
}

/**
 * 显示模式元数据(用于 UI 列表)。
 */
export interface SkeletonDisplayModeInfo {
  mode: SkeletonDisplayMode;
  /** UI 显示文本 */
  label: string;
  /** 简短说明 */
  description: string;
}

/**
 * 获取所有显示模式(用于 UI 列表渲染)。
 */
export function getAllSkeletonDisplayModes(): SkeletonDisplayModeInfo[] {
  return [
    {
      mode: SkeletonDisplayMode.ModelOnly,
      label: '仅模型',
      description: '只显示当前 Avatar 模型(默认)'
    },
    {
      mode: SkeletonDisplayMode.ModelWithSkeleton,
      label: '模型 + 骨架',
      description: '模型与目标骨架叠加显示,骨架来自当前模型的实际重定向结果'
    },
    {
      mode: SkeletonDisplayMode.SkeletonOnly,
      label: '仅骨架',
      description: '只显示目标骨架,无模型'
    },
    {
      mode: SkeletonDisplayMode.SourceActionPreview,
      label: '源动作示意',
      description: '基于 ActionPreviewKeyframes 的 2D 卡片示意,此骨架展示动作源语义,不代表当前模型的默认姿势'
    }
  ];
}

/**
 * 根据显示模式判断是否显示模型。
 */
export function shouldShowModel(mode: SkeletonDisplayMode): boolean {
  return mode === SkeletonDisplayMode.ModelOnly
    || mode === SkeletonDisplayMode.ModelWithSkeleton;
}

/**
 * 根据显示模式判断是否显示 3D 目标骨架。
 */
export function shouldShowSkeleton(mode: SkeletonDisplayMode): boolean {
  return mode === SkeletonDisplayMode.ModelWithSkeleton
    || mode === SkeletonDisplayMode.SkeletonOnly;
}

/**
 * 根据显示模式判断是否回退到 2D 源动作示意。
 */
export function shouldUseSourceActionPreview(mode: SkeletonDisplayMode): boolean {
  return mode === SkeletonDisplayMode.SourceActionPreview;
}
