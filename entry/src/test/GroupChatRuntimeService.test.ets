/**
 * GroupChatRuntimeService 本地单元测试
 *
 * 覆盖测试组:
 * - RUN-01~04 正常完整 Round / Streaming delta / 指定单 Speaker / 空模型结果
 * - STOP-01~08 第一/中间 Speaker 停止 / 重复 stop / 空闲 stop / stop 后迟到回调
 * - RACE-01~05 stop/complete/error 竞态与旧 Round 回调污染
 * - RETRY-01~06 失败 / 中间失败 / 重试 / 重试成功 / 重试再次失败 / 跨群聊锁
 * - END-01~04 空闲结束 / 生成中结束 / 重复结束 / stop 后结束
 *
 * 使用真实 GroupRuntimeRegistry + 真实 GroupRoundCoordinator + Fake 边界
 * (ModelService / MessageService / PromptAssembler)。
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupChatRuntimeService, GroupRuntimeCallbacks, GroupRuntimeMessageUpdate } from '../main/ets/services/groupchat/GroupChatRuntimeService';
import { GroupRoundCoordinator } from '../main/ets/services/groupchat/GroupRoundCoordinator';
import {
  GroupRoundState,
  GroupRoundPlan,
  GroupReplyTarget,
  selectedCharactersReplyTarget,
  REPLY_TARGET_ALL_ENABLED
} from '../main/ets/services/groupchat/GroupRoundTypes';
import { GroupRuntimeRegistry } from '../main/ets/services/groupchat/GroupRuntimeRegistry';
import { GroupConversationMessageService } from '../main/ets/services/groupchat/GroupConversationMessageService';
import { GroupConversationPersistenceService } from '../main/ets/services/groupchat/GroupConversationPersistenceService';
import { GroupPromptAssembler } from '../main/ets/services/groupchat/GroupPromptAssembler';
import { GroupPromptInspectionStore } from '../main/ets/services/groupchat/GroupPromptInspectionStore';
import { ModelService } from '../main/ets/services/ModelService';
import { CharacterService } from '../main/ets/services/CharacterService';
import { ChatMessage, ChatMessageStatus } from '../main/ets/models/ChatMessage';
import { NetworkErrorType } from '../main/ets/models/NetworkError';
import {
  FakeGroupMessageService,
  FakeModelService,
  FakePromptAssembler,
  FakeGroupPersistenceService,
  FakeCharacterService,
  RuntimeCallbackLog,
  createRuntimeCallbackLog,
  flushMicrotasks,
  makeGroupChat,
  makeParticipant,
  makeCharacter,
  makeGroupUserMessage,
  makeProviderConfig,
  CHAT_A,
  CHAT_B
} from './GroupRuntimeTestFakes';

interface RuntimeTestContext {
  runtime: GroupChatRuntimeService;
  registry: GroupRuntimeRegistry;
  coordinator: GroupRoundCoordinator;
  fakeMsg: FakeGroupMessageService;
  fakeModel: FakeModelService;
  fakePrompt: FakePromptAssembler;
  groupService: FakeGroupPersistenceService;
  charService: FakeCharacterService;
  log: RuntimeCallbackLog;
  callbacks: GroupRuntimeCallbacks;
}

class RuntimeCallbacksImpl implements GroupRuntimeCallbacks {
  private readonly log: RuntimeCallbackLog;

  constructor(log: RuntimeCallbackLog) {
    this.log = log;
  }

  onRoundStateChanged(state: GroupRoundState): void {
    this.log.states.push(state);
  }

  onSpeakerStarted(characterId: string, speakerIndex: number): void {
    this.log.speakerStarted.push({ characterId: characterId, index: speakerIndex });
  }

  onMessageCreated(message: ChatMessage): void {
    this.log.messageCreated.push(message);
  }

  onMessageUpdated(update: GroupRuntimeMessageUpdate): void {
    this.log.messageUpdated.push({
      messageId: update.messageId,
      status: update.status,
      content: update.content
    });
  }

  onSpeakerCompleted(characterId: string, speakerIndex: number): void {
    this.log.speakerCompleted.push({ characterId: characterId, index: speakerIndex });
  }

  onRoundCompleted(): void {
    this.log.roundCompleted++;
  }

  onRoundCancelled(): void {
    this.log.roundCancelled++;
  }

  onRoundFailed(characterId: string, errorMessage: string): void {
    this.log.roundFailed.push({ characterId: characterId, message: errorMessage });
  }
}

function makeCallbacks(log: RuntimeCallbackLog): GroupRuntimeCallbacks {
  return new RuntimeCallbacksImpl(log);
}

function setupRuntime(): RuntimeTestContext {
  const registry: GroupRuntimeRegistry = new GroupRuntimeRegistry();
  const groupService: FakeGroupPersistenceService = new FakeGroupPersistenceService();
  const charService: FakeCharacterService = new FakeCharacterService();

  groupService.chats = [makeGroupChat(CHAT_A), makeGroupChat(CHAT_B)];
  groupService.participantsByChat.set(CHAT_A, [
    makeParticipant(CHAT_A, 'char-a', 0),
    makeParticipant(CHAT_A, 'char-b', 1),
    makeParticipant(CHAT_A, 'char-c', 2)
  ]);
  groupService.participantsByChat.set(CHAT_B, [
    makeParticipant(CHAT_B, 'char-d', 0),
    makeParticipant(CHAT_B, 'char-e', 1)
  ]);
  charService.characters.set('char-a', makeCharacter('char-a', 'A'));
  charService.characters.set('char-b', makeCharacter('char-b', 'B'));
  charService.characters.set('char-c', makeCharacter('char-c', 'C'));
  charService.characters.set('char-d', makeCharacter('char-d', 'D'));
  charService.characters.set('char-e', makeCharacter('char-e', 'E'));

  const coordinator: GroupRoundCoordinator = new GroupRoundCoordinator(
    groupService as Object as GroupConversationPersistenceService,
    charService as Object as CharacterService
  );
  const fakeMsg: FakeGroupMessageService = new FakeGroupMessageService();
  const fakePrompt: FakePromptAssembler = new FakePromptAssembler();
  fakePrompt.characters.set('char-a', makeCharacter('char-a', 'A'));
  fakePrompt.characters.set('char-b', makeCharacter('char-b', 'B'));
  fakePrompt.characters.set('char-c', makeCharacter('char-c', 'C'));
  const fakeModel: FakeModelService = new FakeModelService();
  fakeModel.currentConfig = makeProviderConfig();

  const runtime: GroupChatRuntimeService = new GroupChatRuntimeService(
    coordinator,
    fakeMsg as Object as GroupConversationMessageService,
    fakePrompt as Object as GroupPromptAssembler,
    fakeModel as Object as ModelService,
    registry,
    new GroupPromptInspectionStore()
  );

  const log: RuntimeCallbackLog = createRuntimeCallbackLog();
  const callbacks: GroupRuntimeCallbacks = makeCallbacks(log);
  return {
    runtime: runtime,
    registry: registry,
    coordinator: coordinator,
    fakeMsg: fakeMsg,
    fakeModel: fakeModel,
    fakePrompt: fakePrompt,
    groupService: groupService,
    charService: charService,
    log: log,
    callbacks: callbacks
  };
}

interface PreparedRound {
  roundPromise: Promise<void>;
  plan: GroupRoundPlan;
}

/** 轮询等待 FakeModelService 打开到指定数量的流(确定性,不依赖固定 sleep)。 */
async function waitForStreamCount(s: RuntimeTestContext, expected: number): Promise<void> {
  for (let i = 0; i < 100 && s.fakeModel.streamCount() < expected; i++) {
    await flushMicrotasks();
  }
}

