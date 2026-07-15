/**
 * AssetStoreKeyStore 设备集成测试(ohosTest,需真机/模拟器运行)。
 *
 * 验证 Asset Store Kit 在 API 23 真机上的 CRUD 行为。
 * 所有测试 secret 均为假数据,不含真实 API Key,不以 sk- 开头。
 *
 * 验证项:
 * 1. 保存一条 secret
 * 2. 按 alias 读取并完全还原
 * 3. 更新 secret 后读取到新值
 * 4. 删除后读取返回 null
 * 5. 重复删除不崩溃(幂等)
 * 6. 两个 alias 的 secret 互不干扰
 * 7. 重复保存相同 alias 的冲突行为(upsert 覆盖)
 * 8. 空 alias 被拒绝
 * 9. 非法 alias 被拒绝
 * 10. 空 secret 被拒绝
 * 11. 超长 secret 被拒绝
 * 12. 中文 secret 可正确保存和读取
 * 13. Emoji secret 可正确保存和读取
 * 14. 不存在的 alias 返回 null
 * 15. exists 对存在和不存在均正确
 * 16. KeyStore 新实例仍能读取前一个实例保存的数据
 * 17. 应用进程重新启动后仍可读取测试 secret(需手工两阶段验证)
 * 18. 测试完成后清理所有测试数据
 * 19. hilog 中不存在测试 secret(手工 hilog 扫描)
 * 20. 测试失败也会执行清理(每个测试 try/finally 内清理)
 *
 * === 第 17 项手工两阶段验证说明 ===
 * 阶段 A:运行 persistent_save_phase 测试 → 保存固定 secret → 退出应用 → 强制结束进程
 * 阶段 B:重新启动应用 → 运行 persistent_verify_phase 测试 → 读取并验证 → 自动清理
 * 在单次测试套件运行中,两个阶段会顺序执行(同进程内验证 save+read),
 * 跨进程重启验证需按上述步骤手工执行。
 */
import { describe, it, expect } from '@ohos/hypium';
import { AssetStoreKeyStore } from '../../../main/ets/storage/AssetStoreKeyStore';
import { KeyStore, isSecureStorageError } from '../../../main/ets/storage/KeyStore';
import { buildAlias, getMaxSecretBytes } from '../../../main/ets/storage/AliasBuilder';
import { SecureStorageError, SecureStorageErrorType } from '../../../main/ets/models/SecureStorageError';

// ===== 测试常量(均为假数据,非真实 API Key) =====

/** 常规测试 secret */
const SECRET_001: string = 'test-secret-value-001';
/** 第二个测试 secret */
const SECRET_002: string = 'test-secret-value-002';
/** 更新后的 secret */
const SECRET_UPDATED: string = 'test-secret-value-updated-003';
/** 中文测试 secret */
const SECRET_CHINESE: string = '测试密钥-你好世界-001';
/** Emoji 测试 secret */
const SECRET_EMOJI: string = 'test-secret-emoji-🌍🚀-001';
/** 持久化测试固定 secret(用于进程重启验证) */
const SECRET_PERSISTENT: string = 'test-secret-persistent-001';

// ===== 测试用 providerId(每个测试独立,避免互相干扰) =====

const PROVIDER_CRUD: string = 'test-t04-crud';
const PROVIDER_UPDATE: string = 'test-t04-update';
const PROVIDER_REMOVE: string = 'test-t04-remove';
const PROVIDER_DOUBLE_REMOVE: string = 'test-t04-dblrm';
const PROVIDER_ISOLATION_A: string = 'test-t04-iso-a';
const PROVIDER_ISOLATION_B: string = 'test-t04-iso-b';
const PROVIDER_OVERWRITE: string = 'test-t04-overw';
const PROVIDER_CHINESE: string = 'test-t04-cn';
const PROVIDER_EMOJI: string = 'test-t04-emoji';
const PROVIDER_EXISTS: string = 'test-t04-exists';
const PROVIDER_NEW_INSTANCE: string = 'test-t04-newinst';
const PROVIDER_PERSISTENT: string = 'test-t04-persist';

/** 所有测试用 providerId,用于最终清理 */
const ALL_TEST_PROVIDERS: string[] = [
  PROVIDER_CRUD,
  PROVIDER_UPDATE,
  PROVIDER_REMOVE,
  PROVIDER_DOUBLE_REMOVE,
  PROVIDER_ISOLATION_A,
  PROVIDER_ISOLATION_B,
  PROVIDER_OVERWRITE,
  PROVIDER_CHINESE,
  PROVIDER_EMOJI,
  PROVIDER_EXISTS,
  PROVIDER_NEW_INSTANCE,
  PROVIDER_PERSISTENT
];

