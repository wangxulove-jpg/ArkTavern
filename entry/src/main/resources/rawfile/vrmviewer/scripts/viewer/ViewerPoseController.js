/**
 * ViewerPoseController — VRM 静态姿势控制器 (Phase 3D-2R)
 *
 * 职责:
 *   - 绑定当前 VRM (bindVrm), 含 VRM 0.x hips parent Y=PI 旋转
 *   - adaptPoseDocument: 格式识别 / 版本同步 / 坐标空间判定
 *   - 应用静态姿势到 VRM Humanoid normalized bones (via setNormalizedPose)
 *   - 恢复 VRM Humanoid 到 normalized rest pose
 *   - 记录当前 poseId
 *   - 模型替换时清空姿势状态 (unbindVrm), 含 VRM 0.x hips parent 复位
 *   - dispose
 *
 * 不做的事:
 *   - 不做姿势动画过渡 / CrossFade / 骨骼插值
 *   - 不解析 VRMA
 *   - 不做默认姿势持久化
 *   - 不按 Scene 节点名称全局搜索骨骼
 *   - 不直接覆盖 normalized bone quaternion (改用 setNormalizedPose)
 *
 * Humanoid API (确认自 vendor/pixiv/three-vrm.module.js 3.5.5):
 *   - vrm.humanoid.getNormalizedBoneNode(name) -> THREE.Object3D | null
 *   - vrm.humanoid.getRawBoneNode(name) -> THREE.Object3D | null
 *   - vrm.humanoid.resetNormalizedPose()
 *   - vrm.humanoid.setNormalizedPose(poseObject)
 *   - vrm.humanoid.getNormalizedPose() -> VRMPose
 *   - vrm.meta.metaVersion -> "0" | "1"
 *
 * setNormalizedPose 语义 (确认自 three-vrm.module.js setPose 实现):
 *   pose.rotation = node.quaternion * restRotation^-1  (getPose)
 *   node.quaternion = pose.rotation * restRotation       (setPose)
 * 故 pose 数据是 "相对于 rest pose 的 local delta", 不能直接覆盖 node.quaternion。
 *
 * OWNverse JSON 格式 (确认自 ownverse-vrm-viewer main.9ef94820.js):
 *   {
 *     "name": "A-shape",
 *     "vrmVersion": "0",
 *     "data": {
 *       "hips": { "rotation": [x, y, z, w] },
 *       "leftUpperArm": { "rotation": [x, y, z, w] },
 *       ...
 *     }
 *   }
 *   - data 字段即 VRMPose 格式, 直接传给 setNormalizedPose
 *   - vrmVersion "0" 表示该姿势针对 VRM 0.x 导出
 *   - 若模型 metaVersion !== pose vrmVersion, 需对 X/Z Euler 取反 (syncPoseDataBetweenVrmVersion)
 *   - VRM 0.x 模型加载时需将 hips raw bone parent 旋转 PI (setInitPose)
 *
 * Reference:
 *   - three-vrm.module.js (VRMHumanoid.setNormalizedPose / getNormalizedPose / resetNormalizedPose)
 *   - ownverse-vrm-viewer/main.9ef94820.js (setInitPose / setPose / syncPoseDataBetweenVrmVersion / resetInitPose)
 *   - ViewerAnimationController.js (状态机 / dispose / bindVrm 模式参考)
 */

import * as THREE from 'three';

// ===== 状态枚举 =====
export var PoseState = {
  IDLE: 'IDLE',
  APPLIED: 'APPLIED',
  FAILED: 'FAILED',
  DISPOSED: 'DISPOSED'
};

