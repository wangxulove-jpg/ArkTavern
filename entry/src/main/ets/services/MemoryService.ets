/**
 * MemoryService 分支感知长期记忆业务服务
 *
 * 职责:
 * - 触发增量总结(旧摘要 + 新增消息 → 更新摘要)
 * - 标记过期(编辑/切换 Swipe 后使摘要失效)
 * - 清除 Branch Memory(保留继承祖先)
 * - 加载当前 Branch 的有效记忆(供 PromptBuilder 使用)
 * - 手动总结、重新生成、编辑摘要
 *
 * 设计:
 * - 总结失败不阻塞正常聊天(catch 后记录 warn)
 * - 不直接调用 Provider,通过 ModelService.sendChat 复用现有配置
 * - 不暴露 chatId/branchId/summary 内容到日志
 *
 * 分层约束:
 * - 可被 ChatService 调用(注入)
 * - 可被 ChatViewModel / MemoryManagementViewModel 间接调用
 * - 不直接被 pages/ 调用
 */

import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import {
  ChatMemory,
  createChatMemory,
  withUpdatedSummary,
  withExtendedRange,
  MemorySummaryPoints,
  MemoryTriggerConfig,
  DEFAULT_MEMORY_TRIGGER,
  DEFAULT_SUMMARY_POINTS
} from '../models/ChatMemory';
import { ChatRequest } from '../models/ChatRequest';
import { ModelService } from './ModelService';
import { MemoryPersistenceService } from './MemoryPersistenceService';
import { Logger } from '../utils/Logger';
import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

const LOG_TAG: string = 'MemoryService';

/**
 * 总结请求结果。
 */
export interface MemorySummaryResult {
  /** 是否成功 */
  success: boolean;
  /** 更新后的 Memory(失败时为原值或 null) */
  memory: ChatMemory | null;
  /** 失败原因(失败时填) */
  error?: string;
}

/**
 * 注入到 PromptBuilder 的记忆上下文。
 */
export interface MemoryInjectionContext {
  /** 摘要文本(空字符串表示无可用记忆) */
  summary: string;
  /** 覆盖范围起始 position */
  startPosition: number;
  /** 覆盖范围结束 position */
  endPosition: number;
  /** 是否启用 */
  enabled: boolean;
}

export class MemoryService {
  private readonly memoryPersistence: MemoryPersistenceService;
  private readonly modelService: ModelService;
  private readonly summaryPoints: MemorySummaryPoints;
  private readonly triggerConfig: MemoryTriggerConfig;

  constructor(
    memoryPersistence: MemoryPersistenceService,
    modelService: ModelService,
    summaryPoints: MemorySummaryPoints = DEFAULT_SUMMARY_POINTS,
    triggerConfig: MemoryTriggerConfig = DEFAULT_MEMORY_TRIGGER
  ) {
    this.memoryPersistence = memoryPersistence;
    this.modelService = modelService;
    this.summaryPoints = summaryPoints;
    this.triggerConfig = triggerConfig;
  }

  /** 获取 MemoryPersistenceService(供 ChatService 事务内调用) */
  getPersistence(): MemoryPersistenceService {
    return this.memoryPersistence;
  }

  // ===== 加载 =====

  /**
   * 获取 Branch 的有效记忆(最新一条 enabled Memory)。
   * 无 Memory 或禁用时返回 null。
   */
  async getEffectiveMemory(branchId: string): Promise<ChatMemory | null> {
    if (branchId.length === 0) {
      return null;
    }
    try {
      const latest: ChatMemory | null = await this.memoryPersistence.getLatestByBranch(branchId);
      if (latest === null) {
        return null;
      }
      if (!latest.enabled) {
        return null;
      }
      return latest;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getEffectiveMemory failed: ' + String(e));
      return null;
    }
  }

  /**
   * 获取注入 Prompt 的记忆上下文。
   */
  async getInjectionContext(branchId: string): Promise<MemoryInjectionContext> {
    const memory: ChatMemory | null = await this.getEffectiveMemory(branchId);
    if (memory === null) {
      return {
        summary: '',
        startPosition: 0,
        endPosition: -1,
        enabled: false
      };
    }
    return {
      summary: memory.summary,
      startPosition: memory.startPosition,
      endPosition: memory.endPosition,
      enabled: true
    };
  }

  // ===== 触发检查 =====

