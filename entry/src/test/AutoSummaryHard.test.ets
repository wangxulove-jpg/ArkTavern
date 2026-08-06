/**
 * GroupAutoSummary 1C AUTOHARD 可靠性测试
 * 不调用真实模型。
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupAutoSummaryPolicy } from '../../main/ets/services/groupchat/GroupAutoSummaryPlanner';
import { GroupAutoSummaryExecutor } from '../../main/ets/services/groupchat/GroupAutoSummaryExecutor';
import { GroupAutoSummaryDetailLevel, GroupAutoSummaryPlan, getOutputHardCap, computeSummaryInputHash, getGroupAutoSummaryLevelSpec } from '../../main/ets/models/groupchat/GroupAutoSummaryModels';

export default function autoSummaryHardTest(): void {
  describe('GroupAutoSummary_1C_AUTOHARD', (): void => {

    // ===== AUTOHARD-01: in-flight 防重 =====
    it('AUTOHARD-01 in-flight prevents double execution', (): void => {
      const executor: GroupAutoSummaryExecutor = new GroupAutoSummaryExecutor(
        null as Object, null as Object
      ) as GroupAutoSummaryExecutor;

      const plan: GroupAutoSummaryPlan = {
        groupConversationId: 'g1', ownerCharacterId: 'c1',
        detailLevel: GroupAutoSummaryDetailLevel.Medium,
        previousSummaryMemoryId: '', previousSummaryContent: '',
        previousSummaryBoundaryMessageId: '', previousSummaryBoundaryRoundId: '',
        previousSummaryUpdatedAt: 0, previousSummarySourceHash: '',
        activeSummaryIds: [], activeSummaryContents: [], activeSummarySourceHashes: [],
        activeSummaryCount: 0, requiresConsolidation: false,
        candidateMessages: [], candidateMessageIds: ['m1'],
        firstCandidateMessageId: 'm1', lastCandidateMessageId: 'm1',
        completedVisibleMessageCount: 1, userMessageCount: 1,
        characterMessageCount: 0, narrationMessageCount: 0,
        estimatedInputTokens: 50, eligible: true,
        ineligibleReason: '', createdAt: 1
      };

      const key: string = executor.buildInFlightKey(plan);
      expect(executor.tryAcquireInFlight(key)).assertTrue();
      expect(executor.tryAcquireInFlight(key)).assertFalse();
      executor.releaseInFlight(key);
      expect(executor.tryAcquireInFlight(key)).assertTrue();
      executor.releaseInFlight(key);
    });

    // ===== AUTOHARD-04: 持久化 Hash 幂等 =====
    it('AUTOHARD-04 same inputs produce same hash', (): void => {
      const plan: GroupAutoSummaryPlan = {
        groupConversationId: 'g1', ownerCharacterId: 'c1',
        detailLevel: GroupAutoSummaryDetailLevel.Concise,
        previousSummaryMemoryId: 'm0', previousSummaryContent: 'old',
        previousSummaryBoundaryMessageId: 'b0', previousSummaryBoundaryRoundId: 'r0',
        previousSummaryUpdatedAt: 1000, previousSummarySourceHash: 'h0',
        activeSummaryIds: ['s1'], activeSummaryContents: ['c1'],
        activeSummarySourceHashes: ['sh1'],
        activeSummaryCount: 1, requiresConsolidation: false,
        candidateMessages: [], candidateMessageIds: ['m1', 'm2'],
        firstCandidateMessageId: 'm1', lastCandidateMessageId: 'm2',
        completedVisibleMessageCount: 2, userMessageCount: 1,
        characterMessageCount: 1, narrationMessageCount: 0,
        estimatedInputTokens: 100, eligible: true,
        ineligibleReason: '', createdAt: 2
      };
      const h1: string = computeSummaryInputHash(plan, 'g-as-1c-v1');
      const h2: string = computeSummaryInputHash(plan, 'g-as-1c-v1');
      expect(h1).assertEqual(h2);
      expect(h1.length).assertLarger(0);
    });

    // ===== AUTOHARD-16: 档位硬上限 =====
    it('AUTOHARD-16 hard caps per level', (): void => {
      expect(getOutputHardCap(GroupAutoSummaryDetailLevel.Concise)).assertEqual(500);
      expect(getOutputHardCap(GroupAutoSummaryDetailLevel.Medium)).assertEqual(1000);
      expect(getOutputHardCap(GroupAutoSummaryDetailLevel.Detailed)).assertEqual(1800);
    });

    // ===== 回归 =====
    it('AUTOHARD-REGRESS thresholds unchanged', (): void => {
      expect(GroupAutoSummaryPolicy.MESSAGE_COUNT_THRESHOLD).assertEqual(12);
      expect(GroupAutoSummaryPolicy.TOKEN_THRESHOLD).assertEqual(2200);
    });

    it('AUTOHARD-REGRESS maxOutputTokens', (): void => {
      expect(getGroupAutoSummaryLevelSpec(GroupAutoSummaryDetailLevel.Concise).maxOutputTokens).assertEqual(256);
      expect(getGroupAutoSummaryLevelSpec(GroupAutoSummaryDetailLevel.Medium).maxOutputTokens).assertEqual(512);
      expect(getGroupAutoSummaryLevelSpec(GroupAutoSummaryDetailLevel.Detailed).maxOutputTokens).assertEqual(1024);
    });

  });
}
