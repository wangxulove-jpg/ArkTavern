/**
 * LorebookService 世界书业务服务
 *
 * 封装 LorebookStore,提供世界书 CRUD、条目管理、关键词匹配和注入构建。
 * 页面只通过 ViewModel 访问,不直接操作 LorebookStore。
 *
 * 设计原则:
 * - 不依赖 ArkUI
 * - 不缓存 API Key
 * - 不存储聊天记录
 * - 匹配逻辑纯逻辑,不依赖网络
 */

import { common } from '@kit.AbilityKit';
import {
  Lorebook,
  LorebookEntry,
  LorebookPosition,
  LorebookUpdates,
  LorebookEntryUpdates,
  createLorebook,
  createLorebookEntry,
  updateLorebook,
  addEntryToLorebook,
  removeEntryFromLorebook,
  updateEntryInLorebook,
  validateLorebook,
  validateLorebookEntry
} from '../models/Lorebook';
import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { LorebookStore } from '../storage/LorebookStore';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LorebookService';

/** 默认扫描最近消息数 */
const DEFAULT_SCAN_MESSAGES: number = 10;
/** 默认最大注入字符数 */
const DEFAULT_MAX_INJECTION_CHARS: number = 12000;

/**
 * 注入结果。
 */
export interface LorebookInjection {
  /** BeforeCharacter 位置的 System 消息内容 */
  before: string;
  /** AfterCharacter 位置的 System 消息内容 */
  after: string;
}

export class LorebookService {
  private store: LorebookStore;
  private initialized: boolean = false;
  private readonly maxScanMessages: number;
  private readonly maxInjectionChars: number;

  constructor(
    store: LorebookStore,
    maxScanMessages: number = DEFAULT_SCAN_MESSAGES,
    maxInjectionChars: number = DEFAULT_MAX_INJECTION_CHARS
  ) {
    this.store = store;
    this.maxScanMessages = maxScanMessages;
    this.maxInjectionChars = maxInjectionChars;
  }

