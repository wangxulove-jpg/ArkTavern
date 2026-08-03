/**
 * GroupRoundCoordinator 多人聊天轮次协调器(G-RUNTIME-1A 骨架)
 *
 * 职责:
 * - 建立本轮成员快照(GroupRoundPlan)
 * - 管理 operationId,使旧轮次失效
 * - 维护活动轮次上下文(ActiveGroupRoundContext)
 * - 提供校验接口供下一阶段 Provider 回调使用
 *
 * 本阶段状态链:
 *   Idle → Planning → Ready
 *
 * 不实现:
 * - Generating(下一阶段接入 Provider)
 * - 真实 AI 消息创建
 * - 流式输出
 * - 停止 / 重试 / 跳过
 *
 * 设计:
 * - 不依赖 ModelService / Provider / SSE
 * - 不依赖 Page / ArkUI 状态
 * - 不复用单聊 ActiveGenerationContext,避免互相干扰
 * - 同一时间最多一个活动轮次
 *
 * 本轮快照规则:
 * - 读取当前群聊全部 Participant
 * - 过滤 isEnabled = true
 * - 排除已删除角色(通过 CharacterRepository 校验)
 * - 按 speakerOrder ASC
 * - speakerIndex 从 0 连续
 * - 可用角色 < 2 时拒绝建立计划
 *
 * operationId 失效规则:
 * - 创建新轮次:旧 operationId 失效
 * - cancelRound:当前 operationId 失效
 * - clearCompletedRound:当前 operationId 失效
 * - 页面释放 / 切换 Chat:应主动调用 cancelRound
 *
 * 日志规则:
 * - 不打印完整 Chat ID / Character ID / Message ID
 * - 只打印成员数量、状态枚举、操作类别
 */

import { Chat } from '../../models/Chat';
import { ChatParticipant } from '../../models/ChatParticipant';
import { Character } from '../../models/Character';
import { ConversationMode } from '../../models/ConversationMode';
import { nowMillis } from '../../utils/Time';
import { Logger } from '../../utils/Logger';
import { GroupConversationPersistenceService } from './GroupConversationPersistenceService';
import { CharacterService } from '../CharacterService';
import {
  GroupRoundState,
  GroupRoundSpeaker,
  GroupRoundPlan,
  ActiveGroupRoundContext,
  GroupRoundPlanError,
  GroupRoundPlanErrorKind
} from './GroupRoundTypes';

const LOG_TAG: string = 'GroupRoundCoord';

/**
 * 最少可用发言者数(与 MIN_ENABLED_COUNT 一致)。
 * 排除已删除角色后不足此数则拒绝建立计划。
 */
const MIN_AVAILABLE_SPEAKERS: number = 2;

export class GroupRoundCoordinator {
  private readonly groupService: GroupConversationPersistenceService;
  private readonly characterService: CharacterService;

  /** 当前状态 */
  private state: GroupRoundState = GroupRoundState.Idle;
  /** 自增 operationId,每次新建轮次 +1 */
  private generationOperationId: number = 0;
  /** 活动轮次上下文(Idle/Ready 时可能为 null) */
  private activeRound: ActiveGroupRoundContext | null = null;
  /** 最后一次建立的计划(Ready 后保留,供调试;不阻止新发送) */
  private lastPlan: GroupRoundPlan | null = null;

  constructor(
    groupService: GroupConversationPersistenceService,
    characterService: CharacterService
  ) {
    this.groupService = groupService;
    this.characterService = characterService;
  }

