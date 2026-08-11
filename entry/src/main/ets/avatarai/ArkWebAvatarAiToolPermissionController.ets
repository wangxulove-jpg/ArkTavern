import { Logger } from '../utils/Logger';
/**
 * ArkWebAvatarAiToolPermissionController — Avatar AI 工具权限控制器 (Phase 4A-3)
 *
 * 职责:
 *   - 管理当前聊天页面的 Avatar Tool Calling 权限模式
 *   - 校验工具调用是否被当前权限允许
 *   - 权限降级时阻止后续工具调用 (不删除资产/不修改模型)
 *   - 页面退出时恢复 DENY, 清除 Tool Calling 临时状态
 *
 * 权限模式:
 *   - DENY (默认): 不注入任何 Avatar 工具
 *   - READ_ONLY: 只注入 avatar_list_capabilities + avatar_get_state
 *   - CONTROL_THIS_CHAT: 注入全部四个工具
 *
 * 持久化策略:
 *   - 只在当前聊天页面生命周期内保存
 *   - 不写入数据库 / Preferences / 云端账户 / 角色卡 / 聊天消息
 *   - 页面退出: 权限恢复 DENY, 清除 Tool Calling 临时状态
 *
 * 降级策略:
 *   - CONTROL_THIS_CHAT → DENY: 阻止后续工具调用, 不删除资产, 不修改模型
 *   - 当前正在执行的 AI 演出可调用 cancelCurrent('AI_PERMISSION_REVOKED')
 *   - 但不得停止用户通过 AI 面板手动发起的演出
 *
 * Reference:
 *   - AGENTS.md Phase 4A-3 §权限控制
 */

import {
  ArkWebAvatarAiToolName,
  ArkWebAvatarAiToolErrorCode,
  ArkWebAvatarAiToolPermissionModeConst,
  DEFAULT_AVATAR_TOOL_PERMISSION
} from './ArkWebAvatarAiToolTypes';

/**
 * Avatar AI 工具权限控制器。
 *
 * 每个 ChatPage 实例持有一个 PermissionController,
 * 页面 aboutToAppear 时创建, aboutToDisappear 时 dispose。
 */
export class ArkWebAvatarAiToolPermissionController {
  /** 当前权限模式 (默认 DENY) */
  private currentMode: string = DEFAULT_AVATAR_TOOL_PERMISSION;

  /** 是否已销毁 */
  private disposed: boolean = false;

  /** 权限变更监听器 (供 AI 面板显示更新) */
  private modeChangeListener: ((mode: string) => void) | null = null;

  /**
   * 获取当前权限模式。
   */
  getPermissionMode(): string {
    if (this.disposed) {
      return ArkWebAvatarAiToolPermissionModeConst.DENY;
    }
    return this.currentMode;
  }

  /**
   * 设置权限模式。
   *
   * 降级时:
   *   - CONTROL_THIS_CHAT → DENY/READ_ONLY: 阻止后续工具调用
   *   - 不删除资产, 不修改模型
   *   - 当前正在执行的 AI 演出可由调用方调用 cancelCurrent('AI_PERMISSION_REVOKED')
   *
   * @param mode 目标权限模式
   * @param onDowngrade 回调, 当权限降级时触发 (调用方负责停止 AI 演出)
   */
  setPermissionMode(
    mode: string,
    onDowngrade?: () => void
  ): void {
    if (this.disposed) {
      return;
    }

    const oldMode: string = this.currentMode;

    // 校验 mode 合法性
    if (mode !== ArkWebAvatarAiToolPermissionModeConst.DENY
      && mode !== ArkWebAvatarAiToolPermissionModeConst.READ_ONLY
      && mode !== ArkWebAvatarAiToolPermissionModeConst.CONTROL_THIS_CHAT) {
      Logger.warn(`setPermissionMode invalid mode: ${mode}, ignored`);
      return;
    }

    if (oldMode === mode) {
      return;
    }

    this.currentMode = mode;
    Logger.debug(`permission changed: ${oldMode} → ${mode}`);

    // 权限降级 (CONTROL_THIS_CHAT → DENY/READ_ONLY) 时触发回调
    const isDowngrade: boolean =
      oldMode === ArkWebAvatarAiToolPermissionModeConst.CONTROL_THIS_CHAT
      && (mode === ArkWebAvatarAiToolPermissionModeConst.DENY
        || mode === ArkWebAvatarAiToolPermissionModeConst.READ_ONLY);
    if (isDowngrade && onDowngrade !== undefined) {
      try {
        onDowngrade();
      } catch (e) {
        Logger.warn('onDowngrade threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
    }

    // 通知监听器
    if (this.modeChangeListener !== null) {
      try {
        this.modeChangeListener(mode);
      } catch (e) {
        Logger.warn('modeChangeListener threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
    }
  }

  /**
   * 校验工具调用是否被当前权限允许。
   *
   * @param toolName 工具名称
   * @returns 允许返回 null, 拒绝返回 [errorCode, errorMessage]
   */
  checkToolAllowed(toolName: string): [string, string] | null {
    if (this.disposed) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_DISPOSED,
        'PermissionController disposed'];
    }

    // DENY: 拒绝所有工具
    if (this.currentMode === ArkWebAvatarAiToolPermissionModeConst.DENY) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_PERMISSION_DENIED,
        `permission=DENY, tool=${toolName} denied`];
    }

    // READ_ONLY: 只允许读取工具
    if (this.currentMode === ArkWebAvatarAiToolPermissionModeConst.READ_ONLY) {
      if (toolName === ArkWebAvatarAiToolName.AVATAR_LIST_CAPABILITIES
        || toolName === ArkWebAvatarAiToolName.AVATAR_GET_STATE) {
        return null;
      }
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_PERMISSION_DENIED,
        `permission=READ_ONLY, tool=${toolName} denied`];
    }

    // CONTROL_THIS_CHAT: 允许全部四个工具
    // (工具名合法性由 Registry.validateToolName 保证, 这里不重复校验)
    return null;
  }

  /**
   * 判断当前权限是否允许注入工具。
   *
   * @returns DENY 返回 false, READ_ONLY/CONTROL_THIS_CHAT 返回 true
   */
  canInjectTools(): boolean {
    if (this.disposed) {
      return false;
    }
    return this.currentMode !== ArkWebAvatarAiToolPermissionModeConst.DENY;
  }

  /**
   * 判断当前权限是否允许执行演出 (avatar_perform / avatar_stop)。
   */
  canControlAvatar(): boolean {
    if (this.disposed) {
      return false;
    }
    return this.currentMode === ArkWebAvatarAiToolPermissionModeConst.CONTROL_THIS_CHAT;
  }

  /**
   * 设置权限模式变更监听器 (供 AI 面板显示更新)。
   */
  setModeChangeListener(listener: (mode: string) => void): void {
    this.modeChangeListener = listener;
  }

  /**
   * 销毁 (恢复 DENY, 清除监听器)。
   *
   * 页面 aboutToDisappear 时调用。
   * 不停止用户手动发起的演出, 只阻止后续 AI 工具调用。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.currentMode = ArkWebAvatarAiToolPermissionModeConst.DENY;
    this.modeChangeListener = null;
    Logger.debug('dispose, permission reset to DENY');
  }
}
