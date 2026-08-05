/**
 * GroupRoundCoordinator 本地单元测试(ROUND-01 ~ ROUND-08)
 *
 * 验证轮次计划与状态机:
 * - Speaker 排序 / 指定回复目标 / 默认全员 / 空成员
 * - advanceSpeaker 推进 / operationId 隔离 / 状态流转 / 非法重复终态
 *
 * 使用真实 GroupRoundCoordinator + Fake 群聊/角色服务。
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupRoundCoordinator } from '../main/ets/services/groupchat/GroupRoundCoordinator';
import {
  GroupRoundState,
  GroupRoundPlan,
  GroupRoundPlanError,
  GroupRoundPlanErrorKind,
  selectedCharactersReplyTarget,
  REPLY_TARGET_ALL_ENABLED
} from '../main/ets/services/groupchat/GroupRoundTypes';
import { GroupConversationPersistenceService } from '../main/ets/services/groupchat/GroupConversationPersistenceService';
import { CharacterService } from '../main/ets/services/CharacterService';
import {
  FakeGroupPersistenceService,
  FakeCharacterService,
  makeGroupChat,
  makeParticipant,
  makeCharacter,
  CHAT_A
} from './GroupRuntimeTestFakes';

interface CoordinatorContext {
  coordinator: GroupRoundCoordinator;
  groupService: FakeGroupPersistenceService;
  charService: FakeCharacterService;
}

function setupCoordinator(): CoordinatorContext {
  const groupService: FakeGroupPersistenceService = new FakeGroupPersistenceService();
  const charService: FakeCharacterService = new FakeCharacterService();
  const coordinator: GroupRoundCoordinator = new GroupRoundCoordinator(
    groupService as Object as GroupConversationPersistenceService,
    charService as Object as CharacterService
  );
  return { coordinator: coordinator, groupService: groupService, charService: charService };
}

/** 建立 A/B/C 全部启用、角色存在的标准群聊环境。 */
function setupFullGroup(): CoordinatorContext {
  const ctx = setupCoordinator();
  ctx.groupService.chats = [makeGroupChat(CHAT_A)];
  ctx.groupService.participantsByChat.set(CHAT_A, [
    makeParticipant(CHAT_A, 'char-a', 0),
    makeParticipant(CHAT_A, 'char-b', 1),
    makeParticipant(CHAT_A, 'char-c', 2)
  ]);
  ctx.charService.characters.set('char-a', makeCharacter('char-a', 'A'));
  ctx.charService.characters.set('char-b', makeCharacter('char-b', 'B'));
  ctx.charService.characters.set('char-c', makeCharacter('char-c', 'C'));
  return ctx;
}

