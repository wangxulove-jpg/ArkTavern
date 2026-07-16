/**
 * ProviderKeyStore 本地单元测试(无设备依赖)。
 *
 * 使用内存 MockKeyStore 验证 ProviderKeyStore 的业务行为。
 * MockKeyStore 仅位于测试目录,不进入 main。
 * 不模拟密码学,仅验证 ProviderKeyStore 的业务逻辑。
 *
 * 覆盖项:
 * 1. 正常 saveKey
 * 2. save 后 readKey
 * 3. updateKey
 * 4. replaceKey 新增
 * 5. replaceKey 更新
 * 6. removeKey
 * 7. 重复 remove(幂等)
 * 8. hasKey true
 * 9. hasKey false
 * 10. 两个 providerId 相互隔离
 * 11. 同一 ProviderType 的不同配置 id 相互隔离(语义等同第 10 项,此处显式注释)
 * 12. 空 providerId
 * 13. 非法 providerId
 * 14. 空 apiKey
 * 15. 仅空白 apiKey
 * 16. API Key 原始内容不被 trim 修改
 * 17. 底层 NotFound 语义正确传播
 * 18. 底层 StorageUnavailable 语义正确传播
 * 19. ProviderKeyStore 不暴露 alias(编译时保证,运行时验证方法签名)
 * 20. ProviderKeyStore 不持有明文缓存(通过修改底层验证 read 从底层读取)
 */
import { describe, it, expect } from '@ohos/hypium';
import { KeyStore } from '../main/ets/storage/KeyStore';
import { ProviderKeyStore } from '../main/ets/storage/ProviderKeyStore';
import { SecureStorageError, SecureStorageErrorType, createSecureStorageError } from '../main/ets/models/SecureStorageError';

// ===== 仅用于测试的内存 KeyStore 实现(不进入 main) =====

/**
 * 内存 KeyStore 实现,用于本地单元测试。
 * 模拟 save/read/update/remove/exists 语义,不模拟密码学。
 * 可通过标志位强制抛出特定错误,以验证错误传播。
 */
class MockKeyStore extends KeyStore {
  private store: Map<string, string> = new Map<string, string>();
  /** 设置为 true 后,所有操作抛 StorageUnavailable */
  public forceUnavailable: boolean = false;

  async save(alias: string, secret: string): Promise<void> {
    if (this.forceUnavailable) {
      throw createSecureStorageError(
        SecureStorageErrorType.StorageUnavailable,
        'mock unavailable',
        undefined,
        undefined
      );
    }
    this.store.set(alias, secret);
  }

  async read(alias: string): Promise<string | null> {
    if (this.forceUnavailable) {
      throw createSecureStorageError(
        SecureStorageErrorType.StorageUnavailable,
        'mock unavailable',
        undefined,
        undefined
      );
    }
    if (!this.store.has(alias)) {
      return null;
    }
    return this.store.get(alias) as string;
  }

  async update(alias: string, secret: string): Promise<void> {
    if (this.forceUnavailable) {
      throw createSecureStorageError(
        SecureStorageErrorType.StorageUnavailable,
        'mock unavailable',
        undefined,
        undefined
      );
    }
    if (!this.store.has(alias)) {
      throw createSecureStorageError(
        SecureStorageErrorType.NotFound,
        'mock not found',
        undefined,
        undefined
      );
    }
    this.store.set(alias, secret);
  }

  async remove(alias: string): Promise<void> {
    if (this.forceUnavailable) {
      throw createSecureStorageError(
        SecureStorageErrorType.StorageUnavailable,
        'mock unavailable',
        undefined,
        undefined
      );
    }
    this.store.delete(alias);
  }

  async exists(alias: string): Promise<boolean> {
    if (this.forceUnavailable) {
      throw createSecureStorageError(
        SecureStorageErrorType.StorageUnavailable,
        'mock unavailable',
        undefined,
        undefined
      );
    }
    return this.store.has(alias);
  }

  /** 测试辅助:直接写入底层存储(模拟其他进程写入) */
  rawSet(alias: string, secret: string): void {
    this.store.set(alias, secret);
  }

  /** 测试辅助:清空所有数据 */
  clear(): void {
    this.store.clear();
  }
}

// ===== 测试常量(均为假数据,非真实 API Key,不以 sk- 开头) =====

const PROVIDER_A: string = 'provider-unit-a-001';
const PROVIDER_B: string = 'provider-unit-b-002';
const PROVIDER_SAME_TYPE_A: string = 'provider-sametype-a-003';
const PROVIDER_SAME_TYPE_B: string = 'provider-sametype-b-004';
const KEY_001: string = 'provider-key-test-value-001';
const KEY_002: string = 'provider-key-test-value-002';
const KEY_UPDATED: string = 'provider-key-test-value-updated-003';

