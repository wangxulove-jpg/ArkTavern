/**
 * GltfBoundsCalculator 带 node world transform 的 Bounds 计算
 *
 * T-3D.6E P0: 修复 Bounds 未应用 world transform 导致模型不可见
 *
 * 职责:
 * - 遍历 glTF node 树计算每个节点的 world matrix
 * - 对每个 mesh primitive 的 POSITION accessor min/max 8 个角点应用 world matrix
 * - 合并所有 mesh instance 的世界 Bounds
 * - 处理 node.matrix 与 TRS(translation/rotation/scale)
 * - 防御 NaN/Infinity,跳过非法节点
 * - 不修改原 GLB 文件
 */

import { PositionBoundsResult } from './GltfValidator';

/**
 * 4x4 矩阵(列主序,与 glTF 一致)。
 */
interface Mat4 {
  m00: number; m01: number; m02: number; m03: number;
  m10: number; m11: number; m12: number; m13: number;
  m20: number; m21: number; m22: number; m23: number;
  m30: number; m31: number; m32: number; m33: number;
}

/**
 * 3D 点。
 */
interface Point3 {
  x: number;
  y: number;
  z: number;
}

/**
 * Accessor min/max 对。
 */
interface AccessorBounds {
  min: number[];
  max: number[];
}

/**
 * mesh primitive 的 POSITION accessor 引用。
 */
interface MeshPrimitivePosition {
  meshIndex: number;
  positionAccessorIndex: number;
}

/**
 * 单位矩阵。
 */
function identityMatrix(): Mat4 {
  const m: Mat4 = {
    m00: 1, m01: 0, m02: 0, m03: 0,
    m10: 0, m11: 1, m12: 0, m13: 0,
    m20: 0, m21: 0, m22: 1, m23: 0,
    m30: 0, m31: 0, m32: 0, m33: 1
  };
  return m;
}

/**
 * 从 TRS 构建 4x4 矩阵(列主序)。
 * M = T * R * S
 */
function composeMatrixFromTRS(t: number[], r: number[], s: number[]): Mat4 {
  const tx: number = t.length > 0 && Number.isFinite(t[0]) ? t[0] : 0;
  const ty: number = t.length > 1 && Number.isFinite(t[1]) ? t[1] : 0;
  const tz: number = t.length > 2 && Number.isFinite(t[2]) ? t[2] : 0;
  const sx: number = s.length > 0 && Number.isFinite(s[0]) && s[0] !== 0 ? s[0] : 1;
  const sy: number = s.length > 1 && Number.isFinite(s[1]) && s[1] !== 0 ? s[1] : 1;
  const sz: number = s.length > 2 && Number.isFinite(s[2]) && s[2] !== 0 ? s[2] : 1;
  let qx: number = r.length > 0 && Number.isFinite(r[0]) ? r[0] : 0;
  let qy: number = r.length > 1 && Number.isFinite(r[1]) ? r[1] : 0;
  let qz: number = r.length > 2 && Number.isFinite(r[2]) ? r[2] : 0;
  let qw: number = r.length > 3 && Number.isFinite(r[3]) ? r[3] : 1;
  const qLen: number = Math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
  if (qLen > 1e-9) {
    qx /= qLen; qy /= qLen; qz /= qLen; qw /= qLen;
  } else {
    qx = 0; qy = 0; qz = 0; qw = 1;
  }

  const r00: number = 1 - 2 * (qy * qy + qz * qz);
  const r01: number = 2 * (qx * qy - qz * qw);
  const r02: number = 2 * (qx * qz + qy * qw);
  const r10: number = 2 * (qx * qy + qz * qw);
  const r11: number = 1 - 2 * (qx * qx + qz * qz);
  const r12: number = 2 * (qy * qz - qx * qw);
  const r20: number = 2 * (qx * qz - qy * qw);
  const r21: number = 2 * (qy * qz + qx * qw);
  const r22: number = 1 - 2 * (qx * qx + qy * qy);

  const m: Mat4 = {
    m00: sx * r00, m01: sy * r01, m02: sz * r02, m03: tx,
    m10: sx * r10, m11: sy * r11, m12: sz * r12, m13: ty,
    m20: sx * r20, m21: sy * r21, m22: sz * r22, m23: tz,
    m30: 0,        m31: 0,        m32: 0,        m33: 1
  };
  return m;
}

