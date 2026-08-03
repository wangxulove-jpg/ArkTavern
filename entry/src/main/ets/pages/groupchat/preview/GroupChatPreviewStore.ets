/**
 * GroupChatPreviewStore 多人聊天预览状态容器
 *
 * G-UI-1 阶段专用:页面内预览状态的内存容器。
 *
 * 重要:这不是 Repository,不持久化,不读写数据库。
 * 仅用于在多个多人聊天页面之间共享同一份预览会话状态
 * (首页列表、创建页、聊天页、成员管理、设置)。
 *
 * 跨页面 ID 传递:通过 AppStorage 的 PENDING_GROUP_CHAT_ID_KEY。
 *
 * 删除条件:G-DATA-1 接入真实数据库后,本文件整体删除,
 * 由 GroupChatRepository + GroupChatService 替代。
 */

import { generateUuid } from '../../../utils/Uuid';
import {
  GroupChatPreviewMember,
  GroupChatPreviewMessage,
  GroupChatPreviewSession,
  GroupMemberPreviewStatus,
  GroupRoundPreviewStatus,
  GroupReplyMode,
  GroupFailurePolicy
} from './GroupChatPreviewModels';
import {
  PREVIEW_CHARACTERS,
  PREVIEW_MEMBER_MIN,
  PREVIEW_MEMBER_MAX,
  buildPreviewMember,
  buildPreviewMessage,
  buildSeedPreviewSessions,
  composeDefaultTitle,
  getPreviewCharacterById,
  getSampleReply
} from './GroupChatPreviewData';

/** AppStorage 中待进入的群聊 ID(由首页/创建页写入,GroupChatPage 读取) */
export const PENDING_GROUP_CHAT_ID_KEY: string = 'pendingGroupChatId';

/** 复制成员(显式属性复制,ArkTS 不支持对象展开) */
function cloneMember(m: GroupChatPreviewMember): GroupChatPreviewMember {
  return {
    id: m.id,
    characterId: m.characterId,
    name: m.name,
    avatarUri: m.avatarUri,
    order: m.order,
    status: m.status,
    enabled: m.enabled
  };
}

/** 复制成员并替换部分字段 */
function cloneMemberWith(
  m: GroupChatPreviewMember,
  status: GroupMemberPreviewStatus,
  enabled?: boolean
): GroupChatPreviewMember {
  return {
    id: m.id,
    characterId: m.characterId,
    name: m.name,
    avatarUri: m.avatarUri,
    order: m.order,
    status: status,
    enabled: enabled !== undefined ? enabled : m.enabled
  };
}

/** 复制消息(显式属性复制) */
function cloneMessage(m: GroupChatPreviewMessage): GroupChatPreviewMessage {
  return {
    id: m.id,
    senderKind: m.senderKind,
    senderCharacterId: m.senderCharacterId,
    senderName: m.senderName,
    avatarUri: m.avatarUri,
    content: m.content,
    status: m.status,
    createdAt: m.createdAt,
    updatedAt: m.updatedAt
  };
}

/** 复制消息并替换部分字段 */
function cloneMessageWith(
  m: GroupChatPreviewMessage,
  status: string,
  updatedAt: number
): GroupChatPreviewMessage {
  return {
    id: m.id,
    senderKind: m.senderKind,
    senderCharacterId: m.senderCharacterId,
    senderName: m.senderName,
    avatarUri: m.avatarUri,
    content: m.content,
    status: status,
    createdAt: m.createdAt,
    updatedAt: updatedAt
  };
}

