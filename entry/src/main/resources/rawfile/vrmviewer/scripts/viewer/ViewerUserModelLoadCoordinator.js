/**
 * ViewerUserModelLoadCoordinator — 用户模型加载协调器(Phase 1D-2B-2)
 *
 * 职责:
 * - 在用户点击"加载模型"时,协调 PreparedModelResource → 探测结果 → ViewerCore.loadUserModelResource
 * - 检查加载前置条件(Viewer READY / 资源已准备 / 探测 VERIFIED / URL 一致 / ID 一致 / 格式与依赖允许)
 * - 状态机管理(NOT_REQUESTED / LOADING / READY / FAILED / DISPOSED)
 * - 竞态保护(loadGeneration + activePromise + disposed)
 * - 失败时保留旧模型,不改 Viewer 状态(只改本协调器状态)
 *
 * 不做的事:
 * - 不直接调用 GLTFLoader.load()(由 ViewerCore.loadUserModelResource → ViewerModelLoader.loadModel)
 * - 不直接调用 fetch / arrayBuffer / blob
 * - 不接受外部 URL 参数(只从 PreparedModelResourceKeeper 读取)
 * - 不返回 Promise<string> 给 Bridge(Bridge 同步返回 LOADING,结果通过 getLastResult 轮询)
 *
 * 异步 Bridge 模型:
 *   loadPreparedModelResource()        → 同步启动,立即返回 { success: true, state: 'LOADING' }
 *   getPreparedModelLoadResult()       → 同步获取最近一次结果
 *   clearPreparedModelLoadResult()     → 清除结果(不影响已加载模型)
 *
 * 状态机:
 *   NOT_REQUESTED → LOADING → READY    (加载成功,新模型已替换旧模型)
 *   NOT_REQUESTED → LOADING → FAILED   (加载失败,旧模型保留)
 *   任意 → DISPOSED                    (dispose,不可恢复)
 *   READY/FAILED → NOT_REQUESTED       (clear)
 *
 * 安全约束:
 * - 资源 URL 必须是 https://ark-tavern.local/model/<opaque-id>
 * - probeResult.resourceId 与 resourceUrl 中 opaque id 必须一致
 * - .gltf 文件仅 gltfDependencyState === SELF_CONTAINED 时允许加载
 * - 结果对象不包含 cachePath / sourceUri / 文件描述符
 *
 * Reference:
 * - AGENTS.md Phase 1D-2B-2 §九 / §十 / §十一 / §十六 / §二十三
 * - ITEM-008 实施记录(ARKWEB_FIGURE_PORT_LOG.md)
 */

/**
 * 用户模型加载状态常量。
 */
export const UserModelLoadState = Object.freeze({
  NOT_REQUESTED: 'NOT_REQUESTED',
  LOADING: 'LOADING',
  READY: 'READY',
  FAILED: 'FAILED',
  DISPOSED: 'DISPOSED'
});

/**
 * 用户模型加载错误码。
 */
export const UserModelLoadErrorCode = Object.freeze({
  RESOURCE_NOT_PREPARED: 'RESOURCE_NOT_PREPARED',
  RESOURCE_NOT_VERIFIED: 'RESOURCE_NOT_VERIFIED',
  RESOURCE_PROBE_STALE: 'RESOURCE_PROBE_STALE',
  RESOURCE_ID_MISMATCH: 'RESOURCE_ID_MISMATCH',
  VIEWER_NOT_READY: 'VIEWER_NOT_READY',
  MODEL_LOAD_IN_PROGRESS: 'MODEL_LOAD_IN_PROGRESS',
  MODEL_RESOURCE_UNSUPPORTED: 'MODEL_RESOURCE_UNSUPPORTED',
  MODEL_LOAD_FAILED: 'MODEL_LOAD_FAILED',
  MODEL_LOAD_STALE: 'MODEL_LOAD_STALE',
  MODEL_LOAD_COORDINATOR_DISPOSED: 'MODEL_LOAD_COORDINATOR_DISPOSED'
});

/**
 * 受控资源 URL 前缀(与 ArkTS ModelResourceUrlConfig.RESOURCE_URL_PREFIX 对齐)。
 */
var CONTROLLED_URL_PREFIX = 'https://ark-tavern.local/model/';

/**
 * 从受控 URL 提取 opaque id。
 * @param {string} resourceUrl
 * @returns {string} opaque id;空字符串表示 URL 不合法
 */