// ===== 错误代码 =====
export var PoseErrorCode = {
  CONTROLLER_DISPOSED: 'POSE_CONTROLLER_DISPOSED',
  VRM_MISSING: 'POSE_VRM_MISSING',
  VRM_INVALID: 'POSE_VRM_INVALID',
  POSE_DATA_INVALID: 'POSE_DATA_INVALID',
  POSE_BONES_MISSING: 'POSE_BONES_MISSING',
  POSE_ROTATION_INVALID: 'POSE_ROTATION_INVALID',
  POSE_NO_VALID_BONES: 'POSE_NO_VALID_BONES',
  POSE_HUMANOID_MISSING: 'POSE_HUMANOID_MISSING',
  POSE_ROTATION_ORDER_UNSUPPORTED: 'POSE_ROTATION_ORDER_UNSUPPORTED',
  POSE_COORDINATE_SPACE_UNSUPPORTED: 'POSE_COORDINATE_SPACE_UNSUPPORTED',
  POSE_POSITION_INVALID: 'POSE_POSITION_INVALID',
  POSE_CONVERSION_FAILED: 'POSE_CONVERSION_FAILED'
};

/**
 * 四元数长度下限,低于此值视为零四元数并拒绝。
 */
var MIN_QUATERNION_LENGTH = 1e-6;

/**
 * 可识别的姿势数据入口字段名。
 * 'data' 用于兼容 VRoid Studio / OWNverse 导出格式 (顶层 data 字段封装骨骼 map)。
 */
var RECOGNIZED_POSE_ENTRY_FIELDS = ['bones', 'humanBones', 'pose', 'data'];

/**
 * hips 位置位移上限 (米),超过视为异常并拒绝。
 */
var MAX_HIPS_POSITION_MAGNITUDE = 10.0;

/**
 * 构造错误对象。
 */
function makeError(code, message) {
  return { code: code, message: message };
}

/**
 * ViewerPoseController 构造函数。
 *
 * @param {object} options
 * @param {function} options.getCurrentVrm 返回当前 VRM 对象 (由 ViewerCore 注入)
 */
export class ViewerPoseController {
  constructor(options) {
    /** @type {PoseState} */
    this._state = PoseState.IDLE;
    /** @type {object|null} 当前绑定的 VRM */
    this.currentVrm = null;
    /** @type {string} 当前已应用的 poseId (空字符串表示无应用) */
    this.currentPoseId = '';
    /** @type {string} 当前已应用的 displayName */
    this.currentDisplayName = '';
    /** @type {number} 最近一次应用的有效骨骼数 */
    this.appliedBoneCount = 0;
    /** @type {number} 最近一次应用的忽略骨骼数 (未知骨骼 + 非法 rotation) */
    this.ignoredBoneCount = 0;
    /** @type {number} 最近一次版本同步转换的骨骼数 */
    this.convertedBoneCount = 0;
    /** @type {string} 最近一次错误码 */
    this.lastErrorCode = '';
    /** @type {string} 最近一次错误消息 */
    this.lastErrorMessage = '';
    /** @type {string[]} 最近一次忽略的骨骼名列表 (前 20 条,用于 Debug) */
    this.lastIgnoredBones = [];
    /** @type {string} 最近一次姿势来源格式 */
    this.sourceFormat = '';
    /** @type {string} 最近一次坐标空间 */
    this.coordinateSpace = '';
    /** @type {string} 最近一次旋转顺序 */
    this.rotationOrder = 'XYZW';
    /** @type {boolean} 最近一次是否存在 position */
    this.positionPresent = false;
    /** @type {boolean} 最近一次是否应用了 position */
    this.positionApplied = false;
    /** @type {boolean} VRM 0.x hips parent 是否已旋转 */
    this._vrm0HipsRotated = false;
    /** @type {function} 获取当前 VRM 的回调 (由 ViewerCore 注入) */
    this._getCurrentVrm = (options && typeof options.getCurrentVrm === 'function')
      ? options.getCurrentVrm
      : function () { return null; };
    /** @type {boolean} 是否已销毁 */
    this._disposed = false;
    // 复用临时对象,避免每次创建
    this._tmpQuat = new THREE.Quaternion();
    this._tmpEuler = new THREE.Euler();
  }