  /**
   * 建立本轮计划。
   *
   * 步骤:
   * 1. 校验 Chat 存在且为 Group 模式
   * 2. 校验 userMessageId 非空
   * 3. 读取当前参与者
   * 4. 过滤 isEnabled=true
   * 5. 排除已删除角色
   * 6. 按 speakerOrder ASC 排序
   * 7. 校验可用发言者 >= 2
   * 8. 生成 operationId 与 GroupRoundPlan
   * 9. 状态转为 Ready
   *
   * 本阶段不进入 Generating。
   * 计划建立后立即清理活动上下文,允许用户继续发送下一条消息。
   *
   * @param chatId 群聊 ID
   * @param userMessageId 触发本轮的用户消息 ID
   * @param generationBatchId 本轮 ID(等同 messages.generation_batch_id)
   */
  async prepareRound(
    chatId: string,
    userMessageId: string,
    generationBatchId: string
  ): Promise<GroupRoundPlan> {
    if (chatId === '') {
      throw new GroupRoundPlanError(
        GroupRoundPlanErrorKind.ChatNotFound, 'chatId empty'
      );
    }
    if (userMessageId === '') {
      throw new GroupRoundPlanError(
        GroupRoundPlanErrorKind.UserMessageNotFound, 'userMessageId empty'
      );
    }
    if (generationBatchId === '') {
      throw new GroupRoundPlanError(
        GroupRoundPlanErrorKind.Internal, 'generationBatchId empty'
      );
    }

    this.state = GroupRoundState.Planning;
    this.activeRound = null;

    try {
      // 1. 校验 Chat 存在且为 Group
      const chats: Chat[] = await this.groupService.listGroupConversations();
      let targetChat: Chat | null = null;
      for (let i = 0; i < chats.length; i++) {
        if (chats[i].id === chatId) {
          targetChat = chats[i];
          break;
        }
      }
      if (targetChat === null) {
        throw new GroupRoundPlanError(
          GroupRoundPlanErrorKind.ChatNotFound, 'chat not found'
        );
      }
      if (targetChat.conversationMode !== ConversationMode.Group) {
        throw new GroupRoundPlanError(
          GroupRoundPlanErrorKind.NotGroupChat, 'not group mode'
        );
      }

      // 2. 读取参与者并构建快照
      const participants: ChatParticipant[] =
        await this.groupService.getParticipants(chatId);
      const speakers: GroupRoundSpeaker[] = await this.buildSpeakers(participants);

      if (speakers.length < MIN_AVAILABLE_SPEAKERS) {
        throw new GroupRoundPlanError(
          GroupRoundPlanErrorKind.InsufficientAvailableSpeakers,
          'available speakers < ' + String(MIN_AVAILABLE_SPEAKERS)
        );
      }

      // 3. 生成 operationId(自增,使旧轮次失效)
      this.generationOperationId = this.generationOperationId + 1;
      const operationId: number = this.generationOperationId;
      const now: number = nowMillis();

      const plan: GroupRoundPlan = {
        operationId: operationId,
        roundId: generationBatchId,
        chatId: chatId,
        userMessageId: userMessageId,
        speakers: speakers,
        createdAt: now
      };

      this.lastPlan = plan;
      this.state = GroupRoundState.Ready;
      // 本阶段不进入 Generating,立即清理活动上下文
      // 保留 lastPlan 作为最后一次调试信息,但不阻止用户继续发送
      this.activeRound = null;

      Logger.info(LOG_TAG, 'prepareRound ok speakers=' + String(speakers.length));
      return plan;
    } catch (e) {
      this.state = GroupRoundState.Idle;
      this.activeRound = null;
      if (e instanceof GroupRoundPlanError) {
        Logger.error(LOG_TAG, 'prepareRound failed kind=' + e.kind);
        throw e;
      }
      Logger.error(LOG_TAG, 'prepareRound failed: ' + String(e));
      throw new GroupRoundPlanError(
        GroupRoundPlanErrorKind.Internal, String(e)
      );
    }
  }

  /**
   * 获取当前活动轮次上下文。
   * 本阶段不进入 Generating,通常返回 null。
   */
  getActiveRound(): ActiveGroupRoundContext | null {
    return this.activeRound;
  }

  /**
   * 获取最后一次建立的计划(Ready 后保留)。
   * 不阻止用户继续发送,仅供调试 / UI 显示。
   */
  getLastPlan(): GroupRoundPlan | null {
    return this.lastPlan;
  }

  /**
   * 当前状态。
   */
  getState(): GroupRoundState {
    return this.state;
  }

