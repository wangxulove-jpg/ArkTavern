/**
 * ModelBounds 3D 模型包围盒与自适应视角计算(纯逻辑,无平台依赖)
 *
 * 临时开发测试: T-3D.4A 导入模型不可见修复
 *
 * 职责:
 * - 从 GltfModelInfo.boundsMin/boundsMax 计算 ModelBounds(中心/尺寸/半径)
 * - 根据 ModelBounds 计算自适应显示配置(scale/offset/cameraDistance)
 * - 防御 NaN/Infinity/极小值/极大值
 * - 不依赖 ArkUI / ArkGraphics3D,可独立单元测试
 *
 * 自适应策略:
 * - 模型中心移到原点(offsetX/Y/Z = -center * scale)
 * - 期望模型高度约为 2.0 单位(scale = targetHeight / height)
 * - 相机距离根据包围球半径和 FOV 计算,留 20% margin
 * - 相机在 (0, 0, cameraDistance) 看向 -Z,模型中心在原点 → 一定在视口中央
 */

import { GltfModelInfo } from '../../parser/GltfValidator';
import {
  Character3DDisplayConfig,
  SCALE_MIN,
  SCALE_MAX,
  OFFSET_MIN,
  OFFSET_MAX,
  CAMERA_DISTANCE_MIN,
  CAMERA_DISTANCE_MAX,
  DEFAULT_SCALE,
  DEFAULT_OFFSET_X,
  DEFAULT_OFFSET_Y,
  DEFAULT_OFFSET_Z,
  DEFAULT_ROTATION_X_DEG,
  DEFAULT_ROTATION_Y_DEG,
  DEFAULT_ROTATION_Z_DEG,
  DEFAULT_CAMERA_DISTANCE,
  CAMERA_FOV
} from './Character3DDisplayConfig';

/** 期望模型在视口中的高度(单位:场景坐标) */
const TARGET_MODEL_HEIGHT: number = 2.0;
/** Camera Fit 的 margin 系数(留 20% 边距) */
const CAMERA_FIT_MARGIN: number = 1.2;
/** Bounds 尺寸的下限(小于此值视为退化模型,使用默认配置) */
const MIN_BOUNDS_SIZE: number = 1e-6;
/** Bounds 尺寸的上限(大于此值视为异常,使用默认配置) */
const MAX_BOUNDS_SIZE: number = 1e6;

/**
 * 3D 模型包围盒(已计算中心/尺寸/半径)。
 */
export interface ModelBounds {
  /** X 轴最小值 */
  minX: number;
  /** Y 轴最小值 */
  minY: number;
  /** Z 轴最小值 */
  minZ: number;
  /** X 轴最大值 */
  maxX: number;
  /** Y 轴最大值 */
  maxY: number;
  /** Z 轴最大值 */
  maxZ: number;
  /** 中心 X */
  centerX: number;
  /** 中心 Y */
  centerY: number;
  /** 中心 Z */
  centerZ: number;
  /** 宽度(X 方向) */
  width: number;
  /** 高度(Y 方向) */
  height: number;
  /** 深度(Z 方向) */
  depth: number;
  /** 包围球半径 */
  radius: number;
}

/**
 * 从 GltfModelInfo 计算 ModelBounds。
 *
 * @param modelInfo GLTF 模型摘要(必须包含 boundsMin/boundsMax)
 * @returns ModelBounds;无有效 Bounds 时返回 null
 */
export function computeBoundsFromGltf(modelInfo: GltfModelInfo): ModelBounds | null {
  if (modelInfo === null || modelInfo === undefined) {
    return null;
  }
  const min: number[] | null = modelInfo.boundsMin;
  const max: number[] | null = modelInfo.boundsMax;
  if (min === null || max === null) {
    return null;
  }
  if (min.length < 3 || max.length < 3) {
    return null;
  }
  const minX: number = min[0];
  const minY: number = min[1];
  const minZ: number = min[2];
  const maxX: number = max[0];
  const maxY: number = max[1];
  const maxZ: number = max[2];
  // 防御 NaN / Infinity
  if (!Number.isFinite(minX) || !Number.isFinite(minY) || !Number.isFinite(minZ)
    || !Number.isFinite(maxX) || !Number.isFinite(maxY) || !Number.isFinite(maxZ)) {
    return null;
  }
  // 防御 min > max(非法 Bounds)
  if (minX > maxX || minY > maxY || minZ > maxZ) {
    return null;
  }
  const width: number = maxX - minX;
  const height: number = maxY - minY;
  const depth: number = maxZ - minZ;
  // 防御退化或异常尺寸
  if (width < MIN_BOUNDS_SIZE || height < MIN_BOUNDS_SIZE || depth < MIN_BOUNDS_SIZE) {
    return null;
  }
  if (width > MAX_BOUNDS_SIZE || height > MAX_BOUNDS_SIZE || depth > MAX_BOUNDS_SIZE) {
    return null;
  }
  const centerX: number = (minX + maxX) / 2;
  const centerY: number = (minY + maxY) / 2;
  const centerZ: number = (minZ + maxZ) / 2;
  // 包围球半径 = 对角线长度 / 2
  const radius: number = Math.sqrt(width * width + height * height + depth * depth) / 2;
  if (!Number.isFinite(radius) || radius < MIN_BOUNDS_SIZE) {
    return null;
  }
  return {
    minX, minY, minZ,
    maxX, maxY, maxZ,
    centerX, centerY, centerZ,
    width, height, depth,
    radius
  };
}

