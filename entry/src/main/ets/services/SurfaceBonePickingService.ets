/**
 * SurfaceBonePickingService 3D 表面点选骨骼推断服务
 *
 * T-3D.6F-A: 通过点击模型表面推断对应 Bone。
 *
 * 职责:
 * - 屏幕坐标 → 世界射线(透视相机)
 * - 遍历 mesh primitive 三角形,ray-triangle 求交(Möller-Trumbore)
 * - 命中三角形 → 读取顶点 JOINTS/WEIGHTS → Bone 候选评分
 * - 预处理结果缓存(避免每次点击重新解析)
 *
 * 不依赖 ArkUI/ArkGraphics3D,纯逻辑可单元测试。
 *
 * 性能:
 * - 预处理一次,缓存世界空间三角形 + joint/weight 数据
 * - raycast 遍历所有三角形(O(n)),teacher-love 约 1k 三角形可接受
 * - Grace 524 joints 模型三角形更多,但仍可在 100ms 内完成
 */

import { Logger } from '../utils/Logger';
import {
  GlbParsedData,
  parseGlb,
  PrimitiveVertexData,
  collectAllPrimitiveVertexData,
  buildSkinJointNodes,
  getNodeName
} from '../parser/GltfVertexAccessor';
import {
  Ray3D,
  RayHitResult,
  BoneClickCandidate,
  SurfacePickingInput,
  createEmptyHitResult
} from '../models/character3d/SurfaceBoneCandidate';

const LOG_TAG: string = 'SurfaceBonePicking';

/** Möller-Trumbore 求交的 epsilon */
const RAY_TRIANGLE_EPSILON: number = 1e-7;

/**
 * Bone 权重聚合中间结构。
 */
interface BoneWeightAggregate {
  /** 总权重 */
  total: number;
  /** 影响顶点数 */
  count: number;
}

/**
 * 单个三角形的世界空间数据(用于 raycast + bone 推断)。
 *
 * T-3D.6F-A: 导出以供单元测试直接构造并调用 inferCandidates。
 */
export interface WorldTriangle {
  /** 顶点 0 世界坐标 */
  v0X: number; v0Y: number; v0Z: number;
  /** 顶点 1 世界坐标 */
  v1X: number; v1Y: number; v1Z: number;
  /** 顶点 2 世界坐标 */
  v2X: number; v2Y: number; v2Z: number;
  /** 顶点 0 的 4 个 joint 索引(skin.joints 下标,-1 表示无效) */
  j0: number[]; // 长度 4
  /** 顶点 0 的 4 个权重 */
  w0: number[]; // 长度 4
  /** 顶点 1 的 joint/weight */
  j1: number[];
  w1: number[];
  /** 顶点 2 的 joint/weight */
  j2: number[];
  w2: number[];
  /** 所属 primitive 索引 */
  primitiveIndex: number;
}

/**
 * 预处理后的可拾取网格数据。
 */
export interface PickableMeshData {
  /** 世界空间三角形数组 */
  triangles: WorldTriangle[];
  /** skin.joints 数组(nodeIndex 列表) */
  jointNodes: number[];
  /** 是否有效(有三角形且有 skin 数据) */
  valid: boolean;
  /** 三角形总数 */
  triangleCount: number;
}

/**
 * SurfaceBonePickingService 表面点选服务。
 *
 * 使用流程:
 * 1. setModelTransform(scale, offsetX, offsetY, offsetZ, rotX, rotY, rotZ) 设置模型变换
 * 2. prepare(glbBuffer) 预处理(构建世界空间三角形,缓存)
 * 3. pickBone(input) 执行点选,返回候选列表
 * 4. invalidate() 清除缓存(模型变换变化时调用)
 */
