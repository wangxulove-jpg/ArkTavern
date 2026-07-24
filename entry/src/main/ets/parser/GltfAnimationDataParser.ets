/**
 * GltfAnimationDataParser GLB 动画关键帧数据解析器
 *
 * T-4.2E: 从 GLB BIN chunk 解析动画的实际关键帧数据。
 *
 * 与 GltfAnimationParser 的区别:
 * - GltfAnimationParser: 只解析元数据(名称、时长、通道数)
 * - GltfAnimationDataParser: 解析实际关键帧(time/rotation/translation/scale)
 *
 * 复用:
 * - parseGlb(JSON + BIN chunk 解析)
 * - readAccessorAsFloat32(FLOAT accessor 读取,支持 byteOffset/byteStride)
 * - GltfComponentType 枚举
 *
 * 支持:
 * - input accessor: SCALAR FLOAT(时间数组)
 * - output accessor: VEC4 FLOAT(rotation 四元数)
 * - output accessor: VEC3 FLOAT(translation/scale 向量)
 * - interpolation: LINEAR, STEP
 * - CUBICSPLINE: 返回 UnsupportedInterpolation 错误(本轮不实现)
 *
 * 源骨骼映射:
 * - 动作包节点名直接使用 HumanoidBone 标准名(如 "RightUpperArm")
 * - 通过名称直接匹配 HumanoidBone 枚举,无需 HumanoidBoneMapper
 * - 不匹配的节点跳过并记录警告
 */

import {
  parseGlb,
  readAccessorAsFloat32,
  GlbParsedData,
  getComponentsCount
} from './GltfVertexAccessor';
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import {
  HumanoidMotionClip,
  HumanoidBoneTrack,
  QuaternionKeyframe,
  Vector3Keyframe,
  QuaternionValue,
  Vector3Value,
  AnimationInterpolation,
  HumanoidRestPose,
  BoneRestTransform,
  identityQuaternionValue,
  zeroVector3Value,
  oneVector3Value,
  createEmptyRestPose
} from '../models/character3d/HumanoidMotionClip';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'GltfAnimDataParser';

/**
 * 动画数据解析结果。
 */
export interface AnimationDataParseResult {
  /** 是否成功 */
  success: boolean;
  /** 错误信息(失败时) */
  errorMessage: string;
  /** 解析出的 Motion Clip(成功时) */
  clip: HumanoidMotionClip | null;
}

/**
 * 解析 GLB 中指定名称的动画,生成 HumanoidMotionClip。
 *
 * @param buffer GLB 文件 ArrayBuffer
 * @param animationName 动画名称(如 "AT_Wave")
 * @param clipId Clip 唯一标识(通常为 actionId)
 * @param loop 是否循环
 * @returns 解析结果
 */
export function parseAnimationByName(
  buffer: ArrayBuffer,
  animationName: string,
  clipId: string,
  loop: boolean
): AnimationDataParseResult {
  // 1. 解析 GLB
  const parsed: GlbParsedData = parseGlb(buffer);
  if (!parsed.valid) {
    return { success: false, errorMessage: 'GLB 解析失败: ' + parsed.errorMessage, clip: null };
  }

  // 2. 查找指定名称的动画
  const animations: Object[] | undefined = parsed.json['animations'] as Object[] | undefined;
  if (animations === undefined || animations.length === 0) {
    return { success: false, errorMessage: 'GLB 无动画数据', clip: null };
  }

  let targetAnim: Record<string, Object> | null = null;
  let targetIndex: number = -1;
  for (let i: number = 0; i < animations.length; i++) {
    const anim: Record<string, Object> = animations[i] as Record<string, Object>;
    const nameObj: Object | undefined = anim['name'];
    const name: string = (nameObj !== undefined && nameObj !== null) ? String(nameObj) : '';
    if (name === animationName) {
      targetAnim = anim;
      targetIndex = i;
      break;
    }
  }

  if (targetAnim === null) {
    const available: string[] = [];
    for (let i: number = 0; i < animations.length; i++) {
      const a: Record<string, Object> = animations[i] as Record<string, Object>;
      const n: Object | undefined = a['name'];
      if (n !== undefined && n !== null) {
        available.push(String(n));
      }
    }
    return {
      success: false,
      errorMessage: '未找到动画: ' + animationName + ', 可用: ' + available.join(', '),
      clip: null
    };
  }

  Logger.info(LOG_TAG, 'parseAnimationByName: found "' + animationName + '" at index ' + targetIndex);

  // 3. 解析动画数据
  return parseAnimationData(parsed, targetAnim, targetIndex, animationName, clipId, loop);
}

