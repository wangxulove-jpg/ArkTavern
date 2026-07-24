/**
 * VrmLookAtParser VRM 视线跟随解析器
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 1.0: VRMC_vrm.lookAt
 *   - type: 'expression' | 'bone'
 *   - offsetFromHeadBone: [x, y, z]
 *   - rangeMapHorizontalInner/Outer/VerticalDown/Up: { inputMaxValue, outputScale }
 * VRM 0.x: VRM.firstPerson
 *   - firstPersonBone: nodeIndex, firstPersonBoneOffset: [x,y,z]
 *   - lookAtTypeName: 'BlendShape' | 'Bone'
 *   - lookAtHorizontalInner/Outer/VerticalDown/Up: { curve, xRange, yRange }
 */

import { VrmVersion } from '../models/character3d/vrm/VrmVersion';
import {
  VrmLookAt,
  VrmLookAtType,
  VrmLookAtRangeMap,
  Vrm0LookAtCurve,
  createEmptyVrmLookAt
} from '../models/character3d/vrm/VrmLookAt';
import {
  getObject,
  getNumber,
  getNumberArray,
  getString
} from './VrmExtensionParser';

/**
 * 解析 VRM LookAt 配置。
 *
 * @param version VRM 版本
 * @param vrmcVrm VRMC_vrm 扩展对象(VRM 1.0)
 * @param vrm0Extension VRM 扩展对象(VRM 0.x)
 * @param headNodeIndex 头部节点索引(VRM1: 通过 humanoid.head 解析后传入;VRM0: 从 firstPersonBone 取)
 * @returns VRM LookAt 配置
 */
export function parseVrmLookAt(
  version: VrmVersion,
  vrmcVrm: Record<string, Object> | null,
  vrm0Extension: Record<string, Object> | null,
  headNodeIndex: number
): VrmLookAt {
  if (version === VrmVersion.Vrm1 && vrmcVrm !== null) {
    return parseVrm1LookAt(vrmcVrm, headNodeIndex);
  }
  if (version === VrmVersion.Vrm0x && vrm0Extension !== null) {
    return parseVrm0LookAt(vrm0Extension);
  }
  return createEmptyVrmLookAt(version);
}

/**
 * 解析 VRM 1.0 LookAt。
 */
function parseVrm1LookAt(vrmcVrm: Record<string, Object>, headNodeIndex: number): VrmLookAt {
  const result: VrmLookAt = createEmptyVrmLookAt(VrmVersion.Vrm1);
  const lookAtObj: Record<string, Object> | null = getObject(vrmcVrm, 'lookAt');
  if (lookAtObj === null) {
    return result;
  }

  // type
  const typeStr: string = getString(lookAtObj, 'type', 'expression');
  result.type = typeStr === 'bone' ? VrmLookAtType.Bone : VrmLookAtType.Expression;

  // offsetFromHeadBone
  const offset: number[] = getNumberArray(lookAtObj, 'offsetFromHeadBone');
  result.offsetFromHeadBone = offset.length >= 3 ? [offset[0], offset[1], offset[2]] : [0, 0, 0];

  // headNodeIndex
  result.headNodeIndex = headNodeIndex;

  // RangeMap
  result.rangeMapHorizontalInner = parseRangeMap(lookAtObj, 'rangeMapHorizontalInner');
  result.rangeMapHorizontalOuter = parseRangeMap(lookAtObj, 'rangeMapHorizontalOuter');
  result.rangeMapVerticalDown = parseRangeMap(lookAtObj, 'rangeMapVerticalDown');
  result.rangeMapVerticalUp = parseRangeMap(lookAtObj, 'rangeMapVerticalUp');

  result.valid = true;
  return result;
}

/**
 * 解析 VRM 1.0 RangeMap。
 */
