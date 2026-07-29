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

// ===== Phase 1D-2C-1: 运行时诊断阶段(与 ArkTS VrmRuntimeStage 对齐) =====
// 仅与 ArkTS 端 VrmRuntimeStage 枚举的字符串值保持一致,
// 不在此处定义完整枚举,只声明本 Loader 实际会触发的阶段。
var VRM_STAGE = Object.freeze({
  GLTF_LOAD_STARTED: 'GLTF_LOAD_STARTED',
  GLTF_LOAD_PROGRESS: 'GLTF_LOAD_PROGRESS',
  GLTF_LOAD_FAILED: 'GLTF_LOAD_FAILED',
  VRM_DATA_VALIDATED: 'VRM_DATA_VALIDATED',
  MODEL_REPLACE_STARTED: 'MODEL_REPLACE_STARTED',
  MODEL_REPLACE_COMMITTED: 'MODEL_REPLACE_COMMITTED',
  MODEL_REPLACE_FAILED: 'MODEL_REPLACE_FAILED'
});

/**
 * Phase 1D-2C-1: 标准化 GLTFLoader 抛出的错误对象。
 *
 * GLTFLoader 的 onError 可能传入:
 * - Error 实例(含 name / message)
 * - 字符串(如 'Failed to fetch')
 * - XMLHttpRequest(部分旧路径)
 * - ProgressEvent(网络层错误)
 *
 * 本函数只保留 name + message,移除堆栈与文件路径信息。
 *
 * @param {*} error 原始错误对象
 * @returns {{name: string, message: string}}
 */
