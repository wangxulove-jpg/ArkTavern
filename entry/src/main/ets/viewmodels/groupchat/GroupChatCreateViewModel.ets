/**
 * GroupChatCreateViewModel 创建多人聊天状态管理(G-DATA-1B)
 *
 * 职责:
 * - 从 CharacterService 读取真实角色列表
 * - 维护选择顺序(决定 speakerOrder)
 * - 调用 GroupConversationPersistenceService.createGroupConversation 创建真实群聊
 *
 * 不依赖:
 * - GroupChatPreviewStore / PREVIEW_CHARACTERS
 * - ArkUI 装饰器
 *
 * 创建规则:
 * - 最少 2 人,最多 8 人
 * - 角色 ID 不重复
 * - 默认按选择顺序排列
 * - 防止重复提交(isCreating)
 */

import { Character } from '../../models/Character';
import { Chat } from '../../models/Chat';
import { CharacterService } from '../../services/CharacterService';
import { GroupConversationPersistenceService } from '../../services/groupchat/GroupConversationPersistenceService';
import { AppServices } from '../../services/AppServices';
import { Logger } from '../../utils/Logger';
import { CharacterPickState } from './GroupChatUiModels';

const LOG_TAG: string = 'GroupChatCreateVM';

/** 最少成员数 */
export const MIN_MEMBER_COUNT: number = 2;
/** 最多成员数 */
export const MAX_MEMBER_COUNT: number = 8;

/** 角色列表项(含选择状态) */
export interface CharacterPickItem {
  readonly character: Character;
  readonly selectedOrder: number; // 0 表示未选中,>0 表示选择顺序(从 1 开始)
}

@Observed
export class GroupChatCreateViewModel {
  /** 全部角色列表 */
  characters: Character[] = [];
  /** 已选角色 ID 列表(按选择顺序) */
  selectedIds: string[] = [];
  /** 角色列表加载状态 */
  pickState: CharacterPickState = CharacterPickState.Loading;
  /** 是否正在创建(防止重复提交) */
  isCreating: boolean = false;
  /** 最近一次错误信息(创建失败时) */
  errorMessage: string = '';

  private readonly characterService: CharacterService;
  private readonly groupService: GroupConversationPersistenceService;
  private disposed: boolean = false;

  constructor() {
    this.characterService = AppServices.getCharacterService();
    this.groupService = AppServices.getGroupConversationPersistenceService();
  }

  /** 加载真实角色列表 */
  async loadCharacters(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.pickState = CharacterPickState.Loading;
    try {
      const list: Character[] = await this.characterService.list();
      this.characters = list;
      if (list.length === 0) {
        this.pickState = CharacterPickState.Empty;
      } else {
        this.pickState = CharacterPickState.Ready;
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'loadCharacters failed: ' + String(e));
      this.pickState = CharacterPickState.Error;
    }
  }

  /** 切换角色选择状态 */
  toggleSelect(characterId: string): void {
    const idx: number = this.selectedIds.indexOf(characterId);
    if (idx >= 0) {
      // 取消选择
      const next: string[] = this.selectedIds.filter((id: string): boolean => id !== characterId);
      this.selectedIds = next;
    } else {
      if (this.selectedIds.length >= MAX_MEMBER_COUNT) {
        return;
      }
      this.selectedIds = this.selectedIds.concat([characterId]);
    }
  }

  /** 上移已选角色 */
  moveUp(characterId: string): void {
    const idx: number = this.selectedIds.indexOf(characterId);
    if (idx <= 0) {
      return;
    }
    const next: string[] = this.selectedIds.slice();
    next[idx] = next[idx - 1];
    next[idx - 1] = characterId;
    this.selectedIds = next;
  }

  /** 下移已选角色 */
  moveDown(characterId: string): void {
    const idx: number = this.selectedIds.indexOf(characterId);
    if (idx < 0 || idx >= this.selectedIds.length - 1) {
      return;
    }
    const next: string[] = this.selectedIds.slice();
    next[idx] = next[idx + 1];
    next[idx + 1] = characterId;
    this.selectedIds = next;
  }

  /** 是否可进入步骤二 */
  canGoStepTwo(): boolean {
    return this.selectedIds.length >= MIN_MEMBER_COUNT;
  }

  /** 根据已选角色生成默认群聊名称 */
  composeDefaultTitle(): string {
    const names: string[] = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      const c: Character | undefined = this.findCharacter(this.selectedIds[i]);
      if (c !== undefined) {
        names.push(c.name);
      }
    }
    if (names.length === 0) {
      return '';
    }
    if (names.length === 2) {
      return names[0] + ' 与 ' + names[1];
    }
    return names[0] + ' 等 ' + String(names.length) + ' 人';
  }

  /**
   * 创建真实群聊。
   * @param title 群聊名称(trim 后非空,空时自动生成)
   * @returns 新建群聊 ID,失败抛错
   */
  async create(title: string): Promise<string> {
    if (this.disposed) {
      throw new Error('disposed');
    }
    if (this.isCreating) {
      throw new Error('creating');
    }
    if (this.selectedIds.length < MIN_MEMBER_COUNT) {
      throw new Error('至少选择 ' + String(MIN_MEMBER_COUNT) + ' 位角色');
    }
    let finalTitle: string = title.trim();
    if (finalTitle.length === 0) {
      finalTitle = this.composeDefaultTitle();
    }
    this.isCreating = true;
    this.errorMessage = '';
    try {
      const chat: Chat = await this.groupService.createGroupConversation(
        finalTitle, this.selectedIds
      );
      return chat.id;
    } catch (e) {
      Logger.error(LOG_TAG, 'create failed: ' + String(e));
      this.errorMessage = String(e);
      throw new Error(String(e));
    } finally {
      this.isCreating = false;
    }
  }

  /** 按 ID 查找角色 */
  findCharacter(id: string): Character | undefined {
    for (let i = 0; i < this.characters.length; i++) {
      if (this.characters[i].id === id) {
        return this.characters[i];
      }
    }
    return undefined;
  }

  /** 获取已选角色项(按选择顺序) */
  getSelectedItems(): Character[] {
    const result: Character[] = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      const c: Character | undefined = this.findCharacter(this.selectedIds[i]);
      if (c !== undefined) {
        result.push(c);
      }
    }
    return result;
  }

  dispose(): void {
    this.disposed = true;
  }
}