/**
 * 解析动画数据为 HumanoidMotionClip。
 *
 * @param parsed GLB 解析数据
 * @param anim 动画 JSON 对象
 * @param animIndex 动画索引
 * @param animName 动画名称
 * @param clipId Clip ID
 * @param loop 是否循环
 * @returns 解析结果
 */
function parseAnimationData(
  parsed: GlbParsedData,
  anim: Record<string, Object>,
  animIndex: number,
  animName: string,
  clipId: string,
  loop: boolean
): AnimationDataParseResult {
  const channels: Object[] | undefined = anim['channels'] as Object[] | undefined;
  const samplers: Object[] | undefined = anim['samplers'] as Object[] | undefined;
  if (channels === undefined || samplers === undefined) {
    return { success: false, errorMessage: '动画缺少 channels/samplers', clip: null };
  }

  const nodes: Object[] | undefined = parsed.json['nodes'] as Object[] | undefined;
  if (nodes === undefined) {
    return { success: false, errorMessage: 'GLB 缺少 nodes', clip: null };
  }

  const warnings: string[] = [];
  const tracks: HumanoidBoneTrack[] = [];
  let durationSeconds: number = 0;
  let rotationTrackCount: number = 0;
  let translationTrackCount: number = 0;

  // 按 node 分组通道(同一 node 可能有 translation/rotation/scale 三个通道)
  // key = nodeIndex, value = { rotation?, translation?, scale? }
  const nodeChannelMap: Map<number, NodeChannelData> = new Map();

  for (let i: number = 0; i < channels.length; i++) {
    const channel: Record<string, Object> = channels[i] as Record<string, Object>;
    const targetObj: Object | undefined = channel['target'];
    if (targetObj === undefined || targetObj === null) {
      continue;
    }
    const target: Record<string, Object> = targetObj as Record<string, Object>;
    const nodeIdxObj: Object | undefined = target['node'];
    const pathObj: Object | undefined = target['path'];
    if (nodeIdxObj === undefined || pathObj === undefined) {
      continue;
    }
    const nodeIdx: number = Number(nodeIdxObj);
    const path: string = String(pathObj);
    const samplerIdx: number = Number(channel['sampler']);

    if (nodeIdx < 0 || nodeIdx >= nodes.length) {
      warnings.push('channel[' + i + '] nodeIdx 越界: ' + nodeIdx);
      continue;
    }
    if (samplerIdx < 0 || samplerIdx >= samplers.length) {
      warnings.push('channel[' + i + '] samplerIdx 越界: ' + samplerIdx);
      continue;
    }

    // 获取节点名
    const node: Record<string, Object> = nodes[nodeIdx] as Record<string, Object>;
    const nodeNameObj: Object | undefined = node['name'];
    const nodeName: string = (nodeNameObj !== undefined && nodeNameObj !== null) ? String(nodeNameObj) : '';

    // 解析 sampler
    const sampler: Record<string, Object> = samplers[samplerIdx] as Record<string, Object>;
    const inputAccessorIdx: number = Number(sampler['input']);
    const outputAccessorIdx: number = Number(sampler['output']);
    const interpStr: string = String(sampler['interpolation'] ?? 'LINEAR');
    const interp: AnimationInterpolation = parseInterpolation(interpStr, warnings, i);

    // 读取 input(时间数组)
    const inputData: Float32Array | null = readAccessorAsFloat32(parsed, inputAccessorIdx);
    if (inputData === null) {
      warnings.push('channel[' + i + '] input accessor 读取失败: ' + inputAccessorIdx);
      continue;
    }
    const times: number[] = [];
    for (let t: number = 0; t < inputData.length; t++) {
      times.push(inputData[t]);
    }
    // 更新时长
    if (times.length > 0 && times[times.length - 1] > durationSeconds) {
      durationSeconds = times[times.length - 1];
    }

    // 读取 output
    const outputData: Float32Array | null = readAccessorAsFloat32(parsed, outputAccessorIdx);
    if (outputData === null) {
      warnings.push('channel[' + i + '] output accessor 读取失败: ' + outputAccessorIdx);
      continue;
    }

    // 按通道类型解析
    let existing: NodeChannelData | undefined = nodeChannelMap.get(nodeIdx);
    if (existing === undefined) {
      existing = {
        nodeName: nodeName,
        nodeIndex: nodeIdx,
        rotationKeys: [],
        translationKeys: [],
        scaleKeys: [],
        rotationInterp: AnimationInterpolation.Linear,
        translationInterp: AnimationInterpolation.Linear,
        scaleInterp: AnimationInterpolation.Linear
      };
      nodeChannelMap.set(nodeIdx, existing);
    }

    if (path === 'rotation') {
      existing.rotationKeys = parseQuaternionKeyframes(times, outputData, interp, warnings, i);
      existing.rotationInterp = interp;
      rotationTrackCount++;
    } else if (path === 'translation') {
      existing.translationKeys = parseVector3Keyframes(times, outputData, interp, warnings, i);
      existing.translationInterp = interp;
      translationTrackCount++;
    } else if (path === 'scale') {
      existing.scaleKeys = parseVector3Keyframes(times, outputData, interp, warnings, i);
      existing.scaleInterp = interp;
    }
    // weights 通道本轮不处理
  }

  // 将 nodeChannelMap 转为 HumanoidBoneTrack(通过节点名映射 HumanoidBone)
  nodeChannelMap.forEach((data: NodeChannelData, nodeIdx: number) => {
    const bone: HumanoidBone | null = mapNodeNameToHumanoidBone(data.nodeName);
    if (bone === null) {
      warnings.push('节点 "' + data.nodeName + '" (index=' + nodeIdx + ') 无法映射到 HumanoidBone,跳过');
      return;
    }
    tracks.push({
      bone: bone,
      sourceNodeIndex: nodeIdx,
      sourceNodeName: data.nodeName,
      rotationKeys: data.rotationKeys,
      translationKeys: data.translationKeys,
      scaleKeys: data.scaleKeys,
      rotationInterpolation: data.rotationInterp,
      translationInterpolation: data.translationInterp
    });
  });

  // 计算源模型身高(从 Hips 到 Head 的 Y 距离,粗略估算)
  const sourceHeight: number = estimateSkeletonHeight(parsed);

  const clip: HumanoidMotionClip = {
    id: clipId,
    name: animName,
    durationSeconds: durationSeconds,
    loop: loop,
    tracks: tracks,
    sourceSkeletonHash: 'actionpack_v1',
    sourceHeight: sourceHeight,
    warnings: warnings
  };

  Logger.info(LOG_TAG, 'MotionClip parsed: name=' + animName
    + ', duration=' + durationSeconds.toFixed(3)
    + ', channels=' + channels.length
    + ', tracks=' + tracks.length
    + ', rotationTracks=' + rotationTrackCount
    + ', translationTracks=' + translationTrackCount
    + ', sourceHeight=' + sourceHeight.toFixed(3)
    + ', warnings=' + warnings.length);

  return { success: true, errorMessage: '', clip: clip };
}

