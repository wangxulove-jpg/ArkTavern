/**
 * UnifiedActionItem 统一动作展示项
 *
 * T-3D.6C: 将内置动作、用户导入动作、模型内置动画统一为一套卡片数据,
 * 供三列卡片网格使用。
 */

import { Character3DActionAsset } from './Character3DActionAsset';
import { Character3DActionSlot } from './Character3DActionSlot';
import { SkeletonProfile, CompatibilityLevel } from './HumanoidBone';

/**
 * 动作来源类型(用于卡片标记和筛选)。
 */
export enum ActionSourceKind {
  /** App 内置默认动作(不可删除) */
  BuiltIn = 'BuiltIn',
  /** 用户导入动作(可删除) */
  Imported = 'Imported',
  /** 模型自带动画 */
  ModelEmbedded = 'ModelEmbedded',
  /** 元数据记录(SDK 无法播放) */
  MetadataOnly = 'MetadataOnly',
}

/**
 * 动作分类(用于筛选 Chip)。
 */
export enum ActionCategory {
  /** 基础(待机/倾听/思考/说话) */
  Base = 'base',
  /** 社交(问候/挥手/点头/摇头/抱歉) */
  Social = 'social',
  /** 情绪(开心/疑惑/难过/生气) */
  Emotion = 'emotion',
  /** 反应(触摸回应/庆祝) */
  Reaction = 'reaction',
  /** 未分类 */
  Other = 'other',
}

/**
 * 统一动作展示项。
 * 用于三列卡片网格渲染。
 */
export interface UnifiedActionItem {
  /** 稳定 ID(内置动作用 builtin_xxx,导入动作用 act_xxx) */
  id: string;
  /** 显示名(优先:用户自定义 > 默认名 > Clip 名) */
  displayName: string;
  /** 默认显示名(重命名前的原始名) */
  defaultDisplayName: string;
  /** Clip 名称(GLB 内动画名) */
  clipName: string;
  /** Clip 索引(GLB 内动画索引) */
  clipIndex: number;
  /** 来源类型 */
  sourceKind: ActionSourceKind;
  /** 时长(毫秒) */
  durationMs: number;
  /** 是否循环 */
  loop: boolean;
  /** 分类 */
  category: ActionCategory;
  /** 排序序号 */
  sortOrder: number;
  /** 是否隐藏(用户偏好) */
  hidden: boolean;
  /** 是否已绑定到槽位 */
  boundSlot: Character3DActionSlot | null;
  /** 骨骼 Profile */
  skeletonProfile: SkeletonProfile;
  /** 兼容等级(相对于当前模型) */
  compatibilityLevel: CompatibilityLevel;
  /** 动作文件 URI(file:// 路径) */
  fileUri: string;
  /** 文件是否存在 */
  fileExists: boolean;
  /** 原始资产(导入动作时有值,内置动作为 null) */
  originalAsset: Character3DActionAsset | null;
}

/**
 * 筛选条件。
 */
export enum ActionFilter {
  /** 全部 */
  All = 'All',
  /** 内置 */
  BuiltIn = 'BuiltIn',
  /** 已导入 */
  Imported = 'Imported',
  /** 循环 */
  Loop = 'Loop',
  /** 单次 */
  Once = 'Once',
  /** 当前模型可用 */
  Available = 'Available',
}

/**
 * 将字符串分类名转换为枚举。
 */
export function parseActionCategory(value: string): ActionCategory {
  if (value === 'base') {
    return ActionCategory.Base;
  }
  if (value === 'social') {
    return ActionCategory.Social;
  }
  if (value === 'emotion') {
    return ActionCategory.Emotion;
  }
  if (value === 'reaction') {
    return ActionCategory.Reaction;
  }
  return ActionCategory.Other;
}

/**
 * 获取来源类型显示名。
 */
export function getSourceKindDisplayName(kind: ActionSourceKind): string {
  switch (kind) {
    case ActionSourceKind.BuiltIn:
      return '内置';
    case ActionSourceKind.Imported:
      return '导入';
    case ActionSourceKind.ModelEmbedded:
      return '模型';
    case ActionSourceKind.MetadataOnly:
      return '元数据';
    default:
      return '';
  }
}
