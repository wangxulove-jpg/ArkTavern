/**
 * ViewerTypes VRM Viewer 核心类型与常量定义
 *
 * 定义 Viewer 状态机、模型状态、帧循环状态、默认相机/灯光参数、
 * 测试 VRM 资源路径以及统一错误类型。
 *
 * Reference:
 * - figure-main: index.html L434–489 (initThree 默认相机/灯光参数)
 * - ownverse-vrm-viewer: analysis/CAMERA_PIPELINE.md §1 (相机参数),
 *   analysis/RENDER_LOOP.md (帧循环), analysis/VIEWER_ARCHITECTURE.md §3 (Bootstrap 序列)
 */

import { Color, Position3, Quaternion } from '@kit.ArkGraphics3D';

/**
 * Viewer 生命周期状态机。
 *
 * 合法转换:
 * - NOT_INITIALIZED → INITIALIZING (initialize 调用)
 * - INITIALIZING → LOADING_MODEL (Scene/Camera/Light 就绪,开始加载默认 VRM)
 * - INITIALIZING → FAILED (初始化异常)
 * - LOADING_MODEL → READY (加载完成)
 * - LOADING_MODEL → FAILED (加载异常或 Scene 树为空)
 * - READY → LOADING_MODEL (替换模型)
 * - READY → DISPOSING (dispose 调用)
 * - FAILED → DISPOSING (dispose 调用)
 * - FAILED → LOADING_MODEL (重试加载)
 * - DISPOSING → DISPOSED (释放完成)
 *
 * 非法转换:
 * - 任何 → DISPOSED 后再转换
 * - DISPOSED → 任何
 * - NOT_INITIALIZED → LOADING_MODEL (必须先 INITIALIZING)
 */
export enum ViewerState {
  /** 初始状态,Scene/Camera/Light 均未创建。 */
  NOT_INITIALIZED = 0,
  /** Scene/Camera/Light 创建中。 */
  INITIALIZING = 1,
  /** VRM 模型加载中。 */
  LOADING_MODEL = 2,
  /** 模型就绪,帧循环运行中。 */
  READY = 3,
  /** 初始化或加载失败,保留错误摘要。 */
  FAILED = 4,
  /** 资源释放中。 */
  DISPOSING = 5,
  /** 已销毁,所有引用已清空。 */
  DISPOSED = 6
}

/**
 * 当前模型加载状态(独立于 ViewerState,用于调试 Tab 显示)。
 */
export enum ModelState {
  NOT_LOADED = 0,
  LOADING = 1,
  READY = 2,
  FAILED = 3
}

/**
 * 帧循环状态。
 */
export enum FrameLoopState {
  STOPPED = 0,
  RUNNING = 1
}

/**
 * 默认相机参数。
 *
 * FOV=30 / Near=0.1 / Far=1000 由任务指令明确,且 OWNverse `controls.reset()` 后值一致。
 * Position=(0,1.5,3) / Target=(0,1.5,0) 由任务指令明确(OWNverse 已确认值)。
 * Figure 使用 (0,1.25,2.0) 与 far=20,本阶段不采纳。
 */
export const DEFAULT_CAMERA_FOV: number = 30;
export const DEFAULT_CAMERA_NEAR: number = 0.1;
export const DEFAULT_CAMERA_FAR: number = 1000;
export const DEFAULT_CAMERA_POSITION: Position3 = { x: 0, y: 1.5, z: 3 };
export const DEFAULT_CAMERA_TARGET: Position3 = { x: 0, y: 1.5, z: 0 };

/**
 * 默认背景色(Figure #222222,暗背景更适合 VRM 预览)。
 * OWNverse 使用 #e6effc,本阶段不采纳。
 */
export const DEFAULT_BACKGROUND_COLOR: Color = {
  r: 0x22 / 0xff,
  g: 0x22 / 0xff,
  b: 0x22 / 0xff,
  a: 1.0
};

/**
 * 默认灯光参数。
 *
 * Figure: DirectionalLight(white, intensity=3.0), position=(1,1,1).normalize()。
 * OWNverse: DirectionalLight(white), dir=(1,1,1).normalize()。
 * ArkGraphics3D LightType 仅 DIRECTIONAL/SPOT,无 AMBIENT;Figure AmbientLight 强度=0,可省略。
 */
export const DEFAULT_LIGHT_INTENSITY: number = 3.0;
export const DEFAULT_LIGHT_COLOR: Color = { r: 1.0, g: 1.0, b: 1.0, a: 1.0 };
export const DEFAULT_LIGHT_POSITION: Position3 = { x: 1, y: 1, z: 1 };