/**
 * 从 glTF node.matrix(16 个数,列主序)构建 Mat4。
 */
function parseMatrixArray(arr: number[]): Mat4 | null {
  if (arr.length < 16) {
    return null;
  }
  for (let i: number = 0; i < 16; i++) {
    if (!Number.isFinite(arr[i])) {
      return null;
    }
  }
  const m: Mat4 = {
    m00: arr[0],  m01: arr[4],  m02: arr[8],  m03: arr[12],
    m10: arr[1],  m11: arr[5],  m12: arr[9],  m13: arr[13],
    m20: arr[2],  m21: arr[6],  m22: arr[10], m23: arr[14],
    m30: arr[3],  m31: arr[7],  m32: arr[11], m33: arr[15]
  };
  return m;
}

/**
 * 矩阵乘法:parent * local。
 */
function multiplyMatrices(a: Mat4, b: Mat4): Mat4 {
  const m: Mat4 = {
    m00: a.m00 * b.m00 + a.m01 * b.m10 + a.m02 * b.m20 + a.m03 * b.m30,
    m01: a.m00 * b.m01 + a.m01 * b.m11 + a.m02 * b.m21 + a.m03 * b.m31,
    m02: a.m00 * b.m02 + a.m01 * b.m12 + a.m02 * b.m22 + a.m03 * b.m32,
    m03: a.m00 * b.m03 + a.m01 * b.m13 + a.m02 * b.m23 + a.m03 * b.m33,
    m10: a.m10 * b.m00 + a.m11 * b.m10 + a.m12 * b.m20 + a.m13 * b.m30,
    m11: a.m10 * b.m01 + a.m11 * b.m11 + a.m12 * b.m21 + a.m13 * b.m31,
    m12: a.m10 * b.m02 + a.m11 * b.m12 + a.m12 * b.m22 + a.m13 * b.m32,
    m13: a.m10 * b.m03 + a.m11 * b.m13 + a.m12 * b.m23 + a.m13 * b.m33,
    m20: a.m20 * b.m00 + a.m21 * b.m10 + a.m22 * b.m20 + a.m23 * b.m30,
    m21: a.m20 * b.m01 + a.m21 * b.m11 + a.m22 * b.m21 + a.m23 * b.m31,
    m22: a.m20 * b.m02 + a.m21 * b.m12 + a.m22 * b.m22 + a.m23 * b.m32,
    m23: a.m20 * b.m03 + a.m21 * b.m13 + a.m22 * b.m23 + a.m23 * b.m33,
    m30: a.m30 * b.m00 + a.m31 * b.m10 + a.m32 * b.m20 + a.m33 * b.m30,
    m31: a.m30 * b.m01 + a.m31 * b.m11 + a.m32 * b.m21 + a.m33 * b.m31,
    m32: a.m30 * b.m02 + a.m31 * b.m12 + a.m32 * b.m22 + a.m33 * b.m32,
    m33: a.m30 * b.m03 + a.m31 * b.m13 + a.m32 * b.m23 + a.m33 * b.m33
  };
  return m;
}

/**
 * 变换一个点:p' = M * p (w=1)。
 */
function transformPoint(m: Mat4, x: number, y: number, z: number): Point3 {
  const p: Point3 = {
    x: m.m00 * x + m.m01 * y + m.m02 * z + m.m03,
    y: m.m10 * x + m.m11 * y + m.m12 * z + m.m13,
    z: m.m20 * x + m.m21 * y + m.m22 * z + m.m23
  };
  return p;
}

