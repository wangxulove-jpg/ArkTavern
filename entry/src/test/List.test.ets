import localUnitTest from './LocalUnit.test';
import timeTest from './Time.test';
import networkErrorTest from './NetworkError.test';
import sseParserTest from './SseParser.test';
import utf8AndStateMachineTest from './Utf8StreamDecoder.test';
import openAiUrlBuilderTest from './OpenAiUrlBuilder.test';
import openAiSseDeltaParserTest from './OpenAiSseDeltaParser.test';
import aliasBuilderTest from './AliasBuilder.test';
import secureStorageErrorTest from './SecureStorageError.test';
import providerConfigTest from './ProviderConfig.test';
import providerKeyStoreTest from './ProviderKeyStore.test';
import providerConfigCodecTest from './ProviderConfigCodec.test';
import openAiProviderTest from './OpenAIProvider.test';
import harmonyHttpClientHelpersTest from './HarmonyHttpClientHelpers.test';

export default function testsuite() {
  localUnitTest();
  timeTest();
  networkErrorTest();
  sseParserTest();
  utf8AndStateMachineTest();
  openAiUrlBuilderTest();
  openAiSseDeltaParserTest();
  aliasBuilderTest();
  secureStorageErrorTest();
  providerConfigTest();
  providerKeyStoreTest();
  providerConfigCodecTest();
  openAiProviderTest();
  harmonyHttpClientHelpersTest();
}
