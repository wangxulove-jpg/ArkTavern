/**
 * ArkWebDialoguePerformanceTypes — AI 对话结果到演出指令的安全映射类型 (Phase 3F-2)
 *
 * 职责:
 *   - 定义 AI Hint 输入类型 ArkWebDialoguePerformanceHint
 *   - 定义映射结果 ArkWebDialoguePerformanceMappingResult
 *   - 定义映射错误码 DialoguePerformanceErrorCode
 *
 * 安全约束:
 *   - AI 不允许提供 commandId / interruptPolicy
 *   - AI 不允许提供 resourceId / resourceUrl / providerUrl
 *   - AI 不允许提供 absolutePath / relativePath / cachePath / filesDir / sourceUri
 *   - AI 不允许提供骨骼数据 / Three.js 对象 / Expression 实例
 *   - commandId 必须由应用本地生成
 *   - interruptPolicy 固定由 Mapper 设置为 REPLACE
 *
 * 本阶段不实现:
 *   - 真实 AI 接口 / 自然语言解析 / Markdown 解析
 *   - 网络请求 / WebSocket / Timer / Frame Loop
 *
 * Reference:
 *   - AGENTS.md Phase 3F-2 §AI Hint 类型 / §输入安全 / §字段规则
 *   - ArkWebAvatarPerformanceTypes.ets (ArkWebAvatarPerformanceCommand)
 */

import { ArkWebAvatarPerformanceCommand } from './ArkWebAvatarPerformanceTypes';

/**
 * AI Hint 版本。
 *
 * 当前唯一支持版本: 1。
 * 未来版本变更时,旧版本视为不支持。
 */
export const DIALOGUE_PERFORMANCE_HINT_VERSION: number = 1;

/**
 * AI Hint 原始 JSON 最大字符数 (4096)。
 *
 * 超过此大小的输入直接拒绝 (DIALOGUE_HINT_TOO_LARGE)。
 */
export const DIALOGUE_PERFORMANCE_HINT_MAX_CHARS: number = 4096;

/**
 * AI Hint 输入类型。
 *
 * 所有字段均为可选 (除 version),Mapper 负责填充默认值和校验。
 *
 * 字段规则 (详见 Mapper):
 *   - version: 必须为 1
 *   - motionType: animation / pose / none (默认 none)
 *   - motionId: animation 时为 actionId, pose 时为 poseId, none 时必须为空
 *   - expressionId: 空字符串 / neutral/happy/angry/sad/relaxed/surprised
 *   - expressionWeight: 默认 1, 范围 0..1
 *   - durationMs: 默认 2500, 范围 100..30000
 *   - returnPolicy: 默认 DEFAULT_POSE, DEFAULT_POSE / RESET / KEEP
 *
 * 禁止字段 (AI 不得传入):
 *   - commandId (应用本地生成)
 *   - interruptPolicy (Mapper 强制 REPLACE)
 *   - resourceId / resourceUrl / providerUrl
 *   - absolutePath / relativePath / cachePath / filesDir / sourceUri
 *   - bone / skeleton / node / mesh / vrm / expression 等内部对象
 */
export interface ArkWebDialoguePerformanceHint {
  version: number;
  motionType?: string;
  motionId?: string;
  expressionId?: string;
  expressionWeight?: number;
  durationMs?: number;
  returnPolicy?: string;
}

/**
 * 映射结果 (Mapper.mapJson 返回)。
 *
 * 字段:
 *   - accepted: 是否接受执行 (true 时 command 非 null)
 *   - degraded: 是否发生降级 (动作或表情部分被丢弃)
 *   - command: 映射后的演出命令 (accepted=false 时为 undefined)
 *   - warnings: 降级 / 校验警告信息 (非致命)
 *   - errorCode: 错误码 (accepted=true 时为空字符串)
 *   - errorMessage: 错误信息 (accepted=true 时为空字符串)
 */
export interface ArkWebDialoguePerformanceMappingResult {
  accepted: boolean;
  degraded: boolean;
  command?: ArkWebAvatarPerformanceCommand;
  warnings: string[];
  errorCode: string;
  errorMessage: string;
}

