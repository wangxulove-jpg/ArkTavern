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
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Character, createCharacter, updateCharacter, validateCharacter, CharacterUpdates } from '../models/Character';
import { CharacterStore } from '../storage/CharacterStore';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';
import { parseCharacterJson, ParseResult, ParsedCharacterCard } from '../parser/CharacterCardJsonParser';
import { writeCharacterToJson } from '../parser/CharacterCardJsonWriter';

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

  // ===== 导入导出 =====

  /**
   * 解析角色卡 JSON(不保存)。
   * 用于导入前预览。

   * @param jsonString 原始 JSON 字符串
   * @returns ParseResult 包含解析结果
   */
  parseCharacterJson(jsonString: string): ParseResult {
    return parseCharacterJson(jsonString);
  }

  /**
   * 从解析后的角色卡创建并保存 Character。
   * id 冲突时生成新 UUID,不覆盖现有角色。
   *
   * @param parsed 解析后的角色卡
   * @returns 新创建的 Character
   */
  async importFromParsed(parsed: ParsedCharacterCard): Promise<Character> {
    this.requireInit();
    const character: Character = createCharacter(
      'char-' + generateUuid(),
      parsed.name,
      parsed.description,
      parsed.personality,
      parsed.scenario,
      parsed.firstMessage,
      parsed.systemPrompt,
      parsed.avatarUri
    );
    const error: string | null = validateCharacter(character);
    if (error !== null) {
      throw new Error(error);
    }
    await this.store.save(character);
    Logger.info(LOG_TAG, 'importFromParsed ok id=' + character.id + ' source=' + parsed.sourceFormat);
    return character;
  }

  /**
   * 从 JSON 字符串解析并导入角色。
   * 组合 parseCharacterJson + importFromParsed。
   *
   * @param jsonString 原始 JSON 字符串
   * @returns 新创建的 Character
   * @throws Error 解析失败或保存失败
   */
  async importFromJson(jsonString: string): Promise<Character> {
    const result: ParseResult = this.parseCharacterJson(jsonString);
    if (!result.success || result.card === null) {
      throw new Error(result.error !== null ? result.error : '导入失败');
    }
    return await this.importFromParsed(result.card);
  }

  /**
   * 将角色导出为 ArkTavern JSON 字符串。
   *
   * @param id 角色 ID
   * @returns ArkTavern JSON 字符串
   */
  async exportToJson(id: string): Promise<string> {
    this.requireInit();
    const character: Character | null = await this.store.getById(id);
    if (character === null) {
      throw new Error('CharacterService exportToJson: not found: ' + id);
    }
    return writeCharacterToJson(character);
  }

  /**
   * 从文件 URI 读取文本内容。
   * 检查文件大小不超过 10MB。
   *
   * @param uri 文件 URI
   * @returns 文件文本内容
   */
  async readFileContent(uri: string): Promise<string> {
    try {
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      if (stat.size > 10 * 1024 * 1024) {
        fileIo.closeSync(file);
        throw new Error('文件过大,不能超过 10MB');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const readLen: number = fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const content: string = textDecoder.decodeToString(new Uint8Array(buffer, 0, readLen));
      Logger.info(LOG_TAG, 'readFileContent ok size=' + String(readLen));
      return content;
    } catch (e) {
      if (e instanceof Error && e.message.includes('文件过大')) {
        throw e;
      }
      Logger.error(LOG_TAG, 'readFileContent failed: ' + String(e));
      throw new Error('读取文件失败');
    }
  }

  /**
   * 将文本内容写入文件 URI。
   *
   * @param uri 文件 URI
   * @param content 要写入的文本内容
   */
  async writeFileContent(uri: string, content: string): Promise<void> {
    try {
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      const textEncoder: util.TextEncoder = new util.TextEncoder();
      const buffer: Uint8Array = textEncoder.encodeInto(content);
      fileIo.writeSync(file.fd, buffer.buffer as ArrayBuffer);
      fileIo.closeSync(file);
      Logger.info(LOG_TAG, 'writeFileContent ok size=' + String(content.length));
    } catch (e) {
      Logger.error(LOG_TAG, 'writeFileContent failed: ' + String(e));
      throw new Error('写入文件失败');
    }
  }

  /**
   * 从文件 URI 导入角色。
   * 读取文件 → 解析 JSON → 保存。
   *
   * @param uri 文件 URI
   * @returns 新创建的 Character
   */
  async importFromFile(uri: string): Promise<Character> {
    const jsonString: string = await this.readFileContent(uri);
    return await this.importFromJson(jsonString);
  }

  /**
   * 导出角色到文件 URI。
   * 读取角色 → 序列化 → 写入文件。
   *
   * @param id 角色 ID
   * @param uri 文件 URI
   */
  async exportToFile(id: string, uri: string): Promise<void> {
    const jsonString: string = await this.exportToJson(id);
    await this.writeFileContent(uri, jsonString);
    Logger.info(LOG_TAG, 'exportToFile ok id=' + id);
  }
}