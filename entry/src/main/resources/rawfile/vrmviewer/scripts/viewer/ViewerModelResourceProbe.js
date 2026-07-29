/**
 * ViewerModelResourceProbe — ArkWeb 受控模型资源探测器
 *
 * Phase 1D-2B-1 初始实现
 * Phase 1D-2B-2 增加 X-ArkTavern-Resource-Id 一致性校验
 * Phase 1D-2C-2E-2A 增加自定义长度头 X-ArkTavern-Content-Length 优先解析
 *
 * 职责:
 * - 通过 HEAD 请求探测 ArkWebModelResourceProvider 暴露的受控资源 URL
 * - 校验响应状态码、Content-Type、Content-Length(自定义头优先)、X-ArkTavern-Resource-Id
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
 *   返回 200 + 响应头(包含 Content-Length + X-ArkTavern-Content-Length)
 *     ↓
 *   JavaScript 校验 status / MIME / Length / ID / redirected
 *     ↓ (Length 优先使用 X-ArkTavern-Content-Length,标准头作为兼容回退)
 *   RESOURCE_VERIFIED / RESOURCE_PROBE_FAILED
 *
 * Phase 1D-2C-2E-2A 长度解析优先级:
 *   1. X-ArkTavern-Content-Length 有效 → 使用自定义头(contentLengthSource = CUSTOM)
 *   2. 自定义头缺失,标准 Content-Length 为有效正整数 → 使用标准头(STANDARD)
 *   3. 自定义头缺失,标准 Content-Length = 0 → RESOURCE_LENGTH_UNAVAILABLE
 *   4. 两个头都缺失 → RESOURCE_LENGTH_MISSING
 *   5. 自定义头存在但无效(非数字) → RESOURCE_CUSTOM_LENGTH_INVALID
 *   6. 自定义头存在但与 expected size 不一致 → RESOURCE_LENGTH_MISMATCH
 *
 * 安全约束:
 * - 不读取响应 body(HEAD 无 body)
 * - 不调用 response.arrayBuffer() / response.blob() / response.body.getReader()
 * - 不调用 GLTFLoader.load() / ViewerModelLoader.loadModel()
 * - 探测结果只含状态与响应头字段,不含 cachePath / sourceUri
 * - 不记录完整 Headers 对象(仅记录已解析的数值)
 *
 * 竞态保护:
 * - probeGeneration:每次探测递增,完成后检查是否已过期
 * - activePromise:同一资源正在探测时不重复发起 HEAD 请求
 * - disposed:true 后所有探测返回 RESOURCE_PROBE_DISPOSED
 *
 * Reference:
 * - AGENTS.md Phase 1D-2B-1 §九 / §十 / §十一
 * - Phase 1D-2C-2E-1-T2: 根因分类 = ARKWEB_RUNTIME_HEADER_VISIBILITY
 * - Phase 1D-2C-2E-2A: 双头验证方案
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
 *
 * Phase 1D-2C-2E-2A 新增:
 * - RESOURCE_CUSTOM_LENGTH_INVALID: 自定义头存在但无法解析
 * - RESOURCE_LENGTH_UNAVAILABLE: 自定义头缺失且标准头为 0
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
  RESOURCE_ID_MISMATCH: 'RESOURCE_ID_MISMATCH',
  // Phase 1D-2C-2E-2A 新增
  RESOURCE_CUSTOM_LENGTH_INVALID: 'RESOURCE_CUSTOM_LENGTH_INVALID',
  RESOURCE_LENGTH_UNAVAILABLE: 'RESOURCE_LENGTH_UNAVAILABLE'
});

/**
 * Phase 1D-2C-2E-2A: 长度来源类型常量。
 *
 * 用于 Probe 结果中的 contentLengthSource 字段,标识最终选用的长度证明来源。
 */
export const ResourceLengthSource = Object.freeze({
  CUSTOM: 'CUSTOM',
  STANDARD: 'STANDARD',
  UNAVAILABLE: 'UNAVAILABLE'
});

/**
 * 构造失败结果对象(不抛异常)。
 *
 * Phase 1D-2C-2E-2A: 失败结果也包含长度诊断字段(默认 -1 / ''),
 * 保证 ArkTS 端解析时所有字段都存在。
 *
 * @param {string} resourceUrl 资源 URL
 * @param {string} errorCode 错误码(见 ResourceProbeErrorCode)
 * @param {string} errorMessage 错误消息
 * @param {number} [statusCode=0] HTTP 状态码(fetch 失败时为 0)
 * @param {object} [lengthDiagnostic] 长度诊断字段(可选)
 *   @param {number} [lengthDiagnostic.customContentLength]
 *   @param {number} [lengthDiagnostic.standardContentLength]
 *   @param {string} [lengthDiagnostic.contentLengthSource]
 * @returns {Object} 失败结果对象
 */
