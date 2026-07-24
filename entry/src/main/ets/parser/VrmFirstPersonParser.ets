/**
 * VrmFirstPersonParser VRM 第一人称视角解析器
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 1.0: VRMC_vrm.firstPerson
 *   - meshAnnotations: [{ node, firstPersonFlag, thirdPersonFlag }]
 * VRM 0.x: VRM.firstPerson
 *   - firstPersonBone, firstPersonBoneOffset
 *   - meshAnnotations: [{ mesh, firstPersonFlag }]
 */

import { VrmVersion } from '../models/character3d/vrm/VrmVersion';
import {
  VrmFirstPerson,
  VrmMeshAnnotation,
  VrmFirstPersonFlag,
  createEmptyVrmFirstPerson
} from '../models/character3d/vrm/VrmFirstPerson';
import {
  getObject,
  getObjectArray,
  getNumber,
  getNumberArray,
  getString
} from './VrmExtensionParser';

/**
 * 解析 VRM FirstPerson 配置。
 *
 * @param version VRM 版本
 * @param vrmcVrm VRMC_vrm 扩展对象(VRM 1.0)
 * @param vrm0Extension VRM 扩展对象(VRM 0.x)
 * @param headNodeIndex 头部节点索引(VRM 1.0: 从 humanoid 解析;VRM 0.x: 从 firstPersonBone 取)
 * @returns VRM FirstPerson 配置
 */
export function parseVrmFirstPerson(
  version: VrmVersion,
  vrmcVrm: Record<string, Object> | null,
  vrm0Extension: Record<string, Object> | null,
  headNodeIndex: number
): VrmFirstPerson {
  if (version === VrmVersion.Vrm1 && vrmcVrm !== null) {
    return parseVrm1FirstPerson(vrmcVrm, headNodeIndex);
  }
  if (version === VrmVersion.Vrm0x && vrm0Extension !== null) {
    return parseVrm0FirstPerson(vrm0Extension);
  }
  return createEmptyVrmFirstPerson(version);
}

/**
 * 解析 VRM 1.0 FirstPerson。
 */
function parseVrm1FirstPerson(vrmcVrm: Record<string, Object>, headNodeIndex: number): VrmFirstPerson {
  const result: VrmFirstPerson = createEmptyVrmFirstPerson(VrmVersion.Vrm1);
  const fpObj: Record<string, Object> | null = getObject(vrmcVrm, 'firstPerson');
  if (fpObj === null) {
    return result;
  }

  result.firstPersonBoneNodeIndex = headNodeIndex;
  result.firstPersonBoneOffset = [0, 0, 0];

  // meshAnnotations
  const annArr: Record<string, Object>[] = getObjectArray(fpObj, 'meshAnnotations');
  const annotations: VrmMeshAnnotation[] = [];
  for (let i: number = 0; i < annArr.length; i++) {
    const a: Record<string, Object> = annArr[i];
    const nodeIndex: number = getNumber(a, 'node', -1);
    const fpFlagStr: string = getString(a, 'firstPersonFlag', 'auto');
    const tpFlagStr: string = getString(a, 'thirdPersonFlag', 'auto');
    annotations.push({
      nodeIndex: nodeIndex,
      meshIndex: -1,
      firstPersonFlag: parseFirstPersonFlag(fpFlagStr),
      thirdPersonFlag: parseFirstPersonFlag(tpFlagStr)
    });
  }
  result.meshAnnotations = annotations;
  result.valid = true;
  return result;
}

/**
 * 解析 VRM 0.x FirstPerson。
 */
function parseVrm0FirstPerson(vrm0Ext: Record<string, Object>): VrmFirstPerson {
  const result: VrmFirstPerson = createEmptyVrmFirstPerson(VrmVersion.Vrm0x);
  const fpObj: Record<string, Object> | null = getObject(vrm0Ext, 'firstPerson');
  if (fpObj === null) {
    return result;
  }

  result.firstPersonBoneNodeIndex = getNumber(fpObj, 'firstPersonBone', -1);
  const offset: number[] = getNumberArray(fpObj, 'firstPersonBoneOffset');
  result.firstPersonBoneOffset = offset.length >= 3 ? [offset[0], offset[1], offset[2]] : [0, 0, 0];

  // VRM0 meshAnnotations[{ mesh, firstPersonFlag }]
  const annArr: Record<string, Object>[] = getObjectArray(fpObj, 'meshAnnotations');
  const annotations: VrmMeshAnnotation[] = [];
  for (let i: number = 0; i < annArr.length; i++) {
    const a: Record<string, Object> = annArr[i];
    const meshIndex: number = getNumber(a, 'mesh', -1);
    const fpFlagStr: string = getString(a, 'firstPersonFlag', 'Auto');
    annotations.push({
      nodeIndex: -1, // VRM0 用 mesh 索引,nodeIndex 未知
      meshIndex: meshIndex,
      firstPersonFlag: parseFirstPersonFlag(fpFlagStr),
      thirdPersonFlag: null
    });
  }
  result.meshAnnotations = annotations;
  result.valid = true;
  return result;
}

/**
 * 解析 FirstPerson 标志(统一小写)。
 */
function parseFirstPersonFlag(value: string): VrmFirstPersonFlag {
  const lower: string = value.toLowerCase();
  if (lower === VrmFirstPersonFlag.Auto) {
    return VrmFirstPersonFlag.Auto;
  }
  if (lower === VrmFirstPersonFlag.Both) {
    return VrmFirstPersonFlag.Both;
  }
  if (lower === VrmFirstPersonFlag.ThirdPersonOnly) {
    return VrmFirstPersonFlag.ThirdPersonOnly;
  }
  if (lower === VrmFirstPersonFlag.FirstPersonOnly) {
    return VrmFirstPersonFlag.FirstPersonOnly;
  }
  return VrmFirstPersonFlag.Auto;
}
