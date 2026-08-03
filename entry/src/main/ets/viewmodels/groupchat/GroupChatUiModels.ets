/**
 * GroupChatUiModels 多人聊天正式 UI 数据模型(G-DATA-1B)
 *
 * 职责:
 * - 定义只服务于多人 UI 的 DTO,隔离数据库实体与 ArkUI 页面状态
 * - 集中定义跨页面路由 Key
 * - 集中定义页面状态枚举
 *
 * 不依赖:
 * - 数据库实体(Chat / ChatParticipant / Character)
 * - GroupChatPreviewModels(预览模型)
 * - ArkUI 装饰器
 *
 * 规则:
 * - 全部 readonly
 * - 不使用 any
 * - 缺失角色标记 characterExists=false,页面显示"角色已删除"
 */

/** AppStorage 中待进入的群聊 ID(由首页/创建页写入,GroupChatPage 读取) */
export const PENDING_GROUP_CHAT_ID_KEY: string = 'pendingGroupChatId';

/** 多人聊天列表页状态 */
export enum GroupChatListState {
  Loading = 'loading',
  Ready = 'ready',
  Empty = 'empty',
  Error = 'error'
}

/** 多人聊天详情页状态 */
export enum GroupChatDetailState {
  Loading = 'loading',
  Ready = 'ready',
  NotFound = 'not_found',
  Error = 'error'
}

/** 角色选择页状态 */
export enum CharacterPickState {
  Loading = 'loading',
  Ready = 'ready',
  Empty = 'empty',
  Error = 'error'
}

/** 群聊成员 UI 模型 */
export interface GroupMemberUiModel {
  /** 角色 ID */
  readonly characterId: string;
  /** 角色名称(缺失角色显示"角色已删除") */
  readonly name: string;
  /** 头像 URI(缺失角色为空字符串,由 CharacterImageView 显示占位) */
  readonly avatarUri: string;
  /** 角色描述摘要(缺失角色为空) */
  readonly description: string;
  /** 发言顺序(从 0 开始) */
  readonly speakerOrder: number;
  /** 是否启用 */
  readonly isEnabled: boolean;
  /** 角色是否真实存在(false 表示角色已被删除) */
  readonly characterExists: boolean;
}

/** 群聊列表项 UI 模型 */
export interface GroupConversationListItemUiModel {
  readonly chatId: string;
  readonly title: string;
  /** 有序成员列表(全部成员,含停用) */
  readonly members: GroupMemberUiModel[];
  readonly memberCount: number;
  /** 最后消息预览(本阶段无真实多人消息,固定"还没有消息") */
  readonly lastMessagePreview: string;
  readonly updatedAt: number;
}

/** 群聊详情 UI 模型 */
export interface GroupConversationDetailUiModel {
  readonly chatId: string;
  readonly title: string;
  /** 有序成员列表(全部成员,含停用) */
  readonly members: GroupMemberUiModel[];
}

/** 可添加角色 UI 模型(成员管理页"添加角色"弹窗用) */
export interface AddableCharacterUiModel {
  readonly characterId: string;
  readonly name: string;
  readonly avatarUri: string;
  readonly description: string;
}

/**
 * 格式化时间戳为 MM-DD HH:mm(与 ChatSessionListViewModel 一致)。
 */
export function formatGroupTimestamp(ts: number): string {
  if (ts <= 0) {
    return '';
  }
  const d: Date = new Date(ts);
  const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
  const day: string = d.getDate().toString().padStart(2, '0');
  const hour: string = d.getHours().toString().padStart(2, '0');
  const minute: string = d.getMinutes().toString().padStart(2, '0');
  return month + '-' + day + ' ' + hour + ':' + minute;
}

/** 缺失角色显示名称 */
export const DELETED_CHARACTER_NAME: string = '角色已删除';

/** 无消息时的固定预览文本 */
export const NO_MESSAGE_PREVIEW: string = '还没有消息';
