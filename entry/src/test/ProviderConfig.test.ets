/**
 * ProviderConfig 与聊天消息模型本地单元测试
 *
 * 覆盖:
 * 1. ProviderConfig 默认值
 * 2. temperature 最小值
 * 3. temperature 最大值
 * 4. 非法 temperature
 * 5. topP 边界
 * 6. maxTokens 边界
 * 7. 空 id
 * 8. 空配置名称
 * 9. 空 Base URL
 * 10. 空 Model
 * 11. ProviderConfig 不包含 API Key 字段
 * 12. ChatMessage 正常创建
 * 13. ChatRequest 正常创建
 * 14. 消息数组顺序保持不变
 * 15. 默认 stream=true
 */

import { describe, it, expect } from '@ohos/hypium';
import { ProviderType } from '../main/ets/models/ProviderType';
import {
  ProviderConfig,
  TEMPERATURE_MIN,
  TEMPERATURE_MAX,
  TEMPERATURE_DEFAULT,
  TOP_P_MIN,
  TOP_P_MAX,
  TOP_P_DEFAULT,
  MAX_TOKENS_MIN,
  MAX_TOKENS_MAX,
  MAX_TOKENS_DEFAULT,
  STREAM_DEFAULT,
  ENABLED_DEFAULT,
  isValidTemperature,
  isValidTopP,
  isValidMaxTokens,
  isValidId,
  isValidName,
  isValidBaseUrl,
  isValidModelName
} from '../main/ets/models/ProviderConfig';
import { ChatRole } from '../main/ets/models/ChatRole';
import { ChatMessage, createChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRequest, createChatRequest } from '../main/ets/models/ChatRequest';