export default function groupRoundCoordinatorTest() {
  describe('GroupRoundCoordinatorTest', () => {

    it('ROUND_01_speaker_sorted_enabled_existing', 0, async () => {
      const ctx = setupCoordinator();
      // 顺序打乱 + 一个禁用 + 一个已删除
      ctx.groupService.chats = [makeGroupChat(CHAT_A)];
      ctx.groupService.participantsByChat.set(CHAT_A, [
        makeParticipant(CHAT_A, 'char-c', 2),
        makeParticipant(CHAT_A, 'char-b', 1),
        makeParticipant(CHAT_A, 'char-deleted', 3, true),
        makeParticipant(CHAT_A, 'char-disabled', 0, false),
        makeParticipant(CHAT_A, 'char-a', 0)
      ]);
      ctx.charService.characters.set('char-a', makeCharacter('char-a', 'A'));
      ctx.charService.characters.set('char-b', makeCharacter('char-b', 'B'));
      ctx.charService.characters.set('char-c', makeCharacter('char-c', 'C'));
      // char-deleted 角色不存在(getById null)

      const plan: GroupRoundPlan = await ctx.coordinator.prepareRound(
        CHAT_A, 'user-1', 'round-1', REPLY_TARGET_ALL_ENABLED
      );
      expect(plan.speakers.length).assertEqual(3);
      expect(plan.speakers[0].characterId).assertEqual('char-a');
      expect(plan.speakers[1].characterId).assertEqual('char-b');
      expect(plan.speakers[2].characterId).assertEqual('char-c');
      expect(plan.speakers[0].speakerIndex).assertEqual(0);
      expect(plan.speakers[1].speakerIndex).assertEqual(1);
      expect(plan.speakers[2].speakerIndex).assertEqual(2);
    });

    it('ROUND_02_reply_target_single_character', 0, async () => {
      const ctx = setupFullGroup();
      const plan: GroupRoundPlan = await ctx.coordinator.prepareRound(
        CHAT_A, 'user-1', 'round-1', selectedCharactersReplyTarget(['char-b'])
      );
      expect(plan.speakers.length).assertEqual(1);
      expect(plan.speakers[0].characterId).assertEqual('char-b');
    });

    it('ROUND_03_default_all_enabled', 0, async () => {
      const ctx = setupFullGroup();
      const plan: GroupRoundPlan = await ctx.coordinator.prepareRound(
        CHAT_A, 'user-1', 'round-1', REPLY_TARGET_ALL_ENABLED
      );
      expect(plan.speakers.length).assertEqual(3);
      expect(plan.speakers[0].characterId).assertEqual('char-a');
      expect(plan.speakers[1].characterId).assertEqual('char-b');
      expect(plan.speakers[2].characterId).assertEqual('char-c');
      expect(plan.speakers[2].speakerIndex).assertEqual(2);
    });

    it('ROUND_04_no_valid_speakers_throws', 0, async () => {
      // 全部禁用 → InsufficientEnabledMembers
      const ctx1 = setupCoordinator();
      ctx1.groupService.chats = [makeGroupChat(CHAT_A)];
      ctx1.groupService.participantsByChat.set(CHAT_A, [
        makeParticipant(CHAT_A, 'char-a', 0, false),
        makeParticipant(CHAT_A, 'char-b', 1, false),
        makeParticipant(CHAT_A, 'char-c', 2, false)
      ]);
      let threw1: boolean = false;
      let kind1: GroupRoundPlanErrorKind | string = '';
      try {
        await ctx1.coordinator.prepareRound(CHAT_A, 'user-1', 'round-1', REPLY_TARGET_ALL_ENABLED);
      } catch (e) {
        threw1 = true;
        if (e instanceof GroupRoundPlanError) {
          kind1 = e.kind;
        }
      }
      expect(threw1).assertTrue();
      expect(kind1).assertEqual(GroupRoundPlanErrorKind.InsufficientEnabledMembers);
      expect(ctx1.coordinator.getState()).assertEqual(GroupRoundState.Idle);

      // 全部角色已删除 → InsufficientAvailableSpeakers
      const ctx2 = setupCoordinator();
      ctx2.groupService.chats = [makeGroupChat(CHAT_A)];
      ctx2.groupService.participantsByChat.set(CHAT_A, [
        makeParticipant(CHAT_A, 'char-a', 0),
        makeParticipant(CHAT_A, 'char-b', 1),
        makeParticipant(CHAT_A, 'char-c', 2)
      ]);
      // 不注册任何角色
      let threw2: boolean = false;
      let kind2: GroupRoundPlanErrorKind | string = '';
      try {
        await ctx2.coordinator.prepareRound(CHAT_A, 'user-1', 'round-1', REPLY_TARGET_ALL_ENABLED);
      } catch (e) {
        threw2 = true;
        if (e instanceof GroupRoundPlanError) {
          kind2 = e.kind;
        }
      }
      expect(threw2).assertTrue();
      expect(kind2).assertEqual(GroupRoundPlanErrorKind.InsufficientAvailableSpeakers);
      // 不进入 Generating,不持锁(纯协调器无锁,验证状态仍 Idle)
      expect(ctx2.coordinator.getState()).assertEqual(GroupRoundState.Idle);
      expect(ctx2.coordinator.getActiveRound()).assertEqual(null);
    });

    it('ROUND_05_advanceSpeaker_one_at_a_time', 0, async () => {
      const ctx = setupFullGroup();
      const plan: GroupRoundPlan = await ctx.coordinator.prepareRound(
        CHAT_A, 'user-1', 'round-1', REPLY_TARGET_ALL_ENABLED
      );
      const first = ctx.coordinator.beginGeneration(plan);
      expect(first.currentSpeakerIndex).assertEqual(0);
      expect(first.currentSpeakerCharacterId).assertEqual('char-a');

      const second = ctx.coordinator.advanceSpeaker(plan.operationId);
      expect(second === null).assertFalse();
      if (second !== null) {
        expect(second.currentSpeakerIndex).assertEqual(1);
        expect(second.currentSpeakerCharacterId).assertEqual('char-b');
      }

      const third = ctx.coordinator.advanceSpeaker(plan.operationId);
      expect(third === null).assertFalse();
      if (third !== null) {
        expect(third.currentSpeakerIndex).assertEqual(2);
        expect(third.currentSpeakerCharacterId).assertEqual('char-c');
      }

      const end = ctx.coordinator.advanceSpeaker(plan.operationId);
      expect(end).assertEqual(null);

      // 越界:再次调用仍返回 null
      const end2 = ctx.coordinator.advanceSpeaker(plan.operationId);
      expect(end2).assertEqual(null);
    });

    it('ROUND_06_old_operation_cannot_update_new_round', 0, async () => {
      const ctx = setupFullGroup();
      // Round-1
      const plan1: GroupRoundPlan = await ctx.coordinator.prepareRound(
        CHAT_A, 'user-1', 'round-1', REPLY_TARGET_ALL_ENABLED
      );
      ctx.coordinator.beginGeneration(plan1);
      const op1: number = plan1.operationId;

      // Round-2(prepare 覆盖 Ready)
      const plan2: GroupRoundPlan = await ctx.coordinator.prepareRound(
        CHAT_A, 'user-2', 'round-2', REPLY_TARGET_ALL_ENABLED
      );
      const ctx2 = ctx.coordinator.beginGeneration(plan2);
      const op2: number = plan2.operationId;
      expect(op2 === op1).assertFalse();

      // 旧 op1 的 markFailed / advance / updateMsgId 均不得影响新轮次
      ctx.coordinator.markFailed(op1);
      expect(ctx.coordinator.getState()).assertEqual(GroupRoundState.Generating);

      ctx.coordinator.updateCurrentAssistantMessageId(op1, 'stale-msg');
      expect(ctx2.currentAssistantMessageId).assertEqual(undefined);

      const advanced = ctx.coordinator.advanceSpeaker(op1);
      expect(advanced).assertEqual(null);
      // 新轮次仍指向第一个 speaker
      const active = ctx.coordinator.getActiveRound();
      expect(active === null).assertFalse();
      if (active !== null) {
        expect(active.operationId).assertEqual(op2);
        expect(active.currentSpeakerIndex).assertEqual(0);
      }
    });

    it('ROUND_07_state_transitions', 0, async () => {
      // Idle → Planning → Ready → Generating → Completed
      const ctx = setupFullGroup();
      expect(ctx.coordinator.getState()).assertEqual(GroupRoundState.Idle);
      const plan: GroupRoundPlan = await ctx.coordinator.prepareRound(
        CHAT_A, 'user-1', 'round-1', REPLY_TARGET_ALL_ENABLED
      );
      expect(ctx.coordinator.getState()).assertEqual(GroupRoundState.Ready);
      ctx.coordinator.beginGeneration(plan);
      expect(ctx.coordinator.getState()).assertEqual(GroupRoundState.Generating);
      ctx.coordinator.markCompleted(plan.operationId);
      expect(ctx.coordinator.getState()).assertEqual(GroupRoundState.Completed);

      // Generating → Cancelled
      const ctx2 = setupFullGroup();
      const plan2 = await ctx2.coordinator.prepareRound(CHAT_A, 'u', 'r', REPLY_TARGET_ALL_ENABLED);
      ctx2.coordinator.beginGeneration(plan2);
      ctx2.coordinator.markCancelled(plan2.operationId);
      expect(ctx2.coordinator.getState()).assertEqual(GroupRoundState.Cancelled);

      // Generating → Failed
      const ctx3 = setupFullGroup();
      const plan3 = await ctx3.coordinator.prepareRound(CHAT_A, 'u', 'r', REPLY_TARGET_ALL_ENABLED);
      ctx3.coordinator.beginGeneration(plan3);
      ctx3.coordinator.markFailed(plan3.operationId);
      expect(ctx3.coordinator.getState()).assertEqual(GroupRoundState.Failed);
    });

    it('ROUND_08_repeated_terminal_no_second_progress', 0, async () => {
      const ctx = setupFullGroup();
      const plan: GroupRoundPlan = await ctx.coordinator.prepareRound(
        CHAT_A, 'user-1', 'round-1', REPLY_TARGET_ALL_ENABLED
      );
      const op: number = plan.operationId;
      ctx.coordinator.beginGeneration(plan);
      ctx.coordinator.markCompleted(op);
      expect(ctx.coordinator.getState()).assertEqual(GroupRoundState.Completed);

      // 再次 markCompleted:activeRound 已空,直接返回,状态保持 Completed
      ctx.coordinator.markCompleted(op);
      expect(ctx.coordinator.getState()).assertEqual(GroupRoundState.Completed);
      // 不产生新的 activeRound
      expect(ctx.coordinator.getActiveRound()).assertEqual(null);

      // 旧 operation 的 markFailed 在有新活动轮次时不得覆盖
      const ctx2 = setupFullGroup();
      const plan2 = await ctx2.coordinator.prepareRound(CHAT_A, 'u', 'r', REPLY_TARGET_ALL_ENABLED);
      ctx2.coordinator.beginGeneration(plan2);
      ctx2.coordinator.markFailed(plan2.operationId + 999);
      expect(ctx2.coordinator.getState()).assertEqual(GroupRoundState.Generating);
    });

    it('ROUND_08b_markCancelled_after_completed_sets_cancelled_documented', 0, async () => {
      // 记录当前代码实际行为:activeRound 已清理后 markCancelled(任意 op)会把协调器状态改为 Cancelled。
      // 运行时不暴露该路径(startRound 完成后 activeOperationId=0,stopRound 不再执行),
      // 此处仅断言实际行为,不做"通过/失败"判定;是否需强化见报告 ROUND-08b。
      const ctx = setupCoordinator();
      ctx.groupService.chats = [makeGroupChat(CHAT_A)];
      ctx.groupService.participantsByChat.set(CHAT_A, [
        makeParticipant(CHAT_A, 'char-a', 0),
        makeParticipant(CHAT_A, 'char-b', 1)
      ]);
      ctx.charService.characters.set('char-a', makeCharacter('char-a', 'A'));
      ctx.charService.characters.set('char-b', makeCharacter('char-b', 'B'));

      const plan: GroupRoundPlan = await ctx.coordinator.prepareRound(
        CHAT_A, 'u', 'r', REPLY_TARGET_ALL_ENABLED
      );
      ctx.coordinator.beginGeneration(plan);
      ctx.coordinator.markCompleted(plan.operationId);
      ctx.coordinator.markCancelled(plan.operationId + 1);
      // 实际行为:状态变为 Cancelled(因为 activeRound 已为 null)
      expect(ctx.coordinator.getState()).assertEqual(GroupRoundState.Cancelled);
    });
  });
}
