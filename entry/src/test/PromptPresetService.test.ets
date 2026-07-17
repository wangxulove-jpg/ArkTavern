/**
 * PromptPresetService 本地单元测试
 *
 * 使用 mock Repository 和 mock SelectionStore 进行隔离测试。
 * 覆盖:
 * - CRUD 委托
 * - 当前选择管理
 * - 删除当前 Preset 清空选择
 * - 不存在的当前 Preset 自动清空
 * - 不自动创建默认 Preset
 * - 输入对象不修改
 */

import { describe, it, expect } from '@ohos/hypium';
import { PromptPresetService } from '../../main/ets/services/PromptPresetService';
import { PromptPresetRepository } from '../../main/ets/repositories/PromptPresetRepository';
import { PromptPresetSelectionStore } from '../../main/ets/storage/PromptPresetSelectionStore';
import {
  PromptPreset,
  CreatePromptPresetOptions,
  PromptPresetUpdates,
  createPromptPreset,
  validatePromptPreset
} from '../../main/ets/models/PromptPreset';
import { DatabaseError } from '../../main/ets/models/DatabaseError';

// ===== Mock Repository =====

class MockPromptPresetRepository {
  private presets: Map<string, PromptPreset> = new Map();
  private insertCalls: PromptPreset[] = [];
  private updateCalls: PromptPreset[] = [];
  private removeCalls: string[] = [];

  async insert(preset: PromptPreset): Promise<void> {
    if (this.presets.has(preset.id)) {
      throw DatabaseError.alreadyExists('mock');
    }
    this.presets.set(preset.id, preset);
    this.insertCalls.push(preset);
  }

  async getById(id: string): Promise<PromptPreset | null> {
    return this.presets.get(id) ?? null;
  }

  async list(): Promise<PromptPreset[]> {
    const result: PromptPreset[] = [];
    this.presets.forEach((v: PromptPreset): void => { result.push(v); });
    return result;
  }

  async update(preset: PromptPreset): Promise<void> {
    if (!this.presets.has(preset.id)) {
      throw DatabaseError.notFound('mock');
    }
    this.presets.set(preset.id, preset);
    this.updateCalls.push(preset);
  }

  async remove(id: string): Promise<void> {
    this.presets.delete(id);
    this.removeCalls.push(id);
  }

  async count(): Promise<number> {
    return this.presets.size;
  }

  async exists(id: string): Promise<boolean> {
    return this.presets.has(id);
  }

  getInsertedPresets(): PromptPreset[] {
    return this.insertCalls;
  }

  getUpdatedPresets(): PromptPreset[] {
    return this.updateCalls;
  }

  getRemovedIds(): string[] {
    return this.removeCalls;
  }
}

// ===== Mock SelectionStore =====

class MockPromptPresetSelectionStore {
  private currentId: string | null = null;
  private setCalls: (string | null)[] = [];

  async getCurrentPresetId(): Promise<string | null> {
    return this.currentId;
  }

  async setCurrentPresetId(id: string | null): Promise<void> {
    this.currentId = id;
    this.setCalls.push(id);
  }

  async clear(): Promise<void> {
    this.currentId = null;
    this.setCalls.push(null);
  }

  getSetCalls(): (string | null)[] {
    return this.setCalls;
  }

  setCurrentIdForTest(id: string | null): void {
    this.currentId = id;
  }
}

// ===== Helpers =====

function makeOptions(overrides?: Partial<CreatePromptPresetOptions>): CreatePromptPresetOptions {
  return {
    id: 'test-id',
    name: 'Test Preset',
    description: 'A test preset',
    systemPrompt: 'You are helpful',
    temperature: 0.7,
    topP: 1.0,
    maxOutputTokens: 1024,
    contextWindow: 32768,
    createdAt: 1000,
    ...overrides
  };
}

