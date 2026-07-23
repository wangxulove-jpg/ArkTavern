/**
 * ActionPreviewCanvas 动作预览 Canvas 组件
 *
 * T-3D.6C-B: 修复黑屏问题,全面重写。
 *
 * 修复要点:
 * - tryStartRendering 统一启动条件(canvasReady + width>0 + height>0)
 * - 静态基线测试(红框+蓝圆+骨架)先于动画
 * - 低频日志(仅初始化 + 首次成功绘制)
 * - 暂停不清屏(onVisibleAreaChange false 只停 timer)
 * - 回屏时重新绘制一帧再启动 timer
 * - isFinitePoint 坐标防护(在 Renderer 中)
 * - ACTION_PREVIEW_DEBUG 调试模式(每帧叠加红框+信息)
 *
 * T-3D.6C-B v3 vp 坐标修复(关键):
 * - ArkUI Canvas 绘图坐标使用 vp 而非 px
 * - 旧代码将 vp 乘以 density 得到 px(例如 120vp * 3.0 = 360px),
 *   导致所有坐标 >120 的绘制落在 Canvas 表面之外,中心骨架不可见。
 * - 修复:直接传入 vp 值,不再乘 density。
 */

import { Logger } from '../utils/Logger';
import {
  BonePoseFrame,
  getKeyframes,
  interpolateKeyframes
} from '../models/character3d/ActionPreviewKeyframes';
import {
  Character3DActionPreviewRenderer,
  validateSkeletonDefinition,
  isActionPreviewDebug
} from '../models/character3d/Character3DActionPreviewRenderer';

const LOG_TAG: string = 'ActionPreviewCanvas';

/** 动画帧间隔(毫秒),约 30fps */
const FRAME_INTERVAL_MS: number = 33;
/** T-3D.6C-B v3: vp 坐标修复标记(已应用) */

@Component
export struct ActionPreviewCanvas {
  /** 动作 ID(用于查找关键帧) */
  @Prop actionId: string = '';
  /** 动作时长(毫秒) */
  @Prop durationMs: number = 2000;
  /** 是否循环播放 */
  @Prop loop: boolean = true;

  /** Canvas 绘图上下文 */
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  /** 渲染器实例 */
  private renderer: Character3DActionPreviewRenderer | null = null;
  /** 动画定时器 ID */
  private timerId: number = -1;
  /** 动画已播放时长(毫秒) */
  private elapsedMs: number = 0;
  /** 上次 tick 时间戳 */
  private lastTickTs: number = 0;

  /** Canvas onReady 是否已触发 */
  private canvasReady: boolean = false;
  /** Canvas 实际宽度(vp)— 直接传入 Renderer,不再乘 density */
  private canvasWidthVp: number = 0;
  /** Canvas 实际高度(vp)— 直接传入 Renderer,不再乘 density */
  private canvasHeightVp: number = 0;

  /** 是否暂停(页面隐藏/组件不可见) */
  private isPaused: boolean = false;
  /** 关键帧缓存 */
  private keyframes: BonePoseFrame[] = [];

  /** 日志:是否已记录初始化 */
  private hasLoggedInit: boolean = false;
  /** 日志:是否已记录首次绘制 */
  private hasLoggedFirstDraw: boolean = false;
  /** 骨架校验结果 */
  private skeletonValid: boolean = true;

  /** 调试模式(从 Renderer 读取) */
  private debugMode: boolean = isActionPreviewDebug();

  aboutToAppear(): void {
    this.keyframes = getKeyframes(this.actionId);
    const skelError: string | null = validateSkeletonDefinition();
    if (skelError !== null) {
      this.skeletonValid = false;
      Logger.error(LOG_TAG, 'skeleton validation failed: ' + skelError);
    }
  }

  aboutToDisappear(): void {
    this.stopAnimation();
  }

