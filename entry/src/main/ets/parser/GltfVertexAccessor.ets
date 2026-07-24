/**
 * GltfVertexAccessor glTF 顶点数据访问器
 *
 * T-3D.6F-A: 从 GLB BIN chunk 读取指定 accessor 的顶点数据。
 *
 * 职责:
 * - 解析 GLB 结构(JSON chunk + BIN chunk)
 * - 按 accessor 读取 POSITION(VEC3 FLOAT)
 * - 按 accessor 读取 JOINTS_0(VEC4 UNSIGNED_BYTE/SHORT/INT)
 * - 按 accessor 读取 WEIGHTS_0(VEC4 FLOAT/BYTE/SHORT)
 * - 按 indices 读取三角形索引
 * - 构建 PrimitiveVertexData(单 primitive 的完整顶点数据)
 *
 * 不依赖 ArkUI/ArkGraphics3D,纯逻辑可单元测试。
 *
 * 参考:glTF 2.0 规范
 * - accessor.componentType: 5120(BYTE)/5121(UBYTE)/5122(SHORT)/5123(USHORT)/
 *   5125(UINT)/5126(FLOAT)
 * - accessor.type: SCALAR/VEC2/VEC3/VEC4/MAT2/MAT3/MAT4
 * - accessor.bufferView: 指向 bufferView
 * - bufferView.buffer: 指向 buffer(GLB 中 buffer 0 = BIN chunk)
 * - bufferView.byteStride: 交错数据步长(未设置时由 type 推断)
 */

import { Logger } from '../utils/Logger';
import { util } from '@kit.ArkTS';

const LOG_TAG: string = 'GltfVertexAccessor';

/**
 * glTF componentType 枚举。
 */
export enum GltfComponentType {
  Byte = 5120,
  UnsignedByte = 5121,
  Short = 5122,
  UnsignedShort = 5123,
  UnsignedInt = 5125,
  Float = 5126
}

/**
 * 单个 primitive 的完整顶点数据。
 */
export interface PrimitiveVertexData {
  /** POSITION 顶点坐标(本地空间,未应用 node transform) */
  positions: Float32Array;
  /** 顶点数 */
  vertexCount: number;
  /** JOINTS_0(每个顶点 4 个 joint 索引,指向 skin.joints 数组下标) */
  joints: Uint32Array | null;
  /** WEIGHTS_0(每个顶点 4 个权重) */
  weights: Float32Array | null;
  /** 三角形索引(每 3 个一组,指向顶点下标) */
  indices: Uint32Array | null;
  /** 三角形数量 */
  triangleCount: number;
  /** 是否有 Skin 蒙皮数据 */
  hasSkinData: boolean;
}

/**
 * GLB 解析结果。
 */
export interface GlbParsedData {
  /** glTF JSON 对象 */
  json: Record<string, Object>;
  /** BIN chunk 数据 */
  binChunk: ArrayBuffer | null;
  /** 是否解析成功 */
  valid: boolean;
  /** 错误信息 */
  errorMessage: string;
}

/**
 * 解析 GLB 文件为 JSON + BIN chunk。
 *
 * @param buffer GLB 文件 ArrayBuffer
 * @returns 解析结果
 */
export function parseGlb(buffer: ArrayBuffer): GlbParsedData {
  const result: GlbParsedData = {
    json: {},
    binChunk: null,
    valid: false,
    errorMessage: ''
  };
  if (buffer.byteLength < 12) {
    result.errorMessage = 'GLB too small';
    return result;
  }
  const view: DataView = new DataView(buffer);
  // GLB header: magic(4) + version(4) + length(4)
  const magic: number = view.getUint32(0, true);
  if (magic !== 0x46546c67) { // 'glTF'
    result.errorMessage = 'invalid magic';
    return result;
  }
  const version: number = view.getUint32(4, true);
  if (version !== 2) {
    result.errorMessage = 'unsupported version: ' + version;
    return result;
  }
  // 遍历 chunks
  let offset: number = 12;
  let jsonText: string = '';
  while (offset + 8 <= buffer.byteLength) {
    const chunkLength: number = view.getUint32(offset, true);
    const chunkType: number = view.getUint32(offset + 4, true);
    offset += 8;
    if (offset + chunkLength > buffer.byteLength) {
      result.errorMessage = 'chunk out of bounds';
      return result;
    }
    if (chunkType === 0x4e4f534a) { // 'JSON'
      const bytes: Uint8Array = new Uint8Array(buffer, offset, chunkLength);
      jsonText = decodeUtf8(bytes);
    } else if (chunkType === 0x004e4942) { // 'BIN\0'
      result.binChunk = buffer.slice(offset, offset + chunkLength);
    }
    offset += chunkLength;
    // 4 字节对齐 padding
    while (offset < buffer.byteLength && (offset % 4) !== 0) {
      offset++;
    }
  }
  if (jsonText.length === 0) {
    result.errorMessage = 'no JSON chunk';
    return result;
  }
  try {
    result.json = JSON.parse(jsonText) as Record<string, Object>;
    result.valid = true;
  } catch (e) {
    result.errorMessage = 'JSON parse failed: ' + (e as Error)?.message;
  }
  return result;
}

