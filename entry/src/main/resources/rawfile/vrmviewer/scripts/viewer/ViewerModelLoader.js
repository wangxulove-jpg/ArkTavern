/**
 * ViewerModelLoader — VRM 模型加载器(Phase 1C-2)
 *
 * 职责:
 *   - 创建 GLTFLoader 并注册 VRMLoaderPlugin(遵循 Figure)
 *   - 加载默认 VRM(./assets/models/default.vrm)
 *   - 加载任意 URL 的 VRM(内部方法,不对 ArkTS 暴露)
 *   - VRMUtils 性能优化(removeUnnecessaryVertices / combineSkeletons / combineMorphs)
 *   - VRM 0.x / 1.x 朝向处理
 *   - frustumCulled = false
 *   - 原子替换(新模型加载成功后才移除并释放旧模型)
 *   - 模型释放(Geometry / Material / Texture,使用 Set 防重复释放)
 *   - 状态机(NOT_LOADED / LOADING / READY / FAILED / DISPOSED)
 *   - 加载代次(loadGeneration)防止异步竞态
 *   - 通过 onStateChanged / onError 回调通知 ViewerCore
 *
 * Reference:
 *   - figure-main/index.html loadVRM() 行 899-1055:
 *       loader.load(url, onLoad, onProgress, onError)
 *       onLoad:
 *         vrm = gltf.userData.vrm
 *         VRMUtils.removeUnnecessaryVertices(gltf.scene)
 *         VRMUtils.combineSkeletons(gltf.scene)
 *         VRMUtils.combineMorphs(vrm)
 *         vrm.scene.traverse(obj => obj.frustumCulled = false)
 *         if (currentVrm) { scene.remove(currentVrm.scene); disposeVrm(currentVrm); currentVrm = undefined }
 *         scene.add(vrm.scene)
 *         if (vrm.meta.metaVersion == '0') vrm.scene.rotation.y = Math.PI  // VRM 0.x
 *         else vrm.scene.rotation._y = Math.PI                              // VRM 1.x
 *         currentVrm = vrm
 *   - figure-main/index.html disposeVrm() 行 849-893:
 *       vrm.scene.traverse(obj => { if (obj.isMesh) { obj.geometry.dispose(); disposeMaterial(obj.material) } })
 *       vrm.userData = null
 *   - figure-main/index.html animate() 行 2860-2906:
 *       currentVrm.update(deltaTime) → controls.update() → renderer.render()
 *   - figure-main/index.html 行 2963: loadVRM(VRM_MODEL_URL, 'default.vrm')
 *   - ownverse-vrm-viewer/analysis/RESOURCE_LIFECYCLE.md:
 *       OWNverse 不调用 VRMUtils.deepDispose(已知泄漏);本实现补充完整释放
 *
 * 与 Figure 的差异:
 *   - Figure 在 onLoad 中先移除旧模型再添加新模型;本实现采用原子替换:
 *     先加载新模型成功,再移除并释放旧模型,确保加载失败时旧模型仍可用
 *   - Figure 用 traverse + 手动 dispose;本实现复用 ViewerScene.disposeObject3D
 *     并额外用 Set 防止共享资源重复释放
 *   - Figure 在 loadVRM 中创建 AnimationMixer;本阶段不实现动画,留到 Phase 3
 *   - Figure 在 loadVRM 中处理 thumbnail / blend shape / materials / skybox / saveLastVrm;
 *     本阶段不实现,仅核心加载链路
 *
 * Phase 1C-2 限制:
 *   - 只加载默认模型(loadDefault),不对 ArkTS 暴露 loadModel
 *   - 不实现 AnimationMixer / VRMA / 文件选择器 / Object URL
 *   - 不实现自动取景(Phase 2C)
 */

import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMUtils } from '@pixiv/three-vrm';
import { disposeObject3D } from './ViewerScene.js';

// ===== 模型状态枚举 =====
export var ModelState = Object.freeze({
  NOT_LOADED: 'NOT_LOADED',
  LOADING: 'LOADING',
  READY: 'READY',
  FAILED: 'FAILED',
  DISPOSED: 'DISPOSED'
});

