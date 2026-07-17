/**
 * HistoryTrimmer 历史裁剪服务
 *
 * 当 PromptBuilder 生成的最终请求消息超过输入 Token 预算时,
 * 按确定性规则裁剪最旧的可裁剪聊天历史,使请求尽可能回到预算范围内。
 *
 * 职责:
 * - 接收最终请求消息 + 可用 Token 预算,返回裁剪后的消息
 * - 保护 System 消息、Character Prompt、firstMessage、当前 User 消息
 * - 按完整 User/Assistant 轮次从旧到新删除
 * - 不修改输入数组和原始消息对象
 * - 不修改消息正文,不截断
 * - 无状态、不访问 ArkUI / Provider / ChatService
 *
 * 非职责(后续阶段):
 * - 摘要压缩
 * - 消息内容截断
 * - 单条消息按字符截断
 * - 向量检索 / 长期记忆
 * - Preset / UI Token 展示
 *
 * 裁剪原则:
 * - 不超预算:返回与输入等长的新数组,removedMessageCount=0
 * - 超预算:从旧到新扫描,优先按完整 User/Assistant 轮次删除
 * - 极端超预算:删除所有可裁剪历史后仍超预算,exceedsBudgetAfterTrim=true
 * - 受保护消息一律不删
 *
 * 终止条件:
 * - 每轮至少删除一个可裁剪单元
 * - 最多执行可裁剪单元数量次循环
 * - 立即停止条件:达到预算 / 删无可删 / 连续受保护连续段
 */

import { ChatMessage } from '../models/ChatMessage';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatRole } from '../models/ChatRole';
import { TokenCounter, estimateMessagesTokens } from './TokenCounter';
import { HistoryTrimResult, createHistoryTrimResult } from '../models/HistoryTrimResult';

/** 单次裁剪最多循环次数(避免 O(n²) 失控) */
const MAX_TRIM_ITERATIONS: number = 256;

/**
 * 裁剪选项。
 */
export interface HistoryTrimOptions {
  /** 可用输入 Token 数 */
  readonly availableInputTokens: number;
  /** 显式受保护消息 ID 列表(可选) */
  readonly protectedMessageIds?: string[];
}

/**
 * 一个可裁剪单元(用于轮次删除)。
 */
interface TrimUnit {
  /** 单元在 messages 数组中的索引集合(连续段或单条) */
  readonly indices: number[];
  /** 估算 Token 数(单元内所有消息之和) */
  readonly tokens: number;
}

/**
 * 历史裁剪服务。
 *
 * 无状态,只依赖注入的 TokenCounter 做估算。
 */
export class HistoryTrimmer {
  private readonly tokenCounter: TokenCounter;

  constructor(tokenCounter: TokenCounter) {
    this.tokenCounter = tokenCounter;
  }

