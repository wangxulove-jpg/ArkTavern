/**
 * LorebookViewModel 单元测试 - onDataUpdate 回调模式
 *
 * 覆盖:
 * - onDataUpdate 在 load() 后触发
 * - onDataUpdate 在 setCurrentLorebook() 后触发
 * - onDataUpdate 同步 lorebooks 数组
 * - onDataUpdate 同步 currentLorebookId
 * - onDataUpdate 为 null 时不抛异常
 * - saveEntry → load 链触发 onDataUpdate
 * - deleteEntry → load 链触发 onDataUpdate
 * - deleteLorebook → load 链触发 onDataUpdate
 * - saveLorebook → load 链触发 onDataUpdate
 */

import {
  Lorebook,
  LorebookEntry,
  LorebookPosition,
  LorebookUpdates,
  LorebookEntryUpdates,
  createLorebook,
  createLorebookEntry,
  addEntryToLorebook,
  removeEntryFromLorebook,
  updateEntryInLorebook,
  updateLorebook
} from '../main/ets/models/Lorebook';
import { LorebookService } from '../main/ets/services/LorebookService';
import { LorebookViewModel } from '../main/ets/viewmodels/LorebookViewModel';
import { describe, it, expect } from '@ohos/hypium';

// ===== MockLorebookService (内存存储,不依赖 Preferences) =====

class MockLorebookService {
  private data: Map<string, Lorebook> = new Map();
  private currentId: string | null = null;

  async list(): Promise<Lorebook[]> {
    const result: Lorebook[] = [];
    const values: IterableIterator<Lorebook> = this.data.values();
    let next: IteratorResult<Lorebook> = values.next();
    while (!next.done) {
      result.push(next.value);
      next = values.next();
    }
    return result;
  }

  async getById(id: string): Promise<Lorebook | null> {
    return this.data.get(id) ?? null;
  }

  async create(name: string, description: string = ''): Promise<Lorebook> {
    const lb: Lorebook = createLorebook(name, description);
    this.data.set(lb.id, lb);
    return lb;
  }

  async update(id: string, updates: LorebookUpdates): Promise<Lorebook> {
    const existing: Lorebook | undefined = this.data.get(id);
    if (existing === undefined) {
      throw new Error('Not found: ' + id);
    }
    const updated: Lorebook = updateLorebook(existing, updates);
    this.data.set(id, updated);
    return updated;
  }

  async remove(id: string): Promise<void> {
    this.data.delete(id);
    if (this.currentId === id) {
      this.currentId = null;
    }
  }

  async setCurrentLorebookId(id: string | null): Promise<void> {
    if (id !== null && !this.data.has(id)) {
      throw new Error('Not found: ' + id);
    }
    this.currentId = id;
  }

  async getCurrentLorebookId(): Promise<string | null> {
    return this.currentId;
  }

  async getCurrentLorebook(): Promise<Lorebook | null> {
    if (this.currentId === null) {
      return null;
    }
    return this.data.get(this.currentId) ?? null;
  }

  async addEntry(
    id: string,
    name: string,
    keys: string[],
    secondaryKeys: string[],
    content: string,
    selective: boolean,
    secondary: boolean,
    constant: boolean,
    position: LorebookPosition,
    priority: number
  ): Promise<Lorebook> {
    const existing: Lorebook | undefined = this.data.get(id);
    if (existing === undefined) {
      throw new Error('Not found: ' + id);
    }
    const entry: LorebookEntry = createLorebookEntry(
      name, keys, secondaryKeys, content,
      selective, secondary, constant, position, priority
    );
    const updated: Lorebook = addEntryToLorebook(existing, entry);
    this.data.set(id, updated);
    return updated;
  }

  async updateEntry(
    lorebookId: string,
    entryId: string,
    updates: LorebookEntryUpdates
  ): Promise<Lorebook> {
    const existing: Lorebook | undefined = this.data.get(lorebookId);
    if (existing === undefined) {
      throw new Error('Not found: ' + lorebookId);
    }
    const updated: Lorebook = updateEntryInLorebook(existing, entryId, updates);
    this.data.set(lorebookId, updated);
    return updated;
  }

  async removeEntry(lorebookId: string, entryId: string): Promise<Lorebook> {
    const existing: Lorebook | undefined = this.data.get(lorebookId);
    if (existing === undefined) {
      throw new Error('Not found: ' + lorebookId);
    }
    const updated: Lorebook = removeEntryFromLorebook(existing, entryId);
    this.data.set(lorebookId, updated);
    return updated;
  }
}

// ===== 测试辅助函数 =====

interface TestFixture {
  mock: MockLorebookService;
  vm: LorebookViewModel;
}

function createFixture(): TestFixture {
  const mock: MockLorebookService = new MockLorebookService();
  const vm: LorebookViewModel = new LorebookViewModel(mock as Object as LorebookService);
  return { mock: mock, vm: vm };
}

