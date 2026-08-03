/**
 * GroupChatViewModel 多人聊天主页面状态管理(G-DATA-1B)
 *
 * 职责:
 * - 从 GroupConversationPersistenceService 读取真实群聊详情
 * - 加载有序成员并映射为 UI DTO
 * - 处理缺失角色
 * - 提供重命名能力(更多菜单内联)
 *
 * 不依赖:
 * - GroupChatPreviewStore
 * - ChatService / ModelService / Provider / SSE
 *
 * 本阶段不实现:
 * - 多人 AI 生成
 * - 真实消息发送
 * - 流式输出
 */

import { Chat } from '../../models/Chat';
import { ChatParticipant } from '../../models/ChatParticipant';
import { Character } from '../../models/Character';
import { GroupConversationPersistenceService } from '../../services/groupchat/GroupConversationPersistenceService';
import { CharacterService } from '../../services/CharacterService';
import { AppServices } from '../../services/AppServices';
import { Logger } from '../../utils/Logger';
import {
  GroupConversationDetailUiModel,
  GroupMemberUiModel,
  GroupChatDetailState,
  DELETED_CHARACTER_NAME
} from './GroupChatUiModels';

const LOG_TAG: string = 'GroupChatVM';

@Observed
export class GroupChatViewModel {
  /** 当前群聊 ID */
  chatId: string = '';
  /** 群聊详情(Ready 状态下非 null) */
  detail: GroupConversationDetailUiModel | null = null;
  /** 页面状态 */
  state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 是否正在重命名 */
  isRenaming: boolean = false;

  private readonly groupService: GroupConversationPersistenceService;
  private readonly characterService: CharacterService;
  private disposed: boolean = false;

  constructor() {
    this.groupService = AppServices.getGroupConversationPersistenceService();
    this.characterService = AppServices.getCharacterService();
  }

  /**
   * 加载群聊详情。
   * @param chatId 群聊 ID
   */
  async load(chatId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.chatId = chatId;
    this.state = GroupChatDetailState.Loading;
    try {
      const chats: Chat[] = await this.groupService.listGroupConversations();
      let target: Chat | null = null;
      for (let i = 0; i < chats.length; i++) {
        if (chats[i].id === chatId) {
          target = chats[i];
          break;
        }
      }
      if (target === null) {
        this.detail = null;
        this.state = GroupChatDetailState.NotFound;
        return;
      }
      const members: GroupMemberUiModel[] = await this.loadMembers(chatId);
      this.detail = {
        chatId: chatId,
        title: target.title,
        members: members
      };
      this.state = GroupChatDetailState.Ready;
    } catch (e) {
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
      this.state = GroupChatDetailState.Error;
    }
  }

  /**
   * 重命名群聊。
   * @param newTitle 新名称(trim 后非空)
   */
  async rename(newTitle: string): Promise<void> {
    if (this.disposed || this.isRenaming) {
      return;
    }
    const trimmed: string = newTitle.trim();
    if (trimmed.length === 0) {
      throw new Error('名称不能为空');
    }
    this.isRenaming = true;
    try {
      await this.groupService.renameGroupConversation(this.chatId, trimmed);
      // 重命名后重新加载详情
      await this.load(this.chatId);
    } finally {
      this.isRenaming = false;
    }
  }

  /** 加载有序成员并映射为 UI 模型(缺失角色不抛错) */
  private async loadMembers(chatId: string): Promise<GroupMemberUiModel[]> {
    const participants: ChatParticipant[] = await this.groupService.getParticipants(chatId);
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
    const result: GroupMemberUiModel[] = [];
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
