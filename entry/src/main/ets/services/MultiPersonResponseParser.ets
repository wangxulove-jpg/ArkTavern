/**
 * MultiPersonResponseParser 多人世界响应解析器
 *
 * 职责:
 * - 解析模型返回的 JSON 结构化响应
 * - 校验 JSON 完整性
 * - 校验 character_id 属于当前世界
 * - 校验角色在场且未静音
 * - 校验消息内容非空
 * - 校验发言数量符合回复模式
 *
 * 不负责:
 * - 写入数据库(由 MultiPersonChatService 处理)
 * - 关系数值规则(由 WorldRelationshipService 校验字段名)
 *
 * 规则:
 * - JSON 解析失败 → 整轮不保存
 * - 任何一条结构化结果非法 → 整轮不保存
 * - 不得保存半轮消息
 */

import {
  MultiPersonGenerationResult,
  StructuredMessage,
  SceneUpdate,
  RelationUpdate,
  MemoryEventUpdate,
  MultiPersonParseError,
  parseMessageSenderType,
  invalidJsonError,
  missingMessagesError,
  emptyMessagesError,
  unknownCharacterError,
  absentCharacterError,
  mutedCharacterError,
  emptyContentError,
  invalidSenderTypeError,
  countMismatchError
} from '../models/MultiPersonGenerationResult';
import { WorldMember } from '../models/WorldMember';
import { WorldReplyMode } from '../models/World';
import { Character } from '../models/Character';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MultiPersonResponseParser';

/**
 * 解析输入(由 MultiPersonChatService 组装)。
 */
export interface ParseInput {
  /** 模型返回的原始文本(应去除 markdown 代码块标记) */
  readonly rawText: string;
  /** 当前世界的全部成员(用于校验 characterId) */
  readonly members: WorldMember[];
  /** 当前回复模式 */
  readonly replyMode: WorldReplyMode;
  /** 允许发言的角色 ID 列表(由 SpeakerScheduler 输出) */
  readonly allowedCharacterIds: string[];
  /** 候选角色卡(用于 RP 文本解析时反查角色名) */
  readonly candidateCharacters: Character[];
}

/**
 * 解析结果(单接口 + 可选字段,避免 obj-literals-as-types 与联合类型 narrowing 问题)。
 */
export interface ParseOutcome {
  readonly ok: boolean;
  readonly result: MultiPersonGenerationResult | null;
  readonly error: MultiPersonParseError | null;
}

/**
 * 单条消息解析结果(内部使用,单接口)。
 */
interface MessageOutcome {
  readonly ok: boolean;
  readonly message: StructuredMessage | null;
  readonly error: MultiPersonParseError | null;
}

export class MultiPersonResponseParser {
  /**
   * 解析并校验模型响应。
   *
   * 支持两种输出格式:
   * 1. JSON 格式(以 { 开头):走 JSON 解析路径
   * 2. RP 文本格式(默认):按段落解析,识别"角色名: 对白"、"（角色名 动作）对白"、"——旁白"
   */
  parse(input: ParseInput): ParseOutcome {
    // 早期检测:模型返回全是空白字符(空格/换行/制表符)
    // 这是某些模型在 response_format=json_object 模式下的异常行为
    if (this.isAllWhitespace(input.rawText)) {
      Logger.warn(
        LOG_TAG,
        `parse empty_whitespace rawLen=${input.rawText.length} (model returned only whitespace)`
      );
      const err: MultiPersonParseError = invalidJsonError('模型返回空内容(全是空白字符)');
      return { ok: false, result: null, error: err };
    }
    // 检测是否以 { 开头(JSON 路径)或包含 ```json fence
    const trimmedText: string = input.rawText.trim();
    const startsWithBrace: boolean = trimmedText.startsWith('{');
    const startsWithJsonFence: boolean = trimmedText.startsWith('```json')
      || trimmedText.startsWith('```JSON')
      || trimmedText.startsWith('```\n{');
    if (startsWithBrace || startsWithJsonFence) {
      return this.parseAsJson(input);
    }
    // 默认走 RP 文本解析
    return this.parseAsRpText(input);
  }

