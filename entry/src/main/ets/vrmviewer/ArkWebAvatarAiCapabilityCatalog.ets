/**
 * ArkWebAvatarAiCapabilityCatalog — AI 能力目录 (Phase 4A-1)
 *
 * 职责:
 *   - 读取 ArkWebAvatarAssetLibrary 当前模型的业务能力 (动画/姿势/表情)
 *   - 生成 ArkWebAvatarAiCapabilitySnapshot 供 AI Tab UI 展示
 *   - 校验业务 ID 是否存在 (validateAnimationId / validatePoseId / validateExpressionId)
 *
 * 安全约束 (AGENTS.md Phase 4A-1 §能力目录职责):
 *   - 只暴露业务 ID (actionId / poseId / expressionId / displayName / 默认标记 / 映射是否可用)
 *   - 禁止暴露 absolutePath / relativePath / filesDir / resourceId / resourceUrl / Provider URL
 *   - 禁止暴露文件描述符 / Three.js 对象 / VRM 对象 / 骨骼数据
 *   - 业务表情固定为 6 个 ID: neutral / happy / angry / sad / relaxed / surprised
 *
 * 容错策略:
 *   - 旧清单缺少 animations / poses / expressionAliases 时,返回空数组或 available=false
 *   - 不抛异常,失败返回空快照 + 错误码
 *   - 不删除任何模型、动画、姿势或表情映射
 *
 * 不实现:
 *   - 真实 AI 网络请求 / WebSocket / Timer
 *   - 聊天历史 / 系统提示词 / API Key / Provider 配置
 *   - Three.js / VRM 对象访问
 *
 * Reference:
 *   - AGENTS.md Phase 4A-1 §能力目录职责 / §刷新时机
 *   - ArkWebAvatarAssetLibrary.ets (readAnimations / readPoses / findActiveModel /
 *     getDefaultIdleActionId / getDefaultPoseId / getExpressionAliases)
 *   - ArkWebAvatarAssetTypes.ets (ArkWebExpressionAliasBusinessId)
 *   - ArkWebAvatarAiTypes.ets (ArkWebAvatarAiCapabilitySnapshot 等)
 */

import { ArkWebAvatarAssetLibrary } from './ArkWebAvatarAssetLibrary';
import {
  ArkWebExpressionAliasBusinessId,
  ArkWebAvatarAnimationAsset,
  ArkWebAvatarPoseAsset,
  ArkWebAvatarAssetLibraryData
} from './ArkWebAvatarAssetTypes';
import {
  ArkWebAvatarAiAnimationCapability,
  ArkWebAvatarAiPoseCapability,
  ArkWebAvatarAiExpressionCapability,
  ArkWebAvatarAiCapabilitySnapshot,
  ArkWebAvatarAiCapabilityState,
  ArkWebAvatarAiCapabilityErrorCode,
  AI_CAPABILITY_EXPRESSION_BUSINESS_IDS
} from './ArkWebAvatarAiTypes';

/**
 * AI 能力目录。
 *
 * 使用方式:
 *   1. 页面 aboutToAppear 创建实例,传入 ArkWebAvatarAssetLibrary (不转移所有权)
 *   2. 模型 READY / 模型替换 / 动画导入删除 / 姿势导入 / 表情别名变化 时调用 buildSnapshot
 *   3. 页面 aboutToDisappear 调用 dispose (不销毁 AssetLibrary)
 *
 * 不持有 Timer / Frame Loop / 网络连接 / AI 客户端 / Three.js 对象。
 */
export class ArkWebAvatarAiCapabilityCatalog {
  /** AssetLibrary 引用 (不转移所有权,不销毁)。 */
  private assetLibrary: ArkWebAvatarAssetLibrary | null;
  /** 是否已销毁。 */
  private disposed: boolean = false;
  /** 当前状态。 */
  private currentState: ArkWebAvatarAiCapabilityState = ArkWebAvatarAiCapabilityState.IDLE;
  /** 最后错误码。 */
  private lastErrorCode: string = '';
  /** 最后错误消息。 */
  private lastErrorMessage: string = '';

