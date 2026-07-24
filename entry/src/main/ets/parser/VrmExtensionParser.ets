/**
 * VrmExtensionParser VRM 扩展检测与入口
 *
 * T-4.0: VRM First Architecture
 *
 * 职责:
 * 1. 从 glTF JSON 检测 VRM 版本(0.x / 1.0 / 非 VRM)
 * 2. 提供各 VRMC 扩展的入口对象(VRMC_vrm / VRMC_springBone / VRMC_materials_mtoon)
 * 3. 提供 JSON 字段安全提取工具(避免 any,统一 Record<string, Object> 访问)
 *
 * VRM 检测规则:
 * - extensions.VRMC_vrm 存在 → VRM 1.0
 * - extensions.VRM 存在 → VRM 0.x(已弃用但需兼容)
 * - 否则 → NonVrm
 *
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/spec/core/
 * - VRM 0.x: https://vrm.dev/vrm0/
 */

import { VrmVersion, isVrm } from '../models/character3d/vrm/VrmVersion';

/**
 * VRM 扩展检测结果。
 */
export interface VrmExtensionDetection {
  /** VRM 版本 */
  version: VrmVersion;
  /** 是否 VRM */
  isVrm: boolean;
  /** VRMC_vrm 扩展对象(VRM 1.0,null 表示无) */
  vrmcVrm: Record<string, Object> | null;
  /** VRM 扩展对象(VRM 0.x,null 表示无) */
  vrm0Extension: Record<string, Object> | null;
  /** VRMC_springBone 扩展对象(null 表示无) */
  vrmcSpringBone: Record<string, Object> | null;
  /** VRMC_materials_mtoon 是否在 extensionsUsed 中 */
  hasMToonMaterial: boolean;
  /** VRMC_node_constraint 是否在 extensionsUsed 中 */
  hasNodeConstraint: boolean;
  /** 检测错误信息(空表示无错误) */
  error: string;
}

/**
 * 从 glTF JSON 检测 VRM 扩展。
 *
 * @param gltfJson glTF JSON 对象(来自 GLB 解析)
 * @returns 检测结果
 */
export function detectVrmExtension(gltfJson: Record<string, Object>): VrmExtensionDetection {
  const result: VrmExtensionDetection = {
    version: VrmVersion.NonVrm,
    isVrm: false,
    vrmcVrm: null,
    vrm0Extension: null,
    vrmcSpringBone: null,
    hasMToonMaterial: false,
    hasNodeConstraint: false,
    error: ''
  };

  // 获取 extensions 对象
  const extensions: Object | undefined = gltfJson['extensions'];
  if (extensions === undefined) {
    return result; // 非 VRM
  }
  const ext: Record<string, Object> = extensions as Record<string, Object>;

  // 检测 VRM 1.0:extensions.VRMC_vrm
  const vrmcVrm: Object | undefined = ext['VRMC_vrm'];
  if (vrmcVrm !== undefined) {
    result.version = VrmVersion.Vrm1;
    result.isVrm = true;
    result.vrmcVrm = vrmcVrm as Record<string, Object>;
  }

  // 检测 VRM 0.x:extensions.VRM
  if (!result.isVrm) {
    const vrm0: Object | undefined = ext['VRM'];
    if (vrm0 !== undefined) {
      result.version = VrmVersion.Vrm0x;
      result.isVrm = true;
      result.vrm0Extension = vrm0 as Record<string, Object>;
    }
  }

  // VRMC_springBone(VRM 1.0 专有,VRM 0.x 用 secondaryAnimation)
  const vrmcSpringBone: Object | undefined = ext['VRMC_springBone'];
  if (vrmcSpringBone !== undefined) {
    result.vrmcSpringBone = vrmcSpringBone as Record<string, Object>;
  }

  // 检查 extensionsUsed 中的材质/约束扩展
  const extensionsUsed: Object | undefined = gltfJson['extensionsUsed'];
  if (extensionsUsed !== undefined) {
    const used: Object[] = extensionsUsed as Object[];
    for (let i: number = 0; i < used.length; i++) {
      const extName: string = used[i] as string;
      if (extName === 'VRMC_materials_mtoon') {
        result.hasMToonMaterial = true;
      } else if (extName === 'VRMC_node_constraint') {
        result.hasNodeConstraint = true;
      }
    }
  }

  return result;
}

