/**
 * MessageSwipeRepository 设备测试(ohosTest,需真机/模拟器运行)
 *
 * 覆盖:
 * - 基础查询(getGroup/insertGroup/insertCandidate/getCandidate/listCandidates/countCandidates/remove)
 * - 约束(唯一性/非法值/跨Group)
 * - 数据往返(中文/Emoji/Markdown/多行/Cancelled/Failed/空Streaming/updatedAt)
 * - 安全(ResultSet关闭/映射失败后关闭/不影响其他表/错误不含content)
 *
 * 使用独立测试数据库 arktavern_swipe_repo_test.db。
 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { MessageSwipeRepository } from '../../../main/ets/repositories/MessageSwipeRepository';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate,
  createSwipeCandidate,
  CreateSwipeCandidateOptions,
  MAX_SWIPE_CANDIDATES
} from '../../../main/ets/models/MessageSwipe';
import { ChatMessageStatus } from '../../../main/ets/models/ChatMessage';
import { DatabaseError, DatabaseErrorType } from '../../../main/ets/models/DatabaseError';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_LOREBOOKS,
  TABLE_LOREBOOK_ENTRIES,
  TABLE_PROMPT_PRESETS,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_MESSAGE_SWIPE_CANDIDATES,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_CHARACTER_ID,
  COLUMN_TITLE,
  COLUMN_LAST_MESSAGE_AT,
  COLUMN_IS_ARCHIVED,
  COLUMN_CHAT_ID,
  COLUMN_ROLE,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_IS_STREAMING,
  COLUMN_SOURCE,
  COLUMN_ERROR_MESSAGE,
  COLUMN_SWIPE_ASSISTANT_MESSAGE_ID,
  COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX,
  COLUMN_SWIPE_CANDIDATE_ID,
  COLUMN_SWIPE_CANDIDATE_INDEX,
  COLUMN_PRESET_ID,
  COLUMN_PRESET_NAME,
  COLUMN_PRESET_DESCRIPTION,
  COLUMN_PRESET_SYSTEM_PROMPT,
  COLUMN_PRESET_TEMPERATURE,
  COLUMN_PRESET_TOP_P,
  COLUMN_PRESET_MAX_OUTPUT_TOKENS,
  COLUMN_PRESET_CONTEXT_WINDOW,
  COLUMN_LOREBOOK_ID,
  COLUMN_LOREBOOK_NAME,
  COLUMN_LOREBOOK_ENABLED
} from '../../../main/ets/database/DatabaseConstants';

const TEST_DB_NAME: string = 'arktavern_swipe_repo_test.db';

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function deleteDb(context: common.Context): Promise<void> {
  try {
    await relationalStore.deleteRdbStore(context, TEST_DB_NAME);
  } catch (e) {
    /* best-effort */
  }
}

async function makeRepository(): Promise<MessageSwipeRepository> {
  const ctx: common.Context = await getContext();
  await deleteDb(ctx);
  const helper: DbHelper = new DbHelper(TEST_DB_NAME);
  await helper.initialize(ctx);
  return new MessageSwipeRepository(helper);
}

async function cleanupRepo(repo: MessageSwipeRepository): Promise<void> {
  const ctx: common.Context = await getContext();
  await deleteDb(ctx);
}

function makeGroup(
  assistantMessageId: string,
  chatId: string = 'chat-1',
  activeCandidateIndex: number = 0
): MessageSwipeGroup {
  return {
    assistantMessageId: assistantMessageId,
    chatId: chatId,
    activeCandidateIndex: activeCandidateIndex,
    createdAt: 1000,
    updatedAt: 1000
  };
}

function makeCandidate(
  assistantMessageId: string,
  candidateIndex: number,
  options?: CreateSwipeCandidateOptions
): MessageSwipeCandidate {
  return createSwipeCandidate(assistantMessageId, candidateIndex, options);
}

