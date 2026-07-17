/**
 * LorebookRepository Migration 设备测试(ohosTest,需真机/模拟器运行)
 *
 * 覆盖 insertManyIfMissing 的迁移规则。
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { LorebookRepository, LorebookImportResult } from '../../../main/ets/repositories/LorebookRepository';
import { Lorebook, LorebookEntry, LorebookPosition } from '../../../main/ets/models/Lorebook';
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

const TEST_DB_NAME: string = 'arktavern_lorebook_migration_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function deleteDb(context: common.Context): Promise<void> {
  try {
    await relationalStore.deleteRdbStore(context, TEST_DB_NAME);
  } catch (e) { /* ignore */ }
}

async function makeRepo(): Promise<LorebookRepository> {
  const ctx: common.Context = await getContext();
  await deleteDb(ctx);
  const helper: DbHelper = new DbHelper(TEST_DB_NAME, [createV1ToV2Migration()]);
  await helper.initialize(ctx);
  return new LorebookRepository(helper);
}

function makeLb(id: string, name: string, entries: LorebookEntry[] = []): Lorebook {
  return {
    id: id, name: name, description: '', enabled: true,
    entries: entries, createdAt: 1000, updatedAt: 1000
  };
}

function makeEntry(id: string, name: string = 'entry'): LorebookEntry {
  return {
    id: id, name: name, keys: ['key1'], secondaryKeys: [], content: 'content',
    enabled: true, constant: false, selective: false,
    position: LorebookPosition.BeforeCharacter, priority: 0,
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

export default function lorebookRepositoryMigrationTest(): void {
  describe('LorebookRepositoryMigrationTest', () => {

    it('empty_array', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        const result: LorebookImportResult = await repo.insertManyIfMissing([]);
        expect(result.insertedLorebookCount).assertEqual(0);
        expect(result.insertedEntryCount).assertEqual(0);
        expect(result.totalLorebookCount).assertEqual(0);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('single_lorebook', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        const result: LorebookImportResult = await repo.insertManyIfMissing([
          makeLb('lb-1', 'A', [makeEntry('e-1')])
        ]);
        expect(result.insertedLorebookCount).assertEqual(1);
        expect(result.insertedEntryCount).assertEqual(1);
        expect(result.totalLorebookCount).assertEqual(1);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('multiple_lorebooks', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        const result: LorebookImportResult = await repo.insertManyIfMissing([
          makeLb('lb-1', 'A', [makeEntry('e-1')]),
          makeLb('lb-2', 'B', [makeEntry('e-2')])
        ]);
        expect(result.insertedLorebookCount).assertEqual(2);
        expect(result.insertedEntryCount).assertEqual(2);
        expect(result.totalLorebookCount).assertEqual(2);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('preserves_lorebook_id', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        await repo.insertManyIfMissing([makeLb('lb-1', 'A')]);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.id).assertEqual('lb-1');
        }
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('preserves_entry_id', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        await repo.insertManyIfMissing([makeLb('lb-1', 'A', [makeEntry('e-1')])]);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries[0].id).assertEqual('e-1');
        }
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('skip_existing_lorebook', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        await repo.insert(makeLb('lb-1', 'A', [makeEntry('e-1')]));
        const result: LorebookImportResult = await repo.insertManyIfMissing([
          makeLb('lb-1', 'A', [makeEntry('e-1')]),
          makeLb('lb-2', 'B', [makeEntry('e-2')])
        ]);
        expect(result.skippedExistingLorebookCount).assertEqual(1);
        expect(result.insertedLorebookCount).assertEqual(1);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('not_overwrite_existing', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        await repo.insert(makeLb('lb-1', 'Original', [makeEntry('e-1')]));
        await repo.insertManyIfMissing([makeLb('lb-1', 'NewName', [makeEntry('e-2')])]);
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.name).assertEqual('Original');
          expect(fetched.entries.length).assertEqual(1);
        }
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('partial_existing', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        await repo.insert(makeLb('lb-1', 'A'));
        const result: LorebookImportResult = await repo.insertManyIfMissing([
          makeLb('lb-1', 'A'),
          makeLb('lb-2', 'B'),
          makeLb('lb-3', 'C')
        ]);
        expect(result.skippedExistingLorebookCount).assertEqual(1);
        expect(result.insertedLorebookCount).assertEqual(2);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('repeat_execution_no_duplicate', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        const r1: LorebookImportResult = await repo.insertManyIfMissing([
          makeLb('lb-1', 'A', [makeEntry('e-1')])
        ]);
        expect(r1.insertedLorebookCount).assertEqual(1);
        const r2: LorebookImportResult = await repo.insertManyIfMissing([
          makeLb('lb-1', 'A', [makeEntry('e-1')])
        ]);
        expect(r2.skippedExistingLorebookCount).assertEqual(1);
        expect(r2.insertedLorebookCount).assertEqual(0);
        const ctx: common.Context = await getContext();
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
        const count: number = await rowCount(store, TABLE_LOREBOOKS);
        try { await store.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('duplicate_lorebook_id_in_input_rejected', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        let caught: boolean = false;
        try {
          await repo.insertManyIfMissing([
            makeLb('lb-1', 'A'),
            makeLb('lb-1', 'B')
          ]);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('duplicate_entry_id_in_input_rejected', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        let caught: boolean = false;
        try {
          await repo.insertManyIfMissing([
            makeLb('lb-1', 'A', [makeEntry('e-1')]),
            makeLb('lb-2', 'B', [makeEntry('e-1')])
          ]);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('entry_id_conflict_with_other_lorebook_fails', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        await repo.insert(makeLb('lb-1', 'A', [makeEntry('e-1')]));
        let caught: boolean = false;
        try {
          await repo.insertManyIfMissing([makeLb('lb-2', 'B', [makeEntry('e-1')])]);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('mid_batch_failure_rollbacks_new', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        await repo.insert(makeLb('lb-1', 'A', [makeEntry('e-1')]));
        let caught: boolean = false;
        try {
          // lb-2 已存在 e-1 冲突, lb-3 为新增, 整批应回滚
          await repo.insertManyIfMissing([
            makeLb('lb-2', 'B', [makeEntry('e-2')]),
            makeLb('lb-3', 'C', [makeEntry('e-1')])
          ]);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
        // lb-2 不应残留
        const ctx: common.Context = await getContext();
        const config: relationalStore.StoreConfig = {
          name: TEST_DB_NAME,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
        const count: number = await rowCount(store, TABLE_LOREBOOKS);
        try { await store.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('existing_data_unaffected_by_rollback', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        await repo.insert(makeLb('lb-1', 'A', [makeEntry('e-1')]));
        try {
          await repo.insertManyIfMissing([makeLb('lb-2', 'B', [makeEntry('e-1')])]);
        } catch (e) { /* expected */ }
        const fetched: Lorebook | null = await repo.getById('lb-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.entries.length).assertEqual(1);
        }
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('input_array_not_mutated', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        const input: Lorebook[] = [makeLb('lb-1', 'A', [makeEntry('e-1')])];
        const originalLen: number = input.length;
        await repo.insertManyIfMissing(input);
        expect(input.length).assertEqual(originalLen);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('input_lorebook_not_mutated', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        const lb: Lorebook = makeLb('lb-1', 'A', [makeEntry('e-1')]);
        const originalName: string = lb.name;
        await repo.insertManyIfMissing([lb]);
        expect(lb.name).assertEqual(originalName);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('statistics_correct', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
      try {
        const result: LorebookImportResult = await repo.insertManyIfMissing([
          makeLb('lb-1', 'A', [makeEntry('e-1'), makeEntry('e-2')]),
          makeLb('lb-2', 'B', [makeEntry('e-3')])
        ]);
        expect(result.insertedLorebookCount).assertEqual(2);
        expect(result.insertedEntryCount).assertEqual(3);
        expect(result.totalLorebookCount).assertEqual(2);
        expect(result.totalEntryCount).assertEqual(3);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('does_not_affect_characters', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
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
        await repo.insertManyIfMissing([makeLb('lb-1', 'A')]);
        const store2: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
        const count: number = await rowCount(store2, TABLE_CHARACTERS);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });

    it('does_not_affect_chats_messages', 0, async () => {
      const repo: LorebookRepository = await makeRepo();
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
        await repo.insertManyIfMissing([makeLb('lb-1', 'A')]);
        const store2: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
        const count: number = await rowCount(store2, TABLE_CHATS);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        const ctx: common.Context = await getContext();
        await deleteDb(ctx);
      }
    });
  });
}