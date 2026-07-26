/**
 * SceneNodeTransformUtil SceneNode 世界变换累乘工具
 *
 * T-4.2G-A2: 用于 TargetAvatarSkeleton 计算 Avatar 骨骼节点的实时 World Position。
 *
 * 背景:
 * ArkGraphics3D 的 Node 接口仅暴露本地 TRS(position/rotation/scale),
 * 没有提供 worldPosition / worldTransform 属性。
 * 要获取 World Position,必须遍历 Node.parent 链累乘 TRS。
 *
 * 由于每帧 retarget 后父骨骼的 rotation 可能变化,
 * 需要在每帧调用 computeNodeWorldTransform 重新计算。
 *
 * 数学:
 * 对于节点 N,其世界变换 = root_world × ... × parent_world × N.localTransform
 * 简化(忽略 scale 耦合):
 *   worldPos(N) = worldPos(parent) + worldRot(parent) × (localPos × parentScale)
 *   worldRot(N) = worldRot(parent) × localRot(N)
 *   worldScale(N) = worldScale(parent) × localScale(N)
 *
 * 注意:
 * - 严格 TRS 累乘下,scale 会影响 position 传递(父 scale 影响子位移)
 * - 本工具完整处理 scale 耦合,与 ArkGraphics3D 内部矩阵累乘一致
 * - 假设所有四元数为单位四元数(已归一化)
 */

import { Node } from '@kit.ArkGraphics3D';
import { QuaternionValue, Vector3Value } from '../models/character3d/HumanoidMotionClip';
import {
  quaternionMultiply,
  quaternionIdentity
} from './QuaternionUtil';

/**
 * 世界变换结果。
 */
export interface WorldTransform {
  /** 世界坐标位置 */
  position: Vector3Value;
  /** 世界旋转(单位四元数) */
  rotation: QuaternionValue;
  /** 世界缩放 */
  scale: Vector3Value;
}

/**
 * 计算节点的世界变换(从该节点向上遍历父链累乘)。
 *
 * 算法:
 * 1. 从 node 开始,收集所有父节点直到根(parent === null)
 * 2. 从根向下累乘:worldPos = parentWorldPos + parentWorldRot × (localPos × parentWorldScale)
 *                  worldRot = parentWorldRot × localRot
 *                  worldScale = parentWorldScale × localScale
 *
 * 时间复杂度:O(depth),平均骨骼层级深度 5-7
 *
 * @param node 目标节点
 * @returns 世界变换;若 node 为 null 返回 identity
 */
export function computeNodeWorldTransform(node: Node | null): WorldTransform {
  if (node === null) {
    return {
      position: { x: 0, y: 0, z: 0 },
      rotation: quaternionIdentity(),
      scale: { x: 1, y: 1, z: 1 }
    };
  }

  // 1. 收集从根到当前节点的路径
  const path: Node[] = [];
  let current: Node | null = node;
  while (current !== null) {
    path.push(current);
    current = current.parent;
  }
  // path[0] = node(最深),path[length-1] = root(最浅)

  // 2. 从根向下累乘
  // 初始为 identity
  let worldPos: Vector3Value = { x: 0, y: 0, z: 0 };
  let worldRot: QuaternionValue = quaternionIdentity();
  let worldScale: Vector3Value = { x: 1, y: 1, z: 1 };

  // 从根开始,所以倒序遍历
  for (let i: number = path.length - 1; i >= 0; i--) {
    const n: Node = path[i];
    // 读取本地 TRS(可能抛异常,需 try-catch)
    let localPos: Vector3Value = { x: 0, y: 0, z: 0 };
    let localRot: QuaternionValue = quaternionIdentity();
    let localScale: Vector3Value = { x: 1, y: 1, z: 1 };
    try {
      const p = n.position;
      localPos = { x: p.x, y: p.y, z: p.z };
    } catch (_e) {
      // ignore
    }
    try {
      const r = n.rotation;
      localRot = { x: r.x, y: r.y, z: r.z, w: r.w };
    } catch (_e) {
      // ignore
    }
    try {
      const s = n.scale;
      localScale = { x: s.x, y: s.y, z: s.z };
    } catch (_e) {
      // ignore
    }

    // 子节点本地 position 受父节点 scale 影响
    const scaledLocalPos: Vector3Value = {
      x: localPos.x * worldScale.x,
      y: localPos.y * worldScale.y,
      z: localPos.z * worldScale.z
    };
    // 子节点世界 position = 父世界 position + 父世界 rotation × scaledLocalPos
    const rotatedPos: Vector3Value = rotateVectorByQuaternion(scaledLocalPos, worldRot);
    worldPos = {
      x: worldPos.x + rotatedPos.x,
      y: worldPos.y + rotatedPos.y,
      z: worldPos.z + rotatedPos.z
    };
    // 子节点世界 rotation = 父世界 rotation × 本地 rotation
    worldRot = quaternionMultiply(worldRot, localRot);
    // 子节点世界 scale = 父世界 scale × 本地 scale
    worldScale = {
      x: worldScale.x * localScale.x,
      y: worldScale.y * localScale.y,
      z: worldScale.z * localScale.z
    };
  }

  return {
    position: worldPos,
    rotation: worldRot,
    scale: worldScale
  };
}