export class SurfaceBonePickingService {
  /** 预处理缓存 */
  private pickableData: PickableMeshData | null = null;
  /** 模型变换参数 */
  private modelScale: number = 1.0;
  private modelOffsetX: number = 0;
  private modelOffsetY: number = 0;
  private modelOffsetZ: number = 0;
  private modelRotXDeg: number = 0;
  private modelRotYDeg: number = 0;
  private modelRotZDeg: number = 0;
  /** GLB buffer 缓存(用于检测是否需要重新预处理) */
  private cachedGlbBuffer: ArrayBuffer | null = null;

  /**
   * 设置模型变换参数。
   *
   * 变换顺序:Scale → Rotation(Z*Y*X) → Translation
   * 即 worldPos = T(offset) * R(rot) * S(scale) * localPos
   */
  setModelTransform(
    scale: number,
    offsetX: number, offsetY: number, offsetZ: number,
    rotXDeg: number, rotYDeg: number, rotZDeg: number
  ): void {
    this.modelScale = scale;
    this.modelOffsetX = offsetX;
    this.modelOffsetY = offsetY;
    this.modelOffsetZ = offsetZ;
    this.modelRotXDeg = rotXDeg;
    this.modelRotYDeg = rotYDeg;
    this.modelRotZDeg = rotZDeg;
  }

  /**
   * 预处理:解析 GLB,构建世界空间三角形。
   *
   * @param glbBuffer GLB 文件 ArrayBuffer
   * @returns true 预处理成功
   */
  prepare(glbBuffer: ArrayBuffer): boolean {
    if (this.cachedGlbBuffer === glbBuffer && this.pickableData !== null) {
      return true;
    }
    const parsed: GlbParsedData = parseGlb(glbBuffer);
    if (!parsed.valid) {
      Logger.warn(LOG_TAG, 'prepare: parseGlb failed: ' + parsed.errorMessage);
      return false;
    }
    const jointNodes: number[] = buildSkinJointNodes(parsed, 0);
    if (jointNodes.length === 0) {
      Logger.warn(LOG_TAG, 'prepare: no skin joints');
      return false;
    }
    const primitives: PrimitiveVertexData[] = collectAllPrimitiveVertexData(parsed);
    if (primitives.length === 0) {
      Logger.warn(LOG_TAG, 'prepare: no primitives');
      return false;
    }
    // 计算旋转矩阵(欧拉角 ZYX 顺序)
    const rotMatrix: number[] = this.computeRotationMatrixZYX(
      this.modelRotXDeg, this.modelRotYDeg, this.modelRotZDeg
    );
    // 构建世界空间三角形
    const triangles: WorldTriangle[] = [];
    for (let p: number = 0; p < primitives.length; p++) {
      const prim: PrimitiveVertexData = primitives[p];
      if (!prim.hasSkinData) {
        continue;
      }
      // 遍历三角形
      const triCount: number = prim.triangleCount;
      for (let t: number = 0; t < triCount; t++) {
        let i0: number, i1: number, i2: number;
        if (prim.indices !== null) {
          i0 = prim.indices[t * 3];
          i1 = prim.indices[t * 3 + 1];
          i2 = prim.indices[t * 3 + 2];
        } else {
          i0 = t * 3;
          i1 = t * 3 + 1;
          i2 = t * 3 + 2;
        }
        if (i0 >= prim.vertexCount || i1 >= prim.vertexCount || i2 >= prim.vertexCount) {
          continue;
        }
        // 本地坐标
        const l0x: number = prim.positions[i0 * 3];
        const l0y: number = prim.positions[i0 * 3 + 1];
        const l0z: number = prim.positions[i0 * 3 + 2];
        const l1x: number = prim.positions[i1 * 3];
        const l1y: number = prim.positions[i1 * 3 + 1];
        const l1z: number = prim.positions[i1 * 3 + 2];
        const l2x: number = prim.positions[i2 * 3];
        const l2y: number = prim.positions[i2 * 3 + 1];
        const l2z: number = prim.positions[i2 * 3 + 2];
        // 应用 scale
        const sx: number = this.modelScale;
        const s0x: number = l0x * sx, s0y: number = l0y * sx, s0z: number = l0z * sx;
        const s1x: number = l1x * sx, s1y: number = l1y * sx, s1z: number = l1z * sx;
        const s2x: number = l2x * sx, s2y: number = l2y * sx, s2z: number = l2z * sx;
        // 应用旋转
        const r0: number[] = this.transformPoint(rotMatrix, s0x, s0y, s0z);
        const r1: number[] = this.transformPoint(rotMatrix, s1x, s1y, s1z);
        const r2: number[] = this.transformPoint(rotMatrix, s2x, s2y, s2z);
        // 应用平移
        const tri: WorldTriangle = {
          v0X: r0[0] + this.modelOffsetX,
          v0Y: r0[1] + this.modelOffsetY,
          v0Z: r0[2] + this.modelOffsetZ,
          v1X: r1[0] + this.modelOffsetX,
          v1Y: r1[1] + this.modelOffsetY,
          v1Z: r1[2] + this.modelOffsetZ,
          v2X: r2[0] + this.modelOffsetX,
          v2Y: r2[1] + this.modelOffsetY,
          v2Z: r2[2] + this.modelOffsetZ,
          j0: this.readJointIndices(prim, i0, jointNodes),
          w0: this.readWeights(prim, i0),
          j1: this.readJointIndices(prim, i1, jointNodes),
          w1: this.readWeights(prim, i1),
          j2: this.readJointIndices(prim, i2, jointNodes),
          w2: this.readWeights(prim, i2),
          primitiveIndex: p
        };
        triangles.push(tri);
      }
    }
    this.pickableData = {
      triangles: triangles,
      jointNodes: jointNodes,
      valid: triangles.length > 0,
      triangleCount: triangles.length
    };
    this.cachedGlbBuffer = glbBuffer;
    Logger.info(LOG_TAG, 'prepare: triangles=' + triangles.length
      + ', joints=' + jointNodes.length);
    return this.pickableData.valid;
  }