function extractOpaqueIdFromUrl(resourceUrl) {
  if (typeof resourceUrl !== 'string' || resourceUrl.length === 0) {
    return '';
  }
  if (resourceUrl.indexOf(CONTROLLED_URL_PREFIX) !== 0) {
    return '';
  }
  var tail = resourceUrl.substring(CONTROLLED_URL_PREFIX.length);
  if (tail.length === 0) {
    return '';
  }
  var queryIdx = tail.indexOf('?');
  if (queryIdx >= 0) {
    tail = tail.substring(0, queryIdx);
  }
  var fragIdx = tail.indexOf('#');
  if (fragIdx >= 0) {
    tail = tail.substring(0, fragIdx);
  }
  if (tail.indexOf('/') >= 0) {
    return '';
  }
  return tail;
}

/**
 * 用户模型加载协调器。
 *
 * 使用方式:
 * 1. 在 app.js 中创建实例,传入 viewer(ViewerCore)
 * 2. Bridge loadPreparedModelResource() 调用 coordinator.start(resource, probeResult)
 * 3. Bridge getPreparedModelLoadResult() 调用 coordinator.getLastResult()
 * 4. Bridge clearPreparedModelLoadResult() 调用 coordinator.clear()
 * 5. 页面销毁时调用 coordinator.dispose()
 */
export class ViewerUserModelLoadCoordinator {
  /**
   * @param {object} options
   * @param {object} options.viewer ViewerCore 实例(必须实现 getState / loadUserModelResource)
   */
  constructor(options) {
    options = options || {};
    /** @type {object|null} */
    this.viewer = options.viewer || null;
    /** @type {string} */
    this.state = UserModelLoadState.NOT_REQUESTED;
    /** @type {object|null} 最近一次加载结果(READY / FAILED 时非 null) */
    this.lastResult = null;
    /** @type {number} 加载代次(每次 start 递增,用于过期判断) */
    this.loadGeneration = 0;
    /** @type {Promise|null} 当前正在进行的加载 Promise(同一时间只允许一个) */
    this.activePromise = null;
    /** @type {boolean} 是否已销毁 */
    this.disposed = false;
  }

  /**
   * 启动用户模型加载。
   *
   * 同步检查前置条件,通过后异步启动加载,立即返回 LOADING 结果。
   * 最终结果通过 getLastResult() 轮询获取。
   *
   * @param {object} resource 已准备的资源(来自 PreparedModelResourceKeeper)
   * @param {object} probeResult 探测结果(来自 ViewerModelResourceProbe.getLastResult())
   * @returns {object} 启动结果(包含 state 字段)
   */
  start(resource, probeResult) {
    // 1. disposed 检查
    if (this.disposed) {
      this.lastResult = this._buildFailedResult(
        '',
        '',
        UserModelLoadErrorCode.MODEL_LOAD_COORDINATOR_DISPOSED,
        'Coordinator disposed'
      );
      this.state = UserModelLoadState.FAILED;
      return this.lastResult;
    }

    // 2. 已有 activePromise:拒绝重复启动
    if (this.activePromise !== null) {
      this.lastResult = this._buildFailedResult(
        resource && resource.resourceUrl ? resource.resourceUrl : '',
        resource && resource.displayName ? resource.displayName : '',
        UserModelLoadErrorCode.MODEL_LOAD_IN_PROGRESS,
        'A user model load is already in progress'
      );
      // 不更新 state(保持 LOADING)
      return this.lastResult;
    }

    // 3. 前置条件检查
    var precheck = this._checkPreconditions(resource, probeResult);
    if (precheck !== null) {
      this.lastResult = precheck;
      this.state = UserModelLoadState.FAILED;
      return this.lastResult;
    }

    // 4. 启动加载
    var generation = ++this.loadGeneration;
    this.state = UserModelLoadState.LOADING;
    this.lastResult = this._buildLoadingResult(resource);

    var promise = this._executeLoad(resource, generation);
    this.activePromise = promise;

    // 异步推进状态(不阻塞 Bridge 返回)
    this._trackAsyncLoad(promise, resource, generation);

    return this.lastResult;
  }

  /**
   * 异步跟踪加载 Promise,完成后更新 state / lastResult。
   * @param {Promise} promise
   * @param {object} resource
   * @param {number} generation
   * @private
   */
  async _trackAsyncLoad(promise, resource, generation) {
    try {
      var result = await promise;
      // 代次检查:若期间有新加载启动或已 dispose,当前结果视为过期
      if (generation !== this.loadGeneration || this.disposed) {
        // 过期结果不更新 state / lastResult(但记录到 console)
        console.warn('[UserModelLoadCoordinator] stale result ignored: gen=' + generation);
        return;
      }
      this.state = result.state;
      this.lastResult = result;
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      if (generation === this.loadGeneration && !this.disposed) {
        this.state = UserModelLoadState.FAILED;
        this.lastResult = this._buildFailedResult(
          resource.resourceUrl,
          resource.displayName,
          UserModelLoadErrorCode.MODEL_LOAD_FAILED,
          'Unexpected exception: ' + msg
        );
      }
    } finally {
      if (this.activePromise === promise) {
        this.activePromise = null;
      }
    }
  }

