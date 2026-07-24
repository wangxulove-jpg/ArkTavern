/**
 * VrmExpressionParser VRM 表情解析器
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 1.0: VRMC_vrm.expressions
 *   - preset: { happy: {...}, angry: {...}, sad, relaxed, surprised, neutral,
 *               blink, blinkLeft, blinkRight, lookUp, lookDown, lookLeft, lookRight,
 *               aa, ih, ou, ee, oh }
 *   - custom: { "name": {...} }
 *   - 每个表情: morphTargetBinds[{node,index,weight}], materialColorBinds, textureTransformBinds
 * VRM 0.x: VRM.blendShapeMaster.blendShapeGroups
 *   - [{ name, presetName, values: [{ meshes, bindTargets, weight }] }]
 *
 * 本任务仅解析保存,不实现 Runtime。
 */

import { VrmVersion } from '../models/character3d/vrm/VrmVersion';
import {
  VrmExpressionSet,
  VrmExpression,
  VrmExpressionPreset,
  VrmMorphTargetBind,
  VrmMaterialColorBind,
  VrmTextureTransformBind,
  VrmMaterialColorBindType,
  createEmptyVrmExpressionSet,
  isBlinkExpression,
  isLookAtExpression,
  isLipSyncExpression,
  isEmotionExpression
} from '../models/character3d/vrm/VrmExpression';
import {
  getObject,
  getObjectEntries,
  getObjectArray,
  getNumber,
  getNumberArray,
  getString,
  VrmObjectEntry
} from './VrmExtensionParser';

/**
 * VRM 1.0 preset 表情名 → VrmExpressionPreset 映射。
 */
const VRM1_PRESET_MAP: Map<string, VrmExpressionPreset> = buildVrm1PresetMap();

function buildVrm1PresetMap(): Map<string, VrmExpressionPreset> {
  const m: Map<string, VrmExpressionPreset> = new Map();
  m.set('happy', VrmExpressionPreset.Happy);
  m.set('angry', VrmExpressionPreset.Angry);
  m.set('sad', VrmExpressionPreset.Sad);
  m.set('relaxed', VrmExpressionPreset.Relaxed);
  m.set('surprised', VrmExpressionPreset.Surprised);
  m.set('neutral', VrmExpressionPreset.Neutral);
  m.set('blink', VrmExpressionPreset.Blink);
  m.set('blinkLeft', VrmExpressionPreset.BlinkLeft);
  m.set('blinkRight', VrmExpressionPreset.BlinkRight);
  m.set('lookUp', VrmExpressionPreset.LookUp);
  m.set('lookDown', VrmExpressionPreset.LookDown);
  m.set('lookLeft', VrmExpressionPreset.LookLeft);
  m.set('lookRight', VrmExpressionPreset.LookRight);
  m.set('aa', VrmExpressionPreset.A);
  m.set('ih', VrmExpressionPreset.I);
  m.set('ou', VrmExpressionPreset.U);
  m.set('ee', VrmExpressionPreset.E);
  m.set('oh', VrmExpressionPreset.O);
  return m;
}

/**
 * VRM 0.x presetName → VrmExpressionPreset 映射。
 */
const VRM0_PRESET_MAP: Map<string, VrmExpressionPreset> = buildVrm0PresetMap();

function buildVrm0PresetMap(): Map<string, VrmExpressionPreset> {
  const m: Map<string, VrmExpressionPreset> = new Map();
  m.set('Neutral', VrmExpressionPreset.Neutral);
  m.set('A', VrmExpressionPreset.A);
  m.set('I', VrmExpressionPreset.I);
  m.set('U', VrmExpressionPreset.U);
  m.set('E', VrmExpressionPreset.E);
  m.set('O', VrmExpressionPreset.O);
  m.set('Blink', VrmExpressionPreset.Blink);
  m.set('Blink_L', VrmExpressionPreset.BlinkLeft);
  m.set('Blink_R', VrmExpressionPreset.BlinkRight);
  m.set('LookUp', VrmExpressionPreset.LookUp);
  m.set('LookDown', VrmExpressionPreset.LookDown);
  m.set('LookLeft', VrmExpressionPreset.LookLeft);
  m.set('LookRight', VrmExpressionPreset.LookRight);
  return m;
}

/**
 * 解析 VRM 表情集。
 */
export function parseVrmExpressions(
  version: VrmVersion,
  vrmcVrm: Record<string, Object> | null,
  vrm0Extension: Record<string, Object> | null
): VrmExpressionSet {
  if (version === VrmVersion.Vrm1 && vrmcVrm !== null) {
    return parseVrm1Expressions(vrmcVrm);
  }
  if (version === VrmVersion.Vrm0x && vrm0Extension !== null) {
    return parseVrm0Expressions(vrm0Extension);
  }
  return createEmptyVrmExpressionSet();
}

/**
 * 解析 VRM 1.0 表情。
 */
