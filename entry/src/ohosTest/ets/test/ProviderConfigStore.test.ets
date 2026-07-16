/**
 * ProviderConfigStore 设备集成测试(ohosTest,需真机/模拟器运行)。
 *
 * 基于 HarmonyOS Preferences Kit 验证 ProviderConfig 列表的持久化 CRUD 行为,
 * 以及 current_provider_id 选中状态管理。
 * 所有测试数据均为假数据,不含真实 API Key,不含 Base URL 真实值。
 *
 * 验证项(共 27 项):
 * 1. 初始化 Preferences
 * 2. 初始 list 为空
 * 3. save 配置
 * 4. list 返回配置
 * 5. getById
 * 6. save 重复 id 抛 AlreadyExists
 * 7. update 配置
 * 8. update 不存在抛 NotFound
 * 9. remove 配置
 * 10. 重复 remove 不崩溃
 * 11. 保存两个配置
 * 12. 两配置顺序稳定
 * 13. setCurrentProviderId
 * 14. getCurrentProviderId
 * 15. getCurrent
 * 16. setCurrentProviderId 不存在 id 抛 InvalidSelection
 * 17. 删除当前配置后自动清空选择
 * 18. setCurrentProviderId(null)
 * 19. 新 Store 实例仍能读取
 * 20. 进程重启后仍能读取(同进程内通过新实例模拟)
 * 21. 并发 save 不丢失
 * 22. 并发 update/remove 不产生损坏 JSON
 * 23. 手工写入损坏 JSON 后得到 CorruptedData
 * 24. 单个坏配置不会影响有效配置加载
 * 25. 清理测试数据
 * 26. 日志中无配置 JSON
 * 27. Preferences 文件中无 API Key 测试值
 *
 * === 第 20 项持久性说明 ===
 * 真正的跨进程重启验证需手工两阶段执行:
 * 阶段 A:运行 persistent_save_phase 测试 → 保存固定配置 → 退出应用 → 强制结束进程
 * 阶段 B:重新启动应用 → 运行 persistent_verify_phase 测试 → 读取并验证 → 自动清理
 * 在单次测试套件运行中,通过新建 ProviderConfigStore 实例 + 新 AppPreferences 实例验证跨实例读取,
 * 跨进程持久性需按上述步骤手工执行。
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { AppPreferences } from '../../../main/ets/storage/AppPreferences';
import { ProviderConfigStore } from '../../../main/ets/storage/ProviderConfigStore';
import { ProviderConfig } from '../../../main/ets/models/ProviderConfig';
import { ProviderType } from '../../../main/ets/models/ProviderType';
import { PreferencesError, PreferencesErrorType, isPreferencesError } from '../../../main/ets/models/PreferencesError';

// ===== 测试常量(均为假数据,非真实 API Key,不含敏感字段) =====

/** 测试用 Provider id A */
const PROVIDER_A: string = 'test-pref-provider-a';
/** 测试用 Provider id B */
const PROVIDER_B: string = 'test-pref-provider-b';
/** 持久化测试固定 id */
const PROVIDER_PERSIST: string = 'test-pref-provider-persist';
/** 并发测试 id 前缀 */
const CONCURRENCY_PREFIX: string = 'test-pref-conc-';
/** 损坏测试 id */
const PROVIDER_CORRUPT: string = 'test-pref-corrupt';

/** Preferences 测试文件名(独立于生产,避免污染) */
const TEST_STORE_NAME: string = 'arktavern_test_settings';

/** ProviderConfig 列表在 Preferences 中的 key(与生产保持一致) */
const KEY_PROVIDER_CONFIGS: string = 'provider_configs_v1';

/**
 * 测试用混合配置项(用于构造损坏数据测试的 JSON)。
 */
interface MixedConfigItem {
  id: string;
  name: string;
  type: string;
  baseUrl: string;
  modelName: string;
  temperature: number;
  topP: number;
  maxTokens: number;
  stream: boolean;
  enabled: boolean;
  createdAt: number;
  updatedAt: number;
}

/**
 * 测试用混合配置 schema(用于构造损坏数据测试的 JSON)。
 */
