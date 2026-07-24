/**
 * VrmSpringBoneParser VRM SpringBone 解析器
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 1.0: extensions.VRMC_springBone
 *   - colliders: [{ node, shape: { sphere: { offset, radius } | capsule: { offset, tail, radius } } }]
 *   - colliderGroups: [{ name, colliders: [colliderIndex] }]
 *   - springs: [{ name, joints: [{ node, hitRadius, stiffness, gravityPower, gravityFromStartBone, dragForce, center }], colliderGroups: [groupIndex] }]
 * VRM 0.x: extensions.VRM.secondaryAnimation
 *   - boneGroups: [{ bones: [nodeIndex], center, colliderGroups, collisionGroups, dragForce, gravityPower, gravityDir, stiffiness, hitRadius }]
 *   - colliderGroups: [{ node, colliders: [{ offset, radius }] }]
 */

import { VrmVersion } from '../models/character3d/vrm/VrmVersion';
import {
  VrmSpringBoneSet,
  VrmCollider,
  VrmColliderGroup,
  VrmSpring,
  VrmSpringBoneJoint,
  VrmColliderShape,
  VrmColliderShapeType,
  createEmptyVrmSpringBoneSet
} from '../models/character3d/vrm/VrmSpringBone';
import {
  getObject,
  getObjectArray,
  getNumber,
  getNumberArray,
  getString
} from './VrmExtensionParser';

/**
 * 解析 VRM SpringBone 配置。
 *
 * @param version VRM 版本
 * @param vrmcSpringBone VRMC_springBone 扩展对象(VRM 1.0)
 * @param vrm0Extension VRM 扩展对象(VRM 0.x,从中取 secondaryAnimation)
 * @returns VRM SpringBone 配置
 */
export function parseVrmSpringBone(
  version: VrmVersion,
  vrmcSpringBone: Record<string, Object> | null,
  vrm0Extension: Record<string, Object> | null
): VrmSpringBoneSet {
  if (version === VrmVersion.Vrm1 && vrmcSpringBone !== null) {
    return parseVrm1SpringBone(vrmcSpringBone);
  }
  if (version === VrmVersion.Vrm0x && vrm0Extension !== null) {
    return parseVrm0SpringBone(vrm0Extension);
  }
  return createEmptyVrmSpringBoneSet(version);
}

/**
 * 解析 VRM 1.0 SpringBone。
 */
function parseVrm1SpringBone(vrmcSpringBone: Record<string, Object>): VrmSpringBoneSet {
  const result: VrmSpringBoneSet = createEmptyVrmSpringBoneSet(VrmVersion.Vrm1);

  // colliders
  const colliderArr: Record<string, Object>[] = getObjectArray(vrmcSpringBone, 'colliders');
  const colliders: VrmCollider[] = [];
  for (let i: number = 0; i < colliderArr.length; i++) {
    const c: Record<string, Object> = colliderArr[i];
    const nodeIndex: number = getNumber(c, 'node', -1);
    const shape: VrmColliderShape | null = parseVrm1ColliderShape(c);
    if (nodeIndex >= 0 && shape !== null) {
      colliders.push({ nodeIndex: nodeIndex, shape: shape });
    }
  }
  result.colliders = colliders;

  // colliderGroups
  const groupArr: Record<string, Object>[] = getObjectArray(vrmcSpringBone, 'colliderGroups');
  const colliderGroups: VrmColliderGroup[] = [];
  for (let i: number = 0; i < groupArr.length; i++) {
    const g: Record<string, Object> = groupArr[i];
    const name: string = getString(g, 'name');
    const colliderIndices: number[] = [];
    const numArr: number[] = getNumberArray(g, 'colliders');
    for (let j: number = 0; j < numArr.length; j++) {
      colliderIndices.push(numArr[j]);
    }
    colliderGroups.push({ name: name, colliderIndices: colliderIndices });
  }
  result.colliderGroups = colliderGroups;

  // springs
  const springArr: Record<string, Object>[] = getObjectArray(vrmcSpringBone, 'springs');
  const springs: VrmSpring[] = [];
  let totalJointCount: number = 0;
  for (let i: number = 0; i < springArr.length; i++) {
    const s: Record<string, Object> = springArr[i];
    const name: string = getString(s, 'name');
    const joints: VrmSpringBoneJoint[] = parseVrm1Joints(s);
    const colliderGroupIndices: number[] = getNumberArray(s, 'colliderGroups');
    springs.push({
      name: name,
      joints: joints,
      colliderGroupIndices: colliderGroupIndices
    });
    totalJointCount += joints.length;
  }
  result.springs = springs;
  result.totalJointCount = totalJointCount;
  result.valid = colliders.length > 0 || springs.length > 0;
  return result;
}

/**
 * 解析 VRM 1.0 碰撞体形状。
 */
function parseVrm1ColliderShape(c: Record<string, Object>): VrmColliderShape | null {
  const shapeObj: Record<string, Object> | null = getObject(c, 'shape');
  if (shapeObj === null) {
    return null;
  }
  // sphere
  const sphereObj: Record<string, Object> | null = getObject(shapeObj, 'sphere');
  if (sphereObj !== null) {
    const offset: number[] = getNumberArray(sphereObj, 'offset');
    const radius: number = getNumber(sphereObj, 'radius', 0);
    return {
      type: VrmColliderShapeType.Sphere,
      offset: offset.length >= 3 ? [offset[0], offset[1], offset[2]] : [0, 0, 0],
      radius: radius,
      tail: null
    };
  }
  // capsule
  const capsuleObj: Record<string, Object> | null = getObject(shapeObj, 'capsule');
  if (capsuleObj !== null) {
    const offset: number[] = getNumberArray(capsuleObj, 'offset');
    const tail: number[] = getNumberArray(capsuleObj, 'tail');
    const radius: number = getNumber(capsuleObj, 'radius', 0);
    return {
      type: VrmColliderShapeType.Capsule,
      offset: offset.length >= 3 ? [offset[0], offset[1], offset[2]] : [0, 0, 0],
      radius: radius,
      tail: tail.length >= 3 ? [tail[0], tail[1], tail[2]] : [0, 0, 0]
    };
  }
  return null;
}

