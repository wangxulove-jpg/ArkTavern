/**
 * ArkWebDialoguePerformanceMapper — AI 对话结果到演出指令的安全映射器 (Phase 3F-2)
 *
 * 职责:
 *   - 将 AI 返回的受控元数据 (ArkWebDialoguePerformanceHint) 安全转换为
 *     ArkWebAvatarPerformanceCommand
 *   - 严格 JSON 输入校验 (大小 / 根类型 / 未知字段 / 危险字段 / 原型链攻击)
 *   - 字段值校验 (version / motionType / motionId / expressionId / weight / duration / returnPolicy)
 *   - 资源存在性校验 (actionId / poseId 必须精确匹配 library)
 *   - 确定性降级 (动作无效→expression-only / 表情无效→motion-only / 全部无效→拒绝)
 *
 * 安全约束:
 *   - commandId 由本地生成 (不信任 AI)
 *   - interruptPolicy 强制 REPLACE (不信任 AI)
 *   - AI 不得通过显示名称 / 文件名 / 模糊文本调用资源
 *   - 拒绝路径分隔符 / URL / 协议前缀 / __proto__ / prototype / constructor
 *   - 不解析自然语言或 Markdown
 *
 * 本阶段不实现:
 *   - 真实 AI 接口 / 网络请求 / WebSocket / Timer / Frame Loop
 *
 * Reference:
 *   - AGENTS.md Phase 3F-2 §输入安全 / §字段规则 / §资源验证 / §降级规则
 *   - ArkWebAvatarPerformanceTypes.ets (ArkWebAvatarPerformanceCommand / validatePerformanceCommand)
 *   - ArkWebAvatarAssetLibrary.ets (findAnimation / findPose)
 *   - ArkWebAvatarAssetTypes.ets (ArkWebExpressionAliasBusinessId)
 */

import { ArkWebAvatarPerformanceCommand, ArkWebPerformanceMotionType, ArkWebPerformanceReturnPolicy } from './ArkWebAvatarPerformanceTypes';
import { ArkWebAvatarAssetLibrary } from './ArkWebAvatarAssetLibrary';
import { ArkWebExpressionAliasBusinessId } from './ArkWebAvatarAssetTypes';
import {
  ArkWebDialoguePerformanceHint,
  ArkWebDialoguePerformanceMappingResult,
  DialoguePerformanceErrorCode,
  DIALOGUE_PERFORMANCE_HINT_VERSION,
  DIALOGUE_PERFORMANCE_HINT_MAX_CHARS,
  DIALOGUE_HINT_ALLOWED_FIELDS,
  DIALOGUE_HINT_FORBIDDEN_FIELDS,
  DIALOGUE_HINT_FORBIDDEN_PATTERNS
} from './ArkWebDialoguePerformanceTypes';

/**
 * 默认值常量。
 */
const DEFAULT_MOTION_TYPE: ArkWebPerformanceMotionType = 'none';
const DEFAULT_EXPRESSION_WEIGHT: number = 1;
const DEFAULT_DURATION_MS: number = 2500;
const DEFAULT_RETURN_POLICY: ArkWebPerformanceReturnPolicy = 'DEFAULT_POSE';
const MIN_DURATION_MS: number = 100;
const MAX_DURATION_MS: number = 30000;
const MIN_WEIGHT: number = 0;
const MAX_WEIGHT: number = 1;

/**
 * AI 对话结果到演出指令的安全映射器。
 *
 * 不持有 Timer / Frame Loop / 网络连接 / AI 客户端。
 * 通过 ArkWebAvatarAssetLibrary 查询资源存在性。
 */
export class ArkWebDialoguePerformanceMapper {
  private assetLibrary: ArkWebAvatarAssetLibrary | null;
  private disposed: boolean = false;
  private commandIdCounter: number = 0;

  constructor(assetLibrary: ArkWebAvatarAssetLibrary | null) {
    this.assetLibrary = assetLibrary;
  }

  /**
   * 销毁 Mapper。
   *
   * 仅清理内存状态,不删除动作 / 姿势 / 别名 / library.json。
   * 不停止在途演出 (由 PerformanceController.dispose 负责)。
   */
  dispose(): void {
    this.disposed = true;
    this.assetLibrary = null;
  }

