/**
 * GroupConversationMessageService 本地单元测试(MSG-01 ~ MSG-09)
 *
 * 验证消息终态保护:
 * - Streaming → Completed / Cancelled / Failed 只允许一次合法最终化
 * - Completed/Cancelled/Failed → 其他终态 被拒绝(affectedRows 不写入)
 * - 重复 complete 不覆盖
 * - 中断消息恢复委托
 * - Delta 更新失败容错
 *
 * 使用真实 GroupConversationMessageService + Fake DbHelper / ChatRepository /
 * MessageRepository + 真实 GroupRuntimeRegistry。
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupConversationMessageService } from '../main/ets/services/groupchat/GroupConversationMessageService';
import { GroupRuntimeRegistry } from '../main/ets/services/groupchat/GroupRuntimeRegistry';
import { DbHelper } from '../main/ets/database/DbHelper';
import { ChatRepository } from '../main/ets/repositories/ChatRepository';
import { MessageRepository } from '../main/ets/repositories/MessageRepository';
import { ChatMessage, ChatMessageStatus } from '../main/ets/models/ChatMessage';
import { ConversationMode } from '../main/ets/models/ConversationMode';
import {
  FakeDbHelper,
  FakeRdbStore,
  FakeChatRepository,
  FakeMessageRepository,
  makeGroupAssistantMessage,
  makeGroupChat,
  CHAT_A
} from './GroupRuntimeTestFakes';

interface MsgTestContext {
  service: GroupConversationMessageService;
  store: FakeRdbStore;
  chatRepo: FakeChatRepository;
  msgRepo: FakeMessageRepository;
  registry: GroupRuntimeRegistry;
}

function setupMessageService(): MsgTestContext {
  const registry: GroupRuntimeRegistry = new GroupRuntimeRegistry();
  const store: FakeRdbStore = new FakeRdbStore();
  const dbHelper: FakeDbHelper = new FakeDbHelper(store);
  const chatRepo: FakeChatRepository = new FakeChatRepository();
  chatRepo.chatById.set(CHAT_A, makeGroupChat(CHAT_A, 'group-a'));
  const msgRepo: FakeMessageRepository = new FakeMessageRepository();
  // 让 store.update 同步消息仓库(模拟真实 DB 行更新)
  store.attachMessageRepo(msgRepo);

  const service: GroupConversationMessageService = new GroupConversationMessageService(
    dbHelper as Object as DbHelper,
    chatRepo as Object as ChatRepository,
    msgRepo as Object as MessageRepository,
    registry
  );
  return { service: service, store: store, chatRepo: chatRepo, msgRepo: msgRepo, registry: registry };
}

function storeStreamingMessage(ctx: MsgTestContext, id: string, chatId: string, charId: string): void {
  ctx.msgRepo.messageById.set(id, makeGroupAssistantMessage(id, charId, 'round-1', ChatMessageStatus.Streaming, ''));
}

export default function groupConversationMessageServiceTest() {
  describe('GroupConversationMessageServiceTest', () => {

    it('MSG_01_streaming_to_completed_once', 0, async () => {
      const ctx = setupMessageService();
      storeStreamingMessage(ctx, 'm1', CHAT_A, 'char-a');

      const ok: boolean = await ctx.service.finalizeAssistantMessageIfTerminal(
        'm1', 'final-content', ChatMessageStatus.Completed
      );
      expect(ok).assertTrue();
      expect(ctx.store.updateCallCount).assertEqual(1);
      expect(ctx.store.lastStatusWritten).assertEqual('completed');
      expect(ctx.store.lastContentWritten).assertEqual('final-content');
    });

    it('MSG_02_streaming_to_cancelled_once', 0, async () => {
      const ctx = setupMessageService();
      storeStreamingMessage(ctx, 'm1', CHAT_A, 'char-a');

      const ok: boolean = await ctx.service.finalizeAssistantMessageIfTerminal(
        'm1', 'partial', ChatMessageStatus.Cancelled
      );
      expect(ok).assertTrue();
      expect(ctx.store.updateCallCount).assertEqual(1);
      expect(ctx.store.lastStatusWritten).assertEqual('cancelled');
    });

    it('MSG_03_streaming_to_failed_once', 0, async () => {
      const ctx = setupMessageService();
      storeStreamingMessage(ctx, 'm1', CHAT_A, 'char-a');

      const ok: boolean = await ctx.service.finalizeAssistantMessageIfTerminal(
        'm1', 'partial', ChatMessageStatus.Failed
      );
      expect(ok).assertTrue();
      expect(ctx.store.updateCallCount).assertEqual(1);
      expect(ctx.store.lastStatusWritten).assertEqual('failed');
    });

    it('MSG_04_completed_to_cancelled_rejected', 0, async () => {
      const ctx = setupMessageService();
      ctx.msgRepo.messageById.set('m1', makeGroupAssistantMessage(
        'm1', 'char-a', 'round-1', ChatMessageStatus.Completed, 'done'
      ));

      const ok: boolean = await ctx.service.finalizeAssistantMessageIfTerminal(
        'm1', 'overwrite', ChatMessageStatus.Cancelled
      );
      expect(ok).assertFalse();
      expect(ctx.store.updateCallCount).assertEqual(0);
    });

    it('MSG_05_cancelled_to_completed_rejected', 0, async () => {
      const ctx = setupMessageService();
      ctx.msgRepo.messageById.set('m1', makeGroupAssistantMessage(
        'm1', 'char-a', 'round-1', ChatMessageStatus.Cancelled, 'partial'
      ));

      const ok: boolean = await ctx.service.finalizeAssistantMessageIfTerminal(
        'm1', 'done', ChatMessageStatus.Completed
      );
      expect(ok).assertFalse();
      expect(ctx.store.updateCallCount).assertEqual(0);
    });

    it('MSG_06_failed_to_completed_rejected_retry_creates_new', 0, async () => {
      // 当前 Retry 设计:重试创建新消息,不覆盖原 Failed 消息。
      // finalizeAssistantMessageIfTerminal 对 Failed 消息直接拒绝。
      const ctx = setupMessageService();
      ctx.msgRepo.messageById.set('m1', makeGroupAssistantMessage(
        'm1', 'char-a', 'round-1', ChatMessageStatus.Failed, 'partial'
      ));

      const ok: boolean = await ctx.service.finalizeAssistantMessageIfTerminal(
        'm1', 'done', ChatMessageStatus.Completed
      );
      expect(ok).assertFalse();
      expect(ctx.store.updateCallCount).assertEqual(0);
    });

    it('MSG_07_repeat_complete_no_overwrite', 0, async () => {
      const ctx = setupMessageService();
      storeStreamingMessage(ctx, 'm1', CHAT_A, 'char-a');

      const first: boolean = await ctx.service.finalizeAssistantMessageIfTerminal(
        'm1', 'final-1', ChatMessageStatus.Completed
      );
      expect(first).assertTrue();
      const updatesAfterFirst: number = ctx.store.updateCallCount;

      const second: boolean = await ctx.service.finalizeAssistantMessageIfTerminal(
        'm1', 'final-2', ChatMessageStatus.Completed
      );
      expect(second).assertFalse();
      // 第二次不写入
      expect(ctx.store.updateCallCount - updatesAfterFirst).assertEqual(0);
      expect(ctx.store.lastContentWritten).assertEqual('final-1');
    });

    it('MSG_08_interrupted_recovery_delegates', 0, async () => {
      const ctx = setupMessageService();
      ctx.msgRepo.normalizeResult = 3;
      const recovered: number = await ctx.service.recoverInterruptedMessages(CHAT_A);
      expect(ctx.msgRepo.normalizeCallCount).assertEqual(1);
      expect(recovered).assertEqual(3);
    });

    it('MSG_09_delta_update_failure_tolerated_finalize_still_works', 0, async () => {
      const ctx = setupMessageService();
      storeStreamingMessage(ctx, 'm1', CHAT_A, 'char-a');

      // 中间 delta 持久化失败被容错:updateStreamingAssistantMessage 不抛错
      ctx.store.failUpdate = true;
      let threw: boolean = false;
      try {
        await ctx.service.updateStreamingAssistantMessage('m1', 'delta-frame');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();

      // 最终持久化仍尝试
      ctx.store.failUpdate = false;
      const ok: boolean = await ctx.service.finalizeAssistantMessageIfTerminal(
        'm1', 'final-content', ChatMessageStatus.Completed
      );
      expect(ok).assertTrue();
      expect(ctx.store.lastStatusWritten).assertEqual('completed');
    });
  });
}
