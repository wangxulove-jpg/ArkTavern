import groupRuntimeDeviceTest from './GroupRuntimeDevice.test';
import worldPlayerProfileContractTest from './WorldPlayerProfileContract.test';
import worldConversationSessionContractTest from './WorldConversationSessionContract.test';
import w1aSchemaContractTest from './W1aSchemaContract.test';
import participantSnapshotContractTest from './ParticipantSnapshotContract.test';
import w1b1SchemaContractTest from './W1b1SchemaContract.test';
import sessionStorageContractTest from './SessionStorageContract.test';
 
export default function testsuite() {
  groupRuntimeDeviceTest();
  worldPlayerProfileContractTest();
  worldConversationSessionContractTest();
  w1aSchemaContractTest();
  participantSnapshotContractTest();
  w1b1SchemaContractTest();
  sessionStorageContractTest();
}
