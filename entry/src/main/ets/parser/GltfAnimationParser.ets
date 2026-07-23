/**
 * GltfAnimationParser GLB 动画与节点解析器
 *
 * T-3D.6A: 扩展 GltfValidator,从 GLB JSON 提取动画和骨骼节点信息。
 *
 * 职责:
 * - 解析 GLB 2.0 文件头和 chunk 结构(复用 GltfValidator 的格式验证)
 * - 提取 nodes[].name 列表(用于骨骼识别)
 * - 提取 animations[]:name/channels/samplers,计算每个 Clip 的时长
 * - 检测动画通道类型(translation/rotation/scale/weights)
 * - 检测是否包含骨骼蒙皮(skins 数组)
 * - 不读取文件(由调用方传入 ArrayBuffer)
 * - 不依赖 ArkUI / 网络 / 数据库
 *
 * 与 GltfValidator 的关系:
 * - GltfValidator 已完成 GLB 格式验证和摘要信息提取
 * - 本类只负责动画和节点详情提取,不做格式验证
 * - 调用方应先调用 GltfValidator.validate 确认格式有效,再调用本类
 */

import { util } from '@kit.ArkTS';
import { AnimationClipInfo } from '../models/character3d/Character3DActionAsset';

const GLB_MAGIC: number = 0x46546C67;       // "glTF"
const GLB_VERSION: number = 2;               // GLB 2.0
const CHUNK_TYPE_JSON: number = 0x4E4F534A;  // "JSON"
const CHUNK_TYPE_BIN: number = 0x004E4942;   // "BIN\0"
const GLB_HEADER_SIZE: number = 12;
const CHUNK_HEADER_SIZE: number = 8;

/**
 * 动画解析结果。
 */
export interface GltfAnimationParseResult {
  /** 是否解析成功 */
  valid: boolean;
  /** 错误信息(失败时) */
  errorMessage: string;
  /** 所有节点名列表(可能为空数组) */
  nodeNames: string[];
  /** 动画 Clip 列表(可能为空数组) */
  clips: AnimationClipInfo[];
  /** 是否包含骨骼蒙皮 */
  hasSkins: boolean;
  /** 皮肤数量 */
  skinCount: number;
  /** 节点数量 */
  nodeCount: number;
  /** 动画数量 */
  animationCount: number;
}

/**
 * 创建空结果。
 */
function createEmptyResult(): GltfAnimationParseResult {
  return {
    valid: false,
    errorMessage: '',
    nodeNames: [],
    clips: [],
    hasSkins: false,
    skinCount: 0,
    nodeCount: 0,
    animationCount: 0
  };
}

/**
 * 创建失败结果。
 */
function createFailure(message: string): GltfAnimationParseResult {
  const result: GltfAnimationParseResult = createEmptyResult();
  result.errorMessage = message;
  return result;
}

/**
 * GLB 动画与节点解析器。
 */
