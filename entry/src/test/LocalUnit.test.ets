import { describe, it, expect } from '@ohos/hypium';

export default function localUnitSmokeTest() {
  describe('LocalUnitSmoke', () => {
    it('smoke_true', 0, () => {
      expect(true).assertTrue();
    });
  });
}
