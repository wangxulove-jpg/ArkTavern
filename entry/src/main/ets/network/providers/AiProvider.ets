/**
 * AiProvider AI Provider 抽象接口
 *
 * 定义所有 AI Provider(OpenAI-compatible / Claude / Gemini 等)的统一契约。
 * 本阶段只定义非流式方法 sendChat,流式方法留待 T-1.5 扩展。
 *
 * 设计原则:
 * - Provider 不依赖页面或 ViewModel
 * - Provider 不直接读 Preferences
 * - Provider 通过依赖注入获得 HttpClient 和 ProviderKeyStore
 * - Provider 不缓存 API Key
 * - Provider 不实现流式逻辑(本阶段)
 *
 * 扩展策略(T-1.5):
 * 后续增加流式方法时,应在此抽象类追加 streamChat 方法,
 * 不破坏现有 sendChat 调用方。本阶段不预先定义 streamChat 签名,
 * 避免过度设计。
 *
 * 安全要求:
 * - 实现类不得在日志中输出 API Key、Authorization 或请求正文
 * - 实现类不得将 API Key 放入错误对象
 */

import { ProviderConfig } from '../../models/ProviderConfig';
import { ChatRequest } from '../../models/ChatRequest';
import { ChatResponse } from '../../models/ChatResponse';
import { NetworkError } from '../../models/NetworkError';

/**
 * AI Provider 抽象接口。
 * 使用抽象类以支持 ArkTS 严格模式并提供明确契约。
 *
 * 所有实现类必须实现 sendChat 方法。
 * 流式方法(T-1.5)将在后续任务追加,本阶段不定义。
 */
export abstract class AiProvider {
  /**
   * 发送非流式聊天请求,等待完整响应后返回。
   *
   * 实现要求:
   * 1. 从 ProviderKeyStore 读取 config.id 对应的 API Key
   * 2. 构造 Provider 特定的 URL
   * 3. 构造请求体(强制 stream=false)
   * 4. 通过 HttpClient 发起 POST 请求
   * 5. 解析响应并返回 ChatResponse
   * 6. 映射 HTTP/网络/解析错误为 NetworkError
   *
   * @param config Provider 配置(不含 API Key)
   * @param request 聊天请求
   * @returns 聊天响应
   * @throws NetworkError 当 API Key 不存在、网络错误、鉴权失败、解析失败时
   */
  abstract sendChat(config: ProviderConfig, request: ChatRequest): Promise<ChatResponse>;
}

/**
 * 类型守卫:判断未知对象是否为 NetworkError。
 * 用于 catch 块中安全类型断言。
 *
 * @param obj 未知对象
 * @returns 是 NetworkError 返回 true
 */
export function isNetworkError(obj: Object): boolean {
  if (obj === null || obj === undefined) {
    return false;
  }
  // NetworkError 是 interface,无法用 instanceof 判断;
  // 通过鸭子类型检查必需字段。
  const candidate = obj as NetworkError;
  return typeof candidate.type === 'string'
    && typeof candidate.message === 'string'
    && typeof candidate.retryable === 'boolean';
}
