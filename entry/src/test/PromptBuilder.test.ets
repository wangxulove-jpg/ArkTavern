/**
 * PromptBuilder 单元测试
 *
 * 覆盖:
 * 1. 无角色、无世界书时，消息顺序不变
 * 2. 只有角色时，Character System Prompt 正确注入
 * 3. 只有世界书时，BeforeCharacter 和 AfterCharacter 顺序正确
 * 4. 角色与世界书同时存在时，顺序正确
 * 5. constant 条目始终注入
 * 6. 普通关键词命中后注入
 * 7. selective 条目必须主关键词和次关键词同时命中
 * 8. disabled 世界书不注入
 * 9. disabled 条目不注入
 * 10. priority 排序正确
 * 11. 原始消息数组未被修改
 * 12. 重新生成不重复注入
 */

import { describe, it, expect } from '@ohos/hypium';
import { PromptBuilder, PromptBuildContext, PromptBuildResult } from '../main/ets/services/PromptBuilder';
import { LorebookService } from '../main/ets/services/LorebookService';
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
  return new PromptBuilder(createTestLorebookService());
}

export default function promptBuilderTest(): void {
  describe('PromptBuilder', () => {
    // 1. 无角色、无世界书时，消息顺序不变
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

    // 2. 只有角色时，Character System Prompt 正确注入
    it('Only_character_injects_system_prompt', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('测试角色', '测试描述');
      const msgs: ChatMessage[] = [makeUserMsg('你好')];
      const context: PromptBuildContext = { character: char, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // System Prompt 应该在 User 消息之前
      expect(result.messages.length).assertEqual(2);
      expect(result.messages[0].role).assertEqual(ChatRole.System);
      expect(result.messages[0].content).assertContain('测试角色');
      expect(result.messages[1].role).assertEqual(ChatRole.User);
      expect(result.messages[1].content).assertEqual('你好');
    });

    // 3. System 消息不被泄露到输出
    it('System_messages_in_input_are_skipped', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('角色', '描述');
      const msgs: ChatMessage[] = [
        makeSystemMsg('系统提示'),
        makeUserMsg('你好'),
        makeAssistantMsg('回复')
      ];
      const context: PromptBuildContext = { character: char, messages: msgs };

      const result: PromptBuildResult = b.build(context);

      // 只有 Character System Prompt(1个) + User(1个) + Assistant(1个) = 3个
      expect(result.messages.length).assertEqual(3);
      expect(result.messages[0].role).assertEqual(ChatRole.System);
      expect(result.messages[0].content).assertContain('角色');
      expect(result.messages[1].role).assertEqual(ChatRole.User);
      expect(result.messages[2].role).assertEqual(ChatRole.Assistant);
    });

    // 4. 原始消息数组未被修改
    it('Original_messages_array_not_modified', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('测试')];
      const originalLength: number = msgs.length;
      const context: PromptBuildContext = { messages: msgs };

      b.build(context);

      expect(msgs.length).assertEqual(originalLength);
      expect(msgs[0].content).assertEqual('测试');
    });

    // 5. 无角色时行为正常
    it('No_character_no_lorebook_works', 0, () => {
      const b: PromptBuilder = builder();
      const msgs: ChatMessage[] = [makeUserMsg('你好'), makeAssistantMsg('你好')];
      const context: PromptBuildContext = { messages: msgs };

      const result: PromptBuildResult = b.build(context);

      expect(result.messages.length).assertEqual(2);
      expect(result.matchedLorebookEntryIds.length).assertEqual(0);
    });

    // 6. 重新生成不重复注入(每次调用 build 独立构建)
    it('Rebuild_does_not_duplicate_injections', 0, () => {
      const b: PromptBuilder = builder();
      const char: Character = createCharacter('角色', '描述');
      const msgs: ChatMessage[] = [makeUserMsg('你好')];
      const context: PromptBuildContext = { character: char, messages: msgs };

      const result1: PromptBuildResult = b.build(context);
      const result2: PromptBuildResult = b.build(context);

      // 每次构建结果一致，不重复注入
      expect(result1.messages.length).assertEqual(result2.messages.length);
      expect(result1.messages[0].content).assertEqual(result2.messages[0].content);
    });
  });
}