/**
 * 单个节点的通道数据(内部使用)。
 */
interface NodeChannelData {
  nodeName: string;
  nodeIndex: number;
  rotationKeys: QuaternionKeyframe[];
  translationKeys: Vector3Keyframe[];
  scaleKeys: Vector3Keyframe[];
  rotationInterp: AnimationInterpolation;
  translationInterp: AnimationInterpolation;
  scaleInterp: AnimationInterpolation;
}

/**
 * 解析插值类型字符串。
 */
function parseInterpolation(
  str: string,
  warnings: string[],
  channelIndex: number
): AnimationInterpolation {
  if (str === 'LINEAR') {
    return AnimationInterpolation.Linear;
  }
  if (str === 'STEP') {
    return AnimationInterpolation.Step;
  }
  if (str === 'CUBICSPLINE') {
    warnings.push('channel[' + channelIndex + '] 使用 CUBICSPLINE,本轮不支持');
    return AnimationInterpolation.CubicSpline;
  }
  warnings.push('channel[' + channelIndex + '] 未知插值类型: ' + str + ',按 LINEAR 处理');
  return AnimationInterpolation.Linear;
}

/**
 * 解析四元数关键帧数组。
 *
 * output accessor VEC4 FLOAT:每 4 个 float 为一个 quaternion [x, y, z, w]。
 * CUBICSPLINE:每 3 个 VEC4 为一组(in_tangent, value, out_tangent),本轮不支持。
 */
