/**
 * MessageSwipeRepositoryMapper 本地单元测试
 *
 * 覆盖:
 * - Group ValuesBucket 构建(完整/校验/拒绝)
 * - Candidate ValuesBucket 构建(完整/校验/拒绝)
 * - Candidate Update ValuesBucket 构建
 * - 所有 ChatMessageStatus 分支
 * - errorMessage/updatedAt undefined→null
 * - boolean 0/1 转换
 * - status 与 isStreaming 一致性校验
 * - candidateIndex 校验(0/正数/负数/小数)
 * - 非法 status/时间戳/空 assistantMessageId 拒绝
 * - 中文和 Emoji content
 * - 输入对象不修改
 * - 错误不包含 content
 */

import { describe, it, expect } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { ChatMessageStatus } from '../../main/ets/models/ChatMessage';
import { DatabaseError } from '../../main/ets/models/DatabaseError';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate
} from '../../main/ets/models/MessageSwipe';
import {
  swipeGroupToBucket,
  swipeCandidateToBucket,
  swipeCandidateUpdateToBucket
} from '../../main/ets/repositories/MessageSwipeRepositoryMapper';
import {
  parseChatMessageStatus,
  intToBoolean
} from '../../main/ets/repositories/RepositoryMappers';

// ===== Helper: 构建测试 Group =====

function makeGroup(overrides?: Partial<MessageSwipeGroup>): MessageSwipeGroup {
  return {
    assistantMessageId: 'msg-001',
    chatId: 'chat-001',
    activeCandidateIndex: 0,
    createdAt: 1000,
    updatedAt: 2000,
    ...overrides
  };
}

// ===== Helper: 构建测试 Candidate =====

function makeCandidate(overrides?: Partial<MessageSwipeCandidate>): MessageSwipeCandidate {
  return {
    id: 'cand-001',
    assistantMessageId: 'msg-001',
    candidateIndex: 0,
    content: 'Hello, world!',
    status: ChatMessageStatus.Completed,
    errorMessage: undefined,
    isStreaming: false,
    createdAt: 1000,
    updatedAt: undefined,
    ...overrides
  };
}

