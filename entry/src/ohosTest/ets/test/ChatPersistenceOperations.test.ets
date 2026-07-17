/**
 * ChatPersistenceOperations 设备测试
 *
 * 使用独立测试数据库 arktavern_repository_test.db
 * 每个测试创建全新数据库,确保隔离
 *
 * 覆盖(7 项):
 * 1. removeChatWithMessages 同时删除 Chat 和 Message
 * 2. 删除无消息 Chat
 * 3. 删除不存在 Chat(幂等)
 * 4. 消息删除失败时 Chat 不删除(stub)
 * 5. Chat 删除失败时消息回滚(stub)
 * 6. 操作结束后 DbHelper 仍可用
 * 7. 不影响其他 Chat 的消息
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import {
  MessageRepository,
  MessageInsertRecord
} from '../../../main/ets/repositories/MessageRepository';
import { ChatPersistenceOperations } from '../../../main/ets/repositories/ChatPersistenceOperations';
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { Chat, createChat } from '../../../main/ets/models/Chat';
import { DatabaseError } from '../../../main/ets/models/DatabaseError';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES
} from '../../../main/ets/database/DatabaseConstants';

const REPO_TEST_DB_NAME: string = 'arktavern_repository_test.db';
let idCounter: number = 0;

function uniqueId(prefix: string): string {
  idCounter++;
  return `${prefix}-${idCounter}`;
}

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function deleteTestDbIfExists(ctx: common.Context): Promise<void> {
  try {
    const config: relationalStore.StoreConfig = {
      name: REPO_TEST_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore =
      await relationalStore.getRdbStore(ctx, config);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGES);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHATS);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHARACTERS);
    await store.close();
  } catch (e) {
    /* cleanup best-effort */
  }
}

async function makeHelper(): Promise<DbHelper> {
  const helper: DbHelper = new DbHelper(REPO_TEST_DB_NAME, []);
  const ctx: common.Context = await getContext();
  await deleteTestDbIfExists(ctx);
  await helper.initialize(ctx);
  return helper;
}

async function cleanupHelper(helper: DbHelper): Promise<void> {
  try {
    await helper.close();
  } catch (e) {
    /* ignore */
  }
  const ctx: common.Context = await getContext();
  await deleteTestDbIfExists(ctx);
}

function makeMessage(
  id: string,
  role: ChatRole,
  content: string
): ChatMessage {
  return {
    id: id,
    role: role,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    status: ChatMessageStatus.Completed,
    isStreaming: false
  };
}

async function setupChat(
  chatRepo: ChatRepository,
  chatId: string
): Promise<void> {
  const chat = createChat({ id: chatId, title: 'Test Chat' });
  await chatRepo.insert(chat);
}

async function insertMessages(
  msgRepo: MessageRepository,
  chatId: string,
  count: number
): Promise<void> {
  const records: MessageInsertRecord[] = [];
  for (let i = 0; i < count; i++) {
    records.push({
      message: makeMessage(uniqueId('msg'), ChatRole.User, `msg-${i}`),
      sequenceNumber: i
    });
  }
  await msgRepo.insertMany(chatId, records);
}

/**
 * Stub: 消息删除总是失败。
 * 用于验证"消息删除失败时 Chat 不被删除"。
 */
class FailingMessageRepository extends MessageRepository {
  constructor(dbHelper: DbHelper) {
    super(dbHelper);
  }

  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<number> {
    throw DatabaseError.queryFailed('stub: message delete failed');
  }
}

/**
 * Stub: Chat 删除总是失败。
 * 用于验证"Chat 删除失败时消息回滚"。
 */
class FailingChatRepository extends ChatRepository {
  constructor(dbHelper: DbHelper) {
    super(dbHelper);
  }

  async removeWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<void> {
    throw DatabaseError.queryFailed('stub: chat delete failed');
  }
}

