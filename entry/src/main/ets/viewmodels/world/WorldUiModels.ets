/**
 * WorldUiModels 世界模式只读 UI 模型(W-UI-1)
 *
 * 纯 UI 数据结构,供 WorldHomePage / WorldDetailPage 渲染。
 * 不依赖 Repository / Service / ArkUI。
 *
 * 设计:
 * - 不直接把数据库模型塞入页面 Builder
 * - 角色 / 地点 / 事件统一映射为 UI 友好的扁平结构
 * - 内部 ID 不直接展示,缺失数据安全降级
 */

import { WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldEventType } from '../../models/world/WorldEvent';

/** 跨页面路由用的 worldId 暂存键(由 WorldHomePage 写入,WorldDetailPage 读取后清除) */
export const PENDING_WORLD_ID_KEY: string = 'pendingWorldId';

/** 跨页面路由用的 locationId 暂存键(编辑地点时由详情页写入,编辑页读取后清除) */
export const PENDING_WORLD_LOCATION_ID_KEY: string = 'pendingWorldLocationId';

/** 跨页面路由用的 characterInstanceId 暂存键(管理角色时使用) */
export const PENDING_WORLD_CHARACTER_INSTANCE_ID_KEY: string = 'pendingWorldCharacterInstanceId';

/** 世界列表项 UI 模型 */
export interface WorldSummaryUiModel {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly status: WorldStatus;
  readonly locationCount: number;
  readonly characterCount: number;
  readonly updatedAt: number;
}

/** 世界详情 UI 模型(一次性快照,避免 N+1 查询) */
export interface WorldDetailUiModel {
  readonly world: WorldSummaryUiModel;
  readonly edgeCount: number;
  readonly eventCount: number;
  readonly anomalousEdgeCount: number;
  readonly locations: WorldLocationUiModel[];
  readonly edges: WorldEdgeUiModel[];
  readonly characters: WorldCharacterInstanceUiModel[];
  readonly recentEvents: WorldEventUiModel[];
}

/** 地点 UI 模型 */
export interface WorldLocationUiModel {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly status: WorldLocationStatus;
  readonly createdAt: number;
}

/** 连接边 UI 模型(已解析端点名称,缺失端点标记) */
export interface WorldEdgeUiModel {
  readonly id: string;
  readonly fromLocationId: string;
  readonly toLocationId: string;
  readonly fromLocationName: string;
  readonly toLocationName: string;
  readonly fromLocationMissing: boolean;
  readonly toLocationMissing: boolean;
  readonly directionLabel: string;
  readonly travelDescription: string;
  readonly isBidirectional: boolean;
  readonly isEnabled: boolean;
  /** 是否为异常边(端点缺失 / 自连接 / worldId 不一致) */
  readonly isAnomalous: boolean;
}

/** 角色实例 UI 模型(已解析角色卡名称与位置名称) */
export interface WorldCharacterInstanceUiModel {
  readonly id: string;
  readonly characterId: string;
  readonly displayName: string;
  readonly isActive: boolean;
  readonly currentLocationId: string;
  readonly currentLocationName: string;
  readonly locationMissing: boolean;
  readonly characterCardMissing: boolean;
  readonly avatarUri: string;
  /** 用于头像首字占位 */
  readonly fallbackName: string;
  readonly createdAt: number;
}

/** 世界事件 UI 模型(类型已本地化) */
export interface WorldEventUiModel {
  readonly id: string;
  readonly eventType: WorldEventType;
  readonly localizedType: string;
  readonly summary: string;
  readonly occurredAt: number;
}

/** 世界列表加载状态 */
export enum WorldListState {
  Loading = 'loading',
  Ready = 'ready',
  Empty = 'empty',
  Error = 'error'
}

/** 世界详情加载状态 */
export enum WorldDetailLoadState {
  Loading = 'loading',
  Ready = 'ready',
  NotFound = 'not_found',
  Error = 'error'
}

/**
 * 将 WorldEventType 映射为本地化名称。
 * 未知类型安全返回"未知世界事件",不抛错。
 */
export function localizeWorldEventType(type: WorldEventType): string {
  switch (type) {
    case WorldEventType.WorldCreated: return '世界已创建';
    case WorldEventType.WorldUpdated: return '世界已更新';
    case WorldEventType.WorldArchived: return '世界已归档';
    case WorldEventType.WorldActivated: return '世界已激活';
    case WorldEventType.LocationCreated: return '地点已创建';
    case WorldEventType.LocationUpdated: return '地点已更新';
    case WorldEventType.LocationArchived: return '地点已归档';
    case WorldEventType.LocationActivated: return '地点已激活';
    case WorldEventType.LocationDeleted: return '地点已删除';
    case WorldEventType.EdgeCreated: return '连接已创建';
    case WorldEventType.EdgeUpdated: return '连接已更新';
    case WorldEventType.EdgeDeleted: return '连接已删除';
    case WorldEventType.CharacterJoined: return '角色已加入';
    case WorldEventType.CharacterRemoved: return '角色已移除';
    case WorldEventType.CharacterActivated: return '角色已启用';
    case WorldEventType.CharacterDeactivated: return '角色已停用';
    case WorldEventType.CharacterMoved: return '角色已移动';
    default: return '未知世界事件';
  }
}

/**
 * 格式化时间戳为 YYYY-MM-DD HH:mm。
 * 与 ChatSessionRootView 中 formatArchiveTime 风格一致。
 */
export function formatWorldTimestamp(ts: number): string {
  if (!Number.isFinite(ts) || ts <= 0) {
    return '';
  }
  const d: Date = new Date(ts);
  const year: number = d.getFullYear();
  const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
  const day: string = d.getDate().toString().padStart(2, '0');
  const hour: string = d.getHours().toString().padStart(2, '0');
  const minute: string = d.getMinutes().toString().padStart(2, '0');
  return year + '-' + month + '-' + day + ' ' + hour + ':' + minute;
}
