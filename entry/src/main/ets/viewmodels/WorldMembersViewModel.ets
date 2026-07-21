/**
 * WorldMembersViewModel 多人世界成员管理 ViewModel
 *
 * 职责:
 * - 加载指定世界的成员列表
 * - 中途添加角色到世界
 * - 移出成员(不删除原角色卡、不破坏历史消息)
 * - 切换在场 / 离场状态
 * - 切换静音 / 恢复
 * - 调整活跃度
 * - 加载未加入世界的本地角色供添加
 *
 * 不负责:
 * - 聊天发送(走 WorldChatViewModel)
 * - 角色卡 CRUD(走 CharacterListViewModel)
 */

import { Character } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import {
  WorldService,
  WorldMemberView
} from '../services/WorldService';
import { InitialRelationship, createInitialRelationship } from '../models/WorldRelationship';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldMembersViewModel';

/** 添加角色对话框的预览项 */
export interface AddableCharacter {
  readonly character: Character;
  /** 临时初始关系(只在对话框中编辑) */
  initialRelationship: InitialRelationship;
  present: boolean;
  talkativeness: number;
}

@Observed
export class WorldMembersViewModel {
  /** 当前世界 ID */
  worldId: string = '';
  /** 当前世界名称 */
  worldName: string = '';
  /** 成员列表 */
  members: WorldMemberView[] = [];
  /** 加载中 */
  isLoading: boolean = false;
  /** 操作中 */
  isOperating: boolean = false;
  /** 错误信息 */
  errorMessage: string = '';
  /** 添加成员对话框 */
  showAddDialog: boolean = false;
  /** 可添加的角色(未加入世界的本地角色) */
  addableCharacters: AddableCharacter[] = [];

  private readonly worldService: WorldService;
  private readonly characterService: CharacterService;
  private disposed: boolean = false;

  constructor(worldService: WorldService, characterService: CharacterService) {
    this.worldService = worldService;
    this.characterService = characterService;
  }

  /** 初始化(加载世界信息 + 成员) */
  async initialize(worldId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.worldId = worldId;
    await this.reload();
  }