  /**
   * 初始化控制器。幂等。
   * @returns {{success: boolean, state: PoseState}}
   */
  initialize() {
    if (this._disposed) {
      return { success: false, state: PoseState.DISPOSED };
    }
    if (this._state === PoseState.IDLE || this._state === PoseState.FAILED) {
      this._state = PoseState.IDLE;
      this.lastErrorCode = '';
      this.lastErrorMessage = '';
    }
    return { success: true, state: this._state };
  }

  /**
   * 绑定 VRM。
   *
   * 对 VRM 0.x 模型 (metaVersion === "0"), 将 hips raw bone 的 parent 旋转 PI (绕 Y 轴),
   * 与 OWNverse setInitPose 行为一致。
   *
   * @param {object} vrm
   * @returns {{success: boolean, state: PoseState, error?: object}}
   */
  bindVrm(vrm) {
    if (this._disposed) {
      return {
        success: false,
        state: PoseState.DISPOSED,
        error: makeError(PoseErrorCode.CONTROLLER_DISPOSED, 'controller disposed')
      };
    }
    if (!vrm) {
      return {
        success: false,
        state: this._state,
        error: makeError(PoseErrorCode.VRM_INVALID, 'vrm is null')
      };
    }
    // 若已有旧 VRM,先解绑 (含 VRM 0.x hips parent 复位)
    if (this.currentVrm && this.currentVrm !== vrm) {
      this._clearInternalState();
    }
    this.currentVrm = vrm;

    // VRM 0.x: hips parent 旋转 PI (与 OWNverse setInitPose 一致)
    this._applyVrm0HipsRotation(vrm);

    // 不自动应用姿势
    this._state = PoseState.IDLE;
    this.currentPoseId = '';
    this.currentDisplayName = '';
    this.appliedBoneCount = 0;
    this.ignoredBoneCount = 0;
    this.convertedBoneCount = 0;
    this.lastIgnoredBones = [];
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    return { success: true, state: this._state };
  }

  /**
   * 解绑当前 VRM。
   *
   * 对 VRM 0.x 模型, 复位 hips parent Y 旋转为 0 (与 OWNverse resetInitPose 一致)。
   *
   * @returns {{success: boolean, state: PoseState}}
   */
  unbindVrm() {
    if (this._disposed) {
      return { success: false, state: PoseState.DISPOSED };
    }
    this._clearInternalState();
    return { success: true, state: this._state };
  }

