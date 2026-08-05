/**
 * GROUP-CHAT-TARGET-1: @角色回复模式按群聊持久化。
 *
 * 存储位置:Preferences 'ArkTavernSettings'
 * Key: group_reply_mode_{chatId}
 * Value: 'one_shot' | 'persistent'
 */

import { preferences } from '@kit.ArkData';

const STORE_NAME: string = 'ArkTavernSettings';
const MODE_KEY_PREFIX: string = 'group_reply_mode_';

export type GroupReplyTargetModeSetting = 'one_shot' | 'persistent';

/** 加载指定群聊的 @角色回复模式,异常时返回默认 'one_shot' */
export async function loadGroupReplyTargetMode(chatId: string): Promise<GroupReplyTargetModeSetting> {
  try {
    const ctx: Context = getContext();
    const prefs: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    const raw: string = (prefs.getSync(MODE_KEY_PREFIX + chatId, 'one_shot')) as string;
    if (raw === 'persistent') {
      return 'persistent';
    }
    return 'one_shot';
  } catch (_e) {
    return 'one_shot';
  }
}

/** 持久化指定群聊的 @角色回复模式 */
export function persistGroupReplyTargetMode(chatId: string, mode: GroupReplyTargetModeSetting): void {
  try {
    const ctx: Context = getContext();
    preferences.getPreferences(ctx, STORE_NAME).then((prefs: preferences.Preferences): void => {
      prefs.put(MODE_KEY_PREFIX + chatId, mode);
      prefs.flush();
    }).catch((): void => {
      // silently ignore
    });
  } catch (_e) {
    // silently ignore
  }
}
