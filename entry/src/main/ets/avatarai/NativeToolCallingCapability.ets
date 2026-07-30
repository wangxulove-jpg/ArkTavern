/**
 * NativeToolCallingCapability.ets — Phase 4A-3R
 *
 * 定义原生 Tool Calling 支持状态的四态模型、判断来源、错误码和探测结果。
 *
 * 设计原则:
 *   - 不再用 boolean 表示 Provider 是否支持, 改为四态
 *   - UNKNOWN 不能被显示为"不支持"
 *   - 只有 RUNTIME_PROBE 成功才能标记 SUPPORTED
 *   - 探测结果必须包含详细分类错误码
 *
 * 不写入:
 *   - API Key / Authorization / 完整请求正文 / 敏感 Base URL
 */

/**
 * 原生 Tool Calling 支持状态 (四态)。
 *
 * - SUPPORTED: 真实原生 Tool Call 探测成功
 * - UNSUPPORTED: Provider 或模型明确拒绝 tools
 * - UNKNOWN: 尚未实际验证 (默认初始值)
 * - MISCONFIGURED: 本地 Integration / Adapter / Parser 缺失
 */
export type NativeToolCallingSupport =
  'SUPPORTED'
  | 'UNSUPPORTED'
  | 'UNKNOWN'
  | 'MISCONFIGURED';

/**
 * NativeToolCallingSupport 常量集合 (避免字符串拼写错误)。
 */
export class NativeToolCallingSupportConst {
  static readonly SUPPORTED: NativeToolCallingSupport = 'SUPPORTED';
  static readonly UNSUPPORTED: NativeToolCallingSupport = 'UNSUPPORTED';
  static readonly UNKNOWN: NativeToolCallingSupport = 'UNKNOWN';
  static readonly MISCONFIGURED: NativeToolCallingSupport = 'MISCONFIGURED';
}

/**
 * 判断来源 (ProvTool Calling 支持状态的依据)。
 *
 * - RUNTIME_PROBE: 通过 ark_tool_capability_probe 真实探测
 * - PROVIDER_DECLARATION: Provider.supportsToolCalling() 静态声明 (仅参考)
 * - STATIC_REGISTRY: 静态注册表 (未来扩展, 当前未使用)
 * - UNKNOWN: 未经验证
 */
export type NativeToolCallingDecisionSource =
  'RUNTIME_PROBE'
  | 'PROVIDER_DECLARATION'
  | 'STATIC_REGISTRY'
  | 'UNKNOWN';

/**
 * NativeToolCallingDecisionSource 常量集合。
 */
export class NativeToolCallingDecisionSourceConst {
  static readonly RUNTIME_PROBE: NativeToolCallingDecisionSource = 'RUNTIME_PROBE';
  static readonly PROVIDER_DECLARATION: NativeToolCallingDecisionSource = 'PROVIDER_DECLARATION';
  static readonly STATIC_REGISTRY: NativeToolCallingDecisionSource = 'STATIC_REGISTRY';
  static readonly UNKNOWN: NativeToolCallingDecisionSource = 'UNKNOWN';
}

/**
 * 原生 Tool Calling 探测错误码 (失败时分类)。
 *
 * 不允许只显示"测试失败", 必须返回以下之一:
 */