  /**
   * 应用静态姿势。
   *
   * 前置条件:
   *   - Controller 未 dispose
   *   - currentVrm 存在
   *   - currentVrm.humanoid 存在
   *   - poseData 合法 (经 adaptPoseDocument 适配后)
   *
   * 应用顺序:
   *   1. adaptPoseDocument (格式识别 + 版本同步)
   *   2. resetNormalizedPose()
   *   3. setNormalizedPose(adaptedPose)
   *   4. (可选) 应用 hips position
   *   5. 记录 currentPoseId / state = APPLIED
   *
   * 同一姿势可以重复应用, 不会产生漂移 (每次先 resetNormalizedPose)。
   *
   * @param {object} poseData 姿势数据对象
   * @returns {{success: boolean, state: PoseState, poseId?: string, appliedBoneCount?: number, ignoredBoneCount?: number, error?: object}}
   */
  applyPose(poseData) {
    if (this._disposed) {
      return {
        success: false,
        state: PoseState.DISPOSED,
        error: makeError(PoseErrorCode.CONTROLLER_DISPOSED, 'controller disposed')
      };
    }
    if (!this.currentVrm) {
      this._recordFailure(PoseErrorCode.VRM_MISSING, 'currentVrm is null');
      return {
        success: false,
        state: this._state,
        error: makeError(PoseErrorCode.VRM_MISSING, 'currentVrm is null')
      };
    }
    var humanoid = this.currentVrm.humanoid;
    if (!humanoid || typeof humanoid.getNormalizedBoneNode !== 'function' ||
        typeof humanoid.resetNormalizedPose !== 'function' ||
        typeof humanoid.setNormalizedPose !== 'function') {
      this._recordFailure(PoseErrorCode.POSE_HUMANOID_MISSING, 'humanoid missing or API incomplete');
      return {
        success: false,
        state: this._state,
        error: makeError(PoseErrorCode.POSE_HUMANOID_MISSING, 'humanoid missing or API incomplete')
      };
    }

    // 1. adaptPoseDocument: 格式识别 + 版本同步
    var adapted;
    try {
      adapted = this.adaptPoseDocument(poseData, this.currentVrm);
    } catch (e) {
      var adaptMsg = e && e.message ? e.message : String(e);
      this._recordFailure(PoseErrorCode.POSE_CONVERSION_FAILED, 'adaptPoseDocument threw: ' + adaptMsg);
      return {
        success: false,
        state: this._state,
        error: makeError(PoseErrorCode.POSE_CONVERSION_FAILED, 'adaptPoseDocument threw: ' + adaptMsg)
      };
    }
    if (!adapted.success) {
      this._recordFailure(adapted.error.code, adapted.error.message);
      return {
        success: false,
        state: this._state,
        error: adapted.error
      };
    }

    var poseId = adapted.poseId;
    var displayName = adapted.displayName;
    var vrmPose = adapted.vrmPose; // { boneName: { rotation: [x,y,z,w], position?: [x,y,z] } }
    var validBoneCount = adapted.validBoneCount;
    var ignoredCount = adapted.ignoredBoneCount;
    var convertedCount = adapted.convertedBoneCount;
    var hipsPosition = adapted.hipsPosition; // number[] | null

    if (validBoneCount === 0) {
      this._recordFailure(PoseErrorCode.POSE_NO_VALID_BONES, 'no valid bones after adaptation');
      return {
        success: false,
        state: this._state,
        error: makeError(PoseErrorCode.POSE_NO_VALID_BONES, 'no valid bones after adaptation')
      };
    }

    // 2. resetNormalizedPose()
    try {
      humanoid.resetNormalizedPose();
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      this._recordFailure(PoseErrorCode.POSE_HUMANOID_MISSING, 'resetNormalizedPose threw: ' + msg);
      return {
        success: false,
        state: this._state,
        error: makeError(PoseErrorCode.POSE_HUMANOID_MISSING, 'resetNormalizedPose threw: ' + msg)
      };
    }

    // 3. setNormalizedPose(vrmPose) — 使用 three-vrm 标准 API, 不直接覆盖 quaternion
    try {
      humanoid.setNormalizedPose(vrmPose);
    } catch (e) {
      var setMsg = e && e.message ? e.message : String(e);
      this._recordFailure(PoseErrorCode.POSE_HUMANOID_MISSING, 'setNormalizedPose threw: ' + setMsg);
      return {
        success: false,
        state: this._state,
        error: makeError(PoseErrorCode.POSE_HUMANOID_MISSING, 'setNormalizedPose threw: ' + setMsg)
      };
    }

    // 4. (可选) 应用 hips position
    var posApplied = false;
    if (hipsPosition && hipsPosition.length === 3) {
      var hipsNode = null;
      try {
        hipsNode = humanoid.getNormalizedBoneNode('hips');
      } catch (_e) {
        hipsNode = null;
      }
      if (hipsNode && hipsNode.position) {
        try {
          hipsNode.position.set(hipsPosition[0], hipsPosition[1], hipsPosition[2]);
          if (typeof hipsNode.updateMatrix === 'function') {
            hipsNode.updateMatrix();
          }
          posApplied = true;
        } catch (e) {
          console.warn('[ViewerPoseController] apply hips.position threw: ' +
            (e && e.message ? e.message : String(e)));
        }
      }
    }

    // 5. 记录 currentPoseId / state = APPLIED
    this.currentPoseId = poseId;
    this.currentDisplayName = displayName;
    this.appliedBoneCount = validBoneCount;
    this.ignoredBoneCount = ignoredCount;
    this.convertedBoneCount = convertedCount;
    this.lastIgnoredBones = adapted.ignoredBones.slice(0, 20);
    this.sourceFormat = adapted.sourceFormat;
    this.coordinateSpace = adapted.coordinateSpace;
    this.rotationOrder = adapted.rotationOrder;
    this.positionPresent = adapted.positionPresent;
    this.positionApplied = posApplied;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    this._state = PoseState.APPLIED;

    return {
      success: true,
      state: this._state,
      poseId: poseId,
      displayName: displayName,
      appliedBoneCount: validBoneCount,
      ignoredBoneCount: ignoredCount,
      convertedBoneCount: convertedCount
    };
  }

