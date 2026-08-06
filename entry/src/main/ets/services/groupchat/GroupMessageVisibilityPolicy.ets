/**
 * GroupMessageVisibilityPolicy 多人聊天历史消息可见性策略(G-CONTEXT-VISIBILITY-1)
 *
 * 职责:
 * - 为单个 viewerCharacterId 过滤群聊历史消息,输出可见性决策
 * - 纯逻辑,不依赖 RDB / ArkUI / Provider / Runtime
 * - 每条消息独立决策,附带明确原因
 * - 安全失败:viewer 缺失时抛领域错误,不回退完整历史
 *
 * 规则总览:
 * - System 角色:始终排除
 * - status 非 Completed(Failed/Cancelled/Streaming):始终排除
 * - 空正文(trim 后为空):始终排除
 * - Public Completed:对所有 viewer 可见(不依赖 participantIds/witnessIds/replyTargetCharacterIds)
 * - Private Completed:recipientCharacterIds 含 viewer 或 senderCharacterId == viewer 时可见
 * - 旁白(senderType='narrator', visibility='public', status=Completed):对所有角色可见
 * - 未支持可见性(narrator visibility 且非 public):排除
 *
 * 隔离保证:
 * - filterVisible 返回新数组,不修改输入
 * - 每个 viewer 独立调用,结果互不复用
 * - 消息对象为 readonly,可安全共享不可变引用
 *
 * 日志安全:
 * - 不打印完整正文 / Private 正文 / 角色名称 / 完整 ID / recipient 列表全文
 * - 只允许记录输入/包含/排除计数与 reason 计数
 */

import { ChatMessage, ChatMessageStatus, MessageVisibility } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';

/** 可见性决策原因枚举 */
export enum GroupMessageVisibilityReason {
  /** 公开消息,可见 */
  INCLUDED_PUBLIC = 'included_public',
  /** Private 消息,viewer 是接收者,可见 */
  INCLUDED_PRIVATE_RECIPIENT = 'included_private_recipient',
  /** Private 消息,viewer 是发送者,可见 */
  INCLUDED_PRIVATE_SENDER = 'included_private_sender',
  /** 公开旁白消息,可见 */
  INCLUDED_PUBLIC_NARRATION = 'included_public_narration',

  /** 状态 Failed,排除 */
  EXCLUDED_STATUS_FAILED = 'excluded_status_failed',
  /** 状态 Cancelled,排除 */
  EXCLUDED_STATUS_CANCELLED = 'excluded_status_cancelled',
  /** 状态 Streaming,排除 */
  EXCLUDED_STATUS_STREAMING = 'excluded_status_streaming',
  /** 空正文,排除 */
  EXCLUDED_EMPTY_CONTENT = 'excluded_empty_content',
  /** Private 消息且 viewer 不是接收者也不是发送者,排除 */
  EXCLUDED_PRIVATE_NOT_RECIPIENT = 'excluded_private_not_recipient',
  /** System 角色消息,排除 */
  EXCLUDED_SYSTEM = 'excluded_system',
  /** 未支持的可见性(narrator 非 public),排除 */
  EXCLUDED_UNSUPPORTED_VISIBILITY = 'excluded_unsupported_visibility',
  /** viewer 缺失,排除 */
  EXCLUDED_INVALID_VIEWER = 'excluded_invalid_viewer'
}

/** 单条消息的可见性决策 */
export interface GroupMessageVisibilityDecision {
  readonly visible: boolean;
  readonly reason: GroupMessageVisibilityReason;
}

/** 单条消息的决策记录(含消息 ID,供检查器关联) */
export interface GroupMessageVisibilityDecisionRecord {
  readonly messageId: string;
  readonly visible: boolean;
  readonly reason: GroupMessageVisibilityReason;
}

/** 过滤结果 */
export interface GroupVisibleHistoryResult {
  /** 对当前 viewer 可见的消息(新数组,顺序保持输入顺序) */
  readonly includedMessages: ChatMessage[];
  /** 每条输入消息的决策记录(与输入顺序一致) */
  readonly decisions: GroupMessageVisibilityDecisionRecord[];
  /** 包含数量 */
  readonly includedCount: number;
  /** 排除数量 */
  readonly excludedCount: number;
}

/**
 * 群聊消息可见性策略。无状态,纯函数。
 */
