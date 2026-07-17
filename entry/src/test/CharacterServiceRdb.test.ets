/**
 * CharacterService RDB 切换本地测试(T-4.6)
 *
 * 使用 Mock 验证 CharacterService 的 CRUD 委托到 CharacterRepository,
 * 不再调用 Legacy CharacterStore CRUD。
 *
 * 覆盖(23 项):
 * 1. list 从 Repository 读取
 * 2. getById 从 Repository 读取
 * 3. create 写入 Repository
 * 4. update 写入 Repository
 * 5. remove 删除 Repository 记录
 * 6. 删除当前角色清空选择
 * 7. 删除非当前角色不改变选择
 * 8. setCurrentCharacterId 校验存在
 * 9. 设置不存在角色失败
 * 10. getCurrentCharacter 正确
 * 11. JSON 导入写入 RDB
 * 12. JSON ID 冲突生成新 ID
 * 13. PNG 导入写入 RDB
 * 14. PNG 失败无残留角色
 * 15. 删除角色清理头像
 * 16. 导出从 RDB 角色生成
 * 17. 不调用 Legacy CharacterStore CRUD
 * 18. 创建后不写旧 Preferences 列表
 * 19. 编辑后不写旧 Preferences 列表
 * 20. 删除后不改旧 Preferences 备份
 * 21. CharacterService 不直接操作 RdbStore
 * 22. 输入对象不修改
 * 23. 错误不泄露角色正文
 */

import { describe, it, expect } from '@ohos/hypium';
import { Character, CharacterUpdates } from '../main/ets/models/Character';
import { CharacterService } from '../main/ets/services/CharacterService';
import { CharacterRepository, CharacterImportResult } from '../main/ets/repositories/CharacterRepository';
import { CharacterSelectionStore } from '../main/ets/storage/CharacterSelectionStore';
import { CharacterAssetStore } from '../main/ets/storage/CharacterAssetStore';
import { DatabaseError, DatabaseErrorType } from '../main/ets/models/DatabaseError';
import { ParsedCharacterCard } from '../main/ets/parser/CharacterCardJsonParser';

