/**
 * RepositoryMappers 纯逻辑测试
 *
 * 覆盖:
 * - ChatRole 字符串解析
 * - ChatMessageStatus 字符串解析
 * - ChatMessageSource 字符串解析
 * - 非法枚举拒绝
 * - 空 source 返回 undefined
 * - boolean 0/1 转换
 * - 非法 boolean 拒绝
 * - 时间字段校验
 * - sequence 校验
 * - source 持久化白名单
 * - isStreaming 与 status 一致性
 * - 输入对象不修改
 */

import { describe, it, expect } from '@ohos/hypium';
import { ChatRole } from '../main/ets/models/ChatRole';
import { ChatMessageStatus } from '../main/ets/models/ChatMessage';
import { ChatMessageSource } from '../main/ets/models/ChatMessageSource';
import { DatabaseError, DatabaseErrorType } from '../main/ets/models/DatabaseError';
import {
  parseChatRole,
  chatRoleToString,
  parseChatMessageStatus,
  chatMessageStatusToString,
  parseChatMessageSource,
  chatMessageSourceToString,
  booleanToInt,
  intToBoolean,
  isValidTimestamp,
  isValidSequence,
  isPersistableSource,
  resolveIsStreaming,
  extractCauseMessage,
  isConstraintViolation
} from '../main/ets/repositories/RepositoryMappers';

