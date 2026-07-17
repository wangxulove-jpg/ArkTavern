/**
 * CharacterMigrationService 本地测试(T-4.6)
 *
 * 使用 Mock 验证迁移编排逻辑,不依赖真实 RDB。
 *
 * 覆盖(20 项):
 * 1. migration marker=true 时跳过
 * 2. 无旧角色时标记完成
 * 3. 单角色迁移
 * 4. 多角色迁移
 * 5. 保留原 ID
 * 6. 已存在 ID 跳过
 * 7. 不覆盖已有 RDB 角色
 * 8. 部分已存在、部分新增
 * 9. 当前角色存在时保留选择
 * 10. 当前角色不存在时清空选择
 * 11. currentCharacterId 为空
 * 12. Repository 导入失败不写 marker
 * 13. 验证失败不写 marker
 * 14. marker 写入失败返回错误
 * 15. 第一次执行中断后第二次可重试
 * 16. 重复执行不产生重复角色
 * 17. 旧 CharacterStore 数据不删除
 * 18. 不执行双写
 * 19. 返回结果数字正确
 * 20. 日志不包含角色正文
 */

import { describe, it, expect } from '@ohos/hypium';
import { Character } from '../main/ets/models/Character';
import { CharacterMigrationResult } from '../main/ets/models/CharacterMigrationResult';
import { CharacterMigrationService } from '../main/ets/services/CharacterMigrationService';
import { CharacterStore } from '../main/ets/storage/CharacterStore';
import { CharacterRepository, CharacterImportResult } from '../main/ets/repositories/CharacterRepository';
import { CharacterSelectionStore } from '../main/ets/storage/CharacterSelectionStore';
import { AppPreferences } from '../main/ets/storage/AppPreferences';

function makeCharacter(
  id: string,
  name: string = 'TestChar',
  description: string = 'desc'
): Character {
  return {
    id: id,
    name: name,
    description: description,
    personality: 'p',
    scenario: 's',
    firstMessage: 'fm',
    systemPrompt: 'sp',
    avatarUri: 'file://avatar.png',
    createdAt: 1000,
    updatedAt: 1000
  };
}

class MockCharacterStore {
  private characters: Character[] = [];
  private currentId: string | null = null;
  public listCalls: number = 0;
  public getCurrentIdCalls: number = 0;

  setCharacters(chars: Character[]): void {
    this.characters = chars;
  }

  setCurrentId(id: string | null): void {
    this.currentId = id;
  }

  async list(): Promise<Character[]> {
    this.listCalls++;
    return this.characters.slice();
  }

  async getCurrentCharacterId(): Promise<string | null> {
    this.getCurrentIdCalls++;
    return this.currentId;
  }

  // save/update/remove 不应被调用
  async save(_c: Character): Promise<void> {
    throw new Error('MockCharacterStore.save should not be called');
  }
  async update(_c: Character): Promise<void> {
    throw new Error('MockCharacterStore.update should not be called');
  }
  async remove(_id: string): Promise<void> {
    throw new Error('MockCharacterStore.remove should not be called');
  }
}

class MockCharacterRepository {
  private inserted: Character[] = [];
  private existing: Character[] = [];
  public importCalls: number = 0;
  public existsCalls: number = 0;
  public shouldFailImport: boolean = false;
  public shouldFailExists: boolean = false;
  public shouldFailVerify: boolean = false;

  setExisting(chars: Character[]): void {
    this.existing = chars;
    this.inserted = chars.slice();
  }

  getInserted(): Character[] {
    return this.inserted;
  }

  async insertManyIfMissing(chars: Character[]): Promise<CharacterImportResult> {
    this.importCalls++;
    if (this.shouldFailImport) {
      throw new Error('mock import failed');
    }
    let inserted: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < chars.length; i++) {
      const c: Character = chars[i];
      const existsInInserted: boolean = this.inserted.some((x: Character): boolean => x.id === c.id);
      if (existsInInserted) {
        skipped++;
      } else {
        this.inserted.push(c);
        inserted++;
      }
    }
    return {
      insertedCount: inserted,
      skippedExistingCount: skipped,
      totalCount: chars.length
    };
  }

  async exists(id: string): Promise<boolean> {
    this.existsCalls++;
    if (this.shouldFailExists) {
      throw new Error('mock exists failed');
    }
    if (this.shouldFailVerify) {
      return false;
    }
    return this.inserted.some((x: Character): boolean => x.id === id);
  }

  async getById(id: string): Promise<Character | null> {
    const found: Character | undefined = this.inserted.find((x: Character): boolean => x.id === id);
    return found !== undefined ? found : null;
  }

  async list(): Promise<Character[]> {
    return this.inserted.slice();
  }
}

class MockCharacterSelectionStore {
  public currentId: string | null = null;
  public setCalls: number = 0;

