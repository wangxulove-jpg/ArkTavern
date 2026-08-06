import localUnitSmokeTest from './LocalUnit.test';
import groupRuntimeRegistryTest from './GroupRuntimeRegistry.test';
import groupRoundCoordinatorTest from './GroupRoundCoordinator.test';
import groupChatRuntimeServiceTest from './GroupChatRuntimeService.test';
import groupConversationMessageServiceTest from './GroupConversationMessageService.test';
import groupMutationDeleteProtectionTest from './GroupMutationDeleteProtection.test';
import groupMessageVisibilityPolicyTest from './GroupMessageVisibilityPolicy.test';

export default function testsuite() {
  localUnitSmokeTest();
  groupRuntimeRegistryTest();
  groupRoundCoordinatorTest();
  groupChatRuntimeServiceTest();
  groupConversationMessageServiceTest();
  groupMutationDeleteProtectionTest();
  groupMessageVisibilityPolicyTest();
}