/**
 * AI Hint 映射错误码 (Phase 3F-2)。
 */
export class DialoguePerformanceErrorCode {
  /** 输入 JSON 为空字符串 */
  static readonly HINT_EMPTY: string = 'DIALOGUE_HINT_EMPTY';
  /** 输入 JSON 超过 4096 字符 */
  static readonly HINT_TOO_LARGE: string = 'DIALOGUE_HINT_TOO_LARGE';
  /** JSON 解析失败 (非合法 JSON) */
  static readonly HINT_PARSE_FAILED: string = 'DIALOGUE_HINT_PARSE_FAILED';
  /** JSON 根节点不是对象 (如数组 / 字符串 / 数字) */
  static readonly HINT_ROOT_INVALID: string = 'DIALOGUE_HINT_ROOT_INVALID';
  /** 包含未知字段 (不在允许字段白名单中) */
  static readonly HINT_FIELD_UNKNOWN: string = 'DIALOGUE_HINT_FIELD_UNKNOWN';
  /** 包含危险字段 (路径 / URL / __proto__ / prototype / constructor 等) */
  static readonly HINT_FIELD_UNSAFE: string = 'DIALOGUE_HINT_FIELD_UNSAFE';
  /** version 不支持 (非 1) */
  static readonly HINT_VERSION_UNSUPPORTED: string = 'DIALOGUE_HINT_VERSION_UNSUPPORTED';
  /** motionType 非法 (非 animation/pose/none) */
  static readonly MOTION_TYPE_INVALID: string = 'DIALOGUE_MOTION_TYPE_INVALID';
  /** motionId 非法 (空 / 包含路径分隔符 / 包含 URL) */
  static readonly MOTION_ID_INVALID: string = 'DIALOGUE_MOTION_ID_INVALID';
  /** actionId 在 library.animations 中找不到 */
  static readonly ACTION_NOT_FOUND: string = 'DIALOGUE_ACTION_NOT_FOUND';
  /** poseId 在 library.poses 中找不到 */
  static readonly POSE_NOT_FOUND: string = 'DIALOGUE_POSE_NOT_FOUND';
  /** expressionId 非法 (非空且非固定业务 ID) */
  static readonly EXPRESSION_ID_INVALID: string = 'DIALOGUE_EXPRESSION_ID_INVALID';
  /** 动作、姿势和表情都无效,无可执行内容 */
  static readonly NOTHING_TO_PERFORM: string = 'DIALOGUE_NOTHING_TO_PERFORM';
}

/**
 * Hint 允许字段白名单 (AI 只能传这些字段)。
 */
export const DIALOGUE_HINT_ALLOWED_FIELDS: string[] = [
  'version',
  'motionType',
  'motionId',
  'expressionId',
  'expressionWeight',
  'durationMs',
  'returnPolicy'
];

/**
 * Hint 危险字段黑名单 (任何场景都禁止)。
 *
 * 包括:
 *   - 路径相关: absolutePath / relativePath / filesDir / sourceUri / cachePath
 *   - 资源相关: resourceId / resourceUrl / providerUrl
 *   - 内部对象: bone / skeleton / node / mesh / vrm / expression
 *   - 原型链攻击: __proto__ / prototype / constructor
 *   - 协议前缀: file: / http: / https:
 */
export const DIALOGUE_HINT_FORBIDDEN_FIELDS: string[] = [
  'absolutePath', 'relativePath', 'filesDir', 'sourceUri', 'cachePath',
  'resourceId', 'resourceUrl', 'providerUrl',
  'bone', 'skeleton', 'node', 'mesh', 'vrm', 'expression',
  '__proto__', 'prototype', 'constructor',
  'commandId', 'interruptPolicy'
];

/**
 * 危险字符串模式 (motionId / expressionId 等字段值中禁止出现)。
 *
 * - file: / http: / https: 协议前缀
 * - 路径分隔符 / 和 \
 * - ..
 */
export const DIALOGUE_HINT_FORBIDDEN_PATTERNS: string[] = [
  'file:', 'http:', 'https:', 'ftp:', 'data:',
  '/', '\\', '..'
];