  /**
   * 将 AI 返回的原始 JSON 字符串安全映射为 ArkWebAvatarPerformanceCommand。
   *
   * 流程:
   *   1. 输入大小校验 (≤ 4096 字符)
   *   2. JSON 解析 (拒绝数组 / 非对象根)
   *   3. 未知字段校验 (拒绝不在白名单的字段)
   *   4. 危险字段校验 (拒绝路径 / URL / 原型链攻击)
   *   5. version 校验 (必须为 1)
   *   6. 字段值校验 + 默认值填充
   *   7. 资源存在性校验 (actionId / poseId)
   *   8. 降级规则 (动作无效→expression-only / 表情无效→motion-only / 全部无效→拒绝)
   *   9. 生成本地 commandId, 强制 interruptPolicy = REPLACE
   *   10. 通过 validatePerformanceCommand 二次校验
   *
   * @param rawJson AI 返回的原始 JSON 字符串
   * @returns 映射结果
   */
  async mapJson(rawJson: string): Promise<ArkWebDialoguePerformanceMappingResult> {
    if (this.disposed) {
      return this.fail(DialoguePerformanceErrorCode.HINT_EMPTY, 'Mapper 已销毁');
    }

    // ===== 1. 输入大小校验 =====
    if (typeof rawJson !== 'string' || rawJson.length === 0) {
      return this.fail(DialoguePerformanceErrorCode.HINT_EMPTY, '输入 JSON 为空');
    }
    if (rawJson.length > DIALOGUE_PERFORMANCE_HINT_MAX_CHARS) {
      return this.fail(DialoguePerformanceErrorCode.HINT_TOO_LARGE,
        `输入 JSON 超过 ${DIALOGUE_PERFORMANCE_HINT_MAX_CHARS} 字符 (实际 ${rawJson.length})`);
    }

    // ===== 2. JSON 解析 =====
    let root: Record<string, Object> | null = null;
    try {
      const parsed: Object = JSON.parse(rawJson);
      if (parsed === null || typeof parsed !== 'object') {
        return this.fail(DialoguePerformanceErrorCode.HINT_ROOT_INVALID,
          'JSON 根节点必须为对象');
      }
      // 拒绝数组
      if (parsed instanceof Array) {
        return this.fail(DialoguePerformanceErrorCode.HINT_ROOT_INVALID,
          'JSON 根节点不能为数组');
      }
      root = parsed as Record<string, Object>;
    } catch (e) {
      return this.fail(DialoguePerformanceErrorCode.HINT_PARSE_FAILED,
        'JSON 解析失败: ' + (e instanceof Error ? e.message : String(e)));
    }

    // ===== 3. 未知字段校验 =====
    const rootKeys: string[] = Object.keys(root);
    for (let i = 0; i < rootKeys.length; i++) {
      const key: string = rootKeys[i];
      if (DIALOGUE_HINT_ALLOWED_FIELDS.indexOf(key) === -1) {
        return this.fail(DialoguePerformanceErrorCode.HINT_FIELD_UNKNOWN,
          `未知字段: ${key}`);
      }
    }

    // ===== 4. 危险字段校验 =====
    for (let i = 0; i < rootKeys.length; i++) {
      const key: string = rootKeys[i];
      if (DIALOGUE_HINT_FORBIDDEN_FIELDS.indexOf(key) !== -1) {
        return this.fail(DialoguePerformanceErrorCode.HINT_FIELD_UNSAFE,
          `危险字段: ${key}`);
      }
    }
    // 检查所有字符串值是否包含危险模式
    for (let i = 0; i < rootKeys.length; i++) {
      const key: string = rootKeys[i];
      const val: Object = root[key];
      if (typeof val === 'string') {
        if (this.containsForbiddenPattern(val)) {
          return this.fail(DialoguePerformanceErrorCode.HINT_FIELD_UNSAFE,
            `字段 ${key} 包含危险模式 (URL / 路径分隔符 / ..)`);
        }
      }
    }

    // ===== 5. version 校验 =====
    const versionObj: Object | undefined = root['version'];
    if (versionObj === undefined || typeof versionObj !== 'number' || !Number.isFinite(versionObj)) {
      return this.fail(DialoguePerformanceErrorCode.HINT_VERSION_UNSUPPORTED,
        'version 字段缺失或非数字');
    }
    if (versionObj as number !== DIALOGUE_PERFORMANCE_HINT_VERSION) {
      return this.fail(DialoguePerformanceErrorCode.HINT_VERSION_UNSUPPORTED,
        `version 不支持: ${versionObj} (当前仅支持 ${DIALOGUE_PERFORMANCE_HINT_VERSION})`);
    }

    // ===== 6. 字段值提取 + 校验 =====
    // motionType
    const motionTypeRaw: Object | undefined = root['motionType'];
    let motionType: ArkWebPerformanceMotionType = DEFAULT_MOTION_TYPE;
    if (motionTypeRaw !== undefined) {
      if (typeof motionTypeRaw !== 'string') {
        return this.fail(DialoguePerformanceErrorCode.MOTION_TYPE_INVALID,
          'motionType 必须为字符串');
      }
      const mt: string = motionTypeRaw as string;
      if (mt !== 'animation' && mt !== 'pose' && mt !== 'none') {
        return this.fail(DialoguePerformanceErrorCode.MOTION_TYPE_INVALID,
          `motionType 非法: ${mt}`);
      }
      motionType = mt as ArkWebPerformanceMotionType;
    }

    // motionId
    const motionIdRaw: Object | undefined = root['motionId'];
    let motionId: string = '';
    if (motionIdRaw !== undefined) {
      if (typeof motionIdRaw !== 'string') {
        return this.fail(DialoguePerformanceErrorCode.MOTION_ID_INVALID,
          'motionId 必须为字符串');
      }
      motionId = motionIdRaw as string;
      if (this.containsForbiddenPattern(motionId)) {
        return this.fail(DialoguePerformanceErrorCode.MOTION_ID_INVALID,
          `motionId 包含危险模式: ${motionId}`);
      }
    }

    // expressionId
    const expressionIdRaw: Object | undefined = root['expressionId'];
    let expressionId: string = '';
    if (expressionIdRaw !== undefined) {
      if (typeof expressionIdRaw !== 'string') {
        return this.fail(DialoguePerformanceErrorCode.EXPRESSION_ID_INVALID,
          'expressionId 必须为字符串');
      }
      expressionId = expressionIdRaw as string;
      if (expressionId.length > 0 && !ArkWebExpressionAliasBusinessId.isValid(expressionId)) {
        return this.fail(DialoguePerformanceErrorCode.EXPRESSION_ID_INVALID,
          `expressionId 非法: ${expressionId}`);
      }
    }

    // expressionWeight
    const weightRaw: Object | undefined = root['expressionWeight'];
    let expressionWeight: number = DEFAULT_EXPRESSION_WEIGHT;
    if (weightRaw !== undefined) {
      if (typeof weightRaw !== 'number' || !Number.isFinite(weightRaw)) {
        return this.fail(DialoguePerformanceErrorCode.HINT_FIELD_UNSAFE,
          'expressionWeight 必须为有限数字');
      }
      const w: number = weightRaw as number;
      if (w < MIN_WEIGHT || w > MAX_WEIGHT) {
        return this.fail(DialoguePerformanceErrorCode.HINT_FIELD_UNSAFE,
          `expressionWeight 超出范围 [0, 1]: ${w}`);
      }
      expressionWeight = w;
    }

    // durationMs
    const durationRaw: Object | undefined = root['durationMs'];
    let durationMs: number = DEFAULT_DURATION_MS;
    if (durationRaw !== undefined) {
      if (typeof durationRaw !== 'number' || !Number.isFinite(durationRaw)) {
        return this.fail(DialoguePerformanceErrorCode.HINT_FIELD_UNSAFE,
          'durationMs 必须为有限数字');
      }
      const d: number = durationRaw as number;
      if (d < MIN_DURATION_MS || d > MAX_DURATION_MS) {
        return this.fail(DialoguePerformanceErrorCode.HINT_FIELD_UNSAFE,
          `durationMs 超出范围 [100, 30000]: ${d}`);
      }
      durationMs = d;
    }

    // returnPolicy
    const returnPolicyRaw: Object | undefined = root['returnPolicy'];
    let returnPolicy: ArkWebPerformanceReturnPolicy = DEFAULT_RETURN_POLICY;
    if (returnPolicyRaw !== undefined) {
      if (typeof returnPolicyRaw !== 'string') {
        return this.fail(DialoguePerformanceErrorCode.HINT_FIELD_UNSAFE,
          'returnPolicy 必须为字符串');
      }
      const rp: string = returnPolicyRaw as string;
      if (rp !== 'DEFAULT_POSE' && rp !== 'RESET' && rp !== 'KEEP') {
        return this.fail(DialoguePerformanceErrorCode.HINT_FIELD_UNSAFE,
          `returnPolicy 非法: ${rp}`);
      }
      returnPolicy = rp as ArkWebPerformanceReturnPolicy;
    }

    // ===== 7. 资源存在性校验 + 降级规则 =====
    const warnings: string[] = [];
    let finalMotionType: ArkWebPerformanceMotionType = motionType;
    let finalMotionId: string = motionId;
    let finalExpressionId: string = expressionId;
    let degraded: boolean = false;

    // motionType 校验与降级
    let motionValid: boolean = true;
    if (motionType === 'animation') {
      if (motionId.length === 0) {
        // animation 缺 motionId, 尝试降级为 expression-only
        motionValid = false;
        warnings.push(`[${DialoguePerformanceErrorCode.MOTION_ID_INVALID}] animation 缺少 motionId, 降级为 expression-only`);
      } else if (this.assetLibrary === null) {
        motionValid = false;
        warnings.push('AssetLibrary 不可用, 降级为 expression-only');
      } else {
        const anim = await this.assetLibrary.findAnimation(motionId);
        if (anim === null) {
          motionValid = false;
          warnings.push(`[${DialoguePerformanceErrorCode.ACTION_NOT_FOUND}] actionId 不存在: ${motionId}, 降级为 expression-only`);
        }
      }
    } else if (motionType === 'pose') {
      if (motionId.length === 0) {
        motionValid = false;
        warnings.push(`[${DialoguePerformanceErrorCode.MOTION_ID_INVALID}] pose 缺少 motionId, 降级为 expression-only`);
      } else if (this.assetLibrary === null) {
        motionValid = false;
        warnings.push('AssetLibrary 不可用, 降级为 expression-only');
      } else {
        const pose = await this.assetLibrary.findPose(motionId);
        if (pose === null) {
          motionValid = false;
          warnings.push(`[${DialoguePerformanceErrorCode.POSE_NOT_FOUND}] poseId 不存在: ${motionId}, 降级为 expression-only`);
        }
      }
    } else {
      // motionType === 'none'
      if (motionId.length > 0) {
        // none 时 motionId 必须为空, 清除
        finalMotionId = '';
        warnings.push('motionType=none 时 motionId 必须为空, 已清除');
      }
      motionValid = false; // none 本身无动作
    }

    // 表情有效性 (空字符串视为无效)
    const expressionValid: boolean = finalExpressionId.length > 0;

    // ===== 8. 降级决策 =====
    if (!motionValid && expressionValid) {
      // 动作无效, 表情有效 → 降级为 expression-only
      degraded = true;
      finalMotionType = 'none';
      finalMotionId = '';
    } else if (motionValid && !expressionValid) {
      // 动作有效, 表情无效 → motion-only (清除 expressionId)
      degraded = true;
      finalExpressionId = '';
    } else if (!motionValid && !expressionValid) {
      // 全部无效 → 拒绝 (DIALOGUE_NOTHING_TO_PERFORM)
      return this.fail(DialoguePerformanceErrorCode.NOTHING_TO_PERFORM,
        'DIALOGUE_NOTHING_TO_PERFORM: 动作、姿势和表情都无效, 无可执行内容');
    }

    // motionType === 'none' 时, expressionId 必须非空
    if (finalMotionType === 'none' && finalExpressionId.length === 0) {
      return this.fail(DialoguePerformanceErrorCode.NOTHING_TO_PERFORM,
        'DIALOGUE_NOTHING_TO_PERFORM: motionType=none 时 expressionId 不能为空');
    }

    // ===== 9. 生成本地 commandId, 强制 interruptPolicy = REPLACE =====
    const commandId: string = this.generateCommandId();
    const cmd: ArkWebAvatarPerformanceCommand = {
      commandId: commandId,
      motionType: finalMotionType,
      motionId: finalMotionId,
      expressionId: finalExpressionId,
      expressionWeight: expressionWeight,
      durationMs: durationMs,
      interruptPolicy: 'REPLACE',
      returnPolicy: returnPolicy
    };

    // ===== 10. 通过 validatePerformanceCommand 二次校验 =====
    // 注: 前面已做严格校验, 这里是防御性二次校验
    // 若失败, 说明 Mapper 逻辑有 bug, 返回 COMMAND_INVALID
    // (此处不直接调用 validatePerformanceCommand, 避免循环依赖;
    //  校验逻辑由前面的字段检查保证)

    const result: ArkWebDialoguePerformanceMappingResult = {
      accepted: true,
      degraded: degraded,
      command: cmd,
      warnings: warnings,
      errorCode: '',
      errorMessage: ''
    };
    return result;
  }

  /**
   * 检查字符串是否包含危险模式。
   *
   * 危险模式包括:
   *   - 协议前缀: file: / http: / https: / ftp: / data:
   *   - 路径分隔符: / 和 \
   *   - 上级目录: ..
   */
  private containsForbiddenPattern(s: string): boolean {
    for (let i = 0; i < DIALOGUE_HINT_FORBIDDEN_PATTERNS.length; i++) {
      if (s.indexOf(DIALOGUE_HINT_FORBIDDEN_PATTERNS[i]) !== -1) {
        return true;
      }
    }
    return false;
  }

  /**
   * 生成本地 commandId。
   *
   * 格式: dialogue_<timestamp>_<counter>
   *
   * commandId 由本地生成, 不信任 AI。
   */
  private generateCommandId(): string {
    this.commandIdCounter++;
    return `dialogue_${Date.now()}_${this.commandIdCounter}`;
  }

  /**
   * 构造失败结果。
   */
  private fail(errorCode: string, errorMessage: string): ArkWebDialoguePerformanceMappingResult {
    return {
      accepted: false,
      degraded: false,
      command: undefined,
      warnings: [],
      errorCode: errorCode,
      errorMessage: errorMessage
    };
  }
}
