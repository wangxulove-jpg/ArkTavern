import abilityTest from './Ability.test';
import uuidTest from './Uuid.test';
import loggerTest from './Logger.test';
import httpStreamTransportTest from './HttpStreamTransport.test';
import assetStoreKeyStoreTest from './AssetStoreKeyStore.test';
import providerKeyStoreDeviceTest from './ProviderKeyStore.test';
import providerConfigStoreDeviceTest from './ProviderConfigStore.test';
import harmonyHttpClientDeviceTest from './HarmonyHttpClient.test';
import openAiProviderDeviceTest from './OpenAIProvider.test';

export default function testsuite() {
  abilityTest();
  uuidTest();
  loggerTest();
  httpStreamTransportTest();
  assetStoreKeyStoreTest();
  providerKeyStoreDeviceTest();
  providerConfigStoreDeviceTest();
  harmonyHttpClientDeviceTest();
  openAiProviderDeviceTest();
}
