/**
 * 成员修改与群聊删除保护 本地单元测试(MUT-01~05 / DEL-01~02)
 *
 * MUT:
 * - 运行中添加 / 移除成员 / 调整顺序 / 禁用当前成员 安全拒绝
 * - 运行结束后允许正常修改
 *
 * DEL:
 * - 运行中删除群聊安全拒绝
 * - 空闲删除事务调用范围(真实 ChatPersistenceOperations + Fake 依赖)
 *
 * 使用真实 GroupConversationPersistenceService / ChatPersistenceOperations。
 * 真实 RDB 事务回滚(DEL-03)在 ohosTest 中验证。
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupConversationPersistenceService } from '../main/ets/services/groupchat/GroupConversationPersistenceService';
import { ChatPersistenceOperations } from '../main/ets/repositories/ChatPersistenceOperations';
import { GroupRuntimeRegistry } from '../main/ets/services/groupchat/GroupRuntimeRegistry';
import { GroupRoundState } from '../main/ets/services/groupchat/GroupRoundTypes';
import { DbHelper } from '../main/ets/database/DbHelper';
import { ChatRepository } from '../main/ets/repositories/ChatRepository';
import { MessageRepository } from '../main/ets/repositories/MessageRepository';
import { ChatParticipantRepository } from '../main/ets/repositories/ChatParticipantRepository';
import { CharacterRepository } from '../main/ets/repositories/CharacterRepository';
import { MessageSwipeRepository } from '../main/ets/repositories/MessageSwipeRepository';
import { ConversationBranchPersistenceService } from '../main/ets/services/ConversationBranchPersistenceService';
import { MemoryPersistenceService } from '../main/ets/services/MemoryPersistenceService';
import { GroupCharacterMemoryRepository } from '../main/ets/repositories/groupchat/GroupCharacterMemoryRepository';
import { GroupCharacterRelationshipMemoryRepository } from '../main/ets/repositories/groupchat/GroupCharacterRelationshipMemoryRepository';
import {
  FakeDbHelper,
  FakeRdbStore,
  FakeChatRepository,
  FakeMessageRepository,
  FakeParticipantRepository,
  FakeCharacterRepository,
  FakeChatPersistenceOperations,
  FakeSwipeRepository,
  FakeDeleteDeps,
  makeGroupChat,
  makeParticipant,
  makeCharacter,
  CHAT_A
} from './GroupRuntimeTestFakes';

interface MutContext {
  service: GroupConversationPersistenceService;
  registry: GroupRuntimeRegistry;
  chatRepo: FakeChatRepository;
  participantRepo: FakeParticipantRepository;
  charRepo: FakeCharacterRepository;
  ops: FakeChatPersistenceOperations;
}

function setupPersistence(): MutContext {
  const registry: GroupRuntimeRegistry = new GroupRuntimeRegistry();
  const store: FakeRdbStore = new FakeRdbStore();
  const dbHelper: FakeDbHelper = new FakeDbHelper(store);
  const chatRepo: FakeChatRepository = new FakeChatRepository();
  const participantRepo: FakeParticipantRepository = new FakeParticipantRepository();
  const charRepo: FakeCharacterRepository = new FakeCharacterRepository();
  const ops: FakeChatPersistenceOperations = new FakeChatPersistenceOperations();

  const service: GroupConversationPersistenceService = new GroupConversationPersistenceService(
    dbHelper as Object as DbHelper,
    chatRepo as Object as ChatRepository,
    participantRepo as Object as ChatParticipantRepository,
    charRepo as Object as CharacterRepository,
    ops as Object as ChatPersistenceOperations,
    registry
  );
  return {
    service: service,
    registry: registry,
    chatRepo: chatRepo,
    participantRepo: participantRepo,
    charRepo: charRepo,
    ops: ops
  };
}

/** 建立 A 群聊标准环境(3 个启用成员)。 */
function seedGroupA(ctx: MutContext): void {
  ctx.chatRepo.chatById.set(CHAT_A, makeGroupChat(CHAT_A, 'group-a'));
  ctx.participantRepo.participantsByChat.set(CHAT_A, [
    makeParticipant(CHAT_A, 'char-a', 0),
    makeParticipant(CHAT_A, 'char-b', 1),
    makeParticipant(CHAT_A, 'char-c', 2)
  ]);
  ctx.charRepo.characterById.set('char-a', makeCharacter('char-a', 'A'));
  ctx.charRepo.characterById.set('char-b', makeCharacter('char-b', 'B'));
  ctx.charRepo.characterById.set('char-c', makeCharacter('char-c', 'C'));
  ctx.charRepo.characterById.set('char-x', makeCharacter('char-x', 'X'));
}