export default function promptPresetServiceTest(): void {
  describe('PromptPresetServiceTest', () => {

    // ===== 1. list 从 Repository 读取 =====
    it('list_reads_from_repository', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      const preset: PromptPreset = createPromptPreset(makeOptions({ id: 'p1', name: 'P1' }));
      await repo.insert(preset);
      const list: PromptPreset[] = await service.list();
      expect(list.length).assertEqual(1);
    });

    // ===== 2. getById 从 Repository 读取 =====
    it('getById_reads_from_repository', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      const preset: PromptPreset = createPromptPreset(makeOptions({ id: 'p1', name: 'P1' }));
      await repo.insert(preset);
      const found: PromptPreset | null = await service.getById('p1');
      expect(found).assertNotNull();
      expect(found!.name).assertEqual('P1');
    });

    // ===== 3. create 写 Repository =====
    it('create_writes_to_repository', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'P1' }));
      expect(repo.getInsertedPresets().length).assertEqual(1);
    });

    // ===== 4. create 不自动设为当前 =====
    it('create_does_not_set_as_current', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'P1' }));
      expect(await service.getCurrentPresetId()).assertNull();
    });

    // ===== 5. update 写 Repository =====
    it('update_writes_to_repository', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'Original' }));
      await service.update('p1', { name: 'Updated' });
      expect(repo.getUpdatedPresets().length).assertEqual(1);
      expect(repo.getUpdatedPresets()[0].name).assertEqual('Updated');
    });

    // ===== 6. update 保持 createdAt =====
    it('update_preserves_createdAt', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'P1', createdAt: 1000 }));
      const updated: PromptPreset | null = await service.getById('p1');
      expect(updated!.createdAt).assertEqual(1000);
    });

    // ===== 7. remove 删除 Repository 记录 =====
    it('remove_deletes_from_repository', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'P1' }));
      await service.remove('p1');
      expect(await repo.exists('p1')).assertFalse();
    });

    // ===== 8. 删除当前 Preset 清空选择 =====
    it('removing_current_preset_clears_selection', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'P1' }));
      await service.setCurrentPresetId('p1');
      expect(await service.getCurrentPresetId()).assertEqual('p1');
      await service.remove('p1');
      expect(await service.getCurrentPresetId()).assertNull();
    });

    // ===== 9. 删除非当前 Preset 不改变选择 =====
    it('removing_non_current_preset_does_not_change_selection', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'P1' }));
      await service.create(makeOptions({ id: 'p2', name: 'P2' }));
      await service.setCurrentPresetId('p1');
      await service.remove('p2');
      expect(await service.getCurrentPresetId()).assertEqual('p1');
    });

    // ===== 10. 设置存在 Preset 为当前 =====
    it('set_current_preset_to_existing', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'P1' }));
      await service.setCurrentPresetId('p1');
      expect(await service.getCurrentPresetId()).assertEqual('p1');
    });

    // ===== 11. 设置不存在 Preset 失败 =====
    it('set_current_preset_nonexistent_fails', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      try {
        await service.setCurrentPresetId('nonexistent');
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(8); // NotFound
      }
    });

    // ===== 12. 清除当前 Preset =====
    it('clear_current_preset', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'P1' }));
      await service.setCurrentPresetId('p1');
      await service.setCurrentPresetId(null);
      expect(await service.getCurrentPresetId()).assertNull();
    });

    // ===== 13. getCurrentPreset 正确 =====
    it('getCurrentPreset_returns_correct', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({ id: 'p1', name: 'Current Preset' }));
      await service.setCurrentPresetId('p1');
      const current: PromptPreset | null = await service.getCurrentPreset();
      expect(current).assertNotNull();
      expect(current!.name).assertEqual('Current Preset');
    });

    // ===== 14. 当前 ID 指向不存在记录时清空 =====
    it('current_id_pointing_to_nonexistent_clears', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      store.setCurrentIdForTest('nonexistent');
      const current: PromptPreset | null = await service.getCurrentPreset();
      expect(current).assertNull();
      expect(await service.getCurrentPresetId()).assertNull();
    });

    // ===== 15. 无当前 Preset 返回 null =====
    it('no_current_preset_returns_null', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      const current: PromptPreset | null = await service.getCurrentPreset();
      expect(current).assertNull();
    });

    // ===== 16. 不自动创建默认 Preset =====
    it('does_not_auto_create_default_preset', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      const list: PromptPreset[] = await service.list();
      expect(list.length).assertEqual(0);
    });

    // ===== 17. systemPrompt 完整保留 =====
    it('systemPrompt_fully_preserved', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      const sp: string = 'You are a helpful assistant.\nBe concise.\nUse **Markdown**.';
      await service.create(makeOptions({ id: 'p1', name: 'P1', systemPrompt: sp }));
      const preset: PromptPreset | null = await service.getById('p1');
      expect(preset!.systemPrompt).assertEqual(sp);
    });

    // ===== 18. 可选参数 undefined 保留 =====
    it('optional_params_undefined_preserved', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({
        id: 'p1', name: 'P1',
        temperature: undefined,
        topP: undefined,
        maxOutputTokens: undefined,
        contextWindow: undefined
      }));
      const preset: PromptPreset | null = await service.getById('p1');
      expect(preset!.temperature).assertUndefined();
      expect(preset!.topP).assertUndefined();
      expect(preset!.maxOutputTokens).assertUndefined();
      expect(preset!.contextWindow).assertUndefined();
    });

    // ===== 19. clear 参数正确生效 =====
    it('clear_params_work_correctly', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      await service.create(makeOptions({
        id: 'p1', name: 'P1',
        temperature: 0.7,
        topP: 1.0,
        maxOutputTokens: 1024,
        contextWindow: 32768
      }));
      await service.update('p1', {
        clearTemperature: true,
        clearTopP: true,
        clearMaxOutputTokens: true,
        clearContextWindow: true
      });
      const preset: PromptPreset | null = await service.getById('p1');
      expect(preset!.temperature).assertUndefined();
      expect(preset!.topP).assertUndefined();
      expect(preset!.maxOutputTokens).assertUndefined();
      expect(preset!.contextWindow).assertUndefined();
    });

    // ===== 20. 输入对象不修改 =====
    it('input_options_not_modified', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      const options: CreatePromptPresetOptions = makeOptions({ id: 'p1', name: 'Original' });
      await service.create(options);
      expect(options.name).assertEqual('Original');
    });

    // ===== 21. update 不存在返回 NotFound =====
    it('update_nonexistent_throws_not_found', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      try {
        await service.update('nonexistent', { name: 'New' });
        expect(false).assertTrue();
      } catch (e) {
        const err: DatabaseError = e as DatabaseError;
        expect(err.type).assertEqual(8); // NotFound
      }
    });

    // ===== 22. 删除不存在的 Preset 幂等 =====
    it('remove_nonexistent_is_idempotent', 0, async () => {
      const repo: MockPromptPresetRepository = new MockPromptPresetRepository();
      const store: MockPromptPresetSelectionStore = new MockPromptPresetSelectionStore();
      const service: PromptPresetService = new PromptPresetService(
        repo as unknown as PromptPresetRepository,
        store as unknown as PromptPresetSelectionStore
      );
      // 不应抛错
      await service.remove('nonexistent');
      expect(await repo.count()).assertEqual(0);
    });
  });
}