/**
 * RecentMessageSelector 对话历史选择服务(缓存友好版)
 *
 * 职责:
 * - 从头(记忆覆盖边界之后)选择原始消息,作为 PromptBuilder 的 Conversation 段
 * - 与长期记忆去重:已被记忆覆盖(position <= memoryEndPosition)的旧消息不注入原文
 * - 不再使用"最近 N 条滑动窗口"(每轮窗口左移会破坏 DeepSeek 前缀缓存命中)
 * - 保留完整 User+Assistant 轮次,不拆开
 * - 仅在超出 Token 预算时从前往后按完整轮次裁剪(裁剪是低频事件,命中率可快速恢复)
 *
 * 缓存友好性说明(T-7.x):
 * - 每轮请求的对话段 = [记忆覆盖边界+1 .. 当前末尾],只随新消息向后追加
 * - 结合「记忆摘要等动态内容移到对话之后」的重排,对话段构成稳定前缀,
 *   符合 DeepSeek 自动前缀缓存(prefix cache)的完整匹配命中规则
 *
 * 选择规则:
 * 1. 起始索引 = memoryEndPosition + 1(无记忆则 0),回退到 User 边界保证完整轮次
 * 2. 保留最后一条消息与最近若干完整 User+Assistant 轮次(MIN_COMPLETE_TURNS)
 * 3. 超过 Token 预算时从前往后按完整轮次丢弃(每次丢弃会引发一次缓存重置,低频可接受)
 *
 * 设计约束:
 * - 无状态、纯函数式
 * - 不修改输入数组
 * - 不访问数据库 / 网络 / ArkUI
 * - 不记录消息正文到日志
 */

import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { estimateMessagesTokens } from './TokenCounter';
import {
  ContextHistorySelection,
  createEmptySelection
} from '../models/ContextHistorySelection';
import {
  MIN_COMPLETE_TURNS
} from '../models/ContextBudgetConfig';

const LOG_TAG: string = 'RecentMsgSelector';

/**
 * 最近消息选择选项。
 */
export interface RecentMessageSelectionOptions {
  /** 目标保留条数(诊断用,新实现不再限制条数) */
  readonly targetCount?: number;
  /** 最少完整轮次(默认 2) */
  readonly minCompleteTurns?: number;
  /** 可用 Token 预算(用于历史段) */
  readonly availableTokens: number;
  /** 有效记忆覆盖的结束 position(-1 表示无记忆) */
  readonly memoryEndPosition: number;
}

/**
 * 对话历史选择器(缓存友好版)。
 * 无状态,不依赖外部实例。
 */
export class RecentMessageSelector {
  /**
   * 从头选择原始消息(缓存友好版)。
   *
   * @param messages 当前 Branch 的全部消息(按 position ASC)
   * @param options 选择选项
   * @returns 选择结果
   */
  select(
    messages: ChatMessage[],
    options: RecentMessageSelectionOptions
  ): ContextHistorySelection {
    if (messages.length === 0) {
      return createEmptySelection();
    }

    const minTurns: number = options.minCompleteTurns !== undefined
      ? options.minCompleteTurns : MIN_COMPLETE_TURNS;
    const availableTokens: number = options.availableTokens > 0
      ? options.availableTokens : 0;
    const memoryEndPos: number = options.memoryEndPosition;

    const lastIndex: number = messages.length - 1;

    // Step 1: 起始索引 = 记忆覆盖边界 + 1(无记忆则 0)
    // 已覆盖的前段由尾部记忆摘要替代,不再注入原文
    let startIndex: number = memoryEndPos >= 0 ? memoryEndPos + 1 : 0;
    if (startIndex > lastIndex) {
      startIndex = 0;
    }
    // 回退到 User 边界,保证完整轮次(记忆覆盖完整轮次时天然是 User,此为兜底)
    while (startIndex > 0 && messages[startIndex].role !== ChatRole.User) {
      startIndex--;
    }

    // Step 2: 最少保留范围(最近 minTurns 完整轮次 + 最后一条消息)
    const minKeepIndex: number = this.findMinKeepIndexFromEnd(messages, minTurns);

    // Step 3: 预算裁剪 —— 仅当真实预算提供且超出时,从前往后按完整轮次丢弃
    // (当前 ChatService 传 MAX_SAFE_INTEGER,实际预算裁剪由 HistoryTrimmer 完成;
    //  保留此逻辑用于未来传真实预算时对话段预先瘦身)
    let effectiveStart: number = startIndex;
    if (availableTokens > 0) {
      const fullTokens: number = estimateMessagesTokens(messages.slice(startIndex));
      if (fullTokens > availableTokens && startIndex < minKeepIndex) {
        effectiveStart = this.dropFrontTurnsForBudget(
          messages, startIndex, minKeepIndex, availableTokens, fullTokens
        );
      }
    }

    // Step 4: 输出选中消息(ASC)
    const recentMessages: ChatMessage[] = [];
    for (let i = effectiveStart; i <= lastIndex; i++) {
      recentMessages.push(messages[i]);
    }

    const estimatedTokens: number = estimateMessagesTokens(recentMessages);
    // 省略数 = 起始索引(记忆覆盖去重 + 预算裁剪)
    const omittedCount: number = effectiveStart;

    return {
      recentMessages: recentMessages,
      summarizedRangeEndPosition: memoryEndPos,
      omittedMessageCount: omittedCount,
      estimatedTokens: estimatedTokens,
      targetCount: messages.length,
      selectedCount: recentMessages.length
    };
  }

