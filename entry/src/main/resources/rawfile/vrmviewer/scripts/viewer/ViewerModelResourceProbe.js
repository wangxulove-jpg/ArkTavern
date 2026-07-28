/**
 * ViewerModelResourceProbe — ArkWeb 受控模型资源探测器(Phase 1D-2B-1)
 *
 * 职责:
 * - 通过 HEAD 请求探测 ArkWebModelResourceProvider 暴露的受控资源 URL
 * - 校验响应状态码、Content-Type、Content-Length、X-ArkTavern-Resource-Id
 * - 不读取模型文件内容(不调用 arrayBuffer / blob / getReader)
 * - 竞态保护(probeGeneration + activePromise)
 *
 * 探测链路:
 *   PreparedModelResource (window.arkTavernPreparedModelResource)
 *     ↓
 *   fetch(resourceUrl, { method: 'HEAD', cache: 'no-store', redirect: 'error' })
 *     ↓
 *   ArkWeb onInterceptRequest 拦截
 *     ↓
 *   ArkWebModelResourceProvider.handleRequest(url, 'HEAD', headers)
 *     ↓
 *   返回 200 + 响应头(不打开文件)
 *     ↓
 *   JavaScript 校验 status / MIME / Length / ID / redirected
 *     ↓
 *   RESOURCE_VERIFIED / RESOURCE_PROBE_FAILED
 *
 * 安全约束:
 * - 不读取响应 body(HEAD 无 body)
 * - 不调用 response.arrayBuffer() / response.blob() / response.body.getReader()
 * - 不调用 GLTFLoader.load() / ViewerModelLoader.loadModel()
 * - 探测结果只含状态与响应头字段,不含 cachePath / sourceUri
 *
 * 竞态保护:
 * - probeGeneration:每次探测递增,完成后检查是否已过期
 * - activePromise:同一资源正在探测时不重复发起 HEAD 请求
 * - disposed:true 后所有探测返回 RESOURCE_PROBE_DISPOSED
 *
 * Reference:
 * - AGENTS.md Phase 1D-2B-1 §九 / §十 / §十一
 * - ITEM-007 实施记录(ARKWEB_FIGURE_PORT_LOG.md)
 */

/**
 * 探测状态常量(与 ArkTS ModelResourceProbeState 字符串对齐)。
 */
export const ResourceProbeState = Object.freeze({
  NOT_PROBED: 'NOT_PROBED',
  PROBING: 'PROBING',
  VERIFIED: 'VERIFIED',
  FAILED: 'FAILED'
});

/**
 * 探测错误码常量(与 ArkTS ModelResourceProbeErrorCode 字符串对齐)。
 */
export const ResourceProbeErrorCode = Object.freeze({
  RESOURCE_NOT_PREPARED: 'RESOURCE_NOT_PREPARED',
  RESOURCE_PROBE_DISPOSED: 'RESOURCE_PROBE_DISPOSED',
  RESOURCE_PROBE_IN_PROGRESS: 'RESOURCE_PROBE_IN_PROGRESS',
  RESOURCE_FETCH_FAILED: 'RESOURCE_FETCH_FAILED',
  RESOURCE_HTTP_STATUS_INVALID: 'RESOURCE_HTTP_STATUS_INVALID',
  RESOURCE_REDIRECTED: 'RESOURCE_REDIRECTED',
  RESOURCE_MIME_MISMATCH: 'RESOURCE_MIME_MISMATCH',
  RESOURCE_LENGTH_MISSING: 'RESOURCE_LENGTH_MISSING',
  RESOURCE_LENGTH_INVALID: 'RESOURCE_LENGTH_INVALID',
  RESOURCE_LENGTH_MISMATCH: 'RESOURCE_LENGTH_MISMATCH',
  RESOURCE_ID_MISSING: 'RESOURCE_ID_MISSING',
  RESOURCE_ID_MISMATCH: 'RESOURCE_ID_MISMATCH'
});

