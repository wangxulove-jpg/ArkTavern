/**
 * Character3DAnimationController 3D 动画播放控制器
 *
 * T-3D.6A: 独立于 Character3DPocViewModel 的动作播放控制器。
 *
 * 职责:
 * - 管理动画播放状态机(Uninitialized/Idle/Loading/Playing/Paused/Transitioning/Failed/Disposed)
 * - 通过 operationId/playToken 防止竞态(旧动作迟到回调不覆盖新动作)
 * - 查询动作槽位绑定(模型专属 → 全局默认 → 模型内置 → 静态展示)
 * - 播放/暂停/停止/切换动作
 * - 非循环动作完成后自动回到 Idle
 * - 页面隐藏暂停,页面销毁释放
 * - 不读取聊天正文 / Prompt / API Key
 *
 * ArkGraphics 3D Animation API 限制(在报告中写明):
 * - Animation 无 name 属性,只能按索引访问
 * - 不支持运行时调整动画速度(speed 仅作为元数据保存)
 * - 不支持运行时重定向(外部动画应用到不同骨骼的模型)
 * - 不支持动画混合(transitionDurationMs 仅作为预留字段,第一版直接切换)
 *
 * 第一版实际支持:
 * - 模型内置动画:通过 scene.animations[index] 播放
 * - 外部动作文件:仅支持元数据保存,实际播放需要重新加载包含该动画的模型
 */

import { Scene, Animation } from '@kit.ArkGraphics3D';
import { Logger } from '../utils/Logger';
import { Character3DActionSlot, getSlotInfo, getFallbackSlot } from '../models/character3d/Character3DActionSlot';
import { Character3DActionBinding } from '../models/character3d/Character3DActionAsset';
import { ActionCompatibility } from '../models/character3d/HumanoidBone';

const LOG_TAG: string = 'Char3DAnimCtrl';

/**
 * 动画播放状态。
 */
export enum AnimationPlayState {
  /** 未初始化 */
  Uninitialized = 'Uninitialized',
  /** 空闲(等待播放) */
  Idle = 'Idle',
  /** 加载中 */
  Loading = 'Loading',
  /** 播放中 */
  Playing = 'Playing',
  /** 暂停 */
  Paused = 'Paused',
  /** 切换中(预留) */
  Transitioning = 'Transitioning',
  /** 失败 */
  Failed = 'Failed',
  /** 已释放 */
  Disposed = 'Disposed'
}

/**
 * 动画播放请求(由 ViewModel 构造)。
 */
export interface AnimationPlayRequest {
  /** 当前动作槽位 */
  slot: Character3DActionSlot;
  /** 动画索引(模型内置动画时为 scene.animations 的索引) */
  animationIndex: number;
  /** 是否循环 */
  loop: boolean;
  /** 来源标记(模型内置/外部动作) */
  source: AnimationSource;
}

/**
 * 动画来源。
 */
export enum AnimationSource {
  /** 模型内置动画 */
  Embedded = 'Embedded',
  /** 外部动作文件(第一版不支持实际播放) */
  External = 'External',
  /** 静态展示(无动画) */
  Static = 'Static'
}

/**
 * 动画播放控制器。
 *
 * 使用方式:
 * 1. 模型加载完成后调用 attachScene(scene) 注入 Scene
 * 2. 调用 playSlot(slot, binding) 播放指定槽位
 * 3. 调用 pause() / resume() / stop() 控制播放
 * 4. 页面隐藏调用 onPause(),页面恢复调用 onResume()
 * 5. 页面销毁调用 dispose()
 */
export class Character3DAnimationController {
  /** 当前状态 */
  private stateValue: AnimationPlayState = AnimationPlayState.Uninitialized;
  /** 操作 ID,每次操作递增,防止竞态 */
  private operationId: number = 0;
  /** 当前 Scene 引用 */
  private sceneValue: Scene | null = null;
  /** 当前播放的 Animation */
  private currentAnimation: Animation | null = null;
  /** 当前播放的动画索引 */
  private currentIndex: number = -1;
  /** 当前播放的槽位 */
  private currentSlot: Character3DActionSlot = Character3DActionSlot.Idle;
  /** 是否循环 */
  private currentLoop: boolean = false;
  /** 当前来源 */
  private currentSource: AnimationSource = AnimationSource.Static;
  /** 是否已暂停(页面不可见) */
  private pageHidden: boolean = false;
  /** 是否已释放 */
  private disposed: boolean = false;
  /** 状态变更回调 */
  onStateChanged: ((state: AnimationPlayState) => void) | null = null;
  /** 动画完成回调(非循环动作完成时触发) */
  onAnimationFinished: ((slot: Character3DActionSlot) => void) | null = null;
  /** 错误回调 */
  onError: ((message: string) => void) | null = null;

