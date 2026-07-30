/**
 * ArkWebAvatarAiToolRegistry — Avatar AI 工具注册表 (Phase 4A-3)
 *
 * 职责:
 *   - 读取 CapabilityCatalog 快照, 根据权限生成 Tool Definitions
 *   - 生成精简的能力说明 (buildCapabilityContext)
 *   - 校验工具名称 (isSupportedTool)
 *   - 校验工具参数字段 (validatePerformParams)
 *
 * 安全约束:
 *   - Tool Definition 不包含路径 / URL / resourceId / 文件大小 / 导入时间
 *   - Capability Context 只包含业务 ID + displayName + 默认标记
 *   - Capability Context 总长度限制 16384 字符
 *   - 超过时按动作/姿势顺序截断, 保留默认动作和默认姿势, 记录 truncated=true
 *
 * 权限模式:
 *   - DENY: 不注入任何工具
 *   - READ_ONLY: 只注入 avatar_list_capabilities + avatar_get_state
 *   - CONTROL_THIS_CHAT: 注入全部四个工具
 *
 * Reference:
 *   - AGENTS.md Phase 4A-3 §Tool Registry / §动态能力注入 / §权限控制
 */

import {
  ArkWebAvatarAiAnimationCapability,
  ArkWebAvatarAiCapabilitySnapshot,
  ArkWebAvatarAiExpressionCapability,
  ArkWebAvatarAiPoseCapability
} from '../vrmviewer/ArkWebAvatarAiTypes';
import {
  ArkWebChatToolDefinition,
  ArkWebAvatarAiToolName,
  AVATAR_AI_TOOL_NAMES,
  AVATAR_CAPABILITY_CONTEXT_MAX_LENGTH,
  AVATAR_TOOL_EXPRESSION_IDS,
  AVATAR_TOOL_MOTION_TYPES,
  AVATAR_TOOL_RETURN_POLICIES,
  ArkWebAvatarPerformParams,
  ArkWebAvatarAiToolErrorCode,
  ArkWebAvatarAiToolPermissionModeConst,
  isSafeBusinessId,
  containsUnsafeContent,
  hasUnsafeKeys,
  AVATAR_TOOL_NAME_MAX_LENGTH,
  AVATAR_TOOL_ARGUMENTS_MAX_LENGTH
} from './ArkWebAvatarAiToolTypes';

const LOG_TAG: string = 'AvatarAiToolRegistry';

/**
 * Avatar AI 工具注册表。
 *
 * 根据权限模式和能力快照生成 Tool Definitions,
 * 供 ChatService 注入到 Provider 请求中。
 */
export class ArkWebAvatarAiToolRegistry {
  /** 是否已销毁 */
  private disposed: boolean = false;

  /**
   * 根据权限和能力快照构建 Tool Definitions。
   *
   * @param snapshot 能力快照 (可能为 null)
   * @param permissionMode 权限模式 (DENY / READ_ONLY / CONTROL_THIS_CHAT)
   * @returns Tool Definition 数组 (DENY 时为空)
   */
  buildToolDefinitions(
    snapshot: ArkWebAvatarAiCapabilitySnapshot | null,
    permissionMode: string
  ): ArkWebChatToolDefinition[] {
    if (this.disposed) {
      return [];
    }

    // DENY: 不注入任何工具
    if (permissionMode === ArkWebAvatarAiToolPermissionModeConst.DENY) {
      return [];
    }

    const tools: ArkWebChatToolDefinition[] = [];

    // READ_ONLY 和 CONTROL_THIS_CHAT 都注入读取工具
    tools.push(this.buildListCapabilitiesTool());
    tools.push(this.buildGetStateTool());

    // 只有 CONTROL_THIS_CHAT 注入 perform 和 stop
    if (permissionMode === ArkWebAvatarAiToolPermissionModeConst.CONTROL_THIS_CHAT) {
      tools.push(this.buildPerformTool());
      tools.push(this.buildStopTool());
    }

    return tools;
  }

