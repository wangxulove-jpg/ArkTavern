import localUnitTest from './LocalUnit.test';
import timeTest from './Time.test';
import networkErrorTest from './NetworkError.test';
import sseParserTest from './SseParser.test';
import utf8AndStateMachineTest from './Utf8StreamDecoder.test';

export default function testsuite() {
  localUnitTest();
  timeTest();
  networkErrorTest();
  sseParserTest();
  utf8AndStateMachineTest();
}
