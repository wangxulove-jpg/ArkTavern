/**
 * BranchMapViewModel 分支树页面状态管理(T-6.4B-1.1 / T-6.4B-1.2)
 *
 * 职责:
 * - 加载指定 Chat 的 BranchMapDisplayInfo 列表(含 fork User 预览 + 分歧 Assistant 预览)
 * - 加载 Active Branch、RecordCounts
 * - 计算 Branch 树布局(BranchTreeLayout)
 * - 处理节点选中
 * - 调用 ConversationBranchPersistenceService.switchActiveBranch 切换 Branch
 * - 切换成功后刷新布局和 Active 状态
 *
 * 不依赖:
 * - ArkUI / 页面
 * - Repository(DbHelper 由 PersistenceService 封装)
 * - ChatService(避免初始化完整会话)
 *
 * 设计原则:
 * - @Observed 装饰,ArkUI 可直接绑定
 * - 通过 AppServices.getBranchPersistenceService() 获取服务
 * - 失败时保留当前状态,显示错误提示,不静默失败
 * - 不记录完整 Branch ID / Message ID / chatId / SQL
 */

import { ConversationBranchPersistenceService } from '../services/ConversationBranchPersistenceService';
import {
  ConversationBranchSummary,
  ConversationRecordCounts
} from '../models/ConversationBranch';
import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';
import { BranchTreeLayoutResult } from '../models/BranchMapNodeLayout';
import { computeBranchTreeLayout } from '../utils/BranchTreeLayout';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'BranchMapViewModel';

@Observed
export class BranchMapViewModel {
  /** Branch 摘要列表(向后兼容,从 displayInfos 派生) */
  branches: ConversationBranchSummary[] = [];
  /** T-6.4B-1.2: BranchMap 展示信息列表(含预览) */
  displayInfos: BranchMapDisplayInfo[] = [];
  /** 当前活动 Branch ID */
  activeBranchId: string = '';
  /** Branch 记录数量统计 */
  recordCounts: ConversationRecordCounts | undefined = undefined;
  /** 用户选中的 Branch ID(不等于 Active Branch) */
  selectedBranchId: string = '';
  /** 树布局结果 */
  layout: BranchTreeLayoutResult | undefined = undefined;
  /** Branch 切换操作进行中 */
  isBranchOperating: boolean = false;
  /** 加载中 */
  isLoading: boolean = true;
  /** 错误信息(空表示无错误) */
  errorMessage: string = '';

  private branchPersistenceService: ConversationBranchPersistenceService;
  private chatId: string = '';
  private disposed: boolean = false;

  constructor(branchPersistenceService: ConversationBranchPersistenceService) {
    this.branchPersistenceService = branchPersistenceService;
  }

  /**
   * 初始化:加载指定 Chat 的 Branch 数据并计算布局。
   * 默认选中当前 Active Branch。
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
      // 默认选中 Active Branch
      this.selectedBranchId = this.activeBranchId;
    } catch (e) {
      this.errorMessage = '加载分支失败';
      Logger.error(LOG_TAG, 'initialize failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 重新加载 Branch 数据并重算布局。
   * T-6.4B-1.2: 使用 loadBranchMapDisplayInfos 获取含预览的展示信息。
   */
  private async reload(): Promise<void> {
    if (this.chatId.length === 0) {
      return;
    }
    const displayInfos: BranchMapDisplayInfo[] =
      await this.branchPersistenceService.loadBranchMapDisplayInfos(this.chatId);
    const branches: ConversationBranchSummary[] = displayInfos.map(
      (info: BranchMapDisplayInfo): ConversationBranchSummary => info.summary
    );
    const activeBranch: ConversationBranchSummary | undefined =
      branches.find((b: ConversationBranchSummary): boolean => b.isActive);
    const counts: ConversationRecordCounts =
      await this.branchPersistenceService.getRecordCounts(this.chatId);

    this.displayInfos = displayInfos;
    this.branches = branches;
    this.activeBranchId = activeBranch !== undefined ? activeBranch.id : '';
    this.recordCounts = counts;
    this.layout = computeBranchTreeLayout(branches, displayInfos);
  }