  /**
   * JSON 格式解析(向后兼容)。
   */
  private parseAsJson(input: ParseInput): ParseOutcome {
    const cleaned: string = this.stripMarkdownFences(input.rawText);
    let parsed: Object;
    try {
      parsed = JSON.parse(cleaned) as Object;
    } catch (e) {
      const reason: string = (e as Error).message;
      const rawLen: number = input.rawText.length;
      const cleanedLen: number = cleaned.length;
      const rawStartsWithFence: boolean = input.rawText.trimStart().startsWith('```');
      const rawStartsWithBrace: boolean = input.rawText.trimStart().startsWith('{');
      const rawEndsWithFence: boolean = input.rawText.trimEnd().endsWith('```');
      const rawEndsWithBrace: boolean = input.rawText.trimEnd().endsWith('}');
      const cleanedStartsWithBrace: boolean = cleaned.startsWith('{');
      const cleanedEndsWithBrace: boolean = cleaned.endsWith('}');
      const rawPreviewLen: number = Math.min(30, input.rawText.length);
      const rawHead: string = input.rawText.substring(0, rawPreviewLen);
      Logger.warn(
        LOG_TAG,
        `parseAsJson invalid_json reason=${reason} rawLen=${rawLen} cleanedLen=${cleanedLen} ` +
        `raw[fenceS=${rawStartsWithFence},braceS=${rawStartsWithBrace},fenceE=${rawEndsWithFence},braceE=${rawEndsWithBrace}] ` +
        `cleaned[braceS=${cleanedStartsWithBrace},braceE=${cleanedEndsWithBrace}] ` +
        `rawHead=${rawHead}`
      );
      const err: MultiPersonParseError = invalidJsonError(reason);
      return { ok: false, result: null, error: err };
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      const err: MultiPersonParseError = invalidJsonError('root is not object');
      return { ok: false, result: null, error: err };
    }
    const root: Record<string, Object> = parsed as Record<string, Object>;
    if (!Reflect.has(root, 'messages')) {
      const err: MultiPersonParseError = missingMessagesError();
      return { ok: false, result: null, error: err };
    }
    const messagesRaw: Object | undefined = root['messages'];
    if (messagesRaw === undefined || !Array.isArray(messagesRaw)) {
      const err: MultiPersonParseError = missingMessagesError();
      return { ok: false, result: null, error: err };
    }
    const rawArr: Object[] = messagesRaw as Object[];
    if (rawArr.length === 0) {
      const err: MultiPersonParseError = emptyMessagesError();
      return { ok: false, result: null, error: err };
    }
    // 解析每条消息
    const messages: StructuredMessage[] = [];
    for (let i = 0; i < rawArr.length; i++) {
      const item: Object = rawArr[i];
      const msgOutcome: MessageOutcome = this.parseMessageItem(item, i, input);
      if (msgOutcome.ok) {
        if (msgOutcome.message !== null) {
          messages.push(msgOutcome.message);
        }
      } else {
        const retErr: MultiPersonParseError | null = msgOutcome.error;
        return { ok: false, result: null, error: retErr !== null ? retErr : invalidJsonError('unknown') };
      }
    }
    // 数量校验
    const countError: MultiPersonParseError | null = this.checkMessageCount(
      messages.length, input.replyMode, input.allowedCharacterIds
    );
    if (countError !== null) {
      return { ok: false, result: null, error: countError };
    }
    // 解析可选字段
    const sceneUpdate: SceneUpdate | undefined = this.parseSceneUpdate(root['scene_update']);
    const relationUpdates: RelationUpdate[] | undefined = this.parseRelationUpdates(root['relation_updates']);
    const memoryEvents: MemoryEventUpdate[] | undefined = this.parseMemoryEvents(root['memory_events']);
    const result: MultiPersonGenerationResult = {
      messages: messages,
      sceneUpdate: sceneUpdate,
      relationUpdates: relationUpdates,
      memoryEvents: memoryEvents
    };
    return { ok: true, result: result, error: null };
  }