// ===== 错误代码 =====
export var ERR_MODEL_LOADER_NOT_INITIALIZED = 'MODEL_LOADER_NOT_INITIALIZED';
export var ERR_DEFAULT_MODEL_LOAD_FAILED = 'DEFAULT_MODEL_LOAD_FAILED';
export var ERR_MODEL_LOAD_FAILED = 'MODEL_LOAD_FAILED';
export var ERR_VRM_DATA_NOT_FOUND = 'VRM_DATA_NOT_FOUND';
export var ERR_MODEL_SCENE_EMPTY = 'MODEL_SCENE_EMPTY';
export var ERR_MODEL_LOAD_STALE = 'MODEL_LOAD_STALE';
export var ERR_MODEL_LOADER_DISPOSED = 'MODEL_LOADER_DISPOSED';

/** 默认 VRM 资源路径(相对于 index.html) */
export var DEFAULT_VRM_URL = './assets/models/default.vrm';
export var DEFAULT_VRM_DISPLAY_NAME = 'Default VRM';

/**
 * 构造错误对象。
 */
function makeError(code, message, phase, recoverable) {
  return {
    code: code,
    message: message,
    phase: phase || 'LOADING_MODEL',
    recoverable: !!recoverable
  };
}

export class ViewerModelLoader {
  /**
   * @param {object} [options]
   * @param {function(string, string=)} [options.onStateChanged] 状态变化回调 (state, detail?)
   * @param {function(object)} [options.onError] 错误回调 (error)
   * @param {function(object, object|null)} [options.onReplaceModel] 模型替换回调 (nextVrm, previousVrm)
   *   Phase 1D-2B-2:由 ViewerCore 实现,同步完成 scene.addModel + scene.removeModel + scene.removeTestObject。
   *   必须在 currentVrm 提交之前调用,以保持原子性。
   *   抛异常时视为加载失败,新模型将被释放,旧模型保留。
   */
  constructor(options) {
    options = options || {};
    /** @type {function(string, string=)|null} */
    this.onStateChanged = typeof options.onStateChanged === 'function' ? options.onStateChanged : null;
    /** @type {function(object)|null} */
    this.onError = typeof options.onError === 'function' ? options.onError : null;
    /** @type {function(object, object|null)|null} Phase 1D-2B-2 新增 */
    this.onReplaceModel = typeof options.onReplaceModel === 'function' ? options.onReplaceModel : null;

    /** @type {GLTFLoader|null} */
    this.loader = null;
    /** @type {object|null} 当前 VRM 根对象 (gltf.userData.vrm) */
    this.currentVrm = null;
    /** @type {string} 当前模型显示名 */
    this.displayName = '';
    /** @type {string} 当前状态 */
    this.state = ModelState.NOT_LOADED;
    /** @type {object|null} 最近一次错误 */
    this.lastError = null;

    /**
     * 加载代次。
     * 每次 dispose 或开始新一次加载时自增,用于使进行中的异步加载失效,
     * 避免异步加载完成后写入已被销毁 / 已被替换的 currentVrm。
     */
    this.loadGeneration = 0;
    /** 是否已销毁 */
    this.disposed = false;
  }

  /**
   * 初始化 Loader:创建 GLTFLoader 并注册 VRMLoaderPlugin。
   *
   * 遵循 Figure reference/figure-main/index.html 行 719-722:
   *   const loader = new GLTFLoader();
   *   loader.crossOrigin = 'anonymous';
   *   loader.register(parser => new VRMLoaderPlugin(parser));
   */
  initialize() {
    if (this.disposed) {
      throw Object.assign(new Error('ViewerModelLoader: cannot initialize after dispose'), {
        code: ERR_MODEL_LOADER_DISPOSED
      });
    }
    if (this.loader !== null) {
      return; // 幂等
    }

    this.loader = new GLTFLoader();
    // 与 Figure 一致:crossOrigin = 'anonymous'
    this.loader.crossOrigin = 'anonymous';

    // 注册 VRMLoaderPlugin(无额外参数,与 Figure 行 722 一致)
    // VRMLoaderPlugin 内部聚合 humanoid / springbone / materials 等子插件
    this.loader.register((parser) => new VRMLoaderPlugin(parser));
  }

