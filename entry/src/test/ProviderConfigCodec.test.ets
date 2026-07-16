/**
 * ProviderConfigCodec 本地单元测试(无设备依赖)。
 *
 * 验证 ProviderConfig 列表与 JSON 字符串之间的安全序列化/反序列化。
 * 全部为纯逻辑测试,不导入 HarmonyOS Preferences 设备模块。
 *
 * 覆盖项(共 26 项):
 * 1. 单个配置编码
 * 2. 多配置编码
 * 3. 解码后字段一致
 * 4. 列表顺序保持
 * 5. schemaVersion=1
 * 6. 不包含 apiKey
 * 7. 不包含 secret
 * 8. 不包含 authorization
 * 9. ProviderType 全部合法枚举值
 * 10. 非法 ProviderType
 * 11. temperature 非法
 * 12. topP 非法
 * 13. maxTokens 非法
 * 14. 空 id
 * 15. 空 name
 * 16. 空 baseUrl
 * 17. 空 modelName
 * 18. 非法 createdAt
 * 19. 非法 updatedAt
 * 20. 非 JSON 字符串
 * 21. 空字符串
 * 22. 未支持 schemaVersion
 * 23. 一个有效配置加一个损坏配置
 * 24. 全部配置损坏
 * 25. 敏感字段注入时拒绝
 * 26. 编码解码往返一致
 */
import { describe, it, expect } from '@ohos/hypium';
import { ProviderType } from '../main/ets/models/ProviderType';
import { ProviderConfig } from '../main/ets/models/ProviderConfig';
import {
  encodeConfigs,
  decodeConfigs,
  encodeConfigItem,
  itemToConfig,
  roundTrip,
  isSensitiveField,
  containsSensitiveFields,
  isValidProviderTypeValue,
  CURRENT_SCHEMA_VERSION,
  CodecDecodeResult,
  ProviderConfigItemV1
} from '../main/ets/storage/ProviderConfigCodec';
import { PreferencesErrorType } from '../main/ets/models/PreferencesError';

/**
 * 构造一个测试用 ProviderConfig。
 * @param id 配置 id
 * @param type Provider 类型
 * @param createdAt 创建时间
 * @returns ProviderConfig 实例
 */
function makeConfig(
  id: string,
  type: ProviderType = ProviderType.OpenAICompatible,
  createdAt: number = 1000
): ProviderConfig {
  return new ProviderConfig(
    id,
    id + '-name',
    type,
    'https://api.example.com',
    'gpt-4',
    0.7,
    1.0,
    1024,
    true,
    true,
    createdAt,
    createdAt
  );
}