export type NativeToolCallingErrorCode =
  // Provider 或模型明确拒绝 tools (HTTP 400/404 等)
  'NATIVE_TOOL_PROVIDER_UNSUPPORTED'
  // 模型不支持 (Provider 接受但模型拒绝)
  | 'NATIVE_TOOL_MODEL_UNSUPPORTED'
  // 请求 Adapter 缺失或未实现 tools 序列化
  | 'NATIVE_TOOL_REQUEST_ADAPTER_MISSING'
  // 流式 Parser 缺失或未实现 tool_calls 解析
  | 'NATIVE_TOOL_STREAM_PARSER_MISSING'
  // arguments 增量拼接失败 (JSON 解析错误)
  | 'NATIVE_TOOL_ARGUMENT_ASSEMBLY_FAILED'
  // 工具结果回传路径缺失 (无法续写下一轮)
  | 'NATIVE_TOOL_RESULT_CONTINUATION_MISSING'
  // Provider 返回了正文 JSON / Markdown JSON 而非结构化 tool_calls
  | 'NATIVE_TOOL_TEXT_SIMULATION_REJECTED'
  // Tool Integration 未连接 (ChatPage 未调用 setAvatarToolIntegration)
  | 'NATIVE_TOOL_INTEGRATION_NOT_CONNECTED'
  // Provider 配置错误 (API Key 缺失 / Base URL 无效等)
  | 'NATIVE_TOOL_PROVIDER_MISCONFIGURED'
  // 其他未知错误
  | 'NATIVE_TOOL_UNKNOWN_ERROR';

/**
 * NativeToolCallingErrorCode 常量集合。
 */
export class NativeToolCallingErrorCodeConst {
  static readonly PROVIDER_UNSUPPORTED: NativeToolCallingErrorCode = 'NATIVE_TOOL_PROVIDER_UNSUPPORTED';
  static readonly MODEL_UNSUPPORTED: NativeToolCallingErrorCode = 'NATIVE_TOOL_MODEL_UNSUPPORTED';
  static readonly REQUEST_ADAPTER_MISSING: NativeToolCallingErrorCode = 'NATIVE_TOOL_REQUEST_ADAPTER_MISSING';
  static readonly STREAM_PARSER_MISSING: NativeToolCallingErrorCode = 'NATIVE_TOOL_STREAM_PARSER_MISSING';
  static readonly ARGUMENT_ASSEMBLY_FAILED: NativeToolCallingErrorCode = 'NATIVE_TOOL_ARGUMENT_ASSEMBLY_FAILED';
  static readonly RESULT_CONTINUATION_MISSING: NativeToolCallingErrorCode = 'NATIVE_TOOL_RESULT_CONTINUATION_MISSING';
  static readonly TEXT_SIMULATION_REJECTED: NativeToolCallingErrorCode = 'NATIVE_TOOL_TEXT_SIMULATION_REJECTED';
  static readonly INTEGRATION_NOT_CONNECTED: NativeToolCallingErrorCode = 'NATIVE_TOOL_INTEGRATION_NOT_CONNECTED';
  static readonly PROVIDER_MISCONFIGURED: NativeToolCallingErrorCode = 'NATIVE_TOOL_PROVIDER_MISCONFIGURED';
  static readonly UNKNOWN_ERROR: NativeToolCallingErrorCode = 'NATIVE_TOOL_UNKNOWN_ERROR';
}

/**
 * 探测工具定义 (ark_tool_capability_probe)。
 *
 * 无副作用: 只回显传入的 token, 不修改任何状态。
 */
export interface NativeToolCallingProbeTool {
  name: string;
  description: string;
  parametersJson: string;
}

/**
 * 探测工具名称常量。
 */
export const NATIVE_TOOL_PROBE_TOOL_NAME: string = 'ark_tool_capability_probe';

/**
 * 探测工具描述。
 */
export const NATIVE_TOOL_PROBE_TOOL_DESCRIPTION: string =
  'Return the supplied token through a native tool call.';

/**
 * 探测工具 parameters JSON Schema (固定)。
 */
export const NATIVE_TOOL_PROBE_TOOL_PARAMETERS_JSON: string =
  '{"type":"object","properties":{"token":{"type":"string"}},"required":["token"],"additionalProperties":false}';