function parseVrm1Expressions(vrmcVrm: Record<string, Object>): VrmExpressionSet {
  const result: VrmExpressionSet = createEmptyVrmExpressionSet();
  const expressionsObj: Record<string, Object> | null = getObject(vrmcVrm, 'expressions');
  if (expressionsObj === null) {
    return result;
  }

  const expressions: VrmExpression[] = [];

  // preset 表情
  const presetObj: Record<string, Object> | null = getObject(expressionsObj, 'preset');
  if (presetObj !== null) {
    const entries: VrmObjectEntry[] = getObjectEntries(presetObj);
    for (let i: number = 0; i < entries.length; i++) {
      const entry: VrmObjectEntry = entries[i];
      const preset: VrmExpressionPreset | null = VRM1_PRESET_MAP.get(entry.key) ?? null;
      const expr: VrmExpression | null = buildVrm1Expression(entry.key, entry.value, preset);
      if (expr !== null) {
        expressions.push(expr);
      }
    }
  }

  // custom 表情
  const customObj: Record<string, Object> | null = getObject(expressionsObj, 'custom');
  if (customObj !== null) {
    const entries: VrmObjectEntry[] = getObjectEntries(customObj);
    for (let i: number = 0; i < entries.length; i++) {
      const entry: VrmObjectEntry = entries[i];
      const expr: VrmExpression | null = buildVrm1Expression(entry.key, entry.value, null);
      if (expr !== null) {
        expressions.push(expr);
      }
    }
  }

  finalizeExpressionSet(result, expressions);
  return result;
}

/**
 * 构建单个 VRM 1.0 表情。
 */
function buildVrm1Expression(
  name: string,
  exprObj: Record<string, Object>,
  preset: VrmExpressionPreset | null
): VrmExpression | null {
  const morphTargetBinds: VrmMorphTargetBind[] = parseMorphTargetBinds(exprObj);
  const materialColorBinds: VrmMaterialColorBind[] = parseMaterialColorBinds(exprObj);
  const textureTransformBinds: VrmTextureTransformBind[] = parseTextureTransformBinds(exprObj);

  if (morphTargetBinds.length === 0 && materialColorBinds.length === 0
    && textureTransformBinds.length === 0) {
    return null; // 空表情忽略
  }

  const isPreset: boolean = preset !== null;
  return {
    preset: preset,
    name: name,
    isPreset: isPreset,
    morphTargetBinds: morphTargetBinds,
    materialColorBinds: materialColorBinds,
    textureTransformBinds: textureTransformBinds,
    isBlink: isBlinkExpression(name),
    isLookAt: isLookAtExpression(name),
    isLipSync: isLipSyncExpression(name),
    isEmotion: isEmotionExpression(name)
  };
}

/**
 * 解析 morphTargetBinds(VRM 1.0)。
 */
function parseMorphTargetBinds(exprObj: Record<string, Object>): VrmMorphTargetBind[] {
  const arr: Record<string, Object>[] = getObjectArray(exprObj, 'morphTargetBinds');
  const result: VrmMorphTargetBind[] = [];
  for (let i: number = 0; i < arr.length; i++) {
    const item: Record<string, Object> = arr[i];
    const nodeIndex: number = getNumber(item, 'node', -1);
    const morphTargetIndex: number = getNumber(item, 'index', -1);
    const weight: number = getNumber(item, 'weight', 0);
    if (nodeIndex >= 0 && morphTargetIndex >= 0) {
      result.push({
        nodeIndex: nodeIndex,
        morphTargetIndex: morphTargetIndex,
        weight: weight
      });
    }
  }
  return result;
}

/**
 * 解析 materialColorBinds(VRM 1.0)。
 */
function parseMaterialColorBinds(exprObj: Record<string, Object>): VrmMaterialColorBind[] {
  const arr: Record<string, Object>[] = getObjectArray(exprObj, 'materialColorBinds');
  const result: VrmMaterialColorBind[] = [];
  for (let i: number = 0; i < arr.length; i++) {
    const item: Record<string, Object> = arr[i];
    const materialIndex: number = getNumber(item, 'material', -1);
    const typeStr: string = getString(item, 'type');
    const targetValue: number[] = getNumberArray(item, 'targetValue');
    const bindType: VrmMaterialColorBindType = parseMaterialColorBindType(typeStr);
    if (materialIndex >= 0 && targetValue.length >= 3) {
      result.push({
        materialIndex: materialIndex,
        bindType: bindType,
        targetValue: targetValue
      });
    }
  }
  return result;
}

/**
 * 解析 textureTransformBinds(VRM 1.0)。
 */
function parseTextureTransformBinds(exprObj: Record<string, Object>): VrmTextureTransformBind[] {
  const arr: Record<string, Object>[] = getObjectArray(exprObj, 'textureTransformBinds');
  const result: VrmTextureTransformBind[] = [];
  for (let i: number = 0; i < arr.length; i++) {
    const item: Record<string, Object> = arr[i];
    const materialIndex: number = getNumber(item, 'material', -1);
    const offset: number[] = getNumberArray(item, 'offset');
    const scale: number[] = getNumberArray(item, 'scale');
    if (materialIndex >= 0) {
      result.push({
        materialIndex: materialIndex,
        offset: offset.length >= 2 ? offset : [0, 0],
        scale: scale.length >= 2 ? scale : [1, 1]
      });
    }
  }
  return result;
}

