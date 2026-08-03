/**
 * GroupChatHomeViewModel 多人聊天首页列表状态管理(G-DATA-1B)
 *
 * 职责:
 * - 从 GroupConversationPersistenceService 读取真实群聊列表
 * - 为每个群聊加载有序成员并映射为 UI DTO
 * - 处理缺失角色(characterExists=false)
 *
 * 不依赖:
 * - GroupChatPreviewStore(预览)
 * - ArkUI 装饰器
 * - Repository / RdbStore
 *
 * 状态:
 * - items: GroupConversationListItemUiModel[](每次 reload 生成新数组)
 * - state: GroupChatListState
 */

import { Chat } from '../../models/Chat';
import { ChatParticipant } from '../../models/ChatParticipant';
import { Character } from '../../models/Character';
import { GroupConversationPersistenceService } from '../../services/groupchat/GroupConversationPersistenceService';
import { CharacterService } from '../../services/CharacterService';
import { AppServices } from '../../services/AppServices';
import { Logger } from '../../utils/Logger';
import {
  GroupConversationListItemUiModel,
  GroupMemberUiModel,
  GroupChatListState,
  DELETED_CHARACTER_NAME,
  NO_MESSAGE_PREVIEW
} from './GroupChatUiModels';

const LOG_TAG: string = 'GroupChatHomeVM';

@Observed
export class GroupChatHomeViewModel {
  items: GroupConversationListItemUiModel[] = [];
  state: GroupChatListState = GroupChatListState.Loading;

  private readonly groupService: GroupConversationPersistenceService;
  private readonly characterService: CharacterService;
  private disposed: boolean = false;

  constructor() {
    this.groupService = AppServices.getGroupConversationPersistenceService();
    this.characterService = AppServices.getCharacterService();
  }

  /**
   * 重新加载群聊列表。
   * - 读取全部多人聊天
   * - 为每个群聊加载有序成员
   * - 批量查询成员对应角色(缺失标记 characterExists=false)
   */
  async load(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.state = GroupChatListState.Loading;
    try {
      const chats: Chat[] = await this.groupService.listGroupConversations();
      if (chats.length === 0) {
        this.items = [];
        this.state = GroupChatListState.Empty;
        return;
      }

      const items: GroupConversationListItemUiModel[] = [];
      for (let i = 0; i < chats.length; i++) {
        if (this.disposed) {
          return;
        }
        const chat: Chat = chats[i];
        const members: GroupMemberUiModel[] = await this.loadMembers(chat.id);
        items.push({
          chatId: chat.id,
          title: chat.title,
          members: members,
          memberCount: members.length,
          lastMessagePreview: NO_MESSAGE_PREVIEW,
          updatedAt: chat.updatedAt
        });
      }
      this.items = items;
      this.state = GroupChatListState.Ready;
    } catch (e) {
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
      this.state = GroupChatListState.Error;
    }
  }

  /**
   * 加载指定群聊的有序成员并映射为 UI 模型。
   * 缺失角色显示"角色已删除",不抛错。
   */
  private async loadMembers(chatId: string): Promise<GroupMemberUiModel[]> {
    const participants: ChatParticipant[] = await this.groupService.getParticipants(chatId);
    const result: GroupMemberUiModel[] = [];
    // 收集角色 ID 批量查询
    const charMap: Map<string, Character | null> = new Map();
    for (let i = 0; i < participants.length; i++) {
      const charId: string = participants[i].characterId;
      if (!charMap.has(charId)) {
        try {
          const c: Character | null = await this.characterService.getById(charId);
          charMap.set(charId, c);
        } catch (e) {
          charMap.set(charId, null);
        }
      }
    }
    for (let i = 0; i < participants.length; i++) {
      const p: ChatParticipant = participants[i];
      const c: Character | null = charMap.get(p.characterId) ?? null;
      result.push({
        characterId: p.characterId,
        name: c !== null ? c.name : DELETED_CHARACTER_NAME,
        avatarUri: c !== null ? c.avatarUri : '',
        description: c !== null ? c.description : '',
        speakerOrder: p.speakerOrder,
        isEnabled: p.isEnabled,
        characterExists: c !== null
      });
    }
    return result;
  }

  dispose(): void {
    this.disposed = true;
  }
}