/** 复制会话(显式属性复制) */
function cloneSession(s: GroupChatPreviewSession): GroupChatPreviewSession {
  const members: GroupChatPreviewMember[] = s.members.map(
    (m: GroupChatPreviewMember): GroupChatPreviewMember => cloneMember(m)
  );
  const messages: GroupChatPreviewMessage[] = s.messages.map(
    (m: GroupChatPreviewMessage): GroupChatPreviewMessage => cloneMessage(m)
  );
  return {
    id: s.id,
    title: s.title,
    members: members,
    messages: messages,
    roundStatus: s.roundStatus,
    currentGeneratingOrder: s.currentGeneratingOrder,
    completedCount: s.completedCount,
    totalCount: s.totalCount,
    replyMode: s.replyMode,
    failurePolicy: s.failurePolicy,
    updatedAt: s.updatedAt
  };
}

/**
 * 预览状态容器(模块级单例)。
 *
 * 使用方式:
 * - 页面 aboutToAppear 时调用 getSnapshot() 读取当前快照
 * - 页面执行操作后调用对应 mutate 方法,再重新 getSnapshot()
 * - @State 持有快照引用,mutate 后赋值新快照触发刷新
 */
class GroupChatPreviewStoreImpl {
  private sessions: GroupChatPreviewSession[] = [];
  private initialized: boolean = false;

  /** 懒初始化(首次访问时填充种子数据) */
  private ensureInit(): void {
    if (this.initialized) {
      return;
    }
    this.sessions = buildSeedPreviewSessions();
    this.initialized = true;
  }

