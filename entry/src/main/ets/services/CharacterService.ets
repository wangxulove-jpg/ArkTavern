/**
 * CharacterService 角色业务服务
 *
 * 数据源:CharacterRepository(RDB)。
 * 当前角色 ID:CharacterSelectionStore(Preferences)。
 * 头像:CharacterAssetStore(文件系统)。
 *
 * 不再通过 CharacterStore 执行业务 CRUD。
 * CharacterStore 仅作为 Legacy Migration Source,由 CharacterMigrationService 在启动时一次性读取。
 *
 * 设计原则:
 * - 不依赖 ArkUI
 * - 不缓存 API Key
 * - 校验角色数据
 * - 不直接操作 RdbStore
 * - 不向页面暴露 Repository
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Character, createCharacter, updateCharacter, validateCharacter, CharacterUpdates } from '../models/Character';
import { CharacterRepository } from '../repositories/CharacterRepository';
import { CharacterSelectionStore } from '../storage/CharacterSelectionStore';
import { CharacterAssetStore } from '../storage/CharacterAssetStore';
import { CharacterStore } from '../storage/CharacterStore';
import { DatabaseError, DatabaseErrorType } from '../models/DatabaseError';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';
import { parseCharacterJson, ParseResult, ParsedCharacterCard } from '../parser/CharacterCardJsonParser';
import { writeCharacterToJson } from '../parser/CharacterCardJsonWriter';
import { parsePngCharacterCard, PngParseResult } from '../parser/PngCharacterCardParser';

const LOG_TAG: string = 'CharacterService';

/** PNG 导入解析结果 */
export interface PngImportResult {
  result: PngParseResult;
  bytes: ArrayBuffer;
}

export class CharacterService {
  private readonly repository: CharacterRepository;
  private readonly selectionStore: CharacterSelectionStore;
  private readonly assetStore: CharacterAssetStore;
  /** 旧 Preferences 数据源,仅用于迁移期间读取(不用于业务 CRUD) */
  private readonly legacyStore: CharacterStore;
  private initialized: boolean = false;

  constructor(
    repository: CharacterRepository,
    selectionStore: CharacterSelectionStore,
    assetStore: CharacterAssetStore,
    legacyStore: CharacterStore
  ) {
    this.repository = repository;
    this.selectionStore = selectionStore;
    this.assetStore = assetStore;
    this.legacyStore = legacyStore;
  }

  async initialize(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    // legacyStore 用于兼容旧数据读取(迁移时由 MigrationService 调用)
    await this.legacyStore.initialize(context);
    await this.selectionStore.initialize(context);
    this.assetStore.initialize(context);
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
    return await this.repository.list();
  }

