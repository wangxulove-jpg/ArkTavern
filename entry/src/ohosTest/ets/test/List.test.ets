import groupRuntimeDeviceTest from './GroupRuntimeDevice.test';
import worldPlayerProfileContractTest from './WorldPlayerProfileContract.test';
import worldConversationSessionContractTest from './WorldConversationSessionContract.test';
import w1aSchemaContractTest from './W1aSchemaContract.test';
 
export default function testsuite() {
  groupRuntimeDeviceTest();
  worldPlayerProfileContractTest();
  worldConversationSessionContractTest();
  w1aSchemaContractTest();
}
