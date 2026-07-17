/**
 * MessageRepository 设备测试
 *
 * 使用独立测试数据库 arktavern_repository_test.db
 * 每个测试创建全新数据库,确保隔离
 *
 * 覆盖(40 项):
 * 1. 插入 User 消息
 * 2. 插入 Assistant 消息
 * 3. 插入 firstMessage
 * 4. source 为空
 * 5. Conversation source 往返
 * 6. CharacterFirstMessage source 往返
 * 7. ExternalSystem source 往返
 * 8. CharacterPrompt source 拒绝持久化
 * 9. LorebookBefore source 拒绝持久化
 * 10. LorebookAfter source 拒绝持久化
 * 11. Streaming 状态往返
 * 12. Completed 状态往返
 * 13. Cancelled 状态往返
 * 14. Failed 状态及 errorMessage 往返
 * 15. 状态和 isStreaming 矛盾时拒绝
 * 16. chat 不存在时拒绝插入
 * 17. getById 不存在返回 null
 * 18. listByChat 正序
 * 19. listByChat 倒序
 * 20. limit 生效
 * 21. offset 生效
 * 22. 不同 chat 消息隔离
 * 23. getMaxSequenceNumber 空聊天约定值
 * 24. getMaxSequenceNumber 正确
 * 25. update content
 * 26. update status
 * 27. update source
 * 28. update 不存在返回 NotFound
 * 29. remove 幂等
 * 30. removeByChatId 返回删除数量
 * 31. countByChatId 正确
 * 32. sequence 重复失败
 * 33. message id 重复失败
 * 34. insertMany 全部成功
 * 35. insertMany 中途失败整批回滚
 * 36. insertMany 空数组直接成功
 * 37. 中文、Emoji、Markdown、换行完整往返
 * 38. 空 content 可保存
 * 39. 原消息对象未修改
 * 40. 原 records 数组未修改
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
import { createChat } from '../../../main/ets/models/Chat';
import { DatabaseError, DatabaseErrorType } from '../../../main/ets/models/DatabaseError';
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
  content: string,
  status: ChatMessageStatus,
  source?: ChatMessageSource
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
    source: source
  };
}

async function setupChat(
  chatRepo: ChatRepository,
  chatId: string
): Promise<void> {
  const chat = createChat({ id: chatId, title: 'Test Chat' });
  await chatRepo.insert(chat);
}

export default function messageRepositoryDeviceTest(): void {
  describe('MessageRepositoryDeviceTest', () => {

    // ===== 1. 插入 User 消息 =====
    it('insert_user_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.User, 'Hello', ChatMessageStatus.Completed);
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.role).assertEqual(ChatRole.User);
        expect(found!.content).assertEqual('Hello');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. 插入 Assistant 消息 =====
    it('insert_assistant_message', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.Assistant, 'Hi there', ChatMessageStatus.Completed);
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.role).assertEqual(ChatRole.Assistant);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. 插入 firstMessage =====
    it('insert_firstMessage', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(
          uniqueId('msg'), ChatRole.Assistant, 'First!',
          ChatMessageStatus.Completed, ChatMessageSource.CharacterFirstMessage
        );
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.source).assertEqual(ChatMessageSource.CharacterFirstMessage);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. source 为空 =====
    it('insert_empty_source', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.User, 'no source', ChatMessageStatus.Completed);
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.source).assertUndefined();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. Conversation source 往返 =====
    it('conversation_source_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(
          uniqueId('msg'), ChatRole.User, 'conv',
          ChatMessageStatus.Completed, ChatMessageSource.Conversation
        );
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.source).assertEqual(ChatMessageSource.Conversation);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. CharacterFirstMessage source 往返 =====
    it('characterFirstMessage_source_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(
          uniqueId('msg'), ChatRole.Assistant, 'fm',
          ChatMessageStatus.Completed, ChatMessageSource.CharacterFirstMessage
        );
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.source).assertEqual(ChatMessageSource.CharacterFirstMessage);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. ExternalSystem source 往返 =====
    it('externalSystem_source_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(
          uniqueId('msg'), ChatRole.System, 'ext',
          ChatMessageStatus.Completed, ChatMessageSource.ExternalSystem
        );
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.source).assertEqual(ChatMessageSource.ExternalSystem);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 8. CharacterPrompt source 拒绝持久化 =====
    it('characterPrompt_source_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(
          uniqueId('msg'), ChatRole.System, 'prompt',
          ChatMessageStatus.Completed, ChatMessageSource.CharacterPrompt
        );
        try {
          await msgRepo.insert(msg, chatId, 0);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 9. LorebookBefore source 拒绝持久化 =====
    it('lorebookBefore_source_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(
          uniqueId('msg'), ChatRole.System, 'lb-before',
          ChatMessageStatus.Completed, ChatMessageSource.LorebookBefore
        );
        try {
          await msgRepo.insert(msg, chatId, 0);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 10. LorebookAfter source 拒绝持久化 =====
    it('lorebookAfter_source_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(
          uniqueId('msg'), ChatRole.System, 'lb-after',
          ChatMessageStatus.Completed, ChatMessageSource.LorebookAfter
        );
        try {
          await msgRepo.insert(msg, chatId, 0);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 11. Streaming 状态往返 =====
    it('streaming_status_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.Assistant, 'streaming...', ChatMessageStatus.Streaming);
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.status).assertEqual(ChatMessageStatus.Streaming);
        expect(found!.isStreaming).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 12. Completed 状态往返 =====
    it('completed_status_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.Assistant, 'done', ChatMessageStatus.Completed);
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.status).assertEqual(ChatMessageStatus.Completed);
        expect(found!.isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 13. Cancelled 状态往返 =====
    it('cancelled_status_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.Assistant, 'stopped', ChatMessageStatus.Cancelled);
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.status).assertEqual(ChatMessageStatus.Cancelled);
        expect(found!.isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 14. Failed 状态及 errorMessage 往返 =====
    it('failed_status_errorMessage_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = {
          id: uniqueId('msg'),
          role: ChatRole.Assistant,
          content: 'partial',
          createdAt: 1000,
          updatedAt: 1000,
          status: ChatMessageStatus.Failed,
          isStreaming: false,
          errorMessage: 'connection timeout'
        };
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.status).assertEqual(ChatMessageStatus.Failed);
        expect(found!.errorMessage).assertEqual('connection timeout');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 15. 状态和 isStreaming 矛盾时拒绝 =====
    it('status_isStreaming_contradiction_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = {
          id: uniqueId('msg'),
          role: ChatRole.Assistant,
          content: 'bad',
          createdAt: 1000,
          status: ChatMessageStatus.Completed,
          isStreaming: true
        };
        try {
          await msgRepo.insert(msg, chatId, 0);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 16. chat 不存在时拒绝插入 =====
    it('insert_chat_not_found_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.User, 'orphan', ChatMessageStatus.Completed);
        try {
          await msgRepo.insert(msg, 'nonexistent-chat', 0);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type).assertEqual(DatabaseErrorType.NotFound);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 17. getById 不存在返回 null =====
    it('getById_not_found_returns_null', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const found: ChatMessage | null = await msgRepo.getById('nonexistent-msg');
        expect(found).assertNull();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 18. listByChat 正序 =====
    it('listByChat_ascending', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        for (let i = 0; i < 3; i++) {
          const m: ChatMessage = makeMessage(`msg-asc-${i}`, ChatRole.User, `c${i}`, ChatMessageStatus.Completed);
          await msgRepo.insert(m, chatId, i);
        }
        const list: ChatMessage[] = await msgRepo.listByChat(chatId, { ascending: true });
        expect(list.length).assertEqual(3);
        expect(list[0].id).assertEqual('msg-asc-0');
        expect(list[1].id).assertEqual('msg-asc-1');
        expect(list[2].id).assertEqual('msg-asc-2');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 19. listByChat 倒序 =====
    it('listByChat_descending', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        for (let i = 0; i < 3; i++) {
          const m: ChatMessage = makeMessage(`msg-desc-${i}`, ChatRole.User, `c${i}`, ChatMessageStatus.Completed);
          await msgRepo.insert(m, chatId, i);
        }
        const list: ChatMessage[] = await msgRepo.listByChat(chatId, { ascending: false });
        expect(list.length).assertEqual(3);
        expect(list[0].id).assertEqual('msg-desc-2');
        expect(list[1].id).assertEqual('msg-desc-1');
        expect(list[2].id).assertEqual('msg-desc-0');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 20. limit 生效 =====
    it('listByChat_limit', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        for (let i = 0; i < 5; i++) {
          const m: ChatMessage = makeMessage(`msg-lim-${i}`, ChatRole.User, `c${i}`, ChatMessageStatus.Completed);
          await msgRepo.insert(m, chatId, i);
        }
        const list: ChatMessage[] = await msgRepo.listByChat(chatId, { limit: 2 });
        expect(list.length).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 21. offset 生效 =====
    it('listByChat_offset', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        for (let i = 0; i < 5; i++) {
          const m: ChatMessage = makeMessage(`msg-off-${i}`, ChatRole.User, `c${i}`, ChatMessageStatus.Completed);
          await msgRepo.insert(m, chatId, i);
        }
        const list: ChatMessage[] = await msgRepo.listByChat(chatId, { limit: 2, offset: 1 });
        expect(list.length).assertEqual(2);
        expect(list[0].id).assertEqual('msg-off-1');
        expect(list[1].id).assertEqual('msg-off-2');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 22. 不同 chat 消息隔离 =====
    it('messages_isolated_between_chats', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatA: string = uniqueId('chatA');
        const chatB: string = uniqueId('chatB');
        await setupChat(chatRepo, chatA);
        await setupChat(chatRepo, chatB);
        await msgRepo.insert(makeMessage('msg-a-1', ChatRole.User, 'A1', ChatMessageStatus.Completed), chatA, 0);
        await msgRepo.insert(makeMessage('msg-b-1', ChatRole.User, 'B1', ChatMessageStatus.Completed), chatB, 0);
        const listA: ChatMessage[] = await msgRepo.listByChat(chatA);
        const listB: ChatMessage[] = await msgRepo.listByChat(chatB);
        expect(listA.length).assertEqual(1);
        expect(listB.length).assertEqual(1);
        expect(listA[0].id).assertEqual('msg-a-1');
        expect(listB[0].id).assertEqual('msg-b-1');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 23. getMaxSequenceNumber 空聊天约定值 =====
    it('getMaxSequenceNumber_empty_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const maxSeq: number = await msgRepo.getMaxSequenceNumber(chatId);
        expect(maxSeq).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 24. getMaxSequenceNumber 正确 =====
    it('getMaxSequenceNumber_correct', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        await msgRepo.insert(makeMessage('msg-seq-0', ChatRole.User, 'a', ChatMessageStatus.Completed), chatId, 0);
        await msgRepo.insert(makeMessage('msg-seq-1', ChatRole.Assistant, 'b', ChatMessageStatus.Completed), chatId, 1);
        await msgRepo.insert(makeMessage('msg-seq-2', ChatRole.User, 'c', ChatMessageStatus.Completed), chatId, 2);
        const maxSeq: number = await msgRepo.getMaxSequenceNumber(chatId);
        expect(maxSeq).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 25. update content =====
    it('update_content', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.User, 'old', ChatMessageStatus.Completed);
        await msgRepo.insert(msg, chatId, 0);
        const updated: ChatMessage = {
          id: msg.id, role: msg.role, content: 'new content',
          createdAt: msg.createdAt, updatedAt: 2000,
          status: ChatMessageStatus.Completed, isStreaming: false
        };
        await msgRepo.update(updated);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.content).assertEqual('new content');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 26. update status =====
    it('update_status', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.Assistant, 'streaming...', ChatMessageStatus.Streaming);
        await msgRepo.insert(msg, chatId, 0);
        const updated: ChatMessage = {
          id: msg.id, role: msg.role, content: 'completed text',
          createdAt: msg.createdAt, updatedAt: 2000,
          status: ChatMessageStatus.Completed, isStreaming: false
        };
        await msgRepo.update(updated);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.status).assertEqual(ChatMessageStatus.Completed);
        expect(found!.isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 27. update source =====
    it('update_source', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.User, 'test', ChatMessageStatus.Completed);
        await msgRepo.insert(msg, chatId, 0);
        const updated: ChatMessage = {
          id: msg.id, role: msg.role, content: 'test',
          createdAt: msg.createdAt, updatedAt: 2000,
          status: ChatMessageStatus.Completed, isStreaming: false,
          source: ChatMessageSource.Conversation
        };
        await msgRepo.update(updated);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.source).assertEqual(ChatMessageSource.Conversation);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 28. update 不存在返回 NotFound =====
    it('update_not_found_throws', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const msg: ChatMessage = makeMessage('nonexistent-msg', ChatRole.User, 'ghost', ChatMessageStatus.Completed);
        try {
          await msgRepo.update(msg);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type).assertEqual(DatabaseErrorType.NotFound);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 29. remove 幂等 =====
    it('remove_idempotent', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const msgRepo: MessageRepository = new MessageRepository(helper);
        await msgRepo.remove('nonexistent-msg');
        expect(true).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 30. removeByChatId 返回删除数量 =====
    it('removeByChatId_returns_count', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        for (let i = 0; i < 3; i++) {
          await msgRepo.insert(makeMessage(`msg-rm-${i}`, ChatRole.User, `c${i}`, ChatMessageStatus.Completed), chatId, i);
        }
        const deleted: number = await msgRepo.removeByChatId(chatId);
        expect(deleted).assertEqual(3);
        const remaining: number = await msgRepo.countByChatId(chatId);
        expect(remaining).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 31. countByChatId 正确 =====
    it('countByChatId_correct', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        expect(await msgRepo.countByChatId(chatId)).assertEqual(0);
        await msgRepo.insert(makeMessage('msg-cnt-0', ChatRole.User, 'a', ChatMessageStatus.Completed), chatId, 0);
        await msgRepo.insert(makeMessage('msg-cnt-1', ChatRole.Assistant, 'b', ChatMessageStatus.Completed), chatId, 1);
        expect(await msgRepo.countByChatId(chatId)).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 32. sequence 重复失败 =====
    it('duplicate_sequence_fails', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg1: ChatMessage = makeMessage('msg-dup-seq-1', ChatRole.User, 'first', ChatMessageStatus.Completed);
        const msg2: ChatMessage = makeMessage('msg-dup-seq-2', ChatRole.Assistant, 'second', ChatMessageStatus.Completed);
        await msgRepo.insert(msg1, chatId, 0);
        try {
          await msgRepo.insert(msg2, chatId, 0);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type).assertEqual(DatabaseErrorType.ConstraintFailed);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 33. message id 重复失败 =====
    it('duplicate_message_id_fails', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg1: ChatMessage = makeMessage('msg-dup-id', ChatRole.User, 'first', ChatMessageStatus.Completed);
        const msg2: ChatMessage = makeMessage('msg-dup-id', ChatRole.Assistant, 'second', ChatMessageStatus.Completed);
        await msgRepo.insert(msg1, chatId, 0);
        try {
          await msgRepo.insert(msg2, chatId, 1);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type).assertEqual(DatabaseErrorType.ConstraintFailed);
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 34. insertMany 全部成功 =====
    it('insertMany_all_success', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const records: MessageInsertRecord[] = [
          { message: makeMessage('msg-batch-0', ChatRole.User, 'a', ChatMessageStatus.Completed), sequenceNumber: 0 },
          { message: makeMessage('msg-batch-1', ChatRole.Assistant, 'b', ChatMessageStatus.Completed), sequenceNumber: 1 },
          { message: makeMessage('msg-batch-2', ChatRole.User, 'c', ChatMessageStatus.Completed), sequenceNumber: 2 }
        ];
        await msgRepo.insertMany(chatId, records);
        expect(await msgRepo.countByChatId(chatId)).assertEqual(3);
        const list: ChatMessage[] = await msgRepo.listByChat(chatId);
        expect(list[0].id).assertEqual('msg-batch-0');
        expect(list[1].id).assertEqual('msg-batch-1');
        expect(list[2].id).assertEqual('msg-batch-2');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 35. insertMany 中途失败整批回滚 =====
    it('insertMany_failure_rolls_back_all', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        // 第二条和第三条使用相同 sequence → 第三条失败
        const records: MessageInsertRecord[] = [
          { message: makeMessage('msg-rb-0', ChatRole.User, 'a', ChatMessageStatus.Completed), sequenceNumber: 0 },
          { message: makeMessage('msg-rb-1', ChatRole.Assistant, 'b', ChatMessageStatus.Completed), sequenceNumber: 1 },
          { message: makeMessage('msg-rb-2', ChatRole.User, 'c', ChatMessageStatus.Completed), sequenceNumber: 1 }
        ];
        try {
          await msgRepo.insertMany(chatId, records);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
        }
        // 整批回滚:不应有任何消息残留
        expect(await msgRepo.countByChatId(chatId)).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 36. insertMany 空数组直接成功 =====
    it('insertMany_empty_array_success', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const records: MessageInsertRecord[] = [];
        await msgRepo.insertMany(chatId, records);
        expect(await msgRepo.countByChatId(chatId)).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 37. 中文、Emoji、Markdown、换行完整往返 =====
    it('unicode_emoji_markdown_newline_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const content: string = '你好世界 🌍🎉\n```typescript\nconst x: number = 42;\n```\n어서오세요';
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.User, content, ChatMessageStatus.Completed);
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.content).assertEqual(content);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 38. 空 content 可保存 =====
    it('empty_content_saved', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.User, '', ChatMessageStatus.Completed);
        await msgRepo.insert(msg, chatId, 0);
        const found: ChatMessage | null = await msgRepo.getById(msg.id);
        expect(found !== null).assertTrue();
        expect(found!.content).assertEqual('');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 39. 原消息对象未修改 =====
    it('original_message_not_modified', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const msg: ChatMessage = makeMessage(uniqueId('msg'), ChatRole.User, 'original', ChatMessageStatus.Completed);
        const origId: string = msg.id;
        const origRole: ChatRole = msg.role;
        const origContent: string = msg.content;
        const origCreatedAt: number = msg.createdAt;
        const origStatus: ChatMessageStatus | undefined = msg.status;
        const origIsStreaming: boolean | undefined = msg.isStreaming;

        await msgRepo.insert(msg, chatId, 0);
        expect(msg.id).assertEqual(origId);
        expect(msg.role).assertEqual(origRole);
        expect(msg.content).assertEqual(origContent);
        expect(msg.createdAt).assertEqual(origCreatedAt);
        expect(msg.status).assertEqual(origStatus);
        expect(msg.isStreaming).assertEqual(origIsStreaming);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 40. 原 records 数组未修改 =====
    it('original_records_array_not_modified', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const chatId: string = uniqueId('chat');
        await setupChat(chatRepo, chatId);
        const records: MessageInsertRecord[] = [
          { message: makeMessage('msg-arr-0', ChatRole.User, 'a', ChatMessageStatus.Completed), sequenceNumber: 0 },
          { message: makeMessage('msg-arr-1', ChatRole.Assistant, 'b', ChatMessageStatus.Completed), sequenceNumber: 1 }
        ];
        const origLen: number = records.length;
        const origFirstId: string = records[0].message.id;
        const origFirstSeq: number = records[0].sequenceNumber;
        const origSecondContent: string = records[1].message.content;

        await msgRepo.insertMany(chatId, records);
        expect(records.length).assertEqual(origLen);
        expect(records[0].message.id).assertEqual(origFirstId);
        expect(records[0].sequenceNumber).assertEqual(origFirstSeq);
        expect(records[1].message.content).assertEqual(origSecondContent);
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
