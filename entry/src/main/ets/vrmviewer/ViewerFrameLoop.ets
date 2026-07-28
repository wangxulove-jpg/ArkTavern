/**
 * ViewerFrameLoop VRM Viewer 固定渲染循环
 *
 * 使用 setInterval 驱动每帧渲染,调用 Scene.renderFrame() 触发 GPU 渲染。
 * ArkGraphics3D 无 requestAnimationFrame 等价物,采用 setInterval(loop, 16) 约 60 FPS。
 *
 * Reference:
 * - figure-main: index.html L2860–2906 (animate: requestAnimationFrame +
 *   clock.getDelta() + controls.update + mixer.update + renderer.render)
 * - ownverse-vrm-viewer: analysis/RENDER_LOOP.md (setAnimationLoop + clock.getDelta),
 *   analysis/VIEWER_ARCHITECTURE.md §4 Per-Frame Loop
 *
 * 帧循环顺序(任务指令第九条):
 * 1. FRAME_START
 * 2. delta = (now - lastTick) / 1000
 * 3. cameraController.update(delta)
 * 4. modelController.update(delta)
 * 5. scene.renderFrame({ alwaysRender: false })
 * 6. FRAME_END
 */

import { Scene } from '@kit.ArkGraphics3D';
import { systemDateTime } from '@kit.BasicServicesKit';
import { FrameLoopState } from './ViewerTypes';

/** 帧回调接口(供 CameraController/ModelController 实现)。 */
export interface FrameUpdatable {
  /** 每帧更新,参数为距上一帧的秒数。 */
  update(deltaSeconds: number): void;
}

/**
 * 帧循环控制器。
 *
 * 生命周期:
 * - start(): 启动 setInterval,转 RUNNING。重复调用不重复启动。
 * - stop(): clearInterval,转 STOPPED。重复调用不崩溃。
 */
export class ViewerFrameLoop {
  private scene: Scene | null = null;
  private cameraUpdatable: FrameUpdatable | null = null;
  private modelUpdatable: FrameUpdatable | null = null;

  private timerId: number = -1;
  private state: FrameLoopState = FrameLoopState.STOPPED;
  private lastTickMs: number = 0;

  /** 帧间隔(毫秒),约 60 FPS。 */
  private static readonly FRAME_INTERVAL_MS: number = 16;

  /**
   * 绑定 Scene(用于 renderFrame)。
   *
   * @param scene Scene 实例
   */
  public bindScene(scene: Scene | null): void {
    this.scene = scene;
  }

  /**
   * 绑定相机更新回调。
   *
   * @param updatable 实现 FrameUpdatable 的对象(通常为 CameraController)
   */
  public bindCamera(updatable: FrameUpdatable | null): void {
    this.cameraUpdatable = updatable;
  }

  /**
   * 绑定模型更新回调。
   *
   * @param updatable 实现 FrameUpdatable 的对象(通常为 ModelController)
   */
  public bindModel(updatable: FrameUpdatable | null): void {
    this.modelUpdatable = updatable;
  }

  /**
   * 启动帧循环。
   *
   * 幂等:若已 RUNNING,直接返回。
   */
  public start(): void {
    if (this.state === FrameLoopState.RUNNING) {
      return;
    }
    this.state = FrameLoopState.RUNNING;
    this.lastTickMs = systemDateTime.getTime();

    // 使用箭头函数保留 this 绑定
    this.timerId = setInterval(() => {
      this.tick();
    }, ViewerFrameLoop.FRAME_INTERVAL_MS);
  }

  /**
   * 停止帧循环。
   *
   * 幂等:若已 STOPPED,直接返回。
   */
  public stop(): void {
    if (this.state === FrameLoopState.STOPPED) {
      return;
    }
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.state = FrameLoopState.STOPPED;
  }

  /**
   * 获取当前状态。
   */
  public getState(): FrameLoopState {
    return this.state;
  }

  /**
   * 是否正在运行。
   */
  public isRunning(): boolean {
    return this.state === FrameLoopState.RUNNING;
  }

  /**
   * 单帧执行(由 setInterval 触发)。
   *
   * 顺序:
   * 1. delta = (now - lastTick) / 1000
   * 2. cameraController.update(delta)
   * 3. modelController.update(delta)
   * 4. scene.renderFrame({ alwaysRender: false })
   */
  private tick(): void {
    if (this.state !== FrameLoopState.RUNNING) {
      return;
    }
    const nowMs = systemDateTime.getTime();
    const deltaSeconds = (nowMs - this.lastTickMs) / 1000.0;
    this.lastTickMs = nowMs;

    // 1. 更新相机
    const cam = this.cameraUpdatable;
    if (cam !== null) {
      try {
        cam.update(deltaSeconds);
      } catch (_) {
        // 忽略单帧异常
      }
    }

    // 2. 更新模型
    const model = this.modelUpdatable;
    if (model !== null) {
      try {
        model.update(deltaSeconds);
      } catch (_) {
        // 忽略单帧异常
      }
    }

    // 3. 渲染
    const s = this.scene;
    if (s !== null) {
      try {
        s.renderFrame({ alwaysRender: false });
      } catch (_) {
        // 忽略单帧渲染异常
      }
    }
  }
}
