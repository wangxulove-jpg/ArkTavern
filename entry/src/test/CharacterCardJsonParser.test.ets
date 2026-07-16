/**
 * CharacterCardJsonParser 单元测试
 *
 * 覆盖:
 * - ArkTavern schemaVersion=1 解析
 * - V2 chara_card_v2 解析
 * - V3 chara_card_v3 解析
 * - 非法 JSON
 * - 空 name
 * - 未知版本
 * - 超大文件
 * - 字段缺失默认值
 * - 字段过长截断
 */

import { parseCharacterJson, ParseResult, ParsedCharacterCard } from '../main/ets/parser/CharacterCardJsonParser';
import { describe, it, expect } from '@ohos/hypium';

export default function parserTest() {
  describe('CharacterCardJsonParser', () => {

    // ===== ArkTavern 格式 =====

    it('ArkTavern_schemaVersion_1', () => {
      const json = JSON.stringify({
        schemaVersion: 1,
        character: {
          name: '测试角色',
          description: '测试描述',
          personality: '测试性格',
          scenario: '测试场景',
          firstMessage: '你好',
          systemPrompt: '你是测试助手',
          avatarUri: '',
          createdAt: 1000,
          updatedAt: 2000
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('测试角色');
      expect(result.card!.description).assertEqual('测试描述');
      expect(result.card!.personality).assertEqual('测试性格');
      expect(result.card!.scenario).assertEqual('测试场景');
      expect(result.card!.firstMessage).assertEqual('你好');
      expect(result.card!.systemPrompt).assertEqual('你是测试助手');
      expect(result.card!.sourceFormat).assertEqual('arktavern_v1');
    });

    it('ArkTavern_round_trip', () => {
      // 导出再导入,核心字段保持一致
      const original = JSON.stringify({
        schemaVersion: 1,
        character: {
          name: '往返测试',
          description: '往返描述',
          personality: '勇敢',
          scenario: '中世纪',
          firstMessage: '欢迎!',
          systemPrompt: '你是一个法师',
          avatarUri: '',
          createdAt: 1234567890,
          updatedAt: 1234567890
        }
      });
      const result: ParseResult = parseCharacterJson(original);
      expect(result.success).assertTrue();
      // 重新序列化验证核心字段一致
      const reSerialized = JSON.stringify({
        schemaVersion: 1,
        character: {
          name: result.card!.name,
          description: result.card!.description,
          personality: result.card!.personality,
          scenario: result.card!.scenario,
          firstMessage: result.card!.firstMessage,
          systemPrompt: result.card!.systemPrompt,
          avatarUri: result.card!.avatarUri,
          createdAt: 0,
          updatedAt: 0
        }
      });
      const parsed = JSON.parse(reSerialized) as Record<string, Object>;
      const char = parsed['character'] as Record<string, Object>;
      expect(char['name'] as string).assertEqual('往返测试');
      expect(char['description'] as string).assertEqual('往返描述');
      expect(char['personality'] as string).assertEqual('勇敢');
      expect(char['scenario'] as string).assertEqual('中世纪');
      expect(char['firstMessage'] as string).assertEqual('欢迎!');
      expect(char['systemPrompt'] as string).assertEqual('你是一个法师');
    });

    it('ArkTavern_missing_optional_fields', () => {
      const json = JSON.stringify({
        schemaVersion: 1,
        character: {
          name: '只有名字'
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('只有名字');
      expect(result.card!.description).assertEqual('');
      expect(result.card!.personality).assertEqual('');
    });

    it('ArkTavern_missing_character_field', () => {
      const json = JSON.stringify({ schemaVersion: 1 });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('缺少 character');
    });

    it('ArkTavern_unsupported_version', () => {
      const json = JSON.stringify({ schemaVersion: 99, character: { name: 'test' } });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('不支持');
    });

    // ===== V2 格式 =====

    it('V2_complete_card', () => {
      const json = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
          name: '艾伦',
          description: '金发冒险者',
          personality: '勇敢善良',
          scenario: '奇幻世界',
          first_mes: '你好旅行者!',
          mes_example: '示例对话',
          system_prompt: '你是冒险者',
          post_history_instructions: '',
          alternate_greetings: [],
          tags: [],
          creator: '',
          character_version: '',
          extensions: {}
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('艾伦');
      expect(result.card!.description).assertEqual('金发冒险者');
      expect(result.card!.firstMessage).assertEqual('你好旅行者!');
      expect(result.card!.systemPrompt).assertEqual('你是冒险者');
      expect(result.card!.sourceFormat).assertEqual('chara_card_v2');
    });

    it('V2_minimal_card', () => {
      const json = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
          name: '最小角色',
          description: '',
          personality: '',
          scenario: '',
          first_mes: '',
          mes_example: '',
          system_prompt: '',
          post_history_instructions: '',
          alternate_greetings: [],
          tags: [],
          creator: '',
          character_version: '',
          extensions: {}
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('最小角色');
      expect(result.card!.firstMessage).assertEqual('');
    });

    it('V2_missing_name', () => {
      const json = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
          name: '',
          description: 'desc'
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('缺少名称');
    });

    it('V2_missing_data_field', () => {
      const json = JSON.stringify({ spec: 'chara_card_v2', spec_version: '2.0' });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('缺少 data');
    });

    it('V2_name_with_whitespace_only', () => {
      const json = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: { name: '   ' }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('缺少名称');
    });

    it('V2_name_trimmed', () => {
      const json = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: { name: '  艾伦  ' }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('艾伦');
    });

    // ===== V3 格式 =====

    it('V3_complete_card', () => {
      const json = JSON.stringify({
        spec: 'chara_card_v3',
        spec_version: '3.0',
        data: {
          name: 'V3角色',
          description: 'V3描述',
          personality: 'V3性格',
          scenario: 'V3场景',
          first_mes: 'V3开场白',
          mes_example: '',
          system_prompt: 'V3系统提示',
          post_history_instructions: '',
          alternate_greetings: [],
          tags: [],
          creator: '',
          character_version: '',
          extensions: {}
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('V3角色');
      expect(result.card!.sourceFormat).assertEqual('chara_card_v3');
      expect(result.card!.firstMessage).assertEqual('V3开场白');
      expect(result.card!.systemPrompt).assertEqual('V3系统提示');
    });

    // ===== 错误处理 =====

    it('invalid_json_syntax', () => {
      const result: ParseResult = parseCharacterJson('{invalid json');
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('无法解析 JSON');
    });

    it('not_a_json_object', () => {
      const result: ParseResult = parseCharacterJson('"just a string"');
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('顶层必须是对象');
    });

    it('null_input', () => {
      const result: ParseResult = parseCharacterJson('null');
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('顶层必须是对象');
    });

    it('unknown_spec', () => {
      const json = JSON.stringify({ spec: 'unknown_format', data: { name: 'test' } });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('不支持');
    });

    it('empty_json_object', () => {
      const result: ParseResult = parseCharacterJson('{}');
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('无法识别');
    });

    it('oversized_file', () => {
      const prefix = '{"schemaVersion":1,"character":{"name":"';
      const suffix = '"}}';
      const paddingLength = 11 * 1024 * 1024;
      const padding = 'x'.repeat(paddingLength);
      const json = prefix + padding + suffix;
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('文件过大');
    });

    // ===== 字段映射 =====

    it('V2_first_mes_maps_to_firstMessage', () => {
      const json = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
          name: 'test',
          first_mes: '开场白内容'
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.firstMessage).assertEqual('开场白内容');
    });

    it('V2_system_prompt_maps_to_systemPrompt', () => {
      const json = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
          name: 'test',
          system_prompt: '系统提示'
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.systemPrompt).assertEqual('系统提示');
    });

    it('V2_missing_optional_fields_are_empty', () => {
      const json = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
          name: 'test'
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.description).assertEqual('');
      expect(result.card!.personality).assertEqual('');
      expect(result.card!.scenario).assertEqual('');
      expect(result.card!.firstMessage).assertEqual('');
      expect(result.card!.systemPrompt).assertEqual('');
    });

    // ===== 字段截断 =====

    it('long_field_truncated', () => {
      const longText = 'x'.repeat(6000);
      const json = JSON.stringify({
        schemaVersion: 1,
        character: {
          name: 'test',
          description: longText
        }
      });
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.description.length).assertEqual(5000);
    });
  });
}