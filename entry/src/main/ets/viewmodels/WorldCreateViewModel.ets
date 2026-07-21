/**
 * WorldCreateViewModel 创建多人世界 ViewModel
 *
 * 职责:
 * - 加载本地角色列表供选择
 * - 维护多步创建表单(世界基础信息 + 用户身份 + 成员 + 初始关系)
 * - 提交时调用 WorldService.createWorld(事务写入 world + members + scene + 初始关系)
 * - 创建成功后返回 worldId 供页面跳转
 *
 * 不负责:
 * - 持久化 Chat(由调用方调用 createChatForWorld)
 * - 关系/记忆后续管理
 */

import { Character } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import {
  World,
  WorldReplyMode,
  WorldUserIdentity,
  EMPTY_USER_IDENTITY
} from '../models/World';
import {
  WorldService,
  CreateWorldMemberInput,
  CreateWorldResult,
  MIN_WORLD_MEMBERS
} from '../services/WorldService';
import {
  InitialRelationship
} from '../models/WorldRelationship';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldCreateViewModel';

/** 候选角色条目(角色 + 是否被选中 + 默认初始关系) */
export interface CandidateCharacter {
  readonly character: Character;
  selected: boolean;
  present: boolean;
  talkativeness: number;
  initialRelationship: InitialRelationship;
}

/** 表单状态 */
export interface WorldCreateFormState {
  name: string;
  background: string;
  initialScene: string;
  defaultReplyMode: WorldReplyMode;
  userIdentity: WorldUserIdentity;
}

/** 默认表单状态 */
export const DEFAULT_FORM_STATE: WorldCreateFormState = {
  name: '',
  background: '',
  initialScene: '',
  defaultReplyMode: 'auto_director',
  userIdentity: EMPTY_USER_IDENTITY
};

@Observed
export class WorldCreateViewModel {
  /** 本地全部角色 */
  characters: CandidateCharacter[] = [];
  /** 表单 */
  form: WorldCreateFormState = DEFAULT_FORM_STATE;
  /** 加载中 */
  isLoading: boolean = false;
  /** 提交中 */
  isSubmitting: boolean = false;
  /** 错误信息 */
  errorMessage: string = '';
  /** 创建结果(成功后设置) */
  createdWorldId: string = '';

  private readonly worldService: WorldService;
  private readonly characterService: CharacterService;
  private disposed: boolean = false;

  constructor(worldService: WorldService, characterService: CharacterService) {
    this.worldService = worldService;
    this.characterService = characterService;
  }

  /** 加载本地角色列表 */
  async loadCharacters(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const list: Character[] = await this.characterService.list();
      const arr: CandidateCharacter[] = [];
      for (let i = 0; i < list.length; i++) {
        const c: Character = list[i];
        const initRel: InitialRelationship = {
          relationshipLabel: '',
          addressTerm: '',
          affinity: 0,
          trust: 0,
          currentImpression: '',
          sharedExperiences: '',
          knownSecrets: ''
        };
        const candidate: CandidateCharacter = {
          character: c,
          selected: false,
          present: true,
          talkativeness: 0.5,
          initialRelationship: initRel
        };
        arr.push(candidate);
      }
      this.characters = arr;
    } catch (e) {
      this.errorMessage = '加载角色列表失败';
      Logger.error(LOG_TAG, 'loadCharacters failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /** 切换角色选中状态 */
  toggleSelected(characterId: string): void {
    const arr: CandidateCharacter[] = [];
    for (let i = 0; i < this.characters.length; i++) {
      const c: CandidateCharacter = this.characters[i];
      if (c.character.id === characterId) {
        const newSelected: boolean = !c.selected;
        const newPresent: boolean = newSelected ? true : c.present;
        const updated: CandidateCharacter = {
          character: c.character,
          selected: newSelected,
          present: newPresent,
          talkativeness: c.talkativeness,
          initialRelationship: c.initialRelationship
        };
        arr.push(updated);
      } else {
        arr.push(c);
      }
    }
    this.characters = arr;
  }

  /** 设置角色在场状态 */
  setPresent(characterId: string, present: boolean): void {
    const arr: CandidateCharacter[] = [];
    for (let i = 0; i < this.characters.length; i++) {
      const c: CandidateCharacter = this.characters[i];
      if (c.character.id === characterId) {
        const updated: CandidateCharacter = {
          character: c.character,
          selected: c.selected,
          present: present,
          talkativeness: c.talkativeness,
          initialRelationship: c.initialRelationship
        };
        arr.push(updated);
      } else {
        arr.push(c);
      }
    }
    this.characters = arr;
  }

  /** 设置角色活跃度 */
  setTalkativeness(characterId: string, value: number): void {
    const arr: CandidateCharacter[] = [];
    for (let i = 0; i < this.characters.length; i++) {
      const c: CandidateCharacter = this.characters[i];
      if (c.character.id === characterId) {
        const updated: CandidateCharacter = {
          character: c.character,
          selected: c.selected,
          present: c.present,
          talkativeness: value,
          initialRelationship: c.initialRelationship
        };
        arr.push(updated);
      } else {
        arr.push(c);
      }
    }
    this.characters = arr;
  }

  /** 更新角色初始关系字段 */
  updateInitialRelationship(characterId: string, updates: Partial<InitialRelationship>): void {
    const arr: CandidateCharacter[] = [];
    for (let i = 0; i < this.characters.length; i++) {
      const c: CandidateCharacter = this.characters[i];
      if (c.character.id === characterId) {
        const oldRel: InitialRelationship = c.initialRelationship;
        const newRel: InitialRelationship = {
          relationshipLabel: updates.relationshipLabel !== undefined ? updates.relationshipLabel : oldRel.relationshipLabel,
          addressTerm: updates.addressTerm !== undefined ? updates.addressTerm : oldRel.addressTerm,
          affinity: updates.affinity !== undefined ? updates.affinity : oldRel.affinity,
          trust: updates.trust !== undefined ? updates.trust : oldRel.trust,
          currentImpression: updates.currentImpression !== undefined ? updates.currentImpression : oldRel.currentImpression,
          sharedExperiences: updates.sharedExperiences !== undefined ? updates.sharedExperiences : oldRel.sharedExperiences,
          knownSecrets: updates.knownSecrets !== undefined ? updates.knownSecrets : oldRel.knownSecrets
        };
        const updated: CandidateCharacter = {
          character: c.character,
          selected: c.selected,
          present: c.present,
          talkativeness: c.talkativeness,
          initialRelationship: newRel
        };
        arr.push(updated);
      } else {
        arr.push(c);
      }
    }
    this.characters = arr;
  }

  /** 更新表单字段 */
  updateForm(updates: Partial<WorldCreateFormState>): void {
    const oldForm: WorldCreateFormState = this.form;
    this.form = {
      name: updates.name !== undefined ? updates.name : oldForm.name,
      background: updates.background !== undefined ? updates.background : oldForm.background,
      initialScene: updates.initialScene !== undefined ? updates.initialScene : oldForm.initialScene,
      defaultReplyMode: updates.defaultReplyMode !== undefined ? updates.defaultReplyMode : oldForm.defaultReplyMode,
      userIdentity: updates.userIdentity !== undefined ? updates.userIdentity : oldForm.userIdentity
    };
  }

  /** 已选中角色数量 */
  getSelectedCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.characters.length; i++) {
      if (this.characters[i].selected) {
        n++;
      }
    }
    return n;
  }

