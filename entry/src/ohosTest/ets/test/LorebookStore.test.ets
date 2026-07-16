/**
 * LorebookStore 设备测试
 *
 * 覆盖:
 * - 世界书 CRUD 和重启持久化
 * - 条目增删改
 * - 当前世界书设置/读取
 * - 删除当前世界书清空选择
 * - 损坏数据不崩溃
 * - 重复 ID 检查
 * - 不存在的 ID 操作
 */

import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { LorebookStore } from '../../../main/ets/storage/LorebookStore';
import {
  Lorebook,
  LorebookEntry,
  LorebookPosition,
  createLorebook,
  createLorebookEntry,
  addEntryToLorebook,
  updateLorebook,
  updateLorebookEntry,
  removeEntryFromLorebook
} from '../../../main/ets/models/Lorebook';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { UIAbility } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export default function lorebookStoreDeviceTest() {
  describe('LorebookStore', () => {
    let store: LorebookStore;
    let ctx: common.Context;

    beforeAll(async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const ability: UIAbility = await delegator.getCurrentTopAbility();
      ctx = ability.context as common.Context;
      store = new LorebookStore();
      await store.initialize(ctx);
      const existing: Lorebook[] = await store.list();
      for (let i = 0; i < existing.length; i++) {
        await store.remove(existing[i].id);
      }
      await store.setCurrentLorebookId(null);
    });

    afterAll(async () => {
      const existing: Lorebook[] = await store.list();
      for (let i = 0; i < existing.length; i++) {
        await store.remove(existing[i].id);
      }
      await store.setCurrentLorebookId(null);
    });

    it('save_and_retrieve_lorebook', 0, async () => {
      const lb: Lorebook = createLorebook('测试世界书', '描述');
      await store.save(lb);
      const retrieved: Lorebook | null = await store.getById(lb.id);
      expect(retrieved !== null).assertTrue();
      expect(retrieved!.name).assertEqual('测试世界书');
      expect(retrieved!.description).assertEqual('描述');
      expect(retrieved!.entries.length).assertEqual(0);
    });

    it('save_duplicate_id_throws', 0, async () => {
      const lb: Lorebook = createLorebook('重复测试', '');
      await store.save(lb);
      let threw: boolean = false;
      try {
        await store.save(lb);
      } catch (_e) {
        threw = true;
      }
      expect(threw).assertTrue();
      await store.remove(lb.id);
    });

    it('update_lorebook_name', 0, async () => {
      const lb: Lorebook = createLorebook('原名', '');
      await store.save(lb);
      const updated: Lorebook = updateLorebook(lb, { name: '新名' });
      await store.update(updated);
      const retrieved: Lorebook | null = await store.getById(lb.id);
      expect(retrieved !== null).assertTrue();
      expect(retrieved!.name).assertEqual('新名');
      await store.remove(lb.id);
    });

    it('update_nonexistent_throws', 0, async () => {
      const lb: Lorebook = createLorebook('不存在', '');
      let threw: boolean = false;
      try {
        await store.update(lb);
      } catch (_e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('remove_and_getById_returns_null', 0, async () => {
      const lb: Lorebook = createLorebook('待删除', '');
      await store.save(lb);
      await store.remove(lb.id);
      const retrieved: Lorebook | null = await store.getById(lb.id);
      expect(retrieved === null).assertTrue();
    });

    it('list_returns_all_lorebooks', 0, async () => {
      const lb1: Lorebook = createLorebook('A', '');
      const lb2: Lorebook = createLorebook('B', '');
      await store.save(lb1);
      await store.save(lb2);
      const all: Lorebook[] = await store.list();
      expect(all.length >= 2).assertTrue();
      await store.remove(lb1.id);
      await store.remove(lb2.id);
    });

    it('set_and_get_current_lorebook', 0, async () => {
      const lb: Lorebook = createLorebook('当前世界书', '');
      await store.save(lb);
      await store.setCurrentLorebookId(lb.id);
      const currentId: string | null = await store.getCurrentLorebookId();
      expect(currentId).assertEqual(lb.id);
      const current: Lorebook | null = await store.getCurrentLorebook();
      expect(current !== null).assertTrue();
      expect(current!.name).assertEqual('当前世界书');
      await store.remove(lb.id);
    });

    it('set_current_lorebook_nonexistent_throws', 0, async () => {
      let threw: boolean = false;
      try {
        await store.setCurrentLorebookId('nonexistent-id');
      } catch (_e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('set_current_lorebook_null_clears_selection', 0, async () => {
      const lb: Lorebook = createLorebook('临时', '');
      await store.save(lb);
      await store.setCurrentLorebookId(lb.id);
      await store.setCurrentLorebookId(null);
      const currentId: string | null = await store.getCurrentLorebookId();
      expect(currentId === null).assertTrue();
      await store.remove(lb.id);
    });

    it('remove_current_lorebook_clears_selection', 0, async () => {
      const lb: Lorebook = createLorebook('将被删', '');
      await store.save(lb);
      await store.setCurrentLorebookId(lb.id);
      await store.remove(lb.id);
      const currentId: string | null = await store.getCurrentLorebookId();
      expect(currentId === null).assertTrue();
    });

    it('save_lorebook_with_entries', 0, async () => {
      let lb: Lorebook = createLorebook('含条目', '');
      const entry: LorebookEntry = createLorebookEntry(
        '场景', ['酒馆'], [], '这是一间酒馆', true, false, false,
        LorebookPosition.BeforeCharacter, 100
      );
      lb = addEntryToLorebook(lb, entry);
      await store.save(lb);
      const retrieved: Lorebook | null = await store.getById(lb.id);
      expect(retrieved !== null).assertTrue();
      expect(retrieved!.entries.length).assertEqual(1);
      expect(retrieved!.entries[0].name).assertEqual('场景');
      expect(retrieved!.entries[0].keys[0]).assertEqual('酒馆');
      await store.remove(lb.id);
    });

    it('update_lorebook_entries', 0, async () => {
      let lb: Lorebook = createLorebook('更新条目测试', '');
      const entry: LorebookEntry = createLorebookEntry(
        '原条目', ['原'], [], '原内容', true, false, false
      );
      lb = addEntryToLorebook(lb, entry);
      await store.save(lb);

      const updatedEntry: LorebookEntry = updateLorebookEntry(entry, { name: '新条目', content: '新内容' });
      const updated: Lorebook = addEntryToLorebook(
        removeEntryFromLorebook(lb, entry.id), updatedEntry
      );
      await store.update(updated);

      const retrieved: Lorebook | null = await store.getById(lb.id);
      expect(retrieved !== null).assertTrue();
      expect(retrieved!.entries.length).assertEqual(1);
      expect(retrieved!.entries[0].name).assertEqual('新条目');
      expect(retrieved!.entries[0].content).assertEqual('新内容');
      await store.remove(lb.id);
    });

    it('remove_entry_from_lorebook', 0, async () => {
      let lb: Lorebook = createLorebook('删除条目测试', '');
      const e1: LorebookEntry = createLorebookEntry('条目1', ['k1'], [], 'c1');
      const e2: LorebookEntry = createLorebookEntry('条目2', ['k2'], [], 'c2');
      lb = addEntryToLorebook(lb, e1);
      lb = addEntryToLorebook(lb, e2);
      await store.save(lb);

      const afterRemove: Lorebook = removeEntryFromLorebook(lb, e1.id);
      await store.update(afterRemove);

      const retrieved: Lorebook | null = await store.getById(lb.id);
      expect(retrieved !== null).assertTrue();
      expect(retrieved!.entries.length).assertEqual(1);
      expect(retrieved!.entries[0].id).assertEqual(e2.id);
      await store.remove(lb.id);
    });

    it('persistence_across_reloads', 0, async () => {
      const lb: Lorebook = createLorebook('持久化测试', '');
      await store.save(lb);
      const store2: LorebookStore = new LorebookStore();
      await store2.initialize(ctx);
      const retrieved: Lorebook | null = await store2.getById(lb.id);
      expect(retrieved !== null).assertTrue();
      expect(retrieved!.name).assertEqual('持久化测试');
      await store.remove(lb.id);
    });

    it('corrupted_json_does_not_crash', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const ability: UIAbility = await delegator.getCurrentTopAbility();
      const context: common.Context = ability.context as common.Context;
      const p = await preferences.getPreferences(context, 'arktavern_settings');
      const original: string = await p.get('lorebook_list_v1', '[]') as string;
      await p.put('lorebook_list_v1', 'not valid json {{{');
      await p.flush();
      const list: Lorebook[] = await store.list();
      expect(list.length).assertEqual(0);
      await p.put('lorebook_list_v1', original);
      await p.flush();
    });
  });
}