  /**
   * RP 文本格式解析(主路径)。
   *
   * 识别以下段落格式:
   * 1. "角色名: 对白" → character 消息
   * 2. "(角色名 动作) 对白" 或 "（角色名 动作）对白" → character 消息(段落中含角色名)
   * 3. "——旁白" 或 "旁白: 内容" → narrator 消息
   * 4. 兜底:含角色名的段落 → character;否则 → narrator
   */
  private parseAsRpText(input: ParseInput): ParseOutcome {
    const text: string = input.rawText.trim();
    if (text.length === 0) {
      const err: MultiPersonParseError = emptyMessagesError();
      return { ok: false, result: null, error: err };
    }
    // 按空行分割段落
    const paragraphs: string[] = this.splitParagraphs(text);
    if (paragraphs.length === 0) {
      const err: MultiPersonParseError = emptyMessagesError();
      return { ok: false, result: null, error: err };
    }
    const messages: StructuredMessage[] = [];
    for (let i = 0; i < paragraphs.length; i++) {
      const para: string = paragraphs[i].trim();
      if (para.length === 0) {
        continue;
      }
      const msg: StructuredMessage | null = this.parseRpParagraph(para, input);
      if (msg !== null) {
        messages.push(msg);
      }
    }
    if (messages.length === 0) {
      const err: MultiPersonParseError = emptyMessagesError();
      return { ok: false, result: null, error: err };
    }
    // 数量校验(放宽:RP 模式允许少量超出,只校验下限)
    if (input.replyMode === 'narrator_only') {
      // 仅旁白模式:期望 1 条 narrator 消息,但若模型也输出了角色消息,保留第一条
      let narratorCount: number = 0;
      for (let i = 0; i < messages.length; i++) {
        if (messages[i].senderType === 'narrator') {
          narratorCount++;
        }
      }
      if (narratorCount === 0) {
        const err: MultiPersonParseError = countMismatchError(1, 0);
        return { ok: false, result: null, error: err };
      }
    }
    const result: MultiPersonGenerationResult = {
      messages: messages,
      relationUpdates: [],
      memoryEvents: []
    };
    return { ok: true, result: result, error: null };
  }

  /**
   * 解析单个 RP 段落为结构化消息。
   */
  private parseRpParagraph(para: string, input: ParseInput): StructuredMessage | null {
    // 1. 旁白检测:以 —— 或 -- 开头
    if (para.startsWith('——') || para.startsWith('--')) {
      const content: string = para.replace(/^(——|--)/, '').trim();
      if (content.length === 0) {
        return null;
      }
      return {
        senderType: 'narrator',
        characterId: null,
        content: content
      };
    }
    // 2. "角色名: 对白" 格式:查找第一个半角或全角冒号
    const colonIdx: number = this.findColonIndex(para);
    if (colonIdx > 0) {
      const speakerName: string = para.substring(0, colonIdx).trim();
      const content: string = para.substring(colonIdx + 1).trim();
      // 检查是否是"旁白"标记
      if (speakerName === '旁白' || speakerName.toLowerCase() === 'narrator') {
        if (content.length > 0) {
          return {
            senderType: 'narrator',
            characterId: null,
            content: content
          };
        }
        return null;
      }
      // 尝试反查角色
      const characterId: string | null = this.resolveCharacterId(speakerName, input.candidateCharacters);
      if (characterId !== null
        && content.length > 0
        && input.allowedCharacterIds.indexOf(characterId) >= 0) {
        return {
          senderType: 'character',
          characterId: characterId,
          content: content
        };
      }
    }
    // 3. 段落中查找出现的角色名(支持 "(角色名 动作) 对白" 格式)
    const characterId: string | null = this.findCharacterInParagraph(para, input.candidateCharacters);
    if (characterId !== null
      && input.allowedCharacterIds.indexOf(characterId) >= 0) {
      return {
        senderType: 'character',
        characterId: characterId,
        content: para  // 保留括号内的动作描述
      };
    }
    // 4. 兜底:作为 narrator 消息
    return {
      senderType: 'narrator',
      characterId: null,
      content: para
    };
  }

