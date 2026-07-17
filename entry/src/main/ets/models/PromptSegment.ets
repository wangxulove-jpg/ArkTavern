/**
 * PromptSegment 提示词段模型
 *
 * 定义 Prompt 构建中各段的顺序和内容。
 * 不依赖 ArkUI,纯数据模型。
 *
 * 顺序固定:
 * BeforeCharacter → Character → AfterCharacter → Conversation
 */

import { ChatRole } from './ChatRole';
import { ChatMessageSource } from './ChatMessageSource';

/**
 * 提示词段位置枚举。
 * 顺序即构建时的排列顺序。
 */
export enum PromptSegmentPosition {
  BeforeCharacter = 'BeforeCharacter',
  Character = 'Character',
  AfterCharacter = 'AfterCharacter',
  Conversation = 'Conversation'
}

/**
 * 提示词段。
 * 每个段包含位置、角色、内容和优先级(用于同位置排序)。
 */
export interface PromptSegment {
  readonly id: string;
  readonly position: PromptSegmentPosition;
  readonly role: ChatRole;
  readonly content: string;
  /** 优先级,数值越大越靠前。同位置内按 priority 降序排列 */
  readonly priority: number;
  /** 消息来源标签(用于 HistoryTrimmer 识别可裁剪与受保护消息) */
  readonly source: ChatMessageSource;
}

/**
 * 创建提示词段。
 */
export function createPromptSegment(
  id: string,
  position: PromptSegmentPosition,
  role: ChatRole,
  content: string,
  priority: number = 0,
  source: ChatMessageSource = ChatMessageSource.Conversation
): PromptSegment {
  return {
    id: id,
    position: position,
    role: role,
    content: content,
    priority: priority,
    source: source
  };
}

/**
 * 位置排序权重,用于 segments 排序。
 */
const POSITION_ORDER: Record<string, number> = {
  'BeforeCharacter': 0,
  'Character': 1,
  'AfterCharacter': 2,
  'Conversation': 3
};

/**
 * 按 position → priority 降序排列 segments。
 * 返回新数组,不修改原数组。
 */
export function sortSegments(segments: PromptSegment[]): PromptSegment[] {
  const sorted: PromptSegment[] = [...segments];
  sorted.sort((a: PromptSegment, b: PromptSegment): number => {
    const posOrderA: number = POSITION_ORDER[a.position] ?? 99;
    const posOrderB: number = POSITION_ORDER[b.position] ?? 99;
    if (posOrderA !== posOrderB) {
      return posOrderA - posOrderB;
    }
    // 同位置:priority 降序
    return b.priority - a.priority;
  });
  return sorted;
}