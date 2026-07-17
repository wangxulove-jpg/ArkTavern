/**
 * LorebookMigrationService 纯逻辑测试
 *
 * 使用 mock 验证迁移流程,不依赖设备 API。
 */
import { describe, it, expect } from '@ohos/hypium';
import { LorebookMigrationService } from '../../main/ets/services/LorebookMigrationService';
import { LorebookStore } from '../../main/ets/storage/LorebookStore';
import { LorebookSelectionStore } from '../../main/ets/storage/LorebookSelectionStore';
import { LorebookRepository, LorebookImportResult } from '../../main/ets/repositories/LorebookRepository';
import { AppPreferences } from '../../main/ets/storage/AppPreferences';
import { Lorebook, LorebookEntry, LorebookPosition } from '../../main/ets/models/Lorebook';
import { LorebookMigrationResult } from '../../main/ets/models/LorebookMigrationResult';

// ===== Mock AppPreferences =====
class MockAppPreferences extends AppPreferences {
  private markers: Map<string, boolean> = new Map();
  private strings: Map<string, string> = new Map();

  async getBoolean(key: string, defaultValue: boolean): Promise<boolean> {
    const val: boolean | undefined = this.markers.get(key);
    if (val !== undefined) {
      return val;
    }
    return defaultValue;
  }

  async putBoolean(key: string, value: boolean): Promise<void> {
    this.markers.set(key, value);
  }

  async getString(key: string, defaultValue: string): Promise<string> {
    const val: string | undefined = this.strings.get(key);
    if (val !== undefined) {
      return val;
    }
    return defaultValue;
  }

  async putString(key: string, value: string): Promise<void> {
    this.strings.set(key, value);
  }
}

function makeEntry(id: string): LorebookEntry {
  return {
    id: id, name: 'entry', keys: ['key'], secondaryKeys: [], content: 'content',
    enabled: true, constant: false, selective: false,
    position: LorebookPosition.BeforeCharacter, priority: 0,
    createdAt: 2000, updatedAt: 2000
  };
}

function makeLb(id: string, entries: LorebookEntry[] = []): Lorebook {
  return {
    id: id, name: 'Lorebook', description: '', enabled: true,
    entries: entries, createdAt: 1000, updatedAt: 1000
  };
}

function makeSvc(
  legacyBooks: Lorebook[],
  currentId: string | null,
  marker: boolean,
  repoExists: boolean = true
): LorebookMigrationService {
  const prefs: MockAppPreferences = new MockAppPreferences();
  if (marker) {
    prefs.putBoolean('lorebook_rdb_migration_v1_complete', true);
  }
  const legacyStore: LorebookStore = {
    list: async (): Promise<Lorebook[]> => legacyBooks,
    getCurrentLorebookId: async (): Promise<string | null> => currentId
  } as unknown as LorebookStore;
  const selectionStore: LorebookSelectionStore = {
    setCurrentLorebookId: async (id: string | null): Promise<void> => {}
  } as unknown as LorebookSelectionStore;
  const repo: LorebookRepository = {
    insertManyIfMissing: async (lbs: Lorebook[]): Promise<LorebookImportResult> => {
      let entryCount: number = 0;
      for (let i = 0; i < lbs.length; i++) {
        entryCount += lbs[i].entries.length;
      }
      return {
        insertedLorebookCount: lbs.length,
        insertedEntryCount: entryCount,
        skippedExistingLorebookCount: 0,
        totalLorebookCount: lbs.length,
        totalEntryCount: entryCount
      };
    },
    getById: async (id: string): Promise<Lorebook | null> => {
      for (let i = 0; i < legacyBooks.length; i++) {
        if (legacyBooks[i].id === id) {
          return legacyBooks[i];
        }
      }
      return null;
    },
    exists: async (id: string): Promise<boolean> => {
      return repoExists;
    }
  } as unknown as LorebookRepository;
  return new LorebookMigrationService(legacyStore, repo, selectionStore, prefs);
}

