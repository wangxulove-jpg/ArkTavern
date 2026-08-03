/**
 * GroupChatDraftTypes AI 建群草案类型定义(G-AI-BUILDER-1)
 *
 * 定义 AI 建群流程中的纯运行时类型:
 * - 候选角色摘要(脱敏,不含数据库 ID / systemPrompt / 头像路径)
 * - AI 生成的草案(标题 / 有序成员别名 / 推荐理由 / 可选开场消息)
 * - 草案状态机
 * - 错误分类
 *
 * 安全要求:
 * - GroupChatDraftCandidate 不含 Character ID(模型只看到别名)
 * - GeneratedGroupChatDraft.orderedCharacterIds 在本地由 alias 映射得到
 * - 不使用 any
 *
 * 不依赖:ArkUI / 数据库 / Provider。
 */

/**
 * 候选角色摘要(发送给模型的安全视图)。
 *
 * alias 为本地生成的别名(C1/C2/...),模型只能返回别名。
 * 不含数据库 ID、头像路径、systemPrompt、mesExample、创建时间等。
 */
export interface GroupChatDraftCandidate {
  /** 本地别名(C1/C2/...,发送给模型,模型只能返回此别名) */
  readonly alias: string;
  /** 真实角色 ID(仅本地保留,用于 alias→characterId 映射,不发送给模型) */
  readonly characterId: string;
  /** 角色名称 */
  readonly name: string;
  /** 受控摘要(截断后的 description/personality/scenario 组合) */
  readonly summary: string;
}

/**
 * AI 生成的群聊草案(纯内存,不写数据库)。
 *
 * orderedCharacterIds 已在本地由 alias 映射为真实 ID,并按模型返回顺序排列。
 */
export interface GeneratedGroupChatDraft {
  /** 建议群聊标题 */
  readonly title: string;
  /** 建议参与角色 ID 列表(按模型建议顺序,对应 speakerOrder) */
  readonly orderedCharacterIds: string[];
  /** 推荐理由 */
  readonly rationale: string;
  /** 可选的开场用户消息草案(空字符串表示无) */
  readonly openingMessage: string;
}

/**
 * 草案生成状态机。
 * Idle → Generating → Ready / Failed
 * Ready / Failed 可回到 Generating(重新生成)。
 */
export enum GroupChatDraftState {
  Idle = 'idle',
  Generating = 'generating',
  Ready = 'ready',
  Failed = 'failed'
}

/**
 * AI 建群错误类型。
 * 用于区分不同失败场景,向用户展示对应提示。
 */
export enum GroupChatDraftErrorType {
  /** 候选角色不足(< 2) */
  CandidatesInsufficient = 'CandidatesInsufficient',
  /** 候选角色过多(> 12) */
  CandidatesExcessive = 'CandidatesExcessive',
  /** 候选角色在生成期间被删除 */
  CharacterDeleted = 'CharacterDeleted',
  /** 没有可用的模型配置(未选择 Provider / 已禁用) */
  NoModelConfig = 'NoModelConfig',
  /** 认证失败(API Key 无效 / 401 / 403) */
  AuthenticationFailed = 'AuthenticationFailed',
  /** 网络失败(连接 / 超时 / 5xx) */
  NetworkFailed = 'NetworkFailed',
  /** 生成被用户主动取消 */
  Cancelled = 'Cancelled',
  /** AI 返回的 JSON 格式无效(含修复后仍失败) */
  JsonInvalid = 'JsonInvalid',
  /** 成员数量不在 2~8 范围 */
  MemberCountInvalid = 'MemberCountInvalid',
  /** 模型选择了候选池外的角色(别名不在候选列表) */
  OutOfPoolMember = 'OutOfPoolMember',
  /** 创建正式群聊失败 */
  CreateFailed = 'CreateFailed',
  /** 未知错误 */
  Unknown = 'Unknown'
}

/**
 * AI 建群错误对象。
 * 继承自 Error 以满足 ArkTS 的 arkts-limited-throw 规则。
 * 不含 API Key / 完整 Prompt / 角色卡正文。
 */
export class GroupChatDraftError extends Error {
  readonly errorType: GroupChatDraftErrorType;

  constructor(errorType: GroupChatDraftErrorType, message: string) {
    super(message);
    this.name = 'GroupChatDraftError';
    this.errorType = errorType;
  }
}

/** 最少候选角色数 */
export const MIN_CANDIDATE_COUNT: number = 2;
/** 最多候选角色数(允许超出最终 8 人,供 AI 筛选) */
export const MAX_CANDIDATE_COUNT: number = 12;
/** AI 草案最少成员数 */
export const MIN_DRAFT_MEMBER_COUNT: number = 2;
/** AI 草案最多成员数 */
export const MAX_DRAFT_MEMBER_COUNT: number = 8;
/** 开场消息草案最大长度 */
export const MAX_OPENING_MESSAGE_LENGTH: number = 1000;
/** 草案标题最大长度 */
export const MAX_DRAFT_TITLE_LENGTH: number = 60;
/** 单字段摘要截断长度 */
export const SUMMARY_FIELD_MAX_LENGTH: number = 200;