  /** 获取全部会话快照(新数组,修改不影响内部状态) */
  listSessions(): GroupChatPreviewSession[] {
    this.ensureInit();
    return this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => cloneSession(s));
  }

  /** 获取指定会话(不存在返回 null) */
  getSession(id: string): GroupChatPreviewSession | null {
    this.ensureInit();
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === id) {
        return cloneSession(this.sessions[i]);
      }
    }
    return null;
  }

  /**
   * 创建新预览群聊。
   * @param title 群聊名称(空时自动生成)
   * @param characterIds 按选择顺序的角色 ID 列表
   * @returns 新建会话的 ID
   */
  createSession(title: string, characterIds: string[]): string {
    this.ensureInit();
    const clamped: string[] = characterIds.slice(0, PREVIEW_MEMBER_MAX);
    if (clamped.length < PREVIEW_MEMBER_MIN) {
      throw new Error('至少需要 ' + String(PREVIEW_MEMBER_MIN) + ' 位角色');
    }
    const members: GroupChatPreviewMember[] = [];
    const names: string[] = [];
    for (let i = 0; i < clamped.length; i++) {
      const char = getPreviewCharacterById(clamped[i]);
      if (char === null) {
        continue;
      }
      members.push(buildPreviewMember(char, i, GroupMemberPreviewStatus.Waiting, true));
      names.push(char.name);
    }
    if (members.length < PREVIEW_MEMBER_MIN) {
      throw new Error('有效角色不足');
    }
    const finalTitle: string = title.trim().length > 0 ? title.trim() : composeDefaultTitle(names);
    const id: string = 'group_' + generateUuid();
    const now: number = Date.now();
    const session: GroupChatPreviewSession = {
      id: id,
      title: finalTitle,
      members: members,
      messages: [],
      roundStatus: GroupRoundPreviewStatus.Idle,
      currentGeneratingOrder: -1,
      completedCount: 0,
      totalCount: members.length,
      replyMode: GroupReplyMode.Sequential,
      failurePolicy: GroupFailurePolicy.StopRound,
      updatedAt: now
    };
    this.sessions = [session].concat(this.sessions);
    return id;
  }

  /** 重命名 */
  renameSession(id: string, title: string): void {
    this.ensureInit();
    const trimmed: string = title.trim();
    if (trimmed.length === 0) {
      return;
    }
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      const next: GroupChatPreviewSession = cloneSession(s);
      next.title = trimmed;
      next.updatedAt = Date.now();
      return next;
    });
  }

  /** 删除预览群聊 */
  deleteSession(id: string): void {
    this.ensureInit();
    this.sessions = this.sessions.filter((s: GroupChatPreviewSession): boolean => s.id !== id);
  }

  /** 清空指定群聊的消息(预览用) */
  clearMessages(id: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      const next: GroupChatPreviewSession = cloneSession(s);
      next.messages = [];
      next.roundStatus = GroupRoundPreviewStatus.Idle;
      next.currentGeneratingOrder = -1;
      next.completedCount = 0;
      next.updatedAt = Date.now();
      return next;
    });
  }

  /**
   * 追加用户消息并开始模拟生成轮次。
   * 将所有启用成员重置为 Waiting,roundStatus 置为 Generating。
   */
  appendUserMessage(id: string, content: string): void {
    this.ensureInit();
    const trimmed: string = content.trim();
    if (trimmed.length === 0) {
      return;
    }
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      const now: number = Date.now();
      const userMsg: GroupChatPreviewMessage = buildPreviewMessage(
        'msg_' + generateUuid(), 'user', '', '你', '', trimmed, 'completed', now
      );
      const enabledMembers: GroupChatPreviewMember[] = s.members.filter(
        (m: GroupChatPreviewMember): boolean => m.enabled
      );
      const next: GroupChatPreviewSession = cloneSession(s);
      next.messages = s.messages.concat([userMsg]);
      next.updatedAt = now;
      if (enabledMembers.length === 0) {
        return next;
      }
      const nextOrder: number = enabledMembers[0].order;
      next.members = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (!m.enabled) {
            return cloneMember(m);
          }
          if (m.order === nextOrder) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Generating);
          }
          return cloneMemberWith(m, GroupMemberPreviewStatus.Waiting);
        }
      );
      next.roundStatus = GroupRoundPreviewStatus.Generating;
      next.currentGeneratingOrder = nextOrder;
      next.completedCount = 0;
      next.totalCount = enabledMembers.length;
      return next;
    });
  }

  /**
   * 完成当前正在生成的成员,并推进到下一位。
   * - 当前成员状态置 Completed,追加其示例回复消息
   * - 若有下一位启用成员,置为 Generating
   * - 若无下一位,roundStatus 置 Completed
   */
  advanceCurrentMember(id: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id || s.roundStatus !== GroupRoundPreviewStatus.Generating) {
        return s;
      }
      const now: number = Date.now();
      const currentOrder: number = s.currentGeneratingOrder;
      const members: GroupChatPreviewMember[] = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (m.order === currentOrder) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Completed);
          }
          return cloneMember(m);
        }
      );
      const currentMember: GroupChatPreviewMember | undefined = s.members.find(
        (m: GroupChatPreviewMember): boolean => m.order === currentOrder
      );
      const newMessages: GroupChatPreviewMessage[] = s.messages.slice();
      if (currentMember !== undefined) {
        newMessages.push(buildPreviewMessage(
          'msg_' + generateUuid(), 'character', currentMember.characterId,
          currentMember.name, currentMember.avatarUri,
          getSampleReply(currentMember.characterId), 'completed', now
        ));
      }
      const nextEnabled: GroupChatPreviewMember | undefined = members.find(
        (m: GroupChatPreviewMember): boolean => m.enabled && m.order > currentOrder && m.status === GroupMemberPreviewStatus.Waiting
      );
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.messages = newMessages;
      next.completedCount = s.completedCount + 1;
      next.updatedAt = now;
      if (nextEnabled !== undefined) {
        const nextOrder: number = nextEnabled.order;
        next.members = members.map(
          (m: GroupChatPreviewMember): GroupChatPreviewMember => {
            if (m.order === nextOrder) {
              return cloneMemberWith(m, GroupMemberPreviewStatus.Generating);
            }
            return cloneMember(m);
          }
        );
        next.currentGeneratingOrder = nextOrder;
        return next;
      }
      next.roundStatus = GroupRoundPreviewStatus.Completed;
      next.currentGeneratingOrder = -1;
      return next;
    });
  }

  /** 模拟当前成员回复失败 */
  failCurrentMember(id: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id || s.roundStatus !== GroupRoundPreviewStatus.Generating) {
        return s;
      }
      const now: number = Date.now();
      const currentOrder: number = s.currentGeneratingOrder;
      const members: GroupChatPreviewMember[] = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (m.order === currentOrder) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Failed);
          }
          return cloneMember(m);
        }
      );
      const currentMember: GroupChatPreviewMember | undefined = s.members.find(
        (m: GroupChatPreviewMember): boolean => m.order === currentOrder
      );
      const newMessages: GroupChatPreviewMessage[] = s.messages.slice();
      if (currentMember !== undefined) {
        newMessages.push(buildPreviewMessage(
          'msg_' + generateUuid(), 'character', currentMember.characterId,
          currentMember.name, currentMember.avatarUri,
          '', 'failed', now
        ));
      }
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.messages = newMessages;
      next.roundStatus = GroupRoundPreviewStatus.Failed;
      next.updatedAt = now;
      return next;
    });
  }

  /**
   * 重试当前失败成员。
   * - 将 Failed 成员重新置为 Generating,追加 streaming 占位消息
   * - roundStatus 置回 Generating
   */
  retryCurrentMember(id: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id || s.roundStatus !== GroupRoundPreviewStatus.Failed) {
        return s;
      }
      const now: number = Date.now();
      const failedMember: GroupChatPreviewMember | undefined = s.members.find(
        (m: GroupChatPreviewMember): boolean => m.status === GroupMemberPreviewStatus.Failed
      );
      if (failedMember === undefined) {
        return s;
      }
      const failedOrder: number = failedMember.order;
      const members: GroupChatPreviewMember[] = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (m.order === failedOrder) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Generating);
          }
          return cloneMember(m);
        }
      );
      const streamingMsg: GroupChatPreviewMessage = buildPreviewMessage(
        'msg_' + generateUuid(), 'character', failedMember.characterId,
        failedMember.name, failedMember.avatarUri,
        '', 'streaming', now
      );
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.messages = s.messages.concat([streamingMsg]);
      next.roundStatus = GroupRoundPreviewStatus.Generating;
      next.currentGeneratingOrder = failedOrder;
      next.updatedAt = now;
      return next;
    });
  }

  /** 停止本轮(用户手动停止) */
  stopRound(id: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id || s.roundStatus !== GroupRoundPreviewStatus.Generating) {
        return s;
      }
      const now: number = Date.now();
      const members: GroupChatPreviewMember[] = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (m.status === GroupMemberPreviewStatus.Generating) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Completed);
          }
          return cloneMember(m);
        }
      );
      const messages: GroupChatPreviewMessage[] = s.messages.map(
        (m: GroupChatPreviewMessage): GroupChatPreviewMessage => {
          if (m.status === 'streaming') {
            return cloneMessageWith(m, 'cancelled', now);
          }
          return cloneMessage(m);
        }
      );
      const completed: number = members.filter(
        (m: GroupChatPreviewMember): boolean => m.status === GroupMemberPreviewStatus.Completed
      ).length;
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.messages = messages;
      next.roundStatus = GroupRoundPreviewStatus.Cancelled;
      next.currentGeneratingOrder = -1;
      next.completedCount = completed;
      next.updatedAt = now;
      return next;
    });
  }

  /** 结束本轮(失败后用户选择结束) */
  endRound(id: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      const now: number = Date.now();
      const members: GroupChatPreviewMember[] = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (m.status === GroupMemberPreviewStatus.Failed || m.status === GroupMemberPreviewStatus.Generating) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Completed);
          }
          return cloneMember(m);
        }
      );
      const completed: number = members.filter(
        (m: GroupChatPreviewMember): boolean => m.status === GroupMemberPreviewStatus.Completed
      ).length;
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.roundStatus = GroupRoundPreviewStatus.Cancelled;
      next.currentGeneratingOrder = -1;
      next.completedCount = completed;
      next.updatedAt = now;
      return next;
    });
  }

  /** 重置整个会话到空闲态(保留消息,重置成员状态) */
  resetRound(id: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      const now: number = Date.now();
      const members: GroupChatPreviewMember[] = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (m.enabled) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Waiting);
          }
          return cloneMember(m);
        }
      );
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.roundStatus = GroupRoundPreviewStatus.Idle;
      next.currentGeneratingOrder = -1;
      next.completedCount = 0;
      next.updatedAt = now;
      return next;
    });
  }

  // ===== 成员管理 =====

  /** 切换成员启用/停用 */
  setMemberEnabled(id: string, memberId: string, enabled: boolean): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      const enabledCount: number = s.members.filter(
        (m: GroupChatPreviewMember): boolean => m.enabled
      ).length;
      // 停用时至少保留 2 个启用
      if (!enabled && enabledCount <= PREVIEW_MEMBER_MIN) {
        return s;
      }
      const members: GroupChatPreviewMember[] = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (m.id === memberId) {
            const newStatus: GroupMemberPreviewStatus = enabled
              ? GroupMemberPreviewStatus.Waiting
              : GroupMemberPreviewStatus.Disabled;
            return cloneMemberWith(m, newStatus, enabled);
          }
          return cloneMember(m);
        }
      );
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.updatedAt = Date.now();
      return next;
    });
  }

  /** 上移成员(与上一成员交换 order) */
  moveMemberUp(id: string, memberId: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      const idx: number = s.members.findIndex((m: GroupChatPreviewMember): boolean => m.id === memberId);
      if (idx <= 0) {
        return s;
      }
      const members: GroupChatPreviewMember[] = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => cloneMember(m)
      );
      const a: GroupChatPreviewMember = members[idx - 1];
      const b: GroupChatPreviewMember = members[idx];
      // 交换 order
      members[idx - 1] = {
        id: b.id,
        characterId: b.characterId,
        name: b.name,
        avatarUri: b.avatarUri,
        order: a.order,
        status: b.status,
        enabled: b.enabled
      };
      members[idx] = {
        id: a.id,
        characterId: a.characterId,
        name: a.name,
        avatarUri: a.avatarUri,
        order: b.order,
        status: a.status,
        enabled: a.enabled
      };
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.updatedAt = Date.now();
      return next;
    });
  }

  /** 下移成员(与下一成员交换 order) */
  moveMemberDown(id: string, memberId: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      const idx: number = s.members.findIndex((m: GroupChatPreviewMember): boolean => m.id === memberId);
      if (idx < 0 || idx >= s.members.length - 1) {
        return s;
      }
      const members: GroupChatPreviewMember[] = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => cloneMember(m)
      );
      const a: GroupChatPreviewMember = members[idx];
      const b: GroupChatPreviewMember = members[idx + 1];
      // 交换 order
      members[idx] = {
        id: b.id,
        characterId: b.characterId,
        name: b.name,
        avatarUri: b.avatarUri,
        order: a.order,
        status: b.status,
        enabled: b.enabled
      };
      members[idx + 1] = {
        id: a.id,
        characterId: a.characterId,
        name: a.name,
        avatarUri: a.avatarUri,
        order: b.order,
        status: a.status,
        enabled: a.enabled
      };
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.updatedAt = Date.now();
      return next;
    });
  }

  /** 移除成员(至少保留 2 个) */
  removeMember(id: string, memberId: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      if (s.members.length <= PREVIEW_MEMBER_MIN) {
        return s;
      }
      const members: GroupChatPreviewMember[] = s.members
        .filter((m: GroupChatPreviewMember): boolean => m.id !== memberId)
        .map((m: GroupChatPreviewMember, i: number): GroupChatPreviewMember => {
          return {
            id: m.id,
            characterId: m.characterId,
            name: m.name,
            avatarUri: m.avatarUri,
            order: i,
            status: m.status,
            enabled: m.enabled
          };
        });
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = members;
      next.totalCount = members.length;
      next.updatedAt = Date.now();
      return next;
    });
  }

  /** 添加预览角色到群聊 */
  addMember(id: string, characterId: string): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      if (s.members.length >= PREVIEW_MEMBER_MAX) {
        return s;
      }
      const char = getPreviewCharacterById(characterId);
      if (char === null) {
        return s;
      }
      const newMember: GroupChatPreviewMember = buildPreviewMember(
        char, s.members.length, GroupMemberPreviewStatus.Waiting, true
      );
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = s.members.concat([newMember]);
      next.totalCount = s.members.length + 1;
      next.updatedAt = Date.now();
      return next;
    });
  }

  // ===== 设置 =====

  /** 更新失败处理方式 */
  setFailurePolicy(id: string, policy: GroupFailurePolicy): void {
    this.ensureInit();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      const next: GroupChatPreviewSession = cloneSession(s);
      next.failurePolicy = policy;
      next.updatedAt = Date.now();
      return next;
    });
  }

  // ===== 预览状态切换(开发菜单用) =====

  /**
   * 切换到指定预览状态(开发菜单)。
   * mode: empty / normal / generating / cancelled / failed / long / members8
   */
  setPreviewMode(id: string, mode: string): void {
    this.ensureInit();
    const now: number = Date.now();
    this.sessions = this.sessions.map((s: GroupChatPreviewSession): GroupChatPreviewSession => {
      if (s.id !== id) {
        return s;
      }
      return this.applyPreviewMode(s, mode, now);
    });
  }

  private applyPreviewMode(s: GroupChatPreviewSession, mode: string, now: number): GroupChatPreviewSession {
    if (mode === 'empty') {
      const next: GroupChatPreviewSession = cloneSession(s);
      next.messages = [];
      next.roundStatus = GroupRoundPreviewStatus.Idle;
      next.currentGeneratingOrder = -1;
      next.completedCount = 0;
      next.members = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          const newStatus: GroupMemberPreviewStatus = m.enabled
            ? GroupMemberPreviewStatus.Waiting
            : GroupMemberPreviewStatus.Disabled;
          return cloneMemberWith(m, newStatus);
        }
      );
      next.updatedAt = now;
      return next;
    }
    if (mode === 'normal') {
      const alice: GroupChatPreviewMember = s.members[0];
      const kane: GroupChatPreviewMember = s.members.length > 1 ? s.members[1] : s.members[0];
      const msgs: GroupChatPreviewMessage[] = [
        buildPreviewMessage('pv_u', 'user', '', '你', '', '今天天气真不错,大家要不要出去走走?', 'completed', now - 300000),
        buildPreviewMessage('pv_c1', 'character', alice.characterId, alice.name, alice.avatarUri, getSampleReply(alice.characterId), 'completed', now - 240000),
        buildPreviewMessage('pv_c2', 'character', kane.characterId, kane.name, kane.avatarUri, getSampleReply(kane.characterId), 'completed', now - 180000)
      ];
      const next: GroupChatPreviewSession = cloneSession(s);
      next.messages = msgs;
      next.roundStatus = GroupRoundPreviewStatus.Idle;
      next.currentGeneratingOrder = -1;
      next.completedCount = 0;
      next.members = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          const newStatus: GroupMemberPreviewStatus = m.enabled
            ? GroupMemberPreviewStatus.Waiting
            : GroupMemberPreviewStatus.Disabled;
          return cloneMemberWith(m, newStatus);
        }
      );
      next.updatedAt = now;
      return next;
    }
    if (mode === 'generating') {
      const first: GroupChatPreviewMember = s.members.find(
        (m: GroupChatPreviewMember): boolean => m.enabled
      ) ?? s.members[0];
      const streamingMsg: GroupChatPreviewMessage = buildPreviewMessage(
        'pv_stream', 'character', first.characterId, first.name, first.avatarUri,
        '嗯,让我想想……', 'streaming', now
      );
      const next: GroupChatPreviewSession = cloneSession(s);
      next.messages = [
        buildPreviewMessage('pv_u2', 'user', '', '你', '', '大家有什么想法?', 'completed', now - 60000),
        streamingMsg
      ];
      next.roundStatus = GroupRoundPreviewStatus.Generating;
      next.currentGeneratingOrder = first.order;
      next.completedCount = 0;
      next.totalCount = s.members.filter((m: GroupChatPreviewMember): boolean => m.enabled).length;
      next.members = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (!m.enabled) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Disabled);
          }
          if (m.order === first.order) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Generating);
          }
          return cloneMemberWith(m, GroupMemberPreviewStatus.Waiting);
        }
      );
      next.updatedAt = now;
      return next;
    }
    if (mode === 'cancelled') {
      const next: GroupChatPreviewSession = cloneSession(s);
      next.roundStatus = GroupRoundPreviewStatus.Cancelled;
      next.currentGeneratingOrder = -1;
      next.completedCount = 1;
      next.totalCount = s.members.filter((m: GroupChatPreviewMember): boolean => m.enabled).length;
      next.members = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (!m.enabled) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Disabled);
          }
          return cloneMemberWith(m, GroupMemberPreviewStatus.Completed);
        }
      );
      next.updatedAt = now;
      return next;
    }
    if (mode === 'failed') {
      const first: GroupChatPreviewMember = s.members.find(
        (m: GroupChatPreviewMember): boolean => m.enabled
      ) ?? s.members[0];
      const next: GroupChatPreviewSession = cloneSession(s);
      next.roundStatus = GroupRoundPreviewStatus.Failed;
      next.currentGeneratingOrder = first.order;
      next.completedCount = 0;
      next.totalCount = s.members.filter((m: GroupChatPreviewMember): boolean => m.enabled).length;
      next.members = s.members.map(
        (m: GroupChatPreviewMember): GroupChatPreviewMember => {
          if (!m.enabled) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Disabled);
          }
          if (m.order === first.order) {
            return cloneMemberWith(m, GroupMemberPreviewStatus.Failed);
          }
          return cloneMemberWith(m, GroupMemberPreviewStatus.Waiting);
        }
      );
      next.updatedAt = now;
      return next;
    }
    if (mode === 'long') {
      const alice: GroupChatPreviewMember = s.members[0];
      const longContent: string = '这是一段很长的预览消息,用于验证长文本在消息列表中的显示效果。\n\n'
        + '包含多个段落、换行,以及较长的正文内容,确保气泡能够正确换行、'
        + '消息列表可滚动、不会被截断。\n\n'
        + '第三段:测试滚动边界。第四段:测试深色模式。第五段:测试安全区域。';
      const msgs: GroupChatPreviewMessage[] = [
        buildPreviewMessage('pv_lu', 'user', '', '你', '', '请给我讲一个完整的故事。', 'completed', now - 300000),
        buildPreviewMessage('pv_lc', 'character', alice.characterId, alice.name, alice.avatarUri, longContent, 'completed', now - 240000)
      ];
      const next: GroupChatPreviewSession = cloneSession(s);
      next.messages = msgs;
      next.roundStatus = GroupRoundPreviewStatus.Idle;
      next.currentGeneratingOrder = -1;
      next.updatedAt = now;
      return next;
    }
    if (mode === 'members8') {
      const allMembers: GroupChatPreviewMember[] = PREVIEW_CHARACTERS.map(
        (c, i: number): GroupChatPreviewMember => buildPreviewMember(c, i, GroupMemberPreviewStatus.Waiting, true)
      );
      const next: GroupChatPreviewSession = cloneSession(s);
      next.members = allMembers;
      next.totalCount = allMembers.length;
      next.updatedAt = now;
      return next;
    }
    return s;
  }
}

/** 预览状态容器单例 */
export const GroupChatPreviewStore: GroupChatPreviewStoreImpl = new GroupChatPreviewStoreImpl();