export default function providerConfigTest() {
  describe('ProviderConfigTest', () => {
    // ===== 1. ProviderConfig 默认值 =====
    it('create_returns_default_values', 0, () => {
      const config: ProviderConfig = ProviderConfig.create(
        'test-id', 'Test Provider', ProviderType.OpenAICompatible,
        'https://api.example.com', 'gpt-4'
      );
      expect(config.temperature).assertEqual(TEMPERATURE_DEFAULT);
      expect(config.topP).assertEqual(TOP_P_DEFAULT);
      expect(config.maxTokens).assertEqual(MAX_TOKENS_DEFAULT);
      expect(config.stream).assertEqual(STREAM_DEFAULT);
      expect(config.enabled).assertEqual(ENABLED_DEFAULT);
      expect(config.createdAt > 0).assertTrue();
      expect(config.updatedAt > 0).assertTrue();
      expect(config.createdAt === config.updatedAt).assertTrue();
    });

    // ===== 2. temperature 最小值 =====
    it('temperature_min_is_valid', 0, () => {
      expect(isValidTemperature(TEMPERATURE_MIN)).assertTrue();
    });

    // ===== 3. temperature 最大值 =====
    it('temperature_max_is_valid', 0, () => {
      expect(isValidTemperature(TEMPERATURE_MAX)).assertTrue();
    });

    // ===== 4. 非法 temperature =====
    it('temperature_below_min_is_invalid', 0, () => {
      expect(isValidTemperature(TEMPERATURE_MIN - 0.1)).assertFalse();
    });

    it('temperature_above_max_is_invalid', 0, () => {
      expect(isValidTemperature(TEMPERATURE_MAX + 0.1)).assertFalse();
    });

    it('temperature_nan_is_invalid', 0, () => {
      expect(isValidTemperature(NaN)).assertFalse();
    });

    // ===== 5. topP 边界 =====
    it('topP_min_is_valid', 0, () => {
      expect(isValidTopP(TOP_P_MIN)).assertTrue();
    });

    it('topP_max_is_valid', 0, () => {
      expect(isValidTopP(TOP_P_MAX)).assertTrue();
    });

    it('topP_below_min_is_invalid', 0, () => {
      expect(isValidTopP(TOP_P_MIN - 0.01)).assertFalse();
    });

    it('topP_above_max_is_invalid', 0, () => {
      expect(isValidTopP(TOP_P_MAX + 0.01)).assertFalse();
    });

    // ===== 6. maxTokens 边界 =====
    it('maxTokens_min_is_valid', 0, () => {
      expect(isValidMaxTokens(MAX_TOKENS_MIN)).assertTrue();
    });

    it('maxTokens_max_is_valid', 0, () => {
      expect(isValidMaxTokens(MAX_TOKENS_MAX)).assertTrue();
    });

    it('maxTokens_below_min_is_invalid', 0, () => {
      expect(isValidMaxTokens(MAX_TOKENS_MIN - 1)).assertFalse();
    });

    it('maxTokens_above_max_is_invalid', 0, () => {
      expect(isValidMaxTokens(MAX_TOKENS_MAX + 1)).assertFalse();
    });

    it('maxTokens_non_integer_is_invalid', 0, () => {
      expect(isValidMaxTokens(1.5)).assertFalse();
    });

    // ===== 7. 空 id =====
    it('empty_id_is_invalid', 0, () => {
      expect(isValidId('')).assertFalse();
    });

    it('non_empty_id_is_valid', 0, () => {
      expect(isValidId('test-id')).assertTrue();
    });

    // ===== 8. 空配置名称 =====
    it('empty_name_is_invalid', 0, () => {
      expect(isValidName('')).assertFalse();
    });

    it('non_empty_name_is_valid', 0, () => {
      expect(isValidName('Test Provider')).assertTrue();
    });

    // ===== 9. 空 Base URL =====
    it('empty_baseUrl_is_invalid', 0, () => {
      expect(isValidBaseUrl('')).assertFalse();
    });

    it('non_empty_baseUrl_is_valid', 0, () => {
      expect(isValidBaseUrl('https://api.example.com')).assertTrue();
    });

    // ===== 10. 空 Model =====
    it('empty_modelName_is_invalid', 0, () => {
      expect(isValidModelName('')).assertFalse();
    });

    it('non_empty_modelName_is_valid', 0, () => {
      expect(isValidModelName('gpt-4')).assertTrue();
    });

    // ===== 11. ProviderConfig 不包含 API Key 字段 =====
    it('config_does_not_contain_apiKey_field', 0, () => {
      const config: ProviderConfig = ProviderConfig.create(
        'test-id', 'Test', ProviderType.OpenAICompatible,
        'https://api.example.com', 'gpt-4'
      );
      const configJson: string = JSON.stringify(config);
      expect(configJson.includes('apiKey')).assertFalse();
      expect(configJson.includes('api_key')).assertFalse();
      expect(configJson.includes('Authorization')).assertFalse();
      expect(configJson.includes('Bearer')).assertFalse();
      expect(configJson.includes('secret')).assertFalse();
      expect(configJson.includes('sk-')).assertFalse();
    });

    // ===== withUpdates 测试 =====
    it('withUpdates_creates_new_instance_with_changed_fields', 0, () => {
      const original: ProviderConfig = ProviderConfig.create(
        'test-id', 'Test', ProviderType.OpenAICompatible,
        'https://api.example.com', 'gpt-4'
      );
      const updated: ProviderConfig = original.withUpdates(
        'New Name', undefined, undefined, 'gpt-4-turbo', 0.5
      );
      expect(updated.name).assertEqual('New Name');
      expect(updated.modelName).assertEqual('gpt-4-turbo');
      expect(updated.temperature).assertEqual(0.5);
      // 未修改的字段保持不变
      expect(updated.type).assertEqual(ProviderType.OpenAICompatible);
      expect(updated.baseUrl).assertEqual('https://api.example.com');
      expect(updated.id).assertEqual(original.id);
      expect(updated.createdAt).assertEqual(original.createdAt);
      // updatedAt 应刷新
      expect(updated.updatedAt >= original.updatedAt).assertTrue();
    });

    it('withUpdates_preserves_original_instance', 0, () => {
      const original: ProviderConfig = ProviderConfig.create(
        'test-id', 'Test', ProviderType.OpenAICompatible,
        'https://api.example.com', 'gpt-4'
      );
      const originalName: string = original.name;
      const updated: ProviderConfig = original.withUpdates('New Name');
      // 原实例不受影响(不可变)
      expect(original.name).assertEqual(originalName);
      expect(updated.name).assertEqual('New Name');
    });

    // ===== ProviderType 枚举测试 =====
    it('providerType_all_values_distinct', 0, () => {
      const types: ProviderType[] = [
        ProviderType.OpenAICompatible,
        ProviderType.OpenAI,
        ProviderType.DeepSeek,
        ProviderType.OpenRouter,
        ProviderType.Claude,
        ProviderType.Gemini
      ];
      const values: string[] = types.map((t: ProviderType) => t.toString());
      const uniqueValues: Set<string> = new Set(values);
      expect(uniqueValues.size).assertEqual(types.length);
    });

    // ===== ChatRole 枚举测试 =====
    it('chatRole_values_match_openai_format', 0, () => {
      expect(ChatRole.System).assertEqual('system');
      expect(ChatRole.User).assertEqual('user');
      expect(ChatRole.Assistant).assertEqual('assistant');
    });

    // ===== 12. ChatMessage 正常创建 =====
    it('createChatMessage_returns_valid_message', 0, () => {
      const msg: ChatMessage = createChatMessage(
        'msg-001', ChatRole.User, 'Hello', 1700000000000
      );
      expect(msg.id).assertEqual('msg-001');
      expect(msg.role).assertEqual(ChatRole.User);
      expect(msg.content).assertEqual('Hello');
      expect(msg.createdAt).assertEqual(1700000000000);
      // 可选字段未设置
      expect(msg.updatedAt === undefined).assertTrue();
      expect(msg.isStreaming === undefined).assertTrue();
      expect(msg.errorMessage === undefined).assertTrue();
    });

    // ===== 13. ChatRequest 正常创建 =====
    it('createChatRequest_returns_valid_request', 0, () => {
      const msgs: ChatMessage[] = [
        createChatMessage('msg-001', ChatRole.System, 'You are helpful', 1700000000000),
        createChatMessage('msg-002', ChatRole.User, 'Hi', 1700000000001)
      ];
      const req: ChatRequest = createChatRequest('gpt-4', msgs);
      expect(req.model).assertEqual('gpt-4');
      expect(req.messages.length).assertEqual(2);
      expect(req.temperature).assertEqual(TEMPERATURE_DEFAULT);
      expect(req.topP).assertEqual(TOP_P_DEFAULT);
      expect(req.maxTokens).assertEqual(MAX_TOKENS_DEFAULT);
    });

    // ===== 14. 消息数组顺序保持不变 =====
    it('chatRequest_preserves_message_order', 0, () => {
      const msgs: ChatMessage[] = [
        createChatMessage('msg-001', ChatRole.System, 'System prompt', 1700000000000),
        createChatMessage('msg-002', ChatRole.User, 'User message', 1700000000001),
        createChatMessage('msg-003', ChatRole.Assistant, 'Assistant reply', 1700000000002),
        createChatMessage('msg-004', ChatRole.User, 'Second user message', 1700000000003)
      ];
      const req: ChatRequest = createChatRequest('gpt-4', msgs);
      expect(req.messages[0].id).assertEqual('msg-001');
      expect(req.messages[1].id).assertEqual('msg-002');
      expect(req.messages[2].id).assertEqual('msg-003');
      expect(req.messages[3].id).assertEqual('msg-004');
      expect(req.messages[0].role).assertEqual(ChatRole.System);
      expect(req.messages[3].role).assertEqual(ChatRole.User);
    });

    // ===== 15. 默认 stream=true =====
    it('createChatRequest_default_stream_is_true', 0, () => {
      const msgs: ChatMessage[] = [
        createChatMessage('msg-001', ChatRole.User, 'Hi', 1700000000000)
      ];
      const req: ChatRequest = createChatRequest('gpt-4', msgs);
      expect(req.stream).assertTrue();
    });

    it('providerConfig_default_stream_is_true', 0, () => {
      const config: ProviderConfig = ProviderConfig.create(
        'test-id', 'Test', ProviderType.OpenAICompatible,
        'https://api.example.com', 'gpt-4'
      );
      expect(config.stream).assertTrue();
    });

    // ===== ChatRequest 不包含敏感字段 =====
    it('chatRequest_does_not_contain_sensitive_fields', 0, () => {
      const msgs: ChatMessage[] = [
        createChatMessage('msg-001', ChatRole.User, 'Hi', 1700000000000)
      ];
      const req: ChatRequest = createChatRequest('gpt-4', msgs);
      const reqJson: string = JSON.stringify(req);
      expect(reqJson.includes('apiKey')).assertFalse();
      expect(reqJson.includes('Authorization')).assertFalse();
      expect(reqJson.includes('Bearer')).assertFalse();
      expect(reqJson.includes('url')).assertFalse();
      expect(reqJson.includes('header')).assertFalse();
    });
  });
}
