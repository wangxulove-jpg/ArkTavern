import { Logger } from '../utils/Logger';
/**
 * ArkWebVrmViewerPagePerformanceRuntime — VrmViewerPage 演出运行时实现 (Phase 3F-1)
 *
 * 职责:
 *   - 实现 ArkWebAvatarPerformanceRuntime 接口
 *   - 通过依赖回调复用 VrmViewerPage 现有方法, 不复制底层实现
 *   - 不直接创建 GLTFLoader / AnimationMixer / VRMAnimationClip /
 *     VRM Humanoid Node / VRM ExpressionManager / ArkWeb Provider
 *
 * 设计原因:
 *   ArkTS 不允许对象字面量包含方法 (arkts-no-untyped-obj-literals),
 *   必须用 class 实现 interface。本 class 接收依赖回调,
 *   VrmViewerPage 通过箭头函数绑定现有方法到依赖回调。
 *
 * 依赖回调均为函数属性 (非方法), 可通过对象字面量创建。
 */

import { ArkWebAvatarPerformanceRuntime } from './ArkWebAvatarPerformanceTypes';
import { ArkWebVrmViewerController } from './ArkWebVrmViewerController';
import { ArkWebAvatarAssetLibrary } from './ArkWebAvatarAssetLibrary';
import { ArkWebPersistentPoseStore } from './ArkWebPersistentPoseStore';
import { ArkWebSetTemporaryExpressionByAliasParams } from './ArkWebVrmViewerTypes';

/**
 * 演出运行时依赖回调。
 *
 * 所有属性均为函数类型 (非方法), 以便 VrmViewerPage 用对象字面量 + 箭头函数创建。
 */
export interface ArkWebVrmViewerPagePerformanceRuntimeDeps {
  /** 获取 ArkWebVrmViewerController (可能为 null) */
  getArkWebController: () => ArkWebVrmViewerController | null;
  /** 获取 AssetLibrary (可能为 null) */
  getAssetLibrary: () => ArkWebAvatarAssetLibrary | null;
  /** 获取 PersistentPoseStore (可能为 null) */
  getPersistentPoseStore: () => ArkWebPersistentPoseStore | null;
  /** 获取当前表情别名映射 */
  getExpressionAliasMap: () => Record<string, string>;
  /** 获取当前动画状态字符串 */
  getDebugAnimationState: () => string;
  /** 按 actionId 加载动画 (复用 VrmViewerPage.loadAnimationByActionId) */
  loadAnimationByActionId: (actionId: string) => Promise<boolean>;
  /** 等待动画进入 READY 状态 (复用 VrmViewerPage.waitForAnimationReady) */
  waitForAnimationReady: (timeoutMs: number) => Promise<boolean>;
  /** 内部 resetPose 调用 (复用 VrmViewerPage.resetPoseInternal) */
  resetPoseInternal: () => Promise<boolean>;
  /** 内部 applyPoseById 调用 (复用 VrmViewerPage.applyPoseByIdInternal) */
  applyPoseByIdInternal: (poseId: string) => Promise<boolean>;
}

/**
 * VrmViewerPage 演出运行时实现。
 *
 * 实现 ArkWebAvatarPerformanceRuntime 接口,
 * 通过依赖回调复用 VrmViewerPage 现有方法,
 * 不复制动作 / 姿势 / 表情底层实现。
 */
export class ArkWebVrmViewerPagePerformanceRuntime implements ArkWebAvatarPerformanceRuntime {
  private deps: ArkWebVrmViewerPagePerformanceRuntimeDeps;

  constructor(deps: ArkWebVrmViewerPagePerformanceRuntimeDeps) {
    this.deps = deps;
  }