async function rowCount(
  store: relationalStore.RdbStore, table: string
): Promise<number> {
  const rs = await store.querySql(`SELECT COUNT(*) AS cnt FROM ${table}`);
  try {
    if (rs.goToFirstRow()) {
      const ci: number = rs.getColumnIndex('cnt');
      if (ci >= 0) {
        return rs.getLong(ci);
      }
    }
    return 0;
  } finally {
    try {
      rs.close();
    } catch (e) {
      /* ignore */
    }
  }
}

async function getStore(): Promise<relationalStore.RdbStore> {
  const ctx: common.Context = await getContext();
  const config: relationalStore.StoreConfig = {
    name: TEST_DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  return await relationalStore.getRdbStore(ctx, config);
}

export default function messageSwipeRepositoryTest(): void {
  describe('MessageSwipeRepositoryTest', () => {

    // ===== 基础查询 =====

    it('getGroup_null_when_nonexistent', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const result: MessageSwipeGroup | null = await repo.getGroup('nonexistent');
        expect(result === null).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('insert_group', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const group: MessageSwipeGroup = makeGroup('msg-1');
        await repo.insertGroup(group);
        const fetched: MessageSwipeGroup | null = await repo.getGroup('msg-1');
        expect(fetched !== null).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('getGroup_existing', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const group: MessageSwipeGroup = {
          assistantMessageId: 'msg-1',
          chatId: 'chat-1',
          activeCandidateIndex: 0,
          createdAt: 123456,
          updatedAt: 789012
        };
        await repo.insertGroup(group);
        const fetched: MessageSwipeGroup | null = await repo.getGroup('msg-1');
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.assistantMessageId).assertEqual('msg-1');
          expect(fetched.chatId).assertEqual('chat-1');
          expect(fetched.activeCandidateIndex).assertEqual(0);
          expect(fetched.createdAt).assertEqual(123456);
          expect(fetched.updatedAt).assertEqual(789012);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('insert_candidate', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const candidate: MessageSwipeCandidate = makeCandidate('msg-1', 0);
        await repo.insertCandidate(candidate);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.assistantMessageId).assertEqual('msg-1');
          expect(fetched.candidateIndex).assertEqual(0);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('getCandidate_existing', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const candidate: MessageSwipeCandidate = makeCandidate('msg-1', 0, {
          content: 'Hello World',
          status: ChatMessageStatus.Completed,
          isStreaming: false
        });
        await repo.insertCandidate(candidate);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.id).assertEqual(candidate.id);
          expect(fetched.assistantMessageId).assertEqual('msg-1');
          expect(fetched.candidateIndex).assertEqual(0);
          expect(fetched.content).assertEqual('Hello World');
          expect(fetched.status).assertEqual(ChatMessageStatus.Completed);
          expect(fetched.isStreaming).assertEqual(false);
          expect(fetched.createdAt).assertEqual(candidate.createdAt);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('listCandidates_ordered_by_index', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const c0: MessageSwipeCandidate = makeCandidate('msg-1', 0, { content: 'first' });
        const c1: MessageSwipeCandidate = makeCandidate('msg-1', 1, { content: 'second' });
        const c2: MessageSwipeCandidate = makeCandidate('msg-1', 2, { content: 'third' });
        // 逆序插入
        await repo.insertCandidate(c2);
        await repo.insertCandidate(c0);
        await repo.insertCandidate(c1);
        const list: MessageSwipeCandidate[] = await repo.listCandidates('msg-1');
        expect(list.length).assertEqual(3);
        expect(list[0].candidateIndex).assertEqual(0);
        expect(list[0].content).assertEqual('first');
        expect(list[1].candidateIndex).assertEqual(1);
        expect(list[1].content).assertEqual('second');
        expect(list[2].candidateIndex).assertEqual(2);
        expect(list[2].content).assertEqual('third');
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('countCandidates', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        expect(await repo.countCandidates('msg-1')).assertEqual(0);
        await repo.insertCandidate(makeCandidate('msg-1', 0));
        expect(await repo.countCandidates('msg-1')).assertEqual(1);
        await repo.insertCandidate(makeCandidate('msg-1', 1));
        await repo.insertCandidate(makeCandidate('msg-1', 2));
        expect(await repo.countCandidates('msg-1')).assertEqual(3);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('removeByAssistantMessageId', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        await repo.insertCandidate(makeCandidate('msg-1', 0));
        await repo.insertCandidate(makeCandidate('msg-1', 1));
        const store: relationalStore.RdbStore = await getStore();
        const beforeGroup: number = await rowCount(store, TABLE_MESSAGE_SWIPE_GROUPS);
        const beforeCand: number = await rowCount(store, TABLE_MESSAGE_SWIPE_CANDIDATES);
        expect(beforeGroup).assertEqual(1);
        expect(beforeCand).assertEqual(2);
        try { await store.close(); } catch (e) { /* ignore */ }

        await repo.removeByAssistantMessageId('msg-1');
        const fetched: MessageSwipeGroup | null = await repo.getGroup('msg-1');
        expect(fetched === null).assertTrue();
        const list: MessageSwipeCandidate[] = await repo.listCandidates('msg-1');
        expect(list.length).assertEqual(0);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('removeByChatId', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1', 'chat-1'));
        await repo.insertGroup(makeGroup('msg-2', 'chat-1'));
        await repo.insertGroup(makeGroup('msg-3', 'chat-2'));
        await repo.insertCandidate(makeCandidate('msg-1', 0));
        await repo.insertCandidate(makeCandidate('msg-1', 1));
        await repo.insertCandidate(makeCandidate('msg-2', 0));
        await repo.insertCandidate(makeCandidate('msg-3', 0));
        const removed: number = await repo.removeByChatId('chat-1');
        expect(removed).assertEqual(2);
        // chat-1 的 Group 和 Candidate 应全部删除
        const group1: MessageSwipeGroup | null = await repo.getGroup('msg-1');
        expect(group1 === null).assertTrue();
        const group2: MessageSwipeGroup | null = await repo.getGroup('msg-2');
        expect(group2 === null).assertTrue();
        // chat-2 的数据不受影响
        const group3: MessageSwipeGroup | null = await repo.getGroup('msg-3');
        expect(group3 !== null).assertTrue();
        const list3: MessageSwipeCandidate[] = await repo.listCandidates('msg-3');
        expect(list3.length).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('removeByAssistantMessageId_idempotent', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        // 不存在时不应抛出
        await repo.removeByAssistantMessageId('nonexistent');
        expect(true).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('removeByChatId_idempotent', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const removed: number = await repo.removeByChatId('nonexistent');
        expect(removed).assertEqual(0);
      } finally {
        await cleanupRepo(repo);
      }
    });

    // ===== 约束 =====

    it('insert_group_duplicate_messageId_throws', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        let caught: boolean = false;
        let errorType: number = -1;
        try {
          await repo.insertGroup(makeGroup('msg-1'));
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(caught).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.ConstraintFailed);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('insert_candidate_duplicate_id_throws', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const c1: MessageSwipeCandidate = makeCandidate('msg-1', 0, { id: 'same-id' });
        await repo.insertCandidate(c1);
        let caught: boolean = false;
        let errorType: number = -1;
        try {
          const c2: MessageSwipeCandidate = makeCandidate('msg-1', 1, { id: 'same-id' });
          await repo.insertCandidate(c2);
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(caught).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.ConstraintFailed);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('insert_candidate_duplicate_message_index_throws', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const c1: MessageSwipeCandidate = makeCandidate('msg-1', 0, { id: 'id-1' });
        await repo.insertCandidate(c1);
        let caught: boolean = false;
        let errorType: number = -1;
        try {
          const c2: MessageSwipeCandidate = makeCandidate('msg-1', 0, { id: 'id-2' });
          await repo.insertCandidate(c2);
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(caught).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.ConstraintFailed);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('different_message_same_candidate_index_allowed', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        await repo.insertGroup(makeGroup('msg-2'));
        const c1: MessageSwipeCandidate = makeCandidate('msg-1', 0, { content: 'msg1-c0' });
        const c2: MessageSwipeCandidate = makeCandidate('msg-2', 0, { content: 'msg2-c0' });
        await repo.insertCandidate(c1);
        await repo.insertCandidate(c2);
        const list1: MessageSwipeCandidate[] = await repo.listCandidates('msg-1');
        const list2: MessageSwipeCandidate[] = await repo.listCandidates('msg-2');
        expect(list1.length).assertEqual(1);
        expect(list2.length).assertEqual(1);
        expect(list1[0].content).assertEqual('msg1-c0');
        expect(list2[0].content).assertEqual('msg2-c0');
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('invalid_candidate_index_rejected', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        let caught: boolean = false;
        let errorType: number = -1;
        try {
          await repo.getCandidate('msg-1', -1);
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(caught).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('invalid_status_rejected', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, { content: 'test' });
        await repo.insertCandidate(c);
        // 直接修改数据库,设置非法状态
        const store: relationalStore.RdbStore = await getStore();
        const updateBucket: relationalStore.ValuesBucket = {};
        updateBucket[COLUMN_STATUS] = 'invalid_status';
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
        predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, 'msg-1');
        await store.update(updateBucket, predicates);
        await store.close();
        // 读取时应抛出 InvalidData
        let caught: boolean = false;
        let errorType: number = -1;
        try {
          await repo.getCandidate('msg-1', 0);
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(caught).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('status_isstreaming_contradiction_rejected', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        let caught: boolean = false;
        let errorType: number = -1;
        try {
          // 直接构造矛盾对象绕过 createSwipeCandidate 的校验
          const badCandidate: MessageSwipeCandidate = {
            id: 'bad-id',
            assistantMessageId: 'msg-1',
            candidateIndex: 0,
            content: 'test',
            status: ChatMessageStatus.Completed,
            isStreaming: true,
            createdAt: 1000
          };
          await repo.insertCandidate(badCandidate);
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            errorType = e.type;
          }
        }
        expect(caught).assertTrue();
        expect(errorType).assertEqual(DatabaseErrorType.InvalidData);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('candidate_cannot_belong_to_different_group', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1', 'chat-1'));
        await repo.insertGroup(makeGroup('msg-2', 'chat-1'));
        const c1: MessageSwipeCandidate = makeCandidate('msg-1', 0, { id: 'cand-1' });
        await repo.insertCandidate(c1);
        // 尝试用相同 ID 但不同 assistantMessageId 插入 - 应因 ID 重复失败
        let caught: boolean = false;
        try {
          const c2: MessageSwipeCandidate = makeCandidate('msg-2', 0, { id: 'cand-1' });
          await repo.insertCandidate(c2);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
        // 验证 msg-2 的候选不受影响
        const list2: MessageSwipeCandidate[] = await repo.listCandidates('msg-2');
        expect(list2.length).assertEqual(0);
        // 验证 msg-1 的候选仍在
        const list1: MessageSwipeCandidate[] = await repo.listCandidates('msg-1');
        expect(list1.length).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    // ===== 数据往返 =====

    it('chinese_content_roundtrip', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const content: string = '你好世界，这是一段中文内容。';
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, { content: content });
        await repo.insertCandidate(c);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.content).assertEqual(content);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('emoji_content_roundtrip', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const content: string = 'Hello 😀🎉❤️✨';
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, { content: content });
        await repo.insertCandidate(c);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.content).assertEqual(content);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('markdown_content_roundtrip', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const content: string = '# Header\n\n**bold** *italic* `code`\n\n- list item 1\n- list item 2\n\n```\nconsole.log("hello");\n```';
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, { content: content });
        await repo.insertCandidate(c);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.content).assertEqual(content);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('multiline_content_roundtrip', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const content: string = 'line1\nline2\nline3\n\nline4';
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, { content: content });
        await repo.insertCandidate(c);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.content).assertEqual(content);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('cancelled_with_partial_content', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const content: string = 'This is a partial response that was cancelled...';
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, {
          content: content,
          status: ChatMessageStatus.Cancelled,
          isStreaming: false
        });
        await repo.insertCandidate(c);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.content).assertEqual(content);
          expect(fetched.status).assertEqual(ChatMessageStatus.Cancelled);
          expect(fetched.isStreaming).assertEqual(false);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('failed_with_error_message', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const content: string = 'Partial content before error';
        const errorMsg: string = 'API timeout after 30 seconds';
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, {
          content: content,
          status: ChatMessageStatus.Failed,
          isStreaming: false,
          errorMessage: errorMsg
        });
        await repo.insertCandidate(c);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.content).assertEqual(content);
          expect(fetched.status).assertEqual(ChatMessageStatus.Failed);
          expect(fetched.errorMessage).assertEqual(errorMsg);
          expect(fetched.isStreaming).assertEqual(false);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('empty_streaming_content', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, {
          content: '',
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        });
        await repo.insertCandidate(c);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.content).assertEqual('');
          expect(fetched.status).assertEqual(ChatMessageStatus.Streaming);
          expect(fetched.isStreaming).assertEqual(true);
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('updated_at_undefined', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        await repo.insertGroup(makeGroup('msg-1'));
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, { content: 'test' });
        // 默认 createSwipeCandidate 设置 updatedAt = undefined
        expect(c.updatedAt === undefined).assertTrue();
        await repo.insertCandidate(c);
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.updatedAt === undefined).assertTrue();
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    // ===== 安全 =====

    it('resultset_closed', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        // 多次操作验证 ResultSet 正常关闭
        await repo.insertGroup(makeGroup('msg-1'));
        await repo.insertCandidate(makeCandidate('msg-1', 0, { content: 'a' }));
        await repo.insertCandidate(makeCandidate('msg-1', 1, { content: 'b' }));
        const g: MessageSwipeGroup | null = await repo.getGroup('msg-1');
        expect(g !== null).assertTrue();
        const list: MessageSwipeCandidate[] = await repo.listCandidates('msg-1');
        expect(list.length).assertEqual(2);
        const count: number = await repo.countCandidates('msg-1');
        expect(count).assertEqual(2);
        const maxIdx: number = await repo.getMaxCandidateIndex('msg-1');
        expect(maxIdx).assertEqual(1);
        // 再次查询,不应因 ResultSet 未关闭而失败
        const g2: MessageSwipeGroup | null = await repo.getGroup('msg-1');
        expect(g2 !== null).assertTrue();
        const list2: MessageSwipeCandidate[] = await repo.listCandidates('msg-1');
        expect(list2.length).assertEqual(2);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('resultset_closed_after_mapping_failure', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        // 插入正常数据
        await repo.insertGroup(makeGroup('msg-1'));
        await repo.insertCandidate(makeCandidate('msg-1', 0, { content: 'valid' }));
        // 直接修改使候选的状态变为非法
        const store: relationalStore.RdbStore = await getStore();
        const updateBucket: relationalStore.ValuesBucket = {};
        updateBucket[COLUMN_STATUS] = 'bogus_status';
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
        predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, 'msg-1');
        await store.update(updateBucket, predicates);
        await store.close();
        // 读取应失败
        let caught: boolean = false;
        try {
          await repo.getCandidate('msg-1', 0);
        } catch (e) {
          caught = true;
        }
        expect(caught).assertTrue();
        // 后续操作(如插入新数据)应仍可用
        await repo.insertGroup(makeGroup('msg-2'));
        await repo.insertCandidate(makeCandidate('msg-2', 0, { content: 'recovery' }));
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-2', 0);
        expect(fetched !== null).assertTrue();
        if (fetched !== null) {
          expect(fetched.content).assertEqual('recovery');
        }
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('does_not_affect_messages', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const vb: relationalStore.ValuesBucket = {};
        vb[COLUMN_ID] = 'msg-1';
        vb[COLUMN_CHAT_ID] = 'chat-1';
        vb[COLUMN_ROLE] = 'user';
        vb[COLUMN_CONTENT] = 'hello';
        vb[COLUMN_STATUS] = 'completed';
        vb[COLUMN_CREATED_AT] = 3000;
        vb[COLUMN_UPDATED_AT] = 3000;
        vb[COLUMN_SEQUENCE_NUMBER] = 1;
        vb[COLUMN_IS_STREAMING] = 0;
        vb[COLUMN_SOURCE] = null;
        await store.insert(TABLE_MESSAGES, vb);
        await store.close();
        // 执行 Swipe 操作
        await repo.insertGroup(makeGroup('swipe-msg-1'));
        await repo.insertCandidate(makeCandidate('swipe-msg-1', 0));
        // messages 表不应受影响
        const store2: relationalStore.RdbStore = await getStore();
        const count: number = await rowCount(store2, TABLE_MESSAGES);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('does_not_affect_chats', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const vb: relationalStore.ValuesBucket = {};
        vb[COLUMN_ID] = 'chat-1';
        vb[COLUMN_TITLE] = 'Chat';
        vb[COLUMN_CHARACTER_ID] = null;
        vb[COLUMN_CREATED_AT] = 2000;
        vb[COLUMN_UPDATED_AT] = 2000;
        vb[COLUMN_LAST_MESSAGE_AT] = 0;
        vb[COLUMN_IS_ARCHIVED] = 0;
        await store.insert(TABLE_CHATS, vb);
        await store.close();
        await repo.insertGroup(makeGroup('msg-1', 'chat-1'));
        await repo.insertCandidate(makeCandidate('msg-1', 0));
        const store2: relationalStore.RdbStore = await getStore();
        const count: number = await rowCount(store2, TABLE_CHATS);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('does_not_affect_characters', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const vb: relationalStore.ValuesBucket = {};
        vb[COLUMN_ID] = 'c-1';
        vb[COLUMN_NAME] = 'Char';
        vb[COLUMN_CREATED_AT] = 1000;
        vb[COLUMN_UPDATED_AT] = 1000;
        await store.insert(TABLE_CHARACTERS, vb);
        await store.close();
        await repo.insertGroup(makeGroup('msg-1'));
        await repo.insertCandidate(makeCandidate('msg-1', 0));
        const store2: relationalStore.RdbStore = await getStore();
        const count: number = await rowCount(store2, TABLE_CHARACTERS);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('does_not_affect_lorebooks', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const vb: relationalStore.ValuesBucket = {};
        vb[COLUMN_LOREBOOK_ID] = 'lb-1';
        vb[COLUMN_LOREBOOK_NAME] = 'TestLorebook';
        vb[COLUMN_LOREBOOK_ENABLED] = 1;
        vb[COLUMN_CREATED_AT] = 1000;
        vb[COLUMN_UPDATED_AT] = 1000;
        await store.insert(TABLE_LOREBOOKS, vb);
        await store.close();
        await repo.insertGroup(makeGroup('msg-1'));
        await repo.insertCandidate(makeCandidate('msg-1', 0));
        const store2: relationalStore.RdbStore = await getStore();
        const count: number = await rowCount(store2, TABLE_LOREBOOKS);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('does_not_affect_prompt_presets', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const store: relationalStore.RdbStore = await getStore();
        const vb: relationalStore.ValuesBucket = {};
        vb[COLUMN_PRESET_ID] = 'pp-1';
        vb[COLUMN_PRESET_NAME] = 'TestPreset';
        vb[COLUMN_PRESET_DESCRIPTION] = '';
        vb[COLUMN_PRESET_SYSTEM_PROMPT] = '';
        vb[COLUMN_PRESET_TEMPERATURE] = 0.7;
        vb[COLUMN_PRESET_TOP_P] = 1.0;
        vb[COLUMN_PRESET_MAX_OUTPUT_TOKENS] = 2048;
        vb[COLUMN_PRESET_CONTEXT_WINDOW] = 4096;
        vb[COLUMN_CREATED_AT] = 1000;
        vb[COLUMN_UPDATED_AT] = 1000;
        await store.insert(TABLE_PROMPT_PRESETS, vb);
        await store.close();
        await repo.insertGroup(makeGroup('msg-1'));
        await repo.insertCandidate(makeCandidate('msg-1', 0));
        const store2: relationalStore.RdbStore = await getStore();
        const count: number = await rowCount(store2, TABLE_PROMPT_PRESETS);
        try { await store2.close(); } catch (e) { /* ignore */ }
        expect(count).assertEqual(1);
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('error_does_not_contain_content', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const sensitiveContent: string = 'SensitiveUserContent123!@#';
        await repo.insertGroup(makeGroup('msg-1'));
        // 插入一个有效候选
        const c: MessageSwipeCandidate = makeCandidate('msg-1', 0, { content: sensitiveContent });
        await repo.insertCandidate(c);
        // 获取时一切正常
        const fetched: MessageSwipeCandidate | null = await repo.getCandidate('msg-1', 0);
        expect(fetched !== null).assertTrue();
        // 触发约束错误 - 检查错误消息不包含 content
        let caught: boolean = false;
        let msg: string = '';
        try {
          await repo.insertGroup(makeGroup('msg-1'));
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            msg = e.message + ' ' + e.causeMessage;
          } else if (e instanceof Error) {
            msg = e.message;
          }
        }
        expect(caught).assertTrue();
        // 不应包含敏感内容
        expect(msg.indexOf(sensitiveContent) < 0).assertTrue();
        // 不应包含 SQL 关键词
        expect(msg.indexOf('SQL') < 0).assertTrue();
        expect(msg.indexOf('INSERT') < 0).assertTrue();
        expect(msg.indexOf('SELECT') < 0).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });

    it('log_does_not_contain_content', 0, async () => {
      const repo: MessageSwipeRepository = await makeRepository();
      try {
        const secretContent: string = 'HiddenSecretData!@#secret';
        await repo.insertGroup(makeGroup('msg-1'));
        // 验证非法 index 错误不包含 secretContent
        let caught: boolean = false;
        let msg: string = '';
        try {
          await repo.getCandidate('msg-1', -1);
        } catch (e) {
          caught = true;
          if (e instanceof DatabaseError) {
            msg = e.message + ' ' + e.causeMessage;
          } else if (e instanceof Error) {
            msg = e.message;
          }
        }
        expect(caught).assertTrue();
        // 错误消息中不应包含 content
        expect(msg.indexOf(secretContent) < 0).assertTrue();
        // 验证映射错误也不泄露 content
        const store: relationalStore.RdbStore = await getStore();
        const updateBucket: relationalStore.ValuesBucket = {};
        updateBucket[COLUMN_STATUS] = 'bad_status';
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
        predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, 'msg-1');
        await store.update(updateBucket, predicates);
        await store.close();
        let caught2: boolean = false;
        let msg2: string = '';
        try {
          await repo.listCandidates('msg-1');
        } catch (e) {
          caught2 = true;
          if (e instanceof DatabaseError) {
            msg2 = e.message + ' ' + e.causeMessage;
          }
        }
        expect(caught2).assertTrue();
        expect(msg2.indexOf(secretContent) < 0).assertTrue();
        expect(msg2.indexOf('SQL') < 0).assertTrue();
      } finally {
        await cleanupRepo(repo);
      }
    });
  });
}