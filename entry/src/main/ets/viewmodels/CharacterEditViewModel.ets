/**
 * CharacterEditViewModel 角色编辑页面状态管理
 *
 * 全屏角色编辑页(UI-3B-2)与 CharacterService 之间的唯一桥梁。
 * 表单状态通过 getFormState() 返回快照给页面,由页面 @State formState 持有。
 *
 * 设计:
 * - 与 CharacterListViewModel 解耦:本 ViewModel 只负责单角色的加载/保存/新建
 * - 不持有角色列表状态
 * - 不直接依赖 Repository / 数据库
 * - 路由参数解析放在 parseCharacterEditRouteParam,页面 onReady 调用
 *
 * 复用:
 * - CharacterService.list/getById/create/update
 * - 不修改 Character 数据模型
 * - 不修改数据库 Schema
 * - 不修改导入/导出逻辑
 */

import { Character } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterEditViewModel';

// ===== 表单状态快照 =====

/**
 * 角色编辑表单状态快照。
 * 页面通过 @State formState 持有,ViewModel 不持有 ArkUI 状态。
 */
export interface CharacterEditFormState {
  /** 角色名称(必填) */
  nameInput: string;
  /** 角色描述 */
  descriptionInput: string;
  /** 角色性格 */
  personalityInput: string;
  /** 场景 */
  scenarioInput: string;
  /** 开场白 */
  firstMessageInput: string;
  /** System Prompt */
  systemPromptInput: string;
  /** 头像 URI(本轮不实现修改,仅展示) */
  avatarUriInput: string;
}

/** 空表单(新建模式) */
export function emptyFormState(): CharacterEditFormState {
  return {
    nameInput: '',
    descriptionInput: '',
    personalityInput: '',
    scenarioInput: '',
    firstMessageInput: '',
    systemPromptInput: '',
    avatarUriInput: ''
  };
}

/** 复制表单快照(用于不可变更新) */
export function copyFormState(state: CharacterEditFormState): CharacterEditFormState {
  return {
    nameInput: state.nameInput,
    descriptionInput: state.descriptionInput,
    personalityInput: state.personalityInput,
    scenarioInput: state.scenarioInput,
    firstMessageInput: state.firstMessageInput,
    systemPromptInput: state.systemPromptInput,
    avatarUriInput: state.avatarUriInput
  };
}

/** 从 Character 实例构建表单快照(编辑模式回填) */
function formStateFromCharacter(character: Character): CharacterEditFormState {
  return {
    nameInput: character.name,
    descriptionInput: character.description,
    personalityInput: character.personality,
    scenarioInput: character.scenario,
    firstMessageInput: character.firstMessage,
    systemPromptInput: character.systemPrompt,
    avatarUriInput: character.avatarUri
  };
}

// ===== 路由参数解析 =====

/**
 * 路由参数结构:
 * - characterId 为空字符串或 undefined -> 新建模式
 * - characterId 非空 -> 编辑模式
 */
export interface ParsedCharacterEditRoute {
  readonly characterId: string | undefined;
  readonly error: string | undefined;
}

/**
 * 解析路由参数。
 * 兼容 NavPathStack.pushPath({ name, param }) 传入的对象。
 */
export function parseCharacterEditRouteParam(param: Object | undefined): ParsedCharacterEditRoute {
  if (param === undefined) {
    return { characterId: undefined, error: undefined };
  }
  const record = param as Record<string, Object | undefined>;
  const idVal = record['characterId'];
  if (idVal === undefined) {
    // 没有 characterId 字段视为新建
    return { characterId: undefined, error: undefined };
  }
  if (typeof idVal !== 'string') {
    return { characterId: undefined, error: '页面参数错误:characterId 类型无效' };
  }
  return { characterId: idVal, error: undefined };
}

// ===== ViewModel =====

export class CharacterEditViewModel {
  /** 是否为编辑模式(否则为新建模式) */
  isEditing: boolean = false;
  /** 当前编辑的角色 ID(新建模式为空) */
  editingCharacterId: string = '';

  private readonly characterService: CharacterService;
  private disposed: boolean = false;
  /** 加载到的原始角色(用于脏检测;新建模式为 null) */
  private originalCharacter: Character | null = null;

  constructor(characterService: CharacterService) {
    this.characterService = characterService;
  }