/**
 * UTF-8 解码(ArkTS 兼容)。
 */
function decodeUtf8(bytes: Uint8Array): string {
  try {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
  } catch (e) {
    // 回退:逐字节解码 ASCII
    let s: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      s += String.fromCharCode(bytes[i]);
    }
    return s;
  }
}

/**
 * 读取 accessor 数据为 Float32Array。
 *
 * 仅支持 FLOAT(5126) 类型,用于 POSITION/WEIGHTS。
 *
 * @param parsedData GLB 解析数据
 * @param accessorIndex accessor 索引
 * @returns Float32Array 或 null
 */
export function readAccessorAsFloat32(
  parsedData: GlbParsedData,
  accessorIndex: number
): Float32Array | null {
  const accessors: Object[] | undefined = parsedData.json['accessors'] as Object[] | undefined;
  if (accessors === undefined || accessorIndex < 0 || accessorIndex >= accessors.length) {
    return null;
  }
  const accessor: Record<string, Object> = accessors[accessorIndex] as Record<string, Object>;
  const componentType: number = accessor['componentType'] as number;
  const type: string = accessor['type'] as string;
  const count: number = accessor['count'] as number;
  if (componentType !== GltfComponentType.Float) {
    // 仅支持 FLOAT
    return null;
  }
  const componentsPerElement: number = getComponentsCount(type);
  if (componentsPerElement <= 0) {
    return null;
  }
  const rawBytes: Uint8Array | null = readAccessorRawBytes(parsedData, accessor);
  if (rawBytes === null) {
    return null;
  }
  // 拷贝到独立 ArrayBuffer 避免 byteOffset/byteLength 对齐问题
  const sliced: Uint8Array = rawBytes.slice();
  const copyBuffer: ArrayBuffer = sliced.buffer.slice(sliced.byteOffset, sliced.byteOffset + sliced.byteLength);
  const result: Float32Array = new Float32Array(count * componentsPerElement);
  const srcView: Float32Array = new Float32Array(copyBuffer);
  const copyLen: number = Math.min(srcView.length, result.length);
  for (let i: number = 0; i < copyLen; i++) {
    result[i] = srcView[i];
  }
  return result;
}

/**
 * 读取 accessor 数据为 Uint32Array。
 *
 * 支持 UNSIGNED_BYTE/UNSIGNED_SHORT/UNSIGNED_INT,用于 JOINTS/indices。
 *
 * @param parsedData GLB 解析数据
 * @param accessorIndex accessor 索引
 * @returns Uint32Array 或 null
 */