/**
 * 解析材质颜色绑定类型。
 */
function parseMaterialColorBindType(typeStr: string): VrmMaterialColorBindType {
  if (typeStr === VrmMaterialColorBindType.Color) {
    return VrmMaterialColorBindType.Color;
  }
  if (typeStr === VrmMaterialColorBindType.EmissiveColor) {
    return VrmMaterialColorBindType.EmissiveColor;
  }
  if (typeStr === VrmMaterialColorBindType.ShadeColor) {
    return VrmMaterialColorBindType.ShadeColor;
  }
  if (typeStr === VrmMaterialColorBindType.MatcapColor) {
    return VrmMaterialColorBindType.MatcapColor;
  }
  if (typeStr === VrmMaterialColorBindType.RimColor) {
    return VrmMaterialColorBindType.RimColor;
  }
  if (typeStr === VrmMaterialColorBindType.OutlineColor) {
    return VrmMaterialColorBindType.OutlineColor;
  }
  return VrmMaterialColorBindType.Color;
}

/**
 * 解析 VRM 0.x 表情(blendShapeMaster)。
 */
function parseVrm0Expressions(vrm0Ext: Record<string, Object>): VrmExpressionSet {
  const result: VrmExpressionSet = createEmptyVrmExpressionSet();
  const blendShapeMaster: Record<string, Object> | null = getObject(vrm0Ext, 'blendShapeMaster');
  if (blendShapeMaster === null) {
    return result;
  }

  const groups: Record<string, Object>[] = getObjectArray(blendShapeMaster, 'blendShapeGroups');
  const expressions: VrmExpression[] = [];

  for (let i: number = 0; i < groups.length; i++) {
    const group: Record<string, Object> = groups[i];
    const name: string = getString(group, 'name');
    const presetName: string = getString(group, 'presetName');
    const preset: VrmExpressionPreset | null = VRM0_PRESET_MAP.get(presetName) ?? null;

    // VRM0 values[{ meshes, bindTargets, weight }]
    const values: Record<string, Object>[] = getObjectArray(group, 'values');
    const morphTargetBinds: VrmMorphTargetBind[] = [];
    for (let j: number = 0; j < values.length; j++) {
      const v: Record<string, Object> = values[j];
      const meshIndex: number = getNumber(v, 'meshes', -1);
      const bindTarget: number = getNumber(v, 'bindTargets', -1);
      const weight: number = getNumber(v, 'weight', 0);
      // VRM0 meshes 是 mesh 索引(非 node 索引),需要后续 runtime 解析
      // 这里用 nodeIndex 字段暂存 meshIndex,标记为 VRM0 格式
      if (meshIndex >= 0 && bindTarget >= 0) {
        morphTargetBinds.push({
          nodeIndex: meshIndex, // VRM0:meshIndex;VRM1:nodeIndex
          morphTargetIndex: bindTarget, // VRM0:bindTarget;VRM1:index
          weight: weight
        });
      }
    }

    if (morphTargetBinds.length === 0) {
      continue;
    }

    expressions.push({
      preset: preset,
      name: name.length > 0 ? name : presetName,
      isPreset: preset !== null,
      morphTargetBinds: morphTargetBinds,
      materialColorBinds: [],
      textureTransformBinds: [],
      isBlink: isBlinkExpression(name) || isBlinkExpression(presetName),
      isLookAt: isLookAtExpression(name) || isLookAtExpression(presetName),
      isLipSync: isLipSyncExpression(name) || isLipSyncExpression(presetName),
      isEmotion: isEmotionExpression(name) || isEmotionExpression(presetName)
    });
  }

  finalizeExpressionSet(result, expressions);
  return result;
}

/**
 * 汇总表情集统计。
 */
function finalizeExpressionSet(result: VrmExpressionSet, expressions: VrmExpression[]): void {
  result.expressions = expressions;
  let presetCount: number = 0;
  let customCount: number = 0;
  let blinkCount: number = 0;
  let lookAtCount: number = 0;
  let lipSyncCount: number = 0;
  let emotionCount: number = 0;
  for (let i: number = 0; i < expressions.length; i++) {
    const e: VrmExpression = expressions[i];
    if (e.isPreset) {
      presetCount++;
    } else {
      customCount++;
    }
    if (e.isBlink) {
      blinkCount++;
    }
    if (e.isLookAt) {
      lookAtCount++;
    }
    if (e.isLipSync) {
      lipSyncCount++;
    }
    if (e.isEmotion) {
      emotionCount++;
    }
  }
  result.presetCount = presetCount;
  result.customCount = customCount;
  result.blinkCount = blinkCount;
  result.lookAtCount = lookAtCount;
  result.lipSyncCount = lipSyncCount;
  result.emotionCount = emotionCount;
  result.valid = expressions.length > 0;
}