  /**
   * 取消当前轮次。
   * - 使当前 operationId 失效
   * - 状态转为 Idle
   * - 保留 lastPlan(历史记录)
   *
   * @param expectedOperationId 可选,指定要取消的 operationId。
   *   不传或传 0 表示取消当前活动轮次。
   *   传入非 0 且不匹配时,认为是迟到取消,不执行。
   */
  cancelRound(expectedOperationId?: number): void {
    if (expectedOperationId !== undefined && expectedOperationId > 0) {
      if (this.activeRound === null ||
          this.activeRound.operationId !== expectedOperationId) {
        // 迟到取消,忽略
        return;
      }
    }
    this.activeRound = null;
    this.state = GroupRoundState.Idle;
    Logger.info(LOG_TAG, 'cancelRound ok');
  }

  /**
   * 清理已完成的轮次。
   * - 使指定 operationId 失效
   * - 状态转为 Idle
   * - 保留 lastPlan(历史记录)
   *
   * @param expectedOperationId 必填,指定要清理的 operationId。
   *   不匹配时不执行(迟到清理)。
   */
  clearCompletedRound(expectedOperationId: number): void {
    if (expectedOperationId <= 0) {
      return;
    }
    if (this.activeRound !== null &&
        this.activeRound.operationId === expectedOperationId) {
      this.activeRound = null;
      this.state = GroupRoundState.Idle;
      Logger.info(LOG_TAG, 'clearCompletedRound ok opId=' + String(expectedOperationId));
    }
  }

  /**
   * 校验上下文是否属于当前轮次。
   *
   * 校验字段:
   * - operationId
   * - roundId
   * - chatId
   *
   * 下一阶段 Provider 的 delta / complete / error / stop 回调
   * 必须先调用此方法校验,通过后才允许更新状态。
   */
  isCurrentRound(context: ActiveGroupRoundContext): boolean {
    if (this.activeRound === null) {
      return false;
    }
    return this.activeRound.operationId === context.operationId &&
           this.activeRound.roundId === context.roundId &&
           this.activeRound.chatId === context.chatId;
  }

  /**
   * 页面释放时调用,清理活动上下文。
   * 不抛错,不返回值。
   */
  dispose(): void {
    this.activeRound = null;
    this.state = GroupRoundState.Idle;
  }

  // ===== 内部方法 =====

  /**
   * 从参与者构建发言者快照。
   *
   * 规则:
   * - 过滤 isEnabled = true
   * - 按 speakerOrder ASC 排序
   * - 排除已删除角色(CharacterRepository.getById 返回 null)
   * - speakerIndex 从 0 连续
   * - 角色 ID 不重复(数据层已保证,这里再次防御)
   */
  private async buildSpeakers(
    participants: ChatParticipant[]
  ): Promise<GroupRoundSpeaker[]> {
    // 过滤启用成员并按 speakerOrder 排序
    const enabled: ChatParticipant[] = participants
      .filter((p: ChatParticipant): boolean => p.isEnabled)
      .sort((a: ChatParticipant, b: ChatParticipant): number =>
        a.speakerOrder - b.speakerOrder
      );

    if (enabled.length < MIN_AVAILABLE_SPEAKERS) {
      throw new GroupRoundPlanError(
        GroupRoundPlanErrorKind.InsufficientEnabledMembers,
        'enabled members < ' + String(MIN_AVAILABLE_SPEAKERS)
      );
    }

    // 批量校验角色存在性
    const speakers: GroupRoundSpeaker[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < enabled.length; i++) {
      const p: ChatParticipant = enabled[i];
      if (seen.has(p.characterId)) {
        // 防御:数据层已保证唯一,这里跳过
        continue;
      }
      let character: Character | null = null;
      try {
        character = await this.characterService.getById(p.characterId);
      } catch (e) {
        // 读取失败视为已删除,排除
        character = null;
      }
      if (character === null) {
        // 已删除角色不加入 speakers
        continue;
      }
      seen.add(p.characterId);
      speakers.push({
        characterId: p.characterId,
        speakerIndex: speakers.length
      });
    }

    return speakers;
  }
}