  /**
   * 统一启动条件判断。
   *
   * 必须同时满足:
   * - canvasReady === true
   * - canvasWidthVp > 0
   * - canvasHeightVp > 0
   *
   * 满足后:创建 renderer → 绘制首帧 → 启动定时器
   */
  private tryStartRendering(): void {
    if (!this.canvasReady) {
      return;
    }
    if (this.canvasWidthVp <= 0 || this.canvasHeightVp <= 0) {
      return;
    }
    if (this.renderer === null) {
      this.renderer = new Character3DActionPreviewRenderer(
        this.context,
        this.canvasWidthVp,
        this.canvasHeightVp
      );
    }

    if (!this.hasLoggedInit) {
      Logger.debug(LOG_TAG, 'preview canvas ready'
        + ' action=' + this.actionId
        + ' size=' + this.canvasWidthVp.toString() + 'x' + this.canvasHeightVp.toString() + 'vp'
        + ' frames=' + this.keyframes.length.toString()
        + ' skelValid=' + this.skeletonValid.toString());
      this.hasLoggedInit = true;
    }

    // 绘制首帧(含调试边框)
    this.renderFrame();

    // 启动动画
    this.startAnimation();
  }

  /**
   * 启动动画定时器。
   */
  private startAnimation(): void {
    if (this.timerId !== -1) {
      return;
    }
    if (this.keyframes.length === 0) {
      return;
    }
    this.lastTickTs = Date.now();
    this.timerId = setInterval((): void => {
      if (this.isPaused) {
        return;
      }
      const now: number = Date.now();
      const delta: number = now - this.lastTickTs;
      this.lastTickTs = now;
      this.elapsedMs += delta;
      this.renderFrame();
    }, FRAME_INTERVAL_MS);
  }

  /**
   * 停止动画定时器(不清屏,保留最后一帧)。
   */
  private stopAnimation(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /**
   * 渲染一帧。
   *
   * 顺序:
   * 1. drawBackground(清屏 + 背景色)
   * 2. drawPose(骨架)
   * 3. drawDebugBorder(调试红框,叠加在骨架之上)
   * 4. drawDebugOverlay(调试文字)
   */
  private renderFrame(): void {
    if (this.renderer === null) {
      return;
    }
    // 关键帧为空时画静态 T-Pose
    let pose: BonePoseFrame;
    if (this.keyframes.length === 0) {
      pose = { timestamp: 0, rotations: [], rootOffsetX: 0, rootOffsetY: 0 };
    } else {
      pose = interpolateKeyframes(
        this.keyframes,
        this.elapsedMs,
        this.durationMs,
        this.loop
      );
    }

    this.renderer.drawBackground();
    const invalidCount: number = this.renderer.drawPose(pose);

    if (this.debugMode) {
      this.renderer.drawDebugBorder();
      this.renderer.drawDebugOverlay(this.actionId, 14, invalidCount);
    }

    if (!this.hasLoggedFirstDraw) {
      Logger.debug(LOG_TAG, 'preview first draw'
        + ' action=' + this.actionId
        + ' time=' + this.elapsedMs.toString()
        + ' invalid=' + invalidCount.toString());
      this.hasLoggedFirstDraw = true;
    }
  }

  build(): void {
    Canvas(this.context)
      .width('100%')
      .height('100%')
      .zIndex(0)
      .onReady((): void => {
        this.canvasReady = true;
        if (this.canvasWidthVp > 0 && this.canvasHeightVp > 0) {
          this.tryStartRendering();
        }
      })
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        const widthVp: number = this.extractVpSize(newValue.width);
        const heightVp: number = this.extractVpSize(newValue.height);
        if (widthVp <= 0 || heightVp <= 0) {
          return;
        }
        // T-3D.6C-B v3: 直接使用 vp,不再乘 density
        // ArkUI Canvas 绘图坐标使用 vp,乘 density 会导致坐标超出表面
        this.canvasWidthVp = widthVp;
        this.canvasHeightVp = heightVp;
        if (this.renderer !== null) {
          this.renderer.resize(widthVp, heightVp);
          this.renderFrame();
        }
        this.tryStartRendering();
      })
      .onVisibleAreaChange([0.0, 0.5, 1.0], (isVisible: boolean, currentRatio: number) => {
        if (!isVisible || currentRatio <= 0) {
          // 不可见:停止 timer,保留画面
          this.isPaused = true;
          this.stopAnimation();
        } else {
          // 可见:重绘一帧 + 启动 timer
          this.isPaused = false;
          this.renderFrame();
          this.startAnimation();
        }
      });
  }

  /**
   * 从 Area 的 width/height 中提取 vp 数值。
   */
  private extractVpSize(len: Length): number {
    if (typeof len === 'number') {
      return len;
    }
    return 0;
  }
}
