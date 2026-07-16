/**
 * ProviderKeyStore 设备集成测试(ohosTest,需真机/模拟器运行)。
 *
 * 使用 AssetStoreKeyStore → ProviderKeyStore 验证多 Provider 密钥管理在 API 23 真机上的行为。
 * 所有测试 secret 均为假数据,不含真实 API Key,不以 sk- 开头。
 *
 * 验证项:
 * 1. Provider A 保存并读取
 * 2. Provider B 保存并读取
 * 3. A/B 密钥隔离
 * 4. 同一 ProviderType 的两个 config id 隔离
 * 5. 更新 A 不影响 B
 * 6. 删除 A 后 B 仍存在
 * 7. 新 ProviderKeyStore 实例仍可读取
 * 8. 应用进程重启后仍可读取(手工两阶段验证)
 * 9. remove 幂等
 * 10. 所有测试结束后清理资产
 * 11. hilog 中不存在测试 secret(手工 hilog 扫描)
 * 12. 测试失败时也执行清理(每个测试 try/finally 内清理)
 *
 * === 第 8 项手工两阶段验证说明 ===
 * 阶段 A:运行 persistent_save_phase 测试 → 保存固定 secret → 退出应用 → 强制结束进程
 * 阶段 B:重新启动应用 → 运行 persistent_verify_phase 测试 → 读取并验证 → 自动清理
 * 在单次测试套件运行中,两个阶段会顺序执行(同进程内验证 save+read),
 * 跨进程重启验证需按上述步骤手工执行。
 */
import { describe, it, expect } from '@ohos/hypium';
import { AssetStoreKeyStore } from '../../../main/ets/storage/AssetStoreKeyStore';
import { ProviderKeyStore } from '../../../main/ets/storage/ProviderKeyStore';
import { KeyStore } from '../../../main/ets/storage/KeyStore';
import { buildAlias } from '../../../main/ets/storage/AliasBuilder';
import { SecureStorageError, SecureStorageErrorType } from '../../../main/ets/models/SecureStorageError';

// ===== 测试常量(均为假数据,非真实 API Key,不以 sk- 开头) =====

/** 常规测试 secret */
const KEY_A: string = 'provider-key-test-value-001';
/** 第二个测试 secret */
const KEY_B: string = 'provider-key-test-value-002';
/** 更新后的 secret */
const KEY_UPDATED: string = 'provider-key-test-value-updated-003';
/** 持久化测试固定 secret(用于进程重启验证) */
const KEY_PERSISTENT: string = 'provider-key-test-value-persistent-004';

// ===== 测试用 providerId(每个测试独立,避免互相干扰) =====

const PROVIDER_A: string = 'test-t12-pa';
const PROVIDER_B: string = 'test-t12-pb';
const PROVIDER_SAME_TYPE_A: string = 'test-t12-sta';
const PROVIDER_SAME_TYPE_B: string = 'test-t12-stb';
const PROVIDER_UPDATE: string = 'test-t12-upd';
const PROVIDER_REMOVE: string = 'test-t12-rm';
const PROVIDER_DOUBLE_REMOVE: string = 'test-t12-dblrm';
const PROVIDER_REPLACE_NEW: string = 'test-t12-repnew';
const PROVIDER_REPLACE_UPDATE: string = 'test-t12-repupd';
const PROVIDER_NEW_INSTANCE: string = 'test-t12-newinst';
const PROVIDER_PERSISTENT: string = 'test-t12-persist';
const PROVIDER_HAS_KEY: string = 'test-t12-haskey';
const PROVIDER_READ_NONEXIST: string = 'test-t12-rdne';

/** 所有测试用 providerId,用于最终清理 */
const ALL_TEST_PROVIDERS: string[] = [
  PROVIDER_A,
  PROVIDER_B,
  PROVIDER_SAME_TYPE_A,
  PROVIDER_SAME_TYPE_B,
  PROVIDER_UPDATE,
  PROVIDER_REMOVE,
  PROVIDER_DOUBLE_REMOVE,
  PROVIDER_REPLACE_NEW,
  PROVIDER_REPLACE_UPDATE,
  PROVIDER_NEW_INSTANCE,
  PROVIDER_PERSISTENT,
  PROVIDER_HAS_KEY,
  PROVIDER_READ_NONEXIST
];