  /**
   * 恢复 VRM Humanoid 到 normalized rest pose。
   *
   * 执行:
   *   currentVrm.humanoid.resetNormalizedPose()
   *   currentPoseId = ''
   *   state = IDLE
   *
   * 恢复失败不影响 ViewerState / ModelState / AnimationState。
   *
   * @returns {{success: boolean, state: PoseState, error?: object}}
   */
  resetPose() {
    if (this._disposed) {
      return {
        success: false,
        state: PoseState.DISPOSED,
        error: makeError(PoseErrorCode.CONTROLLER_DISPOSED, 'controller disposed')
      };
    }
    if (!this.currentVrm) {
      this._resetPoseStateOnly();
      return { success: true, state: this._state };
    }
    var humanoid = this.currentVrm.humanoid;
    if (!humanoid || typeof humanoid.resetNormalizedPose !== 'function') {
      this._recordFailure(PoseErrorCode.POSE_HUMANOID_MISSING, 'humanoid missing or resetNormalizedPose unavailable');
      return {
        success: false,
        state: this._state,
        error: makeError(PoseErrorCode.POSE_HUMANOID_MISSING, 'humanoid missing or resetNormalizedPose unavailable')
      };
    }
    try {
      humanoid.resetNormalizedPose();
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      this._recordFailure(PoseErrorCode.POSE_HUMANOID_MISSING, 'resetNormalizedPose threw: ' + msg);
      return {
        success: false,
        state: this._state,
        error: makeError(PoseErrorCode.POSE_HUMANOID_MISSING, 'resetNormalizedPose threw: ' + msg)
      };
    }
    this._resetPoseStateOnly();
    return { success: true, state: this._state };
  }

