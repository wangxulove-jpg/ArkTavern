/**
 * Character3DActionAsset 动作资产模型
 *
 * T-3D.6A: 定义独立于模型的动作资产数据结构。
 *
 * 动作文件本体保存在应用私有目录:
 * files/character_actions/{actionId}/
 *   ├── action.glb
 *   ├── metadata.json
 *   └── optional_source.vrma
 *
 * 动作二进制不存入 Preferences 或 RDB。
 */

import { ActionSourceFormat, ActionCompatibility, SkeletonProfile, CompatibilityLevel } from './HumanoidBone';
import { Character3DActionSlot } from './Character3DActionSlot';

/**
 * 动画 Clip 信息(从 GLB 解析)。
 */
export interface AnimationClipInfo {
  /** Clip 在 GLB animations 数组中的索引 */
  index: number;
  /** Clip 名称(GLB JSON 中 animations[].name,无名称时为 'animation_<index>') */
  name: string;
  /** 动画时长(毫秒,从 GLB 解析 max input time) */
  durationMs: number;
  /** 动画通道数量 */
  channelCount: number;
  /** 是否包含平移轨道 */
  hasTranslation: boolean;
  /** 是否包含旋转轨道 */
  hasRotation: boolean;
  /** 是否包含缩放轨道 */
  hasScale: boolean;
  /** 是否包含形变目标轨道 */
  hasMorphTargetWeights: boolean;
}

/**
 * 动作资产(可持久化)。
 */
export interface Character3DActionAsset {
  /** 唯一标识(时间戳+随机数生成) */
  id: string;
  /** 显示名(用户可编辑) */
  displayName: string;
  /** 源文件名 */
  sourceFileName: string;
  /** 应用私有目录内的相对路径(如 character_actions/abc123/action.glb) */
  internalRelativePath: string;
  /** 来源格式 */
  sourceFormat: ActionSourceFormat;
  /** Clip 名称(用户选择的 Clip) */
  clipName: string;
  /** Clip 索引(在 GLB animations 数组中) */
  clipIndex: number;
  /** 绑定的动作槽位(空字符串表示未绑定) */
  slot: string;
  /** 动画时长(毫秒) */
  durationMs: number;
  /** 是否循环 */
  loop: boolean;
  /** 播放速度(0.25~2.0) */
  speed: number;
  /** 骨骼 Profile */
  skeletonProfile: SkeletonProfile;
  /** 兼容等级 */
  compatibilityLevel: CompatibilityLevel;
  /** 兼容性检查结果 */
  actionCompatibility: ActionCompatibility;
  /** 骨骼映射 Profile ID(空字符串表示无映射) */
  boneMappingProfileId: string;
  /** 所有 Clip 信息(多 Clip GLB 时保存全部,用户选择其中一个) */
  allClips: AnimationClipInfo[];
  /** 创建时间(毫秒时间戳) */
  createdAt: number;
  /** 更新时间(毫秒时间戳) */
  updatedAt: number;
  /** 是否内置动作 */
  isBuiltIn: boolean;
  /** 是否启用 */
  enabled: boolean;
}

/**
 * 动作绑定(按 modelId 保存)。
 */
export interface Character3DActionBinding {
  /** 模型标识 */
  modelId: string;
  /** 动作槽位 */
  slot: Character3DActionSlot;
  /** 绑定的动作资产 ID(空字符串表示未绑定) */
  actionAssetId: string;
  /** 绑定的 Clip 名称(模型内置动画时为 Clip 名称) */
  clipName: string;
  /** Clip 索引(模型内置动画时为索引,外部动作为 -1) */
  clipIndex: number;
  /** 是否循环 */
  loop: boolean;
  /** 播放速度 */
  speed: number;
  /** 更新时间 */
  updatedAt: number;
}

