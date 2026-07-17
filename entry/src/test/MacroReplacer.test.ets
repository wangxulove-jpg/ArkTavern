/**
 * MacroReplacer 单元测试
 *
 * 覆盖:
 * 1. {{char}} 正常替换
 * 2. {{character}} 正常替换
 * 3. {{user}} 正常替换
 * 4. 大小写不敏感
 * 5. 同一宏多次出现全部替换
 * 6. 多种宏同时出现
 * 7. 未识别宏保持原样
 * 8. 空文本返回空文本
 * 9. characterName 为空时角色宏保持原样
 * 10. userName 为空时用户宏保持原样
 * 11. 不进行递归替换
 * 12. 原始输入字符串未被修改
 */

import { describe, it, expect } from '@ohos/hypium';
import { MacroReplacer } from '../main/ets/services/MacroReplacer';
import { MacroContext, createMacroContext } from '../main/ets/models/MacroContext';

export default function macroReplacerTest(): void {
  describe('MacroReplacer', () => {
    const replacer: MacroReplacer = new MacroReplacer();

    // 1. {{char}} 正常替换
    it('char_macro_replaced', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'User');
      const result: string = replacer.replace('Hello {{char}}', ctx);
      expect(result).assertEqual('Hello Alice');
    });

    // 2. {{character}} 正常替换
    it('character_macro_replaced', 0, () => {
      const ctx: MacroContext = createMacroContext('Bob', 'User');
      const result: string = replacer.replace('Hello {{character}}', ctx);
      expect(result).assertEqual('Hello Bob');
    });

    // 3. {{user}} 正常替换
    it('user_macro_replaced', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'John');
      const result: string = replacer.replace('Hi {{user}}', ctx);
      expect(result).assertEqual('Hi John');
    });

    // 4. 大小写不敏感
    it('case_insensitive', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'User');
      expect(replacer.replace('{{CHAR}}', ctx)).assertEqual('Alice');
      expect(replacer.replace('{{Character}}', ctx)).assertEqual('Alice');
      expect(replacer.replace('{{USER}}', ctx)).assertEqual('User');
      expect(replacer.replace('{{cHaR}}', ctx)).assertEqual('Alice');
    });

    // 5. 同一宏多次出现全部替换
    it('multiple_occurrences_all_replaced', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'User');
      const result: string = replacer.replace('{{char}} and {{char}} and {{char}}', ctx);
      expect(result).assertEqual('Alice and Alice and Alice');
    });

    // 6. 多种宏同时出现
    it('mixed_macros_all_replaced', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'User');
      const result: string = replacer.replace('{{char}} looks at {{user}}. {{CHAR}} says hello.', ctx);
      expect(result).assertEqual('Alice looks at User. Alice says hello.');
    });

    // 7. 未识别宏保持原样
    it('unknown_macro_preserved', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'User');
      const result: string = replacer.replace('{{time}} and {{description}} and {{char}}', ctx);
      expect(result).assertEqual('{{time}} and {{description}} and Alice');
    });

    // 8. 空文本返回空文本
    it('empty_string_returns_empty', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'User');
      const result: string = replacer.replace('', ctx);
      expect(result).assertEqual('');
    });

    // 9. characterName 为空时角色宏保持原样
    it('empty_characterName_preserves_char_macro', 0, () => {
      const ctx: MacroContext = createMacroContext('', 'User');
      const result: string = replacer.replace('{{char}} and {{character}}', ctx);
      expect(result).assertEqual('{{char}} and {{character}}');
    });

    // 10. userName 为空时用户宏保持原样
    it('empty_userName_preserves_user_macro', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', '');
      const result: string = replacer.replace('{{user}} says hi', ctx);
      expect(result).assertEqual('{{user}} says hi');
    });

    // 11. 不进行递归替换
    it('no_recursive_replacement', 0, () => {
      // characterName 包含 {{user}},不应被二次替换
      const ctx: MacroContext = createMacroContext('{{user}}', 'John');
      const result: string = replacer.replace('{{char}}', ctx);
      expect(result).assertEqual('{{user}}');
    });

    // 12. 原始输入字符串未被修改
    it('original_input_not_modified', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'User');
      const original: string = '{{char}} says hi to {{user}}';
      const originalCopy: string = original;
      replacer.replace(original, ctx);
      expect(original).assertEqual(originalCopy);
    });

    // 额外:无宏文本原样返回
    it('no_macros_returns_unchanged', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'User');
      const result: string = replacer.replace('Hello world without macros', ctx);
      expect(result).assertEqual('Hello world without macros');
    });

    // 额外:userName 包含 {{char}} 时不递归
    it('userName_containing_char_macro_not_recursive', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', '{{char}}');
      const result: string = replacer.replace('{{user}}', ctx);
      expect(result).assertEqual('{{char}}');
    });

    // 额外:花括号不完整不替换
    it('incomplete_braces_not_replaced', 0, () => {
      const ctx: MacroContext = createMacroContext('Alice', 'User');
      const result: string = replacer.replace('{char} and {{char and {{{char}}}', ctx);
      expect(result).assertEqual('{char} and {{char and {{{char}}}');
    });
  });
}
