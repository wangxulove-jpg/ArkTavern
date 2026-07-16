/**
 * CharacterService 角色业务服务
 *
 * 封装 CharacterStore,提供角色 CRUD 和当前角色管理。
 * 页面只通过 CharacterService 访问角色数据,不直接操作 CharacterStore。
 *
 * 设计原则:
 * - 不依赖 ArkUI
 * - 不缓存 API Key
 * - 校验角色数据
 * - 不直接导出 CharacterStore 引用
 */

import { common } from '@kit.AbilityKit';
import { Character, createCharacter, updateCharacter, validateCharacter, CharacterUpdates } from '../models/Character';
import { CharacterStore } from '../storage/CharacterStore';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterService';

export class CharacterService {
  private readonly store: CharacterStore;
  private initialized: boolean = false;

  constructor(store: CharacterStore) {
    this.store = store;
  }

  async initialize(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    Logger.info(LOG_TAG, 'initialize');
    await this.store.initialize(context);
    this.initialized = true;
    Logger.info(LOG_TAG, 'initialize ok');
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('CharacterService not initialized');
    }
  }

  async list(): Promise<Character[]> {
    this.requireInit();
    return await this.store.list();
  }

  async getById(id: string): Promise<Character | null> {
    this.requireInit();
    return await this.store.getById(id);
  }

  async create(
    name: string,
    description: string = '',
    personality: string = '',
    scenario: string = '',
    firstMessage: string = '',
    systemPrompt: string = ''
  ): Promise<Character> {
    this.requireInit();
    const character: Character = createCharacter(
      'char-' + generateUuid(), name, description, personality,
      scenario, firstMessage, systemPrompt
    );
    const error: string | null = validateCharacter(character);
    if (error !== null) {
      throw new Error(error);
    }
    await this.store.save(character);
    Logger.info(LOG_TAG, 'create ok id=' + character.id);
    return character;
  }

  async update(
    id: string,
    updates: CharacterUpdates
  ): Promise<Character> {
    this.requireInit();
    const existing: Character | null = await this.store.getById(id);
    if (existing === null) {
      throw new Error('CharacterService update: not found: ' + id);
    }
    const updated: Character = updateCharacter(existing, updates);
    const error: string | null = validateCharacter(updated);
    if (error !== null) {
      throw new Error(error);
    }
    await this.store.update(updated);
    Logger.info(LOG_TAG, 'update ok id=' + id);
    return updated;
  }

  async remove(id: string): Promise<void> {
    this.requireInit();
    await this.store.remove(id);
    Logger.info(LOG_TAG, 'remove ok id=' + id);
  }

  async setCurrentCharacterId(id: string | null): Promise<void> {
    this.requireInit();
    await this.store.setCurrentCharacterId(id);
    Logger.info(LOG_TAG, 'setCurrentCharacterId ok');
  }

  async getCurrentCharacterId(): Promise<string | null> {
    this.requireInit();
    return await this.store.getCurrentCharacterId();
  }

  async getCurrentCharacter(): Promise<Character | null> {
    this.requireInit();
    return await this.store.getCurrentCharacter();
  }
}