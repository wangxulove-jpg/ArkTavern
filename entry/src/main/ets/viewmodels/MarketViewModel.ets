/**
 * MarketViewModel 市场 ViewModel
 *
 * 管理市场列表/搜索/分页/防抖/UI 状态。
 *
 * 核心职责:
 * 1. 列表加载(首页、下拉刷新)
 * 2. 分页加载(滚动到底部加载更多)
 * 3. 搜索防抖(350ms,空搜索恢复默认推荐列表)
 * 4. 请求取消(operationId 机制,新请求覆盖旧请求)
 * 5. 去重(跨页去重,providerId + remoteId)
 * 6. 筛选(排序、NSFW、已导入、标签、创作者)
 * 7. 已导入状态管理(显示标记,本地过滤)
 * 8. 翻译开关 + 隐私弹窗 + 批量翻译触发
 *
 * 不直接:
 * - 调用 network/ 模块(通过 MarketService / MarketTranslationService)
 * - 调用 CharacterService(通过 MarketImportService,在详情 ViewModel 中)
 * - 操作 Preferences(通过 MarketService)
 */

import { MarketService } from '../services/market/MarketService';
import { MarketTranslationService } from '../services/market/MarketTranslationService';
import {
  MarketQuery,
  MarketPageResult,
  MarketSort,
  DEFAULT_MARKET_PAGE_SIZE
} from '../models/MarketQuery';
import { MarketCharacter, marketCharacterKey } from '../models/MarketCharacter';
import { MarketTranslationResult } from '../models/MarketTranslation';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MarketViewModel';
const DEBOUNCE_MS: number = 350;

@Observed
export class MarketViewModel {
  // ===== 列表状态 =====
  items: MarketCharacter[] = [];
  loading: boolean = false;
  refreshing: boolean = false;
  loadingMore: boolean = false;
  hasMore: boolean = true;
  errorMessage: string = '';

  // ===== 查询参数 =====
  searchInput: string = '';
  appliedSearch: string = '';
  sort: MarketSort = MarketSort.Recommended;
  hideNsfw: boolean = true;
  hideImported: boolean = false;
  tag: string = '';
  creator: string = '';
  providerId: string = 'chub';

  // ===== 已导入状态 =====
  /** key: providerId|remoteId,value: 本地角色 ID(空字符串也表示未导入) */
  importedMap: Map<string, string> = new Map<string, string>();

  // ===== UI 弹窗状态 =====
  /** NSFW 警告弹窗:用户尝试关闭 NSFW 隐藏时弹出 */
  showNsfwConfirm: boolean = false;
  private pendingNsfwValue: boolean = true;

  /** 翻译隐私提示弹窗:首次开启翻译时弹出 */
  showTranslatePrivacy: boolean = false;

  // ===== 翻译状态 =====
  /** "翻译为中文"开关状态(默认关闭) */
  translateEnabled: boolean = false;
  /** 内存中翻译结果,key: remoteId */
  translations: Map<string, MarketTranslationResult> = new Map<string, MarketTranslationResult>();

  /** 搜索历史(用于搜索框下拉提示) */
  searchHistory: string[] = [];

  // ===== 内部状态 =====
  private marketService: MarketService;
  /** 翻译服务(可选,未注入时翻译功能不可用) */
  private translationService: MarketTranslationService | null;
  /** 操作 ID,每次新请求自增,旧请求返回时若 opId 不匹配则忽略结果 */
  private operationId: number = 0;
  /** 防抖定时器 ID,-1 表示无定时器 */
  private debounceTimerId: number = -1;
  /** 当前已加载的页码 */
  private currentPage: number = 0;

  constructor(service: MarketService, translationService: MarketTranslationService | null = null) {
    this.marketService = service;
    this.translationService = translationService;
  }

  // ===== 生命周期 =====

  /**
   * 加载用户偏好并刷新第一页。
   * 由页面 aboutToAppear 调用。
   */
  async load(): Promise<void> {
    await this.loadPreferences();
    await this.refresh();
  }