  /**
   * 生成精简的能力上下文字符串 (供系统提示词注入, 让 AI 知道可用能力)。
   *
   * 格式:
   *   Animations:
   *   - action_wave: Wave
   *   - action_idle: Idle (默认)
   *
   *   Poses:
   *   - pose_standing: Standing (默认)
   *
   *   Expressions:
   *   - happy
   *   - sad
   *
   * 总长度限制 AVATAR_CAPABILITY_CONTEXT_MAX_LENGTH (16384) 字符。
   * 超过时按动作/姿势顺序截断, 保留默认动作和默认姿势, 记录 truncated=true。
   *
   * @param snapshot 能力快照
   * @returns 能力上下文字符串 (无模型时返回空字符串)
   */
  buildCapabilityContext(snapshot: ArkWebAvatarAiCapabilitySnapshot | null): string {
    if (this.disposed || snapshot === null) {
      return '';
    }

    const lines: string[] = [];

    // 模型信息
    lines.push(`Model: ${snapshot.modelDisplayName}`);
    lines.push('');

    // 动画
    if (snapshot.animations.length > 0) {
      lines.push('Animations:');
      // 默认动作放首位
      const sorted: ArkWebAvatarAiAnimationCapability[] = this.sortAnimationsByDefault(
        snapshot.animations);
      for (let i = 0; i < sorted.length; i++) {
        const anim: ArkWebAvatarAiAnimationCapability = sorted[i];
        const suffix: string = anim.isDefaultIdle ? ' (默认)' : '';
        lines.push(`- ${anim.actionId}: ${anim.displayName}${suffix}`);
      }
      lines.push('');
    }

    // 姿势
    if (snapshot.poses.length > 0) {
      lines.push('Poses:');
      const sortedPoses: ArkWebAvatarAiPoseCapability[] = this.sortPosesByDefault(
        snapshot.poses);
      for (let i = 0; i < sortedPoses.length; i++) {
        const pose: ArkWebAvatarAiPoseCapability = sortedPoses[i];
        const suffix: string = pose.isDefaultPose ? ' (默认)' : '';
        lines.push(`- ${pose.poseId}: ${pose.displayName}${suffix}`);
      }
      lines.push('');
    }

    // 表情
    const availableExpressions: ArkWebAvatarAiExpressionCapability[] =
      snapshot.expressions.filter(
        (exp: ArkWebAvatarAiExpressionCapability): boolean => exp.available);
    if (availableExpressions.length > 0) {
      lines.push('Expressions:');
      for (let i = 0; i < availableExpressions.length; i++) {
        lines.push(`- ${availableExpressions[i].expressionId}`);
      }
    }

    let result: string = lines.join('\n');

    // 长度限制: 超过时截断
    if (result.length > AVATAR_CAPABILITY_CONTEXT_MAX_LENGTH) {
      result = result.slice(0, AVATAR_CAPABILITY_CONTEXT_MAX_LENGTH);
      result += '\n...[truncated]';
    }

    return result;
  }

  /**
   * 判断工具名是否为支持的 Avatar 工具。
   *
   * @param name 工具名
   * @returns 支持返回 true
   */
  isSupportedTool(name: string): boolean {
    return AVATAR_AI_TOOL_NAMES.indexOf(name) >= 0;
  }

