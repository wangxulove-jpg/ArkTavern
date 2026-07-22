/**
 * Character3DLoadState 3D 加载状态机(纯逻辑,无平台依赖)
 *
 * 临时开发测试: T-3D.1 内置模型与 3D 渲染 PoC
 *
 * 状态机:
 *
 *   Disposed ──init──▶ Loading ──ok──▶ Ready ──play──▶ Playing
 *                        │              │                 │
 *                        ├──err──▶ Failed◀─stop───────────┤
 *                        │              │                 │
 *                        ▼              ▼                 ▼
 *                     Disposed◀──── dispose ───────────────┘
 *                                       ▲
 *   Ready ──pause──▶ Paused ──resume──▶ Playing
 *   Paused ──stop──▶ Ready
 *   Failed ──retry──▶ Loading
 *
 * 任何状态都可 dispose → Disposed。Disposed 后所有转换拒绝。
 *
 * 不依赖 ArkUI / ArkGraphics3D,可独立单元测试。
 */

/**
 * 3D 加载状态枚举。
 */
export enum Character3DLoadStateEnum {
  /** 已释放,不可再使用 */
  Disposed = 'Disposed',
  /** 加载中 */
  Loading = 'Loading',
  /** 加载完成,待机 */
  Ready = 'Ready',
  /** 播放中 */
  Playing = 'Playing',
  /** 暂停 */
  Paused = 'Paused',
  /** 加载失败 */
  Failed = 'Failed'
}

/**
 * 判断状态转换是否合法。
 *
 * 规则:
 * - Disposed 只能进 Loading(init/retry)
 * - Loading 可进 Ready / Failed / Disposed
 * - Ready 可进 Playing / Paused / Disposed
 * - Playing 可进 Paused / Ready(stop) / Disposed
 * - Paused 可进 Playing(resume) / Ready(stop) / Disposed
 * - Failed 可进 Loading(retry) / Disposed
 * - 同状态保持返回 false(避免无意义通知)
 *
 * @param from 当前状态
 * @param to 目标状态
 * @returns 合法返回 true
 */
export function isValidStateTransition(
  from: Character3DLoadStateEnum,
  to: Character3DLoadStateEnum
): boolean {
  if (from === to) {
    return false;
  }
  switch (from) {
    case Character3DLoadStateEnum.Disposed:
      return to === Character3DLoadStateEnum.Loading;
    case Character3DLoadStateEnum.Loading:
      return to === Character3DLoadStateEnum.Ready
        || to === Character3DLoadStateEnum.Failed
        || to === Character3DLoadStateEnum.Disposed;
    case Character3DLoadStateEnum.Ready:
      return to === Character3DLoadStateEnum.Playing
        || to === Character3DLoadStateEnum.Paused
        || to === Character3DLoadStateEnum.Disposed;
    case Character3DLoadStateEnum.Playing:
      return to === Character3DLoadStateEnum.Paused
        || to === Character3DLoadStateEnum.Ready
        || to === Character3DLoadStateEnum.Disposed;
    case Character3DLoadStateEnum.Paused:
      return to === Character3DLoadStateEnum.Playing
        || to === Character3DLoadStateEnum.Ready
        || to === Character3DLoadStateEnum.Disposed;
    case Character3DLoadStateEnum.Failed:
      return to === Character3DLoadStateEnum.Loading
        || to === Character3DLoadStateEnum.Disposed;
    default:
      return false;
  }
}

/**
 * 判断状态是否可响应用户操作(播放/暂停/恢复)。
 * Disposed / Loading / Failed 状态不响应。
 *
 * @param state 当前状态
 * @returns 可响应返回 true
 */
export function canRespondToUserAction(state: Character3DLoadStateEnum): boolean {
  return state === Character3DLoadStateEnum.Ready
    || state === Character3DLoadStateEnum.Playing
    || state === Character3DLoadStateEnum.Paused;
}

/**
 * 判断状态是否已释放。
 * @param state 当前状态
 * @returns 已释放返回 true
 */
export function isDisposedState(state: Character3DLoadStateEnum): boolean {
  return state === Character3DLoadStateEnum.Disposed;
}

/**
 * 计算拖动产生的旋转角度(度数)。
 *
 * 将像素位移按 sensitivity 系数转换为旋转角度,并限制在 [-maxDeg, maxDeg] 范围内。
 * 默认 sensitivity=0.3(每像素 0.3 度),maxDeg=180。
 *
 * @param deltaPx 像素位移(正为右/下,负为左/上)
 * @param sensitivity 灵敏度(度/像素)
 * @param maxDeg 单次最大旋转度数
 * @returns 旋转角度(度数)
 */
export function computeDragRotationDeg(
  deltaPx: number,
  sensitivity: number = 0.3,
  maxDeg: number = 60
): number {
  if (!Number.isFinite(deltaPx) || !Number.isFinite(sensitivity) || !Number.isFinite(maxDeg)) {
    return 0;
  }
  if (sensitivity <= 0 || maxDeg <= 0) {
    return 0;
  }
  const raw: number = deltaPx * sensitivity;
  if (raw > maxDeg) {
    return maxDeg;
  }
  if (raw < -maxDeg) {
    return -maxDeg;
  }
  return raw;
}

/**
 * 将旋转角度(度数)归一化到 [-180, 180]。
 *
 * @param deg 原始角度
 * @returns 归一化后的角度
 */
export function normalizeRotationDeg(deg: number): number {
  if (!Number.isFinite(deg)) {
    return 0;
  }
  let v: number = deg % 360;
  if (v > 180) {
    v -= 360;
  } else if (v < -180) {
    v += 360;
  }
  return v;
}

/**
 * 默认视角配置(Y 轴旋转 0 度)。
 */
export const DEFAULT_VIEW_ROTATION_Y_DEG: number = 0;