  /**
   * 查找段落中第一个半角冒号(:)或全角冒号(:)的位置。
   * 排除 URL 中的冒号(http:https:)。
   */
  private findColonIndex(text: string): number {
    for (let i = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch === ':' || ch === '：') {
        // 排除行首冒号
        if (i === 0) {
          continue;
        }
        return i;
      }
    }
    return -1;
  }

  /**
   * 按空行分割段落。
   */
  private splitParagraphs(text: string): string[] {
    const result: string[] = [];
    const lines: string[] = text.split('\n');
    let current: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        // 空行:结束当前段落
        if (current.length > 0) {
          result.push(current.join('\n'));
          current = [];
        }
      } else {
        current.push(lines[i]);
      }
    }
    if (current.length > 0) {
      result.push(current.join('\n'));
    }
    return result;
  }

  /**
   * 角色名 → characterId 反查。
   * 支持:精确匹配 name / 精确匹配 id / 包含匹配。
   */
  private resolveCharacterId(name: string, candidates: Character[]): string | null {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return null;
    }
    // 移除外层括号
    let cleaned: string = trimmed;
    while (cleaned.length > 1
      && ((cleaned.startsWith('(') && cleaned.endsWith(')'))
        || (cleaned.startsWith('（') && cleaned.endsWith('）')))) {
      cleaned = cleaned.substring(1, cleaned.length - 1).trim();
    }
    // 1. 精确匹配 name
    for (let i = 0; i < candidates.length; i++) {
      const c: Character = candidates[i];
      if (c.name === cleaned || c.name === trimmed) {
        return c.id;
      }
    }
    // 2. 精确匹配 id
    for (let i = 0; i < candidates.length; i++) {
      const c: Character = candidates[i];
      if (c.id === cleaned || c.id === trimmed) {
        return c.id;
      }
    }
    // 3. 包含匹配(name 包含 cleaned 或反之),要求 name 至少 2 字符避免误匹配
    for (let i = 0; i < candidates.length; i++) {
      const c: Character = candidates[i];
      if (c.name.length >= 2
        && (cleaned.includes(c.name) || c.name.includes(cleaned))) {
        return c.id;
      }
    }
    return null;
  }

  /**
   * 在段落中查找出现的角色名。
   * 优先匹配最长的角色名(避免 "艾伦" 与 "艾伦·史密斯" 冲突)。
   */
  private findCharacterInParagraph(para: string, candidates: Character[]): string | null {
    // 按名称长度降序排序(避免短名优先匹配)
    const sorted: Character[] = candidates.slice().sort((a: Character, b: Character) => {
      return b.name.length - a.name.length;
    });
    for (let i = 0; i < sorted.length; i++) {
      const c: Character = sorted[i];
      if (c.name.length >= 2 && para.indexOf(c.name) >= 0) {
        return c.id;
      }
      if (c.id.length > 0 && para.indexOf(c.id) >= 0) {
        return c.id;
      }
    }
    return null;
  }

  /**
   * 去除 markdown 代码块标记 + 提取首个 JSON 对象。
   *
   * 处理以下情况:
   * - ``` ```json\n{...}\n``` ``` (标准 fence)
   * - ```好的,这是回复:\n```json\n{...}\n```\n好的``` (fence + 前后说明)
   * - ```好的,这是回复:{...}``` (无 fence,有前缀文字)
   * - ```{...}``` (纯 JSON)
   * - ```{...}\n后续说明文字``` (JSON + 后缀文字)
   *
   * 策略:找到第一个 `{` 和最后一个 `}` 之间的内容。
   */
  private stripMarkdownFences(text: string): string {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return '';
    }
    const firstBrace: number = trimmed.indexOf('{');
    const lastBrace: number = trimmed.lastIndexOf('}');
    if (firstBrace < 0 || lastBrace < 0 || lastBrace <= firstBrace) {
      // 没有 {} 结构,返回原文让 JSON.parse 报错
      return trimmed;
    }
    return trimmed.substring(firstBrace, lastBrace + 1);
  }

  /**
   * 检测文本是否全是空白字符(空格/换行/制表符等)。
   */
  private isAllWhitespace(text: string): boolean {
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      // 32=空格, 9=制表符, 10=换行, 13=回车
      if (code !== 32 && code !== 9 && code !== 10 && code !== 13) {
        return false;
      }
    }
    return true;
  }

  private parseMessageItem(
    item: Object,
    index: number,
    input: ParseInput
  ): MessageOutcome {
    if (item === null || typeof item !== 'object' || Array.isArray(item)) {
      const err: MultiPersonParseError = invalidJsonError(`messages[${index}] not object`);
      return { ok: false, message: null, error: err };
    }
    const obj: Record<string, Object> = item as Record<string, Object>;
    const senderTypeRaw: Object | undefined = obj['sender_type'];
    if (senderTypeRaw === undefined || typeof senderTypeRaw !== 'string') {
      const err: MultiPersonParseError = invalidSenderTypeError('<missing>');
      return { ok: false, message: null, error: err };
    }
    const senderType = parseMessageSenderType(senderTypeRaw as string);
    if (senderType === null) {
      const err: MultiPersonParseError = invalidSenderTypeError(senderTypeRaw as string);
      return { ok: false, message: null, error: err };
    }
    const characterIdRaw: Object | undefined = obj['character_id'];
    let characterId: string | null = null;
    if (characterIdRaw !== undefined && characterIdRaw !== null && typeof characterIdRaw === 'string') {
      characterId = characterIdRaw as string;
    }
    const contentRaw: Object | undefined = obj['content'];
    if (contentRaw === undefined || typeof contentRaw !== 'string') {
      const err: MultiPersonParseError = emptyContentError(index);
      return { ok: false, message: null, error: err };
    }
    const content: string = (contentRaw as string).trim();
    if (content.length === 0) {
      const err: MultiPersonParseError = emptyContentError(index);
      return { ok: false, message: null, error: err };
    }
    // 角色消息校验
    if (senderType === 'character') {
      if (characterId === null || characterId.length === 0) {
        const err: MultiPersonParseError = unknownCharacterError('<empty>');
        return { ok: false, message: null, error: err };
      }
      // 校验属于当前世界
      const member: WorldMember | undefined = input.members.find(
        (m: WorldMember) => m.characterId === characterId
      );
      if (member === undefined) {
        const err: MultiPersonParseError = unknownCharacterError(characterId);
        return { ok: false, message: null, error: err };
      }
      // 校验在场
      if (!member.present) {
        const err: MultiPersonParseError = absentCharacterError(characterId);
        return { ok: false, message: null, error: err };
      }
      // 校验未静音
      if (member.muted) {
        const err: MultiPersonParseError = mutedCharacterError(characterId);
        return { ok: false, message: null, error: err };
      }
      // 校验在允许发言列表中
      if (input.allowedCharacterIds.indexOf(characterId) < 0) {
        const err: MultiPersonParseError = unknownCharacterError(characterId);
        return { ok: false, message: null, error: err };
      }
    } else {
      // narrator/user 消息:characterId 必须为空
      if (characterId !== null && characterId.length > 0) {
        const err: MultiPersonParseError = unknownCharacterError(characterId);
        return { ok: false, message: null, error: err };
      }
    }
    const msg: StructuredMessage = {
      senderType: senderType,
      characterId: characterId,
      content: content
    };
    return { ok: true, message: msg, error: null };
  }

  private checkMessageCount(
    actual: number,
    mode: WorldReplyMode,
    allowedCharacterIds: string[]
  ): MultiPersonParseError | null {
    if (mode === 'narrator_only') {
      // 仅旁白:期望 1 条 narrator 消息
      if (actual !== 1) {
        return countMismatchError(1, actual);
      }
      return null;
    }
    if (mode === 'designated') {
      if (actual !== 1) {
        return countMismatchError(1, actual);
      }
    }
    if (mode === 'all_respond') {
      const expected: number = allowedCharacterIds.length;
      if (expected > 0 && actual > expected) {
        return countMismatchError(expected, actual);
      }
    }
    if (mode === 'auto_director') {
      // 自动导演:1 - min(2, 候选数) 条
      const expected: number = Math.min(2, allowedCharacterIds.length);
      if (actual < 1 || actual > expected) {
        return countMismatchError(expected, actual);
      }
    }
    return null;
  }

  private parseSceneUpdate(raw: Object | undefined): SceneUpdate | undefined {
    if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
      return undefined;
    }
    const obj: Record<string, Object> = raw as Record<string, Object>;
    let name: string | undefined;
    let location: string | undefined;
    let timeDescription: string | undefined;
    let description: string | undefined;
    let presentCharacterIds: string[] | undefined;
    let importantObjects: string[] | undefined;
    const nameRaw: Object | undefined = obj['name'];
    if (typeof nameRaw === 'string') {
      name = nameRaw;
    }
    const locationRaw: Object | undefined = obj['location'];
    if (typeof locationRaw === 'string') {
      location = locationRaw;
    }
    const timeDescriptionRaw: Object | undefined = obj['time_description'];
    if (typeof timeDescriptionRaw === 'string') {
      timeDescription = timeDescriptionRaw;
    }
    const descriptionRaw: Object | undefined = obj['description'];
    if (typeof descriptionRaw === 'string') {
      description = descriptionRaw;
    }
    const present: Object | undefined = obj['present_character_ids'];
    if (Array.isArray(present)) {
      const arr: string[] = [];
      for (let i = 0; i < present.length; i++) {
        const v: Object = (present as Object[])[i];
        if (typeof v === 'string') {
          arr.push(v as string);
        }
      }
      presentCharacterIds = arr;
    }
    const objects: Object | undefined = obj['important_objects'];
    if (Array.isArray(objects)) {
      const arr: string[] = [];
      for (let i = 0; i < objects.length; i++) {
        const v: Object = (objects as Object[])[i];
        if (typeof v === 'string') {
          arr.push(v as string);
        }
      }
      importantObjects = arr;
    }
    if (name === undefined && location === undefined && timeDescription === undefined
      && description === undefined && presentCharacterIds === undefined
      && importantObjects === undefined) {
      return undefined;
    }
    const result: SceneUpdate = {
      name: name,
      location: location,
      timeDescription: timeDescription,
      description: description,
      presentCharacterIds: presentCharacterIds,
      importantObjects: importantObjects
    };
    return result;
  }

  private parseRelationUpdates(raw: Object | undefined): RelationUpdate[] | undefined {
    if (raw === undefined || !Array.isArray(raw)) {
      return undefined;
    }
    const arr: RelationUpdate[] = [];
    const rawArr: Object[] = raw as Object[];
    for (let i = 0; i < rawArr.length; i++) {
      const item: Object = rawArr[i];
      if (item === null || typeof item !== 'object' || Array.isArray(item)) {
        continue;
      }
      const obj: Record<string, Object> = item as Record<string, Object>;
      const characterId: Object | undefined = obj['character_id'];
      const fieldName: Object | undefined = obj['field_name'];
      const newValue: Object | undefined = obj['new_value'];
      const reason: Object | undefined = obj['reason'];
      if (typeof characterId !== 'string' || typeof fieldName !== 'string'
        || typeof newValue !== 'string' || typeof reason !== 'string') {
        continue;
      }
      const targetRaw: Object | undefined = obj['target_character_id'];
      let targetCharacterId: string | null = null;
      if (typeof targetRaw === 'string') {
        targetCharacterId = targetRaw as string;
      }
      const update: RelationUpdate = {
        characterId: characterId as string,
        targetCharacterId: targetCharacterId,
        fieldName: fieldName as string,
        newValue: newValue as string,
        reason: reason as string
      };
      arr.push(update);
    }
    return arr.length > 0 ? arr : undefined;
  }

  private parseMemoryEvents(raw: Object | undefined): MemoryEventUpdate[] | undefined {
    if (raw === undefined || !Array.isArray(raw)) {
      return undefined;
    }
    const arr: MemoryEventUpdate[] = [];
    const rawArr: Object[] = raw as Object[];
    for (let i = 0; i < rawArr.length; i++) {
      const item: Object = rawArr[i];
      if (item === null || typeof item !== 'object' || Array.isArray(item)) {
        continue;
      }
      const obj: Record<string, Object> = item as Record<string, Object>;
      const summary: Object | undefined = obj['summary'];
      const visibility: Object | undefined = obj['visibility'];
      if (typeof summary !== 'string' || typeof visibility !== 'string') {
        continue;
      }
      if (visibility !== 'public' && visibility !== 'participants'
        && visibility !== 'private' && visibility !== 'narrator_only') {
        continue;
      }
      const subject: Object | undefined = obj['subject_character_id'];
      const participantIds: string[] = this.parseStringArray(obj['participant_ids']);
      const witnessIds: string[] = this.parseStringArray(obj['witness_ids']);
      const informedCharacterIds: string[] = this.parseStringArray(obj['informed_character_ids']);
      const memEvent: MemoryEventUpdate = {
        summary: summary as string,
        participantIds: participantIds,
        witnessIds: witnessIds,
        informedCharacterIds: informedCharacterIds,
        subjectCharacterId: typeof subject === 'string' ? subject as string : null,
        visibility: visibility as 'public' | 'participants' | 'private' | 'narrator_only'
      };
      arr.push(memEvent);
    }
    return arr.length > 0 ? arr : undefined;
  }

  private parseStringArray(raw: Object | undefined): string[] {
    if (raw === undefined || !Array.isArray(raw)) {
      return [];
    }
    const arr: string[] = [];
    const rawArr: Object[] = raw as Object[];
    for (let i = 0; i < rawArr.length; i++) {
      const v: Object = rawArr[i];
      if (typeof v === 'string') {
        arr.push(v as string);
      }
    }
    return arr;
  }
}