/**
 * 用四元数旋转向量。
 * v' = q × v × q*
 *
 * @param v 输入向量
 * @param q 单位四元数
 * @returns 旋转后的向量
 */
export function rotateVectorByQuaternion(v: Vector3Value, q: QuaternionValue): Vector3Value {
  const qx: number = q.x;
  const qy: number = q.y;
  const qz: number = q.z;
  const qw: number = q.w;

  // 优化公式:v' = v + 2*qw*(q×v) + 2*(q×(q×v))
  const tx: number = 2.0 * (qy * v.z - qz * v.y);
  const ty: number = 2.0 * (qz * v.x - qx * v.z);
  const tz: number = 2.0 * (qx * v.y - qy * v.x);

  return {
    x: v.x + qw * tx + (qy * tz - qz * ty),
    y: v.y + qw * ty + (qz * tx - qx * tz),
    z: v.z + qw * tz + (qx * ty - qy * tx)
  };
}

/**
 * 向量减法: a - b
 */
export function vectorSubtract(a: Vector3Value, b: Vector3Value): Vector3Value {
  return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
}

/**
 * 向量加法: a + b
 */
export function vectorAdd(a: Vector3Value, b: Vector3Value): Vector3Value {
  return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
}

/**
 * 向量数乘: v * s
 */
export function vectorScale(v: Vector3Value, s: number): Vector3Value {
  return { x: v.x * s, y: v.y * s, z: v.z * s };
}

/**
 * 向量点积。
 */
export function vectorDot(a: Vector3Value, b: Vector3Value): number {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

/**
 * 向量叉积: a × b
 */
export function vectorCross(a: Vector3Value, b: Vector3Value): Vector3Value {
  return {
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x
  };
}

/**
 * 向量长度。
 */
export function vectorLength(v: Vector3Value): number {
  return Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

/**
 * 向量归一化(零向量返回零向量)。
 */
export function vectorNormalize(v: Vector3Value): Vector3Value {
  const len: number = vectorLength(v);
  if (len < 1e-9) {
    return { x: 0, y: 0, z: 0 };
  }
  const inv: number = 1.0 / len;
  return { x: v.x * inv, y: v.y * inv, z: v.z * inv };
}

/**
 * 从一个方向向量计算旋转四元数,使默认方向(+Y 轴)旋转到该方向。
 *
 * 用于骨段(cube 默认沿 Y 轴)对齐到任意方向。
 *
 * 算法:
 * - 默认方向 d0 = (0, 1, 0)
 * - 目标方向 d1 = normalize(direction)
 * - 旋转轴 axis = d0 × d1
 * - 旋转角 angle = acos(d0 · d1)
 * - 四元数 q = (axis * sin(angle/2), cos(angle/2))
 *
 * 当 d1 与 d0 共线(同向或反向)时,旋转轴不确定,使用 fallback 轴。
 *
 * @param direction 目标方向(无需归一化,内部归一化)
 * @returns 旋转四元数
 */
export function rotationFromYAxisToDirection(direction: Vector3Value): QuaternionValue {
  const d1: Vector3Value = vectorNormalize(direction);
  const d0: Vector3Value = { x: 0, y: 1, z: 0 };

  const dot: number = vectorDot(d0, d1);
  // 共线检查
  if (Math.abs(dot - 1.0) < 1e-6) {
    // 同向,无旋转
    return quaternionIdentity();
  }
  if (Math.abs(dot + 1.0) < 1e-6) {
    // 反向,绕 Z 轴 180°
    return { x: 0, y: 0, z: 1, w: 0 };
  }

  const axis: Vector3Value = vectorCross(d0, d1);
  const axisNorm: Vector3Value = vectorNormalize(axis);
  const angle: number = Math.acos(Math.max(-1.0, Math.min(1.0, dot)));
  const halfAngle: number = angle * 0.5;
  const sinHalf: number = Math.sin(halfAngle);
  const cosHalf: number = Math.cos(halfAngle);

  return {
    x: axisNorm.x * sinHalf,
    y: axisNorm.y * sinHalf,
    z: axisNorm.z * sinHalf,
    w: cosHalf
  };
}
