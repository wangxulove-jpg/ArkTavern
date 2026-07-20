/**
 * MemoryManagementViewModel 对话记忆管理页面状态(v8)
 *
 * 职责:
 * - 加载当前 Active Branch 的最新 Memory(摘要 / 范围 / 启用状态 / 更新时间)
 * - 启用/禁用 Memory
 * - 手动编辑摘要文本
 * - 手动触发增量总结(若未达阈值也强制执行)
 * - 清除当前 Branch 自产记忆(继承祖先的不删)
 *
 * 数据流:
 * - MemoryManagementPage 传入 chatId
 * - ViewModel 通过 ConversationBranchPersistenceService 加载 Active BranchId + 消息
 * - ViewModel 通过 MemoryService 操作 Memory
 *
 * 不依赖:
 * - ArkUI / 页面
 * - 网络/Provider(通过 MemoryService 间接调用 ModelService)
 */

import { MemoryService } from '../services/MemoryService';
import { ConversationBranchPersistenceService } from '../services/ConversationBranchPersistenceService';
import { ChatMemory } from '../models/ChatMemory';
import { ChatMessage } from '../models/ChatMessage';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MemoryMgmtVM';

@Observed
export class MemoryManagementViewModel {
  /** 当前 Branch 最新 Memory(无则为 null) */
  memory: ChatMemory | null = null;
  /** Active Branch ID */
  activeBranchId: string = '';
  /** 加载中 */
  isLoading: boolean = true;
  /** 操作进行中(启用/禁用/编辑/重新生成/清除) */
  isOperating: boolean = false;
  /** 错误信息(空表示无错误) */
  errorMessage: string = '';
  /** 状态消息(成功提示,自动消失) */
  statusMessage: string = '';
  /** 编辑模式 */
  isEditing: boolean = false;
  /** 编辑中的摘要文本 */
  editingSummary: string = '';
  /** Branch 消息总数(用于估算未总结) */
  totalMessageCount: number = 0;
  /** 摘要覆盖的消息数(= endPosition + 1,endPosition < 0 时为 0) */
  summarizedMessageCount: number = 0;
  /** 未总结消息数 */
  unsummarizedMessageCount: number = 0;
  /** 未总结字符数 */
  unsummarizedChars: number = 0;
  /** 摘要字符数 */
  summaryChars: number = 0;

  private memoryService: MemoryService;
  private branchPersistenceService: ConversationBranchPersistenceService;
  private chatId: string = '';
  private disposed: boolean = false;

  constructor(
    memoryService: MemoryService,
    branchPersistenceService: ConversationBranchPersistenceService
  ) {
    this.memoryService = memoryService;
    this.branchPersistenceService = branchPersistenceService;
  }

