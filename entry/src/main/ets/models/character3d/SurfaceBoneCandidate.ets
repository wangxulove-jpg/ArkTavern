/**
 * SurfaceBoneCandidate 3D 表面点选骨骼候选数据结构
 *
 * T-3D.6F-A: 通过点击模型表面辅助骨骼映射。
 *
 * 职责:
 * - 定义 BoneClickCandidate(单个 Bone 候选评分)
 * - 定义 MappingInteractionMode(点选交互状态机)
 * - 定义 RayHitResult(射线命中结果)
 * - 定义 SurfacePickingInput(点选输入参数)
 *
 * 不依赖 ArkUI/ArkGraphics3D,纯逻辑可单元测试。
 */

/**
 * 单个 Bone 候选评分。
 */
export interface BoneClickCandidate {
  /** 源节点索引(glTF nodes 数组下标) */
  nodeIndex: number;
  /** 骨骼名(原始 name) */
  boneName: string;
  /** 综合评分(0.0~1.0,越大越优先) */
  score: number;
  /** 影响顶点数(3 个顶点中该 bone 影响的数量) */
  vertexCount: number;
  /** 平均权重(0.0~1.0) */
  averageWeight: number;
  /** 总权重(3 个顶点该 bone 权重之和) */
  totalWeight: number;
}

/**
 * 点选交互状态机。
 *
 * 流程:
 * Normal → BoneTreeSelect(选标准关节) → SurfacePicking(点模型) →
 * ConfirmCandidate(确认候选) → Normal
 *
 * 任何状态均可取消回到 Normal。
 */
export enum MappingInteractionMode {
  /** 正常浏览模式 */
  Normal = 'Normal',
  /** 已选标准关节,等待选择源骨骼(骨骼树或表面) */
  BoneTreeSelect = 'BoneTreeSelect',
  /** 表面点选模式,等待用户点击模型 */
  SurfacePicking = 'SurfacePicking',
  /** 候选确认模式,显示候选列表等待用户确认 */
  ConfirmCandidate = 'ConfirmCandidate'
}

/**
 * 3D 射线。
 */
export interface Ray3D {
  /** 射线起点(世界空间) */
  originX: number;
  originY: number;
  originZ: number;
  /** 射线方向(世界空间,已归一化) */
  dirX: number;
  dirY: number;
  dirZ: number;
}

/**
 * 射线命中三角形结果。
 */
export interface RayHitResult {
  /** 是否命中 */
  hit: boolean;
  /** 命点参数 t(origin + t*dir) */
  t: number;
  /** 命点世界坐标 X */
  hitX: number;
  /** 命点世界坐标 Y */
  hitY: number;
  /** 命点世界坐标 Z */
  hitZ: number;
  /** 命中三角形所属 primitive 索引 */
  primitiveIndex: number;
  /** 命中三角形在该 primitive 中的三角形索引(从 0 开始) */
  triangleIndex: number;
  /** 命中三角形 3 顶点的世界坐标 */
  v0X: number; v0Y: number; v0Z: number;
  v1X: number; v1Y: number; v1Z: number;
  v2X: number; v2Y: number; v2Z: number;
}

/**
 * 单个顶点的 Bone 权重信息。
 */
export interface VertexBoneWeight {
  /** 4 个 joint 索引(指向 skin.joints 数组下标) */
  jointIndices: number[];
  /** 4 个权重(与 jointIndices 一一对应) */
  weights: number[];
}

/**
 * 表面点选输入参数。
 */
export interface SurfacePickingInput {
  /** 屏幕点击 X 坐标(px) */
  screenX: number;
  /** 屏幕点击 Y 坐标(px) */
  screenY: number;
  /** 视口宽度(px) */
  viewportWidth: number;
  /** 视口高度(px) */
  viewportHeight: number;
  /** 相机位置 X(世界空间) */
  cameraPosX: number;
  /** 相机位置 Y(世界空间) */
  cameraPosY: number;
  /** 相机位置 Z(世界空间) */
  cameraPosZ: number;
  /** 相机目标 X(世界空间) */
  cameraTargetX: number;
  /** 相机目标 Y(世界空间) */
  cameraTargetY: number;
  /** 相机目标 Z(世界空间) */
  cameraTargetZ: number;
  /** 相机 fov(度) */
  cameraFovDeg: number;
  /** 相机 near */
  cameraNear: number;
  /** 相机 far */
  cameraFar: number;
}

/**
 * 创建空命中结果。
 */
export function createEmptyHitResult(): RayHitResult {
  return {
    hit: false,
    t: 0,
    hitX: 0, hitY: 0, hitZ: 0,
    primitiveIndex: -1,
    triangleIndex: -1,
    v0X: 0, v0Y: 0, v0Z: 0,
    v1X: 0, v1Y: 0, v1Z: 0,
    v2X: 0, v2Y: 0, v2Z: 0
  };
}