  /**
   * 姿势适配器: 识别来源格式, 执行版本同步, 输出统一 VRMPose。
   *
   * @param {object} sourceDocument 原始姿势文档 (含 poseId/displayName/bones 或 data 等)
   * @param {object} currentVrm 当前 VRM
   * @returns {{success: boolean, poseId?: string, displayName?: string, sourceFormat?: string,
   *           coordinateSpace?: string, rotationOrder?: string, positionPresent?: boolean,
   *           vrmPose?: object, validBoneCount?: number, ignoredBoneCount?: number,
   *           convertedBoneCount?: number, hipsPosition?: number[]|null, ignoredBones?: string[],
   *           error?: object}}
   */
  adaptPoseDocument(sourceDocument, currentVrm) {
    if (!sourceDocument || typeof sourceDocument !== 'object') {
      return {
        success: false,
        error: makeError(PoseErrorCode.POSE_DATA_INVALID, 'sourceDocument is not an object')
      };
    }

    var poseId = String(sourceDocument.poseId || '');
    var displayName = String(sourceDocument.displayName || '');

    // 抽取 bones map (兼容 bones / humanBones / pose / data)
    var bonesMap = null;
    var sourceFormat = '';
    for (var i = 0; i < RECOGNIZED_POSE_ENTRY_FIELDS.length; i++) {
      var field = RECOGNIZED_POSE_ENTRY_FIELDS[i];
      var v = sourceDocument[field];
      if (v && typeof v === 'object' && !Array.isArray(v)) {
        var keys = Object.keys(v);
        if (keys.length > 0) {
          bonesMap = v;
          sourceFormat = field;
          break;
        }
      }
    }

    if (!bonesMap) {
      return {
        success: false,
        error: makeError(PoseErrorCode.POSE_BONES_MISSING, 'no recognized bones/humanBones/pose/data field')
      };
    }

    // 获取模型 metaVersion 和姿势 vrmVersion
    var modelMetaVersion = '';
    if (currentVrm && currentVrm.meta && currentVrm.meta.metaVersion) {
      modelMetaVersion = String(currentVrm.meta.metaVersion);
    }
    var poseVrmVersion = String(sourceDocument.vrmVersion || '');
    var needVersionSync = (modelMetaVersion.length > 0 && poseVrmVersion.length > 0 &&
                           modelMetaVersion !== poseVrmVersion);

    // 遍历 bonesMap, 解析 rotation, 可选 position, 执行版本同步
    var vrmPose = {};
    var validBoneCount = 0;
    var ignoredCount = 0;
    var convertedCount = 0;
    var ignoredBones = [];
    var hipsPosition = null;
    var positionPresent = false;

    var boneNames = Object.keys(bonesMap);
    for (var j = 0; j < boneNames.length; j++) {
      var boneName = boneNames[j];
      if (typeof boneName !== 'string' || boneName.length === 0) {
        console.warn('[ViewerPoseController] bone name empty, skipped');
        continue;
      }
      var boneEntry = bonesMap[boneName];
      if (!boneEntry || typeof boneEntry !== 'object') {
        console.warn('[ViewerPoseController] bone "' + boneName + '" entry not an object, skipped');
        ignoredCount++;
        if (ignoredBones.length < 20) ignoredBones.push(boneName);
        continue;
      }

      var quat = this._parseRotation(boneEntry.rotation);
      if (!quat) {
        console.warn('[ViewerPoseController] bone "' + boneName + '" rotation invalid, skipped');
        ignoredCount++;
        if (ignoredBones.length < 20) ignoredBones.push(boneName);
        continue;
      }

      // 版本同步: 对 X 和 Z Euler 角取反 (与 OWNverse syncPoseDataBetweenVrmVersion 一致)
      if (needVersionSync) {
        quat = this._syncQuaternionVersion(quat);
        convertedCount++;
      }

      var poseEntry = { rotation: quat };

      // position 处理 (仅 hips)
      if (boneEntry.position !== undefined && boneEntry.position !== null) {
        positionPresent = true;
        var pos = this._parsePosition(boneEntry.position);
        if (pos && boneName === 'hips') {
          hipsPosition = pos;
          poseEntry.position = pos;
        } else if (pos && boneName !== 'hips') {
          // 非 hips 骨骼的 position 本阶段忽略, 记录 warning
          console.warn('[ViewerPoseController] bone "' + boneName + '" has position but only hips is supported, position ignored');
        }
      }

      vrmPose[boneName] = poseEntry;
      validBoneCount++;
    }

    return {
      success: true,
      poseId: poseId,
      displayName: displayName,
      sourceFormat: sourceFormat,
      coordinateSpace: 'normalized-local',
      rotationOrder: 'XYZW',
      positionPresent: positionPresent,
      vrmPose: vrmPose,
      validBoneCount: validBoneCount,
      ignoredBoneCount: ignoredCount,
      convertedBoneCount: convertedCount,
      hipsPosition: hipsPosition,
      ignoredBones: ignoredBones
    };
  }

  /**
   * 获取当前姿势状态。
   */
  getPoseState() {
    return {
      success: true,
      state: this._state,
      poseId: this.currentPoseId,
      displayName: this.currentDisplayName,
      appliedBoneCount: this.appliedBoneCount,
      ignoredBoneCount: this.ignoredBoneCount
    };
  }

  /**
   * 获取姿势系统调试状态快照。
   */
  getPoseDebugState() {
    return {
      success: true,
      debugState: {
        state: this._state,
        vrmBound: !!this.currentVrm,
        currentPoseId: this.currentPoseId,
        currentDisplayName: this.currentDisplayName,
        appliedBoneCount: this.appliedBoneCount,
        ignoredBoneCount: this.ignoredBoneCount,
        convertedBoneCount: this.convertedBoneCount,
        lastIgnoredBones: this.lastIgnoredBones.slice(),
        sourceFormat: this.sourceFormat,
        coordinateSpace: this.coordinateSpace,
        rotationOrder: this.rotationOrder,
        positionPresent: this.positionPresent,
        positionApplied: this.positionApplied,
        lastErrorCode: this.lastErrorCode,
        lastErrorMessage: this.lastErrorMessage
      }
    };
  }