export default function lorebookMigrationServiceTest(): void {
  describe('LorebookMigrationService', () => {

    it('marker_true_skips', 0, async () => {
      const svc: LorebookMigrationService = makeSvc([], null, true);
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.attempted).assertFalse();
      expect(result.completed).assertFalse();
    });

    it('no_legacy_lorebooks_completes', 0, async () => {
      const svc: LorebookMigrationService = makeSvc([], null, false);
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.attempted).assertTrue();
      expect(result.completed).assertTrue();
      expect(result.legacyLorebookCount).assertEqual(0);
    });

    it('single_lorebook_migration', 0, async () => {
      const svc: LorebookMigrationService = makeSvc(
        [makeLb('lb-1', [makeEntry('e-1')])],
        null, false
      );
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.attempted).assertTrue();
      expect(result.completed).assertTrue();
      expect(result.legacyLorebookCount).assertEqual(1);
      expect(result.legacyEntryCount).assertEqual(1);
    });

    it('multiple_lorebook_migration', 0, async () => {
      const svc: LorebookMigrationService = makeSvc(
        [makeLb('lb-1', [makeEntry('e-1')]), makeLb('lb-2', [makeEntry('e-2')])],
        null, false
      );
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.legacyLorebookCount).assertEqual(2);
      expect(result.legacyEntryCount).assertEqual(2);
    });

    it('preserves_lorebook_id', 0, async () => {
      const svc: LorebookMigrationService = makeSvc(
        [makeLb('lb-1')], null, false
      );
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.completed).assertTrue();
    });

    it('preserves_entry_id', 0, async () => {
      const svc: LorebookMigrationService = makeSvc(
        [makeLb('lb-1', [makeEntry('e-1')])], null, false
      );
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.completed).assertTrue();
    });

    it('current_lorebook_exists_preserved', 0, async () => {
      const svc: LorebookMigrationService = makeSvc(
        [makeLb('lb-1')], 'lb-1', false, true
      );
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.currentLorebookPreserved).assertTrue();
    });

    it('current_lorebook_not_exist_cleared', 0, async () => {
      let cleared: boolean = false;
      const prefs: MockAppPreferences = new MockAppPreferences();
      const legacyStore: LorebookStore = {
        list: async (): Promise<Lorebook[]> => [],
        getCurrentLorebookId: async (): Promise<string | null> => 'missing-id'
      } as unknown as LorebookStore;
      const selectionStore: LorebookSelectionStore = {
        setCurrentLorebookId: async (id: string | null): Promise<void> => {
          cleared = true;
        }
      } as unknown as LorebookSelectionStore;
      const repo: LorebookRepository = {
        insertManyIfMissing: async (): Promise<LorebookImportResult> => ({
          insertedLorebookCount: 0, insertedEntryCount: 0,
          skippedExistingLorebookCount: 0, totalLorebookCount: 0, totalEntryCount: 0
        }),
        getById: async (): Promise<Lorebook | null> => null,
        exists: async (): Promise<boolean> => false
      } as unknown as LorebookRepository;
      const svc: LorebookMigrationService = new LorebookMigrationService(
        legacyStore, repo, selectionStore, prefs
      );
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.currentLorebookPreserved).assertFalse();
      expect(cleared).assertTrue();
    });

    it('current_id_empty', 0, async () => {
      const svc: LorebookMigrationService = makeSvc(
        [makeLb('lb-1')], null, false
      );
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.currentLorebookPreserved).assertTrue();
    });

    it('repo_insert_fail_no_marker', 0, async () => {
      const prefs: MockAppPreferences = new MockAppPreferences();
      const legacyStore: LorebookStore = {
        list: async (): Promise<Lorebook[]> => [makeLb('lb-1')],
        getCurrentLorebookId: async (): Promise<string | null> => null
      } as unknown as LorebookStore;
      const selectionStore: LorebookSelectionStore = {
        setCurrentLorebookId: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const repo: LorebookRepository = {
        insertManyIfMissing: async (): Promise<LorebookImportResult> => {
          throw new Error('insert failed');
        }
      } as unknown as LorebookRepository;
      const svc: LorebookMigrationService = new LorebookMigrationService(
        legacyStore, repo, selectionStore, prefs
      );
      let caught: boolean = false;
      try {
        await svc.migrateIfNeeded();
      } catch (e) {
        caught = true;
      }
      expect(caught).assertTrue();
      const marker: boolean = await prefs.getBoolean('lorebook_rdb_migration_v1_complete', false);
      expect(marker).assertFalse();
    });

    it('verify_fail_no_marker', 0, async () => {
      const prefs: MockAppPreferences = new MockAppPreferences();
      const legacyStore: LorebookStore = {
        list: async (): Promise<Lorebook[]> => [makeLb('lb-1')],
        getCurrentLorebookId: async (): Promise<string | null> => null
      } as unknown as LorebookStore;
      const selectionStore: LorebookSelectionStore = {
        setCurrentLorebookId: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const repo: LorebookRepository = {
        insertManyIfMissing: async (): Promise<LorebookImportResult> => ({
          insertedLorebookCount: 1, insertedEntryCount: 0,
          skippedExistingLorebookCount: 0, totalLorebookCount: 1, totalEntryCount: 0
        }),
        getById: async (): Promise<Lorebook | null> => null
      } as unknown as LorebookRepository;
      const svc: LorebookMigrationService = new LorebookMigrationService(
        legacyStore, repo, selectionStore, prefs
      );
      let caught: boolean = false;
      try {
        await svc.migrateIfNeeded();
      } catch (e) {
        caught = true;
      }
      expect(caught).assertTrue();
      const marker: boolean = await prefs.getBoolean('lorebook_rdb_migration_v1_complete', false);
      expect(marker).assertFalse();
    });

    it('retry_after_interrupt', 0, async () => {
      const prefs: MockAppPreferences = new MockAppPreferences();
      const legacyStore: LorebookStore = {
        list: async (): Promise<Lorebook[]> => [makeLb('lb-1')],
        getCurrentLorebookId: async (): Promise<string | null> => null
      } as unknown as LorebookStore;
      const selectionStore: LorebookSelectionStore = {
        setCurrentLorebookId: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      let callCount: number = 0;
      const repo: LorebookRepository = {
        insertManyIfMissing: async (): Promise<LorebookImportResult> => {
          callCount++;
          if (callCount === 1) {
            throw new Error('first fail');
          }
          return {
            insertedLorebookCount: 1, insertedEntryCount: 0,
            skippedExistingLorebookCount: 0, totalLorebookCount: 1, totalEntryCount: 0
          };
        },
        getById: async (): Promise<Lorebook | null> => makeLb('lb-1'),
        exists: async (): Promise<boolean> => true
      } as unknown as LorebookRepository;
      const svc: LorebookMigrationService = new LorebookMigrationService(
        legacyStore, repo, selectionStore, prefs
      );
      // 第一次失败
      let caught: boolean = false;
      try {
        await svc.migrateIfNeeded();
      } catch (e) {
        caught = true;
      }
      expect(caught).assertTrue();
      // 第二次成功
      const result: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(result.completed).assertTrue();
    });

    it('repeat_no_duplicate', 0, async () => {
      const svc: LorebookMigrationService = makeSvc(
        [makeLb('lb-1')], null, false
      );
      const r1: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(r1.completed).assertTrue();
      const r2: LorebookMigrationResult = await svc.migrateIfNeeded();
      expect(r2.attempted).assertFalse();
    });
  });
}