/**
 * WorldMapBackground 世界地图背景图模型(W2A3-WORLD-MAP-BACKGROUND)
 *
 * 表示某个 World 的地图背景图片(沙盘式地图底图)。
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 *
 * 设计:
 * - 一个 World 有且仅有一张背景图(数据库 UNIQUE world_id)
 * - 图片以文件形式存储于应用沙箱,imageUri 为沙箱文件 URI
 * - rotation 为图片绕自身中心的旋转角度(弧度),地点坐标随旋转同步转换,保证不错位
 * - fitScale 为图片像素 → 世界坐标的缩放因子(导入时按目标画布 fit 计算,之后保持不变)
 * - 图片的世界显示宽度 = imageWidth * fitScale;高度 = imageHeight * fitScale
 * - 图片中心世界坐标 = (imageWidth * fitScale / 2, imageHeight * fitScale / 2)
 * - 无背景图的 World 使用绝对世界坐标地图(原有行为)
 *
 * 持久化到 world_map_backgrounds 表。
 */

import { nowMillis } from '../../utils/Time';

export const WORLD_MAP_BACKGROUND_ID_PREFIX: string = 'world-map-background-';

export interface WorldMapBackground {
  /** 背景图 ID(以 'world-map-background-' 前缀开头) */
  readonly id: string;
  /** 所属世界 ID */
  readonly worldId: string;
  /** 图片沙箱文件 URI(file://...) */
  readonly imageUri: string;
  /** 图片原始宽度(像素) */
  readonly imageWidth: number;
  /** 图片原始高度(像素) */
  readonly imageHeight: number;
  /** 图片旋转角度(弧度,绕图片中心) */
  readonly rotation: number;
  /** 图片像素 → 世界坐标缩放因子 */
  readonly fitScale: number;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateWorldMapBackgroundOptions {
  readonly id: string;
  readonly worldId: string;
  readonly imageUri: string;
  readonly imageWidth: number;
  readonly imageHeight: number;
  readonly rotation?: number;
  readonly fitScale?: number;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

export function validateBackgroundNumbers(
  imageWidth: number,
  imageHeight: number,
  rotation: number,
  fitScale: number
): void {
  if (!Number.isFinite(imageWidth) || imageWidth <= 0) {
    throw new Error('WorldMapBackground: imageWidth must be finite and > 0');
  }
  if (!Number.isFinite(imageHeight) || imageHeight <= 0) {
    throw new Error('WorldMapBackground: imageHeight must be finite and > 0');
  }
  if (!Number.isFinite(rotation)) {
    throw new Error('WorldMapBackground: rotation is not finite');
  }
  if (!Number.isFinite(fitScale) || fitScale <= 0) {
    throw new Error('WorldMapBackground: fitScale must be finite and > 0');
  }
}

export function createWorldMapBackgroundRecord(
  options: CreateWorldMapBackgroundOptions
): WorldMapBackground {
  if (options.id === '') {
    throw new Error('WorldMapBackground: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldMapBackground: worldId empty');
  }
  if (options.imageUri === '') {
    throw new Error('WorldMapBackground: imageUri empty');
  }
  const rotation: number = options.rotation !== undefined ? options.rotation : 0;
  const fitScale: number = options.fitScale !== undefined ? options.fitScale : 1;
  validateBackgroundNumbers(options.imageWidth, options.imageHeight, rotation, fitScale);
  const now: number = nowMillis();
  return {
    id: options.id,
    worldId: options.worldId,
    imageUri: options.imageUri,
    imageWidth: options.imageWidth,
    imageHeight: options.imageHeight,
    rotation: rotation,
    fitScale: fitScale,
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}

/** 图片的世界显示宽度(世界坐标单位) */
export function backgroundWorldWidth(background: WorldMapBackground): number {
  return background.imageWidth * background.fitScale;
}

/** 图片的世界显示高度(世界坐标单位) */
export function backgroundWorldHeight(background: WorldMapBackground): number {
  return background.imageHeight * background.fitScale;
}

/** 图片中心的世界 X 坐标 */
export function backgroundCenterX(background: WorldMapBackground): number {
  return backgroundWorldWidth(background) / 2;
}

/** 图片中心的世界 Y 坐标 */
export function backgroundCenterY(background: WorldMapBackground): number {
  return backgroundWorldHeight(background) / 2;
}

/**
 * 将点 (x, y) 围绕中心 (centerX, centerY) 旋转 deltaRadians 弧度。
 * 返回 [新x, 新y]。
 */
export function rotatePointAroundCenter(
  x: number,
  y: number,
  centerX: number,
  centerY: number,
  deltaRadians: number
): number[] {
  const cosR: number = Math.cos(deltaRadians);
  const sinR: number = Math.sin(deltaRadians);
  const dx: number = x - centerX;
  const dy: number = y - centerY;
  return [
    centerX + dx * cosR - dy * sinR,
    centerY + dx * sinR + dy * cosR
  ];
}