export default function lorebookViewModelTest() {
  describe('LorebookViewModel_onDataUpdate', () => {

    it('onDataUpdate_called_after_load', 0, async () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      await vm.load();
      expect(callCount).assertEqual(1);
    });

    it('onDataUpdate_syncs_lorebooks_array', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      await mock.create('测试', '');

      let syncedLorebooks: Lorebook[] = [];
      vm.onDataUpdate = () => {
        syncedLorebooks = [...vm.lorebooks];
      };

      await vm.load();
      expect(syncedLorebooks.length).assertEqual(1);
      expect(syncedLorebooks[0].name).assertEqual('测试');
    });

    it('onDataUpdate_syncs_currentLorebookId', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = await mock.create('当前', '');
      await mock.setCurrentLorebookId(lb.id);

      let syncedId: string | null = null;
      vm.onDataUpdate = () => {
        syncedId = vm.currentLorebookId;
      };

      await vm.load();
      expect(syncedId).assertEqual(lb.id);
    });

    it('onDataUpdate_called_after_setCurrentLorebook', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = await mock.create('切换', '');
      await vm.load();

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      await vm.setCurrentLorebook(lb.id);
      expect(callCount).assertEqual(1);
      expect(vm.currentLorebookId).assertEqual(lb.id);
    });

    it('onDataUpdate_not_called_when_callback_is_null', 0, async () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      vm.onDataUpdate = null;

      await vm.load();
      expect(vm.lorebooks.length).assertEqual(0);
    });

    it('onDataUpdate_after_setCurrentLorebook_null', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = await mock.create('临时', '');
      await mock.setCurrentLorebookId(lb.id);
      await vm.load();

      let syncedId: string | null = lb.id;
      vm.onDataUpdate = () => {
        syncedId = vm.currentLorebookId;
      };

      await vm.setCurrentLorebook(null);
      expect(syncedId === null).assertTrue();
    });

    // ===== saveEntry → load 链测试 =====

    it('saveEntry_triggers_onDataUpdate_via_load', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = await mock.create('世界书', '');
      await vm.load();

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      vm.editingEntryLorebookId = lb.id;
      vm.editEntryName = '新条目';
      vm.editEntryKeys = '测试';
      vm.editEntryContent = '测试内容';
      const result: boolean = await vm.saveEntry();
      expect(result).assertTrue();
      expect(callCount >= 1).assertTrue();

      expect(vm.lorebooks.length).assertEqual(1);
      expect(vm.lorebooks[0].entries.length).assertEqual(1);
      expect(vm.lorebooks[0].entries[0].name).assertEqual('新条目');
    });

    it('saveEntry_empty_name_returns_false', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = await mock.create('世界书', '');
      await vm.load();

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      vm.editingEntryLorebookId = lb.id;
      vm.editEntryName = '';
      vm.editEntryKeys = '测试';
      vm.editEntryContent = '内容';
      const result: boolean = await vm.saveEntry();
      expect(result).assertFalse();
      expect(callCount).assertEqual(0);
    });

    it('saveEntry_empty_content_returns_false', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = await mock.create('世界书', '');
      await vm.load();

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      vm.editingEntryLorebookId = lb.id;
      vm.editEntryName = '名称';
      vm.editEntryKeys = '测试';
      vm.editEntryContent = '';
      const result: boolean = await vm.saveEntry();
      expect(result).assertFalse();
      expect(callCount).assertEqual(0);
    });

    // ===== deleteEntry → load 链测试 =====

    it('deleteEntry_triggers_onDataUpdate_via_load', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = await mock.create('世界书', '');
      await mock.addEntry(lb.id, '待删除', ['key'], [], 'content', false, false, false, LorebookPosition.BeforeCharacter, 0);
      await vm.load();

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      // 获取实际条目 ID
      const updatedLb: Lorebook | null = await mock.getById(lb.id);
      if (updatedLb !== null && updatedLb.entries.length > 0) {
        await vm.deleteEntry(lb.id, updatedLb.entries[0].id);
      }
      expect(callCount >= 1).assertTrue();
      expect(vm.lorebooks.length).assertEqual(1);
      expect(vm.lorebooks[0].entries.length).assertEqual(0);
    });

    // ===== deleteLorebook → load 链测试 =====

    it('deleteLorebook_triggers_onDataUpdate_via_load', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = await mock.create('待删除', '');
      await vm.load();

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      await vm.deleteLorebook(lb.id);
      expect(callCount >= 1).assertTrue();
      expect(vm.lorebooks.length).assertEqual(0);
    });

    // ===== saveLorebook → load 链测试 =====

    it('saveLorebook_new_triggers_onDataUpdate_via_load', 0, async () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      await vm.load();

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      vm.editLorebookName = '新世界书';
      const result: boolean = await vm.saveLorebook();
      expect(result).assertTrue();
      expect(callCount >= 1).assertTrue();
      expect(vm.lorebooks.length).assertEqual(1);
      expect(vm.lorebooks[0].name).assertEqual('新世界书');
    });

    it('saveLorebook_empty_name_returns_false', 0, async () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      await vm.load();

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      vm.editLorebookName = '';
      const result: boolean = await vm.saveLorebook();
      expect(result).assertFalse();
      expect(callCount).assertEqual(0);
    });

    it('saveLorebook_edit_existing_triggers_onDataUpdate', 0, async () => {
      const fixture: TestFixture = createFixture();
      const mock: MockLorebookService = fixture.mock;
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = await mock.create('原名', '');
      await vm.load();

      let callCount: number = 0;
      vm.onDataUpdate = () => {
        callCount++;
      };

      vm.editingLorebook = lb;
      vm.editLorebookName = '新名';
      const result: boolean = await vm.saveLorebook();
      expect(result).assertTrue();
      expect(callCount >= 1).assertTrue();
      expect(vm.lorebooks[0].name).assertEqual('新名');
    });

    // ===== toggleExpand 测试 =====

    it('toggleExpand_toggles_expanded_id', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      expect(vm.expandedLorebookId === null).assertTrue();
      vm.toggleExpand('lb-1');
      expect(vm.expandedLorebookId).assertEqual('lb-1');
      vm.toggleExpand('lb-1');
      expect(vm.expandedLorebookId === null).assertTrue();
      vm.toggleExpand('lb-2');
      expect(vm.expandedLorebookId).assertEqual('lb-2');
    });

    // ===== isCurrent 测试 =====

    it('isCurrent_returns_true_when_id_matches', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = createLorebook('测试', '');
      vm.currentLorebookId = lb.id;
      expect(vm.isCurrent(lb)).assertTrue();
    });

    it('isCurrent_returns_false_when_id_differs', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = createLorebook('测试', '');
      vm.currentLorebookId = 'other-id';
      expect(vm.isCurrent(lb)).assertFalse();
    });

    // ===== getPositionText 测试 =====

    it('getPositionText_returns_correct_text', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      expect(vm.getPositionText(LorebookPosition.BeforeCharacter)).assertEqual('角色前');
      expect(vm.getPositionText(LorebookPosition.AfterCharacter)).assertEqual('角色后');
    });

    // ===== getEntryCountText 测试 =====

    it('getEntryCountText_returns_correct_text', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = createLorebook('测试', '');
      expect(vm.getEntryCountText(lb)).assertEqual('无条目');

      const entry: LorebookEntry = createLorebookEntry('e', ['k'], [], 'c');
      const lbWithEntry: Lorebook = addEntryToLorebook(lb, entry);
      expect(vm.getEntryCountText(lbWithEntry)).assertEqual('1 个条目');
    });

    // ===== 对话框状态测试 =====

    it('showNewLorebookDialog_resets_fields', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      vm.showNewLorebookDialog();
      expect(vm.showLorebookDialog).assertTrue();
      expect(vm.editingLorebook === null).assertTrue();
      expect(vm.editLorebookName).assertEqual('');
    });

    it('showEditLorebookDialog_populates_fields', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      const lb: Lorebook = createLorebook('编辑', '描述');
      vm.showEditLorebookDialog(lb);
      expect(vm.showLorebookDialog).assertTrue();
      expect(vm.editingLorebook).assertEqual(lb);
      expect(vm.editLorebookName).assertEqual('编辑');
      expect(vm.editLorebookDescription).assertEqual('描述');
    });

    it('closeLorebookDialog_clears_state', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      vm.showNewLorebookDialog();
      vm.closeLorebookDialog();
      expect(vm.showLorebookDialog).assertFalse();
      expect(vm.editingLorebook === null).assertTrue();
    });

    it('showNewEntryDialog_resets_fields', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      vm.showNewEntryDialog('lb-1');
      expect(vm.showEntryDialog).assertTrue();
      expect(vm.editingEntry === null).assertTrue();
      expect(vm.editingEntryLorebookId).assertEqual('lb-1');
      expect(vm.editEntryName).assertEqual('');
      expect(vm.editEntryPriority).assertEqual(0);
    });

    it('showEditEntryDialog_populates_fields', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      const entry: LorebookEntry = createLorebookEntry(
        '条目', ['酒馆'], ['冒险'], '内容',
        true, false, true, LorebookPosition.AfterCharacter, 50
      );
      vm.showEditEntryDialog('lb-1', entry);
      expect(vm.showEntryDialog).assertTrue();
      expect(vm.editingEntry).assertEqual(entry);
      expect(vm.editEntryName).assertEqual('条目');
      expect(vm.editEntryKeys).assertEqual('酒馆');
      expect(vm.editEntrySelective).assertTrue();
      expect(vm.editEntryPosition).assertEqual(1);
      expect(vm.editEntryPriority).assertEqual(50);
    });

    it('closeEntryDialog_clears_state', () => {
      const fixture: TestFixture = createFixture();
      const vm: LorebookViewModel = fixture.vm;

      vm.showNewEntryDialog('lb-1');
      vm.closeEntryDialog();
      expect(vm.showEntryDialog).assertFalse();
      expect(vm.editingEntry === null).assertTrue();
    });
  });
}