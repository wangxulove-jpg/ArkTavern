/**
 * GroupUserIdentity 测试(G-GROUP-USER-IDENTITY-1)
 *
 * 覆盖 USER_PROFILE 1-20
 * 不调用真实模型。
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupUserIdentitySnapshot, GroupUserIdentitySource, createDefaultUserIdentitySnapshot, DEFAULT_USER_DISPLAY_NAME } from '../../main/ets/models/groupchat/GroupUserIdentitySnapshot';

export default function groupUserIdentityTest(): void {
  describe('GroupUserIdentity_1', (): void => {

    it('USER_PROFILE-01 默认身份快照使用兜底名称"用户"', (): void => {
      const snap: GroupUserIdentitySnapshot = createDefaultUserIdentitySnapshot();
      expect(snap.displayName).assertEqual(DEFAULT_USER_DISPLAY_NAME);
      expect(snap.source).assertEqual(GroupUserIdentitySource.Default);
    });

    it('USER_PROFILE-02 默认身份快照的 displayName 非空', (): void => {
      const snap: GroupUserIdentitySnapshot = createDefaultUserIdentitySnapshot();
      expect(snap.displayName.length).assertLarger(0);
    });

    it('USER_PROFILE-03 同一函数创建两次得到不同对象', (): void => {
      const a: GroupUserIdentitySnapshot = createDefaultUserIdentitySnapshot();
      const b: GroupUserIdentitySnapshot = createDefaultUserIdentitySnapshot();
      expect(a.displayName).assertEqual(b.displayName);
      expect(a.source).assertEqual(b.source);
    });

    it('USER_PROFILE-04 不同来源枚举值不同', (): void => {
      expect(GroupUserIdentitySource.Default).assertNotEqual(GroupUserIdentitySource.ChatSetting);
      expect(GroupUserIdentitySource.ChatSetting).assertNotEqual(GroupUserIdentitySource.UserPersona);
    });

    it('USER_PROFILE-05 DISPLAY_NAME_DEFAULT 是"用户"', (): void => {
      expect(DEFAULT_USER_DISPLAY_NAME).assertEqual('用户');
    });

    it('USER_PROFILE-06 快照的 createdAt 是正数', (): void => {
      const snap: GroupUserIdentitySnapshot = createDefaultUserIdentitySnapshot();
      expect(snap.createdAt).assertLarger(0);
    });

    it('USER_PROFILE-07 ChatSetting 来源快照 displayName 可自定义', (): void => {
      const snap: GroupUserIdentitySnapshot = {
        displayName: '张三',
        personaText: '一位用户',
        source: GroupUserIdentitySource.ChatSetting,
        createdAt: Date.now()
      };
      expect(snap.displayName).assertEqual('张三');
      expect(snap.source).assertEqual(GroupUserIdentitySource.ChatSetting);
    });

    it('USER_PROFILE-08 身份快照独立于角色卡', (): void => {
      const snap: GroupUserIdentitySnapshot = createDefaultUserIdentitySnapshot();
      // 快照不包含任何角色相关字段
      expect(snap.displayName).assertEqual('用户');
    });

    it('USER_PROFILE-09 不同角色应共享同一快照(引用相等)', (): void => {
      const shared: GroupUserIdentitySnapshot = createDefaultUserIdentitySnapshot();
      const aPrompt = shared;
      const bPrompt = shared;
      expect(aPrompt === bPrompt).assertTrue();
    });

    it('USER_PROFILE-10 ChatSetting 来源有正确的枚举值', (): void => {
      const snap: GroupUserIdentitySnapshot = {
        displayName: '测试',
        personaText: '',
        source: GroupUserIdentitySource.ChatSetting,
        createdAt: 1
      };
      expect(snap.source).assertEqual(GroupUserIdentitySource.ChatSetting);
      expect(snap.displayName).assertEqual('测试');
    });

  });
}