// ==================== JSON 安全提取工具 ====================

/**
 * 安全获取对象字段。
 */
export function getObject(obj: Record<string, Object>, key: string): Record<string, Object> | null {
  const v: Object | undefined = obj[key];
  if (v === undefined) {
    return null;
  }
  return v as Record<string, Object>;
}

/**
 * 安全获取字符串字段。
 */
export function getString(obj: Record<string, Object>, key: string, defaultValue: string = ''): string {
  const v: Object | undefined = obj[key];
  if (v === undefined) {
    return defaultValue;
  }
  if (typeof v === 'string') {
    return v;
  }
  return defaultValue;
}

/**
 * 安全获取数字字段。
 */
export function getNumber(obj: Record<string, Object>, key: string, defaultValue: number = 0): number {
  const v: Object | undefined = obj[key];
  if (v === undefined) {
    return defaultValue;
  }
  if (typeof v === 'number') {
    return v;
  }
  return defaultValue;
}

/**
 * 安全获取布尔字段。
 */
export function getBoolean(obj: Record<string, Object>, key: string, defaultValue: boolean = false): boolean {
  const v: Object | undefined = obj[key];
  if (v === undefined) {
    return defaultValue;
  }
  if (typeof v === 'boolean') {
    return v;
  }
  return defaultValue;
}

/**
 * 安全获取字符串数组字段。
 */
export function getStringArray(obj: Record<string, Object>, key: string): string[] {
  const v: Object | undefined = obj[key];
  if (v === undefined) {
    return [];
  }
  const arr: Object[] = v as Object[];
  const result: string[] = [];
  for (let i: number = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (typeof item === 'string') {
      result.push(item);
    }
  }
  return result;
}

/**
 * 安全获取数字数组字段(如 [x, y, z])。
 */
export function getNumberArray(obj: Record<string, Object>, key: string): number[] {
  const v: Object | undefined = obj[key];
  if (v === undefined) {
    return [];
  }
  const arr: Object[] = v as Object[];
  const result: number[] = [];
  for (let i: number = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (typeof item === 'number') {
      result.push(item);
    }
  }
  return result;
}

/**
 * 安全获取对象数组字段。
 */
export function getObjectArray(obj: Record<string, Object>, key: string): Record<string, Object>[] {
  const v: Object | undefined = obj[key];
  if (v === undefined) {
    return [];
  }
  const arr: Object[] = v as Object[];
  const result: Record<string, Object>[] = [];
  for (let i: number = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    result.push(item as Record<string, Object>);
  }
  return result;
}

/**
 * 安全获取对象数组中的对象字段(如 humanBones 是对象的对象,非数组)。
 *
 * VRM humanBones 是 { "hips": { node: 0 }, "spine": { node: 1 } } 结构,
 * 此函数将其转为 [{ key: "hips", value: { node: 0 } }, ...] 便于遍历。
 */
export function getObjectEntries(obj: Record<string, Object>): VrmObjectEntry[] {
  const result: VrmObjectEntry[] = [];
  const keys: string[] = Object.keys(obj);
  for (let i: number = 0; i < keys.length; i++) {
    const k: string = keys[i];
    const v: Object | undefined = obj[k];
    if (v !== undefined) {
      result.push({ key: k, value: v as Record<string, Object> });
    }
  }
  return result;
}

/**
 * 对象条目(key-value 对)。
 */
export interface VrmObjectEntry {
  key: string;
  value: Record<string, Object>;
}

/**
 * 判断版本是否 VRM(便捷重导出)。
 */
export { isVrm };
