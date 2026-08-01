/**
 * ViewerAnimationController — VRM 动画运行时控制器 (Phase 3A 骨架)
 *
 * 职责:
 *   - 持有 AnimationMixer / currentAction / currentClip / 动画状态机
 *   - bindVrm(vrm): 绑定 VRM 模型,创建 AnimationMixer(vrm.scene)
 *   - unbindVrm(): 解绑 VRM,停止并释放 Mixer
 *   - update(deltaSeconds): 每帧更新(由 ViewerFrameLoop 调用)
 *   - getState() / getDebugState(): 只读状态查询
 *   - dispose(): 销毁并释放所有资源(不销毁 VRM 模型本身)
 *
 * 不做的事 (Phase 3A 骨架限制):
 *   - 不加载 VRMA 文件 (依赖已就绪但导入流程未实现)
 *   - 不创建 AnimationClip (createVRMAnimationClip 未实际调用)
 *   - 不实际播放动画 (state 不会进入 PLAYING)
 *   - 不提供 play/pause/stop/seek 控制方法
 *   - 不持有 ViewerCore 引用 (仅通过构造参数 getCurrentVrm 获取当前 VRM)
 *
 * 依赖:
 *   - THREE.AnimationMixer (three.js core 0.176.0, 已可用)
 *   - @pixiv/three-vrm-animation 3.5.5 (已安装,静态 import 用于依赖探测;
 *     VRMAnimationLoaderPlugin / createVRMAnimationClip 本阶段不实际调用)
 *
 * Phase 3A 依赖补齐:
 *   - 静态 import { VRMAnimationLoaderPlugin, createVRMAnimationClip } from '@pixiv/three-vrm-animation'
 *   - 通过 getDependencyState() 暴露只读依赖状态
 *   - 不暴露 Node 模块路径、本机绝对路径、完整 package.json、许可证全文
 *   - 不注册 VRMAnimationLoaderPlugin 到生产 GLTFLoader
 *   - 不调用 createVRMAnimationClip
 *
 * Reference:
 *   - figure-main/index.html:937-938 currentMixer = new THREE.AnimationMixer(vrm.scene)
 *   - figure-main/index.html:858-861 disposeVrm: stopAllAction + set undefined
 *   - figure-main/index.html:2876→2880 vrm.update → mixer.update (更新顺序)
 *   - ownverse-vrm-viewer Avatar class: mixer 封装在独立类中(非全局变量)
 *   - AGENTS.md Phase 3A §十~§二十四 规范
 *
 * 状态机 (AnimationState):
 *   UNINITIALIZED → IDLE (initialize)
 *   IDLE → LOADING (loadAnimation, Phase 3A 未实现)
 *   LOADING → READY (clip 准备完成, Phase 3A 未实现)
 *   READY → PLAYING (play, Phase 3A 未实现)
 *   PLAYING → PAUSED (pause, Phase 3A 未实现)
 *   PLAYING/PAUSED → STOPPED (stop, Phase 3A 未实现)
 *   任意 → FAILED (错误,不影响 ViewerState/ModelState)
 *   任意 → DISPOSED (dispose)
 *
 * Phase 3A 实际使用的状态:
 *   UNINITIALIZED → IDLE (initialize)
 *   IDLE (bindVrm 后仍为 IDLE,无 clip)
 *   任意 → DISPOSED (dispose)
 *   任意 → FAILED (错误,仅记录,不阻塞 Viewer)
 */
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import {
  VRMAnimationLoaderPlugin,
  createVRMAnimationClip
} from '@pixiv/three-vrm-animation';

// ===== 动画状态枚举 (与 ArkTS ArkWebAnimationState 对齐) =====
export var AnimationState = Object.freeze({
  UNINITIALIZED: 'UNINITIALIZED',
  IDLE: 'IDLE',
  LOADING: 'LOADING',
  READY: 'READY',
  PLAYING: 'PLAYING',
  PAUSED: 'PAUSED',
  STOPPED: 'STOPPED',
  FAILED: 'FAILED',
  DISPOSED: 'DISPOSED'
});

// ===== 错误代码 (与 ArkTS ArkWebAnimationErrorCode 对齐) =====
export var ANIMATION_ERR_DISPOSED = 'ANIMATION_CONTROLLER_DISPOSED';
export var ANIMATION_ERR_NOT_INITIALIZED = 'ANIMATION_NOT_INITIALIZED';
export var ANIMATION_ERR_VRM_MISSING = 'ANIMATION_VRM_MISSING';
export var ANIMATION_ERR_VRM_INVALID = 'ANIMATION_VRM_INVALID';
export var ANIMATION_ERR_MIXER_CREATION_FAILED = 'ANIMATION_MIXER_CREATION_FAILED';
export var ANIMATION_ERR_DELTA_INVALID = 'ANIMATION_DELTA_INVALID';
export var ANIMATION_ERR_DEPENDENCY_MISSING = 'ANIMATION_DEPENDENCY_MISSING';
export var ANIMATION_ERR_UNSUPPORTED = 'ANIMATION_UNSUPPORTED';
export var ANIMATION_ERR_DEPENDENCY_VERSION_MISMATCH = 'ANIMATION_DEPENDENCY_VERSION_MISMATCH';
export var ANIMATION_ERR_DEPENDENCY_EXPORT_MISSING = 'ANIMATION_DEPENDENCY_EXPORT_MISSING';
export var ANIMATION_ERR_DEPENDENCY_BUILD_FAILED = 'ANIMATION_DEPENDENCY_BUILD_FAILED';
export var ANIMATION_ERR_DEPENDENCY_LICENSE_MISSING = 'ANIMATION_DEPENDENCY_LICENSE_MISSING';

