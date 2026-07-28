/**
 * ViewerFrameLoop — 基于 requestAnimationFrame 的渲染循环
 *
 * 职责:
 *   - requestAnimationFrame 驱动
 *   - 计算 delta time(限制最大值,避免后台恢复跳变)
 *   - 开始 / 停止 / 防止重复启动
 *   - 页面不可见时跳过 update(但仍继续 rAF,恢复时通过 MAX_DELTA 限制)
 *   - Dispose
 *
 * Reference:
 *   - figure-main/index.html animate():
 *       requestAnimationFrame(animate)
 *       const deltaTime = clock.getDelta()
 *       controls.update()
 *       renderer.render(scene, camera)
 *   - ownverse-vrm-viewer/analysis/RENDER_LOOP.md: 交叉验证
 *     (OWNverse 用 setAnimationLoop,Figure 用 rAF,以 Figure 为准)
 *
 * 与 Figure 的差异:
 *   - Figure 用 THREE.Clock.getDelta(),本实现用 performance.now() 手动计算(避免依赖 THREE.Clock)
 *   - Figure 不处理页面可见性,本实现补充 document.hidden 检查
 *   - Figure 在 animate 中直接 controls.update + renderer.render,本实现通过回调解耦
 *
 * 每帧顺序(由 ViewerCore 通过 updateCallback 编排):
 *   FRAME_START
 *   1. 计算 deltaSeconds
 *   2. camera.update(deltaSeconds)
 *   3. scene.render(camera)
 *   FRAME_END
 */

/** 最大 delta 时间(秒),避免页面后台恢复后跳变 */
var MAX_DELTA_SECONDS = 0.1;

export class ViewerFrameLoop {
  constructor() {
    /** @type {boolean} */
    this._running = false;
    /** @type {number} timestamp of last frame (ms) */
    this._lastTime = 0;
    /** @type {number|null} rAF id */
    this._rafId = null;
    /** @type {function((deltaSeconds: number)): void|null} */
    this._updateCallback = null;
    /** @type {function} bound animate fn(便于 cancelAnimationFrame) */
    this._boundAnimate = this._animate.bind(this);
    this._disposed = false;
  }

  /**
   * 启动帧循环。
   * 防止重复启动:若已在运行,直接返回。
   * @param {function(deltaSeconds: number): void} updateCallback 每帧回调
   */
  start(updateCallback) {
    if (this._disposed) return;
    if (this._running) return; // 防止重复启动
    this._running = true;
    this._updateCallback = updateCallback;
    this._lastTime = performance.now();
    this._rafId = requestAnimationFrame(this._boundAnimate);
  }

  /** 停止帧循环。 */
  stop() {
    if (!this._running) return;
    this._running = false;
    if (this._rafId !== null) {
      cancelAnimationFrame(this._rafId);
      this._rafId = null;
    }
    this._updateCallback = null;
  }

  /** @returns {boolean} */
  isRunning() {
    return this._running;
  }

  /** 内部 animate 循环。 */
  _animate(now) {
    if (!this._running) return;
    this._rafId = requestAnimationFrame(this._boundAnimate);

    // 页面不可见时跳过 update(恢复时 MAX_DELTA 会限制跳变)
    if (document.hidden) {
      this._lastTime = now;
      return;
    }

    var deltaMs = now - this._lastTime;
    this._lastTime = now;
    var deltaSeconds = deltaMs / 1000;
    // 限制最大 delta,避免后台恢复后跳变
    if (deltaSeconds > MAX_DELTA_SECONDS) {
      deltaSeconds = MAX_DELTA_SECONDS;
    }
    if (deltaSeconds < 0) {
      deltaSeconds = 0;
    }

    if (this._updateCallback) {
      try {
        this._updateCallback(deltaSeconds);
      } catch (e) {
        console.error('[ViewerFrameLoop] update callback threw: ' + (e && e.message ? e.message : String(e)));
      }
    }
  }

  dispose() {
    if (this._disposed) return;
    this._disposed = true;
    this.stop();
  }
}
