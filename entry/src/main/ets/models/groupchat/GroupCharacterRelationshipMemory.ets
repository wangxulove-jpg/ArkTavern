/**
 * GroupCharacterRelationshipMemory 多人角色定向关系记忆模型
 *
 * G-MEMORY-AUTO-1B 引入。表示某个 owner 角色对某个 target 对象(User/Character)
 * 在某个群聊中的定向关系摘要。
 *
 * 所有权(核心语义,严格不变):
 * - 关系严格属于 (groupConversationId, ownerCharacterId, targetType, targetId) 四元组
 * - groupConversationId 对应 chats.id(ConversationMode=Group)
 * - ownerCharacterId 对应 characters.id(发起方角色卡)
 * - targetType ∈ {user, character}
 * - targetId:User 固定为 'user';Character 为 characters.id
 * - 关系有方向:A→B 与 B→A 完全隔离,各自一条记录
 * - 第一版每个方向对象只保留一条当前关系摘要(UNIQUE 约束)
 * - 再次批准新总结时 UPDATE 现有记录,保留新 sourceMessageIds/sourceHash/updatedAt
 * - 成员移除后关系记录保留(重新加入时恢复正常展示)
 * - 删除整个群聊时同事务级联清理
 * - 删除角色卡时关系记录保留(角色缺失时 UI 安全降级显示"角色已删除")
 *
 * sourceType 固定为 'relationship_summary_v1',用于区分未来其他来源。
 *
 * 持久化到 group_character_relationship_memories 表(V19)。
 */

import { nowMillis } from '../../utils/Time';
import {
  normalizeKeywords,
  parseKeywordsFromText,
  keywordsToText
} from './GroupCharacterMemory';

/** 关系对象类型 */
export enum GroupRelationshipTargetType {
  /** 用户(群聊中固定标识 'user') */
  User = 'user',
  /** 角色(characters.id) */
  Character = 'character'
}

/** 关系记忆状态 */
export enum GroupRelationshipMemoryStatus {
  /** 活跃(默认,未来可进入 Prompt) */
  Active = 'active',
  /** 已归档(用户主动归档,不进入未来 Prompt) */
  Archived = 'archived',
  /** 已失效(来源消息失效,本阶段不自动生成,但必须安全处理) */
  Invalidated = 'invalidated'
}

/** 用户固定 ID(与项目已有用户身份约定保持一致) */
export const RELATIONSHIP_USER_TARGET_ID: string = 'user';

/** 关系记忆 ID 前缀 */
export const GROUP_CHARACTER_RELATIONSHIP_MEMORY_ID_PREFIX: string = 'group-character-relationship-';

/** 自动总结来源类型标识(写入 source_type 字段) */
export const SOURCE_TYPE_RELATIONSHIP_SUMMARY_V1: string = 'relationship_summary_v1';

/** 各摘要字段长度上限 */
export const RELATIONSHIP_EXPERIENCE_SUMMARY_MAX: number = 2000;
export const RELATIONSHIP_ATTITUDE_SUMMARY_MAX: number = 2000;
export const RELATIONSHIP_RELATIONSHIP_SUMMARY_MAX: number = 2000;

/** 重要度范围(1-5,默认 3) */
export const RELATIONSHIP_IMPORTANCE_MIN: number = 1;
export const RELATIONSHIP_IMPORTANCE_MAX: number = 5;
export const RELATIONSHIP_IMPORTANCE_DEFAULT: number = 3;

export interface GroupCharacterRelationshipMemory {
  /** 记忆 ID(以 'group-character-relationship-' 前缀开头) */
  readonly id: string;
  /** 所属群聊会话 ID(chats.id,ConversationMode=Group) */
  readonly groupConversationId: string;
  /** 发起方角色 ID(characters.id) */
  readonly ownerCharacterId: string;

  /** 关系对象类型 */
  readonly targetType: GroupRelationshipTargetType;
  /** 关系对象 ID(User 固定 'user';Character 为 characters.id) */
  readonly targetId: string;