  /**
   * 判断是否应该触发增量总结。
   *
   * @param branchId 当前 Branch ID
   * @param branchMessages 当前 Branch 的全部消息(按 position ASC)
   * @returns true 表示需要触发
   */
  async shouldTriggerSummary(
    branchId: string,
    branchMessages: ChatMessage[]
  ): Promise<boolean> {
    if (branchMessages.length === 0) {
      return false;
    }
    try {
      const latest: ChatMemory | null = await this.memoryPersistence.getLatestByBranch(branchId);
      const summarizedPos: number = latest !== null ? latest.endPosition : -1;
      // 统计未总结的消息数和字符数
      let unsummarizedCount: number = 0;
      let unsummarizedChars: number = 0;
      for (let i = 0; i < branchMessages.length; i++) {
        if (i > summarizedPos) {
          unsummarizedCount++;
          unsummarizedChars += branchMessages[i].content.length;
        }
      }
      if (unsummarizedCount >= this.triggerConfig.messageCountThreshold) {
        return true;
      }
      if (unsummarizedChars >= this.triggerConfig.charLengthThreshold) {
        return true;
      }
      return false;
    } catch (e) {
      Logger.warn(LOG_TAG, 'shouldTriggerSummary failed: ' + String(e));
      return false;
    }
  }

  // ===== 增量总结 =====

  /**
   * 触发增量总结(若当前未总结消息数达到阈值)。
   * 总结失败不抛错,只记录 warn。
   *
   * @param chatId 当前 Chat ID
   * @param branchId 当前 Branch ID
   * @param branchMessages 当前 Branch 的全部消息(按 position ASC)
   * @returns 总结结果(失败时 success=false)
   */
  async trySummarize(
    chatId: string,
    branchId: string,
    branchMessages: ChatMessage[]
  ): Promise<MemorySummaryResult> {
    if (branchMessages.length === 0) {
      return { success: true, memory: null };
    }
    const shouldTrigger: boolean = await this.shouldTriggerSummary(branchId, branchMessages);
    if (!shouldTrigger) {
      return { success: true, memory: null };
    }
    return await this.regenerateSummary(chatId, branchId, branchMessages);
  }

  /**
   * 重新生成当前 Branch 的 Memory。
   * 读取最新 Memory 作为基础,把旧摘要 + 后续未总结消息一起送给模型。
   *
   * 失败处理:
   * - 模型调用失败 → 返回失败结果,不修改 Memory
   * - 持久化失败 → 返回失败结果,可能 Memory 已部分修改(已 try/catch)
   */
  async regenerateSummary(
    chatId: string,
    branchId: string,
    branchMessages: ChatMessage[]
  ): Promise<MemorySummaryResult> {
    if (branchMessages.length === 0) {
      return { success: true, memory: null };
    }
    try {
      const latest: ChatMemory | null = await this.memoryPersistence.getLatestByBranch(branchId);
      const summarizedPos: number = latest !== null ? latest.endPosition : -1;
      const oldSummary: string = latest !== null ? latest.summary : '';

      // 收集需要新增总结的消息(position > summarizedPos)
      const newMessages: ChatMessage[] = [];
      for (let i = 0; i < branchMessages.length; i++) {
        if (i > summarizedPos) {
          newMessages.push(branchMessages[i]);
        }
      }
      if (newMessages.length === 0) {
        return { success: true, memory: latest };
      }

      // 构建总结提示词
      const summaryPrompt: ChatMessage[] = this.buildSummaryPrompt(oldSummary, newMessages);

      // 解析当前 Provider 配置以获取 model 名(sendChat 不会自动填)
      const config = await this.modelService.getCurrentConfig();
      if (config === null) {
        return { success: false, memory: latest, error: 'no current provider config' };
      }
      const modelName: string = config.modelName.trim();
      if (modelName.length === 0) {
        return { success: false, memory: latest, error: 'current model name is empty' };
      }

      // 调用 ModelService.sendChat(非流式)
      const request: ChatRequest = {
        model: modelName,
        messages: summaryPrompt,
        temperature: 0.3,
        topP: 0.9,
        maxTokens: 1024,
        stream: false
      };
      const response = await this.modelService.sendChat(request);
      if (response.content.length === 0) {
        return { success: false, memory: latest, error: 'empty response' };
      }

      // 更新或创建 Memory
      const lastMessage: ChatMessage = branchMessages[branchMessages.length - 1];
      const lastPosition: number = branchMessages.length - 1;
      const now: number = nowMillis();

      if (latest === null) {
        // 创建新 Memory,从 position 0 开始覆盖
        const newMemory: ChatMemory = createChatMemory(
          generateUuid(),
          chatId,
          branchId,
          branchMessages[0].id,
          lastMessage.id,
          0,
          lastPosition,
          response.content,
          now
        );
        await this.memoryPersistence.insert(newMemory);
        Logger.info(LOG_TAG, 'memory created');
        return { success: true, memory: newMemory };
      } else {
        // 扩展范围
        const updated: ChatMemory = withExtendedRange(
          latest,
          lastMessage.id,
          lastPosition,
          response.content,
          now
        );
        await this.memoryPersistence.update(updated);
        Logger.info(LOG_TAG, 'memory updated');
        return { success: true, memory: updated };
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'regenerateSummary failed: ' + String(e));
      return { success: false, memory: null, error: String(e) };
    }
  }

