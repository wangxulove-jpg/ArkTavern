/**
 * CharacterCardJsonWriter 单元测试
 *
 * 覆盖:
 * - ArkTavern 格式导出
 * - 导出内容无敏感数据
 * - 文件名安全处理
 * - 往返一致性
 */

import { writeCharacterToJson, findSensitiveKeys, sanitizeFileName } from '../main/ets/parser/CharacterCardJsonWriter';
import { Character, createCharacter } from '../main/ets/models/Character';
import { parseCharacterJson, ParseResult } from '../main/ets/parser/CharacterCardJsonParser';
import { describe, it, expect } from '@ohos/hypium';

function makeCharacter(name: string, desc: string, personality: string, scenario: string,
  firstMsg: string, sysPrompt: string): Character {
  return createCharacter('char-test-1', name, desc, personality, scenario, firstMsg, sysPrompt, '');
}

export default function writerTest() {
  describe('CharacterCardJsonWriter', () => {

    // ===== 基本导出 =====

    it('write_valid_json', () => {
      const char: Character = makeCharacter('测试', '描述', '性格', '场景', '你好', '系统提示');
      const json: string = writeCharacterToJson(char);
      const parsed: Object = JSON.parse(json) as Object;
      const obj: Record<string, Object> = parsed as Record<string, Object>;
      expect(obj['schemaVersion'] as number).assertEqual(1);
      const character: Record<string, Object> = obj['character'] as Record<string, Object>;
      expect(character['name'] as string).assertEqual('测试');
      expect(character['description'] as string).assertEqual('描述');
      expect(character['personality'] as string).assertEqual('性格');
      expect(character['scenario'] as string).assertEqual('场景');
      expect(character['firstMessage'] as string).assertEqual('你好');
      expect(character['systemPrompt'] as string).assertEqual('系统提示');
    });

    it('write_does_not_contain_id', () => {
      const char: Character = makeCharacter('test', '', '', '', '', '');
      const json: string = writeCharacterToJson(char);
      expect(json.includes('"id"')).assertFalse();
      expect(json.includes('char-test-1')).assertFalse();
    });

    it('write_contains_timestamps', () => {
      const char: Character = makeCharacter('test', '', '', '', '', '');
      const json: string = writeCharacterToJson(char);
      const parsed: Object = JSON.parse(json) as Object;
      const obj: Record<string, Object> = parsed as Record<string, Object>;
      const character: Record<string, Object> = obj['character'] as Record<string, Object>;
      expect(typeof character['createdAt']).assertEqual('number');
      expect(typeof character['updatedAt']).assertEqual('number');
    });

    // ===== 敏感数据检测 =====

    it('no_sensitive_keys_in_export', () => {
      const char: Character = makeCharacter('test', 'apikey', '', '', '', '');
      const json: string = writeCharacterToJson(char);
      const found: string[] = findSensitiveKeys(json);
      expect(found.length).assertEqual(0);
    });

    it('findSensitiveKeys_detects_apiKey', () => {
      const json = '{"apiKey":"sk-test"}';
      const found: string[] = findSensitiveKeys(json);
      expect(found.length).assertEqual(1);
      expect(found[0]).assertEqual('apikey');
    });

    it('findSensitiveKeys_detects_authorization', () => {
      const json = '{"authorization":"Bearer xxx"}';
      const found: string[] = findSensitiveKeys(json);
      expect(found.length).assertEqual(1);
      expect(found[0]).assertEqual('authorization');
    });

    it('findSensitiveKeys_detects_token', () => {
      const json = '{"token":"abc123"}';
      const found: string[] = findSensitiveKeys(json);
      expect(found.length).assertEqual(1);
      expect(found[0]).assertEqual('token');
    });

    it('findSensitiveKeys_no_match_in_value_only', () => {
      // 敏感词出现在值中但不作为键名,不应匹配
      const json = '{"name":"apiKey test"}';
      const found: string[] = findSensitiveKeys(json);
      expect(found.length).assertEqual(0);
    });

    // ===== 文件名安全处理 =====

    it('sanitizeFileName_normal', () => {
      const name: string = sanitizeFileName('艾伦');
      expect(name).assertEqual('艾伦.json');
    });

    it('sanitizeFileName_contains_slash', () => {
      const name: string = sanitizeFileName('a/b:c');
      expect(name).assertEqual('a_b_c.json');
    });

    it('sanitizeFileName_contains_illegal_chars', () => {
      const name: string = sanitizeFileName('test<>.json');
      expect(name).assertEqual('test__.json.json');
    });

    it('sanitizeFileName_empty', () => {
      const name: string = sanitizeFileName('');
      expect(name).assertEqual('character.json');
    });

    it('sanitizeFileName_whitespace_only', () => {
      const name: string = sanitizeFileName('   ');
      expect(name).assertEqual('character.json');
    });

    it('sanitizeFileName_leading_dots', () => {
      const name: string = sanitizeFileName('...test');
      expect(name).assertEqual('test.json');
    });

    it('sanitizeFileName_trailing_dots', () => {
      const name: string = sanitizeFileName('test...');
      expect(name).assertEqual('test.json');
    });

    it('sanitizeFileName_very_long', () => {
      const longName = 'a'.repeat(300);
      const name: string = sanitizeFileName(longName);
      expect(name.length).assertLessOrEqual(205); // 200 + '.json'
    });

    // ===== 往返一致性 =====

    it('round_trip_all_fields', () => {
      const char: Character = createCharacter(
        'char-roundtrip',
        '往返测试',
        '角色描述',
        '勇敢善良',
        '中世纪奇幻',
        '你好,旅行者!',
        '你是勇敢的冒险者',
        ''
      );
      const json: string = writeCharacterToJson(char);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('往返测试');
      expect(result.card!.description).assertEqual('角色描述');
      expect(result.card!.personality).assertEqual('勇敢善良');
      expect(result.card!.scenario).assertEqual('中世纪奇幻');
      expect(result.card!.firstMessage).assertEqual('你好,旅行者!');
      expect(result.card!.systemPrompt).assertEqual('你是勇敢的冒险者');
      expect(result.card!.sourceFormat).assertEqual('arktavern_v1');
    });

    it('round_trip_empty_optional_fields', () => {
      const char: Character = createCharacter('char-min', '最小', '', '', '', '', '', '');
      const json: string = writeCharacterToJson(char);
      const result: ParseResult = parseCharacterJson(json);
      expect(result.success).assertTrue();
      expect(result.card!.name).assertEqual('最小');
      expect(result.card!.description).assertEqual('');
      expect(result.card!.firstMessage).assertEqual('');
    });
  });
}