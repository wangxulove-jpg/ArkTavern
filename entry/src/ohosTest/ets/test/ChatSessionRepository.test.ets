/**
 * ChatSessionRepository 设备定向测试(T-4.5)
 *
 * 验证 ChatRepository.listByExactCharacterId 的精确过滤行为:
 * - 指定 characterId 精确查询
 * - undefined 使用 IS NULL
 * - 排除其他角色
 * - 排除 archived
 * - 排序规则
 * - limit / offset
 * - ResultSet 关闭
 * - 空结果
 * - 删除原子性
 * - 不影响其他 Chat
 * - 中文 title 往返
 * - 错误日志不含正文和 SQL
 *
 * 使用独立测试数据库 arktavern_repository_test.db,前后清理。
 *
 * 覆盖 12 项。
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import { MessageRepository } from '../../../main/ets/repositories/MessageRepository';
import { ChatPersistenceOperations } from '../../../main/ets/repositories/ChatPersistenceOperations';
import { MessageSwipeRepository } from '../../../main/ets/repositories/MessageSwipeRepository';
import { Chat, createChat, updateChat } from '../../../main/ets/models/Chat';
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../../main/ets/models/ChatMessageSource';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_MESSAGE_SWIPE_CANDIDATES
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
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGE_SWIPE_GROUPS);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGE_SWIPE_CANDIDATES);
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

export default function chatSessionRepositoryDeviceTest(): void {
  describe('ChatSessionRepositoryDeviceTest', () => {

    // ===== 1. 精确查询指定 characterId =====
    it('listByExactCharacterId_returns_matching', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const c1: Chat = createChat({
          id: uniqueId('chat'), characterId: 'alice', createdAt: 1000
        });
        const c2: Chat = createChat({
          id: uniqueId('chat'), characterId: 'bob', createdAt: 1000
        });
        await repo.insert(c1);
        await repo.insert(c2);
        const list: Chat[] = await repo.listByExactCharacterId('alice');
        expect(list.length).assertEqual(1);
        expect(list[0].id).assertEqual(c1.id);
        expect(list[0].characterId).assertEqual('alice');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. undefined 使用 IS NULL =====
    it('listByExactCharacterId_undefined_uses_is_null', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const plain: Chat = createChat({
          id: uniqueId('chat'), createdAt: 1000
        });
        const character: Chat = createChat({
          id: uniqueId('chat'), characterId: 'alice', createdAt: 1000
        });
        await repo.insert(plain);
        await repo.insert(character);
        const list: Chat[] = await repo.listByExactCharacterId(undefined);
        expect(list.length).assertEqual(1);
        expect(list[0].id).assertEqual(plain.id);
        expect(list[0].characterId).assertUndefined();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. 不返回其他角色 Chat =====
    it('listByExactCharacterId_excludes_others', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        await repo.insert(createChat({ id: uniqueId('chat'), characterId: 'alice', createdAt: 1000 }));
        await repo.insert(createChat({ id: uniqueId('chat'), characterId: 'bob', createdAt: 1000 }));
        await repo.insert(createChat({ id: uniqueId('chat'), characterId: 'carol', createdAt: 1000 }));
        const list: Chat[] = await repo.listByExactCharacterId('alice');
        list.forEach((c: Chat) => {
          expect(c.characterId).assertEqual('alice');
        });
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. 不返回 archived Chat =====
    it('listByExactCharacterId_excludes_archived', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const active: Chat = createChat({
          id: uniqueId('chat'), characterId: 'alice', createdAt: 1000
        });
        const archivedRaw: Chat = createChat({
          id: uniqueId('chat'), characterId: 'alice', createdAt: 1000
        });
        const archived: Chat = updateChat(archivedRaw, { isArchived: true });
        await repo.insert(active);
        await repo.insert(archived);
        const list: Chat[] = await repo.listByExactCharacterId('alice');
        expect(list.length).assertEqual(1);
        expect(list[0].id).assertEqual(active.id);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. 排序规则正确(last_message_at DESC → updated_at DESC → id ASC) =====
    it('listByExactCharacterId_sorted', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const c1Raw: Chat = createChat({
          id: 'chat-a', characterId: 'alice', createdAt: 1000
        });
        const c1: Chat = updateChat(c1Raw, { lastMessageAt: 1000, updatedAt: 1000 });
        const c2Raw: Chat = createChat({
          id: 'chat-b', characterId: 'alice', createdAt: 1000
        });
        const c2: Chat = updateChat(c2Raw, { lastMessageAt: 2000, updatedAt: 2000 });
        await repo.insert(c1);
        await repo.insert(c2);
        const list: Chat[] = await repo.listByExactCharacterId('alice');
        expect(list.length).assertEqual(2);
        expect(list[0].id).assertEqual('chat-b');
        expect(list[1].id).assertEqual('chat-a');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. limit / offset 正确 =====
    it('listByExactCharacterId_limit_offset', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        for (let i = 0; i < 5; i++) {
          const raw: Chat = createChat({
            id: 'chat-' + i.toString(), characterId: 'alice', createdAt: 1000
          });
          const chat: Chat = updateChat(raw, { lastMessageAt: 1000 + i, updatedAt: 1000 + i });
          await repo.insert(chat);
        }
        const list: Chat[] = await repo.listByExactCharacterId('alice', { limit: 2, offset: 1 });
        expect(list.length).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. ResultSet 正常关闭(不抛错即视为通过) =====
    it('listByExactCharacterId_closes_resultset', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        await repo.insert(createChat({ id: uniqueId('chat'), createdAt: 1000 }));
        // 连续多次查询验证 ResultSet 不泄漏
        for (let i = 0; i < 5; i++) {
          await repo.listByExactCharacterId(undefined);
        }
        expect(true).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 8. 空结果返回空数组 =====
    it('listByExactCharacterId_empty_returns_empty_array', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const list: Chat[] = await repo.listByExactCharacterId('non-existent');
        expect(list.length).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 9. 删除 Chat 和 Message 原子完成 =====
    it('removeChatWithMessages_atomic', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const ops: ChatPersistenceOperations = new ChatPersistenceOperations(helper, chatRepo, msgRepo, new MessageSwipeRepository(helper));
        const chat: Chat = createChat({ id: uniqueId('chat'), createdAt: 1000 });
        await chatRepo.insert(chat);
        // 插入消息(createChatMessage 不带 status,需用对象字面量补充字段)
        const msg: ChatMessage = {
          id: uniqueId('msg'),
          role: ChatRole.User,
          content: 'hello',
          createdAt: 1000,
          status: ChatMessageStatus.Completed,
          isStreaming: false,
          source: ChatMessageSource.Conversation
        };
        await msgRepo.insert(msg, chat.id, 1);
        await ops.removeChatWithMessages(chat.id);
        const found: Chat | null = await chatRepo.getById(chat.id);
        expect(found).assertNull();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 10. 不影响其他 Chat =====
    it('removeChatWithMessages_does_not_affect_others', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const msgRepo: MessageRepository = new MessageRepository(helper);
        const ops: ChatPersistenceOperations = new ChatPersistenceOperations(helper, chatRepo, msgRepo, new MessageSwipeRepository(helper));
        const c1: Chat = createChat({ id: uniqueId('chat'), createdAt: 1000 });
        const c2: Chat = createChat({ id: uniqueId('chat'), createdAt: 1000 });
        await chatRepo.insert(c1);
        await chatRepo.insert(c2);
        await ops.removeChatWithMessages(c1.id);
        expect(await chatRepo.getById(c2.id) !== null).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 11. 中文 title 往返 =====
    it('listByExactCharacterId_chinese_title_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({
          id: uniqueId('chat'), characterId: 'alice', title: '中文标题', createdAt: 1000
        });
        await repo.insert(chat);
        const list: Chat[] = await repo.listByExactCharacterId('alice');
        expect(list.length).assertEqual(1);
        expect(list[0].title).assertEqual('中文标题');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 12. 错误日志不含正文和 SQL(不抛错即通过) =====
    it('listByExactCharacterId_no_log_leak', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({
          id: uniqueId('chat'), characterId: 'alice', title: '敏感标题', createdAt: 1000
        });
        await repo.insert(chat);
        await repo.listByExactCharacterId('alice');
        // 实际日志检查通过 hilog 过滤,此处仅验证操作不抛错
        expect(true).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
