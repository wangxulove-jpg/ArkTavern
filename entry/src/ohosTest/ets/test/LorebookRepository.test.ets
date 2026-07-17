/**
 * LorebookRepository 设备测试(ohosTest,需真机/模拟器运行)
 *
 * 覆盖:
 * - 基础 CRUD(insert/getById/list/update/remove/count/exists)
 * - Entry 字段(keys/secondaryKeys/中文/Emoji/多行/position/priority/enabled/constant/selective)
 * - 聚合事务(插入失败回滚/更新差量同步/删除级联/Entry 跨 Lorebook 移动防护)
 * - 安全和损坏数据(keys_json/position/boolean/time/ResultSet 关闭)
 * - 不持久化动态字段
 * - 不影响旧表
 *
 * 使用独立测试数据库 arktavern_lorebook_repository_test.db。
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { LorebookRepository } from '../../../main/ets/repositories/LorebookRepository';
import { Lorebook, LorebookEntry, LorebookPosition } from '../../../main/ets/models/Lorebook';
import { DatabaseError, DatabaseErrorType } from '../../../main/ets/models/DatabaseError';
import { createV1ToV2Migration } from '../../../main/ets/database/DatabaseMigration';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_LOREBOOKS,
  TABLE_LOREBOOK_ENTRIES,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_CHARACTER_ID,
  COLUMN_TITLE,
  COLUMN_LAST_MESSAGE_AT,
  COLUMN_IS_ARCHIVED,
  COLUMN_CHAT_ID,
  COLUMN_ROLE,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_IS_STREAMING,
  COLUMN_SOURCE
} from '../../../main/ets/database/DatabaseConstants';

const TEST_DB_NAME: string = 'arktavern_lorebook_repository_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function deleteDb(context: common.Context): Promise<void> {
  try {
    await relationalStore.deleteRdbStore(context, TEST_DB_NAME);
  } catch (e) {
    /* best-effort */
  }
}

async function makeRepository(): Promise<LorebookRepository> {
  const ctx: common.Context = await getContext();
  await deleteDb(ctx);
  const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
  await helper.initialize(ctx);
  return new LorebookRepository(helper);
}

async function cleanupRepo(repo: LorebookRepository): Promise<void> {
  const ctx: common.Context = await getContext();
  await deleteDb(ctx);
}

function makeLorebook(
  id: string, name: string, entries: LorebookEntry[] = []
): Lorebook {
  return {
    id: id, name: name, description: '', enabled: true,
    entries: entries, createdAt: 1000, updatedAt: 1000
  };
}

function makeEntry(
  id: string, name: string = 'entry', content: string = 'content',
  position: LorebookPosition = LorebookPosition.BeforeCharacter,
  priority: number = 0
): LorebookEntry {
  return {
    id: id, name: name, keys: ['key1'], secondaryKeys: [], content: content,
    enabled: true, constant: false, selective: false,
    position: position, priority: priority,
    createdAt: 2000, updatedAt: 2000
  };
}

async function rowCount(
  store: relationalStore.RdbStore, table: string
): Promise<number> {
  const rs = await store.querySql(`SELECT COUNT(*) AS cnt FROM ${table}`);
  try {
    if (rs.goToFirstRow()) {
      const ci: number = rs.getColumnIndex('cnt');
      if (ci >= 0) { return rs.getLong(ci); }
    }
    return 0;
  } finally {
    try { rs.close(); } catch (e) { /* ignore */ }
  }
}