export default function providerConfigCodecTest() {
  describe('ProviderConfigCodecTest', () => {

    // ===== 1. 单个配置编码 =====
    it('encode_single_config', 0, () => {
      const config: ProviderConfig = makeConfig('test-1');
      const json: string = encodeConfigs([config]);
      expect(json.length > 0).assertTrue();
      // 应包含 schemaVersion 与 configs
      expect(json.includes('"schemaVersion"')).assertTrue();
      expect(json.includes('"configs"')).assertTrue();
      expect(json.includes('"test-1"')).assertTrue();
    });

    // ===== 2. 多配置编码 =====
    it('encode_multiple_configs', 0, () => {
      const configs: ProviderConfig[] = [
        makeConfig('test-a', ProviderType.OpenAICompatible, 1000),
        makeConfig('test-b', ProviderType.DeepSeek, 2000)
      ];
      const json: string = encodeConfigs(configs);
      expect(json.includes('"test-a"')).assertTrue();
      expect(json.includes('"test-b"')).assertTrue();
    });

    // ===== 3. 解码后字段一致 =====
    it('decode_fields_match', 0, () => {
      const original: ProviderConfig = makeConfig('match-1', ProviderType.Claude, 5000);
      const json: string = encodeConfigs([original]);
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.configs.length).assertEqual(1);
      const decoded: ProviderConfig = result.configs[0];
      expect(decoded.id).assertEqual(original.id);
      expect(decoded.name).assertEqual(original.name);
      expect(decoded.type).assertEqual(original.type);
      expect(decoded.baseUrl).assertEqual(original.baseUrl);
      expect(decoded.modelName).assertEqual(original.modelName);
      expect(decoded.temperature).assertEqual(original.temperature);
      expect(decoded.topP).assertEqual(original.topP);
      expect(decoded.maxTokens).assertEqual(original.maxTokens);
      expect(decoded.stream).assertEqual(original.stream);
      expect(decoded.enabled).assertEqual(original.enabled);
      expect(decoded.createdAt).assertEqual(original.createdAt);
      expect(decoded.updatedAt).assertEqual(original.updatedAt);
    });

    // ===== 4. 列表顺序保持 =====
    it('decode_preserves_order', 0, () => {
      const configs: ProviderConfig[] = [
        makeConfig('order-1', ProviderType.OpenAICompatible, 3000),
        makeConfig('order-2', ProviderType.DeepSeek, 1000),
        makeConfig('order-3', ProviderType.Claude, 2000)
      ];
      const json: string = encodeConfigs(configs);
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.configs.length).assertEqual(3);
      // 顺序与编码时一致(不自动重排)
      expect(result.configs[0].id).assertEqual('order-1');
      expect(result.configs[1].id).assertEqual('order-2');
      expect(result.configs[2].id).assertEqual('order-3');
    });

    // ===== 5. schemaVersion=1 =====
    it('schema_version_is_1', 0, () => {
      const json: string = encodeConfigs([makeConfig('sv-1')]);
      const parsed: Object = JSON.parse(json);
      const record: Record<string, Object> = parsed as Record<string, Object>;
      expect(record['schemaVersion']).assertEqual(CURRENT_SCHEMA_VERSION);
      expect(CURRENT_SCHEMA_VERSION).assertEqual(1);
    });

    // ===== 6. 不包含 apiKey =====
    it('no_apiKey_in_json', 0, () => {
      const json: string = encodeConfigs([makeConfig('nokey-1')]);
      const lower: string = json.toLowerCase();
      expect(lower.includes('apikey')).assertFalse();
      expect(lower.includes('api_key')).assertFalse();
    });

    // ===== 7. 不包含 secret =====
    it('no_secret_in_json', 0, () => {
      const json: string = encodeConfigs([makeConfig('nosec-1')]);
      const lower: string = json.toLowerCase();
      expect(lower.includes('"secret"')).assertFalse();
    });

    // ===== 8. 不包含 authorization =====
    it('no_authorization_in_json', 0, () => {
      const json: string = encodeConfigs([makeConfig('noauth-1')]);
      const lower: string = json.toLowerCase();
      expect(lower.includes('authorization')).assertFalse();
    });

    // ===== 9. ProviderType 全部合法枚举值 =====
    it('all_provider_types_valid', 0, () => {
      const types: ProviderType[] = [
        ProviderType.OpenAICompatible,
        ProviderType.OpenAI,
        ProviderType.DeepSeek,
        ProviderType.OpenRouter,
        ProviderType.Claude,
        ProviderType.Gemini
      ];
      for (let i = 0; i < types.length; i++) {
        expect(isValidProviderTypeValue(types[i])).assertTrue();
      }
      // 编码解码每个类型
      for (let i = 0; i < types.length; i++) {
        const config: ProviderConfig = makeConfig('type-' + i.toString(), types[i]);
        const json: string = encodeConfigs([config]);
        const result: CodecDecodeResult = decodeConfigs(json);
        expect(result.success).assertTrue();
        expect(result.configs[0].type).assertEqual(types[i]);
      }
    });

    // ===== 10. 非法 ProviderType =====
    it('invalid_provider_type_rejected', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: 'badtype-1',
        name: 'name',
        type: 'InvalidType',
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.configs.length).assertEqual(0);
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 11. temperature 非法 =====
    it('invalid_temperature_skipped', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: 'badtemp-1',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 5.0, // 超出 [0.0, 2.0]
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.configs.length).assertEqual(0);
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 12. topP 非法 =====
    it('invalid_topP_skipped', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: 'badtopp-1',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 2.0, // 超出 [0.0, 1.0]
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.configs.length).assertEqual(0);
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 13. maxTokens 非法 =====
    it('invalid_maxTokens_skipped', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: 'badmax-1',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 0, // 小于最小值 1
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.configs.length).assertEqual(0);
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 14. 空 id =====
    it('empty_id_skipped', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: '',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 15. 空 name =====
    it('empty_name_skipped', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: 'emptyname-1',
        name: '',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 16. 空 baseUrl =====
    it('empty_baseUrl_skipped', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: 'emptyurl-1',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: '',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 17. 空 modelName =====
    it('empty_modelName_skipped', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: 'emptymodel-1',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: '',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 18. 非法 createdAt =====
    it('invalid_createdAt_skipped', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: 'badcreated-1',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: -1, // 负数非法
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 19. 非法 updatedAt =====
    it('invalid_updatedAt_skipped', 0, () => {
      const item: ProviderConfigItemV1 = {
        id: 'badupdated-1',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: NaN // NaN 非法
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [item]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 20. 非 JSON 字符串 =====
    it('non_json_string_returns_corrupted', 0, () => {
      const result: CodecDecodeResult = decodeConfigs('this is not json');
      expect(result.success).assertFalse();
      expect(result.error !== undefined).assertTrue();
      expect(result.error!.type).assertEqual(PreferencesErrorType.CorruptedData);
    });

    // ===== 21. 空字符串 =====
    it('empty_string_returns_corrupted', 0, () => {
      const result: CodecDecodeResult = decodeConfigs('');
      expect(result.success).assertFalse();
      expect(result.error !== undefined).assertTrue();
      expect(result.error!.type).assertEqual(PreferencesErrorType.CorruptedData);
    });

    // ===== 22. 未支持 schemaVersion =====
    it('unsupported_schema_version', 0, () => {
      const json: string = JSON.stringify({
        schemaVersion: 99,
        configs: []
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertFalse();
      expect(result.error !== undefined).assertTrue();
      expect(result.error!.type).assertEqual(PreferencesErrorType.UnsupportedVersion);
    });

    // ===== 23. 一个有效配置加一个损坏配置 =====
    it('mixed_valid_and_invalid_configs', 0, () => {
      const validItem: ProviderConfigItemV1 = {
        id: 'mixed-valid',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const invalidItem: ProviderConfigItemV1 = {
        id: 'mixed-invalid',
        name: 'name',
        type: 'InvalidType',
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [validItem, invalidItem]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.configs.length).assertEqual(1);
      expect(result.skippedCount).assertEqual(1);
      expect(result.configs[0].id).assertEqual('mixed-valid');
    });

    // ===== 24. 全部配置损坏 =====
    it('all_configs_invalid_returns_empty', 0, () => {
      const invalid1: ProviderConfigItemV1 = {
        id: 'all-bad-1',
        name: 'name',
        type: 'InvalidType',
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const invalid2: ProviderConfigItemV1 = {
        id: '',
        name: 'name',
        type: ProviderType.OpenAICompatible,
        baseUrl: 'https://api.example.com',
        modelName: 'gpt-4',
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 1024,
        stream: true,
        enabled: true,
        createdAt: 1000,
        updatedAt: 1000
      };
      const json: string = JSON.stringify({
        schemaVersion: 1,
        configs: [invalid1, invalid2]
      });
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.configs.length).assertEqual(0);
      expect(result.skippedCount).assertEqual(2);
    });

    // ===== 25. 敏感字段注入时拒绝 =====
    it('sensitive_fields_rejected', 0, () => {
      // isSensitiveField
      expect(isSensitiveField('apiKey')).assertTrue();
      expect(isSensitiveField('api_key')).assertTrue();
      expect(isSensitiveField('secret')).assertTrue();
      expect(isSensitiveField('authorization')).assertTrue();
      expect(isSensitiveField('token')).assertTrue();
      expect(isSensitiveField('password')).assertTrue();
      // 大小写不敏感
      expect(isSensitiveField('APIKEY')).assertTrue();
      expect(isSensitiveField('SECRET')).assertTrue();
      // 非敏感字段
      expect(isSensitiveField('id')).assertFalse();
      expect(isSensitiveField('name')).assertFalse();
      expect(isSensitiveField('baseUrl')).assertFalse();

      // containsSensitiveFields
      const withSensitive: Record<string, Object> = {
        'id': 'x',
        'apiKey': 'should-not-be-here'
      };
      expect(containsSensitiveFields(withSensitive)).assertTrue();
      const withoutSensitive: Record<string, Object> = {
        'id': 'x',
        'name': 'ok'
      };
      expect(containsSensitiveFields(withoutSensitive)).assertFalse();

      // 解码时拒绝包含敏感字段的项
      const sensConfig: Record<string, Object> = {
        'id': 'sens-1',
        'name': 'name',
        'type': ProviderType.OpenAICompatible,
        'baseUrl': 'https://api.example.com',
        'modelName': 'gpt-4',
        'temperature': 0.7,
        'topP': 1.0,
        'maxTokens': 1024,
        'stream': true,
        'enabled': true,
        'createdAt': 1000,
        'updatedAt': 1000,
        'apiKey': 'should-not-be-here'
      };
      const jsonObj: Record<string, Object> = {
        'schemaVersion': 1,
        'configs': [sensConfig]
      };
      const json: string = JSON.stringify(jsonObj);
      const result: CodecDecodeResult = decodeConfigs(json);
      expect(result.success).assertTrue();
      expect(result.configs.length).assertEqual(0);
      expect(result.skippedCount).assertEqual(1);
    });

    // ===== 26. 编码解码往返一致 =====
    it('round_trip_consistency', 0, () => {
      const configs: ProviderConfig[] = [
        makeConfig('rt-1', ProviderType.OpenAICompatible, 1000),
        makeConfig('rt-2', ProviderType.DeepSeek, 2000),
        makeConfig('rt-3', ProviderType.Claude, 3000)
      ];
      const decoded: ProviderConfig[] = roundTrip(configs);
      expect(decoded.length).assertEqual(configs.length);
      for (let i = 0; i < configs.length; i++) {
        expect(decoded[i].id).assertEqual(configs[i].id);
        expect(decoded[i].name).assertEqual(configs[i].name);
        expect(decoded[i].type).assertEqual(configs[i].type);
        expect(decoded[i].baseUrl).assertEqual(configs[i].baseUrl);
        expect(decoded[i].modelName).assertEqual(configs[i].modelName);
        expect(decoded[i].temperature).assertEqual(configs[i].temperature);
        expect(decoded[i].topP).assertEqual(configs[i].topP);
        expect(decoded[i].maxTokens).assertEqual(configs[i].maxTokens);
        expect(decoded[i].stream).assertEqual(configs[i].stream);
        expect(decoded[i].enabled).assertEqual(configs[i].enabled);
        expect(decoded[i].createdAt).assertEqual(configs[i].createdAt);
        expect(decoded[i].updatedAt).assertEqual(configs[i].updatedAt);
      }
    });

    // ===== 辅助:encodeConfigItem 与 itemToConfig 互逆 =====
    it('encode_and_item_conversion', 0, () => {
      const config: ProviderConfig = makeConfig('conv-1', ProviderType.Gemini);
      const item: ProviderConfigItemV1 = encodeConfigItem(config);
      const back: ProviderConfig = itemToConfig(item);
      expect(back.id).assertEqual(config.id);
      expect(back.type).assertEqual(config.type);
      expect(back.temperature).assertEqual(config.temperature);
    });
  });
}