/**
 * 解析 VRM 1.0 关节列表。
 */
function parseVrm1Joints(springObj: Record<string, Object>): VrmSpringBoneJoint[] {
  const jointArr: Record<string, Object>[] = getObjectArray(springObj, 'joints');
  const result: VrmSpringBoneJoint[] = [];
  for (let i: number = 0; i < jointArr.length; i++) {
    const j: Record<string, Object> = jointArr[i];
    const nodeIndex: number = getNumber(j, 'node', -1);
    if (nodeIndex < 0) {
      continue;
    }
    const gravityArr: number[] = getNumberArray(j, 'gravityFromStartBone');
    result.push({
      nodeIndex: nodeIndex,
      hitRadius: getNumber(j, 'hitRadius', 0.02),
      stiffness: getNumber(j, 'stiffness', 1.0),
      gravityPower: getNumber(j, 'gravityPower', 0),
      gravityFromStartBone: gravityArr.length >= 3 ? [gravityArr[0], gravityArr[1], gravityArr[2]] : [0, -1, 0],
      dragForce: getNumber(j, 'dragForce', 0.4),
      centerNodeIndex: getNumber(j, 'center', -1)
    });
  }
  return result;
}

/**
 * 解析 VRM 0.x SpringBone(secondaryAnimation)。
 */
function parseVrm0SpringBone(vrm0Ext: Record<string, Object>): VrmSpringBoneSet {
  const result: VrmSpringBoneSet = createEmptyVrmSpringBoneSet(VrmVersion.Vrm0x);
  const secondaryObj: Record<string, Object> | null = getObject(vrm0Ext, 'secondaryAnimation');
  if (secondaryObj === null) {
    return result;
  }

  // VRM0 colliderGroups(每个组含 node + colliders[{offset, radius}])
  const groupArr: Record<string, Object>[] = getObjectArray(secondaryObj, 'colliderGroups');
  const colliders: VrmCollider[] = [];
  const colliderGroups: VrmColliderGroup[] = [];
  for (let i: number = 0; i < groupArr.length; i++) {
    const g: Record<string, Object> = groupArr[i];
    const nodeIndex: number = getNumber(g, 'node', -1);
    const colliderArr: Record<string, Object>[] = getObjectArray(g, 'colliders');
    const colliderIndices: number[] = [];
    for (let j: number = 0; j < colliderArr.length; j++) {
      const c: Record<string, Object> = colliderArr[j];
      const offset: number[] = getNumberArray(c, 'offset');
      const radius: number = getNumber(c, 'radius', 0);
      if (nodeIndex >= 0) {
        colliders.push({
          nodeIndex: nodeIndex,
          shape: {
            type: VrmColliderShapeType.Sphere,
            offset: offset.length >= 3 ? [offset[0], offset[1], offset[2]] : [0, 0, 0],
            radius: radius,
            tail: null
          }
        });
        colliderIndices.push(colliders.length - 1);
      }
    }
    colliderGroups.push({ name: 'colliderGroup_' + i, colliderIndices: colliderIndices });
  }
  result.colliders = colliders;
  result.colliderGroups = colliderGroups;

  // VRM0 boneGroups(每条链)
  const boneGroupArr: Record<string, Object>[] = getObjectArray(secondaryObj, 'boneGroups');
  const springs: VrmSpring[] = [];
  let totalJointCount: number = 0;
  for (let i: number = 0; i < boneGroupArr.length; i++) {
    const bg: Record<string, Object> = boneGroupArr[i];
    const bones: number[] = getNumberArray(bg, 'bones');
    const center: number = getNumber(bg, 'center', -1);
    const dragForce: number = getNumber(bg, 'dragForce', 0.4);
    const gravityPower: number = getNumber(bg, 'gravityPower', 0);
    const gravityDir: number[] = getNumberArray(bg, 'gravityDir');
    const stiffiness: number = getNumber(bg, 'stiffiness', 1.0);
    const hitRadius: number = getNumber(bg, 'hitRadius', 0.02);
    const colliderGroupIndices: number[] = getNumberArray(bg, 'colliderGroups');

    // VRM0 bones 数组每个元素是 nodeIndex,转为关节列表
    const joints: VrmSpringBoneJoint[] = [];
    for (let j: number = 0; j < bones.length; j++) {
      joints.push({
        nodeIndex: bones[j],
        hitRadius: hitRadius,
        stiffness: stiffiness,
        gravityPower: gravityPower,
        gravityFromStartBone: gravityDir.length >= 3 ? [gravityDir[0], gravityDir[1], gravityDir[2]] : [0, -1, 0],
        dragForce: dragForce,
        centerNodeIndex: center
      });
    }
    springs.push({
      name: 'spring_' + i,
      joints: joints,
      colliderGroupIndices: colliderGroupIndices
    });
    totalJointCount += joints.length;
  }
  result.springs = springs;
  result.totalJointCount = totalJointCount;
  result.valid = colliders.length > 0 || springs.length > 0;
  return result;
}
