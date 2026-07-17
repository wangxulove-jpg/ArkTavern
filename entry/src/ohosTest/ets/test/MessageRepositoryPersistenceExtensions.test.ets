/**
 * MessageRepositoryPersistenceExtensions 设备测试
 *
 * 使用独立测试数据库 arktavern_repository_test.db
 * 每个测试创建全新数据库,确保隔离
 *
 * 覆盖(12 项):
 * ChatRepository.getLatestByCharacterId:
 * 1. 有角色 - 返回指定角色的最近会话
 * 2. 无角色使用 IS NULL - characterId 为 undefined 查询 IS NULL
 * 3. 不返回 archived - 归档会话不被返回
 * 4. 排序正确 - 按 lastMessageAt DESC 返回最大者
 *
 * MessageRepository.removeAfterSequence:
 * 5. 正确删除 sequence_number > 边界的消息
 * 6. 不删除边界消息(等于边界值保留)
 * 7. 不影响其他 Chat 的消息
 *
 * MessageRepository.normalizeInterruptedMessages:
 * 8. Streaming 消息转为 Cancelled,is_streaming=0
 * 9. Completed 消息不被修改
 * 10. 返回受影响行数(多条 Streaming 都被规范化)
 *
 * 额外验证:
 * 11. removeAfterSequenceWithStore 事务版本
 * 12. getLatestByCharacterId 不存在返回 null
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
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../../main/ets/models/ChatMessageSource';
import { Chat, createChat } from '../../../main/ets/models/Chat';
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

/**
 * 创建 ChatMessage。
 * status 与 isStreaming 自动保持一致:
 * - Streaming → isStreaming=true
 * - 其他状态 → isStreaming=false
 * source 固定为 Conversation(合法可持久化)。
 */
function makeMessage(
  id: string,
  role: ChatRole,
  content: string,
  status: ChatMessageStatus = ChatMessageStatus.Completed
): ChatMessage {
  const isStreaming: boolean = status === ChatMessageStatus.Streaming;
  return {
    id: id,
    role: role,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    status: status,
    isStreaming: isStreaming,
    source: ChatMessageSource.Conversation
  };
}

function makeStreamingMessage(
  id: string,
  role: ChatRole,
  content: string
): ChatMessage {
  return makeMessage(id, role, content, ChatMessageStatus.Streaming);
}

async function setupChat(
  chatRepo: ChatRepository,
  chatId: string,
  characterId?: string
): Promise<Chat> {
  const chat: Chat = createChat({
    id: chatId,
    characterId: characterId,
    title: 'Test Chat'
  });
  await chatRepo.insert(chat);
  return chat;
}

/**
 * 插入 count 条消息,sequence_number 从 startSeq 开始递增。
 */
async function insertSequencedMessages(
  msgRepo: MessageRepository,
  chatId: string,
  startSeq: number,
  count: number
): Promise<void> {
  const records: MessageInsertRecord[] = [];
  for (let i = 0; i < count; i++) {
    records.push({
      message: makeMessage(
        uniqueId('msg'), ChatRole.User, `msg-${startSeq + i}`
      ),
      sequenceNumber: startSeq + i
    });
  }
  await msgRepo.insertMany(chatId, records);
}