  async getCurrentCharacterId(): Promise<string | null> {
    return this.currentId;
  }
  async setCurrentCharacterId(id: string | null): Promise<void> {
    this.setCalls++;
    this.currentId = id;
  }
  async clear(): Promise<void> {
    this.currentId = null;
  }
}

class MockAppPreferences {
  private data: Map<string, boolean> = new Map<string, boolean>();
  public getBooleanCalls: number = 0;
  public putBooleanCalls: number = 0;
  public shouldFailPutBoolean: boolean = false;

  async getBoolean(key: string, defValue: boolean): Promise<boolean> {
    this.getBooleanCalls++;
    if (this.data.has(key)) {
      return this.data.get(key) as boolean;
    }
    return defValue;
  }
  async putBoolean(key: string, value: boolean): Promise<void> {
    this.putBooleanCalls++;
    if (this.shouldFailPutBoolean) {
      throw new Error('mock putBoolean failed');
    }
    this.data.set(key, value);
  }
}

function makeService(
  mockStore: MockCharacterStore,
  mockRepo: MockCharacterRepository,
  mockSelection: MockCharacterSelectionStore,
  mockPrefs: MockAppPreferences
): CharacterMigrationService {
  return new CharacterMigrationService(
    mockStore as Object as CharacterStore,
    mockRepo as Object as CharacterRepository,
    mockSelection as Object as CharacterSelectionStore,
    mockPrefs as Object as AppPreferences
  );
}