function expectThrowsAsync(fn: () => Promise<void>): Promise<boolean> {
  return fn().then((): boolean => false, (): boolean => true);
}

export default function groupMutationDeleteProtectionTest() {
  describe('GroupMutationDeleteProtectionTest', () => {

    it('MUT_01_add_participant_while_running_rejected', 0, async () => {
      const ctx = setupPersistence();
      seedGroupA(ctx);
      ctx.registry.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      const threw: boolean = await expectThrowsAsync((): Promise<void> =>
        ctx.service.addParticipant(CHAT_A, 'char-x')
      );
      expect(threw).assertTrue();
      expect(ctx.participantRepo.insertManyCallCount).assertEqual(0);
    });

    it('MUT_02_remove_participant_while_running_rejected', 0, async () => {
      const ctx = setupPersistence();
      seedGroupA(ctx);
      ctx.registry.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      const threw: boolean = await expectThrowsAsync((): Promise<void> =>
        ctx.service.removeParticipant(CHAT_A, 'char-b')
      );
      expect(threw).assertTrue();
      expect(ctx.participantRepo.replaceAllCallCount).assertEqual(0);
    });

    it('MUT_03_replace_order_while_running_rejected', 0, async () => {
      const ctx = setupPersistence();
      seedGroupA(ctx);
      ctx.registry.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      const threw: boolean = await expectThrowsAsync((): Promise<void> =>
        ctx.service.replaceParticipantOrder(CHAT_A, ['char-b', 'char-a', 'char-c'])
      );
      expect(threw).assertTrue();
      expect(ctx.participantRepo.replaceAllCallCount).assertEqual(0);
    });

    it('MUT_04_disable_participant_while_running_rejected', 0, async () => {
      const ctx = setupPersistence();
      seedGroupA(ctx);
      ctx.registry.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      const threw: boolean = await expectThrowsAsync((): Promise<void> =>
        ctx.service.setParticipantEnabled(CHAT_A, 'char-c', false)
      );
      expect(threw).assertTrue();
    });

    it('MUT_05_modify_after_release_allowed', 0, async () => {
      const ctx = setupPersistence();
      seedGroupA(ctx);
      ctx.registry.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);
      ctx.registry.release(CHAT_A, 1);
      expect(ctx.registry.isAnyGroupRunning()).assertFalse();

      let threw: boolean = false;
      try {
        await ctx.service.addParticipant(CHAT_A, 'char-x');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();
      expect(ctx.participantRepo.insertManyCallCount).assertEqual(1);
    });

    it('DEL_01_delete_group_while_running_rejected', 0, async () => {
      const ctx = setupPersistence();
      seedGroupA(ctx);
      ctx.registry.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      const threw: boolean = await expectThrowsAsync((): Promise<void> =>
        ctx.service.deleteGroupConversation(CHAT_A)
      );
      expect(threw).assertTrue();
      // 未执行任何部分删除
      expect(ctx.ops.removeChatWithMessagesCallCount).assertEqual(0);
    });

    it('DEL_02_delete_transaction_call_range', 0, async () => {
      // 真实 ChatPersistenceOperations + Fake 依赖,验证全部删除步骤都被调用
      const dbHelper: FakeDbHelper = new FakeDbHelper(new FakeRdbStore());
      const chatRepo: FakeChatRepository = new FakeChatRepository();
      const msgRepo: FakeMessageRepository = new FakeMessageRepository();
      const swipeRepo: FakeSwipeRepository = new FakeSwipeRepository();
      const branch = new FakeDeleteDeps();
      const memory = new FakeDeleteDeps();
      const participantRepo: FakeParticipantRepository = new FakeParticipantRepository();
      const groupMemory = new FakeDeleteDeps();
      const groupRelMemory = new FakeDeleteDeps();

      const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
        dbHelper as Object as DbHelper,
        chatRepo as Object as ChatRepository,
        msgRepo as Object as MessageRepository,
        swipeRepo as Object as MessageSwipeRepository,
        branch as Object as ConversationBranchPersistenceService,
        memory as Object as MemoryPersistenceService,
        participantRepo as Object as ChatParticipantRepository,
        groupMemory as Object as GroupCharacterMemoryRepository,
        groupRelMemory as Object as GroupCharacterRelationshipMemoryRepository
      );

      await ops.removeChatWithMessages(CHAT_A);

      expect(branch.callCount).assertEqual(1);
      expect(memory.callCount).assertEqual(1);
      expect(swipeRepo.removeByChatIdCallCount).assertEqual(1);
      expect(msgRepo.removeByChatIdCallCount).assertEqual(1);
      expect(groupMemory.callCount).assertEqual(1);
      expect(groupRelMemory.callCount).assertEqual(1);
      expect(participantRepo.deleteByChatCallCount).assertEqual(1);
      expect(chatRepo.removeWithStoreCallCount).assertEqual(1);
    });

    it('DEL_03_real_transaction_rollback_not_local', 0, async () => {
      // 真实 RDB 事务回滚无法在本地 Fake 环境验证。
      // 此处仅记录:FakeDbHelper.runInTransaction 不模拟真实 begin/commit/rollback。
      // 真实事务回滚需在 ohosTest 中用真实 RDB 验证(DEL-03 ohosTest 待补)。
      const dbHelper: FakeDbHelper = new FakeDbHelper(new FakeRdbStore());
      const chatRepo: FakeChatRepository = new FakeChatRepository();
      const msgRepo: FakeMessageRepository = new FakeMessageRepository();
      const swipeRepo: FakeSwipeRepository = new FakeSwipeRepository();
      const branch = new FakeDeleteDeps();
      const memory = new FakeDeleteDeps();
      const participantRepo: FakeParticipantRepository = new FakeParticipantRepository();
      const groupMemory = new FakeDeleteDeps();
      const groupRelMemory = new FakeDeleteDeps();

      const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
        dbHelper as Object as DbHelper,
        chatRepo as Object as ChatRepository,
        msgRepo as Object as MessageRepository,
        swipeRepo as Object as MessageSwipeRepository,
        branch as Object as ConversationBranchPersistenceService,
        memory as Object as MemoryPersistenceService,
        participantRepo as Object as ChatParticipantRepository,
        groupMemory as Object as GroupCharacterMemoryRepository,
        groupRelMemory as Object as GroupCharacterRelationshipMemoryRepository
      );

      // 某一步抛错时,FakeDbHelper 只是把异常向上抛,不验证真实回滚。
      // 记录:若 groupMemory 抛错,后续 participant/chat 不再调用。
      groupMemory.throwOnDelete = true;
      let threw: boolean = false;
      try {
        await ops.removeChatWithMessages(CHAT_A);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      // 后续步骤未执行(FakeDbHelper 不 catch,异常直接向上传播)
      expect(participantRepo.deleteByChatCallCount).assertEqual(0);
      expect(chatRepo.removeWithStoreCallCount).assertEqual(0);
    });
  });
}
