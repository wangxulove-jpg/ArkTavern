/**
 * ArkWebAvatarAiToolTypes — Avatar AI Tool Calling 通用类型 (Phase 4A-3)
 *
 * 职责:
 *   - 定义项目内部统一的 Tool Calling 类型 (与 Provider 协议无关)
 *   - 定义 Avatar 工具名称常量
 *   - 定义权限模式枚举
 *   - 定义工具执行结果
 *   - 定义错误码常量
 *
 * 安全约束:
 *   - 工具定义只包含业务字段 (name/description/inputSchemaJson)
 *   - 不包含路径 / URL / resourceId / 文件大小 / 导入时间
 *   - argumentsJson 最大 4096 字符
 *   - 业务 ID 只允许字母 / 数字 / 下划线 / 短横线
 *   - 拒绝 __proto__ / prototype / constructor / 路径分隔符 / URL scheme
 *
 * Provider Adapter 负责项目统一类型 ↔ Provider 实际协议的转换。
 * ChatService 不得散落多个 Provider 专属 JSON 字段。
 *
 * Reference:
 *   - AGENTS.md Phase 4A-3 §Tool Calling 通用类型 / §Avatar 工具集合 / §权限控制 / §错误隔离
 */

import { ArkWebAvatarAiCapabilitySnapshot } from '../vrmviewer/ArkWebAvatarAiTypes';

export { ArkWebAvatarAiCapabilitySnapshot } from '../vrmviewer/ArkWebAvatarAiTypes';

// ===== 通用 Tool Calling 类型 =====

/**
 * 项目内部统一的工具定义 (与 Provider 协议无关)。
 *
 * Provider Adapter 负责将其转换为 Provider 实际请求格式
 * (如 OpenAI 的 {type:"function", function:{name, description, parameters}})。
 */
export interface ArkWebChatToolDefinition {
  /** 工具名称 (只允许 avatar_list_capabilities / avatar_perform / avatar_stop / avatar_get_state) */
  name: string;
  /** 工具描述 (供 AI 理解用途) */
  description: string;
  /** 输入参数 JSON Schema 字符串 (Provider 直接透传) */
  inputSchemaJson: string;
}

/**
 * 项目内部统一的工具调用 (与 Provider 协议无关)。
 *
 * 由 Provider Adapter 从 Provider 响应中解析得到
 * (如 OpenAI 的 delta.tool_calls 累积拼接后转为完整调用)。
 */
export interface ArkWebChatToolCall {
  /** 工具调用 ID (Provider 分配,用于回传工具结果时配对) */
  toolCallId: string;
  /** 工具名称 (必须精确匹配 ArkWebChatToolDefinition.name) */
  name: string;
  /** 工具参数 JSON 字符串 (完整 JSON,非增量片段) */
  argumentsJson: string;
}

/**
 * 项目内部统一的工具执行结果 (回传给 Provider)。
 *
 * Provider Adapter 负责将其转换为 Provider 工具结果消息格式
 * (如 OpenAI 的 {role:"tool", tool_call_id, content})。
 */
export interface ArkWebChatToolExecutionResult {
  /** 工具调用 ID (与 ArkWebChatToolCall.toolCallId 一致) */
  toolCallId: string;
  /** 工具名称 (与 ArkWebChatToolCall.name 一致) */
  name: string;
  /** 执行是否成功 */
  success: boolean;
  /** 结果 JSON 字符串 (回传给 AI,不含内部堆栈) */
  resultJson: string;
  /** 错误码 (失败时非空) */
  errorCode: string;
  /** 错误信息 (失败时非空,简短可读) */
  errorMessage: string;
}

// ===== Avatar 工具名称常量 =====

/**
 * Avatar 工具名称常量 (只允许这四个)。
 *
 * 禁止其他工具名称。Tool Registry 只注册这四个工具。
 */
export class ArkWebAvatarAiToolName {
  /** 列出当前模型可用的动画/姿势/表情能力 */
  static readonly AVATAR_LIST_CAPABILITIES: string = 'avatar_list_capabilities';
  /** 执行 Avatar 演出 (动画/姿势/表情) */
  static readonly AVATAR_PERFORM: string = 'avatar_perform';
  /** 停止当前 AI 发起的演出 */
  static readonly AVATAR_STOP: string = 'avatar_stop';
  /** 查询当前 Avatar 业务状态 */
  static readonly AVATAR_GET_STATE: string = 'avatar_get_state';
}

