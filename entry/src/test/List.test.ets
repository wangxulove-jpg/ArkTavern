import localUnitSmokeTest from './LocalUnit.test';
import groupRuntimeRegistryTest from './GroupRuntimeRegistry.test';
import groupRoundCoordinatorTest from './GroupRoundCoordinator.test';
import groupChatRuntimeServiceTest from './GroupChatRuntimeService.test';
import groupConversationMessageServiceTest from './GroupConversationMessageService.test';
import groupMutationDeleteProtectionTest from './GroupMutationDeleteProtection.test';
import groupMessageVisibilityPolicyTest from './GroupMessageVisibilityPolicy.test';
import groupCharacterMemorySelectorTest from './GroupCharacterMemorySelector.test';
import groupMemorySelectionInspectionTest from './GroupMemorySelectionInspection.test';
import groupMemoryPromptInjectionTest from './GroupMemoryPromptInjection.test';
import groupAutoSummaryTest from './GroupAutoSummary.test';
import autoSummaryExecutorTest from './AutoSummaryExecutor.test';
import autoSummaryHardTest from './AutoSummaryHard.test';
import groupUserIdentityTest from './GroupUserIdentity.test';

export default function testsuite() {
  localUnitSmokeTest();
  groupRuntimeRegistryTest();
  groupRoundCoordinatorTest();
  groupChatRuntimeServiceTest();
  groupConversationMessageServiceTest();
  groupMutationDeleteProtectionTest();
  groupMessageVisibilityPolicyTest();
  groupCharacterMemorySelectorTest();
  groupMemorySelectionInspectionTest();
  groupMemoryPromptInjectionTest();
  groupAutoSummaryTest();
  autoSummaryExecutorTest();
  autoSummaryHardTest();
  groupUserIdentityTest();
}
