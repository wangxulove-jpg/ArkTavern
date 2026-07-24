/**
 * VrmLookAt VRM 视线跟随配置
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 1.0: extensions.VRMC_vrm.lookAt
 *   - type: 'expression' | 'bone'
 *   - offsetFromHeadBone: [x, y, z]
 *   - rangeMapHorizontalInner/Outer/VerticalDown/Up: { inputMaxValue, outputScale }
 * VRM 0.x: extensions.VRM.firstPerson
 *   - firstPersonBone: nodeIndex, firstPersonBoneOffset: [x,y,z]
 *   - lookAtTypeName: 'BlendShape' | 'Bone'
 *   - lookAtHorizontalInner/Outer/VerticalDown/Up: { curve, xRange, yRange }
 *
 * 本任务仅解析保存,不实现 Runtime(视线驱动)。
 *
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/spec/core/#lookat
 * - VRM 0.x: https://vrm.dev/vrm0/lookat.html
 */

import { VrmVersion } from './VrmVersion';

/**
 * LookAt 实现类型。
 */
export enum VrmLookAtType {
  /** 通过表情 BlendShape 实现视线(VRM1: expression;VRM0: BlendShape) */
  Expression = 'expression',
  /** 通过骨骼旋转实现视线(VRM1: bone;VRM0: Bone) */
  Bone = 'bone'
}

/**
 * VRM 1.0 RangeMap(输入角度→输出权重/角度的线性映射)。
 */
export interface VrmLookAtRangeMap {
  /** 输入最大值(弧度) */
  inputMaxValue: number;
  /** 输出缩放(权重 0~1 或角度) */
  outputScale: number;
}

/**
 * VRM 0.x LookAt 曲线(VRM0 使用 AnimationCurve)。
 *
 * 0.x 的 curve 是 4 个数字 [x1, y1, x2, y2](贝塞尔控制点),
 * xRange/yRange 表示该方向的映射范围。
 */
export interface Vrm0LookAtCurve {
  /** 贝塞尔控制点 [x1, y1, x2, y2] */
  curve: number[];
  /** X 范围(角度) */
  xRange: number;
  /** Y 范围(权重/角度) */
  yRange: number;
}

/**
 * 统一 LookAt 配置。
 *
 * VRM 1.0 使用 rangeMap;VRM 0.x 使用 curve。
 * 两者都转换为统一 RangeMap 表示(0.x curve 暂保留原值供后续 runtime 使用)。
 */
export interface VrmLookAt {
  /** VRM 版本 */
  version: VrmVersion;
  /** 实现类型 */
  type: VrmLookAtType;
  /** 相对头部骨骼的偏移 [x, y, z](VRM1: offsetFromHeadBone;VRM0: firstPersonBoneOffset) */
  offsetFromHeadBone: number[];
  /** 头部骨骼节点索引(VRM0: firstPersonBone;VRM1: 通过 humanoid.head 解析) */
  headNodeIndex: number;

  /** 水平内侧(鼻子方向)RangeMap */
  rangeMapHorizontalInner: VrmLookAtRangeMap | null;
  /** 水平外侧(耳朵方向)RangeMap */
  rangeMapHorizontalOuter: VrmLookAtRangeMap | null;
  /** 垂直向下 RangeMap */
  rangeMapVerticalDown: VrmLookAtRangeMap | null;
  /** 垂直向上 RangeMap */
  rangeMapVerticalUp: VrmLookAtRangeMap | null;

  /** VRM 0.x 曲线(仅 VRM0 有,VRM1 为 null) */
  vrm0CurveHorizontalInner: Vrm0LookAtCurve | null;
  vrm0CurveHorizontalOuter: Vrm0LookAtCurve | null;
  vrm0CurveVerticalDown: Vrm0LookAtCurve | null;
  vrm0CurveVerticalUp: Vrm0LookAtCurve | null;

  /** 解析是否成功 */
  valid: boolean;
  /** 原始 lookAt JSON 哈希 */
  lookAtHash: string;
}

/**
 * 创建空 LookAt 配置。
 */
export function createEmptyVrmLookAt(version: VrmVersion): VrmLookAt {
  return {
    version: version,
    type: VrmLookAtType.Expression,
    offsetFromHeadBone: [0, 0, 0],
    headNodeIndex: -1,
    rangeMapHorizontalInner: null,
    rangeMapHorizontalOuter: null,
    rangeMapVerticalDown: null,
    rangeMapVerticalUp: null,
    vrm0CurveHorizontalInner: null,
    vrm0CurveHorizontalOuter: null,
    vrm0CurveVerticalDown: null,
    vrm0CurveVerticalUp: null,
    valid: false,
    lookAtHash: ''
  };
}
