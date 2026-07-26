/**
 * QuaternionUtil 四元数数学工具
 *
 * T-4.2E: VRM Humanoid 动作重定向所需的四元数运算。
 *
 * 使用项目自定义的 QuaternionValue 类型({x, y, z, w} 格式,遵循 glTF 规范),
 * 而非 ArkGraphics3D 的 Quaternion,以便纯逻辑代码可单元测试。
 *
 * 乘法顺序:q1 * q2 表示先应用 q2 再应用 q1(局部坐标系,父到子)。
 *
 * 参考:
 * - glTF 2.0 规范:rotation 为 VEC4 [x, y, z, w],单位四元数
 * - VRM 1.0:局部旋转 localRotation,父骨骼空间
 */

import { QuaternionValue } from '../models/character3d/HumanoidMotionClip';

/**
 * 单位四元数 (identity): 表示无旋转。
 */
export function quaternionIdentity(): QuaternionValue {
  return { x: 0, y: 0, z: 0, w: 1 };
}

/**
 * 四元数乘法 q1 * q2。
 *
 * 注意:在骨骼层级中,parentRotation * childLocalRotation 表示
 * 先应用 child 的局部旋转,再应用 parent 的旋转。
 *
 * @param q1 左乘四元数(通常是 parent 或 targetRest)
 * @param q2 右乘四元数(通常是 child 或 delta)
 * @returns q1 * q2
 */
export function quaternionMultiply(q1: QuaternionValue, q2: QuaternionValue): QuaternionValue {
  return {
    x: q1.w * q2.x + q1.x * q2.w + q1.y * q2.z - q1.z * q2.y,
    y: q1.w * q2.y - q1.x * q2.z + q1.y * q2.w + q1.z * q2.x,
    z: q1.w * q2.z + q1.x * q2.y - q1.y * q2.x + q1.z * q2.w,
    w: q1.w * q2.w - q1.x * q2.x - q1.y * q2.y - q1.z * q2.z
  };
}

/**
 * 四元数共轭(对于单位四元数,等于逆)。
 *
 * @param q 输入四元数(应为单位四元数)
 * @returns 共轭四元数
 */
export function quaternionConjugate(q: QuaternionValue): QuaternionValue {
  return { x: -q.x, y: -q.y, z: -q.z, w: q.w };
}

/**
 * 四元数逆(对于单位四元数,等于共轭)。
 *
 * @param q 输入四元数
 * @returns 逆四元数
 */
export function quaternionInverse(q: QuaternionValue): QuaternionValue {
  const dot: number = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w;
  if (Math.abs(dot) < 1e-12) {
    return quaternionIdentity();
  }
  const invDot: number = 1.0 / dot;
  // 对于单位四元数 dot=1,结果即共轭
  return {
    x: -q.x * invDot,
    y: -q.y * invDot,
    z: -q.z * invDot,
    w: q.w * invDot
  };
}

/**
 * 四元数归一化。
 *
 * @param q 输入四元数
 * @returns 归一化后的单位四元数;输入为零四元数时返回 identity
 */
export function quaternionNormalize(q: QuaternionValue): QuaternionValue {
  const len: number = Math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  if (len < 1e-12) {
    return quaternionIdentity();
  }
  const inv: number = 1.0 / len;
  return { x: q.x * inv, y: q.y * inv, z: q.z * inv, w: q.w * inv };
}

/**
 * 四元数是否有效(非 NaN,非 Infinity,长度接近 1)。
 *
 * @param q 输入四元数
 * @param tolerance 长度误差容忍度(默认 0.001)
 * @returns 是否有效
 */
export function quaternionIsValid(q: QuaternionValue, tolerance: number = 0.001): boolean {
  if (isNaN(q.x) || isNaN(q.y) || isNaN(q.z) || isNaN(q.w)) {
    return false;
  }
  if (!isFinite(q.x) || !isFinite(q.y) || !isFinite(q.z) || !isFinite(q.w)) {
    return false;
  }
  const len: number = Math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  return Math.abs(len - 1.0) <= tolerance;
}

/**
 * 四元数点积。
 *
 * @param q1 四元数 1
 * @param q2 四元数 2
 * @returns 点积
 */
export function quaternionDot(q1: QuaternionValue, q2: QuaternionValue): number {
  return q1.x * q2.x + q1.y * q2.y + q1.z * q2.z + q1.w * q2.w;
}