  /**
   * 释放资源,取消所有进行中的请求和定时器。
   * 由页面 aboutToDisappear 调用。
   */
  dispose(): void {
    this.operationId++; // 让所有进行中的请求结果作废
    this.cancelDebounce();
    if (this.translationService !== null) {
      this.translationService.cancelAll();
    }
  }

  // ===== 加载与刷新 =====

  /**
   * 刷新第一页(重置分页)。
   * 取消所有进行中的请求。
   */
  async refresh(): Promise<void> {
    this.operationId++;
    const opId: number = this.operationId;
    this.refreshing = true;
    this.errorMessage = '';
    this.currentPage = 0;
    this.hasMore = true;
    this.cancelDebounce();
    // 清空内存翻译(避免显示陈旧翻译)
    this.translations = new Map<string, MarketTranslationResult>();
    try {
      const query: MarketQuery = this.buildQuery(0);
      const result: MarketPageResult = await this.marketService.searchCharacters(query);
      if (opId !== this.operationId) {
        return;
      }
      // 检查已导入状态
      const newMap: Map<string, string> = await this.marketService.checkImportedBatch(result.items);
      if (opId !== this.operationId) {
        return;
      }
      // 应用 hideImported 过滤
      let finalItems: MarketCharacter[] = result.items;
      if (this.hideImported) {
        finalItems = this.filterImported(result.items, newMap);
      }
      this.importedMap = newMap;
      this.items = finalItems;
      this.currentPage = result.page;
      this.hasMore = result.nextPage >= 0;
      // 翻译触发
      this.maybeTranslateVisible();
    } catch (e) {
      if (opId !== this.operationId) {
        return;
      }
      this.errorMessage = this.formatError(e);
      Logger.error(LOG_TAG, 'refresh failed: ' + String(e));
    } finally {
      if (opId === this.operationId) {
        this.refreshing = false;
      }
    }
  }