function parseQuaternionKeyframes(
  times: number[],
  outputData: Float32Array,
  interp: AnimationInterpolation,
  warnings: string[],
  channelIndex: number
): QuaternionKeyframe[] {
  const keys: QuaternionKeyframe[] = [];
  if (interp === AnimationInterpolation.CubicSpline) {
    // CUBICSPLINE:每 3 个 VEC4 为一组,本轮只取中间的 value
    const stride: number = 12; // 3 * 4
    if (outputData.length < times.length * stride) {
      warnings.push('channel[' + channelIndex + '] CUBICSPLINE rotation 数据不足');
      return keys;
    }
    for (let i: number = 0; i < times.length; i++) {
      const base: number = i * stride + 4; // 跳过 in_tangent
      const q: QuaternionValue = { x: outputData[base], y: outputData[base + 1], z: outputData[base + 2], w: outputData[base + 3] };
      keys.push({ time: times[i], value: q });
    }
    return keys;
  }
  // LINEAR / STEP:每 4 个 float 为一个 quaternion
  if (outputData.length < times.length * 4) {
    warnings.push('channel[' + channelIndex + '] rotation 数据不足: expected=' + (times.length * 4) + ', actual=' + outputData.length);
    return keys;
  }
  for (let i: number = 0; i < times.length; i++) {
    const base: number = i * 4;
    const q: QuaternionValue = {
      x: outputData[base],
      y: outputData[base + 1],
      z: outputData[base + 2],
      w: outputData[base + 3]
    };
    keys.push({ time: times[i], value: q });
  }
  return keys;
}

/**
 * 解析 Vector3 关键帧数组。
 *
 * output accessor VEC3 FLOAT:每 3 个 float 为一个 vector [x, y, z]。
 * CUBICSPLINE:每 3 个 VEC3 为一组,本轮只取中间的 value。
 */
function parseVector3Keyframes(
  times: number[],
  outputData: Float32Array,
  interp: AnimationInterpolation,
  warnings: string[],
  channelIndex: number
): Vector3Keyframe[] {
  const keys: Vector3Keyframe[] = [];
  if (interp === AnimationInterpolation.CubicSpline) {
    const stride: number = 9; // 3 * 3
    if (outputData.length < times.length * stride) {
      warnings.push('channel[' + channelIndex + '] CUBICSPLINE vector 数据不足');
      return keys;
    }
    for (let i: number = 0; i < times.length; i++) {
      const base: number = i * stride + 3;
      const v: Vector3Value = { x: outputData[base], y: outputData[base + 1], z: outputData[base + 2] };
      keys.push({ time: times[i], value: v });
    }
    return keys;
  }
  // LINEAR / STEP
  if (outputData.length < times.length * 3) {
    warnings.push('channel[' + channelIndex + '] vector 数据不足: expected=' + (times.length * 3) + ', actual=' + outputData.length);
    return keys;
  }
  for (let i: number = 0; i < times.length; i++) {
    const base: number = i * 3;
    const v: Vector3Value = {
      x: outputData[base],
      y: outputData[base + 1],
      z: outputData[base + 2]
    };
    keys.push({ time: times[i], value: v });
  }
  return keys;
}