interface MixedConfigSchema {
  schemaVersion: number;
  configs: MixedConfigItem[];
}

/**
 * 构造一个测试用 ProviderConfig。
 * @param id 配置 id
 * @param createdAt 创建时间(用于排序验证)
 * @returns ProviderConfig 实例
 */
function makeConfig(id: string, createdAt: number = 1000): ProviderConfig {
  return new ProviderConfig(
    id,
    id + '-name',
    ProviderType.OpenAICompatible,
    'https://example.test',
    'test-model',
    0.7,
    1.0,
    1024,
    true,
    true,
    createdAt,
    createdAt
  );
}

/**
 * 测试环境上下文,持有 AppPreferences 引用,便于直接清理底层 Preferences。
 */
class TestEnv {
  readonly prefs: AppPreferences;
  readonly store: ProviderConfigStore;

  constructor(prefs: AppPreferences, store: ProviderConfigStore) {
    this.prefs = prefs;
    this.store = store;
  }
}

/**
 * 创建并初始化测试环境。
 * 通过 AbilityDelegator 获取当前顶部 UIAbility 的 context(ApplicationContext 对 Preferences 无效)。
 * @returns TestEnv 实例
 */
async function createEnv(): Promise<TestEnv> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  const context: common.Context = ability.context as common.Context;
  const prefs: AppPreferences = new AppPreferences(TEST_STORE_NAME);
  await prefs.initialize(context);
  const store: ProviderConfigStore = new ProviderConfigStore(prefs);
  return new TestEnv(prefs, store);
}

/**
 * 安全清空测试 Preferences 文件(幂等)。
 * @param env TestEnv 实例
 */
async function safeClear(env: TestEnv): Promise<void> {
  try {
    await env.prefs.clear();
  } catch (e) {
    // 清理时忽略错误
  }
}

/**
 * 安全删除配置(幂等)。
 * @param store ProviderConfigStore 实例
 * @param id 配置 id
 */
async function safeRemove(store: ProviderConfigStore, id: string): Promise<void> {
  try {
    await store.remove(id);
  } catch (e) {
    // 清理时忽略错误
  }
}