  /**
   * 校验 avatar_perform 工具参数。
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
   *
   * @param params 待校验参数
   * @param snapshot 能力快照 (用于精确匹配 actionId / poseId)
   * @returns 校验通过返回 null, 失败返回 [errorCode, errorMessage]
   */
  validatePerformParams(
    params: ArkWebAvatarPerformParams,
    snapshot: ArkWebAvatarAiCapabilitySnapshot | null
  ): [string, string] | null {
    // motionType 校验
    if (AVATAR_TOOL_MOTION_TYPES.indexOf(params.motionType) < 0) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_INVALID,
        `invalid motionType: ${params.motionType}`];
    }

    // motionId 安全校验
    if (!isSafeBusinessId(params.motionId)) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_UNSAFE_FIELD,
        'motionId contains unsafe characters'];
    }
    if (containsUnsafeContent(params.motionId)) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_UNSAFE_FIELD,
        'motionId contains unsafe content'];
    }

    // expressionId 安全校验
    if (!isSafeBusinessId(params.expressionId)) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_UNSAFE_FIELD,
        'expressionId contains unsafe characters'];
    }

    // expressionId 白名单校验
    if (AVATAR_TOOL_EXPRESSION_IDS.indexOf(params.expressionId) < 0) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_INVALID,
        `invalid expressionId: ${params.expressionId}`];
    }

    // motionType 特定规则
    if (params.motionType === 'none') {
      // none: motionId 必须为空, expressionId 必须非空
      if (params.motionId.length > 0) {
        return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_INVALID,
          'motionId must be empty when motionType=none'];
      }
      if (params.expressionId.length === 0) {
        return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_INVALID,
          'expressionId must be non-empty when motionType=none'];
      }
    } else {
      // animation / pose: motionId 必须非空, 且精确匹配 actionId / poseId
      if (params.motionId.length === 0) {
        return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_INVALID,
          `motionId must be non-empty when motionType=${params.motionType}`];
      }
      if (snapshot === null) {
        return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_CAPABILITY_NOT_FOUND,
          'no model loaded'];
      }
      if (params.motionType === 'animation') {
        const found: boolean = snapshot.animations.some(
          (anim: ArkWebAvatarAiAnimationCapability): boolean =>
            anim.actionId === params.motionId);
        if (!found) {
          return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_CAPABILITY_NOT_FOUND,
            `actionId not found: ${params.motionId}`];
        }
      } else if (params.motionType === 'pose') {
        const found: boolean = snapshot.poses.some(
          (pose: ArkWebAvatarAiPoseCapability): boolean =>
            pose.poseId === params.motionId);
        if (!found) {
          return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_CAPABILITY_NOT_FOUND,
            `poseId not found: ${params.motionId}`];
        }
      }
    }

    // expressionWeight 范围校验 (0..1)
    if (params.expressionWeight < 0 || params.expressionWeight > 1) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_INVALID,
        `expressionWeight out of range [0,1]: ${params.expressionWeight}`];
    }

    // durationMs 范围校验 (100..30000)
    if (params.durationMs < 100 || params.durationMs > 30000) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_INVALID,
        `durationMs out of range [100,30000]: ${params.durationMs}`];
    }

    // returnPolicy 白名单校验
    if (AVATAR_TOOL_RETURN_POLICIES.indexOf(params.returnPolicy) < 0) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_INVALID,
        `invalid returnPolicy: ${params.returnPolicy}`];
    }

    return null;
  }

  /**
   * 校验工具名基本合法性 (长度 + 白名单)。
   *
   * @param name 工具名
   * @returns 校验通过返回 null, 失败返回 [errorCode, errorMessage]
   */
  validateToolName(name: string): [string, string] | null {
    if (name.length === 0 || name.length > AVATAR_TOOL_NAME_MAX_LENGTH) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_NAME_INVALID,
        `tool name length invalid: ${name.length}`];
    }
    if (!this.isSupportedTool(name)) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_NAME_INVALID,
        `unsupported tool name: ${name}`];
    }
    return null;
  }

  /**
   * 校验 argumentsJson 基本合法性 (长度 + JSON 解析 + 根节点对象 + 无危险键)。
   *
   * @param argumentsJson 参数 JSON 字符串
   * @returns 校验通过返回 null, 失败返回 [errorCode, errorMessage]
   */
  validateArgumentsJson(argumentsJson: string): [string, string] | null {
    if (argumentsJson.length > AVATAR_TOOL_ARGUMENTS_MAX_LENGTH) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_TOO_LARGE,
        `argumentsJson too large: ${argumentsJson.length}`];
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(argumentsJson);
    } catch (e) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_PARSE_FAILED,
        'argumentsJson is not valid JSON'];
    }
    // 根节点必须为对象, 拒绝数组根节点
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_ARGUMENTS_INVALID,
        'argumentsJson root must be object'];
    }
    const record: Record<string, Object> = parsed as Record<string, Object>;
    if (hasUnsafeKeys(record)) {
      return [ArkWebAvatarAiToolErrorCode.AVATAR_TOOL_UNSAFE_FIELD,
        'argumentsJson contains unsafe key (__proto__/prototype/constructor)'];
    }
    return null;
  }

  /**
   * 销毁 (清空状态, 后续 buildToolDefinitions 返回空)。
   */
  dispose(): void {
    this.disposed = true;
  }

  // ===== 内部: 构建单个 Tool Definition =====

  private buildListCapabilitiesTool(): ArkWebChatToolDefinition {
    return {
      name: ArkWebAvatarAiToolName.AVATAR_LIST_CAPABILITIES,
      description: 'List the current avatar model\'s available animations, poses, and expressions. ' +
        'Returns business IDs only (actionId, poseId, expressionId). ' +
        'No file paths or resource URLs are exposed.',
      inputSchemaJson: '{"type":"object","properties":{},"additionalProperties":false}'
    };
  }

  private buildPerformTool(): ArkWebChatToolDefinition {
    return {
      name: ArkWebAvatarAiToolName.AVATAR_PERFORM,
      description: 'Perform an avatar animation, pose, or expression. ' +
        'Use motionType="animation" with a valid actionId, ' +
        'motionType="pose" with a valid poseId, ' +
        'or motionType="none" with a non-empty expressionId. ' +
        'motionId must exactly match an actionId or poseId from avatar_list_capabilities.',
      inputSchemaJson: '{"type":"object","properties":{' +
        '"motionType":{"type":"string","enum":["animation","pose","none"],"description":"Type of motion to perform."},' +
        '"motionId":{"type":"string","description":"actionId (for animation) or poseId (for pose). Empty when motionType=none."},' +
        '"expressionId":{"type":"string","enum":["neutral","happy","angry","sad","relaxed","surprised"],"description":"Optional facial expression to apply. Empty string for no expression."},' +
        '"expressionWeight":{"type":"number","minimum":0,"maximum":1,"description":"Expression blend weight, 0 to 1."},' +
        '"durationMs":{"type":"integer","minimum":100,"maximum":30000,"description":"Duration in milliseconds (100-30000)."},' +
        '"returnPolicy":{"type":"string","enum":["DEFAULT_POSE","RESET","KEEP"],"description":"What to do after the performance ends."}' +
        '},' +
        '"required":["motionType","motionId","expressionId","expressionWeight","durationMs","returnPolicy"],' +
        '"additionalProperties":false}'
    };
  }

  private buildStopTool(): ArkWebChatToolDefinition {
    return {
      name: ArkWebAvatarAiToolName.AVATAR_STOP,
      description: 'Stop the currently running AI-initiated avatar performance. ' +
        'Only stops performances started by avatar_perform (AI tool calls). ' +
        'Does not stop user-initiated performances from the AI panel.',
      inputSchemaJson: '{"type":"object","properties":{},"additionalProperties":false}'
    };
  }

  private buildGetStateTool(): ArkWebChatToolDefinition {
    return {
      name: ArkWebAvatarAiToolName.AVATAR_GET_STATE,
      description: 'Get the current avatar business state. ' +
        'Returns connection status, model readiness, current shot, performance state, ' +
        'and active motion/expression. Does not return camera coordinates or debug internals.',
      inputSchemaJson: '{"type":"object","properties":{},"additionalProperties":false}'
    };
  }

  // ===== 内部: 排序 (默认在前) =====

  private sortAnimationsByDefault(
    animations: ArkWebAvatarAiAnimationCapability[]
  ): ArkWebAvatarAiAnimationCapability[] {
    const result: ArkWebAvatarAiAnimationCapability[] = [];
    // 默认动作放首位
    for (let i = 0; i < animations.length; i++) {
      if (animations[i].isDefaultIdle) {
        result.push(animations[i]);
      }
    }
    for (let i = 0; i < animations.length; i++) {
      if (!animations[i].isDefaultIdle) {
        result.push(animations[i]);
      }
    }
    return result;
  }

  private sortPosesByDefault(
    poses: ArkWebAvatarAiPoseCapability[]
  ): ArkWebAvatarAiPoseCapability[] {
    const result: ArkWebAvatarAiPoseCapability[] = [];
    for (let i = 0; i < poses.length; i++) {
      if (poses[i].isDefaultPose) {
        result.push(poses[i]);
      }
    }
    for (let i = 0; i < poses.length; i++) {
      if (!poses[i].isDefaultPose) {
        result.push(poses[i]);
      }
    }
    return result;
  }
}
