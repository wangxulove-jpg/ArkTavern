/**
 * GroupRuntimeRegistry 本地单元测试(REG-01 ~ REG-10)
 *
 * 验证应用级多人运行锁:
 * - 首次获取 / 同运行幂等获取
 * - 同群聊不同 operationId / 不同群聊拒绝
 * - 匹配释放 / 旧 operation 迟到释放 / 错误 chatId 释放 / 重复释放
 * - assertChatMutable 互斥
 * - complete/stop/error 清理后可重新获取
 *
 * 使用真实 GroupRuntimeRegistry(纯逻辑,无 RDB / 网络)。
 */

import { describe, it, expect } from '@ohos/hypium';
import { GroupRuntimeRegistry } from '../main/ets/services/groupchat/GroupRuntimeRegistry';
import { GroupRoundState } from '../main/ets/services/groupchat/GroupRoundTypes';
import { CHAT_A, CHAT_B } from './GroupRuntimeTestFakes';

function expectThrows(fn: () => void): boolean {
  try {
    fn();
    return false;
  } catch (e) {
    return true;
  }
}

export default function groupRuntimeRegistryTest() {
  describe('GroupRuntimeRegistryTest', () => {

    it('REG_01_first_acquire_success', 0, () => {
      const reg: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      expect(reg.getChatId()).assertEqual(CHAT_A);
      expect(reg.getRoundId()).assertEqual('round-1');
      expect(reg.getOperationId()).assertEqual(1);
      expect(reg.getState()).assertEqual(GroupRoundState.Generating);
      expect(reg.isAnyGroupRunning()).assertTrue();
      expect(reg.isChatRunning(CHAT_A)).assertTrue();
      expect(reg.isCurrentRun(CHAT_A, 'round-1', 1)).assertTrue();
    });

    it('REG_02_idempotent_acquire_same_run', 0, () => {
      const reg: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      expect(reg.getOperationId()).assertEqual(1);
      expect(reg.getChatId()).assertEqual(CHAT_A);
      expect(reg.getRoundId()).assertEqual('round-1');
      // 幂等获取只更新状态,不创建第二份运行
      expect(reg.isAnyGroupRunning()).assertTrue();
    });

    it('REG_03_same_chat_different_operation_rejected', 0, () => {
      const reg: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      const rejected: boolean = expectThrows((): void => {
        reg.acquire(CHAT_A, 'round-2', 2, GroupRoundState.Generating);
      });
      expect(rejected).assertTrue();
      // 原 op1 仍保留
      expect(reg.getOperationId()).assertEqual(1);
      expect(reg.getChatId()).assertEqual(CHAT_A);
    });

    it('REG_04_different_chat_acquire_rejected', 0, () => {
      const reg: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      const rejected: boolean = expectThrows((): void => {
        reg.acquire(CHAT_B, 'round-b', 2, GroupRoundState.Generating);
      });
      expect(rejected).assertTrue();
      // Registry 仍属于 A
      expect(reg.getChatId()).assertEqual(CHAT_A);
      expect(reg.getOperationId()).assertEqual(1);
    });

    it('REG_05_matched_release_empties', 0, () => {
      const reg: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);
      reg.release(CHAT_A, 1);

      expect(reg.isAnyGroupRunning()).assertFalse();
      expect(reg.getChatId()).assertEqual('');
      expect(reg.getOperationId()).assertEqual(0);
      expect(reg.getState()).assertEqual(GroupRoundState.Idle);
    });

    it('REG_06_old_operation_release_cannot_clear_new', 0, () => {
      const reg: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);
      // op1 释放
      reg.release(CHAT_A, 1);
      // op2 获取
      reg.acquire(CHAT_A, 'round-2', 2, GroupRoundState.Generating);

      // 旧 op1 迟到释放不得清除 op2
      reg.release(CHAT_A, 1);
      expect(reg.getOperationId()).assertEqual(2);
      expect(reg.getChatId()).assertEqual(CHAT_A);
      expect(reg.isAnyGroupRunning()).assertTrue();
    });

    it('REG_07_wrong_chat_release_ignored', 0, () => {
      const reg: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      reg.release(CHAT_B, 1);
      expect(reg.getOperationId()).assertEqual(1);
      expect(reg.getChatId()).assertEqual(CHAT_A);

      reg.release(CHAT_A, 999);
      expect(reg.getOperationId()).assertEqual(1);
    });

    it('REG_08_double_release_idempotent', 0, () => {
      const reg: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);
      reg.release(CHAT_A, 1);
      // 第二次 release 幂等,不崩溃
      reg.release(CHAT_A, 1);

      expect(reg.isAnyGroupRunning()).assertFalse();
      // 后续 acquire 正常
      reg.acquire(CHAT_B, 'round-b', 2, GroupRoundState.Generating);
      expect(reg.getChatId()).assertEqual(CHAT_B);
      expect(reg.getOperationId()).assertEqual(2);
    });

    it('REG_09_assertChatMutable_while_running', 0, () => {
      const reg: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);

      // 修改当前群聊被拒绝
      const rejectedCurrent: boolean = expectThrows((): void => {
        reg.assertChatMutable(CHAT_A);
      });
      expect(rejectedCurrent).assertTrue();

      // 修改其他群聊:按当前代码规则,不处于运行中的群聊允许修改
      // assertChatMutable 只拦截 running 的 chatId
      let otherOk: boolean = true;
      try {
        reg.assertChatMutable(CHAT_B);
      } catch (e) {
        otherOk = false;
      }
      expect(otherOk).assertTrue();
    });

    it('REG_10_reacquire_after_complete_stop_error', 0, () => {
      // complete 后重新获取
      const reg1: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg1.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);
      reg1.updateState(CHAT_A, 1, GroupRoundState.Completed);
      reg1.release(CHAT_A, 1);
      reg1.acquire(CHAT_B, 'round-b', 2, GroupRoundState.Generating);
      expect(reg1.getChatId()).assertEqual(CHAT_B);

      // stop 后重新获取
      const reg2: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg2.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);
      reg2.release(CHAT_A, 1);
      reg2.acquire(CHAT_B, 'round-b', 2, GroupRoundState.Generating);
      expect(reg2.getChatId()).assertEqual(CHAT_B);

      // error 后重新获取
      const reg3: GroupRuntimeRegistry = new GroupRuntimeRegistry();
      reg3.acquire(CHAT_A, 'round-1', 1, GroupRoundState.Generating);
      reg3.updateState(CHAT_A, 1, GroupRoundState.Failed);
      reg3.release(CHAT_A, 1);
      reg3.acquire(CHAT_B, 'round-b', 2, GroupRoundState.Generating);
      expect(reg3.getChatId()).assertEqual(CHAT_B);
    });
  });
}
