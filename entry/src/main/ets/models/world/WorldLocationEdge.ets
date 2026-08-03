/**
 * WorldLocationEdge 世界地点有向边模型
 *
 * W-DATA-1A 引入。表示两个 WorldLocation 之间的有向连接。
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 *
 * 设计:
 * - fromLocationId → toLocationId 表示有向连接
 * - isBidirectional = true 表示同一条边双向可通行
 * - directionLabel 只是显示说明,不决定唯一性
 * - 唯一约束:UNIQUE(world_id, from_location_id, to_location_id)
 *   只阻止完全相同的有向边,不阻止 A→B 与 B→A 共存(由 W-DATA-1B Service 处理)
 *
 * 第一版不包含:坐标、距离、旅行时间、通行费用、地形、传送条件、权限表达式。
 *
 * 持久化到 world_location_edges 表。
 */

import { nowMillis } from '../../utils/Time';

export const WORLD_EDGE_ID_PREFIX: string = 'world-edge-';

export interface WorldLocationEdge {
  /** 边 ID(以 'world-edge-' 前缀开头) */
  readonly id: string;
  /** 所属世界 ID */
  readonly worldId: string;
  /** 起点地点 ID */
  readonly fromLocationId: string;
  /** 终点地点 ID */
  readonly toLocationId: string;
  /** 方向显示说明(如"向北"、"穿过森林"),不决定唯一性 */
  readonly directionLabel: string;
  /** 旅行描述 */
  readonly travelDescription: string;
  /** 是否双向可通行 */
  readonly isBidirectional: boolean;
  /** 是否启用 */
  readonly isEnabled: boolean;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateWorldLocationEdgeOptions {
  readonly id: string;
  readonly worldId: string;
  readonly fromLocationId: string;
  readonly toLocationId: string;
  readonly directionLabel?: string;
  readonly travelDescription?: string;
  readonly isBidirectional?: boolean;
  readonly isEnabled?: boolean;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

/**
 * 创建 WorldLocationEdge 记录。
 * - id / worldId / fromLocationId / toLocationId 不能为空
 * - fromLocationId 不能等于 toLocationId(自环)
 * - directionLabel / travelDescription 默认空字符串
 * - isBidirectional 默认 false
 * - isEnabled 默认 true
 * - createdAt / updatedAt 默认当前时间
 */
export function createWorldLocationEdgeRecord(
  options: CreateWorldLocationEdgeOptions
): WorldLocationEdge {
  if (options.id === '') {
    throw new Error('WorldLocationEdge: id empty');
  }
  if (options.worldId === '') {
    throw new Error('WorldLocationEdge: worldId empty');
  }
  if (options.fromLocationId === '') {
    throw new Error('WorldLocationEdge: fromLocationId empty');
  }
  if (options.toLocationId === '') {
    throw new Error('WorldLocationEdge: toLocationId empty');
  }
  if (options.fromLocationId === options.toLocationId) {
    throw new Error('WorldLocationEdge: self-loop not allowed');
  }
  const now: number = nowMillis();
  return {
    id: options.id,
    worldId: options.worldId,
    fromLocationId: options.fromLocationId,
    toLocationId: options.toLocationId,
    directionLabel: options.directionLabel !== undefined ? options.directionLabel : '',
    travelDescription: options.travelDescription !== undefined ? options.travelDescription : '',
    isBidirectional: options.isBidirectional !== undefined ? options.isBidirectional : false,
    isEnabled: options.isEnabled !== undefined ? options.isEnabled : true,
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}