/**
 * 球面线性插值 (SLERP)。
 *
 * 处理:
 * - 最短路径(dot < 0 时取反)
 * - 接近时退化为线性插值(dot > 0.9995)
 * - t=0 返回 q1,t=1 返回 q2
 * - 归一化结果
 *
 * @param q1 起始四元数
 * @param q2 结束四元数
 * @param t 插值参数 [0, 1]
 * @returns 插值后的四元数(归一化)
 */
export function quaternionSlerp(q1: QuaternionValue, q2: QuaternionValue, t: number): QuaternionValue {
  // 边界情况
  if (t <= 0.0) {
    return { x: q1.x, y: q1.y, z: q1.z, w: q1.w };
  }
  if (t >= 1.0) {
    return { x: q2.x, y: q2.y, z: q2.z, w: q2.w };
  }

  let bx: number = q2.x;
  let by: number = q2.y;
  let bz: number = q2.z;
  let bw: number = q2.w;

  let dot: number = quaternionDot(q1, q2);

  // 最短路径:如果点积为负,取反 q2
  if (dot < 0.0) {
    bx = -bx;
    by = -by;
    bz = -bz;
    bw = -bw;
    dot = -dot;
  }

  // 接近时退化为线性插值,避免 sin(theta) 接近 0 的数值不稳定
  if (dot > 0.9995) {
    const rx: number = q1.x + t * (bx - q1.x);
    const ry: number = q1.y + t * (by - q1.y);
    const rz: number = q1.z + t * (bz - q1.z);
    const rw: number = q1.w + t * (bw - q1.w);
    return quaternionNormalize({ x: rx, y: ry, z: rz, w: rw });
  }

  // 球面插值
  const theta: number = Math.acos(Math.max(-1.0, Math.min(1.0, dot)));
  const sinTheta: number = Math.sin(theta);
  const sinThetaInv: number = 1.0 / sinTheta;
  const w1: number = Math.sin((1.0 - t) * theta) * sinThetaInv;
  const w2: number = Math.sin(t * theta) * sinThetaInv;

  return {
    x: w1 * q1.x + w2 * bx,
    y: w1 * q1.y + w2 * by,
    z: w1 * q1.z + w2 * bz,
    w: w1 * q1.w + w2 * bw
  };
}

/**
 * 判断两个四元数是否相等(分量误差 < epsilon)。
 *
 * @param q1 四元数 1
 * @param q2 四元数 2
 * @param epsilon 误差容忍度(默认 1e-6)
 * @returns 是否相等
 */
export function quaternionEqual(q1: QuaternionValue, q2: QuaternionValue, epsilon: number = 1e-6): boolean {
  return Math.abs(q1.x - q2.x) <= epsilon
    && Math.abs(q1.y - q2.y) <= epsilon
    && Math.abs(q1.z - q2.z) <= epsilon
    && Math.abs(q1.w - q2.w) <= epsilon;
}

/**
 * 四元数转欧拉角(度),返回 [x, y, z] 即 [pitch, yaw, roll]。
 *
 * T-4.2G-A: 用于诊断 Rest Pose 类型(T Pose / A Pose / 双臂下垂)。
 *
 * 采用 ZYX 旋转顺序(即 Yaw-Pitch-Roll),与 glTF 默认约定一致:
 * q = qz * qy * qx (先应用 X,再 Y,再 Z)
 *
 * @param q 单位四元数
 * @returns [x, y, z] 欧拉角(度),范围 x∈[-90,90], y∈[-180,180], z∈[-180,180]
 */
export function quaternionToEulerDeg(q: QuaternionValue): number[] {
  // 归一化以确保数值稳定
  const len: number = Math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  const x: number = q.x / len;
  const y: number = q.y / len;
  const z: number = q.z / len;
  const w: number = q.w / len;

  // Pitch (X 轴旋转)
  const sinPitch: number = 2.0 * (w * x - y * z);
  const pitchRad: number = Math.asin(Math.max(-1.0, Math.min(1.0, sinPitch)));

  // Yaw (Y 轴旋转)
  const sinYaw: number = 2.0 * (w * y + x * z);
  const cosYaw: number = 1.0 - 2.0 * (y * y + x * x);
  const yawRad: number = Math.atan2(sinYaw, cosYaw);

  // Roll (Z 轴旋转)
  const sinRoll: number = 2.0 * (w * z + x * y);
  const cosRoll: number = 1.0 - 2.0 * (z * z + x * x);
  const rollRad: number = Math.atan2(sinRoll, cosRoll);

  const deg: number = 180.0 / Math.PI;
  return [pitchRad * deg, yawRad * deg, rollRad * deg];
}
