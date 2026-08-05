/**
 * 多人 Runtime 设备测试(ohosTest,仅编译 + 用户手动运行,不自动启动设备)
 *
 * 覆盖本地 Fake 无法验证的真实 RDB 场景:
 * - DEL-03: ChatPersistenceOperations 删除事务在真实 RDB 上的回滚
 * - DEL-22: 群聊删除后 chats / messages / chat_participants 级联清理
 *
 * 运行方式:用户连接设备后手动运行 ohosTest。
 */

import { describe, beforeAll, afterAll, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common, UIAbility } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../../main/ets/database/DbHelper';
import { ChatRepository } from '../../../main/ets/repositories/ChatRepository';
import { MessageRepository } from '../../../main/ets/repositories/MessageRepository';
import { ChatParticipantRepository } from '../../../main/ets/repositories/ChatParticipantRepository';
import { MessageSwipeRepository } from '../../../main/ets/repositories/MessageSwipeRepository';
import { ChatPersistenceOperations } from '../../../main/ets/repositories/ChatPersistenceOperations';
import { GroupCharacterMemoryRepository } from '../../../main/ets/repositories/groupchat/GroupCharacterMemoryRepository';
import { GroupCharacterRelationshipMemoryRepository } from '../../../main/ets/repositories/groupchat/GroupCharacterRelationshipMemoryRepository';
import { Chat, createChat } from '../../../main/ets/models/Chat';
import { ChatParticipant, createChatParticipant } from '../../../main/ets/models/ChatParticipant';
import { ChatMessage, ChatMessageStatus, createChatMessage } from '../../../main/ets/models/ChatMessage';
import { ChatRole } from '../../../main/ets/models/ChatRole';
import { ConversationMode } from '../../../main/ets/models/ConversationMode';
import {
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_CHAT_PARTICIPANTS
} from '../../../main/ets/database/DatabaseConstants';

const DEVICE_TEST_DB: string = 'group_runtime_device_test.db';
let idCounter: number = 0;

function uniqueId(prefix: string): string {
  idCounter++;
  return prefix + '-' + idCounter.toString();
}

async function getContext(): Promise<common.Context> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  const ability: UIAbility = await delegator.getCurrentTopAbility();
  return ability.context as common.Context;
}

async function dropTestDb(ctx: common.Context): Promise<void> {
  try {
    const config: relationalStore.StoreConfig = {
      name: DEVICE_TEST_DB,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHAT_PARTICIPANTS);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_MESSAGES);
    await store.executeSql('DROP TABLE IF EXISTS ' + TABLE_CHATS);
    await store.close();
  } catch (e) {
    // best-effort cleanup
  }
}

let helper: DbHelper | null = null;
let chatRepo: ChatRepository | null = null;
let msgRepo: MessageRepository | null = null;
let partRepo: ChatParticipantRepository | null = null;

async function setup(): Promise<void> {
  const ctx: common.Context = await getContext();
  await dropTestDb(ctx);
  const h: DbHelper = new DbHelper(DEVICE_TEST_DB, []);
  await h.initialize(ctx);
  helper = h;
  chatRepo = new ChatRepository(h);
  msgRepo = new MessageRepository(h);
  partRepo = new ChatParticipantRepository(h);
}

async function teardown(): Promise<void> {
  if (helper !== null) {
    try {
      await helper.close();
    } catch (e) {
      // ignore
    }
    helper = null;
  }
  chatRepo = null;
  msgRepo = null;
  partRepo = null;
  const ctx: common.Context = await getContext();
  await dropTestDb(ctx);
}