// Phase 3A — VRMA 文件导入与最小播放闭环: 新增错误码
export var ANIMATION_ERR_RESOURCE_INVALID = 'ANIMATION_RESOURCE_INVALID';
export var ANIMATION_ERR_RESOURCE_URL_INVALID = 'ANIMATION_RESOURCE_URL_INVALID';
export var ANIMATION_ERR_RESOURCE_SIZE_INVALID = 'ANIMATION_RESOURCE_SIZE_INVALID';
export var ANIMATION_ERR_LOAD_IN_PROGRESS = 'ANIMATION_LOAD_IN_PROGRESS';
export var ANIMATION_ERR_DATA_MISSING = 'ANIMATION_DATA_MISSING';
export var ANIMATION_ERR_CLIP_CREATION_FAILED = 'ANIMATION_CLIP_CREATION_FAILED';
export var ANIMATION_ERR_CLIP_INVALID = 'ANIMATION_CLIP_INVALID';
export var ANIMATION_ERR_CLIP_EMPTY = 'ANIMATION_CLIP_EMPTY';
export var ANIMATION_ERR_NOT_READY = 'ANIMATION_NOT_READY';
export var ANIMATION_ERR_ALREADY_PLAYING = 'ANIMATION_ALREADY_PLAYING';
export var ANIMATION_ERR_ACTION_MISSING = 'ANIMATION_ACTION_MISSING';
export var ANIMATION_ERR_PAUSE_INVALID_STATE = 'ANIMATION_PAUSE_INVALID_STATE';
export var ANIMATION_ERR_STOP_INVALID_STATE = 'ANIMATION_STOP_INVALID_STATE';
export var ANIMATION_ERR_POSE_RESET_WARNING = 'ANIMATION_POSE_RESET_WARNING';
export var ANIMATION_ERR_STALE_RESULT = 'ANIMATION_STALE_RESULT';
export var ANIMATION_ERR_LOAD_FAILED = 'ANIMATION_LOAD_FAILED';

// 受控动画资源 URL 前缀 (与 ArkWebAnimationResourceProvider 对齐)
var ANIMATION_RESOURCE_URL_PREFIX = 'https://ark-tavern.local/animation/';

// ===== 依赖元数据 (只读,不暴露本机路径) =====
// 精确版本必须与 tools/vrm-vendor/package.json 锁定值一致。
var ANIMATION_DEPENDENCY_PACKAGE_NAME = '@pixiv/three-vrm-animation';
var ANIMATION_DEPENDENCY_VERSION = '3.5.5';

/**
 * 构造错误对象。
 * @param {string} code
 * @param {string} message
 * @returns {{code: string, message: string}}
 */
function makeAnimError(code, message) {
  return { code: code, message: message };
}

export class ViewerAnimationController {
  /**
   * @param {object} options
   * @param {function(): (object|null)} options.getCurrentVrm 返回当前 VRM 根对象(由 ViewerCore 提供)
   */
  constructor(options) {
    /** @type {string} */
    this._state = AnimationState.UNINITIALIZED;
    /** @type {object|null} 当前绑定的 VRM 根对象(不拥有,仅引用) */
    this.currentVrm = null;
    /** @type {THREE.AnimationMixer|null} */
    this.mixer = null;
    /** @type {THREE.AnimationClip|null} */
    this.currentClip = null;
    /** @type {THREE.AnimationAction|null} */
    this.currentAction = null;
    /** @type {string} 当前动画名称 */
    this.currentAnimationName = '';
    /** @type {number} 动画总时长(秒) */
    this.duration = 0;
    /** @type {number} 当前播放时间(秒) */
    this.currentTime = 0;
    /** @type {boolean} 是否循环播放 */
    this.loop = true;
    /** @type {number} 播放速度 */
    this.playbackSpeed = 1;
    /** @type {{code: string, message: string}|null} 最近错误 */
    this.lastError = null;
    /** @type {boolean} */
    this.disposed = false;
    /** @type {function(): (object|null)} */
    this._getCurrentVrm = (options && typeof options.getCurrentVrm === 'function')
      ? options.getCurrentVrm
      : function () { return null; };

    // Phase 3A — VRMA 文件导入与最小播放闭环
    /** @type {number} 加载代次 (每次 loadVrmaResource 递增,异步回调校验) */
    this.loadGeneration = 0;
    /** @type {number} 当前活动加载代次 (异步回调提交时校验) */
    this.activeLoadGeneration = 0;
    /** @type {object|null} 当前正在加载的资源 (LOADING 期间非空) */
    this.pendingResource = null;
    /** @type {object|null} 当前已加载的资源 (READY+ 状态非空) */
    this.currentResource = null;
    /** @type {string} 上次成功状态 (用于加载失败时恢复) */
    this.lastSuccessfulState = AnimationState.IDLE;
  }