/**
 * T-3D.6C-C: 动作循环模式。
 *
 * UseDefault:使用动作资产原始默认值(manifest 中的 loop 字段)。
 * Loop:强制循环播放。
 * PlayOnce:强制只播放一次,完成后回退到 Idle。
 *
 * 不使用单一 boolean,因为 boolean 无法区分:
 * - 用户没有设置(UseDefault);
 * - 用户明确关闭循环(PlayOnce);
 * - 动作默认就是不循环(defaultLoop=false)。
 */
export enum ActionLoopMode {
  /** 使用动作资产原始默认值 */
  UseDefault = 0,
  /** 强制循环播放 */
  Loop = 1,
  /** 强制只播放一次 */
  PlayOnce = 2
}

/**
 * 根据循环模式和动作默认值解析出实际是否循环。
 *
 * 优先级(由调用方保证):per-model binding loopMode → global action loopMode → defaultLoop
 * 本函数只做单层解析:mode 非 UseDefault 时直接返回 mode 对应的布尔值。
 */
export function resolveLoop(loopMode: ActionLoopMode, defaultLoop: boolean): boolean {
  if (loopMode === ActionLoopMode.Loop) {
    return true;
  }
  if (loopMode === ActionLoopMode.PlayOnce) {
    return false;
  }
  return defaultLoop;
}

/**
 * 循环模式显示标签。
 */
export function loopModeToLabel(mode: ActionLoopMode): string {
  switch (mode) {
    case ActionLoopMode.Loop: return '循环播放';
    case ActionLoopMode.PlayOnce: return '播放一次';
    default: return '跟随默认';
  }
}

/**
 * 从数字解析循环模式(反序列化用)。
 */
export function parseLoopMode(value: number): ActionLoopMode {
  if (value === ActionLoopMode.Loop) {
    return ActionLoopMode.Loop;
  }
  if (value === ActionLoopMode.PlayOnce) {
    return ActionLoopMode.PlayOnce;
  }
  return ActionLoopMode.UseDefault;
}

/**
 * 速度范围常量。
 */
export const ACTION_SPEED_MIN: number = 0.25;
export const ACTION_SPEED_MAX: number = 2.0;
export const ACTION_SPEED_DEFAULT: number = 1.0;

/**
 * 文件大小限制常量。
 */
export const ACTION_FILE_MAX_SIZE_BYTES: number = 50 * 1024 * 1024; // 50MB
export const ACTION_MAX_CLIP_COUNT: number = 64;
export const ACTION_MAX_CHANNEL_COUNT: number = 512;
export const ACTION_MAX_DURATION_MS: number = 10 * 60 * 1000; // 10 分钟

/**
 * 生成动作资产 ID。
 */
export function generateActionId(): string {
  const timestamp: number = Date.now();
  const random: number = Math.floor(Math.random() * 1000000);
  return 'act_' + timestamp.toString(36) + '_' + random.toString(36);
}

/**
 * 创建默认动作资产。
 */
export function createDefaultActionAsset(
  id: string,
  displayName: string,
  sourceFileName: string,
  internalRelativePath: string,
  sourceFormat: ActionSourceFormat
): Character3DActionAsset {
  const now: number = Date.now();
  return {
    id: id,
    displayName: displayName,
    sourceFileName: sourceFileName,
    internalRelativePath: internalRelativePath,
    sourceFormat: sourceFormat,
    clipName: '',
    clipIndex: -1,
    slot: '',
    durationMs: 0,
    loop: false,
    speed: ACTION_SPEED_DEFAULT,
    skeletonProfile: SkeletonProfile.Unknown,
    compatibilityLevel: CompatibilityLevel.Unsupported,
    actionCompatibility: ActionCompatibility.MetadataOnly,
    boneMappingProfileId: '',
    allClips: [],
    createdAt: now,
    updatedAt: now,
    isBuiltIn: false,
    enabled: true
  };
}

/**
 * 安全速度值(夹紧到合法范围)。
 */
export function sanitizeSpeed(speed: number): number {
  if (isNaN(speed) || !isFinite(speed)) {
    return ACTION_SPEED_DEFAULT;
  }
  if (speed < ACTION_SPEED_MIN) {
    return ACTION_SPEED_MIN;
  }
  if (speed > ACTION_SPEED_MAX) {
    return ACTION_SPEED_MAX;
  }
  return speed;
}

