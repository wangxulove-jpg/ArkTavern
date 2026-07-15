/**
 * NetworkError 网络错误模型单元测试(本地单元测试,无设备依赖)。
 * 覆盖 HTTP 状态码到错误类型的映射、Cancelled 与 Timeout 的区分、
 * 以及 createNetworkError 对 causeMessage 的脱敏。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  NetworkErrorType,
  errorTypeFromStatusCode,
  createNetworkError
} from '../main/ets/models/NetworkError';

export default function networkErrorTest() {
  describe('NetworkErrorTest', () => {
    it('400_maps_to_InvalidRequest', 0, () => {
      expect(errorTypeFromStatusCode(400)).assertEqual(NetworkErrorType.InvalidRequest);
    });

    it('401_maps_to_Authentication', 0, () => {
      expect(errorTypeFromStatusCode(401)).assertEqual(NetworkErrorType.Authentication);
    });

    it('403_maps_to_Authentication', 0, () => {
      expect(errorTypeFromStatusCode(403)).assertEqual(NetworkErrorType.Authentication);
    });

    it('408_maps_to_Timeout', 0, () => {
      expect(errorTypeFromStatusCode(408)).assertEqual(NetworkErrorType.Timeout);
    });

    it('429_maps_to_RateLimit', 0, () => {
      expect(errorTypeFromStatusCode(429)).assertEqual(NetworkErrorType.RateLimit);
    });

    it('500_maps_to_Server', 0, () => {
      expect(errorTypeFromStatusCode(500)).assertEqual(NetworkErrorType.Server);
    });

    it('599_maps_to_Server', 0, () => {
      expect(errorTypeFromStatusCode(599)).assertEqual(NetworkErrorType.Server);
    });

    it('200_maps_to_Unknown', 0, () => {
      expect(errorTypeFromStatusCode(200)).assertEqual(NetworkErrorType.Unknown);
    });

    it('Cancelled_differs_from_Timeout', 0, () => {
      expect(NetworkErrorType.Cancelled).not().assertEqual(NetworkErrorType.Timeout);
    });

    it('createNetworkError_redacts_causeMessage_bearer', 0, () => {
      const err = createNetworkError(
        NetworkErrorType.Authentication,
        'auth failed',
        { causeMessage: 'Bearer sk-abc1234567890' }
      );
      const cause: string | undefined = err.causeMessage;
      expect(cause !== undefined).assertTrue();
      if (cause !== undefined) {
        expect(cause.includes('[REDACTED]')).assertTrue();
        expect(cause.includes('sk-abc1234567890')).assertFalse();
      }
    });

    it('createNetworkError_redacts_causeMessage_sk_token', 0, () => {
      const err = createNetworkError(
        NetworkErrorType.Unknown,
        'error',
        { causeMessage: 'token=sk-abcdefgh1234' }
      );
      const cause: string | undefined = err.causeMessage;
      expect(cause !== undefined).assertTrue();
      if (cause !== undefined) {
        expect(cause.includes('[sk-redacted]')).assertTrue();
        expect(cause.includes('sk-abcdefgh1234')).assertFalse();
      }
    });

    it('createNetworkError_default_retryable_Server_true', 0, () => {
      const err = createNetworkError(NetworkErrorType.Server, 'server error');
      expect(err.retryable).assertTrue();
    });

    it('createNetworkError_default_retryable_Authentication_false', 0, () => {
      const err = createNetworkError(NetworkErrorType.Authentication, 'auth error');
      expect(err.retryable).assertFalse();
    });

    it('createNetworkError_default_retryable_Cancelled_false', 0, () => {
      const err = createNetworkError(NetworkErrorType.Cancelled, 'cancelled');
      expect(err.retryable).assertFalse();
    });

    it('createNetworkError_custom_retryable_overrides_default', 0, () => {
      const err = createNetworkError(
        NetworkErrorType.Server,
        'server error',
        { retryable: false }
      );
      expect(err.retryable).assertFalse();
    });

    it('createNetworkError_no_causeMessage_when_omitted', 0, () => {
      const err = createNetworkError(NetworkErrorType.Network, 'net error');
      expect(err.causeMessage === undefined).assertTrue();
    });
  });
}