  /**
   * 选中指定 Branch(不切换 Active)。
   */
  selectBranch(branchId: string): void {
    if (this.disposed || this.isBranchOperating) {
      return;
    }
    this.selectedBranchId = branchId;
  }

  /**
   * 切换 Active Branch 到当前选中的 Branch。
   * 成功后刷新布局和 Active 状态。
   */
  async switchToSelected(): Promise<void> {
    if (this.disposed || this.isBranchOperating) {
      return;
    }
    if (this.selectedBranchId.length === 0) {
      this.errorMessage = '请先选择一个分支';
      return;
    }
    if (this.selectedBranchId === this.activeBranchId) {
      // 已是当前分支,无操作
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    try {
      await this.branchPersistenceService.switchActiveBranch(
        this.chatId, this.selectedBranchId
      );
      await this.reload();
      // 选中跟随 Active
      this.selectedBranchId = this.activeBranchId;
    } catch (e) {
      this.errorMessage = '切换分支失败,请重试';
      Logger.error(LOG_TAG, 'switchToSelected failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  /**
   * 获取顶部统计文本。
   */
  getStatusText(): string {
    if (this.recordCounts === undefined) {
      return '';
    }
    const current: number = this.recordCounts.currentBranchMessageCount;
    const total: number = this.recordCounts.totalUniqueMessageCount;
    const branches: number = this.recordCounts.totalBranchCount;
    return '当前分支 ' + current.toString() + ' 条 · 全部消息 ' + total.toString()
      + ' 条 · ' + branches.toString() + ' 个分支';
  }

  /**
   * 判断指定 Branch 是否为当前选中。
   */
  isSelected(branchId: string): boolean {
    return this.selectedBranchId === branchId;
  }

  /**
   * 判断指定 Branch 是否为当前 Active。
   */
  isActiveBranch(branchId: string): boolean {
    return this.activeBranchId === branchId;
  }

  /**
   * T-6.4B-1.2: 获取指定 Branch 的展示信息。
   */
  getDisplayInfo(branchId: string): BranchMapDisplayInfo | undefined {
    for (let i = 0; i < this.displayInfos.length; i++) {
      if (this.displayInfos[i].branchId === branchId) {
        return this.displayInfos[i];
      }
    }
    return undefined;
  }

  /**
   * T-6.4B-1.2: 获取选中 Branch 的显示名称。
   * Root: "主分支"
   * 非 Root: "第 N 轮分支"(N = forkTurnNumber)
   */
  getSelectedDisplayName(): string {
    if (this.selectedBranchId.length === 0) {
      return '';
    }
    const info: BranchMapDisplayInfo | undefined =
      this.getDisplayInfo(this.selectedBranchId);
    if (info === undefined) {
      return '';
    }
    if (info.isRoot) {
      return '主分支';
    }
    if (info.forkTurnNumber > 0) {
      return '第 ' + info.forkTurnNumber.toString() + ' 轮分支';
    }
    return '分支';
  }

  /**
   * T-6.4B-1.2: 获取选中 Branch 的 fork User 预览。
   */
  getSelectedForkUserPreview(): string {
    if (this.selectedBranchId.length === 0) {
      return '';
    }
    const info: BranchMapDisplayInfo | undefined =
      this.getDisplayInfo(this.selectedBranchId);
    return info !== undefined ? info.forkUserPreview : '';
  }

  /**
   * T-6.4B-1.2: 获取选中 Branch 的分歧 Assistant 预览。
   */
  getSelectedAssistantPreview(): string {
    if (this.selectedBranchId.length === 0) {
      return '';
    }
    const info: BranchMapDisplayInfo | undefined =
      this.getDisplayInfo(this.selectedBranchId);
    return info !== undefined ? info.firstDivergentAssistantPreview : '';
  }

  /**
   * 获取选中 Branch 的消息数。
   */
  getSelectedMessageCount(): number {
    if (this.selectedBranchId.length === 0) {
      return 0;
    }
    const info: BranchMapDisplayInfo | undefined =
      this.getDisplayInfo(this.selectedBranchId);
    return info !== undefined ? info.messageCount : 0;
  }

  dispose(): void {
    this.disposed = true;
  }
}
