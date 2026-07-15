/**
 * Uuid 工具模块单元测试(设备测试,ohosTest)。
 * 测试纯函数 formatUuidV4 与 isUuidV4,不调用依赖 cryptoFramework 的 generateUuid。
 * generateUuid 需在真机/模拟器另行验证。
 */
import { describe, it, expect } from '@ohos/hypium';
import { formatUuidV4, isUuidV4 } from '../../../main/ets/utils/Uuid';

export default function uuidTest() {
  describe('UuidTest', () => {
    it('formatUuidV4_all_zeros_produces_valid_format', 0, () => {
      const zeros: Uint8Array = new Uint8Array(16);
      const uuid: string = formatUuidV4(zeros);
      expect(uuid).assertEqual('00000000-0000-4000-8000-000000000000');
    });

    it('formatUuidV4_sets_version_bit_to_4', 0, () => {
      const bytes: Uint8Array = new Uint8Array(16);
      bytes[6] = 0xFF;
      const uuid: string = formatUuidV4(bytes);
      // version 位位于第 3 段首字符(position 14),必须为 '4'
      const versionChar: string = uuid.charAt(14);
      expect(versionChar).assertEqual('4');
    });

    it('formatUuidV4_sets_variant_bit_to_8_9_a_or_b', 0, () => {
      const bytes: Uint8Array = new Uint8Array(16);
      bytes[8] = 0xFF;
      const uuid: string = formatUuidV4(bytes);
      // variant 位位于第 4 段首字符(position 19),必须为 8/9/a/b 之一
      const variantChar: string = uuid.charAt(19);
      const valid: boolean = variantChar === '8' || variantChar === '9' ||
        variantChar === 'a' || variantChar === 'b';
      expect(valid).assertTrue();
    });

    it('formatUuidV4_throws_on_insufficient_bytes', 0, () => {
      let threw: boolean = false;
      try {
        formatUuidV4(new Uint8Array(15));
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('isUuidV4_accepts_valid_v4', 0, () => {
      expect(isUuidV4('abcdef01-2345-4678-9abc-def012345678')).assertTrue();
    });

    it('isUuidV4_accepts_uppercase_v4', 0, () => {
      expect(isUuidV4('ABCDEF01-2345-4678-9ABC-DEF012345678')).assertTrue();
    });

    it('isUuidV4_accepts_all_zero_v4', 0, () => {
      expect(isUuidV4('00000000-0000-4000-8000-000000000000')).assertTrue();
    });

    it('isUuidV4_rejects_version_3', 0, () => {
      expect(isUuidV4('00000000-0000-3000-8000-000000000000')).assertFalse();
    });

    it('isUuidV4_rejects_bad_variant', 0, () => {
      // variant 位为 '0',不在 8/9/a/b 范围
      expect(isUuidV4('00000000-0000-4000-0000-000000000000')).assertFalse();
    });

    it('isUuidV4_rejects_malformed_string', 0, () => {
      expect(isUuidV4('not-a-uuid')).assertFalse();
    });

    it('isUuidV4_rejects_wrong_length', 0, () => {
      expect(isUuidV4('00000000-0000-4000-8000-0000000000')).assertFalse();
    });
  });
}