/**
 * 将节点名映射到 HumanoidBone。
 *
 * 动作包使用标准 HumanoidBone 名(如 "RightUpperArm"),
 * 直接匹配枚举值。
 *
 * @returns HumanoidBone 或 null(无法映射)
 */
function mapNodeNameToHumanoidBone(nodeName: string): HumanoidBone | null {
  // 直接匹配 HumanoidBone 枚举值
  switch (nodeName) {
    case 'Hips': return HumanoidBone.Hips;
    case 'Spine': return HumanoidBone.Spine;
    case 'Chest': return HumanoidBone.Chest;
    case 'UpperChest': return HumanoidBone.UpperChest;
    case 'Neck': return HumanoidBone.Neck;
    case 'Head': return HumanoidBone.Head;
    case 'LeftShoulder': return HumanoidBone.LeftShoulder;
    case 'LeftUpperArm': return HumanoidBone.LeftUpperArm;
    case 'LeftLowerArm': return HumanoidBone.LeftLowerArm;
    case 'LeftHand': return HumanoidBone.LeftHand;
    case 'RightShoulder': return HumanoidBone.RightShoulder;
    case 'RightUpperArm': return HumanoidBone.RightUpperArm;
    case 'RightLowerArm': return HumanoidBone.RightLowerArm;
    case 'RightHand': return HumanoidBone.RightHand;
    case 'LeftUpperLeg': return HumanoidBone.LeftUpperLeg;
    case 'LeftLowerLeg': return HumanoidBone.LeftLowerLeg;
    case 'LeftFoot': return HumanoidBone.LeftFoot;
    case 'LeftToes': return HumanoidBone.LeftToes;
    case 'RightUpperLeg': return HumanoidBone.RightUpperLeg;
    case 'RightLowerLeg': return HumanoidBone.RightLowerLeg;
    case 'RightFoot': return HumanoidBone.RightFoot;
    case 'RightToes': return HumanoidBone.RightToes;
    case 'LeftEye': return HumanoidBone.LeftEye;
    case 'RightEye': return HumanoidBone.RightEye;
    case 'Jaw': return HumanoidBone.Jaw;
    default: return null;
  }
}

/**
 * 估算骨架高度(从 nodes 的 translation 推断)。
 *
 * 粗略估算:遍历 nodes,找 Hips 和 Head 的 Y 分量差。
 * 如果无法找到,返回默认值 1.4(标准 humanoid 大致高度)。
 */
function estimateSkeletonHeight(parsed: GlbParsedData): number {
  const nodes: Object[] | undefined = parsed.json['nodes'] as Object[] | undefined;
  if (nodes === undefined) {
    return 1.4;
  }
  let hipsY: number = 0;
  let headY: number = 0;
  let foundHips: boolean = false;
  let foundHead: boolean = false;

  // 简单方式:累加 Hips→Spine→Chest→UpperChest→Neck→Head 的 translation.y
  // 但这需要遍历骨骼树。这里用简化版:直接找 Hips 和 Head 节点的 world Y。
  // 由于 GLB nodes 的 translation 是 local,需要遍历父链累加。
  // MVP 简化:直接返回默认值,后续可改进。
  for (let i: number = 0; i < nodes.length; i++) {
    const node: Record<string, Object> = nodes[i] as Record<string, Object>;
    const name: string = String(node['name'] ?? '');
    if (name === 'Hips') {
      foundHips = true;
      const t: Object | undefined = node['translation'];
      if (t instanceof Array) {
        hipsY = Number((t as Object[])[1]);
      }
    } else if (name === 'Head') {
      foundHead = true;
      const t: Object | undefined = node['translation'];
      if (t instanceof Array) {
        headY = Number((t as Object[])[1]);
      }
    }
  }

  if (foundHips && foundHead) {
    // 粗略:Hips 到 Head 的距离 + 头部约 0.2m
    // 注意:这是 local translation,不是 world,只是粗略估算
    return Math.abs(headY - hipsY) + 0.2;
  }
  return 1.4;
}

/**
 * 源 Rest Pose 提取结果。
 */
