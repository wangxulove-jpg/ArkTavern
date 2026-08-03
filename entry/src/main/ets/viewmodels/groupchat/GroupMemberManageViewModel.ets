/**
 * GroupMemberManageViewModel 群聊成员管理状态管理(G-DATA-1B)
 *
 * 职责:
 * - 读取真实群聊成员(有序)
 * - 读取可添加的真实角色(未加入当前群聊)
 * - 调用 GroupConversationPersistenceService 进行成员操作:
 *   上移 / 下移 / 启用 / 停用 / 移除 / 添加
 * - 处理 Service 返回的规则错误(至少 2 人 / 至少 2 个启用)
 *
 * 不依赖:
 * - GroupChatPreviewStore / PREVIEW_CHARACTERS
 * - ArkUI 装饰器
 *
 * 规则:
 * - 防止重复提交(每个操作期间 isSaving=true)
 * - 操作失败时恢复 UI(不修改本地状态,重新加载)
 * - 操作成功后重新加载正式成员
 */

import { Chat } from '../../models/Chat';
import { ChatParticipant } from '../../models/ChatParticipant';
import { Character } from '../../models/Character';
import { GroupConversationPersistenceService } from '../../services/groupchat/GroupConversationPersistenceService';
import { CharacterService } from '../../services/CharacterService';
import { AppServices } from '../../services/AppServices';
import { Logger } from '../../utils/Logger';
import {
  GroupMemberUiModel,
  AddableCharacterUiModel,
  GroupChatDetailState,
  CharacterPickState,
  DELETED_CHARACTER_NAME
} from './GroupChatUiModels';

const LOG_TAG: string = 'GroupMemberManageVM';

/** 最少成员数 */
export const MIN_MEMBER_COUNT: number = 2;
/** 最多成员数 */
export const MAX_MEMBER_COUNT: number = 8;

@Observed
export class GroupMemberManageViewModel {
  /** 当前群聊 ID */
  chatId: string = '';
  /** 群聊标题(用于返回栏显示) */
  chatTitle: string = '';
  /** 有序成员列表 */
  members: GroupMemberUiModel[] = [];
  /** 可添加角色列表 */
  addableCharacters: AddableCharacterUiModel[] = [];
  /** 详情页状态 */
  state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 添加弹窗角色列表状态 */
  addableState: CharacterPickState = CharacterPickState.Loading;
  /** 是否正在执行成员操作(防止并发) */
  isSaving: boolean = false;

  private readonly groupService: GroupConversationPersistenceService;
  private readonly characterService: CharacterService;
  private disposed: boolean = false;

  constructor() {
    this.groupService = AppServices.getGroupConversationPersistenceService();
    this.characterService = AppServices.getCharacterService();
  }

  /** 加载群聊成员 */
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
        this.members = [];
        this.state = GroupChatDetailState.NotFound;
        return;
      }
      this.chatTitle = target.title;
      this.members = await this.loadMembers(chatId);
      this.state = GroupChatDetailState.Ready;
    } catch (e) {
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
      this.state = GroupChatDetailState.Error;
    }
  }

  /** 加载可添加角色(未加入当前群聊的真实角色) */
  async loadAddableCharacters(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.addableState = CharacterPickState.Loading;
    try {
      const allCharacters: Character[] = await this.characterService.list();
      const existIds: Set<string> = new Set<string>();
      for (let i = 0; i < this.members.length; i++) {
        existIds.add(this.members[i].characterId);
      }
      const result: AddableCharacterUiModel[] = [];
      for (let i = 0; i < allCharacters.length; i++) {
        if (!existIds.has(allCharacters[i].id)) {
          result.push({
            characterId: allCharacters[i].id,
            name: allCharacters[i].name,
            avatarUri: allCharacters[i].avatarUri,
            description: allCharacters[i].description
          });
        }
      }
      this.addableCharacters = result;
      this.addableState = result.length === 0
        ? CharacterPickState.Empty
        : CharacterPickState.Ready;
    } catch (e) {
      Logger.error(LOG_TAG, 'loadAddableCharacters failed: ' + String(e));
      this.addableState = CharacterPickState.Error;
    }
  }

  /** 上移成员(与上一位交换顺序) */
  async moveUp(characterId: string): Promise<void> {
    if (this.isSaving) {
      return;
    }
    const orderedIds: string[] = this.currentOrderedIds();
    const idx: number = orderedIds.indexOf(characterId);
    if (idx <= 0) {
      return;
    }
    orderedIds[idx] = orderedIds[idx - 1];
    orderedIds[idx - 1] = characterId;
    await this.replaceOrder(orderedIds);
  }

  /** 下移成员(与下一位交换顺序) */
  async moveDown(characterId: string): Promise<void> {
    if (this.isSaving) {
      return;
    }
    const orderedIds: string[] = this.currentOrderedIds();
    const idx: number = orderedIds.indexOf(characterId);
    if (idx < 0 || idx >= orderedIds.length - 1) {
      return;
    }
    orderedIds[idx] = orderedIds[idx + 1];
    orderedIds[idx + 1] = characterId;
    await this.replaceOrder(orderedIds);
  }

  /** 切换启用/停用 */
  async setEnabled(characterId: string, enabled: boolean): Promise<void> {
    if (this.isSaving) {
      return;
    }
    this.isSaving = true;
    try {
      await this.groupService.setParticipantEnabled(this.chatId, characterId, enabled);
      await this.load(this.chatId);
    } catch (e) {
      Logger.error(LOG_TAG, 'setEnabled failed: ' + String(e));
      throw new Error(String(e));
    } finally {
      this.isSaving = false;
    }
  }

  /** 移除成员 */
  async remove(characterId: string): Promise<void> {
    if (this.isSaving) {
      return;
    }
    this.isSaving = true;
    try {
      await this.groupService.removeParticipant(this.chatId, characterId);
      await this.load(this.chatId);
    } catch (e) {
      Logger.error(LOG_TAG, 'remove failed: ' + String(e));
      throw new Error(String(e));
    } finally {
      this.isSaving = false;
    }
  }

  /** 添加成员到末尾 */
  async add(characterId: string): Promise<void> {
    if (this.isSaving) {
      return;
    }
    this.isSaving = true;
    try {
      await this.groupService.addParticipant(this.chatId, characterId);
      await this.load(this.chatId);
    } catch (e) {
      Logger.error(LOG_TAG, 'add failed: ' + String(e));
      throw new Error(String(e));
    } finally {
      this.isSaving = false;
    }
  }

  /** 当前成员的有序 ID 列表 */
  currentOrderedIds(): string[] {
    const result: string[] = [];
    for (let i = 0; i < this.members.length; i++) {
      result.push(this.members[i].characterId);
    }
    return result;
  }

  /** 替换顺序(内部) */
  private async replaceOrder(orderedIds: string[]): Promise<void> {
    this.isSaving = true;
    try {
      await this.groupService.replaceParticipantOrder(this.chatId, orderedIds);
      await this.load(this.chatId);
    } catch (e) {
      Logger.error(LOG_TAG, 'replaceOrder failed: ' + String(e));
      throw new Error(String(e));
    } finally {
      this.isSaving = false;
    }
  }

  /** 加载有序成员并映射为 UI 模型 */
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