  /**
   * 注入 Scene 引用。
   * 调用后状态变为 Idle。
   */
  attachScene(scene: Scene): void {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'attachScene ignored: disposed');
      return;
    }
    this.sceneValue = scene;
    this.setState(AnimationPlayState.Idle);
    Logger.info(LOG_TAG, 'attachScene ok');
  }

  /**
   * 解除 Scene 引用。
   * 停止当前动画,状态变为 Uninitialized。
   */
  detachScene(): void {
    if (this.disposed) {
      return;
    }
    this.stopInternal();
    this.sceneValue = null;
    this.currentAnimation = null;
    this.currentIndex = -1;
    this.setState(AnimationPlayState.Uninitialized);
  }

  /**
   * 播放指定槽位的动画。
   *
   * 流程:
   * 1. 检查 Scene 和 Animation[]
   * 2. 根据 binding 选择动画
   * 3. 停止当前动画
   * 4. 启动新动画
   * 5. 注册 onFinished 回调(非循环动画)
   *
   * @param slot 动作槽位
   * @param binding 绑定信息(可为 null,表示使用 Idle 回退)
   * @param embeddedAnimationsCount 模型内置动画数量
   */
  playSlot(
    slot: Character3DActionSlot,
    binding: Character3DActionBinding | null,
    embeddedAnimationsCount: number
  ): void {
    if (this.disposed) {
      return;
    }
    if (this.sceneValue === null) {
      Logger.warn(LOG_TAG, 'playSlot ignored: scene null');
      return;
    }
    const opId: number = ++this.operationId;
    this.setState(AnimationPlayState.Loading);

    // 解析播放请求
    const request: AnimationPlayRequest | null = this.resolvePlayRequest(
      slot, binding, embeddedAnimationsCount
    );
    if (request === null) {
      Logger.info(LOG_TAG, 'playSlot: no animation available, static display');
      this.currentSlot = slot;
      this.currentSource = AnimationSource.Static;
      this.setState(AnimationPlayState.Idle);
      return;
    }

    // 第一版 External 也不支持实际播放(SDK 限制)
    if (request.source === AnimationSource.External) {
      Logger.info(LOG_TAG, 'playSlot: external action not supported by SDK, static display');
      this.currentSlot = slot;
      this.currentSource = AnimationSource.Static;
      this.setState(AnimationPlayState.Idle);
      return;
    }

    // 停止当前动画
    this.stopInternal();

    if (opId !== this.operationId) {
      Logger.info(LOG_TAG, 'playSlot: late callback discarded');
      return;
    }

    // 启动新动画
    const scene: Scene = this.sceneValue!;
    const animations: Animation[] = scene.animations;
    if (request.animationIndex < 0 || request.animationIndex >= animations.length) {
      Logger.warn(LOG_TAG, 'playSlot: invalid animation index ' + request.animationIndex);
      this.setState(AnimationPlayState.Failed);
      if (this.onError !== null) {
        this.onError('动画索引无效: ' + request.animationIndex);
      }
      return;
    }

    try {
      const animation: Animation = animations[request.animationIndex];
      this.currentAnimation = animation;
      this.currentIndex = request.animationIndex;
      this.currentSlot = slot;
      this.currentLoop = request.loop;
      this.currentSource = request.source;

      // 注册完成回调(非循环动画)
      if (!request.loop) {
        animation.onFinished(() => {
          if (opId !== this.operationId) {
            return;
          }
          if (this.disposed) {
            return;
          }
          Logger.info(LOG_TAG, 'animation finished, slot=' + slot);
          if (this.onAnimationFinished !== null) {
            this.onAnimationFinished(slot);
          }
          // 自动回到 Idle
          this.fallbackToIdle(embeddedAnimationsCount);
        });
      }

      animation.start();
      this.setState(AnimationPlayState.Playing);
      Logger.info(LOG_TAG, 'playSlot ok: slot=' + slot + ', index=' + request.animationIndex
        + ', loop=' + request.loop);
    } catch (e) {
      Logger.error(LOG_TAG, 'playSlot start failed: ' + (e as Error)?.message);
      this.setState(AnimationPlayState.Failed);
      if (this.onError !== null) {
        this.onError('动画播放失败: ' + (e as Error)?.message);
      }
    }
  }

  /**
   * 暂停当前动画。
   */
  pause(): void {
    if (this.disposed) {
      return;
    }
    if (this.stateValue !== AnimationPlayState.Playing) {
      return;
    }
    if (this.currentAnimation === null) {
      return;
    }
    try {
      this.currentAnimation.pause();
      this.setState(AnimationPlayState.Paused);
      Logger.info(LOG_TAG, 'pause ok');
    } catch (e) {
      Logger.warn(LOG_TAG, 'pause failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 恢复播放。
   */
  resume(): void {
    if (this.disposed) {
      return;
    }
    if (this.stateValue !== AnimationPlayState.Paused) {
      return;
    }
    if (this.currentAnimation === null) {
      return;
    }
    try {
      this.currentAnimation.start();
      this.setState(AnimationPlayState.Playing);
      Logger.info(LOG_TAG, 'resume ok');
    } catch (e) {
      Logger.warn(LOG_TAG, 'resume failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 停止当前动画,回到 Idle 状态。
   */
  stop(): void {
    if (this.disposed) {
      return;
    }
    this.stopInternal();
    this.setState(AnimationPlayState.Idle);
  }

  /**
   * 重新播放当前动画(从开头)。
   */
  replay(embeddedAnimationsCount: number): void {
    if (this.disposed) {
      return;
    }
    if (this.sceneValue === null) {
      return;
    }
    const slot: Character3DActionSlot = this.currentSlot;
    const binding: Character3DActionBinding | null = null; // 由调用方提供
    this.playSlot(slot, binding, embeddedAnimationsCount);
  }

  /**
   * 页面隐藏时调用,暂停动画。
   */
  onPause(): void {
    if (this.disposed) {
      return;
    }
    this.pageHidden = true;
    if (this.stateValue === AnimationPlayState.Playing) {
      this.pause();
    }
  }

  /**
   * 页面恢复时调用,恢复动画(如果之前在播放)。
   */
  onResume(): void {
    if (this.disposed) {
      return;
    }
    this.pageHidden = false;
    if (this.stateValue === AnimationPlayState.Paused && !this.pageHidden) {
      this.resume();
    }
  }

  /**
   * 销毁控制器,释放资源。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.stopInternal();
    this.sceneValue = null;
    this.currentAnimation = null;
    this.currentIndex = -1;
    this.setState(AnimationPlayState.Disposed);
    this.onStateChanged = null;
    this.onAnimationFinished = null;
    this.onError = null;
    Logger.info(LOG_TAG, 'dispose ok');
  }

  /**
   * 获取当前状态。
   */
  getState(): AnimationPlayState {
    return this.stateValue;
  }

  /**
   * 获取当前槽位。
   */
  getCurrentSlot(): Character3DActionSlot {
    return this.currentSlot;
  }

  /**
   * 获取当前动画索引。
   */
  getCurrentIndex(): number {
    return this.currentIndex;
  }

  /**
   * 是否正在播放。
   */
  isPlaying(): boolean {
    return this.stateValue === AnimationPlayState.Playing;
  }

  /**
   * 是否已释放。
   */
  isDisposed(): boolean {
    return this.disposed;
  }

  /**
   * 解析播放请求。
   *
   * 选择顺序(对应任务规格第十一章):
   * 1. 模型专属绑定(actionAssetId 非空)
   * 2. 全局默认绑定(actionAssetId 非空)
   * 3. 模型内置同名 Clip(clipIndex >= 0)
   * 4. 回退动作(getFallbackSlot)
   * 5. 静态展示
   *
   * 第一版限制:
   * - 外部动作(actionAssetId 非空)不支持实际播放(SDK 限制),返回 null
   * - 模型内置动画(clipIndex >= 0)支持播放
   */
  private resolvePlayRequest(
    slot: Character3DActionSlot,
    binding: Character3DActionBinding | null,
    embeddedAnimationsCount: number
  ): AnimationPlayRequest | null {
    // 1. 检查绑定
    if (binding !== null) {
      // 模型内置动画:clipIndex 有效
      if (binding.clipIndex >= 0 && binding.clipIndex < embeddedAnimationsCount) {
        return {
          slot: slot,
          animationIndex: binding.clipIndex,
          loop: binding.loop,
          source: AnimationSource.Embedded
        } as AnimationPlayRequest;
      }
      // 外部动作文件:第一版 SDK 不支持实际播放
      if (binding.actionAssetId.length > 0) {
        return {
          slot: slot,
          animationIndex: -1,
          loop: binding.loop,
          source: AnimationSource.External
        } as AnimationPlayRequest;
      }
    }

    // 2. 回退到 Idle
    if (slot !== Character3DActionSlot.Idle) {
      const fallbackSlot: Character3DActionSlot = getFallbackSlot(slot);
      if (fallbackSlot !== slot) {
        // 尝试 Idle 的回退(模型第一个动画)
        return this.resolveIdleFallback(embeddedAnimationsCount);
      }
    }

    // 3. Idle 的回退:模型第一个动画
    return this.resolveIdleFallback(embeddedAnimationsCount);
  }

  /**
   * Idle 的回退策略(对应任务规格第十章):
   * 1. 模型自带 Idle(优先选择名为 "idle" 的 Clip,但 SDK 不支持按名查询,只能用第一个)
   * 2. 模型第一个循环 Clip
   * 3. 模型第一个 Clip
   * 4. 静态展示
   */
  private resolveIdleFallback(embeddedAnimationsCount: number): AnimationPlayRequest | null {
    if (embeddedAnimationsCount <= 0) {
      return null;
    }
    // SDK 限制:Animation 无 name 属性,只能按索引选择
    // 使用第一个动画作为 Idle 回退
    return {
      slot: Character3DActionSlot.Idle,
      animationIndex: 0,
      loop: true,
      source: AnimationSource.Embedded
    } as AnimationPlayRequest;
  }

  /**
   * 自动回到 Idle。
   */
  private fallbackToIdle(embeddedAnimationsCount: number): void {
    if (this.disposed) {
      return;
    }
    const request: AnimationPlayRequest | null = this.resolveIdleFallback(embeddedAnimationsCount);
    if (request === null) {
      this.setState(AnimationPlayState.Idle);
      return;
    }
    // 直接播放 Idle(不调用 playSlot 避免递归)
    if (this.sceneValue === null) {
      return;
    }
    const scene: Scene = this.sceneValue!;
    const animations: Animation[] = scene.animations;
    if (request.animationIndex < 0 || request.animationIndex >= animations.length) {
      this.setState(AnimationPlayState.Idle);
      return;
    }
    try {
      const animation: Animation = animations[request.animationIndex];
      this.currentAnimation = animation;
      this.currentIndex = request.animationIndex;
      this.currentSlot = Character3DActionSlot.Idle;
      this.currentLoop = true;
      this.currentSource = AnimationSource.Embedded;
      animation.start();
      this.setState(AnimationPlayState.Playing);
      Logger.info(LOG_TAG, 'fallbackToIdle ok');
    } catch (e) {
      Logger.warn(LOG_TAG, 'fallbackToIdle failed: ' + (e as Error)?.message);
      this.setState(AnimationPlayState.Idle);
    }
  }

  /**
   * 内部停止当前动画(不改变状态)。
   */
  private stopInternal(): void {
    if (this.currentAnimation !== null) {
      try {
        this.currentAnimation.stop();
      } catch (_e) {
        // ignore
      }
      this.currentAnimation = null;
      this.currentIndex = -1;
    }
  }

  /**
   * 设置状态并触发回调。
   */
  private setState(state: AnimationPlayState): void {
    if (this.stateValue === state) {
      return;
    }
    this.stateValue = state;
    if (this.onStateChanged !== null) {
      this.onStateChanged(state);
    }
  }
}