/**
 * 检查矩阵是否有限。
 */
function isMatrixFinite(m: Mat4): boolean {
  return Number.isFinite(m.m00) && Number.isFinite(m.m01) && Number.isFinite(m.m02) && Number.isFinite(m.m03)
    && Number.isFinite(m.m10) && Number.isFinite(m.m11) && Number.isFinite(m.m12) && Number.isFinite(m.m13)
    && Number.isFinite(m.m20) && Number.isFinite(m.m21) && Number.isFinite(m.m22) && Number.isFinite(m.m23)
    && Number.isFinite(m.m30) && Number.isFinite(m.m31) && Number.isFinite(m.m32) && Number.isFinite(m.m33);
}

/**
 * 从 JSON 对象读取 number[]。
 */
function toNumberArray(obj: Object | undefined): number[] | null {
  if (obj === undefined || obj === null) {
    return null;
  }
  if (!(obj instanceof Array)) {
    return null;
  }
  const arr: number[] = [];
  const src: Object[] = obj as Object[];
  for (let i: number = 0; i < src.length; i++) {
    const v: Object = src[i];
    if (typeof v !== 'number' || !Number.isFinite(v as number)) {
      return null;
    }
    arr.push(v as number);
  }
  return arr;
}

/**
 * 获取数组长度。
 */
function getArrayLength(json: Record<string, Object>, key: string): number {
  const arr: Object | undefined = json[key];
  if (arr === undefined || arr === null || !(arr instanceof Array)) {
    return 0;
  }
  return (arr as Object[]).length;
}

/**
 * 获取指定 index 的 node 对象。
 */
function getNode(json: Record<string, Object>, index: number): Record<string, Object> | null {
  const nodesObj: Object | undefined = json['nodes'];
  if (nodesObj === undefined || nodesObj === null || !(nodesObj instanceof Array)) {
    return null;
  }
  const nodes: Object[] = nodesObj as Object[];
  if (index < 0 || index >= nodes.length) {
    return null;
  }
  const n: Object = nodes[index];
  if (n === null || n === undefined) {
    return null;
  }
  return n as Record<string, Object>;
}

/**
 * 获取指定 index 的 accessor 的 min/max。
 */
function getAccessorBounds(json: Record<string, Object>, accessorIndex: number): AccessorBounds | null {
  const accessorsObj: Object | undefined = json['accessors'];
  if (accessorsObj === undefined || accessorsObj === null || !(accessorsObj instanceof Array)) {
    return null;
  }
  const accessors: Object[] = accessorsObj as Object[];
  if (accessorIndex < 0 || accessorIndex >= accessors.length) {
    return null;
  }
  const accObj: Object = accessors[accessorIndex];
  if (accObj === null || accObj === undefined) {
    return null;
  }
  const acc: Record<string, Object> = accObj as Record<string, Object>;
  const min: number[] | null = toNumberArray(acc['min']);
  const max: number[] | null = toNumberArray(acc['max']);
  if (min === null || max === null || min.length < 3 || max.length < 3) {
    return null;
  }
  const result: AccessorBounds = {
    min: [min[0], min[1], min[2]],
    max: [max[0], max[1], max[2]]
  };
  return result;
}

/**
 * 收集所有 mesh primitive 的 POSITION accessor 索引,关联 mesh 索引。
 */