  constructor(assetLibrary: ArkWebAvatarAssetLibrary | null) {
    this.assetLibrary = assetLibrary;
  }

  /** 获取当前状态。 */
  getState(): ArkWebAvatarAiCapabilityState {
    return this.currentState;
  }

  /** 获取最后错误码。 */
  getLastErrorCode(): string {
    return this.lastErrorCode;
  }

  /** 获取最后错误消息。 */
  getLastErrorMessage(): string {
    return this.lastErrorMessage;
  }

  /** 是否已销毁。 */
  isDisposed(): boolean {
    return this.disposed;
  }

  /**
   * 生成当前模型的能力快照。
   *
   * 流程:
   *   1. 校验 AssetLibrary 未销毁
   *   2. 读取 library 数据 (readLibrary)
   *   3. 查找 active model 记录 (findActiveModel)
   *   4. 读取 animations → 转换为 ArkWebAvatarAiAnimationCapability[]
   *   5. 读取 poses → 转换为 ArkWebAvatarAiPoseCapability[]
   *   6. 读取 expressionAliases → 遍历 6 个业务 ID 生成表情能力
   *   7. 读取 defaultIdleActionId / defaultPoseId
   *   8. 组装 ArkWebAvatarAiCapabilitySnapshot
   *
   * 容错:
   *   - AssetLibrary 为 null → 返回空快照 + AI_CAPABILITY_LIBRARY_INVALID
   *   - 无 active model → 返回空快照 (modelId='') + AI_CAPABILITY_NO_ACTIVE_MODEL
   *   - 读取失败 → 返回空快照 + AI_CAPABILITY_LIBRARY_READ_FAILED
   *   - 旧清单缺字段 → 对应数组为空或 available=false,不失败
   *
   * @param activeModelId 调用方传入的当前激活模型 ID (用于快照 modelId 字段)
   * @returns 能力快照 (失败时返回空快照,通过 getLastErrorCode 查看错误)
   */
  async buildSnapshot(
    activeModelId: string
  ): Promise<ArkWebAvatarAiCapabilitySnapshot> {
    if (this.disposed) {
      this.currentState = ArkWebAvatarAiCapabilityState.DISPOSED;
      this.lastErrorCode = ArkWebAvatarAiCapabilityErrorCode.AI_CAPABILITY_DISPOSED;
      this.lastErrorMessage = '能力目录已销毁';
      return this.emptySnapshot();
    }

    this.currentState = ArkWebAvatarAiCapabilityState.LOADING;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';

    if (this.assetLibrary === null) {
      this.currentState = ArkWebAvatarAiCapabilityState.FAILED;
      this.lastErrorCode = ArkWebAvatarAiCapabilityErrorCode.AI_CAPABILITY_LIBRARY_INVALID;
      this.lastErrorMessage = 'AssetLibrary 未注入';
      return this.emptySnapshot();
    }

    // 读取 library 数据 (用于 active model 和 displayName)
    let libraryData: ArkWebAvatarAssetLibraryData | null = null;
    try {
      libraryData = await this.assetLibrary.readLibrary();
    } catch (e) {
      this.currentState = ArkWebAvatarAiCapabilityState.FAILED;
      this.lastErrorCode = ArkWebAvatarAiCapabilityErrorCode.AI_CAPABILITY_LIBRARY_READ_FAILED;
      this.lastErrorMessage = '读取 library 异常: ' + (e instanceof Error ? e.message : String(e));
      return this.emptySnapshot();
    }
    if (libraryData === null) {
      this.currentState = ArkWebAvatarAiCapabilityState.FAILED;
      this.lastErrorCode = ArkWebAvatarAiCapabilityErrorCode.AI_CAPABILITY_LIBRARY_READ_FAILED;
      this.lastErrorMessage = '读取 library 返回 null';
      return this.emptySnapshot();
    }

    // 查找 active model (用于 displayName 和 expressionAliases)
    // 注意:activeModelId 参数由调用方传入,优先使用;若为空则从 library 读取
    let effectiveModelId: string = activeModelId;
    if (effectiveModelId.length === 0) {
      effectiveModelId = libraryData.activeModelId;
    }
    if (effectiveModelId.length === 0) {
      // 无激活模型 → 返回空快照 (不算失败,状态为 EMPTY)
      this.currentState = ArkWebAvatarAiCapabilityState.EMPTY;
      this.lastErrorCode = ArkWebAvatarAiCapabilityErrorCode.AI_CAPABILITY_NO_ACTIVE_MODEL;
      this.lastErrorMessage = '无激活模型';
      return this.emptySnapshot();
    }

    // 读取 animations / poses / defaults / expressions
    let animations: ArkWebAvatarAiAnimationCapability[] = [];
    let poses: ArkWebAvatarAiPoseCapability[] = [];
    let expressions: ArkWebAvatarAiExpressionCapability[] = [];
    let defaultIdleActionId: string = '';
    let defaultPoseId: string = '';
    let modelDisplayName: string = '';

    try {
      const lib: ArkWebAvatarAssetLibrary = this.assetLibrary;

      // 查找模型记录 (用于 displayName)
      for (let i = 0; i < libraryData.models.length; i++) {
        if (libraryData.models[i].modelId === effectiveModelId) {
          modelDisplayName = libraryData.models[i].displayName;
          break;
        }
      }

      // 读取 animations
      const animAssets: ArkWebAvatarAnimationAsset[] = await lib.readAnimations();
      defaultIdleActionId = await lib.getDefaultIdleActionId();
      animations = this.buildAnimationCapabilities(animAssets, defaultIdleActionId);

      // 读取 poses
      const poseAssets: ArkWebAvatarPoseAsset[] = await lib.readPoses();
      defaultPoseId = await lib.getDefaultPoseId();
      poses = this.buildPoseCapabilities(poseAssets, defaultPoseId);

      // 读取表情别名映射
      const aliases = await lib.getExpressionAliases(effectiveModelId);
      expressions = this.buildExpressionCapabilities(aliases);
    } catch (e) {
      this.currentState = ArkWebAvatarAiCapabilityState.FAILED;
      this.lastErrorCode = ArkWebAvatarAiCapabilityErrorCode.AI_CAPABILITY_LIBRARY_READ_FAILED;
      this.lastErrorMessage = '读取能力数据异常: ' + (e instanceof Error ? e.message : String(e));
      return this.emptySnapshot();
    }

    // 判断最终状态:有任一能力 → READY,否则 EMPTY
    const hasAnyCapability: boolean =
      animations.length > 0 || poses.length > 0 ||
      expressions.filter((e: ArkWebAvatarAiExpressionCapability): boolean => e.available).length > 0;
    this.currentState = hasAnyCapability
      ? ArkWebAvatarAiCapabilityState.READY
      : ArkWebAvatarAiCapabilityState.EMPTY;

    const snapshot: ArkWebAvatarAiCapabilitySnapshot = {
      modelId: effectiveModelId,
      modelDisplayName: modelDisplayName,
      animations: animations,
      poses: poses,
      expressions: expressions,
      defaultIdleActionId: defaultIdleActionId,
      defaultPoseId: defaultPoseId,
      generatedAt: Date.now()
    };
    return snapshot;
  }