  /**
   * 裁剪消息列表直到 Token 数 <= availableInputTokens。
   *
   * @param messages PromptBuilder 输出的最终请求消息(已含 source 标签)
   * @param options 裁剪选项
   * @returns 裁剪结果
   */
  trim(messages: ChatMessage[], options: HistoryTrimOptions): HistoryTrimResult {
    const available: number = options.availableInputTokens > 0 ? options.availableInputTokens : 0;
    const protectedIds: Set<string> = new Set();
    if (options.protectedMessageIds !== undefined && options.protectedMessageIds !== null) {
      for (let i = 0; i < options.protectedMessageIds.length; i++) {
        protectedIds.add(options.protectedMessageIds[i]);
      }
    }

    const originalTokens: number = this.countTokensSafe(messages);
    const exceedsBefore: boolean = originalTokens > available;

    if (!exceedsBefore || messages.length === 0) {
      // 不超预算:返回新数组(内容相同)
      const copy: ChatMessage[] = messages.slice();
      return createHistoryTrimResult(
        copy,
        originalTokens,
        originalTokens,
        [],
        false,
        false
      );
    }

    // 标记可裁剪索引
    const isTrimmable: boolean[] = new Array(messages.length).fill(false);
    const lastIndex: number = messages.length - 1;
    for (let i = 0; i < messages.length; i++) {
      const m: ChatMessage = messages[i];
      // 最后一条消息无论 role 都受保护(不删除当前正在发送的内容)
      if (i === lastIndex) {
        isTrimmable[i] = false;
        continue;
      }
      // 显式 protected ID 受保护
      if (protectedIds.has(m.id)) {
        isTrimmable[i] = false;
        continue;
      }
      // source 受保护的非 Conversation 全部不裁剪
      if (m.source !== undefined && m.source !== ChatMessageSource.Conversation) {
        isTrimmable[i] = false;
        continue;
      }
      // System 消息一律不裁剪
      if (m.role === ChatRole.System) {
        isTrimmable[i] = false;
        continue;
      }
      // firstMessage(CharacterFirstMessage)已在 source 分支中保护
      // 可裁剪只能是 Conversation 角色 + User/Assistant
      isTrimmable[i] = true;
    }

    // 构建可裁剪轮次单元(从旧到新)
    const units: TrimUnit[] = this.buildTrimUnits(messages, isTrimmable);
    if (units.length === 0) {
      // 全部受保护:返回原列表
      const copy: ChatMessage[] = messages.slice();
      return createHistoryTrimResult(
        copy,
        originalTokens,
        originalTokens,
        [],
        true,
        true
      );
    }

    // 决定要删除的单元(从最旧开始)
    const removedSet: Set<number> = new Set<number>();
    const removedIds: string[] = [];
    let currentTokens: number = originalTokens;
    let iterations: number = 0;

    for (let u = 0; u < units.length; u++) {
      if (currentTokens <= available) {
        break;
      }
      iterations++;
      if (iterations > MAX_TRIM_ITERATIONS) {
        break;
      }
      const unit: TrimUnit = units[u];
      for (let k = 0; k < unit.indices.length; k++) {
        const idx: number = unit.indices[k];
        removedSet.add(idx);
        removedIds.push(messages[idx].id);
      }
      currentTokens = currentTokens - unit.tokens;
      // 防止 currentTokens 异常下溢
      if (currentTokens < 0) {
        currentTokens = 0;
      }
    }

    const exceedsAfter: boolean = currentTokens > available;

    // 构造裁剪后数组(按原顺序)
    const result: ChatMessage[] = [];
    for (let i = 0; i < messages.length; i++) {
      if (!removedSet.has(i)) {
        result.push(messages[i]);
      }
    }

    return createHistoryTrimResult(
      result,
      originalTokens,
      currentTokens,
      removedIds,
      true,
      exceedsAfter
    );
  }

  /**
   * 从旧到新构建可裁剪单元。
   * 优先按"User + 紧邻 Assistant"完整轮次;
   * 不可配对的孤立消息作为单条单元。
   */
  private buildTrimUnits(messages: ChatMessage[], isTrimmable: boolean[]): TrimUnit[] {
    const units: TrimUnit[] = [];
    let i: number = 0;
    const n: number = messages.length;
    while (i < n) {
      if (!isTrimmable[i]) {
        i++;
        continue;
      }
      // 找到一个可裁剪段
      const start: number = i;
      // 先判断本段第一个消息的角色
      const first: ChatMessage = messages[i];
      if (first.role === ChatRole.User) {
        // 寻找紧邻的 Assistant 配对(只有紧邻才算同一轮次,跳过不可裁剪的除外)
        let j: number = i + 1;
        if (j < n && isTrimmable[j] && messages[j].role === ChatRole.Assistant) {
          j++;
        }
        // [start, j) 是一个 User(+ Assistant) 单元
        units.push(this.makeUnit(messages, isTrimmable, start, j));
        i = j;
      } else if (first.role === ChatRole.Assistant) {
        // 孤立 Assistant(没有紧邻 User)作为单条单元
        units.push(this.makeUnit(messages, isTrimmable, start, start + 1));
        i = start + 1;
      } else {
        // 其他角色(User/Assistant 之外):保守作为单条单元
        units.push(this.makeUnit(messages, isTrimmable, start, start + 1));
        i = start + 1;
      }
    }
    return units;
  }

  /**
   * 构造单元。
   * 内部去除 [start, end) 内不可裁剪的项,只保留可裁剪索引。
   */
  private makeUnit(messages: ChatMessage[], isTrimmable: boolean[], start: number, end: number): TrimUnit {
    const indices: number[] = [];
    for (let k = start; k < end; k++) {
      if (isTrimmable[k]) {
        indices.push(k);
      }
    }
    if (indices.length === 0) {
      return { indices: [], tokens: 0 };
    }
    const slice: ChatMessage[] = indices.map((i: number): ChatMessage => messages[i]);
    const tokens: number = estimateMessagesTokens(slice);
    return { indices: indices, tokens: tokens };
  }

  /**
   * 安全计算消息列表 Token 数(捕获异常时返回估算值)。
   */
  private countTokensSafe(messages: ChatMessage[]): number {
    try {
      return this.tokenCounter.estimateMessages(messages);
    } catch (e) {
      return estimateMessagesTokens(messages);
    }
  }
}