  /**
   * 预算超出时,从前往后按完整 User+Assistant 轮次丢弃,直到剩余不超预算。
   * 返回新的起始索引(不再继续丢弃的最早索引)。
   *
   * @param messages 全部消息
   * @param startIndex 当前起始索引(含)
   * @param minKeepIndex 最少保留边界(含)
   * @param availableTokens 可用 Token
   * @param fullTokens 当前选中段的总 Token
   * @returns 裁剪后的起始索引
   */
  private dropFrontTurnsForBudget(
    messages: ChatMessage[],
    startIndex: number,
    minKeepIndex: number,
    availableTokens: number,
    fullTokens: number
  ): number {
    let effectiveStart: number = startIndex;
    let droppedTokens: number = 0;
    let i: number = startIndex;
    while (i < minKeepIndex && droppedTokens < fullTokens) {
      // 只在 User 轮次边界丢弃
      if (messages[i].role !== ChatRole.User) {
        i++;
        continue;
      }
      // 找到本轮的结束索引(下一个 User 的前一条,或最后一条)
      let turnEnd: number = i;
      for (let j = i + 1; j < messages.length; j++) {
        if (messages[j].role === ChatRole.User) {
          break;
        }
        turnEnd = j;
      }
      // 本轮跨过最少保留边界:不再丢弃
      if (turnEnd >= minKeepIndex) {
        break;
      }
      const turnTokens: number = estimateMessagesTokens(messages.slice(i, turnEnd + 1));
      droppedTokens += turnTokens;
      effectiveStart = turnEnd + 1;
      if (fullTokens - droppedTokens <= availableTokens) {
        break;
      }
      i = turnEnd + 1;
    }
    return effectiveStart;
  }

  /**
   * 从末尾向前找到最少必须保留的起始索引。
   * 保证 [result, lastIndex] 范围内包含至少 minTurns 个完整 User+Assistant 轮次。
   *
   * 完整轮次定义:一条 User 紧跟一条 Assistant。
   * 若消息末尾是 User(待生成),该 User 也必须保留,但其前的 Assistant+User 对计入轮次。
   *
   * @return 起始索引(含),若不足 minTurns 则返回 0
   */
  private findMinKeepIndexFromEnd(
    messages: ChatMessage[],
    minTurns: number
  ): number {
    const lastIndex: number = messages.length - 1;
    let turnsFound: number = 0;
    let i: number = lastIndex;

    // 跳过末尾的 User(待生成场景),从其前一条开始找轮次
    if (messages[lastIndex].role === ChatRole.User) {
      i = lastIndex - 1;
    }

    while (i >= 1 && turnsFound < minTurns) {
      // 检查 [i-1, i] 是否构成 User + Assistant 对
      if (messages[i].role === ChatRole.Assistant && messages[i - 1].role === ChatRole.User) {
        turnsFound++;
        i -= 2;
        continue;
      }
      i--;
    }

    // minKeepFromEnd = 找到的最小索引(或 0)
    // 必须包含末尾 User(如果有)
    const minIndex: number = Math.max(0, i + 1);
    // 确保包含末尾消息
    return Math.min(minIndex, lastIndex);
  }
}