function parseRangeMap(lookAtObj: Record<string, Object>, key: string): VrmLookAtRangeMap | null {
  const rmObj: Record<string, Object> | null = getObject(lookAtObj, key);
  if (rmObj === null) {
    return null;
  }
  return {
    inputMaxValue: getNumber(rmObj, 'inputMaxValue', 0),
    outputScale: getNumber(rmObj, 'outputScale', 0)
  };
}

/**
 * 解析 VRM 0.x LookAt(从 firstPerson 字段提取)。
 */
function parseVrm0LookAt(vrm0Ext: Record<string, Object>): VrmLookAt {
  const result: VrmLookAt = createEmptyVrmLookAt(VrmVersion.Vrm0x);
  const firstPersonObj: Record<string, Object> | null = getObject(vrm0Ext, 'firstPerson');
  if (firstPersonObj === null) {
    return result;
  }

  // lookAtTypeName
  const typeName: string = getString(firstPersonObj, 'lookAtTypeName', 'BlendShape');
  result.type = typeName === 'Bone' ? VrmLookAtType.Bone : VrmLookAtType.Expression;

  // firstPersonBone(nodeIndex)
  result.headNodeIndex = getNumber(firstPersonObj, 'firstPersonBone', -1);

  // firstPersonBoneOffset
  const offset: number[] = getNumberArray(firstPersonObj, 'firstPersonBoneOffset');
  result.offsetFromHeadBone = offset.length >= 3 ? [offset[0], offset[1], offset[2]] : [0, 0, 0];

  // VRM0 曲线(lookAtHorizontalInner 等)
  result.vrm0CurveHorizontalInner = parseVrm0Curve(firstPersonObj, 'lookAtHorizontalInner');
  result.vrm0CurveHorizontalOuter = parseVrm0Curve(firstPersonObj, 'lookAtHorizontalOuter');
  result.vrm0CurveVerticalDown = parseVrm0Curve(firstPersonObj, 'lookAtVerticalDown');
  result.vrm0CurveVerticalUp = parseVrm0Curve(firstPersonObj, 'lookAtVerticalUp');

  // VRM0 curve 转 RangeMap(粗略:xRange→inputMaxValue, yRange→outputScale)
  if (result.vrm0CurveHorizontalInner !== null) {
    result.rangeMapHorizontalInner = {
      inputMaxValue: result.vrm0CurveHorizontalInner.xRange,
      outputScale: result.vrm0CurveHorizontalInner.yRange
    };
  }
  if (result.vrm0CurveHorizontalOuter !== null) {
    result.rangeMapHorizontalOuter = {
      inputMaxValue: result.vrm0CurveHorizontalOuter.xRange,
      outputScale: result.vrm0CurveHorizontalOuter.yRange
    };
  }
  if (result.vrm0CurveVerticalDown !== null) {
    result.rangeMapVerticalDown = {
      inputMaxValue: result.vrm0CurveVerticalDown.xRange,
      outputScale: result.vrm0CurveVerticalDown.yRange
    };
  }
  if (result.vrm0CurveVerticalUp !== null) {
    result.rangeMapVerticalUp = {
      inputMaxValue: result.vrm0CurveVerticalUp.xRange,
      outputScale: result.vrm0CurveVerticalUp.yRange
    };
  }

  result.valid = true;
  return result;
}

/**
 * 解析 VRM 0.x LookAt 曲线。
 */
function parseVrm0Curve(firstPersonObj: Record<string, Object>, key: string): Vrm0LookAtCurve | null {
  const curveObj: Record<string, Object> | null = getObject(firstPersonObj, key);
  if (curveObj === null) {
    return null;
  }
  const curve: number[] = getNumberArray(curveObj, 'curve');
  const xRange: number = getNumber(curveObj, 'xRange', 0);
  const yRange: number = getNumber(curveObj, 'yRange', 0);
  return {
    curve: curve.length >= 4 ? [curve[0], curve[1], curve[2], curve[3]] : [0, 0, 0, 0],
    xRange: xRange,
    yRange: yRange
  };
}