  /**
   * 检查加载前置条件。
   * @param {object} resource
   * @param {object} probeResult
   * @returns {object|null} 失败结果对象;null 表示通过
   * @private
   */
  _checkPreconditions(resource, probeResult) {
    // Viewer 状态检查
    if (!this.viewer || typeof this.viewer.getState !== 'function') {
      return this._buildFailedResult(
        '',
        '',
        UserModelLoadErrorCode.VIEWER_NOT_READY,
        'Viewer not available'
      );
    }
    var viewerState = this.viewer.getState();
    if (viewerState !== 'READY') {
      return this._buildFailedResult(
        '',
        '',
        UserModelLoadErrorCode.VIEWER_NOT_READY,
        'Viewer state is ' + viewerState + ', expected READY'
      );
    }

    // 资源已准备
    if (!resource || typeof resource !== 'object') {
      return this._buildFailedResult(
        '',
        '',
        UserModelLoadErrorCode.RESOURCE_NOT_PREPARED,
        'No prepared model resource'
      );
    }
    if (typeof resource.resourceUrl !== 'string' || resource.resourceUrl.length === 0) {
      return this._buildFailedResult(
        '',
        '',
        UserModelLoadErrorCode.RESOURCE_NOT_PREPARED,
        'resourceUrl missing or empty'
      );
    }
    if (typeof resource.displayName !== 'string' || resource.displayName.length === 0) {
      return this._buildFailedResult(
        resource.resourceUrl,
        '',
        UserModelLoadErrorCode.RESOURCE_NOT_PREPARED,
        'displayName missing or empty'
      );
    }

    // 受控 URL 检查
    if (resource.resourceUrl.indexOf(CONTROLLED_URL_PREFIX) !== 0) {
      return this._buildFailedResult(
        resource.resourceUrl,
        resource.displayName,
        UserModelLoadErrorCode.RESOURCE_NOT_PREPARED,
        'resourceUrl is not a controlled URL (must start with ' + CONTROLLED_URL_PREFIX + ')'
      );
    }

    // 探测结果检查
    if (!probeResult || typeof probeResult !== 'object') {
      return this._buildFailedResult(
        resource.resourceUrl,
        resource.displayName,
        UserModelLoadErrorCode.RESOURCE_NOT_VERIFIED,
        'No probe result available'
      );
    }
    if (probeResult.state !== 'VERIFIED') {
      return this._buildFailedResult(
        resource.resourceUrl,
        resource.displayName,
        UserModelLoadErrorCode.RESOURCE_NOT_VERIFIED,
        'Probe state is ' + probeResult.state + ', expected VERIFIED'
      );
    }

    // resourceUrl 一致
    if (probeResult.resourceUrl !== resource.resourceUrl) {
      return this._buildFailedResult(
        resource.resourceUrl,
        resource.displayName,
        UserModelLoadErrorCode.RESOURCE_PROBE_STALE,
        'resourceUrl mismatch: resource=' + resource.resourceUrl +
          ', probe=' + probeResult.resourceUrl
      );
    }

    // resourceId 一致(探测结果中的 resourceId 必须等于 URL 中的 opaque id)
    var urlOpaqueId = extractOpaqueIdFromUrl(resource.resourceUrl);
    if (urlOpaqueId.length === 0) {
      return this._buildFailedResult(
        resource.resourceUrl,
        resource.displayName,
        UserModelLoadErrorCode.RESOURCE_ID_MISMATCH,
        'Failed to extract opaque id from URL'
      );
    }
    if (probeResult.resourceId !== urlOpaqueId) {
      return this._buildFailedResult(
        resource.resourceUrl,
        resource.displayName,
        UserModelLoadErrorCode.RESOURCE_ID_MISMATCH,
        'Probe resourceId mismatch with URL opaque id: url=' + urlOpaqueId +
          ', probe=' + probeResult.resourceId
      );
    }

    // 格式与 gltfDependencyState 检查
    var ext = (resource.extension || '').toLowerCase();
    if (ext !== 'vrm' && ext !== 'glb' && ext !== 'gltf') {
      return this._buildFailedResult(
        resource.resourceUrl,
        resource.displayName,
        UserModelLoadErrorCode.MODEL_RESOURCE_UNSUPPORTED,
        'Unsupported format: ' + ext
      );
    }
    if (ext === 'gltf') {
      if (resource.gltfDependencyState !== 'SELF_CONTAINED') {
        return this._buildFailedResult(
          resource.resourceUrl,
          resource.displayName,
          UserModelLoadErrorCode.MODEL_RESOURCE_UNSUPPORTED,
          '该 glTF 依赖外部 .bin、纹理或远程资源,当前阶段不能直接加载。' +
            ' (gltfDependencyState=' + resource.gltfDependencyState + ')'
        );
      }
    }

    return null;
  }

