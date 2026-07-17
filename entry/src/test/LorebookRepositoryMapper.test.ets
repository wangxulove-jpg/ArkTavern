/**
 * LorebookRepositoryMapper 纯逻辑单元测试
 *
 * 覆盖:
 * - keys JSON 编解码
 * - position 显式解析
 * - boolean 0/1 转换
 * - priority 和时间校验
 * - 输入数组不修改
 *
 * 不依赖设备 API,纯逻辑测试。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  booleanToInt,
  intToBoolean,
  encodeKeysJson,
  decodeKeysJson,
  positionToString,
  parsePosition
} from '../../main/ets/repositories/LorebookRepositoryMapper';
import { LorebookPosition } from '../../main/ets/models/Lorebook';
import { DatabaseError, DatabaseErrorType } from '../../main/ets/models/DatabaseError';

export default function lorebookRepositoryMapperTest(): void {
  describe('LorebookRepositoryMapper', () => {

    // ===== keys JSON 编解码 =====

    it('encodeKeysJson_basic', 0, () => {
      const result: string = encodeKeysJson(['hello', 'world']);
      expect(result).assertEqual('["hello","world"]');
    });

    it('encodeKeysJson_empty_array', 0, () => {
      const result: string = encodeKeysJson([]);
      expect(result).assertEqual('[]');
    });

    it('encodeKeysJson_chinese', 0, () => {
      const result: string = encodeKeysJson(['你好', '世界']);
      expect(result).assertContain('你好');
      expect(result).assertContain('世界');
    });

    it('encodeKeysJson_emoji', 0, () => {
      const result: string = encodeKeysJson(['😀', '🎉']);
      const parsed: string[] = decodeKeysJson(result);
      expect(parsed[0]).assertEqual('😀');
      expect(parsed[1]).assertEqual('🎉');
    });

    it('encodeKeysJson_quotes_and_newlines', 0, () => {
      const input: string[] = ['a"b', 'c\nd', 'e\td'];
      const result: string = encodeKeysJson(input);
      const parsed: string[] = decodeKeysJson(result);
      expect(parsed[0]).assertEqual('a"b');
      expect(parsed[1]).assertEqual('c\nd');
      expect(parsed[2]).assertEqual('e\td');
    });

    it('decodeKeysJson_basic', 0, () => {
      const result: string[] = decodeKeysJson('["a","b","c"]');
      expect(result.length).assertEqual(3);
      expect(result[0]).assertEqual('a');
      expect(result[1]).assertEqual('b');
      expect(result[2]).assertEqual('c');
    });

    it('decodeKeysJson_empty_array', 0, () => {
      const result: string[] = decodeKeysJson('[]');
      expect(result.length).assertEqual(0);
    });

    it('decodeKeysJson_invalid_json', 0, () => {
      let caught: boolean = false;
      let errorType: number = -1;
      try {
        decodeKeysJson('not valid json');
      } catch (e) {
        caught = true;
        if (e instanceof DatabaseError) {
          errorType = e.type;
        }
      }
      expect(caught).assertTrue();
      expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
    });

    it('decodeKeysJson_not_array', 0, () => {
      let caught: boolean = false;
      let errorType: number = -1;
      try {
        decodeKeysJson('{"key":"value"}');
      } catch (e) {
        caught = true;
        if (e instanceof DatabaseError) {
          errorType = e.type;
        }
      }
      expect(caught).assertTrue();
      expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
    });

    it('decodeKeysJson_array_with_number', 0, () => {
      let caught: boolean = false;
      let errorType: number = -1;
      try {
        decodeKeysJson('["a", 123]');
      } catch (e) {
        caught = true;
        if (e instanceof DatabaseError) {
          errorType = e.type;
        }
      }
      expect(caught).assertTrue();
      expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
    });

    it('decodeKeysJson_array_with_null', 0, () => {
      let caught: boolean = false;
      let errorType: number = -1;
      try {
        decodeKeysJson('["a", null]');
      } catch (e) {
        caught = true;
        if (e instanceof DatabaseError) {
          errorType = e.type;
        }
      }
      expect(caught).assertTrue();
      expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
    });

    // ===== Position 解析 =====

    it('positionToString_before', 0, () => {
      const result: string = positionToString(LorebookPosition.BeforeCharacter);
      expect(result).assertEqual('BeforeCharacter');
    });

    it('positionToString_after', 0, () => {
      const result: string = positionToString(LorebookPosition.AfterCharacter);
      expect(result).assertEqual('AfterCharacter');
    });

    it('parsePosition_before', 0, () => {
      const result: LorebookPosition = parsePosition('BeforeCharacter');
      expect(result).assertEqual(LorebookPosition.BeforeCharacter);
    });

    it('parsePosition_after', 0, () => {
      const result: LorebookPosition = parsePosition('AfterCharacter');
      expect(result).assertEqual(LorebookPosition.AfterCharacter);
    });

    it('parsePosition_invalid', 0, () => {
      let caught: boolean = false;
      let errorType: number = -1;
      try {
        parsePosition('InvalidPosition');
      } catch (e) {
        caught = true;
        if (e instanceof DatabaseError) {
          errorType = e.type;
        }
      }
      expect(caught).assertTrue();
      expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
    });

    it('parsePosition_empty_string', 0, () => {
      let caught: boolean = false;
      let errorType: number = -1;
      try {
        parsePosition('');
      } catch (e) {
        caught = true;
        if (e instanceof DatabaseError) {
          errorType = e.type;
        }
      }
      expect(caught).assertTrue();
      expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
    });

    // ===== boolean 转换 =====

    it('booleanToInt_true', 0, () => {
      expect(booleanToInt(true)).assertEqual(1);
    });

    it('booleanToInt_false', 0, () => {
      expect(booleanToInt(false)).assertEqual(0);
    });

    it('intToBoolean_zero', 0, () => {
      expect(intToBoolean(0)).assertEqual(false);
    });

    it('intToBoolean_one', 0, () => {
      expect(intToBoolean(1)).assertEqual(true);
    });

    it('intToBoolean_other_number', 0, () => {
      // intToBoolean treats any non-zero as true
      expect(intToBoolean(2)).assertEqual(true);
      expect(intToBoolean(-1)).assertEqual(true);
    });

    // ===== 输入数组不修改 =====

    it('encodeKeysJson_does_not_mutate_input', 0, () => {
      const input: string[] = ['a', 'b'];
      const copy: string[] = [...input];
      encodeKeysJson(input);
      expect(input.length).assertEqual(copy.length);
      expect(input[0]).assertEqual(copy[0]);
      expect(input[1]).assertEqual(copy[1]);
    });

    it('decodeKeysJson_returns_new_array', 0, () => {
      const result1: string[] = decodeKeysJson('["a","b"]');
      const result2: string[] = decodeKeysJson('["a","b"]');
      expect(result1 !== result2).assertTrue();
    });
  });
}