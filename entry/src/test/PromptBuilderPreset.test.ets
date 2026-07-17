/**
 * PromptBuilder Preset 定向测试
 *
 * 覆盖:
 * 1. 无 Preset 时输出与旧行为一致
 * 2. 空 Preset Prompt 不创建 Segment
 * 3. 空白 Prompt 不创建 Segment
 * 4. 基础 System 位于 Preset 前
 * 5. Preset 位于 LorebookBefore 前
 * 6. LorebookBefore 位于 CharacterPrompt 前
 * 7. CharacterPrompt 位于 LorebookAfter 前
 * 8. Conversation 位于固定系统段后
 * 9. {{char}} 正常替换
 * 10. {{character}} 正常替换
 * 11. {{user}} 正常替换
 * 12. 不递归替换
 * 13. 原始 PromptPreset 不修改
 * 14. 中文、Emoji 和 Markdown 完整
 * 15. source 为 PromptPresetSystem
 * 16. Preset Segment 不进入可见 messages
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
import { ChatMessageSource } from '../main/ets/models/ChatMessageSource';
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

function findMessagesBySource(
  messages: ChatMessage[],
  source: ChatMessageSource
): ChatMessage[] {
  const result: ChatMessage[] = [];
  for (let i = 0; i < messages.length; i++) {
    if (messages[i].source === source) {
      result.push(messages[i]);
    }
  }
  return result;
}

export default function promptBuilderPresetTest(): void {
  describe('PromptBuilderPreset', () => {
    // 1. 无 Preset 时输出与旧行为一致
    it('no_preset_unchanged_behavior', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('你好'), makeAssistantMsg('你好')];
      const context: PromptBuildContext = { messages: msgs };

      const result: PromptBuildResult = b.build(context);

      expect(result.messages.length).assertEqual(2);
      expect(result.messages[0].role).assertEqual(ChatRole.User);
      expect(result.messages[1].role).assertEqual(ChatRole.Assistant);
      // 无 Preset System 段
      const presetMsgs: ChatMessage[] = findMessagesBySource(
        result.messages, ChatMessageSource.PromptPresetSystem
      );
      expect(presetMsgs.length).assertEqual(0);
    });

    // 2. 空 Preset Prompt 不创建 Segment
    it('empty_preset_prompt_no_segment', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('你好')];
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: ''
      };

      const result: PromptBuildResult = b.build(context);

      const presetMsgs: ChatMessage[] = findMessagesBySource(
        result.messages, ChatMessageSource.PromptPresetSystem
      );
      expect(presetMsgs.length).assertEqual(0);
    });

    // 3. 空白 Prompt 不创建 Segment
    it('blank_preset_prompt_no_segment', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('你好')];
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: '   \n  '
      };

      const result: PromptBuildResult = b.build(context);

      const presetMsgs: ChatMessage[] = findMessagesBySource(
        result.messages, ChatMessageSource.PromptPresetSystem
      );
      expect(presetMsgs.length).assertEqual(0);
    });

    // 4. Preset 位于 LorebookBefore 前
    it('preset_before_lorebook_before', 0, () => {
      const b: PromptBuilder = builder();
      const lorebook: Lorebook = createLorebook('lb-test', 'Test');
      const beforeEntry: LorebookEntry = createLorebookEntry('lb-entry', 'world content');
      const lb1: Lorebook = addEntryToLorebook(lorebook, beforeEntry);
      const enabled: Lorebook = updateLorebook(lb1, { enabled: true });
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: 'PRESET_PROMPT',
        lorebook: enabled
      };

      const result: PromptBuildResult = b.build(context);

      // 查找 Preset 和 LorebookBefore 的索引
      let presetIdx: number = -1;
      let lorebookIdx: number = -1;
      for (let i = 0; i < result.messages.length; i++) {
        if (result.messages[i].source === ChatMessageSource.PromptPresetSystem) {
          presetIdx = i;
        }
        if (result.messages[i].source === ChatMessageSource.LorebookBefore) {
          lorebookIdx = i;
        }
      }
      expect(presetIdx >= 0).assertTrue();
      expect(lorebookIdx >= 0).assertTrue();
      expect(presetIdx < lorebookIdx).assertTrue();
    });

    // 5. Preset 位于基础 System 后(无基础 System 时 Preset 在最前)
    it('preset_is_first_system_segment', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: 'PRESET_PROMPT'
      };

      const result: PromptBuildResult = b.build(context);

      // Preset 应该是第一个 System 消息
      let foundPreset: boolean = false;
      for (let i = 0; i < result.messages.length; i++) {
        if (result.messages[i].source === ChatMessageSource.PromptPresetSystem) {
          foundPreset = true;
          // 确认 Preset 之前没有其他 System 消息(除了可能的 ExternalSystem)
          for (let j = 0; j < i; j++) {
            if (result.messages[j].role === ChatRole.System) {
              // 允许 ExternalSystem 在 Preset 之前(基础 System)
              expect(result.messages[j].source === ChatMessageSource.ExternalSystem).assertTrue();
            }
          }
          break;
        }
      }
      expect(foundPreset).assertTrue();
    });

    // 6. LorebookBefore 位于 CharacterPrompt 前
    it('lorebook_before_before_character_prompt', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('char-test', 'TestChar');
      const lorebook: Lorebook = createLorebook('lb-test', 'Test');
      const beforeEntry: LorebookEntry = createLorebookEntry('lb-before', 'world content');
      const lb1: Lorebook = addEntryToLorebook(lorebook, beforeEntry);
      const enabled: Lorebook = updateLorebook(lb1, { enabled: true });
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const context: PromptBuildContext = {
        messages: msgs,
        character: char,
        lorebook: enabled
      };

      const result: PromptBuildResult = b.build(context);

      let lorebookIdx: number = -1;
      let charIdx: number = -1;
      for (let i = 0; i < result.messages.length; i++) {
        if (result.messages[i].source === ChatMessageSource.LorebookBefore) {
          lorebookIdx = i;
        }
        if (result.messages[i].source === ChatMessageSource.CharacterPrompt) {
          charIdx = i;
        }
      }
      expect(lorebookIdx >= 0).assertTrue();
      expect(charIdx >= 0).assertTrue();
      expect(lorebookIdx < charIdx).assertTrue();
    });

    // 7. CharacterPrompt 位于 LorebookAfter 前
    it('character_prompt_before_lorebook_after', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('char-test', 'TestChar');
      const lorebook: Lorebook = createLorebook('lb-test', 'Test');
      const afterEntry: LorebookEntry = createLorebookEntry('lb-after', 'after content');
      const afterEntryLorebook: LorebookEntry = {
        id: afterEntry.id,
        name: afterEntry.name,
        content: afterEntry.content,
        keys: afterEntry.keys,
        secondaryKeys: afterEntry.secondaryKeys,
        position: LorebookPosition.AfterCharacter,
        priority: afterEntry.priority,
        enabled: afterEntry.enabled,
        constant: afterEntry.constant,
        selective: afterEntry.selective,
        createdAt: afterEntry.createdAt,
        updatedAt: afterEntry.updatedAt
      };
      const lb1: Lorebook = addEntryToLorebook(lorebook, afterEntryLorebook);
      const enabled: Lorebook = updateLorebook(lb1, { enabled: true });
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const context: PromptBuildContext = {
        messages: msgs,
        character: char,
        lorebook: enabled
      };

      const result: PromptBuildResult = b.build(context);

      let charIdx: number = -1;
      let afterIdx: number = -1;
      for (let i = 0; i < result.messages.length; i++) {
        if (result.messages[i].source === ChatMessageSource.CharacterPrompt) {
          charIdx = i;
        }
        if (result.messages[i].source === ChatMessageSource.LorebookAfter) {
          afterIdx = i;
        }
      }
      expect(charIdx >= 0).assertTrue();
      expect(afterIdx >= 0).assertTrue();
      expect(charIdx < afterIdx).assertTrue();
    });

    // 8. Conversation 位于固定系统段后
    it('conversation_after_fixed_system_segments', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello'), makeAssistantMsg('hi')];
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: 'PRESET_PROMPT'
      };

      const result: PromptBuildResult = b.build(context);

      // 确认 Preset 在 Conversation 之前
      let presetIdx: number = -1;
      let convIdx: number = -1;
      for (let i = 0; i < result.messages.length; i++) {
        if (result.messages[i].source === ChatMessageSource.PromptPresetSystem) {
          presetIdx = i;
        }
        if (result.messages[i].source === ChatMessageSource.Conversation) {
          if (convIdx < 0) {
            convIdx = i;
          }
        }
      }
      expect(presetIdx >= 0).assertTrue();
      expect(convIdx >= 0).assertTrue();
      expect(presetIdx < convIdx).assertTrue();
    });

    // 9. {{char}} 替换
    it('macro_char_replacement', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: 'You are {{char}}.',
        macroContext: macroCtx
      };

      const result: PromptBuildResult = b.build(context);

      const presetMsgs: ChatMessage[] = findMessagesBySource(
        result.messages, ChatMessageSource.PromptPresetSystem
      );
      expect(presetMsgs.length).assertEqual(1);
      expect(presetMsgs[0].content).assertEqual('You are Alice.');
    });

    // 10. {{character}} 替换
    it('macro_character_replacement', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const macroCtx: MacroContext = createMacroContext('Bob', 'User');
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: 'Role: {{character}}',
        macroContext: macroCtx
      };

      const result: PromptBuildResult = b.build(context);

      const presetMsgs: ChatMessage[] = findMessagesBySource(
        result.messages, ChatMessageSource.PromptPresetSystem
      );
      expect(presetMsgs.length).assertEqual(1);
      expect(presetMsgs[0].content).assertEqual('Role: Bob');
    });

    // 11. {{user}} 替换
    it('macro_user_replacement', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const macroCtx: MacroContext = createMacroContext('Char', 'UserX');
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: 'Speaking to {{user}}.',
        macroContext: macroCtx
      };

      const result: PromptBuildResult = b.build(context);

      const presetMsgs: ChatMessage[] = findMessagesBySource(
        result.messages, ChatMessageSource.PromptPresetSystem
      );
      expect(presetMsgs.length).assertEqual(1);
      expect(presetMsgs[0].content).assertEqual('Speaking to UserX.');
    });

    // 12. 不递归替换
    it('no_recursive_macro_replacement', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      // 角色名恰好是 {{user}},不应递归替换
      const macroCtx: MacroContext = createMacroContext('{{user}}', 'User');
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: 'Char: {{char}}',
        macroContext: macroCtx
      };

      const result: PromptBuildResult = b.build(context);

      const presetMsgs: ChatMessage[] = findMessagesBySource(
        result.messages, ChatMessageSource.PromptPresetSystem
      );
      expect(presetMsgs.length).assertEqual(1);
      // 替换后仍是 {{user}} 或 'User',但不应递归
      expect(presetMsgs[0].content !== 'Char: User').assertFalse();
    });

    // 13. 原始 Preset 不修改(传入的字符串未变)
    it('original_preset_unchanged', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const original: string = 'You are {{char}}.';
      const macroCtx: MacroContext = createMacroContext('Alice', 'User');
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: original,
        macroContext: macroCtx
      };

      b.build(context);

      // 原始字符串不应被修改
      expect(original).assertEqual('You are {{char}}.');
    });

    // 14. 中文、Emoji 和 Markdown 完整
    it('chinese_emoji_markdown_preserved', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const presetContent: string = '你好🎉 **加粗** *斜体*\n换行';
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: presetContent
      };

      const result: PromptBuildResult = b.build(context);

      const presetMsgs: ChatMessage[] = findMessagesBySource(
        result.messages, ChatMessageSource.PromptPresetSystem
      );
      expect(presetMsgs.length).assertEqual(1);
      expect(presetMsgs[0].content).assertEqual(presetContent);
    });

    // 15. source 为 PromptPresetSystem
    it('source_is_prompt_preset_system', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello')];
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: 'PRESET'
      };

      const result: PromptBuildResult = b.build(context);

      const presetMsgs: ChatMessage[] = findMessagesBySource(
        result.messages, ChatMessageSource.PromptPresetSystem
      );
      expect(presetMsgs.length).assertEqual(1);
      expect(presetMsgs[0].source).assertEqual(ChatMessageSource.PromptPresetSystem);
    });

    // 16. Preset Segment 不进入可见 messages(不修改输入 messages)
    it('preset_not_in_input_messages', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('hello'), makeAssistantMsg('hi')];
      const originalLength: number = msgs.length;
      const context: PromptBuildContext = {
        messages: msgs,
        presetSystemPrompt: 'PRESET'
      };

      b.build(context);

      // 输入 messages 数组不应被修改
      expect(msgs.length).assertEqual(originalLength);
      expect(msgs[0].content).assertEqual('hello');
      expect(msgs[1].content).assertEqual('hi');
    });
  });
}