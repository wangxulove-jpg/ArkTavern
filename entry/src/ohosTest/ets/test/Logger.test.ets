/**
 * Logger 脱敏逻辑单元测试(设备测试,ohosTest)。
 * 仅测试纯函数 isSensitiveKey / redactString / redactMap,
 * 不调用依赖 hilog 的 Logger.debug/info/warn/error 方法。
 * Logger 分级输出需在真机/模拟器另行验证。
 */
import { describe, it, expect } from '@ohos/hypium';
import { redactString, redactMap, isSensitiveKey } from '../../../main/ets/utils/Logger';

export default function loggerTest() {
  describe('LoggerTest', () => {
    it('isSensitiveKey_detects_apiKey', 0, () => {
      expect(isSensitiveKey('apiKey')).assertTrue();
    });

    it('isSensitiveKey_detects_api_key', 0, () => {
      expect(isSensitiveKey('api_key')).assertTrue();
    });

    it('isSensitiveKey_detects_Authorization_case_insensitive', 0, () => {
      expect(isSensitiveKey('Authorization')).assertTrue();
      expect(isSensitiveKey('AUTHORIZATION')).assertTrue();
      expect(isSensitiveKey('authorization')).assertTrue();
    });

    it('isSensitiveKey_detects_all_required_sensitive_keys', 0, () => {
      expect(isSensitiveKey('accessToken')).assertTrue();
      expect(isSensitiveKey('refreshToken')).assertTrue();
      expect(isSensitiveKey('secret')).assertTrue();
      expect(isSensitiveKey('password')).assertTrue();
    });

    it('isSensitiveKey_returns_false_for_non_sensitive', 0, () => {
      expect(isSensitiveKey('model')).assertFalse();
      expect(isSensitiveKey('temperature')).assertFalse();
    });

    it('redactString_redacts_Bearer_token', 0, () => {
      const result: string = redactString('Authorization: Bearer abc123.xyz');
      expect(result.includes('[REDACTED]')).assertTrue();
      expect(result.includes('abc123.xyz')).assertFalse();
    });

    it('redactString_redacts_sk_token', 0, () => {
      const result: string = redactString('key is sk-abc1234567890xyz');
      expect(result.includes('[sk-redacted]')).assertTrue();
      expect(result.includes('sk-abc1234567890xyz')).assertFalse();
    });

    it('redactString_redacts_json_apiKey_field', 0, () => {
      const json: string = '{"apiKey":"sk-secret123456","model":"gpt-4"}';
      const result: string = redactString(json);
      expect(result.includes('[REDACTED]')).assertTrue();
      expect(result.includes('sk-secret123456')).assertFalse();
      expect(result.includes('gpt-4')).assertTrue();
    });

    it('redactString_redacts_json_Authorization_field', 0, () => {
      const json: string = '{"Authorization":"Bearer mytoken123"}';
      const result: string = redactString(json);
      expect(result.includes('[REDACTED]')).assertTrue();
      expect(result.includes('mytoken123')).assertFalse();
    });

    it('redactString_redacts_json_password_field', 0, () => {
      const json: string = '{"password":"hunter2"}';
      const result: string = redactString(json);
      expect(result.includes('[REDACTED]')).assertTrue();
      expect(result.includes('hunter2')).assertFalse();
    });

    it('redactString_preserves_non_sensitive_json', 0, () => {
      const json: string = '{"model":"gpt-4","temperature":0.7}';
      const result: string = redactString(json);
      expect(result.includes('gpt-4')).assertTrue();
      expect(result.includes('0.7')).assertTrue();
    });

    it('redactString_handles_non_json_plain_string', 0, () => {
      const result: string = redactString('hello world');
      expect(result.includes('hello')).assertTrue();
      expect(result.includes('world')).assertTrue();
    });

    it('redactMap_redacts_sensitive_keys', 0, () => {
      const map: Record<string, string> = {
        'apiKey': 'sk-secret123456',
        'Authorization': 'Bearer tok',
        'model': 'gpt-4'
      };
      const result: string = redactMap(map);
      expect(result.includes('[REDACTED]')).assertTrue();
      expect(result.includes('sk-secret123456')).assertFalse();
      expect(result.includes('Bearer tok')).assertFalse();
      expect(result.includes('gpt-4')).assertTrue();
    });
  });
}