export default function chatPersistenceOperationsDeviceTest(): void {
  describe('ChatPersistenceOperationsDeviceTest', () => {

    // ===== 1. removeChatWithMessages 同时删除 Chat 和 Message =====
    it('removeChatWithMessages_deletes_chat_and_messages', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
          helper, chatRepo, msgRepo
        );
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        await insertMessages(msgRepo, chatId, 3);

        expect(await msgRepo.countByChatId(chatId)).assertEqual(3);
        expect(await chatRepo.getById(chatId) !== null).assertTrue();

        await ops.removeChatWithMessages(chatId);

        expect(await chatRepo.getById(chatId) === null).assertTrue();
        expect(await msgRepo.countByChatId(chatId)).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. 删除无消息 Chat =====
    it('removeChatWithMessages_no_messages', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
          helper, chatRepo, msgRepo
        );
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);

        expect(await msgRepo.countByChatId(chatId)).assertEqual(0);

        await ops.removeChatWithMessages(chatId);

        expect(await chatRepo.getById(chatId) === null).assertTrue();
        expect(await msgRepo.countByChatId(chatId)).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. 删除不存在 Chat(幂等) =====
    it('removeChatWithMessages_nonexistent_idempotent', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
          helper, chatRepo, msgRepo
        );
        const chatId: string = uniqueId('nonexistent');

        await ops.removeChatWithMessages(chatId);

        expect(await chatRepo.getById(chatId) === null).assertTrue();
        expect(await msgRepo.countByChatId(chatId)).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. 消息删除失败时 Chat 不删除 =====
    it('message_delete_failure_keeps_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const failingMsgRepo: FailingMessageRepository =
          new FailingMessageRepository(helper);
        const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
          helper, chatRepo, failingMsgRepo
        );
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        // 用正常 msgRepo 插入,用 failingMsgRepo 删除
        const normalMsgRepo: MessageRepository = new MessageRepository(helper);
        await insertMessages(normalMsgRepo, chatId, 2);

        let threw: boolean = false;
        try {
          await ops.removeChatWithMessages(chatId);
        } catch (e) {
          threw = true;
          expect(e instanceof DatabaseError).assertTrue();
        }
        expect(threw).assertTrue();

        // Chat 仍应存在(事务回滚,且 chat 删除步骤未执行)
        const chatAfter: Chat | null = await chatRepo.getById(chatId);
        expect(chatAfter !== null).assertTrue();
        expect(chatAfter!.id).assertEqual(chatId);
        // 消息也应仍存在(事务回滚)
        expect(await normalMsgRepo.countByChatId(chatId)).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. Chat 删除失败时消息回滚 =====
    it('chat_delete_failure_rolls_back_messages', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const failingChatRepo: FailingChatRepository =
          new FailingChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
          helper, failingChatRepo, msgRepo
        );
        const chatId: string = uniqueId('chat');
        // 用正常 chatRepo 插入,用 failingChatRepo 删除
        const normalChatRepo: ChatRepository = new ChatRepository(helper);
        await setupChat(normalChatRepo, chatId);
        await insertMessages(msgRepo, chatId, 3);

        let threw: boolean = false;
        try {
          await ops.removeChatWithMessages(chatId);
        } catch (e) {
          threw = true;
          expect(e instanceof DatabaseError).assertTrue();
        }
        expect(threw).assertTrue();

        // Chat 仍应存在(删除失败 + 回滚)
        const chatAfter: Chat | null = await normalChatRepo.getById(chatId);
        expect(chatAfter !== null).assertTrue();
        expect(chatAfter!.id).assertEqual(chatId);
        // 消息也应回滚恢复(事务原子性)
        expect(await msgRepo.countByChatId(chatId)).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. 操作结束后 DbHelper 仍可用 =====
    it('dbhelper_remains_usable_after_operation', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
          helper, chatRepo, msgRepo
        );
        const chatId1: string = uniqueId('chat');
        await setupChat(chatRepo, chatId1);
        await insertMessages(msgRepo, chatId1, 1);
        await ops.removeChatWithMessages(chatId1);

        // 操作结束后,DbHelper 仍可用于新操作
        const chatId2: string = uniqueId('chat');
        await setupChat(chatRepo, chatId2);
        await insertMessages(msgRepo, chatId2, 2);

        const found: Chat | null = await chatRepo.getById(chatId2);
        expect(found !== null).assertTrue();
        expect(found!.id).assertEqual(chatId2);
        expect(await msgRepo.countByChatId(chatId2)).assertEqual(2);

        // 之前的 chat1 仍然不存在
        expect(await chatRepo.getById(chatId1) === null).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. 不影响其他 Chat 的消息 =====
    it('does_not_affect_other_chats', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
          helper, chatRepo, msgRepo
        );
        const chatId1: string = uniqueId('chat');
        const chatId2: string = uniqueId('chat');
        const chatId3: string = uniqueId('chat');
        await setupChat(chatRepo, chatId1);
        await setupChat(chatRepo, chatId2);
        await setupChat(chatRepo, chatId3);
        await insertMessages(msgRepo, chatId1, 2);
        await insertMessages(msgRepo, chatId2, 3);
        await insertMessages(msgRepo, chatId3, 1);

        // 删除 chatId2
        await ops.removeChatWithMessages(chatId2);

        // chatId1 和 chatId3 的数据完好
        expect(await chatRepo.getById(chatId1) !== null).assertTrue();
        expect(await chatRepo.getById(chatId3) !== null).assertTrue();
        expect(await msgRepo.countByChatId(chatId1)).assertEqual(2);
        expect(await msgRepo.countByChatId(chatId3)).assertEqual(1);

        // chatId2 已被完全删除
        expect(await chatRepo.getById(chatId2) === null).assertTrue();
        expect(await msgRepo.countByChatId(chatId2)).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
