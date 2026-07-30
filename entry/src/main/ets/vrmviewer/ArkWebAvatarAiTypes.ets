/**
 * ArkWebAvatarAiTypes — AI Tab 与模型能力目录类型 (Phase 4A-1)
 *
 * 职责:
 *   - 定义 AI 能力目录对外暴露的业务能力类型 (动画/姿势/表情)
 *   - 定义能力快照 (ArkWebAvatarAiCapabilitySnapshot)
 *   - 定义 AI Tab 状态机枚举
 *   - 定义未来与聊天页面的契约接口 (ArkWebAvatarAiChatResult)
 *
 * 安全约束 (AGENTS.md Phase 4A-1 §AI 能力目录职责):
 *   - 只暴露业务 ID (actionId / poseId / expressionId / displayName / 默认标记 / 映射是否可用)
 *   - 禁止暴露 absolutePath / relativePath / filesDir / resourceId / resourceUrl / Provider URL
 *   - 禁止暴露文件描述符 / Three.js 对象 / VRM 对象 / 骨骼数据
 *   - 业务表情固定为 6 个 ID: neutral / happy / angry / sad / relaxed / surprised
 *
 * 本阶段不实现:
 *   - 真实 AI 网络请求
 *   - 聊天历史 / 系统提示词 / API Key / Provider 配置
 *   - 原始 AI 响应对象解析
 *
 * Reference:
 *   - AGENTS.md Phase 4A-1 §AI 能力目录 / §与聊天页面的未来接口
 *   - ArkWebAvatarAssetTypes.ets (ArkWebExpressionAliasBusinessId)
 */

/**
 * AI 能力目录状态机。
 *
 * 状态流转:
 *   IDLE → LOADING → READY
 *   IDLE → LOADING → EMPTY (无模型 / 无任何能力)
 *   IDLE → LOADING → FAILED (读取 library 失败)
 *   任意 → DISPOSED (页面销毁)
 *
 * 不得使用轮询;刷新时机由调用方触发 (页面进入 / 模型 READY / 模型替换 /
 * 动画导入删除重命名 / 姿势导入 / 表情别名变化 / 用户点击刷新)。
 */
export enum ArkWebAvatarAiCapabilityState {
  IDLE = 'IDLE',
  LOADING = 'LOADING',
  READY = 'READY',
  EMPTY = 'EMPTY',
  FAILED = 'FAILED',
  DISPOSED = 'DISPOSED'
}

/**
 * AI 能力目录错误码 (Phase 4A-1)。
 */
export class ArkWebAvatarAiCapabilityErrorCode {
  /** AssetLibrary 未注入或已销毁。 */
  static readonly AI_CAPABILITY_LIBRARY_INVALID: string = 'AI_CAPABILITY_LIBRARY_INVALID';
  /** activeModelId 为空 (无激活模型)。 */
  static readonly AI_CAPABILITY_NO_ACTIVE_MODEL: string = 'AI_CAPABILITY_NO_ACTIVE_MODEL';
  /** 读取 library 失败。 */
  static readonly AI_CAPABILITY_LIBRARY_READ_FAILED: string = 'AI_CAPABILITY_LIBRARY_READ_FAILED';
  /** 能力目录已销毁。 */
  static readonly AI_CAPABILITY_DISPOSED: string = 'AI_CAPABILITY_DISPOSED';
}

/**
 * 可调用动画能力 (Phase 4A-1)。
 *
 * 只暴露业务字段:
 *   - actionId: 业务动画 ID (用于 ArkWebDialoguePerformanceHint.motionId)
 *   - displayName: 用户可读名称
 *   - isDefaultIdle: 是否为默认待机动作
 *
 * 禁止字段:
 *   - resourceId / relativePath / absolutePath / cachePath
 *   - mimeType / byteLength / createdAt / updatedAt
 */
export interface ArkWebAvatarAiAnimationCapability {
  actionId: string;
  displayName: string;
  isDefaultIdle: boolean;
}

/**
 * 可调用姿势能力 (Phase 4A-1)。
 *
 * 只暴露业务字段:
 *   - poseId: 业务姿势 ID (用于 ArkWebDialoguePerformanceHint.motionId)
 *   - displayName: 用户可读名称
 *   - isDefaultPose: 是否为默认姿势
 *
 * 禁止字段:
 *   - relativePath / absolutePath / cachePath
 *   - byteLength / format / createdAt / updatedAt
 */