export default function messageRepositoryPersistenceExtensionsDeviceTest(): void {
  describe('MessageRepositoryPersistenceExtensionsDeviceTest', () => {

    // ===== 1. getLatestByCharacterId 有角色 =====
    it('getLatestByCharacterId_with_character_returns_match', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const charA: string = uniqueId('char');
        const charB: string = uniqueId('char');
        await setupChat(chatRepo, uniqueId('chat'), charA);
        await setupChat(chatRepo, uniqueId('chat'), charB);
        await setupChat(chatRepo, uniqueId('chat'), charA);

        const found: Chat | null = await chatRepo.getLatestByCharacterId(charA);
        expect(found !== null).assertTrue();
        expect(found!.characterId).assertEqual(charA);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. getLatestByCharacterId 无角色使用 IS NULL =====
    it('getLatestByCharacterId_no_character_uses_IS_NULL', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId); // characterId 为 undefined

        const found: Chat | null = await chatRepo.getLatestByCharacterId();
        expect(found !== null).assertTrue();
        expect(found!.id).assertEqual(chatId);
        expect(found!.characterId).assertUndefined();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. getLatestByCharacterId 不返回 archived =====
    it('getLatestByCharacterId_excludes_archived', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const charId: string = uniqueId('char');
        const archivedId: string = uniqueId('chat');
        const activeId: string = uniqueId('chat');
        await setupChat(chatRepo, archivedId, charId);
        await setupChat(chatRepo, activeId, charId);
        await chatRepo.setArchived(archivedId, true);

        const found: Chat | null = await chatRepo.getLatestByCharacterId(charId);
        expect(found !== null).assertTrue();
        expect(found!.id).assertEqual(activeId);
        expect(found!.isArchived).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. getLatestByCharacterId 排序正确 =====
    it('getLatestByCharacterId_orders_by_lastMessageAt_desc', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const charId: string = uniqueId('char');
        const id1: string = uniqueId('chat');
        const id2: string = uniqueId('chat');
        const id3: string = uniqueId('chat');
        // 直接构造 Chat 以指定不同 lastMessageAt
        const chat1: Chat = {
          id: id1,
          characterId: charId,
          title: 'Chat 1',
          createdAt: 1000,
          updatedAt: 1000,
          lastMessageAt: 100,
          isArchived: false
        };
        const chat2: Chat = {
          id: id2,
          characterId: charId,
          title: 'Chat 2',
          createdAt: 1000,
          updatedAt: 1000,
          lastMessageAt: 300,
          isArchived: false
        };
        const chat3: Chat = {
          id: id3,
          characterId: charId,
          title: 'Chat 3',
          createdAt: 1000,
          updatedAt: 1000,
          lastMessageAt: 200,
          isArchived: false
        };
        await chatRepo.insert(chat1);
        await chatRepo.insert(chat2);
        await chatRepo.insert(chat3);

        const found: Chat | null = await chatRepo.getLatestByCharacterId(charId);
        expect(found !== null).assertTrue();
        expect(found!.id).assertEqual(id2);
        expect(found!.lastMessageAt).assertEqual(300);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. removeAfterSequence 正确删除 =====
    it('removeAfterSequence_deletes_messages_after_boundary', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        // 插入 seq=1,2,3,4,5
        await insertSequencedMessages(msgRepo, chatId, 1, 5);
        expect(await msgRepo.countByChatId(chatId)).assertEqual(5);

        // 删除 seq > 3(应删除 4,5 共 2 条)
        const deleted: number = await msgRepo.removeAfterSequence(chatId, 3);
        expect(deleted).assertEqual(2);
        expect(await msgRepo.countByChatId(chatId)).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. removeAfterSequence 不删除边界消息 =====
    it('removeAfterSequence_keeps_boundary_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        await insertSequencedMessages(msgRepo, chatId, 1, 5);

        await msgRepo.removeAfterSequence(chatId, 3);

        // 边界 seq=3 保留 → max sequence 仍为 3
        const maxSeq: number = await msgRepo.getMaxSequenceNumber(chatId);
        expect(maxSeq).assertEqual(3);
        expect(await msgRepo.countByChatId(chatId)).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. removeAfterSequence 不影响其他 Chat =====
    it('removeAfterSequence_does_not_affect_other_chats', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatA: string = uniqueId('chat');
        const chatB: string = uniqueId('chat');
        await setupChat(chatRepo, chatA);
        await setupChat(chatRepo, chatB);
        await insertSequencedMessages(msgRepo, chatA, 1, 5);
        await insertSequencedMessages(msgRepo, chatB, 1, 5);

        const deleted: number = await msgRepo.removeAfterSequence(chatA, 3);
        expect(deleted).assertEqual(2);

        // chatB 完全不受影响
        expect(await msgRepo.countByChatId(chatB)).assertEqual(5);
        const maxSeqB: number = await msgRepo.getMaxSequenceNumber(chatB);
        expect(maxSeqB).assertEqual(5);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 8. normalizeInterruptedMessages 正确 =====
    it('normalizeInterruptedMessages_converts_streaming_to_cancelled', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const streamingId: string = uniqueId('msg');
        await msgRepo.insert(
          makeStreamingMessage(streamingId, ChatRole.Assistant, 'partial...'),
          chatId, 1
        );

        const affected: number = await msgRepo.normalizeInterruptedMessages(chatId);
        expect(affected).assertEqual(1);

        const found: ChatMessage | null = await msgRepo.getById(streamingId);
        expect(found !== null).assertTrue();
        expect(found!.status).assertEqual(ChatMessageStatus.Cancelled);
        expect(found!.isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 9. normalizeInterruptedMessages Completed 不被修改 =====
    it('normalizeInterruptedMessages_keeps_completed_unchanged', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const completedId: string = uniqueId('msg');
        await msgRepo.insert(
          makeMessage(completedId, ChatRole.Assistant, 'done', ChatMessageStatus.Completed),
          chatId, 1
        );

        const affected: number = await msgRepo.normalizeInterruptedMessages(chatId);
        expect(affected).assertEqual(0);

        const found: ChatMessage | null = await msgRepo.getById(completedId);
        expect(found !== null).assertTrue();
        expect(found!.status).assertEqual(ChatMessageStatus.Completed);
        expect(found!.isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 10. normalizeInterruptedMessages 返回受影响行数 =====
    it('normalizeInterruptedMessages_returns_affected_count', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        // 插入 3 条 Streaming 消息
        await msgRepo.insert(
          makeStreamingMessage(uniqueId('msg'), ChatRole.Assistant, 's1'),
          chatId, 1
        );
        await msgRepo.insert(
          makeStreamingMessage(uniqueId('msg'), ChatRole.Assistant, 's2'),
          chatId, 2
        );
        await msgRepo.insert(
          makeStreamingMessage(uniqueId('msg'), ChatRole.Assistant, 's3'),
          chatId, 3
        );

        const affected: number = await msgRepo.normalizeInterruptedMessages(chatId);
        expect(affected).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 11. removeAfterSequenceWithStore 事务版本 =====
    it('removeAfterSequenceWithStore_works_in_transaction', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        await insertSequencedMessages(msgRepo, chatId, 1, 5);

        let deletedInTx: number = 0;
        await helper.runInTransaction(
          async (store: relationalStore.RdbStore): Promise<void> => {
            deletedInTx = await msgRepo.removeAfterSequenceWithStore(
              store, chatId, 3
            );
          }
        );
        expect(deletedInTx).assertEqual(2);
        // 事务提交后,删除生效
        expect(await msgRepo.countByChatId(chatId)).assertEqual(3);
        const maxSeq: number = await msgRepo.getMaxSequenceNumber(chatId);
        expect(maxSeq).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 12. getLatestByCharacterId 不存在返回 null =====
    it('getLatestByCharacterId_returns_null_when_not_found', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        // 插入其他角色的 chat,确保表非空
        await setupChat(chatRepo, uniqueId('chat'), uniqueId('char'));

        const found: Chat | null =
          await chatRepo.getLatestByCharacterId('nonexistent-character');
        expect(found).assertNull();
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
