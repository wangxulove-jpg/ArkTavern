/**
 * ChatPersistenceService 设备测试(28 项)
 * 独立测试数据库 arktavern_repository_test.db,每个测试前后清理
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import { MessageRepository } from '../../../main/ets/repositories/MessageRepository';
import { ChatPersistenceOperations } from '../../../main/ets/repositories/ChatPersistenceOperations';
import { MessageSwipeRepository } from '../../../main/ets/repositories/MessageSwipeRepository';
import { ChatPersistenceService, AppendUserAndAssistantResult } from '../../../main/ets/services/ChatPersistenceService';
import { ChatMessage, ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ChatMessageSource } from '../../../main/ets/models/ChatMessageSource';
import { Chat } from '../../../main/ets/models/Chat';
import { PersistedChatSession } from '../../../main/ets/models/PersistedChatSession';
import { DatabaseError } from '../../../main/ets/models/DatabaseError';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_MESSAGE_SWIPE_CANDIDATES
} from '../../../main/ets/database/DatabaseConstants';

const REPO_TEST_DB_NAME: string = 'arktavern_repository_test.db';
let idCounter: number = 0;

function uniqueId(prefix: string): string {
  idCounter++;
  return `${prefix}-${idCounter}`;
}
async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}
async function deleteTestDbIfExists(ctx: common.Context): Promise<void> {
  try {
    const config: relationalStore.StoreConfig = {
      name: REPO_TEST_DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore =
      await relationalStore.getRdbStore(ctx, config);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGES);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHATS);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHARACTERS);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGE_SWIPE_GROUPS);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGE_SWIPE_CANDIDATES);
    await store.close();
  } catch (e) {
    /* cleanup best-effort */
  }
}
async function makeHelper(): Promise<DbHelper> {
  const helper: DbHelper = new DbHelper(REPO_TEST_DB_NAME, []);
  const ctx: common.Context = await getContext();
  await deleteTestDbIfExists(ctx);
  await helper.initialize(ctx);
  return helper;
}
async function cleanupHelper(helper: DbHelper): Promise<void> {
  try {
    await helper.close();
  } catch (e) {
    /* ignore */
  }
  const ctx: common.Context = await getContext();
  await deleteTestDbIfExists(ctx);
}
function makeMessage(
  id: string,
  role: ChatRole,
  content: string,
  status?: ChatMessageStatus,
  source?: ChatMessageSource
): ChatMessage {
  const resolvedStatus: ChatMessageStatus =
    status !== undefined ? status : ChatMessageStatus.Completed;
  return {
    id: id,
    role: role,
    content: content,
    createdAt: 1000,
    updatedAt: 1000,
    status: resolvedStatus,
    isStreaming: resolvedStatus === ChatMessageStatus.Streaming,
    source: source
  };
}
function makeStreamingMessage(
  id: string,
  role: ChatRole,
  content: string
): ChatMessage {
  return makeMessage(id, role, content, ChatMessageStatus.Streaming);
}
function makeUpdatedMessage(
  original: ChatMessage,
  content: string,
  status: ChatMessageStatus,
  errorMessage?: string
): ChatMessage {
  return {
    id: original.id,
    role: original.role,
    content: content,
    createdAt: original.createdAt,
    updatedAt: 2000,
    status: status,
    isStreaming: status === ChatMessageStatus.Streaming,
    errorMessage: errorMessage
  };
}
function setupService(helper: DbHelper): ChatPersistenceService {
  const chatRepo: ChatRepository = new ChatRepository(helper);
  const msgRepo: MessageRepository = new MessageRepository(helper);
  const swipeRepo: MessageSwipeRepository = new MessageSwipeRepository(helper);
  const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
    helper, chatRepo, msgRepo, swipeRepo
  );
  return new ChatPersistenceService(helper, chatRepo, msgRepo, ops);
}