function buildFailedResult(resourceUrl, errorCode, errorMessage, statusCode, lengthDiagnostic) {
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
    verifiedAt: Date.now(),
    contentLengthSource: (lengthDiagnostic && lengthDiagnostic.contentLengthSource) || '',
    customContentLength: (lengthDiagnostic && typeof lengthDiagnostic.customContentLength === 'number')
      ? lengthDiagnostic.customContentLength
      : -1,
    standardContentLength: (lengthDiagnostic && typeof lengthDiagnostic.standardContentLength === 'number')
      ? lengthDiagnostic.standardContentLength
      : -1
  };
}

/**
 * 构造成功结果对象。
 *
 * Phase 1D-2C-2E-2A: 成功结果必须包含 contentLengthSource / customContentLength / standardContentLength,
 * 以便 ArkTS 端 UI 显示"长度来源: 自定义响应头"等诊断信息。
 *
 * @param {string} resourceUrl 资源 URL
 * @param {number} statusCode HTTP 状态码
 * @param {string} mimeType 响应 Content-Type
 * @param {number} contentLength 选定的 Content-Length(优先来自自定义头)
 * @param {string} resourceId 响应 X-ArkTavern-Resource-Id
 * @param {boolean} redirected 是否发生重定向
 * @param {string} contentLengthSource 长度来源(CUSTOM / STANDARD)
 * @param {number} customContentLength 自定义头解析值(失败时为 -1)
 * @param {number} standardContentLength 标准头解析值(失败时为 -1)
 * @returns {Object} 成功结果对象
 */