/**
 * 构造失败结果对象(不抛异常)。
 *
 * @param {string} resourceUrl 资源 URL
 * @param {string} errorCode 错误码(见 ResourceProbeErrorCode)
 * @param {string} errorMessage 错误消息
 * @param {number} [statusCode=0] HTTP 状态码(fetch 失败时为 0)
 * @returns {Object} 失败结果对象
 */
function buildFailedResult(resourceUrl, errorCode, errorMessage, statusCode) {
  return {
    state: ResourceProbeState.FAILED,
    resourceUrl: resourceUrl || '',
    statusCode: typeof statusCode === 'number' ? statusCode : 0,
    mimeType: '',
    contentLength: -1,
    resourceId: '',
    redirected: false,
    errorCode: errorCode,
    errorMessage: errorMessage || '',
    verifiedAt: Date.now()
  };
}

/**
 * 构造成功结果对象。
 *
 * @param {string} resourceUrl 资源 URL
 * @param {number} statusCode HTTP 状态码
 * @param {string} mimeType 响应 Content-Type
 * @param {number} contentLength 响应 Content-Length
 * @param {string} resourceId 响应 X-ArkTavern-Resource-Id
 * @param {boolean} redirected 是否发生重定向
 * @returns {Object} 成功结果对象
 */
function buildVerifiedResult(resourceUrl, statusCode, mimeType, contentLength, resourceId, redirected) {
  return {
    state: ResourceProbeState.VERIFIED,
    resourceUrl: resourceUrl,
    statusCode: statusCode,
    mimeType: mimeType,
    contentLength: contentLength,
    resourceId: resourceId,
    redirected: redirected === true,
    errorCode: '',
    errorMessage: '',
    verifiedAt: Date.now()
  };
}

/**
 * ArkWeb 受控模型资源探测器。
 *
 * 使用方式:
 * 1. 在 app.js 中创建实例(不放进 ViewerCore)
 * 2. prepareModelResource() 成功后调用 probe.clear()(重置状态)
 * 3. 用户点击"验证资源"时调用 probe.probe(resource)
 * 4. 通过 probe.getLastResult() 获取最近探测结果
 * 5. 资源被替换 / 清除 / 页面销毁时调用 probe.clear() 或 probe.dispose()
 */
export class ViewerModelResourceProbe {
  constructor() {
    /** 当前探测状态(初始 NOT_PROBED)。 */
    this.state = ResourceProbeState.NOT_PROBED;
    /** 最近一次探测结果(初始 null)。 */
    this.lastResult = null;
    /** 探测代次(每次 probe 递增,用于过期判断)。 */
    this.probeGeneration = 0;
    /** 是否已销毁。 */
    this.disposed = false;
    /** 当前正在进行的探测 Promise(同一资源不重复发起)。 */
    this.activePromise = null;
  }