async function seedGroupChat(chatId: string, characterIds: string[]): Promise<void> {
  if (helper === null || chatRepo === null || msgRepo === null || partRepo === null) {
    throw new Error('device test not initialized');
  }
  const h: DbHelper = helper;
  const cr: ChatRepository = chatRepo;
  const mr: MessageRepository = msgRepo;
  const pr: ChatParticipantRepository = partRepo;
  const chat: Chat = createChat({
    id: chatId,
    title: 'device-group',
    conversationMode: ConversationMode.Group
  });
  const now: number = Date.now();
  const participants: ChatParticipant[] = [];
  for (let i = 0; i < characterIds.length; i++) {
    participants.push(createChatParticipant({
      chatId: chatId,
      characterId: characterIds[i],
      speakerOrder: i,
      createdAt: now,
      updatedAt: now
    }));
  }
  const userMsg: ChatMessage = {
    id: 'dm-user-1',
    role: ChatRole.User,
    content: 'hello',
    createdAt: now,
    updatedAt: now,
    isStreaming: false,
    status: ChatMessageStatus.Completed,
    senderType: 'user',
    generationBatchId: 'round-device',
    visibility: 'public'
  };
  await h.runInTransaction(async (store: relationalStore.RdbStore): Promise<void> => {
    await cr.insertWithStore(store, chat);
    await pr.insertManyWithStore(store, participants);
    await mr.insertWithStore(store, userMsg, chatId, 1);
  }, 'unknown');
}

/** 抛错注入:模拟删除链中 group_character_memories 步骤失败。 */
class ThrowingGroupMemoryRepo {
  deleteByGroupWithStore(_store: Object, _chatId: string): Promise<void> {
    return Promise.reject(new Error('mock group memory delete failed'));
  }
}

export default function groupRuntimeDeviceTest() {
  describe('GroupRuntimeDeviceTest', () => {
    beforeAll(async () => {
      await setup();
    });

    afterAll(async () => {
      await teardown();
    });

    it('DEL_03_real_transaction_rollback', 0, async () => {
      if (helper === null || chatRepo === null || msgRepo === null || partRepo === null) {
        return;
      }
      const chatId: string = uniqueId('chat-rb');
      await seedGroupChat(chatId, ['char-a', 'char-b']);

      const swipeRepo: MessageSwipeRepository = new MessageSwipeRepository(helper);
      const groupMemRepo: GroupCharacterMemoryRepository = new GroupCharacterMemoryRepository(helper);
      const groupRelRepo: GroupCharacterRelationshipMemoryRepository =
        new GroupCharacterRelationshipMemoryRepository(helper);
      const throwing: ThrowingGroupMemoryRepo = new ThrowingGroupMemoryRepo();

      const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
        helper,
        chatRepo,
        msgRepo,
        swipeRepo,
        null,
        null,
        partRepo,
        throwing as Object as GroupCharacterMemoryRepository,
        groupRelRepo
      );

      let threw: boolean = false;
      try {
        await ops.removeChatWithMessages(chatId);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();

      // 真实事务回滚:chat / messages / participants 全部保留
      const chatAfter: Chat | null = await chatRepo.getById(chatId);
      expect(chatAfter === null).assertFalse();
      const msgsAfter: ChatMessage[] = await msgRepo.listByChat(chatId);
      expect(msgsAfter.length).assertEqual(1);
      const partsAfter: ChatParticipant[] = await partRepo.listByChatId(chatId);
      expect(partsAfter.length).assertEqual(2);
      void groupMemRepo;
    });

    it('DEL_22_group_delete_cascades_real_rdb', 0, async () => {
      if (helper === null || chatRepo === null || msgRepo === null || partRepo === null) {
        return;
      }
      const chatId: string = uniqueId('chat-del');
      await seedGroupChat(chatId, ['char-a', 'char-b']);

      const swipeRepo: MessageSwipeRepository = new MessageSwipeRepository(helper);
      const groupMemRepo: GroupCharacterMemoryRepository = new GroupCharacterMemoryRepository(helper);
      const groupRelRepo: GroupCharacterRelationshipMemoryRepository =
        new GroupCharacterRelationshipMemoryRepository(helper);

      const ops: ChatPersistenceOperations = new ChatPersistenceOperations(
        helper,
        chatRepo,
        msgRepo,
        swipeRepo,
        null,
        null,
        partRepo,
        groupMemRepo,
        groupRelRepo
      );

      await ops.removeChatWithMessages(chatId);

      const chatAfter: Chat | null = await chatRepo.getById(chatId);
      expect(chatAfter).assertEqual(null);
      const msgsAfter: ChatMessage[] = await msgRepo.listByChat(chatId);
      expect(msgsAfter.length).assertEqual(0);
      const partsAfter: ChatParticipant[] = await partRepo.listByChatId(chatId);
      expect(partsAfter.length).assertEqual(0);
    });
  });
}
