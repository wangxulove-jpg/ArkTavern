/**
 * Character3DDisplayConfig 3D 模型显示配置(纯逻辑,无平台依赖)
 *
 * 临时开发测试: T-3D.4 模型预览与位置校准
 *
 * 职责:
 * - 定义显示参数(scale / offset / rotation / cameraDistance)
 * - 定义上下限与默认值
 * - 提供夹紧、归一化、NaN/Infinity 防御
 * - 提供序列化/反序列化(JSON 字符串,用于 Preferences 存储)
 * - 提供配置迁移(字段缺失时回退默认)
 *
 * 不依赖 ArkUI / ArkGraphics3D,可独立单元测试。
 *
 * 参数说明:
 * - scale:模型整体缩放,默认 1.0,范围 [0.1, 8.0]
 * - offsetX/Y/Z:模型在三个轴的位移,默认 0,范围 [-5.0, 5.0]
 * - rotationX/Y/Z:模型三轴旋转(度数),默认 0,范围 [-180, 180]
 *   rotationY 与 T-3D.1 的拖动旋转共用同一字段
 * - cameraDistance:相机距离原点的距离,默认 3.5,范围 [0.5, 20.0]
 *   实际相机位置 = (0, cameraHeight, cameraDistance),cameraHeight 固定 1.2
 */

/** scale 下限 */
export const SCALE_MIN: number = 0.1;
/** scale 上限 */
export const SCALE_MAX: number = 8.0;
/** offset 各轴下限 */
export const OFFSET_MIN: number = -5.0;
/** offset 各轴上限 */
export const OFFSET_MAX: number = 5.0;
/** rotation 各轴下限(度数) */
export const ROTATION_MIN_DEG: number = -180;
/** rotation 各轴上限(度数) */
export const ROTATION_MAX_DEG: number = 180;
/** cameraDistance 下限 */
export const CAMERA_DISTANCE_MIN: number = 0.5;
/** cameraDistance 上限 */
export const CAMERA_DISTANCE_MAX: number = 20.0;

/** 默认 scale */
export const DEFAULT_SCALE: number = 1.0;
/** 默认 offset X */
export const DEFAULT_OFFSET_X: number = 0;
/** 默认 offset Y */
export const DEFAULT_OFFSET_Y: number = 0;
/** 默认 offset Z */
export const DEFAULT_OFFSET_Z: number = 0;
/** 默认 rotation X(度数) */
export const DEFAULT_ROTATION_X_DEG: number = 0;
/** 默认 rotation Y(度数) */
export const DEFAULT_ROTATION_Y_DEG: number = 0;
/** 默认 rotation Z(度数) */
export const DEFAULT_ROTATION_Z_DEG: number = 0;
/** 默认 cameraDistance */
export const DEFAULT_CAMERA_DISTANCE: number = 3.5;
/** 相机高度(固定,不开放调节) */
export const CAMERA_HEIGHT: number = 1.2;
/** 相机 FOV(固定,不开放调节) */
export const CAMERA_FOV: number = 45;
/** 相机近裁面 */
export const CAMERA_NEAR: number = 0.1;
/** 相机远裁面 */
export const CAMERA_FAR: number = 100;

/**
 * 3D 模型显示配置。
 */
export interface Character3DDisplayConfig {
  /** 模型整体缩放 */
  scale: number;
  /** X 轴位移 */
  offsetX: number;
  /** Y 轴位移 */
  offsetY: number;
  /** Z 轴位移 */
  offsetZ: number;
  /** X 轴旋转(度数) */
  rotationXDeg: number;
  /** Y 轴旋转(度数,与拖动旋转共用) */
  rotationYDeg: number;
  /** Z 轴旋转(度数) */
  rotationZDeg: number;
  /** 相机距离 */
  cameraDistance: number;
}

/**
 * 创建默认配置。
 */
export function createDefaultDisplayConfig(): Character3DDisplayConfig {
  return {
    scale: DEFAULT_SCALE,
    offsetX: DEFAULT_OFFSET_X,
    offsetY: DEFAULT_OFFSET_Y,
    offsetZ: DEFAULT_OFFSET_Z,
    rotationXDeg: DEFAULT_ROTATION_X_DEG,
    rotationYDeg: DEFAULT_ROTATION_Y_DEG,
    rotationZDeg: DEFAULT_ROTATION_Z_DEG,
    cameraDistance: DEFAULT_CAMERA_DISTANCE
  };
}

/**
 * 夹紧单个数值到 [min, max]。
 * NaN / Infinity 回退到 fallback。
 */
function clampNumber(value: number, min: number, max: number, fallback: number): number {
  if (!Number.isFinite(value)) {
    return fallback;
  }
  if (value < min) {
    return min;
  }
  if (value > max) {
    return max;
  }
  return value;
}

/**
 * 将角度归一化到 [-180, 180]。
 * NaN / Infinity 返回 0。
 */