  /**
   * 加载默认 VRM(./assets/models/default.vrm)。
   * Figure reference/figure-main/index.html 行 2963:
   *   await loadVRM(VRM_MODEL_URL, 'default.vrm');
   * @returns {Promise<{success: boolean, error?: object}>}
   */
  async loadDefault() {
    return this.loadModel(DEFAULT_VRM_URL, DEFAULT_VRM_DISPLAY_NAME);
  }

  /**
   * 加载任意 URL 的 VRM。
   *
   * 内部方法,Phase 1C-2 不对 ArkTS 暴露(由 loadDefault 调用)。
   * Phase 1D-2B-2:由 ViewerCore.loadUserModelResource() 调用,加载受控 URL 的用户模型。
   *
   * 原子替换顺序(AGENTS.md Phase 1D-2B-2 §十三):
   *   1. 设置 pending load generation
   *   2. state = LOADING
   *   3. 加载新 GLTF
   *   4. 验证 gltf.scene 和 gltf.userData.vrm
   *   5. 执行 VRMUtils
   *   6. 设置朝向和 frustumCulled
   *   7. 检查 generation(过期则 dispose 新模型,返回 stale)
   *   8. 保存 oldVrm 和 oldDisplayName
   *   9. 调用 onReplaceModel(newVrm, oldVrm) — 同步完成 scene.addModel + scene.removeModel + scene.removeTestObject
   *  10. 提交 currentVrm = newVrm
   *  11. 提交 displayName = pendingDisplayName
   *  12. 释放 oldVrm
   *  13. state = READY
   *  14. 相机 reset(由 ViewerCore 在 onStateChanged(READY) 中执行)
   *
   * 步骤 9-12 在同一同步调用栈内完成,不会在两次 render 之间显示两个模型。
   *
   * 失败回滚(AGENTS.md Phase 1D-2B-2 §十三):
   *   - 旧 currentVrm 保持不变
   *   - 旧 displayName 保持不变
   *   - 旧模型继续逐帧 update
   *   - 新候选模型完整释放
   *   - state = FAILED
   *   - lastError 更新
   *
   * 不得在加载开始时删除当前模型。
   *
   * @param {string} url VRM 文件 URL(受控 URL 或默认资源路径)
   * @param {string} [displayName] 显示名
   * @returns {Promise<{success: boolean, error?: object, state?: string}>}
   */
  async loadModel(url, displayName) {
    if (this.disposed) {
      var err = makeError(ERR_MODEL_LOADER_DISPOSED, 'ModelLoader disposed', this.state, false);
      this._notifyError(err);
      return { success: false, error: err };
    }
    if (!this.loader) {
      var err2 = makeError(ERR_MODEL_LOADER_NOT_INITIALIZED, 'GLTFLoader not initialized', this.state, false);
      this._notifyError(err2);
      return { success: false, error: err2 };
    }

    // 1. 设置 pending load generation
    var generation = ++this.loadGeneration;
    // 2. state = LOADING
    //    注意:Phase 1D-2B-2 修复 DEFECT_1 — displayName 延后到 READY 提交前才设置,
    //    加载失败时保留旧模型的 displayName。
    var pendingDisplayName = displayName || '';
    this._setState(ModelState.LOADING, 'Loading: ' + pendingDisplayName);

    // 3. 加载新 GLTF
    var gltf;
    try {
      gltf = await new Promise((resolve, reject) => {
        // Figure: loader.load(url, onLoad, onProgress, onError)
        this.loader.load(
          url,
          (loaded) => resolve(loaded),
          undefined, // onProgress 暂不处理(ArkWeb rawfile 加载进度不可靠)
          (error) => reject(error)
        );
      });
    } catch (e) {
      // 加载失败:保留旧模型(若有),仅更新状态为 FAILED
      // 旧 currentVrm / displayName 保持不变
      var loadErrMsg = e && e.message ? e.message : String(e);
      // 注意:此处使用 pendingDisplayName 判断是否为默认模型加载,
      // 而非 this.displayName(因为 displayName 未在加载开始时提交)
      var loadErrCode = (pendingDisplayName === DEFAULT_VRM_DISPLAY_NAME)
        ? ERR_DEFAULT_MODEL_LOAD_FAILED
        : ERR_MODEL_LOAD_FAILED;
      var loadErr = makeError(loadErrCode, loadErrMsg, 'LOADING_MODEL', true);
      this.lastError = loadErr;
      this._setState(ModelState.FAILED, loadErrMsg);
      this._notifyError(loadErr);
      return { success: false, error: loadErr };
    }

    // 7. 检查代次:若期间发生了 dispose 或新一次加载,丢弃此结果
    if (generation !== this.loadGeneration || this.disposed) {
      // 过期结果:释放已加载的 gltf 资源,但不通知状态
      this._disposeGltf(gltf);
      var staleErr = makeError(ERR_MODEL_LOAD_STALE, 'Load result is stale', 'LOADING_MODEL', false);
      // 不通知 ArkTS(这是内部竞态,不是用户可见错误)
      return { success: false, error: staleErr };
    }

    // 4. 验证 gltf / vrm
    if (!gltf || !gltf.scene) {
      var emptyErr = makeError(ERR_MODEL_SCENE_EMPTY, 'gltf.scene is empty', 'LOADING_MODEL', true);
      this.lastError = emptyErr;
      this._setState(ModelState.FAILED, 'gltf.scene is empty');
      this._notifyError(emptyErr);
      this._disposeGltf(gltf);
      return { success: false, error: emptyErr };
    }

    var vrm = gltf.userData && gltf.userData.vrm;
    if (!vrm) {
      var noVrmErr = makeError(ERR_VRM_DATA_NOT_FOUND, 'gltf.userData.vrm not found', 'LOADING_MODEL', true);
      this.lastError = noVrmErr;
      this._setState(ModelState.FAILED, 'VRM data not found');
      this._notifyError(noVrmErr);
      this._disposeGltf(gltf);
      return { success: false, error: noVrmErr };
    }

    // 5. 执行 VRMUtils 性能优化(与 Figure 行 910-912 一致)
    // 已确认 three-vrm 3.5.5 导出这三个方法(vendor/pixiv/three-vrm.module.js 行 6694-6699)
    try { VRMUtils.removeUnnecessaryVertices(gltf.scene); } catch (e) { console.warn('[ModelLoader] removeUnnecessaryVertices failed:', e); }
    try { VRMUtils.combineSkeletons(gltf.scene); } catch (e) { console.warn('[ModelLoader] combineSkeletons failed:', e); }
    try { VRMUtils.combineMorphs(vrm); } catch (e) { console.warn('[ModelLoader] combineMorphs failed:', e); }

    // 6. frustumCulled = false(与 Figure 行 915-917 一致)
    vrm.scene.traverse(function (obj) {
      obj.frustumCulled = false;
    });

    // 6.1 朝向处理(与 Figure 行 929-933 一致)
    // VRM 0.x: vrm.scene.rotation.y = Math.PI
    // VRM 1.x: vrm.scene.rotation._y = Math.PI
    // 注意:Figure 用 _y 直接设置内部属性,这是 three-vrm 文档推荐的 VRM 1.x 朝向方式
    // (避免触发 rotation.onChange 回调导致的矩阵重算)
    try {
      var metaVersion = vrm.meta && vrm.meta.metaVersion;
      if (metaVersion === '0') {
        vrm.scene.rotation.y = Math.PI; // VRM 0.x
      } else {
        vrm.scene.rotation._y = Math.PI; // VRM 1.x
      }
    } catch (e) {
      console.warn('[ModelLoader] orientation fix failed:', e);
    }

    // 7. 再次检查代次(异步 await 后可能已过期)
    if (generation !== this.loadGeneration || this.disposed) {
      this._disposeGltf(gltf);
      var staleErr2 = makeError(ERR_MODEL_LOAD_STALE, 'Load result is stale after validate', 'LOADING_MODEL', false);
      return { success: false, error: staleErr2 };
    }

    // 8. 保存 oldVrm 和 oldDisplayName(用于失败回滚和成功后释放)
    var oldVrm = this.currentVrm;

    // 9. 调用 onReplaceModel(newVrm, oldVrm) — 同步完成 Scene 替换
    //    Phase 1D-2B-2 修复 DEFECT_2/3/4:在 currentVrm 提交之前调用 onReplaceModel,
    //    让 ViewerCore 同步完成 scene.addModel + scene.removeModel + scene.removeTestObject。
    //    若 onReplaceModel 抛异常,视为加载失败,释放新模型,旧模型保留。
    if (this.onReplaceModel) {
      try {
        this.onReplaceModel(vrm, oldVrm);
      } catch (replaceErr) {
        // onReplaceModel 失败:释放新模型,旧模型保留
        var replaceErrMsg = replaceErr && replaceErr.message ? replaceErr.message : String(replaceErr);
        console.error('[ModelLoader] onReplaceModel failed: ' + replaceErrMsg);
        this._disposeVrm(vrm);
        var replaceErr2 = makeError(ERR_MODEL_LOAD_FAILED, 'onReplaceModel failed: ' + replaceErrMsg, 'LOADING_MODEL', true);
        this.lastError = replaceErr2;
        this._setState(ModelState.FAILED, replaceErrMsg);
        this._notifyError(replaceErr2);
        return { success: false, error: replaceErr2 };
      }
    }

    // 10. 提交 currentVrm = newVrm
    //     Phase 1D-2B-2 修复 DEFECT_2:延后到 onReplaceModel 成功后才提交
    this.currentVrm = vrm;

    // 11. 提交 displayName = pendingDisplayName
    //     Phase 1D-2B-2 修复 DEFECT_1:延后到 onReplaceModel 成功后才提交
    this.displayName = pendingDisplayName;

    // 12. 释放 oldVrm
    //     Phase 1D-2B-2 修复 DEFECT_3:延后到 currentVrm 提交后才释放
    //     (旧模型已通过 onReplaceModel 从 Scene 移除,此处只释放资源)
    if (oldVrm) {
      this._disposeVrm(oldVrm);
    }

    // 13. state = READY(触发 ViewerCore.onModelStateChanged(READY) → camera.reset)
    this.lastError = null;
    this._setState(ModelState.READY, 'Loaded: ' + this.displayName);

    return { success: true, state: this.state };
  }