  async getById(id: string): Promise<Character | null> {
    this.requireInit();
    return await this.repository.getById(id);
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
    try {
      await this.repository.insert(character);
    } catch (e) {
      // ID 冲突时生成新 UUID 重试一次
      if (e instanceof DatabaseError && e.type === DatabaseErrorType.AlreadyExists) {
        // createCharacter 不会重置 id,这里手动构造新对象
        const retryCharacter: Character = {
          id: 'char-' + generateUuid(),
          name: character.name,
          description: character.description,
          personality: character.personality,
          scenario: character.scenario,
          firstMessage: character.firstMessage,
          systemPrompt: character.systemPrompt,
          avatarUri: character.avatarUri,
          createdAt: character.createdAt,
          updatedAt: character.updatedAt
        };
        await this.repository.insert(retryCharacter);
        Logger.info(LOG_TAG, 'create ok (retry)');
        return retryCharacter;
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('CharacterService create failed: ' + String(e));
    }
    Logger.info(LOG_TAG, 'create ok');
    return character;
  }

  async update(
    id: string,
    updates: CharacterUpdates
  ): Promise<Character> {
    this.requireInit();
    const existing: Character | null = await this.repository.getById(id);
    if (existing === null) {
      throw new Error('CharacterService update: not found');
    }
    const updated: Character = updateCharacter(existing, updates);
    const error: string | null = validateCharacter(updated);
    if (error !== null) {
      throw new Error(error);
    }
    try {
      await this.repository.update(updated);
    } catch (e) {
      if (e instanceof DatabaseError && e.type === DatabaseErrorType.NotFound) {
        throw new Error('CharacterService update: not found');
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('CharacterService update failed: ' + String(e));
    }
    Logger.info(LOG_TAG, 'update ok id=' + id);
    return updated;
  }

  async remove(id: string): Promise<void> {
    this.requireInit();
    const existing: Character | null = await this.repository.getById(id);
    if (existing === null) {
      // 幂等:不存在视为已删除
      Logger.info(LOG_TAG, 'remove skip (not found)');
      return;
    }
    // 1. 删除 RDB Character
    await this.repository.remove(id);
    // 2. 若是当前角色,清空选择
    const currentId: string | null = await this.selectionStore.getCurrentCharacterId();
    if (currentId === id) {
      await this.selectionStore.clear();
    }
    // 3. 删除头像文件(失败不回滚角色记录)
    try {
      await this.assetStore.deleteAvatar(id);
    } catch (e) {
      Logger.warn(LOG_TAG, 'remove: deleteAvatar failed, character record already deleted');
    }
    Logger.info(LOG_TAG, 'remove ok id=' + id);
  }

  async setCurrentCharacterId(id: string | null): Promise<void> {
    this.requireInit();
    if (id !== null) {
      const exists: boolean = await this.repository.exists(id);
      if (!exists) {
        throw new Error('CharacterService setCurrentCharacterId: not found');
      }
    }
    await this.selectionStore.setCurrentCharacterId(id);
    Logger.info(LOG_TAG, 'setCurrentCharacterId ok');
  }

  async getCurrentCharacterId(): Promise<string | null> {
    this.requireInit();
    return await this.selectionStore.getCurrentCharacterId();
  }

  async getCurrentCharacter(): Promise<Character | null> {
    this.requireInit();
    const id: string | null = await this.selectionStore.getCurrentCharacterId();
    if (id === null) {
      return null;
    }
    const c: Character | null = await this.repository.getById(id);
    if (c === null) {
      // 选择指向的角色已被删除,清空选择
      await this.selectionStore.clear();
      return null;
    }
    return c;
  }

  // ===== 导入导出 =====

  /**
   * 解析角色卡 JSON(不保存)。
   * 用于导入前预览。
   */
  parseCharacterJson(jsonString: string): ParseResult {
    return parseCharacterJson(jsonString);
  }

  /**
   * 从解析后的角色卡创建并保存 Character。
   * id 冲突时生成新 UUID,不覆盖现有角色。
   */
  async importFromParsed(parsed: ParsedCharacterCard, avatarUri?: string): Promise<Character> {
    this.requireInit();
    const finalAvatarUri: string = avatarUri !== undefined ? avatarUri : parsed.avatarUri;
    let character: Character = createCharacter(
      'char-' + generateUuid(),
      parsed.name,
      parsed.description,
      parsed.personality,
      parsed.scenario,
      parsed.firstMessage,
      parsed.systemPrompt,
      finalAvatarUri
    );
    const error: string | null = validateCharacter(character);
    if (error !== null) {
      throw new Error(error);
    }
    try {
      await this.repository.insert(character);
    } catch (e) {
      if (e instanceof DatabaseError && e.type === DatabaseErrorType.AlreadyExists) {
        // ID 冲突,生成新 UUID 重试
        character = {
          id: 'char-' + generateUuid(),
          name: character.name,
          description: character.description,
          personality: character.personality,
          scenario: character.scenario,
          firstMessage: character.firstMessage,
          systemPrompt: character.systemPrompt,
          avatarUri: character.avatarUri,
          createdAt: character.createdAt,
          updatedAt: character.updatedAt
        };
        await this.repository.insert(character);
      } else {
        if (e instanceof Error) {
          throw e;
        }
        throw new Error('CharacterService importFromParsed failed: ' + String(e));
      }
    }
    Logger.info(LOG_TAG, 'importFromParsed ok source=' + parsed.sourceFormat);
    return character;
  }

  /**
   * 从 JSON 字符串解析并导入角色。
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
   */
  async exportToJson(id: string): Promise<string> {
    this.requireInit();
    const character: Character | null = await this.repository.getById(id);
    if (character === null) {
      throw new Error('CharacterService exportToJson: not found');
    }
    return writeCharacterToJson(character);
  }

  /**
   * 从文件 URI 读取文本内容。
   * 检查文件大小不超过 10MB。
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
   */
  async importFromFile(uri: string): Promise<Character> {
    const jsonString: string = await this.readFileContent(uri);
    return await this.importFromJson(jsonString);
  }

  /**
   * 导出角色到文件 URI。
   */
  async exportToFile(id: string, uri: string): Promise<void> {
    const jsonString: string = await this.exportToJson(id);
    await this.writeFileContent(uri, jsonString);
    Logger.info(LOG_TAG, 'exportToFile ok');
  }

  // ===== PNG 导入 =====

  /**
   * 从 URI 读取二进制文件内容。
   */
  async readFileBytes(uri: string): Promise<ArrayBuffer> {
    try {
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      if (stat.size > 50 * 1024 * 1024) {
        fileIo.closeSync(file);
        throw new Error('文件过大,不能超过 50MB');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const readLen: number = fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      Logger.info(LOG_TAG, 'readFileBytes ok size=' + String(readLen));
      return buffer;
    } catch (e) {
      if (e instanceof Error && e.message.includes('文件过大')) {
        throw e;
      }
      Logger.error(LOG_TAG, 'readFileBytes failed: ' + String(e));
      throw new Error('读取文件失败');
    }
  }

  /**
   * 从 PNG 文件 URI 解析角色卡(不保存)。
   */
  async importPngFromFile(uri: string): Promise<PngImportResult> {
    const bytes: ArrayBuffer = await this.readFileBytes(uri);
    const uint8: Uint8Array = new Uint8Array(bytes);
    const pngResult: PngParseResult = parsePngCharacterCard(uint8);

    if (!pngResult.success) {
      const result: PngImportResult = { result: pngResult, bytes: bytes };
      return result;
    }

    // 复用 CharacterCardJsonParser 解析 JSON
    const jsonResult: ParseResult = parseCharacterJson(pngResult.jsonString);
    if (!jsonResult.success) {
      const errorResult: PngImportResult = {
        result: {
          success: false,
          jsonString: '',
          sourceFormat: pngResult.sourceFormat,
          error: '角色卡 JSON 解析失败: ' + (jsonResult.error !== null ? jsonResult.error : '')
        },
        bytes: bytes
      };
      return errorResult;
    }

    const okResult: PngImportResult = { result: pngResult, bytes: bytes };
    return okResult;
  }

  /**
   * 确认 PNG 导入:保存头像 + 保存角色。
   * 头像保存失败时不创建角色;角色保存失败时回滚头像。
   */
  async confirmPngImport(parsed: ParsedCharacterCard, pngUri: string): Promise<Character> {
    this.requireInit();
    const characterId: string = 'char-' + generateUuid();
    // 1. 保存头像(失败则不创建角色)
    const avatarUri: string = await this.assetStore.saveAvatar(pngUri, characterId);
    // 2. 创建并保存角色
    const character: Character = createCharacter(
      characterId,
      parsed.name,
      parsed.description,
      parsed.personality,
      parsed.scenario,
      parsed.firstMessage,
      parsed.systemPrompt,
      avatarUri
    );
    const error: string | null = validateCharacter(character);
    if (error !== null) {
      // 回滚:删除已保存的头像
      await this.assetStore.deleteAvatar(characterId);
      throw new Error(error);
    }
    try {
      await this.repository.insert(character);
    } catch (e) {
      // 角色保存失败,回滚头像
      await this.assetStore.deleteAvatar(characterId);
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('CharacterService confirmPngImport failed: ' + String(e));
    }
    Logger.info(LOG_TAG, 'confirmPngImport ok');
    return character;
  }

  /**
   * 获取 Legacy CharacterStore(仅供 CharacterMigrationService 使用)。
   */
  getLegacyStore(): CharacterStore {
    return this.legacyStore;
  }
}