function buildVerifiedResult(
  resourceUrl,
  statusCode,
  mimeType,
  contentLength,
  resourceId,
  redirected,
  contentLengthSource,
  customContentLength,
  standardContentLength
) {
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
    verifiedAt: Date.now(),
    contentLengthSource: contentLengthSource,
    customContentLength: typeof customContentLength === 'number' ? customContentLength : -1,
    standardContentLength: typeof standardContentLength === 'number' ? standardContentLength : -1
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
      verifiedAt: Date.now(),
      contentLengthSource: '',
      customContentLength: -1,
      standardContentLength: -1
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
   * Phase 1D-2C-2E-2A: 长度校验改为双头优先级解析
   * (X-ArkTavern-Content-Length 优先,标准 Content-Length 兼容回退)。
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

    // 5. Phase 1D-2C-2E-2A: 双头长度解析
    //    优先级:
    //      a. 自定义头存在 → 解析为整数
    //         - 解析失败 → RESOURCE_CUSTOM_LENGTH_INVALID(不回退到标准头)
    //         - 与 expectedSize 不一致 → RESOURCE_LENGTH_MISMATCH
    //         - 一致 → 使用自定义头 (CUSTOM)
    //      b. 自定义头缺失,标准头存在 → 解析为整数
    //         - 解析失败 → RESOURCE_LENGTH_INVALID
    //         - 与 expectedSize 不一致 → RESOURCE_LENGTH_MISMATCH
    //         - 一致 → 使用标准头 (STANDARD)
    //      c. 两个头都缺失 → RESOURCE_LENGTH_MISSING
    //      d. 自定义头缺失,标准头 = 0 → RESOURCE_LENGTH_UNAVAILABLE
    //      e. 自定义头缺失,标准头存在但非数字 → RESOURCE_LENGTH_INVALID
    var customLengthStr = response.headers.get('X-ArkTavern-Content-Length');
    var standardLengthStr = response.headers.get('Content-Length');

    // 解析标准头(用于诊断字段,无论是否最终使用)
    // standardContentLength: -1 = 缺失或未解析, >=0 = 解析成功
    // standardHeaderPresent: 标准头是否存在(非空字符串),用于区分 MISSING 与 INVALID
    var standardContentLength = -1;
    var standardHeaderPresent = (
      standardLengthStr !== null && standardLengthStr !== undefined && standardLengthStr !== ''
    );
    if (standardHeaderPresent) {
      var parsedStandard = Number(standardLengthStr);
      if (Number.isSafeInteger(parsedStandard) && parsedStandard >= 0) {
        standardContentLength = parsedStandard;
      }
    }

    // 解析自定义头
    var customContentLength = -1;
    var customHeaderPresent = (customLengthStr !== null && customLengthStr !== undefined && customLengthStr !== '');

    if (customHeaderPresent) {
      var parsedCustom = Number(customLengthStr);
      if (!Number.isSafeInteger(parsedCustom) || parsedCustom < 0) {
        // 自定义头存在但无效 → RESOURCE_CUSTOM_LENGTH_INVALID(不回退)
        return buildFailedResult(
          resourceUrl,
          ResourceProbeErrorCode.RESOURCE_CUSTOM_LENGTH_INVALID,
          'X-ArkTavern-Content-Length not a safe non-negative integer: ' + customLengthStr,
          response.status,
          {
            customContentLength: -1,
            standardContentLength: standardContentLength,
            contentLengthSource: ResourceLengthSource.UNAVAILABLE
          }
        );
      }
      customContentLength = parsedCustom;

      if (customContentLength !== expectedSize) {
        return buildFailedResult(
          resourceUrl,
          ResourceProbeErrorCode.RESOURCE_LENGTH_MISMATCH,
          'Content-Length mismatch: expected ' + expectedSize + ', got ' + customContentLength
            + ' (source: CUSTOM, standard: ' + standardContentLength + ')',
          response.status,
          {
            customContentLength: customContentLength,
            standardContentLength: standardContentLength,
            contentLengthSource: ResourceLengthSource.CUSTOM
          }
        );
      }

      // 自定义头有效且一致 → 使用 CUSTOM
      var selectedLength = customContentLength;
      var selectedSource = ResourceLengthSource.CUSTOM;
    } else {
      // 自定义头缺失,尝试标准头
      if (!standardHeaderPresent) {
        // 标准头也缺失 → RESOURCE_LENGTH_MISSING
        return buildFailedResult(
          resourceUrl,
          ResourceProbeErrorCode.RESOURCE_LENGTH_MISSING,
          'Content-Length header missing (both custom and standard absent)',
          response.status,
          {
            customContentLength: -1,
            standardContentLength: -1,
            contentLengthSource: ResourceLengthSource.UNAVAILABLE
          }
        );
      }
      if (standardContentLength === -1) {
        // 标准头存在但无法解析为非负整数 → RESOURCE_LENGTH_INVALID
        return buildFailedResult(
          resourceUrl,
          ResourceProbeErrorCode.RESOURCE_LENGTH_INVALID,
          'Content-Length not a safe non-negative integer: ' + standardLengthStr,
          response.status,
          {
            customContentLength: -1,
            standardContentLength: -1,
            contentLengthSource: ResourceLengthSource.UNAVAILABLE
          }
        );
      }
      if (standardContentLength === 0) {
        // 自定义头缺失,标准头 = 0 → RESOURCE_LENGTH_UNAVAILABLE
        // (常见于 ArkWeb HEAD 响应重写 Content-Length 为 0 的情况)
        return buildFailedResult(
          resourceUrl,
          ResourceProbeErrorCode.RESOURCE_LENGTH_UNAVAILABLE,
          'Content-Length unavailable: custom header missing, standard = 0 (expected ' + expectedSize + ')',
          response.status,
          {
            customContentLength: -1,
            standardContentLength: 0,
            contentLengthSource: ResourceLengthSource.UNAVAILABLE
          }
        );
      }
      // 标准头有效且非 0 → 检查一致性
      if (standardContentLength !== expectedSize) {
        return buildFailedResult(
          resourceUrl,
          ResourceProbeErrorCode.RESOURCE_LENGTH_MISMATCH,
          'Content-Length mismatch: expected ' + expectedSize + ', got ' + standardContentLength
            + ' (source: STANDARD, custom: missing)',
          response.status,
          {
            customContentLength: -1,
            standardContentLength: standardContentLength,
            contentLengthSource: ResourceLengthSource.STANDARD
          }
        );
      }
      // 标准头有效且一致 → 使用 STANDARD
      var selectedLength = standardContentLength;
      var selectedSource = ResourceLengthSource.STANDARD;
    }

    // 6. 检查 X-ArkTavern-Resource-Id
    var resourceId = response.headers.get('X-ArkTavern-Resource-Id');
    if (resourceId === null || resourceId === undefined || resourceId === '') {
      return buildFailedResult(
        resourceUrl,
        ResourceProbeErrorCode.RESOURCE_ID_MISSING,
        'X-ArkTavern-Resource-Id header missing',
        response.status,
        {
          customContentLength: customContentLength,
          standardContentLength: standardContentLength,
          contentLengthSource: selectedSource
        }
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
        response.status,
        {
          customContentLength: customContentLength,
          standardContentLength: standardContentLength,
          contentLengthSource: selectedSource
        }
      );
    }

    // 7. 全部校验通过
    return buildVerifiedResult(
      resourceUrl,
      response.status,
      contentType,
      selectedLength,
      resourceId,
      response.redirected,
      selectedSource,
      customContentLength,
      standardContentLength
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
