/**
 * ChatMemory Repository Mapper
 *
 * 职责:
 * - ResultSet → ChatMemory
 * - 模型 → ValuesBucket
 * - 不记录正文
 */

import { relationalStore } from '@kit.ArkData';
import { ChatMemory } from '../models/ChatMemory';
import { DatabaseError } from '../models/DatabaseError';
import {
  COLUMN_MEMORY_ID,
  COLUMN_MEMORY_CHAT_ID,
  COLUMN_MEMORY_BRANCH_ID,
  COLUMN_MEMORY_START_MESSAGE_ID,
  COLUMN_MEMORY_END_MESSAGE_ID,
  COLUMN_MEMORY_START_POSITION,
  COLUMN_MEMORY_END_POSITION,
  COLUMN_MEMORY_SUMMARY,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_MEMORY_ENABLED,
  COLUMN_MEMORY_SUMMARY_VERSION,
  COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID
} from '../database/DatabaseConstants';
import {
  booleanToInt,
  intToBoolean,
  isValidTimestamp,
  isValidSequence
} from './RepositoryMappers';

/**
 * 从 ResultSet 读取 ChatMemory(当前行)。
 */
export function memoryFromRow(rs: relationalStore.ResultSet): ChatMemory {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_ID));
  if (id.length === 0) {
    throw DatabaseError.invalidData('memory: id empty');
  }
  const chatId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_CHAT_ID));
  if (chatId.length === 0) {
    throw DatabaseError.invalidData('memory: chatId empty');
  }
  const branchId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_BRANCH_ID));
  if (branchId.length === 0) {
    throw DatabaseError.invalidData('memory: branchId empty');
  }
  const startMessageId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_START_MESSAGE_ID));
  if (startMessageId.length === 0) {
    throw DatabaseError.invalidData('memory: startMessageId empty');
  }
  const endMessageId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_END_MESSAGE_ID));
  if (endMessageId.length === 0) {
    throw DatabaseError.invalidData('memory: endMessageId empty');
  }
  const startPosition: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_START_POSITION));
  if (!isValidSequence(startPosition)) {
    throw DatabaseError.invalidData('memory: invalid startPosition');
  }
  const endPosition: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_END_POSITION));
  if (!isValidSequence(endPosition)) {
    throw DatabaseError.invalidData('memory: invalid endPosition');
  }
  const summary: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_SUMMARY));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('memory: invalid createdAt');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('memory: invalid updatedAt');
  }
  const enabledInt: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_ENABLED));
  const enabled: boolean = intToBoolean(enabledInt);
  const summaryVersion: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_SUMMARY_VERSION));
  if (!isValidSequence(summaryVersion)) {
    throw DatabaseError.invalidData('memory: invalid summaryVersion');
  }
  // inherited_from_memory_id 可空
  const inheritedCol: number = rs.getColumnIndex(COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID);
  const inheritedFromMemoryId: string | undefined =
    (inheritedCol >= 0 && !rs.isColumnNull(inheritedCol))
      ? rs.getString(inheritedCol) : undefined;

  return {
    id,
    chatId,
    branchId,
    startMessageId,
    endMessageId,
    startPosition,
    endPosition,
    summary,
    createdAt,
    updatedAt,
    enabled,
    summaryVersion,
    inheritedFromMemoryId
  };
}

/**
 * ChatMemory → ValuesBucket(用于 insert / replace)。
 */
export function memoryToBucket(memory: ChatMemory): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_MEMORY_ID] = memory.id;
  bucket[COLUMN_MEMORY_CHAT_ID] = memory.chatId;
  bucket[COLUMN_MEMORY_BRANCH_ID] = memory.branchId;
  bucket[COLUMN_MEMORY_START_MESSAGE_ID] = memory.startMessageId;
  bucket[COLUMN_MEMORY_END_MESSAGE_ID] = memory.endMessageId;
  bucket[COLUMN_MEMORY_START_POSITION] = memory.startPosition;
  bucket[COLUMN_MEMORY_END_POSITION] = memory.endPosition;
  bucket[COLUMN_MEMORY_SUMMARY] = memory.summary;
  bucket[COLUMN_CREATED_AT] = memory.createdAt;
  bucket[COLUMN_UPDATED_AT] = memory.updatedAt;
  bucket[COLUMN_MEMORY_ENABLED] = booleanToInt(memory.enabled);
  bucket[COLUMN_MEMORY_SUMMARY_VERSION] = memory.summaryVersion;
  if (memory.inheritedFromMemoryId !== undefined && memory.inheritedFromMemoryId.length > 0) {
    bucket[COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID] = memory.inheritedFromMemoryId;
  } else {
    bucket[COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID] = null;
  }
  return bucket;
}
