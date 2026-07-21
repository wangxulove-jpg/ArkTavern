/**
 * WorldMember 世界成员模型
 *
 * 表示一个角色在世界中的成员资格和在场状态。
 * - 每个角色在一个世界中只有一条 WorldMember 记录
 * - enabled=false 表示已移出世界(不参与新对话)
 * - present=false 表示暂时离场(不知道离场期间事件)
 * - muted=true 表示静音(在场但不主动发言)
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';
import { InitialRelationship } from './WorldRelationship';

export interface WorldMember {
  readonly id: string;
  readonly worldId: string;
  readonly characterId: string;
  readonly enabled: boolean;
  readonly present: boolean;
  readonly muted: boolean;
  /** 发言活跃度 [0, 1] */
  readonly talkativeness: number;
  /** 显示顺序,越小越靠前 */
  readonly displayOrder: number;
  readonly joinedAt: number;
  /** 加入世界时的初始关系设定(用于新会话初始化) */
  readonly initialRelationship: InitialRelationship;
}

export interface CreateWorldMemberOptions {
  readonly id?: string;
  readonly worldId: string;
  readonly characterId: string;
  readonly enabled?: boolean;
  readonly present?: boolean;
  readonly muted?: boolean;
  readonly talkativeness?: number;
  readonly displayOrder?: number;
  readonly joinedAt?: number;
  readonly initialRelationship?: InitialRelationship;
}

export interface WorldMemberUpdates {
  readonly enabled?: boolean;
  readonly present?: boolean;
  readonly muted?: boolean;
  readonly talkativeness?: number;
  readonly displayOrder?: number;
  readonly initialRelationship?: InitialRelationship;
}

export function createWorldMember(options: CreateWorldMemberOptions): WorldMember {
  const now: number = nowMillis();
  const id: string = options.id !== undefined ? options.id : generateUuid();
  const enabled: boolean = options.enabled !== undefined ? options.enabled : true;
  const present: boolean = options.present !== undefined ? options.present : true;
  const muted: boolean = options.muted !== undefined ? options.muted : false;
  const talkativeness: number =
    options.talkativeness !== undefined
      ? clampTalkativeness(options.talkativeness)
      : 0.5;
  const displayOrder: number =
    options.displayOrder !== undefined ? options.displayOrder : 0;
  const joinedAt: number = options.joinedAt !== undefined ? options.joinedAt : now;
  const initialRelationship: InitialRelationship =
    options.initialRelationship !== undefined
      ? options.initialRelationship
      : {
        relationshipLabel: '',
        addressTerm: '',
        affinity: 0,
        trust: 0,
        currentImpression: '',
        sharedExperiences: '',
        knownSecrets: ''
      };
  return {
    id: id,
    worldId: options.worldId,
    characterId: options.characterId,
    enabled: enabled,
    present: present,
    muted: muted,
    talkativeness: talkativeness,
    displayOrder: displayOrder,
    joinedAt: joinedAt,
    initialRelationship: initialRelationship
  };
}

export function updateWorldMember(
  member: WorldMember,
  updates: WorldMemberUpdates
): WorldMember {
  return {
    id: member.id,
    worldId: member.worldId,
    characterId: member.characterId,
    enabled: updates.enabled !== undefined ? updates.enabled : member.enabled,
    present: updates.present !== undefined ? updates.present : member.present,
    muted: updates.muted !== undefined ? updates.muted : member.muted,
    talkativeness: updates.talkativeness !== undefined
      ? clampTalkativeness(updates.talkativeness) : member.talkativeness,
    displayOrder: updates.displayOrder !== undefined
      ? updates.displayOrder : member.displayOrder,
    joinedAt: member.joinedAt,
    initialRelationship: updates.initialRelationship !== undefined
      ? updates.initialRelationship : member.initialRelationship
  };
}

export function clampTalkativeness(value: number): number {
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}
