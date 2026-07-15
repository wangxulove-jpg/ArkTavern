/**
 * AliasBuilder 纯逻辑单元测试(本地单元测试,无设备依赖)。
 *
 * 覆盖:
 * 1. 正常 alias 构建
 * 2. 不同 providerId 生成不同 alias
 * 3. 空 providerId
 * 4. providerId 包含斜杠
 * 5. providerId 包含换行
 * 6. providerId 过长
 * 7. alias 长度边界
 * 8. secret 空字符串验证
 * 9. secret 字节长度边界
 * 10. 中文的 UTF-8 字节长度
 * 11. Emoji 的 UTF-8 字节长度
 *
 * 本地测试不导入 Asset Store 设备模块。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  buildAlias,
  isValidAlias,
  isValidProviderId,
  isValidSecret,
  utf8ByteLength,
  getMaxSecretBytes,
  getMaxAliasLength
} from '../main/ets/storage/AliasBuilder';

export default function aliasBuilderTest() {
  describe('AliasBuilderTest', () => {

    // ===== alias 构建 =====

    it('buildAlias_normal_providerId', 0, () => {
      const result = buildAlias('provider-001');
      expect(result.success).assertTrue();
      expect(result.alias).assertEqual('arktavern.provider.provider-001.api-key');
      expect(result.error).assertEqual('');
    });

    it('buildAlias_supports_uuid_providerId', 0, () => {
      const uuid: string = '550e8400-e29b-41d4-a716-446655440000';
      const result = buildAlias(uuid);
      expect(result.success).assertTrue();
      expect(result.alias).assertEqual('arktavern.provider.' + uuid + '.api-key');
    });

    it('buildAlias_supports_alphanumeric_and_separators', 0, () => {
      // 允许字符:a-z A-Z 0-9 . - _
      const result = buildAlias('Ab.12-cd_EF');
      expect(result.success).assertTrue();
    });

    it('buildAlias_different_providerIds_produce_different_aliases', 0, () => {
      const r1 = buildAlias('provider-A');
      const r2 = buildAlias('provider-B');
      expect(r1.success).assertTrue();
      expect(r2.success).assertTrue();
      expect(r1.alias !== r2.alias).assertTrue();
    });

    // ===== providerId 校验失败场景 =====

    it('buildAlias_rejects_empty_providerId', 0, () => {
      const result = buildAlias('');
      expect(result.success).assertFalse();
      expect(result.alias).assertEqual('');
      expect(result.error.includes('empty')).assertTrue();
    });

    it('isValidProviderId_rejects_empty', 0, () => {
      expect(isValidProviderId('')).assertFalse();
    });

    it('buildAlias_rejects_slash_in_providerId', 0, () => {
      const result = buildAlias('provider/001');
      expect(result.success).assertFalse();
      expect(result.error.includes('invalid characters')).assertTrue();
    });

    it('isValidProviderId_rejects_slash', 0, () => {
      expect(isValidProviderId('a/b')).assertFalse();
    });

    it('buildAlias_rejects_newline_in_providerId', 0, () => {
      const result = buildAlias('provider\n001');
      expect(result.success).assertFalse();
    });

    it('isValidProviderId_rejects_newline', 0, () => {
      expect(isValidProviderId('a\nb')).assertFalse();
    });

    it('buildAlias_rejects_space_in_providerId', 0, () => {
      const result = buildAlias('provider 001');
      expect(result.success).assertFalse();
    });

    it('buildAlias_rejects_path_chars_in_providerId', 0, () => {
      // 反斜杠、冒号、星号等路径字符应被拒绝
      expect(buildAlias('a\\b').success).assertFalse();
      expect(buildAlias('a:b').success).assertFalse();
      expect(buildAlias('a*b').success).assertFalse();
      expect(buildAlias('a?b').success).assertFalse();
      expect(buildAlias('a"b').success).assertFalse();
      expect(buildAlias('a<b').success).assertFalse();
      expect(buildAlias('a>b').success).assertFalse();
      expect(buildAlias('a|b').success).assertFalse();
    });

    it('buildAlias_rejects_control_chars_in_providerId', 0, () => {
      // 制表符、回车等控制字符应被拒绝
      expect(buildAlias('a\tb').success).assertFalse();
      expect(buildAlias('a\rb').success).assertFalse();
      expect(buildAlias('a\u0000b').success).assertFalse();
    });

    it('buildAlias_rejects_overlong_providerId', 0, () => {
      // 构造长度超过 64 的 providerId
      let longId: string = '';
      for (let i = 0; i < 65; i++) {
        longId += 'a';
      }
      const result = buildAlias(longId);
      expect(result.success).assertFalse();
      expect(result.error.includes('too long')).assertTrue();
    });

    it('isValidProviderId_accepts_max_length', 0, () => {
      // 64 字符长度应被接受(边界值)
      let id: string = '';
      for (let i = 0; i < 64; i++) {
        id += 'a';
      }
      expect(isValidProviderId(id)).assertTrue();
    });

    // ===== alias 长度边界 =====

    it('isValidAlias_rejects_empty', 0, () => {
      expect(isValidAlias('')).assertFalse();
    });

    it('isValidAlias_rejects_missing_prefix', 0, () => {
      expect(isValidAlias('foo.provider-001.api-key')).assertFalse();
    });

    it('isValidAlias_rejects_missing_suffix', 0, () => {
      expect(isValidAlias('arktavern.provider.foo')).assertFalse();
    });

    it('isValidAlias_rejects_invalid_chars', 0, () => {
      expect(isValidAlias('arktavern.provider.a/b.api-key')).assertFalse();
    });

    it('isValidAlias_accepts_built_alias', 0, () => {
      const result = buildAlias('provider-001');
      expect(isValidAlias(result.alias)).assertTrue();
    });

    it('isValidAlias_rejects_overlong_alias', 0, () => {
      // 构造长度超过 128 的 alias
      let longId: string = '';
      for (let i = 0; i < 100; i++) {
        longId += 'a';
      }
      const alias: string = 'arktavern.provider.' + longId + '.api-key';
      expect(alias.length > getMaxAliasLength()).assertTrue();
      expect(isValidAlias(alias)).assertFalse();
    });

    it('getMaxAliasLength_returns_positive', 0, () => {
      expect(getMaxAliasLength() > 0).assertTrue();
    });

    // ===== secret 校验 =====

    it('isValidSecret_rejects_empty', 0, () => {
      expect(isValidSecret('')).assertFalse();
    });

    it('isValidSecret_accepts_normal_string', 0, () => {
      expect(isValidSecret('test-secret-value-001')).assertTrue();
    });

    it('isValidSecret_accepts_max_bytes_boundary', 0, () => {
      // 构造正好等于 MAX_SECRET_BYTES 的 ASCII 字符串
      const max: number = getMaxSecretBytes();
      let s: string = '';
      for (let i = 0; i < max; i++) {
        s += 'a';
      }
      expect(utf8ByteLength(s)).assertEqual(max);
      expect(isValidSecret(s)).assertTrue();
    });

    it('isValidSecret_rejects_above_max_bytes', 0, () => {
      const max: number = getMaxSecretBytes();
      let s: string = '';
      for (let i = 0; i < max + 1; i++) {
        s += 'a';
      }
      expect(isValidSecret(s)).assertFalse();
    });

    it('getMaxSecretBytes_returns_positive', 0, () => {
      expect(getMaxSecretBytes() > 0).assertTrue();
    });

    // ===== UTF-8 字节长度计算 =====

    it('utf8ByteLength_ascii_1_byte_per_char', 0, () => {
      expect(utf8ByteLength('')).assertEqual(0);
      expect(utf8ByteLength('a')).assertEqual(1);
      expect(utf8ByteLength('abc')).assertEqual(3);
      expect(utf8ByteLength('ABC123')).assertEqual(6);
    });

    it('utf8ByteLength_latin_2_bytes', 0, () => {
      // U+00E9 (é) 在 UTF-8 中为 2 字节
      expect(utf8ByteLength('é')).assertEqual(2);
      expect(utf8ByteLength('café')).assertEqual(5); // 3*1 + 1*2
    });

    it('utf8ByteLength_chinese_3_bytes', 0, () => {
      // 基本多文种平面汉字 U+4F60 (你) 在 UTF-8 中为 3 字节
      expect(utf8ByteLength('你')).assertEqual(3);
      expect(utf8ByteLength('你好世界')).assertEqual(12); // 4 个汉字 * 3 字节
    });

    it('utf8ByteLength_emoji_4_bytes_surrogate_pair', 0, () => {
      // 😀 U+1F600 在 UTF-16 中为代理对(2 个 char),UTF-8 中为 4 字节
      expect('😀'.length).assertEqual(2); // 确认是代理对
      expect(utf8ByteLength('😀')).assertEqual(4);
      expect(utf8ByteLength('🌍🚀')).assertEqual(8);
    });

    it('utf8ByteLength_mixed_content', 0, () => {
      // a + 你 + 😀 = 1 + 3 + 4 = 8 字节
      expect(utf8ByteLength('a你😀')).assertEqual(8);
    });

    it('utf8ByteLength_secret_within_limit', 0, () => {
      // 常见 API Key 长度应在限制内
      const fakeKey: string = 'test-secret-value-001-ABCDEFGHIJ';
      expect(utf8ByteLength(fakeKey) < getMaxSecretBytes()).assertTrue();
      expect(isValidSecret(fakeKey)).assertTrue();
    });
  });
}
