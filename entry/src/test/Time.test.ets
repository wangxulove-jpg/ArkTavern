/**
 * Time 工具模块单元测试(本地单元测试,无设备依赖)。
 */
import { describe, it, expect } from '@ohos/hypium';
import { nowMillis, nowIso, millisToIso } from '../main/ets/utils/Time';

export default function timeTest() {
  describe('TimeTest', () => {
    it('nowMillis_returns_positive_number', 0, () => {
      const ms: number = nowMillis();
      expect(ms > 0).assertTrue();
    });

    it('nowIso_returns_iso_format_ending_with_Z', 0, () => {
      const iso: string = nowIso();
      expect(iso.endsWith('Z')).assertTrue();
    });

    it('millisToIso_converts_epoch_zero', 0, () => {
      const iso: string = millisToIso(0);
      expect(iso).assertEqual('1970-01-01T00:00:00.000Z');
    });

    it('millisToIso_converts_known_timestamp', 0, () => {
      // 2024-01-01T00:00:00.000Z 对应毫秒时间戳
      const iso: string = millisToIso(1704067200000);
      expect(iso).assertEqual('2024-01-01T00:00:00.000Z');
    });

    it('millisToIso_throws_on_NaN', 0, () => {
      let threw: boolean = false;
      try {
        millisToIso(NaN);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('millisToIso_throws_on_Infinity', 0, () => {
      let threw: boolean = false;
      try {
        millisToIso(Infinity);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('millisToIso_throws_on_negative_Infinity', 0, () => {
      let threw: boolean = false;
      try {
        millisToIso(-Infinity);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });
  });
}