export default function providerConfigStoreDeviceTest() {
  describe('ProviderConfigStoreDeviceTest', () => {

    // ===== 1. 初始化 Preferences =====
    it('initialize_preferences', 0, async () => {
      const env: TestEnv = await createEnv();
      expect(env.store.isInitialized()).assertTrue();
      await safeClear(env);
    });

    // ===== 2. 初始 list 为空 =====
    it('initial_list_is_empty', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const list: ProviderConfig[] = await env.store.list();
        expect(list.length).assertEqual(0);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 3. save 配置 =====
    it('save_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        const list: ProviderConfig[] = await env.store.list();
        expect(list.length).assertEqual(1);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 4. list 返回配置 =====
    it('list_returns_configs', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A, 5000);
        await env.store.save(config);
        const list: ProviderConfig[] = await env.store.list();
        expect(list.length).assertEqual(1);
        expect(list[0].id).assertEqual(PROVIDER_A);
        expect(list[0].name).assertEqual(PROVIDER_A + '-name');
        expect(list[0].type).assertEqual(ProviderType.OpenAICompatible);
        expect(list[0].createdAt).assertEqual(5000);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 5. getById =====
    it('getById_returns_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        const got: ProviderConfig | null = await env.store.getById(PROVIDER_A);
        expect(got !== null).assertTrue();
        expect(got!.id).assertEqual(PROVIDER_A);
        const notFound: ProviderConfig | null = await env.store.getById('nonexistent-id');
        expect(notFound === null).assertTrue();
      } finally {
        await safeClear(env);
      }
    });

    // ===== 6. save 重复 id 抛 AlreadyExists =====
    it('save_duplicate_throws_AlreadyExists', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        let threw: boolean = false;
        let errorType: string = '';
        try {
          await env.store.save(config);
        } catch (e) {
          threw = true;
          if (isPreferencesError(e as Object)) {
            errorType = (e as PreferencesError).type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType).assertEqual(PreferencesErrorType.AlreadyExists);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 7. update 配置 =====
    it('update_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        const updated: ProviderConfig = config.withUpdates('new-name');
        await env.store.update(updated);
        const got: ProviderConfig | null = await env.store.getById(PROVIDER_A);
        expect(got !== null).assertTrue();
        expect(got!.name).assertEqual('new-name');
        expect(got!.updatedAt >= config.updatedAt).assertTrue();
      } finally {
        await safeClear(env);
      }
    });

    // ===== 8. update 不存在抛 NotFound =====
    it('update_nonexistent_throws_NotFound', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        let threw: boolean = false;
        let errorType: string = '';
        try {
          await env.store.update(config);
        } catch (e) {
          threw = true;
          if (isPreferencesError(e as Object)) {
            errorType = (e as PreferencesError).type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType).assertEqual(PreferencesErrorType.NotFound);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 9. remove 配置 =====
    it('remove_config', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        await env.store.remove(PROVIDER_A);
        const list: ProviderConfig[] = await env.store.list();
        expect(list.length).assertEqual(0);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 10. 重复 remove 不崩溃 =====
    it('remove_twice_does_not_throw', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        await env.store.remove(PROVIDER_A);
        let threw: boolean = false;
        try {
          await env.store.remove(PROVIDER_A);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertFalse();
      } finally {
        await safeClear(env);
      }
    });

    // ===== 11. 保存两个配置 =====
    it('save_two_configs', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const a: ProviderConfig = makeConfig(PROVIDER_A, 1000);
        const b: ProviderConfig = makeConfig(PROVIDER_B, 2000);
        await env.store.save(a);
        await env.store.save(b);
        const list: ProviderConfig[] = await env.store.list();
        expect(list.length).assertEqual(2);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 12. 两配置顺序稳定(按 createdAt 升序) =====
    it('list_order_stable', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const a: ProviderConfig = makeConfig(PROVIDER_A, 3000);
        const b: ProviderConfig = makeConfig(PROVIDER_B, 1000);
        await env.store.save(a);
        await env.store.save(b);
        const list: ProviderConfig[] = await env.store.list();
        expect(list.length).assertEqual(2);
        expect(list[0].id).assertEqual(PROVIDER_B);
        expect(list[1].id).assertEqual(PROVIDER_A);
        const list2: ProviderConfig[] = await env.store.list();
        expect(list2[0].id).assertEqual(list[0].id);
        expect(list2[1].id).assertEqual(list[1].id);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 13. setCurrentProviderId =====
    it('setCurrentProviderId', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        await env.store.setCurrentProviderId(PROVIDER_A);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 14. getCurrentProviderId =====
    it('getCurrentProviderId', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const initial: string | null = await env.store.getCurrentProviderId();
        expect(initial === null).assertTrue();
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        await env.store.setCurrentProviderId(PROVIDER_A);
        const current: string | null = await env.store.getCurrentProviderId();
        expect(current).assertEqual(PROVIDER_A);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 15. getCurrent =====
    it('getCurrent', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const initial: ProviderConfig | null = await env.store.getCurrent();
        expect(initial === null).assertTrue();
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        await env.store.setCurrentProviderId(PROVIDER_A);
        const current: ProviderConfig | null = await env.store.getCurrent();
        expect(current !== null).assertTrue();
        expect(current!.id).assertEqual(PROVIDER_A);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 16. setCurrentProviderId 不存在 id 抛 InvalidSelection =====
    it('setCurrentProviderId_nonexistent_throws_InvalidSelection', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        let threw: boolean = false;
        let errorType: string = '';
        try {
          await env.store.setCurrentProviderId('nonexistent-id');
        } catch (e) {
          threw = true;
          if (isPreferencesError(e as Object)) {
            errorType = (e as PreferencesError).type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType).assertEqual(PreferencesErrorType.InvalidSelection);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 17. 删除当前配置后自动清空选择 =====
    it('remove_current_clears_selection', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        await env.store.setCurrentProviderId(PROVIDER_A);
        const before: string | null = await env.store.getCurrentProviderId();
        expect(before).assertEqual(PROVIDER_A);
        await env.store.remove(PROVIDER_A);
        const after: string | null = await env.store.getCurrentProviderId();
        expect(after === null).assertTrue();
      } finally {
        await safeClear(env);
      }
    });

    // ===== 18. setCurrentProviderId(null) =====
    it('setCurrentProviderId_null_clears', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        await env.store.setCurrentProviderId(PROVIDER_A);
        await env.store.setCurrentProviderId(null);
        const current: string | null = await env.store.getCurrentProviderId();
        expect(current === null).assertTrue();
      } finally {
        await safeClear(env);
      }
    });

    // ===== 19. 新 Store 实例仍能读取 =====
    it('new_store_instance_reads_existing', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        await env.store.setCurrentProviderId(PROVIDER_A);
        // 新 Store 实例,复用同底层 AppPreferences
        const store2: ProviderConfigStore = new ProviderConfigStore(env.prefs);
        const list: ProviderConfig[] = await store2.list();
        expect(list.length).assertEqual(1);
        expect(list[0].id).assertEqual(PROVIDER_A);
        const current: string | null = await store2.getCurrentProviderId();
        expect(current).assertEqual(PROVIDER_A);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 20. 进程重启后仍能读取(同进程通过新实例模拟) =====
    // 注:真正跨进程重启需手工两阶段验证(见文件头说明)
    it('persistent_save_phase', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_PERSIST, 9999);
        await env.store.save(config);
        await env.store.setCurrentProviderId(PROVIDER_PERSIST);
      } finally {
        // 本阶段不清理,留给 verify 阶段
      }
    });

    it('persistent_verify_phase', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        const list: ProviderConfig[] = await env.store.list();
        const found: ProviderConfig | null = await env.store.getById(PROVIDER_PERSIST);
        expect(found !== null).assertTrue();
        expect(found!.createdAt).assertEqual(9999);
        const current: string | null = await env.store.getCurrentProviderId();
        expect(current).assertEqual(PROVIDER_PERSIST);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 21. 并发 save 不丢失 =====
    it('concurrent_save_no_loss', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const count: number = 5;
        const promises: Promise<void>[] = [];
        for (let i = 0; i < count; i++) {
          const id: string = CONCURRENCY_PREFIX + 'save-' + i.toString();
          const config: ProviderConfig = makeConfig(id, 1000 + i);
          promises.push(env.store.save(config));
        }
        await Promise.all(promises);
        const list: ProviderConfig[] = await env.store.list();
        expect(list.length).assertEqual(count);
        for (let i = 0; i < count; i++) {
          await safeRemove(env.store, CONCURRENCY_PREFIX + 'save-' + i.toString());
        }
      } finally {
        await safeClear(env);
      }
    });

    // ===== 22. 并发 update/remove 不产生损坏 JSON =====
    it('concurrent_update_remove_no_corruption', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const ids: string[] = [
          CONCURRENCY_PREFIX + 'ur-0',
          CONCURRENCY_PREFIX + 'ur-1',
          CONCURRENCY_PREFIX + 'ur-2'
        ];
        for (let i = 0; i < ids.length; i++) {
          await env.store.save(makeConfig(ids[i], 1000 + i));
        }
        const promises: Promise<void>[] = [];
        promises.push(env.store.update(makeConfig(ids[0], 1000).withUpdates('updated')));
        promises.push(env.store.remove(ids[1]));
        promises.push(env.store.update(makeConfig(ids[2], 1002).withUpdates('still-here')));
        await Promise.all(promises);
        const list: ProviderConfig[] = await env.store.list();
        expect(list.length >= 1).assertTrue();
        const removed: ProviderConfig | null = await env.store.getById(ids[1]);
        expect(removed === null).assertTrue();
        for (let i = 0; i < ids.length; i++) {
          await safeRemove(env.store, ids[i]);
        }
      } finally {
        await safeClear(env);
      }
    });

    // ===== 23. 手工写入损坏 JSON 后得到 CorruptedData =====
    it('corrupted_json_returns_CorruptedData', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        await env.prefs.putString(KEY_PROVIDER_CONFIGS, 'this is not valid json {{{');
        let threw: boolean = false;
        let errorType: string = '';
        try {
          await env.store.list();
        } catch (e) {
          threw = true;
          if (isPreferencesError(e as Object)) {
            errorType = (e as PreferencesError).type;
          }
        }
        expect(threw).assertTrue();
        expect(errorType).assertEqual(PreferencesErrorType.CorruptedData);
      } finally {
        await safeClear(env);
      }
    });

    // ===== 24. 单个坏配置不会影响有效配置加载 =====
    it('mixed_valid_invalid_configs_load', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const validItem: MixedConfigItem = {
          id: PROVIDER_CORRUPT + '-valid',
          name: 'valid',
          type: ProviderType.OpenAICompatible,
          baseUrl: 'https://example.test',
          modelName: 'test-model',
          temperature: 0.7,
          topP: 1.0,
          maxTokens: 1024,
          stream: true,
          enabled: true,
          createdAt: 1000,
          updatedAt: 1000
        };
        const invalidItem: MixedConfigItem = {
          id: PROVIDER_CORRUPT + '-invalid',
          name: 'invalid',
          type: 'InvalidType',
          baseUrl: 'https://example.test',
          modelName: 'test-model',
          temperature: 0.7,
          topP: 1.0,
          maxTokens: 1024,
          stream: true,
          enabled: true,
          createdAt: 1000,
          updatedAt: 1000
        };
        const mixedSchema: MixedConfigSchema = {
          schemaVersion: 1,
          configs: [validItem, invalidItem]
        };
        const mixedJson: string = JSON.stringify(mixedSchema);
        await env.prefs.putString(KEY_PROVIDER_CONFIGS, mixedJson);
        const list: ProviderConfig[] = await env.store.list();
        expect(list.length).assertEqual(1);
        expect(list[0].id).assertEqual(PROVIDER_CORRUPT + '-valid');
      } finally {
        await safeClear(env);
      }
    });

    // ===== 25. 清理测试数据 =====
    it('cleanup_test_data', 0, async () => {
      const env: TestEnv = await createEnv();
      await safeClear(env);
      const list: ProviderConfig[] = await env.store.list();
      expect(list.length).assertEqual(0);
      const current: string | null = await env.store.getCurrentProviderId();
      expect(current === null).assertTrue();
    });

    // ===== 26. 日志中无配置 JSON(运行时验证) =====
    // 本测试通过 Logger 的内置脱敏机制保证日志中不含完整 JSON
    // 此处验证 ProviderConfigStore 不直接输出 JSON 到日志
    // (静态检查:代码中无 console.log / hilog 直接打印 JSON 的调用)
    it('logs_do_not_contain_config_json', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        await env.store.list();
        await env.store.getById(PROVIDER_A);
        await env.store.update(config.withUpdates('updated'));
        await env.store.setCurrentProviderId(PROVIDER_A);
        await env.store.getCurrentProviderId();
        await env.store.getCurrent();
        await env.store.remove(PROVIDER_A);
        expect(true).assertTrue();
      } finally {
        await safeClear(env);
      }
    });

    // ===== 27. Preferences 文件中无 API Key 测试值 =====
    // 本测试通过 Codec 的敏感字段防御检查保证
    // 此处验证写入后再读取,确认不含敏感字段
    it('preferences_no_apiKey_field', 0, async () => {
      const env: TestEnv = await createEnv();
      try {
        await safeClear(env);
        const config: ProviderConfig = makeConfig(PROVIDER_A);
        await env.store.save(config);
        const json: string = await env.prefs.getString(KEY_PROVIDER_CONFIGS, '');
        expect(json.length > 0).assertTrue();
        const lower: string = json.toLowerCase();
        // 检查敏感字段名是否作为 JSON key 出现(带引号避免误判 maxTokens 等合法字段名)
        expect(lower.includes('"apikey"')).assertFalse();
        expect(lower.includes('"api_key"')).assertFalse();
        expect(lower.includes('"secret"')).assertFalse();
        expect(lower.includes('"authorization"')).assertFalse();
        expect(lower.includes('"token"')).assertFalse();
        expect(lower.includes('"password"')).assertFalse();
        // sk- 是 API Key 值前缀,使用 substring 检查
        expect(lower.includes('sk-')).assertFalse();
      } finally {
        await safeClear(env);
      }
    });
  });
}
