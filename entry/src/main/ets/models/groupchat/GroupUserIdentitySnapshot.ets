/**
 * GroupUserIdentitySnapshot 群聊唯一用户身份快照(G-GROUP-USER-IDENTITY-1)
 *
 * 每轮开始时创建一次不可变快照。
 * 同一轮所有角色共享同一个快照。
 */

import { preferences } from '@kit.ArkData';

export interface GroupUserIdentitySnapshot {
  readonly displayName: string;
  readonly personaText: string;
  readonly source: GroupUserIdentitySource;
  readonly createdAt: number;
}

export enum GroupUserIdentitySource {
  UserPersona = 'user_persona',
  ChatSetting = 'chat_setting',
  Default = 'default'
}

export const DEFAULT_USER_DISPLAY_NAME: string = '用户';
export const DEFAULT_USER_PERSONA_TEXT: string = '未设置';

const STORE_NAME: string = 'arktavern_settings';
const USER_IDENTITY_KEY_PREFIX: string = 'group_user_identity_';
const GLOBAL_USER_NAME_KEY: string = 'global_user_name';

/** JSON 解析接口 */
interface UserIdentityJson {
  displayName: string;
  personaText: string;
}

export function createDefaultUserIdentitySnapshot(): GroupUserIdentitySnapshot {
  const s: GroupUserIdentitySnapshot = {
    displayName: DEFAULT_USER_DISPLAY_NAME,
    personaText: DEFAULT_USER_PERSONA_TEXT,
    source: GroupUserIdentitySource.Default,
    createdAt: Date.now()
  };
  return s;
}

function buildUserIdentityKey(chatId: string): string {
  return USER_IDENTITY_KEY_PREFIX + chatId;
}

export async function loadGroupUserIdentitySettings(chatId: string): Promise<GroupUserIdentitySnapshot> {
  try {
    const ctx: Context = getContext();
    const prefs: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);

    // 1. 优先读取该群聊的用户身份设置
    const chatKey: string = buildUserIdentityKey(chatId);
    const raw: string = prefs.getSync(chatKey, '') as string;
    if (raw.length > 0) {
      const parsed: UserIdentityJson = JSON.parse(raw);
      const displayName: string =
        parsed.displayName.length > 0 ? parsed.displayName : DEFAULT_USER_DISPLAY_NAME;
      const personaText: string =
        parsed.personaText.length > 0 ? parsed.personaText : DEFAULT_USER_PERSONA_TEXT;
      const snapshot: GroupUserIdentitySnapshot = {
        displayName: displayName,
        personaText: personaText,
        source: GroupUserIdentitySource.ChatSetting,
        createdAt: Date.now()
      };
      return snapshot;
    }

    // 2. 回退到全局用户名称(应用设置页)
    const globalName: string = prefs.getSync(GLOBAL_USER_NAME_KEY, '') as string;
    if (globalName.length > 0) {
      const snapshot: GroupUserIdentitySnapshot = {
        displayName: globalName,
        personaText: DEFAULT_USER_PERSONA_TEXT,
        source: GroupUserIdentitySource.ChatSetting,
        createdAt: Date.now()
      };
      return snapshot;
    }
  } catch (e) {
    // ignore
  }
  return createDefaultUserIdentitySnapshot();
}

export function persistGroupUserIdentitySettings(
  chatId: string,
  displayName: string,
  personaText: string
): void {
  try {
    const ctx: Context = getContext();
    preferences.getPreferences(ctx, STORE_NAME).then((prefs: preferences.Preferences): void => {
      const key: string = buildUserIdentityKey(chatId);
      const json: string = JSON.stringify({
        displayName: displayName,
        personaText: personaText
      });
      prefs.put(key, json);
      prefs.flush();
    }).catch((): void => {
      // ignore
    });
  } catch (e) {
    // ignore
  }
}