function collectAllMeshPositions(json: Record<string, Object>): MeshPrimitivePosition[] {
  const result: MeshPrimitivePosition[] = [];
  const meshesObj: Object | undefined = json['meshes'];
  if (meshesObj === undefined || meshesObj === null || !(meshesObj instanceof Array)) {
    return result;
  }
  const meshes: Object[] = meshesObj as Object[];
  for (let i: number = 0; i < meshes.length; i++) {
    const meshObj: Object = meshes[i];
    if (meshObj === null || meshObj === undefined) {
      continue;
    }
    const mesh: Record<string, Object> = meshObj as Record<string, Object>;
    const primsObj: Object | undefined = mesh['primitives'];
    if (primsObj === undefined || primsObj === null || !(primsObj instanceof Array)) {
      continue;
    }
    const prims: Object[] = primsObj as Object[];
    for (let j: number = 0; j < prims.length; j++) {
      const primObj: Object = prims[j];
      if (primObj === null || primObj === undefined) {
        continue;
      }
      const prim: Record<string, Object> = primObj as Record<string, Object>;
      const attrsObj: Object | undefined = prim['attributes'];
      if (attrsObj === undefined || attrsObj === null) {
        continue;
      }
      const attrs: Record<string, Object> = attrsObj as Record<string, Object>;
      const posIdxObj: Object | undefined = attrs['POSITION'];
      if (posIdxObj === undefined || posIdxObj === null || typeof posIdxObj !== 'number') {
        continue;
      }
      const posIdx: number = posIdxObj as number;
      if (!Number.isFinite(posIdx) || posIdx < 0) {
        continue;
      }
      const mp: MeshPrimitivePosition = {
        meshIndex: i,
        positionAccessorIndex: posIdx
      };
      result.push(mp);
    }
  }
  return result;
}

/**
 * 从 node 解析 local matrix(优先 matrix,其次 TRS)。
 */
function parseNodeLocalMatrix(node: Record<string, Object>): Mat4 {
  const matrixArr: number[] | null = toNumberArray(node['matrix']);
  if (matrixArr !== null && matrixArr.length >= 16) {
    const m: Mat4 | null = parseMatrixArray(matrixArr);
    if (m !== null && isMatrixFinite(m)) {
      return m;
    }
  }
  const tArr: number[] | null = toNumberArray(node['translation']);
  const rArr: number[] | null = toNumberArray(node['rotation']);
  const sArr: number[] | null = toNumberArray(node['scale']);
  const t: number[] = tArr !== null ? tArr : [0, 0, 0];
  const r: number[] = rArr !== null ? rArr : [0, 0, 0, 1];
  const s: number[] = sArr !== null ? sArr : [1, 1, 1];
  return composeMatrixFromTRS(t, r, s);
}

/**
 * 递归遍历 node 树,计算每个 node 的 world matrix。
 */
function computeWorldMatrices(json: Record<string, Object>): Map<number, Mat4> {
  const result: Map<number, Mat4> = new Map<number, Mat4>();
  const nodeCount: number = getArrayLength(json, 'nodes');
  if (nodeCount === 0) {
    return result;
  }

  // 缓存 local matrix
  const localMatrices: Mat4[] = new Array<Mat4>(nodeCount);
  for (let i: number = 0; i < nodeCount; i++) {
    const node: Record<string, Object> | null = getNode(json, i);
    if (node === null) {
      localMatrices[i] = identityMatrix();
      continue;
    }
    localMatrices[i] = parseNodeLocalMatrix(node);
  }

  // 缓存 children
  const childrenMap: number[][] = new Array<number[]>(nodeCount);
  for (let i: number = 0; i < nodeCount; i++) {
    childrenMap[i] = [];
  }
  const isChild: boolean[] = new Array<boolean>(nodeCount);
  for (let i: number = 0; i < nodeCount; i++) {
    isChild[i] = false;
  }
  for (let i: number = 0; i < nodeCount; i++) {
    const node: Record<string, Object> | null = getNode(json, i);
    if (node === null) {
      continue;
    }
    const childrenObj: Object | undefined = node['children'];
    if (childrenObj === undefined || childrenObj === null || !(childrenObj instanceof Array)) {
      continue;
    }
    const children: Object[] = childrenObj as Object[];
    const childIndices: number[] = [];
    for (let j: number = 0; j < children.length; j++) {
      const c: Object = children[j];
      if (typeof c !== 'number' || !Number.isFinite(c as number)) {
        continue;
      }
      const ci: number = c as number;
      if (ci < 0 || ci >= nodeCount) {
        continue;
      }
      childIndices.push(ci);
      isChild[ci] = true;
    }
    childrenMap[i] = childIndices;
  }

  // 根节点:未被任何 node 引用为 child 的节点
  const rootIndices: number[] = [];
  for (let i: number = 0; i < nodeCount; i++) {
    if (!isChild[i]) {
      rootIndices.push(i);
    }
  }

  // BFS 计算 world matrix
  const stack: number[] = [];
  for (let i: number = 0; i < rootIndices.length; i++) {
    stack.push(rootIndices[i]);
    result.set(rootIndices[i], localMatrices[rootIndices[i]]);
  }
  while (stack.length > 0) {
    const idx: number | undefined = stack.pop();
    if (idx === undefined) {
      break;
    }
    const parentWorld: Mat4 | undefined = result.get(idx);
    if (parentWorld === undefined) {
      continue;
    }
    if (!isMatrixFinite(parentWorld)) {
      continue;
    }
    const children: number[] = childrenMap[idx];
    for (let i: number = 0; i < children.length; i++) {
      const childIdx: number = children[i];
      const childLocal: Mat4 = localMatrices[childIdx];
      const childWorld: Mat4 = multiplyMatrices(parentWorld, childLocal);
      if (!isMatrixFinite(childWorld)) {
        continue;
      }
      result.set(childIdx, childWorld);
      stack.push(childIdx);
    }
  }

  return result;
}