  /**
   * 读取顶点的 joint 索引(转为 skin.joints 下标 → nodeIndex)。
   *
   * JOINTS_0 存储的是 skin.joints 数组的下标,需映射为 nodeIndex。
   */
  private readJointIndices(
    prim: PrimitiveVertexData,
    vertexIndex: number,
    jointNodes: number[]
  ): number[] {
    const result: number[] = [-1, -1, -1, -1];
    if (prim.joints === null) {
      return result;
    }
    const base: number = vertexIndex * 4;
    for (let k: number = 0; k < 4; k++) {
      const jointIdx: number = prim.joints[base + k];
      if (jointIdx >= 0 && jointIdx < jointNodes.length) {
        result[k] = jointNodes[jointIdx];
      }
    }
    return result;
  }

  /**
   * 读取顶点的权重。
   */
  private readWeights(prim: PrimitiveVertexData, vertexIndex: number): number[] {
    const result: number[] = [0, 0, 0, 0];
    if (prim.weights === null) {
      return result;
    }
    const base: number = vertexIndex * 4;
    for (let k: number = 0; k < 4; k++) {
      result[k] = prim.weights[base + k];
    }
    return result;
  }

  /**
   * 执行表面点选,返回 Bone 候选列表。
   *
   * @param input 点选输入(屏幕坐标 + 相机参数)
   * @returns 候选列表(按 score 降序,最多 5 个),空数组表示未命中或无 skin
   */
  pickBone(input: SurfacePickingInput): BoneClickCandidate[] {
    if (this.pickableData === null || !this.pickableData.valid) {
      return [];
    }
    // 1. 屏幕坐标 → 世界射线
    const ray: Ray3D = this.screenToWorldRay(input);
    // 2. ray-triangle 求交,找最近命中
    const hit: RayHitResult = this.raycastClosest(ray, this.pickableData.triangles);
    if (!hit.hit) {
      Logger.info(LOG_TAG, 'pickBone: no hit');
      return [];
    }
    // 3. 读取命中三角形的 joint/weight,推断候选
    const candidates: BoneClickCandidate[] = this.inferCandidates(
      hit, this.pickableData.triangles
    );
    Logger.info(LOG_TAG, 'pickBone: hit tri=' + hit.triangleIndex
      + ', candidates=' + candidates.length);
    return candidates;
  }