  /**
   * 初始化:根据 characterId 加载角色。
   * - characterId 为空或 undefined:新建模式,返回空表单
   * - characterId 非空:编辑模式,加载角色
   * - 角色不存在:抛出错误
   */
  async initialize(characterId: string | undefined): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (characterId === undefined || characterId.length === 0) {
      // 新建模式
      this.isEditing = false;
      this.editingCharacterId = '';
      this.originalCharacter = null;
      Logger.info(LOG_TAG, 'initialize: new character');
      return;
    }
    // 编辑模式
    const character: Character | null = await this.characterService.getById(characterId);
    if (character === null) {
      this.isEditing = false;
      this.editingCharacterId = '';
      this.originalCharacter = null;
      throw new Error('角色不存在或已被删除');
    }
    this.isEditing = true;
    this.editingCharacterId = character.id;
    this.originalCharacter = character;
    Logger.info(LOG_TAG, 'initialize: edit character');
  }

  /**
   * 获取当前表单快照。
   * 编辑模式:从原始角色回填
   * 新建模式:返回空表单
   */
  getFormState(): CharacterEditFormState {
    if (this.originalCharacter !== null) {
      return formStateFromCharacter(this.originalCharacter);
    }
    return emptyFormState();
  }

  /**
   * 检测表单是否有未保存修改。
   * 用于返回前提示。
   *
   * 注意:avatarUriInput 在 changeAvatar 时已即时落库,
   * originalCharacter.avatarUri 也同步刷新,因此 isDirty 不比较头像字段是正确的。
   * (改头像 -> changeAvatar 即时落库 -> originalCharacter 更新 -> isDirty=false,无需提示放弃)
   */
  isDirty(current: CharacterEditFormState): boolean {
    if (this.originalCharacter === null) {
      // 新建模式:任意字段非空即为脏
      return current.nameInput.trim().length > 0
        || current.descriptionInput.length > 0
        || current.personalityInput.length > 0
        || current.scenarioInput.length > 0
        || current.firstMessageInput.length > 0
        || current.systemPromptInput.length > 0;
    }
    // 编辑模式:与原始角色比较(不比较 avatarUriInput,因头像走即时落库)
    const orig: Character = this.originalCharacter;
    return current.nameInput !== orig.name
      || current.descriptionInput !== orig.description
      || current.personalityInput !== orig.personality
      || current.scenarioInput !== orig.scenario
      || current.firstMessageInput !== orig.firstMessage
      || current.systemPromptInput !== orig.systemPrompt;
  }

  /**
   * 修改当前角色头像。
   * 仅在编辑模式下可用,新建模式下调用会抛错。
   *
   * 流程:
   * - characterService.updateAvatar(id, sourceUri):
   *   1. 保存新头像到私有目录(文件名带时间戳)
   *   2. 更新数据库 avatarUri 字段
   *   3. 清理被替换的旧头像文件
   * - 失败时旧头像保留,不修改任何内容
   * - 成功后刷新 originalCharacter,供 getFormState() 返回新 avatarUri
   *
   * @param sourceUri 源 PNG 文件 URI(由 picker 返回)
   * @returns 新的头像 URI(已写入 Character.avatarUri)
   * @throws 新建模式 / 角色不存在 / 保存失败 / 数据库更新失败时抛出
   */
  async changeAvatar(sourceUri: string): Promise<string> {
    if (this.disposed) {
      throw new Error('ViewModel disposed');
    }
    if (!this.isEditing || this.editingCharacterId.length === 0) {
      throw new Error('新建模式下不能修改头像,请先保存角色');
    }
    const updated: Character = await this.characterService.updateAvatar(
      this.editingCharacterId, sourceUri
    );
    this.originalCharacter = updated;
    Logger.info(LOG_TAG, 'changeAvatar ok');
    return updated.avatarUri;
  }

  /**
   * 保存表单。
   * - 新建模式:调用 characterService.create
   * - 编辑模式:调用 characterService.update
   * - 名称校验:trim 后非空
   *
   * @returns 保存成功后返回新的 Character
   * @throws 校验失败或保存失败时抛出 Error
   */
  async save(current: CharacterEditFormState): Promise<Character> {
    if (this.disposed) {
      throw new Error('ViewModel disposed');
    }
    const trimmedName: string = current.nameInput.trim();
    if (trimmedName.length === 0) {
      throw new Error('角色名称不能为空');
    }

    if (this.isEditing) {
      // 编辑模式
      const updated: Character = await this.characterService.update(this.editingCharacterId, {
        name: current.nameInput,
        description: current.descriptionInput,
        personality: current.personalityInput,
        scenario: current.scenarioInput,
        firstMessage: current.firstMessageInput,
        systemPrompt: current.systemPromptInput
      });
      this.originalCharacter = updated;
      Logger.info(LOG_TAG, 'save: update ok');
      return updated;
    }

    // 新建模式
    const created: Character = await this.characterService.create(
      current.nameInput,
      current.descriptionInput,
      current.personalityInput,
      current.scenarioInput,
      current.firstMessageInput,
      current.systemPromptInput
    );
    this.isEditing = true;
    this.editingCharacterId = created.id;
    this.originalCharacter = created;
    Logger.info(LOG_TAG, 'save: create ok');
    return created;
  }

  dispose(): void {
    this.disposed = true;
    this.originalCharacter = null;
  }
}