export default function messageSwipeRepositoryMapperTest(): void {
  describe('MessageSwipeRepositoryMapperTest', () => {

    // ====================================================================
    // 1. Group ValuesBucket
    // ====================================================================

    it('group_values_bucket_full', 0, () => {
      const group: MessageSwipeGroup = makeGroup();
      const bucket: relationalStore.ValuesBucket = swipeGroupToBucket(group);
      expect(bucket['assistant_message_id'] as string).assertEqual('msg-001');
      expect(bucket['chat_id'] as string).assertEqual('chat-001');
      expect(bucket['active_candidate_index'] as number).assertEqual(0);
      expect(bucket['created_at'] as number).assertEqual(1000);
      expect(bucket['updated_at'] as number).assertEqual(2000);
    });

    // ====================================================================
    // 2. Candidate ValuesBucket
    // ====================================================================

    it('candidate_values_bucket_full', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate();
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['id'] as string).assertEqual('cand-001');
      expect(bucket['assistant_message_id'] as string).assertEqual('msg-001');
      expect(bucket['candidate_index'] as number).assertEqual(0);
      expect(bucket['content'] as string).assertEqual('Hello, world!');
      expect(bucket['status'] as string).assertEqual('completed');
      expect(bucket['error_message'] as Object).assertNull();
      expect(bucket['is_streaming'] as number).assertEqual(0);
      expect(bucket['created_at'] as number).assertEqual(1000);
      expect(bucket['updated_at'] as Object).assertNull();
    });

    // ====================================================================
    // 3. Streaming 状态
    // ====================================================================

    it('candidate_values_bucket_streaming', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        status: ChatMessageStatus.Streaming,
        isStreaming: true
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['status'] as string).assertEqual('streaming');
      expect(bucket['is_streaming'] as number).assertEqual(1);
    });

    // ====================================================================
    // 4. Completed 状态
    // ====================================================================

    it('candidate_values_bucket_completed', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        status: ChatMessageStatus.Completed,
        isStreaming: false
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['status'] as string).assertEqual('completed');
      expect(bucket['is_streaming'] as number).assertEqual(0);
    });

    // ====================================================================
    // 5. Cancelled 状态
    // ====================================================================

    it('candidate_values_bucket_cancelled', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        status: ChatMessageStatus.Cancelled,
        isStreaming: false
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['status'] as string).assertEqual('cancelled');
      expect(bucket['is_streaming'] as number).assertEqual(0);
    });

    // ====================================================================
    // 6. Failed 状态
    // ====================================================================

    it('candidate_values_bucket_failed', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        status: ChatMessageStatus.Failed,
        isStreaming: false
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['status'] as string).assertEqual('failed');
      expect(bucket['is_streaming'] as number).assertEqual(0);
    });

    // ====================================================================
    // 7. errorMessage undefined→null
    // ====================================================================

    it('error_message_undefined_becomes_null', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        errorMessage: undefined
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['error_message'] as Object).assertNull();
    });

    it('error_message_defined_not_null', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        errorMessage: 'rate limit exceeded'
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['error_message'] as string).assertEqual('rate limit exceeded');
    });

    // ====================================================================
    // 8. updatedAt undefined→null
    // ====================================================================

    it('updated_at_undefined_becomes_null', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        updatedAt: undefined
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['updated_at'] as Object).assertNull();
    });

    it('updated_at_defined_not_null', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        updatedAt: 3000
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['updated_at'] as number).assertEqual(3000);
    });

    // ====================================================================
    // 9. boolean 0/1
    // ====================================================================

    it('boolean_false_becomes_0', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        status: ChatMessageStatus.Completed,
        isStreaming: false
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['is_streaming'] as number).assertEqual(0);
    });

    it('boolean_true_becomes_1', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        status: ChatMessageStatus.Streaming,
        isStreaming: true
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['is_streaming'] as number).assertEqual(1);
    });

    // ====================================================================
    // 10. 非法 boolean (status=Streaming with isStreaming=false)
    // ====================================================================

    it('reject_streaming_status_with_is_streaming_false', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        status: ChatMessageStatus.Streaming,
        isStreaming: false
      });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('status and isStreaming contradict');
    });

    it('reject_completed_status_with_is_streaming_true', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        status: ChatMessageStatus.Completed,
        isStreaming: true
      });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('status and isStreaming contradict');
    });

    // ====================================================================
    // 11. candidateIndex=0
    // ====================================================================

    it('candidate_index_zero_accepted', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ candidateIndex: 0 });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['candidate_index'] as number).assertEqual(0);
    });

    // ====================================================================
    // 12. candidateIndex 正数
    // ====================================================================

    it('candidate_index_positive_accepted', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ candidateIndex: 3 });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['candidate_index'] as number).assertEqual(3);
    });

    it('candidate_index_max_accepted', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ candidateIndex: 7 });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['candidate_index'] as number).assertEqual(7);
    });

    // ====================================================================
    // 13. 负索引拒绝
    // ====================================================================

    it('reject_negative_candidate_index', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ candidateIndex: -1 });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('candidate: candidateIndex invalid');
    });

    // ====================================================================
    // 14. 小数索引拒绝
    // ====================================================================

    it('reject_float_candidate_index', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ candidateIndex: 1.5 });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('candidate: candidateIndex invalid');
    });

    // ====================================================================
    // 15. 非法 status
    // ====================================================================

    it('reject_unknown_status_string', 0, () => {
      expect(() => {
        parseChatMessageStatus('unknown_status');
      }).assertThrowError('unknown status');
    });

    it('reject_empty_status_string', 0, () => {
      expect(() => {
        parseChatMessageStatus('');
      }).assertThrowError('unknown status');
    });

    // ====================================================================
    // 16. 非法时间
    // ====================================================================

    it('reject_negative_created_at_for_candidate', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ createdAt: -1 });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('candidate: createdAt invalid');
    });

    it('reject_float_created_at_for_candidate', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ createdAt: 1000.5 });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('candidate: createdAt invalid');
    });

    it('reject_infinity_created_at_for_candidate', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ createdAt: Infinity });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('candidate: createdAt invalid');
    });

    it('reject_invalid_updated_at_for_candidate', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        createdAt: 1000,
        updatedAt: -5
      });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('candidate: updatedAt invalid');
    });

    it('reject_negative_created_at_for_group', 0, () => {
      const group: MessageSwipeGroup = makeGroup({ createdAt: -1 });
      expect(() => {
        swipeGroupToBucket(group);
      }).assertThrowError('group: createdAt invalid');
    });

    it('reject_invalid_updated_at_for_group', 0, () => {
      const group: MessageSwipeGroup = makeGroup({ updatedAt: 1.1 });
      expect(() => {
        swipeGroupToBucket(group);
      }).assertThrowError('group: updatedAt invalid');
    });

    // ====================================================================
    // 17. 空 assistantMessageId 拒绝
    // ====================================================================

    it('reject_empty_assistant_message_id_for_group', 0, () => {
      const group: MessageSwipeGroup = makeGroup({ assistantMessageId: '' });
      expect(() => {
        swipeGroupToBucket(group);
      }).assertThrowError('group: assistantMessageId empty');
    });

    it('reject_empty_assistant_message_id_for_candidate', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ assistantMessageId: '' });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('candidate: assistantMessageId empty');
    });

    it('reject_empty_chat_id_for_group', 0, () => {
      const group: MessageSwipeGroup = makeGroup({ chatId: '' });
      expect(() => {
        swipeGroupToBucket(group);
      }).assertThrowError('group: chatId empty');
    });

    it('reject_empty_candidate_id', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({ id: '' });
      expect(() => {
        swipeCandidateToBucket(candidate);
      }).assertThrowError('candidate: id empty');
    });

    // ====================================================================
    // 18. 中文和 Emoji content
    // ====================================================================

    it('chinese_content_in_candidate', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        content: '你好，世界！这是一个测试消息。'
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['content'] as string).assertEqual('你好，世界！这是一个测试消息。');
    });

    it('emoji_content_in_candidate', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        content: 'Hello 🤖! How are you? 😊✨'
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['content'] as string).assertEqual('Hello 🤖! How are you? 😊✨');
    });

    it('chinese_and_emoji_in_candidate', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate({
        content: '你好👋，今天天气真好！🌟'
      });
      const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
      expect(bucket['content'] as string).assertEqual('你好👋，今天天气真好！🌟');
    });

    // ====================================================================
    // 19. 输入对象不修改
    // ====================================================================

    it('input_group_not_modified', 0, () => {
      const group: MessageSwipeGroup = makeGroup();
      const originalId: string = group.assistantMessageId;
      swipeGroupToBucket(group);
      expect(group.assistantMessageId).assertEqual(originalId);
      expect(group.chatId).assertEqual('chat-001');
      expect(group.activeCandidateIndex).assertEqual(0);
    });

    it('input_candidate_not_modified', 0, () => {
      const candidate: MessageSwipeCandidate = makeCandidate();
      const originalId: string = candidate.id;
      swipeCandidateToBucket(candidate);
      expect(candidate.id).assertEqual(originalId);
      expect(candidate.content).assertEqual('Hello, world!');
      expect(candidate.status).assertEqual(ChatMessageStatus.Completed);
    });

    // ====================================================================
    // 20. 错误不包含 content
    // ====================================================================

    it('error_does_not_contain_content', 0, () => {
      const sensitiveContent: string = 'This is a secret message from the AI';
      const candidate: MessageSwipeCandidate = makeCandidate({
        content: sensitiveContent,
        createdAt: -1
      });
      let caught: Error | undefined = undefined;
      try {
        swipeCandidateToBucket(candidate);
      } catch (e) {
        caught = e as Error;
      }
      expect(caught !== undefined).assertTrue();
      if (caught !== undefined) {
        const msg: string = caught.message;
        expect(msg.indexOf(sensitiveContent) >= 0).assertFalse();
      }
    });

    it('error_does_not_contain_error_message_text', 0, () => {
      const sensitiveError: string = 'API key invalid or rate limit exceeded';
      const candidate: MessageSwipeCandidate = makeCandidate({
        errorMessage: sensitiveError,
        createdAt: -1
      });
      let caught: Error | undefined = undefined;
      try {
        swipeCandidateToBucket(candidate);
      } catch (e) {
        caught = e as Error;
      }
      expect(caught !== undefined).assertTrue();
      if (caught !== undefined) {
        const msg: string = caught.message;
        expect(msg.indexOf(sensitiveError) >= 0).assertFalse();
      }
    });

    // ====================================================================
    // swipeCandidateUpdateToBucket 测试
    // ====================================================================

    it('candidate_update_bucket_all_fields', 0, () => {
      const bucket: relationalStore.ValuesBucket = swipeCandidateUpdateToBucket(
        'Updated content',
        ChatMessageStatus.Completed,
        undefined,
        false,
        3000
      );
      expect(bucket['content'] as string).assertEqual('Updated content');
      expect(bucket['status'] as string).assertEqual('completed');
      expect(bucket['error_message'] as Object).assertNull();
      expect(bucket['is_streaming'] as number).assertEqual(0);
      expect(bucket['updated_at'] as number).assertEqual(3000);
    });

    it('candidate_update_bucket_streaming', 0, () => {
      const bucket: relationalStore.ValuesBucket = swipeCandidateUpdateToBucket(
        'Streaming content',
        ChatMessageStatus.Streaming,
        undefined,
        true,
        4000
      );
      expect(bucket['status'] as string).assertEqual('streaming');
      expect(bucket['is_streaming'] as number).assertEqual(1);
    });

    it('candidate_update_bucket_with_error_message', 0, () => {
      const bucket: relationalStore.ValuesBucket = swipeCandidateUpdateToBucket(
        'Failed content',
        ChatMessageStatus.Failed,
        'timeout',
        false,
        5000
      );
      expect(bucket['error_message'] as string).assertEqual('timeout');
    });

    it('candidate_update_bucket_reject_contradiction', 0, () => {
      expect(() => {
        swipeCandidateUpdateToBucket(
          'content',
          ChatMessageStatus.Streaming,
          undefined,
          false,
          1000
        );
      }).assertThrowError('status and isStreaming contradict');
    });

    // ====================================================================
    // intToBoolean 测试(boolean 0/1)
    // ====================================================================

    it('int_to_boolean_0', 0, () => {
      const result: boolean = intToBoolean(0);
      expect(result).assertFalse();
    });

    it('int_to_boolean_1', 0, () => {
      const result: boolean = intToBoolean(1);
      expect(result).assertTrue();
    });

    it('int_to_boolean_reject_2', 0, () => {
      expect(() => {
        intToBoolean(2);
      }).assertThrowError('invalid boolean value');
    });

    it('int_to_boolean_reject_negative', 0, () => {
      expect(() => {
        intToBoolean(-1);
      }).assertThrowError('invalid boolean value');
    });

    // ====================================================================
    // Status 字符串枚举值校验
    // ====================================================================

    it('parse_chat_message_status_all_valid', 0, () => {
      expect(parseChatMessageStatus('streaming')).assertEqual(ChatMessageStatus.Streaming);
      expect(parseChatMessageStatus('completed')).assertEqual(ChatMessageStatus.Completed);
      expect(parseChatMessageStatus('cancelled')).assertEqual(ChatMessageStatus.Cancelled);
      expect(parseChatMessageStatus('failed')).assertEqual(ChatMessageStatus.Failed);
    });

    // ====================================================================
    // Group 校验: 空 chatId / 负 activeCandidateIndex 等
    // ====================================================================

    it('reject_negative_active_candidate_index_for_group', 0, () => {
      const group: MessageSwipeGroup = makeGroup({ activeCandidateIndex: -1 });
      expect(() => {
        swipeGroupToBucket(group);
      }).assertThrowError('group: activeCandidateIndex invalid');
    });
  });
}