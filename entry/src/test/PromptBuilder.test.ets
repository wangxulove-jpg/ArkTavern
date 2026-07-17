/**
 * PromptBuilder 单元测试
 *
 * 覆盖:
 * 1. 无角色、无世界书时，消息顺序不变
 * 2. 输入存在合法 System 消息时不会被无条件删除
 * 3. 只有角色时，Character System Prompt 正确注入
 * 4. 只有世界书时，BeforeCharacter 和 AfterCharacter 顺序正确
 * 5. 角色与世界书同时存在时，顺序正确
 * 6. constant 条目始终注入
 * 7. 普通关键词命中后注入
 * 8. selective 条目必须主关键词和次关键词同时命中
 * 9. selective 只命中主关键词时不注入
 * 10. disabled 世界书不注入
 * 11. disabled 条目不注入
 * 12. priority 排序正确
 * 13. 原始消息数组未被修改
 * 14. firstMessage 不重复
 * 15. 重新生成不重复注入角色或世界书内容
 */

import { describe, it, expect } from '@ohos/hypium';
import { PromptBuilder, PromptBuildContext, PromptBuildResult } from '../main/ets/services/PromptBuilder';
import { LorebookService } from '../main/ets/services/LorebookService';
import { MacroReplacer } from '../main/ets/services/MacroReplacer';
import { LorebookStore } from '../main/ets/storage/LorebookStore';
import {
  Lorebook,
  LorebookEntry,
  LorebookPosition,
  createLorebook,
  createLorebookEntry,
  addEntryToLorebook,
  updateLorebook
} from '../main/ets/models/Lorebook';
import { Character, createCharacter } from '../main/ets/models/Character';
import { ChatMessage, createChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import { MacroContext, createMacroContext } from '../main/ets/models/MacroContext';

function makeUserMsg(content: string): ChatMessage {
  return createChatMessage('msg-u-' + content, ChatRole.User, content, 1000);
}

function makeAssistantMsg(content: string): ChatMessage {
  return createChatMessage('msg-a-' + content, ChatRole.Assistant, content, 1000);
}

function makeSystemMsg(content: string): ChatMessage {
  return createChatMessage('msg-s-' + content, ChatRole.System, content, 1000);
}

function createTestLorebookService(): LorebookService {
  return new LorebookService(new LorebookStore());
}

function builder(): PromptBuilder {
  return new PromptBuilder(createTestLorebookService(), new MacroReplacer());
}

export default function promptBuilderTest(): void {
  describe('PromptBuilder', () => {
    // ===== 基础:无角色无世界书 =====

    it('No_character_no_lorebook_preserves_message_order', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('你好'), makeAssistantMsg('你好')];
      const context: PromptBuildContext = { messages: msgs };

      const result: PromptBuildResult = b.build(context);

      expect(result.messages.length).assertEqual(2);
      expect(result.messages[0].content).assertEqual('你好');
      expect(result.messages[0].role).assertEqual(ChatRole.User);
      expect(result.messages[1].content).assertEqual('你好');
      expect(result.messages[1].role).assertEqual(ChatRole.Assistant);
      expect(result.matchedLorebookEntryIds.length).assertEqual(0);
    });

    // ===== System 消息不被无条件删除 =====

    it('Input_System_messages_are_preserved_not_dropped', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [
        makeSystemMsg('合法系统提示'),
        makeUserMsg('你好'),
        makeAssistantMsg('你好')
      ];
      const context: PromptBuildContext = { messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // 输入中的 System 消息应保留(3条输入 → 3条输出)
      expect(result.messages.length).assertEqual(3);
      expect(result.messages[0].role).assertEqual(ChatRole.System);
      expect(result.messages[0].content).assertEqual('合法系统提示');
      expect(result.messages[1].role).assertEqual(ChatRole.User);
      expect(result.messages[2].role).assertEqual(ChatRole.Assistant);
    });

    // ===== 仅角色 =====

    it('Only_character_injects_system_prompt', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('测试角色', '测试描述');
      const msgs: ChatMessage[] = [makeUserMsg('你好')];
      const context: PromptBuildContext = { character: char, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // Character System Prompt + User = 2 条
      expect(result.messages.length).assertEqual(2);
      expect(result.messages[0].role).assertEqual(ChatRole.System);
      expect(result.messages[0].content).assertContain('测试角色');
      expect(result.messages[1].role).assertEqual(ChatRole.User);
    });

    // ===== 仅世界书:Before/After 顺序 =====

    it('Only_lorebook_before_after_order', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('测试世界书', '', true);
      const entryBefore: LorebookEntry = createLorebookEntry(
        'before', ['酒馆'], [], '这里是酒馆', true, false, false, LorebookPosition.BeforeCharacter, 10
      );
      const entryAfter: LorebookEntry = createLorebookEntry(
        'after', ['酒馆'], [], '酒馆之后', true, false, false, LorebookPosition.AfterCharacter, 10
      );
      let lb2: Lorebook = addEntryToLorebook(lb, entryBefore);
      lb2 = addEntryToLorebook(lb2, entryAfter);
      const msgs: ChatMessage[] = [makeUserMsg('酒馆')];
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // BeforeCharacter System + AfterCharacter System + User = 3 条
      expect(result.messages.length).assertEqual(3);
      // 第一条是 BeforeCharacter 世界书
      expect(result.messages[0].role).assertEqual(ChatRole.System);
      expect(result.messages[0].content).assertEqual('这里是酒馆');
      // 第二条是 AfterCharacter 世界书
      expect(result.messages[1].role).assertEqual(ChatRole.System);
      expect(result.messages[1].content).assertEqual('酒馆之后');
      // 第三条是 User
      expect(result.messages[2].role).assertEqual(ChatRole.User);
      expect(result.matchedLorebookEntryIds.length).assertEqual(2);
    });

    // ===== 角色 + 世界书:完整顺序 =====

    it('Character_and_lorebook_full_order', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('角色', '描述');
      const lb: Lorebook = createLorebook('世界书', '', true);
      const entryBefore: LorebookEntry = createLorebookEntry(
        'before', ['酒馆'], [], '酒馆情景', true, false, false, LorebookPosition.BeforeCharacter, 10
      );
      const entryAfter: LorebookEntry = createLorebookEntry(
        'after', ['酒馆'], [], '酒馆后记', true, false, false, LorebookPosition.AfterCharacter, 10
      );
      let lb2: Lorebook = addEntryToLorebook(lb, entryBefore);
      lb2 = addEntryToLorebook(lb2, entryAfter);
      const msgs: ChatMessage[] = [makeAssistantMsg('欢迎'), makeUserMsg('酒馆里有什么')];
      const context: PromptBuildContext = { character: char, lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // 顺序:BeforeCharacter → Character System Prompt → AfterCharacter → Conversation
      expect(result.messages.length).assertEqual(5);
      // 1. BeforeCharacter 世界书
      expect(result.messages[0].role).assertEqual(ChatRole.System);
      expect(result.messages[0].content).assertEqual('酒馆情景');
      // 2. Character System Prompt
      expect(result.messages[1].role).assertEqual(ChatRole.System);
      expect(result.messages[1].content).assertContain('角色');
      // 3. AfterCharacter 世界书
      expect(result.messages[2].role).assertEqual(ChatRole.System);
      expect(result.messages[2].content).assertEqual('酒馆后记');
      // 4-5. Conversation
      expect(result.messages[3].role).assertEqual(ChatRole.Assistant);
      expect(result.messages[4].role).assertEqual(ChatRole.User);
      expect(result.matchedLorebookEntryIds.length).assertEqual(2);
    });

    // ===== constant 条目 =====

    it('Constant_entry_always_injected', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const constEntry: LorebookEntry = createLorebookEntry(
        'const', [], [], '恒定内容', true, true, false, LorebookPosition.BeforeCharacter, 0
      );
      const lb2: Lorebook = addEntryToLorebook(lb, constEntry);
      // 没有匹配关键词的消息
      const msgs: ChatMessage[] = [makeUserMsg('你好')];
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // constant 条目始终注入,包含 1 条 System + 1 条 User
      expect(result.messages.length).assertEqual(2);
      expect(result.messages[0].content).assertEqual('恒定内容');
      expect(result.matchedLorebookEntryIds.length).assertEqual(1);
    });

    // ===== 普通关键词匹配 =====

    it('Keyword_match_injects_entry', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const entry: LorebookEntry = createLorebookEntry(
        'kw', ['酒馆'], [], '酒馆内容', true, false, false, LorebookPosition.BeforeCharacter, 0
      );
      const lb2: Lorebook = addEntryToLorebook(lb, entry);
      const msgs: ChatMessage[] = [makeUserMsg('我们来到了酒馆')];
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      expect(result.matchedLorebookEntryIds.length).assertEqual(1);
      expect(result.messages[0].content).assertEqual('酒馆内容');
    });

    it('English_keyword_case_insensitive', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const entry: LorebookEntry = createLorebookEntry(
        'en', ['Tavern'], [], 'English tavern', true, false, false, LorebookPosition.BeforeCharacter, 0
      );
      const lb2: Lorebook = addEntryToLorebook(lb, entry);
      const msgs: ChatMessage[] = [makeUserMsg('Welcome to the tavern!')];
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      expect(result.matchedLorebookEntryIds.length).assertEqual(1);
      expect(result.messages[0].content).assertEqual('English tavern');
    });

    // ===== selective 条目 =====

    it('Selective_entry_both_keys_match', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const entry: LorebookEntry = createLorebookEntry(
        'sel', ['酒馆'], ['战斗'], '选择性战斗', true, false, true, LorebookPosition.BeforeCharacter, 0
      );
      const lb2: Lorebook = addEntryToLorebook(lb, entry);
      const msgs: ChatMessage[] = [makeUserMsg('酒馆里发生了战斗')];
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      expect(result.matchedLorebookEntryIds.length).assertEqual(1);
      expect(result.messages[0].content).assertEqual('选择性战斗');
    });

    it('Selective_entry_only_primary_key_not_injected', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const entry: LorebookEntry = createLorebookEntry(
        'sel', ['酒馆'], ['战斗'], '选择性战斗', true, false, true, LorebookPosition.BeforeCharacter, 0
      );
      const lb2: Lorebook = addEntryToLorebook(lb, entry);
      // 只命中主关键词,未命中次关键词
      const msgs: ChatMessage[] = [makeUserMsg('我们来到了酒馆')];
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // selective 只命中主关键词→不注入
      expect(result.matchedLorebookEntryIds.length).assertEqual(0);
    });

    // ===== disabled 世界书 =====

    it('Disabled_lorebook_not_injected', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('禁用世界书', '', false);
      const entry: LorebookEntry = createLorebookEntry(
        'kw', ['酒馆'], [], '酒馆内容', true, false, false, LorebookPosition.BeforeCharacter, 0
      );
      const lb2: Lorebook = addEntryToLorebook(lb, entry);
      const msgs: ChatMessage[] = [makeUserMsg('酒馆')];
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      expect(result.matchedLorebookEntryIds.length).assertEqual(0);
      // 只有 User 消息,无世界书注入
      expect(result.messages.length).assertEqual(1);
    });

    // ===== disabled 条目 =====

    it('Disabled_entry_not_injected', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const entry: LorebookEntry = createLorebookEntry(
        'disabled', ['酒馆'], [], '禁用条目', false, false, false, LorebookPosition.BeforeCharacter, 0
      );
      const lb2: Lorebook = addEntryToLorebook(lb, entry);
      const msgs: ChatMessage[] = [makeUserMsg('酒馆')];
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      expect(result.matchedLorebookEntryIds.length).assertEqual(0);
    });

    // ===== priority 排序 =====

    it('Priority_sorting_descending', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const low: LorebookEntry = createLorebookEntry(
        'low', ['酒馆'], [], '低优先级', true, false, false, LorebookPosition.BeforeCharacter, 1
      );
      const high: LorebookEntry = createLorebookEntry(
        'high', ['酒馆'], [], '高优先级', true, false, false, LorebookPosition.BeforeCharacter, 100
      );
      let lb2: Lorebook = addEntryToLorebook(lb, low);
      lb2 = addEntryToLorebook(lb2, high);
      const msgs: ChatMessage[] = [makeUserMsg('酒馆')];
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // 同位置 BeforeCharacter 内按 priority 降序
      expect(result.matchedLorebookEntryIds.length).assertEqual(2);
      expect(result.matchedLorebookEntryIds[0]).assertEqual('high');
      expect(result.matchedLorebookEntryIds[1]).assertEqual('low');
      expect(result.messages[0].content).assertEqual('高优先级');
      expect(result.messages[1].content).assertEqual('低优先级');
    });

    // ===== 原始消息数组不变 =====

    it('Original_messages_array_not_modified', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('测试')];
      const originalLength: number = msgs.length;
      const context: PromptBuildContext = { messages: msgs };

      b.build(context);

      expect(msgs.length).assertEqual(originalLength);
      expect(msgs[0].content).assertEqual('测试');
    });

    // ===== firstMessage 不重复 =====

    it('FirstMessage_not_duplicated', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('角色', '描述', '', '', '你好，我是角色');
      const msgs: ChatMessage[] = [makeAssistantMsg('你好，我是角色')];
      const context: PromptBuildContext = { character: char, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // Character System Prompt + firstMessage = 2 条,firstMessage 不重复
      expect(result.messages.length).assertEqual(2);
      expect(result.messages[0].role).assertEqual(ChatRole.System);
      expect(result.messages[1].role).assertEqual(ChatRole.Assistant);
      expect(result.messages[1].content).assertEqual('你好，我是角色');
    });

    // ===== 重新生成不重复注入 =====

    it('Rebuild_does_not_duplicate_injections', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('角色', '描述');
      const msgs: ChatMessage[] = [makeUserMsg('你好')];
      const context: PromptBuildContext = { character: char, messages: msgs };

      const result1: PromptBuildResult = b.build(context);
      const result2: PromptBuildResult = b.build(context);

      expect(result1.messages.length).assertEqual(result2.messages.length);
      expect(result1.messages[0].content).assertEqual(result2.messages[0].content);
    });

    // ===== 宏替换测试 =====

    // 13. Character System Prompt 宏替换
    it('Macro_character_system_prompt_replaced', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('Alice', '描述{{user}}');
      const msgs: ChatMessage[] = [makeUserMsg('你好')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = { character: char, messages: msgs, macroContext: macroCtx };

      const result: PromptBuildResult = b.build(context);

      // System Prompt 应包含 "描述User" 而非 "描述{{user}}"
      expect(result.messages[0].role).assertEqual(ChatRole.System);
      expect(result.messages[0].content).assertContain('描述User');
      expect(result.messages[0].content).assertNotContain('{{user}}');
    });

    // 14. BeforeCharacter 世界书宏替换
    it('Macro_before_lorebook_replaced', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const entry: LorebookEntry = createLorebookEntry(
        'before', ['酒馆'], [], '{{char}} 正站在酒馆中。', true, true, false, LorebookPosition.BeforeCharacter, 10
      );
      const lb2: Lorebook = addEntryToLorebook(lb, entry);
      const msgs: ChatMessage[] = [makeUserMsg('酒馆')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs, macroContext: macroCtx };

      const result: PromptBuildResult = b.build(context);

      expect(result.messages[0].content).assertEqual('Alice 正站在酒馆中。');
    });

    // 15. AfterCharacter 世界书宏替换
    it('Macro_after_lorebook_replaced', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const entry: LorebookEntry = createLorebookEntry(
        'after', ['酒馆'], [], '{{user}} 来到酒馆。', true, true, false, LorebookPosition.AfterCharacter, 10
      );
      const lb2: Lorebook = addEntryToLorebook(lb, entry);
      const msgs: ChatMessage[] = [makeUserMsg('酒馆')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'John');
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs, macroContext: macroCtx };

      const result: PromptBuildResult = b.build(context);

      expect(result.messages[0].content).assertEqual('John 来到酒馆。');
    });

    // 16. firstMessage 宏替换且不重复
    it('Macro_firstMessage_replaced_not_duplicated', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('Alice', '描述', '', '', '你好，{{user}}，我是{{char}}。');
      const msgs: ChatMessage[] = [makeAssistantMsg('你好，{{user}}，我是{{char}}。')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = { character: char, messages: msgs, macroContext: macroCtx };

      const result: PromptBuildResult = b.build(context);

      // Character System Prompt + firstMessage = 2 条
      expect(result.messages.length).assertEqual(2);
      // firstMessage 宏被替换
      expect(result.messages[1].role).assertEqual(ChatRole.Assistant);
      expect(result.messages[1].content).assertEqual('你好，User，我是Alice。');
    });

    // 17. User 消息宏替换
    it('Macro_user_message_replaced', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('{{user}} 想说话')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'John');
      const context: PromptBuildContext = { messages: msgs, macroContext: macroCtx };

      const result: PromptBuildResult = b.build(context);

      expect(result.messages[0].content).assertEqual('John 想说话');
    });

    // 18. Assistant 消息宏替换
    it('Macro_assistant_message_replaced', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeAssistantMsg('{{char}} 微笑')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = { messages: msgs, macroContext: macroCtx };

      const result: PromptBuildResult = b.build(context);

      expect(result.messages[0].content).assertEqual('Alice 微笑');
    });

    // 19. 合法 System 消息宏替换
    it('Macro_system_message_replaced', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeSystemMsg('规则：{{char}} 是主角')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = { messages: msgs, macroContext: macroCtx };

      const result: PromptBuildResult = b.build(context);

      expect(result.messages[0].content).assertEqual('规则：Alice 是主角');
    });

    // 20. 原始消息数组和消息对象未修改
    it('Macro_original_messages_not_modified', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('{{user}} 测试'), makeAssistantMsg('{{char}} 回复')];
      const originalUserContent: string = msgs[0].content;
      const originalAssistantContent: string = msgs[1].content;
      const macroCtx: MacroContext = createMacroContext('Alice', 'John');
      const context: PromptBuildContext = { messages: msgs, macroContext: macroCtx };

      b.build(context);

      expect(msgs[0].content).assertEqual(originalUserContent);
      expect(msgs[1].content).assertEqual(originalAssistantContent);
      expect(msgs.length).assertEqual(2);
    });

    // 21. 原始 Character 对象未修改
    it('Macro_original_character_not_modified', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('Alice', '描述{{user}}', '', '', '你好{{char}}');
      const originalDesc: string = char.description;
      const originalFirstMsg: string = char.firstMessage;
      const msgs: ChatMessage[] = [makeUserMsg('hi')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = { character: char, messages: msgs, macroContext: macroCtx };

      b.build(context);

      expect(char.description).assertEqual(originalDesc);
      expect(char.firstMessage).assertEqual(originalFirstMsg);
    });

    // 22. 原始 LorebookEntry 内容未修改
    it('Macro_original_lorebook_entry_not_modified', 0, () => {
      const b: PromptBuilder = builder();
      const lb: Lorebook = createLorebook('世界书', '', true);
      const entry: LorebookEntry = createLorebookEntry(
        'e', ['酒馆'], [], '{{char}} 在酒馆', true, true, false, LorebookPosition.BeforeCharacter, 10
      );
      const lb2: Lorebook = addEntryToLorebook(lb, entry);
      const originalContent: string = entry.content;
      const msgs: ChatMessage[] = [makeUserMsg('酒馆')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = { lorebook: lb2, messages: msgs, macroContext: macroCtx };

      b.build(context);

      expect(entry.content).assertEqual(originalContent);
    });

    // 23. 无角色时角色宏保持原样
    it('Macro_no_character_preserves_char_macro', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('{{char}} is here')];
      const macroCtx: MacroContext = createMacroContext('', 'User');
      const context: PromptBuildContext = { messages: msgs, macroContext: macroCtx };

      const result: PromptBuildResult = b.build(context);

      expect(result.messages[0].content).assertEqual('{{char}} is here');
    });

    // 24. 重新生成不会重复消息
    it('Macro_rebuild_no_duplicate', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('Alice', '描述{{user}}', '', '', '你好{{char}}');
      const msgs: ChatMessage[] = [makeAssistantMsg('你好{{char}}'), makeUserMsg('继续')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = { character: char, messages: msgs, macroContext: macroCtx };

      const result1: PromptBuildResult = b.build(context);
      const result2: PromptBuildResult = b.build(context);

      expect(result1.messages.length).assertEqual(result2.messages.length);
      expect(result1.messages[0].content).assertEqual(result2.messages[0].content);
      expect(result1.messages[1].content).assertEqual(result2.messages[1].content);
    });

    // 额外:无 macroContext 时不执行替换(向后兼容)
    it('Macro_no_context_no_replacement', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('Alice', '描述{{user}}');
      const msgs: ChatMessage[] = [makeUserMsg('你好 {{char}}')];
      const context: PromptBuildContext = { character: char, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // 无 macroContext,宏保持原样
      expect(result.messages[1].content).assertEqual('你好 {{char}}');
    });
  });
}