  /** 重新加载成员列表 */
  async reload(): Promise<void> {
    if (this.disposed || this.worldId.length === 0) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const world = await this.worldService.getWorld(this.worldId);
      if (world === null) {
        this.errorMessage = '世界不存在';
        return;
      }
      this.worldName = world.name;
      this.members = await this.worldService.listMembers(this.worldId);
    } catch (e) {
      this.errorMessage = '加载成员列表失败';
      Logger.error(LOG_TAG, 'reload failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /** 切换在场状态 */
  async setPresent(characterId: string, present: boolean): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.worldService.updateMemberState(this.worldId, characterId, { present: present });
      await this.reload();
    } catch (e) {
      this.errorMessage = '切换在场状态失败';
      Logger.error(LOG_TAG, 'setPresent failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /** 切换静音状态 */
  async setMuted(characterId: string, muted: boolean): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.worldService.updateMemberState(this.worldId, characterId, { muted: muted });
      await this.reload();
    } catch (e) {
      this.errorMessage = '切换静音状态失败';
      Logger.error(LOG_TAG, 'setMuted failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /** 切换启用状态 */
  async setEnabled(characterId: string, enabled: boolean): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.worldService.updateMemberState(this.worldId, characterId, { enabled: enabled });
      await this.reload();
    } catch (e) {
      this.errorMessage = '切换启用状态失败';
      Logger.error(LOG_TAG, 'setEnabled failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /** 调整活跃度 */
  async setTalkativeness(characterId: string, value: number): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.worldService.updateMemberState(this.worldId, characterId, { talkativeness: value });
      await this.reload();
    } catch (e) {
      this.errorMessage = '调整活跃度失败';
      Logger.error(LOG_TAG, 'setTalkativeness failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /** 打开添加成员对话框 */
  async openAddDialog(): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      const all: Character[] = await this.characterService.list();
      const existingIds: Set<string> = new Set<string>();
      for (let i = 0; i < this.members.length; i++) {
        existingIds.add(this.members[i].member.characterId);
      }
      const list: AddableCharacter[] = [];
      for (let i = 0; i < all.length; i++) {
        const c: Character = all[i];
        if (existingIds.has(c.id)) {
          continue;
        }
        const item: AddableCharacter = {
          character: c,
          initialRelationship: createInitialRelationship(),
          present: true,
          talkativeness: 0.5
        };
        list.push(item);
      }
      this.addableCharacters = list;
      this.showAddDialog = true;
    } catch (e) {
      this.errorMessage = '加载可添加角色失败';
      Logger.error(LOG_TAG, 'openAddDialog failed: ' + String(e));
    }
  }

  /** 关闭添加成员对话框 */
  closeAddDialog(): void {
    this.showAddDialog = false;
    this.addableCharacters = [];
  }

  /** 更新添加对话框中某个角色的初始关系 */
  updateAddableRelationship(characterId: string, updates: Partial<InitialRelationship>): void {
    const next: AddableCharacter[] = [];
    for (let i = 0; i < this.addableCharacters.length; i++) {
      const c: AddableCharacter = this.addableCharacters[i];
      if (c.character.id === characterId) {
        const newRel: InitialRelationship = createInitialRelationship({
          relationshipLabel: updates.relationshipLabel !== undefined ? updates.relationshipLabel : c.initialRelationship.relationshipLabel,
          addressTerm: updates.addressTerm !== undefined ? updates.addressTerm : c.initialRelationship.addressTerm,
          affinity: updates.affinity !== undefined ? updates.affinity : c.initialRelationship.affinity,
          trust: updates.trust !== undefined ? updates.trust : c.initialRelationship.trust,
          currentImpression: updates.currentImpression !== undefined ? updates.currentImpression : c.initialRelationship.currentImpression,
          sharedExperiences: updates.sharedExperiences !== undefined ? updates.sharedExperiences : c.initialRelationship.sharedExperiences,
          knownSecrets: updates.knownSecrets !== undefined ? updates.knownSecrets : c.initialRelationship.knownSecrets
        });
        const updated: AddableCharacter = {
          character: c.character,
          initialRelationship: newRel,
          present: c.present,
          talkativeness: c.talkativeness
        };
        next.push(updated);
      } else {
        next.push(c);
      }
    }
    this.addableCharacters = next;
  }

  /** 更新添加对话框中某个角色的在场状态 */
  updateAddablePresent(characterId: string, present: boolean): void {
    const next: AddableCharacter[] = [];
    for (let i = 0; i < this.addableCharacters.length; i++) {
      const c: AddableCharacter = this.addableCharacters[i];
      if (c.character.id === characterId) {
        const updated: AddableCharacter = {
          character: c.character,
          initialRelationship: c.initialRelationship,
          present: present,
          talkativeness: c.talkativeness
        };
        next.push(updated);
      } else {
        next.push(c);
      }
    }
    this.addableCharacters = next;
  }

  /** 更新添加对话框中某个角色的活跃度 */
  updateAddableTalkativeness(characterId: string, value: number): void {
    const next: AddableCharacter[] = [];
    for (let i = 0; i < this.addableCharacters.length; i++) {
      const c: AddableCharacter = this.addableCharacters[i];
      if (c.character.id === characterId) {
        const updated: AddableCharacter = {
          character: c.character,
          initialRelationship: c.initialRelationship,
          present: c.present,
          talkativeness: value
        };
        next.push(updated);
      } else {
        next.push(c);
      }
    }
    this.addableCharacters = next;
  }

  /** 确认添加单个角色到世界 */
  async addMember(characterId: string): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    const target: AddableCharacter | undefined = this.addableCharacters.find(
      (c: AddableCharacter) => c.character.id === characterId
    );
    if (target === undefined) {
      return false;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      let maxOrder: number = 0;
      if (this.members.length > 0) {
        for (let i = 0; i < this.members.length; i++) {
          const order: number = this.members[i].member.displayOrder;
          if (order > maxOrder) {
            maxOrder = order;
          }
        }
        maxOrder = maxOrder + 1;
      }
      await this.worldService.addMember(
        this.worldId,
        characterId,
        target.initialRelationship,
        target.present,
        target.talkativeness,
        maxOrder
      );
      // 从可添加列表移除
      this.addableCharacters = this.addableCharacters.filter(
        (c: AddableCharacter) => c.character.id !== characterId
      );
      await this.reload();
      return true;
    } catch (e) {
      this.errorMessage = '添加成员失败: ' + String(e);
      Logger.error(LOG_TAG, 'addMember failed: ' + String(e));
      return false;
    } finally {
      this.isOperating = false;
    }
  }

  /** 移出成员(不删除原角色卡) */
  async removeMember(characterId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.worldService.removeMember(this.worldId, characterId);
      await this.reload();
    } catch (e) {
      this.errorMessage = '移出成员失败';
      Logger.error(LOG_TAG, 'removeMember failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  dispose(): void {
    this.disposed = true;
    this.members = [];
    this.addableCharacters = [];
  }
}