  /**
   * 探测已准备的模型资源。
   *
   * @param {Object} resource 已准备的资源对象(来自 window.arkTavernPreparedModelResource)
   *   必需字段:resourceUrl / displayName / mimeType / size / extension
   * @returns {Promise<Object>} 探测结果对象(成功或失败,不抛异常)
   */
  async probe(resource) {
    // 已销毁
    if (this.disposed) {
      var result = buildFailedResult(
        resource && resource.resourceUrl ? resource.resourceUrl : '',
        ResourceProbeErrorCode.RESOURCE_PROBE_DISPOSED,
        'Probe disposed'
      );
      this.state = ResourceProbeState.FAILED;
      this.lastResult = result;
      return result;
    }

    // 资源未准备
    if (!resource || typeof resource !== 'object') {
      var result = buildFailedResult(
        '',
        ResourceProbeErrorCode.RESOURCE_NOT_PREPARED,
        'No prepared model resource'
      );
      this.state = ResourceProbeState.FAILED;
      this.lastResult = result;
      return result;
    }
    if (typeof resource.resourceUrl !== 'string' || resource.resourceUrl.length === 0) {
      var result = buildFailedResult(
        '',
        ResourceProbeErrorCode.RESOURCE_NOT_PREPARED,
        'resourceUrl missing or empty'
      );
      this.state = ResourceProbeState.FAILED;
      this.lastResult = result;
      return result;
    }

    // 已有探测进行中:返回进行中错误(不重复发起 HEAD 请求)
    if (this.activePromise !== null) {
      var result = buildFailedResult(
        resource.resourceUrl,
        ResourceProbeErrorCode.RESOURCE_PROBE_IN_PROGRESS,
        'A probe is already in progress'
      );
      // 不更新 lastResult(等正在进行的探测完成后再更新)
      return result;
    }

    // 启动新探测
    var generation = ++this.probeGeneration;
    this.state = ResourceProbeState.PROBING;
    // 暂存 PROBING 状态的 lastResult(供 UI 立即反馈)
    this.lastResult = {
      state: ResourceProbeState.PROBING,
      resourceUrl: resource.resourceUrl,
      statusCode: 0,
      mimeType: '',
      contentLength: -1,
      resourceId: '',
      redirected: false,
      errorCode: '',
      errorMessage: '',
      verifiedAt: Date.now()
    };

    var promise = this._executeProbe(resource, generation);
    this.activePromise = promise;

    try {
      var result = await promise;
      // 代次检查:若期间有新探测启动或已 dispose,当前结果视为过期
      if (generation !== this.probeGeneration || this.disposed) {
        // 过期结果不更新 state / lastResult
        return result;
      }
      this.state = result.state;
      this.lastResult = result;
      return result;
    } catch (e) {
      // _executeProbe 内部已捕获所有异常,这里兜底
      var msg = e && e.message ? e.message : String(e);
      var errResult = buildFailedResult(
        resource.resourceUrl,
        ResourceProbeErrorCode.RESOURCE_FETCH_FAILED,
        'Probe threw: ' + msg
      );
      if (generation === this.probeGeneration && !this.disposed) {
        this.state = ResourceProbeState.FAILED;
        this.lastResult = errResult;
      }
      return errResult;
    } finally {
      if (this.activePromise === promise) {
        this.activePromise = null;
      }
    }
  }

  /**
   * 执行实际的 HEAD fetch 与校验(内部方法)。
   *
   * @param {Object} resource 资源对象
   * @param {number} generation 探测代次
   * @returns {Promise<Object>} 探测结果
   */
  async _executeProbe(resource, generation) {
    var resourceUrl = resource.resourceUrl;
    var expectedMime = resource.mimeType;
    var expectedSize = resource.size;

    // 1. 发起 HEAD 请求
    var response;
    try {
      response = await fetch(resourceUrl, {
        method: 'HEAD',
        cache: 'no-store',
        redirect: 'error'
      });
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_FETCH_FAILED,
        'fetch HEAD failed: ' + msg
      );
    }