  /**
   * 每帧更新(由 ViewerCore 的 FrameLoop 回调调用)。
   * Figure animate() 行 2875-2877:
   *   if (currentVrm) { currentVrm.update(deltaTime); }
   * @param {number} deltaSeconds
   */
  update(deltaSeconds) {
    if (this.disposed) return;
    if (this.currentVrm && typeof this.currentVrm.update === 'function') {
      try {
        this.currentVrm.update(deltaSeconds);
      } catch (e) {
        console.warn('[ModelLoader] vrm.update failed:', e);
      }
    }
  }

  /** @returns {object|null} */
  getCurrentVrm() {
    return this.currentVrm;
  }

  /** @returns {string} */
  getState() {
    return this.state;
  }

  /** @returns {string} */
  getDisplayName() {
    return this.displayName;
  }

  /** @returns {object|null} */
  getLastError() {
    return this.lastError;
  }

  /**
   * 卸载当前模型(不销毁 Loader,可继续加载新模型)。
   * Phase 1C-2:本方法保留供后续 Phase 使用,本阶段不主动调用。
   */
  unloadModel() {
    if (this.disposed) return;
    var oldVrm = this.currentVrm;
    this.currentVrm = null;
    this.displayName = '';
    if (oldVrm) {
      this._disposeVrm(oldVrm);
    }
    this._setState(ModelState.NOT_LOADED, 'Unloaded');
  }

