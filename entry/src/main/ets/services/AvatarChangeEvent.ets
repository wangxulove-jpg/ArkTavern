/**
 * AvatarChangeEvent Avatar 切换事件系统
 *
 * T-4.2 阶段 2: Avatar 单一数据源
 *
 * 职责:
 * - 定义 AvatarChangedEvent 数据结构
 * - 提供轻量级事件订阅/发布机制(进程内,非持久化)
 * - 支持 revision 递增,防止同一 avatarId 重复触发
 *
 * 设计原则:
 * - 不依赖 ArkUI / 网络 / 存储
 * - 订阅者持有 Listener 引用,unsubscribe 时移除
 * - 发布时同步遍历监听器列表,异常隔离(单个监听器失败不影响其他)
 *
 * 使用方式:
 * 1. AvatarLibraryService 持有 AvatarChangeDispatcher 单例
 * 2. setActiveAvatar / importAndActivate / repairLibrary 完成后调用 dispatch
 * 3. Character3DPocViewModel / ActionAvatarPreviewViewModel 在 aboutToAppear 订阅,aboutToDisappear 取消
 */

import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'AvatarChangeEvent';

/**
 * Avatar 变更来源。
 */
export enum AvatarChangeSource {
  /** 用户主动切换(模型库"设为当前") */
  User = 'User',
  /** Agent 通过 API 切换 */
  Agent = 'Agent',
  /** 导入新模型后自动激活 */
  Import = 'Import',
  /** 应用启动恢复上次激活 */
  Restore = 'Restore',
  /** 旧数据迁移 */
  Migration = 'Migration'
}

/**
 * Avatar 变更事件。
 *
 * revision 每次切换递增,订阅者用它判断是否已处理过该事件。
 * 不使用 modelUri 字符串比较,因为同一 Avatar 可能重建 runtime 文件。
 */
export interface AvatarChangedEvent {
  /** 切换前的 avatarId(空字符串表示之前无激活) */
  previousAvatarId: string;
  /** 切换后的 avatarId(空字符串表示取消激活) */
  currentAvatarId: string;
  /** 当前激活模型的运行时 URI(file://...,可直接用于 Scene.load) */
  runtimeUri: string;
  /** 显示名(用于 UI 直显) */
  displayName: string;
  /** 变更来源 */
  source: AvatarChangeSource;
  /** 单调递增的修订号,每次切换 +1 */
  revision: number;
  /** 事件产生时间戳(ms) */
  timestamp: number;
}

/**
 * 事件监听器函数签名。
 */
export type AvatarChangeListener = (event: AvatarChangedEvent) => void;

/**
 * Avatar 变更事件分发器。
 *
 * 单例模式,由 AvatarLibraryService 持有。
 * 进程内同步分发,不持久化。
 */
export class AvatarChangeDispatcher {
  private listeners: AvatarChangeListener[] = [];
  private revisionCounter: number = 0;

  /**
   * 订阅事件。
   * 同一监听器重复订阅只保留一份。
   */
  subscribe(listener: AvatarChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  /**
   * 取消订阅。
   * 不存在时安全忽略。
   */
  unsubscribe(listener: AvatarChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  /**
   * 发布事件。
   *
   * revision 自动递增。
   * 监听器异常隔离:单个监听器抛错不影响其他监听器接收事件。
   */
  dispatch(
    previousAvatarId: string,
    currentAvatarId: string,
    runtimeUri: string,
    displayName: string,
    source: AvatarChangeSource
  ): AvatarChangedEvent {
    this.revisionCounter++;
    const event: AvatarChangedEvent = {
      previousAvatarId: previousAvatarId,
      currentAvatarId: currentAvatarId,
      runtimeUri: runtimeUri,
      displayName: displayName,
      source: source,
      revision: this.revisionCounter,
      timestamp: Date.now()
    };
    // 复制一份遍历,避免监听器在回调中 unsubscribe 导致索引错乱
    const snapshot: AvatarChangeListener[] = this.listeners.slice();
    for (let i: number = 0; i < snapshot.length; i++) {
      const listener: AvatarChangeListener = snapshot[i];
      try {
        listener(event);
      } catch (e) {
        Logger.warn(LOG_TAG, 'listener threw: ' + (e as Error)?.message);
      }
    }
    Logger.info(LOG_TAG, 'dispatched: prev=' + previousAvatarId.substring(0, 8)
      + ', curr=' + currentAvatarId.substring(0, 8)
      + ', rev=' + event.revision
      + ', source=' + source);
    return event;
  }

  /**
   * 读取当前最新 revision(用于初始化订阅者的 loadedRevision)。
   */
  getCurrentRevision(): number {
    return this.revisionCounter;
  }

  /**
   * 清空所有监听器(测试/重置用)。
   */
  clear(): void {
    this.listeners = [];
  }
}