  /**
   * 初始化动画控制器。
   *
   * 状态转换:
   *   UNINITIALIZED → IDLE
   *   IDLE/READY/PLAYING/PAUSED/STOPPED → 返回当前状态(幂等)
   *   DISPOSED → 返回错误 ANIMATION_CONTROLLER_DISPOSED
   *   FAILED → 返回错误(允许重试 initialize)
   *
   * 初始化不得创建假的 AnimationClip。
   *
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  initialize() {
    if (this.disposed) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_DISPOSED, 'AnimationController already disposed')
      };
    }
    // 幂等:已初始化的状态直接返回当前状态
    if (this._state === AnimationState.IDLE ||
        this._state === AnimationState.READY ||
        this._state === AnimationState.PLAYING ||
        this._state === AnimationState.PAUSED ||
        this._state === AnimationState.STOPPED) {
      return { success: true, state: this._state };
    }
    // FAILED 允许重试
    if (this._state === AnimationState.FAILED) {
      this.lastError = null;
    }
    // UNINITIALIZED → IDLE
    this._state = AnimationState.IDLE;
    return { success: true, state: this._state };
  }

  /**
   * 绑定 VRM 模型,创建 AnimationMixer。
   *
   * 策略 (AGENTS.md Phase 3A §十四~§十五):
   *   1. 停止并释放旧 AnimationMixer (若存在)
   *   2. 清除旧 Action/Clip
   *   3. 绑定新 currentVrm
   *   4. 创建 new THREE.AnimationMixer(vrm.scene)
   *   5. state = IDLE (无 clip,不进入 READY/PLAYING)
   *
   * 重复绑定同一 VRM: 不得重复创建 Mixer。
   *
   * 动画绑定失败不得让:
   *   - ModelState = FAILED
   *   - ViewerState = FAILED
   *
   * @param {object} vrm VRM 根对象(必须包含 scene 属性)
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  bindVrm(vrm) {
    if (this.disposed) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_DISPOSED, 'AnimationController already disposed')
      };
    }
    if (this._state === AnimationState.UNINITIALIZED) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_NOT_INITIALIZED, 'AnimationController not initialized')
      };
    }
    // VRM 校验
    if (!vrm) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_VRM_MISSING, 'vrm is null or undefined')
      };
    }
    if (!vrm.scene) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_VRM_INVALID, 'vrm.scene is missing')
      };
    }

    // 重复绑定同一 VRM: 不重复创建 Mixer
    if (this.currentVrm === vrm && this.mixer) {
      return { success: true, state: this._state };
    }

    // 1. 停止并释放旧 Mixer (若存在)
    this._disposeMixer();

    // 2. 清除旧 Action/Clip
    this.currentClip = null;
    this.currentAction = null;
    this.currentAnimationName = '';
    this.duration = 0;
    this.currentTime = 0;
    this.lastError = null;

    // 3. 绑定新 currentVrm
    this.currentVrm = vrm;

    // 4. 创建 AnimationMixer
    try {
      this.mixer = new THREE.AnimationMixer(vrm.scene);
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      this.lastError = makeAnimError(ANIMATION_ERR_MIXER_CREATION_FAILED, msg);
      // Mixer 创建失败:状态保持 IDLE,记录错误,不阻塞 Viewer
      // (动画系统失败不影响模型加载和 Viewer 状态)
      this._state = AnimationState.IDLE;
      return {
        success: false,
        error: this.lastError
      };
    }

    // 5. state = IDLE (无 clip,不进入 READY/PLAYING)
    this._state = AnimationState.IDLE;
    return { success: true, state: this._state };
  }

  /**
   * 解绑 VRM,停止并释放 Mixer。
   *
   * 策略 (AGENTS.md Phase 3A §十五):
   *   mixer.stopAllAction();
   *   mixer.uncacheRoot(vrm.scene);
   *   再清除引用。
   *
   * 不销毁 VRM 模型本身(VRM 所有权属于 ViewerModelLoader)。
   *
   * @returns {{success: boolean, state?: string}}
   */
  unbindVrm() {
    if (this.disposed) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_DISPOSED, 'AnimationController already disposed')
      };
    }
    this._disposeMixer();
    this.currentVrm = null;
    this.currentClip = null;
    this.currentAction = null;
    this.currentAnimationName = '';
    this.duration = 0;
    this.currentTime = 0;
    // 解绑后回到 IDLE (控制器仍可用,等待下次 bindVrm)
    if (this._state !== AnimationState.DISPOSED) {
      this._state = AnimationState.IDLE;
    }
    return { success: true, state: this._state };
  }

  /**
   * 每帧更新(由 ViewerFrameLoop 通过 ViewerCore 调用)。
   *
   * 策略 (AGENTS.md Phase 3A §十六~§十七):
   *   - 复用现有 Frame Loop (不创建第二个 requestAnimationFrame)
   *   - deltaSeconds 必须是有限非负数
   *   - state !== PLAYING → 不调用 mixer.update
   *   - state === PLAYING → mixer.update(deltaSeconds * playbackSpeed)
   *
   * 更新顺序 (ANIMATION_UPDATE_ORDER: VRM_FIRST_THEN_MIXER):
   *   ViewerFrameLoop → modelLoader.update(deltaSeconds) [vrm.update] → animationController.update(deltaSeconds) [mixer.update]
   *   依据: Figure index.html:2876→2880 和 OWNverse offset 3351702 一致采用 vrm.update → mixer.update
   *
   * Phase 3A 骨架:
   *   无实际 Clip 时,state 不会进入 PLAYING,因此 mixer.update 不会被调用。
   *
   * @param {number} deltaSeconds 帧间隔(秒)
   */
  update(deltaSeconds) {
    if (this.disposed) return;
    if (this._state === AnimationState.DISPOSED) return;

    // 参数校验:deltaSeconds 必须是有限非负数
    if (typeof deltaSeconds !== 'number' ||
        !isFinite(deltaSeconds) ||
        deltaSeconds < 0 ||
        isNaN(deltaSeconds)) {
      // 无效值:忽略该帧,记录 warning,不导致 Viewer FAILED
      if (this.lastError === null ||
          this.lastError.code !== ANIMATION_ERR_DELTA_INVALID) {
        this.lastError = makeAnimError(
          ANIMATION_ERR_DELTA_INVALID,
          'deltaSeconds is invalid: ' + String(deltaSeconds)
        );
        console.warn('[ViewerAnimationController] ' + this.lastError.code + ': ' + this.lastError.message);
      }
      return;
    }

    // state !== PLAYING → 不调用 mixer.update
    if (this._state !== AnimationState.PLAYING) {
      return;
    }

    // state === PLAYING → mixer.update(deltaSeconds * playbackSpeed)
    if (this.mixer) {
      try {
        this.mixer.update(deltaSeconds * this.playbackSpeed);
        // 更新 currentTime (由 mixer 内部时间推进,此处仅同步)
        if (this.currentAction) {
          this.currentTime = this.currentAction.time;
        }
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        this.lastError = makeAnimError('ANIMATION_MIXER_UPDATE_FAILED', msg);
        console.warn('[ViewerAnimationController] mixer.update failed: ' + msg);
      }
    }
  }

  /**
   * 获取当前动画状态。
   *
   * @returns {string} AnimationState 枚举值
   */
  getState() {
    return this._state;
  }

  /**
   * 获取调试状态快照(只读,供 Bridge getAnimationDebugState 使用)。
   *
   * Phase 3A — VRMA 文件导入与最小播放闭环:新增 resourceId / loadGeneration 字段。
   *
   * @returns {object} ArkWebAnimationDebugState 兼容对象
   */
  getDebugState() {
    return {
      state: this._state,
      vrmBound: !!this.currentVrm,
      mixerReady: !!this.mixer,
      clipReady: !!this.currentClip,
      actionReady: !!this.currentAction,
      animationName: this.currentAnimationName,
      resourceId: this.currentResource ? this.currentResource.resourceId : '',
      duration: this.duration,
      currentTime: this.currentTime,
      playbackSpeed: this.playbackSpeed,
      loop: this.loop,
      loadGeneration: this.loadGeneration,
      errorCode: this.lastError ? this.lastError.code : '',
      errorMessage: this.lastError ? this.lastError.message : ''
    };
  }

  /**
   * Phase 3A: 查询动画依赖状态(只读,向后兼容)。
   *
   * 返回当前动画系统的依赖可用性信息。
   * - three-vrm-animation 3.5.5 已安装,VRMAnimationLoaderPlugin / createVRMAnimationClip 可用
   * - AnimationMixer 属于 three.js core,已可用
   *
   * 此方法同时引用所有错误码常量,避免 esbuild tree-shaking 移除未使用的错误码。
   *
   * @returns {{dependencyAvailable: boolean, dependencyName: string, dependencyVersion: string, mixerAvailable: boolean, loaderAvailable: boolean, clipFactoryAvailable: boolean, runtimeNetworkRequired: boolean, errorCodes: string[]}}
   */
  getDependencyStatus() {
    return {
      dependencyAvailable: true,
      dependencyName: ANIMATION_DEPENDENCY_PACKAGE_NAME,
      dependencyVersion: ANIMATION_DEPENDENCY_VERSION,
      mixerAvailable: true,
      loaderAvailable: typeof VRMAnimationLoaderPlugin === 'function',
      clipFactoryAvailable: typeof createVRMAnimationClip === 'function',
      runtimeNetworkRequired: false,
      // 引用所有错误码,防止 tree-shaking 移除未使用的常量
      errorCodes: [
        ANIMATION_ERR_DISPOSED,
        ANIMATION_ERR_NOT_INITIALIZED,
        ANIMATION_ERR_VRM_MISSING,
        ANIMATION_ERR_VRM_INVALID,
        ANIMATION_ERR_MIXER_CREATION_FAILED,
        ANIMATION_ERR_DELTA_INVALID,
        ANIMATION_ERR_DEPENDENCY_MISSING,
        ANIMATION_ERR_UNSUPPORTED,
        ANIMATION_ERR_DEPENDENCY_VERSION_MISMATCH,
        ANIMATION_ERR_DEPENDENCY_EXPORT_MISSING,
        ANIMATION_ERR_DEPENDENCY_BUILD_FAILED,
        ANIMATION_ERR_DEPENDENCY_LICENSE_MISSING,
        // Phase 3A — VRMA 文件导入与最小播放闭环 新增错误码
        ANIMATION_ERR_RESOURCE_INVALID,
        ANIMATION_ERR_RESOURCE_URL_INVALID,
        ANIMATION_ERR_RESOURCE_SIZE_INVALID,
        ANIMATION_ERR_LOAD_IN_PROGRESS,
        ANIMATION_ERR_DATA_MISSING,
        ANIMATION_ERR_CLIP_CREATION_FAILED,
        ANIMATION_ERR_CLIP_INVALID,
        ANIMATION_ERR_CLIP_EMPTY,
        ANIMATION_ERR_NOT_READY,
        ANIMATION_ERR_ALREADY_PLAYING,
        ANIMATION_ERR_ACTION_MISSING,
        ANIMATION_ERR_PAUSE_INVALID_STATE,
        ANIMATION_ERR_STOP_INVALID_STATE,
        ANIMATION_ERR_POSE_RESET_WARNING,
        ANIMATION_ERR_STALE_RESULT,
        ANIMATION_ERR_LOAD_FAILED
      ]
    };
  }

  /**
   * Phase 3A 依赖补齐: 查询依赖状态(只读,规范 §十五)。
   *
   * 返回依赖可用性的受控视图,不暴露:
   *   - Node 模块路径
   *   - 本机绝对路径
   *   - 完整 package.json
   *   - 许可证全文
   *
   * @returns {{available: boolean, packageName: string, version: string, loaderAvailable: boolean, clipFactoryAvailable: boolean, runtimeNetworkRequired: boolean}}
   */
  getDependencyState() {
    return {
      available: true,
      packageName: ANIMATION_DEPENDENCY_PACKAGE_NAME,
      version: ANIMATION_DEPENDENCY_VERSION,
      loaderAvailable: typeof VRMAnimationLoaderPlugin === 'function',
      clipFactoryAvailable: typeof createVRMAnimationClip === 'function',
      runtimeNetworkRequired: false
    };
  }

  // ===== Phase 3A — VRMA 文件导入与最小播放闭环 =====

  /**
   * 异步加载 VRMA 资源 (规范 §十五~§二十)。
   *
   * 同步返回加载启动结果,异步结果通过 getState() / getDebugState() 查询。
   * 不通过 Bridge 返回 Promise。
   *
   * 输入 resource:
   *   {
   *     resourceUrl: string,    // 受控 URL https://ark-tavern.local/animation/<id>
   *     resourceId: string,     // 资源 ID
   *     displayName: string,    // 显示名
   *     mimeType: string,       // MIME
   *     size: number            // 字节数
   *   }
   *
   * 同步返回:
   *   { success: true, state: 'LOADING', generation: <number> }
   *   { success: false, error: { code, message } }
   *
   * 加载前置条件 (规范 §十六):
   *   - Controller 未 dispose
   *   - Animation system 已 initialize
   *   - currentVrm 存在
   *   - currentVrm.scene 存在
   *   - resourceUrl 是受控 animation URL
   *   - resourceId 合法
   *   - displayName 非空
   *   - size > 0
   *   - 当前没有其他加载正在进行
   *
   * 加载失败不得改变当前动画 (规范 §二十)。
   *
   * @param {object} resource
   * @returns {{success: boolean, state?: string, generation?: number, error?: {code: string, message: string}}}
   */
  loadVrmaResource(resource) {
    if (this.disposed) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_DISPOSED, 'AnimationController already disposed')
      };
    }
    if (this._state === AnimationState.UNINITIALIZED) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_NOT_INITIALIZED, 'AnimationController not initialized')
      };
    }
    // 已有加载进行中
    if (this._state === AnimationState.LOADING) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_LOAD_IN_PROGRESS, 'Another animation load is in progress')
      };
    }

    // VRM 校验
    var vrm = this._getCurrentVrm();
    if (!vrm) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_VRM_MISSING, 'currentVrm is null or undefined')
      };
    }
    if (!vrm.scene) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_VRM_INVALID, 'currentVrm.scene is missing')
      };
    }

    // resource 校验
    if (!resource || typeof resource !== 'object') {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_RESOURCE_INVALID, 'resource is null or not an object')
      };
    }
    if (typeof resource.resourceUrl !== 'string' || resource.resourceUrl.length === 0) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_RESOURCE_URL_INVALID, 'resourceUrl missing or empty')
      };
    }
    if (resource.resourceUrl.indexOf(ANIMATION_RESOURCE_URL_PREFIX) !== 0) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_RESOURCE_URL_INVALID,
          'resourceUrl is not a controlled animation URL (must start with ' + ANIMATION_RESOURCE_URL_PREFIX + ')')
      };
    }
    if (typeof resource.resourceId !== 'string' || resource.resourceId.length === 0) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_RESOURCE_INVALID, 'resourceId missing or empty')
      };
    }
    if (typeof resource.displayName !== 'string' || resource.displayName.length === 0) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_RESOURCE_INVALID, 'displayName missing or empty')
      };
    }
    if (typeof resource.size !== 'number' || !isFinite(resource.size) || resource.size <= 0) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_RESOURCE_SIZE_INVALID, 'size must be a positive finite number')
      };
    }

    // 启动加载:递增 loadGeneration,记录 pendingResource
    this.loadGeneration++;
    var generation = this.loadGeneration;
    this.activeLoadGeneration = generation;
    this.pendingResource = {
      resourceUrl: resource.resourceUrl,
      resourceId: resource.resourceId,
      displayName: resource.displayName,
      mimeType: resource.mimeType || 'model/gltf-binary',
      size: resource.size
    };
    // 记录加载前的成功状态 (用于失败时恢复)
    if (this._state !== AnimationState.FAILED) {
      this.lastSuccessfulState = this._state;
    }
    this.lastError = null;
    this._state = AnimationState.LOADING;

    // 异步触发 GLTFLoader 加载 (不通过 Bridge 返回 Promise)
    this._asyncLoadVrma(generation, this.pendingResource, vrm);

    return { success: true, state: this._state, generation: generation };
  }

  /**
   * 内部:异步加载 VRMA 文件 (规范 §十七~§二十)。
   *
   * 流程:
   * 1. 创建专用 GLTFLoader (不复用模型 Loader)
   * 2. 注册 VRMAnimationLoaderPlugin (不注册 VRMLoaderPlugin)
   * 3. loader.load(url, onLoad, onProgress, onError)
   * 4. onLoad: 提取 gltf.userData.vrmAnimations[0]
   * 5. 调用 createVRMAnimationClip(vrmAnimation, currentVrm)
   * 6. 验证 Clip (duration / tracks)
   * 7. 创建 Action (mixer.clipAction)
   * 8. 配置 Action (setLoop(LoopRepeat, Infinity) / clampWhenFinished / enabled)
   * 9. 提交新动画 (原子替换)
   * 10. 释放旧 Action/Clip
   * 11. 状态进入 READY
   *
   * 失败时:
   * - 过期结果 (generation 不匹配): ANIMATION_STALE_RESULT,不提交
   * - 无动画数据: ANIMATION_DATA_MISSING
   * - Clip 创建失败: ANIMATION_CLIP_CREATION_FAILED
   * - Clip 无效: ANIMATION_CLIP_INVALID
   * - Clip 空: ANIMATION_CLIP_EMPTY
   * - 加载异常: ANIMATION_LOAD_FAILED
   * - 加载失败时恢复旧动画状态 (若有)
   *
   * @param {number} generation 加载代次
   * @param {object} pendingResource 待加载资源
   * @param {object} vrm 当前 VRM
   * @private
   */
  _asyncLoadVrma(generation, pendingResource, vrm) {
    var self = this;

    // 创建专用 GLTFLoader
    var loader = new GLTFLoader();
    // 仅注册 VRMAnimationLoaderPlugin (不注册 VRMLoaderPlugin)
    loader.register(function (parser) {
      return new VRMAnimationLoaderPlugin(parser);
    });

    var onLoad = function (gltf) {
      // 过期结果检查
      if (self.disposed ||
          generation !== self.activeLoadGeneration ||
          self.pendingResource !== pendingResource) {
        // stale load result 静默忽略(高频保护逻辑,默认不记录)
        return;
      }
      // currentVrm 未改变检查 (模型替换时不应提交)
      var currentVrmNow = self._getCurrentVrm();
      if (currentVrmNow !== vrm) {
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_STALE_RESULT, 'currentVrm changed during animation load'));
        return;
      }

      // 提取 vrmAnimations[0]
      var vrmAnimations = (gltf && gltf.userData && gltf.userData.vrmAnimations) || null;
      if (!Array.isArray(vrmAnimations) || vrmAnimations.length === 0) {
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_DATA_MISSING, 'gltf.userData.vrmAnimations is empty or not an array'));
        return;
      }
      var vrmAnimation = vrmAnimations[0];
      if (!vrmAnimation) {
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_DATA_MISSING, 'vrmAnimations[0] is null or undefined'));
        return;
      }

      // 创建 Clip
      var clip = null;
      try {
        clip = createVRMAnimationClip(vrmAnimation, vrm);
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_CLIP_CREATION_FAILED, 'createVRMAnimationClip threw: ' + msg));
        return;
      }
      if (!clip) {
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_CLIP_CREATION_FAILED, 'createVRMAnimationClip returned null'));
        return;
      }
      // 校验 Clip 类型: three.js 0.176.0 AnimationClip 无 isAnimationClip 属性,
      // 使用 instanceof THREE.AnimationClip 校验 (更严格且符合规范意图)。
      // 若 instanceof 失败 (THREE 实例不一致的边界情况), 降级为结构校验。
      if (!(clip instanceof THREE.AnimationClip)) {
        if (typeof clip.duration !== 'number' || !Array.isArray(clip.tracks)) {
          self._handleLoadFailure(generation, pendingResource,
            makeAnimError(ANIMATION_ERR_CLIP_INVALID, 'clip is not an AnimationClip instance and lacks duration/tracks'));
          return;
        }
      }
      if (typeof clip.duration !== 'number' || !isFinite(clip.duration) || clip.duration <= 0) {
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_CLIP_INVALID, 'clip.duration is invalid: ' + String(clip.duration)));
        return;
      }
      if (!Array.isArray(clip.tracks) || clip.tracks.length === 0) {
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_CLIP_EMPTY, 'clip.tracks is empty or not an array'));
        return;
      }

      // 创建 Action
      var action = null;
      try {
        action = self.mixer.clipAction(clip);
      } catch (e) {
        var msg2 = e && e.message ? e.message : String(e);
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_ACTION_MISSING, 'mixer.clipAction threw: ' + msg2));
        return;
      }
      if (!action || typeof action.play !== 'function' || typeof action.stop !== 'function') {
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_ACTION_MISSING, 'clipAction returned invalid action'));
        return;
      }

      // 配置 Action (固定 LoopRepeat, 不提供循环模式设置)
      try {
        action.setLoop(THREE.LoopRepeat, Infinity);
        action.clampWhenFinished = true;
        action.enabled = true;
      } catch (e) {
        var msg3 = e && e.message ? e.message : String(e);
        self._handleLoadFailure(generation, pendingResource,
          makeAnimError(ANIMATION_ERR_ACTION_MISSING, 'action config failed: ' + msg3));
        return;
      }

      // === 原子替换 (规范 §二十) ===
      // 1. 保存旧 Clip / Action / 资源 / 状态
      var oldClip = self.currentClip;
      var oldAction = self.currentAction;
      var oldResource = self.currentResource;

      // 2. 提交新动画
      self.currentClip = clip;
      self.currentAction = action;
      self.currentResource = pendingResource;
      self.currentAnimationName = pendingResource.displayName;
      self.duration = clip.duration;
      self.currentTime = 0;
      self.pendingResource = null;
      self.lastError = null;
      self._state = AnimationState.READY;
      self.lastSuccessfulState = AnimationState.READY;

      // 3. 释放旧 Action / Clip (规范 §二十五)
      if (oldAction) {
        try { oldAction.stop(); } catch (_e) { /* ignore */ }
      }
      if (self.mixer && oldClip) {
        try {
          // Three.js 0.176.0: uncacheAction(target, root) — root 可选
          if (typeof self.mixer.uncacheAction === 'function') {
            self.mixer.uncacheAction(oldClip, vrm.scene);
          } else {
            self.mixer.uncacheClip(oldClip);
          }
        } catch (_e) { /* ignore */ }
        try {
          self.mixer.uncacheClip(oldClip);
        } catch (_e) { /* ignore */ }
      }
      // 旧资源引用清除 (已由新 currentResource 覆盖)

      console.info('[ViewerAnimationController] VRMA loaded: ' +
        pendingResource.displayName + ' (duration=' + clip.duration + 's, tracks=' + clip.tracks.length + ')');
    };

    var onError = function (error) {
      // 过期结果检查
      if (self.disposed ||
          generation !== self.activeLoadGeneration ||
          self.pendingResource !== pendingResource) {
        // stale load error 静默忽略(高频保护逻辑,默认不记录)
        return;
      }
      var msg = error && error.message ? error.message : String(error);
      self._handleLoadFailure(generation, pendingResource,
        makeAnimError(ANIMATION_ERR_LOAD_FAILED, 'GLTFLoader.load failed: ' + msg));
    };

    try {
      loader.load(pendingResource.resourceUrl, onLoad, undefined, onError);
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      this._handleLoadFailure(generation, pendingResource,
        makeAnimError(ANIMATION_ERR_LOAD_FAILED, 'GLTFLoader.load threw: ' + msg));
    }
  }

  /**
   * 内部:处理加载失败 (规范 §十七~§二十)。
   *
   * - 记录错误
   * - 清除 pendingResource
   * - 若有旧动画可用,恢复旧状态 (而不是永久丢失)
   * - 若无旧动画,状态进入 FAILED
   *
   * @param {number} generation 加载代次
   * @param {object} pendingResource 待加载资源
   * @param {{code: string, message: string}} error 错误对象
   * @private
   */
  _handleLoadFailure(generation, pendingResource, error) {
    // 校验代次 (过期结果不处理)
    if (generation !== this.activeLoadGeneration || this.pendingResource !== pendingResource) {
      return;
    }
    this.lastError = error;
    this.pendingResource = null;

    // 若有旧动画可用,恢复旧状态
    if (this.currentClip && this.currentAction && this.currentResource) {
      this._state = this.lastSuccessfulState || AnimationState.READY;
      console.warn('[ViewerAnimationController] load failed, restored previous animation: ' +
        error.code + ' ' + error.message);
    } else {
      // 无旧动画,进入 FAILED
      this._state = AnimationState.FAILED;
      console.warn('[ViewerAnimationController] load failed, no previous animation: ' +
        error.code + ' ' + error.message);
    }
  }

  /**
   * 播放动画 (规范 §二十二)。
   *
   * 合法状态:READY / PAUSED / STOPPED
   * - READY / STOPPED: action.reset() + action.play()
   * - PAUSED: action.paused = false + action.play()
   *
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  play() {
    if (this.disposed) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_DISPOSED, 'AnimationController already disposed')
      };
    }
    if (this._state === AnimationState.PLAYING) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_ALREADY_PLAYING, 'Animation is already playing')
      };
    }
    if (this._state !== AnimationState.READY &&
        this._state !== AnimationState.PAUSED &&
        this._state !== AnimationState.STOPPED) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_NOT_READY,
          'Cannot play in state ' + this._state + ' (expected READY/PAUSED/STOPPED)')
      };
    }
    if (!this.currentAction) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_ACTION_MISSING, 'currentAction is null')
      };
    }
    if (!this.mixer) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_ACTION_MISSING, 'mixer is null')
      };
    }

    try {
      if (this._state === AnimationState.READY || this._state === AnimationState.STOPPED) {
        this.currentAction.reset();
        this.currentAction.enabled = true;
        this.currentAction.paused = false;
        this.currentAction.play();
        this.currentTime = 0;
      } else {
        // PAUSED: 恢复播放
        this.currentAction.paused = false;
        this.currentAction.play();
      }
      this._state = AnimationState.PLAYING;
      this.lastError = null;
      return { success: true, state: this._state };
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      this.lastError = makeAnimError(ANIMATION_ERR_ACTION_MISSING, 'action.play threw: ' + msg);
      return { success: false, error: this.lastError };
    }
  }

  /**
   * 暂停动画 (规范 §二十三)。
   *
   * 只允许 PLAYING 状态。
   * 保留当前播放时间 / Action / Clip / 资源。
   *
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  pause() {
    if (this.disposed) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_DISPOSED, 'AnimationController already disposed')
      };
    }
    if (this._state !== AnimationState.PLAYING) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_PAUSE_INVALID_STATE,
          'Cannot pause in state ' + this._state + ' (expected PLAYING)')
      };
    }
    if (!this.currentAction) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_ACTION_MISSING, 'currentAction is null')
      };
    }
    try {
      this.currentAction.paused = true;
      // 同步 currentTime
      this.currentTime = this.currentAction.time;
      this._state = AnimationState.PAUSED;
      return { success: true, state: this._state };
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      this.lastError = makeAnimError(ANIMATION_ERR_PAUSE_INVALID_STATE, 'pause threw: ' + msg);
      return { success: false, error: this.lastError };
    }
  }

  /**
   * 停止动画 (规范 §二十四)。
   *
   * 默认 resetPose=true。
   * - action.stop()
   * - mixer.stopAllAction()
   * - currentTime = 0
   * - state = STOPPED
   * - resetPose=true 且 currentVrm.humanoid.resetNormalizedPose 存在时调用
   *
   * STOPPED 仍保留 Clip / 资源 / 动画名称 / duration,可再次播放。
   *
   * @param {object} [options]
   * @param {boolean} [options.resetPose=true] 是否重置姿势
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  stop(options) {
    if (this.disposed) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_DISPOSED, 'AnimationController already disposed')
      };
    }
    if (this._state !== AnimationState.PLAYING && this._state !== AnimationState.PAUSED) {
      return {
        success: false,
        error: makeAnimError(ANIMATION_ERR_STOP_INVALID_STATE,
          'Cannot stop in state ' + this._state + ' (expected PLAYING/PAUSED)')
      };
    }
    var opts = options || {};
    var resetPose = opts.resetPose !== false;

    try {
      if (this.currentAction) {
        try { this.currentAction.stop(); } catch (_e) { /* ignore */ }
      }
      if (this.mixer) {
        try { this.mixer.stopAllAction(); } catch (_e) { /* ignore */ }
      }
      this.currentTime = 0;
      this._state = AnimationState.STOPPED;

      // 重置姿势 (失败只记录 warning,不改 FAILED)
      if (resetPose && this.currentVrm && this.currentVrm.humanoid &&
          typeof this.currentVrm.humanoid.resetNormalizedPose === 'function') {
        try {
          this.currentVrm.humanoid.resetNormalizedPose();
        } catch (e) {
          var msg = e && e.message ? e.message : String(e);
          console.warn('[ViewerAnimationController] resetNormalizedPose failed: ' + msg);
          // 只记录 warning,不改 FAILED (规范 §二十四)
          // 但 lastError 保留为 warning (不影响状态)
          this.lastError = makeAnimError(ANIMATION_ERR_POSE_RESET_WARNING,
            'resetNormalizedPose failed: ' + msg);
        }
      }
      return { success: true, state: this._state };
    } catch (e) {
      var msg2 = e && e.message ? e.message : String(e);
      this.lastError = makeAnimError(ANIMATION_ERR_STOP_INVALID_STATE, 'stop threw: ' + msg2);
      return { success: false, error: this.lastError };
    }
  }

  /**
   * 销毁动画控制器,释放所有资源。
   *
   * 策略 (AGENTS.md Phase 3A §二十四):
   *   1. stopAllAction (mixer 存在时)
   *   2. uncacheClip (currentClip 存在时)
   *   3. uncacheRoot (mixer 与 currentVrm 均存在时)
   *   4. 清除 Mixer
   *   5. 清除 Clip
   *   6. 清除 Action
   *   7. 清除 currentVrm
   *   8. state = DISPOSED
   *
   * 不得 dispose VRM 模型本身(VRM 所有权属于 ViewerModelLoader)。
   */
  dispose() {
    if (this.disposed) return;
    this.disposed = true;

    // 1. stopAllAction
    this._disposeMixer();

    // 4-7. 清除引用
    this.mixer = null;
    this.currentClip = null;
    this.currentAction = null;
    this.currentVrm = null;
    this.currentAnimationName = '';
    this.duration = 0;
    this.currentTime = 0;

    // 8. state = DISPOSED
    this._state = AnimationState.DISPOSED;
  }

  // ===== 内部方法 =====

  /**
   * 内部:停止并释放当前 Mixer(不清除 currentVrm 引用)。
   *
   * 依据 AGENTS.md Phase 3A §十五:
   *   mixer.stopAllAction();
   *   mixer.uncacheRoot(vrm.scene);
   */
  _disposeMixer() {
    if (this.mixer) {
      try {
        this.mixer.stopAllAction();
      } catch (e) {
        console.warn('[ViewerAnimationController] stopAllAction failed: ' + (e && e.message ? e.message : String(e)));
      }
      // uncacheRoot:释放与 root 关联的缓存
      if (this.currentVrm && this.currentVrm.scene) {
        try {
          this.mixer.uncacheRoot(this.currentVrm.scene);
        } catch (e) {
          console.warn('[ViewerAnimationController] uncacheRoot failed: ' + (e && e.message ? e.message : String(e)));
        }
      }
      // uncacheClip:释放 clip 缓存
      if (this.currentClip) {
        try {
          this.mixer.uncacheClip(this.currentClip);
        } catch (e) {
          console.warn('[ViewerAnimationController] uncacheClip failed: ' + (e && e.message ? e.message : String(e)));
        }
      }
      this.mixer = null;
    }
  }
}
