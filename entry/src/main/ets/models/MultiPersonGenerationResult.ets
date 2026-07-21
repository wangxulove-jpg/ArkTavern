/**
 * MultiPersonGenerationResult 多人生成结果模型
 *
 * 模型一次请求返回的结构化结果:
 * - messages: 一条或多条角色/旁白消息
 * - scene_update: 可选场景更新
 * - relation_updates: 可选关系变化
 * - memory_events: 可选记忆事件
 *
 * 解析与校验:
 * - JSON 必须完整可解析
 * - 每条消息的 character_id 必须属于当前世界
 * - 角色 must be present 且未 muted
 * - 内容不得为空
 * - 数量必须符合当前回复模式
 * - 任何一条非法时整轮不保存
 */

import { MessageSenderType } from './ChatMessage';

/**
 * 单条结构化消息(模型返回)。
 */
export interface StructuredMessage {
  readonly senderType: MessageSenderType;
  /** character 消息必填,其他类型留空 */
  readonly characterId: string | null;
  readonly content: string;
}

/**
 * 场景更新(可选)。
 */
export interface SceneUpdate {
  readonly name?: string;
  readonly location?: string;
  readonly timeDescription?: string;
  readonly description?: string;
  readonly presentCharacterIds?: string[];
  readonly importantObjects?: string[];
}

/**
 * 关系变化(可选)。
 */
export interface RelationUpdate {
  /** 关系主体角色 ID */
  readonly characterId: string;
  /** 目标角色 ID,null 表示对用户的关系 */
  readonly targetCharacterId: string | null;
  readonly fieldName: string;
  readonly newValue: string;
  readonly reason: string;
}

/**
 * 记忆事件(可选)。
 */
export interface MemoryEventUpdate {
  readonly summary: string;
  readonly participantIds: string[];
  readonly witnessIds: string[];
  readonly informedCharacterIds: string[];
  readonly subjectCharacterId: string | null;
  readonly visibility: 'public' | 'participants' | 'private' | 'narrator_only';
}

/**
 * 完整结构化生成结果。
 */
export interface MultiPersonGenerationResult {
  readonly messages: StructuredMessage[];
  readonly sceneUpdate?: SceneUpdate;
  readonly relationUpdates?: RelationUpdate[];
  readonly memoryEvents?: MemoryEventUpdate[];
}

/**
 * 解析错误类型 kind 枚举。
 */
export type MultiPersonParseErrorKind =
  | 'invalid_json'
  | 'missing_messages'
  | 'empty_messages'
  | 'unknown_character'
  | 'absent_character'
  | 'muted_character'
  | 'empty_content'
  | 'invalid_sender_type'
  | 'count_mismatch';

/**
 * 解析错误(单接口 + 可选字段,避免 obj-literals-as-types)。
 */
export interface MultiPersonParseError {
  readonly kind: MultiPersonParseErrorKind;
  readonly reason?: string;
  readonly characterId?: string;
  readonly index?: number;
  readonly value?: string;
  readonly expected?: number;
  readonly actual?: number;
}

/** 工厂:invalid_json */
export function invalidJsonError(reason: string): MultiPersonParseError {
  return { kind: 'invalid_json', reason: reason };
}

/** 工厂:missing_messages */
export function missingMessagesError(): MultiPersonParseError {
  return { kind: 'missing_messages' };
}

/** 工厂:empty_messages */
export function emptyMessagesError(): MultiPersonParseError {
  return { kind: 'empty_messages' };
}

/** 工厂:unknown_character */
export function unknownCharacterError(characterId: string): MultiPersonParseError {
  return { kind: 'unknown_character', characterId: characterId };
}

/** 工厂:absent_character */
export function absentCharacterError(characterId: string): MultiPersonParseError {
  return { kind: 'absent_character', characterId: characterId };
}

/** 工厂:muted_character */
export function mutedCharacterError(characterId: string): MultiPersonParseError {
  return { kind: 'muted_character', characterId: characterId };
}

/** 工厂:empty_content */
export function emptyContentError(index: number): MultiPersonParseError {
  return { kind: 'empty_content', index: index };
}

/** 工厂:invalid_sender_type */
export function invalidSenderTypeError(value: string): MultiPersonParseError {
  return { kind: 'invalid_sender_type', value: value };
}

/** 工厂:count_mismatch */
export function countMismatchError(expected: number, actual: number): MultiPersonParseError {
  return { kind: 'count_mismatch', expected: expected, actual: actual };
}

/**
 * 安全解析 sender type。
 */
export function parseMessageSenderType(value: string): MessageSenderType | null {
  if (value === 'user' || value === 'character' || value === 'narrator') {
    return value;
  }
  return null;
}