    // 代次检查(异步等待期间可能已过期)
    if (generation !== this.probeGeneration || this.disposed) {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_PROBE_DISPOSED,
        'Probe stale'
      );
    }

    // 2. 检查重定向
    if (response.redirected) {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_REDIRECTED,
        'Response was redirected',
        response.status
      );
    }

    // 3. 检查 HTTP 状态码
    if (!response.ok || response.status !== 200) {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_HTTP_STATUS_INVALID,
        'HTTP status ' + response.status + ' (expected 200)',
        response.status
      );
    }

    // 4. 检查 Content-Type
    var contentType = response.headers.get('Content-Type');
    if (contentType === null || contentType === undefined || contentType === '') {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_MIME_MISMATCH,
        'Content-Type header missing',
        response.status
      );
    }
    // 比较基础 MIME(忽略 charset 参数,如 model/gltf+json; charset=utf-8)
    var actualBaseMime = contentType.split(';')[0].trim().toLowerCase();
    var expectedBaseMime = String(expectedMime).split(';')[0].trim().toLowerCase();
    if (actualBaseMime !== expectedBaseMime) {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_MIME_MISMATCH,
        'Content-Type mismatch: expected ' + expectedBaseMime + ', got ' + actualBaseMime,
        response.status
      );
    }

    // 5. 检查 Content-Length
    var contentLengthStr = response.headers.get('Content-Length');
    if (contentLengthStr === null || contentLengthStr === undefined || contentLengthStr === '') {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_LENGTH_MISSING,
        'Content-Length header missing',
        response.status
      );
    }
    var contentLength = Number(contentLengthStr);
    if (!Number.isSafeInteger(contentLength) || contentLength < 0) {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_LENGTH_INVALID,
        'Content-Length not a safe non-negative integer: ' + contentLengthStr,
        response.status
      );
    }
    if (contentLength !== expectedSize) {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_LENGTH_MISMATCH,
        'Content-Length mismatch: expected ' + expectedSize + ', got ' + contentLength,
        response.status
      );
    }

    // 6. 检查 X-ArkTavern-Resource-Id
    var resourceId = response.headers.get('X-ArkTavern-Resource-Id');
    if (resourceId === null || resourceId === undefined || resourceId === '') {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_ID_MISSING,
        'X-ArkTavern-Resource-Id header missing',
        response.status
      );
    }

    // 6.1 Phase 1D-2B-2:验证 resourceId 与 resourceUrl 中 /model/ 后的 opaque id 一致
    //     受控 URL 格式:https://ark-tavern.local/model/<opaque-id>
    //     opaque id 即 URL 最后一个路径段
    var urlOpaqueId = '';
    var lastSlash = resourceUrl.lastIndexOf('/');
    if (lastSlash >= 0 && lastSlash < resourceUrl.length - 1) {
      urlOpaqueId = resourceUrl.substring(lastSlash + 1);
      // 移除可能的 query / fragment(虽然 isModelResourceUrl 已禁止,但探测时再做一次防御)
      var queryIdx = urlOpaqueId.indexOf('?');
      if (queryIdx >= 0) {
        urlOpaqueId = urlOpaqueId.substring(0, queryIdx);
      }
      var fragIdx = urlOpaqueId.indexOf('#');
      if (fragIdx >= 0) {
        urlOpaqueId = urlOpaqueId.substring(0, fragIdx);
      }
    }
    if (urlOpaqueId.length === 0 || urlOpaqueId !== resourceId) {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_ID_MISMATCH,
        'Resource ID mismatch: URL opaque id=\'' + urlOpaqueId + '\', header=\'' + resourceId + '\'',
        response.status
      );
    }

    // 7. 全部校验通过
    return buildVerifiedResult(
      resourceUrl,
      response.status,
      contentType,
      contentLength,
      resourceId,
      response.redirected
    );
  }

  /**
   * 获取当前探测状态。
   * @returns {string} 状态字符串(见 ResourceProbeState)
   */
  getState() {
    return this.state;
  }

  /**
   * 获取最近一次探测结果。
   * @returns {Object|null} 探测结果对象,未探测时为 null
   */
  getLastResult() {
    return this.lastResult;
  }

  /**
   * 清除探测状态(资源被替换 / 清除时调用)。
   *
   * - 重置 state 为 NOT_PROBED
   * - 清空 lastResult
   * - 不影响正在进行的探测(代次检查会让其结果过期)
   */
  clear() {
    this.state = ResourceProbeState.NOT_PROBED;
    this.lastResult = null;
    // 递增代次使正在进行的探测结果过期
    this.probeGeneration++;
    // 注意:不重置 activePromise,正在进行的 fetch 会自然完成
    // 其结果会因代次不匹配而被忽略
  }

  /**
   * 销毁探测器(页面销毁时调用)。
   *
   * - 标记 disposed,所有后续探测返回 RESOURCE_PROBE_DISPOSED
   * - 清空 state / lastResult
   * - 不主动取消正在进行的 fetch(浏览器/ArkWeb 不支持取消)
   *   其结果会因 disposed 检查而被忽略
   */
  dispose() {
    this.disposed = true;
    this.state = ResourceProbeState.NOT_PROBED;
    this.lastResult = null;
    this.probeGeneration++;
    // 不重置 activePromise,正在进行的 fetch 完成后会被忽略
  }
}