export class GltfAnimationParser {
  /**
   * 解析 GLB 二进制,提取动画和节点信息。
   *
   * 本方法不做完整格式验证(由 GltfValidator 负责),只解析必要字段。
   * 如果 GLB 格式明显错误(非 GLB 2.0/无 JSON chunk),返回失败。
   *
   * @param buffer GLB 文件二进制内容
   * @returns 解析结果
   */
  static parse(buffer: ArrayBuffer): GltfAnimationParseResult {
    if (buffer === null || buffer === undefined) {
      return createFailure('buffer 为 null');
    }
    if (buffer.byteLength < GLB_HEADER_SIZE + CHUNK_HEADER_SIZE) {
      return createFailure('文件过小');
    }

    const view: DataView = new DataView(buffer);

    // 1. 验证 Header
    const magic: number = view.getUint32(0, true);
    if (magic !== GLB_MAGIC) {
      return createFailure('GLB magic 不匹配');
    }
    const version: number = view.getUint32(4, true);
    if (version !== GLB_VERSION) {
      return createFailure('不支持的 glTF 版本: ' + version);
    }

    // 2. 解析 JSON chunk
    let jsonText: string = '';
    let jsonFound: boolean = false;
    let offset: number = GLB_HEADER_SIZE;
    let chunkIndex: number = 0;
    while (offset + CHUNK_HEADER_SIZE <= buffer.byteLength) {
      const chunkLength: number = view.getUint32(offset, true);
      const chunkType: number = view.getUint32(offset + 4, true);
      const chunkDataStart: number = offset + CHUNK_HEADER_SIZE;
      if (chunkLength > buffer.byteLength - chunkDataStart) {
        break;
      }
      const chunkDataEnd: number = chunkDataStart + chunkLength;
      if (chunkType === CHUNK_TYPE_JSON && chunkIndex === 0) {
        try {
          jsonText = GltfAnimationParser.decodeUtf8(buffer, chunkDataStart, chunkLength);
          jsonFound = true;
        } catch (e) {
          return createFailure('JSON chunk 解码失败: ' + (e as Error)?.message);
        }
        break;
      } else if (chunkType === CHUNK_TYPE_BIN) {
        // BIN chunk 不需要解析
      }
      offset = chunkDataEnd;
      chunkIndex++;
      while (offset < buffer.byteLength && (offset % 4) !== 0) {
        offset++;
      }
    }

    if (!jsonFound) {
      return createFailure('缺少 JSON chunk');
    }

    // 3. 解析 GLTF JSON
    let gltfJson: Record<string, Object> | null = null;
    try {
      gltfJson = JSON.parse(jsonText) as Record<string, Object>;
    } catch (e) {
      return createFailure('GLTF JSON 解析失败: ' + (e as Error)?.message);
    }
    if (gltfJson === null) {
      return createFailure('GLTF JSON 解析结果为 null');
    }

    // 4. 提取节点名列表
    const nodeNames: string[] = GltfAnimationParser.extractNodeNames(gltfJson);

    // 5. 提取动画 Clip 列表
    const clips: AnimationClipInfo[] = GltfAnimationParser.extractClips(gltfJson);

    // 6. 提取皮肤数量
    const skinCount: number = GltfAnimationParser.getArrayLength(gltfJson, 'skins');

    const result: GltfAnimationParseResult = createEmptyResult();
    result.valid = true;
    result.nodeNames = nodeNames;
    result.clips = clips;
    result.hasSkins = skinCount > 0;
    result.skinCount = skinCount;
    result.nodeCount = GltfAnimationParser.getArrayLength(gltfJson, 'nodes');
    result.animationCount = clips.length;
    return result;
  }

  /**
   * 提取所有节点的 name 字段。
   * 节点没有 name 时跳过(glTF 规范允许 node 不命名)。
   */
  private static extractNodeNames(json: Record<string, Object>): string[] {
    const nodesObj: Object | undefined = json['nodes'];
    if (nodesObj === undefined || nodesObj === null) {
      return [];
    }
    if (!(nodesObj instanceof Array)) {
      return [];
    }
    const nodes: Object[] = nodesObj as Object[];
    const names: string[] = [];
    for (let i: number = 0; i < nodes.length; i++) {
      const nodeObj: Object | undefined = nodes[i];
      if (nodeObj === undefined || nodeObj === null) {
        continue;
      }
      const node: Record<string, Object> = nodeObj as Record<string, Object>;
      const nameObj: Object | undefined = node['name'];
      if (nameObj === undefined || nameObj === null) {
        continue;
      }
      const name: string = String(nameObj);
      if (name.length > 0) {
        names.push(name);
      }
    }
    return names;
  }

