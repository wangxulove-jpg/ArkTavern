import abilityTest from './Ability.test';
import uuidTest from './Uuid.test';
import loggerTest from './Logger.test';
import httpStreamTransportTest from './HttpStreamTransport.test';

export default function testsuite() {
  abilityTest();
  uuidTest();
  loggerTest();
  httpStreamTransportTest();
}