/**
 * 探测请求结果。
 *
 * - success: 是否成功 (只有满足全部成功条件才为 true)
 * - support: 四态之一 (成功时为 SUPPORTED, 失败时为 UNSUPPORTED / MISCONFIGURED)
 * - decisionSource: 判断来源 (成功时为 RUNTIME_PROBE)
 * - errorCode: 失败时分类错误码
 * - errorMessage: 失败时人类可读信息
 * - probedToolCallId: 成功时返回的 toolCallId (用于诊断)
 * - probedToolName: 成功时返回的工具名 (应与 NATIVE_TOOL_PROBE_TOOL_NAME 一致)
 * - returnedToken: 成功时返回的 token (应与传入 token 一致)
 * - httpStatus: HTTP 状态码 (诊断用, 不向 UI 显示)
 * - requestId: 请求 ID (诊断用, 不向 UI 显示)
 *
 * 不包含: API Key / Authorization / 完整请求正文 / 敏感 Base URL 参数
 */
export interface NativeToolCallingProbeResult {
  success: boolean;
  support: NativeToolCallingSupport;
  decisionSource: NativeToolCallingDecisionSource;
  errorCode: NativeToolCallingErrorCode;
  errorMessage: string;
  probedToolCallId: string;
  probedToolName: string;
  returnedToken: string;
  httpStatus: number;
  requestId: string;
  probedAt: number;
}

/**
 * 创建初始 UNKNOWN 探测结果。
 */
export function createInitialProbeResult(): NativeToolCallingProbeResult {
  return {
    success: false,
    support: NativeToolCallingSupportConst.UNKNOWN,
    decisionSource: NativeToolCallingDecisionSourceConst.UNKNOWN,
    errorCode: NativeToolCallingErrorCodeConst.UNKNOWN_ERROR,
    errorMessage: '',
    probedToolCallId: '',
    probedToolName: '',
    returnedToken: '',
    httpStatus: 0,
    requestId: '',
    probedAt: 0
  };
}

/**
 * Avatar Tool Integration 接线状态。
 *
 * - CONNECTED: ChatPage 已调用 setAvatarToolIntegration, 所有依赖已注入
 * - NOT_CONNECTED: ChatPage 未调用 setAvatarToolIntegration
 * - FAILED: 接线抛出异常或依赖缺失
 * - DISPOSED: 页面已 aboutToDisappear, Integration 已 dispose
 */
export type AvatarToolIntegrationState =
  'CONNECTED'
  | 'NOT_CONNECTED'
  | 'FAILED'
  | 'DISPOSED';

/**
 * AvatarToolIntegrationState 常量集合。
 */
export class AvatarToolIntegrationStateConst {
  static readonly CONNECTED: AvatarToolIntegrationState = 'CONNECTED';
  static readonly NOT_CONNECTED: AvatarToolIntegrationState = 'NOT_CONNECTED';
  static readonly FAILED: AvatarToolIntegrationState = 'FAILED';
  static readonly DISPOSED: AvatarToolIntegrationState = 'DISPOSED';
}

/**
 * Provider 信息快照 (供 UI 显示, 不含敏感字段)。
 *
 * - providerType: Provider 类型 (openai / deepseek / openrouter / claude / gemini)
 * - providerDisplayName: Provider 显示名称 (用户配置)
 * - currentModelId: 当前模型 ID
 *
 * 禁止包含: API Key / Authorization / 完整 Base URL / 请求正文
 */
export interface ProviderInfoSnapshot {
  providerType: string;
  providerDisplayName: string;
  currentModelId: string;
}

/**
 * 创建空 ProviderInfoSnapshot。
 */
export function createEmptyProviderInfoSnapshot(): ProviderInfoSnapshot {
  return {
    providerType: '',
    providerDisplayName: '',
    currentModelId: ''
  };
}

/**
 * 探测工具定义工厂 (返回 NativeToolCallingProbeTool)。
 *
 * 不接受任何参数, 内部固定使用 NATIVE_TOOL_PROBE_TOOL_NAME 和 PARAMETERS_JSON。
 */