  /** 共同经历摘要 */
  readonly experienceSummary: string;
  /** owner 对对方的态度摘要 */
  readonly attitudeSummary: string;
  /** 当前关系概括 */
  readonly relationshipSummary: string;

  /** 重要度(1-5,默认 3) */
  readonly importance: number;
  /** 关键词列表(去重去空) */
  readonly keywords: string[];

  /** 来源消息 ID 列表(JSON 数组持久化) */
  readonly sourceMessageIds: string[];
  /** 来源内容哈希(稳定哈希,防重复) */
  readonly sourceHash: string;
  /** 来源类型(固定 'relationship_summary_v1') */
  readonly sourceType: string;

  /** 状态 */
  readonly status: GroupRelationshipMemoryStatus;

  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateGroupCharacterRelationshipMemoryOptions {
  readonly id: string;
  readonly groupConversationId: string;
  readonly ownerCharacterId: string;
  readonly targetType: GroupRelationshipTargetType;
  readonly targetId: string;
  readonly experienceSummary: string;
  readonly attitudeSummary: string;
  readonly relationshipSummary: string;
  readonly importance?: number;
  readonly keywords?: string[];
  readonly sourceMessageIds: string[];
  readonly sourceHash: string;
  readonly sourceType?: string;
  readonly status?: GroupRelationshipMemoryStatus;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

/** 更新可编辑字段输入(用于 Service.updateEditableFields) */
export interface UpdateRelationshipMemoryEditableFields {
  readonly experienceSummary: string;
  readonly attitudeSummary: string;
  readonly relationshipSummary: string;
  readonly importance: number;
  readonly keywords: string[];
}

/**
 * 创建 GroupCharacterRelationshipMemory 记录。
 * - id / groupConversationId / ownerCharacterId / targetId / sourceHash 不能为空
 * - targetType 必须合法
 * - targetId !== ownerCharacterId(不能对自己建立关系)
 * - experienceSummary / attitudeSummary / relationshipSummary 至少一个非空
 * - importance 默认 3,范围 [1, 5]
 * - keywords 默认空数组,自动去空去重
 * - sourceType 默认 'relationship_summary_v1'
 * - status 默认 Active
 * - createdAt / updatedAt 默认当前时间
 */
export function createGroupCharacterRelationshipMemoryRecord(
  options: CreateGroupCharacterRelationshipMemoryOptions
): GroupCharacterRelationshipMemory {
  if (options.id === '') {
    throw new Error('GroupCharacterRelationshipMemory: id empty');
  }
  if (options.groupConversationId === '') {
    throw new Error('GroupCharacterRelationshipMemory: groupConversationId empty');
  }
  if (options.ownerCharacterId === '') {
    throw new Error('GroupCharacterRelationshipMemory: ownerCharacterId empty');
  }
  if (!isGroupRelationshipTargetType(options.targetType)) {
    throw new Error('GroupCharacterRelationshipMemory: invalid targetType');
  }
  if (options.targetId === '') {
    throw new Error('GroupCharacterRelationshipMemory: targetId empty');
  }
  // 不允许 owner === target(对 Character 类型)
  if (options.targetType === GroupRelationshipTargetType.Character
    && options.targetId === options.ownerCharacterId) {
    throw new Error('GroupCharacterRelationshipMemory: targetId cannot equal ownerCharacterId');
  }
  const experienceTrimmed: string = options.experienceSummary.trim();
  const attitudeTrimmed: string = options.attitudeSummary.trim();
  const relationshipTrimmed: string = options.relationshipSummary.trim();
  if (experienceTrimmed === '' && attitudeTrimmed === '' && relationshipTrimmed === '') {
    throw new Error('GroupCharacterRelationshipMemory: at least one summary must be non-empty');
  }
  if (experienceTrimmed.length > RELATIONSHIP_EXPERIENCE_SUMMARY_MAX) {
    throw new Error('GroupCharacterRelationshipMemory: experienceSummary too long');
  }
  if (attitudeTrimmed.length > RELATIONSHIP_ATTITUDE_SUMMARY_MAX) {
    throw new Error('GroupCharacterRelationshipMemory: attitudeSummary too long');
  }
  if (relationshipTrimmed.length > RELATIONSHIP_RELATIONSHIP_SUMMARY_MAX) {
    throw new Error('GroupCharacterRelationshipMemory: relationshipSummary too long');
  }
  if (options.sourceMessageIds.length === 0) {
    throw new Error('GroupCharacterRelationshipMemory: sourceMessageIds empty');
  }
  if (options.sourceHash === '') {
    throw new Error('GroupCharacterRelationshipMemory: sourceHash empty');
  }
  const importance: number = options.importance !== undefined
    ? options.importance : RELATIONSHIP_IMPORTANCE_DEFAULT;
  if (!isRelationshipImportance(importance)) {
    throw new Error('GroupCharacterRelationshipMemory: importance out of range');
  }
  const status: GroupRelationshipMemoryStatus = options.status !== undefined
    ? options.status : GroupRelationshipMemoryStatus.Active;
  if (!isGroupRelationshipMemoryStatus(status)) {
    throw new Error('GroupCharacterRelationshipMemory: invalid status');
  }
  const sourceType: string = options.sourceType !== undefined
    ? options.sourceType : SOURCE_TYPE_RELATIONSHIP_SUMMARY_V1;
  if (sourceType === '') {
    throw new Error('GroupCharacterRelationshipMemory: sourceType empty');
  }
  const now: number = nowMillis();
  return {
    id: options.id,
    groupConversationId: options.groupConversationId,
    ownerCharacterId: options.ownerCharacterId,
    targetType: options.targetType,
    targetId: options.targetId,
    experienceSummary: experienceTrimmed,
    attitudeSummary: attitudeTrimmed,
    relationshipSummary: relationshipTrimmed,
    importance: importance,
    keywords: normalizeKeywords(options.keywords),
    sourceMessageIds: normalizeMessageIds(options.sourceMessageIds),
    sourceHash: options.sourceHash,
    sourceType: sourceType,
    status: status,
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}

/** 判断字符串是否为合法 GroupRelationshipTargetType */
export function isGroupRelationshipTargetType(value: string): boolean {
  return value === GroupRelationshipTargetType.User
    || value === GroupRelationshipTargetType.Character;
}

/** 判断字符串是否为合法 GroupRelationshipMemoryStatus */
export function isGroupRelationshipMemoryStatus(value: string): boolean {
  return value === GroupRelationshipMemoryStatus.Active
    || value === GroupRelationshipMemoryStatus.Archived
    || value === GroupRelationshipMemoryStatus.Invalidated;
}

/** 判断数值是否为合法重要度 [1, 5] */
export function isRelationshipImportance(value: number): boolean {
  return Number.isInteger(value)
    && value >= RELATIONSHIP_IMPORTANCE_MIN
    && value <= RELATIONSHIP_IMPORTANCE_MAX;
}

/** 规范化来源消息 ID 列表(去空去重,保留顺序) */
export function normalizeMessageIds(raw: string[]): string[] {
  if (raw === undefined || raw.length === 0) {
    return [];
  }
  const seen: Set<string> = new Set<string>();
  const result: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    const trimmed: string = (raw[i] !== undefined ? String(raw[i]) : '').trim();
    if (trimmed === '') {
      continue;
    }
    if (seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);
    result.push(trimmed);
  }
  return result;
}

/** 解析来源消息 ID JSON */
export function parseSourceMessageIdsJson(raw: string): string[] {
  if (raw === undefined || raw === '' || raw === '[]') {
    return [];
  }
  try {
    const parsed: Object = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }
    const items: string[] = [];
    for (let i = 0; i < parsed.length; i++) {
      const item: Object | undefined = parsed[i];
      if (item !== null && item !== undefined) {
        items.push(String(item));
      }
    }
    return normalizeMessageIds(items);
  } catch (e) {
    return [];
  }
}

/** 将来源消息 ID 列表序列化为 JSON */
export function sourceMessageIdsToJson(ids: string[]): string {
  return JSON.stringify(ids);
}

// 复用 GroupCharacterMemory 的关键词处理函数,保持一致语义
export {
  normalizeKeywords,
  parseKeywordsFromText,
  keywordsToText
};