export interface ArkWebAvatarAiPoseCapability {
  poseId: string;
  displayName: string;
  isDefaultPose: boolean;
}

/**
 * 可调用表情能力 (Phase 4A-1)。
 *
 * 表情业务 ID 固定为 6 个: neutral / happy / angry / sad / relaxed / surprised。
 * 不同模型通过 expressionAliases 映射到真实 expressionName。
 * available=false 表示该业务 ID 当前模型未映射或映射目标不存在。
 *
 * 只暴露业务字段:
 *   - expressionId: 业务表情 ID (用于 ArkWebDialoguePerformanceHint.expressionId)
 *   - mappedExpressionName: 映射到的模型真实 expressionName (空字符串表示未映射)
 *   - available: 映射是否存在且非空
 *
 * 禁止字段:
 *   - 文件路径 / 资源 URL / 骨骼 / BlendShape 对象
 */
export interface ArkWebAvatarAiExpressionCapability {
  expressionId: string;
  mappedExpressionName: string;
  available: boolean;
}

/**
 * AI 能力快照 (Phase 4A-1)。
 *
 * 由 ArkWebAvatarAiCapabilityCatalog.buildSnapshot 生成,
 * 包含当前模型可用的全部业务能力,供 AI Tab UI 展示。
 *
 * 字段:
 *   - modelId: 当前激活模型 ID (空字符串表示无激活模型)
 *   - modelDisplayName: 模型显示名 (用于 UI 展示)
 *   - animations: 动画能力列表 (来自 library.animations)
 *   - poses: 姿势能力列表 (来自 library.poses)
 *   - expressions: 表情能力列表 (6 个固定业务 ID + 映射状态)
 *   - defaultIdleActionId: 默认待机 actionId (空字符串表示无默认)
 *   - defaultPoseId: 默认姿势 poseId (空字符串表示无默认)
 *   - generatedAt: 快照生成时间戳 (ms)
 *
 * 旧清单缺少 animations / poses / expressionAliases 时,
 * 对应数组为空或 available=false,快照不失败。
 */
export interface ArkWebAvatarAiCapabilitySnapshot {
  modelId: string;
  modelDisplayName: string;

  animations: ArkWebAvatarAiAnimationCapability[];
  poses: ArkWebAvatarAiPoseCapability[];
  expressions: ArkWebAvatarAiExpressionCapability[];

  defaultIdleActionId: string;
  defaultPoseId: string;

  generatedAt: number;
}

/**
 * 未来与聊天页面的契约接口 (Phase 4A-1 仅定义,不实现)。
 *
 * 聊天页面只能传:
 *   - turnId: 对话轮次 ID
 *   - performanceHintJson: AI 返回的演出 Hint JSON 字符串
 *
 * 文本仍由聊天页面自行显示,AI Tab 不接收:
 *   - 完整聊天历史
 *   - 系统提示词
 *   - API Key
 *   - Provider 配置
 *   - 原始 AI 响应对象
 */
export interface ArkWebAvatarAiChatResult {
  turnId: string;
  text: string;
  performanceHintJson: string;
}

/**
 * 固定业务表情 ID 列表 (与 ArkWebExpressionAliasBusinessId.ALL 一致)。
 *
 * 用于 ArkWebAvatarAiCapabilityCatalog 生成表情能力列表时遍历。
 */
export const AI_CAPABILITY_EXPRESSION_BUSINESS_IDS: string[] = [
  'neutral',
  'happy',
  'angry',
  'sad',
  'relaxed',
  'surprised'
];

/**
 * 业务表情 ID 到中文显示名的映射 (用于 AI Tab UI 展示)。
 *
 * 与 ArkWebExpressionAliasBusinessId 保持一致,只用于 UI 显示,
 * 不参与业务逻辑判断。
 */
export const AI_CAPABILITY_EXPRESSION_DISPLAY_NAMES: Record<string, string> = {
  'neutral': '中立',
  'happy': '开心',
  'angry': '生气',
  'sad': '悲伤',
  'relaxed': '放松',
  'surprised': '惊讶'
};
