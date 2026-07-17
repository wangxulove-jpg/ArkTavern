/**
 * ChatRepository 设备测试
 *
 * 使用独立测试数据库 arktavern_repository_test.db
 * 每个测试创建全新数据库,确保隔离
 *
 * 覆盖(25 项):
 * 1. 插入普通聊天
 * 2. 插入角色聊天
 * 3. getById 返回完整字段
 * 4. getById 不存在返回 null
 * 5. list 默认不返回 archived
 * 6. list includeArchived=true
 * 7. 按 lastMessageAt 降序
 * 8. 相同时间稳定排序
 * 9. 按 characterId 过滤
 * 10. limit 生效
 * 11. offset 生效
 * 12. 非法 limit 返回错误
 * 13. 非法 offset 返回错误
 * 14. 更新 title
 * 15. 更新 characterId
 * 16. 清空 characterId
 * 17. updateLastMessageAt
 * 18. setArchived
 * 19. update 不存在返回 NotFound
 * 20. remove 存在记录
 * 21. remove 不存在幂等
 * 22. 重复 id 插入失败
 * 23. count 正确
 * 24. 中文和 Emoji title 往返
 * 25. 不修改输入 Chat 对象
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import { Chat, createChat, updateChat } from '../../../main/ets/models/Chat';
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

export default function chatRepositoryDeviceTest(): void {
  describe('ChatRepositoryDeviceTest', () => {

    // ===== 1. 插入普通聊天 =====
    it('insert_plain_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({
          id: uniqueId('chat'),
          title: 'Plain Chat',
          createdAt: 1000
        });
        await repo.insert(chat);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found !== null).assertTrue();
        expect(found!.id).assertEqual(chat.id);
        expect(found!.title).assertEqual('Plain Chat');
        expect(found!.characterId).assertUndefined();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. 插入角色聊天 =====
    it('insert_character_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({
          id: uniqueId('chat'),
          characterId: 'char-001',
          title: 'Character Chat',
          createdAt: 2000
        });
        await repo.insert(chat);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found !== null).assertTrue();
        expect(found!.characterId).assertEqual('char-001');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. getById 返回完整字段 =====
    it('getById_returns_all_fields', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({
          id: uniqueId('chat'),
          characterId: 'char-full',
          title: 'Full Fields',
          createdAt: 5000
        });
        const updated: Chat = updateChat(chat, {
          lastMessageAt: 6000,
          updatedAt: 7000
        });
        await repo.insert(updated);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found !== null).assertTrue();
        expect(found!.id).assertEqual(updated.id);
        expect(found!.characterId).assertEqual('char-full');
        expect(found!.title).assertEqual('Full Fields');
        expect(found!.createdAt).assertEqual(5000);
        expect(found!.updatedAt).assertEqual(7000);
        expect(found!.lastMessageAt).assertEqual(6000);
        expect(found!.isArchived).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. getById 不存在返回 null =====
    it('getById_not_found_returns_null', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const found: Chat | null = await repo.getById('nonexistent-id');
        expect(found).assertNull();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. list 默认不返回 archived =====
    it('list_excludes_archived_by_default', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat1: Chat = createChat({ id: uniqueId('chat'), title: 'Active' });
        const chat2: Chat = createChat({ id: uniqueId('chat'), title: 'Archived' });
        await repo.insert(chat1);
        await repo.insert(chat2);
        await repo.setArchived(chat2.id, true);

        const list: Chat[] = await repo.list();
        expect(list.length).assertEqual(1);
        expect(list[0].id).assertEqual(chat1.id);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. list includeArchived=true =====
    it('list_includes_archived_when_requested', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat1: Chat = createChat({ id: uniqueId('chat'), title: 'Active' });
        const chat2: Chat = createChat({ id: uniqueId('chat'), title: 'Archived' });
        await repo.insert(chat1);
        await repo.insert(chat2);
        await repo.setArchived(chat2.id, true);

        const list: Chat[] = await repo.list({ includeArchived: true });
        expect(list.length).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. 按 lastMessageAt 降序 =====
    it('list_sorted_by_lastMessageAt_desc', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat1: Chat = updateChat(
          createChat({ id: uniqueId('chat'), title: 'Old' }),
          { lastMessageAt: 1000 }
        );
        const chat2: Chat = updateChat(
          createChat({ id: uniqueId('chat'), title: 'New' }),
          { lastMessageAt: 2000 }
        );
        const chat3: Chat = updateChat(
          createChat({ id: uniqueId('chat'), title: 'Mid' }),
          { lastMessageAt: 1500 }
        );
        await repo.insert(chat1);
        await repo.insert(chat2);
        await repo.insert(chat3);

        const list: Chat[] = await repo.list();
        expect(list.length).assertEqual(3);
        expect(list[0].id).assertEqual(chat2.id);
        expect(list[1].id).assertEqual(chat3.id);
        expect(list[2].id).assertEqual(chat1.id);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 8. 相同时间稳定排序 =====
    it('list_stable_sort_same_lastMessageAt', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        // 相同 lastMessageAt,不同 updatedAt,不同 id
        const idA: string = 'aaa-stable';
        const idB: string = 'bbb-stable';
        const idC: string = 'ccc-stable';
        const chatA: Chat = createChat({ id: idA, title: 'A', createdAt: 1000 });
        const chatB: Chat = createChat({ id: idB, title: 'B', createdAt: 1000 });
        const chatC: Chat = createChat({ id: idC, title: 'C', createdAt: 1000 });
        await repo.insert(chatA);
        await repo.insert(chatB);
        await repo.insert(chatC);
        // 通过 updateChat 设置相同的 lastMessageAt 和不同的 updatedAt
        const updatedA: Chat = updateChat(chatA, { lastMessageAt: 5000, updatedAt: 3000 });
        const updatedB: Chat = updateChat(chatB, { lastMessageAt: 5000, updatedAt: 2000 });
        const updatedC: Chat = updateChat(chatC, { lastMessageAt: 5000, updatedAt: 1000 });
        await repo.update(updatedA);
        await repo.update(updatedB);
        await repo.update(updatedC);

        const list: Chat[] = await repo.list();
        expect(list.length).assertEqual(3);
        // lastMessageAt 相同 → updatedAt DESC: A(3000) > B(2000) > C(1000)
        expect(list[0].id).assertEqual(idA);
        expect(list[1].id).assertEqual(idB);
        expect(list[2].id).assertEqual(idC);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 9. 按 characterId 过滤 =====
    it('list_filter_by_characterId', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat1: Chat = createChat({ id: uniqueId('chat'), characterId: 'char-A', title: 'A1' });
        const chat2: Chat = createChat({ id: uniqueId('chat'), characterId: 'char-B', title: 'B1' });
        const chat3: Chat = createChat({ id: uniqueId('chat'), characterId: 'char-A', title: 'A2' });
        await repo.insert(chat1);
        await repo.insert(chat2);
        await repo.insert(chat3);

        const list: Chat[] = await repo.list({ characterId: 'char-A' });
        expect(list.length).assertEqual(2);
        expect(list[0].characterId).assertEqual('char-A');
        expect(list[1].characterId).assertEqual('char-A');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 10. limit 生效 =====
    it('list_limit_works', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        for (let i = 0; i < 5; i++) {
          const c: Chat = updateChat(
            createChat({ id: uniqueId('chat'), title: `Chat${i}` }),
            { lastMessageAt: 1000 + i }
          );
          await repo.insert(c);
        }
        const list: Chat[] = await repo.list({ limit: 3 });
        expect(list.length).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 11. offset 生效 =====
    it('list_offset_works', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const ids: string[] = [];
        for (let i = 0; i < 5; i++) {
          const id: string = uniqueId('chat');
          ids.push(id);
          const c: Chat = updateChat(
            createChat({ id: id, title: `Chat${i}` }),
            { lastMessageAt: 1000 + i }
          );
          await repo.insert(c);
        }
        const list: Chat[] = await repo.list({ limit: 2, offset: 1 });
        expect(list.length).assertEqual(2);
        // 排除 lastMessageAt 最高的那个(offset=1 跳过第一条)
        expect(list[0].id !== ids[4]).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 12. 非法 limit 返回错误 =====
    it('list_invalid_limit_throws', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        try {
          await repo.list({ limit: 0 });
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type).assertEqual(DatabaseErrorType.InvalidData);
        }
        try {
          await repo.list({ limit: 201 });
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

    // ===== 13. 非法 offset 返回错误 =====
    it('list_invalid_offset_throws', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        try {
          await repo.list({ offset: -1 });
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

    // ===== 14. 更新 title =====
    it('update_title', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({ id: uniqueId('chat'), title: 'Old Title' });
        await repo.insert(chat);
        const updated: Chat = updateChat(chat, { title: 'New Title' });
        await repo.update(updated);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found !== null).assertTrue();
        expect(found!.title).assertEqual('New Title');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 15. 更新 characterId =====
    it('update_characterId', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({ id: uniqueId('chat'), characterId: 'char-old' });
        await repo.insert(chat);
        const updated: Chat = updateChat(chat, { characterId: 'char-new' });
        await repo.update(updated);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found !== null).assertTrue();
        expect(found!.characterId).assertEqual('char-new');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 16. 清空 characterId =====
    it('update_clear_characterId', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({ id: uniqueId('chat'), characterId: 'char-1' });
        await repo.insert(chat);
        const updated: Chat = updateChat(chat, { characterId: null });
        await repo.update(updated);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found !== null).assertTrue();
        expect(found!.characterId).assertUndefined();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 17. updateLastMessageAt =====
    it('updateLastMessageAt', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({ id: uniqueId('chat'), title: 'Test' });
        await repo.insert(chat);
        await repo.updateLastMessageAt(chat.id, 9999, 10000);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found !== null).assertTrue();
        expect(found!.lastMessageAt).assertEqual(9999);
        expect(found!.updatedAt).assertEqual(10000);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 18. setArchived =====
    it('setArchived', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({ id: uniqueId('chat'), title: 'Test' });
        await repo.insert(chat);
        await repo.setArchived(chat.id, true);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found !== null).assertTrue();
        expect(found!.isArchived).assertTrue();
        // 默认 list 不返回 archived
        const list: Chat[] = await repo.list();
        expect(list.length).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 19. update 不存在返回 NotFound =====
    it('update_not_found_throws', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({ id: 'nonexistent-update', title: 'Ghost' });
        try {
          await repo.update(chat);
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

    // ===== 20. remove 存在记录 =====
    it('remove_existing', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({ id: uniqueId('chat'), title: 'To Remove' });
        await repo.insert(chat);
        await repo.remove(chat.id);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found).assertNull();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 21. remove 不存在幂等 =====
    it('remove_nonexistent_idempotent', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        await repo.remove('nonexistent-remove');
        expect(true).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 22. 重复 id 插入失败 =====
    it('insert_duplicate_id_fails', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({ id: 'dup-id-1', title: 'First' });
        await repo.insert(chat);
        const chat2: Chat = createChat({ id: 'dup-id-1', title: 'Second' });
        try {
          await repo.insert(chat2);
          expect(true).assertFalse();
        } catch (e) {
          expect(e instanceof DatabaseError).assertTrue();
          const de: DatabaseError = e as DatabaseError;
          expect(de.type === DatabaseErrorType.ConstraintFailed
            || de.type === DatabaseErrorType.AlreadyExists).assertTrue();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 23. count 正确 =====
    it('count_correct', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        expect(await repo.count()).assertEqual(0);
        await repo.insert(createChat({ id: uniqueId('chat'), title: 'A' }));
        await repo.insert(createChat({ id: uniqueId('chat'), title: 'B' }));
        await repo.insert(createChat({ id: uniqueId('chat'), title: 'C' }));
        expect(await repo.count()).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 24. 中文和 Emoji title 往返 =====
    it('chinese_emoji_title_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const title: string = '你好世界 🌍🎉 어서오세요';
        const chat: Chat = createChat({ id: uniqueId('chat'), title: title });
        await repo.insert(chat);
        const found: Chat | null = await repo.getById(chat.id);
        expect(found !== null).assertTrue();
        expect(found!.title).assertEqual(title);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 25. 不修改输入 Chat 对象 =====
    it('does_not_modify_input_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: ChatRepository = new ChatRepository(helper);
        const chat: Chat = createChat({
          id: uniqueId('chat'),
          characterId: 'char-immut',
          title: 'Immutable Test',
          createdAt: 12345
        });
        const origId: string = chat.id;
        const origCharacterId: string | undefined = chat.characterId;
        const origTitle: string = chat.title;
        const origCreatedAt: number = chat.createdAt;
        const origUpdatedAt: number = chat.updatedAt;
        const origLastMessageAt: number = chat.lastMessageAt;
        const origIsArchived: boolean = chat.isArchived;

        await repo.insert(chat);
        expect(chat.id).assertEqual(origId);
        expect(chat.characterId).assertEqual(origCharacterId);
        expect(chat.title).assertEqual(origTitle);
        expect(chat.createdAt).assertEqual(origCreatedAt);
        expect(chat.updatedAt).assertEqual(origUpdatedAt);
        expect(chat.lastMessageAt).assertEqual(origLastMessageAt);
        expect(chat.isArchived).assertEqual(origIsArchived);

        const updated: Chat = updateChat(chat, { title: 'Changed' });
        const updOrigTitle: string = chat.title;
        await repo.update(updated);
        expect(chat.title).assertEqual(updOrigTitle);
        expect(chat.title).assertEqual('Immutable Test');
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