/**
 * 从 providerId 构建 alias(用于底层清理)。
 * @param providerId Provider ID
 * @returns 构建出的 alias
 */
function aliasFor(providerId: string): string {
  const result = buildAlias(providerId);
  if (!result.success) {
    throw new Error('Failed to build test alias for providerId=' + providerId + ': ' + result.error);
  }
  return result.alias;
}

/**
 * 安全删除 alias(幂等,不抛异常)。用于测试前清理和测试后清理。
 * @param store KeyStore 实例
 * @param alias 待删除的 alias
 */
async function safeRemove(store: KeyStore, alias: string): Promise<void> {
  try {
    await store.remove(alias);
  } catch (e) {
    // 清理时忽略错误
  }
}

/**
 * 清理所有测试 providerId 的密钥。
 * @param store KeyStore 实例
 */
async function cleanupAll(store: KeyStore): Promise<void> {
  for (let i = 0; i < ALL_TEST_PROVIDERS.length; i++) {
    const alias: string = aliasFor(ALL_TEST_PROVIDERS[i]);
    await safeRemove(store, alias);
  }
}

export default function providerKeyStoreDeviceTest() {
  describe('ProviderKeyStoreDeviceTest', () => {

    // ===== 1. Provider A 保存并读取 =====
    it('provider_A_save_and_read', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const alias: string = aliasFor(PROVIDER_A);
      try {
        await safeRemove(keyStore, alias);
        await store.saveKey(PROVIDER_A, KEY_A);
        const read: string | null = await store.readKey(PROVIDER_A);
        expect(read).assertEqual(KEY_A);
      } finally {
        await safeRemove(keyStore, alias);
      }
    });

    // ===== 2. Provider B 保存并读取 =====
    it('provider_B_save_and_read', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const alias: string = aliasFor(PROVIDER_B);
      try {
        await safeRemove(keyStore, alias);
        await store.saveKey(PROVIDER_B, KEY_B);
        const read: string | null = await store.readKey(PROVIDER_B);
        expect(read).assertEqual(KEY_B);
      } finally {
        await safeRemove(keyStore, alias);
      }
    });

    // ===== 3. A/B 密钥隔离 =====
    it('provider_A_B_isolated', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const aliasA: string = aliasFor(PROVIDER_A);
      const aliasB: string = aliasFor(PROVIDER_B);
      try {
        await safeRemove(keyStore, aliasA);
        await safeRemove(keyStore, aliasB);
        await store.saveKey(PROVIDER_A, KEY_A);
        await store.saveKey(PROVIDER_B, KEY_B);
        const readA: string | null = await store.readKey(PROVIDER_A);
        const readB: string | null = await store.readKey(PROVIDER_B);
        expect(readA).assertEqual(KEY_A);
        expect(readB).assertEqual(KEY_B);
        expect(readA !== readB).assertTrue();
      } finally {
        await safeRemove(keyStore, aliasA);
        await safeRemove(keyStore, aliasB);
      }
    });

    // ===== 4. 同一 ProviderType 的两个 config id 隔离 =====
    it('same_providerType_different_configIds_isolated', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const aliasA: string = aliasFor(PROVIDER_SAME_TYPE_A);
      const aliasB: string = aliasFor(PROVIDER_SAME_TYPE_B);
      try {
        await safeRemove(keyStore, aliasA);
        await safeRemove(keyStore, aliasB);
        await store.saveKey(PROVIDER_SAME_TYPE_A, KEY_A);
        await store.saveKey(PROVIDER_SAME_TYPE_B, KEY_B);
        const readA: string | null = await store.readKey(PROVIDER_SAME_TYPE_A);
        const readB: string | null = await store.readKey(PROVIDER_SAME_TYPE_B);
        expect(readA).assertEqual(KEY_A);
        expect(readB).assertEqual(KEY_B);
      } finally {
        await safeRemove(keyStore, aliasA);
        await safeRemove(keyStore, aliasB);
      }
    });

    // ===== 5. 更新 A 不影响 B =====
    it('update_A_does_not_affect_B', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const aliasA: string = aliasFor(PROVIDER_UPDATE);
      const aliasB: string = aliasFor(PROVIDER_B);
      try {
        await safeRemove(keyStore, aliasA);
        await safeRemove(keyStore, aliasB);
        await store.saveKey(PROVIDER_UPDATE, KEY_A);
        await store.saveKey(PROVIDER_B, KEY_B);
        await store.updateKey(PROVIDER_UPDATE, KEY_UPDATED);
        const readA: string | null = await store.readKey(PROVIDER_UPDATE);
        const readB: string | null = await store.readKey(PROVIDER_B);
        expect(readA).assertEqual(KEY_UPDATED);
        expect(readB).assertEqual(KEY_B);
      } finally {
        await safeRemove(keyStore, aliasA);
        await safeRemove(keyStore, aliasB);
      }
    });

    // ===== 6. 删除 A 后 B 仍存在 =====
    it('remove_A_leaves_B_intact', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const aliasA: string = aliasFor(PROVIDER_REMOVE);
      const aliasB: string = aliasFor(PROVIDER_B);
      try {
        await safeRemove(keyStore, aliasA);
        await safeRemove(keyStore, aliasB);
        await store.saveKey(PROVIDER_REMOVE, KEY_A);
        await store.saveKey(PROVIDER_B, KEY_B);
        await store.removeKey(PROVIDER_REMOVE);
        const hasA: boolean = await store.hasKey(PROVIDER_REMOVE);
        const hasB: boolean = await store.hasKey(PROVIDER_B);
        expect(hasA).assertFalse();
        expect(hasB).assertTrue();
      } finally {
        await safeRemove(keyStore, aliasA);
        await safeRemove(keyStore, aliasB);
      }
    });

    // ===== 7. 新 ProviderKeyStore 实例仍可读取 =====
    it('new_instance_reads_previous_data', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_NEW_INSTANCE);
      try {
        await safeRemove(keyStore, alias);
        const store1: ProviderKeyStore = new ProviderKeyStore(keyStore);
        await store1.saveKey(PROVIDER_NEW_INSTANCE, KEY_A);
        // 新实例读取(同一 keyStore 实例)
        const store2: ProviderKeyStore = new ProviderKeyStore(keyStore);
        const read: string | null = await store2.readKey(PROVIDER_NEW_INSTANCE);
        expect(read).assertEqual(KEY_A);
        // 新 keyStore + 新 ProviderKeyStore 读取
        const keyStore2: AssetStoreKeyStore = new AssetStoreKeyStore();
        const store3: ProviderKeyStore = new ProviderKeyStore(keyStore2);
        const read2: string | null = await store3.readKey(PROVIDER_NEW_INSTANCE);
        expect(read2).assertEqual(KEY_A);
      } finally {
        await safeRemove(keyStore, alias);
      }
    });

    // ===== 8A. 持久化测试 - 保存阶段 =====
    // 手工两阶段验证:
    //   阶段 A(本测试):保存固定 secret,不删除,退出应用并强制结束进程。
    //   阶段 B(persistent_verify_phase 测试):重启应用后读取同一 providerId,验证内容,清理。
    it('persistent_save_phase', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      // 注意:此处不使用 try/finally 删除,以保留数据用于跨进程验证
      await store.saveKey(PROVIDER_PERSISTENT, KEY_PERSISTENT);
      // 同进程内立即验证
      const read: string | null = await store.readKey(PROVIDER_PERSISTENT);
      expect(read).assertEqual(KEY_PERSISTENT);
    });

    // ===== 8B. 持久化测试 - 验证阶段(单次运行内验证;跨进程需手工) =====
    it('persistent_verify_phase', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const alias: string = aliasFor(PROVIDER_PERSISTENT);
      try {
        const read: string | null = await store.readKey(PROVIDER_PERSISTENT);
        expect(read).assertEqual(KEY_PERSISTENT);
      } finally {
        // 验证完成后清理持久化测试数据
        await safeRemove(keyStore, alias);
      }
    });

    // ===== 9. remove 幂等 =====
    it('remove_twice_does_not_throw', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const alias: string = aliasFor(PROVIDER_DOUBLE_REMOVE);
      try {
        await safeRemove(keyStore, alias);
        await store.saveKey(PROVIDER_DOUBLE_REMOVE, KEY_A);
        await store.removeKey(PROVIDER_DOUBLE_REMOVE);
        // 第二次删除(幂等,不应抛异常)
        let threw: boolean = false;
        try {
          await store.removeKey(PROVIDER_DOUBLE_REMOVE);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertFalse();
      } finally {
        await safeRemove(keyStore, alias);
      }
    });

    // ===== 附加:replaceKey 新增 =====
    it('replaceKey_creates_when_absent', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const alias: string = aliasFor(PROVIDER_REPLACE_NEW);
      try {
        await safeRemove(keyStore, alias);
        await store.replaceKey(PROVIDER_REPLACE_NEW, KEY_A);
        const read: string | null = await store.readKey(PROVIDER_REPLACE_NEW);
        expect(read).assertEqual(KEY_A);
      } finally {
        await safeRemove(keyStore, alias);
      }
    });

    // ===== 附加:replaceKey 更新 =====
    it('replaceKey_updates_when_present', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const alias: string = aliasFor(PROVIDER_REPLACE_UPDATE);
      try {
        await safeRemove(keyStore, alias);
        await store.saveKey(PROVIDER_REPLACE_UPDATE, KEY_A);
        await store.replaceKey(PROVIDER_REPLACE_UPDATE, KEY_UPDATED);
        const read: string | null = await store.readKey(PROVIDER_REPLACE_UPDATE);
        expect(read).assertEqual(KEY_UPDATED);
      } finally {
        await safeRemove(keyStore, alias);
      }
    });

    // ===== 附加:hasKey 对存在和不存在均正确 =====
    it('hasKey_returns_correct_value', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const alias: string = aliasFor(PROVIDER_HAS_KEY);
      try {
        await safeRemove(keyStore, alias);
        // 不存在时返回 false
        const hasBefore: boolean = await store.hasKey(PROVIDER_HAS_KEY);
        expect(hasBefore).assertFalse();
        // 保存后返回 true
        await store.saveKey(PROVIDER_HAS_KEY, KEY_A);
        const hasAfter: boolean = await store.hasKey(PROVIDER_HAS_KEY);
        expect(hasAfter).assertTrue();
        // 删除后返回 false
        await store.removeKey(PROVIDER_HAS_KEY);
        const hasAfterRemove: boolean = await store.hasKey(PROVIDER_HAS_KEY);
        expect(hasAfterRemove).assertFalse();
      } finally {
        await safeRemove(keyStore, alias);
      }
    });

    // ===== 附加:readKey 不存在返回 null =====
    it('readKey_nonexistent_returns_null', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const alias: string = aliasFor(PROVIDER_READ_NONEXIST);
      await safeRemove(keyStore, alias);
      const read: string | null = await store.readKey(PROVIDER_READ_NONEXIST);
      expect(read === null).assertTrue();
    });

    // ===== 附加:updateKey 不存在抛 NotFound =====
    it('updateKey_nonexistent_throws_NotFound', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      const alias: string = aliasFor(PROVIDER_UPDATE);
      await safeRemove(keyStore, alias);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.updateKey(PROVIDER_UPDATE, KEY_A);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.NotFound);
    });

    // ===== 附加:空 providerId 被拒绝 =====
    it('empty_providerId_rejected', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.saveKey('', KEY_A);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.InvalidAlias);
    });

    // ===== 附加:空 apiKey 被拒绝 =====
    it('empty_apiKey_rejected', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(keyStore);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.saveKey(PROVIDER_A, '');
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.InvalidSecret);
    });

    // ===== 10. 所有测试结束后清理资产 =====
    // 作为安全网,确保即使个别测试失败,所有测试 alias 都被清理。
    it('cleanup_all_test_data', 0, async () => {
      const keyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
      await cleanupAll(keyStore);
      // 验证已删除
      for (let i = 0; i < ALL_TEST_PROVIDERS.length; i++) {
        const alias: string = aliasFor(ALL_TEST_PROVIDERS[i]);
        const exists: boolean = await keyStore.exists(alias);
        expect(exists).assertFalse();
      }
    });
  });
}