function normalizeLoaderError(error) {
  if (error === null || error === undefined) {
    return { name: 'Error', message: 'Unknown error' };
  }
  if (typeof error === 'string') {
    return { name: 'Error', message: error };
  }
  if (error instanceof Error) {
    return {
      name: error.name ? String(error.name) : 'Error',
      message: error.message ? String(error.message) : String(error)
    };
  }
  // ProgressEvent / Event 等非 Error 对象
  if (typeof error === 'object') {
    var name = error.name ? String(error.name) : (error.type ? String(error.type) : 'Error');
    var message = error.message
      ? String(error.message)
      : (error.statusText ? String(error.statusText) : 'Network or loader error');
    return { name: name, message: message };
  }
  return { name: 'Error', message: String(error) };
}

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
    /**
     * Phase 1D-2C-1: 运行时诊断回调。
     *
     * 由 ViewerCore 注入(转发到 app.js 的 arkTavernVrmRuntimeDiagnostics keeper)。
     * 签名:function(diagnostic) 其中 diagnostic = {
     *   stage: string,         // VrmRuntimeStage 字符串值
     *   code: string,          // 错误码(成功阶段为空字符串)
     *   message: string,       // 简短消息(已截断,无堆栈)
     *   resourceId: string,    // 资源 opaque id(未知时为空字符串)
     *   requestMethod: string, // 'GET' / 'HEAD' / ''(非 HTTP 阶段)
     *   httpStatus: number,    // HTTP 状态码(非 HTTP 阶段为 0)
     *   mimeType: string,      // MIME 类型(未知时为空字符串)
     *   contentLength: number, // 内容长度(未知时为 0)
     *   timestamp: number      // Date.now()
     * }
     *
     * 安全约束:回调收到的 diagnostic 不含 cachePath / sourceUri / fd / stack。
     * @type {function(object)|null}
     */
    this.onDiagnostic = typeof options.onDiagnostic === 'function' ? options.onDiagnostic : null;

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
     * Phase 1D-2C-1: 当前加载对应的资源 opaque id。
     * 由 loadModel 调用方通过 options 传入,或在 loadModel 解析受控 URL 时提取。
     * 用于诊断回调中填充 resourceId 字段。
     * @type {string}
     */
    this.currentResourceId = '';

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
   * Phase 1D-2C-1: 设置诊断回调。
   * @param {function(object)|null} callback 诊断回调函数(传 null 取消)
   */
  setDiagnosticCallback(callback) {
    this.onDiagnostic = typeof callback === 'function' ? callback : null;
  }

  /**
   * Phase 1D-2C-1: 上报诊断(内部方法)。
   *
   * 只填充 stage / code / message / resourceId / requestMethod / httpStatus / mimeType / contentLength / timestamp,
   * 不包含 cachePath / sourceUri / fd / stack / 用户目录。
   *
   * @param {string} stage VRM_STAGE.* 之一
   * @param {string} code 错误码(成功阶段为空字符串)
   * @param {string} message 简短消息
   * @param {string} [requestMethod] 'GET' / 'HEAD' / ''(默认 '')
   * @param {number} [httpStatus] HTTP 状态码(默认 0)
   * @param {string} [mimeType] MIME 类型(默认 '')
   * @param {number} [contentLength] 内容长度(默认 0)
   * @private
   */
  _emitDiagnostic(stage, code, message, requestMethod, httpStatus, mimeType, contentLength) {
    if (!this.onDiagnostic) {
      return;
    }
    var msg = String(message || '');
    // 截断错误消息,避免完整堆栈或长 URL 泄漏
    if (msg.length > 256) {
      msg = msg.substring(0, 256);
    }
    var diagnostic = {
      stage: stage,
      code: code || '',
      message: msg,
      resourceId: this.currentResourceId || '',
      requestMethod: requestMethod || '',
      httpStatus: httpStatus || 0,
      mimeType: mimeType || '',
      contentLength: contentLength || 0,
      timestamp: Date.now()
    };
    try {
      this.onDiagnostic(diagnostic);
    } catch (e) {
      // 回调失败仅日志,不影响加载主流程
      console.warn('[ModelLoader] onDiagnostic callback failed: ' + (e && e.message ? e.message : String(e)));
    }
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

    // Phase 1D-2C-1: 从受控 URL 提取 opaque id 作为诊断 resourceId
    // 受控 URL 格式:https://ark-tavern.local/model/<opaque-id>
    // 默认 VRM URL (./assets/models/default.vrm) 无 opaque id,resourceId 留空。
    this.currentResourceId = '';
    if (typeof url === 'string' && url.indexOf('https://ark-tavern.local/model/') === 0) {
      var tail = url.substring('https://ark-tavern.local/model/'.length);
      var qIdx = tail.indexOf('?');
      if (qIdx >= 0) {
        tail = tail.substring(0, qIdx);
      }
      var fIdx = tail.indexOf('#');
      if (fIdx >= 0) {
        tail = tail.substring(0, fIdx);
      }
      if (tail.length > 0 && tail.indexOf('/') < 0) {
        this.currentResourceId = tail;
      }
    }

    this._setState(ModelState.LOADING, 'Loading: ' + pendingDisplayName);

    // Phase 1D-2C-1: 上报 GLTF_LOAD_STARTED
    // requestMethod='GET' 因为 GLTFLoader 通过 HTTP GET 获取资源
    this._emitDiagnostic(
      VRM_STAGE.GLTF_LOAD_STARTED,
      '',
      'GLTFLoader.load started for ' + (pendingDisplayName || '(default)'),
      'GET',
      0,
      '',
      0
    );

    // 3. 加载新 GLTF
    var gltf;
    try {
      gltf = await new Promise((resolve, reject) => {
        // Figure: loader.load(url, onLoad, onProgress, onError)
        // Phase 1D-2C-1: 启用 onProgress 回调,上报 GLTF_LOAD_PROGRESS
        this.loader.load(
          url,
          (loaded) => resolve(loaded),
          (progressEvent) => {
            // GLTFLoader 的 onProgress 通常是 ProgressEvent
            // 只保留数字,不记录 URL
            var loaded = 0;
            var total = 0;
            var lengthComputable = false;
            try {
              if (progressEvent && typeof progressEvent === 'object') {
                lengthComputable = !!progressEvent.lengthComputable;
                loaded = typeof progressEvent.loaded === 'number' ? progressEvent.loaded : 0;
                total = typeof progressEvent.total === 'number' ? progressEvent.total : 0;
              }
            } catch (e) {
              // ProgressEvent 读取失败,忽略
              return;
            }
            // 只有 lengthComputable 才有有意义的 total
            this._emitDiagnostic(
              VRM_STAGE.GLTF_LOAD_PROGRESS,
              '',
              'loaded=' + loaded + ' total=' + total + ' computable=' + lengthComputable,
              'GET',
              0,
              '',
              total
            );
          },
          (error) => reject(error)
        );
      });
    } catch (e) {
      // 加载失败:保留旧模型(若有),仅更新状态为 FAILED
      // 旧 currentVrm / displayName 保持不变
      // Phase 1D-2C-1: 标准化错误并上报 GLTF_LOAD_FAILED
      var normalizedErr = normalizeLoaderError(e);
      var loadErrMsg = normalizedErr.message;
      // 注意:此处使用 pendingDisplayName 判断是否为默认模型加载,
      // 而非 this.displayName(因为 displayName 未在加载开始时提交)
      var loadErrCode = (pendingDisplayName === DEFAULT_VRM_DISPLAY_NAME)
        ? ERR_DEFAULT_MODEL_LOAD_FAILED
        : ERR_MODEL_LOAD_FAILED;
      var loadErr = makeError(loadErrCode, loadErrMsg, 'LOADING_MODEL', true);
      this.lastError = loadErr;
      this._setState(ModelState.FAILED, loadErrMsg);
      this._notifyError(loadErr);
      // 上报诊断(只保留 name + message,无堆栈)
      this._emitDiagnostic(
        VRM_STAGE.GLTF_LOAD_FAILED,
        loadErrCode,
        normalizedErr.name + ': ' + loadErrMsg,
        'GET',
        0,
        '',
        0
      );
      return { success: false, error: loadErr };
    }

    // 7. 检查代次:若期间发生了 dispose 或新一次加载,丢弃此结果
    if (generation !== this.loadGeneration || this.disposed) {
      // 过期结果:释放已加载的 gltf 资源,但不通知状态
      this._disposeGltf(gltf);
      var staleErr = makeError(ERR_MODEL_LOAD_STALE, 'Load result is stale', 'LOADING_MODEL', false);
      // 不通知 ArkTS(这是内部竞态,不是用户可见错误)
      // Phase 1D-2C-1: 仍上报诊断(标记为 stale,便于排查)
      this._emitDiagnostic(
        VRM_STAGE.GLTF_LOAD_FAILED,
        ERR_MODEL_LOAD_STALE,
        'Load result is stale (generation mismatch)',
        'GET',
        0,
        '',
        0
      );
      return { success: false, error: staleErr };
    }

    // 4. 验证 gltf / vrm
    if (!gltf || !gltf.scene) {
      var emptyErr = makeError(ERR_MODEL_SCENE_EMPTY, 'gltf.scene is empty', 'LOADING_MODEL', true);
      this.lastError = emptyErr;
      this._setState(ModelState.FAILED, 'gltf.scene is empty');
      this._notifyError(emptyErr);
      this._disposeGltf(gltf);
      this._emitDiagnostic(
        VRM_STAGE.GLTF_LOAD_FAILED,
        ERR_MODEL_SCENE_EMPTY,
        'gltf.scene is empty',
        'GET',
        0,
        '',
        0
      );
      return { success: false, error: emptyErr };
    }

    var vrm = gltf.userData && gltf.userData.vrm;
    if (!vrm) {
      var noVrmErr = makeError(ERR_VRM_DATA_NOT_FOUND, 'gltf.userData.vrm not found', 'LOADING_MODEL', true);
      this.lastError = noVrmErr;
      this._setState(ModelState.FAILED, 'VRM data not found');
      this._notifyError(noVrmErr);
      this._disposeGltf(gltf);
      this._emitDiagnostic(
        VRM_STAGE.GLTF_LOAD_FAILED,
        ERR_VRM_DATA_NOT_FOUND,
        'gltf.userData.vrm not found',
        'GET',
        0,
        '',
        0
      );
      return { success: false, error: noVrmErr };
    }

    // Phase 1D-2C-1: 上报 VRM_DATA_VALIDATED(模型数据校验通过,即将进入替换阶段)
    this._emitDiagnostic(
      VRM_STAGE.VRM_DATA_VALIDATED,
      '',
      'gltf.scene and userData.vrm validated',
      'GET',
      0,
      '',
      0
    );

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
      this._emitDiagnostic(
        VRM_STAGE.GLTF_LOAD_FAILED,
        ERR_MODEL_LOAD_STALE,
        'Load result is stale after validate (generation mismatch)',
        'GET',
        0,
        '',
        0
      );
      return { success: false, error: staleErr2 };
    }

    // 8. 保存 oldVrm 和 oldDisplayName(用于失败回滚和成功后释放)
    var oldVrm = this.currentVrm;

    // 9. 调用 onReplaceModel(newVrm, oldVrm) — 同步完成 Scene 替换
    //    Phase 1D-2B-2 修复 DEFECT_2/3/4:在 currentVrm 提交之前调用 onReplaceModel,
    //    让 ViewerCore 同步完成 scene.addModel + scene.removeModel + scene.removeTestObject。
    //    若 onReplaceModel 抛异常,视为加载失败,释放新模型,旧模型保留。
    // Phase 1D-2C-1: 上报 MODEL_REPLACE_STARTED(即将开始 Scene 替换)
    this._emitDiagnostic(
      VRM_STAGE.MODEL_REPLACE_STARTED,
      '',
      'Replacing model in scene' + (oldVrm ? ' (previous exists)' : ' (first load)'),
      '',
      0,
      '',
      0
    );
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
        // Phase 1D-2C-1: 上报 MODEL_REPLACE_FAILED
        this._emitDiagnostic(
          VRM_STAGE.MODEL_REPLACE_FAILED,
          ERR_MODEL_LOAD_FAILED,
          'onReplaceModel failed: ' + replaceErrMsg,
          '',
          0,
          '',
          0
        );
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

    // Phase 1D-2C-1: 上报 MODEL_REPLACE_COMMITTED(Scene 替换已提交)
    this._emitDiagnostic(
      VRM_STAGE.MODEL_REPLACE_COMMITTED,
      '',
      'Model replaced and committed: ' + (pendingDisplayName || '(default)'),
      '',
      0,
      '',
      0
    );

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
    this.currentResourceId = ''; // Phase 1D-2C-1
    this._setState(ModelState.DISPOSED, 'Disposed');
    this.onStateChanged = null;
    this.onError = null;
    this.onReplaceModel = null; // Phase 1D-2B-2
    this.onDiagnostic = null; // Phase 1D-2C-1
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
