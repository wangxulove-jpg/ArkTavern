/**
 * CharacterRepository 设备测试(T-4.6)
 *
 * 使用独立测试数据库 arktavern_character_repository_test.db,前后清理。
 *
 * 覆盖(30 项):
 * 1. 插入最小角色
 * 2. 插入完整角色
 * 3. getById 完整字段往返
 * 4. 不存在返回 null
 * 5. list 排序稳定
 * 6. 中文角色名
 * 7. Emoji
 * 8. 多行 firstMessage
 * 9. Markdown systemPrompt
 * 10. 空 avatarUri
 * 11. 重复 ID 插入失败
 * 12. update 全字段
 * 13. update 不存在返回 NotFound
 * 14. remove 存在角色
 * 15. remove 不存在幂等
 * 16. count 正确
 * 17. exists 正确
 * 18. insertManyIfMissing 全部插入
 * 19. insertManyIfMissing 跳过已有 ID
 * 20. 不覆盖已有 RDB 记录
 * 21. 中途失败整批新记录回滚
 * 22. 空数组迁移
 * 23. 输入数组未修改
 * 24. 输入 Character 未修改
 * 25. ResultSet 正常关闭
 * 26. 损坏 name 拒绝
 * 27. 损坏时间字段拒绝
 * 28. 数据库错误不含正文
 * 29. characters 表不含 API Key
 * 30. 不影响 chats/messages
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { CharacterRepository } from '../../../main/ets/repositories/CharacterRepository';
import { Character } from '../../../main/ets/models/Character';
import { DatabaseError, DatabaseErrorType } from '../../../main/ets/models/DatabaseError';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES
} from '../../../main/ets/database/DatabaseConstants';

const REPO_TEST_DB_NAME: string = 'arktavern_character_repository_test.db';
let idCounter: number = 0;

function uniqueId(prefix: string): string {
  idCounter++;
  return `${prefix}-${idCounter}`;
}

function makeCharacter(
  id: string,
  name: string = 'TestChar',
  description: string = 'desc',
  personality: string = 'p',
  scenario: string = 's',
  firstMessage: string = 'fm',
  systemPrompt: string = 'sp',
  avatarUri: string = 'file://avatar.png',
  createdAt: number = 1000,
  updatedAt: number = 1000
): Character {
  return {
    id: id,
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMessage: firstMessage,
    systemPrompt: systemPrompt,
    avatarUri: avatarUri,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
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

export default function characterRepositoryDeviceTest(): void {
  describe('CharacterRepositoryDeviceTest', () => {

    // ===== 1. 插入最小角色 =====
    it('insert_minimal', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const c: Character = makeCharacter(uniqueId('char'), 'A');
        await repo.insert(c);
        const found: Character | null = await repo.getById(c.id);
        expect(found !== null).assertTrue();
        expect(found!.name).assertEqual('A');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 2. 插入完整角色 =====
    it('insert_full', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const c: Character = makeCharacter(
          uniqueId('char'), 'Alice', 'desc', 'personality',
          'scenario', 'first', 'system', 'file://a.png'
        );
        await repo.insert(c);
        const found: Character | null = await repo.getById(c.id);
        expect(found !== null).assertTrue();
        expect(found!.description).assertEqual('desc');
        expect(found!.personality).assertEqual('personality');
        expect(found!.scenario).assertEqual('scenario');
        expect(found!.firstMessage).assertEqual('first');
        expect(found!.systemPrompt).assertEqual('system');
        expect(found!.avatarUri).assertEqual('file://a.png');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 3. getById 完整字段往返 =====
    it('getById_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const c: Character = makeCharacter(
          uniqueId('char'), 'Bob', 'd2', 'p2', 'sc2', 'fm2', 'sp2', 'file://b.png', 1111, 2222
        );
        await repo.insert(c);
        const found: Character | null = await repo.getById(c.id);
        expect(found !== null).assertTrue();
        expect(found!.id).assertEqual(c.id);
        expect(found!.name).assertEqual(c.name);
        expect(found!.createdAt).assertEqual(1111);
        expect(found!.updatedAt).assertEqual(2222);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 4. 不存在返回 null =====
    it('getById_not_found_returns_null', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const found: Character | null = await repo.getById(uniqueId('nonexistent'));
        expect(found).assertNull();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 5. list 排序稳定 =====
    it('list_sorted', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        await repo.insert(makeCharacter('char-a', 'A', 'x', 'x', 'x', 'x', 'x', '', 1000, 1000));
        await repo.insert(makeCharacter('char-b', 'B', 'x', 'x', 'x', 'x', 'x', '', 2000, 2000));
        await repo.insert(makeCharacter('char-c', 'C', 'x', 'x', 'x', 'x', 'x', '', 1000, 3000));
        const list: Character[] = await repo.list();
        expect(list.length).assertEqual(3);
        // 排序:created_at ASC → updated_at ASC → id ASC
        expect(list[0].id).assertEqual('char-a'); // created=1000, updated=1000
        expect(list[1].id).assertEqual('char-c'); // created=1000, updated=3000
        expect(list[2].id).assertEqual('char-b'); // created=2000
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 6. 中文角色名 =====
    it('chinese_name', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const c: Character = makeCharacter(uniqueId('char'), '爱丽丝');
        await repo.insert(c);
        const found: Character | null = await repo.getById(c.id);
        expect(found!.name).assertEqual('爱丽丝');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 7. Emoji =====
    it('emoji_name', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const c: Character = makeCharacter(uniqueId('char'), '🐱Cat');
        await repo.insert(c);
        const found: Character | null = await repo.getById(c.id);
        expect(found!.name).assertEqual('🐱Cat');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 8. 多行 firstMessage =====
    it('multiline_firstMessage', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const c: Character = makeCharacter(uniqueId('char'), 'A', 'x', 'x', 'x', 'line1\nline2\nline3', 'x');
        await repo.insert(c);
        const found: Character | null = await repo.getById(c.id);
        expect(found!.firstMessage).assertEqual('line1\nline2\nline3');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 9. Markdown systemPrompt =====
    it('markdown_systemPrompt', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const md: string = '# Title\n\n- item1\n- item2\n\n**bold** _italic_ `code`';
        const c: Character = makeCharacter(uniqueId('char'), 'A', 'x', 'x', 'x', 'x', md);
        await repo.insert(c);
        const found: Character | null = await repo.getById(c.id);
        expect(found!.systemPrompt).assertEqual(md);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 10. 空 avatarUri =====
    it('empty_avatarUri', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const c: Character = makeCharacter(uniqueId('char'), 'A', 'x', 'x', 'x', 'x', 'x', '');
        await repo.insert(c);
        const found: Character | null = await repo.getById(c.id);
        expect(found!.avatarUri).assertEqual('');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 11. 重复 ID 插入失败 =====
    it('duplicate_id_throws', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const id: string = uniqueId('char');
        await repo.insert(makeCharacter(id, 'A'));
        let threw: boolean = false;
        try {
          await repo.insert(makeCharacter(id, 'B'));
        } catch (e) {
          threw = true;
          expect(e instanceof DatabaseError).assertTrue();
          expect((e as DatabaseError).type).assertEqual(DatabaseErrorType.AlreadyExists);
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 12. update 全字段 =====
    it('update_all_fields', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const id: string = uniqueId('char');
        await repo.insert(makeCharacter(id, 'Old', 'od', 'op', 'os', 'ofm', 'osp', 'old.png', 1000, 1000));
        const updated: Character = makeCharacter(id, 'New', 'nd', 'np', 'ns', 'nfm', 'nsp', 'new.png', 1000, 5000);
        await repo.update(updated);
        const found: Character | null = await repo.getById(id);
        expect(found!.name).assertEqual('New');
        expect(found!.description).assertEqual('nd');
        expect(found!.avatarUri).assertEqual('new.png');
        expect(found!.createdAt).assertEqual(1000); // createdAt 不变
        expect(found!.updatedAt).assertEqual(5000);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 13. update 不存在返回 NotFound =====
    it('update_not_found', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        let threw: boolean = false;
        try {
          await repo.update(makeCharacter(uniqueId('nonexistent'), 'X'));
        } catch (e) {
          threw = true;
          expect(e instanceof DatabaseError).assertTrue();
          expect((e as DatabaseError).type).assertEqual(DatabaseErrorType.NotFound);
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 14. remove 存在角色 =====
    it('remove_existing', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const id: string = uniqueId('char');
        await repo.insert(makeCharacter(id));
        await repo.remove(id);
        const found: Character | null = await repo.getById(id);
        expect(found).assertNull();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 15. remove 不存在幂等 =====
    it('remove_nonexistent_idempotent', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        // 不存在删除不抛错
        await repo.remove(uniqueId('nonexistent'));
        expect(true).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 16. count 正确 =====
    it('count_correct', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        expect(await repo.count()).assertEqual(0);
        await repo.insert(makeCharacter(uniqueId('char')));
        await repo.insert(makeCharacter(uniqueId('char')));
        expect(await repo.count()).assertEqual(2);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 17. exists 正确 =====
    it('exists_correct', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const id: string = uniqueId('char');
        expect(await repo.exists(id)).assertFalse();
        await repo.insert(makeCharacter(id));
        expect(await repo.exists(id)).assertTrue();
        expect(await repo.exists('')).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 18. insertManyIfMissing 全部插入 =====
    it('insertManyIfMissing_all_new', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const chars: Character[] = [
          makeCharacter(uniqueId('char'), 'A'),
          makeCharacter(uniqueId('char'), 'B'),
          makeCharacter(uniqueId('char'), 'C')
        ];
        const result = await repo.insertManyIfMissing(chars);
        expect(result.insertedCount).assertEqual(3);
        expect(result.skippedExistingCount).assertEqual(0);
        expect(result.totalCount).assertEqual(3);
        expect(await repo.count()).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 19. insertManyIfMissing 跳过已有 ID =====
    it('insertManyIfMissing_skip_existing', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const existingId: string = uniqueId('char');
        await repo.insert(makeCharacter(existingId, 'Existing'));
        const chars: Character[] = [
          makeCharacter(existingId, 'ShouldSkip'),
          makeCharacter(uniqueId('char'), 'New')
        ];
        const result = await repo.insertManyIfMissing(chars);
        expect(result.insertedCount).assertEqual(1);
        expect(result.skippedExistingCount).assertEqual(1);
        expect(result.totalCount).assertEqual(2);
        // 已有记录不被覆盖
        const found: Character | null = await repo.getById(existingId);
        expect(found!.name).assertEqual('Existing');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 20. 不覆盖已有 RDB 记录 =====
    it('insertManyIfMissing_does_not_overwrite', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const id: string = uniqueId('char');
        const original: Character = makeCharacter(id, 'OriginalName', 'orig');
        await repo.insert(original);
        const newVersion: Character = makeCharacter(id, 'NewName', 'new');
        await repo.insertManyIfMissing([newVersion]);
        const found: Character | null = await repo.getById(id);
        expect(found!.name).assertEqual('OriginalName');
        expect(found!.description).assertEqual('orig');
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 21. 中途失败整批新记录回滚 =====
    it('insertManyIfMissing_rollback_on_failure', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        // 先插入一条
        const existingId: string = uniqueId('char');
        await repo.insert(makeCharacter(existingId, 'Existing'));
        // 构造一个会失败的记录(name 为空)
        const bad: Character = {
          id: uniqueId('char'),
          name: '',  // name 为空会触发 validateCharacter 失败
          description: '',
          personality: '',
          scenario: '',
          firstMessage: '',
          systemPrompt: '',
          avatarUri: '',
          createdAt: 1000,
          updatedAt: 1000
        };
        const good: Character = makeCharacter(uniqueId('char'), 'Good');
        let threw: boolean = false;
        try {
          await repo.insertManyIfMissing([good, bad]);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
        // 事务回滚,good 也不应被插入
        expect(await repo.exists(good.id)).assertFalse();
        // existing 保留
        expect(await repo.exists(existingId)).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 22. 空数组迁移 =====
    it('insertManyIfMissing_empty', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const result = await repo.insertManyIfMissing([]);
        expect(result.insertedCount).assertEqual(0);
        expect(result.skippedExistingCount).assertEqual(0);
        expect(result.totalCount).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 23. 输入数组未修改 =====
    it('insertManyIfMissing_input_array_not_modified', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const chars: Character[] = [
          makeCharacter(uniqueId('char'), 'A'),
          makeCharacter(uniqueId('char'), 'B')
        ];
        const originalLength: number = chars.length;
        await repo.insertManyIfMissing(chars);
        expect(chars.length).assertEqual(originalLength);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 24. 输入 Character 未修改 =====
    it('insertManyIfMissing_input_character_not_modified', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const c: Character = makeCharacter(uniqueId('char'), 'Alice', 'desc1');
        const originalName: string = c.name;
        const originalDesc: string = c.description;
        await repo.insertManyIfMissing([c]);
        expect(c.name).assertEqual(originalName);
        expect(c.description).assertEqual(originalDesc);
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 25. ResultSet 正常关闭(不抛错即通过) =====
    it('resultset_closed', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        await repo.insert(makeCharacter(uniqueId('char')));
        // 连续多次查询验证 ResultSet 不泄漏
        for (let i = 0; i < 5; i++) {
          await repo.list();
          await repo.getById(uniqueId('nonexistent'));
        }
        expect(true).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 26. 损坏 name 拒绝 =====
    it('corrupted_name_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const bad: Character = {
          id: uniqueId('char'),
          name: '',  // 空 name
          description: '',
          personality: '',
          scenario: '',
          firstMessage: '',
          systemPrompt: '',
          avatarUri: '',
          createdAt: 1000,
          updatedAt: 1000
        };
        let threw: boolean = false;
        try {
          await repo.insert(bad);
        } catch (e) {
          threw = true;
          expect(e instanceof DatabaseError).assertTrue();
          expect((e as DatabaseError).type).assertEqual(DatabaseErrorType.InvalidData);
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 27. 损坏时间字段拒绝 =====
    it('corrupted_timestamp_rejected', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const bad: Character = {
          id: uniqueId('char'),
          name: 'X',
          description: '',
          personality: '',
          scenario: '',
          firstMessage: '',
          systemPrompt: '',
          avatarUri: '',
          createdAt: -1,  // 非法时间戳
          updatedAt: 1000
        };
        let threw: boolean = false;
        try {
          await repo.insert(bad);
        } catch (e) {
          threw = true;
          expect(e instanceof DatabaseError).assertTrue();
          expect((e as DatabaseError).type).assertEqual(DatabaseErrorType.InvalidData);
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 28. 数据库错误不含正文 =====
    it('error_no_content_leak', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const sensitive: string = 'SECRET_CONTENT_xyz';
        const c: Character = makeCharacter(uniqueId('char'), 'A', sensitive);
        await repo.insert(c);
        // 重复插入触发错误
        let errorMsg: string = '';
        try {
          await repo.insert(c);
        } catch (e) {
          errorMsg = String(e);
        }
        // 错误信息不应包含正文
        expect(errorMsg.indexOf(sensitive) < 0).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 29. characters 表不含 API Key =====
    it('no_api_key_in_table', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        const c: Character = makeCharacter(uniqueId('char'), 'A', 'desc');
        await repo.insert(c);
        // 直接查询数据库验证没有 API Key 列
        const store: relationalStore.RdbStore = helper.getStore();
        const rs: relationalStore.ResultSet = await store.querySql(
          `PRAGMA table_info(${TABLE_CHARACTERS})`
        );
        try {
          let hasApiKey: boolean = false;
          while (rs.goToNextRow()) {
            const colName: string = rs.getString(rs.getColumnIndex('name'));
            if (colName.toLowerCase().indexOf('key') >= 0
              || colName.toLowerCase().indexOf('secret') >= 0
              || colName.toLowerCase().indexOf('token') >= 0) {
              hasApiKey = true;
            }
          }
          expect(hasApiKey).assertFalse();
        } finally {
          rs.close();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });

    // ===== 30. 不影响 chats/messages =====
    it('does_not_affect_other_tables', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const repo: CharacterRepository = new CharacterRepository(helper);
        // 直接插入 chat 和 message
        const store: relationalStore.RdbStore = helper.getStore();
        await store.executeSql(
          `INSERT INTO ${TABLE_CHATS}(id, character_id, title, created_at, updated_at, last_message_at, is_archived) ` +
          `VALUES('chat-1', NULL, 'TestChat', 1000, 1000, 0, 0)`
        );
        await store.executeSql(
          `INSERT INTO ${TABLE_MESSAGES}(id, chat_id, role, content, status, created_at, sequence_number, is_streaming) ` +
          `VALUES('msg-1', 'chat-1', 'user', 'hello', 'completed', 1000, 1, 0)`
        );
        // 删除角色不应影响 chats/messages
        const charId: string = uniqueId('char');
        await repo.insert(makeCharacter(charId));
        await repo.remove(charId);
        // chats/messages 仍在
        const chatRs: relationalStore.ResultSet = await store.querySql(
          `SELECT COUNT(*) AS c FROM ${TABLE_CHATS} WHERE id = 'chat-1'`
        );
        try {
          chatRs.goToFirstRow();
          expect(chatRs.getLong(chatRs.getColumnIndex('c'))).assertEqual(1);
        } finally {
          chatRs.close();
        }
        const msgRs: relationalStore.ResultSet = await store.querySql(
          `SELECT COUNT(*) AS c FROM ${TABLE_MESSAGES} WHERE id = 'msg-1'`
        );
        try {
          msgRs.goToFirstRow();
          expect(msgRs.getLong(msgRs.getColumnIndex('c'))).assertEqual(1);
        } finally {
          msgRs.close();
        }
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