export function buildNativeToolCallingProbeTool(): NativeToolCallingProbeTool {
  return {
    name: NATIVE_TOOL_PROBE_TOOL_NAME,
    description: NATIVE_TOOL_PROBE_TOOL_DESCRIPTION,
    parametersJson: NATIVE_TOOL_PROBE_TOOL_PARAMETERS_JSON
  };
}

/**
 * 生成随机探测 token (8 位十六进制)。
 *
 * 用于防止 AI 通过记忆历史 token 伪造工具调用结果。
 */
export function generateProbeToken(): string {
  const chars: string[] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
  const parts: string[] = [];
  for (let i = 0; i < 8; i++) {
    const idx: number = Math.floor(Math.random() * 16);
    parts.push(chars[idx]);
  }
  return parts.join('');
}

/**
 * validateProbeToolCall 返回结果。
 */
export interface ValidateProbeToolCallResult {
  valid: boolean;
  errorCode: NativeToolCallingErrorCode;
  errorMessage: string;
}

/**
 * 校验探测返回的工具调用是否合法。
 *
 * 成功条件 (全部满足):
 *   - toolCallId 非空
 *   - toolName 精确匹配 NATIVE_TOOL_PROBE_TOOL_NAME
 *   - argumentsJson 能完整解析为 JSON 对象
 *   - arguments.token 与传入 token 一致
 *
 * 失败时返回对应错误码。
 */
export function validateProbeToolCall(
  toolCallId: string,
  toolName: string,
  argumentsJson: string,
  expectedToken: string
): ValidateProbeToolCallResult {
  if (toolCallId.length === 0) {
    const result: ValidateProbeToolCallResult = {
      valid: false,
      errorCode: NativeToolCallingErrorCodeConst.ARGUMENT_ASSEMBLY_FAILED,
      errorMessage: 'toolCallId is empty.'
    };
    return result;
  }
  if (toolName !== NATIVE_TOOL_PROBE_TOOL_NAME) {
    const result: ValidateProbeToolCallResult = {
      valid: false,
      errorCode: NativeToolCallingErrorCodeConst.TEXT_SIMULATION_REJECTED,
      errorMessage: `tool name mismatch: expected ${NATIVE_TOOL_PROBE_TOOL_NAME}, got ${toolName}.`
    };
    return result;
  }
  let parsed: Record<string, Object> | null = null;
  try {
    parsed = JSON.parse(argumentsJson) as Record<string, Object>;
  } catch (e) {
    const result: ValidateProbeToolCallResult = {
      valid: false,
      errorCode: NativeToolCallingErrorCodeConst.ARGUMENT_ASSEMBLY_FAILED,
      errorMessage: `arguments JSON parse failed: ${e instanceof Error ? e.message : String(e)}`
    };
    return result;
  }
  if (parsed === null) {
    const result: ValidateProbeToolCallResult = {
      valid: false,
      errorCode: NativeToolCallingErrorCodeConst.ARGUMENT_ASSEMBLY_FAILED,
      errorMessage: 'arguments JSON parsed to null.'
    };
    return result;
  }
  const tokenVal: Object | undefined = parsed['token'];
  if (tokenVal === undefined) {
    const result: ValidateProbeToolCallResult = {
      valid: false,
      errorCode: NativeToolCallingErrorCodeConst.ARGUMENT_ASSEMBLY_FAILED,
      errorMessage: 'arguments.token is missing.'
    };
    return result;
  }
  const actualToken: string = String(tokenVal);
  if (actualToken !== expectedToken) {
    const result: ValidateProbeToolCallResult = {
      valid: false,
      errorCode: NativeToolCallingErrorCodeConst.TEXT_SIMULATION_REJECTED,
      errorMessage: `token mismatch: expected ${expectedToken}, got ${actualToken}.`
    };
    return result;
  }
  const okResult: ValidateProbeToolCallResult = {
    valid: true,
    errorCode: NativeToolCallingErrorCodeConst.UNKNOWN_ERROR,
    errorMessage: ''
  };
  return okResult;
}