  /**
   * 屏幕坐标 → 世界射线(透视相机)。
   *
   * 算法:
   * 1. NDC: x = 2*sx/width - 1, y = 1 - 2*sy/height
   * 2. 相机基:forward = normalize(target - pos), right = cross(forward, up), cameraUp = cross(right, forward)
   * 3. 视口半高 = tan(fov/2), 半宽 = halfH * aspect
   * 4. 射线方向 = normalize(forward + right*ndcX*halfW + cameraUp*ndcY*halfH)
   */
  screenToWorldRay(input: SurfacePickingInput): Ray3D {
    // NDC
    const ndcX: number = 2.0 * input.screenX / input.viewportWidth - 1.0;
    const ndcY: number = 1.0 - 2.0 * input.screenY / input.viewportHeight;
    // 相机基
    const fX: number = input.cameraTargetX - input.cameraPosX;
    const fY: number = input.cameraTargetY - input.cameraPosY;
    const fZ: number = input.cameraTargetZ - input.cameraPosZ;
    const fLen: number = Math.sqrt(fX * fX + fY * fY + fZ * fZ);
    const forwardX: number = fX / fLen;
    const forwardY: number = fY / fLen;
    const forwardZ: number = fZ / fLen;
    // right = cross(forward, up=(0,1,0))
    const upX: number = 0, upY: number = 1, upZ: number = 0;
    const rX: number = forwardY * upZ - forwardZ * upY;
    const rY: number = forwardZ * upX - forwardX * upZ;
    const rZ: number = forwardX * upY - forwardY * upX;
    const rLen: number = Math.sqrt(rX * rX + rY * rY + rZ * rZ);
    let rightX: number, rightY: number, rightZ: number;
    if (rLen < 1e-6) {
      // 相机朝上,用 (0,0,1) 作为替代 up
      rightX = 1; rightY = 0; rightZ = 0;
    } else {
      rightX = rX / rLen; rightY = rY / rLen; rightZ = rZ / rLen;
    }
    // cameraUp = cross(right, forward)
    const cUpX: number = rightY * forwardZ - rightZ * forwardY;
    const cUpY: number = rightZ * forwardX - rightX * forwardZ;
    const cUpZ: number = rightX * forwardY - rightY * forwardX;
    // 视口半高/半宽
    const fovRad: number = input.cameraFovDeg * Math.PI / 180.0;
    const halfH: number = Math.tan(fovRad / 2.0);
    const aspect: number = input.viewportWidth / input.viewportHeight;
    const halfW: number = halfH * aspect;
    // 射线方向
    const dirX: number = forwardX + rightX * ndcX * halfW + cUpX * ndcY * halfH;
    const dirY: number = forwardY + rightY * ndcX * halfW + cUpY * ndcY * halfH;
    const dirZ: number = forwardZ + rightZ * ndcX * halfW + cUpZ * ndcY * halfH;
    const dLen: number = Math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ);
    return {
      originX: input.cameraPosX,
      originY: input.cameraPosY,
      originZ: input.cameraPosZ,
      dirX: dirX / dLen,
      dirY: dirY / dLen,
      dirZ: dirZ / dLen
    };
  }

  /**
   * Möller-Trumbore ray-triangle 求交。
   *
   * @returns t(命点参数) > 0 表示命中, < 0 表示未命中
   */
  rayTriangleIntersect(
    ray: Ray3D,
    v0X: number, v0Y: number, v0Z: number,
    v1X: number, v1Y: number, v1Z: number,
    v2X: number, v2Y: number, v2Z: number
  ): number {
    const e1X: number = v1X - v0X;
    const e1Y: number = v1Y - v0Y;
    const e1Z: number = v1Z - v0Z;
    const e2X: number = v2X - v0X;
    const e2Y: number = v2Y - v0Y;
    const e2Z: number = v2Z - v0Z;
    // h = cross(dir, e2)
    const hX: number = ray.dirY * e2Z - ray.dirZ * e2Y;
    const hY: number = ray.dirZ * e2X - ray.dirX * e2Z;
    const hZ: number = ray.dirX * e2Y - ray.dirY * e2X;
    // a = dot(e1, h)
    const a: number = e1X * hX + e1Y * hY + e1Z * hZ;
    if (a > -RAY_TRIANGLE_EPSILON && a < RAY_TRIANGLE_EPSILON) {
      return -1; // 射线与三角形平面平行
    }
    const f: number = 1.0 / a;
    // s = origin - v0
    const sX: number = ray.originX - v0X;
    const sY: number = ray.originY - v0Y;
    const sZ: number = ray.originZ - v0Z;
    // u = f * dot(s, h)
    const u: number = f * (sX * hX + sY * hY + sZ * hZ);
    if (u < 0 || u > 1) {
      return -1;
    }
    // q = cross(s, e1)
    const qX: number = sY * e1Z - sZ * e1Y;
    const qY: number = sZ * e1X - sX * e1Z;
    const qZ: number = sX * e1Y - sY * e1X;
    // v = f * dot(dir, q)
    const v: number = f * (ray.dirX * qX + ray.dirY * qY + ray.dirZ * qZ);
    if (v < 0 || u + v > 1) {
      return -1;
    }
    // t = f * dot(e2, q)
    const t: number = f * (e2X * qX + e2Y * qY + e2Z * qZ);
    if (t > RAY_TRIANGLE_EPSILON) {
      return t;
    }
    return -1;
  }

  /**
   * 遍历所有三角形,找最近命中。
   */
  private raycastClosest(ray: Ray3D, triangles: WorldTriangle[]): RayHitResult {
    let bestT: number = Number.MAX_VALUE;
    let bestTri: number = -1;
    let bestPrim: number = -1;
    for (let i: number = 0; i < triangles.length; i++) {
      const tri: WorldTriangle = triangles[i];
      const t: number = this.rayTriangleIntersect(
        ray,
        tri.v0X, tri.v0Y, tri.v0Z,
        tri.v1X, tri.v1Y, tri.v1Z,
        tri.v2X, tri.v2Y, tri.v2Z
      );
      if (t > 0 && t < bestT) {
        bestT = t;
        bestTri = i;
        bestPrim = tri.primitiveIndex;
      }
    }
    const result: RayHitResult = createEmptyHitResult();
    if (bestTri >= 0) {
      const tri: WorldTriangle = triangles[bestTri];
      result.hit = true;
      result.t = bestT;
      result.hitX = ray.originX + ray.dirX * bestT;
      result.hitY = ray.originY + ray.dirY * bestT;
      result.hitZ = ray.originZ + ray.dirZ * bestT;
      result.primitiveIndex = bestPrim;
      result.triangleIndex = bestTri;
      result.v0X = tri.v0X; result.v0Y = tri.v0Y; result.v0Z = tri.v0Z;
      result.v1X = tri.v1X; result.v1Y = tri.v1Y; result.v1Z = tri.v1Z;
      result.v2X = tri.v2X; result.v2Y = tri.v2Y; result.v2Z = tri.v2Z;
    }
    return result;
  }

  /**
   * 命中三角形 → Bone 候选评分。
   *
   * 算法:
   * 1. 收集 3 顶点的所有 (nodeIndex, weight) 对
   * 2. 按 nodeIndex 聚合:totalWeight += weight, vertexCount++
   * 3. averageWeight = totalWeight / vertexCount
   * 4. score = averageWeight(简化,权重越高越可能)
   * 5. 按 score 降序,取 Top 5
   */
  inferCandidates(
    hit: RayHitResult,
    triangles: WorldTriangle[]
  ): BoneClickCandidate[] {
    if (!hit.hit || hit.triangleIndex < 0 || hit.triangleIndex >= triangles.length) {
      return [];
    }
    const tri: WorldTriangle = triangles[hit.triangleIndex];
    // 聚合:nodeIndex → { totalWeight, vertexCount }
    const nodeIndexMap: Map<number, BoneWeightAggregate> = new Map();
    this.accumulateVertexWeights(tri.j0, tri.w0, nodeIndexMap);
    this.accumulateVertexWeights(tri.j1, tri.w1, nodeIndexMap);
    this.accumulateVertexWeights(tri.j2, tri.w2, nodeIndexMap);
    // 转为候选列表
    const candidates: BoneClickCandidate[] = [];
    nodeIndexMap.forEach((value: BoneWeightAggregate, nodeIndex: number) => {
      // 只考虑 vertexCount >= 1 且 total > 0.01 的候选
      if (value.total < 0.01 || value.count < 1) {
        return;
      }
      const avg: number = value.total / value.count;
      candidates.push({
        nodeIndex: nodeIndex,
        boneName: '', // 由调用方填充
        score: avg,
        vertexCount: value.count,
        averageWeight: avg,
        totalWeight: value.total
      });
    });
    // 按 score 降序
    candidates.sort((a: BoneClickCandidate, b: BoneClickCandidate) => {
      return b.score - a.score;
    });
    // 取 Top 5
    const top: BoneClickCandidate[] = candidates.slice(0, 5);
    return top;
  }

  /**
   * 累加单顶点的权重到聚合 Map。
   */
  private accumulateVertexWeights(
    joints: number[],
    weights: number[],
    map: Map<number, BoneWeightAggregate>
  ): void {
    for (let k: number = 0; k < 4; k++) {
      const nodeIdx: number = joints[k];
      const w: number = weights[k];
      if (nodeIdx < 0 || w < 0.001) {
        continue;
      }
      const existing: BoneWeightAggregate | undefined = map.get(nodeIdx);
      if (existing !== undefined) {
        existing.total += w;
        existing.count += 1;
      } else {
        const agg: BoneWeightAggregate = { total: w, count: 1 };
        map.set(nodeIdx, agg);
      }
    }
  }

  /**
   * 计算欧拉角(ZYX 顺序)旋转矩阵。
   *
   * R = Rz * Ry * Rx
   *
   * @returns 列主序 4x4 矩阵(长度 16)
   */
  private computeRotationMatrixZYX(
    rotXDeg: number, rotYDeg: number, rotZDeg: number
  ): number[] {
    const rx: number = rotXDeg * Math.PI / 180.0;
    const ry: number = rotYDeg * Math.PI / 180.0;
    const rz: number = rotZDeg * Math.PI / 180.0;
    const cx: number = Math.cos(rx), sx: number = Math.sin(rx);
    const cy: number = Math.cos(ry), sy: number = Math.sin(ry);
    const cz: number = Math.cos(rz), sz: number = Math.sin(rz);
    // Rz * Ry * Rx(列主序)
    const m: number[] = [
      cy * cz, cy * sz, -sy, 0,
      sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy, 0,
      cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy, 0,
      0, 0, 0, 1
    ];
    return m;
  }

  /**
   * 用旋转矩阵变换点。
   *
   * @param m 列主序 4x4 矩阵
   * @returns [x, y, z]
   */
  private transformPoint(m: number[], x: number, y: number, z: number): number[] {
    return [
      m[0] * x + m[4] * y + m[8] * z + m[12],
      m[1] * x + m[5] * y + m[9] * z + m[13],
      m[2] * x + m[6] * y + m[10] * z + m[14]
    ];
  }

  /**
   * 清除缓存。
   */
  invalidate(): void {
    this.pickableData = null;
    this.cachedGlbBuffer = null;
  }

  /**
   * 是否已预处理。
   */
  isPrepared(): boolean {
    return this.pickableData !== null && this.pickableData.valid;
  }

  /**
   * 获取缓存三角形数量。
   */
  getTriangleCount(): number {
    return this.pickableData !== null ? this.pickableData.triangleCount : 0;
  }
}