export function readAccessorAsUint32(
  parsedData: GlbParsedData,
  accessorIndex: number
): Uint32Array | null {
  const accessors: Object[] | undefined = parsedData.json['accessors'] as Object[] | undefined;
  if (accessors === undefined || accessorIndex < 0 || accessorIndex >= accessors.length) {
    return null;
  }
  const accessor: Record<string, Object> = accessors[accessorIndex] as Record<string, Object>;
  const componentType: number = accessor['componentType'] as number;
  const type: string = accessor['type'] as string;
  const count: number = accessor['count'] as number;
  const componentsPerElement: number = getComponentsCount(type);
  if (componentsPerElement <= 0) {
    return null;
  }
  const rawBytes: Uint8Array | null = readAccessorRawBytes(parsedData, accessor);
  if (rawBytes === null) {
    return null;
  }
  const totalComponents: number = count * componentsPerElement;
  const result: Uint32Array = new Uint32Array(totalComponents);
  const view: DataView = new DataView(rawBytes.buffer, rawBytes.byteOffset, rawBytes.byteLength);
  let idx: number = 0;
  for (let i: number = 0; i < totalComponents && idx < rawBytes.byteLength; i++) {
    if (componentType === GltfComponentType.UnsignedByte) {
      result[i] = view.getUint8(idx);
      idx += 1;
    } else if (componentType === GltfComponentType.UnsignedShort) {
      result[i] = view.getUint16(idx, true);
      idx += 2;
    } else if (componentType === GltfComponentType.UnsignedInt) {
      result[i] = view.getUint32(idx, true);
      idx += 4;
    } else {
      return null;
    }
  }
  return result;
}

/**
 * 读取 WEIGHTS_0 为 Float32Array,支持归一化。
 *
 * 对于 BYTE/SHORT 类型,需归一化到 0.0~1.0。
 *
 * @param parsedData GLB 解析数据
 * @param accessorIndex accessor 索引
 * @returns Float32Array(每顶点 4 权重)或 null
 */
export function readWeightsAsFloat32(
  parsedData: GlbParsedData,
  accessorIndex: number
): Float32Array | null {
  const accessors: Object[] | undefined = parsedData.json['accessors'] as Object[] | undefined;
  if (accessors === undefined || accessorIndex < 0 || accessorIndex >= accessors.length) {
    return null;
  }
  const accessor: Record<string, Object> = accessors[accessorIndex] as Record<string, Object>;
  const componentType: number = accessor['componentType'] as number;
  const type: string = accessor['type'] as string;
  const count: number = accessor['count'] as number;
  if (type !== 'VEC4') {
    return null;
  }
  const rawBytes: Uint8Array | null = readAccessorRawBytes(parsedData, accessor);
  if (rawBytes === null) {
    return null;
  }
  const result: Float32Array = new Float32Array(count * 4);
  const view: DataView = new DataView(rawBytes.buffer, rawBytes.byteOffset, rawBytes.byteLength);
  let idx: number = 0;
  for (let i: number = 0; i < count * 4 && idx < rawBytes.byteLength; i++) {
    if (componentType === GltfComponentType.Float) {
      result[i] = view.getFloat32(idx, true);
      idx += 4;
    } else if (componentType === GltfComponentType.UnsignedByte) {
      result[i] = view.getUint8(idx) / 255.0;
      idx += 1;
    } else if (componentType === GltfComponentType.UnsignedShort) {
      result[i] = view.getUint16(idx, true) / 65535.0;
      idx += 2;
    } else if (componentType === GltfComponentType.Byte) {
      result[i] = Math.max(view.getInt8(idx), 0) / 127.0;
      idx += 1;
    } else if (componentType === GltfComponentType.Short) {
      result[i] = Math.max(view.getInt16(idx, true), 0) / 32767.0;
      idx += 2;
    } else {
      return null;
    }
  }
  return result;
}

/**
 * 读取 accessor 原始字节(应用 bufferView.byteOffset + accessor.byteOffset + byteStride)。
 *
 * @param parsedData GLB 解析数据
 * @param accessor accessor 对象
 * @returns Uint8Array(可能带 byteStride 交错,调用方需按 stride 解包)或 null
 */