export default function providerKeyStoreTest() {
  describe('ProviderKeyStoreTest', () => {

    // ===== 1 & 2. 正常 saveKey + save 后 readKey =====
    it('saveKey_then_readKey_returns_same', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      const read: string | null = await store.readKey(PROVIDER_A);
      expect(read).assertEqual(KEY_001);
    });

    // ===== 3. updateKey =====
    it('updateKey_changes_value', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      await store.updateKey(PROVIDER_A, KEY_UPDATED);
      const read: string | null = await store.readKey(PROVIDER_A);
      expect(read).assertEqual(KEY_UPDATED);
    });

    // ===== 3b. updateKey 不存在抛 NotFound =====
    it('updateKey_nonexistent_throws_NotFound', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.updateKey(PROVIDER_B, KEY_001);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.NotFound);
    });

    // ===== 4. replaceKey 新增 =====
    it('replaceKey_creates_when_absent', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      const hasBefore: boolean = await store.hasKey(PROVIDER_A);
      expect(hasBefore).assertFalse();
      await store.replaceKey(PROVIDER_A, KEY_001);
      const hasAfter: boolean = await store.hasKey(PROVIDER_A);
      expect(hasAfter).assertTrue();
      const read: string | null = await store.readKey(PROVIDER_A);
      expect(read).assertEqual(KEY_001);
    });

    // ===== 5. replaceKey 更新 =====
    it('replaceKey_updates_when_present', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      await store.replaceKey(PROVIDER_A, KEY_UPDATED);
      const read: string | null = await store.readKey(PROVIDER_A);
      expect(read).assertEqual(KEY_UPDATED);
    });

    // ===== 6. removeKey =====
    it('removeKey_deletes_value', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      await store.removeKey(PROVIDER_A);
      const read: string | null = await store.readKey(PROVIDER_A);
      expect(read === null).assertTrue();
    });

    // ===== 7. 重复 remove(幂等) =====
    it('removeKey_twice_does_not_throw', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      await store.removeKey(PROVIDER_A);
      let threw: boolean = false;
      try {
        await store.removeKey(PROVIDER_A);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();
    });

    // ===== 8. hasKey true =====
    it('hasKey_returns_true_when_present', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      const has: boolean = await store.hasKey(PROVIDER_A);
      expect(has).assertTrue();
    });

    // ===== 9. hasKey false =====
    it('hasKey_returns_false_when_absent', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      const has: boolean = await store.hasKey(PROVIDER_A);
      expect(has).assertFalse();
    });

    // ===== 10. 两个 providerId 相互隔离 =====
    it('two_providerIds_isolated', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      await store.saveKey(PROVIDER_B, KEY_002);
      const readA: string | null = await store.readKey(PROVIDER_A);
      const readB: string | null = await store.readKey(PROVIDER_B);
      expect(readA).assertEqual(KEY_001);
      expect(readB).assertEqual(KEY_002);
      expect(readA !== readB).assertTrue();
    });

    // ===== 11. 同一 ProviderType 的不同配置 id 相互隔离 =====
    // 说明:ProviderKeyStore 按 providerId(配置 id)而非 ProviderType 管理密钥。
    // 两个同类型配置(如两个 OpenAICompatible 配置)使用不同 id,密钥完全隔离。
    it('same_providerType_different_configIds_isolated', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_SAME_TYPE_A, KEY_001);
      await store.saveKey(PROVIDER_SAME_TYPE_B, KEY_002);
      const readA: string | null = await store.readKey(PROVIDER_SAME_TYPE_A);
      const readB: string | null = await store.readKey(PROVIDER_SAME_TYPE_B);
      expect(readA).assertEqual(KEY_001);
      expect(readB).assertEqual(KEY_002);
    });

    // ===== 10b. 更新 A 不影响 B =====
    it('update_A_does_not_affect_B', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      await store.saveKey(PROVIDER_B, KEY_002);
      await store.updateKey(PROVIDER_A, KEY_UPDATED);
      const readA: string | null = await store.readKey(PROVIDER_A);
      const readB: string | null = await store.readKey(PROVIDER_B);
      expect(readA).assertEqual(KEY_UPDATED);
      expect(readB).assertEqual(KEY_002);
    });

    // ===== 10c. 删除 A 后 B 仍存在 =====
    it('remove_A_leaves_B_intact', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      await store.saveKey(PROVIDER_B, KEY_002);
      await store.removeKey(PROVIDER_A);
      const hasA: boolean = await store.hasKey(PROVIDER_A);
      const hasB: boolean = await store.hasKey(PROVIDER_B);
      expect(hasA).assertFalse();
      expect(hasB).assertTrue();
    });

    // ===== 12. 空 providerId =====
    it('empty_providerId_rejected', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.saveKey('', KEY_001);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.InvalidAlias);
    });

    // ===== 13. 非法 providerId(含斜杠) =====
    it('invalid_providerId_rejected', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.saveKey('provider/invalid', KEY_001);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.InvalidAlias);
    });

    // ===== 13b. 非法 providerId(含空格) =====
    it('providerId_with_space_rejected', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      try {
        await store.saveKey('provider invalid', KEY_001);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // ===== 14. 空 apiKey =====
    it('empty_apiKey_rejected', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
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

    // ===== 15. 仅空白 apiKey =====
    it('whitespace_only_apiKey_rejected', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.saveKey(PROVIDER_A, '   ');
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.InvalidSecret);
    });

    // ===== 15b. 仅空白 apiKey 对 replaceKey 也生效 =====
    it('whitespace_only_apiKey_rejected_for_replaceKey', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      try {
        await store.replaceKey(PROVIDER_A, '\t\n ');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // ===== 16. API Key 原始内容不被 trim 修改 =====
    it('apiKey_not_trimmed', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      // 前后有空格但中间有内容,不应被拒绝,也不应被 trim
      const keyWithSpaces: string = '  ' + KEY_001 + '  ';
      await store.saveKey(PROVIDER_A, keyWithSpaces);
      const read: string | null = await store.readKey(PROVIDER_A);
      expect(read).assertEqual(keyWithSpaces);
    });

    // ===== 17. 底层 NotFound 语义正确传播(updateKey) =====
    it('updateKey_propagates_NotFound', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.updateKey(PROVIDER_A, KEY_001);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.NotFound);
    });

    // ===== 18. 底层 StorageUnavailable 语义正确传播 =====
    it('StorageUnavailable_propagates_from_save', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      mock.forceUnavailable = true;
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      let errorType: SecureStorageErrorType = SecureStorageErrorType.Unknown;
      try {
        await store.saveKey(PROVIDER_A, KEY_001);
      } catch (e) {
        threw = true;
        const err: SecureStorageError = e as SecureStorageError;
        errorType = err.type;
      }
      expect(threw).assertTrue();
      expect(errorType).assertEqual(SecureStorageErrorType.StorageUnavailable);
    });

    // ===== 18b. StorageUnavailable 从 readKey 传播 =====
    it('StorageUnavailable_propagates_from_read', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      mock.forceUnavailable = true;
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      try {
        await store.readKey(PROVIDER_A);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // ===== 18c. StorageUnavailable 从 hasKey 传播(不返回 false 掩盖) =====
    it('hasKey_propagates_StorageUnavailable', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      mock.forceUnavailable = true;
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      try {
        await store.hasKey(PROVIDER_A);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // ===== 18d. StorageUnavailable 从 removeKey 传播 =====
    it('StorageUnavailable_propagates_from_remove', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      mock.forceUnavailable = true;
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      let threw: boolean = false;
      try {
        await store.removeKey(PROVIDER_A);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // ===== 19. ProviderKeyStore 不暴露 alias =====
    // 验证方式:ProviderKeyStore 的公共方法签名只接受 providerId,不返回 alias。
    // 此处通过类型系统在编译时保证,运行时验证 readKey 不返回 alias。
    it('ProviderKeyStore_does_not_expose_alias', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      // readKey 返回的是 apiKey,不是 alias
      const read: string | null = await store.readKey(PROVIDER_A);
      expect(read).assertEqual(KEY_001);
      // 返回值不应包含 'arktavern.provider' 前缀(alias 格式)
      if (read !== null) {
        expect(read.includes('arktavern.provider')).assertFalse();
      }
    });

    // ===== 20. ProviderKeyStore 不持有明文缓存 =====
    // 验证方式:save 后直接修改 MockKeyStore 内部存储,readKey 应返回修改后的值。
    // 证明 ProviderKeyStore 没有缓存密钥,每次都从底层读取。
    it('ProviderKeyStore_does_not_cache', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store: ProviderKeyStore = new ProviderKeyStore(mock);
      await store.saveKey(PROVIDER_A, KEY_001);
      // 直接修改底层存储(模拟另一进程或直接操作)
      const alias: string = 'arktavern.provider.' + PROVIDER_A + '.api-key';
      mock.rawSet(alias, KEY_002);
      // readKey 应返回修改后的值,证明没有缓存
      const read: string | null = await store.readKey(PROVIDER_A);
      expect(read).assertEqual(KEY_002);
    });

    // ===== 20b. 新 ProviderKeyStore 实例仍可读取 =====
    it('new_instance_reads_previous_data', 0, async () => {
      const mock: MockKeyStore = new MockKeyStore();
      const store1: ProviderKeyStore = new ProviderKeyStore(mock);
      await store1.saveKey(PROVIDER_A, KEY_001);
      // 新实例(同一 MockKeyStore)读取
      const store2: ProviderKeyStore = new ProviderKeyStore(mock);
      const read: string | null = await store2.readKey(PROVIDER_A);
      expect(read).assertEqual(KEY_001);
    });
  });
}