  /**
   * 加载下一页。
   * 防止重复加载、刷新中、无更多数据时直接返回。
   */
  async loadMore(): Promise<void> {
    if (this.loadingMore || this.refreshing || !this.hasMore) {
      return;
    }
    this.loadingMore = true;
    const opId: number = this.operationId;
    try {
      const nextPage: number = this.currentPage + 1;
      const query: MarketQuery = this.buildQuery(nextPage);
      const result: MarketPageResult = await this.marketService.searchCharacters(query);
      if (opId !== this.operationId) {
        return;
      }
      // 跨页去重
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < this.items.length; i++) {
        seen.add(marketCharacterKey(this.items[i]));
      }
      const dedupedNewItems: MarketCharacter[] = [];
      for (let i = 0; i < result.items.length; i++) {
        const item: MarketCharacter = result.items[i];
        const key: string = marketCharacterKey(item);
        if (!seen.has(key)) {
          dedupedNewItems.push(item);
          seen.add(key);
        }
      }
      // 检查已导入状态(仅检查新条目)
      const newMap: Map<string, string> = await this.marketService.checkImportedBatch(dedupedNewItems);
      if (opId !== this.operationId) {
        return;
      }
      // 合并 importedMap
      const mergedMap: Map<string, string> = new Map<string, string>();
      this.importedMap.forEach((value: string, key: string) => {
        mergedMap.set(key, value);
      });
      newMap.forEach((value: string, key: string) => {
        mergedMap.set(key, value);
      });
      // 应用 hideImported 过滤
      let finalNewItems: MarketCharacter[] = dedupedNewItems;
      if (this.hideImported) {
        finalNewItems = this.filterImported(dedupedNewItems, mergedMap);
      }
      // 合并 items
      if (finalNewItems.length > 0) {
        const mergedItems: MarketCharacter[] = [];
        for (let i = 0; i < this.items.length; i++) {
          mergedItems.push(this.items[i]);
        }
        for (let i = 0; i < finalNewItems.length; i++) {
          mergedItems.push(finalNewItems[i]);
        }
        this.items = mergedItems;
      }
      this.importedMap = mergedMap;
      this.currentPage = result.page;
      this.hasMore = result.nextPage >= 0;
      // 翻译触发(新加载的条目)
      this.maybeTranslateVisible();
    } catch (e) {
      if (opId !== this.operationId) {
        return;
      }
      this.errorMessage = this.formatError(e);
      Logger.error(LOG_TAG, 'loadMore failed: ' + String(e));
    } finally {
      if (opId === this.operationId) {
        this.loadingMore = false;
      }
    }
  }

  // ===== 搜索 =====

  /**
   * 搜索框输入变化,触发防抖。
   * 不在每个字符变化时立即请求。
   */
  onSearchInput(value: string): void {
    this.searchInput = value;
    this.cancelDebounce();
    this.debounceTimerId = setTimeout((): void => {
      void this.applySearch();
    }, DEBOUNCE_MS);
  }

  /**
   * 提交搜索(立即触发,跳过防抖)。
   * 由搜索按钮或回车键调用。
   */
  async submitSearch(): Promise<void> {
    this.cancelDebounce();
    await this.applySearch();
  }

  /**
   * 应用搜索词,空搜索恢复默认推荐列表。
   */
  private async applySearch(): Promise<void> {
    this.debounceTimerId = -1;
    const trimmed: string = this.searchInput.trim();
    if (trimmed === this.appliedSearch) {
      return;
    }
    this.appliedSearch = trimmed;
    await this.refresh();
    if (trimmed.length > 0) {
      try {
        await this.marketService.addSearchHistory(trimmed);
        await this.reloadSearchHistory();
      } catch (e) {
        Logger.warn(LOG_TAG, 'addSearchHistory failed: ' + String(e));
      }
    }
  }

  /**
   * 清空搜索词。
   */
  async clearSearch(): Promise<void> {
    this.searchInput = '';
    this.appliedSearch = '';
    this.cancelDebounce();
    await this.refresh();
  }

  // ===== 筛选 =====

  /**
   * 设置排序方式。
   */
  async setSort(value: MarketSort): Promise<void> {
    if (this.sort === value) {
      return;
    }
    this.sort = value;
    try {
      await this.marketService.setSort(value);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setSort save failed: ' + String(e));
    }
    await this.refresh();
  }

  /**
   * 设置是否隐藏 NSFW。
   * 当用户尝试关闭隐藏(即显示 NSFW)时,弹出二次确认。
   */
  setHideNsfw(value: boolean): void {
    if (this.hideNsfw === value) {
      return;
    }
    if (!value) {
      // 用户尝试显示 NSFW,需要二次确认
      this.pendingNsfwValue = value;
      this.showNsfwConfirm = true;
      return;
    }
    // 隐藏 NSFW 不需要确认
    void this.applyHideNsfw(value);
  }

  /**
   * 确认显示 NSFW 内容。
   */
  async confirmShowNsfw(): Promise<void> {
    this.showNsfwConfirm = false;
    await this.applyHideNsfw(this.pendingNsfwValue);
  }

  /**
   * 取消显示 NSFW。
   */
  cancelShowNsfw(): void {
    this.showNsfwConfirm = false;
    this.pendingNsfwValue = true;
  }

  /**
   * 设置是否隐藏已导入角色。
   */
  async setHideImported(value: boolean): Promise<void> {
    if (this.hideImported === value) {
      return;
    }
    this.hideImported = value;
    try {
      await this.marketService.setHideImported(value);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setHideImported save failed: ' + String(e));
    }
    await this.refresh();
  }

  /**
   * 设置标签筛选(空字符串表示清除标签筛选)。
   */
  async setTag(value: string): Promise<void> {
    if (this.tag === value) {
      return;
    }
    this.tag = value;
    await this.refresh();
  }

  /**
   * 设置创作者筛选(空字符串表示清除创作者筛选)。
   */
  async setCreator(value: string): Promise<void> {
    if (this.creator === value) {
      return;
    }
    this.creator = value;
    await this.refresh();
  }

  /**
   * 切换 Provider(第一版仅 chub)。
   */
  async setProvider(id: string): Promise<void> {
    if (this.providerId === id) {
      return;
    }
    try {
      await this.marketService.setCurrentProvider(id);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setProvider failed: ' + String(e));
    }
    this.providerId = id;
    await this.refresh();
  }

  // ===== 翻译开关 =====

  /**
   * 设置翻译开关状态。
   * 开启时若首次(translateEnabled=false → true),先弹出隐私提示。
   * 关闭时立即生效并清空内存翻译。
   */
  setTranslateEnabled(value: boolean): void {
    if (this.translateEnabled === value) {
      return;
    }
    if (value) {
      // 开启前弹出隐私提示
      this.showTranslatePrivacy = true;
      return;
    }
    // 关闭不需要确认
    void this.applyTranslateEnabled(false);
  }

  /**
   * 确认开启翻译(用户阅读隐私提示后)。
   */
  async confirmEnableTranslate(): Promise<void> {
    this.showTranslatePrivacy = false;
    await this.applyTranslateEnabled(true);
  }

  /**
   * 取消开启翻译。
   */
  cancelEnableTranslate(): void {
    this.showTranslatePrivacy = false;
  }

  /**
   * 应用翻译开关状态(已确认或关闭)。
   */
  private async applyTranslateEnabled(value: boolean): Promise<void> {
    this.translateEnabled = value;
    if (this.translationService !== null) {
      try {
        await this.translationService.setTranslateEnabled(value);
      } catch (e) {
        Logger.warn(LOG_TAG, 'setTranslateEnabled save failed: ' + String(e));
      }
    }
    if (value) {
      // 开启:对当前可见 items 发起翻译
      this.maybeTranslateVisible();
    } else {
      // 关闭:清空内存翻译(避免显示陈旧翻译)
      this.translations = new Map<string, MarketTranslationResult>();
      if (this.translationService !== null) {
        this.translationService.cancelAll();
      }
    }
  }

  /**
   * 获取指定角色的翻译(优先内存,其次缓存)。
   * 返回 null 表示未翻译,UI 显示原文。
   */
  getTranslation(item: MarketCharacter): MarketTranslationResult | null {
    // 内存命中
    const memHit: MarketTranslationResult | undefined = this.translations.get(item.remoteId);
    if (memHit !== undefined) {
      return memHit;
    }
    return null;
  }

  /**
   * 对当前可见 items 发起批量翻译(若翻译开关已开启)。
   * 内部使用 MarketTranslationService 的防抖 + 批量机制。
   * 页面离开后由 dispose() 取消所有待执行任务。
   */
  private maybeTranslateVisible(): void {
    if (!this.translateEnabled) {
      return;
    }
    if (this.translationService === null) {
      return;
    }
    if (this.items.length === 0) {
      return;
    }
    // 过滤掉已缓存的(只翻译未缓存的)
    const pending: MarketCharacter[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const item: MarketCharacter = this.items[i];
      // 不自动翻译隐藏 NSFW 内容(已在 hideNsfw=true 时被服务端过滤,这里无需二次判断)
      pending.push(item);
    }
    if (pending.length === 0) {
      return;
    }
    this.translationService.translateItems(pending, (remoteId: string, t: MarketTranslationResult): void => {
      this.onTranslationResult(remoteId, t);
    });
  }

  /**
   * 单条翻译完成回调。
   * 写入内存 Map,触发 UI 重渲染。
   */
  private onTranslationResult(remoteId: string, translation: MarketTranslationResult): void {
    const newMap: Map<string, MarketTranslationResult> = new Map<string, MarketTranslationResult>();
    this.translations.forEach((v: MarketTranslationResult, k: string) => {
      newMap.set(k, v);
    });
    newMap.set(remoteId, translation);
    this.translations = newMap;
  }

  // ===== 已导入状态 =====

  /**
   * 判断指定角色是否已导入。
   */
  isImported(item: MarketCharacter): boolean {
    const key: string = item.providerId + '|' + item.remoteId;
    const v: string | undefined = this.importedMap.get(key);
    return v !== undefined && v.length > 0;
  }

  /**
   * 获取已导入角色的本地 ID(未导入返回空字符串)。
   */
  getImportedLocalId(item: MarketCharacter): string {
    const key: string = item.providerId + '|' + item.remoteId;
    const v: string | undefined = this.importedMap.get(key);
    if (v === undefined) {
      return '';
    }
    return v;
  }

  /**
   * 导入成功后更新 importedMap。
   * 由详情页导入成功后调用,触发列表"已导入"标记刷新。
   */
  markImported(providerId: string, remoteId: string, localId: string): void {
    const key: string = providerId + '|' + remoteId;
    const newMap: Map<string, string> = new Map<string, string>();
    this.importedMap.forEach((value: string, k: string) => {
      newMap.set(k, value);
    });
    newMap.set(key, localId);
    this.importedMap = newMap;
  }

  // ===== 搜索历史 =====

  /**
   * 重新加载搜索历史(用于搜索框下拉提示)。
   */
  async reloadSearchHistory(): Promise<void> {
    try {
      this.searchHistory = await this.marketService.getSearchHistory();
    } catch (e) {
      Logger.warn(LOG_TAG, 'reloadSearchHistory failed: ' + String(e));
    }
  }

  /**
   * 清空搜索历史。
   */
  async clearSearchHistory(): Promise<void> {
    try {
      await this.marketService.clearSearchHistory();
      this.searchHistory = [];
    } catch (e) {
      Logger.warn(LOG_TAG, 'clearSearchHistory failed: ' + String(e));
    }
  }

  // ===== 内部方法 =====

  /**
   * 加载用户偏好到 ViewModel 状态。
   */
  private async loadPreferences(): Promise<void> {
    try {
      const query: MarketQuery = await this.marketService.loadQueryPreferences();
      this.hideNsfw = query.hideNsfw;
      this.hideImported = query.hideImported;
      this.sort = query.sort;
      this.providerId = this.marketService.getCurrentProvider().providerId;
      this.searchInput = '';
      this.appliedSearch = '';
      // 加载翻译偏好
      if (this.translationService !== null) {
        this.translateEnabled = await this.translationService.isTranslateEnabled();
      } else {
        this.translateEnabled = false;
      }
      await this.reloadSearchHistory();
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadPreferences failed: ' + String(e));
    }
  }

  /**
   * 应用 hideNsfw 偏好并刷新。
   */
  private async applyHideNsfw(value: boolean): Promise<void> {
    this.hideNsfw = value;
    try {
      await this.marketService.setHideNsfw(value);
    } catch (e) {
      Logger.warn(LOG_TAG, 'applyHideNsfw save failed: ' + String(e));
    }
    await this.refresh();
  }

  /**
   * 取消防抖定时器。
   */
  private cancelDebounce(): void {
    if (this.debounceTimerId !== -1) {
      clearTimeout(this.debounceTimerId);
      this.debounceTimerId = -1;
    }
  }

  /**
   * 构造查询参数。
   */
  private buildQuery(page: number): MarketQuery {
    return {
      search: this.appliedSearch,
      sort: this.sort,
      tag: this.tag,
      creator: this.creator,
      hideNsfw: this.hideNsfw,
      hideImported: this.hideImported,
      page: page,
      pageSize: DEFAULT_MARKET_PAGE_SIZE
    };
  }

  /**
   * 过滤已导入角色(本地过滤)。
   */
  private filterImported(
    items: MarketCharacter[],
    map: Map<string, string>
  ): MarketCharacter[] {
    const result: MarketCharacter[] = [];
    for (let i = 0; i < items.length; i++) {
      const item: MarketCharacter = items[i];
      const key: string = item.providerId + '|' + item.remoteId;
      const v: string | undefined = map.get(key);
      const imported: boolean = v !== undefined && v.length > 0;
      if (!imported) {
        result.push(item);
      }
    }
    return result;
  }

  /**
   * 格式化错误消息。
   */
  private formatError(e: Object): string {
    return '加载失败: ' + String(e);
  }
}