  /**
   * 实际执行加载(调用 ViewerCore.loadUserModelResource)。
   * @param {object} resource
   * @param {number} generation
   * @returns {Promise<object>} 加载结果对象(READY / FAILED)
   * @private
   */
  async _executeLoad(resource, generation) {
    try {
      await this.viewer.loadUserModelResource(resource);
      // 代次检查:若期间有新加载或 dispose,返回 stale
      if (generation !== this.loadGeneration || this.disposed) {
        return this._buildFailedResult(
          resource.resourceUrl,
          resource.displayName,
          UserModelLoadErrorCode.MODEL_LOAD_STALE,
          'Load result is stale (generation mismatch)'
        );
      }
      return this._buildReadyResult(resource);
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      return this._buildFailedResult(
        resource.resourceUrl,
        resource.displayName,
        UserModelLoadErrorCode.MODEL_LOAD_FAILED,
        msg
      );
    }
  }

  /**
   * 构造 LOADING 结果。
   * @param {object} resource
   * @returns {object}
   * @private
   */
  _buildLoadingResult(resource) {
    var now = Date.now();
    return {
      state: UserModelLoadState.LOADING,
      resourceUrl: resource.resourceUrl,
      displayName: resource.displayName,
      modelDisplayName: '',
      errorCode: '',
      errorMessage: '',
      startedAt: now,
      completedAt: 0
    };
  }

  /**
   * 构造 READY 结果。
   * @param {object} resource
   * @returns {object}
   * @private
   */
  _buildReadyResult(resource) {
    var now = Date.now();
    var startedAt = (this.lastResult && this.lastResult.startedAt) ? this.lastResult.startedAt : now;
    return {
      state: UserModelLoadState.READY,
      resourceUrl: resource.resourceUrl,
      displayName: resource.displayName,
      modelDisplayName: resource.displayName,
      errorCode: '',
      errorMessage: '',
      startedAt: startedAt,
      completedAt: now
    };
  }

  /**
   * 构造 FAILED 结果。
   * @param {string} resourceUrl
   * @param {string} displayName
   * @param {string} errorCode
   * @param {string} errorMessage
   * @returns {object}
   * @private
   */
  _buildFailedResult(resourceUrl, displayName, errorCode, errorMessage) {
    var now = Date.now();
    var startedAt = (this.lastResult && this.lastResult.startedAt) ? this.lastResult.startedAt : now;
    return {
      state: UserModelLoadState.FAILED,
      resourceUrl: resourceUrl || '',
      displayName: displayName || '',
      modelDisplayName: '',
      errorCode: errorCode,
      errorMessage: errorMessage || '',
      startedAt: startedAt,
      completedAt: now
    };
  }

  /**
   * 获取当前状态。
   * @returns {string}
   */
  getState() {
    return this.state;
  }

  /**
   * 获取最近一次加载结果。
   * @returns {object|null}
   */
  getLastResult() {
    return this.lastResult;
  }

  /**
   * 是否正在加载。
   * @returns {boolean}
   */
  isLoading() {
    return this.state === UserModelLoadState.LOADING;
  }

  /**
   * 清除加载结果(不影响已加载模型)。
   * - 重置 state 为 NOT_REQUESTED
   * - 清空 lastResult
   * - 不取消正在进行的加载(其结果会因代次检查被忽略)
   * - 不影响已加载到 Viewer 的模型
   */
  clear() {
    if (this.disposed) {
      return;
    }
    this.state = UserModelLoadState.NOT_REQUESTED;
    this.lastResult = null;
    this.loadGeneration++;
    // 不重置 activePromise,正在进行的加载完成后会被忽略
  }

  /**
   * 销毁协调器(页面销毁时调用)。
   * - 标记 disposed
   * - 清空 state / lastResult
   * - 不主动取消正在进行的加载(ViewerCore.dispose 会让 ViewerModelLoader.loadGeneration 失效)
   */
  dispose() {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.state = UserModelLoadState.DISPOSED;
    this.lastResult = null;
    this.loadGeneration++;
    this.viewer = null;
    // 不重置 activePromise,正在进行的加载完成后会被忽略
  }
}
