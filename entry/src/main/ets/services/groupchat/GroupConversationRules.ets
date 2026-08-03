/**
 * GroupConversationRules 多人聊天规则校验(G-DATA-1A)
 *
 * 纯逻辑模块,不依赖 RDB / ArkUI / 页面。
 * 集中实现多人聊天参与者的数量、唯一性、顺序、启用数等校验,
 * 避免 Repository / Service / Page 各自重复散落。
 *
 * 规则:
 * - 成员总数 2~8
 * - ID 非空
 * - ID 不重复
 * - speakerOrder 从 0 连续递增
 * - 至少 2 个成员 isEnabled = true
 */

import { ChatParticipant } from '../../models/ChatParticipant';
import { DatabaseError } from '../../models/DatabaseError';

/** 最少成员数(含已停用) */
export const MIN_PARTICIPANT_COUNT: number = 2;
/** 最多成员数(含已停用) */
export const MAX_PARTICIPANT_COUNT: number = 8;
/** 最少启用成员数 */
export const MIN_ENABLED_COUNT: number = 2;

/**
 * 校验原始角色 ID 列表是否可创建为多人聊天参与者。
 *
 * 规则:
 * - 数量 2~8
 * - 每个元素非空
 * - 不重复
 *
 * 不校验角色是否真实存在(由 Service 层调用 CharacterRepository 完成)。
 * 不校验顺序(本函数只校验集合,顺序由 buildOrderedParticipants 处理)。
 */
export function validateParticipantCharacterIds(characterIds: string[]): void {
  if (characterIds.length < MIN_PARTICIPANT_COUNT) {
    throw DatabaseError.invalidData(
      `participants count < ${MIN_PARTICIPANT_COUNT}`
    );
  }
  if (characterIds.length > MAX_PARTICIPANT_COUNT) {
    throw DatabaseError.invalidData(
      `participants count > ${MAX_PARTICIPANT_COUNT}`
    );
  }
  const seen: Set<string> = new Set();
  for (let i = 0; i < characterIds.length; i++) {
    const id: string = characterIds[i];
    if (id === '') {
      throw DatabaseError.invalidData('participant characterId empty');
    }
    if (seen.has(id)) {
      throw DatabaseError.invalidData('participant characterId duplicate');
    }
    seen.add(id);
  }
}

/**
 * 按传入数组顺序构建有序参与者列表。
 *
 * - 调用前应先 validateParticipantCharacterIds
 * - speakerOrder 从 0 开始按数组顺序递增
 * - 全部默认 isEnabled = true
 * - createdAt / updatedAt 使用传入 now
 */
export function buildOrderedParticipants(
  chatId: string,
  characterIds: string[],
  now: number
): ChatParticipant[] {
  if (chatId === '') {
    throw DatabaseError.invalidData('chatId empty');
  }
  validateParticipantCharacterIds(characterIds);
  const list: ChatParticipant[] = [];
  for (let i = 0; i < characterIds.length; i++) {
    list.push({
      chatId: chatId,
      characterId: characterIds[i],
      speakerOrder: i,
      isEnabled: true,
      createdAt: now,
      updatedAt: now
    });
  }
  return list;
}

/**
 * 校验已存在的参与者列表状态是否合法。
 *
 * 规则:
 * - 数量 2~8
 * - characterId 非空且不重复
 * - speakerOrder 非负、不重复、从 0 连续递增
 * - 至少 2 个 isEnabled = true
 */
export function validateParticipantState(participants: ChatParticipant[]): void {
  if (participants.length < MIN_PARTICIPANT_COUNT) {
    throw DatabaseError.invalidData(
      `participants count < ${MIN_PARTICIPANT_COUNT}`
    );
  }
  if (participants.length > MAX_PARTICIPANT_COUNT) {
    throw DatabaseError.invalidData(
      `participants count > ${MAX_PARTICIPANT_COUNT}`
    );
  }

  const charIds: Set<string> = new Set();
  const orders: Set<number> = new Set();
  let enabledCount: number = 0;

  for (let i = 0; i < participants.length; i++) {
    const p: ChatParticipant = participants[i];
    if (p.characterId === '') {
      throw DatabaseError.invalidData('participant characterId empty');
    }
    if (charIds.has(p.characterId)) {
      throw DatabaseError.invalidData('participant characterId duplicate');
    }
    charIds.add(p.characterId);

    if (!Number.isFinite(p.speakerOrder) || p.speakerOrder < 0) {
      throw DatabaseError.invalidData('participant speakerOrder invalid');
    }
    if (orders.has(p.speakerOrder)) {
      throw DatabaseError.invalidData('participant speakerOrder duplicate');
    }
    orders.add(p.speakerOrder);

    if (p.isEnabled) {
      enabledCount++;
    }
  }

  // 校验 speakerOrder 从 0 连续递增
  const sortedOrders: number[] = Array.from(orders).sort((a: number, b: number): number => a - b);
  for (let i = 0; i < sortedOrders.length; i++) {
    if (sortedOrders[i] !== i) {
      throw DatabaseError.invalidData('participant speakerOrder not continuous');
    }
  }

  if (enabledCount < MIN_ENABLED_COUNT) {
    throw DatabaseError.invalidData(
      `enabled participants < ${MIN_ENABLED_COUNT}`
    );
  }
}