  /**
   * 销毁控制器。
   */
  dispose() {
    if (this._disposed) return;
    this._disposed = true;
    this._clearInternalState();
    this._state = PoseState.DISPOSED;
  }

  /** @returns {PoseState} */
  getState() {
    return this._state;
  }

  // ===== 内部方法 =====

  /**
   * VRM 0.x: 将 hips raw bone parent 旋转 PI (绕 Y 轴)。
   * 与 OWNverse setInitPose 一致。
   */
  _applyVrm0HipsRotation(vrm) {
    if (!vrm || !vrm.humanoid || typeof vrm.humanoid.getRawBoneNode !== 'function') {
      return;
    }
    var metaVersion = '';
    if (vrm.meta && vrm.meta.metaVersion) {
      metaVersion = String(vrm.meta.metaVersion);
    }
    if (metaVersion !== '0') {
      return;
    }
    try {
      var hipsNode = vrm.humanoid.getRawBoneNode('hips');
      if (hipsNode && hipsNode.parent) {
        hipsNode.parent.rotation.y = Math.PI;
        if (typeof hipsNode.parent.updateWorldMatrix === 'function') {
          hipsNode.parent.updateWorldMatrix(true, true);
        }
        if (typeof hipsNode.parent.updateMatrixWorld === 'function') {
          hipsNode.parent.updateMatrixWorld(true);
        }
        this._vrm0HipsRotated = true;
      }
    } catch (e) {
      console.warn('[ViewerPoseController] _applyVrm0HipsRotation threw: ' +
        (e && e.message ? e.message : String(e)));
    }
  }

  /**
   * VRM 0.x: 复位 hips raw bone parent Y 旋转为 0。
   * 与 OWNverse resetInitPose 一致。
   */
  _resetVrm0HipsRotation() {
    if (!this._vrm0HipsRotated || !this.currentVrm) {
      return;
    }
    try {
      var humanoid = this.currentVrm.humanoid;
      if (humanoid && typeof humanoid.getRawBoneNode === 'function') {
        var hipsNode = humanoid.getRawBoneNode('hips');
        if (hipsNode && hipsNode.parent) {
          hipsNode.parent.rotation.y = 0;
          if (typeof humanoid.resetRawPose === 'function') {
            humanoid.resetRawPose();
          }
          if (typeof hipsNode.parent.updateWorldMatrix === 'function') {
            hipsNode.parent.updateWorldMatrix(true, true);
          }
          if (typeof hipsNode.parent.updateMatrixWorld === 'function') {
            hipsNode.parent.updateMatrixWorld(true);
          }
        }
      }
    } catch (e) {
      console.warn('[ViewerPoseController] _resetVrm0HipsRotation threw: ' +
        (e && e.message ? e.message : String(e)));
    }
    this._vrm0HipsRotated = false;
  }

  /**
   * 版本同步: 对四元数转换为 Euler, 对 X 和 Z 取反, 再转回四元数。
   * 与 OWNverse syncPoseDataBetweenVrmVersion 一致。
   *
   * @param {number[]} quat [x, y, z, w]
   * @returns {number[]} 转换后的 [x, y, z, w]
   */
  _syncQuaternionVersion(quat) {
    this._tmpQuat.set(quat[0], quat[1], quat[2], quat[3]);
    this._tmpEuler.setFromQuaternion(this._tmpQuat, 'XYZ');
    this._tmpEuler.x *= -1;
    this._tmpEuler.z *= -1;
    this._tmpQuat.setFromEuler(this._tmpEuler);
    return [this._tmpQuat.x, this._tmpQuat.y, this._tmpQuat.z, this._tmpQuat.w];
  }