/**
 * 所有允许的 Avatar 工具名称集合 (用于 isSupportedTool 校验)。
 */
export const AVATAR_AI_TOOL_NAMES: string[] = [
  ArkWebAvatarAiToolName.AVATAR_LIST_CAPABILITIES,
  ArkWebAvatarAiToolName.AVATAR_PERFORM,
  ArkWebAvatarAiToolName.AVATAR_STOP,
  ArkWebAvatarAiToolName.AVATAR_GET_STATE
];

// ===== 权限模式 =====

/**
 * Avatar Tool Calling 权限模式。
 *
 * - DENY: 不注入任何 Avatar 工具,AI 无法读取模型状态,无法执行演出
 * - READ_ONLY: 只注入 avatar_list_capabilities + avatar_get_state
 * - CONTROL_THIS_CHAT: 注入全部四个工具
 *
 * 默认值: DENY
 * 持久化: 只在当前聊天页面生命周期内保存,不写入数据库/Preferences/角色卡/聊天消息
 * 页面退出: 权限恢复 DENY,清除 Tool Calling 临时状态
 */
export type ArkWebAvatarAiToolPermissionMode =
  'DENY' | 'READ_ONLY' | 'CONTROL_THIS_CHAT';

/**
 * 权限模式常量 (用于字符串比较)。
 */
export class ArkWebAvatarAiToolPermissionModeConst {
  static readonly DENY: string = 'DENY';
  static readonly READ_ONLY: string = 'READ_ONLY';
  static readonly CONTROL_THIS_CHAT: string = 'CONTROL_THIS_CHAT';
}

/**
 * 默认权限模式 (DENY)。
 */
export const DEFAULT_AVATAR_TOOL_PERMISSION: string = 'DENY';

// ===== 限制常量 =====

/** 工具名最大长度 */
export const AVATAR_TOOL_NAME_MAX_LENGTH: number = 64;

/** argumentsJson 最大长度 (字符) */
export const AVATAR_TOOL_ARGUMENTS_MAX_LENGTH: number = 4096;

/** 能力上下文最大长度 (字符) */
export const AVATAR_CAPABILITY_CONTEXT_MAX_LENGTH: number = 16384;

/** 单次对话最大工具轮次 (超过停止执行工具) */
export const AVATAR_TOOL_MAX_ROUNDS: number = 3;

/** 单次对话最大工具调用次数 (超过停止执行工具) */
export const AVATAR_TOOL_MAX_CALLS_PER_TURN: number = 4;

/** 工具结果去重缓存上限 */
export const AVATAR_TOOL_RESULT_CACHE_LIMIT: number = 64;

// ===== 业务表情 ID 白名单 =====

/**
 * avatar_perform 工具允许的 expressionId 白名单 (空字符串 + 6 个固定业务 ID)。
 */
export const AVATAR_TOOL_EXPRESSION_IDS: string[] = [
  '',
  'neutral',
  'happy',
  'angry',
  'sad',
  'relaxed',
  'surprised'
];

/**
 * avatar_perform 工具允许的 motionType 白名单。
 */
export const AVATAR_TOOL_MOTION_TYPES: string[] = ['animation', 'pose', 'none'];

/**
 * avatar_perform 工具允许的 returnPolicy 白名单。
 */
export const AVATAR_TOOL_RETURN_POLICIES: string[] = ['DEFAULT_POSE', 'RESET', 'KEEP'];

// ===== 错误码 =====

/**
 * Avatar Tool Calling 错误码 (Phase 4A-3 §错误隔离)。
 *
 * 错误应作为工具结果返回给 AI,不影响聊天文本继续生成。
 */