  async stopAnimation(): Promise<boolean> {
    const controller: ArkWebVrmViewerController | null = this.deps.getArkWebController();
    if (controller === null) {
      return false;
    }
    try {
      const resultJson: string = await controller.stopAnimation('');
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      Logger.warn('[PerformanceRuntime] stopAnimation failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  async playAnimationById(actionId: string): Promise<boolean> {
    // 复用 loadAnimationByActionId (内部完成 Provider 注册 + loadAnimationResource)
    const loaded: boolean = await this.deps.loadAnimationByActionId(actionId);
    if (!loaded) {
      Logger.warn(`[PerformanceRuntime] playAnimationById: loadAnimationByActionId returned false: ${actionId}`);
      return false;
    }
    // loadAnimationResource 是异步加载: Web 端状态会从 LOADING → READY。
    // 但 ArkTS 侧 debugAnimationState 可能仍是上一次的 READY (onAnimationStateChanged
    // 为空实现, 不主动刷新), 导致下面的旧检查被跳过, 在 Web 端仍为 LOADING 时调用
    // playAnimation 而失败 (ANIMATION_NOT_READY)。
    // 修复: 始终进入 waitForAnimationReady, 它内部会调用 getAnimationDebugState()
    // 刷新到最新状态, 然后才检查 READY。
    Logger.debug(`[PerformanceRuntime] playAnimationById: waiting READY after load: ${actionId}`);
    await this.deps.waitForAnimationReady(30000);
    const stateAfterWait: string = this.deps.getDebugAnimationState();
    if (stateAfterWait !== 'READY') {
      Logger.warn(`[PerformanceRuntime] playAnimationById: animation not READY after wait (state=${stateAfterWait}): ${actionId}`);
      return false;
    }
    const controller: ArkWebVrmViewerController | null = this.deps.getArkWebController();
    if (controller === null) {
      Logger.warn(`[PerformanceRuntime] playAnimationById: arkWebController is null: ${actionId}`);
      return false;
    }
    try {
      const resultJson: string = await controller.playAnimation();
      Logger.debug(`[PerformanceRuntime] playAnimationById: playAnimation response: ${resultJson}`);
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const success: boolean = obj['success'] === true;
      if (!success) {
        const errObj = obj['error'] as Record<string, Object>;
        const errCode: string = errObj ? (errObj['code'] as string) || 'UNKNOWN' : 'UNKNOWN';
        const errMsg: string = errObj ? (errObj['message'] as string) || '' : '';
        Logger.warn(`[PerformanceRuntime] playAnimationById: playAnimation returned success=false: code=${errCode}, msg=${errMsg}, actionId=${actionId}`);
      }
      return success;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.warn(`[PerformanceRuntime] playAnimationById: playAnimation threw: ${msg}, actionId=${actionId}`);
      return false;
    }
  }

  async applyPoseById(poseId: string): Promise<boolean> {
    return await this.deps.applyPoseByIdInternal(poseId);
  }

  async resetPose(): Promise<boolean> {
    const controller: ArkWebVrmViewerController | null = this.deps.getArkWebController();
    if (controller === null) {
      return false;
    }
    try {
      const resultJson: string = await controller.resetPose();
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      Logger.warn('[PerformanceRuntime] resetPose failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  async restoreDefaultPose(): Promise<boolean> {
    // 读取 defaultPoseId, 无默认姿势时降级为 resetPose
    const assetLibrary: ArkWebAvatarAssetLibrary | null = this.deps.getAssetLibrary();
    if (assetLibrary === null) {
      return await this.deps.resetPoseInternal();
    }
    try {
      const defaultPoseId: string = await assetLibrary.getDefaultPoseId();
      if (defaultPoseId.length === 0) {
        return await this.deps.resetPoseInternal();
      }
      return await this.deps.applyPoseByIdInternal(defaultPoseId);
    } catch (e) {
      Logger.warn('[PerformanceRuntime] restoreDefaultPose failed, fallback to resetPose: ' +
        (e instanceof Error ? e.message : String(e)));
      return await this.deps.resetPoseInternal();
    }
  }

  async setTemporaryExpressionByAlias(
    expressionId: string,
    weight: number,
    durationMs: number
  ): Promise<boolean> {
    const controller: ArkWebVrmViewerController | null = this.deps.getArkWebController();
    if (controller === null) {
      return false;
    }
    try {
      // 复用 setTemporaryExpressionByAlias Bridge
      const params: ArkWebSetTemporaryExpressionByAliasParams = {
        expressionId: expressionId,
        aliases: this.deps.getExpressionAliasMap(),
        weight: weight,
        durationMs: durationMs,
        restorePolicy: 'PREVIOUS'
      };
      const paramsJson: string = JSON.stringify(params);
      const resultJson: string =
        await controller.setTemporaryExpressionByAlias(paramsJson);
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      Logger.warn('[PerformanceRuntime] setTemporaryExpressionByAlias failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  async cancelTemporaryExpression(): Promise<boolean> {
    const controller: ArkWebVrmViewerController | null = this.deps.getArkWebController();
    if (controller === null) {
      return false;
    }
    try {
      const resultJson: string = await controller.cancelTemporaryExpression();
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      Logger.warn('[PerformanceRuntime] cancelTemporaryExpression failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }
}