  /**
   * 解析 rotation 为 [x, y, z, w] 数组。
   *
   * 支持格式:
   *   - [x, y, z, w] 数组
   *   - { x, y, z, w } 对象
   *
   * 验证:
   *   - 必须有 4 个有限数字
   *   - 四元数长度不能接近 0
   */
  _parseRotation(rotation) {
    if (rotation === null || rotation === undefined) {
      return null;
    }
    var x, y, z, w;
    if (Array.isArray(rotation)) {
      if (rotation.length !== 4) return null;
      x = rotation[0];
      y = rotation[1];
      z = rotation[2];
      w = rotation[3];
    } else if (typeof rotation === 'object') {
      x = rotation.x;
      y = rotation.y;
      z = rotation.z;
      w = rotation.w;
    } else {
      return null;
    }
    if (typeof x !== 'number' || typeof y !== 'number' ||
        typeof z !== 'number' || typeof w !== 'number') {
      return null;
    }
    if (!isFinite(x) || !isFinite(y) || !isFinite(z) || !isFinite(w)) {
      return null;
    }
    var lengthSq = x * x + y * y + z * z + w * w;
    if (lengthSq < MIN_QUATERNION_LENGTH * MIN_QUATERNION_LENGTH) {
      return null;
    }
    return [x, y, z, w];
  }

  /**
   * 解析 position 为 [x, y, z] 数组。
   *
   * 支持格式:
   *   - [x, y, z] 数组
   *   - { x, y, z } 对象
   *
   * 验证:
   *   - 必须有 3 个有限数字
   *   - 位移幅度不能超过 MAX_HIPS_POSITION_MAGNITUDE
   */
  _parsePosition(position) {
    if (position === null || position === undefined) {
      return null;
    }
    var x, y, z;
    if (Array.isArray(position)) {
      if (position.length !== 3) return null;
      x = position[0];
      y = position[1];
      z = position[2];
    } else if (typeof position === 'object') {
      x = position.x;
      y = position.y;
      z = position.z;
    } else {
      return null;
    }
    if (typeof x !== 'number' || typeof y !== 'number' || typeof z !== 'number') {
      return null;
    }
    if (!isFinite(x) || !isFinite(y) || !isFinite(z)) {
      return null;
    }
    var mag = Math.sqrt(x * x + y * y + z * z);
    if (mag > MAX_HIPS_POSITION_MAGNITUDE) {
      console.warn('[ViewerPoseController] hips position magnitude too large: ' + mag);
      return null;
    }
    return [x, y, z];
  }

  /**
   * 清空内部姿势状态, 含 VRM 0.x hips parent 复位。
   */
  _clearInternalState() {
    // VRM 0.x hips parent 复位
    if (this._vrm0HipsRotated) {
      this._resetVrm0HipsRotation();
    }
    this.currentVrm = null;
    this.currentPoseId = '';
    this.currentDisplayName = '';
    this.appliedBoneCount = 0;
    this.ignoredBoneCount = 0;
    this.convertedBoneCount = 0;
    this.lastIgnoredBones = [];
    this.sourceFormat = '';
    this.coordinateSpace = '';
    this.positionPresent = false;
    this.positionApplied = false;
    if (this._state !== PoseState.DISPOSED) {
      this._state = PoseState.IDLE;
    }
  }

  /**
   * 仅重置姿势状态字段 (不触碰 VRM)。
   */
  _resetPoseStateOnly() {
    this.currentPoseId = '';
    this.currentDisplayName = '';
    this.appliedBoneCount = 0;
    this.ignoredBoneCount = 0;
    this.convertedBoneCount = 0;
    this.lastIgnoredBones = [];
    this.sourceFormat = '';
    this.coordinateSpace = '';
    this.positionPresent = false;
    this.positionApplied = false;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    this._state = PoseState.IDLE;
  }

  /**
   * 记录失败 (更新 state=FAILED + lastError)。
   */
  _recordFailure(code, message) {
    this._state = PoseState.FAILED;
    this.lastErrorCode = code;
    this.lastErrorMessage = String(message || '');
  }
}