  /**
   * 校验 actionId 是否存在于 library.animations。
   */
  async validateAnimationId(actionId: string): Promise<boolean> {
    if (this.disposed || this.assetLibrary === null) {
      return false;
    }
    if (actionId.length === 0) {
      return false;
    }
    try {
      const anim = await this.assetLibrary.findAnimation(actionId);
      return anim !== null;
    } catch (_e) {
      return false;
    }
  }

  /**
   * 校验 poseId 是否存在于 library.poses。
   */
  async validatePoseId(poseId: string): Promise<boolean> {
    if (this.disposed || this.assetLibrary === null) {
      return false;
    }
    if (poseId.length === 0) {
      return false;
    }
    try {
      const pose = await this.assetLibrary.findPose(poseId);
      return pose !== null;
    } catch (_e) {
      return false;
    }
  }

  /**
   * 校验 expressionId 是否为合法业务 ID 且当前模型有映射。
   *
   * 注意:本方法只校验 expressionId 是固定业务 ID 且 aliases 中有非空映射,
   * 不校验模型真实 Expression 是否存在 (运行时由 PerformanceController 验证)。
   */
  async validateExpressionId(
    modelId: string,
    expressionId: string
  ): Promise<boolean> {
    if (this.disposed || this.assetLibrary === null) {
      return false;
    }
    if (!ArkWebExpressionAliasBusinessId.isValid(expressionId)) {
      return false;
    }
    if (modelId.length === 0) {
      return false;
    }
    try {
      const aliases = await this.assetLibrary.getExpressionAliases(modelId);
      const mapped: string = aliases[expressionId];
      return typeof mapped === 'string' && mapped.length > 0;
    } catch (_e) {
      return false;
    }
  }