function readAccessorRawBytes(
  parsedData: GlbParsedData,
  accessor: Record<string, Object>
): Uint8Array | null {
  const bufferViewIndex: number | undefined = accessor['bufferView'] as number | undefined;
  if (bufferViewIndex === undefined) {
    return null;
  }
  const bufferViews: Object[] | undefined = parsedData.json['bufferViews'] as Object[] | undefined;
  if (bufferViews === undefined || bufferViewIndex < 0 || bufferViewIndex >= bufferViews.length) {
    return null;
  }
  const bufferView: Record<string, Object> = bufferViews[bufferViewIndex] as Record<string, Object>;
  const bufferIndex: number = bufferView['buffer'] as number;
  const bvByteOffset: number = (bufferView['byteOffset'] as number) ?? 0;
  const bvByteLength: number = bufferView['byteLength'] as number;
  const byteStride: number | undefined = bufferView['byteStride'] as number | undefined;
  const accessorByteOffset: number = (accessor['byteOffset'] as number) ?? 0;
  const count: number = accessor['count'] as number;
  const componentType: number = accessor['componentType'] as number;
  const type: string = accessor['type'] as string;
  const componentSize: number = getComponentSize(componentType);
  const componentsPerElement: number = getComponentsCount(type);
  const elementSize: number = componentSize * componentsPerElement;
  if (componentSize <= 0 || componentsPerElement <= 0) {
    return null;
  }
  // 获取 buffer 数据(GLB 中 buffer 0 = BIN chunk)
  const buffers: Object[] | undefined = parsedData.json['buffers'] as Object[] | undefined;
  if (buffers === undefined || bufferIndex >= buffers.length) {
    return null;
  }
  let binData: ArrayBuffer | null = null;
  if (bufferIndex === 0) {
    binData = parsedData.binChunk;
  } else {
    // 外部 buffer(本任务不支持)
    return null;
  }
  if (binData === null) {
    return null;
  }
  const startOffset: number = bvByteOffset + accessorByteOffset;
  if (startOffset + elementSize * count > binData.byteLength) {
    Logger.warn(LOG_TAG, 'accessor out of bounds: start=' + startOffset
      + ', need=' + (elementSize * count) + ', binLen=' + binData.byteLength);
    return null;
  }
  // 无 byteStride:紧凑布局,直接切片
  if (byteStride === undefined || byteStride === 0 || byteStride === elementSize) {
    return new Uint8Array(binData, startOffset, elementSize * count);
  }
  // 有 byteStride:交错布局,需解包
  const totalBytes: number = elementSize * count;
  const result: Uint8Array = new Uint8Array(totalBytes);
  for (let i: number = 0; i < count; i++) {
    const srcStart: number = startOffset + i * byteStride;
    for (let j: number = 0; j < elementSize; j++) {
      result[i * elementSize + j] = new DataView(binData).getUint8(srcStart + j);
    }
  }
  return result;
}

/**
 * 获取 componentType 的字节大小。
 */
function getComponentSize(componentType: number): number {
  switch (componentType) {
    case GltfComponentType.Byte: return 1;
    case GltfComponentType.UnsignedByte: return 1;
    case GltfComponentType.Short: return 2;
    case GltfComponentType.UnsignedShort: return 2;
    case GltfComponentType.UnsignedInt: return 4;
    case GltfComponentType.Float: return 4;
    default: return 0;
  }
}

/**
 * 获取 accessor.type 的分量数。
 */
export function getComponentsCount(type: string): number {
  switch (type) {
    case 'SCALAR': return 1;
    case 'VEC2': return 2;
    case 'VEC3': return 3;
    case 'VEC4': return 4;
    case 'MAT2': return 4;
    case 'MAT3': return 9;
    case 'MAT4': return 16;
    default: return 0;
  }
}

/**
 * 构建指定 primitive 的完整顶点数据。
 *
 * @param parsedData GLB 解析数据
 * @param meshIndex mesh 索引
 * @param primitiveIndex primitive 索引
 * @returns 顶点数据或 null
 */