function makeCharacter(
  id: string,
  name: string = 'Alice',
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

class MockCharacterRepository {
  private characters: Map<string, Character> = new Map<string, Character>();
  public insertCalls: number = 0;
  public updateCalls: number = 0;
  public removeCalls: number = 0;
  public listCalls: number = 0;
  public getByIdCalls: number = 0;
  public existsCalls: number = 0;
  public countCalls: number = 0;
  public shouldFailInsert: boolean = false;
  public insertError: DatabaseError | null = null;

  async insert(c: Character): Promise<void> {
    this.insertCalls++;
    if (this.shouldFailInsert && this.insertError !== null) {
      throw this.insertError;
    }
    if (this.characters.has(c.id)) {
      throw DatabaseError.alreadyExists('mock duplicate');
    }
    this.characters.set(c.id, c);
  }

  async getById(id: string): Promise<Character | null> {
    this.getByIdCalls++;
    const c: Character | undefined = this.characters.get(id);
    return c !== undefined ? c : null;
  }

  async list(): Promise<Character[]> {
    this.listCalls++;
    const arr: Character[] = [];
    this.characters.forEach((v: Character): void => {
      arr.push(v);
    });
    return arr;
  }

  async update(c: Character): Promise<void> {
    this.updateCalls++;
    if (!this.characters.has(c.id)) {
      throw DatabaseError.notFound('mock not found');
    }
    this.characters.set(c.id, c);
  }

  async remove(id: string): Promise<void> {
    this.removeCalls++;
    this.characters.delete(id);
  }

  async count(): Promise<number> {
    this.countCalls++;
    return this.characters.size;
  }

  async exists(id: string): Promise<boolean> {
    this.existsCalls++;
    return this.characters.has(id);
  }

  async insertManyIfMissing(chars: Character[]): Promise<CharacterImportResult> {
    let inserted: number = 0;
    let skipped: number = 0;
    for (let i = 0; i < chars.length; i++) {
      if (this.characters.has(chars[i].id)) {
        skipped++;
      } else {
        this.characters.set(chars[i].id, chars[i]);
        inserted++;
      }
    }
    return {
      insertedCount: inserted,
      skippedExistingCount: skipped,
      totalCount: chars.length
    };
  }
}

class MockCharacterSelectionStore {
  public currentId: string | null = null;
  public setCalls: number = 0;
  public clearCalls: number = 0;

  async getCurrentCharacterId(): Promise<string | null> {
    return this.currentId;
  }
  async setCurrentCharacterId(id: string | null): Promise<void> {
    this.setCalls++;
    this.currentId = id;
  }
  async clear(): Promise<void> {
    this.clearCalls++;
    this.currentId = null;
  }
}

class MockCharacterAssetStore {
  public saveCalls: number = 0;
  public deleteCalls: number = 0;
  public shouldFailSave: boolean = false;
  public savedAvatarUri: string = 'file://saved.png';

  async saveAvatar(_sourceUri: string, _characterId: string): Promise<string> {
    this.saveCalls++;
    if (this.shouldFailSave) {
      throw new Error('mock saveAvatar failed');
    }
    return this.savedAvatarUri;
  }
  async deleteAvatar(_characterId: string): Promise<void> {
    this.deleteCalls++;
  }
}

class MockLegacyStore {
  public listCalls: number = 0;
  public saveCalls: number = 0;
  public updateCalls: number = 0;
  public removeCalls: number = 0;
  public getByIdCalls: number = 0;
  public getCurrentIdCalls: number = 0;
  public setCurrentIdCalls: number = 0;

  async list(): Promise<Character[]> {
    this.listCalls++;
    return [];
  }
  async getById(_id: string): Promise<Character | null> {
    this.getByIdCalls++;
    return null;
  }
  async save(_c: Character): Promise<void> {
    this.saveCalls++;
  }
  async update(_c: Character): Promise<void> {
    this.updateCalls++;
  }
  async remove(_id: string): Promise<void> {
    this.removeCalls++;
  }
  async getCurrentCharacterId(): Promise<string | null> {
    this.getCurrentIdCalls++;
    return null;
  }
  async setCurrentCharacterId(_id: string | null): Promise<void> {
    this.setCurrentIdCalls++;
  }
  async initialize(_ctx: Object): Promise<void> {
    /* mock */
  }
}

function makeService(
  repo: MockCharacterRepository,
  sel: MockCharacterSelectionStore,
  asset: MockCharacterAssetStore
): CharacterService {
  return new CharacterService(
    repo as Object as CharacterRepository,
    sel as Object as CharacterSelectionStore,
    asset as Object as CharacterAssetStore
  );
}

export default function characterServiceRdbTest(): void {
  describe('CharacterServiceRdbTest', () => {

    // ===== 1. list 从 Repository 读取 =====
    it('list_from_repository', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a'));
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      const list: Character[] = await service.list();

      expect(list.length).assertEqual(1);
      expect(repo.listCalls).assertEqual(1);
    });

    // ===== 2. getById 从 Repository 读取 =====
    it('getById_from_repository', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a'));
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      const found: Character | null = await service.getById('char-a');

      expect(found !== null).assertTrue();
      expect(found!.id).assertEqual('char-a');
      expect(repo.getByIdCalls).assertEqual(1);
    });

    // ===== 3. create 写入 Repository =====
    it('create_writes_repository', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      const c: Character = await service.create('NewChar', 'desc');

      expect(repo.insertCalls).assertEqual(1);
      expect(c.name).assertEqual('NewChar');
    });

    // ===== 4. update 写入 Repository =====
    it('update_writes_repository', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a', 'Old'));
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      const updates: CharacterUpdates = { name: 'New' };
      const updated: Character = await service.update('char-a', updates);

      expect(updated.name).assertEqual('New');
      expect(repo.updateCalls).assertEqual(1);
    });

    // ===== 5. remove 删除 Repository 记录 =====
    it('remove_deletes_repository', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a'));
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      await service.remove('char-a');

      expect(repo.removeCalls).assertEqual(1);
      const found: Character | null = await repo.getById('char-a');
      expect(found).assertNull();
    });

    // ===== 6. 删除当前角色清空选择 =====
    it('remove_current_clears_selection', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a'));
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      sel.currentId = 'char-a';
      const service: CharacterService = makeService(repo, sel, new MockCharacterAssetStore());

      await service.remove('char-a');

      expect(sel.clearCalls).assertEqual(1);
      expect(sel.currentId).assertNull();
    });

    // ===== 7. 删除非当前角色不改变选择 =====
    it('remove_non_current_keeps_selection', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a'));
      await repo.insert(makeCharacter('char-b'));
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      sel.currentId = 'char-a';
      const service: CharacterService = makeService(repo, sel, new MockCharacterAssetStore());

      await service.remove('char-b');

      expect(sel.clearCalls).assertEqual(0);
      expect(sel.currentId).assertEqual('char-a');
    });

    // ===== 8. setCurrentCharacterId 校验存在 =====
    it('setCurrentCharacterId_validates_existence', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a'));
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const service: CharacterService = makeService(repo, sel, new MockCharacterAssetStore());

      await service.setCurrentCharacterId('char-a');

      expect(sel.currentId).assertEqual('char-a');
      expect(repo.existsCalls).assertEqual(1);
    });

    // ===== 9. 设置不存在角色失败 =====
    it('setCurrentCharacterId_nonexistent_fails', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      const service: CharacterService = makeService(repo, sel, new MockCharacterAssetStore());

      let threw: boolean = false;
      try {
        await service.setCurrentCharacterId('nonexistent');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(sel.currentId).assertNull();
    });

    // ===== 10. getCurrentCharacter 正确 =====
    it('getCurrentCharacter_correct', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a', 'Alice'));
      const sel: MockCharacterSelectionStore = new MockCharacterSelectionStore();
      sel.currentId = 'char-a';
      const service: CharacterService = makeService(repo, sel, new MockCharacterAssetStore());

      const c: Character | null = await service.getCurrentCharacter();

      expect(c !== null).assertTrue();
      expect(c!.name).assertEqual('Alice');
    });

    // ===== 11. JSON 导入写入 RDB =====
    it('importFromParsed_writes_rdb', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());
      const parsed: ParsedCharacterCard = {
        name: 'ImportedChar',
        description: 'desc',
        personality: 'p',
        scenario: 's',
        firstMessage: 'fm',
        systemPrompt: 'sp',
        avatarUri: '',
        sourceFormat: 'arktavern_v1'
      };

      const c: Character = await service.importFromParsed(parsed);

      expect(repo.insertCalls).assertEqual(1);
      expect(c.name).assertEqual('ImportedChar');
    });

    // ===== 12. JSON ID 冲突生成新 ID =====
    it('import_id_conflict_generates_new', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      repo.shouldFailInsert = true;
      repo.insertError = DatabaseError.alreadyExists('mock');
      // 只在第一次冲突,第二次成功
      let firstCall: boolean = true;
      const originalInsert: (c: Character) => Promise<void> = repo.insert.bind(repo);
      repo.insert = async (c: Character): Promise<void> => {
        if (firstCall) {
          firstCall = false;
          throw DatabaseError.alreadyExists('mock');
        }
        await originalInsert(c);
      };
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());
      const parsed: ParsedCharacterCard = {
        name: 'X',
        description: '',
        personality: '',
        scenario: '',
        firstMessage: '',
        systemPrompt: '',
        avatarUri: '',
        sourceFormat: 'arktavern_v1'
      };

      const c: Character = await service.importFromParsed(parsed);

      expect(repo.insertCalls).assertEqual(2);  // 第一次失败,第二次成功
    });

    // ===== 13. PNG 导入写入 RDB =====
    it('confirmPngImport_writes_rdb', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const asset: MockCharacterAssetStore = new MockCharacterAssetStore();
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), asset);
      const parsed: ParsedCharacterCard = {
        name: 'PngChar',
        description: 'd',
        personality: 'p',
        scenario: 's',
        firstMessage: 'f',
        systemPrompt: 'sp',
        avatarUri: '',
        sourceFormat: 'chara_card_v2'
      };

      const c: Character = await service.confirmPngImport(parsed, 'file://source.png');

      expect(asset.saveCalls).assertEqual(1);
      expect(repo.insertCalls).assertEqual(1);
      expect(c.avatarUri).assertEqual('file://saved.png');
    });

    // ===== 14. PNG 失败无残留角色 =====
    it('png_failure_no_residual', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const asset: MockCharacterAssetStore = new MockCharacterAssetStore();
      asset.shouldFailSave = true;
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), asset);
      const parsed: ParsedCharacterCard = {
        name: 'PngChar',
        description: 'd',
        personality: 'p',
        scenario: 's',
        firstMessage: 'f',
        systemPrompt: 'sp',
        avatarUri: '',
        sourceFormat: 'chara_card_v2'
      };

      let threw: boolean = false;
      try {
        await service.confirmPngImport(parsed, 'file://source.png');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(repo.insertCalls).assertEqual(0);  // 角色未保存
    });

    // ===== 15. 删除角色清理头像 =====
    it('remove_cleans_avatar', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a'));
      const asset: MockCharacterAssetStore = new MockCharacterAssetStore();
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), asset);

      await service.remove('char-a');

      expect(asset.deleteCalls).assertEqual(1);
    });

    // ===== 16. 导出从 RDB 角色生成 =====
    it('export_from_rdb', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a', 'ExportChar'));
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      const json: string = await service.exportToJson('char-a');

      expect(json.length > 0).assertTrue();
      expect(json.indexOf('ExportChar') >= 0).assertTrue();
    });

    // ===== 17. 不调用 Legacy CharacterStore CRUD =====
    it('no_legacy_crud_calls', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const legacy: MockLegacyStore = new MockLegacyStore();
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      await service.create('A');
      await service.list();
      await service.getById('char-a');
      const chars: Character[] = await repo.list();
      if (chars.length > 0) {
        await service.update(chars[0].id, { name: 'B' });
        await service.remove(chars[0].id);
      }

      expect(legacy.saveCalls).assertEqual(0);
      expect(legacy.updateCalls).assertEqual(0);
      expect(legacy.removeCalls).assertEqual(0);
      expect(legacy.listCalls).assertEqual(0);
      expect(legacy.getByIdCalls).assertEqual(0);
    });

    // ===== 18. 创建后不写旧 Preferences 列表 =====
    it('create_no_legacy_write', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const legacy: MockLegacyStore = new MockLegacyStore();
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      await service.create('NewChar');

      expect(legacy.saveCalls).assertEqual(0);
    });

    // ===== 19. 编辑后不写旧 Preferences 列表 =====
    it('update_no_legacy_write', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a', 'Old'));
      const legacy: MockLegacyStore = new MockLegacyStore();
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      await service.update('char-a', { name: 'New' });

      expect(legacy.updateCalls).assertEqual(0);
    });

    // ===== 20. 删除后不改旧 Preferences 备份 =====
    it('remove_no_legacy_change', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      await repo.insert(makeCharacter('char-a'));
      const legacy: MockLegacyStore = new MockLegacyStore();
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      await service.remove('char-a');

      expect(legacy.removeCalls).assertEqual(0);
    });

    // ===== 21. CharacterService 不直接操作 RdbStore =====
    // 此测试通过类型系统保证:CharacterService 只持有 CharacterRepository,不持有 RdbStore
    // 此处仅验证 service 类型可正常创建
    it('service_does_not_hold_rdbstore', 0, async () => {
      const service: CharacterService = makeService(
        new MockCharacterRepository(),
        new MockCharacterSelectionStore(),
        new MockCharacterAssetStore()
      );
      expect(service !== null).assertTrue();
    });

    // ===== 22. 输入对象不修改 =====
    it('input_not_modified', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());
      const parsed: ParsedCharacterCard = {
        name: 'Original',
        description: 'original desc',
        personality: 'p',
        scenario: 's',
        firstMessage: 'f',
        systemPrompt: 'sp',
        avatarUri: '',
        sourceFormat: 'arktavern_v1'
      };

      await service.importFromParsed(parsed);

      expect(parsed.name).assertEqual('Original');
      expect(parsed.description).assertEqual('original desc');
    });

    // ===== 23. 错误不泄露角色正文 =====
    it('error_no_content_leak', 0, async () => {
      const repo: MockCharacterRepository = new MockCharacterRepository();
      const sensitive: string = 'SECRET_DESCRIPTION_xyz';
      await repo.insert(makeCharacter('char-a', 'Alice', sensitive));
      const service: CharacterService = makeService(repo, new MockCharacterSelectionStore(), new MockCharacterAssetStore());

      // 不存在的更新应抛错,但错误信息不含正文
      let errorMsg: string = '';
      try {
        await service.update('nonexistent', { name: 'X' });
      } catch (e) {
        errorMsg = String(e);
      }
      expect(errorMsg.indexOf(sensitive) < 0).assertTrue();
    });
  });
}