  /**
   * 销毁能力目录。
   *
   * 仅清理内存状态:
   *   - disposed = true
   *   - 清空 assetLibrary 引用 (不销毁 AssetLibrary,由页面负责)
   *   - state = DISPOSED
   *
   * 不删除: 动作资产 / 姿势资产 / 表情别名 / 默认姿势 / library.json
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.currentState = ArkWebAvatarAiCapabilityState.DISPOSED;
    this.assetLibrary = null;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
  }

  // ===== 内部方法 =====

  /**
   * 把 ArkWebAvatarAnimationAsset[] 转换为 ArkWebAvatarAiAnimationCapability[]。
   *
   * 只保留业务字段 (actionId / displayName / isDefaultIdle),
   * 不保留 resourceId / relativePath / mimeType / byteLength / 时间戳。
   */
  private buildAnimationCapabilities(
    assets: ArkWebAvatarAnimationAsset[],
    defaultIdleActionId: string
  ): ArkWebAvatarAiAnimationCapability[] {
    const result: ArkWebAvatarAiAnimationCapability[] = [];
    for (let i = 0; i < assets.length; i++) {
      const a = assets[i];
      result.push({
        actionId: a.actionId,
        displayName: a.displayName,
        isDefaultIdle: a.actionId === defaultIdleActionId
      });
    }
    return result;
  }

  /**
   * 把 ArkWebAvatarPoseAsset[] 转换为 ArkWebAvatarAiPoseCapability[]。
   *
   * 只保留业务字段 (poseId / displayName / isDefaultPose),
   * 不保留 relativePath / byteLength / format / 时间戳。
   */
  private buildPoseCapabilities(
    assets: ArkWebAvatarPoseAsset[],
    defaultPoseId: string
  ): ArkWebAvatarAiPoseCapability[] {
    const result: ArkWebAvatarAiPoseCapability[] = [];
    for (let i = 0; i < assets.length; i++) {
      const p = assets[i];
      result.push({
        poseId: p.poseId,
        displayName: p.displayName,
        isDefaultPose: p.poseId === defaultPoseId
      });
    }
    return result;
  }

  /**
   * 遍历 6 个固定业务 ID,生成表情能力列表。
   *
   * available = aliases[expressionId] 存在且非空字符串。
   * 旧模型记录无 expressionAliases 字段时,全部 available=false。
   */
  private buildExpressionCapabilities(
    aliases: Record<string, string>
  ): ArkWebAvatarAiExpressionCapability[] {
    const result: ArkWebAvatarAiExpressionCapability[] = [];
    for (let i = 0; i < AI_CAPABILITY_EXPRESSION_BUSINESS_IDS.length; i++) {
      const id: string = AI_CAPABILITY_EXPRESSION_BUSINESS_IDS[i];
      const mapped: string | undefined = aliases[id];
      const available: boolean = typeof mapped === 'string' && mapped.length > 0;
      result.push({
        expressionId: id,
        mappedExpressionName: available ? (mapped as string) : '',
        available: available
      });
    }
    return result;
  }

  /**
   * 构造空快照 (失败 / 无模型时返回)。
   */
  private emptySnapshot(): ArkWebAvatarAiCapabilitySnapshot {
    return {
      modelId: '',
      modelDisplayName: '',
      animations: [],
      poses: [],
      expressions: [],
      defaultIdleActionId: '',
      defaultPoseId: '',
      generatedAt: Date.now()
    };
  }
}