/**
 * 收集每个 mesh 被哪些 node 引用。
 */
function collectMeshInstances(json: Record<string, Object>): Map<number, number[]> {
  const result: Map<number, number[]> = new Map<number, number[]>();
  const nodeCount: number = getArrayLength(json, 'nodes');
  for (let i: number = 0; i < nodeCount; i++) {
    const node: Record<string, Object> | null = getNode(json, i);
    if (node === null) {
      continue;
    }
    const meshIdxObj: Object | undefined = node['mesh'];
    if (meshIdxObj === undefined || meshIdxObj === null || typeof meshIdxObj !== 'number') {
      continue;
    }
    const meshIdx: number = meshIdxObj as number;
    if (!Number.isFinite(meshIdx) || meshIdx < 0) {
      continue;
    }
    let list: number[] | undefined = result.get(meshIdx);
    if (list === undefined) {
      list = [];
      result.set(meshIdx, list);
    }
    list.push(i);
  }
  return result;
}

/**
 * T-3D.6E: 计算 glTF 模型的世界 Bounds(应用 node world transform)。
 *
 * 算法:
 * 1. 遍历 node 树计算每个 node 的 world matrix
 * 2. 对每个 mesh primitive 的 POSITION accessor min/max:
 *    - 取 8 个角点(minX/minY/minZ 到 maxX/maxY/maxZ 的组合)
 *    - 通过引用该 mesh 的 node 的 world matrix 变换到世界坐标
 *    - 合并所有 instance 的世界 Bounds
 * 3. 若所有 mesh 都没有有效 world matrix 或 accessor min/max,返回 null
 */
