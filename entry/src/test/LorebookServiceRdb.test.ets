/**
 * LorebookService RDB 纯逻辑测试
 *
 * 使用 mock Repository 验证 CRUD、匹配、注入行为。
 */
import { describe, it, expect } from '@ohos/hypium';
import { LorebookService } from '../../main/ets/services/LorebookService';
import { LorebookRepository } from '../../main/ets/repositories/LorebookRepository';
import { LorebookSelectionStore } from '../../main/ets/storage/LorebookSelectionStore';
import { Lorebook, LorebookEntry, LorebookPosition } from '../../main/ets/models/Lorebook';
import { ChatMessage } from '../../main/ets/models/ChatMessage';
import { ChatRole } from '../../main/ets/models/ChatRole';

function makeEntry(
  id: string, keys: string[] = ['key'], secondaryKeys: string[] = [],
  enabled: boolean = true, constant: boolean = false, selective: boolean = false,
  priority: number = 0, position: LorebookPosition = LorebookPosition.BeforeCharacter
): LorebookEntry {
  return {
    id: id, name: 'entry', keys: keys, secondaryKeys: secondaryKeys,
    content: `content of ${id}`, enabled: enabled, constant: constant,
    selective: selective, position: position, priority: priority,
    createdAt: 2000, updatedAt: 2000
  };
}

function makeLb(
  id: string, name: string = 'Lorebook', enabled: boolean = true,
  entries: LorebookEntry[] = []
): Lorebook {
  return {
    id: id, name: name, description: '', enabled: enabled,
    entries: entries, createdAt: 1000, updatedAt: 1000
  };
}

function makeMsg(role: string, content: string): ChatMessage {
  return {
    id: 'msg-1', chatId: 'chat-1', role: role, content: content,
    status: 'completed', createdAt: 3000, updatedAt: 3000,
    sequenceNumber: 1, isStreaming: false, source: 'conversation'
  } as ChatMessage;
}

function makeSvc(
  repoBooks: Lorebook[] = [],
  currentId: string | null = null
): LorebookService {
  const repo: LorebookRepository = {
    list: async (): Promise<Lorebook[]> => repoBooks,
    getById: async (id: string): Promise<Lorebook | null> => {
      for (let i = 0; i < repoBooks.length; i++) {
        if (repoBooks[i].id === id) {
          return repoBooks[i];
        }
      }
      return null;
    },
    insert: async (): Promise<void> => {},
    update: async (): Promise<void> => {},
    remove: async (): Promise<void> => {},
    exists: async (id: string): Promise<boolean> => {
      for (let i = 0; i < repoBooks.length; i++) {
        if (repoBooks[i].id === id) {
          return true;
        }
      }
      return false;
    },
    count: async (): Promise<number> => repoBooks.length
  } as unknown as LorebookRepository;
  const selectionStore: LorebookSelectionStore = {
    initialize: async (): Promise<void> => {},
    getCurrentLorebookId: async (): Promise<string | null> => currentId,
    setCurrentLorebookId: async (): Promise<void> => {},
    clear: async (): Promise<void> => {}
  } as unknown as LorebookSelectionStore;
  return new LorebookService(repo, selectionStore);
}