export function buildPrimitiveVertexData(
  parsedData: GlbParsedData,
  meshIndex: number,
  primitiveIndex: number
): PrimitiveVertexData | null {
  const meshes: Object[] | undefined = parsedData.json['meshes'] as Object[] | undefined;
  if (meshes === undefined || meshIndex < 0 || meshIndex >= meshes.length) {
    return null;
  }
  const mesh: Record<string, Object> = meshes[meshIndex] as Record<string, Object>;
  const primitives: Object[] | undefined = mesh['primitives'] as Object[] | undefined;
  if (primitives === undefined || primitiveIndex < 0 || primitiveIndex >= primitives.length) {
    return null;
  }
  const primitive: Record<string, Object> = primitives[primitiveIndex] as Record<string, Object>;
  const attributes: Record<string, Object> = primitive['attributes'] as Record<string, Object>;
  if (attributes === undefined) {
    return null;
  }
  // POSITION
  const positionAccessor: number | undefined = attributes['POSITION'] as number | undefined;
  if (positionAccessor === undefined) {
    return null;
  }
  const positions: Float32Array | null = readAccessorAsFloat32(parsedData, positionAccessor);
  if (positions === null) {
    return null;
  }
  const vertexCount: number = positions.length / 3;
  // JOINTS_0
  const jointsAccessor: number | undefined = attributes['JOINTS_0'] as number | undefined;
  let joints: Uint32Array | null = null;
  if (jointsAccessor !== undefined) {
    joints = readAccessorAsUint32(parsedData, jointsAccessor);
  }
  // WEIGHTS_0
  const weightsAccessor: number | undefined = attributes['WEIGHTS_0'] as number | undefined;
  let weights: Float32Array | null = null;
  if (weightsAccessor !== undefined) {
    weights = readWeightsAsFloat32(parsedData, weightsAccessor);
  }
  // indices
  const indicesAccessor: number | undefined = primitive['indices'] as number | undefined;
  let indices: Uint32Array | null = null;
  let triangleCount: number = 0;
  if (indicesAccessor !== undefined) {
    indices = readAccessorAsUint32(parsedData, indicesAccessor);
    if (indices !== null) {
      triangleCount = Math.floor(indices.length / 3);
    }
  } else {
    // 无 indices:按顶点顺序生成(假设 TRIANGLES 模式)
    triangleCount = Math.floor(vertexCount / 3);
  }
  const hasSkinData: boolean = joints !== null && weights !== null
    && joints.length === vertexCount * 4 && weights.length === vertexCount * 4;
  return {
    positions: positions,
    vertexCount: vertexCount,
    joints: joints,
    weights: weights,
    indices: indices,
    triangleCount: triangleCount,
    hasSkinData: hasSkinData
  };
}

/**
 * 收集所有 mesh primitive 的顶点数据。
 *
 * @param parsedData GLB 解析数据
 * @returns primitive 顶点数据数组
 */
export function collectAllPrimitiveVertexData(parsedData: GlbParsedData): PrimitiveVertexData[] {
  const result: PrimitiveVertexData[] = [];
  const meshes: Object[] | undefined = parsedData.json['meshes'] as Object[] | undefined;
  if (meshes === undefined) {
    return result;
  }
  for (let m: number = 0; m < meshes.length; m++) {
    const mesh: Record<string, Object> = meshes[m] as Record<string, Object>;
    const primitives: Object[] | undefined = mesh['primitives'] as Object[] | undefined;
    if (primitives === undefined) {
      continue;
    }
    for (let p: number = 0; p < primitives.length; p++) {
      const data: PrimitiveVertexData | null = buildPrimitiveVertexData(parsedData, m, p);
      if (data !== null) {
        result.push(data);
      }
    }
  }
  return result;
}

/**
 * 构建 skin.joints 数组(nodeIndex 列表)。
 *
 * @param parsedData GLB 解析数据
 * @param skinIndex skin 索引(默认 0)
 * @returns joint nodeIndex 数组或空数组
 */
export function buildSkinJointNodes(
  parsedData: GlbParsedData,
  skinIndex: number = 0
): number[] {
  const skins: Object[] | undefined = parsedData.json['skins'] as Object[] | undefined;
  if (skins === undefined || skinIndex < 0 || skinIndex >= skins.length) {
    return [];
  }
  const skin: Record<string, Object> = skins[skinIndex] as Record<string, Object>;
  const joints: number[] | undefined = skin['joints'] as number[] | undefined;
  if (joints === undefined) {
    return [];
  }
  return joints;
}

/**
 * 获取 node 名称。
 *
 * @param parsedData GLB 解析数据
 * @param nodeIndex node 索引
 * @returns 名称或空字符串
 */
export function getNodeName(
  parsedData: GlbParsedData,
  nodeIndex: number
): string {
  const nodes: Object[] | undefined = parsedData.json['nodes'] as Object[] | undefined;
  if (nodes === undefined || nodeIndex < 0 || nodeIndex >= nodes.length) {
    return '';
  }
  const node: Record<string, Object> = nodes[nodeIndex] as Record<string, Object>;
  const name: string | undefined = node['name'] as string | undefined;
  return name !== undefined ? name : '';
}