export default function lorebookRepositoryTest(): void {
  describe('LorebookRepositoryTest', () => {

    // ===== 基础 CRUD =====

    it('insert_empty_entries', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const lb: Lorebook = makeLorebook('lb-1', 'Test');
        await repo.insert(lb);
        const count: number = await repo.count();
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('insert_single_entry', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = makeEntry('e-1');
        const lb: Lorebook = makeLorebook('lb-1', 'Test', [e]);
        await repo.insert(lb);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries.length).assertEqual(1);
          expect(fetched.entries[0].id).assertEqual('e-1');
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('insert_multiple_entries', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e1: LorebookEntry = makeEntry('e-1', 'a', 'content-a');
        const e2: LorebookEntry = makeEntry('e-2', 'b', 'content-b');
        const lb: Lorebook = makeLorebook('lb-1', 'Test', [e1, e2]);
        await repo.insert(lb);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries.length).assertEqual(2);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('getById_all_fields_complete', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = makeEntry('e-1', 'EntryName', 'EntryContent');
        const lb: Lorebook = {
          id: 'lb-1', name: 'LbName', description: 'Desc', enabled: true,
          entries: [e], createdAt: 1000, updatedAt: 2000
        };
        await repo.insert(lb);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.id).assertEqual('lb-1');
          expect(fetched.name).assertEqual('LbName');
          expect(fetched.description).assertEqual('Desc');
          expect(fetched.enabled).assertEqual(true);
          expect(fetched.createdAt).assertEqual(1000);
          expect(fetched.updatedAt).assertEqual(2000);
          expect(fetched.entries.length).assertEqual(1);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('getById_not_found_returns_null', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const fetched: Lorebook | null = await repo.getById('nonexistent');
        expect(fetched === null).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('list_returns_full_aggregation', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e1: LorebookEntry = makeEntry('e-1', 'a', 'ca');
        const e2: LorebookEntry = makeEntry('e-2', 'b', 'cb');
        await repo.insert(makeLorebook('lb-1', 'Lb1', [e1]));
        await repo.insert(makeLorebook('lb-2', 'Lb2', [e2]));
        const list: Lorebook[] = await repo.list();
        expect(list.length).assertEqual(2);
        expect(list[0].entries.length).assertEqual(1);
        expect(list[1].entries.length).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('list_stable_order', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'A'));
        await repo.insert(makeLorebook('lb-2', 'B'));
        await repo.insert(makeLorebook('lb-3', 'C'));
        const list: Lorebook[] = await repo.list();
        expect(list.length).assertEqual(3);
        expect(list[0].id).assertEqual('lb-1');
        expect(list[1].id).assertEqual('lb-2');
        expect(list[2].id).assertEqual('lb-3');
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('update_main_fields', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'Old'));
        const updated: Lorebook = {
          id: 'lb-1', name: 'New', description: 'NewDesc', enabled: false,
          entries: [], createdAt: 1000, updatedAt: 3000
        };
        await repo.update(updated);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.name).assertEqual('New');
          expect(fetched.description).assertEqual('NewDesc');
          expect(fetched.enabled).assertEqual(false);
          expect(fetched.updatedAt).assertEqual(3000);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('update_not_found_throws', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const updated: Lorebook = {
          id: 'nonexistent', name: 'N', description: '', enabled: true,
          entries: [], createdAt: 1000, updatedAt: 1000
        };
        let caught: boolean = false;
        let errorType: number = -1;
        try {
          await repo.update(updated);
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(caught).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.NotFound);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('remove_existing', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'Test'));
        await repo.remove('lb-1');
        const count: number = await repo.count();
        expect(count).assertEqual(0);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('remove_nonexistent_idempotent', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.remove('nonexistent');
        expect(true).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('count_correct', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'A'));
        await repo.insert(makeLorebook('lb-2', 'B'));
        const count: number = await repo.count();
        expect(count).assertEqual(2);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('exists_true', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'Test'));
        expect(await repo.exists('lb-1')).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('exists_false', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        expect(await repo.exists('nonexistent')).assertFalse();
      } finally {
        await cleanupRepo(repo);
      }
    });

    // ===== Entry 字段 =====

    it('entry_keys_roundtrip', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = {
          id: 'e-1', name: 'entry', keys: ['k1', 'k2', 'k3'], secondaryKeys: [],
          content: 'c', enabled: true, constant: false, selective: false,
          position: LorebookPosition.BeforeCharacter, priority: 0,
          createdAt: 2000, updatedAt: 2000
        };
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].keys.length).assertEqual(3);
          expect(fetched.entries[0].keys[0]).assertEqual('k1');
          expect(fetched.entries[0].keys[2]).assertEqual('k3');
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_secondaryKeys_roundtrip', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = {
          id: 'e-1', name: 'entry', keys: ['primary'], secondaryKeys: ['sk1', 'sk2'],
          content: 'c', enabled: true, constant: false, selective: false,
          position: LorebookPosition.BeforeCharacter, priority: 0,
          createdAt: 2000, updatedAt: 2000
        };
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].secondaryKeys.length).assertEqual(2);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_chinese_keys', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = {
          id: 'e-1', name: '中文', keys: ['你好', '世界'], secondaryKeys: ['中文'],
          content: '中文内容', enabled: true, constant: false, selective: false,
          position: LorebookPosition.BeforeCharacter, priority: 0,
          createdAt: 2000, updatedAt: 2000
        };
        await repo.insert(makeLorebook('lb-1', '中文世界书', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].keys[0]).assertEqual('你好');
          expect(fetched.entries[0].content).assertEqual('中文内容');
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_emoji', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = {
          id: 'e-1', name: '😀', keys: ['🎉', '❤️'], secondaryKeys: [],
          content: 'emoji test 😀', enabled: true, constant: false, selective: false,
          position: LorebookPosition.BeforeCharacter, priority: 0,
          createdAt: 2000, updatedAt: 2000
        };
        await repo.insert(makeLorebook('lb-1', 'Emoji', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].keys[0]).assertEqual('🎉');
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_multiline_content', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = {
          id: 'e-1', name: 'entry', keys: ['key'], secondaryKeys: [],
          content: 'line1\nline2\nline3', enabled: true, constant: false, selective: false,
          position: LorebookPosition.BeforeCharacter, priority: 0,
          createdAt: 2000, updatedAt: 2000
        };
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].content).assertEqual('line1\nline2\nline3');
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_position_before', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = makeEntry('e-1', 'e', 'c', LorebookPosition.BeforeCharacter);
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].position).assertEqual(LorebookPosition.BeforeCharacter);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_position_after', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = makeEntry('e-1', 'e', 'c', LorebookPosition.AfterCharacter);
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].position).assertEqual(LorebookPosition.AfterCharacter);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_priority_positive', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = makeEntry('e-1', 'e', 'c', LorebookPosition.BeforeCharacter, 100);
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].priority).assertEqual(100);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_priority_negative', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = makeEntry('e-1', 'e', 'c', LorebookPosition.BeforeCharacter, -5);
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].priority).assertEqual(-5);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_enabled_false', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = {
          id: 'e-1', name: 'entry', keys: ['key'], secondaryKeys: [],
          content: 'c', enabled: false, constant: false, selective: false,
          position: LorebookPosition.BeforeCharacter, priority: 0,
          createdAt: 2000, updatedAt: 2000
        };
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].enabled).assertEqual(false);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_constant_true', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = {
          id: 'e-1', name: 'entry', keys: [], secondaryKeys: [],
          content: 'c', enabled: true, constant: true, selective: false,
          position: LorebookPosition.BeforeCharacter, priority: 0,
          createdAt: 2000, updatedAt: 2000
        };
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].constant).assertEqual(true);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_selective_true', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = {
          id: 'e-1', name: 'entry', keys: ['primary'], secondaryKeys: ['secondary'],
          content: 'c', enabled: true, constant: false, selective: true,
          position: LorebookPosition.BeforeCharacter, priority: 0,
          createdAt: 2000, updatedAt: 2000
        };
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].selective).assertEqual(true);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    // ===== 聚合事务 =====

    it('insert_id_conflict_throws', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'Test'));
        let caught: boolean = false;
        try {
          await repo.insert(makeLorebook('lb-1', 'Dup'));
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('insert_entry_id_conflict_throws', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'A', [makeEntry('e-1', 'a', 'ca')]));
        let caught: boolean = false;
        try {
          await repo.insert(makeLorebook('lb-2', 'B', [makeEntry('e-1', 'b', 'cb')]));
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
        // 第二个 Lorebook 不应部分插入
        const list: Lorebook[] = await repo.list();
        expect(list.length).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('lorebook_not_remaining_after_failed_insert', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        try {
          await repo.insert(makeLorebook('lb-1', 'A', [makeEntry('e-1')]));
          await repo.insert(makeLorebook('lb-2', 'B', [makeEntry('e-1')]));
        } catch (e) { /* expected */ }
        const count: number = await repo.count();
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('update_add_new_entry', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'Test', [makeEntry('e-1')]));
        const updated: Lorebook = {
          id: 'lb-1', name: 'Test', description: '', enabled: true,
          entries: [makeEntry('e-1'), makeEntry('e-2', 'new', 'new-content')],
          createdAt: 1000, updatedAt: 3000
        };
        await repo.update(updated);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries.length).assertEqual(2);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('update_existing_entry', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'Test', [makeEntry('e-1', 'old', 'old-content')]));
        const updated: Lorebook = {
          id: 'lb-1', name: 'Test', description: '', enabled: true,
          entries: [{
            id: 'e-1', name: 'updated', keys: ['new-key'], secondaryKeys: ['sk'],
            content: 'new-content', enabled: true, constant: false, selective: false,
            position: LorebookPosition.AfterCharacter, priority: 10,
            createdAt: 2000, updatedAt: 4000
          }],
          createdAt: 1000, updatedAt: 3000
        };
        await repo.update(updated);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries.length).assertEqual(1);
          expect(fetched.entries[0].name).assertEqual('updated');
          expect(fetched.entries[0].content).assertEqual('new-content');
          expect(fetched.entries[0].keys[0]).assertEqual('new-key');
          expect(fetched.entries[0].priority).assertEqual(10);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('update_delete_entry', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'Test', [makeEntry('e-1'), makeEntry('e-2')]));
        const updated: Lorebook = {
          id: 'lb-1', name: 'Test', description: '', enabled: true,
          entries: [makeEntry('e-1')],
          createdAt: 1000, updatedAt: 3000
        };
        await repo.update(updated);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries.length).assertEqual(1);
          expect(fetched.entries[0].id).assertEqual('e-1');
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('update_transaction_failure_rollback', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'Test', [makeEntry('e-1', 'a', 'ca')]));
        // 尝试用非法数据更新(空 name)
        let caught: boolean = false;
        try {
          const invalid: Lorebook = {
            id: 'lb-1', name: '', description: '', enabled: true,
            entries: [makeEntry('e-1', 'a', 'ca')],
            createdAt: 1000, updatedAt: 3000
          };
          await repo.update(invalid);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
        // 原数据应保持不变
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.name).assertEqual('Test');
          expect(fetched.entries.length).assertEqual(1);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('remove_cascades_entries', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'Test', [makeEntry('e-1'), makeEntry('e-2')]));
        await repo.remove('lb-1');
        // 直接查 entries 表
        const ctx: common.Context = await getContext();
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
        const count: number = await rowCount(store, TABLE_LOREBOOK_ENTRIES);
        try { await store.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(0);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('remove_does_not_affect_other_lorebook', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'A', [makeEntry('e-1')]));
        await repo.insert(makeLorebook('lb-2', 'B', [makeEntry('e-2')]));
        await repo.remove('lb-1');
        const fetched: Lorebook | null = await repo.getById('lb-2');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries.length).assertEqual(1);
          expect(fetched.entries[0].id).assertEqual('e-2');
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('entry_id_cannot_move_across_lorebooks', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        await repo.insert(makeLorebook('lb-1', 'A', [makeEntry('e-1')]));
        await repo.insert(makeLorebook('lb-2', 'B', [makeEntry('e-2')]));
        // 尝试把 e-1 移到 lb-2
        let caught: boolean = false;
        try {
          const updated: Lorebook = {
            id: 'lb-2', name: 'B', description: '', enabled: true,
            entries: [makeEntry('e-2'), makeEntry('e-1')],
            createdAt: 1000, updatedAt: 3000
          };
          await repo.update(updated);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('duplicate_entry_id_in_input_rejected', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const lb: Lorebook = {
          id: 'lb-1', name: 'Test', description: '', enabled: true,
          entries: [makeEntry('e-1', 'a'), makeEntry('e-1', 'b')],
          createdAt: 1000, updatedAt: 1000
        };
        let caught: boolean = false;
        try {
          await repo.insert(lb);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    // ===== 安全和损坏数据 =====

    it('corrupted_keys_json_returns_invalid_data', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      const ctx: common.Context = await getContext();
      const config: relationalStore.StoreConfig = {
        name: TEST_DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
      await store.executeSql(
        `INSERT INTO ${TABLE_LOREBOOKS}(id,name,description,enabled,created_at,updated_at) VALUES('lb-1','x','',1,1,1)`
      );
      await store.executeSql(
        `INSERT INTO ${TABLE_LOREBOOK_ENTRIES}(id,lorebook_id,name,keys_json,secondary_keys_json,content,enabled,constant,selective,position,priority,created_at,updated_at) VALUES('e-1','lb-1','x','not json','[]','',1,0,0,'BeforeCharacter',0,1,1)`
      );
      await store.close();
      let caught: boolean = false;
      let errorType: number = -1;
      try {
        await repo.getById('lb-1');
      } catch (e) {
        caught = true;
        if (e instanceof DatabaseError) {
          errorType = e.type;
        }
      }
      expect(caught).assertTrue();
      expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
      try {
        await cleanupRepo(repo);
      } catch (e) { /* ignore */ }
    });

    it('empty_name_rejected', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        let caught: boolean = false;
        try {
          await repo.insert(makeLorebook('lb-1', ''));
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('invalid_timestamp_rejected', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        let caught: boolean = false;
        try {
          const lb: Lorebook = {
            id: 'lb-1', name: 'Test', description: '', enabled: true,
            entries: [], createdAt: NaN, updatedAt: 1000
          };
          await repo.insert(lb);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('input_lorebook_not_mutated', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const lb: Lorebook = makeLorebook('lb-1', 'Test', [makeEntry('e-1')]);
        const originalName: string = lb.name;
        const originalEntryCount: number = lb.entries.length;
        await repo.insert(lb);
        expect(lb.name).assertEqual(originalName);
        expect(lb.entries.length).assertEqual(originalEntryCount);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('input_entries_array_not_mutated', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const entries: LorebookEntry[] = [makeEntry('e-1')];
        const originalLength: number = entries.length;
        const lb: Lorebook = makeLorebook('lb-1', 'Test', entries);
        await repo.insert(lb);
        expect(entries.length).assertEqual(originalLength);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('no_persist_prompt_transient_fields', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const e: LorebookEntry = makeEntry('e-1');
        await repo.insert(makeLorebook('lb-1', 'Test', [e]));
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          const entryKeys: string[] = Object.keys(fetched.entries[0]);
          expect(entryKeys.indexOf('matchedEntryIds') < 0).assertTrue();
          expect(entryKeys.indexOf('injectionResult') < 0).assertTrue();
          expect(entryKeys.indexOf('promptSegment') < 0).assertTrue();
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('does_not_affect_characters', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const ctx: common.Context = await getContext();
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
        const vb: relationalStore.ValuesBucket = {};
        vb[COLUMN_ID] = 'c-1';
        vb[COLUMN_NAME] = 'Char';
        vb[COLUMN_CREATED_AT] = 1000;
        vb[COLUMN_UPDATED_AT] = 1000;
        await store.insert(TABLE_CHARACTERS, vb);
        await store.close();
        await repo.insert(makeLorebook('lb-1', 'Test'));
        const ctx2: common.Context = await getContext();
        const store2: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx2, config);
        const count: number = await rowCount(store2, TABLE_CHARACTERS);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('does_not_affect_chats', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const ctx: common.Context = await getContext();
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
        const vb: relationalStore.ValuesBucket = {};
        vb[COLUMN_ID] = 'chat-1';
        vb[COLUMN_TITLE] = 'Chat';
        vb[COLUMN_CHARACTER_ID] = null;
        vb[COLUMN_CREATED_AT] = 2000;
        vb[COLUMN_UPDATED_AT] = 2000;
        vb[COLUMN_LAST_MESSAGE_AT] = 0;
        vb[COLUMN_IS_ARCHIVED] = 0;
        await store.insert(TABLE_CHATS, vb);
        await store.close();
        await repo.insert(makeLorebook('lb-1', 'Test'));
        const ctx2: common.Context = await getContext();
        const store2: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx2, config);
        const count: number = await rowCount(store2, TABLE_CHATS);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('does_not_affect_messages', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        const ctx: common.Context = await getContext();
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
        const vb: relationalStore.ValuesBucket = {};
        vb[COLUMN_ID] = 'msg-1';
        vb[COLUMN_CHAT_ID] = 'chat-1';
        vb[COLUMN_ROLE] = 'user';
        vb[COLUMN_CONTENT] = 'hello';
        vb[COLUMN_STATUS] = 'completed';
        vb[COLUMN_CREATED_AT] = 3000;
        vb[COLUMN_UPDATED_AT] = 3000;
        vb[COLUMN_SEQUENCE_NUMBER] = 1;
        vb[COLUMN_IS_STREAMING] = 0;
        vb[COLUMN_SOURCE] = null;
        await store.insert(TABLE_MESSAGES, vb);
        await store.close();
        await repo.insert(makeLorebook('lb-1', 'Test'));
        const ctx2: common.Context = await getContext();
        const store2: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx2, config);
        const count: number = await rowCount(store2, TABLE_MESSAGES);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('error_does_not_contain_content_or_sql', 0, async () => {
      const repo: LorebookRepository = await makeRepository();
      try {
        let caught: boolean = false;
        let msg: string = '';
        try {
          await repo.insert(makeLorebook('lb-1', ''));
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            msg = e.message + ' ' + e.causeMessage;
          } else if (e instanceof Error) {
            msg = e.message;
          }
        }
        expect(caught).assertTrue();
        expect(msg.indexOf('SQL') < 0).assertTrue();
        expect(msg.indexOf('CREATE') < 0).assertTrue();
        expect(msg.indexOf('SELECT') < 0).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });
  });
}