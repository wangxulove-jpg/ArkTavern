/**
 * GroupMessageRenderState 多人消息渲染状态(G-RUNTIME-1C-FIX)
 *
 * 目的:
 * - 解决 ForEach 在固定 key(messageId)下复用 GroupMessageBubble 时,
 *   普通参数不触发重渲染导致 Streaming 正文不更新、Completed 最终内容不显示的根因。
 * - 与单聊 ChatMessageRenderState 采用完全相同的 @Observed + @ObjectLink 模式。
 *
 * 设计:
 * - @Observed 装饰,字段赋值时触发 @ObjectLink 响应式更新
 * - GroupMessageBubble 通过 @ObjectLink renderState 接收,
 *   同一 messageId 始终对应同一个 RenderState 实例,
 *   ArkUI 字段赋值即可触发气泡重建,无需销毁组件实例
 *
 * 关键约束:
 * - messageId 在创建后不可变,用于 ForEach key
 * - 所有 UI 字段均为可观察字段,业务层 GroupMessageUiModel 变更时通过 applyMessage 同步更新
 * - 不存储敏感数据
 */

import { ChatMessageStatus } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { GroupMessageUiModel } from './GroupChatUiModels';

@Observed
export class GroupMessageRenderState {
  /** 对应的消息 ID(创建后不变,ForEach key) */
  readonly messageId: string;
  /** 消息角色 */
  role: ChatRole;
  /** 当前消息正文(随流式持续增长) */
  content: string;
  /** 是否正在流式生成中 */
  isStreaming: boolean;
  /** 消息状态 */
  status: ChatMessageStatus;
  /** 发言角色 ID(用户消息为空) */
  senderCharacterId: string;
  /** 发言者显示名称 */
  senderName: string;
  /** 发言者头像 URI */
  senderAvatarUri: string;
  /** 角色是否真实存在 */
  characterExists: boolean;
  /** 生成批次 ID */
  generationBatchId: string;
  /** 创建时间(毫秒) */
  createdAt: number;
  /** 更新时间(毫秒) */
  updatedAt: number;
  /** G-CONTROL-1: 单角色回复目标角色 ID(用户消息,全员回复为空) */
  replyTargetCharacterId: string;
  /** G-CONTROL-1: 目标角色显示名称(用户消息下方标签,全员回复为空) */
  replyTargetName: string;

  constructor(msg: GroupMessageUiModel) {
    this.messageId = msg.id;
    this.role = msg.role;
    this.content = msg.content;
    this.status = msg.status;
    this.isStreaming = msg.status === ChatMessageStatus.Streaming;
    this.senderCharacterId = msg.senderCharacterId !== undefined ? msg.senderCharacterId : '';
    this.senderName = msg.senderName;
    this.senderAvatarUri = msg.senderAvatarUri !== undefined ? msg.senderAvatarUri : '';
    this.characterExists = msg.characterExists;
    this.generationBatchId = msg.generationBatchId !== undefined ? msg.generationBatchId : '';
    this.createdAt = msg.createdAt;
    this.updatedAt = msg.updatedAt;
    this.replyTargetCharacterId = msg.replyTargetCharacterId !== undefined
      ? msg.replyTargetCharacterId : '';
    this.replyTargetName = msg.replyTargetName !== undefined ? msg.replyTargetName : '';
  }

  /**
   * 同步最新 GroupMessageUiModel 到 RenderState(原地修改 @Observed 字段)。
   * 业务层不可变更新后,本方法把最新值拷贝到 RenderState 的可观察字段,
   * 触发 @ObjectLink 响应式刷新。
   */
  applyMessage(msg: GroupMessageUiModel): void {
    this.role = msg.role;
    this.content = msg.content;
    this.status = msg.status;
    this.isStreaming = msg.status === ChatMessageStatus.Streaming;
    this.senderCharacterId = msg.senderCharacterId !== undefined ? msg.senderCharacterId : '';
    this.senderName = msg.senderName;
    this.senderAvatarUri = msg.senderAvatarUri !== undefined ? msg.senderAvatarUri : '';
    this.characterExists = msg.characterExists;
    this.generationBatchId = msg.generationBatchId !== undefined ? msg.generationBatchId : '';
    this.createdAt = msg.createdAt;
    this.updatedAt = msg.updatedAt;
    this.replyTargetCharacterId = msg.replyTargetCharacterId !== undefined
      ? msg.replyTargetCharacterId : '';
    this.replyTargetName = msg.replyTargetName !== undefined ? msg.replyTargetName : '';
  }
}
