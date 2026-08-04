/**
 * GroupCharacterMemory 多人聊天每角色独立记忆模型
 *
 * G-MEMORY-1A 引入。表示某个角色在某个群聊中的独立长期记忆。
 *
 * 所有权(核心语义,严格不变):
 * - 记忆严格属于 (groupConversationId, characterId) 二元组
 * - groupConversationId 对应 chats.id(ConversationMode=Group)
 * - characterId 对应 characters.id(角色卡)
 * - 同一角色在不同群聊中的记忆完全隔离
 * - 角色被移出群聊时记忆保留,重新加入时恢复
 * - 删除整个群聊时同事务级联清理
 * - 删除角色卡时记忆保留(角色缺失时 UI 安全降级显示"角色已删除")
 *
 * 来源字段语义(交互记忆预留,本阶段不写入):
 * - sourceMessageId / sourceRoundId / sourceSenderCharacterId / sourceType / sourceHash
 * - 仅 origin=Interaction 时存在;本阶段 UI 不创建
 * - 来源引用失效时记忆仍保留,UI 安全降级显示"来源已失效"等
 * - 交互记忆的自动生成 / 自动审批 / 自动失效留给 G-MEMORY-1B / G-MEMORY-1C
 *
 * 本阶段 UI 创建的记忆固定:
 * - origin = Manual
 * - status = Active
 * - source_* = undefined
 *
 * Interaction origin 为后续阶段保留,本阶段不通过 UI 创建,也不允许手动改为 Interaction。
 *
 * 持久化到 group_character_memories 表(V18)。
 */

import { nowMillis } from '../../utils/Time';

/** 记忆来源 */
export enum GroupCharacterMemoryOrigin {
  /** 用户手动创建(本阶段唯一来源) */
  Manual = 'manual',
  /** 从群聊消息自动提取(G-MEMORY-1B 预留,本阶段不创建) */
  Interaction = 'interaction'
}

/** 记忆状态 */
export enum GroupCharacterMemoryStatus {
  /** 活跃(默认,未来可进入 Prompt) */
  Active = 'active',
  /** 已归档(用户主动归档,不进入未来 Prompt) */
  Archived = 'archived',
  /** 已失效(交互记忆来源失效,G-MEMORY-1B 预留,本阶段不由手动 UI 创建) */
  Invalidated = 'invalidated'
}

export const GROUP_CHARACTER_MEMORY_ID_PREFIX: string = 'group-character-memory-';

/** 标题长度上限 */
export const GROUP_CHARACTER_MEMORY_TITLE_MAX: number = 80;
/** 正文长度上限 */
export const GROUP_CHARACTER_MEMORY_CONTENT_MAX: number = 4000;
/** 重要度下限(含) */
export const GROUP_CHARACTER_MEMORY_IMPORTANCE_MIN: number = 1;
/** 重要度上限(含) */
export const GROUP_CHARACTER_MEMORY_IMPORTANCE_MAX: number = 5;
/** 重要度默认值 */
export const GROUP_CHARACTER_MEMORY_IMPORTANCE_DEFAULT: number = 3;
/** 关键词数量上限 */
export const GROUP_CHARACTER_MEMORY_KEYWORDS_MAX: number = 20;
/** 单个关键词长度上限 */
export const GROUP_CHARACTER_MEMORY_KEYWORD_MAX_LENGTH: number = 40;

export interface GroupCharacterMemory {
  /** 记忆 ID(以 'group-character-memory-' 前缀开头) */
  readonly id: string;
  /** 所属群聊会话 ID(chats.id,ConversationMode=Group) */
  readonly groupConversationId: string;
  /** 所属角色 ID(characters.id,角色卡) */
  readonly characterId: string;

  /** 记忆来源 */
  readonly origin: GroupCharacterMemoryOrigin;
  /** 记忆状态 */
  readonly status: GroupCharacterMemoryStatus;

  /** 记忆标题 */
  readonly title: string;
  /** 记忆正文 */
  readonly content: string;
  /** 重要度(1-5,默认 3) */
  readonly importance: number;
  /** 关键词列表(去重去空) */
  readonly keywords: string[];

