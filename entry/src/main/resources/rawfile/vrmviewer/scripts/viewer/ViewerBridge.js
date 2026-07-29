/**
 * ViewerBridge — ArkTS ↔ JavaScript 双向通信桥(Phase 1B)
 *
 * 职责:
 * 1. 提供向 ArkTS 回调的工具方法(window.ViewerBridge.notifyXxx),
 *    供 ViewerCore / app.js 在状态变化时调用。
 *    ArkTS 会在 Web 组件上注册名为 arkTavernNative 的 JavaScriptProxy,
 *    提供 onViewerReady / onViewerError / onModelStateChanged / onAnimationStateChanged。
 *
 * 2. 不再直接定义 window.arkTavernViewerBridge(Phase 1A 曾在此处定义占位实现)。
 *    Phase 1B 起,arkTavernViewerBridge 由 app.js(ES Module)在加载后注入,
 *    委托给 ViewerCore 实例,提供:
 *      - initializeViewer / disposeViewer / getViewerState (Phase 1A 兼容)
 *      - resetCamera / resizeViewer / getSceneState         (Phase 1B 新增)
 *
 * 加载顺序:
 *   <script src="ViewerBridge.js">          (普通脚本,同步执行,设置 window.ViewerBridge)
 *   <script type="module" src="app.js">     (ES Module,延迟执行,覆盖 window.arkTavernViewerBridge)
 *   ArkTS onPageEnd → runJavaScript(...)    (在 Module 执行完毕后调用 bridge 方法)
 *
 * Reference:
 * - HarmonyOS ArkWeb: WebviewController.registerJavaScriptProxy / runJavaScript
 * - figure-main: index.html 中的 Figure API 全局对象(参考命名约定)
 * - ownverse-vrm-viewer: VIEWER_ARCHITECTURE.md §Bridge Layer(分层参考)
 */