export interface SourceRestPoseParseResult {
  success: boolean;
  errorMessage: string;
  restPose: HumanoidRestPose | null;
}

/**
 * 从 GLB nodes 默认 TRS 提取源骨架 Rest Pose。
 *
 * 优先使用 nodes[].translation/rotation/scale 默认值。
 * 不使用动画第 0 帧(除非确认第 0 帧就是 Rest Pose)。
 *
 * @param buffer GLB 文件 ArrayBuffer
 * @returns 解析结果
 */
export function parseSourceRestPose(buffer: ArrayBuffer): SourceRestPoseParseResult {
  const parsed: GlbParsedData = parseGlb(buffer);
  if (!parsed.valid) {
    return { success: false, errorMessage: 'GLB 解析失败: ' + parsed.errorMessage, restPose: null };
  }

  const nodes: Object[] | undefined = parsed.json['nodes'] as Object[] | undefined;
  if (nodes === undefined) {
    return { success: false, errorMessage: 'GLB 缺少 nodes', restPose: null };
  }

  const restPose: HumanoidRestPose = createEmptyRestPose();
  let hipsY: number = 0;
  let maxWorldY: number = 0;

  for (let i: number = 0; i < nodes.length; i++) {
    const node: Record<string, Object> = nodes[i] as Record<string, Object>;
    const nameObj: Object | undefined = node['name'];
    const nodeName: string = (nameObj !== undefined && nameObj !== null) ? String(nameObj) : '';
    const bone: HumanoidBone | null = mapNodeNameToHumanoidBone(nodeName);
    if (bone === null) {
      continue;
    }

    // 读取 translation(默认 [0,0,0])
    const pos: Vector3Value = readVec3(node['translation'], zeroVector3Value());
    // 读取 rotation(默认 [0,0,0,1] identity)
    const rot: QuaternionValue = readQuat(node['rotation'], identityQuaternionValue());
    // 读取 scale(默认 [1,1,1])
    const scl: Vector3Value = readVec3(node['scale'], oneVector3Value());

    restPose.bones.set(bone, {
      localPosition: pos,
      localRotation: rot,
      localScale: scl
    });

    if (bone === HumanoidBone.Hips) {
      hipsY = pos.y;
    }
    // 粗略累计最大 Y(不完整,因为没遍历父链)
    if (pos.y > maxWorldY) {
      maxWorldY = pos.y;
    }
  }

  restPose.hipsHeight = hipsY;
  restPose.modelHeight = estimateSkeletonHeight(parsed);

  Logger.info(LOG_TAG, 'parseSourceRestPose: bones=' + restPose.bones.size
    + ', hipsY=' + hipsY.toFixed(3)
    + ', modelHeight=' + restPose.modelHeight.toFixed(3));

  return { success: true, errorMessage: '', restPose: restPose };
}

/**
 * 从 Object 读取 VEC3 数组。
 */
function readVec3(value: Object | undefined, defaultValue: Vector3Value): Vector3Value {
  if (value === undefined || value === null || !(value instanceof Array)) {
    return { x: defaultValue.x, y: defaultValue.y, z: defaultValue.z };
  }
  const arr: Object[] = value as Object[];
  return {
    x: arr.length > 0 ? Number(arr[0]) : defaultValue.x,
    y: arr.length > 1 ? Number(arr[1]) : defaultValue.y,
    z: arr.length > 2 ? Number(arr[2]) : defaultValue.z
  };
}

/**
 * 从 Object 读取 VEC4 四元数。
 */
function readQuat(value: Object | undefined, defaultValue: QuaternionValue): QuaternionValue {
  if (value === undefined || value === null || !(value instanceof Array)) {
    return { x: defaultValue.x, y: defaultValue.y, z: defaultValue.z, w: defaultValue.w };
  }
  const arr: Object[] = value as Object[];
  return {
    x: arr.length > 0 ? Number(arr[0]) : defaultValue.x,
    y: arr.length > 1 ? Number(arr[1]) : defaultValue.y,
    z: arr.length > 2 ? Number(arr[2]) : defaultValue.z,
    w: arr.length > 3 ? Number(arr[3]) : defaultValue.w
  };
}