  /** 来源消息 ID(可空,仅 origin=Interaction 时存在) */
  readonly sourceMessageId?: string;
  /** 来源轮次 ID(可空,仅 origin=Interaction 时存在) */
  readonly sourceRoundId?: string;
  /** 来源发言角色 ID(可空,仅 origin=Interaction 时存在) */
  readonly sourceSenderCharacterId?: string;
  /** 来源类型(可空,仅 origin=Interaction 时存在,如 'user_message' / 'ai_message') */
  readonly sourceType?: string;
  /** 来源内容哈希(可空,用于交互记忆幂等去重,本阶段不使用) */
  readonly sourceHash?: string;

  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateGroupCharacterMemoryOptions {
  readonly id: string;
  readonly groupConversationId: string;
  readonly characterId: string;
  readonly origin?: GroupCharacterMemoryOrigin;
  readonly status?: GroupCharacterMemoryStatus;
  readonly title: string;
  readonly content: string;
  readonly importance: number;
  readonly keywords?: string[];
  readonly sourceMessageId?: string;
  readonly sourceRoundId?: string;
  readonly sourceSenderCharacterId?: string;
  readonly sourceType?: string;
  readonly sourceHash?: string;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

/**
 * 创建 GroupCharacterMemory 记录。
 * - id / groupConversationId / characterId / title / content 不能为空
 * - origin 默认 Manual
 * - status 默认 Active
 * - importance 必须在 [1, 5] 范围内
 * - keywords 默认空数组,自动去空去重
 * - createdAt / updatedAt 默认当前时间
 * - 可选字段 undefined 或空字符串视为未指定
 */
export function createGroupCharacterMemoryRecord(
  options: CreateGroupCharacterMemoryOptions
): GroupCharacterMemory {
  if (options.id === '') {
    throw new Error('GroupCharacterMemory: id empty');
  }
  if (options.groupConversationId === '') {
    throw new Error('GroupCharacterMemory: groupConversationId empty');
  }
  if (options.characterId === '') {
    throw new Error('GroupCharacterMemory: characterId empty');
  }
  if (!isGroupCharacterMemoryOrigin(options.origin !== undefined
    ? options.origin : GroupCharacterMemoryOrigin.Manual)) {
    throw new Error('GroupCharacterMemory: invalid origin');
  }
  if (!isGroupCharacterMemoryStatus(options.status !== undefined
    ? options.status : GroupCharacterMemoryStatus.Active)) {
    throw new Error('GroupCharacterMemory: invalid status');
  }
  if (options.title === '') {
    throw new Error('GroupCharacterMemory: title empty');
  }
  if (options.content === '') {
    throw new Error('GroupCharacterMemory: content empty');
  }
  if (!isGroupCharacterMemoryImportance(options.importance)) {
    throw new Error('GroupCharacterMemory: importance out of range');
  }
  const now: number = nowMillis();
  const origin: GroupCharacterMemoryOrigin = options.origin !== undefined
    ? options.origin : GroupCharacterMemoryOrigin.Manual;
  const status: GroupCharacterMemoryStatus = options.status !== undefined
    ? options.status : GroupCharacterMemoryStatus.Active;
  return {
    id: options.id,
    groupConversationId: options.groupConversationId,
    characterId: options.characterId,
    origin: origin,
    status: status,
    title: options.title,
    content: options.content,
    importance: options.importance,
    keywords: normalizeKeywords(options.keywords),
    sourceMessageId: normalizeOptionalId(options.sourceMessageId),
    sourceRoundId: normalizeOptionalId(options.sourceRoundId),
    sourceSenderCharacterId: normalizeOptionalId(options.sourceSenderCharacterId),
    sourceType: normalizeOptionalId(options.sourceType),
    sourceHash: normalizeOptionalId(options.sourceHash),
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}

/** 判断字符串是否为合法 GroupCharacterMemoryOrigin */
export function isGroupCharacterMemoryOrigin(value: string): boolean {
  return value === GroupCharacterMemoryOrigin.Manual
    || value === GroupCharacterMemoryOrigin.Interaction;
}

/** 判断字符串是否为合法 GroupCharacterMemoryStatus */
export function isGroupCharacterMemoryStatus(value: string): boolean {
  return value === GroupCharacterMemoryStatus.Active
    || value === GroupCharacterMemoryStatus.Archived
    || value === GroupCharacterMemoryStatus.Invalidated;
}

/** 判断数值是否为合法重要度 [1, 5] */
export function isGroupCharacterMemoryImportance(value: number): boolean {
  return Number.isInteger(value)
    && value >= GROUP_CHARACTER_MEMORY_IMPORTANCE_MIN
    && value <= GROUP_CHARACTER_MEMORY_IMPORTANCE_MAX;
}

/**
 * 规范化关键词列表:
 * - trim 每项
 * - 去除空项
 * - 去重(保留顺序)
 * - 限制数量上限
 * - 限制单项长度(超出截断)
 */
export function normalizeKeywords(raw?: string[]): string[] {
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
    const truncated: string = trimmed.length > GROUP_CHARACTER_MEMORY_KEYWORD_MAX_LENGTH
      ? trimmed.substring(0, GROUP_CHARACTER_MEMORY_KEYWORD_MAX_LENGTH) : trimmed;
    if (seen.has(truncated)) {
      continue;
    }
    seen.add(truncated);
    result.push(truncated);
    if (result.length >= GROUP_CHARACTER_MEMORY_KEYWORDS_MAX) {
      break;
    }
  }
  return result;
}

/**
 * 将逗号分隔文本解析为关键词列表(用于 UI 编辑)。
 * 调用 normalizeKeywords 完成规范化。
 */
export function parseKeywordsFromText(text: string): string[] {
  if (text === undefined || text === '') {
    return [];
  }
  const parts: string[] = text.split(',');
  return normalizeKeywords(parts);
}

/**
 * 将关键词列表拼接为逗号分隔文本(用于 UI 显示)。
 */
export function keywordsToText(keywords: string[]): string {
  if (keywords === undefined || keywords.length === 0) {
    return '';
  }
  return keywords.join(', ');
}

/** 规范化可选 ID:undefined 或空字符串视为未指定 */
function normalizeOptionalId(value?: string): string | undefined {
  if (value === undefined || value === '') {
    return undefined;
  }
  return value;
}