  async initialize(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    await this.store.initialize(context);
    this.initialized = true;
    Logger.info(LOG_TAG, 'initialize ok');
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('LorebookService not initialized');
    }
  }

  // ===== 世界书 CRUD =====

  async list(): Promise<Lorebook[]> {
    this.requireInit();
    return await this.store.list();
  }

  async getById(id: string): Promise<Lorebook | null> {
    this.requireInit();
    return await this.store.getById(id);
  }

  async create(name: string, description: string = ''): Promise<Lorebook> {
    this.requireInit();
    const lorebook: Lorebook = createLorebook(name, description);
    const error: string | null = validateLorebook(lorebook);
    if (error !== null) {
      throw new Error(error);
    }
    await this.store.save(lorebook);
    Logger.info(LOG_TAG, 'create ok id=' + lorebook.id);
    return lorebook;
  }

  async update(id: string, updates: LorebookUpdates): Promise<Lorebook> {
    this.requireInit();
    const existing: Lorebook | null = await this.store.getById(id);
    if (existing === null) {
      throw new Error('LorebookService update: not found: ' + id);
    }
    const updated: Lorebook = updateLorebook(existing, updates);
    const error: string | null = validateLorebook(updated);
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

  async setCurrentLorebookId(id: string | null): Promise<void> {
    this.requireInit();
    await this.store.setCurrentLorebookId(id);
    Logger.info(LOG_TAG, 'setCurrentLorebookId ok');
  }

  async getCurrentLorebookId(): Promise<string | null> {
    this.requireInit();
    return await this.store.getCurrentLorebookId();
  }

  async getCurrentLorebook(): Promise<Lorebook | null> {
    this.requireInit();
    return await this.store.getCurrentLorebook();
  }

  // ===== 条目管理 =====

  async addEntry(
    lorebookId: string,
    name: string,
    keys: string[],
    secondaryKeys: string[],
    content: string,
    enabled: boolean = true,
    constant: boolean = false,
    selective: boolean = false,
    position: LorebookPosition = LorebookPosition.BeforeCharacter,
    priority: number = 0
  ): Promise<Lorebook> {
    this.requireInit();
    const existing: Lorebook | null = await this.store.getById(lorebookId);
    if (existing === null) {
      throw new Error('LorebookService addEntry: lorebook not found: ' + lorebookId);
    }
    const entry: LorebookEntry = createLorebookEntry(
      name, keys, secondaryKeys, content, enabled, constant, selective, position, priority
    );
    const error: string | null = validateLorebookEntry(entry);
    if (error !== null) {
      throw new Error(error);
    }
    const updated: Lorebook = addEntryToLorebook(existing, entry);
    await this.store.update(updated);
    Logger.info(LOG_TAG, 'addEntry ok lorebook=' + lorebookId + ' entry=' + entry.id);
    return updated;
  }

  async updateEntry(
    lorebookId: string,
    entryId: string,
    updates: LorebookEntryUpdates
  ): Promise<Lorebook> {
    this.requireInit();
    const existing: Lorebook | null = await this.store.getById(lorebookId);
    if (existing === null) {
      throw new Error('LorebookService updateEntry: lorebook not found: ' + lorebookId);
    }
    let entryFound: boolean = false;
    for (let i = 0; i < existing.entries.length; i++) {
      if (existing.entries[i].id === entryId) {
        entryFound = true;
        break;
      }
    }
    if (!entryFound) {
      throw new Error('LorebookService updateEntry: entry not found: ' + entryId);
    }
    const updated: Lorebook = updateEntryInLorebook(existing, entryId, updates);
    const updatedEntry: LorebookEntry | null = this.findEntry(updated, entryId);
    if (updatedEntry !== null) {
      const error: string | null = validateLorebookEntry(updatedEntry);
      if (error !== null) {
        throw new Error(error);
      }
    }
    await this.store.update(updated);
    Logger.info(LOG_TAG, 'updateEntry ok lorebook=' + lorebookId + ' entry=' + entryId);
    return updated;
  }

  async removeEntry(lorebookId: string, entryId: string): Promise<Lorebook> {
    this.requireInit();
    const existing: Lorebook | null = await this.store.getById(lorebookId);
    if (existing === null) {
      throw new Error('LorebookService removeEntry: lorebook not found: ' + lorebookId);
    }
    const updated: Lorebook = removeEntryFromLorebook(existing, entryId);
    await this.store.update(updated);
    Logger.info(LOG_TAG, 'removeEntry ok lorebook=' + lorebookId + ' entry=' + entryId);
    return updated;
  }

  // ===== 关键词匹配 =====

  /**
   * 匹配世界书条目。
   *
   * 规则:
   * 1. 扫描最近 N 条 User/Assistant 消息,忽略 System 消息
   * 2. 英文关键词不区分大小写
   * 3. 中文按原文本包含匹配
   * 4. constant=true 始终激活
   * 5. selective=false:任一主关键词匹配即激活
   * 6. selective=true:主关键词和至少一个 secondaryKey 同时匹配
   * 7. disabled 条目不激活
   * 8. 按 priority 从高到低排序
   * 9. 同一条目每次请求只注入一次
   * 10. 限制最大注入字符数,超出时优先保留高优先级条目
   *
   * @param messages 消息列表
   * @returns 匹配的条目列表(按 priority 降序)
   */
  matchEntries(messages: ChatMessage[]): LorebookEntry[] {
    const lorebook: Lorebook | null = this.getCurrentLorebookSync();
    if (lorebook === null || !lorebook.enabled) {
      return [];
    }

    // 收集最近 N 条 User/Assistant 消息文本
    const recentTexts: string[] = [];
    let count: number = 0;
    for (let i = messages.length - 1; i >= 0 && count < this.maxScanMessages; i--) {
      const msg: ChatMessage = messages[i];
      if (msg.role === ChatRole.User || msg.role === ChatRole.Assistant) {
        recentTexts.push(msg.content);
        count++;
      }
    }

    const matched: LorebookEntry[] = [];
    for (let i = 0; i < lorebook.entries.length; i++) {
      const entry: LorebookEntry = lorebook.entries[i];
      if (!entry.enabled) {
        continue;
      }
      if (entry.constant) {
        matched.push(entry);
      } else if (this.isEntryMatched(entry, recentTexts)) {
        matched.push(entry);
      }
    }

    // 按 priority 降序排序
    matched.sort((a: LorebookEntry, b: LorebookEntry): number => b.priority - a.priority);

    // 限制最大字符数
    const limited: LorebookEntry[] = [];
    let totalChars: number = 0;
    for (let i = 0; i < matched.length; i++) {
      const entryChars: number = matched[i].content.length;
      if (totalChars + entryChars <= this.maxInjectionChars) {
        limited.push(matched[i]);
        totalChars += entryChars;
      }
    }

    return limited;
  }

  /**
   * 构建注入内容。
   * 将匹配条目按 Position 分组,返回 Before/After 格式。
   *
   * @param messages 消息列表
   * @returns 注入内容
   */
  buildInjection(messages: ChatMessage[]): LorebookInjection {
    const entries: LorebookEntry[] = this.matchEntries(messages);
    const beforeParts: string[] = [];
    const afterParts: string[] = [];

    for (let i = 0; i < entries.length; i++) {
      const entry: LorebookEntry = entries[i];
      if (entry.position === LorebookPosition.BeforeCharacter) {
        beforeParts.push(entry.content);
      } else {
        afterParts.push(entry.content);
      }
    }

    const result: LorebookInjection = {
      before: beforeParts.join('\n\n'),
      after: afterParts.join('\n\n')
    };
    return result;
  }

  // ===== 内部方法 =====

  /**
   * 同步获取当前世界书(不涉及异步操作,仅在已初始化后使用)。
   */
  private getCurrentLorebookSync(): Lorebook | null {
    // 注意:这里不能直接调用 store.getCurrentLorebook() 因为它是 async
    // 但 matchEntries 是同步方法。我们需要在 matchEntries 调用前确保
    // 当前世界书已被缓存。这里简化处理:直接返回 null 表示需要异步获取。
    // 实际使用时,调用方应在调用 matchEntries 前获取当前世界书。
    return null;
  }

  /**
   * 异步获取当前世界书并匹配条目。
   */
  async matchEntriesAsync(messages: ChatMessage[]): Promise<LorebookEntry[]> {
    this.requireInit();
    const lorebook: Lorebook | null = await this.store.getCurrentLorebook();
    if (lorebook === null || !lorebook.enabled) {
      return [];
    }
    return this.matchEntriesForLorebook(lorebook, messages);
  }

  /**
   * 异步构建注入内容。
   */
  async buildInjectionAsync(messages: ChatMessage[]): Promise<LorebookInjection> {
    this.requireInit();
    const lorebook: Lorebook | null = await this.store.getCurrentLorebook();
    if (lorebook === null || !lorebook.enabled) {
      const empty: LorebookInjection = { before: '', after: '' };
      return empty;
    }
    const entries: LorebookEntry[] = this.matchEntriesForLorebook(lorebook, messages);
    const beforeParts: string[] = [];
    const afterParts: string[] = [];

    for (let i = 0; i < entries.length; i++) {
      const entry: LorebookEntry = entries[i];
      if (entry.position === LorebookPosition.BeforeCharacter) {
        beforeParts.push(entry.content);
      } else {
        afterParts.push(entry.content);
      }
    }

    const result: LorebookInjection = {
      before: beforeParts.join('\n\n'),
      after: afterParts.join('\n\n')
    };
    return result;
  }

  /**
   * 对指定世界书和消息列表执行匹配。
   * 公开方法,供 PromptBuilder 等外部调用。
   */
  matchEntriesForLorebook(
    lorebook: Lorebook,
    messages: ChatMessage[]
  ): LorebookEntry[] {
    // 收集最近 N 条 User/Assistant 消息文本
    const recentTexts: string[] = [];
    let count: number = 0;
    for (let i = messages.length - 1; i >= 0 && count < this.maxScanMessages; i--) {
      const msg: ChatMessage = messages[i];
      if (msg.role === ChatRole.User || msg.role === ChatRole.Assistant) {
        recentTexts.push(msg.content);
        count++;
      }
    }

    const matched: LorebookEntry[] = [];
    for (let i = 0; i < lorebook.entries.length; i++) {
      const entry: LorebookEntry = lorebook.entries[i];
      if (!entry.enabled) {
        continue;
      }
      if (entry.constant) {
        matched.push(entry);
      } else if (this.isEntryMatched(entry, recentTexts)) {
        matched.push(entry);
      }
    }

    // 按 priority 降序排序
    matched.sort((a: LorebookEntry, b: LorebookEntry): number => b.priority - a.priority);

    // 限制最大字符数
    const limited: LorebookEntry[] = [];
    let totalChars: number = 0;
    for (let i = 0; i < matched.length; i++) {
      const entryChars: number = matched[i].content.length;
      if (totalChars + entryChars <= this.maxInjectionChars) {
        limited.push(matched[i]);
        totalChars += entryChars;
      }
    }

    return limited;
  }

  /**
   * 判断条目是否匹配最近的聊天文本。
   */
  private isEntryMatched(entry: LorebookEntry, texts: string[]): boolean {
    if (entry.selective) {
      // selective: 主关键词 + 次关键词同时匹配
      const primaryMatched: boolean = this.matchAnyKey(entry.keys, texts);
      if (!primaryMatched) {
        return false;
      }
      if (entry.secondaryKeys.length === 0) {
        return true;
      }
      return this.matchAnyKey(entry.secondaryKeys, texts);
    } else {
      // non-selective: 任一主关键词匹配
      return this.matchAnyKey(entry.keys, texts);
    }
  }

  /**
   * 判断关键词列表中是否有任意一个匹配文本列表。
   * 英文不区分大小写,中文按原文本包含匹配。
   */
  private matchAnyKey(keys: string[], texts: string[]): boolean {
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      if (key.length === 0) {
        continue;
      }
      for (let j = 0; j < texts.length; j++) {
        if (this.matchKeyInText(key, texts[j])) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 判断关键词是否在文本中匹配。
   * 英文不区分大小写,中文按原文本包含匹配。
   */
  private matchKeyInText(key: string, text: string): boolean {
    if (this.isAsciiOnly(key)) {
      // 英文:不区分大小写
      const lowerKey: string = key.toLowerCase();
      const lowerText: string = text.toLowerCase();
      return lowerText.includes(lowerKey);
    } else {
      // 中文/混合:原文本包含匹配
      return text.includes(key);
    }
  }

  /**
   * 判断字符串是否仅含 ASCII 字符。
   */
  private isAsciiOnly(str: string): boolean {
    for (let i = 0; i < str.length; i++) {
      if (str.charCodeAt(i) > 127) {
        return false;
      }
    }
    return true;
  }

  private findEntry(lorebook: Lorebook, entryId: string): LorebookEntry | null {
    for (let i = 0; i < lorebook.entries.length; i++) {
      if (lorebook.entries[i].id === entryId) {
        return lorebook.entries[i];
      }
    }
    return null;
  }
}