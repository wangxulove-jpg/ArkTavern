/**
 * ArkWebAvatarChatBridgeTypes — Avatar ↔ 聊天桥接器类型 (Phase 4A-2)
 *
 * 职责:
 *   - 定义最终助手消息结果类型 (ArkWebAvatarChatFinalResult)
 *   - 定义桥接器状态机 (ArkWebAvatarChatBridgeState)
 *   - 定义 Avatar endpoint handler 签名
 *   - 定义错误码常量
 *   - 定义 source 标识常量
 *
 * 安全约束 (AGENTS.md Phase 4A-2 §消息类型):
 *   - 只允许字段: turnId / performanceHintJson / finalizedAt / source
 *   - 禁止携带: 完整聊天历史 / 系统提示词 / API Key / Provider 配置 /
 *               模型路径 / 资源 URL / 用户原始输入 / AI 原始响应对象 /
 *               Three.js / VRM 对象
 *
 * 不实现:
 *   - 真实 AI Tool Calling
 *   - 自然语言解析 / Markdown 解析
 *   - 网络请求 / WebSocket / 文件轮询 / setInterval / 数据库 / 系统剪贴板
 *
 * Reference:
 *   - AGENTS.md Phase 4A-2 §消息类型 / §Bridge 状态 / §无 Avatar 消费者时
 *   - ArkWebDialoguePerformanceLifecycleController.ets (消费 turnId + hint)
 */

/**
 * 最终助手消息结果 (从单人聊天发布到 Avatar 桥接器)。
 *
 * 字段约束:
 *   - turnId: 非空,来自真实消息 ID / 请求 ID / 稳定的本地 turn ID
 *   - performanceHintJson: 可为空字符串;只允许来自结构化结果字段
 *   - finalizedAt: 消息完成时间戳 (ms)
 *   - source: 发布来源标识 (SINGLE_CHAT / AI_TAB_MANUAL_TEST 等)
 *
 * 禁止字段 (违反则桥接器拒绝):
 *   - 完整聊天历史 / 系统提示词 / API Key / Provider 配置
 *   - 模型路径 / 资源 URL / 用户原始输入 / AI 原始响应对象
 *   - Three.js / VRM 对象
 */
export interface ArkWebAvatarChatFinalResult {
  /** 对话轮次 ID (非空,来自真实消息 ID / 请求 ID / 稳定本地 turn ID) */
  turnId: string;
  /** AI 返回的演出 Hint JSON 字符串 (可为空字符串) */
  performanceHintJson: string;
  /** 消息完成时间戳 (ms) */
  finalizedAt: number;
  /** 发布来源标识 (见 ArkWebAvatarChatFinalResultSource) */
  source: string;
}

/**
 * Avatar endpoint handler 签名。
 *
 * VrmViewerPage 在 aboutToAppear 中注册此 handler,
 * 桥接器在 Avatar endpoint 就绪后调用 handler 处理待处理结果。
 *
 * handler 内部必须经过 DialoguePerformanceLifecycleController,
 * 不得直接调用 PerformanceController / Mapper / 动画 / 姿势 / 表情运行时。
 *
 * @param result 最终助手消息结果 (只读)
 * @returns Promise<void> handler 应捕获自身异常,桥接器不强制要求 reject
 */
export type ArkWebAvatarChatEndpointHandler =
  (result: ArkWebAvatarChatFinalResult) => Promise<void>;

/**
 * 桥接器状态机 (Phase 4A-2)。
 *
 * 状态流转:
 *   DISCONNECTED (初始)
 *     ├─ registerChatEndpoint → CHAT_READY
 *     └─ registerAvatarEndpoint → AVATAR_READY
 *   CHAT_READY
 *     ├─ registerAvatarEndpoint → CONNECTED
 *     └─ unregisterChatEndpoint → DISCONNECTED
 *   AVATAR_READY
 *     ├─ registerChatEndpoint → CONNECTED
 *     └─ unregisterAvatarEndpoint → DISCONNECTED
 *   CONNECTED
 *     ├─ unregisterChatEndpoint → AVATAR_READY
 *     └─ unregisterAvatarEndpoint → CHAT_READY
 *   任意 → DISPOSED (dispose 调用,不可恢复)
 *
 * 同一时刻允许:
 *   - 多个 chat endpoint (至少一个就为 CHAT_READY)
 *   - 单个 avatar endpoint (覆盖式注册)
 */
export enum ArkWebAvatarChatBridgeState {
  DISCONNECTED = 'DISCONNECTED',
  CHAT_READY = 'CHAT_READY',
  AVATAR_READY = 'AVATAR_READY',
  CONNECTED = 'CONNECTED',
  DISPOSED = 'DISPOSED'
}

/**
 * 桥接器错误码常量 (Phase 4A-2)。
 *
 * 错误隔离原则:
 *   - 桥接器 / Avatar 演出失败不影响聊天文本显示
 *   - 聊天页面只记录轻量日志,不弹出阻塞式错误
 */
export class ArkWebAvatarChatBridgeErrorCode {
  /** turnId 为空或非法 */
  static readonly AVATAR_CHAT_TURN_ID_INVALID: string = 'AVATAR_CHAT_TURN_ID_INVALID';
  /** 相同 turnId 已发布 (按 DUPLICATE_TURN_POLICY:IGNORE 忽略) */
  static readonly AVATAR_CHAT_DUPLICATE_TURN: string = 'AVATAR_CHAT_DUPLICATE_TURN';
  /** 待处理队列已满 (按 NO_CONSUMER_POLICY:QUEUE LATEST RESULTS,超过上限丢弃最旧) */
  static readonly AVATAR_CHAT_QUEUE_FULL: string = 'AVATAR_CHAT_QUEUE_FULL';
  /** 无 Avatar endpoint 注册 (结果入队但不投递,不视为错误) */
  static readonly AVATAR_CHAT_ENDPOINT_MISSING: string = 'AVATAR_CHAT_ENDPOINT_MISSING';
  /** Avatar handler 投递失败 (handler 抛异常或返回 reject) */
  static readonly AVATAR_CHAT_DELIVERY_FAILED: string = 'AVATAR_CHAT_DELIVERY_FAILED';
  /** 桥接器已销毁 (应用退出) */
  static readonly AVATAR_CHAT_BRIDGE_DISPOSED: string = 'AVATAR_CHAT_BRIDGE_DISPOSED';
}

/**
 * 最终消息来源标识 (Phase 4A-2)。
 *
 * - SINGLE_CHAT: 真实单人聊天页面发布的最终消息
 * - AI_TAB_MANUAL_TEST: AI Tab 手动测试入口发布的结果
 *
 * 其他来源 (群体聊天 / 历史回放 / 自动化测试) 留待后续阶段扩展,
 * 本阶段只允许这两个常量。
 */
export class ArkWebAvatarChatFinalResultSource {
  static readonly SINGLE_CHAT: string = 'SINGLE_CHAT';
  static readonly AI_TAB_MANUAL_TEST: string = 'AI_TAB_MANUAL_TEST';
}

/**
 * 待处理队列上限 (Phase 4A-2)。
 *
 * - 最大 8 条
 * - 按 finalizedAt 顺序
 * - 相同 turnId 去重
 * - 超过上限丢弃最旧项
 */
export const ARKWEB_AVATAR_CHAT_QUEUE_LIMIT: number = 8;