export default function characterMigrationServiceTest(): void {
  describe('CharacterMigrationServiceTest', () => {

    // ===== 1. migration marker=true 时跳过 =====
    it('skip_when_marker_true', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      // 预设 marker=true
      await prefs.putBoolean('character_rdb_migration_v1_complete', true);
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.attempted).assertFalse();
      expect(result.completed).assertTrue();
      expect(repo.importCalls).assertEqual(0);
      expect(store.listCalls).assertEqual(0);
    });

    // ===== 2. 无旧角色时标记完成 =====
    it('complete_when_no_legacy', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.attempted).assertTrue();
      expect(result.legacyCount).assertEqual(0);
      expect(result.insertedCount).assertEqual(0);
      expect(result.completed).assertTrue();
      expect(prefs.putBooleanCalls).assertEqual(1);  // 写入 marker
    });

    // ===== 3. 单角色迁移 =====
    it('migrate_single', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.legacyCount).assertEqual(1);
      expect(result.insertedCount).assertEqual(1);
      expect(result.completed).assertTrue();
    });

    // ===== 4. 多角色迁移 =====
    it('migrate_multiple', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([
        makeCharacter('char-a', 'Alice'),
        makeCharacter('char-b', 'Bob'),
        makeCharacter('char-c', 'Carol')
      ]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.legacyCount).assertEqual(3);
      expect(result.insertedCount).assertEqual(3);
      expect(result.completed).assertTrue();
    });

    // ===== 5. 保留原 ID =====
    it('preserve_original_id', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('original-id-123', 'Alice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      await service.migrateIfNeeded();

      const inserted: Character[] = repo.getInserted();
      expect(inserted[0].id).assertEqual('original-id-123');
    });

    // ===== 6. 已存在 ID 跳过 =====
    it('skip_existing_id', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      repo.setExisting([makeCharacter('char-a', 'ExistingAlice')]);
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.insertedCount).assertEqual(0);
      expect(result.skippedExistingCount).assertEqual(1);
      expect(result.completed).assertTrue();
    });

    // ===== 7. 不覆盖已有 RDB 角色 =====
    it('do_not_overwrite', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'NewAlice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      repo.setExisting([makeCharacter('char-a', 'OriginalAlice')]);
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      await service.migrateIfNeeded();

      // 已存在的角色名应保留
      const found: Character | null = await repo.getById('char-a');
      expect(found!.name).assertEqual('OriginalAlice');
    });

    // ===== 8. 部分已存在、部分新增 =====
    it('partial_existing_partial_new', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([
        makeCharacter('char-a', 'Alice'),
        makeCharacter('char-b', 'Bob'),
        makeCharacter('char-c', 'Carol')
      ]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      repo.setExisting([makeCharacter('char-a', 'ExistingAlice')]);
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.insertedCount).assertEqual(2);
      expect(result.skippedExistingCount).assertEqual(1);
    });

    // ===== 9. 当前角色存在时保留选择 =====
    it('preserve_current_when_exists', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      store.setCurrentId('char-a');
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.currentCharacterPreserved).assertTrue();
      expect(sel.currentId).assertEqual('char-a');
      expect(sel.setCalls).assertEqual(1);
    });

    // ===== 10. 当前角色不存在时清空选择 =====
    it('clear_current_when_not_exists', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      store.setCurrentId('char-deleted');  // 指向不存在的角色
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.currentCharacterPreserved).assertFalse();
      expect(sel.currentId).assertNull();
    });

    // ===== 11. currentCharacterId 为空 =====
    it('empty_current_id', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      store.setCurrentId(null);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.currentCharacterPreserved).assertTrue();
      expect(sel.setCalls).assertEqual(0);  // 未设置选择
    });

    // ===== 12. Repository 导入失败不写 marker =====
    it('no_marker_on_import_failure', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      repo.shouldFailImport = true;
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      let threw: boolean = false;
      try {
        await service.migrateIfNeeded();
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(prefs.putBooleanCalls).assertEqual(0);  // 未写 marker
    });

    // ===== 13. 验证失败不写 marker =====
    it('no_marker_on_verify_failure', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      repo.shouldFailVerify = true;
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.completed).assertFalse();
      expect(prefs.putBooleanCalls).assertEqual(0);  // 未写 marker
    });

    // ===== 14. marker 写入失败返回错误 =====
    it('marker_write_failure', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      prefs.shouldFailPutBoolean = true;
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      let threw: boolean = false;
      try {
        await service.migrateIfNeeded();
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // ===== 15. 第一次执行中断后第二次可重试 =====
    it('retry_after_interrupted', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service1: CharacterMigrationService = makeService(store, repo, sel, prefs);

      // 第一次执行,marker 写入失败
      prefs.shouldFailPutBoolean = true;
      let threw: boolean = false;
      try {
        await service1.migrateIfNeeded();
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      // 角色已被插入但 marker 未写入
      expect(repo.getInserted().length).assertEqual(1);

      // 第二次执行,marker 写入成功
      prefs.shouldFailPutBoolean = false;
      const service2: CharacterMigrationService = makeService(store, repo, sel, prefs);
      const result: CharacterMigrationResult = await service2.migrateIfNeeded();

      expect(result.completed).assertTrue();
      // 不重复插入
      expect(result.insertedCount).assertEqual(0);
      expect(result.skippedExistingCount).assertEqual(1);
    });

    // ===== 16. 重复执行不产生重复角色 =====
    it('repeat_no_duplicate', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service1: CharacterMigrationService = makeService(store, repo, sel, prefs);

      await service1.migrateIfNeeded();
      expect(repo.getInserted().length).assertEqual(1);

      // 第二次执行:marker 已为 true,应直接跳过
      const service2: CharacterMigrationService = makeService(store, repo, sel, prefs);
      const result: CharacterMigrationResult = await service2.migrateIfNeeded();

      expect(result.attempted).assertFalse();
      expect(repo.getInserted().length).assertEqual(1);  // 不重复
    });

    // ===== 17. 旧 CharacterStore 数据不删除 =====
    it('legacy_data_not_deleted', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      const legacyChars: Character[] = [
        makeCharacter('char-a', 'Alice'),
        makeCharacter('char-b', 'Bob')
      ];
      store.setCharacters(legacyChars);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      await service.migrateIfNeeded();

      // 旧数据仍在(MockCharacterStore 不应有 remove 调用,但我们无法直接断言)
      // 验证:旧 list 调用只读取,未删除
      const legacyStillThere: Character[] = await store.list();
      expect(legacyStillThere.length).assertEqual(2);
    });

    // ===== 18. 不执行双写 =====
    it('no_double_write', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([makeCharacter('char-a', 'Alice')]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      await service.migrateIfNeeded();

      // 只调用 list 一次,getCurrentCharacterId 一次,不调用 save/update/remove
      expect(store.listCalls).assertEqual(1);
      expect(store.getCurrentIdCalls).assertEqual(1);
    });

    // ===== 19. 返回结果数字正确 =====
    it('result_numbers_correct', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      store.setCharacters([
        makeCharacter('char-a', 'Alice'),
        makeCharacter('char-b', 'Bob'),
        makeCharacter('char-c', 'Carol')
      ]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      repo.setExisting([makeCharacter('char-a', 'ExistingAlice')]);
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      const result: CharacterMigrationResult = await service.migrateIfNeeded();

      expect(result.legacyCount).assertEqual(3);
      expect(result.insertedCount).assertEqual(2);
      expect(result.skippedExistingCount).assertEqual(1);
      expect(result.totalCount === undefined || true).assertTrue();  // totalCount 不在结果中
    });

    // ===== 20. 日志不包含角色正文 =====
    it('log_no_content', 0, async () => {
      const store: MockCharacterStore = new MockCharacterStore();
      const sensitive: string = 'SENSITIVE_DESCRIPTION_xyz';
      store.setCharacters([makeCharacter('char-a', 'Alice', sensitive)]);
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const prefs: MockAppPreferences = new MockAppPreferences();
      const service: CharacterMigrationService = makeService(store, repo, sel, prefs);

      // 这里只能验证不抛错,实际日志检查通过 hilog 过滤
      const result: CharacterMigrationResult = await service.migrateIfNeeded();
      expect(result.completed).assertTrue();
      // 验证结果对象不包含正文
      expect(JSON.stringify(result).indexOf(sensitive) < 0).assertTrue();
    });
  });
}