export default function lorebookServiceRdbTest(): void {
  describe('LorebookServiceRdb', () => {

    // ===== CRUD =====

    it('list_from_repo', 0, async () => {
      const svc: LorebookService = makeSvc([makeLb('lb-1'), makeLb('lb-2')]);
      await svc.initialize();
      const list: Lorebook[] = await svc.list();
      expect(list.length).assertEqual(2);
    });

    it('getById_from_repo', 0, async () => {
      const svc: LorebookService = makeSvc([makeLb('lb-1', 'Test')]);
      await svc.initialize();
      const lb: Lorebook | null = await svc.getById('lb-1');
      expect(lb !== null).assertTrue();
      if (lb !== null) {
        expect(lb.name).assertEqual('Test');
      }
    });

    it('create_writes_repo', 0, async () => {
      let received: boolean = false;
      const repo: LorebookRepository = {
        list: async (): Promise<Lorebook[]> => [],
        getById: async (): Promise<Lorebook | null> => null,
        insert: async (): Promise<void> => { received = true; },
        update: async (): Promise<void> => {},
        remove: async (): Promise<void> => {},
        exists: async (): Promise<boolean> => false,
        count: async (): Promise<number> => 0
      } as unknown as LorebookRepository;
      const selectionStore: LorebookSelectionStore = {
        initialize: async (): Promise<void> => {},
        getCurrentLorebookId: async (): Promise<string | null> => null,
        setCurrentLorebookId: async (): Promise<void> => {},
        clear: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const svc: LorebookService = new LorebookService(repo, selectionStore);
      await svc.initialize();
      await svc.create('New');
      expect(received).assertTrue();
    });

    it('update_writes_repo', 0, async () => {
      let updated: boolean = false;
      const repo: LorebookRepository = {
        list: async (): Promise<Lorebook[]> => [],
        getById: async (): Promise<Lorebook | null> => makeLb('lb-1', 'Old'),
        insert: async (): Promise<void> => {},
        update: async (): Promise<void> => { updated = true; },
        remove: async (): Promise<void> => {},
        exists: async (): Promise<boolean> => true,
        count: async (): Promise<number> => 1
      } as unknown as LorebookRepository;
      const selectionStore: LorebookSelectionStore = {
        initialize: async (): Promise<void> => {},
        getCurrentLorebookId: async (): Promise<string | null> => null,
        setCurrentLorebookId: async (): Promise<void> => {},
        clear: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const svc: LorebookService = new LorebookService(repo, selectionStore);
      await svc.initialize();
      await svc.update('lb-1', { name: 'New' });
      expect(updated).assertTrue();
    });

    it('remove_deletes_repo', 0, async () => {
      let deleted: boolean = false;
      const repo: LorebookRepository = {
        list: async (): Promise<Lorebook[]> => [],
        getById: async (): Promise<Lorebook | null> => null,
        insert: async (): Promise<void> => {},
        update: async (): Promise<void> => {},
        remove: async (): Promise<void> => { deleted = true; },
        exists: async (): Promise<boolean> => false,
        count: async (): Promise<number> => 0
      } as unknown as LorebookRepository;
      let cleared: boolean = false;
      const selectionStore: LorebookSelectionStore = {
        initialize: async (): Promise<void> => {},
        getCurrentLorebookId: async (): Promise<string | null> => 'lb-1',
        setCurrentLorebookId: async (): Promise<void> => { cleared = true; },
        clear: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const svc: LorebookService = new LorebookService(repo, selectionStore);
      await svc.initialize();
      await svc.remove('lb-1');
      expect(deleted).assertTrue();
      expect(cleared).assertTrue();
    });

    it('remove_current_clears_selection', 0, async () => {
      let cleared: boolean = false;
      const repo: LorebookRepository = {
        list: async (): Promise<Lorebook[]> => [],
        getById: async (): Promise<Lorebook | null> => null,
        insert: async (): Promise<void> => {},
        update: async (): Promise<void> => {},
        remove: async (): Promise<void> => {},
        exists: async (): Promise<boolean> => false,
        count: async (): Promise<number> => 0
      } as unknown as LorebookRepository;
      const selectionStore: LorebookSelectionStore = {
        initialize: async (): Promise<void> => {},
        getCurrentLorebookId: async (): Promise<string | null> => 'lb-1',
        setCurrentLorebookId: async (): Promise<void> => { cleared = true; },
        clear: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const svc: LorebookService = new LorebookService(repo, selectionStore);
      await svc.initialize();
      await svc.remove('lb-1');
      expect(cleared).assertTrue();
    });

    it('remove_noncurrent_does_not_clear', 0, async () => {
      let cleared: boolean = false;
      const repo: LorebookRepository = {
        list: async (): Promise<Lorebook[]> => [],
        getById: async (): Promise<Lorebook | null> => null,
        insert: async (): Promise<void> => {},
        update: async (): Promise<void> => {},
        remove: async (): Promise<void> => {},
        exists: async (): Promise<boolean> => false,
        count: async (): Promise<number> => 0
      } as unknown as LorebookRepository;
      const selectionStore: LorebookSelectionStore = {
        initialize: async (): Promise<void> => {},
        getCurrentLorebookId: async (): Promise<string | null> => 'lb-2',
        setCurrentLorebookId: async (): Promise<void> => { cleared = true; },
        clear: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const svc: LorebookService = new LorebookService(repo, selectionStore);
      await svc.initialize();
      await svc.remove('lb-1');
      expect(cleared).assertFalse();
    });

    it('set_existing_to_current', 0, async () => {
      let set: boolean = false;
      const repo: LorebookRepository = {
        list: async (): Promise<Lorebook[]> => [],
        getById: async (): Promise<Lorebook | null> => null,
        insert: async (): Promise<void> => {},
        update: async (): Promise<void> => {},
        remove: async (): Promise<void> => {},
        exists: async (): Promise<boolean> => true,
        count: async (): Promise<number> => 0
      } as unknown as LorebookRepository;
      const selectionStore: LorebookSelectionStore = {
        initialize: async (): Promise<void> => {},
        getCurrentLorebookId: async (): Promise<string | null> => null,
        setCurrentLorebookId: async (): Promise<void> => { set = true; },
        clear: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const svc: LorebookService = new LorebookService(repo, selectionStore);
      await svc.initialize();
      await svc.setCurrentLorebookId('lb-1');
      expect(set).assertTrue();
    });

    it('set_nonexisting_fails', 0, async () => {
      const repo: LorebookRepository = {
        list: async (): Promise<Lorebook[]> => [],
        getById: async (): Promise<Lorebook | null> => null,
        insert: async (): Promise<void> => {},
        update: async (): Promise<void> => {},
        remove: async (): Promise<void> => {},
        exists: async (): Promise<boolean> => false,
        count: async (): Promise<number> => 0
      } as unknown as LorebookRepository;
      const selectionStore: LorebookSelectionStore = {
        initialize: async (): Promise<void> => {},
        getCurrentLorebookId: async (): Promise<string | null> => null,
        setCurrentLorebookId: async (): Promise<void> => {},
        clear: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const svc: LorebookService = new LorebookService(repo, selectionStore);
      await svc.initialize();
      let caught: boolean = false;
      try {
        await svc.setCurrentLorebookId('nonexistent');
      } catch (e) {
        caught = true;
      }
      expect(caught).assertTrue();
    });

    it('getCurrentLorebook_correct', 0, async () => {
      const svc: LorebookService = makeSvc([makeLb('lb-1', 'Current')], 'lb-1');
      await svc.initialize();
      const lb: Lorebook | null = await svc.getCurrentLorebook();
      expect(lb !== null).assertTrue();
      if (lb !== null) {
        expect(lb.name).assertEqual('Current');
      }
    });

    it('current_not_found_clears', 0, async () => {
      let cleared: boolean = false;
      const repo: LorebookRepository = {
        list: async (): Promise<Lorebook[]> => [],
        getById: async (): Promise<Lorebook | null> => null,
        insert: async (): Promise<void> => {},
        update: async (): Promise<void> => {},
        remove: async (): Promise<void> => {},
        exists: async (): Promise<boolean> => false,
        count: async (): Promise<number> => 0
      } as unknown as LorebookRepository;
      const selectionStore: LorebookSelectionStore = {
        initialize: async (): Promise<void> => {},
        getCurrentLorebookId: async (): Promise<string | null> => 'missing',
        setCurrentLorebookId: async (): Promise<void> => { cleared = true; },
        clear: async (): Promise<void> => {}
      } as unknown as LorebookSelectionStore;
      const svc: LorebookService = new LorebookService(repo, selectionStore);
      await svc.initialize();
      const lb: Lorebook | null = await svc.getCurrentLorebook();
      expect(lb === null).assertTrue();
      expect(cleared).assertTrue();
    });

    // ===== 匹配回归 =====

    it('disabled_lorebook_no_match', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['hello']);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', false, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', false, [e1]),
        [makeMsg('user', 'hello world')]
      );
      expect(entries.length).assertEqual(0);
    });

    it('disabled_entry_no_match', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['hello'], [], false);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1]),
        [makeMsg('user', 'hello world')]
      );
      expect(entries.length).assertEqual(0);
    });

    it('constant_entry_always_matched', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', [], [], true, true);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1]),
        [makeMsg('user', 'anything')]
      );
      expect(entries.length).assertEqual(1);
    });

    it('primary_key_match', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['hello']);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1]),
        [makeMsg('user', 'hello world')]
      );
      expect(entries.length).assertEqual(1);
    });

    it('selective_secondary_required', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['primary'], ['secondary'], true, false, true);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1]),
        [makeMsg('user', 'primary only')]
      );
      expect(entries.length).assertEqual(0);
    });

    it('selective_match_both', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['primary'], ['secondary'], true, false, true);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1]),
        [makeMsg('user', 'primary and secondary together')]
      );
      expect(entries.length).assertEqual(1);
    });

    it('priority_sorting', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['key'], [], true, false, false, 1);
      const e2: LorebookEntry = makeEntry('e-2', ['key'], [], true, false, false, 10);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1, e2])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1, e2]),
        [makeMsg('user', 'key')]
      );
      expect(entries.length).assertEqual(2);
      expect(entries[0].priority).assertEqual(10);
      expect(entries[1].priority).assertEqual(1);
    });

    it('before_character_group', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['key'], [], true, false, false, 0, LorebookPosition.BeforeCharacter);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1]),
        [makeMsg('user', 'key')]
      );
      expect(entries.length).assertEqual(1);
      expect(entries[0].position).assertEqual(LorebookPosition.BeforeCharacter);
    });

    it('after_character_group', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['key'], [], true, false, false, 0, LorebookPosition.AfterCharacter);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1]),
        [makeMsg('user', 'key')]
      );
      expect(entries.length).assertEqual(1);
      expect(entries[0].position).assertEqual(LorebookPosition.AfterCharacter);
    });

    it('chinese_keywords', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['你好']);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1]),
        [makeMsg('user', '你好世界')]
      );
      expect(entries.length).assertEqual(1);
    });

    it('chinese_case_insensitive_not_applied', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['你好']);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const entries: LorebookEntry[] = svc.matchEntriesForLorebook(
        makeLb('lb-1', 'Lb', true, [e1]),
        [makeMsg('user', '你好')]
      );
      expect(entries.length).assertEqual(1);
    });

    it('buildInjectionAsync_structure', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['key'], [], true, false, false, 0, LorebookPosition.BeforeCharacter);
      const e2: LorebookEntry = makeEntry('e-2', ['key'], [], true, false, false, 0, LorebookPosition.AfterCharacter);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1, e2])], 'lb-1'
      );
      await svc.initialize();
      const injection = await svc.buildInjectionAsync([makeMsg('user', 'key')]);
      expect(injection.before.length > 0).assertTrue();
      expect(injection.after.length > 0).assertTrue();
    });

    it('buildInjectionAsync_before_content', 0, async () => {
      const e1: LorebookEntry = {
        id: 'e-1', name: 'entry', keys: ['key'], secondaryKeys: [],
        content: 'BEFORE_CONTENT', enabled: true, constant: false, selective: false,
        position: LorebookPosition.BeforeCharacter, priority: 0,
        createdAt: 2000, updatedAt: 2000
      };
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const injection = await svc.buildInjectionAsync([makeMsg('user', 'key')]);
      expect(injection.before).assertEqual('BEFORE_CONTENT');
      expect(injection.after).assertEqual('');
    });

    it('buildInjectionAsync_after_content', 0, async () => {
      const e1: LorebookEntry = {
        id: 'e-1', name: 'entry', keys: ['key'], secondaryKeys: [],
        content: 'AFTER_CONTENT', enabled: true, constant: false, selective: false,
        position: LorebookPosition.AfterCharacter, priority: 0,
        createdAt: 2000, updatedAt: 2000
      };
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const injection = await svc.buildInjectionAsync([makeMsg('user', 'key')]);
      expect(injection.before).assertEqual('');
      expect(injection.after).assertEqual('AFTER_CONTENT');
    });

    it('no_persist_matched_results', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['key']);
      const svc: LorebookService = makeSvc(
        [makeLb('lb-1', 'Lb', true, [e1])], 'lb-1'
      );
      await svc.initialize();
      const lb: Lorebook | null = await svc.getCurrentLorebook();
      expect(lb !== null).assertTrue();
      if (lb !== null) {
        const keys: string[] = Object.keys(lb);
        expect(keys.indexOf('matchedEntryIds') < 0).assertTrue();
      }
    });

    it('input_object_not_mutated', 0, async () => {
      const e1: LorebookEntry = makeEntry('e-1', ['key']);
      const lb: Lorebook = makeLb('lb-1', 'Lb', true, [e1]);
      const svc: LorebookService = makeSvc([lb], 'lb-1');
      await svc.initialize();
      const originalLen: number = lb.entries.length;
      svc.matchEntriesForLorebook(lb, [makeMsg('user', 'key')]);
      expect(lb.entries.length).assertEqual(originalLen);
    });
  });
}