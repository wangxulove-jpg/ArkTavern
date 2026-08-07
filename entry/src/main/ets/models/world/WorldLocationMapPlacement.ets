/**
 * WorldLocationMapPlacement 地图放置模型(W1C-WORLD-MAP-CONTRACT)
 *
 * 表示某个 World 下某个 Location 在 3D 空间中的视觉放置位置。
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 *
 * 设计:
 * - 一个 World 有且仅有一个地图(单地图设计)
 * - 一个 Location 在同一个 World 中只能有一个 Placement(UNIQUE world_id, location_id)
 * - position/rotation/scale 为视觉属性,不影响逻辑关系
 * - position 必须是有限数(禁止 NaN/Infinity)
 * - rotation 必须是有限数(禁止 NaN/Infinity),默认 0
 * - scale 必须是有限数且 > 0(禁止 NaN/Infinity/0/负数),默认 1
 * - 不做静默修正/裁剪/默认值替换,无效值直接拒绝
 * - 无 Placement 的 Location 是合法的(空 World 可以有 0 个 Placement)
 *
 * 持久化到 world_location_map_placements 表。
 */

import { nowMillis } from '../../utils/Time';

export const WORLD_MAP_PLACEMENT_ID_PREFIX: string = 'world-map-placement-';

export interface WorldLocationMapPlacement {
  /** 放置 ID(以 'world-map-placement-' 前缀开头) */
  readonly id: string;
  /** 所属世界 ID */
  readonly worldId: string;
  /** 关联地点 ID */
  readonly locationId: string;
  /** X 坐标位置 */
  readonly positionX: number;
  /** Y 坐标位置 */
  readonly positionY: number;
  /** Z 坐标位置 */
  readonly positionZ: number;
  /** X 轴旋转(弧度) */
  readonly rotationX: number;
  /** Y 轴旋转(弧度) */
  readonly rotationY: number;
  /** Z 轴旋转(弧度) */
  readonly rotationZ: number;
  /** 缩放因子 */
  readonly scale: number;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateWorldLocationMapPlacementOptions {
  readonly id: string;
  readonly worldId: string;
  readonly locationId: string;
  readonly positionX: number;
  readonly positionY: number;
  readonly positionZ: number;
  readonly rotationX?: number;
  readonly rotationY?: number;
  readonly rotationZ?: number;
  readonly scale?: number;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

export interface UpdateWorldLocationMapPlacementPositionOptions {
  readonly positionX: number;
  readonly positionY: number;
  readonly positionZ: number;
}

export interface UpdateWorldLocationMapPlacementTransformOptions {
  readonly positionX: number;
  readonly positionY: number;
  readonly positionZ: number;
  readonly rotationX: number;
  readonly rotationY: number;
  readonly rotationZ: number;
  readonly scale: number;
}

function isFiniteNumber(value: number): boolean {
  return Number.isFinite(value);
}

function isFinitePositiveNumber(value: number): boolean {
  return Number.isFinite(value) && value > 0;
}

export function validatePlacementNumbers(
  positionX: number,
  positionY: number,
  positionZ: number,
  rotationX: number,
  rotationY: number,
  rotationZ: number,
  scale: number
): void {
  if (!isFiniteNumber(positionX)) {
    throw new Error('WorldLocationMapPlacement: positionX is not finite');
  }
  if (!isFiniteNumber(positionY)) {
    throw new Error('WorldLocationMapPlacement: positionY is not finite');
  }
  if (!isFiniteNumber(positionZ)) {
    throw new Error('WorldLocationMapPlacement: positionZ is not finite');
  }
  if (!isFiniteNumber(rotationX)) {
    throw new Error('WorldLocationMapPlacement: rotationX is not finite');
  }
  if (!isFiniteNumber(rotationY)) {
    throw new Error('WorldLocationMapPlacement: rotationY is not finite');
  }
  if (!isFiniteNumber(rotationZ)) {
    throw new Error('WorldLocationMapPlacement: rotationZ is not finite');
  }
  if (!isFinitePositiveNumber(scale)) {
    throw new Error('WorldLocationMapPlacement: scale must be finite and > 0');
  }
}

export function createWorldLocationMapPlacementRecord(
  options: CreateWorldLocationMapPlacementOptions
): WorldLocationMapPlacement {
  if (options.id === '') {
    throw new Error('WorldLocationMapPlacement: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldLocationMapPlacement: worldId empty');
  }
  if (options.locationId === '') {
    throw new Error('WorldLocationMapPlacement: locationId empty');
  }
  const rotationX: number = options.rotationX !== undefined ? options.rotationX : 0;
  const rotationY: number = options.rotationY !== undefined ? options.rotationY : 0;
  const rotationZ: number = options.rotationZ !== undefined ? options.rotationZ : 0;
  const scale: number = options.scale !== undefined ? options.scale : 1;
  validatePlacementNumbers(
    options.positionX, options.positionY, options.positionZ,
    rotationX, rotationY, rotationZ, scale
  );
  const now: number = nowMillis();
  return {
    id: options.id,
    worldId: options.worldId,
    locationId: options.locationId,
    positionX: options.positionX,
    positionY: options.positionY,
    positionZ: options.positionZ,
    rotationX: rotationX,
    rotationY: rotationY,
    rotationZ: rotationZ,
    scale: scale,
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}