export class GroupMessageVisibilityPolicy {
  /**
   * 对单条消息评估可见性。
   *
   * 判定顺序:
   * 1. viewer 非空(调用前已校验,此处防御)
   * 2. System 角色排除
   * 3. 状态排除(Failed / Cancelled / Streaming)
   * 4. 空正文排除
   * 5. visibility 分支(public / private / narrator / undefined)
   *
   * @param message 待评估消息
   * @param viewerCharacterId 当前查看角色 ID(非空)
   * @returns 可见性决策
   */
  static evaluate(
    message: ChatMessage,
    viewerCharacterId: string
  ): GroupMessageVisibilityDecision {
    // 1. viewer 校验(防御;正常流程由 filterVisible 前置校验)
    if (viewerCharacterId.trim().length === 0) {
      return {
        visible: false,
        reason: GroupMessageVisibilityReason.EXCLUDED_INVALID_VIEWER
      };
    }

    // 2. System 角色排除
    if (message.role === ChatRole.System) {
      return {
        visible: false,
        reason: GroupMessageVisibilityReason.EXCLUDED_SYSTEM
      };
    }

    // 3. 状态过滤
    const status: ChatMessageStatus | undefined = message.status;
    if (status === ChatMessageStatus.Failed) {
      return {
        visible: false,
        reason: GroupMessageVisibilityReason.EXCLUDED_STATUS_FAILED
      };
    }
    if (status === ChatMessageStatus.Cancelled) {
      return {
        visible: false,
        reason: GroupMessageVisibilityReason.EXCLUDED_STATUS_CANCELLED
      };
    }
    if (status === ChatMessageStatus.Streaming) {
      return {
        visible: false,
        reason: GroupMessageVisibilityReason.EXCLUDED_STATUS_STREAMING
      };
    }
    // status undefined 视为历史兼容消息,按可见性规则继续判断

    // 4. 空正文排除
    if (message.content.trim().length === 0) {
      return {
        visible: false,
        reason: GroupMessageVisibilityReason.EXCLUDED_EMPTY_CONTENT
      };
    }

    // 5. visibility 分支
    const visibility: MessageVisibility | undefined = message.visibility;

    // 旁白消息:公开旁白对所有人可见
    if (message.senderType === 'narrator') {
      if (visibility === undefined || visibility === 'public') {
        return {
          visible: true,
          reason: GroupMessageVisibilityReason.INCLUDED_PUBLIC_NARRATION
        };
      }
      // 非 Public 旁白:按实际 visibility 规则判断
      if (visibility === 'private') {
        return GroupMessageVisibilityPolicy.evaluatePrivate(message, viewerCharacterId);
      }
      // visibility === 'narrator' 或其他:未支持
      return {
        visible: false,
        reason: GroupMessageVisibilityReason.EXCLUDED_UNSUPPORTED_VISIBILITY
      };
    }

    if (visibility === undefined || visibility === 'public') {
      // 公开消息:对所有在场角色可见,不依赖 participantIds / witnessIds / replyTargetCharacterIds
      return {
        visible: true,
        reason: GroupMessageVisibilityReason.INCLUDED_PUBLIC
      };
    }

    if (visibility === 'private') {
      return GroupMessageVisibilityPolicy.evaluatePrivate(message, viewerCharacterId);
    }

    // visibility === 'narrator':用户旁白或其他未支持
    return {
      visible: false,
      reason: GroupMessageVisibilityReason.EXCLUDED_UNSUPPORTED_VISIBILITY
    };
  }

  /**
   * Private 消息可见性。
   *
   * 可见条件(满足其一):
   * - recipientCharacterIds 包含 viewerCharacterId
   * - senderCharacterId == viewerCharacterId
   *
   * 不使用:replyTargetCharacterIds / participantIds / 当前回复选择。
   */
  private static evaluatePrivate(
    message: ChatMessage,
    viewerCharacterId: string
  ): GroupMessageVisibilityDecision {
    const recipients: string[] | undefined = message.recipientCharacterIds;
    if (recipients !== undefined) {
      for (let i = 0; i < recipients.length; i++) {
        if (recipients[i] === viewerCharacterId) {
          return {
            visible: true,
            reason: GroupMessageVisibilityReason.INCLUDED_PRIVATE_RECIPIENT
          };
        }
      }
    }

    const sender: string | undefined = message.senderCharacterId;
    if (sender !== undefined && sender === viewerCharacterId) {
      return {
        visible: true,
        reason: GroupMessageVisibilityReason.INCLUDED_PRIVATE_SENDER
      };
    }

    return {
      visible: false,
      reason: GroupMessageVisibilityReason.EXCLUDED_PRIVATE_NOT_RECIPIENT
    };
  }

  /**
   * 过滤消息列表,返回当前 viewer 可见的消息与决策记录。
   *
   * 安全失败:
   * - viewerCharacterId 为空时抛领域错误,不得返回完整历史
   *
   * 隔离保证:
   * - 返回新数组,不修改输入数组
   * - 不修改消息对象字段
   *
   * @param messages 完整历史消息(来自数据库,顺序 ASC)
   * @param viewerCharacterId 当前查看角色 ID(非空)
   * @returns 过滤结果(新数组)
   */
  static filterVisible(
    messages: ChatMessage[],
    viewerCharacterId: string
  ): GroupVisibleHistoryResult {
    if (viewerCharacterId.trim().length === 0) {
      throw new Error('GroupMessageVisibilityPolicy: viewerCharacterId empty');
    }

    const included: ChatMessage[] = [];
    const decisions: GroupMessageVisibilityDecisionRecord[] = [];
    for (let i = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      const decision: GroupMessageVisibilityDecision =
        GroupMessageVisibilityPolicy.evaluate(msg, viewerCharacterId);
      decisions.push({
        messageId: msg.id,
        visible: decision.visible,
        reason: decision.reason
      });
      if (decision.visible) {
        included.push(msg);
      }
    }

    return {
      includedMessages: included,
      decisions: decisions,
      includedCount: included.length,
      excludedCount: messages.length - included.length
    };
  }
}
