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
      console.warn('[PerformanceRuntime] stopAnimation failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  async playAnimationById(actionId: string): Promise<boolean> {
    // 复用 loadAnimationByActionId (内部完成 Provider 注册 + loadAnimationResource)
    const loaded: boolean = await this.deps.loadAnimationByActionId(actionId);
    if (!loaded) {
      return false;
    }
    // 等待动画进入 READY 状态 (复用轮询机制, 最多 30s)
    if (this.deps.getDebugAnimationState() !== 'READY') {
      await this.deps.waitForAnimationReady(30000);
    }
    if (this.deps.getDebugAnimationState() !== 'READY') {
      console.warn(`[PerformanceRuntime] playAnimationById: animation not READY after wait: ${actionId}`);
      return false;
    }
    const controller: ArkWebVrmViewerController | null = this.deps.getArkWebController();
    if (controller === null) {
      return false;
    }
    try {
      const resultJson: string = await controller.playAnimation();
      const obj: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      return obj['success'] === true;
    } catch (e) {
      console.warn('[PerformanceRuntime] playAnimation failed: ' +
        (e instanceof Error ? e.message : String(e)));
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
      console.warn('[PerformanceRuntime] resetPose failed: ' +
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
      console.warn('[PerformanceRuntime] restoreDefaultPose failed, fallback to resetPose: ' +
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
      console.warn('[PerformanceRuntime] setTemporaryExpressionByAlias failed: ' +
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
      console.warn('[PerformanceRuntime] cancelTemporaryExpression failed: ' +
        (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }
}