function normalizeDeg(deg: number): number {
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
 * 对配置中的每个字段做夹紧与 NaN/Infinity 防御。
 * 不修改原对象,返回新对象。
 *
 * 旋转字段处理顺序:先 normalize(把 270° 归一化为 -90°),再 clamp 到 [-180, 180]。
 * 这样用户输入 270° 会得到 -90°(等价角度),而不是被夹到 180°。
 *
 * @param config 原始配置(可能包含非法值)
 * @returns 合法配置
 */
export function sanitizeDisplayConfig(config: Character3DDisplayConfig): Character3DDisplayConfig {
  return {
    scale: clampNumber(config.scale, SCALE_MIN, SCALE_MAX, DEFAULT_SCALE),
    offsetX: clampNumber(config.offsetX, OFFSET_MIN, OFFSET_MAX, DEFAULT_OFFSET_X),
    offsetY: clampNumber(config.offsetY, OFFSET_MIN, OFFSET_MAX, DEFAULT_OFFSET_Y),
    offsetZ: clampNumber(config.offsetZ, OFFSET_MIN, OFFSET_MAX, DEFAULT_OFFSET_Z),
    rotationXDeg: clampNumber(
      normalizeDeg(config.rotationXDeg), ROTATION_MIN_DEG, ROTATION_MAX_DEG, DEFAULT_ROTATION_X_DEG
    ),
    rotationYDeg: clampNumber(
      normalizeDeg(config.rotationYDeg), ROTATION_MIN_DEG, ROTATION_MAX_DEG, DEFAULT_ROTATION_Y_DEG
    ),
    rotationZDeg: clampNumber(
      normalizeDeg(config.rotationZDeg), ROTATION_MIN_DEG, ROTATION_MAX_DEG, DEFAULT_ROTATION_Z_DEG
    ),
    cameraDistance: clampNumber(
      config.cameraDistance, CAMERA_DISTANCE_MIN, CAMERA_DISTANCE_MAX, DEFAULT_CAMERA_DISTANCE
    )
  };
}

/**
 * 判断两个配置是否相等(逐字段比较,NaN 视为不等)。
 */
export function isDisplayConfigEqual(
  a: Character3DDisplayConfig,
  b: Character3DDisplayConfig
): boolean {
  return a.scale === b.scale
    && a.offsetX === b.offsetX
    && a.offsetY === b.offsetY
    && a.offsetZ === b.offsetZ
    && a.rotationXDeg === b.rotationXDeg
    && a.rotationYDeg === b.rotationYDeg
    && a.rotationZDeg === b.rotationZDeg
    && a.cameraDistance === b.cameraDistance;
}

/**
 * 序列化用的中间接口(ArkTS 要求对象字面量对应显式声明的接口)。
 */
interface DisplayConfigSerialized {
  scale: number;
  offsetX: number;
  offsetY: number;
  offsetZ: number;
  rotationXDeg: number;
  rotationYDeg: number;
  rotationZDeg: number;
  cameraDistance: number;
}

/**
 * 序列化为 JSON 字符串(用于 Preferences 存储)。
 */
export function serializeDisplayConfig(config: Character3DDisplayConfig): string {
  const obj: DisplayConfigSerialized = {
    scale: config.scale,
    offsetX: config.offsetX,
    offsetY: config.offsetY,
    offsetZ: config.offsetZ,
    rotationXDeg: config.rotationXDeg,
    rotationYDeg: config.rotationYDeg,
    rotationZDeg: config.rotationZDeg,
    cameraDistance: config.cameraDistance
  };
  return JSON.stringify(obj);
}

/**
 * 从 JSON 字符串反序列化。
 * 解析失败或字段缺失时,缺失字段回退默认值,最后做一次 sanitize。
 *
 * @param json JSON 字符串(可能为空或损坏)
 * @returns 合法配置(永不为 null)
 */
export function deserializeDisplayConfig(json: string): Character3DDisplayConfig {
  const fallback: Character3DDisplayConfig = createDefaultDisplayConfig();
  if (json === null || json === undefined || json.length === 0) {
    return fallback;
  }
  let parsed: Record<string, Object> | null = null;
  try {
    parsed = JSON.parse(json) as Record<string, Object>;
  } catch (_e) {
    return fallback;
  }
  if (parsed === null || parsed === undefined) {
    return fallback;
  }
  // 字段缺失时回退默认,类型不匹配也回退默认
  const config: Character3DDisplayConfig = {
    scale: typeof parsed['scale'] === 'number' ? (parsed['scale'] as number) : DEFAULT_SCALE,
    offsetX: typeof parsed['offsetX'] === 'number' ? (parsed['offsetX'] as number) : DEFAULT_OFFSET_X,
    offsetY: typeof parsed['offsetY'] === 'number' ? (parsed['offsetY'] as number) : DEFAULT_OFFSET_Y,
    offsetZ: typeof parsed['offsetZ'] === 'number' ? (parsed['offsetZ'] as number) : DEFAULT_OFFSET_Z,
    rotationXDeg: typeof parsed['rotationXDeg'] === 'number'
      ? (parsed['rotationXDeg'] as number) : DEFAULT_ROTATION_X_DEG,
    rotationYDeg: typeof parsed['rotationYDeg'] === 'number'
      ? (parsed['rotationYDeg'] as number) : DEFAULT_ROTATION_Y_DEG,
    rotationZDeg: typeof parsed['rotationZDeg'] === 'number'
      ? (parsed['rotationZDeg'] as number) : DEFAULT_ROTATION_Z_DEG,
    cameraDistance: typeof parsed['cameraDistance'] === 'number'
      ? (parsed['cameraDistance'] as number) : DEFAULT_CAMERA_DISTANCE
  };
  return sanitizeDisplayConfig(config);
}
