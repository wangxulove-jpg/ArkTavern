/**
 * ActionCardDataSource 动作卡片懒加载数据源
 *
 * T-3D.6C-A: 为 LazyForEach 提供数据源,实现卡片懒加载。
 *
 * 职责:
 * - 包装 ActionCardItem[] 数组
 * - 实现 IDataSource 接口
 * - 在数据变化时通知 DataChangeListener
 *
 * 性能:
 * - 配合 Grid + LazyForEach,屏幕外卡片不创建组件
 * - 卡片组件被销毁时,其内部 ActionPreviewCanvas 的定时器自动清理
 */

import { ActionCardItem } from '../viewmodels/Character3DActionManagerViewModel';

/**
 * 动作卡片懒加载数据源。
 *
 * 使用方式:
 * ```
 * private dataSource: ActionCardDataSource = new ActionCardDataSource();
 * // 更新数据
 * this.dataSource.setCards(cards);
 * // 在 build 中
 * LazyForEach(this.dataSource, (card: ActionCardItem) => { ... }, (card: ActionCardItem) => card.id)
 * ```
 */
export class ActionCardDataSource implements IDataSource {
  /** 卡片数据 */
  private cards: ActionCardItem[] = [];
  /** 已注册的监听器 */
  private listeners: DataChangeListener[] = [];

  /**
   * 设置全部卡片数据(全量替换)。
   */
  setCards(cards: ActionCardItem[]): void {
    this.cards = cards;
    this.notifyReloaded();
  }

  /**
   * 获取当前卡片数量。
   */
  totalCount(): number {
    return this.cards.length;
  }

  /**
   * 获取指定索引的卡片。
   * 越界时抛出异常(LazyForEach 保证不越界,此为防御性检查)。
   */
  getData(index: number): ActionCardItem {
    if (index < 0 || index >= this.cards.length) {
      throw new Error(`ActionCardDataSource: index ${index} out of bounds [0, ${this.cards.length})`);
    }
    return this.cards[index];
  }

  /**
   * 注册数据变化监听器。
   */
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  /**
   * 注销数据变化监听器。
   */
  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  /**
   * 通知所有监听器数据已全量刷新。
   */
  private notifyReloaded(): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}
