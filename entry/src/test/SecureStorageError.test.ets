/**
 * SecureStorageError 错误模型单元测试(本地单元测试,无设备依赖)。
 *
 * 覆盖:
 * 1. 平台错误码到 SecureStorageErrorType 的映射纯函数
 * 2. createSecureStorageError 基础构造
 * 3. causeMessage 脱敏(Bearer / sk- token)
 * 4. 默认 retryable 标志
 * 5. fromPlatformError 兜底逻辑
 * 6. SecureStorageErrorTypeMessage 文案
 *
 * 本地测试不导入 Asset Store 设备模块。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  SecureStorageErrorType,
  errorTypeFromPlatformCode,
  createSecureStorageError,
  fromPlatformError,
  SecureStorageErrorTypeMessage
} from '../main/ets/models/SecureStorageError';

export default function secureStorageErrorTest() {
  describe('SecureStorageErrorTest', () => {

    // ===== 平台错误码映射 =====

    it('platform_201_maps_to_AccessDenied', 0, () => {
      expect(errorTypeFromPlatformCode(201)).assertEqual(SecureStorageErrorType.AccessDenied);
    });

    it('platform_401_maps_to_PlatformError', 0, () => {
      expect(errorTypeFromPlatformCode(401)).assertEqual(SecureStorageErrorType.PlatformError);
    });

    it('platform_24000001_maps_to_StorageUnavailable', 0, () => {
      expect(errorTypeFromPlatformCode(24000001)).assertEqual(SecureStorageErrorType.StorageUnavailable);
    });

    it('platform_24000002_maps_to_NotFound', 0, () => {
      expect(errorTypeFromPlatformCode(24000002)).assertEqual(SecureStorageErrorType.NotFound);
    });

    it('platform_24000003_maps_to_AlreadyExists', 0, () => {
      expect(errorTypeFromPlatformCode(24000003)).assertEqual(SecureStorageErrorType.AlreadyExists);
    });

    it('platform_24000004_maps_to_AccessDenied', 0, () => {
      expect(errorTypeFromPlatformCode(24000004)).assertEqual(SecureStorageErrorType.AccessDenied);
    });

    it('platform_24000005_maps_to_DeviceLocked', 0, () => {
      expect(errorTypeFromPlatformCode(24000005)).assertEqual(SecureStorageErrorType.DeviceLocked);
    });

    it('platform_24000006_maps_to_StorageUnavailable', 0, () => {
      expect(errorTypeFromPlatformCode(24000006)).assertEqual(SecureStorageErrorType.StorageUnavailable);
    });

    it('platform_24000007_maps_to_PlatformError', 0, () => {
      expect(errorTypeFromPlatformCode(24000007)).assertEqual(SecureStorageErrorType.PlatformError);
    });

    it('platform_24000008_maps_to_PlatformError', 0, () => {
      expect(errorTypeFromPlatformCode(24000008)).assertEqual(SecureStorageErrorType.PlatformError);
    });

    it('platform_24000009_maps_to_PlatformError', 0, () => {
      expect(errorTypeFromPlatformCode(24000009)).assertEqual(SecureStorageErrorType.PlatformError);
    });

    it('platform_24000010_maps_to_StorageUnavailable', 0, () => {
      expect(errorTypeFromPlatformCode(24000010)).assertEqual(SecureStorageErrorType.StorageUnavailable);
    });

    it('platform_24000011_maps_to_StorageUnavailable', 0, () => {
      expect(errorTypeFromPlatformCode(24000011)).assertEqual(SecureStorageErrorType.StorageUnavailable);
    });

    it('platform_24000012_maps_to_StorageUnavailable', 0, () => {
      expect(errorTypeFromPlatformCode(24000012)).assertEqual(SecureStorageErrorType.StorageUnavailable);
    });

    it('platform_24000013_maps_to_StorageUnavailable', 0, () => {
      expect(errorTypeFromPlatformCode(24000013)).assertEqual(SecureStorageErrorType.StorageUnavailable);
    });

    it('platform_24000014_maps_to_PlatformError', 0, () => {
      expect(errorTypeFromPlatformCode(24000014)).assertEqual(SecureStorageErrorType.PlatformError);
    });

    it('platform_24000015_maps_to_PlatformError', 0, () => {
      expect(errorTypeFromPlatformCode(24000015)).assertEqual(SecureStorageErrorType.PlatformError);
    });

    it('platform_24000016_maps_to_SecretTooLarge', 0, () => {
      expect(errorTypeFromPlatformCode(24000016)).assertEqual(SecureStorageErrorType.SecretTooLarge);
    });

    it('platform_24000017_maps_to_PlatformError', 0, () => {
      expect(errorTypeFromPlatformCode(24000017)).assertEqual(SecureStorageErrorType.PlatformError);
    });

    it('platform_unknown_code_maps_to_Unknown', 0, () => {
      expect(errorTypeFromPlatformCode(99999999)).assertEqual(SecureStorageErrorType.Unknown);
    });

    // ===== createSecureStorageError 基础构造 =====

    it('createSecureStorageError_basic_fields', 0, () => {
      const err = createSecureStorageError(
        SecureStorageErrorType.InvalidAlias,
        'bad alias'
      );
      expect(err.type).assertEqual(SecureStorageErrorType.InvalidAlias);
      expect(err.message).assertEqual('bad alias');
      expect(err.retryable).assertFalse();
      expect(err.platformCode === undefined).assertTrue();
      expect(err.causeMessage === undefined).assertTrue();
    });

    it('createSecureStorageError_with_platformCode', 0, () => {
      const err = createSecureStorageError(
        SecureStorageErrorType.NotFound,
        'not found',
        24000002
      );
      expect(err.platformCode).assertEqual(24000002);
    });

    it('createSecureStorageError_with_causeMessage', 0, () => {
      const err = createSecureStorageError(
        SecureStorageErrorType.PlatformError,
        'platform error',
        24000008,
        'database broken'
      );
      expect(err.causeMessage).assertEqual('database broken');
    });

    // ===== causeMessage 脱敏 =====

    it('createSecureStorageError_redacts_bearer_token', 0, () => {
      const err = createSecureStorageError(
        SecureStorageErrorType.AccessDenied,
        'access denied',
        24000004,
        'Authorization: Bearer sk-abcdef1234567890'
      );
      const cause: string | undefined = err.causeMessage;
      expect(cause !== undefined).assertTrue();
      if (cause !== undefined) {
        expect(cause.includes('[REDACTED]')).assertTrue();
        expect(cause.includes('sk-abcdef1234567890')).assertFalse();
      }
    });

    it('createSecureStorageError_redacts_sk_token', 0, () => {
      const err = createSecureStorageError(
        SecureStorageErrorType.Unknown,
        'unknown',
        undefined,
        'token=sk-abcdefgh123456'
      );
      const cause: string | undefined = err.causeMessage;
      expect(cause !== undefined).assertTrue();
      if (cause !== undefined) {
        expect(cause.includes('[sk-redacted]')).assertTrue();
        expect(cause.includes('sk-abcdefgh123456')).assertFalse();
      }
    });

    it('createSecureStorageError_redacts_both_bearer_and_sk', 0, () => {
      const err = createSecureStorageError(
        SecureStorageErrorType.Unknown,
        'err',
        undefined,
        'Bearer sk-aaa111222333 and sk-bbb444555666'
      );
      const cause: string | undefined = err.causeMessage;
      expect(cause !== undefined).assertTrue();
      if (cause !== undefined) {
        expect(cause.includes('sk-aaa111222333')).assertFalse();
        expect(cause.includes('sk-bbb444555666')).assertFalse();
      }
    });

    // ===== 默认 retryable =====

    it('default_retryable_StorageUnavailable_true', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.StorageUnavailable, 'unavailable');
      expect(err.retryable).assertTrue();
    });

    it('default_retryable_DeviceLocked_true', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.DeviceLocked, 'locked');
      expect(err.retryable).assertTrue();
    });

    it('default_retryable_InvalidAlias_false', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.InvalidAlias, 'bad');
      expect(err.retryable).assertFalse();
    });

    it('default_retryable_InvalidSecret_false', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.InvalidSecret, 'bad');
      expect(err.retryable).assertFalse();
    });

    it('default_retryable_SecretTooLarge_false', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.SecretTooLarge, 'too large');
      expect(err.retryable).assertFalse();
    });

    it('default_retryable_NotFound_false', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.NotFound, 'missing');
      expect(err.retryable).assertFalse();
    });

    it('default_retryable_AlreadyExists_false', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.AlreadyExists, 'dup');
      expect(err.retryable).assertFalse();
    });

    it('default_retryable_AccessDenied_false', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.AccessDenied, 'denied');
      expect(err.retryable).assertFalse();
    });

    it('default_retryable_EncodingFailed_false', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.EncodingFailed, 'enc');
      expect(err.retryable).assertFalse();
    });

    it('default_retryable_PlatformError_false', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.PlatformError, 'platform');
      expect(err.retryable).assertFalse();
    });

    it('default_retryable_Unknown_false', 0, () => {
      const err = createSecureStorageError(SecureStorageErrorType.Unknown, 'unknown');
      expect(err.retryable).assertFalse();
    });

    // ===== fromPlatformError =====

    it('fromPlatformError_uses_mapped_type_for_known_code', 0, () => {
      const err = fromPlatformError(24000002, 'asset not found', SecureStorageErrorType.PlatformError);
      expect(err.type).assertEqual(SecureStorageErrorType.NotFound);
      expect(err.platformCode).assertEqual(24000002);
    });

    it('fromPlatformError_uses_fallback_for_unknown_code', 0, () => {
      const err = fromPlatformError(99999999, 'weird error', SecureStorageErrorType.PlatformError);
      expect(err.type).assertEqual(SecureStorageErrorType.PlatformError);
      expect(err.platformCode).assertEqual(99999999);
    });

    it('fromPlatformError_redacts_message', 0, () => {
      const err = fromPlatformError(24000004, 'Bearer sk-xyz1234567890', SecureStorageErrorType.PlatformError);
      const cause: string | undefined = err.causeMessage;
      expect(cause !== undefined).assertTrue();
      if (cause !== undefined) {
        expect(cause.includes('sk-xyz1234567890')).assertFalse();
      }
    });

    it('fromPlatformError_NOT_FOUND_returns_NotFound_not_fallback', 0, () => {
      // 即便 fallback 为 Unknown,已知错误码应优先返回映射类型
      const err = fromPlatformError(24000003, 'duplicate', SecureStorageErrorType.Unknown);
      expect(err.type).assertEqual(SecureStorageErrorType.AlreadyExists);
    });

    // ===== SecureStorageErrorTypeMessage 文案 =====

    it('SecureStorageErrorTypeMessage_returns_non_empty_for_all_types', 0, () => {
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.InvalidAlias).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.InvalidSecret).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.SecretTooLarge).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.NotFound).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.AlreadyExists).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.AccessDenied).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.DeviceLocked).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.StorageUnavailable).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.EncodingFailed).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.PlatformError).length > 0).assertTrue();
      expect(SecureStorageErrorTypeMessage(SecureStorageErrorType.Unknown).length > 0).assertTrue();
    });

    it('SecureStorageErrorTypeMessage_distinct_for_different_types', 0, () => {
      const m1: string = SecureStorageErrorTypeMessage(SecureStorageErrorType.NotFound);
      const m2: string = SecureStorageErrorTypeMessage(SecureStorageErrorType.AlreadyExists);
      expect(m1 !== m2).assertTrue();
    });
  });
}