  /** 是否可提交 */
  canSubmit(): boolean {
    if (this.isSubmitting) {
      return false;
    }
    if (this.form.name.length === 0) {
      return false;
    }
    return this.getSelectedCount() >= MIN_WORLD_MEMBERS;
  }

  /**
   * 提交创建世界。
   * 成功后 createdWorldId 设置为返回的世界 ID。
   */
  async submit(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (!this.canSubmit()) {
      this.errorMessage = '请填写世界名称并至少选择 ' + MIN_WORLD_MEMBERS + ' 个角色';
      return false;
    }
    this.isSubmitting = true;
    this.errorMessage = '';
    try {
      const selected: CandidateCharacter[] = this.characters.filter(
        (c: CandidateCharacter) => c.selected
      );
      const members: CreateWorldMemberInput[] = selected.map(
        (c: CandidateCharacter, idx: number): CreateWorldMemberInput => ({
          characterId: c.character.id,
          present: c.present,
          talkativeness: c.talkativeness,
          displayOrder: idx,
          initialRelationship: c.initialRelationship
        })
      );
      const result: CreateWorldResult = await this.worldService.createWorld({
        name: this.form.name,
        background: this.form.background,
        initialScene: this.form.initialScene,
        userIdentity: this.form.userIdentity,
        defaultReplyMode: this.form.defaultReplyMode,
        members: members
      });
      this.createdWorldId = result.world.id;
      Logger.info(LOG_TAG, 'createWorld ok');
      return true;
    } catch (e) {
      this.errorMessage = '创建世界失败: ' + String(e);
      Logger.error(LOG_TAG, 'submit failed: ' + String(e));
      return false;
    } finally {
      this.isSubmitting = false;
    }
  }

  /** 重置表单(创建成功后调用) */
  reset(): void {
    this.form = DEFAULT_FORM_STATE;
    this.createdWorldId = '';
    this.errorMessage = '';
    if (this.characters.length > 0) {
      const arr: CandidateCharacter[] = [];
      for (let i = 0; i < this.characters.length; i++) {
        const c: CandidateCharacter = this.characters[i];
        const initRel: InitialRelationship = {
          relationshipLabel: '',
          addressTerm: '',
          affinity: 0,
          trust: 0,
          currentImpression: '',
          sharedExperiences: '',
          knownSecrets: ''
        };
        const reset: CandidateCharacter = {
          character: c.character,
          selected: false,
          present: true,
          talkativeness: 0.5,
          initialRelationship: initRel
        };
        arr.push(reset);
      }
      this.characters = arr;
    }
  }

  dispose(): void {
    this.disposed = true;
    this.characters = [];
  }
}
