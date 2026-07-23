/**
 * DefaultHumanoidSkeleton 轻量人形骨架定义
 *
 * T-3D.6C-A: 为动作卡片预览提供 2D 骨骼动画基础。
 * 不使用 3D Scene,不加载 GLB,仅在 Canvas 上绘制线段和圆点。
 *
 * 骨骼结构(14 节点,前视图 2D):
 *
 *         Head
 *          |
 *         Neck
 *          |
 *   LSh — Spine — RSh
 *    |      |      |
 *  LArm     |     RArm
 *    |     Hips     |
 *  LHand   / \    RHand
 *         /   \
 *      LLeg   RLeg
 *       |       |
 *     LFoot   RFoot
 *
 * 坐标系:100×100 逻辑空间,原点左上,Y 轴向下。
 */

/**
 * 骨骼节点定义。
 */
export interface SkeletonNodeDef {
  /** 节点名(与 HumanoidBone 命名风格一致,简化为单骨) */
  name: string;
  /** 父节点名(null 表示根) */
  parent: string | null;
  /** 相对父节点的静止偏移 X(父节点局部坐标系) */
  offsetX: number;
  /** 相对父节点的静止偏移 Y(父节点局部坐标系) */
  offsetY: number;
}

/**
 * 默认人形骨架(14 节点)。
 * 节点顺序保证父节点在子节点之前,便于正向运动学遍历。
 */
export const DEFAULT_HUMANOID_SKELETON: SkeletonNodeDef[] = [
  { name: 'Hips', parent: null, offsetX: 50, offsetY: 56 },
  { name: 'Spine', parent: 'Hips', offsetX: 0, offsetY: -16 },
  { name: 'Neck', parent: 'Spine', offsetX: 0, offsetY: -8 },
  { name: 'Head', parent: 'Neck', offsetX: 0, offsetY: -9 },
  { name: 'LeftShoulder', parent: 'Spine', offsetX: -10, offsetY: -3 },
  { name: 'LeftArm', parent: 'LeftShoulder', offsetX: 0, offsetY: 13 },
  { name: 'LeftHand', parent: 'LeftArm', offsetX: 0, offsetY: 11 },
  { name: 'RightShoulder', parent: 'Spine', offsetX: 10, offsetY: -3 },
  { name: 'RightArm', parent: 'RightShoulder', offsetX: 0, offsetY: 13 },
  { name: 'RightHand', parent: 'RightArm', offsetX: 0, offsetY: 11 },
  { name: 'LeftLeg', parent: 'Hips', offsetX: -6, offsetY: 15 },
  { name: 'LeftFoot', parent: 'LeftLeg', offsetX: 0, offsetY: 16 },
  { name: 'RightLeg', parent: 'Hips', offsetX: 6, offsetY: 15 },
  { name: 'RightFoot', parent: 'RightLeg', offsetX: 0, offsetY: 16 }
];

/**
 * 骨骼节点名称常量。
 */
export const BONE_HIPS: string = 'Hips';
export const BONE_SPINE: string = 'Spine';
export const BONE_NECK: string = 'Neck';
export const BONE_HEAD: string = 'Head';
export const BONE_LEFT_SHOULDER: string = 'LeftShoulder';
export const BONE_LEFT_ARM: string = 'LeftArm';
export const BONE_LEFT_HAND: string = 'LeftHand';
export const BONE_RIGHT_SHOULDER: string = 'RightShoulder';
export const BONE_RIGHT_ARM: string = 'RightArm';
export const BONE_RIGHT_HAND: string = 'RightHand';
export const BONE_LEFT_LEG: string = 'LeftLeg';
export const BONE_LEFT_FOOT: string = 'LeftFoot';
export const BONE_RIGHT_LEG: string = 'RightLeg';
export const BONE_RIGHT_FOOT: string = 'RightFoot';

/**
 * 计算后的关节世界坐标。
 */
export interface ComputedJoint {
  name: string;
  x: number;
  y: number;
  /** 累积世界旋转角度(度) */
  worldAngle: number;
}

/**
 * 骨骼旋转条目(单个骨骼在某关键帧的旋转增量,度)。
 */
export interface BoneRotationEntry {
  bone: string;
  angle: number;
}

/**
 * 根据旋转增量数组计算所有关节的世界坐标。
 *
 * 正向运动学:
 * - 根节点位置 = 静止位置 + 根偏移
 * - 子节点位置 = 父节点位置 + rotate(静止偏移, 父世界旋转角)
 * - 节点世界旋转 = 父世界旋转 + 节点旋转增量
 *
 * @param rotations 骨骼旋转增量数组(未列出的骨骼旋转为 0)
 * @param rootOffsetX 根节点 X 偏移(用于呼吸/跳跃等根运动)
 * @param rootOffsetY 根节点 Y 偏移
 * @returns 关节名 → 世界坐标的映射数组(顺序与骨架定义一致)
 */
export function computeSkeletonJoints(
  rotations: BoneRotationEntry[],
  rootOffsetX: number,
  rootOffsetY: number
): ComputedJoint[] {
  const result: ComputedJoint[] = [];
  for (let i: number = 0; i < DEFAULT_HUMANOID_SKELETON.length; i++) {
    const node: SkeletonNodeDef = DEFAULT_HUMANOID_SKELETON[i];
    const ownRotation: number = lookupRotation(rotations, node.name);
    if (node.parent === null) {
      result.push({
        name: node.name,
        x: node.offsetX + rootOffsetX,
        y: node.offsetY + rootOffsetY,
        worldAngle: ownRotation
      });
    } else {
      const parentIndex: number = findJointIndex(result, node.parent);
      const parent: ComputedJoint = result[parentIndex];
      const rad: number = parent.worldAngle * Math.PI / 180;
      const cosV: number = Math.cos(rad);
      const sinV: number = Math.sin(rad);
      const dx: number = node.offsetX * cosV - node.offsetY * sinV;
      const dy: number = node.offsetX * sinV + node.offsetY * cosV;
      result.push({
        name: node.name,
        x: parent.x + dx,
        y: parent.y + dy,
        worldAngle: parent.worldAngle + ownRotation
      });
    }
  }
  return result;
}

/**
 * 在旋转数组中查找指定骨骼的旋转角度。
 */
function lookupRotation(rotations: BoneRotationEntry[], boneName: string): number {
  for (let i: number = 0; i < rotations.length; i++) {
    if (rotations[i].bone === boneName) {
      return rotations[i].angle;
    }
  }
  return 0;
}

/**
 * 在已计算关节数组中查找指定名称的索引。
 */
function findJointIndex(joints: ComputedJoint[], name: string): number {
  for (let i: number = 0; i < joints.length; i++) {
    if (joints[i].name === name) {
      return i;
    }
  }
  return 0;
}