export default function chatPersistenceServiceDeviceTest(): void {
  describe('ChatPersistenceServiceDeviceTest', () => {
    // ===== 会话创建和恢复 =====
    it('createSession_plain_returns_empty_messages', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        expect(session.chat.id.length > 0).assertTrue();
        expect(session.chat.characterId === undefined).assertTrue();
        expect(session.messages.length).assertEqual(0);
        expect(session.maxSequenceNumber).assertEqual(0);
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const found: Chat | null = await chatRepo.getById(session.chat.id);
        expect(found !== null).assertTrue();
        expect(found!.characterId === undefined).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('createSession_with_character_persists_characterId', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const charId: string = uniqueId('char');
        const title: string = '角色对话';
        const session: PersistedChatSession =
          await service.createSession(charId, title);
        expect(session.chat.characterId).assertEqual(charId);
        expect(session.chat.title).assertEqual(title);
        expect(session.messages.length).assertEqual(0);
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const found: Chat | null = await chatRepo.getById(session.chat.id);
        expect(found !== null).assertTrue();
        expect(found!.characterId).assertEqual(charId);
        expect(found!.title).assertEqual(title);
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('createSessionWithFirstMessage_includes_firstMessage_seq1', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const charId: string = uniqueId('char');
        const firstMsg: ChatMessage = makeMessage(
          uniqueId('fm'), ChatRole.Assistant, '开场白',
          ChatMessageStatus.Completed, ChatMessageSource.CharacterFirstMessage
        );
        const session: PersistedChatSession =
          await service.createSessionWithFirstMessage(charId, '标题', firstMsg);
        expect(session.messages.length).assertEqual(1);
        expect(session.messages[0].id).assertEqual(firstMsg.id);
        expect(session.maxSequenceNumber).assertEqual(1);
        const reopened: PersistedChatSession | null =
          await service.openLatestSession(charId);
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages.length).assertEqual(1);
        expect(reopened!.messages[0].id).assertEqual(firstMsg.id);
        expect(reopened!.maxSequenceNumber).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('createSessionWithFirstMessage_undefined_creates_empty', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession =
          await service.createSessionWithFirstMessage(undefined, '空', undefined);
        expect(session.messages.length).assertEqual(0);
        expect(session.maxSequenceNumber).assertEqual(0);
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const found: Chat | null = await chatRepo.getById(session.chat.id);
        expect(found !== null).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('openLatestSession_restores_plain_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const created: PersistedChatSession = await service.createSession();
        const session: PersistedChatSession | null =
          await service.openLatestSession();
        expect(session !== null).assertTrue();
        expect(session!.chat.id).assertEqual(created.chat.id);
        expect(session!.chat.characterId === undefined).assertTrue();
        expect(session!.messages.length).assertEqual(0);
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('openLatestSession_restores_character_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const charId: string = uniqueId('char');
        const created: PersistedChatSession =
          await service.createSession(charId, '角色');
        const session: PersistedChatSession | null =
          await service.openLatestSession(charId);
        expect(session !== null).assertTrue();
        expect(session!.chat.id).assertEqual(created.chat.id);
        expect(session!.chat.characterId).assertEqual(charId);
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('openLatestSession_does_not_restore_other_character', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const charA: string = uniqueId('charA');
        const charB: string = uniqueId('charB');
        await service.createSession(charA, 'A');
        const session: PersistedChatSession | null =
          await service.openLatestSession(charB);
        expect(session === null).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('openLatestSession_skips_archived_chat', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const created: PersistedChatSession = await service.createSession();
        const chatRepo: ChatRepository = new ChatRepository(helper);
        await chatRepo.setArchived(created.chat.id, true);
        const session: PersistedChatSession | null =
          await service.openLatestSession();
        expect(session === null).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('openLatestSession_returns_messages_ascending', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const firstMsg: ChatMessage = makeMessage(
          uniqueId('fm'), ChatRole.Assistant, 'first',
          ChatMessageStatus.Completed, ChatMessageSource.CharacterFirstMessage
        );
        const session: PersistedChatSession =
          await service.createSessionWithFirstMessage(undefined, 't', firstMsg);
        const userMsg: ChatMessage =
          makeMessage(uniqueId('u'), ChatRole.User, 'hi');
        const astMsg: ChatMessage =
          makeMessage(uniqueId('a'), ChatRole.Assistant, 'hello');
        await service.appendMessage(session.chat.id, userMsg);
        await service.appendMessage(session.chat.id, astMsg);
        const reopened: PersistedChatSession | null =
          await service.openLatestSession();
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages.length).assertEqual(3);
        expect(reopened!.messages[0].id).assertEqual(firstMsg.id);
        expect(reopened!.messages[1].id).assertEqual(userMsg.id);
        expect(reopened!.messages[2].id).assertEqual(astMsg.id);
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('openLatestSession_maxSequenceNumber_correct', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const empty: PersistedChatSession = await service.createSession();
        const s0: PersistedChatSession | null =
          await service.openLatestSession();
        expect(s0 !== null).assertTrue();
        expect(s0!.maxSequenceNumber).assertEqual(0);
        const userMsg: ChatMessage =
          makeMessage(uniqueId('u'), ChatRole.User, 'hi');
        await service.appendMessage(empty.chat.id, userMsg);
        const s1: PersistedChatSession | null =
          await service.openLatestSession();
        expect(s1 !== null).assertTrue();
        expect(s1!.maxSequenceNumber).assertEqual(1);
      } finally {
        await cleanupHelper(helper);
      }
    });
    // ===== firstMessage =====
    it('firstMessage_not_duplicated_on_reload', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const firstMsg: ChatMessage = makeMessage(
          uniqueId('fm'), ChatRole.Assistant, '开场',
          ChatMessageStatus.Completed, ChatMessageSource.CharacterFirstMessage
        );
        await service.createSessionWithFirstMessage(undefined, 't', firstMsg);
        const r1: PersistedChatSession | null =
          await service.openLatestSession();
        const r2: PersistedChatSession | null =
          await service.openLatestSession();
        expect(r1 !== null).assertTrue();
        expect(r2 !== null).assertTrue();
        expect(r1!.messages.length).assertEqual(1);
        expect(r2!.messages.length).assertEqual(1);
        expect(r2!.messages[0].id).assertEqual(firstMsg.id);
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('firstMessage_source_is_CharacterFirstMessage', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const firstMsg: ChatMessage = makeMessage(
          uniqueId('fm'), ChatRole.Assistant, '开场',
          ChatMessageStatus.Completed, ChatMessageSource.CharacterFirstMessage
        );
        await service.createSessionWithFirstMessage(undefined, 't', firstMsg);
        const session: PersistedChatSession | null =
          await service.openLatestSession();
        expect(session !== null).assertTrue();
        expect(session!.messages[0].source).assertEqual(
          ChatMessageSource.CharacterFirstMessage
        );
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('firstMessage_macros_preserved', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const raw: string = '你好 {{user}},我是 {{char}}。';
        const firstMsg: ChatMessage = makeMessage(
          uniqueId('fm'), ChatRole.Assistant, raw,
          ChatMessageStatus.Completed, ChatMessageSource.CharacterFirstMessage
        );
        await service.createSessionWithFirstMessage(undefined, 't', firstMsg);
        const session: PersistedChatSession | null =
          await service.openLatestSession();
        expect(session !== null).assertTrue();
        expect(session!.messages[0].content).assertEqual(raw);
        expect(session!.messages[0].source).assertEqual(
          ChatMessageSource.CharacterFirstMessage
        );
      } finally {
        await cleanupHelper(helper);
      }
    });
    // ===== 消息追加和更新 =====
    it('appendMessage_returns_sequenceNumber', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const userMsg: ChatMessage =
          makeMessage(uniqueId('u'), ChatRole.User, 'hello');
        const seq: number =
          await service.appendMessage(session.chat.id, userMsg);
        expect(seq).assertEqual(1);
        const reopened: PersistedChatSession | null =
          await service.loadSession(session.chat.id);
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages.length).assertEqual(1);
        expect(reopened!.messages[0].id).assertEqual(userMsg.id);
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('appendUserAndStreamingAssistant_returns_both_sequences', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const userMsg: ChatMessage =
          makeMessage(uniqueId('u'), ChatRole.User, 'q');
        const astMsg: ChatMessage =
          makeStreamingMessage(uniqueId('a'), ChatRole.Assistant, '');
        const result: AppendUserAndAssistantResult =
          await service.appendUserAndStreamingAssistant(
            session.chat.id, userMsg, astMsg
          );
        expect(result.userSequenceNumber).assertEqual(1);
        expect(result.assistantSequenceNumber).assertEqual(2);
        const reopened: PersistedChatSession | null =
          await service.loadSession(session.chat.id);
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages.length).assertEqual(2);
        expect(reopened!.messages[0].id).assertEqual(userMsg.id);
        expect(reopened!.messages[1].id).assertEqual(astMsg.id);
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('updateMessage_updates_content', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const astMsg: ChatMessage =
          makeStreamingMessage(uniqueId('a'), ChatRole.Assistant, '');
        await service.appendMessage(session.chat.id, astMsg);
        const updated: ChatMessage = makeUpdatedMessage(
          astMsg, 'final content', ChatMessageStatus.Streaming
        );
        await service.updateMessage(session.chat.id, updated);
        const reopened: PersistedChatSession | null =
          await service.loadSession(session.chat.id);
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages[0].content).assertEqual('final content');
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('updateMessage_streaming_to_completed', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const astMsg: ChatMessage =
          makeStreamingMessage(uniqueId('a'), ChatRole.Assistant, 'partial');
        await service.appendMessage(session.chat.id, astMsg);
        const updated: ChatMessage = makeUpdatedMessage(
          astMsg, 'done', ChatMessageStatus.Completed
        );
        await service.updateMessage(session.chat.id, updated);
        const reopened: PersistedChatSession | null =
          await service.loadSession(session.chat.id);
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages[0].status).assertEqual(
          ChatMessageStatus.Completed
        );
        expect(reopened!.messages[0].isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('updateMessage_streaming_to_cancelled', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const astMsg: ChatMessage =
          makeStreamingMessage(uniqueId('a'), ChatRole.Assistant, 'partial');
        await service.appendMessage(session.chat.id, astMsg);
        const updated: ChatMessage = makeUpdatedMessage(
          astMsg, 'partial', ChatMessageStatus.Cancelled
        );
        await service.updateMessage(session.chat.id, updated);
        const reopened: PersistedChatSession | null =
          await service.loadSession(session.chat.id);
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages[0].status).assertEqual(
          ChatMessageStatus.Cancelled
        );
        expect(reopened!.messages[0].isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('updateMessage_streaming_to_failed_with_error', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const astMsg: ChatMessage =
          makeStreamingMessage(uniqueId('a'), ChatRole.Assistant, 'partial');
        await service.appendMessage(session.chat.id, astMsg);
        const updated: ChatMessage = makeUpdatedMessage(
          astMsg, 'partial', ChatMessageStatus.Failed, '生成失败'
        );
        await service.updateMessage(session.chat.id, updated);
        const reopened: PersistedChatSession | null =
          await service.loadSession(session.chat.id);
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages[0].status).assertEqual(
          ChatMessageStatus.Failed
        );
        expect(reopened!.messages[0].isStreaming).assertFalse();
        expect(reopened!.messages[0].errorMessage).assertEqual('生成失败');
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('content_with_emoji_markdown_roundtrip', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const raw: string = '你好世界 🌍 **粗体** _斜体_ `代码`\n## 标题\n- 列表项';
        const userMsg: ChatMessage =
          makeMessage(uniqueId('u'), ChatRole.User, raw);
        await service.appendMessage(session.chat.id, userMsg);
        const reopened: PersistedChatSession | null =
          await service.loadSession(session.chat.id);
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages[0].content).assertEqual(raw);
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('appendMessage_updates_chat_timestamps', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const originalUpdatedAt: number = session.chat.updatedAt;
        expect(session.chat.lastMessageAt).assertEqual(0);
        const userMsg: ChatMessage =
          makeMessage(uniqueId('u'), ChatRole.User, 'hi');
        await service.appendMessage(session.chat.id, userMsg);
        const chatRepo: ChatRepository = new ChatRepository(helper);
        const reloaded: Chat | null = await chatRepo.getById(session.chat.id);
        expect(reloaded !== null).assertTrue();
        expect(reloaded!.lastMessageAt > 0).assertTrue();
        expect(reloaded!.lastMessageAt).assertEqual(reloaded!.updatedAt);
        expect(reloaded!.updatedAt >= originalUpdatedAt).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('appendMessage_sequence_increments', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const seq1: number = await service.appendMessage(
          session.chat.id, makeMessage(uniqueId('u1'), ChatRole.User, 'a')
        );
        const seq2: number = await service.appendMessage(
          session.chat.id, makeMessage(uniqueId('u2'), ChatRole.User, 'b')
        );
        const seq3: number = await service.appendMessage(
          session.chat.id, makeMessage(uniqueId('u3'), ChatRole.User, 'c')
        );
        expect(seq1).assertEqual(1);
        expect(seq2).assertEqual(2);
        expect(seq3).assertEqual(3);
        const reopened: PersistedChatSession | null =
          await service.loadSession(session.chat.id);
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages.length).assertEqual(3);
        expect(reopened!.maxSequenceNumber).assertEqual(3);
      } finally {
        await cleanupHelper(helper);
      }
    });
    // ===== 中断恢复 =====
    it('openLatestSession_normalizes_streaming_to_cancelled', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const userMsg: ChatMessage =
          makeMessage(uniqueId('u'), ChatRole.User, 'q');
        const astMsg: ChatMessage =
          makeStreamingMessage(uniqueId('a'), ChatRole.Assistant, 'partial');
        await service.appendUserAndStreamingAssistant(
          session.chat.id, userMsg, astMsg
        );
        const reopened: PersistedChatSession | null =
          await service.openLatestSession();
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages.length).assertEqual(2);
        expect(reopened!.messages[0].status).assertEqual(
          ChatMessageStatus.Completed
        );
        expect(reopened!.messages[1].status).assertEqual(
          ChatMessageStatus.Cancelled
        );
        expect(reopened!.messages[1].isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('normalize_keeps_partial_content', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const userMsg: ChatMessage =
          makeMessage(uniqueId('u'), ChatRole.User, 'q');
        const astMsg: ChatMessage =
          makeStreamingMessage(uniqueId('a'), ChatRole.Assistant, '中断前内容');
        await service.appendUserAndStreamingAssistant(
          session.chat.id, userMsg, astMsg
        );
        const reopened: PersistedChatSession | null =
          await service.openLatestSession();
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages[1].content).assertEqual('中断前内容');
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('normalize_does_not_touch_completed', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const userMsg: ChatMessage =
          makeMessage(uniqueId('u'), ChatRole.User, 'q');
        await service.appendMessage(session.chat.id, userMsg);
        const reopened: PersistedChatSession | null =
          await service.openLatestSession();
        expect(reopened !== null).assertTrue();
        expect(reopened!.messages[0].status).assertEqual(
          ChatMessageStatus.Completed
        );
        expect(reopened!.messages[0].isStreaming).assertFalse();
      } finally {
        await cleanupHelper(helper);
      }
    });
    // ===== 安全 =====
    it('appendMessage_rejects_CharacterPrompt_source', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const bad: ChatMessage = makeMessage(
          uniqueId('u'), ChatRole.System, 'sys',
          ChatMessageStatus.Completed, ChatMessageSource.CharacterPrompt
        );
        let threw: boolean = false;
        try {
          await service.appendMessage(session.chat.id, bad);
        } catch (e) {
          threw = true;
          expect(e instanceof DatabaseError).assertTrue();
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('appendMessage_rejects_LorebookBefore_source', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const bad: ChatMessage = makeMessage(
          uniqueId('u'), ChatRole.System, 'sys',
          ChatMessageStatus.Completed, ChatMessageSource.LorebookBefore
        );
        let threw: boolean = false;
        try {
          await service.appendMessage(session.chat.id, bad);
        } catch (e) {
          threw = true;
          expect(e instanceof DatabaseError).assertTrue();
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
    it('appendMessage_rejects_LorebookAfter_source', 0, async () => {
      const helper: DbHelper = await makeHelper();
      try {
        const service: ChatPersistenceService = setupService(helper);
        const session: PersistedChatSession = await service.createSession();
        const bad: ChatMessage = makeMessage(
          uniqueId('u'), ChatRole.System, 'sys',
          ChatMessageStatus.Completed, ChatMessageSource.LorebookAfter
        );
        let threw: boolean = false;
        try {
          await service.appendMessage(session.chat.id, bad);
        } catch (e) {
          threw = true;
          expect(e instanceof DatabaseError).assertTrue();
        }
        expect(threw).assertTrue();
      } finally {
        await cleanupHelper(helper);
      }
    });
  });
}
