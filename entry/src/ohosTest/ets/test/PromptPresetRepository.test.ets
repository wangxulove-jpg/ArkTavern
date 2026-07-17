/**
 * PromptPresetRepository 设备测试(ohosTest,需真机/模拟器运行)
 *
 * 覆盖:
 * - CRUD 操作
 * - 可选参数 NULL 持久化
 * - 中文/Emoji/多行/Markdown 内容往返
 * - 校验和安全
 * - 不影响 Character/Lorebook/Chat/Message
 * - 不包含 Secret 字段
 *
 * 使用独立测试数据库 arktavern_prompt_preset_repository_test.db。
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { PromptPresetRepository } from '../../../main/ets/repositories/PromptPresetRepository';
import { PromptPreset } from '../../../main/ets/models/PromptPreset';
import { DatabaseError } from '../../../main/ets/models/DatabaseError';
import {
  createV1ToV2Migration,
  createV2ToV3Migration
} from '../../../main/ets/database/DatabaseMigration';
import {
  TABLE_CHARACTERS,
  TABLE_LOREBOOKS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_PROMPT_PRESETS,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_PRESET_ID,
  COLUMN_PRESET_NAME,
  COLUMN_PRESET_TEMPERATURE,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../../main/ets/database/DatabaseConstants';

const TEST_DB_NAME: string = 'arktavern_prompt_preset_repository_test.db';

interface SetupResult {
  helper: DbHelper;
  repo: PromptPresetRepository;
}

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

async function setupRepo(
  context: common.Context
): Promise<SetupResult> {
  await deleteDb(context);
  const helper: DbHelper = new DbHelper(TEST_DB_NAME,
    [createV1ToV2Migration(), createV2ToV3Migration()]);
  await helper.initialize(context);
  const repo: PromptPresetRepository = new PromptPresetRepository(helper);
  const result: SetupResult = { helper: helper, repo: repo };
  return result;
}

function makePreset(overrides?: Partial<PromptPreset>): PromptPreset {
  const base: PromptPreset = {
    id: 'test-id',
    name: 'Test Preset',
    description: 'Test description',
    systemPrompt: 'You are a helpful assistant',
    temperature: 0.7,
    topP: 1.0,
    maxOutputTokens: 1024,
    contextWindow: 32768,
    createdAt: 1000,
    updatedAt: 2000
  };
  if (overrides === undefined) {
    return base;
  }
  return {
    id: overrides.id !== undefined ? overrides.id : base.id,
    name: overrides.name !== undefined ? overrides.name : base.name,
    description: overrides.description !== undefined ? overrides.description : base.description,
    systemPrompt: overrides.systemPrompt !== undefined ? overrides.systemPrompt : base.systemPrompt,
    temperature: overrides.temperature !== undefined ? overrides.temperature : base.temperature,
    topP: overrides.topP !== undefined ? overrides.topP : base.topP,
    maxOutputTokens: overrides.maxOutputTokens !== undefined ? overrides.maxOutputTokens : base.maxOutputTokens,
    contextWindow: overrides.contextWindow !== undefined ? overrides.contextWindow : base.contextWindow,
    createdAt: overrides.createdAt !== undefined ? overrides.createdAt : base.createdAt,
    updatedAt: overrides.updatedAt !== undefined ? overrides.updatedAt : base.updatedAt
  };
}

function copyPreset(preset: PromptPreset,
  overrides?: Partial<PromptPreset>
): PromptPreset {
  return {
    id: overrides?.id !== undefined ? overrides.id : preset.id,
    name: overrides?.name !== undefined ? overrides.name : preset.name,
    description: overrides?.description !== undefined ? overrides.description : preset.description,
    systemPrompt: overrides?.systemPrompt !== undefined ? overrides.systemPrompt : preset.systemPrompt,
    temperature: overrides?.temperature !== undefined ? overrides.temperature : preset.temperature,
    topP: overrides?.topP !== undefined ? overrides.topP : preset.topP,
    maxOutputTokens: overrides?.maxOutputTokens !== undefined ? overrides.maxOutputTokens : preset.maxOutputTokens,
    contextWindow: overrides?.contextWindow !== undefined ? overrides.contextWindow : preset.contextWindow,
    createdAt: overrides?.createdAt !== undefined ? overrides.createdAt : preset.createdAt,
    updatedAt: overrides?.updatedAt !== undefined ? overrides.updatedAt : preset.updatedAt
  };
}

export default function promptPresetRepositoryTest(): void {
  describe('PromptPresetRepositoryTest', () => {

    // ===== 1. 插入最小 Preset =====
    it('insert_minimal_preset', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({
          id: 'min-1',
          description: '',
          systemPrompt: '',
          temperature: undefined,
          topP: undefined,
          maxOutputTokens: undefined,
          contextWindow: undefined
        });
        await repo.insert(preset);
        expect(await repo.exists('min-1')).assertTrue();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 2. 插入完整 Preset =====
    it('insert_full_preset', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'full-1' });
        await repo.insert(preset);
        expect(await repo.count()).assertEqual(1);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 3. getById 完整字段往返 =====
    it('getById_full_roundtrip', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'rt-1' });
        await repo.insert(preset);
        const found: PromptPreset | null = await repo.getById('rt-1');
        expect(found === null).assertFalse();
        expect(found!.name).assertEqual('Test Preset');
        expect(found!.description).assertEqual('Test description');
        expect(found!.systemPrompt).assertEqual('You are a helpful assistant');
        expect(found!.temperature).assertEqual(0.7);
        expect(found!.topP).assertEqual(1.0);
        expect(found!.maxOutputTokens).assertEqual(1024);
        expect(found!.contextWindow).assertEqual(32768);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 4. getById 不存在返回 null =====
    it('getById_nonexistent_returns_null', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const found: PromptPreset | null = await repo.getById('nonexistent');
        expect(found).assertNull();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 5. list 排序正确 =====
    it('list_sorted_by_updated_at_desc', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        await repo.insert(makePreset({ id: 'p1', name: 'A', updatedAt: 1000 }));
        await repo.insert(makePreset({ id: 'p2', name: 'B', updatedAt: 3000 }));
        await repo.insert(makePreset({ id: 'p3', name: 'C', updatedAt: 2000 }));
        const list: PromptPreset[] = await repo.list();
        expect(list.length).assertEqual(3);
        expect(list[0].id).assertEqual('p2');
        expect(list[1].id).assertEqual('p3');
        expect(list[2].id).assertEqual('p1');
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 6. update name =====
    it('update_name', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'up-1', name: 'Old' });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { name: 'New', updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('up-1');
        expect(found!.name).assertEqual('New');
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 7. update description =====
    it('update_description', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'up-2', description: 'Old desc' });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { description: 'New desc', updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('up-2');
        expect(found!.description).assertEqual('New desc');
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 8. update systemPrompt =====
    it('update_systemPrompt', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'up-3', systemPrompt: 'Old sp' });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { systemPrompt: 'New sp', updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('up-3');
        expect(found!.systemPrompt).assertEqual('New sp');
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 9. update temperature =====
    it('update_temperature', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'up-4', temperature: 0.5 });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { temperature: 1.5, updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('up-4');
        expect(found!.temperature).assertEqual(1.5);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 10. update topP =====
    it('update_topP', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'up-5', topP: 0.5 });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { topP: 0.9, updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('up-5');
        expect(found!.topP).assertEqual(0.9);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 11. update maxOutputTokens =====
    it('update_maxOutputTokens', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'up-6', maxOutputTokens: 512 });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { maxOutputTokens: 2048, updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('up-6');
        expect(found!.maxOutputTokens).assertEqual(2048);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 12. update contextWindow =====
    it('update_contextWindow', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'up-7', contextWindow: 16384 });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { contextWindow: 65536, updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('up-7');
        expect(found!.contextWindow).assertEqual(65536);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 13. 清空 temperature =====
    it('clear_temperature_to_null', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'cl-1', temperature: 0.7 });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { temperature: undefined, updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('cl-1');
        expect(found!.temperature).assertUndefined();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 14. 清空 topP =====
    it('clear_topP_to_null', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'cl-2', topP: 1.0 });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { topP: undefined, updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('cl-2');
        expect(found!.topP).assertUndefined();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 15. 清空 maxOutputTokens =====
    it('clear_maxOutputTokens_to_null', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'cl-3', maxOutputTokens: 1024 });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { maxOutputTokens: undefined, updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('cl-3');
        expect(found!.maxOutputTokens).assertUndefined();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 16. 清空 contextWindow =====
    it('clear_contextWindow_to_null', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'cl-4', contextWindow: 32768 });
        await repo.insert(preset);
        const updated: PromptPreset = copyPreset(preset, { contextWindow: undefined, updatedAt: 3000 });
        await repo.update(updated);
        const found: PromptPreset | null = await repo.getById('cl-4');
        expect(found!.contextWindow).assertUndefined();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 17. update 不存在返回 NotFound =====
    it('update_nonexistent_throws_not_found', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'nonexistent' });
        try {
          await repo.update(preset);
          expect(false).assertTrue();
        } catch (e) {
          const err: DatabaseError = e as DatabaseError;
          expect(err.type).assertEqual(8); // NotFound
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 18. remove 存在记录 =====
    it('remove_existing_preset', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'rm-1' });
        await repo.insert(preset);
        await repo.remove('rm-1');
        expect(await repo.exists('rm-1')).assertFalse();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 19. remove 不存在幂等 =====
    it('remove_nonexistent_is_idempotent', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        await repo.remove('nonexistent');
        expect(await repo.count()).assertEqual(0);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 20. count 正确 =====
    it('count_correct', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        expect(await repo.count()).assertEqual(0);
        await repo.insert(makePreset({ id: 'c1' }));
        expect(await repo.count()).assertEqual(1);
        await repo.insert(makePreset({ id: 'c2' }));
        expect(await repo.count()).assertEqual(2);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 21. exists 正确 =====
    it('exists_correct', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        await repo.insert(makePreset({ id: 'ex-1' }));
        expect(await repo.exists('ex-1')).assertTrue();
        expect(await repo.exists('nonexistent')).assertFalse();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 22. 重复 ID 插入失败 =====
    it('duplicate_id_insert_fails', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        await repo.insert(makePreset({ id: 'dup-1' }));
        try {
          await repo.insert(makePreset({ id: 'dup-1' }));
          expect(false).assertTrue();
        } catch (e) {
          const err: DatabaseError = e as DatabaseError;
          expect(err.type).assertEqual(9); // AlreadyExists
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 23. 中文名称 =====
    it('chinese_name_roundtrip', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        await repo.insert(makePreset({ id: 'cn-1', name: '角色扮演预设' }));
        const found: PromptPreset | null = await repo.getById('cn-1');
        expect(found!.name).assertEqual('角色扮演预设');
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 24. Emoji =====
    it('emoji_roundtrip', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        await repo.insert(makePreset({ id: 'emo-1', name: '🎭 RP', systemPrompt: '🤖 Assistant' }));
        const found: PromptPreset | null = await repo.getById('emo-1');
        expect(found!.name).assertEqual('🎭 RP');
        expect(found!.systemPrompt).assertEqual('🤖 Assistant');
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 25. 多行 systemPrompt =====
    it('multiline_systemPrompt_roundtrip', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const sp: string = 'Line 1\nLine 2\nLine 3';
        await repo.insert(makePreset({ id: 'ml-1', systemPrompt: sp }));
        const found: PromptPreset | null = await repo.getById('ml-1');
        expect(found!.systemPrompt).assertEqual(sp);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 26. Markdown =====
    it('markdown_systemPrompt_roundtrip', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const sp: string = '**Bold**\n- List\n`code`';
        await repo.insert(makePreset({ id: 'md-1', systemPrompt: sp }));
        const found: PromptPreset | null = await repo.getById('md-1');
        expect(found!.systemPrompt).assertEqual(sp);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 27. 引号和反斜线 =====
    it('quotes_and_backslashes', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const sp: string = 'He said "hello" and \\backslash\\';
        await repo.insert(makePreset({ id: 'qb-1', systemPrompt: sp }));
        const found: PromptPreset | null = await repo.getById('qb-1');
        expect(found!.systemPrompt).assertEqual(sp);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 28. 空 systemPrompt =====
    it('empty_systemPrompt', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        await repo.insert(makePreset({ id: 'esp-1', systemPrompt: '' }));
        const found: PromptPreset | null = await repo.getById('esp-1');
        expect(found!.systemPrompt).assertEqual('');
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 29. description 空字符串 =====
    it('empty_description', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        await repo.insert(makePreset({ id: 'ed-1', description: '' }));
        const found: PromptPreset | null = await repo.getById('ed-1');
        expect(found!.description).assertEqual('');
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 30. 空 name 拒绝 =====
    it('reject_empty_name', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        try {
          await repo.insert(makePreset({ id: 'en-1', name: '   ' }));
          expect(false).assertTrue();
        } catch (e) {
          const err: DatabaseError = e as DatabaseError;
          expect(err.type).assertEqual(7); // InvalidData
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 31. temperature 越界拒绝 =====
    it('reject_temperature_out_of_range', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        try {
          await repo.insert(makePreset({ id: 'ot-1', temperature: 3.0 }));
          expect(false).assertTrue();
        } catch (e) {
          const err: DatabaseError = e as DatabaseError;
          expect(err.type).assertEqual(7); // InvalidData
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 32. topP 越界拒绝 =====
    it('reject_topP_out_of_range', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        try {
          await repo.insert(makePreset({ id: 'ot-2', topP: 1.5 }));
          expect(false).assertTrue();
        } catch (e) {
          const err: DatabaseError = e as DatabaseError;
          expect(err.type).assertEqual(7); // InvalidData
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 33. maxOutputTokens 非整数拒绝 =====
    it('reject_maxOutputTokens_not_integer', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        try {
          await repo.insert(makePreset({ id: 'ot-3', maxOutputTokens: 1.5 }));
          expect(false).assertTrue();
        } catch (e) {
          const err: DatabaseError = e as DatabaseError;
          expect(err.type).assertEqual(7); // InvalidData
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 34. contextWindow 非整数拒绝 =====
    it('reject_contextWindow_not_integer', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        try {
          await repo.insert(makePreset({ id: 'ot-4', contextWindow: 1.5 }));
          expect(false).assertTrue();
        } catch (e) {
          const err: DatabaseError = e as DatabaseError;
          expect(err.type).assertEqual(7); // InvalidData
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 35. 非法时间拒绝 =====
    it('reject_invalid_timestamp', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        try {
          await repo.insert(makePreset({ id: 'it-1', createdAt: -1 }));
          expect(false).assertTrue();
        } catch (e) {
          const err: DatabaseError = e as DatabaseError;
          expect(err.type).assertEqual(7); // InvalidData
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 36. 数据库 NULL 正确映射 undefined =====
    it('null_maps_to_undefined', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        await repo.insert(makePreset({
          id: 'null-1',
          temperature: undefined,
          topP: undefined,
          maxOutputTokens: undefined,
          contextWindow: undefined
        }));
        const found: PromptPreset | null = await repo.getById('null-1');
        expect(found!.temperature).assertUndefined();
        expect(found!.topP).assertUndefined();
        expect(found!.maxOutputTokens).assertUndefined();
        expect(found!.contextWindow).assertUndefined();
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 37. 输入 Preset 未修改 =====
    it('input_preset_not_modified', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const preset: PromptPreset = makePreset({ id: 'imm-1' });
        const originalName: string = preset.name;
        await repo.insert(preset);
        expect(preset.name).assertEqual(originalName);
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 38. 不影响 Character =====
    it('does_not_affect_characters', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        const bucket: relationalStore.ValuesBucket = {};
        bucket[COLUMN_ID] = 'char-1';
        bucket[COLUMN_NAME] = 'TestChar';
        bucket[COLUMN_CREATED_AT] = 1000;
        bucket[COLUMN_UPDATED_AT] = 1000;
        await store.insert(TABLE_CHARACTERS, bucket);
        await repo.insert(makePreset({ id: 'pp1' }));
        const rs: relationalStore.ResultSet =
          await store.querySql(`SELECT COUNT(*) AS cnt FROM ${TABLE_CHARACTERS}`);
        try {
          if (rs.goToFirstRow()) {
            expect(rs.getLong(rs.getColumnIndex('cnt'))).assertEqual(1);
          }
        } finally {
          try { rs.close(); } catch (e) { /* ignore */ }
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });

    // ===== 39. 表中不包含 Secret 字段 =====
    it('no_secret_fields_in_table', 0, async () => {
      const ctx: common.Context = await getContext();
      const setupResult = await setupRepo(ctx);
      const helper = setupResult.helper;
      const repo = setupResult.repo;
      try {
        const store: relationalStore.RdbStore = helper.getStore();
        const rs: relationalStore.ResultSet =
          await store.querySql(`PRAGMA table_info(${TABLE_PROMPT_PRESETS})`);
        try {
          while (rs.goToNextRow()) {
            const ci: number = rs.getColumnIndex('name');
            if (ci >= 0) {
              const colName: string = rs.getString(ci).toUpperCase();
              expect(colName.indexOf('SECRET') >= 0).assertFalse();
              expect(colName.indexOf('API_KEY') >= 0).assertFalse();
              expect(colName.indexOf('BASE_URL') >= 0).assertFalse();
              expect(colName.indexOf('AUTHORIZATION') >= 0).assertFalse();
            }
          }
        } finally {
          try { rs.close(); } catch (e) { /* ignore */ }
        }
      } finally {
        try { await helper.close(); } catch (e) { /* ignore */ }
        await deleteDb(ctx);
      }
    });
  });
}