export class ArkWebAvatarAiToolErrorCode {
  static readonly AVATAR_TOOL_PERMISSION_DENIED: string = 'AVATAR_TOOL_PERMISSION_DENIED';
  static readonly AVATAR_TOOL_PROVIDER_UNSUPPORTED: string = 'AVATAR_TOOL_PROVIDER_UNSUPPORTED';
  static readonly AVATAR_TOOL_NAME_INVALID: string = 'AVATAR_TOOL_NAME_INVALID';
  static readonly AVATAR_TOOL_ARGUMENTS_TOO_LARGE: string = 'AVATAR_TOOL_ARGUMENTS_TOO_LARGE';
  static readonly AVATAR_TOOL_ARGUMENTS_PARSE_FAILED: string = 'AVATAR_TOOL_ARGUMENTS_PARSE_FAILED';
  static readonly AVATAR_TOOL_ARGUMENTS_INVALID: string = 'AVATAR_TOOL_ARGUMENTS_INVALID';
  static readonly AVATAR_TOOL_UNSAFE_FIELD: string = 'AVATAR_TOOL_UNSAFE_FIELD';
  static readonly AVATAR_TOOL_CAPABILITY_NOT_FOUND: string = 'AVATAR_TOOL_CAPABILITY_NOT_FOUND';
  static readonly AVATAR_TOOL_ENDPOINT_UNAVAILABLE: string = 'AVATAR_TOOL_ENDPOINT_UNAVAILABLE';
  static readonly AVATAR_TOOL_EXECUTION_FAILED: string = 'AVATAR_TOOL_EXECUTION_FAILED';
  static readonly AVATAR_TOOL_DUPLICATE: string = 'AVATAR_TOOL_DUPLICATE';
  static readonly AVATAR_TOOL_ROUND_LIMIT: string = 'AVATAR_TOOL_ROUND_LIMIT';
  static readonly AVATAR_TOOL_DISPOSED: string = 'AVATAR_TOOL_DISPOSED';
}

// ===== 安全: 业务 ID 校验 =====

/**
 * 业务 ID 允许的字符正则 (字母 / 数字 / 下划线 / 短横线)。
 *
 * 用于校验 actionId / poseId / expressionId。
 * 拒绝路径分隔符 / URL scheme / __proto__ / prototype / constructor。
 */
const SAFE_BUSINESS_ID_REGEX: RegExp = /^[A-Za-z0-9_-]+$/;

/**
 * 危险键名集合 (拒绝 __proto__ / prototype / constructor)。
 */
const UNSAFE_KEYS: string[] = ['__proto__', 'prototype', 'constructor'];

/**
 * 危险前缀集合 (拒绝 file: / http: / https: / content: / data: / D:\ / / / ../)。
 */
const UNSAFE_PREFIXES: string[] = [
  'file:',
  'http:',
  'https:',
  'content:',
  'data:',
  'D:\\',
  '../',
  '..\\'
];

/**
 * 校验业务 ID 是否安全 (只允许字母/数字/下划线/短横线)。
 *
 * @param id 业务 ID (actionId / poseId / expressionId)
 * @returns 安全返回 true
 */
export function isSafeBusinessId(id: string): boolean {
  if (id.length === 0) {
    // 空字符串允许 (expressionId 可为空, motionId 在 motionType=none 时为空)
    return true;
  }
  return SAFE_BUSINESS_ID_REGEX.test(id);
}

/**
 * 检查字符串是否包含危险前缀或路径分隔符。
 *
 * @param str 待检查字符串
 * @returns 包含危险内容返回 true
 */
export function containsUnsafeContent(str: string): boolean {
  for (let i = 0; i < UNSAFE_PREFIXES.length; i++) {
    if (str.includes(UNSAFE_PREFIXES[i])) {
      return true;
    }
  }
  // 单独检查 "/" 和 "\\" (路径分隔符, 但允许 argumentsJson 中的 JSON 字符串包含)
  // 这里只对业务 ID 检查, 不对 argumentsJson 整体检查
  return false;
}

/**
 * 检查 JSON 对象的键是否包含危险键名。
 *
 * @param obj 待检查的 Record
 * @returns 包含危险键返回 true
 */
export function hasUnsafeKeys(obj: Record<string, Object>): boolean {
  const keys: string[] = Object.keys(obj);
  for (let i = 0; i < UNSAFE_KEYS.length; i++) {
    for (let j = 0; j < keys.length; j++) {
      if (keys[j] === UNSAFE_KEYS[i]) {
        return true;
      }
    }
  }
  return false;
}

// ===== avatar_perform 参数与结果类型 =====

/**
 * avatar_perform 工具参数 (项目内部统一类型,从 argumentsJson 解析得到)。
 *
 * 规则:
 *   - motionType: animation / pose / none
 *   - animation: motionId 必须精确匹配 actionId
 *   - pose: motionId 必须精确匹配 poseId
 *   - none: motionId 必须为空, expressionId 必须非空
 *   - expressionId: 空字符串 / neutral / happy / angry / sad / relaxed / surprised
 *   - expressionWeight: 0..1
 *   - durationMs: 100..30000
 *   - returnPolicy: DEFAULT_POSE / RESET / KEEP
 */