/**
 * 根据模型 Bounds 计算自适应显示配置。
 *
 * 算法:
 * 1. scale = TARGET_MODEL_HEIGHT / bounds.height,夹紧到 [SCALE_MIN, SCALE_MAX]
 * 2. offsetX/Y/Z = 0(T-3D.5A: offset 含义改为"模型中心目标位置",autoFit 时模型中心在原点)
 *    旋转中心跟随由 applyDisplayConfigToScene 的数学补偿负责:
 *    rootNode.position = offset - R*(center*scale),使模型中心固定在 offset 位置
 * 3. cameraDistance = (bounds.radius * scale) / sin(FOV/2) * margin,夹紧到 [CAMERA_DISTANCE_MIN, CAMERA_DISTANCE_MAX]
 * 4. rotation 归零(面向相机)
 *
 * T-3D.5A 变更:offset 从 -center*scale 改为 0
 * - 旧版:offset = -center*scale,rootNode.position = offset,把模型中心移到原点(仅 R=0 时有效)
 * - 新版:offset = 0,rootNode.position = offset - R*(center*scale),模型中心始终在 offset 位置
 * - 用户调整 offset → 模型中心移动(不是 rootNode 移动)
 * - 旋转 → 模型围绕自己中心旋转(原地自转)
 *
 * @param bounds 模型包围盒
 * @returns 自适应显示配置;bounds 非法时返回全局默认配置
 */
export function computeAutoFitDisplayConfig(bounds: ModelBounds | null): Character3DDisplayConfig {
  if (bounds === null) {
    return createGlobalDefaultConfig();
  }
  // 1. 计算 scale
  let scale: number = TARGET_MODEL_HEIGHT / bounds.height;
  if (!Number.isFinite(scale) || scale <= 0) {
    scale = DEFAULT_SCALE;
  }
  if (scale < SCALE_MIN) {
    scale = SCALE_MIN;
  }
  if (scale > SCALE_MAX) {
    scale = SCALE_MAX;
  }

  // 2. T-3D.5A: offset = 0(模型中心在原点)
  // 旋转中心跟随由 applyDisplayConfigToScene 的数学补偿负责
  const offsetX: number = DEFAULT_OFFSET_X;
  const offsetY: number = DEFAULT_OFFSET_Y;
  const offsetZ: number = DEFAULT_OFFSET_Z;

  // 3. 计算 cameraDistance
  // 包围球半径(应用 scale 后)
  const scaledRadius: number = bounds.radius * scale;
  // FOV 半角(弧度)
  const fovHalfRad: number = (CAMERA_FOV * Math.PI / 180) / 2;
  const sinFovHalf: number = Math.sin(fovHalfRad);
  let cameraDistance: number;
  if (sinFovHalf <= 0) {
    cameraDistance = DEFAULT_CAMERA_DISTANCE;
  } else {
    cameraDistance = (scaledRadius / sinFovHalf) * CAMERA_FIT_MARGIN;
  }
  if (!Number.isFinite(cameraDistance) || cameraDistance <= 0) {
    cameraDistance = DEFAULT_CAMERA_DISTANCE;
  }
  if (cameraDistance < CAMERA_DISTANCE_MIN) {
    cameraDistance = CAMERA_DISTANCE_MIN;
  }
  if (cameraDistance > CAMERA_DISTANCE_MAX) {
    cameraDistance = CAMERA_DISTANCE_MAX;
  }

  return {
    scale: scale,
    offsetX: offsetX,
    offsetY: offsetY,
    offsetZ: offsetZ,
    rotationXDeg: DEFAULT_ROTATION_X_DEG,
    rotationYDeg: DEFAULT_ROTATION_Y_DEG,
    rotationZDeg: DEFAULT_ROTATION_Z_DEG,
    cameraDistance: cameraDistance
  };
}

/**
 * 判断 Bounds 是否有效(非 null 且尺寸合法)。
 */
export function isBoundsValid(bounds: ModelBounds | null): boolean {
  if (bounds === null) {
    return false;
  }
  if (!Number.isFinite(bounds.width) || !Number.isFinite(bounds.height) || !Number.isFinite(bounds.depth)) {
    return false;
  }
  if (bounds.width < MIN_BOUNDS_SIZE || bounds.height < MIN_BOUNDS_SIZE || bounds.depth < MIN_BOUNDS_SIZE) {
    return false;
  }
  return true;
}

/**
 * 创建全局默认配置(用于 Bounds 非法时回退)。
 */
function createGlobalDefaultConfig(): Character3DDisplayConfig {
  return {
    scale: DEFAULT_SCALE,
    offsetX: DEFAULT_OFFSET_X,
    offsetY: DEFAULT_OFFSET_Y,
    offsetZ: DEFAULT_OFFSET_Z,
    rotationXDeg: DEFAULT_ROTATION_X_DEG,
    rotationYDeg: DEFAULT_ROTATION_Y_DEG,
    rotationZDeg: DEFAULT_ROTATION_Z_DEG,
    cameraDistance: DEFAULT_CAMERA_DISTANCE
  };
}

/**
 * 夹紧 offset 到 [OFFSET_MIN, OFFSET_MAX],防御 NaN/Infinity。
 */
function clampOffset(value: number): number {
  if (!Number.isFinite(value)) {
    return DEFAULT_OFFSET_X;
  }
  if (value < OFFSET_MIN) {
    return OFFSET_MIN;
  }
  if (value > OFFSET_MAX) {
    return OFFSET_MAX;
  }
  return value;
}