(function (global) {
  'use strict';

  /**
   * ArkTS 注入的 Native Bridge 句柄。
   * 在 Web 组件 javaScriptProxy 注册完成后,ArkTS 会将其设置为 window.arkTavernNative。
   * 若未注入(如浏览器调试),使用 noop fallback,使 JS 不崩溃。
   */
  function getNativeBridge() {
    if (global.arkTavernNative && typeof global.arkTavernNative === 'object') {
      return global.arkTavernNative;
    }
    return null;
  }

  /**
   * 调用 ArkTS 回调,带错误保护。
   * 若 ArkTS 端方法不存在或调用失败,仅记录到 console,不抛出异常。
   */
  function invokeNative(methodName, payload) {
    var bridge = getNativeBridge();
    if (!bridge) {
      console.warn('[ViewerBridge] arkTavernNative not ready, skip ' + methodName);
      return;
    }
    var fn = bridge[methodName];
    if (typeof fn !== 'function') {
      console.warn('[ViewerBridge] arkTavernNative.' + methodName + ' is not a function');
      return;
    }
    try {
      if (payload === undefined) {
        fn.call(bridge);
      } else {
        fn.call(bridge, payload);
      }
    } catch (e) {
      console.error('[ViewerBridge] invoke ' + methodName + ' failed: ' + (e && e.message ? e.message : String(e)));
    }
  }

  /**
   * 通知 ArkTS:Viewer 已就绪。
   * 由 ViewerCore._notifyReady() 在 initialize 成功后调用。
   */
  function notifyViewerReady() {
    invokeNative('onViewerReady');
  }

  /**
   * 通知 ArkTS:Viewer 发生错误。
   * 由 ViewerCore._notifyError() 在 initialize 失败或运行时错误时调用。
   * @param {string} code 错误代码,如 'SCENE_INITIALIZATION_FAILED' / 'WEBGL_NOT_SUPPORTED'
   * @param {string} message 人类可读错误信息
   * @param {string} [phase] 错误发生时的状态阶段
   * @param {boolean} [recoverable] 是否可恢复
   */
  function notifyViewerError(code, message, phase, recoverable) {
    var payload = JSON.stringify({
      code: code || 'UNKNOWN',
      message: message || '',
      phase: phase || 'UNKNOWN',
      recoverable: recoverable !== false
    });
    invokeNative('onViewerError', payload);
  }

  /**
   * 通知 ArkTS:模型状态变化。
   * Phase 1B:不调用(模型未加载,状态始终为 NOT_LOADED)。
   * Phase 1C+ 在加载 VRM 时调用。
   * @param {string} state 状态字符串,如 'NOT_LOADED' / 'LOADING' / 'READY' / 'FAILED'
   */
  function notifyModelStateChanged(state) {
    invokeNative('onModelStateChanged', state);
  }

  /**
   * 通知 ArkTS:动画状态变化。
   * Phase 1B:不调用(动画未初始化)。
   * Phase 3+ 在加载 / 播放动画时调用。
   * @param {string} state 状态字符串,如 'NOT_LOADED' / 'LOADING' / 'PLAYING' / 'PAUSED' / 'STOPPED' / 'FAILED'
   */
  function notifyAnimationStateChanged(state) {
    invokeNative('onAnimationStateChanged', state);
  }

  // ===== Phase 1D-2A: PreparedModelResourceKeeper =====
  // 缓存模型资源元数据 keeper(协议骨架,不触发任何加载行为)。
  //
  // 设计约束(AGENTS.md Phase 1D-2A §十六 / 1D-2B-2 §五):
  // - 只保存字段白名单:resourceUrl / displayName / mimeType / size / extension / gltfDependencyState(1D-2B-2)
  // - 严禁保存:cachePath / sourceUri / 任何文件系统路径
  // - 严禁调用:ViewerModelLoader.loadModel() / GLTFLoader.load()
  // - 状态保存在 window.arkTavernPreparedModelResource
  // - prepare() 返回 { success: true, state: 'RESOURCE_READY' }
  //
  // 后续 Phase 1D-2B-2 起增加 loadModel() 调用,但加载协调由 ViewerUserModelLoadCoordinator 负责,
  // 本 keeper 仍只保存元数据。

  /** 字段白名单(只允许这些字段进入 preparedResource)。 */
  var PREPARED_RESOURCE_FIELDS = ['resourceUrl', 'displayName', 'mimeType', 'size', 'extension', 'gltfDependencyState'];

  /** 内部 keeper 引用,默认 null(无准备资源)。 */
  function getPreparedRef() {
    if (typeof global.arkTavernPreparedModelResource === 'undefined') {
      global.arkTavernPreparedModelResource = null;
    }
    return global.arkTavernPreparedModelResource;
  }

  /**
   * 准备模型资源(仅保存元数据,不加载)。
   * @param {string} resourceJson ArkTS 传入的 JSON 字符串
   * @returns {string} JSON 结果
   *   成功:{"success": true, "state": "RESOURCE_READY"}
   *   失败:{"success": false, "error": {"code": "...", "message": "..."}}
   */
  function prepareModelResource(resourceJson) {
    var parsed;
    try {
      parsed = JSON.parse(resourceJson);
    } catch (e) {
      return JSON.stringify({
        success: false,
        error: {
          code: 'INVALID_JSON',
          message: 'Failed to parse resourceJson: ' + (e && e.message ? e.message : String(e))
        }
      });
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return JSON.stringify({
        success: false,
        error: { code: 'INVALID_PAYLOAD', message: 'Expected JSON object' }
      });
    }
    // 字段白名单过滤 + 必需字段检查
    var filtered = {};
    var missing = [];
    for (var i = 0; i < PREPARED_RESOURCE_FIELDS.length; i++) {
      var key = PREPARED_RESOURCE_FIELDS[i];
      if (Object.prototype.hasOwnProperty.call(parsed, key)) {
        filtered[key] = parsed[key];
      } else {
        missing.push(key);
      }
    }
    if (missing.length > 0) {
      return JSON.stringify({
        success: false,
        error: { code: 'MISSING_FIELDS', message: 'Missing required fields: ' + missing.join(', ') }
      });
    }
    // 类型基本校验
    if (typeof filtered.resourceUrl !== 'string' || filtered.resourceUrl.length === 0) {
      return JSON.stringify({
        success: false,
        error: { code: 'INVALID_FIELD', message: 'resourceUrl must be non-empty string' }
      });
    }
    if (typeof filtered.size !== 'number' || !isFinite(filtered.size) || filtered.size < 0) {
      return JSON.stringify({
        success: false,
        error: { code: 'INVALID_FIELD', message: 'size must be non-negative finite number' }
      });
    }
    // Phase 1D-2B-2:gltfDependencyState 必须是已知枚举值
    var validDepStates = ['NOT_APPLICABLE', 'SELF_CONTAINED', 'EXTERNAL_FILES_REQUIRED', 'REMOTE_RESOURCES_FOUND', 'INVALID_JSON'];
    if (validDepStates.indexOf(filtered.gltfDependencyState) < 0) {
      return JSON.stringify({
        success: false,
        error: { code: 'INVALID_FIELD', message: 'gltfDependencyState must be one of ' + validDepStates.join('/') }
      });
    }
    // 持久化(只含白名单字段,cachePath / sourceUri 永远不会被保存)
    global.arkTavernPreparedModelResource = filtered;
    console.log('[ViewerBridge] preparedModelResource saved: url=' + filtered.resourceUrl);
    return JSON.stringify({ success: true, state: 'RESOURCE_READY' });
  }

  /**
   * 获取当前已准备的模型资源。
   * @returns {string} JSON 结果
   *   {"success": true, "resource": <object|null>}
   */
  function getPreparedModelResource() {
    return JSON.stringify({
      success: true,
      resource: getPreparedRef()
    });
  }

  /**
   * 清除已准备的模型资源(不影响已加载的模型,本阶段也无已加载模型)。
   * @returns {string} JSON 结果
   *   {"success": true, "state": "RESOURCE_CLEARED"}
   */
  function clearPreparedModelResource() {
    global.arkTavernPreparedModelResource = null;
    console.log('[ViewerBridge] preparedModelResource cleared');
    return JSON.stringify({ success: true, state: 'RESOURCE_CLEARED' });
  }

  // ===== Phase 1D-2C-1: VrmRuntimeDiagnostics keeper =====
  // 运行时诊断记录 keeper,只保存最近一条 VrmRuntimeDiagnostic。
  //
  // 设计约束(AGENTS.md Phase 1D-2C-1 §十三 / §十七):
  // - 诊断对象字段白名单:stage / code / message / resourceId / requestMethod /
  //   httpStatus / mimeType / contentLength / timestamp
  // - 严禁保存:cachePath / sourceUri / fd / stack / 用户目录
  // - 只保留最近一条(覆盖式),不累积历史
  // - getVrmRuntimeDiagnostic() 返回最近一条;无记录时返回 {success: true, diagnostic: null}
  // - clearVrmRuntimeDiagnostic() 清除记录
  //
  // 由 ViewerModelLoader.onDiagnostic 回调(经 ViewerCore._forwardModelLoaderDiagnostic 转发)
  // 与 ViewerUserModelLoadCoordinator.onDiagnostic 回调写入。
  // Provider 的诊断由 ArkTS 端直接处理(不经过此 keeper)。

  /** 诊断字段白名单(只允许这些字段进入 keeper)。 */
  var DIAGNOSTIC_FIELDS = [
    'stage', 'code', 'message', 'resourceId',
    'requestMethod', 'httpStatus', 'mimeType', 'contentLength', 'timestamp'
  ];

  /**
   * 记录一条诊断(覆盖式,只保留最近一条)。
   * @param {object} diagnostic 诊断对象
   */
  function recordDiagnostic(diagnostic) {
    if (!diagnostic || typeof diagnostic !== 'object') {
      console.warn('[ViewerBridge] recordDiagnostic ignored: invalid diagnostic');
      return;
    }
    // 字段白名单过滤 + 类型基本校验
    var filtered = {};
    for (var i = 0; i < DIAGNOSTIC_FIELDS.length; i++) {
      var key = DIAGNOSTIC_FIELDS[i];
      if (Object.prototype.hasOwnProperty.call(diagnostic, key)) {
        var value = diagnostic[key];
        // 基本类型校验:stage/code/message/resourceId/mimeType 为 string,
        // httpStatus/contentLength/timestamp 为 number
        if (key === 'httpStatus' || key === 'contentLength' || key === 'timestamp') {
          if (typeof value === 'number' && isFinite(value)) {
            filtered[key] = value;
          } else {
            filtered[key] = 0;
          }
        } else {
          filtered[key] = typeof value === 'string' ? value : '';
        }
      } else {
        // 缺失字段填充默认值
        if (key === 'httpStatus' || key === 'contentLength' || key === 'timestamp') {
          filtered[key] = 0;
        } else {
          filtered[key] = '';
        }
      }
    }
    global.arkTavernVrmRuntimeDiagnosticRecord = filtered;
  }

  /**
   * 获取最近一条诊断。
   * @returns {string} JSON 结果
   *   {"success": true, "diagnostic": <object|null>}
   */
  function getDiagnostic() {
    var record = null;
    if (typeof global.arkTavernVrmRuntimeDiagnosticRecord !== 'undefined' &&
        global.arkTavernVrmRuntimeDiagnosticRecord !== null) {
      // 复制一份,避免外部修改污染内部记录
      record = {};
      var src = global.arkTavernVrmRuntimeDiagnosticRecord;
      for (var i = 0; i < DIAGNOSTIC_FIELDS.length; i++) {
        var key = DIAGNOSTIC_FIELDS[i];
        if (Object.prototype.hasOwnProperty.call(src, key)) {
          record[key] = src[key];
        }
      }
    }
    return JSON.stringify({ success: true, diagnostic: record });
  }

  /**
   * 清除最近一条诊断。
   * @returns {string} JSON 结果
   *   {"success": true, "state": "DIAGNOSTIC_CLEARED"}
   */
  function clearDiagnostic() {
    global.arkTavernVrmRuntimeDiagnosticRecord = null;
    return JSON.stringify({ success: true, state: 'DIAGNOSTIC_CLEARED' });
  }

  // 暴露 notify 工具到 window.ViewerBridge,供 ViewerCore / app.js 调用。
  global.ViewerBridge = {
    notifyViewerReady: notifyViewerReady,
    notifyViewerError: notifyViewerError,
    notifyModelStateChanged: notifyModelStateChanged,
    notifyAnimationStateChanged: notifyAnimationStateChanged,
    // Phase 1D-2A: 缓存模型资源协议骨架(不触发加载)
    preparedResource: {
      prepare: prepareModelResource,
      get: getPreparedModelResource,
      clear: clearPreparedModelResource
    },
    // Phase 1D-2C-1: 运行时诊断 keeper(只保留最近一条)
    runtimeDiagnostics: {
      record: recordDiagnostic,
      get: getDiagnostic,
      clear: clearDiagnostic
    }
  };

  // Phase 1D-2C-1: 同时暴露 arkTavernVrmRuntimeDiagnostics 给 ViewerCore._forwardModelLoaderDiagnostic 使用
  // (ViewerCore 通过 window.arkTavernVrmRuntimeDiagnostics.record 转发 ModelLoader 诊断)
  global.arkTavernVrmRuntimeDiagnostics = {
    record: recordDiagnostic,
    get: getDiagnostic,
    clear: clearDiagnostic
  };

  console.log('[ViewerBridge] window.ViewerBridge notify helpers + preparedResource keeper + runtimeDiagnostics keeper registered (Phase 1B + 1D-2A + 1D-2C-1)');
})(typeof window !== 'undefined' ? window : globalThis);
