/**
 * PromptBuilder 提示词构建器
 *
 * 统一构建发送给模型的最终请求消息。
 * 将角色提示词、世界书注入和聊天历史按固定顺序组装。
 *
 * 职责:
 * - 接收角色、世界书和聊天消息
 * - 动态匹配世界书条目
 * - 构建最终 ChatMessage[]
 * - 不修改传入的原始消息数组
 * - 不保存状态
 * - 不访问页面或网络层
 *
 * 固定消息顺序:
 * 1. BeforeCharacter 世界书(System)
 * 2. Character System Prompt(System)
 * 3. AfterCharacter 世界书(System)
 * 4. firstMessage 和聊天历史(Assistant/User)
 */

import { Character, buildCharacterSystemContent } from '../models/Character';
import { Lorebook, LorebookEntry, LorebookPosition } from '../models/Lorebook';
import { ChatMessage, createChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { MacroContext } from '../models/MacroContext';
import {
  PromptSegment,
  PromptSegmentPosition,
  createPromptSegment,
  sortSegments
} from '../models/PromptSegment';
import { LorebookService } from './LorebookService';
import { MacroReplacer } from './MacroReplacer';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptBuilder';

/**
 * Prompt 构建上下文。
 */
export interface PromptBuildContext {
  /** 当前角色(可选) */
  character?: Character;
  /** 当前世界书(可选) */
  lorebook?: Lorebook;
  /** 当前聊天消息列表 */
  messages: ChatMessage[];
  /** 宏替换上下文(可选,提供时对最终消息执行宏替换) */
  macroContext?: MacroContext;
}

/**
 * Prompt 构建结果。
 */
export interface PromptBuildResult {
  /** 构建后的请求消息列表 */
  messages: ChatMessage[];
  /** 匹配到的世界书条目 ID 列表 */
  matchedLorebookEntryIds: string[];
}

/**
 * 提示词构建器。
 */
export class PromptBuilder {
  private readonly lorebookService: LorebookService;
  private readonly macroReplacer: MacroReplacer;

  constructor(lorebookService: LorebookService, macroReplacer: MacroReplacer) {
    this.lorebookService = lorebookService;
    this.macroReplacer = macroReplacer;
  }

  /**
   * 构建最终请求消息。
   *
   * 顺序:BeforeCharacter → Character System Prompt → AfterCharacter → 聊天历史
   * 世界书内容作为 System 消息发送,不进入 ChatService 可见消息。
   * 不修改传入的 messages 数组。
   *
   * @param context 构建上下文
   * @returns 构建结果
   */
  build(context: PromptBuildContext): PromptBuildResult {
    const segments: PromptSegment[] = [];
    const matchedIds: string[] = [];
    const now: number = Date.now();

    // 1. BeforeCharacter 世界书
    if (context.lorebook !== undefined && context.lorebook !== null && context.lorebook.enabled) {
      const loreEntries: LorebookEntry[] = this.lorebookService.matchEntriesForLorebook(
        context.lorebook, context.messages
      );
      for (let i = 0; i < loreEntries.length; i++) {
        const entry: LorebookEntry = loreEntries[i];
        matchedIds.push(entry.id);
        const isBefore: boolean = entry.position === LorebookPosition.BeforeCharacter;
        const position: PromptSegmentPosition = isBefore
          ? PromptSegmentPosition.BeforeCharacter
          : PromptSegmentPosition.AfterCharacter;
        const source: ChatMessageSource = isBefore
          ? ChatMessageSource.LorebookBefore
          : ChatMessageSource.LorebookAfter;
        const seg: PromptSegment = createPromptSegment(
          'lorebook-' + entry.id,
          position,
          ChatRole.System,
          entry.content,
          entry.priority,
          source
        );
        segments.push(seg);
      }
    }

    // 2. Character System Prompt
    if (context.character !== undefined && context.character !== null) {
      const systemContent: string = buildCharacterSystemContent(context.character);
      if (systemContent.length > 0) {
        const charSeg: PromptSegment = createPromptSegment(
          'character-system',
          PromptSegmentPosition.Character,
          ChatRole.System,
          systemContent,
          0,
          ChatMessageSource.CharacterPrompt
        );
        segments.push(charSeg);
      }
    }

    // 3. Conversation:保留输入中的所有消息(包括合法 System 消息)
    // Character System Prompt 已由 Step 2 动态生成,不再从输入中取
    // 世界书 System 消息已由 Step 1 动态生成
    // firstMessage 识别:输入 messages 中第一条 Assistant 消息视为 firstMessage
    let firstAssistantSeen: boolean = false;
    for (let i = 0; i < context.messages.length; i++) {
      const msg: ChatMessage = context.messages[i];
      let source: ChatMessageSource = ChatMessageSource.Conversation;
      if (msg.role === ChatRole.System) {
        source = ChatMessageSource.ExternalSystem;
      } else if (msg.role === ChatRole.Assistant && !firstAssistantSeen) {
        source = ChatMessageSource.CharacterFirstMessage;
        firstAssistantSeen = true;
      }
      const convSeg: PromptSegment = createPromptSegment(
        msg.id,
        PromptSegmentPosition.Conversation,
        msg.role,
        msg.content,
        0,
        source
      );
      segments.push(convSeg);
    }

    // 排序:position → priority
    const sorted: PromptSegment[] = sortSegments(segments);

    // 转换为 ChatMessage[](如提供 macroContext,对每条消息内容执行宏替换)
    const macroCtx: MacroContext | undefined = context.macroContext;
    const resultMessages: ChatMessage[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const seg: PromptSegment = sorted[i];
      let content: string = seg.content;
      if (macroCtx !== undefined) {
        content = this.macroReplacer.replace(content, macroCtx);
      }
      const msg: ChatMessage = createChatMessage(
        seg.id,
        seg.role,
        content,
        now
      );
      // 携带 source 标签(内部辅助标记,不会写入网络请求 JSON)
      resultMessages.push({
        id: msg.id,
        role: msg.role,
        content: msg.content,
        createdAt: msg.createdAt,
        source: seg.source
      });
    }

    Logger.info(LOG_TAG, 'build: segments=' + sorted.length + ' lorebook=' + matchedIds.length
      + ' macro=' + (macroCtx !== undefined ? 'on' : 'off'));
    const result: PromptBuildResult = {
      messages: resultMessages,
      matchedLorebookEntryIds: matchedIds
    };
    return result;
  }
}