export interface ArkWebAvatarPerformParams {
  motionType: string;
  motionId: string;
  expressionId: string;
  expressionWeight: number;
  durationMs: number;
  returnPolicy: string;
}

/**
 * avatar_perform 工具执行结果 JSON (回传给 AI)。
 *
 * Phase 4C-2: 新增 noOp 字段, 用于相同活动演出 no-op 保护 (不重播, 不报错)。
 */
export interface ArkWebAvatarPerformResultJson {
  success: boolean;
  errorCode: string;
  message: string;
  commandId: string;
  /**
   * Phase 4C-2: 是否为 no-op (当前演出 ACTIVE 且新参数完全相同)。
   * - true: success=true, 不重播动画, 不报错
   * - false: 正常执行
   */
  noOp: boolean;
}

/**
 * avatar_list_capabilities 工具结果 JSON (回传给 AI)。
 *
 * 禁止返回映射对象内部路径或真实 Expression 实例。
 */
export interface ArkWebAvatarListCapabilitiesResultJson {
  modelId: string;
  modelDisplayName: string;
  animations: ArkWebAvatarAiAnimationSummary[];
  poses: ArkWebAvatarAiPoseSummary[];
  expressions: ArkWebAvatarAiExpressionSummary[];
}

/**
 * 动画能力摘要 (回传给 AI,只含业务字段)。
 */
export interface ArkWebAvatarAiAnimationSummary {
  actionId: string;
  displayName: string;
  isDefaultIdle: boolean;
}

/**
 * 姿势能力摘要 (回传给 AI,只含业务字段)。
 */
export interface ArkWebAvatarAiPoseSummary {
  poseId: string;
  displayName: string;
  isDefaultPose: boolean;
}

/**
 * 表情能力摘要 (回传给 AI,只含业务字段)。
 */
export interface ArkWebAvatarAiExpressionSummary {
  expressionId: string;
  available: boolean;
}

/**
 * avatar_get_state 工具结果 JSON (回传给 AI,只含业务状态)。
 *
 * 禁止返回 Generation / 相机坐标 / Provider URL / 路径 / Three.js Debug / 错误堆栈。
 */
export interface ArkWebAvatarGetStateResultJson {
  connected: boolean;
  modelReady: boolean;
  modelDisplayName: string;
  shot: string;
  performanceState: string;
  motionType: string;
  motionId: string;
  expressionId: string;
}

/**
 * avatar_stop 工具结果 JSON (回传给 AI)。
 */
export interface ArkWebAvatarStopResultJson {
  success: boolean;
  errorCode: string;
  message: string;
}

// ===== Provider 能力声明 =====

/**
 * Provider 原生 Tool Calling 支持声明。
 *
 * Provider Adapter 通过此接口声明是否支持原生 Tool Calling。
 * ChatService 只在 supported=true 时注入 tools。
 */
export interface ArkWebProviderToolCallingCapability {
  /** Provider 是否支持原生 structured tool calling */
  supported: boolean;
  /** Provider 标识 (如 'openai' / 'openai-compatible' / 'deepseek' / 'openrouter') */
  providerId: string;
}

// ===== 去重缓存条目 =====

/**
 * 工具调用去重缓存条目。
 *
 * Key: chatTurnId + toolCallId
 * Value: 执行结果
 * 上限: AVATAR_TOOL_RESULT_CACHE_LIMIT (64)
 * 超过: 删除最旧记录
 */
export interface ArkWebAvatarToolResultCacheEntry {
  chatTurnId: string;
  toolCallId: string;
  result: ArkWebChatToolExecutionResult;
  cachedAt: number;
}

// ===== Tool Calling 上下文 (传递给 Executor) =====

/**
 * Avatar Tool Calling 上下文 (ChatService 传给 Executor)。
 *
 * 包含执行工具所需的全部依赖,Executor 不直接访问 ChatService 内部状态。
 */
export interface ArkWebAvatarAiToolContext {
  /** 当前对话轮次 ID (用于去重和 Bridge turnId) */
  chatTurnId: string;
  /** 当前能力快照 (可能为 null,表示无模型) */
  snapshot: ArkWebAvatarAiCapabilitySnapshot | null;
  /** 当前权限模式 */
  permissionMode: string;
}
