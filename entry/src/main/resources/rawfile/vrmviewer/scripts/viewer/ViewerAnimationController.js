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
      duration: this.duration,
      currentTime: this.currentTime,
      playbackSpeed: this.playbackSpeed,
      loop: this.loop,
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
        ANIMATION_ERR_DEPENDENCY_LICENSE_MISSING
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
