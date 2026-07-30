/**
 * ChatRequest 聊天请求模型
 *
 * 与 OpenAI Chat Completions 常用字段兼容,保持 Provider 无关。
 *
 * 安全要求:
 * - 不包含 URL
 * - 不包含 API Key
 * - 不包含 Header
 * - 不包含 UI 状态
 *
 * 本阶段不加入:
 * - images / audio
 * - SillyTavern Prompt
 * - Character / Lorebook
 *
 * Phase 4A-3 已加入:
 * - tools / toolResults (项目内部统一类型, Provider Adapter 负责协议转换)
 */

import { ChatMessage } from './ChatMessage';
import { TEMPERATURE_DEFAULT, TOP_P_DEFAULT, MAX_TOKENS_DEFAULT } from './ProviderConfig';
import {
  ArkWebChatToolDefinition,
  ArkWebChatToolCall,
  ArkWebChatToolExecutionResult
} from '../avatarai/ArkWebAvatarAiToolTypes';

/**
 * 聊天请求选项(不含 model,由 ModelService 填充)。
 */
export interface ChatRequestOptions {
  /** 采样温度 */
  readonly temperature: number;
  /** 核采样概率 */
  readonly topP: number;
  /** 最大生成 token 数 */
  readonly maxTokens: number;
  /** 是否流式请求 */
  readonly stream: boolean;
  /**
   * 思考强度(可选):
   * - '' 跟随 Provider 默认(不发送 reasoning_effort 字段)
   * - 'none' 关闭思考
   * - 'low' / 'medium' / 'high' 三档
   * Provider 不支持时自动忽略。
   */
  readonly reasoningEffort?: string;
  /**
   * 是否强制 JSON 输出模式(可选):
   * - true 时向 OpenAI-compatible Provider 发送 response_format={type:"json_object"}
   * - Provider 不支持时自动忽略
   * - 要求 prompt 中必须包含 "JSON" 字样,否则部分 Provider 会报错
   */
  readonly responseFormatJson?: boolean;
  /**
   * Phase 4A-3: 工具定义列表 (可选)。
   *
   * - Provider 不支持原生 Tool Calling 时,此字段被忽略
   * - Provider 支持时, Adapter 将其转换为 Provider 协议格式
   * - 空数组或不传: 不注入工具
   */
  readonly tools?: ArkWebChatToolDefinition[];
  /**
   * Phase 4A-3: 上一轮工具执行结果 (可选)。
   *
   * 当上一轮 AI 返回 tool_calls 并已执行后, 将结果作为工具结果消息回传继续对话。
   * Provider Adapter 负责转换为 Provider 协议格式 (如 OpenAI 的 role:"tool" 消息)。
   */
  readonly toolResults?: ArkWebChatToolExecutionResult[];
  /**
   * Phase 4A-3: 上一轮 AI 返回的工具调用 (可选)。
   *
   * 用于在工具结果回传时, 将 assistant 的 tool_calls 一并放回 messages 中
   * (OpenAI 协议要求 assistant 消息包含 tool_calls, 然后是 role:"tool" 消息)。
   */
  readonly priorToolCalls?: ArkWebChatToolCall[];
}

/**
 * 聊天请求模型。
 */
export interface ChatRequest {
  /** 模型名称 */
  readonly model: string;
  /** 消息列表(顺序保持不变) */
  readonly messages: ChatMessage[];
  /** 采样温度 */
  readonly temperature: number;
  /** 核采样概率 */
  readonly topP: number;
  /** 最大生成 token 数 */
  readonly maxTokens: number;
  /** 是否流式请求 */
  readonly stream: boolean;
  /**
   * 思考强度(可选):
   * - '' 或 undefined 跟随 Provider 默认(不发送 reasoning_effort 字段)
   * - 'none' 关闭思考
   * - 'low' / 'medium' / 'high' 三档
   * Provider 不支持时自动忽略。
   */
  readonly reasoningEffort?: string;
  /**
   * 是否强制 JSON 输出模式(可选):
   * - true 时向 OpenAI-compatible Provider 发送 response_format={type:"json_object"}
   * - Provider 不支持时自动忽略
   */
  readonly responseFormatJson?: boolean;
  /**
   * Phase 4A-3: 工具定义列表 (可选)。
   *
   * Provider 不支持原生 Tool Calling 时,此字段被忽略。
   * Provider 支持时, Adapter 转换为 Provider 协议格式并注入请求。
   */
  readonly tools?: ArkWebChatToolDefinition[];
  /**
   * Phase 4A-3: 上一轮工具执行结果 (可选)。
   *
   * Provider Adapter 负责转换为 Provider 协议格式的工具结果消息。
   */
  readonly toolResults?: ArkWebChatToolExecutionResult[];
  /**
   * Phase 4A-3: 上一轮 AI 返回的工具调用 (可选)。
   *
   * 用于在工具结果回传时, 将 assistant 的 tool_calls 一并放回 messages 中
   * (OpenAI 协议要求 assistant 消息包含 tool_calls, 然后是 role:"tool" 消息)。
   */
  readonly priorToolCalls?: ArkWebChatToolCall[];
}

/**
 * 创建聊天请求,带安全默认值。
 * @param model 模型名称
 * @param messages 消息列表
 * @returns ChatRequest 实例
 */
export function createChatRequest(
  model: string,
  messages: ChatMessage[]
): ChatRequest {
  return {
    model: model,
    messages: messages,
    temperature: TEMPERATURE_DEFAULT,
    topP: TOP_P_DEFAULT,
    maxTokens: MAX_TOKENS_DEFAULT,
    stream: true
  };
}