/**
 * VRM 模型加载后的 Y 轴旋转角(弧度)。
 *
 * Figure 对 VRM 0.x 与 1.x 均执行 `vrm.scene.rotation.y = Math.PI`,
 * 使模型面向相机。ArkGraphics3D Node.rotation 为四元数,
 * 需从欧拉角 (0, π, 0) 转换。
 */
export const VRM_MODEL_Y_ROTATION_RAD: number = Math.PI;

/**
 * 测试 VRM 资源路径(集中定义,禁止在生产代码其他位置硬编码)。
 *
 * 部署位置:entry/src/main/resources/rawfile/vrm/default.vrm
 * 来源:reference/figure-main/VRM/default.vrm
 */
export class ViewerTestAssets {
  /** 默认测试 VRM 在 rawfile 下的相对路径。 */
  public static readonly DEFAULT_VRM: string = 'vrm/default.vrm';
}

/**
 * Viewer 统一错误类型。
 * phase 字段记录错误发生时的 ViewerState,便于调试。
 */
export class ViewerError extends Error {
  public readonly phase: ViewerState;

  constructor(message: string, phase: ViewerState) {
    super(message);
    this.name = 'ViewerError';
    this.phase = phase;
  }
}

/**
 * 将欧拉角 (0, yRad, 0) 转换为四元数 {x,y,z,w}。
 *
 * ArkGraphics3D Node.rotation 为 Quaternion {x,y,z,w},
 * 绕 Y 轴旋转 θ 的四元数为 (0, sin(θ/2), 0, cos(θ/2))。
 *
 * @param yRad Y 轴旋转弧度
 * @returns Quaternion 对象
 */
export function quaternionFromEulerY(yRad: number): Quaternion {
  const half: number = yRad / 2;
  return {
    x: 0,
    y: Math.sin(half),
    z: 0,
    w: Math.cos(half)
  };
}

/**
 * 验证 ViewerState 转换是否合法。
 *
 * 合法转换(见 ViewerState 注释):
 * - NOT_INITIALIZED → INITIALIZING
 * - INITIALIZING → LOADING_MODEL
 * - INITIALIZING → FAILED
 * - LOADING_MODEL → READY
 * - LOADING_MODEL → FAILED
 * - READY → LOADING_MODEL
 * - READY → DISPOSING
 * - FAILED → DISPOSING
 * - FAILED → LOADING_MODEL
 * - DISPOSING → DISPOSED
 *
 * @param from 当前状态
 * @param to 目标状态
 * @returns 合法返回 true,非法返回 false
 */
export function isValidStateTransition(from: ViewerState, to: ViewerState): boolean {
  // DISPOSED 是终态,不能再转换
  if (from === ViewerState.DISPOSED) {
    return false;
  }

  // 相同状态不算转换
  if (from === to) {
    return true;
  }

  switch (from) {
    case ViewerState.NOT_INITIALIZED:
      return to === ViewerState.INITIALIZING;

    case ViewerState.INITIALIZING:
      return to === ViewerState.LOADING_MODEL
        || to === ViewerState.FAILED
        || to === ViewerState.DISPOSING;

    case ViewerState.LOADING_MODEL:
      return to === ViewerState.READY
        || to === ViewerState.FAILED
        || to === ViewerState.DISPOSING;

    case ViewerState.READY:
      return to === ViewerState.LOADING_MODEL
        || to === ViewerState.DISPOSING;

    case ViewerState.FAILED:
      return to === ViewerState.LOADING_MODEL
        || to === ViewerState.DISPOSING;

    case ViewerState.DISPOSING:
      return to === ViewerState.DISPOSED;

    default:
      return false;
  }
}

/**
 * 将 ViewerState 转换为调试 Tab 显示字符串。
 *
 * @param state Viewer 状态
 * @returns 调试显示文本
 */
export function viewerStateLabel(state: ViewerState): string {
  switch (state) {
    case ViewerState.NOT_INITIALIZED:
      return 'NOT_INITIALIZED';
    case ViewerState.INITIALIZING:
      return 'INITIALIZING';
    case ViewerState.LOADING_MODEL:
      return 'LOADING_MODEL';
    case ViewerState.READY:
      return 'READY';
    case ViewerState.FAILED:
      return 'FAILED';
    case ViewerState.DISPOSING:
      return 'DISPOSING';
    case ViewerState.DISPOSED:
      return 'DISPOSED';
    default:
      return 'UNKNOWN';
  }
}

/**
 * 将 ModelState 转换为调试 Tab 显示字符串。
 *
 * @param state 模型状态
 * @returns 调试显示文本
 */
export function modelStateLabel(state: ModelState): string {
  switch (state) {
    case ModelState.NOT_LOADED:
      return 'NOT_LOADED';
    case ModelState.LOADING:
      return 'LOADING';
    case ModelState.READY:
      return 'READY';
    case ModelState.FAILED:
      return 'FAILED';
    default:
      return 'UNKNOWN';
  }
}