/**
 * 从 providerId 构建 alias。
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

export default function assetStoreKeyStoreTest() {
  describe('AssetStoreKeyStoreTest', () => {

    // ===== 1 & 2. 保存一条 secret 并按 alias 读取完全还原 =====
    it('save_and_read_secret', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_CRUD);
      try {
        await safeRemove(store, alias);
        await store.save(alias, SECRET_001);
        const read: string | null = await store.read(alias);
        expect(read).assertEqual(SECRET_001);
      } finally {
        await safeRemove(store, alias);
      }
    });

    // ===== 3. 更新 secret 后读取到新值 =====
    it('update_secret_returns_new_value', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_UPDATE);
      try {
        await safeRemove(store, alias);
        await store.save(alias, SECRET_001);
        await store.update(alias, SECRET_UPDATED);
        const read: string | null = await store.read(alias);
        expect(read).assertEqual(SECRET_UPDATED);
      } finally {
        await safeRemove(store, alias);
      }
    });

    // ===== 4. 删除后读取返回 null =====
    it('remove_then_read_returns_null', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_REMOVE);
      try {
        await safeRemove(store, alias);
        await store.save(alias, SECRET_001);
        await store.remove(alias);
        const read: string | null = await store.read(alias);
        expect(read === null).assertTrue();
      } finally {
        await safeRemove(store, alias);
      }
    });

    // ===== 5. 重复删除不崩溃(幂等) =====
    it('remove_twice_does_not_throw', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_DOUBLE_REMOVE);
      try {
        await safeRemove(store, alias);
        await store.save(alias, SECRET_001);
        await store.remove(alias);
        // 第二次删除(幂等,不应抛异常)
        let threw: boolean = false;
        try {
          await store.remove(alias);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertFalse();
      } finally {
        await safeRemove(store, alias);
      }
    });

    // ===== 6. 两个 alias 的 secret 互不干扰 =====
    it('two_aliases_isolated', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const aliasA: string = aliasFor(PROVIDER_ISOLATION_A);
      const aliasB: string = aliasFor(PROVIDER_ISOLATION_B);
      try {
        await safeRemove(store, aliasA);
        await safeRemove(store, aliasB);
        await store.save(aliasA, SECRET_001);
        await store.save(aliasB, SECRET_002);
        const readA: string | null = await store.read(aliasA);
        const readB: string | null = await store.read(aliasB);
        expect(readA).assertEqual(SECRET_001);
        expect(readB).assertEqual(SECRET_002);
        expect(readA !== readB).assertTrue();
      } finally {
        await safeRemove(store, aliasA);
        await safeRemove(store, aliasB);
      }
    });

    // ===== 7. 重复保存相同 alias 的冲突行为(upsert 覆盖) =====
    it('save_twice_overwrites', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_OVERWRITE);
      try {
        await safeRemove(store, alias);
        await store.save(alias, SECRET_001);
        await store.save(alias, SECRET_002);
        const read: string | null = await store.read(alias);
        expect(read).assertEqual(SECRET_002);
      } finally {
        await safeRemove(store, alias);
      }
    });

    // ===== 8. 空 alias 被拒绝 =====
    it('empty_alias_rejected', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.save('', SECRET_001);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.InvalidAlias);
    });

    // ===== 9. 非法 alias 被拒绝 =====
    it('invalid_alias_rejected', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        // 不符合 arktavern.provider.<id>.api-key 格式
        await store.save('invalid-alias', SECRET_001);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.InvalidAlias);
    });

    // ===== 10. 空 secret 被拒绝 =====
    it('empty_secret_rejected', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_CRUD);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.save(alias, '');
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.InvalidSecret);
    });

    // ===== 11. 超长 secret 被拒绝 =====
    it('oversized_secret_rejected', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_CRUD);
      // 构造超过 MAX_SECRET_BYTES 的字符串
      const max: number = getMaxSecretBytes();
      let oversized: string = '';
      for (let i = 0; i < max + 1; i++) {
        oversized += 'a';
      }
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.save(alias, oversized);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.SecretTooLarge);
    });

    // ===== 12. 中文 secret 可正确保存和读取 =====
    it('chinese_secret_saved_and_read', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_CHINESE);
      try {
        await safeRemove(store, alias);
        await store.save(alias, SECRET_CHINESE);
        const read: string | null = await store.read(alias);
        expect(read).assertEqual(SECRET_CHINESE);
      } finally {
        await safeRemove(store, alias);
      }
    });

    // ===== 13. Emoji secret 可正确保存和读取 =====
    it('emoji_secret_saved_and_read', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_EMOJI);
      try {
        await safeRemove(store, alias);
        await store.save(alias, SECRET_EMOJI);
        const read: string | null = await store.read(alias);
        expect(read).assertEqual(SECRET_EMOJI);
      } finally {
        await safeRemove(store, alias);
      }
    });

    // ===== 14. 不存在的 alias 返回 null =====
    it('read_nonexistent_returns_null', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_CRUD);
      // 确保不存在
      await safeRemove(store, alias);
      const read: string | null = await store.read(alias);
      expect(read === null).assertTrue();
    });

    // ===== 15. exists 对存在和不存在均正确 =====
    it('exists_returns_correct_value', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_EXISTS);
      try {
        await safeRemove(store, alias);
        // 不存在时返回 false
        const existsBefore: boolean = await store.exists(alias);
        expect(existsBefore).assertFalse();
        // 保存后返回 true
        await store.save(alias, SECRET_001);
        const existsAfter: boolean = await store.exists(alias);
        expect(existsAfter).assertTrue();
        // 删除后返回 false
        await store.remove(alias);
        const existsAfterRemove: boolean = await store.exists(alias);
        expect(existsAfterRemove).assertFalse();
      } finally {
        await safeRemove(store, alias);
      }
    });

    // ===== 16. KeyStore 新实例仍能读取前一个实例保存的数据 =====
    it('new_instance_reads_previous_data', 0, async () => {
      const alias: string = aliasFor(PROVIDER_NEW_INSTANCE);
      // 第一个实例保存
      const store1: AssetStoreKeyStore = new AssetStoreKeyStore();
      try {
        await safeRemove(store1, alias);
        await store1.save(alias, SECRET_001);
        // 第二个实例读取
        const store2: AssetStoreKeyStore = new AssetStoreKeyStore();
        const read: string | null = await store2.read(alias);
        expect(read).assertEqual(SECRET_001);
      } finally {
        await safeRemove(store1, alias);
      }
    });

    // ===== 17A. 持久化测试 - 保存阶段 =====
    // 手工两阶段验证:
    //   阶段 A(本测试):保存固定 secret,不删除,退出应用并强制结束进程。
    //   阶段 B(persistent_verify_phase 测试):重启应用后读取同一 alias,验证内容,清理。
    it('persistent_save_phase', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_PERSISTENT);
      // 注意:此处不使用 try/finally 删除,以保留数据用于跨进程验证
      await store.save(alias, SECRET_PERSISTENT);
      // 同进程内立即验证
      const read: string | null = await store.read(alias);
      expect(read).assertEqual(SECRET_PERSISTENT);
    });

    // ===== 17B. 持久化测试 - 验证阶段(单次运行内验证;跨进程需手工) =====
    // 在单次测试套件运行中,本测试验证 save_phase 保存的数据可被读取。
    // 跨进程重启验证:先运行 persistent_save_phase → 杀进程 → 重启 → 运行本测试。
    it('persistent_verify_phase', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_PERSISTENT);
      try {
        const read: string | null = await store.read(alias);
        expect(read).assertEqual(SECRET_PERSISTENT);
      } finally {
        // 验证完成后清理持久化测试数据
        await safeRemove(store, alias);
      }
    });

    // ===== 18. 测试完成后清理所有测试数据 =====
    // 作为安全网,确保即使个别测试失败,所有测试 alias 都被清理。
    it('cleanup_all_test_data', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      for (let i = 0; i < ALL_TEST_PROVIDERS.length; i++) {
        const alias: string = aliasFor(ALL_TEST_PROVIDERS[i]);
        await safeRemove(store, alias);
        // 验证已删除
        const exists: boolean = await store.exists(alias);
        expect(exists).assertFalse();
      }
    });

    // ===== 附加验证:isSecureStorageError 类型守卫 =====
    it('isSecureStorageError_type_guard_works', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      let caughtError: Object | null = null;
      try {
        await store.save('', SECRET_001);
      } catch (e) {
        caughtError = e as Object;
      }
      expect(caughtError !== null).assertTrue();
      if (caughtError !== null) {
        expect(isSecureStorageError(caughtError)).assertTrue();
      }
    });

    // ===== 附加验证:update 不存在的 alias 抛 NotFound =====
    it('update_nonexistent_throws_NotFound', 0, async () => {
      const store: AssetStoreKeyStore = new AssetStoreKeyStore();
      const alias: string = aliasFor(PROVIDER_UPDATE);
      await safeRemove(store, alias);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.update(alias, SECRET_001);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.NotFound);
    });
  });
}