  /**
   * 销毁 Loader,释放当前模型与 GLTFLoader 引用。
   *
   * 顺序(AGENTS.md Phase 1C-2 §十九):
   *   1. 标记 disposed
   *   2. loadGeneration 失效
   *   3. 释放当前 VRM
   *   4. 清空引用
   *   5. 状态推进到 DISPOSED
   */
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.loadGeneration++; // 使进行中的异步加载失效

    var oldVrm = this.currentVrm;
    this.currentVrm = null;
    if (oldVrm) {
      this._disposeVrm(oldVrm);
    }
    this.loader = null;
    this.displayName = '';
    this._setState(ModelState.DISPOSED, 'Disposed');
    this.onStateChanged = null;
    this.onError = null;
    this.onReplaceModel = null; // Phase 1D-2B-2
  }

  // ===== 内部方法 =====

  /**
   * 释放 VRM 资源。
   *
   * 参考 Figure disposeVrm() 行 849-893:
   *   vrm.scene.traverse(obj => { if (obj.isMesh) { geometry.dispose(); disposeMaterial(material) } })
   *   vrm.userData = null
   *
   * 增强(相比 Figure):
   *   - 使用 Set 防止共享 Geometry / Material / Texture 重复释放
   *   - 调用 disposeObject3D(复用 ViewerScene 的通用释放函数)
   *   - 不释放 AnimationMixer(本阶段未创建)
   *
   * @param {object} vrm
   */
  _disposeVrm(vrm) {
    if (!vrm) return;
    try {
      // 从父节点移除(若尚未移除)
      if (vrm.scene && vrm.scene.parent) {
        vrm.scene.parent.remove(vrm.scene);
      }

      // 使用 Set 防止共享资源重复释放
      var disposedGeometries = new Set();
      var disposedMaterials = new Set();
      var disposedTextures = new Set();

      if (vrm.scene) {
        vrm.scene.traverse(function (obj) {
          if (!obj) return;
          // 释放 Geometry
          if (obj.geometry && !disposedGeometries.has(obj.geometry)) {
            disposedGeometries.add(obj.geometry);
            try { obj.geometry.dispose(); } catch (e) { /* ignore */ }
          }
          // 释放 Material 及其 Texture
          if (obj.material) {
            var materials = Array.isArray(obj.material) ? obj.material : [obj.material];
            materials.forEach(function (mat) {
              if (!mat || disposedMaterials.has(mat)) return;
              disposedMaterials.add(mat);
              // 释放关联 Texture
              var textureKeys = [
                'map', 'normalMap', 'roughnessMap', 'metalnessMap',
                'emissiveMap', 'aoMap', 'bumpMap', 'alphaMap',
                'envMap', 'specularMap', 'displacementMap'
              ];
              textureKeys.forEach(function (key) {
                var tex = mat[key];
                if (tex && !disposedTextures.has(tex)) {
                  disposedTextures.add(tex);
                  try { tex.dispose(); } catch (e) { /* ignore */ }
                }
              });
              // 释放 Material 本身
              try { mat.dispose(); } catch (e) { /* ignore */ }
            });
          }
        });
      }

      // 清理 userData(与 Figure 行 892 一致)
      try { if (vrm.userData) vrm.userData = null; } catch (e) { /* ignore */ }
    } catch (e) {
      console.warn('[ModelLoader] _disposeVrm failed:', e);
    }
  }

  /**
   * 释放 gltf(加载失败或过期时的清理)。
   * 复用 _disposeVrm 的逻辑,若无 vrm 则用 disposeObject3D。
   */
  _disposeGltf(gltf) {
    if (!gltf) return;
    try {
      var vrm = gltf.userData && gltf.userData.vrm;
      if (vrm) {
        this._disposeVrm(vrm);
      } else if (gltf.scene) {
        // 无 VRM 数据,直接释放 scene
        disposeObject3D(gltf.scene);
      }
    } catch (e) {
      console.warn('[ModelLoader] _disposeGltf failed:', e);
    }
  }

  /** @param {string} state @param {string} [detail] */
  _setState(state, detail) {
    this.state = state;
    if (this.onStateChanged) {
      try {
        this.onStateChanged(state, detail);
      } catch (e) {
        console.warn('[ModelLoader] onStateChanged callback failed:', e);
      }
    }
  }

  /** @param {object} err */
  _notifyError(err) {
    this.lastError = err;
    if (this.onError) {
      try {
        this.onError(err);
      } catch (e) {
        console.warn('[ModelLoader] onError callback failed:', e);
      }
    }
  }
}