  /**
   * 初始化:加载 Active Branch 的 Memory 与统计。
   */
  async initialize(chatId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.chatId = chatId;
    this.isLoading = true;
    this.errorMessage = '';
    try {
      await this.reload();
    } catch (e) {
      this.errorMessage = '加载记忆失败';
      Logger.error(LOG_TAG, 'initialize failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 重新加载 Memory 与 Branch 消息统计。
   */
  async reload(): Promise<void> {
    if (this.chatId.length === 0) {
      return;
    }
    try {
      // 加载 Active Branch 消息
      const messages: ChatMessage[] =
        await this.branchPersistenceService.loadActiveBranchMessages(this.chatId);
      this.totalMessageCount = messages.length;

      // 获取 Active Branch ID(从 PersistenceService 间接获取)
      const activeBranch = await this.branchPersistenceService.getActiveBranch(this.chatId);
      const branchId: string = activeBranch !== null ? activeBranch.id : '';
      this.activeBranchId = branchId;
      if (branchId.length === 0) {
        // 无 Active Branch,直接返回空状态
        this.memory = null;
        this.summarizedMessageCount = 0;
        this.unsummarizedMessageCount = this.totalMessageCount;
        this.unsummarizedChars = 0;
        this.summaryChars = 0;
        return;
      }

      // 加载最新 Memory
      const memory: ChatMemory | null =
        await this.memoryService.getEffectiveMemory(branchId);
      this.memory = memory;

      // 统计
      this.summarizedMessageCount = memory !== null && memory.endPosition >= 0
        ? memory.endPosition + 1 : 0;
      this.unsummarizedMessageCount = Math.max(0, this.totalMessageCount - this.summarizedMessageCount);
      let chars: number = 0;
      for (let i = this.summarizedMessageCount; i < messages.length; i++) {
        chars += messages[i].content.length;
      }
      this.unsummarizedChars = chars;
      this.summaryChars = memory !== null ? memory.summary.length : 0;
    } catch (e) {
      this.errorMessage = '加载记忆失败';
      Logger.error(LOG_TAG, 'reload failed: ' + String(e));
    }
  }

  /**
   * 启用/禁用当前 Memory。
   */
  async toggleEnabled(): Promise<void> {
    if (this.memory === null) {
      return;
    }
    if (this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.memoryService.setEnabled(this.memory.id, !this.memory.enabled);
      this.statusMessage = this.memory.enabled ? '已禁用' : '已启用';
      await this.reload();
    } catch (e) {
      this.errorMessage = '切换状态失败';
      Logger.error(LOG_TAG, 'toggleEnabled failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 进入编辑模式。
   */
  enterEditMode(): void {
    if (this.memory === null) {
      return;
    }
    this.editingSummary = this.memory.summary;
    this.isEditing = true;
  }

  /**
   * 取消编辑。
   */
  cancelEdit(): void {
    this.isEditing = false;
    this.editingSummary = '';
  }

  /**
   * 保存编辑后的摘要。
   */
  async saveEditedSummary(): Promise<void> {
    if (this.memory === null) {
      return;
    }
    if (this.isOperating) {
      return;
    }
    const trimmed: string = this.editingSummary.trim();
    if (trimmed.length === 0) {
      this.errorMessage = '摘要不能为空';
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.memoryService.editSummary(this.memory.id, trimmed);
      this.statusMessage = '已保存';
      this.isEditing = false;
      this.editingSummary = '';
      await this.reload();
    } catch (e) {
      this.errorMessage = '保存失败';
      Logger.error(LOG_TAG, 'saveEditedSummary failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 手动触发重新生成摘要(强制,不检查阈值)。
   */
  async regenerateSummary(): Promise<void> {
    if (this.activeBranchId.length === 0) {
      return;
    }
    if (this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.statusMessage = '正在生成摘要...';
    try {
      const messages: ChatMessage[] =
        await this.branchPersistenceService.loadActiveBranchMessages(this.chatId);
      if (messages.length === 0) {
        this.errorMessage = '没有消息可总结';
        this.statusMessage = '';
        return;
      }
      const result = await this.memoryService.regenerateSummary(
        this.chatId, this.activeBranchId, messages
      );
      if (result.success) {
        this.statusMessage = result.memory !== null ? '已生成摘要' : '无新消息需总结';
      } else {
        this.errorMessage = '生成失败: ' + (result.error !== undefined ? result.error : '未知错误');
        this.statusMessage = '';
      }
      await this.reload();
    } catch (e) {
      this.errorMessage = '生成失败';
      this.statusMessage = '';
      Logger.error(LOG_TAG, 'regenerateSummary failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 清除当前 Branch 自产的记忆(继承祖先的不删)。
   */
  async clearOwnedMemory(): Promise<void> {
    if (this.activeBranchId.length === 0) {
      return;
    }
    if (this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.memoryService.clearOwnedByBranch(this.activeBranchId);
      this.statusMessage = '已清除当前分支记忆';
      await this.reload();
    } catch (e) {
      this.errorMessage = '清除失败';
      Logger.error(LOG_TAG, 'clearOwnedMemory failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 清除状态消息。
   */
  clearStatusMessage(): void {
    this.statusMessage = '';
  }

  /**
   * 清除错误消息。
   */
  clearErrorMessage(): void {
    this.errorMessage = '';
  }

  /**
   * 释放资源。
   */
  dispose(): void {
    this.disposed = true;
  }
}