  /**
   * 构建总结提示词。
   * 包含:角色定义 + 任务说明 + 旧摘要 + 新增消息 + 输出要求。
   */
  private buildSummaryPrompt(oldSummary: string, newMessages: ChatMessage[]): ChatMessage[] {
    const points: string[] = [];
    if (this.summaryPoints.relationships) points.push('- 人物关系');
    if (this.summaryPoints.facts) points.push('- 重要事实');
    if (this.summaryPoints.events) points.push('- 已发生事件');
    if (this.summaryPoints.userPreferences) points.push('- 用户偏好');
    if (this.summaryPoints.commitments) points.push('- 承诺和目标');
    if (this.summaryPoints.openIssues) points.push('- 未解决事项');
    if (this.summaryPoints.characterState) points.push('- 角色当前情绪与状态');

    const systemPrompt: string =
      '你是对话记忆助手。任务:综合旧摘要和新增对话,生成新的对话记忆摘要。\n\n' +
      '需要保留:\n' + points.join('\n') + '\n\n' +
      '避免保存:\n' +
      '- 重复寒暄\n' +
      '- 无关措辞\n' +
      '- 大量原文复述\n' +
      '- 模型推理过程\n\n' +
      '输出要求:简洁的中文段落,不超过 500 字,只输出摘要本身。';

    const userContent: string =
      (oldSummary.length > 0 ? '【旧摘要】\n' + oldSummary + '\n\n' : '') +
      '【新增对话】\n' + this.formatMessages(newMessages) + '\n\n' +
      '请输出更新后的记忆摘要:';

    return [
      {
        id: 'memory-summary-system',
        role: ChatRole.System,
        content: systemPrompt,
        createdAt: 0
      },
      {
        id: 'memory-summary-user',
        role: ChatRole.User,
        content: userContent,
        createdAt: 0
      }
    ];
  }

  /**
   * 格式化消息列表为可读文本。
   */
  private formatMessages(messages: ChatMessage[]): string {
    const parts: string[] = [];
    for (let i = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      const role: string = msg.role === ChatRole.User ? '用户' :
        msg.role === ChatRole.Assistant ? '角色' : '系统';
      parts.push(role + ': ' + msg.content);
    }
    return parts.join('\n');
  }

  // ===== 过期标记 =====

  /**
   * 使 Branch 中 endPosition >= thresholdPosition 的 Memory 失效(删除)。
   * 用于编辑消息或切换 Swipe 后。
   * 失效后的 Memory 不再注入 Prompt,后续总结会从最近有效检查点重新生成。
   */
  async invalidateFromPosition(branchId: string, thresholdPosition: number): Promise<void> {
    try {
      await this.memoryPersistence.invalidateFromPosition(branchId, thresholdPosition);
    } catch (e) {
      Logger.warn(LOG_TAG, 'invalidateFromPosition failed: ' + String(e));
    }
  }

  /**
   * 清除当前 Branch 自产的记忆(继承祖先的不删)。
   */
  async clearOwnedByBranch(branchId: string): Promise<void> {
    try {
      await this.memoryPersistence.clearOwnedByBranch(branchId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'clearOwnedByBranch failed: ' + String(e));
    }
  }

  // ===== 手动操作 =====

  /**
   * 编辑 Memory 摘要文本(不修改原始消息)。
   */
  async editSummary(memoryId: string, newSummary: string): Promise<void> {
    await this.memoryPersistence.updateSummary(memoryId, newSummary);
  }

  /**
   * 启用/禁用 Memory。
   */
  async setEnabled(memoryId: string, enabled: boolean): Promise<void> {
    await this.memoryPersistence.setEnabled(memoryId, enabled);
  }

  /**
   * 获取 Branch 的全部 Memory(用于 UI 展示)。
   */
  async listByBranch(branchId: string): Promise<ChatMemory[]> {
    return await this.memoryPersistence.listByBranch(branchId);
  }

  /**
   * 按 ID 查询 Memory。
   */
  async getById(memoryId: string): Promise<ChatMemory | null> {
    return await this.memoryPersistence.getById(memoryId);
  }
}
