/**
 * VrmFirstPerson VRM 第一人称视角配置
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 1.0: extensions.VRMC_vrm.firstPerson
 *   - meshAnnotations: [{ node, firstPersonFlag, thirdPersonFlag }]
 *   - flag 枚举: 'auto' | 'both' | 'thirdPartyOnly' | 'firstPersonOnly'
 * VRM 0.x: extensions.VRM.firstPerson
 *   - firstPersonBone: nodeIndex, firstPersonBoneOffset: [x,y,z]
 *   - meshAnnotations: [{ mesh, firstPersonFlag }]
 *   - flag 枚举: 'Auto' | 'Both' | 'ThirdPersonOnly' | 'FirstPersonOnly'
 *
 * 本任务仅解析保存,不实现 Runtime(视角切换/网格遮罩)。
 *
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/spec/core/#first-person
 * - VRM 0.x: https://vrm.dev/vrm0/firstperson.html
 */

import { VrmVersion } from './VrmVersion';

/**
 * 网格遮罩标志(统一小写)。
 */
export enum VrmFirstPersonFlag {
  /** 自动判断(VRM 规范:头部以下第一人称隐藏,以上显示) */
  Auto = 'auto',
  /** 第一人称和第三人称都显示 */
  Both = 'both',
  /** 仅第三人称显示(第一人称隐藏) */
  ThirdPersonOnly = 'thirdPersonOnly',
  /** 仅第一人称显示(第三人称隐藏) */
  FirstPersonOnly = 'firstPersonOnly'
}

/**
 * 单个网格标注(遮罩规则)。
 */
export interface VrmMeshAnnotation {
  /**
   * 节点索引(VRM1: node;VRM0: 通过 mesh 反查节点)。
   * 若 VRM0 mesh 无法反查节点,此字段为 -1,meshIndex 有效。
   */
  nodeIndex: number;
  /** VRM 0.x mesh 索引(VRM1 为 -1) */
  meshIndex: number;
  /** 第一人称标志 */
  firstPersonFlag: VrmFirstPersonFlag;
  /** 第三人称标志(仅 VRM1) */
  thirdPersonFlag: VrmFirstPersonFlag | null;
}

/**
 * VRM FirstPerson 配置。
 */
export interface VrmFirstPerson {
  /** VRM 版本 */
  version: VrmVersion;
  /** 第一人称骨骼节点索引(VRM0: firstPersonBone;VRM1: 通过 humanoid.head 解析) */
  firstPersonBoneNodeIndex: number;
  /** 第一人称骨骼偏移 [x, y, z](VRM0: firstPersonBoneOffset;VRM1: 从 lookAt.offsetFromHeadBone 复用) */
  firstPersonBoneOffset: number[];
  /** 网格标注列表 */
  meshAnnotations: VrmMeshAnnotation[];
  /** 解析是否成功 */
  valid: boolean;
  /** 原始 firstPerson JSON 哈希 */
  firstPersonHash: string;
}

/**
 * 创建空 FirstPerson 配置。
 */
export function createEmptyVrmFirstPerson(version: VrmVersion): VrmFirstPerson {
  return {
    version: version,
    firstPersonBoneNodeIndex: -1,
    firstPersonBoneOffset: [0, 0, 0],
    meshAnnotations: [],
    valid: false,
    firstPersonHash: ''
  };
}