export default function repositoryMappersTest(): void {
  describe('RepositoryMappers_chatRole', () => {
    it('ParseChatRole_system', 0, () => {
      expect(parseChatRole('system')).assertEqual(ChatRole.System);
    });

    it('ParseChatRole_user', 0, () => {
      expect(parseChatRole('user')).assertEqual(ChatRole.User);
    });

    it('ParseChatRole_assistant', 0, () => {
      expect(parseChatRole('assistant')).assertEqual(ChatRole.Assistant);
    });

    it('ParseChatRole_invalid_throws', 0, () => {
      try {
        parseChatRole('admin');
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof DatabaseError).assertTrue();
        const de: DatabaseError = e as DatabaseError;
        expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
      }
    });

    it('ParseChatRole_empty_throws', 0, () => {
      try {
        parseChatRole('');
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof DatabaseError).assertTrue();
      }
    });

    it('ChatRoleToString_roundtrip', 0, () => {
      expect(chatRoleToString(ChatRole.System)).assertEqual('system');
      expect(chatRoleToString(ChatRole.User)).assertEqual('user');
      expect(chatRoleToString(ChatRole.Assistant)).assertEqual('assistant');
    });
  });

  describe('RepositoryMappers_chatMessageStatus', () => {
    it('ParseStatus_streaming', 0, () => {
      expect(parseChatMessageStatus('streaming')).assertEqual(ChatMessageStatus.Streaming);
    });

    it('ParseStatus_completed', 0, () => {
      expect(parseChatMessageStatus('completed')).assertEqual(ChatMessageStatus.Completed);
    });

    it('ParseStatus_cancelled', 0, () => {
      expect(parseChatMessageStatus('cancelled')).assertEqual(ChatMessageStatus.Cancelled);
    });

    it('ParseStatus_failed', 0, () => {
      expect(parseChatMessageStatus('failed')).assertEqual(ChatMessageStatus.Failed);
    });

    it('ParseStatus_invalid_throws', 0, () => {
      try {
        parseChatMessageStatus('pending');
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof DatabaseError).assertTrue();
        const de: DatabaseError = e as DatabaseError;
        expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
      }
    });

    it('StatusToString_roundtrip', 0, () => {
      expect(chatMessageStatusToString(ChatMessageStatus.Streaming)).assertEqual('streaming');
      expect(chatMessageStatusToString(ChatMessageStatus.Completed)).assertEqual('completed');
      expect(chatMessageStatusToString(ChatMessageStatus.Cancelled)).assertEqual('cancelled');
      expect(chatMessageStatusToString(ChatMessageStatus.Failed)).assertEqual('failed');
    });
  });

  describe('RepositoryMappers_chatMessageSource', () => {
    it('ParseSource_null_returns_undefined', 0, () => {
      expect(parseChatMessageSource(null)).assertUndefined();
    });

    it('ParseSource_empty_returns_undefined', 0, () => {
      expect(parseChatMessageSource('')).assertUndefined();
    });

    it('ParseSource_conversation', 0, () => {
      expect(parseChatMessageSource('conversation')).assertEqual(ChatMessageSource.Conversation);
    });

    it('ParseSource_characterPrompt', 0, () => {
      expect(parseChatMessageSource('characterPrompt')).assertEqual(ChatMessageSource.CharacterPrompt);
    });

    it('ParseSource_characterFirstMessage', 0, () => {
      expect(parseChatMessageSource('characterFirstMessage')).assertEqual(ChatMessageSource.CharacterFirstMessage);
    });

    it('ParseSource_lorebookBefore', 0, () => {
      expect(parseChatMessageSource('lorebookBefore')).assertEqual(ChatMessageSource.LorebookBefore);
    });

    it('ParseSource_lorebookAfter', 0, () => {
      expect(parseChatMessageSource('lorebookAfter')).assertEqual(ChatMessageSource.LorebookAfter);
    });

    it('ParseSource_externalSystem', 0, () => {
      expect(parseChatMessageSource('externalSystem')).assertEqual(ChatMessageSource.ExternalSystem);
    });

    it('ParseSource_invalid_throws', 0, () => {
      try {
        parseChatMessageSource('unknown');
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof DatabaseError).assertTrue();
        const de: DatabaseError = e as DatabaseError;
        expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
      }
    });

    it('SourceToString_undefined_returns_null', 0, () => {
      expect(chatMessageSourceToString(undefined)).assertNull();
    });

    it('SourceToString_roundtrip', 0, () => {
      expect(chatMessageSourceToString(ChatMessageSource.Conversation)).assertEqual('conversation');
      expect(chatMessageSourceToString(ChatMessageSource.ExternalSystem)).assertEqual('externalSystem');
    });
  });

  describe('RepositoryMappers_boolean', () => {
    it('BooleanToInt_true', 0, () => {
      expect(booleanToInt(true)).assertEqual(1);
    });

    it('BooleanToInt_false', 0, () => {
      expect(booleanToInt(false)).assertEqual(0);
    });

    it('IntToBoolean_0', 0, () => {
      expect(intToBoolean(0)).assertFalse();
    });

    it('IntToBoolean_1', 0, () => {
      expect(intToBoolean(1)).assertTrue();
    });

    it('IntToBoolean_2_throws', 0, () => {
      try {
        intToBoolean(2);
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof DatabaseError).assertTrue();
        const de: DatabaseError = e as DatabaseError;
        expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
      }
    });

    it('IntToBoolean_negative_throws', 0, () => {
      try {
        intToBoolean(-1);
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof DatabaseError).assertTrue();
      }
    });
  });

  describe('RepositoryMappers_timestamp', () => {
    it('IsValidTimestamp_zero', 0, () => {
      expect(isValidTimestamp(0)).assertTrue();
    });

    it('IsValidTimestamp_positive', 0, () => {
      expect(isValidTimestamp(1000)).assertTrue();
    });

    it('IsValidTimestamp_negative_false', 0, () => {
      expect(isValidTimestamp(-1)).assertFalse();
    });

    it('IsValidTimestamp_NaN_false', 0, () => {
      expect(isValidTimestamp(Number.NaN)).assertFalse();
    });

    it('IsValidTimestamp_Infinity_false', 0, () => {
      expect(isValidTimestamp(Number.POSITIVE_INFINITY)).assertFalse();
    });

    it('IsValidTimestamp_float_false', 0, () => {
      expect(isValidTimestamp(1.5)).assertFalse();
    });
  });

  describe('RepositoryMappers_sequence', () => {
    it('IsValidSequence_zero', 0, () => {
      expect(isValidSequence(0)).assertTrue();
    });

    it('IsValidSequence_positive', 0, () => {
      expect(isValidSequence(42)).assertTrue();
    });

    it('IsValidSequence_negative_false', 0, () => {
      expect(isValidSequence(-1)).assertFalse();
    });

    it('IsValidSequence_NaN_false', 0, () => {
      expect(isValidSequence(Number.NaN)).assertFalse();
    });

    it('IsValidSequence_float_false', 0, () => {
      expect(isValidSequence(1.5)).assertFalse();
    });
  });

  describe('RepositoryMappers_persistableSource', () => {
    it('IsPersistable_undefined', 0, () => {
      expect(isPersistableSource(undefined)).assertTrue();
    });

    it('IsPersistable_conversation', 0, () => {
      expect(isPersistableSource(ChatMessageSource.Conversation)).assertTrue();
    });

    it('IsPersistable_characterFirstMessage', 0, () => {
      expect(isPersistableSource(ChatMessageSource.CharacterFirstMessage)).assertTrue();
    });

    it('IsPersistable_externalSystem', 0, () => {
      expect(isPersistableSource(ChatMessageSource.ExternalSystem)).assertTrue();
    });

    it('IsPersistable_characterPrompt_false', 0, () => {
      expect(isPersistableSource(ChatMessageSource.CharacterPrompt)).assertFalse();
    });

    it('IsPersistable_lorebookBefore_false', 0, () => {
      expect(isPersistableSource(ChatMessageSource.LorebookBefore)).assertFalse();
    });

    it('IsPersistable_lorebookAfter_false', 0, () => {
      expect(isPersistableSource(ChatMessageSource.LorebookAfter)).assertFalse();
    });
  });

  describe('RepositoryMappers_resolveIsStreaming', () => {
    it('ResolveIsStreaming_streaming_undefined', 0, () => {
      expect(resolveIsStreaming(ChatMessageStatus.Streaming, undefined)).assertEqual(1);
    });

    it('ResolveIsStreaming_streaming_true', 0, () => {
      expect(resolveIsStreaming(ChatMessageStatus.Streaming, true)).assertEqual(1);
    });

    it('ResolveIsStreaming_completed_undefined', 0, () => {
      expect(resolveIsStreaming(ChatMessageStatus.Completed, undefined)).assertEqual(0);
    });

    it('ResolveIsStreaming_completed_false', 0, () => {
      expect(resolveIsStreaming(ChatMessageStatus.Completed, false)).assertEqual(0);
    });

    it('ResolveIsStreaming_cancelled_false', 0, () => {
      expect(resolveIsStreaming(ChatMessageStatus.Cancelled, false)).assertEqual(0);
    });

    it('ResolveIsStreaming_failed_false', 0, () => {
      expect(resolveIsStreaming(ChatMessageStatus.Failed, false)).assertEqual(0);
    });

    it('ResolveIsStreaming_contradiction_throws', 0, () => {
      try {
        resolveIsStreaming(ChatMessageStatus.Completed, true);
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof DatabaseError).assertTrue();
        const de: DatabaseError = e as DatabaseError;
        expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
      }
    });

    it('ResolveIsStreaming_streaming_false_contradiction', 0, () => {
      try {
        resolveIsStreaming(ChatMessageStatus.Streaming, false);
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof DatabaseError).assertTrue();
      }
    });
  });

  describe('RepositoryMappers_extractCauseMessage', () => {
    it('ExtractCause_null', 0, () => {
      const s: string = extractCauseMessage(null as Object);
      expect(s).assertEqual('');
    });

    it('ExtractCause_undefined', 0, () => {
      const s: string = extractCauseMessage(undefined as Object);
      expect(s).assertEqual('');
    });

    it('ExtractCause_businessError', 0, () => {
      const err: BusinessError = { code: 14800000, message: 'sql error' };
      const s: string = extractCauseMessage(err as Object);
      expect(s.indexOf('code=14800000') >= 0).assertTrue();
      expect(s.indexOf('message=sql error') >= 0).assertTrue();
    });

    it('ExtractCause_plain_message', 0, () => {
      const err: PlainError = { message: 'something failed' };
      const s: string = extractCauseMessage(err as Object);
      expect(s).assertEqual('something failed');
    });

    it('ExtractCause_string', 0, () => {
      const s: string = extractCauseMessage('just a string' as Object);
      expect(s).assertEqual('unknown error');
    });
  });

  describe('RepositoryMappers_isConstraintViolation', () => {
    it('IsConstraint_unique', 0, () => {
      const err: BusinessError = { code: 14800000, message: 'UNIQUE constraint failed' };
      expect(isConstraintViolation(err as Object)).assertTrue();
    });

    it('IsConstraint_constraint', 0, () => {
      const err: BusinessError = { code: 14800000, message: 'constraint failed: idx_messages' };
      expect(isConstraintViolation(err as Object)).assertTrue();
    });

    it('IsConstraint_primaryKey', 0, () => {
      const err: BusinessError = { code: 14800000, message: 'PRIMARY KEY constraint' };
      expect(isConstraintViolation(err as Object)).assertTrue();
    });

    it('IsConstraint_nonConstraint', 0, () => {
      const err: BusinessError = { code: 14800000, message: 'disk I/O error' };
      expect(isConstraintViolation(err as Object)).assertFalse();
    });

    it('IsConstraint_null', 0, () => {
      expect(isConstraintViolation(null as Object)).assertFalse();
    });
  });

  describe('RepositoryMappers_noMutation', () => {
    it('ChatRoleToString_does_not_modify', 0, () => {
      const role: ChatRole = ChatRole.User;
      const s: string = chatRoleToString(role);
      expect(s).assertEqual('user');
      expect(role).assertEqual(ChatRole.User);
    });

    it('SourceToString_does_not_modify', 0, () => {
      const source: ChatMessageSource = ChatMessageSource.Conversation;
      const s: string | null = chatMessageSourceToString(source);
      expect(s).assertEqual('conversation');
      expect(source).assertEqual(ChatMessageSource.Conversation);
    });
  });
}

interface BusinessError {
  code: number;
  message: string;
}

interface PlainError {
  message: string;
}