  /**
   * 提取所有动画 Clip 信息。
   *
   * glTF 动画结构:
   * - animations[i].name:Clip 名称(可选)
   * - animations[i].channels[]:动画通道,每个通道引用一个 sampler 和 target node
   * - animations[i].samplers[]:采样器,引用 input(accessor)和 output(accessor)
   * - accessors[input].max[0]:最大输入时间(秒),即动画时长
   *
   * 时长计算:取该动画所有 sampler 的 input accessor 的 max[0] 的最大值,转为毫秒。
   */
  private static extractClips(json: Record<string, Object>): AnimationClipInfo[] {
    const animationsObj: Object | undefined = json['animations'];
    if (animationsObj === undefined || animationsObj === null) {
      return [];
    }
    if (!(animationsObj instanceof Array)) {
      return [];
    }
    const animations: Object[] = animationsObj as Object[];
    const accessorsObj: Object | undefined = json['accessors'];
    const accessors: Object[] | null =
      (accessorsObj instanceof Array) ? (accessorsObj as Object[]) : null;

    const clips: AnimationClipInfo[] = [];
    for (let i: number = 0; i < animations.length; i++) {
      const animObj: Object | undefined = animations[i];
      if (animObj === undefined || animObj === null) {
        continue;
      }
      const anim: Record<string, Object> = animObj as Record<string, Object>;

      // Clip 名称
      const nameObj: Object | undefined = anim['name'];
      const name: string = (nameObj !== undefined && nameObj !== null)
        ? String(nameObj) : 'animation_' + i;

      // 解析 channels
      const channels: Object[] = GltfAnimationParser.toArray(anim['channels']);
      let channelCount: number = channels.length;
      let hasTranslation: boolean = false;
      let hasRotation: boolean = false;
      let hasScale: boolean = false;
      let hasMorphWeights: boolean = false;

      // 解析 samplers,计算时长
      const samplers: Object[] = GltfAnimationParser.toArray(anim['samplers']);
      let maxDurationSec: number = 0.0;
      for (let j: number = 0; j < samplers.length; j++) {
        const samplerObj: Object | undefined = samplers[j];
        if (samplerObj === undefined || samplerObj === null) {
          continue;
        }
        const sampler: Record<string, Object> = samplerObj as Record<string, Object>;
        const inputIdxObj: Object | undefined = sampler['input'];
        if (inputIdxObj === undefined || inputIdxObj === null) {
          continue;
        }
        const inputIdx: number = Number(inputIdxObj);
        if (accessors === null || inputIdx < 0 || inputIdx >= accessors.length) {
          continue;
        }
        const accessorObj: Object | undefined = accessors[inputIdx];
        if (accessorObj === undefined || accessorObj === null) {
          continue;
        }
        const accessor: Record<string, Object> = accessorObj as Record<string, Object>;
        const maxObj: Object | undefined = accessor['max'];
        const maxArr: number[] | null = GltfAnimationParser.toNumberArray(maxObj);
        if (maxArr !== null && maxArr.length > 0) {
          const maxVal: number = maxArr[0];
          if (!isNaN(maxVal) && isFinite(maxVal) && maxVal > maxDurationSec) {
            maxDurationSec = maxVal;
          }
        }
      }

      // 解析通道类型
      for (let j: number = 0; j < channels.length; j++) {
        const channelObj: Object | undefined = channels[j];
        if (channelObj === undefined || channelObj === null) {
          continue;
        }
        const channel: Record<string, Object> = channelObj as Record<string, Object>;
        const targetObj: Object | undefined = channel['target'];
        if (targetObj === undefined || targetObj === null) {
          continue;
        }
        const target: Record<string, Object> = targetObj as Record<string, Object>;
        const pathObj: Object | undefined = target['path'];
        if (pathObj === undefined || pathObj === null) {
          continue;
        }
        const path: string = String(pathObj);
        if (path === 'translation') {
          hasTranslation = true;
        } else if (path === 'rotation') {
          hasRotation = true;
        } else if (path === 'scale') {
          hasScale = true;
        } else if (path === 'weights') {
          hasMorphWeights = true;
        }
      }

      const durationMs: number = Math.round(maxDurationSec * 1000.0);
      clips.push({
        index: i,
        name: name,
        durationMs: durationMs,
        channelCount: channelCount,
        hasTranslation: hasTranslation,
        hasRotation: hasRotation,
        hasScale: hasScale,
        hasMorphTargetWeights: hasMorphWeights
      } as AnimationClipInfo);
    }
    return clips;
  }

  /**
   * 解码 UTF-8 字节为字符串。
   */
  private static decodeUtf8(buffer: ArrayBuffer, start: number, length: number): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buffer, start, length));
  }

  /**
   * 安全获取 GLTF JSON 中的数组字段长度。
   */
  private static getArrayLength(json: Record<string, Object>, key: string): number {
    const value: Object | undefined = json[key];
    if (value === undefined || value === null) {
      return 0;
    }
    if (value instanceof Array) {
      return value.length;
    }
    return 0;
  }

  /**
   * 将 Object 安全转为 Array。
   */
  private static toArray(obj: Object | undefined): Object[] {
    if (obj === undefined || obj === null) {
      return [];
    }
    if (obj instanceof Array) {
      return obj as Object[];
    }
    return [];
  }

  /**
   * 将 Object 安全转为 number[]。
   */
  private static toNumberArray(obj: Object | undefined): number[] | null {
    if (obj === undefined || obj === null) {
      return null;
    }
    if (!(obj instanceof Array)) {
      return null;
    }
    const arr: Object[] = obj as Object[];
    const result: number[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      const num: number = Number(item);
      if (!isNaN(num)) {
        result.push(num);
      }
    }
    return result;
  }
}
