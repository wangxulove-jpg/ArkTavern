/**
 * CharacterCardJsonParser 设备测试(ohosTest)
 */

import { parseCharacterJson, ParseResult } from '../../../main/ets/parser/CharacterCardJsonParser';
import { describe, it, expect } from '@ohos/hypium';

/** 辅助:构建 ArkTavern V1 格式 JSON */
function arkTavernJson(name: string, fields: Record<string, Object>): string {
  const char: Record<string, Object> = fields;
  char['name'] = name;
  const root: Record<string, Object> = {
    'schemaVersion': 1,
    'character': char
  };
  return JSON.stringify(root);
}

/** 辅助:构建 V2/V3 格式 JSON */
function charaCardJson(spec: string, version: string, name: string, fields: Record<string, Object>): string {
  const data: Record<string, Object> = fields;
  data['name'] = name;
  const root: Record<string, Object> = {
    'spec': spec,
    'spec_version': version,
    'data': data
  };
  return JSON.stringify(root);
}

export default function parserTest() {
  describe('CharacterCardJsonParser', () => {

    it('ArkTavern_schemaVersion_1', 0, () => {
      const fields: Record<string, Object> = {
        'name': '测试角色',
        'description': '测试描述',
        'personality': '测试性格',
        'scenario': '测试场景',
        'firstMessage': '你好',
        'systemPrompt': '你是测试助手',
        'avatarUri': '',
        'createdAt': 1000,
        'updatedAt': 2000
      };
      const json = arkTavernJson('测试角色', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('测试角色');
      expect(result.card!.description).assertEqual('测试描述');
      expect(result.card!.sourceFormat).assertEqual('arktavern_v1');
    });

    it('ArkTavern_missing_optional_fields', 0, () => {
      const fields: Record<string, Object> = {};
      const json = arkTavernJson('只有名字', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('只有名字');
      expect(result.card!.description).assertEqual('');
    });

    it('ArkTavern_missing_character_field', 0, () => {
      const root: Record<string, Object> = { 'schemaVersion': 1 };
      const json = JSON.stringify(root);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('缺少 character');
    });

    it('ArkTavern_unsupported_version', 0, () => {
      const char: Record<string, Object> = { 'name': 'test' };
      const root: Record<string, Object> = { 'schemaVersion': 99, 'character': char };
      const json = JSON.stringify(root);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('不支持');
    });

    it('V2_complete_card', 0, () => {
      const fields: Record<string, Object> = {
        'name': '艾伦',
        'description': '金发冒险者',
        'personality': '勇敢善良',
        'scenario': '奇幻世界',
        'first_mes': '你好旅行者!',
        'system_prompt': '你是冒险者'
      };
      const json = charaCardJson('chara_card_v2', '2.0', '艾伦', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('艾伦');
      expect(result.card!.description).assertEqual('金发冒险者');
      expect(result.card!.firstMessage).assertEqual('你好旅行者!');
      expect(result.card!.systemPrompt).assertEqual('你是冒险者');
      expect(result.card!.sourceFormat).assertEqual('chara_card_v2');
    });

    it('V2_missing_name', 0, () => {
      const fields: Record<string, Object> = { 'description': 'desc' };
      const json = charaCardJson('chara_card_v2', '2.0', '', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('缺少名称');
    });

    it('V2_name_with_whitespace_only', 0, () => {
      const fields: Record<string, Object> = {};
      const json = charaCardJson('chara_card_v2', '2.0', '   ', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('缺少名称');
    });

    it('V2_name_trimmed', 0, () => {
      const fields: Record<string, Object> = {};
      const json = charaCardJson('chara_card_v2', '2.0', '  艾伦  ', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('艾伦');
    });

    it('V2_missing_data_field', 0, () => {
      const root: Record<string, Object> = { 'spec': 'chara_card_v2', 'spec_version': '2.0' };
      const json = JSON.stringify(root);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('缺少 data');
    });

    it('V2_first_mes_maps_to_firstMessage', 0, () => {
      const fields: Record<string, Object> = { 'first_mes': '开场白内容' };
      const json = charaCardJson('chara_card_v2', '2.0', 'test', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.firstMessage).assertEqual('开场白内容');
    });

    it('V2_system_prompt_maps_to_systemPrompt', 0, () => {
      const fields: Record<string, Object> = { 'system_prompt': '系统提示' };
      const json = charaCardJson('chara_card_v2', '2.0', 'test', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.systemPrompt).assertEqual('系统提示');
    });

    it('V2_missing_optional_fields_are_empty', 0, () => {
      const fields: Record<string, Object> = {};
      const json = charaCardJson('chara_card_v2', '2.0', 'test', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.description).assertEqual('');
      expect(result.card!.personality).assertEqual('');
      expect(result.card!.scenario).assertEqual('');
      expect(result.card!.firstMessage).assertEqual('');
      expect(result.card!.systemPrompt).assertEqual('');
    });

    it('V3_complete_card', 0, () => {
      const fields: Record<string, Object> = {
        'name': 'V3角色',
        'description': 'V3描述',
        'personality': 'V3性格',
        'scenario': 'V3场景',
        'first_mes': 'V3开场白',
        'system_prompt': 'V3系统提示'
      };
      const json = charaCardJson('chara_card_v3', '3.0', 'V3角色', fields);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('V3角色');
      expect(result.card!.sourceFormat).assertEqual('chara_card_v3');
      expect(result.card!.firstMessage).assertEqual('V3开场白');
      expect(result.card!.systemPrompt).assertEqual('V3系统提示');
    });

    it('invalid_json_syntax', 0, () => {
      const result: ParseResult = parseCharacterJson('{invalid json');
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('无法解析 JSON');
    });

    it('not_a_json_object', 0, () => {
      const result: ParseResult = parseCharacterJson('"just a string"');
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('顶层必须是对象');
    });

    it('null_input', 0, () => {
      const result: ParseResult = parseCharacterJson('null');
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('顶层必须是对象');
    });

    it('unknown_spec', 0, () => {
      const data: Record<string, Object> = { 'name': 'test' };
      const root: Record<string, Object> = { 'spec': 'unknown_format', 'data': data };
      const json = JSON.stringify(root);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('不支持');
    });

    it('empty_json_object', 0, () => {
      const root: Record<string, Object> = {};
      const json = JSON.stringify(root);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('无法识别');
    });

    it('oversized_file', 0, () => {
      const prefix = '{"schemaVersion":1,"character":{"name":"';
      const suffix = '"}}';
      const paddingLength = 11 * 1024 * 1024;
      const padding = 'x'.repeat(paddingLength);
      const json = prefix + padding + suffix;
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertFalse();
      expect(result.error!).assertContain('文件过大');
    });

    it('long_field_truncated', 0, () => {
      const longText = 'x'.repeat(6000);
      const char: Record<string, Object> = { 'name': 'test', 'description': longText };
      const root: Record<string, Object> = { 'schemaVersion': 1, 'character': char };
      const json = JSON.stringify(root);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.description.length).assertEqual(5000);
    });
  });
}