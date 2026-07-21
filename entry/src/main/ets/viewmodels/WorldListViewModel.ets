/**
 * WorldListViewModel 多人世界列表 ViewModel
 *
 * 职责:
 * - 加载全部多人世界列表
 * - 显示每个世界的成员数量、最近会话信息
 * - 删除世界(级联清理 9 张 v10 表,不删除关联 Chat)
 * - 创建/进入世界聊天由页面跳转,不在本 ViewModel 处理
 *
 * 不负责:
 * - 世界创建流程(走 WorldCreateViewModel)
 * - 聊天会话管理(走 WorldChatViewModel)
 */

import { World } from '../models/World';
import { WorldService, WorldMemberView } from '../services/WorldService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldListViewModel';

/** 世界列表项(含成员预览) */
export interface WorldListItem {
  readonly world: World;
  readonly memberCount: number;
  readonly presentCount: number;
  readonly memberPreview: WorldMemberView[];
}

@Observed
export class WorldListViewModel {
  worlds: WorldListItem[] = [];
  isLoading: boolean = false;
  errorMessage: string = '';
  /** 待删除世界(确认对话框使用) */
  pendingDeleteWorldId: string = '';
  showDeleteConfirm: boolean = false;

  private readonly worldService: WorldService;
  private disposed: boolean = false;

  constructor(worldService: WorldService) {
    this.worldService = worldService;
  }

  /** 重新加载全部世界列表 */
  async reload(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const all: World[] = await this.worldService.listWorlds();
      const items: WorldListItem[] = [];
      for (let i = 0; i < all.length; i++) {
        const w: World = all[i];
        try {
          const members: WorldMemberView[] = await this.worldService.listMembers(w.id);
          const presentCount: number = members.filter(
            (v: WorldMemberView) => v.member.enabled && v.member.present
          ).length;
          items.push({
            world: w,
            memberCount: members.length,
            presentCount: presentCount,
            memberPreview: members.slice(0, 4)
          });
        } catch (e) {
          Logger.warn(LOG_TAG, 'load members failed: ' + String(e));
          items.push({
            world: w,
            memberCount: 0,
            presentCount: 0,
            memberPreview: []
          });
        }
      }
      this.worlds = items;
    } catch (e) {
      this.errorMessage = '加载世界列表失败';
      Logger.error(LOG_TAG, 'reload failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /** 请求删除世界(打开确认对话框) */
  requestDelete(worldId: string): void {
    this.pendingDeleteWorldId = worldId;
    this.showDeleteConfirm = true;
  }

  /** 取消删除 */
  cancelDelete(): void {
    this.pendingDeleteWorldId = '';
    this.showDeleteConfirm = false;
  }

  /** 确认删除世界 */
  async confirmDelete(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const worldId: string = this.pendingDeleteWorldId;
    if (worldId.length === 0) {
      return;
    }
    this.showDeleteConfirm = false;
    this.errorMessage = '';
    try {
      await this.worldService.deleteWorld(worldId);
      this.worlds = this.worlds.filter((item: WorldListItem) => item.world.id !== worldId);
    } catch (e) {
      this.errorMessage = '删除世界失败';
      Logger.error(LOG_TAG, 'delete failed: ' + String(e));
    } finally {
      this.pendingDeleteWorldId = '';
    }
  }

  dispose(): void {
    this.disposed = true;
    this.worlds = [];
  }
}