async function prepareAndStart(
  s: RuntimeTestContext,
  replyTarget: GroupReplyTarget = REPLY_TARGET_ALL_ENABLED
): Promise<PreparedRound> {
  const userMsg: ChatMessage = makeGroupUserMessage('user-1', 'hello', 'round-1');
  s.fakeMsg.setHistory(CHAT_A, [userMsg]);
  const plan: GroupRoundPlan = await s.coordinator.prepareRound(
    CHAT_A, userMsg.id, 'round-1', replyTarget
  );
  const roundPromise: Promise<void> = s.runtime.startRound(plan, s.callbacks);
  await waitForStreamCount(s, 1);
  return { roundPromise: roundPromise, plan: plan };
}

function statesContain(states: GroupRoundState[], target: GroupRoundState): boolean {
  for (let i = 0; i < states.length; i++) {
    if (states[i] === target) {
      return true;
    }
  }
  return false;
}

export default function groupChatRuntimeServiceTest() {
  describe('GroupChatRuntimeServiceTest', () => {

    // ===== RUN 正常轮次 =====

    it('RUN_01_full_round_strict_order', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;

      // A 开始,只有一个活跃 Stream
      expect(s.fakeModel.streamCount()).assertEqual(1);
      expect(s.fakePrompt.lastSpeakerCharacterId).assertEqual('char-a');

      s.fakeModel.fireCompleteAt(0, 'reply-a');
      await flushMicrotasks();
      expect(s.fakeModel.streamCount()).assertEqual(2);
      expect(s.fakePrompt.lastSpeakerCharacterId).assertEqual('char-b');

      s.fakeModel.fireCompleteAt(1, 'reply-b');
      await flushMicrotasks();
      expect(s.fakeModel.streamCount()).assertEqual(3);
      expect(s.fakePrompt.lastSpeakerCharacterId).assertEqual('char-c');

      s.fakeModel.fireCompleteAt(2, 'reply-c');
      await roundPromise;

      expect(s.log.roundCompleted).assertEqual(1);
      expect(statesContain(s.log.states, GroupRoundState.Completed)).assertTrue();
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Completed);
      expect(s.fakeMsg.getStatus('aid-2')).assertEqual(ChatMessageStatus.Completed);
      expect(s.fakeMsg.getStatus('aid-3')).assertEqual(ChatMessageStatus.Completed);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.coordinator.getState()).assertEqual(GroupRoundState.Completed);
    });

    it('RUN_02_streaming_delta_accumulates', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;

      expect(s.fakeModel.streamCount()).assertEqual(1);
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();
      s.fakeModel.fireDeltaAt(0, 'delta-b');
      await flushMicrotasks();

      // UI 更新路径:onMessageUpdated 携带累计正文(与持久化节流无关)
      let lastUiContent: string = '';
      for (let i = 0; i < s.log.messageUpdated.length; i++) {
        if (s.log.messageUpdated[i].messageId === 'aid-1') {
          lastUiContent = s.log.messageUpdated[i].content;
        }
      }
      expect(lastUiContent).assertEqual('delta-adelta-b');
      // B 尚未开始
      expect(s.fakeModel.streamCount()).assertEqual(1);

      s.fakeModel.fireCompleteAt(0, 'complete-value');
      await waitForStreamCount(s, 2);
      s.fakeModel.fireCompleteAt(1, 'reply-b');
      await waitForStreamCount(s, 3);
      s.fakeModel.fireCompleteAt(2, 'reply-c');
      await roundPromise;
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Completed);
      expect(s.fakeMsg.getContent('aid-1')).assertEqual('complete-value');
    });

    it('RUN_03_single_speaker_target', 0, async () => {
      const s = setupRuntime();
      const preparedPrepared = await prepareAndStart(s, selectedCharactersReplyTarget(['char-b']));
      const roundPromise: Promise<void> = preparedPrepared.roundPromise;

      expect(s.fakeModel.streamCount()).assertEqual(1);
      expect(s.fakePrompt.lastSpeakerCharacterId).assertEqual('char-b');

      s.fakeModel.fireCompleteAt(0, 'reply-b');
      await roundPromise;

      expect(s.log.roundCompleted).assertEqual(1);
      expect(s.fakeModel.streamCount()).assertEqual(1);
      // 只创建了 B 的一条消息
      expect(s.log.messageCreated.length).assertEqual(1);
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Completed);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('RUN_04_empty_model_result_completed', 0, async () => {
      // 按当前生产设计:模型正常 complete 但内容为空 → 消息仍 Completed(正文为空)
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;

      s.fakeModel.fireCompleteAt(0, '');
      await waitForStreamCount(s, 2);
      s.fakeModel.fireCompleteAt(1, '');
      await waitForStreamCount(s, 3);
      s.fakeModel.fireCompleteAt(2, '');
      await roundPromise;

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Completed);
      expect(s.fakeMsg.getStatus('aid-2')).assertEqual(ChatMessageStatus.Completed);
      expect(s.fakeMsg.getStatus('aid-3')).assertEqual(ChatMessageStatus.Completed);
      expect(s.log.roundCompleted).assertEqual(1);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    // ===== STOP 停止整轮 =====

    it('STOP_01_stop_during_first_speaker', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      expect(s.fakeModel.streamCount()).assertEqual(1);

      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();

      await s.runtime.stopRound();
      await roundPromise;

      // Stream abort 恰好一次
      expect(s.fakeModel.recordAt(0).handle.abortCount).assertEqual(1);
      // A 最终 Cancelled
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);
      // B、C 不启动
      expect(s.fakeModel.streamCount()).assertEqual(1);
      expect(s.log.roundCancelled).assertEqual(0); // 当前实现:stopRound 不触发 onRoundCancelled
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.coordinator.getState()).assertEqual(GroupRoundState.Cancelled);

      // 可以启动下一 Round(单角色目标,验证锁释放后可正常生成)
      const userMsg2: ChatMessage = makeGroupUserMessage('user-2', 'again', 'round-2');
      s.fakeMsg.setHistory(CHAT_A, [userMsg2]);
      const plan2: GroupRoundPlan = await s.coordinator.prepareRound(
        CHAT_A, userMsg2.id, 'round-2', selectedCharactersReplyTarget(['char-a'])
      );
      const p2: Promise<void> = s.runtime.startRound(plan2, s.callbacks);
      await waitForStreamCount(s, 2);
      expect(s.fakeModel.streamCount()).assertEqual(2);
      s.fakeModel.fireCompleteAt(1, 'ok');
      await p2;
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('STOP_02_stop_during_middle_speaker', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;

      s.fakeModel.fireCompleteAt(0, 'reply-a');
      await flushMicrotasks();
      expect(s.fakeModel.streamCount()).assertEqual(2);
      s.fakeModel.fireDeltaAt(1, 'delta-b');
      await flushMicrotasks();

      await s.runtime.stopRound();
      await roundPromise;

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Completed);
      expect(s.fakeMsg.getStatus('aid-2')).assertEqual(ChatMessageStatus.Cancelled);
      expect(s.fakeMsg.getContent('aid-1')).assertEqual('reply-a');
      // C 不启动
      expect(s.fakeModel.streamCount()).assertEqual(2);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.coordinator.getState()).assertEqual(GroupRoundState.Cancelled);
    });

    it('STOP_03_double_stop', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();

      const finalizeBefore: number = s.fakeMsg.finalizeCallCount;
      await s.runtime.stopRound();
      await s.runtime.stopRound();
      await roundPromise;

      expect(s.fakeModel.recordAt(0).handle.abortCount).assertEqual(1);
      expect(s.fakeMsg.finalizeCallCount - finalizeBefore).assertEqual(1);
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('STOP_04_idle_stop', 0, async () => {
      const s = setupRuntime();
      const finalizeBefore: number = s.fakeMsg.finalizeCallCount;
      await s.runtime.stopRound();
      expect(s.fakeMsg.finalizeCallCount - finalizeBefore).assertEqual(0);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.coordinator.getState()).assertEqual(GroupRoundState.Idle);
    });

    it('STOP_05_late_delta_after_stop_isolated', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();
      await s.runtime.stopRound();
      await roundPromise;

      const contentAfterStop: string = s.fakeMsg.getContent('aid-1');
      const updateCountAfterStop: number = s.fakeMsg.updateStreamingCount;

      // stop 后触发旧 Stream 迟到 delta
      s.fakeModel.fireLateDeltaAt(0, 'delta-late');
      await flushMicrotasks();

      expect(s.fakeMsg.getContent('aid-1')).assertEqual(contentAfterStop);
      expect(s.fakeMsg.updateStreamingCount).assertEqual(updateCountAfterStop);
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.fakeModel.streamCount()).assertEqual(1);
    });

    it('STOP_06_late_complete_after_stop_isolated', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();
      await s.runtime.stopRound();
      await roundPromise;

      s.fakeModel.fireLateCompleteAt(0, 'late-complete');
      await flushMicrotasks();

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.fakeModel.streamCount()).assertEqual(1);
    });

    it('STOP_07_late_error_after_stop_isolated', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();
      await s.runtime.stopRound();
      await roundPromise;

      const failedBefore: number = s.log.roundFailed.length;
      s.fakeModel.fireLateErrorAt(0, NetworkErrorType.Network, 'late-error');
      await flushMicrotasks();

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);
      expect(s.log.roundFailed.length - failedBefore).assertEqual(0);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.fakeModel.streamCount()).assertEqual(1);
    });

    it('STOP_08_throttled_tail_no_overwrite', 0, async () => {
      // 触发多次 delta(含超过 64 字符阈值),stop 后最终 Cancelled 内容不被尾部 delta 覆盖
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      // 3 段 30 字符 → 每段不足 64,但累计足够;这里仅验证最终化用停止时累积正文
      s.fakeModel.fireDeltaAt(0, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      await flushMicrotasks();
      s.fakeModel.fireDeltaAt(0, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      await flushMicrotasks();
      await s.runtime.stopRound();
      await roundPromise;

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);
      expect(s.fakeMsg.getContent('aid-1')).assertEqual('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
      // 迟到 delta 不得改写最终正文
      s.fakeModel.fireLateDeltaAt(0, 'ccc');
      await flushMicrotasks();
      expect(s.fakeMsg.getContent('aid-1')).assertEqual('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    });

    // ===== RACE 竞态 =====

    it('RACE_01_complete_then_stop', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;

      // 1. onComplete 先触发
      s.fakeModel.fireCompleteAt(0, 'reply-a');
      // 2. 立即 stop(在 finalize .then 完成前)
      await s.runtime.stopRound();
      await roundPromise;

      // Completed 获胜:消息不能被改为 Cancelled
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Completed);
      expect(s.fakeMsg.getContent('aid-1')).assertEqual('reply-a');
      // 不重复 finalize
      expect(s.fakeMsg.finalizeCallCount).assertEqual(1);
      // 后续流程只推进一次(B 不启动)
      expect(s.fakeModel.streamCount()).assertEqual(1);
      // Registry 释放
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('RACE_02_stop_then_complete', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();

      await s.runtime.stopRound();
      await roundPromise;

      // stop 后触发 complete → Cancelled 获胜,complete 被拒绝
      s.fakeModel.fireLateCompleteAt(0, 'late');
      await flushMicrotasks();

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);
      expect(s.fakeModel.streamCount()).assertEqual(1);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('RACE_03_complete_then_error', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;

      s.fakeModel.fireCompleteAt(0, 'reply-a');
      s.fakeModel.fireErrorAt(0, NetworkErrorType.Network, 'stale-error');
      // 轮次继续推进到 B、C,补完它们
      await waitForStreamCount(s, 2);
      s.fakeModel.fireCompleteAt(1, 'reply-b');
      await waitForStreamCount(s, 3);
      s.fakeModel.fireCompleteAt(2, 'reply-c');
      await roundPromise;

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Completed);
      expect(s.log.roundFailed.length).assertEqual(0);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('RACE_04_error_then_complete', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;

      s.fakeModel.fireErrorAt(0, NetworkErrorType.Network, 'net-down');
      s.fakeModel.fireCompleteAt(0, 'late-complete');
      await roundPromise;

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Failed);
      expect(s.log.roundFailed.length).assertEqual(1);
      expect(s.fakeModel.streamCount()).assertEqual(1);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('RACE_05_old_round_callbacks_do_not_pollute_new_round', 0, async () => {
      const s = setupRuntime();

      // Round-1:启动后停止
      const preparedR1 = await prepareAndStart(s);
      const r1: Promise<void> = preparedR1.roundPromise;
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();
      await s.runtime.stopRound();
      await r1;
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.fakeModel.streamCount()).assertEqual(1);

      // Round-2:启动
      const userMsg2: ChatMessage = makeGroupUserMessage('user-2', 'second', 'round-2');
      s.fakeMsg.setHistory(CHAT_A, [userMsg2]);
      const plan2: GroupRoundPlan = await s.coordinator.prepareRound(CHAT_A, userMsg2.id, 'round-2');
      const p2: Promise<void> = s.runtime.startRound(plan2, s.callbacks);
      await flushMicrotasks();
      expect(s.fakeModel.streamCount()).assertEqual(2);
      expect(s.fakePrompt.lastSpeakerCharacterId).assertEqual('char-a');

      // 触发 Round-1 的迟到 delta / complete / error
      s.fakeModel.fireLateDeltaAt(0, 'stale-delta');
      s.fakeModel.fireLateCompleteAt(0, 'stale-complete');
      s.fakeModel.fireLateErrorAt(0, NetworkErrorType.Network, 'stale-error');
      await flushMicrotasks();

      // Round-2 状态不受影响
      expect(s.registry.isAnyGroupRunning()).assertTrue();
      expect(s.registry.isChatRunning(CHAT_A)).assertTrue();
      // Round-2 消息未被修改(仍 Streaming)
      expect(s.fakeMsg.getStatus('aid-2')).assertEqual(ChatMessageStatus.Streaming);

      // 正常完成 Round-2(推进 A→B→C)
      s.fakeModel.fireCompleteAt(1, 'reply');
      await waitForStreamCount(s, 3);
      s.fakeModel.fireCompleteAt(2, 'reply-b');
      await waitForStreamCount(s, 4);
      s.fakeModel.fireCompleteAt(3, 'reply-c');
      await p2;
      expect(s.fakeMsg.getStatus('aid-2')).assertEqual(ChatMessageStatus.Completed);
      expect(s.log.roundCompleted).assertEqual(1);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    // ===== RETRY 失败与重试 =====

    it('RETRY_01_first_speaker_failure', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;

      s.fakeModel.fireErrorAt(0, NetworkErrorType.Network, 'net-down');
      await roundPromise;

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Failed);
      expect(s.log.roundFailed.length).assertEqual(1);
      expect(s.log.roundFailed[0].characterId).assertEqual('char-a');
      expect(s.fakeModel.streamCount()).assertEqual(1);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.coordinator.getState()).assertEqual(GroupRoundState.Failed);
    });

    it('RETRY_02_middle_speaker_failure', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;

      s.fakeModel.fireCompleteAt(0, 'reply-a');
      await flushMicrotasks();
      expect(s.fakeModel.streamCount()).assertEqual(2);
      s.fakeModel.fireErrorAt(1, NetworkErrorType.Network, 'net-down');
      await roundPromise;

      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Completed);
      expect(s.fakeMsg.getStatus('aid-2')).assertEqual(ChatMessageStatus.Failed);
      expect(s.fakeModel.streamCount()).assertEqual(2);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('RETRY_03_retry_failed_speaker', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireErrorAt(0, NetworkErrorType.Network, 'net-down');
      await roundPromise;

      const oldMsgId: string = s.log.messageCreated[0].id;
      expect(s.fakeMsg.getStatus(oldMsgId)).assertEqual(ChatMessageStatus.Failed);

      // 重试(异步,等待 stream 打开)
      const retryPromise: Promise<void> = s.runtime.retrySpeakerMessage(oldMsgId, CHAT_A, s.callbacks);
      await waitForStreamCount(s, 2);

      // 新 operationId + 只启动失败 Speaker(char-a)
      expect(s.fakeModel.streamCount()).assertEqual(2);
      expect(s.fakePrompt.lastSpeakerCharacterId).assertEqual('char-a');
      expect(s.registry.isAnyGroupRunning()).assertTrue();

      s.fakeModel.fireCompleteAt(1, 'reply-retry');
      await retryPromise;

      // 新消息创建(不覆盖原消息),同 generationBatchId
      expect(s.log.messageCreated.length).assertEqual(2);
      const newMsgId: string = s.log.messageCreated[1].id;
      expect(newMsgId === oldMsgId).assertFalse();
      expect(s.fakeMsg.getStatus(oldMsgId)).assertEqual(ChatMessageStatus.Failed);
      expect(s.fakeMsg.getStatus(newMsgId)).assertEqual(ChatMessageStatus.Completed);
      expect(s.log.roundCompleted).assertEqual(1);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.coordinator.getState()).assertEqual(GroupRoundState.Idle);
    });

    it('RETRY_04_retry_success_clears_error_state', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireErrorAt(0, NetworkErrorType.Network, 'net-down');
      await roundPromise;
      const oldMsgId: string = s.log.messageCreated[0].id;

      const retryPromise: Promise<void> = s.runtime.retrySpeakerMessage(oldMsgId, CHAT_A, s.callbacks);
      await waitForStreamCount(s, 2);
      s.fakeModel.fireCompleteAt(1, 'reply-retry');
      await retryPromise;

      expect(s.fakeMsg.getStatus(s.log.messageCreated[1].id)).assertEqual(ChatMessageStatus.Completed);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      // 不重复创建用户消息(用户消息数不变)
      const userMessages: ChatMessage[] = s.fakeMsg.getMessages(CHAT_A).filter((m: ChatMessage): boolean =>
        m.senderType === 'user'
      );
      expect(userMessages.length).assertEqual(1);
    });

    it('RETRY_05_retry_fails_again', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireErrorAt(0, NetworkErrorType.Network, 'net-down');
      await roundPromise;
      const oldMsgId: string = s.log.messageCreated[0].id;

      const retryPromise: Promise<void> = s.runtime.retrySpeakerMessage(oldMsgId, CHAT_A, s.callbacks);
      await waitForStreamCount(s, 2);
      s.fakeModel.fireErrorAt(1, NetworkErrorType.Network, 'net-down-again');
      await retryPromise;

      expect(s.fakeMsg.getStatus(oldMsgId)).assertEqual(ChatMessageStatus.Failed);
      expect(s.fakeMsg.getStatus(s.log.messageCreated[1].id)).assertEqual(ChatMessageStatus.Failed);
      // 不产生无限消息
      expect(s.log.messageCreated.length).assertEqual(2);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      // 可以再次重试或结束
      const retryPromise2: Promise<void> = s.runtime.retrySpeakerMessage(oldMsgId, CHAT_A, s.callbacks);
      await waitForStreamCount(s, 3);
      expect(s.fakeModel.streamCount()).assertEqual(3);
      s.fakeModel.fireCompleteAt(2, 'ok');
      await retryPromise2;
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('RETRY_06_other_chat_locked_during_retry', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireErrorAt(0, NetworkErrorType.Network, 'net-down');
      await roundPromise;
      const oldMsgId: string = s.log.messageCreated[0].id;

      const retryPromise: Promise<void> = s.runtime.retrySpeakerMessage(oldMsgId, CHAT_A, s.callbacks);
      await waitForStreamCount(s, 2);
      expect(s.registry.isChatRunning(CHAT_A)).assertTrue();

      // Retry 运行时,B 群聊获取锁应安全拒绝
      let rejected: boolean = false;
      try {
        s.registry.acquire(CHAT_B, 'round-b', 100, GroupRoundState.Generating);
      } catch (e) {
        rejected = true;
      }
      expect(rejected).assertTrue();

      s.fakeModel.fireCompleteAt(1, 'ok');
      await retryPromise;

      // Retry 完成后 B 可获取
      s.registry.acquire(CHAT_B, 'round-b', 101, GroupRoundState.Generating);
      expect(s.registry.getChatId()).assertEqual(CHAT_B);
    });

    // ===== END 结束本轮 =====

    it('END_01_idle_end_idempotent', 0, async () => {
      const s = setupRuntime();
      const msgBefore: number = s.fakeMsg.getMessages(CHAT_A).length;
      await s.runtime.endRound();
      expect(s.fakeMsg.getMessages(CHAT_A).length - msgBefore).assertEqual(0);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
      expect(s.coordinator.getState()).assertEqual(GroupRoundState.Idle);
    });

    it('END_02_end_during_streaming', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();

      await s.runtime.endRound();
      await roundPromise;

      expect(s.fakeModel.recordAt(0).handle.abortCount).assertEqual(1);
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);
      expect(s.fakeModel.streamCount()).assertEqual(1);
      expect(s.registry.isAnyGroupRunning()).assertFalse();

      // 可以开始下一 Round(单角色目标)
      const userMsg2: ChatMessage = makeGroupUserMessage('user-2', 'again', 'round-2');
      s.fakeMsg.setHistory(CHAT_A, [userMsg2]);
      const plan2: GroupRoundPlan = await s.coordinator.prepareRound(
        CHAT_A, userMsg2.id, 'round-2', selectedCharactersReplyTarget(['char-a'])
      );
      const p2: Promise<void> = s.runtime.startRound(plan2, s.callbacks);
      await waitForStreamCount(s, 2);
      s.fakeModel.fireCompleteAt(1, 'ok');
      await p2;
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('END_03_repeat_end', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();

      await s.runtime.endRound();
      await roundPromise;
      expect(s.fakeModel.recordAt(0).handle.abortCount).assertEqual(1);

      const finalizeBefore: number = s.fakeMsg.finalizeCallCount;
      await s.runtime.endRound();
      expect(s.fakeMsg.finalizeCallCount - finalizeBefore).assertEqual(0);
      expect(s.fakeModel.recordAt(0).handle.abortCount).assertEqual(1);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });

    it('END_04_end_after_stop', 0, async () => {
      const s = setupRuntime();
      const prepared = await prepareAndStart(s);
      const roundPromise: Promise<void> = prepared.roundPromise;
      s.fakeModel.fireDeltaAt(0, 'delta-a');
      await flushMicrotasks();

      await s.runtime.stopRound();
      await roundPromise;
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);

      await s.runtime.endRound();
      // 不覆盖 Cancelled,不产生二次清理异常,Registry 保持为空
      expect(s.fakeMsg.getStatus('aid-1')).assertEqual(ChatMessageStatus.Cancelled);
      expect(s.registry.isAnyGroupRunning()).assertFalse();
    });
  });
}
