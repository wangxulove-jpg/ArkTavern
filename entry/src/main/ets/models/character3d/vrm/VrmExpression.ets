/**
 * VrmExpression VRM 表情(BlendShape)
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 1.0: extensions.VRMC_vrm.expressions.preset.custom[]
 *   - 每个表情包含 morphTargetBinds / materialColorBinds / textureTransformBinds
 * VRM 0.x: extensions.VRM.blendShapeMaster.blendShapeGroups[]
 *   - 每个表情包含 values[{ meshes, bindTargets, weight }]
 *
 * 本任务仅解析保存,不实现 Runtime(权重驱动)。
 *
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/spec/core/#expressions
 * - VRM 0.x: https://vrm.dev/vrm0/blendshape.html
 */

/**
 * VRM 表情预设类型(VRM 1.0 与 0.x 统一)。
 *
 * 注意:VRM 1.0 的 preset 仅含 happy/angry/sad/relaxed/surprised/neutral,
 * 其余 Blink/LookUp/A/I/U/E/O 等在 VRM 1.0 中作为 custom 名称出现,
 * 但语义与 VRM 0.x presetName 一致,这里统一枚举。
 */
export enum VrmExpressionPreset {
  Happy = 'happy',
  Angry = 'angry',
  Sad = 'sad',
  Relaxed = 'relaxed',
  Surprised = 'surprised',
  Neutral = 'neutral',
  /** 眨眼(双眼) */
  Blink = 'Blink',
  /** 左眼眨眼 */
  BlinkLeft = 'BlinkLeft',
  /** 右眼眨眼 */
  BlinkRight = 'BlinkRight',
  /** 视线上抬 */
  LookUp = 'LookUp',
  /** 视线下移 */
  LookDown = 'LookDown',
  /** 视线左移 */
  LookLeft = 'LookLeft',
  /** 视线右移 */
  LookRight = 'LookRight',
  /** 嘴型 A */
  A = 'A',
  /** 嘴型 I */
  I = 'I',
  /** 嘴型 U */
  U = 'U',
  /** 嘴型 E */
  E = 'E',
  /** 嘴型 O */
  O = 'O'
}

/**
 * 材质颜色绑定类型(VRM 1.0 materialColorBinds.type)。
 */
export enum VrmMaterialColorBindType {
  Color = 'color',
  EmissiveColor = 'emissiveColor',
  ShadeColor = 'shadeColor',
  MatcapColor = 'matcapColor',
  RimColor = 'rimColor',
  OutlineColor = 'outlineColor'
}

/**
 * Morph Target 绑定。
 */
export interface VrmMorphTargetBind {
  /** glTF 节点索引(该节点的 mesh.primitives[k].targets 中的 morph target) */
  nodeIndex: number;
  /** morph target 索引(targets 数组下标) */
  morphTargetIndex: number;
  /** 权重 0~1 */
  weight: number;
}

/**
 * 材质颜色绑定。
 */
export interface VrmMaterialColorBind {
  /** glTF material 索引 */
  materialIndex: number;
  /** 绑定类型 */
  bindType: VrmMaterialColorBindType;
  /** 目标颜色 [r, g, b, a](0~1) */
  targetValue: number[];
}

/**
 * 纹理变换绑定。
 */
export interface VrmTextureTransformBind {
  /** glTF material 索引 */
  materialIndex: number;
  /** UV 偏移 [u, v] */
  offset: number[];
  /** UV 缩放 [u, v] */
  scale: number[];
}

/**
 * 单个 VRM 表情定义。
 */
export interface VrmExpression {
  /** 预设类型(若是预设表情);custom 表情此字段为 Neutral 或特定标记 */
  preset: VrmExpressionPreset | null;
  /** 表情名(VRM1: custom 名称;VRM0: name 字段) */
  name: string;
  /** 是否预设表情(VRM1: preset !== null;VRM0: presetName !== 'Unknown') */
  isPreset: boolean;
  /** Morph Target 绑定列表 */
  morphTargetBinds: VrmMorphTargetBind[];
  /** 材质颜色绑定列表 */
  materialColorBinds: VrmMaterialColorBind[];
  /** 纹理变换绑定列表 */
  textureTransformBinds: VrmTextureTransformBind[];
  /** 是否是 Blink 系列(用于 LookAt 视线) */
  isBlink: boolean;
  /** 是否是 LookAt 系列(视线方向) */
  isLookAt: boolean;
  /** 是否是 LipSync 嘴型(A/I/U/E/O) */
  isLipSync: boolean;
  /** 是否是情绪表情(Happy/Angry/Sad/Relaxed/Surprised) */
  isEmotion: boolean;
}

/**
 * VRM 表情集合。
 */
export interface VrmExpressionSet {
  /** 所有表情列表 */
  expressions: VrmExpression[];
  /** 预设表情数量 */
  presetCount: number;
  /** 自定义表情数量 */
  customCount: number;
  /** Blink 表情数 */
  blinkCount: number;
  /** LookAt 表情数 */
  lookAtCount: number;
  /** LipSync 表情数 */
  lipSyncCount: number;
  /** 情绪表情数 */
  emotionCount: number;
  /** 解析是否成功 */
  valid: boolean;
  /** 原始 expressions JSON 哈希 */
  expressionHash: string;
}

/**
 * 创建空表情集合。
 */
export function createEmptyVrmExpressionSet(): VrmExpressionSet {
  return {
    expressions: [],
    presetCount: 0,
    customCount: 0,
    blinkCount: 0,
    lookAtCount: 0,
    lipSyncCount: 0,
    emotionCount: 0,
    valid: false,
    expressionHash: ''
  };
}

/**
 * 判断表情名是否为 Blink 系列。
 */
export function isBlinkExpression(name: string): boolean {
  const lower: string = name.toLowerCase();
  return lower === 'blink' || lower === 'blinkleft' || lower === 'blink_l'
    || lower === 'blinkright' || lower === 'blink_r' || lower === 'blinkleft' || lower === 'blink_right';
}

/**
 * 判断表情名是否为 LookAt 系列。
 */
export function isLookAtExpression(name: string): boolean {
  const lower: string = name.toLowerCase();
  return lower === 'lookup' || lower === 'look_up' || lower === 'lookdown'
    || lower === 'look_down' || lower === 'lookleft' || lower === 'look_left'
    || lower === 'lookright' || lower === 'look_right';
}

/**
 * 判断表情名是否为 LipSync 嘴型。
 */
export function isLipSyncExpression(name: string): boolean {
  return name === 'A' || name === 'I' || name === 'U' || name === 'E' || name === 'O'
    || name === 'a' || name === 'i' || name === 'u' || name === 'e' || name === 'o';
}

/**
 * 判断表情名是否为情绪表情。
 */
export function isEmotionExpression(name: string): boolean {
  const lower: string = name.toLowerCase();
  return lower === 'happy' || lower === 'angry' || lower === 'sad'
    || lower === 'relaxed' || lower === 'surprised';
}