export function computeWorldBounds(gltfJson: Record<string, Object>): PositionBoundsResult {
  const nodeCount: number = getArrayLength(gltfJson, 'nodes');
  const meshCount: number = getArrayLength(gltfJson, 'meshes');
  if (nodeCount === 0 || meshCount === 0) {
    const empty: PositionBoundsResult = { min: null, max: null } as PositionBoundsResult;
    return empty;
  }

  const worldMatrices: Map<number, Mat4> = computeWorldMatrices(gltfJson);
  const meshInstances: Map<number, number[]> = collectMeshInstances(gltfJson);
  const meshPositions: MeshPrimitivePosition[] = collectAllMeshPositions(gltfJson);
  if (meshPositions.length === 0) {
    const empty: PositionBoundsResult = { min: null, max: null } as PositionBoundsResult;
    return empty;
  }

  let aggMinX: number | null = null;
  let aggMinY: number | null = null;
  let aggMinZ: number | null = null;
  let aggMaxX: number | null = null;
  let aggMaxY: number | null = null;
  let aggMaxZ: number | null = null;

  for (let i: number = 0; i < meshPositions.length; i++) {
    const mp: MeshPrimitivePosition = meshPositions[i];
    const accBounds: AccessorBounds | null = getAccessorBounds(gltfJson, mp.positionAccessorIndex);
    if (accBounds === null) {
      continue;
    }
    const minX: number = accBounds.min[0];
    const minY: number = accBounds.min[1];
    const minZ: number = accBounds.min[2];
    const maxX: number = accBounds.max[0];
    const maxY: number = accBounds.max[1];
    const maxZ: number = accBounds.max[2];

    // 8 个角点
    const corners: Point3[] = [
      { x: minX, y: minY, z: minZ } as Point3,
      { x: maxX, y: minY, z: minZ } as Point3,
      { x: minX, y: maxY, z: minZ } as Point3,
      { x: maxX, y: maxY, z: minZ } as Point3,
      { x: minX, y: minY, z: maxZ } as Point3,
      { x: maxX, y: minY, z: maxZ } as Point3,
      { x: minX, y: maxY, z: maxZ } as Point3,
      { x: maxX, y: maxY, z: maxZ } as Point3
    ];

    const instances: number[] | undefined = meshInstances.get(mp.meshIndex);
    if (instances === undefined || instances.length === 0) {
      for (let k: number = 0; k < corners.length; k++) {
        const c: Point3 = corners[k];
        if (aggMinX === null || c.x < aggMinX) { aggMinX = c.x; }
        if (aggMinY === null || c.y < aggMinY) { aggMinY = c.y; }
        if (aggMinZ === null || c.z < aggMinZ) { aggMinZ = c.z; }
        if (aggMaxX === null || c.x > aggMaxX) { aggMaxX = c.x; }
        if (aggMaxY === null || c.y > aggMaxY) { aggMaxY = c.y; }
        if (aggMaxZ === null || c.z > aggMaxZ) { aggMaxZ = c.z; }
      }
      continue;
    }
    for (let j: number = 0; j < instances.length; j++) {
      const nodeIdx: number = instances[j];
      const world: Mat4 | undefined = worldMatrices.get(nodeIdx);
      if (world === undefined || !isMatrixFinite(world)) {
        continue;
      }
      for (let k: number = 0; k < corners.length; k++) {
        const c: Point3 = corners[k];
        const tc: Point3 = transformPoint(world, c.x, c.y, c.z);
        if (!Number.isFinite(tc.x) || !Number.isFinite(tc.y) || !Number.isFinite(tc.z)) {
          continue;
        }
        if (aggMinX === null || tc.x < aggMinX) { aggMinX = tc.x; }
        if (aggMinY === null || tc.y < aggMinY) { aggMinY = tc.y; }
        if (aggMinZ === null || tc.z < aggMinZ) { aggMinZ = tc.z; }
        if (aggMaxX === null || tc.x > aggMaxX) { aggMaxX = tc.x; }
        if (aggMaxY === null || tc.y > aggMaxY) { aggMaxY = tc.y; }
        if (aggMaxZ === null || tc.z > aggMaxZ) { aggMaxZ = tc.z; }
      }
    }
  }

  if (aggMinX === null || aggMinY === null || aggMinZ === null
    || aggMaxX === null || aggMaxY === null || aggMaxZ === null) {
    const empty: PositionBoundsResult = { min: null, max: null } as PositionBoundsResult;
    return empty;
  }

  const result: PositionBoundsResult = {
    min: [aggMinX, aggMinY, aggMinZ],
    max: [aggMaxX, aggMaxY, aggMaxZ]
  } as PositionBoundsResult;
  return result;
}