/**
 * 序列化动作资产为 JSON 字符串。
 */
export function serializeActionAsset(asset: Character3DActionAsset): string {
  return JSON.stringify(asset);
}

/**
 * 反序列化动作资产。
 * 损坏时返回 null。
 */
export function deserializeActionAsset(json: string): Character3DActionAsset | null {
  try {
    const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    return {
      id: String(obj['id'] ?? ''),
      displayName: String(obj['displayName'] ?? ''),
      sourceFileName: String(obj['sourceFileName'] ?? ''),
      internalRelativePath: String(obj['internalRelativePath'] ?? ''),
      sourceFormat: obj['sourceFormat'] as ActionSourceFormat,
      clipName: String(obj['clipName'] ?? ''),
      clipIndex: Number(obj['clipIndex'] ?? -1),
      slot: String(obj['slot'] ?? ''),
      durationMs: Number(obj['durationMs'] ?? 0),
      loop: Boolean(obj['loop'] ?? false),
      speed: sanitizeSpeed(Number(obj['speed'] ?? ACTION_SPEED_DEFAULT)),
      skeletonProfile: obj['skeletonProfile'] as SkeletonProfile,
      compatibilityLevel: obj['compatibilityLevel'] as CompatibilityLevel,
      actionCompatibility: obj['actionCompatibility'] as ActionCompatibility,
      boneMappingProfileId: String(obj['boneMappingProfileId'] ?? ''),
      allClips: parseClipInfos(obj['allClips']),
      createdAt: Number(obj['createdAt'] ?? 0),
      updatedAt: Number(obj['updatedAt'] ?? 0),
      isBuiltIn: Boolean(obj['isBuiltIn'] ?? false),
      enabled: Boolean(obj['enabled'] ?? true)
    };
  } catch (_e) {
    return null;
  }
}

/**
 * 解析 Clip 信息数组。
 */
function parseClipInfos(obj: Object | undefined): AnimationClipInfo[] {
  if (obj === undefined || obj === null) {
    return [];
  }
  if (!(obj instanceof Array)) {
    return [];
  }
  const arr: Object[] = obj as Object[];
  const result: AnimationClipInfo[] = [];
  for (let i: number = 0; i < arr.length; i++) {
    const item: Record<string, Object> = arr[i] as Record<string, Object>;
    result.push({
      index: Number(item['index'] ?? 0),
      name: String(item['name'] ?? ''),
      durationMs: Number(item['durationMs'] ?? 0),
      channelCount: Number(item['channelCount'] ?? 0),
      hasTranslation: Boolean(item['hasTranslation'] ?? false),
      hasRotation: Boolean(item['hasRotation'] ?? false),
      hasScale: Boolean(item['hasScale'] ?? false),
      hasMorphTargetWeights: Boolean(item['hasMorphTargetWeights'] ?? false)
    });
  }
  return result;
}

/**
 * 序列化动作绑定为 JSON 字符串。
 */
export function serializeActionBinding(binding: Character3DActionBinding): string {
  return JSON.stringify(binding);
}

/**
 * 反序列化动作绑定。
 */
export function deserializeActionBinding(json: string): Character3DActionBinding | null {
  try {
    const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    return {
      modelId: String(obj['modelId'] ?? ''),
      slot: obj['slot'] as Character3DActionSlot,
      actionAssetId: String(obj['actionAssetId'] ?? ''),
      clipName: String(obj['clipName'] ?? ''),
      clipIndex: Number(obj['clipIndex'] ?? -1),
      loop: Boolean(obj['loop'] ?? false),
      speed: sanitizeSpeed(Number(obj['speed'] ?? ACTION_SPEED_DEFAULT)),
      updatedAt: Number(obj['updatedAt'] ?? 0)
    };
  } catch (_e) {
    return null;
  }
}
